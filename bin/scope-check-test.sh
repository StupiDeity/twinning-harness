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

# ─── Case 6: stale local main ─── ENG-59 ─────────────────────────────
# Repro for the false-positive halt where scope-check.sh's diff against
# the local main ref includes commits already merged on origin/main but
# not yet pulled to the host's local main. Fixture sets local main to
# SHA X, simulates origin/main at SHA Y (Y is X plus an out-of-scope
# file), branches off Y, modifies only an in-scope file, and asserts
# the post-fix diff resolves to origin/main...test-branch (clean) and
# scope-check exits 0.
sandbox6="$(mktemp -d -t scope-check-test6-XXXXXX)"
(
  cd "$sandbox6"
  git init -q
  git config user.email t@example.com
  git config user.name 'Test'
  mkdir -p docs/plans
  cat > docs/plans/2026-05-08-eng-test-59.md <<'PLAN'
---
linear: ENG-T59
---
## File Structure
- `IN_SCOPE.md` — the only file this plan declares.
PLAN
  printf 'baseline\n' > IN_SCOPE.md
  printf 'baseline\n' > OUT_OF_SCOPE.md
  git add -A
  git commit -qm "initial (SHA X)"
  git branch -m main
  sha_x="$(git rev-parse HEAD)"

  # Side-branch commit Y: modifies OUT_OF_SCOPE.md (the file the upstream
  # merge will touch). After this commit, sha_y is X's child via this
  # side branch — the same shape as a real upstream merge that hasn't
  # reached the host's local main.
  git checkout -qb upstream-merge
  printf '+upstream change\n' >> OUT_OF_SCOPE.md
  git commit -aqm "upstream merge touches OUT_OF_SCOPE.md (SHA Y)"
  sha_y="$(git rev-parse HEAD)"

  # Simulate origin/main at Y without configuring a remote: write the
  # remote-tracking ref directly. (See plan A-013.)
  git update-ref refs/remotes/origin/main "$sha_y"

  # Roll local main back to X (the operator's stale local main).
  git update-ref refs/heads/main "$sha_x"

  # Agent's branch: off Y, modifies only IN_SCOPE.md (the in-plan file).
  git checkout -qb test-branch "$sha_y"
  printf '+agent change\n' >> IN_SCOPE.md
  git commit -aqm "agent change on IN_SCOPE.md (SHA Z)"
)

if (cd "$sandbox6" && bash "$SCRIPT_DIR/scope-check.sh" ENG-T59 test-branch) >/dev/null 2>&1; then
  pass_at "case-6 stale local main: scope-check resolves diff against origin/main, ignoring upstream-merge files (ENG-59)"
else
  rc=$?
  fail_at "case-6 stale local main: scope-check should pass (rc=0) when only IN_SCOPE.md changes on the agent's branch" "rc=$rc"
fi
rm -rf "$sandbox6"

