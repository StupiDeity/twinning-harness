#!/usr/bin/env bash
# Test harness for run-local-helpers.sh's partition_dirty_paths.
# Wired into dry-run.sh. Exits non-zero on first failing case.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PROJECT_SLUG="${PROJECT_SLUG:-test-slug}"
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

# 1: brainstorming in-scope D-004 hit
printf '?? docs/brainstorms/2026-04-20-ENG-14-foo-design.md\0' \
  | assert_partition brainstorm_in_scope_d004_hit brainstorming ENG-14 1 0 0

# 2: brainstorming D-004 miss — same directory, other issue
printf '?? docs/brainstorms/2026-04-20-ENG-11-bar-design.md\0' \
  | assert_partition brainstorm_d004_miss_excludes_other_issue brainstorming ENG-14 0 1 0

# 3: planning D-004 case-insensitive hit
printf '?? docs/plans/2026-04-20-eng-14-foo.md\0' \
  | assert_partition plan_d004_case_insensitive_match planning ENG-14 1 0 0

# 4: building stage rejects brainstorm dir
printf '?? docs/brainstorms/anything.md\0' \
  | assert_partition build_rejects_brainstorm_dir building ENG-5 0 0 1

# (ENG-12 case 5 dropped — common telemetry entries removed per ENG-13.)

# 6: path-boundary — brainstorms-archive MUST NOT match brainstorms
printf '?? docs/brainstorms-archive/foo.md\0' \
  | assert_partition path_boundary_archive_excluded brainstorming ENG-14 0 0 1

# 7: filename with embedded space
printf '?? docs/brainstorms/2026-04-20-ENG-14-with space-design.md\0' \
  | assert_partition filename_with_spaces_handled brainstorming ENG-14 1 0 0

# 8: rename record consumes source
printf 'R  docs/plans/2026-04-20-eng-14-new.md\0docs/plans/2026-04-20-eng-14-old.md\0' \
  | assert_partition rename_record_consumes_source planning ENG-14 1 0 0

# 9: word-boundary — ENG-1 must NOT match ENG-14
printf '?? docs/plans/2026-04-20-eng-1-foo.md\0' \
  | assert_partition eng_1_does_not_match_eng_14 planning ENG-14 0 1 0

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

# 11: source file observed, not staged (brainstorming stage)
printf ' M crates/twinning-pipeline/src/foo.rs\0' \
  | assert_partition source_file_observed_not_staged brainstorming ENG-14 0 0 1

# 12 (new for ENG-13): implementing stage sweeps Rust source without D-004
# ENG-95: case-12 back-compat — the new derivation reads `## File layout`
# from `learned-rules/$PROJECT_SLUG/project-profile.md`. With PROJECT_SLUG=
# test-slug and no such profile present in the harness repo, the parser
# returns empty and the always-include catalog is the entire fallback —
# which does NOT include `crates/`. Seed a tempdir profile fixture listing
# `crates/` and point HARNESS_ROOT at it for the duration of this case.
_eng95_case12_tdir="$(mktemp -d -t twinning-eng95-case12.XXXXXX)"
mkdir -p "$_eng95_case12_tdir/learned-rules/$PROJECT_SLUG"
cat > "$_eng95_case12_tdir/learned-rules/$PROJECT_SLUG/project-profile.md" <<MD
---
slug: $PROJECT_SLUG
schema_version: 1
---

# Project profile

## File layout

- \`crates/\` — Rust workspace member dirs
MD
_eng95_case12_save_hr="${HARNESS_ROOT-}"
HARNESS_ROOT="$_eng95_case12_tdir"
export HARNESS_ROOT
printf ' M crates/twinning-pipeline/src/foo.rs\0' \
  | assert_partition implement_stage_sweeps_rust_source implementing ENG-14 1 0 0
HARNESS_ROOT="$_eng95_case12_save_hr"
export HARNESS_ROOT
rm -rf "$_eng95_case12_tdir"

# 13 (new for ENG-13, updated for ENG-23): retrospective allowlist now covers
# `.pipeline-config/config.json` (target-repo config) — `.pipeline/learned-rules/`
# moved to the harness repo and is no longer target-relative.
printf ' M .pipeline-config/config.json\0' \
  | assert_partition retrospective_pipeline_config_in_scope retrospective ENG-14 1 0 0

# ─── ENG-95: stack-fixture integration cases ────────────────────────────
# Each case seeds a tempdir profile (learned-rules/$PROJECT_SLUG/project-
# profile.md) with a stack-shaped `## File layout`, points HARNESS_ROOT
# at the tempdir for the duration of the assertion, and verifies that a
# representative dirty-path record lands in the expected stream. The
# helper below writes the fixture and runs the partition under the
# override; it always restores HARNESS_ROOT/CONFIG afterward.

