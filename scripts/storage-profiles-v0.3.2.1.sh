#!/usr/bin/env bash
set -euo pipefail

# ONLYOFFICE Community Storage Profiles — v0.3.2.1
# Corrective wrapper for v0.3.2 compiler preflight.
#
# v0.3.2 incorrectly attempted:
#   docker exec <container> command -v mcs
# `command` is a shell builtin, not an executable. This wrapper makes a
# temporary copy of v0.3.2, changes only that preflight to run through
# `sh -lc`, then executes the requested operation.
#
# It does not call the storage API and introduces no migration behaviour.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BASE="$SCRIPT_DIR/storage-profiles-v0.3.2.sh"
TMP="$(mktemp /tmp/storage-profiles-v0.3.2.1.XXXXXX.sh)"
cleanup(){ rm -f -- "$TMP"; }
trap cleanup EXIT

[ -f "$BASE" ] || { echo "ERROR: base v0.3.2 script missing: $BASE" >&2; exit 1; }

python3 - "$BASE" "$TMP" <<'PY'
import sys
from pathlib import Path
src,dst=map(Path,sys.argv[1:3])
text=src.read_text(encoding='utf-8')
old='docker exec "$COMM" command -v mcs >/dev/null 2>&1 || die "mcs not found in $COMM"'
new='docker exec "$COMM" sh -lc \'command -v mcs >/dev/null 2>&1\' || die "mcs not found in $COMM"'
count=text.count(old)
if count != 1:
    raise SystemExit(f'ERROR: expected exactly one v0.3.2 mcs preflight, found {count}')
text=text.replace(old,new,1)
dst.write_text(text,encoding='utf-8')
PY

chmod 700 "$TMP"
bash "$TMP" "${1:-status}"
