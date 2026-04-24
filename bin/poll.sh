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

# Gather all non-Done issues bearing any non-released stage:* label.
# Emits: JSON array [{identifier, stage_label, stage_index, priority, labels}]
# where stage_index is the position of the stage in workflow_stages (0 = earliest,
# higher = closer to stage:released). Released is excluded.
#
# Dedupes by identifier (protects against the rare race where an issue is mid
# label-swap and appears in two stage buckets). Last write wins on stage fields.
_poll_gather_stage_labeled_issues() {
  local acc='[]'
  local idx=-1
  local stage
  while IFS= read -r stage; do
    idx=$((idx+1))
    [[ "$stage" == "released" ]] && continue
    local stage_label="stage:$stage"
    local batch
    batch="$(bash "$SCRIPT_DIR/linear.sh" list-issues-with-label "$stage_label" \
      | jq -c --arg label "$stage_label" --argjson idx "$idx" '
        [.data.issues.nodes[]
         | select(.state.name != "Done")
         | {identifier:   .identifier,
            stage_label:  $label,
            stage_index:  $idx,
            priority:     (.priority // 0),
            labels:       [.labels.nodes[].name]}]')"
    acc="$(jq -c --argjson a "$acc" --argjson b "$batch" '$a + $b' <<<"$acc")"
  done < <(jq -r '.linear.workflow_stages[]' "$CONFIG")
  jq -c 'unique_by(.identifier)' <<<"$acc"
}

# Classify one issue's slot state from its labels (+ Linear comments when needed).
# Input:  ident, labels_json  (labels_json is a JSON array of label name strings)
# Output: {"slot": "hold"|"vacate"|"terminal", "advanceable": true|false}
#
# Rules (evaluated top-down, first match wins):
#   _poll_evaluate_skip returns 1 (still skipped — applies to:
#     skip-until-human-acts present, OR
#     skip-until-code-changes present AND evidence unchanged)
#                                                    → vacate
#   _poll_evaluate_skip returns 0 (include — covers:
#     no skip labels + no state file, OR
#     orphan state file cleanup, OR
#     orphan label cleanup, OR
#     skip-until-code-changes evidence changed + label cleared)
#                                                    → proceed with label-based classification
#   pipeline:abandoned                               → terminal
#   pipeline:paused                                  → vacate (human-initiated)
#   pipeline:scope-approval-needed                   → vacate (human-gated)
#   pipeline:halted (bare; evaluated via marker)     →
#     find_fresh_verdict returns empty               → hold, NOT advanceable
#                                                      (agent may have exited silently;
#                                                       next tick pre-dispatch re-checks)
#     fresh marker is pipeline-halt                  → vacate (halt-for-human / protocol-violation)
#     fresh marker is pipeline-stage-summary/rejection → hold, advanceable
#                                                      (verdict_handler will transition)
#     other marker shape                             → hold, NOT advanceable (conservative)
#   no blocker labels                                → hold, advanceable
#
# Note: _poll_evaluate_skip handles both skip-until-* label branches AND
# orphan cleanup (state file without label, or label without state file).
# Calling it up-front subsumes the skip-label case and preserves the
# orphan-cleanup behavior of pre-ENG-20 main(). For non-skip issues with
# neither label nor state file, it short-circuits to return 0 with no
# side effects — cheap.
_poll_classify_labels() {
  local ident="$1" labels_json="$2"

  if ! _poll_evaluate_skip "$ident" "$labels_json"; then
    printf '{"slot":"vacate","advanceable":false}'
    return 0
  fi

  _has_label() {
    jq -r --arg n "$1" '[.[] | select(. == $n)] | length > 0' <<<"$labels_json"
  }

  if [[ "$(_has_label pipeline:abandoned)" == "true" ]]; then
    printf '{"slot":"terminal","advanceable":false}'
    return 0
  fi

  if [[ "$(_has_label pipeline:paused)" == "true" ]] \
  || [[ "$(_has_label pipeline:scope-approval-needed)" == "true" ]]; then
    printf '{"slot":"vacate","advanceable":false}'
    return 0
  fi

  if [[ "$(_has_label pipeline:halted)" == "true" ]]; then
    local fresh
    fresh="$(find_fresh_verdict "$ident" 2>/dev/null || printf '')"
    if [[ -z "$fresh" ]]; then
      printf '{"slot":"hold","advanceable":false}'
      return 0
    fi
    local marker
    marker="$(jq -r '.marker // ""' <<<"$fresh")"
    case "$marker" in
      pipeline-stage-summary|pipeline-rejection)
        printf '{"slot":"hold","advanceable":true}' ;;
      pipeline-halt)
        printf '{"slot":"vacate","advanceable":false}' ;;
      *)
        printf '{"slot":"hold","advanceable":false}' ;;
    esac
    return 0
  fi

  printf '{"slot":"hold","advanceable":true}'
}

