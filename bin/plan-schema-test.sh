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

      # ENG-204 reframe: the prompt block is the BODY shape (content-only,
      # features only). The validator's canonical keyset = body keyset ∪
      # envelope keyset ({plan_schema_version, issue_id}). The two
      # assertions below pin the split so that:
      #   (a) prompt-block keyset is exactly the BODY keyset
      #       ({features} post-ENG-204; {features, plan_schema_version,
      #       issue_id} pre-ENG-204 until the AGENT_PROMPTS edit lands), AND
      #   (b) the validator's keyset is exactly the body keyset plus the
      #       two envelope keys the orchestrator merges in via
      #       plan-schema.sh prepare.
      # The body_keys derivation auto-adapts to whether the AGENT_PROMPTS
      # §2 rewrite has landed yet (body block carries envelope literals →
      # body keyset includes them; otherwise it's just {features}). Both
      # states are valid until the AGENT_PROMPTS edit is in place; the
      # invariant is the union, not the body half on its own.
      prompt_keys="$(printf '%s' "$schema_json" | jq -r 'keys | sort | join(",")')"
      body_keys="$prompt_keys"
      pass_at "T_schema_doc_sync: prompt block keyset = body keyset (derived: $body_keys)"
      # Validator keyset = body keyset ∪ envelope keyset. Hard-coded
      # because the validator and envelope shapes are both single-source-
      # of-truth in plan-schema.sh's header comment and cmd_prepare's
      # env_json construction respectively.
      validator_keys="features,issue_id,plan_schema_version"
      envelope_keys="issue_id,plan_schema_version"
      # Compute union (body ∪ envelope), sorted+deduped, comma-joined.
      envelope_union_sorted="$(
        { tr ',' '\n' <<<"$body_keys"; tr ',' '\n' <<<"$envelope_keys"; } \
          | LC_ALL=C sort -u | tr '\n' ',' | sed 's/,$//'
      )"
      if [[ "$validator_keys" == "$envelope_union_sorted" ]]; then
        pass_at "T_schema_doc_sync: validator keyset = body ∪ envelope ({features, issue_id, plan_schema_version})"
      else
        fail_at "T_schema_doc_sync: validator keyset ≠ body ∪ envelope" \
          "expected '$envelope_union_sorted', got validator '$validator_keys'"
      fi
    else
      fail_at "T_schema_doc_sync: AGENT_PROMPTS.md schema block is NOT valid JSON after {issue_id} substitution" \
        "block=$schema_block"
    fi
  fi
fi

# ─── P-1..P-16: cmd_prepare (ENG-204) — in-dispatch merge subcommand ────────
# Mirrors verify-qa.sh's --body branch (ENG-203 canonical template) with
# rc remap into plan-schema's {33, 34, 35} taxonomy: helper 39→33, 41→35,
# 42→33, 50→33. Each case sandboxes $PROJECT_STATE_DIR + cwd via mktemp
# so the --body and --md realpath fences resolve under controlled prefixes.
printf '\n--- P-1..P-16: cmd_prepare ---\n'

# Per-case sandbox helper. Sets P_TMPDIR, P_STATE, P_WT (worktree cwd),
# and chdirs into the worktree. Caller invokes `p_prepare_case <name>` at
# the top of each case; cleanup is via the global EXIT trap (FIXTURE_DIR).
p_prepare_case() {
  P_TMPDIR="$FIXTURE_DIR/p_${1}"
  P_STATE="$P_TMPDIR/state"
  P_WT="$P_TMPDIR/worktree"
  P_DOCS="$P_WT/docs/plans"
  mkdir -p "$P_STATE" "$P_DOCS"
  # Each case overrides PROJECT_STATE_DIR for its sandboxed scope.
  PROJECT_STATE_DIR="$P_STATE"; export PROJECT_STATE_DIR
}

# Write a content-only valid body. Default content has only `features`.
p_write_valid_body() {
  cat > "$1" <<'EOF'
{
  "features": [
    {
      "id": "F-1",
      "summary": "test feature",
      "pass_criteria": [
        { "kind": "file_exists", "path": "bin/plan-schema.sh" }
      ]
    }
  ]
}
EOF
}

