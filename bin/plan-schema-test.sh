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

      # ENG-204 reframe: the prompt block now carries body-only keys ({features});
      # the envelope keys (plan_schema_version, issue_id) are added by the
      # orchestrator via cmd_prepare. Two assertions:
      # (a) prompt block keyset == {features} (body-only).
      # (b) validator's full keyset == body keyset ∪ {plan_schema_version, issue_id}
      #     (exactly those two keys are added by the envelope helper).
      prompt_keys="$(printf '%s' "$schema_json" | jq -r 'keys | sort | join(",")')"
      body_keyset="features"
      if [[ "$prompt_keys" == "$body_keyset" ]]; then
        pass_at "T_schema_doc_sync: prompt block keyset is body-only ({features})"
      else
        fail_at "T_schema_doc_sync: prompt block has unexpected keys" \
          "expected body-only keys=$body_keyset, got prompt_keys=$prompt_keys (envelope keys must not appear in prompt block — ENG-204)"
      fi
      validator_keys="features,issue_id,plan_schema_version"
      envelope_added="$(printf '%s,%s' "$prompt_keys" "issue_id,plan_schema_version" | tr ',' '\n' | sort -u | tr '\n' ',' | sed 's/,$//')"
      if [[ "$validator_keys" == "$envelope_added" ]]; then
        pass_at "T_schema_doc_sync: validator keyset == body keyset ∪ {plan_schema_version, issue_id}"
      else
        fail_at "T_schema_doc_sync: validator-vs-body-plus-envelope mismatch" \
          "expected=$validator_keys, computed union=$envelope_added"
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

# ─── ENG-192: CommonMark marker variety + multi-line bullet support ───
# The ENG-157 validator only matched `- ` markers on a bullet's first line.
# ENG-192 broadens to all three CommonMark unordered markers (`-`/`*`/`+`)
# and accumulates continuation lines so a wrapped `verified_by:` counts.

# ─── T_validate_md_asterisk_marker: `* ` bullets → rc=0
cat > "$FIXTURE_DIR/md_asterisk_marker.md" <<'MDEOF'
## System invariants

* I-1: foo verified_by: bin/foo.sh:T_foo
* I-2: bar verified_by: task:T2
MDEOF
rc=0; bash "$VALIDATOR" validate-md "$FIXTURE_DIR/md_asterisk_marker.md" >/dev/null 2>&1 || rc=$?
(( rc == 0 )) \
  && pass_at "T_validate_md_asterisk_marker: '* ' CommonMark bullets → rc=0 (ENG-192)" \
  || fail_at "T_validate_md_asterisk_marker" "expected rc=0, got rc=$rc"

# ─── T_validate_md_plus_marker: `+ ` bullets → rc=0
cat > "$FIXTURE_DIR/md_plus_marker.md" <<'MDEOF'
## System invariants

+ I-1: foo verified_by: bin/foo.sh:T_foo
MDEOF
rc=0; bash "$VALIDATOR" validate-md "$FIXTURE_DIR/md_plus_marker.md" >/dev/null 2>&1 || rc=$?
(( rc == 0 )) \
  && pass_at "T_validate_md_plus_marker: '+ ' CommonMark bullets → rc=0 (ENG-192)" \
  || fail_at "T_validate_md_plus_marker" "expected rc=0, got rc=$rc"

# ─── T_validate_md_multiline_token: verified_by: on a continuation line → rc=0
cat > "$FIXTURE_DIR/md_multiline_token.md" <<'MDEOF'
## System invariants

- I-1: a long invariant that wraps across several physical
  lines before the reference appears verified_by:
  bin/foo.sh:T_foo
MDEOF
rc=0; bash "$VALIDATOR" validate-md "$FIXTURE_DIR/md_multiline_token.md" >/dev/null 2>&1 || rc=$?
(( rc == 0 )) \
  && pass_at "T_validate_md_multiline_token: token on continuation line → rc=0 (ENG-192)" \
  || fail_at "T_validate_md_multiline_token" "expected rc=0, got rc=$rc"

# ─── T_validate_md_mixed_markers_multiline: `*`/`+` markers + wrapped tokens
# The exact ENG-192 emission shape — marker variety AND continuation-line
# tokens in one section. Pre-ENG-192 this halted with "0 bullets".
cat > "$FIXTURE_DIR/md_mixed_markers_multiline.md" <<'MDEOF'
## System invariants

