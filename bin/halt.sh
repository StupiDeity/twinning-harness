#!/usr/bin/env bash
# Halt resolution CLI (ENG-18). Posts a <!-- pipeline-decision: --> comment
# and removes pipeline:halted in one step.
#
# Usage:
#   halt.sh resolve <ENG-XX> --decision <scope-approved|scope-rejected|resume>

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

resolve() {
  local issue="$1" decision="$2"
  [[ -n "$issue" && -n "$decision" ]] \
    || die "usage: halt.sh resolve <ENG-XX> --decision <scope-approved|scope-rejected|resume>"
  case "$decision" in
    scope-approved|scope-rejected|resume) ;;
    *) die "unknown decision: $decision" ;;
  esac
  local body
  body="$(printf '<!-- pipeline-decision: %s -->\n\nHalt resolved by human via halt.sh (decision=%s).' "$decision" "$decision")"
  bash "$SCRIPT_DIR/linear.sh" add-comment "$issue" "$body"
  bash "$SCRIPT_DIR/linear.sh" remove-label "$issue" "pipeline:halted"
  log "halt resolved: $issue decision=$decision"
}

main() {
  local cmd="${1:-}"
  shift || true
  case "$cmd" in
    resolve)
      local issue="" decision=""
      while (( $# )); do
        case "$1" in
          --decision) decision="$2"; shift 2 ;;
          ENG-*)      issue="$1"; shift ;;
          *)          die "unknown arg: $1" ;;
        esac
      done
      resolve "$issue" "$decision"
      ;;
    *) die "usage: halt.sh resolve <ENG-XX> --decision <scope-approved|scope-rejected|resume>" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
