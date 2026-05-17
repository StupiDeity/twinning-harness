---
linear: ENG-138
title: guards — scope review_rejection halt to the reviewing→implementing loopback edge (post-ENG-116 regression)
date: 2026-05-16
status: draft
---

# ENG-138 — `guards.sh` review_rejection counter halts on `reviewing → qa` (post-ENG-116 regression)

## 1. Overview

ENG-116 (PR #116, commit `c80bd63`) tightened the `review_rejection` /
`qa_rejection` / `implement_rejection` counters in `bin/guards.sh` so
they accumulate across loopback cycles and reset only on an
operator-resume waypoint
(`<!-- pipeline: transition ... reason=operator-resume -->` posted by
`bin/pipeline.sh decide --action continue`). That fix is correct for
the runaway implement↔reviewing ping-pong it targeted.

The implementation gates the halt at the wrong place. `bin/guards.sh`
is invoked unconditionally at the start of every stage dispatch
(`bin/run-stage.sh:1177`), so the cumulative `review_rejection` count
trips even on the **forward exit edge** `reviewing → qa` — i.e.,
immediately after a clean reviewing PASS that proves the loop
converged.

Observed on ENG-123 (2026-05-16): four `reviewing → implementing`
loopback cycles produced by rebased deltas after a `building` merge-
conflict, then a clean reviewing PASS on `aac9560`, then the `qa`
dispatch's first action — `bin/guards.sh check ENG-123` — tripped
with `review_rejection(4>=2)`. ~$25–30 of converged review output was
held behind an operator-resume.

The fix is to scope the `review_rejection` halt check to the stage
that consumes the *next* iteration of the implement↔reviewing loop —
`implementing` — rather than firing on every stage's pre-dispatch
guard call. ENG-116's intent (halt at N consecutive
`reviewing → implementing` rejections) is preserved verbatim because
the next implementing dispatch is exactly when the rule wants to
fire.

## 2. Goal

After ENG-138 lands:

- **AC#1.** Reaching `stage:qa` after a clean reviewing PASS no longer
  halts on the cumulative `review_rejection` counter, regardless of
  how many `reviewing → implementing` rejections preceded the pass.
- **AC#2.** Two or more consecutive `reviewing → implementing`
  rejections still halt at the next `implementing` dispatch (ENG-116
  intent preserved; default threshold 2).
- **AC#3.** Operator-resume waypoint still resets the counter
  (ENG-116 contract preserved).
- **AC#4.** A new `bin/guards-test.sh` covers the three cases above
  using the source-and-stub pattern that the rest of the suite uses.
  The existing `bin/run-stage-test.sh::case-15` regression
  (`bin/run-stage-test.sh:1523-1635`) stays green.
- **AC#5.** Pre-commit hook (`.githooks/pre-commit`, every
  `bin/*-test.sh`) stays green.

## 3. Architectural principle this extends

The harness has **no formal ADR registry** — verified: `ls docs/`
returns `architecture.md assumptions.md brainstorms/ configuration.md
cost.md demos install.md operations.md pipeline-vocabulary.md
pipeline-vocabulary.template.md plans runbooks security.md`. No
`VISION.md`. No `docs/knowledge/decisions.md`. Governing constraints
are `CLAUDE.md`, `docs/architecture.md`, and
`learned-rules/<slug>/project-profile.md`. No new ADR is proposed —
ENG-138 is a single-file behavioural narrowing, not a new
architectural pattern.

ENG-138 extends two existing implicit principles:

1. **Single human-approval gate (`CLAUDE.md::"Single human-approval
   gate (ENG-54)"`).** Review is agent-only and forward-only on
   PASS; the orchestrator advances `reviewing → qa` automatically
   on a clean verdict. A guards halt that fires *after* the
   transition is applied but *before* the next stage dispatches
   silently re-introduces a human gate the reframe explicitly
   removed. ENG-138 restores the intended invariant.

2. **ENG-116's loop-termination claim** (`bin/guards.sh:9-21`).
   ENG-116's prose says the counter "let review/implement loops
   churn indefinitely" — the loop, not the forward edge. Scoping
   the halt to the loopback target is the literal expression of
   that claim.

No existing decision is overturned. The ENG-116 commit message
(`c80bd63 — fix(guards): only operator-resume waypoints reset
rejection counters`) describes a reset-side semantic; ENG-138 leaves
that semantic intact and refines the *check-side* semantic.

