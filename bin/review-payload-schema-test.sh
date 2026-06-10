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
printf '\n--- review-payload-schema-test: sentinel + executable ---\n'
if [[ -f "$VALIDATOR" ]]; then
  pass_at "validator file present at $VALIDATOR"
else
  fail_at "validator file missing" "$VALIDATOR not found"
fi
if [[ -x "$VALIDATOR" ]]; then
  pass_at "validator is executable"
else
  fail_at "validator not executable" "chmod +x missing on $VALIDATOR"
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

printf '\nreview-payload-schema-test: passed=%d failed=%d\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
