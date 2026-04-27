#!/usr/bin/env bash
# Table-driven lane-fence tests for linear.sh (ENG-41).
# Verifies that _check_lane, _classify_label, and _classify_comment_body
# enforce the per-lane allow/deny matrix from the plan's Command API contract.
#
# Does NOT exercise Linear network calls. Tests source linear.sh and call
# the classification/lane helpers directly, or call add_label/remove_label/
# add_comment and observe exit code + stderr.

set -euo pipefail
SCRIPT_DIR_REAL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export PIPELINE_DRY_RUN=1
export LINEAR_API_KEY="${LINEAR_API_KEY:-test-mock-key}"
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
# common.sh requires TARGET_REPO to be a real directory containing
# .pipeline-config/config.json and schemas/linear-ids.json.
export TARGET_REPO="$_TEST_TARGET_DIR"
mkdir -p "$TARGET_REPO/.pipeline-config/schemas"

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

# Minimal linear-ids.json (just enough for label_id to not die on lookup).
jq -n '{
  labels: {
    "stage:brainstorming": "uuid-stage-brainstorming",
    "stage:planning":      "uuid-stage-planning",
    "pipeline:halted":     "uuid-pipeline-halted",
    "pipeline:supersede":  "uuid-pipeline-supersede",
    "pipeline:skip-until-code-changes": "uuid-skip-until",
    "custom:label":        "uuid-custom"
  },
  states: {}
}' > "$TARGET_REPO/.pipeline-config/schemas/linear-ids.json"

HARNESS_STATE_DIR="$_TEST_STUB_DIR/state"
export HARNESS_STATE_DIR
PROJECT_STATE_DIR="${HARNESS_STATE_DIR}/${PROJECT_SLUG}"
export PROJECT_STATE_DIR
mkdir -p "$PROJECT_STATE_DIR"

# ─── Source linear.sh ────────────────────────────────────────────────────
# This loads all helper functions without running main.
# shellcheck source=linear.sh
source "$SCRIPT_DIR_REAL/linear.sh"

# Override SCRIPT_DIR inside linear.sh to point to our stub dir so any
# `bash "$SCRIPT_DIR/..."` calls inside the sourced functions hit stubs.
# (For lane tests we don't need external calls, but keep consistent.)
SCRIPT_DIR="$_TEST_STUB_DIR"

# ─── Assertion helpers ───────────────────────────────────────────────────
PASS=0; FAIL=0
fail_at() { printf '  FAIL %s\n      %s\n' "$1" "$2" >&2; FAIL=$((FAIL+1)); }
pass_at() { printf '  PASS %s\n' "$1"; PASS=$((PASS+1)); }

# run_deny <label> <lane> <action> <object_class>
# Calls _check_lane with the given lane, asserts exit code 11
# and stderr matches the expected pattern.
run_deny() {
  local label="$1" lane="$2" action="$3" object_class="$4"
  local stderr_out rc=0
  stderr_out="$(PIPELINE_WRITER="$lane" _check_lane "$action" "$object_class" 2>&1 >/dev/null)" || rc=$?
  if [[ "$rc" != 13 ]]; then
    fail_at "$label" "expected exit 13, got $rc (stderr: $stderr_out)"
    return
  fi
  if ! printf '%s' "$stderr_out" | grep -qE "lane=$lane denied: $action $object_class"; then
    fail_at "$label" "stderr did not match 'lane=$lane denied: $action $object_class' — got: $stderr_out"
    return
  fi
  pass_at "$label"
}

# run_allow <label> <lane> <action> <object_class>
# Calls _check_lane with the given lane, asserts exit code 0.
run_allow() {
  local label="$1" lane="$2" action="$3" object_class="$4"
  local rc=0
  PIPELINE_WRITER="$lane" _check_lane "$action" "$object_class" 2>/dev/null || rc=$?
  if [[ "$rc" == 0 ]]; then
    pass_at "$label"
  else
    fail_at "$label" "expected exit 0, got $rc"
  fi
}

# ─── Section 1: _classify_label ─────────────────────────────────────────
printf '\n--- _classify_label ---\n'