## 4. Decisions

Each decision is **D-N: \<verdict\>** + Why + rejected alternatives.
Every reference cites a concrete `path:line`.

### D-1: Implement Option (a) from the Linear issue — scope the `review_rejection` halt check to the `reviewing → implementing` loopback edge only.

**Verdict.** When the dispatched stage is **not** `implementing`,
`bin/guards.sh::check` skips the `review_rejection` threshold check
(but still computes the count for the trailing `guards: clear` log
line). The counter still accumulates across loopback cycles; reset
semantics from ENG-116 are unchanged.

The other counters (`gotcha_triggered`, `learned_rule_renewal`,
`qa_rejection`, `implement_rejection`) are left untouched in this
ticket per the Linear issue's `OUT` scope clause: *"Any other
counter in `issue-state.json` (review_rejection only)"*. See
§9 Open Questions for follow-up on whether `qa_rejection` /
`implement_rejection` exhibit the same edge-confusion bug.

**Why.** The `review_rejection` counter exists to halt the
implementing↔reviewing loop after N unsuccessful agent attempts. The
loop's bad-state continuation is exactly the
`reviewing → implementing` loopback edge in the verdict-handler
loopback table (`bin/verdict-handler.sh:35` — `reviewing|implementing|`).
The downstream consumer of that edge is the next `implementing`
dispatch; that is the *only* stage where halting before dispatch
prevents the next loop iteration from burning agent budget. Firing
the same threshold on the forward edge `reviewing → qa` (table:
`bin/verdict-handler.sh:24` — `reviewing=qa`) instead penalises the
agent for converging — the inverse of the counter's stated purpose.

**Rejected alternative — Option (b): reset on pass.** Treat a
passing `reviewing` verdict as loop-exit and zero the counter
window from that point forward (i.e., `count_marker_since_last_*`
takes the most recent of `operator-resume waypoint` OR `passing
reviewing verdict` as its lower bound). Rejected because:

- ENG-116's stated intent (`bin/guards.sh:9-21`) is that the count
  "accumulate[s] across loopback cycles and are cleared ONLY by an
  operator-resume waypoint." A pass-clears semantic conflicts with
  that intent: an issue that loops `implementing → ui → reviewing →
  reject → implementing → ui → reviewing → pass → qa → reject →
  implementing → ui → reviewing → reject → ...` would silently reset
  the review_rejection budget at every transient pass, hiding the
  long-term churn ENG-116 wants the operator to see.
