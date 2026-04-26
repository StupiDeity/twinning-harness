#!/usr/bin/env bash
# Append a pipeline event to ~/.twinning-pipeline/metrics/events.jsonl.
# Usage: metrics.sh <event> <issue_id> <stage> <outcome> <duration_ms> [notes...]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

main() {
  local event="${1:-}" issue_id="${2:-}" stage="${3:-}" outcome="${4:-}" duration_ms="${5:-0}"
  shift 5 || true
  local notes="${*:-}"

  [[ -n "$event" && -n "$outcome" ]] || die "usage: metrics.sh <event> <issue_id> <stage> <outcome> <duration_ms> [notes]"

  local jsonl_file="$PROJECT_STATE_DIR/metrics/events.jsonl"
  local iso_ts
  iso_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  mkdir -p "$(dirname "$jsonl_file")"

  jq -cn \
    --arg ts "$iso_ts" \
    --arg event "$event" \
    --arg issue_id "${issue_id:-}" \
    --arg stage "${stage:-}" \
    --arg outcome "$outcome" \
    --argjson duration_ms "${duration_ms:-0}" \
    --arg notes "${notes:-}" \
    '{ts:$ts, event:$event, issue_id:$issue_id, stage:$stage, outcome:$outcome, duration_ms:$duration_ms, notes:$notes}' \
    >> "$jsonl_file"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
