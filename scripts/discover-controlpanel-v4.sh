#!/usr/bin/env bash
set -euo pipefail

# ONLYOFFICE Community Storage Profiles
# Control Panel / S3 placeholder discovery v4
# READ ONLY — makes no changes to containers or host configuration.

COMM="${OCSP_COMMUNITY_CONTAINER:-onlyoffice-community-server}"

say() { printf '%s\n' "$*"; }

banner() {
  cat <<'EOF'
====================================================================
 ONLYOFFICE Community Storage Profiles — Control Panel discovery v4
 READ ONLY
====================================================================
EOF
}

banner

command -v docker >/dev/null 2>&1 || { echo "ERROR: docker not found" >&2; exit 1; }

say
say "=== 1. RUNNING ONLYOFFICE-RELATED CONTAINERS ==="
docker ps --format '{{.Names}}\t{{.Image}}' | grep -Ei 'onlyoffice|control.?panel' || true

say
say "=== 2. LOCATE CONTROL PANEL STORAGE FILES ==="

mapfile -t containers < <(docker ps --format '{{.Names}}')
cp_container=""

for c in "${containers[@]}"; do
  # Prefer a cheap existence search in common application roots.
  found="$(docker exec "$c" sh -lc '
    for root in /var/www /app /usr/src /opt; do
      [ -d "$root" ] || continue
      find "$root" -maxdepth 8 -type f \
        \( -path "*/public/javascripts/views/storage.js" -o -path "*/views/storage.pug" \) \
        2>/dev/null | head -5
    done
  ' 2>/dev/null || true)"

  if [ -n "$found" ]; then
    say "Candidate container: $c"
    printf '%s\n' "$found" | sed 's/^/  /'
    if printf '%s\n' "$found" | grep -q '/public/javascripts/views/storage.js'; then
      cp_container="$c"
      break
    fi
  fi
done

if [ -z "$cp_container" ]; then
  say "ERROR: could not locate the Control Panel storage.js in any running container."
  say "Nothing modified."
  exit 1
fi

say
say "Selected Control Panel container: $cp_container"

find_one() {
  local pattern="$1"
  docker exec "$cp_container" sh -lc "
    for root in /var/www /app /usr/src /opt; do
      [ -d \"\$root\" ] || continue
      find \"\$root\" -maxdepth 9 -type f -path '$pattern' 2>/dev/null | head -1
    done
  "
}

STORAGE_JS="$(find_one '*/public/javascripts/views/storage.js')"
STORAGE_PUG="$(find_one '*/views/storage.pug')"
CONSUMER_PUG="$(find_one '*/views/consumerSettingsPartial.pug')"
STORAGE_CONTROLLER="$(find_one '*/app/controllers/storage.js')"
CONTROL_RESOURCE="$(find_one '*/public/resources/ControlPanelResource.json')"

say
say "=== 3. CONTROL PANEL FILE MAP ==="
printf '%-24s %s\n' 'storage.js:' "${STORAGE_JS:-NOT FOUND}"
printf '%-24s %s\n' 'storage.pug:' "${STORAGE_PUG:-NOT FOUND}"
printf '%-24s %s\n' 'consumerSettingsPartial:' "${CONSUMER_PUG:-NOT FOUND}"
printf '%-24s %s\n' 'storage controller:' "${STORAGE_CONTROLLER:-NOT FOUND}"
printf '%-24s %s\n' 'resource JSON:' "${CONTROL_RESOURCE:-NOT FOUND}"

say
say "=== 4. CONTROL PANEL VERSION HINTS ==="
docker exec "$cp_container" sh -lc '
  for f in \
    /var/www/onlyoffice/controlpanel/package.json \
    /var/www/onlyoffice/ControlPanel/package.json \
    /app/package.json \
    /usr/src/app/package.json; do
    if [ -f "$f" ]; then
      echo "--- $f"
      grep -E '"(name|version)"[[:space:]]*:' "$f" | head -4
    fi
  done
  find /var/www /app /usr/src /opt -maxdepth 6 -type f -name package.json 2>/dev/null \
    | grep -Ei 'control|onlyoffice' \
    | head -10 \
    | while read -r f; do
        echo "--- $f"
        grep -E '"(name|version)"[[:space:]]*:' "$f" | head -4
      done
' 2>/dev/null || true

say
say "=== 5. LIVE FILE HASHES / METADATA ==="
for f in "$STORAGE_JS" "$STORAGE_PUG" "$CONSUMER_PUG" "$STORAGE_CONTROLLER" "$CONTROL_RESOURCE"; do
  [ -n "$f" ] || continue
  docker exec "$cp_container" sh -lc "sha256sum '$f'; stat -c 'META %u:%g:%a %n' '$f'" 2>/dev/null || true
done

say
say "=== 6. STORAGE.JS S3 / API CONTEXT ==="
if [ -n "$STORAGE_JS" ]; then
  docker exec "$cp_container" sh -lc "grep -nE 'getAllStorages|thirdPartyJSON|initStorages|consumerSettingsTmpl|updateStorage|radioBox|S3' '$STORAGE_JS' | head -120" || true
fi

say
say "=== 7. CONTROL PANEL S3 TEMPLATE CONTEXT ==="
if [ -n "$CONSUMER_PUG" ]; then
  docker exec "$cp_container" sh -lc "grep -nE 'consumerItemS3Tmpl|region|forcepathstyle|usehttp|sse|ssekey' '$CONSUMER_PUG' | head -160" || true
fi

say
say "=== 8. CONTROL PANEL RESOURCE STRINGS ==="
if [ -n "$CONTROL_RESOURCE" ]; then
  docker exec "$cp_container" sh -lc "grep -nE 'Amazon AWS S3|Connect storage for static data|storage as CDN|S3' '$CONTROL_RESOURCE' | head -120" || true
fi

say
say "=== 9. COMMUNITYSERVER AUTHORIZATION UI FILES ==="
if docker inspect "$COMM" >/dev/null 2>&1; then
  AUTH_ASC='/var/www/onlyoffice/WebStudio/UserControls/Management/AuthorizationKeys/AuthorizationKeys.ascx'
  AUTH_CS='/var/www/onlyoffice/WebStudio/UserControls/Management/AuthorizationKeys/AuthorizationKeys.ascx.cs'
  for f in "$AUTH_ASC" "$AUTH_CS"; do
    if docker exec "$COMM" test -f "$f"; then
      docker exec "$COMM" sh -lc "sha256sum '$f'; stat -c 'META %u:%g:%a %n' '$f'"
    else
      say "NOT FOUND: $f"
    fi
  done

  if docker exec "$COMM" test -f "$AUTH_ASC"; then
    say
    say "--- AuthorizationKeys S3/title rendering context"
    docker exec "$COMM" sh -lc "grep -nE 'service.Title|service.Description|service.Instruction|service.Name' '$AUTH_ASC' | head -100" || true
  fi
else
  say "CommunityServer container not found: $COMM"
fi

say
say "=== 10. V0.1 EXPERIMENT STATE ==="
STATE='/var/lib/onlyoffice-community-storage-profiles/storage-profiles-v0.1.state'
if [ -f "$STATE" ]; then
  say "v0.1 state: PRESENT"
  sed 's/^/  /' "$STATE"
else
  say "v0.1 state: ABSENT"
fi

say
say "===================================================================="
say " V4 COMPLETE — NOTHING MODIFIED"
say "===================================================================="
