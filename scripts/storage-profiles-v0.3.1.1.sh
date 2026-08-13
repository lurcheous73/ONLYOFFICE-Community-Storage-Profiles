#!/usr/bin/env bash
set -euo pipefail

# ONLYOFFICE Community Storage Profiles — v0.3.1.1
# Corrective patch for v0.3.1 provider UI:
#   * load runtime catalogue through Common.basePath
#   * clear stale provider-owned values when switching profiles
#   * rebuild the actual production combined.*.js bundle
#
# No credentials are read or changed. No storage API is called. No migration.

CP="${OCSP_CONTROL_PANEL_CONTAINER:-onlyoffice-control-panel}"
ROOT="/var/www/onlyoffice/controlpanel/www"
SRC="$ROOT/public/javascripts/views/storage.js"
CATALOGUE="$ROOT/public/resources/ocsp-s3-providers.json"
STATE_DIR="/var/lib/onlyoffice-community-storage-profiles"
BACKUP_ROOT="/var/backups/onlyoffice-community-storage-profiles"
V031_STATE="$STATE_DIR/storage-profiles-v0.3.1.state"
STATE_FILE="$STATE_DIR/storage-profiles-v0.3.1.1.state"
MARKER_V031='OCSP v0.3.1 provider catalogue'
MARKER_V0311='OCSP v0.3.1.1 provider switch reset'
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
 ONLYOFFICE Community Storage Profiles — v0.3.1.1
 Runtime catalogue + provider switch correction
====================================================================
EOF
}

status(){
  banner
  [ -f "$V031_STATE" ] && say "v0.3.1 base: PRESENT" || say "v0.3.1 base: absent"
  [ -f "$STATE_FILE" ] && { say "v0.3.1.1 state: PRESENT"; sed 's/^/  /' "$STATE_FILE"; } || say "v0.3.1.1 state: absent"
  if docker exec "$CP" grep -Fq "$MARKER_V0311" "$SRC" 2>/dev/null; then say "Provider switch correction: PRESENT"; else say "Provider switch correction: absent"; fi
  if docker exec "$CP" test -f "$CATALOGUE" 2>/dev/null; then
    say "Runtime catalogue file: PRESENT"
    docker exec "$CP" python3 -c 'import json; d=json.load(open("/var/www/onlyoffice/controlpanel/www/public/resources/ocsp-s3-providers.json")); print("  version=%s revision=%s updated=%s providers=%s"%(d.get("catalogueVersion"),d.get("revision"),d.get("updated"),len(d.get("providers",[]))))' 2>/dev/null || true
  else
    say "Runtime catalogue file: absent"
  fi
  say "No credentials are read and no storage API is called by status."
}

