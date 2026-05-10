#!/usr/bin/env bash
# Shared classifier called from every failure exit site in run-stage.sh.
# Encapsulates: auto-escalation for retry-immediately, state-file write,
# Linear label apply, halt-comment upsert, metrics event, Slack warn.
#
# Source-able (no main). Callers:
#   source "$SCRIPT_DIR/classify-failure.sh"
#   classify_failure <issue> <stage> <base_policy> <reason> <exit_code> [<subcode>]

set -euo pipefail
_CFS_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$_CFS_SCRIPT_DIR/common.sh"

# Resolve the branch name for an issue. Thin wrapper around branch-name.sh.
# Returns empty string if the issue has no branch yet (pre-implement stages).
_cf_branch_for() {
  local issue="$1"
  bash "$_CFS_SCRIPT_DIR/branch-name.sh" "$issue" 2>/dev/null || printf ''
}

# Fetch origin/<branch> HEAD SHA. Empty on failure (network, missing branch).
_cf_branch_head_sha() {
  local branch="$1"
  [[ -z "$branch" ]] && { printf ''; return 0; }
  git -C "$TARGET_REPO" ls-remote origin "$branch" 2>/dev/null \
    | awk '{print $1}' | head -1 || true
}

# Atomic write: tmp + rename.
_cf_write_state() {
  local path="$1" content="$2"
  local tmp="${path}.tmp.$$"
  mkdir -p "$(dirname "$path")"
  printf '%s' "$content" > "$tmp"
  mv -f "$tmp" "$path"
}