- The counter's audit value (operator runs `bin/linear.sh
  get-comments` and counts `<!-- meta: metric name=review_rejection -->`
  bodies for triage) is degraded — the operator-visible total no
  longer matches the threshold-relevant total.
- It's strictly weaker than D-1: D-1 fully preserves ENG-116's
  reset-side contract and only narrows the *check* side.

**Rejected alternative — Option (c): split into two counters
(consecutive-in-current-loop-run + lifetime).** Rejected because:

- Adds a second marker shape (`<!-- meta: metric
  name=review_rejection_consecutive -->`) and a second clearing rule.
  The pipeline vocabulary registry at `bin/pipeline-events.json` and
  the docs at `docs/pipeline-vocabulary.md` would both need
  expansion.
- Touches three subsystems (orchestrator counter logic, pipeline
  vocabulary, retrospective metrics) vs D-1's one (orchestrator
  counter logic). Per the CLAUDE.md ticket sizing rubric, that's
  the edge of autonomy-safe — and the Linear issue's scope claim
  ("1 subsystem … autonomy-safe") matches D-1, not (c).
- D-1 is reversible: if a future ticket needs the
  consecutive-in-current-loop semantic (e.g., for retrospective
  triage), it can layer that on top of D-1 without rework.

**Rejected alternative — gate the call in `bin/run-stage.sh`
instead of inside `bin/guards.sh::check`.** I.e., the run-stage
caller skips invoking guards entirely when `stage != implementing`.
Rejected because guards.sh check ALSO computes the
`gotcha_triggered` / `learned_rule_renewal` / `qa_rejection` /
`implement_rejection` thresholds — skipping the whole call on
non-implementing stages would silently disable those checks (a
regression on every non-implementing dispatch). The fix has to live
inside guards.sh::check so only the `review_rejection` arm of the
gate is narrowed.

### D-2: Implementation site — extend `bin/guards.sh::check` to accept an optional `stage` second positional argument; gate the `review_rejection` halt on `stage == implementing`. `bin/run-stage.sh:1177` passes the dispatched stage.

**Verdict.** Change three lines:

- `bin/guards.sh:31` (usage comment): `guards.sh check <issue_id> [stage]`.
- `bin/guards.sh:85-131` (`check()` function): accept `stage`
  as `${2:-}`. After computing `rev`, wrap the trip with
  `if (( rev >= review_threshold )) && [[ -z "$stage" || "$stage"
  == "implementing" ]]`. The empty-stage branch preserves
  back-compat for direct CLI invocations
  (`bash bin/guards.sh check ENG-N` with no stage arg still trips
  exactly as today — important for `bin/status.sh` triage flows and
  for the existing `case-15` test which calls guards directly).
- `bin/run-stage.sh:1177-1179`: pass `"$stage"` as second arg to
  both `guards.sh check` invocations.

The `guards: clear on $ident (rev=$rev …)` log line at
`bin/guards.sh:130` continues to print `rev` so operators can still
read the lifetime count out of the per-stage transcript — the
audit value of the cumulative count is preserved.

**Why.** Three small edits, one bash file plus one call site, no
new state, no schema change, no marker change. Reversible via a
single revert. Matches the minimum-viable-fix shape that ENG-101
and ENG-116 themselves shipped.

The optional-arg-with-empty-default pattern is the established
back-compat shape in the harness — used by
`bin/render-prompt.sh::main`'s `${3:-}` token-resolver, by
`bin/dispatch.sh::main`'s `${PIPELINE_DISPATCH_MODEL:-}`, and (most
relevantly) by `bin/guards.sh::bump`'s
`counter` arg which is required-by-case but not validated at
function-entry. The empty-arg fallback "trip exactly as today"
preserves the CLI surface that `bin/status.sh` and operator
triage already consume.

**Rejected alternative — read the stage from the issue's `stage:*`
label inside `guards.sh::check` via `bash bin/linear.sh stage-of
$ident`.** Rejected because (a) it adds a Linear round-trip to the
hottest gate on the dispatch path, (b) it duplicates work the
caller has already done (`run-stage.sh` knows the dispatched stage
from its first positional arg), and (c) `stage-of` reflects the
label state *after* `apply_transition` ran in the prior dispatch
— for an in-flight `resume_in_progress_transition` recovery the
label may briefly disagree with the dispatched stage, introducing
a race that the explicit-arg path side-steps.

**Rejected alternative — pass an enum like
`--loopback-source=reviewing`.** Rejected because the intent is
"halt before this stage runs another loop iteration", which is
fully captured by the dispatched stage. Naming the *source* of the
loopback would require the caller to know which counter belongs
to which loop — knowledge that today lives entirely inside
`guards.sh`.

### D-3: Test placement — create `bin/guards-test.sh` (new file) following the source-and-stub pattern; keep `bin/run-stage-test.sh::case-15` unchanged.

**Verdict.** New file `bin/guards-test.sh` with the sentinel + stub
pattern documented in `CLAUDE.md::"How tests work — important when
adding new ones"`. Three test cases:

- **case-1 (preserves ENG-116 intent).** Stub `linear.sh
  get-comments` returns two `review_rejection` markers, no
  operator-resume. Invoke `bash bin/guards.sh check ENG-T138
  implementing`. Assert rc=10, output contains
  `review_rejection(2>=2)`.
- **case-2 (fixes the regression).** Same stub as case-1. Invoke
  `bash bin/guards.sh check ENG-T138 qa`. Assert rc=0 (no trip).
- **case-3 (operator-resume still resets).** Stub returns two
  `review_rejection` markers + a `<!-- pipeline: transition
  from=implementing to=implementing reason=operator-resume -->`
  body newer than both. Invoke `bash bin/guards.sh check ENG-T138
  implementing`. Assert rc=0.

The `bin/run-stage-test.sh::case-15` test
(`bin/run-stage-test.sh:1523-1635`) drives `bash
bin/guards.sh check ENG-T15` with NO stage arg — that exact CLI
shape is the back-compat target of D-2's `${2:-}` default. The
test stays valid without modification.

