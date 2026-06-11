---
linear: ENG-115
title: Pivot marker — verdict shape and parsing (parent ENG-35 sub-ticket 1)
date: 2026-06-10
status: draft
supersedes: docs/brainstorms/2026-05-17-eng-115-pivot-marker-verdict-shape-and-parsing-design.md
---

# ENG-115 — Pivot marker: verdict shape and parsing

> **Re-dispatch note.** The first brainstorm dispatch on this feature branch
> landed `docs/brainstorms/2026-05-17-eng-115-…-design.md` (committed in
> `9d37a4f`). This 2026-06-10 re-dispatch supersedes that doc. The archived
> version's `linear:` frontmatter was demoted to `linear-archived:` so
> `bin/reconcile.sh::resolve_via_control_label` selects this doc as canonical.
> Content is substantially identical (32 of 35 path:line refs re-verified
> against worktree HEAD `9d37a4f` — see §10.3). The one correction is
> `bin/pipeline.sh:117-122` (marker body composition; prior doc said 118-122,
> off-by-one against current code).

## 1. Overview

ENG-35 is the umbrella ticket for "let `implement` and `ui` agents
escalate to planning when the plan is **structurally wrong** rather
than merely incomplete." It deliberately split into three sub-tickets:

1. **ENG-115 (this ticket)** — define the marker shape, validate it at
   the writer (`bin/pipeline.sh`), parse it at the reader
   (`bin/verdict-handler.sh`), stop short of any orchestrator routing.
2. ENG-NEXT (not yet filed) — orchestrator routing (loopback to
   `planning` with `pipeline:supersede`, mirroring the existing
   `reviewing → brainstorming` loopback row in
   `bin/verdict-handler.sh:33`).
3. ENG-NEXT+1 (not yet filed) — `AGENT_PROMPTS.md` §§3-4 prose
   teaching implement/ui *when* to pivot.

The parsing-only split is load-bearing: the writer and reader need to
agree on the marker shape before any code path can use it, and
landing the shape independently of routing lets the next sub-ticket
land with zero registry/parser risk.

**State of the codebase today (verified 2026-06-10 — see §10
Assumption Inventory):**

- `bin/pipeline-events.json` already lists `"pivot"` in
  `verdict_results` (`bin/pipeline-events.json:8`) and
  `"pivot_targets": ["planning"]` (`bin/pipeline-events.json:32-34`).
  These were added at `be456ee` (ENG-87) alongside the dispatch_id
  vocabulary churn; they have *no* writer/reader behind them yet.
- `bin/pipeline.sh::cmd_event_verdict` has a `pivot)` arm
  (`bin/pipeline.sh:113-114`) that requires only `--target`. No
  `--reason` and no `--stage` (originating stage).
- `bin/verdict-handler.sh::find_fresh_verdict`'s jq projection
  (`bin/verdict-handler.sh:236-248`) has no `pivot` arm — a pivot
  body falls into the `marker:"unknown"` else branch
  (`bin/verdict-handler.sh:247`).
- `bin/verdict-handler.sh::verdict_handler`'s dispatch table
  (`bin/verdict-handler.sh:545-593`) has no `pipeline-pivot)` case —
  the `*)` arm routes to `_vh_protocol_violation "$issue"
  "unknown-marker"` (`bin/verdict-handler.sh:589-591`).
- `bin/common.sh::parse_pipeline_marker`
  (`bin/common.sh:338-400`) is a generic k=v parser; it already
  parses any `<!-- pipeline: verdict result=pivot k=v k=v -->`
  correctly into `{event:"verdict", result:"pivot", ...}`.

So the registry's claim that pivot is a verdict result is unbacked by
the call chain: today an agent that emits a pivot marker would
trigger a `protocol-violation/unknown-marker` halt with the comment
"`marker=unknown`" — confusing, since the marker is in the registry.
ENG-115 makes the call chain match the registry.

## 2. Goal

After ENG-115 lands:

- **AC#1.** `bash bin/pipeline.sh event ENG-N verdict pivot --target
  planning --stage implementing --reason plan-structural-defect`
  emits a registry-validated marker body
  `<!-- pipeline: verdict result=pivot target=planning
  stage=implementing reason=plan-structural-defect -->`.
- **AC#2.** Omitting any of `--target`, `--stage`, or `--reason`
  dies with a clear error message naming the missing flag.
- **AC#3.** Bogus values for any of those three flags die with a
  registry-aware error message ("not in &lt;field&gt; — allowed: ...").
- **AC#4.** `bin/verdict-handler.sh::find_fresh_verdict` projects a
  fresh pivot verdict to `{marker:"pipeline-pivot", source_stage:
  &lt;stage&gt;, target_stage:&lt;target&gt;, reason:&lt;reason&gt;, comment_id, event}`.
- **AC#5.** `bin/verdict-handler.sh::verdict_handler` dispatches the
  `pipeline-pivot` marker to a stub that emits a single
  `log "verdict-handler: pivot-detected on $issue (source=$src →
  target=$tgt, reason=$reason) — routing deferred to ENG-NEXT"`
  and returns rc=1 (halt-preserved; see D-5 for the rationale).
- **AC#6.** `docs/pipeline-vocabulary.md` regenerated to include the
  new `pivot_reasons` field and a one-paragraph "Reading the
  registry" entry for it.
- **AC#7.** Tests cover parsing pass/fail at both layers:
  - `bin/pipeline-test.sh` — PE7 updated (full three-field form); new
    PE7a/PE7b/PE7c for the missing-field rejection cases.
  - `bin/verdict-handler-test.sh` — new case-NN for fresh-pivot
    detection + stub log line + rc=1.
  - `bin/vocabulary-cleanliness-test.sh::case-2` `required_keys` list
    extended to include `pivot_reasons`.
- **AC#8.** Pre-commit hook (`.githooks/pre-commit`, every
  `bin/*-test.sh`) stays green.

