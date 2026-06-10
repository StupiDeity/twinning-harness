#!/usr/bin/env bash
# Tests for bin/verify-qa.sh (ENG-113).
#
# Covers V-1..V-12 — every documented exit code (0 / 36 / 37 / 38), every
# pass-criterion kind (smoke / file_exists / grep / http_get), the D-011
# path-prefix authority surface, the D-013 path-traversal hardening, and
# the --ident cross-check.
#
# Pattern: source-and-stub (CLAUDE.md "How tests work"). Tests invoke
# bin/verify-qa.sh via direct CLI call (matches production invocation by
# the QA agent and, later, the orchestrator's post-dispatch detective).

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_DRY_RUN=1
export PIPELINE_DRY_RUN
LINEAR_API_KEY=test-mock-key
export LINEAR_API_KEY

PASS=0; FAIL=0
pass_at() { PASS=$((PASS+1)); printf '  OK %s\n' "$*"; }
fail_at() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$1" "$2" >&2; }

FIXTURE_DIR="$(mktemp -d -t verify-qa-test.XXXXXX)"
# verify-qa.sh sources common.sh which requires TARGET_REPO + PROJECT_SLUG.
export TARGET_REPO="$FIXTURE_DIR/target"
mkdir -p "$TARGET_REPO/.pipeline-config"
printf '{"project":{"slug":"test-slug"}}\n' > "$TARGET_REPO/.pipeline-config/config.json"
export PROJECT_SLUG=test-slug
# D-011: predicate must live under $PROJECT_STATE_DIR. Override default.
export PROJECT_STATE_DIR="$FIXTURE_DIR/project-state"
mkdir -p "$PROJECT_STATE_DIR/ENG-1"
trap 'rm -rf "$FIXTURE_DIR"' EXIT

VERIFIER="$SCRIPT_DIR/verify-qa.sh"

printf '\n--- verify-qa-test: V-1..V-12 ---\n'

# Helper — write a valid predicate fixture (single file_exists criterion).
# Usage: write_valid_predicate <relpath-under-PROJECT_STATE_DIR/ENG-1> [issue_id]
write_valid_predicate() {
  local rel="$1" iid="${2:-ENG-1}"
  local file="$PROJECT_STATE_DIR/ENG-1/$rel"
  cat > "$file" <<EOF
{
  "qa_predicate_schema_version": 1,
  "issue_id": "$iid",
  "pass_criteria": [
    { "kind": "file_exists", "path": "bin/verify-qa.sh" }
  ]
}
EOF
  printf '%s' "$file"
}

# ─── V-1: predicate file absent → rc=38 ──────────────────────────────
rc=0
out="$(bash "$VERIFIER" validate "$FIXTURE_DIR/nonexistent.json" 2>&1)" || rc=$?
if (( rc == 38 )) && [[ "$out" == *"qa-predicate-missing"* ]]; then
  pass_at "V-1: missing file → exit 38 + stdout names qa-predicate-missing"
else
  fail_at "V-1: missing file" "expected rc=38 + 'qa-predicate-missing'; got rc=$rc, out=$out"
fi

# ─── V-2: predicate file present, JSON parse error → rc=36 ──────────
printf '{,}\n' > "$PROJECT_STATE_DIR/ENG-1/qa-predicate-ENG-1.json"
rc=0
out="$(bash "$VERIFIER" validate "$PROJECT_STATE_DIR/ENG-1/qa-predicate-ENG-1.json" 2>&1)" || rc=$?
if (( rc == 36 )) && [[ "$out" == *"qa-predicate-malformed"* ]]; then
  pass_at "V-2: JSON parse error → exit 36 + stdout names qa-predicate-malformed"
else
  fail_at "V-2: JSON parse error" "expected rc=36 + 'qa-predicate-malformed'; got rc=$rc, out=$out"
fi

