#!/usr/bin/env bash
# Run a single pipeline stage against a Linear issue.
# Usage: run-stage.sh <issue_id> <stage>
# Exit codes: 0=success, 10=guards-tripped, 11=paused, 12=reconcile-human, 20=dispatch-failed,
#             21=scope-violation, 22=pr-opened-too-early, 24=linear-post-failed.
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

next_stage() {
  # Canonical happy-path advancement.
  case "$1" in
    brainstorm)    printf 'planning' ;;
    plan)          printf 'implementing' ;;
    implement)     printf 'ui' ;;
    ui)            printf 'reviewing' ;;
    review)        printf 'qa' ;;           # approve-path; reject handled separately
    qa)            printf 'building' ;;     # pass-path; fail handled separately
    build)         printf 'released' ;;
    release)       printf '' ;;             # terminal
    retrospective) printf '' ;;             # not part of per-issue flow
    *)             die "unknown stage: $1" ;;
  esac
}

# ─── Per-stage success-path completion comment (ENG-11) ──────────────────────
# Read the agent-authored summary file, wrap with header + PR tail, and
# upsert under sig completion/<stage>/<issue>. On missing/empty/symlink,
# post a mechanical fallback with <!-- pipeline-metric: summary_missing -->.
# Returns nonzero if Linear post itself fails after one retry.
#
# Caller contract: this helper is only invoked for stages in the set
# {brainstorm, plan, implement, ui, review, qa, build} — every one of which
# has a non-empty next_stage. We therefore do NOT branch on "terminal stage"
# here; release/retrospective never reach this path (see run-stage.sh success
# block's case statement in Task 2).
post_completion_comment() {
  local issue="$1" stage="$2"
  local next_label; next_label="$(next_stage "$stage")"
  local summary_path; summary_path="$(issue_dir "$issue")/stage-summary-${stage}.md"
  local sig="completion/${stage}/${issue}"

  local header="**${stage} complete** → advancing to stage:${next_label}"

  # PR tail only on post-UI stages where a PR is guaranteed to exist.
  local pr_tail=""
  case "$stage" in
    ui|review|qa|build)
      local branch pr_url
      branch="$(bash "$SCRIPT_DIR/branch-name.sh" "$issue" 2>/dev/null || printf '')"
      if [[ -n "$branch" ]] && command -v gh >/dev/null 2>&1; then
        pr_url="$(gh pr list --head "$branch" --state open  --json url --jq '.[0].url // ""' 2>/dev/null || printf '')"
        [[ -z "$pr_url" ]] && pr_url="$(gh pr list --head "$branch" --state all --json url --jq '.[0].url // ""' 2>/dev/null || printf '')"
        [[ -n "$pr_url" ]] && pr_tail=$'\n\n— PR: '"$pr_url"
      fi
      ;;
  esac

  # Read + safety-filter the summary body, or take fallback.
  # Order matters: strip sig-marker LINES *before* byte-truncating so a mid-line
  # byte cut inside a `<!-- pipeline-sig: … -->` line cannot leave a partial
  # (and therefore unmatched-by-sed) marker in the posted body.
  local body fallback_marker=""
  if [[ -L "$summary_path" ]]; then
    fallback_marker="summary_symlink_refused"
  elif [[ ! -s "$summary_path" ]]; then
    fallback_marker="summary_missing"
  else
    local fsize; fsize="$(wc -c < "$summary_path" | tr -d ' ')"
    body="$(sed -E '/<!-- pipeline-sig: .* -->/d' "$summary_path" | head -c 32768)"
    if (( fsize > 32768 )); then
      body+=$'\n\n_[truncated at 32 KiB]_'
      body+=$'\n<!-- pipeline-metric: summary_truncated -->'
    fi
  fi

  local comment_body
  if [[ -n "$fallback_marker" ]]; then
    # Fallback MUST include the PR tail when it would normally apply — a reviewer
    # landing on a mechanical comment still benefits from the PR link (D-004 open
    # question resolved: include tail).
    comment_body="$(printf '%s\n\n_Agent did not write a stage summary; posting mechanical completion._%s\n<!-- pipeline-metric: %s -->' \
      "$header" "$pr_tail" "$fallback_marker")"
  else
    comment_body="$(printf '%s\n\n%s%s' "$header" "$body" "$pr_tail")"
  fi

  # Retry once on failure. add-or-update-comment appends the canonical sig itself.
  if bash "$SCRIPT_DIR/linear.sh" add-or-update-comment "$sig" "$issue" "$comment_body"; then
    return 0
  fi
  sleep 5
  bash "$SCRIPT_DIR/linear.sh" add-or-update-comment "$sig" "$issue" "$comment_body"
}

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

advance_label() {
  local ident="$1" stage="$2" nxt="$3"
  local prefix
  prefix="$(config_get '.linear.stage_label_prefix')"
  bash "$SCRIPT_DIR/linear.sh" swap-stage "$ident" "$nxt"

  # Per ENG-13 D-014: Linear native state transitions.
  # - stage:reviewing applied → In Review (PR just opened in UI stage).
  # - stage:released does NOT transition to Done here; Done is set by
  #   cleanup-worktrees.sh when the PR actually merges.
  if [[ "$nxt" == "reviewing" ]]; then
    local in_review_state
    in_review_state="$(config_get '.linear.native_states.in_review')"
    bash "$SCRIPT_DIR/linear.sh" transition-state "$ident" "$in_review_state"
  fi
}

