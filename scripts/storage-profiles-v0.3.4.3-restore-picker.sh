#!/usr/bin/env bash
set -euo pipefail

# OCSP v0.3.4.3 — S3-compatible restore bucket / backup object picker.
# Adds read-only ListObjectsV2 + HEAD discovery and gates Restore until the
# selected .tar.gz object has been verified. No restore is started here.

CP="${OCSP_CONTROL_PANEL_CONTAINER:-onlyoffice-control-panel}"
EXPECTED_CP_IMAGE="onlyoffice/controlpanel:3.5.5.549"
ROOT="/var/www/onlyoffice/controlpanel/www"
BACKUP_CONTROLLER="$ROOT/app/controllers/backup.js"
RESTORE_JS="$ROOT/public/javascripts/views/restore.js"
EXISTING_PROBE="$ROOT/app/ocsp/s3Probe.js"
EXISTING_BACKUP_UI="$ROOT/public/javascripts/views/ocsp-manual-s3-backup.js"
RESTORE_PROBE="$ROOT/app/ocsp/s3RestoreProbe.js"
RESTORE_UI="$ROOT/public/javascripts/views/ocsp-s3-restore.js"

STATE_DIR="/var/lib/onlyoffice-community-storage-profiles"
BACKUP_ROOT="/var/backups/onlyoffice-community-storage-profiles"
V0342_STATE="$STATE_DIR/storage-profiles-v0.3.4.2-fetch-buckets.state"
STATE_FILE="$STATE_DIR/storage-profiles-v0.3.4.3-restore-picker.state"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
PROBE_SOURCE="$REPO_ROOT/patches/v0.3.4/controlpanel-s3-restore-probe.js"
UI_SOURCE="$REPO_ROOT/patches/v0.3.4/controlpanel-s3-restore.js"

