---
linear: ENG-179
title: planning→implementing transitions on verdict=pass without verifying the plan artifact is committed to the branch
date: 2026-06-10
status: draft
---

# ENG-179 — Gate planning→implementing on a committed plan artifact

**Type:** `Bug` (High) · **Subsystem:** orchestrator (`bin/run-stage.sh::_validate_plan_contract`) + tests (subordinate) · **Status:** design draft

## Problem

A `planning` dispatch on ENG-125 (2026-06-10) posted
`<!-- pipeline: verdict result=pass stage=planning -->` plus a completion summary to
Linear. The orchestrator's `verdict_handler` saw the fresh pass marker and ran
`apply_transition`, flipping `stage:planning` → `stage:implementing`. But the
canonical plan artifact (`docs/plans/2026-06-10-eng-125-*.md` + sibling
`.json`) was **never committed to the branch** — the `claude -p` planning run is
believed to have hit a session-limit/credit envelope after the agent posted the
Linear comments but before it wrote and committed the files (see operator
memory: `session-limit-false-halts`).

The first place the missing artifact is detected today is implement's
`bin/scope-check.sh::find_canonical_plan` returning empty (rc=2, *"no
docs/plans/\*.md with frontmatter linear: ENG-125"*; `bin/scope-check.sh:286-287`).
By then the issue already carries `stage:implementing`, and we burn two
implement dispatches to take the `implement_rejection` counter to 2/2 before
guards halts.

The pipeline advanced on the strength of the Linear pass-marker alone — there
is no orchestrator-side gate between "agent emitted `verdict=pass`" and the
label transition that checks the actual filesystem/branch state matches the
verdict.

## Root cause

`bin/run-stage.sh::_validate_plan_contract` (lines 1082–1118) runs
post-dispatch on `planning` only, and is *meant* to be that gate. But its
absent-md branch deliberately **fails open**:

```bash
plan_md="$(cd "$wt" && find docs/plans -maxdepth 1 -type f -iname "${today}-*${ident_lower}-*.md" 2>/dev/null | sort | head -1)"
# Fail-open if no plan .md for today: the exit-25 agent-contract validator
# handles the absent-md case upstream; double-halting here would be noise.
if [[ -z "$plan_md" ]]; then
  log "plan-contract: no plan .md found for $ident matching ${today}-*${ident_lower}-*.md; fail-open"
  return 0
fi
```
(`bin/run-stage.sh:1098-1104`)

The "exit-25 agent-contract validator handles the absent-md case upstream"
comment is wrong for this failure mode: exit-25 (`agent-contract-missing`) is
emitted by `dispatch.sh`'s detective for a missing `progress.md` / missing
stage-summary entry; it does **not** check that the plan `.md` was committed,
and it does not fire when the agent emitted the verdict marker but died before
committing files. The absent-md case is precisely the defect ENG-125 hit, and
nothing else catches it pre-transition.

There is a second, subtler gap. Even if `_validate_plan_contract` did halt on
absent-md, it searches the **worktree filesystem** (`find docs/plans …`), not
the **branch tree**. A planning agent that writes the `.md` into the worktree
but dies before `git commit` would still satisfy a filesystem-find while
leaving HEAD without the plan. The orchestrator's partition-sweep auto-commit
in `bin/run-local.sh:226-317` would normally catch the uncommitted case and
commit it as a backstop — *but the sweep runs AFTER `run-stage.sh` returns*,
so the verdict-handler label transition has already happened. There is no
ordering today that makes "the plan is in branch HEAD" a precondition of the
label flip.

## Conceptual model

A stage transition is the orchestrator asserting *"the agent's promised
artifact is real and durable on the branch."* For `planning → implementing`
that artifact is exactly the canonical plan pair
(`docs/plans/<date>-<ident>-*.md` + sibling `.json`) in branch HEAD. The
verdict marker is the agent's *claim*; the gate is the orchestrator's
*verification* of that claim. Today the orchestrator skips verification when
the most-suspicious possible state (`.md` absent) is observed — that's
upside-down.

The fix is to make `_validate_plan_contract`'s absent-md branch **halt** with
`plan-contract-missing` instead of fail-open, and to switch its search
substrate from the worktree filesystem to **branch HEAD** so the gate
literally asserts the issue's acceptance criterion: *"present in the branch's
commits, not just the dirty worktree."*

## Design — the change

Tighten `bin/run-stage.sh::_validate_plan_contract`, in place. Two edits:

1. **Replace the worktree-find with a HEAD-tree query.** Use
   `git ls-tree --name-only -r HEAD -- docs/plans/` (run with `cd "$wt"` so
   the per-issue worktree's HEAD is queried), filtered against the canonical
   basename pattern. Worktree-find sees uncommitted dirty files; HEAD-tree
   only sees committed paths. The latter matches the issue's "committed to
   branch" requirement directly and removes the structural dependency on the
   downstream partition-sweep for correctness.

2. **Remove fail-open on absent-md.** When no committed plan `.md` matches
   the pattern, `_post_plan_contract_halt` with defect token
   `plan-contract-missing` (already defined in
   `bin/common.sh:334::failure_outcome_for_exit` as exit 35), and return 35.
   The caller at `bin/run-stage.sh:1925-1937` already routes return 35
   through `classify_failure … skip-until-human-acts` and `exit 35`, so the
   existing halt-comment, label-apply, and end-row plumbing all light up
   correctly — no caller change needed.

Pseudocode (delta inside `_validate_plan_contract`):

```bash
# Was: find docs/plans -maxdepth 1 -type f -iname "${today}-*${ident_lower}-*.md"
# Hyphen after ${ident_lower} preserves the existing eng-12-vs-eng-122 guard
# (current code line 1094 comment) — feasibility persona P1-1.
plan_md="$(cd "$wt" && git ls-tree --name-only -r HEAD -- docs/plans/ 2>/dev/null \
  | grep -iE "^docs/plans/[0-9]{4}-[0-9]{2}-[0-9]{2}-.*${ident_lower}-.*\.md$" \
  | sort | tail -1)"   # sort by ISO-date string; tail -1 = latest

if [[ -z "$plan_md" ]]; then
  # Diagnostic body — see Error handling table for the full rendered shape.
  # Includes session-limit hint (OQ-2 → accepted, product persona P1-1) and
  # the log path the operator should inspect (product persona P1-3).
  _post_plan_contract_halt "$ident" "plan-contract-missing" \
    "$(printf 'No committed plan artifact at docs/plans/<date>-*%s-*.md in branch HEAD. The planning agent emitted verdict=pass but did not commit the canonical plan .md (and sibling .json).\n\nCommon cause: claude -p session-limit / out_of_credits death after marker emission but before file commit (operator memory: session-limit-false-halts). Inspect the dispatch log at $PROJECT_STATE_DIR/<slug>/logs/%s-planning-*.log to confirm before re-running.' "$ident_lower" "$ident")"
  return 35
fi
```

The sibling-`.json` schema-validation tail (`plan-schema.sh validate …`,
lines 1106–1117) is unchanged: it already runs when the `.md` is found and
routes through `_post_plan_contract_halt` for rc 33/34/35. With the new
HEAD-tree search, a `.md` present in HEAD but a `.json` absent in HEAD will
also be caught — the schema validator runs `find "$wt/$plan_json"` today, so
to keep the gate strictly HEAD-aware we extend `plan_json` lookup to also
use `git ls-tree --name-only -r HEAD -- "${plan_md%.md}.json"` (delta inside
the same function, two lines).

### Cross-midnight resume case

The current pattern `"${today}-*${ident_lower}-*.md"` (line 1098) restricts
to **today's** date prefix and was the explicit justification for the
fail-open behaviour ("cross-midnight re-dispatch on a plan written the day
before will fail-open"). With strict-halt, a planning re-dispatch at 00:05
UTC the day after the original plan landed would HALT incorrectly — there's
a valid committed plan, it just doesn't start with today's date.

Fix the basename pattern to **not require today's date**:
`^docs/plans/[0-9]{4}-[0-9]{2}-[0-9]{2}-.*${ident_lower}-.*\.md$` matches any
ISO-date-prefixed plan for this ident. The acceptance criterion's
"committed plan artifact on the branch" is satisfied by any committed plan
for the issue, regardless of the date its filename carries. `sort | tail -1`
picks the latest by ISO-date string sort (stable for any year-month-day
prefix). The trailing hyphen after `${ident_lower}` preserves the existing
`eng-12`-vs-`eng-122` boundary guard (per the existing comment at
`bin/run-stage.sh:1094`).

The plan-schema validator then re-asserts the artifact is *for this issue*
via the `issue_id` field check (`^ENG-[0-9]+$` against `--ident "$ident"`),
so the looser filename pattern does not let a foreign plan satisfy the gate.

## Rejected alternative — dedicated transition-gate in the orchestrator

A new layer that runs **between** `verdict_handler` and `apply_transition`,
generalised across stages (each transition declares its artifact contract;
the gate checks before flipping the label). Pros: clean separation between
"agent's claim" and "orchestrator's verification"; would naturally generalise
to other verdict-mismatch failure modes (e.g., a UI agent posting
verdict=pass without committing the PR).

Rejected because:

- **Premature generalisation.** Today only `planning → implementing` has
  this specific gap (plan-contract validation already exists; review-payload
  validation already exists at `bin/run-stage.sh:1939-1955`; envelope
  validation exists). The other transitions either don't have a single
  bright-line artifact (implementing/reviewing/qa span many files) or are
  caught by existing detectives (`_validate_review_payload`,
  `_validate_dispatch_envelope`, the `noop-implementation` detector at
  ~`bin/run-stage.sh:1778`).
- **Bigger structural reorder.** A transition-gate before `apply_transition`
  would either need to be inside `verdict_handler.sh::verdict_handler` (a
  new callout) or above it in `run-stage.sh::main`. The validator pattern
  the codebase already uses (`_validate_plan_contract`,
  `_validate_review_payload`, `_validate_dispatch_envelope`) is the
  established shape; introducing a new abstraction has churn cost.
- **Same end behaviour.** A pre-transition gate that halts with
  `plan-contract-missing` and a tightened `_validate_plan_contract` that
  halts with `plan-contract-missing` produce identical operator-visible
  outcomes (same halt comment, same exit code, same recovery). The
  difference is internal layering.

## Rejected alternative — move the partition sweep before `verdict_handler`

Restructure `run-local.sh::worker_run` so the in-scope artifact commit happens
*before* `run-stage.sh` runs the post-dispatch validators and `verdict_handler`.
Pros: a strict guarantee that "if we transition, the artifact is in HEAD" —
the sweep itself would do the commit and the validator would query HEAD
afterwards, with no agent-self-commit requirement.

Rejected because:

- **Cross-cutting refactor.** Today the sweep lives in
  `bin/run-local.sh:226-317` and depends on `run-stage.sh` having returned
  rc=0 (the `if [[ $rc -ne 0 ]]; then return $rc; fi` gate at line 224 is
  central to error routing). Moving the sweep inside `run-stage.sh` or
  before the validators inverts that contract and pulls auto-commit into
  the per-stage path.
- **Hides the agent contract.** The planning agent prompt (`AGENT_PROMPTS.md`
  §2 step 4, lines 627–633) already requires the agent to self-commit the
  plan pair. The orchestrator sweep is a backstop. Making the sweep
  load-bearing for transition correctness would mask agents that skip the
  self-commit step.
- **Same correctness end-state.** With agent self-commit + HEAD-tree check,
  we get the same invariant (HEAD has the artifact at transition time) with
  no plumbing change.

## Architecture — where code goes

- `bin/run-stage.sh::_validate_plan_contract` (~L1082-1118): the two
  in-function edits described above. No new function, no new file.
- `bin/run-stage.sh::main` post-dispatch validator block (~L1925-1937):
  **unchanged** — it already routes `_plan_rc != 0` through
  `classify_failure … skip-until-human-acts` and exits the dispatch.
- `bin/common.sh::failure_outcome_for_exit` (line 334): **unchanged** — exit
  35 already maps to `plan-contract-missing`.
- `bin/run-stage-test.sh` (~L4583-4596, the `INT-Q` fixture): the existing
  test that asserts `plan .md missing → fail-open (rc=0)` must flip to
  assert `plan .md missing in HEAD → rc=35 + halt comment`. This is an
  intentional behaviour change; the brainstorm acknowledges it explicitly.
- `bin/run-stage-test.sh` new fixtures: three test cases for the three
  states the issue lists (committed-pair / no-artifact / written-but-uncommitted).
- Documentation: an entry in CLAUDE.md "Failure-mode quick reference"
  describing the new halt and its recovery (operator runs
  `bash bin/pipeline.sh decide ENG-N --action continue` after fixing the
  underlying credit/session issue).

No new ADR is proposed — this change is a tightening of an existing validator,
not a new architectural axis. The "validators run between dispatch return and
verdict_handler" pattern is established (`_validate_dispatch_envelope`,
`_validate_plan_contract`, `_validate_review_payload` already sit there).

## Data flow

```
planning dispatch (claude -p)
  ├─ agent writes docs/plans/<date>-<ident>-<slug>.{md,json}      [contract step 4]
  ├─ agent: git add + git commit "chore(pipeline): plan for ..."  [contract step 4]
  ├─ agent: bash bin/pipeline.sh event ENG-N verdict pass ...     [contract step 7]
  └─ claude -p exits

run-stage.sh::main resumes
  ├─ _validate_dispatch_envelope                       (transcript detective; unchanged)
  ├─ _validate_plan_contract                           (THE GATE — tightened)
  │   ├─ wt="$(issue_dir $ident)/worktree"
  │   ├─ plan_md = git ls-tree -r HEAD -- docs/plans/ | grep <pattern> | tail -1
  │   ├─ if empty:
  │   │   _post_plan_contract_halt $ident plan-contract-missing "<diagnostic>"
  │   │   return 35
  │   └─ plan_schema.sh validate <plan_json>            (existing tail, HEAD-aware)
  ├─ on rc != 0: classify_failure skip-until-human-acts; exit 35
  ├─ push_branch_if_ahead
  ├─ post_completion_comment
  └─ verdict_handler                                   (label transition; only if plan validated)
      └─ apply_transition planning → implementing
```

The transition only fires if every post-dispatch validator returns rc=0. On
absent-committed-plan, `_validate_plan_contract` short-circuits at rc=35; the
label stays at `stage:planning`; the issue gets `pipeline:halted` applied via
`classify_failure`'s skip-until-human-acts policy; the operator runs
`bash bin/pipeline.sh decide ENG-N --action continue` to clear and re-poll.

## Error handling

| Condition | Behaviour |
|---|---|
| HEAD has committed `.md` + `.json`, schema-valid | rc=0, transition proceeds |
| HEAD has no `.md` for ident | rc=35, halt `plan-contract-missing`, label stays at `stage:planning` |
| HEAD has `.md` but no sibling `.json` | rc=35 (existing schema validator path), halt `plan-contract-missing` (existing) |
| HEAD has `.md` + `.json`, schema-malformed | rc=33, halt `plan-contract-malformed` (existing) |
| HEAD has `.md` + `.json`, schema-incomplete | rc=34, halt `plan-contract-incomplete` (existing) |
| Worktree dir absent (`! -d $wt`) | fail-open (unchanged from current line 1087); upstream preconditions already handle it |
| `git ls-tree HEAD` fails (e.g., bare repo, no HEAD) | empty stdout → treated as no committed plan → halt `plan-contract-missing`. The diagnostic body explicitly mentions HEAD-tree query so the operator can distinguish from "agent didn't write." |

Sanitisation in the diagnostic body uses the existing `_post_plan_contract_halt`
sub-replace (`safe="${raw//<!--/<\\!--}"`, line 1125) — no new injection
surface.

## Edge cases

1. **Cross-midnight planning re-dispatch.** The today-only date prefix is
   the reason fail-open exists today. The fix loosens the basename pattern
   to `[0-9]{4}-[0-9]{2}-[0-9]{2}-.*${ident_lower}`, so yesterday's
   committed plan satisfies the gate. Validated by a new test fixture.

2. **Operator-resume after credit fix.** Operator restores the
   account/credits, then runs `bash bin/pipeline.sh decide ENG-N --action continue`.
   `--action continue` clears `pipeline:halted` and the skip label; next tick
   re-polls ENG-N, sees `stage:planning`, dispatches planning again. The new
   planning run writes + commits the artifact; the gate passes; transition
   to implementing fires. Standard recovery flow; no special handling
   needed.

3. **Operator manually commits the plan and re-runs `decide --action continue`.**
   Acceptable: the gate sees the committed `.md` in HEAD, validates the
   `.json`, returns 0; the orchestrator's verdict_handler reads the fresh
   verdict marker (the one the failed dispatch posted) and transitions. The
   operator's commit is honoured.

4. **Plan committed but `.json` missing or malformed.** Already handled by
   the existing schema-validator tail. The fix preserves this path
   unchanged (rc=33/34/35 with their existing halt-comment bodies).

5. **Plan committed but `linear:` frontmatter points to a different issue
   (foreign plan).** The plan-schema validator's `issue_id` field check
   asserts the JSON's `issue_id` matches `--ident "$ident"` (already
   enforced via `^ENG-[0-9]+$` pattern check; see `bin/plan-schema.sh`).
   Net: a foreign plan satisfies the basename glob but fails the JSON
   ident check, producing `plan-contract-incomplete` (rc=34). Acceptable —
   the operator sees the diagnostic and knows the wrong ident landed.

6. **Multiple plan files committed (mid-flight re-attempts).** `sort |
   tail -1` picks the latest by ISO-date string sort. The validator's
   schema check runs against that one. Older plan files are ignored. This
   matches the today-only behaviour: only the latest plan is verified.

7. **The planning agent's verdict marker is itself dispatch-id-stale.**
   ENG-87's `find_fresh_verdict` strict id-match already filters out
   prior-dispatch verdict markers; if the dying dispatch posted its
   `verdict=pass` with the current `PIPELINE_DISPATCH_ID` baked in (which
   it does via `_inject_dispatch_marker`), then a *next* dispatch's
   `find_fresh_verdict` won't see it (id mismatch). This means our gate is
   load-bearing only WITHIN the failing dispatch's own `run-stage.sh::main`
   — exactly where `_validate_plan_contract` already runs, post-dispatch
   pre-verdict_handler. Good: the fix is in the right place.

## Testing (TDD)

New / extended fixtures in `bin/run-stage-test.sh`:

1. **INT-R (committed pair → rc=0, transitions):** Create a per-issue
   worktree with `git init`, write + commit
   `docs/plans/${today}-eng-179r-test.md` (any valid frontmatter) plus
   sibling `.json` (minimal schema-v1 fixture from
   `_eng122_write_valid_json`), then call `_validate_plan_contract ENG-179R`
   and assert rc=0, empty CAPTURE_FILE. Drives acceptance criterion (a).

2. **INT-S (no committed artifact → rc=35, halts):** Per-issue worktree
   with `git init` and an *initial* commit (so HEAD exists), but no plan
   file anywhere. Call `_validate_plan_contract ENG-179S`; assert rc=35,
   halt comment carries `<!-- pipeline: verdict result=halt
   reason=plan-contract-invalid -->` and `Defect: plan-contract-missing`.
   Drives acceptance criterion (b) and replaces the existing INT-Q
   fail-open assertion at `bin/run-stage-test.sh:4583-4596`.

3. **INT-T (written-but-uncommitted → rc=35, halts):** Per-issue worktree
   with `git init` + initial commit, plan `.md` + `.json` written to the
   worktree but NOT `git add`-ed. Call `_validate_plan_contract ENG-179T`;
   assert rc=35 with `plan-contract-missing`. Drives acceptance criterion
   (c) — this is the case that distinguishes HEAD-tree-check from
   worktree-find.

4. **INT-U (cross-midnight resume → rc=0, transitions):** Per-issue
   worktree with a committed plan whose date prefix is `yesterday`
   (compute as `$(date -u -v-1d +%Y-%m-%d)` on macOS / `$(date -u -d "yesterday" +%Y-%m-%d)` on
   Linux — both are macOS-compatible per CLAUDE.md "Bash 3.2+, macOS-compatible").
   Call `_validate_plan_contract`; assert rc=0. Regression guard against the
   broken loose-pattern change.

5. **INT-Q replacement:** the existing test at `bin/run-stage-test.sh:4583-4596`
   asserting "plan .md missing → fail-open (rc=0)" flips to "plan .md missing
   → rc=35". Documented in the test diff as an intentional behaviour change
   with a `# ENG-179: was fail-open, now strict-halt; see brainstorm.` marker.

All five tests use the existing `STUB_DIR`-and-source pattern, the existing
`plan-schema.sh` STUB_DIR delegation (lines 4396-4400), and the existing
`_eng122_write_valid_json` helper.

Run the full `bin/*-test.sh` sweep (the pre-commit gate) green before commit.

## Out of scope

- Reworking session-limit / out-of-credits death handling itself (separate
  concern; `session-limit-false-halts` operator memory).
- The implement-side `scope-check rc=2` "plan not found" path — already
  correct as a defence-in-depth backstop; intentionally untouched.
- Generalising the gate to other stages' artifact contracts (rejected as
  premature generalisation in §"Rejected alternative — dedicated
  transition-gate").
- Moving the partition-sweep before `verdict_handler` (rejected as
  cross-cutting refactor).
- Hardening `verdict_handler` to refuse pass verdicts whose body claims a
  file that's not in HEAD — out of scope; the validator pattern already
  enforces this at the right layer.

## Acceptance criteria

1. A `planning` dispatch that emits `verdict=pass` but leaves zero
   committed plan artifact on the branch (HEAD tree) does NOT transition to
   implementing; the issue stays at `stage:planning`. (Driven by INT-S.)
2. A `planning` dispatch that writes the plan into the worktree but does
   not commit it does NOT transition; the issue stays at `stage:planning`.
   (Driven by INT-T.)
3. The halt comment carries `<!-- pipeline: verdict result=halt
   reason=plan-contract-invalid -->` with `Defect: plan-contract-missing`,
   naming the missing-committed-artifact cause explicitly (not the
   downstream `scope-check rc=2`).
4. A `planning` dispatch with the committed `.md` + sibling `.json` pair
   transitions cleanly. (Driven by INT-R, regression guard.)
5. Cross-midnight planning re-dispatch on yesterday's committed plan still
   transitions cleanly. (Driven by INT-U.)
6. Existing INT-K / INT-L / INT-M / INT-N / INT-O / INT-P tests stay green
   under the new HEAD-tree query (note: INT-K, INT-L, INT-M, INT-O all
   write directly to the worktree filesystem — those tests will need
   `git init && git add && git commit` added to their setup, otherwise the
   tightened gate will halt them with `plan-contract-missing`; this is a
   mechanical test-fixture update, not a contract change).
7. INT-Q is intentionally replaced; its current "fail-open on absent .md"
   assertion is the bug.
8. Full `bin/*-test.sh` suite passes (the pre-commit gate).
9. CLAUDE.md "Failure-mode quick reference" adds a row for the
   `plan-contract-missing` halt with recovery via `decide --action
   continue` after operator-investigation of the underlying cause
   (commonly: session-limit credit death; see
   `session-limit-false-halts`). Symptom phrasing should explicitly
   contrast with the existing `scope-check rc=2` row (per product
   persona P1-2): something like *"Issue at `stage:planning` halts
   with `plan-contract-missing` defect immediately after a planning
   dispatch (no implement dispatches consumed) — contrast with
   `scope-check rc=2` which fires post-transition at
   `stage:implementing` after burning the implement_rejection budget."*

## Open questions

1. **OQ-1 — should the gate also assert the agent self-committed (vs the
   orchestrator-sweep committed)?** Today the partition-sweep at
   `bin/run-local.sh:226-317` runs *after* `run-stage.sh` returns rc=0, so
   any uncommitted plan would not yet be in HEAD when `_validate_plan_contract`
   runs. Under the new design, this means the agent MUST self-commit (or
   halt). That matches the agent prompt's step 4 ("Commit artifacts… on
   the feature branch with message `chore(pipeline): plan for {issue_id}`",
   AGENT_PROMPTS.md:627-630), so there is no contract divergence — but it
   does remove the sweep as a safety net specifically for the plan-pair.
   **Recommendation:** accept this as a strengthening of the agent
   contract. **Implementation note (per design persona P1-1):**
   "agent self-commit is now load-bearing for the planning gate's
   correctness" should appear as a one-line comment immediately above
   the new pseudocode block in `_validate_plan_contract`, so future
   readers don't mistake it for a soft check. If the sweep-as-safety-net
   for plan files is later judged necessary, the fix is structural
   (reorder sweep before verdict-handler), not a softening of this gate.

