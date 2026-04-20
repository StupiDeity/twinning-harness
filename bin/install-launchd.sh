#!/usr/bin/env bash
# Render and load both pipeline LaunchAgents:
#   - com.twinning.pipeline       (every 5 min; main per-issue tick + release watcher)
#   - com.twinning.retrospective  (weekly Mon 09:00; retrospective agent + PR)
# Idempotent: bootout any previous version first.
#
# Usage: bash .pipeline/bin/install-launchd.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

TARGET_DIR="$HOME/Library/LaunchAgents"
DOMAIN="gui/$(id -u)"

mkdir -p "$TARGET_DIR"
mkdir -p "$REPO_ROOT/logs/pipeline"

# $1=label, $2=kickstart(1|0). We kickstart the 5-min pipeline so it runs once
# immediately; the retrospective runs on calendar schedule only.
install_plist() {
  local label="$1" kickstart="$2"
  local template="$PIPELINE_ROOT/launchd/${label}.plist.template"
  local target="$TARGET_DIR/${label}.plist"

  [[ -f "$template" ]] || die "plist template missing: $template"

  sed \
    -e "s|{{REPO_ROOT}}|$REPO_ROOT|g" \
    -e "s|{{HOME}}|$HOME|g" \
    "$template" > "$target"
  log "rendered $target"

  if launchctl print "$DOMAIN/$label" >/dev/null 2>&1; then
    log "unloading previous agent $label"
    launchctl bootout "$DOMAIN/$label"
  fi

  launchctl bootstrap "$DOMAIN" "$target"
  log "loaded $label into $DOMAIN"

  if [[ "$kickstart" == "1" ]]; then
    launchctl kickstart -k "$DOMAIN/$label"
    log "kickstarted $label"
  fi
}

install_plist "com.twinning.pipeline"      1
install_plist "com.twinning.retrospective" 0

cat <<EOF

Pipeline LaunchAgents installed.
  com.twinning.pipeline       — every 5 min, main tick + release watcher
  com.twinning.retrospective  — weekly Mon 09:00, retrospective agent + PR
  Domain:  $DOMAIN
  Logs:    $REPO_ROOT/logs/pipeline/launchd.{out,err}.log
           $REPO_ROOT/logs/pipeline/retrospective-launchd.{out,err}.log
           $REPO_ROOT/logs/pipeline/local-YYYY-MM-DD.log

Useful:
  launchctl list | grep com.twinning
  tail -f $REPO_ROOT/logs/pipeline/local-\$(date -u +%Y-%m-%d).log
  bash .pipeline/bin/uninstall-launchd.sh    # stop & remove both
EOF