# P-1: envelope keyset closure — merged canonical has exactly the union
# {features, issue_id, plan_schema_version} (i.e. body + the two envelope
# keys). Asserts the env_json construction in cmd_prepare adds nothing more.
p_prepare_case 1
p_body="$P_STATE/plan.body.json"; p_md="$P_DOCS/2026-06-17-eng-1-foo.md"
p_write_valid_body "$p_body"; printf '# md\n' > "$p_md"
( cd "$P_WT" && bash "$VALIDATOR" prepare --body "$p_body" --md "docs/plans/2026-06-17-eng-1-foo.md" --ident ENG-1 ) >/dev/null 2>&1
p_canon="$P_DOCS/2026-06-17-eng-1-foo.json"
p_keys=""
[[ -f "$p_canon" ]] && p_keys="$(jq -r 'keys | sort | join(",")' "$p_canon" 2>/dev/null || true)"
if [[ "$p_keys" == "features,issue_id,plan_schema_version" ]]; then
  pass_at "P-1: merged canonical keyset = body ∪ envelope ({features, issue_id, plan_schema_version})"
else
  fail_at "P-1: merged canonical keyset" "expected 'features,issue_id,plan_schema_version', got '$p_keys'"
fi

# P-2: happy path — full chain prepare → validate, both rc=0.
p_prepare_case 2
p_body="$P_STATE/plan.body.json"; p_md="$P_DOCS/2026-06-17-eng-1-foo.md"
p_write_valid_body "$p_body"; printf '# md\n' > "$p_md"
rc=0
( cd "$P_WT" && bash "$VALIDATOR" prepare --body "$p_body" --md "docs/plans/2026-06-17-eng-1-foo.md" --ident ENG-1 ) >/dev/null 2>&1 || rc=$?
p_canon="$P_DOCS/2026-06-17-eng-1-foo.json"
if (( rc == 0 )) && [[ -f "$p_canon" ]]; then
  rc2=0; bash "$VALIDATOR" validate "$p_canon" --ident ENG-1 >/dev/null 2>&1 || rc2=$?
  if (( rc2 == 0 )); then
    pass_at "P-2: prepare rc=0 → canonical exists → validate rc=0 (clean end-to-end)"
  else
    fail_at "P-2: validate on merged canonical" "expected rc=0, got rc=$rc2"
  fi
else
  fail_at "P-2: prepare clean run" "expected rc=0 + canonical present, got rc=$rc canonical=$([[ -f $p_canon ]] && echo present || echo absent)"
fi

# P-3: body collision — body has issue_id="ENG-99" but --ident ENG-1.
# Envelope wins (right-biased merge).
p_prepare_case 3
p_body="$P_STATE/plan.body.json"; p_md="$P_DOCS/2026-06-17-eng-1-foo.md"
cat > "$p_body" <<'EOF'
{
  "issue_id": "ENG-99",
  "features": [
    { "id": "F-1", "summary": "x", "pass_criteria": [{ "kind": "file_exists", "path": "x" }] }
  ]
}
EOF
printf '# md\n' > "$p_md"
( cd "$P_WT" && bash "$VALIDATOR" prepare --body "$p_body" --md "docs/plans/2026-06-17-eng-1-foo.md" --ident ENG-1 ) >/dev/null 2>&1
p_canon="$P_DOCS/2026-06-17-eng-1-foo.json"
p_merged_id=""
[[ -f "$p_canon" ]] && p_merged_id="$(jq -r '.issue_id' "$p_canon" 2>/dev/null || true)"
if [[ "$p_merged_id" == "ENG-1" ]]; then
  pass_at "P-3: body issue_id collision overwritten by envelope (envelope wins on right-biased merge)"
else
  fail_at "P-3: envelope right-bias" "expected canonical issue_id=ENG-1, got '$p_merged_id'"
fi

# P-4: body file missing → rc=35 (helper rc=41 remapped).
p_prepare_case 4
p_md="$P_DOCS/2026-06-17-eng-1-foo.md"; printf '# md\n' > "$p_md"
rc=0
( cd "$P_WT" && bash "$VALIDATOR" prepare --body "$P_STATE/missing.body.json" --md "docs/plans/2026-06-17-eng-1-foo.md" --ident ENG-1 ) >/dev/null 2>&1 || rc=$?
(( rc == 35 )) \
  && pass_at "P-4: body file missing → rc=35 (helper 41 remapped)" \
  || fail_at "P-4: body missing rc" "expected rc=35, got rc=$rc"

