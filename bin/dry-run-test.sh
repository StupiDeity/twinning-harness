#!/usr/bin/env bash
# ENG-98: Invariants on bin/dry-run.sh content.
#
# Pins AC1/AC3: bin/dry-run.sh must not invoke `bun -e`, and the
# replacement check must label itself as "GH Actions workflow
# structure" so a future edit cannot silently revert D-1 (per the
# ENG-98 brainstorm at docs/brainstorms/2026-05-13-eng-98-…-design.md).
#
# Picked up by .githooks/pre-commit's `for t in bin/*-test.sh` glob.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DRY_RUN_PATH="$HARNESS_ROOT/bin/dry-run.sh"
[[ -f "$DRY_RUN_PATH" ]] \
  || { printf 'FATAL: not found: %s\n' "$DRY_RUN_PATH" >&2; exit 1; }

PASS=0; FAIL=0
ok()   { printf 'OK: %s\n' "$1"; PASS=$((PASS+1)); }
nope() { printf 'FAIL: %s\n  reason: %s\n' "$1" "$2" >&2; FAIL=$((FAIL+1)); }

main() {
  # AC1 invariant: bun -e MUST NOT appear in dry-run.sh as an executed call.
  # Pattern anchors to non-comment lines so a future "we replaced bun -e"
  # comment cannot false-positive (review #4).
  if grep -qE '^[[:space:]]*[^#[:space:]].*bun[[:space:]]+-e' "$DRY_RUN_PATH"; then
    nope 'no-bun-e' \
      "bin/dry-run.sh contains 'bun -e' — D-1 (ENG-98) requires the Bun-coupled YAML check to be replaced by a pure-bash structural check"
  else
    ok 'no-bun-e'
  fi

  # AC4 invariant: the replacement check's renamed label appears in an
  # actual `check "GH Actions workflow structure: …"` invocation, not in a
  # comment or stale documentation (review #3 — vacuous-anchor fix).
  if grep -qE '^check[[:space:]]+"GH Actions workflow structure:' "$DRY_RUN_PATH"; then
    ok 'structural-check-present'
  else
    nope 'structural-check-present' \
      "bin/dry-run.sh missing 'check \"GH Actions workflow structure: …\"' invocation — D-1 (ENG-98) replacement check label not present"
  fi

  printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
  (( FAIL == 0 ))
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
