#!/usr/bin/env bash
# Append a pipeline event to $PROJECT_STATE_DIR/metrics/events.jsonl.
# Usage:
#   metrics.sh <event> <issue_id> <stage> <outcome> <duration_ms>
#              [notes…] [--tokens-in N --tokens-out N
#                        --cache-read N --cache-create N
#                        --cost-usd F --model S]
#
# The trailing flag pairs are optional and may appear anywhere in the
# trailing args (interleaved with notes tokens). Only the flags that
# are set produce a JSONL field — unset flags are OMITTED from the line
# (not null, not 0). See ENG-26 brainstorm D-004.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

main() {
  local event="${1:-}" issue_id="${2:-}" stage="${3:-}" outcome="${4:-}" duration_ms="${5:-0}"
  shift 5 || true

  # Cost flags. Empty-string sentinel = "flag not set" (a real number is
  # always non-empty after `--<flag> N`). Pre-declared so `set -u` is happy.
  local tokens_in="" tokens_out="" cache_read="" cache_create="" cost_usd="" model=""
  local notes_parts=()
  while (( $# > 0 )); do
    case "$1" in
      --tokens-in)    tokens_in="${2:-}";    shift 2 ;;
      --tokens-out)   tokens_out="${2:-}";   shift 2 ;;
      --cache-read)   cache_read="${2:-}";   shift 2 ;;
      --cache-create) cache_create="${2:-}"; shift 2 ;;
      --cost-usd)     cost_usd="${2:-}";     shift 2 ;;
      --model)        model="${2:-}";        shift 2 ;;
      *)              notes_parts+=("$1");   shift ;;
    esac
  done
  # bash 3.2-safe expansion: ${arr[*]:-} is empty when the array is empty.
  local notes="${notes_parts[*]:-}"

  [[ -n "$event" && -n "$outcome" ]] || die "usage: metrics.sh <event> <issue_id> <stage> <outcome> <duration_ms> [notes] [--key value …]"

  local jsonl_file="$PROJECT_STATE_DIR/metrics/events.jsonl"
  local iso_ts
  iso_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  mkdir -p "$(dirname "$jsonl_file")"

  # Conditional object literal: each cost field is added only when the
  # corresponding flag was set. Numeric fields go through `tonumber` so
  # consumers see numbers, not strings (D-004); the model field stays a
  # string and preserves glob chars like `[1m]` verbatim.
  jq -cn \
    --arg ts "$iso_ts" \
    --arg event "$event" \
    --arg issue_id "${issue_id:-}" \
    --arg stage "${stage:-}" \
    --arg outcome "$outcome" \
    --argjson duration_ms "${duration_ms:-0}" \
    --arg notes "${notes:-}" \
    --arg tokens_in "$tokens_in" \
    --arg tokens_out "$tokens_out" \
    --arg cache_read "$cache_read" \
    --arg cache_create "$cache_create" \
    --arg cost_usd "$cost_usd" \
    --arg model "$model" \
    '{ts:$ts, event:$event, issue_id:$issue_id, stage:$stage, outcome:$outcome, duration_ms:$duration_ms, notes:$notes}
     + (if ($tokens_in    | length) > 0 then {tokens_in:    ($tokens_in    | tonumber)} else {} end)
     + (if ($tokens_out   | length) > 0 then {tokens_out:   ($tokens_out   | tonumber)} else {} end)
     + (if ($cache_read   | length) > 0 then {cache_read:   ($cache_read   | tonumber)} else {} end)
     + (if ($cache_create | length) > 0 then {cache_create: ($cache_create | tonumber)} else {} end)
     + (if ($cost_usd     | length) > 0 then {cost_usd:     ($cost_usd     | tonumber)} else {} end)
     + (if ($model        | length) > 0 then {model:         $model}                    else {} end)' \
    >> "$jsonl_file"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
