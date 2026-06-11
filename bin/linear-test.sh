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

# agent adding other_comment should be allowed (dry-run returns 0).
# Agents ALWAYS run with the dispatch env set (run-stage exports
# PIPELINE_DISPATCH_ID + PIPELINE_STAGE); _render_event_header (ENG-151 D-006)
# now requires both on the agent lane and fail-closes (rc=15) without them.
# Set them here so the test asserts the real production contract rather than
# passing only because an ambient dispatch env happens to leak in.
rc=0
PIPELINE_WRITER=agent PIPELINE_DISPATCH_ID=ENG-99-d0001 PIPELINE_STAGE=implementing \
  add_comment "ENG-99" "Stage summary text here." 2>/dev/null || rc=$?
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

# ─── ENG-55: _resolve_body_arg + add-comment body shapes ────────────
# `add-comment` accepts body via:
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

# add_comment --sig with --body - reads stdin and reaches dry-run.
out="$(printf 'aouc-stdin-marker' | add_comment ENG-55T --sig "test/sig/ENG-55T" --body - 2>&1)"
printf '%s' "$out" | grep -qF "aouc-stdin-marker" \
  && pass_at "ENG-55 add_comment --sig: --body - reads stdin in dry-run path" \
  || fail_at "ENG-55 add_comment --sig: --body -" "out=$out"

# add_comment --sig legacy positional body still works.
out="$(add_comment ENG-55T --sig "test/sig/ENG-55T" "legacy-positional-marker" 2>&1)"
printf '%s' "$out" | grep -qF "legacy-positional-marker" \
  && pass_at "ENG-55 add_comment --sig: legacy positional body still works" \
  || fail_at "ENG-55 add_comment --sig: legacy positional" "out=$out"

# add_comment --sig with empty body dies.
rc=0
err="$(add_comment ENG-55T --sig "test/sig/ENG-55T" 2>&1)" || rc=$?
[[ "$rc" -ne 0 ]] && printf '%s' "$err" | grep -qF "body is empty" \
  && pass_at "ENG-55 add_comment --sig: empty body dies cleanly" \
  || fail_at "ENG-55 add_comment --sig: empty body" "rc=$rc err=$err"

# ─── ENG-151: header line on every harness-written comment (H-001..H-013) ──
# bin/linear.sh::add_comment auto-prepends a
# two-line canonical header (`[<ident> · <stage> · <dispatch-tail> ·
# <iso-ts> · <actor>]\n<EVENT-TYPE> — <summary>`) for every non-human
# writer.  Tests pin the per-event-type derivation, the human-lane
# bypass (D-005), the agent-lane fail-closed on missing dispatch
# context (D-006), the agent-lane hand-rolled-header rejection
# (D-009-b), the strip_re byte-equal-modulo-header normalisation
# (D-007), and the source-of-truth centralisation (AC #2).
printf '\n--- ENG-151: header line ---\n'

_eng151_orig_linear_query="$(declare -f linear_query)"
_eng151_orig_resolve_uuid="$(declare -f _resolve_issue_uuid)"
_eng151_orig_dry_run="$PIPELINE_DRY_RUN"
_eng151_orig_script_dir="$SCRIPT_DIR"

SCRIPT_DIR="$SCRIPT_DIR_REAL"

_resolve_issue_uuid() { printf 'uuid-mock'; }

_eng151_capture_file="$(mktemp -t eng151-capture.XXXXXX)"
_eng151_canned_existing_body=""
_eng151_canned_existing_id="cmt-mock-001"
_eng151_canned_existing_url=""

linear_query() {
  local query="$1" variables="${2:-{\}}"
  if [[ "$query" =~ commentUpdate ]]; then
    jq -r '.body' <<<"$variables" >> "$_eng151_capture_file"
    printf '{"data":{"commentUpdate":{"success":true}}}\n'
    return 0
  fi
  if [[ "$query" =~ commentCreate ]]; then
    jq -r '.body' <<<"$variables" >> "$_eng151_capture_file"
    printf '{"data":{"commentCreate":{"success":true}}}\n'
    return 0
  fi
  jq -cn --arg id "$_eng151_canned_existing_id" \
         --arg body "$_eng151_canned_existing_body" \
         --arg url "$_eng151_canned_existing_url" \
    '{data:{issue:{comments:{nodes:[{id:$id,body:$body,url:$url}]}}}}'
}

export PIPELINE_DRY_RUN=0
mkdir -p "$PROJECT_STATE_DIR/metrics"
: > "$PROJECT_STATE_DIR/metrics/events.jsonl"

# H-001: verdict.pass under agent lane → canonical bracket line + PASS
# event-type line.  The body carries `<!-- pipeline: verdict result=pass
# stage=brainstorming -->`; P2 derivation in _derive_event_type_and_summary
# extracts the stage and emits `PASS\tstage brainstorming complete`.
: > "$_eng151_capture_file"
_eng151_canned_existing_body=""
PIPELINE_WRITER=agent \
PIPELINE_DISPATCH_ID=ENG-151T-d0001 \
PIPELINE_STAGE=brainstorming \
  add_comment ENG-151T --body '<!-- pipeline: verdict result=pass stage=brainstorming -->' \
  >/dev/null 2>&1
if grep -qE '^\[ENG-151T · brainstorming · d0001 · [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z · agent\]$' "$_eng151_capture_file" \
   && grep -qF 'PASS — stage brainstorming complete' "$_eng151_capture_file"; then
  pass_at "ENG-151 H-001 verdict.pass → canonical bracket + PASS line"
else
  fail_at "ENG-151 H-001 verdict.pass → canonical bracket + PASS line" \
    "captured: $(cat "$_eng151_capture_file")"
fi
unset PIPELINE_WRITER PIPELINE_DISPATCH_ID PIPELINE_STAGE

# H-002: verdict.halt → HALT — <reason>.  P2 derivation extracts the
# `reason=` token from the halt marker.
: > "$_eng151_capture_file"
PIPELINE_WRITER=agent \
PIPELINE_DISPATCH_ID=ENG-151T-d0002 \
PIPELINE_STAGE=implementing \
  add_comment ENG-151T --body '<!-- pipeline: verdict result=halt reason=scope-violation -->' \
  >/dev/null 2>&1
if grep -qE '^\[ENG-151T · implementing · d0002 · .* · agent\]$' "$_eng151_capture_file" \
   && grep -qF 'HALT — scope-violation' "$_eng151_capture_file"; then
  pass_at "ENG-151 H-002 verdict.halt → HALT — scope-violation"
else
  fail_at "ENG-151 H-002 verdict.halt → HALT — scope-violation" \
    "captured: $(cat "$_eng151_capture_file")"
fi
unset PIPELINE_WRITER PIPELINE_DISPATCH_ID PIPELINE_STAGE

