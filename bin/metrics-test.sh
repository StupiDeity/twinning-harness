#!/usr/bin/env bash
# Test harness for bin/metrics.sh's flag-pair parser (ENG-26 Task 1, brainstorm D-004).
#
# Each case shells out `bash bin/metrics.sh stage-end …` against an isolated
# PROJECT_STATE_DIR/metrics/events.jsonl. The append-only file must end with
# exactly one new JSONL record per call; assertions inspect that record.
#
# CLAUDE.md "How tests work" pattern:
#   - PIPELINE_DRY_RUN=1 (metrics.sh ignores this — it runs in dry-run too —
#     but the convention keeps the env consistent with sibling tests).
#   - LINEAR_API_KEY=test-mock-key (defensive; metrics.sh does not call Linear).
#   - STUB_DIR + override of PROJECT_STATE_DIR after sourcing common.sh.

set -euo pipefail
HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export PIPELINE_DRY_RUN=1
export PROJECT_SLUG="${PROJECT_SLUG:-test-slug}"
: "${LINEAR_API_KEY:=test-mock-key}"
export LINEAR_API_KEY
export TARGET_REPO="${TARGET_REPO:-$(cd "$HARNESS_DIR/.." && pwd)}"

STUB_DIR="$(mktemp -d)"
HARNESS_STATE_DIR="$(mktemp -d)"
PROJECT_STATE_DIR="${HARNESS_STATE_DIR}/${PROJECT_SLUG}"
JSONL="${PROJECT_STATE_DIR}/metrics/events.jsonl"
mkdir -p "$(dirname "$JSONL")"
export HARNESS_STATE_DIR PROJECT_STATE_DIR
trap 'rm -rf "$HARNESS_STATE_DIR" "$STUB_DIR"' EXIT