* §3 hoisted block sits in the right place — verified_by:
  bin/agent-prompts-content-test.sh:t_eng192_pin2_position
* §3 fence count remains exactly 2 — verified_by:
  bin/agent-prompts-content-test.sh:t_eng192_pin10_fence_count

## File Structure
MDEOF
rc=0; bash "$VALIDATOR" validate-md "$FIXTURE_DIR/md_mixed_markers_multiline.md" >/dev/null 2>&1 || rc=$?
(( rc == 0 )) \
  && pass_at "T_validate_md_mixed_markers_multiline: ENG-192 real shape (asterisk + wrap) → rc=0" \
  || fail_at "T_validate_md_mixed_markers_multiline" "expected rc=0, got rc=$rc"

# ─── ENG-203: markdown-emphasis around the verified_by: label ─────────
# Planning agents emit `**verified_by:** task:T2` (bold label). The
# closing `**` sits between the colon and the token; the pre-ENG-203
# separator `[[:space:]]*` could not span it, so a semantically-valid
# plan halted with plan-md-malformed (rc=33). The separator now also
# tolerates `*`/`_`/backtick emphasis runs.
cat > "$FIXTURE_DIR/md_bold_label.md" <<'MDEOF'
## System invariants

- I-1: orchestrator owns the envelope. **verified_by:** task:T2
  (adds AP-1/AP-2 prompt-content assertions).
- I-2: merge helper is pure. **verified_by:** bin/common-test.sh:U_merge
MDEOF
rc=0; bash "$VALIDATOR" validate-md "$FIXTURE_DIR/md_bold_label.md" >/dev/null 2>&1 || rc=$?
(( rc == 0 )) \
  && pass_at "T_validate_md_bold_label: '**verified_by:**' bold label → rc=0 (ENG-203)" \
  || fail_at "T_validate_md_bold_label" "expected rc=0, got rc=$rc"

# ─── T_validate_md_multiline_missing_token: wrapped bullet, NO token anywhere
# Guard: multi-line accumulation must not mask a genuinely missing reference.
cat > "$FIXTURE_DIR/md_multiline_missing.md" <<'MDEOF'
## System invariants

- I-1: this invariant wraps across lines
  but never carries any reference at all

## Next
MDEOF
rc=0
md_out="$(bash "$VALIDATOR" validate-md "$FIXTURE_DIR/md_multiline_missing.md" 2>/dev/null)" || rc=$?
(( rc == 34 )) \
  && pass_at "T_validate_md_multiline_missing_token: wrapped bullet w/o token → rc=34 (no masking)" \
  || fail_at "T_validate_md_multiline_missing_token" "expected rc=34, got rc=$rc; out=$md_out"

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

# ─── ENG-204: cmd_prepare unit tests (P-1..P-16) ─────────────────────────────
# Each case uses its own mktemp sandbox, a PROJECT_STATE_DIR inside it,
# and cds into a temp worktree so the --md cwd fence resolves correctly.
printf '\n--- ENG-204: cmd_prepare P-1..P-16 ---\n'

# Minimal valid body content for prepare tests.
_valid_body='{"features":[{"id":"F-1","summary":"x","pass_criteria":[{"kind":"file_exists","path":"x"}]}]}'
# Minimal valid md path component (relative to cwd).
_md_relpath="docs/plans/2026-06-01-eng-1-test.md"

# Helper: run cmd_prepare in a sandboxed env, return its rc.
# Usage: _run_prepare <psd> <wt> [extra args...]
_run_prepare() {
  local _psd="$1" _wt="$2"; shift 2
  (
    export PROJECT_STATE_DIR="$_psd"
    export TARGET_REPO="$FIXTURE_DIR/target"
    export PROJECT_SLUG=test-slug
    cd "$_wt" 2>/dev/null || exit 99
    bash "$VALIDATOR" prepare "$@" 2>/dev/null
  )
}

# ─── P-1: envelope keyset closure ──────────────────────────────────────
p1_tmp="$(mktemp -d -t pst-p1.XXXXXX)"
trap 'rm -rf "$p1_tmp"' EXIT
p1_psd="$p1_tmp/project_state/test-slug"
p1_wt="$p1_tmp/worktree"
mkdir -p "$p1_psd/ENG-1" "$p1_wt/docs/plans"
printf '%s\n' "$_valid_body" > "$p1_psd/ENG-1/plan.body.json"
touch "$p1_wt/$_md_relpath"
rc=0; _run_prepare "$p1_psd" "$p1_wt" \
  --body "$p1_psd/ENG-1/plan.body.json" \
  --md "$_md_relpath" --ident ENG-1 >/dev/null 2>&1 || rc=$?
