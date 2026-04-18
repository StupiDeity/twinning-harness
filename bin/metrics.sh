#!/usr/bin/env bash
# Append a pipeline event to docs/knowledge/pipeline-metrics.md.
# Usage: metrics.sh <event> <issue_id> <stage> <outcome> <duration_ms> [notes...]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

main() {
  local event="${1:-}" issue_id="${2:-}" stage="${3:-}" outcome="${4:-}" duration_ms="${5:-0}"
  shift 5 || true
  local notes="${*:-}"

  [[ -n "$event" && -n "$outcome" ]] || die "usage: metrics.sh <event> <issue_id> <stage> <outcome> <duration_ms> [notes]"

  local metrics_file="$REPO_ROOT/docs/knowledge/pipeline-metrics.md"
  local jsonl_file="$REPO_ROOT/.pipeline/metrics/events.jsonl"
  local today iso_ts
  today="$(date -u +%Y-%m-%d)"
  iso_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  mkdir -p "$(dirname "$metrics_file")" "$(dirname "$jsonl_file")"
  if [[ ! -f "$metrics_file" ]]; then
    cat > "$metrics_file" <<EOF
# Pipeline Metrics

> Append-only log of pipeline events. One line per event. Written by .pipeline/bin/metrics.sh.
> Timezone: UTC (ISO-8601 Z).
> Machine-readable twin: \`.pipeline/metrics/events.jsonl\` (one JSON object per line).

EOF
  fi

  # Add today's heading if not present.
  if ! grep -qE "^## $today\$" "$metrics_file"; then
    printf '\n## %s\n\n' "$today" >> "$metrics_file"
  fi

  # Human-readable markdown line (legacy).
  printf -- '- `%s` event=%s issue=%s stage=%s outcome=%s duration_ms=%s%s\n' \
    "$iso_ts" "$event" "${issue_id:-}" "${stage:-}" "$outcome" "$duration_ms" \
    "${notes:+ notes=\"$notes\"}" >> "$metrics_file"

  # Machine-readable JSONL twin (for retrospective queries).
  # jq constructs safely-escaped JSON; no shell-interpolation of notes field.
  jq -cn \
    --arg ts "$iso_ts" \
    --arg event "$event" \
    --arg issue_id "${issue_id:-}" \
    --arg stage "${stage:-}" \
    --arg outcome "$outcome" \
    --argjson duration_ms "${duration_ms:-0}" \
    --arg notes "${notes:-}" \
    '{ts:$ts, event:$event, issue_id:$issue_id, stage:$stage, outcome:$outcome, duration_ms:$duration_ms, notes:$notes}' \
    >> "$jsonl_file"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
