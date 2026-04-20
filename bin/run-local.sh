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

LOCK_DIR="$TWINNING_DIR/.run-local.lock"
ENV_FILE="$PIPELINE_ROOT/.env.local"
FAIL_COUNTER="$TWINNING_DIR/.consecutive-failures"
FAIL_THRESHOLD=3
TICK_COUNTER="$TWINNING_DIR/.tick-counter"
CLEANUP_EVERY_N_TICKS=10
LOG_DIR="$REPO_ROOT/logs/pipeline"
LOG_FILE="$LOG_DIR/local-$(date -u +%Y-%m-%d).log"
BOT_NAME="twinning-pipeline-bot"
BOT_EMAIL="twinning-pipeline-bot@users.noreply.github.com"

stage_output_paths() {
  local stage="$1" issue_id="$2"
  # Always-staged (common to all stages).
  local common=()
  # Per-stage allowlists. Directory entries end in /.
  case "$stage" in
    brainstorm)
      printf 'docs/brainstorms/\n'
      printf 'docs/knowledge/decisions.md\n'
      ;;
    plan)
      printf 'docs/plans/\n'
      ;;
    implement|ui|qa)
      # Implement/UI/QA commit their own work via Bash(git:*); run-local
      # sweep here should ONLY pick up anything the agent left behind. Keep
      # the allowlist broad for these so legitimate edits aren't dropped.
      printf 'src/\n'
      printf 'src-tauri/\n'
      printf 'crates/\n'
      printf 'tests/\n'
      printf 'docs/\n'
      printf 'package.json\n'
      printf 'package-lock.json\n'
      printf 'bun.lock\n'
      printf 'bun.lockb\n'
      printf 'Cargo.toml\n'
      printf 'Cargo.lock\n'
      ;;
    retrospective)
      printf '.pipeline/learned-rules/\n'
      printf 'docs/knowledge/gotchas.md\n'
      printf 'docs/knowledge/qa-patterns.md\n'
      printf 'docs/knowledge/conventions.md\n'
      printf 'docs/knowledge/decisions.md\n'
      printf '.pipeline/AGENT_PROMPTS.md\n'
      printf '.pipeline/config.json\n'
      printf '.github/workflows/\n'
      ;;
    review|build|release)
      # Read-mostly stages; nothing to sweep.
      ;;
    *)
      ;;
  esac
}

stage_in_scope() {
  # $1=dirty_path, $2=stage, $3=issue_id
  local path="$1" stage="$2" issue_id="$3"
  while IFS= read -r allow; do
    [[ -z "$allow" ]] && continue
    if [[ "$allow" == */ ]]; then
      # Directory prefix match with path boundary.
      [[ "$path" == "$allow"* ]] && return 0
    else
      # Exact file match.
      [[ "$path" == "$allow" ]] && return 0
    fi
  done < <(stage_output_paths "$stage" "$issue_id")
  return 1
}

acquire_lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '%s\n' $$ > "$LOCK_DIR/pid"
    return 0
  fi
  # Existing lock: break it if the holder process is gone.
  local holder
  holder="$(cat "$LOCK_DIR/pid" 2>/dev/null || echo 0)"
  if [[ "$holder" =~ ^[0-9]+$ ]] && (( holder > 0 )) && ! kill -0 "$holder" 2>/dev/null; then
    rm -rf "$LOCK_DIR"
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      printf '%s\n' $$ > "$LOCK_DIR/pid"
      log "broke stale lock held by dead pid $holder"
      return 0
    fi
  fi
  return 1
}

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

mkdir -p "$TWINNING_DIR"

if ! acquire_lock; then
  # Silent skip: overlapping tick is expected if a stage runs >5 min.
  exit 0
fi
trap 'rm -rf "$LOCK_DIR"' EXIT

mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

