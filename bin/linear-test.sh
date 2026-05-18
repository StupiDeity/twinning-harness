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
  "<!-- pipeline: transition from=brainstorming to=planning -->" \
  "transition_comment"

check_classify_comment \
  $'<!-- pipeline: transition from=ui to=reviewing -->' \
  "transition_comment"

# First non-blank line is the transition marker (with preamble whitespace)
check_classify_comment \
  $'\n  <!-- pipeline: transition from=planning to=implementing -->' \
  "transition_comment"

check_classify_comment \
  "<!-- pipeline: verdict result=pass stage=brainstorm -->" \
  "other_comment"

check_classify_comment \
  "<!-- pipeline: verdict result=halt reason=agent-failure -->" \
  "other_comment"

check_classify_comment \
  "Hello world" \
  "other_comment"

check_classify_comment \
  $'Some text\n<!-- pipeline: transition from=a to=b -->' \
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
transition_body="<!-- pipeline: transition from=planning to=implementing -->"
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

# ─── ENG-55: _resolve_body_arg + add-comment / add-or-update-comment ────
# `add-comment` and `add-or-update-comment` accept body via:
#   * legacy positional: `add-comment ENG-N "<body>"`
#   * `--body <text>` / `--body=<text>`
#   * `--body -` (read from stdin — heredoc-friendly, no scratch files)
#   * `--body-file <path>` (read from file — back-compat / large-body path)
# Pre-fix, agents wrote `.scratch.md` files at the worktree root, piped
# them via the (broken) `--body-file` flag, and then couldn't `rm` them
# because no stage's allow-list included `Bash(rm:*)`. ENG-44's dogfood
# accumulated 15 such dotfiles.
printf '\n--- ENG-55 _resolve_body_arg + body-arg shapes ---\n'

# Legacy positional body: `<body>` last positional arg, no flag form.
got="$(_resolve_body_arg "literal body")"
[[ "$got" == "literal body" ]] \
  && pass_at "ENG-55 _resolve_body_arg: legacy positional body" \
  || fail_at "ENG-55 _resolve_body_arg: legacy positional body" "got: '$got'"

# --body <text>
got="$(_resolve_body_arg --body "flag form body")"
[[ "$got" == "flag form body" ]] \
  && pass_at "ENG-55 _resolve_body_arg: --body <text>" \
  || fail_at "ENG-55 _resolve_body_arg: --body <text>" "got: '$got'"

# --body=<text>
got="$(_resolve_body_arg --body=eq-form)"
[[ "$got" == "eq-form" ]] \
  && pass_at "ENG-55 _resolve_body_arg: --body=<text>" \
  || fail_at "ENG-55 _resolve_body_arg: --body=<text>" "got: '$got'"

# --body - reads from stdin. Verify that newlines are preserved.
got="$(printf 'line one\nline two\nline three' | _resolve_body_arg --body -)"
expected=$'line one\nline two\nline three'
[[ "$got" == "$expected" ]] \
  && pass_at "ENG-55 _resolve_body_arg: --body - (stdin) preserves newlines" \
  || fail_at "ENG-55 _resolve_body_arg: --body - (stdin)" "got: '$got'"

# Stdin body containing $VAR-shaped strings is preserved verbatim under a
# quoted heredoc (the contract documented in the prompt sweep).
got="$(cat <<'EOF' | _resolve_body_arg --body -
shell-active: $HOME and `cmd` and $(date)
EOF
)"
[[ "$got" == 'shell-active: $HOME and `cmd` and $(date)' ]] \
  && pass_at "ENG-55 _resolve_body_arg: stdin under <<'EOF' preserves \$VAR / backticks / \$()" \
  || fail_at "ENG-55 _resolve_body_arg: stdin literal-shell-syntax" "got: '$got'"

# --body-file <path> reads a file (back-compat path).
_eng55_body_file="$_TEST_STUB_DIR/body-file.md"
printf 'file body line A\nfile body line B' > "$_eng55_body_file"
got="$(_resolve_body_arg --body-file "$_eng55_body_file")"
expected=$'file body line A\nfile body line B'
[[ "$got" == "$expected" ]] \
  && pass_at "ENG-55 _resolve_body_arg: --body-file <path>" \
  || fail_at "ENG-55 _resolve_body_arg: --body-file <path>" "got: '$got'"

# --body-file with a missing path dies cleanly.
rc=0
( _resolve_body_arg --body-file "/nonexistent/path/$$.md" ) >/dev/null 2>&1 || rc=$?
[[ "$rc" -ne 0 ]] \
  && pass_at "ENG-55 _resolve_body_arg: missing --body-file dies" \
  || fail_at "ENG-55 _resolve_body_arg: missing --body-file dies" "got rc=$rc"

# --body without a value dies cleanly.
rc=0
( _resolve_body_arg --body ) >/dev/null 2>&1 || rc=$?
[[ "$rc" -ne 0 ]] \
  && pass_at "ENG-55 _resolve_body_arg: --body without value dies" \
  || fail_at "ENG-55 _resolve_body_arg: --body without value dies" "got rc=$rc"

# add_comment with empty body (no flag, no positional) dies cleanly.
rc=0
err="$(add_comment ENG-55T 2>&1)" || rc=$?
[[ "$rc" -ne 0 ]] && printf '%s' "$err" | grep -qF "body is empty" \
  && pass_at "ENG-55 add_comment: empty body dies cleanly (no API call)" \
  || fail_at "ENG-55 add_comment: empty body" "rc=$rc err=$err"

# add_comment with --body - reads stdin and reaches the dry-run path.
out="$(printf 'stdin-body-marker' | add_comment ENG-55T --body - 2>&1)"
printf '%s' "$out" | grep -qF "stdin-body-marker" \
  && pass_at "ENG-55 add_comment: --body - reads stdin in dry-run path" \
  || fail_at "ENG-55 add_comment: --body - in dry-run" "out=$out"

# add_or_update_comment with --body - reads stdin and reaches dry-run.
out="$(printf 'aouc-stdin-marker' | add_or_update_comment "test/sig/ENG-55T" ENG-55T --body - 2>&1)"
printf '%s' "$out" | grep -qF "aouc-stdin-marker" \
  && pass_at "ENG-55 add_or_update_comment: --body - reads stdin in dry-run path" \
  || fail_at "ENG-55 add_or_update_comment: --body -" "out=$out"

# add_or_update_comment legacy positional body still works.
out="$(add_or_update_comment "test/sig/ENG-55T" ENG-55T "legacy-positional-marker" 2>&1)"
printf '%s' "$out" | grep -qF "legacy-positional-marker" \
  && pass_at "ENG-55 add_or_update_comment: legacy positional body still works" \
  || fail_at "ENG-55 add_or_update_comment: legacy positional" "out=$out"

# add_or_update_comment with empty body dies.
rc=0
err="$(add_or_update_comment "test/sig/ENG-55T" ENG-55T 2>&1)" || rc=$?
[[ "$rc" -ne 0 ]] && printf '%s' "$err" | grep -qF "body is empty" \
  && pass_at "ENG-55 add_or_update_comment: empty body dies cleanly" \
  || fail_at "ENG-55 add_or_update_comment: empty body" "rc=$rc err=$err"

# ─── ENG-63: add_or_update_comment identical-body footer (C-001..C-006) ──
# Exercise the commentUpdate branch under controlled GraphQL responses.
# Override linear_query and _resolve_issue_uuid post-source (the same idiom
# used at line 87 for SCRIPT_DIR), and flip PIPELINE_DRY_RUN=0 so the
# function reaches the existing-id resolution path instead of the dry-run
# short-circuit at bin/linear.sh:553.
printf '\n--- ENG-63: identical-body re-apply visibility ---\n'

_eng63_orig_linear_query="$(declare -f linear_query)"
_eng63_orig_resolve_uuid="$(declare -f _resolve_issue_uuid)"
_eng63_orig_dry_run="$PIPELINE_DRY_RUN"
_eng63_orig_script_dir="$SCRIPT_DIR"

# linear.sh's metric emission resolves bin/metrics.sh via $SCRIPT_DIR. The
# lane-fence section above overrode SCRIPT_DIR to the stub dir; flip it
# back to the real bin/ so the metric write reaches the real script.
SCRIPT_DIR="$SCRIPT_DIR_REAL"

_resolve_issue_uuid() { printf 'uuid-mock'; }

_eng63_capture_file="$(mktemp -t eng63-capture.XXXXXX)"
_eng63_canned_existing_body=""
_eng63_canned_existing_id="cmt-mock-001"

