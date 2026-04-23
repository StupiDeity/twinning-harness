#!/usr/bin/env bash
# Run a single pipeline stage against a Linear issue.
# Usage: run-stage.sh <issue_id> <stage>
# Exit codes: 0=success, 10=guards-tripped, 11=paused, 12=reconcile-human, 20=dispatch-failed,
#             21=scope-violation, 22=pr-opened-too-early, 23=linear-comment-missing.
#
# Caller contract: run-stage.sh expects the issue to already carry stage:<X> for the
# stage being run (the poller sets this on entry). On success, run-stage.sh advances
# the label to the NEXT stage in the pipeline. On reject loops, guards+metrics handle bookkeeping.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"
# shellcheck source=classify-failure.sh
source "$SCRIPT_DIR/classify-failure.sh"
# shellcheck source=verdict-handler.sh
source "$SCRIPT_DIR/verdict-handler.sh"

verify_preconditions() {
  local ident="$1" stage="$2"

  # Global pause?
  local paused
  paused="$(config_get '.orchestrator.paused')"
  if [[ "$paused" == "true" ]]; then
    log "orchestrator globally paused"
    return 11
  fi

  # Per-issue pause?
  if bash "$SCRIPT_DIR/linear.sh" has-label "$ident" "pipeline:paused"; then
    log "issue paused via pipeline:paused label"
    return 11
  fi

  # Expected stage label present?
  local prefix expected
  prefix="$(config_get '.linear.stage_label_prefix')"
  expected="${prefix}${stage//brainstorm/brainstorming}"  # handle abbreviation
  expected="${expected//implement/implementing}"
  expected="${expected//review/reviewing}"
  expected="${expected//plan/planning}"
  expected="${expected//build/building}"
  expected="${expected//release/released}"
  expected="${expected//qa/qa}"
  expected="${expected//ui/ui}"
  # Simpler: just derive from the canonical ordering.
  expected="$(bash -c "
    case '$stage' in
      brainstorm) echo '${prefix}brainstorming' ;;
      plan)       echo '${prefix}planning' ;;
      implement)  echo '${prefix}implementing' ;;
      ui)         echo '${prefix}ui' ;;
      review)     echo '${prefix}reviewing' ;;
      qa)         echo '${prefix}qa' ;;
      build)      echo '${prefix}building' ;;
      release)    echo '${prefix}released' ;;
    esac
  ")"

  if [[ -n "$expected" ]] && ! bash "$SCRIPT_DIR/linear.sh" has-label "$ident" "$expected"; then
    die "precondition failed: $ident does not carry $expected (must be applied before run-stage)"
  fi

  return 0
}

