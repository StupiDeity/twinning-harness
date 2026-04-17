#!/usr/bin/env bash
# Scan Linear for the next actionable (issue, stage) to run.
# Emits a JSON decision to stdout and exits 0, OR emits {"issue_id": null} when idle.
# Does NOT dispatch — that's run-stage.sh. The caller (pipeline.yml) chains them.
#
# Rules:
#   1. Skip entirely if config.orchestrator.paused == true.
#   2. Respect max_concurrent_features: count issues currently in any stage:* label
#      that are not stage:released. If >= max, return idle.
#   3. Otherwise, find the highest-priority ready issue and emit { issue_id, stage, entry_action }.
#      entry_action is "apply-stage-label" when the issue is being picked up from Todo, else "run".
#
# Priority:
#   a. Issues in Todo with no stage:* label → candidate for brainstorm entry.
#   b. Issues with any stage:* label (≠ stage:released, ≠ paused, status still In Progress) →
#      candidate for their current stage to progress.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

STAGE_LABEL_TO_STAGE_ARG='
stage:brainstorming=brainstorm
stage:planning=plan
stage:implementing=implement
stage:ui=ui
stage:reviewing=review
stage:qa=qa
stage:building=build
'
# stage:released is terminal — not polled.

stage_arg_for_label() {
  grep -E "^${1}=" <<<"$STAGE_LABEL_TO_STAGE_ARG" | head -1 | cut -d= -f2-
}

idle() {
  local reason="${1:-}"
  bash "$SCRIPT_DIR/metrics.sh" poll-tick "" "" "idle" 0 "$reason" || true
  printf '{"issue_id":null,"stage":null,"reason":%s}\n' "$(jq -Rn --arg r "$reason" '$r')"
  exit 0
}

main() {
  require_env LINEAR_API_KEY

  local paused
  paused="$(config_get '.orchestrator.paused')"
  [[ "$paused" == "true" ]] && idle "orchestrator-paused"

  local max_concurrent
  max_concurrent="$(config_get '.orchestrator.max_concurrent_features')"

  # Count currently active features (any non-terminal stage label).
  local active_count=0
  while IFS= read -r stage_label; do
    local arg; arg="$(stage_arg_for_label "$stage_label")"
    [[ -z "$arg" ]] && continue
    local n
    n="$(bash "$SCRIPT_DIR/linear.sh" list-issues-with-label "$stage_label" \
      | jq '[.data.issues.nodes[] | select(.state.name != "Done")] | length')"
    active_count=$((active_count + n))
  done < <(jq -r '.linear.workflow_stages[] | "stage:" + .' "$CONFIG" | grep -v '^stage:released$')

  if (( active_count >= max_concurrent )); then
    idle "max-concurrent-reached (active=$active_count, limit=$max_concurrent)"
  fi

  # 1. Active issues: find one needing its current stage run.
  # We iterate stages in canonical order so early stages get priority over late ones.
  while IFS= read -r stage_label; do
    local arg; arg="$(stage_arg_for_label "$stage_label")"
    [[ -z "$arg" ]] && continue

    # Find the most-recently-updated issue at this stage that isn't paused and isn't Done.
    local pick
    pick="$(bash "$SCRIPT_DIR/linear.sh" list-issues-with-label "$stage_label" \
      | jq -r '
        [.data.issues.nodes[]
         | select(.state.name != "Done")
         | select([.labels.nodes[].name] | index("pipeline:paused") | not)
         | .identifier] | first // ""')"
    if [[ -n "$pick" ]]; then
      jq -nc \
        --arg issue_id "$pick" \
        --arg stage "$arg" \
        --arg reason "active at $stage_label" \
        '{issue_id:$issue_id, stage:$stage, entry_action:"run", reason:$reason}'
      exit 0
    fi
  done < <(jq -r '.linear.workflow_stages[] | "stage:" + .' "$CONFIG" | grep -v '^stage:released$')

  # 2. Inbox: find a Todo-state issue with no stage:* label.
  local inbox_state
  inbox_state="$(config_get '.linear.native_states.inbox')"
  local inbox_pick
  inbox_pick="$(bash "$SCRIPT_DIR/linear.sh" list-issues-in-state "$inbox_state" \
    | jq -r '
      [.data.issues.nodes[]
       | select([.labels.nodes[].name] | any(startswith("stage:")) | not)
       | select([.labels.nodes[].name] | index("pipeline:paused") | not)
       | .identifier] | first // ""')"
  if [[ -n "$inbox_pick" ]]; then
    jq -nc \
      --arg issue_id "$inbox_pick" \
      --arg stage "brainstorm" \
      --arg reason "inbox pickup" \
      '{issue_id:$issue_id, stage:$stage, entry_action:"apply-stage-label", reason:$reason}'
    exit 0
  fi

  idle "no-work"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
