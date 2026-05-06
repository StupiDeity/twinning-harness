#!/usr/bin/env bash
# ENG-51 — profile-driven scope allowlist + dispatch tool extensions.
#
# Two surfaces:
#   1. run-local-helpers.sh::stage_output_paths reads
#      config.json::scope.allowlist.<stage>[] for implementing|ui|qa,
#      falling back to the hardcoded Tauri-shaped list when the key is
#      missing or the value is empty/non-array.
#   2. dispatch.sh::allowed_tools_for reads
#      config.json::dispatch.tools.<stage>[] and APPENDS each entry to
#      the hardcoded base, leaving the base unchanged when missing.
#
# Coverage target (acceptance criterion #5):
#   (a) profile-driven allowlist read
#   (b) fallback when profile is missing or partial
#   (c) per-stage override resolution order (one stage configured does
#       not affect any other)
#
# Both surfaces preserve the existing Tauri target's behavior when
# config.json carries no override (AC #4 regression guarantee).

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export PIPELINE_DRY_RUN=1
: "${LINEAR_API_KEY:=test-mock-key}"
export LINEAR_API_KEY
export PROJECT_SLUG="${PROJECT_SLUG:-test-slug}"

# Per-test scaffold lives under platform tempdir; safety check before any rm.
_TEST_ROOT="$(mktemp -d -t twinning-eng51.XXXXXX)"
_assert_temp_path() {
  case "$1" in
    /var/folders/*|/tmp/*|/private/var/folders/*|/private/tmp/*) return 0 ;;
    *) printf 'REFUSING: %q is not a platform temp dir\n' "$1" >&2; exit 99 ;;
  esac
}
_assert_temp_path "$_TEST_ROOT"
trap 'case "$_TEST_ROOT" in /var/folders/*|/tmp/*|/private/var/folders/*|/private/tmp/*) rm -rf "$_TEST_ROOT" ;; esac' EXIT

# A baseline TARGET_REPO with no scope/dispatch overrides — this is what
# common.sh reads at source time. Per-test CONFIG variations are loaded
# by overriding the `CONFIG` env var on a single function invocation.
export TARGET_REPO="$_TEST_ROOT/target"
mkdir -p "$TARGET_REPO/.pipeline-config/schemas"
jq -n '{
  project: { slug: "test-slug" },
  linear: { team_id: "t", project_id: "p", stage_label_prefix: "stage:",
            native_states: { inbox: "Todo", active: "In Progress", done: "Done" },
            workflow_stages: [] },
  orchestrator: { paused: false, max_concurrent_features: 2, alert_on_halted_over: 5 }
}' > "$TARGET_REPO/.pipeline-config/config.json"
jq -n '{labels:{},states:{}}' > "$TARGET_REPO/.pipeline-config/schemas/linear-ids.json"

export HARNESS_STATE_DIR="$_TEST_ROOT/state"
export PROJECT_STATE_DIR="$HARNESS_STATE_DIR/test-slug"
mkdir -p "$PROJECT_STATE_DIR"

# Source order matters: common.sh first (sets CONFIG/HARNESS_ROOT and
# `set -e`), then the two units under test.
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"
# shellcheck source=run-local-helpers.sh
source "$SCRIPT_DIR/run-local-helpers.sh"
# shellcheck source=dispatch.sh
source "$SCRIPT_DIR/dispatch.sh"

# Disable -e so assertion mismatches don't abort the whole run; keep -u/pipefail.
set +e

PASS=0
FAIL=0
FAILED=()

ok()   { printf 'OK: %s\n' "$1"; PASS=$((PASS+1)); }
ng()   { printf 'FAIL: %s\n  expected: %s\n  got:      %s\n' "$1" "$2" "$3" >&2
         FAIL=$((FAIL+1)); FAILED+=("$1"); }
eq()   { if [[ "$3" == "$2" ]]; then ok "$1"; else ng "$1" "$2" "$3"; fi }
contains()    { if [[ "$3" == *"$2"* ]];   then ok "$1"; else ng "$1" "contains: $2" "$3"; fi }
notcontains() { if [[ "$3" != *"$2"* ]];   then ok "$1"; else ng "$1" "absent:   $2" "$3"; fi }

# Write a config.json under $1 (a fresh tempdir) merging $2 (a JSON object
# fragment) onto the baseline. Returns the absolute path to config.json.
mkconfig() {
  local dir="$1" extra="$2"
  mkdir -p "$dir"
  if [[ -n "$extra" ]]; then
    jq -n --argjson extra "$extra" '
      ({
        project: { slug: "test-slug" },
        linear: { team_id: "t", project_id: "p", stage_label_prefix: "stage:",
                  native_states: { inbox: "Todo", active: "In Progress", done: "Done" },
                  workflow_stages: [] },
        orchestrator: { paused: false, max_concurrent_features: 2, alert_on_halted_over: 5 }
      } + $extra)
    ' > "$dir/config.json"
  else
    jq -n '{
      project: { slug: "test-slug" },
      linear: { team_id: "t", project_id: "p", stage_label_prefix: "stage:",
                native_states: { inbox: "Todo", active: "In Progress", done: "Done" },
                workflow_stages: [] },
      orchestrator: { paused: false, max_concurrent_features: 2, alert_on_halted_over: 5 }
    }' > "$dir/config.json"
  fi
  printf '%s' "$dir/config.json"
}

# ─── Surface 1: stage_output_paths ──────────────────────────────────────
printf '\n--- stage_output_paths: profile-driven scope allowlist ---\n'

# (b) Fallback: missing scope key → hardcoded Tauri-shaped list.
TAURI_EXPECTED='Cargo.lock,Cargo.toml,bun.lock,bun.lockb,crates/,docs/,package-lock.json,package.json,src-tauri/,src/,tests/'

cfg="$(mkconfig "$_TEST_ROOT/cfg-empty" '')"
got="$(CONFIG="$cfg" stage_output_paths implementing | LC_ALL=C sort | paste -sd, -)"
eq 'fallback_implement_matches_legacy_tauri_list' "$TAURI_EXPECTED" "$got"

got="$(CONFIG="$cfg" stage_output_paths ui | LC_ALL=C sort | paste -sd, -)"
eq 'fallback_ui_matches_legacy_tauri_list' "$TAURI_EXPECTED" "$got"

got="$(CONFIG="$cfg" stage_output_paths qa | LC_ALL=C sort | paste -sd, -)"
eq 'fallback_qa_matches_legacy_tauri_list' "$TAURI_EXPECTED" "$got"

# (b) Fallback: completely missing CONFIG file → hardcoded list.
got="$(CONFIG="/nonexistent/path/config.json" stage_output_paths implementing | LC_ALL=C sort | paste -sd, -)"
eq 'fallback_when_config_file_missing' "$TAURI_EXPECTED" "$got"

# (a) Override: scope.allowlist.implementing REPLACES the hardcoded list.
cfg="$(mkconfig "$_TEST_ROOT/cfg-impl" '{
  "scope": { "allowlist": { "implementing": ["bin/", "AGENT_PROMPTS.md", "docs/"] } }
}')"
got="$(CONFIG="$cfg" stage_output_paths implementing | LC_ALL=C sort | paste -sd, -)"
eq 'override_implement_replaces_fallback' \
  'AGENT_PROMPTS.md,bin/,docs/' "$got"

# (c) Per-stage isolation: implementing override does NOT leak to ui/qa.
got="$(CONFIG="$cfg" stage_output_paths ui | LC_ALL=C sort | paste -sd, -)"
eq 'override_does_not_leak_to_ui' "$TAURI_EXPECTED" "$got"

got="$(CONFIG="$cfg" stage_output_paths qa | LC_ALL=C sort | paste -sd, -)"
eq 'override_does_not_leak_to_qa' "$TAURI_EXPECTED" "$got"

# Per-stage divergence: each stage carries its own list.
cfg="$(mkconfig "$_TEST_ROOT/cfg-three" '{
  "scope": { "allowlist": {
    "implementing": ["bin/"],
    "ui":        ["src/", "static/"],
    "qa":        ["tests/", "e2e/"]
  } }
}')"
eq 'override_implement_divergent' 'bin/' \
  "$(CONFIG="$cfg" stage_output_paths implementing | LC_ALL=C sort | paste -sd, -)"
eq 'override_ui_divergent'        'src/,static/' \
  "$(CONFIG="$cfg" stage_output_paths ui | LC_ALL=C sort | paste -sd, -)"
eq 'override_qa_divergent'        'e2e/,tests/' \
  "$(CONFIG="$cfg" stage_output_paths qa | LC_ALL=C sort | paste -sd, -)"

# (b) Defensive fallback: empty array means "fall back" — an empty
# configured allowlist would route every dirty path to self-leak,
# which is almost certainly a misconfiguration.
cfg="$(mkconfig "$_TEST_ROOT/cfg-empty-arr" '{
  "scope": { "allowlist": { "implementing": [] } }
}')"
got="$(CONFIG="$cfg" stage_output_paths implementing | LC_ALL=C sort | paste -sd, -)"
eq 'empty_array_override_falls_back_to_hardcoded' "$TAURI_EXPECTED" "$got"

# Defensive: non-array value (string instead of list) → fallback.
cfg="$(mkconfig "$_TEST_ROOT/cfg-bad-type" '{
  "scope": { "allowlist": { "implementing": "bin/" } }
}')"
got="$(CONFIG="$cfg" stage_output_paths implementing | LC_ALL=C sort | paste -sd, -)"
eq 'non_array_override_falls_back_to_hardcoded' "$TAURI_EXPECTED" "$got"

# Defensive: non-string entries silently dropped.
cfg="$(mkconfig "$_TEST_ROOT/cfg-mixed" '{
  "scope": { "allowlist": { "implementing": ["bin/", 42, null, "AGENT_PROMPTS.md"] } }
}')"
got="$(CONFIG="$cfg" stage_output_paths implementing | LC_ALL=C sort | paste -sd, -)"
eq 'non_string_entries_silently_dropped' 'AGENT_PROMPTS.md,bin/' "$got"

# scope.allowlist must NOT affect brainstorming/planning/retrospective stages.
cfg="$(mkconfig "$_TEST_ROOT/cfg-brain-attempt" '{
  "scope": { "allowlist": {
    "brainstorming":    ["should/not/win/"],
    "planning":          ["also/not/"],
    "retrospective": ["nope/"]
  } }
}')"
eq 'scope_allowlist_does_not_alter_brainstorm' \
  'docs/brainstorms/,docs/knowledge/decisions.md' \
  "$(CONFIG="$cfg" stage_output_paths brainstorming | LC_ALL=C sort | paste -sd, -)"
eq 'scope_allowlist_does_not_alter_plan' \
  'docs/plans/' \
  "$(CONFIG="$cfg" stage_output_paths planning | LC_ALL=C sort | paste -sd, -)"
RETRO_EXPECTED='.github/workflows/,.pipeline-config/config.json,docs/knowledge/conventions.md,docs/knowledge/decisions.md,docs/knowledge/gotchas.md,docs/knowledge/qa-patterns.md'
eq 'scope_allowlist_does_not_alter_retrospective' \
  "$RETRO_EXPECTED" \
  "$(CONFIG="$cfg" stage_output_paths retrospective | LC_ALL=C sort | paste -sd, -)"

# read-mostly stages still emit nothing (review|build|release).
got="$(CONFIG="$cfg" stage_output_paths review)"
eq 'review_stage_remains_read_mostly' '' "$got"

# ─── Surface 2: allowed_tools_for ───────────────────────────────────────
printf '\n--- allowed_tools_for: dispatch.tools.<stage>[] extras ---\n'

# (b) Fallback: no dispatch.tools key → base only, no trailing comma.
cfg="$(mkconfig "$_TEST_ROOT/cfg-tools-empty" '')"
base_implement="$(CONFIG="$cfg" allowed_tools_for implementing)"
contains 'fallback_base_includes_cargo' 'Bash(cargo:*)' "$base_implement"
contains 'fallback_base_includes_bun'   'Bash(bun:*)'   "$base_implement"
notcontains 'fallback_base_no_trailing_comma' ',,'      "$base_implement"
case "$base_implement" in
  *,) ng 'fallback_base_no_trailing_comma_at_end' 'no trailing comma' "$base_implement" ;;
  *)  ok 'fallback_base_no_trailing_comma_at_end' ;;
esac

# (a) Override: extras appended after the base, joined with comma.
cfg="$(mkconfig "$_TEST_ROOT/cfg-tools-impl" '{
  "dispatch": { "tools": { "implementing": [
    "Bash(bash bin/run-local-helpers-adversarial-test.sh:*)",
    "Bash(shellcheck:*)"
  ] } }
}')"
got="$(CONFIG="$cfg" allowed_tools_for implementing)"
contains 'extras_present_test_runner' \
  'Bash(bash bin/run-local-helpers-adversarial-test.sh:*)' "$got"
contains 'extras_present_shellcheck' 'Bash(shellcheck:*)' "$got"
contains 'extras_appended_after_base_cargo' 'Bash(cargo:*)' "$got"
# Comma-separated, with extras after base.
case "$got" in
  *"Bash(cargo:*)"*"Bash(shellcheck:*)"*) ok 'extras_ordered_after_base' ;;
  *) ng 'extras_ordered_after_base' 'shellcheck after cargo' "$got" ;;
esac

# (c) Per-stage isolation: implementing extras don't leak to ui/qa/build.
ui_tools="$(CONFIG="$cfg" allowed_tools_for ui)"
notcontains 'extras_do_not_leak_to_ui' 'Bash(shellcheck:*)' "$ui_tools"
qa_tools="$(CONFIG="$cfg" allowed_tools_for qa)"
notcontains 'extras_do_not_leak_to_qa' 'Bash(shellcheck:*)' "$qa_tools"
build_tools="$(CONFIG="$cfg" allowed_tools_for build)"
notcontains 'extras_do_not_leak_to_build' 'Bash(shellcheck:*)' "$build_tools"

# Each stage can carry its own extras independently.
cfg="$(mkconfig "$_TEST_ROOT/cfg-tools-multi" '{
  "dispatch": { "tools": {
    "implementing": ["Bash(pytest:*)"],
    "qa":        ["Bash(go test:*)"],
    "ui":        ["Bash(rspec:*)"]
  } }
}')"
contains 'multi_implement'   'Bash(pytest:*)'   "$(CONFIG="$cfg" allowed_tools_for implementing)"
contains 'multi_qa'          'Bash(go test:*)'  "$(CONFIG="$cfg" allowed_tools_for qa)"
contains 'multi_ui'          'Bash(rspec:*)'    "$(CONFIG="$cfg" allowed_tools_for ui)"
notcontains 'multi_iso_impl_no_go'    'Bash(go test:*)'  "$(CONFIG="$cfg" allowed_tools_for implementing)"
notcontains 'multi_iso_qa_no_pytest'  'Bash(pytest:*)'   "$(CONFIG="$cfg" allowed_tools_for qa)"
notcontains 'multi_iso_ui_no_pytest'  'Bash(pytest:*)'   "$(CONFIG="$cfg" allowed_tools_for ui)"

# Defensive: non-array value → no extras.
cfg="$(mkconfig "$_TEST_ROOT/cfg-tools-bad" '{
  "dispatch": { "tools": { "implementing": "Bash(pytest:*)" } }
}')"
got="$(CONFIG="$cfg" allowed_tools_for implementing)"
notcontains 'non_array_dispatch_tools_silently_ignored' 'Bash(pytest:*)' "$got"

# Defensive: non-string entries silently dropped.
cfg="$(mkconfig "$_TEST_ROOT/cfg-tools-mixed" '{
  "dispatch": { "tools": { "implementing": ["Bash(pytest:*)", 99, null, "Bash(ruff:*)"] } }
}')"
got="$(CONFIG="$cfg" allowed_tools_for implementing)"
contains    'mixed_string_pytest_kept' 'Bash(pytest:*)' "$got"
contains    'mixed_string_ruff_kept'   'Bash(ruff:*)'   "$got"
notcontains 'mixed_no_literal_99'      ',99,'           "$got"
notcontains 'mixed_no_literal_null'    'null'           "$got"

# Empty array → no extras, no trailing comma.
cfg="$(mkconfig "$_TEST_ROOT/cfg-tools-empty-arr" '{
  "dispatch": { "tools": { "implementing": [] } }
}')"
got="$(CONFIG="$cfg" allowed_tools_for implementing)"
case "$got" in
  *,) ng 'empty_extras_no_trailing_comma' 'no trailing comma' "$got" ;;
  *)  ok 'empty_extras_no_trailing_comma' ;;
esac

# Regression: missing CONFIG file path → no extras (defensive, matches
# the dispatch_timeout_minutes pattern in main()).
got="$(CONFIG="/nonexistent/path/config.json" allowed_tools_for implementing)"
contains 'missing_config_file_returns_base_implement' 'Bash(cargo:*)' "$got"
case "$got" in
  *,) ng 'missing_config_file_no_trailing_comma' 'no trailing comma' "$got" ;;
  *)  ok 'missing_config_file_no_trailing_comma' ;;
esac

# ─── ENG-76: prompt-utility patterns must be in their stage's allowlist ─
# ENG-62 (May 2026) surfaced a longstanding gap: the review prompt tells
# the agent to bump `bash bin/guards.sh bump <issue> review_rejection`,
# but the reviewing stage allowlist did not include `Bash(bash bin/guards.sh:*)`.
# Same gap on QA (`qa_rejection`) and release (`slack.sh info` + `metrics.sh release`).
# The agents gracefully degraded by noting the gap in their rejection
# comment, but counters never bumped, Slack notifications never posted,
# and release events never landed in events.jsonl. Pin the patterns now
# so a future allowlist edit can't quietly drop them again.
printf '\n--- ENG-76: stage allowlists carry the utilities the prompts invoke ---\n'

cfg="$(mkconfig "$_TEST_ROOT/cfg-eng76" '')"

# review: prompt says `guards.sh bump <issue> review_rejection`.
review_tools="$(CONFIG="$cfg" allowed_tools_for reviewing)"
contains 'eng76_review_carries_guards_dotpipeline' \
  'Bash(bash .pipeline/bin/guards.sh:*)' "$review_tools"
contains 'eng76_review_carries_guards_bin' \
  'Bash(bash bin/guards.sh:*)' "$review_tools"

# qa: prompt says `guards.sh bump <issue> qa_rejection`.
qa_tools="$(CONFIG="$cfg" allowed_tools_for qa)"
contains 'eng76_qa_carries_guards_dotpipeline' \
  'Bash(bash .pipeline/bin/guards.sh:*)' "$qa_tools"
contains 'eng76_qa_carries_guards_bin' \
  'Bash(bash bin/guards.sh:*)' "$qa_tools"

# release: prompt says `slack.sh info` + `metrics.sh release`.
release_tools="$(CONFIG="$cfg" allowed_tools_for released)"
contains 'eng76_release_carries_slack_dotpipeline' \
  'Bash(bash .pipeline/bin/slack.sh:*)' "$release_tools"
contains 'eng76_release_carries_slack_bin' \
  'Bash(bash bin/slack.sh:*)' "$release_tools"
contains 'eng76_release_carries_metrics_dotpipeline' \
  'Bash(bash .pipeline/bin/metrics.sh:*)' "$release_tools"
contains 'eng76_release_carries_metrics_bin' \
  'Bash(bash bin/metrics.sh:*)' "$release_tools"

# build: prompt says `slack.sh info / warn` (already present pre-ENG-76; pin it).
build_tools="$(CONFIG="$cfg" allowed_tools_for building)"
contains 'eng76_build_carries_slack_dotpipeline' \
  'Bash(bash .pipeline/bin/slack.sh:*)' "$build_tools"
contains 'eng76_build_carries_slack_bin' \
  'Bash(bash bin/slack.sh:*)' "$build_tools"

# Negative: stages that don't invoke these utilities should NOT have
# them granted — least-privilege defense (e.g. brainstorm/plan/implement/ui
# don't bump counters or post Slack).
for stg in brainstorming planning implementing ui; do
  tools="$(CONFIG="$cfg" allowed_tools_for "$stg")"
  notcontains "eng76_${stg}_no_guards" 'Bash(bash bin/guards.sh:*)' "$tools"
  notcontains "eng76_${stg}_no_slack"  'Bash(bash bin/slack.sh:*)'  "$tools"
  notcontains "eng76_${stg}_no_metrics" 'Bash(bash bin/metrics.sh:*)' "$tools"
done

# ─── Summary ────────────────────────────────────────────────────────────
printf '\nRESULTS: %d passed, %d failed\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf 'failed cases:\n'
  for c in "${FAILED[@]}"; do printf '  - %s\n' "$c"; done
  exit 1
fi
exit 0
