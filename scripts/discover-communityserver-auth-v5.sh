#!/usr/bin/env bash
set -euo pipefail

COMM="${OCSP_COMMUNITY_CONTAINER:-onlyoffice-community-server}"

say(){ printf '%s\n' "$*"; }

cat <<'EOF'
====================================================================
 ONLYOFFICE Community Storage Profiles — CommunityServer auth UI v5.1
 READ ONLY — bounded search, no whole-tree grep
====================================================================
EOF

command -v docker >/dev/null 2>&1 || { echo "ERROR: docker not found" >&2; exit 1; }
docker inspect "$COMM" >/dev/null 2>&1 || { echo "ERROR: container not found: $COMM" >&2; exit 1; }

say
say "=== 1. CONTAINER / IMAGE ==="
docker inspect -f 'NAME={{.Name}} IMAGE={{.Config.Image}} RUNNING={{.State.Running}}' "$COMM"

say
say "=== 2. WEBSTUDIO ROOTS ==="
docker exec "$COMM" sh -lc '
  for d in /var/www/onlyoffice/WebStudio /var/www/onlyoffice/WebStudio2 /var/www/onlyoffice/WebStudio3 /var/www/onlyoffice/WebStudio4; do
    [ -d "$d" ] || continue
    printf "%s -> %s\n" "$d" "$(readlink -f "$d")"
    stat -c "META %u:%g:%a inode=%i mtime=%y %n" "$d"
  done
' || true

say
say "=== 3. KNOWN AUTHORIZATIONKEYS FILES ==="
docker exec "$COMM" sh -lc '
  for d in /var/www/onlyoffice/WebStudio /var/www/onlyoffice/WebStudio2 /var/www/onlyoffice/WebStudio3 /var/www/onlyoffice/WebStudio4; do
    [ -d "$d" ] || continue
    for f in \
      "$d/UserControls/Management/AuthorizationKeys/js/authorizationkeys.js" \
      "$d/UserControls/Management/AuthorizationKeys/img/s3.svg"; do
      if [ -f "$f" ]; then
        sha256sum "$f"
        stat -c "META %u:%g:%a %n" "$f"
      fi
    done
    for f in "$d"/bin/authorizationkeys.ascx.*.compiled; do
      [ -f "$f" ] || continue
      sha256sum "$f"
      stat -c "META %u:%g:%a %n" "$f"
    done
  done
' || true

say
say "=== 4. AUTHORIZATION JS CONTEXT — BOUNDED ==="
docker exec "$COMM" sh -lc '
  for d in /var/www/onlyoffice/WebStudio /var/www/onlyoffice/WebStudio2 /var/www/onlyoffice/WebStudio3 /var/www/onlyoffice/WebStudio4; do
    f="$d/UserControls/Management/AuthorizationKeys/js/authorizationkeys.js"
    [ -f "$f" ] || continue
    echo "--- $f"
    grep -nE "switcherBtn|saveBtn|popupDialog|auth-service|service|S3" "$f" | head -180 || true
  done
' || true

say
say "=== 5. S3 ICON PREVIEW / HASHES ==="
docker exec "$COMM" sh -lc '
  for d in /var/www/onlyoffice/WebStudio /var/www/onlyoffice/WebStudio2 /var/www/onlyoffice/WebStudio3 /var/www/onlyoffice/WebStudio4; do
    f="$d/UserControls/Management/AuthorizationKeys/img/s3.svg"
    [ -f "$f" ] || continue
    echo "--- $f"
    sha256sum "$f"
    head -20 "$f" || true
  done
' || true

say
say "=== 6. TARGETED AMAZON/S3 RESOURCE CANDIDATES ==="
docker exec "$COMM" sh -lc '
  command -v strings >/dev/null 2>&1 || exit 0
  for d in /var/www/onlyoffice/WebStudio /var/www/onlyoffice/WebStudio2 /var/www/onlyoffice/WebStudio3 /var/www/onlyoffice/WebStudio4; do
    [ -d "$d/bin" ] || continue
    echo "--- $d/bin"
    for f in \
      "$d/bin/ASC.Web.Studio.dll" \
      "$d/bin/ASC.Web.Core.dll" \
      "$d/bin/ASC.Core.Common.dll"; do
      [ -f "$f" ] || continue
      if strings -a "$f" | grep -m1 -F "ConsumersS3" >/dev/null 2>&1; then
        echo "RESOURCE-KEY-CANDIDATE $f"
      fi
      if strings -a "$f" | grep -m1 -F "Amazon AWS S3" >/dev/null 2>&1; then
        echo "LITERAL-AMAZON-TEXT $f"
      fi
    done
    find "$d/bin" -maxdepth 2 -type f -name "*.resources.dll" 2>/dev/null | head -40 | while read -r f; do
      if strings -a "$f" | grep -m1 -F "Amazon AWS S3" >/dev/null 2>&1; then
        echo "LITERAL-AMAZON-TEXT $f"
      fi
    done
  done
' || true

say
say "=== 7. ACTIVE PROCESS / WEB ROOT HINTS ==="
docker exec "$COMM" sh -lc '
  ps -eo pid,args 2>/dev/null | grep -E "mono|WebStudio|onlyoffice" | grep -v grep | head -60 || true
  for f in /etc/nginx/nginx.conf /etc/nginx/conf.d/*.conf /etc/nginx/sites-enabled/*; do
    [ -f "$f" ] || continue
    grep -nE "WebStudio[234]?|root |alias " "$f" 2>/dev/null | head -80 && echo "--- $f"
  done
' || true

say
say "===================================================================="
say " V5.1 COMPLETE — NOTHING MODIFIED"
say "===================================================================="