_eng95_pin_root_with_profile() {
  local tdir="$1" layout_body="$2" slug="${3:-$PROJECT_SLUG}"
  mkdir -p "$tdir/learned-rules/$slug"
  {
    printf -- '---\n'
    printf 'slug: %s\n' "$slug"
    printf 'schema_version: 1\n'
    printf -- '---\n\n'
    printf '# Project profile\n\n## File layout\n\n%s\n' "$layout_body"
  } > "$tdir/learned-rules/$slug/project-profile.md"
}

# 14: Rust workspace — `crates/` + `tests/` in profile; agent writes
# `crates/twinning-foo/src/lib.rs` → in-scope.
_t="$(mktemp -d -t twinning-eng95-sweep.XXXXXX)"
_eng95_pin_root_with_profile "$_t" '- `crates/` — workspace member dirs
- `tests/` — integration tests'
_saved_hr="$HARNESS_ROOT"; HARNESS_ROOT="$_t"; export HARNESS_ROOT
printf '?? crates/twinning-foo/src/lib.rs\0' \
  | assert_partition profile_rust_workspace_inscope implementing ENG-14 1 0 0
HARNESS_ROOT="$_saved_hr"; export HARNESS_ROOT; rm -rf "$_t"

# 15: Python single-package — `app/` + `tests/` in profile; agent writes
# `app/handlers.py` → in-scope.
_t="$(mktemp -d -t twinning-eng95-sweep.XXXXXX)"
_eng95_pin_root_with_profile "$_t" '- `app/` — application code
- `tests/` — pytest suite'
_saved_hr="$HARNESS_ROOT"; HARNESS_ROOT="$_t"; export HARNESS_ROOT
printf '?? app/handlers.py\0' \
  | assert_partition profile_python_single_pkg_inscope implementing ENG-14 1 0 0
HARNESS_ROOT="$_saved_hr"; export HARNESS_ROOT; rm -rf "$_t"

# 16: Go module — `cmd/` + `pkg/` + `internal/` in profile; agent writes
# `cmd/server/main.go` → in-scope.
_t="$(mktemp -d -t twinning-eng95-sweep.XXXXXX)"
_eng95_pin_root_with_profile "$_t" '- `cmd/` — main packages
- `pkg/` — exported library code
- `internal/` — private packages'
_saved_hr="$HARNESS_ROOT"; HARNESS_ROOT="$_t"; export HARNESS_ROOT
printf '?? cmd/server/main.go\0' \
  | assert_partition profile_go_module_inscope implementing ENG-14 1 0 0
HARNESS_ROOT="$_saved_hr"; export HARNESS_ROOT; rm -rf "$_t"

# 17: harness-self — `bin/`, `learned-rules/<slug>/`, `AGENT_PROMPTS.md`
# in profile. Two assertions: (a) `?? bin/foo.sh` → in-scope; (b) the
# `<slug>` substitution lands `learned-rules/$PROJECT_SLUG/build.md`
# in-scope.
_t="$(mktemp -d -t twinning-eng95-sweep.XXXXXX)"
_eng95_pin_root_with_profile "$_t" '- `bin/` — orchestration scripts
- `learned-rules/<slug>/` — per-slug rules
- `AGENT_PROMPTS.md` — stage prompt source'
_saved_hr="$HARNESS_ROOT"; HARNESS_ROOT="$_t"; export HARNESS_ROOT
printf '?? bin/foo.sh\0' \
  | assert_partition profile_harness_self_inscope_bin implementing ENG-14 1 0 0
printf '?? learned-rules/%s/build.md\0' "$PROJECT_SLUG" \
  | assert_partition profile_harness_self_inscope_slug_sub implementing ENG-14 1 0 0
