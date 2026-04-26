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

# launchd hands us a minimal PATH. Prepend the places the tools actually live on
# macOS (Homebrew on Apple Silicon + Intel, npm/bun user-global bins). The plist
# also sets PATH; this is belt-and-braces so the script works if invoked manually.
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:$HOME/.bun/bin:$HOME/.npm-global/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"
# shellcheck source=run-local-helpers.sh
source "$SCRIPT_DIR/run-local-helpers.sh"

LOCK_DIR="$PROJECT_STATE_DIR/.run-local.lock"
ENV_FILE="$TARGET_CONFIG_DIR/.env.local"
FAIL_COUNTER="$PROJECT_STATE_DIR/.consecutive-failures"
FAIL_THRESHOLD=3
TICK_COUNTER="$PROJECT_STATE_DIR/.tick-counter"
CLEANUP_EVERY_N_TICKS=10
LOG_DIR="$PROJECT_STATE_DIR/logs"
LOG_FILE="$LOG_DIR/local-$(date -u +%Y-%m-%d).log"
BOT_NAME="twinning-pipeline-bot"
BOT_EMAIL="twinning-pipeline-bot@users.noreply.github.com"

trip_breaker() {
  log "CIRCUIT BREAKER: setting orchestrator.paused=true after $FAIL_THRESHOLD consecutive failures"
  # Surgical edit (not jq-write) so formatting/blank lines in config.json are preserved.
  # Relies on the single `"paused": false` occurrence under orchestrator.
  if grep -q '"paused": false' "$CONFIG"; then
    sed -i.bak 's/"paused": false/"paused": true/' "$CONFIG"
    rm -f "${CONFIG}.bak"
  else
    log "trip_breaker: could not find '\"paused\": false' in $CONFIG; leaving as-is"
  fi
}

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

paused="$(config_get '.orchestrator.paused')"
if [[ "$paused" == "true" ]]; then
  log "tick skipped: orchestrator.paused=true"
  log "reset with: jq '.orchestrator.paused=false' $CONFIG > /tmp/c && mv /tmp/c $CONFIG"
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
    brainstorm) label_suffix=brainstorming ;;
    plan)       label_suffix=planning ;;
    implement)  label_suffix=implementing ;;
    ui)         label_suffix=ui ;;
    review)     label_suffix=reviewing ;;
    qa)         label_suffix=qa ;;
    build)      label_suffix=building ;;
    release)    label_suffix=released ;;
    *)          label_suffix="$stage" ;;
  esac
  active_state="$(config_get '.linear.native_states.active')"
  bash "$SCRIPT_DIR/linear.sh" transition-state "$issue_id" "$active_state"
  bash "$SCRIPT_DIR/linear.sh" add-label "$issue_id" "stage:$label_suffix"
fi

reconcile_decision="proceed"
if [[ "$stage" == "brainstorm" || "$stage" == "plan" ]]; then
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
      brainstorm) nxt_label="planning" ;;
      plan)       nxt_label="implementing" ;;
      *)          nxt_label="" ;;
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

# Determine branch name and worktree path. Only for new-model branches; for
# legacy feature/* in-flight, skip worktree creation and fall through.
branch=""
worktree_path=""
if [[ "$reconcile_decision" == "proceed" ]]; then
  # Legacy-branch coexistence: if a feature/<issue> branch already exists
  # locally or on origin, use the old flow for this issue.
  ident_lower="$(tr '[:upper:]' '[:lower:]' <<<"$issue_id")"
  if [[ -n "$(git -C "$TARGET_REPO" branch --list "feature/${ident_lower}-*" 2>/dev/null)" ]] \
     || git -C "$TARGET_REPO" ls-remote --heads origin "feature/${ident_lower}-*" 2>/dev/null | grep -q "feature/"; then
    log "legacy feature/* branch detected for $issue_id — using old flow (no worktree)"
  else
    branch="$(bash "$SCRIPT_DIR/branch-name.sh" "$issue_id")"
    worktree_path="$(resolve_worktree_path "$branch" "$issue_id")"
    mkdir -p "$(dirname "$worktree_path")"
    ensure_worktree "$branch" "$worktree_path"
  fi
fi

# Dispatch run-stage.sh from the worktree if one was resolved, else from main.
dispatch_cwd="$TARGET_REPO"
if [[ -n "$worktree_path" ]]; then
  dispatch_cwd="$worktree_path"
fi

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

if [[ $rc -ne 0 ]]; then
  count="$(cat "$FAIL_COUNTER" 2>/dev/null || echo 0)"
  count=$((count + 1))
  printf '%s\n' "$count" > "$FAIL_COUNTER"
  log "run-stage.sh exited $rc; consecutive failures = $count"
  if (( count >= FAIL_THRESHOLD )); then
    trip_breaker
  fi
  exit $rc
fi

rm -f "$FAIL_COUNTER"

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
    fi
  done < "$out_scope_file"
fi

# Precedence: self-leak (hard-fail) > leaked-in-scope (counter+conditional
# trip) > in-scope commit > observed bucketed (info only). Brainstorm OQ-4.

# 1. Self-leak has highest severity. Emit metric, trip breaker, exit.
if (( ${#self_leak_hashes[@]} > 0 )); then
  leak_csv=""
  for h in "${self_leak_hashes[@]}"; do
    leak_csv="${leak_csv:+${leak_csv},}${h}"
  done
  bash "$SCRIPT_DIR/metrics.sh" sweep-self-leak-out-of-scope "$issue_id" "$stage" \
    "self-leak" 0 "count=${#self_leak_hashes[@]} hashes=${leak_csv}" \
    || log "metrics.sh sweep-self-leak-out-of-scope emission failed (non-blocking)"
  log "SELF-LEAK: ${#self_leak_hashes[@]} bot-introduced out-of-scope path(s); tripping breaker (in-scope paths NOT committed)"
  if [[ "$PIPELINE_DRY_RUN" != "1" ]]; then
    trip_breaker
    exit 1
  fi
fi

# 2. Leaked-in-scope: soft failure. Emit metric, increment counter, trip
#    breaker only at threshold, exit. Leaves in-scope paths un-committed.
if (( leaked_count > 0 )); then
  leaked_hashes=""
  while IFS= read -r -d '' p; do
    h="$(sha12 "$p")"
    leaked_hashes="${leaked_hashes:+${leaked_hashes},}${h}"
  done < "$leaked_file"
  bash "$SCRIPT_DIR/metrics.sh" sweep-leaked-in-scope "$issue_id" "$stage" \
    "leak" 0 "count=${leaked_count} hashes=${leaked_hashes}" \
    || log "metrics.sh sweep-leaked-in-scope emission failed (non-blocking)"
  if [[ "$PIPELINE_DRY_RUN" != "1" ]]; then
    fc="$(cat "$FAIL_COUNTER" 2>/dev/null || echo 0)"
    fc=$((fc + 1))
    printf '%s\n' "$fc" > "$FAIL_COUNTER"
    log "sweep-leaked-in-scope: $leaked_count path(s); consecutive failures = $fc (in-scope paths NOT committed)"
    if (( fc >= FAIL_THRESHOLD )); then
      trip_breaker
    fi
    exit 1
  fi
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
