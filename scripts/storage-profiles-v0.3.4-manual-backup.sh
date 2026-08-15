#!/usr/bin/env bash
set -euo pipefail

# ONLYOFFICE Community Storage Profiles — v0.3.4
# Manual S3-compatible backup hardening.
#
# Manual backup only. This release deliberately does NOT create/modify a
# backup schedule, cron entry, primary-storage migration, or restore job.
#
# Operations: install | status | rollback

COMM="${OCSP_COMMUNITY_CONTAINER:-onlyoffice-community-server}"
CP="${OCSP_CONTROL_PANEL_CONTAINER:-onlyoffice-control-panel}"
EXPECTED_COMM_IMAGE="onlyoffice/communityserver:12.8.0.1971"
EXPECTED_CP_IMAGE="onlyoffice/controlpanel:3.5.5.549"
UPSTREAM_COMMIT="fe1fa7babd093969e939ba6ff45a9fee1299dc93"
UPSTREAM_SOURCE_URL="https://raw.githubusercontent.com/ONLYOFFICE/CommunityServer/${UPSTREAM_COMMIT}/common/ASC.Data.Storage/S3/S3Storage.cs"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
PATCH_DIR="$REPO_ROOT/patches/v0.3.4"
TRANSFORMER="$PATCH_DIR/build-s3compatible.py"
WRITER_SOURCE="$PATCH_DIR/S3CompatibleZipWriteOperator.cs"
CP_PROBE_SOURCE="$PATCH_DIR/controlpanel-s3-probe.js"
CP_UI_SOURCE="$PATCH_DIR/controlpanel-manual-s3-backup.js"

STATE_DIR="/var/lib/onlyoffice-community-storage-profiles"
BACKUP_ROOT="/var/backups/onlyoffice-community-storage-profiles"
V032_STATE="$STATE_DIR/storage-profiles-v0.3.2.state"
V033_STATE="$STATE_DIR/storage-profiles-v0.3.3-ui.state"
STATE_FILE="$STATE_DIR/storage-profiles-v0.3.4-manual-backup.state"
MANIFEST="manifest.tsv"

PART_SIZE=201326592
MAX_PARTS=10000
CUSTOM_ASSEMBLY="ASC.Data.Storage.S3Compatible.dll"
CUSTOM_TYPE="ASC.Data.Storage.S3Compatible.S3CompatibleStorage"
CUSTOM_WRITER_TYPE="ASC.Data.Storage.S3Compatible.S3CompatibleZipWriteOperator"
CUSTOM_HANDLER="${CUSTOM_TYPE}, ASC.Data.Storage.S3Compatible"

CP_ROOT="/var/www/onlyoffice/controlpanel/www"
CP_BACKUP_CONTROLLER="$CP_ROOT/app/controllers/backup.js"
CP_PROBE="$CP_ROOT/app/ocsp/s3Probe.js"
CP_BACKUP_JS="$CP_ROOT/public/javascripts/views/backup.js"
CP_UI="$CP_ROOT/public/javascripts/views/ocsp-manual-s3-backup.js"

ROOTS=(WebStudio WebStudio2 WebStudio3 WebStudio4)
TMP=""
INSTALL_BACKUP=""