install_patch(){
  banner
  command -v docker >/dev/null || die "docker not found"
  command -v python3 >/dev/null || die "python3 not found"
  [ -f "$V031_STATE" ] || die "v0.3.1 state not found"
  [ ! -f "$STATE_FILE" ] || die "v0.3.1.1 already installed; use status or rollback"
  docker inspect "$CP" >/dev/null 2>&1 || die "container not found: $CP"
  docker exec "$CP" test -f "$SRC" || die "storage.js missing"
  docker exec "$CP" test -f "$CATALOGUE" || die "runtime catalogue missing"
  docker exec "$CP" grep -Fq "$MARKER_V031" "$SRC" || die "v0.3.1 marker missing from storage.js"
  docker exec "$CP" grep -Fq "$MARKER_V0311" "$SRC" && die "v0.3.1.1 marker already present without state"

  BUNDLE="$(bundle_path)"
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  backup="$BACKUP_ROOT/v0.3.1.1-$stamp"
  mkdir -p "$backup" "$STATE_DIR"; chmod 700 "$backup" "$STATE_DIR"
  TMP="$(mktemp -d /tmp/ocsp-v0311.XXXXXX)"

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

old='$.getJSON("/resources/ocsp-s3-providers.json")'
new='$.getJSON(((window.Common && Common.basePath) ? Common.basePath.replace(/\\/$/, "") : "") + "/resources/ocsp-s3-providers.json")'
if text.count(old) != 1:
    raise SystemExit(f'expected one absolute catalogue URL, got {text.count(old)}')
text=text.replace(old,new,1)

old_block='''        var defaults = provider.defaults || {};
        if (provider.id !== "custom-s3") {
            ["region", "serviceurl"].forEach(function (key) {
                if (Object.prototype.hasOwnProperty.call(defaults, key)) ocspSetText($s3, key, defaults[key]);
            });
            ["forcepathstyle", "usehttp"].forEach(function (key) {
                if (Object.prototype.hasOwnProperty.call(defaults, key)) ocspSetBool($s3, key, defaults[key]);
            });
        }
'''
new_block='''        var defaults = provider.defaults || {};
        // OCSP v0.3.1.1 provider switch reset
        // Preserve the user-specific bucket, but never carry endpoint/region/root
        // values or addressing flags from one provider profile into another.
        ["region", "serviceurl", "cname", "cnamessl"].forEach(function (key) {
            ocspSetText($s3, key, "");
        });
        ["forcepathstyle", "usehttp"].forEach(function (key) {
            ocspSetBool($s3, key, false);
        });
        if (provider.id !== "custom-s3") {
            ["region", "serviceurl"].forEach(function (key) {
                if (Object.prototype.hasOwnProperty.call(defaults, key)) ocspSetText($s3, key, defaults[key]);
            });
            ["forcepathstyle", "usehttp"].forEach(function (key) {
                if (Object.prototype.hasOwnProperty.call(defaults, key)) ocspSetBool($s3, key, defaults[key]);
            });
        }
'''
if text.count(old_block) != 1:
    raise SystemExit(f'expected one provider apply block, got {text.count(old_block)}')
text=text.replace(old_block,new_block,1)

if 'OCSP v0.3.1.1 provider switch reset' not in text:
    raise SystemExit('v0.3.1.1 marker missing after patch')
if 'Common.basePath' not in text or 'ocsp-s3-providers.json' not in text:
    raise SystemExit('base-path catalogue loader missing after patch')
dst.write_text(text,encoding='utf-8')
PY

  docker exec "$CP" stat -c '%u:%g:%a' "$SRC" >"$TMP/meta"
  meta="$(cat "$TMP/meta")"; uid="${meta%%:*}"; rest="${meta#*:}"; gid="${rest%%:*}"; mode="${rest##*:}"
  docker cp "$TMP/storage.new.js" "$CP:$SRC" >/dev/null
  docker exec "$CP" chown "$uid:$gid" "$SRC"
  docker exec "$CP" chmod "$mode" "$SRC"
  docker exec "$CP" node --check "$SRC" >/dev/null || die "patched storage.js syntax check failed"
  docker exec "$CP" grep -Fq "$MARKER_V0311" "$SRC" || die "v0.3.1.1 marker missing after install"

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

  # Verify stable user-visible/minified strings instead of source comments.
  docker exec "$CP" grep -aFq 'ocsp-profile-select' "$BUNDLE" || die "provider selector missing from regenerated bundle"
  docker exec "$CP" grep -aFq 'MEGA S4' "$BUNDLE" || die "MEGA S4 missing from regenerated bundle"
  docker exec "$CP" grep -aFq 'embedded-fallback' "$BUNDLE" || die "provider catalogue code missing from regenerated bundle"

  cat >"$STATE_FILE" <<EOF
PATCH_VERSION=v0.3.1.1
BACKUP_DIR=$backup
BUNDLE=$BUNDLE
INSTALLED_UTC=$stamp
EOF
  chmod 600 "$STATE_FILE"

  say
  say "PASS: v0.3.1.1 corrective patch installed."
  say "Provider switches now clear stale provider-owned values while preserving bucket."
  say "Runtime catalogue URL now follows Control Panel Common.basePath."
  say "No credentials were read or changed; no storage API was called; no migration started."
}

rollback_patch(){
  banner
  [ -f "$STATE_FILE" ] || die "v0.3.1.1 state absent"
  # shellcheck disable=SC1090
  source "$STATE_FILE"
  [ "${PATCH_VERSION:-}" = "v0.3.1.1" ] || die "unexpected state version"
  [ -f "$BACKUP_DIR/storage.js" ] || die "storage.js backup missing"
  [ -f "$BACKUP_DIR/$(basename "$BUNDLE")" ] || die "bundle backup missing"

  say "Restoring v0.3.1 source and production bundle from: $BACKUP_DIR"
  docker cp "$BACKUP_DIR/storage.js" "$CP:$SRC" >/dev/null
  docker cp "$BACKUP_DIR/$(basename "$BUNDLE")" "$CP:$BUNDLE" >/dev/null
  rm -f "$STATE_FILE"
  docker restart "$CP" >/dev/null
  wait_container
  say "PASS: v0.3.1.1 rolled back to v0.3.1 presentation."
}

case "${1:-}" in
  install) install_patch;;
  status) status;;
  rollback) rollback_patch;;
  *) echo "Usage: $0 {install|status|rollback}" >&2; exit 2;;
esac
