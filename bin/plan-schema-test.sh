#!/usr/bin/env bash
# Tests for bin/plan-schema.sh (ENG-122).
#
# Covers T1-T12 (validator unit tests) and T_schema_doc_sync (drift check
# between AGENT_PROMPTS.md §2's inline schema block and bin/plan-schema.sh's
# header-comment schema).
#
# Pattern: source-and-stub (CLAUDE.md "How tests work"). Tests invoke
# bin/plan-schema.sh via direct CLI call (matches production invocation in
# _validate_plan_contract).

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_DRY_RUN=1
export PIPELINE_DRY_RUN

PASS=0; FAIL=0
pass_at() { PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
fail_at() { FAIL=$((FAIL+1)); printf '  ❌ %s — %s\n' "$1" "$2" >&2; }

FIXTURE_DIR="$(mktemp -d -t plan-schema-test.XXXXXX)"
# plan-schema.sh sources common.sh which requires TARGET_REPO + PROJECT_SLUG.
export TARGET_REPO="$FIXTURE_DIR/target"
mkdir -p "$TARGET_REPO/.pipeline-config"
printf '{"project":{"slug":"test-slug"}}\n' > "$TARGET_REPO/.pipeline-config/config.json"
export PROJECT_SLUG=test-slug
trap 'rm -rf "$FIXTURE_DIR"' EXIT

# ─── Helpers ─────────────────────────────────────────────────────────

# Write a well-formed schema-v1 fixture to a named file and return the path.
# Usage: write_valid_fixture <filename> [issue_id]
write_valid_fixture() {
  local file="$FIXTURE_DIR/${1}"
  local iid="${2:-ENG-1}"
  cat > "$file" <<EOF
{
  "plan_schema_version": 1,
  "issue_id": "$iid",
  "features": [
    {
      "id": "F-1",
      "summary": "Test feature",
      "pass_criteria": [
        { "kind": "file_exists", "path": "bin/plan-schema.sh" }
      ]
    }
  ]
}
EOF
  printf '%s' "$file"
}

VALIDATOR="$SCRIPT_DIR/plan-schema.sh"

printf '\n--- plan-schema-test: T1-T12 + T_schema_doc_sync ---\n'

# ─── T1: well-formed schema-v1 JSON → exit 0 ─────────────────────────
f="$(write_valid_fixture t1.json ENG-1)"
rc=0; bash "$VALIDATOR" validate "$f" --ident ENG-1 >/dev/null 2>&1 || rc=$?
(( rc == 0 )) \
  && pass_at "T1: well-formed JSON → exit 0" \
  || fail_at "T1: well-formed JSON" "expected rc=0, got rc=$rc"

# ─── T2: missing file → exit 35 ──────────────────────────────────────
rc=0; bash "$VALIDATOR" validate "$FIXTURE_DIR/nonexistent.json" >/dev/null 2>&1 || rc=$?
(( rc == 35 )) \
  && pass_at "T2: missing file → exit 35" \
  || fail_at "T2: missing file" "expected rc=35, got rc=$rc"

# ─── T3: malformed JSON syntax (stray comma) → exit 33 ───────────────
printf '{,}\n' > "$FIXTURE_DIR/t3.json"
rc=0; bash "$VALIDATOR" validate "$FIXTURE_DIR/t3.json" >/dev/null 2>&1 || rc=$?
(( rc == 33 )) \
  && pass_at "T3: malformed JSON syntax → exit 33" \
  || fail_at "T3: malformed JSON syntax" "expected rc=33, got rc=$rc"

# ─── T4: malformed (top-level array, not object) → exit 33 ───────────
printf '[1, 2, 3]\n' > "$FIXTURE_DIR/t4.json"
rc=0; bash "$VALIDATOR" validate "$FIXTURE_DIR/t4.json" >/dev/null 2>&1 || rc=$?
(( rc == 33 )) \
  && pass_at "T4: top-level array → exit 33" \
  || fail_at "T4: top-level array" "expected rc=33, got rc=$rc"

# ─── T5: incomplete — missing plan_schema_version → exit 34 ──────────
cat > "$FIXTURE_DIR/t5.json" <<'EOF'
{
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
rc=0; bash "$VALIDATOR" validate "$FIXTURE_DIR/t5.json" >/dev/null 2>&1 || rc=$?
(( rc == 34 )) \
  && pass_at "T5: missing plan_schema_version → exit 34" \
  || fail_at "T5: missing plan_schema_version" "expected rc=34, got rc=$rc"

# ─── T6: incomplete — issue_id is integer, not string → exit 34 ──────
cat > "$FIXTURE_DIR/t6.json" <<'EOF'
{
  "plan_schema_version": 1,
  "issue_id": 1,
  "features": [
    {
      "id": "F-1",
      "summary": "test",
      "pass_criteria": [{ "kind": "file_exists", "path": "x" }]
    }
  ]
}
EOF
rc=0; bash "$VALIDATOR" validate "$FIXTURE_DIR/t6.json" >/dev/null 2>&1 || rc=$?
(( rc == 34 )) \
  && pass_at "T6: issue_id is integer → exit 34" \
  || fail_at "T6: issue_id integer" "expected rc=34, got rc=$rc"

# ─── T7: incomplete — features: [] (empty) → exit 34 ─────────────────
cat > "$FIXTURE_DIR/t7.json" <<'EOF'
{
  "plan_schema_version": 1,
  "issue_id": "ENG-1",
  "features": []
}
EOF
rc=0; bash "$VALIDATOR" validate "$FIXTURE_DIR/t7.json" >/dev/null 2>&1 || rc=$?
(( rc == 34 )) \
  && pass_at "T7: features=[] → exit 34" \
  || fail_at "T7: features empty" "expected rc=34, got rc=$rc"

# ─── T8: incomplete — pass_criteria: [] on first feature → exit 34 ───
cat > "$FIXTURE_DIR/t8.json" <<'EOF'
{
  "plan_schema_version": 1,
  "issue_id": "ENG-1",
  "features": [
    {
      "id": "F-1",
      "summary": "test",
      "pass_criteria": []
    }
  ]
}
EOF
rc=0; bash "$VALIDATOR" validate "$FIXTURE_DIR/t8.json" >/dev/null 2>&1 || rc=$?
(( rc == 34 )) \
  && pass_at "T8: pass_criteria=[] → exit 34" \
  || fail_at "T8: pass_criteria empty" "expected rc=34, got rc=$rc"

# ─── T9: incomplete — unknown kind "bogus" → exit 34 ─────────────────
cat > "$FIXTURE_DIR/t9.json" <<'EOF'
{
  "plan_schema_version": 1,
  "issue_id": "ENG-1",
  "features": [
    {
      "id": "F-1",
      "summary": "test",
      "pass_criteria": [{ "kind": "bogus", "path": "x" }]
    }
  ]
}
EOF
rc=0; bash "$VALIDATOR" validate "$FIXTURE_DIR/t9.json" >/dev/null 2>&1 || rc=$?
(( rc == 34 )) \
  && pass_at "T9: unknown kind bogus → exit 34" \
  || fail_at "T9: unknown kind" "expected rc=34, got rc=$rc"

# ─── T10: well-formed + unknown top-level field → exit 0 + stderr warns
cat > "$FIXTURE_DIR/t10.json" <<'EOF'
{
  "plan_schema_version": 1,
  "issue_id": "ENG-1",
  "roadmap": "some future thing",
  "features": [
    {
      "id": "F-1",
      "summary": "test",
      "pass_criteria": [{ "kind": "file_exists", "path": "x" }]
    }
  ]
}
EOF
rc=0
stdout_out="$(bash "$VALIDATOR" validate "$FIXTURE_DIR/t10.json" 2>/dev/null)" || rc=$?
stderr_out="$(bash "$VALIDATOR" validate "$FIXTURE_DIR/t10.json" 2>&1 >/dev/null)" || true
(( rc == 0 )) \
  && pass_at "T10: unknown top-level field → exit 0" \
  || fail_at "T10: unknown field exit code" "expected rc=0, got rc=$rc"
if [[ "$stderr_out" == *"warning"* ]] && [[ "$stderr_out" == *"roadmap"* ]]; then
  pass_at "T10: unknown top-level field stderr contains 'warning' and field name"
else
  fail_at "T10: unknown field warning" "stderr should contain 'warning' and 'roadmap', got: $stderr_out"
fi

# ─── T11: issue_id mismatch → exit 34 ────────────────────────────────
f="$(write_valid_fixture t11.json ENG-999)"
rc=0; bash "$VALIDATOR" validate "$f" --ident ENG-1 >/dev/null 2>&1 || rc=$?
(( rc == 34 )) \
  && pass_at "T11: issue_id mismatch → exit 34" \
  || fail_at "T11: issue_id mismatch" "expected rc=34, got rc=$rc"

# ─── T12: plan_schema_version: 2 → exit 34 ───────────────────────────
cat > "$FIXTURE_DIR/t12.json" <<'EOF'
{
  "plan_schema_version": 2,
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
rc=0; bash "$VALIDATOR" validate "$FIXTURE_DIR/t12.json" >/dev/null 2>&1 || rc=$?
(( rc == 34 )) \
  && pass_at "T12: plan_schema_version=2 → exit 34" \
  || fail_at "T12: schema version 2" "expected rc=34, got rc=$rc"

# ─── T_schema_doc_sync: AGENT_PROMPTS.md schema block parses as valid JSON
# and has the same top-level field set as the canonical schema in plan-schema.sh.
printf '\n--- T_schema_doc_sync ---\n'
AGENT_PROMPTS="$SCRIPT_DIR/../AGENT_PROMPTS.md"
if [[ ! -f "$AGENT_PROMPTS" ]]; then
  fail_at "T_schema_doc_sync: AGENT_PROMPTS.md not found" "$AGENT_PROMPTS"
else
  # Extract the plan-schema-v1 fenced block from AGENT_PROMPTS.md.
  # The block is indented inside a bullet list; `render-prompt.sh` only counts
  # column-0 fences. Use sed to extract between ```plan-schema-v1 and ``` .
  schema_block="$(awk '
    /```plan-schema-v1/ { in_block=1; next }
    in_block && /```/ { in_block=0; exit }
    in_block { print }
  ' "$AGENT_PROMPTS")"

  if [[ -z "$schema_block" ]]; then
    fail_at "T_schema_doc_sync: no plan-schema-v1 block found in AGENT_PROMPTS.md" \
      "expected a \`\`\`plan-schema-v1 ... \`\`\` block in §2 Plan Agent Output section"
  else
    # Replace {issue_id} template token with ENG-1 and try to parse as JSON.
    schema_json="$(printf '%s' "$schema_block" | sed 's/{issue_id}/ENG-1/g')"
    if printf '%s' "$schema_json" | jq -e 'type == "object"' >/dev/null 2>&1; then
      pass_at "T_schema_doc_sync: AGENT_PROMPTS.md schema block is valid JSON"

      # Check top-level field set equality with canonical keys.
      prompt_keys="$(printf '%s' "$schema_json" | jq -r 'keys | sort | join(",")')"
      canonical_keys="features,issue_id,plan_schema_version"
      if [[ "$prompt_keys" == "$canonical_keys" ]]; then
        pass_at "T_schema_doc_sync: field-set matches canonical schema (plan_schema_version, issue_id, features)"
      else
        fail_at "T_schema_doc_sync: field-set mismatch" \
          "expected keys=$canonical_keys, got prompt_keys=$prompt_keys"
      fi
    else
      fail_at "T_schema_doc_sync: AGENT_PROMPTS.md schema block is NOT valid JSON after {issue_id} substitution" \
        "block=$schema_block"
    fi
  fi
fi

# ─── T13-T18: kind-specific rc=34 paths (M2 review finding) ─────────────────
# Plan-schema.sh validates required fields for each kind. These six paths
# had no tests; the test strategy claimed full coverage but reality was partial.

# ─── T13: smoke — missing command → exit 34 ──────────────────────────
cat > "$FIXTURE_DIR/t13.json" <<'EOF'
{
  "plan_schema_version": 1,
  "issue_id": "ENG-1",
  "features": [
    {
      "id": "F-1",
      "summary": "test",
      "pass_criteria": [{ "kind": "smoke", "expect_exit": 0 }]
    }
  ]
}
EOF
rc=0; bash "$VALIDATOR" validate "$FIXTURE_DIR/t13.json" >/dev/null 2>&1 || rc=$?
(( rc == 34 )) \
  && pass_at "T13: smoke missing command → exit 34" \
  || fail_at "T13: smoke missing command" "expected rc=34, got rc=$rc"

# ─── T14: smoke — missing expect_exit → exit 34 ──────────────────────
cat > "$FIXTURE_DIR/t14.json" <<'EOF'
{
  "plan_schema_version": 1,
  "issue_id": "ENG-1",
  "features": [
    {
      "id": "F-1",
      "summary": "test",
      "pass_criteria": [{ "kind": "smoke", "command": "echo hi" }]
    }
  ]
}
EOF
rc=0; bash "$VALIDATOR" validate "$FIXTURE_DIR/t14.json" >/dev/null 2>&1 || rc=$?
(( rc == 34 )) \
  && pass_at "T14: smoke missing expect_exit → exit 34" \
  || fail_at "T14: smoke missing expect_exit" "expected rc=34, got rc=$rc"

# ─── T15: file_exists — missing path → exit 34 ───────────────────────
cat > "$FIXTURE_DIR/t15.json" <<'EOF'
{
  "plan_schema_version": 1,
  "issue_id": "ENG-1",
  "features": [
    {
      "id": "F-1",
      "summary": "test",
      "pass_criteria": [{ "kind": "file_exists" }]
    }
  ]
}
EOF
rc=0; bash "$VALIDATOR" validate "$FIXTURE_DIR/t15.json" >/dev/null 2>&1 || rc=$?
(( rc == 34 )) \
  && pass_at "T15: file_exists missing path → exit 34" \
  || fail_at "T15: file_exists missing path" "expected rc=34, got rc=$rc"

# ─── T16: grep — missing path → exit 34 ─────────────────────────────
cat > "$FIXTURE_DIR/t16.json" <<'EOF'
{
  "plan_schema_version": 1,
  "issue_id": "ENG-1",
  "features": [
    {
      "id": "F-1",
      "summary": "test",
      "pass_criteria": [{ "kind": "grep", "pattern": "foo", "expect_match": true }]
    }
  ]
}
EOF
rc=0; bash "$VALIDATOR" validate "$FIXTURE_DIR/t16.json" >/dev/null 2>&1 || rc=$?
(( rc == 34 )) \
  && pass_at "T16: grep missing path → exit 34" \
  || fail_at "T16: grep missing path" "expected rc=34, got rc=$rc"

# ─── T17: grep — missing pattern → exit 34 ───────────────────────────
cat > "$FIXTURE_DIR/t17.json" <<'EOF'
{
  "plan_schema_version": 1,
  "issue_id": "ENG-1",
  "features": [
    {
      "id": "F-1",
      "summary": "test",
      "pass_criteria": [{ "kind": "grep", "path": "bin/plan-schema.sh", "expect_match": true }]
    }
  ]
}
EOF
rc=0; bash "$VALIDATOR" validate "$FIXTURE_DIR/t17.json" >/dev/null 2>&1 || rc=$?
(( rc == 34 )) \
  && pass_at "T17: grep missing pattern → exit 34" \
  || fail_at "T17: grep missing pattern" "expected rc=34, got rc=$rc"

# ─── T18: grep — expect_match wrong type (string instead of boolean) → exit 34
cat > "$FIXTURE_DIR/t18.json" <<'EOF'
{
  "plan_schema_version": 1,
  "issue_id": "ENG-1",
  "features": [
    {
      "id": "F-1",
      "summary": "test",
      "pass_criteria": [{ "kind": "grep", "path": "x", "pattern": "y", "expect_match": "yes" }]
    }
  ]
}
EOF
rc=0; bash "$VALIDATOR" validate "$FIXTURE_DIR/t18.json" >/dev/null 2>&1 || rc=$?
(( rc == 34 )) \
  && pass_at "T18: grep expect_match wrong type (string) → exit 34" \
  || fail_at "T18: grep expect_match wrong type" "expected rc=34, got rc=$rc"

printf '\nplan-schema-test: passed=%d failed=%d\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