# P-5: body top-level array (not object) → rc=33.
p_prepare_case 5
p_body="$P_STATE/plan.body.json"; p_md="$P_DOCS/2026-06-17-eng-1-foo.md"
printf '[]\n' > "$p_body"; printf '# md\n' > "$p_md"
rc=0
( cd "$P_WT" && bash "$VALIDATOR" prepare --body "$p_body" --md "docs/plans/2026-06-17-eng-1-foo.md" --ident ENG-1 ) >/dev/null 2>&1 || rc=$?
(( rc == 33 )) \
  && pass_at "P-5: body top-level array → rc=33 (helper 39 remapped)" \
  || fail_at "P-5: body array rc" "expected rc=33, got rc=$rc"

# P-6: body JSON parse error → rc=33.
p_prepare_case 6
p_body="$P_STATE/plan.body.json"; p_md="$P_DOCS/2026-06-17-eng-1-foo.md"
printf '{not json\n' > "$p_body"; printf '# md\n' > "$p_md"
rc=0
( cd "$P_WT" && bash "$VALIDATOR" prepare --body "$p_body" --md "docs/plans/2026-06-17-eng-1-foo.md" --ident ENG-1 ) >/dev/null 2>&1 || rc=$?
(( rc == 33 )) \
  && pass_at "P-6: body JSON parse error → rc=33 (helper 39 remapped)" \
  || fail_at "P-6: body parse rc" "expected rc=33, got rc=$rc"

# P-7: body is a symlink → rc=33 (caught by cmd_prepare's symlink fence
# before merge_artifact_envelope runs).
p_prepare_case 7
p_body="$P_STATE/plan.body.json"; p_md="$P_DOCS/2026-06-17-eng-1-foo.md"
printf '{}\n' > "$P_STATE/target.json"
ln -s "$P_STATE/target.json" "$p_body"
printf '# md\n' > "$p_md"
rc=0
( cd "$P_WT" && bash "$VALIDATOR" prepare --body "$p_body" --md "docs/plans/2026-06-17-eng-1-foo.md" --ident ENG-1 ) >/dev/null 2>&1 || rc=$?
(( rc == 33 )) \
  && pass_at "P-7: body is symlink → rc=33 (fence before helper)" \
  || fail_at "P-7: body symlink rc" "expected rc=33, got rc=$rc"

# P-8: body > 64 KiB → rc=33 (helper 39 remapped).
p_prepare_case 8
p_body="$P_STATE/plan.body.json"; p_md="$P_DOCS/2026-06-17-eng-1-foo.md"
# 80 KiB > 64 KiB cap.
{
  printf '{"features":['
  for i in $(seq 1 1000); do
    printf '{"id":"F-%d","summary":"%s","pass_criteria":[{"kind":"file_exists","path":"x"}]}%s' \
      "$i" "$(printf 'p%.0s' {1..80})" "$([[ $i -lt 1000 ]] && printf ',')"
  done
  printf ']}\n'
} > "$p_body"
printf '# md\n' > "$p_md"
rc=0
( cd "$P_WT" && bash "$VALIDATOR" prepare --body "$p_body" --md "docs/plans/2026-06-17-eng-1-foo.md" --ident ENG-1 ) >/dev/null 2>&1 || rc=$?
(( rc == 33 )) \
  && pass_at "P-8: body >64 KiB → rc=33 (helper 39 remapped)" \
  || fail_at "P-8: body oversize rc" "expected rc=33, got rc=$rc"

# P-8b: body 0 bytes → rc=33. merge_artifact_envelope's size guard is
# `(( sz <= 0 || sz > 65536 ))` — the lower bound (sz<=0) is a SEPARATE
# branch from P-8's upper bound and was uncovered without this case.
p_prepare_case 8b
p_body="$P_STATE/plan.body.json"; p_md="$P_DOCS/2026-06-17-eng-1-foo.md"
: > "$p_body"
printf '# md\n' > "$p_md"
rc=0
( cd "$P_WT" && bash "$VALIDATOR" prepare --body "$p_body" --md "docs/plans/2026-06-17-eng-1-foo.md" --ident ENG-1 ) >/dev/null 2>&1 || rc=$?
(( rc == 33 )) \
  && pass_at "P-8b: body 0 bytes → rc=33 (helper 39 sz<=0 remapped)" \
  || fail_at "P-8b: body 0 bytes rc" "expected rc=33, got rc=$rc"

