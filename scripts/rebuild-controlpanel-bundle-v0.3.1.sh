#!/usr/bin/env bash
set -euo pipefail

CP="${OCSP_CONTROL_PANEL_CONTAINER:-onlyoffice-control-panel}"
ROOT="/var/www/onlyoffice/controlpanel/www"
SRC="$ROOT/public/javascripts/views/storage.js"
STATE_DIR="/var/lib/onlyoffice-community-storage-profiles"
BACKUP_ROOT="/var/backups/onlyoffice-community-storage-profiles"
V031_STATE="$STATE_DIR/storage-profiles-v0.3.1.state"
MARKER='OCSP v0.3.1 provider catalogue'

say(){ printf '%s\n' "$*"; }
die(){ say "ERROR: $*" >&2; exit 1; }
wait_container(){
  local i
  for i in $(seq 1 90); do
    if [ "$(docker inspect -f '{{.State.Running}}' "$CP" 2>/dev/null || true)" = true ] && docker exec "$CP" true >/dev/null 2>&1; then return 0; fi
    sleep 2
  done
  die "$CP did not return to running state"
}

[ -f "$V031_STATE" ] || die "v0.3.1 state not found"
docker inspect "$CP" >/dev/null 2>&1 || die "container not found: $CP"
docker exec "$CP" test -f "$SRC" || die "patched storage.js missing"
docker exec "$CP" grep -Fq "$MARKER" "$SRC" || die "v0.3.1 provider marker missing from storage.js"
docker exec "$CP" node --check "$SRC" >/dev/null || die "storage.js syntax check failed"

mapfile -t bundles < <(docker exec "$CP" sh -lc "find '$ROOT/public/javascripts' -maxdepth 1 -type f -name 'combined.*.js' -print | sort")
[ "${#bundles[@]}" -eq 1 ] || die "expected exactly one Control Panel combined bundle; found ${#bundles[@]}"
BUNDLE="${bundles[0]}"

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
backup="$BACKUP_ROOT/v0.3.1-bundle-$stamp"
mkdir -p "$backup"; chmod 700 "$backup"

say "Control Panel bundle: $BUNDLE"
say "Backing up existing bundle to: $backup/$(basename "$BUNDLE")"
docker cp "$CP:$BUNDLE" "$backup/$(basename "$BUNDLE")" >/dev/null
chmod 600 "$backup/$(basename "$BUNDLE")"

old_sha="$(docker exec "$CP" sha256sum "$BUNDLE" | awk '{print $1}')"
say "Old bundle SHA256: $old_sha"

docker exec "$CP" rm -f "$BUNDLE"
say "Restarting $CP so production bundle is regenerated from patched sources..."
docker restart "$CP" >/dev/null
wait_container

for i in $(seq 1 90); do
  if docker exec "$CP" test -f "$BUNDLE" 2>/dev/null; then break; fi
  sleep 1
done
docker exec "$CP" test -f "$BUNDLE" || die "bundle did not regenerate: $BUNDLE"

new_sha="$(docker exec "$CP" sha256sum "$BUNDLE" | awk '{print $1}')"
say "New bundle SHA256: $new_sha"
[ "$new_sha" != "$old_sha" ] || say "WARNING: regenerated bundle SHA is unchanged"

docker exec "$CP" grep -Fq 'ocsp-s3-providers.json' "$BUNDLE" || die "provider catalogue loader missing from regenerated bundle"
docker exec "$CP" grep -Fq 'MEGA S4' "$BUNDLE" || die "MEGA S4 profile missing from regenerated bundle"
docker exec "$CP" grep -Fq 'ocsp-profile-select' "$BUNDLE" || die "provider selector missing from regenerated bundle"

say
say "PASS: Control Panel production bundle regenerated with v0.3.1 provider UI."
say "No storage API was called; no credentials or storage settings were read or changed."
