#!/usr/bin/env bash
# Periodic sweep. Remove worktrees whose PR merged, whose Linear issue is
# Canceled, or which are 30+ days orphaned.
# Safe to run repeatedly; idempotent. Called from run-local.sh every N ticks.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

require_bin gh jq git

WORKTREES_DIR="$HARNESS_STATE_DIR/worktrees"
[[ -d "$WORKTREES_DIR" ]] || { log "no worktrees dir; nothing to sweep"; exit 0; }

# issue_id_from_branch: "feat/eng-13-foo" → "ENG-13"; empty if no match.
issue_id_from_branch() {
  local branch="$1"
  local m
  m="$(sed -nE 's|^(feat|fix)/(eng-[0-9]+)-.*|\2|pI' <<<"$branch" || true)"
  [[ -n "$m" ]] || return 0
  printf '%s\n' "$(tr '[:lower:]' '[:upper:]' <<<"$m")"
}

remove_tree() {
  local path="$1" branch="$2" reason="$3"
  log "cleanup: removing worktree $path (branch=$branch, reason=$reason)"
  git -C "$TARGET_REPO" worktree remove --force "$path" 2>/dev/null || {
    log "cleanup: git worktree remove failed; forcing rm of $path"
    rm -rf "$path"
  }
  git -C "$TARGET_REPO" branch -D "$branch" 2>/dev/null || true
  bash "$SCRIPT_DIR/metrics.sh" worktree-cleanup "$3" "$branch" "success" 0 "path=$path"
}

# Transition the Linear issue to "Done" if we can resolve an issue ID from
# the branch. Called before remove_tree when the trigger is a merged PR.
# Per ENG-13 D-014: Done is set at actual merge, not when stage:released fires.
transition_done() {
  local issue_id="$1"
  [[ -n "$issue_id" ]] || return 0
  local done_state
  done_state="$(config_get '.linear.native_states.done')"
  bash "$SCRIPT_DIR/linear.sh" transition-state "$issue_id" "$done_state"
  log "cleanup: transitioned $issue_id to Linear state '$done_state'"
}

shopt -s nullglob
for path in "$WORKTREES_DIR"/*/; do
  path="${path%/}"
  # Resolve the branch at this worktree.
  branch="$(git -C "$path" rev-parse --abbrev-ref HEAD 2>/dev/null || echo)"
  [[ -n "$branch" ]] || { log "cleanup: skip $path (not a git worktree)"; continue; }

  # 1. PR merged? If so, transition Linear to Done before removing.
  pr_merged_count="$(gh pr list --head "$branch" --state merged --json number --jq 'length' 2>/dev/null || echo 0)"
  if (( pr_merged_count > 0 )); then
    issue_id="$(issue_id_from_branch "$branch")"
    transition_done "$issue_id"
    remove_tree "$path" "$branch" "merged"
    continue
  fi

  # 2. Linear issue Canceled?
  issue_id="$(issue_id_from_branch "$branch")"
  if [[ -n "$issue_id" ]]; then
    state="$(bash "$SCRIPT_DIR/linear.sh" get-issue "$issue_id" 2>/dev/null | jq -r '.data.issue.state.name // empty')"
    if [[ "$state" == "Canceled" ]]; then
      remove_tree "$path" "$branch" "canceled"
      continue
    fi
  fi

  # 3. Orphan: no open PR AND no merged PR AND no open issue AND no commits in 30 days.
  pr_open_count="$(gh pr list --head "$branch" --state open --json number --jq 'length' 2>/dev/null || echo 0)"
  last_commit_ts="$(git -C "$path" log -1 --format=%ct 2>/dev/null || echo 0)"
  now_ts="$(date +%s)"
  age_days=$(( (now_ts - last_commit_ts) / 86400 ))

  if (( pr_open_count == 0 )) && (( pr_merged_count == 0 )) && [[ -z "${state:-}" ]] && (( age_days >= 30 )); then
    log "cleanup: orphan detected (path=$path branch=$branch age_days=$age_days) — NOT auto-deleting"
    bash "$SCRIPT_DIR/metrics.sh" worktree-orphan-detected "$branch" "cleanup" "warn" 0 "path=$path age_days=$age_days"
  fi
done