check_classify_label() {
  local label="$1" expected="$2"
  local got
  got="$(_classify_label "$label")"
  if [[ "$got" == "$expected" ]]; then
    pass_at "_classify_label '$label' -> $expected"
  else
    fail_at "_classify_label '$label' -> $expected" "got: $got"
  fi
}

check_classify_label "stage:brainstorming" "stage_label"
check_classify_label "stage:planning"      "stage_label"
check_classify_label "stage:implementing"  "stage_label"
check_classify_label "pipeline:halted"     "pipeline_halted"
check_classify_label "pipeline:supersede"  "pipeline_supersede"
check_classify_label "pipeline:skip-until-code-changes" "pipeline_skip_until"
check_classify_label "pipeline:skip-until-foo"          "pipeline_skip_until"
check_classify_label "pipeline:abandoned"  "any_other_label"
check_classify_label "custom:label"        "any_other_label"
check_classify_label "bug"                 "any_other_label"

# ─── Section 2: _classify_comment_body ──────────────────────────────────
printf '\n--- _classify_comment_body ---\n'

check_classify_comment() {
  local body="$1" expected="$2"
  local got
  got="$(_classify_comment_body "$body")"
  if [[ "$got" == "$expected" ]]; then
    pass_at "_classify_comment_body '${body:0:50}' -> $expected"
  else
    fail_at "_classify_comment_body '${body:0:50}' -> $expected" "got: $got"
  fi
}

check_classify_comment \
  "<!-- pipeline-transition: brainstorming → planning -->" \
  "transition_comment"

check_classify_comment \
  $'<!-- pipeline-transition: ui → reviewing -->' \
  "transition_comment"

# First non-blank line is the transition marker (with preamble whitespace)
check_classify_comment \
  $'\n  <!-- pipeline-transition: planning → implementing -->' \
  "transition_comment"

check_classify_comment \
  "<!-- pipeline-stage-summary: brainstorm -->" \
  "other_comment"

check_classify_comment \
  "<!-- pipeline-halt: agent-failure -->" \
  "other_comment"

check_classify_comment \
  "Hello world" \
  "other_comment"

check_classify_comment \
  $'Some text\n<!-- pipeline-transition: a → b -->' \
  "other_comment"

# ─── Section 3: Default lane when PIPELINE_WRITER is unset ──────────────
printf '\n--- Default lane (unset PIPELINE_WRITER) ---\n'

# orchestrator is the default; stage_label add is allowed for orchestrator
rc=0
unset PIPELINE_WRITER 2>/dev/null || true
PIPELINE_WRITER="" _check_lane "add" "stage_label" 2>/dev/null || rc=$?
if [[ "$rc" == 0 ]]; then
  pass_at "unset PIPELINE_WRITER defaults to orchestrator (add stage_label -> allow)"
else
  fail_at "unset PIPELINE_WRITER defaults to orchestrator" "got exit $rc"
fi

# ─── Section 4: Unknown lane is rejected ────────────────────────────────
printf '\n--- Unknown lane rejection ---\n'

rc=0
stderr_out="$(PIPELINE_WRITER=foo _check_lane "add" "stage_label" 2>&1 >/dev/null)" || rc=$?
if [[ "$rc" != 0 ]] && printf '%s' "$stderr_out" | grep -qi "unknown.*lane\|invalid.*lane\|unrecognised.*lane\|unrecognized.*lane"; then
  pass_at "unknown lane 'foo' rejected with distinct error"
else
  fail_at "unknown lane 'foo' rejected with distinct error" "rc=$rc stderr=$stderr_out"
fi

# ─── Section 5: Full lane × action × object_class matrix ────────────────
printf '\n--- Lane allow/deny matrix ---\n'

# Matrix from plan's Command API contract:
# Columns: orchestrator | agent | classify | scope-check | human
#
# add stage_label          allow  deny  deny  deny  allow
# remove stage_label       allow  deny  deny  deny  allow
# add pipeline_halted      allow  allow allow allow allow
# remove pipeline_halted   allow  deny  deny  deny  allow
# add pipeline_supersede   allow  deny  deny  deny  allow
# remove pipeline_supersede allow deny  deny  deny  allow
# add pipeline_skip_until  deny   deny  allow deny  allow
# remove pipeline_skip_until allow deny allow deny  allow
# add transition_comment   allow  deny  deny  deny  allow
# add other_comment        allow  allow allow allow allow
# add any_other_label      allow  deny  deny  deny  allow
# remove any_other_label   allow  deny  deny  deny  allow

