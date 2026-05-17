---
linear: ENG-145
title: guards — extend the ENG-138 stage gate to qa_rejection and implement_rejection
date: 2026-05-17
status: draft
---

# ENG-145 — `guards.sh` qa_rejection / implement_rejection counters missing the ENG-138 stage gate

## 1. Overview

ENG-138 (commit `444e752`, merged 2026-05-17) narrowed the
`review_rejection` halt in `bin/guards.sh` so it fires only when the
dispatched stage is `implementing` — the loopback-continuation edge.
The fix scoped the gate at `bin/guards.sh:129`:

```bash
if (( rev >= review_threshold )) && [[ -z "$stage" || "$stage" == "implementing" ]]; then
  tripped+="review_rejection($rev>=$review_threshold) "
fi
```

The same false-positive shape exists for the other two rejection
counters at `bin/guards.sh:138-143`:

```bash
if (( qa >= qa_threshold )); then
  tripped+="qa_rejection($qa>=$qa_threshold) "
fi
if (( impl >= impl_threshold )); then
  tripped+="implement_rejection($impl>=$impl_threshold) "
fi
```

Neither has the stage gate. ENG-138 fixed the review half of a
symmetric three-counter contract; the qa and implement halves were
left in the pre-ENG-138 state. This brainstorm applies ENG-138's
pattern symmetrically.

Both counters' loopback target is `implementing`
(`bin/verdict-handler.sh:35-37` — `reviewing|implementing|`,
`qa|implementing|`, `building|implementing|`). The next loop iteration
burns agent budget at the next `implementing` dispatch and nowhere
else, so that is the only edge where halting helps. Firing on a
forward exit edge (`qa → building`, `implementing → ui`) penalises
the agent for converging — the inverse of the counter's purpose,
the exact bug ENG-138 fixed for review.

This is preventive, not reactive. ENG-138 OQ-1 and OQ-2 flagged both
shapes as follow-up hypotheses; ENG-123 has not yet recurred on the qa
side because no in-flight issue has cycled `qa → impl → qa → impl →
qa PASS → building` to threshold since the ENG-116 cutover.

## 2. Goal

After ENG-145 lands:

- **AC#1.** After N consecutive `qa → implementing` rejections
  (default threshold 2), guards halt the next `→ implementing`
  dispatch. Mirror of ENG-138 AC#2 for the qa_rejection counter.
- **AC#2.** After a clean `qa` PASS, the `qa → building` forward
  transition is NOT blocked by the cumulative `qa_rejection` counter.
  Mirror of ENG-138 AC#1 for the qa_rejection counter.
- **AC#3.** After N consecutive `implement_rejection` bumps, guards
  halt the next `→ implementing` dispatch (the next post-resume
  implementing pass). Mirror of ENG-138 AC#2 for the
  `implement_rejection` counter.
- **AC#4.** Operator-resume still resets all three counters
  (ENG-116 contract preserved; reset semantics unchanged because the
  reset is computed by `count_marker_since_last_operator_resume` at
  `bin/guards.sh:77-96`, untouched).