# H-003 / H-004 deleted in ENG-150: cases exercised the retired
# upsert lane (retired in ENG-150).  Sig-derivation under the new
# add_comment --sig chokepoint is covered by ENG-150 A-001 below.

# H-005: counter-bump (`<!-- meta: metric name=… -->` marker) → P3
# derivation emits `COUNTER-BUMP — <metric-name>`.
: > "$_eng151_capture_file"
_eng151_canned_existing_body=""
PIPELINE_WRITER=agent \
PIPELINE_DISPATCH_ID=ENG-151T-d0005 \
PIPELINE_STAGE=reviewing \
  add_comment ENG-151T --body '<!-- meta: metric name=review_rejection --> Counter bumped' \
  >/dev/null 2>&1
if grep -qF 'COUNTER-BUMP — review_rejection' "$_eng151_capture_file"; then
  pass_at "ENG-151 H-005 counter-bump → COUNTER-BUMP — review_rejection"
else
  fail_at "ENG-151 H-005 counter-bump → COUNTER-BUMP — review_rejection" \
    "captured: $(cat "$_eng151_capture_file")"
fi
unset PIPELINE_WRITER PIPELINE_DISPATCH_ID PIPELINE_STAGE

# H-006 / H-007 deleted in ENG-150: cases exercised the retired
# upsert lane (retired in ENG-150).  Sig-derivation under the new
# add_comment --sig chokepoint is covered by ENG-150 A-001 below.

# H-008: agent-lane fail-closed (D-006) — missing PIPELINE_DISPATCH_ID
# AND/OR missing PIPELINE_STAGE under PIPELINE_WRITER=agent causes
# _render_event_header to exit 15; the chokepoint propagates.  Stderr
# carries the documented diagnostic.
: > "$_eng151_capture_file"
_eng151_h8_stderr="$(mktemp -t eng151-h8.XXXXXX)"
_eng151_h8_rc=0
PIPELINE_WRITER=agent \
PIPELINE_DISPATCH_ID= \
PIPELINE_STAGE= \
  add_comment ENG-151T --body 'x' \
  >/dev/null 2>"$_eng151_h8_stderr" || _eng151_h8_rc=$?
if [[ "$_eng151_h8_rc" == "15" ]] \
   && grep -qF 'agent-lane comment missing header inputs' "$_eng151_h8_stderr"; then
  pass_at "ENG-151 H-008 agent fail-closed missing inputs → rc=15"
else
  fail_at "ENG-151 H-008 agent fail-closed missing inputs → rc=15" \
    "rc=$_eng151_h8_rc stderr=$(cat "$_eng151_h8_stderr")"
fi
rm -f "$_eng151_h8_stderr"
unset PIPELINE_WRITER PIPELINE_DISPATCH_ID PIPELINE_STAGE _eng151_h8_stderr _eng151_h8_rc

# H-009: human lane bypass (D-005) — PIPELINE_WRITER=human skips header
# injection entirely; captured body starts with the caller's prose, not
# with a bracket line.
: > "$_eng151_capture_file"
_eng151_canned_existing_body=""
PIPELINE_WRITER=human \
  add_comment ENG-151T --body 'operator note' \
  >/dev/null 2>&1
_eng151_h9_first_char="$(head -c 1 "$_eng151_capture_file" || true)"
if [[ "$_eng151_h9_first_char" != "[" ]] \
   && grep -qF 'operator note' "$_eng151_capture_file"; then
  pass_at "ENG-151 H-009 human lane bypass → no header line"
else
  fail_at "ENG-151 H-009 human lane bypass → no header line" \
    "first_char='$_eng151_h9_first_char' captured: $(cat "$_eng151_capture_file")"
fi
unset PIPELINE_WRITER _eng151_h9_first_char

# H-010 deleted in ENG-150: case exercised the retired upsert lane's
# reapply-path header preservation (retired in ENG-150).  Append-only
# writes have no reapply path.


# H-011: source-of-truth centralisation (AC #2) — the canonical
# ` · agent` / ` · orchestrator` header glyph pattern must appear only
# in linear.sh (helper) and linear-test.sh (this file).  Any leakage
# into another bin/* file indicates a copy-paste of the format outside
# the chokepoint.
_eng151_h11_out="$(grep -rn ' · orchestrator\| · agent' "$SCRIPT_DIR_REAL" 2>/dev/null \
  | grep -v -e linear-test.sh -e linear.sh || true)"
if [[ -z "$_eng151_h11_out" ]]; then
  pass_at "ENG-151 H-011 grep-source-of-truth → no leakage outside linear.sh/linear-test.sh"
else
  fail_at "ENG-151 H-011 grep-source-of-truth → no leakage outside linear.sh/linear-test.sh" \
    "unexpected matches: $_eng151_h11_out"
fi
unset _eng151_h11_out

# H-012: agent header-spoof rejected (D-009-b) — body whose first
# non-blank line matches `^\[ENG-[0-9]+ · ` under PIPELINE_WRITER=agent
# is rejected with rc=14 and a structured stderr.  Mirrors the
# _reject_legacy_marker_body diagnostic pattern (same exit-code class
# in failure_outcome_for_exit: `legacy-marker-write`).
: > "$_eng151_capture_file"
_eng151_h12_stderr="$(mktemp -t eng151-h12.XXXXXX)"
_eng151_h12_rc=0
PIPELINE_WRITER=agent \
PIPELINE_DISPATCH_ID=ENG-151T-d0012 \
PIPELINE_STAGE=brainstorming \
  add_comment ENG-151T --body $'[ENG-151T · brainstorming · d0001 · 2026-05-20T10:00:00Z · orchestrator]\nfake header\nbody' \
  >/dev/null 2>"$_eng151_h12_stderr" || _eng151_h12_rc=$?
if [[ "$_eng151_h12_rc" == "14" ]] \
   && grep -qF 'agent-lane comment carries hand-rolled header line — rejected' "$_eng151_h12_stderr"; then
  pass_at "ENG-151 H-012 agent header-spoof rejected → rc=14"
else
  fail_at "ENG-151 H-012 agent header-spoof rejected → rc=14" \
    "rc=$_eng151_h12_rc stderr=$(cat "$_eng151_h12_stderr")"
fi
rm -f "$_eng151_h12_stderr"
unset PIPELINE_WRITER PIPELINE_DISPATCH_ID PIPELINE_STAGE _eng151_h12_stderr _eng151_h12_rc

# H-013: orchestrator manual header silently allowed — same body as
# H-012 under PIPELINE_WRITER=orchestrator.  Detective only fires on
# agent lane; canonical header is prepended above the manual one
# (two bracket lines visible to the operator, no rejection).
: > "$_eng151_capture_file"
_eng151_canned_existing_body=""
_eng151_h13_rc=0
PIPELINE_WRITER=orchestrator \
PIPELINE_DISPATCH_ID=ENG-151T-d0013 \
PIPELINE_STAGE=brainstorming \
  add_comment ENG-151T --body $'[ENG-151T · brainstorming · d0001 · 2026-05-20T10:00:00Z · orchestrator]\nfake header\nbody' \
  >/dev/null 2>&1 || _eng151_h13_rc=$?