linear_query() {
  local query="$1" variables="${2:-{\}}"
  if [[ "$query" =~ commentUpdate ]]; then
    jq -r '.body' <<<"$variables" >> "$_eng63_capture_file"
    printf '{"data":{"commentUpdate":{"success":true}}}\n'
    return 0
  fi
  if [[ "$query" =~ commentCreate ]]; then
    jq -r '.body' <<<"$variables" >> "$_eng63_capture_file"
    printf '{"data":{"commentCreate":{"success":true}}}\n'
    return 0
  fi
  jq -cn --arg id "$_eng63_canned_existing_id" --arg body "$_eng63_canned_existing_body" \
    '{data:{issue:{comments:{nodes:[{id:$id,body:$body}]}}}}'
}

export PIPELINE_DRY_RUN=0
mkdir -p "$PROJECT_STATE_DIR/metrics"
: > "$PROJECT_STATE_DIR/metrics/events.jsonl"

# C-001: identical body (no prior footer) → footer appended
: > "$_eng63_capture_file"
_eng63_canned_existing_body=$'Test body line 1\nTest body line 2\n\n<!-- meta: dedup key=test/sig/ENG-63T -->'
add_or_update_comment "test/sig/ENG-63T" ENG-63T \
  --body "$_eng63_canned_existing_body" >/dev/null 2>&1
if grep -qE '^<!-- meta: reapplied at=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z -->$' "$_eng63_capture_file"; then
  pass_at "ENG-63 C-001 identical body → footer appended"
else
  fail_at "ENG-63 C-001 identical body → footer appended" "captured: $(cat "$_eng63_capture_file")"
fi

# C-002: different body → no footer
: > "$_eng63_capture_file"
_eng63_canned_existing_body=$'Test body line 1\n\n<!-- meta: dedup key=test/sig/ENG-63T -->'
add_or_update_comment "test/sig/ENG-63T" ENG-63T \
  --body $'Test body line 1 CHANGED\n\n<!-- meta: dedup key=test/sig/ENG-63T -->' >/dev/null 2>&1
if grep -q '<!-- meta: reapplied at=' "$_eng63_capture_file"; then
  fail_at "ENG-63 C-002 different body → no footer" "captured: $(cat "$_eng63_capture_file")"
else
  pass_at "ENG-63 C-002 different body → no footer"
fi

# C-003: identical body + prior footer → footer rotated, not stacked
: > "$_eng63_capture_file"
_eng63_canned_existing_body=$'Test body line 1\n<!-- meta: dedup key=test/sig/ENG-63T -->\n<!-- meta: reapplied at=2025-01-01T00:00:00Z -->'
add_or_update_comment "test/sig/ENG-63T" ENG-63T \
  --body $'Test body line 1\n<!-- meta: dedup key=test/sig/ENG-63T -->' >/dev/null 2>&1
_eng63_footer_count="$(grep -cE '^<!-- meta: reapplied at=' "$_eng63_capture_file" || true)"
_eng63_has_old_ts="$(grep -c '2025-01-01T00:00:00Z' "$_eng63_capture_file" || true)"
if [[ "$_eng63_footer_count" == "1" && "$_eng63_has_old_ts" == "0" ]]; then
  pass_at "ENG-63 C-003 identical body + prior footer → rotated, not stacked"
else
  fail_at "ENG-63 C-003 identical body + prior footer → rotated, not stacked" \
    "footer_count=$_eng63_footer_count has_old_ts=$_eng63_has_old_ts captured: $(cat "$_eng63_capture_file")"
fi

# C-004: identical body emits exactly one comment-reapplied metric event
# (delta-based: count before vs after, so prior-test residue does not mask
# a regression where this call writes zero or two events.)
: > "$_eng63_capture_file"
_eng63_canned_existing_body=$'Test body line 1\n\n<!-- meta: dedup key=test/sig/ENG-63T -->'
_eng63_metric_count_before="$(grep -c '"event":"comment-reapplied"' "$PROJECT_STATE_DIR/metrics/events.jsonl" 2>/dev/null || true)"
add_or_update_comment "test/sig/ENG-63T" ENG-63T \
  --body "$_eng63_canned_existing_body" >/dev/null 2>&1
_eng63_metric_count_after="$(grep -c '"event":"comment-reapplied"' "$PROJECT_STATE_DIR/metrics/events.jsonl" 2>/dev/null || true)"
_eng63_metric_delta=$(( _eng63_metric_count_after - _eng63_metric_count_before ))
if [[ "$_eng63_metric_delta" == "1" ]]; then
  pass_at "ENG-63 C-004 identical body → one comment-reapplied metric event"
else
  fail_at "ENG-63 C-004 identical body → one comment-reapplied metric event" \
    "delta=$_eng63_metric_delta before=$_eng63_metric_count_before after=$_eng63_metric_count_after"
fi

# C-005: identical body, existing carries trailing newline → footer still appended
# Guards against a future regression where the equality check loses its trailing-
# newline tolerance (today the shell's $() command-substitution strips trailing
# newlines from both norms; the test pins the property so a refactor of that path
# can't silently re-introduce the asymmetry).
: > "$_eng63_capture_file"
_eng63_canned_existing_body=$'Test body line 1\nTest body line 2\n\n<!-- meta: dedup key=test/sig/ENG-63T -->\n'
add_or_update_comment "test/sig/ENG-63T" ENG-63T \
  --body $'Test body line 1\nTest body line 2\n\n<!-- meta: dedup key=test/sig/ENG-63T -->' >/dev/null 2>&1
if grep -qE '^<!-- meta: reapplied at=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z -->$' "$_eng63_capture_file"; then
  pass_at "ENG-63 C-005 trailing-newline asymmetry → footer still appended"
else
  fail_at "ENG-63 C-005 trailing-newline asymmetry → footer still appended" \
    "captured: $(cat "$_eng63_capture_file")"
fi

# C-006: no existing matching comment → commentCreate path, no footer.
# Stub returns one node with empty body — first jq's `select(.body | contains($m))`
# yields no match, existing_id is empty, function falls through to commentCreate.
: > "$_eng63_capture_file"
_eng63_canned_existing_body=""
add_or_update_comment "test/sig/ENG-63T" ENG-63T \
  --body $'Brand new body\n\n<!-- meta: dedup key=test/sig/ENG-63T -->' >/dev/null 2>&1
if grep -q '<!-- meta: reapplied at=' "$_eng63_capture_file"; then
  fail_at "ENG-63 C-006 no existing comment → no footer on create" \
    "captured: $(cat "$_eng63_capture_file")"
else
  pass_at "ENG-63 C-006 no existing comment → no footer on create"
fi

# ─── ENG-63: QA-authored adversarial coverage (AD-001..AD-005) ──
# These tests target gaps the plan's Failure Mode → Test Map did not
# enumerate, surfaced by an independent cold review of the api-contract
# and new code paths. Each pin is a property already implied by the
# brainstorm's design decisions (D-002 line-anchored regex; D-003 single
# rotating footer; D-004 create-path bypass) but not directly exercised
# by C-001..C-006.

# AD-001: mid-line `<!-- meta: reapplied at=… -->` substring is NOT stripped.
# Pins D-002's line-anchored regex shape: a quoted mention of the marker
# (e.g. inside fenced prose) must survive normalization, otherwise an
# un-anchored regex regression would silently drop content from operator-
# facing bodies. Construct an existing body with the marker text mid-line;
# new body identical → footer SHOULD append (norms equal because both
# carry the mid-line text identically).
: > "$_eng63_capture_file"
_eng63_canned_existing_body=$'prefix <!-- meta: reapplied at=2026-01-01T00:00:00Z --> suffix\n\n<!-- meta: dedup key=test/sig/ENG-63T -->'
add_or_update_comment "test/sig/ENG-63T" ENG-63T \
  --body "$_eng63_canned_existing_body" >/dev/null 2>&1
# Footer must append (bodies equal after strip) AND the original 2026-01-01
# timestamp must survive in the captured commentUpdate body (line-anchored
# regex did not strip the mid-line occurrence).
if grep -qE '^<!-- meta: reapplied at=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z -->$' "$_eng63_capture_file" \
   && grep -q 'prefix <!-- meta: reapplied at=2026-01-01T00:00:00Z --> suffix' "$_eng63_capture_file"; then
  pass_at "ENG-63 AD-001 mid-line marker substring survives strip (line-anchored regex)"
else
  fail_at "ENG-63 AD-001 mid-line marker substring survives strip (line-anchored regex)" \
    "captured: $(cat "$_eng63_capture_file")"
fi

