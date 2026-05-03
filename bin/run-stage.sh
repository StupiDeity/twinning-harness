#!/usr/bin/env bash
# Run a single pipeline stage against a Linear issue.
# Usage: run-stage.sh <issue_id> <stage>
# Exit codes: 0=success, 10=guards-tripped, 11=paused, 12=stage-drift (post-dispatch
#             stage label changed during run; no halt re-applied), 13=lane-violation
#             (linear.sh write rejected for caller's PIPELINE_WRITER lane),
#             20=dispatch-failed, 21=scope-violation, 22=pr-opened-too-early,
#             24=linear-post-failed, 25=agent-contract-missing (agent exited clean
#             but emitted neither the stage-summary file nor a verdict-marker comment).
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

  # Stage → doc-dir mapping. Only brainstorm/brainstorming and plan/planning
  # have a single canonical doc surface; post-plan stages span the repo and
  # are best described by branch-delta which the PR link already covers.
  local doc_dir=""
  case "$stage" in
    brainstorm|brainstorming) doc_dir="docs/brainstorms" ;;
    plan|planning)            doc_dir="docs/plans" ;;
    *)                        printf ''; return 0 ;;
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
    ui|review|reviewing|qa|build|building)
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
    # The cost footer is intentionally NOT appended on the fallback path —
    # symmetric with _stage_artifacts_footer's "artifacts-only-on-fallback"
    # design (no usage to report on a silent-exit / dispatch-crashed run).
    local artifacts_tail
    artifacts_tail="$(_stage_artifacts_footer "$issue" "$stage")"
    comment_body="$(printf '%s\n\n_Agent did not write a stage summary; posting mechanical completion._%s%s\n<!-- pipeline-metric: %s -->' \
      "$header" "$pr_tail" "$artifacts_tail" "$fallback_marker")"
  else
    # Cost footer (ENG-26 D-008): one line of `cost: $X · in Yk · out Zk
    # · cache N%` between body and PR tail. Empty string when the usage
    # file is missing/malformed (legacy / dispatch-crashed / dry-run).
    local cost_footer
    cost_footer="$(_cost_footer "$issue" "$stage")"
    comment_body="$(printf '%s\n\n%s%s%s' "$header" "$body" "$cost_footer" "$pr_tail")"
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

  # Expected stage label present? Map the (possibly verb-form) stage arg to
  # its canonical gerund label suffix, then check for stage:<suffix>.
  local prefix expected
  prefix="$(config_get '.linear.stage_label_prefix')"
  local label_suffix
  case "$stage" in
    brainstorm|brainstorming) label_suffix="brainstorming" ;;
    plan|planning)            label_suffix="planning"      ;;
    implement|implementing)   label_suffix="implementing"  ;;
    ui)                       label_suffix="ui"            ;;
    review|reviewing)         label_suffix="reviewing"     ;;
    qa)                       label_suffix="qa"            ;;
    build|building)           label_suffix="building"      ;;
    release|released)         label_suffix="released"      ;;
    *)                        label_suffix=""              ;;
  esac
  expected="${prefix}${label_suffix}"

  if [[ -n "$expected" ]] && ! bash "$SCRIPT_DIR/linear.sh" has-label "$ident" "$expected"; then
    die "precondition failed: $ident does not carry $expected (must be applied before run-stage)"
  fi

  return 0
}

# ─── ENG-45 / ENG-54: build-stage wait-marker gate + budget escalation ──────
# Returns the wait reason on stdout (exit 0) iff a fresh, well-formed,
# build-only `<!-- pipeline-wait: <reason> -->` marker exists newer than the
# most recent pipeline-transition. Else prints empty + nonzero. Build-only
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
    build|building) ;;
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

  # Find the latest wait verdict newer than the transition.
  local fresh_reason=""
  local fresh_ts=""
  while IFS=$'\t' read -r ts body; do
    [[ -n "$last_t" && ! "$ts" > "$last_t" ]] && continue
    ev="$(parse_pipeline_marker "$body" 2>/dev/null || true)"
    [[ -z "$ev" ]] && continue
    [[ "$(jq -r '.event' <<<"$ev")" != "verdict" ]] && continue
    [[ "$(jq -r '.result' <<<"$ev")" != "wait" ]] && continue
    if [[ "$ts" > "$fresh_ts" ]]; then
      fresh_ts="$ts"
      fresh_reason="$(jq -r '.reason' <<<"$ev")"
    fi
  done < <(jq -r '.[] | "\(.createdAt)\t\(.body | gsub("\n"; " "))"' <<<"$comments")

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
# Wait-shape carve-out: if a fresh `<!-- pipeline-wait: <reason> -->` marker
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
    halt_body="$(printf '<!-- pipeline-halt: external-signal-budget-exhausted -->\n\nBuild stage halted: %s budget exhausted (%d attempts since %s).\n\n**Resume:** approve the PR as a non-bot Code Owner, then run `bash bin/halt.sh resolve %s --decision resume`. Or raise `orchestrator.external_signal_budget.max_attempts` / `max_minutes` in `.pipeline-config/config.json` to extend the window.' \
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

