#!/usr/bin/env bash
# ENG-50 / ENG-54: review-poll — orchestrator's gate for whether to dispatch
# the review agent. Consults `gh pr view` for the PR HEAD SHA against
# last-review-state.sha to decide.
#
# Returns 0 (dispatch) when:
#   - No last-review-state exists yet (bootstrap path).
#   - Current HEAD SHA != last-review-state.sha (new commits since last review).
#   - PR view query failed (defensive — let run-stage's stage-drift / agent
#     contract guards trip on the next tick rather than silently idling).
# Returns 1 (idle) otherwise.
#
# ENG-54: pre-fix this also fired on a fresh non-bot APPROVED or
# CHANGES_REQUESTED review newer than the per-state "last-processed"
# timestamp. That was load-bearing under ENG-50's review-stage human-approval
# gate. ENG-54 moved the human-approval gate to build's P2 (the sole gate
# now), so review never waits for humans. The simpler "new commits → run
# again" contract is enough.

set -euo pipefail
_RP_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$_RP_SCRIPT_DIR/common.sh"
# shellcheck source=review-state.sh
source "$_RP_SCRIPT_DIR/review-state.sh"

SCRIPT_DIR="${SCRIPT_DIR:-$_RP_SCRIPT_DIR}"

review_should_dispatch() {
  local issue="$1" branch="$2"
  [[ -n "$issue" && -n "$branch" ]] \
    || die "review_should_dispatch: usage <issue> <branch>"

  # Bootstrap path: no last-review-state → dispatch.
  local state
  state="$(read_review_state "$issue" 2>/dev/null || printf '')"
  [[ -z "$state" ]] && return 0

  # Read PR view: HEAD SHA only (reviews no longer drive the gate).
  local pr_view
  pr_view="$(gh pr view "$branch" --json commits 2>/dev/null || printf '{}')"
  [[ -z "$pr_view" || "$pr_view" == "{}" ]] && return 0  # PR query failed; dispatch defensively.

  local head_sha state_sha
  head_sha="$(jq -r '.commits[-1].oid // empty' <<<"$pr_view")"
  state_sha="$(jq -r '.sha // empty' <<<"$state")"

  # New commits since last review → dispatch. Otherwise idle.
  if [[ -n "$head_sha" && "$head_sha" != "$state_sha" ]]; then
    return 0
  fi
  return 1
}

export -f review_should_dispatch

# Sentinel — runnable as a CLI for ad-hoc inspection.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  [[ $# -eq 2 ]] || die "usage: review-poll.sh <issue> <branch>"
  if review_should_dispatch "$1" "$2"; then
    printf 'dispatch\n'
    exit 0
  else
    printf 'idle\n'
    exit 1
  fi
fi