# AD-002: multiple stacked historical footers in existing body → all stripped,
# rotation collapses to exactly ONE footer. Pins D-003's single-footer
# invariant under a corrupted-history scenario where a buggy past write
# stacked 3 footers; the new write must still detect equality and produce
# a single fresh footer, not five.
: > "$_eng63_capture_file"
_eng63_canned_existing_body=$'Halt body\n<!-- meta: dedup key=test/sig/ENG-63T -->\n<!-- meta: reapplied at=2025-01-01T00:00:00Z -->\n<!-- meta: reapplied at=2025-02-02T00:00:00Z -->\n<!-- meta: reapplied at=2025-03-03T00:00:00Z -->'
add_or_update_comment "test/sig/ENG-63T" ENG-63T \
  --body $'Halt body\n<!-- meta: dedup key=test/sig/ENG-63T -->' >/dev/null 2>&1
_eng63_ad002_count="$(grep -cE '^<!-- meta: reapplied at=' "$_eng63_capture_file" || true)"
_eng63_ad002_old_jan="$(grep -c '2025-01-01T00:00:00Z' "$_eng63_capture_file" || true)"
_eng63_ad002_old_feb="$(grep -c '2025-02-02T00:00:00Z' "$_eng63_capture_file" || true)"
_eng63_ad002_old_mar="$(grep -c '2025-03-03T00:00:00Z' "$_eng63_capture_file" || true)"
if [[ "$_eng63_ad002_count" == "1" \
   && "$_eng63_ad002_old_jan" == "0" \
   && "$_eng63_ad002_old_feb" == "0" \
   && "$_eng63_ad002_old_mar" == "0" ]]; then
  pass_at "ENG-63 AD-002 stacked historical footers → collapse to one fresh footer"
else
  fail_at "ENG-63 AD-002 stacked historical footers → collapse to one fresh footer" \
    "count=$_eng63_ad002_count jan=$_eng63_ad002_old_jan feb=$_eng63_ad002_old_feb mar=$_eng63_ad002_old_mar captured: $(cat "$_eng63_capture_file")"
fi

# AD-003: caller body is ONLY a `<!-- meta: reapplied at=… -->` line plus
# the dedup marker (no other content). After strip, `new_norm` carries
# only the dedup marker line; if existing body matches that exact shape
# (no prior content), the `-n existing_norm` guard still fires (norm
# is non-empty) and footer appends. Pins that the guard's purpose is
# specifically to short-circuit on EMPTY norms (jq parse failure /
# null body), not on small-but-present norms.
: > "$_eng63_capture_file"
_eng63_canned_existing_body=$'<!-- meta: dedup key=test/sig/ENG-63T -->'
add_or_update_comment "test/sig/ENG-63T" ENG-63T \
  --body $'<!-- meta: dedup key=test/sig/ENG-63T -->' >/dev/null 2>&1
if grep -qE '^<!-- meta: reapplied at=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z -->$' "$_eng63_capture_file"; then
  pass_at "ENG-63 AD-003 dedup-marker-only body → guard accepts non-empty norm, footer appends"
else
  fail_at "ENG-63 AD-003 dedup-marker-only body → guard accepts non-empty norm, footer appends" \
    "captured: $(cat "$_eng63_capture_file")"
fi

# AD-004: legacy-marker-shaped existing comment (`<!-- pipeline-sig: ... -->`)
# is the matched comment in `existing_id` lookup; caller passes a body
# carrying the new-shape `<!-- meta: dedup key=... -->` marker. The two
# bodies differ by marker shape → `existing_norm != new_norm` →
# no footer → caller's body posted (in-place migration to new shape).
# Pins the documented behaviour for plan Failure Mode row "Mixed
# legacy/new dedup marker shapes" beyond the C-002 trivial-different-
# bodies case.
: > "$_eng63_capture_file"
_eng63_canned_existing_body=$'Halt body\n\n<!-- pipeline-sig: test/sig/ENG-63T -->'
add_or_update_comment "test/sig/ENG-63T" ENG-63T \
  --body $'Halt body\n\n<!-- meta: dedup key=test/sig/ENG-63T -->' >/dev/null 2>&1
# Footer must NOT appear (norms differ by marker shape) AND the captured
# body must carry the new-shape marker (in-place migration occurred).
if grep -q '<!-- meta: reapplied at=' "$_eng63_capture_file"; then
  fail_at "ENG-63 AD-004 legacy→new marker migration → no footer (bodies differ by marker)" \
    "captured: $(cat "$_eng63_capture_file")"
elif grep -qF '<!-- meta: dedup key=test/sig/ENG-63T -->' "$_eng63_capture_file"; then
  pass_at "ENG-63 AD-004 legacy→new marker migration → no footer (bodies differ by marker)"
else
  fail_at "ENG-63 AD-004 legacy→new marker migration → no footer (bodies differ by marker)" \
    "expected new-shape marker in captured body; captured: $(cat "$_eng63_capture_file")"
fi

# AD-005: identical body containing multibyte Unicode (emoji + CJK) → footer
# appends. Pins that the byte-equality comparison and the `sed -E` strip
# both handle Unicode payloads correctly — operator-facing halt bodies
# routinely carry non-ASCII (project / branch names, error messages).
: > "$_eng63_capture_file"
_eng63_canned_existing_body=$'Halt: 失败 ⚠️ retry\n\n<!-- meta: dedup key=test/sig/ENG-63T -->'
add_or_update_comment "test/sig/ENG-63T" ENG-63T \
  --body "$_eng63_canned_existing_body" >/dev/null 2>&1
if grep -qE '^<!-- meta: reapplied at=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z -->$' "$_eng63_capture_file" \
   && grep -q '失败' "$_eng63_capture_file"; then
  pass_at "ENG-63 AD-005 multibyte Unicode body → footer appends, content survives"
else
  fail_at "ENG-63 AD-005 multibyte Unicode body → footer appends, content survives" \
    "captured: $(cat "$_eng63_capture_file")"
fi

# Restore originals so subsequent tests in this file (or callers) inherit a
# pristine env.
rm -f "$_eng63_capture_file"
unset -f linear_query _resolve_issue_uuid
eval "$_eng63_orig_linear_query"
eval "$_eng63_orig_resolve_uuid"
export PIPELINE_DRY_RUN="$_eng63_orig_dry_run"
SCRIPT_DIR="$_eng63_orig_script_dir"
unset _eng63_orig_linear_query _eng63_orig_resolve_uuid _eng63_orig_dry_run \
      _eng63_orig_script_dir _eng63_capture_file _eng63_canned_existing_body \
      _eng63_canned_existing_id _eng63_footer_count _eng63_has_old_ts \
      _eng63_metric_count_before _eng63_metric_count_after _eng63_metric_delta \
      _eng63_ad002_count _eng63_ad002_old_jan _eng63_ad002_old_feb _eng63_ad002_old_mar

# ─── ENG-111: breadcrumb-on-body-change in add_or_update_comment (B-001..B-006) ─
# When add_or_update_comment runs commentUpdate with a body that DIFFERS
# from the existing canonical (post the ENG-63 dispatch+reapplied strip),
# also post a sig-less chronological breadcrumb via add_comment. The
# breadcrumb gets a fresh createdAt so a top-down feed scan surfaces the
# re-fire — closing the gap ENG-63's identical-body footer rotation does
# not cover.
printf '\n--- ENG-111: breadcrumb-on-body-change ---\n'

_eng111_orig_linear_query="$(declare -f linear_query)"
_eng111_orig_resolve_uuid="$(declare -f _resolve_issue_uuid)"
_eng111_orig_dry_run="$PIPELINE_DRY_RUN"
_eng111_orig_script_dir="$SCRIPT_DIR"

SCRIPT_DIR="$SCRIPT_DIR_REAL"

_resolve_issue_uuid() { printf 'uuid-mock'; }

_eng111_capture_file="$(mktemp -t eng111-capture.XXXXXX)"
_eng111_canned_existing_body=""
_eng111_canned_existing_id="cmt-mock-001"
_eng111_canned_existing_url=""
_eng111_canned_no_match=0
_eng111_force_create_failure=0
_eng111_create_call_count=0