main() {
  local ident="${1:-}" stage="${2:-}"
  [[ -n "$ident" && -n "$stage" ]] || die "usage: run-stage.sh <issue_id> <stage>"

  # Normalize verb-form stage name to canonical gerund (backwards-compat).
  # Verb forms (brainstorm, plan, implement, review, build, release) are deprecated;
  # callers should pass gerund (brainstorming, planning, implementing, reviewing,
  # building, released). Both work for one release cycle.
  local _verb_to_gerund
  case "$stage" in
    brainstorm) _verb_to_gerund="brainstorming"; log "[deprecated] stage 'brainstorm' should be 'brainstorming'" ;;
    plan)       _verb_to_gerund="planning";      log "[deprecated] stage 'plan' should be 'planning'" ;;
    implement)  _verb_to_gerund="implementing";  log "[deprecated] stage 'implement' should be 'implementing'" ;;
    review)     _verb_to_gerund="reviewing";     log "[deprecated] stage 'review' should be 'reviewing'" ;;
    build)      _verb_to_gerund="building";      log "[deprecated] stage 'build' should be 'building'" ;;
    release)    _verb_to_gerund="released";      log "[deprecated] stage 'release' should be 'released'" ;;
    *)          _verb_to_gerund="$stage" ;;
  esac
  stage="$_verb_to_gerund"

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
  if [[ "$stage" == "implement" || "$stage" == "implementing" || "$stage" == "ui" ]]; then
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
    log_file="$PROJECT_STATE_DIR/logs/${ident}-${stage}-$(date -u +%Y%m%dT%H%M%SZ).log"
    mkdir -p "$(dirname "$log_file")"
    bash "$SCRIPT_DIR/render-prompt.sh" "$stage" "$ident" > "$prompt_file"
    log "rendered prompt: $prompt_file ($(wc -l < "$prompt_file") lines)"

    bash "$SCRIPT_DIR/metrics.sh" stage-start "$ident" "$stage" "dispatching" 0

    # Dispatch. Export PIPELINE_ISSUE_ID so dispatch.sh can resolve the
    # per-stage usage-file path (ENG-26 D-012). Ambient-context env var
    # mirrors the existing PIPELINE_DRY_RUN pattern (common.sh:171).
    local dispatch_rc=0
    PIPELINE_ISSUE_ID="$ident" \
      bash "$SCRIPT_DIR/dispatch.sh" "$stage" "$prompt_file" "$log_file" \
      || dispatch_rc=$?

    if (( dispatch_rc == 124 )); then
      # ENG-48: gtimeout SIGTERM'd a wedged dispatch. This is a hard halt,
      # not a transient failure — the agent likely entered a self-loop
      # and operator review is required. skip-until-human-acts policy
      # (vs. retry-immediately for generic exit 20) ensures the next
      # tick won't re-dispatch automatically.
      classify_failure "$ident" "$stage" "skip-until-human-acts" \
        "dispatch wall-clock timeout — agent exceeded budget without exiting" 124
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
  if [[ "$stage" == "implement" || "$stage" == "implementing" || "$stage" == "ui" ]]; then
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
          halt_body="$(printf '<!-- pipeline-halt: scope-deviation -->\n\nPipeline: `%s` stage touched files outside the plan File Structure on branch `%s`. Notable (adjacent-to-scope) files:\n\n%s\nTo approve and resume:\n\n    bash %s/bin/halt.sh resolve %s --decision scope-approved\n\nTo reject, revert the out-of-scope edits and remove `pipeline:halted`. (Benign escapes — pipeline telemetry, Cargo.lock, docs/knowledge, tests under an in-scope crate — are auto-allowed and not listed here.)' \
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
  fi

  # ENG-45: wait exit. Build agent posts <!-- pipeline-wait: <reason> --> on
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
      brainstorm|brainstorming|plan|planning|implement|implementing|ui|review|reviewing|qa|build|building)
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
    brainstorm|brainstorming|plan|planning|implement|implementing|ui|review|reviewing|qa|build|building)
      push_branch_if_ahead || true
      ;;
  esac

  # Post-stage completion comment (ENG-11). Orchestrator-owned narrative post.
  # Runs on both fresh dispatches and scope-approval replays (narrates the advance).
  case "$stage" in
    brainstorm|brainstorming|plan|planning|implement|implementing|ui|review|reviewing|qa|build|building)
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
    brainstorm|brainstorming) stage_label_long="brainstorming" ;;
    plan|planning)            stage_label_long="planning"      ;;
    implement|implementing)   stage_label_long="implementing"  ;;
    review|reviewing)         stage_label_long="reviewing"     ;;
    build|building)           stage_label_long="building"      ;;
    release|released)         stage_label_long="released"      ;;
    *)                        stage_label_long="$stage"        ;;  # ui, qa stay as-is
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
  local vh_rc=0
  verdict_handler "$ident" "$vh_stage" || vh_rc=$?

  t1="$(date +%s)"; duration=$(( (t1 - t0) * 1000 ))
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
      rm -f "$(issue_dir "$ident")/issue-state.json" 2>/dev/null || true
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
