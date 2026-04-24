#!/usr/bin/env bash
# Run a single pipeline stage against a Linear issue.
# Usage: run-stage.sh <issue_id> <stage>
# Exit codes: 0=success, 10=guards-tripped, 11=paused, 12=reconcile-human, 20=dispatch-failed,
#             21=scope-violation, 22=pr-opened-too-early, 24=linear-post-failed,
#             25=agent-contract-missing (agent exited clean but emitted neither the
#                stage-summary file nor a verdict-marker comment).
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

# ─── Fallback-comment enrichment (ENG-7) ──────────────────────────────────────
# When post_completion_comment takes the summary_missing / summary_symlink_refused
# fallback, enumerate whatever the agent did manage to produce in the worktree.
# Silence-on-fallback was the worst part of ENG-7: a complete 571-line brainstorm
# doc sat untracked in the worktree while Linear showed only "Agent did not write
# a stage summary". Prints "" on no artifacts so the fallback body is unchanged.
_stage_artifacts_footer() {
  local issue="$1" stage="$2"
  local wt; wt="$(issue_dir "$issue")/worktree"
  [[ -d "$wt" ]] || { printf ''; return 0; }

  # Stage → doc-dir mapping. Only brainstorm and plan have a single canonical
  # doc surface; post-plan stages span the repo and are best described by
  # branch-delta which the PR link already covers.
  local doc_dir=""
  case "$stage" in
    brainstorm) doc_dir="docs/brainstorms" ;;
    plan)       doc_dir="docs/plans" ;;
    *)          printf ''; return 0 ;;
  esac

  local paths
  paths="$(git -C "$wt" status --porcelain -- "$doc_dir" 2>/dev/null \
    | awk '{print $NF}' | sort -u)"
  [[ -z "$paths" ]] && { printf ''; return 0; }

  local lines=""
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    lines+="$(printf -- '- \`%s\`\n' "$p")"
  done <<<"$paths"

  printf '\n\n**Artifacts detected in worktree (%s):**\n\n%s' "$doc_dir" "$lines"
}

