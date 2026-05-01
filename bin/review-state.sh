#!/usr/bin/env bash
# ENG-50 / ENG-54: review-state — orchestrator's last-review-state/<issue>
# Linear comment manager. Source-able helper with bootstrap/read/update for
# the JSON state body. Sentinel-guarded for testing and ad-hoc CLI use.
#
# Body format:
#   <!-- pipeline-state: last-review-state -->
#
#   {"sha":"<sha-or-null>"}
#
# The marker line lets the agent grep for the comment via `linear.sh
# get-comments` without needing the sig.
#
# ENG-54: pre-fix this struct also carried `last_processed_approval_at` and
# `last_processed_cr_at` — review-stage's human-approval gate (ENG-50) used
# them to decide whether a fresh non-bot review warranted re-dispatch. ENG-54
# moved the human-approval gate to build's P2 (the sole remaining
# approval-bearing gate); review never waits for humans now, so those fields
# became dead. Removing them simplifies `review_should_dispatch` to a pure
# "new commits since last reviewed SHA" check.

set -euo pipefail
_RS_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$_RS_SCRIPT_DIR/common.sh"

# Default linear.sh path; override SCRIPT_DIR in tests post-source.
SCRIPT_DIR="${SCRIPT_DIR:-$_RS_SCRIPT_DIR}"

_RS_MARKER='<!-- pipeline-state: last-review-state -->'

_rs_compose_body() {
  local sha="$1"
  local payload
  payload="$(jq -cn --arg sha "$sha" \
    '{sha: (if $sha=="" then null else $sha end)}')"
  printf '%s\n\n%s\n' "$_RS_MARKER" "$payload"
}

bootstrap_review_state() {
  local issue="$1"
  [[ -n "$issue" ]] || die "bootstrap_review_state: issue id required"
  local body
  body="$(_rs_compose_body "")"
  bash "$SCRIPT_DIR/linear.sh" add-or-update-comment "last-review-state/$issue" "$issue" "$body"
}

update_review_state() {
  local issue="$1" sha="${2:-}"
  [[ -n "$issue" ]] || die "update_review_state: issue id required"
  local body
  body="$(_rs_compose_body "$sha")"
  bash "$SCRIPT_DIR/linear.sh" add-or-update-comment "last-review-state/$issue" "$issue" "$body"
}

read_review_state() {
  local issue="$1"
  [[ -n "$issue" ]] || die "read_review_state: issue id required"
  local comments
  comments="$(bash "$SCRIPT_DIR/linear.sh" get-comments "$issue" 2>/dev/null || printf '[]')"
  [[ -z "$comments" || "$comments" == "null" ]] && { printf ''; return 0; }
  local body
  body="$(jq -r --arg m "$_RS_MARKER" '
    [.[] | select(.body | contains($m))]
    | sort_by(.createdAt) | last | (.body // "")' <<<"$comments")"
  [[ -z "$body" || "$body" == "null" ]] && { printf ''; return 0; }
  # Extract JSON (which may be single-line or multi-line); skip any leading marker content
  printf '%s\n' "$body" | grep -E '^\{' | head -1
}

export -f bootstrap_review_state update_review_state read_review_state

# Sentinel — runnable as a CLI for orchestrator-side calls (apply_transition, run-stage.sh).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  cmd="${1:-}"
  shift || true
  case "$cmd" in
    bootstrap) bootstrap_review_state "$@" ;;
    update)    update_review_state "$@" ;;
    read)      read_review_state "$@" ;;
    *)         die "usage: review-state.sh <bootstrap|update|read> <issue> [<sha>]" ;;
  esac
fi
