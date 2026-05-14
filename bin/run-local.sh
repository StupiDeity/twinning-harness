#!/usr/bin/env bash
# Run one pipeline tick locally. Launched by the launchd agent at
# ~/Library/LaunchAgents/com.twinning.pipeline.plist every 5 minutes.
#
# Mirrors the dispatch job that used to run in .github/workflows/pipeline.yml:
#   poll -> (entry-action) -> run-stage -> commit+push artifacts.
#
# Responsibilities layered on top of run-stage.sh:
#   - Single-flight lock so overlapping 5-min fires don't stack.
#   - Load LINEAR_API_KEY from .pipeline/.env.local; no ANTHROPIC_API_KEY
#     because `claude` uses the logged-in subscription session.
#   - Respect orchestrator.paused in config.json.
#   - Rolling daily log at logs/pipeline/local-YYYY-MM-DD.log.
#   - Circuit breaker: after 3 consecutive run-stage failures, flip
#     orchestrator.paused=true so subsequent ticks skip until a human resets it.

set -euo pipefail

# launchd hands us a minimal PATH; belt-and-braces it with Homebrew
# sbin dirs plus stack-specific user-global bins for the dispatched
# agent. Harmless on hosts lacking those dirs (absent segments are
# ignored). See CLAUDE.md "PATH expectations on the launchd host"
# for the per-segment attribution.
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:$HOME/.bun/bin:$HOME/.npm-global/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"
# shellcheck source=run-local-helpers.sh
source "$SCRIPT_DIR/run-local-helpers.sh"
# shellcheck source=classify-failure.sh
# ENG-69: helpers (halt_issue_for_self_leak, tally_leaked_in_scope_failure,
# route_run_stage_exit) call classify_failure to halt a single issue
# without tripping the global breaker.
source "$SCRIPT_DIR/classify-failure.sh"

LOCK_DIR="$PROJECT_STATE_DIR/.run-local.lock"
ENV_FILE="$TARGET_CONFIG_DIR/.env.local"
FAIL_COUNTER="$PROJECT_STATE_DIR/.consecutive-failures"
FAIL_THRESHOLD=3
TICK_COUNTER="$PROJECT_STATE_DIR/.tick-counter"
CLEANUP_EVERY_N_TICKS=10
LOG_DIR="$PROJECT_STATE_DIR/logs"
LOG_FILE="$LOG_DIR/local-$(date -u +%Y-%m-%d).log"
# BOT_NAME / BOT_EMAIL provided by common.sh (shared with pipeline.sh's
# decide --action continue auto-commit so all bot commits attribute to
# the same identity).

mkdir -p "$HARNESS_STATE_DIR"

if ! acquire_lock "$LOCK_DIR"; then
  # Silent skip: overlapping tick is expected if a stage runs >5 min.
  exit 0
fi

