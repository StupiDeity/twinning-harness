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
# shellcheck source=verdict-handler.sh
source "$SCRIPT_DIR/verdict-handler.sh"

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

# Return 0 iff the candidate should be INCLUDED (i.e., not currently in a
# resolved-but-cleared skip state). Side effects: if the skip state's evidence
# has changed, deletes the state file and removes the label. For orphan
# labels (no state file), removes the label and includes the candidate.
# For orphan state files (label absent), deletes the state file.
_poll_evaluate_skip() {
  local ident="$1" labels_json="$2"
  local state_file; state_file="$(issue_dir "$ident")/issue-state.json"
  local has_code_label has_human_label
  has_code_label="$(jq -r --arg n "pipeline:skip-until-code-changes" \
    '[.[] | select(. == $n)] | length > 0' <<<"$labels_json")"
  has_human_label="$(jq -r --arg n "pipeline:skip-until-human-acts" \
    '[.[] | select(. == $n)] | length > 0' <<<"$labels_json")"

  # No skip label AND no state file → normal eligible candidate.
  if [[ "$has_code_label" != "true" && "$has_human_label" != "true" ]]; then
    if [[ -f "$state_file" ]]; then
      log "poll: orphan state file for $ident (no skip label); removing"
      rm -f "$state_file"
    fi
    return 0
  fi

  # Label without file → orphan; remove label, include.
  if [[ ! -f "$state_file" ]]; then
    log "poll: orphan skip label on $ident (no state file); clearing"
    [[ "$has_code_label" == "true" ]]  && bash "$SCRIPT_DIR/linear.sh" remove-label "$ident" "pipeline:skip-until-code-changes" || true
    [[ "$has_human_label" == "true" ]] && bash "$SCRIPT_DIR/linear.sh" remove-label "$ident" "pipeline:skip-until-human-acts"   || true
    return 0
  fi

  # skip-until-human-acts: label present → still skipped. Include NOT allowed.
  if [[ "$has_human_label" == "true" ]]; then
    return 1
  fi

  # skip-until-code-changes: recompute evidence; include iff changed.
  local prev_hash prev_sha branch current_hash current_sha
  prev_hash="$(jq -r '.evidence.pipeline_content_hash // ""' "$state_file")"
  prev_sha="$(jq -r '.evidence.branch_head_sha // ""'       "$state_file")"
  branch="$(jq -r '.branch // ""'                            "$state_file")"
  current_hash="$(compute_pipeline_content_hash)"
  if [[ -n "$branch" ]]; then
    current_sha="$(git -C "$REPO_ROOT" ls-remote origin "$branch" 2>/dev/null | awk '{print $1}' | head -1 || true)"
  else
    current_sha=""
  fi

  if [[ "$prev_hash" != "$current_hash" ]] || [[ "$prev_sha" != "$current_sha" ]]; then
    log "poll: evidence changed for $ident; clearing skip state"
    rm -f "$state_file"
    bash "$SCRIPT_DIR/linear.sh" remove-label "$ident" "pipeline:skip-until-code-changes" || true
    return 0
  fi
  return 1
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

    # Enumerate candidates + labels; helper decides include/exclude.
    local cand_json
    cand_json="$(bash "$SCRIPT_DIR/linear.sh" list-issues-with-label "$stage_label" \
      | jq -c '
        [.data.issues.nodes[]
         | select(.state.name != "Done")
         | select([.labels.nodes[].name] | index("pipeline:paused") | not)
         | select([.labels.nodes[].name] | index("pipeline:abandoned") | not)
         | select([.labels.nodes[].name] | index("pipeline:scope-approval-needed") | not)
         | {identifier: .identifier, labels: [.labels.nodes[].name]}]')"

    local pick=""
    local candidates_count
    candidates_count="$(jq 'length' <<<"$cand_json")"
    local i=0
    while (( i < candidates_count )); do
      local ident labels_json
      ident="$(jq -r ".[$i].identifier" <<<"$cand_json")"
      labels_json="$(jq -c ".[$i].labels" <<<"$cand_json")"

      # Pre-dispatch: process pending verdicts on halted issues. If the
      # fresh marker is pass/reject, the Verdict Handler transitions and
      # clears halt; the next tick will then see the new stage. If the
      # fresh marker is a halt-for-human (rc=1) or protocol violation
      # (rc=2), leave as-is and skip dispatching this candidate.
      local has_halt
      has_halt="$(jq -r --arg n "pipeline:halted" \
        '[.[] | select(. == $n)] | length > 0' <<<"$labels_json")"
      if [[ "$has_halt" == "true" ]]; then
        local cur_stage_suffix="${stage_label#stage:}"
        if verdict_handler "$ident" "$cur_stage_suffix"; then
          log "poll: verdict-handler transitioned $ident; will be picked up next tick"
        fi
        i=$((i+1))
        continue
      fi

      if _poll_evaluate_skip "$ident" "$labels_json"; then
        pick="$ident"; break
      fi
      i=$((i+1))
    done

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
       | select([.labels.nodes[].name] | index("pipeline:abandoned") | not)
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
