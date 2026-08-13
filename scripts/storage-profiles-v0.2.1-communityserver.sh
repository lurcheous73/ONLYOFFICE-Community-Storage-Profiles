#!/usr/bin/env bash
set -euo pipefail

# ONLYOFFICE Community Storage Profiles
# v0.2.1 developer preview — CommunityServer Third-Party Services presentation
#
# Purpose:
#   Replace the user-facing Amazon-specific S3 branding in CommunityServer's
#   Authorization Keys / Third-Party Services page with the generic
#   "S3-Compatible Object Storage" presentation while preserving the stable
#   internal consumer identity "S3" and the existing credential save path.
#
# This script:
#   * DOES NOT modify ASC.Web.Studio.dll.
#   * DOES NOT modify web.consumers.config.
#   * DOES NOT call any storage API.
#   * DOES NOT read or write storage credentials.
#   * DOES NOT start storage migration.
#   * Patches only AuthorizationKeys presentation JS and the S3 icon asset.
#
# Supported operations:
#   install | status | rollback

COMM="${OCSP_COMMUNITY_CONTAINER:-onlyoffice-community-server}"
EXPECTED_IMAGE="onlyoffice/communityserver:12.8.0.1971"
EXPECTED_JS_SHA="c6ba7611549a7a51514e44838d34118ed422422f4b7b86350dd58fe05f69c7e9"
EXPECTED_SVG_SHA="30ba1bc79968aec04814949ac67351dc3d8f744b2cde38bbcbb8d2f057caece7"

ROOTS=(WebStudio WebStudio2 WebStudio3 WebStudio4)
BASE="/var/www/onlyoffice"
JS_REL="UserControls/Management/AuthorizationKeys/js/authorizationkeys.js"
SVG_REL="UserControls/Management/AuthorizationKeys/img/s3.svg"

BACKUP_ROOT="/var/backups/onlyoffice-community-storage-profiles"
STATE_DIR="/var/lib/onlyoffice-community-storage-profiles"
STATE_FILE="$STATE_DIR/storage-profiles-v0.2.1-communityserver.state"
MARKER="OCSP v0.2.1 S3-Compatible Object Storage branding"
TMP_DIR=""

say(){ printf '%s\n' "$*"; }
die(){ say "ERROR: $*" >&2; exit 1; }

cleanup(){
  if [ -n "${TMP_DIR:-}" ] && [ -d "$TMP_DIR" ]; then
    rm -rf -- "$TMP_DIR"
  fi
}
trap cleanup EXIT

banner(){
  cat <<'EOF'
====================================================================
 ONLYOFFICE Community Storage Profiles — v0.2.1 developer preview
 CommunityServer S3-Compatible Object Storage branding
====================================================================
EOF
}

