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
  # ENG-69 debug: temporary write so the failing case details survive the
  # pre-commit hook's stdout-capture-and-discard behavior. Remove once the
  # test stabilizes.
  {
    printf '%s\n' "FAIL: $name"
    printf '%s\n' "  expected: $expected"
    printf '%s\n' "  got:      $got"
  } >> /tmp/eng69-test-debug.log 2>/dev/null || true
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
  assert_eq "ENG-69#1 self-leak routes per-issue (skip-until-human-acts, exit 26)" \
    "issue=ENG-901 stage=reviewing policy=skip-until-human-acts exit=26" \
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
#             human-acts, exit_code=27 (leaked-in-scope-threshold)
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

  # The single call uses skip-until-human-acts policy + exit_code=27.
  local got_call; got_call="$(awk -F'|' '{printf "issue=%s stage=%s policy=%s exit=%s",$1,$2,$3,$5}' "$classify_log")"
  assert_eq "ENG-69#2 threshold halt routes per-issue (exit 27)" \
    "issue=ENG-902 stage=implementing policy=skip-until-human-acts exit=27" \
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

printf '\n'
printf 'adversarial summary: %d passed, %d failed\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf 'failed cases:\n'
  for c in "${FAILED_CASES[@]}"; do
    printf '  - %s\n' "$c"
  done
  exit 1
fi
