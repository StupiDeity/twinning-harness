#!/usr/bin/env bash
# QA-authored adversarial coverage for run-local-helpers.sh (ENG-14).
#
# Complements run-local-sweep-test.sh (which only exercises
# partition_dirty_paths on plan-enumerated cases). This harness covers:
#   - bucket_for_path boundary inputs
#   - sha12 boundary inputs
#   - assert_stage_allowlist_coverage happy path
#   - partition_dirty_paths inputs not in the plan's Failure Mode map:
#       empty stdin, Unicode filename, many records in one invocation,
#       regex-metachar issue_id, empty issue_id
#   - Snapshot-pipeline (run-local.sh:245-248) behavior on rename records
#
# Two cases deliberately assert the CORRECT behavior for suspected defects
# (`regex_metachar_issue_id_literal_match`, `snapshot_preserves_rename_oldpath`).
# When those defects are present, this harness exits non-zero with the
# failing-case name, which feeds ENG-14's QA bug triage.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"
# shellcheck source=run-local-helpers.sh
source "$SCRIPT_DIR/run-local-helpers.sh"

PASS=0
FAIL=0
FAILED_CASES=()

report_ok() {
  printf 'OK: %s\n' "$1"
  PASS=$((PASS + 1))
}

report_fail() {
  local name="$1" expected="$2" got="$3"
  printf 'FAIL: %s\n' "$name" >&2
  printf '  expected: %s\n' "$expected" >&2
  printf '  got:      %s\n' "$got" >&2
  FAIL=$((FAIL + 1))
  FAILED_CASES+=("$name")
}

assert_eq() {
  local name="$1" expected="$2" got="$3"
  if [[ "$got" == "$expected" ]]; then
    report_ok "$name"
  else
    report_fail "$name" "$expected" "$got"
  fi
}

assert_partition_counts() {
  local name="$1" stage="$2" issue_id="$3"
  local expect_in="$4" expect_leaked="$5" expect_observed="$6"
  local input_file="$7"
  local tdir; tdir="$(mktemp -d -t twinning-adversarial.XXXXXX)"
  local fin="$tdir/in" fleaked="$tdir/leaked" fobserved="$tdir/observed"
  : > "$fin" "$fleaked" "$fobserved"

  partition_dirty_paths "$stage" "$issue_id" \
    3>"$fin" 4>"$fleaked" 5>"$fobserved" < "$input_file"

  local got_in got_leaked got_observed
  got_in="$(tr -cd '\0' < "$fin" | wc -c | tr -d ' ')"
  got_leaked="$(tr -cd '\0' < "$fleaked" | wc -c | tr -d ' ')"
  got_observed="$(tr -cd '\0' < "$fobserved" | wc -c | tr -d ' ')"

  if [[ "$got_in" == "$expect_in" \
        && "$got_leaked" == "$expect_leaked" \
        && "$got_observed" == "$expect_observed" ]]; then
    report_ok "$name"
  else
    report_fail "$name" \
      "in=$expect_in leaked=$expect_leaked observed=$expect_observed" \
      "in=$got_in leaked=$got_leaked observed=$got_observed"
    printf '  in-scope stream:\n' >&2
    tr '\0' '\n' < "$fin"        | sed 's/^/    /' >&2
    printf '  leaked stream:\n' >&2
    tr '\0' '\n' < "$fleaked"    | sed 's/^/    /' >&2
    printf '  observed stream:\n' >&2
    tr '\0' '\n' < "$fobserved"  | sed 's/^/    /' >&2
  fi
  rm -rf "$tdir"
}

# ─── bucket_for_path ────────────────────────────────────────────────────

assert_eq 'bucket_for_path_nested_path' \
  'docs/' \
  "$(bucket_for_path 'docs/brainstorms/foo.md')"

assert_eq 'bucket_for_path_top_level_file' \
  'Cargo.toml' \
  "$(bucket_for_path 'Cargo.toml')"

assert_eq 'bucket_for_path_single_directory' \
  'crates/' \
  "$(bucket_for_path 'crates/lib.rs')"

assert_eq 'bucket_for_path_empty_string' \
  '' \
  "$(bucket_for_path '')"

# Unicode top-level dir: must round-trip the multibyte name intact.
assert_eq 'bucket_for_path_unicode_topdir' \
  'docs🔥/' \
  "$(bucket_for_path 'docs🔥/brainstorms/foo.md')"

# ─── sha12 ──────────────────────────────────────────────────────────────