2. **OQ-2 — should the diagnostic body link `session-limit-false-halts`
   recovery steps inline?** The operator memory advises checking the log
   before re-running; the halt comment could include a one-liner. The
   current `_post_plan_contract_halt` body is already operator-actionable
   (names the defect, points at the schema, gives the `decide --action
   continue` command). A reference to "common cause: session-limit"
   inside the diagnostic might prevent operators from blaming code first.
   **Recommendation:** include a single-sentence reference. The cost is
   one line of body text; the value is non-trivial for the operator
   on-call at 03:00.

3. **OQ-3 — should we also tighten the existing today-only date prefix in
   the matched basename?** The current `${today}-*${ident_lower}-*.md`
   pattern already mis-matches across midnight; the fix removes the
   today-anchor entirely. A residual question: should we cap the
   basename match to the *current dispatch's* plan only, to prevent a
   stale prior-day plan from satisfying the gate after the operator
   abandoned that plan via `--action abandon`? **Recommendation:** no —
   `--action abandon` clears the issue from the pipeline; if the
   operator re-opens, a new planning dispatch would write a fresh plan
   and `sort | tail -1` would pick the new one. The stale-prior-day case
   only matters if the operator intends to RE-RUN planning on the same
   issue without abandoning, which is the cross-midnight resume case
   we explicitly want to support.

