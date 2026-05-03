#!/usr/bin/env bash
# bin/pipeline.sh — single-entry CLI for pipeline events (ENG-60).
#
# Usage:
#   bin/pipeline.sh status <issue>
#   bin/pipeline.sh event <issue> <event> [args]
#   bin/pipeline.sh decide <issue> --action <continue|approve|abandon> [--gate <gate>]
#
# All writes validate against bin/pipeline-events.json. Lane fences honored
# via PIPELINE_WRITER (set by callers; agent | orchestrator | human).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

REGISTRY="$HARNESS_ROOT/bin/pipeline-events.json"

usage() {
  cat <<'EOF'
Usage:
  bin/pipeline.sh status <issue>
  bin/pipeline.sh event <issue> verdict <pass|fail|halt|wait|pivot> [--stage X] [--target Y] [--reason Z]
  bin/pipeline.sh event <issue> transition <from→to>
  bin/pipeline.sh decide <issue> --action <continue|approve|abandon> [--gate <gate>]

Environment:
  PIPELINE_WRITER  Lane attribution: agent | orchestrator | human (required for writes).
  PIPELINE_DRY_RUN If set, print intended action to stderr and skip the Linear write.
EOF
}

# cmd_status <issue> — read-only summary of pipeline events on an issue.
# Lists every comment whose body parses as a pipeline event, in chronological
# order, one per line: "<createdAt> <event> <key=value ...>"
cmd_status() {
  local issue="$1"
  [[ -n "$issue" ]] || die "status: issue id required"
  local comments
  comments="$(bash "$SCRIPT_DIR/linear.sh" get-comments "$issue" 2>&1)" || {
    log "status: could not fetch comments for $issue (linear error above)"
    return 0
  }
  [[ -z "$comments" || "$comments" == "null" ]] && { log "status: no comments"; return 0; }

  local ts body ev
  while IFS=$'\t' read -r ts body; do
    ev="$(parse_pipeline_marker "$body" 2>/dev/null || true)"
    [[ -z "$ev" ]] && continue
    printf '%s  %s\n' "$ts" "$(jq -c . <<<"$ev")"
  done < <(jq -r '.[] | "\(.createdAt)\t\(.body | gsub("\n"; " "))"' <<<"$comments")
}

main() {
  local sub="${1:-}"
  shift || true
  case "$sub" in
    status) cmd_status "$@" ;;
    event)  die "event subcommand: not yet implemented (T2.5–T2.6)" ;;
    decide) die "decide subcommand: not yet implemented (T2.7)" ;;
    -h|--help|"") usage; [[ -z "$sub" ]] && exit 1 || exit 0 ;;
    *) usage; die "unknown subcommand: $sub" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
