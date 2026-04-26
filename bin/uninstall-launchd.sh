#!/usr/bin/env bash
# Bootout and remove the per-project launchd pair.
#
# Usage:
#   bash bin/uninstall-launchd.sh /path/to/target
#   bash bin/uninstall-launchd.sh --slug <slug>

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAUNCHD_DIR="$HOME/Library/LaunchAgents"
DOMAIN="gui/$(id -u)"

slug=""
case "${1:-}" in
  --slug)
    slug="${2:-}"
    [[ -n "$slug" ]] || { printf 'usage: bash bin/uninstall-launchd.sh --slug <slug>\n' >&2; exit 64; }
    ;;
  *)
    TARGET_REPO="${TARGET_REPO:-${1:-}}"
    [[ -n "$TARGET_REPO" && -d "$TARGET_REPO" ]] || {
      printf 'usage: bash bin/uninstall-launchd.sh /path/to/target\n' >&2; exit 64; }
    export TARGET_REPO
    # shellcheck source=common.sh
    source "$SCRIPT_DIR/common.sh"
    slug="$PROJECT_SLUG"
    ;;
esac

uninstall_one() {
  local kind="$1"
  local label="com.twinning.${kind}.${slug}"
  local target="$LAUNCHD_DIR/${label}.plist"
  if launchctl print "$DOMAIN/$label" >/dev/null 2>&1; then
    launchctl bootout "$DOMAIN/$label" || true
    printf 'unloaded %s\n' "$label" >&2
  else
    printf '%s was not loaded\n' "$label" >&2
  fi
  if [[ -f "$target" ]]; then
    rm -f "$target"
    printf 'removed %s\n' "$target" >&2
  fi
}

uninstall_one pipeline
uninstall_one retrospective
