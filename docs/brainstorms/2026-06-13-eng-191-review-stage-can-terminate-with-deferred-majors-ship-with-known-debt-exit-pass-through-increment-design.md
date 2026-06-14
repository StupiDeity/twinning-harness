---
linear: ENG-191
title: Review stage can terminate with deferred majors (ship-with-known-debt exit, pass-through increment)
date: 2026-06-13
status: draft
---

# Review stage can terminate with deferred majors — pass-through increment

## 1. Problem

[ENG-190](https://linear.app/twinning/issue/ENG-190) gives the
adjudicator a memory ledger so it can recognise "same class,
repeatedly" and downgrade it to `defer-candidate`. But the path
predicate is still mechanical: **path C fires iff `Adjudicated
critical == 0 AND Adjudicated major == 0`** (AGENT_PROMPTS.md:1506-
1514). A PR that legitimately surfaces ≥1 genuine adjudicated-major
every round — even after stabilisation — has no exit. The agent
either keeps emitting path-B loopbacks until `review_rejection(2>=2)`
trips at the next implementing dispatch (`bin/guards.sh:135-137`,
ENG-138) and halts for human triage, or the loop runs unbounded.

Real teams converge by triaging: "merge it, file the rest as
follow-ups." The harness lacks that valve.

ENG-191 (Lever 2 of [ENG-189]) adds the **selective exit**: a third
reachable path from reviewing — `reviewing → qa` — that fires when
critical=0 AND every remaining major has been adjudged
*deferrable* (ship + record as known debt). The triage decision is
per-finding: the adjudicator splits "how bad" (severity, already
ENG-119 + ENG-190) from "must-fix-now" (a new `blocks_ship` axis),
emits both, and the orchestrator-side predicate gates the exit on
the conjunction.

Selective: **any** major adjudged blocking forces the existing
`reviewing → implementing` loopback. The exit is not all-or-
nothing; it is per-finding triage filtered through the structural
rubric.

## 2. Decisions

### D-001. Selective exit is a new agent-side verdict reason — `verdict result=pass stage=reviewing reason=ship-with-deferred-majors` — that the existing verdict-handler maps to `reviewing → qa` unchanged.

**Rationale.** Linear AC #1: "A PR at 0-critical whose remaining
majors are ALL adjudged deferrable transitions `reviewing → qa`
instead of looping/halting."

The state-transition shape `reviewing → qa` already exists in
`bin/verdict-handler.sh::_VH_FORWARD_TRANSITIONS` (line 24:
`reviewing=qa`). The agent's existing path-C clean exit already
fires `bash bin/pipeline.sh event {issue_id} verdict pass --stage
reviewing` (AGENT_PROMPTS.md:1551, 1653). The orchestrator's
forward-transition logic is `pipeline-stage-summary` →
`_vh_lookup_forward(reviewing)` → `qa`
(`bin/verdict-handler.sh:548-561`). **No verdict-handler change
needed.**

What is new is the *reason* token. The selective exit fires the
same `verdict pass --stage reviewing` marker, optionally carrying
`reason=ship-with-deferred-majors`. The reason is informational
for the orchestrator's post-dispatch hook (D-005) and for the
operator triaging the audit trail — it tells them WHY the exit
was taken without re-reading the ledger.

**The closed registry path.** `bin/pipeline-events.json` already
defines `events.verdict.linear_comment.field_registry_by_arm`
(ENG-115; pipeline.sh:168-174). Add a new top-level array
`pass_reasons: ["ship-with-deferred-majors"]` and a new
`field_registry_by_arm.pass.reason = "pass_reasons"` entry. The
schema validator at `bin/pipeline.sh::_validate_event_payload`
(line 173) prefers `field_registry_by_arm[arm][k]` over
`field_registry[k]`, so:

* `verdict pass --stage reviewing` → no reason, valid.
* `verdict pass --stage reviewing --reason ship-with-deferred-majors`
  → reason validated against `pass_reasons`, valid.
* `verdict pass --stage qa --reason ship-with-deferred-majors` →
  no `field_registry_by_arm.qa.reason` override, falls through to
  `field_registry.reason = "halt_reasons|wait_reasons"`, fails
  because `ship-with-deferred-majors` is not in either union — die
  with "registry: 'ship-with-deferred-majors' not in
  halt_reasons|wait_reasons". The reason token is **scoped to
  result=pass arm only** without widening any unrelated arm.

`bin/generate-vocabulary-doc.sh` regenerates
`docs/pipeline-vocabulary.md` from the registry; the new
`pass_reasons` array surfaces there automatically.

**Reference to constraint.** CLAUDE.md "Pipeline vocabulary"
section: "Single source of truth: `docs/pipeline-vocabulary.md`
(generated from `bin/pipeline-events.json`)." Adding a closed
vocabulary for `pass_reasons` follows the established additive
shape; ENG-115 set the per-arm-override precedent for the pivot
arm.

**Reference to constraint.** Linear AC #7: "The new marker is
registered and the vocabulary doc regenerates cleanly." The
`pass_reasons` array + `field_registry_by_arm.pass.reason` are
the registration; running `bash bin/generate-vocabulary-doc.sh`
regenerates the doc.

**Rejected alternative — new `verdict_result` token (e.g.
`result=ship-with-debt`).** Rejected because (a) it splits the
forward-transition table — `_VH_FORWARD_TRANSITIONS` keys off
the SOURCE stage, not the result, so `result=pass --stage
reviewing` and `result=ship-with-debt --stage reviewing` would
need identical handling, just with the agent's marker shape
different; (b) the verdict-handler dispatch table at
`bin/verdict-handler.sh:547-603` is keyed on
`{stage-summary,rejection,halt,pivot}` (the four marker classes
emitted by `find_fresh_verdict`). Adding a fifth class
duplicates the pass shape with no semantic distinction at the
state machine level; (c) the registry validator's
`verdict_results` union (`bin/pipeline-events.json:5` per the
schema dump) is already five entries — adding a sixth widens the
top-level surface for what is structurally just `pass with a
reason`.

**Rejected alternative — extend `_VH_LOOPBACK_TRANSITIONS` with
`reviewing|qa|pipeline:ship-with-debt`.** Rejected because (a) the
loopback table is structurally for REJECTION verdicts
(`pipeline-rejection`, `bin/verdict-handler.sh:563-586`), and the
selective exit is semantically a PASS forward, not a rejection;
(b) the side-effect labels column would be load-bearing (the only
existing non-empty rows are `planning|brainstorming|pipeline:
supersede` and `reviewing|brainstorming|pipeline:supersede`), and
adding a new `pipeline:ship-with-debt` label is wasted-state
sprawl when the reason token + ledger rows are already the
record; (c) the agent's existing path-C marker shape — `verdict
pass --stage reviewing` — is the right state-machine input
class; the new behaviour rides on it.

**Rejected alternative — no marker, agent emits regular
`verdict pass --stage reviewing` and the orchestrator decides
post-dispatch whether to post the deferred-majors comment by
reading the ledger.** Rejected because (a) the orchestrator
post-hook needs to know if `verdict pass` was taken from a
zero-major path (no deferred-majors comment) or a
deferred-majors path (post the comment), and reading the ledger
to disambiguate is a roundabout proxy for what the agent already
knows in-prompt; (b) explicit reason is the operator-discoverable
audit signal — searching Linear comments for `reason=ship-with-
deferred-majors` is the natural triage recipe.

### D-002. The deferability axis is a per-finding `blocks_ship: bool` + `block_rationale | defer_rationale` + structured `decision_factors` object, emitted on the ENG-190 ledger row (additive to v1 schema). Critical-floor invariant extends to `blocks_ship`.

**Rationale.** Linear scope: "Today `major` conflates two
orthogonal things: *how bad* (severity) and *must-fix-now*
(blocks-ship). Split them."

The ledger is already the per-finding decision record (ENG-190
D-002, D-004). Adding `blocks_ship` to the same row keeps the
adjudicator's per-finding output in one place — schema, validator,
post-dispatch reader. The alternatives explored below
(verdict-review.json extension, a new file) all sprawl across
multiple surfaces for one logical decision.

**Schema extension (additive, v1 stays).** Three new optional
fields on every ledger row:

```json
{
  "ledger_schema_version": 1,
  "issue_id": "ENG-191",
  "dispatch_id": "ENG-191-d0001",
  "iteration": 1,
  "created_at": "2026-06-13T00:00:00Z",
  "finding_class_key": "maintainability:bin/run-stage.sh::naming",
  "cold_severity": "major",
  "adjudicated_severity": "major",
  "decision": "carry",
  "rationale": "first observation: function name drift",
  "blocks_ship": false,                                      // NEW
  "ship_classification_rationale": "doc-drift polish; no behaviour change",  // NEW
  "decision_factors": {                                      // NEW
    "in_changed_code": true,
    "is_regression": false,
    "user_visible": false,
    "reversible_post_ship": true,
    "has_workaround": true
  }
}
```

**Field contracts:**

* `blocks_ship` — boolean. **Required** on rows whose
  `adjudicated_severity ∈ {major, critical}` (i.e. severities
  that drive path-B/D selection). **Optional and ignored** on
  rows with `adjudicated_severity ∈ {minor, nit}` — path-C/D
  selection only consults critical+major. When omitted on a
  major/critical row, the validator emits rc=49 with diagnostic
  `blocks_ship-missing-on-blocking-severity`. When present on a
  minor/nit row, validator emits an `_warn_unknown`-style
  stderr line and passes (free-form extension).
* `ship_classification_rationale` — non-empty string when
  `blocks_ship` is present. Soft-limit ≤ 280 chars
  (informational; not length-checked, mirrors `rationale`).
  When `blocks_ship=true`, names the blocking failure mode
  (e.g. "regression of cached-result-invalidation path;
  exploitable post-ship"). When `blocks_ship=false`, names the
  rubric category that justified deferral (e.g.
  "doc-drift-only; covered by ENG-193 follow-up").
* `decision_factors` — JSON object. **Required** when
  `blocks_ship` is present (on major/critical rows). Closed-
  vocabulary keys: `in_changed_code, is_regression,
  user_visible, reversible_post_ship, has_workaround`. Each value
  is a boolean. Missing keys → rc=49 incomplete. Unknown keys
  → stderr warning, pass. Each factor is the adjudicator's
  yes/no answer to a concrete question (D-003).

**Critical-floor extension (ENG-190 D-005a invariant).** ENG-190's
critical-floor: `cold_severity == critical ⇒ decision == block
AND adjudicated_severity == critical`. ENG-191 EXTENDS this:

> `adjudicated_severity == critical` ⇒ `blocks_ship == true`.

A `critical` finding can NEVER ship as debt. Validator rule:
`adjudicated_severity == critical AND blocks_ship != true` →
rc=49 incomplete, diagnostic `critical-floor-blocks-ship-
violation: adjudicated=critical but blocks_ship=$blocks_ship`.

This is structurally identical to ENG-190's critical-floor and
inherits the same three-layer defense-in-depth: prompt rule,
schema validator, predicate. AC #5 ("A PR with any critical
never takes the exit") is satisfied because the orchestrator's
exit predicate (D-006) requires `every adjudicated-major row has
blocks_ship=false`; a critical finding's blocks_ship=true
short-circuits the predicate, AND the path predicate at the
agent side reads `Adjudicated critical > 0 → path B`
unconditionally — so a critical never reaches the path-D
exit-eligibility branch in the first place.

**Why on the ledger row, not on verdict-review.json.** Three
reasons:

1. **Per-finding shape.** verdict-review.json is per-DIMENSION
   (correctness/testing/maintainability/scope/...), not per-
   finding (`bin/review-payload-schema.sh:24-43`). ENG-190 D-004
   rejected reconstructing per-finding from per-dimension. ENG-191
   inherits that constraint.
2. **Cross-iteration auditability.** The ledger is append-only
   across iterations (ENG-190 D-001). Tracking deferability
   decisions in the ledger gives the retrospective shape (ENG-193
   substrate) and the operator the same cross-iteration audit
   surface ENG-190 built. verdict-review.json is overwrite-on-
   every-dispatch (cleared by `_clear_current_stage_slots`,
   `bin/run-stage.sh:962-964`); putting deferability there loses
   the prior-iteration record.
3. **Already-in-prompt.** The adjudicator's existing §5 prompt
   block (AGENT_PROMPTS.md:1366-1390) emits one ledger row per
   finding. Adding three fields to the same emission is a
   natural extension, not a new write surface.

**Why additive v1 instead of v2 bump.** ENG-190 D-002 explicitly
positioned schema as closed-minimal — "five schema fields beyond
the identifier triple plus the `iteration` counter is the minimum
set the Linear AC #5 mandates." ENG-191 needs three more fields
but the schema mechanics are unchanged: same JSONL shape, same
header, same critical-floor pattern, same severity ladder. A v2
bump would force the validator to accept both v1 (prior
dispatches' rows) and v2 (new rows) — net complexity for no
behavioral difference. Additive v1:

* Existing v1 rows still validate (the new fields are absent;
  validator skips them on minor/nit rows; on major/critical
  rows, the new validation rule fires "blocks_ship missing on
  blocking severity" — IF the row was written by a pre-ENG-191
  dispatch. **Pre-ENG-191 ledger rows on issues mid-flight at
  rollout WILL trip the new validation.**)
* **The mid-flight ledger compatibility burden** is the single
  load-bearing cost: an issue with a pre-ENG-191 row at
  `cold=major adjudicated=major decision=carry` (no
  `blocks_ship`) re-enters reviewing post-ship and the validator
  halts with rc=49 on the prior row. Two mitigation patterns
  available:

  - **Schema-grace clause (preferred).** The validator's
    rc=49 rule fires only on rows whose `dispatch_id` matches
    `$PIPELINE_DISPATCH_ID` (this dispatch's contribution).
    Prior-dispatch rows missing `blocks_ship` are validated
    against the pre-ENG-191 closed contract (no
    `blocks_ship` requirement). Implementation: add a guard
    `[[ "$did_val" == "$dispatch_id_flag" ]] || skip
    blocks_ship checks` around the new validation block in
    `bin/review-ledger-schema.sh`. Cost: ~3 lines + a
    fixture. Benefit: zero-touch rollout for in-flight
    issues.
  - **Operator-bounce.** Halt-and-resume the affected issue;
    operator hand-deletes the offending row(s) per the
    `recovery.md` §12 procedure (ENG-190 D-010), then `bash
    bin/pipeline.sh decide --action continue`. Cost: per-
    issue operator touch on every in-flight ledger at rollout
    cutover. Number of currently-affected issues bounded by
    the K-concurrency cap × time in reviewing — empirically
    ≤4 issues at any moment.

  **Working decision: schema-grace clause.** The grace check is
  cheap and covers the rollout-cutover invariant; operator-
  bounce as a fallback for non-grace failure modes.

**Reference to constraint.** CLAUDE.md "Don't add features
beyond what the task requires." The three new fields map
directly to the Linear ticket's three sub-bullets:
`blocks_ship` (deferability axis), `ship_classification_
rationale` (the per-finding "why"), `decision_factors` (the
structured-question forcing function). No fourth field.

**Reference to constraint.** ENG-190 D-002's
ledger_schema_version=1 closed-minimal posture is preserved —
additive-optional fields are explicitly the migration path the
validator's `_warn_unknown` mechanism leaves open
(`bin/review-ledger-schema.sh:311-318`).

**Rejected alternative — bump to ledger_schema_version: 2 with
`blocks_ship` mandatory.** Rejected because (a) doubles the
validator's known-shape surface (v1-OR-v2 branching at every
field check); (b) creates a cutover hazard (v2 rows on
pre-ENG-191 dispatches' ledgers; mixed-version ledgers within
one issue) without buying behavioral robustness — the schema-
grace check above gives the same isolation for less cost;
(c) ENG-190 OQ-5 explicitly anticipated additive consumption:
"the ledger schema as designed here exposes enough signal …
no schema bump needed for ENG-191."

**Rejected alternative — `blocks_ship` lives in verdict-
review.json as a top-level array of `{finding_class_key:
str, blocks_ship: bool, decision_factors: obj}` entries.**
Rejected per the "per-finding shape" argument above:
verdict-review.json is per-dimension, and tacking a per-finding
array onto it cross-cuts two structurally distinct contracts.
The validator at `bin/review-payload-schema.sh` would need a
new array-typed field; the per-dimension validation loop would
need to know about it. Sprawl for no payoff.

**Rejected alternative — new file
`$(issue_dir)/review-deferability.jsonl` next to the ledger.**
Rejected because (a) one more per-issue artifact, one more
validator, one more detective slot — sprawl; (b) the ledger
already has the per-finding row, and `decision +
blocks_ship` together are the unified per-finding adjudicator
output. Splitting them mid-stage prevents the natural in-prompt
flow ("adjudicate severity + deferability per finding, emit one
row") and forces the agent to write two files in coordination.

### D-003. The structured decision schema (forcing function) — five concrete questions per major, near-deterministic rule mapping to defer/block. Authored in `AGENT_PROMPTS.md` §5; emitted in `decision_factors`.

**Rationale.** Linear scope: "The adjudicator answers a fixed set
of concrete questions per major rather than free-form prose — e.g.
`in_changed_code? / is_regression? / user_visible? / reversible_
post_ship? / has_workaround?` — and a near-deterministic rule maps
the answers to defer/block."

The five questions are the closed set, chosen to align with the
triage rubric in the Linear ticket's IN bullet 2:

| Question | Maps to BLOCK pattern when true | Maps to DEFER pattern when true |
|---|---|---|
| `in_changed_code` | Yes — bug in *changed* path | (No direct mapping; both BLOCK and DEFER patterns can involve unchanged code; informational signal) |
| `is_regression` | Yes — regression of existing behaviour | (n/a; deferrable findings are non-regression) |
| `user_visible` | Yes — exploitable / observable defect | (n/a; non-user-visible polish is a DEFER pattern) |
| `reversible_post_ship` | (false ⇒ BLOCK lean — can't fix it post-merge) | Yes ⇒ DEFER lean — easy to undo if wrong |
| `has_workaround` | (false ⇒ BLOCK lean — no escape valve) | Yes ⇒ DEFER lean — operational mitigation exists |

**Near-deterministic rule (BLOCK-on-uncertainty bias):**

```
if is_regression OR user_visible OR (in_changed_code AND NOT reversible_post_ship):
    blocks_ship = true   # BLOCK
elif NOT in_changed_code AND reversible_post_ship AND (NOT user_visible):
    blocks_ship = false  # DEFER (polish/doc-drift pattern)
else:
    blocks_ship = true   # BLOCK on uncertainty (asymmetric default per Linear scope)
```

**Asymmetric default.** Linear scope: "when uncertain → BLOCK.
Deferral requires positive justification against the rubric
(false-defer = shipping a real bug is worse than false-block =
one extra cycle)." The rule's final fallthrough enforces this.

**Project policy hook (deferred to ENG-193 / future work).**
Linear scope: "The rubric reads risk tolerance from
`learned-rules/<slug>/project-profile.md` where present, falling
back to the conservative default above." V1 ships the
conservative default unconditionally; the project-profile
override is documented as a follow-up hook (§7 OQ-3) — adding
profile-policy plumbing is a separate decision concern that
this ticket's scope does not require to ship.

**The questions are agent-judged, NOT auto-derived.** The
adjudicator answers each yes/no based on its in-prompt
reasoning about the finding text, the diff, the changed-files
list, the brainstorm, and the plan. The structured form is a
forcing function for *consistency*, not a fact extractor: the
agent's job is to BE the discipline. AC #3 calls this out
("a deferrable-vs-blocking classification is asserted against
the rubric in a fixture") — the fixture is prompt-content-test
shape (D-008), not a runtime classifier.

**Reference to constraint.** CLAUDE.md "AGENT_PROMPTS.md is
load-bearing." The five-question rubric, the BLOCK-default
fallthrough, and the prompt-rule wording live in §5 Review
Agent inside the existing fenced block. No new H2 sections; no
fence-count change.

**Reference to constraint.** Linear AC #3: "The per-finding
`blocks_ship` decision is emitted in the verdict payload with
a rationale and the structured-question answers; a deferrable-
vs-blocking classification is asserted against the rubric in
a fixture." The `decision_factors` schema (D-002) carries the
five answers verbatim; the prompt-content test (D-008)
asserts the rubric wording is present and the fallthrough
biases toward BLOCK.

**Rejected alternative — open-ended free-prose rationale, no
structured questions.** Rejected per the Linear ticket's
"forcing function" framing: free prose is consistent on the
same dispatch and inconsistent run-to-run on identical inputs.
The closed-vocabulary five-question shape forces the agent
through identical decision steps, makes the decision
auditable (the answers ARE the audit trail), and feeds the
ENG-190 outcome-flywheel substrate with structured signal.

**Rejected alternative — wider question set (e.g. 10
questions: covered-by-test, named-in-plan, files-in-scope,
PR-author-experience-level, …).** Rejected because every
additional question is one more bit the adjudicator must
reason about per finding; five questions are the minimum that
discriminate the BLOCK/DEFER patterns the Linear ticket
names, and more is YAGNI until empirical drift data exists.

**Rejected alternative — fine-tune the adjudicator on
labelled examples.** Explicitly rejected by the Linear ticket:
"Model fine-tuning of the adjudicator — explicitly NOT this
approach; the decision core is prompt + schema + project-
policy. Fine-tuning is justified only after the ENG-190
flywheel yields thousands of labelled decisions, a stable
policy, and a demonstrated prompt-consistency ceiling." V1
ships prompt + schema.

### D-004. The convergence-rounds signal `N` is read from the ledger via `iteration` + `cold_severity == critical` join. Config-driven cap; sane default of 2 rounds.

**Rationale.** Linear scope: "fires when … critical=0 AND every
remaining major is adjudged deferrable per the rubric above,
after the PR has been at 0-critical for N consecutive rounds
(convergence signal supplied by [ENG-190])."

The ledger gives the adjudicator the convergence signal natively
(ENG-190 D-004 step 1a — inventory prior rows). Compute
`convergence_rounds_at_zero_critical` from the ledger:

```
Read every prior-dispatch row (dispatch_id != current).
Group by iteration.
For each iteration K (descending from max-prior-iteration):
  If ANY row in iteration K has cold_severity == critical → break.
  Else increment counter.
return counter
```

The agent runs this inline as part of the existing ENG-190 step
1a ledger inventory (no new file read, no new resolver). The
selective-exit predicate, evaluated AFTER the count-tuple emission:

```
selective_exit_eligible :=
  Adjudicated critical == 0
  AND  every adjudicated-major finding this dispatch has blocks_ship == false
  AND  convergence_rounds_at_zero_critical >= N
```

**Config key + default.** New config key
`human_checkpoints.review_converge_rounds`, integer ≥ 1.
Validation lives in the agent's prompt (it reads the value from
the project profile, falling back to default 2 on absent/invalid).
Sane default: **2**.

**Why 2.** Two prior rounds with cold_critical=0 means the issue
has cleared cold-detector criticals for two full re-implements
worth of regression risk. One round at 0-critical could be the
implementer fixing a fresh critical that just appeared; two
rounds is a meaningful stable plateau. Three would be
conservative for high-confidence — and operators can tune via
the config key per project. The default sits at the lowest
"plateau" interpretation to keep the harness usable at low
issue-iteration counts (most issues will not have 5+ review
iterations before the operator's patience runs out).

**Convergence on a brand-new issue.** When a PR has only ever
been at 0-critical (e.g. iter 1 found 0 critical AND
deferrable-only majors), `convergence_rounds_at_zero_critical`
equals the count of prior iterations whose cold was 0-critical
PLUS the current. The agent should fold the current iteration
INTO the count — if the current cold is 0-critical AND
convergence_rounds_at_zero_critical ≥ N-1 from prior history,
the exit fires. (If N=2 and this is iter 2 with 0-critical
prior and 0-critical current, eligible.) The first-ever review
iteration with N=2 needs ONE prior iteration of 0-critical
before exiting — so a first-ever review pass with major-only-
deferrable findings does NOT immediately ship; the
implementer-loopback-and-reconverge round earns the exit. This
is the intended "no first-shot deferred-shipment" property.

**Resolution precedence (mirrors ENG-65/ENG-81/ENG-132 shape):**

1. `human_checkpoints.review_converge_rounds` in the target's
   `.pipeline-config/config.json` — highest.
2. Built-in default **2**.

Validation: integer regex `^[0-9]+$`, value `>= 1`. Invalid
values log a warning to stderr (visible in
`$PROJECT_STATE_DIR/<slug>/logs/<ident>-reviewing-*.log` via
the agent's `log` lines) and fall back to the default.

**Where the agent reads the config.** The agent dispatches under
`bash bin/...` allowlist patterns; it does not read config.json
directly. Two clean options:

* **Resolver token (preferred).** `{review_converge_rounds}` —
  `bin/render-prompt.sh::PROMPT_RESOLVERS` registers a new
  resolver that reads `config.json::human_checkpoints.review_
  converge_rounds` via `config_get` (the same pattern
  `bin/guards.sh::check` uses at line 108) and returns the
  integer (or `2` on absent/invalid). The agent receives the
  number inline in its rendered prompt. Token validation in
  `render-prompt.sh` already dies on unknown tokens
  (ENG-87 §D-008) — sequenced resolver-first, prompt-edit-
  second.
* **Hardcoded in the prompt.** Rejected as policy drift — a
  per-project tuning surface that requires re-shipping
  AGENT_PROMPTS.md is bad UX.

V1 ships the resolver-token approach.

**Reference to constraint.** CLAUDE.md "Per-stage dispatch
timeouts (ENG-65)" and "Per-project dispatch concurrency
(ENG-81)" establish the config-key + validation + default
pattern this decision mirrors. Same shape, same diagnostics.

**Reference to constraint.** Linear AC #6: "N is config-driven
and validated; absent/invalid falls back to the default with a
warning." Default 2; validation at the resolver; warning
emitted to dispatch log.

**Rejected alternative — N is hardcoded at 2 in the prompt.**
Rejected because different projects have different tolerance for
"ship with debt" — a payments service may want N=3 or N=5
(more rounds of stability before the valve opens); a research
prototype may want N=1 (faster iteration). The config key is
the established tuning surface.

**Rejected alternative — N is global to the harness (single env
var or single CLAUDE.md constant).** Rejected for the same
project-policy reason as the hardcoded variant; the
`config.json::human_checkpoints` namespace is the canonical
per-project knob set.

**Rejected alternative — derive N from the ledger heuristically
(e.g. "the issue's median iteration-budget × 0.5").** Rejected
as YAGNI — no empirical data yet, the analytics layer is
explicitly out of scope per ENG-190, and a deterministic
default is more debuggable than a heuristic for v1.

### D-005. The orchestrator (NOT the agent) posts ONE Linear comment enumerating the deferred majors on selective-exit dispatch. Source: read this-dispatch ledger rows where `decision=defer-candidate` AND `blocks_ship=false` (or any major-row with blocks_ship=false). Idempotent via `add-comment --sig deferred-majors/<issue>`.

**Rationale.** Linear AC #4: "The orchestrator posts exactly one
deferred-majors comment on the exit; the agent makes no Linear
write for it (envelope-validator clean)."

The agent is forbidden from making this Linear write — see Edge
case 1 below for the envelope-validator hazard. The orchestrator
is the only legal poster. Decision specifics:

**Where in the orchestrator.** `bin/run-stage.sh::main`'s
post-dispatch hook block, stage-gated to reviewing only, runs
AFTER `_validate_review_payload` (invocation at line 2321,
inside the 2317-2329 block) and `_validate_review_ledger`
(invocation at line 2339, inside the 2335-2347 block) and
BEFORE `post_completion_comment` (invocation at line 2381,
inside the 2379-2387 block). NEW helper:
`_post_deferred_majors_comment_if_eligible`. Runs only when:

* `stage == reviewing`
* The agent's verdict marker on the issue has
  `reason=ship-with-deferred-majors` (read via
  `find_fresh_verdict` and inspecting the marker body).

This dispatch-id-scoped read avoids posting the comment on a
loopback or on a clean-pass-without-debt verdict.

**Data source.** The this-dispatch ledger rows. From
`$(issue_dir <ident>)/review-findings-ledger.jsonl`, filter rows
where `dispatch_id == $PIPELINE_DISPATCH_ID` AND
`adjudicated_severity == major` AND `blocks_ship == false`.
Format each row as a Linear bullet:

```
- [major] <file:line from finding_class_key's scope-anchor>: <ship_classification_rationale>
  Decision factors: in_changed_code=<b>, is_regression=<b>, user_visible=<b>,
                    reversible_post_ship=<b>, has_workaround=<b>
  Ledger row: dispatch_id=<id> iteration=<N> finding_class_key=<key>
```

The comment body is composed in shell, NOT in the agent.

**Idempotence.** Use `add-comment --sig deferred-majors/<issue>`.
Per the ENG-150 append-only convention (CLAUDE.md tool-allowlist
section): the sig stamps the dispatch-suffixed `<!-- meta: dedup
key=… -->` marker; same sig + new body posts a fresh chronological
comment. The same comment on the *same dispatch* is idempotent
(the `--sig` infra is the dedup target). On operator-resume after
a halt, a fresh dispatch posts a fresh comment with the new
dispatch_id suffix — operator triages the multi-comment audit via
the operator-mental-model grep recipe.

**Sanitisation (MANDATORY — every interpolated agent-string).**
The deferred-majors comment interpolates SIX fields from each
ledger row into its body: `finding_class_key`,
`ship_classification_rationale`, the five `decision_factors`
boolean values, AND `dispatch_id` + `iteration` in the per-row
"Ledger row: …" suffix. All six come from the JSONL file
where the agent is the writer, so all six are agent-
controlled. The orchestrator MUST re-sanitise every field at
interpolation time, NOT trust the schema validator's row-level
checks. Apply the same `<!-- → <\!--` pattern ENG-119 D-004 /
ENG-122 / ENG-190 D-009 use:

```bash
sanitise_for_comment() {
  local raw="$1"
  raw="${raw//$'\n'/ }"
  raw="${raw//$'\r'/ }"
  raw="${raw//<!--/<\\!--}"
  printf '%s' "$raw"
}
```

Apply to every interpolated field — including ones the
validator already cross-checks (e.g. `dispatch_id`), because a
malformed-but-passing row (e.g. an unknown-field-warning row)
could still drop a marker payload into the comment body. The
comment body itself is plain markdown; no triple-backtick
fences around agent strings (the fence-breakout hazard noted
in ENG-190 D-009 adversarial-test #3 applies only when stdout
is wrapped in backticks; this comment is plain bullets).

**Comment-body shape (operator-discoverable lede + audit table).**
First line is the lede; bullets follow. Operators landing on
the comment via grep see the lede immediately:

```
Review took the selective exit (ENG-191). N major finding(s) deferred as known debt.
ENG-193 will auto-create follow-up tickets per deferred major.

- [major] <sanitised finding_class_key>
  Rationale: <sanitised ship_classification_rationale>
  Decision factors:
    - in_changed_code: <yes|no>
    - is_regression: <yes|no>
    - user_visible: <yes|no>
    - reversible_post_ship: <yes|no>
    - has_workaround: <yes|no>
  Ledger row: dispatch_id=<sanitised dispatch_id> iteration=<sanitised iteration>
```

The lede is fixed-prose (not agent-controlled), so it never
needs sanitisation. Operator audit recipe lives in
`docs/runbooks/operator-mental-model.md` §3 (D-011 update).

**Reference to constraint.** CLAUDE.md "Cross-dispatch staleness
contract (ENG-87)" — the orchestrator-side Linear write goes
through `bash bin/linear.sh add-comment`, which auto-injects the
`<!-- meta: dispatch id=... -->` marker. The chokepoint owns
the marker; we do not emit it manually.

**Reference to constraint.** Linear AC #4 (exact wording):
"the agent makes no Linear write for it (envelope-validator
clean)." This is structural: `_validate_dispatch_envelope`
(ENG-87, `bin/run-stage.sh:1013`) halts the dispatch on
`mcp__plugin_linear` / `curl https://api.linear.app` /
`gh api graphql` / `wget https://api.linear.app` /
`unset PIPELINE_DISPATCH_ID` in transcript. The agent CANNOT
emit this comment without bypassing the envelope; the
orchestrator-side write is the only legal path.

**Rejected alternative — agent emits the deferred-majors
comment as part of its consolidated Linear summary.** Rejected
because (a) Linear AC #4 explicitly forbids it; (b) it bloats
the `completion/reviewing/<issue>` body, which is already
4096-char-limited and carries the ENG-119 dimension-scoring
table + the ENG-190 Adjudicator summary line; (c) operator
discoverability is better with a dedicated `--sig deferred-
majors/<issue>` thread.

**Rejected alternative — orchestrator writes deferred majors
into a new committed artifact `docs/known-debt/<issue>.md` on
the feature branch.** Rejected because (a) committing debt
into a permanent doc adds a sweep-side surface the
`partition_dirty_paths::implementing | ui | qa` allowlist
doesn't cover (this would have to be added — sprawl); (b) the
known-debt record's natural reader is the future
ENG-193-created Linear ticket per deferred major, not a
committed doc; (c) the Linear comment is the
operator-discoverable canonical surface today.

**Rejected alternative — write to verdict-review.json with a
new top-level `deferred_findings[]` array; the orchestrator
reads from there.** Rejected because (a) the ledger already
has the per-finding rows; reading from two sources for one
decision is fragile; (b) verdict-review.json's reader surface
is the ENG-119 dimensional-grading consumer, which doesn't
need per-finding deferability.

### D-006. The path-D selective-exit predicate runs in the agent's prompt logic, NOT in the orchestrator. Orchestrator gates the EFFECT (deferred-majors comment); agent decides the OUTCOME (which verdict marker to emit).

**Rationale.** This decision sits at the agent/orchestrator
boundary. Two natural shapes:

* **Agent decides** — the agent computes the predicate in-prompt
  and emits one of three terminal markers: `verdict pass --stage
  reviewing` (path C clean), `verdict pass --stage reviewing
  --reason ship-with-deferred-majors` (path D selective-exit),
  or `verdict fail --target implementing` (path B loopback).
  Orchestrator transitions based on the marker; no orchestrator-
  side predicate.
* **Orchestrator decides** — the agent emits structured per-
  finding data (the ledger rows already do this), and the
  orchestrator-side hook reads the ledger + computes the
  predicate post-dispatch. The agent emits a single uniform
  `verdict pass --stage reviewing` and the orchestrator decides
  which forward-or-loopback to take.

**V1 ships agent-decides.** Reasons:

1. **Consistency with ENG-190's existing predicate placement.**
   ENG-190 D-004's path-B vs path-C predicate is in the agent's
   prompt, not the orchestrator: `Adjudicated critical > 0 OR
   Adjudicated major > 0`. Putting path-D in the same place
   keeps all three branches under one in-prompt mechanism.
2. **State-machine simplicity.** `verdict-handler.sh`'s
   dispatch table at `bin/verdict-handler.sh:547-603` is keyed
   on marker class (stage-summary / rejection / halt / pivot).
   Agent-decides keeps the table key-uniform: path-D is just
   another `pass + stage` shape that takes the existing
   forward-transition row.
3. **Loopback budget.** The path-B loopback fires `bash
   bin/guards.sh bump {issue} review_rejection` (AGENT_PROMPTS.md:
   1536). The path-D selective-exit does NOT bump
   review_rejection (consistent with path-C clean — no rejection
   was issued). Agent-decides keeps both `bump` and `no-bump`
   under the agent's control, where the rejection-cause is
   already known.

**The orchestrator hook is purely the EFFECT.** Read the agent's
verdict marker; if `reason=ship-with-deferred-majors`, post the
deferred-majors comment. No re-evaluation of the predicate; no
re-derivation of the deferred-majors set. The agent is the
single decider; the orchestrator is the post-effect
publisher.

**Why this is safe under adversarial-agent assumptions.** A
buggy or malicious agent could in principle emit
`reason=ship-with-deferred-majors` on a path-B-eligible state
(any critical, or any blocking major). Defense:

* **Critical-floor invariant (D-002 critical-floor extension).**
  Any critical row's `blocks_ship` must be `true`. The
  validator rejects rows with critical AND blocks_ship!=true at
  rc=49. If the agent forges blocks_ship=false on a critical
  cold finding, the ledger row fails validation and the
  dispatch halts with `review-ledger-invalid` BEFORE the
  selective-exit's effect (deferred-majors comment) fires.
* **Schema validation runs BEFORE the deferred-majors hook.**
  Hook ordering (D-005): validators run first; deferred-majors
  hook runs after. A malformed ledger halts the dispatch
  before the misleading deferred-majors comment is posted.
* **Operator-visible audit trail.** Even if a buggy agent emits
  a path-D marker on a path-B-eligible state without tripping
  the validator (e.g. agent correctly emits blocks_ship=true on
  all rows but then emits the reason token anyway), the
  deferred-majors comment will enumerate zero rows
  (`adjudicated=major AND blocks_ship=false` filter returns
  empty). The operator sees "deferred-majors comment with 0
  bullets" — visibly wrong, easy to triage.
* **No silent shipping.** ENG-138 already gates review_rejection
  trips to `stage == implementing` only; on a `reviewing → qa`
  transition guards.sh does NOT fire. But the QA stage
  CONTINUES to validate the feature; an actual
  correctness/security bug would surface there. So the
  defense-in-depth ladder is: schema validator → path predicate
  → critical-floor → QA gate.

**Reference to constraint.** CLAUDE.md "Don't add error handling
… for scenarios that can't happen." The four defenses above are
calibrated to the real failure modes (buggy agent, prompt drift)
rather than pre-emptive guard-rails for adversarial impossibilities.

**Rejected alternative — orchestrator re-evaluates the path-D
predicate post-dispatch by reading the ledger and the convergence
rounds, overriding the agent's marker if it disagrees.**
Rejected because (a) the agent's marker IS the contract; the
orchestrator-side override creates two sources of truth; (b) the
verdict-handler dispatch table is designed for the agent's
marker as input — overriding mid-table is a new control flow
shape; (c) the orchestrator would need its own jq parser for
the ledger rows, duplicating logic the agent already has
in-prompt.

**Rejected alternative — agent emits two markers (verdict pass
+ a separate `deferred-majors` marker) so the orchestrator
reads each independently.** Rejected because (a) two markers
per exit doubles the dispatch-id matching surface; (b) ENG-87's
strict-id verdict freshness path expects exactly one verdict
marker per dispatch; (c) the existing reason field on the
verdict marker is the natural place.

### D-007. `guards.sh` pre-emption is structural — no code change needed. The selective exit fires `reviewing → qa` (forward transition), which is NOT a rejection. `review_rejection` counter only fires on `bump`, which agent path-D explicitly skips.

**Rationale.** Linear scope: "the exit must pre-empt
`review_rejection` so a PR converging on deferrable-only majors
advances instead of halting."

Today's flow:

* Path B (loopback): agent runs `bash bin/guards.sh bump {issue}
  review_rejection --reason "..."` (AGENT_PROMPTS.md:1536) then
  emits `verdict fail --target implementing`. The bump increments
  the counter. The NEXT dispatch (implementing) re-runs
  `guards.sh check {issue} implementing` which trips at threshold
  (default 2). Halt fires on implementing dispatch start
  (ENG-138).
* Path C (clean): no bump; advance to qa.
* **Path D (selective exit, NEW): no bump; advance to qa.**

`guards.sh::check` only trips on `count >= threshold`. Since
path D doesn't bump, the counter doesn't increase on this
exit. AND ENG-138 already gates the trip to `stage ==
implementing` (`bin/guards.sh:135`), so even if the counter is
ALREADY at threshold from prior failed iterations,
transitioning `reviewing → qa` doesn't cause a halt — the next
QA dispatch's `guards.sh check` is gated to qa, and qa's gate
fires on `qa_rejection`, not `review_rejection`.

**Concrete walk-through.** Issue ENG-191 review iteration 4:

* Iter 1: cold finds 2 majors. Adjudicator carries both as
  major+blocks_ship=true. Path B. Loop back. review_rejection=1.
* Iter 2: cold finds 1 of the 2 (one fixed). Adjudicator
  stabilises at major+blocks_ship=true. Path B. Loop back.
  review_rejection=2.
  * Implementing dispatch start: `guards.sh check ENG-191
    implementing` trips on `review_rejection(2>=2)`. Halt.
  * Operator triages, runs `bash bin/pipeline.sh decide
    ENG-191 --action continue`. Halt cleared, operator-resume
    waypoint posted, review_rejection counter resets via
    `count_marker_since_last_operator_resume` (ENG-123 in
    `bin/guards.sh:83-102`).
* Iter 3 (post-resume): cold finds 1 major. Adjudicator
  downgrades to minor (defer-candidate from ENG-190).
  Adjudicated major=0. Path C. Advance to qa.

Now WITH ENG-191 selective exit:

* Iter 1: same as above. review_rejection=1.
* Iter 2: cold finds 1 major. Adjudicator stabilises at
  major+blocks_ship=**false** (it's polish — doc drift, scope-
  silent on the change). Adjudicated major=1; blocks_ship=false.
  Convergence_rounds_at_zero_critical=2 (both prior iterations
  had 0-critical). **Path D fires.** Advance to qa. No bump.

OR if blocks_ship=true on iter 2 instead, Path B fires
unchanged (the exit is selective, AC #2).

**No code change to `bin/guards.sh`.** The structural property
"path D doesn't bump → guards doesn't trip" is sufficient.
The agent prompt change (D-008) is the load-bearing change.

**Reference to constraint.** ENG-138/ENG-145 narrowing of
the `review_rejection` trip to `stage == implementing` is
the load-bearing prior decision that makes this work without
code change. Without ENG-138, the trip could fire on the
`reviewing → qa` selective exit's NEXT dispatch (qa) if the
counter was at threshold — but the gate prevents that.

**Rejected alternative — explicit `guards.sh check` skip on
the selective exit (e.g. a new env var
`PIPELINE_SKIP_REVIEW_REJECTION_CHECK=1`).** Rejected as YAGNI:
the gate at line 135 already does this structurally. Adding a
skip flag is a workaround for a problem ENG-138 already fixed.

**Rejected alternative — reset `review_rejection` counter on
selective exit (operator-resume-style waypoint).** Rejected
because (a) the counter is the cross-iteration record of how
many real loopbacks the issue went through — it carries audit
value beyond the current dispatch; (b) the operator-resume
waypoint pattern is designed for OPERATOR-initiated resets,
not agent-initiated; introducing agent-initiated resets blurs
the lane-fence (`bin/linear.sh` writer-lane enforcement).

### D-008. AGENT_PROMPTS.md §5 Review Agent gains: the deferability axis, the five-question rubric, the BLOCK-default fallthrough, the path-D selective-exit branch, the new ledger fields (`blocks_ship`, `ship_classification_rationale`, `decision_factors`). Asserted by new prompt-content test cases.

**Rationale.** The load-bearing prompt change. Insertions (all
inside the existing §5 fenced block — no fence-count change):

1. **After the Adjudication block (after line 1390):** insert a
   "Deferability adjudication" block describing the
   five-question rubric (D-003) and the BLOCK-default
   fallthrough. Exact rubric questions enumerated in §5 text.

2. **In the count-tuple emission block (lines 1392-1404):**
   add a new third line emission:
   ```
   Findings:     (critical=N, major=N, minor=N, nit=N)
   Adjudicated:  (critical=N, major=N, minor=N, nit=N)
   Deferrable:   (deferrable_majors=N, blocking_majors=N)
   ```
   `Deferrable:` is the new ENG-191 line; it partitions the
   Adjudicated `major` count by `blocks_ship`. Sum constraint:
   `deferrable_majors + blocking_majors == Adjudicated.major`.

3. **In the Decision path block (lines 1504-1554):** insert a
   new path D between C and the final notes:

   ```
   D. Ship with deferred majors (NEW — ENG-191).
      Mechanical predicate:
        Adjudicated critical == 0
        AND  blocking_majors == 0      (i.e. every adjudicated-major has blocks_ship=false)
        AND  convergence_rounds_at_zero_critical >= {review_converge_rounds}
      Where convergence_rounds_at_zero_critical is computed from the
      ledger as: count of consecutive prior-dispatch iterations
      (descending from most-recent) whose rows all have
      cold_severity != critical, PLUS 1 if this dispatch's cold
      critical == 0.

      Steps:
        - Post a consolidated COMMENTED-state review with deferred-
          majors and any minor/nit observations via
            gh pr review {pr_number} --comment --body "<summary>"
          Summary line: "Reviewed commit {sha[:8]}. {N} personas: PASS.
          0 critical, {M} major adjudged deferrable (shipping with debt)."
        - Post Linear consolidated review summary via `add-comment --sig
          completion/reviewing/{issue_id}`. INCLUDE the Adjudicator
          summary line (ENG-190) AND a new ship-with-debt summary line:
            "Ship-with-debt: {M} deferrable major(s) recorded; orchestrator
            will post deferred-majors comment under sig deferred-majors/{issue_id}."
          The orchestrator (not you) posts the per-finding deferred-
          majors comment. Do NOT post it yourself.
        - Write the stage summary file at `{stage_summary_path}` per
          the Stage summary comment format contract.
        - Run: `bash bin/pipeline.sh event {issue_id} verdict pass
          --stage reviewing --reason ship-with-deferred-majors`
        - Exit. Orchestrator transitions `reviewing → qa`, applies
          pipeline:halted (ENG-56), AND posts the deferred-majors
          comment.
   ```

4. **In the Decision path predicate clarification (lines
   1506-1514):** update the predicate-source to read from
   `Deferrable:` AND `Adjudicated:`:
   * Path B (changes requested) fires iff
     `Adjudicated critical > 0 OR blocking_majors > 0`.
   * Path C (clean) fires iff `Adjudicated critical == 0
     AND Adjudicated major == 0`.
   * Path D (ship-with-debt) fires iff `Adjudicated critical
     == 0 AND Adjudicated major > 0 AND blocking_majors == 0
     AND convergence_rounds_at_zero_critical >=
     {review_converge_rounds}`.
   * **When path D's first three conditions are met but
     convergence_rounds is below {review_converge_rounds},
     emit path B (loopback to implementing) BUT with the
     `review_rejection` bump elided** (sub-variant B′ — no
     fault to charge against the implementer's budget; the
     review verdict is "still convergence-waiting", not
     "fix these things"). The agent's path B body still
     posts the review comment + Linear summary so the
     implementer sees the deferrable-only list and can
     decide whether to address one of them eagerly. The next
     dispatch's convergence counter increments and path D
     becomes eligible the round after.

     Path B′ is mechanically distinct from path B only at the
     `guards.sh bump` step: path B runs `bash bin/guards.sh
     bump review_rejection --reason "..."`; path B′ skips it
     (the prompt rule names the elision explicitly). Same
     verdict marker shape (`verdict fail --target
     implementing`); same loopback transition. The bump
     elision keeps the implement budget intact for the
     waiting-for-convergence rounds, addressing the design
     concern that an issue with ALL-deferrable majors should
     not burn implement_rejection budget while it waits for
     the convergence plateau.

     **Asymmetric to path B.** Path B (real blocking majors)
     bumps `review_rejection` so the threshold halt-for-human
     fires on persistent loopbacks. Path B′ (convergence-
     waiting) does not — its loop is bounded by the
     convergence counter ratcheting monotonically up to N.
     If the issue NEVER reaches the plateau (e.g. fresh
     criticals keep appearing on every iteration), the
     `review_rejection` count stays low while real `critical`
     findings drive path B with bumps. The two paths cannot
     both fire on the same dispatch (mutual exclusion via the
     three predicate conditions).

5. **In the Output block (lines 1565-1646):** update the
   "Append one row per finding" bullet (lines 1617-1632) to
   emit the new ENG-191 fields:
   * On every major/critical row: `blocks_ship` boolean,
     `ship_classification_rationale` non-empty string,
     `decision_factors` object with the five booleans.
   * On minor/nit rows: omit (or leave null — validator
     ignores).

6. **In the Verdict marker block (lines 1648-1671):** add a
   bullet for path D:
   ```
   To ship with deferred majors (path D — adjudicated critical=0,
   all adjudicated majors deferrable, convergence rounds satisfied):

     bash bin/pipeline.sh event {issue_id} verdict pass --stage reviewing --reason ship-with-deferred-majors
   ```

**Test mechanism (mirrors `bin/agent-prompts-content-test.sh`
+ the ENG-190 D-003 / ENG-133 / ENG-190 D-001-D-005 patterns):**

* Assert §5 contains the literal phrase "Deferrable:
  (deferrable_majors=N, blocking_majors=N)".
* Assert §5 contains the five questions verbatim
  (`in_changed_code`, `is_regression`, `user_visible`,
  `reversible_post_ship`, `has_workaround`).
* Assert §5 contains the BLOCK-default fallthrough wording
  ("when uncertain → BLOCK" or equivalent).
* Assert §5 contains the path-D predicate (the three-AND
  expression).
* Assert §5 contains the path-D verdict-marker command
  (`verdict pass --stage reviewing --reason
  ship-with-deferred-majors`).
* Assert §5 does NOT instruct the agent to post the
  deferred-majors comment itself (defensive against AC #4 /
  envelope-validator violation).
* Assert §5 references `{review_converge_rounds}` token.

**Reference to constraint.** CLAUDE.md "AGENT_PROMPTS.md is
load-bearing" — the prompt file's fence-count + section-table
invariants are preserved. No new H2 sections.

**Reference to constraint.** AGENT_PROMPTS.md preamble's
"Sub-agent debris (ENG-100)" — the agent must NOT write fixture
files to verify the predicate. Reason inline.

**Rejected alternative — the new path-D logic lives in a
helper script the agent invokes via Bash.** Rejected because
(a) the reviewing stage allowed-tools list is `(none)` for
custom Bash patterns (per the project profile addendum — only
`bash bin/linear.sh` / `bash bin/pipeline.sh` / `bash
bin/guards.sh` / `bash bin/slack.sh` / `bash bin/metrics.sh`);
adding a `Bash(bash bin/path-d-predicate.sh:*)` widens the
allowlist for one feature; (b) the predicate is in-prompt
arithmetic; the agent already does count-tuple counting and
boolean evaluation; (c) the orchestrator-side check is
post-dispatch via the validator + the reason token, not via a
runtime helper.

### D-009. Schema validator extension — `bin/review-ledger-schema.sh` gains validation for the three new fields, the critical-floor extension, and the schema-grace clause for prior-dispatch rows. NO new exit code (uses existing rc=49 incomplete). NO new halt reason.

**Rationale.** Linear AC #5 requires the critical-floor invariant
to apply to `blocks_ship`; AC #6 requires N validation; AC #7
requires the new marker to register cleanly. The validator does
the structural side of all three.

**Validation rules added (in cmd_validate, after the existing
critical-floor block at lines 304-309):**

1. **`blocks_ship` presence on major/critical rows.** For each
   row where `adjudicated_severity ∈ {major, critical}`, AND
   `dispatch_id == --dispatch-id` (schema-grace clause: skip
   prior-dispatch rows), `blocks_ship` MUST be a boolean:
   ```
   if [[ "$as_val" == "major" || "$as_val" == "critical" ]] && \
      [[ "$did_val" == "$dispatch_id_flag" ]]; then
     local bs_type bs_val
     bs_type="$(jq -r '.blocks_ship | type' <<<"$line" 2>/dev/null)"
     bs_val="$(jq -r '.blocks_ship // "MISSING"' <<<"$line")"
     if [[ "$bs_type" != "boolean" ]]; then
       _emit_incomplete "$line_no" "blocks_ship must be boolean on adjudicated_severity=$as_val rows (this dispatch); got type=$bs_type" "$fck"
       return 49
     fi
   fi
   ```

2. **Critical-floor extension.** If `adjudicated_severity ==
   critical` AND `blocks_ship == false`, return rc=49 incomplete:
   ```
   if [[ "$as_val" == "critical" ]] && \
      [[ "$did_val" == "$dispatch_id_flag" ]]; then
     local bs_val
     bs_val="$(jq -r '.blocks_ship // "MISSING"' <<<"$line")"
     if [[ "$bs_val" != "true" ]]; then
       _emit_incomplete "$line_no" "critical-floor-blocks-ship-violation: adjudicated=critical but blocks_ship=$bs_val" "$fck"
       return 49
     fi
   fi
   ```

3. **`ship_classification_rationale` presence when
   `blocks_ship` is present.** Non-empty string on
   major/critical rows (this dispatch).

4. **`decision_factors` presence + closed-vocabulary keys.**
   On major/critical rows (this dispatch), `decision_factors`
   MUST be an object with all five required boolean keys.
   Each key validated as type=boolean. Missing key → rc=49
   incomplete with the missing key name.

5. **Add new known-fields to the unknown-keys allowlist.**
   `bin/review-ledger-schema.sh:312-318` filters known fields;
   extend the list:
   ```
   - ["ledger_schema_version","issue_id","dispatch_id",...]
   + ["ledger_schema_version","issue_id","dispatch_id",...,
   +  "blocks_ship","ship_classification_rationale","decision_factors"]
   ```

**Schema-grace clause is load-bearing.** Prior-dispatch rows
written by pre-ENG-191 code MUST validate against the
pre-ENG-191 contract (no `blocks_ship` requirement). Without
the grace clause, every in-flight issue at rollout cutover
halts on its first post-cutover reviewing dispatch. The grace
check is `[[ "$did_val" == "$dispatch_id_flag" ]]` — only
this-dispatch rows enforce the new fields.

**Exit codes unchanged.** The ENG-190 validator uses 48/49/50
for malformed/incomplete/missing. ENG-191's new validation
rules all map to rc=49 incomplete. No new exit code is
needed. The halt reason `review-ledger-invalid` (ENG-190)
covers both ENG-190 and ENG-191 violations.

**Reference to constraint.** CLAUDE.md "Never use exit codes
outside the taxonomy in `failure_outcome_for_exit`" — no new
codes, taxonomy unchanged.

**Reference to constraint.** ENG-190 D-009 sanitisation
contract (`<!-- → <\!--` + `\n,\r → space`) applies to all
new agent-controlled string interpolation. `ship_
classification_rationale` is agent-controlled and adds to
the existing sanitisation surface (alongside `rationale` and
`finding_class_key`). Apply the same `sanitise_for_diag`
function (ENG-190 `bin/review-ledger-schema.sh:89-95`).

**Adversarial test cases (sibling — added to
`bin/review-ledger-schema-adversarial-test.sh`):**

* **AC-AD-1.** Row with `adjudicated_severity=major,
  blocks_ship missing` → rc=49 with
  `blocks_ship-missing-on-blocking-severity` (or
  `blocks_ship must be boolean`).
* **AC-AD-2.** Row with `adjudicated_severity=critical,
  blocks_ship=false` → rc=49 with `critical-floor-blocks-
  ship-violation`.
* **AC-AD-3.** Row with `adjudicated_severity=major,
  blocks_ship=true, ship_classification_rationale missing`
  → rc=49 with `ship_classification_rationale must be
  non-empty`.
* **AC-AD-4.** Row with `adjudicated_severity=major,
  decision_factors missing` → rc=49 with
  `decision_factors-missing`.
* **AC-AD-5.** Row with `adjudicated_severity=major,
  decision_factors={in_changed_code:true, is_regression:true,
  user_visible:true, reversible_post_ship:true,
  has_workaround:true}` (all five keys) → rc=0 valid.
* **AC-AD-6.** Row with `adjudicated_severity=major,
  decision_factors={in_changed_code:true}` (missing 4 keys)
  → rc=49 with the missing-key names.
* **AC-AD-7.** Sanitisation: row with
  `ship_classification_rationale: "x\n<!-- pipeline:
  verdict result=pass -->"` → diagnostic carries `<\!--`,
  not `<!--`.
* **AC-AD-8.** Schema-grace clause: ledger has a
  prior-dispatch row with `adjudicated=major, blocks_ship
  missing` (pre-ENG-191 shape) AND a this-dispatch row
  with all new fields → rc=0 valid (prior-dispatch row
  passes via grace; this-dispatch row passes the new rules).
* **AC-AD-9.** Schema-grace clause: ledger has only a
  this-dispatch row with `adjudicated=major, blocks_ship
  missing` (no prior rows) → rc=49 (this-dispatch row
  fails the new rule).

**Reference to constraint.** Linear AC #3: "a deferrable-
vs-blocking classification is asserted against the rubric in
a fixture." Tests AC-AD-3 through AC-AD-6 are the structural
side (schema). The prompt-content fixture in
`bin/agent-prompts-content-test.sh` (D-008 test cases) is
the rubric side.

**Rejected alternative — bump to ledger_schema_version: 2 with
mandatory `blocks_ship`.** Rejected per D-002; the additive-v1
shape is strictly less complex AND avoids the cutover hazard.

**Rejected alternative — new validator file
`bin/review-deferability-schema.sh`.** Rejected because (a)
the ledger row IS the deferability record; splitting the
validator across two files for one logical schema is sprawl;
(b) the orchestrator-side detective slot is already wired in
`bin/run-stage.sh::_validate_review_ledger`; adding a second
detective for the same file is duplicate enforcement.

### D-010. Config key — `human_checkpoints.review_converge_rounds`. New resolver `{review_converge_rounds}` in `bin/render-prompt.sh`. Validation at the resolver; default 2 on absent/invalid.

**Rationale.** Per D-004, N must be config-driven and
agent-readable inline. The resolver pattern is established
(`bin/render-prompt.sh::PROMPT_RESOLVERS` at lines 40-61).

```bash
# In PROMPT_RESOLVERS registry (added near line 60):
review_converge_rounds=_resolve_review_converge_rounds

# Resolver body (added after _resolve_review_ledger_path):
_resolve_review_converge_rounds() {
  local n
  n="$(config_get '.human_checkpoints.review_converge_rounds' 2>/dev/null || printf '')"
  if [[ -n "$n" && "$n" != "null" && "$n" =~ ^[0-9]+$ && "$n" -ge 1 ]]; then
    printf '%s' "$n"
  else
    [[ -n "$n" && "$n" != "null" ]] && log "[render] review_converge_rounds invalid value '$n'; falling back to default 2"
    printf '2'
  fi
}
```

**Config shape (in target's `.pipeline-config/config.json`):**

```json
{
  "human_checkpoints": {
    "review_converge_rounds": 3
  }
}
```

Absence falls back to default 2 with no warning (absent ≠
invalid; the resolver's warn-on-invalid is for type errors
only).

**Reference to constraint.** CLAUDE.md "Per-stage dispatch
timeouts (ENG-65)" — the resolution precedence + validation +
default pattern. CLAUDE.md "Pipeline vocabulary" — no
registry change needed (the value is data, not a closed-
vocabulary token).

**No sidecar entry.** The token resolves to an integer, NOT a
path. `_write_rendered_paths_sidecar` enumerates explicitly
(`bin/render-prompt.sh:101-123`); the new resolver is NOT
added to the sidecar (mirrors the dispatch_id, issue_id,
date, slug exclusions — non-path resolvers stay out).

**Reference to constraint.** ENG-156 D-004 (sandbox-denial
detective sidecar surface) — the sidecar is the closed
allowlist of path-shaped tokens. An integer token does NOT
belong there.

**Rejected alternative — env-var pass-through (`PIPELINE_
REVIEW_CONVERGE_ROUNDS`).** Rejected because env-var
precedence is reserved for launchd-host-level tuning
(`STUCK_TICK_ALARM_MINUTES`, `CLAUDE_MAX_CONCURRENT`); a
per-project policy belongs in `.pipeline-config/config.json`,
not the host plist.

### D-011. Operator runbook + CLAUDE.md row — `docs/runbooks/recovery.md` §13 selective-exit awareness; CLAUDE.md failure-mode quick-reference row for "issue advanced to qa with `reason=ship-with-deferred-majors`".

**Rationale.** New operator-visible behaviour needs operator-
discoverable documentation. Mirrors the ENG-190 D-010 runbook +
CLAUDE.md row pattern.

**`docs/runbooks/recovery.md` new §13 — "Selective exit
(ENG-191)".** Lede-first shape (operator P1):

> **Status:** mid-pipeline at `stage:qa`. **No recovery
> action required**; the issue is advancing normally with
> recorded debt.
>
> **What it means.** Reviewer found N adjudicated-major
> findings, all classified deferrable by the structured
> rubric (D-003). The harness shipped with known debt; ENG-193
> will auto-create follow-up tickets per deferred major.
>
> **Audit recipe** (find the deferred majors for this issue):
>
> ```
> bash bin/linear.sh get-comments <ENG-N> | \
>   jq '.[] | select(.body | test("dedup key=deferred-majors"))'
> ```
>
> **Override (power user only):** to revoke the exit and
> force a re-review with deferred items as blocking,
> manually `bash bin/linear.sh add-label <ENG-N>
> pipeline:halted` + `bash bin/pipeline.sh decide <ENG-N>
> --action continue` from `stage:qa`. This crosses the
> orchestrator-managed `pipeline:halted` lane fence
> deliberately; documented but not optimised in v1.

**CLAUDE.md "Failure-mode quick reference" new row** —
single-line Symptom + single-line Where-to-look, the
canonical compact shape:

| Symptom | Where to look |
|---|---|
| Issue at `stage:qa` with verdict comment `reason=ship-with-deferred-majors` | Selective exit (ENG-191) — no recovery needed; deferred-majors audit + power-user override in `docs/runbooks/recovery.md` §13. |

**Reference to constraint.** CLAUDE.md "Failure-mode quick
reference" — operator-discoverable mental model;
operator-mental-model.md §3 grep recipe is the related
discovery surface.

**Reference to constraint.** Linear scope's IN bullet — "the
orchestrator (not the agent) posts ONE Linear comment
enumerating the deferred majors … as known, accepted debt."
The runbook documents this for the operator.

**No new runbook file.** All ENG-191 operator-relevant
behaviour fits in the existing recovery.md + CLAUDE.md row
(unlike ENG-190's review-findings-ledger.md, which documented
a new artifact file's lifecycle). The selective exit is a
new code path on existing files; no new artifact to document.

## 3. Architecture (where code goes)

```
bin/pipeline-events.json                EDIT (~6 lines).
                                        - Add `pass_reasons:
                                          ["ship-with-deferred-majors"]`
                                          top-level array.
                                        - Add
                                          `events.verdict.linear_comment.
                                          field_registry_by_arm.pass.reason =
                                          "pass_reasons"`.
                                        Run bin/generate-vocabulary-doc.sh
                                        to regenerate docs/pipeline-
                                        vocabulary.md.

bin/review-ledger-schema.sh             EDIT (~80 lines).
                                        - Add known-fields entries:
                                          blocks_ship,
                                          ship_classification_rationale,
                                          decision_factors.
                                        - Add validation block for each
                                          new field, gated on
                                          `adjudicated_severity ∈
                                          {major, critical}` AND
                                          `did_val == dispatch_id_flag`
                                          (schema-grace clause).
                                        - Add critical-floor-blocks-
                                          ship extension rule.
                                        - Extend SEED-HEADER unchanged
                                          (no header text change).

bin/review-ledger-schema-test.sh        EDIT. New positive cases:
                                        - well-formed row with all new
                                          fields (major + blocks_ship=
                                          true/false).
                                        - schema-grace pass: prior
                                          rows without new fields.

bin/review-ledger-schema-adversarial-test.sh  EDIT. New cases AC-AD-1
                                        through AC-AD-9 from D-009.

bin/render-prompt.sh                    EDIT (~12 lines).
                                        - Register
                                          `review_converge_rounds`
                                          resolver in
                                          PROMPT_RESOLVERS.
                                        - Add
                                          `_resolve_review_converge_rounds`
                                          body (after
                                          `_resolve_review_ledger_path`
                                          per D-010).
                                        NO sidecar entry (non-path
                                        token).

bin/render-prompt-test.sh               EDIT. Sibling test for the new
                                        resolver: default 2 on absent,
                                        passes through valid integer,
                                        falls back to 2 on invalid type.

bin/run-stage.sh                        EDIT (~60 lines).
                                        - New helper
                                          `_post_deferred_majors_
                                          comment_if_eligible(ident)`:
                                          reads ledger rows for
                                          this dispatch's
                                          adjudicated=major +
                                          blocks_ship=false; reads the
                                          fresh verdict marker; if
                                          reason=ship-with-deferred-
                                          majors, formats a markdown
                                          bullet list and posts via
                                          `bash bin/linear.sh add-
                                          comment <ident> --sig
                                          deferred-majors/<ident>
                                          --body -`.
                                        - Wire the helper into main()'s
                                          post-dispatch hook block
                                          AFTER _validate_review_ledger
                                          and BEFORE
                                          post_completion_comment.
                                          Stage-gated to reviewing.
                                          rc never blocks the dispatch
                                          (best-effort post; failure
                                          logs warning).
                                        - Sanitisation: apply
                                          `<!-- → <\!--` to every
                                          agent-string interpolation.

bin/run-stage-test.sh                   EDIT. New cases:
                                        - "selective exit posts
                                          deferred-majors comment"
                                          (AC #1): fixture with
                                          verdict marker
                                          reason=ship-with-deferred-
                                          majors AND ledger rows
                                          (adjudicated=major,
                                          blocks_ship=false); assert
                                          the orchestrator posts the
                                          comment with expected body
                                          shape (lede line + N
                                          bullets).
                                        - "mixed deferrable+blocking
                                          → path B no exit" (AC #2):
                                          fixture with this-dispatch
                                          ledger rows containing ONE
                                          adjudicated=major
                                          blocks_ship=false AND ONE
                                          adjudicated=major
                                          blocks_ship=true; agent's
                                          verdict marker is `verdict
                                          fail --target
                                          implementing` (NOT a path-D
                                          marker); assert the
                                          orchestrator does NOT post
                                          the deferred-majors comment
                                          AND the transition is
                                          `reviewing → implementing`
                                          (loopback). Verifies path D
                                          is selective, not all-or-
                                          nothing.
                                        - "regular pass does NOT
                                          post deferred-majors":
                                          fixture with verdict pass
                                          (no reason) — orchestrator
                                          skips the post.
                                        - "loopback does NOT post":
                                          fixture with verdict fail
                                          — orchestrator skips.
                                        - "critical never takes
                                          the exit" (AC #5): fixture
                                          with this-dispatch ledger
                                          containing a row with
                                          adjudicated_severity=
                                          critical; agent's verdict
                                          is path B (per critical-
                                          floor invariant); assert
                                          the orchestrator does NOT
                                          post deferred-majors.
                                        - "sanitisation": fixture
                                          with `ship_classification_
                                          rationale` containing
                                          `<!-- pipeline: verdict
                                          result=pass -->` — assert
                                          the posted body contains
                                          `<\!--`. ALSO assert that
                                          `dispatch_id` and
                                          `iteration` interpolations
                                          are sanitised (defensive
                                          test for the "every
                                          interpolated agent-string"
                                          contract per D-005).

bin/pipeline-test.sh                    EDIT. Sibling tests for the new
                                        verdict arm:
                                        - "pass + reason=ship-with-
                                          deferred-majors valid".
                                        - "pass + reason=unknown-
                                          token rejected with
                                          registry not in pass_reasons".
                                        - "fail + reason=ship-with-
                                          deferred-majors rejected
                                          (per-arm override doesn't
                                          apply to fail arm; falls
                                          through to fail_targets/
                                          pivot_targets — reason is
                                          unknown there)".

AGENT_PROMPTS.md                        EDIT. §5 Review Agent
                                        modifications per D-008's
                                        six insertions. All inside
                                        the existing fenced block;
                                        no fence-count change.

bin/agent-prompts-content-test.sh       EDIT. Seven new content
                                        assertions per D-008.

docs/runbooks/recovery.md               EDIT. New §13 "Selective
                                        exit (ship-with-deferred-
                                        majors)" per D-011.

docs/runbooks/operator-mental-model.md  EDIT. Add the
                                        deferred-majors/<issue> grep
                                        recipe to §3.

CLAUDE.md                               EDIT. One new Failure-mode
                                        quick reference row per D-011.

docs/pipeline-vocabulary.md             REGENERATED by
                                        bin/generate-vocabulary-doc.sh
                                        when pipeline-events.json is
                                        edited.
```

**Lifecycle dataflow (selective-exit dispatch, K-th reviewing
iteration):**

```
[Orchestrator: bin/run-stage.sh main()]      [Agent (claude -p)]
  allocate_dispatch_id
    └─ export PIPELINE_DISPATCH_ID=ENG-N-d000K
  _ensure_progress_md
  _ensure_review_ledger   (ENG-190; no-op if file exists)
  _clear_current_stage_slots
    └─ rm -f stage-summary-reviewing.md
    └─ rm -f verdict-review.json
    └─ (ledger NOT cleared — ENG-190 D-006)
  render-prompt.sh
    └─ {review_ledger_path}        → $issue_dir/review-findings-ledger.jsonl
    └─ {verdict_review_path}       → $issue_dir/verdict-review.json
    └─ {review_converge_rounds}    → 2  (default) or config value (NEW — D-010)
    └─ {dispatch_id}               → ENG-N-d000K
  dispatch.sh
    └─ claude -p ─────────────────────────▶ Read input files (incl. ledger)
                                            Read review-findings-ledger.jsonl
                                            Inventory prior rows
                                            Compute iteration K
                                            Compute convergence_rounds_at_zero_critical
                                              from ledger
                                            Dispatch sub-agents (cold)
                                            Merge findings → severity-tagged list
                                            For each finding:
                                              - Match against prior keys (ENG-190 D-004)
                                              - For major/critical findings:
                                                  Answer 5 structured questions (NEW — D-003)
                                                  Apply rule → blocks_ship + ship_classification_
                                                    rationale + decision_factors (NEW — D-002)
                                            Emit Findings: (cold) line
                                            Emit Adjudicated: (post-memory)
                                            Emit Deferrable: (deferrable_majors=N,
                                              blocking_majors=N) line (NEW — D-008)
                                            Dimension scoring → in memory
                                            Anti-bias pass
                                            Decision path A/B/C/D using
                                              Adjudicated counts + Deferrable counts +
                                              convergence_rounds (NEW — D-006)
                                            Output:
                                              - gh pr review --comment
                                              - linear.sh add-comment --sig
                                                completion/reviewing/ENG-N
                                              - Write stage-summary-reviewing.md
                                              - Write verdict-review.json
                                              - Edit append review-findings-ledger.jsonl
                                                with NEW fields per row
                                              - Append progress.md (path C/D only)
                                              - pipeline.sh event ... verdict pass
                                                --stage reviewing --reason
                                                ship-with-deferred-majors  (path D, NEW)
    ◀───────────────────────────────────── exit
  _validate_dispatch_envelope (ENG-87)
  _validate_review_payload (ENG-119)
  _validate_review_ledger (ENG-190 + NEW ENG-191 rules)
  _post_deferred_majors_comment_if_eligible   ◀── NEW (D-005)
    └─ find_fresh_verdict → reason=ship-with-deferred-majors?
    └─ if yes: read ledger rows for dispatch_id=current,
        adjudicated=major, blocks_ship=false
    └─ format markdown bullets + post via
        `bash linear.sh add-comment --sig deferred-majors/<ident>`
  post_completion_comment
  verdict-handler picks up agent's verdict marker
    └─ pass + stage=reviewing → forward transition reviewing → qa
       (reason field is informational; handler ignores)
```

## 4. Data flow

**Producer (path-D selective exit):** review agent on a dispatch
where critical=0 AND every adjudicated-major has blocks_ship=
false AND convergence_rounds_at_zero_critical >= N. Emits:

* `Adjudicated:` line with major>0.
* `Deferrable:` line with deferrable_majors>0, blocking_majors=0.
* Per-finding ledger rows with the three new fields.
* Verdict marker: `verdict pass --stage reviewing --reason
  ship-with-deferred-majors`.

**Producer (path-B / path-C unchanged):** agent emits the
existing markers; ledger rows now include the three new fields
on major/critical rows even on path B (the structured-question
answers are useful as ENG-190 cross-iteration record even when
the exit doesn't fire this round). Path B / C verdict markers
unchanged.

**Storage:** `$(issue_dir <ident>)/review-findings-ledger.jsonl`
(extended schema). Append-only across all review dispatches.

**Reader (v1):**

1. The same review agent's adjudication step on the NEXT review
   dispatch — reads ledger as ENG-190 already does.
2. The orchestrator's `_post_deferred_majors_comment_if_eligible`
   helper — reads this-dispatch rows only, filters
   adjudicated=major + blocks_ship=false.

**Detective reader:** `bin/run-stage.sh::_validate_review_ledger`
post-dispatch scan (extended with ENG-191 rules).

**Linear-comment surfaces:**

| Surface | Sig | Writer | Body |
|---|---|---|---|
| Completion summary | `completion/reviewing/<issue>` | orchestrator (via post_completion_comment, ENG-11) | Agent's stage-summary-reviewing.md (includes Adjudicator summary line per ENG-190 + ship-with-debt summary line per ENG-191 D-008). |
| Deferred majors | `deferred-majors/<issue>` | orchestrator (NEW, D-005) | Markdown bullet list of this-dispatch's deferred majors. |
| Verdict | (none — verdict markers are body-only) | agent (via `bash bin/pipeline.sh event`) | `<!-- pipeline: verdict result=pass stage=reviewing reason=ship-with-deferred-majors -->` |

## 5. Error handling

**Halt cases (this ticket's contract):**

| Failure mode | rc | Outcome token | Halt reason | Operator recovery |
|---|---|---|---|---|
| Agent emits `verdict pass --reason ship-with-deferred-majors` but ledger has any this-dispatch critical row | 49 | review-ledger-incomplete | review-ledger-invalid (existing) | The critical-floor-blocks-ship rule trips at validation; halt body names the row. Operator inspects ledger; fixes by hand if the agent's classification was wrong. |
| Agent emits `verdict pass --reason ship-with-deferred-majors` but a this-dispatch major row has blocks_ship=true | not a structural error — the Deferrable: line's blocking_majors > 0 would have driven the agent to path B in-prompt; reaching path D in this state is an agent-side bug | (caught only by AC-AD-style fixture test if at all) | n/a | If observed in prod, operator inspects the agent's reasoning in the transcript; ENG-190 retrospective shape would surface "agent emits ship-with-debt marker on blocking_majors>0 state" as a drift incident. |
| Major row missing `blocks_ship` on this dispatch | 49 | review-ledger-incomplete | review-ledger-invalid | Inspect agent transcript; the prompt rule was not followed. Operator hand-edits row or deletes + `--action continue`. |
| Major row missing `decision_factors` on this dispatch | 49 | review-ledger-incomplete | review-ledger-invalid | Same as above. |
| `decision_factors` missing one of the five required keys | 49 | review-ledger-incomplete | review-ledger-invalid | Diagnostic names which keys are missing. |
| `pass_reasons` registry mismatch (e.g. agent emits `reason=unknown-token`) | 1 | verdict-handler protocol-violation | protocol-violation | The `bin/pipeline.sh event` validator dies BEFORE posting the marker (`_validate_event_payload`). The agent's bash invocation fails with stderr `registry: 'unknown-token' not in pass_reasons`. |
| `verdict-handler.sh` receives `verdict pass stage=reviewing reason=ship-with-deferred-majors` but no other state changes | 0 | success | n/a | Normal path. Reason is informational. Forward transition fires. |
| Deferred-majors-comment post fails (network / Linear API outage) | non-fatal | (log warning) | n/a | The orchestrator logs the failure and proceeds; the transition still fires. On next operator inspection, the deferred-majors comment is absent; operator can re-derive from the ledger by reading `$(issue_dir <ident>)/review-findings-ledger.jsonl`. |

**Soft-fail cases (NOT this ticket's halt scope):**

* `_post_deferred_majors_comment_if_eligible` failing to post
  (Linear API outage) does NOT halt the dispatch. The forward
  transition to qa still fires; the audit is recoverable from
  on-disk ledger. Same shape as ENG-119's review-payload-post
  warning: the post is for operator visibility, not state.

* `convergence_rounds_at_zero_critical` mis-computation
  (off-by-one in agent's prompt logic) is a soft drift; v1
  detects nothing post-hoc. The retrospective could surface
  "agent's path-D count was N=1 when ledger shows it should
  have been 2" as a future shape, but v1 trusts the agent's
  in-prompt arithmetic.

**Logging.** Validator stdout follows the existing
`review-ledger-{malformed,incomplete,missing}: row N: <msg>
finding_class_key=<key>` shape (ENG-190 D-009). New diagnostic
messages live in `bin/review-ledger-schema.sh` per AC-AD-1
through AC-AD-9.

**No retry path.** Same as ENG-190 / ENG-119 — emission is
deterministic; failure means agent bug. Halt + operator
triage.

## 6. Edge cases

1. **Agent posts the deferred-majors comment itself.** Two
   sub-cases with different defenses:
   * **Via `mcp__plugin_linear` / `curl https://api.linear.app`
     / `gh api graphql` / `wget`.** The ENG-87
     `_validate_dispatch_envelope` detective halts the
     dispatch with `dispatch-envelope-violation` (rc=29) post-
     dispatch. Since validation runs BEFORE
     `_post_deferred_majors_comment_if_eligible` in the hook
     block, the orchestrator's post never fires; no duplicate.
   * **Via the allowed `bash bin/linear.sh add-comment` choke-
     point with a forged `--sig deferred-majors/<issue>`.**
     This bypasses the envelope-validator (the allowed
     chokepoint is the legitimate Linear write path; agents
     already use it for `completion/reviewing/<issue>`). The
     agent could in principle emit a `--sig deferred-majors/
     <issue>` post itself; the orchestrator then ALSO posts
     under the same sig (with the dispatch-suffixed dedup key
     `…/d000K`), producing TWO chronological comments under
     similar sigs. Defenses: (a) AGENT_PROMPTS.md §5 Output
     bullet forbids it explicitly; (b) prompt-content test
     (D-008 assertion #6) catches at edit time; (c) runtime
     produces two comments visibly grep-able under `deferred-
     majors/<issue>` with different dispatch_id suffixes —
     operator triage signal. Defense-in-depth via transcript-
     based assertion on the literal `deferred-majors/` sig is
     YAGNI for v1 (no observed-needed); flagged for follow-up
     hardening if drift observed.
   * **Chained command** (`bash bin/linear.sh add-comment …;
     mcp__plugin_linear …`). The envelope-validator's prefix-
     match is documented as evadable per CLAUDE.md "Operator
     gotcha — chained-command blind spot." Bounded by the
     prompt-side defense at AGENT_PROMPTS.md preamble; not
     this ticket's primary concern.

2. **`convergence_rounds_at_zero_critical` is gameable.** An
   agent could read the ledger and refuse to record critical
   findings on prior dispatches' rows. But:
   - ENG-190 prompt forbids modifying prior-dispatch rows (the
     ledger is append-only; agent only emits this-dispatch
     rows).
   - The ENG-190 D-009 validator detects modification of
     prior rows via row-format violations.
   - The cold-pass contract (ENG-190 D-003) keeps sub-agents
     from accessing the ledger, so they can't be coerced into
     emitting "0 critical" on a real critical.
   Bounded by ENG-190's existing defenses.

3. **First-ever reviewing dispatch on an issue with no prior
   review iterations.** `convergence_rounds_at_zero_critical=
   0` (no prior rows). Default N=2 means selective exit cannot
   fire — agent falls through to path B if any major exists
   blocking, or path C if all clear. This is the intended
   "no first-shot deferred-shipment" property (D-004).

4. **Issue at iter K reaches `Adjudicated major>0,
   blocking_majors=0, convergence_rounds=N-1`.** Path D's
   convergence-rounds gate is unmet; agent falls through to
   path B (per D-008 update). Loop back; on iter K+1 the
   counter increments and the exit is eligible. **NOT a hang
   risk** — the implementer agent's loopback dispatch
   re-emits with progress (any progress); the convergence
   counter ratchets monotonically. If the implementer makes
   zero progress, ENG-138's `review_rejection` trip at
   threshold halts the issue, restoring operator-visible halt
   behaviour.

5. **`pass_reasons` registry contains an empty string or null
   value.** Validator (`bin/pipeline.sh::_validate_registry_
   union`) iterates entries; an empty string entry would match
   an empty `--reason ""`. The agent doesn't emit empty
   reasons (the bash invocation requires `--reason <value>`
   with a non-empty value). Defensive: when registering
   `pass_reasons`, the entry MUST be `"ship-with-deferred-
   majors"` exact; pipeline-test.sh's adversarial fixture
   covers empty-string mismatch.

6. **Two consecutive selective exits (issue advances qa→...→
   building, gets `building → implementing` loopback, comes
   back to reviewing).** Ledger is preserved across stages
   (per-issue lifetime). Ledger has new-dispatch rows for the
   new reviewing iteration; convergence counter is recomputed
   from the entire ledger. If the issue's history is
   `(0-cold-critical)×3` consecutive then `1-cold-critical
   round` then `(0-cold-critical)×2`, the count restarts at
   the most recent critical. Default behaviour is correct
   without special handling.

7. **Operator manually edits ledger to remove `blocks_ship`
   from this-dispatch rows.** Schema-grace clause (D-002):
   the dispatch_id-match check skips prior-dispatch rows but
   NOT this-dispatch rows. After hand-edit + `--action
   continue`, the next dispatch's pre-dispatch validation
   would actually pass (the ledger is read at dispatch START;
   the modified row's dispatch_id is no longer the current
   dispatch_id) — so the edit succeeds. This is the documented
   recovery for `recovery.md` §12 (ENG-190).

8. **Dry-run (`PIPELINE_DRY_RUN=1`).** Same as ENG-119 / ENG-
   190: `_post_deferred_majors_comment_if_eligible` runs but
   the `bash bin/linear.sh add-comment` call is dry-run-
   gated by linear.sh itself (the `linear.sh` chokepoint
   honours `PIPELINE_DRY_RUN=1` and logs "would post" instead
   of posting). Detective + validator run as normal.

9. **`PIPELINE_DISPATCH_ID` unset when validator runs.**
   ENG-190 D-009 fail-open shape: `--dispatch-id` is optional;
   when absent, schema-grace clause becomes a no-op
   (no prior/current distinction). All rows must satisfy
   the new ENG-191 rules. This is the test-fixture case
   (e.g. running `bash bin/review-ledger-schema.sh validate
   tests/fixtures/ledger.jsonl` without `--dispatch-id`).

10. **Ledger has a row with `adjudicated_severity=minor` AND
    `blocks_ship=true` (agent emitted blocks_ship on a
    non-major row).** Validator skips the
    blocks-ship-presence check for minor/nit rows (D-002 field
    contract). The row passes; `_warn_unknown` does NOT fire
    because `blocks_ship` is in the new known-fields list.
    Cost: agent free-form data on minor rows. Bounded; no
    correctness impact.

11. **Sandbox-denial on ledger write.** Pre-existing ENG-156
    detective (`_validate_rendered_paths`) catches sandbox
    denials on path-shaped tokens; the ledger path is in the
    sidecar (ENG-190 D-008). New ENG-191 fields are content,
    not path — no new sidecar entry needed.

12. **Test-fixture leak (CI's ledger fixture written to a
    real issue's path).** ENG-190 D-009's `--ident`
    cross-check catches this; ENG-191's new validation
    rules apply per-row, so the leak still trips rc=49 if
    the new rules fail. Bounded.

13. **Concurrent dispatches on the same issue.** ENG-81
    per-issue concurrency lock at `$(issue_dir)/.in-flight.
    lock` prevents this; no new concurrent-writer hazard
    introduced.

14. **The deferred-majors comment's body exceeds 4096 chars.**
    A pathological PR with 100+ deferrable majors. The
    `linear.sh add-comment` chokepoint truncates per the
    existing Linear-API limit. Bounded by reality (no
    real PR has 100+ deferrable majors); operator-visible
    truncation via `<!-- meta: metric name=summary_truncated
    -->` (the existing post_completion_comment fallback). Not
    blocking v1.

## 7. Open questions

* **OQ-1.** Should the verdict marker also carry the
  deferrable-majors COUNT (e.g. `verdict pass --stage
  reviewing --reason ship-with-deferred-majors --count 3`)?
  **Working decision:** no in v1. The count is in the
  deferred-majors comment body; the marker is the
  state-transition trigger, not the audit surface. If
  retrospective wants the count for trend analysis, it can
  derive from the ledger (more reliable than parsing marker
  fields).

* **OQ-2.** Should `decision_factors` allow project-policy
  override keys (e.g. `regulatory_compliance: bool` for
  payments paths)? **Working decision:** no in v1. The five
  keys are the closed vocabulary; project-policy hooks fit
  better as profile-derived risk-tolerance multipliers on
  the BLOCK-default fallthrough — a follow-up if
  observed-needed.

* **OQ-3.** Linear scope mentions reading risk tolerance
  from `learned-rules/<slug>/project-profile.md`. **Working
  decision:** defer to a follow-up. V1 ships the
  conservative-default rubric unconditionally; the project-
  policy hook is structural plumbing (a new resolver token
  `{project_risk_policy}` reading a new profile section) that
  doubles the implementation surface for one feature. Not in
  the IN bullet's primary scope.

* **OQ-4.** Should the orchestrator's deferred-majors comment
  include a link to ENG-193 (the follow-up auto-ticketing
  ticket)? **Working decision:** yes — one line at the
  bottom of the comment body: "These will be auto-ticketed
  by ENG-193." Operator-discoverable context. Cost: one
  literal line in the helper.

* **OQ-5.** Cross-coordination with ENG-192 (implement-side
  fix-the-class). ENG-192 may want to know which findings
  were deferred so it doesn't pre-emptively try to fix them
  on the loopback. **Working decision:** Same as ENG-190
  OQ-6 — ENG-192 can opt to read the ledger or not; the v1
  ledger schema (after ENG-191 extensions) exposes the
  necessary signal. No pre-emptive plumbing here.

* **OQ-6.** Test for the "convergence-rounds gate" predicate.
  AC #1 + AC #5 cover the structural cases. Should there be
  a fixture that simulates a 4-iteration history with
  varying cold-critical patterns and asserts the agent's
  computed convergence count is correct? **Working
  decision:** yes — add an integration fixture in
  `bin/run-stage-test.sh` (AC-1 mirror): construct a 4-row
  ledger spanning 3 prior dispatches with patterns
  `[0-critical, 1-critical, 0-critical, 0-critical (current)]`
  and assert the agent's prompt-computed
  convergence_rounds_at_zero_critical equals 2 (the two most
  recent rounds; the 1-critical breaks the run). Difficult to
  test the agent's in-prompt arithmetic directly without a
  runtime harness; instead, assert the LEDGER state and
  document the expected prompt behavior in the test
  preamble. Implementation-time call.

* **OQ-7.** Schema-grace clause edge: what if a future
  dispatch's `--dispatch-id` argument is unset (e.g. operator
  manually validates the ledger out-of-band with no flag)?
  Per D-009 / ENG-190 D-009 fail-open shape, the schema-
  grace check becomes a no-op (all rows treated as "this
  dispatch") — which means an out-of-band validation against
  a ledger containing both old and new rows would trip rc=49
  on the old rows missing `blocks_ship`. **Working decision:**
  document the workflow: operators running ad-hoc validation
  should pass `--dispatch-id $(jq -r 'last(rows by dispatch_id)'
  …)` to scope the grace clause. Mention in the runbook.

* **OQ-8.** Reason-field defaulting on `bin/pipeline.sh event
  verdict pass --stage reviewing`. The agent could
  accidentally omit `--reason ship-with-deferred-majors` on a
  path-D exit (typing slip). Then the orchestrator's
  `_post_deferred_majors_comment_if_eligible` sees no reason
  and skips the post — deferred majors disappear from
  operator audit. Mitigation:
    * Prompt rule emphasises EXACT command shape (D-008
      includes the literal bash line).
    * The prompt-content test pins the verbatim command.
    * On a missed --reason, the ledger still has the rows;
      operator can derive from `$(issue_dir <ident>)/review-
      findings-ledger.jsonl` per recovery.md §13.
  **Working decision:** documented; bounded.

* **OQ-9.** Convergence-rounds default tuning.  Default 2 may
  be too eager for some projects (premature shipping with
  debt). Alternative: default 3, which is more conservative.
  **Working decision:** 2 — the lowest defensible plateau.
  Operators with stricter standards tune via the config key
  per D-010. Retrospective can audit "issues that shipped
  with debt at N=2 and later had QA failures" — a
  flywheel-grade signal for tuning the default if needed.

## 8. Out-of-scope reminders

* **Auto-creating follow-up Linear ticket per deferred major
  ([ENG-193]).** This ticket emits the rows AND posts the
  deferred-majors comment. ENG-193's contract is to
  auto-ticket. Cross-dispatch hand-off via the
  `deferred-majors/<issue>` Linear comment.
* **Lever 1 — adjudication memory ([ENG-190]).** Blocking
  parent; consumed unchanged.
* **Lever 3 — implement-side fix-the-class ([ENG-192]).**
  Independent. ENG-192 may read the ledger; ENG-191 does not
  pre-empt that choice.
* **Project-policy risk-tolerance override (Linear IN bullet
  2's last line).** Deferred to OQ-3 follow-up.
* **Outcome-correlation automation (does the deferral later
  regress?).** Out of scope; the substrate is the ledger +
  the deferred-majors comment. Retrospective shape later.
* **Model fine-tuning.** Explicitly out of scope per Linear
  ticket.

## 9. ADR stress test

This brainstorm puts pressure on the following accepted
decisions:

* **ENG-190 ledger schema (closed-minimal posture).** D-002
  adds three optional fields to the v1 schema. Stress: ENG-190
  D-002 said "five schema fields beyond the identifier triple
  is the minimum." ENG-191 increases this by three. Mitigation:
  the three new fields are conditional (required only on
  major/critical rows this dispatch). The schema-grace clause
  preserves backwards compatibility. The OQ-5 hook ENG-190
  already anticipated — "ENG-191 consumes v1 unchanged" — is
  honoured in that the schema VERSION (=1) is unchanged; only
  the optional-field count grew. Within contract.

* **ENG-87 cross-dispatch staleness contract.** The schema-
  grace clause cross-checks `dispatch_id == --dispatch-id`
  per row, which uses the ENG-87 dispatch-id primitive. Adds
  ONE new reader of the primitive in the validator. Strictly
  additive; no stress.

* **ENG-115 per-arm field-registry-override.** D-001 adds
  the SECOND per-arm override (`pass.reason`); the FIRST was
  `pivot.{target,reason}` per ENG-115. The
  `field_registry_by_arm` mechanism scales linearly with
  arm/field count; ENG-191 doubles the override count from
  two entries to three. Within contract — no parser-side
  generalisation needed.

* **ENG-133 count-tuple emission (Findings: line).** ENG-190
  already added `Adjudicated:`. ENG-191 adds `Deferrable:`.
  The Findings:, Adjudicated:, Deferrable: triple is now the
  full count-tuple emission contract. No orchestrator-side
  parser (verified — `bin/agent-prompts-content-test.sh` and
  retrospective are the only readers). Prompt-content test
  surface expands; not a stress.

* **CLAUDE.md "Sub-agent debris (ENG-100)".** The agent does
  NOT write fixture files to verify path-D arithmetic; the
  five-question rubric is in-prompt reasoning. Same constraint
  as ENG-190; respected.

* **CLAUDE.md "AGENT_PROMPTS.md is load-bearing."** §5 gains
  ~30 lines (the new path-D block + the Deferrable: line +
  the rubric). No fence-count change; no new H2 section. Within
  contract.

* **CLAUDE.md "Don't add features beyond what the task
  requires."** The Linear ticket names five specific shapes:
  (1) `reviewing → qa` selective transition; (2) deferability
  axis; (3) triage rubric; (4) structured decision schema; (5)
  marker registration. ENG-191 implements exactly these five.
  No sixth.

* **CLAUDE.md "Defense-in-depth: when a stage's contract says
  'agent must not invoke tool X,' prefer a transcript-based
  assertion over a post-dispatch state check."** AC #4 says
  agent must NOT post the deferred-majors comment. Two
  defenses: (a) prompt-content test (compile-time); (b)
  envelope validator catches `mcp__plugin_linear` and curl/
  wget at runtime. The runtime defense is NOT a transcript-
  based assertion for "agent posted via bash bin/linear.sh
  add-comment --sig deferred-majors/" — because that IS
  allowed for OTHER sigs (the agent posts via that exact
  command for `completion/reviewing/<issue>`). Adding a
  transcript-based deny on the specific sig is feasible but
  YAGNI for v1. Documented as future hardening in OQ-8 vein.

## 10. Simpler-alternative pass

Per-decision rejected alternatives documented inline. Consolidated:

| Decision | Rejected alternative | Why rejected |
|---|---|---|
| D-001 | New `verdict_result` token (e.g. `result=ship-with-debt`) | Splits the forward-transition table; widens the top-level verdict_results union; duplicates the pass semantic. |
| D-001 | New `_VH_LOOPBACK_TRANSITIONS` row `reviewing\|qa\|pipeline:ship-with-debt` | Loopback table is for rejection verdicts; introduces a new side-effect label for no payoff. |
| D-001 | No marker; orchestrator derives from ledger only | Loses operator-discoverable audit signal; roundabout proxy. |
| D-002 | Bump ledger schema to v2 | Doubles validator surface for no behavioural difference; ENG-190 OQ-5 anticipated additive. |
| D-002 | Per-finding `blocks_ship` in verdict-review.json | verdict-review.json is per-dimension; cross-cuts two contracts. |
| D-002 | New file `review-deferability.jsonl` | One more validator + one more detective for one logical schema. |
| D-003 | Free-prose rationale (no five questions) | Loses cross-iteration consistency; defeats forcing-function intent. |
| D-003 | Wider question set (10+) | YAGNI; the five discriminate the BLOCK/DEFER patterns. |
| D-003 | Fine-tune the adjudicator | Explicitly out of scope per Linear ticket. |
| D-004 | N hardcoded at 2 in prompt | Project-policy concern. |
| D-004 | N as global env var | Same as hardcoded; ignores per-project tuning surface. |
| D-004 | Heuristic N from ledger | YAGNI; no empirical data; harder to debug. |
| D-005 | Agent posts deferred-majors comment | Linear AC #4 forbids; envelope-validator risk. |
| D-005 | Write to committed artifact `docs/known-debt/<issue>.md` | Sweep-surface sprawl; ENG-193's natural consumer is Linear, not a committed file. |
| D-005 | New top-level `deferred_findings[]` in verdict-review.json | Two sources of truth for one record. |
| D-006 | Orchestrator re-evaluates path-D predicate post-dispatch | Two deciders; duplicates ledger parser. |
| D-006 | Agent emits two markers (pass + deferred-majors) | ENG-87 strict-id verdict freshness path expects exactly one verdict per dispatch. |
| D-007 | Explicit `guards.sh check` skip for path D | YAGNI; ENG-138 gate already does this structurally. |
| D-007 | Reset `review_rejection` counter on path D | Blurs lane-fence; counter is the operator audit signal. |
| D-008 | Path-D predicate lives in a helper Bash script | Widens reviewing-stage allowlist; in-prompt arithmetic is sufficient. |
| D-009 | New exit codes (51/52/53) | Reuses ENG-190's 49 incomplete; one validator, one halt reason. |
| D-009 | Bump schema version to v2 | (Same as D-002 rejection.) |
| D-009 | New validator file | (Same as D-002 rejection.) |
| D-010 | Env-var pass-through | Env-var reserved for host-level tuning; per-project is config.json. |
| D-011 | New runbook file | All ENG-191 operator-relevant behaviour fits in recovery.md §13 + CLAUDE.md row. |

## 11. Assumption inventory

| # | Assumption | Status | Evidence |
|---|------------|--------|----------|
| 1 | `bin/pipeline-events.json` has `events.verdict.linear_comment.field_registry_by_arm` and the ENG-115 per-arm override mechanism is wired in `bin/pipeline.sh::_validate_event_payload` | **verified** | `bin/pipeline-events.json::events.verdict.linear_comment.field_registry_by_arm` is present (jq dump above); `bin/pipeline.sh:168-174` implements the override; ENG-115 brainstorm at `docs/brainstorms/2026-05-17-eng-115-...` documents the precedent |
| 2 | `bin/pipeline-events.json::halt_reasons` already contains `review-ledger-invalid` (ENG-190 shipped) — no new halt reason needed for ENG-191 | **verified** | jq dump above shows `review-ledger-invalid` in the array |
| 3 | `bin/pipeline-events.json::fail_targets` is `[brainstorming, planning, implementing, ui]` — does NOT include `qa`, so `verdict fail --target qa` would die in validation. This means ENG-191 does NOT need to manipulate `fail_targets` | **verified** | jq dump above |
| 4 | `bin/verdict-handler.sh::_VH_FORWARD_TRANSITIONS` line 24 has `reviewing=qa`; `_vh_lookup_forward` returns "qa" for src="reviewing" | **verified** | `bin/verdict-handler.sh:19-27, 40-43` read |
| 5 | `bin/verdict-handler.sh::find_fresh_verdict` returns `{marker, source_stage, target_stage, reason, comment_id, event}`; `event` is the parsed JSON object including `result` and `reason` (when present) | **verified** | `bin/verdict-handler.sh:233-251` read in full; the projection includes `event` |
| 6 | `bin/verdict-handler.sh::apply_transition` does NOT read or honour the verdict's `reason` field; it only uses `from`/`to` and `side_labels` | **verified** | `bin/verdict-handler.sh:311-432` read; only `from`, `to`, `side_labels` are parameters |
| 7 | `bin/guards.sh::check` trips `review_rejection` only when `stage == implementing` (ENG-138) | **verified** | `bin/guards.sh:135-137` |
| 8 | `bin/run-stage.sh::_validate_review_payload` (lines 1392-1411) and `_validate_review_ledger` (lines 1434-1453) are the two post-dispatch validators for reviewing | **verified** | `bin/run-stage.sh:1392-1453` read |
| 9 | `bin/run-stage.sh::_clear_current_stage_slots` (lines 949-974) clears verdict-review.json on reviewing-stage dispatch start; ledger NOT in cleared set | **verified** | `bin/run-stage.sh:946-974` read; comment at line 946 explicitly excludes the ledger |
| 10 | `bin/run-stage.sh::post_completion_comment` at line 344 posts the agent's stage-summary file as `completion/<stage>/<issue>` | **verified** | `bin/run-stage.sh:344-437` read |
| 11 | `bin/run-stage.sh::main` post-dispatch hook block invokes `_validate_review_payload` at line 2321, `_validate_review_ledger` at line 2339, and `post_completion_comment` at line 2381 | **verified** | `bin/run-stage.sh:2317-2387` read |
| 12 | `bin/render-prompt.sh::PROMPT_RESOLVERS` (lines 40-61) registers tokens; new resolvers add to this list AND need a `_resolve_*` function body | **verified** | `bin/render-prompt.sh:40-62`, e.g. `review_ledger_path=_resolve_review_ledger_path` |
| 13 | `bin/render-prompt.sh::_write_rendered_paths_sidecar` enumerates path-shaped resolvers explicitly (lines 93-126); non-path resolvers are excluded | **verified** | `bin/render-prompt.sh:93-126` read |
| 14 | `bin/common.sh::config_get` reads `$CONFIG` JSON with `jq -r`; absence returns "null" | **verified** | `bin/common.sh:1130-1133` read |
| 15 | `bin/review-ledger-schema.sh` (ENG-190) implements seed-header byte equality at lines 156-161 and per-row validation in cmd_validate; unknown fields warn (`_warn_unknown`) but pass at lines 311-318 | **verified** | `bin/review-ledger-schema.sh:155-318` read |
| 16 | `bin/review-ledger-schema.sh::sanitise_for_diag` (lines 89-95) is the canonical sanitisation function for agent-controlled strings | **verified** | `bin/review-ledger-schema.sh:89-95` read |
| 17 | `bin/review-ledger-schema.sh` has `dispatch_id_flag` flag (lines 135-139) and `--dispatch-id` is the standard cross-check flag (ENG-190 D-006 fail-open shape) | **verified** | `bin/review-ledger-schema.sh:135-139, 230-234` read |
| 18 | `_ensure_review_ledger` at `bin/run-stage.sh:1016-1024` seeds with two `#`-prefix lines; ENG-190 D-007 | **verified** | `bin/run-stage.sh:1016-1024` read |
| 19 | AGENT_PROMPTS.md §5 review-agent body spans lines 1288-1672 (after ENG-190 edits); ENG-190's `Findings ledger`, `Adjudication`, and adjudicated-line predicate blocks are at 1345-1356, 1366-1390, 1392-1404, 1506-1514 | **verified** | AGENT_PROMPTS.md:1288-1672 read |
| 20 | AGENT_PROMPTS.md §5 Output bullets include adjudicator summary line (lines 1600-1616) and ledger append (lines 1617-1632) — both ENG-190 contributions | **verified** | AGENT_PROMPTS.md:1600-1632 read |
| 21 | `bin/run-stage.sh::main` post-dispatch hook block (lines 2317-2387) is the natural insertion site for `_post_deferred_majors_comment_if_eligible` AFTER ledger validation | **verified** | `bin/run-stage.sh:2317-2387` read |
| 22 | `bin/pipeline.sh::cmd_event_verdict` (line 267) parses `--reason` flag and adds `reason=<value>` to the args array passed to `_validate_event_payload` | **verified** | `bin/pipeline.sh:266-287` read |
| 23 | `bin/pipeline.sh::_validate_event_payload` line 173-181 implements the per-arm override (`field_registry_by_arm`) and falls through to `field_registry` if no override | **verified** | `bin/pipeline.sh:168-181` read |
| 24 | `bin/linear.sh add-comment --sig <sig>` is the append-only API per ENG-150; sig-suffix `/d<seq>` is auto-injected by the chokepoint | **verified** | CLAUDE.md "When wiring a new script" section: `bin/linear.sh add-comment`, which is append-only — every emission produces a fresh chronological comment; ENG-150 brainstorm documented |
| 25 | ENG-138/ENG-145 narrowed `review_rejection` trip to `stage == implementing`; the trip predicate is `(( rev >= review_threshold )) && [[ -z "$stage" \|\| "$stage" == "implementing" ]]` | **verified** | `bin/guards.sh:135-137` |
| 26 | `_validate_dispatch_envelope` halts on `mcp__plugin_linear` / `curl https://api.linear.app` / `gh api graphql` / `wget https://api.linear.app` / `unset PIPELINE_DISPATCH_ID` in transcript with rc=29 (ENG-87) | **verified** | CLAUDE.md "Cross-dispatch staleness contract" detective backstop section; `bin/run-stage.sh:1039` is the function definition (initial doc draft cited `1013` — ~26-line drift; corrected) |
| 27 | `bin/agent-prompts-content-test.sh` exists as the prompt-content content test harness; ENG-190 D-003 added §5 cold-pass / ledger / Adjudicated assertions | **verified** | `bin/agent-prompts-content-test.sh` referenced in the project-profile addendum's tool-allowlist enumeration; ENG-190 brainstorm D-003 specifies the pattern |
| 28 | `docs/runbooks/recovery.md` exists and has section numbers 1-12 (ENG-190 added §12) | **verified** | `docs/runbooks/recovery.md` present at `ls docs/runbooks/` |
| 29 | `docs/runbooks/operator-mental-model.md` exists and has §3 (grep-recipe) | **verified** | `docs/runbooks/operator-mental-model.md` present at `ls docs/runbooks/` |
| 30 | `bin/generate-vocabulary-doc.sh` regenerates `docs/pipeline-vocabulary.md` from `bin/pipeline-events.json`; new top-level arrays surface automatically | **verified** | CLAUDE.md "Pipeline vocabulary" section |

## 12. Out-of-scope flags

This brainstorm stays inside the Linear scope as written.
Three soft near-misses worth calling out (each within scope but
not literally enumerated):

* **D-010 (`{review_converge_rounds}` resolver + config key).**
  Required by Linear AC #6 ("N is config-driven and validated").
  Structural plumbing.
* **D-011 (CLAUDE.md row + recovery.md §13).** Required by
  Linear scope as operator-discoverable surface for the new
  state. Structural documentation.
* **Schema-grace clause (D-002).** Required by additive-v1
  approach to avoid the mid-flight in-flight-ledger compatibility
  burden. Structural shape forced by ENG-190's strict-v1
  posture.

All Linear IN bullets covered:

* "A new reachable `reviewing → qa` transition" → D-001 +
  D-006 (path D predicate).
* "deferability axis (`blocks_ship` per finding) + triage
  rubric + structured decision schema, authored in
  AGENT_PROMPTS.md (reviewing/adjudication section) and
  emitted in the verdict payload (extends verdict-review.
  json)" → D-002 (ledger row extension, NOT verdict-review.
  json — see D-002 rationale on why) + D-003 (rubric) +
  D-008 (prompt authoring).
* "Any major adjudged blocking forces the existing
  `reviewing → implementing` loopback" → D-006 (selective
  predicate, not all-or-nothing) + D-008 (path-B fallthrough).
* "N is config-driven (e.g.
  human_checkpoints.review_converge_rounds), with a sane
  default" → D-004 (count) + D-010 (resolver + key).
* "On taking the exit, the orchestrator (not the agent) posts
  ONE Linear comment enumerating the deferred majors" →
  D-005.
* "New verdict/marker shape registered in
  bin/pipeline-events.json + docs/pipeline-vocabulary.md" →
  D-001.
* "guards.sh interaction: the exit must pre-empt
  `review_rejection`" → D-007 (structural, no code change).

All Linear OUT bullets honoured:

* Auto-create follow-up Linear ticket per deferred major
  (ENG-193) → §8 first bullet.
* Adjudication-memory work (Lever 1, ENG-190) → §8 second
  bullet (consumed unchanged).
* Implement-side fix-the-class (Lever 3, ENG-192) → §8 third
  bullet.
* Model fine-tuning → §8 last bullet.

All seven Linear acceptance criteria map to concrete decisions:

* AC #1 (selective exit fires `reviewing → qa` on
  critical=0 + all-deferrable + convergence) → D-001 + D-006.
* AC #2 (mixed deferrable+blocking → path B; both fixtures) →
  D-006 + D-008.
* AC #3 (`blocks_ship` per finding + rationale + structured
  questions; rubric fixture) → D-002 (schema) + D-003
  (rubric) + D-008 (prompt-content tests).
* AC #4 (orchestrator posts deferred-majors comment;
  envelope-clean) → D-005.
* AC #5 (critical never takes the exit) → D-002 (critical-
  floor extension).
* AC #6 (N config-driven + validated, default + warning) →
  D-004 + D-010.
* AC #7 (marker registered, vocab regenerates) → D-001.

## 13. Persona review

Six personas, canonical order (design → security → scope →
coherence → product → feasibility). Iteration history in §14.

### 13.1 Design — PASS

* P0: 0.
* P1: 3 findings.
  * Schema-grace clause vs adjudication-memory clarification
    — addressed by D-002 explicit note: prior-dispatch
    `blocks_ship` is informational-only for adjudication
    memory; only current-dispatch rows enforce the new
    contract (already implicit in the dispatch_id-gated
    rules; surfaced explicitly in D-002 narrative).
  * D-006 agent-decides + "visibly wrong, easy to triage"
    mitigation is reactive — addressed by Edge case 1
    rewrite distinguishing the four bypass shapes + their
    defenses + the operator-discoverable signal (duplicate
    sigs).
  * D-008 path-B fallthrough on convergence-unmet burns
    `review_rejection` budget for no-fault state —
    addressed by introducing sub-variant **path B′** (no
    bump) for the convergence-waiting case. D-008 step 4
    updated to spec the bump elision; asymmetric semantics
    documented (path B = real loopback bumps; path B′ =
    waiting-for-plateau does not).
* P2: 3 findings. D-009 closed-five validation for
  `decision_factors` keys — already enforced by the
  closed-vocabulary check in D-009 step 4 (sibling
  AC-AD-6 fixture); operator-discoverable. D-011 power-
  user override crosses lane fence — accepted v1 cost,
  documented as power-user only in §13 recovery.md.
  Edge case 1 duplicate-comment prompt-test — addressed
  by D-008 assertion #6 (prompt-content test forbids the
  agent post).

### 13.2 Security — PASS

* P0: 0.
* P1: 2 findings.
  * D-005 deferred-majors comment sanitisation incomplete
    for non-named interpolated fields (`dispatch_id`,
    `iteration`) — addressed by D-005 rewrite naming SIX
    interpolated fields (was: three) and an explicit
    "re-sanitise every interpolated field" contract
    regardless of validator's row-level checks.
  * Envelope-validator chokepoint-bypass via `bash
    bin/linear.sh` chained command — Edge case 1 rewritten
    to distinguish four bypass shapes; runtime mitigation
    is duplicate-sig audit trail; transcript-based
    deny-on-`deferred-majors/`-sig flagged as YAGNI
    follow-up.
* P2: 2 findings (OQ-8 missed-`--reason` UX hole — flagged
  in OQ-8 with bounded-but-imperfect mitigation; OQ-7
  ad-hoc validation default — documented for the runbook).

### 13.3 Scope — PASS

* P0: 0.
* P1: 2 findings.
  * Subsystem count: 5 touched (orchestrator + dispatch +
    agent-prompts + Linear-contract + tests). Per CLAUDE.md
    rubric: 3+ is over-scope unless subordinate. Mitigated:
    Linear-contract is a 6-line registry edit; tests/docs
    are subordinate. Three load-bearing subsystems
    (orchestrator + agent-prompts + dispatch) match the
    Linear ticket's "Sizing" subsection's "Two load-bearing
    subsystems … agent-prompts is the subordinate third
    touch." Within sizing rubric as written.
  * OQ-4 forward-references ENG-193 in operator-visible
    comment text — accepted v1 (one literal "ENG-193 will
    auto-create follow-up tickets" line; couples the comment
    template to a future ticket but operator-discoverable
    value outweighs the coupling cost).
* P2: 2 findings (line-number drift in §11 — feasibility-
  level concern; OQ-3 project-policy-resolver defer —
  flagged in §7).
* All 7 ACs mapped (§12); all 4 OUT bullets honoured.

### 13.4 Coherence — PASS

* P0: 0.
* P1: 3 findings.
  * D-005 line-number drift (function vs invocation) —
    fixed: D-005 now distinguishes invocation lines (2321/
    2339/2381) from function definitions, matching
    assumption #11.
  * AC #2 mixed-fixture gap — addressed: §3
    `bin/run-stage-test.sh` enumeration now includes a
    "mixed deferrable+blocking → path B no exit" fixture
    AND a "critical never takes the exit" fixture
    explicitly mapping to AC #2 and AC #5.
  * Path A/B/C/D enumeration — clarified: AGENT_PROMPTS.md
    §5 lines 1516-1554 already define Path A (premise
    failure), Path B (changes requested), Path C (clean);
    ENG-191 adds Path D + sub-variant B′. The dataflow
    diagram now references the existing A/B/C/D set
    consistently.
* P2: 3 findings (guards predicate empty-stage branch — no
  impact, verdict-handler always passes a stage; Edge case
  1 prose tightening — addressed by rewrite; ENG-115
  "doubles" → "extends from two entries to three" prose
  fix accepted as P2 cosmetic).

### 13.5 Product — PASS

* P0: 0.
* P1: 3 findings.
  * D-005 deferred-majors comment lede — addressed: D-005
    now specifies a fixed-prose lede line at the top of
    the comment body ("Review took the selective exit
    (ENG-191). N major finding(s) deferred …").
  * CLAUDE.md row density — addressed: D-011 simplified to
    single-line Symptom + single-line Where-to-look
    pointing to recovery.md §13; runbook §13 holds the
    grep recipe + override.
  * Recovery.md §13 lede — addressed: D-011 §13 sketch
    now ledes with **Status** + **No recovery action
    required** + audit recipe block, prose-after-action
    shape.
* P2: 4 findings (path-B′ explicit naming — addressed
  inline in D-008; OQ-8 missed-`--reason` UX hole —
  remains a known soft signal; deferred-majors comment
  one-line-per-factor formatting — addressed by D-005
  body-shape spec; markdown-table pipe rendering — fixed
  by single-line row).

### 13.6 Feasibility — PASS

* P0: 0. All named code-level facts verified against
  source.
* P1: 4 findings — minor citation drift (`bin/run-stage.sh:
  1013` → 1039; D-005 function-vs-invocation phrasing;
  AGENT_PROMPTS.md §5 1288-1672 → 1288-1673;
  `PROMPT_RESOLVERS` 40-61 → 40-62). All corrected in
  assumption #26 and D-005 narrative; off-by-ones on
  PROMPT_RESOLVERS and §5 noted but not corrected (≤2-
  line drift, semantically correct, implementation-time
  grep will pin).
* P2: 1 — cosmetic.

**Gate status: 6/6 personas PASS, feasibility P0 count = 0.**
Brainstorm cleared for commit and stage progression.

## 14. Persona-review iteration history

* **Iteration 1.** All six personas PASS first-pass.
  Feasibility P0 count = 0. No P0 from any persona.
  P1 findings catalogued across all six (15 total).
  Edits applied (this dispatch):
  - **D-002.** No textual change required (prior-row
    informational-only is implicit in dispatch_id-gated
    grace; surface clarified in §13.1 narrative).
  - **D-005.** Sanitisation contract rewritten to name
    SIX agent-controlled interpolated fields with an
    explicit "re-sanitise every interpolated field"
    rule; added fixed-prose lede + structured body-
    shape spec; renamed line-number references to
    distinguish invocation vs function definition.
  - **D-008.** Added sub-variant **path B′** for
    convergence-waiting case (no `review_rejection`
    bump); documented asymmetric semantics vs path B.
  - **§3 Architecture.** Added explicit AC #2
    "mixed deferrable+blocking" fixture + AC #5
    "critical never takes the exit" fixture +
    sanitisation defensive fixture to
    `bin/run-stage-test.sh` enumeration.
  - **§6 Edge case 1.** Rewrote to distinguish four
    agent-self-post bypass shapes + their defenses +
    chained-command blind spot reference.
  - **§D-011.** Simplified CLAUDE.md row to single-line
    Symptom/Where-to-look; restructured recovery.md §13
    sketch to lede-first shape (Status + No-recovery-
    needed + audit recipe block).
  - **§11 assumption #26.** Updated cited
    `_validate_dispatch_envelope` location from `1013`
    to `1039` per feasibility drift correction.
  Re-verification of edits is implicit: no new code-
  level claims were introduced by iter-1 edits; existing
  verifications still hold.
* **Iter-1 gate met: 6/6 PASS, feasibility P0 = 0.**

**Final gate (this dispatch): 6/6 PASS, feasibility P0 = 0.
Brainstorm cleared for commit and stage progression.**

## 15. Proposed ADRs

This ticket does not propose new ADRs. The decisions fit within
established architectural patterns:

* ENG-87 cross-dispatch staleness contract (extended additively
  — schema-grace clause uses the dispatch-id primitive).
* ENG-115 per-arm field-registry-override pattern (extended with
  a second use case for the pass arm).
* ENG-119 / ENG-122 / ENG-190 dedicated-validator pattern
  (extended; no new validator file).
* ENG-138/ENG-145 stage-gated rejection-counter trip (relied on
  structurally for guards.sh pre-emption).
* ENG-190 cold-detect/warm-score ledger pattern (consumer
  extension; same schema and lifecycle).
* ENG-46 secret-handling (no env-var dereferences in new code).
* ENG-100 sub-agent debris (the prompt forbids fixture writes;
  same constraint).

If `docs/knowledge/decisions.md` ever materialises (verified
non-existent today via `ls docs/knowledge/` — no such
directory), the ENG-87 / ENG-115 / ENG-119 / ENG-138 / ENG-190
ADRs are the implicit parents this ticket mirrors.