Explicitly **OUT** (matches Linear issue's OUT scope):

- Any orchestrator routing (no new row in `_VH_LOOPBACK_TRANSITIONS`
  at `bin/verdict-handler.sh:32-38`; no `apply_transition` call from
  the new `pipeline-pivot)` arm).
- Any `_post_dispatch_apply_halt` carve-out for pivot
  (`bin/run-stage.sh:583-595`) — pivot continues to be halt-applied
  by the orchestrator's defensive halt-apply, exactly like halt itself.
- Any `AGENT_PROMPTS.md` change — implement and ui prompts continue
  to NOT mention pivot. Agents won't emit pivot until ENG-NEXT+1
  teaches them how.
- Any `pivot_rejection` counter in `bin/guards.sh` — the rate metric
  comes when there is real data, per ENG-35's OUT clause.

## 3. Architectural principle this extends

The harness has no formal ADR registry (verified — `docs/knowledge/`
does not exist; `Glob docs/VISION*` returns no matches). Governing
documents are `CLAUDE.md`, `docs/architecture.md`, and
`learned-rules/<slug>/project-profile.md`. No new ADR is proposed.

ENG-115 extends three existing implicit principles:

1. **Closed vocabulary registry (ENG-60).** Every key=value pair in
   a pipeline marker validates against
   `bin/pipeline-events.json`; unknown tokens cause `bin/pipeline.sh`
   to die loudly (`docs/pipeline-vocabulary.md:25-27`). Adding
   `pivot_reasons` as a new registry field is the direct extension
   of that pattern; the alternative — free-form pivot reason — would
   silently degrade the retrospective filter and `bin/status.sh`
   triage path.
2. **Writer-side validation, reader-side tolerance.** `bin/pipeline.sh`
   is the single sanctioned writer
   (`docs/pipeline-vocabulary.md:31`); it validates aggressively.
   `bin/verdict-handler.sh` parses what's actually on the wire — it
   does not re-validate against the registry (the registry already
   filtered at write time). The new `pipeline-pivot` projection in
   `find_fresh_verdict` follows the same shape as the existing
   `pipeline-stage-summary`/`pipeline-rejection`/`pipeline-halt`
   projections (`bin/verdict-handler.sh:240-247`).
3. **Stub-before-route.** ENG-122/ENG-123 split plan.json shipping
   into "writer ships valid JSON" (ENG-122) and "implement reads it"
   (ENG-123). The parsing-only sub-ticket pattern is the established
   harness approach for split-load risk: land the data contract
   first, then land the consumer. ENG-115 is the writer-side; the
   consumer (routing) is the next sub-ticket.

## 4. Decisions

Each decision is **D-N: &lt;verdict&gt;** + Why + rejected alternatives.
Every code reference cites a `path:line`.

### D-1: Marker shape — three required k=v pairs: `target`, `stage`, `reason`.

**Verdict.** A canonical pivot marker has exactly three required key=value
pairs in addition to `result=pivot`:

```
<!-- pipeline: verdict result=pivot target=planning stage=implementing reason=plan-structural-defect -->
```

- `result=pivot` — selects the verdict-result branch.
- `target=planning` — closed-vocab from `pivot_targets`
  (`bin/pipeline-events.json:32-34`; currently the only value).
  Identifies the loopback destination.
- `stage=implementing` — closed-vocab from `stages`
  (`bin/pipeline-events.json:52-61`). Identifies the originating
  stage (where the agent emitted the pivot). Required so the
  routing sub-ticket can attribute the loopback edge.
- `reason=plan-structural-defect` — closed-vocab from the new
  `pivot_reasons` registry field (see D-2). Closed-vocab from
  day-1 so the retrospective filter has a bucket key.

**Why.** Three concrete drivers:

1. **Routing sub-ticket needs all three.** The next sub-ticket will
   convert a fresh-pivot marker into an `apply_transition $issue
   $stage $target $side_labels` call (mirroring
   `bin/verdict-handler.sh:582`'s loopback dispatch). Without
   `target` in the marker, the orchestrator would have to hard-code
   `planning` — preventing any future `pivot_targets` expansion.
   Without `stage`, the orchestrator falls back to reading the
   `stage:*` label — which agrees with the originating stage today
   but disagrees in `resume_in_progress_transition` recovery paths
   (`bin/verdict-handler.sh:437-512`). The marker carries the
   originating stage explicitly so resume edge cases stay clean.
2. **Linear ticket text says all three.** The ENG-115 IN scope says
   "a `pivot` event with target=planning, reason field,
   originating-stage field." Three fields, three required arguments.
3. **Symmetry with `verdict result=halt`.** Halt requires
   `--reason` (`bin/pipeline.sh:109-110`). Pivot is the same shape
   ("agent is escalating") with one more dimension (where to go);
   carrying `--reason` makes the two shapes look like siblings in
   the registry and in the parsed JSON.

**Rejected alternative — single-field `stage=` (omit `target` and
`reason`).** Rejected because (a) it forces hard-coding `planning`
in the routing sub-ticket, blocking future `pivot_targets` growth;
(b) it loses the bucket key for retrospective filtering; (c) it
makes pivot a less-rich version of halt rather than a sibling.

**Rejected alternative — companion markers, `<!-- pipeline-pivot:
&lt;stage&gt; -->` + `<!-- pipeline-pivot-reason: &lt;reason&gt; -->` (the
shape proposed in ENG-35's parent body).** Rejected because (a)
the harness moved to the unified `<!-- pipeline: &lt;event&gt; k=v -->`
shape at ENG-60 — the companion-comment shape is *legacy* and
`bin/vocabulary-cleanliness-test.sh` would flag it
(`bin/vocabulary-cleanliness-test.sh:36`); (b) two-comment shapes
create a fresh class of "what if only one made it through?" race
that the unified marker side-steps; (c) `parse_pipeline_marker`
(`bin/common.sh:338-400`) is the single sanctioned reader and only
understands the unified shape. ENG-35's parent body was written
before the ENG-60 simplification landed; the unified shape is the
post-ENG-60 normal form.

**Rejected alternative — four+ fields (e.g., add `iteration=N` or
`evidence=&lt;sha&gt;`).** Rejected because YAGNI: the routing
sub-ticket has no consumer for either field, and the closed
vocabulary registry pattern makes it cheap to add a fourth field in
a follow-up if data accumulates a need for it.

### D-2: Registry — add `pivot_reasons: ["plan-structural-defect"]` as a new top-level field in `bin/pipeline-events.json`.

**Verdict.** New registry field, initial vocabulary one token:

```json
"pivot_reasons": [
  "plan-structural-defect"
]
```

**Why.** Three concrete drivers:

1. **Closed-vocabulary pattern.** ENG-60 made every marker field's
   permitted values explicit in `bin/pipeline-events.json`. Halt
   has `halt_reasons` (`bin/pipeline-events.json:10-21`), wait has
   `wait_reasons` (`:22-25`), fail has `fail_targets` (`:26-31`).
   Pivot needs the same shape; without `pivot_reasons`,
   `cmd_event_verdict` cannot call `_validate_registry` for
   `--reason` (`bin/pipeline.sh:80-84`).
2. **One token is enough to bootstrap.** The single token
   `plan-structural-defect` covers the parent ticket's stated use
   case ("plan needs to change"). Adding tokens is a one-line
   registry edit when the agent prompt teaches a second case;
   premature registry growth would clutter the vocabulary doc.
3. **The retrospective filter buckets by token.** Free-form reason
   means every pivot emission becomes its own bucket in the
   retrospective's §1 filter and `bin/status.sh`'s halt-sprawl
   classifier (`bin/halt-sprawl-test.sh`). Closed-vocab keeps the
   bucket count bounded.

**Rejected alternative — free-form `reason` (no registry).**
Rejected because (a) it breaks the closed-vocabulary invariant
asserted at `docs/pipeline-vocabulary.md:25-27` ("Every key=value
pair is validated against the closed registry below"); (b) the
retrospective filter loses its bucket key; (c) operator triage
loses the "is this a known shape?" signal.

**Rejected alternative — share the existing `halt_reasons`
registry (`bin/pipeline-events.json:10-21`).** Rejected because
the existing reasons (`agent-blocked`, `scope-violation`,
`dispatch-timeout`, etc.) describe *why a halt fired* — none of
them describe "the plan is wrong." Forcing pivot to alias one of
those tokens would conflate the two semantics in retrospective
buckets, defeating the field's purpose.

**Rejected alternative — `pivot_reasons: []` (initialize empty,
let agents propose tokens).** Rejected because an empty registry
makes `_validate_registry` reject every pivot attempt, which
means the writer is unusable until a follow-up. Lands one token
("plan-structural-defect") so the writer is usable from day-1.

### D-3: Writer — extend `bin/pipeline.sh::cmd_event_verdict`'s `pivot` arm at `bin/pipeline.sh:113-114` to require `--target` + `--stage` + `--reason`, and validate each against its registry field.

**Verdict.** The current arm:

```bash
pivot) [[ -n "$target" ]] || die "event verdict pivot: --target required"
       _validate_registry pivot_targets "$target" ;;
```

becomes:

```bash
pivot) [[ -n "$target" ]] || die "event verdict pivot: --target required"
       [[ -n "$stage" ]]  || die "event verdict pivot: --stage required"
       [[ -n "$reason" ]] || die "event verdict pivot: --reason required"
       _validate_registry pivot_targets "$target"
       _validate_registry stages "$stage"
       _validate_registry pivot_reasons "$reason" ;;
```

The marker body composition at `bin/pipeline.sh:117-122` already
appends `stage=` and `reason=` when the variables are non-empty —
no change there. (Corrected from prior 2026-05-17 doc which claimed
118-122; current code is 117-122.)

**Why.** Validates at write-time so a malformed pivot never reaches
Linear. Mirrors the existing pattern for `halt`
(`bin/pipeline.sh:109-110`) which requires `--reason` and validates.

**Rejected alternative — partial validation (require but don't
validate against the registry).** Rejected because the registry
exists to be enforced; skipping registry validation means a typo
(`reason=plan-structurla-defect`) silently sails through to
Linear and the routing sub-ticket would then need to handle the
mis-spelled token. Validation at the chokepoint is cheaper than
defense-in-depth at every reader.

**Rejected alternative — make `--stage` optional (derive from the
issue's `stage:*` label).** Rejected because (a) the writer should
not require a Linear round-trip just to validate its own argument;
(b) the explicit-arg path side-steps the
`resume_in_progress_transition` race documented in
`bin/verdict-handler.sh:437-512` where the stage label may
briefly disagree with the dispatched stage; (c) requiring the arg
makes the CLI self-documenting in operator transcripts.

### D-4: Reader (find_fresh_verdict) — add a `pivot` arm to the jq projection at `bin/verdict-handler.sh:236-248`.

**Verdict.** The current `if/elif/else` chain projecting fresh
verdicts to the legacy output shape:

```jq
($e.result) as $r |
if $r == "pass" then
  {marker:"pipeline-stage-summary", source_stage:$e.stage, target_stage:"", reason:"", comment_id:$id, event:$e}
elif $r == "fail" then
  {marker:"pipeline-rejection", source_stage:"", target_stage:$e.target, reason:"", comment_id:$id, event:$e}
elif $r == "halt" then
  {marker:"pipeline-halt", source_stage:"", target_stage:"", reason:$e.reason, comment_id:$id, event:$e}
else
  {marker:"unknown", source_stage:"", target_stage:"", reason:"", comment_id:$id, event:$e}
end
```

gains a new `elif` for `pivot`:

```jq
elif $r == "pivot" then
  {marker:"pipeline-pivot", source_stage:$e.stage, target_stage:$e.target, reason:$e.reason, comment_id:$id, event:$e}
```

Projection populates `source_stage` from `$e.stage`, `target_stage`
from `$e.target`, and `reason` from `$e.reason` — all three are
the registry-validated values D-3 forces the writer to provide.

**Why.** The `find_fresh_verdict` output shape is the established
contract between the reader and `verdict_handler`'s dispatch table
at `bin/verdict-handler.sh:545-593` (every existing case
destructures `source_stage` and/or `target_stage` from the JSON).
Adding `pipeline-pivot` to the same projection shape means the
dispatch table needs only a new `case` arm — no change to the
intermediate JSON contract.

**Rejected alternative — introduce a separate `find_fresh_pivot`
function paralleling `find_fresh_wait_verdict`
(`bin/verdict-handler.sh:261-298`).** Rejected because (a)
pivot is not stage-gated the way wait is (wait is
build-only); (b) the existing dispatch table at line 545 is
already the chokepoint for "decide what to do based on the fresh
verdict" — a parallel reader would double the freshness logic
without buying a clean separation; (c) `find_fresh_wait_verdict`
exists because wait is special-cased pre-dispatch in
`run-stage.sh::_fresh_wait_reason` (`bin/run-stage.sh:513-559`),
not because wait is structurally different at the marker layer.

### D-5: Reader (verdict_handler) — add a `pipeline-pivot)` arm to the dispatch table at `bin/verdict-handler.sh:545-593` that logs and returns rc=1 (halt-preserved).

**Verdict.** The new arm sits between `pipeline-halt)` and the `*)`
fallback:

```bash
pipeline-pivot)
  # ENG-115: parsing-only. The next sub-ticket will replace the log line
  # with an `apply_transition "$issue" "$src" "$tgt" "pipeline:supersede"`
  # call mirroring the reviewing → brainstorming loopback at line 32.
  local pivot_reason
  pivot_reason="$(jq -r '.reason' <<<"$fresh")"
  log "verdict-handler: pivot-detected on $issue (source=$src → target=$tgt, reason=$pivot_reason) — routing deferred to ENG-NEXT"
  return 1
  ;;
```

`return 1` is the halt-preserved code at the verdict_handler
contract (`bin/verdict-handler.sh:6-9`). The caller in
`bin/run-stage.sh:1949-1988` interprets rc=1 as "halt-for-human" —
the orchestrator's `_post_dispatch_apply_halt` defensive halt-apply
at `bin/run-stage.sh:583-595` (which runs *before* verdict_handler
at line 1904) has already applied `pipeline:halted` because the
fresh verdict's result is not `wait`. The combined behaviour: a
pivot marker results in a halted issue, an operator-visible log
line in the per-stage transcript, and no orchestrator-side
state corruption.

**Why.** Three concrete drivers:

1. **Parsing-only scope.** The Linear issue's IN scope explicitly
   says "routes to a stub `pivot-detected` log line." The stub
   has to *do something*; the safest something is "log and let
   the orchestrator's existing halt-apply machinery handle it."
2. **Halt-preserved is the safest semantic for unwired routing.**
   Returning rc=0 (success) would trigger
   `bin/run-stage.sh:1963-1976`'s success cleanup (remove
   skip-labels, clear issue-state.json) and post a `stage-end
   ... outcome=success` metric — silent state corruption since
   no transition actually happened. Returning rc=2
   (protocol-violation) would emit a second halt comment with a
   misleading `marker=unknown` body (the path today) — worse
   operator-facing experience. rc=1 is the only option that
   matches the actual state ("agent emitted a marker we
   recognize but cannot yet route; operator action required").
3. **Forward-compatible.** When the routing sub-ticket lands, the
   only change is to replace the log+return body with
   `apply_transition ... return 0`. The fixture wiring stays
   the same; only the assertion changes from `rc == 1` to
   `rc == 0` with transition side-effects.

**Rejected alternative — return 0 (treat as silent success).**
Rejected because of the state-corruption path above. The success
arm clears `issue-state.json` and skip labels, and emits a
`stage-end outcome=success verdict=transitioned` metric — both
plainly false when no transition happened.

**Rejected alternative — return 2 (protocol-violation).** Rejected
because pivot is a legitimate verdict result in the registry; the
verdict_handler's job is to recognise it, not to flag it as a
violation. The pre-ENG-115 behaviour (pivot → `unknown-marker`
protocol violation) is the bug ENG-115 fixes.

**Rejected alternative — add a new rc=3 ("pivot-detected, routing
deferred").** Rejected because it forces a `bin/run-stage.sh`
edit to handle the new code in the rc-dispatch at
`bin/run-stage.sh:1949-1988`, expanding scope beyond
parsing-only. Halt-preserved (rc=1) is the only existing code
that's semantically defensible without that edit.

**Rejected alternative — post a Linear comment ("pivot
acknowledged, routing not yet wired").** Rejected because the
orchestrator's defensive `_post_dispatch_apply_halt` already
applies `pipeline:halted` (the operator-visible signal); a
second comment would be redundant chatter and would have to be
removed when routing lands. The per-stage transcript log line is
the durable forensic record.

### D-6: Tests — extend the three existing test files; no new test file.

**Verdict.**

- **`bin/pipeline-test.sh`** (current PE7 at lines 82-83):
  - Rewrite PE7 to use the full three-field form and assert the
    full body:
    ```bash
    out="$(run_pipe event ENG-PE7 verdict pivot --target planning --stage implementing --reason plan-structural-defect)"
    expect='<!-- pipeline: verdict result=pivot target=planning stage=implementing reason=plan-structural-defect -->'
    [[ "$out" == *"$expect"* ]] && pass_at "PE7: verdict pivot full body" || ...
    ```
  - Add **PE7a** — missing `--reason` rejected.
  - Add **PE7b** — bogus `--reason` rejected (registry validation).
  - Add **PE7c** — missing `--stage` rejected.
  - Add **PE7d** — bogus `--stage` rejected.
- **`bin/verdict-handler-test.sh`** (case-shape established at
  lines 139-156):
  - Add **case-NN-pivot-detected**: fresh `verdict result=pivot
    target=planning stage=implementing reason=plan-structural-defect`
    comment after a transition; assert `verdict_handler` returns 1,
    no `add-label ENG-N stage:planning` call, no
    `add-or-update-comment protocol-violation/` call, log line
    contains `pivot-detected`.
  - Add **case-NN-pivot-find-fresh-projection**: same fixture,
    call `find_fresh_verdict` directly; assert `jq -r '.marker'`
    returns `pipeline-pivot`, `.source_stage` returns
    `implementing`, `.target_stage` returns `planning`, `.reason`
    returns `plan-structural-defect`.
- **`bin/vocabulary-cleanliness-test.sh`** (line 102-103):
  - Add `pivot_reasons` to the `required_keys` array.
  - Add a new `case-ENG-115` block asserting
    `jq -e '.pivot_reasons | index("plan-structural-defect")
    != null'`, mirroring the existing `case-4`
    (`bin/vocabulary-cleanliness-test.sh:146-155`).
- **`bin/run-stage-test.sh::WS8`** (lines 2487-2503): the existing
  fixture uses `<!-- pipeline: verdict result=pivot stage=building -->`
  (no target, no reason). It exercises the parser, not the writer;
  the predicate it tests is "any non-wait verdict shadows wait" —
  which D-3's writer-tightening does not affect. **No change to
  WS8 needed**; the fixture is a hand-crafted Linear comment data
  shape, not a pipeline.sh-produced body. Calling this out
  explicitly so a future reader does not "fix" a working test.

**Why.** All three changes are within existing test files using the
existing source-and-stub pattern (CLAUDE.md "How tests work").
`.githooks/pre-commit` runs every `bin/*-test.sh` so the new
cases land in the gate automatically. No new test file means no
new boilerplate.

**Rejected alternative — new file `bin/pivot-test.sh`.** Rejected
because pivot's three test surfaces all already have a sibling
test file (`pipeline-test`, `verdict-handler-test`,
`vocabulary-cleanliness-test`); adding a fourth would force a
future reader investigating "pivot behaviour" to read four files
instead of three.

### D-7: Vocabulary doc regeneration — extend `bin/generate-vocabulary-doc.sh:14` to include `pivot_reasons` in the for-loop, and update the template's "Reading the registry" section with a one-paragraph entry.

**Verdict.** Two edits:

- `bin/generate-vocabulary-doc.sh:14`: extend the for-loop's field
  list:
  ```bash
  for field in verdict_results halt_reasons wait_reasons fail_targets pivot_targets pivot_reasons decision_actions decision_gates meta_kinds stages; do
  ```
- `docs/pipeline-vocabulary.template.md` (between the existing
  `pivot_targets` paragraph at lines 74-75 and the
  `decision_actions` paragraph at lines 76-77): add
  ```markdown
  - **`pivot_reasons`** — why an agent declared the plan is
    structurally wrong. Currently only `plan-structural-defect`.
    Mirrors the `halt_reasons` shape; the rare-and-bucketed
    discipline applies (the retrospective surfaces pivot rates so
    we can size when to grow the vocabulary). *Routing of pivot
    markers (loopback to `stage:planning` with `pipeline:supersede`)
    is not yet wired in ENG-115; the verdict_handler logs the
    detection and halts the issue pending the routing sub-ticket.
    Operator recovery is `bin/pipeline.sh decide --action continue`,
    same as any other halt.*
  ```
- Re-run `bash bin/generate-vocabulary-doc.sh` to refresh
  `docs/pipeline-vocabulary.md` (the generated registry section is
  auto-rebuilt; the new template paragraph lands above it).

**Why.** The generator already covers `pivot_targets` and reading
docs are operator-facing; without the template paragraph, the
new field would appear in the generated registry block with no
prose context. Mirrors the structure used for every other
registry field.

**Rejected alternative — skip the doc regeneration in this
ticket; defer to a follow-up.** Rejected because the vocabulary
doc is the single source of operator truth for marker shapes
(`docs/pipeline-vocabulary.md:54`); shipping a writer that
emits `reason=...` against a registry the doc does not describe
silently widens the doc-vs-code drift surface
`bin/vocabulary-cleanliness-test.sh` exists to prevent.

## 5. Architecture (where code goes)

| Site | Change |
|---|---|
| `bin/pipeline-events.json:32-34` (after `pivot_targets`) | New field `"pivot_reasons": ["plan-structural-defect"]`. |
| `bin/pipeline.sh:113-114` (pivot arm of `cmd_event_verdict`) | Extend to require + validate `--target`, `--stage`, `--reason`. |
| `bin/verdict-handler.sh:236-248` (jq projection in `find_fresh_verdict`) | Add `elif $r == "pivot"` arm projecting to `marker:"pipeline-pivot"`. |
| `bin/verdict-handler.sh:545-593` (dispatch table in `verdict_handler`) | Add `pipeline-pivot)` case before `*)`; log and return 1. |
| `bin/generate-vocabulary-doc.sh:14` | Extend for-loop to include `pivot_reasons`. |
| `docs/pipeline-vocabulary.template.md:74-75` | Add `pivot_reasons` paragraph. |
| `docs/pipeline-vocabulary.md` | Regenerated from template + registry via `bash bin/generate-vocabulary-doc.sh`. |
| `bin/pipeline-test.sh:82-83` | Rewrite PE7; add PE7a/PE7b/PE7c/PE7d. |
| `bin/verdict-handler-test.sh` (end of file, before summary) | Add case-NN-pivot-detected + case-NN-pivot-find-fresh-projection. |
| `bin/vocabulary-cleanliness-test.sh:102-103` | Add `pivot_reasons` to `required_keys`; add `case-ENG-115` token assertion. |

No edits to `bin/run-stage.sh`, `bin/poll.sh`, `bin/guards.sh`,
`bin/classify-failure.sh`, `AGENT_PROMPTS.md`, or
`learned-rules/`. Routing edits land in the next sub-ticket.

## 6. Data flow

```
agent (implement | ui, hypothetically; today: operator manual)
  │
  │  bash bin/pipeline.sh event ENG-N verdict pivot \
  │      --target planning --stage implementing \
  │      --reason plan-structural-defect
  │
  ▼
bin/pipeline.sh::cmd_event_verdict (pivot arm, D-3)
  │
  │  validates each field against bin/pipeline-events.json
  │  composes body: "<!-- pipeline: verdict result=pivot target=planning
  │                  stage=implementing reason=plan-structural-defect -->"
  │
  ▼
bin/linear.sh add-comment ENG-N "<body>"
  │
  │  (auto-injects <!-- meta: dispatch id=... stage=... --> per ENG-87)
  │
  ▼
Linear comment thread
  │
  │  (orchestrator next-tick polls; reaches post-dispatch phase)
  │
  ▼
bin/run-stage.sh::main
  │
  │  _post_dispatch_apply_halt — fresh verdict result != wait → applies pipeline:halted
  │
  ▼
verdict_handler (bin/verdict-handler.sh:515)
  │
  │  find_fresh_verdict → strict-id-match returns the pivot comment
  │  jq projection → {marker:"pipeline-pivot", source_stage:"implementing",
  │                   target_stage:"planning", reason:"plan-structural-defect",
  │                   comment_id, event}
  │
  ▼
case "pipeline-pivot") arm (D-5)
  │
  │  log "verdict-handler: pivot-detected on ENG-N (source=implementing → target=planning,
  │       reason=plan-structural-defect) — routing deferred to ENG-NEXT"
  │  return 1
  │
  ▼
bin/run-stage.sh:1978-1982 (rc=1 branch)
  │
  │  stage-end metric: outcome=halt-for-human verdict=halt
  │
  ▼
issue sits halted; pipeline:halted label visible to operator
operator runs `bash bin/pipeline.sh decide ENG-N --action continue` to reset
```

## 7. Error handling

| Failure mode | Layer | Response |
|---|---|---|
| `cmd_event_verdict pivot` called with missing `--target`/`--stage`/`--reason` | writer | `die "event verdict pivot: --X required"`. |
| `cmd_event_verdict pivot` called with bogus token | writer | `die "registry: 'X' not in &lt;field&gt; — allowed: ..."` (existing `_validate_registry` shape, `bin/pipeline.sh:80-84`). |
| Pivot marker reaches Linear with a malformed body (operator hand-crafted, bypassing pipeline.sh) | reader | `parse_pipeline_marker` returns the best-effort parse. `find_fresh_verdict`'s jq projection requires `$e.stage`/`$e.target`/`$e.reason` — null values pass through as JSON `null` to verdict_handler, which calls `jq -r '.reason'` producing the string `"null"`. The log line shows `reason=null`. Operator sees `pipeline:halted` and `decide --action continue` to recover. *Not a new failure mode introduced by ENG-115 — it's the same handling shape as today's halt with a hand-crafted body.* |
| `verdict_handler` reached with `_curr_id` unset (legacy issues, pre-ENG-87) | reader | Falls through to the timestamp-window legacy fallback (`bin/verdict-handler.sh:201-223`). Pivot marker projected the same way; behaviour identical. |
| Two pivot markers in the same dispatch window | reader | `find_fresh_verdict` picks the latest by timestamp (`bin/verdict-handler.sh:189-191`); existing semantics. |
| Pivot marker shadowed by a newer halt/pass/fail | reader | The newer marker wins; pivot is suppressed. Existing WS3-shape semantics from `_fresh_wait_reason` (`bin/run-stage.sh:557-559`) — D-004 symmetry from `bin/run-stage-test.sh:WS8`. |
| Pivot from a stage outside implement/ui (e.g., reviewing) | writer | Accepted at the writer (the registry does not restrict which stages may emit pivot; `stages` registry validates the *value*, not who emitted). The next sub-ticket will add reader-side stage gating; today the log line is informational only — no transition fires. |
| `pivot_reasons` field absent from `bin/pipeline-events.json` (e.g., partial revert) | writer + cleanliness test | `_validate_registry pivot_reasons "$reason"` dies with `"'X' not in pivot_reasons — allowed: "` (empty allowed list — surfaces immediately). `bin/vocabulary-cleanliness-test.sh::case-2` also catches missing registry keys at every test run. |

## 8. Edge cases

- **Operator emits pivot manually for forensic recovery.** Supported.
  `PIPELINE_WRITER=human bash bin/pipeline.sh event ENG-N verdict
  pivot ...` warns about the lane mismatch
  (`bin/pipeline.sh:129-131`) but still writes — same pattern as
  the existing `PL1` test at `bin/pipeline-test.sh:128-129`. Today's
  parsing-only handler logs the detection; the next sub-ticket
  will route.
- **Two pivot markers in the same dispatch (agent re-emits).**
  ENG-87 strict-id-match takes the latest (`bin/verdict-handler.sh
  :189-191`); the older one is invisible. No state divergence.
- **Pivot emitted from a stage outside implement/ui.** Writer
  accepts (no enforcement at write time); reader logs the
  detection; orchestrator applies `pipeline:halted`. The next
  sub-ticket's routing will need to decide whether to gate by
  stage at the reader; out of scope here.
- **Pivot marker that lacks the `<!-- meta: dispatch id=... -->`
  auto-injection (legacy issues + manual operator emission with
  `PIPELINE_DISPATCH_ID` unset).** `find_fresh_verdict` falls
  through to the timestamp-window legacy path
  (`bin/verdict-handler.sh:201-223`), which works identically.
- **Pivot marker arrives after a `transition` waypoint with the
  same target.** Today's `find_fresh_verdict` strict-id path
  filters comments by current dispatch_id; the transition
  waypoint would not carry the current id (it was posted by a
  prior dispatch) so does not interfere. The pivot is detected
  normally.
- **WS8 fixture (existing) uses `result=pivot stage=building` with
  no target/reason.** Continues to parse — `parse_pipeline_marker`
  is field-tolerant. The new `find_fresh_verdict` jq arm would
  project to `{marker:"pipeline-pivot", source_stage:"building",
  target_stage:null, reason:null, ...}`. WS8 does not call
  `verdict_handler`; it only tests the wait-shadow predicate, so
  the null target/reason are harmless. *Documented in D-6 so
  this is not "fixed" later.*
- **A `<!-- meta: dispatch id=... -->` marker that mentions
  `result=pivot` in prose (e.g., a halt body diagnosing pivot
  attempts).** `parse_pipeline_marker`'s pipeline-family
  precedence rule (`bin/common.sh:347-358`) wins on the first
  `<!-- pipeline: ... -->` regex match; prose embedded in a meta
  marker is not detected as a real pivot. Same protection that
  prevents halt-body prose from being detected as verdicts.
- **Pivot emitted during a `resume_in_progress_transition`
  recovery.** The recovery completes the existing transition's
  label work without re-posting the transition comment
  (`bin/verdict-handler.sh:507-510`); the verdict_handler is then
  invoked from a clean state. A pivot detected here logs
  normally; no compound transition.

## 9. Open questions

1. **OQ-1.** Should the `pivot_reasons` vocabulary land with a
   second token (e.g., `plan-misses-existing-constraint`) so
   the implement-prompt sub-ticket has more than one bucket to
   teach from? *Recommendation: ship single-token to keep ENG-115
   tight; expand when the agent-prompt sub-ticket has a concrete
   distinction it wants to draw.* Marker: assumed.

2. **OQ-2.** Should `_post_dispatch_apply_halt`
   (`bin/run-stage.sh:583-595`) carve out pivot the way it
   carves out wait? *Recommendation: No, in this ticket.* Pivot
   is parsing-only here; halt is the right state for "I cannot
   yet route." The carve-out belongs in the routing sub-ticket,
   where `verdict_handler` will return rc=0 with an actual
   transition applied — at which point `_post_dispatch_apply_halt`
   *also* needs to suppress halt-apply for pivot (otherwise the
   transition would still be halt-labeled). Filing a follow-up
   note on the routing ticket. Marker: assumed.

3. **OQ-3.** Should the verdict_handler stub additionally bump
   a `pivot_detected` counter via `bash bin/metrics.sh`? *That
   would emit a structured event for the retrospective filter
   without yet routing — useful for "how often is this fired but
   ignored?" observability.* **Recommendation: defer to the
   routing sub-ticket.** Until routing lands, the agent prompt
   does not teach pivot, so no agent will fire it — the only
   firers are manual operator emissions, which are visible in
   the per-stage transcript already. Adding a metric for a
   no-op event is YAGNI. Marker: assumed.

4. **OQ-4.** ENG-35's parent body says pivot triggers the
   `pipeline:supersede` label as a side-effect (mirroring
   `reviewing → brainstorming`). Should we land `supersede` in
   the registry as part of ENG-115, or wait for routing?
   *Recommendation: wait for routing.* `pipeline:supersede` is
   not a marker token; it's a Linear label applied by
   `apply_transition`'s side-effect param
   (`bin/verdict-handler.sh:418-426`). No registry entry
   needed; the label already exists in the codebase via
   `bin/verdict-handler.sh:34` and `bin/poll.sh` consumers.
   Marker: verified — `Grep "pipeline:supersede"` shows
   existing references at `bin/verdict-handler.sh:34`,
   `bin/run-stage.sh:1975`, others. The label is a no-op until
   the next sub-ticket's `apply_transition` call wires it.

## 10. Anti-bias checks

### 10.1 ADR stress test

The harness has no formal ADR registry. The closest analogues are
the documented decisions in `CLAUDE.md` and `docs/architecture.md`.
ENG-115 puts pressure on three:

- **"Closed vocabulary registry" (CLAUDE.md "Pipeline vocabulary"
  + `docs/pipeline-vocabulary.md:25-27`).** ENG-115 *extends* this
  pattern (new `pivot_reasons` field with single token). No
  pressure to relax it. ✓
- **"Single human-approval gate (ENG-54)"
  (`docs/architecture.md:233`).** ENG-115 does not introduce
  a new human-action gate; pivot's eventual routing (next
  sub-ticket) returns the issue to `planning` for the
  planning-agent to re-attempt, with no operator intervention
  required for the auto-routing case. No pressure. ✓
- **"Stub-before-route" (informal — used in ENG-122/ENG-123 split,
  ENG-58/ENG-60 split, ENG-87 review iterations).** ENG-115
  reinforces this pattern (parsing-only sub-ticket lands data
  contract; routing sub-ticket lands consumer). No pressure. ✓

The one real tradeoff is operator-experience cost during the gap
between ENG-115 landing and the next sub-ticket landing: a manual
pivot emission today produces a halt rather than a transition. This
is a short-lived cost (next sub-ticket is expected within days)
and is bounded by the existing `decide --action continue` recovery.

### 10.2 Simpler alternative per major decision

| Decision | Simpler alternative considered | Why rejected |
|---|---|---|
| D-1 (three required fields) | Single-field `stage=` only | Forces hard-coded routing target; loses bucket key for retrospective. |
| D-1 (unified marker shape) | ENG-35 parent's companion-comment shape | Legacy shape; `vocabulary-cleanliness-test` flags it; race-prone. |
| D-2 (`pivot_reasons` registry) | Free-form `reason=` field | Violates closed-vocab invariant; degrades retrospective bucketing. |
| D-2 (initial vocabulary one token) | Initial vocabulary empty | Writer unusable until follow-up; one token is enough to bootstrap. |
| D-3 (validate at writer) | Read-side validation only | Doubles defense; bogus tokens still reach Linear; not the established pattern. |
| D-3 (require `--stage` as arg) | Derive from issue's `stage:*` label | Adds Linear round-trip to writer; race with `resume_in_progress_transition`. |
| D-4 (extend `find_fresh_verdict`) | Parallel `find_fresh_pivot` function | Doubles freshness logic; existing dispatch table is the right chokepoint. |
| D-5 (return rc=1 halt-preserved) | Return rc=0 (success) | Silent state corruption — clears issue-state.json + emits false success metric. |
| D-5 (return rc=1 halt-preserved) | Return rc=2 (protocol-violation) | Pivot is legitimate; emitting a violation comment is worse-than-today UX. |
| D-5 (return rc=1 halt-preserved) | New rc=3 ("pivot-detected") | Forces `run-stage.sh` edit; expands scope beyond parsing-only. |
| D-6 (extend existing test files) | New `bin/pivot-test.sh` | Splits pivot test surface across four files instead of three; harder to discover. |
| D-7 (regenerate vocab doc) | Defer doc regen | Widens doc-vs-code drift surface; cleanliness gate complains downstream. |

### 10.3 Assumption inventory

Every named code symbol or path:line referenced in §§1-9 was opened
and verified against the worktree HEAD `9d37a4f` (branch
`feat/eng-115-pivot-marker-verdict-shape-and-parsing`) on
2026-06-10. The `status` column tags each as **verified** (read in
this dispatch) or **assumed** (extrapolation that the
implementation will surface). Re-verification on this dispatch
exposed one off-by-one in the prior 2026-05-17 doc (A5: was
118-122, current 117-122); the architecture table §5 and D-3 above
carry the corrected range.

| # | Claim | path:line | Status |
|---|---|---|---|
| A1 | `"pivot"` listed in `verdict_results` | `bin/pipeline-events.json:8` | verified |
| A2 | `pivot_targets: ["planning"]` registry field exists | `bin/pipeline-events.json:32-34` | verified |
| A3 | `cmd_event_verdict` `pivot)` arm requires `--target` only | `bin/pipeline.sh:113-114` | verified |
| A4 | `_validate_registry` shape `"X not in &lt;field&gt;"` | `bin/pipeline.sh:80-84` | verified |
| A5 | Marker body composition appends `stage=` / `target=` / `reason=` conditionally | `bin/pipeline.sh:117-122` | verified (corrected from prior doc's 118-122) |
| A6 | Lane-fence warning shape for `PIPELINE_WRITER != agent` | `bin/pipeline.sh:129-131` | verified |
| A7 | `find_fresh_verdict` jq projection has pass/fail/halt arms; pivot falls to `marker:"unknown"` | `bin/verdict-handler.sh:236-248` | verified |
| A8 | `verdict_handler` dispatch table has pipeline-stage-summary/rejection/halt cases; `*)` routes to `unknown-marker` protocol violation | `bin/verdict-handler.sh:545-593` | verified |
| A9 | `_VH_LOOPBACK_TRANSITIONS` table at `bin/verdict-handler.sh:32-38` lists existing loopback rows | `bin/verdict-handler.sh:32-38` | verified |
| A10 | `apply_transition` accepts `(issue, from, to, side_labels_csv)` shape | `bin/verdict-handler.sh:309-311` | verified |
| A11 | `find_fresh_wait_verdict` exists as a parallel sibling | `bin/verdict-handler.sh:261-298` | verified |
| A12 | `resume_in_progress_transition` is the recovery path | `bin/verdict-handler.sh:437` (defn) → ~512 | verified |
| A13 | `_post_dispatch_apply_halt` runs before `verdict_handler` in run-stage.sh main | `bin/run-stage.sh:1904,1921` | verified |
| A14 | `_post_dispatch_apply_halt` wait-shape carve-out only excludes `wait` | `bin/run-stage.sh:583-595` | verified |
| A15 | run-stage rc=0/1/2 dispatch arms (success / halt-for-human / protocol-violation) | `bin/run-stage.sh:1949-1988` | verified |
| A16 | `parse_pipeline_marker` is a generic k=v parser; family precedence pipeline > meta | `bin/common.sh:338-400` (family precedence at 347-358) | verified |
| A17 | Generator's for-loop with registry-field list (no `pivot_reasons` yet) | `bin/generate-vocabulary-doc.sh:14` | verified |
| A18 | Template `pivot_targets` paragraph at lines 74-75 | `docs/pipeline-vocabulary.template.md:74-75` | verified |
| A19 | `vocabulary-cleanliness-test::case-2` `required_keys` list | `bin/vocabulary-cleanliness-test.sh:102-103` | verified |
| A20 | `vocabulary-cleanliness-test::case-4` (plan-contract-invalid pattern to mirror) | `bin/vocabulary-cleanliness-test.sh:146-155` | verified |
| A21 | `pipeline-test.sh` PE7 current shape | `bin/pipeline-test.sh:82-83` | verified |
| A22 | `pipeline-test.sh` PE3 / PE4 rejection-shape pattern to mirror | `bin/pipeline-test.sh:67-73` | verified |
| A23 | `verdict-handler-test.sh` case-1 shape (fixture + mk_fixture + reset_calls + asserts) | `bin/verdict-handler-test.sh:139-156` | verified |
| A24 | `assert_marker_event` helper for spec-shape assertions | `bin/verdict-handler-test.sh:110-124` | verified |
| A25 | `run-stage-test.sh::WS8` fixture uses pivot without target/reason | `bin/run-stage-test.sh:2487-2503` | verified |
| A26 | `_fresh_wait_reason` predicate is "any non-wait shadows wait" | `bin/run-stage.sh:559` (`[[ "$fresh_result" != "wait" ]] && return 1`) | verified |
| A27 | ENG-35 parent ticket says companion-comment shape `<!-- pipeline-pivot: -->` + `<!-- pipeline-pivot-reason: -->` | Linear ENG-35 body (carried forward from 2026-05-17 doc; not re-fetched this dispatch — the ENG-35 body has not been amended) | verified-by-prior-dispatch |
| A28 | ENG-122/ENG-123 stub-before-route split precedent | `docs/brainstorms/2026-05-15-eng-122-...md`, `docs/brainstorms/2026-05-15-eng-123-...md` | verified (file presence) |
| A29 | `docs/knowledge/` does not exist (no formal ADR registry) | (no path — `ls docs/knowledge/` returned "No such file or directory") | verified |
| A30 | `docs/VISION.md` does not exist | (no path — `ls docs/VISION*` returned no matches) | verified |
| A31 | No `learned-rules/harness/brainstorm.md` (no harness-stage brainstorm rules) | (only `build.md` and `project-profile.md` present under `learned-rules/harness/`) | verified |
| A32 | `pipeline:supersede` exists in the codebase as a label | `bin/verdict-handler.sh:34`, `bin/run-stage.sh:1975` | verified |
| A33 | Implementing the writer-side tightening will not break existing tests (only PE7 needs update) | (extrapolation: D-3 narrows the writer; existing tests for pass/fail/halt/wait/transition are untouched) | assumed — will validate at implement time |
| A34 | Adding the new `find_fresh_verdict` arm will not break existing case-1 through case-NN tests | (extrapolation: the new `elif` adds a branch but does not modify existing branches) | assumed — will validate at implement time |
| A35 | Routing the pivot to rc=1 in verdict_handler integrates with `_post_dispatch_apply_halt`'s existing behaviour without orchestrator-side changes | (extrapolation: halt is already applied for non-wait verdicts, and verdict_handler rc=1 is "halt preserved" — no orchestrator-side flow change needed) | assumed — will validate at implement time with a smoke test in `bin/verdict-handler-test.sh` |

The three **assumed** entries (A33-A35) are validation-by-test-suite
items; the implement-stage agent must run
`bash bin/pipeline-test.sh && bash bin/verdict-handler-test.sh &&
bash bin/vocabulary-cleanliness-test.sh && bash bin/run-stage-test.sh`
green before committing.

## 11. Persona review

Six personas were run in the exact order **design → security → scope
→ coherence → product → feasibility** (feasibility last because
codebase-fact errors are always P0). Verdicts and findings recorded
here as the durable audit trail; the Linear stage-summary carries
only the headline.

### 11.1 Design — PASS

**Verdict.** PASS.

The design is the minimum coherent set of changes to make the
existing registry's `"pivot"` token actually work end-to-end. Three
registry edits, two `bash` file edits, three test file edits, one
generator edit, one template edit. No new abstractions, no new
data shapes outside the established marker family. The
sub-ticket-split rationale (parsing-only landing first) follows
ENG-122/ENG-123 and ENG-60's precedent.

**Findings:** none.

### 11.2 Security — PASS

**Verdict.** PASS.

No new attack surface. The writer-side validation calls the
existing `_validate_registry` (`bin/pipeline.sh:80-84`) which is
already tested against shell-metachar injection via PE3 / PT2 /
PD6. The reader-side `jq` projection only reads from JSON the
parser already produced; no shell-metachar reaches `bash`. The log
line in D-5 uses `log "..."` which is a stderr writer with no
unescaped variable expansion vectors beyond the existing pattern
used throughout `bin/verdict-handler.sh`.

The new registry field follows the same closed-vocab discipline
as `halt_reasons`; the validation chokepoint is the same; the
adversarial test surface (`bin/verdict-adversarial-test.sh`)
already exercises the surrounding code paths.

**Findings:** none.

### 11.3 Scope — PASS

**Verdict.** PASS.

The doc explicitly lists OUT-of-scope items matching the Linear
issue's OUT section (orchestrator routing, AGENT_PROMPTS.md
updates). The implementation surface is one subsystem
(orchestrator / pipeline vocabulary) per the CLAUDE.md ticket
sizing rubric — autonomy-safe. The doc itself flags the future
sub-tickets explicitly so the operator can audit the unstated
work.

**Findings:** none.

### 11.4 Coherence — PASS

**Verdict.** PASS.

The data flow diagram (§6) traces a complete pivot from agent
emission to operator-visible halt, and identifies every
intermediate site. The architecture table (§5) lists every file
to edit with `path:line` references. The §3 principles section
cites three existing patterns each decision extends. The
assumption inventory (§10.3) verifies 32 of 35 claims against
current code; the 3 assumed claims are validation-by-test-suite
which is the established harness convention.

The 2026-06-10 re-dispatch caught a single line-range drift in
the prior doc (A5: 118-122 → 117-122). No semantic change to any
decision; the change set is identical.

**Findings:** none.

### 11.5 Product — PASS

**Verdict.** PASS.

Without ENG-115, an agent that emits a pivot marker (manual or
otherwise) triggers a `protocol-violation/unknown-marker` halt
with a body that reads `marker=unknown` — confusing to operators
because the marker IS in the registry. ENG-115 makes the
behaviour match the registry: a recognised pivot marker produces
a recognisable log line and the standard halt experience pending
routing. Operator-visible improvement is real even before routing
lands.

The fact that pivot continues to halt after ENG-115 (until
routing lands) is documented in §6 data flow and §10.1 ADR stress
test — the operator-experience cost is bounded by the existing
`decide --action continue` recovery and is short-lived.

D-7's vocabulary template paragraph includes the routing-not-yet-wired
operator warning carried over from the 2026-05-17 product-iter-1
finding; that resolution is durable across this re-dispatch.

**Findings:** none.

### 11.6 Feasibility — PASS (0 P0)

**Verdict.** PASS — zero P0 findings.

Codebase-fact verification:

- All `path:line` references in §§1-10 cross-checked against the
  worktree (see Assumption Inventory §10.3). 32 verified, 3
  assumed (validation-by-test-suite).
- The proposed change set is small: one JSON edit, two bash file
  edits, three test file edits, one generator edit, one template
  edit, one doc regeneration. Total lines added < 100 by
  inspection.
- Test infrastructure is established (source-and-stub pattern;
  every test file already mocks `linear.sh`).
- No external dependencies (no new bins, no new env vars, no
  Linear-side state).
- Pre-commit hook runs every `bin/*-test.sh`; CI surface is
  identical to all prior sub-ticket landings.
- No conflict with the ENG-87 dispatch_id contract: pivot markers
  go through the same auto-injection chokepoint at
  `bin/linear.sh::add_comment`; `find_fresh_verdict`'s strict-id
  filter (`bin/verdict-handler.sh:175-200`) sees pivot bodies
  identically to other verdict bodies.

**Re-dispatch delta (2026-06-10).** This re-dispatch checked the
`origin/feat/eng-115-...` branch one commit ahead (already has a
`planning for ENG-115` commit `19de561`), but the worktree HEAD is
`9d37a4f` (brainstorming commit); the codebase reflected in this
brainstorm is the worktree state, not the origin state. The
landing assumptions are unchanged by the planning commit (planning
landed a plan doc, not a registry edit).

The branch is also missing churn that landed on `main` after
2026-05-17 (ENG-150 removed `linear.sh::add-or-update-comment`,
ENG-156 added `sandbox-contract-violation`, ENG-119 added
`review-payload-invalid`, ENG-112 added a ledger schema, ENG-152
split stage-completion-claim, ENG-113 added qa_predicate_path).
None of those changes touch the pivot writer/reader call chain;
they will land on this branch via the standard rebase-on-build
loopback path when the implementing sub-ticket merges. *Flagged
here so the implementing-stage agent does not get blindsided by
a merge-conflict surprise.*

P1 / P2 findings: none surfaced.

**Findings:** none.

---

**Gate (2026-06-10 iter-1):** 6/6 PASS, feasibility 0 P0. Proceeding to planning.
