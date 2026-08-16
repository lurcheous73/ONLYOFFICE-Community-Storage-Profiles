#!/usr/bin/env bash
set -euo pipefail

# OCSP v0.3.4.4 — scheduled S3-compatible bucket picker / validation gate.
# Reuses the already-installed read/write S3 probe routes from v0.3.4 and
# applies the manual-backup bucket workflow to Automatic Backup.
# No schedule is created/changed by this installer and no backup is started.

CP="${OCSP_CONTROL_PANEL_CONTAINER:-onlyoffice-control-panel}"
EXPECTED_CP_IMAGE="onlyoffice/controlpanel:3.5.5.549"
ROOT="/var/www/onlyoffice/controlpanel/www"
BACKUP_JS="$ROOT/public/javascripts/views/backup.js"
MANUAL_UI="$ROOT/public/javascripts/views/ocsp-manual-s3-backup.js"
SCHEDULE_UI="$ROOT/public/javascripts/views/ocsp-s3-schedule.js"

STATE_DIR="/var/lib/onlyoffice-community-storage-profiles"
BACKUP_ROOT="/var/backups/onlyoffice-community-storage-profiles"
V0342_STATE="$STATE_DIR/storage-profiles-v0.3.4.2-fetch-buckets.state"
V0343_STATE="$STATE_DIR/storage-profiles-v0.3.4.3-restore-picker.state"
STATE_FILE="$STATE_DIR/storage-profiles-v0.3.4.4-scheduled-buckets.state"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
SOURCE="$REPO_ROOT/patches/v0.3.4/controlpanel-s3-schedule.js"

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
  [ -f "$V0343_STATE" ] || die "v0.3.4.3 restore-picker state missing"
  [ ! -f "$STATE_FILE" ] || die "v0.3.4.4 already installed; use status or rollback"
  [ -f "$SOURCE" ] || die "missing source: $SOURCE"

  docker inspect "$CP" >/dev/null 2>&1 || die "container not found: $CP"
  [ "$(docker inspect -f '{{.Config.Image}}' "$CP")" = "$EXPECTED_CP_IMAGE" ] \
    || die "unsupported Control Panel image: $(docker inspect -f '{{.Config.Image}}' "$CP")"

  docker exec "$CP" test -f "$BACKUP_JS" || die "backup.js missing"
  docker exec "$CP" test -f "$MANUAL_UI" || die "manual S3 backup helper missing"
  docker exec "$CP" test ! -e "$SCHEDULE_UI" || die "unexpected pre-existing $SCHEDULE_UI"
  docker exec "$CP" grep -Fq 'OCSP v0.3.4 manual S3 backup gate' "$BACKUP_JS" \
    || die "v0.3.4 manual backup gate marker missing"
  docker exec "$CP" grep -Fq 'function saveSchedule() {' "$BACKUP_JS" \
    || die "saveSchedule baseline missing"

  docker cp "$SOURCE" "$CP:/tmp/ocsp-s3-schedule-v0344.js" >/dev/null
  docker exec "$CP" node --check /tmp/ocsp-s3-schedule-v0344.js >/dev/null \
    || die "scheduled bucket helper syntax check failed"
  docker exec "$CP" rm -f /tmp/ocsp-s3-schedule-v0344.js
}

