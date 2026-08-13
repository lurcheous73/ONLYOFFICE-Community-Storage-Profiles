#!/usr/bin/env bash
set -euo pipefail

# ONLYOFFICE Community Storage Profiles — v0.3 developer preview
#
# Creates a NEW first-class DataStoreConsumer named S3Compatible while reusing
# ONLYOFFICE's existing ASC.Data.Storage.S3.S3Storage handler.
#
# v0.3 does NOT select the new storage, does NOT call updateStorage, does NOT
# migrate document data, and does NOT read/write credentials.
#
# Operations: install | status | rollback

COMM="${OCSP_COMMUNITY_CONTAINER:-onlyoffice-community-server}"
CP="${OCSP_CONTROL_PANEL_CONTAINER:-onlyoffice-control-panel}"
EXPECTED_COMM_IMAGE="onlyoffice/communityserver:12.8.0.1971"
EXPECTED_CP_IMAGE="onlyoffice/controlpanel:3.5.5.549"

STATE_DIR="/var/lib/onlyoffice-community-storage-profiles"
BACKUP_ROOT="/var/backups/onlyoffice-community-storage-profiles"
STATE_FILE="$STATE_DIR/storage-profiles-v0.3.state"
MANIFEST_NAME="manifest.tsv"

OLD_STATES=(
  "$STATE_DIR/storage-profiles-v0.1.state"
  "$STATE_DIR/storage-profiles-v0.2.state"
  "$STATE_DIR/storage-profiles-v0.2.1-communityserver.state"
)

CP_STORAGE_JS="/var/www/onlyoffice/controlpanel/www/public/javascripts/views/storage.js"
CP_VIEWS=(
  "/var/www/onlyoffice/controlpanel/www/views/storage.pug"
  "/var/www/onlyoffice/controlpanel/www/views/backup.pug"
  "/var/www/onlyoffice/controlpanel/www/views/restore.pug"
)

STOCK_CP_STORAGE_JS_SHA="4d97712fb1b62b1da1fe6e0ff37488b7eb06310607faba54ffeaa8ac33dd821c"
STOCK_AUTH_JS_SHA="c6ba7611549a7a51514e44838d34118ed422422f4b7b86350dd58fe05f69c7e9"
AUTH_JS_REL="UserControls/Management/AuthorizationKeys/js/authorizationkeys.js"
AUTH_IMG_REL="UserControls/Management/AuthorizationKeys/img"
ROOTS=(WebStudio WebStudio2 WebStudio3 WebStudio4)

COMM_MARKER='OCSP v0.3 S3Compatible presentation'
CP_MARKER='OCSP v0.3 S3Compatible Control Panel'
CONSUMER_NAME='S3Compatible'
TMP_DIR=""

