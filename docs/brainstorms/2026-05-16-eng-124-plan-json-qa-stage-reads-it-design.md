---
linear: ENG-124
title: plan.json — qa stage reads it
date: 2026-05-16
status: draft
---

# plan.json — qa stage reads it

## 1. Problem

ENG-30 is the umbrella decision to give the plan stage a machine-readable
artifact (`docs/plans/<plan-basename>.json`) alongside the prose markdown
plan, so downstream stages can verify pass-criteria against structured
fields instead of re-interpreting prose. The umbrella is split into a
plan-emits sub-ticket (ENG-122, the producer) and two reader sub-tickets
— one for implementing (ENG-123) and one for QA (THIS ticket, ENG-124).

The current QA stage prompt (`AGENT_PROMPTS.md:1180-1359`, §6 "QA Agent")
already treats the prose plan as authoritative — see the
"Authoritative test manifest" block at `AGENT_PROMPTS.md:1203-1207`:

> The plan's Failure Mode → Test Map is the contract. For every row, the
> named test MUST (a) exist on the branch, (b) execute, (c) assert the
> "Expected behavior" column …

That contract today is markdown table cells. The QA agent re-derives test
identifiers from prose and infers the "expected behavior" semantics each
dispatch. Concrete failure modes:

- **Test-name drift.** A markdown table cell `bin/foo-test.sh` is parsed
  by the agent as the canonical test path; if the plan author capitalised
  it differently or omitted the `bin/` prefix, the agent silently re-derives
  a different name and either runs the wrong test or files a missing-test
  P0 against a test that does exist under the canonical name.
- **Pass-criterion ambiguity.** Prose like "smoke command exits 0" leaves
  it to the agent to figure out *which* smoke command. A structured
  `pass_criteria[].kind=smoke` row with `command` + `expect_exit` is
  unambiguous and machine-runnable.
- **Verification predicate drift between sub-agent and main QA.** §5 of
  the QA prompt dispatches a sub-agent for adversarial coverage; the
  sub-agent and the main agent see *different prose interpretations* of
  the same plan, so the adversarial-coverage delta is muddied.

ENG-124's scope per the Linear ticket: make the QA agent **read the
structured `plan.json` when present, treat its `pass_criteria[]` as the
verification contract, and fall back to prose with an info log when
absent**. The JSON schema itself is owned by ENG-122 (plan-emits); this
ticket designs only the consumer-side wiring for §6 and the two test
paths (with-`plan.json` vs without). Threshold logic over the structured
criteria is ENG-31 territory and stays out.

## 2. Decisions

### D-001. Reuse the {plan_json} content-embedding resolver from ENG-123 — do NOT introduce a parallel `{plan_json_qa}`.

ENG-123 (parallel-safe sibling) registers a `{plan_json}` token and an
`_resolve_plan_json` content-embedding resolver in `bin/render-prompt.sh`.
It is named generically (not `{plan_json_implementing}`) for the explicit
reason called out in ENG-123 D-005:

> QA's plan.json reader, when its sibling ticket ships, will register
> its own consumer site — likely reusing the same `{plan_json}` resolver
> (tokens are global to AGENT_PROMPTS.md per
> `bin/render-prompt.sh:41-55`'s registry). ENG-123 should leave the
> resolver named such that QA can reuse it without renaming.

ENG-124 acts on that contract: the only AGENT_PROMPTS.md change is to
add a `{plan_json}` reference in §6, mirroring the §3 placement. No
new resolver is registered; no duplicate code path.

**Why reuse rather than parallel-token:**

- Tokens are GLOBAL to AGENT_PROMPTS.md per the registry at
  `bin/render-prompt.sh:41-55` and the per-stage extraction at
  `bin/render-prompt.sh:92-131`. Each stage's prompt block is rendered
  with the SAME resolver registry; whichever stage happens to embed
  `{plan_json}` triggers the resolver during ITS render.
- A parallel `{plan_json_qa}` would force two near-identical resolver
  bodies (sibling-search, embed-or-fallback) — duplication that drifts.
- The fallback-marker text `(no plan.json — falling back to prose plan)`
  is stage-neutral by construction; both implementing and qa agents
  recognise it the same way.

*Reference to constraint:* CLAUDE.md "Don't add features ... beyond
what the task requires." The parent ENG-30 spec (decision 11 in the
ticket body) lists "implement, ui, and qa read it" as a single concern;
mirroring the same resolver across stages matches that intent.

*Rejected alternative — register a parallel `{plan_json_qa}` token with
its own resolver body (`_resolve_plan_json_qa`):* duplicates the
sibling-search, the empty-marker emit, and the metric call. Drift cost:
when a future ticket changes the sibling-search heuristic (e.g., to
support a multi-plan history), two resolvers must change in lockstep.
Rejected.

*Rejected alternative — collapse the implementing and qa sites into one
shared "downstream-reader" prompt block extracted into a §0 fragment:*
out of scope and would couple §3 and §6 in a way the parent ENG-30
ticket does not request. Rejected on scope-budget grounds.

### D-002. Make `_resolve_plan_json`'s metric stage-aware via a new `_RENDER_STAGE` resolver-side global. Hardcoded `implementing` is the gap. (Acknowledged: this is a small ENG-123 follow-up absorbed into ENG-124 by design — see "Why absorb, not defer" below.)

ENG-123's resolver body emits a metric on miss as
(`bin/render-prompt.sh` post-ENG-123 at lines ~262-281 on the ENG-123
branch — verified at `feat/eng-123-plan-json-implement-stage-reads-it:bin/render-prompt.sh:266-279`):

```bash
bash "$SCRIPT_DIR/metrics.sh" plan_json_missing \
  "$_RENDER_ISSUE_ID" implementing fallback 0
```

The literal `implementing` is the third positional arg of `metrics.sh`
(`bin/metrics.sh:20` — `<event> <issue_id> <stage> <outcome> <duration_ms>`).
When QA renders the same resolver, the emitted JSONL row would mis-stamp
the stage as `implementing`, blinding the retrospective's plan.json
adoption-rate measurement (the §9 retrospective scans `events.jsonl` for
per-stage outcomes per `bin/metrics.sh:67`).

ENG-124 fixes this by binding a `_RENDER_STAGE` global in `main()` (next
to the existing `_RENDER_ISSUE_ID`/`_RENDER_DISPATCH_ID` siblings at
`bin/render-prompt.sh:404-421`) and updating `_resolve_plan_json` to
emit `"$_RENDER_STAGE"` instead of the literal `implementing`. The
binding mirrors the established pattern (no new mechanism). Retroactive:
the implement-reader keeps working unchanged because the `main()` stage
arg already holds `implementing` when §3 renders.

**Why a stage-aware metric, not stage-neutral:**