# ── orchestrator ──
run_allow "orchestrator: add stage_label"              "orchestrator" "add"    "stage_label"
run_allow "orchestrator: remove stage_label"           "orchestrator" "remove" "stage_label"
run_allow "orchestrator: add pipeline_halted"          "orchestrator" "add"    "pipeline_halted"
run_allow "orchestrator: remove pipeline_halted"       "orchestrator" "remove" "pipeline_halted"
run_allow "orchestrator: add pipeline_supersede"       "orchestrator" "add"    "pipeline_supersede"
run_allow "orchestrator: remove pipeline_supersede"    "orchestrator" "remove" "pipeline_supersede"
run_deny  "orchestrator: add pipeline_skip_until"      "orchestrator" "add"    "pipeline_skip_until"
run_allow "orchestrator: remove pipeline_skip_until"   "orchestrator" "remove" "pipeline_skip_until"
run_allow "orchestrator: add transition_comment"       "orchestrator" "add"    "transition_comment"
run_allow "orchestrator: add other_comment"            "orchestrator" "add"    "other_comment"
run_allow "orchestrator: add any_other_label"          "orchestrator" "add"    "any_other_label"
run_allow "orchestrator: remove any_other_label"       "orchestrator" "remove" "any_other_label"

# ── agent ──
run_deny  "agent: add stage_label"                     "agent" "add"    "stage_label"
run_deny  "agent: remove stage_label"                  "agent" "remove" "stage_label"
run_allow "agent: add pipeline_halted"                 "agent" "add"    "pipeline_halted"
run_deny  "agent: remove pipeline_halted"              "agent" "remove" "pipeline_halted"
run_deny  "agent: add pipeline_supersede"              "agent" "add"    "pipeline_supersede"
run_allow "agent: remove pipeline_supersede"           "agent" "remove" "pipeline_supersede"
run_deny  "agent: add pipeline_skip_until"             "agent" "add"    "pipeline_skip_until"
run_deny  "agent: remove pipeline_skip_until"          "agent" "remove" "pipeline_skip_until"
run_deny  "agent: add transition_comment"              "agent" "add"    "transition_comment"
run_allow "agent: add other_comment"                   "agent" "add"    "other_comment"
run_deny  "agent: add any_other_label"                 "agent" "add"    "any_other_label"
run_deny  "agent: remove any_other_label"              "agent" "remove" "any_other_label"

# ── classify ──
run_deny  "classify: add stage_label"                  "classify" "add"    "stage_label"
run_deny  "classify: remove stage_label"               "classify" "remove" "stage_label"
run_allow "classify: add pipeline_halted"              "classify" "add"    "pipeline_halted"
run_deny  "classify: remove pipeline_halted"           "classify" "remove" "pipeline_halted"
run_deny  "classify: add pipeline_supersede"           "classify" "add"    "pipeline_supersede"
run_deny  "classify: remove pipeline_supersede"        "classify" "remove" "pipeline_supersede"
run_allow "classify: add pipeline_skip_until"          "classify" "add"    "pipeline_skip_until"
run_allow "classify: remove pipeline_skip_until"       "classify" "remove" "pipeline_skip_until"
run_deny  "classify: add transition_comment"           "classify" "add"    "transition_comment"
run_allow "classify: add other_comment"                "classify" "add"    "other_comment"
run_deny  "classify: add any_other_label"              "classify" "add"    "any_other_label"
run_deny  "classify: remove any_other_label"           "classify" "remove" "any_other_label"

