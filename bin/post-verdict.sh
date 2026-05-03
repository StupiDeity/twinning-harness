#!/usr/bin/env bash
# DEPRECATED (ENG-60 T2.10): bin/post-verdict.sh — transitional wrapper.
# Translates legacy <kind, stage_or_target_or_reason> tuple into the new
# bin/pipeline event verdict subcommand. Will be removed in Phase 3.
#
# Usage (preserved for backward compatibility):
#   post-verdict.sh <issue> <kind> <stage> [<reason>]
#     kind  ∈ stage-summary | rejection | halt
#     stage ∈ brainstorming|planning|implementing|ui|reviewing|qa|building|released
#             OR (for kind=halt) any halt-reason word matching [a-z-]+
#
# NOTE: The optional 4th arg [<reason>] (free-text rationale appended to the
# comment body) is NOT forwarded to bin/pipeline event verdict, which has no
# equivalent parameter. The text is silently dropped in this wrapper.
#
# New callers should use directly:
#   bin/pipeline.sh event <issue> verdict pass   --stage <stage>
#   bin/pipeline.sh event <issue> verdict fail   --target <target>
#   bin/pipeline.sh event <issue> verdict halt   --reason <reason>

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

# ENG-41 T3: human lane — operator CLI; Linear writes are unrestricted.
export PIPELINE_WRITER=human

main() {
  local issue="${1:-}" kind="${2:-}" stage_or_target_or_reason="${3:-}"
  [[ -n "$issue" && -n "$kind" && -n "$stage_or_target_or_reason" ]] \
    || die "usage: post-verdict.sh <issue> <kind> <stage|target|reason>"

  printf '[deprecated] bin/post-verdict.sh will be removed in Phase 3. ' >&2
  printf 'Use: bin/pipeline.sh event %s verdict <result> [args]\n' "$issue" >&2

  case "$kind" in
    stage-summary) bash "$SCRIPT_DIR/pipeline.sh" event "$issue" verdict pass --stage "$stage_or_target_or_reason" ;;
    rejection)     bash "$SCRIPT_DIR/pipeline.sh" event "$issue" verdict fail --target "$stage_or_target_or_reason" ;;
    halt)          bash "$SCRIPT_DIR/pipeline.sh" event "$issue" verdict halt --reason "$stage_or_target_or_reason" ;;
    *) die "post-verdict: unknown kind '$kind' (allowed: stage-summary, rejection, halt)" ;;
  esac

  log "post-verdict: posted $kind:$stage_or_target_or_reason on $issue"
}

# post_verdict <issue> <kind> <stage_or_target_or_reason> [<rationale>]
# Sourceable shim retained for bin/post-verdict-test.sh and any other
# in-tree caller that sources this file rather than invoking it as a CLI.
# The 4th rationale arg is accepted but silently dropped (parity with main()).
post_verdict() {
  main "$@"
}
export -f post_verdict

# Sentinel — runnable as a CLI.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