# Classify every issue in a gathered-issues JSON array and augment each object
# with {slot, advanceable, priority_sort_rank}.
# priority_sort_rank maps Linear priority for descending sort:
#   Urgent(1)=4, High(2)=3, Normal(3)=2, Low(4)=1, None(0)=0.
_poll_classify_all() {
  local gathered_json="$1"
  local n
  n="$(jq 'length' <<<"$gathered_json")"
  local acc='[]'
  local i=0
  while (( i < n )); do
    local item ident labels_json class augmented
    item="$(jq -c ".[$i]" <<<"$gathered_json")"
    ident="$(jq -r '.identifier' <<<"$item")"
    labels_json="$(jq -c '.labels' <<<"$item")"
    class="$(_poll_classify_labels "$ident" "$labels_json")"
    augmented="$(jq -c --argjson c "$class" '
      . + $c + {
        priority_sort_rank: (if (.priority // 0) == 0 then 0 else (5 - .priority) end)
      }' <<<"$item")"
    acc="$(jq -c --argjson a "$acc" --argjson x "$augmented" '$a + [$x]' <<<"$acc")"
    i=$((i+1))
  done
  printf '%s' "$acc"
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

  # Pass 1: gather all non-Done issues bearing any non-released stage:* label.
  local gathered
  gathered="$(_poll_gather_stage_labeled_issues)"

  # Pass 2: classify each → {slot, advanceable, priority_sort_rank, ...}.
  local classified
  classified="$(_poll_classify_all "$gathered")"

  # Pass 3: derive held slots = top-N holders sorted by
  # (stage descending toward released, Linear priority descending).
  local held
  held="$(jq -c --argjson n "$max_concurrent" '
    [.[] | select(.slot == "hold")]
    | sort_by([-(.stage_index), -(.priority_sort_rank)])
    | .[:$n]' <<<"$classified")"
  local held_count
  held_count="$(jq 'length' <<<"$held")"

  # Pass 4: attempt dispatch from held slots in sorted order.
  # First advanceable candidate that is NOT currently pending a verdict
  # transition wins. For halted-with-stage-summary-or-rejection candidates,
  # we invoke verdict_handler (same as previous behaviour) and let the
  # transition land; the new stage is picked up next tick.
  local i=0
  local hn
  hn="$(jq 'length' <<<"$held")"
  while (( i < hn )); do
    local ident stage_label labels_json advanceable
    ident="$(jq -r ".[$i].identifier"    <<<"$held")"
    stage_label="$(jq -r ".[$i].stage_label" <<<"$held")"
    labels_json="$(jq -c ".[$i].labels"   <<<"$held")"
    advanceable="$(jq -r ".[$i].advanceable" <<<"$held")"

    if [[ "$advanceable" != "true" ]]; then
      i=$((i+1)); continue
    fi

    local has_halt
    has_halt="$(jq -r --arg n "pipeline:halted" \
      '[.[] | select(. == $n)] | length > 0' <<<"$labels_json")"
    if [[ "$has_halt" == "true" ]]; then
      local cur_stage_suffix="${stage_label#stage:}"
      if verdict_handler "$ident" "$cur_stage_suffix"; then
        log "poll: verdict-handler transitioned $ident; will be picked up next tick"
      fi
      i=$((i+1)); continue
    fi

    local arg
    arg="$(stage_arg_for_label "$stage_label")"
    jq -nc \
      --arg issue_id "$ident" \
      --arg stage "$arg" \
      --arg reason "held slot at $stage_label" \
      '{issue_id:$issue_id, stage:$stage, entry_action:"run", reason:$reason}'
    exit 0
  done

  # Pass 5: inbox pickup, only if a slot is available.
  if (( held_count >= max_concurrent )); then
    idle "max-concurrent-reached (held=$held_count, limit=$max_concurrent)"
  fi

  local inbox_state
  inbox_state="$(config_get '.linear.native_states.inbox')"
  local inbox_pick
  inbox_pick="$(bash "$SCRIPT_DIR/linear.sh" list-issues-in-state "$inbox_state" \
    | jq -r '
      [.data.issues.nodes[]
       | select([.labels.nodes[].name] | any(startswith("stage:")) | not)
       | select([.labels.nodes[].name] | index("pipeline:paused") | not)
       | select([.labels.nodes[].name] | index("pipeline:abandoned") | not)
       | {identifier: .identifier,
          priority_sort_rank: (if (.priority // 0) == 0 then 0 else (5 - .priority) end)}]
      | sort_by(-.priority_sort_rank)
      | .[0].identifier // ""')"
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
