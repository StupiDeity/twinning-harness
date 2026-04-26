#!/usr/bin/env bash
# Render and load the per-project launchd pair.
#
# Usage: bash bin/install-launchd.sh /path/to/target

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_REPO="${TARGET_REPO:-${1:-}}"
[[ -n "$TARGET_REPO" && -d "$TARGET_REPO" ]] || {
  printf 'usage: bash bin/install-launchd.sh /path/to/target\n' >&2; exit 64; }
export TARGET_REPO
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

LAUNCHD_DIR="$HOME/Library/LaunchAgents"
DOMAIN="gui/$(id -u)"
mkdir -p "$LAUNCHD_DIR" "$PROJECT_STATE_DIR/logs"

install_one() {
  local kind="$1" kickstart="$2"     # kind: pipeline | retrospective
  local label="com.twinning.${kind}.${PROJECT_SLUG}"
  local template="$HARNESS_ROOT/launchd/com.twinning.${kind}.plist.template"
  local target="$LAUNCHD_DIR/${label}.plist"
  [[ -f "$template" ]] || die "missing template: $template"

  sed \
    -e "s|__HARNESS_ROOT__|$HARNESS_ROOT|g" \
    -e "s|__TARGET_REPO__|$TARGET_REPO|g" \
    -e "s|__HARNESS_STATE_DIR__|$HARNESS_STATE_DIR|g" \
    -e "s|__PROJECT_SLUG__|$PROJECT_SLUG|g" \
    -e "s|__HOME__|$HOME|g" \
    "$template" > "$target"
  log "rendered $target"

  if launchctl print "$DOMAIN/$label" >/dev/null 2>&1; then
    launchctl bootout "$DOMAIN/$label" || true
    log "bootout $label"
  fi
  launchctl bootstrap "$DOMAIN" "$target"
  log "bootstrap $label"
  if [[ "$kickstart" == "1" ]]; then
    launchctl kickstart -k "$DOMAIN/$label"
    log "kickstart $label"
  fi
}

install_one pipeline      1
install_one retrospective 0

cat <<EOF

Pipeline LaunchAgents installed for project '$PROJECT_SLUG':
  com.twinning.pipeline.$PROJECT_SLUG       — every 5 min
  com.twinning.retrospective.$PROJECT_SLUG  — Mondays 09:00
  Logs: $PROJECT_STATE_DIR/logs/launchd.{out,err}.log
EOF
