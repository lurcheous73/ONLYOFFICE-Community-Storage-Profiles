#!/usr/bin/env bash
set -euo pipefail

# ONLYOFFICE Community Storage Profiles
# Remove/rollback superseded v0.1, v0.2 and v0.2.1 developer experiments.
# This script does not call any ONLYOFFICE storage API and does not touch
# credentials or storage settings.

COMM="${OCSP_COMMUNITY_CONTAINER:-onlyoffice-community-server}"
CP="${OCSP_CONTROL_PANEL_CONTAINER:-onlyoffice-control-panel}"
STATE_DIR="/var/lib/onlyoffice-community-storage-profiles"

V01_STATE="$STATE_DIR/storage-profiles-v0.1.state"
V02_STATE="$STATE_DIR/storage-profiles-v0.2.state"
V021_STATE="$STATE_DIR/storage-profiles-v0.2.1-communityserver.state"

WEBSTUDIO="/var/www/onlyoffice/WebStudio/web.consumers.config"
TEAMLAB="/var/www/onlyoffice/Services/TeamLabSvc/web.consumers.config"
STORAGE_JS="/var/www/onlyoffice/controlpanel/www/public/javascripts/views/storage.js"

STOCK_CONSUMERS_SHA="e23a225eab3d17125a0c8961e2d842f385249a11d7a2bf1f13d3e2fc1f3ccc2b"
STOCK_CP_STORAGE_SHA="4d97712fb1b62b1da1fe6e0ff37488b7eb06310607faba54ffeaa8ac33dd821c"
STOCK_AUTH_JS_SHA="c6ba7611549a7a51514e44838d34118ed422422f4b7b86350dd58fe05f69c7e9"
STOCK_S3_SVG_SHA="30ba1bc79968aec04814949ac67351dc3d8f744b2cde38bbcbb8d2f057caece7"

ROOTS=(WebStudio WebStudio2 WebStudio3 WebStudio4)
AUTH_JS_REL="UserControls/Management/AuthorizationKeys/js/authorizationkeys.js"
S3_SVG_REL="UserControls/Management/AuthorizationKeys/img/s3.svg"

say(){ printf '%s\n' "$*"; }
die(){ say "ERROR: $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }
sha_in(){ docker exec "$1" sha256sum "$2" | awk '{print $1}'; }

restore_meta(){
  local container="$1" path="$2" meta="$3" uid gid mode rest
  [ -n "$meta" ] || return 0
  uid="${meta%%:*}"; rest="${meta#*:}"; gid="${rest%%:*}"; mode="${rest##*:}"
  docker exec "$container" chown "$uid:$gid" "$path"
  docker exec "$container" chmod "$mode" "$path"
}

wait_container(){
  local container="$1" i
  for i in $(seq 1 90); do
    if [ "$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null || true)" = "true" ] \
       && docker exec "$container" true >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  die "$container did not return to running state"
}

rollback_v01(){
  [ -f "$V01_STATE" ] || { say "v0.1: no active state"; return 0; }
  # shellcheck disable=SC1090
  source "$V01_STATE"
  case "${PATCH_VERSION:-}" in v0.1|v0.1.1) ;; *) die "unexpected v0.1 state version: ${PATCH_VERSION:-unset}";; esac
  [ -f "$BACKUP_DIR/WebStudio.web.consumers.config" ] || die "v0.1 WebStudio backup missing"
  [ -f "$BACKUP_DIR/TeamLabSvc.web.consumers.config" ] || die "v0.1 TeamLabSvc backup missing"

  say "v0.1: restoring stock consumer configs from $BACKUP_DIR"
  docker cp "$BACKUP_DIR/WebStudio.web.consumers.config" "$COMM:$WEBSTUDIO" >/dev/null
  docker cp "$BACKUP_DIR/TeamLabSvc.web.consumers.config" "$COMM:$TEAMLAB" >/dev/null
  restore_meta "$COMM" "$WEBSTUDIO" "${ORIGINAL_WEBSTUDIO_META:-}"
  restore_meta "$COMM" "$TEAMLAB" "${ORIGINAL_TEAMLAB_META:-}"
  [ "$(sha_in "$COMM" "$WEBSTUDIO")" = "$STOCK_CONSUMERS_SHA" ] || die "v0.1 WebStudio rollback hash mismatch"
  [ "$(sha_in "$COMM" "$TEAMLAB")" = "$STOCK_CONSUMERS_SHA" ] || die "v0.1 TeamLabSvc rollback hash mismatch"
  rm -f "$V01_STATE"
  RESTART_COMM=1
}

