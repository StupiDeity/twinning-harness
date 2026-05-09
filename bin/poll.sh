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
stage:brainstorming=brainstorming
stage:planning=planning
stage:implementing=implementing
stage:ui=ui
stage:reviewing=reviewing
stage:qa=qa
stage:building=building
'
# stage:released is terminal — not polled.

stage_arg_for_label() {
  grep -E "^${1}=" <<<"$STAGE_LABEL_TO_STAGE_ARG" | head -1 | cut -d= -f2-
}

# Return 0 iff the candidate should be INCLUDED (i.e., not currently in a
# resolved-but-cleared skip state). Side effects: if the skip state's
# evidence has changed, deletes the state file, removes the
# skip-until-code-changes label, and (if pipeline:halted is also present)
# clears the halt label and posts a `pipeline: decision action=continue` marker.
# For orphan state files (label absent), deletes the state file. For a
# skip label without a state file, skips and performs no Linear writes
# — see ENG-24.
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
      # ENG-78: a state file with policy=retry-immediately is NOT
      # orphan — it's the durable retry-tracking record that
      # classify_failure's auto-escalation guard reads on every tick
      # to compute retry_count. Removing it would reset the counter
      # to 0 each tick and break the 2-retry escalation cap. Only
      # delete state files whose policy is genuinely orphaned (the
      # original use case: human removed a skip label without
      # removing the file, or pre-ENG-78 leftover).
      local cur_policy
      cur_policy="$(jq -r '.policy // ""' "$state_file" 2>/dev/null || true)"
      if [[ "$cur_policy" == "retry-immediately" ]]; then
        log "poll: keeping retry-immediately state for $ident (active retry tracking, ENG-78)"
      else
        log "poll: orphan state file for $ident (no skip label, policy=$cur_policy); removing"
        rm -f "$state_file"
      fi
    fi
    return 0
  fi

  # Skip label present without a state file → respect the label and skip.
  # Either a human applied it (the documented contract — see
  # bin/setup-labels.sh:38) or classify-failure.sh has not yet written the
  # state file. In every case, the conservative default is to leave the
  # label in place and let either a human remove-label call or the next
  # classify-failure.sh write resolve. Do NOT call linear.sh remove-label
  # here — that silently undid human pauses (ENG-24 Bug B).
  if [[ ! -f "$state_file" ]]; then
    log "poll: $ident has skip label without state file (code=$has_code_label human=$has_human_label); skipping"
    return 1
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
    current_sha="$(git -C "$TARGET_REPO" ls-remote origin "$branch" 2>/dev/null | awk '{print $1}' | head -1 || true)"
  else
    current_sha=""
  fi

  if [[ "$prev_hash" != "$current_hash" ]] || [[ "$prev_sha" != "$current_sha" ]]; then
    log "poll: evidence changed for $ident; clearing skip state"
    rm -f "$state_file"
    bash "$SCRIPT_DIR/linear.sh" remove-label "$ident" "pipeline:skip-until-code-changes" || true
    # classify-failure pairs every skip-until-code-changes halt with a
    # pipeline:halted label and a `<!-- pipeline: verdict result=halt -->`
    # marker comment. Without also clearing the halt label here,
    # _poll_classify_labels' halted branch keeps the slot vacated and
    # auto-resume can never actually advance the issue. Post an
    # informational decision marker (not a verdict shape — does not
    # affect find_fresh_verdict freshness) and remove the label.
    local has_halt
    has_halt="$(jq -r --arg n "pipeline:halted" \
      '[.[] | select(. == $n)] | length > 0' <<<"$labels_json")"
    if [[ "$has_halt" == "true" ]]; then
      local resume_body
      resume_body="$(printf '<!-- pipeline: decision action=continue -->\n\nHalt auto-resolved by orchestrator: pipeline_content_hash or branch HEAD changed.')"
      bash "$SCRIPT_DIR/linear.sh" add-comment  "$ident" "$resume_body"   || true
      bash "$SCRIPT_DIR/linear.sh" remove-label "$ident" "pipeline:halted" || true
    fi
    # Emit the post-resume labels on stdout so the caller can re-classify
    # within the same tick. Without this, the local labels_json snapshot
    # still has pipeline:halted, _poll_classify_labels' halted branch
    # fires, and the slot stays vacated for one extra tick (~5 min).
    jq -c '[.[] | select(. != "pipeline:halted" and . != "pipeline:skip-until-code-changes")]' <<<"$labels_json"
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
# Output: {"slot": "hold"|"vacate"|"terminal", "advanceable": true|false,
#          "labels": [name, ...]}
# The emitted "labels" reflects any auto-resume label mutations from
# _poll_evaluate_skip; _poll_classify_all merges it onto the gathered item
# so Pass 4 reads the post-resume label set in the same tick.
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
#
# ENG-90: every `slot:"vacate"` output declares operator_action_required.
# See CLAUDE.md "Slot-occupancy contract (ENG-90)" before adding new
# branches.
_poll_classify_labels() {
  local ident="$1" labels_json="$2"
  local refreshed_labels=""

  if ! refreshed_labels="$(_poll_evaluate_skip "$ident" "$labels_json")"; then
    # ENG-90 D-005: differentiate the two skip kinds.
    # skip-until-human-acts is operator-action-required (operator removes
    # the label). skip-until-code-changes with evidence unchanged is
    # auto-recallable: the next-tick _poll_evaluate_skip re-checks
    # pipeline_content_hash + branch SHA and clears the label mid-tick on
    # change (line 109-134).
    local oar="false"
    if [[ "$(jq -r --arg n "pipeline:skip-until-human-acts" \
            '[.[] | select(. == $n)] | length > 0' <<<"$labels_json")" == "true" ]]; then
      oar="true"
    fi
    jq -nc --argjson l "$labels_json" --argjson oar "$oar" \
      '{slot:"vacate",advanceable:false,operator_action_required:$oar,labels:$l}'
    return 0
  fi
  # _poll_evaluate_skip prints a refreshed labels_json on auto-resume so
  # downstream label checks (here AND in Pass 4) see the post-resume
  # state within the same tick. Empty stdout means no refresh needed —
  # echo back the input labels_json verbatim.
  [[ -n "$refreshed_labels" ]] && labels_json="$refreshed_labels"

  _has_label() {
    jq -r --arg n "$1" '[.[] | select(. == $n)] | length > 0' <<<"$labels_json"
  }

  local class fresh_wait
  if [[ "$(_has_label pipeline:abandoned)" == "true" ]]; then
    class='{"slot":"terminal","advanceable":false}'
  elif [[ "$(_has_label pipeline:paused)" == "true" ]] \
    || [[ "$(_has_label pipeline:scope-approval-needed)" == "true" ]]; then
    # ENG-90 D-001: human-applied paused / scope-approval-needed labels
    # require an operator action (label removal) before the slot recalls.
    class='{"slot":"vacate","advanceable":false,"operator_action_required":true}'
  elif [[ "$(_has_label pipeline:halted)" == "true" ]]; then
    local fresh
    fresh="$(find_fresh_verdict "$ident" 2>/dev/null || printf '')"
    if [[ -n "$fresh" ]]; then
      local marker
      marker="$(jq -r '.marker // ""' <<<"$fresh")"
      case "$marker" in
        pipeline-stage-summary|pipeline-rejection)
          # Verdict-handler-led transition is upcoming in Pass 4; the halt
          # label is consumed by apply_transition. Slot remains held
          # (active dispatch work).
          class='{"slot":"hold","advanceable":true}' ;;
        *)
          # ENG-90 D-003: pipeline-halt OR unknown marker. Halt label gates
          # dispatch — no agent compute will run regardless of marker
          # shape. Operator must run `bin/pipeline.sh decide --action
          # continue`.
          class='{"slot":"vacate","advanceable":false,"operator_action_required":true}' ;;
      esac
    else
      # ENG-90 D-003: no fresh marker (silent agent crash, externally-
      # applied label, or marker race with this tick). Halt label still
      # gates dispatch — no agent compute will run. Operator must run
      # `bin/pipeline.sh decide --action continue`.
      class='{"slot":"vacate","advanceable":false,"operator_action_required":true}'
    fi
  elif fresh_wait="$(find_fresh_wait_verdict "$ident" 2>/dev/null)"; [[ -n "$fresh_wait" ]]; then
    # ENG-85: a wait verdict newer than the most recent transition vacates
    # the slot. Symmetric with the pipeline-halt arm above — both express
    # agent-idle-on-external-signal. Pass 6 in main() picks wait-recallable
    # issues only when no held / inbox work is ready. ENG-90 D-001:
    # operator_action_required=false — _handle_wait re-runs the predicate
    # on the next tick.
    local _wait_ts
    _wait_ts="$(jq -r '.created_at' <<<"$fresh_wait")"
    class="$(jq -nc --arg ts "$_wait_ts" \
      '{slot:"vacate", advanceable:false, wait_recallable:true, wait_progress_ts:$ts, operator_action_required:false}')"
  elif [[ "$(_has_label stage:reviewing)" == "true" ]]; then
    # ENG-50: gate review dispatch on observable PR state.
    # ENG-53 #12: derive the branch via bin/branch-name.sh (same convention
    # that creates the worktree branch) instead of via Linear's
    # `gitBranchName` field. Two reasons:
    # 1. bin/linear.sh::get_issue does not select gitBranchName in its
    #    GraphQL query (ENG-53 #1), so the prior expression returned empty
    #    in production. Empty branch hit the "fail open" path → review
    #    re-dispatched on every 5-min tick during the awaiting-approval
    #    wait state, accumulating self-leak scratch files (observed on
    #    ENG-44's dogfood: review-2 through review-5 in a tight loop).
    # 2. Linear's gitBranchName auto-format
    #    (`rajatgoyal/eng-N-with_underscores`) does not match the harness's
    #    actual branch (`feat/eng-N-with-hyphens`), so even with linear.sh
    #    fixed, `gh pr view --branch <wrong-name>` would fail → review_
    #    should_dispatch's defensive dispatch path → same loop.
    local _rp_branch
    _rp_branch="$(bash "$SCRIPT_DIR/branch-name.sh" "$ident" 2>/dev/null || true)"
    if [[ -z "$_rp_branch" ]]; then
      # Branch derivation failed (e.g., Linear API down, title unfetchable).
      # Fail open — dispatch as before.
      class='{"slot":"hold","advanceable":true}'
    else
      # shellcheck source=review-poll.sh
      source "$SCRIPT_DIR/review-poll.sh"
      if review_should_dispatch "$ident" "$_rp_branch"; then
        class='{"slot":"hold","advanceable":true}'
      else
        # ENG-90 D-002: PR not mergeable / checks pending. Agent dispatch
        # will not run; the next tick re-evaluates review_should_dispatch
        # (cheap orchestrator-side state check). Vacate the slot so
        # sibling work can dispatch.
        class='{"slot":"vacate","advanceable":false,"operator_action_required":false}'
      fi
    fi
  else
    class='{"slot":"hold","advanceable":true}'
  fi

  jq -nc --argjson c "$class" --argjson l "$labels_json" '$c + {labels:$l}'
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
    # `class` includes a `labels` key reflecting any auto-resume label
    # mutations; merging it after $item lets it override .labels so Pass 4
    # reads the post-resume label set.
    augmented="$(jq -c --argjson c "$class" '
      . + $c + {
        priority_sort_rank: (if (.priority // 0) == 0 then 0 else (5 - .priority) end)
      }' <<<"$item")"
    acc="$(jq -c --argjson a "$acc" --argjson x "$augmented" '$a + [$x]' <<<"$acc")"
    i=$((i+1))
  done
  printf '%s' "$acc"
}

# Emit a per-tick halt-sprawl alert when the count of slot=="vacate"
# entries in the classified array exceeds the configured threshold.
#
# Behaviour (ENG-21):
#   - threshold read from .orchestrator.alert_on_halted_over
#   - missing / null / non-integer key → feature disabled (one log line, early return)
#   - count > threshold (strict GT) → always append halt-sprawl metric row
#   - if $PIPELINE_SLACK_WEBHOOK_URL is set AND debounce file is absent or >86400s old:
#       → fire slack.sh warn "..." naming the first 3 vacate identifiers
#       → stamp ~/.twinning-pipeline/.halt-sprawl-last-alerted with current ISO-8601 UTC
#   - metric emission never fails the tick (|| true, mirroring poll.sh:235)
#
# Input:  classified_json (JSON array produced by _poll_classify_all)
# Output: none
# Side effects: writes to $PROJECT_STATE_DIR/metrics/events.jsonl and
#               $PROJECT_STATE_DIR/.halt-sprawl-last-alerted; may POST to Slack.
_poll_emit_halt_sprawl_alert() {
  local classified_json="$1"

  local threshold
  threshold="$(config_get '.orchestrator.alert_on_halted_over')"
  if [[ -z "$threshold" ]] || [[ "$threshold" == "null" ]]; then
    log "halt-sprawl: threshold unset; alert disabled"
    return 0
  fi
  if ! [[ "$threshold" =~ ^[0-9]+$ ]]; then
    log "halt-sprawl: non-integer threshold ($threshold); alert disabled"
    return 0
  fi

  # ENG-90 D-004: count vacates where operator action is required to advance.
  # Excludes orchestrator-recallable vacates (build-wait — ENG-85;
  # review-PR-pending — D-002; skip-until-code-changes evidence-unchanged —
  # D-005), which are not halts. Default-false hatch: items missing the
  # flag default to excluded (strictly safer than over-counting). The
  # `AC-ADV-MISSING-FLAG` adversarial test pins this default.
  local count
  count="$(jq '[.[] | select(.slot == "vacate" and (.operator_action_required // false) == true)] | length' <<<"$classified_json")"

  if ! (( count > threshold )); then
    return 0
  fi

  # Level-triggered: append metric every tick above threshold.
  bash "$SCRIPT_DIR/metrics.sh" halt-sprawl "" "" alert 0 \
    "count=$count threshold=$threshold" || true

  # Edge-triggered: Slack at most once per 24h.
  local debounce_file="$PROJECT_STATE_DIR/.halt-sprawl-last-alerted"
  local now_epoch last_epoch="0"
  now_epoch="$(date -u +%s)"
  if [[ -f "$debounce_file" ]]; then
    local stamp
    stamp="$(cat "$debounce_file" 2>/dev/null || printf '')"
    # Accept ISO-8601 UTC (primary) or empty (treat as absent).
    # Any unparseable content → last_epoch stays 0 → Slack fires.
    if [[ -n "$stamp" ]]; then
      last_epoch="$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$stamp" +%s 2>/dev/null \
                    || date -u -d "$stamp" +%s 2>/dev/null \
                    || printf '0')"
    fi
  fi

  if (( now_epoch - last_epoch > 86400 )); then
    local top3
    top3="$(jq -rc '[.[] | select(.slot == "vacate" and (.operator_action_required // false) == true) | .identifier] | .[:3] | join(", ")' \
             <<<"$classified_json")"
    local suffix=""
    if (( count > 3 )); then
      suffix=", …"
    fi
    local msg="Halt sprawl: $count halted ($top3$suffix) exceed threshold $threshold"
    log "halt-sprawl: firing slack (count=$count threshold=$threshold)"
    bash "$SCRIPT_DIR/slack.sh" warn "$msg" || true

    date -u +%Y-%m-%dT%H:%M:%SZ > "$debounce_file"
  else
    log "halt-sprawl: slack suppressed by debounce ($((now_epoch - last_epoch))s < 86400s)"
  fi

  return 0
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
  paused="$(is_orchestrator_paused)"
  [[ "$paused" == "true" ]] && idle "orchestrator-paused"

  local max_concurrent
  max_concurrent="$(config_get '.orchestrator.max_concurrent_features')"
  # Defensive default: missing or null key would otherwise trip set -u
  # at the (( held_count >= max_concurrent )) arithmetic below.
  [[ "$max_concurrent" == "null" || -z "$max_concurrent" ]] && max_concurrent=2

  # Pass 1: gather all non-Done issues bearing any non-released stage:* label.
  local gathered
  gathered="$(_poll_gather_stage_labeled_issues)"

  # Pass 2: classify each → {slot, advanceable, priority_sort_rank, ...}.
  local classified
  classified="$(_poll_classify_all "$gathered")"

  # Pass 2b: halt-sprawl observability (ENG-21). Reads classified only;
  # never fails the tick.
  _poll_emit_halt_sprawl_alert "$classified"

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
  if (( held_count < max_concurrent )); then
    local inbox_state
    inbox_state="$(config_get '.linear.native_states.inbox')"
    local inbox_pick
    inbox_pick="$(bash "$SCRIPT_DIR/linear.sh" list-issues-in-state "$inbox_state" \
      | jq -r '
        [.data.issues.nodes[]
         | select([.labels.nodes[].name] | any(startswith("stage:")) | not)
         | select([.labels.nodes[].name] | index("pipeline:paused") | not)
         | select([.labels.nodes[].name] | index("pipeline:abandoned") | not)
         | select([.labels.nodes[].name] | index("pipeline:skip-until-human-acts") | not)
         | select([.labels.nodes[].name] | index("pipeline:skip-until-code-changes") | not)
         | {identifier: .identifier,
            priority_sort_rank: (if (.priority // 0) == 0 then 0 else (5 - .priority) end)}]
        | sort_by(-.priority_sort_rank)
        | .[0].identifier // ""')"
    if [[ -n "$inbox_pick" ]]; then
      jq -nc \
        --arg issue_id "$inbox_pick" \
        --arg stage "brainstorming" \
        --arg reason "inbox pickup" \
        '{issue_id:$issue_id, stage:$stage, entry_action:"apply-stage-label", reason:$reason}'
      exit 0
    fi
  fi

  # Pass 6 (ENG-85): wait re-pickup as last resort. Only fires when no
  # held was dispatched (Pass 4), no inbox issue picked (Pass 5), AND
  # there is slot capacity. Sort: priority desc, then wait_progress_ts asc
  # (FIFO fairness — older waits go first).
  if (( held_count < max_concurrent )); then
    local wait_pick
    wait_pick="$(jq -c '
      [.[] | select(.slot == "vacate" and (.wait_recallable // false) == true)]
      | sort_by([-(.priority_sort_rank), .wait_progress_ts])
      | .[0] // empty' <<<"$classified")"
    if [[ -n "$wait_pick" && "$wait_pick" != "null" ]]; then
      local _wp_ident _wp_stage_label _wp_arg
      _wp_ident="$(jq -r '.identifier'  <<<"$wait_pick")"
      _wp_stage_label="$(jq -r '.stage_label' <<<"$wait_pick")"
      _wp_arg="$(stage_arg_for_label "$_wp_stage_label")"
      jq -nc \
        --arg issue_id "$_wp_ident" \
        --arg stage "$_wp_arg" \
        --arg reason "wait re-pickup at $_wp_stage_label (no other ready work)" \
        '{issue_id:$issue_id, stage:$stage, entry_action:"run", reason:$reason}'
      exit 0
    fi
  fi

  # Reached here with no work to dispatch.
  if (( held_count >= max_concurrent )); then
    idle "max-concurrent-reached (held=$held_count, limit=$max_concurrent)"
  fi
  idle "no-work"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
