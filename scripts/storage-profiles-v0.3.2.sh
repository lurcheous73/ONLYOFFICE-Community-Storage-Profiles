#!/usr/bin/env bash
set -euo pipefail

# ONLYOFFICE Community Storage Profiles — v0.3.2
# Backend compatibility handler for first-class S3Compatible storage.
#
# This release does NOT call the ONLYOFFICE storage API and does NOT start a
# migration. It builds and deploys a separate handler assembly so the stock
# ASC.Data.Storage.dll / legacy S3 handler remain untouched.
#
# Operations: install | status | rollback

COMM="${OCSP_COMMUNITY_CONTAINER:-onlyoffice-community-server}"
EXPECTED_COMM_IMAGE="onlyoffice/communityserver:12.8.0.1971"
UPSTREAM_COMMIT="fe1fa7babd093969e939ba6ff45a9fee1299dc93"
UPSTREAM_SOURCE_URL="https://raw.githubusercontent.com/ONLYOFFICE/CommunityServer/${UPSTREAM_COMMIT}/common/ASC.Data.Storage/S3/S3Storage.cs"

STATE_DIR="/var/lib/onlyoffice-community-storage-profiles"
BACKUP_ROOT="/var/backups/onlyoffice-community-storage-profiles"
V03_STATE="$STATE_DIR/storage-profiles-v0.3.state"
STATE_FILE="$STATE_DIR/storage-profiles-v0.3.2.state"
MANIFEST_NAME="manifest.tsv"
STOCK_HASHES_NAME="stock-asc-data-storage-sha256.tsv"

CUSTOM_ASSEMBLY="ASC.Data.Storage.S3Compatible.dll"
CUSTOM_TYPE="ASC.Data.Storage.S3Compatible.S3CompatibleStorage"
CUSTOM_HANDLER="${CUSTOM_TYPE}, ASC.Data.Storage.S3Compatible"
STOCK_HANDLER="ASC.Data.Storage.S3.S3Storage, ASC.Data.Storage"
COMPAT_PROP="disabledefaultchecksumvalidation"

ROOTS=(WebStudio WebStudio2 WebStudio3 WebStudio4)
TMP_DIR=""
INSTALL_BACKUP=""