# ─── V-3: schema-incomplete (missing pass_criteria) → rc=37 ──────────
cat > "$PROJECT_STATE_DIR/ENG-1/qa-predicate-ENG-1.json" <<'EOF'
{
  "qa_predicate_schema_version": 1,
  "issue_id": "ENG-1"
}
EOF
rc=0
out="$(bash "$VERIFIER" validate "$PROJECT_STATE_DIR/ENG-1/qa-predicate-ENG-1.json" 2>&1)" || rc=$?
if (( rc == 37 )) && [[ "$out" == *"qa-predicate-incomplete"* ]]; then
  pass_at "V-3: missing pass_criteria → exit 37 + stdout names qa-predicate-incomplete"
else
  fail_at "V-3: missing pass_criteria" "expected rc=37 + 'qa-predicate-incomplete'; got rc=$rc, out=$out"
fi

# ─── V-4: valid, all pass → rc=0, summary failed=0 ──────────────────
f="$(write_valid_predicate qa-predicate-ENG-1.json ENG-1)"
rc=0
# Anchor file_exists at the worktree fixture; pre-create the target file.
mkdir -p "$FIXTURE_DIR/wt/bin"
printf '#!/bin/sh\n' > "$FIXTURE_DIR/wt/bin/verify-qa.sh"
out="$(bash "$VERIFIER" validate "$f" --ident ENG-1 --worktree "$FIXTURE_DIR/wt" 2>&1)" || rc=$?
summary_line="$(printf '%s\n' "$out" | tail -1)"
if (( rc == 0 )) \
   && printf '%s\n' "$summary_line" | jq -e '.summary == true and .failed == 0' >/dev/null 2>&1; then
  pass_at "V-4: all pass → exit 0 + summary failed=0"
else
  fail_at "V-4: all pass" "expected rc=0 + JSON summary failed=0; got rc=$rc, summary=$summary_line"
fi

# ─── V-5: smoke command fails → per-criterion pass=false, summary failed>=1
cat > "$PROJECT_STATE_DIR/ENG-1/qa-predicate-ENG-1.json" <<'EOF'
{
  "qa_predicate_schema_version": 1,
  "issue_id": "ENG-1",
  "pass_criteria": [
    { "kind": "smoke", "command": "exit 1", "expect_exit": 0, "expect_stdout_match": null }
  ]
}
EOF
rc=0
out="$(bash "$VERIFIER" validate "$PROJECT_STATE_DIR/ENG-1/qa-predicate-ENG-1.json" --worktree "$FIXTURE_DIR/wt" 2>&1)" || rc=$?
per_criterion_line="$(printf '%s\n' "$out" | head -1)"
summary_line="$(printf '%s\n' "$out" | tail -1)"
if (( rc == 0 )) \
   && printf '%s\n' "$per_criterion_line" | jq -e '.pass == false' >/dev/null 2>&1 \
   && printf '%s\n' "$per_criterion_line" | grep -qF 'actual_exit' \
   && printf '%s\n' "$summary_line" | jq -e '.summary == true and .failed >= 1' >/dev/null 2>&1; then
  pass_at "V-5: smoke 'exit 1' vs expect_exit=0 → per-criterion pass=false (actual_exit cited), summary failed>=1"
else
  fail_at "V-5: smoke fail" "expected rc=0 + first-line pass=false (with actual_exit) + summary failed>=1; got rc=$rc, per=$per_criterion_line, summary=$summary_line"
fi

# ─── V-6: file_exists path absent → pass=false, summary failed>=1 ───
cat > "$PROJECT_STATE_DIR/ENG-1/qa-predicate-ENG-1.json" <<'EOF'
{
  "qa_predicate_schema_version": 1,
  "issue_id": "ENG-1",
  "pass_criteria": [
    { "kind": "file_exists", "path": "no-such-file.txt" }
  ]
}
EOF
rc=0
out="$(bash "$VERIFIER" validate "$PROJECT_STATE_DIR/ENG-1/qa-predicate-ENG-1.json" --worktree "$FIXTURE_DIR/wt" 2>&1)" || rc=$?
per_criterion_line="$(printf '%s\n' "$out" | head -1)"
summary_line="$(printf '%s\n' "$out" | tail -1)"
if (( rc == 0 )) \
   && printf '%s\n' "$per_criterion_line" | jq -e '.pass == false' >/dev/null 2>&1 \
   && printf '%s\n' "$summary_line" | jq -e '.summary == true and .failed >= 1' >/dev/null 2>&1; then
  pass_at "V-6: file_exists absent → per-criterion pass=false, summary failed>=1"