say(){ printf '%s\n' "$*"; }
die(){ say "ERROR: $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }
container_image(){ docker inspect -f '{{.Config.Image}}' "$1"; }
meta_in(){ docker exec "$1" stat -c '%u:%g:%a' "$2"; }

cleanup(){ [ -n "${TMP:-}" ] && [ -d "$TMP" ] && rm -rf -- "$TMP" || true; }
trap cleanup EXIT

banner(){
cat <<'EOF'
====================================================================
 ONLYOFFICE Community Storage Profiles — v0.3.4
 Manual S3-compatible backup hardening
====================================================================
EOF
}

wait_container(){
  local c="$1" i
  for i in $(seq 1 90); do
    if [ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null || true)" = true ] \
       && docker exec "$c" true >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  die "$c did not return to running state"
}

restore_meta(){
  local c="$1" p="$2" m="$3" uid gid mode rest
  uid="${m%%:*}"; rest="${m#*:}"; gid="${rest%%:*}"; mode="${rest##*:}"
  docker exec "$c" chown "$uid:$gid" "$p"
  docker exec "$c" chmod "$mode" "$p"
}

bundle_path(){
  local b
  mapfile -t b < <(docker exec "$CP" sh -lc "find '$CP_ROOT/public/javascripts' -maxdepth 1 -type f -name 'combined.*.js' -print | sort")
  [ "${#b[@]}" -eq 1 ] || die "expected exactly one production combined.*.js bundle; found ${#b[@]}"
  printf '%s\n' "${b[0]}"
}

community_configs(){
  local root p
  for root in "${ROOTS[@]}"; do
    p="/var/www/onlyoffice/$root/web.consumers.config"
    docker exec "$COMM" test -f "$p" >/dev/null 2>&1 && printf '%s\n' "$p"
  done
  p="/var/www/onlyoffice/Services/TeamLabSvc/web.consumers.config"
  docker exec "$COMM" test -f "$p" >/dev/null 2>&1 && printf '%s\n' "$p"
}

storage_bin_dirs(){
  docker exec "$COMM" sh -lc \
    "find /var/www/onlyoffice -type f -name ASC.Data.Storage.dll -printf '%h\\n' 2>/dev/null | sort -u"
}

backup_existing(){
  local backup="$1" c="$2" label="$3" path="$4" meta dst
  docker exec "$c" test -e "$path" || die "cannot back up missing $c:$path"
  meta="$(meta_in "$c" "$path")"
  dst="$backup/$label"
  mkdir -p "$(dirname "$dst")"
  docker cp "$c:$path" "$dst" >/dev/null
  chmod 600 "$dst"
  printf 'RESTORE\t%s\t%s\t%s\t%s\n' "$c" "$path" "$meta" "$label" >>"$backup/$MANIFEST"
}

record_created(){
  local backup="$1" c="$2" path="$3"
  printf 'DELETE\t%s\t%s\t-\t-\n' "$c" "$path" >>"$backup/$MANIFEST"
}

restore_manifest(){
  local backup="$1" action c path meta rel src
  [ -f "$backup/$MANIFEST" ] || return 0
  tac "$backup/$MANIFEST" | while IFS=$'\t' read -r action c path meta rel; do
    case "$action" in
      RESTORE)
        src="$backup/$rel"
        [ -f "$src" ] || continue
        docker exec "$c" mkdir -p "$(dirname "$path")"
        docker cp "$src" "$c:$path" >/dev/null
        restore_meta "$c" "$path" "$meta"
        ;;
      DELETE)
        docker exec "$c" rm -f -- "$path" >/dev/null 2>&1 || true
        ;;
    esac
  done
}

consumer_check(){
  local path="$1"
  docker exec "$COMM" python3 - "$path" "$CUSTOM_HANDLER" "$PART_SIZE" <<'PY'
import re,sys
p,handler,part=sys.argv[1:4]
text=open(p,encoding='utf-8').read()
m=re.search(r'<component\b(?=[^>]*\bname="S3Compatible")[^>]*>.*?</component>',text,re.S)
if not m: raise SystemExit(2)
block=m.group(0)
if handler not in block: raise SystemExit(3)
if 'key="disabledefaultchecksumvalidation"' not in block: raise SystemExit(4)
if not re.search(r'key="backupchunksize"\s+value="'+re.escape(part)+r'"',block): raise SystemExit(5)
PY
}