# ── scope-check ──
run_deny  "scope-check: add stage_label"               "scope-check" "add"    "stage_label"
run_deny  "scope-check: remove stage_label"            "scope-check" "remove" "stage_label"
run_allow "scope-check: add pipeline_halted"           "scope-check" "add"    "pipeline_halted"
run_deny  "scope-check: remove pipeline_halted"        "scope-check" "remove" "pipeline_halted"
run_deny  "scope-check: add pipeline_supersede"        "scope-check" "add"    "pipeline_supersede"
run_deny  "scope-check: remove pipeline_supersede"     "scope-check" "remove" "pipeline_supersede"
run_deny  "scope-check: add pipeline_skip_until"       "scope-check" "add"    "pipeline_skip_until"
run_deny  "scope-check: remove pipeline_skip_until"    "scope-check" "remove" "pipeline_skip_until"
run_deny  "scope-check: add transition_comment"        "scope-check" "add"    "transition_comment"
run_allow "scope-check: add other_comment"             "scope-check" "add"    "other_comment"
run_deny  "scope-check: add any_other_label"           "scope-check" "add"    "any_other_label"
run_deny  "scope-check: remove any_other_label"        "scope-check" "remove" "any_other_label"

# ── human ──
run_allow "human: add stage_label"                     "human" "add"    "stage_label"
run_allow "human: remove stage_label"                  "human" "remove" "stage_label"
run_allow "human: add pipeline_halted"                 "human" "add"    "pipeline_halted"
run_allow "human: remove pipeline_halted"              "human" "remove" "pipeline_halted"
run_allow "human: add pipeline_supersede"              "human" "add"    "pipeline_supersede"
run_allow "human: remove pipeline_supersede"           "human" "remove" "pipeline_supersede"
run_allow "human: add pipeline_skip_until"             "human" "add"    "pipeline_skip_until"
run_allow "human: remove pipeline_skip_until"          "human" "remove" "pipeline_skip_until"
run_allow "human: add transition_comment"              "human" "add"    "transition_comment"
run_allow "human: add other_comment"                   "human" "add"    "other_comment"
run_allow "human: add any_other_label"                 "human" "add"    "any_other_label"
run_allow "human: remove any_other_label"              "human" "remove" "any_other_label"

# ─── Section 6: Integration — add_label/remove_label/add_comment deny ───
# Verify that the fence is called inside add_label, remove_label, add_comment
# and that denial propagates as exit 11.
printf '\n--- Integration: fence wired into add_label/remove_label/add_comment ---\n'

# agent tries to add stage:brainstorming — should return 11
rc=0
stderr_out="$(PIPELINE_WRITER=agent add_label "ENG-99" "stage:brainstorming" 2>&1 >/dev/null)" || rc=$?
if [[ "$rc" == 13 ]] && printf '%s' "$stderr_out" | grep -qE "lane=agent denied:"; then
  pass_at "add_label: agent + stage_label -> exit 13 + deny error"
else
  fail_at "add_label: agent + stage_label -> exit 13 + deny error" "rc=$rc stderr=$stderr_out"
fi

# agent tries to remove pipeline:halted — should return 11
rc=0
stderr_out="$(PIPELINE_WRITER=agent remove_label "ENG-99" "pipeline:halted" 2>&1 >/dev/null)" || rc=$?
if [[ "$rc" == 13 ]] && printf '%s' "$stderr_out" | grep -qE "lane=agent denied:"; then
  pass_at "remove_label: agent + pipeline_halted -> exit 13 + deny error"
else
  fail_at "remove_label: agent + pipeline_halted -> exit 13 + deny error" "rc=$rc stderr=$stderr_out"
fi

# agent tries to add transition_comment — should return 11
transition_body="<!-- pipeline-transition: planning → implementing -->"
rc=0
stderr_out="$(PIPELINE_WRITER=agent add_comment "ENG-99" "$transition_body" 2>&1 >/dev/null)" || rc=$?
if [[ "$rc" == 13 ]] && printf '%s' "$stderr_out" | grep -qE "lane=agent denied:"; then
  pass_at "add_comment: agent + transition_comment -> exit 13 + deny error"
else
  fail_at "add_comment: agent + transition_comment -> exit 13 + deny error" "rc=$rc stderr=$stderr_out"
fi

