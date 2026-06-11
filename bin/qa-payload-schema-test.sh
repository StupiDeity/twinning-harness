#!/usr/bin/env bash
# Tests for bin/qa-payload-schema.sh (ENG-117).
#
# Covers T1-T21 + T_schema_doc_sync (validator unit tests).
#
# Pattern: source-and-stub (CLAUDE.md "How tests work"). Tests invoke
# bin/qa-payload-schema.sh via direct CLI call (matches production
# invocation in run-stage.sh::_validate_qa_payload).

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_DRY_RUN=1
export PIPELINE_DRY_RUN

PASS=0; FAIL=0
pass_at() { PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
fail_at() { FAIL=$((FAIL+1)); printf '  ❌ %s — %s\n' "$1" "$2" >&2; }

FIXTURE_DIR="$(mktemp -d -t qa-payload-schema-test.XXXXXX)"
# qa-payload-schema.sh sources common.sh which requires TARGET_REPO + PROJECT_SLUG.
export TARGET_REPO="$FIXTURE_DIR/target"
mkdir -p "$TARGET_REPO/.pipeline-config"
printf '{"project":{"slug":"test-slug"}}\n' > "$TARGET_REPO/.pipeline-config/config.json"
export PROJECT_SLUG=test-slug
trap 'rm -rf "$FIXTURE_DIR"' EXIT

VALIDATOR="$SCRIPT_DIR/qa-payload-schema.sh"

# ─── Sentinel header check ───────────────────────────────────────────
printf '\n--- qa-payload-schema-test: sentinel + executable ---\n'
if [[ -f "$VALIDATOR" ]]; then
  pass_at "validator file present at $VALIDATOR"
else
  fail_at "validator file missing" "$VALIDATOR not found"
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
  "qa_payload_schema_version": 1,
  "issue_id": "$iid",
  "dispatch_id": "$did",
  "verdict": "pass",
  "dimensions": [
    { "name": "gate_compliance", "score": 1.0, "rationale": "all gates green", "threshold_met": true }
  ]
}
EOF
  printf '%s' "$file"
}

printf '\n--- qa-payload-schema-test: T1-T21 ---\n'

# ─── T1: well-formed schema-v1 JSON → exit 0 ─────────────────────────
f="$(write_valid_fixture t1.json ENG-1 ENG-1-d0001)"
rc=0; bash "$VALIDATOR" validate "$f" --ident ENG-1 --dispatch-id ENG-1-d0001 >/dev/null 2>&1 || rc=$?
(( rc == 0 )) \
  && pass_at "T1: well-formed JSON → exit 0" \
  || fail_at "T1: well-formed JSON" "expected rc=0, got rc=$rc"

# ─── T2: missing file → exit 41 ──────────────────────────────────────
rc=0; bash "$VALIDATOR" validate "$FIXTURE_DIR/nonexistent.json" >/dev/null 2>&1 || rc=$?
(( rc == 41 )) \
  && pass_at "T2: missing file → exit 41" \
  || fail_at "T2: missing file" "expected rc=41, got rc=$rc"

# ─── T3: malformed JSON syntax (stray comma) → exit 39 ───────────────
printf '{,}\n' > "$FIXTURE_DIR/t3.json"
rc=0; bash "$VALIDATOR" validate "$FIXTURE_DIR/t3.json" >/dev/null 2>&1 || rc=$?
(( rc == 39 )) \
  && pass_at "T3: malformed JSON syntax (stray-comma) → exit 39" \
  || fail_at "T3: malformed JSON syntax" "expected rc=39, got rc=$rc"

# ─── T4: top-level is an array → exit 39 ─────────────────────────────
printf '[1, 2, 3]\n' > "$FIXTURE_DIR/t4.json"
rc=0; bash "$VALIDATOR" validate "$FIXTURE_DIR/t4.json" >/dev/null 2>&1 || rc=$?
(( rc == 39 )) \
  && pass_at "T4: top-level array → exit 39" \
  || fail_at "T4: top-level array" "expected rc=39, got rc=$rc"