TMP=""
say(){ printf '%s\n' "$*"; }
die(){ say "ERROR: $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }
cleanup(){ [ -n "${TMP:-}" ] && [ -d "$TMP" ] && rm -rf -- "$TMP" || true; }
trap cleanup EXIT

wait_cp(){
  local i
  for i in $(seq 1 90); do
    if [ "$(docker inspect -f '{{.State.Running}}' "$CP" 2>/dev/null || true)" = true ] \
       && docker exec "$CP" true >/dev/null 2>&1; then
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

copy_with_meta(){
  local source="$1" target="$2" meta_source="$3" meta uid gid mode rest
  meta="$(docker exec "$CP" stat -c '%u:%g:%a' "$meta_source")"
  uid="${meta%%:*}"; rest="${meta#*:}"; gid="${rest%%:*}"; mode="${rest##*:}"
  docker cp "$source" "$CP:$target" >/dev/null
  docker exec "$CP" chown "$uid:$gid" "$target"
  docker exec "$CP" chmod "$mode" "$target"
}

preflight(){
  need docker; need python3; need sha256sum
  [ -f "$V0342_STATE" ] || die "v0.3.4.2 saved-key bucket UI state missing"
  [ ! -f "$STATE_FILE" ] || die "v0.3.4.3 already installed; use status or rollback"
  [ -f "$PROBE_SOURCE" ] || die "missing source: $PROBE_SOURCE"
  [ -f "$UI_SOURCE" ] || die "missing source: $UI_SOURCE"

  docker inspect "$CP" >/dev/null 2>&1 || die "container not found: $CP"
  [ "$(docker inspect -f '{{.Config.Image}}' "$CP")" = "$EXPECTED_CP_IMAGE" ] \
    || die "unsupported Control Panel image: $(docker inspect -f '{{.Config.Image}}' "$CP")"

  docker exec "$CP" test -f "$BACKUP_CONTROLLER" || die "backup controller missing"
  docker exec "$CP" test -f "$RESTORE_JS" || die "restore.js missing"
  docker exec "$CP" test -f "$EXISTING_PROBE" || die "v0.3.4 S3 probe missing"
  docker exec "$CP" test -f "$EXISTING_BACKUP_UI" || die "v0.3.4 backup UI helper missing"
  docker exec "$CP" test ! -e "$RESTORE_PROBE" || die "unexpected pre-existing $RESTORE_PROBE"
  docker exec "$CP" test ! -e "$RESTORE_UI" || die "unexpected pre-existing $RESTORE_UI"

  docker exec "$CP" grep -Fq 'OCSP v0.3.4 manual S3 validation routes' "$BACKUP_CONTROLLER" \
    || die "v0.3.4 backup controller marker missing"
  docker exec "$CP" grep -Fq 'ocspS3ValidateBucket' "$BACKUP_CONTROLLER" \
    || die "v0.3.4 bucket validation route missing"
  docker exec "$CP" grep -Fq 'function startRestore() {' "$RESTORE_JS" \
    || die "unexpected restore.js baseline"
  docker exec "$CP" grep -Fq 'initConsumerStorages(thirdPartyJSON);' "$RESTORE_JS" \
    || die "restore consumer init anchor missing"

  docker exec "$CP" node --check "$EXISTING_PROBE" >/dev/null
  node --check "$PROBE_SOURCE" >/dev/null
  node --check "$UI_SOURCE" >/dev/null
}

install_cmd(){
  preflight
  TMP="$(mktemp -d)"

  local bundle stamp backup oldsha newsha meta uid gid mode rest ready=0
  local controller_in="$TMP/backup-controller.in" controller_out="$TMP/backup-controller.out"
  local restore_in="$TMP/restore.in" restore_out="$TMP/restore.out"

  bundle="$(bundle_path)"
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  backup="$BACKUP_ROOT/v0.3.4.3-restore-picker-$stamp"
  mkdir -p "$backup" "$STATE_DIR"
  chmod 700 "$backup" "$STATE_DIR"

  say "Backing up current Control Panel restore state to: $backup"
  docker cp "$CP:$BACKUP_CONTROLLER" "$backup/backup-controller.js" >/dev/null
  docker cp "$CP:$RESTORE_JS" "$backup/restore.js" >/dev/null
  docker cp "$CP:$bundle" "$backup/$(basename "$bundle")" >/dev/null
  chmod 600 "$backup/backup-controller.js" "$backup/restore.js" "$backup/$(basename "$bundle")"
  oldsha="$(docker exec "$CP" sha256sum "$bundle" | awk '{print $1}')"

  docker cp "$CP:$BACKUP_CONTROLLER" "$controller_in" >/dev/null
  docker cp "$CP:$RESTORE_JS" "$restore_in" >/dev/null

  python3 - "$controller_in" "$controller_out" <<'PY1'
from pathlib import Path
import sys
src,dst=map(Path,sys.argv[1:3])
t=src.read_text(encoding='utf-8')
marker='OCSP v0.3.4.3 S3 restore discovery routes'
if marker in t: raise SystemExit('v0.3.4.3 controller marker already present')
anchor="const ocspS3Probe = require('../ocsp/s3Probe.js');\n"
if t.count(anchor)!=1: raise SystemExit('existing S3 probe require anchor mismatch')
t=t.replace(anchor, anchor+"// "+marker+"\nconst ocspS3RestoreProbe = require('../ocsp/s3RestoreProbe.js');\n", 1)
anchor='    .post("/ocspS3ValidateBucket", ocspS3Probe.validateBucketHandler)\n'
if t.count(anchor)!=1: raise SystemExit('existing S3 validation route anchor mismatch')
t=t.replace(anchor, anchor+
    '    .post("/ocspS3ListBackups", ocspS3RestoreProbe.listBackupsHandler)\n'
    '    .post("/ocspS3HeadBackup", ocspS3RestoreProbe.headBackupHandler)\n', 1)
dst.write_text(t,encoding='utf-8')
PY1

  python3 - "$restore_in" "$restore_out" <<'PY2'
from pathlib import Path
import sys
src,dst=map(Path,sys.argv[1:3])
t=src.read_text(encoding='utf-8')
marker='OCSP v0.3.4.3 S3 restore picker'
if marker in t: raise SystemExit('v0.3.4.3 restore.js marker already present')
old='''                    initConsumerStorages(thirdPartyJSON);\n                    $sourceFileSelector.show();'''
new='''                    initConsumerStorages(thirdPartyJSON);\n                    // OCSP v0.3.4.3 S3 restore picker\n                    if (window.OCSPS3Restore) window.OCSPS3Restore.init();\n                    $sourceFileSelector.show();'''
if t.count(old)!=1: raise SystemExit('restore initConsumerStorages anchor mismatch')
t=t.replace(old,new,1)
old='''    function startRestore() {\n        clearSourceErrors();'''
new='''    function startRestore() {\n        if (window.OCSPS3Restore && !window.OCSPS3Restore.canStart()) {\n            window.OCSPS3Restore.warn();\n            return;\n        }\n        clearSourceErrors();'''
if t.count(old)!=1: raise SystemExit('startRestore gate anchor mismatch')
t=t.replace(old,new,1)
dst.write_text(t,encoding='utf-8')
PY2

  docker cp "$controller_out" "$CP:/tmp/ocsp-backup-controller-v0343.js" >/dev/null
  docker cp "$restore_out" "$CP:/tmp/ocsp-restore-v0343.js" >/dev/null
  docker cp "$PROBE_SOURCE" "$CP:/tmp/ocsp-s3-restore-probe-v0343.js" >/dev/null
  docker cp "$UI_SOURCE" "$CP:/tmp/ocsp-s3-restore-ui-v0343.js" >/dev/null
  docker exec "$CP" node --check /tmp/ocsp-backup-controller-v0343.js >/dev/null
  docker exec "$CP" node --check /tmp/ocsp-restore-v0343.js >/dev/null
  docker exec "$CP" node --check /tmp/ocsp-s3-restore-probe-v0343.js >/dev/null
  docker exec "$CP" node --check /tmp/ocsp-s3-restore-ui-v0343.js >/dev/null
  docker exec "$CP" rm -f /tmp/ocsp-backup-controller-v0343.js /tmp/ocsp-restore-v0343.js \
    /tmp/ocsp-s3-restore-probe-v0343.js /tmp/ocsp-s3-restore-ui-v0343.js

  meta="$(docker exec "$CP" stat -c '%u:%g:%a' "$BACKUP_CONTROLLER")"
  uid="${meta%%:*}"; rest="${meta#*:}"; gid="${rest%%:*}"; mode="${rest##*:}"
  docker cp "$controller_out" "$CP:$BACKUP_CONTROLLER" >/dev/null
  docker exec "$CP" chown "$uid:$gid" "$BACKUP_CONTROLLER"
  docker exec "$CP" chmod "$mode" "$BACKUP_CONTROLLER"

  meta="$(docker exec "$CP" stat -c '%u:%g:%a' "$RESTORE_JS")"
  uid="${meta%%:*}"; rest="${meta#*:}"; gid="${rest%%:*}"; mode="${rest##*:}"
  docker cp "$restore_out" "$CP:$RESTORE_JS" >/dev/null
  docker exec "$CP" chown "$uid:$gid" "$RESTORE_JS"
  docker exec "$CP" chmod "$mode" "$RESTORE_JS"

  copy_with_meta "$PROBE_SOURCE" "$RESTORE_PROBE" "$EXISTING_PROBE"
  copy_with_meta "$UI_SOURCE" "$RESTORE_UI" "$EXISTING_BACKUP_UI"

  docker exec "$CP" grep -Fq 'OCSP v0.3.4.3 S3 restore discovery routes' "$BACKUP_CONTROLLER" \
    || die "controller marker missing after deploy"
  docker exec "$CP" grep -Fq 'ocspS3ListBackups' "$BACKUP_CONTROLLER" \
    || die "ListBackups route missing after deploy"
  docker exec "$CP" grep -Fq 'OCSP v0.3.4.3 S3 restore picker' "$RESTORE_JS" \
    || die "restore.js marker missing after deploy"
  docker exec "$CP" grep -Fq 'Fetch backup list' "$RESTORE_UI" \
    || die "restore UI marker missing after deploy"

  say "Rebuilding Control Panel production bundle..."
  docker exec "$CP" rm -f "$bundle"
  docker restart "$CP" >/dev/null
  wait_cp

  for i in $(seq 1 120); do
    if docker exec "$CP" test -f "$bundle" >/dev/null 2>&1 \
       && docker exec "$CP" grep -aFq 'Fetch backup list' "$bundle" >/dev/null 2>&1 \
       && docker exec "$CP" grep -aFq 'Verify selected backup' "$bundle" >/dev/null 2>&1 \
       && docker exec "$CP" grep -aFq 'Select and verify the S3-compatible backup object before restoring.' "$bundle" >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 1
  done
  [ "$ready" = 1 ] || die "production bundle never reached v0.3.4.3 restore-picker state"

  newsha="$(docker exec "$CP" sha256sum "$bundle" | awk '{print $1}')"

  cat >"$STATE_FILE" <<STATE
VERSION=0.3.4.3-restore-picker
BACKUP=$backup
BUNDLE=$bundle
INSTALLED_UTC=$stamp
OLD_BUNDLE_SHA256=$oldsha
NEW_BUNDLE_SHA256=$newsha
STATE
  chmod 600 "$STATE_FILE"

  say "Control Panel bundle SHA256: $oldsha -> $newsha"
  say
  say "PASS — v0.3.4.3 S3-compatible restore picker installed."
  say "  Restore can fetch saved S3Compatible credentials, list buckets, list .tar.gz objects, and HEAD-verify the chosen backup."
  say "  Restore is gated until the selected object is verified."
  say "  Internal backupchunksize/checksum compatibility fields are hidden on Restore."
  say "  No restore, backup, storage migration, schedule, delete, upload or S3 write was started by this installer."
}

status_cmd(){
  need docker
  [ -f "$STATE_FILE" ] || die "v0.3.4.3 state absent"
  local bundle
  bundle="$(sed -n 's/^BUNDLE=//p' "$STATE_FILE" | head -1)"
  docker exec "$CP" grep -Fq 'OCSP v0.3.4.3 S3 restore discovery routes' "$BACKUP_CONTROLLER" || die "controller marker missing"
  docker exec "$CP" grep -Fq 'OCSP v0.3.4.3 S3 restore picker' "$RESTORE_JS" || die "restore marker missing"
  docker exec "$CP" node --check "$RESTORE_PROBE" >/dev/null || die "restore probe syntax failure"
  docker exec "$CP" node --check "$RESTORE_UI" >/dev/null || die "restore UI syntax failure"
  docker exec "$CP" grep -aFq 'Fetch backup list' "$bundle" || die "bundle restore picker string missing"
  docker exec "$CP" grep -aFq 'Verify selected backup' "$bundle" || die "bundle verify string missing"
  say "PASS — v0.3.4.3 S3-compatible restore picker present."
}

rollback_cmd(){
  need docker
  [ -f "$STATE_FILE" ] || die "v0.3.4.3 state absent"
  local backup bundle meta uid gid mode rest
  backup="$(sed -n 's/^BACKUP=//p' "$STATE_FILE" | head -1)"
  bundle="$(sed -n 's/^BUNDLE=//p' "$STATE_FILE" | head -1)"
  [ -f "$backup/backup-controller.js" ] || die "controller rollback file missing"
  [ -f "$backup/restore.js" ] || die "restore.js rollback file missing"
  [ -f "$backup/$(basename "$bundle")" ] || die "bundle rollback file missing"

  meta="$(docker exec "$CP" stat -c '%u:%g:%a' "$BACKUP_CONTROLLER")"
  uid="${meta%%:*}"; rest="${meta#*:}"; gid="${rest%%:*}"; mode="${rest##*:}"
  docker cp "$backup/backup-controller.js" "$CP:$BACKUP_CONTROLLER" >/dev/null
  docker exec "$CP" chown "$uid:$gid" "$BACKUP_CONTROLLER"
  docker exec "$CP" chmod "$mode" "$BACKUP_CONTROLLER"

  meta="$(docker exec "$CP" stat -c '%u:%g:%a' "$RESTORE_JS")"
  uid="${meta%%:*}"; rest="${meta#*:}"; gid="${rest%%:*}"; mode="${rest##*:}"
  docker cp "$backup/restore.js" "$CP:$RESTORE_JS" >/dev/null
  docker exec "$CP" chown "$uid:$gid" "$RESTORE_JS"
  docker exec "$CP" chmod "$mode" "$RESTORE_JS"

  docker exec "$CP" rm -f "$RESTORE_PROBE" "$RESTORE_UI"
  docker cp "$backup/$(basename "$bundle")" "$CP:$bundle" >/dev/null
  rm -f "$STATE_FILE"
  docker restart "$CP" >/dev/null
  wait_cp
  say "PASS — v0.3.4.3 rolled back to the exact pre-picker controller/restore UI/bundle."
}

case "${1:-status}" in
  install) install_cmd ;;
  status) status_cmd ;;
  rollback) rollback_cmd ;;
  *) die "usage: $0 {install|status|rollback}" ;;
esac
