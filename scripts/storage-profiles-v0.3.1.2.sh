#!/usr/bin/env bash
set -euo pipefail

# ONLYOFFICE Community Storage Profiles — v0.3.1.2
# Correct provider switching after Control Panel form re-renders.
#
# Fixes:
#   * bind provider changes on the stable .storageView container
#   * set selected provider state before clearing/applying fields
#   * stop programmatic field writes from recursively firing the previous profile
#   * rebuild the actual production combined.*.js bundle
#
# No credentials are read or changed. No storage API is called. No migration.

CP="${OCSP_CONTROL_PANEL_CONTAINER:-onlyoffice-control-panel}"
ROOT="/var/www/onlyoffice/controlpanel/www"
SRC="$ROOT/public/javascripts/views/storage.js"
STATE_DIR="/var/lib/onlyoffice-community-storage-profiles"
BACKUP_ROOT="/var/backups/onlyoffice-community-storage-profiles"
BASE_STATE="$STATE_DIR/storage-profiles-v0.3.1.1.state"
STATE_FILE="$STATE_DIR/storage-profiles-v0.3.1.2.state"
BASE_MARKER='OCSP v0.3.1.1 provider switch reset'
MARKER='OCSP v0.3.1.2 delegated provider switching'
TMP=""

say(){ printf '%s\n' "$*"; }
die(){ say "ERROR: $*" >&2; exit 1; }
cleanup(){ [ -n "${TMP:-}" ] && [ -d "$TMP" ] && rm -rf -- "$TMP" || true; }
trap cleanup EXIT

wait_container(){
  local i
  for i in $(seq 1 90); do
    if [ "$(docker inspect -f '{{.State.Running}}' "$CP" 2>/dev/null || true)" = true ] && docker exec "$CP" true >/dev/null 2>&1; then return 0; fi
    sleep 2
  done
  die "$CP did not return to running state"
}

bundle_path(){
  mapfile -t b < <(docker exec "$CP" sh -lc "find '$ROOT/public/javascripts' -maxdepth 1 -type f -name 'combined.*.js' -print | sort")
  [ "${#b[@]}" -eq 1 ] || die "expected exactly one production combined.*.js bundle; found ${#b[@]}"
  printf '%s\n' "${b[0]}"
}

banner(){
cat <<'EOF'
====================================================================
 ONLYOFFICE Community Storage Profiles — v0.3.1.2
 Delegated provider switching
====================================================================
EOF
}

status(){
  banner
  [ -f "$BASE_STATE" ] && say "v0.3.1.1 base: PRESENT" || say "v0.3.1.1 base: absent"
  [ -f "$STATE_FILE" ] && { say "v0.3.1.2 state: PRESENT"; sed 's/^/  /' "$STATE_FILE"; } || say "v0.3.1.2 state: absent"
  if docker exec "$CP" grep -Fq "$MARKER" "$SRC" 2>/dev/null; then say "Delegated provider switching: PRESENT"; else say "Delegated provider switching: absent"; fi
  say "No credentials are read and no storage API is called by status."
}