# ─── T5: incomplete — missing qa_payload_schema_version → exit 40 ────
cat > "$FIXTURE_DIR/t5.json" <<'EOF'
{
  "issue_id": "ENG-1",
  "dispatch_id": "ENG-1-d0001",
  "verdict": "pass",
  "dimensions": [
    { "name": "gate_compliance", "score": 1.0, "rationale": "ok", "threshold_met": true }
  ]
}
EOF
rc=0; bash "$VALIDATOR" validate "$FIXTURE_DIR/t5.json" >/dev/null 2>&1 || rc=$?
(( rc == 40 )) \
  && pass_at "T5: missing qa_payload_schema_version → exit 40" \
  || fail_at "T5: missing schema version" "expected rc=40, got rc=$rc"

# ─── T6: qa_payload_schema_version: 2 → exit 40 ──────────────────────
cat > "$FIXTURE_DIR/t6.json" <<'EOF'
{
  "qa_payload_schema_version": 2,
  "issue_id": "ENG-1",
  "dispatch_id": "ENG-1-d0001",
  "verdict": "pass",
  "dimensions": [
    { "name": "gate_compliance", "score": 1.0, "rationale": "ok", "threshold_met": true }
  ]
}
EOF
rc=0; bash "$VALIDATOR" validate "$FIXTURE_DIR/t6.json" >/dev/null 2>&1 || rc=$?
(( rc == 40 )) \
  && pass_at "T6: qa_payload_schema_version=2 → exit 40" \
  || fail_at "T6: schema version 2" "expected rc=40, got rc=$rc"

# ─── T7: qa_payload_schema_version: "1" (string) → exit 40 ───────────
cat > "$FIXTURE_DIR/t7.json" <<'EOF'
{
  "qa_payload_schema_version": "1",
  "issue_id": "ENG-1",
  "dispatch_id": "ENG-1-d0001",
  "verdict": "pass",
  "dimensions": [
    { "name": "gate_compliance", "score": 1.0, "rationale": "ok", "threshold_met": true }
  ]
}
EOF
rc=0; bash "$VALIDATOR" validate "$FIXTURE_DIR/t7.json" >/dev/null 2>&1 || rc=$?
(( rc == 40 )) \
  && pass_at "T7: qa_payload_schema_version=\"1\" (string) → exit 40" \
  || fail_at "T7: schema version string" "expected rc=40, got rc=$rc"

# ─── T8: issue_id wrong type (integer) → exit 40 ─────────────────────
cat > "$FIXTURE_DIR/t8.json" <<'EOF'
{
  "qa_payload_schema_version": 1,
  "issue_id": 1,
  "dispatch_id": "ENG-1-d0001",
  "verdict": "pass",
  "dimensions": [
    { "name": "gate_compliance", "score": 1.0, "rationale": "ok", "threshold_met": true }
  ]
}
EOF
rc=0; bash "$VALIDATOR" validate "$FIXTURE_DIR/t8.json" >/dev/null 2>&1 || rc=$?
(( rc == 40 )) \
  && pass_at "T8: issue_id wrong type (integer) → exit 40" \
  || fail_at "T8: issue_id wrong type" "expected rc=40, got rc=$rc"

# ─── T9: dispatch_id missing → exit 40 ───────────────────────────────
cat > "$FIXTURE_DIR/t9.json" <<'EOF'
{
  "qa_payload_schema_version": 1,
  "issue_id": "ENG-1",
  "verdict": "pass",
  "dimensions": [
    { "name": "gate_compliance", "score": 1.0, "rationale": "ok", "threshold_met": true }
  ]
}
EOF
rc=0; bash "$VALIDATOR" validate "$FIXTURE_DIR/t9.json" >/dev/null 2>&1 || rc=$?
(( rc == 40 )) \
  && pass_at "T9: dispatch_id missing → exit 40" \
  || fail_at "T9: dispatch_id missing" "expected rc=40, got rc=$rc"

# ─── T10: dispatch_id fails regex (ENG-1-foo) → exit 40 ──────────────
cat > "$FIXTURE_DIR/t10.json" <<'EOF'
{
  "qa_payload_schema_version": 1,
  "issue_id": "ENG-1",
  "dispatch_id": "ENG-1-foo",
  "verdict": "pass",
  "dimensions": [
    { "name": "gate_compliance", "score": 1.0, "rationale": "ok", "threshold_met": true }
  ]
}
EOF
rc=0; bash "$VALIDATOR" validate "$FIXTURE_DIR/t10.json" >/dev/null 2>&1 || rc=$?
(( rc == 40 )) \
  && pass_at "T10: dispatch_id fails regex → exit 40" \
  || fail_at "T10: dispatch_id regex" "expected rc=40, got rc=$rc"

