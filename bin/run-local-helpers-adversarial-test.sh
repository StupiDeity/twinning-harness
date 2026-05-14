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
export PROJECT_SLUG="${PROJECT_SLUG:-test-slug}"
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
assert_partition_counts 'partition_empty_stdin' brainstorming ENG-14 0 0 0 \
  "$_input_dir/empty"

printf '?? docs/brainstorms/2026-04-20-ENG-14-ドキュメント-design.md\0' \
  > "$_input_dir/unicode"
assert_partition_counts 'partition_unicode_filename_in_scope' brainstorming ENG-14 1 0 0 \
  "$_input_dir/unicode"

: > "$_input_dir/bulk"
for i in $(seq 1 50); do
  printf '?? docs/brainstorms/2026-04-20-ENG-14-bulk-%02d-design.md\0' "$i" \
    >> "$_input_dir/bulk"
done
assert_partition_counts 'partition_bulk_50_records' brainstorming ENG-14 50 0 0 \
  "$_input_dir/bulk"

{
  printf '?? docs/brainstorms/2026-04-20-ENG-14-foo-design.md\0'
  printf '?? docs/brainstorms/2026-04-20-ENG-11-bar-design.md\0'
  printf '?? docs/brainstorms/2026-04-20-ENG-22-baz-design.md\0'
  printf '?? crates/twinning-core/src/foo.rs\0'
  printf '?? src/lib/components/Bar.svelte\0'
  printf '?? README.md\0'
} > "$_input_dir/mixed"
assert_partition_counts 'partition_mixed_streams_single_call' brainstorming ENG-14 1 2 3 \
  "$_input_dir/mixed"

# Word-boundary: ENG-140 must NOT match ENG-14 (the right-side substring case;
# mirrors ENG-1-vs-ENG-14 in run-local-sweep-test.sh). Without the trailing
# [^a-z0-9]|$ anchor this would false-match.
printf '?? docs/plans/2026-04-20-eng-140-design.md\0' > "$_input_dir/eng140"
assert_partition_counts 'partition_eng140_not_matched_by_eng14' \
  planning ENG-14 0 1 0 "$_input_dir/eng140"

# Copy record (C *) — git -z two-NUL framing identical to rename. Consumes
# source entry, classifies destination once. Mirror of
# rename_record_consumes_source in run-local-sweep-test.sh.
printf 'C  docs/plans/2026-04-20-eng-14-new.md\0docs/plans/2026-04-20-eng-14-old.md\0' \
  > "$_input_dir/copy"
assert_partition_counts 'partition_copy_record_consumes_source' \
  planning ENG-14 1 0 0 "$_input_dir/copy"

# Empty issue_id: D-004 regex MUST NOT spuriously match every basename. A
# legitimately-named ENG-14 brainstorm file must still be routed somewhere
# deterministic (either in-scope or leaked — but the count invariant
# in+leaked+observed must equal the input record count). Asserts no records
# are silently dropped when issue_id is empty.
printf '?? docs/brainstorms/2026-04-20-ENG-14-design.md\0' > "$_input_dir/empty_id"
_tdir_empty="$(mktemp -d -t twinning-empty-id.XXXXXX)"
: > "$_tdir_empty/in" "$_tdir_empty/leaked" "$_tdir_empty/observed"
partition_dirty_paths brainstorming '' \
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
  brainstorming 'a.b' 0 1 0 "$_input_dir/regex_metachar"

# ─── QA-authored adversarial coverage for ENG-16 (metachar escape) ──────
# These cases are NOT in the plan's Failure Mode -> Test Map. Each one
# exercises a metachar class the plan's single `a.b` case does not, plus
# the positive-match symmetry and a sequential-invocation state check.

# Positive-match symmetry: plan's `regex_metachar_issue_id_literal_match`
# tests the negative (a.b vs a-b-foo -> leaked). This is the positive
# (a.b vs a.b-foo with literal `.`) -> in-scope. Confirms the escape is
# not over-aggressive (i.e. doesn't block legitimate literal matches).
printf '?? docs/brainstorms/2026-04-20-a.b-foo.md\0' \
  > "$_input_dir/qa_metachar_positive"
assert_partition_counts 'qa_metachar_dot_positive_literal_match' \
  brainstorming 'a.b' 1 0 0 "$_input_dir/qa_metachar_positive"

# Alternation metachar `|`. Without escape, ERE `a|b` means "match a OR b"
# and the top-level `(^|[^a-z0-9])a|b([^a-z0-9]|$)` parses as
# `((^|[^a-z0-9])a) | (b([^a-z0-9]|$))`. Basename `2026-04-20-a-foo.md`
# has `-a-` (non-alnum/a/non-alnum) -> unescaped routes in-scope.
# With escape (`a\|b`), requires literal `a|b` -> absent -> leaked.
printf '?? docs/brainstorms/2026-04-20-a-foo.md\0' \
  > "$_input_dir/qa_metachar_pipe"
assert_partition_counts 'qa_metachar_pipe_no_false_match' \
  brainstorming 'a|b' 0 1 0 "$_input_dir/qa_metachar_pipe"

# Kleene star `*`. Without escape, ERE `a*b` means "zero or more a's then b",
# which matches `b` preceded by any boundary. Basename `2026-04-20-b-foo.md`
# has `-b-` -> unescaped routes in-scope. With escape (`a\*b`), requires
# literal `a*b` -> absent -> leaked.
printf '?? docs/brainstorms/2026-04-20-b-foo.md\0' \
  > "$_input_dir/qa_metachar_star"
assert_partition_counts 'qa_metachar_star_no_false_match' \
  brainstorming 'a*b' 0 1 0 "$_input_dir/qa_metachar_star"

# Parentheses as capture group. Without escape, ERE `feat(x)` makes `(x)`
# a 1-char capture group, so the pattern matches literal `featx` with
# boundaries. Basename `xyz-featx-foo.md` -> unescaped routes in-scope.
# With escape (`feat\(x\)`), requires literal `feat(x)` -> absent -> leaked.
printf '?? docs/brainstorms/2026-04-20-xyz-featx-foo.md\0' \
  > "$_input_dir/qa_metachar_parens"
assert_partition_counts 'qa_metachar_parens_no_false_match' \
  brainstorming 'feat(x)' 0 1 0 "$_input_dir/qa_metachar_parens"

# Leading-metachar boundary composition. issue_id beginning with an
# escaped metachar must still compose cleanly with the left-boundary
# `(^|[^a-z0-9])` anchor. issue_id `.eng` against basename `.eng-foo.md`
# -> `\.eng` matches literal `.eng` preceded by ^ -> in-scope.
printf '?? docs/brainstorms/.eng-foo.md\0' \
  > "$_input_dir/qa_metachar_leading"
assert_partition_counts 'qa_metachar_leading_dot_boundary_match' \
  brainstorming '.eng' 1 0 0 "$_input_dir/qa_metachar_leading"

# Backslash in issue_id (plan Open Question 4 — explicit post-merge
# follow-up, promoted to committed coverage here). issue_id `a\b` is three
# literal chars. Sed escape produces `a\\b` (4 chars). POSIX ERE reads
# `\\` as literal `\`, so the regex requires literal `a\b` in basename.
# Basename `a-b-foo.md` has no backslash -> leaked.
printf '?? docs/brainstorms/2026-04-20-a-b-foo.md\0' \
  > "$_input_dir/qa_metachar_backslash"
assert_partition_counts 'qa_metachar_backslash_no_false_match' \
  brainstorming 'a\b' 0 1 0 "$_input_dir/qa_metachar_backslash"

# Sequential-invocation state integrity. `issue_lower_re` must be a
# function-local, so a metachar-bearing first call does not leak its
# escaped regex into a metachar-free second call. First invocation uses
# `a.b`; second uses `ENG-14`. If `issue_lower_re` leaked, the second
# call would re-use `a\.b` as its pattern and the ENG-14 basename would
# be misrouted. Assert the second call routes 1 record to in-scope.
_qa_state_dir="$(mktemp -d -t twinning-qa-state.XXXXXX)"
printf '?? docs/brainstorms/2026-04-20-a-b-foo.md\0' \
  > "$_qa_state_dir/first_in"
printf '?? docs/brainstorms/2026-04-20-ENG-14-foo.md\0' \
  > "$_qa_state_dir/second_in"
: > "$_qa_state_dir/first_fd3" "$_qa_state_dir/first_fd4" "$_qa_state_dir/first_fd5"
: > "$_qa_state_dir/second_fd3" "$_qa_state_dir/second_fd4" "$_qa_state_dir/second_fd5"
partition_dirty_paths brainstorming 'a.b' \
  3>"$_qa_state_dir/first_fd3" 4>"$_qa_state_dir/first_fd4" 5>"$_qa_state_dir/first_fd5" \
  < "$_qa_state_dir/first_in"
partition_dirty_paths brainstorming 'ENG-14' \
  3>"$_qa_state_dir/second_fd3" 4>"$_qa_state_dir/second_fd4" 5>"$_qa_state_dir/second_fd5" \
  < "$_qa_state_dir/second_in"
_state_second_in="$(tr -cd '\0' < "$_qa_state_dir/second_fd3" | wc -c | tr -d ' ')"
assert_eq 'qa_no_state_bleed_between_invocations' '1' "$_state_second_in"
rm -rf "$_qa_state_dir"

# Long metachar-bearing issue_id. Sed must handle a 200-char id (100
# repetitions of `x.`) without truncation; the resulting regex (~300
# chars) must be well-formed in bash's `[[ =~ ]]` and still route a
# non-matching basename to leaked.
_qa_long_id=""
for _ in $(seq 1 100); do _qa_long_id+='x.'; done
printf '?? docs/brainstorms/2026-04-20-nomatch-foo.md\0' \
  > "$_input_dir/qa_metachar_long_id"
assert_partition_counts 'qa_metachar_long_id_no_false_match' \
  brainstorming "$_qa_long_id" 0 1 0 "$_input_dir/qa_metachar_long_id"

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

# ─── acquire_lock — concurrent race (ENG-8) ─────────────────────────────
# Bug class (Linear ENG-8, 2026-04-18): two overlapping pipeline ticks
# both call acquire_lock on the same lock_dir; at most one must win.
# Fork two background subshells, each attempting acquisition, capture
# both exit codes, assert the sum is exactly 1. The lock directory is
# a fresh mktemp path whose parent exists but whose leaf does not —
# that is the state acquire_lock's mkdir branch races against.
_tdir="$(mktemp -d -t twinning-adversarial-lock.XXXXXX)"
_lock_path="$_tdir/lock"
_rc_a="$_tdir/rc_a"
_rc_b="$_tdir/rc_b"
# common.sh has already enabled `set -e`; capture acquire_lock's exit
# status with `|| rc=$?` so the losing subshell doesn't abort before
# writing its rc file.
(
  _rc=0
  acquire_lock "$_lock_path" || _rc=$?
  printf '%s\n' "$_rc" > "$_rc_a"
) &
_pid_a=$!
(
  _rc=0
  acquire_lock "$_lock_path" || _rc=$?
  printf '%s\n' "$_rc" > "$_rc_b"
) &
_pid_b=$!
wait "$_pid_a" || true
wait "$_pid_b" || true
_val_a="$(cat "$_rc_a" 2>/dev/null || echo X)"
_val_b="$(cat "$_rc_b" 2>/dev/null || echo X)"
if [[ "$_val_a" =~ ^[0-9]+$ && "$_val_b" =~ ^[0-9]+$ ]]; then
  _sum=$(( _val_a + _val_b ))
else
  _sum="invalid(a=$_val_a,b=$_val_b)"
fi
assert_eq 'concurrent_acquire_lock_exactly_one_winner' '1' "$_sum"
rm -rf "$_tdir"

# ─── acquire_lock — QA adversarial coverage (ENG-8) ─────────────────────
# QA-authored checks beyond the plan's Failure Mode → Test Map. These
# guard against regressions a future refactor could introduce: pid-file
# contents, live-holder clobber, and the explicit-argument contract.

# qa_acquire_lock_writes_calling_pid_to_pidfile
# Boundary assertion on the documented side effect: after a fresh
# acquisition, $lock_dir/pid must contain the calling shell's $$.
_qtdir="$(mktemp -d -t twinning-adversarial-lock-qa.XXXXXX)"
_qlock="$_qtdir/lock"
acquire_lock "$_qlock"
_qwrote="$(cat "$_qlock/pid" 2>/dev/null || echo MISSING)"
assert_eq 'qa_acquire_lock_writes_calling_pid_to_pidfile' "$$" "$_qwrote"
rm -rf "$_qtdir"

# qa_acquire_lock_live_holder_rejected_without_clobber
# Pre-seed the lock dir with our own live PID, then call acquire_lock:
# expected rc=1, and the pid file must still contain the original
# PID (i.e. the relocated function must not `rm -rf` a live lock).
_qtdir="$(mktemp -d -t twinning-adversarial-lock-qa.XXXXXX)"
_qlock="$_qtdir/lock"
mkdir "$_qlock"
printf '%s\n' "$$" > "$_qlock/pid"
_qorig="$(cat "$_qlock/pid")"
_qrc=0
acquire_lock "$_qlock" || _qrc=$?
_qafter="$(cat "$_qlock/pid" 2>/dev/null || echo MISSING)"
assert_eq 'qa_acquire_lock_live_holder_rejected_rc' '1' "$_qrc"
assert_eq 'qa_acquire_lock_live_holder_pidfile_preserved' "$_qorig" "$_qafter"
rm -rf "$_qtdir"

# qa_acquire_lock_uses_arg_not_lock_dir_global
# Contract assertion: the relocated function takes the lock path as an
# explicit positional argument and must not fall back to a caller-side
# $LOCK_DIR global. Unset LOCK_DIR in a subshell, then call acquire_lock
# with an explicit arg — expect rc=0 and the explicit path to exist.
_qtdir="$(mktemp -d -t twinning-adversarial-lock-qa.XXXXXX)"
_qlock="$_qtdir/explicit-lock"
_qrc=0
(
  unset LOCK_DIR
  acquire_lock "$_qlock"
) || _qrc=$?
_qexists='no'
[[ -d "$_qlock" ]] && _qexists='yes'
assert_eq 'qa_acquire_lock_explicit_arg_rc' '0' "$_qrc"
assert_eq 'qa_acquire_lock_explicit_arg_path_created' 'yes' "$_qexists"
rm -rf "$_qtdir"

# ─── Summary ────────────────────────────────────────────────────────────

# ─── Gap #6: state.local.json paused override is honored ──────────────
# Reproducer for ENG-49 Gap #6. config.json::orchestrator.paused=true must
# be overridden by state.local.json::orchestrator.paused=false so the
# orchestrator can resume after a manual paused-state edit. Both poll.sh
# and run-local.sh must consult is_orchestrator_paused (not config_get).
test_paused_override_honored() {
  local tdir; tdir="$(mktemp -d -t twinning-paused.XXXXXX)"
  local cfg="$tdir/config.json" sf="$tdir/state.local.json"
  jq -n '{orchestrator:{paused:true}}' > "$cfg"
  jq -n '{orchestrator:{paused:false}}' > "$sf"
  local got
  CONFIG="$cfg" STATE_FILE="$sf" got="$(is_orchestrator_paused)"
  assert_eq "paused-override state.local wins" "false" "$got"
  rm -rf "$tdir"
}
test_paused_override_honored

# Verify poll.sh and run-local.sh USE is_orchestrator_paused, not the
# bypass call config_get '.orchestrator.paused'. This is a static check:
# fail if the bypass appears outside common.sh (its definitional home).
test_paused_callsites_use_helper() {
  local bypass_found=0
  [[ $(grep -c "config_get.*'\.orchestrator\.paused'" "$SCRIPT_DIR/poll.sh" 2>/dev/null) -gt 0 ]] && bypass_found=1
  [[ $(grep -c "config_get.*'\.orchestrator\.paused'" "$SCRIPT_DIR/run-local.sh" 2>/dev/null) -gt 0 ]] && bypass_found=1
  assert_eq "no config_get bypass in poll.sh/run-local.sh" "0" "$bypass_found"
}
test_paused_callsites_use_helper

# ─── ENG-53 #2: trip_breaker writes to STATE_FILE, not CONFIG ──────────
# Pre-fix: trip_breaker did `grep '"paused": false' $CONFIG && sed s/.../`,
# which (a) silently no-op'd when CONFIG already had paused:true, and
# (b) couldn't override state.local.json's paused:false runtime override
# even on success. Observed during ENG-44's dogfood run: 7+ trips, zero
# actual halts. Fix: trip_breaker calls set_orchestrator_paused true,
# writing to the same STATE_FILE lane is_orchestrator_paused reads.
test_trip_breaker_overrides_state_local_false() {
  local tdir; tdir="$(mktemp -d -t twinning-trip-breaker.XXXXXX)"
  local cfg="$tdir/config.json" sf="$tdir/state.local.json"
  # Operator's resume override: state.local.json says paused=false.
  # CONFIG also says paused=false (the original sed-target). Pre-fix,
  # the sed would flip CONFIG to paused=true, but is_orchestrator_paused
  # still reads paused=false from state.local.json — net halt: nothing.
  jq -n '{orchestrator:{paused:false}}' > "$cfg"
  jq -n '{orchestrator:{paused:false}}' > "$sf"

  CONFIG="$cfg" STATE_FILE="$sf" trip_breaker >/dev/null 2>&1

  local got
  got="$(CONFIG="$cfg" STATE_FILE="$sf" is_orchestrator_paused)"
  assert_eq "trip_breaker overrides state.local.json paused=false" "true" "$got"

  # Belt-and-suspenders: STATE_FILE itself should now show paused=true.
  local state_value
  state_value="$(jq -r '.orchestrator.paused' "$sf")"
  assert_eq "trip_breaker writes STATE_FILE.orchestrator.paused=true" "true" "$state_value"
  rm -rf "$tdir"
}
test_trip_breaker_overrides_state_local_false

