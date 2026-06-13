#!/usr/bin/env bash
# Tests for bin/review-ledger-schema.sh (ENG-190).
#
# Covers T1-T12 (validator unit tests for the per-issue
# review-findings-ledger.jsonl append-only ledger).
#
# Pattern: source-and-stub (CLAUDE.md "How tests work"). Tests invoke
# bin/review-ledger-schema.sh via direct CLI call (matches production
# invocation in run-stage.sh::_validate_review_ledger).

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_DRY_RUN=1
export PIPELINE_DRY_RUN

PASS=0; FAIL=0
pass_at() { PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
fail_at() { FAIL=$((FAIL+1)); printf '  ❌ %s — %s\n' "$1" "$2" >&2; }

FIXTURE_DIR="$(mktemp -d -t review-ledger-schema-test.XXXXXX)"
# review-ledger-schema.sh sources common.sh which requires TARGET_REPO + PROJECT_SLUG.
export TARGET_REPO="$FIXTURE_DIR/target"
mkdir -p "$TARGET_REPO/.pipeline-config"
printf '{"project":{"slug":"test-slug"}}\n' > "$TARGET_REPO/.pipeline-config/config.json"
export PROJECT_SLUG=test-slug
trap 'rm -rf "$FIXTURE_DIR"' EXIT

VALIDATOR="$SCRIPT_DIR/review-ledger-schema.sh"

# Canonical seed-header (must byte-equal _ensure_review_ledger's output).
SEED_LINE_1='# review-findings-ledger — per-issue cumulative ledger; append one JSON object per line.'
SEED_LINE_2='# See docs/runbooks/review-findings-ledger.md. Never truncate; never cleared on dispatch.'

write_seed_header() {
  local file="$1"
  printf '%s\n%s\n' "$SEED_LINE_1" "$SEED_LINE_2" > "$file"
}

write_row() {
  local file="$1" iid="$2" did="$3" iter="$4" key="$5" cold="$6" adj="$7" decision="$8" rationale="$9"
  # Emit one JSON object per line via jq -c (compact).
  jq -cn \
    --argjson lv 1 \
    --arg iid "$iid" \
    --arg did "$did" \
    --argjson iter "$iter" \
    --arg key "$key" \
    --arg cold "$cold" \
    --arg adj "$adj" \
    --arg dec "$decision" \
    --arg rat "$rationale" \
    --arg ts "2026-06-13T00:00:00Z" \
    '{ledger_schema_version:$lv, issue_id:$iid, dispatch_id:$did, iteration:$iter, created_at:$ts, finding_class_key:$key, cold_severity:$cold, adjudicated_severity:$adj, decision:$dec, rationale:$rat}' \
    >> "$file"
}

# ─── Sentinel header check ───────────────────────────────────────────
printf '\n--- review-ledger-schema-test: sentinel + executable ---\n'
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

printf '\n--- review-ledger-schema-test: T1-T12 ---\n'

# ─── T1: well-formed multi-row ledger (3 rows, mixed decisions) → exit 0 ─
f="$FIXTURE_DIR/t1.jsonl"
write_seed_header "$f"
write_row "$f" ENG-1 ENG-1-d0001 1 "correctness:auth.rs:duplicate-key" major major carry "first iteration"
write_row "$f" ENG-1 ENG-1-d0002 2 "correctness:auth.rs:duplicate-key" major major stabilise "no change"
write_row "$f" ENG-1 ENG-1-d0002 2 "testing:auth-test.rs:missing-case" minor minor carry "new class"
rc=0; bash "$VALIDATOR" validate "$f" --ident ENG-1 --dispatch-id ENG-1-d0002 >/dev/null 2>&1 || rc=$?
(( rc == 0 )) \
  && pass_at "T1: well-formed multi-row ledger → exit 0" \
  || fail_at "T1: well-formed multi-row ledger" "expected rc=0, got rc=$rc"

# ─── T2: JSON parse error on row N → exit 48 ─────────────────────────
f="$FIXTURE_DIR/t2.jsonl"
write_seed_header "$f"
write_row "$f" ENG-1 ENG-1-d0001 1 "k1" major major carry "ok"
printf '{not valid json}\n' >> "$f"
rc=0; out="$(bash "$VALIDATOR" validate "$f" --ident ENG-1 2>&1)" || rc=$?
(( rc == 48 )) \
  && pass_at "T2: JSON parse error → exit 48" \
  || fail_at "T2: JSON parse error" "expected rc=48, got rc=$rc"
if [[ "$out" == *"row 4"* ]] || [[ "$out" == *"row "* ]]; then
  pass_at "T2: diagnostic names a row number"
else
  fail_at "T2: diagnostic row number" "expected 'row N' in diagnostic; got: $out"
fi

# ─── T3: missing required field per row → exit 49 ────────────────────
f="$FIXTURE_DIR/t3.jsonl"
write_seed_header "$f"
# Missing 'decision' field.
jq -cn '{ledger_schema_version:1, issue_id:"ENG-1", dispatch_id:"ENG-1-d0001", iteration:1, created_at:"2026-06-13T00:00:00Z", finding_class_key:"k1", cold_severity:"major", adjudicated_severity:"major", rationale:"r"}' >> "$f"
rc=0; bash "$VALIDATOR" validate "$f" --ident ENG-1 >/dev/null 2>&1 || rc=$?
(( rc == 49 )) \
  && pass_at "T3: missing required field 'decision' → exit 49" \
  || fail_at "T3: missing required field" "expected rc=49, got rc=$rc"

# ─── T4: missing file → exit 50 ──────────────────────────────────────
rc=0; bash "$VALIDATOR" validate "$FIXTURE_DIR/nonexistent.jsonl" >/dev/null 2>&1 || rc=$?
(( rc == 50 )) \
  && pass_at "T4: missing file → exit 50" \
  || fail_at "T4: missing file" "expected rc=50, got rc=$rc"

# ─── T5: --ident mismatch on any row → exit 49 ───────────────────────
f="$FIXTURE_DIR/t5.jsonl"
write_seed_header "$f"
write_row "$f" ENG-999 ENG-999-d0001 1 "k1" major major carry "ok"
rc=0; bash "$VALIDATOR" validate "$f" --ident ENG-1 >/dev/null 2>&1 || rc=$?
(( rc == 49 )) \
  && pass_at "T5: --ident mismatch → exit 49" \
  || fail_at "T5: --ident mismatch" "expected rc=49, got rc=$rc"

# ─── T6: severity-ladder violation (adjudicated > cold) → exit 49 ────
f="$FIXTURE_DIR/t6.jsonl"
write_seed_header "$f"
# cold=minor (2), adjudicated=major (3): forbidden escalation.
write_row "$f" ENG-1 ENG-1-d0001 1 "k1" minor major carry "escalating, forbidden"
rc=0; out="$(bash "$VALIDATOR" validate "$f" --ident ENG-1 2>&1)" || rc=$?
(( rc == 49 )) \
  && pass_at "T6: severity-ladder violation → exit 49" \
  || fail_at "T6: severity-ladder violation" "expected rc=49, got rc=$rc"
if [[ "$out" == *"severity-ladder"* ]]; then
  pass_at "T6: diagnostic mentions severity-ladder"
else
  fail_at "T6: diagnostic" "expected 'severity-ladder' in diagnostic; got: $out"
fi

# ─── T7: critical-floor violation (cold=critical, decision=stabilise, adj=minor) → exit 49 ─
f="$FIXTURE_DIR/t7.jsonl"
write_seed_header "$f"
write_row "$f" ENG-1 ENG-1-d0001 1 "k1" critical minor stabilise "downgrade forbidden"
rc=0; out="$(bash "$VALIDATOR" validate "$f" --ident ENG-1 2>&1)" || rc=$?
(( rc == 49 )) \
  && pass_at "T7: critical-floor violation → exit 49" \
  || fail_at "T7: critical-floor violation" "expected rc=49, got rc=$rc"
if [[ "$out" == *"critical-floor"* ]]; then
  pass_at "T7: diagnostic mentions critical-floor"
else
  fail_at "T7: diagnostic" "expected 'critical-floor' in diagnostic; got: $out"
fi

# ─── T8: empty-after-header-strip → exit 0 (first-reviewing-dispatch shape) ─
f="$FIXTURE_DIR/t8.jsonl"
write_seed_header "$f"
rc=0; bash "$VALIDATOR" validate "$f" --ident ENG-1 >/dev/null 2>&1 || rc=$?
(( rc == 0 )) \
  && pass_at "T8: empty-after-header-strip → exit 0" \
  || fail_at "T8: empty-after-header-strip" "expected rc=0, got rc=$rc"

# ─── T9: --dispatch-id flag empty → fail-open, rc=0 ──────────────────
f="$FIXTURE_DIR/t9.jsonl"
write_seed_header "$f"
write_row "$f" ENG-1 ENG-1-d0099 1 "k1" major major carry "ok"
rc=0; bash "$VALIDATOR" validate "$f" --ident ENG-1 --dispatch-id '' >/dev/null 2>&1 || rc=$?
(( rc == 0 )) \
  && pass_at "T9: --dispatch-id empty → fail-open, rc=0" \
  || fail_at "T9: --dispatch-id empty" "expected rc=0 (fail-open), got rc=$rc"

# ─── T10: seed-header byte-mismatch → exit 49 ────────────────────────
f="$FIXTURE_DIR/t10.jsonl"
printf '# tampered header line 1\n# tampered header line 2\n' > "$f"
write_row "$f" ENG-1 ENG-1-d0001 1 "k1" major major carry "ok"
rc=0; out="$(bash "$VALIDATOR" validate "$f" --ident ENG-1 2>&1)" || rc=$?
(( rc == 49 )) \
  && pass_at "T10: seed-header tampered → exit 49" \
  || fail_at "T10: seed-header tampered" "expected rc=49, got rc=$rc"
if [[ "$out" == *"seed-header"* ]]; then
  pass_at "T10: diagnostic mentions seed-header"
else
  fail_at "T10: diagnostic" "expected 'seed-header' in diagnostic; got: $out"
fi

# ─── T11: unknown per-row field → warns + returns 0 ──────────────────
f="$FIXTURE_DIR/t11.jsonl"
write_seed_header "$f"
jq -cn '{ledger_schema_version:1, issue_id:"ENG-1", dispatch_id:"ENG-1-d0001", iteration:1, created_at:"2026-06-13T00:00:00Z", finding_class_key:"k1", cold_severity:"major", adjudicated_severity:"major", decision:"carry", rationale:"r", future_field:"x"}' >> "$f"
rc=0
stdout_out="$(bash "$VALIDATOR" validate "$f" --ident ENG-1 2>/dev/null)" || rc=$?
stderr_out="$(bash "$VALIDATOR" validate "$f" --ident ENG-1 2>&1 >/dev/null)" || true
(( rc == 0 )) \
  && pass_at "T11: unknown field → exit 0" \
  || fail_at "T11: unknown field exit code" "expected rc=0, got rc=$rc"
if [[ "$stderr_out" == *"warning"* ]] && [[ "$stderr_out" == *"future_field"* ]]; then
  pass_at "T11: unknown field stderr contains warning + field name"
else
  fail_at "T11: unknown field warning" "stderr should contain warning + future_field; got: $stderr_out"
fi

# ─── T12: dispatch_id malformed (ENG-1-dABC) → exit 49 ───────────────
f="$FIXTURE_DIR/t12.jsonl"
write_seed_header "$f"
write_row "$f" ENG-1 ENG-1-dABC 1 "k1" major major carry "ok"
rc=0; bash "$VALIDATOR" validate "$f" --ident ENG-1 >/dev/null 2>&1 || rc=$?
(( rc == 49 )) \
  && pass_at "T12: dispatch_id malformed → exit 49" \
  || fail_at "T12: dispatch_id malformed" "expected rc=49, got rc=$rc"

# ─── Diagnostic must append finding_class_key when parseable ──────────
# Plan Task 2 line 182 mandate: downstream-check diagnostic appends
# ` finding_class_key=<sanitised>`. JSON parse errors do NOT append it.
f="$FIXTURE_DIR/t-diag.jsonl"
write_seed_header "$f"
write_row "$f" ENG-1 ENG-1-d0001 1 "correctness:foo.rs:bar" critical minor stabilise "downgrade forbidden"
rc=0; out="$(bash "$VALIDATOR" validate "$f" --ident ENG-1 2>&1)" || rc=$?
if [[ "$out" == *"finding_class_key=correctness:foo.rs:bar"* ]]; then
  pass_at "T-diag: critical-floor diag appends finding_class_key=<sanitised>"
else
  fail_at "T-diag: finding_class_key in diagnostic" "expected finding_class_key=... in diag; got: $out"
fi

printf '\nreview-ledger-schema-test: passed=%d failed=%d\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
