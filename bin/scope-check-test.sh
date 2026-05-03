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

# ─── Case 5: dotfile directory in plan File Structure ────────────────────────
# A plan declaring `.github/workflows/foo.yml` (the harness's first CI workflow,
# ENG-46) must parse `.github/` as an allowed directory. Earlier the awk filter
# `!/\.[a-zA-Z0-9]+\/$/` over-aggressively excluded any `.X/`-shaped match,
# stripping `.github/` along with any malformed `file.ext/` capture. Result:
# the file matched no allowed dir → SEVERE → halt on every subsequent stage.
sandbox5="$(mktemp -d)"
(
  cd "$sandbox5"
  git init -q
  git config user.email t@example.com
  git config user.name 'Test'
  mkdir -p docs/plans .github/workflows
  cat > docs/plans/2026-04-29-eng-test-5.md <<'PLAN'
---
linear: ENG-T5
---
## File Structure
.github/
  workflows/
    foo.yml          NEW (the disputed file)
PLAN
  printf 'baseline\n' > docs/plans/2026-04-29-eng-test-5.md.lock  # noise
  git add docs/plans
  git commit -qm "initial"
  git branch -m main
  git checkout -qb test-branch
  cat > .github/workflows/foo.yml <<'YML'
name: foo
on: { push: {} }
jobs: { lint: { runs-on: ubuntu-latest, steps: [ { uses: actions/checkout@v4 } ] } }
YML
  git add .github
  git commit -qm "add foo workflow"
)
if (cd "$sandbox5" && bash "$SCRIPT_DIR/scope-check.sh" ENG-T5 test-branch) >/dev/null 2>&1; then
  pass_at "case-5 dotfile dir: .github/workflows/foo.yml is in-plan when File Structure declares .github/"
else
  rc=$?
  fail_at "case-5 dotfile dir" "rc=$rc (expected 0; .github/ should parse as allowed dir)"
fi
rm -rf "$sandbox5"

# ─── Group: has_scope_approval new-shape detection (ENG-60 Phase 1) ─────

printf '\n--- has_scope_approval accepts new-shape decision ---\n'

HSA_STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$HSA_STUB_DIR"' EXIT

# Source scope-check.sh to load has_scope_approval (sentinel prevents main from running).
# common.sh needs TARGET_REPO exported — it is already set by the caller.
# After source, SCRIPT_DIR points at bin/; we override it per-fixture below.
PIPELINE_DRY_RUN=1 LINEAR_API_KEY=test-mock-key \
  source "$SCRIPT_DIR/scope-check.sh" 2>/dev/null || true

# Fixture HSA1: new-shape decision approve gate=scope after new-shape halt
# (scope-deviation reason — alias-normalized to scope-violation via T2.0 normalization)
HSA_COMMENTS_JSON='[
  {"id":"c1","createdAt":"2026-05-02T10:00:00Z","body":"<!-- pipeline: verdict result=halt reason=scope-deviation -->"},
  {"id":"c2","createdAt":"2026-05-02T11:00:00Z","body":"<!-- pipeline: decision action=approve gate=scope -->"}
]'
cat > "$HSA_STUB_DIR/linear.sh" <<EOF
#!/bin/bash
[[ "\$1" == "get-comments" ]] && printf '%s' '$HSA_COMMENTS_JSON'
EOF
chmod +x "$HSA_STUB_DIR/linear.sh"
SCRIPT_DIR="$HSA_STUB_DIR"
has_scope_approval ENG-HSA1 \
  && pass_at "HSA1: new-shape halt+approve detected (scope-deviation aliased)" \
  || fail_at "HSA1" "new-shape decision approve after new-shape halt not detected"

# Fixture HSA2: new-shape halt + new-shape decision approve
HSA_COMMENTS_JSON='[
  {"id":"c1","createdAt":"2026-05-02T10:00:00Z","body":"<!-- pipeline: verdict result=halt reason=scope-violation -->"},
  {"id":"c2","createdAt":"2026-05-02T11:00:00Z","body":"<!-- pipeline: decision action=approve gate=scope -->"}
]'
cat > "$HSA_STUB_DIR/linear.sh" <<EOF
#!/bin/bash
[[ "\$1" == "get-comments" ]] && printf '%s' '$HSA_COMMENTS_JSON'
EOF
chmod +x "$HSA_STUB_DIR/linear.sh"
SCRIPT_DIR="$HSA_STUB_DIR"
has_scope_approval ENG-HSA2 \
  && pass_at "HSA2: new-shape halt+approve detected" \
  || fail_at "HSA2" "new-shape halt + new-shape decision approve not detected"

echo
echo "scope-check-test: passed=$PASS failed=$FAIL"
(( FAIL == 0 )) || exit 1