canonical="$p1_wt/${_md_relpath%.md}.json"
if (( rc == 0 )) && [[ -f "$canonical" ]]; then
  env_only_keys="$(jq -r '[keys[] | select(. != "features")] | sort | join(",")' "$canonical" 2>/dev/null)"
  if [[ "$env_only_keys" == "issue_id,plan_schema_version" ]]; then
    pass_at "P-1: envelope adds exactly {issue_id, plan_schema_version} — no extra keys"
  else
    fail_at "P-1: envelope keyset" "expected issue_id,plan_schema_version, got '$env_only_keys'"
  fi
else
  fail_at "P-1: prepare returned rc=$rc or canonical absent" "canonical=$canonical"
fi

# ─── P-2: body+envelope merge happy path ───────────────────────────────
p2_tmp="$(mktemp -d -t pst-p2.XXXXXX)"
trap 'rm -rf "$p2_tmp"' EXIT
p2_psd="$p2_tmp/project_state/test-slug"
p2_wt="$p2_tmp/worktree"
mkdir -p "$p2_psd/ENG-1" "$p2_wt/docs/plans"
printf '%s\n' "$_valid_body" > "$p2_psd/ENG-1/plan.body.json"
touch "$p2_wt/$_md_relpath"
rc=0; out="$(_run_prepare "$p2_psd" "$p2_wt" \
  --body "$p2_psd/ENG-1/plan.body.json" \
  --md "$_md_relpath" --ident ENG-1 2>/dev/null)" || rc=$?
canonical2="$p2_wt/${_md_relpath%.md}.json"
if (( rc == 0 )) && [[ -f "$canonical2" ]]; then
  if jq -e 'has("features") and has("plan_schema_version") and has("issue_id")' "$canonical2" >/dev/null 2>&1 \
    && [[ "$out" == *"plan-contract-prepared:"* ]]; then
    pass_at "P-2: happy path — rc=0, canonical has all keys, stdout contains plan-contract-prepared"
  else
    fail_at "P-2: canonical missing keys or wrong stdout" "out=$out keys=$(jq -r 'keys' "$canonical2" 2>/dev/null)"
  fi
  rc_v=0; bash "$VALIDATOR" validate "$canonical2" --ident ENG-1 >/dev/null 2>&1 || rc_v=$?
  (( rc_v == 0 )) \
    && pass_at "P-2: validate on merged canonical → rc=0" \
    || fail_at "P-2: validate on merged canonical" "expected rc=0, got rc=$rc_v"
else
  fail_at "P-2: prepare returned rc=$rc or canonical absent" "canonical=$canonical2"
fi

# ─── P-3: body collision — envelope wins ───────────────────────────────
p3_tmp="$(mktemp -d -t pst-p3.XXXXXX)"
trap 'rm -rf "$p3_tmp"' EXIT
p3_psd="$p3_tmp/project_state/test-slug"
p3_wt="$p3_tmp/worktree"
mkdir -p "$p3_psd/ENG-1" "$p3_wt/docs/plans"
printf '{"issue_id":"ENG-99","features":[{"id":"F-1","summary":"x","pass_criteria":[{"kind":"file_exists","path":"x"}]}]}\n' \
  > "$p3_psd/ENG-1/plan.body.json"
touch "$p3_wt/$_md_relpath"
rc=0; _run_prepare "$p3_psd" "$p3_wt" \
  --body "$p3_psd/ENG-1/plan.body.json" \
  --md "$_md_relpath" --ident ENG-1 >/dev/null 2>&1 || rc=$?
canonical3="$p3_wt/${_md_relpath%.md}.json"
if (( rc == 0 )) && [[ -f "$canonical3" ]]; then
  got_iid="$(jq -r '.issue_id' "$canonical3" 2>/dev/null)"
  if [[ "$got_iid" == "ENG-1" ]]; then
    pass_at "P-3: body issue_id ENG-99 overridden by envelope → ENG-1"
  else
    fail_at "P-3: envelope-wins contract" "expected issue_id=ENG-1, got '$got_iid'"
  fi
else
  fail_at "P-3: prepare returned rc=$rc or canonical absent" "canonical=$canonical3"
fi

