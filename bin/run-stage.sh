#!/usr/bin/env bash
# Run a single pipeline stage against a Linear issue.
# Usage: run-stage.sh <issue_id> <stage>
# Exit codes: 0=success, 10=guards-tripped, 11=paused, 12=stage-drift (post-dispatch
#             stage label changed during run; no halt re-applied), 13=lane-violation
#             (linear.sh write rejected for caller's PIPELINE_WRITER lane),
#             20=dispatch-failed, 21=scope-violation, 22=pr-opened-too-early,
#             23=branch-creation-forbidden (any-stage transcript invoked
#             git checkout -b/-B/branch -m/switch -c; ENG-66),
#             24=linear-post-failed, 25=agent-contract-missing (agent exited clean
#             but emitted neither the stage-summary file nor a verdict-marker comment),
#             26=worktree-mutation-forbidden (build-stage transcript invoked
#             git checkout/switch/pull/reset; ENG-71),
#             27=self-leak (out-of-scope path appeared post-dispatch; ENG-14),
#             28=leaked-in-scope-threshold (≥3 consecutive in-scope leaks; ENG-14),
#             29=envelope-violation (dispatch envelope validator detected agent bypass
#             of bin/linear.sh — ENG-87),
#             33=plan-contract-malformed (plan.json exists but fails jq parse; ENG-122),
#             34=plan-contract-incomplete (plan.json parses but missing required field; ENG-122),
#             35=plan-contract-missing (no sibling .json alongside plan .md; ENG-122),
#             39=qa-payload-malformed (verdict-qa.json fails jq parse; ENG-117),
#             40=qa-payload-incomplete (verdict-qa.json parses but missing required field; ENG-117),
#             41=qa-payload-missing (no verdict-qa.json post-qa-dispatch; ENG-117),
#             124=dispatch-timeout (gtimeout SIGTERM'd a wedged claude -p — ENG-48).
#             (See bin/common.sh::failure_outcome_for_exit for the canonical mapping.)
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

  # Stage → doc-dir mapping. Only brainstorming and planning have a single
  # canonical doc surface; post-plan stages span the repo and are best
  # described by branch-delta which the PR link already covers.
  local doc_dir=""
  case "$stage" in
    brainstorming) doc_dir="docs/brainstorms" ;;
    planning)      doc_dir="docs/plans" ;;
    *)             printf ''; return 0 ;;
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

# ─── Cost-telemetry helpers (ENG-26) ─────────────────────────────────────────
# Read $issue_dir/usage-<stage>.json (six fields written by dispatch.sh's
# stream-json renderer) and turn it into the per-stage `metrics.sh stage-end`
# flag stream / Linear footer string. Both helpers are silent on missing or
# malformed file (D-010 — soft fail; cost telemetry is observability, not
# control flow).
#
# The flag stream is newline-delimited: one `--key` per line, one value per
# line. The caller slurps it into a bash array and passes it via
# `"${cost_flags[@]+"${cost_flags[@]}"}"` (bash-3.2 / set -u safe expansion).
# Newline-delimited output is the contract that preserves the captured
# `claude-opus-4-7[1m]` model name verbatim across the function boundary —
# the model literal contains glob chars and would word-split if returned as
# a single string (DL-202 / SEC-007).
_cost_flags_for() {
  local issue="$1" stage="$2"
  local f; f="$(issue_dir "$issue")/usage-${stage}.json"
  [[ -s "$f" ]] || return 0
  jq -r '
    "--tokens-in",    (.tokens_in    // 0 | tostring),
    "--tokens-out",   (.tokens_out   // 0 | tostring),
    "--cache-read",   (.cache_read   // 0 | tostring),
    "--cache-create", (.cache_create // 0 | tostring),
    "--cost-usd",     (.cost_usd     // 0 | tostring),
    "--model",        (.model        // "unknown")
  ' "$f" 2>/dev/null || true
}

# ─── Per-stage model resolver (ENG-103) ───────────────────────────────────
# Count <!-- pipeline: verdict result=fail target=<stage> --> markers newer
# than the most recent <!-- pipeline: transition ... to=<stage> --> comment.
# Used by _resolve_dispatch_model's escalation predicate (ENG-103 D-002).
# Reuses the comment-fetch path from guards.sh::count_marker_since_last_operator_resume
# but projects each body through parse_pipeline_marker (common.sh) so prose-
# quoted markers don't register (ENG-87 / ENG-61 Bug A precedent). Fail-open:
# Linear API outage returns 0 (no escalation) — matches the dispatch-side
# fail-open posture of _entry_conditions_gate's ENG-86 block.
# ENG-105 follow-up: detects whether an implementing dispatch made any
# new commits by comparing the worktree's HEAD before and after.
# Returns 0 (true — new commits) if HEAD advanced or if HEAD-post can't
# be read (fail-open: a missing worktree means dispatch failed elsewhere
# and shouldn't be re-classified as a NOOP). Returns 1 (false) only when
# HEAD-post is non-empty and exactly equals HEAD-pre.
#
# Caller is responsible for the gating (stage == implementing,
# !skip_dispatch, _HEAD_PRE_DISPATCH non-empty) — this helper only
# implements the comparison so it's straightforward to unit-test.
_dispatch_made_new_commits() {
  local worktree="$1" head_pre="$2"
  local head_post
  head_post="$(git -C "$worktree" rev-parse HEAD 2>/dev/null || printf '')"
  [[ -n "$head_post" ]] || return 0
  [[ "$head_post" != "$head_pre" ]]
}

# ENG-139 follow-up: extract the source stage of the most-recent
# transition `to=<stage>` from Linear comments, excluding operator-resume
# self-loops (`from=<stage> to=<stage> reason=operator-resume`). Without
# the operator-resume filter, a resume from a halted review-loopback
# would return `<stage>` instead of `reviewing` and the caller would
# wrongly conclude "not a review-loopback" — losing the very signal the
# resume was meant to continue.
#
# Used by main() to set PIPELINE_LOOPBACK_SOURCE before invoking
# render-prompt.sh, which gates _resolve_review_findings so build →
# implementing rebase loopbacks (ENG-106 / ENG-139) and qa →
# implementing fail loopbacks don't inherit stale review findings.
#
# Fail-open: Linear API outage / empty comments / parse failure → empty
# stdout. render-prompt.sh's resolver treats unset env as back-compat
# (file content if non-empty), so an outage replicates pre-ENG-139
# behavior rather than surprising the agent.
_resolve_loopback_source() {
  local ident="$1" stage="$2"
  local comments
  comments="$(bash "$SCRIPT_DIR/linear.sh" get-comments "$ident" 2>/dev/null)" \
    || { printf ''; return 0; }
  [[ -z "$comments" || "$comments" == "null" ]] && { printf ''; return 0; }

  local latest_ts="" latest_from="" body ts ev
  local event_field to_field from_field reason_field
  while IFS=$'\t' read -r ts body; do
    [[ -z "$ts" ]] && continue
    ev="$(parse_pipeline_marker "$body" 2>/dev/null || true)"
    [[ -z "$ev" ]] && continue
    event_field="$(jq -r '.event // ""' <<<"$ev" 2>/dev/null || printf '')"
    to_field="$(jq -r '.to // ""' <<<"$ev" 2>/dev/null || printf '')"
    from_field="$(jq -r '.from // ""' <<<"$ev" 2>/dev/null || printf '')"
    reason_field="$(jq -r '.reason // ""' <<<"$ev" 2>/dev/null || printf '')"
    [[ "$event_field" == "transition" && "$to_field" == "$stage" ]] || continue
    [[ "$reason_field" == "operator-resume" ]] && continue
    if [[ "$ts" > "$latest_ts" ]]; then
      latest_ts="$ts"
      latest_from="$from_field"
    fi
  done < <(jq -r '.[] | "\(.createdAt)\t\(.body | gsub("\n"; " "))"' <<<"$comments" 2>/dev/null)

  printf '%s' "$latest_from"
}

_count_loopback_rejections_for_stage() {
  local ident="$1" stage="$2"
  local comments
  comments="$(bash "$SCRIPT_DIR/linear.sh" get-comments "$ident" 2>/dev/null)" \
    || { printf '0'; return 0; }
  [[ -z "$comments" || "$comments" == "null" ]] && { printf '0'; return 0; }

  # Find most recent transition.to=<stage> createdAt (empty → count all).
  local last_ts="" body ts ev event_field to_field
  while IFS=$'\t' read -r ts body; do
    [[ -z "$ts" ]] && continue
    ev="$(parse_pipeline_marker "$body" 2>/dev/null || true)"
    [[ -z "$ev" ]] && continue
    event_field="$(jq -r '.event // ""' <<<"$ev" 2>/dev/null || printf '')"
    to_field="$(jq -r '.to // ""' <<<"$ev" 2>/dev/null || printf '')"
    if [[ "$event_field" == "transition" && "$to_field" == "$stage" ]]; then
      [[ "$ts" > "$last_ts" ]] && last_ts="$ts"
    fi
  done < <(jq -r '.[] | "\(.createdAt)\t\(.body | gsub("\n"; " "))"' <<<"$comments" 2>/dev/null)

  # Count verdict.result=fail.target=<stage> newer than last_ts.
  local count=0 result_field target_field
  while IFS=$'\t' read -r ts body; do
    [[ -z "$ts" ]] && continue
    [[ -n "$last_ts" && ! "$ts" > "$last_ts" ]] && continue
    ev="$(parse_pipeline_marker "$body" 2>/dev/null || true)"
    [[ -z "$ev" ]] && continue
    event_field="$(jq -r '.event // ""' <<<"$ev" 2>/dev/null || printf '')"
    result_field="$(jq -r '.result // ""' <<<"$ev" 2>/dev/null || printf '')"
    target_field="$(jq -r '.target // ""' <<<"$ev" 2>/dev/null || printf '')"
    if [[ "$event_field" == "verdict" \
       && "$result_field" == "fail" \
       && "$target_field" == "$stage" ]]; then
      count=$((count + 1))
    fi
  done < <(jq -r '.[] | "\(.createdAt)\t\(.body | gsub("\n"; " "))"' <<<"$comments" 2>/dev/null)

  printf '%s' "$count"
}

# Resolve the model identifier for a dispatched stage. Precedence (highest →
# lowest), mirroring _cfg_minutes at bin/dispatch.sh:469-488:
#   1. .pipeline-config/config.json::dispatch.model[<stage>]
#   2. Built-in escalation override on implementing/ui when
#      _count_loopback_rejections_for_stage >= 1.
#   3. Built-in default table (ENG-103 D-001).
#   4. Unset → empty stdout → dispatch.sh omits --model.
# Validation: claude model identifiers match [A-Za-z0-9._\[\]:-]+. Regex-fail
# at layer 1 logs a warning and falls through to layer 2/3.
_resolve_dispatch_model() {
  local stage="$1" ident="$2"

  # Layer 1: operator-pinned config. `strings` filter discards non-string
  # types (jq integer 60 → no output) so type-mismatched config silently
  # falls through. Regex validator then rejects shell-meta payloads
  # (`claude$(curl evil.com)` contains `$()` which is NOT in the char class).
  # The optional `\[...\]` suffix accommodates `claude-opus-4-7[1m]` 1M-context
  # form without admitting brackets anywhere else in the identifier.
  if [[ -f "$CONFIG" ]]; then
    local _cfg
    _cfg="$(jq -r --arg s "$stage" '(.dispatch.model[$s] | strings) // empty' \
      "$CONFIG" 2>/dev/null || true)"
    if [[ -n "$_cfg" ]]; then
      if [[ "$_cfg" =~ ^[A-Za-z0-9._:-]+(\[[A-Za-z0-9._:-]+\])?$ ]]; then
        printf '%s' "$_cfg"; return 0
      else
        log "_resolve_dispatch_model: rejecting config value for $stage (failed regex); falling through" >&2
      fi
    fi
  fi

  # Layer 2: escalation override (implementing | ui only).
  case "$stage" in
    implementing|ui)
      local _count
      _count="$(_count_loopback_rejections_for_stage "$ident" "$stage" 2>/dev/null || printf '0')"
      if [[ "$_count" =~ ^[0-9]+$ ]] && (( _count >= 1 )); then
        printf 'claude-opus-4-7'; return 0
      fi
      ;;
  esac

  # Layer 3: built-in default table (ENG-103 D-001).
  case "$stage" in
    brainstorming) printf 'claude-opus-4-7' ;;
    planning)      printf 'claude-opus-4-7' ;;
    # implementing default: stays Opus until ENG-101 stabilises (D-008);
    # flip to claude-sonnet-4-6 in follow-up commit when ENG-101 ships.
    implementing)  printf 'claude-opus-4-7' ;;
    ui)            printf 'claude-sonnet-4-6' ;;
    reviewing)     printf 'claude-opus-4-7' ;;
    qa)            printf 'claude-sonnet-4-6' ;;
    building)      printf 'claude-haiku-4-5-20251001' ;;
    *)             printf '' ;;  # released, retrospective → subscription default
  esac
}

# Format: leading newline so the caller can append unconditionally.
# Cache% (D-007): round(100 * cache_read / (cache_read + cache_create)).
# When read+create == 0, omit the `· cache N%` segment entirely — do NOT
# print `0%` (that misleads the operator into thinking the cache failed
# rather than that there was no cache traffic at all).
#
# Soft-fail semantics (D-010): a corrupt-but-nonempty usage file MUST
# return empty, mirroring the absent-file path. The single `jq @tsv`
# extraction returns nothing when the file does not parse as JSON
# (errors silenced); an empty TSV short-circuits before any awk
# formatting can render misleading `cost: $0.00 · in 0.0k …` output.
_cost_footer() {
  local issue="$1" stage="$2"
  local f; f="$(issue_dir "$issue")/usage-${stage}.json"
  [[ -s "$f" ]] || { printf ''; return 0; }

  local tsv
  tsv="$(jq -r '[.cost_usd // 0, .tokens_in // 0, .tokens_out // 0, .cache_read // 0, .cache_create // 0] | @tsv' \
    "$f" 2>/dev/null)" || tsv=""
  [[ -z "$tsv" ]] && { printf ''; return 0; }

  local cost_usd tokens_in tokens_out cache_read cache_create
  IFS=$'\t' read -r cost_usd tokens_in tokens_out cache_read cache_create <<<"$tsv"

  local cache_seg=""
  if (( cache_read + cache_create > 0 )); then
    local cache_pct
    cache_pct="$(awk -v r="$cache_read" -v c="$cache_create" \
      'BEGIN{ printf("%d", (100.0 * r) / (r + c) + 0.5) }')"
    cache_seg=" · cache ${cache_pct}%"
  fi

  awk -v cost="$cost_usd" -v ti="$tokens_in" -v to="$tokens_out" -v cs="$cache_seg" \
    'BEGIN{ printf("\ncost: $%.2f · in %.1fk · out %.1fk%s", cost, ti/1000.0, to/1000.0, cs) }'
}

# ENG-26 D-011: scope-approval replay does NOT invoke claude this tick,
# so a usage-<stage>.json from the prior real dispatch would otherwise
# be re-read by `_cost_flags_for` and double-count cost. Remove the file
# before the replay metrics emit so it cleanly omits cost fields.
_replay_scope_approval() {
  local ident="$1" stage="$2"
  rm -f "$(issue_dir "$ident")/usage-${stage}.json"
  bash "$SCRIPT_DIR/metrics.sh" stage-start "$ident" "$stage" "scope-approval-replay" 0
}