PASS=0; FAIL=0
pass_at() { printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); }
fail_at() { printf '  ❌ %s\n     %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

# Reset events.jsonl before every case so the last-line read is unambiguous.
reset_jsonl() { : > "$JSONL"; }
last_line() { tail -n 1 "$JSONL"; }
line_count() { wc -l < "$JSONL" | tr -d ' '; }

run_metrics() {
  HARNESS_STATE_DIR="$HARNESS_STATE_DIR" \
  PROJECT_STATE_DIR="$PROJECT_STATE_DIR" \
  PROJECT_SLUG="$PROJECT_SLUG" \
  TARGET_REPO="$TARGET_REPO" \
  LINEAR_API_KEY="$LINEAR_API_KEY" \
  PIPELINE_DRY_RUN=1 \
  bash "$HARNESS_DIR/metrics.sh" "$@"
}

# ─── Case A: no flags → 7-key legacy line ──────────────────────────────────
reset_jsonl
run_metrics stage-end ENG-T1 plan success 100 "branch=foo"
line="$(last_line)"
keys="$(jq -r 'keys | length' <<<"$line")"
notes="$(jq -r '.notes' <<<"$line")"
if [[ "$keys" == "7" ]] \
   && [[ "$notes" == "branch=foo" ]] \
   && [[ "$(jq -r 'has("tokens_in")' <<<"$line")" == "false" ]] \
   && [[ "$(jq -r 'has("cost_usd")'  <<<"$line")" == "false" ]] \
   && [[ "$(jq -r 'has("model")'     <<<"$line")" == "false" ]]; then
  pass_at "case-A no flags: 7-key line; notes preserved; cost fields absent"
else
  fail_at "case-A no flags" "keys=$keys notes=$notes line=$line"
fi

# ─── Case B: all six flags + notes → 13-key line ───────────────────────────
# The model literal `claude-opus-4-7[1m]` must round-trip with [1m] intact
# (DL-202 / SEC-007: glob-char preservation).
reset_jsonl
run_metrics stage-end ENG-T2 plan success 100 "branch=foo" \
  --tokens-in 5 --tokens-out 6 \
  --cache-read 20773 --cache-create 17419 \
  --cost-usd 0.119 --model "claude-opus-4-7[1m]"
line="$(last_line)"
keys="$(jq -r 'keys | length' <<<"$line")"
ti="$(jq -r '.tokens_in' <<<"$line")"
co="$(jq -r '.cost_usd' <<<"$line")"
mo="$(jq -r '.model' <<<"$line")"
ti_t="$(jq -r '.tokens_in | type' <<<"$line")"
co_t="$(jq -r '.cost_usd | type' <<<"$line")"
if [[ "$keys" == "13" ]] \
   && [[ "$ti" == "5" ]] \
   && [[ "$co" == "0.119" ]] \
   && [[ "$mo" == "claude-opus-4-7[1m]" ]] \
   && [[ "$ti_t" == "number" ]] \
   && [[ "$co_t" == "number" ]]; then
  pass_at "case-B all six flags: 13 keys, numeric types, model literal preserved"
else
  fail_at "case-B all six flags" "keys=$keys tokens_in=$ti(type=$ti_t) cost_usd=$co(type=$co_t) model=$mo line=$line"
fi

# ─── Case C: flags interleaved before notes ────────────────────────────────
reset_jsonl
run_metrics stage-end ENG-T3 plan success 100 \
  --cost-usd 0.42 --tokens-in 500 "branch=foo"
line="$(last_line)"
notes="$(jq -r '.notes' <<<"$line")"
co="$(jq -r '.cost_usd' <<<"$line")"
ti="$(jq -r '.tokens_in' <<<"$line")"
if [[ "$notes" == "branch=foo" ]] \
   && [[ "$co" == "0.42" ]] \
   && [[ "$ti" == "500" ]]; then
  pass_at "case-C flags-before-notes: notes='branch=foo', cost_usd=0.42, tokens_in=500"
else
  fail_at "case-C flags-before-notes" "notes=$notes cost_usd=$co tokens_in=$ti line=$line"
fi

# ─── Case D: legacy stage-start with empty notes ───────────────────────────
reset_jsonl
run_metrics stage-start ENG-T4 plan dispatching 0
line="$(last_line)"
keys="$(jq -r 'keys | length' <<<"$line")"
notes="$(jq -r '.notes' <<<"$line")"
if [[ "$keys" == "7" ]] \
   && [[ "$notes" == "" ]] \
   && [[ "$(jq -r 'has("tokens_in")' <<<"$line")" == "false" ]]; then
  pass_at "case-D legacy stage-start: 7-key line, empty notes, no cost fields"
else
  fail_at "case-D legacy stage-start" "keys=$keys notes='$notes' line=$line"
fi

# ─── Case E: partial flags emit only set fields ────────────────────────────
# Only --cost-usd set → 8 keys (7 base + cost_usd). Other five MUST be absent
# (not null, not 0).
reset_jsonl
run_metrics stage-end ENG-T5 plan success 100 --cost-usd 0.42
line="$(last_line)"
keys="$(jq -r 'keys | length' <<<"$line")"
co="$(jq -r '.cost_usd' <<<"$line")"
if [[ "$keys" == "8" ]] \
   && [[ "$co" == "0.42" ]] \
   && [[ "$(jq -r 'has("tokens_in")'    <<<"$line")" == "false" ]] \
   && [[ "$(jq -r 'has("tokens_out")'   <<<"$line")" == "false" ]] \
   && [[ "$(jq -r 'has("cache_read")'   <<<"$line")" == "false" ]] \
   && [[ "$(jq -r 'has("cache_create")' <<<"$line")" == "false" ]] \
   && [[ "$(jq -r 'has("model")'        <<<"$line")" == "false" ]]; then
  pass_at "case-E partial flags: 8-key line; cost_usd present; the other five absent"
else
  fail_at "case-E partial flags" "keys=$keys cost_usd=$co line=$line"
fi

# ─── Case F: each metrics.sh call appends exactly one line ─────────────────
# Anti-regression: a flag-parser bug that loops or double-appends would
# break this assertion before it could break events.jsonl readers.
reset_jsonl
run_metrics stage-end ENG-T6 plan success 100 --cost-usd 0.10
run_metrics stage-end ENG-T6 plan success 200 --cost-usd 0.20
run_metrics stage-end ENG-T6 plan success 300 --cost-usd 0.30
if [[ "$(line_count)" == "3" ]]; then
  pass_at "case-F three calls append three lines (no double-write)"
else
  fail_at "case-F append count" "line_count=$(line_count)"
fi

# ─── QA-authored adversarial cases (NOT in plan's Failure Mode → Test Map) ──

# ─── Case G: unknown flag falls through to notes (backward-compat preserve) ─
# A future caller passing an unrecognised `--foo` MUST NOT abort; the parser's
# `*) notes_parts+=("$1"); shift` arm must absorb both the unknown flag and
# its value as plain notes tokens. Otherwise an out-of-tree caller ships a
# breakage every time we add a flag.
reset_jsonl
run_metrics stage-end ENG-T7 plan success 100 "branch=foo" --bogus 42
line="$(last_line)"
notes="$(jq -r '.notes' <<<"$line")"
keys="$(jq -r 'keys | length' <<<"$line")"
if [[ "$notes" == "branch=foo --bogus 42" ]] \
   && [[ "$keys" == "7" ]] \
   && [[ "$(jq -r 'has("cost_usd")' <<<"$line")" == "false" ]]; then
  pass_at "case-G unknown flag --bogus 42: absorbed into notes; 7-key line; no spurious cost field"
else
  fail_at "case-G unknown flag" "notes='$notes' keys=$keys line=$line"
fi

# ─── Case H: malformed --cost-usd value (next-flag eats the value) ─────────
# `--cost-usd --tokens-in 5` consumes `--tokens-in` as the cost value. The
# downstream `tonumber` MUST fail loudly (rc != 0, no event written) rather
# than silently writing a string-typed cost field that breaks every reader
# of events.jsonl. Pin the rejection so a future "permissive" parser change
# (e.g. silent fallback to cost_usd=null) trips this test.
reset_jsonl
set +e
run_metrics stage-end ENG-T8 plan success 100 --cost-usd --tokens-in 5 >/dev/null 2>&1
rc_h=$?
set -e
lines_h="$(wc -l < "$JSONL" | tr -d ' ')"
if (( rc_h != 0 )) && [[ "$lines_h" == "0" ]]; then
  pass_at "case-H malformed --cost-usd value: parser rejects; rc=$rc_h, no event written"
else
  fail_at "case-H malformed --cost-usd" "rc=$rc_h lines=$lines_h"
fi

# ─── Case I: --cost-usd value with leading dash that is NOT a known flag ───
# A negative cost would be nonsensical, but the parser MUST treat the dash-
# prefixed value as the value (since the flag-table's `*)` arm only catches
# unknown flags AFTER the recognised six). Today the parser is unconditional
# `shift 2`, so `--cost-usd -0.5` writes cost_usd=-0.5. Pin behavior — if a
# future tightening rejects negatives, that's a deliberate change and the
# test should be updated alongside.
reset_jsonl
run_metrics stage-end ENG-T9 plan success 100 --cost-usd "-0.5"
line="$(last_line)"
co="$(jq -r '.cost_usd' <<<"$line")"
co_t="$(jq -r '.cost_usd | type' <<<"$line")"
if [[ "$co" == "-0.5" && "$co_t" == "number" ]]; then
  pass_at "case-I --cost-usd negative: numeric -0.5 accepted (current behavior pinned)"
else
  fail_at "case-I --cost-usd negative" "cost=$co type=$co_t line=$line"
fi

# ─── Case ENG-120: free-form impl_iteration event token ───────────────
# The within-stage iteration loop (ENG-120) emits per-iteration metric
# events with the free-form event name 'impl_iteration'. metrics.sh
# accepts any string for $event (no enum validation — line 41 only
# requires non-empty $event and $outcome). This case pins that the
# token, outcome, and notes payload land verbatim in the JSONL row so a
# future schema-tightening refactor that introduced enum validation
# would surface here, not silently in production.
reset_jsonl
run_metrics impl_iteration ENG-T120 implementing pass 1234 "iteration=1"
line="$(last_line)"
for expected in \
  '"event":"impl_iteration"' \
  '"issue_id":"ENG-T120"' \
  '"stage":"implementing"' \
  '"outcome":"pass"' \
  '"duration_ms":1234' \
  '"notes":"iteration=1"'; do
  if printf '%s' "$line" | grep -qF "$expected"; then
    pass_at "Case ENG-120: row contains $expected"
  else
    fail_at "Case ENG-120: row contains $expected" "got: $line"
  fi
done
# Anti-regression: the fail-iteration shape must also land cleanly, including
# the structured `failed=<kind>:<key>` notes payload.
reset_jsonl
run_metrics impl_iteration ENG-T120 implementing fail 5000 "iteration=2 failed=smoke:bash-bin-foo-test.sh"
line="$(last_line)"
if printf '%s' "$line" | grep -qF '"outcome":"fail"' \
   && printf '%s' "$line" | grep -qF '"notes":"iteration=2 failed=smoke:bash-bin-foo-test.sh"'; then
  pass_at "Case ENG-120: fail-iteration row carries outcome=fail + structured failed= notes"
else
  fail_at "Case ENG-120: fail-iteration row carries outcome=fail + structured failed= notes" \
    "got: $line"
fi

# ─── QA-ADV ENG-120: duration_ms is a JSON number, not a string ────────
# Case ENG-120 uses substring match only. If --argjson is replaced by --arg
# (e.g. for consistency with other fields), duration_ms becomes a string.
# Pin the type explicitly via jq.
reset_jsonl
run_metrics impl_iteration ENG-T120 implementing pass 4567 "iteration=1"
line="$(last_line)"
dt="$(jq -r '.duration_ms | type' <<<"$line" 2>/dev/null)"
if [[ "$dt" == "number" ]]; then
  pass_at "QA-ADV Case ENG-120: duration_ms field is JSON number type"
else
  fail_at "QA-ADV Case ENG-120: duration_ms must be JSON number, got type='$dt'" "line: $line"
fi

# ─── QA-ADV ENG-120: exhausted outcome roundtrip ──────────────────────
# The plan tests pass + fail; this adversarial case pins that outcome=exhausted
# also lands verbatim (completeness of the three-outcome vocabulary).
reset_jsonl
run_metrics impl_iteration ENG-T120 implementing exhausted 9000 "iteration=3 failed=smoke:bash-bin-bar-test.sh,file_exists:bin/new.sh"
line="$(last_line)"
if printf '%s' "$line" | grep -qF '"outcome":"exhausted"' \
   && printf '%s' "$line" | grep -qF '"notes":"iteration=3 failed=smoke:bash-bin-bar-test.sh,file_exists:bin/new.sh"'; then
  pass_at "QA-ADV Case ENG-120: exhausted-iteration row carries outcome=exhausted + multi-criterion failed= notes"
else
  fail_at "QA-ADV Case ENG-120: exhausted-iteration row" "got: $line"
fi

echo
echo "metrics-test: passed=$PASS failed=$FAIL"
(( FAIL == 0 )) || exit 1
