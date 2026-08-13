#!/usr/bin/env bash
set -euo pipefail

# ONLYOFFICE Community Storage Profiles
# v0.2 developer preview
#
# Purpose:
#   Reuse ONLYOFFICE Control Panel's existing S3 slot as the user-facing
#   "S3-Compatible Object Storage" placeholder while preserving the internal
#   module id "S3" and ASC.Data.Storage.S3.S3Storage backend.
#
# This developer preview:
#   * DOES NOT call the storage API.
#   * DOES NOT select a storage provider.
#   * DOES NOT migrate document data.
#   * DOES NOT write credentials.
#   * Changes only the Control Panel storage.js presentation layer.
#
# Supported operations:
#   install | status | rollback

CP="${OCSP_CONTROL_PANEL_CONTAINER:-onlyoffice-control-panel}"
EXPECTED_IMAGE="onlyoffice/controlpanel:3.5.5.549"
EXPECTED_UPSTREAM_TAG="v3.5.5"

BACKUP_ROOT="/var/backups/onlyoffice-community-storage-profiles"
STATE_DIR="/var/lib/onlyoffice-community-storage-profiles"
STATE_FILE="$STATE_DIR/storage-profiles-v0.2.state"

STORAGE_JS="/var/www/onlyoffice/controlpanel/www/public/javascripts/views/storage.js"
EXPECTED_STORAGE_JS_SHA="4d97712fb1b62b1da1fe6e0ff37488b7eb06310607faba54ffeaa8ac33dd821c"
MARKER="OCSP v0.2 S3-Compatible Object Storage placeholder"

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
 ONLYOFFICE Community Storage Profiles — v0.2 developer preview
 S3-Compatible Object Storage placeholder
====================================================================
EOF
}

need() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

container_ok() {
  docker inspect "$CP" >/dev/null 2>&1 || die "container not found: $CP"
  [ "$(docker inspect -f '{{.State.Running}}' "$CP" 2>/dev/null)" = "true" ] || die "container is not running: $CP"
}

image_name() {
  docker inspect -f '{{.Config.Image}}' "$CP"
}

sha_live() {
  docker exec "$CP" sha256sum "$1" | awk '{print $1}'
}

file_meta() {
  docker exec "$CP" stat -c '%u:%g:%a' "$1"
}

restore_meta() {
  local path="$1" meta="$2" uid gid mode
  uid="${meta%%:*}"
  meta="${meta#*:}"
  gid="${meta%%:*}"
  mode="${meta##*:}"
  docker exec "$CP" chown "$uid:$gid" "$path"
  docker exec "$CP" chmod "$mode" "$path"
}

has_marker() {
  docker exec "$CP" grep -Fq "$MARKER" "$STORAGE_JS"
}

wait_container() {
  local i
  for i in $(seq 1 90); do
    if [ "$(docker inspect -f '{{.State.Running}}' "$CP" 2>/dev/null || true)" = "true" ] && docker exec "$CP" true >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  die "Control Panel container did not return to running state in time"
}

preflight_common() {
  need docker
  need python3
  need sha256sum
  need stat
  container_ok

  local image
  image="$(image_name)"
  say "Control Panel container: $CP"
  say "Detected image:          $image"
  say "Expected image:          $EXPECTED_IMAGE"
  say "Upstream source tag:     $EXPECTED_UPSTREAM_TAG"

  [ "$image" = "$EXPECTED_IMAGE" ] || die "unsupported Control Panel image; refusing to patch"
  docker exec "$CP" test -f "$STORAGE_JS" || die "storage.js not found at expected path"
}

