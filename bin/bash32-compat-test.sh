#!/usr/bin/env bash
# Guard: every script under bin/ must run on the launchd host's bash.
#
# Why this exists: the host has ONLY /bin/bash 3.2.57 (no Homebrew bash 5),
# and the launchd plists invoke `/bin/bash <script>` explicitly. A bash-4+
# construct therefore does not fail at lint time on a dev machine with a
# newer bash — it fails at 03:30 on Monday in launchd, silently, with the
# whole job dead. This has bitten three times:
#   1. render-prompt UTF-8 ${var//…} hang (LC_ALL=C fix).
#   2. run-retrospective-local.sh `local -A shape_rcs` (ENG-130) — killed
#      the weekly retrospective for weeks before anyone noticed (all
#      retrospective-*/ artifact dirs were empty).
#   3. (this guard exists so there is no #3 of the same class.)
#
# Two assertions:
#   A. No bash-4+ ONLY constructs in any bin/*.sh (grep, comments stripped).
#   B. Every bin/*.sh parses under /bin/bash -n (3.2 syntax).
#
# If you legitimately need a bash-4 feature, the answer is NOT to allowlist
# it — it is to rewrite it 3.2-safe (parallel arrays for assoc arrays, a
# `tr`/`awk` pipe for case conversion, a read-loop for mapfile). The host
# is bash 3.2; that is not negotiable here.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$(basename "${BASH_SOURCE[0]}")"

PASS=0
FAIL=0
pass_at() { PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
fail_at() { FAIL=$((FAIL+1)); printf '  ❌ %s — %s\n' "$1" "$2"; }

# label|extended-regex  — each matches a construct introduced after bash 3.2.
PATTERNS=(
  'associative-array (local/declare -A)|\b(local|declare|typeset|readonly)[[:space:]]+-[A-Za-z]*A\b'
  'nameref (local/declare -n)|\b(local|declare|typeset)[[:space:]]+-[A-Za-z]*n\b'
  'mapfile/readarray|\b(mapfile|readarray)\b'
  'case-conversion ${v,,} / ${v^^}|\$\{[A-Za-z0-9_@*]+(\[[^]]*\])?[,^]'
  'append-both redirect &>>|&>>'
)

# Strip shell comments WITHOUT mangling ${#arr} / $# (a `#` that means
# "length"/"arg-count" is preceded by `{` or `$`, never by start-of-line
# or whitespace). First clause: full-line comments. Second: inline ` #…`.
# sed blanks lines rather than deleting them, so grep -n line numbers still
# match the original file.
strip_comments() { sed -E 's/^[[:space:]]*#.*$//; s/[[:space:]]#.*$//' "$1"; }

# ─── Assertion A: no bash-4+ constructs ──────────────────────────────
violations=0
for f in "$SCRIPT_DIR"/*.sh; do
  [[ "$(basename "$f")" == "$SELF" ]] && continue   # this file holds the patterns as data
  stripped="$(strip_comments "$f")"
  for entry in "${PATTERNS[@]}"; do
    label="${entry%%|*}"
    re="${entry#*|}"
    hits="$(printf '%s\n' "$stripped" | grep -nE "$re" || true)"
    if [[ -n "$hits" ]]; then
      violations=$((violations+1))
      while IFS= read -r h; do
        fail_at "bash-4 construct in $(basename "$f"):${h%%:*}" "$label → ${h#*:}"
      done <<< "$hits"
    fi
  done
done
if (( violations == 0 )); then
  pass_at "no bash-4+ constructs in any bin/*.sh"
fi

# ─── Assertion B: every script parses under /bin/bash (3.2 on host) ───
BASH32="/bin/bash"
if [[ -x "$BASH32" ]]; then
  parse_fail=0
  for f in "$SCRIPT_DIR"/*.sh; do
    if ! err="$("$BASH32" -n "$f" 2>&1)"; then
      parse_fail=$((parse_fail+1))
      fail_at "syntax error under $BASH32: $(basename "$f")" "$err"
    fi
  done
  (( parse_fail == 0 )) && pass_at "all bin/*.sh parse under $BASH32 ($("$BASH32" --version | head -1 | grep -oE 'version [0-9.]+'))"
else
  printf '  ⚠️  %s not present; skipping syntax assertion (dev machine)\n' "$BASH32"
fi

echo
echo "bash32-compat-test: passed=$PASS failed=$FAIL"
(( FAIL == 0 )) || exit 1