_eng151_h13_bracket_count="$(grep -cE '^\[ENG-151T · brainstorming · d[0-9]+ · .* · (orchestrator|agent)\]$' "$_eng151_capture_file" || true)"
if [[ "$_eng151_h13_rc" == "0" && "$_eng151_h13_bracket_count" -ge 2 ]]; then
  pass_at "ENG-151 H-013 orchestrator manual header silently allowed → canonical above hand-rolled"
else
  fail_at "ENG-151 H-013 orchestrator manual header silently allowed → canonical above hand-rolled" \
    "rc=$_eng151_h13_rc bracket_count=$_eng151_h13_bracket_count captured: $(cat "$_eng151_capture_file")"
fi
unset PIPELINE_WRITER PIPELINE_DISPATCH_ID PIPELINE_STAGE _eng151_h13_rc _eng151_h13_bracket_count

# QA-ADV-H014: malformed PIPELINE_DISPATCH_ID (no -(d[0-9]+)$ suffix) emits
# verbatim bleed (visible-bug surface per plan) — NOT silently swallowed as `-`
# and NOT rejected with rc=15 (only agent+missing-env trips rc=15).
: > "$_eng151_capture_file"
_eng151_canned_existing_body=""
_eng151_adv_h14_rc=0
PIPELINE_WRITER=agent \
PIPELINE_DISPATCH_ID=ENG-151T-implementing \
PIPELINE_STAGE=implementing \
  add_comment ENG-151T --body 'probe body' \
  >/dev/null 2>&1 || _eng151_adv_h14_rc=$?
# rc=0 (not rc=15 — malformed id does not trigger fail-closed)
# capture carries the full malformed dispatch_id verbatim in the bracket line.
if [[ "$_eng151_adv_h14_rc" == "0" ]] \
   && grep -qE '^\[ENG-151T · implementing · ENG-151T-implementing · .* · agent\]$' "$_eng151_capture_file"; then
  pass_at "ENG-151 QA-ADV-H014 malformed dispatch_id → verbatim bleed, rc=0"
else
  fail_at "ENG-151 QA-ADV-H014 malformed dispatch_id → verbatim bleed, rc=0" \
    "rc=$_eng151_adv_h14_rc captured: $(cat "$_eng151_capture_file")"
fi
unset PIPELINE_WRITER PIPELINE_DISPATCH_ID PIPELINE_STAGE _eng151_adv_h14_rc

# QA-ADV-H018: _derive P4 fallback when body contains only HTML comment lines
# (no prose, no recognised pipeline/meta marker) → second line of header is
# `COMMENT — (no body)`.  Defensive against empty-string or crash on
# meta-only bodies (e.g. a comment that is just dispatch + dedup markers).
: > "$_eng151_capture_file"
_eng151_canned_existing_body=""
PIPELINE_WRITER=orchestrator \
PIPELINE_DISPATCH_ID=ENG-151T-d0018 \
PIPELINE_STAGE=implementing \
  add_comment ENG-151T \
  --body $'<!-- meta: dispatch id=ENG-151T-d0001 stage=implementing -->\n<!-- meta: dedup key=completion/implementing/ENG-151T -->' \
  >/dev/null 2>&1
if grep -qF 'COMMENT — (no body)' "$_eng151_capture_file"; then
  pass_at "ENG-151 QA-ADV-H018 P4 fallback meta-only body → COMMENT — (no body)"
else
  fail_at "ENG-151 QA-ADV-H018 P4 fallback meta-only body → COMMENT — (no body)" \
    "captured: $(cat "$_eng151_capture_file")"
fi
unset PIPELINE_WRITER PIPELINE_DISPATCH_ID PIPELINE_STAGE

# QA-ADV-H019: classify lane with missing PIPELINE_DISPATCH_ID + PIPELINE_STAGE
# degrades to `-` placeholders — does NOT return rc=15 (rc=15 is agent-lane
# only per D-006).  Guards that the agent-specific fail-closed gate does not
# bleed into the classify lane.
: > "$_eng151_capture_file"
_eng151_canned_existing_body=""
_eng151_adv_h19_rc=0
_eng151_adv_h19_dispatch_saved="${PIPELINE_DISPATCH_ID-}"
_eng151_adv_h19_stage_saved="${PIPELINE_STAGE-}"
unset PIPELINE_DISPATCH_ID PIPELINE_STAGE
PIPELINE_WRITER=classify \
  add_comment ENG-151T --body 'Agent was halted for exceeding retry limit.' \
  >/dev/null 2>&1 || _eng151_adv_h19_rc=$?
if [[ "$_eng151_adv_h19_rc" == "0" ]] \
   && grep -qE '^\[ENG-151T · - · - · .* · classify\]$' "$_eng151_capture_file"; then
  pass_at "ENG-151 QA-ADV-H019 classify lane missing env → '-' placeholders, rc=0"
else
  fail_at "ENG-151 QA-ADV-H019 classify lane missing env → '-' placeholders, rc=0" \
    "rc=$_eng151_adv_h19_rc captured: $(cat "$_eng151_capture_file")"
fi
# Restore
[[ -n "$_eng151_adv_h19_dispatch_saved" ]] && export PIPELINE_DISPATCH_ID="$_eng151_adv_h19_dispatch_saved" || true
[[ -n "$_eng151_adv_h19_stage_saved" ]] && export PIPELINE_STAGE="$_eng151_adv_h19_stage_saved" || true
unset PIPELINE_WRITER _eng151_adv_h19_rc _eng151_adv_h19_dispatch_saved _eng151_adv_h19_stage_saved

# QA-ADV-COMMON15: failure_outcome_for_exit 15 → 'header-missing-inputs'
# (new arm added to bin/common.sh in Task 6).  Guards that the exit-code
# taxonomy correctly maps rc=15 so the retrospective §1 filter classifies
# agent-lane missing-input failures, not routing them to unknown-exit-15.
_eng151_adv_c15_out="$(failure_outcome_for_exit 15)"
if [[ "$_eng151_adv_c15_out" == "header-missing-inputs" ]]; then
  pass_at "ENG-151 QA-ADV-COMMON15 failure_outcome_for_exit 15 → header-missing-inputs"
else
  fail_at "ENG-151 QA-ADV-COMMON15 failure_outcome_for_exit 15 → header-missing-inputs" \
    "got: $_eng151_adv_c15_out"
fi
unset _eng151_adv_c15_out

# H-017 deleted in ENG-150: case pinned the retired upsert lane's
# reapply-path bracket-header preservation (retired in ENG-150).
# Append-only writes have no reapply path.