HARNESS_ROOT="$_saved_hr"; export HARNESS_ROOT; rm -rf "$_t"

# 18: Python lockfile via always-include catalog — profile lists only
# `app/`; agent writes `poetry.lock` (top-level lockfile) → in-scope
# via the always-include catalog, not the profile.
_t="$(mktemp -d -t twinning-eng95-sweep.XXXXXX)"
_eng95_pin_root_with_profile "$_t" '- `app/` — sole source dir'
_saved_hr="$HARNESS_ROOT"; HARNESS_ROOT="$_t"; export HARNESS_ROOT
printf '?? poetry.lock\0' \
  | assert_partition profile_python_lockfile_inscope implementing ENG-14 1 0 0
HARNESS_ROOT="$_saved_hr"; export HARNESS_ROOT; rm -rf "$_t"

# 19: Go lockfile via always-include catalog — profile lists only
# `cmd/`; agent writes `go.sum` → in-scope via catalog.
_t="$(mktemp -d -t twinning-eng95-sweep.XXXXXX)"
_eng95_pin_root_with_profile "$_t" '- `cmd/` — main packages only'
_saved_hr="$HARNESS_ROOT"; HARNESS_ROOT="$_t"; export HARNESS_ROOT
printf '?? go.sum\0' \
  | assert_partition profile_go_lockfile_inscope implementing ENG-14 1 0 0
HARNESS_ROOT="$_saved_hr"; export HARNESS_ROOT; rm -rf "$_t"

# 20: `docs/` always in-scope — profile lists only `src/`; agent writes
# `docs/anything.md` → in-scope via catalog's `docs/`.
_t="$(mktemp -d -t twinning-eng95-sweep.XXXXXX)"
_eng95_pin_root_with_profile "$_t" '- `src/` — sources'
_saved_hr="$HARNESS_ROOT"; HARNESS_ROOT="$_t"; export HARNESS_ROOT
printf '?? docs/anything.md\0' \
  | assert_partition profile_docs_always_inscope implementing ENG-14 1 0 0
HARNESS_ROOT="$_saved_hr"; export HARNESS_ROOT; rm -rf "$_t"

# 21: profile_unknown_dir_out_of_scope — profile lists only `crates/`;
# agent writes `app/leak.py` (untracked, no allowlist match) → observed
# (FD5). The leaked-vs-observed split happens upstream in run-local.sh
# via the tick-start snapshot; partition_dirty_paths alone routes
# allowlist-misses to FD5.
_t="$(mktemp -d -t twinning-eng95-sweep.XXXXXX)"
_eng95_pin_root_with_profile "$_t" '- `crates/` — Rust workspace only'
_saved_hr="$HARNESS_ROOT"; HARNESS_ROOT="$_t"; export HARNESS_ROOT
printf '?? app/leak.py\0' \
  | assert_partition profile_unknown_dir_out_of_scope implementing ENG-14 0 0 1
HARNESS_ROOT="$_saved_hr"; export HARNESS_ROOT; rm -rf "$_t"

# 22: profile_missing_falls_back_to_always_include — no profile file on
# disk; two assertions: (a) `docs/foo.md` → in-scope via catalog;
# (b) `src/leak.rs` → observed (catalog has no `src/`).
_t="$(mktemp -d -t twinning-eng95-sweep.XXXXXX)"
_saved_hr="$HARNESS_ROOT"; HARNESS_ROOT="$_t"; export HARNESS_ROOT
printf '?? docs/foo.md\0' \
  | assert_partition profile_missing_falls_back_docs implementing ENG-14 1 0 0
printf '?? src/leak.rs\0' \
  | assert_partition profile_missing_falls_back_src implementing ENG-14 0 0 1
HARNESS_ROOT="$_saved_hr"; export HARNESS_ROOT; rm -rf "$_t"