# Strip common.sh::log's `[ts]` prefix from scope-check stderr and join
# multi-line diagnostics with `; ` so the halt reason reads as one sentence
# in Linear. Empty input → empty output (caller falls back).
# `|| true` guards the grep-no-match rc=1 from killing set -e callers.
_compose_scope_check_detail() {
  local scope_out="$1"
  { grep -E '^\[.*\] scope-check: ' <<<"$scope_out" \
      | sed -E 's/^\[[^]]+\][[:space:]]+//' \
      | awk 'BEGIN{ORS=""} NR>1{print "; "} {print}'; } || true
}

# ─── Per-stage success-path completion comment (ENG-11) ──────────────────────
# Read the agent-authored summary file, wrap with header + PR tail, and
# upsert under sig completion/<stage>/<issue>. On missing/empty/symlink,
# post a mechanical fallback with <!-- meta: metric name=summary_missing -->.
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
    ui|reviewing|qa|building)
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
  # Order matters: strip dedup-marker LINES *before* byte-truncating so a
  # mid-line byte cut inside a `<!-- meta: dedup key=… -->` line cannot leave
  # a partial (and therefore unmatched-by-sed) marker in the posted body.
  # Both new-shape and any legacy `<!-- pipeline-<word>: … -->` lines are
  # stripped so an agent that copies a stale fixture can't hijack the dedup
  # key, and so the linear.sh lane-fence (PR #44) doesn't reject the post for
  # carrying a legacy verdict-family marker (`pipeline-stage-summary`,
  # `pipeline-rejection`, `pipeline-halt`, etc.) the agent may have emitted.
  # The new `<!-- pipeline: <event> ... -->` shape (no hyphen between
  # `pipeline` and the event) is preserved.
  #
  # ENG-96: also strip `<!-- meta: dispatch id=... -->` lines. The
  # chokepoint at bin/linear.sh::add_comment owns this marker
  # (auto-injects from PIPELINE_DISPATCH_ID); an agent-emitted marker —
  # whether a literal-placeholder `$PIPELINE_DISPATCH_ID` (the ENG-96
  # case), a stale prior-dispatch id, or a syntactically valid current id —
  # is defense-in-depth-scrubbed here so the auto-injection re-adds
  # exactly one canonical marker. Without this, an agent-emitted marker
  # poisons find_fresh_verdict's ENG-87 strict-id-match path and halts
  # the issue with `protocol-violation/dispatch-id-mismatch`.
  local body fallback_marker=""
  if [[ -L "$summary_path" ]]; then
    fallback_marker="summary_symlink_refused"
  elif [[ ! -s "$summary_path" ]]; then
    fallback_marker="summary_missing"
  else
    local fsize; fsize="$(wc -c < "$summary_path" | tr -d ' ')"
    body="$(sed -E \
      -e '/<!-- meta: dedup key=.* -->/d' \
      -e '/<!-- meta: dispatch id=.* -->/d' \
      -e '/<!-- pipeline-[a-z]+: .* -->/d' \
      "$summary_path" | head -c 32768)"
    if (( fsize > 32768 )); then
      body+=$'\n\n_[truncated at 32 KiB]_'
      body+=$'\n<!-- meta: metric name=summary_truncated -->'
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
    # The cost footer is intentionally NOT appended on the fallback path —
    # symmetric with _stage_artifacts_footer's "artifacts-only-on-fallback"
    # design (no usage to report on a silent-exit / dispatch-crashed run).
    local artifacts_tail
    artifacts_tail="$(_stage_artifacts_footer "$issue" "$stage")"
    comment_body="$(printf '%s\n\n_Agent did not write a stage summary; posting mechanical completion._%s%s\n<!-- meta: metric name=%s -->' \
      "$header" "$pr_tail" "$artifacts_tail" "$fallback_marker")"
  else
    # Cost footer (ENG-26 D-008): one line of `cost: $X · in Yk · out Zk
    # · cache N%` between body and PR tail. Empty string when the usage
    # file is missing/malformed (legacy / dispatch-crashed / dry-run).
    local cost_footer
    cost_footer="$(_cost_footer "$issue" "$stage")"
    comment_body="$(printf '%s\n\n%s%s%s' "$header" "$body" "$cost_footer" "$pr_tail")"
  fi

  # Retry once on failure. add-comment --sig stamps the dispatch-
  # suffixed dedup marker; each retry posts a fresh chronological
  # comment if the first one didn't land.
  if bash "$SCRIPT_DIR/linear.sh" add-comment "$issue" --sig "$sig" --body "$comment_body"; then
    return 0
  fi
  sleep 5
  bash "$SCRIPT_DIR/linear.sh" add-comment "$issue" --sig "$sig" --body "$comment_body"
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
  paused="$(is_orchestrator_paused)"
  if [[ "$paused" == "true" ]]; then
    log "orchestrator globally paused"
    return 11
  fi

  # Per-issue pause?
  if bash "$SCRIPT_DIR/linear.sh" has-label "$ident" "pipeline:paused"; then
    log "issue paused via pipeline:paused label"
    return 11
  fi

  # Expected stage label present? Derive the canonical gerund label suffix.
  local prefix expected
  prefix="$(config_get '.linear.stage_label_prefix')"
  local label_suffix
  case "$stage" in
    brainstorming) label_suffix="brainstorming" ;;
    planning)      label_suffix="planning"      ;;
    implementing)  label_suffix="implementing"  ;;
    ui)            label_suffix="ui"            ;;
    reviewing)     label_suffix="reviewing"     ;;
    qa)            label_suffix="qa"            ;;
    building)      label_suffix="building"      ;;
    released)      label_suffix="released"      ;;
    *)             label_suffix=""              ;;
  esac
  expected="${prefix}${label_suffix}"

  if [[ -n "$expected" ]] && ! bash "$SCRIPT_DIR/linear.sh" has-label "$ident" "$expected"; then
    die "precondition failed: $ident does not carry $expected (must be applied before run-stage)"
  fi

  return 0
}

# ─── ENG-45 / ENG-54: build-stage wait-marker gate + budget escalation ──────
# Returns the wait reason on stdout (exit 0) iff a fresh, well-formed,
# build-only `<!-- pipeline: verdict result=wait reason=... -->` marker
# exists newer than the most recent transition. Else prints empty + nonzero.
# Build-only
# gate (security F-1); closed reason allow-list (security F-2). Fail-closed
# on Linear read failure: nonzero exit OR empty/null output from get-comments
# → return 1 → caller falls through to the agent-contract validator.
#
# ENG-54: review was previously also allow-listed (review-stage human-approval
# gate). The human-approval gate now lives at build's P2 — review never waits
# — so the allow-list narrows back to `build` only.
_fresh_wait_reason() {
  local issue="$1" stage="$2"
  case "$stage" in
    building) ;;
    *) return 1 ;;
  esac

  local comments
  comments="$(bash "$SCRIPT_DIR/linear.sh" get-comments "$issue" 2>/dev/null)" || return 1
  [[ -z "$comments" || "$comments" == "null" ]] && return 1

  # Find the most recent transition timestamp to set freshness floor.
  local last_t=""
  local ts body ev
  while IFS=$'\t' read -r ts body; do
    ev="$(parse_pipeline_marker "$body" 2>/dev/null || true)"
    [[ -z "$ev" ]] && continue
    if [[ "$(jq -r '.event' <<<"$ev")" == "transition" ]]; then
      [[ "$ts" > "$last_t" ]] && last_t="$ts"
    fi
  done < <(jq -r '.[] | "\(.createdAt)\t\(.body | gsub("\n"; " "))"' <<<"$comments")

  # Find the latest verdict (of any result) newer than the transition.
  # ENG-61 Bug B fix: tracking only wait verdicts here meant any later
  # pass/fail/halt/pivot was invisible — _fresh_wait_reason kept returning
  # a stale wait reason and the orchestrator looped on _handle_wait until
  # an operator manually flipped labels. Track the latest verdict
  # regardless of result; decide post-loop whether it is still a wait.
  local fresh_reason="" fresh_result=""
  local fresh_ts=""
  while IFS=$'\t' read -r ts body; do
    [[ -n "$last_t" && ! "$ts" > "$last_t" ]] && continue
    ev="$(parse_pipeline_marker "$body" 2>/dev/null || true)"
    [[ -z "$ev" ]] && continue
    [[ "$(jq -r '.event' <<<"$ev")" != "verdict" ]] && continue
    if [[ "$ts" > "$fresh_ts" ]]; then
      fresh_ts="$ts"
      fresh_result="$(jq -r '.result' <<<"$ev")"
      # `// ""` keeps the post-loop empty-reason guard semantically correct
      # for the wait branch (pass/fail/halt verdicts have no .reason field).
      fresh_reason="$(jq -r '.reason // ""' <<<"$ev")"
    fi
  done < <(jq -r '.[] | "\(.createdAt)\t\(.body | gsub("\n"; " "))"' <<<"$comments")

  # If the latest verdict in the freshness window is not a wait, the wait
  # has been superseded — return rc=1 and let the caller fall through.
  [[ "$fresh_result" != "wait" ]] && return 1

  [[ -z "$fresh_reason" ]] && return 1

  case "$fresh_reason" in
    awaiting-approval|awaiting-ci) printf '%s' "$fresh_reason"; return 0 ;;
    *) return 1 ;;
  esac
}

# ENG-56: orchestrator is the canonical applier of pipeline:halted. Called
# from main()'s post-dispatch hook after every non-drift, non-wait-early-exit
# stage run. Idempotent: skips the add-label call if the label is already on
# the issue.
#
# Wait-shape carve-out: if a fresh `<!-- pipeline: verdict result=wait reason=... -->` marker
# (ENG-45) is the latest verdict, the issue is *waiting*, not *halted*, and
# the label must NOT be applied. In current control flow the wait-shape
# early-exit at line ~676 prevents this hook from being reached on a real
# wait — but the carve-out here is defense-in-depth so a future flow change
# cannot silently mis-label a waiting issue. Stage-restricted to build /
# review (matching `_fresh_wait_reason`'s allow-list); other stages that
# stray into wait-shape territory are agent protocol violations and the
# halt apply is the correct response.
_post_dispatch_apply_halt() {
  local ident="$1" stage="$2"
  local _wait_reason
  _wait_reason="$(_fresh_wait_reason "$ident" "$stage" 2>/dev/null || printf '')"
  if [[ -n "$_wait_reason" ]]; then
    log "post-dispatch: wait-shape verdict ($_wait_reason); not applying pipeline:halted"
    return 0
  fi
  if ! bash "$SCRIPT_DIR/linear.sh" has-label "$ident" "pipeline:halted"; then
    log "post-dispatch: applying pipeline:halted (orchestrator-managed, ENG-56)"
    bash "$SCRIPT_DIR/linear.sh" add-label "$ident" "pipeline:halted" || true
  fi
}

# ENG-71: defense-in-depth detector for the worktree-on-main symptom.
# D-002 (in dispatch.sh) catches the contract violation pre-exit; this
# is the state-of-the-world fallback that runs even if D-002 misses
# (chained commands that bypass the startswith matcher per the brainstorm
# §7 known-limitation; future matcher change silently re-permits
# Bash(git checkout:*); etc.).
#
# On detection, detach HEAD to the current commit. A detached HEAD is
# invisible to git's "branch already checked out" lock, so the operator's
# primary main-checkout becomes usable again. We do NOT auto-switch back
# to {branch_name} — if the agent left commits on main locally, switching
# back would silently abandon them; detach preserves them as a
# reflog-recoverable orphan and surfaces the anomaly via the metric.
#
# Stage-gated to "building" because that's the only stage with the
# observed symptom (post-merge worktree-on-main). Other stages may
# legitimately have detached HEADs (none today, but the gate keeps
# the change minimal).
_post_dispatch_check_worktree_head() {
  local PIPELINE_WRITER=orchestrator
  export PIPELINE_WRITER

  local ident="$1" stage="$2"
  case "$stage" in building) ;; *) return 0 ;; esac
  local wt; wt="$(issue_dir "$ident")/worktree"
  [[ -d "$wt/.git" ]] || [[ -f "$wt/.git" ]] || return 0

  # Resolve expected branch via branch-name.sh (the canonical derivation;
  # mirrors run-local.sh:220). Soft-fail on Linear API outage so we don't
  # detach on a wrong expected value. ENG-71 m2 (review iter-2): emit a
  # log line on the silent-skip path so operators can distinguish "no
  # mismatch" from "branch-name.sh returned empty" in the per-stage
  # transcript.
  local expected_branch current_branch
  expected_branch="$(bash "$SCRIPT_DIR/branch-name.sh" "$ident" 2>/dev/null || printf '')"
  current_branch="$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || printf '')"
  if [[ -z "$expected_branch" || -z "$current_branch" ]]; then
    log "post-dispatch worktree-HEAD check: skipping ($ident, $stage) — expected_branch='$expected_branch' current_branch='$current_branch' (one or both empty; branch-name.sh outage or git unavailable). No detach attempted."
    return 0
  fi
  # ENG-71 review iter-6 [M1]: when HEAD is already detached (this helper
  # ran on a prior tick, or any other actor detached), `git rev-parse
  # --abbrev-ref HEAD` returns the literal string "HEAD". Steady-state of
  # this helper is "HEAD detached so main is unlocked" — re-running
  # `git checkout --detach` (a no-op on already-detached) and re-emitting
  # the worktree-mutated metric every dispatch would just pollute
  # events.jsonl. Mirrors the early-exit precedent at push_branch_if_ahead
  # (line 236).
  [[ "$current_branch" == "HEAD" ]] && return 0
  [[ "$current_branch" == "$expected_branch" ]] && return 0

  log "post-dispatch: WORKTREE HEAD MUTATED — expected=$expected_branch current=$current_branch; detaching to unlock parent ref"
  # ENG-71 m1 (review iter-2): capture the detach exit code via PIPESTATUS
  # so the operator-visibility comment body and the metric notes can both
  # describe the actual detach outcome. Pre-iter-6 the body unconditionally
  # claimed "Orchestrator detached HEAD" even when `git checkout --detach`
  # silently failed (the `|| true` swallowed the rc), which mis-led
  # operators into believing main was unlocked when in fact it was still
  # locked by a failed detach.
  git -C "$wt" checkout --detach 2>&1 | sed 's/^/  detach: /' >&2
  local _detach_rc=${PIPESTATUS[0]}
  bash "$SCRIPT_DIR/metrics.sh" worktree-mutated-by-agent "$ident" "$stage" \
    "warn" 0 "expected=$expected_branch current=$current_branch detach_rc=$_detach_rc" \
    || log "metrics.sh worktree-mutated-by-agent emission failed (non-blocking)"

  # Operator-visibility: post a non-halting Linear comment so an operator
  # skimming the issue thread sees the detach without grepping events.jsonl
  # or per-stage transcripts. Append-only via add-comment --sig so
  # re-fires on retry collapse to one comment per issue. ENG-71 m5 (review
  # iter-2): sig prefix `worktree-mutation/<issue>` is functionally named
  # (mirrors the existing `completion/<stage>/<issue>` and
  # `protocol-violation/<reason>/<issue>` patterns: <category>/<issue>)
  # rather than the prior severity-adjective `warn/<topic>/<issue>` which
  # had no precedent in the codebase.
  local _detach_status
  if (( _detach_rc == 0 )); then
    _detach_status='Orchestrator detached HEAD to unlock `main` globally. The merged feature commit is preserved as a detached-HEAD reflog entry; `cleanup-worktrees.sh` will remove the worktree on the next post-merge tick. No operator action required.'
  else
    _detach_status="Orchestrator attempted to detach HEAD but \`git checkout --detach\` failed (rc=$_detach_rc); \`main\` may STILL be globally locked. Operator action required: from a sibling shell run \`git -C $wt checkout --detach\` (or \`git worktree remove --force $wt\` if the worktree is otherwise corrupt)."
  fi
  local _body
  _body="$(printf '<!-- meta: metric name=worktree-mutated-by-agent -->\n\nBuild agent left this worktree on `%s` (expected `%s`) post-dispatch. %s' \
    "$current_branch" "$expected_branch" "$_detach_status")"
  bash "$SCRIPT_DIR/linear.sh" add-comment "$ident" \
    --sig "worktree-mutation/$ident" --body "$_body" \
    || log "linear.sh add-comment failed for worktree-mutation/$ident (non-blocking)"
}