# ─── Per-stage success-path completion comment (ENG-11) ──────────────────────
# Read the agent-authored summary file, wrap with header + PR tail, and
# upsert under sig completion/<stage>/<issue>. On missing/empty/symlink,
# post a mechanical fallback with <!-- pipeline-metric: summary_missing -->.
# Returns nonzero if Linear post itself fails after one retry.
#
# Caller contract: this helper is only invoked for stages in the set
# {brainstorm, plan, implement, ui, review, qa, build}; release and
# retrospective never reach this path (see run-stage.sh success block's
# case statement). The header is narrative-only — the verdict marker in
# the agent's separate append-only comment is what drives the state
# transition, so this comment does not pre-announce the next stage.
post_completion_comment() {
  local issue="$1" stage="$2"
  local summary_path; summary_path="$(issue_dir "$issue")/stage-summary-${stage}.md"
  local sig="completion/${stage}/${issue}"

  local header="**${stage} summary**"

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
    # Also enumerate the worktree artifacts the agent left behind, so the reviewer
    # sees what (if anything) it managed to produce before the silent exit. ENG-7
    # was the motivating case: a 571-line brainstorm doc sat untracked in the
    # worktree while Linear showed only "Agent did not write a stage summary".
    local artifacts_tail
    artifacts_tail="$(_stage_artifacts_footer "$issue" "$stage")"
    comment_body="$(printf '%s\n\n_Agent did not write a stage summary; posting mechanical completion._%s%s\n<!-- pipeline-metric: %s -->' \
      "$header" "$pr_tail" "$artifacts_tail" "$fallback_marker")"
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

# Push the current worktree branch to origin if HEAD is ahead of origin/<branch>.
# Without this, an agent that commits brainstorm/plan docs inside the worktree
# leaves the commit un-pushed: run-local.sh's partition-sweep push only fires
# when there are *uncommitted* dirty paths, so a clean agent commit stays local.
# Result (observed on ENG-6): the completion comment's `github.com/.../blob/<branch>/…`
# link 404s because the branch never reached origin. Push here so the link resolves
# by the time post_completion_comment posts it.
push_branch_if_ahead() {
  local branch ahead upstream_ref
  branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || printf '')"
  [[ -z "$branch" || "$branch" == "HEAD" ]] && return 0
  case "$branch" in main|master) return 0 ;; esac
  git remote get-url origin >/dev/null 2>&1 || return 0

  upstream_ref="refs/remotes/origin/${branch}"
  if git rev-parse --verify --quiet "$upstream_ref" >/dev/null; then
    ahead="$(git rev-list --count "${upstream_ref}..HEAD" 2>/dev/null || printf 0)"
  else
    ahead=1  # branch absent on origin — treat as needing push
  fi
  (( ahead > 0 )) || return 0

  log "pushing $branch to origin ($ahead unpushed commit(s)) so completion-comment links resolve"
  if ! git push -u origin HEAD 2>&1 | sed 's/^/  push: /' >&2; then
    log "git push -u origin $branch failed; completion-comment link may 404 until next tick"
    return 0
  fi
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
    # ENG-10 D-004: emit a matching stage-end so retrospective §1 can pair
    # the events. Helper resolves rc=11 to "paused"; any other rc would
    # return "unknown-exit-<N>" which is the correct drift signal.
    bash "$SCRIPT_DIR/metrics.sh" stage-end "$ident" "$stage" \
      "$(failure_outcome_for_exit "$rc" "")" 0 "exit=$rc" || true
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
          # ENG-18: append-only halt marker (scope-deviation shape) + sentinel
          # label. The Verdict Handler leaves the halt intact until halt.sh
          # resolve posts a pipeline-decision marker.
          local halt_body
          halt_body="$(printf '<!-- pipeline-halt: scope-deviation -->\n\nPipeline: `%s` stage touched files outside the plan File Structure on branch `%s`. Notable (adjacent-to-scope) files:\n\n%s\nTo approve and resume:\n\n    bash .pipeline/bin/halt.sh resolve %s --decision scope-approved\n\nTo reject, revert the out-of-scope edits and remove `pipeline:halted`. (Benign escapes — pipeline telemetry, Cargo.lock, docs/knowledge, tests under an in-scope crate — are auto-allowed and not listed here.)' \
            "$stage" "$branch" "$fs_patch" "$ident")"
          bash "$SCRIPT_DIR/linear.sh" add-comment "$ident" "$halt_body" || true
          bash "$SCRIPT_DIR/linear.sh" add-label   "$ident" "pipeline:halted" || true

          t1="$(date +%s)"; duration=$(( (t1 - t0) * 1000 ))
          # ENG-10: emit typed outcome via the failure taxonomy so
          # retrospective §1's filter picks up the halt event.
          bash "$SCRIPT_DIR/metrics.sh" stage-end "$ident" "$stage" \
            "$(failure_outcome_for_exit 0 1)" "$duration" \
            "branch=$branch notable_count=$(wc -l <<<"$notable_files" | tr -d ' ')" || true
          exit 0
        fi
        ;;
      3)
        local severe_files
        severe_files="$(grep -E '^severe	' <<<"$scope_out" | awk -F'\t' '{print $2}' | sort -u)"
        local severe_patch
        severe_patch="$(printf -- '- `%s`\n' $severe_files)"
        bash "$SCRIPT_DIR/guards.sh" bump "$ident" implement_rejection || true
        classify_failure "$ident" "$stage" "skip-until-human-acts" \
          "SEVERE scope violation on $branch: $(tr '\n' ' ' <<<"$severe_patch")" 21 3
        exit 21
        ;;
      *)
        bash "$SCRIPT_DIR/guards.sh" bump "$ident" implement_rejection || true
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
          bash "$SCRIPT_DIR/guards.sh" bump "$ident" implement_rejection || true
          classify_failure "$ident" "$stage" "skip-until-human-acts" \
            "implement stage opened a PR on $branch — UI stage should own PR creation" 22
          exit 22
        fi
      fi
    fi
  fi

  # Agent-contract validator (ENG-7). On a fresh dispatch (not scope-approval
  # replay), the agent MUST have produced at least one of:
  #   (a) stage-summary-<stage>.md in issue_dir — read by post_completion_comment.
  #   (b) A fresh verdict-marker comment on the Linear issue — read by verdict_handler.
  # Exiting clean without either artifact is an agent protocol failure: the
  # downstream cascade posts summary_missing + halt + protocol-violation/no-marker,
  # which silently parks the issue while consuming a max_concurrent_features slot.
  # Classify as retry-immediately (exit 25); classify_failure's auto-escalation
  # converts repeated same-evidence retries into skip-until-code-changes.
  if (( ! skip_dispatch )); then
    case "$stage" in
      brainstorm|plan|implement|ui|review|qa|build)
        local _summary_path _fresh_marker
        _summary_path="$(issue_dir "$ident")/stage-summary-${stage}.md"
        _fresh_marker="$(find_fresh_verdict "$ident" 2>/dev/null || printf '')"
        if [[ ! -s "$_summary_path" ]] && [[ -z "$_fresh_marker" ]]; then
          classify_failure "$ident" "$stage" "retry-immediately" \
            "agent dispatch returned 0 but emitted no stage-summary file and no verdict marker" 25
          exit 25
        fi
        ;;
    esac
  fi

  # Push branch BEFORE posting the completion comment so any `github.com/.../blob/<branch>/…`
  # link in the agent's summary resolves. run-local.sh's partition-sweep push only fires on
  # uncommitted dirty paths; an agent that commits its artifacts cleanly otherwise leaves the
  # branch local-only (ENG-6 observed). Non-fatal on failure — next tick will retry.
  case "$stage" in
    brainstorm|plan|implement|ui|review|qa|build)
      push_branch_if_ahead || true
      ;;
  esac

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
      # Clear pipeline:supersede on brainstorm/plan stage success so the signal
      # does not leak into downstream stages (only reconcile reads this label,
      # and reconcile only runs for brainstorm/plan per run-local.sh).
      # NOTE: pipeline:extend is NOT auto-cleared (ENG-6 D-005 — extend is a
      # carry-forward signal the operator may intend to span multiple stages).
      if [[ "$stage" == "brainstorm" || "$stage" == "plan" ]]; then
        bash "$SCRIPT_DIR/linear.sh" remove-label "$ident" "pipeline:supersede" 2>/dev/null || true
      fi
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