classify_failure() {
  # ENG-41 T3: set classify lane for all Linear writes inside this function.
  # Use local+export so it scopes to this function's bash subprocesses without
  # permanently polluting the caller's environment after the function returns.
  local PIPELINE_WRITER=classify
  export PIPELINE_WRITER

  local issue="$1" stage="$2" base_policy="$3" reason="$4" exit_code="$5" subcode="${6:-}"
  local state_file; state_file="$(issue_dir "$issue")/issue-state.json"

  local branch current_hash current_sha
  branch="$(_cf_branch_for "$issue")"
  current_hash="$(compute_pipeline_content_hash)"
  current_sha="$(_cf_branch_head_sha "$branch")"

  # Load prior state (if any). prior_json carries the full document so
  # the merge-write below preserves allocator-set fields
  # (current_dispatch_id, current_dispatch_seq, current_stage) and any
  # other operator-visible state. Plan §A-007 mandates this idiom; pre-
  # ENG-87 review C2 fix, the body construction stomped allocator fields
  # by writing a fresh object — breaking dispatch_id monotonicity
  # (next allocator read prior_seq=0 → re-emitted d0001).
  # ENG-87 review-iter-2 m6: hoist the four scalar reads above the
  # conditional. jq's `// "default"` makes them safe on corrupt /
  # empty / missing files (returns ""/"0"). Only `prior_json` (consumed
  # by --argjson prior in the merge below) MUST be `{}` on the
  # corrupt-JSON branch — --argjson would die on invalid input.
  local prior_policy prior_hash prior_sha prior_count prior_json
  prior_policy="$(jq -r '.policy // ""'                       "$state_file" 2>/dev/null || true)"
  prior_hash="$(jq -r '.evidence.pipeline_content_hash // ""' "$state_file" 2>/dev/null || true)"
  prior_sha="$(jq -r '.evidence.branch_head_sha // ""'        "$state_file" 2>/dev/null || true)"
  prior_count="$(jq -r '.retry_count // 0'                    "$state_file" 2>/dev/null || printf '0')"
  prior_json="{}"
  if [[ -s "$state_file" ]] && jq -e . "$state_file" >/dev/null 2>&1; then
    prior_json="$(cat "$state_file")"
  fi

  # Auto-escalation: retry-immediately with matching evidence → increment, escalate at >=2.
  local effective_policy="$base_policy" retry_count=0 effective_reason="$reason"
  if [[ "$base_policy" == "retry-immediately" ]] && [[ "$prior_policy" == "retry-immediately" ]]; then
    if [[ "$prior_hash" == "$current_hash" ]] && [[ "$prior_sha" == "$current_sha" ]]; then
      retry_count=$((prior_count + 1))
      if (( retry_count >= 2 )); then
        effective_policy="skip-until-code-changes"
        effective_reason="escalated after $retry_count same-evidence retries of: $reason"
      fi
    fi
  fi

  local recorded_at; recorded_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # Build JSON atomically. ENG-87 review C2: merge with prior_json so
  # allocator-set fields (current_dispatch_id, current_dispatch_seq,
  # current_stage) and other operator-visible state survive the write.
  # Mirrors common.sh::_allocate_dispatch_id_locked's merge idiom.
  local body
  body="$(jq -cn \
    --argjson prior "$prior_json" \
    --arg issue "$issue" \
    --arg stage "$stage" \
    --arg policy "$effective_policy" \
    --arg reason "$effective_reason" \
    --argjson exit_code "${exit_code:-0}" \
    --arg subcode "${subcode:-}" \
    --arg recorded_at "$recorded_at" \
    --argjson retry_count "$retry_count" \
    --arg pipeline_content_hash "$current_hash" \
    --arg branch_head_sha "$current_sha" \
    --arg branch "$branch" '
    $prior + {
      issue: $issue, stage: $stage, policy: $policy, reason: $reason,
      exit_code: $exit_code, exit_subcode: (if $subcode == "" then null else ($subcode|tonumber) end),
      recorded_at: $recorded_at, retry_count: $retry_count, branch: $branch,
      evidence: { pipeline_content_hash: $pipeline_content_hash, branch_head_sha: $branch_head_sha }
    }')"

  _cf_write_state "$state_file" "$body"
  log "classify-failure: wrote $state_file (policy=$effective_policy retry_count=$retry_count)"

  # ENG-87 review M2: surface effective_policy to run-stage's
  # dispatch_history end-row trap. No-op when the caller is not
  # run-stage.sh::main (the global is unset / empty); set -u-safe via
  # the `${var-}` form. Allocator-style coupling — same pattern as
  # PIPELINE_DISPATCH_ID export from common.sh::_allocate_dispatch_id_locked.
  #
  # ENG-87 review-iter-7 M3: cross-file mutation of run-stage.sh's
  # verdict_emitted global is gone — the writer in
  # _append_dispatch_end_row reads find_fresh_verdict at trap-fire time,
  # so the halt comment this function just posted (or is about to
  # post via add-or-update-comment below) is picked up automatically.
  # _END_ROW_POLICY stays here because it reflects this function's
  # own decision (skip-until-* / retry-immediately), which is local
  # information not derivable from Linear.
  if [[ -n "${_END_ROW_HIST_FILE-}" ]]; then
    _END_ROW_POLICY="$effective_policy"
  fi

  # Apply matching Linear label (skip policies only).
  case "$effective_policy" in
    skip-until-code-changes)
      bash "$_CFS_SCRIPT_DIR/linear.sh" remove-label "$issue" "pipeline:skip-until-human-acts" 2>/dev/null || true
      bash "$_CFS_SCRIPT_DIR/linear.sh" add-label    "$issue" "pipeline:skip-until-code-changes" || true
      ;;
    skip-until-human-acts)
      bash "$_CFS_SCRIPT_DIR/linear.sh" remove-label "$issue" "pipeline:skip-until-code-changes" 2>/dev/null || true
      bash "$_CFS_SCRIPT_DIR/linear.sh" add-label    "$issue" "pipeline:skip-until-human-acts" || true
      ;;
  esac

  # ENG-78: only the halt-policy branches apply pipeline:halted.
  # retry-immediately is the explicit non-halt failure path — poll.sh
  # re-dispatches automatically on the next tick. The auto-escalation
  # guard at lines 67-77 will flip effective_policy to
  # skip-until-code-changes after retry_count >= 2 same-evidence
  # retries; that branch DOES apply the halt label below.
  case "$effective_policy" in
    skip-until-code-changes|skip-until-human-acts)
      bash "$_CFS_SCRIPT_DIR/linear.sh" add-label "$issue" "pipeline:halted" || true
      ;;
    retry-immediately)
      : # no halt; orchestrator re-dispatches next tick (ENG-78)
      ;;
  esac

  # ENG-78: split comment shape on effective_policy.
  # Halt-policy arms post the same halt-shape verdict marker as today
  # (preserves verdict-handler / find_fresh_verdict / status.sh behavior).
  # retry-immediately posts a meta-shape transient-retry comment under a
  # distinct sig so an auto-escalation tick later (effective_policy →
  # skip-until-code-changes) creates a NEW halt comment with its OWN
  # createdAt rather than overwriting in place. find_fresh_verdict
  # excludes meta-shape (event != "verdict" filter at
  # verdict-handler.sh:111), so the retry-pending comment never registers
  # as a halt verdict and never trips the halt-sprawl threshold.
  case "$effective_policy" in
    skip-until-code-changes|skip-until-human-acts)
      local sig="halt/$stage/$issue"
      local marker_reason
      case "$effective_policy" in
        skip-until-human-acts) marker_reason="agent-blocked" ;;
        *)                     marker_reason="agent-failure" ;;
      esac
      local comment_body
      comment_body="$(printf '<!-- pipeline: verdict result=halt reason=%s -->\n\nPipeline: `%s` stage halted — %s\n\n**Policy:** %s\n**Recorded at:** %s\n**Branch:** %s\n**Retry count:** %d\n\n**Resume:** ' \
        "$marker_reason" "$stage" "$effective_reason" "$effective_policy" "$recorded_at" "${branch:-none}" "$retry_count")"
      case "$effective_policy" in
        skip-until-code-changes)
          comment_body+="$(printf 'auto-resumes when `.pipeline/{bin,config.json,AGENT_PROMPTS.md}` content hash OR `origin/%s` HEAD changes, OR when `pipeline:skip-until-code-changes` label is removed.' "${branch:-<branch>}")"
          ;;
        skip-until-human-acts)
          comment_body+="remove the \`pipeline:skip-until-human-acts\` label when the underlying issue is resolved."
          ;;
      esac
      comment_body+="$(printf '\n\n**Evidence:**\n- pipeline_content_hash: `%s`\n- branch_head_sha: `%s`\n' "$current_hash" "${current_sha:-<none>}")"
      bash "$_CFS_SCRIPT_DIR/linear.sh" add-or-update-comment "$sig" "$issue" "$comment_body" || true
      ;;
    retry-immediately)
      local sig="retry-pending/$stage/$issue"
      local remaining=$((2 - retry_count))
      local comment_body
      comment_body="$(printf '<!-- meta: metric name=transient-retry stage=%s attempt=%d -->\n\nPipeline: transient `%s`-stage failure — %s\n\n**Status:** retry-pending (attempt %d of 2 before auto-escalation to `skip-until-code-changes`).\n**Recorded at:** %s\n**Branch:** %s\n\nThe pipeline will re-dispatch this stage on the next tick. If the same evidence reproduces this failure %d more time(s), the orchestrator will halt the issue with `pipeline:skip-until-code-changes` for operator visibility.\n\n**Evidence:**\n- pipeline_content_hash: `%s`\n- branch_head_sha: `%s`\n' \
        "$stage" "$retry_count" "$stage" "$effective_reason" "$retry_count" "$recorded_at" "${branch:-none}" "$remaining" "$current_hash" "${current_sha:-<none>}")"
      bash "$_CFS_SCRIPT_DIR/linear.sh" add-or-update-comment "$sig" "$issue" "$comment_body" || true
      ;;
  esac

  # Slack.
  bash "$_CFS_SCRIPT_DIR/slack.sh" warn "Stage $stage on $issue → $effective_policy (exit=$exit_code, retry=$retry_count)" || true

  # Metric event (ENG-10): outcome is the typed failure-mode name via the
  # common.sh taxonomy helper; policy rides in notes alongside exit/subcode/
  # retry/branch. Consumers (status.sh, retrospective §1) filter on outcome.
  local _typed_outcome
  _typed_outcome="$(failure_outcome_for_exit "$exit_code" "${subcode:-}")"
  bash "$_CFS_SCRIPT_DIR/metrics.sh" stage-end "$issue" "$stage" "$_typed_outcome" 0 \
    "exit=$exit_code${subcode:+ subcode=$subcode} policy=$effective_policy retry_count=$retry_count branch=${branch:-none}" || true
}
export -f classify_failure