rollback_v02(){
  [ -f "$V02_STATE" ] || { say "v0.2: no active state"; return 0; }
  # shellcheck disable=SC1090
  source "$V02_STATE"
  [ "${PATCH_VERSION:-}" = "v0.2" ] || die "unexpected v0.2 state version: ${PATCH_VERSION:-unset}"
  [ -f "$BACKUP_DIR/storage.js" ] || die "v0.2 storage.js backup missing"

  say "v0.2: restoring stock Control Panel storage.js from $BACKUP_DIR"
  docker cp "$BACKUP_DIR/storage.js" "$CP:$STORAGE_JS" >/dev/null
  restore_meta "$CP" "$STORAGE_JS" "${ORIGINAL_STORAGE_JS_META:-}"
  [ "$(sha_in "$CP" "$STORAGE_JS")" = "$STOCK_CP_STORAGE_SHA" ] || die "v0.2 rollback hash mismatch"
  rm -f "$V02_STATE"
  RESTART_CP=1
}

rollback_v021(){
  [ -f "$V021_STATE" ] || { say "v0.2.1: no active state"; return 0; }
  # shellcheck disable=SC1090
  source "$V021_STATE"
  [ "${PATCH_VERSION:-}" = "v0.2.1" ] || die "unexpected v0.2.1 state version: ${PATCH_VERSION:-unset}"
  [ -f "$BACKUP_DIR/meta.tsv" ] || die "v0.2.1 metadata backup missing"

  local root js svg jsmeta svgmeta
  say "v0.2.1: restoring stock AuthorizationKeys assets from $BACKUP_DIR"
  for root in "${ROOTS[@]}"; do
    js="/var/www/onlyoffice/$root/$AUTH_JS_REL"
    svg="/var/www/onlyoffice/$root/$S3_SVG_REL"
    [ -f "$BACKUP_DIR/$root/authorizationkeys.js" ] || die "v0.2.1 JS backup missing for $root"
    [ -f "$BACKUP_DIR/$root/s3.svg" ] || die "v0.2.1 SVG backup missing for $root"
    jsmeta="$(awk -F '\t' -v r="$root" '$1==r{print $2}' "$BACKUP_DIR/meta.tsv")"
    svgmeta="$(awk -F '\t' -v r="$root" '$1==r{print $3}' "$BACKUP_DIR/meta.tsv")"
    docker cp "$BACKUP_DIR/$root/authorizationkeys.js" "$COMM:$js" >/dev/null
    docker cp "$BACKUP_DIR/$root/s3.svg" "$COMM:$svg" >/dev/null
    restore_meta "$COMM" "$js" "$jsmeta"
    restore_meta "$COMM" "$svg" "$svgmeta"
    [ "$(sha_in "$COMM" "$js")" = "$STOCK_AUTH_JS_SHA" ] || die "v0.2.1 JS rollback hash mismatch for $root"
    [ "$(sha_in "$COMM" "$svg")" = "$STOCK_S3_SVG_SHA" ] || die "v0.2.1 SVG rollback hash mismatch for $root"
  done
  rm -f "$V021_STATE"
  RESTART_COMM=1
}

status(){
  say "Superseded experiment state:"
  for f in "$V01_STATE" "$V02_STATE" "$V021_STATE"; do
    if [ -f "$f" ]; then say "  PRESENT: $f"; else say "  absent:  $f"; fi
  done
}

cleanup_all(){
  need docker
  docker inspect "$COMM" >/dev/null 2>&1 || die "missing container: $COMM"
  docker inspect "$CP" >/dev/null 2>&1 || die "missing container: $CP"
  RESTART_COMM=0
  RESTART_CP=0

  rollback_v01
  rollback_v02
  rollback_v021

  if [ "$RESTART_COMM" -eq 1 ]; then
    say "Restarting $COMM..."
    docker restart "$COMM" >/dev/null
    wait_container "$COMM"
  fi
  if [ "$RESTART_CP" -eq 1 ]; then
    say "Restarting $CP..."
    docker restart "$CP" >/dev/null
    wait_container "$CP"
  fi

  say
  status
  say
  say "PASS: superseded OCSP experiments are rolled back."
  say "No storage API was called; no credentials or storage settings were changed."
}

case "${1:-cleanup}" in
  cleanup) cleanup_all ;;
  status) status ;;
  *) echo "Usage: $0 {cleanup|status}" >&2; exit 2 ;;
esac