preflight(){
  need docker; need python3; need curl; need sha256sum; need awk
  [ -f "$TRANSFORMER" ] || die "missing $TRANSFORMER"
  [ -f "$WRITER_SOURCE" ] || die "missing $WRITER_SOURCE"
  [ -f "$CP_PROBE_SOURCE" ] || die "missing $CP_PROBE_SOURCE"
  [ -f "$CP_UI_SOURCE" ] || die "missing $CP_UI_SOURCE"

  docker inspect "$COMM" >/dev/null 2>&1 || die "container not found: $COMM"
  docker inspect "$CP" >/dev/null 2>&1 || die "container not found: $CP"
  [ "$(container_image "$COMM")" = "$EXPECTED_COMM_IMAGE" ] \
    || die "unsupported CommunityServer image: $(container_image "$COMM")"
  [ "$(container_image "$CP")" = "$EXPECTED_CP_IMAGE" ] \
    || die "unsupported Control Panel image: $(container_image "$CP")"

  [ -f "$V032_STATE" ] || die "v0.3.2 backend state missing"
  [ -f "$V033_STATE" ] || die "v0.3.3 shared UI state missing"
  [ ! -f "$STATE_FILE" ] || die "v0.3.4 already installed; use status or rollback"

  docker exec "$COMM" sh -lc 'command -v mcs >/dev/null' || die "mcs not found in CommunityServer"
  docker exec "$CP" sh -lc 'command -v node >/dev/null' || die "node not found in Control Panel"

  docker exec "$CP" grep -Fq 'OCSP v0.3.3 shared S3Compatible UI' \
    "$CP_ROOT/public/javascripts/views/consumersettings.js" \
    || die "v0.3.3 shared provider UI marker missing"

  docker exec "$CP" grep -Fq '.post("/start", baseController.post.bind(baseController, '\''portal/startbackup.json'\''))' \
    "$CP_BACKUP_CONTROLLER" || die "unexpected Control Panel backup controller baseline"
  docker exec "$CP" grep -Fq 'function startBackup() {' "$CP_BACKUP_JS" \
    || die "unexpected Control Panel backup.js baseline"
  docker exec "$CP" test ! -e "$CP_PROBE" || die "unexpected pre-existing $CP_PROBE"
  docker exec "$CP" test ! -e "$CP_UI" || die "unexpected pre-existing $CP_UI"

  mapfile -t CONFIGS < <(community_configs)
  mapfile -t BIN_DIRS < <(storage_bin_dirs)
  [ "${#CONFIGS[@]}" -ge 2 ] || die "could not discover consumer configs"
  [ "${#BIN_DIRS[@]}" -ge 2 ] || die "could not discover ASC.Data.Storage.dll deployment directories"

  local d
  for d in "${BIN_DIRS[@]}"; do
    docker exec "$COMM" test -f "$d/$CUSTOM_ASSEMBLY" \
      || die "v0.3.2 custom handler missing: $d/$CUSTOM_ASSEMBLY"
  done

  local refdir="/var/www/onlyoffice/WebStudio/bin" r
  for r in ASC.Data.Storage.dll ASC.Common.dll ASC.Core.Common.dll AWSSDK.Core.dll AWSSDK.S3.dll AWSSDK.CloudFront.dll Amazon.Extensions.S3.Encryption.dll ICSharpCode.SharpZipLib.dll; do
    docker exec "$COMM" test -f "$refdir/$r" || die "compile reference missing: $refdir/$r"
  done
}

compile_handler(){
  local storage_source="$1" writer_source="$2" out_host="$3"
  local build="/tmp/ocsp-v034-build"
  local refdir="/var/www/onlyoffice/WebStudio/bin"

  docker exec "$COMM" rm -rf "$build"
  docker exec "$COMM" mkdir -p "$build"
  docker cp "$storage_source" "$COMM:$build/S3CompatibleStorage.cs" >/dev/null
  docker cp "$writer_source" "$COMM:$build/S3CompatibleZipWriteOperator.cs" >/dev/null

  docker exec "$COMM" bash -lc "
set -e
cd '$build'
mcs -target:library -optimize+ -out:'$CUSTOM_ASSEMBLY' \\
  -lib:'$refdir' \\
  -r:ASC.Data.Storage.dll \\
  -r:ASC.Common.dll \\
  -r:ASC.Core.Common.dll \\
  -r:AWSSDK.Core.dll \\
  -r:AWSSDK.S3.dll \\
  -r:AWSSDK.CloudFront.dll \\
  -r:Amazon.Extensions.S3.Encryption.dll \\
  -r:ICSharpCode.SharpZipLib.dll \\
  -r:System.Configuration.dll \\
  -r:System.Runtime.Serialization.dll \\
  -r:System.ServiceModel.dll \\
  -r:System.Web.dll \\
  S3CompatibleStorage.cs S3CompatibleZipWriteOperator.cs
"

  docker cp "$COMM:$build/$CUSTOM_ASSEMBLY" "$out_host" >/dev/null
  chmod 600 "$out_host"
}

