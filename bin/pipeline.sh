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

# cmd_event <issue> <event> [args] — dispatch to event-specific writer.
cmd_event() {
  local issue="${1:-}"; shift || true
  [[ -n "$issue" ]] || die "event: issue id required (e.g., bin/pipeline event ENG-1 verdict pass --stage X)"
  local event="${1:-}"; shift || true
  [[ -n "$event" ]] || die "event: event type required (verdict, transition)"
  case "$event" in
    verdict)    cmd_event_verdict "$issue" "$@" ;;
    transition) cmd_event_transition "$issue" "$@" ;;
    *) die "event: unknown event '$event' (allowed: verdict, transition)" ;;
  esac
}

# Validate $1 is in the named registry array; die with the registry's contents
# in the error message if not.
_validate_registry() {
  local field="$1" value="$2"
  jq -e --arg f "$field" --arg v "$value" '.[$f] | index($v) // empty' "$REGISTRY" >/dev/null 2>&1 \
    || die "registry: '$value' not in $field — allowed: $(jq -r --arg f "$field" '.[$f] | join(", ")' "$REGISTRY")"
}

# cmd_event_verdict <issue> <result> [--stage X] [--target Y] [--reason Z]
cmd_event_verdict() {
  local issue="$1"; shift
  local result="${1:-}"; shift || true
  [[ -n "$issue" && -n "$result" ]] || die "event verdict: usage: <issue> <result> [args]"
  _validate_registry verdict_results "$result"

  local stage="" target="" reason=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --stage)  stage="${2:-}"; shift 2 ;;
      --target) target="${2:-}"; shift 2 ;;
      --reason) reason="${2:-}"; shift 2 ;;
      *) die "event verdict: unknown flag '$1'" ;;
    esac
  done

  # Per-result required fields.
  case "$result" in
    pass)  [[ -n "$stage" ]]  || die "event verdict pass: --stage required"
           _validate_registry stages "$stage" ;;
    fail)  [[ -n "$target" ]] || die "event verdict fail: --target required"
           _validate_registry fail_targets "$target" ;;
    halt)  [[ -n "$reason" ]] || die "event verdict halt: --reason required"
           _validate_registry halt_reasons "$reason" ;;
    wait)  [[ -n "$reason" ]] || die "event verdict wait: --reason required"
           _validate_registry wait_reasons "$reason" ;;
    pivot) [[ -n "$target" ]] || die "event verdict pivot: --target required"
           _validate_registry pivot_targets "$target" ;;
  esac

  # Build the marker body.
  local body="<!-- pipeline: verdict result=$result"
  [[ -n "$stage" ]]  && body="$body stage=$stage"
  [[ -n "$target" ]] && body="$body target=$target"
  [[ -n "$reason" ]] && body="$body reason=$reason"
  body="$body -->"

  # Lane fence: agents emit verdicts. dispatch.sh sets PIPELINE_WRITER=agent
  # for the agent path; common.sh defaults it to orchestrator for everything
  # else (operator manual runs, tests). The default-assignment idiom would be
  # a no-op here because common.sh has already exported the var, so we just
  # warn instead and tell the caller how to suppress.
  if [[ "$PIPELINE_WRITER" != "agent" ]]; then
    log "warning: PIPELINE_WRITER=$PIPELINE_WRITER writing a verdict (lane mismatch — set PIPELINE_WRITER=agent to suppress)"
  fi

  if [[ "${PIPELINE_DRY_RUN:-}" == "1" ]]; then
    printf '[DRY_RUN] would post on %s: %s\n' "$issue" "$body" >&2
    return 0
  fi

  bash "$SCRIPT_DIR/linear.sh" add-comment "$issue" "$body"
}

main() {
  local sub="${1:-}"
  shift || true
  case "$sub" in
    status) cmd_status "$@" ;;
    event)  cmd_event "$@" ;;
    decide) die "decide subcommand: not yet implemented (T2.7)" ;;
    -h|--help|"") usage; [[ -z "$sub" ]] && exit 1 || exit 0 ;;
    *) usage; die "unknown subcommand: $sub" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