linear_query() {
  local query="$1" variables="${2:-{\}}"
  if [[ "$query" =~ commentUpdate ]]; then
    jq -r '.body' <<<"$variables" >> "$_eng111_capture_file"
    printf '{"data":{"commentUpdate":{"success":true}}}\n'
    return 0
  fi
  if [[ "$query" =~ commentCreate ]]; then
    _eng111_create_call_count=$(( _eng111_create_call_count + 1 ))
    # B-005: fail the breadcrumb commentCreate (the second commentCreate
    # under a body-change update is the breadcrumb post). The canonical
    # `commentUpdate` already ran on a prior linear_query call and is
    # untouched by this failure.
    if (( _eng111_force_create_failure == 1 && _eng111_create_call_count >= 1 )); then
      printf 'GraphQL error: simulated breadcrumb post failure\n' 1>&2
      return 1
    fi
    jq -r '.body' <<<"$variables" >> "$_eng111_capture_file"
    printf '{"data":{"commentCreate":{"success":true}}}\n'
    return 0
  fi
  # Comments-fetch query path. When _eng111_canned_no_match=1, return a
  # single unrelated comment whose body does NOT carry the sig (drives
  # the first-emission commentCreate branch). Otherwise return one node
  # carrying the canned body + id + url.
  if (( _eng111_canned_no_match == 1 )); then
    jq -cn '{data:{issue:{comments:{nodes:[{id:"cmt-unrelated",body:"unrelated comment",url:""}]}}}}'
    return 0
  fi
  jq -cn --arg id "$_eng111_canned_existing_id" \
         --arg body "$_eng111_canned_existing_body" \
         --arg url "$_eng111_canned_existing_url" \
    '{data:{issue:{comments:{nodes:[{id:$id,body:$body,url:$url}]}}}}'
}

export PIPELINE_DRY_RUN=0
mkdir -p "$PROJECT_STATE_DIR/metrics"
: > "$PROJECT_STATE_DIR/metrics/events.jsonl"

# B-001: first-emit (no matching existing comment) → commentCreate path,
# capture has exactly ONE entry, no breadcrumb. Pins D-004 (first emission
# does not emit a breadcrumb).
: > "$_eng111_capture_file"
_eng111_canned_no_match=1
_eng111_create_call_count=0
_eng111_force_create_failure=0
add_or_update_comment "test/sig/ENG-111T" ENG-111T \
  --body $'Fresh body line\n\n<!-- meta: dedup key=test/sig/ENG-111T -->' >/dev/null 2>&1
_eng111_entry_count="$(grep -c 'test/sig/ENG-111T' "$_eng111_capture_file" || true)"
if [[ "$_eng111_entry_count" == "1" ]] \
   && ! grep -q 'meta: breadcrumb sig=' "$_eng111_capture_file"; then
  pass_at "ENG-111 B-001 first-emit → no breadcrumb"
else
  fail_at "ENG-111 B-001 first-emit → no breadcrumb" \
    "entries=$_eng111_entry_count captured: $(cat "$_eng111_capture_file")"
fi
_eng111_canned_no_match=0

# B-002: body-change update, canonical URL present → capture has TWO entries
# (the updated canonical AND a breadcrumb). The breadcrumb's body carries
# the trailing marker, the canned URL, and the prose phrase referencing
# the sig. Pins AC #1.
: > "$_eng111_capture_file"
_eng111_canned_existing_body=$'Old halt body line\n\n<!-- meta: dedup key=test/sig/ENG-111T -->'
_eng111_canned_existing_url='https://linear.app/example/issue/ENG-111/#comment-cmt-mock-001'
_eng111_create_call_count=0
add_or_update_comment "test/sig/ENG-111T" ENG-111T \
  --body $'New halt body line CHANGED\n\n<!-- meta: dedup key=test/sig/ENG-111T -->' >/dev/null 2>&1
_eng111_canonical_count="$(grep -cF 'New halt body line CHANGED' "$_eng111_capture_file" || true)"
_eng111_breadcrumb_count="$(grep -cF '<!-- meta: breadcrumb sig=test/sig/ENG-111T comment_id=cmt-mock-001 -->' "$_eng111_capture_file" || true)"
_eng111_url_count="$(grep -cF 'https://linear.app/example/issue/ENG-111/#comment-cmt-mock-001' "$_eng111_capture_file" || true)"
_eng111_prose_count="$(grep -c 'Re-emitted (body changed) under sig' "$_eng111_capture_file" || true)"
if [[ "$_eng111_canonical_count" == "1" \
   && "$_eng111_breadcrumb_count" == "1" \
   && "$_eng111_url_count" == "1" \
   && "$_eng111_prose_count" == "1" ]]; then
  pass_at "ENG-111 B-002 body-change update → breadcrumb with sig+URL+prose"
else
  fail_at "ENG-111 B-002 body-change update → breadcrumb with sig+URL+prose" \
    "canonical=$_eng111_canonical_count breadcrumb=$_eng111_breadcrumb_count url=$_eng111_url_count prose=$_eng111_prose_count captured: $(cat "$_eng111_capture_file")"
fi

# B-003: identical-body update → no breadcrumb (ENG-63 footer instead).
# Pins AC #2: identical re-runs stay silent at the breadcrumb level.
: > "$_eng111_capture_file"
_eng111_canned_existing_body=$'Halt body steady\n\n<!-- meta: dedup key=test/sig/ENG-111T -->'
_eng111_canned_existing_url='https://linear.app/example/issue/ENG-111/#comment-cmt-mock-001'
_eng111_create_call_count=0
add_or_update_comment "test/sig/ENG-111T" ENG-111T \
  --body "$_eng111_canned_existing_body" >/dev/null 2>&1
_eng111_footer_present=0
grep -qE '^<!-- meta: reapplied at=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z -->$' "$_eng111_capture_file" \
  && _eng111_footer_present=1
if [[ "$_eng111_footer_present" == "1" ]] \
   && ! grep -q 'meta: breadcrumb sig=' "$_eng111_capture_file"; then
  pass_at "ENG-111 B-003 identical-body update → no breadcrumb (footer only)"
else
  fail_at "ENG-111 B-003 identical-body update → no breadcrumb (footer only)" \
    "footer=$_eng111_footer_present captured: $(cat "$_eng111_capture_file")"
fi

# B-004: body-change update, canonical URL empty → breadcrumb still posts
# but the URL line is omitted. The trailing meta marker is still present.
# Pins D-002 + D-003 URL-fallback path (A-11 graceful degradation).
: > "$_eng111_capture_file"
_eng111_canned_existing_body=$'Old halt body line\n\n<!-- meta: dedup key=test/sig/ENG-111T -->'
_eng111_canned_existing_url=''
_eng111_create_call_count=0
add_or_update_comment "test/sig/ENG-111T" ENG-111T \
  --body $'New halt body line CHANGED v2\n\n<!-- meta: dedup key=test/sig/ENG-111T -->' >/dev/null 2>&1
_eng111_breadcrumb_present=0
grep -qF '<!-- meta: breadcrumb sig=test/sig/ENG-111T comment_id=cmt-mock-001 -->' "$_eng111_capture_file" \
  && _eng111_breadcrumb_present=1
_eng111_has_url=0
grep -q 'https://' "$_eng111_capture_file" && _eng111_has_url=1
if [[ "$_eng111_breadcrumb_present" == "1" && "$_eng111_has_url" == "0" ]]; then
  pass_at "ENG-111 B-004 body-change + empty URL → breadcrumb posts, URL line omitted"
else
  fail_at "ENG-111 B-004 body-change + empty URL → breadcrumb posts, URL line omitted" \
    "breadcrumb=$_eng111_breadcrumb_present has_url=$_eng111_has_url captured: $(cat "$_eng111_capture_file")"
fi

# B-005: body-change update, breadcrumb commentCreate fails → canonical
# commentUpdate is observable in capture AND add_or_update_comment exits 0.
# Pins §5 error-handling: breadcrumb post is best-effort, never blocks the
# load-bearing canonical update.
: > "$_eng111_capture_file"
_eng111_canned_existing_body=$'Old halt body B5\n\n<!-- meta: dedup key=test/sig/ENG-111T -->'
_eng111_canned_existing_url=''
_eng111_force_create_failure=1
_eng111_create_call_count=0
add_or_update_comment "test/sig/ENG-111T" ENG-111T \
  --body $'New halt body B5 CHANGED\n\n<!-- meta: dedup key=test/sig/ENG-111T -->' >/dev/null 2>&1
_eng111_b5_rc=$?
_eng111_canonical_seen=0
grep -qF 'New halt body B5 CHANGED' "$_eng111_capture_file" && _eng111_canonical_seen=1
_eng111_breadcrumb_seen=0
grep -q 'meta: breadcrumb sig=' "$_eng111_capture_file" && _eng111_breadcrumb_seen=1
if [[ "$_eng111_b5_rc" == "0" && "$_eng111_canonical_seen" == "1" && "$_eng111_breadcrumb_seen" == "0" ]]; then
  pass_at "ENG-111 B-005 breadcrumb post failure → canonical preserved, function rc=0"
else
  fail_at "ENG-111 B-005 breadcrumb post failure → canonical preserved, function rc=0" \
    "rc=$_eng111_b5_rc canonical=$_eng111_canonical_seen breadcrumb=$_eng111_breadcrumb_seen captured: $(cat "$_eng111_capture_file")"
fi
_eng111_force_create_failure=0

