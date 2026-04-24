#!/usr/bin/env bash
# Test harness for reconcile.sh label-permutation semantics (ENG-6).
#
# Covers the five reconcile cases that the canonical/fuzzy branches must agree on:
#   (a) canonical fixture + no label            → link:<path>
#   (b) canonical fixture + pipeline:supersede  → proceed         [ENG-6 bug repro]
#   (c) canonical fixture + pipeline:extend     → proceed
#   (d) canonical fixture + pipeline:ignore     → link:<path>
#   (e) fuzzy-only fixture + pipeline:supersede → proceed         [fuzzy regression probe]
#
# Pattern: source common.sh + reconcile.sh (the `main "$@"` sentinel at
# reconcile.sh:116-118 short-circuits under sourced invocation), then
# override REPO_ROOT + SCRIPT_DIR to point at a per-run fixture tree and a
# stub linear.sh. Bash variables are global; post-source overrides stick
# for subsequent `main` calls.

set -euo pipefail
HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export PIPELINE_DRY_RUN=1
export LINEAR_API_KEY="${LINEAR_API_KEY:-test-mock-key}"

STUB_DIR="$(mktemp -d)"
FIXTURE_DIR="$(mktemp -d)"
LABELS_FILE="$STUB_DIR/labels.txt"
TITLE_FILE="$STUB_DIR/title.txt"
: > "$LABELS_FILE"
: > "$TITLE_FILE"
export LABELS_FILE TITLE_FILE
trap 'rm -rf "$STUB_DIR" "$FIXTURE_DIR"' EXIT

cat > "$STUB_DIR/linear.sh" <<'SH'
#!/usr/bin/env bash
# args: $1 subcmd $2 ident [$3 label]
case "${1:-}" in
  has-label)
    # exit 0 if $3 is listed on its own line in $LABELS_FILE, else exit 1
    grep -Fxq "${3:-}" "${LABELS_FILE:-/dev/null}"
    ;;
  get-issue)
    printf '{"data":{"issue":{"title":"%s"}}}\n' "$(cat "${TITLE_FILE:-/dev/null}")"
    ;;
  *)
    exit 0
    ;;
esac
SH
chmod +x "$STUB_DIR/linear.sh"

# Source the real scripts (main defined, not invoked — see sentinel at
# reconcile.sh:116-118).
# shellcheck source=common.sh
source "$HARNESS_DIR/common.sh"
# shellcheck source=reconcile.sh
source "$HARNESS_DIR/reconcile.sh"

# Post-source overrides: reconcile.sh:15 sets SCRIPT_DIR; common.sh:7 sets REPO_ROOT.
# Both are top-level assignments and thus overridable globally.
REPO_ROOT="$FIXTURE_DIR"
SCRIPT_DIR="$STUB_DIR"
mkdir -p "$FIXTURE_DIR/docs/brainstorms"

PASS=0; FAIL=0
pass_at() { printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); }
fail_at() { printf '  ❌ %s\n     %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

reset_fixtures() {
  rm -f "$FIXTURE_DIR"/docs/brainstorms/*.md
  : > "$LABELS_FILE"
  : > "$TITLE_FILE"
}

write_canonical_fixture() {
  # $1: relative filename under docs/brainstorms/
  local f="$FIXTURE_DIR/docs/brainstorms/$1"
  cat > "$f" <<MD
---
linear: ENG-TEST
---
# ENG-TEST: test doc
MD
}

write_fuzzy_only_fixture() {
  # $1: relative filename; YAML frontmatter without a `linear:` line, so the
  # canonical frontmatter matcher at reconcile.sh:54-58 exits 1 (the `---`
  # close fence triggers `in_fm && $0=="---" { exit 1 }`). Title line must
  # not contain the ID so the H1 fallback at reconcile.sh:63-67 also misses.
  local f="$FIXTURE_DIR/docs/brainstorms/$1"
  cat > "$f" <<MD
---
date: 2026-04-23
---
# Reconcile canonical match path design
MD
}

expect_out() {
  # $1: case label; $2: expected stdout; $3: actual stdout
  if [[ "$2" == "$3" ]]; then
    pass_at "$1"
  else
    fail_at "$1" "expected=$2 got=$3"
  fi
}

# ─── Case (a): canonical fixture + no label → link:<path> ──────────────
reset_fixtures
write_canonical_fixture "test-canonical.md"
out="$(main ENG-TEST brainstorm)"
expect_out "case-a canonical+no-label → link:docs/brainstorms/test-canonical.md" \
           "link:docs/brainstorms/test-canonical.md" "$out"

# ─── Case (b): canonical fixture + pipeline:supersede → proceed ────────
# This is the ENG-5 bug repro: today reconcile short-circuits before the
# label lookup and emits `link:`. After Tasks 1+2, it emits `proceed`.
reset_fixtures
write_canonical_fixture "test-canonical.md"
printf 'pipeline:supersede\n' > "$LABELS_FILE"
out="$(main ENG-TEST brainstorm)"
expect_out "case-b canonical+supersede → proceed (ENG-5 bug repro)" \
           "proceed" "$out"

# ─── Case (c): canonical fixture + pipeline:extend → proceed ───────────
reset_fixtures
write_canonical_fixture "test-canonical.md"
printf 'pipeline:extend\n' > "$LABELS_FILE"
out="$(main ENG-TEST brainstorm)"
expect_out "case-c canonical+extend → proceed" \
           "proceed" "$out"

# ─── Case (d): canonical fixture + pipeline:ignore → link:<path> ───────
reset_fixtures
write_canonical_fixture "test-canonical.md"
printf 'pipeline:ignore\n' > "$LABELS_FILE"
out="$(main ENG-TEST brainstorm)"
expect_out "case-d canonical+ignore → link:docs/brainstorms/test-canonical.md" \
           "link:docs/brainstorms/test-canonical.md" "$out"

# ─── Case (e): fuzzy-only + pipeline:supersede → proceed (regression) ──
# The fuzzy branch already handles this; the test guards against the
# helper extraction (Task 3) drifting it.
reset_fixtures
write_fuzzy_only_fixture "reconcile-canonical-match-path-design.md"
printf 'pipeline:supersede\n' > "$LABELS_FILE"
printf 'reconcile canonical match path' > "$TITLE_FILE"
out="$(main ENG-TEST brainstorm)"
expect_out "case-e fuzzy+supersede → proceed (fuzzy regression probe)" \
           "proceed" "$out"

echo
echo "reconcile-test: $PASS/$((PASS+FAIL)) cases passed"
(( FAIL == 0 )) || exit 1
