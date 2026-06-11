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

# ─── T_unicode: UTF-8 field values parse correctly (Nit 7) ───────────────
# Locks current jq behavior: jq parses and outputs UTF-8 summary/id strings
# without mangling. Regression guard against a future jq version change or
# locale shift that would corrupt non-ASCII content.
cat > "$FIXTURE_DIR/t_unicode.json" <<'EOF'
{
  "plan_schema_version": 1,
  "issue_id": "ENG-1",
  "features": [
    {
      "id": "F-1",
      "summary": "Ünïcödé feature: résumé / 日本語 / emoji 🚀",
      "pass_criteria": [{ "kind": "file_exists", "path": "README.md" }]
    }
  ]
}
EOF
rc=0; bash "$VALIDATOR" validate "$FIXTURE_DIR/t_unicode.json" >/dev/null 2>&1 || rc=$?
(( rc == 0 )) \
  && pass_at "T_unicode: UTF-8 summary with non-ASCII chars → exit 0 (jq handles Unicode)" \
  || fail_at "T_unicode: UTF-8 summary" "expected rc=0, got rc=$rc"

# ─── ENG-157: T_validate_md_* — MD-side validator unit tests ──────────
# Cover the `cmd_validate_md` sub-command which enforces the new
# `## System invariants` H2 section + parseable `verified_by:` token
# contract on plan markdowns. Each test follows the same pass_at/fail_at
# pattern as T1-T18.

printf '\n--- ENG-157: T_validate_md_* (cmd_validate_md) ---\n'

# ─── T_validate_md_valid_single: one bullet with <path>:<test-name> → rc=0
cat > "$FIXTURE_DIR/md_valid_single.md" <<'MDEOF'
---
linear: ENG-1
---

# stub

## System invariants

- foo verified_by: bin/foo.sh:T_foo
MDEOF
rc=0
md_out="$(bash "$VALIDATOR" validate-md "$FIXTURE_DIR/md_valid_single.md" 2>/dev/null)" || rc=$?
(( rc == 0 )) \
  && pass_at "T_validate_md_valid_single: one valid bullet → rc=0" \
  || fail_at "T_validate_md_valid_single" "expected rc=0, got rc=$rc; out=$md_out"
if [[ "$md_out" == *"plan-md-contract-valid:"* ]]; then
  pass_at "T_validate_md_valid_single: stdout contains plan-md-contract-valid:"
else
  fail_at "T_validate_md_valid_single: missing valid marker" "out=$md_out"
fi

# ─── T_validate_md_valid_multi: three bullets, mix of token shapes → rc=0
cat > "$FIXTURE_DIR/md_valid_multi.md" <<'MDEOF'
# stub

## System invariants

- I-1: foo verified_by: bin/foo.sh:T_foo
- I-2: bar verified_by: task:T2
- I-3: baz verified_by: bin/baz-test.sh:T_baz_passes

## Other section
MDEOF
rc=0; bash "$VALIDATOR" validate-md "$FIXTURE_DIR/md_valid_multi.md" >/dev/null 2>&1 || rc=$?
(( rc == 0 )) \
  && pass_at "T_validate_md_valid_multi: 3 bullets, mixed token shapes → rc=0" \
  || fail_at "T_validate_md_valid_multi" "expected rc=0, got rc=$rc"

# ─── T_validate_md_missing_section: heading absent → rc=34
cat > "$FIXTURE_DIR/md_missing_section.md" <<'MDEOF'
# stub

## Goal

x

## File Structure

y
MDEOF
rc=0
md_out="$(bash "$VALIDATOR" validate-md "$FIXTURE_DIR/md_missing_section.md" 2>/dev/null)" || rc=$?
(( rc == 34 )) \
  && pass_at "T_validate_md_missing_section: heading absent → rc=34" \
  || fail_at "T_validate_md_missing_section" "expected rc=34, got rc=$rc"
if [[ "$md_out" == *'plan-md-incomplete: required H2 section "## System invariants" missing'* ]]; then
  pass_at "T_validate_md_missing_section: diagnostic names missing H2 section"
else
  fail_at "T_validate_md_missing_section: diagnostic shape" "out=$md_out"
fi