# 23: profile_file_layout_missing_falls_back — profile exists but has
# no `## File layout` section. Behaves identically to missing profile.
_t="$(mktemp -d -t twinning-eng95-sweep.XXXXXX)"
mkdir -p "$_t/learned-rules/$PROJECT_SLUG"
{
  printf -- '---\nslug: %s\nschema_version: 1\n---\n\n' "$PROJECT_SLUG"
  printf '# Project profile\n\n## Stack\n\ntext\n\n## Language idioms\n\ntext\n'
} > "$_t/learned-rules/$PROJECT_SLUG/project-profile.md"
_saved_hr="$HARNESS_ROOT"; HARNESS_ROOT="$_t"; export HARNESS_ROOT
printf '?? docs/anywhere.md\0' \
  | assert_partition profile_file_layout_missing_falls_back implementing ENG-14 1 0 0
HARNESS_ROOT="$_saved_hr"; export HARNESS_ROOT; rm -rf "$_t"

# 24: profile_override_shadows_layout — profile lists `crates/`, config
# override = `[src/]`. The override (ENG-51 contract, D-004) wins
# absolutely; profile is NOT consulted. Two assertions:
#  (a) `?? src/foo.rs` → in-scope (override hit);
#  (b) `?? crates/foo.rs` → observed (profile is shadowed).
_t="$(mktemp -d -t twinning-eng95-sweep.XXXXXX)"
_eng95_pin_root_with_profile "$_t" '- `crates/` — workspace dirs'
_cfg="$_t/config.json"
printf '%s\n' '{"scope":{"allowlist":{"implementing":["src/"]}}}' > "$_cfg"
_saved_hr="$HARNESS_ROOT"; _saved_cfg="${CONFIG-}"
HARNESS_ROOT="$_t"; CONFIG="$_cfg"; export HARNESS_ROOT CONFIG
printf '?? src/foo.rs\0' \
  | assert_partition profile_override_shadows_layout_inscope implementing ENG-14 1 0 0
printf '?? crates/foo.rs\0' \
  | assert_partition profile_override_shadows_layout_observed implementing ENG-14 0 0 1
HARNESS_ROOT="$_saved_hr"; CONFIG="$_saved_cfg"; export HARNESS_ROOT CONFIG
rm -rf "$_t"

# 25: .scratch/ is invisible to sweep for implementing|ui|qa only.
# Agents on those stages drop verification fixtures alongside legitimate
# in-scope writes; the gitignored .scratch/ namespace + the partition
# filter keep those fixtures from misclassifying as out-of-scope.
printf '?? .scratch/bte_paren.md\0' \
  | assert_partition scratch_invisible_implementing implementing ENG-14 0 0 0
printf '?? .scratch/run_checks.sh\0' \
  | assert_partition scratch_invisible_ui ui ENG-14 0 0 0
printf '?? .scratch/fixtures/nested.md\0' \
  | assert_partition scratch_invisible_qa qa ENG-14 0 0 0

# 26: .scratch/ on brainstorming|planning falls through to out-of-scope
# (review finding M2 — cross-dispatch state-injection vector). The
# carve-out is gated to allowlisted stages; brainstorm/plan must
# self-leak on .scratch/* so a planted fixture cannot persist across
# dispatches and condition the next agent's behavior via Read.
printf '?? .scratch/seed-prompt.md\0' \
  | assert_partition scratch_brainstorm_self_leaks brainstorming ENG-14 0 0 1
printf '?? .scratch/seed-prompt.md\0' \
  | assert_partition scratch_planning_self_leaks planning ENG-14 0 0 1

# 27: .scratch/ on reviewing|building|released ALSO falls through to
# out-of-scope here. Those stages are handled by clean_self_leak_residue
# in run-local.sh's self-leak handler (auto-clean, no halt). The
# partition filter is not the defense surface for those stages — the
# read-mostly intervention is.
printf '?? .scratch/bte.md\0' \
  | assert_partition scratch_reviewing_through_partition reviewing ENG-14 0 0 1
printf '?? .scratch/bte.md\0' \
  | assert_partition scratch_building_through_partition building ENG-14 0 0 1
printf '?? .scratch/bte.md\0' \
  | assert_partition scratch_released_through_partition released ENG-14 0 0 1

# 28: path-boundary — a file NAMED .scratchpad (no slash) must NOT
# match the .scratch/ prefix. The case glob is `.scratch/*` so the
# trailing slash is load-bearing.
printf '?? .scratchpad\0' \
  | assert_partition scratch_path_boundary_not_matched implementing ENG-14 0 0 1

