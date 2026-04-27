---
linear: ENG-41
topic: Pipeline trust model — enforce label/comment write lanes + cycle-scoped recovery
date: 2026-04-27
status: draft
---

# Plan — ENG-41 pipeline trust-model fix

Implementation plan for the design in
`docs/brainstorms/2026-04-27-pipeline-trust-model-enforce-write-lanes-design.md`.

## Goal

Land a single PR that (1) installs a writer-lane fence in `bin/linear.sh` so
agents technically cannot write `<!-- pipeline-transition: -->` comments or
mutate `stage:*` labels, (2) adds two consistency guards to
`verdict-handler.sh::resume_in_progress_transition` that refuse to act on
stale or forged comments, and (3) gates `run-stage.sh`'s post-dispatch halt
re-application on "still on the dispatched stage." Together these restore
the four trust invariants in the brainstorm §2 and prevent ENG-24 / ENG-26
recurrence.

## Assumption inventory

- A-001: every harness label/comment write goes through `bin/linear.sh`. Verified by `grep -rn "linear.app/graphql\|graphql.linear.app\|api.linear.app" bin/` returning nothing outside `linear.sh`.
- A-002: agent `--allowed-tools` (in `dispatch.sh::allowed_tools_for`) excludes `mcp__plugin_linear_linear__*` for every stage. New `dispatch-test.sh` case asserts this.
- A-003: bash env-var inheritance carries `PIPELINE_WRITER=agent` from `dispatch.sh` into the `claude -p` subshell and any sub-bash the agent spawns. New fixture in `dispatch-test.sh` asserts this.
- A-004: `linear.sh` centralizes `add_label`, `remove_label`, `add_comment` — fence at the top of these three covers all writes.
- A-005: `verdict_handler` falls through to `find_fresh_verdict` when `resume_in_progress_transition` returns 1 (existing behavior, verdict-handler.sh:209-232).
- A-006: `linear.sh stage-of` returns the empty string when the issue carries no `stage:*` label.
- A-007: tests source the script-under-test with `PIPELINE_DRY_RUN=1` + `LINEAR_API_KEY=test-mock-key` and stub `STUB_DIR/linear.sh` (CLAUDE.md "How tests work").
- A-008: `failure_outcome_for_exit` in `common.sh` is the single source of truth for exit-code → outcome name.
- A-009: `dispatch.sh` invokes `claude -p` via a single chokepoint where `PIPELINE_WRITER=agent` can be exported (to be confirmed in Task 3).
- A-010: `halt.sh`, `reset-pipeline.sh`, `mark-abandoned.sh` are the only operator-facing entry points needing the `human` lane.

## File Structure

```
bin/
  linear.sh                 modified  — lane fence in add_label/remove_label/add_comment
  common.sh                 modified  — default PIPELINE_WRITER=orchestrator + lane-violation outcome
  dispatch.sh               modified  — export PIPELINE_WRITER=agent before claude -p
  classify-failure.sh       modified  — set PIPELINE_WRITER=classify
  scope-check.sh            modified  — set PIPELINE_WRITER=scope-check
  halt.sh                   modified  — set PIPELINE_WRITER=human
  reset-pipeline.sh         modified  — set PIPELINE_WRITER=human
  mark-abandoned.sh         modified  — set PIPELINE_WRITER=human
  verdict-handler.sh        modified  — two new guards in resume_in_progress_transition
  run-stage.sh              modified  — stage-drift guard before defensive halt-add
  linear-test.sh            NEW       — table-driven lane-fence test
  verdict-handler-test.sh   modified  — stale-comment + multi-stage-label cases
  run-stage-test.sh         modified  — stage-drift case
  dispatch-test.sh          modified  — allowed-tools + env-propagation cases

AGENT_PROMPTS.md            modified  — replace label vocabulary table (lines 67-91)
docs/runbooks/recovery.md   NEW       — multi-stage-label + forged-transition recovery runbook
```

## Command API contract

