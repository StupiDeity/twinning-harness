---
linear: ENG-69
date: 2026-05-07
topic: per-issue halt vs. harness-wide pause; right-size the circuit breaker
---

# Plan — ENG-69 per-issue halt vs. harness-wide pause

Implementation plan for the design in
`docs/brainstorms/2026-05-07-eng-69-self-leak-and-per-issue-agent-failures-should-not-trip-the-global-circuit-breaker-separate-per-issue-halt-from-harness-wide-pause-design.md`.

## Anti-anchoring

- **Problem (operator's words):** "self-leak and per-issue agent failures
  should not trip the global circuit breaker; separate per-issue halt from
  harness-wide pause." On 2026-05-05, ENG-63's reviewing-stage agent left a
  stray `.eng63-strip-test.in` (no `rm` in the reviewing tool sandbox);
  `run-local.sh`'s tick-end sweep classified the path as self-leak and
  unconditionally tripped the global `orchestrator.paused=true` breaker on
  first occurrence. ENG-64 and ENG-65, both `stage:implementing` with no
  per-issue halt, were silently blocked across 63 launchd ticks (~5 hours)
  until the operator manually `rm`'d the file and reset the breaker.
- **Does the brainstorm address it?** Yes — directly. Three structurally
  different failure classes today share one global counter and one global
  pause. The brainstorm splits them into three lanes: (a) self-leak and
  leaked-in-scope route through `classify_failure` against the affected
  issue (per-issue halt — the existing precedent at
  `bin/run-stage.sh:763-771` for `scope_check rc=3`); (b) run-stage rc≠0
  routes to a per-issue counter EXCEPT rc=24 (`linear-post-failed` — the
  one infrastructure exit that genuinely portends "the next dispatch on
  ANY issue will also fail"); (c) the global breaker stays for rc=24
  cross-issue accumulation at threshold 3. No reframing of the problem;
  the brainstorm's "right granularity" table maps 1:1 to the issue's
  acceptance-criteria table.
- **Proportional?** Yes. The change is mechanical: rewire three
  failure-routing inline blocks in `run-local.sh`, extract them to
  named functions in `run-local-helpers.sh` so the new tests can
  source-and-stub them (D-8), add two new exit codes (26, 27) to the
  existing `failure_outcome_for_exit` taxonomy in `bin/common.sh`, add
  one `rm -f` to the atomic-reset block in `bin/pipeline.sh`, append
  four test groups to the existing
  `bin/run-local-helpers-adversarial-test.sh`, and rewrite one row in
  CLAUDE.md. No new files except the optional pull-out is rejected
  (D-7 alternative). Net code delta: ~+90 LOC in helpers, ~-50 LOC in
  run-local.sh, ~+120 LOC in tests, ~+10 LOC across common.sh/pipeline.sh,
  ~+2 lines in CLAUDE.md.
- **No escalation needed.** No problem reframing; the proposed changes
  satisfy each of AC #1-#7 directly, and the brainstorm's persona round
  ended with "Personas: 6/6 PASS · gate P0: 0 · proceeding to planning."

## Goal

Self-leak, leaked-in-scope at threshold, and same-issue run-stage
failures at threshold halt only the affected issue (via
`classify_failure` with `skip-until-human-acts`) and leave
`orchestrator.paused` untouched, so other issues continue to be polled;
the global breaker fires only when `run-stage.sh` exits with `rc=24`
(`linear-post-failed`) on three consecutive ticks. Verifiable by:

1. `bash bin/run-local-helpers-adversarial-test.sh` passes its four new
   test groups in addition to the existing 30+ cases.
2. `bash bin/dispatch-test.sh && bash bin/run-stage-test.sh && bash
   bin/poll-slot-test.sh && bash bin/scope-check-test.sh && bash
   bin/verdict-handler-test.sh && bash bin/classify-failure-test.sh && bash
   bin/halt-sprawl-test.sh && bash bin/halt-sprawl-adversarial-test.sh && bash
   bin/linear-test.sh && bash bin/metrics-test.sh && bash bin/mutex-test.sh
   && bash bin/setup-helpers-test.sh && bash bin/render-prompt-test.sh && bash
   bin/phase-project-profile-test.sh && bash bin/common-test.sh` — all
   green (none of these test files exercise the rewired routing today).
3. `bash -n bin/run-local.sh bin/run-local-helpers.sh bin/common.sh
   bin/pipeline.sh` — all clean.

## Assumption Inventory

Every modified-file fact below is `path:line`-cited against the current
worktree. The brainstorm's §12 "Assumption inventory" already verified
28 facts in-line; this section tightens to the eight that the implement
agent will edit.

### Modified files — current state and call sites

- **A-001 — `bin/run-local.sh:32-33` defines the global counter file and threshold.**
  Verified at `bin/run-local.sh:32-33`:
  ```
  FAIL_COUNTER="$PROJECT_STATE_DIR/.consecutive-failures"
  FAIL_THRESHOLD=3
  ```
  The plan reuses both as-is (the global counter survives narrowed to
  rc=24 only; the threshold is shared by both lanes).

- **A-002 — `bin/run-local.sh:24-28` sources `common.sh` and `run-local-helpers.sh`; does NOT source `classify-failure.sh` today.**
  Verified at `bin/run-local.sh:24-28`:
  ```
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=common.sh
  source "$SCRIPT_DIR/common.sh"
  # shellcheck source=run-local-helpers.sh
  source "$SCRIPT_DIR/run-local-helpers.sh"
  ```
  The plan adds a `source "$SCRIPT_DIR/classify-failure.sh"` line after
  line 28 so D-1, D-2, D-3 can call `classify_failure` from the
  helpers (call sites are inside extracted functions in helpers, but
  helpers are sourced by run-local.sh first; `classify_failure` is
  exported by `bin/classify-failure.sh:159` so once sourced it is
  reachable from the helper functions too).

- **A-003 — `bin/run-local.sh:249-258` is the run-stage rc-handler; today it increments the global `FAIL_COUNTER` for any non-zero rc and trips the breaker at threshold.**
  Verified at `bin/run-local.sh:249-258`:
  ```
  if [[ $rc -ne 0 ]]; then
    count="$(cat "$FAIL_COUNTER" 2>/dev/null || echo 0)"
    count=$((count + 1))
    printf '%s\n' "$count" > "$FAIL_COUNTER"
    log "run-stage.sh exited $rc; consecutive failures = $count"
    if (( count >= FAIL_THRESHOLD )); then
      trip_breaker
    fi
    exit $rc
  fi
  rm -f "$FAIL_COUNTER"
  ```
  The plan replaces this block with `route_run_stage_exit "$issue_id"
  "$stage" "$rc"` (D-3, D-8). The `rm -f "$FAIL_COUNTER"` at line 260
  collapses into the new helper's `rc==0` arm, which clears BOTH
  counters (per-issue file as well as the global file) for
  symmetry. The caller still does `[[ $rc -ne 0 ]] && exit $rc` so
  existing exit semantics are preserved.

- **A-004 — `bin/run-local.sh:304-318` is the self-leak branch; today it calls `trip_breaker; exit 1`.**
  Verified at `bin/run-local.sh:304-318`:
  ```
  if (( ${#self_leak_hashes[@]} > 0 )); then
    leak_csv=""
    for h in "${self_leak_hashes[@]}"; do
      leak_csv="${leak_csv:+${leak_csv},}${h}"
    done
    bash "$SCRIPT_DIR/metrics.sh" sweep-self-leak-out-of-scope "$issue_id" "$stage" \
      "self-leak" 0 "count=${#self_leak_hashes[@]} hashes=${leak_csv}" \
      || log "metrics.sh sweep-self-leak-out-of-scope emission failed (non-blocking)"
    log "SELF-LEAK: ${#self_leak_hashes[@]} bot-introduced out-of-scope path(s); tripping breaker (in-scope paths NOT committed)"
    if [[ "$PIPELINE_DRY_RUN" != "1" ]]; then
      trip_breaker
      exit 1
    fi
  fi
  ```
  The plan replaces this block with `halt_issue_for_self_leak
  "$issue_id" "$stage" "${self_leak_hashes[@]}"` followed by `[[
  "$PIPELINE_DRY_RUN" != "1" ]] && exit 1` (D-1, D-8). The new helper
  emits the same `sweep-self-leak-out-of-scope` metric event (shape
  preserved for the retrospective's §1 filter) and then calls
  `classify_failure` instead of `trip_breaker`.

- **A-005 — `bin/run-local.sh:322-341` is the leaked-in-scope branch; today it increments the global `FAIL_COUNTER` and trips the breaker at threshold.**
  Verified at `bin/run-local.sh:322-341`:
  ```
  if (( leaked_count > 0 )); then
    leaked_hashes=""
    while IFS= read -r -d '' p; do
      h="$(sha12 "$p")"
      leaked_hashes="${leaked_hashes:+${leaked_hashes},}${h}"
    done < "$leaked_file"
    bash "$SCRIPT_DIR/metrics.sh" sweep-leaked-in-scope "$issue_id" "$stage" \
      "leak" 0 "count=${leaked_count} hashes=${leaked_hashes}" \
      || log "metrics.sh sweep-leaked-in-scope emission failed (non-blocking)"
    if [[ "$PIPELINE_DRY_RUN" != "1" ]]; then
      fc="$(cat "$FAIL_COUNTER" 2>/dev/null || echo 0)"
      fc=$((fc + 1))
      printf '%s\n' "$fc" > "$FAIL_COUNTER"
      log "sweep-leaked-in-scope: $leaked_count path(s); consecutive failures = $fc (in-scope paths NOT committed)"
      if (( fc >= FAIL_THRESHOLD )); then
        trip_breaker
      fi
      exit 1
    fi
  fi
  ```
  The plan replaces the inner `if [[ "$PIPELINE_DRY_RUN" != "1" ]]` block
  with `tally_leaked_in_scope_failure "$issue_id" "$stage"
  "$leaked_count" "$leaked_hashes"` (D-2, D-8). The
  `metrics.sh sweep-leaked-in-scope` call moves INTO the helper too so
  the dry-run early-return suppresses both the FS write and the metric
  side-effect uniformly (the original block had the metric call
  outside the dry-run guard, but a leaked-in-scope event cannot
  happen on a dry run anyway because `partition_dirty_paths` runs
  against the real `git status`; this is a no-op behavior change).

- **A-006 — `bin/run-local-helpers.sh:42-45` defines `trip_breaker`; the helpers file is a pure function library with no top-level side effects (it's sourced).**
  Verified at `bin/run-local-helpers.sh:42-45`:
  ```
  trip_breaker() {
    log "CIRCUIT BREAKER: setting orchestrator.paused=true after ${FAIL_THRESHOLD:-3} consecutive failures"
    set_orchestrator_paused true
  }
  ```
  And `bin/run-local-helpers.sh:1-5` (header: "Pure-function library
  for run-local.sh's sweep-partition logic. Defines functions only;
  no top-level side effects. Do NOT set `set -euo pipefail` here").
  The plan adds three new functions next to `trip_breaker`
  (`halt_issue_for_self_leak`, `tally_leaked_in_scope_failure`,
  `route_run_stage_exit`) per D-8.

- **A-007 — `bin/common.sh:107-129` is `failure_outcome_for_exit`; today it has cases for 0,10,11,12,13,14,20,21,22,24,25,124, falling through to `unknown-exit-N`.**
  Verified at `bin/common.sh:107-129` (full block read above). The
  plan inserts `26) printf 'self-leak' ;;` and `27) printf
  'leaked-in-scope-threshold' ;;` cases between the existing 25 and
  124 entries (D-5).

- **A-008 — `bin/classify-failure.sh:39-159::classify_failure` accepts `<issue> <stage> <base_policy> <reason> <exit_code> [<subcode>]` and is exported via `export -f classify_failure` at line 159.**
  Verified at `bin/classify-failure.sh:46`:
  ```
  local issue="$1" stage="$2" base_policy="$3" reason="$4" exit_code="$5" subcode="${6:-}"
  ```
  And `bin/classify-failure.sh:159`:
  ```
  export -f classify_failure
  ```
  Once `run-local.sh` sources `classify-failure.sh` (per A-002 edit),
  the function is callable from inside helpers because exported bash
  functions traverse function-call boundaries within the same
  process. (Verified by inspecting how `run-stage.sh` already does
  exactly this pattern: it sources `classify-failure.sh` at line 20
  and calls `classify_failure` from within helper-function-wrapped
  contexts at multiple sites including the scope-violation branch at
  line 769.)

- **A-009 — `bin/classify-failure.sh:121-146` posts a halt comment with marker `<!-- pipeline: verdict result=halt reason=agent-blocked -->` for `policy=skip-until-human-acts`, applies `pipeline:halted` and `pipeline:skip-until-human-acts` labels.**
  Verified at `bin/classify-failure.sh:111-114`:
  ```
  skip-until-human-acts)
    bash "$_CFS_SCRIPT_DIR/linear.sh" remove-label "$issue" "pipeline:skip-until-code-changes" 2>/dev/null || true
    bash "$_CFS_SCRIPT_DIR/linear.sh" add-label    "$issue" "pipeline:skip-until-human-acts" || true
    ;;
  ```
  At line 119: `bash "$_CFS_SCRIPT_DIR/linear.sh" add-label "$issue"
  "pipeline:halted" || true`. At line 127: `marker_reason="agent-blocked"`
  for `skip-until-human-acts` policy. The plan reuses these
  side-effects unchanged via the new helpers.

- **A-010 — `bin/pipeline.sh:268-276::_pipeline_clear_breaker` clears the global counter file via `rm -f "$PROJECT_STATE_DIR/.consecutive-failures"`.**
  Verified at `bin/pipeline.sh:268-276` (full block read above). The
  plan does NOT modify this helper (it stays focused on the global
  counter — that's its name). The per-issue `rm -f` is added in
  `cmd_decide` at the appropriate point (per D-4) so the
  responsibility split stays clean: `_pipeline_clear_breaker` =
  global state; `cmd_decide` = both global and per-issue state via
  composition.

- **A-011 — `bin/pipeline.sh:319-362::cmd_decide` runs the atomic-reset block on `action=continue` between issue-id validation (line 324) and the decision-comment post (line 364).**
  Verified at `bin/pipeline.sh:333-358`:
  ```
  local wf sl sf breaker_was autocommit_n
  wf="$(_pipeline_drain_wait_files "$issue")"
  sl="$(_pipeline_drain_skip_labels "$issue")"
  sf="$(_pipeline_drain_issue_state "$issue")"
  ...
  breaker_was="$(_pipeline_clear_breaker)"
  ...
  autocommit_n="$(auto_commit_in_scope "$issue" "$current_stage" || printf '0')"
  _pipeline_post_operator_transition "$issue" "$current_stage"
  _pipeline_emit_resume_metric "$issue" "$current_stage" "$wf" "$sl" "$sf" "1" "$breaker_was" "$autocommit_n"
  ```
  The plan adds one `rm -f "$(issue_dir "$issue")/.consecutive-failures"
  2>/dev/null || true` line between `_pipeline_clear_breaker` and
  `auto_commit_in_scope` (D-4). `issue_dir` is already in scope
  because `pipeline.sh` sources `common.sh` (verified at
  `bin/pipeline.sh:8-10`). No metric-shape change; the existing
  `_pipeline_emit_resume_metric` notes string already carries enough
  state for the retrospective.

- **A-012 — `bin/run-local-helpers-adversarial-test.sh:1-25` is the
  source-and-stub harness; lines 624-673 are the existing `trip_breaker`
  test cases the new tests will sit alongside.**
  Verified at `bin/run-local-helpers-adversarial-test.sh:23-25`
  (`source "$SCRIPT_DIR/common.sh"` then `source
  "$SCRIPT_DIR/run-local-helpers.sh"`) and at lines 624-673
  (`test_trip_breaker_overrides_state_local_false` +
  `test_trip_breaker_works_when_config_already_paused`). The new
  tests source the helpers the same way and stub `classify_failure`,
  `linear.sh`, and `metrics.sh` per D-7.

- **A-013 — `bin/common.sh:68-72::issue_dir` returns `$PROJECT_STATE_DIR/$issue`.**
  Verified at `bin/common.sh:68-72`:
  ```
  issue_dir() {
    local issue="$1"
    [[ -n "$issue" ]] || die "issue_dir: missing issue id"
    printf '%s/%s' "$PROJECT_STATE_DIR" "$issue"
  }
  ```
  Used unchanged in three places: D-1 helper, D-2 helper, D-3 helper,
  D-4 `cmd_decide` edit.

- **A-014 — `CLAUDE.md:386` is the existing "Breaker tripped" row in the
  Failure-mode quick reference table.**
  Verified at `CLAUDE.md:381-390`:
  ```
  ## Failure-mode quick reference
  | Symptom | Where to look |
  |---|---|
  | Tick is silent | ...
  | Breaker tripped | `$PROJECT_STATE_DIR/.consecutive-failures` ≥ 3 and `orchestrator.paused=true` in `STATE_FILE` or `CONFIG`; flip back via `set_orchestrator_paused false` (or `jq`) and the next successful tick clears the counter |
  ```
  The plan replaces this single row with two rows distinguishing
  per-issue halt from the (now narrowed) global breaker (D-6).

### Assumed/new artifacts

- **A-015 — Exit codes 26 (`self-leak`) and 27 (`leaked-in-scope-threshold`) do not exist today.**
  Verified at `bin/common.sh:107-129` (case statement enumerated;
  neither code present). Both are added to `failure_outcome_for_exit`
  in Task 5 and reused as the typed-outcome strings the
  retrospective's §1 filter recognises.

- **A-016 — `halt_issue_for_self_leak`, `tally_leaked_in_scope_failure`,
  `route_run_stage_exit` do not exist today.**
  Verified by `grep -n 'halt_issue_for_self_leak\|tally_leaked_in_scope_failure\|route_run_stage_exit' bin/*.sh` returns no matches.
  All three are added to `bin/run-local-helpers.sh` in Tasks 1, 2, 3.

- **A-017 — Per-issue counter file `$(issue_dir <issue>)/.consecutive-failures` does not exist today.**
  Verified by `ls -la $PROJECT_STATE_DIR/ENG-69/` (no
  `.consecutive-failures` file under any per-issue dir; the only
  global counter file is `$PROJECT_STATE_DIR/.consecutive-failures`).
  Created on demand by the new helpers' `mkdir -p "$(dirname …)"` +
  atomic write pattern.

All 17 assumptions verified against current code/repo state. Codebase-fact
verification per ENG-5 anti-pattern guard: every named function
(`trip_breaker`, `classify_failure`, `partition_dirty_paths`,
`failure_outcome_for_exit`, `_pipeline_clear_breaker`,
`_pipeline_drain_*`, `issue_dir`, `set_orchestrator_paused`,
`is_orchestrator_paused`, `compute_pipeline_content_hash`), file path,
line range, exit code, and metric event name in this plan has been
opened and confirmed in the current `bin/` tree.

## File Structure

| File | Status | Change |
|---|---|---|
| `bin/run-local.sh` | modified | source `classify-failure.sh`; replace inline rc-handler at L249-260 with `route_run_stage_exit` call; replace inline self-leak block at L304-318 with `halt_issue_for_self_leak` call; replace inline leaked-in-scope block at L322-341 with `tally_leaked_in_scope_failure` call |
| `bin/run-local-helpers.sh` | modified | add `halt_issue_for_self_leak`, `tally_leaked_in_scope_failure`, `route_run_stage_exit` (~+90 LOC; alongside existing `trip_breaker` at L42-45) |
| `bin/common.sh` | modified | add `26) printf 'self-leak' ;;` and `27) printf 'leaked-in-scope-threshold' ;;` cases to `failure_outcome_for_exit` between existing 25 and 124 entries |
| `bin/pipeline.sh` | modified | add `rm -f "$(issue_dir "$issue")/.consecutive-failures"` line in `cmd_decide`'s atomic-reset block, between `_pipeline_clear_breaker` and `auto_commit_in_scope` |
| `bin/run-local-helpers-adversarial-test.sh` | modified | append four new test groups (~+250 LOC) for the three new helpers + cross-issue isolation |
| `CLAUDE.md` | modified | replace the "Breaker tripped" row at L386 with two rows distinguishing per-issue halt from global breaker |

No other files change. No `AGENT_PROMPTS.md`, `dispatch.sh`,
`linear.sh`, `metrics.sh`, `learned-rules/`, or
`.pipeline-config/config.json` change. No new test file (D-7 rejected
the alternative). No new prompt section.

## API Contract

No new API surface. The harness has no FE↔BE handlers; this is a
shell-script-internal change. The existing internal contracts
preserved by this plan:

- `metrics.sh sweep-self-leak-out-of-scope` event shape unchanged
  (issue_id, stage, outcome=self-leak, duration_ms=0, notes
  containing `count=N hashes=…`).
- `metrics.sh sweep-leaked-in-scope` event shape unchanged.
- `metrics.sh stage-end` shape unchanged (emitted by
  `classify_failure` per A-008/A-009; the new exit codes 26/27 ride
  through `failure_outcome_for_exit` to populate `outcome=self-leak` /
  `outcome=leaked-in-scope-threshold`).
- Halt-comment marker shape unchanged: `<!-- pipeline: verdict
  result=halt reason=agent-blocked -->` (per
  `bin/classify-failure.sh:127-128`; the closed event vocabulary in
  `bin/pipeline-events.json` already accepts this marker).
- `pipeline.sh decide --action continue` external contract unchanged
  from the operator's perspective; one additional file is `rm -f`'d as
  part of the existing "atomic, idempotent reset" promise.

## Backend Tasks

**Concurrency note.** Tasks 1, 2, 3 each *append* a new function to
`bin/run-local-helpers.sh` (alongside the existing `trip_breaker` at
L42-45). None of them edit existing code; therefore the order of
application is irrelevant — whichever task's edit lands last simply
appends at the current end-of-file. An implementation agent applying
them concurrently sees no merge conflict.

### Task 1: Add `halt_issue_for_self_leak` to `run-local-helpers.sh`

- `depends_on: []`
- `touches: bin/run-local-helpers.sh::halt_issue_for_self_leak`
- [ ] Append a new function `halt_issue_for_self_leak` to
      `bin/run-local-helpers.sh` after `trip_breaker` (currently
      L42-45). The function takes `<issue> <stage> <hash1> [<hash2> ...]`
      and:
      1. Validates `issue` matches `^ENG-[0-9]+$` (security P1-2 in
         brainstorm §9 iter-1).
      2. Emits the existing `sweep-self-leak-out-of-scope` metric
         (preserves retrospective's §1 filter shape).
      3. Logs the halt with leak count.
      4. Skips `classify_failure` under `PIPELINE_DRY_RUN=1`.
      5. Renders a hash-only halt-reason string truncated at 5 hashes
         with `(and N more)` suffix (max 5 per AC #1; security
         P1-1 — no raw paths flow into the comment body via the reason).
      6. Calls `classify_failure "$issue" "$stage"
         "skip-until-human-acts" "$reason_string" 26` — exit code 26
         is the new `self-leak` outcome from Task 5.
      Concrete body:
      ```bash
      # halt_issue_for_self_leak <issue> <stage> <hash1> [<hash2> ...]
      # Halts a single issue for self-leak via classify_failure with
      # skip-until-human-acts policy. Does NOT trip the global breaker.
      # The reason string carries ONLY sha12 hashes (max 5, with "(and N
      # more)" suffix when count > 5) — no raw paths flow into the halt
      # comment body via this entrypoint.
      halt_issue_for_self_leak() {
        local issue="$1" stage="$2"
        shift 2
        [[ "$issue" =~ ^ENG-[0-9]+$ ]] \
          || die "halt_issue_for_self_leak: invalid issue id '$issue'"
        local hashes=("$@") count=$#
        local leak_csv="" h
        for h in "${hashes[@]}"; do
          leak_csv="${leak_csv:+${leak_csv},}${h}"
        done
        bash "$SCRIPT_DIR/metrics.sh" sweep-self-leak-out-of-scope "$issue" "$stage" \
          "self-leak" 0 "count=${count} hashes=${leak_csv}" \
          || log "metrics.sh sweep-self-leak-out-of-scope emission failed (non-blocking)"
        log "SELF-LEAK: ${count} bot-introduced out-of-scope path(s) on $issue; halting issue (in-scope paths NOT committed)"
        [[ "${PIPELINE_DRY_RUN:-}" == "1" ]] && return 0
        local hash_lines="" h_count=0
        for h in "${hashes[@]}"; do
          (( h_count >= 5 )) && break
          hash_lines="${hash_lines}${hash_lines:+, }${h}"
          h_count=$((h_count + 1))
        done
        local suffix=""
        (( count > 5 )) && suffix=" (and $((count - 5)) more)"
        classify_failure "$issue" "$stage" "skip-until-human-acts" \
          "self-leak: ${count} bot-introduced out-of-scope path(s); leaked hashes: ${hash_lines}${suffix}" \
          26
      }
      ```
- [ ] Confirm the helpers file still has no top-level side effects
      (no new `set -euo pipefail`, no new file I/O at top level — the
      header at `bin/run-local-helpers.sh:1-5` forbids both).

### Task 2: Add `tally_leaked_in_scope_failure` to `run-local-helpers.sh`

- `depends_on: []`
- `touches: bin/run-local-helpers.sh::tally_leaked_in_scope_failure`
- [ ] Append the function next to `halt_issue_for_self_leak`. Takes
      `<issue> <stage> <leaked_count> <leaked_hashes_csv>`. Behavior:
      1. Validates `issue` matches `^ENG-[0-9]+$`.
      2. Emits the existing `sweep-leaked-in-scope` metric (move the
         call IN from `run-local.sh` so the dry-run guard suppresses
         it uniformly with the FS write).
      3. Skips FS write under `PIPELINE_DRY_RUN=1`.
      4. Reads `$(issue_dir "$issue")/.consecutive-failures`,
         increments via integer-sanitized
         `pic="${pic//[^0-9]/}"; pic="${pic:-0}"` (security P1-3
         counter-file integrity), writes atomically (tmp + `mv -f`).
      5. At threshold `>= FAIL_THRESHOLD` (3), calls
         `classify_failure "$issue" "$stage" "skip-until-human-acts"
         "<reason>" 27` — exit code 27 is the new
         `leaked-in-scope-threshold` outcome from Task 5.
      Concrete body:
      ```bash
      # tally_leaked_in_scope_failure <issue> <stage> <leaked_count> <leaked_hashes_csv>
      # Increments the per-issue consecutive-failures counter at
      # $(issue_dir <issue>)/.consecutive-failures and escalates to a
      # skip-until-human-acts halt at threshold. Does NOT touch the global
      # counter or trip the breaker.
      tally_leaked_in_scope_failure() {
        local issue="$1" stage="$2" leaked_count="$3" leaked_hashes="$4"
        [[ "$issue" =~ ^ENG-[0-9]+$ ]] \
          || die "tally_leaked_in_scope_failure: invalid issue id '$issue'"
        bash "$SCRIPT_DIR/metrics.sh" sweep-leaked-in-scope "$issue" "$stage" \
          "leak" 0 "count=${leaked_count} hashes=${leaked_hashes}" \
          || log "metrics.sh sweep-leaked-in-scope emission failed (non-blocking)"
        [[ "${PIPELINE_DRY_RUN:-}" == "1" ]] && return 0
        local pic_file pic
        pic_file="$(issue_dir "$issue")/.consecutive-failures"
        mkdir -p "$(dirname "$pic_file")"
        pic="$(cat "$pic_file" 2>/dev/null || printf '0')"
        pic="${pic//[^0-9]/}"; pic="${pic:-0}"
        pic=$((pic + 1))
        printf '%s\n' "$pic" > "${pic_file}.tmp.$$"
        mv -f "${pic_file}.tmp.$$" "$pic_file"
        log "sweep-leaked-in-scope: ${leaked_count} path(s) on $issue; per-issue consecutive failures = $pic (in-scope paths NOT committed)"
        if (( pic >= FAIL_THRESHOLD )); then
          classify_failure "$issue" "$stage" "skip-until-human-acts" \
            "leaked-in-scope at threshold: ${pic} consecutive failures (last leak: ${leaked_count} path(s))" \
            27
        fi
      }
      ```

### Task 3: Add `route_run_stage_exit` to `run-local-helpers.sh`

- `depends_on: []`
- `touches: bin/run-local-helpers.sh::route_run_stage_exit`
- [ ] Append the function. Takes `<issue> <stage> <rc>`. Behavior:
      1. Validates `issue` matches `^ENG-[0-9]+$`.
      2. `rc==0`: clears BOTH counters (`rm -f "$FAIL_COUNTER"` and
         `rm -f "$(issue_dir <issue>)/.consecutive-failures"`).
         Returns 0.
      3. `rc==24` (linear-post-failed): increments the global counter
         atomically; calls `trip_breaker` at threshold. Stays in the
         global lane because Linear API outage will fail the next
         dispatch on ANY issue.
      4. `rc==*` (any other non-zero): increments the per-issue counter
         atomically; calls `classify_failure "$issue" "$stage"
         "skip-until-human-acts" "<reason>" "$rc"` at threshold (rc is
         passed through unchanged so the existing taxonomy entries —
         e.g. 21=scope-violation, 124=dispatch-timeout — flow into the
         retrospective). Note: classify_failure has typically ALREADY
         been called from inside `run-stage.sh` for this rc; this is
         the soft-tally for cumulative same-issue escalation.
      Concrete body:
      ```bash
      # route_run_stage_exit <issue> <stage> <rc>
      # Routes a run-stage exit to the appropriate counter lane:
      #   rc==0  → clear both global and per-issue counters; return 0.
      #   rc==24 → global counter += 1; trip breaker at threshold.
      #   else   → per-issue counter += 1; classify_failure halt at threshold.
      # Returns 0 in all cases; caller still does `exit $rc` for non-zero rc.
      route_run_stage_exit() {
        local issue="$1" stage="$2" rc="$3"
        [[ "$issue" =~ ^ENG-[0-9]+$ ]] \
          || die "route_run_stage_exit: invalid issue id '$issue'"
        local pic_file; pic_file="$(issue_dir "$issue")/.consecutive-failures"
        if (( rc == 0 )); then
          rm -f "$FAIL_COUNTER"
          rm -f "$pic_file"
          return 0
        fi
        case "$rc" in
          24)
            local count
            count="$(cat "$FAIL_COUNTER" 2>/dev/null || printf '0')"
            count="${count//[^0-9]/}"; count="${count:-0}"
            count=$((count + 1))
            mkdir -p "$(dirname "$FAIL_COUNTER")"
            printf '%s\n' "$count" > "${FAIL_COUNTER}.tmp.$$"
            mv -f "${FAIL_COUNTER}.tmp.$$" "$FAIL_COUNTER"
            log "run-stage.sh exited $rc (linear-post-failed; infrastructure); global consecutive failures = $count"
            if (( count >= FAIL_THRESHOLD )); then
              trip_breaker
            fi
            ;;
          *)
            mkdir -p "$(dirname "$pic_file")"
            local pic
            pic="$(cat "$pic_file" 2>/dev/null || printf '0')"
            pic="${pic//[^0-9]/}"; pic="${pic:-0}"
            pic=$((pic + 1))
            printf '%s\n' "$pic" > "${pic_file}.tmp.$$"
            mv -f "${pic_file}.tmp.$$" "$pic_file"
            log "run-stage.sh exited $rc on $issue; per-issue consecutive failures = $pic"
            if (( pic >= FAIL_THRESHOLD )); then
              classify_failure "$issue" "$stage" "skip-until-human-acts" \
                "exceeded ${FAIL_THRESHOLD} consecutive same-issue failures (last exit ${rc})" \
                "$rc"
            fi
            ;;
        esac
        return 0
      }
      ```

### Task 4: Wire the new helpers into `run-local.sh`

- `depends_on: [1, 2, 3]`
- `touches: bin/run-local.sh:24-28, bin/run-local.sh:249-260, bin/run-local.sh:304-318, bin/run-local.sh:322-341`
- [ ] Edit `bin/run-local.sh:24-28` — add `source
      "$SCRIPT_DIR/classify-failure.sh"` after the existing `source
      "$SCRIPT_DIR/run-local-helpers.sh"` line. The new line must
      come AFTER helpers (so helpers can later call the
      already-exported `classify_failure`) and is harmless if a future
      refactor sources classify-failure.sh from inside helpers
      instead. Concretely insert at L29:
      ```bash
      # shellcheck source=classify-failure.sh
      source "$SCRIPT_DIR/classify-failure.sh"
      ```
- [ ] Edit `bin/run-local.sh:249-260` — replace the inline rc-handler
      and clean-tick `rm -f "$FAIL_COUNTER"` with a single
      `route_run_stage_exit` call. The new block:
      ```bash
      route_run_stage_exit "$issue_id" "$stage" "$rc"
      [[ $rc -ne 0 ]] && exit $rc
      ```
      The clean-tick `rm -f "$FAIL_COUNTER"` at L260 collapses into
      `route_run_stage_exit`'s `rc==0` arm (which also clears the
      per-issue counter — beneficial: a clean tick on ENG-X resets
      ENG-X's per-issue counter, matching the "consecutive same-issue
      failures" semantic).
- [ ] Edit `bin/run-local.sh:304-318` — replace the inline self-leak
      block (the one that builds `leak_csv`, emits the metric, and
      conditionally calls `trip_breaker; exit 1`) with:
      ```bash
      if (( ${#self_leak_hashes[@]} > 0 )); then
        halt_issue_for_self_leak "$issue_id" "$stage" "${self_leak_hashes[@]}"
        [[ "$PIPELINE_DRY_RUN" != "1" ]] && exit 1
      fi
      ```
      The metric emission and log line move INTO
      `halt_issue_for_self_leak` (Task 1). The `leak_csv` local that
      run-local built is now built inside the helper.
- [ ] Edit `bin/run-local.sh:322-341` — replace the inline
      leaked-in-scope block (the one that builds `leaked_hashes`,
      emits the metric, and increments the global counter) with:
      ```bash
      if (( leaked_count > 0 )); then
        leaked_hashes=""
        while IFS= read -r -d '' p; do
          h="$(sha12 "$p")"
          leaked_hashes="${leaked_hashes:+${leaked_hashes},}${h}"
        done < "$leaked_file"
        tally_leaked_in_scope_failure "$issue_id" "$stage" "$leaked_count" "$leaked_hashes"
        [[ "$PIPELINE_DRY_RUN" != "1" ]] && exit 1
      fi
      ```
      The CSV-building loop stays in run-local.sh (it consumes the
      `$leaked_file` named pipe-output in the local context); the
      metric and counter logic move INTO the helper.
- [ ] `bash -n bin/run-local.sh` — verify clean parse.
- [ ] `bash -n bin/run-local-helpers.sh` — verify clean parse.

### Task 5: Add exit codes 26 and 27 to `failure_outcome_for_exit`

- `depends_on: []`
- `touches: bin/common.sh:107-129`
- [ ] Edit `bin/common.sh:107-129` — insert two new case arms
      between the existing `25)` and `124)` lines:
      ```bash
      26) printf 'self-leak' ;;
      27) printf 'leaked-in-scope-threshold' ;;
      ```
      Position immediately before the `124)` arm to preserve the
      ascending-numeric ordering pattern.
- [ ] Update the comment block at `bin/common.sh:96-106` —  append a
      sentence to the existing "Reconcile-human (run-local.sh) does
      NOT call this helper" paragraph noting that "self-leak (exit
      26) and leaked-in-scope-threshold (exit 27) are emitted by
      `classify_failure` calls from run-local.sh's tick-end sweep,
      not from run-stage.sh."
- [ ] `bash -n bin/common.sh` — verify clean parse.

### Task 6: Add per-issue counter clear to `pipeline.sh decide --action continue`

- `depends_on: []`
- `touches: bin/pipeline.sh::cmd_decide`
- [ ] Edit `bin/pipeline.sh:319-362::cmd_decide` — between
      `breaker_was="$(_pipeline_clear_breaker)"` (L348) and
      `autocommit_n="$(auto_commit_in_scope ...)"` (L354), insert:
      ```bash
      # ENG-69: clear the per-issue consecutive-failures counter, sibling of
      # the global counter cleared by _pipeline_clear_breaker. Idempotent:
      # rm -f shrugs at missing files.
      rm -f "$(issue_dir "$issue")/.consecutive-failures" 2>/dev/null || true
      ```
      `issue_dir` is already in scope (sourced via `common.sh` at
      `bin/pipeline.sh:8-10`); `$issue` is already validated against
      `^ENG-[0-9]+$` at L324-325 so this is safe.
- [ ] Update the `log` line at `bin/pipeline.sh:358` — append `
      per_issue_counter_cleared=true` (literal — the `rm -f` is
      unconditional, so the boolean is constant). Optional, recommended
      for symmetry with the existing audit fields.
- [ ] `bash -n bin/pipeline.sh` — verify clean parse.

### Task 7: Append the four test groups to `run-local-helpers-adversarial-test.sh`

- `depends_on: [1, 2, 3, 5]`
- `touches: bin/run-local-helpers-adversarial-test.sh`
- [ ] Append a new section titled `# ─── ENG-69: per-issue halt vs.
      global breaker ────────────` before the `printf 'adversarial
      summary: ...'` block at line 802. The section:
      1. Sets up shared stubs in `STUB_DIR`: a fake
         `classify_failure` function (replaces the real one for these
         tests; logs `issue=$1 stage=$2 policy=$3 reason=$4 exit_code=$5`
         to a capture file), a stub `linear.sh` and `metrics.sh`
         (both no-op writes to `STUB_DIR/<event>.log`), and a fake
         `set_orchestrator_paused` reading/writing a fake STATE_FILE
         under a per-test `mktemp -d`.
      2. Runs each test in a subshell (`( ... )`) so `set -e` exits
         from helper assertion failures don't kill the harness.
      3. Sources the new helpers via `source
         "$SCRIPT_DIR/run-local-helpers.sh"` (already done at the
         top of the file; a second `source` is a no-op).
      4. Each test starts by re-creating
         `$PROJECT_STATE_DIR=$(mktemp -d)` so per-issue counter
         files can be inspected without bleed.
- [ ] `test_halt_issue_for_self_leak_per_issue_routes_correctly` — D-7 #1.
      Stubs `classify_failure` as a capture, `metrics.sh` as a no-op
      capture; calls `halt_issue_for_self_leak ENG-X reviewing
      aabbccdd1122 ddeeff334455`; asserts:
      * Capture file shows `issue=ENG-X stage=reviewing
        policy=skip-until-human-acts exit_code=26`.
      * Capture's reason field matches the regex
        `^[0-9a-f]{12}(, [0-9a-f]{12})*$` for the hash list (no raw
        paths in body — security P1-1) AND contains the exact
        substrings `aabbccdd1122` and `ddeeff334455` (defends against
        a regression where the helper renders zeros or a constant —
        product P1).
      * `is_orchestrator_paused` returns `false` (with a fresh
        STATE_FILE).
      * `$PROJECT_STATE_DIR/.consecutive-failures` does NOT exist.
      * Truncation: invocation with 7 hashes asserts the rendered
        reason contains `(and 2 more)` and exactly 5 leading hashes.
- [ ] `test_tally_leaked_in_scope_increments_per_issue_counter` — D-7 #2.
      Three sequential tick-equivalent invocations:
      `tally_leaked_in_scope_failure ENG-X implementing 1 abcdef012345`.
      * After call 1: `$(issue_dir ENG-X)/.consecutive-failures` content is `1`.
        Capture file does NOT show classify_failure invocation.
      * After call 2: counter is `2`. Still no halt.
      * After call 3: counter is `3`. Capture file shows
        `policy=skip-until-human-acts exit_code=27`.
      * Assertion that the GLOBAL counter at
        `$PROJECT_STATE_DIR/.consecutive-failures` does NOT exist
        across all three calls.
- [ ] `test_route_run_stage_exit_rc24_increments_global` — D-7 #3 positive.
      Three sequential `route_run_stage_exit ENG-A planning 24`,
      `route_run_stage_exit ENG-B implementing 24`,
      `route_run_stage_exit ENG-C qa 24` (different issues each tick).
      * After call 3: `$PROJECT_STATE_DIR/.consecutive-failures` content is `3`.
      * Asserts `is_orchestrator_paused` returns `true` (trip_breaker
        was called).
      Negative: `route_run_stage_exit ENG-X implementing 20` (rc=20 =
      dispatch-failed). Asserts the global counter file does NOT
      exist (or is `0`); per-issue counter at
      `$(issue_dir ENG-X)/.consecutive-failures` is `1`.
- [ ] `test_cross_issue_isolation_self_leak_does_not_block_other_issues` — D-7 #4.
      The regression lock for the 2026-05-05 ENG-63→ENG-64/65
      incident. Three "ticks" via three subshells:
      * Tick 1: `halt_issue_for_self_leak ENG-A reviewing
        aabbccdd1122`. Asserts capture shows ENG-A halted; global
        breaker `is_orchestrator_paused` = false; ENG-A's
        `.consecutive-failures` (per-issue) does not need to exist
        (D-1 doesn't increment the per-issue counter; halt is direct).
      * Tick 2: simulated as a fresh subshell that calls
        `route_run_stage_exit ENG-B implementing 0` (clean run on a
        DIFFERENT issue). Asserts no change to ENG-A's halt state;
        no global counter file.
      * Tick 3: `route_run_stage_exit ENG-C reviewing 0` (clean run
        on yet another DIFFERENT issue). Same assertions.
      The cross-issue claim is "ENG-A's halt did not block the next
      tick's clean run on ENG-B/C" — encoded as: at the END of EACH
      of the three subshells, `is_orchestrator_paused` is asserted to
      return `false` (defends against a regression where a later
      helper accidentally trips the breaker — product P1), and
      ENG-B/ENG-C have no per-issue counter files (clean runs).
- [ ] Run the test suite: `bash bin/run-local-helpers-adversarial-test.sh`
      — confirm exit 0 with all PASS lines including the four new
      tests (and no regression in the existing 30+ tests).
- [ ] `bash -n bin/run-local-helpers-adversarial-test.sh` — verify clean parse.

### Task 8: Update CLAUDE.md "Failure-mode quick reference"

- `depends_on: []`
- `touches: CLAUDE.md:386`
- [ ] Edit `CLAUDE.md:386` — replace the single "Breaker tripped"
      row with two rows distinguishing per-issue halt from the global
      breaker. Concrete replacement:
      ```markdown
      | Per-issue halt (self-leak / leaked-in-scope at threshold / N×same-issue failure) | Linear comments under sig `halt/<stage>/<issue>` (verdict result=halt, reason=agent-blocked); `pipeline:halted` + `pipeline:skip-until-human-acts` labels; `$(issue_dir <issue>)/.consecutive-failures` carries the count. Other issues continue to be polled — do NOT touch `orchestrator.paused`. **One-command recovery:** `bash bin/pipeline.sh decide <ENG-N> --action continue` (clears halt label, skip labels, per-issue counter, issue-state, posts operator-resume waypoint). |
      | Global breaker (infrastructure outage) | `$PROJECT_STATE_DIR/.consecutive-failures` ≥ 3 from rc=24 (linear-post-failed) accumulated across ticks; `orchestrator.paused=true` in `STATE_FILE` or `CONFIG`. Resolve with `set_orchestrator_paused false` (or any `decide --action continue`, which also clears the breaker via `_pipeline_clear_breaker`). The next clean tick clears the global counter. |
      ```
      Both rows use `|` table separators consistent with the
      surrounding rows; both single-line entries (no embedded
      newlines). `bash bin/pipeline.sh` invocation uses the
      harness-relative path matching the other rows (`Kill switch`).

### Task 9: Verify full-suite test parity

- `depends_on: [4, 6, 7, 8]`
- `touches: (none — verification only)`
- [ ] Run the full pre-commit gate: `bash bin/dispatch-test.sh && bash
      bin/run-stage-test.sh && bash bin/poll-slot-test.sh && bash
      bin/scope-check-test.sh && bash bin/verdict-handler-test.sh && bash
      bin/classify-failure-test.sh && bash bin/halt-sprawl-test.sh && bash
      bin/halt-sprawl-adversarial-test.sh && bash bin/linear-test.sh && bash
      bin/metrics-test.sh && bash bin/mutex-test.sh && bash
      bin/setup-helpers-test.sh && bash bin/render-prompt-test.sh && bash
      bin/phase-project-profile-test.sh && bash bin/common-test.sh && bash
      bin/run-local-helpers-adversarial-test.sh`. Confirm all green.
- [ ] If any pre-existing test fails (see CLAUDE.md `KNOWN_BROKEN`
      allowlist), confirm the failure was not introduced by ENG-69
      changes; if introduced, root-cause and fix in this branch.
- [ ] `bash -n bin/run-local.sh bin/run-local-helpers.sh bin/common.sh
      bin/pipeline.sh bin/run-local-helpers-adversarial-test.sh`
      — verify clean parse on all five.

## Frontend Tasks

No frontend tasks. The harness has no UI.

## Failure Mode → Test Map

The brainstorm's §7 (Error handling) and §8 (Edge cases) are bound to
concrete tests below. Test names match the function names in Task 7.

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
|---|---|---|---|---|
| Self-leak on ENG-X reaches `trip_breaker` directly (the bug) | Synthetic: agent leaves a new untracked file outside the allowlist; `partition_dirty_paths` classifies as out-of-scope-and-NEW | Per-issue halt via classify_failure with skip-until-human-acts; orchestrator.paused stays false | unit | `test_halt_issue_for_self_leak_per_issue_routes_correctly` |
| Self-leak halt-comment marker injection via leaked filename | Synthetic: hash list contains adversarial strings (verified to be sha12 only — `^[0-9a-f]{12}$`) | Halt-comment body contains hashes only; matches regex; never raw paths | unit | `test_halt_issue_for_self_leak_per_issue_routes_correctly` (regex-assertion sub-case) |
| Self-leak with > 5 hashes | Synthetic: 7 hashes passed | Reason renders 5 hashes plus `(and 2 more)` suffix | unit | `test_halt_issue_for_self_leak_per_issue_routes_correctly` (truncation sub-case) |
| Leaked-in-scope below threshold | Two ticks with leaked_count>0 on ENG-X | Per-issue counter increments to 2; no halt | unit | `test_tally_leaked_in_scope_increments_per_issue_counter` |
| Leaked-in-scope at threshold | Three ticks with leaked_count>0 on ENG-X | classify_failure invoked with policy=skip-until-human-acts, exit_code=27; per-issue counter at 3; global counter never written | unit | `test_tally_leaked_in_scope_increments_per_issue_counter` |
| Linear API outage trips global breaker | Three ticks with rc=24 on different issues | Global counter at 3; trip_breaker invoked; orchestrator.paused=true | unit | `test_route_run_stage_exit_rc24_increments_global` (positive half) |
| Per-issue rc=20 (dispatch-failed) does NOT trip global | Single tick rc=20 on ENG-X | Per-issue counter on ENG-X = 1; global counter does not exist | unit | `test_route_run_stage_exit_rc24_increments_global` (negative half) |
| Cross-issue isolation regression (ENG-63→ENG-64/65) | Tick1: ENG-A self-leaks; Tick2: ENG-B clean run; Tick3: ENG-C clean run | After tick1: ENG-A halted, breaker NOT tripped; ticks 2/3 proceed normally on different issues | unit | `test_cross_issue_isolation_self_leak_does_not_block_other_issues` |
| Counter file corrupted (non-integer body) | Synthetic: write "garbage" to per-issue counter, then call `tally_leaked_in_scope_failure` | Sanitizer collapses non-digits; counter resumes at 1 (NOT 0+1=1, but specifically the first write after corruption) | unit | covered as a sub-case in `test_tally_leaked_in_scope_increments_per_issue_counter` (extend the existing test) |
| Brand-new issue with no `issue_dir` yet | First leaked-in-scope on ENG-X, no prior `$(issue_dir ENG-X)` | `mkdir -p` creates dir; counter file written at `1` | unit | covered by the first call in `test_tally_leaked_in_scope_increments_per_issue_counter` (subshell uses fresh `mktemp -d`) |
| `decide --action continue` clears per-issue counter | `cmd_decide ENG-X --action continue` after counter set to 2 | Per-issue counter file removed; global counter unchanged unless tripped | integration | added as `test_decide_continue_clears_per_issue_counter` to `bin/halt-sprawl-test.sh` (existing pipeline.sh-cmd_decide test file) — **out of scope but flagged**; primary verification is via Task 7 helper unit test where `tally_leaked_in_scope_failure` is invoked then `rm -f` is called manually mirroring D-4's behavior |
| Idempotency: second invocation of `halt_issue_for_self_leak` on same tick | Two back-to-back calls (defensive — should not happen in real code path) | Each call invokes classify_failure exactly once; metric event emitted twice (acceptable: classify_failure's halt-comment is upserted via add-or-update-comment) | unit | covered by re-running the same call in `test_halt_issue_for_self_leak_per_issue_routes_correctly` and asserting capture file has 2 entries (idempotent at the FS level, not at the metric level — flagged in §10 OQ-1 of brainstorm) |

The "decide --action continue clears per-issue counter" row is the
only mapping that does NOT have a unit test in Task 7 (because it
exercises `pipeline.sh::cmd_decide`, not the helpers). The
brainstorm's AC #4 names this as an integration concern; `cmd_decide`
is exercised by `bin/halt-sprawl-test.sh` already, but extending that
test is **out of strict scope** for this plan since AC #1-#7 don't
require it. The defensive proof is mechanical: `rm -f` of a missing
file is idempotent and a no-op (verified by inspection of the existing
`_pipeline_clear_breaker` line at `bin/pipeline.sh:274`); a manual
operator test of `decide --action continue` after a synthetic per-issue
halt is the recommended pre-merge spot-check.

## Test Strategy

- **Unit (function-level, Task 7).** Four new `bin/run-local-helpers-adversarial-test.sh`
  test groups source the helpers, stub `classify_failure`,
  `linear.sh`, `metrics.sh`, `set_orchestrator_paused` per the
  existing source-and-stub pattern at lines 624-673 (`trip_breaker`
  tests). These exercise the new functions in isolation: the routing
  decision, the counter math, the threshold escalation, and the
  cross-issue independence.
- **Integration (PIPELINE_DRY_RUN end-to-end).** No new
  integration test added (D-7 explicitly rejects the black-box
  alternative). The implement agent SHOULD run
  `PIPELINE_DRY_RUN=1 TARGET_REPO=… bash bin/run-local.sh` post-merge
  to confirm a synthetic dispatch path exits cleanly under the rewired
  routing. Not a strict gate.
- **Smoke.** `bash -n` parse-checks on all five modified files (Task
  9). The existing pre-commit hook at `.githooks/pre-commit` runs
  the full `bin/*-test.sh` glob, which auto-includes the appended
  test cases without further wiring.
- **Adversarial coverage (already in Task 7).** Counter-file
  corruption (`pic="${pic//[^0-9]/}"`); >5-hash truncation; missing
  per-issue dir (`mkdir -p`); halt-comment regex assertion (no raw
  paths in body); idempotent re-invocation. The cross-issue isolation
  test is the regression lock for the 2026-05-05 ENG-63 incident —
  written before the fix to ensure failure on `main`.
- **Failure-mode coverage.** Every row of the Failure Mode → Test Map
  table maps to a named test in Task 7 (or a sub-case within a named
  test, explicitly flagged). The `decide --action continue` row is
  flagged as out-of-scope-but-expected-to-work via the inspection
  argument (`rm -f` idempotence).

Pre-commit gate: `.githooks/pre-commit` runs every `bin/*-test.sh` and
any new failure halts the commit. The KNOWN_BROKEN allowlist is not
modified by this plan.
