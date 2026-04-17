#!/usr/bin/env bash
# POST a simple message to a Slack incoming webhook if PIPELINE_SLACK_WEBHOOK_URL is set.
# No-op otherwise. Safe to call from any stage.
# Usage: slack.sh <level> <message>
#   level: info | warn | error

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

main() {
  local level="${1:-info}" message="${2:-}"
  [[ -n "$message" ]] || die "usage: slack.sh <level> <message>"

  if [[ -z "${PIPELINE_SLACK_WEBHOOK_URL:-}" ]]; then
    log "slack.sh: no webhook configured; skipping ($level: $message)"
    return 0
  fi

  local emoji
  case "$level" in
    info)  emoji=":information_source:" ;;
    warn)  emoji=":warning:" ;;
    error) emoji=":rotating_light:" ;;
    *)     emoji=":gear:" ;;
  esac

  if [[ "$PIPELINE_DRY_RUN" == "1" ]]; then
    log "slack.sh [DRY_RUN] would post: $emoji $message"
    return 0
  fi

  local payload
  payload="$(jq -cn --arg text "$emoji [pipeline] $message" '{text: $text}')"
  curl -fsS -X POST -H 'Content-Type: application/json' \
    --data "$payload" "$PIPELINE_SLACK_WEBHOOK_URL" >/dev/null \
    || log "slack.sh: webhook post failed (non-fatal)"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