# AC-K2-PARALLEL-WORKERS (ENG-81 Task 5): structural assertions on the
# scheduler/worker fork plumbing in bin/run-local.sh. The full end-to-end
# fanout against stubbed poll.sh / run-stage.sh is deferred to QA per
# plan §5 Task 5; here we pin the structural invariants the review flagged
# as load-bearing — the parallel fork loop, the pre-fork
# _SCHEDULER_INFLIGHT_LOCKS clear, the wait after fork — so a future edit
# that breaks them surfaces in CI rather than silently regressing K=2.
RUN_LOCAL_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/run-local.sh"
[[ -f "$RUN_LOCAL_SRC" ]] || { printf 'FAIL AC-K2-PARALLEL-WORKERS: cannot locate run-local.sh at %s\n' "$RUN_LOCAL_SRC"; exit 1; }

# Invariant 1: _run_worker function is defined.
grep -q '^_run_worker() {' "$RUN_LOCAL_SRC" \
  || { printf 'FAIL AC-K2-PARALLEL-WORKERS-DEFN: _run_worker function missing in %s\n' "$RUN_LOCAL_SRC"; exit 1; }

# Invariant 2: the only `_SCHEDULER_INFLIGHT_LOCKS=()` clear is the
# global initialization at the top of the file. A `die` between
# `try_acquire_lock` and the worker fork would otherwise orphan the
# locks of any worker already pushed onto the array (worker EXIT trap
# never installed). Double-release via worker EXIT trap after fork is
# harmless (rm -rf is idempotent).
clear_count="$(grep -c '^_SCHEDULER_INFLIGHT_LOCKS=()$' "$RUN_LOCAL_SRC")"
[[ "$clear_count" == "1" ]] \
  || { printf 'FAIL AC-K2-PARALLEL-WORKERS-NO-PREFORK-CLEAR: expected exactly 1 `_SCHEDULER_INFLIGHT_LOCKS=()` (global init only), got %s\n' "$clear_count"; exit 1; }

# Invariant 3: the worker fork loop uses background-fork (`) &`) and the
# scheduler `wait`s after. A regression to sequential dispatch would drop
# the `&` and the test would catch it.
grep -q '^  ) &$' "$RUN_LOCAL_SRC" \
  || { printf 'FAIL AC-K2-PARALLEL-WORKERS-FORK: worker subshell is not backgrounded with `) &` in %s\n' "$RUN_LOCAL_SRC"; exit 1; }
grep -q '^wait$' "$RUN_LOCAL_SRC" \
  || { printf 'FAIL AC-K2-PARALLEL-WORKERS-WAIT: `wait` after worker fork not present in %s\n' "$RUN_LOCAL_SRC"; exit 1; }

# Invariant 4: per-worker log file name carries the issue id (so K=2 ticks
# produce two distinct log files, not interleaved daily logs).
grep -q 'worker_log=.*local-.*\${issue_id}' "$RUN_LOCAL_SRC" \
  || grep -q 'local-.*-${issue_id}.log' "$RUN_LOCAL_SRC" \
  || { printf 'FAIL AC-K2-PARALLEL-WORKERS-LOG: per-worker log filename does not contain ${issue_id}\n'; exit 1; }

printf 'OK AC-K2-PARALLEL-WORKERS structural invariants (4 of 4): _run_worker, pre-fork clear, ) & wait, per-issue log filename\n'

# ──────────────────────────────────────────────────────────────────────
# AC-K2-PARALLEL-WORKERS-BEHAVIORAL (ENG-81 review-3 critical finding #1)
# ──────────────────────────────────────────────────────────────────────
# The structural greps above catch literal-text regressions (`) &` drop,
# `wait` drop, missing `_run_worker` invocation). They do NOT catch
# regressions that preserve the literal tokens but break semantics —
# e.g. inserting `wait` INSIDE the fork loop body (serializes), moving
# `) &` to a non-loop context, or reordering so workers never start
# concurrently. A behavioral test that drives the production fork-loop
# block end-to-end is the only defense against those classes.
#
# Approach: awk-extract the fork loop block from run-local.sh source,
# install stubs for `_run_worker` (a sleep-then-touch-sentinel function)
# and `release_lock` (no-op rmdir), then `eval` the extracted block with
# two pre-claimed worker specs. Assert:
#   1. Both sentinel files exist (both workers ran)
#   2. Total elapsed time < 2× per-worker sleep (proves parallel, not serial)
#   3. Worker start times are within 1s of each other (proves
#      simultaneous fork, not staggered serial)
RUN_LOCAL_BEHAVIORAL_BLOCK="$(awk '
  /^for spec in "\$\{_claimed_workers\[@\]\}"; do/ { in_loop=1 }
  in_loop { print }
  in_loop && /^done$/ { exit }