# Bash traps are NOT stacked — a later `trap ... EXIT` REPLACES this one.
# Register sweep tempfiles in TWINNING_SWEEP_TMPS so they are reaped here.
TWINNING_SWEEP_TMPS=()
cleanup_on_exit() {
  rm -rf "$LOCK_DIR"
  if (( ${#TWINNING_SWEEP_TMPS[@]} > 0 )); then
    rm -f "${TWINNING_SWEEP_TMPS[@]}"
  fi
}
trap cleanup_on_exit EXIT

mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

log "== tick start =="

# Invariant: the harness's TARGET_REPO and HARNESS_ROOT git repos must
# NOT be bare. Bare-mode flips `git status` semantics and hides leaked
# state from the partition_dirty_paths sweep — exactly the failure mode
# that produced ENG-63/64/65's seed.txt scope-violation halts on
# 2026-05-04 (cause: test-fixture leak through inherited GIT_DIR).
# Self-heal here so the next tick can run cleanly; investigate via the
# warning if it ever fires.
for _git_dir in "$TARGET_REPO/.git" "$HARNESS_ROOT/.git"; do
  if [[ -d "$_git_dir" ]]; then
    bare="$(git --git-dir="$_git_dir" config --get core.bare 2>/dev/null || printf 'false')"
    if [[ "$bare" == "true" ]]; then
      capture_core_bare_forensic "$_git_dir"     # ENG-68 D-001: capture before heal
      git --git-dir="$_git_dir" config core.bare false
      log "WARNING: $_git_dir had core.bare=true; reset to false (test-fixture leak suspected — see ENG-63/64/65; forensic dump per ENG-68)"
    fi
  fi
done

SECRETS_FILE="$HARNESS_CONFIG_DIR/secrets.env"
if [[ -f "$SECRETS_FILE" ]]; then
  set -a; source "$SECRETS_FILE"; set +a
fi
if [[ -f "$ENV_FILE" ]]; then
  set -a; source "$ENV_FILE"; set +a   # per-project may override
fi
require_env LINEAR_API_KEY
require_env GH_APP_ID GH_APP_INSTALLATION_ID GH_APP_PRIVATE_KEY_PATH
require_bin shasum
assert_stage_allowlist_coverage
GITHUB_TOKEN="$(bash "$SCRIPT_DIR/gh-app-token.sh")"
export GITHUB_TOKEN
log "minted GitHub App installation token (~1h TTL)"

paused="$(is_orchestrator_paused)"
if [[ "$paused" == "true" ]]; then
  log "tick skipped: orchestrator.paused=true"
  log "reset with: bash $HARNESS_ROOT/bin/reset-pipeline.sh   # writes state.local.json (preferred)"
  log "             OR: jq '.orchestrator.paused=false' \$CONFIG > /tmp/c && mv /tmp/c \$CONFIG (legacy)"
  exit 0
fi

# ─── Worktree resolution (ENG-15: per-issue dir layout) ────────────────
# Worktrees now live under ~/.twinning-pipeline/ENG-N/worktree/ alongside
# issue-state.json + scope-approval. Parent is created on demand.
resolve_worktree_path() {
  # $1 = branch name (unused, kept for call-site compat), $2 = issue id
  local branch="$1" issue="$2"
  [[ -n "$issue" ]] || die "resolve_worktree_path: issue id required"
  printf '%s/worktree' "$(issue_dir "$issue")"
}

ensure_worktree() {
  local branch="$1" path="$2"
  if [[ -d "$path/.git" ]] || [[ -f "$path/.git" ]]; then
    log "worktree exists: $path"
    return 0
  fi
  if git -C "$TARGET_REPO" rev-parse --verify "refs/heads/$branch" >/dev/null 2>&1; then
    log "branch exists locally; creating worktree at $path pointing at $branch"
    git -C "$TARGET_REPO" worktree add "$path" "$branch"
  elif git -C "$TARGET_REPO" rev-parse --verify "refs/remotes/origin/$branch" >/dev/null 2>&1; then
    log "branch exists on origin; creating worktree at $path tracking origin/$branch"
    git -C "$TARGET_REPO" worktree add "$path" -b "$branch" "origin/$branch"
  else
    log "creating new branch $branch and worktree at $path from origin/main"
    git -C "$TARGET_REPO" fetch origin main
    # --no-track: branching off a remote-tracking ref (origin/main) otherwise wires
    # the new branch's upstream to origin/main, which makes later `git push` fail
    # with "upstream branch of your current branch does not match the name" under
    # the default push.default=simple. The first push below uses `-u origin HEAD` to
    # set the correct upstream to origin/<branch>.
    git -C "$TARGET_REPO" worktree add --no-track "$path" -b "$branch" origin/main
  fi
}

cd "$TARGET_REPO"

decision="$(bash "$SCRIPT_DIR/poll.sh")"
log "poll decision: $decision"
issue_id="$(jq -r '.issue_id // ""' <<<"$decision")"
stage="$(jq -r '.stage // ""' <<<"$decision")"
entry_action="$(jq -r '.entry_action // "run"' <<<"$decision")"

if [[ -z "$issue_id" ]]; then
  log "no work this tick"
  exit 0
fi

if [[ "$entry_action" == "apply-stage-label" ]]; then
  # Note: inline `case` inside `$( ... )` trips bash 3.2 (macOS default) — the
  # `)` after each pattern closes the command substitution early. Assign
  # directly in the case body instead.
  case "$stage" in
    brainstorming|planning|implementing|ui|reviewing|qa|building|released|retrospective) label_suffix="$stage" ;;
    *) label_suffix="$stage" ;;
  esac
  active_state="$(config_get '.linear.native_states.active')"
  bash "$SCRIPT_DIR/linear.sh" transition-state "$issue_id" "$active_state"
  bash "$SCRIPT_DIR/linear.sh" add-label "$issue_id" "stage:$label_suffix"
fi

reconcile_decision="proceed"
if [[ "$stage" == "brainstorming" || "$stage" == "planning" ]]; then
  reconcile_decision="$(bash "$SCRIPT_DIR/reconcile.sh" "$issue_id" "$stage")"
  log "reconcile decision: $reconcile_decision"
fi

# Handle link: and human reconcile outcomes before deciding to create a
# worktree. These paths short-circuit: no dispatch, no worktree, just
# Linear side effects + metrics. Per ENG-13 D-009 and recovery of the
# side-effect logic that used to live in run-stage.sh:121-151.
case "$reconcile_decision" in
  link:*)
    doc_path="${reconcile_decision#link:}"
    bash "$SCRIPT_DIR/linear.sh" add-comment "$issue_id" \
      "Pipeline reconcile: existing $stage doc is canonical: \`$doc_path\`. Advancing without regeneration."
    # Advance the stage label to the next happy-path stage.
    case "$stage" in
      brainstorming) nxt_label="planning" ;;
      planning)      nxt_label="implementing" ;;
      *)             nxt_label="" ;;
    esac
    if [[ -n "$nxt_label" ]]; then
      bash "$SCRIPT_DIR/linear.sh" swap-stage "$issue_id" "$nxt_label"
    fi
    bash "$SCRIPT_DIR/metrics.sh" stage-end "$issue_id" "$stage" "linked" 0 "doc=$doc_path"
    log "== tick end (reconcile linked) =="
    exit 0
    ;;
  human)
    bash "$SCRIPT_DIR/linear.sh" add-comment "$issue_id" \
      "Pipeline reconcile: an existing $stage doc appears to cover this topic. Apply one of: \`pipeline:supersede\` (generate fresh and retire the old), \`pipeline:extend\` (generate fresh, referencing the old), or \`pipeline:ignore\` (link the old as canonical). Until a label is applied, this issue is paused."
    bash "$SCRIPT_DIR/metrics.sh" stage-start "$issue_id" "$stage" "reconcile-human" 0
    # ENG-10 D-004: emit a matching stage-end so retrospective §1 can pair
    # the events. Direct-string emission (not via failure_outcome_for_exit)
    # because exit_code=0 subcode="" would route to unknown-exit-0; this
    # path is a short-circuit, not a classified failure.
    bash "$SCRIPT_DIR/metrics.sh" stage-end "$issue_id" "$stage" \
      "reconcile-human" 0 "awaiting=supersede-or-extend-or-ignore" || true
    log "== tick end (reconcile human gate) =="
    exit 0
    ;;
