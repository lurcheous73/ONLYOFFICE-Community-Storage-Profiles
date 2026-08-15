#!/usr/bin/env bash
set -euo pipefail

# OCSP v0.3.4.1 compile hotfix for Mono/SharpZipLib netstandard facade.
# This wrapper does not modify the checked-in v0.3.4 installer. It creates a
# temporary runtime copy in the same scripts directory, injects automatic
# netstandard.dll discovery/reference into compile_handler(), runs the requested
# operation, then removes the temporary copy.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BASE="$SCRIPT_DIR/storage-profiles-v0.3.4-manual-backup.sh"
RUNTIME="$SCRIPT_DIR/.storage-profiles-v0.3.4.1-runtime.$$"
COMM="${OCSP_COMMUNITY_CONTAINER:-onlyoffice-community-server}"

cleanup(){ rm -f -- "$RUNTIME"; }
trap cleanup EXIT

[ -f "$BASE" ] || { echo "ERROR: missing $BASE" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 not found" >&2; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "ERROR: docker not found" >&2; exit 1; }

NETSTANDARD="$(docker exec "$COMM" sh -lc "find /usr/lib/mono -type f -path '*/Facades/netstandard.dll' -print 2>/dev/null | sort -V | tail -n 1")"
[ -n "$NETSTANDARD" ] || {
  echo "ERROR: no Mono netstandard facade found in $COMM" >&2
  exit 1
}

echo "Using Mono netstandard facade: $NETSTANDARD"

python3 - "$BASE" "$RUNTIME" "$NETSTANDARD" <<'PY'
from pathlib import Path
import sys
src, dst = map(Path, sys.argv[1:3])
netstandard = sys.argv[3]
t = src.read_text(encoding='utf-8')

needle = "  -r:ICSharpCode.SharpZipLib.dll \\\\\n  -r:System.Configuration.dll"
replacement = "  -r:ICSharpCode.SharpZipLib.dll \\\\\n  -r:'" + netstandard + "' \\\\\n  -r:System.Configuration.dll"

if t.count(needle) != 1:
    raise SystemExit("ERROR: expected exactly one SharpZipLib compiler reference anchor")

t = t.replace(needle, replacement, 1)
dst.write_text(t, encoding='utf-8')
PY

chmod 700 "$RUNTIME"
bash -n "$RUNTIME"
# Do not exec here: the wrapper's EXIT trap must run so the temporary runtime
# copy is removed after both successful and failed installer invocations.
bash "$RUNTIME" "${1:-status}"