## Anti-bias checks

### ADR stress test

There is no formal ADR ledger in `docs/` (only `docs/architecture.md` and
`docs/assumptions.md`). The closest invariant this change touches is the
*"validators sit between dispatch return and `verdict_handler`"* pattern
established by `_validate_dispatch_envelope`, `_validate_plan_contract`,
and `_validate_review_payload`. The fix strengthens that pattern; no
existing decision is overturned. The agent-side contract that "plans are
committed by the agent, not by the sweep" is documented in
`AGENT_PROMPTS.md` §2 step 4 — this design relies on that contract
remaining authoritative.

### Simpler alternative

The simplest possible fix is *just* replacing the `return 0` at
`bin/run-stage.sh:1103` with `_post_plan_contract_halt … 'plan-contract-missing'
…; return 35`, leaving the worktree-`find` substrate alone. This would
satisfy acceptance criterion (b) (no artifact → halt) but not (c)
(written-but-uncommitted → halt) — `find` would still see the worktree
file. The HEAD-tree switch is the load-bearing addition for (c); without
it, the issue's stated requirement is not met.

### Assumption inventory

Every item below is verified against the worktree at the file:line cited.

- `bin/run-stage.sh::_validate_plan_contract` exists at lines 1082-1118 —
  **verified** (`bin/run-stage.sh:1082`).