# SHA-256("") = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
assert_eq 'sha12_empty_string' \
  'e3b0c4429' \
  "$(sha12 '' | cut -c1-9)"

# Length is always exactly 12 chars.
_got_len="$(sha12 'foo' | awk '{print length($0)}')"
assert_eq 'sha12_output_is_12_chars' '12' "$_got_len"

# Deterministic: same input → same digest.
_a="$(sha12 'docs/plans/2026-04-20-eng-14-foo.md')"
_b="$(sha12 'docs/plans/2026-04-20-eng-14-foo.md')"
assert_eq 'sha12_deterministic' "$_a" "$_b"

# Distinct input → distinct digest (collision free for trivial input).
_x="$(sha12 'alpha')"
_y="$(sha12 'beta')"
if [[ "$_x" != "$_y" ]]; then
  report_ok 'sha12_distinct_inputs_distinct_outputs'
else
  report_fail 'sha12_distinct_inputs_distinct_outputs' \
    'distinct digests' "$_x == $_y"
fi

# Long input (1 KiB of 'a').
_long="$(printf 'a%.0s' {1..1024})"
_long_out="$(sha12 "$_long" | awk '{print length($0)}')"
assert_eq 'sha12_long_input_still_12_chars' '12' "$_long_out"

# Unicode input.
_unicode_out="$(sha12 'ドキュメント/plans/foo.md' | awk '{print length($0)}')"
assert_eq 'sha12_unicode_input_12_chars' '12' "$_unicode_out"

# ─── assert_stage_allowlist_coverage ────────────────────────────────────

if ( assert_stage_allowlist_coverage ) >/dev/null 2>&1; then
  report_ok 'assert_stage_allowlist_coverage_happy_path'
else
  report_fail 'assert_stage_allowlist_coverage_happy_path' \
    'exit 0 when all stages defined' \
    "non-zero exit"
fi

# ─── partition_dirty_paths — boundary inputs ────────────────────────────
# Inputs are written to tempfiles so the assertion function runs in the
# current shell (piping into a function would subshell-orphan PASS/FAIL).

_input_dir="$(mktemp -d -t twinning-adversarial-in.XXXXXX)"

: > "$_input_dir/empty"
assert_partition_counts 'partition_empty_stdin' brainstorm ENG-14 0 0 0 \
  "$_input_dir/empty"

printf '?? docs/brainstorms/2026-04-20-ENG-14-ドキュメント-design.md\0' \
  > "$_input_dir/unicode"
assert_partition_counts 'partition_unicode_filename_in_scope' brainstorm ENG-14 1 0 0 \
  "$_input_dir/unicode"

: > "$_input_dir/bulk"
for i in $(seq 1 50); do
  printf '?? docs/brainstorms/2026-04-20-ENG-14-bulk-%02d-design.md\0' "$i" \
    >> "$_input_dir/bulk"
done
assert_partition_counts 'partition_bulk_50_records' brainstorm ENG-14 50 0 0 \
  "$_input_dir/bulk"

{
  printf '?? docs/brainstorms/2026-04-20-ENG-14-foo-design.md\0'
  printf '?? docs/brainstorms/2026-04-20-ENG-11-bar-design.md\0'
  printf '?? docs/brainstorms/2026-04-20-ENG-22-baz-design.md\0'
  printf '?? crates/twinning-core/src/foo.rs\0'
  printf '?? src/lib/components/Bar.svelte\0'
  printf '?? README.md\0'
} > "$_input_dir/mixed"
assert_partition_counts 'partition_mixed_streams_single_call' brainstorm ENG-14 1 2 3 \
  "$_input_dir/mixed"

# Word-boundary: ENG-140 must NOT match ENG-14 (the right-side substring case;
# mirrors ENG-1-vs-ENG-14 in run-local-sweep-test.sh). Without the trailing
# [^a-z0-9]|$ anchor this would false-match.
printf '?? docs/plans/2026-04-20-eng-140-design.md\0' > "$_input_dir/eng140"
assert_partition_counts 'partition_eng140_not_matched_by_eng14' \
  plan ENG-14 0 1 0 "$_input_dir/eng140"

# Copy record (C *) — git -z two-NUL framing identical to rename. Consumes
# source entry, classifies destination once. Mirror of
# rename_record_consumes_source in run-local-sweep-test.sh.
printf 'C  docs/plans/2026-04-20-eng-14-new.md\0docs/plans/2026-04-20-eng-14-old.md\0' \
  > "$_input_dir/copy"
