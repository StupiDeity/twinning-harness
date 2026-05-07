#!/usr/bin/env bash
# Regression-pin: run-local.sh must not contain the legacy `feature/*`
# coexistence path (deleted ENG-67, May 2026). The path silently
# dispatched agents into $TARGET_REPO when a non-canonical
# `feature/eng-N-...` branch existed, mutating the operator's HEAD
# and breaking scope-check (May-2026 ENG-63/64/65 incident).
# PR #48 (commit 4635cd3) closed the upstream cause at the prompt
# level; this test pins the orchestrator side.
#
# Operates on bin/run-local.sh as text (awk + grep). Does NOT source
# run-local.sh (no sentinel — sourcing would fire main).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_LOCAL="$SCRIPT_DIR/run-local.sh"
[[ -f "$RUN_LOCAL" ]] || { printf 'FAIL: missing %s\n' "$RUN_LOCAL" >&2; exit 1; }

PASS=0; FAIL=0
ok()   { printf 'OK: %s\n' "$1"; PASS=$((PASS + 1)); }
nope() { printf 'FAIL: %s — %s\n' "$1" "$2" >&2; FAIL=$((FAIL + 1)); }

# Strip comment lines (lines whose first non-blank char is `#`) and
# blank lines before scanning. The deletion-site comment in
# run-local.sh legitimately cites the historical `feature/*` failure
# mode in prose; that citation is documentation, not code. Only flag
# a re-introduction in executable lines.
non_comment="$(awk '!/^[[:space:]]*#/ && !/^[[:space:]]*$/' "$RUN_LOCAL")"

if printf '%s\n' "$non_comment" | grep -qF 'feature/'; then
  nope 'no feature/ token in non-comment lines' \
    'legacy feature/* coexistence appears to be re-introduced; see ENG-67'
else
  ok 'no feature/ token in non-comment lines (ENG-67)'
fi

if printf '%s\n' "$non_comment" | grep -qF 'legacy feature'; then
  nope 'no "legacy feature" phrase in code' \
    'legacy detection log line re-introduced; see ENG-67'
else
  ok 'no "legacy feature" phrase in non-comment lines'
fi

if printf '%s\n' "$non_comment" | grep -qF 'using old flow'; then
  nope 'no "using old flow" log line' \
    're-introduction of legacy coexistence; see ENG-67'
else
  ok 'no "using old flow" log line'
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
exit $(( FAIL > 0 ? 1 : 0 ))