No flag-level CLI changes. `linear.sh` argv shapes are unchanged:

```
linear.sh add-label    <issue> <label_name>
linear.sh remove-label <issue> <label_name>
linear.sh add-comment  <issue> <body>
```

Behavior is conditioned on the new env var:

```
PIPELINE_WRITER ∈ { orchestrator | agent | classify | scope-check | human }
                  default: orchestrator if unset
```

The lane allow-list is the single source of truth. Object classes:

- `stage_label` — any label matching `^stage:.+$`
- `pipeline_halted` — exact label `pipeline:halted`
- `pipeline_supersede` — exact label `pipeline:supersede`
- `pipeline_skip_until` — any label matching `^pipeline:skip-until-.+$`
- `any_other_label` — labels not matching `^(stage|pipeline):.+$`
- `transition_comment` — comment whose first non-blank line is `<!-- pipeline-transition: ... -->`
- `other_comment` — any other comment

Per-lane allow / deny matrix:

| Action / object             | orchestrator | agent | classify | scope-check | human |
|---|:-:|:-:|:-:|:-:|:-:|
| add stage_label             | allow | deny | deny | deny | allow |
| remove stage_label          | allow | deny | deny | deny | allow |
| add pipeline_halted         | allow | allow | allow | allow | allow |
| remove pipeline_halted      | allow | deny | deny | deny | allow |
| add pipeline_supersede      | allow | deny | deny | deny | allow |
| remove pipeline_supersede   | allow | allow | deny | deny | allow |
| add pipeline_skip_until     | deny | deny | allow | deny | allow |
| remove pipeline_skip_until  | allow | deny | allow | deny | allow |
| add transition_comment      | allow | deny | deny | deny | allow |
| add other_comment           | allow | allow | allow | allow | allow |
| add any_other_label         | allow | deny | deny | deny | allow |
| remove any_other_label      | allow | deny | deny | deny | allow |

Lane-denial error format (stderr; stdout empty; exit code 11):

```
linear.sh: lane=<W> denied: <action> <object>
            (allowed lanes for <action> <object>: <comma-separated lanes>)
```

`failure_outcome_for_exit 11 ""` returns `lane-violation`.

## Backend tasks

(Bash harness — there is no Tauri/Rust backend. "Backend" here = harness scripts.)

### Task 1 — `bin/linear.sh` lane fence

**depends_on:** []

Add helper `_check_lane <action> <object_class>` at top of `linear.sh`. Reads `${PIPELINE_WRITER:-orchestrator}`, looks up the per-lane matrix (encoded as a heredoc string), prints stderr + returns nonzero on deny. Insert call at top of `add_label`, `remove_label`, `add_comment` after argv validation but before any Linear API call (so dry-run still respects the fence).

Object-class detection helpers:
- `_classify_label "$label"` → emits one of `stage_label | pipeline_halted | pipeline_supersede | pipeline_skip_until | any_other_label`
- `_classify_comment_body "$body"` → emits `transition_comment` if the body's first non-blank line matches the regex, else `other_comment`

Test commit precedes implementation commit (TDD).

### Task 2 — `bin/common.sh` default lane + outcome

**depends_on:** []

