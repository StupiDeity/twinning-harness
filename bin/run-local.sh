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

_write_tick_heartbeat() {
  local heartbeat_file="$PROJECT_STATE_DIR/.last-tick-end"
  local tmp="${heartbeat_file}.tmp.$$"
  if date -u +%Y-%m-%dT%H:%M:%SZ > "$tmp" 2>/dev/null \
     && mv -f "$tmp" "$heartbeat_file" 2>/dev/null; then
    return 0
  fi
  log "heartbeat write failed (continuing tick)"
  rm -f "$tmp" 2>/dev/null || true
  return 0
}

if ! acquire_lock "$LOCK_DIR"; then
  # Silent skip: overlapping tick is expected if a stage runs >5 min.
  exit 0
fi

# Bash traps are NOT stacked — a later `trap ... EXIT` REPLACES this one.
# Register sweep tempfiles in TWINNING_SWEEP_TMPS so they are reaped here.
TWINNING_SWEEP_TMPS=()

# Track scheduler-acquired per-issue in-flight locks so cleanup_on_exit
# can reap any that did NOT successfully hand off to a forked worker.
# The scheduler pushes here right after every try_acquire_lock claim and
# CLEARS the array just before forking; workers re-trap EXIT with their
# own release inside the subshell.
_SCHEDULER_INFLIGHT_LOCKS=()
cleanup_on_exit() {
  rm -rf "$LOCK_DIR"
  local _l
  for _l in "${_SCHEDULER_INFLIGHT_LOCKS[@]+"${_SCHEDULER_INFLIGHT_LOCKS[@]}"}"; do
    release_lock "$_l"
  done
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
  _write_tick_heartbeat
  exit 0
fi

# ─── Worktree resolution (ENG-15: per-issue dir layout) ────────────────
# Worktrees now live under ~/.twinning-pipeline/ENG-N/worktree/ alongside
# issue-state.json + scope-approval. Parent is created on demand.
resolve_worktree_path() {
  local issue="$1"
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

# ─── ENG-81: per-worker arm ────────────────────────────────────────────
# Runs in a forked subshell, one per (issue, stage) decision claimed by
# the scheduler. Performs everything that pre-ENG-81 lived inline in
# run-local.sh's main body: tick-start snapshot, run-stage dispatch,
# scratch cleanup, lane-routed exit, 3-stream partition sweep,
# observed-vs-self-leak classification, halt/commit/push.
#
# Per-issue locks/state mutations are owned by the called helpers
# (route_run_stage_exit, halt_issue_for_self_leak,
# tally_leaked_in_scope_failure). Workers do NOT mutate
# TWINNING_SWEEP_TMPS or any shared scheduler state — local arrays only.
#
# The wire-up patterns the run-local-helpers-adversarial-test.sh greps
# (#1-#6) live in this function body so the existing pins keep
# anchoring the same invariants.
_run_worker() {
  local issue_id="$1" stage="$2" dispatch_cwd="$3"

  # Per-worker log file (Phase 3c). Replaces the shared daily log
  # INSIDE the worker subshell. Scheduler-side messages still land in
  # $LOG_FILE.
  local worker_log="$LOG_DIR/local-$(date -u +%Y-%m-%d)-${issue_id}.log"
  exec > >(tee -a "$worker_log") 2>&1
  log "== worker start: $issue_id / $stage =="

  # Tick-start dirty-path snapshot for self-leak detection (ENG-14 D-4).
  local snapshot_file
  snapshot_file="$(mktemp -t twinning-snapshot.XXXXXX)"
  local _worker_tmps=("$snapshot_file")
  git -C "$dispatch_cwd" status -z --porcelain \
    | awk 'BEGIN{RS="\\0"} skip==1 { print; skip=0; next }
           length >= 4 { print substr($0, 4); if ($0 ~ /^(R|C)/) skip=1 }' \
    | sort -u > "$snapshot_file"

  set +e
  (cd "$dispatch_cwd" && bash "$SCRIPT_DIR/run-stage.sh" "$issue_id" "$stage")
  local rc=$?
  set -e

  # Tick-end .scratch/ cleanup — MUST appear BEFORE the rc-gate below
  # so it fires on EVERY post-dispatch path including agent failures
  # (timeout rc=124, envelope validator rc=29, scope-check rc=21,
  # crashes). Placing this AFTER the rc-gate would leak stale
  # .scratch/ across operator --action continue resumes on failure
  # paths. .scratch/ is gitignored; cleanup is rc=0 always.
  clean_scratch_dir "$dispatch_cwd"

  # ENG-69: route the run-stage exit through the per-issue/global lane
  # split. rc=24 (linear-post-failed) → global counter; every other
  # non-zero rc → per-issue counter; rc=0 clears both.
  route_run_stage_exit "$issue_id" "$stage" "$rc"
  # Reap tempfiles on every non-zero exit (timeout, envelope, scope, crash).
  # Single-line form matches the wire-up anchor regex
  # `[[ $rc -ne 0 ]]; then return $rc`.
  if [[ $rc -ne 0 ]]; then rm -f "${_worker_tmps[@]}"; return $rc; fi

  # 3-stream partition sweep (ENG-14 D-3).
  local in_scope_file leaked_file out_scope_file
  in_scope_file="$(mktemp -t twinning-inscope.XXXXXX)"
  leaked_file="$(mktemp -t twinning-leaked.XXXXXX)"
  out_scope_file="$(mktemp -t twinning-outscope.XXXXXX)"
  _worker_tmps+=("$in_scope_file" "$leaked_file" "$out_scope_file")
  : > "$in_scope_file" "$leaked_file" "$out_scope_file"

  git -C "$dispatch_cwd" status -z --porcelain \
    | partition_dirty_paths "$stage" "$issue_id" \
        3>"$in_scope_file" 4>"$leaked_file" 5>"$out_scope_file"

  local in_scope_count leaked_count observed_count
  in_scope_count="$(tr -cd '\0' < "$in_scope_file" | wc -c | tr -d ' ')"
  leaked_count="$(tr -cd '\0' < "$leaked_file" | wc -c | tr -d ' ')"
  observed_count="$(tr -cd '\0' < "$out_scope_file" | wc -c | tr -d ' ')"

  # Classify out-of-scope into bucketed-observed (pre-existing, present
  # in tick-start snapshot) vs self-leak (NEW since tick start).
  # Review-3 minor #11: bucket de-duplication is `sort -u` on a tempfile
  # rather than the prior manual seen-flag inner loop. Same behavior;
  # less code; pattern matches the rest of the helpers (every other
  # multiset dedup in run-local-helpers.sh uses `sort -u`).
  local -a observed_buckets=()
  local -a self_leak_hashes=()
  local -a self_leak_paths=()
  if (( observed_count > 0 )); then
    local buckets_raw
    buckets_raw="$(mktemp -t twinning-buckets.XXXXXX)"
    _worker_tmps+=("$buckets_raw")
    local p
    while IFS= read -r -d '' p; do
      if grep -qxF -- "$p" "$snapshot_file"; then
        bucket_for_path "$p" >> "$buckets_raw"
      else
        self_leak_hashes+=("$(sha12 "$p")")
        self_leak_paths+=("$p")
      fi
    done < "$out_scope_file"
    if [[ -s "$buckets_raw" ]]; then
      local b
      while IFS= read -r b; do
        [[ -n "$b" ]] && observed_buckets+=("$b")
      done < <(sort -u "$buckets_raw")
    fi
  fi

  # Precedence: self-leak (hard-fail) > leaked-in-scope > in-scope
  # commit > observed bucketed.
  if (( ${#self_leak_hashes[@]} > 0 )); then
    if stage_auto_cleans_self_leak "$stage"; then
      clean_self_leak_residue "$issue_id" "$stage" "$dispatch_cwd" "${self_leak_paths[@]}"
    else
      halt_issue_for_self_leak "$issue_id" "$stage" "${self_leak_hashes[@]}"
      if [[ "$PIPELINE_DRY_RUN" != "1" ]]; then
        rm -f "${_worker_tmps[@]}"
        log "== worker end: $issue_id / $stage (self-leak halt) =="
        return 1
      fi
    fi
  fi

  if (( leaked_count > 0 )); then
    local leaked_hashes="" h p
    while IFS= read -r -d '' p; do
      h="$(sha12 "$p")"
      leaked_hashes="${leaked_hashes:+${leaked_hashes},}${h}"
    done < "$leaked_file"
    tally_leaked_in_scope_failure "$issue_id" "$stage" "$leaked_count" "$leaked_hashes"
    if [[ "$PIPELINE_DRY_RUN" != "1" ]]; then
      rm -f "${_worker_tmps[@]}"
      log "== worker end: $issue_id / $stage (leaked-in-scope tally) =="
      return 1
    fi
  fi

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
      git -C "$dispatch_cwd" push -u origin HEAD
    fi
  else
    log "no in-scope artifacts to commit"
  fi

  if (( ${#observed_buckets[@]} > 0 )); then
    local observed_buckets_csv="" b
    for b in "${observed_buckets[@]}"; do
      observed_buckets_csv="${observed_buckets_csv:+${observed_buckets_csv},}${b}"
    done
    bash "$SCRIPT_DIR/metrics.sh" sweep-observed-out-of-scope "$issue_id" "$stage" \
      "observed" 0 "count=${#observed_buckets[@]} buckets=${observed_buckets_csv}" \
      || log "metrics.sh sweep-observed-out-of-scope emission failed (non-blocking)"
  fi

  rm -f "${_worker_tmps[@]}"
  log "== worker end: $issue_id / $stage (success) =="
  return 0
}

cd "$TARGET_REPO"

# ─── ENG-81 scheduler arm: poll up to K decisions, claim per-issue
# locks, ensure worktrees, fork workers, wait for all ─────────────────
K="$(_resolve_K)"
log "scheduler: K=$K (concurrency cap)"

# poll.sh emits an array when --max > 1; a single object when --max == 1.
if (( K == 1 )); then
  decision="$(bash "$SCRIPT_DIR/poll.sh")"
  decisions_json="[$decision]"
else
  decisions_json="$(bash "$SCRIPT_DIR/poll.sh" --max "$K")"
fi
log "poll decisions: $decisions_json"

# Filter null/empty (idle) decisions. poll.sh's idle() branch emits a
# single JSON object (not an array) regardless of --max; wrap defensively
# so arrays pass through and anything else collapses to [].
decisions_json="$(jq -c '(if type == "array" then . else [] end) | [.[] | select(.issue_id != null and .issue_id != "")]' <<<"$decisions_json")"
decisions_count="$(jq 'length' <<<"$decisions_json")"
if (( decisions_count == 0 )); then
  log "no work this tick"
  _write_tick_heartbeat
  exit 0
fi

# Per-decision: handle entry-action, reconcile, ensure worktree,
# claim per-issue .in-flight.lock. Releases the lock if this decision
# short-circuits (link/human reconcile path).
declare -a _claimed_workers=()   # entries: "<issue>|<stage>|<worktree>|<lock_dir>"
for di in $(seq 0 $((decisions_count - 1))); do
  decision="$(jq -c ".[$di]" <<<"$decisions_json")"
  issue_id="$(jq -r '.issue_id' <<<"$decision")"
  stage="$(jq -r '.stage' <<<"$decision")"
  entry_action="$(jq -r '.entry_action // "run"' <<<"$decision")"

  # Acquire the per-issue .in-flight.lock as late as possible — after
  # every error-prone scheduler-side call (linear.sh, reconcile.sh,
  # branch-name.sh, resolve_worktree_path, ensure_worktree) so a
  # transient failure does not orphan the lock and silently skip the
  # issue on every subsequent tick.
  if [[ "$entry_action" == "apply-stage-label" ]]; then
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
    log "reconcile decision ($issue_id): $reconcile_decision"
  fi

  case "$reconcile_decision" in
    link:*)
      doc_path="${reconcile_decision#link:}"
      bash "$SCRIPT_DIR/linear.sh" add-comment "$issue_id" \
        "Pipeline reconcile: existing $stage doc is canonical: \`$doc_path\`. Advancing without regeneration."
      case "$stage" in
        brainstorming) nxt_label="planning" ;;
        planning)      nxt_label="implementing" ;;
        *)             nxt_label="" ;;
      esac
      [[ -n "$nxt_label" ]] && bash "$SCRIPT_DIR/linear.sh" swap-stage "$issue_id" "$nxt_label"
      bash "$SCRIPT_DIR/metrics.sh" stage-end "$issue_id" "$stage" "linked" 0 "doc=$doc_path"
      continue
      ;;
    human)
      bash "$SCRIPT_DIR/linear.sh" add-comment "$issue_id" \
        "Pipeline reconcile: an existing $stage doc appears to cover this topic. Apply one of: \`pipeline:supersede\`, \`pipeline:extend\`, or \`pipeline:ignore\`. Until a label is applied, this issue is paused."
      bash "$SCRIPT_DIR/metrics.sh" stage-start "$issue_id" "$stage" "reconcile-human" 0
      bash "$SCRIPT_DIR/metrics.sh" stage-end "$issue_id" "$stage" \
        "reconcile-human" 0 "awaiting=supersede-or-extend-or-ignore" || true
      continue
      ;;
  esac

  # ENG-67 D-004 (set -u safety): initialize worktree_path BEFORE the
  # `resolve_worktree_path` substitution. If a future edit drops the
  # initializer and the substitution fails, the `[[ -n "$worktree_path" ]]`
  # guard would error as "unbound variable" instead of dying with the
  # operator-recognition message — pinned by
  # bin/run-local-content-adversarial-test.sh::AD-4.
  branch="$(bash "$SCRIPT_DIR/branch-name.sh" "$issue_id")"
  worktree_path=""
  worktree_path="$(resolve_worktree_path "$issue_id")"
  mkdir -p "$(dirname "$worktree_path")"
  ensure_worktree "$branch" "$worktree_path"
  [[ -n "$worktree_path" ]] || die "internal: worktree_path empty after reconcile=proceed (ENG-67); refusing to dispatch from \$TARGET_REPO"

  # Now that every error-prone call has succeeded, acquire the per-issue
  # in-flight lock. The window between this line and the worker fork is
  # tiny (one array append); cleanup_on_exit's EXIT trap covers it via
  # _SCHEDULER_INFLIGHT_LOCKS.
  inflight_lock="$(issue_dir "$issue_id")/.in-flight.lock"
  mkdir -p "$(issue_dir "$issue_id")"
  if ! try_acquire_lock "$inflight_lock"; then
    log "scheduler: $issue_id .in-flight.lock held by prior tick worker; skipping this decision"
    continue
  fi
  _SCHEDULER_INFLIGHT_LOCKS+=("$inflight_lock")

  _claimed_workers+=("${issue_id}|${stage}|${worktree_path}|${inflight_lock}")
done

# ─── Periodic worktree sweep (BEFORE fork — Phase 3d) ─────────────────
# Pre-ENG-81 this ran post-dispatch at the end of the tick. Moving it
# here ensures it never races a worker (workers operate on per-issue
# worktrees that cleanup-worktrees.sh would not touch in the same
# tick anyway, but the ordering is the conservative choice).
tick_count=0
[[ -f "$TICK_COUNTER" ]] && tick_count="$(cat "$TICK_COUNTER")"
tick_count=$((tick_count + 1))
if (( tick_count % CLEANUP_EVERY_N_TICKS == 0 )); then
  log "periodic sweep: running cleanup-worktrees.sh (scheduler arm, pre-fork)"
  bash "$SCRIPT_DIR/cleanup-worktrees.sh" || log "cleanup-worktrees.sh exited nonzero (non-fatal)"
fi
printf '%s\n' "$tick_count" > "$TICK_COUNTER"

# ─── Release tick lock BEFORE forking workers ─────────────────────────
# cleanup_on_exit's `rm -rf "$LOCK_DIR"` is idempotent if the dir is
# already gone, so we leave the EXIT trap registered (defensive
# coverage in case a future scheduler-side mutation re-populates
# TWINNING_SWEEP_TMPS).
release_lock "$LOCK_DIR"

if (( ${#_claimed_workers[@]} == 0 )); then
  log "no workers claimed this tick (all decisions short-circuited in scheduler)"
  _write_tick_heartbeat
  exit 0
fi

# Hand off lock ownership to workers. Each worker subshell re-traps EXIT
# with its own release. The scheduler-side `_SCHEDULER_INFLIGHT_LOCKS`
# array stays populated through the fork loop so a `die` between
# `try_acquire_lock` and `( ... ) &` still releases locks of any workers
# already forked. Double-release via worker EXIT trap is a harmless
# `rm -rf` of a freed dir.
for spec in "${_claimed_workers[@]}"; do
  IFS='|' read -r w_issue w_stage w_worktree w_lock <<<"$spec"
  (
    # Worker subshell entry: REPLACE inherited scheduler trap with
    # our own so we release ONLY this issue's per-issue lock on exit.
    trap 'release_lock "'"$w_lock"'"' EXIT
    _run_worker "$w_issue" "$w_stage" "$w_worktree"
  ) &
done

# set +e around wait so a worker's nonzero rc does not kill the
# scheduler before sibling workers finish. Each worker's per-issue
# mutations (counter, halt label, comments) are already done BEFORE
# the subshell exits.
set +e
wait
set -e

# Release watcher: detect newly-published GitHub releases and trigger
# the local on-new-release handler. Replaces the old
# pipeline-release.yml workflow. Cheap: one `gh api` call per tick.
LAST_RELEASE_FILE="$PROJECT_STATE_DIR/last-observed-release"
if command -v gh >/dev/null 2>&1; then
  latest_release_json="$(gh release list --limit 1 --json tagName,name 2>/dev/null || printf '[]')"
  latest_tag="$(jq -r '.[0].tagName // ""' <<<"$latest_release_json")"
  if [[ -n "$latest_tag" ]]; then
    prev_tag=""
    [[ -f "$LAST_RELEASE_FILE" ]] && prev_tag="$(cat "$LAST_RELEASE_FILE")"
    if [[ "$latest_tag" != "$prev_tag" ]]; then
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

log "== tick end (success, ${#_claimed_workers[@]} worker(s)) =="
_write_tick_heartbeat