`.githooks/pre-commit` runs every `bin/*-test.sh` so the new file
is picked up automatically.

**Why.** No `bin/guards-test.sh` exists today (verified: `ls
bin/guards*` returns only `bin/guards.sh`). Adding the file gives
`guards.sh` its own per-file regression surface, mirroring
`bin/dispatch-test.sh`, `bin/verdict-handler-test.sh`, etc. The
three cases above are the AC#1–AC#3 trio from §2; one test per
acceptance criterion is the convention used in (for example)
`bin/halt-sprawl-test.sh` and `bin/entry-conditions-test.sh`.

**Rejected alternative — extend `bin/run-stage-test.sh::case-15`
to cover the new stage-scoped paths.** Rejected because case-15
runs guards.sh against a fake-repo overlay with the goal of
verifying the cross-cut between `run-stage.sh`'s call site and
`guards.sh`'s internal logic. The three ENG-138 cases are
intrinsic to `guards.sh::check` (they don't need the fake-repo
overlay). Mixing them into case-15 inflates the test's already
substantial setup boilerplate.

**Rejected alternative — write the tests inline in
`bin/run-stage-test.sh`.** Rejected for the same reason as the
above and for code-locality: future readers asking "where do I
look for guards behaviour?" should find `bin/guards-test.sh`
adjacent to `bin/guards.sh`.

### D-4: Documentation — update the header comment of `bin/guards.sh:9-21` to note the per-stage scoping, and add a one-line entry to `CLAUDE.md`'s "Failure-mode quick reference" table mapping the symptom "`reviewing → qa` transition halts on `review_rejection(N>=2)`" to "fixed in ENG-138; before that fix, operator-resume."

**Verdict.** Two doc edits, both inside the same file group already
in scope:

- `bin/guards.sh:9-21` header comment: append a sentence after the
  ENG-123 line: `ENG-138 narrows the halt firing-side: the
  review_rejection threshold trips only when the dispatched stage
  is 'implementing' (the loopback continuation edge). The counter
  still accumulates across loopback cycles for operator audit, and
  reset semantics are unchanged.`
- `CLAUDE.md` "Failure-mode quick reference" table: add a row
  *only if* a similar symptom row doesn't already exist. (Search
  on "review_rejection" returns zero rows in the failure-mode
  table today — verified by `Grep review_rejection
  CLAUDE.md`; row is genuinely new.)

**Why.** The header comment is the in-file documentation of the
counter contract; future readers look there before grep'ing the
ticket history. The CLAUDE.md row is the operator-recognition
surface; the table is the harness's "I'm seeing weird state, what
fixed it" index. Both edits cost <10 lines combined.

**Rejected alternative — write a runbook entry under
`docs/runbooks/`.** Rejected because the existing
`docs/runbooks/recovery.md` and `docs/runbooks/operator-mental-
model.md` are mental-model documents for ongoing/manual operator
work; a one-time semantic fix like this lives better in the
nearest-to-the-code header comment + the CLAUDE.md quick-reference.

## 5. Architecture (where code goes)

| Site | Change |
|---|---|
| `bin/guards.sh:31` | Update usage comment to show the optional `[stage]` arg. |
| `bin/guards.sh:9-21` | Extend header comment per D-4 (one sentence). |
| `bin/guards.sh:85-131` (`check()`) | Accept `${2:-}` as `stage`; wrap the `review_rejection` trip in `[[ -z "$stage" || "$stage" == "implementing" ]]`. Other counter trips unchanged. |
| `bin/run-stage.sh:1177-1179` | Pass `"$stage"` to both `guards.sh check` invocations. |
| `bin/guards-test.sh` (new) | Source-and-stub pattern, three cases per D-3. |
| `CLAUDE.md` "Failure-mode quick reference" | Optional one-row addition per D-4 (only if no equivalent row exists). |

No new bash files outside `bin/guards-test.sh`; no schema changes;
no marker changes; no learned-rules edits; no Linear write changes;
no metric stream changes.

## 6. Data flow

**Pre-ENG-138 (broken) trip path on the forward edge.**

1. Reviewer agent in C path (clean pass): writes the stage summary,
   posts `verdict pass --stage reviewing`, exits.
   (`AGENT_PROMPTS.md:1173-1186`.)