# QA-ADV-H020: _derive P3 BREADCRUMB path — body carries breadcrumb marker;
# sig is empty so P1 does not fire; P3 captures the sig verbatim.
_eng151_h020_et='' _eng151_h020_sm=''
IFS=$'\t' read -r _eng151_h020_et _eng151_h020_sm \
  < <(_derive_event_type_and_summary \
        '<!-- meta: breadcrumb sig=halt/implementing/ENG-151T -->' '')
if [[ "$_eng151_h020_et" == 'BREADCRUMB' \
   && "$_eng151_h020_sm" == 're-emit of halt/implementing/ENG-151T' ]]; then
  pass_at "ENG-151 QA-ADV-H020 P3 BREADCRUMB derivation → BREADCRUMB — re-emit of halt/implementing/ENG-151T"
else
  fail_at "ENG-151 QA-ADV-H020 P3 BREADCRUMB derivation → BREADCRUMB — re-emit of halt/implementing/ENG-151T" \
    "got type='$_eng151_h020_et' summary='$_eng151_h020_sm'"
fi
unset _eng151_h020_et _eng151_h020_sm

# QA-ADV-H021: _derive P3 FORENSIC path — body carries forensic marker.
_eng151_h021_et='' _eng151_h021_sm=''
IFS=$'\t' read -r _eng151_h021_et _eng151_h021_sm \
  < <(_derive_event_type_and_summary \
        '<!-- meta: forensic kind=cross-dispatch -->' '')
if [[ "$_eng151_h021_et" == 'FORENSIC' \
   && "$_eng151_h021_sm" == 'cross-dispatch' ]]; then
  pass_at "ENG-151 QA-ADV-H021 P3 FORENSIC derivation → FORENSIC — cross-dispatch"
else
  fail_at "ENG-151 QA-ADV-H021 P3 FORENSIC derivation → FORENSIC — cross-dispatch" \
    "got type='$_eng151_h021_et' summary='$_eng151_h021_sm'"
fi
unset _eng151_h021_et _eng151_h021_sm

# Restore originals.
rm -f "$_eng151_capture_file"
unset -f linear_query _resolve_issue_uuid
eval "$_eng151_orig_linear_query"
eval "$_eng151_orig_resolve_uuid"
export PIPELINE_DRY_RUN="$_eng151_orig_dry_run"
SCRIPT_DIR="$_eng151_orig_script_dir"
unset _eng151_orig_linear_query _eng151_orig_resolve_uuid _eng151_orig_dry_run \
      _eng151_orig_script_dir _eng151_capture_file _eng151_canned_existing_body \
      _eng151_canned_existing_id _eng151_canned_existing_url

# ─── ENG-87: dispatch_id auto-injection in add_comment ───────────────
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
# PIPELINE_WRITER=human bypasses ENG-151's header injection so the
# 80-char dry-run log truncation window still captures the dispatch
# marker.  Test intent is lane-agnostic ("does add_comment thread the
# body through _inject_dispatch_marker before the dry-run short-
# circuit?"); human lane still runs _inject_dispatch_marker.
PIPELINE_WRITER=human \
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

# Case 87-L4-int deleted in ENG-150: exercised the retired upsert
# lane's inject-before-dedup ordering (retired in ENG-150).  The new
# chokepoint (add_comment --sig) carries the equivalent assembly (Task 1
# places the dedup-marker append AFTER _inject_dispatch_marker) and is
# covered by ENG-150 A-001 below.

# ─── ENG-150: append-only ledger writes (A-001..A-009) ────────────────
# Post-cutover, every "canonical comment per logical event" write
# (halt, completion, protocol-violation, worktree-mutation,
# retry-pending, last-review-state, core-bare-flip) goes through
# `add_comment <issue> --sig <category>/<stage>/<issue>`.  The
# chokepoint suffixes `/d<NNNN>` (from PIPELINE_DISPATCH_ID) and
# appends `<!-- meta: dedup key=<full-sig> -->`.  Every emission posts
# a fresh chronological comment; the pre-ENG-150 sig-based commentUpdate
# is gone (deleted in Task 3).  These cases pin the contract.
printf '\n--- ENG-150: append-only ledger writes ---\n'

_eng150_orig_linear_query="$(declare -f linear_query 2>/dev/null || printf '')"
_eng150_orig_resolve_uuid="$(declare -f _resolve_issue_uuid 2>/dev/null || printf '')"
_eng150_orig_log="$(declare -f log 2>/dev/null || printf '')"
_eng150_orig_dry_run="${PIPELINE_DRY_RUN-1}"
_eng150_orig_script_dir="$SCRIPT_DIR"
SCRIPT_DIR="$SCRIPT_DIR_REAL"
_eng150_log="$_TEST_STUB_DIR/eng150.log"
: > "$_eng150_log"
log() { printf '%s\n' "$*" >> "$_eng150_log"; }

# A-001: --sig with PIPELINE_DISPATCH_ID set under dry-run carries BOTH
# the dispatch marker (auto-injected) AND the dispatch-suffixed dedup
# marker.  Also pins the ENG-151 header derivation under the new sig
# path: P1 sig-derivation emits `HALT — stage implementing halt`.
: > "$_eng150_log"
PIPELINE_DRY_RUN=1 \
PIPELINE_WRITER=agent \
PIPELINE_DISPATCH_ID=ENG-X-d0007 \
PIPELINE_STAGE=implementing \
  add_comment ENG-X --sig "halt/implementing/ENG-X" --body "halt body" >/dev/null 2>&1
_eng150_a001="$(cat "$_eng150_log")"
if grep -qF '<!-- meta: dispatch id=ENG-X-d0007 stage=implementing -->' <<<"$_eng150_a001" \
   && grep -qF '<!-- meta: dedup key=halt/implementing/ENG-X/d0007 -->' <<<"$_eng150_a001" \
   && grep -qF 'HALT — stage implementing halt' <<<"$_eng150_a001"; then
  pass_at "ENG-150 A-001 --sig + PIPELINE_DISPATCH_ID → suffixed dedup marker + dispatch marker + HALT header"
else
  fail_at "ENG-150 A-001 --sig + PIPELINE_DISPATCH_ID" "captured: $_eng150_a001"
fi
unset PIPELINE_DRY_RUN PIPELINE_WRITER PIPELINE_DISPATCH_ID PIPELINE_STAGE

# A-002: --sig with PIPELINE_DISPATCH_ID UNSET → sig collapses to legacy
# shape (no `/d<NNNN>` suffix); no dispatch marker.
: > "$_eng150_log"
PIPELINE_DRY_RUN=1 \
  add_comment ENG-X --sig "halt/implementing/ENG-X" --body "halt body" >/dev/null 2>&1