esac

# Determine branch name and worktree path. The legacy `feature/*`
# coexistence path that used to live here was deleted in ENG-67
# (May 2026): it dispatched the agent from the operator's $TARGET_REPO
# checkout when an agent had created a non-canonical
# `feature/eng-N-...` branch (the May-2026 ENG-63/64/65 failure mode),
# silently mutating the operator's HEAD and breaking scope-check.
# PR #48 (commit 4635cd3) closed the upstream cause at the prompt
# level (AGENT_PROMPTS.md:77-88 hard-rules 1-4 +
# bin/agent-prompts-content-test.sh:447-491 pins); the orchestrator-
# side coexistence is no longer needed. Any future feature/* branch
# that somehow appears falls through to canonical resolution, where
# ensure_worktree creates a fresh worktree off origin/main — a clean
# error surface, not a silent dispatch into $TARGET_REPO.
branch=""
worktree_path=""
if [[ "$reconcile_decision" == "proceed" ]]; then
  branch="$(bash "$SCRIPT_DIR/branch-name.sh" "$issue_id")"
  worktree_path="$(resolve_worktree_path "$branch" "$issue_id")"
  mkdir -p "$(dirname "$worktree_path")"
  ensure_worktree "$branch" "$worktree_path"
fi

# After ENG-67, every reconcile_decision=="proceed" tick resolves a
# per-issue worktree_path; the link:/human reconcile branches `exit 0`
# at lines 177-205 before reaching here. So the previous fallback
# `dispatch_cwd=$TARGET_REPO` is unreachable by construction. Surface
# any future regression that lets worktree_path stay empty as a loud
# failure rather than a silent dispatch into the operator's checkout.
[[ -n "$worktree_path" ]] || die "internal: worktree_path empty after reconcile=proceed (ENG-67); refusing to dispatch from \$TARGET_REPO"
dispatch_cwd="$worktree_path"

