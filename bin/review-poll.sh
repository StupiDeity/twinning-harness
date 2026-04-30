#!/usr/bin/env bash
# ENG-50: review-poll — orchestrator's gate for whether to dispatch the
# review agent. Consults `gh pr view` (HEAD SHA + most recent non-bot
# review) against last-review-state to decide.
#
# Returns 0 (dispatch) when:
#   - No last-review-state exists yet (bootstrap).
#   - Current HEAD SHA != last-review-state.sha.
#   - Most recent non-bot APPROVED review is on current HEAD AND
#     submittedAt > last_processed_approval_at.
#   - Most recent non-bot CHANGES_REQUESTED review is on current HEAD AND
#     submittedAt > last_processed_cr_at.
# Returns 1 (idle) otherwise.

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

  # Read PR view: HEAD SHA + most recent non-bot review.
  local pr_view
  pr_view="$(gh pr view "$branch" --json commits,reviews 2>/dev/null || printf '{}')"
  [[ -z "$pr_view" || "$pr_view" == "{}" ]] && return 0  # PR query failed; dispatch defensively.

  local head_sha state_sha
  head_sha="$(jq -r '.commits[-1].oid // empty' <<<"$pr_view")"
  state_sha="$(jq -r '.sha // empty' <<<"$state")"

  # Case B: HEAD SHA differs (new commits since last review).
  if [[ -n "$head_sha" && "$head_sha" != "$state_sha" ]]; then
    return 0
  fi

  # Most recent non-bot review (filter out [bot] logins).
  local nonbot_review
  nonbot_review="$(jq -c '
    [.reviews[]? | select(.author.login | test("\\[bot\\]$") | not)]
    | sort_by(.submittedAt) | last // empty' <<<"$pr_view")"
  [[ -z "$nonbot_review" || "$nonbot_review" == "null" ]] && return 1  # no non-bot review; idle.

  local nb_state nb_commit nb_at
  nb_state="$(jq -r '.state // ""'      <<<"$nonbot_review")"
  nb_commit="$(jq -r '.commit_id // ""' <<<"$nonbot_review")"
  nb_at="$(jq -r '.submittedAt // ""'   <<<"$nonbot_review")"

  # Approval on current HEAD AND newer than last_processed_approval_at → dispatch.
  if [[ "$nb_state" == "APPROVED" && "$nb_commit" == "$head_sha" ]]; then
    local last_app
    last_app="$(jq -r '.last_processed_approval_at // ""' <<<"$state")"
    if [[ -z "$last_app" || "$nb_at" > "$last_app" ]]; then
      return 0
    fi
  fi

  # CHANGES_REQUESTED on current HEAD AND newer than last_processed_cr_at → dispatch.
  if [[ "$nb_state" == "CHANGES_REQUESTED" && "$nb_commit" == "$head_sha" ]]; then
    local last_cr
    last_cr="$(jq -r '.last_processed_cr_at // ""' <<<"$state")"
    if [[ -z "$last_cr" || "$nb_at" > "$last_cr" ]]; then
      return 0
    fi
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
