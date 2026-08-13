#!/usr/bin/env bash
set -euo pipefail

# ONLYOFFICE Community Storage Profiles
# v0.1.1 developer preview for ONLYOFFICE Workspace Community Server 12.8.0.1971
#
# This patch DOES NOT migrate or reconfigure document storage.
# It only exposes existing hidden S3-compatible consumer properties:
#   serviceurl, forcepathstyle, usehttp
#
# Supported operations:
#   install | status | rollback

COMM="${OCSP_COMMUNITY_CONTAINER:-onlyoffice-community-server}"
EXPECTED_VERSION="12.8.0.1971"
BACKUP_ROOT="/var/backups/onlyoffice-community-storage-profiles"
STATE_DIR="/var/lib/onlyoffice-community-storage-profiles"
STATE_FILE="$STATE_DIR/storage-profiles-v0.1.state"

WEBSTUDIO="/var/www/onlyoffice/WebStudio/web.consumers.config"
TEAMLAB="/var/www/onlyoffice/Services/TeamLabSvc/web.consumers.config"
EXPECTED_WEBSTUDIO_SHA="e23a225eab3d17125a0c8961e2d842f385249a11d7a2bf1f13d3e2fc1f3ccc2b"
EXPECTED_TEAMLAB_SHA="e23a225eab3d17125a0c8961e2d842f385249a11d7a2bf1f13d3e2fc1f3ccc2b"

TMP_DIR=""

say() { printf '%s\n' "$*"; }
die() { say "ERROR: $*" >&2; exit 1; }

cleanup() {
  if [ -n "${TMP_DIR:-}" ] && [ -d "$TMP_DIR" ]; then
    rm -rf -- "$TMP_DIR"
  fi
}
trap cleanup EXIT

banner() {
  cat <<'EOF'
====================================================================
 ONLYOFFICE Community Storage Profiles — v0.1.1 developer preview
====================================================================
EOF
}

need() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

container_ok() {
  docker inspect "$COMM" >/dev/null 2>&1 || die "container not found: $COMM"
  [ "$(docker inspect -f '{{.State.Running}}' "$COMM" 2>/dev/null)" = "true" ] || die "container is not running: $COMM"
}

detect_version() {
  docker exec "$COMM" sh -lc "grep -Rhs 'version.number' /var/www/onlyoffice/WebStudio/web.appsettings.config /etc/onlyoffice/communityserver 2>/dev/null | sed -n 's/.*version.number.*value=\"\([^\"]*\)\".*/\1/p' | head -1"
}

sha_live() {
  docker exec "$COMM" sha256sum "$1" | awk '{print $1}'
}

file_meta() {
  docker exec "$COMM" stat -c '%u:%g:%a' "$1"
}

restore_meta() {
  local path="$1" meta="$2" uid gid mode
  uid="${meta%%:*}"
  meta="${meta#*:}"
  gid="${meta%%:*}"
  mode="${meta##*:}"
  docker exec "$COMM" chown "$uid:$gid" "$path"
  docker exec "$COMM" chmod "$mode" "$path"
}

s3_section() {
  local path="$1"
  docker exec "$COMM" sh -lc "awk '/<component name=\"S3\" /{p=1} p{print} p && /<\\/component>/{exit}' '$path'"
}

is_exposed() {
  local path="$1" section
  section="$(s3_section "$path")"
  grep -q 'key="serviceurl".*optional="true"' <<<"$section" || return 1
  grep -q 'key="forcepathstyle".*optional="true"' <<<"$section" || return 1
  grep -q 'key="usehttp".*optional="true"' <<<"$section" || return 1
  ! grep -q 'key="serviceurl".*hidden="true"' <<<"$section" || return 1
  ! grep -q 'key="forcepathstyle".*hidden="true"' <<<"$section" || return 1
  ! grep -q 'key="usehttp".*hidden="true"' <<<"$section" || return 1
}

wait_container() {
  local i
  for i in $(seq 1 90); do
    if [ "$(docker inspect -f '{{.State.Running}}' "$COMM" 2>/dev/null || true)" = "true" ] && docker exec "$COMM" true >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  die "container did not return to running state in time"
}

