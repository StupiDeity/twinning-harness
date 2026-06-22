#!/usr/bin/env bash
set -euo pipefail
F="/Users/rajatgoyal/.local/state/twinning-harness/harness/metrics/events.jsonl"
START="2026-05-23T03:30:06Z"
END="2026-06-22T03:30:06Z"

# distinct issues that entered any non-empty stage within window (features_attempted)
attempted=$(jq -rc --arg s "$START" --arg e "$END" '
  select(.ts >= $s and .ts <= $e)
  | select((.stage // "") != "")
  | .issue_id // ""' "$F" \
  | grep -v '^$' | grep -v '^DRY-' | sort -u)

# distinct issues that reached stage:released within window (features_completed)
completed=$(jq -rc --arg s "$START" --arg e "$END" '
  select(.ts >= $s and .ts <= $e)
  | select((.stage // "") == "released")
  | .issue_id // ""' "$F" \
  | grep -v '^$' | grep -v '^DRY-' | sort -u)

n_attempted=$(printf '%s\n' "$attempted" | grep -c . || true)
n_completed=$(printf '%s\n' "$completed" | grep -c . || true)

echo "ATTEMPTED_COUNT=$n_attempted"
echo "COMPLETED_COUNT=$n_completed"
echo "--- attempted ids ---"
printf '%s\n' "$attempted"
echo "--- completed ids ---"
printf '%s\n' "$completed"
