#!/usr/bin/env bash
set -euo pipefail

COMM="${OCSP_COMMUNITY_CONTAINER:-onlyoffice-community-server}"

say(){ printf '%s\n' "$*"; }

cat <<'EOF'
====================================================================
 ONLYOFFICE Community Storage Profiles — CommunityServer auth UI v5
 READ ONLY
====================================================================
EOF

command -v docker >/dev/null 2>&1 || { echo "ERROR: docker not found" >&2; exit 1; }
docker inspect "$COMM" >/dev/null 2>&1 || { echo "ERROR: container not found: $COMM" >&2; exit 1; }

say
say "=== 1. CONTAINER / IMAGE ==="
docker inspect -f 'NAME={{.Name}} IMAGE={{.Config.Image}} RUNNING={{.State.Running}}' "$COMM"

say
say "=== 2. AUTHORIZATIONKEYS FILES ==="
docker exec "$COMM" sh -lc '
  find /var/www/onlyoffice -type f \
    \( -iname "*authorizationkeys*" -o -path "*/AuthorizationKeys/*" \) \
    2>/dev/null | sort | head -200
' || true

say
say "=== 3. S3/AWS ICON FILES ==="
docker exec "$COMM" sh -lc '
  find /var/www/onlyoffice -type f \
    \( -iname "s3.svg" -o -iname "*amazon*.svg" -o -iname "*aws*.svg" \) \
    2>/dev/null | sort | head -100
' || true

say
say "=== 4. FILES CONTAINING AMAZON AWS S3 TEXT ==="
docker exec "$COMM" sh -lc '
  grep -RIl --binary-files=without-match "Amazon AWS S3" /var/www/onlyoffice 2>/dev/null | head -100
' || true

say
say "=== 5. AUTHORIZATION JS CONTEXT ==="
docker exec "$COMM" sh -lc '
  for f in $(find /var/www/onlyoffice -type f -iname "authorizationkeys.js" 2>/dev/null | head -20); do
    echo "--- $f"
    sha256sum "$f"
    stat -c "META %u:%g:%a %n" "$f"
    grep -nE "switcherBtn|saveBtn|auth-service|popupDialog|S3" "$f" | head -160 || true
  done
' || true

say
say "=== 6. S3 ICON HASHES ==="
docker exec "$COMM" sh -lc '
  for f in $(find /var/www/onlyoffice -type f -iname "s3.svg" 2>/dev/null | head -20); do
    sha256sum "$f"
    stat -c "META %u:%g:%a %n" "$f"
  done
' || true

say
say "=== 7. RESOURCE / ASSEMBLY CANDIDATES ==="
docker exec "$COMM" sh -lc '
  find /var/www/onlyoffice -type f \
    \( -iname "Resource.resx" -o -iname "ASC.Web.Studio.dll" -o -iname "ASC.Web.Studio.resources.dll" \) \
    2>/dev/null | sort | head -100
' || true

say
say "===================================================================="
say " V5 COMPLETE — NOTHING MODIFIED"
say "===================================================================="
