#!/usr/bin/env bash
# Invoke the Claude Code CLI headlessly with a rendered prompt.
# Usage: dispatch.sh <stage> <prompt_file> [<log_file>]
# In PIPELINE_DRY_RUN=1, echoes what it would do without calling claude.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

allowed_tools_for() {
  case "$1" in
    brainstorm)     printf 'Read,Write,Edit,Grep,Glob,TaskCreate,WebFetch' ;;
    plan)           printf 'Read,Write,Edit,Grep,Glob,TaskCreate,Bash(git log:*),Bash(git diff:*)' ;;
    implement)      printf 'Read,Write,Edit,Grep,Glob,TaskCreate,Bash(git:*),Bash(cargo:*),Bash(bun:*),Bash(rustc:*),Bash(jq:*),Bash(awk:*)' ;;
    ui)             printf 'Read,Write,Edit,Grep,Glob,TaskCreate,Agent,Bash(git:*),Bash(cargo:*),Bash(bun:*),Bash(npx:*),Bash(node:*),Bash(jq:*),Bash(awk:*),Bash(gh pr create:*),Bash(gh pr view:*),Bash(gh pr edit:*)' ;;
    review)         printf 'Read,Grep,Glob,TaskCreate,Agent,Bash(git diff:*),Bash(git log:*),Bash(git show:*),Bash(gh pr view:*),Bash(gh pr diff:*),Bash(gh pr list:*),Bash(gh pr review:*),Bash(gh pr comment:*),Bash(gh issue create:*)' ;;
    qa)             printf 'Read,Write,Edit,Grep,Glob,TaskCreate,Agent,Bash(git:*),Bash(cargo:*),Bash(bun:*),Bash(npx:*),Bash(node:*),Bash(jq:*),Bash(awk:*),Bash(gh pr view:*),Bash(gh pr diff:*),Bash(gh pr comment:*),Bash(gh issue create:*),Bash(gh issue list:*)' ;;
    build)          printf 'Read,Grep,Glob,Bash(git fetch:*),Bash(git clone:*),Bash(git rebase:*),Bash(gh run:*),Bash(gh pr list:*),Bash(gh pr view:*),Bash(gh pr checks:*),Bash(gh pr edit:*),Bash(gh pr merge:*),Bash(jq:*),Bash(mktemp:*)' ;;
    release)        printf 'Read,Grep,Glob,Bash(git log:*),Bash(git show:*),Bash(git rev-list:*),Bash(git describe:*),Bash(gh release view:*),Bash(gh release list:*),Bash(jq:*)' ;;
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

  local cmd=(claude -p --allowed-tools "$tools")
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