# Idempotent counter mutation + budget check for wait exits. All Linear writes
# inside this function go through the orchestrator lane (security F-4). State
# file at $(issue_dir)/wait-${stage}.json is owned by the orchestrator (per
# ENG-18 separation between agent signals and orchestrator-owned state).
# Returns 0 = within budget (caller exits 0). Returns 1 = budget exhausted,
# halt was applied (caller falls through to defensive halt-add (now a no-op)
# and verdict_handler, which preserves the halt naturally).
_handle_wait() {
  local PIPELINE_WRITER=orchestrator
  export PIPELINE_WRITER

  local ident="$1" stage="$2" reason="$3"
  local f; f="$(issue_dir "$ident")/wait-${stage}.json"
  local now; now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # Clear any stale stage-summary file so a later post_completion_comment
  # cannot post stale content from a prior dispatch.
  rm -f "$(issue_dir "$ident")/stage-summary-${stage}.md" 2>/dev/null || true

  local first attempts
  if [[ -s "$f" ]] && jq -e . "$f" >/dev/null 2>&1; then
    first="$(jq -r '.first_attempt_at // ""' "$f")"
    attempts="$(jq -r '.attempts // 0' "$f")"
    # Field-validity guard (security F-3): regex-validate first_attempt_at
    # before feeding it to date -j -f. An attacker-controlled file (crafted
    # via the agent's Write tool) cannot reach the arithmetic substitution.
    if [[ ! "$first" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
      first="$now"; attempts=0
    else
      # Value-validity guard (review-major-2 + round-2 M1): regex-valid but
      # out-of-band timestamps neutralise the wall-clock cap. The future-
      # clamp closes 9999-12-31T… (negative elapsed → clamp to 0 → never
      # exhausts on max_minutes-only). The pre-epoch floor closes the
      # symmetric attack: 1900-01-01T00:00:00Z parses (under BSD date) to
      # ~-2.2e9, blowing past any max_minutes on the first tick. Treat any
      # first_attempt_at outside [0, now] as corrupt and reset.
      local _first_epoch _now_epoch
      # TZ=UTC pin: the `Z` in the format string is matched as a literal
      # character, not interpreted as zulu. Without TZ=UTC, date interprets
      # the H:M:S in host-local TZ and the resulting epoch is off by the
      # host TZ offset (round-2 review M2).
      _first_epoch="$(TZ=UTC date -j -f %Y-%m-%dT%H:%M:%SZ "$first" +%s 2>/dev/null || printf '')"
      _now_epoch="$(date -u +%s)"
      if [[ -z "$_first_epoch" ]] || (( _first_epoch < 0 )) || (( _first_epoch > _now_epoch )); then
        first="$now"; attempts=0
      fi
    fi
    [[ "$attempts" =~ ^[0-9]+$ ]] || attempts=0
    attempts=$((attempts + 1))
  else
    first="$now"; attempts=1
  fi

  local body tmp
  body="$(jq -cn --arg i "$ident" --arg s "$stage" --arg r "$reason" \
                --arg fa "$first" --arg la "$now" --argjson n "$attempts" '
    {issue:$i, stage:$s, reason:$r, attempts:$n,
     first_attempt_at:$fa, last_attempt_at:$la}')"
  tmp="${f}.tmp.$$"; printf '%s' "$body" > "$tmp"; mv -f "$tmp" "$f"

  local max_a max_m
  max_a="$(config_get '.orchestrator.external_signal_budget.max_attempts // empty')"
  max_m="$(config_get '.orchestrator.external_signal_budget.max_minutes  // empty')"

  local exhausted=0
  [[ -n "$max_a" && "$max_a" =~ ^[0-9]+$ ]] && (( attempts >= max_a )) && exhausted=1
  if [[ -n "$max_m" && "$max_m" =~ ^[0-9]+$ ]]; then
    local first_epoch elapsed_m
    # TZ=UTC pin (round-2 review M2): see analogous note above. case K2
    # fails on a non-UTC host without this prefix.
    first_epoch="$(TZ=UTC date -j -f %Y-%m-%dT%H:%M:%SZ "$first" +%s 2>/dev/null || printf '')"
    if [[ -n "$first_epoch" ]]; then
      elapsed_m=$(( ($(date -u +%s) - first_epoch) / 60 ))
      (( elapsed_m < 0 )) && elapsed_m=0
      (( elapsed_m >= max_m )) && exhausted=1
    fi
  fi

  if (( exhausted )); then
    local halt_body
    halt_body="$(printf '<!-- pipeline: verdict result=halt reason=external-signal-budget-exhausted -->\n\nBuild stage halted: %s budget exhausted (%d attempts since %s).\n\n**Resume:** approve the PR as a non-bot Code Owner, then run `bash bin/pipeline.sh decide %s --action continue`. Or raise `orchestrator.external_signal_budget.max_attempts` / `max_minutes` in `.pipeline-config/config.json` to extend the window.' \
                "$reason" "$attempts" "$first" "$ident")"
    bash "$SCRIPT_DIR/linear.sh" add-comment "$ident" "$halt_body" || true
    # Only delete the wait file if the halt label actually applied. A network
    # blip on add-label could otherwise leave the issue with no halt label AND
    # no counter file — the next dispatch would start a brand-new wait window
    # at attempts=1, silently bypassing the budget safety net. Preserving the
    # file means the next dispatch retries the escalation atomically.
    if bash "$SCRIPT_DIR/linear.sh" add-label "$ident" "pipeline:halted"; then
      rm -f "$f"
    else
      log "WARN: pipeline:halted apply failed for $ident at budget exhaust; preserving $f for retry"
    fi
    return 1
  fi
  return 0
}

# ENG-50 / ENG-54: write last-review-state to Linear after a successful
# review-stage dispatch. Records the just-reviewed HEAD SHA so the next
# tick's `review_should_dispatch` only re-fires when new commits land.
# Called from the success branch in main(). Stage-gated by the caller.
#
# ENG-54: this used to also record the most-recent non-bot APPROVED /
# CHANGES_REQUESTED submittedAt timestamps for review-poll's
# human-approval gate. The gate moved to build's P2 in ENG-54; review only
# tracks SHA now.
_post_review_dispatch_update() {
  local issue="$1" branch="$2"
  [[ -n "$issue" && -n "$branch" ]] || { log "post-review-update: missing args; skipping"; return 0; }

  local pr_view
  pr_view="$(gh pr view "$branch" --json commits 2>/dev/null || printf '{}')"

  local head_sha
  head_sha="$(jq -r '.commits[-1].oid // empty' <<<"$pr_view")"

  bash "$SCRIPT_DIR/review-state.sh" update "$issue" "$head_sha" \
    || log "post-review-update: review-state update failed for $issue (continuing)"
}

# ENG-62: pre-dispatch merge-detection gate. If the PR for stage=building
# is already MERGED (e.g., a prior dispatch fired `gh pr merge --auto`
# successfully), there is nothing left for the build agent to do —
# dispatching costs ≈ $1.50 and risks an awaiting-approval emission from
# a prompt-following regression on a future build prompt rewrite.
# Returns 0 = gate fired, transition applied (caller MUST exit 0 after).
# Returns 1 = gate did not fire (caller proceeds to dispatch as today).
# Stage-gated to "building" — only stage with PR-merge semantics today
# (security parallel to _fresh_wait_reason's allow-list at lines 303-306).
# Fail-open on gh outage / branch-derivation failure (D-006).
_pre_dispatch_merge_gate() {
  # Lane attribution mirrors _handle_wait at lines 382-383: file-scope
  # inheritance is correct today, but explicit assignment prevents silent
  # lane-violation if a future caller invokes this helper from an agent
  # sub-shell.
  local PIPELINE_WRITER=orchestrator
  export PIPELINE_WRITER

  local ident="$1" stage="$2"
  case "$stage" in building) ;; *) return 1 ;; esac
  command -v gh >/dev/null 2>&1 || return 1

  local _branch
  _branch="$(bash "$SCRIPT_DIR/branch-name.sh" "$ident" 2>/dev/null || printf '')"
  [[ -n "$_branch" ]] || return 1

  # --state all so a --delete-branch'd merged PR is still found. Mirrors
  # the --state all fallback at line 160 for pr_url derivation.
  local _pr_state
  _pr_state="$(gh pr list --head "$_branch" --state all --json state \
                --jq '.[0].state // ""' 2>/dev/null || printf '')"
  [[ "$_pr_state" == "MERGED" ]] || return 1

  log "build pre-dispatch: PR for $_branch is MERGED; transitioning building → released without invoking agent (ENG-62)"

  local _summary_path
  _summary_path="$(issue_dir "$ident")/stage-summary-${stage}.md"
  mkdir -p "$(dirname "$_summary_path")"
  printf 'Pre-dispatch merge detection (ENG-62): PR on `%s` was already MERGED at orchestrator entry. Transitioned `building → released` without invoking the build agent.\n' \
    "$_branch" > "$_summary_path"

  # Success-path state cleanup, mirroring the cleanup at lines 851-855.
  # ENG-146: strip-not-delete preserves the dispatch_id seq counter so
  # the next stage's first dispatch increments to d<seq+1> instead of
  # colliding at d0001 with this stage's id.
  rm -f "$(issue_dir "$ident")/wait-${stage}.json" 2>/dev/null || true
  strip_state_preserve_alloc "$(issue_dir "$ident")/issue-state.json" 2>/dev/null || true

  # Apply the transition directly. Each step in apply_transition is
  # idempotent (verdict-handler.sh:158-184); on partial failure (e.g.,
  # transient Linear add-label outage) the next tick re-enters cleanly.
  apply_transition "$ident" "building" "released" "" || true

  return 0
}

# ENG-86: orchestrator-side entry-condition gate. Runs AFTER
# _pre_dispatch_merge_gate (handles MERGED) and BEFORE render-prompt +
# dispatch. Shells out to bin/entry-conditions.sh::should_dispatch which
# reads a per-stage check list from CONFIG and prints `proceed`,
# `skip:<reason>`, or `error:<check-name>` on stdout.
#
# When the gate prints `skip:`, this helper bumps the existing ENG-45
# wait counter via _handle_wait so external_signal_budget escalation
# still applies — a buggy predicate that permanently skips dispatch
# halts the issue within max_attempts ticks.
#
# Returns 0 = gate did NOT fire (caller proceeds to dispatch — note
#             inversion vs _pre_dispatch_merge_gate).
# Returns 1 = gate fired skip; caller MUST exit 0 (caller emits
#             paired dispatch-skipped metric events).
#
# Fail-open on subprocess failure / unexpected outcome (D-010): the
# agent-side P2 (AGENT_PROMPTS.md:1287-1289) is the defense-in-depth
# fallback when an operator opts out of the config or when `gh` errors.
_entry_conditions_gate() {
  # Lane attribution mirrors _pre_dispatch_merge_gate at lines 618-619
  # and _handle_wait at lines 490-491: file-scope inheritance is correct
  # today, but explicit assignment prevents silent lane-violation if a
  # future caller invokes this helper from an agent sub-shell.
  local PIPELINE_WRITER=orchestrator
  export PIPELINE_WRITER

  local ident="$1" stage="$2"
  local outcome
  outcome="$(bash "$SCRIPT_DIR/entry-conditions.sh" should_dispatch \
              "$stage" "$ident" 2>/dev/null || printf 'error:invocation')"

  case "$outcome" in
    proceed)
      return 0
      ;;
    skip:*)
      local reason="${outcome#skip:}"
      log "entry-conditions: skip ($ident, $stage) — reason=$reason"
      # Reuse _handle_wait so external_signal_budget escalation still
      # applies. Within budget → returns 0; budget exhausted → returns
      # 1 (halt already applied). Either way the caller exits clean;
      # the halt label is the durable signal.
      _handle_wait "$ident" "$stage" "$reason" || true
      return 1
      ;;
    error:*)
      local check="${outcome#error:}"
      log "entry-conditions: WARNING — check '$check' errored for $ident/$stage; falling through to dispatch"
      return 0
      ;;
    *)
      log "entry-conditions: unexpected outcome '$outcome'; falling through to dispatch"
      return 0
      ;;
  esac
}

# ENG-87: clear current-stage local files at the start of every dispatch
# so file existence post-dispatch is proof of THIS-dispatch authorship.
# Generalises the wait-exit clear at lines 497-499 (build-only) to all
# stages. Cleared:
#   stage-summary-${stage}.md  (read by post_completion_comment)
#   .rendered-paths-${stage}   (rewritten by render-prompt.sh at dispatch
#                               render; clearing here avoids stale-from-
#                               prior-attempt contamination on retry —
#                               OQ-5)
#   wait-${stage}.json         (overwritten by _handle_wait when the
#                               agent emits a wait verdict; clearing
#                               here ensures a fresh dispatch doesn't
#                               inherit a stale counter)
# NOT cleared:
#   issue-state.json           (allocator merges into it; clearing
#                               would lose classify-failure state)
#   stage-summary-OTHER.md     (forward+loopback reads need them
#                               intact — see brainstorm §6.1/6.2)
_clear_current_stage_slots() {
  local PIPELINE_WRITER=orchestrator
  export PIPELINE_WRITER
  local ident="$1" stage="$2"
  local d; d="$(issue_dir "$ident")"
  rm -f "$d/stage-summary-${stage}.md" 2>/dev/null || true
  rm -f "$d/wait-${stage}.json"        2>/dev/null || true
  rm -f "$d/.rendered-paths-${stage}" 2>/dev/null || true
  # ENG-119: pre-clean verdict-review.json on reviewing-stage dispatch
  # start. Per-medium primitive (CLAUDE.md ENG-87) for the new agent-owned
  # writer file. Stage-gated to reviewing because the file is review-
  # specific; clearing on implementing/qa would erase prior-iteration
  # payloads that ENG-118 / the retrospective may read during loopback.
  if [[ "$stage" == "reviewing" ]]; then
    rm -f "$d/verdict-review.json" 2>/dev/null || true
  fi
  # ENG-117: pre-clean verdict-qa.json on qa-stage dispatch start.
  # Stage-gated to qa for the same reason as ENG-119's reviewing-gated
  # clear: the file is qa-specific; clearing on other stages would erase
  # prior-iteration payloads the threshold / retrospective sub-tickets
  # may read during loopback.
  if [[ "$stage" == "qa" ]]; then
    rm -f "$d/verdict-qa.json" 2>/dev/null || true
  fi
  return 0
}