install_patch(){
  banner
  command -v docker >/dev/null || die "docker not found"
  command -v python3 >/dev/null || die "python3 not found"
  [ -f "$BASE_STATE" ] || die "v0.3.1.1 state not found"
  [ ! -f "$STATE_FILE" ] || die "v0.3.1.2 already installed; use status or rollback"
  docker inspect "$CP" >/dev/null 2>&1 || die "container not found: $CP"
  docker exec "$CP" test -f "$SRC" || die "storage.js missing"
  docker exec "$CP" grep -Fq "$BASE_MARKER" "$SRC" || die "v0.3.1.1 marker missing from storage.js"
  docker exec "$CP" grep -Fq "$MARKER" "$SRC" && die "v0.3.1.2 marker already present without state"

  BUNDLE="$(bundle_path)"
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  backup="$BACKUP_ROOT/v0.3.1.2-$stamp"
  mkdir -p "$backup" "$STATE_DIR"; chmod 700 "$backup" "$STATE_DIR"
  TMP="$(mktemp -d /tmp/ocsp-v0312.XXXXXX)"

  say "Control Panel bundle: $BUNDLE"
  say "Backing up storage.js and production bundle to: $backup"
  docker cp "$CP:$SRC" "$backup/storage.js" >/dev/null
  docker cp "$CP:$BUNDLE" "$backup/$(basename "$BUNDLE")" >/dev/null
  chmod 600 "$backup/storage.js" "$backup/$(basename "$BUNDLE")"

  docker cp "$CP:$SRC" "$TMP/storage.orig.js" >/dev/null
  python3 - "$TMP/storage.orig.js" "$TMP/storage.new.js" <<'PY'
from pathlib import Path
import sys
src,dst=map(Path,sys.argv[1:3])
text=src.read_text(encoding='utf-8')

old='''    function ocspSetText($s3, key, value) {
        var $input = ocspText($s3, key);
        if ($input.length) $input.val(value == null ? "" : value).trigger("input");
    }
'''
new='''    function ocspSetText($s3, key, value) {
        var $input = ocspText($s3, key);
        // OCSP v0.3.1.2 delegated provider switching
        // Programmatic preset writes must not recursively invoke the previous
        // provider through the delegated input recalculation handler.
        if ($input.length) $input.val(value == null ? "" : value);
    }
'''
if text.count(old) != 1:
    raise SystemExit(f'expected one ocspSetText block, got {text.count(old)}')
text=text.replace(old,new,1)

old='''    function ocspApplyProfile($s3, provider) {
        if (!provider) return;
        var defaults = provider.defaults || {};
        // OCSP v0.3.1.1 provider switch reset
'''
new='''    function ocspApplyProfile($s3, provider) {
        if (!provider) return;
        // Make the newly selected profile authoritative before any field reset.
        // This prevents stale profile state being observed during the switch.
        $s3.data("ocspProvider", provider.id);
        var defaults = provider.defaults || {};
        // OCSP v0.3.1.1 provider switch reset
'''
if text.count(old) != 1:
    raise SystemExit(f'expected one ocspApplyProfile header, got {text.count(old)}')
text=text.replace(old,new,1)

# Remove the later duplicate state assignment: the new profile is now recorded
# before reset/apply, where it belongs.
old='''        $s3.data("ocspProvider", provider.id);
        var meta = provider.note || "";
'''
new='''        var meta = provider.note || "";
'''
if text.count(old) != 1:
    raise SystemExit(f'expected one late ocspProvider assignment, got {text.count(old)}')
text=text.replace(old,new,1)

old='''        $s3.find(".ocsp-profile-select").on("change.ocsp", function () {
            ocspApplyProfile($s3, ocspFindProvider($(this).val()));
        });
        $s3.on("input.ocsp change.ocsp", "[data-id='region'] .textBox, [data-id='bucket'] .textBox, [data-id='serviceurl'] .textBox", function () {
            ocspRecalculate($s3, ocspFindProvider($s3.data("ocspProvider")));
        });
'''
new='''        // Bind on the stable Storage view, not on the generated S3 form.
        // ONLYOFFICE can rebuild the form markup; delegated handlers survive it.
        $view.off("change.ocspProfile", ".ocsp-profile-select")
             .on("change.ocspProfile", ".ocsp-profile-select", function () {
                 var $currentS3 = $(this).closest(".storage[data-id='S3Compatible']");
                 ocspApplyProfile($currentS3, ocspFindProvider($(this).val()));
             });
        $view.off("input.ocspProfile change.ocspProfileFields", ".storage[data-id='S3Compatible'] [data-id='region'] .textBox, .storage[data-id='S3Compatible'] [data-id='bucket'] .textBox, .storage[data-id='S3Compatible'] [data-id='serviceurl'] .textBox")
             .on("input.ocspProfile change.ocspProfileFields", ".storage[data-id='S3Compatible'] [data-id='region'] .textBox, .storage[data-id='S3Compatible'] [data-id='bucket'] .textBox, .storage[data-id='S3Compatible'] [data-id='serviceurl'] .textBox", function () {
                 var $currentS3 = $(this).closest(".storage[data-id='S3Compatible']");
                 ocspRecalculate($currentS3, ocspFindProvider($currentS3.data("ocspProvider")));
             });
'''
if text.count(old) != 1:
    raise SystemExit(f'expected one direct OCSP binding block, got {text.count(old)}')
text=text.replace(old,new,1)

if 'OCSP v0.3.1.2 delegated provider switching' not in text:
    raise SystemExit('v0.3.1.2 marker missing after patch')
if '.on("change.ocspProfile", ".ocsp-profile-select"' not in text:
    raise SystemExit('delegated profile handler missing after patch')

dst.write_text(text,encoding='utf-8')
PY

  meta="$(docker exec "$CP" stat -c '%u:%g:%a' "$SRC")"
  uid="${meta%%:*}"; rest="${meta#*:}"; gid="${rest%%:*}"; mode="${rest##*:}"
  docker cp "$TMP/storage.new.js" "$CP:$SRC" >/dev/null
  docker exec "$CP" chown "$uid:$gid" "$SRC"
  docker exec "$CP" chmod "$mode" "$SRC"
  docker exec "$CP" node --check "$SRC" >/dev/null || die "patched storage.js syntax check failed"
  docker exec "$CP" grep -Fq "$MARKER" "$SRC" || die "v0.3.1.2 marker missing after install"

  old_sha="$(docker exec "$CP" sha256sum "$BUNDLE" | awk '{print $1}')"
  say "Old bundle SHA256: $old_sha"
  docker exec "$CP" rm -f "$BUNDLE"
  say "Restarting $CP so production bundle is regenerated from corrected source..."
  docker restart "$CP" >/dev/null
  wait_container

  for i in $(seq 1 90); do
    if docker exec "$CP" test -f "$BUNDLE" 2>/dev/null; then break; fi
    sleep 1
  done
  docker exec "$CP" test -f "$BUNDLE" || die "bundle did not regenerate: $BUNDLE"
  new_sha="$(docker exec "$CP" sha256sum "$BUNDLE" | awk '{print $1}')"
  say "New bundle SHA256: $new_sha"
  [ "$new_sha" != "$old_sha" ] || say "WARNING: regenerated bundle SHA is unchanged"

  docker exec "$CP" grep -aFq 'ocsp-profile-select' "$BUNDLE" || die "provider selector missing from regenerated bundle"
  docker exec "$CP" grep -aFq 'MEGA S4' "$BUNDLE" || die "MEGA S4 missing from regenerated bundle"
  docker exec "$CP" grep -aFq 'ocspProvider' "$BUNDLE" || die "provider state code missing from regenerated bundle"

  cat >"$STATE_FILE" <<EOF
PATCH_VERSION=v0.3.1.2
BACKUP_DIR=$backup
BUNDLE=$BUNDLE
INSTALLED_UTC=$stamp
EOF
  chmod 600 "$STATE_FILE"

  say
  say "PASS: v0.3.1.2 provider switching fix installed."
  say "Provider changes now use delegated handlers that survive Control Panel form rebuilds."
  say "Programmatic preset writes no longer recurse through the previous provider."
  say "No credentials were read or changed; no storage API was called; no migration started."
}

rollback_patch(){
  banner
  [ -f "$STATE_FILE" ] || die "v0.3.1.2 state absent"
  # shellcheck disable=SC1090
  source "$STATE_FILE"
  [ "${PATCH_VERSION:-}" = "v0.3.1.2" ] || die "unexpected state version"
  [ -f "$BACKUP_DIR/storage.js" ] || die "storage.js backup missing"
  [ -f "$BACKUP_DIR/$(basename "$BUNDLE")" ] || die "bundle backup missing"

  say "Restoring v0.3.1.1 source and production bundle from: $BACKUP_DIR"
  docker cp "$BACKUP_DIR/storage.js" "$CP:$SRC" >/dev/null
  docker cp "$BACKUP_DIR/$(basename "$BUNDLE")" "$CP:$BUNDLE" >/dev/null
  rm -f "$STATE_FILE"
  docker restart "$CP" >/dev/null
  wait_container
  say "PASS: v0.3.1.2 rolled back to v0.3.1.1 presentation."
}

case "${1:-}" in
  install) install_patch;;
  status) status;;
  rollback) rollback_patch;;
  *) echo "Usage: $0 {install|status|rollback}" >&2; exit 2;;
esac