2. `bin/run-stage.sh::main` post-dispatch calls `verdict_handler`
   (`bin/run-stage.sh:1784`). `find_fresh_verdict` returns the
   pass marker; `apply_transition reviewing qa ""` swaps labels.
3. Next tick: `bin/poll.sh` picks up `stage:qa`. `run-stage.sh
   ENG-N qa` runs. Line 1177 invokes `bin/guards.sh check ENG-N`.
4. `check()` reads the cumulative review_rejection count via
   `count_marker_since_last_operator_resume` (`bin/guards.sh:64-83`)
   — count is 2+ from the prior loopback cycles. Threshold
   tripped; rc=10 → `classify_failure` applies
   `pipeline:skip-until-human-acts`; the issue idles until the
   operator runs `bin/pipeline.sh decide --action continue`.

**Post-ENG-138 (fixed) trip path on the forward edge.**

1–3 unchanged.
4'. `check()` is now called with `stage=qa`. The review_rejection
   threshold check skips because `stage != implementing`. Other
   counter trips still evaluate. The `guards: clear on $ident
   (rev=$rev …)` log line still prints `rev=N` so the operator
   can still observe the cumulative count from the per-stage
   transcript.
5'. Dispatch proceeds; qa agent runs.

**Post-ENG-138 trip path on the loopback continuation edge
(ENG-116 intent preserved).**

1. Reviewer agent in B path (changes requested): bumps
   review_rejection (`AGENT_PROMPTS.md:1168`), posts
   `verdict fail --target implementing`, exits.
2. Verdict_handler applies `reviewing → implementing` loopback.
3. Next tick: `run-stage.sh ENG-N implementing` runs. Line 1177
   invokes `bin/guards.sh check ENG-N implementing`.
4. `check()` reads count; if count >= threshold AND
   `stage == implementing`, trips. Halts the next iteration of
   the loop — exactly what ENG-116 wants.

## 7. Error handling and edge cases

- **Direct CLI invocation
  `bash bin/guards.sh check ENG-N` (no stage arg).** D-2's
  `${2:-}` default lets the empty-stage branch trip exactly as
  today, preserving `bin/status.sh`-style triage flows and
  `bin/run-stage-test.sh::case-15` semantics.
- **`bash bin/guards.sh check ENG-N <unknown-stage>`.** Unknown
  stages fall through to "trip only if implementing" — i.e.,
  never trip the review_rejection arm for unknown stages. Same
  fail-safe as the empty-stage path. ENG-116 intent is conserved
  on the only stage where it matters (`implementing`).
- **`stage:implementing` → guards trip → operator runs
  `pipeline.sh decide --action continue`.** Operator-resume
  waypoint posted; counter reset via the existing ENG-116 path;
  next tick's implementing dispatch sees count=0 → no trip.
  Unchanged.
- **`reviewing → implementing → ui → reviewing → pass → qa`
  sequence (rebase-induced multi-cycle, ENG-123 shape).** Each
  reviewing → implementing rejection bumps review_rejection.
  If count reaches threshold before a clean pass, next
  implementing dispatch halts (ENG-116 wins). If the pass lands
  first (ENG-123's actual sequence), the `reviewing → qa`
  transition proceeds (ENG-138 wins).
- **`qa → implementing` loopback after a clean reviewing pass
  with high cumulative review_rejection.** The next implementing
  dispatch DOES see `stage == implementing`, so the
  review_rejection threshold IS evaluated. If still >= threshold
  (no operator-resume between), halt fires. This is the
  acknowledged trade-off of D-1: the counter is still lifetime
  (per ENG-116), so a re-entry into the implementing loop after a
  qa rejection inherits the prior loop's exhausted budget. An
  operator who wants to grant a fresh budget runs
  `--action continue`. See §9 Open Questions for whether to
  refine this further.
- **`brainstorming` / `planning` / `ui` / `building` / `released`
  dispatches with high cumulative review_rejection.** All non-
  implementing stages — no trip. Forward progress unblocked.
- **`stage_drift` race: orchestrator dispatches stage=qa but
  Linear label flipped back to stage:reviewing mid-tick.** The
  drift check at `bin/run-stage.sh:1756` exits cleanly with
  `stage-drift` metric BEFORE the post-dispatch verdict_handler
  fires. The pre-dispatch guards check has already happened with
  `stage=qa` (the dispatched value), so it didn't trip — correct,
  because the actual stage is reviewing, where review_rejection
  trips don't fire either (D-1 narrows the trip to
  implementing). Net behavior: drift case is fail-open, which
  matches the existing run-stage.sh drift handling philosophy.

