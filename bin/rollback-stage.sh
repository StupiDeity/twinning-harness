#!/usr/bin/env bash
# Un-advance a Linear issue's stage label with a reason + metrics event.
# Usage: rollback-stage.sh <issue_id> <to_stage> <reason>
#
# The pipeline's state machine is mostly forward-only (run-stage.sh advances on
# success). When a downstream stage discovers that an upstream artifact is wrong
# — e.g., QA finds the plan's Failure Mode Test Map was incomplete — the only
# built-in backward edge is review→brainstorm via `pipeline:premise-failure`.
# This script generalises: from any stage:X label, roll back to stage:Y with
# a durable metric entry. Respects PIPELINE_DRY_RUN.
#
# Valid backward targets (forward rolls not allowed here — use run-stage.sh):
#   from stage:planning      → brainstorming
#   from stage:implementing  → planning | brainstorming
#   from stage:ui            → implementing | planning
#   from stage:reviewing     → implementing | ui | planning | brainstorming
#   from stage:qa            → implementing | ui | planning
#   from stage:building      → implementing | reviewing | qa
# No rollback from stage:released (that's terminal; use mark-abandoned.sh + revert).

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

# Stage ordering for forward-only validation.
stage_rank() {
  case "$1" in
    brainstorming) echo 1 ;;
    planning)      echo 2 ;;
    implementing)  echo 3 ;;
    ui)            echo 4 ;;
    reviewing)     echo 5 ;;
    qa)            echo 6 ;;
    building)      echo 7 ;;
    released)      echo 8 ;;
    *)             echo 0 ;;
  esac
}

main() {
  local issue_id="${1:-}" to_stage="${2:-}" reason="${*:3}"
  [[ -n "$issue_id" && -n "$to_stage" && -n "$reason" ]] \
    || die "usage: rollback-stage.sh <issue_id> <to_stage> <reason>"

  local current
  current="$(bash "$SCRIPT_DIR/linear.sh" stage-of "$issue_id" 2>/dev/null || true)"
  current="${current#stage:}"
  [[ -n "$current" ]] || die "issue $issue_id has no stage:* label; cannot roll back"

  local cur_rank tgt_rank
  cur_rank="$(stage_rank "$current")"
  tgt_rank="$(stage_rank "$to_stage")"

  [[ "$cur_rank" != "0" ]] || die "unknown current stage: $current"
  [[ "$tgt_rank" != "0" ]] || die "unknown target stage: $to_stage"
  (( tgt_rank < cur_rank )) \
    || die "rollback requires target stage to be earlier than current ($to_stage rank=$tgt_rank vs $current rank=$cur_rank); use run-stage.sh for forward moves"
  [[ "$current" != "released" ]] \
    || die "cannot roll back from released; use mark-abandoned.sh and revert via git"

  log "rollback: $issue_id $current -> $to_stage reason=$reason"

  bash "$SCRIPT_DIR/linear.sh" swap-stage "$issue_id" "$to_stage"

  # ENG-11: drop stale stage-summary files for stages we just rolled through, so
  # the forward re-run publishes fresh substance rather than recycling pre-rollback bodies.
  local _r short summary
  for (( _r = tgt_rank + 1; _r <= cur_rank; _r++ )); do
    case "$_r" in
      1) short=brainstorm ;; 2) short=plan ;; 3) short=implement ;;
      4) short=ui         ;; 5) short=review ;; 6) short=qa ;;
      7) short=build      ;; *) continue ;;
    esac
    summary="$(issue_dir "$issue_id")/stage-summary-${short}.md"
    if [[ -f "$summary" ]]; then
      rm -f "$summary"
      log "rollback: cleared $summary"
    fi
  done

  bash "$SCRIPT_DIR/linear.sh" add-comment "$issue_id" \
    "Pipeline rollback: \`stage:${current}\` → \`stage:${to_stage}\`. Reason: $reason"
  bash "$SCRIPT_DIR/metrics.sh" stage-rollback "$issue_id" "$current" "rolled-back" 0 \
    "to=$to_stage reason=\"$reason\""
  bash "$SCRIPT_DIR/slack.sh" warn \
    "Rollback $issue_id: stage:${current} → stage:${to_stage} — $reason"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