Export `PIPELINE_WRITER="${PIPELINE_WRITER:-orchestrator}"` near the other env exports. Extend `failure_outcome_for_exit` switch with `11) printf 'lane-violation' ;;`. No test commit (covered by Task 1's test which exercises the unset → default behavior).

### Task 3 — entry-point lane assignments

**depends_on:** [Task 1, Task 2]

Set `PIPELINE_WRITER` in each script's main entry, before any `linear.sh` call:

- `bin/dispatch.sh::main` — `export PIPELINE_WRITER=agent` immediately before `claude -p` invocation chokepoint.
- `bin/classify-failure.sh::classify_failure` — `export PIPELINE_WRITER=classify` at function top.
- `bin/scope-check.sh::main` — `export PIPELINE_WRITER=scope-check` at script top after sourcing common.sh.
- `bin/halt.sh::main`, `bin/reset-pipeline.sh::main`, `bin/mark-abandoned.sh::main` — `export PIPELINE_WRITER=human` at script top.

No new tests for this task; coverage comes from Task 7's dispatch-test (env propagation) and a smoke fixture in linear-test.sh (Task 6) that exercises each entry point's lane.

### Task 4 — `verdict-handler.sh::resume_in_progress_transition` cross-check guards

**depends_on:** []

Replace the predicate at verdict-handler.sh:192-200 with the two-guard logic from brainstorm §4.2:

```bash
# Guard 1: already at destination — nothing to resume.
[[ "$current_stage" == "$to" ]] && return 1

# Guard 2 (NEW): comment.from disagrees with labels.from — comment is stale or forged.
if [[ "$current_stage" != "$from" ]]; then
  log "verdict-handler: skipping resume — labels(from=$current_stage) disagree with comment(from=$from)"
  return 1
fi

# Guard 3 (NEW): issue carries multiple stage:* labels — malformed, refuse to compound.
local all_stages
all_stages="$(bash "$_VH_SCRIPT_DIR/linear.sh" all-stage-labels "$issue")"
if [[ "$(wc -w <<<"$all_stages")" -gt 1 ]]; then
  log "verdict-handler: skipping resume — multiple stage:* labels: $all_stages"
  return 1
fi

# Existing condition — preserved.
if bash "$_VH_SCRIPT_DIR/linear.sh" has-label "$issue" "pipeline:halted"; then
  log "verdict-handler: resuming mid-transition $issue: $from → $to"
  apply_transition "$issue" "$from" "$to" "" 0
  return 0
fi
return 1
```

Add helper `linear.sh all-stage-labels <issue>` (Task 1's enabling helper) that emits all `stage:*` labels space-separated.

Test commit precedes implementation.

### Task 5 — `run-stage.sh` stage-drift guard

**depends_on:** []

Replace lines 431-436 with:

```bash
local dispatched_stage_label="stage:$stage_label_long"
local current_stage_label
current_stage_label="$(bash "$SCRIPT_DIR/linear.sh" stage-of "$ident")"
if [[ "$current_stage_label" != "$dispatched_stage_label" ]]; then
  log "post-dispatch: stage drifted ($dispatched_stage_label → ${current_stage_label:-none}) during run — skipping defensive halt apply and verdict handler"
  bash "$SCRIPT_DIR/metrics.sh" stage-end "$ident" "$stage" "stage-drift" "$duration" "drift=${current_stage_label:-none}"
  exit 0
fi
if ! bash "$SCRIPT_DIR/linear.sh" has-label "$ident" "pipeline:halted"; then
  log "post-dispatch: agent did not apply pipeline:halted; applying on its behalf"
  bash "$SCRIPT_DIR/linear.sh" add-label "$ident" "pipeline:halted" || true
fi
```

Note: when stage-drift is detected, both the defensive halt-add AND the subsequent `verdict_handler` call (currently at lines 444-461) are skipped. Wrap both in a shared early-exit.

Add `stage-drift` to `failure_outcome_for_exit` (Task 2 already added one slot at exit code 11 for lane-violation; stage-drift gets its own slot — propose exit code 12).

Test commit precedes implementation.

### Task 6 — `bin/linear-test.sh` lane-fence test (NEW)

**depends_on:** [Task 1]

Table-driven: `lane × action × object_class → expected (allow | deny)`. ~36 cases (5 lanes × ~12 cells). Sources `bin/linear.sh` with `PIPELINE_DRY_RUN=1` and overrides the dry-run path inside `add_label`/`remove_label`/`add_comment` to capture intent without hitting the network. Asserts:

1. Allow cells return 0 and (in dry-run) print the intended write.
2. Deny cells return non-zero AND emit the expected stderr error format.
3. Unset `PIPELINE_WRITER` defaults to `orchestrator`.
4. Unknown lane (e.g., `PIPELINE_WRITER=foo`) is rejected with a distinct error message.

Sentinel pattern at end of file (CLAUDE.md "How tests work").

### Task 7 — `bin/dispatch-test.sh` extend

**depends_on:** [Task 3]

Add cases:

- `dispatch_allowed_tools_for <each_stage>` does NOT include `mcp__plugin_linear_linear__*` (grep assertion).
- Env propagation: launch a sub-shell with `PIPELINE_WRITER=foo` set in the parent, run a stub for `dispatch.sh`'s `_invoke_claude`, assert the sub-shell receives `PIPELINE_WRITER=agent` (not `foo`).

### Task 8 — `bin/verdict-handler-test.sh` extend

**depends_on:** [Task 4]

Two new cases:

- **Case N+1:** stale-comment ENG-24 fixture — issue has `stage:brainstorming` + `pipeline:halted`, latest transition comment is `<!-- pipeline-transition: planning → implementing -->` from 2 days ago. Expectation: `resume_in_progress_transition` returns 1; `verdict_handler` then transitions brainstorming → planning via `find_fresh_verdict`.
- **Case N+2:** multi-stage-label fixture — issue has `stage:brainstorming` AND `stage:implementing` AND `pipeline:halted`. Expectation: `resume_in_progress_transition` returns 1; halt-sprawl alert fires after threshold ticks (existing test infrastructure).

### Task 9 — `bin/run-stage-test.sh` extend

**depends_on:** [Task 5]

One new case:

- dispatched_stage=ui, mid-run a stub flips stage label to stage:reviewing, post-run check: `pipeline:halted` is NOT applied, exit code 0, metrics record `stage-drift` outcome.

### Task 10 — `AGENT_PROMPTS.md` label vocabulary table

**depends_on:** [Task 1]

Replace the 4-row "Label vocabulary (post-Phase-4)" table at lines 67-91 with the 6×6 lane matrix from the §Command API contract above, plus a one-line reference: `"See bin/linear.sh's lane fence for the source of truth and the structured deny error."`. The "do NOT post this yourself" prose at line 52 is preserved (defense in depth).

### Task 11 — `docs/runbooks/recovery.md` NEW

**depends_on:** [Task 4, Task 8]

Three procedures:

1. **Multi-stage-label issue.** Identify via `bin/status.sh --json` or Linear UI. Decide which stage is correct (consult comment history). Remove the wrong label via `PIPELINE_WRITER=human bash bin/linear.sh remove-label <ENG-N> stage:<wrong>`. Confirm via `bin/linear.sh stage-of <ENG-N>` returns single label.
2. **Forged transition comment (e.g., from a misbehaving agent).** Cannot delete a Linear comment via API; instead post a counter-marker via `PIPELINE_WRITER=human bash bin/linear.sh add-comment <ENG-N> "<!-- pipeline-transition: <correct-from> → <correct-to> -->\n\nManual correction by operator on $(date -u +%Y-%m-%dT%H:%M:%SZ)."` to advance the freshness window.
3. **Stuck protocol-violation halt.** Run `bash bin/halt.sh resolve <ENG-N> --decision resume`.

## Frontend tasks

No frontend tasks. This is a bash harness; there is no UI surface.

## Failure mode → test map

| Failure mode | Bound test | Pass / fail |
|---|---|---|
| Agent attempts to post `<!-- pipeline-transition: -->` comment | linear-test.sh: lane=agent × add transition_comment → deny | must pass |
| Agent attempts to add `stage:<X>` label | linear-test.sh: lane=agent × add stage_label → deny | must pass |
| Agent attempts to remove `pipeline:halted` | linear-test.sh: lane=agent × remove pipeline_halted → deny | must pass |
| Stale-cycle transition comment present (ENG-24 scenario) | verdict-handler-test.sh case N+1: returns 1 (no resume), find_fresh_verdict transitions correctly | must pass |
| Two `stage:*` labels on one issue | verdict-handler-test.sh case N+2: returns 1 (no resume), no apply_transition call | must pass |
| Stage label flipped during agent run (ENG-26 scenario, even with lane fence — defense in depth) | run-stage-test.sh new case: halt NOT re-applied, stage-drift outcome emitted | must pass |
| Lane unset in caller's env | linear-test.sh: defaults to orchestrator (preserves existing behavior) | must pass |
| Unknown lane name | linear-test.sh: rejected with distinct error message | must pass |
| Agent's allowed-tools includes Linear MCP (would bypass lane fence) | dispatch-test.sh: grep assertion fails the test | must pass |
| Mid-run real crash between transition comment write and label updates (the original use case for resume_in_progress_transition) | existing verdict-handler-test.sh case (resume from comment.from == labels.from) | must remain passing |
| `linear.sh stage-of` on issue with no stage label | linear-test.sh + verdict-handler-test.sh: returns empty string; cross-check guard fires (current_stage="" != from → return 1, safe) | must pass |
| Operator runs `halt.sh resolve` (lane=human, removes pipeline:halted) | linear-test.sh: lane=human × remove pipeline_halted → allow | must pass |

## Test strategy

Bash test scripts in `bin/*-test.sh`, each self-contained per CLAUDE.md "Tests" section. New tests follow the existing source-and-stub pattern: source the script-under-test inside the test, set `PIPELINE_DRY_RUN=1` and `LINEAR_API_KEY=test-mock-key` before sourcing, override globals (`TARGET_REPO`, `SCRIPT_DIR`, `_VH_SCRIPT_DIR`, etc.) post-source to point at fixture dirs.

Three test surfaces:

1. **Lane fence (linear-test.sh, NEW)**: table-driven, ~36 cases. Captures both allow and deny outcomes. The dry-run path is extended slightly so deny is observable without network.
2. **Verdict handler (verdict-handler-test.sh, extended)**: 2 new cases for cross-check guards. Existing cases (no transition, single transition, in-progress mid-crash) must remain green — the guards must not regress legit recovery.
3. **Run-stage (run-stage-test.sh, extended)**: 1 new case for stage-drift skip. Existing cases (clean exit, halt applied, scope-deviation) must remain green.

Plus extension to `dispatch-test.sh` for env propagation + allowed-tools assertion.

Gate command set: `bash bin/linear-test.sh && bash bin/verdict-handler-test.sh && bash bin/run-stage-test.sh && bash bin/dispatch-test.sh && bash bin/dry-run.sh`.

`dry-run.sh` runs as a final smoke pass — it exercises render-prompt + dispatch + linear.sh under each known lane and asserts no lane-violation errors leak out. If `dry-run.sh` doesn't already cover this path, extend it as part of Task 6.

## Rollout

Single-PR rollout. Tasks 1+2+4+5 are independent and can be authored in any order (their tests are independent too). Task 3 depends on 1+2. Tasks 6-9 are tests that depend on their respective implementation tasks. Tasks 10-11 are docs.

Suggested commit order (TDD):

1. Task 6 test (red) → Task 1 impl (green)
2. Task 2 (impl + verified by Task 6's default-lane case)
3. Task 8 test (red) → Task 4 impl (green)
4. Task 9 test (red) → Task 5 impl (green)
5. Task 3 (entry-point lanes; verified by Task 7 next)
6. Task 7 test (covers Task 3)
7. Task 10 docs
8. Task 11 runbook

Post-merge manual recovery (one-time):

- ENG-24: `PIPELINE_WRITER=human bash bin/linear.sh remove-label ENG-24 stage:brainstorming` (keep `stage:implementing`); `bash bin/halt.sh resolve ENG-24 --decision resume`.
- ENG-26: `bash bin/halt.sh resolve ENG-26 --decision resume` then `PIPELINE_WRITER=human bash bin/linear.sh add-label ENG-26 stage:reviewing` (the save_issue side-effect from ENG-41 setup stripped this).

No feature flag. The cross-check and lane fence are strictly more conservative than current behavior.