# ─── T11: verdict outside closed vocab → exit 40 ─────────────────────
cat > "$FIXTURE_DIR/t11.json" <<'EOF'
{
  "qa_payload_schema_version": 1,
  "issue_id": "ENG-1",
  "dispatch_id": "ENG-1-d0001",
  "verdict": "bogus",
  "dimensions": [
    { "name": "gate_compliance", "score": 1.0, "rationale": "ok", "threshold_met": true }
  ]
}
EOF
rc=0; bash "$VALIDATOR" validate "$FIXTURE_DIR/t11.json" >/dev/null 2>&1 || rc=$?
(( rc == 40 )) \
  && pass_at "T11: verdict=\"bogus\" → exit 40" \
  || fail_at "T11: verdict outside vocab" "expected rc=40, got rc=$rc"

# ─── T12: empty dimensions [] → exit 40 ──────────────────────────────
cat > "$FIXTURE_DIR/t12.json" <<'EOF'
{
  "qa_payload_schema_version": 1,
  "issue_id": "ENG-1",
  "dispatch_id": "ENG-1-d0001",
  "verdict": "pass",
  "dimensions": []
}
EOF
rc=0; bash "$VALIDATOR" validate "$FIXTURE_DIR/t12.json" >/dev/null 2>&1 || rc=$?
(( rc == 40 )) \
  && pass_at "T12: dimensions: [] (len 0) → exit 40" \
  || fail_at "T12: empty dimensions" "expected rc=40, got rc=$rc"

# ─── T13: dimensions[0].name fails regex (capital letter) → exit 40 ──
cat > "$FIXTURE_DIR/t13.json" <<'EOF'
{
  "qa_payload_schema_version": 1,
  "issue_id": "ENG-1",
  "dispatch_id": "ENG-1-d0001",
  "verdict": "pass",
  "dimensions": [
    { "name": "Coverage", "score": 1.0, "rationale": "ok", "threshold_met": true }
  ]
}
EOF
rc=0; bash "$VALIDATOR" validate "$FIXTURE_DIR/t13.json" >/dev/null 2>&1 || rc=$?
(( rc == 40 )) \
  && pass_at "T13: dimensions[0].name=\"Coverage\" (capital) → exit 40" \
  || fail_at "T13: name regex" "expected rc=40, got rc=$rc"

# ─── T14: dimensions[0].score out of range (1.5) → exit 40 ───────────
cat > "$FIXTURE_DIR/t14.json" <<'EOF'
{
  "qa_payload_schema_version": 1,
  "issue_id": "ENG-1",
  "dispatch_id": "ENG-1-d0001",
  "verdict": "pass",
  "dimensions": [
    { "name": "gate_compliance", "score": 1.5, "rationale": "ok", "threshold_met": true }
  ]
}
EOF
rc=0; bash "$VALIDATOR" validate "$FIXTURE_DIR/t14.json" >/dev/null 2>&1 || rc=$?
(( rc == 40 )) \
  && pass_at "T14: dimensions[0].score=1.5 → exit 40" \
  || fail_at "T14: score out of range" "expected rc=40, got rc=$rc"

# ─── T15: dimensions[0].score: "0.8" (string) → exit 40 ──────────────
cat > "$FIXTURE_DIR/t15.json" <<'EOF'
{
  "qa_payload_schema_version": 1,
  "issue_id": "ENG-1",
  "dispatch_id": "ENG-1-d0001",
  "verdict": "pass",
  "dimensions": [
    { "name": "gate_compliance", "score": "0.8", "rationale": "ok", "threshold_met": true }
  ]
}
EOF
rc=0; bash "$VALIDATOR" validate "$FIXTURE_DIR/t15.json" >/dev/null 2>&1 || rc=$?
(( rc == 40 )) \
  && pass_at "T15: dimensions[0].score=\"0.8\" (string) → exit 40" \
  || fail_at "T15: score string" "expected rc=40, got rc=$rc"