# B-006: comment-breadcrumb metric emitted exactly once per body-change update.
# Delta-based to survive residue from B-002/B-004.
: > "$_eng111_capture_file"
_eng111_canned_existing_body=$'Old halt body B6\n\n<!-- meta: dedup key=test/sig/ENG-111T -->'
_eng111_canned_existing_url=''
_eng111_create_call_count=0
_eng111_metric_count_before="$(grep -c '"event":"comment-breadcrumb"' "$PROJECT_STATE_DIR/metrics/events.jsonl" 2>/dev/null || true)"
add_or_update_comment "test/sig/ENG-111T" ENG-111T \
  --body $'New halt body B6 CHANGED\n\n<!-- meta: dedup key=test/sig/ENG-111T -->' >/dev/null 2>&1
_eng111_metric_count_after="$(grep -c '"event":"comment-breadcrumb"' "$PROJECT_STATE_DIR/metrics/events.jsonl" 2>/dev/null || true)"
_eng111_metric_delta=$(( _eng111_metric_count_after - _eng111_metric_count_before ))
if [[ "$_eng111_metric_delta" == "1" ]]; then
  pass_at "ENG-111 B-006 body-change update → one comment-breadcrumb metric event"
else
  fail_at "ENG-111 B-006 body-change update → one comment-breadcrumb metric event" \
    "delta=$_eng111_metric_delta before=$_eng111_metric_count_before after=$_eng111_metric_count_after"
fi

# Restore originals.
rm -f "$_eng111_capture_file"
unset -f linear_query _resolve_issue_uuid
eval "$_eng111_orig_linear_query"
eval "$_eng111_orig_resolve_uuid"
export PIPELINE_DRY_RUN="$_eng111_orig_dry_run"
SCRIPT_DIR="$_eng111_orig_script_dir"
unset _eng111_orig_linear_query _eng111_orig_resolve_uuid _eng111_orig_dry_run \
      _eng111_orig_script_dir _eng111_capture_file _eng111_canned_existing_body \
      _eng111_canned_existing_id _eng111_canned_existing_url \
      _eng111_canned_no_match _eng111_force_create_failure _eng111_create_call_count \
      _eng111_entry_count _eng111_canonical_count _eng111_breadcrumb_count \
      _eng111_url_count _eng111_prose_count _eng111_footer_present \
      _eng111_breadcrumb_present _eng111_has_url _eng111_b5_rc \
      _eng111_canonical_seen _eng111_breadcrumb_seen \
      _eng111_metric_count_before _eng111_metric_count_after _eng111_metric_delta

# ─── ENG-87: dispatch_id auto-injection in add_comment / add_or_update_comment ─
# bin/linear.sh's _inject_dispatch_marker is the chokepoint where every
# Linear comment body gets stamped with the current dispatch_id. Tests
# pin: env-set → marker appended; env-unset → no injection (operator
# lane); idempotent re-apply; coexists with dedup-marker footer.
printf '\n--- ENG-87: dispatch_id auto-injection ---\n'

# Capture file for inspecting bodies via a stubbed log path. Use the
# existing PIPELINE_DRY_RUN=1 path: add_comment in dry-run mode emits
# `[DRY_RUN] would comment on <ident>: <first 80 chars>...` via log()
# (writes to stderr). We stub the log function to capture full bodies.
_eng87_lin_log="$_TEST_STUB_DIR/eng87-lin-log.txt"

# Override the production log function with a body-capturing stub.
# We can't see the full body via the normal log(), so we tap the
# _inject_dispatch_marker invocation directly.
_eng87_test_inject() {
  local body="$1"
  _inject_dispatch_marker "$body"
}

# Case 87-L1: env set → add-comment body carries the marker. Direct
# invocation of _inject_dispatch_marker is the unit-test surface; the
# add_comment wrapper invokes it before the dry-run short-circuit (Task
# 7 placement).
PIPELINE_DISPATCH_ID="ENG-87L-d0007" \
PIPELINE_STAGE="implementing" \
PIPELINE_DRY_RUN=1 \
_eng87_l1_out="$(_eng87_test_inject "agent body line 1")"
if grep -qF '<!-- meta: dispatch id=ENG-87L-d0007 stage=implementing -->' <<<"$_eng87_l1_out"; then
  pass_at "ENG-87 L1: env set → marker appended to body"
else
  fail_at "ENG-87 L1: env set → marker appended to body" \
    "expected marker in body, got: $_eng87_l1_out"
fi

# Case 87-L2: env unset → no injection (operator-manual lane bypass).
unset PIPELINE_DISPATCH_ID
unset PIPELINE_STAGE
_eng87_l2_out="$(_eng87_test_inject "operator-direct comment")"
if [[ "$_eng87_l2_out" == "operator-direct comment" ]]; then
  pass_at "ENG-87 L2: env unset → body unchanged (operator-lane bypass)"
else
  fail_at "ENG-87 L2: env unset → body unchanged" \
    "expected unchanged body, got: $_eng87_l2_out"
fi

# Case 87-L3: idempotent re-apply (body already carries marker).
PIPELINE_DISPATCH_ID="ENG-87L-d0007" \
PIPELINE_STAGE="implementing" \
_eng87_l3_input=$'pre-stamped body line 1\n\n<!-- meta: dispatch id=ENG-87L-d0007 stage=implementing -->'
PIPELINE_DISPATCH_ID="ENG-87L-d0007" \
PIPELINE_STAGE="implementing" \
_eng87_l3_out="$(_eng87_test_inject "$_eng87_l3_input")"
# Count occurrences of the marker — must be exactly one (idempotent).
_eng87_l3_count="$(grep -cF '<!-- meta: dispatch id=ENG-87L-d0007 stage=implementing -->' <<<"$_eng87_l3_out")"
if [[ "$_eng87_l3_count" == "1" ]]; then
  pass_at "ENG-87 L3: re-apply with marker present → exactly one marker (idempotent)"
else
  fail_at "ENG-87 L3: idempotent re-apply" \
    "expected 1 marker, got $_eng87_l3_count occurrences in: $_eng87_l3_out"
fi

# Case 87-L4: dispatch marker AND dedup marker coexist on the same body.
# Plan §Task 10 L4 (Failure-Mode row "Auto-injection breaks dedup-marker
# placement") asserts that `_inject_dispatch_marker` does NOT remove or
# clobber the existing `<!-- meta: dedup key=... -->` footer. Both
# markers must be present after injection.
PIPELINE_DISPATCH_ID="ENG-87L4-d0007" \
PIPELINE_STAGE="implementing" \
_eng87_l4_input=$'completion summary body\n\nmore prose.\n\n<!-- meta: dedup key=completion/implementing/ENG-87L4 -->'
PIPELINE_DISPATCH_ID="ENG-87L4-d0007" \
PIPELINE_STAGE="implementing" \
_eng87_l4_out="$(_eng87_test_inject "$_eng87_l4_input")"
if grep -qF '<!-- meta: dispatch id=ENG-87L4-d0007 stage=implementing -->' <<<"$_eng87_l4_out" \
   && grep -qF '<!-- meta: dedup key=completion/implementing/ENG-87L4 -->' <<<"$_eng87_l4_out"; then
  pass_at "ENG-87 L4: dispatch marker + dedup marker coexist after injection"
else
  fail_at "ENG-87 L4: dispatch + dedup coexistence" "got: $_eng87_l4_out"
fi
unset PIPELINE_DISPATCH_ID PIPELINE_STAGE

# Case 87-L4b: empty PIPELINE_STAGE produces stage="" but still injects.
# Documents env-consistency contract: orchestrator owns env setup; if
# PIPELINE_DISPATCH_ID is set but PIPELINE_STAGE is empty, the marker
# carries `stage=` (empty value). Pins behavior because dispatch.sh
# always sets both, but a future caller might not.
PIPELINE_DISPATCH_ID="ENG-87L4b-d0001" \
PIPELINE_STAGE="" \
_eng87_l4b_out="$(_eng87_test_inject "test body")"
if grep -qF '<!-- meta: dispatch id=ENG-87L4b-d0001 stage= -->' <<<"$_eng87_l4b_out"; then
  pass_at "ENG-87 L4b: env partial (stage empty) → marker still appended with empty stage value"
else
  fail_at "ENG-87 L4b: empty stage value" "got: $_eng87_l4b_out"
fi
unset PIPELINE_DISPATCH_ID PIPELINE_STAGE

# Case 87-L5: integration — call add_comment directly under PIPELINE_DRY_RUN=1
# and assert the captured `[DRY_RUN] would comment` log line shows the
# body ends with `<!-- meta: dispatch id=… -->`. Pins the wiring at
# bin/linear.sh::add_comment (line 507-ish): a future refactor that
# drops `body=$(_inject_dispatch_marker "$body")` would not be caught
# by L1/L3/L4 (those test the helper directly).
_eng87_l5_log="$_TEST_STUB_DIR/eng87-l5-add-comment.log"
: > "$_eng87_l5_log"

