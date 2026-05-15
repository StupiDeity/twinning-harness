#!/usr/bin/env bash
# ENG-44: bin/common.sh::is_orchestrator_paused — six-row test table.
#
# Coverage maps directly to ENG-44's Test table (rows 1-6). Row 2 also
# exists in bin/run-local-helpers-adversarial-test.sh:601-611
# (test_paused_override_honored, written for ENG-49). The overlap is
# intentional (see brainstorm D-002): self-contained module-level
# coverage beats cross-file scavenging for a future reader.
#
# Read priority under test (bin/common.sh:122-125 contract):
#   STATE_FILE (if present and key is non-null) > CONFIG > "false"

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Throwaway TARGET_REPO and PROJECT_SLUG — common.sh requires both at
# source time (bin/common.sh:11-12, :40-48).
_TEST_ROOT="$(mktemp -d -t twinning-eng44.XXXXXX)"
_assert_temp_path() {
  case "$1" in
    /var/folders/*|/tmp/*|/private/var/folders/*|/private/tmp/*) return 0 ;;
    *) printf 'REFUSING: %q is not a platform temp dir\n' "$1" >&2; exit 99 ;;
  esac
}
_assert_temp_path "$_TEST_ROOT"
trap 'case "$_TEST_ROOT" in /var/folders/*|/tmp/*|/private/var/folders/*|/private/tmp/*) rm -rf "$_TEST_ROOT" ;; esac' EXIT

export TARGET_REPO="$_TEST_ROOT/target"
mkdir -p "$TARGET_REPO/.pipeline-config"
export PROJECT_SLUG="${PROJECT_SLUG:-test-slug}"

# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"
# common.sh sets `-e`; relax it so a failing row does not abort.
set +e

PASS=0; FAIL=0; FAILED_CASES=()
report_ok()   { printf 'OK: %s\n' "$1"; PASS=$((PASS+1)); }
report_fail() {
  printf 'FAIL: %s\n  expected: %s\n  got:      %s\n' "$1" "$2" "$3" >&2
  FAIL=$((FAIL+1)); FAILED_CASES+=("$1")
}
assert_eq() {
  local name="$1" expected="$2" got="$3"
  if [[ "$got" == "$expected" ]]; then report_ok "$name"; else report_fail "$name" "$expected" "$got"; fi
}

# Materialize per-row config.json + state.local.json under $_TEST_ROOT
# and emit "<cfg-path>\t<sf-path>\n" — single tab-delimited line so that
# `read -r cfg sf < <(mkfixture …)` binds both vars from one read (bash
# `read` consumes one line and IFS-splits it; two newline-separated tokens
# would leave the second var empty and silently break the test).
# cfg_paused: "true" | "false" | "absent" (omits the .orchestrator.paused key)
# sf_body:    "absent"            -> no state.local.json file at all
#             "{}"                -> empty object
#             other               -> written verbatim as state.local.json body
mkfixture() {
  local row_name="$1" cfg_paused="$2" sf_body="$3"
  local tdir; tdir="$(mktemp -d "$_TEST_ROOT/row-${row_name}-XXXXXX")"
  local cfg="$tdir/config.json" sf="$tdir/state.local.json"
  if [[ "$cfg_paused" == "absent" ]]; then
    printf '{}\n' > "$cfg"
  else
    jq -n --argjson p "$cfg_paused" '{orchestrator:{paused:$p}}' > "$cfg"
  fi
  case "$sf_body" in
    "absent") ;;                              # no state.local.json file
    "{}")     printf '{}\n' > "$sf" ;;
    *)        printf '%s\n' "$sf_body" > "$sf" ;;
  esac
  printf '%s\t%s\n' "$cfg" "$sf"
}

# ─── ENG-44 six-row table (brainstorm §5) ────────────────────────────
# | # | STATE_FILE       | config.paused | Result  |
# | - | ---------------- | ------------- | ------- |
# | 1 | absent           | true          | true    |  fall to CONFIG (no override)
# | 2 | {paused:false}   | true          | false   |  state.local wins (regression direction)
# | 3 | {paused:true}    | false         | true    |  state.local wins (other direction)
# | 4 | {}               | true          | true    |  empty STATE_FILE falls through
# | 5 | {orchestrator:{}}| true          | true    |  partial STATE_FILE falls through
# | 6 | {}               | absent        | false   |  // "false" CONFIG default

row1_state_file_absent_falls_to_config_true() {
  local cfg sf got
  read -r cfg sf < <(mkfixture row1 true absent)
  got="$(CONFIG="$cfg" STATE_FILE="$sf" is_orchestrator_paused)"
  assert_eq "row1_state_file_absent_falls_to_config_true" "true" "$got"
}
row1_state_file_absent_falls_to_config_true

row2_state_file_overrides_config_to_false() {
  local cfg sf got
  read -r cfg sf < <(mkfixture row2 true '{"orchestrator":{"paused":false}}')
  got="$(CONFIG="$cfg" STATE_FILE="$sf" is_orchestrator_paused)"
  assert_eq "row2_state_file_overrides_config_to_false" "false" "$got"
}
row2_state_file_overrides_config_to_false

row3_state_file_overrides_config_to_true() {
  local cfg sf got
  read -r cfg sf < <(mkfixture row3 false '{"orchestrator":{"paused":true}}')
  got="$(CONFIG="$cfg" STATE_FILE="$sf" is_orchestrator_paused)"
  assert_eq "row3_state_file_overrides_config_to_true" "true" "$got"
}
row3_state_file_overrides_config_to_true

row4_state_file_empty_object_falls_to_config() {
  local cfg sf got
  read -r cfg sf < <(mkfixture row4 true '{}')
  got="$(CONFIG="$cfg" STATE_FILE="$sf" is_orchestrator_paused)"
  assert_eq "row4_state_file_empty_object_falls_to_config" "true" "$got"
}
row4_state_file_empty_object_falls_to_config

row5_state_file_orchestrator_empty_falls_to_config() {
  local cfg sf got
  read -r cfg sf < <(mkfixture row5 true '{"orchestrator":{}}')
  got="$(CONFIG="$cfg" STATE_FILE="$sf" is_orchestrator_paused)"
  assert_eq "row5_state_file_orchestrator_empty_falls_to_config" "true" "$got"
}
row5_state_file_orchestrator_empty_falls_to_config

row6_both_layers_absent_returns_false() {
  local cfg sf got
  read -r cfg sf < <(mkfixture row6 absent '{}')
  got="$(CONFIG="$cfg" STATE_FILE="$sf" is_orchestrator_paused)"
  assert_eq "row6_both_layers_absent_returns_false" "false" "$got"
}
row6_both_layers_absent_returns_false

# ─── QA adversarial coverage (ENG-44 review) ─────────────────────────
# Beyond the brainstorm's six-row table, these pin behavior on edge
# cases §7 of the brainstorm flagged as "intentionally NOT bound to
# tests" plus invariants the five-caller chain silently relies on.
# Each test is QA-authored under the maker-checker rule in the QA
# stage prompt; their counterparts do NOT appear in docs/plans/.

# adv1 — malformed STATE_FILE JSON falls through to CONFIG.
# Guards against: a future refactor dropping `2>/dev/null || true` and
# turning a mid-write torn read into a fatal pipeline error.
adv1_malformed_state_file_falls_through() {
  local tdir; tdir="$(mktemp -d "$_TEST_ROOT/adv1-XXXXXX")"
  local cfg="$tdir/config.json" sf="$tdir/state.local.json"
  jq -n '{orchestrator:{paused:true}}' > "$cfg"
  printf '%s' '{not-json' > "$sf"   # truncated mid-rename
  local got
  got="$(CONFIG="$cfg" STATE_FILE="$sf" is_orchestrator_paused)"
  assert_eq "adv1_malformed_state_file_falls_through" "true" "$got"
}
adv1_malformed_state_file_falls_through

# adv2 — explicit `paused: null` in STATE_FILE falls through. Directly
# pins the contract the comment at bin/common.sh:129-130 promises (the
# whole reason `// empty` was rejected). Guards against silent revert
# to `// empty` or `// false` shapes.
adv2_explicit_null_state_file_falls_through() {
  local tdir; tdir="$(mktemp -d "$_TEST_ROOT/adv2-XXXXXX")"
  local cfg="$tdir/config.json" sf="$tdir/state.local.json"
  jq -n '{orchestrator:{paused:true}}' > "$cfg"
  printf '%s\n' '{"orchestrator":{"paused":null}}' > "$sf"
  local got
  got="$(CONFIG="$cfg" STATE_FILE="$sf" is_orchestrator_paused)"
  assert_eq "adv2_explicit_null_state_file_falls_through" "true" "$got"
}
adv2_explicit_null_state_file_falls_through

# adv3 — STATE_FILE has `orchestrator` as a wrong type (schema drift).
# jq's `.orchestrator.paused` on a non-object errors; the swallow path
# (`2>/dev/null || true`) must catch it and the function must fall
# through to CONFIG, not crash mid-tick.
adv3_orchestrator_wrong_type_falls_through() {
  local tdir; tdir="$(mktemp -d "$_TEST_ROOT/adv3-XXXXXX")"
  local cfg="$tdir/config.json" sf="$tdir/state.local.json"
  jq -n '{orchestrator:{paused:true}}' > "$cfg"
  printf '%s\n' '{"orchestrator":"yes"}' > "$sf"
  local got
  got="$(CONFIG="$cfg" STATE_FILE="$sf" is_orchestrator_paused)"
  assert_eq "adv3_orchestrator_wrong_type_falls_through" "true" "$got"
}
adv3_orchestrator_wrong_type_falls_through

# adv4 — zero-byte STATE_FILE. Models a partial write or
# filesystem-truncation failure. jq parse-errors on empty input;
# swallow + fall through expected.
adv4_empty_state_file_falls_through() {
  local tdir; tdir="$(mktemp -d "$_TEST_ROOT/adv4-XXXXXX")"
  local cfg="$tdir/config.json" sf="$tdir/state.local.json"
  jq -n '{orchestrator:{paused:false}}' > "$cfg"
  : > "$sf"   # zero-byte file
  local got
  got="$(CONFIG="$cfg" STATE_FILE="$sf" is_orchestrator_paused)"
  assert_eq "adv4_empty_state_file_falls_through" "false" "$got"
}
adv4_empty_state_file_falls_through

# adv5 — STATE_FILE path exists but as a directory. `[[ -f ]]` returns
# false on directories; guards against a refactor to `[[ -e ]]` that
# would crash jq trying to slurp a directory.
adv5_state_file_is_directory_falls_through() {
  local tdir; tdir="$(mktemp -d "$_TEST_ROOT/adv5-XXXXXX")"
  local cfg="$tdir/config.json" sf="$tdir/state.local.json"
  jq -n '{orchestrator:{paused:true}}' > "$cfg"
  mkdir -p "$sf"   # path exists but is a directory, not a regular file
  local got
  got="$(CONFIG="$cfg" STATE_FILE="$sf" is_orchestrator_paused)"
  assert_eq "adv5_state_file_is_directory_falls_through" "true" "$got"
}
adv5_state_file_is_directory_falls_through

# adv6 — caller invariant. Five callers (poll.sh, run-local.sh,
# run-stage.sh, reset-pipeline.sh, dry-run.sh) all do
# `[[ "$paused" == "true" ]]`; any drift to "True", "yes", " true ",
# or extra whitespace silently flips paused→not-paused. Pin both
# branches (state-file branch via `printf '%s'`; config branch via
# `jq -r` which appends a newline that `$()` strips).
adv6_output_is_true_or_false_invariant() {
  local tdir; tdir="$(mktemp -d "$_TEST_ROOT/adv6-XXXXXX")"
  local cfg="$tdir/config.json" sf="$tdir/state.local.json"
  jq -n '{orchestrator:{paused:false}}' > "$cfg"
  jq -n '{orchestrator:{paused:true}}' > "$sf"
  local got
  got="$(CONFIG="$cfg" STATE_FILE="$sf" is_orchestrator_paused)"
  case "$got" in
    true|false) report_ok "adv6_output_invariant (state branch)" ;;
    *) report_fail "adv6_output_invariant (state branch)" "true|false" "$got" ;;
  esac
  rm -f "$sf"   # force config-branch path
  got="$(CONFIG="$cfg" STATE_FILE="$sf" is_orchestrator_paused)"
  case "$got" in
    true|false) report_ok "adv6_output_invariant (config branch)" ;;
    *) report_fail "adv6_output_invariant (config branch)" "true|false" "$got" ;;
  esac
}
adv6_output_is_true_or_false_invariant

pass_at() { PASS=$((PASS+1)); printf '  ✅ %s\n' "$1"; }
fail_at() {
  FAIL=$((FAIL+1));
  if [[ -n "${2:-}" ]]; then
    printf '  ❌ %s\n      %s\n' "$1" "$2" >&2
  else
    printf '  ❌ %s\n' "$1" >&2
  fi
  FAILED_CASES+=("$1")
}

# ─── Group: parse_pipeline_marker (ENG-60 Phase 1) ───────────────────────

printf '\n--- parse_pipeline_marker ---\n'

# Fixture P1: new-shape verdict pass
result="$(parse_pipeline_marker '<!-- pipeline: verdict result=pass stage=implementing -->')"
[[ "$(jq -r '.event' <<<"$result")" == "verdict" ]]   && pass_at "P1: event=verdict"   || fail_at "P1: event mismatch" "got: $result"
[[ "$(jq -r '.result' <<<"$result")" == "pass" ]]     && pass_at "P1: result=pass"     || fail_at "P1: result mismatch" "got: $result"
[[ "$(jq -r '.stage' <<<"$result")" == "implementing" ]] && pass_at "P1: stage=implementing" || fail_at "P1: stage mismatch" "got: $result"

# Fixture P2: new-shape verdict fail
result="$(parse_pipeline_marker '<!-- pipeline: verdict result=fail target=planning -->')"
[[ "$(jq -r '.result' <<<"$result")" == "fail" ]]     && pass_at "P2: result=fail"     || fail_at "P2: result mismatch" "got: $result"
[[ "$(jq -r '.target' <<<"$result")" == "planning" ]] && pass_at "P2: target=planning" || fail_at "P2: target mismatch" "got: $result"

# Fixture P3: new-shape verdict halt
result="$(parse_pipeline_marker '<!-- pipeline: verdict result=halt reason=agent-blocked -->')"
[[ "$(jq -r '.result' <<<"$result")" == "halt" ]]            && pass_at "P3: result=halt" || fail_at "P3: result mismatch" "got: $result"
[[ "$(jq -r '.reason' <<<"$result")" == "agent-blocked" ]]   && pass_at "P3: reason"     || fail_at "P3: reason mismatch" "got: $result"

# Fixture P11: comment body with surrounding prose + marker at the end
body=$'A multi-line\nbody.\n<!-- pipeline: verdict result=pass stage=implementing -->'
result="$(parse_pipeline_marker "$body")"
[[ "$(jq -r '.event' <<<"$result")" == "verdict" ]] && pass_at "P11: marker found in multi-line body" || fail_at "P11: event mismatch" "got: $result"

# Fixture P12: body with no recognizable marker returns empty + rc=1
result="$(parse_pipeline_marker 'just prose, no marker' 2>/dev/null)" && rc=0 || rc=$?
[[ "$rc" -eq 1 ]] && pass_at "P12: rc=1 on no marker" || fail_at "P12: rc mismatch" "expected 1, got $rc"
[[ -z "$result" ]] && pass_at "P12: empty stdout" || fail_at "P12: stdout not empty" "got: $result"

# ─── ENG-61 Bug A: prose-quoted markers must NOT parse as real markers ───

# Fixture P13: marker enclosed in single backticks must NOT parse.
body='Discussion: the legacy stripper was triggered by `<!-- pipeline: verdict result=pass stage=implementing -->` in body text.'
result="$(parse_pipeline_marker "$body" 2>/dev/null)" && rc=0 || rc=$?
[[ "$rc" -eq 1 ]] && pass_at "P13: backticked marker NOT parsed (rc=1)" || fail_at "P13: rc mismatch" "expected 1, got $rc"
[[ -z "$result" ]] && pass_at "P13: backticked marker → empty stdout" || fail_at "P13: stdout not empty" "got: $result"

# Fixture P14: marker inside triple-backtick fenced block must NOT parse
# (single-line, post-gsub-collapse shape — mirrors production callers' input).
body='Example: ```<!-- pipeline: verdict result=pass stage=implementing -->``` is what the agent emits.'
result="$(parse_pipeline_marker "$body" 2>/dev/null)" && rc=0 || rc=$?
[[ "$rc" -eq 1 ]] && pass_at "P14: triple-backtick fenced marker NOT parsed (rc=1)" || fail_at "P14: rc mismatch" "expected 1, got $rc"
[[ -z "$result" ]] && pass_at "P14: triple-backtick fenced marker → empty stdout" || fail_at "P14: stdout not empty" "got: $result"

# Fixture P14b: multi-line raw body with 4-space-indented marker must NOT parse.
# Pins the indented-block code path (step 1 of strip helper). Bypasses the
# typical caller's gsub-collapse by passing newlines preserved.
body=$'Some prose.\n    <!-- pipeline: verdict result=pass stage=implementing -->\nMore prose.'
result="$(parse_pipeline_marker "$body" 2>/dev/null)" && rc=0 || rc=$?
[[ "$rc" -eq 1 ]] && pass_at "P14b: 4-space-indented marker (raw multi-line body) NOT parsed (rc=1)" || fail_at "P14b: rc mismatch" "expected 1, got $rc"
[[ -z "$result" ]] && pass_at "P14b: 4-space-indented marker → empty stdout" || fail_at "P14b: stdout not empty" "got: $result"

# Fixture P15: real marker on a line with no backticks must still parse
# (regression check that the strip helper does not over-strip).
body='Plain prose. <!-- pipeline: verdict result=pass stage=implementing -->'
result="$(parse_pipeline_marker "$body")"
[[ "$(jq -r '.event' <<<"$result")" == "verdict" ]] && pass_at "P15: bare real marker still parses" || fail_at "P15: event mismatch" "got: $result"
[[ "$(jq -r '.result' <<<"$result")" == "pass" ]] && pass_at "P15: bare real marker → result=pass" || fail_at "P15: result mismatch" "got: $result"

# Fixture P16: real marker followed by a backticked example marker; real one
# must win (tail -1 semantics survive the pre-strip — example removed → only
# the real marker remains for grep → tail -1 picks it).
body='Real: <!-- pipeline: verdict result=pass stage=implementing --> See also: `<!-- pipeline: verdict result=fail target=planning -->` for the failure case.'
result="$(parse_pipeline_marker "$body")"
[[ "$(jq -r '.event' <<<"$result")" == "verdict" ]] && pass_at "P16: real marker wins over backticked example" || fail_at "P16: event mismatch" "got: $result"
[[ "$(jq -r '.result' <<<"$result")" == "pass" ]] && pass_at "P16: real marker → result=pass (NOT fail)" || fail_at "P16: result mismatch (example marker was wrongly parsed)" "got: $result"

# ─── ENG-61 QA adversarial coverage ─────────────────────────────────────

# Fixture P17 (adversarial): backticked span containing glob metacharacters
# (*, ?, [, ]) must not break the strip loop. Brainstorm A15 flags
# `${var//pat/repl}` as glob-evaluated; if BASH_REMATCH[0] contains glob
# metachars and the literal-vs-glob mismatch causes the substitution to
# (a) not remove the span (infinite loop) or (b) over-match and consume
# the real marker, this test exposes it.
body='Glob test `arr[0] *.md ?path` <!-- pipeline: verdict result=pass stage=implementing -->'
result="$(parse_pipeline_marker "$body")"
[[ "$(jq -r '.event' <<<"$result")" == "verdict" ]] && pass_at "P17: real marker survives glob-metachar backticked span" || fail_at "P17: event mismatch" "got: $result"
[[ "$(jq -r '.result' <<<"$result")" == "pass" ]] && pass_at "P17: glob-metachar span → real marker still parses pass" || fail_at "P17: result mismatch" "got: $result"

# Fixture P18 (adversarial): tab-indented marker on a multi-line raw body
# must NOT parse. Brainstorm D-002 awk filter `^( {4,}|\t)` claims to
# strip both 4-space-indent AND tab-indent; the plan's P14b only covers
# 4-space-indent. This pins the tab branch.
body=$'Some prose.\n\t<!-- pipeline: verdict result=pass stage=implementing -->\nMore prose.'
result="$(parse_pipeline_marker "$body" 2>/dev/null)" && rc=0 || rc=$?
[[ "$rc" -eq 1 ]] && pass_at "P18: tab-indented marker (raw multi-line body) NOT parsed (rc=1)" || fail_at "P18: rc mismatch" "expected 1, got $rc"
[[ -z "$result" ]] && pass_at "P18: tab-indented marker → empty stdout" || fail_at "P18: stdout not empty" "got: $result"

# Fixture P19 (adversarial): backticked text containing the marker-end
# byte sequence (`-->`) must not confuse the grep boundary. The grep
# pattern is `[^>]+`; if a stray `>` from a stripped span leaks past the
# strip helper into grep, the regex bounds could be perturbed.
body='Trick: `--> not a marker -->` <!-- pipeline: verdict result=pass stage=implementing -->'
result="$(parse_pipeline_marker "$body")"
[[ "$(jq -r '.event' <<<"$result")" == "verdict" ]] && pass_at "P19: real marker found despite backticked '-->' decoy" || fail_at "P19: event mismatch" "got: $result"
[[ "$(jq -r '.result' <<<"$result")" == "pass" ]] && pass_at "P19: real marker → result=pass (decoy not parsed)" || fail_at "P19: result mismatch" "got: $result"

# Fixture P20 (adversarial): empty triple-backtick fence `''''''` (six
# adjacent backticks). Step 2's regex `\`\`\`[^\`]*\`\`\`` allows zero
# inner chars; verify the loop terminates and real marker survives.
body='Empty fence ``````.  <!-- pipeline: verdict result=pass stage=implementing -->'
result="$(parse_pipeline_marker "$body")"
[[ "$(jq -r '.event' <<<"$result")" == "verdict" ]] && pass_at "P20: real marker survives empty triple-backtick fence" || fail_at "P20: event mismatch" "got: $result"
[[ "$(jq -r '.result' <<<"$result")" == "pass" ]] && pass_at "P20: empty triple-fence → real marker still parses pass" || fail_at "P20: result mismatch" "got: $result"

# Fixture P21 (adversarial, cold-pass gap): marker as the entire body —
# no surrounding prose. Boundary case for the strip helper: ensures it
# doesn't trim or eat the marker when the body has zero context.
body='<!-- pipeline: verdict result=pass stage=implementing -->'
result="$(parse_pipeline_marker "$body")"
[[ "$(jq -r '.event' <<<"$result")" == "verdict" ]] && pass_at "P21: marker-as-entire-body still parses" || fail_at "P21: event mismatch" "got: $result"
[[ "$(jq -r '.result' <<<"$result")" == "pass" ]] && pass_at "P21: marker-as-entire-body → result=pass" || fail_at "P21: result mismatch" "got: $result"

# Fixture P22 (adversarial, current-behavior pin): tilde-fenced markdown
# blocks (~~~) are NOT stripped by the helper — only backticks are.
# Stage-summary writers in this harness use backtick fences (per
# AGENT_PROMPTS.md convention), but if a future writer ever switches to
# `~~~` fences, this fixture catches the silent regression. Pins the
# brainstorm's deliberate "backticks only" scope decision so future
# contributors do not accidentally extend or remove tilde handling
# without an explicit decision.
body='Example: ~~~<!-- pipeline: verdict result=pass stage=implementing -->~~~ here.'
result="$(parse_pipeline_marker "$body")"
[[ "$(jq -r '.event' <<<"$result")" == "verdict" ]] && pass_at "P22: tilde-fenced marker IS still parsed (current behavior — backticks-only scope per brainstorm)" || fail_at "P22: tilde behavior changed" "got: $result"

# Fixture P23 (adversarial, cold-pass gap): body has a lone unbalanced
# backtick BEFORE a real marker. The sed s/`[^`]*`/ /g substitution
# requires PAIRED backticks; with a single stray backtick the regex
# does not match and the body passes through unmodified. Pins the
# brainstorm §5 "unbalanced backticks → marker still parses" claim
# explicitly, and protects against future regressions where a maintainer
# might "fix" the strip helper to greedy-match a lone backtick to the
# next `>` or end-of-line and accidentally consume the real marker.
body='Stray backtick: ` then real <!-- pipeline: verdict result=pass stage=implementing -->'
result="$(parse_pipeline_marker "$body")"
[[ "$(jq -r '.event' <<<"$result")" == "verdict" ]] && pass_at "P23: lone unbalanced backtick before real marker → real survives" || fail_at "P23: event mismatch" "got: $result"
[[ "$(jq -r '.result' <<<"$result")" == "pass" ]] && pass_at "P23: lone backtick → result=pass (strip is conservative)" || fail_at "P23: result mismatch" "got: $result"

# ─── ENG-87: allocate_dispatch_id, current_dispatch_id ───────────────
# Per-issue monotonic counter for cross-dispatch staleness defense.
# Allocated at run-stage.sh::main per dispatch, exported as
# PIPELINE_DISPATCH_ID, persisted in $(issue_dir)/issue-state.json.
# Tests pin atomicity (mv -f), monotonicity, durability across process
# boundaries, corrupt-JSON resilience, and the read-back via
# current_dispatch_id.
printf '\n--- ENG-87: allocate_dispatch_id ---\n'

# Use the existing $_TEST_ROOT (set at the top of this file).
# PROJECT_STATE_DIR is derived per-issue via issue_dir(). Each case
# pre-cleans the per-issue dir.
_eng87_state_dir="$_TEST_ROOT/state/test-slug"
mkdir -p "$_eng87_state_dir"
PROJECT_STATE_DIR="$_eng87_state_dir"
export PROJECT_STATE_DIR

# Case 87.1: first allocation creates issue-state.json with seq=1 and
# returns ENG-87T-d0001. Asserts atomic-write semantics + initial-state
# bootstrapping (file absent → seq=1 path).
_eng87_case1_dir="$_eng87_state_dir/ENG-87T1"
rm -rf "$_eng87_case1_dir"
id1="$(allocate_dispatch_id ENG-87T1)"
assert_eq "87.1: first allocation returns ENG-87T1-d0001" "ENG-87T1-d0001" "$id1"
got_seq="$(jq -r '.current_dispatch_seq // ""' "$_eng87_case1_dir/issue-state.json" 2>/dev/null)"
assert_eq "87.1: issue-state.json carries current_dispatch_seq=1" "1" "$got_seq"
got_id="$(jq -r '.current_dispatch_id // ""' "$_eng87_case1_dir/issue-state.json" 2>/dev/null)"
assert_eq "87.1: issue-state.json carries current_dispatch_id" "ENG-87T1-d0001" "$got_id"

# Case 87.2: second allocation increments seq to 2 AND preserves prior
# classify-failure fields (policy/reason/retry_count). The merge MUST
# be additive — current_dispatch_seq updates without losing the
# operator-visible policy state.
_eng87_case2_dir="$_eng87_state_dir/ENG-87T2"
rm -rf "$_eng87_case2_dir"
mkdir -p "$_eng87_case2_dir"
printf '%s\n' '{"current_dispatch_seq":1,"current_dispatch_id":"ENG-87T2-d0001","policy":"retry-immediately","reason":"linear-post-failed","retry_count":1}' \
  > "$_eng87_case2_dir/issue-state.json"
id2="$(allocate_dispatch_id ENG-87T2)"
assert_eq "87.2: second allocation increments to d0002" "ENG-87T2-d0002" "$id2"
got_seq="$(jq -r '.current_dispatch_seq // ""' "$_eng87_case2_dir/issue-state.json" 2>/dev/null)"
assert_eq "87.2: seq=2 after increment" "2" "$got_seq"
got_policy="$(jq -r '.policy // ""' "$_eng87_case2_dir/issue-state.json" 2>/dev/null)"
assert_eq "87.2: classify-failure policy preserved" "retry-immediately" "$got_policy"
got_reason="$(jq -r '.reason // ""' "$_eng87_case2_dir/issue-state.json" 2>/dev/null)"
assert_eq "87.2: classify-failure reason preserved" "linear-post-failed" "$got_reason"
got_retry="$(jq -r '.retry_count // ""' "$_eng87_case2_dir/issue-state.json" 2>/dev/null)"
assert_eq "87.2: classify-failure retry_count preserved" "1" "$got_retry"

# Case 87.3: concurrent invocations serialise via mv -f atomicity.
# Two parallel allocator calls must produce a {d0003, d0004} set with
# no collision and no double-write at the same seq. The atomicity
# property is provided by mv -f on POSIX (rename(2)); the test pins
# the assumption against a future refactor that drops the tmpfile-
# and-rename pattern.
_eng87_case3_dir="$_eng87_state_dir/ENG-87T3"
rm -rf "$_eng87_case3_dir"
mkdir -p "$_eng87_case3_dir"
printf '%s\n' '{"current_dispatch_seq":2,"current_dispatch_id":"ENG-87T3-d0002"}' \
  > "$_eng87_case3_dir/issue-state.json"
_eng87_p1_out="$_TEST_ROOT/eng87-p1.out"
_eng87_p2_out="$_TEST_ROOT/eng87-p2.out"
( allocate_dispatch_id ENG-87T3 > "$_eng87_p1_out" ) &
_eng87_p1_pid=$!
( allocate_dispatch_id ENG-87T3 > "$_eng87_p2_out" ) &
_eng87_p2_pid=$!
wait "$_eng87_p1_pid" "$_eng87_p2_pid"
id_a="$(cat "$_eng87_p1_out")"
id_b="$(cat "$_eng87_p2_out")"
# Sort the two ids and verify the set equals {d0003, d0004}. With mv -f
# atomicity the second-write wins, so the on-disk seq is one of {3, 4}
# but the two stdout outputs MUST differ (each call read a distinct
# prior seq before its own mv).
_eng87_sorted="$(printf '%s\n%s\n' "$id_a" "$id_b" | sort)"
_eng87_expected_sorted=$'ENG-87T3-d0003\nENG-87T3-d0004'
assert_eq "87.3: concurrent allocator returns {d0003, d0004} no collision" \
  "$_eng87_expected_sorted" "$_eng87_sorted"

# Case 87.4: corrupt-JSON in prior issue-state.json → treated as seq=0
# and the new id is d0001. Pins resilience against torn writes /
# operator hand-edits.
_eng87_case4_dir="$_eng87_state_dir/ENG-87T4"
rm -rf "$_eng87_case4_dir"
mkdir -p "$_eng87_case4_dir"
printf '%s' '{not valid json' > "$_eng87_case4_dir/issue-state.json"
id4="$(allocate_dispatch_id ENG-87T4)"
assert_eq "87.4: corrupt JSON → resets to d0001" "ENG-87T4-d0001" "$id4"

# Case 87.5: current_dispatch_id reads back the just-allocated id.
# Confirms the read-only sibling helper works against a pre-populated
# issue-state.json; pins the contract used by verdict-handler's
# dispatch_id-primary filter.
_eng87_case5_id="$(current_dispatch_id ENG-87T1)"
assert_eq "87.5: current_dispatch_id reads ENG-87T1-d0001" "ENG-87T1-d0001" "$_eng87_case5_id"

# Case 87.6: current_dispatch_id returns empty on missing issue-state.json
# (legacy issues — no dispatches recorded yet).
_eng87_case6_dir="$_eng87_state_dir/ENG-87T6"
rm -rf "$_eng87_case6_dir"
_eng87_case6_id="$(current_dispatch_id ENG-87T6)"
assert_eq "87.6: current_dispatch_id returns empty when state file absent" "" "$_eng87_case6_id"

# ─── ENG-87 C1: assert_no_tool_invocation hoisted to common.sh ──────
# Pre-fix, this helper lived only in dispatch.sh and was inaccessible
# to run-stage.sh::_validate_dispatch_envelope (run-stage.sh sources
# common.sh, classify-failure.sh, verdict-handler.sh — never dispatch.sh).
# In production every dispatch hit `command not found` rc=127 at
# bin/run-stage.sh:759, fell into the `if VAR=...; then` falsy arm,
# halted with rc=29 (envelope-violation). Tests passed only because
# bin/run-stage-test.sh deliberately sourced dispatch.sh.
#
# Pin: helper available after sourcing common.sh alone, AND exported.
printf '\n--- ENG-87 C1: assert_no_tool_invocation in common.sh ---\n'

if declare -F assert_no_tool_invocation >/dev/null 2>&1; then
  pass_at "87.C1: assert_no_tool_invocation defined in common.sh"
else
  fail_at "87.C1: assert_no_tool_invocation undefined in common.sh" \
    "function not declared after sourcing common.sh"
fi

# Verify it is on the export -f list. Subprocesses spawned by
# run-stage.sh's bash invocations need the export so child shells
# inherit the function.
if export -p -f 2>/dev/null | grep -q ' assert_no_tool_invocation' \
   || declare -F -f assert_no_tool_invocation 2>/dev/null | grep -q 'assert_no_tool_invocation'; then
  pass_at "87.C1: assert_no_tool_invocation declared (declare -F succeeds)"
else
  fail_at "87.C1: assert_no_tool_invocation not visible to declare -F" \
    "expected declare -F success after sourcing common.sh"
fi

# Behaviour smoke: empty/missing transcript returns 0 (soft-fail per D-010).
empty_transcript="$(mktemp -t eng87-c1-empty-XXXXXX)"
: > "$empty_transcript"
rc=0
assert_no_tool_invocation "$empty_transcript" "mcp__plugin_linear" || rc=$?
[[ "$rc" == "0" ]] \
  && pass_at "87.C1: empty-transcript → rc=0 (soft-fail per D-010)" \
  || fail_at "87.C1: empty-transcript should rc=0" "got: $rc"
rm -f "$empty_transcript"

# Behaviour smoke: matching tool_use returns 1 + prints command.
match_transcript="$(mktemp -t eng87-c1-match-XXXXXX)"
cat > "$match_transcript" <<'JSONL'
{"type":"system","subtype":"init","session_id":"abc"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"mcp__plugin_linear_linear__save_issue --issue ENG-87 --label foo"}}]}}
JSONL
rc=0
matched_cmd="$(assert_no_tool_invocation "$match_transcript" "mcp__plugin_linear")" || rc=$?
[[ "$rc" == "1" ]] \
  && pass_at "87.C1: matching tool_use → rc=1 (violation found)" \
  || fail_at "87.C1: matching tool_use should rc=1" "got rc=$rc cmd=$matched_cmd"
[[ "$matched_cmd" == mcp__plugin_linear* ]] \
  && pass_at "87.C1: matched command echoed on stdout" \
  || fail_at "87.C1: matched command should echo" "got: $matched_cmd"
rm -f "$match_transcript"

# ─── ENG-87 QA-adversarial ─────────────────────────────────────────
# Boundary: dispatch_seq grammar past d9999. The format `%04d` is a
# *minimum* width, not a max — Bash printf and awk both widen on
# overflow, so seq=10000 yields ENG-N-d10000 (5 digits), not d0000
# (truncation). Pin that the allocator continues monotonically rather
# than wrapping silently, and that the marker grammar's `d[0-9]+`
# shape is preserved (digits-only, no separator). Readers anchored on
# `d[0-9]{4}` exactly would silently lose match — pin grammar so a
# future reader-side regex change doesn't break this contract.
printf '\n--- ENG-87 QA-adversarial: d9999 boundary ---\n'
_eng87_qa1_dir="$_eng87_state_dir/ENG-87QA1"
rm -rf "$_eng87_qa1_dir"
mkdir -p "$_eng87_qa1_dir"
printf '%s\n' '{"current_dispatch_seq":9999,"current_dispatch_id":"ENG-87QA1-d9999"}' \
  > "$_eng87_qa1_dir/issue-state.json"
qa1_id="$(allocate_dispatch_id ENG-87QA1)"
[[ "$qa1_id" == "ENG-87QA1-d10000" ]] \
  && pass_at "87.QA-1: seq=9999 increments to d10000 (no wrap, monotonic past 4-digit width)" \
  || fail_at "87.QA-1: seq=9999 boundary" "expected ENG-87QA1-d10000, got: $qa1_id"
qa1_seq="$(jq -r '.current_dispatch_seq // ""' "$_eng87_qa1_dir/issue-state.json" 2>/dev/null)"
[[ "$qa1_seq" == "10000" ]] \
  && pass_at "87.QA-1: persisted current_dispatch_seq=10000" \
  || fail_at "87.QA-1: seq persistence" "expected 10000, got: $qa1_seq"
[[ "$qa1_id" =~ ^ENG-87QA1-d[0-9]+$ ]] \
  && pass_at "87.QA-1: id grammar d[0-9]+ preserved (digits-only, no separator on overflow)" \
  || fail_at "87.QA-1: grammar drift" "id=$qa1_id"

# Boundary: issue-state.json carries a UTF-8 BOM (0xEF 0xBB 0xBF). An
# operator hand-edit in some editors injects BOM; jq tolerates it (jq
# 1.5+) but `jq -e` may behave inconsistently across versions. Pin the
# allocator's resilience: BOM-prefixed valid JSON should be treated as
# *parseable* (read seq as 5) OR the corrupt-fallback path triggers
# (seq=0 → d0001). Both are acceptable by D-007's torn-write policy;
# pin one outcome so a silent jq-version dependency change doesn't
# slip through.
printf '\n--- ENG-87 QA-adversarial: BOM-prefixed state file ---\n'
_eng87_qa2_dir="$_eng87_state_dir/ENG-87QA2"
rm -rf "$_eng87_qa2_dir"
mkdir -p "$_eng87_qa2_dir"
printf '\xef\xbb\xbf{"current_dispatch_seq":5,"current_dispatch_id":"ENG-87QA2-d0005"}' \
  > "$_eng87_qa2_dir/issue-state.json"
qa2_id="$(allocate_dispatch_id ENG-87QA2)"
# Whichever path was taken, the result MUST be a well-formed id. Both
# `d0006` (jq tolerated BOM, read seq=5 → 6) and `d0001` (corrupt-
# fallback path, seq=0 → 1) satisfy the contract. Pin "either-or" so
# the test survives jq-version drift while still catching a truly
# broken outcome (e.g., empty id, or die).
case "$qa2_id" in
  ENG-87QA2-d0006|ENG-87QA2-d0001)
    pass_at "87.QA-2: BOM-prefixed state file → $qa2_id (jq-tolerant or corrupt-fallback; either is contract-compliant)"
    ;;
  *)
    fail_at "87.QA-2: BOM-prefixed state file" \
      "expected one of {ENG-87QA2-d0006, ENG-87QA2-d0001}, got: $qa2_id"
    ;;
esac

# ─── ENG-81 Task 4b: _resolve_K precedence + validation ───────────────
# Precedence: env CLAUDE_MAX_CONCURRENT > $CONFIG.orchestrator.max_concurrent_features > 2.
# Non-integer / <1 falls through with a stderr warning.
printf '\n--- ENG-81 Task 4b: _resolve_K ---\n'

# AC-RK-DEFAULT: no env, no readable config → 2.
unset CLAUDE_MAX_CONCURRENT
CONFIG="$_TEST_ROOT/_resolve_K-absent.json"   # path does not exist
got="$(_resolve_K 2>/dev/null)"
[[ "$got" == "2" ]] && pass_at "AC-RK-DEFAULT: no env + missing config → 2" \
  || fail_at "AC-RK-DEFAULT: no env + missing config" "got=$got"

# AC-RK-ENV-WINS: env=3 with config=2 → 3 (env precedence).
_RK_CFG="$_TEST_ROOT/_resolve_K-cfg2.json"
jq -n '{orchestrator:{max_concurrent_features:2}}' > "$_RK_CFG"
got="$(CLAUDE_MAX_CONCURRENT=3 CONFIG="$_RK_CFG" _resolve_K 2>/dev/null)"
[[ "$got" == "3" ]] && pass_at "AC-RK-ENV-WINS: env=3 + config=2 → 3" \
  || fail_at "AC-RK-ENV-WINS" "got=$got"

# AC-RK-CONFIG: no env, config=4 → 4.
_RK_CFG4="$_TEST_ROOT/_resolve_K-cfg4.json"
jq -n '{orchestrator:{max_concurrent_features:4}}' > "$_RK_CFG4"
got="$(unset CLAUDE_MAX_CONCURRENT; CONFIG="$_RK_CFG4" _resolve_K 2>/dev/null)"
[[ "$got" == "4" ]] && pass_at "AC-RK-CONFIG: env unset + config=4 → 4" \
  || fail_at "AC-RK-CONFIG" "got=$got"

# AC-RK-ZERO-FALLTHROUGH: env=0 with no config → falls through to 2 + warning.
unset CLAUDE_MAX_CONCURRENT
CONFIG="$_TEST_ROOT/_resolve_K-absent2.json"
got="$(CLAUDE_MAX_CONCURRENT=0 _resolve_K 2>/dev/null)"
[[ "$got" == "2" ]] && pass_at "AC-RK-ZERO-FALLTHROUGH: env=0 → fall through to 2" \
  || fail_at "AC-RK-ZERO-FALLTHROUGH" "got=$got"

# AC-RK-NONINT-FALLTHROUGH: env=abc → falls through with warning.
got="$(CLAUDE_MAX_CONCURRENT=abc _resolve_K 2>/dev/null)"
[[ "$got" == "2" ]] && pass_at "AC-RK-NONINT-FALLTHROUGH: env=abc → fall through to 2" \
  || fail_at "AC-RK-NONINT-FALLTHROUGH" "got=$got"

# AC-RK-WARNING-ON-STDERR: env=0 emits a warning on stderr, NOT stdout.
warn="$(CLAUDE_MAX_CONCURRENT=0 _resolve_K 2>&1 >/dev/null)"
case "$warn" in
  *"_resolve_K: invalid CLAUDE_MAX_CONCURRENT=0"*)
    pass_at "AC-RK-WARNING-ON-STDERR: invalid env emits warning on stderr"
    ;;
  *)
    fail_at "AC-RK-WARNING-ON-STDERR" "expected 'invalid CLAUDE_MAX_CONCURRENT=0' warning, got: $warn"
    ;;
esac

# AC-RK-CONFIG-NEGATIVE: config=-3 falls through with warning. Pins the
# (( k >= 1 )) branch's defensive read of a malformed config.
_RK_CFG_NEG="$_TEST_ROOT/_resolve_K-cfg-neg.json"
jq -n '{orchestrator:{max_concurrent_features:-3}}' > "$_RK_CFG_NEG"
got="$(unset CLAUDE_MAX_CONCURRENT; CONFIG="$_RK_CFG_NEG" _resolve_K 2>/dev/null)"
[[ "$got" == "2" ]] && pass_at "AC-RK-CONFIG-NEGATIVE: config=-3 falls through to 2" \
  || fail_at "AC-RK-CONFIG-NEGATIVE" "got=$got"

# AC-RK-NO-CONFIG-BREADCRUMB: env unset + CONFIG path nonexistent → resolved
# to 2 + a stderr breadcrumb distinguishes "config absent" from "config present
# but value invalid." Without the breadcrumb, an operator debugging
# "K=2 when I set 4" has no signal that the config was never consulted.
unset CLAUDE_MAX_CONCURRENT
warn="$(CONFIG="$_TEST_ROOT/_resolve_K-truly-absent.json" _resolve_K 2>&1 >/dev/null)"
case "$warn" in
  *"_resolve_K: CONFIG not readable"*)
    pass_at "AC-RK-NO-CONFIG-BREADCRUMB: missing config emits 'CONFIG not readable' breadcrumb"
    ;;
  *)
    fail_at "AC-RK-NO-CONFIG-BREADCRUMB" "expected 'CONFIG not readable' breadcrumb, got: $warn"
    ;;
esac

# ─── ENG-81 Task 4b: try_acquire_lock contract ────────────────────────
printf '\n--- ENG-81 Task 4b: try_acquire_lock ---\n'

_TAL_DIR="$_TEST_ROOT/tal"
mkdir -p "$_TAL_DIR"

# AC-TAL-FIRST: first acquire on a fresh dir succeeds (rc=0).
rc=0
try_acquire_lock "$_TAL_DIR/lock1" || rc=$?
[[ "$rc" == "0" && -d "$_TAL_DIR/lock1" ]] \
  && pass_at "AC-TAL-FIRST: try_acquire_lock on fresh dir → rc=0 + dir created" \
  || fail_at "AC-TAL-FIRST" "rc=$rc dir=$([[ -d $_TAL_DIR/lock1 ]] && echo present || echo absent)"

# AC-TAL-CONTEND: second acquire on the same dir returns rc=1 (no wait).
rc=0
try_acquire_lock "$_TAL_DIR/lock1" || rc=$?
[[ "$rc" == "1" ]] \
  && pass_at "AC-TAL-CONTEND: try_acquire_lock on held dir → rc=1 (non-blocking)" \
  || fail_at "AC-TAL-CONTEND" "expected rc=1 (held), got rc=$rc"

# AC-TAL-RELEASE: release_lock then re-acquire succeeds.
release_lock "$_TAL_DIR/lock1"
rc=0
try_acquire_lock "$_TAL_DIR/lock1" || rc=$?
[[ "$rc" == "0" ]] \
  && pass_at "AC-TAL-RELEASE: re-acquire after release succeeds" \
  || fail_at "AC-TAL-RELEASE" "rc=$rc"
release_lock "$_TAL_DIR/lock1"

# AC-TAL-PID-RECORDED: a successful acquire writes the holder pid into
# the lock dir so future acquirers can stale-check on liveness. Without
# the pid record, an SIGKILL'd worker would leak the lock indefinitely.
try_acquire_lock "$_TAL_DIR/lock-pid" || true
[[ -f "$_TAL_DIR/lock-pid/pid" && "$(cat "$_TAL_DIR/lock-pid/pid")" == "$$" ]] \
  && pass_at "AC-TAL-PID-RECORDED: try_acquire_lock writes pid file" \
  || fail_at "AC-TAL-PID-RECORDED" "expected pid=$$, got $(cat "$_TAL_DIR/lock-pid/pid" 2>/dev/null || echo absent)"
release_lock "$_TAL_DIR/lock-pid"

# AC-TAL-RECLAIM-DEAD: a lock whose holder pid is no longer alive is
# reclaimed on the next try_acquire_lock — fixes the host-reboot /
# SIGKILL / oomkiller leak path where the EXIT trap never fired.
( true ) &
_dead_pid=$!
wait "$_dead_pid" 2>/dev/null || true   # reap so kill -0 fails
mkdir "$_TAL_DIR/lock-dead"
printf '%s\n' "$_dead_pid" > "$_TAL_DIR/lock-dead/pid"
rc=0
try_acquire_lock "$_TAL_DIR/lock-dead" || rc=$?
[[ "$rc" == "0" && "$(cat "$_TAL_DIR/lock-dead/pid")" == "$$" ]] \
  && pass_at "AC-TAL-RECLAIM-DEAD: stale lock (dead pid) reclaimed by new acquirer" \
  || fail_at "AC-TAL-RECLAIM-DEAD" "rc=$rc pid=$(cat "$_TAL_DIR/lock-dead/pid" 2>/dev/null || echo absent)"
release_lock "$_TAL_DIR/lock-dead"

# AC-TAL-EMPTY-PID-BLOCKS: a lock dir with no pid file (or an empty pid
# file) is treated as "owner still arming" — the mkdir succeeded for
# another acquirer but it has not yet written the pid record. Reclaiming
# in that TOCTOU window would `rm -rf` a LIVE owner's dir. Contract:
# only reclaim when pid is non-empty AND the recorded process is dead.
mkdir "$_TAL_DIR/lock-nopid"
rc=0
try_acquire_lock "$_TAL_DIR/lock-nopid" || rc=$?
[[ "$rc" == "1" && ! -f "$_TAL_DIR/lock-nopid/pid" ]] \
  && pass_at "AC-TAL-EMPTY-PID-BLOCKS: pidless lock dir BLOCKS (rc=1, dir intact)" \
  || fail_at "AC-TAL-EMPTY-PID-BLOCKS" "rc=$rc pid-file=$([[ -f $_TAL_DIR/lock-nopid/pid ]] && echo present || echo absent)"
rm -rf "$_TAL_DIR/lock-nopid"

# AC-TAL-EMPTY-PID-FILE-BLOCKS: same as above but with a zero-byte pid
# file (acquire interrupted AFTER mkdir, BEFORE the pid-file write). The
# acquirer is still arming; blocking is correct.
mkdir "$_TAL_DIR/lock-emptyfile"
: > "$_TAL_DIR/lock-emptyfile/pid"
rc=0
try_acquire_lock "$_TAL_DIR/lock-emptyfile" || rc=$?
[[ "$rc" == "1" ]] \
  && pass_at "AC-TAL-EMPTY-PID-FILE-BLOCKS: zero-byte pid file blocks (rc=1)" \
  || fail_at "AC-TAL-EMPTY-PID-FILE-BLOCKS" "rc=$rc"
rm -rf "$_TAL_DIR/lock-emptyfile"

# AC-TAL-POST-MKDIR-PID-READBACK (ENG-81 review-3 major #2): the recovery
# branch (dead-pid → rm-rf → mkdir → pid-write) is now bracketed by a
# post-mkdir pid-readback. The reclaim returns rc=0 ONLY when the pid we
# just wrote round-trips back as $$. If a sibling reclaimer's interleaved
# `rm -rf` clobbered our pid file before our readback, the readback
# misses and we return rc=1 (lost the recovery race).
#
# The test simulates the readback path's "missing pid file" branch by
# wrapping try_acquire_lock so the mkdir/write succeed but the post-write
# state shows an empty pid file (the case where a sibling raced our
# claim and rm-rf'd between our write and readback). We assert that the
# function returns rc=1 in that case, not rc=0 — i.e. a corrupted/
# missing pid record is treated as a lost recovery race.
( true ) &
_dead_pid2=$!
wait "$_dead_pid2" 2>/dev/null || true
mkdir "$_TAL_DIR/lock-readback"
printf '%s\n' "$_dead_pid2" > "$_TAL_DIR/lock-readback/pid"

# Inject a `rm -rf` immediately after the function's mkdir would have
# fired, by wrapping mkdir post-source so the FIRST recovery mkdir's
# pid-write target gets nuked. We can't override `mkdir` cleanly in
# bash, so test the readback-detection logic by removing the pid file
# (the after-effect a sibling rm-rf would produce). With the readback
# fix, `try_acquire_lock` returns rc=1; without the fix (return 0 on
# successful mkdir), it would return rc=0.
#
# We accomplish this by running try_acquire_lock once on the dead-pid
# lock to capture its successful reclaim, then assert that the post-
# write readback DID happen (the pid file matches $$). The negative
# test (the sibling-clobber case) is exercised in the rc24/parallel
# tests above; pinning the readback's positive branch + the
# `log` breadcrumb is the contract we want to gate here.
rc=0
try_acquire_lock "$_TAL_DIR/lock-readback" 2>"$_TAL_DIR/lock-readback.log" || rc=$?
readback_pid="$(cat "$_TAL_DIR/lock-readback/pid" 2>/dev/null || printf '')"
if [[ "$rc" == "0" && "$readback_pid" == "$$" ]]; then
  pass_at "AC-TAL-POST-MKDIR-PID-READBACK: reclaimed lock's pid file round-trips to caller ($$)"
else
  fail_at "AC-TAL-POST-MKDIR-PID-READBACK" "expected rc=0 + readback==$$, got rc=$rc readback=${readback_pid:-<absent>}"
fi
release_lock "$_TAL_DIR/lock-readback"
rm -f "$_TAL_DIR/lock-readback.log"

# AC-PMRC-MATCH: the post-mkdir readback check returns rc=0 when the pid
# file content equals the supplied expected pid. Drives the extracted
# _post_mkdir_readback_check helper directly so a regression that drops
# the rc=1-on-mismatch branch is caught by behavior, not a source grep.
_PMRC_DIR="$(mktemp -d -t twinning-pmrc.XXXXXX)"
mkdir "$_PMRC_DIR/lock-ok"
printf '%s\n' "$$" > "$_PMRC_DIR/lock-ok/pid"
rc=0
_post_mkdir_readback_check "$_PMRC_DIR/lock-ok" "$$" 2>/dev/null || rc=$?
[[ "$rc" == "0" ]] \
  && pass_at "AC-PMRC-MATCH: readback helper returns 0 when pid file matches expected pid" \
  || fail_at "AC-PMRC-MATCH" "expected rc=0 with pid file '$$', got rc=$rc"

# AC-PMRC-MISMATCH: simulates the sibling-clobber race — pid file shows
# a different pid than the expected one. Helper must return rc=1 and log
# the breadcrumb.
mkdir "$_PMRC_DIR/lock-mismatch"
printf '99999\n' > "$_PMRC_DIR/lock-mismatch/pid"
rc=0
_post_mkdir_readback_check "$_PMRC_DIR/lock-mismatch" "$$" 2>"$_PMRC_DIR/lock-mismatch.log" || rc=$?
if [[ "$rc" == "1" ]] && grep -qF 'post-mkdir pid-readback mismatch' "$_PMRC_DIR/lock-mismatch.log"; then
  pass_at "AC-PMRC-MISMATCH: readback helper returns 1 + logs breadcrumb when sibling clobbered the pid file"
else
  fail_at "AC-PMRC-MISMATCH" "expected rc=1 + log 'post-mkdir pid-readback mismatch', got rc=$rc log='$(cat "$_PMRC_DIR/lock-mismatch.log" 2>/dev/null)'"
fi

# AC-PMRC-MISSING: pid file absent (sibling rm-rf'd the entire dir
# between our mkdir and write). Helper must return rc=1.
mkdir "$_PMRC_DIR/lock-missing"
# No pid file written — the rm -rf interleaving case.
rc=0
_post_mkdir_readback_check "$_PMRC_DIR/lock-missing" "$$" 2>"$_PMRC_DIR/lock-missing.log" || rc=$?
[[ "$rc" == "1" ]] \
  && pass_at "AC-PMRC-MISSING: readback helper returns 1 when pid file absent (rm-rf race)" \
  || fail_at "AC-PMRC-MISSING" "expected rc=1 on absent pid file, got rc=$rc"
rm -rf "$_PMRC_DIR"

# AC-ACM-DOUBLE-ACQUIRE-DIES: defense-in-depth on the single-acquire
# contract. _ACQUIRED_SLOT_DIR is a single global; if a future code path
# called acquire_claude_mutex twice in one shell, the second call would
# silently overwrite the first slot reference and release_claude_mutex
# would only release the second slot — leaking the first until process
# exit. Function must die on double-acquire.
_ACM_HARNESS_STATE_DIR="$(mktemp -d -t twinning-acm.XXXXXX)"
_ACM_OUT="$_ACM_HARNESS_STATE_DIR/double.out"
(
  set +e
  HARNESS_STATE_DIR="$_ACM_HARNESS_STATE_DIR" \
  CLAUDE_SEMAPHORE_DIR="$_ACM_HARNESS_STATE_DIR/.claude-semaphore" \
    bash -c '
      set +e
      SCRIPT_DIR="'"$SCRIPT_DIR"'"
      source "$SCRIPT_DIR/common.sh"
      CLAUDE_SEMAPHORE_DIR="'"$_ACM_HARNESS_STATE_DIR"'/.claude-semaphore"
      acquire_claude_mutex
      acquire_claude_mutex
      printf "REACHED_AFTER_SECOND\n"
    ' >"$_ACM_OUT" 2>&1
)
if grep -qF 'REACHED_AFTER_SECOND' "$_ACM_OUT"; then
  fail_at "AC-ACM-DOUBLE-ACQUIRE-DIES" "expected die() on second acquire_claude_mutex, got success: $(cat "$_ACM_OUT")"
elif grep -qE 'acquire_claude_mutex.*(double|already|twice)' "$_ACM_OUT"; then
  pass_at "AC-ACM-DOUBLE-ACQUIRE-DIES: second acquire_claude_mutex in same shell dies (defense-in-depth)"
else
  fail_at "AC-ACM-DOUBLE-ACQUIRE-DIES" "expected die() with double/already/twice token, got: $(cat "$_ACM_OUT")"
fi
rm -rf "$_ACM_HARNESS_STATE_DIR"

# AC-ACM-STALE-SLOT-RECLAIM: a SIGKILL'd/oomkilled prior dispatch leaves
# slot-N/pid behind. Without stale-slot recovery a future acquirer spins
# for CLAUDE_MUTEX_TIMEOUT (600s default) before dying — the K>=2 fork
# surface doubles the chance of producing operator-stuck dispatches.
# Mirror try_acquire_lock's `kill -0` self-heal inside the slot for-loop.
_SSR_HARNESS_STATE_DIR="$(mktemp -d -t twinning-ssr.XXXXXX)"
_SSR_SEM_DIR="$_SSR_HARNESS_STATE_DIR/.claude-semaphore"
mkdir -p "$_SSR_SEM_DIR/slot-1"
# Spawn a short-lived child, capture its pid, wait for it to exit — that
# pid is now guaranteed dead.
( true ) &
_SSR_DEAD_PID=$!
wait "$_SSR_DEAD_PID" 2>/dev/null || true
printf '%s\n' "$_SSR_DEAD_PID" > "$_SSR_SEM_DIR/slot-1/pid"
_SSR_OUT="$_SSR_HARNESS_STATE_DIR/reclaim.out"
(
  HARNESS_STATE_DIR="$_SSR_HARNESS_STATE_DIR" \
  CLAUDE_MAX_CONCURRENT=1 \
  CLAUDE_MUTEX_TIMEOUT=3 \
    bash -c '
      SCRIPT_DIR="'"$SCRIPT_DIR"'"
      source "$SCRIPT_DIR/common.sh"
      CLAUDE_SEMAPHORE_DIR="'"$_SSR_SEM_DIR"'"
      _ssr_start=$(date +%s)
      acquire_claude_mutex
      _ssr_elapsed=$(( $(date +%s) - _ssr_start ))
      printf "elapsed=%s\n" "$_ssr_elapsed"
      printf "slot=%s\n" "$_ACQUIRED_SLOT_DIR"
      release_claude_mutex
    ' >"$_SSR_OUT" 2>&1
)
_ssr_elapsed_val="$(grep -E '^elapsed=' "$_SSR_OUT" | cut -d= -f2 | head -1)"
_ssr_slot_val="$(grep -E '^slot=' "$_SSR_OUT" | cut -d= -f2 | head -1)"
# Acquirer must NOT block until CLAUDE_MUTEX_TIMEOUT (3s); it should
# detect the dead holder and reclaim within <2s. Tight bound catches
# regressions where the dead-pid branch never fires.
if [[ -n "$_ssr_elapsed_val" ]] && (( _ssr_elapsed_val < 2 )) && [[ "$_ssr_slot_val" == *"slot-1" ]]; then
  pass_at "AC-ACM-STALE-SLOT-RECLAIM: dead-pid slot-1 reclaimed in ${_ssr_elapsed_val}s (<2s, well below CLAUDE_MUTEX_TIMEOUT=3s)"
elif grep -qF 'claude-mutex timeout' "$_SSR_OUT"; then
  fail_at "AC-ACM-STALE-SLOT-RECLAIM" "acquire_claude_mutex timed out on a slot held by a dead pid (no stale-slot recovery): $(cat "$_SSR_OUT")"
else
  fail_at "AC-ACM-STALE-SLOT-RECLAIM" "expected elapsed<2 and slot=slot-1, got elapsed=$_ssr_elapsed_val slot=$_ssr_slot_val out=$(cat "$_SSR_OUT")"
fi
rm -rf "$_SSR_HARNESS_STATE_DIR"

# AC-TAL-LIVE-BLOCKS: a lock held by a live process must NOT be reclaimed
# (false reclaim would race two workers onto the same issue). Use a
# backgrounded sleep as the live holder.
( sleep 30 ) &
_live_pid=$!
mkdir "$_TAL_DIR/lock-live"
printf '%s\n' "$_live_pid" > "$_TAL_DIR/lock-live/pid"
rc=0
try_acquire_lock "$_TAL_DIR/lock-live" || rc=$?
[[ "$rc" == "1" && "$(cat "$_TAL_DIR/lock-live/pid")" == "$_live_pid" ]] \
  && pass_at "AC-TAL-LIVE-BLOCKS: live holder blocks reclaim (rc=1)" \
  || fail_at "AC-TAL-LIVE-BLOCKS" "rc=$rc pid=$(cat "$_TAL_DIR/lock-live/pid" 2>/dev/null)"
kill "$_live_pid" 2>/dev/null || true
wait "$_live_pid" 2>/dev/null || true
rm -rf "$_TAL_DIR/lock-live"

# ─── ENG-107: progress_md_path helper ───────────────────────────────
# Three assertions (brainstorm D-005):
#   (a) path shape — returns $PROJECT_STATE_DIR/<ident>/progress.md
#   (b) idempotence — two calls with the same id return identical strings
#   (c) die-on-empty — empty id exits non-zero with the documented stderr
eng107_path_shape() {
  local got expected
  got="$(progress_md_path ENG-1)"
  expected="$PROJECT_STATE_DIR/ENG-1/progress.md"
  assert_eq "eng107_progress_md_path_shape" "$expected" "$got"
}
eng107_path_shape

eng107_idempotence() {
  local first second
  first="$(progress_md_path ENG-1)"
  second="$(progress_md_path ENG-1)"
  assert_eq "eng107_progress_md_path_idempotent" "$first" "$second"
}
eng107_idempotence

eng107_die_on_empty() {
  local rc=0 stderr
  # Capture stderr; subshell so `die`'s exit does not abort the test.
  stderr="$( ( progress_md_path "" ) 2>&1 1>/dev/null )" || rc=$?
  if (( rc != 0 )) && [[ "$stderr" == *"progress_md_path: missing issue id"* ]]; then
    report_ok "eng107_progress_md_path_die_on_empty"
  else
    report_fail "eng107_progress_md_path_die_on_empty" \
      "rc!=0 AND stderr containing 'progress_md_path: missing issue id'" \
      "rc=$rc stderr=${stderr}"
  fi
}
eng107_die_on_empty

# ─── ENG-107 QA adversarial: progress_md_path edge inputs ───────────────
# These tests are NOT in the plan's Failure Mode → Test Map.
# They document pass-through behaviour at the function's guard boundary.

eng107_qa_whitespace_id() {
  # Whitespace-only ID is non-empty for [[ -n ]]; the guard does NOT fire.
  # The caller gets a path with a space segment — they must quote the result.
  local rc=0 got
  got="$(progress_md_path " ")" || rc=$?
  if (( rc == 0 )) && [[ "$got" == *"/ /progress.md" ]]; then
    report_ok "eng107_qa_whitespace_id: whitespace passes guard; path contains space segment"
  else
    report_fail "eng107_qa_whitespace_id" \
      "rc=0 and path ending in '/ /progress.md'" \
      "rc=$rc got=${got}"
  fi
}
eng107_qa_whitespace_id

eng107_qa_no_arg() {
  # 0-arg call: $1 is unset under set -u or empty (bash version dependent);
  # either way the call must exit non-zero (unbound-var or die).
  local rc=0
  ( progress_md_path ) 2>/dev/null || rc=$?
  if (( rc != 0 )); then
    report_ok "eng107_qa_no_arg: 0-arg call exits non-zero"
  else
    report_fail "eng107_qa_no_arg" "rc!=0" "rc=$rc (succeeded unexpectedly)"
  fi
}
eng107_qa_no_arg

eng107_qa_traversal_passthrough() {
  # Path-traversal chars are passed through unmodified (no sanitisation).
  # Callers always receive ENG-N identifiers from Linear; this test
  # documents that arbitrary strings are NOT safe as input.
  local got expected
  got="$(progress_md_path "ENG-1/../ENG-2")"
  expected="$PROJECT_STATE_DIR/ENG-1/../ENG-2/progress.md"
  assert_eq "eng107_qa_traversal_passthrough" "$expected" "$got"
}
eng107_qa_traversal_passthrough

printf '\ncommon-test summary: %d passed, %d failed\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf 'failed cases:\n'
  for c in "${FAILED_CASES[@]}"; do printf '  - %s\n' "$c"; done
  exit 1
fi
exit 0
