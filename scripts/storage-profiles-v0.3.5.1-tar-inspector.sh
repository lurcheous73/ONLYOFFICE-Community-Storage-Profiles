#!/usr/bin/env bash
set -euo pipefail

# OCSP v0.3.5.1 — Restore-page streaming TAR inspector / single-file recovery.
# Adds read-only archive scanning plus explicit single-file extraction/download.
# The full .tar.gz is never staged locally by this tool.

CP="${OCSP_CONTROL_PANEL_CONTAINER:-onlyoffice-control-panel}"
EXPECTED_CP_IMAGE="onlyoffice/controlpanel:3.5.5.549"
ROOT="/var/www/onlyoffice/controlpanel/www"
BACKUP_CONTROLLER="$ROOT/app/controllers/backup.js"
RESTORE_JS="$ROOT/public/javascripts/views/restore.js"
INSPECTOR="$ROOT/app/ocsp/s3TarInspector.js"
BROWSER="$ROOT/public/javascripts/views/ocsp-s3-tar-browser.js"

STATE_DIR="/var/lib/onlyoffice-community-storage-profiles"
BACKUP_ROOT="/var/backups/onlyoffice-community-storage-profiles"
RESTORE_PICKER_STATE="$STATE_DIR/storage-profiles-v0.3.4.3-restore-picker.state"
STATE_FILE="$STATE_DIR/storage-profiles-v0.3.5.1-tar-inspector.state"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
INSPECTOR_SOURCE="$REPO_ROOT/patches/v0.3.5/controlpanel-s3-tar-inspector.js"
BROWSER_SOURCE="$REPO_ROOT/patches/v0.3.5/controlpanel-s3-tar-browser.js"
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
       && docker exec "$CP" true >/dev/null 2>&1; then return 0; fi
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

restore_meta(){
  local path="$1" meta="$2" uid gid mode rest
  uid="${meta%%:*}"; rest="${meta#*:}"; gid="${rest%%:*}"; mode="${rest##*:}"
  docker exec "$CP" chown "$uid:$gid" "$path"
  docker exec "$CP" chmod "$mode" "$path"
}

preflight(){
  need docker; need python3; need sha256sum
  [ -f "$RESTORE_PICKER_STATE" ] || die "v0.3.4.3 restore-picker state missing"
  [ ! -f "$STATE_FILE" ] || die "v0.3.5.1 TAR inspector already installed; use status or rollback"
  [ -f "$INSPECTOR_SOURCE" ] || die "missing source: $INSPECTOR_SOURCE"
  [ -f "$BROWSER_SOURCE" ] || die "missing source: $BROWSER_SOURCE"

  docker inspect "$CP" >/dev/null 2>&1 || die "container not found: $CP"
  [ "$(docker inspect -f '{{.Config.Image}}' "$CP")" = "$EXPECTED_CP_IMAGE" ] \
    || die "unsupported Control Panel image: $(docker inspect -f '{{.Config.Image}}' "$CP")"
  docker exec "$CP" test -f "$BACKUP_CONTROLLER" || die "backup controller missing"
  docker exec "$CP" test -f "$RESTORE_JS" || die "restore.js missing"
  docker exec "$CP" grep -Fq 'OCSP v0.3.4.3 S3 restore discovery routes' "$BACKUP_CONTROLLER" || die "v0.3.4.3 restore route marker missing"
  docker exec "$CP" grep -Fq 'ocspS3HeadBackup' "$BACKUP_CONTROLLER" || die "restore HEAD route missing"
  docker exec "$CP" grep -Fq 'OCSP v0.3.4.3 S3 restore picker' "$RESTORE_JS" || die "v0.3.4.3 restore.js marker missing"
  docker exec "$CP" test ! -e "$INSPECTOR" || die "unexpected pre-existing $INSPECTOR"
  docker exec "$CP" test ! -e "$BROWSER" || die "unexpected pre-existing $BROWSER"

  docker cp "$INSPECTOR_SOURCE" "$CP:/tmp/ocsp-s3-tar-inspector-v0351.js" >/dev/null
  docker cp "$BROWSER_SOURCE" "$CP:/tmp/ocsp-s3-tar-browser-v0351.js" >/dev/null
  docker exec "$CP" node --check /tmp/ocsp-s3-tar-inspector-v0351.js >/dev/null || die "TAR inspector backend syntax check failed"
  docker exec "$CP" node --check /tmp/ocsp-s3-tar-browser-v0351.js >/dev/null || die "TAR browser UI syntax check failed"
  docker exec "$CP" rm -f /tmp/ocsp-s3-tar-inspector-v0351.js /tmp/ocsp-s3-tar-browser-v0351.js
}

