#!/usr/bin/env bash
# ENG-98: Invariants on bin/dry-run.sh content.
#
# Pins AC1/AC3: bin/dry-run.sh must not invoke `bun -e`, and the
# replacement check must label itself as "GH Actions workflow
# structure" so a future edit cannot silently revert D-1 (per the
# ENG-98 brainstorm at
# docs/brainstorms/2026-05-13-eng-98-de-tauri-bin-dry-run-sh-replace-bun-e-and-document-run-local-sh-path-expectations-design.md).
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

# Matcher: returns 0 iff $1 contains a non-comment line invoking `bun -e`.
# awk skips lines whose first non-whitespace char is `#` (pure comments) and
# scans the rest for `bun` followed by whitespace then `-e`. Known limitation:
# `bun -e` inside a non-comment quoted string (e.g. `echo "...bun -e..."`)
# false-positives — accepted because dry-run.sh has no legitimate reason to
# embed that token in a string literal and a shell-aware parser is overkill.
_has_bun_e() {
  awk '/^[[:space:]]*#/ { next } /bun[[:space:]]+-e/ { found=1 } END { exit !found }' "$1"
}

main() {
  # AC1 invariant: bun -e MUST NOT appear in dry-run.sh as an executed call.
  if _has_bun_e "$DRY_RUN_PATH"; then
    nope 'no-bun-e' \
      "bin/dry-run.sh contains 'bun -e' — D-1 (ENG-98) requires the Bun-coupled YAML check to be replaced by a pure-bash structural check"
  else
    ok 'no-bun-e'
  fi

  # Adversarial coverage on the matcher itself: prove it fires on real
  # `bun -e` invocations (bare and indented) and ignores comment-only
  # references, so a future regression in dry-run.sh cannot pass undetected.
  local tmpdir
  tmpdir="$(mktemp -d -t dry-run-test.XXXXXX)"
  trap 'rm -rf "$tmpdir"' RETURN

  printf '%s\n' '    bun -e "x"' > "$tmpdir/indented.sh"
  if _has_bun_e "$tmpdir/indented.sh"; then
    ok 'matcher-catches-indented'
  else
    nope 'matcher-catches-indented' \
      "matcher MUST fire on indented '    bun -e \"x\"' (the pre-PR shape of bin/dry-run.sh per AC1)"
  fi

  printf '%s\n' 'bun -e "x"' > "$tmpdir/bare.sh"
  if _has_bun_e "$tmpdir/bare.sh"; then
    ok 'matcher-catches-bare'
  else
    nope 'matcher-catches-bare' "matcher MUST fire on bare 'bun -e' invocations"
  fi

  printf '%s\n' '# bun -e example' > "$tmpdir/comment.sh"
  if _has_bun_e "$tmpdir/comment.sh"; then
    nope 'matcher-ignores-comments' \
      "matcher MUST ignore commented-out 'bun -e' references"
  else
    ok 'matcher-ignores-comments'
  fi

  # AC4 invariant: the replacement check's renamed label appears in an
  # actual `check "GH Actions workflow structure …"` invocation, not in a
  # comment or stale documentation. Allow leading whitespace so the anchor
  # does not couple to top-level invocation position.
  if grep -qE '^[[:space:]]*check[[:space:]]+"GH Actions workflow structure' "$DRY_RUN_PATH"; then
    ok 'structural-check-present'
  else
    nope 'structural-check-present' \
      "bin/dry-run.sh missing 'check \"GH Actions workflow structure …\"' invocation — D-1 (ENG-98) replacement check label not present"
  fi

  printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
  (( FAIL == 0 ))
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
