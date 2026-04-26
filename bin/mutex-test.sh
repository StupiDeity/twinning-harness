#!/usr/bin/env bash
# Verify dispatch.sh serializes claude calls via $HARNESS_STATE_DIR/.claude-mutex.lock/.
# We dry-run dispatch.sh from two parallel children; the second must report
# waiting for the first's PID.

set -euo pipefail
HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PIPELINE_DRY_RUN=1
export LINEAR_API_KEY=test-mock-key
export PROJECT_SLUG=test-slug
HARNESS_STATE_DIR="$(mktemp -d)"
export PROJECT_STATE_DIR="$HARNESS_STATE_DIR/$PROJECT_SLUG"
export HARNESS_STATE_DIR
# TARGET_REPO must exist; use a tmpdir — dispatch.sh only needs it for
# common.sh's directory-existence check, not for any real repo operations.
export TARGET_REPO="$HARNESS_STATE_DIR/target-repo"
mkdir -p "$PROJECT_STATE_DIR" "$TARGET_REPO"
trap 'rm -rf "$HARNESS_STATE_DIR"' EXIT

PROMPT="$(mktemp)"
echo "PROMPT BODY" > "$PROMPT"

# Slow-down dispatch.sh so the second invocation actually contends. We do
# this by pre-acquiring the mutex from this test process for 3s before
# launching the dispatch under-test.
mkdir "$HARNESS_STATE_DIR/.claude-mutex.lock"
(
  sleep 3
  rmdir "$HARNESS_STATE_DIR/.claude-mutex.lock"
) &

start="$(date +%s)"
out="$(bash "$HARNESS_DIR/dispatch.sh" brainstorm "$PROMPT" 2>&1)"
elapsed=$(( $(date +%s) - start ))

grep -q 'claude-mutex.*waiting' <<<"$out" \
  || { echo "FAIL: no waiting log line: $out"; exit 1; }
(( elapsed >= 3 )) || { echo "FAIL: did not wait (elapsed=$elapsed)"; exit 1; }

echo "OK (waited ${elapsed}s)"
