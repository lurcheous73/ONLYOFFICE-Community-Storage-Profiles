#!/usr/bin/env bash
set -euo pipefail

PROJECT_NAME="ONLYOFFICE Community Storage Profiles"
REPO_URL="https://github.com/lurcheous73/ONLYOFFICE-Community-Storage-Profiles.git"
INSTALL_DIR="${OCSP_INSTALL_DIR:-/opt/onlyoffice-community-storage-profiles}"
CONFIG_DIR="${OCSP_CONFIG_DIR:-/etc/onlyoffice-community-storage-profiles}"
STATE_DIR="${OCSP_STATE_DIR:-/var/lib/onlyoffice-community-storage-profiles}"
BACKUP_DIR="${OCSP_BACKUP_DIR:-/var/backups/onlyoffice-community-storage-profiles}"
COMMUNITY_CONTAINER="${OCSP_COMMUNITY_CONTAINER:-onlyoffice-community-server}"
EXPECTED_VERSION="${OCSP_EXPECTED_VERSION:-12.8.0.1971}"
MODE="${1:-install}"

say() { printf '%s\n' "$*"; }
die() { say "ERROR: $*" >&2; exit 1; }
need_root() { [ "$(id -u)" -eq 0 ] || die "run as root"; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }

header() {
  say "===================================================================="
  say " $PROJECT_NAME"
  say " SAFE WORKSPACE BOOTSTRAP"
  say "===================================================================="
}

get_version() {
  docker exec "$COMMUNITY_CONTAINER" sh -lc '
    grep -Rhs "version.number" \
      /var/www/onlyoffice/WebStudio \
      /etc/onlyoffice/communityserver \
      2>/dev/null \
    | sed -n "s/.*value=\"\([0-9][0-9.]*\)\".*/\1/p" \
    | head -1
  ' 2>/dev/null || true
}

preflight() {
  need_root
  need_cmd git
  need_cmd docker

  docker inspect "$COMMUNITY_CONTAINER" >/dev/null 2>&1 \
    || die "container not found: $COMMUNITY_CONTAINER"

  local version
  version="$(get_version)"
  [ -n "$version" ] || die "could not determine ONLYOFFICE Community Server version"

  say "ONLYOFFICE container: $COMMUNITY_CONTAINER"
  say "Detected version:     $version"
  say "Expected baseline:    $EXPECTED_VERSION"

  if [ "$version" != "$EXPECTED_VERSION" ]; then
    say
    say "WARNING: this checkout is currently developed against $EXPECTED_VERSION."
    say "No live ONLYOFFICE files will be modified by this bootstrap."
  fi
}

write_config() {
  mkdir -p "$CONFIG_DIR" "$STATE_DIR" "$BACKUP_DIR"
  chmod 0750 "$CONFIG_DIR" "$STATE_DIR" "$BACKUP_DIR"

  if [ ! -f "$CONFIG_DIR/config.env" ]; then
    cat >"$CONFIG_DIR/config.env" <<EOF
# ONLYOFFICE Community Storage Profiles local configuration
# No cloud credentials belong in this file unless a later provider adapter
# explicitly documents a root-only secret-file mechanism.
OCSP_COMMUNITY_CONTAINER=$COMMUNITY_CONTAINER
OCSP_EXPECTED_VERSION=$EXPECTED_VERSION
OCSP_INSTALL_DIR=$INSTALL_DIR
OCSP_STATE_DIR=$STATE_DIR
OCSP_BACKUP_DIR=$BACKUP_DIR
EOF
    chmod 0640 "$CONFIG_DIR/config.env"
  fi
}

install_project() {
  preflight
  write_config

  if [ -d "$INSTALL_DIR/.git" ]; then
    say "Updating existing checkout: $INSTALL_DIR"
    git -C "$INSTALL_DIR" fetch --prune origin
    git -C "$INSTALL_DIR" pull --ff-only
  elif [ -e "$INSTALL_DIR" ]; then
    die "$INSTALL_DIR exists but is not a git checkout"
  else
    say "Cloning project to: $INSTALL_DIR"
    git clone --depth 1 "$REPO_URL" "$INSTALL_DIR"
  fi

  chmod 0755 "$INSTALL_DIR/scripts/bootstrap-workspace.sh" 2>/dev/null || true

  cat >"$STATE_DIR/install-state" <<EOF
installed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
repo=$REPO_URL
commit=$(git -C "$INSTALL_DIR" rev-parse HEAD)
community_container=$COMMUNITY_CONTAINER
community_version=$(get_version)
EOF
  chmod 0640 "$STATE_DIR/install-state"

  say
  say "PASS: project bootstrap installed."
  say "Checkout: $INSTALL_DIR"
  say "Config:   $CONFIG_DIR/config.env"
  say "State:    $STATE_DIR/install-state"
  say "Backups:  $BACKUP_DIR"
  say
  say "IMPORTANT: no ONLYOFFICE storage configuration was changed."
}

show_status() {
  preflight
  say
  if [ -d "$INSTALL_DIR/.git" ]; then
    say "Project checkout: INSTALLED"
    say "Path:             $INSTALL_DIR"
    say "Commit:           $(git -C "$INSTALL_DIR" rev-parse --short HEAD)"
    say "Branch:           $(git -C "$INSTALL_DIR" branch --show-current)"
    say "Origin:           $(git -C "$INSTALL_DIR" remote get-url origin)"
  else
    say "Project checkout: NOT INSTALLED"
  fi
  say
  [ -f "$CONFIG_DIR/config.env" ] && say "Config:            PRESENT" || say "Config:            MISSING"
  [ -f "$STATE_DIR/install-state" ] && say "State file:        PRESENT" || say "State file:        MISSING"
  [ -d "$BACKUP_DIR" ] && say "Backup directory:  PRESENT" || say "Backup directory:  MISSING"
  say
  say "Live storage patch: NOT INSTALLED BY THIS SCRIPT"
}

update_project() {
  preflight
  [ -d "$INSTALL_DIR/.git" ] || die "project is not installed at $INSTALL_DIR"
  git -C "$INSTALL_DIR" fetch --prune origin
  git -C "$INSTALL_DIR" pull --ff-only
  say "PASS: checkout updated to $(git -C "$INSTALL_DIR" rev-parse --short HEAD)"
}

case "$MODE" in
  install) header; install_project ;;
  status)  header; show_status ;;
  update)  header; update_project ;;
  *)
    echo "Usage: $0 {install|status|update}" >&2
    exit 2
    ;;
esac
