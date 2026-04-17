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
  local today iso_ts
  today="$(date -u +%Y-%m-%d)"
  iso_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  mkdir -p "$(dirname "$metrics_file")"
  if [[ ! -f "$metrics_file" ]]; then
    cat > "$metrics_file" <<EOF
# Pipeline Metrics

> Append-only log of pipeline events. One line per event. Written by .pipeline/bin/metrics.sh.

EOF
  fi

  # Add today's heading if not present.
  if ! grep -qE "^## $today\$" "$metrics_file"; then
    printf '\n## %s\n\n' "$today" >> "$metrics_file"
  fi

  printf -- '- `%s` event=%s issue=%s stage=%s outcome=%s duration_ms=%s%s\n' \
    "$iso_ts" "$event" "${issue_id:-}" "${stage:-}" "$outcome" "$duration_ms" \
    "${notes:+ notes=\"$notes\"}" >> "$metrics_file"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