# ─── T16: dimensions[0].rationale empty → exit 40 ────────────────────
cat > "$FIXTURE_DIR/t16.json" <<'EOF'
{
  "qa_payload_schema_version": 1,
  "issue_id": "ENG-1",
  "dispatch_id": "ENG-1-d0001",
  "verdict": "pass",
  "dimensions": [
    { "name": "gate_compliance", "score": 1.0, "rationale": "", "threshold_met": true }
  ]
}
EOF
rc=0; bash "$VALIDATOR" validate "$FIXTURE_DIR/t16.json" >/dev/null 2>&1 || rc=$?
(( rc == 40 )) \
  && pass_at "T16: rationale empty → exit 40" \
  || fail_at "T16: empty rationale" "expected rc=40, got rc=$rc"

# ─── T17: dimensions[0].threshold_met missing → exit 40 ──────────────
cat > "$FIXTURE_DIR/t17.json" <<'EOF'
{
  "qa_payload_schema_version": 1,
  "issue_id": "ENG-1",
  "dispatch_id": "ENG-1-d0001",
  "verdict": "pass",
  "dimensions": [
    { "name": "gate_compliance", "score": 1.0, "rationale": "ok" }
  ]
}
EOF
rc=0; bash "$VALIDATOR" validate "$FIXTURE_DIR/t17.json" >/dev/null 2>&1 || rc=$?
(( rc == 40 )) \
  && pass_at "T17: threshold_met missing → exit 40" \
  || fail_at "T17: threshold_met missing" "expected rc=40, got rc=$rc"

# ─── T18: unknown top-level field → exit 0 + stderr warning ──────────
cat > "$FIXTURE_DIR/t18.json" <<'EOF'
{
  "qa_payload_schema_version": 1,
  "issue_id": "ENG-1",
  "dispatch_id": "ENG-1-d0001",
  "verdict": "pass",
  "debug": "scratch context for future readers",
  "dimensions": [
    { "name": "gate_compliance", "score": 1.0, "rationale": "ok", "threshold_met": true }
  ]
}
EOF
rc=0
stdout_out="$(bash "$VALIDATOR" validate "$FIXTURE_DIR/t18.json" 2>/dev/null)" || rc=$?
stderr_out="$(bash "$VALIDATOR" validate "$FIXTURE_DIR/t18.json" 2>&1 >/dev/null)" || true
(( rc == 0 )) \
  && pass_at "T18: unknown top-level field (\"debug\") → exit 0" \
  || fail_at "T18: unknown top-level field exit code" "expected rc=0, got rc=$rc"
if [[ "$stderr_out" == *"warning"* ]] && [[ "$stderr_out" == *"debug"* ]]; then
  pass_at "T18: unknown top-level field stderr contains 'warning' and 'debug'"
else
  fail_at "T18: unknown top-level field warning" "stderr should contain 'warning' and 'debug', got: $stderr_out"
fi

# ─── T19: unknown per-dimension field → exit 0 + stderr warning ──────
cat > "$FIXTURE_DIR/t19.json" <<'EOF'
{
  "qa_payload_schema_version": 1,
  "issue_id": "ENG-1",
  "dispatch_id": "ENG-1-d0001",
  "verdict": "pass",
  "dimensions": [
    { "name": "gate_compliance", "score": 1.0, "rationale": "ok", "threshold_met": true, "weight": 0.5 }
  ]
}
EOF
rc=0
stdout_out="$(bash "$VALIDATOR" validate "$FIXTURE_DIR/t19.json" 2>/dev/null)" || rc=$?
stderr_out="$(bash "$VALIDATOR" validate "$FIXTURE_DIR/t19.json" 2>&1 >/dev/null)" || true
(( rc == 0 )) \
  && pass_at "T19: unknown per-dimension field (\"weight\") → exit 0" \
  || fail_at "T19: unknown per-dim field exit code" "expected rc=0, got rc=$rc"
if [[ "$stderr_out" == *"warning"* ]] && [[ "$stderr_out" == *"weight"* ]]; then
  pass_at "T19: unknown per-dim field stderr contains 'warning' and 'weight'"