patch_copy() {
  local src="$1" dst="$2"
  python3 - "$src" "$dst" <<'PY'
import re
import sys
from pathlib import Path

src = Path(sys.argv[1])
dst = Path(sys.argv[2])
text = src.read_text(encoding="utf-8")

# Match the S3 component robustly. The old v0.1 matcher used \b after the
# closing quote in name="S3", which cannot match because quote+space are
# both non-word characters.
component_re = re.compile(
    r'<component\b(?=[^>]*\bname="S3")[^>]*>.*?</component>',
    flags=re.S,
)
matches = list(component_re.finditer(text))
if len(matches) != 1:
    raise SystemExit(f"expected exactly one S3 component, found {len(matches)}")

m = matches[0]
section = m.group(0)
original = section

for key in ("serviceurl", "forcepathstyle", "usehttp"):
    pattern = rf'(<item\s+key="{key}"\s+value="")\s+hidden="true"(\s+optional="true"\s*/>)'
    section, count = re.subn(pattern, r'\1\2', section, count=1)
    if count != 1:
        raise SystemExit(f"expected one hidden {key} property in S3 component, changed {count}")

if section == original:
    raise SystemExit("no changes made")

new_text = text[:m.start()] + section + text[m.end():]
dst.write_text(new_text, encoding="utf-8")
PY
}

verify_expected_diff() {
  python3 - "$1" "$2" <<'PY'
import sys
from pathlib import Path

old = Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
new = Path(sys.argv[2]).read_text(encoding="utf-8").splitlines()
if len(old) != len(new):
    raise SystemExit("line count changed unexpectedly")

allowed = {"serviceurl", "forcepathstyle", "usehttp"}
changed = [(a, b) for a, b in zip(old, new) if a != b]
if len(changed) != 3:
    raise SystemExit(f"expected exactly 3 changed lines, got {len(changed)}")

seen = set()
for before, after in changed:
    key = next((k for k in allowed if f'key="{k}"' in before), None)
    if key is None or key in seen:
        raise SystemExit(f"unexpected changed line: {before}")
    if 'hidden="true"' not in before or 'hidden="true"' in after:
        raise SystemExit(f"unexpected transformation for {key}")
    if 'optional="true"' not in before or 'optional="true"' not in after:
        raise SystemExit(f"optional flag changed for {key}")
    seen.add(key)

if seen != allowed:
    raise SystemExit(f"missing expected changes: {sorted(allowed-seen)}")
PY
}

preflight_common() {
  need docker
  need python3
  need sha256sum
  need stat
  container_ok
  local version
  version="$(detect_version)"
  say "ONLYOFFICE container: $COMM"
  say "Detected version:     $version"
  say "Expected baseline:    $EXPECTED_VERSION"
  [ "$version" = "$EXPECTED_VERSION" ] || die "unsupported ONLYOFFICE build; refusing to patch"
}

status() {
  banner
  preflight_common
  say
  local wsha tsha
  wsha="$(sha_live "$WEBSTUDIO")"
  tsha="$(sha_live "$TEAMLAB")"
  say "WebStudio SHA256: $wsha"
  say "TeamLab   SHA256: $tsha"
  say

  if is_exposed "$WEBSTUDIO"; then
    say "WebStudio S3 advanced fields: EXPOSED"
  else
    say "WebStudio S3 advanced fields: STOCK/HIDDEN"
  fi
  if is_exposed "$TEAMLAB"; then
    say "TeamLab S3 advanced fields:   EXPOSED"
  else
    say "TeamLab S3 advanced fields:   STOCK/HIDDEN"
  fi

  if [ -f "$STATE_FILE" ]; then
    say "Patch state: PRESENT ($STATE_FILE)"
    sed 's/^/  /' "$STATE_FILE"
  else
    say "Patch state: ABSENT"
  fi

  say
  say "No storage credentials are read or displayed by this command."
}

