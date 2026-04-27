#!/usr/bin/env bash
# Tests for .pipeline/bin/scope-check.sh (ENG-25).
#
# Bug under test (pre-fix):
#   scope-check.sh:139 used `([a-zA-Z0-9_./-]+/)+[a-zA-Z0-9_.-]+\.[a-zA-Z0-9]+`.
#   The `+` quantifier on the directory-prefix group required at least one
#   trailing `/` before the filename, structurally excluding repo-root files
#   like CLAUDE.md, README.md, package.json from `allowed_files`. Plans that
#   legitimately declared a root file always SEVERE-failed scope-check.
#
# Fix: change `+` → `*` on the directory-prefix group.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PROJECT_SLUG="${PROJECT_SLUG:-test-slug}"

PASS=0
FAIL=0
pass_at() { PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
fail_at() { FAIL=$((FAIL+1)); printf '  ❌ %s — %s\n' "$1" "$2"; }

# The regex source-of-truth — keep in sync with scope-check.sh:139.
ALLOWED_FILES_RE='([a-zA-Z0-9_./-]+/)*[a-zA-Z0-9_.-]+\.[a-zA-Z0-9]+'

# ─── Case 1: regex extracts both repo-root and nested files ──────────
fixture='## File Structure

**Modified:**
- `CLAUDE.md` — additive paragraph at root.
- `docs/reference/foo.md` — nested doc update.
- `package.json` — bump version.
- `README.md` — install steps.
- `.pipeline/bin/scope-check.sh` — the file under test.'

extracted="$(grep -oE "$ALLOWED_FILES_RE" <<<"$fixture" | sort -u)"

for f in CLAUDE.md README.md docs/reference/foo.md package.json .pipeline/bin/scope-check.sh; do
  if grep -qxF "$f" <<<"$extracted"; then
    pass_at "case-1 extract: $f"
  else
    fail_at "case-1 extract: $f" "extracted=$(tr '\n' ' ' <<<"$extracted")"
  fi
done

# ─── Case 2: end-to-end — branch modifying a declared repo-root file passes ──
sandbox="$(mktemp -d -t scope-check-test-XXXXXX)"
trap 'rm -rf "$sandbox"' EXIT

(
  cd "$sandbox"
  git init -q
  git config user.email t@example.com
  git config user.name 'Test'
  mkdir -p docs/plans
  cat > docs/plans/2026-04-25-eng-test-99.md <<'PLAN'
---
linear: ENG-T99
---
## File Structure
- `CLAUDE.md` — additive docs change at repo root.
PLAN
  printf 'baseline\n' > CLAUDE.md
  git add -A
  git commit -qm "initial"
  git branch -m main
  git checkout -qb test-branch
  printf '+more docs\n' >> CLAUDE.md
  git commit -aqm "test branch change"
)

if (cd "$sandbox" && bash "$SCRIPT_DIR/scope-check.sh" ENG-T99 test-branch) >/dev/null 2>&1; then
  pass_at "case-2 end-to-end: scope-check passes when plan declares CLAUDE.md and branch modifies CLAUDE.md"
else
  rc=$?
  fail_at "case-2 end-to-end: scope-check passes for declared repo-root file" "rc=$rc"
fi

# ─── Case 3: end-to-end — undeclared repo-root file is SEVERE ────────
sandbox2="$(mktemp -d -t scope-check-test2-XXXXXX)"
(
  cd "$sandbox2"
  git init -q
  git config user.email t@example.com
  git config user.name 'Test'
  mkdir -p docs/plans docs/reference
  cat > docs/plans/2026-04-25-eng-test-100.md <<'PLAN'
---
linear: ENG-T100
---
## File Structure
- `docs/reference/foo.md` — nested doc.
PLAN
  printf 'baseline\n' > CLAUDE.md
  printf 'baseline\n' > docs/reference/foo.md
  git add -A
  git commit -qm "initial"
  git branch -m main
  git checkout -qb test-branch
  printf '+changes\n' >> CLAUDE.md
  git commit -aqm "branch touches undeclared file"
)
sc_rc=0
(cd "$sandbox2" && bash "$SCRIPT_DIR/scope-check.sh" ENG-T100 test-branch) >/dev/null 2>&1 || sc_rc=$?
[[ "$sc_rc" == "3" ]] \
  && pass_at "case-3 end-to-end: undeclared CLAUDE.md still SEVERE-flags (rc=3)" \
  || fail_at "case-3 end-to-end: undeclared CLAUDE.md SEVERE-flag" "rc=$sc_rc (expected 3)"
rm -rf "$sandbox2"

# ─── Case 4: end-to-end — `## File structure` (lowercase 's') still parses ──
# Regression: ENG-26 implement halted with rc=2 because the extractor only
# matched "File Structure" verbatim. Plans that title the section with any
# of the natural casings should be accepted.
for heading in "File Structure" "File structure" "file structure"; do
  sandbox4="$(mktemp -d -t scope-check-test4-XXXXXX)"
  (
    cd "$sandbox4"
    git init -q
    git config user.email t@example.com
    git config user.name 'Test'
    mkdir -p docs/plans
    cat > docs/plans/2026-04-27-eng-test-126.md <<PLAN
---
linear: ENG-T126
---
## ${heading}
- \`CLAUDE.md\` — additive docs change at repo root.
PLAN
    printf 'baseline\n' > CLAUDE.md
    git add -A
    git commit -qm "initial"
    git branch -m main
    git checkout -qb test-branch
    printf '+more docs\n' >> CLAUDE.md
    git commit -aqm "test branch change"
  )
  if (cd "$sandbox4" && bash "$SCRIPT_DIR/scope-check.sh" ENG-T126 test-branch) >/dev/null 2>&1; then
    pass_at "case-4 heading '## $heading' parses and passes scope-check"
  else
    rc=$?
    fail_at "case-4 heading '## $heading'" "rc=$rc (expected 0)"
  fi
  rm -rf "$sandbox4"
done

echo
echo "scope-check-test: passed=$PASS failed=$FAIL"
(( FAIL == 0 )) || exit 1