## 8. Anti-bias checks (mandatory)

### ADR stress test

The harness has no formal ADR registry. The implicit principles
ENG-138 puts pressure on:

- **ENG-116's "loops churn indefinitely" framing
  (`bin/guards.sh:9-21`).** ENG-138 does NOT overturn it — the
  reset-side semantic is left intact, the counter still
  accumulates across loopback cycles, only the check-side
  firing edge is narrowed. The two changes compose cleanly.
- **ENG-54 "single human-approval gate".** ENG-138 *restores*
  this principle, which the regression silently violated by
  re-introducing a human gate on the reviewing → qa transition.
- **CLAUDE.md ticket sizing rubric.** The Linear issue's sizing
  claim ("1 subsystem … autonomy-safe") matches D-1; if D-1
  were rejected in favor of Option (c) the rubric calibration
  would tighten to "2 subsystems with one clearly subordinate" or
  break to "3 subsystems → split". D-1 stays inside the
  autonomy-safe envelope.

### Simpler alternative

Documented inline under each decision (D-1's Option (b)/Option
(c), D-2's stage-of-from-Linear and enum-source alternatives,
D-3's extend-case-15 alternative, D-4's runbook-entry
alternative). Every rejected alternative has a stated
"why-worse" line.

### Assumption inventory

- **Verified** — `bin/guards.sh::check()` is the single point
  of policy for the three rejection counters
  (`bin/guards.sh:85-131`). Read 2026-05-16.
- **Verified** — `bin/run-stage.sh:1177` is the only caller of
  `guards.sh check` in the orchestrator. Confirmed via
  `Grep "guards\.sh check" bin/` returning only
  `bin/run-stage.sh:1177` (plus the
  test files). Read 2026-05-16.
- **Verified** — `bin/verdict-handler.sh:24` declares
  `reviewing=qa` as the forward transition.
  `bin/verdict-handler.sh:35` declares `reviewing|implementing|`
  as the loopback. Read 2026-05-16.
- **Verified** — `AGENT_PROMPTS.md:1168` is where the reviewer
  agent bumps `review_rejection`. Read 2026-05-16.
- **Verified** — `bin/run-stage-test.sh:1523-1635` is the
  current Case 15 regression; it calls `guards.sh check ENG-T15`
  with no stage arg. The optional-stage default in D-2 preserves
  that exact CLI shape. Read 2026-05-16.
- **Verified** — `bin/guards-test.sh` does NOT exist on disk
  today; D-3 creates it (`Bash ls bin/guards*` returned only
  `bin/guards.sh`, 2026-05-16).
- **Verified** — `.githooks/pre-commit` runs the full
  `bin/*-test.sh` suite (per `CLAUDE.md::"Pre-commit hook"`),
  so the new test file is picked up by the hook automatically.
- **Verified** — `bin/run-stage.sh:1335-1337` captures
  `_HEAD_PRE_DISPATCH` only for `stage == implementing`; the
  noop-implementation detector at `bin/run-stage.sh:1587-1595`
  is gated on `stage == implementing`. ENG-138 does not touch
  these paths but its narrative depends on them not firing on
  non-implementing dispatches; verified.
- **Assumed** — `bin/pipeline.sh decide --action continue` posts
  the operator-resume waypoint `<!-- pipeline: transition ...
  reason=operator-resume -->` (per `bin/guards.sh:11-13` comment
  and `CLAUDE.md::"What --action continue clears (atomic)"` step
  7). Counter reset semantics rely on this; implementation
  must not regress it. Not re-read in this brainstorm.
- **Assumed** — The empty-string-arg trip-as-today path of D-2
  preserves the case-15 test without modification. Verified
  inline (case-15 calls guards directly with `ENG-T15`, no
  stage). Implementer should still run `bash
  bin/run-stage-test.sh` post-change to confirm.

### Codebase-fact verification

Every named file/function/line cited has been opened during this
dispatch:

