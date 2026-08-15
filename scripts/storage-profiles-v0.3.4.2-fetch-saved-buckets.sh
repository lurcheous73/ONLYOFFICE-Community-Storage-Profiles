#!/usr/bin/env bash
set -euo pipefail

# OCSP v0.3.4.2 — manual backup UI hotfix.
# Reuse the S3Compatible credentials already saved under Third-Party Services,
# fetch the available buckets, and hide the internal backupchunksize field.
# No backup, restore, migration, schedule or S3 operation is started here.

CP="${OCSP_CONTROL_PANEL_CONTAINER:-onlyoffice-control-panel}"
EXPECTED_CP_IMAGE="onlyoffice/controlpanel:3.5.5.549"
ROOT="/var/www/onlyoffice/controlpanel/www"
UI="$ROOT/public/javascripts/views/ocsp-manual-s3-backup.js"
STATE_DIR="/var/lib/onlyoffice-community-storage-profiles"
BACKUP_ROOT="/var/backups/onlyoffice-community-storage-profiles"
V034_STATE="$STATE_DIR/storage-profiles-v0.3.4-manual-backup.state"
STATE_FILE="$STATE_DIR/storage-profiles-v0.3.4.2-fetch-buckets.state"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
SOURCE="$REPO_ROOT/patches/v0.3.4/controlpanel-manual-s3-backup.js"

