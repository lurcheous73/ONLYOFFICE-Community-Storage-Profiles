#!/usr/bin/env bash
set -euo pipefail

# OCSP v0.3.5 — S3-compatible bucket picker for Connect storage for static data.
# This adds discovery/create/validation UI and gates CONNECT until validation.
# It never invokes updateStorage, CDN, migration, backup, restore or schedule APIs.

CP="${OCSP_CONTROL_PANEL_CONTAINER:-onlyoffice-control-panel}"
EXPECTED_CP_IMAGE="onlyoffice/controlpanel:3.5.5.549"
ROOT="/var/www/onlyoffice/controlpanel/www"
STORAGE_JS="$ROOT/public/javascripts/views/storage.js"
STATIC_UI="$ROOT/public/javascripts/views/ocsp-static-s3-storage.js"
BACKUP_CONTROLLER="$ROOT/app/controllers/backup.js"
EXISTING_PROBE="$ROOT/app/ocsp/s3Probe.js"

STATE_DIR="/var/lib/onlyoffice-community-storage-profiles"
BACKUP_ROOT="/var/backups/onlyoffice-community-storage-profiles"
V034_STATE="$STATE_DIR/storage-profiles-v0.3.4-manual-backup.state"
STATE_FILE="$STATE_DIR/storage-profiles-v0.3.5-static-storage-buckets.state"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
UI_SOURCE="$REPO_ROOT/patches/v0.3.5/controlpanel-static-s3-storage.js"
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
  [ -f "$V034_STATE" ] || die "v0.3.4 manual-backup state missing"
  [ ! -f "$STATE_FILE" ] || die "v0.3.5 static-storage bucket picker already installed; use status or rollback"
  [ -f "$UI_SOURCE" ] || die "missing source: $UI_SOURCE"

  docker inspect "$CP" >/dev/null 2>&1 || die "container not found: $CP"
  [ "$(docker inspect -f '{{.Config.Image}}' "$CP")" = "$EXPECTED_CP_IMAGE" ] \
    || die "unsupported Control Panel image: $(docker inspect -f '{{.Config.Image}}' "$CP")"
  docker exec "$CP" test -f "$STORAGE_JS" || die "storage.js missing"
  docker exec "$CP" test -f "$EXISTING_PROBE" || die "v0.3.4 S3 probe missing"
  docker exec "$CP" test -f "$BACKUP_CONTROLLER" || die "backup controller missing"
  docker exec "$CP" grep -Fq 'ocspS3ListBuckets' "$BACKUP_CONTROLLER" || die "S3 bucket-list route missing"
  docker exec "$CP" grep -Fq 'ocspS3CreateBucket' "$BACKUP_CONTROLLER" || die "S3 bucket-create route missing"
  docker exec "$CP" grep -Fq 'ocspS3ValidateBucket' "$BACKUP_CONTROLLER" || die "S3 bucket-validation route missing"
  docker exec "$CP" grep -Fq 'function connectWithStorage() {' "$STORAGE_JS" || die "unexpected storage.js baseline"
  docker exec "$CP" test ! -e "$STATIC_UI" || die "unexpected pre-existing $STATIC_UI"

  docker cp "$UI_SOURCE" "$CP:/tmp/ocsp-static-s3-storage-v035.js" >/dev/null
  docker exec "$CP" node --check /tmp/ocsp-static-s3-storage-v035.js >/dev/null || die "static-storage helper syntax check failed"
  docker exec "$CP" rm -f /tmp/ocsp-static-s3-storage-v035.js
}