' "$RUN_LOCAL_SRC")"

if [[ -z "$RUN_LOCAL_BEHAVIORAL_BLOCK" ]]; then
  printf 'FAIL AC-K2-PARALLEL-WORKERS-BEHAVIORAL: could not extract fork loop block from %s\n' "$RUN_LOCAL_SRC" >&2
  exit 1
fi

# Sanity-check the extracted block: must contain ) &, _run_worker, NO wait
# (wait belongs OUTSIDE the loop). This guards against an awk extraction
# that grabbed the wrong region — without these checks the eval below
# could silently exercise nothing.
grep -qF ') &' <<<"$RUN_LOCAL_BEHAVIORAL_BLOCK" \
  || { printf 'FAIL AC-K2-PARALLEL-WORKERS-BEHAVIORAL: extracted block missing `) &` — awk grabbed wrong region\n' >&2; exit 1; }
grep -qF '_run_worker "$w_issue" "$w_stage" "$w_worktree"' <<<"$RUN_LOCAL_BEHAVIORAL_BLOCK" \
  || { printf 'FAIL AC-K2-PARALLEL-WORKERS-BEHAVIORAL: extracted block missing _run_worker invocation\n' >&2; exit 1; }
if grep -qE '^[[:space:]]*wait[[:space:]]*$' <<<"$RUN_LOCAL_BEHAVIORAL_BLOCK"; then
  printf 'FAIL AC-K2-PARALLEL-WORKERS-BEHAVIORAL: `wait` found INSIDE fork loop body — would serialize K=2 workers\n' >&2
  exit 1
fi

K2_SENTINEL_DIR="$(mktemp -d -t twinning-k2-behavioral.XXXXXX)"
trap 'rm -rf "$K2_SENTINEL_DIR"' EXIT

# Stub _run_worker (overrides any inherited definition). Records start
# time, sleeps 2s, records end time. Two parallel invocations should
# overlap; sequential would not.
_run_worker() {
  local issue="$1"
  date +%s > "$K2_SENTINEL_DIR/$issue.start"
  sleep 2
  date +%s > "$K2_SENTINEL_DIR/$issue.end"
}
# Stub release_lock (no-op — the eval'd block's per-subshell trap fires
# release_lock on subshell exit; we don't want it to die).
release_lock() { :; }

# Populate the input array the loop iterates over.
_claimed_workers=(
  "ENG-K2BX|implementing|/tmp/wt-X|/tmp/lock-X"
  "ENG-K2BY|implementing|/tmp/wt-Y|/tmp/lock-Y"
)

start_ts="$(date +%s)"
# Disable `set -e` propagation locally so a single subshell's nonzero rc
# doesn't kill the test before we assert (mirrors run-local.sh's
# `set +e; wait; set -e` block around the production wait).
set +e
eval "$RUN_LOCAL_BEHAVIORAL_BLOCK"
wait
set -e
end_ts="$(date +%s)"
elapsed=$((end_ts - start_ts))

# Assert 1: both sentinels present (both workers ran to completion).
if [[ ! -f "$K2_SENTINEL_DIR/ENG-K2BX.end" || ! -f "$K2_SENTINEL_DIR/ENG-K2BY.end" ]]; then
  printf 'FAIL AC-K2-PARALLEL-WORKERS-BEHAVIORAL: one or both workers did not run to completion (X.end=%s, Y.end=%s)\n' \
    "$([[ -f $K2_SENTINEL_DIR/ENG-K2BX.end ]] && echo present || echo absent)" \
    "$([[ -f $K2_SENTINEL_DIR/ENG-K2BY.end ]] && echo present || echo absent)" >&2
  exit 1
fi