# Tick-start dirty-path snapshot for self-leak detection (ENG-14 D-4).
# Any out-of-scope path present at end-of-tick that is NOT in this
# snapshot must have been introduced by the bot — hard-fail on first
# occurrence after partition.
snapshot_file="$(mktemp -t twinning-snapshot.XXXXXX)"
TWINNING_SWEEP_TMPS+=("$snapshot_file")
git -C "$dispatch_cwd" status -z --porcelain \
  | awk 'BEGIN{RS="\\0"} skip==1 { print; skip=0; next }
         length >= 4 { print substr($0, 4); if ($0 ~ /^(R|C)/) skip=1 }' \
  | sort -u > "$snapshot_file"

set +e
(cd "$dispatch_cwd" && bash "$SCRIPT_DIR/run-stage.sh" "$issue_id" "$stage")
rc=$?
set -e

# Tick-end .scratch/ cleanup — runs BEFORE the rc-gate below so it
# fires on EVERY post-dispatch path including agent failures (timeout
# rc=124, envelope validator rc=29, scope-check rc=21, crashes).
# Placing this AFTER the rc-gate (as in the original v3 patch) leaves
# stale .scratch/ payload across operator --action continue resumes
# on the failure path, re-opening the cross-dispatch state-injection
# vector this helper exists to close. .scratch/ is gitignored, has no
# upstream consumer regardless of dispatch outcome, and the cleanup
# is rc=0 always (failures are non-blocking and logged).
clean_scratch_dir "$dispatch_cwd"

# ENG-69: route the run-stage exit through the per-issue/global lane
# split. rc=24 (linear-post-failed) accumulates against the global
# counter and trips the breaker at threshold; every other non-zero rc
# accumulates against the issue's per-issue counter and halts only that
# issue at threshold. rc=0 clears both counters.
route_run_stage_exit "$issue_id" "$stage" "$rc"
[[ $rc -ne 0 ]] && exit $rc

# 3-stream partition sweep (ENG-14 D-3).
in_scope_file="$(mktemp -t twinning-inscope.XXXXXX)"
leaked_file="$(mktemp -t twinning-leaked.XXXXXX)"
out_scope_file="$(mktemp -t twinning-outscope.XXXXXX)"
TWINNING_SWEEP_TMPS+=("$in_scope_file" "$leaked_file" "$out_scope_file")
: > "$in_scope_file" "$leaked_file" "$out_scope_file"

git -C "$dispatch_cwd" status -z --porcelain \
  | partition_dirty_paths "$stage" "$issue_id" \
      3>"$in_scope_file" 4>"$leaked_file" 5>"$out_scope_file"