# ─── P-4: body file missing → rc=35 ───────────────────────────────────
p4_tmp="$(mktemp -d -t pst-p4.XXXXXX)"
trap 'rm -rf "$p4_tmp"' EXIT
p4_psd="$p4_tmp/project_state/test-slug"
p4_wt="$p4_tmp/worktree"
mkdir -p "$p4_psd/ENG-1" "$p4_wt/docs/plans"
touch "$p4_wt/$_md_relpath"
rc=0; _run_prepare "$p4_psd" "$p4_wt" \
  --body "$p4_psd/ENG-1/plan.body.json" \
  --md "$_md_relpath" --ident ENG-1 2>/dev/null || rc=$?
(( rc == 35 )) \
  && pass_at "P-4: body file missing → rc=35" \
  || fail_at "P-4: body missing" "expected rc=35, got rc=$rc"

# ─── P-5: body top-level array → rc=33 ────────────────────────────────
p5_tmp="$(mktemp -d -t pst-p5.XXXXXX)"
trap 'rm -rf "$p5_tmp"' EXIT
p5_psd="$p5_tmp/project_state/test-slug"
p5_wt="$p5_tmp/worktree"
mkdir -p "$p5_psd/ENG-1" "$p5_wt/docs/plans"
printf '[{"features":[]}]\n' > "$p5_psd/ENG-1/plan.body.json"
touch "$p5_wt/$_md_relpath"
rc=0; _run_prepare "$p5_psd" "$p5_wt" \
  --body "$p5_psd/ENG-1/plan.body.json" \
  --md "$_md_relpath" --ident ENG-1 2>/dev/null || rc=$?
(( rc == 33 )) \
  && pass_at "P-5: body top-level array → rc=33" \
  || fail_at "P-5: body array" "expected rc=33, got rc=$rc"

# ─── P-6: body JSON parse error → rc=33 ───────────────────────────────
p6_tmp="$(mktemp -d -t pst-p6.XXXXXX)"
trap 'rm -rf "$p6_tmp"' EXIT
p6_psd="$p6_tmp/project_state/test-slug"
p6_wt="$p6_tmp/worktree"
mkdir -p "$p6_psd/ENG-1" "$p6_wt/docs/plans"
printf 'not-json-{{\n' > "$p6_psd/ENG-1/plan.body.json"
touch "$p6_wt/$_md_relpath"
rc=0; _run_prepare "$p6_psd" "$p6_wt" \
  --body "$p6_psd/ENG-1/plan.body.json" \
  --md "$_md_relpath" --ident ENG-1 2>/dev/null || rc=$?
(( rc == 33 )) \
  && pass_at "P-6: body JSON parse error → rc=33" \
  || fail_at "P-6: body parse error" "expected rc=33, got rc=$rc"

# ─── P-7: body is symlink → rc=33 ─────────────────────────────────────
p7_tmp="$(mktemp -d -t pst-p7.XXXXXX)"
trap 'rm -rf "$p7_tmp"' EXIT
p7_psd="$p7_tmp/project_state/test-slug"
p7_wt="$p7_tmp/worktree"
mkdir -p "$p7_psd/ENG-1" "$p7_wt/docs/plans"
printf '%s\n' "$_valid_body" > "$p7_tmp/real_body.json"
ln -s "$p7_tmp/real_body.json" "$p7_psd/ENG-1/plan.body.json"
touch "$p7_wt/$_md_relpath"
rc=0; _run_prepare "$p7_psd" "$p7_wt" \
  --body "$p7_psd/ENG-1/plan.body.json" \
  --md "$_md_relpath" --ident ENG-1 2>/dev/null || rc=$?
(( rc == 33 )) \
  && pass_at "P-7: body is symlink → rc=33" \
  || fail_at "P-7: body symlink" "expected rc=33, got rc=$rc"

# ─── P-8: body > 64 KiB → rc=33 (size cap) ────────────────────────────
p8_tmp="$(mktemp -d -t pst-p8.XXXXXX)"
trap 'rm -rf "$p8_tmp"' EXIT
p8_psd="$p8_tmp/project_state/test-slug"
p8_wt="$p8_tmp/worktree"
mkdir -p "$p8_psd/ENG-1" "$p8_wt/docs/plans"
# Write > 65536 bytes: prefix + valid JSON structure + padding to exceed 64 KiB.
{
  printf '{"features":[{"id":"F-1","summary":"'
  head -c 65537 /dev/zero | tr '\0' 'x'
  printf '","pass_criteria":[{"kind":"file_exists","path":"x"}]}]}\n'
} > "$p8_psd/ENG-1/plan.body.json"
touch "$p8_wt/$_md_relpath"
rc=0; _run_prepare "$p8_psd" "$p8_wt" \
  --body "$p8_psd/ENG-1/plan.body.json" \
  --md "$_md_relpath" --ident ENG-1 2>/dev/null || rc=$?