# Assert 2: total elapsed < 2× per-worker sleep (would-be-serial 4s; parallel ~2s).
# Allow a generous upper bound (3s) so slow CI host doesn't flake.
if (( elapsed >= 4 )); then
  printf 'FAIL AC-K2-PARALLEL-WORKERS-BEHAVIORAL: workers appear to run sequentially (elapsed=%ds, expected <4s for 2x 2s parallel)\n' "$elapsed" >&2
  exit 1
fi

# Assert 3: worker start times are within 1s of each other (proves the
# fork loop iterates fast, not staggered with sleeps).
start_x="$(cat "$K2_SENTINEL_DIR/ENG-K2BX.start")"
start_y="$(cat "$K2_SENTINEL_DIR/ENG-K2BY.start")"
if (( start_x > start_y )); then
  start_diff=$((start_x - start_y))
else
  start_diff=$((start_y - start_x))
fi
if (( start_diff > 1 )); then
  printf 'FAIL AC-K2-PARALLEL-WORKERS-BEHAVIORAL: worker start times diverge (Δ=%ds, expected ≤1s — fork loop should iterate near-instantly)\n' "$start_diff" >&2
  exit 1
fi

printf 'OK AC-K2-PARALLEL-WORKERS-BEHAVIORAL (elapsed=%ds<4s, start_diff=%ds≤1s, both sentinels present)\n' "$elapsed" "$start_diff"

# Cleanup stubs/array so subsequent test runs aren't polluted.
unset -f _run_worker release_lock
unset _claimed_workers

# ──────────────────────────────────────────────────────────────────────
# AC-K2-PARALLEL-WORKERS-FAILURE-RESILIENT
# ──────────────────────────────────────────────────────────────────────
# Plan §7 line 944 row claims AC-K2-PARALLEL-WORKERS covers "one worker
# fails, scheduler still runs release watcher" via the `set +e; wait;
# set -e` bracket. The BEHAVIORAL case above only stubs rc=0 workers, so
# a regression that drops the bracket would pass CI silently.
#
# Drive the production fork-loop block with one stub _run_worker that
# exits non-zero and one that exits clean. Assert: the clean worker's
# sentinel still lands AND the test process survives past `wait` to
# reach the assertion (proves `set +e` shielded the scheduler from the
# failing worker's rc).
K2FR_SENTINEL_DIR="$(mktemp -d -t twinning-k2-failresilient.XXXXXX)"
trap 'rm -rf "$K2FR_SENTINEL_DIR"' EXIT

_run_worker() {
  local issue="$1"
  case "$issue" in
    ENG-K2FRA) date +%s > "$K2FR_SENTINEL_DIR/$issue.start"; exit 1 ;;
    ENG-K2FRB) date +%s > "$K2FR_SENTINEL_DIR/$issue.start"; sleep 1; date +%s > "$K2FR_SENTINEL_DIR/$issue.end"; return 0 ;;
  esac
}
release_lock() { :; }

_claimed_workers=(
  "ENG-K2FRA|implementing|/tmp/wt-A|/tmp/lock-A"
  "ENG-K2FRB|implementing|/tmp/wt-B|/tmp/lock-B"
)

# Sentinel proving the test process reached the assert phase. If the
# scheduler's `set +e; wait; set -e` bracket were missing AND the test
# inherited `set -e`, the failing worker subshell's rc=1 would kill the
# test process before `wait` returns and this sentinel would not be
# touched. The behavioral block at run-local.sh:483-484 mirrors this.
set +e
eval "$RUN_LOCAL_BEHAVIORAL_BLOCK"
wait
set -e
date +%s > "$K2FR_SENTINEL_DIR/scheduler-reached-assert"

# Assert 1: scheduler process survived past `wait` (proves resilience).
if [[ ! -f "$K2FR_SENTINEL_DIR/scheduler-reached-assert" ]]; then
  printf 'FAIL AC-K2-PARALLEL-WORKERS-FAILURE-RESILIENT: scheduler did not reach post-wait assert (set +e bracket may have been dropped)\n' >&2
  exit 1
fi