- The fail-open absent-md branch is at lines 1101-1104 — **verified**
  (`bin/run-stage.sh:1101`).
- `_post_plan_contract_halt` exists and sanitises agent-controlled text
  with `<!--` → `<\!--` — **verified** (`bin/run-stage.sh:1123-1130`).
- `_validate_plan_contract`'s caller routes return 35 through
  `classify_failure … skip-until-human-acts` and exits — **verified**
  (`bin/run-stage.sh:1925-1937`).
- Exit code 35 maps to `plan-contract-missing` in the failure taxonomy —
  **verified** (`bin/common.sh:334`).
- The planning agent prompt requires step 4 commit of `.md` + `.json` —
  **verified** (`AGENT_PROMPTS.md:627-633`).
- `bin/scope-check.sh::find_canonical_plan` does worktree-find and exits 2
  on absent plan (the downstream "plan not found" symptom) — **verified**
  (`bin/scope-check.sh:142-156, 286-287`).
- The partition-sweep in `run-local.sh` runs after `run-stage.sh` returns
  rc=0 — **verified** (`bin/run-local.sh:205-207, 226-317`).
- `verdict_handler` is called inside `run-stage.sh::main` after the
  validators — **verified** (`bin/run-stage.sh:2019`).
- `apply_transition` flips `stage:` labels and removes `pipeline:halted` —
  **verified** (`bin/verdict-handler.sh:309-430`).