# ENG-109 C2 + ENG-160: ensure progress.md exists AND has a stable Edit
# anchor before dispatch so the agent's Edit tool (append-via-anchor) can
# always find a non-empty old_string on first dispatch of a fresh issue
# and on stages that lack Write in their allowed-tools (building, released).
#
# Pre-ENG-160 this just `touch`ed the file; on a fresh issue progress.md
# was therefore empty and Edit had no anchor to match. Combined with claude
# 2.1.x's directory sandbox (blocks `bash -c "cat >> /abs/path"` on paths
# outside cwd) and the ENG-109 Write-tool ban, the first dispatch of any
# fresh issue had no working option to append: Edit failed (empty file),
# bash cat>> failed (sandbox), Write succeeded but tripped the rc=29
# detective. Catch-22 — observed live on ENG-155 brainstorm 2026-05-19.
#
# Seeding two HTML-comment lines preserves the append-only contract,
# survives across dispatches (top of file), and gives Edit a permanent
# anchor. Idempotent on existing non-empty files via the -f guard.
_ensure_progress_md() {
  local ident="$1"
  local pmd
  pmd="$(progress_md_path "$ident")"
  [[ -f "$pmd" ]] && return 0
  if [[ "${PIPELINE_DRY_RUN:-0}" == "1" ]]; then
    log "_ensure_progress_md: dry-run — would seed $pmd"
    return 0
  fi
  {
    printf '<!-- progress.md — per-issue cross-dispatch notebook; append H2 entries below. -->\n'
    printf '<!-- See docs/runbooks/progress-md.md. Never truncate; orchestrator-owned. -->\n\n'
  } > "$pmd"
  log "_ensure_progress_md: seeded $pmd"
}

# ENG-87: post-dispatch envelope validator. Detective-only — halts only
# on egregious bypass:
#   (a) Transcript invoked mcp__plugin_linear* (Linear MCP fork outside
#       bin/linear.sh's auto-injection lane).
#   (b) Transcript invoked curl https://api.linear.app (direct Linear
#       HTTP API outside bin/linear.sh).
# Returns 0 = envelope clean, 29 = violation (caller halts).
# Skip on wait-exit and scope-approval-replay (caller gate).
_validate_dispatch_envelope() {
  local PIPELINE_WRITER=orchestrator
  export PIPELINE_WRITER
  local ident="$1" stage="$2"
  local d; d="$(issue_dir "$ident")"
  local sidecar="${d}/.envelope-transcript-${stage}"
  # When dispatch.sh's _render_and_capture_stream did not persist a
  # sidecar (dry-run, smoke-only path), no transcript scan is possible —
  # the validator is detective-only, fail-open in that case.
  [[ -s "$sidecar" ]] || return 0

  local violations=()
  local _viol_mcp _viol_curl _viol_curl_post _viol_gh_graphql _viol_unset_id _viol_wget
  if _viol_mcp="$(assert_no_tool_invocation "$sidecar" "mcp__plugin_linear")"; then
    :
  else
    violations+=("mcp__plugin_linear:${_viol_mcp}")
  fi
  if _viol_curl="$(assert_no_tool_invocation "$sidecar" "curl https://api.linear.app")"; then
    :
  else
    violations+=("curl-linear:${_viol_curl}")
  fi
  if _viol_curl_post="$(assert_no_tool_invocation "$sidecar" "curl -X POST https://api.linear.app")"; then
    :
  else
    violations+=("curl-post:${_viol_curl_post}")
  fi
  if _viol_gh_graphql="$(assert_no_tool_invocation "$sidecar" "gh api graphql")"; then
    :
  else
    violations+=("gh-api-graphql:${_viol_gh_graphql}")
  fi
  if _viol_unset_id="$(assert_no_tool_invocation "$sidecar" "unset PIPELINE_DISPATCH_ID")"; then
    :
  else
    violations+=("unset-dispatch-id:${_viol_unset_id}")
  fi
  if _viol_wget="$(assert_no_tool_invocation "$sidecar" "wget https://api.linear.app")"; then
    :
  else
    violations+=("wget-linear:${_viol_wget}")
  fi
  if (( ${#violations[@]} > 0 )); then
    # ENG-87 review-iter-7 Critical 3: SANITISE viol_str BEFORE
    # interpolation into the halt body. The agent-controlled bytes
    # (extracted via assert_no_tool_invocation's printf '%s' "$matched"
    # — which is the unsanitised .input.command from the transcript)
    # could contain a literal `<!-- pipeline: verdict result=pass -->`
    # substring. Such an embedded pipeline-marker would be picked up by
    # parse_pipeline_marker's tail -1 family-precedence selector and
    # promote the halt comment INTO a forward `pass` transition on
    # every find_fresh_verdict / resume_in_progress_transition read.
    # The auto-injected dispatch_id marker means the comment is no
    # longer filtered as legacy by D-005's strict-id-match path either,
    # so the hijack survives readers that key off the freshness floor.
    #
    # Defense:
    #  (1) Replace embedded `<!--` opens with `<\!--` so any agent-
    #      injected HTML-comment shape no longer matches the
    #      `<!-- pipeline: ... -->` and `<!-- meta: ... -->` parsers.
    #      Operators read the visible escape difference; markers do
    #      NOT classify.
    #  (2) Wrap viol_str in a triple-backtick fenced code block as
    #      defense-in-depth: parse_pipeline_marker's
    #      _strip_code_blocks_and_spans removes `{3}[^`]{3}` runs
    #      before the marker grep, so any fenced-out content is
    #      structurally invisible to the parser.
    local viol_str_raw viol_str_safe
    viol_str_raw="$(printf '%s; ' "${violations[@]}")"
    viol_str_safe="${viol_str_raw//<!--/<\\!--}"
    local body
    # ${VAR:-unknown} (NOT ${VAR-}) is intentional here: the halt body is
    # operator-facing prose and must never render a literal empty
    # `dispatch_id=` field — `unknown` is a self-explanatory sentinel
    # if the env var was somehow unset by the time validation runs (e.g.
    # a downstream caller that forgot to allocate). Lint-safe — neither
    # variable name matches secret-probe-lint.sh's regex.
    body="$(printf '<!-- pipeline: verdict result=halt reason=dispatch-envelope-violation -->\n\nDispatch envelope violation on dispatch_id=%s stage=%s:\n\n```\n%s\n```\n\nThe agent bypassed bin/linear.sh (auto-injection chokepoint). Inspect: %s\n\n**Resume:** investigate the bypass, fix the agent prompt or tool-allowlist, then run `bash bin/pipeline.sh decide %s --action continue`.' \
      "${PIPELINE_DISPATCH_ID:-unknown}" "$stage" "$viol_str_safe" "$sidecar" "$ident")"
    bash "$SCRIPT_DIR/linear.sh" add-comment "$ident" "$body" || true
    return 29
  fi
  return 0
}

# ENG-156 D-001 (Phase A) + D-004 (Phase B): post-dispatch sandbox-denial
# detective. Scans .envelope-transcript-<stage>.ndjson for
# `tool_result.is_error:true` rows matching a 2-entry signature table.
# Phase A: always log-only — one events.jsonl row per dispatch when
# denial count > 0. Phase B: when orchestrator.sandbox_contract_halt is
# true AND a denied path matches a path resolved by PROMPT_RESOLVERS
# (read from .rendered-paths-<stage>), promotes to rc=29 halt with
# reason=sandbox-contract-violation. Mirror of _validate_dispatch_envelope
# at a different axis (tool_result vs tool_use). Sidecar fail-open: missing
# or empty file returns 0 silently (matches the envelope-validator's
# `[[ -s "$sidecar" ]] || return 0` shape).
_emit_sandbox_denial_metric() {
  local PIPELINE_WRITER=orchestrator
  export PIPELINE_WRITER
  local ident="$1" stage="$2"
  local d; d="$(issue_dir "$ident")"
  local sidecar="${d}/.envelope-transcript-${stage}"
  [[ -s "$sidecar" ]] || return 0

  # Walk the transcript twice via a single jq invocation:
  #  Pass 1: build tool_use_id → (file_path // command-trailing-token) map.
  #  Pass 2: for each user.tool_result with is_error==true, classify
  #    content via the 2-entry signature table; emit one TSV row per
  #    denial: <signature>\t<path>.
  # Substring match (no regex compilation inside --arg-bound jq strings —
  # awkward to test). Aggregation to count + comma-separated signatures
  # + comma-separated paths happens in shell post-jq for clarity.
  local denials_tsv
  denials_tsv="$(jq -Rrn '
    [inputs | (fromjson? // empty)] as $events
    | ($events
      | map(select(.type == "assistant")
            | .message.content[]?
            | select(.type == "tool_use")
            | {key: .id, value: (.input.file_path // (.input.command // "" | split(" ") | last // ""))})
      | from_entries) as $tu_map
    | $events[]
    | select(.type == "user")
    | .message.content[]?
    | select(.type == "tool_result" and (.is_error == true))
    | (.content // "" | if type == "array" then map(.text // "") | join(" ") else tostring end) as $body
    | (if ($body | contains("may only list files in the allowed working directories")) then "sandbox-path"
       elif ($body | contains("This command requires approval")) then "bash-classifier"
       else "" end) as $sig
    | select($sig != "")
    | ($tu_map[.tool_use_id] // "") as $p
    | "\($sig)\t\($p)"
  ' "$sidecar" 2>/dev/null)" || denials_tsv=""

  [[ -n "$denials_tsv" ]] || return 0
  local count signatures paths
  count="$(printf '%s\n' "$denials_tsv" | wc -l | awk '{print $1}')"
  signatures="$(printf '%s\n' "$denials_tsv" | awk -F'\t' '{print $1}' | sort -u | paste -sd, -)"
  paths="$(printf '%s\n' "$denials_tsv" | awk -F'\t' '$2 != "" {print $2}' | sort -u | paste -sd, -)"

  # Extract only the version token (first whitespace-delimited field).
  # `claude --version` emits e.g. `1.0.93 (Claude Code)` with an embedded
  # space + parenthesised suffix; without `awk '{print $1}'` the embedded
  # space would split the metric notes' space-delimited fields and
  # `show_sandbox_denials`'s `capture("claude_version=(?<v>\\S+)")` selector
  # would silently truncate, leaking `(Claude` into the next pseudo-field.
  local claude_version
  claude_version="$(claude --version 2>/dev/null | head -1 | awk '{print $1}' || true)"
  [[ -n "$claude_version" ]] || claude_version="unknown"

  # Phase B: read .rendered-paths-<stage> (if present) and check whether
  # any denied path contains a resolved path-string. Gated on the
  # orchestrator.sandbox_contract_halt config flag (default false).
  local phase_b_enabled=0
  if [[ -f "$CONFIG" ]]; then
    local _cfg
    _cfg="$(jq -r '.orchestrator.sandbox_contract_halt // false' "$CONFIG" 2>/dev/null || true)"
    [[ "$_cfg" == "true" ]] && phase_b_enabled=1
  fi

  local outcome="detected"
  local matched_token="" matched_path=""
  local rp="${d}/.rendered-paths-${stage}"
  if (( phase_b_enabled )) && [[ -s "$rp" ]] && [[ -n "$paths" ]]; then
    # paths is a comma-separated set; iterate denied paths against
    # each resolved-path line. First match wins.
    local _dp _tok _val
    while IFS=, read -ra _denied; do
      for _dp in "${_denied[@]}"; do
        [[ -n "$_dp" ]] || continue
        while IFS=$'\t' read -r _tok _val; do
          [[ -n "$_val" ]] || continue
          if [[ "$_dp" == *"$_val"* ]]; then
            matched_token="$_tok"
            matched_path="$_dp"
            break 3
          fi
        done < "$rp"
      done
    done <<< "$paths"
  fi

  if [[ -n "$matched_token" ]]; then
    outcome="contract-violation"
  fi

  # Always emit the metric row (Phase A behavior preserved even when
  # Phase B fires — operator gets both the halt comment and the
  # events.jsonl row for retrospective consumption).
  bash "$SCRIPT_DIR/metrics.sh" sandbox_denial "$ident" "$stage" "$outcome" 0 \
    "count=$count signatures=$signatures paths=$paths claude_version=$claude_version" \
    || log "[sandbox-denial] metric emit failed for $ident/$stage"

  if [[ -n "$matched_token" ]]; then
    # Phase B halt path. Sidecar carries the unsanitised matched_path
    # (operator-read only; never parsed by parse_pipeline_marker).
    # Linear comment body uses ONLY $matched_token (closed enumeration
    # from PROMPT_RESOLVERS path-shaped allowlist) and orchestrator-
    # generated $ident / $PIPELINE_DISPATCH_ID. Matches ENG-87
    # review-iter-7 Critical 3 / ENG-155 D-004 sanitisation precedent.
    printf 'sandbox-contract-violation: token=%s path=%s\n' \
      "$matched_token" "$matched_path" \
      > "${d}/.transcript-violation-${stage}"
    local body
    body="$(printf '<!-- pipeline: verdict result=halt reason=sandbox-contract-violation -->\n\nSandbox blocked agent write to a harness-contract path on dispatch_id=%s stage=%s.\n\nResolver token: `%s`\n\nThe orchestrator rendered this resolver value into the agent prompt and the sandbox denied the agent'\''s tool call against it. Inspect `%s/.transcript-violation-%s` for the denied path; expected fix is the project profile / `--add-dir` / tool-allowlist (NOT the agent prompt).\n\n**Resume:** fix the contract drift, then run `bash bin/pipeline.sh decide %s --action continue`.' \
      "${PIPELINE_DISPATCH_ID:-unknown}" "$stage" "$matched_token" "$d" "$stage" "$ident")"
    bash "$SCRIPT_DIR/linear.sh" add-comment "$ident" "$body" || true
    return 29
  fi
  return 0
}

# ENG-122: plan-contract validator. Runs after dispatch for stage=planning only.
# Locates the sibling .json alongside the prose .md in docs/plans/, then shells
# out to bin/plan-schema.sh validate. Returns 0 = valid, 33 = malformed,
# 34 = incomplete, 35 = missing-file. Caller must gate to stage=planning.
_validate_plan_contract() {
  local ident="$1"
  local wt
  wt="$(issue_dir "$ident")/worktree"
  # Fail-open if worktree is absent: caller's earlier preconditions handle it.
  [[ -d "$wt" ]] || { log "plan-contract: no worktree dir for $ident; fail-open"; return 0; }
  local ident_lower
  ident_lower="$(printf '%s' "$ident" | tr '[:upper:]' '[:lower:]')"
  local today
  today="$(date +%Y-%m-%d)"
  local plan_md plan_json schema_out schema_rc=0

  # ENG-179: gate planning→implementing on a HEAD-COMMITTED plan artifact.
  # Worktree `find` (pre-ENG-179) saw dirty-but-uncommitted files; that
  # let a session-limit death post verdict=pass + write files into the
  # worktree but die before commit, and the transition would still fire
  # because the orchestrator's partition-sweep runs AFTER verdict_handler.
  # `git ls-tree -r HEAD` returns only committed paths, matching the
  # issue's acceptance criterion ("present in the branch's commits, not
  # just the dirty worktree"). Agent self-commit (AGENT_PROMPTS.md §2
  # step 4) is now LOAD-BEARING for this gate's correctness; if that
  # contract is ever softened, this gate must be reordered behind the
  # partition-sweep commit (a structural change, not a softening here).
  #
  # Trailing hyphen after ident_lower preserves the existing eng-12 vs
  # eng-122 boundary guard. The today-only date prefix was DROPPED
  # (vs pre-ENG-179) so a cross-midnight planning re-dispatch on
  # yesterday's committed plan still satisfies the gate; the schema
  # validator's `issue_id` field check (^ENG-[0-9]+$ matched against
  # --ident) re-asserts the artifact belongs to this ident, so the
  # looser filename pattern cannot let a foreign plan satisfy the gate.
  plan_md="$(cd "$wt" && git ls-tree --name-only -r HEAD -- docs/plans/ 2>/dev/null \
    | grep -iE "^docs/plans/[0-9]{4}-[0-9]{2}-[0-9]{2}-.*${ident_lower}-.*\.md$" \
    | sort | tail -1)"
  if [[ -z "$plan_md" ]]; then
    _post_plan_contract_halt "$ident" "plan-contract-missing" \
      "$(printf 'No committed plan artifact at docs/plans/<date>-*-%s-*.md in branch HEAD. The planning agent emitted verdict=pass but did not commit the canonical plan .md (and sibling .json).\n\nCommon cause: claude -p session-limit / out_of_credits death after marker emission but before file commit (operator memory: session-limit-false-halts). Inspect the dispatch log at $PROJECT_STATE_DIR/<slug>/logs/%s-planning-*.log to confirm before re-running.\n\nResume: bash bin/pipeline.sh decide %s --action continue' "$ident_lower" "$ident" "$ident")"
    return 35
  fi

  plan_json="${plan_md%.md}.json"

  # ENG-179: also gate the sibling .json on HEAD. plan-schema.sh's
  # rc=35 (missing-file) reads the worktree filesystem and would accept
  # a written-but-uncommitted .json; querying HEAD here closes that
  # gap with the same shape used for the .md above.
  if ! (cd "$wt" && git ls-tree --name-only -r HEAD -- "$plan_json" 2>/dev/null | grep -qxF "$plan_json"); then
    _post_plan_contract_halt "$ident" "plan-contract-missing" \
      "$(printf 'Sibling plan JSON not committed to HEAD at %s. The .md is in HEAD but the .json is not — schema validation cannot proceed.\n\nResume: bash bin/pipeline.sh decide %s --action continue' "$plan_json" "$ident")"
    return 35
  fi

  schema_out="$(bash "$SCRIPT_DIR/plan-schema.sh" validate "$wt/$plan_json" \
    --ident "$ident")" || schema_rc=$?
  case "$schema_rc" in
    0)  return 0 ;;
    33) _post_plan_contract_halt "$ident" "plan-contract-malformed"  "$schema_out" ; return 33 ;;
    34) _post_plan_contract_halt "$ident" "plan-contract-incomplete" "$schema_out" ; return 34 ;;
    35) _post_plan_contract_halt "$ident" "plan-contract-missing"    "$schema_out" ; return 35 ;;
    *)  _post_plan_contract_halt "$ident" "unexpected-rc" \
          "validator returned unexpected rc=$schema_rc; stdout: $schema_out" ; return 33 ;;
  esac
}

# Posts a halt comment for a plan-contract violation. Mirrors _validate_dispatch_envelope's
# sanitisation pattern (D-004): replace `<!--` with `<\!--` in agent-controlled text
# before embedding in the Linear comment body to prevent marker hijacking.
_post_plan_contract_halt() {
  local ident="$1" defect="$2" raw="$3"
  local safe="${raw//<!--/<\\!--}"
  local body
  body="$(printf '<!-- pipeline: verdict result=halt reason=plan-contract-invalid -->\n\nPlan-contract validation failed on dispatch_id=%s stage=planning:\n\n- Defect: %s\n\n~~~\n%s\n~~~\n\nSchema source-of-truth: see header comment in `bin/plan-schema.sh`.\n\n**Resume:** fix the JSON (or the plan prompt'\''s emission step), commit on the feature branch, then run `bash bin/pipeline.sh decide %s --action continue`.' \
    "${PIPELINE_DISPATCH_ID:-unknown}" "$defect" "$safe" "$ident")"
  bash "$SCRIPT_DIR/linear.sh" add-comment "$ident" "$body" || true
}

# ENG-119: review-payload validator. Filesystem detective — checks that
# the review agent wrote a well-formed $issue_dir/verdict-review.json
# with current dispatch_id. Returns 0=valid, 36=malformed, 37=incomplete,
# 38=missing-file (caller halts).
_validate_review_payload() {
  local ident="$1"
  local payload; payload="$(issue_dir "$ident")/verdict-review.json"
  if [[ ! -f "$payload" ]]; then
    _post_review_payload_halt "$ident" "review-payload-missing" \
      "no verdict-review.json at $payload"
    return 38
  fi
  local out rc=0
  out="$(bash "$SCRIPT_DIR/review-payload-schema.sh" validate "$payload" \
         --ident "$ident" --dispatch-id "${PIPELINE_DISPATCH_ID-}" 2>&1)" || rc=$?
  case "$rc" in
    0)  return 0 ;;
    36) _post_review_payload_halt "$ident" "review-payload-malformed"  "$out" ; return 36 ;;
    37) _post_review_payload_halt "$ident" "review-payload-incomplete" "$out" ; return 37 ;;
    38) _post_review_payload_halt "$ident" "review-payload-missing"    "$out" ; return 38 ;;
    *)  _post_review_payload_halt "$ident" "unexpected-rc" \
          "validator returned unexpected rc=$rc; stdout: $out" ; return 36 ;;
  esac
}