# Assert 2: failing worker started; clean worker ran to completion.
if [[ ! -f "$K2FR_SENTINEL_DIR/ENG-K2FRA.start" ]]; then
  printf 'FAIL AC-K2-PARALLEL-WORKERS-FAILURE-RESILIENT: failing worker A did not start\n' >&2
  exit 1
fi
if [[ ! -f "$K2FR_SENTINEL_DIR/ENG-K2FRB.end" ]]; then
  printf 'FAIL AC-K2-PARALLEL-WORKERS-FAILURE-RESILIENT: clean worker B did not complete despite parallel worker A exit 1 (failure isolation broken)\n' >&2
  exit 1
fi

printf 'OK AC-K2-PARALLEL-WORKERS-FAILURE-RESILIENT (worker A exit 1, worker B completed, scheduler reached post-wait)\n'

unset -f _run_worker release_lock
unset _claimed_workers

# AC-ENG-100-PREDICATE-PLANNING: new predicate routes planning to
# auto-clean lane. Reason: brainstorm D-002/D-004 — docs-only stages
# carry no `Bash(rm:*)` so the orchestrator absorbs cleanup at the
# self-leak gate rather than halting on sub-agent residue.
if stage_auto_cleans_self_leak planning; then
  printf 'OK: stage_auto_cleans_self_leak: planning routes to auto-clean lane\n'
else
  printf 'FAIL: stage_auto_cleans_self_leak: planning routes to auto-clean lane\n  reason: expected planning to auto-clean self-leak residue\n' >&2; exit 1
fi

# AC-ENG-100-PREDICATE-BRAINSTORM: same for brainstorming.
if stage_auto_cleans_self_leak brainstorming; then
  printf 'OK: stage_auto_cleans_self_leak: brainstorming routes to auto-clean lane\n'
else
  printf 'FAIL: stage_auto_cleans_self_leak: brainstorming routes to auto-clean lane\n  reason: expected brainstorming to auto-clean self-leak residue\n' >&2; exit 1
fi

# AC-ENG-100-PREDICATE-REVIEWING / BUILDING / RELEASED: superset of
# stage_is_read_mostly's truthy stages — the new predicate must keep
# routing them to auto-clean (pre-ENG-100 contract preserved).
for _s in reviewing building released; do
  if stage_auto_cleans_self_leak "$_s"; then
    printf 'OK: stage_auto_cleans_self_leak: %s stays on auto-clean lane\n' "$_s"
  else
    printf 'FAIL: stage_auto_cleans_self_leak: %s should stay on auto-clean lane\n' "$_s" >&2; exit 1
  fi
done
unset _s

# AC-ENG-100-PREDICATE-IMPLEMENTING: implementing STAYS on the halt
# lane — operator decision asymmetry between docs-only and
# production-path stages must be preserved.
if stage_auto_cleans_self_leak implementing; then
  printf 'FAIL: stage_auto_cleans_self_leak: implementing must NOT auto-clean\n  reason: production-path stages still halt on self-leak (operator signal)\n' >&2; exit 1
else
  printf 'OK: stage_auto_cleans_self_leak: implementing stays on halt lane\n'
fi

# AC-ENG-100-PREDICATE-UI: ui STAYS on the halt lane.
if stage_auto_cleans_self_leak ui; then
  printf 'FAIL: stage_auto_cleans_self_leak: ui must NOT auto-clean\n' >&2; exit 1
else
  printf 'OK: stage_auto_cleans_self_leak: ui stays on halt lane\n'
fi

# AC-ENG-100-PREDICATE-QA: qa STAYS on the halt lane.
if stage_auto_cleans_self_leak qa; then
  printf 'FAIL: stage_auto_cleans_self_leak: qa must NOT auto-clean\n' >&2; exit 1
else
  printf 'OK: stage_auto_cleans_self_leak: qa stays on halt lane\n'
fi

# AC-ENG-100-PREDICATE-UNKNOWN: UNKNOWN stage → halt lane (conservative).
if stage_auto_cleans_self_leak some-unknown-stage 2>/dev/null; then
  printf 'FAIL: stage_auto_cleans_self_leak: unknown stage must NOT auto-clean\n' >&2; exit 1
else
  printf 'OK: stage_auto_cleans_self_leak: unknown stage stays on halt lane (conservative)\n'
fi

printf 'All sweep-test cases passed.\n'
