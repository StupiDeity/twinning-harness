#!/usr/bin/env bash
# Tests for bin/review-payload-schema.sh (ENG-119).
#
# Covers T1-T12 (validator unit tests).
#
# Pattern: source-and-stub (CLAUDE.md "How tests work"). Tests invoke
# bin/review-payload-schema.sh via direct CLI call (matches production
# invocation in _validate_review_payload).

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_DRY_RUN=1
export PIPELINE_DRY_RUN

PASS=0; FAIL=0
pass_at() { PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
fail_at() { FAIL=$((FAIL+1)); printf '  ❌ %s — %s\n' "$1" "$2" >&2; }

FIXTURE_DIR="$(mktemp -d -t review-payload-schema-test.XXXXXX)"
# review-payload-schema.sh sources common.sh which requires TARGET_REPO + PROJECT_SLUG.
export TARGET_REPO="$FIXTURE_DIR/target"
mkdir -p "$TARGET_REPO/.pipeline-config"
printf '{"project":{"slug":"test-slug"}}\n' > "$TARGET_REPO/.pipeline-config/config.json"
export PROJECT_SLUG=test-slug
trap 'rm -rf "$FIXTURE_DIR"' EXIT

VALIDATOR="$SCRIPT_DIR/review-payload-schema.sh"

# ─── Sentinel header check ───────────────────────────────────────────
# The validator is always invoked via `bash <file>` (production sites:
# run-stage.sh::_validate_review_payload runs `bash "$SCRIPT_DIR/...sh"`;
# this test runs `bash "$VALIDATOR" validate ...`). Exec bit is informational
# only — its absence does not break either call site.
printf '\n--- review-payload-schema-test: sentinel + executable ---\n'
if [[ -f "$VALIDATOR" ]]; then
  pass_at "validator file present at $VALIDATOR"
else
  fail_at "validator file missing" "$VALIDATOR not found"
fi
if [[ -x "$VALIDATOR" ]]; then
  pass_at "validator has exec bit set"
else
  printf '  ⚠️  validator lacks exec bit (informational; invocation uses `bash <file>`)\n'
fi
if grep -q 'BASH_SOURCE\[0\].*"\${0}".*then main' "$VALIDATOR" 2>/dev/null; then
  pass_at "sentinel present (sourcable for tests)"
else
  fail_at "sentinel missing" "expected: if [[ \"\${BASH_SOURCE[0]}\" == \"\${0}\" ]]; then main \"\$@\"; fi"
fi

# ─── Helpers ─────────────────────────────────────────────────────────

# Write a well-formed schema-v1 fixture.
# Usage: write_valid_fixture <filename> [issue_id] [dispatch_id]
write_valid_fixture() {
  local file="$FIXTURE_DIR/${1}"
  local iid="${2:-ENG-1}"
  local did="${3:-ENG-1-d0001}"
  cat > "$file" <<EOF
{
  "review_schema_version": 1,
  "issue_id": "$iid",
  "dispatch_id": "$did",
  "sha": "deadbeef",
  "verdict": "approve",
  "dimensions": {
    "correctness":     { "score": "pass", "rationale": "ok", "thresholds_met": [], "thresholds_missed": [] },
    "testing":         { "score": "pass", "rationale": "ok", "thresholds_met": [], "thresholds_missed": [] },
    "maintainability": { "score": "pass", "rationale": "ok", "thresholds_met": [], "thresholds_missed": [] },
    "scope":           { "score": "pass", "rationale": "ok", "thresholds_met": [], "thresholds_missed": [] }
  }
}
EOF
  printf '%s' "$file"
}

printf '\n--- review-payload-schema-test: T1-T12 ---\n'

# ─── T1: well-formed schema-v1 JSON → exit 0 ─────────────────────────
f="$(write_valid_fixture t1.json ENG-1 ENG-1-d0001)"
rc=0; bash "$VALIDATOR" validate "$f" --ident ENG-1 --dispatch-id ENG-1-d0001 >/dev/null 2>&1 || rc=$?
(( rc == 0 )) \
  && pass_at "T1: well-formed JSON → exit 0" \
  || fail_at "T1: well-formed JSON" "expected rc=0, got rc=$rc"

# ─── T2: missing file → exit 38 ──────────────────────────────────────
rc=0; bash "$VALIDATOR" validate "$FIXTURE_DIR/nonexistent.json" >/dev/null 2>&1 || rc=$?
(( rc == 38 )) \
  && pass_at "T2: missing file → exit 38" \
  || fail_at "T2: missing file" "expected rc=38, got rc=$rc"

# ─── T3: malformed JSON syntax (stray comma) → exit 36 ───────────────
printf '{,}\n' > "$FIXTURE_DIR/t3.json"
rc=0; bash "$VALIDATOR" validate "$FIXTURE_DIR/t3.json" >/dev/null 2>&1 || rc=$?
(( rc == 36 )) \
  && pass_at "T3: malformed JSON syntax (stray-comma) → exit 36" \
  || fail_at "T3: malformed JSON syntax" "expected rc=36, got rc=$rc"

# ─── T4: malformed (top-level array, not object) → exit 36 ───────────
printf '[1, 2, 3]\n' > "$FIXTURE_DIR/t4.json"
rc=0; bash "$VALIDATOR" validate "$FIXTURE_DIR/t4.json" >/dev/null 2>&1 || rc=$?
(( rc == 36 )) \
  && pass_at "T4: top-level array → exit 36" \
  || fail_at "T4: top-level array" "expected rc=36, got rc=$rc"

# ─── T5: incomplete — missing review_schema_version → exit 37 ────────
cat > "$FIXTURE_DIR/t5.json" <<'EOF'
{
  "issue_id": "ENG-1",
  "dispatch_id": "ENG-1-d0001",
  "sha": "deadbeef",
  "verdict": "approve",
  "dimensions": {
    "correctness":     { "score": "pass", "rationale": "ok", "thresholds_met": [], "thresholds_missed": [] },
    "testing":         { "score": "pass", "rationale": "ok", "thresholds_met": [], "thresholds_missed": [] },
    "maintainability": { "score": "pass", "rationale": "ok", "thresholds_met": [], "thresholds_missed": [] },
    "scope":           { "score": "pass", "rationale": "ok", "thresholds_met": [], "thresholds_missed": [] }
  }
}
EOF
rc=0; bash "$VALIDATOR" validate "$FIXTURE_DIR/t5.json" >/dev/null 2>&1 || rc=$?
(( rc == 37 )) \
  && pass_at "T5: missing review_schema_version → exit 37" \
  || fail_at "T5: missing review_schema_version" "expected rc=37, got rc=$rc"

# ─── T5b: review_schema_version != 1 → exit 37 ───────────────────────
cat > "$FIXTURE_DIR/t5b.json" <<'EOF'
{
  "review_schema_version": 2,
  "issue_id": "ENG-1",
  "dispatch_id": "ENG-1-d0001",
  "sha": "deadbeef",
  "verdict": "approve",
  "dimensions": {
    "correctness":     { "score": "pass", "rationale": "ok", "thresholds_met": [], "thresholds_missed": [] },
    "testing":         { "score": "pass", "rationale": "ok", "thresholds_met": [], "thresholds_missed": [] },
    "maintainability": { "score": "pass", "rationale": "ok", "thresholds_met": [], "thresholds_missed": [] },
    "scope":           { "score": "pass", "rationale": "ok", "thresholds_met": [], "thresholds_missed": [] }
  }
}
EOF
rc=0; bash "$VALIDATOR" validate "$FIXTURE_DIR/t5b.json" >/dev/null 2>&1 || rc=$?
(( rc == 37 )) \
  && pass_at "T5b: review_schema_version=2 → exit 37" \
  || fail_at "T5b: schema version 2" "expected rc=37, got rc=$rc"

# ─── T6: incomplete — missing required dimension (correctness) → exit 37 ──
cat > "$FIXTURE_DIR/t6.json" <<'EOF'
{
  "review_schema_version": 1,
  "issue_id": "ENG-1",
  "dispatch_id": "ENG-1-d0001",
  "sha": "deadbeef",
  "verdict": "approve",
  "dimensions": {
    "testing":         { "score": "pass", "rationale": "ok", "thresholds_met": [], "thresholds_missed": [] },
    "maintainability": { "score": "pass", "rationale": "ok", "thresholds_met": [], "thresholds_missed": [] },
    "scope":           { "score": "pass", "rationale": "ok", "thresholds_met": [], "thresholds_missed": [] }
  }
}
EOF
rc=0; bash "$VALIDATOR" validate "$FIXTURE_DIR/t6.json" >/dev/null 2>&1 || rc=$?
(( rc == 37 )) \
  && pass_at "T6: missing required dimension correctness → exit 37" \
  || fail_at "T6: missing required dimension" "expected rc=37, got rc=$rc"

# ─── T7: per-dimension score outside enum → exit 37 ──────────────────
cat > "$FIXTURE_DIR/t7.json" <<'EOF'
{
  "review_schema_version": 1,
  "issue_id": "ENG-1",
  "dispatch_id": "ENG-1-d0001",
  "sha": "deadbeef",
  "verdict": "approve",
  "dimensions": {
    "correctness":     { "score": "good", "rationale": "ok", "thresholds_met": [], "thresholds_missed": [] },
    "testing":         { "score": "pass", "rationale": "ok", "thresholds_met": [], "thresholds_missed": [] },
    "maintainability": { "score": "pass", "rationale": "ok", "thresholds_met": [], "thresholds_missed": [] },
    "scope":           { "score": "pass", "rationale": "ok", "thresholds_met": [], "thresholds_missed": [] }
  }
}
EOF
rc=0; bash "$VALIDATOR" validate "$FIXTURE_DIR/t7.json" >/dev/null 2>&1 || rc=$?
(( rc == 37 )) \
  && pass_at "T7: bad score enum (\"good\") → exit 37" \
  || fail_at "T7: bad score enum" "expected rc=37, got rc=$rc"

# ─── T8: per-dimension rationale empty → exit 37 ─────────────────────
cat > "$FIXTURE_DIR/t8.json" <<'EOF'
{
  "review_schema_version": 1,
  "issue_id": "ENG-1",
  "dispatch_id": "ENG-1-d0001",
  "sha": "deadbeef",
  "verdict": "approve",
  "dimensions": {
    "correctness":     { "score": "pass", "rationale": "", "thresholds_met": [], "thresholds_missed": [] },
    "testing":         { "score": "pass", "rationale": "ok", "thresholds_met": [], "thresholds_missed": [] },
    "maintainability": { "score": "pass", "rationale": "ok", "thresholds_met": [], "thresholds_missed": [] },
    "scope":           { "score": "pass", "rationale": "ok", "thresholds_met": [], "thresholds_missed": [] }
  }
}
EOF
rc=0; bash "$VALIDATOR" validate "$FIXTURE_DIR/t8.json" >/dev/null 2>&1 || rc=$?
(( rc == 37 )) \
  && pass_at "T8: empty rationale → exit 37" \
  || fail_at "T8: empty rationale" "expected rc=37, got rc=$rc"

# ─── T9: per-dimension thresholds_met not an array → exit 37 ─────────
cat > "$FIXTURE_DIR/t9.json" <<'EOF'
{
  "review_schema_version": 1,
  "issue_id": "ENG-1",
  "dispatch_id": "ENG-1-d0001",
  "sha": "deadbeef",
  "verdict": "approve",
  "dimensions": {
    "correctness":     { "score": "pass", "rationale": "ok", "thresholds_met": "nope", "thresholds_missed": [] },
    "testing":         { "score": "pass", "rationale": "ok", "thresholds_met": [], "thresholds_missed": [] },
    "maintainability": { "score": "pass", "rationale": "ok", "thresholds_met": [], "thresholds_missed": [] },
    "scope":           { "score": "pass", "rationale": "ok", "thresholds_met": [], "thresholds_missed": [] }
  }
}
EOF
rc=0; bash "$VALIDATOR" validate "$FIXTURE_DIR/t9.json" >/dev/null 2>&1 || rc=$?
(( rc == 37 )) \
  && pass_at "T9: bad thresholds_met type (string not array) → exit 37" \
  || fail_at "T9: bad thresholds type" "expected rc=37, got rc=$rc"

# ─── T10: issue_id mismatch with --ident → exit 37 ───────────────────
f="$(write_valid_fixture t10.json ENG-999 ENG-999-d0001)"
rc=0; out="$(bash "$VALIDATOR" validate "$f" --ident ENG-1 --dispatch-id ENG-1-d0001 2>&1)" || rc=$?
(( rc == 37 )) \
  && pass_at "T10: issue_id mismatch → exit 37" \
  || fail_at "T10: issue_id mismatch" "expected rc=37, got rc=$rc"
if [[ "$out" == *"stale template?"* ]]; then
  pass_at "T10: stale template? hint present in diagnostic"
else
  fail_at "T10: stale template hint" "diagnostic should mention 'stale template?'; got: $out"
fi

# ─── T11: dispatch_id mismatch with --dispatch-id → exit 37 ──────────
f="$(write_valid_fixture t11.json ENG-1 ENG-1-d0099)"
rc=0; out="$(bash "$VALIDATOR" validate "$f" --ident ENG-1 --dispatch-id ENG-1-d0001 2>&1)" || rc=$?
(( rc == 37 )) \
  && pass_at "T11: dispatch_id mismatch → exit 37" \
  || fail_at "T11: dispatch_id mismatch" "expected rc=37, got rc=$rc"
if [[ "$out" == *"dispatch_id"* ]]; then
  pass_at "T11: dispatch_id mentioned in diagnostic"
else
  fail_at "T11: diagnostic mention" "expected diagnostic to mention dispatch_id; got: $out"
fi

# ─── T11b: empty --dispatch-id flag → cross-check skipped (rc=0) ─────
f="$(write_valid_fixture t11b.json ENG-1 ENG-1-d0099)"
rc=0; bash "$VALIDATOR" validate "$f" --ident ENG-1 --dispatch-id '' >/dev/null 2>&1 || rc=$?
(( rc == 0 )) \
  && pass_at "T11b: empty --dispatch-id flag → cross-check skipped, rc=0" \
  || fail_at "T11b: empty --dispatch-id flag" "expected rc=0 (fail-open), got rc=$rc"

# ─── T12: unknown dimension key → exit 0 + stderr warning ────────────
cat > "$FIXTURE_DIR/t12.json" <<'EOF'
{
  "review_schema_version": 1,
  "issue_id": "ENG-1",
  "dispatch_id": "ENG-1-d0001",
  "sha": "deadbeef",
  "verdict": "approve",
  "dimensions": {
    "correctness":     { "score": "pass", "rationale": "ok", "thresholds_met": [], "thresholds_missed": [] },
    "testing":         { "score": "pass", "rationale": "ok", "thresholds_met": [], "thresholds_missed": [] },
    "maintainability": { "score": "pass", "rationale": "ok", "thresholds_met": [], "thresholds_missed": [] },
    "scope":           { "score": "pass", "rationale": "ok", "thresholds_met": [], "thresholds_missed": [] },
    "future_concern":  { "score": "pass", "rationale": "ok", "thresholds_met": [], "thresholds_missed": [] }
  }
}
EOF
rc=0
stdout_out="$(bash "$VALIDATOR" validate "$FIXTURE_DIR/t12.json" 2>/dev/null)" || rc=$?
stderr_out="$(bash "$VALIDATOR" validate "$FIXTURE_DIR/t12.json" 2>&1 >/dev/null)" || true
(( rc == 0 )) \
  && pass_at "T12: unknown dimension → exit 0" \
  || fail_at "T12: unknown dimension exit code" "expected rc=0, got rc=$rc"
if [[ "$stderr_out" == *"warning"* ]] && [[ "$stderr_out" == *"future_concern"* ]]; then
  pass_at "T12: unknown dimension stderr contains 'warning' and field name"
else
  fail_at "T12: unknown dimension warning" "stderr should contain 'warning' and 'future_concern', got: $stderr_out"
fi

printf '\n--- QA adversarial tests (ENG-119) ---\n'

# ─── QA1: sha: null (explicit null, not absent) → rc=37 ──────────────
# jq // fires on null, so sha_val becomes "MISSING"; sha_type becomes "null".
# Line 169 fires on MISSING sentinel → rc=37.
cat > "$FIXTURE_DIR/qa1.json" <<'EOF'
{
  "review_schema_version": 1,
  "issue_id": "ENG-1",
  "dispatch_id": "ENG-1-d0001",
  "sha": null,
  "verdict": "approve",
  "dimensions": {
    "correctness":     { "score": "pass", "rationale": "ok", "thresholds_met": [], "thresholds_missed": [] },
    "testing":         { "score": "pass", "rationale": "ok", "thresholds_met": [], "thresholds_missed": [] },
    "maintainability": { "score": "pass", "rationale": "ok", "thresholds_met": [], "thresholds_missed": [] },
    "scope":           { "score": "pass", "rationale": "ok", "thresholds_met": [], "thresholds_missed": [] }
  }
}
EOF
rc=0; bash "$VALIDATOR" validate "$FIXTURE_DIR/qa1.json" >/dev/null 2>&1 || rc=$?
(( rc == 37 )) \
  && pass_at "QA1: sha: null (explicit null) → exit 37" \
  || fail_at "QA1: sha: null" "expected rc=37, got rc=$rc"

# ─── QA2: dimensions: {} (empty object) → rc=37 ──────────────────────
# All 4 required keys absent; first missing key (correctness) trips rc=37.
cat > "$FIXTURE_DIR/qa2.json" <<'EOF'
{
  "review_schema_version": 1,
  "issue_id": "ENG-1",
  "dispatch_id": "ENG-1-d0001",
  "sha": "deadbeef",
  "verdict": "approve",
  "dimensions": {}
}
EOF
rc=0; bash "$VALIDATOR" validate "$FIXTURE_DIR/qa2.json" >/dev/null 2>&1 || rc=$?
(( rc == 37 )) \
  && pass_at "QA2: dimensions: {} (empty object) → exit 37" \
  || fail_at "QA2: dimensions: {}" "expected rc=37, got rc=$rc"

# ─── QA3: dispatch_id with 5-digit counter → rc=0 ────────────────────
# Validates the + (not {4}) quantifier in ^ENG-[0-9]+-d[0-9]+$
# so d10000 and beyond are legal.
f="$(write_valid_fixture qa3.json ENG-1 ENG-1-d10000)"
rc=0; bash "$VALIDATOR" validate "$f" --ident ENG-1 --dispatch-id ENG-1-d10000 >/dev/null 2>&1 || rc=$?
(( rc == 0 )) \
  && pass_at "QA3: dispatch_id ENG-1-d10000 (5-digit counter) → exit 0" \
  || fail_at "QA3: 5-digit dispatch counter" "expected rc=0, got rc=$rc"

# ─── QA4: verdict = "refused" (unlisted enum) → rc=37 ────────────────
# Supplements T7 (which tests score enum); verdict enum is a distinct gate.
cat > "$FIXTURE_DIR/qa4.json" <<'EOF'
{
  "review_schema_version": 1,
  "issue_id": "ENG-1",
  "dispatch_id": "ENG-1-d0001",
  "sha": "deadbeef",
  "verdict": "refused",
  "dimensions": {
    "correctness":     { "score": "pass", "rationale": "ok", "thresholds_met": [], "thresholds_missed": [] },
    "testing":         { "score": "pass", "rationale": "ok", "thresholds_met": [], "thresholds_missed": [] },
    "maintainability": { "score": "pass", "rationale": "ok", "thresholds_met": [], "thresholds_missed": [] },
    "scope":           { "score": "pass", "rationale": "ok", "thresholds_met": [], "thresholds_missed": [] }
  }
}
EOF
rc=0; bash "$VALIDATOR" validate "$FIXTURE_DIR/qa4.json" >/dev/null 2>&1 || rc=$?
(( rc == 37 )) \
  && pass_at "QA4: verdict=\"refused\" (unlisted enum) → exit 37" \
  || fail_at "QA4: unlisted verdict enum" "expected rc=37, got rc=$rc"

# ─── QA5: thresholds_missed absent (thresholds_met present) → rc=37 ──
# Asymmetric with T9 (which tests thresholds_met type); this ensures
# the missing-field path for thresholds_missed is exercised separately.
cat > "$FIXTURE_DIR/qa5.json" <<'EOF'
{
  "review_schema_version": 1,
  "issue_id": "ENG-1",
  "dispatch_id": "ENG-1-d0001",
  "sha": "deadbeef",
  "verdict": "approve",
  "dimensions": {
    "correctness":     { "score": "pass", "rationale": "ok", "thresholds_met": [] },
    "testing":         { "score": "pass", "rationale": "ok", "thresholds_met": [], "thresholds_missed": [] },
    "maintainability": { "score": "pass", "rationale": "ok", "thresholds_met": [], "thresholds_missed": [] },
    "scope":           { "score": "pass", "rationale": "ok", "thresholds_met": [], "thresholds_missed": [] }
  }
}
EOF
rc=0; bash "$VALIDATOR" validate "$FIXTURE_DIR/qa5.json" >/dev/null 2>&1 || rc=$?
(( rc == 37 )) \
  && pass_at "QA5: thresholds_missed absent (thresholds_met present) → exit 37" \
  || fail_at "QA5: thresholds_missed absent" "expected rc=37, got rc=$rc"

# ─── QA6: dimensions: null (explicit null object) → rc=37 ────────────
# dims_type → "null"; "null" != "object" → rc=37.
cat > "$FIXTURE_DIR/qa6.json" <<'EOF'
{
  "review_schema_version": 1,
  "issue_id": "ENG-1",
  "dispatch_id": "ENG-1-d0001",
  "sha": "deadbeef",
  "verdict": "approve",
  "dimensions": null
}
EOF
rc=0; bash "$VALIDATOR" validate "$FIXTURE_DIR/qa6.json" >/dev/null 2>&1 || rc=$?
(( rc == 37 )) \
  && pass_at "QA6: dimensions: null (explicit null) → exit 37" \
  || fail_at "QA6: dimensions: null" "expected rc=37, got rc=$rc"

# ─── QA-N1: review_schema_version: 1.0 (float) → rc=0 ───────────────
# INTENTIONAL behavior: jq `== 1` evaluates true for 1.0 (no int/float
# distinction in JSON/jq). Float 1.0 is accepted as schema-v1. Document
# here to pin this as a known-valid path, not a gap.
cat > "$FIXTURE_DIR/qa-n1.json" <<'EOF'
{
  "review_schema_version": 1.0,
  "issue_id": "ENG-1",
  "dispatch_id": "ENG-1-d0001",
  "sha": "deadbeef",
  "verdict": "approve",
  "dimensions": {
    "correctness":     { "score": "pass", "rationale": "ok", "thresholds_met": [], "thresholds_missed": [] },
    "testing":         { "score": "pass", "rationale": "ok", "thresholds_met": [], "thresholds_missed": [] },
    "maintainability": { "score": "pass", "rationale": "ok", "thresholds_met": [], "thresholds_missed": [] },
    "scope":           { "score": "pass", "rationale": "ok", "thresholds_met": [], "thresholds_missed": [] }
  }
}
EOF
rc=0; bash "$VALIDATOR" validate "$FIXTURE_DIR/qa-n1.json" >/dev/null 2>&1 || rc=$?
(( rc == 0 )) \
  && pass_at "QA-N1: review_schema_version: 1.0 (float) → exit 0 (jq int/float parity; intentional)" \
  || fail_at "QA-N1: float schema version" "expected rc=0 (jq parity), got rc=$rc"

# ─── QA-N3: known-optional dimension with invalid score → rc=0 ───────
# INTENTIONAL behavior: per design, only the 4 required dimensions are
# validated; optional dims (security, performance, api_contract, premise)
# are known to the schema but their content is NOT validated in schema-v1.
# This is expected — optional dims are for future ENG-118 reporting only.
cat > "$FIXTURE_DIR/qa-n3.json" <<'EOF'
{
  "review_schema_version": 1,
  "issue_id": "ENG-1",
  "dispatch_id": "ENG-1-d0001",
  "sha": "deadbeef",
  "verdict": "approve",
  "dimensions": {
    "correctness":     { "score": "pass", "rationale": "ok", "thresholds_met": [], "thresholds_missed": [] },
    "testing":         { "score": "pass", "rationale": "ok", "thresholds_met": [], "thresholds_missed": [] },
    "maintainability": { "score": "pass", "rationale": "ok", "thresholds_met": [], "thresholds_missed": [] },
    "scope":           { "score": "pass", "rationale": "ok", "thresholds_met": [], "thresholds_missed": [] },
    "security":        { "score": "broken_value", "rationale": "bad" }
  }
}
EOF
rc=0; bash "$VALIDATOR" validate "$FIXTURE_DIR/qa-n3.json" >/dev/null 2>&1 || rc=$?
(( rc == 0 )) \
  && pass_at "QA-N3: optional dimension (security) with invalid score → exit 0 (v1: optional dims not validated; intentional)" \
  || fail_at "QA-N3: optional dimension with invalid score" "expected rc=0 (optional dims not validated), got rc=$rc"

# ─── QA-N4: rationale = "MISSING" string literal → rc=37 (known quirk)─
# KNOWN LIMITATION: the "MISSING" string is the jq-// sentinel the
# validator uses for absent fields. A legitimate rationale of literally
# "MISSING" trips the absent-field guard. Machine-generated payloads
# will not produce this string; documented here to pin the behavior.
cat > "$FIXTURE_DIR/qa-n4.json" <<'EOF'
{
  "review_schema_version": 1,
  "issue_id": "ENG-1",
  "dispatch_id": "ENG-1-d0001",
  "sha": "deadbeef",
  "verdict": "approve",
  "dimensions": {
    "correctness":     { "score": "pass", "rationale": "MISSING", "thresholds_met": [], "thresholds_missed": [] },
    "testing":         { "score": "pass", "rationale": "ok", "thresholds_met": [], "thresholds_missed": [] },
    "maintainability": { "score": "pass", "rationale": "ok", "thresholds_met": [], "thresholds_missed": [] },
    "scope":           { "score": "pass", "rationale": "ok", "thresholds_met": [], "thresholds_missed": [] }
  }
}
EOF
rc=0; bash "$VALIDATOR" validate "$FIXTURE_DIR/qa-n4.json" >/dev/null 2>&1 || rc=$?
(( rc == 37 )) \
  && pass_at "QA-N4: rationale=\"MISSING\" string literal → exit 37 (jq sentinel collision; known quirk — machine-generated payloads never emit this string)" \
  || fail_at "QA-N4: sentinel collision" "expected rc=37 (known quirk), got rc=$rc"

printf '\nreview-payload-schema-test: passed=%d failed=%d\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
