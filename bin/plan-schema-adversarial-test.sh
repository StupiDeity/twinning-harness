#!/usr/bin/env bash
# QA-authored adversarial tests for bin/plan-schema.sh (ENG-122).
#
# Covers boundary cases and failure modes NOT in the plan's Failure Mode →
# Test Map (T1-T18 in plan-schema-test.sh + INT1-INT5/P/Q in run-stage-test.sh).
#
# Sub-agent (general-purpose, 2026-05-16) surfaced 10 untested breakage scenarios;
# this file covers the 9 most impactful (plus one regression guard).
#
# Pattern: direct CLI invocation (same as production path in _validate_plan_contract).

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_DRY_RUN=1
export PIPELINE_DRY_RUN

PASS=0; FAIL=0
pass_at() { PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
fail_at() { FAIL=$((FAIL+1)); printf '  ❌ %s — %s\n' "$1" "$2" >&2; }

FIXTURE_DIR="$(mktemp -d -t plan-schema-adv-test.XXXXXX)"
export TARGET_REPO="$FIXTURE_DIR/target"
mkdir -p "$TARGET_REPO/.pipeline-config"
printf '{"project":{"slug":"test-slug"}}\n' > "$TARGET_REPO/.pipeline-config/config.json"
export PROJECT_SLUG=test-slug
trap 'rm -rf "$FIXTURE_DIR"' EXIT

VALIDATOR="$SCRIPT_DIR/plan-schema.sh"

printf '\n--- plan-schema-adversarial-test: QA adversarial cases (ENG-122) ---\n'

# ─── T_adv_1: features[0].id = "" (explicit empty string) → exit 34 ─────────
# The plan-schema.sh code checks `[[ -z "$feat_id" ]]` so an empty string
# should trip rc=34. No plan test covers explicit "" vs absent.
cat > "$FIXTURE_DIR/adv1.json" <<'EOF'
{
  "plan_schema_version": 1,
  "issue_id": "ENG-1",
  "features": [
    {
      "id": "",
      "summary": "test",
      "pass_criteria": [{ "kind": "file_exists", "path": "x" }]
    }
  ]
}
EOF
rc=0; bash "$VALIDATOR" validate "$FIXTURE_DIR/adv1.json" >/dev/null 2>&1 || rc=$?
(( rc == 34 )) \
  && pass_at "T_adv_1: features[0].id='' (empty string) → exit 34" \
  || fail_at "T_adv_1: features[0].id empty string" "expected rc=34, got rc=$rc"

# ─── T_adv_2: features[0].summary = "" (explicit empty string) → exit 34 ────
cat > "$FIXTURE_DIR/adv2.json" <<'EOF'
{
  "plan_schema_version": 1,
  "issue_id": "ENG-1",
  "features": [
    {
      "id": "F-1",
      "summary": "",
      "pass_criteria": [{ "kind": "file_exists", "path": "x" }]
    }
  ]
}
EOF
rc=0; bash "$VALIDATOR" validate "$FIXTURE_DIR/adv2.json" >/dev/null 2>&1 || rc=$?
(( rc == 34 )) \
  && pass_at "T_adv_2: features[0].summary='' (empty string) → exit 34" \
  || fail_at "T_adv_2: features[0].summary empty string" "expected rc=34, got rc=$rc"

# ─── T_adv_3: features: null (not absent, not array) → exit 34 ───────────────
# JSON can represent null distinctly from a missing field.
# jq's `type` returns "null" for null, which != "array" → rc=34.
cat > "$FIXTURE_DIR/adv3.json" <<'EOF'
{
  "plan_schema_version": 1,
  "issue_id": "ENG-1",
  "features": null
}
EOF
rc=0; bash "$VALIDATOR" validate "$FIXTURE_DIR/adv3.json" >/dev/null 2>&1 || rc=$?
(( rc == 34 )) \
  && pass_at "T_adv_3: features=null (not array) → exit 34" \
  || fail_at "T_adv_3: features null" "expected rc=34, got rc=$rc"

# ─── T_adv_4: pass_criteria[0].kind = null → exit 34 ────────────────────────
# jq's `// "MISSING"` fallback fires for null (falsy), so kind="MISSING" → rc=34.
cat > "$FIXTURE_DIR/adv4.json" <<'EOF'
{
  "plan_schema_version": 1,
  "issue_id": "ENG-1",
  "features": [
    {
      "id": "F-1",
      "summary": "test",
      "pass_criteria": [{ "kind": null, "path": "x" }]
    }
  ]
}
EOF
rc=0; bash "$VALIDATOR" validate "$FIXTURE_DIR/adv4.json" >/dev/null 2>&1 || rc=$?
(( rc == 34 )) \
  && pass_at "T_adv_4: pass_criteria[0].kind=null → exit 34" \
  || fail_at "T_adv_4: kind null" "expected rc=34, got rc=$rc"

# ─── T_adv_5: plan_schema_version: "1" (string, not number) → exit 34 ────────
# Type check requires number; string "1" fails the jq `type == "number"` guard.
cat > "$FIXTURE_DIR/adv5.json" <<'EOF'
{
  "plan_schema_version": "1",
  "issue_id": "ENG-1",
  "features": [
    {
      "id": "F-1",
      "summary": "test",
      "pass_criteria": [{ "kind": "file_exists", "path": "x" }]
    }
  ]
}
EOF
rc=0; bash "$VALIDATOR" validate "$FIXTURE_DIR/adv5.json" >/dev/null 2>&1 || rc=$?
(( rc == 34 )) \
  && pass_at "T_adv_5: plan_schema_version='1' (string, not number) → exit 34" \
  || fail_at "T_adv_5: plan_schema_version string" "expected rc=34, got rc=$rc"

# ─── T_adv_6: smoke expect_exit = 0.5 (float, not integer) → documents behavior
# JSON has no integer type; jq's type returns "number" for both 0 and 0.5.
# The validator only checks type=="number", so 0.5 passes (rc=0).
# This is a documented limitation: downstream consumers must validate integer.
# This test asserts the ACTUAL behavior and guards against regression.
cat > "$FIXTURE_DIR/adv6.json" <<'EOF'
{
  "plan_schema_version": 1,
  "issue_id": "ENG-1",
  "features": [
    {
      "id": "F-1",
      "summary": "test",
      "pass_criteria": [{ "kind": "smoke", "command": "echo hi", "expect_exit": 0.5 }]
    }
  ]
}
EOF
rc=0; bash "$VALIDATOR" validate "$FIXTURE_DIR/adv6.json" >/dev/null 2>&1 || rc=$?
(( rc == 0 )) \
  && pass_at "T_adv_6: smoke expect_exit=0.5 (float) → rc=0 (known: JSON has no integer type; downstream consumers validate)" \
  || fail_at "T_adv_6: smoke float expect_exit behavior change" "expected rc=0 (float passes type==number check), got rc=$rc"

# ─── T_adv_7: --ident flag BEFORE file argument → should work ────────────────
# The parser processes --ident first, then the positional file argument.
# Verifies the flag-ordering contract: --ident ENG-1 plan.json == plan.json --ident ENG-1.
cat > "$FIXTURE_DIR/adv7.json" <<'EOF'
{
  "plan_schema_version": 1,
  "issue_id": "ENG-1",
  "features": [
    {
      "id": "F-1",
      "summary": "test",
      "pass_criteria": [{ "kind": "file_exists", "path": "x" }]
    }
  ]
}
EOF
rc=0; bash "$VALIDATOR" validate --ident ENG-1 "$FIXTURE_DIR/adv7.json" >/dev/null 2>&1 || rc=$?
(( rc == 0 )) \
  && pass_at "T_adv_7: --ident before file argument → exit 0 (flag ordering commutes)" \
  || fail_at "T_adv_7: --ident before file" "expected rc=0, got rc=$rc"

# ─── T_adv_8: two positional file arguments → exit 33 (usage error) ──────────
# Second positional arg triggers "unexpected argument" → return 33.
cat > "$FIXTURE_DIR/adv8a.json" <<'EOF'
{ "plan_schema_version": 1, "issue_id": "ENG-1", "features": [{ "id": "F-1", "summary": "t", "pass_criteria": [{ "kind": "file_exists", "path": "x" }] }] }
EOF
rc=0; bash "$VALIDATOR" validate "$FIXTURE_DIR/adv8a.json" "$FIXTURE_DIR/adv8a.json" >/dev/null 2>&1 || rc=$?
(( rc == 33 )) \
  && pass_at "T_adv_8: two positional file arguments → exit 33 (usage error)" \
  || fail_at "T_adv_8: two positional args" "expected rc=33, got rc=$rc"

# ─── T_adv_9: plan_schema_version: 1.0 (float 1) → documents behavior ────────
# jq numeric equality (.plan_schema_version == 1) treats 1.0 == 1 as true in JSON.
# This is intentionally permissive: 1.0 == 1 in JSON semantics.
cat > "$FIXTURE_DIR/adv9.json" <<'EOF'
{
  "plan_schema_version": 1.0,
  "issue_id": "ENG-1",
  "features": [
    {
      "id": "F-1",
      "summary": "test",
      "pass_criteria": [{ "kind": "file_exists", "path": "x" }]
    }
  ]
}
EOF
rc=0; bash "$VALIDATOR" validate "$FIXTURE_DIR/adv9.json" >/dev/null 2>&1 || rc=$?
(( rc == 0 )) \
  && pass_at "T_adv_9: plan_schema_version=1.0 (float) → rc=0 (jq numeric equality: 1.0==1; intentional)" \
  || fail_at "T_adv_9: plan_schema_version=1.0 behavior change" "expected rc=0, got rc=$rc"

# ─── T_adv_10: multiple valid features with all three kinds → exit 0 ─────────
# Validates that the per-feature/per-criterion iteration handles multiple entries.
cat > "$FIXTURE_DIR/adv10.json" <<'EOF'
{
  "plan_schema_version": 1,
  "issue_id": "ENG-1",
  "features": [
    {
      "id": "F-1",
      "summary": "first feature",
      "pass_criteria": [
        { "kind": "smoke",       "command": "echo hi", "expect_exit": 0 },
        { "kind": "file_exists", "path": "bin/plan-schema.sh" }
      ]
    },
    {
      "id": "F-2",
      "summary": "second feature",
      "pass_criteria": [
        { "kind": "grep", "path": "bin/plan-schema.sh", "pattern": "BASH_SOURCE", "expect_match": true },
        { "kind": "grep", "path": "bin/plan-schema.sh", "pattern": "ABSENT_TOKEN", "expect_match": false }
      ]
    }
  ]
}
EOF
rc=0; bash "$VALIDATOR" validate "$FIXTURE_DIR/adv10.json" >/dev/null 2>&1 || rc=$?
(( rc == 0 )) \
  && pass_at "T_adv_10: multi-feature, all three kinds → exit 0" \
  || fail_at "T_adv_10: multi-feature all kinds" "expected rc=0, got rc=$rc"

printf '\nplan-schema-adversarial-test: passed=%d failed=%d\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