_eng150_a002="$(cat "$_eng150_log")"
if grep -qF '<!-- meta: dedup key=halt/implementing/ENG-X -->' <<<"$_eng150_a002" \
   && ! grep -qF '<!-- meta: dispatch id=' <<<"$_eng150_a002" \
   && ! grep -qE 'dedup key=halt/implementing/ENG-X/d[0-9]' <<<"$_eng150_a002"; then
  pass_at "ENG-150 A-002 --sig + PIPELINE_DISPATCH_ID unset → legacy-shape sig, no dispatch marker"
else
  fail_at "ENG-150 A-002 --sig + PIPELINE_DISPATCH_ID unset" "captured: $_eng150_a002"
fi
unset PIPELINE_DRY_RUN

# A-003: two distinct dispatches under the same sig produce TWO distinct
# commentCreate calls (no commentUpdate).  Verifies AC #2 — the
# append-only ledger semantic.
_eng150_capture_a3="$(mktemp -t eng150-a3.XXXXXX)"
_resolve_issue_uuid() { printf 'uuid-mock-a3'; }
linear_query() {
  local query="$1" variables="${2:-{\}}"
  # commentUpdate arm is a tripwire: post-ENG-150 the chokepoint must
  # NEVER emit commentUpdate. Any UPDATE row in $_eng150_capture_a3
  # fails the AC #2 (append-only) assertion below.
  if [[ "$query" =~ commentUpdate ]]; then
    printf 'UPDATE %s\n' "$(jq -r '.body' <<<"$variables")" >> "$_eng150_capture_a3"
    printf '{"data":{"commentUpdate":{"success":true}}}\n'
    return 0
  fi
  if [[ "$query" =~ commentCreate ]]; then
    printf 'CREATE %s\n' "$(jq -r '.body' <<<"$variables")" >> "$_eng150_capture_a3"
    printf '{"data":{"commentCreate":{"success":true}}}\n'
    return 0
  fi
  jq -cn '{data:{issue:{comments:{nodes:[]}}}}'
}
export PIPELINE_DRY_RUN=0
: > "$_eng150_capture_a3"
PIPELINE_WRITER=agent PIPELINE_DISPATCH_ID=ENG-X-d0007 PIPELINE_STAGE=implementing \
  add_comment ENG-X --sig "halt/implementing/ENG-X" --body "halt body" >/dev/null 2>&1
PIPELINE_WRITER=agent PIPELINE_DISPATCH_ID=ENG-X-d0008 PIPELINE_STAGE=implementing \
  add_comment ENG-X --sig "halt/implementing/ENG-X" --body "halt body v2" >/dev/null 2>&1
_eng150_a3_create_count="$(grep -c '^CREATE ' "$_eng150_capture_a3" || true)"
_eng150_a3_update_count="$(grep -c '^UPDATE ' "$_eng150_capture_a3" || true)"
if [[ "$_eng150_a3_create_count" == "2" && "$_eng150_a3_update_count" == "0" ]]; then
  pass_at "ENG-150 A-003 two distinct dispatches → TWO commentCreate, zero commentUpdate (append-only)"
else
  fail_at "ENG-150 A-003 two distinct dispatches → append-only" \
    "create=$_eng150_a3_create_count update=$_eng150_a3_update_count captured: $(cat "$_eng150_capture_a3")"
fi
unset PIPELINE_WRITER PIPELINE_DISPATCH_ID PIPELINE_STAGE
rm -f "$_eng150_capture_a3"

# A-004: same dispatch retries with BYTE-IDENTICAL body and same sig →
# TWO commentCreate calls (hash dedup skipped on --sig per Task 1's
# D-007 rule).
export PIPELINE_DRY_RUN=0  # explicit — do not inherit from A-003 (ENG-150 review nit)
_eng150_capture_a4="$(mktemp -t eng150-a4.XXXXXX)"
linear_query() {
  local query="$1" variables="${2:-{\}}"
  # commentUpdate arm is a tripwire: post-ENG-150 the chokepoint must
  # NEVER emit commentUpdate. The byte-identical-body path below would
  # historically have routed through commentUpdate (hash dedup); D-007's
  # --sig skip makes it route through commentCreate instead. Any UPDATE
  # row here would silently mask a regression.
  if [[ "$query" =~ commentUpdate ]]; then
    printf 'UPDATE %s\n' "$(jq -r '.body' <<<"$variables")" >> "$_eng150_capture_a4"
    printf '{"data":{"commentUpdate":{"success":true}}}\n'
    return 0
  fi
  if [[ "$query" =~ commentCreate ]]; then
    printf 'CREATE %s\n' "$(jq -r '.body' <<<"$variables")" >> "$_eng150_capture_a4"
    printf '{"data":{"commentCreate":{"success":true}}}\n'
    return 0
  fi
  # Simulate the first commentCreate having already landed (existing
  # comment with identical body) so hash dedup would fire in the absence
  # of the --sig bypass.
  jq -cn '{data:{issue:{comments:{nodes:[
    {body:"completion/implementing/ENG-X body\n\n<!-- meta: dispatch id=ENG-X-d0007 stage=implementing -->\n\n<!-- meta: dedup key=completion/implementing/ENG-X/d0007 -->"}
  ]}}}}'
}
: > "$_eng150_capture_a4"
PIPELINE_WRITER=agent PIPELINE_DISPATCH_ID=ENG-X-d0007 PIPELINE_STAGE=implementing \
  add_comment ENG-X --sig "completion/implementing/ENG-X" --body "completion/implementing/ENG-X body" >/dev/null 2>&1
PIPELINE_WRITER=agent PIPELINE_DISPATCH_ID=ENG-X-d0007 PIPELINE_STAGE=implementing \
  add_comment ENG-X --sig "completion/implementing/ENG-X" --body "completion/implementing/ENG-X body" >/dev/null 2>&1
_eng150_a4_create_count="$(grep -c '^CREATE ' "$_eng150_capture_a4" || true)"
if [[ "$_eng150_a4_create_count" == "2" ]]; then
  pass_at "ENG-150 A-004 same dispatch + identical body + --sig → TWO commentCreate (hash dedup skipped per D-007)"
else
  fail_at "ENG-150 A-004 same dispatch + identical body" \
    "create=$_eng150_a4_create_count captured: $(cat "$_eng150_capture_a4")"
fi
unset PIPELINE_WRITER PIPELINE_DISPATCH_ID PIPELINE_STAGE
rm -f "$_eng150_capture_a4"

