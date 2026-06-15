---
linear: ENG-118
title: Dimensional grading — threshold logic gating verdicts
date: 2026-06-14
status: draft
---

# Dimensional grading — threshold logic gating verdicts

## 1. Problem

ENG-117 (qa) and ENG-119 (reviewing) shipped two dimensional-grading
payloads that today are **recorded forensically without gating**. Both
prompt blocks call this out in-line:

* `AGENT_PROMPTS.md:2062-2064` (qa, §6): "The threshold sub-ticket will
  later gate the dispatch verdict on dimensional minimums; today the
  payload is recorded forensically without gating."
* `AGENT_PROMPTS.md:1511-1513` (review, §5): "`thresholds_met[]` /
  `thresholds_missed[]` are free-text narrative arrays — NOT a closed
  vocabulary; ENG-118 threshold-gating reads only `score` in v1."

The structural gap: the agent self-grades, emits `verdict pass`, and the
issue advances. There is no orchestrator-side check that the
self-graded scores actually clear a per-dimension floor. An evaluator
biased toward "near-enough is good enough" silently ships sub-floor
work; the calibration shape (ENG-39) cannot exist until we have a
deterministic record of "what the agent claimed vs what the
orchestrator's gate decided."

ENG-118 layers the gate on top of both shipped payloads, with one
per-stage asymmetry:

* Per-dimension threshold floors live in the target's
  `.pipeline-config/config.json` under `review.thresholds.<dim>`
  and `qa.thresholds.<dim>`.
* A post-dispatch detective in `bin/run-stage.sh` reads the relevant
  payload, compares each dimension's `score` to its configured
  threshold, and — when ANY dimension is below threshold AND the agent
  emitted a self-PASS verdict (qa: `verdict == "pass"`; review:
  `verdict == "approve"`; the two schemas use different enums — see
  D-001 step 3) — COERCES the dispatch by posting a structured
  `verdict fail --target implementing --reason dimensional-threshold-not-met`
  Linear comment. `verdict_handler` then sees the orchestrator's fresh
  comment, applies the existing loopback transition, and the issue
  reverts to `stage:implementing`.

The coercion is deliberately a **loopback**, not a **halt**: dimensional
shortfalls are a recurring quality-gate signal, not an operator-triage
event. ENG-39 (calibration) consumes the agent-vs-orchestrator
disagreement record this gate now produces.

## 2. Decisions

### D-001. The threshold gate is a new post-dispatch detective in `bin/run-stage.sh`, NOT a `verdict-handler.sh` extension.

**Rationale.** The Linear ticket says "bin/verdict-handler.sh enforces
thresholds." Reading the verdict-handler internals shows this would be
the WRONG seam:

* `bin/verdict-handler.sh:156-251` (`find_fresh_verdict`) reads Linear
  comments only. It never opens worktree-side JSON files. Threshold
  enforcement requires reading
  `$(issue_dir)/verdict-{review,qa}.json` — a coupling
  verdict-handler does not currently have.
* The existing payload-validation detectives
  (`bin/run-stage.sh:1392-1411` `_validate_review_payload`,
  `bin/run-stage.sh:1567-1586` `_validate_qa_payload`,
  `bin/run-stage.sh:1430-1453` `_validate_review_ledger`) already
  read these files post-dispatch. Adding a threshold-gate sibling is
  the natural extension of that pattern.
* `verdict-handler` runs LAST in the post-dispatch sequence
  (`bin/run-stage.sh:2573`). The threshold gate must run BEFORE
  it so the coerced fail-marker is in Linear when `find_fresh_verdict`
  scans the thread.

The Linear ticket's phrasing is best read as a goal ("a system-level
enforcement gate exists"), not a literal placement directive. The
brainstorm interprets the goal and places the gate at the structurally
correct seam.

**Function shape.** Two parallel functions sized to mirror the existing
detectives:

```
_validate_review_thresholds <ident>   # post-_validate_review_ledger, reviewing stage only
_validate_qa_thresholds     <ident>   # post-_validate_qa_payload, qa stage only
```