say(){ printf '%s\n' "$*"; }
die(){ say "ERROR: $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

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

latest_partial_backup(){
  local p
  p="$(find "$BACKUP_ROOT" -maxdepth 1 -type d -name 'v0.3.4.2-fetch-buckets-*' -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk 'NR==1{sub(/^[^ ]+ /,""); print; exit}')"
  [ -n "$p" ] && printf '%s\n' "$p"
}

install_cmd(){
  need docker; need sha256sum
  [ -f "$SOURCE" ] || die "missing source: $SOURCE"
  [ -f "$V034_STATE" ] || die "v0.3.4 base install state missing"
  [ ! -f "$STATE_FILE" ] || die "v0.3.4.2 already installed; use status or rollback"
  docker inspect "$CP" >/dev/null 2>&1 || die "container not found: $CP"
  [ "$(docker inspect -f '{{.Config.Image}}' "$CP")" = "$EXPECTED_CP_IMAGE" ] \
    || die "unsupported Control Panel image: $(docker inspect -f '{{.Config.Image}}' "$CP")"
  docker exec "$CP" test -f "$UI" || die "v0.3.4 UI module missing: $UI"

  docker exec "$CP" node --check "$UI" >/dev/null

  local bundle stamp backup meta uid gid mode rest oldsha newsha ready=0 partial=0
  bundle="$(bundle_path)"
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"

  # A previous v0.3.4.2 attempt may have copied the source and rebuilt the
  # production bundle, then failed only because the readiness probe looked for
  # a source comment. Production minification strips comments, so that was a
  # false negative. Reuse the original pre-hotfix backup instead of taking a
  # second backup of the already-hotfixed files.
  if docker exec "$CP" grep -Fq 'OCSP v0.3.4.2' "$UI" 2>/dev/null; then
    partial=1
    backup="$(latest_partial_backup || true)"
    [ -n "$backup" ] || die "partial v0.3.4.2 deploy detected but original backup directory was not found"
    [ -f "$backup/ocsp-manual-s3-backup.js" ] || die "partial retry UI backup missing: $backup"
    [ -f "$backup/$(basename "$bundle")" ] || die "partial retry bundle backup missing: $backup"
    say "Detected prior partial v0.3.4.2 deploy; reusing original rollback snapshot: $backup"
    oldsha="$(sha256sum "$backup/$(basename "$bundle")" | awk '{print $1}')"
  else
    backup="$BACKUP_ROOT/v0.3.4.2-fetch-buckets-$stamp"
    mkdir -p "$backup" "$STATE_DIR"; chmod 700 "$backup" "$STATE_DIR"

    say "Backing up current v0.3.4 UI and production bundle to: $backup"
    docker cp "$CP:$UI" "$backup/ocsp-manual-s3-backup.js" >/dev/null
    docker cp "$CP:$bundle" "$backup/$(basename "$bundle")" >/dev/null
    chmod 600 "$backup/ocsp-manual-s3-backup.js" "$backup/$(basename "$bundle")"
    oldsha="$(docker exec "$CP" sha256sum "$bundle" | awk '{print $1}')"
  fi

  meta="$(docker exec "$CP" stat -c '%u:%g:%a' "$UI")"
  uid="${meta%%:*}"; rest="${meta#*:}"; gid="${rest%%:*}"; mode="${rest##*:}"

  docker cp "$SOURCE" "$CP:$UI" >/dev/null
  docker exec "$CP" chown "$uid:$gid" "$UI"
  docker exec "$CP" chmod "$mode" "$UI"
  docker exec "$CP" node --check "$UI" >/dev/null || die "v0.3.4.2 UI syntax check failed"
  docker exec "$CP" grep -Fq 'OCSP v0.3.4.2' "$UI" || die "v0.3.4.2 source marker missing"
  docker exec "$CP" grep -Fq 'Check connection & fetch buckets' "$UI" || die "bucket-fetch UI marker missing"

  say "Rebuilding Control Panel production bundle..."
  docker exec "$CP" rm -f "$bundle"
  docker restart "$CP" >/dev/null
  wait_cp

  # Do not look for the source comment in the minified production bundle:
  # bundle generation strips comments. Check runtime strings that must survive
  # minification instead.
  for i in $(seq 1 120); do
    if docker exec "$CP" test -f "$bundle" >/dev/null 2>&1 \
       && docker exec "$CP" grep -aFq 'Check connection & fetch buckets' "$bundle" >/dev/null 2>&1 \
       && docker exec "$CP" grep -aFq '/Management.aspx?type=ThirdPartyAuthorization' "$bundle" >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 1
  done
  [ "$ready" = 1 ] || die "production bundle never reached v0.3.4.2 runtime state"

  newsha="$(docker exec "$CP" sha256sum "$bundle" | awk '{print $1}')"

  mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
  cat >"$STATE_FILE" <<EOF
VERSION=0.3.4.2-fetch-saved-buckets
BACKUP=$backup
BUNDLE=$bundle
INSTALLED_UTC=$stamp
OLD_BUNDLE_SHA256=$oldsha
NEW_BUNDLE_SHA256=$newsha
PARTIAL_RETRY=$partial
EOF
  chmod 600 "$STATE_FILE"

  say "Control Panel bundle SHA256: $oldsha -> $newsha"
  say
  say "PASS — v0.3.4.2 saved-key bucket fetch UI installed."
  say "  Check Connection now reuses saved S3Compatible keys from Third-Party Services when the manual form is blank."
  say "  The saved secret is used transiently in the authenticated browser request and is not stored by this patch."
  say "  Check Connection fetches bucket names; create/select/100 KiB validation remain gated as before."
  say "  Internal backupchunksize is hidden from the manual UI."
  say "  No backup, restore, storage migration, schedule, cron or S3 request was started by this installer."
}

status_cmd(){
  need docker
  [ -f "$STATE_FILE" ] || die "v0.3.4.2 state absent"
  local bundle
  bundle="$(sed -n 's/^BUNDLE=//p' "$STATE_FILE" | head -1)"
  docker exec "$CP" grep -Fq 'OCSP v0.3.4.2' "$UI" || die "v0.3.4.2 UI source marker missing"
  docker exec "$CP" grep -Fq 'Check connection & fetch buckets' "$UI" || die "bucket-fetch source marker missing"
  docker exec "$CP" grep -aFq 'Check connection & fetch buckets' "$bundle" || die "v0.3.4.2 bundle runtime string missing"
  docker exec "$CP" grep -aFq '/Management.aspx?type=ThirdPartyAuthorization' "$bundle" || die "v0.3.4.2 saved-key runtime string missing"
  say "PASS — v0.3.4.2 saved-key bucket fetch UI present."
}

rollback_cmd(){
  need docker
  [ -f "$STATE_FILE" ] || die "v0.3.4.2 state absent"
  local backup bundle meta uid gid mode rest
  backup="$(sed -n 's/^BACKUP=//p' "$STATE_FILE" | head -1)"
  bundle="$(sed -n 's/^BUNDLE=//p' "$STATE_FILE" | head -1)"
  [ -f "$backup/ocsp-manual-s3-backup.js" ] || die "UI rollback file missing"
  [ -f "$backup/$(basename "$bundle")" ] || die "bundle rollback file missing"

  meta="$(docker exec "$CP" stat -c '%u:%g:%a' "$UI")"
  uid="${meta%%:*}"; rest="${meta#*:}"; gid="${rest%%:*}"; mode="${rest##*:}"
  docker cp "$backup/ocsp-manual-s3-backup.js" "$CP:$UI" >/dev/null
  docker exec "$CP" chown "$uid:$gid" "$UI"
  docker exec "$CP" chmod "$mode" "$UI"
  docker cp "$backup/$(basename "$bundle")" "$CP:$bundle" >/dev/null
  rm -f "$STATE_FILE"
  docker restart "$CP" >/dev/null
  wait_cp
  say "PASS — v0.3.4.2 rolled back to the exact pre-hotfix UI/bundle."
}

case "${1:-status}" in
  install) install_cmd ;;
  status) status_cmd ;;
  rollback) rollback_cmd ;;
  *) die "usage: $0 {install|status|rollback}" ;;
esac