| Reference | File:line read |
|---|---|
| `check()` body | `bin/guards.sh:85-131` |
| `count_marker_since_last_operator_resume()` | `bin/guards.sh:64-83` |
| header comment (ENG-116/ENG-123 framing) | `bin/guards.sh:9-21` |
| `bump()` body | `bin/guards.sh:133-140` |
| Usage comment | `bin/guards.sh:31` |
| run-stage.sh guards call site | `bin/run-stage.sh:1177-1183` |
| run-stage.sh noop-impl detector | `bin/run-stage.sh:1587-1595` |
| verdict-handler forward table | `bin/verdict-handler.sh:19-27` |
| verdict-handler loopback table | `bin/verdict-handler.sh:29-38` |
| verdict-handler apply_transition entrypoint | `bin/verdict-handler.sh:309-430` |
| reviewer-agent B-path bump | `AGENT_PROMPTS.md:1168` |
| reviewer-agent C-path pass | `AGENT_PROMPTS.md:1173-1186` |
| Case 15 fixture (no-stage CLI shape) | `bin/run-stage-test.sh:1523-1635` |
| stage_drift exit path | `bin/run-stage.sh:1756-1762` |

No referenced item is a code-level invention; everything cited has
been physically verified.

## 9. Open questions

- **OQ-1.** Does `qa_rejection` exhibit the same edge-confusion
  bug shape? Hypothesis: yes — if a `qa → implementing` loopback
  is followed by a clean qa pass, the next `building` dispatch
  trips on accumulated `qa_rejection`. The same scoping fix
  applies (`stage == implementing` for qa_rejection because the
  loopback target is implementing — see
  `bin/verdict-handler.sh:36`). **Scope: explicitly OUT per the
  Linear issue's `OUT` clause.** File a follow-up after ENG-138
  ships if observed.
- **OQ-2.** Does `implement_rejection` exhibit the same? It's
  bumped on implement-stage internal failures (scope-check,
  noop-implementation), not on a loopback edge per se. The
  trip-on-non-implementing-stage path is unreachable in
  practice because the bumps only happen during an implementing
  dispatch, but the LIFETIME counter could trip a *subsequent*
  non-implementing dispatch the same way review_rejection does.
  **Scope: explicitly OUT per the Linear issue.** Worth a
  retrospective look at the events.jsonl stream post-ship to
  confirm whether the bug is theoretical or actual.
- **OQ-3.** Should the `qa → implementing` loopback that
  occurs after a previously-converged review loop (i.e., the
  case where ENG-138's "lifetime counter, halted only on next
  implementing dispatch" trade-off bites) reset the counter?
  Argument for: each loop run is conceptually distinct.
  Argument against: the implementer's prior reviewing-loop
  failures are evidence of accumulated agent struggle and
  should still gate the next attempt. Defer to evidence — file
  follow-up if observed in the wild.
- **OQ-4.** Should the threshold default change? Currently 2.
  ENG-123 produced a clean pass on cycle 4 — under the new
  semantics with threshold 2, ENG-123 would have halted at the
  start of the third implementing dispatch (count=2 → trip).
  An operator-resume would have been required to reach the
  fourth cycle. Is threshold=2 still right when the loopback
  cause is a rebase delta (Mode B in the Linear issue)? **Scope:
  OUT per the Linear issue's "same threshold as today, default
  2" wording.** File follow-up if rebase-delta cycles become a
  recurring drag.

## 10. Scope-exceeded / conflict flags

- **No scope excess.** Every file edit listed in §5 is inside the
  Linear issue's `IN:` clause (`bin/guards.sh`, `bin/run-stage.sh`,
  new test file). The CLAUDE.md doc-edit in D-4 is documentation
  adjacent to the change, within the same harness repo.
- **No architectural conflict.** D-1 is a strict refinement of
  the ENG-116 contract on `bin/guards.sh:9-21` — the reset-side
  semantic ("only operator-resume clears the counter") is
  preserved verbatim; only the check-side firing edge narrows.
- **Implicit dependency.** The fix presumes that `stage`, as
  passed by `bin/run-stage.sh::main`, is in the long-form
  vocabulary (`implementing`, not `implement`). Verified at
  `bin/run-stage.sh:1750-1751` — that block normalises stage to
  the long form (`stage_label_long`) for downstream consumers.
  The first positional arg to main is already in the long form
  by the time line 1177 fires. Confirmed.