patch_copy() {
  local src="$1" dst="$2"

  python3 - "$src" "$dst" <<'PY'
import sys
from pathlib import Path

src = Path(sys.argv[1])
dst = Path(sys.argv[2])
text = src.read_text(encoding="utf-8")

marker = "OCSP v0.2 S3-Compatible Object Storage placeholder"
if marker in text:
    raise SystemExit("v0.2 marker already present in source copy")

anchor = "    function init(portal) {\n"
if text.count(anchor) != 1:
    raise SystemExit(f"expected one init(portal) anchor, found {text.count(anchor)}")

helper = r'''    // BEGIN OCSP v0.2 S3-Compatible Object Storage placeholder
    // Presentation only. The backend module id remains "S3".
    var ocspProviderProfiles = [
        { id: "amazon-s3", name: "Amazon S3" },
        { id: "mega-s4", name: "MEGA S4" },
        { id: "wasabi", name: "Wasabi" },
        { id: "backblaze-b2-s3", name: "Backblaze B2 S3" },
        { id: "cloudflare-r2", name: "Cloudflare R2" },
        { id: "minio", name: "MinIO" },
        { id: "ceph-rgw", name: "Ceph RGW" },
        { id: "ovhcloud", name: "OVHcloud Object Storage" },
        { id: "custom-s3", name: "Custom S3-Compatible Endpoint" }
    ];

    function ocspDecorateStorages(storages) {
        if (!Array.isArray(storages)) return storages;

        storages.forEach(function (item) {
            if (item && item.id === "S3") {
                item.title = "S3-Compatible Object Storage";
            }
        });

        return storages;
    }

    function ocspInjectProfileSelector($box) {
        var $s3 = $box.find(".storage[data-id='S3']");
        if (!$s3.length || $s3.find(".ocsp-profile-selector").length) return;

        var options = ocspProviderProfiles.map(function (profile) {
            return '<option value="' + profile.id + '">' + profile.name + '</option>';
        }).join("");

        var html = '' +
            '<div class="flexContainer ocsp-profile-selector">' +
                '<span>Provider profile</span>' +
                '<select class="textBox ocsp-profile-select">' + options + '</select>' +
            '</div>' +
            '<div class="flexContainer fullWidth emptyMargin ocsp-profile-note">' +
                '<span>Community Storage Profiles developer preview — profile selection is not sent to ONLYOFFICE as a storage property.</span>' +
            '</div>';

        $s3.prepend(html);
    }
    // END OCSP v0.2 S3-Compatible Object Storage placeholder

'''
text = text.replace(anchor, helper + anchor, 1)

old = "                    var thirdPartyJSON = res[0];\n"
new = "                    var thirdPartyJSON = ocspDecorateStorages(res[0]);\n"
if text.count(old) != 1:
    raise SystemExit(f"expected one primary storage response assignment, found {text.count(old)}")
text = text.replace(old, new, 1)

old = "                    allStorages = initStorages(Object.assign({}, diskDefault), res[1]);\n"
new = "                    allStorages = initStorages(Object.assign({}, diskDefault), ocspDecorateStorages(res[1]));\n"
if text.count(old) != 1:
    raise SystemExit(f"expected one CDN storage response assignment, found {text.count(old)}")
text = text.replace(old, new, 1)

old = '''        if (selected.properties && selected.properties.length && selected.current) {
            window.ConsumerStorageSettings.setProps($box, selected);
        }
    }

    function bindEvents() {
'''
new = '''        if (selected.properties && selected.properties.length && selected.current) {
            window.ConsumerStorageSettings.setProps($box, selected);
        }

        // Keep the profile selector out of the payload: it intentionally has
        // no data-id attribute, so getStorage()/ConsumerStorageSettings never
        // serialise it as an ONLYOFFICE storage property.
        if ($box.is($storageSettingsBox)) {
            ocspInjectProfileSelector($box);
        }
    }

    function bindEvents() {
'''
if text.count(old) != 1:
    raise SystemExit(f"expected one initStorage tail anchor, found {text.count(old)}")
text = text.replace(old, new, 1)

if marker not in text:
    raise SystemExit("patch marker missing after transformation")

# Safety assertions: v0.2 must not alter the API request names or backend id.
for required in (
    "request = 'storage/updateStorage';",
    "module: storage.id,",
    'item.id === "S3"',
):
    if required not in text:
        raise SystemExit(f"required stock/backend contract missing after patch: {required}")

# The preview selector must not carry data-id and therefore cannot enter props.
selector_fragment = 'select class="textBox ocsp-profile-select"'
if selector_fragment not in text:
    raise SystemExit("profile selector missing")

# Keep the transformation intentionally small and deterministic.
if len(text) - len(src.read_text(encoding="utf-8")) > 7000:
    raise SystemExit("unexpectedly large patch")

dst.write_text(text, encoding="utf-8")
PY
}

syntax_check() {
  local host_file="$1" remote_tmp="/tmp/ocsp-storage-v02.$$.js"
  docker cp "$host_file" "$CP:$remote_tmp" >/dev/null
  if docker exec "$CP" sh -lc 'command -v node >/dev/null 2>&1'; then
    if ! docker exec "$CP" node --check "$remote_tmp" >/dev/null; then
      docker exec "$CP" rm -f "$remote_tmp" >/dev/null 2>&1 || true
      die "patched storage.js failed node --check"
    fi
  else
    say "WARNING: node executable not found in Control Panel container; skipping JS syntax check"
  fi
  docker exec "$CP" rm -f "$remote_tmp" >/dev/null 2>&1 || true
}

