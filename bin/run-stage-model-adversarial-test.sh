#!/usr/bin/env bash
# Adversarial coverage for ENG-103 per-stage model tiering (QA-authored).
#
# Sibling to bin/run-stage-model-test.sh (16 plan-enumerated fixtures + 3
# counter fixtures). This file covers breakages NOT in the plan's
# Failure Mode → Test Map, derived from QA's cold-sub-agent review:
#
#   ADV-1: Multi-line / control-char config payload — regex MUST be string-
#          anchored, not line-anchored (bash =~ with ^...$ can be either
#          depending on POSIX regex engine; we assert string-anchoring).
#   ADV-2: Stage-name spoofing via capitalisation — `Implementing` falls
#          through to the case-statement `*` arm, returning empty.
#   ADV-3: Stage-name spoofing via trailing whitespace — `implementing `
#          falls through to `*`, returning empty.
#   ADV-4: Counter without a `transition to=<stage>` floor (e.g. operator
#          erases history) — documents the "count all fail markers"
#          fail-permissive contract; regression sentinel if behaviour drifts.
#   ADV-5: Counter with multiple `transition to=<stage>` markers — the
#          most-recent transition is the floor; older transitions don't
#          re-include their newer fail markers.
#
# Pattern follows bin/run-stage-model-test.sh exactly (source + stub).

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export PIPELINE_DRY_RUN=1
: "${LINEAR_API_KEY:=test-mock-key}"
export LINEAR_API_KEY
export PROJECT_SLUG="${PROJECT_SLUG:-test-slug}"

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
    /var/folders/*|/tmp/*|/private/var/folders/*|/private/tmp/*) rm -rf "$path" ;;
    *) printf 'SAFETY: refusing rm -rf %q\n' "$path" >&2 ;;
  esac
}
trap '_test_safe_rm "$_TEST_STUB_DIR"; _test_safe_rm "$_TEST_TARGET_DIR"' EXIT

export TARGET_REPO="$_TEST_TARGET_DIR"
mkdir -p "$TARGET_REPO/.pipeline-config/schemas"

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

_FIXTURE_COMMENTS_FILE="$_TEST_STUB_DIR/fixture-comments.json"
printf '[]' > "$_FIXTURE_COMMENTS_FILE"

cat > "$_TEST_STUB_DIR/linear.sh" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  get-comments)
    cat "$_FIXTURE_COMMENTS_FILE" 2>/dev/null || printf '[]'
    ;;
  *) : ;;
esac
exit 0
SH
chmod +x "$_TEST_STUB_DIR/linear.sh"

# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"
# shellcheck source=classify-failure.sh
source "$SCRIPT_DIR/classify-failure.sh"
# shellcheck source=dispatch.sh
source "$SCRIPT_DIR/dispatch.sh"
# shellcheck source=run-stage.sh
source "$SCRIPT_DIR/run-stage.sh"

SCRIPT_DIR="$_TEST_STUB_DIR"

PASS=0; FAIL=0
pass_at() { printf '  PASS %s\n' "$1"; PASS=$((PASS+1)); }
fail_at() { printf '  FAIL %s\n      %s\n' "$1" "$2" >&2; FAIL=$((FAIL+1)); }

_set_config_model() {
  local stage="$1" value="$2"
  jq --arg s "$stage" --arg v "$value" \
     '. + { dispatch: { model: { ($s): $v } } }' \
     "$TARGET_REPO/.pipeline-config/config.json" > "$TARGET_REPO/.pipeline-config/config.json.tmp"
  mv "$TARGET_REPO/.pipeline-config/config.json.tmp" "$TARGET_REPO/.pipeline-config/config.json"
}

_set_fixture_comments() {
  printf '%s' "$1" > "$_FIXTURE_COMMENTS_FILE"
}

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

printf '\n=== ENG-103 QA adversarial coverage ===\n'

# ─── ADV-1: multi-line config payload must be regex-rejected ─────────────
# Bash =~ with ^...$ behaviour against newline-containing values: the
# implementation MUST treat the value as a single string. A line-anchored
# match would let `claude-opus-4-7\nrm -rf /` slip through as valid.
# Expected: regex rejects, falls through to layer-2/3 default.
printf '\n--- ADV-1: embedded newline in config rejected by regex ---\n'
_set_config_model implementing "$(printf 'claude-opus-4-7\nrm -rf /')"
_assert_resolve "ADV-1: newline-injected config rejected; falls through to default" \
  implementing ENG-ADV1 'claude-opus-4-7'
_write_default_config

# ADV-1b: embedded tab.
_set_config_model implementing "$(printf 'claude-opus-4-7\t1m')"
_assert_resolve "ADV-1b: tab-injected config rejected; falls through to default" \
  implementing ENG-ADV1b 'claude-opus-4-7'
_write_default_config

# ADV-1c: CRLF.
_set_config_model implementing "$(printf 'claude-opus-4-7\r\n')"
_assert_resolve "ADV-1c: CRLF-injected config rejected; falls through to default" \
  implementing ENG-ADV1c 'claude-opus-4-7'
_write_default_config

# ADV-1d: leading space.
_set_config_model implementing ' claude-opus-4-7'
_assert_resolve "ADV-1d: leading-space config rejected; falls through to default" \
  implementing ENG-ADV1d 'claude-opus-4-7'
_write_default_config

# ADV-1e: trailing space.
_set_config_model implementing 'claude-opus-4-7 '
_assert_resolve "ADV-1e: trailing-space config rejected; falls through to default" \
  implementing ENG-ADV1e 'claude-opus-4-7'
_write_default_config

# ADV-1f: brackets in middle (NOT a valid suffix; the tightened regex from
# commit 50e32cf only allows brackets as a structural suffix).
_set_config_model implementing 'claude[1m]-opus-4-7'
_assert_resolve "ADV-1f: brackets-in-middle config rejected by tightened regex" \
  implementing ENG-ADV1f 'claude-opus-4-7'
_write_default_config

# ─── ADV-2: stage-name spoofing via capitalisation ───────────────────────
# `case "$stage" in implementing|ui)` is case-sensitive. A caller passing
# `Implementing` (mixed-case) silently falls through to `*` and returns
# empty (subscription default). Safe-by-default but worth pinning.
printf '\n--- ADV-2: capitalised stage name falls through silently ---\n'
_assert_resolve "ADV-2: 'Implementing' (mixed-case) → empty (case statement is case-sensitive)" \
  Implementing ENG-ADV2 ''

# ADV-2b: ALL-CAPS.
_assert_resolve "ADV-2b: 'IMPLEMENTING' (all-caps) → empty" \
  IMPLEMENTING ENG-ADV2b ''

# ─── ADV-3: stage-name spoofing via trailing whitespace ──────────────────
printf '\n--- ADV-3: trailing-whitespace stage name falls through ---\n'
_assert_resolve "ADV-3: 'implementing ' (trailing space) → empty" \
  'implementing ' ENG-ADV3 ''

# ADV-3b: leading whitespace.
_assert_resolve "ADV-3b: ' implementing' (leading space) → empty" \
  ' implementing' ENG-ADV3b ''

# ─── ADV-4: counter without a transition-floor — counts all ──────────────
# By design (per _count_loopback_rejections_for_stage), if NO transition.to=
# <stage> marker exists, last_ts stays empty and the counter includes ALL
# verdict.fail markers regardless of age. This is the fail-permissive
# contract that ensures escalation fires after the FIRST rebase loopback
# even before a transition is posted. Regression sentinel.
printf '\n--- ADV-4: counter with no transition-floor counts all fail markers ---\n'
_set_fixture_comments '[
  {"createdAt": "2026-05-15T10:00:00Z", "body": "<!-- pipeline: verdict result=fail target=implementing -->"},
  {"createdAt": "2026-05-15T11:00:00Z", "body": "<!-- pipeline: verdict result=fail target=implementing -->"}
]'
_count="$(_count_loopback_rejections_for_stage ENG-ADV4 implementing 2>/dev/null || true)"
if [[ "$_count" == "2" ]]; then
  pass_at "ADV-4: counter with no transition-floor returns count of all fail markers (n=2)"
else
  fail_at "ADV-4: counter with no transition-floor" "expected=2 actual='$_count'"
fi
# Resolver consequence: implementing with count>=1 → claude-opus-4-7 (escalation).
_assert_resolve "ADV-4b: resolver escalates when no transition-floor and fail markers exist" \
  implementing ENG-ADV4 'claude-opus-4-7'

# ─── ADV-5: multiple transitions; most-recent is the floor ───────────────
# Two transitions to=implementing, the SECOND is the floor. A verdict.fail
# between the two transitions must NOT count.
printf '\n--- ADV-5: counter uses most-recent transition as the floor ---\n'
_set_fixture_comments '[
  {"createdAt": "2026-05-15T09:00:00Z", "body": "<!-- pipeline: transition from=brainstorming to=implementing -->"},
  {"createdAt": "2026-05-15T10:00:00Z", "body": "<!-- pipeline: verdict result=fail target=implementing -->"},
  {"createdAt": "2026-05-15T11:00:00Z", "body": "<!-- pipeline: transition from=reviewing to=implementing -->"},
  {"createdAt": "2026-05-15T12:00:00Z", "body": "<!-- pipeline: verdict result=fail target=implementing -->"}
]'
_count="$(_count_loopback_rejections_for_stage ENG-ADV5 implementing 2>/dev/null || true)"
if [[ "$_count" == "1" ]]; then
  pass_at "ADV-5: most-recent transition is the floor (n=1; older fail discarded)"
else
  fail_at "ADV-5: most-recent transition floor" "expected=1 actual='$_count'"
fi

# ─── Summary ─────────────────────────────────────────────────────────────
printf '\nrun-stage-model-adversarial: passed=%d failed=%d\n' "$PASS" "$FAIL"
exit $(( FAIL ? 1 : 0 ))