install_patch() {
  banner
  preflight_common

  if is_exposed "$WEBSTUDIO" && is_exposed "$TEAMLAB"; then
    say "Patch already appears installed; no changes made."
    exit 0
  fi

  local wsha tsha wmeta tmeta stamp backup
  wsha="$(sha_live "$WEBSTUDIO")"
  tsha="$(sha_live "$TEAMLAB")"
  [ "$wsha" = "$EXPECTED_WEBSTUDIO_SHA" ] || die "WebStudio config hash differs from tested stock baseline; refusing to patch"
  [ "$tsha" = "$EXPECTED_TEAMLAB_SHA" ] || die "TeamLab config hash differs from tested stock baseline; refusing to patch"

  wmeta="$(file_meta "$WEBSTUDIO")"
  tmeta="$(file_meta "$TEAMLAB")"
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  backup="$BACKUP_ROOT/v0.1-$stamp"
  TMP_DIR="$(mktemp -d /tmp/ocsp-v01.XXXXXX)"

  mkdir -p "$backup" "$STATE_DIR"
  chmod 700 "$backup" "$STATE_DIR"

  say "Backing up tested originals to: $backup"
  docker cp "$COMM:$WEBSTUDIO" "$backup/WebStudio.web.consumers.config"
  docker cp "$COMM:$TEAMLAB" "$backup/TeamLabSvc.web.consumers.config"
  chmod 600 "$backup"/*

  docker cp "$COMM:$WEBSTUDIO" "$TMP_DIR/WebStudio.original"
  docker cp "$COMM:$TEAMLAB" "$TMP_DIR/TeamLab.original"

  patch_copy "$TMP_DIR/WebStudio.original" "$TMP_DIR/WebStudio.patched"
  patch_copy "$TMP_DIR/TeamLab.original" "$TMP_DIR/TeamLab.patched"
  verify_expected_diff "$TMP_DIR/WebStudio.original" "$TMP_DIR/WebStudio.patched"
  verify_expected_diff "$TMP_DIR/TeamLab.original" "$TMP_DIR/TeamLab.patched"

  say "Installing developer-preview UI exposure..."
  docker cp "$TMP_DIR/WebStudio.patched" "$COMM:$WEBSTUDIO"
  docker cp "$TMP_DIR/TeamLab.patched" "$COMM:$TEAMLAB"
  restore_meta "$WEBSTUDIO" "$wmeta"
  restore_meta "$TEAMLAB" "$tmeta"

  is_exposed "$WEBSTUDIO" || die "post-install verification failed for WebStudio"
  is_exposed "$TEAMLAB" || die "post-install verification failed for TeamLab"

  cat >"$STATE_FILE" <<EOF
PATCH_VERSION=v0.1.1
ONLYOFFICE_VERSION=$EXPECTED_VERSION
BACKUP_DIR=$backup
ORIGINAL_WEBSTUDIO_SHA=$EXPECTED_WEBSTUDIO_SHA
ORIGINAL_TEAMLAB_SHA=$EXPECTED_TEAMLAB_SHA
ORIGINAL_WEBSTUDIO_META=$wmeta
ORIGINAL_TEAMLAB_META=$tmeta
INSTALLED_UTC=$stamp
EOF
  chmod 600 "$STATE_FILE"

  say "Restarting $COMM so consumer metadata is reloaded..."
  docker restart "$COMM" >/dev/null
  wait_container

  say
  say "PASS: v0.1.1 developer preview installed."
  say "No storage provider was selected and no document data was migrated."
  say "Next: open the ONLYOFFICE Storage settings page and inspect the S3 fields."
}

rollback_patch() {
  banner
  preflight_common
  [ -f "$STATE_FILE" ] || die "no v0.1 state file found; refusing to guess a rollback source"

  # shellcheck disable=SC1090
  source "$STATE_FILE"
  case "${PATCH_VERSION:-}" in
    v0.1|v0.1.1) ;;
    *) die "state file is not for a supported v0.1 patch" ;;
  esac
  [ -n "${BACKUP_DIR:-}" ] || die "BACKUP_DIR missing from state file"
  [ -f "$BACKUP_DIR/WebStudio.web.consumers.config" ] || die "WebStudio backup missing"
  [ -f "$BACKUP_DIR/TeamLabSvc.web.consumers.config" ] || die "TeamLab backup missing"

  say "Restoring stock consumer configs from: $BACKUP_DIR"
  docker cp "$BACKUP_DIR/WebStudio.web.consumers.config" "$COMM:$WEBSTUDIO"
  docker cp "$BACKUP_DIR/TeamLabSvc.web.consumers.config" "$COMM:$TEAMLAB"

  if [ -n "${ORIGINAL_WEBSTUDIO_META:-}" ]; then restore_meta "$WEBSTUDIO" "$ORIGINAL_WEBSTUDIO_META"; fi
  if [ -n "${ORIGINAL_TEAMLAB_META:-}" ]; then restore_meta "$TEAMLAB" "$ORIGINAL_TEAMLAB_META"; fi

  local wsha tsha
  wsha="$(sha_live "$WEBSTUDIO")"
  tsha="$(sha_live "$TEAMLAB")"
  [ "$wsha" = "$EXPECTED_WEBSTUDIO_SHA" ] || die "WebStudio rollback hash verification failed"
  [ "$tsha" = "$EXPECTED_TEAMLAB_SHA" ] || die "TeamLab rollback hash verification failed"

  rm -f "$STATE_FILE"
  say "Restarting $COMM..."
  docker restart "$COMM" >/dev/null
  wait_container
  say "PASS: stock consumer configs restored."
}

case "${1:-}" in
  install) install_patch ;;
  status) status ;;
  rollback) rollback_patch ;;
  *)
    echo "Usage: $0 {install|status|rollback}" >&2
    exit 2
    ;;
esac