install_cmd(){
  preflight
  TMP="$(mktemp -d)"
  local bundle stamp backup oldsha newsha meta ready=0
  local controller_in="$TMP/controller.in" controller_out="$TMP/controller.out"
  local restore_in="$TMP/restore.in" restore_out="$TMP/restore.out"

  bundle="$(bundle_path)"
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  backup="$BACKUP_ROOT/v0.3.5.1-tar-inspector-$stamp"
  mkdir -p "$backup" "$STATE_DIR"; chmod 700 "$backup" "$STATE_DIR"

  say "Backing up current Restore/controller state to: $backup"
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
marker='OCSP v0.3.5.1 streaming TAR inspector routes'
if marker in t: raise SystemExit('TAR inspector controller marker already present')
anchor="const ocspS3RestoreProbe = require('../ocsp/s3RestoreProbe.js');\n"
if t.count(anchor)!=1: raise SystemExit('restore probe require anchor mismatch')
t=t.replace(anchor, anchor+"// "+marker+"\nconst ocspS3TarInspector = require('../ocsp/s3TarInspector.js');\n", 1)
anchor='    .post("/ocspS3HeadBackup", ocspS3RestoreProbe.headBackupHandler)\n'
if t.count(anchor)!=1: raise SystemExit('HEAD route anchor mismatch')
routes=(
'    .post("/ocspS3TarScanStart", ocspS3TarInspector.scanStartHandler)\n'
'    .get("/ocspS3TarScanStatus", ocspS3TarInspector.scanStatusHandler)\n'
'    .post("/ocspS3TarSearch", ocspS3TarInspector.searchHandler)\n'
'    .post("/ocspS3TarExtractStart", ocspS3TarInspector.extractStartHandler)\n'
'    .get("/ocspS3TarExtractStatus", ocspS3TarInspector.extractStatusHandler)\n'
'    .get("/ocspS3TarDownload", ocspS3TarInspector.downloadHandler)\n'
)
t=t.replace(anchor, anchor+routes, 1)
dst.write_text(t,encoding='utf-8')
PY1

  python3 - "$restore_in" "$restore_out" <<'PY2'
from pathlib import Path
import sys
src,dst=map(Path,sys.argv[1:3])
t=src.read_text(encoding='utf-8')
marker='OCSP v0.3.5.1 TAR browser init'
if marker in t: raise SystemExit('TAR browser restore.js marker already present')
old='''                    // OCSP v0.3.4.3 S3 restore picker\n                    if (window.OCSPS3Restore) window.OCSPS3Restore.init();\n                    $sourceFileSelector.show();'''
new='''                    // OCSP v0.3.4.3 S3 restore picker\n                    if (window.OCSPS3Restore) window.OCSPS3Restore.init();\n                    // OCSP v0.3.5.1 TAR browser init\n                    if (window.OCSPS3TarBrowser) window.OCSPS3TarBrowser.init();\n                    $sourceFileSelector.show();'''
if t.count(old)!=1: raise SystemExit('restore picker init anchor mismatch')
t=t.replace(old,new,1)
dst.write_text(t,encoding='utf-8')
PY2

  docker cp "$controller_out" "$CP:/tmp/ocsp-controller-v0351.js" >/dev/null
  docker cp "$restore_out" "$CP:/tmp/ocsp-restore-v0351.js" >/dev/null
  docker exec "$CP" node --check /tmp/ocsp-controller-v0351.js >/dev/null || die "patched controller syntax check failed"
  docker exec "$CP" node --check /tmp/ocsp-restore-v0351.js >/dev/null || die "patched restore.js syntax check failed"
  docker exec "$CP" rm -f /tmp/ocsp-controller-v0351.js /tmp/ocsp-restore-v0351.js

  meta="$(docker exec "$CP" stat -c '%u:%g:%a' "$BACKUP_CONTROLLER")"
  docker cp "$controller_out" "$CP:$BACKUP_CONTROLLER" >/dev/null
  restore_meta "$BACKUP_CONTROLLER" "$meta"

  meta="$(docker exec "$CP" stat -c '%u:%g:%a' "$RESTORE_JS")"
  docker cp "$restore_out" "$CP:$RESTORE_JS" >/dev/null
  restore_meta "$RESTORE_JS" "$meta"

  meta="$(docker exec "$CP" stat -c '%u:%g:%a' "$BACKUP_CONTROLLER")"
  docker cp "$INSPECTOR_SOURCE" "$CP:$INSPECTOR" >/dev/null
  restore_meta "$INSPECTOR" "$meta"

  meta="$(docker exec "$CP" stat -c '%u:%g:%a' "$RESTORE_JS")"
  docker cp "$BROWSER_SOURCE" "$CP:$BROWSER" >/dev/null
  restore_meta "$BROWSER" "$meta"

  docker exec "$CP" grep -Fq 'OCSP v0.3.5.1 streaming TAR inspector routes' "$BACKUP_CONTROLLER" || die "controller TAR marker missing"
  docker exec "$CP" grep -Fq 'ocspS3TarScanStart' "$BACKUP_CONTROLLER" || die "scan route missing"
  docker exec "$CP" grep -Fq 'ocspS3TarDownload' "$BACKUP_CONTROLLER" || die "download route missing"
  docker exec "$CP" grep -Fq 'OCSP v0.3.5.1 TAR browser init' "$RESTORE_JS" || die "restore TAR init marker missing"
  docker exec "$CP" node --check "$INSPECTOR" >/dev/null || die "deployed TAR inspector syntax failure"
  docker exec "$CP" node --check "$BROWSER" >/dev/null || die "deployed TAR browser syntax failure"

  say "Rebuilding Control Panel production bundle..."
  docker exec "$CP" rm -f "$bundle"
  docker restart "$CP" >/dev/null
  wait_cp

  for i in $(seq 1 120); do
    if docker exec "$CP" test -f "$bundle" >/dev/null 2>&1 \
       && docker exec "$CP" grep -aFq 'Inspect backup archive / recover one file' "$bundle" >/dev/null 2>&1 \
       && docker exec "$CP" grep -aFq 'Inspect selected backup' "$bundle" >/dev/null 2>&1 \
       && docker exec "$CP" grep -aFq 'Search scanned entries' "$bundle" >/dev/null 2>&1; then
      ready=1; break
    fi
    sleep 1
  done
  [ "$ready" = 1 ] || die "production bundle never reached v0.3.5.1 TAR-browser state"
  newsha="$(docker exec "$CP" sha256sum "$bundle" | awk '{print $1}')"

  cat >"$STATE_FILE" <<STATE
VERSION=0.3.5.1-tar-inspector
BACKUP=$backup
BUNDLE=$bundle
INSTALLED_UTC=$stamp
OLD_BUNDLE_SHA256=$oldsha
NEW_BUNDLE_SHA256=$newsha
STATE
  chmod 600 "$STATE_FILE"

  say "Control Panel bundle SHA256: $oldsha -> $newsha"
  say
  say "PASS — v0.3.5.1 streaming TAR inspector installed."
  say "  Restore can stream-scan a selected S3 .tar.gz without staging the full archive locally."
  say "  Scanned file entries can be searched and one selected file can be recovered to a temporary file and downloaded once."
  say "  A gzip archive is sequential: scan/recovery may need to read from the beginning of the 391 GiB object."
  say "  No portal restore, storage migration, backup, schedule, archive delete or S3 write is started by this installer."
}

