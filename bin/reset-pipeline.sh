#!/usr/bin/env bash
# Reset pipeline halt/error state.
# Usage:
#   reset-pipeline.sh                    # global reset: unpause, clear counter
#   reset-pipeline.sh <issue_id>         # global + clear that issue's state/labels
#
# Clears:
#   - $HARNESS_STATE_DIR/.consecutive-failures     (circuit-breaker counter)
#   - orchestrator.paused in $STATE_FILE           (flipped back to false via set_orchestrator_paused)
#   - $HARNESS_STATE_DIR/<ID>/issue-state.json     (per-issue classify_failure record)
#   - Linear labels pipeline:skip-until-code-changes / pipeline:skip-until-human-acts

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

# HARNESS_STATE_DIR + CONFIG are exported by common.sh.

main() {
  local issue="${1:-}"

  if [[ -f "$HARNESS_STATE_DIR/.consecutive-failures" ]]; then
    rm -f "$HARNESS_STATE_DIR/.consecutive-failures"
    log "cleared $HARNESS_STATE_DIR/.consecutive-failures"
  fi

  if [[ "$(is_orchestrator_paused)" == "true" ]]; then
    set_orchestrator_paused false
    log "reset orchestrator.paused=false in $STATE_FILE"
  fi

  if [[ -n "$issue" ]]; then
    local state_file; state_file="$(issue_dir "$issue")/issue-state.json"
    if [[ -f "$state_file" ]]; then
      rm -f "$state_file"
      log "cleared $state_file"
    fi
    bash "$SCRIPT_DIR/linear.sh" remove-label "$issue" "pipeline:skip-until-code-changes" 2>/dev/null || true
    bash "$SCRIPT_DIR/linear.sh" remove-label "$issue" "pipeline:skip-until-human-acts"   2>/dev/null || true
    log "removed skip-until-* labels from $issue"
  fi

  log "pipeline reset complete${issue:+ for $issue}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