say(){ printf '%s\n' "$*"; }
die(){ say "ERROR: $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }
container_image(){ docker inspect -f '{{.Config.Image}}' "$1"; }
meta_in(){ docker exec "$1" stat -c '%u:%g:%a' "$2"; }

cleanup_tmp(){
  if [ -n "${TMP_DIR:-}" ] && [ -d "$TMP_DIR" ]; then rm -rf -- "$TMP_DIR"; fi
}
trap cleanup_tmp EXIT

banner(){
  cat <<'BANNER'
====================================================================
 ONLYOFFICE Community Storage Profiles — v0.3.2
 S3Compatible backend compatibility handler
====================================================================
BANNER
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

consumer_block_check(){
  local path="$1" expected_handler="$2"
  docker exec "$COMM" python3 - "$path" "$expected_handler" "$COMPAT_PROP" <<'PY'
import re,sys
p,expected,compat=sys.argv[1:4]
text=open(p,encoding='utf-8').read()
m=re.search(r'<component\b(?=[^>]*\bname="S3Compatible")[^>]*>.*?</component>',text,re.S)
if not m:
    raise SystemExit(2)
block=m.group(0)
if expected not in block:
    raise SystemExit(3)
if expected.endswith('S3Compatible') and compat not in block:
    raise SystemExit(4)
PY
}

preflight_common(){
  need docker; need python3; need curl; need sha256sum; need awk
  docker inspect "$COMM" >/dev/null 2>&1 || die "container not found: $COMM"
  [ "$(container_image "$COMM")" = "$EXPECTED_COMM_IMAGE" ] \
    || die "unsupported CommunityServer image: $(container_image "$COMM")"
  docker exec "$COMM" command -v mcs >/dev/null 2>&1 || die "mcs not found in $COMM"
}

preflight_install(){
  preflight_common
  [ -f "$V03_STATE" ] || die "v0.3 state not found; install the S3Compatible consumer first"
  [ ! -f "$STATE_FILE" ] || die "v0.3.2 already installed; use status or rollback"

  mapfile -t CONFIGS < <(community_configs)
  [ "${#CONFIGS[@]}" -ge 2 ] || die "expected WebStudio and TeamLabSvc consumer configs"
  local p
  for p in "${CONFIGS[@]}"; do
    consumer_block_check "$p" "$STOCK_HANDLER" \
      || die "S3Compatible does not use the expected stock handler in $p"
  done

  mapfile -t BIN_DIRS < <(storage_bin_dirs)
  [ "${#BIN_DIRS[@]}" -ge 2 ] || die "could not discover ASC.Data.Storage.dll deployment directories"
  for p in "${BIN_DIRS[@]}"; do
    docker exec "$COMM" test ! -e "$p/$CUSTOM_ASSEMBLY" \
      || die "unexpected pre-existing $p/$CUSTOM_ASSEMBLY"
  done

  local refdir="/var/www/onlyoffice/WebStudio/bin"
  local refs=(
    ASC.Data.Storage.dll
    ASC.Common.dll
    ASC.Core.Common.dll
    AWSSDK.Core.dll
    AWSSDK.S3.dll
    AWSSDK.CloudFront.dll
    Amazon.Extensions.S3.Encryption.dll
  )
  local r
  for r in "${refs[@]}"; do
    docker exec "$COMM" test -f "$refdir/$r" \
      || die "compile reference missing: $refdir/$r"
  done
}

backup_file(){
  local c="$1" label="$2" path="$3" backup="$4" meta dst
  meta="$(meta_in "$c" "$path")"
  dst="$backup/$label$path"
  mkdir -p "$(dirname "$dst")"
  docker cp "$c:$path" "$dst" >/dev/null
  chmod 600 "$dst"
  printf 'RESTORE\t%s\t%s\t%s\n' "$label" "$path" "$meta" >>"$backup/$MANIFEST_NAME"
}

record_delete(){
  local label="$1" path="$2" backup="$3"
  printf 'DELETE\t%s\t%s\t-\n' "$label" "$path" >>"$backup/$MANIFEST_NAME"
}

record_stock_hashes(){
  local backup="$1" d
  : >"$backup/$STOCK_HASHES_NAME"
  for d in "${BIN_DIRS[@]}"; do
    printf '%s\t%s\n' "$d/ASC.Data.Storage.dll" \
      "$(docker exec "$COMM" sha256sum "$d/ASC.Data.Storage.dll" | awk '{print $1}')" \
      >>"$backup/$STOCK_HASHES_NAME"
  done
  chmod 600 "$backup/$STOCK_HASHES_NAME"
}

verify_stock_hashes(){
  local backup="$1" path expected actual bad=0
  while IFS=$'\t' read -r path expected; do
    [ -n "$path" ] || continue
    actual="$(docker exec "$COMM" sha256sum "$path" 2>/dev/null | awk '{print $1}' || true)"
    if [ "$actual" != "$expected" ]; then
      say "MISMATCH: stock DLL changed: $path"
      bad=1
    fi
  done <"$backup/$STOCK_HASHES_NAME"
  [ "$bad" = 0 ]
}

restore_manifest(){
  local backup="$1" action label path meta src
  [ -f "$backup/$MANIFEST_NAME" ] || return 0
  tac "$backup/$MANIFEST_NAME" | while IFS=$'\t' read -r action label path meta; do
    case "$action" in
      RESTORE)
        src="$backup/$label$path"
        if [ -f "$src" ]; then
          docker cp "$src" "$COMM:$path" >/dev/null
          restore_meta "$COMM" "$path" "$meta"
        fi
        ;;
      DELETE)
        docker exec "$COMM" rm -f -- "$path" || true
        ;;
    esac
  done
}