install_cmd(){
  preflight
  TMP="$(mktemp -d)"

  local bundle stamp backup oldsha newsha ready=0 meta uid gid mode rest
  local backup_in="$TMP/backup.in" backup_out="$TMP/backup.out"

  bundle="$(bundle_path)"
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  backup="$BACKUP_ROOT/v0.3.4.4-scheduled-buckets-$stamp"
  mkdir -p "$backup" "$STATE_DIR"
  chmod 700 "$backup" "$STATE_DIR"

  say "Backing up current Automatic Backup UI and production bundle to: $backup"
  docker cp "$CP:$BACKUP_JS" "$backup/backup.js" >/dev/null
  docker cp "$CP:$bundle" "$backup/$(basename "$bundle")" >/dev/null
  chmod 600 "$backup/backup.js" "$backup/$(basename "$bundle")"
  oldsha="$(docker exec "$CP" sha256sum "$bundle" | awk '{print $1}')"

  docker cp "$CP:$BACKUP_JS" "$backup_in" >/dev/null
  python3 - "$backup_in" "$backup_out" <<'PY'
from pathlib import Path
import sys
src,dst=map(Path,sys.argv[1:3])
t=src.read_text(encoding='utf-8')
marker='OCSP v0.3.4.4 scheduled S3 bucket gate'
if marker in t:
    raise SystemExit('v0.3.4.4 backup.js marker already present')

old='''                    if (window.OCSPManualS3Backup) window.OCSPManualS3Backup.init();'''
new='''                    if (window.OCSPManualS3Backup) window.OCSPManualS3Backup.init();
                    // OCSP v0.3.4.4 scheduled S3 bucket gate
                    if (window.OCSPS3Schedule) window.OCSPS3Schedule.init();'''
if t.count(old) != 1:
    raise SystemExit('manual backup init hook count = %d' % t.count(old))
t=t.replace(old,new,1)

sync='''        if (window.OCSPManualS3Backup) window.OCSPManualS3Backup.sync();'''
count=t.count(sync)
if count != 2:
    raise SystemExit('manual backup sync hook count = %d, expected 2' % count)
t=t.replace(sync, sync + '''
        if (window.OCSPS3Schedule) window.OCSPS3Schedule.sync();''')

old='''    function saveSchedule() {
        $scheduleBox.find('.withError').removeClass(withErrorClass);'''
new='''    function saveSchedule() {
        if (window.OCSPS3Schedule && !window.OCSPS3Schedule.canSave()) {
            window.OCSPS3Schedule.warn();
            return;
        }
        $scheduleBox.find('.withError').removeClass(withErrorClass);'''
if t.count(old) != 1:
    raise SystemExit('saveSchedule gate anchor count = %d' % t.count(old))
t=t.replace(old,new,1)

dst.write_text(t,encoding='utf-8')
PY

  docker cp "$backup_out" "$CP:/tmp/ocsp-backup-v0344.js" >/dev/null
  docker exec "$CP" node --check /tmp/ocsp-backup-v0344.js >/dev/null \
    || die "patched backup.js syntax check failed"
  docker exec "$CP" rm -f /tmp/ocsp-backup-v0344.js

  meta="$(docker exec "$CP" stat -c '%u:%g:%a' "$BACKUP_JS")"
  uid="${meta%%:*}"; rest="${meta#*:}"; gid="${rest%%:*}"; mode="${rest##*:}"
  docker cp "$backup_out" "$CP:$BACKUP_JS" >/dev/null
  docker exec "$CP" chown "$uid:$gid" "$BACKUP_JS"
  docker exec "$CP" chmod "$mode" "$BACKUP_JS"

  copy_with_meta "$SOURCE" "$SCHEDULE_UI" "$MANUAL_UI"

  docker exec "$CP" grep -Fq 'OCSP v0.3.4.4 scheduled S3 bucket gate' "$BACKUP_JS" \
    || die "scheduled bucket gate marker missing after deploy"
  docker exec "$CP" grep -Fq 'OCSP v0.3.4.4' "$SCHEDULE_UI" \
    || die "scheduled helper marker missing after deploy"
  docker exec "$CP" grep -Fq 'Validate bucket (100 KiB)' "$SCHEDULE_UI" \
    || die "scheduled validation UI marker missing"

  say "Rebuilding Control Panel production bundle..."
  docker exec "$CP" rm -f "$bundle"
  docker restart "$CP" >/dev/null
  wait_cp

  for i in $(seq 1 120); do
    if docker exec "$CP" test -f "$bundle" >/dev/null 2>&1 \
       && docker exec "$CP" grep -aFq 'ocsp-s3-schedule-tools' "$bundle" >/dev/null 2>&1 \
       && docker exec "$CP" grep -aFq 'Save is unlocked.' "$bundle" >/dev/null 2>&1 \
       && docker exec "$CP" grep -aFq 'before saving this backup schedule.' "$bundle" >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 1
  done
  [ "$ready" = 1 ] || die "production bundle never reached v0.3.4.4 scheduled-bucket state"

  newsha="$(docker exec "$CP" sha256sum "$bundle" | awk '{print $1}')"

  cat >"$STATE_FILE" <<STATE
VERSION=0.3.4.4-scheduled-buckets
BACKUP=$backup
BUNDLE=$bundle
INSTALLED_UTC=$stamp
OLD_BUNDLE_SHA256=$oldsha
NEW_BUNDLE_SHA256=$newsha
STATE
  chmod 600 "$STATE_FILE"

  say "Control Panel bundle SHA256: $oldsha -> $newsha"
  say
  say "PASS — v0.3.4.4 Automatic Backup S3 bucket picker installed."
  say "  Scheduled S3Compatible backup now reuses saved Third-Party Services credentials."
  say "  It can fetch/select/refresh/create buckets and run the same disposable 100 KiB validation as manual backup."
  say "  Save Settings is gated until the chosen bucket has passed validation."
  say "  Internal backupchunksize/checksum compatibility fields are hidden on Automatic Backup."
  say "  No backup, restore, schedule, migration, delete or S3 operation was started by this installer."
}