# A-005: back-compat reader fixture.  An operator-side prefix-match-sort-
# latest jq recipe finds the LATEST halt under the sig prefix across a
# mix of one legacy comment (no /d suffix) and three post-cutover
# comments.  Verifies D-006 — the runbook recipe works for both shapes.
_eng150_a5_fixture="$(jq -cn '[
  {id:"c-legacy", createdAt:"2026-01-01T00:00:00Z", body:"halt body\n<!-- meta: dedup key=halt/X/Y -->"},
  {id:"c-d0007",  createdAt:"2026-01-02T00:00:00Z", body:"halt body\n<!-- meta: dedup key=halt/X/Y/d0007 -->"},
  {id:"c-d0008",  createdAt:"2026-01-03T00:00:00Z", body:"halt body\n<!-- meta: dedup key=halt/X/Y/d0008 -->"},
  {id:"c-d0009",  createdAt:"2026-01-04T00:00:00Z", body:"halt body\n<!-- meta: dedup key=halt/X/Y/d0009 -->"}
]')"
_eng150_a5_latest_id="$(jq -r '
  [.[] | select(.body | contains("<!-- meta: dedup key=halt/X/Y"))]
  | sort_by(.createdAt) | last | .id
' <<<"$_eng150_a5_fixture")"
if [[ "$_eng150_a5_latest_id" == "c-d0009" ]]; then
  pass_at "ENG-150 A-005 prefix-match-sort-latest finds latest dispatch (c-d0009) across legacy + post-cutover mix"
else
  fail_at "ENG-150 A-005 operator-recipe latest-by-prefix" "got: $_eng150_a5_latest_id"
fi
# A-005 paired: same recipe against a fixture with only ONE legacy
# comment returns that single legacy comment id (back-compat for issues
# that have not yet emitted under the post-cutover code path).
_eng150_a5b_fixture="$(jq -cn '[
  {id:"c-legacy", createdAt:"2026-01-01T00:00:00Z", body:"halt body\n<!-- meta: dedup key=halt/X/Y -->"}
]')"
_eng150_a5b_id="$(jq -r '
  [.[] | select(.body | contains("<!-- meta: dedup key=halt/X/Y"))]
  | sort_by(.createdAt) | last | .id
' <<<"$_eng150_a5b_fixture")"
if [[ "$_eng150_a5b_id" == "c-legacy" ]]; then
  pass_at "ENG-150 A-005b legacy-only fixture → recipe still returns the single legacy comment id"
else
  fail_at "ENG-150 A-005b legacy-only fixture" "got: $_eng150_a5b_id"
fi
unset _eng150_a5_fixture _eng150_a5_latest_id _eng150_a5b_fixture _eng150_a5b_id

# A-006: add_comment called WITHOUT --sig → no dedup marker appended,
# dispatch marker still injected.  Pins that --sig is opt-in for the
# append-only ledger.  Hash dedup is not exercised here (the stub
# fixture returns empty nodes, so the dedup branch could not fire
# regardless); A-004 covers the --sig hash-dedup-skip path.
export PIPELINE_DRY_RUN=0  # explicit — do not inherit from A-003 (ENG-150 review nit)
_eng150_capture_a6="$(mktemp -t eng150-a6.XXXXXX)"
linear_query() {
  local query="$1" variables="${2:-{\}}"
  if [[ "$query" =~ commentCreate ]]; then
    printf 'CREATE %s\n' "$(jq -r '.body' <<<"$variables")" >> "$_eng150_capture_a6"
    printf '{"data":{"commentCreate":{"success":true}}}\n'
    return 0
  fi
  jq -cn '{data:{issue:{comments:{nodes:[]}}}}'
}
: > "$_eng150_capture_a6"
PIPELINE_WRITER=agent PIPELINE_DISPATCH_ID=ENG-X-d0007 PIPELINE_STAGE=implementing \
  add_comment ENG-X --body "no sig" >/dev/null 2>&1
_eng150_a6_body="$(cat "$_eng150_capture_a6")"
if ! grep -qF '<!-- meta: dedup key=' <<<"$_eng150_a6_body" \
   && grep -qF '<!-- meta: dispatch id=ENG-X-d0007 stage=implementing -->' <<<"$_eng150_a6_body"; then
  pass_at "ENG-150 A-006 --sig opt-in → no dedup marker without --sig; dispatch marker still injected"
else
  fail_at "ENG-150 A-006 --sig opt-in" "captured: $_eng150_a6_body"
fi
unset PIPELINE_WRITER PIPELINE_DISPATCH_ID PIPELINE_STAGE
rm -f "$_eng150_capture_a6"

# A-007: sig-content validation (D-007) — newline / `-->` in --sig
# rejected with stderr containing `illegal characters`.  Use subshell
# isolation because `die` calls `exit` and would kill the test shell
# when add_comment is sourced (not called via cmdsub).
_eng150_a7_stderr="$(mktemp -t eng150-a7.XXXXXX)"
_eng150_a7_rc=0
( PIPELINE_DRY_RUN=1 add_comment ENG-X --sig $'halt/implementing/\nENG-X' --body "x" >/dev/null 2>"$_eng150_a7_stderr" ) \
  || _eng150_a7_rc=$?
if [[ "$_eng150_a7_rc" -ne 0 ]] && grep -qF 'illegal characters' "$_eng150_a7_stderr"; then
  pass_at "ENG-150 A-007 newline in --sig → die with 'illegal characters'"
else
  fail_at "ENG-150 A-007 newline in --sig" "rc=$_eng150_a7_rc stderr=$(cat "$_eng150_a7_stderr")"
fi
: > "$_eng150_a7_stderr"
_eng150_a7_rc=0
( PIPELINE_DRY_RUN=1 add_comment ENG-X --sig 'halt/--><script>' --body "x" >/dev/null 2>"$_eng150_a7_stderr" ) \
  || _eng150_a7_rc=$?
if [[ "$_eng150_a7_rc" -ne 0 ]] && grep -qF 'illegal characters' "$_eng150_a7_stderr"; then
  pass_at "ENG-150 A-007 '-->' in --sig → die with 'illegal characters'"
else
  fail_at "ENG-150 A-007 '-->' in --sig" "rc=$_eng150_a7_rc stderr=$(cat "$_eng150_a7_stderr")"
fi
rm -f "$_eng150_a7_stderr"
unset _eng150_a7_rc

# B-LEG: legacy single-comment shape under sig `last-review-state/ENG-X`
# (no /d<NNNN> suffix) — the existing read_review_state jq pipeline still
# finds it (back-compat for in-flight issues).  Pins D-006 read path.
_eng150_bleg_fixture="$(jq -cn '[
  {createdAt:"2026-01-01T00:00:00Z",
   body:"<!-- pipeline-state: last-review-state -->\n{\"sha\":\"abc\"}\n\n<!-- meta: dedup key=last-review-state/ENG-X -->"}
]')"
_eng150_bleg_pick="$(jq -r '
  [.[] | select(.body | contains("<!-- meta: dedup key=last-review-state/ENG-X"))]
  | sort_by(.createdAt) | last | .body
' <<<"$_eng150_bleg_fixture")"
if grep -qF '{"sha":"abc"}' <<<"$_eng150_bleg_pick"; then
  pass_at "ENG-150 B-LEG legacy single-comment shape under review-state sig → recipe returns body verbatim"