probe_handler(){
  local dll="$1" build="/tmp/ocsp-v034-probe"
  docker exec "$COMM" rm -rf "$build"
  docker exec "$COMM" mkdir -p "$build"
  docker exec "$COMM" bash -lc "cat >'$build/probe.cs' <<'CS'
using System;
using System.Reflection;
class Probe {
  static int Main(string[] args) {
    var a=Assembly.LoadFrom(args[0]);
    var h=a.GetType(\"$CUSTOM_TYPE\", false);
    var w=a.GetType(\"$CUSTOM_WRITER_TYPE\", false);
    if (h==null || w==null) { Console.Error.WriteLine(\"v0.3.4 types missing\"); return 2; }
    Console.WriteLine(h.FullName);
    Console.WriteLine(w.FullName);
    return 0;
  }
}
CS
mcs -out:'$build/probe.exe' '$build/probe.cs'
MONO_PATH=/var/www/onlyoffice/WebStudio/bin mono '$build/probe.exe' '$dll'
"
}

patch_configs(){
  local backup="$1" p n=0 in out meta label
  for p in "${CONFIGS[@]}"; do
    n=$((n+1)); label="comm-config-$n"
    backup_existing "$backup" "$COMM" "$label" "$p"
    in="$TMP/config-$n.in"; out="$TMP/config-$n.out"
    docker cp "$COMM:$p" "$in" >/dev/null
    python3 "$TRANSFORMER" consumer "$in" "$out" "$PART_SIZE"
    meta="$(meta_in "$COMM" "$p")"
    docker cp "$out" "$COMM:$p" >/dev/null
    restore_meta "$COMM" "$p" "$meta"
  done
}

patch_controlpanel(){
  local backup="$1" controller_in="$TMP/cp-backup-controller.in" controller_out="$TMP/cp-backup-controller.out"
  local backupjs_in="$TMP/cp-backup-js.in" backupjs_out="$TMP/cp-backup-js.out"
  local meta

  backup_existing "$backup" "$CP" "cp-backup-controller.js" "$CP_BACKUP_CONTROLLER"
  backup_existing "$backup" "$CP" "cp-backup.js" "$CP_BACKUP_JS"

  docker cp "$CP:$CP_BACKUP_CONTROLLER" "$controller_in" >/dev/null
  docker cp "$CP:$CP_BACKUP_JS" "$backupjs_in" >/dev/null

  python3 - "$controller_in" "$controller_out" <<'PY'
from pathlib import Path
import sys
src,dst=map(Path,sys.argv[1:3])
t=src.read_text(encoding='utf-8')
marker='OCSP v0.3.4 manual S3 validation routes'
if marker in t: raise SystemExit('controller marker already present')
anchor="    fullAccess = require('../middleware/fullAccess.js');\n"
if t.count(anchor)!=1: raise SystemExit('fullAccess anchor mismatch')
t=t.replace(anchor,anchor+"\n// "+marker+"\nconst ocspS3Probe = require('../ocsp/s3Probe.js');\n",1)
old='''    .post("/createSchedule", baseController.post.bind(baseController, 'portal/createbackupschedule.json'))\n    .post("/start", baseController.post.bind(baseController, 'portal/startbackup.json'))\n    .delete("/deleteSchedule", baseController.dlt.bind(baseController, 'portal/deletebackupschedule.json'));'''
new='''    .post("/createSchedule", baseController.post.bind(baseController, 'portal/createbackupschedule.json'))\n    .post("/start", baseController.post.bind(baseController, 'portal/startbackup.json'))\n    .post("/ocspS3ListBuckets", ocspS3Probe.listBucketsHandler)\n    .post("/ocspS3CreateBucket", ocspS3Probe.createBucketHandler)\n    .post("/ocspS3ValidateBucket", ocspS3Probe.validateBucketHandler)\n    .delete("/deleteSchedule", baseController.dlt.bind(baseController, 'portal/deletebackupschedule.json'));'''
if t.count(old)!=1: raise SystemExit('backup route anchor mismatch')
t=t.replace(old,new,1)
dst.write_text(t,encoding='utf-8')
PY

  python3 - "$backupjs_in" "$backupjs_out" <<'PY'
from pathlib import Path
import sys
src,dst=map(Path,sys.argv[1:3])
t=src.read_text(encoding='utf-8')
marker='OCSP v0.3.4 manual S3 backup gate'
if marker in t: raise SystemExit('backup.js marker already present')

old='''                    initConsumerStorages(thirdPartyJSON);\n                    $thirdStorageHelpers = $view.find('.helpCenterSwitcher');'''
new='''                    initConsumerStorages(thirdPartyJSON);\n                    // OCSP v0.3.4 manual S3 backup gate\n                    if (window.OCSPManualS3Backup) window.OCSPManualS3Backup.init();\n                    $thirdStorageHelpers = $view.find('.helpCenterSwitcher');'''
if t.count(old)!=1: raise SystemExit('initConsumerStorages hook mismatch')
t=t.replace(old,new,1)

old='''        $box.find("[data-id='" + newVal + "']").removeClass(displayNoneClass).addClass('flexTextBox');\n    }\n\n    function showStorageFolderPop() {'''
new='''        $box.find("[data-id='" + newVal + "']").removeClass(displayNoneClass).addClass('flexTextBox');\n        if (window.OCSPManualS3Backup) window.OCSPManualS3Backup.sync();\n    }\n\n    function showStorageFolderPop() {'''
if t.count(old)!=1: raise SystemExit('selectThirdParty hook mismatch')
t=t.replace(old,new,1)

old='''            case storageTypes.Local:\n                hideAll();\n                $localFileSelectorBox.removeClass(displayNoneClass);\n                break;\n        }\n    }\n\n    function startBackup() {'''
new='''            case storageTypes.Local:\n                hideAll();\n                $localFileSelectorBox.removeClass(displayNoneClass);\n                break;\n        }\n        if (window.OCSPManualS3Backup) window.OCSPManualS3Backup.sync();\n    }\n\n    function startBackup() {'''
if t.count(old)!=1: raise SystemExit('selectStorage hook mismatch')
t=t.replace(old,new,1)

old='''    function startBackup() {\n        if ($startBackupBtn.is('.disabled')) {\n            return;\n        }'''
new='''    function startBackup() {\n        if (window.OCSPManualS3Backup && !window.OCSPManualS3Backup.canStart()) {\n            window.OCSPManualS3Backup.warn();\n            return;\n        }\n        if ($startBackupBtn.is('.disabled')) {\n            return;\n        }'''
if t.count(old)!=1: raise SystemExit('startBackup gate anchor mismatch')
t=t.replace(old,new,1)

dst.write_text(t,encoding='utf-8')
PY

  docker exec "$CP" mkdir -p "$(dirname "$CP_PROBE")"
  record_created "$backup" "$CP" "$CP_PROBE"
  record_created "$backup" "$CP" "$CP_UI"

  docker cp "$CP_PROBE_SOURCE" "$CP:$CP_PROBE" >/dev/null
  docker cp "$CP_UI_SOURCE" "$CP:$CP_UI" >/dev/null
  docker exec "$CP" chown 0:0 "$CP_PROBE" "$CP_UI" >/dev/null 2>&1 || true
  docker exec "$CP" chmod 644 "$CP_PROBE" "$CP_UI"

  meta="$(meta_in "$CP" "$CP_BACKUP_CONTROLLER")"
  docker cp "$controller_out" "$CP:$CP_BACKUP_CONTROLLER" >/dev/null
  restore_meta "$CP" "$CP_BACKUP_CONTROLLER" "$meta"

  meta="$(meta_in "$CP" "$CP_BACKUP_JS")"
  docker cp "$backupjs_out" "$CP:$CP_BACKUP_JS" >/dev/null
  restore_meta "$CP" "$CP_BACKUP_JS" "$meta"

  docker exec "$CP" node --check "$CP_PROBE"
  docker exec "$CP" node --check "$CP_UI"
  docker exec "$CP" node --check "$CP_BACKUP_CONTROLLER"
  docker exec "$CP" node --check "$CP_BACKUP_JS"

  docker exec "$CP" node - "$CP_PROBE" <<'NODE'
const path=process.argv[2];
const p=require(path);
const b=p._test.parseBucketNames('<ListAllMyBucketsResult><Buckets><Bucket><Name>alpha</Name></Bucket><Bucket><Name>beta</Name></Bucket></Buckets></ListAllMyBucketsResult>');
if (b.length!==2 || b[0]!=='alpha' || b[1]!=='beta') process.exit(2);
if (p._test.validateBucketName('onlyoffice-test-bucket')!=='onlyoffice-test-bucket') process.exit(3);
console.log('PASS: Control Panel S3 helper offline parser/name self-test');
NODE
}

write_state(){
  local backup="$1" sha="$2" bundle="$3" stamp="$4"
  mkdir -p "$STATE_DIR"
  cat >"$STATE_FILE" <<EOF
VERSION=0.3.4-manual-backup
BACKUP=$backup
CUSTOM_SHA256=$sha
PART_SIZE=$PART_SIZE
MAX_PARTS=$MAX_PARTS
BUNDLE=$bundle
INSTALLED_UTC=$stamp
EOF
  chmod 600 "$STATE_FILE"
}

read_state(){ sed -n "s/^$1=//p" "$STATE_FILE" | head -1; }

install_cmd(){
  banner
  preflight
  TMP="$(mktemp -d /tmp/ocsp-v034.XXXXXX)"

  local stamp backup upstream patched built custom_sha d p meta bundle old_bundle_sha new_bundle_sha ready=0
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  backup="$BACKUP_ROOT/v0.3.4-manual-backup-$stamp"
  mkdir -p "$backup"; chmod 700 "$backup"; : >"$backup/$MANIFEST"
  INSTALL_BACKUP="$backup"

  bundle="$(bundle_path)"
  backup_existing "$backup" "$CP" "cp-production-bundle.js" "$bundle"

  upstream="$TMP/S3Storage.upstream.cs"
  patched="$TMP/S3CompatibleStorage.cs"
  built="$TMP/$CUSTOM_ASSEMBLY"

  say "Fetching exact ONLYOFFICE CommunityServer source $UPSTREAM_COMMIT..."
  curl -fsSL --retry 3 --connect-timeout 15 "$UPSTREAM_SOURCE_URL" -o "$upstream"
  grep -Fq 'public class S3Storage : BaseStorage' "$upstream" || die "unexpected upstream S3Storage.cs"

  say "Generating v0.3.4 S3Compatible handler source..."
  python3 "$TRANSFORMER" storage "$upstream" "$patched"

  say "Compiling hardened handler + 192 MiB backup writer..."
  compile_handler "$patched" "$WRITER_SOURCE" "$built"
  custom_sha="$(sha256sum "$built" | awk '{print $1}')"
  say "v0.3.4 custom handler SHA256: $custom_sha"

  say "Backing up and replacing only the custom S3Compatible assembly..."
  for d in "${BIN_DIRS[@]}"; do
    backup_existing "$backup" "$COMM" "custom-dll-$(printf '%s' "$d" | tr '/' '_')" "$d/$CUSTOM_ASSEMBLY"
    meta="$(meta_in "$COMM" "$d/$CUSTOM_ASSEMBLY")"
    docker cp "$built" "$COMM:$d/$CUSTOM_ASSEMBLY" >/dev/null
    restore_meta "$COMM" "$d/$CUSTOM_ASSEMBLY" "$meta"
  done

  say "Adding hidden backupchunksize=$PART_SIZE only to S3Compatible consumers..."
  patch_configs "$backup"

  say "Installing manual Backup-page connection/list/create/validate workflow..."
  patch_controlpanel "$backup"

  say "Restarting CommunityServer..."
  docker restart "$COMM" >/dev/null
  wait_container "$COMM"
  probe_handler "/var/www/onlyoffice/WebStudio/bin/$CUSTOM_ASSEMBLY"

  for p in "${CONFIGS[@]}"; do
    consumer_check "$p" || die "consumer validation failed after restart: $p"
  done

  say "Rebuilding Control Panel production bundle..."
  old_bundle_sha="$(docker exec "$CP" sha256sum "$bundle" | awk '{print $1}')"
  docker exec "$CP" rm -f "$bundle"
  docker restart "$CP" >/dev/null
  wait_container "$CP"
  for i in $(seq 1 120); do
    if docker exec "$CP" test -f "$bundle" >/dev/null 2>&1 \
       && docker exec "$CP" grep -aFq 'OCSPManualS3Backup' "$bundle" >/dev/null 2>&1 \
       && docker exec "$CP" grep -aFq 'ocspS3ValidateBucket' "$CP_BACKUP_CONTROLLER" >/dev/null 2>&1; then
      ready=1; break
    fi
    sleep 1
  done
  [ "$ready" = 1 ] || die "Control Panel bundle/routes did not reach v0.3.4 state"
  new_bundle_sha="$(docker exec "$CP" sha256sum "$bundle" | awk '{print $1}')"
  say "Control Panel bundle SHA256: $old_bundle_sha -> $new_bundle_sha"

  write_state "$backup" "$custom_sha" "$bundle" "$stamp"
  INSTALL_BACKUP=""

  say
  say "PASS — v0.3.4 manual backup hardening installed."
  say "  S3Compatible backup part size: 192 MiB"
  say "  S3 multipart guard: 10,000 parts (~1.83 TiB theoretical ceiling)"
  say "  Manual S3 workflow: Check connection -> list/create/select bucket -> 100 KiB validate -> Make Backup"
  say "  Validation: PUT -> HEAD -> GET/SHA-256 -> DELETE -> confirm gone"
  say "  No S3 credentials were read by the installer."
  say "  No storage migration, backup, restore, schedule or cron API was called by the installer."
  say "Next acceptance step: use the Control Panel manually against the sacrificial test bucket/provider."
}

status_cmd(){
  banner
  need docker; need sha256sum; need awk
  [ -f "$STATE_FILE" ] || die "v0.3.4 state absent"
  local expected_sha bundle d p actual bad=0
  expected_sha="$(read_state CUSTOM_SHA256)"
  bundle="$(read_state BUNDLE)"
  mapfile -t CONFIGS < <(community_configs)
  mapfile -t BIN_DIRS < <(storage_bin_dirs)

  for d in "${BIN_DIRS[@]}"; do
    actual="$(docker exec "$COMM" sha256sum "$d/$CUSTOM_ASSEMBLY" 2>/dev/null | awk '{print $1}' || true)"
    if [ "$actual" != "$expected_sha" ]; then say "MISMATCH: $d/$CUSTOM_ASSEMBLY"; bad=1; fi
  done
  for p in "${CONFIGS[@]}"; do
    if ! consumer_check "$p"; then say "BAD CONSUMER: $p"; bad=1; fi
  done

  docker exec "$CP" grep -Fq 'OCSP v0.3.4 manual S3 validation routes' "$CP_BACKUP_CONTROLLER" || { say "MISSING: Control Panel validation routes"; bad=1; }
  docker exec "$CP" grep -Fq 'OCSP v0.3.4 manual S3 backup gate' "$CP_BACKUP_JS" || { say "MISSING: manual backup gate hook"; bad=1; }
  docker exec "$CP" grep -Fq 'OCSP v0.3.4' "$CP_UI" || { say "MISSING: manual S3 UI module"; bad=1; }
  docker exec "$CP" test -f "$CP_PROBE" || { say "MISSING: S3 probe module"; bad=1; }
  docker exec "$CP" grep -aFq 'OCSPManualS3Backup' "$bundle" || { say "MISSING: production bundle marker"; bad=1; }

  if [ "$bad" = 0 ]; then
    say "PASS — v0.3.4 manual backup hardening present."
    say "Part size: $(read_state PART_SIZE) bytes; max parts: $(read_state MAX_PARTS)."
    say "Status does not read credentials or call any S3/backup/migration/restore API."
  else
    die "v0.3.4 status validation failed"
  fi
}

rollback_cmd(){
  banner
  need docker
  [ -f "$STATE_FILE" ] || die "v0.3.4 state absent"
  local backup bundle
  backup="$(read_state BACKUP)"
  bundle="$(read_state BUNDLE)"
  [ -d "$backup" ] || die "rollback backup missing: $backup"

  say "Restoring exact pre-v0.3.4 custom DLL/config/Control Panel files..."
  restore_manifest "$backup"
  rm -f "$STATE_FILE"

  docker restart "$COMM" >/dev/null
  wait_container "$COMM"
  docker restart "$CP" >/dev/null
  wait_container "$CP"

  say "PASS — v0.3.4 rolled back to the exact pre-install files."
  say "No storage migration, backup, restore or schedule API was called."
}

on_install_error(){
  local rc=$?
  if [ -n "${INSTALL_BACKUP:-}" ] && [ -d "$INSTALL_BACKUP" ]; then
    say "Install failed; restoring backed-up v0.3.4 files..." >&2
    restore_manifest "$INSTALL_BACKUP" || true
    docker restart "$COMM" >/dev/null 2>&1 || true
    wait_container "$COMM" >/dev/null 2>&1 || true
    docker restart "$CP" >/dev/null 2>&1 || true
    wait_container "$CP" >/dev/null 2>&1 || true
  fi
  exit "$rc"
}

case "${1:-status}" in
  install)
    trap on_install_error ERR
    install_cmd
    trap - ERR
    ;;
  status) status_cmd ;;
  rollback) rollback_cmd ;;
  *) die "usage: $0 {install|status|rollback}" ;;
esac