assert_partition_counts 'partition_copy_record_consumes_source' \
  plan ENG-14 1 0 0 "$_input_dir/copy"

# Empty issue_id: D-004 regex MUST NOT spuriously match every basename. A
# legitimately-named ENG-14 brainstorm file must still be routed somewhere
# deterministic (either in-scope or leaked — but the count invariant
# in+leaked+observed must equal the input record count). Asserts no records
# are silently dropped when issue_id is empty.
printf '?? docs/brainstorms/2026-04-20-ENG-14-design.md\0' > "$_input_dir/empty_id"
_tdir_empty="$(mktemp -d -t twinning-empty-id.XXXXXX)"
: > "$_tdir_empty/in" "$_tdir_empty/leaked" "$_tdir_empty/observed"
partition_dirty_paths brainstorm '' \
  3>"$_tdir_empty/in" 4>"$_tdir_empty/leaked" 5>"$_tdir_empty/observed" \
  < "$_input_dir/empty_id"
_sum_in="$(tr -cd '\0' < "$_tdir_empty/in" | wc -c | tr -d ' ')"
_sum_leaked="$(tr -cd '\0' < "$_tdir_empty/leaked" | wc -c | tr -d ' ')"
_sum_observed="$(tr -cd '\0' < "$_tdir_empty/observed" | wc -c | tr -d ' ')"
_sum_total=$((_sum_in + _sum_leaked + _sum_observed))
assert_eq 'partition_empty_issue_id_preserves_record_count' '1' "$_sum_total"
rm -rf "$_tdir_empty"

# ─── SUSPECTED DEFECT 1: regex-metachar issue_id ────────────────────────
# The D-004 regex at run-local-helpers.sh:118 interpolates ${issue_lower}
# unescaped into `[[ "$base_lower" =~ ... ]]`. An issue_id of "a.b" makes
# `.` a regex wildcard; basename `a-b` (which does NOT literally contain
# "a.b") should be classified as leaked-in-scope.
printf '?? docs/brainstorms/2026-04-20-a-b-foo.md\0' \
  > "$_input_dir/regex_metachar"
assert_partition_counts 'regex_metachar_issue_id_literal_match' \
  brainstorm 'a.b' 0 1 0 "$_input_dir/regex_metachar"

rm -rf "$_input_dir"

# ─── SUSPECTED DEFECT 2: snapshot pipeline loses rename oldpath ─────────
# run-local.sh:245-248 does:
#   git status -z --porcelain | tr '\0' '\n' | sed 's/^...//' | sort -u
# git -z rename records emit two NUL entries: `R  newpath\0oldpath\0`.
# The SECOND (oldpath) record has NO `XY ` prefix, but sed strips 3 chars
# unconditionally, corrupting oldpath in the snapshot. Expected: snapshot
# should preserve both full paths.
_tdir="$(mktemp -d -t twinning-adversarial-snap.XXXXXX)"
printf 'R  docs/plans/2026-04-20-eng-14-new.md\0docs/plans/2026-04-20-eng-14-old.md\0' \
  | awk 'BEGIN{RS="\\0"} skip==1 { print; skip=0; next }
         length >= 4 { print substr($0, 4); if ($0 ~ /^(R|C)/) skip=1 }' \
  | sort -u > "$_tdir/snap"
if grep -qxF -- 'docs/plans/2026-04-20-eng-14-old.md' "$_tdir/snap" \
   && grep -qxF -- 'docs/plans/2026-04-20-eng-14-new.md' "$_tdir/snap"; then
  report_ok 'snapshot_preserves_rename_oldpath'
else
  report_fail 'snapshot_preserves_rename_oldpath' \
    'snapshot contains BOTH oldpath and newpath intact' \
    "snap lines: $(tr '\n' '|' < "$_tdir/snap")"
fi
rm -rf "$_tdir"

# ─── SUSPECTED DEFECT 2 (cont.): copy records share the same two-NUL framing
# C<Y> <newpath>\0<oldpath>\0 — must be treated identically to renames so
# that a user `git cp` or git's copy-detection heuristic does not trip the
# self-leak breaker. Same awk program; same assertion shape.
_tdir="$(mktemp -d -t twinning-adversarial-snap-copy.XXXXXX)"
printf 'C  a/new.md\0a/old.md\0' \
  | awk 'BEGIN{RS="\\0"} skip==1 { print; skip=0; next }
         length >= 4 { print substr($0, 4); if ($0 ~ /^(R|C)/) skip=1 }' \
  | sort -u > "$_tdir/snap"