# Stub `log` to capture lines into our file (production log writes to
# stderr; we want stdout-style capture for the assertion).
_eng87_l5_orig_log="$(declare -f log 2>/dev/null || printf '')"
log() {
  local m="$*"
  printf '%s\n' "$m" >> "$_eng87_l5_log"
}

# Stub `_resolve_issue_uuid` so add_comment's pre-flight passes without
# hitting Linear (linear-test.sh's existing pattern; see ENG-63 cases).
_eng87_l5_orig_resolve="$(declare -f _resolve_issue_uuid 2>/dev/null || printf '')"
_resolve_issue_uuid() {
  printf 'mock-uuid-eng87-l5'
}
export PIPELINE_DRY_RUN=1
PIPELINE_DISPATCH_ID="ENG-87L5-d0011" \
PIPELINE_STAGE="reviewing" \
add_comment ENG-87L5 "agent body line 1" >/dev/null 2>&1 || true

# Restore original behaviour so subsequent tests are not contaminated.
if [[ -n "$_eng87_l5_orig_log" ]]; then
  unset -f log
  eval "$_eng87_l5_orig_log"
fi
unset -f _resolve_issue_uuid
[[ -n "$_eng87_l5_orig_resolve" ]] && eval "$_eng87_l5_orig_resolve"
unset PIPELINE_DISPATCH_ID PIPELINE_STAGE

# Assert the captured log line shows the marker — confirms add_comment
# threads the body through _inject_dispatch_marker before the dry-run
# short-circuit fires.
if grep -qF '<!-- meta: dispatch id=ENG-87L5-d0011 stage=reviewing -->' "$_eng87_l5_log"; then
  pass_at "ENG-87 L5: add_comment invokes _inject_dispatch_marker (integration)"
else
  fail_at "ENG-87 L5: add_comment integration" \
    "expected dispatch marker in dry-run log, got: $(cat "$_eng87_l5_log")"
fi
rm -f "$_eng87_l5_log"
unset _eng87_l5_log _eng87_l5_orig_log _eng87_l5_orig_resolve

# Case 87-L4-int (review-iter-2 M6): integration test for
# add_or_update_comment — pre-fix, Case-87-L4 only invoked the
# _inject_dispatch_marker helper directly with a hand-crafted body
# containing the dedup marker. That asserts the helper is dedup-marker-
# aware but NOT the production assembly (line 588 inject vs line 597
# dedup-append). A regression that swapped the two assembly steps
# (dedup-append before inject) would silently false-pass L4 because
# the helper invocation is unchanged. This integration test drives
# add_or_update_comment end-to-end under PIPELINE_DRY_RUN=1 and asserts
# both markers appear in the production-written body in the documented
# source-order: dispatch BEFORE dedup.
#
# Two-pronged approach: (a) capture-via-log integration test (uses a
# body short enough that both markers fit in the 80-char truncation
# the dry-run path applies); (b) source-text grep that pins the
# inject-before-dedup ordering directly.
_eng87_l4i_log="$_TEST_STUB_DIR/eng87-l4int.log"
: > "$_eng87_l4i_log"
_eng87_l4i_orig_log="$(declare -f log 2>/dev/null || printf '')"
log() { printf '%s\n' "$*" >> "$_eng87_l4i_log"; }
# Use very short id + sig so both markers fit in the 80-char dry-run
# truncation: body(1) + \n\n(2) + dispatch(46) + \n\n(2) + dedup(26) = 77.
PIPELINE_DISPATCH_ID="ENG-X-d0001" \
PIPELINE_STAGE="ui" \
PIPELINE_DRY_RUN=1 \
add_or_update_comment "t" "ENG-X" "x" >/dev/null 2>&1 || true
unset -f log
[[ -n "$_eng87_l4i_orig_log" ]] && eval "$_eng87_l4i_orig_log"
unset PIPELINE_DISPATCH_ID PIPELINE_STAGE PIPELINE_DRY_RUN
_eng87_l4i_line="$(cat "$_eng87_l4i_log")"
# (a) Both markers present.
if grep -qF '<!-- meta: dispatch id=ENG-X-d0001 stage=ui -->' <<<"$_eng87_l4i_line" \
   && grep -qF '<!-- meta: dedup key=t -->' <<<"$_eng87_l4i_line"; then
  pass_at "ENG-87 L4-int (review-iter-2 M6): add_or_update_comment dry-run carries BOTH dispatch + dedup markers"
else
  fail_at "ENG-87 L4-int: dual-marker presence" "log=$_eng87_l4i_line"
fi
# Source-order: dispatch index < dedup index (dispatch injected first;
# dedup appended last). Production code at lines 588 (inject) and 597
# (append) — pin via byte-position arithmetic.
_eng87_l4i_disp_at="$(grep -nF '<!-- meta: dispatch id=ENG-X-d0001' <<<"$_eng87_l4i_line" | head -1 | cut -d: -f1)"
_eng87_l4i_dedup_at="$(grep -nF '<!-- meta: dedup key=t -->' <<<"$_eng87_l4i_line" | head -1 | cut -d: -f1)"
_eng87_l4i_disp_at="${_eng87_l4i_disp_at:-0}"
_eng87_l4i_dedup_at="${_eng87_l4i_dedup_at:-0}"
if (( _eng87_l4i_disp_at > 0 )) && (( _eng87_l4i_dedup_at > 0 )) \
   && (( _eng87_l4i_disp_at < _eng87_l4i_dedup_at )); then
  pass_at "ENG-87 L4-int (review-iter-2 M6): dispatch marker precedes dedup marker (production source-order preserved)"
else
  fail_at "ENG-87 L4-int: source-order" \
    "disp_at=$_eng87_l4i_disp_at dedup_at=$_eng87_l4i_dedup_at log=$_eng87_l4i_line"