# Posts a halt comment for a review-payload violation. Mirrors
# _post_plan_contract_halt sanitisation: <!-- → <\!-- + tilde-fence wrap
# so agent-controlled diagnostic strings can't hijack the marker parser.
# Per product persona P1-1 / P1-2: includes the absolute payload path
# (so the operator can cat it at 3am without resolving issue_dir) AND
# explicitly warns that --action continue erases hand-edits via
# pre-clean (brainstorm Edge case 2).
_post_review_payload_halt() {
  local ident="$1" defect="$2" raw="$3"
  local safe="${raw//<!--/<\\!--}"
  local payload; payload="$(issue_dir "$ident")/verdict-review.json"
  local body
  body="$(printf '<!-- pipeline: verdict result=halt reason=review-payload-invalid -->\n\nReview-payload validation failed on dispatch_id=%s stage=reviewing:\n\n- Defect: %s\n- Payload: %s\n\n~~~\n%s\n~~~\n\nSchema source-of-truth: see header comment in `bin/review-payload-schema.sh`.\n\n**Resume options:**\n- Re-dispatch (preferred): `bash bin/pipeline.sh decide %s --action continue`. **WARNING:** this pre-cleans the payload file. Any hand-edit you make first will be erased.\n- Manual repair: hand-edit `%s` to a valid payload, then emit a verdict marker yourself with `bash bin/pipeline.sh event %s verdict pass --stage reviewing`. See `docs/runbooks/recovery.md` §11.' \
    "${PIPELINE_DISPATCH_ID:-unknown}" "$defect" "$payload" "$safe" "$ident" "$payload" "$ident")"
  bash "$SCRIPT_DIR/linear.sh" add-comment "$ident" "$body" || true
}

# ENG-117: qa-payload validator. Filesystem detective — checks that the qa
# agent wrote a well-formed $issue_dir/verdict-qa.json with current
# dispatch_id. Returns 0=valid, 39=malformed, 40=incomplete,
# 41=missing-file (caller halts).
_validate_qa_payload() {
  local ident="$1"
  local payload; payload="$(issue_dir "$ident")/verdict-qa.json"
  if [[ ! -f "$payload" ]]; then
    _post_qa_payload_halt "$ident" "qa-payload-missing" \
      "no verdict-qa.json at $payload"
    return 41
  fi
  local out rc=0
  out="$(bash "$SCRIPT_DIR/qa-payload-schema.sh" validate "$payload" \
         --ident "$ident" --dispatch-id "${PIPELINE_DISPATCH_ID-}" 2>&1)" || rc=$?
  case "$rc" in
    0)  return 0 ;;
    39) _post_qa_payload_halt "$ident" "qa-payload-malformed"  "$out" ; return 39 ;;
    40) _post_qa_payload_halt "$ident" "qa-payload-incomplete" "$out" ; return 40 ;;
    41) _post_qa_payload_halt "$ident" "qa-payload-missing"    "$out" ; return 41 ;;
    *)  _post_qa_payload_halt "$ident" "unexpected-rc" \
          "validator returned unexpected rc=$rc; stdout: $out" ; return 39 ;;
  esac
}

# Posts a halt comment for a qa-payload violation. Mirrors
# _post_review_payload_halt sanitisation: <!-- → <\!-- + tilde-fence wrap
# so agent-controlled diagnostic strings can't hijack the marker parser.
_post_qa_payload_halt() {
  local ident="$1" defect="$2" raw="$3"
  local safe="${raw//<!--/<\\!--}"
  local payload; payload="$(issue_dir "$ident")/verdict-qa.json"
  local body
  body="$(printf '<!-- pipeline: verdict result=halt reason=qa-payload-invalid -->\n\nQA-payload validation failed on dispatch_id=%s stage=qa:\n\n- Defect: %s\n- Payload: %s\n\n~~~\n%s\n~~~\n\nSchema source-of-truth: see header comment in `bin/qa-payload-schema.sh`.\n\n**Resume options:**\n- Re-dispatch (preferred): `bash bin/pipeline.sh decide %s --action continue`. **WARNING:** this pre-cleans the payload file. Any hand-edit you make first will be erased.\n- Manual repair: hand-edit `%s` to a valid payload, then emit a verdict marker yourself with `bash bin/pipeline.sh event %s verdict pass --stage qa`. See `docs/runbooks/recovery.md` §11.' \
    "${PIPELINE_DISPATCH_ID:-unknown}" "$defect" "$payload" "$safe" "$ident" "$payload" "$ident")"
  bash "$SCRIPT_DIR/linear.sh" add-comment "$ident" "$body" || true
}

# ENG-87 review M1+M2: dispatch_history.jsonl end-row trap. Plan §13.1.2
# + §A-026 mandate two rows per dispatch (start + end). Pre-fix the end
# row was only emitted on the success path (1 of 15 exit sites) and was
# missing 3 of the 9 documented schema fields (policy, verdict_emitted,
# verdict_target). EXIT trap centralises the emission so every early-
# exit path appends the row exactly once.
#
# Globals owned by main() that the trap reads. Empty defaults so the
# trap is a no-op until main() initialises them after the start-row.
# ENG-87 review-iter-7 M2: _END_ROW_TRANSCRIPT_CLEAN is removed (was
# a redundant module-level global; the writer now derives the field
# from the trap's exit_code arg, so the validator's rc=29 path no
# longer needs to mutate cross-function state). M3: _END_ROW_VERDICT_*
# initial values are seeded once per dispatch in main(); the writer
# below reads find_fresh_verdict + find_fresh_wait_verdict at end-row
# time so classify-failure.sh and verdict-handler.sh no longer need
# to reach in and mutate them.
_END_ROW_HIST_FILE=""
_END_ROW_DISPATCH_ID=""
_END_ROW_STAGE=""
_END_ROW_T0=""
_END_ROW_ISSUE=""
_END_ROW_VERDICT_EMITTED=""
_END_ROW_VERDICT_TARGET=""
_END_ROW_POLICY=""