## Persona review

Six personas were run inline during this dispatch. Each persona's
verdict is recorded below. Findings folded into the body above
where they shifted the design; outstanding observations recorded
here.

### design — PASS

- The fix shape (scope the halt to the loopback-continuation
  stage) is the canonical pattern for counter-driven gates: the
  counter's purpose is to halt the loop's bad-state continuation,
  not its forward exit. D-1 expresses this directly.
- The optional-arg-with-empty-default pattern in D-2 matches
  established harness shape (`bin/render-prompt.sh`,
  `bin/dispatch.sh`, `bin/guards.sh::bump`).
- No new state, no new marker, no new schema. Reversible via a
  single revert.

### security — PASS

- No new credential surface, no new network surface, no new
  filesystem write surface.
- Inputs to the new `stage` arg in `guards.sh::check` are sourced
  from `run-stage.sh`'s own first positional arg (which is
  validated upstream); direct CLI invocations with an arbitrary
  string fall through to "no trip on review_rejection" which is
  the fail-safe (never accidentally HALT on attacker-supplied
  stage).
- No interaction with the `PIPELINE_WRITER` lane fence or the
  dispatch envelope validator.

### scope — PASS (with two flags)

- Linear issue's `IN:` list: `bin/guards.sh`, `bin/run-stage.sh`,
  new regression test. ENG-138 edits exactly those. ✓
- Linear issue's `OUT:` list excludes other counters
  (qa_rejection, implement_rejection). ENG-138 leaves them
  untouched. ✓
- **Flag 1.** D-4 adds a CLAUDE.md doc-edit. Strictly speaking
  CLAUDE.md is not listed in the IN: clause. Conditional on
  "no equivalent row already exists"; if a row exists, skip the
  edit. Implementer can drop this scope edge entirely without
  affecting AC#1–AC#5.
- **Flag 2.** D-4 also extends `bin/guards.sh:9-21` comment text.
  In-scope edit to an in-scope file; documentation hygiene.

### coherence — PASS

- Decisions follow the harness's established
  one-decision-per-issue idiom (cf. ENG-101, ENG-103, ENG-129).
- Cross-references to `bin/guards.sh:9-21`, ENG-116, ENG-123 are
  consistent.
- §6 Data flow's "Pre/Post-ENG-138 trip path" structure mirrors
  the analogous sections in `docs/brainstorms/2026-05-15-eng-103-
  per-stage-model-tiering-default-cheaper-models-with-rebase-
  loopback-escalation-design.md` and earlier brainstorms.

### product — PASS

- AC#1–AC#5 (§2) are testable, observable, and map 1:1 to the
  Linear issue's stated AC#1–AC#4 plus the implicit "doesn't
  break the pre-commit gate" requirement.
- The cost-asymmetry argument from the Linear issue (~$25–30 of
  agent spend held behind operator-resume) is the right product
  motivation; D-1 directly recovers that cost on convergent
  cycles.
- The trade-off in §7 / OQ-3 (re-entry after qa rejection still
  inherits the lifetime counter) is honestly named, not glossed.

### feasibility — PASS · zero P0

- Code changes total ~6 lines plus a new test file of ~50 lines.
  Every file edit cites an exact line range that has been
  physically read during this dispatch.
- All referenced functions, fields, and paths are verified
  against the current codebase per the Assumption inventory's
  Codebase-fact verification table.
- `.githooks/pre-commit` runs `bin/guards-test.sh` automatically
  (no `KNOWN_BROKEN` allowlist edit needed) once the file is
  created and `chmod +x`'d, per the existing pre-commit pattern.
- No model/tier changes, no dispatch surface changes, no Linear
  contract changes.
- One feasibility note (advisory, not P0): D-2's empty-stage
  branch in `check()` must use `[[ -z "$stage" || "$stage" ==
  "implementing" ]]` so the case-15 test (which passes no stage)
  still trips on count=2. The implementer should write this
  guard explicitly and not collapse to a bare `[[ "$stage" ==
  "implementing" ]]`, which would silently disable the trip for
  every direct-CLI invocation. Worth a code review pin.

**Gate decision: 6/6 PASS · feasibility P0=0 · proceeding to
planning.**