else
  fail_at "V-6: file_exists absent" "expected rc=0 + first-line pass=false + summary failed>=1; got rc=$rc, per=$per_criterion_line, summary=$summary_line"
fi

# ─── V-7: grep matches when expect_match=true → pass=true ───────────
printf 'hello world\n' > "$FIXTURE_DIR/wt/sample.txt"
cat > "$PROJECT_STATE_DIR/ENG-1/qa-predicate-ENG-1.json" <<'EOF'
{
  "qa_predicate_schema_version": 1,
  "issue_id": "ENG-1",
  "pass_criteria": [
    { "kind": "grep", "path": "sample.txt", "pattern": "hello", "expect_match": true }
  ]
}
EOF
rc=0
out="$(bash "$VERIFIER" validate "$PROJECT_STATE_DIR/ENG-1/qa-predicate-ENG-1.json" --worktree "$FIXTURE_DIR/wt" 2>&1)" || rc=$?
per_criterion_line="$(printf '%s\n' "$out" | head -1)"
summary_line="$(printf '%s\n' "$out" | tail -1)"
if (( rc == 0 )) \
   && printf '%s\n' "$per_criterion_line" | jq -e '.pass == true' >/dev/null 2>&1 \
   && printf '%s\n' "$summary_line" | jq -e '.summary == true and .failed == 0' >/dev/null 2>&1; then
  pass_at "V-7: grep present-pattern + expect_match=true → per-criterion pass=true, summary failed=0"
else
  fail_at "V-7: grep match" "expected rc=0 + first-line pass=true + summary failed=0; got rc=$rc, per=$per_criterion_line, summary=$summary_line"
fi

# ─── V-8: http_get stub → pass=true ────────────────────────────────
STUB_DIR="$FIXTURE_DIR/stubs"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/curl" <<'STUB'
#!/usr/bin/env bash
# Minimal curl stub for verify-qa-test V-8. Honors -w '%{http_code}'.
want_code=0
for arg in "$@"; do
  case "$arg" in
    '%{http_code}') want_code=1 ;;
  esac
done
if (( want_code == 1 )); then
  printf '200'
fi
exit 0
STUB
chmod +x "$STUB_DIR/curl"
cat > "$PROJECT_STATE_DIR/ENG-1/qa-predicate-ENG-1.json" <<'EOF'
{
  "qa_predicate_schema_version": 1,
  "issue_id": "ENG-1",
  "pass_criteria": [
    { "kind": "http_get", "url": "http://example.test/", "expect_status": 200, "expect_body_match": null }
  ]
}
EOF
rc=0
out="$(PATH="$STUB_DIR:$PATH" bash "$VERIFIER" validate "$PROJECT_STATE_DIR/ENG-1/qa-predicate-ENG-1.json" --worktree "$FIXTURE_DIR/wt" 2>&1)" || rc=$?
per_criterion_line="$(printf '%s\n' "$out" | head -1)"
summary_line="$(printf '%s\n' "$out" | tail -1)"
if (( rc == 0 )) \
   && printf '%s\n' "$per_criterion_line" | jq -e '.pass == true' >/dev/null 2>&1 \
   && printf '%s\n' "$summary_line" | jq -e '.summary == true and .failed == 0' >/dev/null 2>&1; then
  pass_at "V-8: http_get stubbed 200 + expect_status=200 → per-criterion pass=true, summary failed=0"
else
  fail_at "V-8: http_get" "expected rc=0 + first-line pass=true + summary failed=0; got rc=$rc, per=$per_criterion_line, summary=$summary_line"