log "== tick start =="

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi
require_env LINEAR_API_KEY
require_env GH_APP_ID GH_APP_INSTALLATION_ID GH_APP_PRIVATE_KEY_PATH
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
  if git -C "$REPO_ROOT" rev-parse --verify "refs/heads/$branch" >/dev/null 2>&1; then
    log "branch exists locally; creating worktree at $path pointing at $branch"
    git -C "$REPO_ROOT" worktree add "$path" "$branch"
  elif git -C "$REPO_ROOT" rev-parse --verify "refs/remotes/origin/$branch" >/dev/null 2>&1; then
    log "branch exists on origin; creating worktree at $path tracking origin/$branch"
    git -C "$REPO_ROOT" worktree add "$path" -b "$branch" "origin/$branch"
  else
    log "creating new branch $branch and worktree at $path from origin/main"
    git -C "$REPO_ROOT" fetch origin main
    # --no-track: branching off a remote-tracking ref (origin/main) otherwise wires
    # the new branch's upstream to origin/main, which makes later `git push` fail
    # with "upstream branch of your current branch does not match the name" under
    # the default push.default=simple. The first push below uses `-u origin HEAD` to
    # set the correct upstream to origin/<branch>.
    git -C "$REPO_ROOT" worktree add --no-track "$path" -b "$branch" origin/main
  fi
}

cd "$REPO_ROOT"

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
  if [[ -n "$(git -C "$REPO_ROOT" branch --list "feature/${ident_lower}-*" 2>/dev/null)" ]] \
     || git -C "$REPO_ROOT" ls-remote --heads origin "feature/${ident_lower}-*" 2>/dev/null | grep -q "feature/"; then
    log "legacy feature/* branch detected for $issue_id — using old flow (no worktree)"
  else
    branch="$(bash "$SCRIPT_DIR/branch-name.sh" "$issue_id")"
    worktree_path="$(resolve_worktree_path "$branch" "$issue_id")"
    mkdir -p "$(dirname "$worktree_path")"
    ensure_worktree "$branch" "$worktree_path"
  fi
fi

# Dispatch run-stage.sh from the worktree if one was resolved, else from main.
dispatch_cwd="$REPO_ROOT"
if [[ -n "$worktree_path" ]]; then
  dispatch_cwd="$worktree_path"
fi

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

if [[ -n "$(git -C "$dispatch_cwd" status --porcelain)" ]]; then
  # D-001 allowlist: only stage files the stage is expected to produce.
  in_scope=()
  out_of_scope=()
  while IFS= read -r line; do
    # Porcelain format: "XY path" where XY is 2-char status.
    path="${line:3}"
    if stage_in_scope "$path" "$stage" "$issue_id"; then
      in_scope+=("$path")
    else
      out_of_scope+=("$path")
    fi
  done < <(git -C "$dispatch_cwd" status --porcelain)

  if (( ${#out_of_scope[@]} > 0 )); then
    log "sweep: ${#out_of_scope[@]} out-of-scope dirty paths (NOT staged): ${out_of_scope[*]}"
    bash "$SCRIPT_DIR/metrics.sh" sweep-observed-out-of-scope "$issue_id" "$stage" "observed" 0 "count=${#out_of_scope[@]}"
  fi

  if (( ${#in_scope[@]} > 0 )); then
    log "sweep: staging ${#in_scope[@]} in-scope paths for $issue_id / $stage"
    (cd "$dispatch_cwd" && git add -- "${in_scope[@]}")
    git -C "$dispatch_cwd" \
      -c user.name="$BOT_NAME" \
      -c user.email="$BOT_EMAIL" \
      commit -m "chore(pipeline): $stage for $issue_id"
    # -u origin HEAD: sets (or retargets) upstream to origin/<current-branch>. Without
    # this, `git push` inherits push.default=simple behaviour and refuses when the
    # branch was created off origin/main (see ensure_worktree above). Idempotent for
    # already-correctly-tracked branches.
    git -C "$dispatch_cwd" push -u origin HEAD
  else
    log "no in-scope artifacts to commit"
  fi
else
  log "no artifacts to commit"
fi

# Release watcher: detect newly-published GitHub releases and trigger the local
# on-new-release handler (sweep + observer agent). Replaces the old
# pipeline-release.yml workflow. Cheap: one `gh api` call per tick.
LAST_RELEASE_FILE="$TWINNING_DIR/last-observed-release"
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