patch_source(){
  local src="$1" dst="$2"
  python3 - "$src" "$dst" <<'PY'
import sys
from pathlib import Path
src,dst=map(Path,sys.argv[1:3])
text=src.read_text(encoding='utf-8')

checks={
 'namespace ASC.Data.Storage.S3':1,
 'public class S3Storage : BaseStorage':1,
 'public S3Storage(':2,
 'result = result.Replace("//", "/").TrimStart(\'/\').TrimEnd(\'/\');':1,
 'var request = new TransferUtilityUploadRequest':2,
 'uploader.Upload(request);':2,
 'var request = new UploadPartRequest':2,
 's3.UploadPart(request);':1,
 's3.UploadPartAsync(request)':1,
}
for needle,want in checks.items():
    got=text.count(needle)
    if got!=want:
        raise SystemExit(f'baseline mismatch for {needle!r}: expected {want}, got {got}')

text=text.replace('using System.Linq;\n','using System.Linq;\nusing System.Reflection;\n',1)
text=text.replace('using ASC.Data.Storage.Configuration;\n','using ASC.Data.Storage.Configuration;\nusing ASC.Data.Storage.S3;\n',1)
text=text.replace('namespace ASC.Data.Storage.S3\n','namespace ASC.Data.Storage.S3Compatible\n',1)
text=text.replace('public class S3Storage : BaseStorage','public class S3CompatibleStorage : BaseStorage',1)
text=text.replace('public S3Storage(', 'public S3CompatibleStorage(', 2)

class_anchor='    public class S3CompatibleStorage : BaseStorage\n    {\n'
if class_anchor not in text:
    raise SystemExit('custom class anchor missing')
shadow=r'''    public class S3CompatibleStorage : BaseStorage
    {
        // OCSP v0.3.2: BaseStorage state is internal in the stock assembly.
        // Keep a local mirror and sync the stock base fields after Configure().
        private string _tenant;
        private string _modulename;
        private bool _cache;
        private bool _attachment;
        private DataList _dataList;
        private Dictionary<string, TimeSpan> _domainsExpires = new Dictionary<string, TimeSpan>();
        private Dictionary<string, IDataStoreValidator> _domainsValidators = new Dictionary<string, IDataStoreValidator>();
        private bool _disableDefaultChecksumValidation;

'''
text=text.replace(class_anchor,shadow,1)

ctor_anchor='        public S3CompatibleStorage(string tenant)\n'
if ctor_anchor not in text:
    raise SystemExit('constructor anchor missing')
helpers=r'''        private void SetBaseField(string name, object value)
        {
            var field = typeof(BaseStorage).GetField(name, BindingFlags.Instance | BindingFlags.NonPublic);
            if (field == null)
            {
                throw new MissingFieldException(typeof(BaseStorage).FullName, name);
            }
            field.SetValue(this, value);
        }

        private void SyncBaseState()
        {
            SetBaseField("_tenant", _tenant);
            SetBaseField("_modulename", _modulename);
            SetBaseField("_cache", _cache);
            SetBaseField("_attachment", _attachment);
            SetBaseField("_dataList", _dataList);
            SetBaseField("_domainsExpires", _domainsExpires);
            SetBaseField("_domainsValidators", _domainsValidators);
        }

        private string QuotaData(string domain)
        {
            return _dataList == null ? string.Empty : _dataList.GetData(domain);
        }

        private void QuotaUsedAdd(string domain, long size, bool quotaCheckFileSize = true)
        {
            QuotaUsedAdd(domain, size, Guid.Empty, quotaCheckFileSize);
        }

        private void QuotaUsedAdd(string domain, long size, Guid ownerId, bool quotaCheckFileSize = true)
        {
            if (QuotaController != null)
            {
                QuotaController.QuotaUsedAdd(_modulename, domain, QuotaData(domain), size, ownerId, quotaCheckFileSize);
            }
        }

        private void QuotaUsedDelete(string domain, long size)
        {
            QuotaUsedDelete(domain, size, Guid.Empty);
        }

        private void QuotaUsedDelete(string domain, long size, Guid ownerId)
        {
            if (QuotaController != null)
            {
                QuotaController.QuotaUsedDelete(_modulename, domain, QuotaData(domain), size, ownerId);
            }
        }

'''
text=text.replace(ctor_anchor,helpers+ctor_anchor,1)

configure_anchor='''            if (props.ContainsKey("subdir"))
            {
                _subDir = props["subdir"];
            }

            return this;
'''
if text.count(configure_anchor)!=1:
    raise SystemExit('Configure tail anchor mismatch')
configure_new='''            if (props.ContainsKey("subdir"))
            {
                _subDir = props["subdir"];
            }

            if (props.ContainsKey("disabledefaultchecksumvalidation"))
            {
                bool.TryParse(props["disabledefaultchecksumvalidation"], out _disableDefaultChecksumValidation);
            }

            SyncBaseState();
            return this;
'''
text=text.replace(configure_anchor,configure_new,1)

old='result = result.Replace("//", "/").TrimStart(\'/\').TrimEnd(\'/\');'
new='''while (result.Contains("//"))
            {
                result = result.Replace("//", "/");
            }
            result = result.TrimStart('/').TrimEnd('/');'''
text=text.replace(old,new,1)

text=text.replace('                uploader.Upload(request);',
                  '                request.DisableDefaultChecksumValidation = _disableDefaultChecksumValidation;\n                uploader.Upload(request);',2)
text=text.replace('                    var response = s3.UploadPart(request);',
                  '                    request.DisableDefaultChecksumValidation = _disableDefaultChecksumValidation;\n                    var response = s3.UploadPart(request);',1)
text=text.replace('                    var response = await s3.UploadPartAsync(request);',
                  '                    request.DisableDefaultChecksumValidation = _disableDefaultChecksumValidation;\n                    var response = await s3.UploadPartAsync(request);',1)

for forbidden in ('namespace ASC.Data.Storage.S3\n','public class S3Storage : BaseStorage','public S3Storage('):
    if forbidden in text:
        raise SystemExit('rename incomplete: '+forbidden)
if text.count('DisableDefaultChecksumValidation = _disableDefaultChecksumValidation;')!=4:
    raise SystemExit('checksum compatibility injection count invalid')
if 'while (result.Contains("//"))' not in text:
    raise SystemExit('key normalization patch missing')

dst.write_text(text,encoding='utf-8')
PY
}