in_scope_count="$(tr -cd '\0' < "$in_scope_file" | wc -c | tr -d ' ')"
leaked_count="$(tr -cd '\0' < "$leaked_file" | wc -c | tr -d ' ')"
observed_count="$(tr -cd '\0' < "$out_scope_file" | wc -c | tr -d ' ')"

# Classify out-of-scope into bucketed-observed (pre-existing, present in
# tick-start snapshot) vs self-leak (NEW since tick start). Task 10 decides
# what to do with each.
observed_buckets=()
self_leak_hashes=()
self_leak_paths=()
if (( observed_count > 0 )); then
  while IFS= read -r -d '' p; do
    if grep -qxF -- "$p" "$snapshot_file"; then
      b="$(bucket_for_path "$p")"
      if (( ${#observed_buckets[@]} == 0 )); then
        observed_buckets+=("$b")
      else
        seen=0
        for existing in "${observed_buckets[@]}"; do
          [[ "$existing" == "$b" ]] && { seen=1; break; }
        done
        (( seen )) || observed_buckets+=("$b")
      fi
    else
      self_leak_hashes+=("$(sha12 "$p")")
      self_leak_paths+=("$p")
    fi
  done < "$out_scope_file"
fi

# Tick-end .scratch/ cleanup. Stage-agnostic — runs BEFORE the
# precedence block so it executes regardless of the halt/commit path
# chosen below. .scratch/ is gitignored and therefore invisible to
# git status / partition / self_leak_paths on every stage; without
# this cleanup, an agent's verification scratch persists across
# dispatches and creates a cross-dispatch state-injection vector
# (planted file readable by subsequent agents via Read). The agent's
# work product is in Linear comments + stage-summary outside the
# worktree, not in .scratch/.
clean_scratch_dir "$dispatch_cwd"

# Precedence: self-leak (hard-fail) > leaked-in-scope (counter+conditional
# trip) > in-scope commit > observed bucketed (info only). Brainstorm OQ-4.

# 1. Self-leak has highest severity. For implementing|ui|qa (where
#    the allowlist is real signal) halt the affected issue via
#    classify_failure (skip-until-human-acts); the global breaker stays
#    untouched so other issues keep polling. (ENG-69 lane separation —
#    helper owns metric emit, hash truncation, and reason rendering.)
#
#    For reviewing|building|released (stage_is_read_mostly — the
#    contract guarantees no legitimate worktree writes) the residue
#    is agent verification scratch with no upstream consumer. The
#    verdict + stage summary are already in Linear. Clean the
#    self-leak paths and continue the tick instead of halting —
#    eliminates the operator-touch halt that ENG-96's reviewer
#    triggered with .scratch/bte_*.md + tmp-awk-dup-test.md
#    verification fixtures.
#
#    Snapshot safety: self_leak_paths are by construction NEW since
#    tick-start (the observed-vs-self-leak classification above
#    already filtered out paths present at tick-start). The
#    operator's pre-existing 'observed' edits are NEVER in this list
#    and therefore NEVER touched by the clean.
if (( ${#self_leak_hashes[@]} > 0 )); then
  if stage_is_read_mostly "$stage"; then
    clean_self_leak_residue "$issue_id" "$stage" "$dispatch_cwd" "${self_leak_paths[@]}"
  else
    halt_issue_for_self_leak "$issue_id" "$stage" "${self_leak_hashes[@]}"
    [[ "$PIPELINE_DRY_RUN" != "1" ]] && exit 1
  fi
fi

# 2. Leaked-in-scope: soft failure. Tally against the per-issue counter
#    and escalate to a per-issue halt at threshold. The global breaker
#    is no longer touched on this lane (ENG-69). Leaves in-scope paths
#    un-committed regardless of escalation.
if (( leaked_count > 0 )); then
  leaked_hashes=""
  while IFS= read -r -d '' p; do
    h="$(sha12 "$p")"
    leaked_hashes="${leaked_hashes:+${leaked_hashes},}${h}"
  done < "$leaked_file"
  tally_leaked_in_scope_failure "$issue_id" "$stage" "$leaked_count" "$leaked_hashes"
  [[ "$PIPELINE_DRY_RUN" != "1" ]] && exit 1
fi

# 3. Clean tick: commit in-scope artifacts if any.
if (( in_scope_count > 0 )); then
  if [[ "$PIPELINE_DRY_RUN" == "1" ]]; then
    log "[DRY_RUN] would git add -- ($in_scope_count paths):"
    tr '\0' '\n' < "$in_scope_file" | sed 's/^/[DRY_RUN]   /' >&2
  else
    log "committing pipeline artifacts for $issue_id / $stage ($in_scope_count paths)"
    (cd "$dispatch_cwd" && xargs -0 git add -- < "$in_scope_file")
    git -C "$dispatch_cwd" \
      -c user.name="$BOT_NAME" \
      -c user.email="$BOT_EMAIL" \
      commit -m "chore(pipeline): $stage for $issue_id"
    # -u origin HEAD: sets (or retargets) upstream to origin/<current-branch>. Without
    # this, `git push` inherits push.default=simple behaviour and refuses when the
    # branch was created off origin/main (see ensure_worktree above). Idempotent for
    # already-correctly-tracked branches.
    git -C "$dispatch_cwd" push -u origin HEAD
  fi
else
  log "no in-scope artifacts to commit"
fi

# 4. Observed bucketed (info only — user concurrent work, no breaker).
if (( ${#observed_buckets[@]} > 0 )); then
  observed_buckets_csv=""
  for b in "${observed_buckets[@]}"; do
    observed_buckets_csv="${observed_buckets_csv:+${observed_buckets_csv},}${b}"
  done
  bash "$SCRIPT_DIR/metrics.sh" sweep-observed-out-of-scope "$issue_id" "$stage" \
    "observed" 0 "count=${#observed_buckets[@]} buckets=${observed_buckets_csv}" \
    || log "metrics.sh sweep-observed-out-of-scope emission failed (non-blocking)"
fi

# Release watcher: detect newly-published GitHub releases and trigger the local
# on-new-release handler (sweep + observer agent). Replaces the old
# pipeline-release.yml workflow. Cheap: one `gh api` call per tick.
LAST_RELEASE_FILE="$PROJECT_STATE_DIR/last-observed-release"
if command -v gh >/dev/null 2>&1; then
  latest_release_json="$(gh release list --limit 1 --json tagName,name 2>/dev/null || printf '[]')"
  latest_tag="$(jq -r '.[0].tagName // ""' <<<"$latest_release_json")"
  if [[ -n "$latest_tag" ]]; then
    prev_tag=""
    [[ -f "$LAST_RELEASE_FILE" ]] && prev_tag="$(cat "$LAST_RELEASE_FILE")"
    if [[ "$latest_tag" != "$prev_tag" ]]; then
      # Version is the tag minus the leading `v`.
      latest_version="${latest_tag#v}"
      log "release watcher: detected new release $latest_tag (was: ${prev_tag:-none})"
      if bash "$SCRIPT_DIR/on-new-release.sh" "$latest_version" "$latest_tag"; then
        printf '%s\n' "$latest_tag" > "$LAST_RELEASE_FILE"
      else
        log "on-new-release.sh exited nonzero for $latest_tag; will retry next tick"
      fi
    fi
  fi
else
  log "release watcher: gh CLI not on PATH; skipping"
fi

# Periodic worktree sweep (every N ticks).
tick_count=0
if [[ -f "$TICK_COUNTER" ]]; then
  tick_count="$(cat "$TICK_COUNTER")"
fi
tick_count=$((tick_count + 1))
if (( tick_count % CLEANUP_EVERY_N_TICKS == 0 )); then
  log "periodic sweep: running cleanup-worktrees.sh"
  bash "$SCRIPT_DIR/cleanup-worktrees.sh" || log "cleanup-worktrees.sh exited nonzero (non-fatal)"
fi
printf '%s\n' "$tick_count" > "$TICK_COUNTER"

log "== tick end (success) =="
