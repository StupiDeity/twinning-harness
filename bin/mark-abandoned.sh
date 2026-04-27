#!/usr/bin/env bash
# Mark a pipeline issue as abandoned and emit a metrics event.
# Usage: mark-abandoned.sh <issue_id> <reason>
# Applies `pipeline:abandoned` label, posts a Linear comment, and writes a
# terminal pipeline-metrics event so retrospective survivorship analysis can
# detect the abandonment (otherwise abandoned work is invisible — see Retrospective
# Gap 4).

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

# ENG-41 T3: human lane — operator CLI; all Linear writes are unrestricted.
export PIPELINE_WRITER=human

main() {
  local issue_id="${1:-}" reason="${*:2}"
  [[ -n "$issue_id" && -n "$reason" ]] || die "usage: mark-abandoned.sh <issue_id> <reason>"

  local current_stage
  current_stage="$(bash "$SCRIPT_DIR/linear.sh" stage-of "$issue_id" 2>/dev/null || true)"
  current_stage="${current_stage#stage:}"

  log "mark-abandoned: $issue_id current_stage=${current_stage:-none} reason=$reason"

  bash "$SCRIPT_DIR/linear.sh" add-label "$issue_id" "pipeline:abandoned"
  bash "$SCRIPT_DIR/linear.sh" add-comment "$issue_id" \
    "Pipeline: issue marked abandoned (\`pipeline:abandoned\`). Reason: $reason. Retrospective will pick this up in survivorship analysis. Remove the label to resume."
  bash "$SCRIPT_DIR/metrics.sh" stage-abandon "$issue_id" "${current_stage:-unknown}" "abandoned" 0 "reason=\"$reason\""
  bash "$SCRIPT_DIR/slack.sh" warn "Issue $issue_id abandoned at stage:${current_stage:-unknown} — $reason"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