patch_consumer_config(){
  local src="$1" dst="$2"
  python3 - "$src" "$dst" "$STOCK_HANDLER" "$CUSTOM_HANDLER" "$COMPAT_PROP" <<'PY'
import re,sys
from pathlib import Path
src,dst=map(Path,sys.argv[1:3])
stock,custom,compat=sys.argv[3:6]
text=src.read_text(encoding='utf-8')
pat=re.compile(r'<component\b(?=[^>]*\bname="S3Compatible")[^>]*>.*?</component>',re.S)
m=pat.search(text)
if not m:
    raise SystemExit('S3Compatible component not found')
block=m.group(0)
if stock not in block:
    raise SystemExit('expected stock S3 handler not found in S3Compatible component')
if custom in block or compat in block:
    raise SystemExit('v0.3.2 consumer changes already present')
block=block.replace(stock,custom,1)
nl='\r\n' if '\r\n' in block else '\n'
needle=re.search(r'(?P<indent>^[ \t]*)<item\s+key="usehttp"[^>]*/>',block,re.M)
if not needle:
    raise SystemExit('usehttp item anchor not found')
indent=needle.group('indent')
item=indent + '<item key="'+compat+'" value="true" hidden="true" optional="true" />'
pos=needle.end()
block=block[:pos]+nl+item+block[pos:]
new=text[:m.start()]+block+text[m.end():]
if new.count(custom)!=1 or new.count('key="'+compat+'"')!=1:
    raise SystemExit('post-patch consumer validation failed')
dst.write_text(new,encoding='utf-8')
PY
}

compile_handler(){
  local source="$1" out_host="$2"
  local build="/tmp/ocsp-v032-build"
  local refdir="/var/www/onlyoffice/WebStudio/bin"

  docker exec "$COMM" rm -rf "$build"
  docker exec "$COMM" mkdir -p "$build"
  docker cp "$source" "$COMM:$build/S3CompatibleStorage.cs" >/dev/null

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
  -r:System.Configuration.dll \\
  -r:System.Runtime.Serialization.dll \\
  -r:System.ServiceModel.dll \\
  -r:System.Web.dll \\
  S3CompatibleStorage.cs
"

  docker cp "$COMM:$build/$CUSTOM_ASSEMBLY" "$out_host" >/dev/null
  chmod 600 "$out_host"
}