# Sub-cases: typos on the heading are treated as "missing section" — the
# validator matches the literal heading only. Plan Failure Mode → Test Map
# enumerates four typo shapes (capital `I`, singular, H3, lowercase `s`).
cat > "$FIXTURE_DIR/md_heading_typo.md" <<'MDEOF'
## system invariants

- foo verified_by: bin/foo.sh:T_foo
MDEOF
rc=0; bash "$VALIDATOR" validate-md "$FIXTURE_DIR/md_heading_typo.md" >/dev/null 2>&1 || rc=$?
(( rc == 34 )) \
  && pass_at "T_validate_md_missing_section: lowercase typo → rc=34 (heading literal-match)" \
  || fail_at "T_validate_md_missing_section (typo subcase)" "expected rc=34, got rc=$rc"

cat > "$FIXTURE_DIR/md_heading_typo_capital_i.md" <<'MDEOF'
## System Invariants

- foo verified_by: bin/foo.sh:T_foo
MDEOF
rc=0; bash "$VALIDATOR" validate-md "$FIXTURE_DIR/md_heading_typo_capital_i.md" >/dev/null 2>&1 || rc=$?
(( rc == 34 )) \
  && pass_at "T_validate_md_missing_section: capital-I typo → rc=34 (heading literal-match)" \
  || fail_at "T_validate_md_missing_section (capital-I subcase)" "expected rc=34, got rc=$rc"

cat > "$FIXTURE_DIR/md_heading_typo_singular.md" <<'MDEOF'
## System invariant

- foo verified_by: bin/foo.sh:T_foo
MDEOF
rc=0; bash "$VALIDATOR" validate-md "$FIXTURE_DIR/md_heading_typo_singular.md" >/dev/null 2>&1 || rc=$?
(( rc == 34 )) \
  && pass_at "T_validate_md_missing_section: singular typo → rc=34 (heading literal-match)" \
  || fail_at "T_validate_md_missing_section (singular subcase)" "expected rc=34, got rc=$rc"

cat > "$FIXTURE_DIR/md_heading_typo_h3.md" <<'MDEOF'
### System invariants

- foo verified_by: bin/foo.sh:T_foo
MDEOF
rc=0; bash "$VALIDATOR" validate-md "$FIXTURE_DIR/md_heading_typo_h3.md" >/dev/null 2>&1 || rc=$?
(( rc == 34 )) \
  && pass_at "T_validate_md_missing_section: H3 typo → rc=34 (heading literal-match)" \
  || fail_at "T_validate_md_missing_section (H3 subcase)" "expected rc=34, got rc=$rc"

# ─── T_validate_md_zero_bullets: heading present, no bullets → rc=34
cat > "$FIXTURE_DIR/md_zero_bullets.md" <<'MDEOF'
# stub

## System invariants

(no bullets — just prose.)

## Next section
MDEOF
rc=0
md_out="$(bash "$VALIDATOR" validate-md "$FIXTURE_DIR/md_zero_bullets.md" 2>/dev/null)" || rc=$?
(( rc == 34 )) \
  && pass_at "T_validate_md_zero_bullets: heading + 0 bullets → rc=34" \
  || fail_at "T_validate_md_zero_bullets" "expected rc=34, got rc=$rc"
if [[ "$md_out" == *'"## System invariants" section has 0 bullets'* ]]; then
  pass_at "T_validate_md_zero_bullets: diagnostic names 0 bullets"
else
  fail_at "T_validate_md_zero_bullets: diagnostic shape" "out=$md_out"
fi

# ─── T_validate_md_missing_token: bullet lacks verified_by: → rc=34
cat > "$FIXTURE_DIR/md_missing_token.md" <<'MDEOF'
## System invariants

- this bullet has no verified-by reference at all
MDEOF
rc=0
md_out="$(bash "$VALIDATOR" validate-md "$FIXTURE_DIR/md_missing_token.md" 2>/dev/null)" || rc=$?
(( rc == 34 )) \
  && pass_at "T_validate_md_missing_token: bullet lacks verified_by: → rc=34" \
  || fail_at "T_validate_md_missing_token" "expected rc=34, got rc=$rc"
if [[ "$md_out" == *"bullet 1"* ]] && [[ "$md_out" == *'lacks parseable "verified_by:" reference'* ]]; then
  pass_at "T_validate_md_missing_token: diagnostic carries bullet index + reference shape"