status_cmd(){
  need docker
  [ -f "$STATE_FILE" ] || die "v0.3.5.1 TAR inspector state absent"
  local bundle
  bundle="$(sed -n 's/^BUNDLE=//p' "$STATE_FILE" | head -1)"
  docker exec "$CP" grep -Fq 'OCSP v0.3.5.1 streaming TAR inspector routes' "$BACKUP_CONTROLLER" || die "TAR controller marker missing"
  docker exec "$CP" grep -Fq 'OCSP v0.3.5.1 TAR browser init' "$RESTORE_JS" || die "TAR restore marker missing"
  docker exec "$CP" node --check "$INSPECTOR" >/dev/null || die "TAR inspector syntax failure"
  docker exec "$CP" node --check "$BROWSER" >/dev/null || die "TAR browser syntax failure"
  docker exec "$CP" grep -aFq 'Inspect backup archive / recover one file' "$bundle" || die "TAR browser bundle marker missing"
  say "PASS — v0.3.5.1 streaming TAR inspector present."
}

rollback_cmd(){
  need docker
  [ -f "$STATE_FILE" ] || die "v0.3.5.1 TAR inspector state absent"
  local backup bundle meta
  backup="$(sed -n 's/^BACKUP=//p' "$STATE_FILE" | head -1)"
  bundle="$(sed -n 's/^BUNDLE=//p' "$STATE_FILE" | head -1)"
  [ -f "$backup/backup-controller.js" ] || die "controller rollback file missing"
  [ -f "$backup/restore.js" ] || die "restore.js rollback file missing"
  [ -f "$backup/$(basename "$bundle")" ] || die "bundle rollback file missing"

  meta="$(docker exec "$CP" stat -c '%u:%g:%a' "$BACKUP_CONTROLLER")"
  docker cp "$backup/backup-controller.js" "$CP:$BACKUP_CONTROLLER" >/dev/null
  restore_meta "$BACKUP_CONTROLLER" "$meta"
  meta="$(docker exec "$CP" stat -c '%u:%g:%a' "$RESTORE_JS")"
  docker cp "$backup/restore.js" "$CP:$RESTORE_JS" >/dev/null
  restore_meta "$RESTORE_JS" "$meta"
  docker exec "$CP" rm -f "$INSPECTOR" "$BROWSER"
  docker cp "$backup/$(basename "$bundle")" "$CP:$bundle" >/dev/null
  rm -f "$STATE_FILE"
  docker restart "$CP" >/dev/null
  wait_cp
  say "PASS — v0.3.5.1 TAR inspector rolled back."
}

case "${1:-status}" in
  install) install_cmd ;;
  status) status_cmd ;;
  rollback) rollback_cmd ;;
  *) die "usage: $0 {install|status|rollback}" ;;
esac