fi

# ─── V-9: --ident mismatch → rc=37 ──────────────────────────────────
f="$(write_valid_predicate qa-predicate-ENG-1.json ENG-1)"
rc=0
out="$(bash "$VERIFIER" validate "$f" --ident ENG-2 --worktree "$FIXTURE_DIR/wt" 2>&1)" || rc=$?
if (( rc == 37 )) && [[ "$out" == *"qa-predicate-incomplete"* ]] && [[ "$out" == *"issue_id mismatch"* ]]; then
  pass_at "V-9: --ident mismatch → exit 37 + stdout names issue_id mismatch"
else
  fail_at "V-9: --ident mismatch" "expected rc=37 + 'issue_id mismatch'; got rc=$rc, out=$out"
fi

# ─── V-10: file_exists with ../ traversal → rc=37 ───────────────────
cat > "$PROJECT_STATE_DIR/ENG-1/qa-predicate-ENG-1.json" <<'EOF'
{
  "qa_predicate_schema_version": 1,
  "issue_id": "ENG-1",
  "pass_criteria": [
    { "kind": "file_exists", "path": "../escape.txt" }
  ]
}
EOF
rc=0
out="$(bash "$VERIFIER" validate "$PROJECT_STATE_DIR/ENG-1/qa-predicate-ENG-1.json" --worktree "$FIXTURE_DIR/wt" 2>&1)" || rc=$?
if (( rc == 37 )) && [[ "$out" == *"path must be worktree-relative"* ]]; then
  pass_at "V-10: file_exists with '../' → exit 37 + traversal diagnostic"
else
  fail_at "V-10: file_exists ../" "expected rc=37 + 'path must be worktree-relative'; got rc=$rc, out=$out"
fi

# ─── V-11: grep with absolute path → rc=37 ─────────────────────────
cat > "$PROJECT_STATE_DIR/ENG-1/qa-predicate-ENG-1.json" <<'EOF'
{
  "qa_predicate_schema_version": 1,
  "issue_id": "ENG-1",
  "pass_criteria": [
    { "kind": "grep", "path": "/etc/passwd", "pattern": "root", "expect_match": true }
  ]
}
EOF
rc=0
out="$(bash "$VERIFIER" validate "$PROJECT_STATE_DIR/ENG-1/qa-predicate-ENG-1.json" --worktree "$FIXTURE_DIR/wt" 2>&1)" || rc=$?
if (( rc == 37 )) && [[ "$out" == *"path must be worktree-relative"* ]]; then
  pass_at "V-11: grep absolute path → exit 37 + traversal diagnostic"
else
  fail_at "V-11: grep absolute path" "expected rc=37 + 'path must be worktree-relative'; got rc=$rc, out=$out"
fi

# ─── V-12: predicate file outside $PROJECT_STATE_DIR → rc=36 ────────
mkdir -p "$FIXTURE_DIR/escape"
cat > "$FIXTURE_DIR/escape/qa-predicate-ENG-1.json" <<'EOF'
{
  "qa_predicate_schema_version": 1,
  "issue_id": "ENG-1",
  "pass_criteria": [
    { "kind": "file_exists", "path": "bin/verify-qa.sh" }
  ]
}
EOF
rc=0
out="$(bash "$VERIFIER" validate "$FIXTURE_DIR/escape/qa-predicate-ENG-1.json" --worktree "$FIXTURE_DIR/wt" 2>&1)" || rc=$?
if (( rc == 36 )) && [[ "$out" == *"predicate file must live under"* ]]; then
  pass_at "V-12: predicate outside PROJECT_STATE_DIR → exit 36 + authority diagnostic"
else
  fail_at "V-12: predicate outside PROJECT_STATE_DIR" "expected rc=36 + 'predicate file must live under'; got rc=$rc, out=$out"
fi

printf '\n━━━ Summary ━━━\nPASS: %d / FAIL: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]] || exit 1
exit 0
