#!/usr/bin/env bash
set -euo pipefail

COMM="${COMM:-onlyoffice-community-server}"
EXPECTED_VERSION="12.8.0.1971"

say() { printf '%s\n' "$*"; }

need_root() {
  [ "$(id -u)" -eq 0 ] || { say "ERROR: run as root"; exit 1; }
}

need_root

say "===================================================================="
say " ONLYOFFICE Community Storage Profiles — storage UI discovery v3"
say " READ ONLY"
say "===================================================================="
say

if ! docker inspect "$COMM" >/dev/null 2>&1; then
  say "ERROR: container not found: $COMM"
  exit 1
fi

VERSION="$(docker exec "$COMM" sh -lc "grep -Rhs '<add key=\"version.number\"' /var/www/onlyoffice/WebStudio /etc/onlyoffice/communityserver 2>/dev/null | head -1 | sed -n 's/.*value=\"\([^\"]*\)\".*/\1/p'")"
say "Container:         $COMM"
say "Detected version:  ${VERSION:-unknown}"
say "Expected baseline: $EXPECTED_VERSION"
if [ "$VERSION" != "$EXPECTED_VERSION" ]; then
  say "WARNING: version differs from the initial development baseline."
fi
say

say "=== 1. TEMPLATE IDS AND THEIR FILES ==="
docker exec "$COMM" sh -lc '
  grep -RIlE "storageSettingsBlockTemplate|storageSettingsTemplate|consumerSettingsTmpl" \
    /var/www/onlyoffice/WebStudio/UserControls/Management \
    --include="*.ascx" --include="*.aspx" --include="*.html" --include="*.tmpl" --include="*.js" \
    2>/dev/null | sort
'
say

say "=== 2. TEMPLATE DEFINITIONS WITH CONTEXT ==="
docker exec "$COMM" sh -lc '
  grep -RniE -B12 -A80 "id=[\"\x27](storageSettingsBlockTemplate|storageSettingsTemplate|consumerSettingsTmpl)[\"\x27]" \
    /var/www/onlyoffice/WebStudio/UserControls/Management \
    --include="*.ascx" --include="*.aspx" --include="*.html" --include="*.tmpl" \
    2>/dev/null | head -800 || true
'
say

say "=== 3. S3 CONSUMER — WEBSTUDIO ==="
docker exec "$COMM" sh -lc '
  python3 - <<"PY"
from pathlib import Path
p=Path("/var/www/onlyoffice/WebStudio/web.consumers.config")
s=p.read_text(errors="replace").splitlines()
for i,line in enumerate(s):
    if "<component name=\"S3\"" in line:
        for n in range(max(0,i-2), min(len(s),i+24)):
            print(f"{n+1:5d} {s[n]}")
        break
PY
'
say

say "=== 4. S3 CONSUMER — TEAMLAB SERVICE ==="
docker exec "$COMM" sh -lc '
  python3 - <<"PY"
from pathlib import Path
p=Path("/var/www/onlyoffice/Services/TeamLabSvc/web.consumers.config")
s=p.read_text(errors="replace").splitlines()
for i,line in enumerate(s):
    if "<component name=\"S3\"" in line:
        for n in range(max(0,i-2), min(len(s),i+24)):
            print(f"{n+1:5d} {s[n]}")
        break
PY
'
say

say "=== 5. GOOGLE CLOUD CONSUMER ==="
docker exec "$COMM" sh -lc '
  python3 - <<"PY"
from pathlib import Path
for fn in [
    "/var/www/onlyoffice/WebStudio/web.consumers.config",
    "/var/www/onlyoffice/Services/TeamLabSvc/web.consumers.config",
]:
    print("---", fn)
    s=Path(fn).read_text(errors="replace").splitlines()
    for i,line in enumerate(s):
        if "<component name=\"GoogleCloud\"" in line:
            for n in range(max(0,i-2), min(len(s),i+14)):
                print(f"{n+1:5d} {s[n]}")
            break
PY
'
say

say "=== 6. STORAGE SETTINGS JS ==="
docker exec "$COMM" sh -lc '
  nl -ba /var/www/onlyoffice/WebStudio/UserControls/Management/StorageSettings/js/storagesettings.js | sed -n "1,240p"
'
say

say "=== 7. COMMON CONSUMER STORAGE JS ==="
docker exec "$COMM" sh -lc '
  nl -ba /var/www/onlyoffice/WebStudio/UserControls/Management/Backup/js/consumersettings.js | sed -n "1,280p"
'
say

say "=== 8. RESOURCE KEYS USED BY STORAGE UI ==="
docker exec "$COMM" sh -lc '
  grep -RniE "ConsumersS3|StorageStorageTitle|StorageCdnTitle|Amazon|GoogleCloud|Rackspace|Selectel" \
    /var/www/onlyoffice/WebStudio/App_GlobalResources \
    /var/www/onlyoffice/WebStudio/UserControls/Management \
    --include="*.resx" --include="*.xml" --include="*.ascx" --include="*.aspx" --include="*.js" \
    --exclude="*.min.js" 2>/dev/null | head -700 || true
'
say

say "=== 9. LIVE CONFIG HASHES ==="
docker exec "$COMM" sh -lc '
  sha256sum \
    /var/www/onlyoffice/WebStudio/web.consumers.config \
    /var/www/onlyoffice/Services/TeamLabSvc/web.consumers.config \
    /etc/onlyoffice/communityserver/autofac.consumers.json \
    /var/www/onlyoffice/WebStudio/UserControls/Management/StorageSettings/js/storagesettings.js \
    /var/www/onlyoffice/WebStudio/UserControls/Management/Backup/js/consumersettings.js \
    2>/dev/null || true
'
say

say "=== 10. STORAGE-RELATED SERVICES ==="
docker exec "$COMM" sh -lc '
  systemctl list-units --type=service --all 2>/dev/null | grep -Ei "teamlab|studio|storage|web" | head -120 || true
'
say

say "===================================================================="
say " V3 COMPLETE — NOTHING MODIFIED"
say "===================================================================="
