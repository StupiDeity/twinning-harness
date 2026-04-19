#!/usr/bin/env bash
# Render the launchd plist template with absolute paths for this checkout and
# load it as a user LaunchAgent. Idempotent: bootout any previous version first.
#
# Usage: bash .pipeline/bin/install-launchd.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

LABEL="com.twinning.pipeline"
TEMPLATE="$PIPELINE_ROOT/launchd/${LABEL}.plist.template"
TARGET_DIR="$HOME/Library/LaunchAgents"
TARGET="$TARGET_DIR/${LABEL}.plist"
DOMAIN="gui/$(id -u)"

[[ -f "$TEMPLATE" ]] || die "plist template missing: $TEMPLATE"

mkdir -p "$TARGET_DIR"
mkdir -p "$REPO_ROOT/logs/pipeline"

# Render.
sed \
  -e "s|{{REPO_ROOT}}|$REPO_ROOT|g" \
  -e "s|{{HOME}}|$HOME|g" \
  "$TEMPLATE" > "$TARGET"

log "rendered $TARGET"

# Idempotent reload: bootout if loaded, then bootstrap.
if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
  log "unloading previous agent"
  launchctl bootout "$DOMAIN/$LABEL"
fi

launchctl bootstrap "$DOMAIN" "$TARGET"
log "loaded $LABEL into $DOMAIN"

# Kick one tick immediately so we don't wait up to StartInterval.
launchctl kickstart -k "$DOMAIN/$LABEL"
log "kickstarted first tick"

cat <<EOF

Pipeline LaunchAgent installed.
  Label:      $LABEL
  Domain:     $DOMAIN
  Plist:      $TARGET
  Interval:   every 5 minutes (StartInterval=300)
  Logs:       $REPO_ROOT/logs/pipeline/launchd.{out,err}.log
              $REPO_ROOT/logs/pipeline/local-YYYY-MM-DD.log

Useful:
  launchctl list | grep $LABEL        # see last-exit-status / pid
  tail -f $REPO_ROOT/logs/pipeline/local-\$(date -u +%Y-%m-%d).log
  bash .pipeline/bin/uninstall-launchd.sh   # stop & remove
EOF