# agent adding other_comment should be allowed (dry-run returns 0)
rc=0
PIPELINE_WRITER=agent add_comment "ENG-99" "Stage summary text here." 2>/dev/null || rc=$?
if [[ "$rc" == 0 ]]; then
  pass_at "add_comment: agent + other_comment -> allow (exit 0)"
else
  fail_at "add_comment: agent + other_comment -> allow (exit 0)" "rc=$rc"
fi

# classify adding pipeline:skip-until-code-changes — should be allowed
rc=0
PIPELINE_WRITER=classify add_label "ENG-99" "pipeline:skip-until-code-changes" 2>/dev/null || rc=$?
if [[ "$rc" == 0 ]]; then
  pass_at "add_label: classify + pipeline_skip_until -> allow (exit 0)"
else
  fail_at "add_label: classify + pipeline_skip_until -> allow (exit 0)" "rc=$rc"
fi

# human removing pipeline:halted — should be allowed
rc=0
PIPELINE_WRITER=human remove_label "ENG-99" "pipeline:halted" 2>/dev/null || rc=$?
if [[ "$rc" == 0 ]]; then
  pass_at "remove_label: human + pipeline_halted -> allow (exit 0)"
else
  fail_at "remove_label: human + pipeline_halted -> allow (exit 0)" "rc=$rc"
fi

# ─── Section 7: all-stage-labels subcommand ─────────────────────────────
printf '\n--- all_stage_labels helper ---\n'
# We test the function directly. It calls get_issue internally which calls linear_query.
# In dry-run mode linear_query on queries is NOT suppressed (only mutations), so we
# need to stub _resolve_issue_uuid / get_issue. Override get_issue here.
get_issue() {
  # Return a synthetic issue with two stage labels for the first test,
  # and zero stage labels for the second test.
  # We key off $1 (identifier).
  case "$1" in
    ENG-multi)
      printf '{"data":{"issue":{"id":"uuid-multi","identifier":"ENG-multi","title":"Multi","description":"","state":{"id":"s1","name":"In Progress"},"labels":{"nodes":[{"id":"l1","name":"stage:brainstorming"},{"id":"l2","name":"stage:planning"},{"id":"l3","name":"pipeline:halted"}]},"url":"","createdAt":"","updatedAt":""}}}\n'
      ;;
    ENG-single)
      printf '{"data":{"issue":{"id":"uuid-single","identifier":"ENG-single","title":"Single","description":"","state":{"id":"s1","name":"In Progress"},"labels":{"nodes":[{"id":"l1","name":"stage:reviewing"}]},"url":"","createdAt":"","updatedAt":""}}}\n'
      ;;
    ENG-none)
      printf '{"data":{"issue":{"id":"uuid-none","identifier":"ENG-none","title":"None","description":"","state":{"id":"s1","name":"In Progress"},"labels":{"nodes":[{"id":"l1","name":"pipeline:halted"}]},"url":"","createdAt":"","updatedAt":""}}}\n'
      ;;
  esac
}

got_multi="$(all_stage_labels "ENG-multi")"
word_count="$(printf '%s' "$got_multi" | wc -w | tr -d ' ')"
if [[ "$word_count" == 2 ]] && printf '%s' "$got_multi" | grep -qF "stage:brainstorming" && printf '%s' "$got_multi" | grep -qF "stage:planning"; then
  pass_at "all_stage_labels: multi-label issue returns both stage: labels"
else
  fail_at "all_stage_labels: multi-label issue returns both stage: labels" "got: $got_multi"
fi

got_single="$(all_stage_labels "ENG-single")"
if [[ "$got_single" == "stage:reviewing" ]]; then
  pass_at "all_stage_labels: single-label issue returns exactly one label"
else
  fail_at "all_stage_labels: single-label issue returns exactly one label" "got: $got_single"
fi

got_none="$(all_stage_labels "ENG-none")"
if [[ -z "$got_none" ]]; then
  pass_at "all_stage_labels: issue with no stage: labels returns empty string"
else
  fail_at "all_stage_labels: issue with no stage: labels returns empty string" "got: $got_none"
fi

# ─── Summary ────────────────────────────────────────────────────────────
printf '\nRESULTS: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]] || exit 1
exit 0

# Sentinel — allows sourcing without running main.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