if grep -qxF -- 'a/new.md' "$_tdir/snap" \
   && grep -qxF -- 'a/old.md' "$_tdir/snap"; then
  report_ok 'snapshot_preserves_copy_oldpath'
else
  report_fail 'snapshot_preserves_copy_oldpath' \
    'snapshot contains BOTH oldpath and newpath intact for copy records' \
    "snap lines: $(tr '\n' '|' < "$_tdir/snap")"
fi
rm -rf "$_tdir"

# ─── ENG-17 QA adversarial coverage ─────────────────────────────────────
# QA-authored cases NOT in the plan's Failure Mode → Test Map. These cover
# breakages surfaced by a cold-reviewer pass over the awk pipeline that
# the plan-enumerated tests do not exercise.

# Shared helper: run the awk stage under test against a fixture on stdin.
# Reads printf-ready fixture (with literal \0) and emits sort -u'd snapshot
# to $1. All QA cases use the SAME awk program as run-local.sh and the
# rename/copy tests above — drift between the three call sites is a P0.
_snap_pipeline() {
  local out="$1"
  awk 'BEGIN{RS="\\0"} skip==1 { print; skip=0; next }
       length >= 4 { print substr($0, 4); if ($0 ~ /^(R|C)/) skip=1 }' \
    | sort -u > "$out"
}

# QA-1 (failure-mode): regex anchor must isolate the FIRST character only.
# A basename beginning with `R` (e.g. `Readme.md`) after a `?? ` untracked
# status code would, under a broken anchor, set skip=1 and consume the
# NEXT record as if it were an oldpath — corrupting the snapshot. Covers
# the "regex is anchored to the STATUS column, not the path" invariant.
_tdir="$(mktemp -d -t twinning-qa-snap-r-anchor.XXXXXX)"
printf '?? Readme.md\0?? other.md\0' \
  | _snap_pipeline "$_tdir/snap"
if grep -qxF -- 'Readme.md' "$_tdir/snap" \
   && grep -qxF -- 'other.md' "$_tdir/snap" \
   && [[ "$(wc -l < "$_tdir/snap" | tr -d ' ')" == '2' ]]; then
  report_ok 'qa_snapshot_untracked_R_prefix_no_false_skip'
else
  report_fail 'qa_snapshot_untracked_R_prefix_no_false_skip' \
    'both Readme.md and other.md present, exactly 2 lines' \
    "snap lines: $(tr '\n' '|' < "$_tdir/snap")"
fi
rm -rf "$_tdir"

# QA-2 (failure-mode): two-letter XY code `RM` (staged rename + worktree
# modify). The first char is still `R`, so the regex must still match and
# the oldpath (second NUL record) must be emitted verbatim. Exercises a
# realistic porcelain v1 emission not covered by the plain `R ` test.
_tdir="$(mktemp -d -t twinning-qa-snap-rm.XXXXXX)"
printf 'RM staged-new.md\0staged-old.md\0' \
  | _snap_pipeline "$_tdir/snap"
if grep -qxF -- 'staged-new.md' "$_tdir/snap" \
   && grep -qxF -- 'staged-old.md' "$_tdir/snap" \
   && [[ "$(wc -l < "$_tdir/snap" | tr -d ' ')" == '2' ]]; then
  report_ok 'qa_snapshot_RM_two_letter_xy_preserves_oldpath'
else
  report_fail 'qa_snapshot_RM_two_letter_xy_preserves_oldpath' \
    'both staged-new.md and staged-old.md present, exactly 2 lines' \
    "snap lines: $(tr '\n' '|' < "$_tdir/snap")"
fi
rm -rf "$_tdir"

# QA-3 (failure-mode): multiple consecutive renames in a single stream.
# The skip=0 reset after each oldpath must cycle cleanly — a sticky skip
# flag would drop alternating newpaths. Plan explicitly scopes this out
# of committed tests as "transitively covered"; QA adds the explicit
# case because state machines merit explicit multi-cycle coverage.
_tdir="$(mktemp -d -t twinning-qa-snap-multi.XXXXXX)"
printf 'R  a.md\0b.md\0R  c.md\0d.md\0C  e.md\0f.md\0' \
  | _snap_pipeline "$_tdir/snap"
