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
# ENG-113 (qa-predicate) lives at 42/43/44.
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
# --worktree fence requires the path be a realpath subpath of
# TARGET_REPO. Place the worktree fixture INSIDE TARGET_REPO so
# realpath-on-realpath containment holds. V-4 grep target lives at
# $WT_DIR/bin/verify-qa.sh. Pre-create here so each test case does
# not need its own mkdir.
WT_DIR="$TARGET_REPO/wt"
mkdir -p "$WT_DIR/bin"
# Defensive path-shape guard before any rm -rf.
_assert_temp_path() {
  case "$1" in
    /var/folders/*|/tmp/*|/private/var/folders/*|/private/tmp/*) return 0 ;;
    *) printf 'verify-qa-test: REFUSING to rm %q (not under /tmp or /var/folders)\n' "$1" >&2; exit 99 ;;
  esac
}
_assert_temp_path "$FIXTURE_DIR"
trap 'case "$FIXTURE_DIR" in /var/folders/*|/tmp/*|/private/var/folders/*|/private/tmp/*) rm -rf "$FIXTURE_DIR" ;; esac' EXIT

VERIFIER="$SCRIPT_DIR/verify-qa.sh"

printf '\n--- verify-qa-test: V-1..V-44 (44 cases + sub-cases) ---\n'

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
# additions (a header line, e.g.) don't break the assertion silently.
_summary_line() { printf '%s\n' "$1" | jq -c 'select(.summary == true)' 2>/dev/null; }
_first_crit_line() { printf '%s\n' "$1" | jq -c 'select(.summary != true)' 2>/dev/null | head -1; }

# ─── V-1: predicate file absent → rc=44 ──────────────────────────────
# Fixture lives under $PROJECT_STATE_DIR so the missing-file (rc=44) and
# path-prefix (rc=42) axes are orthogonal: pre-fix, the test happened to
# pass because the missing-file check runs before the path-prefix check,
# but the ordering is undocumented contract. Keeping the path under
# $PROJECT_STATE_DIR pins the pure-missing case independently.
rc=0
out="$(bash "$VERIFIER" validate "$PROJECT_STATE_DIR/ENG-1/nonexistent.json" 2>&1)" || rc=$?
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
# Asserts the specific diagnostic phrase (pass_criteria must be an array)
# in addition to the contract prefix — mirrors V-37/V-38/V-39's
# per-branch diagnostic pin so a regression that returns rc=43 with a
# generic "incomplete" message is caught.
cat > "$PROJECT_STATE_DIR/ENG-1/qa-predicate-ENG-1.json" <<'EOF'
{
  "qa_predicate_schema_version": 1,
  "issue_id": "ENG-1"
}
EOF
rc=0
out="$(bash "$VERIFIER" validate "$PROJECT_STATE_DIR/ENG-1/qa-predicate-ENG-1.json" 2>&1)" || rc=$?
if (( rc == 43 )) \
   && [[ "$out" == *"qa-predicate-incomplete"* ]] \
   && [[ "$out" == *"pass_criteria must be an array"* ]]; then
  pass_at "V-3: missing pass_criteria → exit 43 + 'qa-predicate-incomplete' + 'pass_criteria must be an array'"
else
  fail_at "V-3: missing pass_criteria" "expected rc=43 + 'qa-predicate-incomplete' + 'pass_criteria must be an array'; got rc=$rc, out=$out"
fi

# ─── V-3b: empty pass_criteria array → rc=43 ────────────────────────
# Covers verify-qa.sh:275 — the `pc_len == 0` arm of _validate_predicate_schema.
# V-3 covers pass_criteria absent (type check fails); V-3b covers the
# array-present-but-empty branch which is otherwise unhit by the suite.
cat > "$PROJECT_STATE_DIR/ENG-1/qa-predicate-ENG-1.json" <<'EOF'
{
  "qa_predicate_schema_version": 1,
  "issue_id": "ENG-1",
  "pass_criteria": []
}
EOF
rc=0
out="$(bash "$VERIFIER" validate "$PROJECT_STATE_DIR/ENG-1/qa-predicate-ENG-1.json" 2>&1)" || rc=$?
if (( rc == 43 )) \
   && [[ "$out" == *"qa-predicate-incomplete"* ]] \
   && [[ "$out" == *"pass_criteria must contain at least 1 entry"* ]]; then
  pass_at "V-3b: empty pass_criteria array → exit 43 + 'pass_criteria must contain at least 1 entry'"
else
  fail_at "V-3b: empty pass_criteria" "expected rc=43 + 'pass_criteria must contain at least 1 entry'; got rc=$rc, out=$out"
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
# Asserts the `detail` shape, not just .pass == false — a regression
# that silently swapped `detail` for `null` on the fail path would
# otherwise pass V-6 and break operator triage.
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
# Per-case mktemp dir isolates V-7's grep target from V-15/V-15b's
# symlink residue: a future case forgetting cleanup must not silently
# shift V-7's assertions onto stale state. WT_V7 is removed at script
# exit via the FIXTURE_DIR EXIT trap (parent dir).
WT_V7="$(mktemp -d "$TARGET_REPO/wt-v7-XXXXXX")"
printf 'hello world\n' > "$WT_V7/sample.txt"
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
out="$(bash "$VERIFIER" validate "$PROJECT_STATE_DIR/ENG-1/qa-predicate-ENG-1.json" --worktree "$WT_V7" 2>&1)" || rc=$?
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
# Stub verifies --max-time 10 and the URL argument so a regression that
# drops the timeout (DoS surface) trips this test.
STUB_DIR="$FIXTURE_DIR/stubs"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/curl" <<'STUB'
#!/usr/bin/env bash
# Minimal curl stub for verify-qa-test V-8/V-8b/V-8c. Honors -w
# '%{http_code}' AND -o <path> AND asserts argv contract: --max-time 10
# must be present, the URL must be the predicate's url, -sS must be
# present (silent + show-errors — a regression that drops -S silently
# eats stderr; one that adds -k disables TLS verification), -k must
# NOT be present, AND --proto '=http,https' / --proto-redir
# '=http,https' MUST be present (without these flags curl honors
# file://, scp://, dict:// schemes which a 30x redirect attack could
# exploit even though -L isn't passed today — preventive defense),
# AND --max-filesize MUST be present (bounds the body byte count so a
# legitimate or attacker URL streaming hundreds of MB within --max-time
# 10s cannot exhaust disk before the EXIT trap cleans body_tmp — same
# DoS-byte-cap intent as the predicate-file 64 KiB cap).
# Writes diagnostics to $STUB_LOG so the test can read them
# post-invocation.
# Env knobs: $STUB_BODY (default empty) — bytes written to -o path,
#            $STUB_STATUS (default 200) — printed to stdout via -w.
want_code=0 max_time_seen=0 url_seen="" out_path=""
sS_seen=0 k_seen=0 proto_seen=0 proto_redir_seen=0 max_filesize_seen=0
# Walk argv pairwise: look for --max-time 10 AND -o <path>.
i=1
while [[ $i -le $# ]]; do
  cur="${!i}"
  case "$cur" in
    '%{http_code}') want_code=1 ;;
    --max-time)
      next_i=$((i+1))
      next="${!next_i}"
      if [[ "$next" == "10" ]]; then max_time_seen=1; fi
      ;;
    -o)
      next_i=$((i+1))
      out_path="${!next_i}"
      ;;
    --proto)
      # Real curl: `--proto '=http,https'` restricts the initial-URL
      # scheme to http/https. The leading `=` is the "exact set" form
      # (no inheritance from default). Accept either '=http,https' or
      # 'http,https' to keep the assertion shape-tolerant.
      next_i=$((i+1))
      next="${!next_i}"
      if [[ "$next" == *http* && "$next" == *https* ]]; then proto_seen=1; fi
      ;;
    --proto-redir)
      # Same shape as --proto but applies to the redirect target. Even
      # though -L is not used today (preventive), curl honors this for
      # default-on redirects if someone adds -L without removing the
      # flag, and a regression that drops it re-opens the file://
      # redirect window.
      next_i=$((i+1))
      next="${!next_i}"
      if [[ "$next" == *http* && "$next" == *https* ]]; then proto_redir_seen=1; fi
      ;;
    --max-filesize)
      # Real curl: `--max-filesize <bytes>` aborts the transfer when the
      # body exceeds <bytes>. Accept any positive integer — the exact
      # value is a defense-in-depth tuning parameter, not a contract;
      # a regression that drops the flag entirely is the failure mode
      # this pin guards against.
      next_i=$((i+1))
      next="${!next_i}"
      if [[ "$next" =~ ^[0-9]+$ ]] && (( next > 0 )); then max_filesize_seen=1; fi
      ;;
  esac
  # Detect -sS (any single-dash flag bundle containing both s and S)
  # and -k. Real curl accepts -sS as one bundled flag, or -s -S split.
  case "$cur" in
    -sS|-Ss) sS_seen=1 ;;
    -s)
      # Split -s from -S — accept if a later positional arg is -S.
      for ((k=i+1; k<=$#; k++)); do
        kk="${!k}"
        [[ "$kk" == "-S" ]] && { sS_seen=1; break; }
      done
      ;;
    -k|--insecure) k_seen=1 ;;
    -*k|-*k*) [[ "$cur" == -*k* && "$cur" != --* ]] && k_seen=1 ;;
  esac
  # Last positional non-flag is the URL.
  case "$cur" in
    -*) ;;
    *) url_seen="$cur" ;;
  esac
  i=$((i+1))
done
# Honor -o: write body to the requested path.
if [[ -n "$out_path" ]]; then
  printf '%s\n' "${STUB_BODY:-}" > "$out_path"
fi
# Log assertions for the test to inspect.
{
  printf 'max_time_seen=%s\n' "$max_time_seen"
  printf 'url_seen=%s\n' "$url_seen"
  printf 'sS_seen=%s\n' "$sS_seen"
  printf 'k_seen=%s\n' "$k_seen"
  printf 'proto_seen=%s\n' "$proto_seen"
  printf 'proto_redir_seen=%s\n' "$proto_redir_seen"
  printf 'max_filesize_seen=%s\n' "$max_filesize_seen"
} >> "$STUB_LOG"
if (( want_code == 1 )); then
  printf '%s' "${STUB_STATUS:-200}"
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
stub_sS="$(grep -c '^sS_seen=1$' "$STUB_LOG" || true)"
stub_k="$(grep -c '^k_seen=1$' "$STUB_LOG" || true)"
stub_proto="$(grep -c '^proto_seen=1$' "$STUB_LOG" || true)"
stub_proto_redir="$(grep -c '^proto_redir_seen=1$' "$STUB_LOG" || true)"
stub_max_filesize="$(grep -c '^max_filesize_seen=1$' "$STUB_LOG" || true)"
total_calls="$(grep -c '^max_time_seen=' "$STUB_LOG" || true)"
# Pin single-curl invocation. A two-curl shape (one for status, one for
# body) would log max_time_seen=1 TWICE; a `>= 1` assertion would let
# it pass silently. Also pin -sS present and -k absent: dropping -S
# silently eats curl stderr (triage friction); adding -k disables TLS
# verification (security regression). Pin --proto / --proto-redir
# present: dropping either re-opens the file:// / scp:// scheme
# escape window through a 30x redirect (preventive defense — V-13
# pins the initial-URL scheme gate only). Pin --max-filesize present:
# dropping it lets a hundred-MB body stream into body_tmp before the
# --max-time wall-clock fires, exhausting disk.
if (( rc == 0 )) \
   && printf '%s\n' "$per_criterion_line" | jq -e '.pass == true' >/dev/null 2>&1 \
   && printf '%s\n' "$summary_line" | jq -e '.summary == true and .failed == 0' >/dev/null 2>&1 \
   && (( stub_max == 1 )) \
   && (( stub_url == 1 )) \
   && (( stub_sS == 1 )) \
   && (( stub_k == 0 )) \
   && (( stub_proto == 1 )) \
   && (( stub_proto_redir == 1 )) \
   && (( stub_max_filesize == 1 )) \
   && (( total_calls == 1 )); then
  pass_at "V-8: http_get stubbed 200 → pass=true + EXACTLY one curl call with --max-time 10 + URL + -sS + --proto + --proto-redir + --max-filesize + -k absent"
else
  fail_at "V-8: http_get" "expected pass=true + summary failed=0 + curl ONCE + -sS + --proto + --proto-redir + --max-filesize + -k absent; got rc=$rc, per=$per_criterion_line, summary=$summary_line, stub_max=$stub_max, stub_url=$stub_url, stub_sS=$stub_sS, stub_k=$stub_k, stub_proto=$stub_proto, stub_proto_redir=$stub_proto_redir, stub_max_filesize=$stub_max_filesize, total_calls=$total_calls, stub_log=$(cat "$STUB_LOG")"
fi

# ─── V-8b: http_get expect_body_match true-path ─────────────────────
# The stub writes "hello\n" to its -o path; predicate expects to match
# "hello". Exercises the body-fetch + grep arm of _exec_http_get.
: > "$STUB_LOG"  # rotate so V-8b doesn't accumulate V-8's counts
cat > "$PROJECT_STATE_DIR/ENG-1/qa-predicate-ENG-1.json" <<'EOF'
{
  "qa_predicate_schema_version": 1,
  "issue_id": "ENG-1",
  "pass_criteria": [
    { "kind": "http_get", "url": "http://example.test/", "expect_status": 200, "expect_body_match": "hello" }
  ]
}
EOF
rc=0
out="$(PATH="$STUB_DIR:$PATH" STUB_LOG="$STUB_LOG" STUB_BODY=hello bash "$VERIFIER" validate "$PROJECT_STATE_DIR/ENG-1/qa-predicate-ENG-1.json" --worktree "$WT_DIR" 2>&1)" || rc=$?
per_criterion_line="$(_first_crit_line "$out")"
summary_line="$(_summary_line "$out")"
total_calls="$(grep -c '^max_time_seen=' "$STUB_LOG" || true)"
if (( rc == 0 )) \
   && printf '%s\n' "$per_criterion_line" | jq -e '.pass == true' >/dev/null 2>&1 \
   && printf '%s\n' "$summary_line" | jq -e '.summary == true and .failed == 0' >/dev/null 2>&1 \
   && (( total_calls == 1 )); then
  pass_at "V-8b: http_get expect_body_match='hello' + body='hello' → pass=true + single curl"
else
  fail_at "V-8b: body-match true-path" "expected pass=true + single curl; got rc=$rc, per=$per_criterion_line, summary=$summary_line, total_calls=$total_calls"
fi

# ─── V-8c: http_get expect_body_match false-path ────────────────────
# Stub writes "other\n"; predicate expects "hello". Body mismatch must
# produce pass=false + detail naming "body did not match".
: > "$STUB_LOG"
cat > "$PROJECT_STATE_DIR/ENG-1/qa-predicate-ENG-1.json" <<'EOF'
{
  "qa_predicate_schema_version": 1,
  "issue_id": "ENG-1",
  "pass_criteria": [
    { "kind": "http_get", "url": "http://example.test/", "expect_status": 200, "expect_body_match": "hello" }
  ]
}
EOF
rc=0
out="$(PATH="$STUB_DIR:$PATH" STUB_LOG="$STUB_LOG" STUB_BODY=other bash "$VERIFIER" validate "$PROJECT_STATE_DIR/ENG-1/qa-predicate-ENG-1.json" --worktree "$WT_DIR" 2>&1)" || rc=$?
per_criterion_line="$(_first_crit_line "$out")"
summary_line="$(_summary_line "$out")"
total_calls="$(grep -c '^max_time_seen=' "$STUB_LOG" || true)"
if (( rc == 0 )) \
   && printf '%s\n' "$per_criterion_line" | jq -e '.pass == false and (.detail | test("body did not match"))' >/dev/null 2>&1 \
   && printf '%s\n' "$summary_line" | jq -e '.summary == true and .failed == 1' >/dev/null 2>&1 \
   && (( total_calls == 1 )); then
  pass_at "V-8c: http_get expect_body_match='hello' + body='other' → pass=false + 'body did not match'"
else
  fail_at "V-8c: body-match false-path" "expected pass=false + 'body did not match' + failed=1 + single curl; got rc=$rc, per=$per_criterion_line, summary=$summary_line, total_calls=$total_calls"
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

# ─── V-14b: --worktree under PROJECT_STATE_DIR/<ident>/worktree → accepted
# Per-issue worktrees resolve to $PROJECT_STATE_DIR/<ident>/worktree/ — a
# TARGET_REPO-only fence would reject these. Accept-list widens to
# include $PROJECT_STATE_DIR subpaths.
ISSUE_WT="$PROJECT_STATE_DIR/ENG-1/worktree"
mkdir -p "$ISSUE_WT/bin"
printf '#!/bin/sh\n' > "$ISSUE_WT/bin/verify-qa.sh"
f="$(write_valid_predicate qa-predicate-ENG-1.json ENG-1)"
rc=0
out="$(bash "$VERIFIER" validate "$f" --ident ENG-1 --worktree "$ISSUE_WT" 2>&1)" || rc=$?
summary_line="$(_summary_line "$out")"
if (( rc == 0 )) \
   && printf '%s\n' "$summary_line" | jq -e '.summary == true and .failed == 0' >/dev/null 2>&1; then
  pass_at "V-14b: --worktree under PROJECT_STATE_DIR/<ident>/worktree → accepted (widened fence)"
else
  fail_at "V-14b: per-issue worktree fence" "expected rc=0 + summary failed=0; got rc=$rc, summary=$summary_line"
fi

# ─── V-14c: no --worktree, PIPELINE_ISSUE_ID auto-derives per-issue worktree
# AGENT_PROMPTS.md §6 invokes verify-qa.sh WITHOUT --worktree; the auto-derive
# from PIPELINE_ISSUE_ID is what makes the documented invocation work.
f="$(write_valid_predicate qa-predicate-ENG-1.json ENG-1)"
rc=0
out="$(PIPELINE_ISSUE_ID=ENG-1 bash "$VERIFIER" validate "$f" --ident ENG-1 2>&1)" || rc=$?
summary_line="$(_summary_line "$out")"
if (( rc == 0 )) \
   && printf '%s\n' "$summary_line" | jq -e '.summary == true and .failed == 0' >/dev/null 2>&1; then
  pass_at "V-14c: no --worktree + PIPELINE_ISSUE_ID set → auto-derive"
else
  fail_at "V-14c: auto-derive --worktree" "expected rc=0 + summary failed=0; got rc=$rc, out=$out"
fi

# ─── V-14d: auto-derive worktree fence — symlink-pivot via PIPELINE_ISSUE_ID
# Reviewer iter-6 M1 (verify-qa.sh:177-188): the auto-derive branch
# previously bypassed the in_target/in_state fence. Plant a symlink at
# $(issue_dir ENG-VICTIM)/worktree → /etc; if the fence runs on the
# auto-derive branch, RESOLVED_WORKTREE (after `cd && pwd -P`) lands
# at /etc which is neither under TARGET_REPO nor PROJECT_STATE_DIR
# → rc=43 with fence diagnostic. Pre-fix: auto-derive set
# RESOLVED_WORKTREE=/etc unchecked, and a file_exists criterion for
# `passwd` would pass — confirming the D-011 trust anchor was broken.
mkdir -p "$PROJECT_STATE_DIR/ENG-VICTIM"
ln -sfn /etc "$PROJECT_STATE_DIR/ENG-VICTIM/worktree"
# Place the predicate under the per-issue state dir (D-011 path-prefix surface).
cat > "$PROJECT_STATE_DIR/ENG-VICTIM/qa-predicate-ENG-VICTIM.json" <<'EOF'
{
  "qa_predicate_schema_version": 1,
  "issue_id": "ENG-VICTIM",
  "pass_criteria": [
    { "kind": "file_exists", "path": "passwd" }
  ]
}
EOF
rc=0
out="$(PIPELINE_ISSUE_ID=ENG-VICTIM bash "$VERIFIER" validate "$PROJECT_STATE_DIR/ENG-VICTIM/qa-predicate-ENG-VICTIM.json" --ident ENG-VICTIM 2>&1)" || rc=$?
if (( rc == 43 )) && [[ "$out" == *"must be a subpath of"* ]]; then
  pass_at "V-14d: auto-derive --worktree → fence applies, symlink to /etc rejected"
else
  fail_at "V-14d: auto-derive fence" "expected rc=43 + 'must be a subpath of'; got rc=$rc, out=$out"
fi
rm -f "$PROJECT_STATE_DIR/ENG-VICTIM/worktree"

# ─── V-15: file_exists with symlink-pivot → pass=false
# Drop a symlink inside the worktree pointing at /etc/passwd. The
# lexical D-013 guard accepts `path: "leak"` (no ../ no leading /);
# only the executor's realpath containment check stops the exfiltration
# oracle. Per-case mktemp dir isolates the leak symlink so a future
# case forgetting cleanup cannot silently shift V-15b's chain assertions.
WT_V15="$(mktemp -d "$TARGET_REPO/wt-v15-XXXXXX")"
ln -sfn /etc/passwd "$WT_V15/leak"
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
out="$(bash "$VERIFIER" validate "$PROJECT_STATE_DIR/ENG-1/qa-predicate-ENG-1.json" --worktree "$WT_V15" 2>&1)" || rc=$?
per_criterion_line="$(_first_crit_line "$out")"
if (( rc == 0 )) \
   && printf '%s\n' "$per_criterion_line" | jq -e '.pass == false' >/dev/null 2>&1 \
   && printf '%s\n' "$per_criterion_line" | jq -e '.detail | type == "string" and (test("escapes worktree"))' >/dev/null 2>&1; then
  pass_at "V-15: file_exists via symlink to /etc/passwd → pass=false (escape diagnostic)"
else
  fail_at "V-15: symlink pivot" "expected rc=0 + pass=false + 'escapes worktree' detail; got rc=$rc, per=$per_criterion_line"
fi

# ─── V-16: predicate file > 64 KiB → rc=42 (file-size cap) ─────────
# The byte-size cap replaced a criteria-count cap which did NOT bound
# wall-clock (64×60s smoke = 64 min, past the 30 min dispatch watchdog).
# Bytes-per-parse is the cost that matters for DoS.
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
# Prior shape emitted `duration_ms` whose value was `seconds × 1000`
# (always 0/1000/2000 ms); rename + correct unit.
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

# ─── V-15b: two-hop symlink chain → pass=false ───────────────────────
# `<wt>/a -> <wt>/b`, `<wt>/b -> /etc/passwd` bypassed the single-hop
# resolver. realpath -m -- canonicalises the full chain in one call so
# both hops are followed. Per-case mktemp dir keeps the chain isolated
# from V-7/V-15 residue (and from any future case forgetting cleanup).
WT_V15B="$(mktemp -d "$TARGET_REPO/wt-v15b-XXXXXX")"
ln -sfn "$WT_V15B/b_target" "$WT_V15B/a_link"
ln -sfn /etc/passwd "$WT_V15B/b_target"
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
out="$(bash "$VERIFIER" validate "$PROJECT_STATE_DIR/ENG-1/qa-predicate-ENG-1.json" --worktree "$WT_V15B" 2>&1)" || rc=$?
per_criterion_line="$(_first_crit_line "$out")"
if (( rc == 0 )) \
   && printf '%s\n' "$per_criterion_line" | jq -e '.pass == false' >/dev/null 2>&1 \
   && printf '%s\n' "$per_criterion_line" | jq -e '.detail | type == "string" and (test("escapes worktree"))' >/dev/null 2>&1; then
  pass_at "V-15b: two-hop symlink chain → pass=false (chain bypass closed)"
else
  fail_at "V-15b: two-hop chain" "expected rc=0 + pass=false + 'escapes worktree' detail; got rc=$rc, per=$per_criterion_line"
fi

# ─── V-23: bare '..' lexical guard → rc=43 ─────────────────────────
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
  pass_at "V-23: file_exists bare '..' → exit 43 (lexical guard)"
else
  fail_at "V-23: bare '..'" "expected rc=43 + 'path must be worktree-relative'; got rc=$rc, out=$out"
fi

# ─── V-24: http_get loopback host → rc=43 (host-class denylist) ──────
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
if (( rc == 43 )) && [[ "$out" == *"on the denylist"* ]]; then
  pass_at "V-24: http_get to 127.0.0.1 → exit 43 (host-class denylist)"
else
  fail_at "V-24: loopback denylist" "expected rc=43 + 'on the denylist' in diagnostic; got rc=$rc, out=$out"
fi

# ─── V-25: http_get IMDS → rc=43 (host-class denylist) ──────────────
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
if (( rc == 43 )) && [[ "$out" == *"on the denylist"* ]]; then
  pass_at "V-25: http_get to 169.254.169.254 → exit 43 (cloud-metadata denylist)"
else
  fail_at "V-25: IMDS denylist" "expected rc=43 + 'on the denylist' in diagnostic; got rc=$rc, out=$out"
fi

# ─── V-26: http_get RFC1918 private → rc=43 ─────────────────────────
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
if (( rc == 43 )) && [[ "$out" == *"on the denylist"* ]]; then
  pass_at "V-26: http_get to 10.0.0.1 → exit 43 (RFC1918 denylist)"
else
  fail_at "V-26: RFC1918 denylist" "expected rc=43 + 'on the denylist' in diagnostic; got rc=$rc, out=$out"
fi

# ─── V-27: grep against a directory → distinct diagnostic ──────────
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
  pass_at "V-27: grep target is a directory → distinct 'directory' diagnostic"
else
  fail_at "V-27: grep on directory" "expected pass=false + directory-named detail; got rc=$rc, per=$per_criterion_line"
fi

# ─── V-28: smoke runs at anchor cwd ─────────────────────────────────
# A naive bash -c that inherits the runner's PWD would have smoke
# commands observe wherever verify-qa.sh was invoked from. The
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
  pass_at "V-28: smoke 'pwd' matches anchor (cwd at anchor, not runner's PWD)"
else
  fail_at "V-28: smoke at anchor cwd" "expected rc=0 + summary failed=0 (pwd matched $WT_DIR); got rc=$rc, out=$out"
fi

# ─── V-30..V-34: IPv4/IPv6 numeric-encoding bypass guard ────────────
# Every one of these URLs resolves to 127.0.0.1 or 0.0.0.0 in curl. A
# canonical-form-only denylist misses them. Each case asserts the
# helper refuses at validate-time (rc=43 + 'host' in diagnostic) —
# symmetric with V-24/V-25/V-26.
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
  # Pin the literal denylist phrase (not just "host") so a regression that
  # drops the deny-list semantic but still emits "host" (e.g. "connect to
  # host refused") cannot pass — symmetric to V-10/V-11's
  # "path must be worktree-relative" phrase pin.
  if (( _rc == 43 )) && [[ "$_out" == *"on the denylist"* ]]; then
    pass_at "$case_id: $url → exit 43 (numeric-encoding guard)"
  else
    fail_at "$case_id: $url" "expected rc=43 + 'on the denylist' in diagnostic; got rc=$_rc, out=$_out"
  fi
}
# ─── V-26b..V-26i: positive SSRF coverage gap fill ────────────────────
# Iter-4 landed _url_host_class_denied arms for 192.168.* / 172.16-31.* /
# localhost / 0.0.0.0 / fe80:* / fc00:/fd00:* ULA, but only V-24/V-25/V-26
# pinned them (loopback / IMDS / class-10). Per-arm assertions below
# close the test-coverage gap so a regression dropping any arm trips a
# specific case.
_assert_url_denied "V-26b" "http://192.168.0.1/foo"
_assert_url_denied "V-26c" "http://172.16.0.1/foo"
_assert_url_denied "V-26d" "http://172.31.255.255/foo"
_assert_url_denied "V-26e" "http://[fe80::1]/foo"
_assert_url_denied "V-26f" "http://[fc00::1]/foo"
_assert_url_denied "V-26g" "http://[fd00::1]/foo"
_assert_url_denied "V-26h" "http://localhost/foo"
_assert_url_denied "V-26i" "http://0.0.0.0/foo"

# ─── V-26j/V-26k: 172.16-31 boundary negative controls ──────────────
# The RFC1918 172.16/12 block bounds at 172.16.0.0..172.31.255.255. A
# regression that widened the arm to `172.*` (or narrowed it to a single
# octet) would silently change classification of public 172.15.* /
# 172.32.* hosts. Source common.sh and invoke _url_host_class_denied
# directly so the negative assertion doesn't depend on curl reaching a
# real public host.
_assert_url_class_check() {
  local case_id="$1" url="$2" expect="$3"  # expect: denied | allowed
  local _rc=0
  bash -c "TARGET_REPO='$TARGET_REPO' PROJECT_SLUG='$PROJECT_SLUG' source '$SCRIPT_DIR/common.sh' 2>/dev/null && _url_host_class_denied '$url'" || _rc=$?
  case "$expect" in
    denied)
      if (( _rc == 0 )); then pass_at "$case_id: $url → denied"
      else fail_at "$case_id" "expected denied (rc=0), got rc=$_rc"
      fi ;;
    allowed)
      if (( _rc == 1 )); then pass_at "$case_id: $url → allowed (negative control)"
      else fail_at "$case_id" "expected allowed (rc=1), got rc=$_rc"
      fi ;;
  esac
}
_assert_url_class_check "V-26j" "http://172.15.0.1/foo" "allowed"
_assert_url_class_check "V-26k" "http://172.32.0.1/foo" "allowed"

# ─── V-26L..V-26P: SSRF bypass via `@` in path/query/fragment ──────────
# `_url_host_class_denied` strips userinfo (`${rest##*@}`) with greedy
# match. RFC 3986 puts `@` only inside the authority component, but curl
# parses path/query/fragment as data — any `@` there belongs to the
# request, not userinfo. Pre-fix the validator stripped userinfo BEFORE
# isolating the authority, so `http://127.0.0.1/@public.com/` had its
# host parsed as `public.com` (greedy strip ate through the path) while
# curl connected to `127.0.0.1`. Same parser-divergence class as the
# iter-3 case-insensitive scheme and iter-5 unbracketed-IPv6 truncation.
# Cases below cover the five attack surfaces named in the iter-8
# critical finding: path-segment, IMDS-via-path, IPv6-via-path, query,
# fragment. _url_host_class_denied is the SoT for the deny decision —
# invoking it directly (via _assert_url_class_check) keeps these tests
# off the curl path so they remain hermetic.
_assert_url_class_check "V-26L" "http://127.0.0.1/@attacker.com/"          "denied"
_assert_url_class_check "V-26M" "http://169.254.169.254/latest/@x.com"     "denied"
_assert_url_class_check "V-26N" "http://10.0.0.1?@x.com"                   "denied"
_assert_url_class_check "V-26O" "http://192.168.1.1#@x.com"                "denied"
_assert_url_class_check "V-26P" "http://[::1]/@x.com/"                     "denied"

# ─── V-26q/V-26r: real-public-host negative control (iter-9 testing major) ──
# V-26j/k pin RFC1918 *boundary* hosts (172.15/172.32) as allowed, but no
# test pinned a genuinely public host. Without one, a regression flipping
# _url_host_class_denied to deny-all (or a broken normalizer dropping the
# final `return 1`) would pass every V-24..V-30 deny arm silently. Pin a
# public DNS name and a public IPv4 literal as 'allowed'.
_assert_url_class_check "V-26q" "http://example.com/foo"                   "allowed"
_assert_url_class_check "V-26r" "http://93.184.216.34/foo"                 "allowed"

# ─── V-26s..V-26w: trailing-dot FQDN normalization (iter-9 security major) ──
# Root-anchored trailing-dot forms (`localhost.`, `0.0.0.0.`, `::1.`, bare
# `0.`) resolve identically to their dotless spelling via getaddrinfo but
# bypassed the exact-match / numeric-shorthand arms. The trailing-dot strip
# in _url_host_class_denied normalizes the whole class before matching; pin
# one representative per arm-family, plus a public trailing-dot host that
# must STILL be allowed (normalization must not over-deny).
_assert_url_class_check "V-26s" "http://localhost./foo"                    "denied"
_assert_url_class_check "V-26t" "http://0.0.0.0./foo"                      "denied"
_assert_url_class_check "V-26u" "http://::1./foo"                          "denied"
_assert_url_class_check "V-26v" "http://0./foo"                            "denied"
_assert_url_class_check "V-26w" "http://example.com./foo"                  "allowed"

_assert_url_denied "V-30" "http://2130706433/"
_assert_url_denied "V-31" "http://0x7f000001/"
_assert_url_denied "V-32" "http://0177.0.0.1/"
_assert_url_denied "V-33" "http://0/"
_assert_url_denied "V-34" "http://[::ffff:7f00:1]/"
# IPv6 long-form expansions of ::1 (loopback). `::1` short form is one
# denylist arm; the curl resolver also accepts the canonical long form
# `0:0:0:0:0:0:0:1` plus partial collapses (`0::1`, `::0:1`). Symmetric
# to V-30..V-34 — the brainstorm D-011 "no out-of-worktree access"
# intent must hold for every alias curl normalises to ::1.
_assert_url_denied "V-30b" "http://[0:0:0:0:0:0:0:1]/"
_assert_url_denied "V-30c" "http://[0::1]/"
# IPv4-mapped IPv6 long form: 0:0:0:0:0:ffff:7f00:1 = ::ffff:127.0.0.1.
# The `::ffff:*` short-form arm misses the canonical long form.
_assert_url_denied "V-30d" "http://[0:0:0:0:0:ffff:7f00:1]/"
# IPv6 with zone-id (`%`). RFC 6874 allows a `%<zone>` suffix on link-
# local addresses. Without zone-id stripping, `::1%eth0` skips the `::1`
# arm and reaches the host. curl accepts the suffix; the denylist must
# strip it before the case-match.
_assert_url_denied "V-30e" "http://[::1%eth0]/"
# IPv6 unspecified address. `[::]` resolves to ::1 on Linux for outbound
# connect, so `http://[::]/internal-service` reaches loopback. Symmetric
# to V-30b..V-30e for the unspecified axis (parallel to but not covered
# by V-24's ::1 loopback arm).
_assert_url_class_check "V-30f" "http://[::]/foo" "denied"
# V-30g: long canonical form `0:0:0:0:0:0:0:0` and one partial-collapse
# arm `[0::]` for the unspecified address. V-30f pins only the
# short-form `[::]`; a regression that dropped the long-form / partial-
# collapse arms from `_url_host_class_denied` would not trip V-30f.
_assert_url_class_check "V-30g" "http://[0:0:0:0:0:0:0:0]/foo" "denied"
_assert_url_class_check "V-30h" "http://[0::]/foo"             "denied"

# ─── V-35: case-insensitive scheme test ─────────────────────────────
# Pre-fix: ^https?:// was case-sensitive; HTTP://2130706433/ bypassed
# the scheme gate AND combined with the encoding-bypass to land at
# 127.0.0.1. Post-fix the URL is lowercased before the regex, so the
# encoding-bypass guard above still fires.
_assert_url_denied "V-35" "HTTP://2130706433/"

# ─── V-36: unknown kind rejection ───────────────────────────────────
# verify-qa.sh passes --kinds smoke,file_exists,grep,http_get; the
# helper's fall-through emits 'unknown kind "X" (allowed: …)'. No prior
# fixture exercised this arm; a regression dropping a kind from the
# CSV would silently reject every predicate of that kind at rc=43 with
# the wrong diagnostic. Pin the path explicitly.
cat > "$PROJECT_STATE_DIR/ENG-1/qa-predicate-ENG-1.json" <<'EOF'
{
  "qa_predicate_schema_version": 1,
  "issue_id": "ENG-1",
  "pass_criteria": [
    { "kind": "bogus", "path": "x" }
  ]
}
EOF
rc=0
out="$(bash "$VERIFIER" validate "$PROJECT_STATE_DIR/ENG-1/qa-predicate-ENG-1.json" --worktree "$WT_DIR" 2>&1)" || rc=$?
if (( rc == 43 )) \
   && [[ "$out" == *"unknown kind"* ]] \
   && [[ "$out" == *"smoke"* ]] \
   && [[ "$out" == *"file_exists"* ]] \
   && [[ "$out" == *"grep"* ]] \
   && [[ "$out" == *"http_get"* ]]; then
  pass_at "V-36: kind='bogus' → exit 43 + 'unknown kind' + every allowed kind named"
else
  fail_at "V-36: unknown kind" "expected rc=43 + 'unknown kind' + all 4 allowed kinds in diagnostic; got rc=$rc, out=$out"
fi

# ─── V-37/V-38/V-39: qa_predicate_schema_version wrong-type /
# wrong-value / missing branches. The schema validator has three
# rejection paths: missing, non-integer, !=1. Without explicit
# coverage, a future bump to schema_version=2 (a real possibility)
# without updating the validator would silently accept v2 documents
# on a v1 validator.
#
# V-37 — qa_predicate_schema_version absent → 'missing required field'.
cat > "$PROJECT_STATE_DIR/ENG-1/qa-predicate-ENG-1.json" <<'EOF'
{
  "issue_id": "ENG-1",
  "pass_criteria": [
    { "kind": "file_exists", "path": "x" }
  ]
}
EOF
rc=0
out="$(bash "$VERIFIER" validate "$PROJECT_STATE_DIR/ENG-1/qa-predicate-ENG-1.json" --worktree "$WT_DIR" 2>&1)" || rc=$?
if (( rc == 43 )) && [[ "$out" == *"missing required field"* ]] && [[ "$out" == *"qa_predicate_schema_version"* ]]; then
  pass_at "V-37: qa_predicate_schema_version absent → exit 43 + 'missing required field'"
else
  fail_at "V-37: schema_version absent" "expected rc=43 + 'missing required field' + field name; got rc=$rc, out=$out"
fi

# V-38 — qa_predicate_schema_version wrong type (string) → 'must be an integer'.
cat > "$PROJECT_STATE_DIR/ENG-1/qa-predicate-ENG-1.json" <<'EOF'
{
  "qa_predicate_schema_version": "one",
  "issue_id": "ENG-1",
  "pass_criteria": [
    { "kind": "file_exists", "path": "x" }
  ]
}
EOF
rc=0
out="$(bash "$VERIFIER" validate "$PROJECT_STATE_DIR/ENG-1/qa-predicate-ENG-1.json" --worktree "$WT_DIR" 2>&1)" || rc=$?
if (( rc == 43 )) && [[ "$out" == *"must be an integer"* ]]; then
  pass_at "V-38: qa_predicate_schema_version='one' → exit 43 + 'must be an integer'"
else
  fail_at "V-38: schema_version type" "expected rc=43 + 'must be an integer'; got rc=$rc, out=$out"
fi

# V-39 — qa_predicate_schema_version wrong value (2) → 'must be 1'.
cat > "$PROJECT_STATE_DIR/ENG-1/qa-predicate-ENG-1.json" <<'EOF'
{
  "qa_predicate_schema_version": 2,
  "issue_id": "ENG-1",
  "pass_criteria": [
    { "kind": "file_exists", "path": "x" }
  ]
}
EOF
rc=0
out="$(bash "$VERIFIER" validate "$PROJECT_STATE_DIR/ENG-1/qa-predicate-ENG-1.json" --worktree "$WT_DIR" 2>&1)" || rc=$?
if (( rc == 43 )) && [[ "$out" == *"must be 1"* ]]; then
  pass_at "V-39: qa_predicate_schema_version=2 → exit 43 + 'must be 1'"
else
  fail_at "V-39: schema_version value" "expected rc=43 + 'must be 1'; got rc=$rc, out=$out"
fi

# ─── V-40: snapshot dir creation failure → rc=42 + 'snapshot' ──────
# The authority phase creates $PROJECT_STATE_DIR/.verify-qa-snap before
# mktemp'ing the predicate snapshot. If the parent is unwritable
# (operator perms drift, FS hardening), mkdir fails and the validator
# must halt with rc=42 + a diagnostic naming the snapshot surface so
# triage can pinpoint the perms drift. Pin both axes here so a
# regression dropping the diagnostic naming does not silently shift
# from rc=42 + 'snapshot' to rc=42 + a less-actionable diagnostic.
SNAP_PARENT="$PROJECT_STATE_DIR/.verify-qa-snap"
rm -rf "$SNAP_PARENT" 2>/dev/null || true
chmod 0500 "$PROJECT_STATE_DIR"
f="$(write_valid_predicate qa-predicate-ENG-1.json ENG-1)"
rc=0
out="$(bash "$VERIFIER" validate "$f" --worktree "$WT_DIR" 2>&1)" || rc=$?
chmod 0755 "$PROJECT_STATE_DIR"
if (( rc == 42 )) && [[ "$out" == *"snapshot"* ]]; then
  pass_at "V-40: $PROJECT_STATE_DIR chmod 0500 → rc=42 + 'snapshot' diagnostic"
else
  fail_at "V-40: snapshot dir create-fail" "expected rc=42 + 'snapshot' in diagnostic; got rc=$rc, out=$out"
fi

# ─── V-41: cd-failure detection inside _exec_smoke ──────────────────
# When the worktree anchor is removed between fence resolution and
# smoke execution, the inner `cd "$anchor_real"` fails. Pre-fix, the
# failed cd's rc (1) populated actual_exit, and the criterion reported
# a generic exit-mismatch — triage had no signal that the command was
# never invoked. Post-fix, the validator detects the cd failure and
# reports CRIT_DETAIL='"failed to cd to anchor"'.
#
# Race scaffold: two smoke criteria; the first removes the anchor it
# just cd'd into (rmdir of cwd is permitted on macOS — the inode stays
# referenced for the current shell). The second criterion's fresh cd
# then encounters ENOENT.
WT_V41="$(mktemp -d "$TARGET_REPO/wt-v41-XXXXXX")"
cat > "$PROJECT_STATE_DIR/ENG-1/qa-predicate-ENG-1.json" <<EOF
{
  "qa_predicate_schema_version": 1,
  "issue_id": "ENG-1",
  "pass_criteria": [
    { "kind": "smoke", "command": "rmdir \"$WT_V41\"", "expect_exit": 0, "expect_stdout_match": null },
    { "kind": "smoke", "command": "true", "expect_exit": 0, "expect_stdout_match": null }
  ]
}
EOF
rc=0
out="$(bash "$VERIFIER" validate "$PROJECT_STATE_DIR/ENG-1/qa-predicate-ENG-1.json" --worktree "$WT_V41" 2>&1)" || rc=$?
crit_lines="$(printf '%s\n' "$out" | jq -c 'select(.summary != true)' 2>/dev/null)"
second_crit="$(printf '%s\n' "$crit_lines" | sed -n '2p')"
summary_line="$(_summary_line "$out")"
if (( rc == 0 )) \
   && printf '%s\n' "$second_crit" | jq -e '.pass == false and (.detail | type == "string" and test("failed to cd to anchor"))' >/dev/null 2>&1 \
   && printf '%s\n' "$summary_line" | jq -e '.summary == true and .total == 2 and .failed >= 1' >/dev/null 2>&1; then
  pass_at "V-41: anchor removed mid-stream → criterion 2 reports 'failed to cd to anchor' + summary total=2 failed>=1"
else
  fail_at "V-41: cd-failure detection" "expected criterion 2 pass=false + 'failed to cd to anchor' + summary total=2 failed>=1; got rc=$rc, second_crit=$second_crit, summary=$summary_line, out=$out"
fi

# ─── V-42: _parse_validate_argv flag-value collision ────────────────
# Pre-fix, `--ident --worktree /path` populated ARG_IDENT="--worktree"
# (the parser blindly consumed $2). Post-fix, a value starting with `--`
# is rejected with rc=42 + a diagnostic naming the flag.
f="$(write_valid_predicate qa-predicate-ENG-1.json ENG-1)"
rc=0
out="$(bash "$VERIFIER" validate "$f" --ident --worktree "$WT_DIR" 2>&1)" || rc=$?
if (( rc == 42 )) && [[ "$out" == *"--ident"* ]] && [[ "$out" == *"non-flag value"* ]]; then
  pass_at "V-42: '--ident --worktree …' → rc=42 + '--ident' + 'non-flag value'"
else
  fail_at "V-42: --ident flag-value collision" "expected rc=42 + '--ident' + 'non-flag value'; got rc=$rc, out=$out"
fi
rc=0
out="$(bash "$VERIFIER" validate "$f" --worktree --ident ENG-1 2>&1)" || rc=$?
if (( rc == 42 )) && [[ "$out" == *"--worktree"* ]] && [[ "$out" == *"non-flag value"* ]]; then
  pass_at "V-42b: '--worktree --ident …' → rc=42 + '--worktree' + 'non-flag value'"
else
  fail_at "V-42b: --worktree flag-value collision" "expected rc=42 + '--worktree' + 'non-flag value'; got rc=$rc, out=$out"
fi

# ─── V-43: predicate file is a symlink → rc=42 ─────────────────────
# `_authority_check` canonicalizes the predicate file's PARENT via
# `cd … && pwd -P`, but then suffixes the basename verbatim. A symlink
# at $ARG_FILE whose target is outside $PROJECT_STATE_DIR passes the
# parent-prefix check; the subsequent `cp -f` follows the symlink and
# the validator reads bytes from the target. Reject `[[ -L "$file" ]]`
# at the authority phase before the snapshot step.
TARGET_FILE="$FIXTURE_DIR/outside-state.json"
cat > "$TARGET_FILE" <<'EOF'
{
  "qa_predicate_schema_version": 1,
  "issue_id": "ENG-1",
  "pass_criteria": [
    { "kind": "file_exists", "path": "bin/verify-qa.sh" }
  ]
}
EOF
SYMLINK="$PROJECT_STATE_DIR/ENG-1/qa-predicate-ENG-1.json"
rm -f "$SYMLINK"
ln -sfn "$TARGET_FILE" "$SYMLINK"
rc=0
out="$(bash "$VERIFIER" validate "$SYMLINK" --ident ENG-1 --worktree "$WT_DIR" 2>&1)" || rc=$?
if (( rc == 42 )) && [[ "$out" == *"symlink"* ]]; then
  pass_at "V-43: predicate file is a symlink → rc=42 + 'symlink' diagnostic"
else
  fail_at "V-43: symlink reject" "expected rc=42 + 'symlink' in diagnostic; got rc=$rc, out=$out"
fi
rm -f "$SYMLINK"

# ─── V-43b: unbracketed IPv6 host (::1) → denied ───────────────────
# `_url_host_class_denied`'s pre-fix port-strip `host="${host%%:*}"`
# truncated unbracketed IPv6 at the first colon, leaving an empty host
# that matched no denylist arm. The fix detects multi-colon hosts and
# skips the port-strip arm so the literal `::1` arm fires.
_assert_url_class_check "V-43b" "http://::1/foo" "denied"

# ─── V-44: oversize predicate (>64 KiB) → rc=42 ────────────────────
# Reviewer iter-6 M2: the 64 KiB DoS cap was previously checked on
# `wc -c < "$ARG_FILE"` BEFORE the snapshot cp. Post-iter-2 M5, snap_file
# is the canonical source — checking the original opens a TOCTOU window
# (attacker swaps the file between size check and cp; the snapshot is
# arbitrarily large). Fix bounds the snapshot via head -c MAX+1 and
# re-checks size on the snapshot. The test writes a 70 KiB predicate
# (well above the 64 KiB cap) and asserts the size-cap diagnostic
# still fires.
BIG_FILE="$PROJECT_STATE_DIR/ENG-1/qa-predicate-ENG-1.json"
{
  printf '{\n  "qa_predicate_schema_version": 1,\n  "issue_id": "ENG-1",\n  "pass_criteria": [\n    { "kind": "smoke", "command": "true", "expect_exit": 0, "expect_stdout_match": null,\n      "padding": "'
  # 70 KiB of padding to push the file decisively over the 64 KiB cap.
  head -c 71680 < /dev/zero | tr '\0' 'x'
  printf '" }\n  ]\n}\n'
} > "$BIG_FILE"
rc=0
out="$(bash "$VERIFIER" validate "$BIG_FILE" --ident ENG-1 --worktree "$WT_DIR" 2>&1)" || rc=$?
if (( rc == 42 )) && [[ "$out" == *"exceeds cap"* ]]; then
  pass_at "V-44: oversize predicate (>64 KiB) → rc=42 + 'exceeds cap' diagnostic"
else
  fail_at "V-44: size cap" "expected rc=42 + 'exceeds cap'; got rc=$rc, out=$out (size=$(wc -c < "$BIG_FILE"))"
fi
rm -f "$BIG_FILE"

# ─── V-44b: snap_file is the canonical source — diagnostic pins the
# snapshot's bounded size (MAX+1=65537), not the original ARG_FILE size.
# Pre-iter-6 the check was `wc -c < "$ARG_FILE"` which trips at the
# original size (e.g. 1048576 for a 1 MiB ARG_FILE). The post-fix code
# bounds the snapshot via `head -c MAX+1 < ARG_FILE > snap_file` and
# runs `wc -c < snap_file`, so the diagnostic reports MAX+1 regardless
# of original size. A regression that reverts to `wc -c < "$ARG_FILE"`
# would emit "size 1048576 exceeds cap 65536" — this assertion would
# catch it.
BIG_FILE="$PROJECT_STATE_DIR/ENG-1/qa-predicate-ENG-1.json"
{
  printf '{\n  "qa_predicate_schema_version": 1,\n  "issue_id": "ENG-1",\n  "pass_criteria": [\n    { "kind": "smoke", "command": "true", "expect_exit": 0, "expect_stdout_match": null,\n      "padding": "'
  # 1 MiB of padding — well above the 64 KiB cap; pre-fix would report
  # size 1048576, post-fix reports the snap-bounded 65537.
  head -c 1048576 < /dev/zero | tr '\0' 'x'
  printf '" }\n  ]\n}\n'
} > "$BIG_FILE"
rc=0
out="$(bash "$VERIFIER" validate "$BIG_FILE" --ident ENG-1 --worktree "$WT_DIR" 2>&1)" || rc=$?
if (( rc == 42 )) && [[ "$out" == *"size 65537 exceeds cap 65536"* ]]; then
  pass_at "V-44b: snap_file canonical-source bound → diagnostic reports MAX+1 (not original size)"
else
  fail_at "V-44b: snap-bound TOCTOU closure" "expected rc=42 + 'size 65537 exceeds cap 65536'; got rc=$rc, out=$out (orig_size=$(wc -c < "$BIG_FILE"))"
fi
rm -f "$BIG_FILE"

printf '\n━━━ Summary ━━━\nPASS: %d / FAIL: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]] || exit 1
exit 0
