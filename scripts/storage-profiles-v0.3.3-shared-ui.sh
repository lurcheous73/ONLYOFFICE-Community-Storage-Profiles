#!/usr/bin/env bash
set -euo pipefail

# ONLYOFFICE Community Storage Profiles — v0.3.3
# Shared S3Compatible provider UI for Storage / Backup / Scheduled Backup / Restore.
#
# This is presentation-only. It does not read credentials, call storage APIs,
# start a backup/restore, or start a storage migration.

CP="${OCSP_CONTROL_PANEL_CONTAINER:-onlyoffice-control-panel}"
ROOT="/var/www/onlyoffice/controlpanel/www"
STORAGE_JS="$ROOT/public/javascripts/views/storage.js"
CONSUMER_JS="$ROOT/public/javascripts/views/consumersettings.js"
BACKUP_PUG="$ROOT/views/backup.pug"
RESTORE_PUG="$ROOT/views/restore.pug"
STATE_DIR="/var/lib/onlyoffice-community-storage-profiles"
BACKUP_ROOT="/var/backups/onlyoffice-community-storage-profiles"
STATE_FILE="$STATE_DIR/storage-profiles-v0.3.3-ui.state"
BASE_MARKER='OCSP v0.3.1.2 delegated provider switching'
LIVE_V2_MARKER='OCSP shared S3Compatible provider dropdowns v2'
FINAL_MARKER='OCSP v0.3.3 shared S3Compatible UI'
TMP=""

say(){ printf '%s\n' "$*"; }
die(){ say "ERROR: $*" >&2; exit 1; }
cleanup(){ [ -n "${TMP:-}" ] && [ -d "$TMP" ] && rm -rf -- "$TMP" || true; }
trap cleanup EXIT

wait_cp(){
  local i
  for i in $(seq 1 90); do
    if [ "$(docker inspect -f '{{.State.Running}}' "$CP" 2>/dev/null || true)" = true ] && docker exec "$CP" true >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  die "$CP did not return to running state"
}

bundle_path(){
  local b
  mapfile -t b < <(docker exec "$CP" sh -lc "find '$ROOT/public/javascripts' -maxdepth 1 -type f -name 'combined.*.js' -print | sort")
  [ "${#b[@]}" -eq 1 ] || die "expected exactly one production combined.*.js bundle; found ${#b[@]}"
  printf '%s\n' "${b[0]}"
}

banner(){
cat <<'EOF'
====================================================================
 ONLYOFFICE Community Storage Profiles — v0.3.3
 Shared provider UI finalizer
====================================================================
EOF
}

status(){
  banner
  [ -f "$STATE_FILE" ] && { say "v0.3.3 state: PRESENT"; sed 's/^/  /' "$STATE_FILE"; } || say "v0.3.3 state: absent"
  if docker exec "$CP" grep -Fq "$FINAL_MARKER" "$CONSUMER_JS" 2>/dev/null; then
    say "Shared provider UI: PRESENT"
  elif docker exec "$CP" grep -Fq "$LIVE_V2_MARKER" "$CONSUMER_JS" 2>/dev/null; then
    say "Shared provider UI: v2 live patch present; finalizer not applied"
  else
    say "Shared provider UI: absent"
  fi
  say "No credentials are read and no storage/backup/restore API is called by status."
}