install_cmd(){
  preflight
  TMP="$(mktemp -d)"

  local bundle stamp backup oldsha newsha meta ready=0
  local in="$TMP/storage.in" out="$TMP/storage.out"
  bundle="$(bundle_path)"
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  backup="$BACKUP_ROOT/v0.3.5-static-storage-buckets-$stamp"
  mkdir -p "$backup" "$STATE_DIR"; chmod 700 "$backup" "$STATE_DIR"

  say "Backing up Storage UI and production bundle to: $backup"
  docker cp "$CP:$STORAGE_JS" "$backup/storage.js" >/dev/null
  docker cp "$CP:$bundle" "$backup/$(basename "$bundle")" >/dev/null
  chmod 600 "$backup/storage.js" "$backup/$(basename "$bundle")"
  oldsha="$(docker exec "$CP" sha256sum "$bundle" | awk '{print $1}')"

  docker cp "$CP:$STORAGE_JS" "$in" >/dev/null
  python3 - "$in" "$out" <<'PY'
from pathlib import Path
import sys
src,dst=map(Path,sys.argv[1:3])
t=src.read_text(encoding='utf-8')
marker='OCSP v0.3.5 static S3 bucket gate'
if marker in t: raise SystemExit('v0.3.5 storage marker already present')

old='''                    bindEvents();\n                    initStorageType($storageSettingsBox);\n                    initStorageType($CDNSettingsBox);\n                    initEncryptionForm(res[2]);'''
new='''                    bindEvents();\n                    initStorageType($storageSettingsBox);\n                    initStorageType($CDNSettingsBox);\n                    // OCSP v0.3.5 static S3 bucket gate\n                    if (window.OCSPStaticS3Storage) window.OCSPStaticS3Storage.init();\n                    initEncryptionForm(res[2]);'''
if t.count(old)!=1: raise SystemExit('Storage init anchor mismatch')
t=t.replace(old,new,1)

old='''        if (finded.id === newVal && finded.isChange === false) {\n            currentConnectBtn.addClass(disabledClass);\n        } else {\n            currentConnectBtn.removeClass(disabledClass);\n        }\n\n    }\n\n    function initStorageType($box) {'''
new='''        if (finded.id === newVal && finded.isChange === false) {\n            currentConnectBtn.addClass(disabledClass);\n        } else {\n            currentConnectBtn.removeClass(disabledClass);\n        }\n        if (window.OCSPStaticS3Storage) window.OCSPStaticS3Storage.sync();\n\n    }\n\n    function initStorageType($box) {'''
if t.count(old)!=1: raise SystemExit('selectStorage sync anchor mismatch')
t=t.replace(old,new,1)

old='''    function connectWithStorage() {\n        var $box = $(this).closest('.selectTypeStorageBox');'''
new='''    function connectWithStorage() {\n        if ($(this).is($storageButton) && window.OCSPStaticS3Storage && !window.OCSPStaticS3Storage.canConnect()) {\n            window.OCSPStaticS3Storage.warn();\n            return;\n        }\n        var $box = $(this).closest('.selectTypeStorageBox');'''
if t.count(old)!=1: raise SystemExit('connectWithStorage gate anchor mismatch')
t=t.replace(old,new,1)

dst.write_text(t,encoding='utf-8')
PY

  docker cp "$out" "$CP:/tmp/ocsp-storage-v035.js" >/dev/null
  docker exec "$CP" node --check /tmp/ocsp-storage-v035.js >/dev/null || die "patched storage.js syntax check failed"
  docker exec "$CP" rm -f /tmp/ocsp-storage-v035.js

  meta="$(docker exec "$CP" stat -c '%u:%g:%a' "$STORAGE_JS")"
  docker cp "$out" "$CP:$STORAGE_JS" >/dev/null
  restore_meta "$STORAGE_JS" "$meta"

  meta="$(docker exec "$CP" stat -c '%u:%g:%a' "$STORAGE_JS")"
  docker cp "$UI_SOURCE" "$CP:$STATIC_UI" >/dev/null
  restore_meta "$STATIC_UI" "$meta"

  docker exec "$CP" grep -Fq 'OCSP v0.3.5 static S3 bucket gate' "$STORAGE_JS" || die "storage marker missing after deploy"
  docker exec "$CP" grep -Fq 'Check connection & fetch buckets' "$STATIC_UI" || die "static bucket helper marker missing after deploy"

  say "Rebuilding Control Panel production bundle..."
  docker exec "$CP" rm -f "$bundle"
  docker restart "$CP" >/dev/null
  wait_cp

  for i in $(seq 1 120); do
    if docker exec "$CP" test -f "$bundle" >/dev/null 2>&1 \
       && docker exec "$CP" grep -aFq 'CONNECT can migrate portal static data' "$bundle" >/dev/null 2>&1 \
       && docker exec "$CP" grep -aFq 'validate the selected bucket before CONNECT' "$bundle" >/dev/null 2>&1; then
      ready=1; break
    fi
    sleep 1
  done
  [ "$ready" = 1 ] || die "production bundle never reached v0.3.5 static-storage state"
  newsha="$(docker exec "$CP" sha256sum "$bundle" | awk '{print $1}')"

  cat >"$STATE_FILE" <<STATE
VERSION=0.3.5-static-storage-buckets
BACKUP=$backup
BUNDLE=$bundle
INSTALLED_UTC=$stamp
OLD_BUNDLE_SHA256=$oldsha
NEW_BUNDLE_SHA256=$newsha
STATE
  chmod 600 "$STATE_FILE"

  say "Control Panel bundle SHA256: $oldsha -> $newsha"
  say
  say "PASS — v0.3.5 static-storage S3 bucket picker installed."
  say "  Connect storage for static data can fetch/create/select/validate S3Compatible buckets."
  say "  CONNECT remains gated until the selected bucket passes 100 KiB validation."
  say "  Internal backupchunksize/checksum compatibility fields are hidden."
  say "  No storage migration, CDN change, backup, restore, schedule or S3 write beyond explicit validation/create actions is started by the installer."
}