# ─── Case 7: end-to-end — numbered `## N. File Structure` headings parse ────
# Regression: ENG-96 implement halted with rc=2 because the plan was written
# with `## 3. File Structure` (the H2 numbering style used by the plan-agent
# template for its top-level sections). The pre-fix awk pattern required the
# literal "File Structure" tokens to come immediately after `## `, so any
# `N. ` between the hashes and the title produced an empty extract → exit 2.
# Two plans in flight at fix-time used this shape (ENG-24, ENG-96); fixing
# the parser is cheaper and more durable than re-issuing those plans.
for heading in "3. File Structure" "12. File Structure" "1. File structure"; do
  sandbox7="$(mktemp -d -t scope-check-test7-XXXXXX)"
  (
    cd "$sandbox7"
    git init -q
    git config user.email t@example.com
    git config user.name 'Test'
    mkdir -p docs/plans
    cat > docs/plans/2026-05-13-eng-test-96.md <<PLAN
---
linear: ENG-T96
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
  if (cd "$sandbox7" && bash "$SCRIPT_DIR/scope-check.sh" ENG-T96 test-branch) >/dev/null 2>&1; then
    pass_at "case-7 numbered heading '## $heading' parses and passes scope-check"
  else
    rc=$?
    fail_at "case-7 numbered heading '## $heading'" "rc=$rc (expected 0)"
  fi
  rm -rf "$sandbox7"
done

# ─── Case 8: rc=2 diagnostics distinguish plan-not-found from missing-section
# Regression: ENG-96 halt body read "scope-check rc=2 (likely plan not found
# or File Structure unparseable)" — operators could not tell which side
# failed. Split the stderr text so each branch is independently identifiable.
sandbox8a="$(mktemp -d -t scope-check-test8a-XXXXXX)"
(
  cd "$sandbox8a"
  git init -q
  git config user.email t@example.com
  git config user.name 'Test'
  mkdir -p docs/plans
  # No plan with linear: ENG-T96A frontmatter exists — only a sibling plan
  # with a different ID, which find_canonical_plan must skip.
  cat > docs/plans/2026-05-13-eng-test-96a-other.md <<'PLAN'
---
linear: ENG-OTHER
---
## File Structure
- `CLAUDE.md`
PLAN
  printf 'baseline\n' > CLAUDE.md
  git add -A
  git commit -qm "initial"
  git branch -m main
  git checkout -qb test-branch
  printf '+x\n' >> CLAUDE.md
  git commit -aqm "test"
)
c8a_stderr="$(cd "$sandbox8a" && bash "$SCRIPT_DIR/scope-check.sh" ENG-T96A test-branch 2>&1 1>/dev/null || true)"
if grep -q 'scope-check: plan not found for ENG-T96A' <<<"$c8a_stderr"; then
  pass_at "case-8a plan-not-found diagnostic mentions the missing issue id"
else
  fail_at "case-8a plan-not-found diagnostic" "stderr=$(tr '\n' '|' <<<"$c8a_stderr")"
fi
rm -rf "$sandbox8a"

sandbox8b="$(mktemp -d -t scope-check-test8b-XXXXXX)"
(
  cd "$sandbox8b"
  git init -q
  git config user.email t@example.com
  git config user.name 'Test'
  mkdir -p docs/plans
  # Plan exists for the issue but has no File Structure heading at all.
  cat > docs/plans/2026-05-13-eng-test-96b.md <<'PLAN'
---
linear: ENG-T96B
---
## Goal
Do a thing.

## Backend Tasks
1. Foo.
PLAN
  printf 'baseline\n' > CLAUDE.md
  git add -A
  git commit -qm "initial"
  git branch -m main
  git checkout -qb test-branch
  printf '+x\n' >> CLAUDE.md
  git commit -aqm "test"
)
c8b_stderr="$(cd "$sandbox8b" && bash "$SCRIPT_DIR/scope-check.sh" ENG-T96B test-branch 2>&1 1>/dev/null || true)"
if grep -q 'scope-check: plan=.*2026-05-13-eng-test-96b.md: File Structure section missing' <<<"$c8b_stderr"; then
  pass_at "case-8b missing-section diagnostic mentions the plan path"
else
  fail_at "case-8b missing-section diagnostic" "stderr=$(tr '\n' '|' <<<"$c8b_stderr")"
fi
rm -rf "$sandbox8b"

# ─── QA-Adv-1 (ENG-59): scope-check still SEVERE-flags an undeclared file
# even when the diff base is origin/main rather than local main.
# Pins that the fix does NOT disable scope-check semantics — it only
# changes the merge base. Same fixture shape as case-6 but the agent
# also writes OUT_OF_SCOPE.md (undeclared in plan). Expected rc=3.
sandbox_qa1="$(mktemp -d -t scope-check-qa1-XXXXXX)"
(
  cd "$sandbox_qa1"
  git init -q
  git config user.email t@example.com
  git config user.name 'Test'
  mkdir -p docs/plans
  cat > docs/plans/2026-05-08-eng-test-59-qa1.md <<'PLAN'
---
linear: ENG-T59Q1
---
## File Structure
- `IN_SCOPE.md` — the only file this plan declares.
PLAN
  printf 'baseline\n' > IN_SCOPE.md
  printf 'baseline\n' > OUT_OF_SCOPE.md
  git add -A
  git commit -qm "initial (SHA X)"
  git branch -m main
  sha_x="$(git rev-parse HEAD)"
  git checkout -qb upstream-merge
  printf '+upstream noise\n' >> IN_SCOPE.md
  git commit -aqm "upstream merge (SHA Y)"
  sha_y="$(git rev-parse HEAD)"
  git update-ref refs/remotes/origin/main "$sha_y"
  git update-ref refs/heads/main "$sha_x"
  git checkout -qb test-branch "$sha_y"
  printf '+agent in-scope\n' >> IN_SCOPE.md
  printf '+agent OUT-OF-SCOPE\n' >> OUT_OF_SCOPE.md
  git commit -aqm "agent touches IN_SCOPE.md AND OUT_OF_SCOPE.md (SHA Z)"
)
qa1_rc=0
(cd "$sandbox_qa1" && bash "$SCRIPT_DIR/scope-check.sh" ENG-T59Q1 test-branch) >/dev/null 2>&1 || qa1_rc=$?
[[ "$qa1_rc" == "3" ]] \
  && pass_at "QA-adv-1: stale-local-main + undeclared file → still SEVERE (rc=3); fix preserves scope semantics" \
  || fail_at "QA-adv-1: stale-local-main + undeclared file" "rc=$qa1_rc (expected 3)"
rm -rf "$sandbox_qa1"

# ─── QA-Adv-2 (ENG-59): pins fetch-failure warning text on stderr.
# Without this, a typo / accidental deletion of the log line would
# silently degrade observability — operators rely on this string when
# diagnosing the residual offline-degraded mode (per CLAUDE.md row).
sandbox_qa2="$(mktemp -d -t scope-check-qa2-XXXXXX)"
(
  cd "$sandbox_qa2"
  git init -q
  git config user.email t@example.com
  git config user.name 'Test'
  mkdir -p docs/plans
  cat > docs/plans/2026-05-08-eng-test-59-qa2.md <<'PLAN'
---
linear: ENG-T59Q2
---
## File Structure
- `IN_SCOPE.md` — declared.
PLAN
  printf 'baseline\n' > IN_SCOPE.md
  git add -A
  git commit -qm "initial"
  git branch -m main
  git checkout -qb test-branch
  printf '+agent change\n' >> IN_SCOPE.md
  git commit -aqm "agent change"
)
qa2_stderr="$(cd "$sandbox_qa2" && bash "$SCRIPT_DIR/scope-check.sh" ENG-T59Q2 test-branch 2>&1 1>/dev/null || true)"
if grep -q 'scope-check: fetch origin main failed' <<<"$qa2_stderr" \
   && grep -q 'scope-check: origin/main ref absent' <<<"$qa2_stderr"; then
  pass_at "QA-adv-2: both warning lines emitted on fetch fail + no remote ref (observability pin)"
else
  fail_at "QA-adv-2: fetch-failure warning text" "stderr=$(tr '\n' '|' <<<"$qa2_stderr")"
fi
rm -rf "$sandbox_qa2"

# ─── QA-Adv-3 (ENG-59): real bare-repo origin → fetch SUCCESS arm.
# Plan claims case-6 implicitly covers the online happy path, but
# case-6's fixture has no `origin` remote so its fetch always fails.
# This case configures a real bare repo as origin; fetch actually
# updates refs/remotes/origin/main, exercising the fetch-success arm
# the plan's Failure Mode → Test Map row 4 claims to cover.
sandbox_qa3_origin="$(mktemp -d -t scope-check-qa3-origin-XXXXXX)"
sandbox_qa3="$(mktemp -d -t scope-check-qa3-XXXXXX)"
(
  cd "$sandbox_qa3_origin"
  git init -q --bare
)
(
  cd "$sandbox_qa3"
  git init -q
  git config user.email t@example.com
  git config user.name 'Test'
  git remote add origin "$sandbox_qa3_origin"
  mkdir -p docs/plans
  cat > docs/plans/2026-05-08-eng-test-59-qa3.md <<'PLAN'
---
linear: ENG-T59Q3
---
## File Structure
- `IN_SCOPE.md` — declared.
PLAN
  printf 'baseline\n' > IN_SCOPE.md
  git add -A
  git commit -qm "initial"
  git branch -m main
  git push -q origin main
  git checkout -qb test-branch
  printf '+agent change\n' >> IN_SCOPE.md
  git commit -aqm "agent change"
)
# After scope-check runs, refs/remotes/origin/main should be populated
# by the fetch (even if it wasn't before — we never set it manually).
(cd "$sandbox_qa3" && bash "$SCRIPT_DIR/scope-check.sh" ENG-T59Q3 test-branch) >/dev/null 2>&1
qa3_rc=$?
qa3_origin_sha="$(cd "$sandbox_qa3" && git rev-parse --verify --quiet refs/remotes/origin/main 2>/dev/null || true)"
if [[ "$qa3_rc" == "0" && -n "$qa3_origin_sha" ]]; then
  pass_at "QA-adv-3: real fetch arm — origin remote present, fetch populates refs/remotes/origin/main, scope-check passes (rc=0)"
else
  fail_at "QA-adv-3: real fetch arm" "rc=$qa3_rc origin_sha=$qa3_origin_sha"
fi
rm -rf "$sandbox_qa3" "$sandbox_qa3_origin"

# ─── QA-Adv-4 (ENG-59): branch == "main" produces empty diff → rc=0.
# Edge case: if a stage somehow runs with branch="main" (post-ENG-67
# this should not occur, but worth pinning as inherent to the
# three-dot syntax: origin/main...main is empty when refs match).
sandbox_qa4="$(mktemp -d -t scope-check-qa4-XXXXXX)"
(
  cd "$sandbox_qa4"
  git init -q
  git config user.email t@example.com
  git config user.name 'Test'
  mkdir -p docs/plans
  cat > docs/plans/2026-05-08-eng-test-59-qa4.md <<'PLAN'
---
linear: ENG-T59Q4
---
## File Structure
- `IN_SCOPE.md` — declared.
PLAN
  printf 'baseline\n' > IN_SCOPE.md
  git add -A
  git commit -qm "initial"
  git branch -m main
  git update-ref refs/remotes/origin/main "$(git rev-parse HEAD)"
)
qa4_rc=0
(cd "$sandbox_qa4" && bash "$SCRIPT_DIR/scope-check.sh" ENG-T59Q4 main) >/dev/null 2>&1 || qa4_rc=$?
[[ "$qa4_rc" == "0" ]] \
  && pass_at "QA-adv-4: branch=main with origin/main at same SHA → empty diff → rc=0 (no false positive)" \
  || fail_at "QA-adv-4: branch=main edge case" "rc=$qa4_rc (expected 0)"
rm -rf "$sandbox_qa4"

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
# Uses canonical scope-violation (only token that reaches has_scope_approval
# after T3.1 removed old-shape and T3.7 removed alias normalization).
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
has_scope_approval ENG-HSA1 \
  && pass_at "HSA1: new-shape halt+approve detected" \
  || fail_at "HSA1" "new-shape decision approve after new-scope halt not detected"

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

# ─── Group: ENG-96 profile-driven lockfile inference ──────────────
printf '\n--- ENG-96: profile-driven _profile_lockfile_basenames ---\n'

# The HSA group above reassigned $SCRIPT_DIR to $HSA_STUB_DIR. Restore
# the real bin/ dir so the T8/T8b sandboxes can locate scope-check.sh.
ENG96_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENG96_DIR="$(mktemp -d -t scope-check-eng96-XXXXXX)"
trap 'rm -rf "$HSA_STUB_DIR" "$ENG96_DIR"' EXIT

_eng96_write_profile() {
  local path="$1" gates="$2"
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<EOF
---
slug: test
---
## Build & test gates

$gates

## File layout
- bin/
EOF
}

_eng96_assert_basenames() {
  local case_name="$1" profile_path="$2" expected="$3"  # expected: comma-sep
  local got
  SCOPE_CHECK_PROFILE_PATH="$profile_path" \
    got="$(_profile_lockfile_basenames "$profile_path" | LC_ALL=C sort -u | paste -sd, -)"
  if [[ "$got" == "$expected" ]]; then
    pass_at "$case_name (expected=$expected got=$got)"
  else
    fail_at "$case_name" "expected=$expected got=$got"
  fi
}

# T1: Rust profile → Cargo.lock benign (back-compat anchor; security P1d)
_eng96_write_profile "$ENG96_DIR/T1.md" '- Test: `cargo test --workspace`'
_eng96_assert_basenames 'T1 Rust(cargo)→Cargo.lock' "$ENG96_DIR/T1.md" 'Cargo.lock'

# T2: Node (npm) → package-lock.json
_eng96_write_profile "$ENG96_DIR/T2.md" '- Test: `npm test` and `npm run lint`'
_eng96_assert_basenames 'T2 Node(npm)→package-lock.json' "$ENG96_DIR/T2.md" 'package-lock.json'

# T3: Python (poetry) → poetry.lock
_eng96_write_profile "$ENG96_DIR/T3.md" '- Build: `poetry build`; Test: `poetry run pytest`'
_eng96_assert_basenames 'T3 Python(poetry)→poetry.lock' "$ENG96_DIR/T3.md" 'poetry.lock'

# T4: Go → go.sum (pins word-boundary correctness)
_eng96_write_profile "$ENG96_DIR/T4.md" '- Test: `go test ./...`'
_eng96_assert_basenames 'T4 Go(go)→go.sum' "$ENG96_DIR/T4.md" 'go.sum'

# T5: Bun → both bun.lock and bun.lockb (multi-lockfile PM)
_eng96_write_profile "$ENG96_DIR/T5.md" '- Test: `bun test`'
_eng96_assert_basenames 'T5 Bun(bun)→bun.lock+bun.lockb' "$ENG96_DIR/T5.md" 'bun.lock,bun.lockb'

# T6: Profile missing → empty set
rm -f "$ENG96_DIR/T6-missing.md"  # ensure absent
_eng96_assert_basenames 'T6 missing profile→empty' "$ENG96_DIR/T6-missing.md" ''

# T7: Profile present, no PM tokens (harness-self shape) → empty
_eng96_write_profile "$ENG96_DIR/T7.md" '- Test: `bash bin/dispatch-test.sh && bash bin/run-stage-test.sh`'
_eng96_assert_basenames 'T7 bash-only profile→empty' "$ENG96_DIR/T7.md" ''

# T9: Word-boundary regression — "tango" and "ego" must NOT match cargo/go
_eng96_write_profile "$ENG96_DIR/T9.md" '- Build: `tango build`; Test: my-ego-tool'
_eng96_assert_basenames 'T9 word-boundary tango/ego→empty' "$ENG96_DIR/T9.md" ''

# T10: awk parser robustness — duplicate `## Build & test gates` header
# exits at the first one (awk loops until next `## `, prints first body).
# Asserts no crash + correct PM token detection on first section.
cat > "$ENG96_DIR/T10.md" <<'EOF'
---
slug: test
---
## Build & test gates

- Test: `cargo test`

## Other heading

## Build & test gates

- Test: `poetry run pytest`

## File layout
- bin/
EOF
_eng96_assert_basenames 'T10 duplicate header→first section wins (cargo)' "$ENG96_DIR/T10.md" 'Cargo.lock'

# T11: CRLF line endings — awk's default record separator handles \n,
# so \r\n leaves trailing \r on captured tokens. Asserts behavior is
# benign (no crash; either matches with \r-stripped or fails to match
# cleanly — both acceptable). The contract: helper does NOT crash.
printf -- '---\nslug: test\n---\n## Build & test gates\n\n- Test: `cargo test`\n\n## File layout\n- bin/\n' \
  | tr '\n' '~' | sed 's/~/\r\n/g' | tr -d '~' > "$ENG96_DIR/T11.md" || true
# We don't assert a specific basename — we assert no crash.
if _profile_lockfile_basenames "$ENG96_DIR/T11.md" >/dev/null 2>&1; then
  pass_at "T11 CRLF endings → no crash"
else
  fail_at "T11 CRLF endings" "_profile_lockfile_basenames crashed on CRLF input"
fi

# ─── T8: end-to-end Python (poetry) — plan declares pyproject.toml,
# branch modifies pyproject.toml + poetry.lock, scope-check exits 0.
# Pins the full path through main() including the SCOPE_BENIGN_LOCKFILES
# population (D-005 happy path).
sandbox_t8="$(mktemp -d -t scope-check-t8-XXXXXX)"
profile_t8="$ENG96_DIR/T8-profile.md"
_eng96_write_profile "$profile_t8" '- Build: `poetry build`; Test: `poetry run pytest`'
(
  cd "$sandbox_t8"
  git init -q
  git config user.email t@example.com
  git config user.name 'Test'
  mkdir -p docs/plans
  cat > docs/plans/2026-05-13-eng-test-96.md <<'PLAN'
---
linear: ENG-T96
---
## File Structure
- `pyproject.toml` — bump a dep version.
PLAN
  printf '[tool.poetry]\nname = "x"\n' > pyproject.toml
  printf 'baseline\n' > poetry.lock
  git add -A
  git commit -qm "initial"
  git branch -m main
  git checkout -qb test-branch
  printf '[tool.poetry]\nname = "x-updated"\n' > pyproject.toml
  printf 'baseline + churn\n' > poetry.lock
  git commit -aqm "agent change"
)
t8_rc=0
(cd "$sandbox_t8" && SCOPE_CHECK_PROFILE_PATH="$profile_t8" \
  bash "$ENG96_SCRIPT_DIR/scope-check.sh" ENG-T96 test-branch) >/dev/null 2>&1 || t8_rc=$?
[[ "$t8_rc" == "0" ]] \
  && pass_at "T8 end-to-end Python: pyproject.toml in-plan + poetry.lock benign → rc=0" \
  || fail_at "T8 end-to-end Python" "rc=$t8_rc (expected 0)"
rm -rf "$sandbox_t8"

# ─── T8b: end-to-end Go (product persona insurance) — pins go.sum
# word-boundary behavior end-to-end through main(). Identical shape
# to T8 but with the Go token + go.sum lockfile.
sandbox_t8b="$(mktemp -d -t scope-check-t8b-XXXXXX)"
profile_t8b="$ENG96_DIR/T8b-profile.md"
_eng96_write_profile "$profile_t8b" '- Test: `go test ./...`'
(
  cd "$sandbox_t8b"
  git init -q
  git config user.email t@example.com
  git config user.name 'Test'
  mkdir -p docs/plans
  cat > docs/plans/2026-05-13-eng-test-96b.md <<'PLAN'
---
linear: ENG-T96B
---
## File Structure
- `go.mod` — bump a module version.
PLAN
  printf 'module x\n' > go.mod
  printf 'baseline\n' > go.sum
  git add -A
  git commit -qm "initial"
  git branch -m main
  git checkout -qb test-branch
  printf 'module x-updated\n' > go.mod
  printf 'baseline + churn\n' > go.sum
  git commit -aqm "agent change"
)
t8b_rc=0
(cd "$sandbox_t8b" && SCOPE_CHECK_PROFILE_PATH="$profile_t8b" \
  bash "$ENG96_SCRIPT_DIR/scope-check.sh" ENG-T96B test-branch) >/dev/null 2>&1 || t8b_rc=$?
[[ "$t8b_rc" == "0" ]] \
  && pass_at "T8b end-to-end Go: go.mod in-plan + go.sum benign → rc=0" \
  || fail_at "T8b end-to-end Go" "rc=$t8b_rc (expected 0)"
rm -rf "$sandbox_t8b"

# ─── Group: ENG-96 QA adversarial coverage ──────────────────────────────
# QA-authored tests (not in plan §7 Failure Mode → Test Map). Each pins a
# breakage shape the unit + e2e fixtures above leave unconstrained.
printf '\n--- ENG-96: QA adversarial coverage ---\n'

# QA-ADV-1: is_benign uses BASENAME EQUALITY, not glob — subdirectory
# variants of a profile-derived lockfile basename must NOT be auto-benign.
# Pins the [[ "$f" == "$lf" ]] string-equality semantics so a future
# refactor to `case $f in *$lf)` would visibly regress.
SCOPE_BENIGN_LOCKFILES=('Cargo.lock' 'poetry.lock')
allowed_files=""
allowed_dirs=""
for adv_path in 'Cargo.lock' 'poetry.lock'; do
  is_benign "$adv_path" \
    && pass_at "QA-ADV-1: bare basename '$adv_path' → benign" \
    || fail_at "QA-ADV-1: bare basename" "expected benign for $adv_path"
done
for adv_path in 'evil/Cargo.lock' 'node_modules/poetry.lock' '/Cargo.lock' './Cargo.lock' 'sub/dir/Cargo.lock'; do
  if is_benign "$adv_path"; then
    fail_at "QA-ADV-1: subdir smuggle" "path '$adv_path' wrongly classified benign — basename-equality contract broken"
  else
    pass_at "QA-ADV-1: subdir/abs '$adv_path' → NOT benign (basename equality holds)"
  fi
done

# QA-ADV-2: Unicode look-alike — Cyrillic 'а' (U+0430) in place of ASCII
# 'a'. is_benign's bash [[ == ]] is byte-equality, so non-ASCII variants
# must fail to match the ASCII lockfile name.
adv_uni=$'C\xd0\xb0rgo.lock'  # Cа (Latin C + Cyrillic a) .lock
if is_benign "$adv_uni"; then
  fail_at "QA-ADV-2: unicode look-alike" "Cyrillic-а 'Cаrgo.lock' wrongly classified benign"
else
  pass_at "QA-ADV-2: unicode look-alike 'Cаrgo.lock' → NOT benign (byte-equality holds)"
fi

# QA-ADV-3: _lockfile_for_pm unknown token emits nothing (no crash).
out="$(_lockfile_for_pm 'maven' 2>&1)"
if [[ -z "$out" ]]; then
  pass_at "QA-ADV-3: _lockfile_for_pm unknown token → empty output (no crash)"
else
  fail_at "QA-ADV-3: _lockfile_for_pm unknown" "expected empty, got: $out"
fi
out_empty="$(_lockfile_for_pm '' 2>&1)"
if [[ -z "$out_empty" ]]; then
  pass_at "QA-ADV-3b: _lockfile_for_pm empty arg → empty output (no crash)"
else
  fail_at "QA-ADV-3b: _lockfile_for_pm empty arg" "expected empty, got: $out_empty"
fi

# QA-ADV-4: Section is LAST section in profile — no following '## ' header
# to trigger awk's `exit`. The parser must read to EOF and emit the body.
cat > "$ENG96_DIR/qa-adv4.md" <<'EOF'
---
slug: test
---
## File layout
- bin/

## Build & test gates

- Test: `cargo test`
EOF
_eng96_assert_basenames 'QA-ADV-4: section-as-last (no trailing ## )→cargo→Cargo.lock' \
  "$ENG96_DIR/qa-adv4.md" 'Cargo.lock'

# QA-ADV-5: Multi-PM profile — cargo + bun + poetry tokens together →
# union of all three lockfile sets. Brainstorm Q2 acknowledged this is
# covered implicitly by T1+T5 separately; QA pins the union explicitly.
cat > "$ENG96_DIR/qa-adv5.md" <<'EOF'
---
slug: test
---
## Build & test gates

- Build: `cargo build` (Rust workspace)
- Frontend: `bun install` then `bun run dev`
- Tests: `poetry run pytest tests/`

## File layout
- bin/
EOF
_eng96_assert_basenames 'QA-ADV-5: multi-PM (cargo+bun+poetry) → union' \
  "$ENG96_DIR/qa-adv5.md" 'Cargo.lock,bun.lock,bun.lockb,poetry.lock'

# QA-ADV-6: word-boundary follow-ups beyond T9 — confirm 'go' does NOT
# match inside 'golang' (l is a word char on the right boundary). Also
# confirm 'cargo' DOES match inside 'cargo-nextest' (hyphen breaks word
# boundary). Both pin grep -qwE semantics.
cat > "$ENG96_DIR/qa-adv6a.md" <<'EOF'
---
slug: test
---
## Build & test gates

- Build: `golang stdlib usage`; Test: `golangci-lint run`

## File layout
- bin/
EOF
_eng96_assert_basenames 'QA-ADV-6a: golang/golangci → no go.sum (l is word boundary)' \
  "$ENG96_DIR/qa-adv6a.md" ''

cat > "$ENG96_DIR/qa-adv6b.md" <<'EOF'
---
slug: test
---
## Build & test gates

- Test: `cargo-nextest run --workspace`

## File layout
- bin/
EOF
_eng96_assert_basenames 'QA-ADV-6b: cargo-nextest (hyphen=word break) → Cargo.lock matches' \
  "$ENG96_DIR/qa-adv6b.md" 'Cargo.lock'

# QA-ADV-7: SCOPE_CHECK_PROFILE_PATH set to a DIRECTORY (not a file) →
# [[ -f "$path" ]] returns false → empty set, no crash. Pins the
# missing-path branch when the override is misconfigured.
SCOPE_CHECK_PROFILE_PATH="$ENG96_DIR" \
  got_dir="$(_profile_lockfile_basenames "$ENG96_DIR" 2>&1)"
if [[ -z "$got_dir" ]]; then
  pass_at "QA-ADV-7: profile path=directory → empty (no crash, file-test guard works)"
else
  fail_at "QA-ADV-7: profile=directory" "expected empty, got: $got_dir"
fi

# QA-ADV-8: SCOPE_CHECK_PROFILE_PATH set to empty string → resolver
# falls through to the slug-relative default. Pins [[ -n "..." ]] guard.
# We can't easily assert the full default path resolution (depends on
# $HARNESS_ROOT / $PROJECT_SLUG), but we can verify the empty-string
# override does NOT short-circuit and DOES return a non-empty path.
empty_override_resolved="$(SCOPE_CHECK_PROFILE_PATH='' _resolve_profile_path)"
if [[ -n "$empty_override_resolved" && "$empty_override_resolved" == */learned-rules/*/project-profile.md ]]; then
  pass_at "QA-ADV-8: empty SCOPE_CHECK_PROFILE_PATH → fallback to default (got=$empty_override_resolved)"
else
  fail_at "QA-ADV-8: empty override fallback" "expected slug-relative default, got: $empty_override_resolved"
fi

# QA-ADV-9: end-to-end subdirectory-smuggle attack — Rust profile,
# plan declares `src/main.rs`, branch modifies `src/main.rs` (in-scope)
# AND a smuggled `evil/Cargo.lock` (NOT auto-benign because the
# basename-equality contract excludes subdir variants). Expect rc=3
# (severe) — the scope-check gate must catch this.
sandbox_qa9="$(mktemp -d -t scope-check-qa-adv9-XXXXXX)"
profile_qa9="$ENG96_DIR/qa-adv9-profile.md"
_eng96_write_profile "$profile_qa9" '- Test: `cargo test --workspace`'
(
  cd "$sandbox_qa9"
  git init -q
  git config user.email t@example.com
  git config user.name 'Test'
  mkdir -p docs/plans src evil
  cat > docs/plans/2026-05-13-eng-test-96qa9.md <<'PLAN'
---
linear: ENG-T96QA9
---
## File Structure
- `src/main.rs` — main module.
PLAN
  printf 'fn main() {}\n' > src/main.rs
  printf 'baseline\n' > evil/Cargo.lock
  git add -A
  git commit -qm "initial"
  git branch -m main
  git checkout -qb test-branch
  printf 'fn main() { println!("hi"); }\n' > src/main.rs
  printf 'churn\n' > evil/Cargo.lock
  git commit -aqm "agent change with smuggled subdir lockfile"
)
qa9_rc=0
qa9_out="$(cd "$sandbox_qa9" && SCOPE_CHECK_PROFILE_PATH="$profile_qa9" \
  bash "$ENG96_SCRIPT_DIR/scope-check.sh" ENG-T96QA9 test-branch 2>&1)" || qa9_rc=$?
# rc=3 = severe (preferred); rc=1 = notable also acceptable if `evil/`
# happens to share a top-level segment (it doesn't here, so severe is
# the correct expectation).
if [[ "$qa9_rc" == "3" ]] && grep -q "evil/Cargo.lock" <<<"$qa9_out"; then
  pass_at "QA-ADV-9: e2e subdir smuggle 'evil/Cargo.lock' → rc=3 severe (basename-equality contract holds end-to-end)"
else
  fail_at "QA-ADV-9: e2e subdir smuggle" "rc=$qa9_rc (expected 3) out=$(printf '%s' "$qa9_out" | tr '\n' ' ' | cut -c1-200)"
fi
rm -rf "$sandbox_qa9"

# QA-ADV-10: end-to-end Bun multi-lockfile — profile names `bun`,
# branch modifies BOTH bun.lock AND bun.lockb. T5 unit-tests the helper
# emits both basenames; T8/T8b cover single-lockfile e2e. QA pins the
# multi-lockfile e2e — both basenames must be benign in a single main()
# population block.
sandbox_qa10="$(mktemp -d -t scope-check-qa-adv10-XXXXXX)"
profile_qa10="$ENG96_DIR/qa-adv10-profile.md"
_eng96_write_profile "$profile_qa10" '- Test: `bun test`'
(
  cd "$sandbox_qa10"
  git init -q
  git config user.email t@example.com
  git config user.name 'Test'
  mkdir -p docs/plans
  cat > docs/plans/2026-05-13-eng-test-96qa10.md <<'PLAN'
---
linear: ENG-T96QA10
---
## File Structure
- `package.json` — bump a dep version.
PLAN
  printf '{"name":"x"}\n' > package.json
  printf 'baseline\n' > bun.lock
  printf 'baseline-bin' > bun.lockb
  git add -A
  git commit -qm "initial"
  git branch -m main
  git checkout -qb test-branch
  printf '{"name":"x-updated"}\n' > package.json
  printf 'baseline + churn\n' > bun.lock
  printf 'baseline-bin + churn' > bun.lockb
  git commit -aqm "agent change touching both bun lockfiles"
)
qa10_rc=0
(cd "$sandbox_qa10" && SCOPE_CHECK_PROFILE_PATH="$profile_qa10" \
  bash "$ENG96_SCRIPT_DIR/scope-check.sh" ENG-T96QA10 test-branch) >/dev/null 2>&1 || qa10_rc=$?
[[ "$qa10_rc" == "0" ]] \
  && pass_at "QA-ADV-10: e2e Bun multi-lockfile (bun.lock + bun.lockb both benign) → rc=0" \
  || fail_at "QA-ADV-10: e2e Bun multi-lockfile" "rc=$qa10_rc (expected 0)"
rm -rf "$sandbox_qa10"

# QA-ADV-11: end-to-end observability pin — profile present but section
# absent → empty SCOPE_BENIGN_LOCKFILES + warning log line on stderr. The
# message text is contractual (operator runbook references it).
sandbox_qa11="$(mktemp -d -t scope-check-qa-adv11-XXXXXX)"
profile_qa11="$ENG96_DIR/qa-adv11-profile.md"
cat > "$profile_qa11" <<'EOF'
---
slug: test
---
## File layout
- bin/
EOF
(
  cd "$sandbox_qa11"
  git init -q
  git config user.email t@example.com
  git config user.name 'Test'
  mkdir -p docs/plans
  cat > docs/plans/2026-05-13-eng-test-96qa11.md <<'PLAN'
---
linear: ENG-T96QA11
---
## File Structure
- `README.md` — a doc bump.
PLAN
  printf 'old\n' > README.md
  git add -A
  git commit -qm "initial"
  git branch -m main
  git checkout -qb test-branch
  printf 'new\n' > README.md
  git commit -aqm "agent change"
)
qa11_stderr="$(cd "$sandbox_qa11" && SCOPE_CHECK_PROFILE_PATH="$profile_qa11" \
  bash "$ENG96_SCRIPT_DIR/scope-check.sh" ENG-T96QA11 test-branch 2>&1 1>/dev/null)" || true
if grep -qF 'profile-derived lockfile set empty' <<<"$qa11_stderr"; then
  pass_at "QA-ADV-11: observability pin — empty-set warning lands on stderr"
else
  fail_at "QA-ADV-11: empty-set warning" "expected 'profile-derived lockfile set empty' in stderr; got: $(printf '%s' "$qa11_stderr" | tr '\n' ' ' | cut -c1-200)"
fi
rm -rf "$sandbox_qa11"

echo
echo "scope-check-test: passed=$PASS failed=$FAIL"
(( FAIL == 0 )) || exit 1
