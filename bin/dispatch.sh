#!/usr/bin/env bash
# Invoke the Claude Code CLI headlessly with a rendered prompt.
# Usage: dispatch.sh <stage> <prompt_file> [<log_file>]
# In PIPELINE_DRY_RUN=1, echoes what it would do without calling claude.
#
# CWD is the feature's worktree when called from run-local.sh (ENG-13 D-011),
# or the main repo root for legacy feature/* branches.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

CLAUDE_MUTEX_DIR="$HARNESS_STATE_DIR/.claude-mutex.lock"
CLAUDE_MUTEX_TIMEOUT="${CLAUDE_MUTEX_TIMEOUT:-600}"

acquire_claude_mutex() {
  local waited=0
  while ! mkdir "$CLAUDE_MUTEX_DIR" 2>/dev/null; do
    if (( waited == 0 )); then
      local holder=""
      [[ -f "$CLAUDE_MUTEX_DIR/pid" ]] && holder="$(cat "$CLAUDE_MUTEX_DIR/pid" 2>/dev/null || true)"
      log "[claude-mutex] waiting for lock held by ${holder:-<unknown>}"
    fi
    (( waited >= CLAUDE_MUTEX_TIMEOUT )) && die "[claude-mutex] timeout after ${CLAUDE_MUTEX_TIMEOUT}s"
    sleep 1
    waited=$((waited + 1))
  done
  printf '%s\n' "$$" > "$CLAUDE_MUTEX_DIR/pid"
}

release_claude_mutex() {
  rm -rf "$CLAUDE_MUTEX_DIR"
}

allowed_tools_for() {
  # Every stage gets `Bash(bash .pipeline/bin/linear.sh:*)` so agents can always post
  # Linear comments via the canonical bash path. MCP Linear remains available in parallel;
  # this just guarantees a bash fallback so tool-allowlist omissions can't silently block
  # the mandatory end-of-stage Linear comment.
  case "$1" in
    brainstorm)     printf 'Read,Write,Edit,Grep,Glob,TaskCreate,WebFetch,Bash(bash .pipeline/bin/linear.sh:*)' ;;
    plan)           printf 'Read,Write,Edit,Grep,Glob,TaskCreate,Bash(git log:*),Bash(git diff:*),Bash(bash .pipeline/bin/linear.sh:*)' ;;
    implement)      printf 'Read,Write,Edit,Grep,Glob,TaskCreate,Bash(git:*),Bash(cargo:*),Bash(bun:*),Bash(rustc:*),Bash(jq:*),Bash(awk:*),Bash(bash .pipeline/bin/linear.sh:*)' ;;
    ui)             printf 'Read,Write,Edit,Grep,Glob,TaskCreate,Agent,Bash(git:*),Bash(cargo:*),Bash(bun:*),Bash(npx:*),Bash(node:*),Bash(jq:*),Bash(awk:*),Bash(gh pr create:*),Bash(gh pr view:*),Bash(gh pr edit:*),Bash(bash .pipeline/bin/linear.sh:*)' ;;
    review)         printf 'Read,Write,Grep,Glob,TaskCreate,Agent,Bash(git diff:*),Bash(git log:*),Bash(git show:*),Bash(gh pr view:*),Bash(gh pr diff:*),Bash(gh pr list:*),Bash(gh pr review:*),Bash(gh pr comment:*),Bash(gh issue create:*),Bash(bash .pipeline/bin/linear.sh:*)' ;;
    qa)             printf 'Read,Write,Edit,Grep,Glob,TaskCreate,Agent,Bash(git:*),Bash(cargo:*),Bash(bun:*),Bash(npx:*),Bash(node:*),Bash(jq:*),Bash(awk:*),Bash(gh pr view:*),Bash(gh pr diff:*),Bash(gh pr comment:*),Bash(gh issue create:*),Bash(gh issue list:*),Bash(bash .pipeline/bin/linear.sh:*)' ;;
    build)          printf 'Read,Write,Grep,Glob,Bash(git fetch:*),Bash(git clone:*),Bash(git rebase:*),Bash(gh run:*),Bash(gh pr list:*),Bash(gh pr view:*),Bash(gh pr checks:*),Bash(gh pr edit:*),Bash(gh pr merge:*),Bash(jq:*),Bash(mktemp:*),Bash(bash .pipeline/bin/linear.sh:*),Bash(bash .pipeline/bin/slack.sh:*)' ;;
    release)        printf 'Read,Grep,Glob,Bash(git log:*),Bash(git show:*),Bash(git rev-list:*),Bash(git describe:*),Bash(gh release view:*),Bash(gh release list:*),Bash(jq:*),Bash(bash .pipeline/bin/linear.sh:*)' ;;
    retrospective)  printf 'Read,Write,Edit,Grep,Glob,TaskCreate,Agent,Bash(git log:*),Bash(git diff:*),Bash(git show:*),Bash(git rev-list:*),Bash(git describe:*),Bash(jq:*),Bash(awk:*),Bash(bash .pipeline/bin/linear.sh:*),Bash(bash .pipeline/bin/guards.sh:*),Bash(bash .pipeline/bin/metrics.sh:*)' ;;
    *)              die "no allowed-tools profile for stage: $1" ;;
  esac
}

main() {
  local stage="${1:-}" prompt_file="${2:-}" log_file="${3:-}"
  [[ -n "$stage" && -n "$prompt_file" ]] || die "usage: dispatch.sh <stage> <prompt_file> [<log_file>]"
  [[ -f "$prompt_file" ]] || die "prompt file not found: $prompt_file"

  local tools
  tools="$(allowed_tools_for "$stage")"

  acquire_claude_mutex
  trap 'release_claude_mutex' EXIT

  if [[ "$PIPELINE_DRY_RUN" == "1" ]]; then
    log "[DRY_RUN] would invoke: claude -p --allowed-tools \"$tools\" < $prompt_file"
    log "[DRY_RUN] prompt preview (first 500 chars):"
    head -c 500 "$prompt_file" >&2
    printf '\n' >&2
    return 0
  fi

  require_bin claude
  # Auth: ANTHROPIC_API_KEY for CI/headless; claude CLI subscription session for local.
  # Don't require either here — claude errors at invocation time if no auth is available.

  # ENG-41 T3: set the agent lane only for the claude -p subprocess.
  # Any orchestrator-side Linear writes above (none currently, but guarding for
  # future additions) stay in the default orchestrator lane.
  local cmd=(env PIPELINE_WRITER=agent claude -p --allowed-tools "$tools")
  if [[ -n "$log_file" ]]; then
    mkdir -p "$(dirname "$log_file")"
    log "dispatching stage=$stage, log=$log_file"
    "${cmd[@]}" < "$prompt_file" | tee "$log_file"
  else
    log "dispatching stage=$stage"
    "${cmd[@]}" < "$prompt_file"
  fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