main() {
  local ident="${1:-}" stage="${2:-}"
  [[ -n "$ident" && -n "$stage" ]] || die "usage: run-stage.sh <issue_id> <stage>"

  local t0 t1 duration
  t0="$(date +%s)"

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

  # Scope-approval replay: if this is implement/ui and the user just cleared
  # `pipeline:scope-approval-needed` (state file exists, label absent), skip the
  # agent dispatch and fall through to the post-stage guards. The branch is
  # already green from the prior dispatch; re-running the agent would just burn
  # tokens. The post-stage scope-check will observe (state file + no label) and
  # treat the notable tier as approved.
  local skip_dispatch=0
  if [[ "$stage" == "implement" || "$stage" == "ui" ]]; then
    local _approval_state="$(issue_dir "$ident")/scope-approval"
    if [[ -f "$_approval_state" ]] \
       && ! bash "$SCRIPT_DIR/linear.sh" has-label "$ident" "pipeline:scope-approval-needed"; then
      log "scope-approval: label cleared; skipping agent dispatch for $stage replay"
      skip_dispatch=1
    fi
  fi

  # Guarantee the per-issue state dir exists before dispatch so an agent's first
  # Write of stage-summary-<stage>.md cannot fail on missing parents.
  mkdir -p "$(issue_dir "$ident")"

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

  # Post-review: premise-failure loopback to brainstorming.
  # The review agent applies `pipeline:premise-failure` when it concludes the brainstorm
  # itself was wrong. The orchestrator handles the state transition so the review agent
  # never touches stage labels directly (preamble contract).
  if [[ "$stage" == "review" ]]; then
    if bash "$SCRIPT_DIR/linear.sh" has-label "$ident" "pipeline:premise-failure"; then
      log "review: premise-failure flagged — looping back to stage:brainstorming"
      bash "$SCRIPT_DIR/linear.sh" swap-stage "$ident" "brainstorming"
      bash "$SCRIPT_DIR/linear.sh" add-label    "$ident" "pipeline:supersede"
      bash "$SCRIPT_DIR/linear.sh" remove-label "$ident" "pipeline:premise-failure"
      bash "$SCRIPT_DIR/linear.sh" add-comment  "$ident" \
        "Pipeline: premise-failure loopback → brainstorming. \`pipeline:supersede\` applied so the next brainstorm regenerates (rather than linking the existing doc)."
      t1="$(date +%s)"; duration=$(( (t1 - t0) * 1000 ))
      bash "$SCRIPT_DIR/metrics.sh" stage-end "$ident" "$stage" "premise-failure" "$duration" "loopback=brainstorming"
      exit 0
    fi
  fi

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
        # NOTABLE tier. If the user has already acknowledged (state file exists,
        # label absent), treat as approved and clear state. Otherwise, soft-pause.
        if [[ -f "$approval_state_file" ]] \
           && ! bash "$SCRIPT_DIR/linear.sh" has-label "$ident" "pipeline:scope-approval-needed"; then
          log "scope-check: notable approved by label removal; clearing state and proceeding"
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
          local reason
          reason="scope-approval pending on $branch (notable files listed in halt comment)"
          classify_failure "$ident" "$stage" "skip-until-human-acts" "$reason" 0
          # Update the dedicated scope-approval sig comment with the file list.
          bash "$SCRIPT_DIR/linear.sh" add-or-update-comment "scope-approval/$stage/$ident" "$ident" \
            "Pipeline: \`$stage\` stage is awaiting scope approval on \`$branch\`. The following files were modified outside the plan's File Structure but live in directories adjacent to declared scope:

$fs_patch

To approve and resume, add these entries to the plan's File Structure section and **remove the \`pipeline:scope-approval-needed\` label**. To reject, revert the out-of-scope edits and re-run. (Benign escapes — pipeline telemetry, Cargo.lock, docs/knowledge, tests under an in-scope crate — are auto-allowed and not listed here.)"
          # Also keep the existing scope-approval-needed label for backward compat.
          if ! bash "$SCRIPT_DIR/linear.sh" has-label "$ident" "pipeline:scope-approval-needed"; then
            bash "$SCRIPT_DIR/linear.sh" add-label "$ident" "pipeline:scope-approval-needed"
          fi
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

  # Post-stage completion comment (ENG-11). Orchestrator-owned narrative post.
  # Runs on both fresh dispatches and scope-approval replays (narrates the advance).
  case "$stage" in
    brainstorm|plan|implement|ui|review|qa|build)
      if ! post_completion_comment "$ident" "$stage"; then
        classify_failure "$ident" "$stage" "retry-immediately" \
          "linear post failed for completion/$stage/$ident after one retry" 24
        exit 24
      fi
      ;;
  esac

  # Advance label.
  local nxt
  nxt="$(next_stage "$stage")"
  if [[ -n "$nxt" ]]; then
    advance_label "$ident" "$stage" "$nxt"
  fi

  t1="$(date +%s)"; duration=$(( (t1 - t0) * 1000 ))
  bash "$SCRIPT_DIR/metrics.sh" stage-end "$ident" "$stage" "success" "$duration" "next=$nxt"
  log "stage $stage complete for $ident (next: ${nxt:-terminal})"

  # Success path: clear any prior failure state + skip labels so this issue
  # re-enters the normal scheduling pool without manual intervention.
  rm -f "$(issue_dir "$ident")/issue-state.json" 2>/dev/null || true
  bash "$SCRIPT_DIR/linear.sh" remove-label "$ident" "pipeline:skip-until-code-changes" 2>/dev/null || true
  bash "$SCRIPT_DIR/linear.sh" remove-label "$ident" "pipeline:skip-until-human-acts"   2>/dev/null || true
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
