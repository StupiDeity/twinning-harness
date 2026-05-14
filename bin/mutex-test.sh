#!/usr/bin/env bash
# Verify dispatch.sh serializes claude calls via the counting semaphore at
# $HARNESS_STATE_DIR/.claude-semaphore/slot-<N>/.
#
# K=1 contention: pre-acquire slot-1; second dispatch waits ≥3s and the
# wait log enumerates the held slot. K=2 cases live in
# bin/mutex-k2-test.sh — this file is on the pre-commit KNOWN_BROKEN
# allowlist for a pre-existing tempdir-cleanup race, so the K=2 cases
# (which need to gate the commit) are in a separate file.

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

SEM_DIR="$HARNESS_STATE_DIR/.claude-semaphore"

reset_sem() {
  rm -rf "$SEM_DIR"
  mkdir -p "$SEM_DIR"
}

# ── K=1 contention (regression — preserves pre-ENG-81 contract) ──────
# Slow-down dispatch.sh so the second invocation actually contends. We do
# this by pre-acquiring slot-1 from this test process for 3s before
# launching the dispatch under-test.
#
# CLAUDE_MAX_CONCURRENT=1 forces cap=1 so the pre-held slot-1 is the only
# slot dispatch.sh can target — without this, Task 7's default cap=2 would
# let dispatch take slot-2 immediately and the wait would never happen.
reset_sem
mkdir "$SEM_DIR/slot-1"
(
  sleep 3
  rmdir "$SEM_DIR/slot-1" 2>/dev/null || true
) &

start="$(date +%s)"
out="$(CLAUDE_MAX_CONCURRENT=1 bash "$HARNESS_DIR/dispatch.sh" brainstorming "$PROMPT" 2>&1)" || true
elapsed=$(( $(date +%s) - start ))

grep -q 'claude-mutex.*waiting' <<<"$out" \
  || { echo "FAIL K=1: no waiting log line: $out"; exit 1; }
(( elapsed >= 3 )) || { echo "FAIL K=1: did not wait (elapsed=$elapsed)"; exit 1; }
echo "OK K=1 contention (waited ${elapsed}s)"

# Slot enumeration in the wait log: under K>1 the
# "[claude-mutex] waiting for lock held by …" message must enumerate
# ALL held slots (by slot id and pid), not just slot-1.
case "$out" in
  *"slot-1"*)
    echo "OK K=1 wait log enumerates slot-1 (slot-enumeration contract)"
    ;;
  *)
    echo "FAIL K=1: wait log does not enumerate slot-1 holders: $out"
    exit 1
    ;;
esac

echo "OK (K=1 contention + slot-enumeration; K=2 cases in mutex-k2-test.sh)"