status_cmd(){
  need docker
  [ -f "$STATE_FILE" ] || die "v0.3.5 static-storage state absent"
  local bundle
  bundle="$(sed -n 's/^BUNDLE=//p' "$STATE_FILE" | head -1)"
  docker exec "$CP" grep -Fq 'OCSP v0.3.5 static S3 bucket gate' "$STORAGE_JS" || die "storage gate marker missing"
  docker exec "$CP" node --check "$STATIC_UI" >/dev/null || die "static helper syntax failure"
  docker exec "$CP" grep -aFq 'CONNECT can migrate portal static data' "$bundle" || die "bundle static picker string missing"
  say "PASS — v0.3.5 static-storage S3 bucket picker present."
}

rollback_cmd(){
  need docker
  [ -f "$STATE_FILE" ] || die "v0.3.5 static-storage state absent"
  local backup bundle meta
  backup="$(sed -n 's/^BACKUP=//p' "$STATE_FILE" | head -1)"
  bundle="$(sed -n 's/^BUNDLE=//p' "$STATE_FILE" | head -1)"
  [ -f "$backup/storage.js" ] || die "storage.js rollback file missing"
  [ -f "$backup/$(basename "$bundle")" ] || die "bundle rollback file missing"

  meta="$(docker exec "$CP" stat -c '%u:%g:%a' "$STORAGE_JS")"
  docker cp "$backup/storage.js" "$CP:$STORAGE_JS" >/dev/null
  restore_meta "$STORAGE_JS" "$meta"
  docker exec "$CP" rm -f "$STATIC_UI"
  docker cp "$backup/$(basename "$bundle")" "$CP:$bundle" >/dev/null
  rm -f "$STATE_FILE"
  docker restart "$CP" >/dev/null
  wait_cp
  say "PASS — v0.3.5 static-storage bucket picker rolled back."
}

case "${1:-status}" in
  install) install_cmd ;;
  status) status_cmd ;;
  rollback) rollback_cmd ;;
  *) die "usage: $0 {install|status|rollback}" ;;
esac