status_cmd(){
  need docker
  [ -f "$STATE_FILE" ] || die "v0.3.4.4 state absent"
  local bundle
  bundle="$(sed -n 's/^BUNDLE=//p' "$STATE_FILE" | head -1)"
  docker exec "$CP" grep -Fq 'OCSP v0.3.4.4 scheduled S3 bucket gate' "$BACKUP_JS" || die "backup.js gate missing"
  docker exec "$CP" node --check "$SCHEDULE_UI" >/dev/null || die "scheduled helper syntax failure"
  docker exec "$CP" grep -aFq 'ocsp-s3-schedule-tools' "$bundle" || die "bundle scheduled picker marker missing"
  docker exec "$CP" grep -aFq 'Save is unlocked.' "$bundle" || die "bundle validation marker missing"
  say "PASS — v0.3.4.4 Automatic Backup S3 bucket picker present."
}

rollback_cmd(){
  need docker
  [ -f "$STATE_FILE" ] || die "v0.3.4.4 state absent"
  local backup bundle meta uid gid mode rest
  backup="$(sed -n 's/^BACKUP=//p' "$STATE_FILE" | head -1)"
  bundle="$(sed -n 's/^BUNDLE=//p' "$STATE_FILE" | head -1)"
  [ -f "$backup/backup.js" ] || die "backup.js rollback file missing"
  [ -f "$backup/$(basename "$bundle")" ] || die "bundle rollback file missing"

  meta="$(docker exec "$CP" stat -c '%u:%g:%a' "$BACKUP_JS")"
  uid="${meta%%:*}"; rest="${meta#*:}"; gid="${rest%%:*}"; mode="${rest##*:}"
  docker cp "$backup/backup.js" "$CP:$BACKUP_JS" >/dev/null
  docker exec "$CP" chown "$uid:$gid" "$BACKUP_JS"
  docker exec "$CP" chmod "$mode" "$BACKUP_JS"
  docker exec "$CP" rm -f "$SCHEDULE_UI"
  docker cp "$backup/$(basename "$bundle")" "$CP:$bundle" >/dev/null
  rm -f "$STATE_FILE"
  docker restart "$CP" >/dev/null
  wait_cp
  say "PASS — v0.3.4.4 rolled back to the exact pre-scheduled-picker Control Panel state."
}

case "${1:-status}" in
  install) install_cmd ;;
  status) status_cmd ;;
  rollback) rollback_cmd ;;
  *) die "usage: $0 {install|status|rollback}" ;;
esac