fi
# Source-text pin: linear.sh::add_or_update_comment must call
# _inject_dispatch_marker BEFORE the dedup-marker append. A behavioral
# test alone cannot detect a refactor that re-orders these (because
# both markers would still appear in the body); the source pin closes
# that gap.
_eng87_l4i_src="$SCRIPT_DIR_REAL/linear.sh"
_eng87_l4i_block="$(awk '/^add_or_update_comment\(\)/,/^}/' "$_eng87_l4i_src")"
_eng87_l4i_inject_line="$(grep -n 'body="$(_inject_dispatch_marker' <<<"$_eng87_l4i_block" | head -1 | cut -d: -f1)"
_eng87_l4i_dedup_line="$(grep -n 'body+=\$.\\n\\n.\"\$marker\"' <<<"$_eng87_l4i_block" | head -1 | cut -d: -f1)"
if [[ -z "$_eng87_l4i_dedup_line" ]]; then
  _eng87_l4i_dedup_line="$(grep -n 'body+=' <<<"$_eng87_l4i_block" | head -1 | cut -d: -f1)"
fi
if [[ -n "$_eng87_l4i_inject_line" ]] && [[ -n "$_eng87_l4i_dedup_line" ]] \
   && (( _eng87_l4i_inject_line < _eng87_l4i_dedup_line )); then
  pass_at "ENG-87 L4-int (review-iter-2 M6): linear.sh source-text pins inject-before-dedup ordering"
else
  fail_at "ENG-87 L4-int: source-text order" \
    "inject_line=$_eng87_l4i_inject_line dedup_line=$_eng87_l4i_dedup_line"
fi
rm -f "$_eng87_l4i_log"
unset _eng87_l4i_log _eng87_l4i_orig_log _eng87_l4i_line _eng87_l4i_disp_at _eng87_l4i_dedup_at _eng87_l4i_src _eng87_l4i_block _eng87_l4i_inject_line _eng87_l4i_dedup_line

# ─── ENG-110: agent-lane auto-injection ───────────────────────────────
# Pin the contract that PIPELINE_WRITER=agent does not short-circuit
# _inject_dispatch_marker. The lane fence runs BEFORE the inject
# (bin/linear.sh:505 _check_lane vs line 514 _inject_dispatch_marker
# in add_comment). A regression that swapped the order or gated
# injection on lane would silently false-pass the orchestrator-lane
# tests (Cases 87-L1 / 87-L5) but break agent-lane writes.
printf '\n--- ENG-110: agent-lane auto-injection ---\n'
_eng110_al_log="$_TEST_STUB_DIR/eng110-agent-lane.log"
: > "$_eng110_al_log"
_eng110_al_orig_log="$(declare -f log 2>/dev/null || printf '')"
log() { printf '%s\n' "$*" >> "$_eng110_al_log"; }
_eng110_al_orig_resolve="$(declare -f _resolve_issue_uuid 2>/dev/null || printf '')"
_resolve_issue_uuid() { printf 'mock-uuid-eng110-al'; }
export PIPELINE_DRY_RUN=1
PIPELINE_WRITER=agent \
PIPELINE_DISPATCH_ID="ENG-110A-d0001" \
PIPELINE_STAGE="implementing" \
add_comment ENG-110A "agent body line 1" >/dev/null 2>&1 || true
unset -f log
[[ -n "$_eng110_al_orig_log" ]] && eval "$_eng110_al_orig_log"
unset -f _resolve_issue_uuid
[[ -n "$_eng110_al_orig_resolve" ]] && eval "$_eng110_al_orig_resolve"
unset PIPELINE_WRITER PIPELINE_DISPATCH_ID PIPELINE_STAGE PIPELINE_DRY_RUN
if grep -qF '<!-- meta: dispatch id=ENG-110A-d0001 stage=implementing -->' "$_eng110_al_log"; then
  pass_at "ENG-110 agent-lane: PIPELINE_WRITER=agent does not short-circuit auto-injection"
else
  fail_at "ENG-110 agent-lane: agent-lane marker presence" \
    "expected marker in dry-run log, got: $(cat "$_eng110_al_log")"
fi
rm -f "$_eng110_al_log"
unset _eng110_al_log _eng110_al_orig_log _eng110_al_orig_resolve

# ─── ENG-110: add_comment source-pin parity (mirror L4-int) ───────────
# Case 87-L4-int pinned inject-before-dedup ordering in
# add_or_update_comment via source-text grep (lines 967-979). The
# symmetric refactor risk in add_comment is inject-before-
# PIPELINE_DRY_RUN-short-circuit: a future change that moves
# _inject_dispatch_marker AFTER the `if [[ "${PIPELINE_DRY_RUN:-0}"
# == "1" ]]` branch would silently false-pass under
# PIPELINE_DRY_RUN=1 (the function returns 0 before the inject runs).
# Source-pin closes that gap.
printf '\n--- ENG-110: add_comment source-pin parity ---\n'
_eng110_sp_src="$SCRIPT_DIR_REAL/linear.sh"
_eng110_sp_block="$(awk '/^add_comment\(\)/,/^}/' "$_eng110_sp_src")"
_eng110_sp_inject_line="$(grep -n 'body="$(_inject_dispatch_marker' <<<"$_eng110_sp_block" | head -1 | cut -d: -f1)"
_eng110_sp_dryrun_line="$(grep -n 'PIPELINE_DRY_RUN:-0' <<<"$_eng110_sp_block" | head -1 | cut -d: -f1)"
if [[ -n "$_eng110_sp_inject_line" ]] && [[ -n "$_eng110_sp_dryrun_line" ]] \
   && (( _eng110_sp_inject_line < _eng110_sp_dryrun_line )); then
  pass_at "ENG-110 source-pin: add_comment invokes _inject_dispatch_marker BEFORE PIPELINE_DRY_RUN short-circuit"
else
  fail_at "ENG-110 source-pin: add_comment inject ordering" \
    "inject_line=$_eng110_sp_inject_line dryrun_line=$_eng110_sp_dryrun_line"
fi
unset _eng110_sp_src _eng110_sp_block _eng110_sp_inject_line _eng110_sp_dryrun_line

# ─── ENG-87 QA-adversarial: _inject_dispatch_marker edge cases ────────
# Defensive: relax `set -e` so a single failing `if` predicate (e.g.
# grep returning 1) cannot abort the whole test file early.
set +e

# QA-1 (idempotency false-positive on quoted-marker substring).
# `_inject_dispatch_marker` checks for marker presence via `grep -qF
# '<!-- meta: dispatch id='` against the entire body. If the body
# legitimately *quotes* a prior dispatch's marker (e.g., a halt comment
# diagnosing cross-dispatch staleness, or a fenced code block in
# documentation), the substring match fires → injector skips → real
# trailing marker NEVER appended → reader-side strict id-match path at
# bin/verdict-handler.sh:123 looks for the CURRENT id and finds only
# the quoted PRIOR id → comment filtered out as stale.
#
# This pins the CURRENT (false-positive) behavior so a reader can see
# at-a-glance the gap. A targeted fix should anchor the idempotency
# check to a trailing-on-its-own-line marker (line-anchored regex) so a
# quoted-mid-body marker does NOT defeat injection. Test stays green;
# the operator-visible cost is a follow-up Linear bug citing this case.
printf '\n--- ENG-87 QA-adversarial: marker-injection edges ---\n'
PIPELINE_DISPATCH_ID="ENG-87QA-d0008" \
PIPELINE_STAGE="qa" \
_eng87qa_quoted_body=$'Diagnostic for cross-dispatch staleness:\n\nThe prior cycle posted `<!-- meta: dispatch id=ENG-87QA-d0007 stage=qa -->` (cited here).\n\nMore body text.'
PIPELINE_DISPATCH_ID="ENG-87QA-d0008" \
PIPELINE_STAGE="qa" \
_eng87qa_out="$(_eng87_test_inject "$_eng87qa_quoted_body")"
# Pin current behavior: substring match fires, no current-dispatch
# marker injected. The body still carries ONLY the quoted d0007
# substring; the d0008 marker is absent.
_eng87qa_d8_count="$(grep -cF 'dispatch id=ENG-87QA-d0008' <<<"$_eng87qa_out")"
_eng87qa_d7_count="$(grep -cF 'dispatch id=ENG-87QA-d0007' <<<"$_eng87qa_out")"
# Iter-7 m2 (post-fix): the idempotency check is now CURRENT-id-
# specific (linear.sh::_inject_dispatch_marker matches
# `<!-- meta: dispatch id=$PIPELINE_DISPATCH_ID `). The quoted prior
# d0007 marker no longer satisfies the d0008 check, so injection
# fires and the d0008 marker IS appended; the d0007 quoted prose
# survives unchanged.
if [[ "$_eng87qa_d8_count" == "1" && "$_eng87qa_d7_count" == "1" ]]; then
  pass_at "ENG-87 QA-3 (post-iter-7 m2): quoted prior-dispatch marker no longer defeats current-dispatch injection"
else
  fail_at "ENG-87 QA-3: post-iter-7 m2 idempotency current-id" \
    "expected d0008-count=1 (injected) d0007-count=1 (prose preserved); got d0008=$_eng87qa_d8_count d0007=$_eng87qa_d7_count out: $_eng87qa_out"
fi
unset PIPELINE_DISPATCH_ID PIPELINE_STAGE
unset _eng87qa_quoted_body _eng87qa_out _eng87qa_d8_count _eng87qa_d7_count

# QA-4 (foreign-dispatch update via add_or_update_comment).
# add_or_update_comment finds an in-flight comment under the same
# `meta: dedup key=...` and updates it with a new body. If the existing
# comment carries a *prior* dispatch's `meta: dispatch id=` marker (the
# dedup-found comment was originally posted under d0006), invoking
# add_or_update_comment now under d0009 with a fresh body will:
#   - inject d0009 marker into the new body (current dispatch's stamp)
#   - the orchestrator-side update code path sends the current body
# The test pins that the NEW body posted carries the CURRENT dispatch's
# marker, not the prior one's. (Pre-fix bodies that quoted the OLD
# dispatch id mid-text would have skipped injection — but a clean new
# body posts cleanly under the current id.)
PIPELINE_DISPATCH_ID="ENG-87QA-d0009" \
PIPELINE_STAGE="qa" \
_eng87qa4_clean_body="status update — dispatch context changed since last apply"
PIPELINE_DISPATCH_ID="ENG-87QA-d0009" \
PIPELINE_STAGE="qa" \
_eng87qa4_out="$(_eng87_test_inject "$_eng87qa4_clean_body")"
if grep -qF '<!-- meta: dispatch id=ENG-87QA-d0009 stage=qa -->' <<<"$_eng87qa4_out"; then
  pass_at "ENG-87 QA-4: clean re-apply body under new dispatch_id stamps with current id (no prior-id leak)"
else
  fail_at "ENG-87 QA-4: foreign-dispatch update" \
    "expected current-id stamp, got: $_eng87qa4_out"
fi
unset PIPELINE_DISPATCH_ID PIPELINE_STAGE
unset _eng87qa4_clean_body _eng87qa4_out

# QA-5 (multi-line body with embedded marker-lookalike near end).
# Pin: when the body's last line is the actual marker (correct shape),
# injection skips. When the body's last line LOOKS like a marker but is
# actually e.g. an HTML comment continuing onto the same line ending,
# pin the substring-grep behavior (current). A line-anchored fix would
# distinguish these; documenting current behavior so the contrast is
# visible at fix time.
PIPELINE_DISPATCH_ID="ENG-87QA-d0010" \
PIPELINE_STAGE="implementing" \
_eng87qa5_body="line one\n\n<!-- meta: dispatch id=ENG-87QA-d0010 stage=implementing -->"
PIPELINE_DISPATCH_ID="ENG-87QA-d0010" \
PIPELINE_STAGE="implementing" \
_eng87qa5_out="$(_eng87_test_inject "$_eng87qa5_body")"
_eng87qa5_count="$(grep -cF 'dispatch id=ENG-87QA-d0010' <<<"$_eng87qa5_out")"
if [[ "$_eng87qa5_count" == "1" ]]; then
  pass_at "ENG-87 QA-5: body with single trailing real marker → idempotent (count=1)"
else
  fail_at "ENG-87 QA-5: trailing-marker idempotency" "expected count=1, got: $_eng87qa5_count"
fi
unset PIPELINE_DISPATCH_ID PIPELINE_STAGE
unset _eng87qa5_body _eng87qa5_out _eng87qa5_count

# ─── ENG-87 review-iter-7 Critical 4: reapplied audit + dispatch-id strip ──
# ENG-63's add_or_update_comment byte-equal-modulo-marker arm strips
# `<!-- meta: reapplied at=… -->` lines before comparing existing vs
# new. Post-ENG-87, every comment body now ends with
# `<!-- meta: dispatch id=ENG-N-d<NNNN> stage=… -->` (auto-injected at
# `_inject_dispatch_marker`). Two re-applies of the same logical halt
# body across two different dispatches now carry different dispatch
# markers → existing_norm != new_norm → byte-equal arm never fires → no
# reapplied footer ever appears → metrics.sh comment-reapplied stays at
# zero per re-apply post-cutover. ENG-63's audit signal is silently
# regressed for every halt re-apply. Operator runbook (recovery.md §4)
# instructs grepping `<!-- meta: reapplied at=` to find the latest
# re-apply moment; that signal is now invisible.
#
# Fix: extend strip_re to remove BOTH `reapplied at=` and `dispatch id=`
# lines so byte-equal-modulo-meta-noise normalisation works across
# dispatch-id rotation.
printf '\n--- ENG-87 review-iter-7 Critical 4: reapplied + dispatch-id strip ---\n'

# Re-establish the linear_query stub + capture file used by the ENG-63
# block above (which restored the originals at line ~752). Mirrors the
# pattern from line 530-550.
_iter7_l7_capture="$(mktemp -t eng87-l7-capture.XXXXXX)"
_iter7_l7_canned_existing_body=""
_iter7_l7_canned_existing_id="cmt-mock-l7"
_iter7_l7_orig_linear_query="$(declare -f linear_query 2>/dev/null || true)"
_iter7_l7_orig_resolve_uuid="$(declare -f _resolve_issue_uuid 2>/dev/null || true)"
_iter7_l7_orig_dry_run="${PIPELINE_DRY_RUN-1}"
_iter7_l7_orig_script_dir="$SCRIPT_DIR"
SCRIPT_DIR="$SCRIPT_DIR_REAL"
_resolve_issue_uuid() { printf 'uuid-mock'; }
linear_query() {
  local query="$1" variables="${2:-{\}}"
  if [[ "$query" =~ commentUpdate ]]; then
    jq -r '.body' <<<"$variables" >> "$_iter7_l7_capture"
    printf '{"data":{"commentUpdate":{"success":true}}}\n'
    return 0
  fi
  if [[ "$query" =~ commentCreate ]]; then
    jq -r '.body' <<<"$variables" >> "$_iter7_l7_capture"
    printf '{"data":{"commentCreate":{"success":true}}}\n'
    return 0
  fi
  jq -cn --arg id "$_iter7_l7_canned_existing_id" --arg body "$_iter7_l7_canned_existing_body" \
    '{data:{issue:{comments:{nodes:[{id:$id,body:$body}]}}}}'
}
export PIPELINE_DRY_RUN=0

# Case 87-L7-reapplied-audit: same byte body across two dispatches → footer.
# Stub returns existing body whose body BYTES match the caller body BYTES
# in everything except the trailing dispatch-id marker (auto-injected by
# the prior dispatch). Post-fix: strip both noise lines → norms equal →
# byte-equal arm fires → reapplied footer appended.
: > "$_iter7_l7_capture"
_iter7_l7_canned_existing_body=$'Halt body line 1\nHalt body line 2\n\n<!-- meta: dedup key=halt/reviewing/ENG-87L7 -->\n<!-- meta: dispatch id=ENG-87L7-d0007 stage=reviewing -->'
PIPELINE_DISPATCH_ID="ENG-87L7-d0008" \
PIPELINE_STAGE="reviewing" \
add_or_update_comment "halt/reviewing/ENG-87L7" ENG-87L7 \
  --body $'Halt body line 1\nHalt body line 2\n\n<!-- meta: dedup key=halt/reviewing/ENG-87L7 -->' \
  >/dev/null 2>&1
if grep -qE '^<!-- meta: reapplied at=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z -->$' "$_iter7_l7_capture"; then
  pass_at "ENG-87 L7 reapplied-audit: same body across dispatches → reapplied footer appended"
else
  fail_at "ENG-87 L7 reapplied-audit: footer appended" \
    "captured: $(cat "$_iter7_l7_capture") — strip_re must remove both 'reapplied at=' AND 'dispatch id=' lines so byte-equal arm fires across dispatch_id rotation"
fi
unset PIPELINE_DISPATCH_ID PIPELINE_STAGE

# Restore originals before continuing (the L8 case below reads
# _inject_dispatch_marker directly, no stub needed).
rm -f "$_iter7_l7_capture"
unset -f linear_query _resolve_issue_uuid 2>/dev/null || true
[[ -n "$_iter7_l7_orig_linear_query" ]] && eval "$_iter7_l7_orig_linear_query"
[[ -n "$_iter7_l7_orig_resolve_uuid" ]] && eval "$_iter7_l7_orig_resolve_uuid"
export PIPELINE_DRY_RUN="$_iter7_l7_orig_dry_run"
SCRIPT_DIR="$_iter7_l7_orig_script_dir"
unset _iter7_l7_capture _iter7_l7_canned_existing_body _iter7_l7_canned_existing_id \
      _iter7_l7_orig_linear_query _iter7_l7_orig_resolve_uuid \
      _iter7_l7_orig_dry_run _iter7_l7_orig_script_dir

# Case 87-L8-idempotency-current-id: a body carrying a STALE dispatch
# marker (from a prior dispatch) should NOT short-circuit injection of
# the current marker. Pre-fix: `_inject_dispatch_marker`'s idempotency
# check `grep -qF '<!-- meta: dispatch id='` matches ANY marker, even
# a stale one — re-apply preserves the stale marker, the strict-id
# reader filters the comment OUT, and the operator-visible marker
# disagrees with the freshness rule. Post-fix: idempotency check must
# match the CURRENT id specifically.
printf '\n--- ENG-87 L8 idempotency: current-id-specific check ---\n'

# Use the existing _eng87_test_inject helper from linear-test.sh's
# ENG-87 section. The helper invokes _inject_dispatch_marker directly.
PIPELINE_DISPATCH_ID="ENG-87L8-d0099" \
PIPELINE_STAGE="implementing" \
_eng87_l8_input=$'body line 1\n\n<!-- meta: dispatch id=ENG-87L8-d0050 stage=reviewing -->'
PIPELINE_DISPATCH_ID="ENG-87L8-d0099" \
PIPELINE_STAGE="implementing" \
_eng87_l8_out="$(_eng87_test_inject "$_eng87_l8_input")"
# Post-fix invariant: the current marker (d0099) should now be present
# in addition to the stale one (d0050). Pre-fix: only d0050 present.
if grep -qF '<!-- meta: dispatch id=ENG-87L8-d0099 stage=implementing -->' <<<"$_eng87_l8_out"; then
  pass_at "ENG-87 L8 idempotency: stale marker on body → new marker still injected (current-id-specific check)"
else
  fail_at "ENG-87 L8 idempotency: new marker injected" \
    "expected d0099 marker appended despite stale d0050 already present, got: $_eng87_l8_out — idempotency check must look for the CURRENT \$PIPELINE_DISPATCH_ID, not any dispatch id= prefix"
fi
unset PIPELINE_DISPATCH_ID PIPELINE_STAGE _eng87_l8_input _eng87_l8_out

# ─── Summary ────────────────────────────────────────────────────────────
printf '\nRESULTS: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]] || exit 1
exit 0

# Sentinel — allows sourcing without running main.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
