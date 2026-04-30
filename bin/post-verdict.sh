#!/usr/bin/env bash
# ENG-49 Gap #3: bin/post-verdict.sh — operator-facing helper for safely
# posting verdict markers to Linear. Constructs the marker body via
# heredoc (immune to bash history expansion of `<!--`) and validates the
# constructed body against verdict-handler.sh::find_fresh_verdict's
# grep regex before sending.
#
# Usage:
#   post-verdict.sh <issue> <kind> <stage> [<reason>]
#     kind  ∈ stage-summary | rejection | halt
#     stage ∈ brainstorming|planning|implementing|ui|reviewing|qa|building|released
#             OR (for kind=halt) any halt-reason word matching [a-z-]+
#
# Examples:
#   bin/post-verdict.sh ENG-45 stage-summary building "release shipped"
#   bin/post-verdict.sh ENG-46 rejection reviewing "rework needed"
#   bin/post-verdict.sh ENG-47 halt agent-blocked "operator stop"

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

# ENG-41 T3: human lane — operator CLI; Linear writes are unrestricted.
export PIPELINE_WRITER=human

_PV_KNOWN_STAGES='brainstorming planning implementing ui reviewing qa building released'

post_verdict() {
  local issue="$1" kind="$2" stage="$3" reason="${4:-Manual marker post by operator.}"
  [[ -n "$issue" && -n "$kind" && -n "$stage" ]] \
    || die "usage: post-verdict.sh <issue> <kind> <stage> [<reason>]"
  case "$kind" in
    stage-summary|rejection|halt) ;;
    *) die "unknown kind: $kind (expected stage-summary|rejection|halt)" ;;
  esac
  if [[ "$kind" != "halt" ]]; then
    grep -qw -- "$stage" <<<"$_PV_KNOWN_STAGES" \
      || die "unknown stage: $stage (expected one of: $_PV_KNOWN_STAGES)"
  else
    [[ "$stage" =~ ^[a-z][a-z-]*$ ]] \
      || die "halt reason must match [a-z-]+, got: $stage"
  fi

  local marker
  case "$kind" in
    stage-summary) marker="<!-- pipeline-stage-summary: ${stage} -->" ;;
    rejection)     marker="<!-- pipeline-rejection: ${stage} -->" ;;
    halt)          marker="<!-- pipeline-halt: ${stage} -->" ;;
  esac

  local body
  body="$(cat <<EOF
${marker}

${reason}
EOF
)"

  # Validate against verdict-handler's regexes (one per kind).
  local re
  case "$kind" in
    stage-summary) re='<!-- pipeline-stage-summary: [a-z]+ -->' ;;
    rejection)     re='<!-- pipeline-rejection: [a-z]+ -->' ;;
    halt)          re='<!-- pipeline-halt: [a-z-]+ -->' ;;
  esac
  grep -qE -- "$re" <<<"$body" \
    || die "constructed body did not match verdict-handler regex: $re"

  bash "$SCRIPT_DIR/linear.sh" add-comment "$issue" "$body"
  log "post-verdict: posted $kind:$stage on $issue"
}

export -f post_verdict

# Sentinel — runnable as a CLI.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  post_verdict "$@"
fi