main() {
  local ident="${1:-}" stage="${2:-}"
  [[ -n "$ident" && -n "$stage" ]] || die "usage: run-stage.sh <issue_id> <stage>"

  local t0 t0_iso t1 duration
  t0="$(date +%s)"
  t0_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # Preconditions.
  verify_preconditions "$ident" "$stage" || {
    local rc=$?
    bash "$SCRIPT_DIR/metrics.sh" stage-start "$ident" "$stage" "paused" 0 \
      || true
    exit "$rc"
  }

  # Guards (threshold-based human gates).
  if ! bash "$SCRIPT_DIR/guards.sh" check "$ident" 2>/dev/null; then
    local tripped
    tripped="$(bash "$SCRIPT_DIR/guards.sh" check "$ident" 2>&1 || true)"
    classify_failure "$ident" "$stage" "skip-until-human-acts" \
      "guards tripped: $tripped" 10
    exit 10
  fi

  # Reconcile is now performed in run-local.sh before this script is called,
  # so that link:/human decisions don't create empty worktrees. See ENG-13 D-009.

  # Scope-approval replay: if this is implement/ui and the user has posted
  # a `<!-- pipeline-decision: scope-approved -->` comment newer than the
  # most recent `<!-- pipeline-halt: scope-deviation -->` marker, skip the
  # agent dispatch and fall through to the post-stage guards. The branch
  # is already green from the prior dispatch; re-running the agent would
  # just burn tokens. The post-stage scope-check will observe the same
  # decision marker and treat the notable tier as approved.
  local skip_dispatch=0
  if [[ "$stage" == "implement" || "$stage" == "ui" ]]; then
    local _approval_state="$(issue_dir "$ident")/scope-approval"
    if [[ -f "$_approval_state" ]] \
       && bash "$SCRIPT_DIR/scope-check.sh" has-scope-approval "$ident" 2>/dev/null; then
      log "scope-approval: decision marker posted; skipping agent dispatch for $stage replay"
      skip_dispatch=1
    fi
  fi

  # Render the prompt.
  local prompt_file log_file
  if (( ! skip_dispatch )); then
    prompt_file="$(mktemp -t pipeline-prompt-XXXXXX)"
    log_file="$REPO_ROOT/logs/pipeline/${ident}-${stage}-$(date -u +%Y%m%dT%H%M%SZ).log"
    mkdir -p "$(dirname "$log_file")"
    bash "$SCRIPT_DIR/render-prompt.sh" "$stage" "$ident" > "$prompt_file"
    log "rendered prompt: $prompt_file ($(wc -l < "$prompt_file") lines)"

    bash "$SCRIPT_DIR/metrics.sh" stage-start "$ident" "$stage" "dispatching" 0

    # Dispatch.
    if ! bash "$SCRIPT_DIR/dispatch.sh" "$stage" "$prompt_file" "$log_file"; then
      classify_failure "$ident" "$stage" "retry-immediately" \
        "dispatch failed (see $log_file)" 20
      rm -f "$prompt_file"
      exit 20
    fi
    rm -f "$prompt_file"
  else
    bash "$SCRIPT_DIR/metrics.sh" stage-start "$ident" "$stage" "scope-approval-replay" 0
  fi

  # Post-review premise-failure is now expressed as a pipeline-rejection
  # marker with target brainstorming; the Verdict Handler loopback table
  # (reviewing|brainstorming|pipeline:supersede) handles it below.

  # Post-implement / post-ui guards:
  #   (a) scope-check: no files outside plan File Structure were touched.
  #   (b) no-pr-check: implement stage must NOT have opened a PR (UI stage opens the PR).
  if [[ "$stage" == "implement" || "$stage" == "ui" ]]; then
    local branch
    branch="$(bash "$SCRIPT_DIR/branch-name.sh" "$ident")"
    [[ -n "$branch" ]] || die "could not resolve branch name for $ident"

    local approval_state_file="$(issue_dir "$ident")/scope-approval"
    local scope_out scope_rc=0
    scope_out="$(bash "$SCRIPT_DIR/scope-check.sh" "$ident" "$branch" 2>&1)" || scope_rc=$?

    case "$scope_rc" in
      0)
        # Clean pass; clear any stale approval-state file.
        rm -f "$approval_state_file"
        ;;
      1)
        # NOTABLE tier. If the user has already acknowledged (state file
        # exists, scope-approved decision marker newer than the most
        # recent scope-deviation halt), treat as approved and clear
        # state. Otherwise, emit a pipeline-halt: scope-deviation marker
        # and the sentinel label; the Verdict Handler leaves the halt
        # intact until halt.sh resolve posts a decision.
        if [[ -f "$approval_state_file" ]] \
           && bash "$SCRIPT_DIR/scope-check.sh" has-scope-approval "$ident" 2>/dev/null; then
          log "scope-check: notable approved by pipeline-decision marker; clearing state and proceeding"
          rm -f "$approval_state_file"
        else
          mkdir -p "$(dirname "$approval_state_file")"
          local notable_files
          notable_files="$(grep -E '^notable	' <<<"$scope_out" | awk -F'\t' '{print $2}' | sort -u)"
          printf 'issue=%s\nbranch=%s\napplied_at=%s\n' \
            "$ident" "$branch" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$approval_state_file"
          printf '%s\n' "$notable_files" >> "$approval_state_file"

          local fs_patch
          fs_patch="$(printf -- '- `%s`\n' $notable_files)"
          local halt_body
          halt_body="$(printf '<!-- pipeline-halt: scope-deviation -->\n\nPipeline: `%s` stage touched files outside the plan File Structure on branch `%s`. Notable (adjacent-to-scope) files:\n\n%s\nTo approve and resume:\n\n    bash .pipeline/bin/halt.sh resolve %s --decision scope-approved\n\nTo reject, revert the out-of-scope edits and remove `pipeline:halted`. (Benign escapes — pipeline telemetry, Cargo.lock, docs/knowledge, tests under an in-scope crate — are auto-allowed and not listed here.)' \
            "$stage" "$branch" "$fs_patch" "$ident")"
          bash "$SCRIPT_DIR/linear.sh" add-comment "$ident" "$halt_body" || true
          bash "$SCRIPT_DIR/linear.sh" add-label   "$ident" "pipeline:halted" || true

          t1="$(date +%s)"; duration=$(( (t1 - t0) * 1000 ))
          bash "$SCRIPT_DIR/metrics.sh" stage-end "$ident" "$stage" "scope-deviation" "$duration" \
            "branch=$branch notable_count=$(wc -l <<<"$notable_files" | tr -d ' ')" || true
          exit 0
        fi
        ;;
      3)
        local severe_files
        severe_files="$(grep -E '^severe	' <<<"$scope_out" | awk -F'\t' '{print $2}' | sort -u)"
        local severe_patch
        severe_patch="$(printf -- '- `%s`\n' $severe_files)"
        classify_failure "$ident" "$stage" "skip-until-human-acts" \
          "SEVERE scope violation on $branch: $(tr '\n' ' ' <<<"$severe_patch")" 21 3
        exit 21
        ;;
      *)
        classify_failure "$ident" "$stage" "skip-until-code-changes" \
          "scope-check rc=$scope_rc (likely plan not found or File Structure unparseable)" \
          21 "$scope_rc"
        exit 21
        ;;
    esac

    # Scan for Gotcha-hit commit trailers and bump the per-issue counter.
    # Non-blocking: telemetry only. Retrospective reads both the aggregate git log
    # AND the per-issue counter.
    bash "$SCRIPT_DIR/scan-gotcha-trailers.sh" "$ident" "$branch" || true

    if [[ "$stage" == "implement" ]]; then
      if command -v gh >/dev/null 2>&1; then
        local pr_count
        pr_count="$(gh pr list --head "$branch" --state open --json number --jq 'length' 2>/dev/null || printf '0')"
        if (( pr_count > 0 )); then
          classify_failure "$ident" "$stage" "skip-until-human-acts" \
            "implement stage opened a PR on $branch — UI stage should own PR creation" 22
          exit 22
        fi
      fi
    fi
  fi

  # Post-stage Linear-comment assertion. The "Completion checklist" in each agent prompt
  # makes the Linear comment the final mandatory step; this check confirms the agent
  # actually ran that step rather than exiting early after self-review. Skip for
  # scope-approval replays (the original dispatch already posted) and for `release`
  # (terminal stage with variable comment patterns). If missing, fail with exit 23 so
  # the retrospective loop catches it instead of the pipeline silently marking success.
  if (( ! skip_dispatch )); then
    case "$stage" in
      brainstorm|plan|implement|ui|review|qa|build)
        if ! bash "$SCRIPT_DIR/linear.sh" has-comment-since "$ident" "$t0_iso"; then
          classify_failure "$ident" "$stage" "retry-immediately" \
            "agent exited without posting a Linear comment (completion checklist violated)" 23
          exit 23
        fi
        ;;
    esac
  fi

  # Post-dispatch halt check: every stage agent must apply pipeline:halted.
  # If it did not, apply it on the agent's behalf and let the Verdict Handler
  # surface a protocol violation on the next tick.
  if ! bash "$SCRIPT_DIR/linear.sh" has-label "$ident" "pipeline:halted"; then
    log "post-dispatch: agent did not apply pipeline:halted; applying on its behalf"
    bash "$SCRIPT_DIR/linear.sh" add-label "$ident" "pipeline:halted" || true
  fi

  # Resolve the current stage from the Linear label (long form) rather than
  # the short-form $stage argument, because the Verdict Handler tables are
  # keyed on the long form (brainstorming, planning, implementing, ...).
  local current_stage_label vh_stage
  current_stage_label="$(bash "$SCRIPT_DIR/linear.sh" stage-of "$ident")"
  vh_stage="${current_stage_label#stage:}"
  local vh_rc=0
  verdict_handler "$ident" "$vh_stage" || vh_rc=$?

  t1="$(date +%s)"; duration=$(( (t1 - t0) * 1000 ))
  case "$vh_rc" in
    0)
      bash "$SCRIPT_DIR/metrics.sh" stage-end "$ident" "$stage" "success" "$duration" "verdict=transitioned"
      log "stage $stage complete for $ident (verdict-handler transitioned)"
      # Success path: clear any prior failure state + skip labels.
      rm -f "$(issue_dir "$ident")/issue-state.json" 2>/dev/null || true
      bash "$SCRIPT_DIR/linear.sh" remove-label "$ident" "pipeline:skip-until-code-changes" 2>/dev/null || true
      bash "$SCRIPT_DIR/linear.sh" remove-label "$ident" "pipeline:skip-until-human-acts"   2>/dev/null || true
      ;;
    1)
      bash "$SCRIPT_DIR/metrics.sh" stage-end "$ident" "$stage" "halt-for-human" "$duration" "verdict=halt"
      log "stage $stage halted on $ident (human intervention required)"
      ;;
    2)
      bash "$SCRIPT_DIR/metrics.sh" stage-end "$ident" "$stage" "protocol-violation" "$duration" "verdict=violation"
      log "stage $stage protocol violation on $ident"
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
