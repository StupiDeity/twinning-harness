#!/usr/bin/env bash
# Unload both pipeline LaunchAgents and remove their plists. Idempotent.
# Usage: bash .pipeline/bin/uninstall-launchd.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

TARGET_DIR="$HOME/Library/LaunchAgents"
DOMAIN="gui/$(id -u)"

uninstall_plist() {
  local label="$1"
  local target="$TARGET_DIR/${label}.plist"

  if launchctl print "$DOMAIN/$label" >/dev/null 2>&1; then
    launchctl bootout "$DOMAIN/$label"
    log "unloaded $label"
  else
    log "$label was not loaded"
  fi

  if [[ -f "$target" ]]; then
    rm -f "$target"
    log "removed $target"
  fi
}

uninstall_plist "com.twinning.pipeline"
uninstall_plist "com.twinning.retrospective"
