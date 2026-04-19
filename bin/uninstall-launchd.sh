#!/usr/bin/env bash
# Unload the pipeline LaunchAgent and remove its plist. Idempotent.
# Usage: bash .pipeline/bin/uninstall-launchd.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

LABEL="com.twinning.pipeline"
TARGET="$HOME/Library/LaunchAgents/${LABEL}.plist"
DOMAIN="gui/$(id -u)"

if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
  launchctl bootout "$DOMAIN/$LABEL"
  log "unloaded $LABEL"
else
  log "$LABEL was not loaded"
fi

if [[ -f "$TARGET" ]]; then
  rm -f "$TARGET"
  log "removed $TARGET"
fi