(( rc == 33 )) \
  && pass_at "P-8: body > 64 KiB → rc=33 (size cap)" \
  || fail_at "P-8: body oversize" "expected rc=33, got rc=$rc"

# ─── P-9: --ident missing → rc=34 ─────────────────────────────────────
p9_tmp="$(mktemp -d -t pst-p9.XXXXXX)"
trap 'rm -rf "$p9_tmp"' EXIT
p9_psd="$p9_tmp/project_state/test-slug"
p9_wt="$p9_tmp/worktree"
mkdir -p "$p9_psd/ENG-1" "$p9_wt/docs/plans"
printf '%s\n' "$_valid_body" > "$p9_psd/ENG-1/plan.body.json"
touch "$p9_wt/$_md_relpath"
rc=0; _run_prepare "$p9_psd" "$p9_wt" \
  --body "$p9_psd/ENG-1/plan.body.json" \
  --md "$_md_relpath" 2>/dev/null || rc=$?
(( rc == 34 )) \
  && pass_at "P-9: --ident missing → rc=34" \
  || fail_at "P-9: ident missing" "expected rc=34, got rc=$rc"

# ─── P-10: --ident malformed → rc=34 ──────────────────────────────────
p10_tmp="$(mktemp -d -t pst-p10.XXXXXX)"
trap 'rm -rf "$p10_tmp"' EXIT
p10_psd="$p10_tmp/project_state/test-slug"
p10_wt="$p10_tmp/worktree"
mkdir -p "$p10_psd/ENG-1" "$p10_wt/docs/plans"
printf '%s\n' "$_valid_body" > "$p10_psd/ENG-1/plan.body.json"
touch "$p10_wt/$_md_relpath"
for bad_ident in "eng-1" "ENG-" "ENGG-1" "ENG-abc" "1"; do
  rc=0; _run_prepare "$p10_psd" "$p10_wt" \
    --body "$p10_psd/ENG-1/plan.body.json" \
    --md "$_md_relpath" --ident "$bad_ident" 2>/dev/null || rc=$?
  (( rc == 34 )) \
    && pass_at "P-10: --ident '$bad_ident' malformed → rc=34" \
    || fail_at "P-10: ident malformed ($bad_ident)" "expected rc=34, got rc=$rc"
done

# ─── P-11: --md missing → rc=34 ───────────────────────────────────────
p11_tmp="$(mktemp -d -t pst-p11.XXXXXX)"
trap 'rm -rf "$p11_tmp"' EXIT
p11_psd="$p11_tmp/project_state/test-slug"
p11_wt="$p11_tmp/worktree"
mkdir -p "$p11_psd/ENG-1" "$p11_wt/docs/plans"
printf '%s\n' "$_valid_body" > "$p11_psd/ENG-1/plan.body.json"
rc=0; _run_prepare "$p11_psd" "$p11_wt" \
  --body "$p11_psd/ENG-1/plan.body.json" \
  --ident ENG-1 2>/dev/null || rc=$?
(( rc == 34 )) \
  && pass_at "P-11: --md missing → rc=34" \
  || fail_at "P-11: md missing" "expected rc=34, got rc=$rc"

# ─── P-12: --md does not end in .md → rc=33 ───────────────────────────
p12_tmp="$(mktemp -d -t pst-p12.XXXXXX)"
trap 'rm -rf "$p12_tmp"' EXIT
p12_psd="$p12_tmp/project_state/test-slug"
p12_wt="$p12_tmp/worktree"
mkdir -p "$p12_psd/ENG-1" "$p12_wt/docs/plans"
printf '%s\n' "$_valid_body" > "$p12_psd/ENG-1/plan.body.json"
touch "$p12_wt/docs/plans/2026-06-01-eng-1-test.markdown"
rc=0; _run_prepare "$p12_psd" "$p12_wt" \
  --body "$p12_psd/ENG-1/plan.body.json" \
  --md "docs/plans/2026-06-01-eng-1-test.markdown" --ident ENG-1 2>/dev/null || rc=$?