- The retrospective measures success-vs-fallback rates per stage
  (`AGENT_PROMPTS.md` §9 inputs). One row per stage per dispatch is the
  unit of analysis. A blanket `plan_json_missing` row that drops the
  stage field would conflate "implementer fell back" and "qa fell back"
  — different signals with different fixes (planning produced bad JSON
  vs planning didn't produce JSON at all).
- The `_RENDER_*` pattern is the established convention for binding
  rendering-time context to resolvers (see ENG-87 review-iter-7 M9 at
  `bin/render-prompt.sh:228-234` for the precedent — `_RENDER_DISPATCH_ID`
  was added for exactly this kind of cross-cutting metric stamp).
- Adding the global is one line in `main()` and a one-token swap in the
  resolver. No registry change.

**Empty `_RENDER_STAGE` contract (resolver hardening):** the resolver
MUST emit a non-empty stage value when it reaches the metric line.
Three reachable paths:

1. Normal `main()` render — `_RENDER_STAGE` bound from the `stage`
   arg, never empty (validated upstream by the `STAGE_TO_SECTION`
   lookup at `bin/render-prompt.sh:319` which dies on unknown stage).
2. Direct test invocation that binds `_RENDER_STAGE` explicitly — D-005
   cases R1, R2, R3 each bind it; the test-suite contract is "bind it."
3. Hypothetical future caller that invokes the resolver directly
   without binding — emits `stage="unknown"` (literal sentinel) so
   the retrospective sees a single distinguishable bucket instead of
   silent `stage=""` rows. Implemented as
   `local stage="${_RENDER_STAGE:-unknown}"` at the top of
   `_resolve_plan_json`. The sentinel exists to make accidental
   regressions observable, not to be a runtime fallback.

**Why absorb the ENG-123 follow-up, not defer (Scope persona M-1
response):** the literal `implementing` arg becomes operationally
wrong the moment §6 emits `{plan_json}` — there is no clean state in
which ENG-124 ships AC1+AC2+AC3 cleanly while leaving the metric
stamp wrong. Filing a separate "fix the stage stamp" sibling ticket
would (a) duplicate the ENG-124 dispatch + review cost, (b) ship a
known-broken metric on the day ENG-124 lands, (c) require ENG-124's
test cases to assert WRONG values to pass review. The 1-line
binding + 1-token swap + 1 regression-pin test is the minimum
correct surface. Absorption is honest scope, not creep.

**ENG-123 test-fixture coordination (Coherence persona Major #1
response):** ENG-123's R2 cases assert literal
`plan_json_missing <issue> implementing fallback 0`. After D-002
ships, R2 must bind `_RENDER_STAGE=implementing` BEFORE invoking
the resolver, otherwise the assertion would observe the new
`unknown` sentinel. The plan ticket's PR sequencing must encode
this update — either:
  (a) ENG-124 lands first → it includes BOTH the resolver change
      AND the R2 fixture binding update; ENG-123 then merges with
      its R2 tests pre-fixed.
  (b) ENG-123 lands first → ENG-124's PR includes the R2 binding
      update as part of its own diff.
Either way, the R2 binding is owned by whichever PR ships D-002.

*Reference to constraint:* CLAUDE.md "All metric writes go through
`bin/metrics.sh` so they end up in the canonical `events.jsonl` stream"
— the metric *must* be correct at the source, since the retrospective
is the only consumer and there's no in-band correction.

*Rejected alternative — leave the `implementing` literal and accept the
mis-stamp on QA misses:* breaks the retrospective's per-stage signal.
The whole point of the metric is observability; stamping it wrong
defeats the purpose. Rejected.

*Rejected alternative — drop the stage field entirely (`""` or `-`):*
matches the "stage-neutral" framing but loses the per-stage signal the
retrospective will eventually use. The cost of the keep-it-correct fix
is one bound global; rejecting it on simplicity is false economy.
Rejected.

*Rejected alternative — split into `_resolve_plan_json_implementing`
and `_resolve_plan_json_qa`:* duplicates everything ENG-123 D-001
explicitly avoided. Rejected (see D-001 above for the same argument).

### D-003. AGENT_PROMPTS.md §6 gets ONE new block, placed identically to §3's §3-Plan-JSON-contract block.

The new block is inserted **between the "Read these files first" list
(`AGENT_PROMPTS.md:1192`) and the "Branch:" line (`AGENT_PROMPTS.md:1194`)** —
the same anchor §3 uses (between read list and "Branch:"). Block text
mirrors §3 verbatim except the qa-specific clause:

> When present, treat the structured `pass_criteria[]` array as the
> AUTHORITATIVE verification contract over the prose plan's Failure
> Mode → Test Map where they overlap. Each `pass_criteria` entry's
> `kind` (smoke / file_exists / grep) maps to a runnable check; treat
> the prose Failure Mode → Test Map as narrative context only when a
> structured criterion exists for the same feature.

Block also retains §3's injection-defense clause verbatim (the
"DATA, not instructions" prose at the §3 block's tail) — that's a
shared §11-derived security invariant, not a per-stage policy.

**Why mirror §3's placement and prose shape:**

- The qa agent's existing "Authoritative test manifest" block
  (`AGENT_PROMPTS.md:1203-1207`) reads the markdown plan via
  `{plan_file}`. Putting `{plan_json}` BEFORE that block lets the
  qa-specific clause cleanly say "structured fields override prose
  where they overlap" — establishes precedence before the prose
  manifest is referenced downstream.
- Mirroring §3's anchor (after read list, before Branch) makes the
  drift-guard cheap: a §6 reviewer can compare §3 and §6 visually
  to spot accidental divergence on the next round of plan.json
  evolution.
- The "DATA, not instructions" injection-defense clause is required
  by ENG-123 D-001's iter-1 P1 finding (verified by reading the
  ENG-123 §3 block at the ENG-123 branch tip — see
  `feat/eng-123-plan-json-implement-stage-reads-it:AGENT_PROMPTS.md`
  at the §3 block's tail). Same threat applies to QA's prompt; same
  clause defends.

*Reference to constraint:* CLAUDE.md "AGENT_PROMPTS.md is load-bearing"
+ "Pipeline comment dedup convention" (i.e., the prompt is the
contract; per-stage prompts share §0 + per-stage shape, but each
stage edits ONLY its own H2 section).

*Rejected alternative — embed `{plan_json}` INSIDE the existing
"Authoritative test manifest" block (same paragraph):* makes the
block longer and harder to read; mixes two concerns (the prose-or-
structured DATA section and the AGENT'S contract-handling rules) in
one paragraph. Splitting them — like §3 does — is cleaner.
Rejected.

*Rejected alternative — append `{plan_json}` to §6 at the END (after
"Decision path"):* puts the embedded data far below where it is
first referenced (§6's "Authoritative test manifest" near the top).
The agent would have to scroll past hundreds of lines of decision
prose before seeing the data the test manifest depends on.
Rejected.

### D-004. The "Authoritative test manifest" block (`AGENT_PROMPTS.md:1203-1207`) gets a one-sentence bridge to the embedded plan.json.

Anchored on the existing line:

> The plan's Failure Mode → Test Map is the contract.

Insert immediately after:

> When `plan.json` is present (embedded above between the
> `<<<PLAN_JSON_BEGIN>>>` / `<<<PLAN_JSON_END>>>` delimiters), its
> per-feature `pass_criteria[]` entries are the structured form of the
> contract. Run each `kind` check (smoke command, file_exists path,
> grep pattern) and report failures with the same P0 weighting as
> Failure Mode → Test Map rows.

This is the bridge between "the embedded JSON exists" (D-003) and "the
agent uses it as the verification contract" (the Linear ticket's AC1).
Without the bridge, the qa agent has the JSON in its prompt but no
explicit instruction to act on it — the existing prose contract would
remain the only authoritative source by default.

**Why a bridge sentence, not a full rewrite of the manifest block:**

- The qa stage does back-fill PR handling, regression-intent audit,
  adversarial-coverage budget, and bug dedup — all built on top of the
  current manifest framing. A full rewrite is unbounded scope.
- A two-sentence bridge keeps `plan.json` strictly additive: when
  absent, the prose contract is unchanged; when present, the structured
  contract overrides at the field level, not the section level.
- Matches the Linear ticket's "treat per-feature criteria as the
  verification contract" — verbatim phrase carried into the prompt.

*Reference to constraint:* the Linear ticket's AC1: "qa dispatch reads
plan.json when present and uses its per-feature criteria as the
verification contract."

*Rejected alternative — replace the entire "Authoritative test manifest"
block when plan.json is present:* requires a runtime conditional in
the prompt the agent has to interpret correctly. Adds prompt-following
risk for no benefit; the bridge sentence achieves AC1 with less
surface. Rejected.

### D-005. Tests live in existing `bin/render-prompt-test.sh` and `bin/agent-prompts-content-test.sh`. No new test file.

- `bin/render-prompt-test.sh`:
  - **Case ENG-124-R1** (extends ENG-123-R1's fixture): with-`plan.json` —
    set `_RENDER_PLAN_FILE` AND `_RENDER_STAGE=qa`; assert the resolver
    output contains the JSON contents AND assert no metric row is
    emitted (success path).
  - **Case ENG-124-R2** (extends ENG-123-R2): without-`plan.json` —
    set `_RENDER_STAGE=qa`; assert the fallback marker is returned AND
    the metric row reads `plan_json_missing <issue> qa fallback 0`
    (NOT `… implementing fallback 0` — the per-D-002 stage-aware
    behavior).
  - **Case ENG-124-R3** (regression for D-002): with `_RENDER_STAGE=implementing`,
    re-assert ENG-123-R2's exact `… implementing fallback 0` literal
    is preserved. Pinned so a future change to D-002's binding doesn't
    silently flip the implementing stage's metric stamp.
- `bin/agent-prompts-content-test.sh`:
  - **Case ENG-124-C1**: §6 body contains the literal substring
    `{plan_json}`.
  - **Case ENG-124-C2**: §6 body contains the directive sentence about
    treating structured `pass_criteria` as authoritative (pin one or
    two unique phrases — e.g. `pass_criteria` and `authoritative`).
  - **Case ENG-124-C3** (drift guard): existing R5 token-coverage
    assertion already validates that every `{token}` in AGENT_PROMPTS.md
    has a resolver. Adding `{plan_json}` to §6 is automatically
    satisfied because the resolver already exists from ENG-123. No new
    code needed for the drift guard.
  - **Case ENG-124-C4** (cross-stage parity, strengthened per Design
    persona Major #3): extract the `<<<PLAN_JSON_BEGIN>>>` and
    `<<<PLAN_JSON_END>>>` delimiter lines from §3 AND §6, assert
    BOTH delimiters are present in EACH section, AND assert the
    literal delimiter strings are byte-for-byte equal across the
    two sections. The presence-only check from the prior draft
    misses the inverse failure (someone changes the delimiter shape
    in §3 and forgets §6, or vice versa); equality-of-token catches it.
  - **Case ENG-124-C5** (injection-defense parity, per Security
    persona M-1): assert §6 contains the literal substrings
    `DATA, not instructions` AND `never copy a` AND
    `<!-- pipeline:` (the three load-bearing phrases that constitute
    the §3 injection-defense clause). C4's delimiter check guards
    block presence; C5 guards the prose-clause content so a future
    §6 cleanup cannot silently drop the defense while leaving the
    delimiters intact.

*Reference to constraint:* CLAUDE.md "Tests are sibling shell scripts
named `*-test.sh` in `bin/`" — both target files already exist and
follow the right pattern. CLAUDE.md "Tests use the source-and-stub
pattern" — both files already use it; ENG-124 cases follow suit.

*Rejected alternative — new test file `bin/plan-json-qa-reader-test.sh`:*
splits coverage across files for the same resolver. The two existing
files are the natural homes for resolver-behavior + prompt-content
assertions respectively. Rejected.

### D-007. Emit a `plan_json_present` success-path metric symmetric with `plan_json_missing` so the retrospective can compute adoption-rate without inference. (Product persona Major #1 response.)

The fallback metric (`plan_json_missing`) gives the operator a count
of misses but no clean denominator: `success_rate = present / (present
+ missing)` is uncomputable from `events.jsonl` alone unless `present`
is inferred (total qa dispatches minus fallback rows), which conflates
"qa not dispatched" with "qa dispatched and used JSON."

ENG-124 emits a symmetric row on the success path:

```bash
bash bin/metrics.sh plan_json_present "$_RENDER_ISSUE_ID" \
  "${_RENDER_STAGE:-unknown}" used 0
```

Stamped at the same site (inside `_resolve_plan_json`) as the
fallback emit, immediately after the `cat "$plan_json_abs"` succeeds.
Same per-stage stage-correctness from D-002 applies.

**Why a separate event name (not one event with an `outcome` discriminator):**

- Matches the `bin/metrics.sh` convention of one event per discrete
  occurrence (per `bin/metrics.sh:67` — `event` is the primary key
  consumers group on; `outcome` is a per-event qualifier).
- Lets the retrospective's §1 filter classify on event name alone
  without parsing outcome strings.
- The `plan_json_missing` event name is already shipped by ENG-123;
  staying additive (new event, no rename) avoids breaking anything
  ENG-123 already emits.

**Test coverage:** D-005 R1 is updated to also assert ONE
`plan_json_present <issue> qa used 0` row in the stub metrics log
on the with-`plan.json` path. R3 is updated symmetrically for the
implementing-stage success row. R2 (miss path) keeps its existing
single-`plan_json_missing` assertion — D-007 does NOT fire on the
miss path.

*Reference to constraint:* the parent ENG-30 ticket explicitly cites
"the load-bearing discipline that prevents premature-victory
declarations" — measurable adoption is the operator-side equivalent.

*Rejected alternative — derive presence by subtraction (`total_qa_dispatches
- plan_json_missing_count`):* requires the retrospective to join two
event streams and conflates "qa not dispatched" with "qa dispatched
+ used JSON." Brittle.

*Rejected alternative — single event with `outcome ∈ {used, fallback}`:*
divergent from `plan_json_missing` (already shipped). Renaming would
break ENG-123's tests. Rejected on additive-change grounds.

### D-006. plan.json schema validity and per-criterion executor are OUT OF SCOPE for ENG-124.

Schema validation lives in `bin/plan-schema.sh` (per the ENG-122
plan-emits sibling — verified at `feat/eng-122-plan-json-plan-stage-emits-structured-contract-tests:bin/plan-schema.sh:1-80`).
The plan stage runs validation post-dispatch; if schema-incomplete or
malformed, the plan stage halts with structured exit codes 30/31/32 per
ENG-122's failure-outcome taxonomy. By the time the QA agent runs, any
plan.json on disk is schema-v1-valid by construction.

ENG-124 therefore:
- Does NOT call `plan-schema.sh validate` from the qa render path.
- Does NOT add a validator to the resolver.
- Does NOT teach the qa prompt the JSON's specific keys (the prompt
  references `pass_criteria[]` and `kind` because those are stable
  schema-v1 names from ENG-122; if schema evolves, ENG-124's prompt
  text gets a follow-up — explicit, not silent).

The per-criterion executor (running `kind=smoke` commands, asserting
`expect_exit`, etc.) is left to the QA agent's prompt-following.
The agent has the JSON in its prompt and existing `Bash(...)` allowlist
entries for the gate commands per the project profile's `## Tool
allowlist :: qa` section. Building a generic
`bash bin/plan-schema.sh run-criteria` executor (Option B in the
exploration) is gold-plating per the parent ENG-30 spec — qa can read
and act today; richer dispatch is a v2 once we observe how often the
prompt-following alone is insufficient.

**Why prompt-following over executor delegation:**

- Mirrors §3 (implement-reader) which also leaves the agent to act on
  the embedded JSON. Symmetry between sibling consumers reduces
  cognitive load.
- The qa allowlist already grants the bash patterns needed for the
  current `kind=smoke` shapes (`bash bin/<test>-test.sh:*` per the
  enumerated qa allowlist in the project profile). New smoke commands
  in plan.json that aren't in the allowlist will hit the documented
  permission-denial path and the agent's existing exit ramp
  (`bash bin/pipeline.sh event {issue_id} verdict halt --reason
  agent-blocked`) handles it — no new error pathway needed.
- Defers the executor question (which is its own scope-laden ticket)
  until we have empirical evidence of prompt-following insufficiency.

*Reference to constraint:* Linear ticket "OUT" scope row — "Threshold
logic over structured criteria (ENG-31 territory)". A generic executor
is one step removed from threshold logic; both belong to v2.

*Rejected alternative — implement `bash bin/plan-schema.sh run-criteria
<file> --output-jsonl` and have the qa agent invoke it:* requires:
(a) new subcommand on plan-schema.sh, (b) new allowlist entry
(`Bash(bash bin/plan-schema.sh:*)`) for qa, (c) per-`kind` runner code
(smoke / file_exists / grep), (d) result-aggregation and reporting.
Easily 200+ lines and a separate ticket's worth of design. Rejected.

## 3. Architecture

### Files added

(None.)

### Files modified

- **`AGENT_PROMPTS.md`** (§6 only):
  - Insert the Plan JSON contract block per D-003 between the read list
    and the Branch line (anchor: `AGENT_PROMPTS.md:1192-1194`).
  - Insert the bridge sentence per D-004 immediately after
    `AGENT_PROMPTS.md:1203` ("The plan's Failure Mode → Test Map is the
    contract.").
  - No other §6 lines change.
  - §§ 1, 2, 3, 4, 5, 7, 8, 9, 0 — UNCHANGED. (§3 already carries the
    parallel block from ENG-123.)

- **`bin/render-prompt.sh`**:
  - In `main()` (lines 314-424), bind a new `_RENDER_STAGE="$stage"`
    global immediately before the `resolve_block_tokens` call at
    `bin/render-prompt.sh:423`. Place it next to the existing
    `_RENDER_DISPATCH_ID="${PIPELINE_DISPATCH_ID-}"` binding for
    locality.
  - In the `_resolve_plan_json` body (existing on the ENG-123 branch
    at `feat/eng-123-plan-json-implement-stage-reads-it:bin/render-prompt.sh:262-281`),
    make three additive changes:
    1. Bind a local sentinel at the top of the function:
       `local stage="${_RENDER_STAGE:-unknown}"` (per D-002's
       empty-stage contract — the `unknown` sentinel is observable
       in `events.jsonl` rather than silently empty).
    2. Replace both occurrences of the literal third arg
       `implementing` in the `bash bin/metrics.sh plan_json_missing …`
       calls with `"$stage"`.
    3. After the `cat "$plan_json_abs"` line (success path), emit
       the D-007 success metric:
       `bash "$SCRIPT_DIR/metrics.sh" plan_json_present "$_RENDER_ISSUE_ID" "$stage" used 0`.
       Same site, same stage variable; one row per dispatch, mirrors
       the miss-path emit shape exactly.
  - No other resolver changes; the existing PROMPT_RESOLVERS registry
    (line 41-55, post-ENG-123 includes `plan_json=_resolve_plan_json`)
    is untouched.

- **`bin/render-prompt-test.sh`**: append three cases (ENG-124-R1,
  ENG-124-R2, ENG-124-R3) per D-005. Stub `bin/metrics.sh` via the
  existing `$sandbox/stubs123` pattern (or create a `stubs124` dir
  to keep failure messages distinguishable).

- **`bin/agent-prompts-content-test.sh`**: append four cases (C1-C4)
  per D-005. The `$s6` block-extraction follows the existing `$s3`
  pattern at `feat/eng-123-plan-json-implement-stage-reads-it:bin/agent-prompts-content-test.sh:1489+`.

### Files NOT modified (intentional)

- `bin/dispatch.sh::allowed_tools_for` — qa allowlist already covers
  the bash patterns per the project profile's `## Tool allowlist :: qa`
  enumeration. The agent reads JSON from prompt text, not via Read.
- `bin/run-stage.sh` — render-prompt.sh remains the single entrypoint
  for prompt assembly; no orchestrator-side glue.
- `bin/scope-check.sh` — `docs/plans/*.json` is in-scope for the
  planning stage's writes (per the project profile's File layout); qa
  only reads it via the embed-into-prompt path, no scope rule needed.
- `bin/reconcile.sh` — uses YAML frontmatter `linear: ENG-N` to bind
  docs to issues. plan.json has no frontmatter (it's JSON), so reconcile
  ignores it; the markdown sibling remains the canonical doc per the
  existing rule at `bin/reconcile.sh:67-89`.
- `bin/plan-schema.sh` — owned by ENG-122; ENG-124 does not call it.
- `bin/render-prompt.sh::AGENT_RUNTIME_TOKENS` (line 75) — `{plan_json}`
  is a render-time token (resolved at render), not an agent-runtime
  token. ENG-123's registration already handles it.
- §§ 1-5 and §7-9 of `AGENT_PROMPTS.md`. §3 (implement-reader) is owned
  by ENG-123; ENG-124 must not double-edit it.

## 4. Data flow

```
plan stage (out-of-scope: ENG-122 plan-emits sibling)
  └── git commits docs/plans/<plan-basename>.md AND
      docs/plans/<plan-basename>.json on per-issue worktree branch.
      Schema-v1 valid by construction (ENG-122's run-stage hook
      rejects malformed/incomplete plan.json post-dispatch).

qa stage dispatch:
  bin/run-stage.sh → bin/render-prompt.sh qa <issue_id>
    │
    ├─ main() resolves stage='qa', issue_id, ...
    ├─ binds _RENDER_STAGE="qa" (NEW per D-002)
    ├─ binds _RENDER_PLAN_FILE="docs/plans/<plan-basename>.md"
    ├─ extract_block "6. QA Agent" → §6 prompt body
    ├─ resolve_block_tokens($block):
    │    └─ encounters {plan_json} → calls _resolve_plan_json
    │       ├─ stage="${_RENDER_STAGE:-unknown}"        (D-002 sentinel)
    │       ├─ derives plan_json_rel = docs/plans/<plan-basename>.json
    │       ├─ if -s "$TARGET_REPO/$plan_json_rel":
    │       │    cat "$plan_json_abs"  → embedded verbatim into prompt
    │       │    metrics.sh plan_json_present <issue> qa used 0   (D-007)
    │       └─ else:
    │            metrics.sh plan_json_missing <issue> qa fallback 0
    │            log to stderr (visible in per-stage transcript)
    │            print "(no plan.json — falling back to prose plan)"
    └─ append_project_profile "qa" → final prompt to claude -p stdin

dispatched qa agent:
  reads its prompt; sees the embedded plan.json contents;
  walks pass_criteria[] per the bridge sentence (D-004);
  for each kind:
    ├─ smoke: invoke command via existing Bash(...) allowlist; assert exit
    ├─ file_exists: Read tool to confirm path on branch
    └─ grep: Grep tool with provided pattern
  on failure: existing decision-path B (genuine failure → loop back)
  on missing-criterion-coverage: existing P0 framework
  on fallback marker visible: prose-only path, current behavior
```

## 5. Error handling

| Condition | Detection | Action |
|---|---|---|
| plan.json absent | resolver: `[[ -s "$plan_json_abs" ]]` false | emit fallback marker; log to stderr; metric `plan_json_missing <issue> qa fallback 0`; agent reads marker → falls back to prose |
| plan.json zero-byte | same `[[ -s ... ]]` predicate (covers absent + zero-byte) | same as above |
| `_RENDER_PLAN_FILE` empty (no markdown plan resolved either) | early-return guard at top of `_resolve_plan_json` (per ENG-123 body) | same as above |
| plan.json present but malformed | OUT OF SCOPE — ENG-122's plan stage halts before qa is reached. If somehow malformed JSON reaches qa (operator hand-edit, version skew), the agent treats the embedded text as opaque data per D-006. Worst case: agent reports "plan.json present but I cannot parse pass_criteria" via P0; operator triages. No new resolver-side validation. |
| smoke command in `pass_criteria[]` not in qa allowlist | agent invokes; sandbox returns permission denial. Agent's existing exit ramp: `bash bin/pipeline.sh event {issue_id} verdict halt --reason agent-blocked` per §0. |
| `kind=grep` regex pathological / matches nothing on a working branch | agent reports as P0 per the existing manifest contract; bug-dedup applies. No new pathway. |
| Render-time stage binding `_RENDER_STAGE` empty (e.g., direct test calls into resolver without binding it) | Resolver binds `local stage="${_RENDER_STAGE:-unknown}"` per D-002's empty-stage contract. Metric row stamps `stage="unknown"` (literal sentinel, not empty) so the retrospective's `events.jsonl` scan sees a single distinguishable bucket. Tests R1/R2/R3 each explicitly bind `_RENDER_STAGE` per their case stage; the `unknown` sentinel never fires on the normal render path (`main()` binds from a validated `STAGE_TO_SECTION` arg). |
| `_RENDER_STAGE` bound but plan.json present on the success path | Resolver emits ONE `plan_json_present <issue> <stage> used 0` row per D-007 immediately after embedding the JSON. Lets the retrospective compute `success_rate = present / (present + missing)` without inference. |

## 6. Edge cases

- **Mixed-scope plan.json on a back-fill PR.** §6 already has a
  back-fill detection block (`AGENT_PROMPTS.md:1197-1201` and the
  Decision path D at `AGENT_PROMPTS.md:1317-1328`). When the PR is
  back-fill (docs-only diff), §6 D-path skips the coverage / regression
  audits; the plan.json's `pass_criteria` are likewise vacuously
  satisfied (zero new code paths). The new D-003 bridge sentence
  applies only to the non-back-fill path; the agent reads "this is a
  back-fill PR" first and follows the D-path before reaching the
  manifest contract section. No conflict, but the brainstorm's
  AGENT_PROMPTS edit MUST NOT change the back-fill detection or D-path.
- **Multiple plan markdown files for the same issue (loopback /
  supersede).** `_resolve_plan_file` resolves to ONE plan.md; the
  resolver derives the JSON sibling from that md basename. If a
  superseded plan.md still has a sibling .json on disk, it's invisible
  unless `_resolve_plan_file` resolves to that older basename. This is
  the same hazard ENG-123 D-002 documented for implementing; ENG-124
  inherits it. Mitigation: plan stage's `pipeline:supersede` handling
  in reconcile.sh ensures `_resolve_plan_file` returns the canonical
  newer plan.md.
- **plan.json present but features list is empty (`features: []`).**
  ENG-122 schema requires `features[].len >= 1` at validation time, so
  this should never occur in practice. If it does (operator hand-edit
  bypass), the qa agent reads valid JSON with no criteria and falls
  through to the prose contract — the bridge sentence (D-004) only
  prescribes acting on per-feature criteria when present. Edge case
  is observable but non-breaking.
- **`<<<PLAN_JSON_BEGIN>>>` / `<<<PLAN_JSON_END>>>` delimiters appear
  inside the embedded JSON (e.g., a quoted string).** Bash literal
  substitution at `bin/render-prompt.sh:296` does NOT escape delimiters;
  if a future plan.json contains the literal string `<<<PLAN_JSON_END>>>`
  inside a `summary` field, the agent's parser would see the delimiter
  twice. Probability is negligible for human-authored plan.json and
  ENG-122's schema doesn't restrict string contents. Not worth a fix
  in this ticket; flag in §7 OQ-1.
- **The qa stage runs parallel to itself across issues (per ENG-81
  K-tuning).** Each render is per-dispatch in its own subshell;
  `_RENDER_STAGE` is a local-to-process global, so no cross-dispatch
  contamination. Verified by reading the dispatch flow at
  `bin/run-stage.sh` (the dispatch fork point) — each `claude -p`
  call is in its own subshell.
- **ENG-123 has not landed when ENG-124 implements (cross-PR
  sequencing — Coherence persona Major #1 + Design persona Major #2
  response).** The Linear ticket says "Parallel-safe with the
  implement-reader sub-ticket." Two concrete PR shapes follow,
  picked at plan-time based on `git merge-base` state:
  - **Shape A — ENG-124 lands first:** absorb the `{plan_json}`
    registry entry AND `_resolve_plan_json` body from the ENG-123
    branch into ENG-124's PR. Ship D-002 (stage-aware metric) AND
    D-007 (success-path metric) AS PART OF the resolver's first
    landing — i.e., the resolver lands stage-correct from day one,
    no hardcoded `implementing` ever ships to main. ENG-123's PR
    then reduces to the §3 prompt edit + §3 content tests; its R2
    test fixture binds `_RENDER_STAGE=implementing` from the start.
  - **Shape B — ENG-123 lands first:** the resolver merges with the
    hardcoded `implementing` literal. ENG-124's PR includes the
    one-line stage binding in `main()`, the resolver's literal-to-
    `_RENDER_STAGE` swap, the D-007 success-emit insertion, AND the
    update to ENG-123's existing R2 test fixture to bind
    `_RENDER_STAGE=implementing`. The R2 binding is part of ENG-124's
    diff under this shape.
  Regardless of shape, no version of the resolver with hardcoded
  `implementing` is on main while §6 emits `{plan_json}`. The plan
  ticket selects the shape with one `git merge-base` check.

## 7. Open questions

1. **OQ-1 — Delimiter collision (edge case 4 above; Security persona
   M-3 escalation):** is it worth a defensive
   `printf '%s' "$content" | sed 's/<<<PLAN_JSON_END>>>/<<<PLAN_JSON_END_ESC>>>/g'`
   in the resolver? Cost: ~1 line. Benefit: closes the only realistic
   prompt-injection vector (a worktree-co-located malicious plan agent,
   or operator hand-edit, embedding the literal end-delimiter string
   inside a JSON `summary` field — would let the embedded data section
   end early and inject prompt-level text). §3 (implement-reader) has
   the same exposure but is ENG-123's problem; ENG-124 can ship the
   fix symmetrically since both stages share the same resolver
   (D-001). Security persona recommends shipping with this PR rather
   than deferring. Recommendation for the planning stage: ship the
   sed-escape in ENG-124's resolver edit, add a R4 test case asserting
   the escape fires on a fixture with the delimiter literal embedded.
   Cost is bounded and the failure mode is silent (agent sees JSON
   truncated mid-string, no metric or log). Owner: planning agent —
   decide in-scope or out-of-scope; if in-scope, the brainstorm's
   Architecture and D-005 sections gain one bullet each.
2. **OQ-2 — Should D-002's `_RENDER_STAGE` be exported as part of
   AGENT_RUNTIME_TOKENS or just a resolver-side global?** Currently
   the existing globals are resolver-side only. Exporting would let
   future tokens like `{stage}` interpolate into prompts directly.
   Out of scope for ENG-124 (no current consumer); flag for ENG-NN
   (future "stage-aware prompt templating" ticket if ever filed).
3. **OQ-3 — Does the §6 bridge sentence (D-004) need to teach the
   agent the per-`kind` runner shapes?** Today the qa prompt assumes
   the agent figures out "smoke = invoke and check exit" etc. from
   context. If empirical telemetry shows the agent skips structured
   criteria silently, the bridge could be expanded to enumerate
   each `kind`'s expected handling. Defer until the retrospective
   shows the gap.
4. **OQ-4 — Sub-agent (§5 adversarial-coverage dispatch) and
   plan.json:** the §5 sub-agent receives "the feature description,
   the api-contract block, and the list of new code paths" — should
   it ALSO receive the plan.json's `pass_criteria[]` to anchor its
   adversarial questions? Probably yes for richness, but expanding
   the sub-agent's input is its own scope decision. Out of scope for
   ENG-124; flag for a follow-up `qa-adversarial-plan-json-input`
   ticket. Owner: planning agent's brainstorm follow-up.
5. **OQ-5 — Should `_RENDER_STAGE` be resolved through a registry
   resolver function (`_resolve_render_stage`) rather than a raw
   global?** The existing `_RENDER_*` globals are accessed directly
   by their resolvers (e.g., `_resolve_issue_id` reads
   `_RENDER_ISSUE_ID`). ENG-124 follows the same pattern. If a future
   refactor wants pure-function resolvers, that's a §0 token-system
   evolution, not ENG-124's concern. Flag for the planning stage to
   confirm.
6. **OQ-6 — AC1 in-band agent-consulted-criteria signal (Product
   persona Major #2):** today the only mechanism that the qa agent
   actually consulted `pass_criteria[]` (vs. silently reverting to
   prose interpretation) is the D-004 bridge sentence + prompt-
   following. If the agent ignores the structured contract, the
   D-007 `plan_json_present` metric still fires (JSON was present),
   and nothing surfaces the regression. Candidate fixes for a v2
   ticket:
     (a) require the qa agent's verdict comment to enumerate
         `pass_criteria[].id` it actually ran (transcript-asserted),
     (b) extend the QA evidence comment shape to carry a structured
         per-criterion outcome table.
   Both require AGENT_PROMPTS.md §6 expansion beyond ENG-124's scope
   and depend on observed empirical adherence after ship. Defer to
   a follow-up "qa-agent-cites-pass-criteria-ids" ticket. Owner:
   planning agent decides whether to file the follow-up now or
   wait for retrospective signal.

## 8. Assumption inventory

Every named file, function, and `path:line` reference verified against
the current worktree state OR the ENG-123 branch tip (where ENG-123's
work sits today, awaiting merge).

| # | Assumption | Status | Verified at |
|---|---|---|---|
| A1 | `AGENT_PROMPTS.md` has §6 "QA Agent" between lines 1180 and 1359 | verified | `AGENT_PROMPTS.md:1180` and `AGENT_PROMPTS.md:1361` (next H2 `## 7.`) |
| A2 | §6's "Read these files first" list ends at line 1192; "Branch:" is at line 1194 | verified | `AGENT_PROMPTS.md:1186-1194` |
| A3 | §6's "Authoritative test manifest" block starts at line 1203, anchor sentence at 1204 | verified | `AGENT_PROMPTS.md:1203-1207` |
| A4 | `bin/render-prompt.sh::PROMPT_RESOLVERS` is a heredoc-ish string at lines 41-55 | verified | `bin/render-prompt.sh:41-55` |
| A5 | `bin/render-prompt.sh::main()` binds `_RENDER_*` globals at lines 404-421 before calling `resolve_block_tokens` | verified | `bin/render-prompt.sh:404-423` |
| A6 | The existing `_RENDER_DISPATCH_ID` global is bound from `${PIPELINE_DISPATCH_ID-}` at line 421 | verified | `bin/render-prompt.sh:421` |
| A7 | `bin/render-prompt.sh::resolve_block_tokens` does literal `${var//pat/repl}` substitution at line 296 | verified | `bin/render-prompt.sh:296` |
| A8 | `bin/render-prompt.sh::append_project_profile` is the per-stage-prompt addendum hook called from line 423 | verified | `bin/render-prompt.sh:185-211` and `bin/render-prompt.sh:423` |
| A9 | `bin/metrics.sh` signature is `<event> <issue_id> <stage> <outcome> <duration_ms>` (third arg is stage) | verified | `bin/metrics.sh:20-21` |
| A10 | `bin/metrics.sh::main` writes to `$PROJECT_STATE_DIR/metrics/events.jsonl` at line 43 | verified | `bin/metrics.sh:43` |
| A11 | ENG-122's `bin/plan-schema.sh` exists with `validate <file>` and exit codes 30/31/32 | verified | `feat/eng-122-plan-json-plan-stage-emits-structured-contract-tests:bin/plan-schema.sh:1-44` |
| A12 | ENG-122's plan.json shape is `{plan_schema_version: 1, issue_id, features:[{id, summary, pass_criteria:[{kind, ...}]}]}` with `kind ∈ {smoke, file_exists, grep}` | verified | `feat/eng-122-plan-json-plan-stage-emits-structured-contract-tests:bin/plan-schema.sh:13-34` and example file `…/docs/plans/2026-05-15-eng-122-plan-json-plan-stage-emits-structured-contract-tests.json` |
| A13 | ENG-123's `_resolve_plan_json` is at lines 262-281 of render-prompt.sh on the ENG-123 branch and emits literal `implementing` as the metric stage | verified | `feat/eng-123-plan-json-implement-stage-reads-it:bin/render-prompt.sh:262-281` |
| A14 | ENG-123 registers `plan_json=_resolve_plan_json` in PROMPT_RESOLVERS at line 55 of the ENG-123 branch | verified | `feat/eng-123-plan-json-implement-stage-reads-it:bin/render-prompt.sh:55` |
| A15 | ENG-123 inserts the §3 Plan JSON contract block between the read list and "Branch:" of §3 | verified | `feat/eng-123-plan-json-implement-stage-reads-it:AGENT_PROMPTS.md` (around line 622-647) |
| A16 | ENG-123 tests are appended to `bin/render-prompt-test.sh` (R1, R2 cases) and `bin/agent-prompts-content-test.sh` (C1, C2 cases) | verified | `feat/eng-123-plan-json-implement-stage-reads-it:bin/render-prompt-test.sh:383+` and `…:bin/agent-prompts-content-test.sh:1489+` |
| A17 | `bin/render-prompt-test.sh` uses `run_resolver_body` helper for resolver-isolated test runs | verified | usage at `feat/eng-123-plan-json-implement-stage-reads-it:bin/render-prompt-test.sh:391`; canonical form pre-existed in `bin/render-prompt-test.sh` (helper used by multiple resolver test cases) |
| A18 | `bin/reconcile.sh` matches `linear: <ID>` YAML frontmatter and ignores files without frontmatter | verified | `bin/reconcile.sh:67-89` |
| A19 | `find_doc` in render-prompt.sh searches `$TARGET_REPO/docs/plans/` for the plan markdown | verified | `bin/render-prompt.sh:380` |
| A20 | qa stage tool allowlist enumerates `bash bin/<test>-test.sh:*` per the project profile's `## Tool allowlist :: qa` section | verified | project profile addendum (this prompt's bottom) `## Tool allowlist :: qa` enumeration |
| A21 | The `${VAR-}` (single-dash) form is the `set -u`-safe presence check per ENG-46 secret-handling rule | verified | `bin/linear.sh:62` (`${PIPELINE_DISPATCH_ID-}` example) |
| A22 | The merge-base of `feat/eng-124-plan-json-qa-stage-reads-it` and `main` is `c8483e8` (predates both ENG-122 and ENG-123 branches) | verified | `git merge-base main HEAD` output during exploration |

No "assumed" rows — every codebase-fact is verified against current
files (worktree, ENG-122 branch, or ENG-123 branch).

## 9. ADR stress test

ENG-124 puts no measurable pressure on existing ADRs.

- **Cross-dispatch staleness contract (ENG-87 / CLAUDE.md §
  "Cross-dispatch staleness contract"):** unaffected — `_RENDER_STAGE`
  is bound per-dispatch in the orchestrator's render step, not
  carried across dispatches. No `dispatch_id`-equality contract is
  touched.
- **AGENT_PROMPTS.md schema invariant (`render-prompt.sh::extract_block`
  fence-count check at `bin/render-prompt.sh:99-114`):** the new §6
  Plan JSON contract block uses indented `<<<PLAN_JSON_BEGIN>>>` /
  `<<<PLAN_JSON_END>>>` delimiters (NOT column-0 ``` fences), so the
  fence-count of §6 stays at 2. Verified against §3's existing block
  on the ENG-123 branch (which uses the same indented delimiter
  shape and passes fence-count assertions).
- **Don'ts list (CLAUDE.md "Don'ts"):** ENG-124 modifies §6 only; does
  NOT renumber `STAGE_TO_SECTION`, does NOT add column-0 ``` fences
  inside the §6 body, does NOT use exit codes outside the existing
  taxonomy (no new exit codes at all).
- **Tool allowlist boundary (CLAUDE.md "Per-target dispatch.tools
  extras"):** unchanged — qa allowlist is static; no new patterns
  granted. Smoke commands in plan.json that aren't enumerated will
  hit the documented permission-denial path.
- **Slot-occupancy contract (ENG-90 / CLAUDE.md "Slot-occupancy
  contract"):** unaffected; ENG-124 changes prompt content, not
  poller/scheduler decisions.

ENG-124 is intentionally a small ticket (1-2 subsystems by the
ticket-sizing rubric — `dispatch` + `agent prompts`) with one main
design decision (D-002's stage-aware metric) that's a natural ENG-123
follow-up. No ADRs need new status.

## 10. Persona review

Six personas were dispatched as cold sub-agents (general-purpose) with
read-only access, in the prescribed order: design → security → scope →
coherence → product → feasibility. Each received the brainstorm path
and a persona-specific brief; each returned a structured verdict.
Findings are summarised verbatim where possible; load-bearing Major
findings have been folded back into the design (cross-referenced in
each persona's "Action taken" line below). The gate (≥5/6 PASS AND
feasibility 0 P0) is the orchestrator's advance criterion.

### 10.1 Design persona — verdict: PASS (0 P0, 3 Major)

- **Major #1 — D-002 `_RENDER_STAGE` empty fallback semantics
  under-specified.** Trades a clear failure for silent metric
  corruption. Recommended either `die` or an explicit sentinel.
  *Action taken:* D-002 amended with the empty-stage contract
  (`local stage="${_RENDER_STAGE:-unknown}"` — observable bucket,
  not silent empty). Error-handling table row updated.
- **Major #2 — Edge case 6 sequencing identified but unresolved.**
  Doc should pre-commit to a PR shape, not hand to the planner.
  *Action taken:* Edge case 6 amended to enumerate Shapes A and B
  with explicit fixture-coordination rules; plan ticket selects with
  one `git merge-base` check.
- **Major #3 — D-005 C4 cross-stage parity test has weak failure
  semantics.** Catches §6-deletion but not delimiter-shape change in
  §3-without-§6 update.
  *Action taken:* C4 amended to assert byte-for-byte equality of
  delimiter tokens across §3 and §6, not just presence.
- **Strengths:** D-002 R3 regression-pin for the implementing-stage
  metric stamp; full file:line traceability in the data flow.

### 10.2 Security persona — verdict: PASS (0 P0, 0 Major; 3 Minor)

- **M-1 — pin §6's injection-defense prose with a content test.**
  *Action taken:* D-005 case C5 added — asserts §6 contains
  `DATA, not instructions`, `never copy a`, and `<!-- pipeline:`
  substrings (the three load-bearing phrases of the §3 injection
  defense).
- **M-2 — `_RENDER_STAGE` value-domain hardening via stage-regex
  guard in `main()`.** Acknowledged as planner-discretion; current
  upstream validation (`STAGE_TO_SECTION` lookup at
  `bin/render-prompt.sh:319` dies on unknown stage) already
  constrains the domain. Not folded — `main()` already validates.
- **M-3 — OQ-1 (delimiter collision) is the realistic injection
  vector; recommend escalating to in-PR fix.** Flagged for planner.
  *Action taken:* OQ-1 amended with security framing and explicit
  recommendation to ship the sed-escape in ENG-124's resolver edit;
  decision deferred to planning per the ticket-sizing convention.
- **Strengths:** §3 injection-defense clause preserved verbatim; no
  new Linear-write surface; D-006 declines to introduce new
  validators; A21 verifies `${VAR-}` `set -u`-safe form used
  throughout.

### 10.3 Scope persona — verdict: PASS (0 P0, 1 Major)

- **Major #1 — D-002 is borderline scope creep dressed as a bug
  fix.** Recommend either filing as sibling micro-ticket OR
  acknowledging absorption explicitly.
  *Action taken:* D-002 amended with explicit "Why absorb, not defer"
  framing — the literal `implementing` becomes operationally wrong
  the moment §6 emits `{plan_json}`; absorbing is honest scope, not
  creep.
- **Minors:** Subsystems count honest (2 — dispatch + agent prompts).
  ENG-123 sequencing properly flagged. OQs correctly deferred.
- **Strengths:** D-001's reuse-not-duplicate framing; D-006's explicit
  out-of-scope inventory; assumption inventory has zero "assumed"
  rows.

### 10.4 Coherence persona — verdict: PASS (0 P0, 2 Major)

- **Major #1 — D-002 modifies a function ENG-123 owns; ENG-123's R2
  test fixture will need an update.** Brainstorm acknowledges
  sibling-coordination in Edge case 6 but doesn't call out the
  specific test-fixture modification.
  *Action taken:* D-002's "ENG-123 test-fixture coordination" block
  added — explicitly enumerates Shape A and Shape B ownership of the
  R2 binding update.
- **Major #2 — OQ-2/OQ-5 hint at unresolved naming convention for
  `_RENDER_STAGE`.** Not a P0 since the choice mirrors precedent.
  *Action taken:* No fold-back; explicit deferral acknowledged.
- **Minors:** A15's ENG-123 §3 line range is vague (`622-647`) vs.
  ENG-124's tighter anchor — acceptable since ENG-123 is sibling
  branch and §3 block size differs.
- **Strengths:** D-001/D-002 don't contradict (additive
  modification); fallback marker text + delimiter shape + metric
  event name + token name + resolver name all match ENG-123 verbatim.

### 10.5 Product persona — verdict: PASS (0 P0, 2 Major)

- **Major #1 — Observability of fallback rate is partial without a
  symmetric `plan_json_present` metric on the success path.**
  Adoption-rate denominator is otherwise uncomputable from
  `events.jsonl` alone.
  *Action taken:* D-007 added — emits one `plan_json_present <issue>
  <stage> used 0` row per dispatch on the success path. R1/R3
  amended to assert it.
- **Major #2 — AC1 has no in-band signal that the agent actually
  consulted `pass_criteria[]` (vs. silently reverting to prose).**
  Considered: agent self-reports `pass_criteria_consulted: <count>`.
  *Action taken:* Added as OQ-6 deferred to a v2 follow-up ticket
  (`qa-agent-cites-pass-criteria-ids`); requires AGENT_PROMPTS.md §6
  expansion beyond ENG-124's scope.
- **Minors:** AC2 "info log" is stderr/transcript-only (no Linear
  surface); rollback story is implicitly clean but undocumented.
- **Strengths:** D-006's explicit out-of-scope inventory; assumption
  inventory; D-007 closes the operator's adoption-rate KPI gap.

### 10.6 Feasibility persona — verdict: PASS (0 P0, 0 Major; 8 Minor — all verifications)

- All 22 codebase-facts in §8's Assumption inventory verify against
  the actual files. Every cited `path:line` is accurate or within
  1-2 lines (rounding for awk-block boundaries).
- The proposed `_RENDER_STAGE` binding is the single-line addition
  claimed (mirrors `_RENDER_DISPATCH_ID=…` at
  `bin/render-prompt.sh:421`).
- Metric positional shape `<event> <issue_id> <stage> <outcome>
  <duration_ms>` matches `bin/metrics.sh:20`.
- `_resolve_plan_json` exists on ENG-123 branch with literal
  `implementing` at lines 267 and 278 (brainstorm A13's "262-281"
  range — exact).
- §6's "Authoritative test manifest" begins at
  `AGENT_PROMPTS.md:1203` (A3 — exact).
- D-006's claim that ENG-122 plan stage halts on malformed JSON via
  exit codes 30/31/32 verified at
  `feat/eng-122-plan-json-plan-stage-emits-structured-contract-tests:bin/plan-schema.sh:7-12`.
- ENG-123-C2's "DATA, not instructions" assertion exists in §3 of
  ENG-123 branch (verified). D-003's promise to mirror it verbatim
  into §6 is achievable (now pinned by C5 per Security M-1).
- §9 ADR stress-test correctly notes the §6 block uses INDENTED
  delimiters (not column-0 fences), preserving the
  `extract_block` fence-count==2 invariant — verified against
  ENG-123's §3 block at `bin/render-prompt.sh:99-114`.
- *Action taken:* No fold-back required — feasibility passes clean.

**Persona gate result: 6/6 PASS, 0 P0 in feasibility — proceed to
planning.**
