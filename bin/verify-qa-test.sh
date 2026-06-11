#!/usr/bin/env bash
# Tests for bin/verify-qa.sh (ENG-113).
#
# Covers V-1..V-12 — every documented exit code (0 / 42 / 43 / 44), every
# pass-criterion kind (smoke / file_exists / grep / http_get), the D-011
# path-prefix authority surface, the D-013 path-traversal hardening, and
# the --ident cross-check.
#
# Codes 36/37/38 are held by ENG-119 (review-payload-{malformed,
# incomplete,missing}); codes 39/40/41 are held by ENG-117 (qa-payload-*);
# ENG-113 (qa-predicate) lives at 42/43/44 — the gap was closed in review
# iter-3 after the c6722bc rebase observed ENG-117 had taken 39/40/41.
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
# --worktree fence (finding #15) requires the path be a realpath
# subpath of TARGET_REPO. Place the worktree fixture INSIDE TARGET_REPO
# so realpath-on-realpath containment holds. V-4 grep target lives at
# $WT_DIR/bin/verify-qa.sh; V-7's sample.txt lives at $WT_DIR/sample.txt.
# WT_DIR replaces the original $FIXTURE_DIR/wt path; finding #25 noted
# that V-7's grep target relied on V-4's mkdir, so we pre-create here.
WT_DIR="$TARGET_REPO/wt"
mkdir -p "$WT_DIR/bin"
# Defensive path-shape guard before any rm -rf (finding #26).
_assert_temp_path() {
  case "$1" in
    /var/folders/*|/tmp/*|/private/var/folders/*|/private/tmp/*) return 0 ;;
    *) printf 'verify-qa-test: REFUSING to rm %q (not under /tmp or /var/folders)\n' "$1" >&2; exit 99 ;;
  esac
}
_assert_temp_path "$FIXTURE_DIR"
trap 'case "$FIXTURE_DIR" in /var/folders/*|/tmp/*|/private/var/folders/*|/private/tmp/*) rm -rf "$FIXTURE_DIR" ;; esac' EXIT

VERIFIER="$SCRIPT_DIR/verify-qa.sh"

printf '\n--- verify-qa-test: V-1..V-12 + V-13..V-17 + V-15b/V-14b/V-10b + V-23..V-28 ---\n'

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

# Pull the LAST JSONL line (summary) and FIRST per-criterion line. The
# per-criterion lines start at line 1 (validator emits no leading
# diagnostics on the success path), but pull explicitly so future
# additions (a header line, e.g.) don't break the assertion silently
# (finding #24).
_summary_line() { printf '%s\n' "$1" | jq -c 'select(.summary == true)' 2>/dev/null; }
_first_crit_line() { printf '%s\n' "$1" | jq -c 'select(.summary != true)' 2>/dev/null | head -1; }

# ─── V-1: predicate file absent → rc=44 ──────────────────────────────
rc=0
out="$(bash "$VERIFIER" validate "$FIXTURE_DIR/nonexistent.json" 2>&1)" || rc=$?
if (( rc == 44 )) && [[ "$out" == *"qa-predicate-missing"* ]]; then
  pass_at "V-1: missing file → exit 44 + stdout names qa-predicate-missing"
else
  fail_at "V-1: missing file" "expected rc=44 + 'qa-predicate-missing'; got rc=$rc, out=$out"
fi

# ─── V-2: predicate file present, JSON parse error → rc=42 ──────────
printf '{,}\n' > "$PROJECT_STATE_DIR/ENG-1/qa-predicate-ENG-1.json"
rc=0
out="$(bash "$VERIFIER" validate "$PROJECT_STATE_DIR/ENG-1/qa-predicate-ENG-1.json" 2>&1)" || rc=$?
if (( rc == 42 )) && [[ "$out" == *"qa-predicate-malformed"* ]]; then
  pass_at "V-2: JSON parse error → exit 42 + stdout names qa-predicate-malformed"
else
  fail_at "V-2: JSON parse error" "expected rc=42 + 'qa-predicate-malformed'; got rc=$rc, out=$out"
fi

# ─── V-3: schema-incomplete (missing pass_criteria) → rc=43 ──────────
cat > "$PROJECT_STATE_DIR/ENG-1/qa-predicate-ENG-1.json" <<'EOF'
{
  "qa_predicate_schema_version": 1,
  "issue_id": "ENG-1"
}
EOF
rc=0
out="$(bash "$VERIFIER" validate "$PROJECT_STATE_DIR/ENG-1/qa-predicate-ENG-1.json" 2>&1)" || rc=$?
if (( rc == 43 )) && [[ "$out" == *"qa-predicate-incomplete"* ]]; then
  pass_at "V-3: missing pass_criteria → exit 43 + stdout names qa-predicate-incomplete"
else
  fail_at "V-3: missing pass_criteria" "expected rc=43 + 'qa-predicate-incomplete'; got rc=$rc, out=$out"
fi

# ─── V-4: valid, all pass → rc=0, summary failed=0 ──────────────────
f="$(write_valid_predicate qa-predicate-ENG-1.json ENG-1)"
rc=0
# Anchor file_exists at the worktree fixture; pre-create the target file.
printf '#!/bin/sh\n' > "$WT_DIR/bin/verify-qa.sh"
out="$(bash "$VERIFIER" validate "$f" --ident ENG-1 --worktree "$WT_DIR" 2>&1)" || rc=$?
summary_line="$(_summary_line "$out")"
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
out="$(bash "$VERIFIER" validate "$PROJECT_STATE_DIR/ENG-1/qa-predicate-ENG-1.json" --worktree "$WT_DIR" 2>&1)" || rc=$?
per_criterion_line="$(_first_crit_line "$out")"
summary_line="$(_summary_line "$out")"
if (( rc == 0 )) \
   && printf '%s\n' "$per_criterion_line" | jq -e '.pass == false' >/dev/null 2>&1 \
   && printf '%s\n' "$per_criterion_line" | jq -e '.detail.actual_exit == 1 and .detail.expect_exit == 0' >/dev/null 2>&1 \
   && printf '%s\n' "$summary_line" | jq -e '.summary == true and .failed >= 1' >/dev/null 2>&1; then
  pass_at "V-5: smoke 'exit 1' vs expect_exit=0 → per-criterion pass=false (actual_exit cited), summary failed>=1"
else
  fail_at "V-5: smoke fail" "expected rc=0 + first-line pass=false (with actual_exit=1/expect_exit=0 object) + summary failed>=1; got rc=$rc, per=$per_criterion_line, summary=$summary_line"
fi

# ─── V-6: file_exists path absent → pass=false, detail names path ───
# Finding #17: also assert the `detail` shape, not just .pass == false —
# a regression that silently swapped `detail` for `null` on the fail
# path would otherwise pass V-6 today and break operator triage.
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
out="$(bash "$VERIFIER" validate "$PROJECT_STATE_DIR/ENG-1/qa-predicate-ENG-1.json" --worktree "$WT_DIR" 2>&1)" || rc=$?
per_criterion_line="$(_first_crit_line "$out")"
summary_line="$(_summary_line "$out")"
if (( rc == 0 )) \
   && printf '%s\n' "$per_criterion_line" | jq -e '.pass == false' >/dev/null 2>&1 \
   && printf '%s\n' "$per_criterion_line" | jq -e '.detail | type == "string" and (test("no-such-file.txt"))' >/dev/null 2>&1 \
   && printf '%s\n' "$summary_line" | jq -e '.summary == true and .failed >= 1' >/dev/null 2>&1; then
  pass_at "V-6: file_exists absent → per-criterion pass=false + detail names missing path, summary failed>=1"
else
  fail_at "V-6: file_exists absent" "expected rc=0 + pass=false + detail naming 'no-such-file.txt' + summary failed>=1; got rc=$rc, per=$per_criterion_line, summary=$summary_line"
fi

# ─── V-7: grep matches when expect_match=true → pass=true ───────────
mkdir -p "$WT_DIR"  # finding #25: defensive mkdir; do not rely on V-4
printf 'hello world\n' > "$WT_DIR/sample.txt"
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
out="$(bash "$VERIFIER" validate "$PROJECT_STATE_DIR/ENG-1/qa-predicate-ENG-1.json" --worktree "$WT_DIR" 2>&1)" || rc=$?
per_criterion_line="$(_first_crit_line "$out")"
summary_line="$(_summary_line "$out")"
if (( rc == 0 )) \
   && printf '%s\n' "$per_criterion_line" | jq -e '.pass == true' >/dev/null 2>&1 \
   && printf '%s\n' "$summary_line" | jq -e '.summary == true and .failed == 0' >/dev/null 2>&1; then
  pass_at "V-7: grep present-pattern + expect_match=true → per-criterion pass=true, summary failed=0"
else
  fail_at "V-7: grep match" "expected rc=0 + first-line pass=true + summary failed=0; got rc=$rc, per=$per_criterion_line, summary=$summary_line"
fi

# ─── V-8: http_get stub → pass=true + curl argv verified ────────────
# Finding #18: stub must verify --max-time 10 and the URL argument so a
# regression that drops the timeout (DoS surface) trips this test.
STUB_DIR="$FIXTURE_DIR/stubs"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/curl" <<'STUB'
#!/usr/bin/env bash
# Minimal curl stub for verify-qa-test V-8. Honors -w '%{http_code}' AND
# asserts argv contract: --max-time 10 must be present AND the URL must
# be the predicate's url. Writes diagnostics to $STUB_LOG so the test
# can read them post-invocation.
want_code=0 max_time_seen=0 url_seen=""
for arg in "$@"; do
  case "$arg" in
    '%{http_code}') want_code=1 ;;
  esac
done
# Walk argv pairwise: look for --max-time 10.
i=1
while [[ $i -le $# ]]; do
  cur="${!i}"
  if [[ "$cur" == "--max-time" ]]; then
    next_i=$((i+1))
    next="${!next_i}"
    if [[ "$next" == "10" ]]; then max_time_seen=1; fi
  fi
  # Last positional non-flag is the URL.
  case "$cur" in
    -*) ;;
    *) url_seen="$cur" ;;
  esac
  i=$((i+1))
done
# Log assertions for the test to inspect.
{
  printf 'max_time_seen=%s\n' "$max_time_seen"
  printf 'url_seen=%s\n' "$url_seen"
} >> "$STUB_LOG"
if (( want_code == 1 )); then
  printf '200'
fi
exit 0
STUB
chmod +x "$STUB_DIR/curl"
export STUB_LOG="$FIXTURE_DIR/curl-stub.log"
: > "$STUB_LOG"
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
out="$(PATH="$STUB_DIR:$PATH" STUB_LOG="$STUB_LOG" bash "$VERIFIER" validate "$PROJECT_STATE_DIR/ENG-1/qa-predicate-ENG-1.json" --worktree "$WT_DIR" 2>&1)" || rc=$?
per_criterion_line="$(_first_crit_line "$out")"
summary_line="$(_summary_line "$out")"
stub_max="$(grep -c '^max_time_seen=1$' "$STUB_LOG" || true)"
stub_url="$(grep -c '^url_seen=http://example.test/$' "$STUB_LOG" || true)"
if (( rc == 0 )) \
   && printf '%s\n' "$per_criterion_line" | jq -e '.pass == true' >/dev/null 2>&1 \
   && printf '%s\n' "$summary_line" | jq -e '.summary == true and .failed == 0' >/dev/null 2>&1 \
   && (( stub_max >= 1 )) \
   && (( stub_url >= 1 )); then
  pass_at "V-8: http_get stubbed 200 → pass=true + curl saw --max-time 10 + URL exactly"
else
  fail_at "V-8: http_get" "expected pass=true + summary failed=0 + curl-stub.log records max-time + URL; got rc=$rc, per=$per_criterion_line, summary=$summary_line, stub_max=$stub_max, stub_url=$stub_url, stub_log=$(cat "$STUB_LOG")"
fi

# ─── V-9: --ident mismatch → rc=43 ──────────────────────────────────
f="$(write_valid_predicate qa-predicate-ENG-1.json ENG-1)"
rc=0
out="$(bash "$VERIFIER" validate "$f" --ident ENG-2 --worktree "$WT_DIR" 2>&1)" || rc=$?
if (( rc == 43 )) && [[ "$out" == *"qa-predicate-incomplete"* ]] && [[ "$out" == *"issue_id mismatch"* ]]; then
  pass_at "V-9: --ident mismatch → exit 43 + stdout names issue_id mismatch"
else
  fail_at "V-9: --ident mismatch" "expected rc=43 + 'issue_id mismatch'; got rc=$rc, out=$out"
fi

# ─── V-10: file_exists with ../ traversal → rc=43 ───────────────────
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
out="$(bash "$VERIFIER" validate "$PROJECT_STATE_DIR/ENG-1/qa-predicate-ENG-1.json" --worktree "$WT_DIR" 2>&1)" || rc=$?
if (( rc == 43 )) && [[ "$out" == *"path must be worktree-relative"* ]]; then
  pass_at "V-10: file_exists with '../' → exit 43 + traversal diagnostic"
else
  fail_at "V-10: file_exists ../" "expected rc=43 + 'path must be worktree-relative'; got rc=$rc, out=$out"
fi

# ─── V-11: grep with absolute path → rc=43 ─────────────────────────
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
out="$(bash "$VERIFIER" validate "$PROJECT_STATE_DIR/ENG-1/qa-predicate-ENG-1.json" --worktree "$WT_DIR" 2>&1)" || rc=$?
if (( rc == 43 )) && [[ "$out" == *"path must be worktree-relative"* ]]; then
  pass_at "V-11: grep absolute path → exit 43 + traversal diagnostic"
else
  fail_at "V-11: grep absolute path" "expected rc=43 + 'path must be worktree-relative'; got rc=$rc, out=$out"
fi

# ─── V-12: predicate file outside $PROJECT_STATE_DIR → rc=42 ────────
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
out="$(bash "$VERIFIER" validate "$FIXTURE_DIR/escape/qa-predicate-ENG-1.json" --worktree "$WT_DIR" 2>&1)" || rc=$?
if (( rc == 42 )) && [[ "$out" == *"predicate file must live under"* ]]; then
  pass_at "V-12: predicate outside PROJECT_STATE_DIR → exit 42 + authority diagnostic"
else
  fail_at "V-12: predicate outside PROJECT_STATE_DIR" "expected rc=42 + 'predicate file must live under'; got rc=$rc, out=$out"
fi

# ─── V-13: http_get with file:// scheme → rc=43 (critical #5) ──────
cat > "$PROJECT_STATE_DIR/ENG-1/qa-predicate-ENG-1.json" <<'EOF'
{
  "qa_predicate_schema_version": 1,
  "issue_id": "ENG-1",
  "pass_criteria": [
    { "kind": "http_get", "url": "file:///etc/passwd", "expect_status": 200, "expect_body_match": null }
  ]
}
EOF
rc=0
out="$(bash "$VERIFIER" validate "$PROJECT_STATE_DIR/ENG-1/qa-predicate-ENG-1.json" --worktree "$WT_DIR" 2>&1)" || rc=$?
if (( rc == 43 )) && [[ "$out" == *"url must use http:// or https:// scheme"* ]]; then
  pass_at "V-13: http_get file:// → exit 43 + scheme diagnostic"
else
  fail_at "V-13: http_get file://" "expected rc=43 + 'url must use http:// or https:// scheme'; got rc=$rc, out=$out"
fi

# ─── V-14: --worktree outside TARGET_REPO and PROJECT_STATE_DIR → rc=43
mkdir -p "$FIXTURE_DIR/elsewhere"
f="$(write_valid_predicate qa-predicate-ENG-1.json ENG-1)"
rc=0
out="$(bash "$VERIFIER" validate "$f" --ident ENG-1 --worktree "$FIXTURE_DIR/elsewhere" 2>&1)" || rc=$?
if (( rc == 43 )) && [[ "$out" == *"must be a subpath of"* ]]; then
  pass_at "V-14: --worktree outside fence accept-list → exit 43 + fence diagnostic"
else
  fail_at "V-14: --worktree fence" "expected rc=43 + 'must be a subpath of'; got rc=$rc, out=$out"
fi

# ─── V-14b: --worktree under PROJECT_STATE_DIR/<ident>/worktree → accepted (C1)
# Per-issue worktrees resolve to $PROJECT_STATE_DIR/<ident>/worktree/ — the
# pre-fix fence rejected these because they are NOT a TARGET_REPO subpath.
# Post-C1 fix: accept-list widens to include $PROJECT_STATE_DIR subpaths.
ISSUE_WT="$PROJECT_STATE_DIR/ENG-1/worktree"
mkdir -p "$ISSUE_WT/bin"
printf '#!/bin/sh\n' > "$ISSUE_WT/bin/verify-qa.sh"
f="$(write_valid_predicate qa-predicate-ENG-1.json ENG-1)"
rc=0
out="$(bash "$VERIFIER" validate "$f" --ident ENG-1 --worktree "$ISSUE_WT" 2>&1)" || rc=$?
summary_line="$(_summary_line "$out")"
if (( rc == 0 )) \
   && printf '%s\n' "$summary_line" | jq -e '.summary == true and .failed == 0' >/dev/null 2>&1; then
  pass_at "V-14b: --worktree under PROJECT_STATE_DIR/<ident>/worktree → accepted (C1 widened fence)"
else
  fail_at "V-14b: per-issue worktree fence" "expected rc=0 + summary failed=0; got rc=$rc, summary=$summary_line"
fi

# ─── V-14c: no --worktree, PIPELINE_ISSUE_ID auto-derives per-issue worktree (C1)
# AGENT_PROMPTS.md §6 invokes verify-qa.sh WITHOUT --worktree; the auto-derive
# from PIPELINE_ISSUE_ID is what makes the documented invocation work.
f="$(write_valid_predicate qa-predicate-ENG-1.json ENG-1)"
rc=0
out="$(PIPELINE_ISSUE_ID=ENG-1 bash "$VERIFIER" validate "$f" --ident ENG-1 2>&1)" || rc=$?
summary_line="$(_summary_line "$out")"
if (( rc == 0 )) \
   && printf '%s\n' "$summary_line" | jq -e '.summary == true and .failed == 0' >/dev/null 2>&1; then
  pass_at "V-14c: no --worktree + PIPELINE_ISSUE_ID set → auto-derive (C1)"
else
  fail_at "V-14c: auto-derive --worktree" "expected rc=0 + summary failed=0; got rc=$rc, out=$out"
fi

# ─── V-15: file_exists with symlink-pivot → pass=false (critical #4)
# Drop a symlink inside the worktree pointing at /etc/passwd. The
# lexical D-013 guard accepts `path: "leak"` (no ../ no leading /);
# only the executor's realpath containment check stops the exfiltration
# oracle.
ln -sfn /etc/passwd "$WT_DIR/leak"
cat > "$PROJECT_STATE_DIR/ENG-1/qa-predicate-ENG-1.json" <<'EOF'
{
  "qa_predicate_schema_version": 1,
  "issue_id": "ENG-1",
  "pass_criteria": [
    { "kind": "file_exists", "path": "leak" }
  ]
}
EOF
rc=0
out="$(bash "$VERIFIER" validate "$PROJECT_STATE_DIR/ENG-1/qa-predicate-ENG-1.json" --worktree "$WT_DIR" 2>&1)" || rc=$?
per_criterion_line="$(_first_crit_line "$out")"
if (( rc == 0 )) \
   && printf '%s\n' "$per_criterion_line" | jq -e '.pass == false' >/dev/null 2>&1 \
   && printf '%s\n' "$per_criterion_line" | jq -e '.detail | type == "string" and (test("escapes worktree"))' >/dev/null 2>&1; then
  pass_at "V-15: file_exists via symlink to /etc/passwd → pass=false (escape diagnostic)"
else
  fail_at "V-15: symlink pivot" "expected rc=0 + pass=false + 'escapes worktree' detail; got rc=$rc, per=$per_criterion_line"
fi
rm -f "$WT_DIR/leak"

# ─── V-16: predicate file > 64 KiB → rc=42 (M8 file-size cap) ──────
# M8 replaced the criteria-count cap (which did NOT bound wall-clock — 64×60s
# smoke = 64 min, past the 30 min dispatch watchdog) with a byte-size cap at
# the authority phase, which actually bounds memory/parse cost.
LARGE="$PROJECT_STATE_DIR/ENG-1/qa-predicate-ENG-1.json"
{
  printf '{\n  "qa_predicate_schema_version": 1,\n  "issue_id": "ENG-1",\n  "pass_criteria": [\n'
  printf '    { "kind": "smoke", "command": "true", "expect_exit": 0, "expect_stdout_match": null }'
  awk 'BEGIN{ for(i=0;i<2048;i++) printf(",\n    { \"kind\": \"smoke\", \"command\": \"true\", \"expect_exit\": 0, \"expect_stdout_match\": null }") }'
  printf '\n  ]\n}\n'
} > "$LARGE"
size="$(wc -c < "$LARGE" | tr -d ' ')"
rc=0
out="$(bash "$VERIFIER" validate "$LARGE" --worktree "$WT_DIR" 2>&1)" || rc=$?
if (( rc == 42 )) && [[ "$out" == *"qa-predicate-malformed"* ]] && [[ "$out" == *"size"* ]]; then
  pass_at "V-16: predicate > 64 KiB (got $size B) → exit 42 + size-cap diagnostic"
else
  fail_at "V-16: predicate size cap" "expected rc=42 + 'size'; got rc=$rc, out=$out (size=$size)"
fi

# ─── V-17: summary line carries duration_s (not duration_ms) ───────
# Finding #8: prior shape emitted `duration_ms` whose value was
# `seconds × 1000` (always 0/1000/2000 ms); rename + correct unit.
f="$(write_valid_predicate qa-predicate-ENG-1.json ENG-1)"
rc=0
out="$(bash "$VERIFIER" validate "$f" --ident ENG-1 --worktree "$WT_DIR" 2>&1)" || rc=$?
summary_line="$(_summary_line "$out")"
if (( rc == 0 )) \
   && printf '%s\n' "$summary_line" | jq -e '.duration_s | type == "number"' >/dev/null 2>&1 \
   && printf '%s\n' "$summary_line" | jq -e 'has("duration_ms") | not' >/dev/null 2>&1; then
  pass_at "V-17: summary has duration_s (number); no duration_ms misnamed field"
else
  fail_at "V-17: duration field" "expected duration_s number + no duration_ms; got rc=$rc, summary=$summary_line"
fi

# ─── V-15b: two-hop symlink chain → pass=false (C2) ───────────────
# Critical #2: `<wt>/a -> <wt>/b`, `<wt>/b -> /etc/passwd` bypassed the
# single-hop resolver. realpath -m -- canonicalises the full chain in
# one call so both hops are followed.
ln -sfn "$WT_DIR/b_target" "$WT_DIR/a_link"
ln -sfn /etc/passwd "$WT_DIR/b_target"
cat > "$PROJECT_STATE_DIR/ENG-1/qa-predicate-ENG-1.json" <<'EOF'
{
  "qa_predicate_schema_version": 1,
  "issue_id": "ENG-1",
  "pass_criteria": [
    { "kind": "file_exists", "path": "a_link" }
  ]
}
EOF
rc=0
out="$(bash "$VERIFIER" validate "$PROJECT_STATE_DIR/ENG-1/qa-predicate-ENG-1.json" --worktree "$WT_DIR" 2>&1)" || rc=$?
per_criterion_line="$(_first_crit_line "$out")"
if (( rc == 0 )) \
   && printf '%s\n' "$per_criterion_line" | jq -e '.pass == false' >/dev/null 2>&1 \
   && printf '%s\n' "$per_criterion_line" | jq -e '.detail | type == "string" and (test("escapes worktree"))' >/dev/null 2>&1; then
  pass_at "V-15b: two-hop symlink chain → pass=false (C2 chain bypass closed)"
else
  fail_at "V-15b: two-hop chain" "expected rc=0 + pass=false + 'escapes worktree' detail; got rc=$rc, per=$per_criterion_line"
fi
rm -f "$WT_DIR/a_link" "$WT_DIR/b_target"

# ─── V-23: bare '..' lexical guard → rc=43 (M1) ────────────────────
cat > "$PROJECT_STATE_DIR/ENG-1/qa-predicate-ENG-1.json" <<'EOF'
{
  "qa_predicate_schema_version": 1,
  "issue_id": "ENG-1",
  "pass_criteria": [
    { "kind": "file_exists", "path": ".." }
  ]
}
EOF
rc=0
out="$(bash "$VERIFIER" validate "$PROJECT_STATE_DIR/ENG-1/qa-predicate-ENG-1.json" --worktree "$WT_DIR" 2>&1)" || rc=$?
if (( rc == 43 )) && [[ "$out" == *"path must be worktree-relative"* ]]; then
  pass_at "V-23: file_exists bare '..' → exit 43 (M1 lexical guard widened)"
else
  fail_at "V-23: bare '..'" "expected rc=43 + 'path must be worktree-relative'; got rc=$rc, out=$out"
fi

# ─── V-24: http_get loopback host → rc=43 (C4 host-class denylist) ───
cat > "$PROJECT_STATE_DIR/ENG-1/qa-predicate-ENG-1.json" <<'EOF'
{
  "qa_predicate_schema_version": 1,
  "issue_id": "ENG-1",
  "pass_criteria": [
    { "kind": "http_get", "url": "http://127.0.0.1/secret", "expect_status": 200, "expect_body_match": null }
  ]
}
EOF
rc=0
out="$(bash "$VERIFIER" validate "$PROJECT_STATE_DIR/ENG-1/qa-predicate-ENG-1.json" --worktree "$WT_DIR" 2>&1)" || rc=$?
if (( rc == 43 )) && [[ "$out" == *"host"* ]]; then
  pass_at "V-24: http_get to 127.0.0.1 → exit 43 (C4 host-class denylist)"
else
  fail_at "V-24: loopback denylist" "expected rc=43 + 'host' in diagnostic; got rc=$rc, out=$out"
fi

# ─── V-25: http_get IMDS → rc=43 (C4 host-class denylist) ───────────
cat > "$PROJECT_STATE_DIR/ENG-1/qa-predicate-ENG-1.json" <<'EOF'
{
  "qa_predicate_schema_version": 1,
  "issue_id": "ENG-1",
  "pass_criteria": [
    { "kind": "http_get", "url": "http://169.254.169.254/latest/meta-data/", "expect_status": 200, "expect_body_match": null }
  ]
}
EOF
rc=0
out="$(bash "$VERIFIER" validate "$PROJECT_STATE_DIR/ENG-1/qa-predicate-ENG-1.json" --worktree "$WT_DIR" 2>&1)" || rc=$?
if (( rc == 43 )) && [[ "$out" == *"host"* ]]; then
  pass_at "V-25: http_get to 169.254.169.254 → exit 43 (C4 cloud-metadata denylist)"
else
  fail_at "V-25: IMDS denylist" "expected rc=43 + 'host' in diagnostic; got rc=$rc, out=$out"
fi

# ─── V-26: http_get RFC1918 private → rc=43 (C4) ────────────────────
cat > "$PROJECT_STATE_DIR/ENG-1/qa-predicate-ENG-1.json" <<'EOF'
{
  "qa_predicate_schema_version": 1,
  "issue_id": "ENG-1",
  "pass_criteria": [
    { "kind": "http_get", "url": "http://10.0.0.1/foo", "expect_status": 200, "expect_body_match": null }
  ]
}
EOF
rc=0
out="$(bash "$VERIFIER" validate "$PROJECT_STATE_DIR/ENG-1/qa-predicate-ENG-1.json" --worktree "$WT_DIR" 2>&1)" || rc=$?
if (( rc == 43 )) && [[ "$out" == *"host"* ]]; then
  pass_at "V-26: http_get to 10.0.0.1 → exit 43 (C4 RFC1918 denylist)"
else
  fail_at "V-26: RFC1918 denylist" "expected rc=43 + 'host' in diagnostic; got rc=$rc, out=$out"
fi

# ─── V-27: grep against a directory → distinct diagnostic (m7) ──────
mkdir -p "$WT_DIR/somedir"
cat > "$PROJECT_STATE_DIR/ENG-1/qa-predicate-ENG-1.json" <<'EOF'
{
  "qa_predicate_schema_version": 1,
  "issue_id": "ENG-1",
  "pass_criteria": [
    { "kind": "grep", "path": "somedir", "pattern": "x", "expect_match": true }
  ]
}
EOF
rc=0
out="$(bash "$VERIFIER" validate "$PROJECT_STATE_DIR/ENG-1/qa-predicate-ENG-1.json" --worktree "$WT_DIR" 2>&1)" || rc=$?
per_criterion_line="$(_first_crit_line "$out")"
if (( rc == 0 )) \
   && printf '%s\n' "$per_criterion_line" | jq -e '.pass == false' >/dev/null 2>&1 \
   && printf '%s\n' "$per_criterion_line" | jq -e '.detail | type == "string" and (test("directory"; "i"))' >/dev/null 2>&1; then
  pass_at "V-27: grep target is a directory → distinct 'directory' diagnostic (m7)"
else
  fail_at "V-27: grep on directory" "expected pass=false + directory-named detail; got rc=$rc, per=$per_criterion_line"
fi

# ─── V-28: smoke runs at anchor cwd (M4) ───────────────────────────
# Pre-M4: bash -c inherited the runner's PWD; smoke commands depending on
# cwd would observe wherever verify-qa.sh was invoked from. Post-M4 the
# command's cwd is the worktree anchor.
cat > "$PROJECT_STATE_DIR/ENG-1/qa-predicate-ENG-1.json" <<'EOF'
{
  "qa_predicate_schema_version": 1,
  "issue_id": "ENG-1",
  "pass_criteria": [
    { "kind": "smoke", "command": "pwd", "expect_exit": 0, "expect_stdout_match": "/wt$" }
  ]
}
EOF
rc=0
# Invoke from / so the cwd-leak case fails loudly if not cd'd to anchor.
out="$(cd / && bash "$VERIFIER" validate "$PROJECT_STATE_DIR/ENG-1/qa-predicate-ENG-1.json" --worktree "$WT_DIR" 2>&1)" || rc=$?
summary_line="$(_summary_line "$out")"
if (( rc == 0 )) \
   && printf '%s\n' "$summary_line" | jq -e '.summary == true and .failed == 0' >/dev/null 2>&1; then
  pass_at "V-28: smoke 'pwd' matches anchor (M4: cwd at anchor, not runner's PWD)"
else
  fail_at "V-28: smoke at anchor cwd" "expected rc=0 + summary failed=0 (pwd matched $WT_DIR); got rc=$rc, out=$out"
fi

# ─── V-30..V-34: M1 (review iter-3) IPv4/IPv6 encoding-bypass guard ─
# Reviewer-cited cases — every one of these resolves to 127.0.0.1 or
# 0.0.0.0 in curl. The canonical-form denylist arms below missed them.
# Each case asserts the helper now refuses at validate-time (rc=43 +
# 'host' in diagnostic) — symmetric with V-24/V-25/V-26.
_assert_url_denied() {
  local case_id="$1" url="$2"
  cat > "$PROJECT_STATE_DIR/ENG-1/qa-predicate-ENG-1.json" <<EOF
{
  "qa_predicate_schema_version": 1,
  "issue_id": "ENG-1",
  "pass_criteria": [
    { "kind": "http_get", "url": "$url", "expect_status": 200, "expect_body_match": null }
  ]
}
EOF
  local _rc=0 _out
  _out="$(bash "$VERIFIER" validate "$PROJECT_STATE_DIR/ENG-1/qa-predicate-ENG-1.json" --worktree "$WT_DIR" 2>&1)" || _rc=$?
  if (( _rc == 43 )) && [[ "$_out" == *"host"* ]]; then
    pass_at "$case_id: $url → exit 43 (C4 numeric-encoding guard, M1 iter-3)"
  else
    fail_at "$case_id: $url" "expected rc=43 + 'host' in diagnostic; got rc=$_rc, out=$_out"
  fi
}
_assert_url_denied "V-30" "http://2130706433/"
_assert_url_denied "V-31" "http://0x7f000001/"
_assert_url_denied "V-32" "http://0177.0.0.1/"
_assert_url_denied "V-33" "http://0/"
_assert_url_denied "V-34" "http://[::ffff:7f00:1]/"

# ─── V-35: case-insensitive scheme test (minor finding iter-3) ─────
# Pre-fix: ^https?:// was case-sensitive; HTTP://2130706433/ bypassed
# the scheme gate AND combined with the encoding-bypass to land at
# 127.0.0.1. Post-fix the URL is lowercased before the regex, so the
# encoding-bypass guard above still fires.
_assert_url_denied "V-35" "HTTP://2130706433/"

printf '\n━━━ Summary ━━━\nPASS: %d / FAIL: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]] || exit 1
exit 0