- `find_fresh_verdict`'s strict dispatch-id filter excludes prior-dispatch
  verdict markers — **verified** (`bin/verdict-handler.sh:156-200`).
- The existing INT-Q test (line 4583-4596) asserts `plan .md missing →
  fail-open (rc=0)` and will need to flip — **verified**
  (`bin/run-stage-test.sh:4583-4596`).
- The existing INT1 (122-K), INT2 (122-L), INT3 (122-M), INT4 (122-N),
  INT5 (122-O), INT-P (122-P) tests use worktree-`find` setup and will need
  `git init && git add && git commit` added to their fixtures —
  **verified** (`bin/run-stage-test.sh:4388-4596`).
- `git ls-tree --name-only -r HEAD -- docs/plans/` returns committed paths
  in a per-issue worktree — **assumed** (the worktree is created via
  `git worktree add` from the target repo's HEAD per the harness setup;
  HEAD is always a valid ref in a worktree as long as a commit exists).
  Risk: a fresh-init worktree with no commits would fail the gate. The
  worktree-creation path commits an initial state before dispatch, so this
  is not a realistic state; the failure mode (rc=35) is also operator-safe.
- The `plan-schema.sh validate` invocation accepts the JSON path as
  `$wt/$plan_json` (worktree-relative) — **verified**
  (`bin/run-stage.sh:1108-1109`). The HEAD-tree-found `plan_md` is also a
  worktree-relative path (since `git ls-tree` strips the worktree root),
  so the concatenation `$wt/$plan_json` remains correct.

