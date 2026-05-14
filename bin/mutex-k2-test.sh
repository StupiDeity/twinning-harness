#!/usr/bin/env bash
# K=2 slot-accounting fixtures for the counting semaphore in common.sh.
#
# Split from bin/mutex-test.sh because that file is on the pre-commit
# hook's KNOWN_BROKEN allowlist for a pre-existing tempdir-cleanup race;
# K=2 is ENG-81's load-bearing contract and needs to gate the commit.
#
# Two cases:
#   AC-N2-FREE-SLOT-2 — cap=2 + slot-1 held; dispatch takes slot-2
#                       immediately (elapsed <2s) AND does not destroy
#                       the test's pre-acquired slot-1.
#   AC-N2-CONTEND     — cap=2 with both slots held; third dispatch
#                       waits ≥3s.

set -euo pipefail
HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PIPELINE_DRY_RUN=1
export LINEAR_API_KEY=test-mock-key
export PROJECT_SLUG=test-slug
HARNESS_STATE_DIR="$(mktemp -d)"
export PROJECT_STATE_DIR="$HARNESS_STATE_DIR/$PROJECT_SLUG"
export HARNESS_STATE_DIR
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

# ── AC-N2-FREE-SLOT-2 ─────────────────────────────────────────────────
# Pins both timing (fast acquire) AND the slot-allocation contract: the
# pre-acquired slot-1 must remain intact after dispatch returns, proving
# the dispatch claimed slot-2 specifically (release_claude_mutex only
# rms _ACQUIRED_SLOT_DIR, so a buggy allocator that raced slot-1 would
# have rm -rf'd the test's lock).
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
[[ -d "$SEM_DIR/slot-1" ]] || {
  echo "FAIL AC-N2-FREE-SLOT-2: slot-1 was destroyed by dispatch (allocator raced slot-1 instead of claiming slot-2)";
  exit 1;
}
rmdir "$SEM_DIR/slot-1" 2>/dev/null || true
echo "OK AC-N2-FREE-SLOT-2 (slot-1 intact, dispatch claimed slot-2, elapsed=${elapsed}s)"

# ── AC-N2-CONTEND ─────────────────────────────────────────────────────
# Review-3 finding #13: soften the timing envelope so the test does not
# flake on slow CI runners. Bump the background-release timer from 3s →
# 4s and lower the assertion to >= 2s. The regression we want to catch is
# "wait loop exits immediately when both slots held" — elapsed ~0s. Any
# elapsed >= 2s proves the wait loop honored the contention; the upper-
# bound elapsed (release_timer + dispatch-startup overhead) is naturally
# bounded by gtimeout above us, no need for a tight test-side ceiling.
reset_sem
mkdir "$SEM_DIR/slot-1"
mkdir "$SEM_DIR/slot-2"
( sleep 4; rmdir "$SEM_DIR/slot-1" 2>/dev/null || true ) &
start="$(date +%s)"
CLAUDE_MAX_CONCURRENT=2 \
  bash "$HARNESS_DIR/dispatch.sh" brainstorming "$PROMPT" >/dev/null 2>&1
elapsed=$(( $(date +%s) - start ))
(( elapsed >= 2 )) || {
  echo "FAIL AC-N2-CONTEND: cap=2 with both slots held should wait (elapsed=$elapsed)";
  exit 1;
}
echo "OK AC-N2-CONTEND (waited ${elapsed}s)"

echo "OK (K=2 free-slot + K=2 contention)"