else
  fail_at "T_validate_md_missing_token: diagnostic shape" "out=$md_out"
fi

# ─── T_validate_md_malformed_token: gibberish_no_colon → rc=33
cat > "$FIXTURE_DIR/md_malformed_token.md" <<'MDEOF'
## System invariants

- foo verified_by: gibberish_no_colon
MDEOF
rc=0
md_out="$(bash "$VALIDATOR" validate-md "$FIXTURE_DIR/md_malformed_token.md" 2>/dev/null)" || rc=$?
(( rc == 33 )) \
  && pass_at "T_validate_md_malformed_token: unparseable token → rc=33" \
  || fail_at "T_validate_md_malformed_token" "expected rc=33, got rc=$rc"
if [[ "$md_out" == *"plan-md-malformed:"* ]]; then
  pass_at "T_validate_md_malformed_token: diagnostic prefix is plan-md-malformed:"
else
  fail_at "T_validate_md_malformed_token: prefix" "out=$md_out"
fi

# ─── T_validate_md_no_arg: no positional file → rc=33
rc=0
md_out="$(bash "$VALIDATOR" validate-md 2>/dev/null)" || rc=$?
(( rc == 33 )) \
  && pass_at "T_validate_md_no_arg: missing file argument → rc=33" \
  || fail_at "T_validate_md_no_arg" "expected rc=33, got rc=$rc"
if [[ "$md_out" == *"plan-md-malformed: file argument required"* ]]; then
  pass_at "T_validate_md_no_arg: diagnostic says file argument required"
else
  fail_at "T_validate_md_no_arg: diagnostic shape" "out=$md_out"
fi

# ─── T_validate_md_missing_file: path does not exist → rc=35
rc=0
md_out="$(bash "$VALIDATOR" validate-md "$FIXTURE_DIR/never_existed.md" 2>/dev/null)" || rc=$?
(( rc == 35 )) \
  && pass_at "T_validate_md_missing_file: path does not exist → rc=35" \
  || fail_at "T_validate_md_missing_file" "expected rc=35, got rc=$rc"
if [[ "$md_out" == *"plan-md-missing: file not found"* ]]; then
  pass_at "T_validate_md_missing_file: diagnostic says file not found"
else
  fail_at "T_validate_md_missing_file: diagnostic shape" "out=$md_out"
fi

# ─── T_validate_md_bsd_awk_sanity: bullet with embedded TAB before verified_by:
# Verifies I-4: BSD awk on macOS handles `[[:space:]]` for tab characters.
# If BSD awk balks, the implementer falls back to `[ \t]` POSIX class.
printf '## System invariants\n\n- foo\tverified_by: bin/foo.sh:T_foo\n' \
  > "$FIXTURE_DIR/md_bsd_awk_sanity.md"
rc=0; bash "$VALIDATOR" validate-md "$FIXTURE_DIR/md_bsd_awk_sanity.md" >/dev/null 2>&1 || rc=$?
(( rc == 0 )) \
  && pass_at "T_validate_md_bsd_awk_sanity: bullet w/ TAB before verified_by → rc=0 (BSD awk [[:space:]] OK)" \
  || fail_at "T_validate_md_bsd_awk_sanity" "expected rc=0, got rc=$rc (BSD awk regex incompatibility?)"

# ─── T_validate_md_large_fixture: 50 bullets → rc=0 (informational latency)
{
  printf '## System invariants\n\n'
  for i in $(seq 1 50); do
    printf -- '- I-%d: invariant %d verified_by: bin/test.sh:T_case_%d\n' "$i" "$i" "$i"
  done
} > "$FIXTURE_DIR/md_large_fixture.md"
rc=0; bash "$VALIDATOR" validate-md "$FIXTURE_DIR/md_large_fixture.md" >/dev/null 2>&1 || rc=$?
(( rc == 0 )) \
  && pass_at "T_validate_md_large_fixture: 50-bullet plan → rc=0 (informational; A-017)" \
  || fail_at "T_validate_md_large_fixture" "expected rc=0, got rc=$rc"

printf '\nplan-schema-test: passed=%d failed=%d\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