Each:
1. Reads `.review.thresholds` or `.qa.thresholds` from `$CONFIG` (the
   target's `.pipeline-config/config.json`). On absent block → no-op,
   return 0 (preserves pre-ENG-118 behavior).
2. Reads the per-dispatch payload at `$(issue_dir "$ident")/verdict-review.json`
   or `verdict-qa.json`. (The payload is guaranteed to exist and validate
   at this point because the preceding detective halted on absence.)
3. Reads the payload's top-level `verdict` field and SHORT-CIRCUITS per
   stage when the agent already self-rejected. The two payloads use
   ASYMMETRIC verdict enums:
   * **QA payload** (`bin/qa-payload-schema.sh:22,169-172`): `verdict ∈
     {pass, fail, halt}`. Short-circuit (return 0) when `verdict !=
     "pass"`.
   * **Review payload** (`bin/review-payload-schema.sh:23,183-184`):
     `verdict ∈ {approve, request-changes, premise-failure, halt}`.
     Short-circuit (return 0) when `verdict != "approve"`.
   This is the **single most-overlooked load-bearing fact** in the
   brainstorm — review payloads NEVER carry `verdict = "pass"`, so a
   naive `if verdict != "pass" return 0` check would always-coerce on
   review and never-coerce on qa-with-self-fail. The per-stage gate
   functions implement the correct asymmetric check. (Assumption-
   Inventory rows #6 and #7 carry the explicit enum verifications;
   D-001 was rewritten to honor them after the iter-1 design persona
   flagged the conflation.)
4. For each dimension whose name appears in the threshold config:
   compares `score` to the configured threshold. Builds a
   `failed_dimensions[]` list.
5. If `failed_dimensions[]` is non-empty: posts a verdict-fail comment
   via `bash bin/pipeline.sh event "$ident" verdict fail --target implementing --reason dimensional-threshold-not-met`,
   plus a sibling `add-comment --sig dimensional-threshold/<stage>/<ident>`
   comment carrying the structured failed-dimensions table. Return 0.
6. If `failed_dimensions[]` is empty: return 0.

The function never returns a halt rc. The only path to halt is a
prior detective (payload / ledger validator) already halting the
dispatch.

**Reference to constraint.** CLAUDE.md "Cross-dispatch staleness
contract (ENG-87)": "Per-medium primitives: clear-on-dispatch-start
for per-issue files." `verdict-{review,qa}.json` are already
clear-on-dispatch-start per ENG-117/ENG-119 (`bin/run-stage.sh:957-972`).
The threshold gate reads them within the same dispatch, so the
staleness contract is satisfied without new mechanism.

**Reference to constraint.** CLAUDE.md "Detective backstop" pattern:
"emits a halt marker and exits with a non-zero rc" — ENG-118 deviates
ON PURPOSE: it emits a *loopback* marker (not halt) and exits 0.
Justification documented in D-004.

**Rejected alternative — extend `verdict-handler.sh::verdict_handler`
to consult the payload file before applying the `pipeline-stage-summary`
transition.** Rejected because (a) it adds payload-file knowledge to a
function whose contract is "read Linear comments, apply state
transitions" — the architectural seam blurs; (b) the verdict-handler
runs unconditionally for every stage, but threshold gating only
applies to reviewing+qa — a stage-conditional inside verdict-handler
duplicates information that already lives in the stage→detective
table; (c) the existing detective pattern is the documented surface
for "post-dispatch checks that consult worktree state"
(`docs/architecture.md` "Dispatch lifecycle"), so adding a fourth
detective is cheaper than expanding a fifth seam.

**Rejected alternative — bake the gate into the payload validators
(`_validate_qa_payload` / `_validate_review_payload`).** Rejected
because (a) those validators today have a clean contract: structural
schema validity only. They halt on shape errors. ENG-118's threshold
gate is policy, not structure — a valid payload can fail thresholds.
Conflating the two muddies the "shape vs policy" distinction that the
payload header comments enforce; (b) the existing payload halt body
includes a stack trace and resume instructions assuming a malformed
file. Threshold failure resume instructions are different (loop back
to implementer, not hand-edit JSON). Two distinct halt-comment bodies
inside one function is a smell; two functions is the right
factoring.

### D-002. Threshold config shape: `.review.thresholds.<dim>` is an ENUM (`fail|concern|pass`); `.qa.thresholds.<dim>` is a NUMBER in `[0.0, 1.0]`. Both blocks are OPTIONAL.

**Rationale.** The two payloads have asymmetric score types:

* `bin/review-payload-schema.sh:217-220`: review per-dimension `score`
  is `string in {pass, concern, fail}` (enum).
* `bin/qa-payload-schema.sh:205-215`: qa per-dimension `score` is
  `number in [0.0, 1.0]`.

The config must match the payload's type — anything else introduces a
translation layer (e.g., "0.7 maps to 'concern'") that has no defensible
mapping table. Operator setting `review.thresholds.correctness = 0.7`
or `qa.thresholds.coverage = "pass"` is a misconfig; the validator
emits a warning and skips that threshold (fail-open per D-009).

**Review enum ordinal.** `fail = 0 < concern = 1 < pass = 2`. A
dimension is "above threshold" iff its score's ordinal is `>=` the
configured threshold's ordinal.

**Default behavior — neither block present.** Pre-ENG-118 behavior
unchanged: the threshold gate is a no-op, all `verdict pass` markers
flow through to verdict-handler. Operators opt in by adding the
config block.

**Recommended starting config** (added to `docs/configuration.md`
as a documented example, NOT shipped as a default):

```json
{
  "review": {
    "thresholds": {
      "correctness":     "concern",
      "testing":         "concern",
      "maintainability": "concern",
      "scope":           "concern"
    }
  },
  "qa": {
    "thresholds": {
      "gate_compliance":           1.0,
      "coverage":                  0.8,
      "regression_intent":         1.0,
      "adversarial_coverage":      0.7,
      "plan_alignment":            0.8,
      "flake_dismissal_integrity": 1.0
    }
  }
}
```

The review defaults are `concern` (not `pass`) to preserve ENG-191's
`ship-with-deferred-majors` exit path — see D-006. The qa defaults
mirror the six dimensions named in `AGENT_PROMPTS.md:2054-2055` as
"suggested starter dimensions for the qa stage."

**Reference to constraint.** CLAUDE.md "Per-stage dispatch model
(ENG-103)" precedent: per-stage configuration is `config.json`
top-level blocks (`dispatch.model.<stage>`, `dispatch.tools.<stage>`,
`orchestrator.entry_conditions.<stage>`). ENG-118 follows the same
"top-level block per concern, nested by stage" shape with
`review.thresholds.*` and `qa.thresholds.*`. The
`config.json` schema documentation in `docs/configuration.md` is
the canonical reference and gets an additive section.

**Rejected alternative — single `.dimensional_thresholds.<stage>.<dim>`
block.** Rejected because (a) the two stages have different value
types (enum vs number) — a unified block needs runtime type-dispatch
that the per-stage block obviates; (b) the Linear ticket literally
names `review.thresholds.<dimension>` and `qa.thresholds.<dimension>`
— the shape matches the ticket text.

**Rejected alternative — agent reads thresholds from config and
self-coerces.** Rejected because (a) the goal is "make evaluator bias
observable and bounded" — letting the agent self-coerce restores the
bias surface; (b) decoupling agent from per-target config means
operators can tune thresholds without re-rendering prompts; (c) the
agent's existing `threshold_met` boolean (qa) and `thresholds_met[]`
narrative arrays (review) become forensic data the orchestrator can
compare to its own computed truth — the calibration substrate ENG-39
needs.

### D-003. Registry extension: a new `fail_reasons` array carrying `["dimensional-threshold-not-met"]`, plus `field_registry_by_arm.fail.reason = "fail_reasons"`. Mirrors the ENG-191 `pass_reasons` precedent.

**Rationale.** The threshold gate's coercion comment must carry a
structured token so the operator's audit recipe (`grep
reason=dimensional-threshold-not-met linear-comments`) and ENG-39's
retrospective consumer can both filter on it. Today's `fail` arm
accepts `target` only (`bin/pipeline-events.json:97-103`); adding
optional `reason` requires:

1. New top-level array `fail_reasons: ["dimensional-threshold-not-met"]`.
2. New per-arm override `events.verdict.linear_comment.field_registry_by_arm.fail.reason = "fail_reasons"`.

The registry validator (`bin/pipeline.sh::_validate_event_payload`,
line 174) already prefers `field_registry_by_arm[arm][k]` over
`field_registry[k]`, so:

* `verdict fail --target implementing` → no reason, valid (back-compat).
* `verdict fail --target implementing --reason dimensional-threshold-not-met`
  → reason validated against `fail_reasons`, valid.
* `verdict halt --reason dimensional-threshold-not-met` → no
  `field_registry_by_arm.halt.reason` override, falls through to
  `field_registry.reason = "halt_reasons|wait_reasons"`, fails
  because `dimensional-threshold-not-met` is not in either union —
  die with "registry: 'dimensional-threshold-not-met' not in
  halt_reasons|wait_reasons". The reason token is scoped to the
  `fail` arm only.

`bin/generate-vocabulary-doc.sh` regenerates
`docs/pipeline-vocabulary.md` from the registry; the new
`fail_reasons` array surfaces there automatically (the
`vocabulary-cleanliness-test.sh` pin from ENG-113 / ENG-115 is the
mirrored pattern — ENG-118 adds a `case-X: dimensional-threshold-not-met
in fail_reasons registry` assertion).

**Reference to constraint.** CLAUDE.md "Pipeline vocabulary": "Single
source of truth: `docs/pipeline-vocabulary.md` (generated from
`bin/pipeline-events.json`)." Closed vocabulary extension follows
the established additive shape.

**Rejected alternative — new `verdict_results` token like
`threshold-failed`.** Rejected because (a) widening
`verdict_results` requires updates to `find_fresh_verdict`'s jq
projection (`bin/verdict-handler.sh:233-250`), the verdict_handler
case-table (`bin/verdict-handler.sh:547-602`), AND every
test that mocks the verdict shape (~12 sites); (b) semantically a
threshold-fail IS a regular fail — the result is identical
(loopback to implementing). The reason field is the right
discriminator for "WHY this fail-marker was emitted."

**Rejected alternative — reuse an existing `halt_reasons` token like
`agent-blocked`.** Rejected because the result class is wrong:
threshold failure routes to loopback, not halt. The Linear ticket's
"not pass/reject" phrasing rules out using a halt result, and
`agent-blocked` semantically belongs to "agent cannot proceed" not
"agent's output failed quality gate."

### D-004. The coerced verdict is `verdict fail --target implementing --reason dimensional-threshold-not-met`. `verdict_handler` requires no code changes — the existing `pipeline-rejection` branch routes the loopback unchanged.

**Rationale.** The coercion shape was chosen to require ZERO changes to
the state-transition machine. Walk-through:

1. Threshold gate posts the coercion comment via
   `bash bin/pipeline.sh event "$ident" verdict fail --target implementing --reason dimensional-threshold-not-met`.
2. `bin/linear.sh::add_comment` (the chokepoint) auto-injects
   `<!-- meta: dispatch id=$PIPELINE_DISPATCH_ID stage=<stage> -->`
   per ENG-87. The marker rides the body of the verdict comment.
3. `verdict_handler` runs next (`bin/run-stage.sh:2573`).
   `find_fresh_verdict` enters its strict-id path
   (`bin/verdict-handler.sh:175-200`), iterates verdict comments
   carrying the current dispatch_id, picks the latest by
   `createdAt`. The orchestrator's coerced fail is newer than the
   agent's pass → fail wins.
4. The fresh marker projects to `{marker:"pipeline-rejection",
   source_stage:"", target_stage:"implementing", ...}`
   (`bin/verdict-handler.sh:242-243`).
5. `verdict_handler`'s `pipeline-rejection` case
   (`bin/verdict-handler.sh:563-586`) resolves `src` from the
   issue's `stage:*` label (T2.2 fallback) — yields `reviewing` or
   `qa`. `_vh_lookup_loopback "reviewing" "implementing"` and
   `_vh_lookup_loopback "qa" "implementing"` both have rows in
   `_VH_LOOPBACK_TRANSITIONS` (`bin/verdict-handler.sh:32-38`,
   `reviewing|implementing|` and `qa|implementing|`).
6. `apply_transition` runs the standard loopback.

The agent's earlier `verdict pass` is older by `createdAt`; under the
strict-id-match path, it is naturally superseded. No `find_fresh_verdict`
edits needed.

**Reference to constraint.** CLAUDE.md "Cross-dispatch staleness
contract": the strict-id path is the freshness mechanism. Within a
single dispatch, the latest verdict comment by `createdAt` is the
truth.

**Lane fence note.** `bin/pipeline.sh::cmd_event_verdict` warns when
`PIPELINE_WRITER != agent` (`bin/pipeline.sh:296-298`). The check
fires unconditionally for non-agent writers — setting
`PIPELINE_WRITER=orchestrator` does NOT suppress it (the hint at
`bin/pipeline.sh:297` says "set PIPELINE_WRITER=agent to suppress",
explicitly naming `agent` as the only suppressor). ENG-191's
`_post_deferred_majors_comment_if_eligible` (`bin/run-stage.sh:1484-1485`)
sets `local PIPELINE_WRITER=orchestrator`, but its sole comment is
an `add-comment --sig deferred-majors/<ident>` (NOT a verdict
marker) — `add_comment`'s lane check is keyed on `_object_class`, not
on the writer-must-be-agent rule, so that helper doesn't trip the
warning regardless of writer label. ENG-118's threshold gate
emits a verdict marker, so the warning WILL fire — once per coerced
dispatch — into `$PROJECT_STATE_DIR/<slug>/logs/<ident>-<stage>-*.log`.
The warning is informational only; the post itself succeeds and
`find_fresh_verdict` processes it normally. **Cost is bounded:** one
log line per coerced dispatch, in the per-stage transcript only;
no Linear comment noise, no operator-visible degraded signal.
Tightening the lane fence (allowing orchestrator to emit specific
verdict reasons without warning) is a follow-up to track in OQ-1.

**Reference to constraint.** CLAUDE.md "Don't add features beyond what
the task requires." The lane fence today is a `log` warning, not a
hard rejection. Living with the warning is cheaper than refactoring
the lane-fence contract for one new case. The forensic noise is
bounded — one warning per threshold-coerced dispatch, never per
non-coerced dispatch.

**Rejected alternative — orchestrator emits a marker via direct
`linear.sh add-comment` (bypasses `pipeline.sh event`).** Rejected
because (a) it bypasses the registry validator — the marker body
becomes hand-crafted and drift-prone; (b) the auto-injected
dispatch_id marker is still applied (the chokepoint is
`linear.sh::add_comment`), but the closed-vocabulary check on
`reason=...` is lost. We want the validator's guarantee that
`dimensional-threshold-not-met` matches the closed set.

### D-005. Composition with ENG-190 critical-floor: review-ledger detective (rc=49) halts FIRST; threshold gate runs SECOND. Two coercion rules cover orthogonal axes.

**Rationale.** The Linear ticket's scope note flags this composition
explicitly: "Whoever picks it up needs to make the two coercion rules
compose coherently rather than fight (e.g. precedence/ordering of
'critical-floor fail' vs 'sub-threshold dimension fail')."

The two rules operate on different data:

* ENG-190 `critical-floor` (`bin/review-ledger-schema.sh:340-348`):
  "cold_severity == critical ⇒ decision == block AND
  adjudicated_severity == critical." Per-finding invariant; enforced
  on the JSONL ledger.
* ENG-118 dimensional threshold: "every payload-emitted dimension's
  `score` clears the configured floor." Per-dimension invariant;
  enforced on the per-dispatch JSON payload.

The current post-dispatch detective sequence in
`bin/run-stage.sh:2406-2473` is:

```
1. _validate_review_payload   (rc 36/37/38 → halt)
2. _validate_review_ledger    (rc 48/49/50 → halt)  ← ENG-190 critical-floor
3. _post_deferred_majors_comment_if_eligible  ← ENG-191 enumeration
4. (NEW) _validate_review_thresholds          ← ENG-118 coercion
5. _validate_qa_payload       (rc 39/40/41 → halt)
6. (NEW) _validate_qa_thresholds              ← ENG-118 coercion
7. push_branch_if_ahead + post_completion_comment
8. verdict_handler (line 2573)
```

Slot order: ENG-118's review-side gate runs AFTER ENG-190's ledger
validator AND after ENG-191's deferred-majors hook, BEFORE the
qa-side validators (which fire only on `stage == qa`).

The composition matrix:

| ENG-190 status | ENG-118 status | Outcome |
|---|---|---|
| Ledger has critical-floor violation | (any) | `_validate_review_ledger` halts; ENG-118 never runs. |
| Ledger clean; ≥1 critical adjudicated | (any) | Payload `correctness.score == "fail"` (per `AGENT_PROMPTS.md:1509`). Score ordinal 0 (`fail`) is below threshold `concern` (ord 1) → coerces. Score ordinal 0 below threshold `pass` (ord 2) → coerces. Score ordinal 0 equals threshold `fail` (ord 0) — at-floor → does NOT coerce (operator effectively disabled this gate). |
| Ledger clean; all majors deferrable (ENG-191 exit) | review.thresholds set | See D-006. |
| Ledger clean; no critical/major | All scores `pass` | No coercion. Issue advances to qa. |

**No mutual-exclusion logic is needed.** The detective sequence
naturally enforces ENG-190 > ENG-118. ENG-118 silently no-ops when
the ledger halts. The two halts cannot fire on the same dispatch
because ENG-190 exits the function before ENG-118 runs.

**Reference to constraint.** CLAUDE.md "Per-medium primitives" plus
the established detective-sequence pattern: "post-dispatch detectives
run in `run-stage.sh::main`'s post-dispatch block in declared order;
each is independent." Composition by ordering, not by interaction
logic.

**Reference to constraint.** Linear scope note (2026-06-14):
"compose coherently rather than fight." The ordering choice
documented here is the entire mechanism.

### D-006. Composition with ENG-191 `ship-with-deferred-majors` exit: the threshold gate runs UNCONDITIONALLY. Operator-tunable defaults preserve ENG-191's exit semantics; setting `review.thresholds.correctness = "pass"` is the documented way to forbid deferred-majors exits.

**Rationale.** ENG-191's selective exit fires when the agent emits
`verdict pass --reason ship-with-deferred-majors` (one or more major
findings adjudged `blocks_ship=false`). In this state, the review
payload typically reports `dimensions.correctness.score == "concern"`
(per the score mapping at `AGENT_PROMPTS.md:1506-1509`: "`concern` —
at least one `major` finding").

Two composition postures considered:

**A. ENG-118 skips when ENG-191's exit fired.** Special-case in the
threshold gate: if `find_fresh_verdict`'s `reason ==
"ship-with-deferred-majors"`, no-op. Strictly preserves ENG-191. But
this carve-out is exactly the kind of "evaluator bias" the ticket
wants bounded — an agent that takes the selective exit on
sub-threshold scores would silently pass.

**B. ENG-118 runs unconditionally; operator tunes defaults.** The
threshold gate runs. If the operator set `correctness >= "concern"`,
the deferred-majors path's `concern` score is at-floor and the
issue advances to qa. If the operator set `correctness >= "pass"`,
the deferred-majors path coerces to fail-loopback. The operator
chooses which posture matches their team's tolerance for
"ship-with-debt."

**Chosen: B.** The ticket goal — "make evaluator bias observable and
bounded" — demands the gate run unconditionally. The two features
remain composable through operator-tunable defaults.

**Recommended default** (D-002): `concern` for the four required
review dimensions. Preserves ENG-191's exit. Operators raising to
`pass` make an explicit policy choice; the audit trail (Linear
comment grep for `reason=dimensional-threshold-not-met`) shows
exactly why.

**Edge case: the agent emits `verdict pass --reason
ship-with-deferred-majors` AND `correctness.score == "concern"` AND
`review.thresholds.correctness == "pass"`.** Sequence:
1. `_validate_review_payload` passes (payload is well-formed).
2. `_validate_review_ledger` passes (no critical-floor violation —
   majors with `blocks_ship=false` are valid per ENG-191).
3. `_post_deferred_majors_comment_if_eligible` posts the
   enumeration comment under `sig deferred-majors/<ident>`.
4. `_validate_review_thresholds` (NEW) sees `correctness.score ==
   "concern"` < threshold `"pass"`, coerces to
   `verdict fail --target implementing --reason
   dimensional-threshold-not-met`.
5. `verdict_handler` reads the latest verdict comment (orchestrator's
   coercion). Loops back to implementing.

The deferred-majors enumeration comment from step 3 is
ORPHANED — it documents findings that will NOT be deferred (the
issue is looping back, not shipping). This is a known
operator-visibility quirk but not a correctness bug; the
enumeration is still useful for triage. OQ-2 tracks the cosmetic
fix.

**Reference to constraint.** ENG-191 D-006 left this composition
explicit: the deferred-majors exit is "operator-tunable" via the
config. ENG-118's threshold config is the tuning surface.

**Rejected alternative — auto-skip threshold gate on
deferred-majors exit.** Rejected (posture A above) because it
silently re-introduces the evaluator-bias surface the ticket
forbids.

### D-007. The agent's self-reported `threshold_met` (qa) and `thresholds_met[]` (review) become FORENSIC fields. The orchestrator computes its own `passed = score >= threshold` per dimension. Disagreement is the calibration signal.

**Rationale.** Two truth sources today:

* QA agent emits `dimensions[].threshold_met: <bool>` —
  `bin/qa-payload-schema.sh:39` documents this as "your judgment"
  (the agent's call).
* Review agent emits `dimensions.<name>.thresholds_met[]` and
  `thresholds_missed[]` as "free-text narrative arrays" —
  `AGENT_PROMPTS.md:1511-1513` explicitly says ENG-118 reads only
  `score`.

ENG-118 introduces a THIRD truth source: orchestrator-computed
`passed_threshold` per dimension. The orchestrator does NOT read the
agent's `threshold_met` field when deciding to coerce. The
orchestrator reads `score` and `score` only, compares to its own
config, and decides.

The agent's `threshold_met` field becomes forensic:

* Retrospective (ENG-39 substrate): per-dispatch, computes
  `agent_says_met[dim] XOR orchestrator_says_met[dim]` and reports
  systematic disagreement. A dimension where the agent consistently
  says "met" but orchestrator says "not met" → calibration target
  (lower the threshold, or rewrite the prompt to better explain
  the threshold).
* Operator forensics: visible in the per-dispatch payload at
  `$(issue_dir)/verdict-{review,qa}.json`. The audit recipe is
  `jq '.dimensions[] | [.name, .score, .threshold_met]' verdict-qa.json`.

**Reference to constraint.** Linear ticket OUT clause: "Dynamic
threshold adjustment (e.g., calibration — ENG-39's territory)."
ENG-118 produces the disagreement signal; ENG-39 consumes it. The
ticket-boundary is honored — no dynamic adjustment, just the
substrate.

**Rejected alternative — orchestrator reads `threshold_met` and
treats it as authoritative.** Rejected because it restores
evaluator bias as the verdict-decision surface.

**Rejected alternative — drop `threshold_met` from the qa schema.**
Rejected because (a) it's already shipped in v1 — removing it is a
breaking change with no upside; (b) the forensic value is real;
(c) the field is what the calibration shape needs.

### D-008. Missing config-named dimension (operator names `foo` in `qa.thresholds`, agent did NOT emit a `foo` dimension) → fail-CLOSED. Treat as below threshold; coerce.

**Rationale.** Two competing pulls:

* **Fail-open:** skip the dimension silently. Operator doesn't get
  blocked by their own misconfig. But this hides drift — the agent
  could be silently omitting a required dimension AND the operator
  could be silently misconfigured AND we'd never notice.
* **Fail-closed:** treat as threshold-violated, include in the
  coercion's failed_dimensions list with a `dimension-missing-in-payload`
  marker. Forces immediate operator attention.

The ticket goal — "make evaluator bias observable and bounded" —
demands fail-closed. A configured threshold is a load-bearing
operator intent; missing payload data is a structural defect that
should not pass silently.

**Implementation.** When building `failed_dimensions[]`:

```
for each dim_name in keys(.<stage>.thresholds):
  payload_dim = payload.dimensions[dim_name]
  if payload_dim is null:
    failed_dimensions += { name: dim_name,
                           reason: "missing-in-payload",
                           threshold: <configured-value> }
    continue
  if payload_dim.score < configured_threshold:
    failed_dimensions += { name: dim_name,
                           reason: "below-threshold",
                           score: payload_dim.score,
                           threshold: <configured-value> }
```

The coercion comment enumerates BOTH classes in the structured
body (sib `--sig dimensional-threshold/<stage>/<ident>`).

**Reference to constraint.** AGENT_PROMPTS.md:2056-2057 (qa):
"Include a dimension only if you can cite concrete evidence; omit
rather than fabricate." This sets up the conflict: omission is
agent-blessed, but omission of a configured dimension is operator-
forbidden. Fail-closed is the right resolution — the operator's
config is the contract; the agent's prompt-level "omit rather than
fabricate" defends against fabricated EXTRA dimensions, not against
omitting REQUIRED ones.

**Rejected alternative — fail-open with a `log` warning.** Rejected
per above: hides drift.

**Rejected alternative — hard halt on missing payload-dimension.**
Rejected because dimensional misalignment is a recurring calibration
signal, not a triage event. Loopback is right.

### D-009. Malformed config (wrong type, out-of-range value, non-enum review threshold) → fail-OPEN. Log warning, skip that threshold.

**Rationale.** The asymmetric to D-008: a misconfigured threshold (e.g.,
`qa.thresholds.coverage = "high"` where a number is required) should
NOT block dispatch. The operator made a typo; the next iteration fixes
it. Fail-open with a `log` warning visible in the per-stage transcript.

**Validation rules:**

* QA: `qa.thresholds.<dim>` must be a number AND in `[0.0, 1.0]`.
  Reject non-number / out-of-range with `log "warning: rejecting
  qa.thresholds.$dim=<value> (expected number in [0.0, 1.0])"`,
  skip that threshold.
* Review: `review.thresholds.<dim>` must be a string AND in
  `{fail, concern, pass}`. Reject with `log` warning, skip that
  threshold.
* Both: unknown threshold dim name (no dimension with that name in
  the agent's payload-emitted dimensions[]) handled by D-008.

**Reference to constraint.** CLAUDE.md "Per-stage dispatch model
(ENG-103)" precedent: invalid config values "log a warning and fall
through to the next layer" — fail-open with operator-visible
diagnostic. Same pattern here.

**Rejected alternative — fail-closed on malformed config.**
Rejected because the operator misconfigured ONCE produces a
permanent loopback halt until they fix it. The blast radius (next
dispatch is halted) is disproportionate to the cause (a typo).

## 3. Architecture

### 3.1 Files touched

| Path | Change | Lines |
|---|---|---|
| `bin/run-stage.sh` | Add `_validate_review_thresholds` and `_validate_qa_thresholds` (siblings of `_validate_review_payload`, etc.). Insert two `case "$stage"` switches in the post-dispatch sequence. | ~120 added |
| `bin/pipeline-events.json` | Add `fail_reasons: ["dimensional-threshold-not-met"]` array. Add `events.verdict.linear_comment.field_registry_by_arm.fail.reason = "fail_reasons"`. Add `"dimensional_threshold_coerced"` to the existing `metric_names` array (so the §3.3 step 7 metric emission passes the closed-vocabulary validator at `bin/pipeline.sh::_validate_event_payload`). | ~7 added |
| `docs/configuration.md` | Add `.review.thresholds.*` and `.qa.thresholds.*` documentation sections under "config.json schema." Include the recommended-defaults example from D-002. Tabulate the enum-vs-number asymmetry explicitly (review uses enum, qa uses number — they are NOT interchangeable). | ~80 added |
| `docs/pipeline-vocabulary.md` | Auto-regenerated by `bin/generate-vocabulary-doc.sh` after the registry edit. | (generated) |
| `bin/vocabulary-cleanliness-test.sh` | Add TWO pins: `dimensional-threshold-not-met in fail_reasons registry` AND `dimensional_threshold_coerced in metric_names registry`. | ~20 added |
| `docs/runbooks/recovery.md` | Add §N "Dimensional threshold coercion" — operator triage recipe (grep recipe + how to disable/loosen a threshold + how to resume). One-paragraph inline summary preserved in §5 of this brainstorm. | ~30 added |
| `CLAUDE.md` "Failure-mode quick reference" table | Add row: "Issue at `stage:reviewing\|qa` with verdict comment `reason=dimensional-threshold-not-met`" pointing to docs/configuration.md and the audit grep recipe. | ~3 added |
| `bin/run-stage-test.sh` | Add fixture-driven tests for the two new functions: pass-above-threshold, fail-below-threshold per dimension, fail-closed on missing dim, fail-open on malformed config, composition with ENG-190 halt, composition with ENG-191 exit. | ~250 added |
| `AGENT_PROMPTS.md` (§5 review, §6 qa) | Trim the "ENG-118 will later" sentinel from the two pointer lines (`:1511-1513`, `:2062-2064`); replace with a one-line link to `docs/configuration.md`. | ~6 changed |
| `bin/common.sh::failure_outcome_for_exit` | NO change. The threshold gate never exits with a new code; coercion is a 0-rc post-Linear-comment operation. | 0 |
| `bin/verdict-handler.sh` | NO change. The coercion fits the existing `pipeline-rejection` branch via the new `reason` field. | 0 |
| `bin/qa-payload-schema.sh`, `bin/review-payload-schema.sh` | NO change. Schemas are unchanged; ENG-118 is a layer on top. | 0 |

### 3.2 Subsystems touched (rubric check)

Per CLAUDE.md "Ticket sizing rubric":

* **orchestrator** — `bin/run-stage.sh` (the two new functions, two new
  case-switches).
* **Linear contract** — `bin/pipeline-events.json` (registry extension),
  vocabulary doc regen, the new `fail_reasons` token.
* **tests/fixtures** — `bin/run-stage-test.sh`,
  `bin/vocabulary-cleanliness-test.sh`.
* **agent prompts** — trim of two pointer-comment lines in
  `AGENT_PROMPTS.md` (one each in §5 review and §6 qa). NOT a
  structural prompt change — the new gate is orchestrator-side,
  invisible to the agent.

**Subsystems = 4 with three clearly subordinate** (Linear contract is
one registry-array addition; tests are coverage; agent prompts is a
six-line tidy). The orchestrator's `run-stage.sh` is the substantive
change. **Within rubric — autonomy-safe, with scope boundary
explicitly named here.**

### 3.3 Per-dispatch data flow (qa stage example)

```
qa agent dispatches; writes verdict-qa.json; emits `verdict pass --stage qa`.
  ↓
run-stage.sh post-dispatch sequence:
  ↓
_validate_qa_payload                    (existing, ENG-117)
  → payload structurally valid → proceed
  ↓
_validate_qa_thresholds                 (NEW, ENG-118)
  ↓
  Step 1: Read .qa.thresholds from $CONFIG.
          if absent → return 0 (no-op).
  ↓
  Step 2: Read verdict-qa.json. Read .verdict.
          (QA stage gate: short-circuit when .verdict != "pass".
          Review stage gate: short-circuit when .verdict != "approve".
          See D-001 step 3 for the asymmetric enum rationale.)
  ↓
  Step 3: For each dim_name in keys(.qa.thresholds):
            value = .qa.thresholds.<dim_name>
            if value not in valid range → log warning, skip.
            payload_dim = lookup dim_name in .dimensions[].name
            if payload_dim missing → failed += {missing}
            elif payload_dim.score < value → failed += {below}
            else → passed
  ↓
  Step 4: if failed empty → return 0.
  ↓
  Step 5: PIPELINE_WRITER=orchestrator
          bash bin/pipeline.sh event $ident verdict fail \
            --target implementing \
            --reason dimensional-threshold-not-met
          (lane-warning emitted to stderr; comment posted)
  ↓
  Step 6: bash bin/linear.sh add-comment $ident \
            --sig "dimensional-threshold/qa/$ident" \
            --body "<structured failed-dimensions table>"
  ↓
  Step 7: emit metric event via `bash bin/metrics.sh event` with name
          "dimensional_threshold_coerced" — REQUIRES adding the token to
          `bin/pipeline-events.json::metric_names` (§3.1 row 2 + 4).
          Tracks coercion rate as the calibration substrate for ENG-39.
  ↓
  return 0.
  ↓
verdict_handler $ident qa
  → find_fresh_verdict picks orchestrator's coerced fail-marker
    (newer createdAt within same dispatch_id)
  → routes to pipeline-rejection branch
  → _vh_lookup_loopback "qa" "implementing" → row exists
  → apply_transition qa → implementing
  ↓
run-stage.sh exits 0; next tick polls; issue resumes at stage:implementing.
```

### 3.4 Composition diagram (review stage with all three layers)

```
review agent → emits verdict pass --reason ship-with-deferred-majors,
                writes verdict-review.json (correctness.score=concern),
                appends to review-findings-ledger.jsonl with deferred majors.

run-stage.sh post-dispatch (reviewing stage):
  _validate_review_payload    → PASS (payload structurally valid)
  _validate_review_ledger     → PASS (critical-floor + blocks_ship OK)
                                  ┝── if FAIL here: halt rc=49,
                                      threshold gate never runs.
  _post_deferred_majors_comment_if_eligible  → posts enumeration comment
  _validate_review_thresholds (NEW) →
    case A: thresholds absent OR all clear → no-op.
    case B: correctness.score=concern, threshold=concern → no-op.
    case C: correctness.score=concern, threshold=pass → coerce.
            posts verdict fail --target implementing
            --reason dimensional-threshold-not-met.
  verdict_handler →
    case A: applies forward transition reviewing→qa.
    case B: applies forward transition reviewing→qa.
    case C: applies loopback reviewing→implementing.
            (deferred-majors comment from step 3 is orphaned but
             still operator-discoverable.)
```

## 4. Data Flow

### 4.1 Config read

`$CONFIG` is the target's `.pipeline-config/config.json` (resolved by
`bin/common.sh`). The threshold gate reads with a defensive jq guard:

```bash
local thresholds_block
thresholds_block="$(jq -r '.review.thresholds // empty' "$CONFIG" 2>/dev/null || printf '')"
[[ -z "$thresholds_block" || "$thresholds_block" == "null" ]] && return 0
```

If the block is absent, malformed, or `null`, the function returns 0
(no-op). This matches the ENG-86 entry-conditions precedent: empty
config → fail-open with no behavior change.

### 4.2 Per-dimension iteration

```bash
local dim_names
dim_names="$(jq -r '.review.thresholds | keys[]' "$CONFIG" 2>/dev/null || printf '')"
local dim_name
while IFS= read -r dim_name; do
  [[ -z "$dim_name" ]] && continue
  local threshold_val
  threshold_val="$(jq -r --arg n "$dim_name" '.review.thresholds[$n]' "$CONFIG")"
  # ... validate type, compare, accumulate failed_dimensions[] ...
done <<< "$dim_names"
```

For review: ordinal comparison via case statement
(`fail < concern < pass`). For qa: numeric comparison via jq
`-e '.dimensions[] | select(.name == $n) | .score < $t'`.

### 4.3 Coercion comment shape

The verdict-fail marker:

```
<!-- pipeline: verdict result=fail target=implementing reason=dimensional-threshold-not-met -->

(post-injected) <!-- meta: dispatch id=ENG-118-d0001 stage=qa -->
```

The companion structured body (separate `add-comment --sig`):

```
<!-- meta: dispatch id=ENG-118-d0001 stage=qa -->

Dimensional threshold gate coerced verdict on dispatch ENG-118-d0001 stage=qa.

Failed dimensions (3):

- **coverage** — score=0.65, threshold=0.80 (below-threshold)
- **regression_intent** — score=0.95, threshold=1.0 (below-threshold)
- **gate_compliance** — missing in payload, threshold=1.0 (missing-in-payload)

Recovery: this is a loopback to `stage:implementing`. The implement agent
will see the failed dimensions in the next dispatch's prior-review
summary. To raise/lower a threshold, edit `.qa.thresholds.<dim>` in
`.pipeline-config/config.json`.
```

Sanitisation: the dimension name, score, threshold values are
agent-controlled inputs to the body. Apply the existing `<!-- → <\!--`
rewrite (mirrors `_post_review_ledger_halt` at
`bin/run-stage.sh:1462-1467`) so a hand-crafted dim name like
`<!-- pipeline: verdict result=halt -->` cannot hijack the marker
parser. The values are already shape-validated by the payload
schema, but defense-in-depth.

### 4.4 Idempotency on resume

`bin/pipeline.sh decide ENG-N --action continue` clears the
`pipeline:halted` label and re-allocates a fresh `dispatch_id`. On
the next tick:

* The orchestrator's prior coerce-fail comment from the OLD dispatch
  no longer matches the NEW dispatch_id → `find_fresh_verdict`'s
  strict-id path filters it out.
* The new dispatch's verdict-qa.json gets pre-cleaned by
  `_clear_current_stage_slots` (`bin/run-stage.sh:957-972`).
* The threshold gate runs fresh on the new dispatch's data.

No stale-coercion concern; the dispatch_id-primary contract handles
it.

## 5. Error Handling

### 5.1 Exit codes

The threshold gate functions never return a non-zero rc that
propagates outside themselves. All paths return 0:

* threshold met / no thresholds configured → return 0 (no-op).
* threshold failed → post coercion + companion comment + metric → return 0.
* malformed config (D-009) → log warning, skip that threshold → continue or return 0.
* missing dim in payload (D-008) → include in failed_dimensions → return 0 (coerces).

**No new entries in `bin/common.sh::failure_outcome_for_exit`.** The
ticket scope (per CLAUDE.md "When wiring a new script") is honored —
new exit codes only when needed; ENG-118 doesn't need any.

### 5.1.1 Operator visibility — `log` lines per branch

The threshold gate emits exactly ONE `log` line per branch so the operator
can grep the per-stage transcript to answer "did the gate run and what
did it decide?":

| Branch | `log` line |
|---|---|
| Config block absent → no-op | `_validate_<stage>_thresholds: <stage>.thresholds absent; gate is no-op` |
| Scope-approval replay → skipped | `_validate_<stage>_thresholds: skipped (scope-approval replay)` |
| Payload `verdict != "pass"\|"approve"` → no-op | `_validate_<stage>_thresholds: agent self-rejected; no coercion needed` |
| All dimensions clear → no-op | `_validate_<stage>_thresholds: all N dimensions clear` |
| One+ dimensions failed → coerce | `_validate_<stage>_thresholds: coercing (N failed: <comma-list of dim names>)` |
| jq missing OR `$CONFIG` unreadable → fail-open | `warning: threshold gate skipped (<jq missing\|config unreadable>)` |
| `PIPELINE_DISPATCH_ID` unset → fail-open | `warning: threshold gate skipped (no dispatch id)` |

The grep recipe is `grep '_validate_.*_thresholds' "$PROJECT_STATE_DIR/<slug>/logs/<ident>-<stage>-*.log"`.
The fail-open warnings (D-009 posture) are CRITICAL operator-visibility
surfaces — a silently-skipped gate is exactly the kind of "gate disabled
with no signal" path that violates the harness's "operator can grep for
what happened" mental model.

### 5.1.2 Missing tools / unreadable config

Two operator-visible silent-skip paths that flow through the same fail-open
branch (D-009):

* `jq` not on PATH → `jq -r ... 2>/dev/null` returns empty string →
  threshold block read returns empty → gate is no-op. Mitigation: explicit
  `command -v jq >/dev/null || { log "warning: jq missing; threshold gate skipped"; return 0; }`
  guard at the top of each gate function (mirrors `bin/dispatch.sh`'s
  optional-`gtime` discovery from CLAUDE.md "PATH expectations").
* `$CONFIG` unreadable (file perms / missing) →
  `[[ -f "$CONFIG" && -r "$CONFIG" ]]` guard catches; logs `warning: threshold
  gate skipped (config unreadable: $CONFIG)`. Both fail-open per D-009;
  documented as expected behavior, not silent.

### 5.2 Linear post failures

The coercion uses `bash bin/pipeline.sh event ...` which calls
`bin/linear.sh add-comment` internally. If the Linear API call fails:

* `pipeline.sh event` returns non-zero (e.g., HTTP error, network).
* Our caller (`_validate_qa_thresholds`) currently treats that as a
  best-effort post and logs a warning. The dispatch continues and
  `verdict_handler` runs on the agent's `verdict pass` — the
  coercion did not land, so the issue advances WITHOUT the
  threshold check enforced.

**This is a quiet failure mode.** Two mitigations available:

* **A. Soft-fail with retry.** Mirror the existing
  `post_completion_comment` retry-once pattern
  (`bin/run-stage.sh:2488-2494`). On second failure, `classify_failure`
  routes to `linear-post-failed` (rc=24). The global breaker eventually
  trips.
* **B. Hard-fail rc=24.** Treat any Linear post failure in the
  coercion path as `linear-post-failed`, exit immediately.

**Chosen: A.** Mirrors the existing pattern. Single retry, then breaker.
The brainstorm flags this as an explicit edge case rather than a silent
behavior.

### 5.3 Dispatch_id race

If the orchestrator's coerce-fail comment somehow lands BEFORE the
agent's `verdict pass` (e.g., Linear API latency reordering), the
agent's later `verdict pass` would win on createdAt and the coercion
would be silently overruled. Mitigation: the threshold gate runs
AFTER the agent dispatch has fully exited (gtimeout completed) and
AFTER the existing payload validator. The agent cannot post new
comments at that point (its dispatch is done). Concrete sequence
guarantee:

* dispatch.sh blocks until claude -p exits → return from
  `bin/run-stage.sh::dispatch.sh ...`.
* All subsequent validators (including ENG-118's gate) run in
  series with no parallel agent activity.
* The orchestrator's coerce-fail is therefore strictly the last
  verdict marker by wall-clock; createdAt ordering is monotonic
  enough for the find_fresh_verdict strict-id path.

This is not a real race in practice; it would only manifest with
Linear API clock skew across two writes within ~milliseconds, which
is rarer than the existing transition-vs-verdict ordering hazards
the codebase tolerates.

### 5.3.1 Operator recovery from an unwanted coercion

Suppose the gate fires unintentionally (operator set the threshold too
tight or named a dimension that the agent doesn't reliably emit).
Recovery procedure (in order of escalating intervention):

1. **Loosen the threshold.** Edit `.pipeline-config/config.json` —
   raise `qa.thresholds.<dim>` to a lower numeric floor, or change
   `review.thresholds.<dim>` from `"pass"` to `"concern"` (or
   `"fail"`, which effectively disables the gate for that dimension
   because every score is at-or-above ord 0). The next dispatch
   reads the new value.
2. **Remove the threshold entry.** Delete the offending key from the
   threshold block. The gate iterates `keys(...)`; an absent key is
   not enforced.
3. **Remove the entire threshold block.** Drop `.qa.thresholds` or
   `.review.thresholds`. Gate is fully no-op (D-002 default).
4. **Resume.** `bash bin/pipeline.sh decide ENG-N --action continue`
   clears any halt label and re-dispatches the stage on the next
   tick. The new threshold block is read fresh.

The forensic audit recipe (find all coerced dispatches on an issue):

```bash
bash bin/linear.sh get-comments ENG-N \
  | jq -r '.[] | select(.body | contains("reason=dimensional-threshold-not-met")) | .body' \
  | head -20
```

A cross-issue audit (operator wants to see all threshold coercions
this week):

```bash
jq -r 'select(.event == "dimensional_threshold_coerced") | .ident + " " + .ts' \
  $PROJECT_STATE_DIR/metrics/events.jsonl | sort -k2 | tail -50
```

OQ-3 captures the `docs/runbooks/recovery.md` follow-up; this
section is the load-bearing inline summary for in-brainstorm
triage.

### 5.4 Concurrent operator config edit

If the operator edits `.qa.thresholds.coverage` from `0.8` to `0.5`
DURING an in-flight dispatch (between dispatch start and the
threshold gate read), the new value applies. Mitigation: none
needed. The threshold gate reads at evaluation time, not at
dispatch-start. Operator-edited mid-flight thresholds reflect intent
("loosen the gate, this one's a special case"). Documented in OQ-3.

## 6. Edge Cases

1. **Both `.review.thresholds` and `.qa.thresholds` absent.** No-op; pre-ENG-118 behavior preserved.

2. **`.qa.thresholds` block present but empty (`{}`).** No-op (no dim_names iterated).

3. **Agent emits `verdict halt --reason agent-blocked`.** Payload's `verdict == "halt"` ≠ `"pass"` → gate returns 0. Halt flows through unchanged.

4. **Agent emits a self-reject verdict.** QA: payload `verdict == "fail"` → gate returns 0. Review: payload `verdict ∈ {"request-changes", "premise-failure", "halt"}` → gate returns 0. Either way the agent already self-rejected; the existing find_fresh_verdict + verdict_handler flow loops back unchanged. No double-coercion.

5. **Agent emits `verdict pass` AND payload structurally fails schema.** `_validate_*_payload` halts BEFORE `_validate_*_thresholds` runs. Halt wins.

6. **All thresholds met but no dimensions emitted at all.** Payload schema (`bin/qa-payload-schema.sh:182-185`, `bin/review-payload-schema.sh:197-201`) already requires ≥1 dimension (qa) or all 4 required (review). Cannot reach the threshold gate with zero dimensions.

7. **Threshold name has uppercase or special chars** (e.g., `"qa.thresholds.GateCompliance": 1.0`). The gate iterates keys as-is; uppercase won't match an agent-emitted snake_case dim name → treated as missing-in-payload (D-008) → coerce. Operator-visible misconfig (the failed_dimensions table names `GateCompliance`).

8. **Multiple dispatches on the same issue accumulate coercion comments.** Each dispatch's coercion comment carries its own dispatch_id; old dispatches' comments are filtered out by the strict-id path in `find_fresh_verdict`. The Linear comment thread grows by one comment per coerced dispatch — acceptable forensic noise, matches the existing ENG-191 deferred-majors hook's growth profile.

9. **Threshold gate runs but the agent's `verdict pass` marker is missing from Linear entirely.** `find_fresh_verdict` then sees only the orchestrator's coerced fail-marker — loops back as designed. (Edge case where agent crashed before posting verdict but somehow wrote a valid payload — combination is rare but the gate is robust to it.)

10. **`PIPELINE_DISPATCH_ID` env var unset.** Detective backstop scenario; the gate should still post the coercion but the auto-injected dispatch marker is malformed. Mitigation: gate checks `[[ -n "${PIPELINE_DISPATCH_ID-}" ]]` before posting; if unset, log warning and skip coercion (don't poison the comment thread with markerless coerce-fails). Equivalent to D-009's fail-open posture for orchestrator-side misconfig.

11. **Dispatch is a scope-approval replay (`skip_dispatch == 1`).** Per `bin/run-stage.sh:2410-2473`, all the existing payload validators are skipped on scope-approval replay. ENG-118's gates follow the same gate (`if (( ! skip_dispatch ))`) — no coercion on replay. The original dispatch's coerced fail-marker was already there (if it triggered); replay flows through the scope-approval transition path.

## 7. Open Questions

* **OQ-1: Should the orchestrator be added to the verdict-emitter lane?**
  Today `bin/pipeline.sh::cmd_event_verdict` warns when
  `PIPELINE_WRITER != agent`. The threshold gate intentionally crosses
  the lane fence with a `log` warning per dispatch. A follow-up could
  add `agent-or-coercion` as a recognized lane, with closed-vocabulary
  reason filter (only `dimensional-threshold-not-met` and future
  similar tokens allowed when writer is orchestrator). Out-of-scope
  for ENG-118; tracked for the ENG-39 calibration shape.

* **OQ-2: Orphan deferred-majors enumeration on coerced exit.**
  When ENG-191's `_post_deferred_majors_comment_if_eligible` posts an
  enumeration AND ENG-118 then coerces to loopback, the enumeration
  comment is correct-but-misleading (it lists findings that won't
  actually be deferred this dispatch — the issue is looping back). A
  cosmetic fix: have `_validate_review_thresholds` detect the
  enumeration sig and either edit (impossible — `add-comment` is
  append-only post-ENG-150) or post a corrective `meta: invalidated_by`
  comment. Bounded operator confusion; flagged for retrospective
  review.

* **OQ-3: Documented expectation for mid-flight config edits.**
  Operators editing `.qa.thresholds` between dispatch start and the
  gate read get the new value. This is intentional but undocumented;
  add to `docs/runbooks/recovery.md` as part of the ENG-118
  documentation pass.

* **OQ-4: Per-stage threshold "warn-only" mode?**
  A staged rollout could let operators set
  `qa.thresholds.coverage = { value: 0.8, mode: "warn" }` to log a
  warning without coercing. Useful for tuning before enforcement.
  ENG-118 ships enforcement-only for simplicity; OQ-4 captures the
  shape for ENG-39 calibration to evaluate.

* **OQ-5: Schema-validate config at startup?**
  Today `bin/run-local.sh` doesn't pre-validate config blocks. A
  malformed threshold value is caught at gate time (per-dispatch log
  warning). A startup-time `config-validate.sh` would surface
  misconfigs earlier. Out-of-scope; the existing per-stage warning
  is sufficient for v1.

## 8. Assumption Inventory

All code-level claims verified against current code at the listed
`path:line`. "verified" = quoted text exists at the cited line.

| # | Assumption | Status | Evidence |
|---|---|---|---|
| 1 | `bin/run-stage.sh` post-dispatch sequence: payload-validator → ledger-validator → deferred-majors-hook → verdict-handler. | verified | `bin/run-stage.sh:2406-2473` (review/qa validators), `:2573` (verdict_handler) |
| 2 | `_validate_qa_payload` exists, halts on schema violation. | verified | `bin/run-stage.sh:1567-1586` |
| 3 | `_validate_review_payload` exists, halts on schema violation. | verified | `bin/run-stage.sh:1392-1411` |
| 4 | `_validate_review_ledger` exists, halts on critical-floor violation. | verified | `bin/run-stage.sh:1430-1453` |
| 5 | `_post_deferred_majors_comment_if_eligible` posts ENG-191 enumeration. | verified | `bin/run-stage.sh:1483-1561` |
| 6 | qa-payload schema: `dimensions[].name` snake_case, `score` number `[0.0, 1.0]`, `threshold_met` bool. | verified | `bin/qa-payload-schema.sh:24-39`, `:189-242` |
| 7 | review-payload schema: `dimensions.{correctness,testing,maintainability,scope}.score` enum {pass,concern,fail}, `thresholds_met[]`, `thresholds_missed[]` arrays. | verified | `bin/review-payload-schema.sh:22-43`, `:196-246` |
| 8 | `verdict_handler` reads Linear comments via `find_fresh_verdict`, does NOT read payload JSON. | verified | `bin/verdict-handler.sh:156-252`, `:517-604` |
| 9 | `find_fresh_verdict` strict-id path picks latest by `createdAt` within current `dispatch_id`. | verified | `bin/verdict-handler.sh:175-200` |
| 10 | `_VH_LOOPBACK_TRANSITIONS` includes `reviewing|implementing|` and `qa|implementing|`. | verified | `bin/verdict-handler.sh:32-38` |
| 11 | `_VH_FORWARD_TRANSITIONS` includes `reviewing=qa` and `qa=building`. | verified | `bin/verdict-handler.sh:19-27` |
| 12 | `bin/pipeline-events.json` carries `fail_targets: ["brainstorming","planning","implementing","ui"]`. | verified | `bin/pipeline-events.json:34-39` |
| 13 | `field_registry_by_arm[arm][k]` beats `field_registry[k]` per `bin/pipeline.sh`. | verified | `bin/pipeline.sh:174`, `bin/pipeline-events.json:110-119` |
| 14 | `bin/linear.sh::add_comment` auto-injects `<!-- meta: dispatch id=... stage=... -->` when `PIPELINE_DISPATCH_ID` is set. | verified | `bin/linear.sh:86-110`, ENG-87 contract in CLAUDE.md |
| 15 | `bin/pipeline.sh::cmd_event_verdict` warns when `PIPELINE_WRITER != agent`, does not block. | verified | `bin/pipeline.sh:291-298` |
| 16 | `verdict-{qa,review}.json` are clear-on-dispatch-start. | verified | `bin/run-stage.sh:957-972` |
| 17 | ENG-190's critical-floor lives in `bin/review-ledger-schema.sh`, not in `_validate_review_payload`. | verified | `bin/review-ledger-schema.sh:340-348` |
| 18 | ENG-191 added `pass_reasons` registry array with `ship-with-deferred-majors`. | verified | `bin/pipeline-events.json:10-12`, `:111-119` |
| 19 | `bin/generate-vocabulary-doc.sh` regenerates `docs/pipeline-vocabulary.md` from the registry. | verified | CLAUDE.md "Pipeline vocabulary" section |
| 20 | `bin/vocabulary-cleanliness-test.sh` carries per-token pins (ENG-113 case-4b, ENG-115 case-5). | verified | `bin/vocabulary-cleanliness-test.sh:157-180` |
| 21 | `_post_completion_comment` retries once on Linear-post failure, then routes to `linear-post-failed` (rc=24). | verified | `bin/run-stage.sh:2488-2494` |
| 22 | `scope-approval replay` skips the validators via `if (( ! skip_dispatch ))`. | verified | `bin/run-stage.sh:2410, 2428, 2449, 2461` |
| 23 | The agent's QA prompt §6 includes a "later gate" sentinel pointing at ENG-118. | verified | `AGENT_PROMPTS.md:2062-2064` |
| 24 | The agent's review prompt §5 explicitly states "ENG-118 threshold-gating reads only `score` in v1." | verified | `AGENT_PROMPTS.md:1511-1513` |
| 25 | No `review.thresholds` / `qa.thresholds` config exists today; the block is net-new. | verified | `grep -rn "review.thresholds\|qa.thresholds" bin/ docs/` returns no hits |
| 26 | `qa-predicate-invalid` is reserved in the registry from ENG-113 but is unrelated to ENG-118 (it's the verification-predicate validator's halt reason). | verified | `bin/vocabulary-cleanliness-test.sh:157-168`, `docs/brainstorms/2026-05-17-eng-113-...md:23-69` |
| 27 | `bin/common.sh::failure_outcome_for_exit` maps 48/49/50 to review-ledger codes; 51+ are free. | verified | `bin/common.sh:710-745` |
| 28 | Loopback markers (`pipeline-rejection`) follow the existing reason-free shape; adding optional `reason` is additive. | verified | `bin/verdict-handler.sh:242-243`, registry `field_registry_by_arm` map |

All 28 assumptions verified — zero "assumed" entries.

## 9. Acceptance criteria mapping

| Linear AC | Satisfied by |
|---|---|
| #1. "A review/qa dispatch that scores below threshold on any dimension cannot emit verdict=pass." | D-001 + D-004. The threshold gate runs post-payload-validation, post-ledger-validation; on sub-threshold dimension, posts the coerced fail-marker; `find_fresh_verdict`'s strict-id path picks the orchestrator's fresh comment as the verdict; `verdict_handler` routes the loopback. The agent's `verdict pass` is structurally allowed (the agent self-emits it) but is OVERRULED — which is the goal: agent emits, orchestrator validates, system enforces. |
| #2. "Threshold-failed verdicts route to a clear next-action (rejection with the failed dimension(s) called out)." | D-001 step 5 + 6 (verdict-fail marker + sib structured comment). D-003 (registered `dimensional-threshold-not-met` token makes the audit recipe `grep 'reason=dimensional-threshold-not-met' linear-comments` complete). |
| #3. "Tests cover pass-above-threshold + fail-below-threshold paths." | §3.1 row `bin/run-stage-test.sh` — fixture-driven tests for both. Composition with ENG-190 halt and ENG-191 exit also covered. |

OUT bullet ("Dynamic threshold adjustment") honored: D-002 (config is
static) + D-007 (orchestrator computes from config, never adjusts).
The agent-vs-orchestrator disagreement record (D-007) is the
substrate ENG-39 consumes; ENG-118 does not consume or write
calibration adjustments.

## 10. ADR stress test

Existing ADR cited as constraint: CLAUDE.md "Cross-dispatch staleness
contract (ENG-87)" — every Linear comment carries the auto-injected
dispatch_id marker; reader-side strict-id filter is the freshness
mechanism. ENG-118's coerce-fail comment composes ON TOP of this
contract (D-004) — no pressure.

CLAUDE.md "Pipeline vocabulary" + "Single source of truth: closed
registry": ENG-118 extends the registry with an additive
`fail_reasons` array (D-003) — no pressure.

CLAUDE.md "Per-medium primitives": clear-on-dispatch-start for
per-issue files (verdict-*.json) — composes naturally with the gate
(§4.4 idempotency) — no pressure.

**One pressure point.** CLAUDE.md "Lane fence: agents emit verdicts."
ENG-118 has the orchestrator emit a verdict (with `--reason
dimensional-threshold-not-met`). The lane fence today is a `log`
warning (`bin/pipeline.sh:296-298`), not a hard rejection. **The
brainstorm makes the tradeoff explicit** (D-004): we accept the
per-coerced-dispatch lane warning as forensic noise. The follow-up
to formalize a coercion lane is OQ-1. This is an acknowledged tax,
not a hidden one.

## 11. Persona review

Six personas, canonical order (design → security → scope → coherence
→ product → feasibility). Two iterations executed; this section
records the final gate state. Iteration 1 returned 3/6 PASS; the
three REVISE findings (design P0, coherence P0, feasibility 3 P0s)
all centred on three concrete defects that have been fixed:

1. **D-001 step 3 verdict-enum asymmetry.** The original draft used a
   stage-symmetric `verdict != "pass"` short-circuit, which is dead
   code for review (review's enum is `{approve, request-changes,
   premise-failure, halt}`). Fixed: D-001 step 3 now spells out the
   per-stage check, §1 framing acknowledges the asymmetry, §6 Edge
   case #4 enumerates both schemas, §3.3 data flow Step 2 carries the
   per-stage gate.
2. **`metric_names` registry extension missing from §3.1.** The metric
   token `dimensional_threshold_coerced` was named in §3.3 step 7
   without a corresponding registry edit. Fixed: §3.1's
   `pipeline-events.json` row now lists the metric_names addition,
   the `bin/vocabulary-cleanliness-test.sh` row pins TWO assertions,
   and §3.3 step 7 cross-references §3.1.
3. **D-004 lane-fence precedent mis-stated.** The original draft
   claimed ENG-191's `PIPELINE_WRITER=orchestrator` suppresses the
   verdict-marker warning; per `bin/pipeline.sh:296-298` the
   suppression keyword is `agent`, not `orchestrator`. Fixed: D-004's
   "Lane fence note" now states the precedent correctly and explains
   why ENG-191's helper doesn't trip the warning (it's not a verdict
   marker), while ENG-118's gate does (and accepts one log line per
   coerced dispatch).

### 11.1 Design — PASS (post-iter-1 fixes)

* P0: 0. (Original P0: D-001 step 3 verdict-enum conflation; resolved.)
* P1: 3 acknowledged.
  * D-005 wording "fail is the floor" was imprecise; the §5 composition
    matrix now reads correctly given `fail=0 < concern=1 < pass=2`
    ordinals.
  * D-002 config-shape precedent: chose `review.thresholds.*` /
    `qa.thresholds.*` (concern-then-knob) over `thresholds.review.*`.
    Rationale documented: literal match to Linear ticket text,
    asymmetry-of-types means a unified `thresholds.*` block would need
    runtime type-dispatch.
  * D-004 lane-fence precedent now correctly described; OQ-1 captures
    the formalisation work.
* P2: 4 (one per design persona finding, all closed inline; subsystem
  framing in §3.2 acknowledged as "1 substantive + 3 subordinate").
* PASS. The 4-detective seam mirrors three established precedents
  (`_validate_review_payload`, `_validate_review_ledger`,
  `_validate_qa_payload`); registry extension mirrors ENG-191's
  `pass_reasons` precedent verbatim; ENG-39 forward-compat
  articulated via D-007.

### 11.2 Security — PASS

* P0: 0.
* P1: 1 acknowledged — sib-comment body sanitisation must be
  plan-stage MANDATORY (not aspirational) because the structured body
  carries agent-supplied `rationale` strings (review's `rationale`
  field is free-text per `bin/review-payload-schema.sh:224-227`).
  Without the `<!-- → <\!--` rewrite, an attacker-crafted rationale
  could inject a `verdict result=pass` marker that wins on
  `createdAt` and self-neutralises the gate. §4.3 names the
  sanitisation; planning must add a fixture-driven test asserting
  that the verdict-fail comment (NOT the sib) is what
  `find_fresh_verdict` resolves.
* P2: 3 (closed-vocabulary check on `--reason` defends the
  verdict-fail marker body; lane-fence acceptance is the documented
  tax; PIPELINE_DISPATCH_ID-unset path adds metric emission for
  observability — D-009 fail-open posture preserved).

### 11.3 Scope — PASS

* P0: 0.
* P1: 2 (§3.1 table is forward-looking — could be more explicit;
  metric event in §3.3 is borderline feature-creep but defensible as
  ENG-39 substrate — accepted as in-scope).
* P2: 4 (decision count = 9 with five subordinate; OQ-1..5 properly
  deferred; OUT-clause honored; subsystem count at rubric edge).
* PASS. Cleared for planning.

### 11.4 Coherence — PASS (post-iter-1 fixes)

* P0: 0. (Original P0s: D-001 step 3 enum-conflation AND §1 framing
  inconsistency; both resolved by the iter-1 edits — §1 now
  acknowledges the per-stage asymmetry, §6 edge case #4 enumerates
  both schemas.)
* P1: 3 acknowledged (line-number off-by-N citations tightened where
  possible; §11 reframed from "completed self-claim" to "iteration
  history"; D-002 qa-defaults trace to `AGENT_PROMPTS.md:2054-2055`
  confirmed via spot-check).
* P2: 3 (naming consistency standardised; §8 row-27 wording clarified
  "free, not consumed"; D-002 ↔ D-006 cross-reference added inline).
* PASS.

### 11.5 Product — PASS

* P0: 0.
* P1: 4 acknowledged.
  * `metric_names` registry edit added to §3.1 (fixes silent-skip on
    metric emission).
  * `log` warning lines specified for scope-approval-replay and
    no-thresholds-configured branches (operator triage at 3am).
  * `jq` missing / `$CONFIG` unreadable failure modes added to §5
    with explicit `log` warnings (D-009 fail-open posture).
  * Recovery path now documented inline in §5 (raise threshold to
    floor OR remove block; `bash bin/pipeline.sh decide ... --action
    continue`). OQ-3 covers the recovery.md follow-up.
* P2: 5 (enum-vs-number asymmetry table in docs/configuration.md;
  qa-default rationale; CLAUDE.md failure-mode row; concrete
  `bin/linear.sh get-comments` audit recipe; ENG-39 substrate pinned
  to `verdict-*.json` + `events.jsonl` as the two canonical
  consumed surfaces).
* PASS.

### 11.6 Feasibility — PASS (post-iter-1 fixes)

* P0: 0. (Original P0s: D-001 step 3 review-enum mismatch;
  `metric_names` registry omission; D-004 lane-fence precedent
  mis-statement. All three resolved by iter-1 edits documented
  above.)
* P1: 4 acknowledged (line-number citations within ±2; brainstorm
  spot-check of `_VH_LOOPBACK_TRANSITIONS` ENG-191
  `local PIPELINE_WRITER` site, `find_fresh_verdict` strict-id
  path, `bin/review-ledger-schema.sh:340-348` critical-floor rule
  — all verified at exactly cited lines or within ±2).
* P2: 5 (pipeline-rejection projection sets `reason:""` — informational
  only; brainstorm's `bin/common.sh::failure_outcome_for_exit` NO
  change verified; critical-floor reference exact; loopback table
  has 5 rows including unused `building|implementing|`).
* PASS. Of 28 Assumption-Inventory rows, 28 verified at or within ±2
  lines of cited path:line references.

### 11.7 Gate summary

| Persona | Verdict | P0 |
|---|---|---|
| Design | PASS | 0 |
| Security | PASS | 0 |
| Scope | PASS | 0 |
| Coherence | PASS | 0 |
| Product | PASS | 0 |
| Feasibility | PASS | 0 |

Gate: **6/6 PASS, feasibility P0 = 0. Proceeding to planning.**

### 11.8 Iteration history

* **Iter 1.** 3 PASS (Security, Scope, Product) + 3 REVISE (Design,
  Coherence, Feasibility). 3 distinct P0 findings (D-001 step 3
  verdict-enum conflation, metric_names registry omission, D-004
  lane-fence precedent mis-statement) plus the secondary §1 framing
  inconsistency. All resolved by inline edits documented in §11
  preamble.
* **Iter 2.** All six personas PASS. Gate met.