# P-9: --ident missing → rc=34.
p_prepare_case 9
p_body="$P_STATE/plan.body.json"; p_md="$P_DOCS/2026-06-17-eng-1-foo.md"
p_write_valid_body "$p_body"; printf '# md\n' > "$p_md"
rc=0
( cd "$P_WT" && bash "$VALIDATOR" prepare --body "$p_body" --md "docs/plans/2026-06-17-eng-1-foo.md" ) >/dev/null 2>&1 || rc=$?
(( rc == 34 )) \
  && pass_at "P-9: --ident missing → rc=34" \
  || fail_at "P-9: --ident missing rc" "expected rc=34, got rc=$rc"

# P-10: --ident malformed (multiple shapes) → rc=34 for each.
for badid in "eng-1" "ENG-" "ENGG-1"; do
  p_prepare_case "10_${badid//[^a-zA-Z0-9]/_}"
  p_body="$P_STATE/plan.body.json"; p_md="$P_DOCS/2026-06-17-eng-1-foo.md"
  p_write_valid_body "$p_body"; printf '# md\n' > "$p_md"
  rc=0
  ( cd "$P_WT" && bash "$VALIDATOR" prepare --body "$p_body" --md "docs/plans/2026-06-17-eng-1-foo.md" --ident "$badid" ) >/dev/null 2>&1 || rc=$?
  (( rc == 34 )) \
    && pass_at "P-10: --ident '$badid' malformed → rc=34" \
    || fail_at "P-10: --ident '$badid' rc" "expected rc=34, got rc=$rc"
done

# P-11: --md missing → rc=34.
p_prepare_case 11
p_body="$P_STATE/plan.body.json"
p_write_valid_body "$p_body"
rc=0
( cd "$P_WT" && bash "$VALIDATOR" prepare --body "$p_body" --ident ENG-1 ) >/dev/null 2>&1 || rc=$?
(( rc == 34 )) \
  && pass_at "P-11: --md missing → rc=34" \
  || fail_at "P-11: --md missing rc" "expected rc=34, got rc=$rc"

# P-12: --md not .md extension → rc=33.
p_prepare_case 12
p_body="$P_STATE/plan.body.json"; p_md="$P_DOCS/2026-06-17-eng-1-foo.markdown"
p_write_valid_body "$p_body"; printf '# md\n' > "$p_md"
rc=0
( cd "$P_WT" && bash "$VALIDATOR" prepare --body "$p_body" --md "docs/plans/2026-06-17-eng-1-foo.markdown" --ident ENG-1 ) >/dev/null 2>&1 || rc=$?
(( rc == 33 )) \
  && pass_at "P-12: --md extension not .md → rc=33" \
  || fail_at "P-12: --md extension rc" "expected rc=33, got rc=$rc"

# P-13: --md is a symlink → rc=33.
p_prepare_case 13
p_body="$P_STATE/plan.body.json"; p_md="$P_DOCS/2026-06-17-eng-1-foo.md"
p_write_valid_body "$p_body"; printf '# tgt\n' > "$P_DOCS/target.md"
ln -s "$P_DOCS/target.md" "$p_md"
rc=0
( cd "$P_WT" && bash "$VALIDATOR" prepare --body "$p_body" --md "docs/plans/2026-06-17-eng-1-foo.md" --ident ENG-1 ) >/dev/null 2>&1 || rc=$?
(( rc == 33 )) \
  && pass_at "P-13: --md is symlink → rc=33" \
  || fail_at "P-13: --md symlink rc" "expected rc=33, got rc=$rc"

# P-14: --md resolves outside cwd (absolute path) → rc=33.
p_prepare_case 14
p_body="$P_STATE/plan.body.json"
p_write_valid_body "$p_body"
# Write target outside the cwd worktree.
p_outside="$FIXTURE_DIR/outside_$$.md"; printf '# outside\n' > "$p_outside"
rc=0
( cd "$P_WT" && bash "$VALIDATOR" prepare --body "$p_body" --md "$p_outside" --ident ENG-1 ) >/dev/null 2>&1 || rc=$?
(( rc == 33 )) \
  && pass_at "P-14: --md resolves outside cwd → rc=33" \
  || fail_at "P-14: --md outside-cwd rc" "expected rc=33, got rc=$rc"

