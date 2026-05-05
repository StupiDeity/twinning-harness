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

printf '\ncommon-test summary: %d passed, %d failed\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf 'failed cases:\n'
  for c in "${FAILED_CASES[@]}"; do printf '  - %s\n' "$c"; done
  exit 1
fi
exit 0