# Bonus: when CONFIG already has paused=true (e.g., harness ships
# paused-by-default and the operator unpaused via STATE_FILE), the pre-fix
# grep for `"paused": false` failed and the breaker logged "leaving
# as-is". Post-fix, trip_breaker writes STATE_FILE regardless of CONFIG's
# state — so the breaker still halts.
test_trip_breaker_works_when_config_already_paused() {
  local tdir; tdir="$(mktemp -d -t twinning-trip-breaker.XXXXXX)"
  local cfg="$tdir/config.json" sf="$tdir/state.local.json"
  jq -n '{orchestrator:{paused:true}}' > "$cfg"
  jq -n '{orchestrator:{paused:false}}' > "$sf"

  CONFIG="$cfg" STATE_FILE="$sf" trip_breaker >/dev/null 2>&1

  local got
  got="$(CONFIG="$cfg" STATE_FILE="$sf" is_orchestrator_paused)"
  assert_eq "trip_breaker halts even when CONFIG already paused=true" "true" "$got"
  rm -rf "$tdir"
}
test_trip_breaker_works_when_config_already_paused

# ─── ENG-53 #5: frontmatter-based D-004 fallback ────────────────────────
# Pre-fix: D-004 only checked the basename for the issue-id token. If the
# brainstorm/plan agent wrote a doc with the correct `linear: ENG-N`
# frontmatter but a basename slugged-from-title (no eng-N), the doc was
# leaked-in-scope and never committed. Observed on ENG-44's dogfood run.
# Post-fix: when basename mismatches, partition_dirty_paths ALSO checks
# the file's first 20 lines for `^linear:[[:space:]]+ENG-N$`. CLAUDE.md
# says frontmatter is the canonical mapping; reconcile.sh already greps
# it. Now partition_dirty_paths agrees.
test_frontmatter_d004_in_scope() {
  local tdir; tdir="$(mktemp -d -t twinning-frontmatter.XXXXXX)"
  local subdir="$tdir/docs/brainstorms"
  mkdir -p "$subdir"
  # Filename has NO eng-44 token (the ENG-44 brainstorm scenario).
  local doc="$subdir/2026-04-30-orchestrator-paused-design.md"
  cat > "$doc" <<'MD'
---
linear: ENG-44
title: orchestrator paused override fix
date: 2026-04-30
---

# Brainstorm
MD
  local fixture="$tdir/in" leaked="$tdir/leaked" observed="$tdir/observed"
  : > "$fixture" "$leaked" "$observed"

  (
    cd "$tdir"
    printf '?? docs/brainstorms/2026-04-30-orchestrator-paused-design.md\0' \
      | partition_dirty_paths brainstorming ENG-44 \
        3>"$fixture" 4>"$leaked" 5>"$observed"
  )

  local got_in got_leaked
  got_in="$(tr -cd '\0' < "$fixture" | wc -c | tr -d ' ')"
  got_leaked="$(tr -cd '\0' < "$leaked" | wc -c | tr -d ' ')"
  assert_eq "ENG-53#5 frontmatter-only routes in-scope (basename token absent)" '1' "$got_in"
  assert_eq "ENG-53#5 frontmatter-only NOT leaked-in-scope" '0' "$got_leaked"
  rm -rf "$tdir"
}
test_frontmatter_d004_in_scope

# Negative: file has frontmatter pointing at a DIFFERENT issue → leaked.
test_frontmatter_d004_wrong_issue_leaked() {
  local tdir; tdir="$(mktemp -d -t twinning-frontmatter.XXXXXX)"
  local subdir="$tdir/docs/brainstorms"
  mkdir -p "$subdir"
  local doc="$subdir/2026-04-30-orchestrator-paused-design.md"
  cat > "$doc" <<'MD'
---
linear: ENG-99
title: a different issue's brainstorm
---

# Brainstorm
MD
  local fixture="$tdir/in" leaked="$tdir/leaked" observed="$tdir/observed"
  : > "$fixture" "$leaked" "$observed"

  (
    cd "$tdir"
    printf '?? docs/brainstorms/2026-04-30-orchestrator-paused-design.md\0' \
      | partition_dirty_paths brainstorming ENG-44 \
        3>"$fixture" 4>"$leaked" 5>"$observed"
  )
  local got_in got_leaked
  got_in="$(tr -cd '\0' < "$fixture" | wc -c | tr -d ' ')"
  got_leaked="$(tr -cd '\0' < "$leaked" | wc -c | tr -d ' ')"
  assert_eq "ENG-53#5 wrong-issue frontmatter routes leaked-in-scope" '0' "$got_in"
  assert_eq "ENG-53#5 wrong-issue frontmatter routes leaked-in-scope (leaked count)" '1' "$got_leaked"
  rm -rf "$tdir"
}
test_frontmatter_d004_wrong_issue_leaked

# Negative: file is missing on disk (e.g., deleted record D) → frontmatter
# check returns 1 (file unreadable), basename mismatch → leaked. Pre-fix
# behavior preserved.
test_frontmatter_d004_missing_file_leaked() {
  local tdir; tdir="$(mktemp -d -t twinning-frontmatter.XXXXXX)"
  mkdir -p "$tdir/docs/brainstorms"
  # Note: NOT creating the file. The path exists only in the git-status record.
  local fixture="$tdir/in" leaked="$tdir/leaked" observed="$tdir/observed"
  : > "$fixture" "$leaked" "$observed"

  (
    cd "$tdir"
    printf 'D  docs/brainstorms/2026-04-30-deleted-design.md\0' \
      | partition_dirty_paths brainstorming ENG-44 \
        3>"$fixture" 4>"$leaked" 5>"$observed"
  )
  local got_leaked
  got_leaked="$(tr -cd '\0' < "$leaked" | wc -c | tr -d ' ')"
  assert_eq "ENG-53#5 missing file (deleted) routes leaked-in-scope" '1' "$got_leaked"
  rm -rf "$tdir"
}
test_frontmatter_d004_missing_file_leaked

# Positive: matching basename token AND matching frontmatter → in-scope
# (existing behavior preserved; basename takes precedence per the
# fast-path order in partition_dirty_paths).
test_frontmatter_d004_basename_match_unchanged() {
  local tdir; tdir="$(mktemp -d -t twinning-frontmatter.XXXXXX)"
  mkdir -p "$tdir/docs/brainstorms"
  local doc="$tdir/docs/brainstorms/2026-04-30-eng-44-orchestrator-paused-design.md"
  cat > "$doc" <<'MD'
---
linear: ENG-44
---
MD
  local fixture="$tdir/in" leaked="$tdir/leaked" observed="$tdir/observed"
  : > "$fixture" "$leaked" "$observed"

  (
    cd "$tdir"
    printf '?? docs/brainstorms/2026-04-30-eng-44-orchestrator-paused-design.md\0' \
      | partition_dirty_paths brainstorming ENG-44 \
        3>"$fixture" 4>"$leaked" 5>"$observed"
  )
  local got_in
  got_in="$(tr -cd '\0' < "$fixture" | wc -c | tr -d ' ')"
  assert_eq "ENG-53#5 basename match still routes in-scope" '1' "$got_in"
  rm -rf "$tdir"
}
test_frontmatter_d004_basename_match_unchanged

# ─── ENG-69: per-issue halt vs. global breaker ────────────────────────────
# Regression lock for the 2026-05-05 ENG-63 incident: a stray test fixture
# left behind by a review-stage agent's run was classified as self-leak by
# the tick-end sweep and unconditionally tripped the GLOBAL
# orchestrator.paused breaker on first occurrence. ENG-64 and ENG-65 (both
# stage:implementing with no halt of their own) were silently blocked across
# 63 launchd ticks until manual intervention. The tests below verify the
# new lane separation:
#   1. self-leak halts only the affected issue (per-issue lane via
#      classify_failure with skip-until-human-acts)
#   2. leaked-in-scope at threshold halts only the affected issue
#   3. rc=24 (linear-post-failed) still trips the global breaker; any
#      other non-zero rc routes per-issue
#   4. cross-issue isolation regression lock — multi-tick sequence where
#      ENG-A's halt does not block ENG-B/ENG-C clean runs

# Build a stubs dir with a no-op metrics.sh that logs args to
# $STUB_METRICS_LOG. _eng69_make_stubs always writes the script body fresh
# so repeated calls are safe in-suite.
_eng69_make_stubs() {
  local sd="$1"
  mkdir -p "$sd"
  cat > "$sd/metrics.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_METRICS_LOG"
STUB
  chmod +x "$sd/metrics.sh"
}

# ─── ENG-69 #1: halt_issue_for_self_leak routes per-issue ─────────────────