install_patch(){
  banner
  command -v docker >/dev/null || die "docker not found"
  command -v python3 >/dev/null || die "python3 not found"
  [ ! -f "$STATE_FILE" ] || die "v0.3.3 already installed; use status or rollback"
  docker inspect "$CP" >/dev/null 2>&1 || die "container not found: $CP"
  docker exec "$CP" test -f "$STORAGE_JS" || die "storage.js missing"
  docker exec "$CP" test -f "$CONSUMER_JS" || die "consumersettings.js missing"
  docker exec "$CP" test -f "$BACKUP_PUG" || die "backup.pug missing"
  docker exec "$CP" test -f "$RESTORE_PUG" || die "restore.pug missing"
  docker exec "$CP" grep -Fq "$BASE_MARKER" "$STORAGE_JS" || die "working v0.3.1.2 provider implementation missing from storage.js"
  docker exec "$CP" grep -Fq '{{if id == "S3" || id == "S3Compatible"}}' "$BACKUP_PUG" || die "Backup does not render S3Compatible with S3 controls"
  docker exec "$CP" grep -Fq '{{if id == "S3" || id == "S3Compatible"}}' "$RESTORE_PUG" || die "Restore does not render S3Compatible with S3 controls"
  docker exec "$CP" grep -Fq "$FINAL_MARKER" "$CONSUMER_JS" && die "v0.3.3 marker already present without state"

  BUNDLE="$(bundle_path)"
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  backup="$BACKUP_ROOT/v0.3.3-ui-$stamp"
  mkdir -p "$backup" "$STATE_DIR"; chmod 700 "$backup" "$STATE_DIR"
  TMP="$(mktemp -d /tmp/ocsp-v033-ui.XXXXXX)"

  say "Backing up shared consumer UI and production bundle to: $backup"
  docker cp "$CP:$CONSUMER_JS" "$backup/consumersettings.js" >/dev/null
  docker cp "$CP:$BUNDLE" "$backup/$(basename "$BUNDLE")" >/dev/null
  chmod 600 "$backup/consumersettings.js" "$backup/$(basename "$BUNDLE")"

  docker cp "$CP:$STORAGE_JS" "$TMP/storage.js" >/dev/null
  docker cp "$CP:$CONSUMER_JS" "$TMP/consumersettings.js" >/dev/null

  python3 - "$TMP/storage.js" "$TMP/consumersettings.js" <<'PY'
import re,sys
from pathlib import Path

storage_path, consumer_path = map(Path, sys.argv[1:3])
s = storage_path.read_text(encoding='utf-8')
c = consumer_path.read_text(encoding='utf-8')

LIVE_V2 = 'OCSP shared S3Compatible provider dropdowns v2'
FINAL = 'OCSP v0.3.3 shared S3Compatible UI'

if FINAL in c:
    raise SystemExit('v0.3.3 marker already present')

# If yesterday's verified live v2 patch is present, upgrade it in place.
if LIVE_V2 in c:
    old = '            var $row = $s3.find("[data-id=\'" + key + "\']");'
    new = '            var $row = $s3.find("[data-id=\'" + key + "\'], [prop-id=\'" + key + "\']").first();'
    if c.count(old) != 1:
        raise SystemExit(f'expected one shared label row lookup, got {c.count(old)}')
    c = c.replace(old, new, 1)
    c = c.replace('    // ' + LIVE_V2 + '\n', '    // ' + LIVE_V2 + '\n    // ' + FINAL + '\n', 1)
else:
    # Fresh install from the already-tested v0.3.1.2 Storage-page helper.
    pat = re.compile(
        r'    // BEGIN OCSP v0\.3 S3Compatible Control Panel\n'
        r'.*?'
        r'    // END OCSP v0\.3 S3Compatible Control Panel\n',
        re.S
    )
    m = pat.search(s)
    if not m:
        raise SystemExit('working provider helper block not found in storage.js')
    helper = m.group(0)

    old = '            var $row = $s3.find("[data-id=\'" + key + "\']");'
    new = '            var $row = $s3.find("[data-id=\'" + key + "\'], [prop-id=\'" + key + "\']").first();'
    if helper.count(old) != 1:
        raise SystemExit(f'expected one helper label row lookup, got {helper.count(old)}')
    helper = helper.replace(old, new, 1)
    helper = '    // ' + FINAL + '\n' + helper + '\n'

    anchor = '    function initS3Regions(regions) {'
    if c.count(anchor) != 1:
        raise SystemExit(f'initS3Regions anchor count = {c.count(anchor)}')
    c = c.replace(anchor, helper + anchor, 1)

    old = '        init: init,'
    new = '''        init: function(view, storages) {
            init(view, storages);
            ocspLoadCatalogue();
        },'''
    if c.count(old) != 1:
        raise SystemExit(f'exported init entry count = {c.count(old)}')
    c = c.replace(old, new, 1)

    old = '        bindEvents: bindEvents,'
    new = '''        bindEvents: function($box) {
            bindEvents($box);
            ocspInjectProfileSelector($box);
            $box.find(
                ".storage[data-id='S3Compatible'] " +
                "[data-id='disabledefaultchecksumvalidation']"
            ).hide();
        },'''
    if c.count(old) != 1:
        raise SystemExit(f'exported bindEvents entry count = {c.count(old)}')
    c = c.replace(old, new, 1)

required = [
    FINAL,
    'ocsp-profile-select',
    'MEGA S4',
    'ocspInjectProfileSelector($box)',
    'disabledefaultchecksumvalidation',
    '[prop-id=\'" + key + "\']'
]
for item in required:
    if item not in c:
        raise SystemExit('required final UI content missing: ' + item)

# The provider selector is UI-only metadata and must never be serialized as a
# storage property.
if 'data-id="ocsp-profile' in c:
    raise SystemExit('unsafe provider profile data-id detected')

consumer_path.write_text(c, encoding='utf-8')
print('PASS: v0.3.3 shared UI source prepared')
PY

  docker cp "$TMP/consumersettings.js" "$CP:/tmp/ocsp-consumersettings-v033.js" >/dev/null
  docker exec "$CP" node --check /tmp/ocsp-consumersettings-v033.js >/dev/null || die "patched consumersettings.js syntax check failed"
  docker exec "$CP" rm -f /tmp/ocsp-consumersettings-v033.js

  meta="$(docker exec "$CP" stat -c '%u:%g:%a' "$CONSUMER_JS")"
  uid="${meta%%:*}"; rest="${meta#*:}"; gid="${rest%%:*}"; mode="${rest##*:}"
  docker cp "$TMP/consumersettings.js" "$CP:$CONSUMER_JS" >/dev/null
  docker exec "$CP" chown "$uid:$gid" "$CONSUMER_JS"
  docker exec "$CP" chmod "$mode" "$CONSUMER_JS"
  docker exec "$CP" grep -Fq "$FINAL_MARKER" "$CONSUMER_JS" || die "v0.3.3 source marker missing after deploy"

  old_sha="$(docker exec "$CP" sha256sum "$BUNDLE" | awk '{print $1}')"
  say "Old bundle SHA256: $old_sha"
  docker exec "$CP" rm -f "$BUNDLE"
  say "Restarting $CP and waiting for the COMPLETE production bundle..."
  docker restart "$CP" >/dev/null
  wait_cp

  # bundle.js writes combined.* incrementally. Do not treat mere file existence
  # as completion: wait until the final S3Compatible strings are actually there.
  ready=0
  for i in $(seq 1 120); do
    if docker exec "$CP" test -f "$BUNDLE" >/dev/null 2>&1 \
       && docker exec "$CP" grep -aFq 'ocsp-profile-select' "$BUNDLE" >/dev/null 2>&1 \
       && docker exec "$CP" grep -aFq 'MEGA S4' "$BUNDLE" >/dev/null 2>&1 \
       && docker exec "$CP" grep -aFq 'disabledefaultchecksumvalidation' "$BUNDLE" >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 1
  done
  [ "$ready" = 1 ] || die "production bundle never reached the completed S3Compatible state"

  new_sha="$(docker exec "$CP" sha256sum "$BUNDLE" | awk '{print $1}')"
  say "New bundle SHA256: $new_sha"

  cat >"$STATE_FILE" <<EOF
PATCH_VERSION=v0.3.3
BACKUP_DIR=$backup
BUNDLE=$BUNDLE
INSTALLED_UTC=$stamp
EOF
  chmod 600 "$STATE_FILE"

  say
  say "PASS: v0.3.3 shared S3Compatible UI installed."
  say "Provider dropdowns are shared by Storage, Backup, Scheduled Backup and Restore."
  say "The internal checksum-compatibility field is hidden and the S3 encryption label is presented as Encryption."
  say "No credentials were read or changed; no storage, backup, restore or migration API was called."
}

rollback_patch(){
  banner
  [ -f "$STATE_FILE" ] || die "v0.3.3 state absent"
  # shellcheck disable=SC1090
  source "$STATE_FILE"
  [ "${PATCH_VERSION:-}" = v0.3.3 ] || die "unexpected state version"
  [ -f "$BACKUP_DIR/consumersettings.js" ] || die "consumersettings.js backup missing"
  [ -f "$BACKUP_DIR/$(basename "$BUNDLE")" ] || die "bundle backup missing"
  say "Restoring exact pre-v0.3.3 shared UI from: $BACKUP_DIR"
  docker cp "$BACKUP_DIR/consumersettings.js" "$CP:$CONSUMER_JS" >/dev/null
  docker cp "$BACKUP_DIR/$(basename "$BUNDLE")" "$CP:$BUNDLE" >/dev/null
  rm -f "$STATE_FILE"
  docker restart "$CP" >/dev/null
  wait_cp
  say "PASS: v0.3.3 rolled back to the exact previous shared UI."
}

case "${1:-}" in
  install) install_patch;;
  status) status;;
  rollback) rollback_patch;;
  *) echo "Usage: $0 {install|status|rollback}" >&2; exit 2;;
esac