else
  fail_at "ENG-150 B-LEG legacy review-state read path" "got: $_eng150_bleg_pick"
fi
unset _eng150_bleg_fixture _eng150_bleg_pick

# A-008: forensic grep — the deleted symbols MUST be absent from
# production bin/*.sh + AGENT_PROMPTS.md + CLAUDE.md.  Mechanically pins
# AC #1.  Patterns use `[_]` / `[-]` so this file's literal grep pattern
# does not self-match (a future grep for the bare literal in *.sh would
# see brackets here and skip the line).
_eng150_a8_root="$SCRIPT_DIR_REAL/.."
_eng150_a8_pat='add[-]or[-]update[-]comment\|add[_]or[_]update[_]comment'
_eng150_a8_hits="$(grep -rln \
  "$_eng150_a8_pat" \
  "$_eng150_a8_root"/bin/*.sh \
  "$_eng150_a8_root/AGENT_PROMPTS.md" \
  "$_eng150_a8_root/CLAUDE.md" \
  2>/dev/null | grep -v -- '-test\.sh$' || true)"
if [[ -z "$_eng150_a8_hits" ]]; then
  pass_at "ENG-150 A-008 forensic: zero hits for retired symbol in production bin/ + AGENT_PROMPTS.md + CLAUDE.md"
else
  fail_at "ENG-150 A-008 forensic regression" "hits: $_eng150_a8_hits"
fi
unset _eng150_a8_root _eng150_a8_pat _eng150_a8_hits

# A-009: bin/linear-test.sh itself must NOT contain the retired symbol
# in literal form (only paraphrased references survive in the deletion
# comments above).  Pins the prose mop-up so F-4's pass criterion holds.
# Grep pattern uses `[_]` so the assertion does not self-match.
_eng150_a9_self="$SCRIPT_DIR_REAL/linear-test.sh"
_eng150_a9_pat='add[_]or[_]update[_]comment'
if grep -q "$_eng150_a9_pat" "$_eng150_a9_self"; then
  fail_at "ENG-150 A-009 self-grep: bin/linear-test.sh still contains the retired symbol literal" \
    "see grep -n on the retired add-comment-upsert symbol"
else
  pass_at "ENG-150 A-009 self-grep: bin/linear-test.sh carries zero retired-symbol literals"
fi
unset _eng150_a9_self _eng150_a9_pat

# ─── ENG-150 QA adversarial: chokepoint boundary cases ────────────────
# Cases not covered by A-001..A-009 / B-LEG but identified during QA
# review of the reviewing-round findings (linear.sh:745, :746, :802,
# :805).  All run under PIPELINE_DRY_RUN=1 (no GraphQL calls needed).
printf '\n--- ENG-150 QA adversarial ---\n'

# Q-ADV-001: --sig= (empty equals-sign form) extracts "" via
# `"${1#--sig=}"`, falls through [[ -n "$sig" ]] unchanged, and
# behaves as if --sig was never passed: no dedup marker appended, hash
# dedup resumes normally.  Documents the caller-footgun gap at
# linear.sh:728+745 — `--sig "$MY_VAR"` where $MY_VAR is empty
# silently opts out of the ledger contract with no error.
: > "$_eng150_log"
PIPELINE_DRY_RUN=1 \
  add_comment ENG-X --sig= --body "halt body" >/dev/null 2>&1
_eng150_adv001="$(cat "$_eng150_log")"
if ! grep -qF '<!-- meta: dedup key=' <<<"$_eng150_adv001"; then
  pass_at "ENG-150 Q-ADV-001 --sig= (empty) → no dedup marker (documents known bypass gap at linear.sh:745)"
else
  fail_at "ENG-150 Q-ADV-001 --sig= (empty): expected NO dedup marker" \
    "captured: $_eng150_adv001"
fi
unset PIPELINE_DRY_RUN _eng150_adv001

# Q-ADV-002: PIPELINE_DISPATCH_ID without a -d<NNNN> suffix (malformed
# env).  `${PIPELINE_DISPATCH_ID##*-}` strips the longest `*-` prefix,
# extracting the last hyphen-delimited segment regardless of shape.
# "ENG-150" → dispatch_seq="150"; dedup marker becomes
# "halt/implementing/ENG-X/150" instead of the expected "…/d0007".
# Documents the env-shape trust gap at linear.sh:805.
: > "$_eng150_log"
PIPELINE_DRY_RUN=1 \
PIPELINE_DISPATCH_ID=ENG-150 \
  add_comment ENG-X --sig "halt/implementing/ENG-X" --body "halt body" >/dev/null 2>&1
_eng150_adv002="$(cat "$_eng150_log")"
if grep -qF '<!-- meta: dedup key=halt/implementing/ENG-X/150 -->' <<<"$_eng150_adv002" \
   && ! grep -qE 'dedup key=halt/implementing/ENG-X/d[0-9]' <<<"$_eng150_adv002"; then
  pass_at "ENG-150 Q-ADV-002 malformed PIPELINE_DISPATCH_ID → non-d-prefix dispatch_seq in dedup marker (documents gap at linear.sh:805)"
else
  fail_at "ENG-150 Q-ADV-002 malformed PIPELINE_DISPATCH_ID" \
    "captured: $_eng150_adv002"
fi
unset PIPELINE_DISPATCH_ID _eng150_adv002

# Q-ADV-003: dedup marker embedded mid-line (surrounding text on the
# same line) survives the defensive strip at line 802.  The sed pattern
# `/^<!-- meta: dedup key=.* -->$/d` requires line isolation (anchored
# `^…$`); a marker with surrounding text is left intact.  A second dedup
# marker is then appended, producing two markers in the output.
# Documents the line-anchored-regex gap at linear.sh:802 — both review
# rounds flagged this same finding.
: > "$_eng150_log"
PIPELINE_DRY_RUN=1 \
PIPELINE_DISPATCH_ID=ENG-X-d0007 \
  add_comment ENG-X --sig "halt/implementing/ENG-X" \
    --body "body text <!-- meta: dedup key=old/sig --> more" >/dev/null 2>&1
_eng150_adv003="$(cat "$_eng150_log")"
_eng150_adv003_count="$(printf '%s' "$_eng150_adv003" | grep -o '<!-- meta: dedup key=' | wc -l | tr -d ' ')"
if [[ "$_eng150_adv003_count" -ge 2 ]]; then
  pass_at "ENG-150 Q-ADV-003 mid-line dedup marker survives strip → double dedup markers (documents gap at linear.sh:802)"
else
  fail_at "ENG-150 Q-ADV-003 mid-line dedup marker not stripped" \
    "expected >=2 dedup markers; got=$_eng150_adv003_count captured: $_eng150_adv003"
fi
unset PIPELINE_DISPATCH_ID _eng150_adv003 _eng150_adv003_count