test_halt_issue_for_self_leak_per_issue_routes_correctly() {
  local tdir; tdir="$(mktemp -d -t twinning-eng69-selfleak.XXXXXX)"
  local stub_dir="$tdir/stubs"
  _eng69_make_stubs "$stub_dir"
  local classify_log="$tdir/classify.log"
  : > "$classify_log"
  export STUB_METRICS_LOG="$tdir/metrics.log"
  : > "$STUB_METRICS_LOG"

  # `|| true` so a non-zero rc from the helper does not propagate set -e
  # to the parent shell (which would abort the test script before we
  # reach the assertion block below).
  (
    SCRIPT_DIR="$stub_dir"
    PROJECT_STATE_DIR="$tdir/state"
    mkdir -p "$PROJECT_STATE_DIR"
    set_orchestrator_paused() { printf '%s\n' "$1" > "$tdir/paused"; }
    is_orchestrator_paused()  { cat "$tdir/paused" 2>/dev/null || printf 'false'; }
    # Pipe-separated capture so the reason field's spaces don't collide with
    # field boundaries when assertions parse it back out.
    classify_failure() {
      printf '%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" "$5" >> "$classify_log"
    }
    halt_issue_for_self_leak ENG-901 reviewing aabbccdd1122 ddeeff334455 \
      >/dev/null 2>&1
  ) || true

  # 1a. classify_failure called with the per-issue policy + new exit code.
  local got_call; got_call="$(awk -F'|' '{printf "issue=%s stage=%s policy=%s exit=%s",$1,$2,$3,$5}' "$classify_log")"
  assert_eq "ENG-69#1 self-leak routes per-issue (skip-until-human-acts, exit 27)" \
    "issue=ENG-901 stage=reviewing policy=skip-until-human-acts exit=27" \
    "$got_call"

  # 1b. reason field carries the leak hashes verbatim and contains no
  #     raw filesystem paths (security P1-1).
  local got_reason; got_reason="$(awk -F'|' '{print $4}' "$classify_log")"
  case "$got_reason" in
    *aabbccdd1122*ddeeff334455*) report_ok "ENG-69#1 self-leak reason carries both hashes" ;;
    *) report_fail "ENG-69#1 self-leak reason carries both hashes" \
         "contains aabbccdd1122 and ddeeff334455" "$got_reason" ;;
  esac
  case "$got_reason" in
    */*) report_fail "ENG-69#1 self-leak reason has no raw paths" \
         "no '/' in reason" "$got_reason" ;;
    *)   report_ok "ENG-69#1 self-leak reason has no raw paths" ;;
  esac

  # 1c. hash-list slice matches the hex-only regex (no positional swaps,
  #     no zeros/constants). Use grep -E for portability — bash 3.2's `=~`
  #     accepts `\,` and `\ ` in undefined-behavior territory and the
  #     backslash escapes are not needed (neither is a metachar in ERE).
  local hash_slice="${got_reason#*leaked hashes: }"
  hash_slice="${hash_slice%% (and*}"
  if printf '%s' "$hash_slice" | grep -qE '^[0-9a-f]{12}(, [0-9a-f]{12})*$'; then
    report_ok "ENG-69#1 self-leak hash list matches ^[0-9a-f]{12}(, [0-9a-f]{12})*$"
  else
    report_fail "ENG-69#1 self-leak hash list matches ^[0-9a-f]{12}(, [0-9a-f]{12})*$" \
      "hex-only sha12 list" "$hash_slice"
  fi

  # 1d. global breaker NOT tripped (set_orchestrator_paused never invoked).
  local pause_state="false"
  [[ -f "$tdir/paused" ]] && pause_state="$(cat "$tdir/paused")"
  assert_eq "ENG-69#1 self-leak does not trip global breaker" "false" "$pause_state"

  # 1e. global per-project counter file does NOT exist (the bug it locks down).
  if [[ -f "$tdir/state/.consecutive-failures" ]]; then
    report_fail "ENG-69#1 self-leak does not write global counter" \
      "no .consecutive-failures" \
      "exists with $(cat "$tdir/state/.consecutive-failures")"
  else
    report_ok "ENG-69#1 self-leak does not write global counter"
  fi

  # 1f. metric event shape preserved (sweep-self-leak-out-of-scope) so the
  #     retrospective's §1 filter does not need to relearn the event name.
  local metric_line; metric_line="$(cat "$STUB_METRICS_LOG" 2>/dev/null || true)"
  case "$metric_line" in
    *sweep-self-leak-out-of-scope*ENG-901*reviewing*self-leak*count=2*aabbccdd1122*ddeeff334455*)
      report_ok "ENG-69#1 self-leak metric event shape preserved" ;;
    *)
      report_fail "ENG-69#1 self-leak metric event shape preserved" \
        "sweep-self-leak-out-of-scope ENG-901 reviewing self-leak ... count=2 hashes=...,..." \
        "$metric_line" ;;
  esac

  rm -rf "$tdir"
  unset STUB_METRICS_LOG
}
test_halt_issue_for_self_leak_per_issue_routes_correctly

# Truncation sub-case: more than 5 hashes → reason carries 5 + "(and N more)".
test_halt_issue_for_self_leak_truncation_at_5() {
  local tdir; tdir="$(mktemp -d -t twinning-eng69-trunc.XXXXXX)"
  local stub_dir="$tdir/stubs"
  _eng69_make_stubs "$stub_dir"
  local classify_log="$tdir/classify.log"
  : > "$classify_log"
  export STUB_METRICS_LOG="$tdir/metrics.log"
  : > "$STUB_METRICS_LOG"

  (
    SCRIPT_DIR="$stub_dir"
    PROJECT_STATE_DIR="$tdir/state"
    mkdir -p "$PROJECT_STATE_DIR"
    set_orchestrator_paused() { printf '%s\n' "$1" > "$tdir/paused"; }
    is_orchestrator_paused()  { cat "$tdir/paused" 2>/dev/null || printf 'false'; }
    classify_failure() {
      printf '%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" "$5" >> "$classify_log"
    }
    halt_issue_for_self_leak ENG-901 reviewing \
      000011112222 333344445555 666677778888 9999aaaabbbb ccccddddeeee \
      ffff00001111 222233334444 >/dev/null 2>&1
  ) || true

  local reason; reason="$(awk -F'|' '{print $4}' "$classify_log")"
  case "$reason" in
    *"(and 2 more)"*)
      report_ok "ENG-69#1 truncation: reason ends with '(and 2 more)'" ;;
    *)
      report_fail "ENG-69#1 truncation: reason ends with '(and 2 more)'" \
        "(and 2 more)" "$reason" ;;
  esac
  # The 6th and 7th hashes must NOT appear in the reason (truncation).
  case "$reason" in
    *ffff00001111*|*222233334444*)
      report_fail "ENG-69#1 truncation: hashes 6+ omitted from reason" \
        "no ffff00001111 or 222233334444" "$reason" ;;
    *)
      report_ok "ENG-69#1 truncation: hashes 6+ omitted from reason" ;;
  esac
  # The first 5 hashes MUST appear (no positional swap regression).
  case "$reason" in
    *000011112222*333344445555*666677778888*9999aaaabbbb*ccccddddeeee*)
      report_ok "ENG-69#1 truncation: first 5 hashes present in order" ;;
    *)
      report_fail "ENG-69#1 truncation: first 5 hashes present in order" \
        "all 5 leading hashes in order" "$reason" ;;
  esac

  rm -rf "$tdir"
  unset STUB_METRICS_LOG
}
test_halt_issue_for_self_leak_truncation_at_5

# DRY-RUN sub-case: PIPELINE_DRY_RUN=1 must skip classify_failure (the FS
# state-file write is the irreversible side effect we suppress on dry-run
# ticks).
test_halt_issue_for_self_leak_dry_run_skips_classify() {
  local tdir; tdir="$(mktemp -d -t twinning-eng69-dryrun.XXXXXX)"
  local stub_dir="$tdir/stubs"
  _eng69_make_stubs "$stub_dir"
  local classify_log="$tdir/classify.log"
  : > "$classify_log"
  export STUB_METRICS_LOG="$tdir/metrics.log"
  : > "$STUB_METRICS_LOG"

  (
    SCRIPT_DIR="$stub_dir"
    PROJECT_STATE_DIR="$tdir/state"
    PIPELINE_DRY_RUN=1
    mkdir -p "$PROJECT_STATE_DIR"
    set_orchestrator_paused() { printf '%s\n' "$1" > "$tdir/paused"; }
    is_orchestrator_paused()  { cat "$tdir/paused" 2>/dev/null || printf 'false'; }
    classify_failure() {
      printf '%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" "$5" >> "$classify_log"
    }
    halt_issue_for_self_leak ENG-901 reviewing aabbccdd1122 >/dev/null 2>&1
  ) || true

  local n_calls; n_calls="$(wc -l < "$classify_log" | tr -d ' ')"
  assert_eq "ENG-69#1 dry-run skips classify_failure" "0" "$n_calls"
  # But the metric IS emitted (audit trail for dry-run inspection).
  case "$(cat "$STUB_METRICS_LOG" 2>/dev/null)" in
    *sweep-self-leak-out-of-scope*) report_ok "ENG-69#1 dry-run still emits metric" ;;
    *) report_fail "ENG-69#1 dry-run still emits metric" \
         "sweep-self-leak-out-of-scope" "$(cat "$STUB_METRICS_LOG" 2>/dev/null)" ;;
  esac

  rm -rf "$tdir"
  unset STUB_METRICS_LOG
}
test_halt_issue_for_self_leak_dry_run_skips_classify

# ─── ENG-69 #2: tally_leaked_in_scope_failure increments per-issue ────────

# Three sequential ticks on the same issue at FAIL_THRESHOLD=3:
#   - tick 1: counter = 1, no halt
#   - tick 2: counter = 2, no halt
#   - tick 3: counter = 3, classify_failure invoked with policy=skip-until-
#             human-acts, exit_code=28 (leaked-in-scope-threshold)
# The global counter file MUST NOT be created across all three ticks
# (that's the regression lock for the breaker-tripped-on-first-leak bug).
test_tally_leaked_in_scope_increments_per_issue_counter() {
  local tdir; tdir="$(mktemp -d -t twinning-eng69-leakcount.XXXXXX)"
  local stub_dir="$tdir/stubs"
  _eng69_make_stubs "$stub_dir"
  local classify_log="$tdir/classify.log"
  : > "$classify_log"
  export STUB_METRICS_LOG="$tdir/metrics.log"
  : > "$STUB_METRICS_LOG"

  local i
  for i in 1 2 3; do
    (
      SCRIPT_DIR="$stub_dir"
      PROJECT_STATE_DIR="$tdir/state"
      FAIL_THRESHOLD=3
      mkdir -p "$PROJECT_STATE_DIR"
      set_orchestrator_paused() { printf '%s\n' "$1" > "$tdir/paused"; }
      classify_failure() {
        printf '%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" "$5" >> "$classify_log"
      }
      tally_leaked_in_scope_failure ENG-902 implementing 1 abcdef012345 \
        >/dev/null 2>&1
    ) || true
  done

  # Per-issue counter file ends at 3.
  local pic_file="$tdir/state/ENG-902/.consecutive-failures"
  local pic_count="missing"
  [[ -f "$pic_file" ]] && pic_count="$(cat "$pic_file" | tr -d ' \n')"
  assert_eq "ENG-69#2 per-issue counter increments to 3" "3" "$pic_count"

  # Global counter NEVER written.
  if [[ -f "$tdir/state/.consecutive-failures" ]]; then
    report_fail "ENG-69#2 global counter NOT written across 3 ticks" \
      "no .consecutive-failures at PROJECT_STATE_DIR root" \
      "exists with $(cat "$tdir/state/.consecutive-failures")"
  else
    report_ok "ENG-69#2 global counter NOT written across 3 ticks"
  fi

  # classify_failure invoked exactly ONCE (on the threshold tick).
  local n_calls; n_calls="$(wc -l < "$classify_log" | tr -d ' ')"
  assert_eq "ENG-69#2 classify_failure called once at threshold" "1" "$n_calls"

  # The single call uses skip-until-human-acts policy + exit_code=28.
  local got_call; got_call="$(awk -F'|' '{printf "issue=%s stage=%s policy=%s exit=%s",$1,$2,$3,$5}' "$classify_log")"
  assert_eq "ENG-69#2 threshold halt routes per-issue (exit 28)" \
    "issue=ENG-902 stage=implementing policy=skip-until-human-acts exit=28" \
    "$got_call"

  # Global breaker NOT tripped.
  local pause_state="false"
  [[ -f "$tdir/paused" ]] && pause_state="$(cat "$tdir/paused")"
  assert_eq "ENG-69#2 leaked-in-scope threshold does not trip global breaker" \
    "false" "$pause_state"

  rm -rf "$tdir"
  unset STUB_METRICS_LOG
}
test_tally_leaked_in_scope_increments_per_issue_counter

# Counter-file corruption sub-case: write garbage, sanitizer collapses it.
# Expected behavior: pic="${pic//[^0-9]/}"; pic="${pic:-0}"; pic=$((pic+1))
# So a corrupted file resumes at 1 on the next tick.
test_tally_leaked_in_scope_recovers_from_corrupt_counter() {
  local tdir; tdir="$(mktemp -d -t twinning-eng69-corrupt.XXXXXX)"
  local stub_dir="$tdir/stubs"
  _eng69_make_stubs "$stub_dir"
  local classify_log="$tdir/classify.log"
  : > "$classify_log"
  export STUB_METRICS_LOG="$tdir/metrics.log"
  : > "$STUB_METRICS_LOG"

  # Pre-seed a corrupt counter so the helper observes the cleanup in action.
  mkdir -p "$tdir/state/ENG-903"
  printf 'garbage-not-a-number' > "$tdir/state/ENG-903/.consecutive-failures"

  (
    SCRIPT_DIR="$stub_dir"
    PROJECT_STATE_DIR="$tdir/state"
    FAIL_THRESHOLD=3
    set_orchestrator_paused() { printf '%s\n' "$1" > "$tdir/paused"; }
    classify_failure() {
      printf '%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" "$5" >> "$classify_log"
    }
    tally_leaked_in_scope_failure ENG-903 implementing 1 abcdef012345 \
      >/dev/null 2>&1
  ) || true

  # Counter resumes at 1 (sanitizer collapses non-digits, then increments).
  local pic_count; pic_count="$(cat "$tdir/state/ENG-903/.consecutive-failures" | tr -d ' \n')"
  assert_eq "ENG-69#2 corrupt counter resumes at 1 after sanitizer" "1" "$pic_count"
  rm -rf "$tdir"
  unset STUB_METRICS_LOG
}
test_tally_leaked_in_scope_recovers_from_corrupt_counter

# Brand-new issue with no prior issue_dir on disk.
test_tally_leaked_in_scope_creates_issue_dir() {
  local tdir; tdir="$(mktemp -d -t twinning-eng69-newdir.XXXXXX)"
  local stub_dir="$tdir/stubs"
  _eng69_make_stubs "$stub_dir"
  export STUB_METRICS_LOG="$tdir/metrics.log"
  : > "$STUB_METRICS_LOG"

  (
    SCRIPT_DIR="$stub_dir"
    PROJECT_STATE_DIR="$tdir/state"
    FAIL_THRESHOLD=3
    classify_failure() { :; }
    set_orchestrator_paused() { :; }
    # No mkdir -p PROJECT_STATE_DIR — let the helper create the per-issue dir.
    tally_leaked_in_scope_failure ENG-904 implementing 2 deadbeef0123,cafebabe5678 \
      >/dev/null 2>&1
  ) || true

  if [[ -f "$tdir/state/ENG-904/.consecutive-failures" ]]; then
    report_ok "ENG-69#2 helper creates per-issue dir on first call"
  else
    report_fail "ENG-69#2 helper creates per-issue dir on first call" \
      "$tdir/state/ENG-904/.consecutive-failures exists" \
      "(missing)"
  fi
  rm -rf "$tdir"
  unset STUB_METRICS_LOG
}
test_tally_leaked_in_scope_creates_issue_dir

# DRY-RUN sub-case: no FS write, no classify_failure.
test_tally_leaked_in_scope_dry_run_skips_fs_write() {
  local tdir; tdir="$(mktemp -d -t twinning-eng69-tally-dryrun.XXXXXX)"
  local stub_dir="$tdir/stubs"
  _eng69_make_stubs "$stub_dir"
  local classify_log="$tdir/classify.log"
  : > "$classify_log"
  export STUB_METRICS_LOG="$tdir/metrics.log"
  : > "$STUB_METRICS_LOG"

  (
    SCRIPT_DIR="$stub_dir"
    PROJECT_STATE_DIR="$tdir/state"
    PIPELINE_DRY_RUN=1
    FAIL_THRESHOLD=3
    classify_failure() {
      printf '%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" "$5" >> "$classify_log"
    }
    set_orchestrator_paused() { :; }
    tally_leaked_in_scope_failure ENG-905 implementing 1 abcdef012345 \
      >/dev/null 2>&1
  ) || true

  # No counter file written.
  if [[ -f "$tdir/state/ENG-905/.consecutive-failures" ]]; then
    report_fail "ENG-69#2 dry-run skips per-issue counter write" \
      "no counter file" \
      "exists"
  else
    report_ok "ENG-69#2 dry-run skips per-issue counter write"
  fi
  # classify_failure not called.
  local n_calls; n_calls="$(wc -l < "$classify_log" | tr -d ' ')"
  assert_eq "ENG-69#2 dry-run skips classify_failure" "0" "$n_calls"
  # Metric STILL emitted (audit trail).
  case "$(cat "$STUB_METRICS_LOG" 2>/dev/null)" in
    *sweep-leaked-in-scope*) report_ok "ENG-69#2 dry-run still emits metric" ;;
    *) report_fail "ENG-69#2 dry-run still emits metric" \
         "sweep-leaked-in-scope" "$(cat "$STUB_METRICS_LOG" 2>/dev/null)" ;;
  esac
  rm -rf "$tdir"
  unset STUB_METRICS_LOG
}
test_tally_leaked_in_scope_dry_run_skips_fs_write

# ─── ENG-69 #3: route_run_stage_exit splits rc=24 from per-issue lane ─────

# Three sequential rc=24 ticks across DIFFERENT issues should accumulate the
# global counter and trip the breaker at FAIL_THRESHOLD (the legitimate
# infrastructure-outage signal). rc=20 (or any other non-24 non-zero) goes
# to the per-issue counter and never touches the global counter or breaker.
test_route_run_stage_exit_rc24_increments_global() {
  local tdir; tdir="$(mktemp -d -t twinning-eng69-rc24.XXXXXX)"
  local stub_dir="$tdir/stubs"
  _eng69_make_stubs "$stub_dir"
  local classify_log="$tdir/classify.log"
  : > "$classify_log"
  export STUB_METRICS_LOG="$tdir/metrics.log"
  : > "$STUB_METRICS_LOG"

  local issue
  for issue in ENG-911 ENG-912 ENG-913; do
    (
      SCRIPT_DIR="$stub_dir"
      PROJECT_STATE_DIR="$tdir/state"
      FAIL_THRESHOLD=3
      FAIL_COUNTER="$tdir/state/.consecutive-failures"
      mkdir -p "$tdir/state"
      set_orchestrator_paused() { printf '%s\n' "$1" > "$tdir/paused"; }
      classify_failure() {
        printf '%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" "$5" >> "$classify_log"
      }
      route_run_stage_exit "$issue" implementing 24 >/dev/null 2>&1
    ) || true
  done

  # Global counter at 3.
  local fc; fc="$(cat "$tdir/state/.consecutive-failures" 2>/dev/null | tr -d ' \n')"
  assert_eq "ENG-69#3 rc=24 increments global counter to 3" "3" "$fc"

  # Breaker tripped (orchestrator.paused=true).
  local pause_state="false"
  [[ -f "$tdir/paused" ]] && pause_state="$(cat "$tdir/paused" | tr -d ' \n')"
  assert_eq "ENG-69#3 rc=24 at threshold trips global breaker" "true" "$pause_state"

  # No per-issue counter created for any of ENG-911/912/913.
  local i_no_pic=0
  for issue in ENG-911 ENG-912 ENG-913; do
    if [[ -f "$tdir/state/$issue/.consecutive-failures" ]]; then
      report_fail "ENG-69#3 rc=24 leaves per-issue counters alone ($issue)" \
        "no $tdir/state/$issue/.consecutive-failures" "exists"
    else
      i_no_pic=$((i_no_pic + 1))
    fi
  done
  assert_eq "ENG-69#3 rc=24 leaves all 3 per-issue counters absent" "3" "$i_no_pic"

  # classify_failure NOT called (rc=24 is global lane, not per-issue).
  local n_calls; n_calls="$(wc -l < "$classify_log" | tr -d ' ')"
  assert_eq "ENG-69#3 rc=24 does not invoke classify_failure" "0" "$n_calls"

  rm -rf "$tdir"
  unset STUB_METRICS_LOG
}
test_route_run_stage_exit_rc24_increments_global

# Negative half: rc=20 (dispatch-failed) routes to the per-issue counter.
test_route_run_stage_exit_rc_other_increments_per_issue() {
  local tdir; tdir="$(mktemp -d -t twinning-eng69-rcother.XXXXXX)"
  local stub_dir="$tdir/stubs"
  _eng69_make_stubs "$stub_dir"
  local classify_log="$tdir/classify.log"
  : > "$classify_log"
  export STUB_METRICS_LOG="$tdir/metrics.log"
  : > "$STUB_METRICS_LOG"

  (
    SCRIPT_DIR="$stub_dir"
    PROJECT_STATE_DIR="$tdir/state"
    FAIL_THRESHOLD=3
    FAIL_COUNTER="$tdir/state/.consecutive-failures"
    mkdir -p "$tdir/state"
    set_orchestrator_paused() { printf '%s\n' "$1" > "$tdir/paused"; }
    classify_failure() {
      printf '%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" "$5" >> "$classify_log"
    }
    route_run_stage_exit ENG-921 implementing 20 >/dev/null 2>&1
  ) || true

  # Per-issue counter created at 1.
  local pic; pic="$(cat "$tdir/state/ENG-921/.consecutive-failures" 2>/dev/null | tr -d ' \n')"
  assert_eq "ENG-69#3 rc=20 increments per-issue counter to 1" "1" "$pic"

  # Global counter NOT created.
  if [[ -f "$tdir/state/.consecutive-failures" ]]; then
    report_fail "ENG-69#3 rc=20 leaves global counter alone" \
      "no $tdir/state/.consecutive-failures" \
      "exists with $(cat "$tdir/state/.consecutive-failures")"
  else
    report_ok "ENG-69#3 rc=20 leaves global counter alone"
  fi

  # No breaker trip.
  local pause_state="false"
  [[ -f "$tdir/paused" ]] && pause_state="$(cat "$tdir/paused" | tr -d ' \n')"
  assert_eq "ENG-69#3 rc=20 does not trip global breaker" "false" "$pause_state"

  # classify_failure NOT called below threshold.
  local n_calls; n_calls="$(wc -l < "$classify_log" | tr -d ' ')"
  assert_eq "ENG-69#3 rc=20 single tick does not invoke classify_failure" "0" "$n_calls"

  rm -rf "$tdir"
  unset STUB_METRICS_LOG
}
test_route_run_stage_exit_rc_other_increments_per_issue

# Per-issue rc!=24 at threshold escalates to classify_failure with the
# original rc passed through unchanged (so the existing taxonomy entries
# — 21=scope-violation, 124=dispatch-timeout, etc. — survive into the
# retrospective's bucketing).
test_route_run_stage_exit_rc_other_escalates_at_threshold() {
  local tdir; tdir="$(mktemp -d -t twinning-eng69-escalate.XXXXXX)"
  local stub_dir="$tdir/stubs"
  _eng69_make_stubs "$stub_dir"
  local classify_log="$tdir/classify.log"
  : > "$classify_log"
  export STUB_METRICS_LOG="$tdir/metrics.log"
  : > "$STUB_METRICS_LOG"

  local i
  for i in 1 2 3; do
    (
      SCRIPT_DIR="$stub_dir"
      PROJECT_STATE_DIR="$tdir/state"
      FAIL_THRESHOLD=3
      FAIL_COUNTER="$tdir/state/.consecutive-failures"
      mkdir -p "$tdir/state"
      set_orchestrator_paused() { printf '%s\n' "$1" > "$tdir/paused"; }
      classify_failure() {
        printf '%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" "$5" >> "$classify_log"
      }
      route_run_stage_exit ENG-922 implementing 21 >/dev/null 2>&1
    ) || true
  done

  # classify_failure invoked exactly once at threshold, with rc=21 passed through.
  local n_calls; n_calls="$(wc -l < "$classify_log" | tr -d ' ')"
  assert_eq "ENG-69#3 escalation invokes classify_failure exactly once" "1" "$n_calls"

  local got_call; got_call="$(awk -F'|' '{printf "issue=%s stage=%s policy=%s exit=%s",$1,$2,$3,$5}' "$classify_log")"
  assert_eq "ENG-69#3 escalation passes rc through unchanged (21=scope-violation)" \
    "issue=ENG-922 stage=implementing policy=skip-until-human-acts exit=21" \
    "$got_call"

  rm -rf "$tdir"
  unset STUB_METRICS_LOG
}
test_route_run_stage_exit_rc_other_escalates_at_threshold

# rc=0 clears BOTH counters (clean tick on an issue resets that issue's
# per-issue counter AND the global counter).
test_route_run_stage_exit_rc0_clears_both_counters() {
  local tdir; tdir="$(mktemp -d -t twinning-eng69-rc0.XXXXXX)"
  local stub_dir="$tdir/stubs"
  _eng69_make_stubs "$stub_dir"
  export STUB_METRICS_LOG="$tdir/metrics.log"
  : > "$STUB_METRICS_LOG"

  # Pre-seed both counters.
  mkdir -p "$tdir/state/ENG-931"
  printf '2\n' > "$tdir/state/.consecutive-failures"
  printf '1\n' > "$tdir/state/ENG-931/.consecutive-failures"

  (
    SCRIPT_DIR="$stub_dir"
    PROJECT_STATE_DIR="$tdir/state"
    FAIL_THRESHOLD=3
    FAIL_COUNTER="$tdir/state/.consecutive-failures"
    set_orchestrator_paused() { :; }
    classify_failure() { :; }
    route_run_stage_exit ENG-931 implementing 0 >/dev/null 2>&1
  ) || true

  if [[ -f "$tdir/state/.consecutive-failures" ]]; then
    report_fail "ENG-69#3 rc=0 clears global counter" \
      "no .consecutive-failures" "exists with $(cat "$tdir/state/.consecutive-failures")"
  else
    report_ok "ENG-69#3 rc=0 clears global counter"
  fi
  if [[ -f "$tdir/state/ENG-931/.consecutive-failures" ]]; then
    report_fail "ENG-69#3 rc=0 clears per-issue counter" \
      "no ENG-931/.consecutive-failures" "exists"
  else
    report_ok "ENG-69#3 rc=0 clears per-issue counter"
  fi

  rm -rf "$tdir"
  unset STUB_METRICS_LOG
}
test_route_run_stage_exit_rc0_clears_both_counters

# Issue-id validation: bogus issue id must die() before any side effect.
test_halt_issue_for_self_leak_rejects_bogus_issue_id() {
  local tdir; tdir="$(mktemp -d -t twinning-eng69-bogus.XXXXXX)"
  local stub_dir="$tdir/stubs"
  _eng69_make_stubs "$stub_dir"
  export STUB_METRICS_LOG="$tdir/metrics.log"
  : > "$STUB_METRICS_LOG"
  local rc=0
  (
    SCRIPT_DIR="$stub_dir"
    PROJECT_STATE_DIR="$tdir/state"
    mkdir -p "$PROJECT_STATE_DIR"
    halt_issue_for_self_leak '../../etc/passwd' reviewing aabbccdd1122 \
      >/dev/null 2>&1
  ) || rc=$?
  if (( rc != 0 )); then
    report_ok "ENG-69#1 bogus issue id is rejected (die)"
  else
    report_fail "ENG-69#1 bogus issue id is rejected (die)" "non-zero exit" "rc=$rc"
  fi
  # Metric MUST NOT have been emitted before the validation check.
  local got_metric; got_metric="$(cat "$STUB_METRICS_LOG" 2>/dev/null || true)"
  assert_eq "ENG-69#1 bogus issue id emits no metric" "" "$got_metric"
  rm -rf "$tdir"
  unset STUB_METRICS_LOG
}
test_halt_issue_for_self_leak_rejects_bogus_issue_id

# ─── ENG-69 #4: cross-issue isolation regression lock ─────────────────────
#
# This is the load-bearing regression lock for the 2026-05-05 ENG-63 →
# ENG-64/65 incident. Pre-ENG-69, a self-leak on ENG-63's reviewing tick
# called `trip_breaker; exit 1` directly — flipping orchestrator.paused=true
# on the FIRST occurrence and freezing every other issue's poll. ENG-64
# and ENG-65 (both stage:implementing with no halt of their own) were
# silently blocked across 63 launchd ticks until manual intervention.
#
# With the new lane separation in place:
#   - halt_issue_for_self_leak halts only the affected issue via
#     classify_failure (skip-until-human-acts policy)
#   - clean ticks on OTHER issues do not see the halted issue's state
#   - the global breaker stays at false across the entire sequence
#
# Three subshell-ticks simulate three independent launchd fires:
#   Tick 1: ENG-A reviewing self-leaks → per-issue halt
#   Tick 2: ENG-B implementing clean run → no global state touched
#   Tick 3: ENG-C reviewing clean run → no global state touched
# Per-tick assertion: is_orchestrator_paused returns false. End-of-suite
# assertion: ENG-B and ENG-C have no per-issue counter files.
test_cross_issue_isolation_self_leak_does_not_block_other_issues() {
  local tdir; tdir="$(mktemp -d -t twinning-eng69-isolation.XXXXXX)"
  local stub_dir="$tdir/stubs"
  _eng69_make_stubs "$stub_dir"
  local classify_log="$tdir/classify.log"
  : > "$classify_log"
  export STUB_METRICS_LOG="$tdir/metrics.log"
  : > "$STUB_METRICS_LOG"

  # Tick 1: ENG-A self-leaks → per-issue halt; global breaker untouched.
  (
    SCRIPT_DIR="$stub_dir"
    PROJECT_STATE_DIR="$tdir/state"
    FAIL_THRESHOLD=3
    FAIL_COUNTER="$tdir/state/.consecutive-failures"
    mkdir -p "$PROJECT_STATE_DIR"
    set_orchestrator_paused() { printf '%s\n' "$1" > "$tdir/paused"; }
    is_orchestrator_paused()  { cat "$tdir/paused" 2>/dev/null || printf 'false'; }
    classify_failure() {
      printf '%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" "$5" >> "$classify_log"
    }
    halt_issue_for_self_leak ENG-941 reviewing aabbccdd1122 >/dev/null 2>&1
    # In-tick assertion: breaker NOT tripped.
    pause_state="$(is_orchestrator_paused)"
    if [[ "$pause_state" != "false" ]]; then
      printf 'TICK1 FAIL: breaker tripped after self-leak\n' >&2
      exit 1
    fi
  ) || report_fail "ENG-69#4 tick1 keeps orchestrator.paused=false" "false" "true (tripped)"

  # ENG-A should be the ONLY issue captured by classify_failure so far.
  local n_calls_after_tick1; n_calls_after_tick1="$(wc -l < "$classify_log" | tr -d ' ')"
  assert_eq "ENG-69#4 tick1 halts exactly one issue" "1" "$n_calls_after_tick1"
  local halted_issue; halted_issue="$(awk -F'|' '{print $1}' "$classify_log")"
  assert_eq "ENG-69#4 tick1 halts ENG-941 only" "ENG-941" "$halted_issue"
  # Global breaker is still false at the test-shell level too.
  local pause_state="false"
  [[ -f "$tdir/paused" ]] && pause_state="$(cat "$tdir/paused" | tr -d ' \n')"
  assert_eq "ENG-69#4 after-tick1 global breaker stays false" "false" "$pause_state"

  # Tick 2: ENG-B clean run → no global state touched, no per-issue counter
  # for ENG-B (rc=0 clears both, but ENG-B never had a counter to clear).
  (
    SCRIPT_DIR="$stub_dir"
    PROJECT_STATE_DIR="$tdir/state"
    FAIL_THRESHOLD=3
    FAIL_COUNTER="$tdir/state/.consecutive-failures"
    set_orchestrator_paused() { printf '%s\n' "$1" > "$tdir/paused"; }
    is_orchestrator_paused()  { cat "$tdir/paused" 2>/dev/null || printf 'false'; }
    classify_failure() {
      printf '%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" "$5" >> "$classify_log"
    }
    route_run_stage_exit ENG-942 implementing 0 >/dev/null 2>&1
    pause_state="$(is_orchestrator_paused)"
    if [[ "$pause_state" != "false" ]]; then
      printf 'TICK2 FAIL: breaker tripped during clean ENG-B tick\n' >&2
      exit 1
    fi
  ) || report_fail "ENG-69#4 tick2 keeps orchestrator.paused=false on clean ENG-B run" "false" "true (tripped)"

  # Tick 3: ENG-C clean run → same as tick2.
  (
    SCRIPT_DIR="$stub_dir"
    PROJECT_STATE_DIR="$tdir/state"
    FAIL_THRESHOLD=3
    FAIL_COUNTER="$tdir/state/.consecutive-failures"
    set_orchestrator_paused() { printf '%s\n' "$1" > "$tdir/paused"; }
    is_orchestrator_paused()  { cat "$tdir/paused" 2>/dev/null || printf 'false'; }
    classify_failure() {
      printf '%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" "$5" >> "$classify_log"
    }
    route_run_stage_exit ENG-943 reviewing 0 >/dev/null 2>&1
    pause_state="$(is_orchestrator_paused)"
    if [[ "$pause_state" != "false" ]]; then
      printf 'TICK3 FAIL: breaker tripped during clean ENG-C tick\n' >&2
      exit 1
    fi
  ) || report_fail "ENG-69#4 tick3 keeps orchestrator.paused=false on clean ENG-C run" "false" "true (tripped)"

  # End-of-sequence: ENG-B and ENG-C have no per-issue counter files
  # (clean runs on issues that never accumulated state should not write
  # any counter).
  if [[ -f "$tdir/state/ENG-942/.consecutive-failures" ]]; then
    report_fail "ENG-69#4 tick2 leaves ENG-B with no per-issue counter" \
      "no $tdir/state/ENG-942/.consecutive-failures" "exists"
  else
    report_ok "ENG-69#4 tick2 leaves ENG-B with no per-issue counter"
  fi
  if [[ -f "$tdir/state/ENG-943/.consecutive-failures" ]]; then
    report_fail "ENG-69#4 tick3 leaves ENG-C with no per-issue counter" \
      "no $tdir/state/ENG-943/.consecutive-failures" "exists"
  else
    report_ok "ENG-69#4 tick3 leaves ENG-C with no per-issue counter"
  fi

  # Global counter file never created across all three ticks (the regression
  # lock — pre-ENG-69 the self-leak on tick1 would have written this).
  if [[ -f "$tdir/state/.consecutive-failures" ]]; then
    report_fail "ENG-69#4 global counter never written across all 3 ticks" \
      "no $tdir/state/.consecutive-failures" \
      "exists with $(cat "$tdir/state/.consecutive-failures")"
  else
    report_ok "ENG-69#4 global counter never written across all 3 ticks"
  fi

  # Final classify_failure call count: still exactly 1 (the tick1 self-leak).
  # Ticks 2 and 3 are clean runs and must NOT emit any classify_failure.
  local final_n_calls; final_n_calls="$(wc -l < "$classify_log" | tr -d ' ')"
  assert_eq "ENG-69#4 only the self-leak tick invokes classify_failure" \
    "1" "$final_n_calls"

  rm -rf "$tdir"
  unset STUB_METRICS_LOG
}
test_cross_issue_isolation_self_leak_does_not_block_other_issues

# ─── ENG-69 QA adversarial coverage (post-review) ─────────────────────────
#
# Plug three gaps surfaced in the review-stage minor findings:
#   - rc=24 below threshold (symmetric to the leaked-in-scope below/at-threshold
#     pair). Locks the negative case for the breaker — accidentally tripping
#     on FIRST occurrence is exactly the ENG-69 incident shape, just on a
#     different lane.
#   - tally_leaked_in_scope_failure with bogus issue id. Symmetric to the
#     halt_issue_for_self_leak test; both helpers share the same regex
#     guard, but only one was tested.
#   - halt_issue_for_self_leak with EXACTLY 5 hashes. Boundary between the
#     "all hashes shown, no suffix" case and the "(and N more)" case. The
#     existing tests cover 2 and 7 hashes, leaving the boundary unasserted.

# Below-threshold rc=24: 1 and 2 ticks must NOT trip the breaker, even
# though the global counter increments.
test_route_run_stage_exit_rc24_below_threshold() {
  local tdir; tdir="$(mktemp -d -t twinning-eng69-rc24below.XXXXXX)"
  local stub_dir="$tdir/stubs"
  _eng69_make_stubs "$stub_dir"
  local classify_log="$tdir/classify.log"
  : > "$classify_log"
  export STUB_METRICS_LOG="$tdir/metrics.log"
  : > "$STUB_METRICS_LOG"

  local i
  for i in 1 2; do
    (
      SCRIPT_DIR="$stub_dir"
      PROJECT_STATE_DIR="$tdir/state"
      FAIL_THRESHOLD=3
      FAIL_COUNTER="$tdir/state/.consecutive-failures"
      mkdir -p "$tdir/state"
      set_orchestrator_paused() { printf '%s\n' "$1" > "$tdir/paused"; }
      classify_failure() {
        printf '%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" "$5" >> "$classify_log"
      }
      route_run_stage_exit ENG-951 implementing 24 >/dev/null 2>&1
    ) || true
  done

  local fc; fc="$(cat "$tdir/state/.consecutive-failures" 2>/dev/null | tr -d ' \n')"
  assert_eq "ENG-69 QA-adv rc=24 below threshold: global counter increments to 2" "2" "$fc"

  local pause_state="false"
  [[ -f "$tdir/paused" ]] && pause_state="$(cat "$tdir/paused" | tr -d ' \n')"
  assert_eq "ENG-69 QA-adv rc=24 below threshold does NOT trip breaker" "false" "$pause_state"

  local n_calls; n_calls="$(wc -l < "$classify_log" | tr -d ' ')"
  assert_eq "ENG-69 QA-adv rc=24 below threshold does not invoke classify_failure" "0" "$n_calls"

  rm -rf "$tdir"
  unset STUB_METRICS_LOG
}
test_route_run_stage_exit_rc24_below_threshold

# Bogus-id regex guard: tally_leaked_in_scope_failure rejects '../../etc/passwd'
# before any side effect (metric emit, counter write, or classify_failure call).
# Symmetric to test_halt_issue_for_self_leak_rejects_bogus_issue_id.
test_tally_leaked_in_scope_failure_rejects_bogus_issue_id() {
  local tdir; tdir="$(mktemp -d -t twinning-eng69-tallybogus.XXXXXX)"
  local stub_dir="$tdir/stubs"
  _eng69_make_stubs "$stub_dir"
  export STUB_METRICS_LOG="$tdir/metrics.log"
  : > "$STUB_METRICS_LOG"
  local rc=0
  (
    SCRIPT_DIR="$stub_dir"
    PROJECT_STATE_DIR="$tdir/state"
    FAIL_COUNTER="$tdir/state/.consecutive-failures"
    mkdir -p "$PROJECT_STATE_DIR"
    classify_failure() { :; }
    tally_leaked_in_scope_failure '../../etc/passwd' implementing 1 abcdef012345 \
      >/dev/null 2>&1
  ) || rc=$?
  if (( rc != 0 )); then
    report_ok "ENG-69 QA-adv tally bogus issue id is rejected (die)"
  else
    report_fail "ENG-69 QA-adv tally bogus issue id is rejected (die)" "non-zero exit" "rc=$rc"
  fi
  # Metric MUST NOT have been emitted before the validation check.
  local got_metric; got_metric="$(cat "$STUB_METRICS_LOG" 2>/dev/null || true)"
  assert_eq "ENG-69 QA-adv tally bogus issue id emits no metric" "" "$got_metric"
  # No counter written under any path containing 'passwd'.
  if find "$tdir/state" -name '.consecutive-failures' 2>/dev/null | grep -q .; then
    report_fail "ENG-69 QA-adv tally bogus issue id writes no counter file" \
      "no .consecutive-failures under state/" "found"
  else
    report_ok "ENG-69 QA-adv tally bogus issue id writes no counter file"
  fi
  rm -rf "$tdir"
  unset STUB_METRICS_LOG
}
test_tally_leaked_in_scope_failure_rejects_bogus_issue_id

# Boundary at exactly 5 hashes: all 5 appear in order, NO "(and N more)" suffix.
# The truncation logic uses `(( h_count >= 5 )) && break`; off-by-one would
# either truncate to 4 (suffix "(and 1 more)" appears) or leak a 6th hash.
test_halt_issue_for_self_leak_at_exactly_5_hashes() {
  local tdir; tdir="$(mktemp -d -t twinning-eng69-exactly5.XXXXXX)"
  local stub_dir="$tdir/stubs"
  _eng69_make_stubs "$stub_dir"
  local classify_log="$tdir/classify.log"
  : > "$classify_log"
  export STUB_METRICS_LOG="$tdir/metrics.log"
  : > "$STUB_METRICS_LOG"

  (
    SCRIPT_DIR="$stub_dir"
    PROJECT_STATE_DIR="$tdir/state"
    mkdir -p "$PROJECT_STATE_DIR"
    set_orchestrator_paused() { :; }
    is_orchestrator_paused()  { printf 'false'; }
    classify_failure() {
      printf '%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" "$5" >> "$classify_log"
    }
    halt_issue_for_self_leak ENG-961 reviewing \
      000011112222 333344445555 666677778888 9999aaaabbbb ccccddddeeee \
      >/dev/null 2>&1
  ) || true

  local reason; reason="$(awk -F'|' '{print $4}' "$classify_log")"
  # No suffix at boundary.
  case "$reason" in
    *"(and "*"more)"*)
      report_fail "ENG-69 QA-adv exactly-5: no '(and N more)' suffix at boundary" \
        "no (and N more)" "$reason" ;;
    *)
      report_ok "ENG-69 QA-adv exactly-5: no '(and N more)' suffix at boundary" ;;
  esac
  # All 5 hashes present in order.
  case "$reason" in
    *000011112222*333344445555*666677778888*9999aaaabbbb*ccccddddeeee*)
      report_ok "ENG-69 QA-adv exactly-5: all 5 hashes present in order" ;;
    *)
      report_fail "ENG-69 QA-adv exactly-5: all 5 hashes present in order" \
        "all 5 hashes in order" "$reason" ;;
  esac
  # Reason field's hash slice matches the canonical regex.
  local hash_slice="${reason#*leaked hashes: }"
  if printf '%s' "$hash_slice" | grep -qE '^[0-9a-f]{12}(, [0-9a-f]{12}){4}$'; then
    report_ok "ENG-69 QA-adv exactly-5: hash slice matches ^[0-9a-f]{12}(, [0-9a-f]{12}){4}\$"
  else
    report_fail "ENG-69 QA-adv exactly-5: hash slice matches ^[0-9a-f]{12}(, [0-9a-f]{12}){4}\$" \
      "5 hex-only sha12 entries" "$hash_slice"
  fi

  rm -rf "$tdir"
  unset STUB_METRICS_LOG
}
test_halt_issue_for_self_leak_at_exactly_5_hashes

# ─── ENG-95: profile-driven stage_output_paths ──────────────────────────
# Coverage matrix: parser format handling (em-dash split, multi-backtick
# prefix, no-em-dash), placeholder substitution (<slug> resolution + other
# placeholder rejection), path-syntax filters (D-006: absolute, traversal,
# embedded traversal), slug-shape validation (D-002: regex metachar fail-
# closed), always-include union behavior (minimal profile, dedup), override
# precedence (empty array falls through), and diagnostic-log emission
# (D-005). Each case is self-contained: tempdir + fixture profile + post-
# source override of HARNESS_ROOT/PROJECT_SLUG + restore (mirrors the
# qa_no_state_bleed_between_invocations pattern at line ~300).

_eng95_save_hr=""
_eng95_save_ps=""
_eng95_save_cfg=""
_eng95_save_env() {
  _eng95_save_hr="${HARNESS_ROOT-}"
  _eng95_save_ps="${PROJECT_SLUG-}"
  _eng95_save_cfg="${CONFIG-}"
}
_eng95_restore_env() {
  HARNESS_ROOT="$_eng95_save_hr"
  PROJECT_SLUG="$_eng95_save_ps"
  CONFIG="$_eng95_save_cfg"
  export HARNESS_ROOT PROJECT_SLUG CONFIG
}

# Build a fixture profile at $tdir/learned-rules/<slug>/project-profile.md
# whose `## File layout` body is supplied via $2 (multi-line string of
# bullets). $3 is the slug; defaults to "test-slug".
_eng95_write_profile() {
  local tdir="$1" body="$2" slug="${3:-test-slug}"
  local pf="$tdir/learned-rules/$slug/project-profile.md"
  mkdir -p "$(dirname "$pf")"
  {
    printf '%s\n' '---'
    printf 'slug: %s\n' "$slug"
    printf '%s\n' 'schema_version: 1'
    printf '%s\n' '---'
    printf '%s\n' ''
    printf '%s\n' '# Project profile'
    printf '%s\n' ''
    printf '%s\n' '## File layout'
    printf '%s\n' ''
    printf '%s\n' "$body"
    printf '%s\n' ''
    printf '%s\n' '## Language idioms'
    printf '%s\n' ''
    printf '%s\n' 'text'
  } > "$pf"
  printf '%s' "$pf"
}

# parse_em_dash_split: only backticked tokens BEFORE the em-dash are
# extracted; description-side backticks ignored.
_eng95_save_env
_tdir="$(mktemp -d -t twinning-eng95.XXXXXX)"
_pf="$(_eng95_write_profile "$_tdir" '- `src/` — note about `tests/`')"
_got="$(_parse_profile_file_layout "$_pf" test-slug | LC_ALL=C sort | paste -sd, -)"
assert_eq 'eng95_parse_em_dash_split' 'src/' "$_got"
rm -rf "$_tdir"
_eng95_restore_env

# parse_multi_backtick_prefix: multiple backticked tokens before the em-
# dash are all extracted (mirrors harness profile's `docs/brainstorms/` +
# `docs/plans/` bullet).
_eng95_save_env
_tdir="$(mktemp -d -t twinning-eng95.XXXXXX)"
_pf="$(_eng95_write_profile "$_tdir" '- `docs/brainstorms/` and `docs/plans/` — caption')"
_got="$(_parse_profile_file_layout "$_pf" test-slug | LC_ALL=C sort | paste -sd, -)"
assert_eq 'eng95_parse_multi_backtick_prefix' 'docs/brainstorms/,docs/plans/' "$_got"
rm -rf "$_tdir"
_eng95_restore_env

# parse_slug_substitution: `<slug>` placeholder in a bullet path resolves
# to the supplied slug.
_eng95_save_env
_tdir="$(mktemp -d -t twinning-eng95.XXXXXX)"
_pf="$(_eng95_write_profile "$_tdir" '- `learned-rules/<slug>/` — per-slug rules' foo)"
_got="$(_parse_profile_file_layout "$_pf" foo | LC_ALL=C sort | paste -sd, -)"
assert_eq 'eng95_parse_slug_substitution' 'learned-rules/foo/' "$_got"
rm -rf "$_tdir"
_eng95_restore_env

# parse_other_placeholder_skipped: D-006 drops any token still containing
# `<...>` after `<slug>` substitution (defensive against future placeholders
# like `<stage>` that aren't substituted).
_eng95_save_env
_tdir="$(mktemp -d -t twinning-eng95.XXXXXX)"
_pf="$(_eng95_write_profile "$_tdir" '- `<stage>/output/` — placeholder')"
_got="$(_parse_profile_file_layout "$_pf" test-slug | LC_ALL=C sort | paste -sd, -)"
assert_eq 'eng95_parse_other_placeholder_skipped' '' "$_got"
rm -rf "$_tdir"
_eng95_restore_env

# always_include_present_when_profile_minimal: stage_output_paths returns
# the union of profile-derived list and always-include catalog. A profile
# with one bullet still yields the full catalog plus that bullet.
_eng95_save_env
_tdir="$(mktemp -d -t twinning-eng95.XXXXXX)"
_pf="$(_eng95_write_profile "$_tdir" '- `src/` — sole source')"
HARNESS_ROOT="$_tdir"
PROJECT_SLUG="test-slug"
export HARNESS_ROOT PROJECT_SLUG
unset CONFIG
_got="$(stage_output_paths implementing 2>/dev/null | LC_ALL=C sort | paste -sd, -)"
# Expected: profile `src/` ∪ always-include catalog (18 entries dedup'd; src/
# is new, no overlap with catalog).
_expected='Cargo.lock,Cargo.toml,Gemfile,Gemfile.lock,Pipfile,Pipfile.lock,bun.lock,bun.lockb,docs/,go.mod,go.sum,package-lock.json,package.json,pnpm-lock.yaml,poetry.lock,pyproject.toml,src/,uv.lock,yarn.lock'
assert_eq 'eng95_always_include_present_when_profile_minimal' "$_expected" "$_got"
rm -rf "$_tdir"
_eng95_restore_env

# always_include_dedup_with_profile: a profile that lists `docs/` (also in
# the always-include catalog) MUST yield exactly one `docs/` entry in
# stage_output_paths' output (sort -u boundary).
_eng95_save_env
_tdir="$(mktemp -d -t twinning-eng95.XXXXXX)"
_pf="$(_eng95_write_profile "$_tdir" '- `docs/` — duplicates catalog')"
HARNESS_ROOT="$_tdir"
PROJECT_SLUG="test-slug"
export HARNESS_ROOT PROJECT_SLUG
unset CONFIG
_got="$(stage_output_paths implementing 2>/dev/null | grep -c '^docs/$' | tr -d ' ')"
assert_eq 'eng95_always_include_dedup_with_profile' '1' "$_got"
rm -rf "$_tdir"
_eng95_restore_env

# override_empty_falls_through_to_profile: an empty-array
# `config.json::scope.allowlist.implementing` (ENG-51's fallback case)
# routes to the profile-derived path (not the legacy fallback).
_eng95_save_env
_tdir="$(mktemp -d -t twinning-eng95.XXXXXX)"
_pf="$(_eng95_write_profile "$_tdir" '- `app/` — only entry')"
_cfg="$_tdir/config.json"
printf '%s\n' '{"scope":{"allowlist":{"implementing":[]}}}' > "$_cfg"
HARNESS_ROOT="$_tdir"
PROJECT_SLUG="test-slug"
CONFIG="$_cfg"
export HARNESS_ROOT PROJECT_SLUG CONFIG
_got="$(stage_output_paths implementing 2>/dev/null | LC_ALL=C sort | paste -sd, -)"
case "$_got" in
  *app/*) report_ok 'eng95_override_empty_falls_through_to_profile' ;;
  *)      report_fail 'eng95_override_empty_falls_through_to_profile' \
            "output contains profile-derived app/" "$_got" ;;
esac
rm -rf "$_tdir"
_eng95_restore_env

# parse_absolute_path_rejected: D-006 drops tokens beginning with `/`.
_eng95_save_env
_tdir="$(mktemp -d -t twinning-eng95.XXXXXX)"
_pf="$(_eng95_write_profile "$_tdir" '- `/etc/passwd` — adversary')"
_got="$(_parse_profile_file_layout "$_pf" test-slug | LC_ALL=C sort | paste -sd, -)"
assert_eq 'eng95_parse_absolute_path_rejected' '' "$_got"
rm -rf "$_tdir"
_eng95_restore_env

# parse_traversal_prefix_rejected: D-006 drops tokens beginning with `../`.
_eng95_save_env
_tdir="$(mktemp -d -t twinning-eng95.XXXXXX)"
_pf="$(_eng95_write_profile "$_tdir" '- `../../etc/shadow` — adversary')"
_got="$(_parse_profile_file_layout "$_pf" test-slug | LC_ALL=C sort | paste -sd, -)"
assert_eq 'eng95_parse_traversal_prefix_rejected' '' "$_got"
rm -rf "$_tdir"
_eng95_restore_env

# parse_embedded_traversal_rejected: D-006 drops tokens with `/../`
# embedded.
_eng95_save_env
_tdir="$(mktemp -d -t twinning-eng95.XXXXXX)"
_pf="$(_eng95_write_profile "$_tdir" '- `foo/../../bar` — adversary')"
_got="$(_parse_profile_file_layout "$_pf" test-slug | LC_ALL=C sort | paste -sd, -)"
assert_eq 'eng95_parse_embedded_traversal_rejected' '' "$_got"
rm -rf "$_tdir"
_eng95_restore_env

# parse_unbalanced_backticks_safe: a bullet with an opened-but-not-closed
# backtick after the first valid token extracts ONLY the closed pair; the
# inner match loop exits cleanly, no partial-token leak, no abort.
_eng95_save_env
_tdir="$(mktemp -d -t twinning-eng95.XXXXXX)"
_pf="$(_eng95_write_profile "$_tdir" '- `src/` `docs/ — caption')"
_got="$(_parse_profile_file_layout "$_pf" test-slug | LC_ALL=C sort | paste -sd, -)"
assert_eq 'eng95_parse_unbalanced_backticks_safe' 'src/' "$_got"
rm -rf "$_tdir"
_eng95_restore_env

# parse_slug_regex_metachar_safe: a slug containing awk regex metachars
# (e.g. `.`) fails the D-002 validation regex and substitutes to the empty
# string; `learned-rules/<slug>/` collapses to `learned-rules//` (harmless;
# matches no real path). Critical assertion: no awk-replacement-string
# injection (no exotic token, no crash).
_eng95_save_env
_tdir="$(mktemp -d -t twinning-eng95.XXXXXX)"
_pf="$(_eng95_write_profile "$_tdir" '- `learned-rules/<slug>/` — metachar slug')"
_got="$(_parse_profile_file_layout "$_pf" 'a.b' | LC_ALL=C sort | paste -sd, -)"
assert_eq 'eng95_parse_slug_regex_metachar_safe' 'learned-rules//' "$_got"
rm -rf "$_tdir"
_eng95_restore_env

# parse_slug_amp_metachar_safe: a benign slug (`foo`) yields the expected
# substitution with no awk-replacement-string injection (smoke for the
# gsub-escape pre-pass on `&`/`\` — actual `&` would fail validation, so
# this verifies the happy-path side doesn't double-escape).
_eng95_save_env
_tdir="$(mktemp -d -t twinning-eng95.XXXXXX)"
_pf="$(_eng95_write_profile "$_tdir" '- `learned-rules/<slug>/` — benign slug')"
_got="$(_parse_profile_file_layout "$_pf" 'foo' | LC_ALL=C sort | paste -sd, -)"
assert_eq 'eng95_parse_slug_amp_metachar_safe' 'learned-rules/foo/' "$_got"
rm -rf "$_tdir"
_eng95_restore_env

# parse_no_em_dash_handled: a bullet with no em-dash (single backticked
# token, no description) is parsed whole-line; the token is still extracted.
_eng95_save_env
_tdir="$(mktemp -d -t twinning-eng95.XXXXXX)"
_pf="$(_eng95_write_profile "$_tdir" '- `src/`')"
_got="$(_parse_profile_file_layout "$_pf" test-slug | LC_ALL=C sort | paste -sd, -)"
assert_eq 'eng95_parse_no_em_dash_handled' 'src/' "$_got"
rm -rf "$_tdir"
_eng95_restore_env

# parse_log_fires_on_empty_profile_layout: stage_output_paths emits the
# D-005 diagnostic exactly once on stderr when the profile-derived list is
# empty (missing `## File layout` section); always-include set still emits
# on stdout.
_eng95_save_env
_tdir="$(mktemp -d -t twinning-eng95.XXXXXX)"
# Profile WITHOUT `## File layout` section.
mkdir -p "$_tdir/learned-rules/test-slug"
cat > "$_tdir/learned-rules/test-slug/project-profile.md" <<'MD'
---
slug: test-slug
schema_version: 1
---

# Project profile

## Stack

text

## Language idioms

text
MD
HARNESS_ROOT="$_tdir"
PROJECT_SLUG="test-slug"
export HARNESS_ROOT PROJECT_SLUG
unset CONFIG
_stderr_file="$_tdir/stderr"
_stdout="$(stage_output_paths implementing 2>"$_stderr_file")"
_stderr_grep_count="$(grep -c 'profile-derived list empty' "$_stderr_file" 2>/dev/null | tr -d ' ' || true)"
_stderr_grep_count="${_stderr_grep_count:-0}"
assert_eq 'eng95_parse_log_fires_on_empty_profile_layout' '1' "$_stderr_grep_count"
# Always-include still emits on stdout (catalog has 18 entries).
_stdout_lines="$(printf '%s\n' "$_stdout" | grep -c '.' 2>/dev/null | tr -d ' ' || true)"
_stdout_lines="${_stdout_lines:-0}"
case "$_stdout_lines" in
  18) report_ok 'eng95_parse_log_fires_always_include_still_emits' ;;
  *)  report_fail 'eng95_parse_log_fires_always_include_still_emits' \
        '18 lines' "$_stdout_lines lines: $_stdout" ;;
esac
rm -rf "$_tdir"
_eng95_restore_env

# parse_log_does_not_fire_on_valid_profile: a profile with a populated
# `## File layout` section silences the D-005 diagnostic.
_eng95_save_env
_tdir="$(mktemp -d -t twinning-eng95.XXXXXX)"
_pf="$(_eng95_write_profile "$_tdir" '- `crates/` — Rust workspace')"
HARNESS_ROOT="$_tdir"
PROJECT_SLUG="test-slug"
export HARNESS_ROOT PROJECT_SLUG
unset CONFIG
_stderr_file="$_tdir/stderr"
stage_output_paths implementing >/dev/null 2>"$_stderr_file"
_stderr_grep_count="$(grep -c 'profile-derived list empty' "$_stderr_file" 2>/dev/null | tr -d ' ' || true)"
_stderr_grep_count="${_stderr_grep_count:-0}"
assert_eq 'eng95_parse_log_does_not_fire_on_valid_profile' '0' "$_stderr_grep_count"
rm -rf "$_tdir"
_eng95_restore_env

# ─── ENG-95 QA-adversarial coverage ──────────────────────────────────────
# These cases were NOT in the plan's Failure Mode → Test Map. They probe
# the boundary between the awk parser's regex anchors and operator-authored
# profile shapes (case-sensitivity, sub-headings, CRLF, etc) plus
# stage_output_paths' equivalence across implementing/ui/qa.

# QA-adv-1: section header case-sensitivity. `## File Layout` (capital L)
# is NOT the canonical heading; parser MUST yield nothing and the
# stage_output_paths diagnostic MUST fire.
_eng95_save_env
_tdir="$(mktemp -d -t twinning-eng95-qa.XXXXXX)"
mkdir -p "$_tdir/learned-rules/test-slug"
cat > "$_tdir/learned-rules/test-slug/project-profile.md" <<'MD'
---
slug: test-slug
---

## File Layout

- `wrongcase/` — header has capital L
MD
HARNESS_ROOT="$_tdir"
PROJECT_SLUG="test-slug"
export HARNESS_ROOT PROJECT_SLUG
unset CONFIG
_parser_got="$(_parse_profile_file_layout "$_tdir/learned-rules/test-slug/project-profile.md" test-slug | paste -sd, -)"
assert_eq 'eng95_qa_adv_section_header_case_sensitive_parser' '' "$_parser_got"
_stderr_file="$_tdir/stderr"
stage_output_paths implementing >/dev/null 2>"$_stderr_file"
_stderr_grep_count="$(grep -c 'profile-derived list empty' "$_stderr_file" 2>/dev/null | tr -d ' ' || true)"
_stderr_grep_count="${_stderr_grep_count:-0}"
assert_eq 'eng95_qa_adv_section_header_case_sensitive_log_fires' '1' "$_stderr_grep_count"
rm -rf "$_tdir"
_eng95_restore_env

# QA-adv-2: section header with trailing whitespace (tab + spaces). The
# `[[:space:]]*$` anchor must accept this — operators occasionally trail
# whitespace and the parser must NOT silently drop the section.
_eng95_save_env
_tdir="$(mktemp -d -t twinning-eng95-qa.XXXXXX)"
mkdir -p "$_tdir/learned-rules/test-slug"
printf -- '---\nslug: test-slug\n---\n\n## File layout\t   \n\n- `src/` — trailing whitespace ok\n' \
  > "$_tdir/learned-rules/test-slug/project-profile.md"
_parser_got="$(_parse_profile_file_layout "$_tdir/learned-rules/test-slug/project-profile.md" test-slug | paste -sd, -)"
assert_eq 'eng95_qa_adv_section_header_trailing_whitespace' 'src/' "$_parser_got"
rm -rf "$_tdir"
_eng95_restore_env

# QA-adv-3: sub-headings (`### foo`) inside `## File layout` do NOT
# terminate the section — only `^## ` matches the exit guard. Current
# behavior: bullets in subsections leak into the allowlist. Pin this
# behavior so a future regex tweak doesn't accidentally narrow it.
_eng95_save_env
_tdir="$(mktemp -d -t twinning-eng95-qa.XXXXXX)"
mkdir -p "$_tdir/learned-rules/test-slug"
cat > "$_tdir/learned-rules/test-slug/project-profile.md" <<'MD'
---
slug: test-slug
---

## File layout

- `top/` — top-level bullet

### Subsection

- `sub/` — bullets in subsections also leak (pinned)

## Stack

- `outside/` — outside section must NOT leak
MD
_parser_got="$(_parse_profile_file_layout "$_tdir/learned-rules/test-slug/project-profile.md" test-slug | LC_ALL=C sort | paste -sd, -)"
assert_eq 'eng95_qa_adv_subsection_bullets_pinned' 'sub/,top/' "$_parser_got"
rm -rf "$_tdir"
_eng95_restore_env

# QA-adv-4: profile with `## File layout` section present but no bullets
# at all (operator stubbed the header but hasn't filled it in). Parser
# emits nothing; stage_output_paths fires the empty-list diagnostic.
_eng95_save_env
_tdir="$(mktemp -d -t twinning-eng95-qa.XXXXXX)"
mkdir -p "$_tdir/learned-rules/test-slug"
cat > "$_tdir/learned-rules/test-slug/project-profile.md" <<'MD'
---
slug: test-slug
---

## File layout

(empty — operator hasn't filled in directory list)

## Stack

text
MD
HARNESS_ROOT="$_tdir"
PROJECT_SLUG="test-slug"
export HARNESS_ROOT PROJECT_SLUG
unset CONFIG
_parser_got="$(_parse_profile_file_layout "$_tdir/learned-rules/test-slug/project-profile.md" test-slug | paste -sd, -)"
assert_eq 'eng95_qa_adv_section_present_no_bullets_parser' '' "$_parser_got"
_stderr_file="$_tdir/stderr"
stage_output_paths implementing >/dev/null 2>"$_stderr_file"
_stderr_grep_count="$(grep -c 'profile-derived list empty' "$_stderr_file" 2>/dev/null | tr -d ' ' || true)"
_stderr_grep_count="${_stderr_grep_count:-0}"
assert_eq 'eng95_qa_adv_section_present_no_bullets_log_fires' '1' "$_stderr_grep_count"
rm -rf "$_tdir"
_eng95_restore_env

# QA-adv-5: CRLF line endings (Windows-edited profile). Section header
# match, bullet match, and em-dash split must all survive `\r` line
# terminators on macOS bsdawk.
_eng95_save_env
_tdir="$(mktemp -d -t twinning-eng95-qa.XXXXXX)"
mkdir -p "$_tdir/learned-rules/test-slug"
printf -- '---\r\nslug: test-slug\r\n---\r\n\r\n## File layout\r\n\r\n- `src/` — CRLF profile\r\n' \
  > "$_tdir/learned-rules/test-slug/project-profile.md"
_parser_got="$(_parse_profile_file_layout "$_tdir/learned-rules/test-slug/project-profile.md" test-slug \
  | tr -d '\r' | LC_ALL=C sort | paste -sd, -)"
# Accept either bare 'src/' (CR stripped pre-emit by awk) or 'src/' after
# the tr -d strip. The contract is: at least 'src/' is extracted.
case "$_parser_got" in
  *src/*) report_ok 'eng95_qa_adv_crlf_line_endings' ;;
  *)      report_fail 'eng95_qa_adv_crlf_line_endings' \
            "contains 'src/'" "$_parser_got" ;;
esac
rm -rf "$_tdir"
_eng95_restore_env

# QA-adv-6: stage_output_paths `ui` and `qa` arms behave identically to
# `implementing`. ENG-95 collapses all three under one case-arm; pin
# this equivalence so a future split (e.g. ui-only `static/`) doesn't
# silently regress.
_eng95_save_env
_tdir="$(mktemp -d -t twinning-eng95-qa.XXXXXX)"
_pf="$(_eng95_write_profile "$_tdir" '- `crates/` — Rust workspace')"
HARNESS_ROOT="$_tdir"
PROJECT_SLUG="test-slug"
export HARNESS_ROOT PROJECT_SLUG
unset CONFIG
_impl_out="$(stage_output_paths implementing 2>/dev/null | LC_ALL=C sort | paste -sd, -)"
_ui_out="$(stage_output_paths ui 2>/dev/null | LC_ALL=C sort | paste -sd, -)"
_qa_out="$(stage_output_paths qa 2>/dev/null | LC_ALL=C sort | paste -sd, -)"
assert_eq 'eng95_qa_adv_ui_matches_implementing' "$_impl_out" "$_ui_out"
assert_eq 'eng95_qa_adv_qa_matches_implementing'  "$_impl_out" "$_qa_out"
rm -rf "$_tdir"
_eng95_restore_env

# QA-adv-7: `HARNESS_ROOT` unset entirely (test-source path before
# common.sh's line-9 derivation). profile_path becomes
# `/learned-rules/<slug>/project-profile.md` — almost certainly absent
# in real environments. [[ -f ]] returns false → parser returns rc 0
# with empty stdout → catalog-only emission + diagnostic fires. No
# crash, no leak.
_eng95_save_env
unset HARNESS_ROOT
PROJECT_SLUG="test-slug"
export PROJECT_SLUG
unset CONFIG
_stderr_file="$(mktemp -t twinning-eng95-qa.XXXXXX)"
_stdout="$(stage_output_paths implementing 2>"$_stderr_file")"
_stderr_grep_count="$(grep -c 'profile-derived list empty' "$_stderr_file" 2>/dev/null | tr -d ' ' || true)"
_stderr_grep_count="${_stderr_grep_count:-0}"
assert_eq 'eng95_qa_adv_harness_root_unset_log_fires' '1' "$_stderr_grep_count"
_stdout_lines="$(printf '%s\n' "$_stdout" | grep -c '.' 2>/dev/null | tr -d ' ' || true)"
_stdout_lines="${_stdout_lines:-0}"
# Catalog has 18 entries; emit count must equal exactly 18.
case "$_stdout_lines" in
  18) report_ok 'eng95_qa_adv_harness_root_unset_catalog_emits' ;;
  *)  report_fail 'eng95_qa_adv_harness_root_unset_catalog_emits' \
        '18 lines' "$_stdout_lines lines" ;;
esac
rm -f "$_stderr_file"
_eng95_restore_env

# QA-adv-8: PROJECT_SLUG unset entirely. Same fail-soft contract as
# HARNESS_ROOT-unset: profile_path becomes
# `$HARNESS_ROOT/learned-rules//project-profile.md` (double slash) →
# [[ -f ]] returns false → catalog-only emission.
_eng95_save_env
_tdir="$(mktemp -d -t twinning-eng95-qa.XXXXXX)"
HARNESS_ROOT="$_tdir"
unset PROJECT_SLUG
export HARNESS_ROOT
unset CONFIG
_stderr_file="$(mktemp -t twinning-eng95-qa.XXXXXX)"
_stdout="$(stage_output_paths implementing 2>"$_stderr_file")"
_stdout_lines="$(printf '%s\n' "$_stdout" | grep -c '.' 2>/dev/null | tr -d ' ' || true)"
_stdout_lines="${_stdout_lines:-0}"
case "$_stdout_lines" in
  18) report_ok 'eng95_qa_adv_project_slug_unset_catalog_emits' ;;
  *)  report_fail 'eng95_qa_adv_project_slug_unset_catalog_emits' \
        '18 lines' "$_stdout_lines lines: $_stdout" ;;
esac
rm -f "$_stderr_file"
rm -rf "$_tdir"
_eng95_restore_env

# QA-adv-9: _always_include_paths returns exactly the cataloged 18
# entries, every one a literal filename or `docs/`. No directory prefixes
# beyond `docs/`, no `<placeholder>`s. Pin the catalog shape so an
# accidental edit (e.g. adding `src/` to the catalog) is caught.
_got_count="$(_always_include_paths | grep -c '.' | tr -d ' ')"
assert_eq 'eng95_qa_adv_always_include_catalog_count' '18' "$_got_count"
_dir_entries="$(_always_include_paths | grep -c '/$' | tr -d ' ')"
# Only `docs/` is a directory prefix; the other 17 are literal filenames.
assert_eq 'eng95_qa_adv_always_include_one_directory_only' '1' "$_dir_entries"
# No placeholders. (grep -c returns rc=1 on zero matches under
# pipefail+errexit from common.sh; awk avoids the rc trap.)
_placeholder_count="$(_always_include_paths | awk '/</ {n++} END {print n+0}')"
assert_eq 'eng95_qa_adv_always_include_no_placeholders' '0' "$_placeholder_count"

# QA-adv-10: Bullet with `%` and `$` in the path. printf '%s' is the
# safe form, but pin against accidental re-introduction of
# `printf "$profile_list"` (format-string injection) by sending a path
# with `%s` through the full stage_output_paths pipeline.
_eng95_save_env
_tdir="$(mktemp -d -t twinning-eng95-qa.XXXXXX)"
_pf="$(_eng95_write_profile "$_tdir" '- `pct-%s-end/` — percent-s in path')"
HARNESS_ROOT="$_tdir"
PROJECT_SLUG="test-slug"
export HARNESS_ROOT PROJECT_SLUG
unset CONFIG
_got="$(stage_output_paths implementing 2>/dev/null | grep '^pct-' | head -1)"
assert_eq 'eng95_qa_adv_percent_s_in_path_safe' 'pct-%s-end/' "$_got"
rm -rf "$_tdir"
_eng95_restore_env

# QA-adv-11: Empty profile file (0-byte). [[ -f ]] passes; awk reads
# nothing; parser emits nothing. stage_output_paths logs the diagnostic
# and falls through to catalog.
_eng95_save_env
_tdir="$(mktemp -d -t twinning-eng95-qa.XXXXXX)"
mkdir -p "$_tdir/learned-rules/test-slug"
: > "$_tdir/learned-rules/test-slug/project-profile.md"
HARNESS_ROOT="$_tdir"
PROJECT_SLUG="test-slug"
export HARNESS_ROOT PROJECT_SLUG
unset CONFIG
_parser_got="$(_parse_profile_file_layout "$_tdir/learned-rules/test-slug/project-profile.md" test-slug | paste -sd, -)"
assert_eq 'eng95_qa_adv_empty_profile_file' '' "$_parser_got"
_stderr_file="$_tdir/stderr"
stage_output_paths implementing >/dev/null 2>"$_stderr_file"
_stderr_grep_count="$(grep -c 'profile-derived list empty' "$_stderr_file" 2>/dev/null | tr -d ' ' || true)"
_stderr_grep_count="${_stderr_grep_count:-0}"
assert_eq 'eng95_qa_adv_empty_profile_file_log_fires' '1' "$_stderr_grep_count"
rm -rf "$_tdir"
_eng95_restore_env

# QA-adv-12: Adjacent bullets with no blank-line separator are all
# extracted (markdown allows tight lists).
_eng95_save_env
_tdir="$(mktemp -d -t twinning-eng95-qa.XXXXXX)"
mkdir -p "$_tdir/learned-rules/test-slug"
printf -- '---\nslug: test-slug\n---\n\n## File layout\n- `a/`\n- `b/`\n- `c/`\n' \
  > "$_tdir/learned-rules/test-slug/project-profile.md"
_parser_got="$(_parse_profile_file_layout "$_tdir/learned-rules/test-slug/project-profile.md" test-slug | LC_ALL=C sort | paste -sd, -)"
assert_eq 'eng95_qa_adv_tight_list_no_blank_lines' 'a/,b/,c/' "$_parser_got"
rm -rf "$_tdir"
_eng95_restore_env

# QA-adv-13: Profile ends mid-section (no closing H2). awk's exit guard
# `in_section && /^## /` never fires; bullets through EOF must all
# extract.
_eng95_save_env
_tdir="$(mktemp -d -t twinning-eng95-qa.XXXXXX)"
mkdir -p "$_tdir/learned-rules/test-slug"
printf -- '---\nslug: test-slug\n---\n\n## File layout\n\n- `eof-bullet/` — runs to EOF, no closing heading' \
  > "$_tdir/learned-rules/test-slug/project-profile.md"
_parser_got="$(_parse_profile_file_layout "$_tdir/learned-rules/test-slug/project-profile.md" test-slug | paste -sd, -)"
assert_eq 'eng95_qa_adv_eof_no_closing_heading' 'eof-bullet/' "$_parser_got"
rm -rf "$_tdir"
_eng95_restore_env

# QA-adv-14: Slug starts with digit (valid per `^[a-zA-Z0-9_-]+$` regex,
# even though semantically odd). Confirms the regex character-class
# correctly admits digit-leading slugs.
_eng95_save_env
_tdir="$(mktemp -d -t twinning-eng95-qa.XXXXXX)"
_pf="$(_eng95_write_profile "$_tdir" '- `learned-rules/<slug>/` — digit-leading slug' 99slug)"
_got="$(_parse_profile_file_layout "$_pf" 99slug | paste -sd, -)"
assert_eq 'eng95_qa_adv_digit_leading_slug' 'learned-rules/99slug/' "$_got"
rm -rf "$_tdir"
_eng95_restore_env

# ─── stage_is_read_mostly (predicate over stage_output_paths SoT) ───────
#
# Single source of truth: predicate derives from stage_output_paths
# returning empty. No duplicate stage list to drift.

test_read_mostly_predicate() {
  if stage_is_read_mostly reviewing; then
    report_ok 'read_mostly: reviewing is read-mostly'
  else
    report_fail 'read_mostly: reviewing' 'true' 'false'
  fi
  if stage_is_read_mostly building; then
    report_ok 'read_mostly: building is read-mostly'
  else
    report_fail 'read_mostly: building' 'true' 'false'
  fi
  if stage_is_read_mostly released; then
    report_ok 'read_mostly: released is read-mostly'
  else
    report_fail 'read_mostly: released' 'true' 'false'
  fi
  for s in brainstorming planning implementing ui qa retrospective; do
    if stage_is_read_mostly "$s"; then
      report_fail "read_mostly: $s should NOT be read-mostly" 'false' 'true'
    else
      report_ok "read_mostly: $s correctly not read-mostly"
    fi
  done
}
test_read_mostly_predicate

# ─── clean_self_leak_residue (per-path cleanup taking explicit paths) ───

_self_leak_make_repo() {
  local td="$1" branch="$2"
  mkdir -p "$td"
  (
    cd "$td"
    git init -q
    git config user.email t@example.com
    git config user.name 'Test'
    printf 'baseline\n' > tracked.md
    git add tracked.md
    git commit -qm 'init'
    git branch -m main
    git checkout -qb "$branch"
  )
}

_self_leak_stub_metrics() {
  local stub_dir="$1" sink="$2"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/metrics.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$sink"
EOF
  chmod +x "$stub_dir/metrics.sh"
}

test_self_leak_cleans_untracked() {
  local td; td="$(mktemp -d -t twinning-self-leak.XXXXXX)"
  local wt="$td/wt"; _self_leak_make_repo "$wt" "feat/sl-untracked"
  echo "junk" > "$wt/tmp-foo.md"
  mkdir -p "$wt/.scratch"; echo "f" > "$wt/.scratch/bte.md"
  local sink="$td/metrics.log"; : > "$sink"
  _self_leak_stub_metrics "$td/stubs" "$sink"
  (
    SCRIPT_DIR="$td/stubs"
    clean_self_leak_residue ENG-SL01 reviewing "$wt" \
      "tmp-foo.md" ".scratch/bte.md"
  ) >/dev/null 2>&1
  if [[ -f "$wt/tmp-foo.md" || -f "$wt/.scratch/bte.md" ]]; then
    report_fail 'self_leak: untracked files removed' 'both removed' 'one or both remain'
  else
    report_ok 'self_leak: untracked files removed'
  fi
  rm -rf "$td"
}
test_self_leak_cleans_untracked

test_self_leak_reverts_tracked_modification() {
  local td; td="$(mktemp -d -t twinning-self-leak.XXXXXX)"
  local wt="$td/wt"; _self_leak_make_repo "$wt" "feat/sl-tracked"
  echo "modified" >> "$wt/tracked.md"
  local sink="$td/metrics.log"; : > "$sink"
  _self_leak_stub_metrics "$td/stubs" "$sink"
  (
    SCRIPT_DIR="$td/stubs"
    clean_self_leak_residue ENG-SL02 reviewing "$wt" "tracked.md"
  ) >/dev/null 2>&1
  local content; content="$(cat "$wt/tracked.md")"
  assert_eq 'self_leak: tracked modification reverted via git checkout' 'baseline' "$content"
  rm -rf "$td"
}
test_self_leak_reverts_tracked_modification

test_self_leak_preserves_paths_NOT_in_list() {
  # Core correctness invariant from review finding C1 — the helper
  # NEVER touches a path it wasn't told to touch. Snapshot protection
  # comes from run-local.sh's observed-vs-self-leak split upstream.
  local td; td="$(mktemp -d -t twinning-self-leak.XXXXXX)"
  local wt="$td/wt"; _self_leak_make_repo "$wt" "feat/sl-preserve"
  echo "operator-work-in-progress" > "$wt/operator-edit.md"
  echo "agent-junk" > "$wt/agent-residue.md"
  local sink="$td/metrics.log"; : > "$sink"
  _self_leak_stub_metrics "$td/stubs" "$sink"
  (
    SCRIPT_DIR="$td/stubs"
    clean_self_leak_residue ENG-SL03 reviewing "$wt" "agent-residue.md"
  ) >/dev/null 2>&1
  if [[ ! -f "$wt/operator-edit.md" ]]; then
    report_fail 'self_leak: operator pre-existing edit preserved' 'present' 'removed'
  else
    local op_content; op_content="$(cat "$wt/operator-edit.md")"
    if [[ "$op_content" == "operator-work-in-progress" ]]; then
      report_ok 'self_leak: operator pre-existing edit preserved (C1 correctness)'
    else
      report_fail 'self_leak: operator content preserved' \
        'operator-work-in-progress' "$op_content"
    fi
  fi
  if [[ -f "$wt/agent-residue.md" ]]; then
    report_fail 'self_leak: agent residue removed' 'removed' 'present'
  else
    report_ok 'self_leak: agent residue removed (the path passed in)'
  fi
  rm -rf "$td"
}
test_self_leak_preserves_paths_NOT_in_list

test_self_leak_empty_path_list_noop() {
  local td; td="$(mktemp -d -t twinning-self-leak.XXXXXX)"
  local wt="$td/wt"; _self_leak_make_repo "$wt" "feat/sl-empty"
  local sink="$td/metrics.log"; : > "$sink"
  _self_leak_stub_metrics "$td/stubs" "$sink"
  (
    SCRIPT_DIR="$td/stubs"
    clean_self_leak_residue ENG-SL04 reviewing "$wt"
  ) >/dev/null 2>&1
  if [[ -s "$sink" ]]; then
    report_fail 'self_leak: empty list emits no metric' 'no metric' "$(cat "$sink")"
  else
    report_ok 'self_leak: empty path list is a no-op (no metric emitted)'
  fi
  rm -rf "$td"
}
test_self_leak_empty_path_list_noop

test_self_leak_missing_worktree_noop() {
  local td; td="$(mktemp -d -t twinning-self-leak.XXXXXX)"
  local sink="$td/metrics.log"; : > "$sink"
  _self_leak_stub_metrics "$td/stubs" "$sink"
  local rc=0
  (
    SCRIPT_DIR="$td/stubs"
    clean_self_leak_residue ENG-SL05 reviewing "$td/nope" "any.md"
  ) >/dev/null 2>&1 || rc=$?
  assert_eq 'self_leak: missing worktree rc=0' '0' "$rc"
  rm -rf "$td"
}
test_self_leak_missing_worktree_noop

test_self_leak_refuses_on_main_branch() {
  local td; td="$(mktemp -d -t twinning-self-leak.XXXXXX)"
  local wt="$td/wt"; mkdir -p "$wt"
  (
    cd "$wt"
    git init -q
    git config user.email t@example.com
    git config user.name 'Test'
    printf 'baseline\n' > tracked.md
    git add tracked.md
    git commit -qm 'init'
    git branch -m main
  )
  echo "should-survive" > "$wt/residue.md"
  local sink="$td/metrics.log"; : > "$sink"
  _self_leak_stub_metrics "$td/stubs" "$sink"
  (
    SCRIPT_DIR="$td/stubs"
    clean_self_leak_residue ENG-SL06 reviewing "$wt" "residue.md"
  ) >/dev/null 2>&1
  if [[ -f "$wt/residue.md" ]]; then
    report_ok 'self_leak: defensive refuse on main (residue preserved)'
  else
    report_fail 'self_leak: defensive refuse on main' 'preserved' 'cleaned'
  fi
  rm -rf "$td"
}
test_self_leak_refuses_on_main_branch

test_self_leak_dry_run_skips_mutation() {
  local td; td="$(mktemp -d -t twinning-self-leak.XXXXXX)"
  local wt="$td/wt"; _self_leak_make_repo "$wt" "feat/sl-dry"
  echo "junk" > "$wt/tmp.md"
  local sink="$td/metrics.log"; : > "$sink"
  _self_leak_stub_metrics "$td/stubs" "$sink"
  (
    SCRIPT_DIR="$td/stubs"
    PIPELINE_DRY_RUN=1
    clean_self_leak_residue ENG-SL07 reviewing "$wt" "tmp.md"
  ) >/dev/null 2>&1
  if [[ -f "$wt/tmp.md" ]]; then
    report_ok 'self_leak: dry-run preserves worktree'
  else
    report_fail 'self_leak: dry-run' 'preserved' 'cleaned'
  fi
  rm -rf "$td"
}
test_self_leak_dry_run_skips_mutation

test_self_leak_metric_payload_pinned() {
  # Review finding M4: assertion must pin event name + issue + stage +
  # outcome + exit-code + notes including count, branch, hashes, and
  # per-class failure counts. Substring-match is not enough — a
  # regression that drops `count=` or `hashes=` would slip past.
  local td; td="$(mktemp -d -t twinning-self-leak.XXXXXX)"
  local wt="$td/wt"; _self_leak_make_repo "$wt" "feat/sl-metric"
  echo "a" > "$wt/p1.md"
  echo "b" > "$wt/p2.md"
  local sink="$td/metrics.log"; : > "$sink"
  _self_leak_stub_metrics "$td/stubs" "$sink"
  (
    SCRIPT_DIR="$td/stubs"
    clean_self_leak_residue ENG-SL08 reviewing "$wt" "p1.md" "p2.md"
  ) >/dev/null 2>&1
  local line; line="$(cat "$sink")"
  case "$line" in
    *'sweep-readonly-residue-cleaned ENG-SL08 reviewing cleaned 0 count=2 branch=feat/sl-metric hashes='*'rm_fail=0 checkout_fail=0'*)
      report_ok 'self_leak: metric payload pinned (event/issue/stage/count/branch/hashes/fail-counts)'
      ;;
    *)
      report_fail 'self_leak: metric payload pinned' \
        'full positional argv with count=2, branch, hashes, fail counts' \
        "$line"
      ;;
  esac
  rm -rf "$td"
}
test_self_leak_metric_payload_pinned

test_self_leak_partial_failure_still_emits_metric() {
  # Review finding M5: per-class rc bookkeeping does not propagate
  # rc≠0, AND the metric still emits so retrospective sees the
  # partial-failure event. Seed a path rm can't remove by making the
  # parent dir read-only.
  local td; td="$(mktemp -d -t twinning-self-leak.XXXXXX)"
  local wt="$td/wt"; _self_leak_make_repo "$wt" "feat/sl-fail"
  mkdir -p "$wt/locked"
  echo "locked-content" > "$wt/locked/payload.md"
  chmod 555 "$wt/locked"  # parent read-only: child rm fails
  local sink="$td/metrics.log"; : > "$sink"
  _self_leak_stub_metrics "$td/stubs" "$sink"
  local rc=0
  (
    SCRIPT_DIR="$td/stubs"
    clean_self_leak_residue ENG-SL09 reviewing "$wt" "locked/payload.md"
  ) >/dev/null 2>&1 || rc=$?
  assert_eq 'self_leak: partial-failure path returns rc=0' '0' "$rc"
  case "$(cat "$sink")" in
    *'sweep-readonly-residue-cleaned'*'rm_fail=1'*)
      report_ok 'self_leak: partial failure still emits metric with rm_fail=1'
      ;;
    *)
      report_fail 'self_leak: partial-failure metric' \
        'rm_fail=1 in payload' "$(cat "$sink")"
      ;;
  esac
  chmod 755 "$wt/locked" 2>/dev/null || true
  rm -rf "$td"
}
test_self_leak_partial_failure_still_emits_metric

# ─── stage_is_read_mostly unknown-stage hardening (post-v2 correctness) ──
# Previous version's `2>/dev/null || true` swallowed stage_output_paths's
# die on unknown stages → unknown classified as read-mostly. Hardened
# version checks rc explicitly so unknown → NOT read-mostly (conservative).
test_read_mostly_predicate_unknown_stage_returns_false() {
  if stage_is_read_mostly bogus-stage-name 2>/dev/null; then
    report_fail 'read_mostly: unknown stage should NOT be read-mostly' 'false' 'true'
  else
    report_ok 'read_mostly: unknown stage is NOT read-mostly (conservative)'
  fi
  # Empty-string stage also: stage_output_paths dies on empty, predicate
  # must NOT silently classify as read-mostly.
  if stage_is_read_mostly "" 2>/dev/null; then
    report_fail 'read_mostly: empty-string stage should NOT be read-mostly' 'false' 'true'
  else
    report_ok 'read_mostly: empty-string stage is NOT read-mostly'
  fi
}
test_read_mostly_predicate_unknown_stage_returns_false

# ─── clean_scratch_dir (tick-end stage-agnostic cross-dispatch guard) ───
# Closes the cross-dispatch persistence vector: .scratch/ is gitignored
# and therefore invisible to git status / partition / self_leak_paths
# on every stage. Without this cleanup, files an agent drops into
# .scratch/ during one dispatch survive into the next.

test_clean_scratch_dir_removes_directory() {
  local td; td="$(mktemp -d -t twinning-scratch.XXXXXX)"
  mkdir -p "$td/.scratch/nested"
  echo "leftover" > "$td/.scratch/payload.md"
  echo "deep" > "$td/.scratch/nested/file.md"
  clean_scratch_dir "$td" >/dev/null 2>&1
  if [[ -e "$td/.scratch" ]]; then
    report_fail 'scratch-clean: .scratch/ removed' 'absent' 'present'
  else
    report_ok 'scratch-clean: .scratch/ directory removed (including nested files)'
  fi
  rm -rf "$td"
}
test_clean_scratch_dir_removes_directory

test_clean_scratch_dir_missing_noop() {
  local td; td="$(mktemp -d -t twinning-scratch.XXXXXX)"
  local rc=0
  clean_scratch_dir "$td" >/dev/null 2>&1 || rc=$?
  assert_eq 'scratch-clean: missing .scratch/ returns rc=0 (no-op)' '0' "$rc"
  rm -rf "$td"
}
test_clean_scratch_dir_missing_noop

test_clean_scratch_dir_preserves_siblings() {
  # Cleanup MUST NOT touch anything outside .scratch/. The worktree's
  # source files, gitignored .pipeline-config, etc., all stay.
  local td; td="$(mktemp -d -t twinning-scratch.XXXXXX)"
  mkdir -p "$td/.scratch" "$td/src" "$td/.pipeline-config"
  echo "scratch" > "$td/.scratch/junk.md"
  echo "source"  > "$td/src/main.rs"
  echo "config"  > "$td/.pipeline-config/config.json"
  clean_scratch_dir "$td" >/dev/null 2>&1
  if [[ -f "$td/src/main.rs" && -f "$td/.pipeline-config/config.json" && ! -e "$td/.scratch" ]]; then
    report_ok 'scratch-clean: preserves siblings (.scratch/ gone, src/ + .pipeline-config/ intact)'
  else
    report_fail 'scratch-clean: sibling preservation' \
      'src/main.rs + .pipeline-config/config.json present; .scratch absent' \
      "src=$([[ -f "$td/src/main.rs" ]] && echo y || echo n) cfg=$([[ -f "$td/.pipeline-config/config.json" ]] && echo y || echo n) scratch=$([[ -e "$td/.scratch" ]] && echo present || echo absent)"
  fi
  rm -rf "$td"
}
test_clean_scratch_dir_preserves_siblings

test_clean_scratch_dir_dry_run_skips_mutation() {
  local td; td="$(mktemp -d -t twinning-scratch.XXXXXX)"
  mkdir -p "$td/.scratch"
  echo "preserved" > "$td/.scratch/payload.md"
  (
    PIPELINE_DRY_RUN=1
    clean_scratch_dir "$td"
  ) >/dev/null 2>&1
  if [[ -f "$td/.scratch/payload.md" ]]; then
    report_ok 'scratch-clean: dry-run preserves .scratch/ contents'
  else
    report_fail 'scratch-clean: dry-run' 'preserved' 'removed'
  fi
  rm -rf "$td"
}
test_clean_scratch_dir_dry_run_skips_mutation

# ─── Integration test (M-T2): self-leak handler pipeline end-to-end ─────
# All clean_self_leak_residue unit tests call the helper directly with
# hand-crafted path lists. The full production flow is:
#   tick-start snapshot → dispatch → partition → observed-vs-self-leak
#   classification (populates self_leak_paths + self_leak_hashes) →
#   stage_is_read_mostly branch → clean_self_leak_residue invocation
# A regression dropping `self_leak_paths+=("$p")` from the classification
# loop would cause clean_self_leak_residue to be invoked with an empty
# array → silent no-op. The wire-up greps catch the deletion at source
# level; this test exercises the dynamic behavior of the loop + helper
# pair together.
test_self_leak_handler_pipeline_e2e() {
  local td; td="$(mktemp -d -t twinning-pipeline.XXXXXX)"
  local wt="$td/wt"
  _self_leak_make_repo "$wt" "feat/integration"

  # Seed the OPERATOR's pre-existing edit (would be in tick-start snapshot).
  echo "operator-wip" > "$wt/operator-edit.md"
  # Seed two AGENT residue files (would self-leak post-dispatch).
  echo "agent-fixture-A" > "$wt/agent-A.md"
  echo "agent-fixture-B" > "$wt/agent-B.md"

  # Build a snapshot_file containing ONLY the operator's path (the
  # state at tick-start, before dispatch produced agent-A.md / agent-B.md).
  local snapshot_file="$td/snapshot"
  echo "operator-edit.md" > "$snapshot_file"

  # Simulate partition's out_scope_file output. In production this comes
  # from `git status -z | partition_dirty_paths ... 5>out_scope_file`.
  # All three files are dirty post-dispatch and (since the test stage
  # is `reviewing` with no allowlist) all three land in out-of-scope FD5.
  local out_scope_file="$td/out_scope"
  printf 'operator-edit.md\0agent-A.md\0agent-B.md\0' > "$out_scope_file"

  # Stub metrics.sh so the helper's emit doesn't fail.
  local sink="$td/metrics.log"; : > "$sink"
  _self_leak_stub_metrics "$td/stubs" "$sink"

  # Now replay the observed-vs-self-leak classification loop from
  # bin/run-local.sh:286-310. If the loop's self_leak_paths+=("$p") line
  # is missing in the actual production file, this replay still works
  # because we're executing OUR copy here — the wire-up grep is what
  # catches the source-level regression. This test catches a different
  # class: that the dynamic semantics work correctly when the loop IS
  # wired up properly.
  local observed_buckets=() self_leak_hashes=() self_leak_paths=()
  while IFS= read -r -d '' p; do
    if grep -qxF -- "$p" "$snapshot_file"; then
      observed_buckets+=("$(bucket_for_path "$p")")
    else
      self_leak_hashes+=("$(sha12 "$p")")
      self_leak_paths+=("$p")
    fi
  done < "$out_scope_file"

  # Invariant: operator's path went to observed; agent's paths went to
  # self_leak. The C1 correctness invariant is enforced HERE (the
  # snapshot check in the classification loop), not in clean_self_leak_residue.
  assert_eq 'pipeline: observed_buckets count' '1' "${#observed_buckets[@]}"
  assert_eq 'pipeline: self_leak_paths count'   '2' "${#self_leak_paths[@]}"
  assert_eq 'pipeline: self_leak_hashes count'  '2' "${#self_leak_hashes[@]}"

  # stage_is_read_mostly branch — reviewing IS read-mostly, so clean path runs.
  if stage_is_read_mostly reviewing; then
    (
      SCRIPT_DIR="$td/stubs"
      clean_self_leak_residue ENG-INT01 reviewing "$wt" "${self_leak_paths[@]}"
    ) >/dev/null 2>&1
  fi

  # Assert C1 — operator's edit survives.
  local op_content; op_content="$(cat "$wt/operator-edit.md" 2>/dev/null)"
  if [[ "$op_content" == "operator-wip" ]]; then
    report_ok 'pipeline-e2e: operator pre-existing edit survives (C1 invariant preserved)'
  else
    report_fail 'pipeline-e2e: C1 invariant' 'operator-wip' "${op_content:-MISSING}"
  fi

  # Assert agent residue removed.
  if [[ ! -f "$wt/agent-A.md" && ! -f "$wt/agent-B.md" ]]; then
    report_ok 'pipeline-e2e: agent residue removed (both self-leak paths)'
  else
    report_fail 'pipeline-e2e: residue removal' \
      'both agent-A.md and agent-B.md removed' \
      "A=$([[ -f "$wt/agent-A.md" ]] && echo present || echo absent) B=$([[ -f "$wt/agent-B.md" ]] && echo present || echo absent)"
  fi

  # Assert metric was emitted with count=2.
  case "$(cat "$sink")" in
    *'sweep-readonly-residue-cleaned ENG-INT01 reviewing cleaned 0 count=2 branch=feat/integration'*)
      report_ok 'pipeline-e2e: metric emitted with count=2 and integration branch'
      ;;
    *)
      report_fail 'pipeline-e2e: metric payload' \
        'sweep-readonly-residue-cleaned ENG-INT01 reviewing cleaned 0 count=2 branch=feat/integration ...' \
        "$(cat "$sink")"
      ;;
  esac

  rm -rf "$td"
}
test_self_leak_handler_pipeline_e2e

# ─── Wire-up assertions (review finding m1 — strengthened post-v2) ──────
# A regression that deletes any of the four load-bearing wire-up lines
# from run-local.sh would leave every unit test green while removing
# the production fix entirely. The previous version used a greedy
# `.*$issue_id.*$stage.*$dispatch_cwd` regex that matched even when
# args were reordered or padded with junk — testing-reviewer M-T1.
# This version pins each load-bearing line with explicit quoted-token
# anchors so a positional regression visibly fails.
test_self_leak_callsite_wired() {
  local rl="$SCRIPT_DIR/run-local.sh"
  if [[ ! -f "$rl" ]]; then
    report_fail 'self_leak: run-local.sh exists for wire-up grep' 'present' 'missing'
    return
  fi
  # Anchor 1: self_leak_paths array is declared empty alongside hashes.
  # ENG-81: also accept the function-local form `local -a self_leak_paths=()`
  # introduced when the body moved into _run_worker() (Task 5 refactor).
  if grep -qE '^[[:space:]]*(local[[:space:]]+-a[[:space:]]+)?self_leak_paths=\(\)' "$rl"; then
    report_ok 'wire-up #1: self_leak_paths=() declaration present in run-local.sh'
  else
    report_fail 'wire-up #1: self_leak_paths declaration' \
      'self_leak_paths=() (with optional `local -a` prefix) at column-aligned indentation' 'not found'
  fi
  # Anchor 2: self_leak_paths is appended-to in the observed-vs-self-leak
  # loop (the load-bearing line that, if dropped, makes self_leak_paths
  # always empty and silently no-ops clean_self_leak_residue).
  if grep -qE 'self_leak_paths\+=\("\$p"\)' "$rl"; then
    report_ok 'wire-up #2: self_leak_paths+=("$p") push site present in run-local.sh'
  else
    report_fail 'wire-up #2: self_leak_paths push' \
      'self_leak_paths+=("$p") inside the observed-vs-self-leak loop' 'not found'
  fi
  # Anchor 3: stage_is_read_mostly is the gate inside the self-leak
  # handler — must appear with $stage as the sole positional argument.
  if grep -qE 'if[[:space:]]+stage_is_read_mostly[[:space:]]+"\$stage";' "$rl"; then
    report_ok 'wire-up #3: stage_is_read_mostly "$stage" gate present in run-local.sh'
  else
    report_fail 'wire-up #3: predicate gate' \
      'if stage_is_read_mostly "$stage"; then' 'not found'
  fi
  # Anchor 4: clean_self_leak_residue invocation with the exact
  # positional argv (issue, stage, worktree) AND the array splat as
  # the trailing argument. A refactor that drops "${self_leak_paths[@]}"
  # or reorders any positional silently breaks the production path.
  if grep -qE 'clean_self_leak_residue[[:space:]]+"\$issue_id"[[:space:]]+"\$stage"[[:space:]]+"\$dispatch_cwd"[[:space:]]+"\$\{self_leak_paths\[@\]\}"' "$rl"; then
    report_ok 'wire-up #4: clean_self_leak_residue "$issue_id" "$stage" "$dispatch_cwd" "${self_leak_paths[@]}" exact invocation'
  else
    report_fail 'wire-up #4: callsite exact shape' \
      'clean_self_leak_residue "$issue_id" "$stage" "$dispatch_cwd" "${self_leak_paths[@]}"' \
      'not found (refactor may have reordered args or dropped the array splat)'
  fi
  # Anchor 5: clean_scratch_dir tick-end cleanup wired.
  if grep -qE '^[[:space:]]*clean_scratch_dir[[:space:]]+"\$dispatch_cwd"' "$rl"; then
    report_ok 'wire-up #5: clean_scratch_dir "$dispatch_cwd" tick-end cleanup present in run-local.sh'
  else
    report_fail 'wire-up #5: scratch-dir cleanup' \
      'clean_scratch_dir "$dispatch_cwd" before the precedence block' 'not found'
  fi
  # Anchor 6: clean_scratch_dir MUST appear BEFORE the rc-gate that
  # exits on dispatch failure. Without this position invariant, agent
  # failures (timeout rc=124, envelope validator rc=29, scope-check
  # rc=21, crashes) leave stale .scratch/ payload across operator
  # --action continue resumes — re-opening the cross-dispatch state-
  # injection vector. Catches refactor regressions that move the
  # cleanup downstream of the failure exit (the bug correctness
  # reviewer caught in v3).
  #
  # ENG-81 review.minor: the rc-gate idiom is now the clean form
  # `if [[ $rc -ne 0 ]]; then return $rc; fi` (was the opaque
  # `&& exit $rc; then :; fi` workaround that pinned the test grep).
  # This regex accepts the canonical `if-then-return-fi` shape.
  # Suppress set -e from sourced common.sh: grep no-match returns 1
  # under pipefail and kills the test before report_fail can run. Using
  # `|| true` on the subshell preserves report_fail's diagnostic.
  local cleanup_line rcgate_line
  cleanup_line="$(grep -n 'clean_scratch_dir[[:space:]]\+"\$dispatch_cwd"' "$rl" | head -1 | cut -d: -f1 || true)"
  rcgate_line="$(grep -nE '\[\[[[:space:]]+\$rc[[:space:]]+-ne[[:space:]]+0[[:space:]]+\]\][[:space:]]*;[[:space:]]*then[[:space:]]+return[[:space:]]+\$rc' "$rl" | head -1 | cut -d: -f1 || true)"
  if [[ -z "$cleanup_line" || -z "$rcgate_line" ]]; then
    report_fail 'wire-up #6: positional invariant' \
      "clean_scratch_dir must appear before [[ \$rc -ne 0 ]]; then return \$rc (cleanup=${cleanup_line:-MISSING}, rc-gate=${rcgate_line:-MISSING})" \
      'one or both anchors missing — agent-failure ticks would leak stale .scratch/ across --action continue'
  elif (( cleanup_line < rcgate_line )); then
    report_ok "wire-up #6: clean_scratch_dir at line $cleanup_line runs BEFORE rc-gate at line $rcgate_line"
  else
    report_fail 'wire-up #6: positional invariant' \
      "clean_scratch_dir line < rc-gate line (cleanup=$cleanup_line, rc-gate=$rcgate_line)" \
      'cleanup is at or after rc-gate — agent-failure ticks would leak stale .scratch/ across --action continue'
  fi
}
test_self_leak_callsite_wired

# ─── ENG-81 review.major: scheduler-side in-flight lock wire-up ───────
# Production code (run-local.sh) must:
#   1. Declare `_SCHEDULER_INFLIGHT_LOCKS=()` array.
#   2. Push to it after every try_acquire_lock claim.
#   3. Reap it inside cleanup_on_exit (EXIT trap).
#   4. Clear it just before forking workers (so the trap stops reaping
#      locks that workers now own).
# Without each of these, the leak path described in the review re-opens.
test_scheduler_inflight_lock_wireup() {
  local rl="$SCRIPT_DIR/run-local.sh"
  if [[ ! -f "$rl" ]]; then
    report_fail 'scheduler-leak: run-local.sh present' 'present' 'missing'
    return
  fi
  if grep -qE '^[[:space:]]*_SCHEDULER_INFLIGHT_LOCKS=\(\)' "$rl"; then
    report_ok "wire-up scheduler-leak #1: _SCHEDULER_INFLIGHT_LOCKS=() declared"
  else
    report_fail "wire-up scheduler-leak #1: tracking array missing" \
      "_SCHEDULER_INFLIGHT_LOCKS=()" "not found"
  fi
  if grep -qE '_SCHEDULER_INFLIGHT_LOCKS\+=\(.*inflight_lock' "$rl"; then
    report_ok "wire-up scheduler-leak #2: array push after try_acquire_lock claim"
  else
    report_fail "wire-up scheduler-leak #2: array push missing" \
      '_SCHEDULER_INFLIGHT_LOCKS+=("$inflight_lock")' "not found"
  fi
  # Cleanup must walk the array and call release_lock on each entry.
  if grep -qE 'for[[:space:]]+_[a-z_]+[[:space:]]+in[[:space:]]+.*_SCHEDULER_INFLIGHT_LOCKS' "$rl"; then
    report_ok "wire-up scheduler-leak #3: cleanup_on_exit walks _SCHEDULER_INFLIGHT_LOCKS"
  else
    report_fail "wire-up scheduler-leak #3: cleanup loop missing" \
      'for _l in "${_SCHEDULER_INFLIGHT_LOCKS[@]}"' "not found"
  fi
  # Pre-fork clear so workers own their locks.
  if grep -qE '^[[:space:]]*_SCHEDULER_INFLIGHT_LOCKS=\(\)' "$rl" \
    && [[ "$(grep -cE '^[[:space:]]*_SCHEDULER_INFLIGHT_LOCKS=\(\)' "$rl")" -ge 2 ]]; then
    report_ok "wire-up scheduler-leak #4: array cleared (init + pre-fork)"
  else
    report_fail "wire-up scheduler-leak #4: missing pre-fork clear" \
      "two _SCHEDULER_INFLIGHT_LOCKS=() lines (init + before worker fork)" \
      "fewer than 2 occurrences in run-local.sh"
  fi
}
test_scheduler_inflight_lock_wireup

# ─── ENG-81 Task 4: per-issue .in-flight.lock contention ──────────────
# Acquired by the run-local.sh scheduler arm before forking a worker
# for a specific issue. Prevents the same issue from being dispatched
# twice if a tick-N worker is still running when tick-N+1 fires (the
# K=1 lock cannot help here — it is a global single-flight, not a
# per-issue gate). Uses try_acquire_lock from common.sh (added in this
# ticket; non-blocking by design — acquire_lock with timeout=0 means
# "wait forever" and would hang the scheduler).
#
# Post-stale-lock-recovery (ENG-81 review.major bin/common.sh:411-414):
# the contention check uses a LIVE background process as the lock
# holder. A dead-pid lock is reclaimed by the new acquirer (covered by
# AC-TAL-RECLAIM-DEAD in common-test.sh), so the "second-acquire
# blocked" assertion only holds when the holder is actually alive.
test_inflight_lock_contention() {
  local case_name="AC-INFLIGHT-LOCK"
  local eh_dir; eh_dir="$(mktemp -d -t twinning-inflight.XXXXXX)"
  local issue_root="$eh_dir/issue-state-test"
  mkdir -p "$issue_root/ENG-INFLIGHT"
  local lock_dir="$issue_root/ENG-INFLIGHT/.in-flight.lock"

  # First acquire by the test runner (live pid = $$).
  local out1
  out1="$(PROJECT_STATE_DIR="$issue_root" bash -c '
    SCRIPT_DIR="'"$SCRIPT_DIR"'"
    source "$SCRIPT_DIR/common.sh"
    try_acquire_lock "$(issue_dir ENG-INFLIGHT)/.in-flight.lock" || echo SECOND_FAILED
  ' 2>&1)"
  if [[ -z "$out1" ]]; then
    report_ok "$case_name first-acquire produces no output (lock taken)"
  else
    report_fail "$case_name first acquire" "empty stdout" "got: $out1"
  fi

  # Now overwrite the pid file with a LIVE backgrounded sleep so the
  # next acquire sees a live holder (not a dead subshell pid). This
  # models the real failure mode: tick N+1 fires while tick N's
  # WORKER (still alive) holds the lock.
  ( sleep 30 ) &
  local live_pid=$!
  printf '%s\n' "$live_pid" > "$lock_dir/pid"

  local out2
  out2="$(PROJECT_STATE_DIR="$issue_root" bash -c '
    SCRIPT_DIR="'"$SCRIPT_DIR"'"
    source "$SCRIPT_DIR/common.sh"
    try_acquire_lock "$(issue_dir ENG-INFLIGHT)/.in-flight.lock" || echo SECOND_FAILED
  ' 2>&1)"
  if grep -q SECOND_FAILED <<<"$out2"; then
    report_ok "$case_name second-acquire blocks (live holder → rc=1 → SECOND_FAILED)"
  else
    report_fail "$case_name second-acquire" "SECOND_FAILED in output" "got: $out2"
  fi

  kill "$live_pid" 2>/dev/null || true
  wait "$live_pid" 2>/dev/null || true
  rm -rf "$eh_dir"
}
test_inflight_lock_contention

# ─── ENG-81 review.major: scheduler-side in-flight lock leak ──────────
# Pre-fix, the run-local.sh scheduler acquired .in-flight.lock BEFORE
# every error-prone call (linear.sh transition-state, add-label,
# reconcile.sh, branch-name.sh, resolve_worktree_path, ensure_worktree).
# With set -e, any of those failing on a transient blip killed the
# scheduler; the EXIT trap reaped LOCK_DIR but not the per-issue
# in-flight locks, leaving the issue silently stuck across ticks.
#
# The fix: track scheduler-acquired-but-unforked locks in an array;
# release them all via the existing cleanup_on_exit trap. After
# workers fork, the array is cleared so each worker's own trap owns
# its lock.
test_scheduler_inflight_lock_cleanup_on_error() {
  local case_name="AC-SCHEDULER-INFLIGHT-CLEANUP"
  local eh_dir; eh_dir="$(mktemp -d -t twinning-sched-cleanup.XXXXXX)"
  local issue_root="$eh_dir/issue-state-test"
  mkdir -p "$issue_root/ENG-SCHED-LEAK"
  local lock_dir="$issue_root/ENG-SCHED-LEAK/.in-flight.lock"

  # Simulate the scheduler arm's pattern: acquire, register cleanup
  # trap, then die mid-claim before any worker forks.
  bash -c '
    set -euo pipefail
    SCRIPT_DIR="'"$SCRIPT_DIR"'"
    PROJECT_STATE_DIR="'"$issue_root"'"
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/common.sh"
    _SCHEDULER_INFLIGHT_LOCKS=()
    cleanup_on_exit() {
      local _l
      for _l in "${_SCHEDULER_INFLIGHT_LOCKS[@]+"${_SCHEDULER_INFLIGHT_LOCKS[@]}"}"; do
        release_lock "$_l"
      done
    }
    trap cleanup_on_exit EXIT

    try_acquire_lock "'"$lock_dir"'"
    _SCHEDULER_INFLIGHT_LOCKS+=("'"$lock_dir"'")

    # set -e bites here, simulating a Linear API blip.
    false
  ' >/dev/null 2>&1 || true

  if [[ ! -d "$lock_dir" ]]; then
    report_ok "$case_name scheduler EXIT trap releases unclaimed in-flight lock"
  else
    report_fail "$case_name lock leaked across scheduler error" \
      "lock dir absent" \
      "lock dir still present at $lock_dir"
  fi

  rm -rf "$eh_dir"
}
test_scheduler_inflight_lock_cleanup_on_error

# ─── ENG-81 Task 6: parallel events.jsonl writes (POSIX O_APPEND) ────
# 50 paired metrics.sh invocations from two issue identities, each
# backgrounded. POSIX O_APPEND guarantees atomic writes up to PIPE_BUF
# (4 KB on macOS); each metrics.sh line is ~250-500 bytes (8 base
# fields + 0-6 cost flags). Test pins: every line in events.jsonl
# parses as JSON; total line count >= 100.
test_parallel_events_jsonl_atomic() {
  local case_name="AC-METRICS-CONCURRENT-WRITE"
  local mc_dir; mc_dir="$(mktemp -d -t twinning-mcwrite.XXXXXX)"
  local i
  for i in $(seq 1 50); do
    PROJECT_STATE_DIR="$mc_dir" \
      bash "$SCRIPT_DIR/metrics.sh" stage-start "ENG-W1" "implementing" "test" 0 "iter=$i" &
    PROJECT_STATE_DIR="$mc_dir" \
      bash "$SCRIPT_DIR/metrics.sh" stage-start "ENG-W2" "implementing" "test" 0 "iter=$i" &
  done
  wait

  local events="$mc_dir/metrics/events.jsonl"
  if [[ ! -f "$events" ]]; then
    report_fail "$case_name events.jsonl missing" "exists" "absent"
    rm -rf "$mc_dir"
    return
  fi

  local total bad=0
  total="$(wc -l < "$events" | tr -d ' ')"
  while IFS= read -r line; do
    jq -e . <<<"$line" >/dev/null 2>&1 || bad=$((bad + 1))
  done < "$events"

  if (( bad == 0 && total >= 100 )); then
    report_ok "$case_name $total lines, 0 torn (POSIX O_APPEND atomic <= PIPE_BUF)"
  else
    report_fail "$case_name torn-write detected or short" \
      "0 torn lines, total >= 100" \
      "$bad torn lines, total=$total"
  fi
  rm -rf "$mc_dir"
}
test_parallel_events_jsonl_atomic

# ─── ENG-81 Task 6: worker-isolation under self-leak halt ─────────────
# When worker A halts via halt_issue_for_self_leak, the per-issue
# counter for worker B (a sibling issue) MUST NOT be touched. ENG-69's
# lane separation is the load-bearing invariant; this test pins it
# under the new K>1 worker fanout where worker A's halt could
# inadvertently mutate sibling state if implementations share globals.
test_worker_isolation_under_halt() {
  local case_name="AC-WORKER-ISOLATION"
  local wi_dir; wi_dir="$(mktemp -d -t twinning-isolation.XXXXXX)"
  mkdir -p "$wi_dir/ENG-WIA" "$wi_dir/ENG-WIB"

  PROJECT_STATE_DIR="$wi_dir" PIPELINE_DRY_RUN=1 \
    bash -c '
      SCRIPT_DIR="'"$SCRIPT_DIR"'"
      source "$SCRIPT_DIR/common.sh"
      source "$SCRIPT_DIR/classify-failure.sh"
      source "$SCRIPT_DIR/run-local-helpers.sh"
      halt_issue_for_self_leak ENG-WIA implementing abc123def456
    ' >/dev/null 2>&1 || true

  if [[ ! -f "$wi_dir/ENG-WIB/.consecutive-failures" ]]; then
    report_ok "$case_name ENG-WIB per-issue counter untouched by ENG-WIA halt"
  else
    report_fail "$case_name ENG-WIB counter mutated" \
      "absent" "present"
  fi
  rm -rf "$wi_dir"
}
test_worker_isolation_under_halt

printf '\n'
printf 'adversarial summary: %d passed, %d failed\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf 'failed cases:\n'
  for c in "${FAILED_CASES[@]}"; do
    printf '  - %s\n' "$c"
  done
  exit 1
fi