else
  fail_at "T19: unknown per-dim field warning" "stderr should contain 'warning' and 'weight', got: $stderr_out"
fi

# ─── T20: issue_id mismatch with --ident → exit 40 ───────────────────
f="$(write_valid_fixture t20.json ENG-117 ENG-117-d0001)"
rc=0; out="$(bash "$VALIDATOR" validate "$f" --ident ENG-999 --dispatch-id ENG-117-d0001 2>&1)" || rc=$?
(( rc == 40 )) \
  && pass_at "T20: issue_id mismatch (JSON ENG-117 vs --ident ENG-999) → exit 40" \
  || fail_at "T20: issue_id mismatch" "expected rc=40, got rc=$rc"
if [[ "$out" == *"issue_id mismatch"* ]]; then
  pass_at "T20: diagnostic contains 'issue_id mismatch'"
else
  fail_at "T20: issue_id mismatch hint" "diagnostic should mention 'issue_id mismatch'; got: $out"
fi

# ─── T21: dispatch_id mismatch with --dispatch-id → exit 40 ──────────
f="$(write_valid_fixture t21.json ENG-117 ENG-117-d0001)"
rc=0; out="$(bash "$VALIDATOR" validate "$f" --ident ENG-117 --dispatch-id ENG-117-d9999 2>&1)" || rc=$?
(( rc == 40 )) \
  && pass_at "T21: dispatch_id mismatch (JSON d0001 vs --dispatch-id d9999) → exit 40" \
  || fail_at "T21: dispatch_id mismatch" "expected rc=40, got rc=$rc"
if [[ "$out" == *"dispatch_id mismatch"* ]]; then
  pass_at "T21: diagnostic contains 'dispatch_id mismatch'"
else
  fail_at "T21: dispatch_id mismatch hint" "diagnostic should mention 'dispatch_id mismatch'; got: $out"
fi

# ─── T_schema_doc_sync: AGENT_PROMPTS §6 step 8 ↔ validator header ───
# Drift detection between §6 step 8's inline schema reference and the
# validator's canonical schema. The validator's header-comment JSON shape
# names the required top-level fields; §6 step 8 enumerates them as
# prose for the agent. Both must reference the same field set.
printf '\n--- qa-payload-schema-test: T_schema_doc_sync ---\n'
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AGENT_PROMPTS_FILE="$PROJECT_ROOT/AGENT_PROMPTS.md"
sync_failures=0
if [[ ! -f "$AGENT_PROMPTS_FILE" ]]; then
  fail_at "T_schema_doc_sync setup" "AGENT_PROMPTS.md not found at $AGENT_PROMPTS_FILE"
else
  # The validator header MUST name every required top-level field; §6 step 8
  # MUST reference the same names. Check both directions.
  for field in qa_payload_schema_version issue_id dispatch_id verdict dimensions; do
    if ! grep -q "$field" "$VALIDATOR"; then
      fail_at "T_schema_doc_sync: validator missing field" "$field absent from $VALIDATOR"
      sync_failures=$((sync_failures + 1))
    fi
    # Find the §6 step 8 block by literal anchor and assert each field appears
    # within the file.
    if ! grep -q "$field" "$AGENT_PROMPTS_FILE"; then
      fail_at "T_schema_doc_sync: AGENT_PROMPTS missing field" "$field absent from AGENT_PROMPTS.md (§6 step 8 should reference)"
      sync_failures=$((sync_failures + 1))
    fi
  done
  # Step 8 anchor: the literal "Emit dimensional grading payload" heading.
  if grep -q "Emit dimensional grading payload" "$AGENT_PROMPTS_FILE"; then
    pass_at "T_schema_doc_sync: §6 step 8 anchor 'Emit dimensional grading payload' present"
  else
    fail_at "T_schema_doc_sync: §6 step 8 anchor" "literal 'Emit dimensional grading payload' missing from AGENT_PROMPTS.md"
    sync_failures=$((sync_failures + 1))
  fi
  if (( sync_failures == 0 )); then
    pass_at "T_schema_doc_sync: all 5 required field names appear in both validator header AND AGENT_PROMPTS.md"
  fi
fi

# ─── Summary ─────────────────────────────────────────────────────────
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
