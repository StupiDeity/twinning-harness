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