need(){ command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

container_ok(){
  docker inspect "$COMM" >/dev/null 2>&1 || die "container not found: $COMM"
  [ "$(docker inspect -f '{{.State.Running}}' "$COMM" 2>/dev/null)" = "true" ] || die "container is not running: $COMM"
  local image
  image="$(docker inspect -f '{{.Config.Image}}' "$COMM")"
  say "CommunityServer container: $COMM"
  say "Detected image:           $image"
  say "Expected image:           $EXPECTED_IMAGE"
  [ "$image" = "$EXPECTED_IMAGE" ] || die "unsupported CommunityServer image; refusing to patch"
}

sha_live(){ docker exec "$COMM" sha256sum "$1" | awk '{print $1}'; }
meta_live(){ docker exec "$COMM" stat -c '%u:%g:%a' "$1"; }

restore_meta(){
  local path="$1" meta="$2" uid gid mode rest
  uid="${meta%%:*}"
  rest="${meta#*:}"
  gid="${rest%%:*}"
  mode="${rest##*:}"
  docker exec "$COMM" chown "$uid:$gid" "$path"
  docker exec "$COMM" chmod "$mode" "$path"
}

preflight(){
  need docker
  need python3
  need sha256sum
  container_ok

  local root js svg
  for root in "${ROOTS[@]}"; do
    js="$BASE/$root/$JS_REL"
    svg="$BASE/$root/$SVG_REL"
    docker exec "$COMM" test -f "$js" || die "missing expected JS: $js"
    docker exec "$COMM" test -f "$svg" || die "missing expected SVG: $svg"
  done
}

has_marker(){
  local root js
  for root in "${ROOTS[@]}"; do
    js="$BASE/$root/$JS_REL"
    docker exec "$COMM" grep -Fq "$MARKER" "$js" || return 1
  done
  return 0
}

patch_js(){
  local src="$1" dst="$2"
  python3 - "$src" "$dst" <<'PY'
import sys
from pathlib import Path

src = Path(sys.argv[1])
dst = Path(sys.argv[2])
with src.open('r', encoding='utf-8', newline='') as f:
    text = f.read()

marker = 'OCSP v0.2.1 S3-Compatible Object Storage branding'
if marker in text:
    raise SystemExit('v0.2.1 marker already present')

nl = '\r\n' if '\r\n' in text else '\n'
anchor = '    function init() {' + nl
if text.count(anchor) != 1:
    raise SystemExit(f'expected exactly one init() anchor, found {text.count(anchor)}')

lines = [
'    // BEGIN OCSP v0.2.1 S3-Compatible Object Storage branding',
'    // Presentation only: the internal consumer name remains "S3".',
'    function ocspDecorateS3Consumer() {',
'        var switcher = jq("#switcherBtnS3");',
'        if (!switcher.length) return;',
'',
'        var tile = switcher.closest(".auth-service-item");',
'        tile.attr("data-ocsp-storage-profile", "s3-compatible");',
'        tile.find(".auth-service-img").attr("alt", "S3-Compatible Object Storage");',
'        tile.find(".auth-service-dscr").first().text(',
'            "Connect S3-compatible object storage for portal storage and backups."',
'        );',
'',
'        var popup = jq("#popupDialogS3");',
'        popup.find(".containerHeaderBlock td").first().text("S3-Compatible Object Storage");',
'        popup.find(".auth-service-img").attr("alt", "S3-Compatible Object Storage");',
'',
'        var instruction = popup.find(".popup-info-block").first();',
'        if (instruction.length) {',
'            instruction.text(',
'                "Enter the access key and secret access key for your selected S3-compatible provider. " +',
'                "Endpoint, region, bucket and addressing settings are configured in Storage Profiles."',
'            );',
'        }',
'',
'        var accessKey = popup.find("#acesskey");',
'        if (accessKey.length) {',
'            accessKey.prev(".headerPanelSmall").text("Access key:");',
'            accessKey.attr("placeholder", "Access key");',
'        }',
'',
'        var secretKey = popup.find("#secretaccesskey");',
'        if (secretKey.length) {',
'            secretKey.prev(".headerPanelSmall").text("Secret access key:");',
'            secretKey.attr("placeholder", "Secret access key");',
'        }',
'    }',
'    // END OCSP v0.2.1 S3-Compatible Object Storage branding',
'',
]
helper = nl.join(lines) + nl
text = text.replace(anchor, helper + anchor, 1)

call_anchor = '    function init() {' + nl
call = '        ocspDecorateS3Consumer();' + nl
text = text.replace(call_anchor, call_anchor + call, 1)

for required in (
    'save(itemName, true);',
    'window.AuthorizationKeys.SaveAuthKeys(itemName, props,',
    'jq("#popupDialog" + itemName + " .auth-service-key")',
):
    if required not in text:
        raise SystemExit(f'required stock credential contract missing after patch: {required}')

if marker not in text or 'ocspDecorateS3Consumer();' not in text:
    raise SystemExit('post-transform marker/call verification failed')

with dst.open('w', encoding='utf-8', newline='') as f:
    f.write(text)
PY
}

write_neutral_svg(){
  local dst="$1"
  cat >"$dst" <<'SVG'
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

status(){
  banner
  preflight
  say
  local root js svg js_sha svg_sha
  for root in "${ROOTS[@]}"; do
    js="$BASE/$root/$JS_REL"
    svg="$BASE/$root/$SVG_REL"
    js_sha="$(sha_live "$js")"
    svg_sha="$(sha_live "$svg")"
    printf '%-10s JS=%s  SVG=%s\n' "$root" "$js_sha" "$svg_sha"
  done
  say
  if has_marker; then
    say "CommunityServer S3 presentation: S3-COMPATIBLE BRANDING PRESENT"
  else
    say "CommunityServer S3 presentation: STOCK"
  fi
  if [ -f "$STATE_FILE" ]; then
    say "Patch state: PRESENT ($STATE_FILE)"
    sed 's/^/  /' "$STATE_FILE"
  else
    say "Patch state: ABSENT"
  fi
  say
  say "No credential values are read or displayed by this command."
}

install_patch(){
  banner
  preflight

  if has_marker; then
    say "v0.2.1 marker already present in all WebStudio trees; no changes made."
    exit 0
  fi

  local root js svg js_sha svg_sha stamp backup jsmeta svgmeta
  for root in "${ROOTS[@]}"; do
    js="$BASE/$root/$JS_REL"
    svg="$BASE/$root/$SVG_REL"
    js_sha="$(sha_live "$js")"
    svg_sha="$(sha_live "$svg")"
    [ "$js_sha" = "$EXPECTED_JS_SHA" ] || die "$root authorizationkeys.js differs from tested baseline; refusing to patch ($js_sha)"
    [ "$svg_sha" = "$EXPECTED_SVG_SHA" ] || die "$root s3.svg differs from tested baseline; refusing to patch ($svg_sha)"
  done

  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  backup="$BACKUP_ROOT/v0.2.1-communityserver-$stamp"
  TMP_DIR="$(mktemp -d /tmp/ocsp-v021.XXXXXX)"
  mkdir -p "$backup" "$STATE_DIR"
  chmod 700 "$backup" "$STATE_DIR"

  say "Backing up all four AuthorizationKeys presentation copies to: $backup"

  : >"$TMP_DIR/meta.tsv"
  for root in "${ROOTS[@]}"; do
    js="$BASE/$root/$JS_REL"
    svg="$BASE/$root/$SVG_REL"
    mkdir -p "$backup/$root" "$TMP_DIR/$root"

    jsmeta="$(meta_live "$js")"
    svgmeta="$(meta_live "$svg")"
    printf '%s\t%s\t%s\n' "$root" "$jsmeta" "$svgmeta" >>"$TMP_DIR/meta.tsv"

    docker cp "$COMM:$js" "$backup/$root/authorizationkeys.js"
    docker cp "$COMM:$svg" "$backup/$root/s3.svg"
    chmod 600 "$backup/$root/authorizationkeys.js" "$backup/$root/s3.svg"

    docker cp "$COMM:$js" "$TMP_DIR/$root/authorizationkeys.original.js"
    patch_js "$TMP_DIR/$root/authorizationkeys.original.js" "$TMP_DIR/$root/authorizationkeys.patched.js"
    write_neutral_svg "$TMP_DIR/$root/s3.patched.svg"
  done

  say "Installing generic S3-Compatible presentation..."
  for root in "${ROOTS[@]}"; do
    js="$BASE/$root/$JS_REL"
    svg="$BASE/$root/$SVG_REL"
    jsmeta="$(awk -F '\t' -v r="$root" '$1==r{print $2}' "$TMP_DIR/meta.tsv")"
    svgmeta="$(awk -F '\t' -v r="$root" '$1==r{print $3}' "$TMP_DIR/meta.tsv")"

    docker cp "$TMP_DIR/$root/authorizationkeys.patched.js" "$COMM:$js"
    docker cp "$TMP_DIR/$root/s3.patched.svg" "$COMM:$svg"
    restore_meta "$js" "$jsmeta"
    restore_meta "$svg" "$svgmeta"
  done

  has_marker || die "post-install JS marker verification failed"

  cp "$TMP_DIR/meta.tsv" "$backup/meta.tsv"
  chmod 600 "$backup/meta.tsv"
  cat >"$STATE_FILE" <<EOF
PATCH_VERSION=v0.2.1
COMMUNITYSERVER_IMAGE=$EXPECTED_IMAGE
BACKUP_DIR=$backup
ORIGINAL_JS_SHA=$EXPECTED_JS_SHA
ORIGINAL_SVG_SHA=$EXPECTED_SVG_SHA
INSTALLED_UTC=$stamp
EOF
  chmod 600 "$STATE_FILE"

  say "Restarting $COMM so the AuthorizationKeys presentation is reloaded..."
  docker restart "$COMM" >/dev/null

  say
  say "PASS: CommunityServer S3-Compatible Object Storage branding installed."
  say "Internal consumer id remains S3; credential save code is unchanged."
  say "No storage API was called and no migration was started."
}

rollback_patch(){
  banner
  preflight
  [ -f "$STATE_FILE" ] || die "no v0.2.1 CommunityServer state file found; refusing to guess rollback source"
  # shellcheck disable=SC1090
  source "$STATE_FILE"
  [ "${PATCH_VERSION:-}" = "v0.2.1" ] || die "state file is not for v0.2.1"
  [ -n "${BACKUP_DIR:-}" ] || die "BACKUP_DIR missing from state"
  [ -f "$BACKUP_DIR/meta.tsv" ] || die "backup metadata missing"

  local root js svg jsmeta svgmeta
  for root in "${ROOTS[@]}"; do
    [ -f "$BACKUP_DIR/$root/authorizationkeys.js" ] || die "missing JS backup for $root"
    [ -f "$BACKUP_DIR/$root/s3.svg" ] || die "missing SVG backup for $root"
    js="$BASE/$root/$JS_REL"
    svg="$BASE/$root/$SVG_REL"
    jsmeta="$(awk -F '\t' -v r="$root" '$1==r{print $2}' "$BACKUP_DIR/meta.tsv")"
    svgmeta="$(awk -F '\t' -v r="$root" '$1==r{print $3}' "$BACKUP_DIR/meta.tsv")"

    docker cp "$BACKUP_DIR/$root/authorizationkeys.js" "$COMM:$js"
    docker cp "$BACKUP_DIR/$root/s3.svg" "$COMM:$svg"
    restore_meta "$js" "$jsmeta"
    restore_meta "$svg" "$svgmeta"

    [ "$(sha_live "$js")" = "$EXPECTED_JS_SHA" ] || die "rollback JS hash verification failed for $root"
    [ "$(sha_live "$svg")" = "$EXPECTED_SVG_SHA" ] || die "rollback SVG hash verification failed for $root"
  done

  rm -f "$STATE_FILE"
  docker restart "$COMM" >/dev/null
  say "PASS: stock CommunityServer AuthorizationKeys S3 presentation restored."
}

case "${1:-}" in
  install) install_patch ;;
  status) status ;;
  rollback) rollback_patch ;;
  *) echo "Usage: $0 {install|status|rollback}" >&2; exit 2 ;;
esac