status() {
  banner
  preflight_common
  say

  local sha
  sha="$(sha_live "$STORAGE_JS")"
  say "storage.js SHA256: $sha"
  say "Stock baseline SHA: $EXPECTED_STORAGE_JS_SHA"
  say

  if has_marker; then
    say "Control Panel S3 presentation: S3-COMPATIBLE PLACEHOLDER"
  else
    say "Control Panel S3 presentation: STOCK"
  fi

  if [ -f "$STATE_FILE" ]; then
    say "Patch state: PRESENT ($STATE_FILE)"
    sed 's/^/  /' "$STATE_FILE"
  else
    say "Patch state: ABSENT"
  fi

  say
  say "No storage API is called and no credentials are read by this status command."
}

install_patch() {
  banner
  preflight_common

  if has_marker; then
    say "v0.2 marker already present; no changes made."
    exit 0
  fi

  local sha meta stamp backup patched_sha
  sha="$(sha_live "$STORAGE_JS")"
  [ "$sha" = "$EXPECTED_STORAGE_JS_SHA" ] || die "storage.js hash differs from tested 3.5.5.549 baseline; refusing to patch"

  meta="$(file_meta "$STORAGE_JS")"
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  backup="$BACKUP_ROOT/v0.2-$stamp"
  TMP_DIR="$(mktemp -d /tmp/ocsp-v02.XXXXXX)"

  mkdir -p "$backup" "$STATE_DIR"
  chmod 700 "$backup" "$STATE_DIR"

  say "Backing up Control Panel storage.js to: $backup"
  docker cp "$CP:$STORAGE_JS" "$backup/storage.js"
  chmod 600 "$backup/storage.js"

  docker cp "$CP:$STORAGE_JS" "$TMP_DIR/storage.original.js"
  patch_copy "$TMP_DIR/storage.original.js" "$TMP_DIR/storage.patched.js"
  syntax_check "$TMP_DIR/storage.patched.js"
  patched_sha="$(sha256sum "$TMP_DIR/storage.patched.js" | awk '{print $1}')"

  say "Installing v0.2 presentation patch..."
  docker cp "$TMP_DIR/storage.patched.js" "$CP:$STORAGE_JS"
  restore_meta "$STORAGE_JS" "$meta"

  has_marker || die "post-install marker verification failed"
  [ "$(sha_live "$STORAGE_JS")" = "$patched_sha" ] || die "post-install hash verification failed"

  cat >"$STATE_FILE" <<EOF
PATCH_VERSION=v0.2
CONTROL_PANEL_IMAGE=$EXPECTED_IMAGE
UPSTREAM_TAG=$EXPECTED_UPSTREAM_TAG
BACKUP_DIR=$backup
ORIGINAL_STORAGE_JS_SHA=$EXPECTED_STORAGE_JS_SHA
PATCHED_STORAGE_JS_SHA=$patched_sha
ORIGINAL_STORAGE_JS_META=$meta
INSTALLED_UTC=$stamp
EOF
  chmod 600 "$STATE_FILE"

  say "Restarting $CP so the presentation code is reloaded..."
  docker restart "$CP" >/dev/null
  wait_container

  say
  say "PASS: v0.2 S3-Compatible Object Storage placeholder installed."
  say "Internal ONLYOFFICE module id remains S3."
  say "No storage provider was selected and no document migration was started."
  say "Next: refresh Control Panel -> Storage and inspect the former Amazon S3 slot."
}

rollback_patch() {
  banner
  preflight_common
  [ -f "$STATE_FILE" ] || die "no v0.2 state file found; refusing to guess a rollback source"

  # shellcheck disable=SC1090
  source "$STATE_FILE"
  [ "${PATCH_VERSION:-}" = "v0.2" ] || die "state file is not for v0.2"
  [ -n "${BACKUP_DIR:-}" ] || die "BACKUP_DIR missing from state file"
  [ -f "$BACKUP_DIR/storage.js" ] || die "storage.js backup missing"

  say "Restoring stock Control Panel storage.js from: $BACKUP_DIR"
  docker cp "$BACKUP_DIR/storage.js" "$CP:$STORAGE_JS"

  if [ -n "${ORIGINAL_STORAGE_JS_META:-}" ]; then
    restore_meta "$STORAGE_JS" "$ORIGINAL_STORAGE_JS_META"
  fi

  [ "$(sha_live "$STORAGE_JS")" = "$EXPECTED_STORAGE_JS_SHA" ] || die "rollback hash verification failed"

  rm -f "$STATE_FILE"
  say "Restarting $CP..."
  docker restart "$CP" >/dev/null
  wait_container

  say "PASS: stock Control Panel storage.js restored."
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