say(){ printf '%s\n' "$*"; }
die(){ say "ERROR: $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

cleanup_tmp(){
  if [ -n "${TMP_DIR:-}" ] && [ -d "$TMP_DIR" ]; then rm -rf -- "$TMP_DIR"; fi
}
trap cleanup_tmp EXIT

banner(){
  cat <<'EOF'
====================================================================
 ONLYOFFICE Community Storage Profiles — v0.3 developer preview
 First-class S3Compatible consumer
====================================================================
EOF
}

container_image(){ docker inspect -f '{{.Config.Image}}' "$1"; }
sha_in(){ docker exec "$1" sha256sum "$2" | awk '{print $1}'; }
meta_in(){ docker exec "$1" stat -c '%u:%g:%a' "$2"; }

restore_meta(){
  local container="$1" path="$2" meta="$3" uid gid mode rest
  uid="${meta%%:*}"; rest="${meta#*:}"; gid="${rest%%:*}"; mode="${rest##*:}"
  docker exec "$container" chown "$uid:$gid" "$path"
  docker exec "$container" chmod "$mode" "$path"
}

wait_container(){
  local container="$1" i
  for i in $(seq 1 90); do
    if [ "$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null || true)" = "true" ] \
       && docker exec "$container" true >/dev/null 2>&1; then return 0; fi
    sleep 2
  done
  die "$container did not return to running state"
}

community_configs(){
  local root path
  for root in "${ROOTS[@]}"; do
    path="/var/www/onlyoffice/$root/web.consumers.config"
    docker exec "$COMM" test -f "$path" >/dev/null 2>&1 && printf '%s\n' "$path"
  done
  path="/var/www/onlyoffice/Services/TeamLabSvc/web.consumers.config"
  docker exec "$COMM" test -f "$path" >/dev/null 2>&1 && printf '%s\n' "$path"
}

auth_js_files(){
  local root path
  for root in "${ROOTS[@]}"; do
    path="/var/www/onlyoffice/$root/$AUTH_JS_REL"
    docker exec "$COMM" test -f "$path" >/dev/null 2>&1 && printf '%s\n' "$path"
  done
}

icon_files(){
  local root path
  for root in "${ROOTS[@]}"; do
    path="/var/www/onlyoffice/$root/$AUTH_IMG_REL/s3compatible.svg"
    printf '%s\n' "$path"
  done
}

consumer_present(){
  local path="$1"
  docker exec "$COMM" grep -Eq '<component[^>]+name="S3Compatible"' "$path"
}

preflight_common(){
  need docker
  need python3
  need sha256sum
  need awk

  docker inspect "$COMM" >/dev/null 2>&1 || die "container not found: $COMM"
  docker inspect "$CP" >/dev/null 2>&1 || die "container not found: $CP"
  [ "$(container_image "$COMM")" = "$EXPECTED_COMM_IMAGE" ] || die "unsupported CommunityServer image: $(container_image "$COMM")"
  [ "$(container_image "$CP")" = "$EXPECTED_CP_IMAGE" ] || die "unsupported Control Panel image: $(container_image "$CP")"
}

preflight_install(){
  preflight_common
  local f path count

  for f in "${OLD_STATES[@]}"; do
    [ ! -f "$f" ] || die "superseded experiment state still present: $f — run scripts/cleanup-pre-v0.3.sh cleanup first"
  done
  [ ! -f "$STATE_FILE" ] || die "v0.3 state already exists; use status or rollback"

  mapfile -t CONFIGS < <(community_configs)
  [ "${#CONFIGS[@]}" -ge 2 ] || die "expected WebStudio and TeamLabSvc consumer configs"
  for path in "${CONFIGS[@]}"; do
    consumer_present "$path" && die "S3Compatible already exists in $path without v0.3 state"
    count="$(docker exec "$COMM" sh -lc "grep -c '<component .*name=\"S3\"' '$path' || true")"
    [ "$count" = "1" ] || die "expected exactly one stock S3 component in $path; got $count"
    docker exec "$COMM" grep -Fq 'ASC.Data.Storage.S3.S3Storage, ASC.Data.Storage' "$path" || die "S3 handler missing from $path"
  done

  mapfile -t AUTH_FILES < <(auth_js_files)
  [ "${#AUTH_FILES[@]}" -ge 1 ] || die "no AuthorizationKeys JS files found"
  for path in "${AUTH_FILES[@]}"; do
    [ "$(sha_in "$COMM" "$path")" = "$STOCK_AUTH_JS_SHA" ] || die "AuthorizationKeys JS is not stock: $path"
  done

  for path in $(icon_files); do
    docker exec "$COMM" test ! -e "$path" || die "unexpected pre-existing icon: $path"
  done

  docker exec "$CP" test -f "$CP_STORAGE_JS" || die "Control Panel storage.js missing"
  [ "$(sha_in "$CP" "$CP_STORAGE_JS")" = "$STOCK_CP_STORAGE_JS_SHA" ] || die "Control Panel storage.js is not stock; run pre-v0.3 cleanup first"

  for path in "${CP_VIEWS[@]}"; do
    docker exec "$CP" test -f "$path" || die "Control Panel view missing: $path"
    count="$(docker exec "$CP" sh -lc "grep -Fc '{{if id == \"S3\"}}' '$path' || true")"
    [ "$count" = "1" ] || die "unexpected S3 template condition count in $path: $count"
  done
}

backup_existing(){
  local container="$1" label="$2" path="$3" backup="$4" meta dst
  meta="$(meta_in "$container" "$path")"
  dst="$backup/$label$path"
  mkdir -p "$(dirname "$dst")"
  docker cp "$container:$path" "$dst" >/dev/null
  chmod 600 "$dst"
  printf 'RESTORE\t%s\t%s\t%s\n' "$label" "$path" "$meta" >>"$backup/$MANIFEST_NAME"
}

record_delete(){
  local label="$1" path="$2" backup="$3"
  printf 'DELETE\t%s\t%s\t-\n' "$label" "$path" >>"$backup/$MANIFEST_NAME"
}

patch_consumer_config(){
  local src="$1" dst="$2"
  python3 - "$src" "$dst" <<'PY'
import re, sys
from pathlib import Path
src, dst = map(Path, sys.argv[1:3])
with src.open('r', encoding='utf-8', newline='') as f:
    text = f.read()
if re.search(r'<component\b[^>]*\bname="S3Compatible"', text):
    raise SystemExit('S3Compatible already present')
pat = re.compile(r'(?P<indent>^[ \t]*)<component\b(?=[^>]*\bname="S3")[^>]*>.*?</component>', re.M | re.S)
m = pat.search(text)
if not m:
    raise SystemExit('stock S3 component not found')
if pat.search(text, m.end()):
    raise SystemExit('multiple stock S3 components found')
indent = m.group('indent')
nl = '\r\n' if '\r\n' in text else '\n'
i1 = indent + '  '
i2 = indent + '    '
lines = [
    indent + '<component name="S3Compatible" type="ASC.Core.Common.Configuration.DataStoreConsumer, ASC.Core.Common" order="19">',
    i1 + '<props>',
    i2 + '<item key="acesskey" value="" />',
    i2 + '<item key="secretaccesskey" value="" password="true" />',
    i2 + '<item key="handlerType" value="ASC.Data.Storage.S3.S3Storage, ASC.Data.Storage" hidden="true" />',
    i2 + '<item key="bucket" value="" hidden="true" />',
    i2 + '<item key="region" value="" hidden="true" />',
    i2 + '<item key="serviceurl" value="" hidden="true" optional="true" />',
    i2 + '<item key="forcepathstyle" value="" hidden="true" optional="true" />',
    i2 + '<item key="usehttp" value="" hidden="true" optional="true" />',
    i2 + '<item key="cname" value="" hidden="true" optional="true" />',
    i2 + '<item key="cnamessl" value="" hidden="true" optional="true" />',
    i2 + '<item key="sse" value="" hidden="true" optional="true" />',
    i2 + '<item key="ssekey" value="" hidden="true" optional="true" />',
    i1 + '</props>',
    indent + '</component>',
]
block = nl.join(lines) + nl
new = text[:m.start()] + block + text[m.start():]
if new.count('name="S3Compatible"') != 1:
    raise SystemExit('post-patch S3Compatible count invalid')
with dst.open('w', encoding='utf-8', newline='') as f:
    f.write(new)
PY
}

patch_auth_js(){
  local src="$1" dst="$2"
  python3 - "$src" "$dst" <<'PY'
import sys
from pathlib import Path
src, dst = map(Path, sys.argv[1:3])
with src.open('r', encoding='utf-8', newline='') as f:
    text = f.read()
nl = '\r\n' if '\r\n' in text else '\n'
marker = 'OCSP v0.3 S3Compatible presentation'
if marker in text:
    raise SystemExit('v0.3 auth marker already present')
anchor = '    function init() {' + nl
if text.count(anchor) != 1:
    raise SystemExit(f'expected one init() anchor, got {text.count(anchor)}')
lines = [
'    // BEGIN OCSP v0.3 S3Compatible presentation',
'    function ocspDecorateS3Compatible() {',
'        var switcher = jq("#switcherBtnS3Compatible");',
'        if (switcher.length) {',
'            var tile = switcher.closest(".auth-service-item");',
'            tile.find(".auth-service-img").attr("alt", "S3-Compatible Object Storage");',
'            tile.find(".auth-service-dscr").first().text("Connect S3-compatible object storage for portal storage and backups.");',
'',
'            var popup = jq("#popupDialogS3Compatible");',
'            popup.find(".containerHeaderBlock td").first().text("S3-Compatible Object Storage");',
'            popup.find(".auth-service-img").attr("alt", "S3-Compatible Object Storage");',
'            var info = popup.find(".popup-info-block").first();',
'            if (info.length) info.text("Enter the access key and secret access key for the selected S3-compatible provider. Endpoint, bucket and protocol settings are configured in Storage.");',
'            var access = popup.find("#acesskey");',
'            if (access.length) { access.prev(".headerPanelSmall").text("Access key:"); access.attr("placeholder", "Access key"); }',
'            var secret = popup.find("#secretaccesskey");',
'            if (secret.length) { secret.prev(".headerPanelSmall").text("Secret access key:"); secret.attr("placeholder", "Secret access key"); }',
'        }',
'',
'        // Preserve configured legacy AWS access. Hide the stock AWS tile only',
'        // when it is unused; this avoids stranding an existing installation.',
'        var legacy = jq("#switcherBtnS3");',
'        if (legacy.length && legacy.hasClass("off")) legacy.closest(".auth-service-item").hide();',
'    }',
'    // END OCSP v0.3 S3Compatible presentation',
'',
]
helper = nl.join(lines) + nl
text = text.replace(anchor, helper + anchor, 1)
text = text.replace(anchor, anchor + '        ocspDecorateS3Compatible();' + nl, 1)
for required in ('window.AuthorizationKeys.SaveAuthKeys(itemName, props,', 'save(itemName, true);'):
    if required not in text:
        raise SystemExit('credential-save contract missing: ' + required)
with dst.open('w', encoding='utf-8', newline='') as f:
    f.write(text)
PY
}

write_neutral_icon(){
  cat >"$1" <<'SVG'
<svg width="50" height="40" viewBox="0 0 50 40" fill="none" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="S3-compatible object storage">
  <g stroke="#667085" stroke-width="2" fill="none" stroke-linecap="round" stroke-linejoin="round">
    <ellipse cx="25" cy="8" rx="15" ry="5"/>
    <path d="M10 8v8c0 2.8 6.7 5 15 5s15-2.2 15-5V8"/>
    <path d="M10 16v8c0 2.8 6.7 5 15 5s15-2.2 15-5v-8"/>
    <path d="M10 24v8c0 2.8 6.7 5 15 5s15-2.2 15-5v-8"/>
  </g>
</svg>
SVG
}

patch_cp_view(){
  local src="$1" dst="$2"
  python3 - "$src" "$dst" <<'PY'
import sys
from pathlib import Path
src, dst = map(Path, sys.argv[1:3])
with src.open('r', encoding='utf-8', newline='') as f:
    text = f.read()
old = '{{if id == "S3"}}'
if text.count(old) != 1:
    raise SystemExit(f'expected one S3 template condition, got {text.count(old)}')
text = text.replace(old, '{{if id == "S3" || id == "S3Compatible"}}', 1)
old_label = '<span>${title}</span>'
if text.count(old_label) < 1:
    raise SystemExit('storage title span not found')
text = text.replace(old_label, '<span>{{if id == "S3Compatible"}}S3-Compatible Object Storage{{else}}${title}{{/if}}</span>', 1)
with dst.open('w', encoding='utf-8', newline='') as f:
    f.write(text)
PY
}

patch_cp_storage_js(){
  local src="$1" dst="$2"
  python3 - "$src" "$dst" <<'PY'
import sys
from pathlib import Path
src, dst = map(Path, sys.argv[1:3])
text = src.read_text(encoding='utf-8')
marker = 'OCSP v0.3 S3Compatible Control Panel'
if marker in text:
    raise SystemExit('v0.3 Control Panel marker already present')
anchor = '    function init(portal) {\n'
if text.count(anchor) != 1:
    raise SystemExit(f'expected one init(portal) anchor, got {text.count(anchor)}')
helper = r'''    // BEGIN OCSP v0.3 S3Compatible Control Panel
    var ocspProviderProfiles = [
        { id: "amazon-s3", name: "Amazon S3" },
        { id: "mega-s4", name: "MEGA S4" },
        { id: "wasabi", name: "Wasabi" },
        { id: "backblaze-b2-s3", name: "Backblaze B2 S3" },
        { id: "cloudflare-r2", name: "Cloudflare R2" },
        { id: "minio", name: "MinIO" },
        { id: "ceph-rgw", name: "Ceph RGW" },
        { id: "ovhcloud", name: "OVHcloud Object Storage" },
        { id: "custom-s3", name: "Custom S3-Compatible Endpoint" }
    ];

    function ocspDecorateStorages(storages) {
        if (!Array.isArray(storages)) return storages;
        return storages.filter(function (item) {
            if (!item) return false;
            if (item.id === "S3Compatible") item.title = "S3-Compatible Object Storage";
            if (item.id === "S3") {
                if (!item.current && !item.isSet) return false;
                item.title = "Legacy Amazon S3";
            }
            return true;
        });
    }

    function ocspInjectProfileSelector($box) {
        var $s3 = $box.find(".storage[data-id='S3Compatible']");
        if (!$s3.length || $s3.find(".ocsp-profile-selector").length) return;
        var options = ocspProviderProfiles.map(function (p) {
            return '<option value="' + p.id + '">' + p.name + '</option>';
        }).join("");
        $s3.prepend(
            '<div class="flexContainer ocsp-profile-selector">' +
              '<span>Provider profile</span>' +
              '<select class="textBox ocsp-profile-select">' + options + '</select>' +
            '</div>' +
            '<div class="flexContainer fullWidth emptyMargin ocsp-profile-note">' +
              '<span>Profile selection does not activate storage. Enter provider values below, then use Connect only when ready to migrate.</span>' +
            '</div>'
        );

        var labels = {
            serviceurl: "Endpoint / service URL",
            region: "Region / signing region",
            bucket: "Bucket",
            cname: "Object base URL (HTTP)",
            cnamessl: "Object base URL (HTTPS)",
            forcepathstyle: "Force path-style addressing",
            usehttp: "Use HTTP",
            sse: "Encryption",
            ssekey: "Encryption key"
        };
        Object.keys(labels).forEach(function (key) {
            var $row = $s3.find("[data-id='" + key + "']");
            var $label = $row.children("span").first();
            if (!$label.length) $label = $row.find(".checkBox span").first();
            if ($label.length) $label.text(labels[key]);
        });
    }
    // END OCSP v0.3 S3Compatible Control Panel

'''
text = text.replace(anchor, helper + anchor, 1)
old = '                    var thirdPartyJSON = res[0];\n'
new = '                    var thirdPartyJSON = ocspDecorateStorages(res[0]);\n'
if text.count(old) != 1:
    raise SystemExit(f'expected one primary storage response assignment, got {text.count(old)}')
text = text.replace(old, new, 1)
old = '''        if (selected.properties && selected.properties.length && selected.current) {
            window.ConsumerStorageSettings.setProps($box, selected);
        }
    }

    function bindEvents() {
'''
new = '''        if (selected.properties && selected.properties.length && selected.current) {
            window.ConsumerStorageSettings.setProps($box, selected);
        }
        if ($box.is($storageSettingsBox)) {
            ocspInjectProfileSelector($box);
        }
    }

    function bindEvents() {
'''
if text.count(old) != 1:
    raise SystemExit(f'expected one initStorage tail anchor, got {text.count(old)}')
text = text.replace(old, new, 1)
for required in ("request = 'storage/updateStorage';", 'module: storage.id,', 'props: storage.params'):
    if required not in text:
        raise SystemExit('storage API contract missing after patch: ' + required)
# Selector has no data-id, therefore ConsumerStorageSettings.getProps will not serialise it.
if 'ocsp-profile-select' not in text or 'data-id="ocsp-profile' in text:
    raise SystemExit('profile selector safety assertion failed')
dst.write_text(text, encoding='utf-8')
PY
}

install_patch(){
  banner
  preflight_install
  local stamp backup path host_src host_dst meta root stock_icon_meta icon

  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  backup="$BACKUP_ROOT/v0.3-$stamp"
  TMP_DIR="$(mktemp -d /tmp/ocsp-v03.XXXXXX)"
  mkdir -p "$backup" "$STATE_DIR"
  chmod 700 "$backup" "$STATE_DIR"
  : >"$backup/$MANIFEST_NAME"
  chmod 600 "$backup/$MANIFEST_NAME"

  say "Backing up files to: $backup"

  # CommunityServer consumer configs
  for path in "${CONFIGS[@]}"; do
    backup_existing "$COMM" COMM "$path" "$backup"
    host_src="$TMP_DIR/$(echo "$path" | tr '/' '_').orig"
    host_dst="$TMP_DIR/$(echo "$path" | tr '/' '_').new"
    docker cp "$COMM:$path" "$host_src" >/dev/null
    patch_consumer_config "$host_src" "$host_dst"
    meta="$(meta_in "$COMM" "$path")"
    docker cp "$host_dst" "$COMM:$path" >/dev/null
    restore_meta "$COMM" "$path" "$meta"
  done

  # CommunityServer Third-Party Services presentation and dedicated icon
  for path in "${AUTH_FILES[@]}"; do
    backup_existing "$COMM" COMM "$path" "$backup"
    host_src="$TMP_DIR/$(echo "$path" | tr '/' '_').orig"
    host_dst="$TMP_DIR/$(echo "$path" | tr '/' '_').new"
    docker cp "$COMM:$path" "$host_src" >/dev/null
    patch_auth_js "$host_src" "$host_dst"
    meta="$(meta_in "$COMM" "$path")"
    docker cp "$host_dst" "$COMM:$path" >/dev/null
    restore_meta "$COMM" "$path" "$meta"
  done

  for root in "${ROOTS[@]}"; do
    icon="/var/www/onlyoffice/$root/$AUTH_IMG_REL/s3compatible.svg"
    docker exec "$COMM" test -d "$(dirname "$icon")" || continue
    host_dst="$TMP_DIR/s3compatible-$root.svg"
    write_neutral_icon "$host_dst"
    stock_icon_meta="$(meta_in "$COMM" "/var/www/onlyoffice/$root/$AUTH_IMG_REL/s3.svg")"
    docker cp "$host_dst" "$COMM:$icon" >/dev/null
    restore_meta "$COMM" "$icon" "$stock_icon_meta"
    record_delete COMM "$icon" "$backup"
  done

  # Control Panel Storage JS
  backup_existing "$CP" CP "$CP_STORAGE_JS" "$backup"
  host_src="$TMP_DIR/cp-storage.orig.js"
  host_dst="$TMP_DIR/cp-storage.new.js"
  docker cp "$CP:$CP_STORAGE_JS" "$host_src" >/dev/null
  patch_cp_storage_js "$host_src" "$host_dst"
  meta="$(meta_in "$CP" "$CP_STORAGE_JS")"
  docker cp "$host_dst" "$CP:$CP_STORAGE_JS" >/dev/null
  restore_meta "$CP" "$CP_STORAGE_JS" "$meta"

  # Control Panel views: teach Storage, Backup and Restore that S3Compatible
  # uses the stock S3 field template.
  for path in "${CP_VIEWS[@]}"; do
    backup_existing "$CP" CP "$path" "$backup"
    host_src="$TMP_DIR/$(basename "$path").orig"
    host_dst="$TMP_DIR/$(basename "$path").new"
    docker cp "$CP:$path" "$host_src" >/dev/null
    patch_cp_view "$host_src" "$host_dst"
    meta="$(meta_in "$CP" "$path")"
    docker cp "$host_dst" "$CP:$path" >/dev/null
    restore_meta "$CP" "$path" "$meta"
  done

  # Pre-restart verification
  for path in "${CONFIGS[@]}"; do consumer_present "$path" || die "S3Compatible missing after patch: $path"; done
  for path in "${AUTH_FILES[@]}"; do docker exec "$COMM" grep -Fq "$COMM_MARKER" "$path" || die "auth marker missing: $path"; done
  docker exec "$CP" grep -Fq "$CP_MARKER" "$CP_STORAGE_JS" || die "Control Panel marker missing"
  for path in "${CP_VIEWS[@]}"; do docker exec "$CP" grep -Fq 'id == "S3" || id == "S3Compatible"' "$path" || die "S3Compatible template condition missing: $path"; done

  cat >"$STATE_FILE" <<EOF
PATCH_VERSION=v0.3
COMMUNITYSERVER_IMAGE=$EXPECTED_COMM_IMAGE
CONTROL_PANEL_IMAGE=$EXPECTED_CP_IMAGE
BACKUP_DIR=$backup
INSTALLED_UTC=$stamp
EOF
  chmod 600 "$STATE_FILE"

  say "Restarting CommunityServer and Control Panel..."
  docker restart "$COMM" >/dev/null
  wait_container "$COMM"
  docker restart "$CP" >/dev/null
  wait_container "$CP"

  # Post-restart verification catches image entrypoints that regenerate files.
  mapfile -t POST_CONFIGS < <(community_configs)
  for path in "${POST_CONFIGS[@]}"; do consumer_present "$path" || die "S3Compatible did not survive restart in $path"; done
  docker exec "$CP" grep -Fq "$CP_MARKER" "$CP_STORAGE_JS" || die "Control Panel v0.3 patch did not survive restart"

  say
  say "PASS: v0.3 S3Compatible consumer installed."
  say "New internal consumer: S3Compatible"
  say "Reused backend: ASC.Data.Storage.S3.S3Storage"
  say "Legacy S3 consumer remains for backward compatibility."
  say "No storage API was called, no provider selected, and no migration started."
}

status(){
  banner
  preflight_common
  local path configs=0 present=0 auth_present=0
  mapfile -t STATUS_CONFIGS < <(community_configs)
  for path in "${STATUS_CONFIGS[@]}"; do
    configs=$((configs+1))
    if consumer_present "$path"; then present=$((present+1)); fi
  done
  mapfile -t STATUS_AUTH < <(auth_js_files)
  for path in "${STATUS_AUTH[@]}"; do
    if docker exec "$COMM" grep -Fq "$COMM_MARKER" "$path"; then auth_present=$((auth_present+1)); fi
  done

  say "Consumer configs with S3Compatible: $present / $configs"
  say "AuthorizationKeys copies with v0.3 presentation: $auth_present / ${#STATUS_AUTH[@]}"
  if docker exec "$CP" grep -Fq "$CP_MARKER" "$CP_STORAGE_JS" 2>/dev/null; then
    say "Control Panel v0.3 presentation: PRESENT"
  else
    say "Control Panel v0.3 presentation: absent"
  fi
  if [ -f "$STATE_FILE" ]; then
    say "Patch state: PRESENT ($STATE_FILE)"
    sed 's/^/  /' "$STATE_FILE"
  else
    say "Patch state: ABSENT"
  fi
  say
  say "No credentials are read and no storage API is called by status."
}

rollback_patch(){
  banner
  preflight_common
  [ -f "$STATE_FILE" ] || die "no v0.3 state file; refusing to guess rollback source"
  # shellcheck disable=SC1090
  source "$STATE_FILE"
  [ "${PATCH_VERSION:-}" = "v0.3" ] || die "state is not v0.3"
  [ -f "$BACKUP_DIR/$MANIFEST_NAME" ] || die "v0.3 backup manifest missing"

  say "Restoring v0.3 backups from: $BACKUP_DIR"
  while IFS=$'\t' read -r action label path meta; do
    case "$label" in COMM) container="$COMM";; CP) container="$CP";; *) die "unknown manifest container: $label";; esac
    case "$action" in
      RESTORE)
        src="$BACKUP_DIR/$label$path"
        [ -f "$src" ] || die "missing backup: $src"
        docker cp "$src" "$container:$path" >/dev/null
        restore_meta "$container" "$path" "$meta"
        ;;
      DELETE)
        docker exec "$container" rm -f "$path"
        ;;
      *) die "unknown manifest action: $action";;
    esac
  done <"$BACKUP_DIR/$MANIFEST_NAME"

  rm -f "$STATE_FILE"
  docker restart "$COMM" >/dev/null
  wait_container "$COMM"
  docker restart "$CP" >/dev/null
  wait_container "$CP"
  say "PASS: v0.3 rolled back to the pre-install files."
}

case "${1:-}" in
  install) install_patch ;;
  status) status ;;
  rollback) rollback_patch ;;
  *) echo "Usage: $0 {install|status|rollback}" >&2; exit 2 ;;
esac
