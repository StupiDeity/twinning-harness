#!/usr/bin/env bash
# bin/migrate-labels.sh — one-time legacy pipeline-namespace label drain.
#
# Iterates every Linear issue carrying any of the five legacy labels
# (paused, scope-approval-needed, supersede, skip-until-code-changes,
# skip-until-human-acts) and removes the label. Idempotent. Safe to re-run.
#
# Usage:
#   TARGET_REPO=/path/to/target bash bin/migrate-labels.sh [--dry-run]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

LEGACY_LABELS=(
  pipeline:paused
  pipeline:scope-approval-needed
  pipeline:supersede
  pipeline:skip-until-code-changes
  pipeline:skip-until-human-acts
)

# ENG-41 T3: this script is the human lane — operator-driven one-time sweep.
export PIPELINE_WRITER=human

total=0
removed=0
for legacy in "${LEGACY_LABELS[@]}"; do
  log "scanning for issues with label '$legacy'"
  # list-issues-with-label returns JSON; extract identifier field
  while IFS= read -r issue; do
    [[ -z "$issue" ]] && continue
    total=$((total + 1))
    if (( DRY_RUN == 1 )); then
      log "[DRY_RUN] would remove $legacy from $issue"
    else
      bash "$SCRIPT_DIR/linear.sh" remove-label "$issue" "$legacy" 2>/dev/null || true
      removed=$((removed + 1))
    fi
  done < <(bash "$SCRIPT_DIR/linear.sh" list-issues-with-label "$legacy" 2>/dev/null | jq -r '.data.issues.nodes[].identifier // empty')
done

log "migrate-labels: found=$total removed=$removed (dry_run=$DRY_RUN)"
