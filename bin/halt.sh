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

# ENG-41 T3: human lane — operator CLI; all Linear writes are unrestricted.
export PIPELINE_WRITER=human

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

  if [[ "$decision" == "resume" ]]; then
    # ENG-49 Gap #2: invoke verdict-handler BEFORE clearing pipeline:halted
    # so any fresh forward verdict marker actually advances the stage.
    # shellcheck source=verdict-handler.sh
    source "$SCRIPT_DIR/verdict-handler.sh"
    local current_stage rc=0
    current_stage="$(bash "$SCRIPT_DIR/linear.sh" stage-of "$issue")"
    current_stage="${current_stage#stage:}"
    verdict_handler "$issue" "$current_stage" || rc=$?
    case "$rc" in
      0)
        # apply_transition already removed pipeline:halted as part of the transition.
        log "halt resolved: $issue decision=resume (verdict-handler transitioned)"
        return 0
        ;;
      1)
        # No fresh forward verdict; halt-marker is preserved. Proceed with manual halt clear.
        bash "$SCRIPT_DIR/linear.sh" remove-label "$issue" "pipeline:halted"
        log "halt resolved: $issue decision=resume (no fresh forward verdict; halt label cleared)"
        return 0
        ;;
      2)
        # Protocol violation — verdict-handler re-applied pipeline:halted.
        # Do NOT clear it; operator must address the violation.
        printf 'halt.sh: verdict-handler reported protocol violation on %s; halt label preserved.\n' "$issue" >&2
        printf 'halt.sh: see Linear comment with sig protocol-violation/<case_id>/%s for details.\n' "$issue" >&2
        return 2
        ;;
      *)
        die "verdict_handler returned unknown rc=$rc"
        ;;
    esac
  fi

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