- **AC#5.** Empty-stage CLI invocation (`bash bin/guards.sh check
  ENG-N` with no stage arg) preserves trip-as-today behaviour for
  back-compat with operator triage and the existing
  `bin/run-stage-test.sh::case-15` regression — mirror of ENG-138's
  line 129 `[[ -z "$stage" || ... ]]` pattern.
- **AC#6.** `bin/guards-test.sh` covers the qa and implement
  parallels of ENG-138's case-1/case-2/case-3 trio. The existing
  `case-9` (which asserts `qa_rejection` trips at `stage=qa`) is
  inverted — see §4 D-3.
- **AC#7.** Pre-commit hook (`.githooks/pre-commit`, every
  `bin/*-test.sh`) stays green.

## 3. Architectural principle this extends

The harness has **no formal ADR registry** — verified: `ls docs/`
returns `architecture.md assumptions.md brainstorms/ configuration.md
cost.md install.md operations.md pipeline-vocabulary.md
pipeline-vocabulary.template.md plans runbooks security.md`. No
`VISION.md`. No `docs/knowledge/decisions.md`. Governing constraints
are `CLAUDE.md`, `docs/architecture.md`, and
`learned-rules/<slug>/project-profile.md`. No new ADR is proposed —
ENG-145 is a single-file behavioural symmetry fix, the same shape
ENG-138 shipped under.

ENG-145 extends two existing implicit principles, both of which
ENG-138 already invoked verbatim:

1. **Single human-approval gate (`CLAUDE.md::"Single human-approval
   gate (ENG-54)"`).** Review/QA are agent-only on PASS; the
   orchestrator advances `qa → building` automatically on a clean
   verdict. A guards halt that fires *after* the transition is
   applied but *before* the next stage dispatches silently
   re-introduces a human gate the reframe explicitly removed. ENG-145
   restores the invariant on the qa edge that ENG-138 restored on
   the reviewing edge.

2. **ENG-116's loop-termination claim (`bin/guards.sh:9-21`).**
   ENG-116's prose says the counters "let review/implement loops
   churn indefinitely" — the loops, not the forward edges. Scoping
   each counter's halt to its loopback target is the literal
   expression of that claim.

No existing decision is overturned. The ENG-138 commit message
(`444e752 — fix(guards): scope review_rejection halt to implementing
stage`) describes the pattern this brainstorm extends; the
reset-side semantic from ENG-116 is left intact.

## 4. Decisions

Each decision is **D-N: \<verdict\>** + Why + rejected alternatives.
Every reference cites a concrete `path:line`.

### D-1: Apply ENG-138's stage-gate pattern symmetrically to `qa_rejection` and `implement_rejection`.

**Verdict.** Both trips at `bin/guards.sh:138-143` gain the
`[[ -z "$stage" || "$stage" == "implementing" ]]` clause, identical
in shape to the `review_rejection` clause at line 129. The counters
still accumulate across loopback cycles (computed by
`count_marker_since_last_operator_resume`); only the firing-side
semantic narrows. Reset semantics from ENG-116 are unchanged.

**Why.** Both counters' loopback target is `implementing`
(`bin/verdict-handler.sh:35-37`). The downstream consumer of the
loopback edge is the next `implementing` dispatch; that is the only
stage where halting before dispatch prevents the next loop
iteration from burning agent budget. Firing the same threshold on
any other stage (forward edge after a converging pass, or a
midstream stage like `building` after a clean `qa`) penalises the
agent for converging — the inverse of the counter's stated purpose.
By direct symmetry with ENG-138 D-1.

For `qa_rejection` specifically, the reproduction shape mirrors
ENG-123 exactly: `building → REJECT(merge_conflict) → implementing
(rebase) → ui → reviewing → qa → REJECT → implementing → ui →
reviewing → qa → REJECT → implementing → ui → reviewing → qa PASS →
building`. At the final `qa → building` forward transition the
cumulative `qa_rejection` counter is at the threshold; today the
guard trips and halts. After D-1, it does not.

For `implement_rejection`, the failure shape is narrower in current
practice (per the Linear ticket's own analysis): the bumps at
`bin/run-stage.sh:1684, 1690, 1732` all fire on scope-violation /
noop-implementation halts which apply `pipeline:skip-until-human-
acts`, requiring `--action continue` to resume. That resume posts
the operator-resume waypoint, which resets the counter via
`count_marker_since_last_operator_resume`. So in steady state the
counter rarely reaches 2 from the scope-violation path alone.
Two reasons to still apply the symmetry fix:

- The asymmetry with `review_rejection` is itself a latent foot-gun.
  Any future code path that bumps `implement_rejection` outside the
  resume flow (e.g., a non-halting "soft warning" bump) inherits
  ENG-138's exact bug. The ticket was filed preventively, and the
  marginal cost of the fix is one additional line.
- The fix lets the ticket's AC#3 be tested by the same source-and-
  stub fixture pattern as AC#1, with the same minimum-viable diff.

**Rejected alternative — Option (b) of ENG-138 redux: reset
counter on a passing verdict (qa or reviewing).** Treat a passing
verdict as loop-exit and zero the counter window from that point.
Rejected for the same three reasons ENG-138's D-1 rejected its
Option (b):

- ENG-116's stated intent (`bin/guards.sh:9-21`) is that counters
  "accumulate across loopback cycles and are cleared ONLY by an
  operator-resume waypoint." Pass-clears conflicts with that intent;
  a sequence like `qa REJECT → impl → qa REJECT → impl → qa PASS →
  building → REJECT(merge_conflict) → impl → qa REJECT → impl → qa
  REJECT → impl → ...` would silently reset the qa_rejection budget
  on the transient pass, hiding the long-term churn ENG-116 wants
  the operator to see.
- The counter's audit value (operator runs `bin/linear.sh
  get-comments` and counts `<!-- meta: metric name=qa_rejection -->`
  bodies for triage) is degraded — the operator-visible total no
  longer matches the threshold-relevant total.
- It's strictly weaker than D-1: D-1 fully preserves ENG-116's
  reset-side contract and only narrows the *check* side.

**Rejected alternative — Option (c) of ENG-138 redux: split each
counter into two (consecutive-in-current-loop-run + lifetime).**
Rejected because:

- Adds two new marker shapes (`<!-- meta: metric
  name=qa_rejection_consecutive -->`, similarly for implement) and
  two new clearing rules. The pipeline vocabulary registry at
  `bin/pipeline-events.json` and the docs at
  `docs/pipeline-vocabulary.md` would both need expansion.
- Touches three subsystems (orchestrator counter logic, pipeline
  vocabulary, retrospective metrics) vs D-1's one (orchestrator
  counter logic). Per CLAUDE.md's ticket sizing rubric, that
  exceeds the "1 subsystem … autonomy-safe" envelope ENG-138 shipped
  in. The Linear ticket's `Sizing rubric check` matches D-1, not (c).
- D-1 is reversible: a future ticket that needs the
  consecutive-in-current-loop semantic can layer it on without
  rework.

**Rejected alternative — gate the call in `bin/run-stage.sh`
instead of inside `bin/guards.sh::check`.** I.e., the run-stage
caller skips invoking guards entirely when `stage != implementing`.
Rejected because `guards.sh check` also computes the
`gotcha_triggered` / `learned_rule_renewal` thresholds — those are
lifetime counters by design (`bin/guards.sh:117-118, 132-136`) and
must keep firing on every stage. Skipping the whole call would
silently disable those checks on every non-implementing dispatch
(a regression on every brainstorm/plan/ui/review/qa/build/release
tick). The fix has to live inside guards.sh::check so only the
rejection arms of the gate are narrowed.

**Rejected alternative — apply the gate only to `qa_rejection`,
leave `implement_rejection` alone.** I.e., interpret the Linear
ticket's "implement_rejection failure shape is narrower" remark as
a reason to defer that half. Rejected because:

- The Linear ticket explicitly includes implement_rejection in its
  AC#3 and its IN: scope clause. Splitting now would violate the
  ticket's stated scope.
- The marginal cost is one line of code + one test case. Splitting
  would itself be more work than including.
- The asymmetry-as-foot-gun argument applies: any future bump-site
  that doesn't immediately halt for resume inherits the bug.
  Closing the gap now keeps the three counters in lockstep.

### D-2: Implementation site — modify exactly the two trips at `bin/guards.sh:138-143`.

**Verdict.** Two lines change. After:

```bash
if (( qa >= qa_threshold )) && [[ -z "$stage" || "$stage" == "implementing" ]]; then
  tripped+="qa_rejection($qa>=$qa_threshold) "
fi
if (( impl >= impl_threshold )) && [[ -z "$stage" || "$stage" == "implementing" ]]; then
  tripped+="implement_rejection($impl>=$impl_threshold) "
fi
```

No change to `bin/run-stage.sh:1261, 1263` — ENG-138 already
threaded `$stage` through both `guards.sh check` call sites. Verified
read on those lines this dispatch.

No change to `count_marker_since_last_operator_resume` at
`bin/guards.sh:77-96` — already invoked for `qa_rejection` (line
119) and `implement_rejection` (line 120). Reset semantics intact.

**Why.** Two ~6-character edits, one bash file, no call-site
change, no schema change, no marker change. Reversible via a single
revert. Matches the minimum-viable shape ENG-138 itself shipped.

The empty-stage `[[ -z "$stage" || ... ]]` clause preserves
back-compat for direct CLI invocations
(`bash bin/guards.sh check ENG-N` with no stage arg still trips
exactly as today). This matters for `bin/status.sh`-style triage
flows and for the existing `bin/run-stage-test.sh::case-15` which
calls guards directly with `ENG-T15` and no stage. Identical
pattern to line 129; the clause is established harness shape.

**Rejected alternative — extract a helper
`_should_trip_loopback_counter(stage)`.** Rejected because:

- The clause is six characters of bash logic. Wrapping it in a
  named function adds indirection without reducing repetition; the
  three call sites would still each call the helper, and the
  intent ("trip only when about to enter the implementing
  loopback target") is more obvious inline.
- Existing pattern at line 129 is unwrapped. Extracting would
  introduce one wrapped invocation and leave two unwrapped, which
  is worse than three unwrapped uniform clauses.

**Rejected alternative — pass an enum like
`--loopback-source=qa`.** Rejected because the intent is "halt
before this stage runs another loop iteration", fully captured by
the dispatched stage. Naming the source of the loopback would
require the caller to know which counter belongs to which loop —
knowledge that lives entirely inside `guards.sh`.

### D-3: Test placement — invert existing `bin/guards-test.sh::case-9`; add three new cases (one trip-at-implementing per counter, plus an operator-resume reset).

**Verdict.** Edit `bin/guards-test.sh`. Inverted and added cases
land at the bottom of the file, immediately after the existing
`case-9` block (`bin/guards-test.sh:269-302`).

**Case-9 inversion (mandatory).** The fixture (two `qa_rejection`
markers, no operator-resume, stage=qa) is correct; the assertion is
not. Today: expect rc=10 and trip text. After ENG-145: expect rc=0
and `guards: clear`. The case's body comment ("ENG-138 narrowing is
review_rejection-only") becomes false on this PR; rewrite the
comment to read "ENG-145 narrowing extends to qa_rejection: trip
fires only at stage=implementing." Without this inversion the new
trip-gate is contradicted by an existing test and the pre-commit
hook fails the moment the gate is added.

**New case-10: `qa_rejection` trips at stage=implementing.** Stub:
two `qa_rejection` markers, no operator-resume. Invoke `bash
bin/guards.sh check ENG-T145A implementing`. Assert rc=10, output
contains `qa_rejection(2>=2)`. Mirrors AC#1.

**New case-11: `qa_rejection` does NOT trip at stage=building
(forward edge after qa PASS).** Stub: same as case-10. Invoke
`bash bin/guards.sh check ENG-T145B building`. Assert rc=0,
`guards: clear`. Mirrors AC#2.

**New case-12: `implement_rejection` trips at stage=implementing.**
Stub: two `implement_rejection` markers, no operator-resume. Invoke
`bash bin/guards.sh check ENG-T145C implementing`. Assert rc=10,
output contains `implement_rejection(2>=2)`. Mirrors AC#3.

**New case-13: operator-resume waypoint resets both counters.**
Stub: two `qa_rejection` markers + two `implement_rejection`
markers + a newer `<!-- pipeline: transition from=implementing
to=implementing reason=operator-resume -->`. Invoke `bash
bin/guards.sh check ENG-T145D implementing`. Assert rc=0
(both counters reset). Mirrors AC#4.

**Case-15 in `bin/run-stage-test.sh:1523-1635` stays unchanged.**
It invokes `guards.sh check ENG-T15` with no stage arg; the
empty-stage branch of D-2's clause trips exactly as today. AC#5
satisfied without modification.

**Why.** No new test file. `bin/guards-test.sh` is the established
home for guards-policy assertions per the ENG-138 conventions.
Three new cases is the same shape ENG-138 introduced
(`case-1`/`case-2`/`case-3`). Including the operator-resume reset
case (case-13) keeps the three-counter contract symmetric in
fixtures: pre-ENG-145 the suite only exercised reset for
`review_rejection` via case-3, leaving qa/impl reset paths
uncovered.

The case-9 inversion is unavoidable: ENG-138 introduced case-9 to
*defend* the qa_rejection-at-stage=qa trip on the explicit
assumption "ENG-138 narrowing is review_rejection-only". ENG-145
removes that defense; the case must flip in lockstep. Failing to
flip it would block the pre-commit hook (AC#7).

**Rejected alternative — write the new cases without flipping
case-9; instead delete case-9 entirely.** Rejected because:

- The case-9 fixture is good and reuse-worthy; deleting it loses
  the test of "qa_rejection trip is *narrowed*, not removed." The
  inverted assertion ("does NOT trip at stage=qa") is itself a
  regression guard against a future overcorrection that removes
  the trip entirely.
- Deletion + addition is more diff churn than in-place inversion.

**Rejected alternative — fold the new cases into
`bin/run-stage-test.sh`'s case-15 area.** Rejected for the same
reasons ENG-138 D-3 rejected the equivalent: case-15 verifies the
cross-cut between run-stage.sh's call site and guards.sh's internal
logic; the new cases are intrinsic to `guards.sh::check` and don't
need the fake-repo overlay. `bin/guards-test.sh` is the right
file by ENG-138 precedent.

### D-4: Documentation — extend `bin/guards.sh:21-27` header comment to name all three counters.

**Verdict.** One paragraph edit. The current header (lines 21-27)
reads:

> ENG-138 narrows the firing-side: the review_rejection threshold
> trips only when the dispatched stage is 'implementing' (the
> loopback continuation edge). Reaching qa after a clean reviewing
> PASS no longer halts even when the cumulative count is at or
> over the threshold. ...

Extend to:

> ENG-138/ENG-145 narrow the firing-side for all three rejection
> counters: each threshold (review_rejection, qa_rejection,
> implement_rejection) trips only when the dispatched stage is
> 'implementing' — the loopback continuation edge shared by all
> three loops (verdict-handler.sh:35-37). Reaching a downstream
> stage after a clean upstream PASS no longer halts even when the
> cumulative count is at or over the threshold. The counter still
> accumulates across loopback cycles for operator audit (visible
> in the 'guards: clear' log line), and reset semantics
> (operator-resume waypoint clears) are unchanged.

Also update the usage block at `bin/guards.sh:38-45` if it
mentions the review-only narrowing; currently it says "the
review_rejection trip is scoped to stage == implementing" — extend
to "the review_rejection, qa_rejection, and implement_rejection
trips are scoped to stage == implementing."

**Why.** The header comment is the in-file documentation of the
counter contract; ENG-138 added it precisely so future readers
could see the firing-side scoping rule. Leaving review_rejection
named alone in a file that gates all three is the same hazard the
post-ENG-138 misread of case-9's comment ("ENG-138 narrowing is
review_rejection-only") created — the comment becomes a lie the
moment the next ticket lands.

**Rejected alternative — add a row to CLAUDE.md "Failure-mode
quick reference".** Rejected as scope creep:

- The CLAUDE.md table already carries the ENG-138 row for the
  reviewing → qa shape. The qa → building shape has not been
  observed in the wild yet (this is preventive); adding a
  speculative row dilutes the table's value as an
  observed-incident index.
- The header comment + the new test cases cover the operator-
  recognition need without expanding CLAUDE.md. A row can be
  added in a follow-up if the qa-side shape is observed.

**Rejected alternative — write a runbook entry under
`docs/runbooks/`.** Rejected for the same reason ENG-138 D-4
rejected it: one-shot semantic refinement, not an ongoing
operator workflow.

## 5. Architecture (where code goes)

| Site | Change |
|---|---|
| `bin/guards.sh:21-27` | Extend header comment per D-4 (one paragraph). |
| `bin/guards.sh:38-45` | Update usage comment to name all three counters per D-4. |
| `bin/guards.sh:138-143` | Add `[[ -z "$stage" || "$stage" == "implementing" ]]` clause to both trips (D-2). |
| `bin/guards-test.sh:269-302` | Invert case-9: expected rc 10 → 0; assert `guards: clear`; rewrite the in-test comment (D-3). |
| `bin/guards-test.sh` (after case-9 block) | Add case-10/11/12/13 per D-3. |

No new bash files; no schema changes; no marker changes; no
learned-rules edits; no Linear write changes; no metric stream
changes; no `bin/run-stage.sh` changes (ENG-138 already passes
`$stage`); no CLAUDE.md change.

## 6. Data flow

**Pre-ENG-145 (broken) trip path on the forward edge.**

1. QA agent in C path (all green): writes the stage summary,
   posts `verdict pass --stage qa`, exits
   (`AGENT_PROMPTS.md:1468-1480`).
2. `bin/run-stage.sh::main` post-dispatch calls `verdict_handler`.
   `find_fresh_verdict` returns the pass marker;
   `apply_transition qa building ""` swaps labels.
3. Next tick: `bin/poll.sh` picks up `stage:building`.
   `run-stage.sh ENG-N building` runs. Line 1261 invokes
   `bin/guards.sh check ENG-N building`.
4. `check()` reads the cumulative `qa_rejection` count via
   `count_marker_since_last_operator_resume` (line 119) —
   count is 2+ from prior loopback cycles. Today: threshold tripped
   unconditionally at line 138; rc=10 → `classify_failure` applies
   `pipeline:skip-until-human-acts`; the issue idles until
   operator runs `bin/pipeline.sh decide --action continue`.

**Post-ENG-145 (fixed) trip path on the forward edge.**

1–3 unchanged.
4'. `check()` is now called with `stage=building`. The
   `qa_rejection` threshold check skips because `stage !=
   implementing`. Other trips still evaluate normally. The
   `guards: clear on $ident (rev=$rev got=$got rule=$rule qa=$qa
   impl=$impl)` log line at line 150 still prints `qa=N` so the
   operator can still observe the cumulative count from the
   per-stage transcript.
5'. Dispatch proceeds; building agent runs.

**Post-ENG-145 trip path on the loopback continuation edge
(ENG-116 intent preserved).**

1. QA agent in B path (genuine failure): bumps `qa_rejection`
   (`AGENT_PROMPTS.md:1462`), posts
   `verdict fail --target implementing`, exits.
2. `verdict_handler` applies `qa → implementing` loopback.
3. Next tick: `run-stage.sh ENG-N implementing` runs. Line 1261
   invokes `bin/guards.sh check ENG-N implementing`.
4. `check()` reads count; if count >= threshold AND
   `stage == implementing`, trips. Halts the next iteration of
   the loop — exactly what ENG-116 wants.

**`implement_rejection` parallel.** Bump sites at
`bin/run-stage.sh:1684, 1690, 1732` all fire inside a `stage ==
implementing` dispatch and immediately exit with classify_failure
applying `skip-until-human-acts`. The next dispatch after
`--action continue` is implementing again (same stage label
preserved). Under D-1, the next implementing dispatch's pre-guard
sees the still-accumulated count (the resume waypoint posted by
`decide --action continue` SHOULD have reset it; this is the
ENG-116 contract). If for any reason the counter survives (Linear
outage during resume → marker not posted, or future bump-sites
that don't trigger resume), the gate still fires correctly at the
next implementing dispatch.

## 7. Error handling and edge cases

- **Direct CLI invocation `bash bin/guards.sh check ENG-N` (no
  stage arg).** D-2's `[[ -z "$stage" || ... ]]` clauses preserve
  trip-as-today for all three counters — `bin/status.sh`-style
  triage and `bin/run-stage-test.sh::case-15` semantics unchanged.
- **`bash bin/guards.sh check ENG-N <unknown-stage>`.** Unknown
  stages fall through to "trip only if implementing" — i.e.,
  never trip the rejection arms for unknown stages. Same
  fail-safe as the empty-stage path. ENG-116 intent conserved on
  the only stage where it matters (`implementing`). Mirror of
  ENG-138's unknown-stage handling.
- **`stage:implementing` → guards trip → operator runs
  `pipeline.sh decide --action continue`.** Operator-resume
  waypoint posted; all three counters reset via the existing
  ENG-116 path; next tick's implementing dispatch sees count=0 →
  no trip. Unchanged.
- **Long convergent cycle (`qa REJECT → impl → qa REJECT → impl →
  qa PASS → building`).** Each qa REJECT bumps `qa_rejection`. If
  count reaches threshold before a clean pass, next implementing
  dispatch halts. If the pass lands first (analogue of ENG-123's
  actual sequence on the reviewing side), `qa → building`
  proceeds. Behavior matches ENG-138's documented `reviewing →
  qa` shape.
- **`building → implementing` rebase loopback after a high
  cumulative qa_rejection.** The next implementing dispatch DOES
  see `stage == implementing`, so the qa_rejection threshold IS
  evaluated. If still >= threshold (no operator-resume between),
  halt fires. This is the acknowledged trade-off of D-1 (mirror
  of ENG-138's OQ-3): the counter is lifetime per ENG-116, so a
  re-entry into the implementing loop after a building rejection
  inherits the prior qa loop's exhausted budget. An operator who
  wants to grant a fresh budget runs `--action continue`.
- **All non-implementing stages (`brainstorming`, `planning`,
  `ui`, `reviewing`, `qa`, `building`, `released`) with high
  cumulative qa_rejection or implement_rejection.** No trip.
  Forward progress unblocked. (Note: `reviewing` is interesting
  because it sits between `ui` and `qa` on the forward path; the
  prior reviewing-side gap closed by ENG-138 was qa-stage trips
  on review_rejection. Now no rejection counter trips a forward
  stage. Symmetric.)
- **`stage_drift` race: orchestrator dispatches stage=building
  but Linear label flipped back mid-tick.** Same fail-open
  philosophy as ENG-138's analogous edge case. The drift check
  at `bin/run-stage.sh:1756` exits cleanly BEFORE the
  post-dispatch verdict_handler fires; the pre-dispatch guards
  check happened with `stage=building` (dispatched value), so it
  didn't trip — correct because the actual stage is non-
  implementing, where the trips don't fire either.

## 8. Anti-bias checks (mandatory)

### ADR stress test

No formal ADR registry. The implicit principles ENG-145 puts
pressure on:

- **ENG-116's "loops churn indefinitely" framing
  (`bin/guards.sh:9-21`).** ENG-145 does NOT overturn it — the
  reset-side semantic is left intact, the counters still
  accumulate across loopback cycles, only the check-side firing
  edge narrows. ENG-138 already established this composition;
  ENG-145 applies it to two more counters with no new
  composition risk.
- **ENG-54 "single human-approval gate".** ENG-145 *restores*
  this principle on two more edges (`qa → building`,
  `implementing → ui`). Previously the qa_rejection /
  implement_rejection counters could silently re-introduce a
  human gate on those forward edges in the same way
  review_rejection did on `reviewing → qa` pre-ENG-138.
- **CLAUDE.md ticket sizing rubric.** Linear ticket's sizing
  claim ("1 subsystem … autonomy-safe") matches D-1. Rejecting
  D-1 in favor of D-1's Option (c) (per-counter split) would
  push to 3 subsystems → split-before-filing. D-1 stays inside
  the autonomy-safe envelope. Same calibration ENG-138 shipped.

### Simpler alternative

Documented inline under each decision:

- D-1 rejects pass-clears reset (Option b), per-counter split
  (Option c), run-stage.sh-side gate, and qa-only partial fix.
- D-2 rejects helper extraction and enum-source argument.
- D-3 rejects case-9 deletion and folding new cases into
  run-stage-test.sh.
- D-4 rejects CLAUDE.md row addition and a new runbook entry.

Every rejected alternative has a stated "why-worse" line.

### Assumption inventory

- **Verified** — `bin/guards.sh::check()` body at
  `bin/guards.sh:98-151`; trips for qa_rejection at line 138-140,
  implement_rejection at line 141-143. Read 2026-05-17 this
  dispatch.
- **Verified** — `bin/guards.sh:129` is the existing
  review_rejection trip with the stage gate clause to mirror.
- **Verified** — `count_marker_since_last_operator_resume` at
  `bin/guards.sh:77-96`; invoked for `qa_rejection` (line 119)
  and `implement_rejection` (line 120). Reset semantics
  unchanged by this brainstorm.
- **Verified** — `bin/run-stage.sh:1261, 1263` are the only
  orchestrator call sites of `guards.sh check`; both already
  pass `"$stage"` per ENG-138's earlier change. No
  `bin/run-stage.sh` modification needed by ENG-145. Confirmed
  via `Grep "guards\.sh" bin/run-stage.sh`.
- **Verified** — `bin/run-stage.sh:1684, 1690, 1732` are the
  three `implement_rejection` bump sites; all fire inside
  `stage == implementing` dispatches and immediately
  `classify_failure` with `skip-until-human-acts`. Read this
  dispatch.
- **Verified** — `AGENT_PROMPTS.md:1462` is the QA agent's
  `qa_rejection` bump site (in path-B fail handler). Read this
  dispatch.
- **Verified** — `bin/verdict-handler.sh:35-37` declares all
  three loopback targets as `implementing`:
  `reviewing|implementing|`, `qa|implementing|`,
  `building|implementing|`. Read this dispatch.
- **Verified** — `bin/guards-test.sh:269-302` is the current
  `case-9` block to invert. Its in-test comment ("ENG-138
  narrowing is review_rejection-only") becomes inaccurate the
  moment ENG-145 lands; the implementer must rewrite it
  per D-3.
- **Verified** — `bin/run-stage-test.sh:1523-1635` is the
  existing case-15 regression; calls `guards.sh check ENG-T15`
  with NO stage arg. D-2's empty-stage clause preserves the
  trip-as-today behaviour for all three counters; case-15 stays
  green without modification.
- **Verified** — `.githooks/pre-commit` runs every
  `bin/*-test.sh` (per `CLAUDE.md::"Pre-commit hook"`), so the
  edited `bin/guards-test.sh` is picked up automatically. No
  hook change needed.
- **Verified** — No `docs/VISION.md`, no
  `docs/knowledge/decisions.md` in this repo. Same finding as
  ENG-138; no new ADR proposed.
- **Verified** — `count_marker_since_last_operator_resume`
  fallback path (no operator-resume waypoint exists yet)
  counts all markers across lifetime — `bin/guards.sh:84-88`.
  Confirmed this matches the case-10 fixture shape (two
  qa_rejection markers, no resume → count == 2).
- **Assumed** — `bin/pipeline.sh decide --action continue` posts
  the operator-resume waypoint `<!-- pipeline: transition ...
  reason=operator-resume -->`. Per `bin/guards.sh:11-13` comment
  and `CLAUDE.md::"What --action continue clears (atomic)"`
  step 7. ENG-138 brainstorm relied on the same assumption;
  reset semantics unchanged by this brainstorm.
- **Assumed** — The default threshold of 2 (applied at
  `bin/guards.sh:112-113` when config is absent) is acceptable
  for both qa_rejection and implement_rejection on the
  trip-at-implementing edge. ENG-138 carried the same default
  for review_rejection without observed pain. Worth a
  retrospective look at events.jsonl post-ship for the
  trip-at-implementing path on either counter; not a blocker.

### Codebase-fact verification

Every named file/function/line cited has been opened during this
dispatch:

| Reference | File:line read |
|---|---|
| `check()` body | `bin/guards.sh:98-151` |
| `count_marker_since_last_operator_resume()` | `bin/guards.sh:77-96` |
| header comment (ENG-116/ENG-138 framing) | `bin/guards.sh:9-27` |
| `bump()` body | `bin/guards.sh:153-160` |
| Usage comment | `bin/guards.sh:38-47` |
| `qa_rejection` count read site | `bin/guards.sh:119` |
| `implement_rejection` count read site | `bin/guards.sh:120` |
| `qa_rejection` unguarded trip | `bin/guards.sh:138-140` |
| `implement_rejection` unguarded trip | `bin/guards.sh:141-143` |
| `review_rejection` stage-gated trip (pattern source) | `bin/guards.sh:129-131` |
| run-stage.sh guards call sites | `bin/run-stage.sh:1261, 1263` |
| run-stage.sh `implement_rejection` bumps | `bin/run-stage.sh:1684, 1690, 1732` |
| verdict-handler forward table | `bin/verdict-handler.sh:19-27` |
| verdict-handler loopback table | `bin/verdict-handler.sh:29-38` |
| QA agent path-B `qa_rejection` bump | `AGENT_PROMPTS.md:1462` |
| existing case-9 (to invert) | `bin/guards-test.sh:269-302` |
| Case 15 fixture (no-stage CLI shape) | `bin/run-stage-test.sh:1523-1635` |

No referenced item is a code-level invention; every cited line
has been physically verified.

## 9. Open questions

- **OQ-1.** Should the threshold default change for the now-
  symmetric trio? Currently all three default to 2. Under the new
  semantics, a `qa → impl → qa → impl → qa PASS → building`
  sequence (count=2 then PASS) proceeds; a third REJECT before any
  PASS would halt at the next implementing dispatch. Mirror of
  ENG-138 OQ-4; **OUT** per ticket scope.
- **OQ-2.** ENG-138 OQ-3 asks whether a `qa → implementing`
  loopback after a previously-converged review loop should reset
  the review_rejection counter. The same question applies
  symmetrically: should a `building → implementing` rebase
  loopback reset the qa_rejection counter (or vice versa)? Today
  the counters are lifetime per ENG-116; cross-loop re-entry
  inherits exhausted budget. Defer to evidence; file follow-up
  if observed in the wild.
- **OQ-3.** With all three rejection counters now stage-gated,
  is there value in extracting `_should_trip_loopback_counter`
  per D-2's rejected alternative? Today: no — three uniform
  inline clauses are cleaner than one helper + three call
  sites. If a fourth counter ever joins the rejection family
  (e.g., a hypothetical `ui_rejection`), revisit. **Defer.**
- **OQ-4.** A meta-question prompted by case-9's inversion:
  several test-case comments reference the ticket that
  introduced them ("ENG-138 narrowing is review_rejection-
  only"). When a subsequent ticket changes the semantic, the
  comment becomes a lie. Worth a future retrospective pass to
  audit `bin/*-test.sh` for stale ticket-specific narrative.
  **OUT** of ENG-145 scope.

## 10. Scope-exceeded / conflict flags

- **No scope excess.** Every file edit listed in §5 is inside the
  Linear issue's `IN:` clause (`bin/guards.sh`, `bin/guards-test.sh`
  new cases). The header-comment + usage-comment edits in D-4 are
  inside `bin/guards.sh`, an IN: file.
- **No architectural conflict.** D-1 is a strict refinement of
  the ENG-138 contract on `bin/guards.sh:21-27` extended to two
  more counters — the reset-side semantic ("only operator-resume
  clears the counter") is preserved verbatim for all three
  counters; only the check-side firing edge narrows symmetrically.
- **No CLAUDE.md edit.** Per D-4's rejected alternative, no row
  is added to the "Failure-mode quick reference" table. The
  existing ENG-138 row covers the only observed-in-wild
  instance; the qa-side shape is preventive and warrants a row
  only after observation.
- **Test-fixture inversion is load-bearing.** `bin/guards-test.sh::
  case-9`'s expected outcome MUST be inverted in lockstep with the
  guards.sh edit; otherwise the pre-commit hook fails on the same
  commit that introduces the gate. The implementer should make
  both edits in the same commit.
- **Implicit dependency.** Same as ENG-138's §10: the fix presumes
  `stage`, as passed by `bin/run-stage.sh::main`, is in the long-
  form vocabulary (`implementing`, not `implement`). Verified at
  `bin/run-stage.sh:1891-1896` — normalization to `stage_label_long`
  preserves the long form; the first positional arg to main is
  already long by the time line 1261 fires. Confirmed.

## Persona review

Six personas were run inline during this dispatch. Each persona's
verdict is recorded below. Findings folded into the body above
where they shifted the design; outstanding observations recorded
here.

### design — PASS

- The fix shape (extend the ENG-138 stage gate symmetrically to
  the other two rejection counters) is the canonical pattern for
  counter-driven gates: each counter's purpose is to halt its
  loop's bad-state continuation, not its forward exit. D-1
  expresses this directly for all three.
- The empty-stage `[[ -z "$stage" || ... ]]` clause is the
  established harness shape (line 129) and matches the
  optional-arg-with-empty-default convention already documented
  in ENG-138 D-2.
- No new state, no new marker, no new schema. Reversible via a
  single revert.

### security — PASS

- No new credential surface, no new network surface, no new
  filesystem write surface.
- Inputs to the gated `stage` arg are sourced from
  `run-stage.sh`'s first positional arg (validated upstream);
  direct CLI invocations with an arbitrary string fall through to
  "no trip on rejection arms" which is the fail-safe (never
  accidentally HALT on attacker-supplied stage).
- No interaction with the `PIPELINE_WRITER` lane fence or the
  dispatch envelope validator.

### scope — PASS (with one note)

- Linear issue's `IN:` list: `bin/guards.sh` (lines 138-143 gate
  + header lines 21-27) + new regression cases in
  `bin/guards-test.sh` parallel to ENG-138's. ENG-145 edits
  exactly those.
- Linear issue's `OUT:` list excludes counter accumulation/reset
  semantics, the `review_rejection` gate, and
  `gotcha_triggered` / `learned_rule_renewal`. ENG-145 leaves
  all of those untouched.
- **Note.** D-3 inverts `bin/guards-test.sh::case-9` (introduced
  by ENG-138). The inversion is not strictly "new regression
  cases parallel to ENG-138's" — it's an edit to an existing
  ENG-138 case. The Linear issue's IN: clause names "new
  regression cases", but the inversion is a consequence of the
  gate change being made (the test contradicts the new
  semantic). Not a scope violation; called out for transparency.

### coherence — PASS

- Decisions follow the same one-decision-per-counter-family
  shape as ENG-138 (D-1 policy, D-2 site, D-3 tests, D-4 docs).
- All cross-references to ENG-138, ENG-116, ENG-123,
  `bin/guards.sh:N`, `bin/verdict-handler.sh:N` are
  verified-on-disk this dispatch.
- §6 data-flow narrative mirrors ENG-138's analogous section
  one-for-one with the qa/impl substitution.

### product — PASS

- AC#1–AC#7 (§2) are testable, observable, and map 1:1 to the
  Linear issue's AC#1–AC#5 plus the implicit "pre-commit gate
  stays green" requirement.
- The cost-asymmetry argument from ENG-138 (~$25–30 of agent
  spend held behind operator-resume on the reviewing side)
  applies symmetrically to the qa side once the reproduction
  occurs; D-1 prevents that cost on convergent qa cycles.
- The trade-off in §7 (cross-loop re-entry after
  `building → implementing` rebase still inherits the prior
  qa loop's lifetime counter) is honestly named via OQ-2, not
  glossed.

### feasibility — PASS · zero P0

- Code changes total ~2 lines in `bin/guards.sh` (plus the
  paragraph header rewrite) and ~80 lines in
  `bin/guards-test.sh` (one inversion + three new cases + one
  resume-reset case). Every file edit cites an exact line
  range physically read during this dispatch.
- All referenced functions, fields, and paths are verified
  against the current codebase per §8's Codebase-fact
  verification table. No invented identifiers.
- `bin/run-stage.sh:1261, 1263` already pass `$stage` per
  ENG-138; no orchestrator-side change needed. Confirmed.
- `.githooks/pre-commit` runs `bin/guards-test.sh`
  automatically. The case-9 inversion + new cases are picked
  up without hook changes.
- One feasibility note (advisory, not P0): the case-9
  inversion MUST land in the same commit as the
  `bin/guards.sh:138-143` edit. A split commit would leave one
  side red:
  - guards.sh edit first → case-9 assertion fails (was rc=10,
    now rc=0).
  - case-9 inversion first → case-9 assertion fails (was rc=10,
    now expects rc=0, but gate still trips).
  Implementer should write both edits in one atomic commit.
  Worth a code-review pin and a plan-doc reminder.

**Gate decision: 6/6 PASS · feasibility P0=0 · proceeding to
planning.**
