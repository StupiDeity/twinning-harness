#!/usr/bin/env bash
# ENG-50: review-state — orchestrator's last-review-state/<issue> Linear
# comment manager. Source-able helper with bootstrap/read/update for the
# JSON state body. Sentinel-guarded for testing and ad-hoc CLI use.
#
# Body format:
#   <!-- pipeline-state: last-review-state -->
#
#   {"sha":"<sha-or-null>","last_processed_approval_at":"<ts-or-null>","last_processed_cr_at":"<ts-or-null>"}
#
# All three values may be JSON null. The marker line lets the agent grep
# for the comment via linear.sh get-comments without needing the sig.

set -euo pipefail
_RS_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$_RS_SCRIPT_DIR/common.sh"

# Default linear.sh path; override SCRIPT_DIR in tests post-source.
SCRIPT_DIR="${SCRIPT_DIR:-$_RS_SCRIPT_DIR}"

_RS_MARKER='<!-- pipeline-state: last-review-state -->'

_rs_compose_body() {
  local sha="$1" approval_at="$2" cr_at="$3"
  local payload
  payload="$(jq -cn \
    --arg sha "$sha" --arg approval "$approval_at" --arg cr "$cr_at" \
    '{sha:                        (if $sha==""      then null else $sha      end),
      last_processed_approval_at: (if $approval=="" then null else $approval end),
      last_processed_cr_at:       (if $cr==""       then null else $cr       end)}')"
  printf '%s\n\n%s\n' "$_RS_MARKER" "$payload"
}

bootstrap_review_state() {
  local issue="$1"
  [[ -n "$issue" ]] || die "bootstrap_review_state: issue id required"
  local body
  body="$(_rs_compose_body "" "" "")"
  bash "$SCRIPT_DIR/linear.sh" add-or-update-comment "last-review-state/$issue" "$issue" "$body"
}

update_review_state() {
  local issue="$1" sha="${2:-}" approval_at="${3:-}" cr_at="${4:-}"
  [[ -n "$issue" ]] || die "update_review_state: issue id required"
  local body
  body="$(_rs_compose_body "$sha" "$approval_at" "$cr_at")"
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
    *)         die "usage: review-state.sh <bootstrap|update|read> <issue> [<sha> <approval_at> <cr_at>]" ;;
  esac
fi