(( rc == 33 )) \
  && pass_at "P-12: --md not .md extension → rc=33" \
  || fail_at "P-12: md no .md ext" "expected rc=33, got rc=$rc"

# ─── P-13: --md is symlink → rc=33 ────────────────────────────────────
p13_tmp="$(mktemp -d -t pst-p13.XXXXXX)"
trap 'rm -rf "$p13_tmp"' EXIT
p13_psd="$p13_tmp/project_state/test-slug"
p13_wt="$p13_tmp/worktree"
mkdir -p "$p13_psd/ENG-1" "$p13_wt/docs/plans"
printf '%s\n' "$_valid_body" > "$p13_psd/ENG-1/plan.body.json"
printf '' > "$p13_tmp/real.md"
ln -s "$p13_tmp/real.md" "$p13_wt/$_md_relpath"
rc=0; _run_prepare "$p13_psd" "$p13_wt" \
  --body "$p13_psd/ENG-1/plan.body.json" \
  --md "$_md_relpath" --ident ENG-1 2>/dev/null || rc=$?
(( rc == 33 )) \
  && pass_at "P-13: --md is symlink → rc=33" \
  || fail_at "P-13: md symlink" "expected rc=33, got rc=$rc"

# ─── P-14: --md resolves outside cwd → rc=33 ──────────────────────────
p14_tmp="$(mktemp -d -t pst-p14.XXXXXX)"
trap 'rm -rf "$p14_tmp"' EXIT
p14_psd="$p14_tmp/project_state/test-slug"
p14_wt="$p14_tmp/worktree"
mkdir -p "$p14_psd/ENG-1" "$p14_wt"
printf '%s\n' "$_valid_body" > "$p14_psd/ENG-1/plan.body.json"
printf '' > "$p14_tmp/outside.md"
rc=0; _run_prepare "$p14_psd" "$p14_wt" \
  --body "$p14_psd/ENG-1/plan.body.json" \
  --md "$p14_tmp/outside.md" --ident ENG-1 2>/dev/null || rc=$?
(( rc == 33 )) \
  && pass_at "P-14: --md outside cwd → rc=33" \
  || fail_at "P-14: md outside cwd" "expected rc=33, got rc=$rc"

# ─── P-15: --body resolves outside PROJECT_STATE_DIR → rc=33 ──────────
p15_tmp="$(mktemp -d -t pst-p15.XXXXXX)"
trap 'rm -rf "$p15_tmp"' EXIT
p15_psd="$p15_tmp/project_state/test-slug"
p15_wt="$p15_tmp/worktree"
mkdir -p "$p15_psd/ENG-1" "$p15_wt/docs/plans"
printf '%s\n' "$_valid_body" > "$p15_tmp/body_outside.json"
touch "$p15_wt/$_md_relpath"
rc=0; _run_prepare "$p15_psd" "$p15_wt" \
  --body "$p15_tmp/body_outside.json" \
  --md "$_md_relpath" --ident ENG-1 2>/dev/null || rc=$?
(( rc == 33 )) \
  && pass_at "P-15: --body outside PROJECT_STATE_DIR → rc=33" \
  || fail_at "P-15: body outside project-state-dir" "expected rc=33, got rc=$rc"

# ─── P-16: canonical destination not writable → rc=33 ─────────────────
p16_tmp="$(mktemp -d -t pst-p16.XXXXXX)"
trap 'rm -rf "$p16_tmp"' EXIT
p16_psd="$p16_tmp/project_state/test-slug"
p16_wt="$p16_tmp/worktree"
mkdir -p "$p16_psd/ENG-1" "$p16_wt/docs/plans"
printf '%s\n' "$_valid_body" > "$p16_psd/ENG-1/plan.body.json"
touch "$p16_wt/$_md_relpath"
chmod 0500 "$p16_wt/docs/plans"
rc=0; _run_prepare "$p16_psd" "$p16_wt" \
  --body "$p16_psd/ENG-1/plan.body.json" \
  --md "$_md_relpath" --ident ENG-1 2>/dev/null || rc=$?
chmod 0755 "$p16_wt/docs/plans"
(( rc == 33 )) \
  && pass_at "P-16: canonical destination not writable → rc=33" \
  || fail_at "P-16: unwritable canonical dir" "expected rc=33, got rc=$rc"

printf '\nplan-schema-test: passed=%d failed=%d\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