if grep -qxF -- 'a.md' "$_tdir/snap" \
   && grep -qxF -- 'b.md' "$_tdir/snap" \
   && grep -qxF -- 'c.md' "$_tdir/snap" \
   && grep -qxF -- 'd.md' "$_tdir/snap" \
   && grep -qxF -- 'e.md' "$_tdir/snap" \
   && grep -qxF -- 'f.md' "$_tdir/snap" \
   && [[ "$(wc -l < "$_tdir/snap" | tr -d ' ')" == '6' ]]; then
  report_ok 'qa_snapshot_consecutive_renames_and_copies'
else
  report_fail 'qa_snapshot_consecutive_renames_and_copies' \
    'all 6 paths (a-f) present, exactly 6 lines' \
    "snap lines: $(tr '\n' '|' < "$_tdir/snap")"
fi
rm -rf "$_tdir"

# QA-4 (boundary): empty input — clean worktree at tick-start. Awk must
# produce an empty snapshot (zero bytes). Non-empty output here would
# cause the downstream classifier to misclassify any path against phantom
# lines.
_tdir="$(mktemp -d -t twinning-qa-snap-empty.XXXXXX)"
: | _snap_pipeline "$_tdir/snap"
if [[ ! -s "$_tdir/snap" ]]; then
  report_ok 'qa_snapshot_empty_input_produces_empty_file'
else
  report_fail 'qa_snapshot_empty_input_produces_empty_file' \
    'zero-byte snapshot' \
    "snap lines: $(tr '\n' '|' < "$_tdir/snap")"
fi
rm -rf "$_tdir"

# QA-5 (boundary): short oldpath (1 char) — skip branch MUST run before
# the `length >= 4` guard, else a legal 1-char filename following an R/C
# record would be silently dropped. Explicit coverage of the branch order.
_tdir="$(mktemp -d -t twinning-qa-snap-short.XXXXXX)"
printf 'R  some/long/path.md\0y\0' \
  | _snap_pipeline "$_tdir/snap"
if grep -qxF -- 'some/long/path.md' "$_tdir/snap" \
   && grep -qxF -- 'y' "$_tdir/snap" \
   && [[ "$(wc -l < "$_tdir/snap" | tr -d ' ')" == '2' ]]; then
  report_ok 'qa_snapshot_short_oldpath_one_char'
else
  report_fail 'qa_snapshot_short_oldpath_one_char' \
    'both long newpath and 1-char oldpath present, exactly 2 lines' \
    "snap lines: $(tr '\n' '|' < "$_tdir/snap")"
fi
rm -rf "$_tdir"

# QA-6 (portability): BSD awk on macOS with RS="\\0". Plan D-001 verifies
# this empirically at plan-write time via /usr/bin/awk 20200816; the QA
# suite automates it as a CI-resident regression so a future awk upgrade
# or helper-extraction that accidentally reverts RS to the plain-string
# form `"\0"` trips here (BSD awk with RS="\0" reads only the first
# record of a NUL stream; plan Success Criterion #7). Skips cleanly
# on hosts without /usr/bin/awk.
if [[ -x /usr/bin/awk ]]; then
  _tdir="$(mktemp -d -t twinning-qa-snap-bsd.XXXXXX)"
  printf 'R  bsd-new.md\0bsd-old.md\0?? bsd-untracked.md\0' \
    | /usr/bin/awk 'BEGIN{RS="\\0"} skip==1 { print; skip=0; next }
                    length >= 4 { print substr($0, 4); if ($0 ~ /^(R|C)/) skip=1 }' \
    | sort -u > "$_tdir/snap"
  if grep -qxF -- 'bsd-new.md' "$_tdir/snap" \
     && grep -qxF -- 'bsd-old.md' "$_tdir/snap" \
     && grep -qxF -- 'bsd-untracked.md' "$_tdir/snap" \
     && [[ "$(wc -l < "$_tdir/snap" | tr -d ' ')" == '3' ]]; then
    report_ok 'qa_snapshot_bsd_awk_RS_regex_escape_portable'
  else
    report_fail 'qa_snapshot_bsd_awk_RS_regex_escape_portable' \
      'BSD /usr/bin/awk emits all 3 records with RS="\\0"' \
      "snap lines: $(tr '\n' '|' < "$_tdir/snap")"
  fi
  rm -rf "$_tdir"
else
  printf 'SKIP: qa_snapshot_bsd_awk_RS_regex_escape_portable (no /usr/bin/awk)\n'
fi

# ─── Summary ────────────────────────────────────────────────────────────

printf '\n'
printf 'adversarial summary: %d passed, %d failed\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf 'failed cases:\n'
  for c in "${FAILED_CASES[@]}"; do
    printf '  - %s\n' "$c"
  done
  exit 1
fi