# Q-ADV-004: line-isolated dedup marker (its own complete line) IS
# stripped before the new marker is appended — the happy-path of the
# D-003+D-007a defensive strip.  A prior dispatch's canonical marker on
# its own line is removed, leaving only the current dispatch's marker.
: > "$_eng150_log"
PIPELINE_DRY_RUN=1 \
PIPELINE_DISPATCH_ID=ENG-X-d0008 \
  add_comment ENG-X --sig "halt/implementing/ENG-X" \
    --body $'halt body\n\n<!-- meta: dedup key=halt/implementing/ENG-X/d0007 -->' >/dev/null 2>&1
_eng150_adv004="$(cat "$_eng150_log")"
_eng150_adv004_count="$(printf '%s' "$_eng150_adv004" | grep -o '<!-- meta: dedup key=' | wc -l | tr -d ' ')"
if [[ "$_eng150_adv004_count" -eq 1 ]] \
   && grep -qF '<!-- meta: dedup key=halt/implementing/ENG-X/d0008 -->' <<<"$_eng150_adv004" \
   && ! grep -qF '<!-- meta: dedup key=halt/implementing/ENG-X/d0007 -->' <<<"$_eng150_adv004"; then
  pass_at "ENG-150 Q-ADV-004 line-isolated prior dedup marker stripped → only new dispatch marker present"
else
  fail_at "ENG-150 Q-ADV-004 line-isolated dedup strip" \
    "count=$_eng150_adv004_count captured: $_eng150_adv004"
fi
unset PIPELINE_DISPATCH_ID _eng150_adv004 _eng150_adv004_count

# Q-ADV-005: sig containing `<!--` (HTML comment opener without closer)
# passes the validation gate at line 746, which only rejects `\n` and
# `-->`.  The resulting dedup marker embeds a nested `<!--` inside the
# outer HTML comment, producing malformed markup.  Documents the
# defense-in-depth gap at linear.sh:746 (review finding: sig validation
# misses `<!--` opener).
: > "$_eng150_log"
_eng150_adv005_rc=0
PIPELINE_DRY_RUN=1 \
PIPELINE_DISPATCH_ID=ENG-X-d0007 \
  add_comment ENG-X --sig "halt/<!--nested/ENG-X" --body "body" >/dev/null 2>&1 \
  || _eng150_adv005_rc=$?
_eng150_adv005="$(cat "$_eng150_log")"
if [[ "$_eng150_adv005_rc" -eq 0 ]] \
   && grep -qF '<!-- meta: dedup key=halt/<!--nested/ENG-X' <<<"$_eng150_adv005"; then
  pass_at "ENG-150 Q-ADV-005 sig with '<!--' passes validation and embeds nested opener (documents gap at linear.sh:746)"
else
  fail_at "ENG-150 Q-ADV-005 sig with '<!--'" \
    "rc=$_eng150_adv005_rc; expected rc=0 + nested <!--; captured: $_eng150_adv005"
fi
unset PIPELINE_DISPATCH_ID _eng150_adv005 _eng150_adv005_rc

# Q-ADV-006: --body - (stdin form) combined with --sig works correctly
# regardless of arg order.  The arg-stripping loop at line 721-734
# extracts --sig from the full arg list in one pass before passing the
# remainder to _resolve_body_arg, so stdin piping is transparent to
# --sig even when --body - precedes --sig in argv.
: > "$_eng150_log"
PIPELINE_DRY_RUN=1 \
PIPELINE_DISPATCH_ID=ENG-X-d0007 \
  add_comment ENG-X --body - --sig "halt/implementing/ENG-X" <<'STDIN_BODY' >/dev/null 2>&1
stdin body text
STDIN_BODY
_eng150_adv006="$(cat "$_eng150_log")"
if grep -qF '<!-- meta: dedup key=halt/implementing/ENG-X/d0007 -->' <<<"$_eng150_adv006" \
   && grep -qF 'stdin body text' <<<"$_eng150_adv006"; then
  pass_at "ENG-150 Q-ADV-006 --body - stdin + --sig → dedup marker appended and stdin content captured"
else
  fail_at "ENG-150 Q-ADV-006 --body - + --sig" \
    "captured: $_eng150_adv006"
fi
unset PIPELINE_DISPATCH_ID _eng150_adv006

# Restore originals so subsequent tests inherit a pristine env.
rm -f "$_eng150_log"
unset -f log linear_query _resolve_issue_uuid 2>/dev/null || true
[[ -n "$_eng150_orig_log" ]] && eval "$_eng150_orig_log"
[[ -n "$_eng150_orig_linear_query" ]] && eval "$_eng150_orig_linear_query"
[[ -n "$_eng150_orig_resolve_uuid" ]] && eval "$_eng150_orig_resolve_uuid"
export PIPELINE_DRY_RUN="$_eng150_orig_dry_run"
SCRIPT_DIR="$_eng150_orig_script_dir"
unset _eng150_orig_linear_query _eng150_orig_resolve_uuid _eng150_orig_log \
      _eng150_orig_dry_run _eng150_orig_script_dir _eng150_log \
      _eng150_a001 _eng150_a002 \
      _eng150_a3_create_count _eng150_a3_update_count \
      _eng150_a4_create_count \
      _eng150_a6_body \
      _eng150_adv001 _eng150_adv002 \
      _eng150_adv003 _eng150_adv003_count \
      _eng150_adv004 _eng150_adv004_count \
      _eng150_adv005 _eng150_adv005_rc \
      _eng150_adv006

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

# ─── ENG-110: add_comment source-pin (inject-before-dry-run) ──────────
# Pin the inject-before-PIPELINE_DRY_RUN-short-circuit ordering: a
# future change that moves _inject_dispatch_marker AFTER the
# `if [[ "${PIPELINE_DRY_RUN:-0}" == "1" ]]` branch would silently
# false-pass under PIPELINE_DRY_RUN=1 (the function returns 0 before
# the inject runs).  Source-pin closes that gap.
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

# QA-4 (current-id injection on fresh body under new dispatch_id).
# Pin: a clean body invoked under a NEW PIPELINE_DISPATCH_ID stamps
# with the current id only (no prior-id leak from prose).  Pre-ENG-150
# this case was framed against the retired upsert path's lookup finding
# an in-flight comment with a stale id-marker; post-ENG-150 the
# append-only write has no in-flight lookup, but the injector contract
# (current-id-specific idempotency from _inject_dispatch_marker line 56)
# is unchanged.
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

# Case 87-L7 reapplied-audit deleted in ENG-150: exercised the retired
# upsert lane's byte-equal-modulo-meta-noise arm under dispatch_id
# rotation (retired in ENG-150).  Append-only writes have no reapply
# path so the audit signal does not need to survive id-rotation — every
# halt re-fire appears as a fresh chronological comment with its own
# createdAt and a dispatch-suffixed `<!-- meta: dedup key=... -->`
# marker (see ENG-150 A-003).

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