_append_dispatch_end_row() {
  local exit_code="${1:-0}"
  # Sentinel: empty HIST_FILE → trap fires before main() initialised the
  # globals (precondition / guard early-exit) OR after a prior successful
  # append (idempotency). No-op in both cases.
  [[ -n "$_END_ROW_HIST_FILE" ]] || return 0
  [[ -n "$_END_ROW_DISPATCH_ID" ]] || return 0
  local exit_at; exit_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local now duration
  now="$(date +%s)"
  duration=$(( (now - _END_ROW_T0) * 1000 ))
  local _summary_path="$(issue_dir "$_END_ROW_ISSUE")/stage-summary-${_END_ROW_STAGE}.md"
  local _summary_present
  _summary_present="$([[ -s "$_summary_path" ]] && printf 'true' || printf 'false')"

  # ENG-87 review-iter-7 M2: derive transcript_clean from exit_code
  # rather than from a cross-function module-level global. exit_code 29
  # is `envelope-violation` per failure_outcome_for_exit (common.sh) —
  # any other rc means the validator either passed cleanly or never
  # ran. Single-purpose computation; no cross-script mutation.
  local _transcript_clean
  if [[ "$exit_code" == "29" ]]; then
    _transcript_clean=false
  else
    _transcript_clean=true
  fi

  # ENG-87 review-iter-7 M3: read verdict_emitted + verdict_target
  # from Linear at end-row time. Pre-iter-7 these were seeded at 5+
  # explicit sites across run-stage.sh (scope-violation halt, wait-
  # success, budget-exhausted halt, success-path read), classify-
  # failure.sh (halt-policy arms), and verdict-handler.sh (protocol-
  # violation halt). Each new halt path was a silent gap unless the
  # developer remembered to seed. Plan §13.1.2 says verdict_emitted
  # reflects "what the agent posted to Linear"; Linear is the source
  # of truth. Try find_fresh_verdict (pass/fail/halt) first; if the
  # latest verdict on the issue is a wait, fall back to
  # find_fresh_wait_verdict (which find_fresh_verdict explicitly
  # excludes). Two Linear queries per dispatch end is acceptable cost
  # against the simplification — and the success-path consolidation
  # at line ~1437 already paid the same query cost in the pre-iter-7
  # shape.
  if [[ -z "$_END_ROW_VERDICT_EMITTED" ]] && [[ -n "$_END_ROW_ISSUE" ]]; then
    local _fresh_v
    _fresh_v="$(find_fresh_verdict "$_END_ROW_ISSUE" 2>/dev/null || printf '')"
    if [[ -n "$_fresh_v" ]]; then
      _END_ROW_VERDICT_EMITTED="$(jq -r '.event.result // ""' <<<"$_fresh_v" 2>/dev/null || printf '')"
      _END_ROW_VERDICT_TARGET="$(jq -r '.event.target // .event.stage // ""' <<<"$_fresh_v" 2>/dev/null || printf '')"
    else
      local _fresh_wv
      _fresh_wv="$(find_fresh_wait_verdict "$_END_ROW_ISSUE" 2>/dev/null || printf '')"
      if [[ -n "$_fresh_wv" ]]; then
        _END_ROW_VERDICT_EMITTED="wait"
      fi
    fi
  fi

  # ENG-87 review-iter-7 M1: derive policy from issue-state.json. The
  # file is classify-failure.sh's durable artifact (poll.sh reads
  # .policy on every tick to decide skip-policy), and _cf_write_state
  # populated it microseconds before classify-failure returned. Reading
  # here at end-row time eliminates the last cross-file _END_ROW_*
  # mutation. Empty default when the file is absent (success path
  # never invokes classify-failure) or when jq cannot parse it.
  if [[ -z "$_END_ROW_POLICY" ]] && [[ -n "$_END_ROW_ISSUE" ]]; then
    local _state_file
    _state_file="$(issue_dir "$_END_ROW_ISSUE")/issue-state.json"
    if [[ -s "$_state_file" ]]; then
      _END_ROW_POLICY="$(jq -r '.policy // ""' "$_state_file" 2>/dev/null || printf '')"
    fi
  fi

  # ENG-87 review-iter-3 M1: envelope schema completeness. Plan §13.1.2
  # mandates 3 sub-fields — stage_summary_present, comments_stamped,
  # transcript_clean. comments_stamped ships as `[]` baseline (forensic-
  # only writer with no runtime consumer; ENG-92 deferred populates it).
  jq -nc \
    --arg dispatch_id "$_END_ROW_DISPATCH_ID" \
    --arg stage "$_END_ROW_STAGE" \
    --arg exit_at "$exit_at" \
    --argjson exit_code "${exit_code:-0}" \
    --arg policy "$_END_ROW_POLICY" \
    --arg verdict_emitted "$_END_ROW_VERDICT_EMITTED" \
    --arg verdict_target "$_END_ROW_VERDICT_TARGET" \
    --argjson duration_ms "$duration" \
    --argjson stage_summary_present "$_summary_present" \
    --argjson transcript_clean "$_transcript_clean" \
    --argjson comments_stamped '[]' '
    {
      dispatch_id: $dispatch_id, stage: $stage, exit_at: $exit_at,
      exit_code: $exit_code, policy: $policy,
      verdict_emitted: $verdict_emitted, verdict_target: $verdict_target,
      duration_ms: $duration_ms,
      envelope: {
        stage_summary_present: $stage_summary_present,
        comments_stamped:      $comments_stamped,
        transcript_clean:      $transcript_clean
      }
    }' >> "$_END_ROW_HIST_FILE" \
    || log "warning: dispatch_history.jsonl write failed for $_END_ROW_DISPATCH_ID"
  # Idempotency: clear the sentinel so a nested `set -e` exit does not
  # double-append the same row.
  _END_ROW_HIST_FILE=""
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

  # Guards (threshold-based human gates). ENG-138: pass the dispatched
  # stage so guards.sh::check can scope the review_rejection threshold
  # trip to stage == implementing (the loopback continuation edge).
  if ! bash "$SCRIPT_DIR/guards.sh" check "$ident" "$stage" 2>/dev/null; then
    local tripped
    tripped="$(bash "$SCRIPT_DIR/guards.sh" check "$ident" "$stage" 2>&1 || true)"
    classify_failure "$ident" "$stage" "skip-until-human-acts" \
      "guards tripped: $tripped" 10
    exit 10
  fi

  # Reconcile is now performed in run-local.sh before this script is called,
  # so that link:/human decisions don't create empty worktrees. See ENG-13 D-009.

  # Scope-approval replay: if this is implement/ui and the user has posted
  # a `<!-- pipeline: decision action=approve gate=scope -->` comment newer
  # than the most recent `<!-- pipeline: verdict result=halt reason=scope-violation -->`
  # marker, skip the agent dispatch and fall through to the post-stage guards.
  # The branch is already green from the prior dispatch; re-running the agent
  # would just burn tokens. The post-stage scope-check will observe the same
  # decision marker and treat the notable tier as approved.
  local skip_dispatch=0
  if [[ "$stage" == "implementing" || "$stage" == "ui" ]]; then
    local _approval_state="$(issue_dir "$ident")/scope-approval"
    if [[ -f "$_approval_state" ]] \
       && bash "$SCRIPT_DIR/scope-check.sh" has-scope-approval "$ident" 2>/dev/null; then
      log "scope-approval: decision marker posted; skipping agent dispatch for $stage replay"
      skip_dispatch=1
    fi
  fi

  # ENG-62: pre-dispatch merge-detection gate. If the PR for stage=building
  # is already MERGED (e.g., a prior dispatch fired `gh pr merge --auto`
  # successfully), there is nothing left for the build agent to do —
  # dispatching costs ≈ $1.50 and risks an awaiting-approval emission from
  # a prompt-following regression. Apply the transition directly and exit.
  if _pre_dispatch_merge_gate "$ident" "$stage"; then
    t1="$(date +%s)"; duration=$(( (t1 - t0) * 1000 ))
    # ENG-10 D-004: pair every stage-end with a stage-start so retrospective
    # §1's stage-pairing pass doesn't see an orphaned terminal event. Mirrors
    # the precondition-failure path above (lines ~574-580) and every other
    # early-exit in this file. The gate-fires path was the one early-exit
    # that didn't pair them (ENG-62 review finding).
    bash "$SCRIPT_DIR/metrics.sh" stage-start "$ident" "$stage" \
      "merged-pre-dispatch" 0 || true
    bash "$SCRIPT_DIR/metrics.sh" stage-end "$ident" "$stage" \
      "merged-pre-dispatch" "$duration" || true
    exit 0
  fi

  # ENG-86: orchestrator-side entry-condition gate. If the configured
  # check(s) for this stage are unmet, skip the agent dispatch entirely
  # (~100ms vs ~2 min full dispatch). The gate bumps the ENG-45 wait
  # counter via _handle_wait so external_signal_budget still escalates a
  # stale predicate. The `if !` inversion is intentional: the helper
  # returns 0 (proceed) on the pass-through path; we negate to enter the
  # exit-block only on `return 1` (gate fired skip).
  if ! _entry_conditions_gate "$ident" "$stage"; then
    t1="$(date +%s)"; duration=$(( (t1 - t0) * 1000 ))
    bash "$SCRIPT_DIR/metrics.sh" stage-start "$ident" "$stage" \
      "dispatch-skipped" 0 || true
    bash "$SCRIPT_DIR/metrics.sh" stage-end "$ident" "$stage" \
      "dispatch-skipped" "$duration" || true
    exit 0
  fi

  # Guarantee the per-issue state dir exists before dispatch so an agent's first
  # Write of stage-summary-<stage>.md cannot fail on missing parents.
  mkdir -p "$(issue_dir "$ident")"
  # ENG-109 C2: ensure progress.md exists before dispatch so the agent's Edit
  # tool (append-via-anchor path) succeeds on first dispatch on a fresh issue.
  _ensure_progress_md "$ident"

  # ENG-87: allocate dispatch_id (per-issue monotonic counter) and clear
  # current-stage local files. Skip on scope-approval replay (the prior
  # dispatch's id is still durable in issue-state.json and its envelope
  # was already validated). Stamps PIPELINE_DISPATCH_ID + PIPELINE_STAGE
  # into the env so dispatch.sh's `env` block carries them into the
  # agent subshell, where bin/linear.sh's auto-injection picks them up
  # for the per-comment dispatch marker.
  if (( ! skip_dispatch )); then
    export PIPELINE_STAGE="$stage"
    local _dispatch_id
    _dispatch_id="$(allocate_dispatch_id "$ident")"
    # allocate_dispatch_id's `export PIPELINE_DISPATCH_ID` (common.sh:155)
    # fires inside this $(...) subshell and is lost on its exit. Re-export
    # in the parent so dispatch.sh inherits it (consumed by dispatch.sh's
    # env block, render-prompt.sh's {dispatch_id} resolver, bin/linear.sh's
    # auto-marker injection, and the ENG-106 plan-stage detective).
    export PIPELINE_DISPATCH_ID="$_dispatch_id"
    log "dispatch-id allocated: $_dispatch_id (stage=$stage)"
    _clear_current_stage_slots "$ident" "$stage"
    # Append dispatch-start row to history (orchestrator-only forensic
    # log; never read at runtime by decision-making code).
    local _hist_file _trigger _predecessor _branch _hash
    _hist_file="$(issue_dir "$ident")/dispatch_history.jsonl"
    _branch="$(bash "$SCRIPT_DIR/branch-name.sh" "$ident" 2>/dev/null || printf '')"
    _hash="$(compute_pipeline_content_hash 2>/dev/null || printf '')"
    # predecessor = the prior id; empty if this is d0001.
    if [[ "$_dispatch_id" =~ -d0*([1-9][0-9]*)$ ]]; then
      local _seq="${BASH_REMATCH[1]}"
      if (( _seq > 1 )); then
        _predecessor="$(printf '%s-d%04d' "$ident" "$((_seq - 1))")"
      else
        _predecessor=""
      fi
    else
      _predecessor=""
    fi
    # Trigger inferred from labels; conservative default = "transition".
    # Refining (loopback vs inbox-pickup vs retry-immediately) is forensic
    # only and is left to a future ticket per brainstorm §12.
    _trigger="transition"
    # ENG-87 review-iter-2 m1: jq -nc --arg for symmetry with the
    # end-row writer at line ~824 and to keep the row safe under any
    # future field carrying embedded `"` / newline. printf '%s' was a
    # holdover from when the schema was strictly ASCII-safe.
    jq -nc \
      --arg dispatch_id "$_dispatch_id" \
      --arg stage "$stage" \
      --arg started_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg trigger "$_trigger" \
      --arg predecessor_dispatch_id "$_predecessor" \
      --arg branch "$_branch" \
      --arg pipeline_content_hash "$_hash" '
      {
        dispatch_id: $dispatch_id,
        stage: $stage,
        started_at: $started_at,
        trigger: $trigger,
        predecessor_dispatch_id: $predecessor_dispatch_id,
        branch: $branch,
        pipeline_content_hash: $pipeline_content_hash
      }' >> "$_hist_file"

    # ENG-87 review M1+M2: install the EXIT trap that appends the end
    # row at every exit site. Globals seeded here; classify_failure /
    # verdict_handler call sites refine POLICY / VERDICT_* below before
    # the trap fires.
    _END_ROW_HIST_FILE="$_hist_file"
    _END_ROW_DISPATCH_ID="$_dispatch_id"
    _END_ROW_STAGE="$stage"
    # ENG-87 review-iter-3 m2: capture _END_ROW_T0 at the start-row
    # write site, NOT at the top of main(). `t0` was set before
    # verify_preconditions, scope-approval check, _pre_dispatch_merge_gate,
    # and _entry_conditions_gate — so duration_ms used to include
    # pre-dispatch gating that has nothing to do with the agent's run,
    # breaking the started_at + duration_ms ≈ exit_at invariant the
    # plan §13.1.2 schema implies. `date +%s` here aligns with the
    # `started_at` jq arg above (within ~milliseconds).
    _END_ROW_T0="$(date +%s)"
    _END_ROW_ISSUE="$ident"
    _END_ROW_VERDICT_EMITTED=""
    _END_ROW_VERDICT_TARGET=""
    _END_ROW_POLICY=""
    # ENG-87 review-iter-7 M2: _END_ROW_TRANSCRIPT_CLEAN global is
    # gone — _append_dispatch_end_row now derives transcript_clean
    # from the trap's exit_code arg (29 = false; anything else = true).
    trap '_append_dispatch_end_row $?' EXIT
  fi

  # ENG-105 follow-up: capture worktree HEAD before dispatch so the
  # post-dispatch noop detector (further below) can recognise a
  # zero-commit implementing dispatch. Gated on stage=implementing
  # because ui/brainstorm/plan/review have no commit expectation
  # (ui is a documented no-op on harness-self; brainstorm/plan/review
  # write docs/comments but not commits the noop detector would fire on).
  # Empty value when worktree isn't a git dir is fine — the detector's
  # `[[ -n "$_HEAD_PRE_DISPATCH" ]]` guard fails open.
  local _HEAD_PRE_DISPATCH=""
  if [[ "$stage" == "implementing" ]] && (( ! skip_dispatch )); then
    _HEAD_PRE_DISPATCH="$(git -C "$(issue_dir "$ident")/worktree" rev-parse HEAD 2>/dev/null || printf '')"
  fi

  # Render the prompt.
  local prompt_file log_file
  if (( ! skip_dispatch )); then
    prompt_file="$(mktemp -t pipeline-prompt-XXXXXX)"
    log_file="$PROJECT_STATE_DIR/logs/${ident}-${stage}-$(date -u +%Y%m%dT%H%M%SZ).log"
    mkdir -p "$(dirname "$log_file")"
    # ENG-139 follow-up: resolve the loopback shape (which from-stage
    # routed us here) and hand off via PIPELINE_LOOPBACK_SOURCE so
    # render-prompt.sh's _resolve_review_findings can gate stale
    # review findings out of build → implementing rebase loopbacks and
    # qa → implementing fail loopbacks. Only meaningful for the
    # implementing stage today; other stages don't read review_findings.
    local loopback_source=""
    if [[ "$stage" == "implementing" ]]; then
      loopback_source="$(_resolve_loopback_source "$ident" "$stage" 2>/dev/null || printf '')"
      [[ -n "$loopback_source" ]] && log "loopback source=$loopback_source (stage=$stage)"
    fi
    PIPELINE_LOOPBACK_SOURCE="$loopback_source" \
      bash "$SCRIPT_DIR/render-prompt.sh" "$stage" "$ident" > "$prompt_file"
    log "rendered prompt: $prompt_file ($(wc -l < "$prompt_file") lines)"

    bash "$SCRIPT_DIR/metrics.sh" stage-start "$ident" "$stage" "dispatching" 0

    # Dispatch. Export PIPELINE_ISSUE_ID so dispatch.sh can resolve the
    # per-stage usage-file path (ENG-26 D-012). Ambient-context env var
    # mirrors the existing PIPELINE_DRY_RUN pattern (common.sh:171).
    # ENG-103: resolve per-stage model and hand off via PIPELINE_DISPATCH_MODEL.
    # Empty string propagates unchanged; dispatch.sh's `[[ -n ... ]]` test
    # elides the --model flag in that case (preserving subscription default).
    local dispatch_rc=0
    local resolved_model
    resolved_model="$(_resolve_dispatch_model "$stage" "$ident" 2>/dev/null || printf '')"
    if [[ -n "$resolved_model" ]]; then
      log "dispatch model=$resolved_model (stage=$stage)"
    fi
    PIPELINE_ISSUE_ID="$ident" \
      PIPELINE_DISPATCH_MODEL="$resolved_model" \
      bash "$SCRIPT_DIR/dispatch.sh" "$stage" "$prompt_file" "$log_file" \
      || dispatch_rc=$?

    if (( dispatch_rc == 124 )); then
      # ENG-48: gtimeout SIGTERM'd a wedged dispatch. This is a hard halt,
      # not a transient failure — the agent likely entered a self-loop
      # and operator review is required. skip-until-human-acts policy
      # (vs. retry-immediately for generic exit 20) ensures the next
      # tick won't re-dispatch automatically.
      # ENG-65 D-004: surface the worktree-resume hint so the operator
      # can inspect the partial artifact (the watchdog SIGTERM may fire
      # mid-iteration with a usable doc on disk; see ENG-58 incident)
      # and either resume via `--action continue` or fix the underlying P0.
      classify_failure "$ident" "$stage" "skip-until-human-acts" \
        "dispatch wall-clock timeout — agent exceeded budget without exiting. Partial worktree artifacts may resume cleanly. Inspect: $(issue_dir "$ident")/worktree/. If the artifact looks complete, run: bash bin/pipeline.sh decide $ident --action continue" 124
      rm -f "$prompt_file"
      exit 124
    elif (( dispatch_rc == 22 )); then
      # ENG-43: implement-stage transcript invoked the forbidden
      # `gh pr create` tool. Read the matched command from the sidecar
      # written by _render_and_capture_stream and surface the same
      # operator-facing halt as the deleted state-check guard:
      # exit 22, skip-until-human-acts, pr-opened-too-early.
      local _viol_file _viol_cmd
      _viol_file="$(issue_dir "$ident")/.transcript-violation-${stage}"
      _viol_cmd="$(cat "$_viol_file" 2>/dev/null || printf '<command-unavailable>')"
      classify_failure "$ident" "$stage" "skip-until-human-acts" \
        "implement-stage transcript invoked forbidden tool: $_viol_cmd" 22
      rm -f "$_viol_file" "$prompt_file"
      exit 22
    elif (( dispatch_rc == 23 )); then
      # ENG-66: agent transcript invoked one of the four banned
      # branch-creation forms (git checkout -b/-B, git branch -m,
      # git switch -c). The orchestrator owns the worktree's branch;
      # this is a hard halt — the operator must investigate before
      # the next dispatch. Cross-stage by design (the renderer's
      # ENG-66 loop has no stage gate); fires on any stage whose
      # transcript matched. Recovery recipe is documented in
      # docs/runbooks/recovery.md §7.
      local _viol_file_23 _viol_cmd_23
      _viol_file_23="$(issue_dir "$ident")/.transcript-violation-${stage}"
      _viol_cmd_23="$(cat "$_viol_file_23" 2>/dev/null || printf '<command-unavailable>')"
      classify_failure "$ident" "$stage" "skip-until-human-acts" \
        "agent transcript invoked forbidden branch-creation form: $_viol_cmd_23" 23
      rm -f "$_viol_file_23" "$prompt_file"
      exit 23
    elif (( dispatch_rc == 26 )); then
      # ENG-71: build-stage transcript invoked one of `git checkout`,
      # `git switch`, `git pull`, `git reset` — the four worktree-HEAD-
      # mutating verbs the build agent is contractually forbidden from
      # invoking (the merge is server-side via `gh pr merge --auto`;
      # local sync is the harness's job). Read the matched command
      # from the sidecar written by _render_and_capture_stream and
      # surface a skip-until-human-acts halt.
      #
      # D-002's assert_no_tool_invocation runs AFTER the agent has
      # already executed the forbidden Bash command (the transcript
      # scan is post-stream), so the worktree may already be on `main`
      # by the time we reach this arm. Invoke the post-dispatch
      # HEAD-detection helper before exit so HEAD is detached on the
      # way out and `main` is globally unlocked. The helper is
      # idempotent (no-op when HEAD already on the expected branch)
      # and stage-gated to building, so calling it on this fail path
      # is safe regardless of whether the agent's chained-command
      # actually mutated HEAD or not.
      local _viol_file _viol_cmd
      _viol_file="$(issue_dir "$ident")/.transcript-violation-${stage}"
      _viol_cmd="$(cat "$_viol_file" 2>/dev/null || printf '<command-unavailable>')"
      classify_failure "$ident" "$stage" "skip-until-human-acts" \
        "build-stage transcript invoked forbidden worktree-HEAD-mutating tool: $_viol_cmd" 26
      _post_dispatch_check_worktree_head "$ident" "$stage" || true
      rm -f "$_viol_file" "$prompt_file"
      exit 26
    elif (( dispatch_rc == 13 )); then
      # ENG-68: stage transcript invoked a forbidden core.bare git form
      # (one of: `git config core.bare`, `git init --bare`, `git --bare`,
      # `git config --add core.bare`, `git -c core.bare=`). Read the
      # matched command from the sidecar and surface a halt with
      # lane-violation outcome and skip-until-human-acts policy —
      # operator must investigate the allowlist drift before resume.
      local _viol_file_13 _viol_cmd_13
      _viol_file_13="$(issue_dir "$ident")/.transcript-violation-${stage}"
      _viol_cmd_13="$(cat "$_viol_file_13" 2>/dev/null || printf '<command-unavailable>')"
      classify_failure "$ident" "$stage" "skip-until-human-acts" \
        "stage transcript invoked forbidden core.bare git form: $_viol_cmd_13" 13
      rm -f "$_viol_file_13" "$prompt_file"
      exit 13
    elif (( dispatch_rc == 29 )); then
      # ENG-109: dispatch.sh's Write-on-progress.md detective caught
      # an agent truncating the per-issue progress notebook via the
      # Write tool (the append-only contract of progress.md is a
      # convention not an ACL — the detective is the catch-net per
      # docs/runbooks/progress-md.md §3). Sidecar shape mirrors the
      # rc=22/23/26/13 arms above. Note: rc=29 is also produced by
      # the post-dispatch _validate_dispatch_envelope at line ~1630
      # below; both halt with skip-until-human-acts dispatch-envelope-
      # violation. The disambiguator lives in the per-stage transcript
      # (this arm's `[assert] ... forbidden Write on progress.md` log
      # vs the envelope validator's `mcp__plugin_linear` /
      # `curl https://api.linear.app` match).
      local _viol_file_29 _viol_cmd_29
      _viol_file_29="$(issue_dir "$ident")/.transcript-violation-${stage}"
      _viol_cmd_29="$(cat "$_viol_file_29" 2>/dev/null || printf '<path-unavailable>')"
      classify_failure "$ident" "$stage" "skip-until-human-acts" \
        "dispatch-stage transcript invoked forbidden Write on progress.md: $_viol_cmd_29" 29
      # rm -f here diverges from _validate_dispatch_envelope's C3 preservation
      # (envelope validator preserves its sidecar for post-halt inspection).
      # This arm's sidecar contains only the matched file_path (single line,
      # no multi-path context); the classify_failure message above already
      # surfaces the path in the Linear halt comment, making the sidecar
      # redundant for operator triage.
      rm -f "$_viol_file_29" "$prompt_file"
      exit 29
    elif (( dispatch_rc == 31 )); then
      # ENG-106: plan-stage progress.md detective halt. Read the diagnostic
      # message from $(issue_dir "$ident")/.transcript-violation-${stage}
      # (the sidecar written by _assert_progress_md_entry in dispatch.sh)
      # and surface a skip-until-human-acts halt. Recovery: docs/runbooks/recovery.md.
      local _viol_file_31 _viol_msg_31
      _viol_file_31="$(issue_dir "$ident")/.transcript-violation-${stage}"
      _viol_msg_31="$(cat "$_viol_file_31" 2>/dev/null || printf '<violation-detail-unavailable>')"
      classify_failure "$ident" "$stage" "skip-until-human-acts" \
        "plan-stage progress.md entry missing or malformed: $_viol_msg_31" 31
      rm -f "$_viol_file_31" "$prompt_file"
      exit 31
    elif (( dispatch_rc != 0 )); then
      classify_failure "$ident" "$stage" "retry-immediately" \
        "dispatch failed (see $log_file)" 20
      rm -f "$prompt_file"
      exit 20
    fi
    rm -f "$prompt_file"
  else
    _replay_scope_approval "$ident" "$stage"
  fi

  # Post-review premise-failure is now expressed as a pipeline-rejection
  # marker with target brainstorming; the Verdict Handler loopback table
  # (reviewing|brainstorming|pipeline:supersede) handles it below.

  # Post-implement / post-ui guards:
  #   (a) scope-check: no files outside plan File Structure were touched.
  #   (b) no-pr-check: implement stage must NOT have opened a PR (UI stage opens the PR).
  if [[ "$stage" == "implementing" || "$stage" == "ui" ]]; then
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
        # exists, scope-approve decision marker newer than the most
        # recent scope-violation halt), treat as approved and clear
        # state. Otherwise, emit a verdict result=halt reason=scope-violation
        # marker and the sentinel label; the Verdict Handler leaves the halt
        # intact until pipeline.sh decide --action approve --gate scope posts
        # a decision marker.
        if [[ -f "$approval_state_file" ]] \
           && bash "$SCRIPT_DIR/scope-check.sh" has-scope-approval "$ident" 2>/dev/null; then
          log "scope-check: notable approved by scope-approve decision; clearing state and proceeding"
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
          # ENG-18: append-only halt marker (scope-violation reason) + sentinel
          # label. The Verdict Handler leaves the halt intact until
          # pipeline.sh decide --action approve --gate scope posts a decision.
          local halt_body
          halt_body="$(printf '<!-- pipeline: verdict result=halt reason=scope-violation -->\n\nPipeline: `%s` stage touched files outside the plan File Structure on branch `%s`. Notable (adjacent-to-scope) files:\n\n%s\nTo approve and resume:\n\n    bash %s/bin/pipeline.sh decide %s --action approve --gate scope\n\nTo reject, revert the out-of-scope edits and remove `pipeline:halted`. (Benign escapes — pipeline telemetry, Cargo.lock, docs/knowledge, tests under an in-scope crate — are auto-allowed and not listed here.)' \
            "$stage" "$branch" "$fs_patch" "$HARNESS_ROOT" "$ident")"
          bash "$SCRIPT_DIR/linear.sh" add-comment "$ident" "$halt_body" || true
          bash "$SCRIPT_DIR/linear.sh" add-label   "$ident" "pipeline:halted" || true

          t1="$(date +%s)"; duration=$(( (t1 - t0) * 1000 ))
          # ENG-10: emit typed outcome via the failure taxonomy so
          # retrospective §1's filter picks up the halt event.
          # ENG-26 (D-005): claude ran on this branch, so attach cost
          # flags. Empty array (no usage file) expands to zero args
          # under the bash-3.2-safe `[@]+…` form.
          local _cf_pending=()
          local _cf_line
          while IFS= read -r _cf_line; do
            _cf_pending+=("$_cf_line")
          done < <(_cost_flags_for "$ident" "$stage")
          bash "$SCRIPT_DIR/metrics.sh" stage-end "$ident" "$stage" \
            "$(failure_outcome_for_exit 0 1)" "$duration" \
            "branch=$branch notable_count=$(wc -l <<<"$notable_files" | tr -d ' ')" \
            "${_cf_pending[@]+"${_cf_pending[@]}"}" || true
          # ENG-87 review-iter-7 M3: end-row writer reads find_fresh_verdict
          # at trap-fire time, so this manual seed is no longer needed.
          # The just-posted halt verdict will be picked up by the writer's
          # Linear read.
          exit 0
        fi
        ;;
      3)
        local severe_files
        severe_files="$(grep -E '^severe	' <<<"$scope_out" | awk -F'\t' '{print $2}' | sort -u)"
        local severe_patch
        severe_patch="$(printf -- '- `%s`\n' $severe_files)"
        bash "$SCRIPT_DIR/guards.sh" bump "$ident" implement_rejection \
          --reason "SEVERE scope violation on $branch: $(tr '\n' ' ' <<<"$severe_patch")" \
          --reason-code scope-violation-severe || true
        classify_failure "$ident" "$stage" "skip-until-human-acts" \
          "SEVERE scope violation on $branch: $(tr '\n' ' ' <<<"$severe_patch")" 21 3
        exit 21
        ;;
      *)
        local scope_detail
        scope_detail="$(_compose_scope_check_detail "$scope_out")"
        bash "$SCRIPT_DIR/guards.sh" bump "$ident" implement_rejection \
          --reason "scope-check rc=$scope_rc: ${scope_detail:-no diagnostic captured}" \
          --reason-code scope-violation || true
        classify_failure "$ident" "$stage" "skip-until-code-changes" \
          "scope-check rc=$scope_rc: ${scope_detail:-no diagnostic captured}" \
          21 "$scope_rc"
        exit 21
        ;;
    esac

    # Scan for Gotcha-hit commit trailers and bump the per-issue counter.
    # Non-blocking: telemetry only. Retrospective reads both the aggregate git log
    # AND the per-issue counter.
    bash "$SCRIPT_DIR/scan-gotcha-trailers.sh" "$ident" "$branch" || true
  fi

  # ENG-105 follow-up: noop-implementation halt detector.
  # After a clean implementing dispatch with passing scope-check, if the
  # branch HEAD is unchanged from before the dispatch, the agent silently
  # re-emitted its prior stage summary without committing any code. This
  # is the ENG-105 failure mode: on a review-loopback, the implementer
  # reads the dedup-updated `completion/implementing/<issue>` Linear
  # comment (still showing the PREVIOUS dispatch's body), copies it to
  # its stage-summary file as-is, posts `verdict pass`, and exits — the
  # reviewer then runs again against the unchanged branch tip, re-emits
  # the same findings, and the cycle repeats. ENG-105 burned 7 such
  # cycles before manual intervention (~$45 of reviewer cost).
  #
  # Gating:
  #   - stage == implementing (ui's no-op on harness-self is legitimate;
  #     brainstorm/plan/review don't commit at all)
  #   - !skip_dispatch (scope-approval replay legitimately has zero
  #     new commits since it doesn't dispatch the agent)
  #   - _HEAD_PRE_DISPATCH captured (non-git worktree fail-open)
  #   - HEAD_POST == HEAD_PRE (the actual signal)
  # Exit 30 routes via failure_outcome_for_exit → 'noop-implementation'
  # and classify_failure → policy 'skip-until-human-acts' →
  # halt_reason 'agent-blocked'. Resume via
  # `bash bin/pipeline.sh decide <issue> --action continue`
  # after addressing the reviewer's findings on the branch.
  if [[ "$stage" == "implementing" ]] && (( ! skip_dispatch )) && [[ -n "$_HEAD_PRE_DISPATCH" ]]; then
    if ! _dispatch_made_new_commits "$(issue_dir "$ident")/worktree" "$_HEAD_PRE_DISPATCH"; then
      bash "$SCRIPT_DIR/guards.sh" bump "$ident" implement_rejection \
        --reason "implementing dispatch produced zero new commits (branch HEAD unchanged from $_HEAD_PRE_DISPATCH)" \
        --reason-code noop-implementation || true
      classify_failure "$ident" "$stage" "skip-until-human-acts" \
        "implementing dispatch produced zero new commits (branch HEAD unchanged from $_HEAD_PRE_DISPATCH). On a review-loopback this means the agent re-emitted its prior stage summary without addressing the reviewer's findings — the ENG-105 NOOP failure mode. Inspect the prior review at \`completion/reviewing/$ident\` in Linear, fix the cited findings on the branch by hand, then resume with \`bash bin/pipeline.sh decide $ident --action continue\`." \
        30
      exit 30
    fi
  fi

  # ENG-45: wait exit. Build agent posts <!-- pipeline: verdict result=wait reason=... --> on
  # P2/P5 failures so the orchestrator re-dispatches next tick instead of
  # halting. Detect BEFORE the agent-contract validator below — that
  # validator (and the defensive halt-add + verdict_handler downstream)
  # would otherwise trip on a legitimate wait exit (no summary file, no
  # verdict marker).
  if (( ! skip_dispatch )); then
    local _wait_reason
    _wait_reason="$(_fresh_wait_reason "$ident" "$stage" 2>/dev/null || printf '')"
    if [[ -n "$_wait_reason" ]]; then
      if _handle_wait "$ident" "$stage" "$_wait_reason"; then
        # ENG-45 review-major-1: wait-exit must propagate ENG-26 D-008 cost
        # flags. dispatch.sh ran (we're inside `! skip_dispatch`) and wrote
        # usage-${stage}.json; without these flags the retrospective per-stage
        # cost aggregation under-counts Opus spend by one row per wait dispatch.
        local _wait_cost_flags=()
        local _wait_cf_line
        while IFS= read -r _wait_cf_line; do
          _wait_cost_flags+=("$_wait_cf_line")
        done < <(_cost_flags_for "$ident" "$stage")
        bash "$SCRIPT_DIR/metrics.sh" stage-end "$ident" "$stage" "soft-pending" \
          "$(( ($(date +%s) - t0) * 1000 ))" "reason=$_wait_reason" \
          "${_wait_cost_flags[@]+"${_wait_cost_flags[@]}"}" || true
        # ENG-54: review-stage wait-success branch is gone (review never
        # waits anymore — _fresh_wait_reason narrowed to build only).
        log "stage $stage wait on $ident (reason=$_wait_reason)"
        # ENG-87 review-iter-7 M3: writer reads find_fresh_wait_verdict
        # at trap-fire time when find_fresh_verdict returns empty (wait
        # is excluded by the latter's filter). Manual seed removed.
        exit 0
      fi
      # Budget exhausted: _handle_wait already posted the halt comment and
      # applied pipeline:halted. Skip the rest of the dispatch flow entirely.
      # The previous design fell through, but post_completion_comment then
      # fired against the just-deleted stage-summary file and posted a
      # contradictory `summary_missing` follow-up (review-major-1). Emit the
      # halt-for-human metric explicitly here and exit clean — verdict_handler
      # will re-classify the halt naturally on the next tick.
      local _halt_cost_flags=()
      local _halt_cf_line
      while IFS= read -r _halt_cf_line; do
        _halt_cost_flags+=("$_halt_cf_line")
      done < <(_cost_flags_for "$ident" "$stage")
      bash "$SCRIPT_DIR/metrics.sh" stage-end "$ident" "$stage" "halt-for-human" \
        "$(( ($(date +%s) - t0) * 1000 ))" "verdict=halt reason=$_wait_reason exhausted=external-signal-budget" \
        "${_halt_cost_flags[@]+"${_halt_cost_flags[@]}"}" || true
      log "stage $stage halt-for-human on $ident (external-signal-budget exhausted, reason=$_wait_reason)"
      # ENG-87 review-iter-7 M3: writer reads find_fresh_verdict at
      # trap-fire time and picks up the budget-exhausted halt comment
      # _handle_wait just posted. Manual seed removed.
      exit 0
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
      brainstorming|planning|implementing|ui|reviewing|qa|building)
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

  # ENG-87: post-dispatch envelope validator. Halts on egregious bypass
  # only — transcript scan for direct Linear API calls (mcp__plugin_linear*
  # or curl https://api.linear.app) outside the bin/linear.sh chokepoint.
  # Detective backstop on top of (a) ENG-41's lane fence, (b) Task 7's
  # auto-injection — catches an agent that bypasses bin/linear.sh entirely.
  # Skip on scope-approval replay (no agent ran). Cleans the sidecar
  # whether the envelope is clean OR violation (after halt comment lands).
  if (( ! skip_dispatch )); then
    case "$stage" in
      brainstorming|planning|implementing|ui|reviewing|qa|building)
        local _env_rc=0
        _validate_dispatch_envelope "$ident" "$stage" || _env_rc=$?
        if (( _env_rc == 29 )); then
          classify_failure "$ident" "$stage" "skip-until-human-acts" \
            "dispatch envelope violation: agent bypassed bin/linear.sh (transcript shows mcp__plugin_linear or curl https://api.linear.app)" 29
          # ENG-87 review C3: do NOT remove the sidecar on the halt
          # path. CLAUDE.md and docs/runbooks/recovery.md both promise
          # that the transcript is "preserved across the halt for
          # forensic review and removed by the next clean dispatch."
          # Pre-clean at dispatch.sh:102 ensures the next dispatch
          # cannot inherit a stale sidecar; cleanup on `--action
          # continue` is the operator's recovery path.
          exit 29
        fi
        # ENG-156: Phase A detective (always log-only); Phase B halt
        # when config flag is on AND a PROMPT_RESOLVERS path is denied.
        local _sd_rc=0
        _emit_sandbox_denial_metric "$ident" "$stage" || _sd_rc=$?
        if (( _sd_rc == 29 )); then
          classify_failure "$ident" "$stage" "skip-until-human-acts" \
            "sandbox-contract-violation: orchestrator rendered a path the sandbox denied (inspect $(issue_dir "$ident")/.transcript-violation-${stage})" 29
          # ENG-87 review C3 precedent: preserve the envelope-transcript
          # sidecar on the halt path for forensic review. The next clean
          # dispatch's pre-clean removes it.
          exit 29
        fi
        rm -f "$(issue_dir "$ident")/.envelope-transcript-${stage}" 2>/dev/null || true
        ;;
    esac
  fi

  # ENG-122: plan-contract validator. Post-dispatch; planning stage only.
  # Halts with plan-contract-invalid if docs/plans/<basename>.json is absent,
  # malformed, or fails schema-v1 validation. Exit codes 30/31/32 map to the
  # failure_outcome_for_exit taxonomy entries added in Task 1.
  if (( ! skip_dispatch )); then
    case "$stage" in
      planning)
        local _plan_rc=0
        _validate_plan_contract "$ident" || _plan_rc=$?
        if (( _plan_rc != 0 )); then
          classify_failure "$ident" "$stage" "skip-until-human-acts" \
            "plan-contract-invalid: $(failure_outcome_for_exit "$_plan_rc")" "$_plan_rc"
          exit "$_plan_rc"
        fi
        ;;
    esac
  fi

  # ENG-119: review-payload validator. Post-dispatch; reviewing stage only.
  # Halts with review-payload-invalid if $issue_dir/verdict-review.json is
  # absent, malformed, or fails schema-v1 validation. Exit codes 36/37/38
  # map to the failure_outcome_for_exit taxonomy entries added in Task 1.
  if (( ! skip_dispatch )); then
    case "$stage" in
      reviewing)
        local _rev_rc=0
        _validate_review_payload "$ident" || _rev_rc=$?
        if (( _rev_rc != 0 )); then
          classify_failure "$ident" "$stage" "skip-until-human-acts" \
            "review-payload-invalid: $(failure_outcome_for_exit "$_rev_rc")" "$_rev_rc"
          exit "$_rev_rc"
        fi
        ;;
    esac
  fi

  # ENG-117: qa-payload validator. Post-dispatch; qa stage only.
  # Halts with qa-payload-invalid if $issue_dir/verdict-qa.json is absent,
  # malformed, or fails schema-v1 validation. Exit codes 39/40/41 map to
  # the failure_outcome_for_exit taxonomy entries added in 75d2866.
  if (( ! skip_dispatch )); then
    case "$stage" in
      qa)
        local _qa_payload_rc=0
        _validate_qa_payload "$ident" || _qa_payload_rc=$?
        if (( _qa_payload_rc != 0 )); then
          classify_failure "$ident" "$stage" "skip-until-human-acts" \
            "qa-payload-invalid: $(failure_outcome_for_exit "$_qa_payload_rc")" "$_qa_payload_rc"
          exit "$_qa_payload_rc"
        fi
        ;;
    esac
  fi

  # Push branch BEFORE posting the completion comment so any `github.com/.../blob/<branch>/…`
  # link in the agent's summary resolves. run-local.sh's partition-sweep push only fires on
  # uncommitted dirty paths; an agent that commits its artifacts cleanly otherwise leaves the
  # branch local-only (ENG-6 observed). Non-fatal on failure — next tick will retry.
  case "$stage" in
    brainstorming|planning|implementing|ui|reviewing|qa|building)
      push_branch_if_ahead || true
      ;;
  esac

  # Post-stage completion comment (ENG-11). Orchestrator-owned narrative post.
  # Runs on both fresh dispatches and scope-approval replays (narrates the advance).
  case "$stage" in
    brainstorming|planning|implementing|ui|reviewing|qa|building)
      if ! post_completion_comment "$ident" "$stage"; then
        classify_failure "$ident" "$stage" "retry-immediately" \
          "linear post failed for completion/$stage/$ident after one retry" 24
        exit 24
      fi
      ;;
  esac

  # Stage-drift guard (ENG-41 §4.3): if the stage label changed during the
  # agent run, something (legitimate or forged) already transitioned the issue.
  # Skip both the defensive halt-add AND the verdict_handler call so we do not
  # compound a state we do not recognise. The next tick re-evaluates from poll.
  local stage_label_long
  case "$stage" in
    brainstorming|planning|implementing|reviewing|building|released) stage_label_long="$stage" ;;
    *) stage_label_long="$stage" ;;  # ui, qa, retrospective stay as-is
  esac
  local dispatched_stage_label="stage:$stage_label_long"
  local current_stage_label
  current_stage_label="$(bash "$SCRIPT_DIR/linear.sh" stage-of "$ident")"
  if [[ "$current_stage_label" != "$dispatched_stage_label" ]]; then
    log "post-dispatch: stage drifted ($dispatched_stage_label → ${current_stage_label:-none}) during run — skipping defensive halt apply and verdict handler"
    t1="$(date +%s)"; duration=$(( (t1 - t0) * 1000 ))
    bash "$SCRIPT_DIR/metrics.sh" stage-end "$ident" "$stage" "stage-drift" "$duration" \
      "drift=${current_stage_label:-none}" || true
    exit 0
  fi

  # Post-dispatch halt apply (ENG-56): orchestrator is the canonical applier
  # of pipeline:halted. See `_post_dispatch_apply_halt` for the wait-shape
  # carve-out and why it's structured as a callable.
  _post_dispatch_apply_halt "$ident" "$stage"

  # Resolve the current stage from the Linear label (long form) rather than
  # the short-form $stage argument, because the Verdict Handler tables are
  # keyed on the long form (brainstorming, planning, implementing, ...).
  # current_stage_label was already fetched above in the drift guard (and
  # confirmed equal to dispatched_stage_label, so no second linear.sh call needed).
  local vh_stage
  vh_stage="${current_stage_label#stage:}"

  # ENG-87 review-iter-7 M3: verdict_emitted / verdict_target are now
  # derived inside _append_dispatch_end_row (which calls find_fresh_verdict
  # at trap-fire time). The pre-iter-7 explicit pre-seed here was the
  # success-path mirror of M3's manual seeds at halt/wait sites; with
  # the writer-side derivation it's redundant.

  local vh_rc=0
  verdict_handler "$ident" "$vh_stage" || vh_rc=$?

  # ENG-71: defense-in-depth check for the worktree-on-main symptom
  # observed in ENG-61. Stage-gated to building inside the helper.
  case "$stage" in
    building) _post_dispatch_check_worktree_head "$ident" "$stage" ;;
  esac

  t1="$(date +%s)"; duration=$(( (t1 - t0) * 1000 ))

  # ENG-87 review M1+M2: the dispatch_history.jsonl end row is appended
  # by the EXIT trap (_append_dispatch_end_row) installed after the
  # start-row above. The trap emits the full 9-field schema (plan §13.1.2)
  # at every exit site (clean OR halt). If skip_dispatch was set
  # (scope-approval replay), the trap is NOT installed (no start row was
  # either — preserves the start/end pairing invariant).

  # ENG-26 D-005: claude ran for all three vh_rc arms below (success,
  # halt-for-human, protocol-violation), so each site receives cost
  # flags. Read once into a bash array, then expand under the
  # `${arr[@]+"${arr[@]}"}` empty-safe form (bash 3.2 + set -u; A-23).
  # The empty array preserves the legacy positional shape on missing
  # usage file (D-005 absence path).
  local cost_flags=()
  local _cf_line
  while IFS= read -r _cf_line; do
    cost_flags+=("$_cf_line")
  done < <(_cost_flags_for "$ident" "$stage")
  case "$vh_rc" in
    0)
      bash "$SCRIPT_DIR/metrics.sh" stage-end "$ident" "$stage" "success" "$duration" "verdict=transitioned" \
        "${cost_flags[@]+"${cost_flags[@]}"}"
      log "stage $stage complete for $ident (verdict-handler transitioned)"
      # ENG-50: capture last-review-state on review-stage transitions
      # (advance to qa OR loopback to implementing). Both are successful
      # exits where the agent observed the PR state and acted on it.
      if [[ "$stage" == "review" || "$stage" == "reviewing" ]]; then
        local _rp_branch
        _rp_branch="$(bash "$SCRIPT_DIR/linear.sh" get-issue "$ident" 2>/dev/null \
          | jq -r '.data.issue.gitBranchName // empty' 2>/dev/null || true)"
        [[ -n "$_rp_branch" ]] && _post_review_dispatch_update "$ident" "$_rp_branch" || true
      fi
      # Success path: clear any prior failure state + skip labels.
      # ENG-146: strip-not-delete preserves the dispatch_id seq counter
      # so the next stage's first dispatch increments to d<seq+1>.
      strip_state_preserve_alloc "$(issue_dir "$ident")/issue-state.json" 2>/dev/null || true
      rm -f "$(issue_dir "$ident")/wait-${stage}.json" 2>/dev/null || true
      bash "$SCRIPT_DIR/linear.sh" remove-label "$ident" "pipeline:skip-until-code-changes" 2>/dev/null || true
      bash "$SCRIPT_DIR/linear.sh" remove-label "$ident" "pipeline:skip-until-human-acts"   2>/dev/null || true
      # Clear pipeline:supersede on brainstorm/plan stage success so the signal
      # does not leak into downstream stages (only reconcile reads this label,
      # and reconcile only runs for brainstorm/plan per run-local.sh).
      # NOTE: pipeline:extend is NOT auto-cleared (ENG-6 D-005 — extend is a
      # carry-forward signal the operator may intend to span multiple stages).
      if [[ "$stage" == "brainstorm" || "$stage" == "brainstorming" \
         || "$stage" == "plan"       || "$stage" == "planning" ]]; then
        bash "$SCRIPT_DIR/linear.sh" remove-label "$ident" "pipeline:supersede" 2>/dev/null || true
      fi
      ;;
    1)
      bash "$SCRIPT_DIR/metrics.sh" stage-end "$ident" "$stage" "halt-for-human" "$duration" "verdict=halt" \
        "${cost_flags[@]+"${cost_flags[@]}"}"
      log "stage $stage halted on $ident (human intervention required)"
      ;;
    2)
      bash "$SCRIPT_DIR/metrics.sh" stage-end "$ident" "$stage" "protocol-violation" "$duration" "verdict=violation" \
        "${cost_flags[@]+"${cost_flags[@]}"}"
      log "stage $stage protocol violation on $ident"
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