probe_handler(){
  local dll_path="$1"
  local build="/tmp/ocsp-v032-probe"
  docker exec "$COMM" rm -rf "$build"
  docker exec "$COMM" mkdir -p "$build"
  docker exec "$COMM" bash -lc "cat >'$build/probe.cs' <<'CS'
using System;
using System.Reflection;
class Probe {
  static int Main(string[] args) {
    var a=Assembly.LoadFrom(args[0]);
    var t=a.GetType(\"$CUSTOM_TYPE\", false);
    if (t==null) { Console.Error.WriteLine(\"custom handler type missing\"); return 2; }
    Console.WriteLine(t.AssemblyQualifiedName);
    return 0;
  }
}
CS
mcs -out:'$build/probe.exe' '$build/probe.cs'
MONO_PATH=/var/www/onlyoffice/WebStudio/bin mono '$build/probe.exe' '$dll_path'
"
}

deploy_handler(){
  local built="$1" backup="$2" d target meta
  for d in "${BIN_DIRS[@]}"; do
    target="$d/$CUSTOM_ASSEMBLY"
    record_delete COMM "$target" "$backup"
    meta="$(meta_in "$COMM" "$d/ASC.Data.Storage.dll")"
    docker cp "$built" "$COMM:$target" >/dev/null
    restore_meta "$COMM" "$target" "$meta"
  done
}

patch_configs(){
  local backup="$1" p label in out meta
  local n=0
  for p in "${CONFIGS[@]}"; do
    n=$((n+1)); label="COMM-CONFIG-$n"
    backup_file "$COMM" "$label" "$p" "$backup"
    in="$TMP_DIR/config-$n.in"; out="$TMP_DIR/config-$n.out"
    docker cp "$COMM:$p" "$in" >/dev/null
    patch_consumer_config "$in" "$out"
    meta="$(meta_in "$COMM" "$p")"
    docker cp "$out" "$COMM:$p" >/dev/null
    restore_meta "$COMM" "$p" "$meta"
  done
}

write_state(){
  local backup="$1" custom_sha="$2"
  mkdir -p "$STATE_DIR"
  cat >"$STATE_FILE" <<EOFSTATE
VERSION=0.3.2
UPSTREAM_COMMIT=$UPSTREAM_COMMIT
BACKUP=$backup
CUSTOM_ASSEMBLY=$CUSTOM_ASSEMBLY
CUSTOM_SHA256=$custom_sha
CUSTOM_HANDLER=$CUSTOM_HANDLER
EOFSTATE
  chmod 600 "$STATE_FILE"
}

read_state_value(){
  local key="$1"
  sed -n "s/^${key}=//p" "$STATE_FILE" | head -1
}

install_cmd(){
  banner
  preflight_install
  TMP_DIR="$(mktemp -d /tmp/ocsp-v032.XXXXXX)"
  local stamp backup source patched built custom_sha p
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  backup="$BACKUP_ROOT/v0.3.2-$stamp"
  mkdir -p "$backup"; chmod 700 "$backup"; : >"$backup/$MANIFEST_NAME"
  INSTALL_BACKUP="$backup"

  say "Backing up consumer configs and recording stock ASC.Data.Storage.dll hashes..."
  record_stock_hashes "$backup"

  source="$TMP_DIR/S3Storage.upstream.cs"
  patched="$TMP_DIR/S3CompatibleStorage.cs"
  built="$TMP_DIR/$CUSTOM_ASSEMBLY"

  say "Fetching exact ONLYOFFICE CommunityServer source commit $UPSTREAM_COMMIT..."
  curl -fsSL --retry 3 --connect-timeout 15 "$UPSTREAM_SOURCE_URL" -o "$source"
  [ -s "$source" ] || die "upstream S3Storage.cs download is empty"
  grep -Fq 'public class S3Storage : BaseStorage' "$source" \
    || die "downloaded source is not the expected S3Storage.cs"

  say "Generating provider-scoped S3Compatible handler source..."
  patch_source "$source" "$patched"

  say "Compiling $CUSTOM_ASSEMBLY against the installed ONLYOFFICE/AWS assemblies..."
  compile_handler "$patched" "$built"
  custom_sha="$(sha256sum "$built" | awk '{print $1}')"
  say "Custom handler SHA256: $custom_sha"

  say "Deploying the separate handler beside each stock ASC.Data.Storage.dll..."
  deploy_handler "$built" "$backup"

  say "Updating only the S3Compatible consumer handler and compatibility property..."
  patch_configs "$backup"

  say "Verifying stock ASC.Data.Storage.dll files are byte-for-byte unchanged..."
  verify_stock_hashes "$backup" || {
    restore_manifest "$backup"
    die "stock ASC.Data.Storage.dll changed unexpectedly; rolled back files"
  }

  say "Restarting Community Server..."
  docker restart "$COMM" >/dev/null
  wait_container "$COMM"

  say "Probing deployed custom handler type..."
  probe_handler "/var/www/onlyoffice/WebStudio/bin/$CUSTOM_ASSEMBLY"

  for p in "${CONFIGS[@]}"; do
    consumer_block_check "$p" "$CUSTOM_HANDLER" \
      || die "post-install S3Compatible consumer validation failed: $p"
  done

  write_state "$backup" "$custom_sha"
  INSTALL_BACKUP=""

  say
  say "PASS — v0.3.2 backend compatibility handler installed."
  say "Stock legacy S3 assembly was not modified."
  say "No storage API was called and no migration was started."
  say "Next: run scripts/test-s3compatible-v0.3.2.sh before CONNECT."
}

status_cmd(){
  banner
  preflight_common
  if [ ! -f "$STATE_FILE" ]; then
    say "v0.3.2 state: absent"
    exit 1
  fi
  local backup expected_sha d p actual bad=0
  backup="$(read_state_value BACKUP)"
  expected_sha="$(read_state_value CUSTOM_SHA256)"
  say "v0.3.2 state: PRESENT"
  say "Backup: $backup"
  say "Expected custom SHA256: $expected_sha"

  mapfile -t CONFIGS < <(community_configs)
  mapfile -t BIN_DIRS < <(storage_bin_dirs)
  for d in "${BIN_DIRS[@]}"; do
    if ! docker exec "$COMM" test -f "$d/$CUSTOM_ASSEMBLY"; then
      say "MISSING: $d/$CUSTOM_ASSEMBLY"; bad=1; continue
    fi
    actual="$(docker exec "$COMM" sha256sum "$d/$CUSTOM_ASSEMBLY" | awk '{print $1}')"
    if [ "$actual" != "$expected_sha" ]; then say "MISMATCH: $d/$CUSTOM_ASSEMBLY"; bad=1; fi
  done
  for p in "${CONFIGS[@]}"; do
    if ! consumer_block_check "$p" "$CUSTOM_HANDLER"; then say "BAD CONSUMER: $p"; bad=1; fi
  done
  if ! verify_stock_hashes "$backup"; then bad=1; fi

  if [ "$bad" = 0 ]; then
    say "PASS — custom handler/config present; stock ASC.Data.Storage.dll hashes unchanged."
    say "No credentials are read and no storage API is called by status."
  else
    die "v0.3.2 status validation failed"
  fi
}

rollback_cmd(){
  banner
  preflight_common
  [ -f "$STATE_FILE" ] || die "v0.3.2 state not found"
  local backup
  backup="$(read_state_value BACKUP)"
  [ -d "$backup" ] || die "backup directory missing: $backup"

  say "Restoring S3Compatible consumer configs and removing custom handler assembly..."
  restore_manifest "$backup"
  say "Restarting Community Server..."
  docker restart "$COMM" >/dev/null
  wait_container "$COMM"
  verify_stock_hashes "$backup" || die "stock ASC.Data.Storage.dll hash mismatch after rollback"
  rm -f "$STATE_FILE"
  say "PASS — v0.3.2 rolled back. Legacy stock S3 assembly remains unchanged."
}

on_install_error(){
  local rc=$?
  if [ -n "${INSTALL_BACKUP:-}" ] && [ -d "$INSTALL_BACKUP" ]; then
    say "Install failed; restoring v0.3.2 file/config changes from $INSTALL_BACKUP ..." >&2
    restore_manifest "$INSTALL_BACKUP" || true
    docker restart "$COMM" >/dev/null 2>&1 || true
    wait_container "$COMM" >/dev/null 2>&1 || true
  fi
  exit "$rc"
}

cmd="${1:-status}"
case "$cmd" in
  install)
    trap on_install_error ERR
    install_cmd
    trap - ERR
    ;;
  status) status_cmd ;;
  rollback) rollback_cmd ;;
  *) die "usage: $0 {install|status|rollback}" ;;
esac