## Persona review

Internal record of the six persona passes run via the document-review
skill. Replace each stub with the resolved verdict + findings before
declaring iteration complete.

| Persona | Verdict | Notes |
|---|---|---|
| design | PASS | The targeted-tighten approach matches the established validator pattern; rejected alternatives are addressed with reasons. |
| security | PASS | Diagnostic body sanitisation preserved via existing `_post_plan_contract_halt` substitution; no new injection surface. |
| scope | PASS | Strictly inside the issue's "IN" scope; the explicit OUT items (session-limit handling, implement-side scope-check) are untouched. |
| coherence | PASS | The fix reads as a single tightening of one function; the existing taxonomy and caller routing make the change ~5 lines plus tests. |
| product | PASS | Operator-visible failure mode names the right cause; recovery path is the standard `decide --action continue` (no new operator vocabulary). |
| feasibility | PASS | All code-level references verified at file:line in the assumption inventory; no `find`/grep guesses; HEAD-tree query is a stable `git ls-tree` invocation; existing tests reroute via known fixture helper. |

Gate: **6/6 PASS · feasibility P0: 0 · proceeding to planning.**

## References

- `bin/run-stage.sh::_validate_plan_contract` (~L1082-1118); caller routing
  (~L1925-1937); halt-comment poster (~L1123-1130).
- `bin/common.sh::failure_outcome_for_exit` (L305-341, especially L334 for
  `plan-contract-missing`).
- `bin/run-local.sh` partition-sweep + commit (~L226-317).
- `bin/verdict-handler.sh::find_fresh_verdict` (L156-250) and
  `apply_transition` (L309-430).
- `bin/scope-check.sh::find_canonical_plan` (L142-156) — the downstream
  symptom-surface this brainstorm prevents reaching.
- `AGENT_PROMPTS.md` §2 step 4 (L627-633) — agent's commit contract.
- `bin/run-stage-test.sh` (~L4388-4596) — existing INT1-INT5 + INT-P,
  INT-Q fixtures and their STUB_DIR delegation pattern.
- ENG-122 (introduced `_validate_plan_contract` and the
  `plan-contract-*` taxonomy).
- ENG-87 (`PIPELINE_DISPATCH_ID` strict id-match in `find_fresh_verdict`).
- ENG-125 (the observed-instance incident, 2026-06-10).
- Operator memory: `session-limit-false-halts` (the underlying failure
  mode); `scope-approval-resume-broken-eng180` (related: scope-violation
  resume is broken, but not relevant here).
