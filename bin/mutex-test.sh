#!/usr/bin/env bash
# Verify dispatch.sh serializes claude calls via the counting semaphore at
# $HARNESS_STATE_DIR/.claude-semaphore/slot-<N>/ (ENG-81; replaces the
# pre-ENG-81 binary mkdir-mutex at .claude-mutex.lock/).
#
# Three contention scenarios:
#   K=1 contention  — pre-acquire slot-1; second dispatch waits ≥3s.
#   K=2 free-slot   — pre-acquire slot-1 only, with cap=2; second dispatch
#                     takes slot-2 immediately (elapsed <2s).
#   K=2 contention  — pre-acquire slot-1 + slot-2, with cap=2; third
#                     dispatch waits ≥3s.
#
# The `[claude-mutex] waiting for lock held by <pid>` log line is preserved
# verbatim across the K=1/binary-mutex → counting-semaphore migration so
# this test's grep keeps anchoring the same operator-visible signal.

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

# ── AC-N2-FREE-SLOT-2: cap=2 + slot-1 held → second acquirer takes slot-2 ──
reset_sem
mkdir "$SEM_DIR/slot-1"
start="$(date +%s)"
CLAUDE_MAX_CONCURRENT=2 \
  bash "$HARNESS_DIR/dispatch.sh" brainstorming "$PROMPT" >/dev/null 2>&1
elapsed=$(( $(date +%s) - start ))
(( elapsed < 2 )) || {
  echo "FAIL AC-N2-FREE-SLOT-2: cap=2 with only slot-1 held should not wait (elapsed=$elapsed)";
  exit 1;
}
rmdir "$SEM_DIR/slot-1" 2>/dev/null || true
echo "OK AC-N2-FREE-SLOT-2 (slot-2 acquired immediately, elapsed=${elapsed}s)"

# ── AC-N2-CONTEND: cap=2 with BOTH slots held → third acquirer waits ──
reset_sem
mkdir "$SEM_DIR/slot-1"
mkdir "$SEM_DIR/slot-2"
( sleep 3; rmdir "$SEM_DIR/slot-1" 2>/dev/null || true ) &
start="$(date +%s)"
CLAUDE_MAX_CONCURRENT=2 \
  bash "$HARNESS_DIR/dispatch.sh" brainstorming "$PROMPT" >/dev/null 2>&1
elapsed=$(( $(date +%s) - start ))
(( elapsed >= 3 )) || {
  echo "FAIL AC-N2-CONTEND: cap=2 with both slots held should wait (elapsed=$elapsed)";
  exit 1;
}
echo "OK AC-N2-CONTEND (waited ${elapsed}s)"

echo "OK (Phase-2 capacity=1 + N=2 free-slot + N=2 contention covered)"