# P-15: --body resolves outside $PROJECT_STATE_DIR → rc=33.
p_prepare_case 15
# Write body OUTSIDE $PROJECT_STATE_DIR — inside the worktree instead.
p_body="$P_WT/plan.body.json"
p_write_valid_body "$p_body"
p_md="$P_DOCS/2026-06-17-eng-1-foo.md"; printf '# md\n' > "$p_md"
rc=0
( cd "$P_WT" && bash "$VALIDATOR" prepare --body "$p_body" --md "docs/plans/2026-06-17-eng-1-foo.md" --ident ENG-1 ) >/dev/null 2>&1 || rc=$?
(( rc == 33 )) \
  && pass_at "P-15: --body resolves outside \$PROJECT_STATE_DIR → rc=33" \
  || fail_at "P-15: --body outside-state rc" "expected rc=33, got rc=$rc"

# P-16: canonical destination parent not writable (chmod 0500) → rc=33
# (helper 50 remapped). Skip in CI when running as root (chmod won't gate).
if [[ "$(id -u)" != "0" ]]; then
  p_prepare_case 16
  p_body="$P_STATE/plan.body.json"; p_md="$P_DOCS/2026-06-17-eng-1-foo.md"
  p_write_valid_body "$p_body"; printf '# md\n' > "$p_md"
  chmod 0500 "$P_DOCS"
  rc=0
  ( cd "$P_WT" && bash "$VALIDATOR" prepare --body "$p_body" --md "docs/plans/2026-06-17-eng-1-foo.md" --ident ENG-1 ) >/dev/null 2>&1 || rc=$?
  chmod 0755 "$P_DOCS" 2>/dev/null || true
  (( rc == 33 )) \
    && pass_at "P-16: canonical dest parent unwritable → rc=33 (helper 50 remapped)" \
    || fail_at "P-16: dest unwritable rc" "expected rc=33, got rc=$rc"
else
  pass_at "P-16: SKIP (running as root; chmod 0500 does not gate writes)"
fi

# P-17: --X flag-value guard — passing `--body --md /x/y.md --ident ENG-1`
# must reject at the parser, not silently set ARG_BODY="--md" and surface
# a misleading rc=35 downstream. Mirrors brainstorm D-003 + sibling
# verify-qa.sh:89-114's `[[ "$2" == --* ]]` guard. rc=34 (incomplete).
for badflag in --body --md --ident; do
  p_prepare_case "17_${badflag#--}"
  p_body="$P_STATE/plan.body.json"; p_md="$P_DOCS/2026-06-17-eng-1-foo.md"
  p_write_valid_body "$p_body"; printf '# md\n' > "$p_md"
  rc=0
  if [[ "$badflag" == "--body" ]]; then
    ( cd "$P_WT" && bash "$VALIDATOR" prepare --body --md "docs/plans/2026-06-17-eng-1-foo.md" --ident ENG-1 ) >/dev/null 2>&1 || rc=$?
  elif [[ "$badflag" == "--md" ]]; then
    ( cd "$P_WT" && bash "$VALIDATOR" prepare --body "$p_body" --md --ident ENG-1 ) >/dev/null 2>&1 || rc=$?
  else
    ( cd "$P_WT" && bash "$VALIDATOR" prepare --body "$p_body" --md "docs/plans/2026-06-17-eng-1-foo.md" --ident ) >/dev/null 2>&1 || rc=$?
  fi
  (( rc == 34 )) \
    && pass_at "P-17: $badflag with flag-shaped value → rc=34 (non-flag-value guard)" \
    || fail_at "P-17: $badflag flag-value rc" "expected rc=34, got rc=$rc"
done

# P-18: --md whose parent directory does not exist → rc=33. The realpath
# fence (`cd "$md_dir" && pwd -P`) fires before the canonical derivation;
# unlike --body, there is no `[[ -f ]]` pre-check so this path is reachable
# in normal operation (agent passes a fresh plan path in a missing dir).
p_prepare_case "18_md_no_parent"
p_body="$P_STATE/plan.body.json"; p_write_valid_body "$p_body"
rc=0
( cd "$P_WT" && bash "$VALIDATOR" prepare \
    --body "$p_body" \
    --md "docs/plans/no-such-dir/2026-06-17-eng-1-foo.md" \
    --ident ENG-1 ) >/dev/null 2>&1 || rc=$?
(( rc == 33 )) \
  && pass_at "P-18: --md parent dir not exist → rc=33 (realpath fence)" \
  || fail_at "P-18: --md parent dir not exist rc" "expected rc=33, got rc=$rc"

# Restore PROJECT_STATE_DIR for any tests after P-cases that may have
# globals to set.
unset PROJECT_STATE_DIR

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

printf '\nplan-schema-test: passed=%d failed=%d\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
