#!/usr/bin/env bash
# Test harness for run-local-helpers.sh's partition_dirty_paths.
# Wired into dry-run.sh. Exits non-zero on first failing case.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"
# shellcheck source=run-local-helpers.sh
source "$SCRIPT_DIR/run-local-helpers.sh"

assert_partition() {
  local name="$1" stage="$2" issue_id="$3"
  local expect_in="$4" expect_leaked="$5" expect_observed="$6"
  local tdir; tdir="$(mktemp -d -t twinning-sweep-test.XXXXXX)"
  local fin="$tdir/in" fleaked="$tdir/leaked" fobserved="$tdir/observed"
  : > "$fin" "$fleaked" "$fobserved"

  partition_dirty_paths "$stage" "$issue_id" \
    3>"$fin" 4>"$fleaked" 5>"$fobserved"

  local got_in got_leaked got_observed
  got_in="$(tr -cd '\0' < "$fin" | wc -c | tr -d ' ')"
  got_leaked="$(tr -cd '\0' < "$fleaked" | wc -c | tr -d ' ')"
  got_observed="$(tr -cd '\0' < "$fobserved" | wc -c | tr -d ' ')"

  if [[ "$got_in" == "$expect_in" && "$got_leaked" == "$expect_leaked" \
        && "$got_observed" == "$expect_observed" ]]; then
    printf 'OK: %s\n' "$name"; rm -rf "$tdir"; return 0
  fi
  printf 'FAIL: %s\n' "$name" >&2
  printf '  expected: in=%s leaked=%s observed=%s\n' \
    "$expect_in" "$expect_leaked" "$expect_observed" >&2
  printf '  got:      in=%s leaked=%s observed=%s\n' \
    "$got_in" "$got_leaked" "$got_observed" >&2
  printf '  in-scope stream:\n' >&2
  tr '\0' '\n' < "$fin" | sed 's/^/    /' >&2
  printf '  leaked stream:\n' >&2
  tr '\0' '\n' < "$fleaked" | sed 's/^/    /' >&2
  printf '  observed stream:\n' >&2
  tr '\0' '\n' < "$fobserved" | sed 's/^/    /' >&2
  rm -rf "$tdir"; exit 1
}

# 1: brainstorm in-scope D-004 hit
printf '?? docs/brainstorms/2026-04-20-ENG-14-foo-design.md\0' \
  | assert_partition brainstorm_in_scope_d004_hit brainstorm ENG-14 1 0 0

# 2: brainstorm D-004 miss — same directory, other issue
printf '?? docs/brainstorms/2026-04-20-ENG-11-bar-design.md\0' \
  | assert_partition brainstorm_d004_miss_excludes_other_issue brainstorm ENG-14 0 1 0

# 3: plan D-004 case-insensitive hit
printf '?? docs/plans/2026-04-20-eng-14-foo.md\0' \
  | assert_partition plan_d004_case_insensitive_match plan ENG-14 1 0 0

# 4: build stage rejects brainstorm dir
printf '?? docs/brainstorms/anything.md\0' \
  | assert_partition build_rejects_brainstorm_dir build ENG-5 0 0 1

# (ENG-12 case 5 dropped — common telemetry entries removed per ENG-13.)

# 6: path-boundary — brainstorms-archive MUST NOT match brainstorms
printf '?? docs/brainstorms-archive/foo.md\0' \
  | assert_partition path_boundary_archive_excluded brainstorm ENG-14 0 0 1

# 7: filename with embedded space
printf '?? docs/brainstorms/2026-04-20-ENG-14-with space-design.md\0' \
  | assert_partition filename_with_spaces_handled brainstorm ENG-14 1 0 0

# 8: rename record consumes source
printf 'R  docs/plans/2026-04-20-eng-14-new.md\0docs/plans/2026-04-20-eng-14-old.md\0' \
  | assert_partition rename_record_consumes_source plan ENG-14 1 0 0

# 9: word-boundary — ENG-1 must NOT match ENG-14
printf '?? docs/plans/2026-04-20-eng-1-foo.md\0' \
  | assert_partition eng_1_does_not_match_eng_14 plan ENG-14 0 1 0

# 10: stage_output_paths dies on unknown stage. `die` calls `exit 1`, so
# wrap in `( ... )` subshells to prevent the exit from killing the harness.
case10_out="$( ( stage_output_paths "bogus-stage" >/dev/null ) 2>&1 || true )"
case10_rc="$( ( stage_output_paths "bogus-stage" >/dev/null ) 2>/dev/null; printf '%s' $? )"
if [[ "$case10_rc" == "0" ]]; then
  printf 'FAIL: assertion_dies_on_missing_stage — expected non-zero exit\n' >&2; exit 1
fi
if [[ "$case10_out" != *"unknown stage"* ]]; then
  printf 'FAIL: assertion_dies_on_missing_stage — stderr missing "unknown stage": %s\n' "$case10_out" >&2; exit 1
fi
printf 'OK: assertion_dies_on_missing_stage\n'

# 11: source file observed, not staged (brainstorm stage)
printf ' M crates/twinning-pipeline/src/foo.rs\0' \
  | assert_partition source_file_observed_not_staged brainstorm ENG-14 0 0 1

# 12 (new for ENG-13): implement stage sweeps Rust source without D-004
printf ' M crates/twinning-pipeline/src/foo.rs\0' \
  | assert_partition implement_stage_sweeps_rust_source implement ENG-14 1 0 0

# 13 (new for ENG-13, updated for ENG-23): retrospective allowlist now covers
# `.pipeline-config/config.json` (target-repo config) — `.pipeline/learned-rules/`
# moved to the harness repo and is no longer target-relative.
printf ' M .pipeline-config/config.json\0' \
  | assert_partition retrospective_pipeline_config_in_scope retrospective ENG-14 1 0 0

printf 'All sweep-test cases passed.\n'
