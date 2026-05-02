---
linear: ENG-60
title: Pipeline vocabulary simplification — collapse markers, sigs, labels, and decision verbs into one closed event taxonomy
date: 2026-05-02
status: draft
---

# Pipeline vocabulary simplification

## 1. Context

The harness vocabulary has compounded across ten ENG tickets (ENG-18, ENG-23,
ENG-26, ENG-41, ENG-45, ENG-49, ENG-50, ENG-54, ENG-56, ENG-57). Every increment
was correct in isolation, but the cumulative surface is now unreadable for
anyone not already in the operator's head:

- 9 distinct `pipeline-X` HTML-comment shapes, only 5 of which drive state — yet
  all share the `pipeline-` prefix and identical syntax. ENG-47 Track C and
  ENG-57 are both bugs caused by agents/operators confusing `pipeline-sig` (a
  dedup key, not a verdict) with verdict markers.
- Two label namespaces (`stage:*` and `pipeline:*`) with overlapping semantics
  (`pipeline:halted` vs `pipeline:skip-until-human-acts` vs `pipeline:paused` —
  three labels for one concept).
- Open-ended reason-token vocabulary: `agent-blocked`, `protocol-violation`,
  `smoke-failed`, `iteration-exhausted`, `pr-opened-too-early`, … — no central
  registry; each addition is invisible.
- Stage-name tense drift across prompts (verb), labels (gerund), markers
  (gerund), CLI args (verb), function names (mixed).
- Operator decision verbs mix scope-specific (`scope-approved`/`scope-rejected`)
  with generic (`resume`); not extensible to other gates.

The trigger for this work is open-source readiness: a new reader should grasp
the protocol from one canonical glossary page, not by spelunking through
`bin/run-stage.sh` and `bin/verdict-handler.sh`.

## 2. Goals (priority order)

1. **New-reader comprehensibility.** A new contributor should learn the protocol
   from one page.
2. **Agent/operator footgun reduction.** Narrow, closed enums with visual
   distinction between state-driving and bookkeeping comments. The recent
   ENG-47/56/57 bugs were all vocabulary-confusion bugs.
3. **Operator memorability for day-to-day use.** Short CLI verbs, consistent
   tense, fewer labels to track.

These mostly point in the same direction, but they tilt a few choices: (1) wants
verbose readable shapes, (2) wants narrow closed enums, (3) wants short CLI
verbs. Where they conflict, the priority order resolves it.

## 3. Non-goals

- Reducing the **number of state combinations** (verdict result types, halt
  reasons, etc.) below what's currently expressible. This work is syntax/
  semantics simplification, not feature reduction.
- Reverting any orchestrator-correctness work from ENG-41 / ENG-56 (label
  authority, lane fences). Both are preserved.
- Building the full **FSM-interpreter design** (Level 3 from the brainstorming
  triage). This work lands the closed event registry that a future Level 3
  effort would consume, but does not implement an interpreter.
- Touching `verdict-<stage>.json` dimensional grading (ENG-31) — orthogonal
  payload schema.
- Touching the `pipeline:rule-reviewed` retrospective approval gate —
  orthogonal.
- Backwards-compatibility shim beyond one release.

## 4. Inventory of current vocabulary

### 4.1 Marker shapes (HTML comments inside Linear comment bodies)

| # | Shape | Writer | Drives state? | Notes |
|---|---|---|---|---|
| 1 | `pipeline-transition: <from> → <to>` | orchestrator | yes | freshness boundary every other read uses |
| 2 | `pipeline-stage-summary: <stage>` | agent | yes (verdict) | "I finished cleanly" |
| 3 | `pipeline-rejection: <target-stage>` | agent | yes (verdict) | "loop back" |
| 4 | `pipeline-halt: <reason>` | agent | yes (verdict) | "stop, human action" |
| 5 | `pipeline-wait: <reason>` | agent (build only) | yes (verdict) | "soft pause" |
| 6 | `pipeline-decision: <scope-approved\|scope-rejected\|resume>` | operator | yes (override) | not a verdict |
| 7 | `pipeline-pivot: <stage>` | agent (proposed ENG-35, not built) | yes (would be) | "plan is wrong" |
| 8 | `pipeline-sig: <ns/stage/issue>` | any | **no** | dedup key for `linear.sh add-or-update-comment` |
| 9 | `pipeline-metric: <name>` | scripts | **no** | observability counter |

### 4.2 Labels (Linear)

- **Stage** (one always present): `stage:brainstorming` · `stage:planning` ·
  `stage:implementing` · `stage:ui` · `stage:reviewing` · `stage:qa` ·
  `stage:building` · `stage:released`
- **Pipeline** (zero or more): `pipeline:halted` · `pipeline:supersede` ·
  `pipeline:skip-until-code-changes` · `pipeline:skip-until-human-acts` ·
  `pipeline:abandoned` · `pipeline:scope-approval-needed` (legacy) ·
  `pipeline:paused` (legacy) · `pipeline:rule-reviewed`

### 4.3 Sig namespaces (open-ended payload of marker #8)

- `completion/<stage>/<issue>`
- `halt/<stage>/<issue>`
- `scope-approval/<stage>/<issue>`
- `tdd-evidence/<stage>/<issue>`
- (open)

### 4.4 State files (per-issue, `$issue_dir/`)

- `issue-state.json` — durable skip-label dance state
- `wait-{stage}.json` — soft-pause budget (ENG-45)
- `stage-summary-<stage>.md` — per-stage exit verdict file
- `verdict-<stage>.json` (proposed ENG-31) — dimensional grading

### 4.5 Operator CLI

- `bin/halt.sh resolve ENG-N --decision <scope-approved|scope-rejected|resume>`
- `bin/post-verdict.sh ENG-N <stage-summary|rejection|halt> <stage> [reason]`

## 5. Confusion sources (ranked by expected impact)

1. **`pipeline-sig` looks like a verdict but isn't.** Same prefix, same syntax,
   different meaning. Root cause of ENG-47 Track C and ENG-57.
2. **Marker + label dual-write.** Every state change requires the agent to post
   a marker AND the orchestrator to apply a label. Two paths, two reads, drift
   opportunities (ENG-47 / ENG-56 fixed instances).
3. **"Stop" vocabulary explosion.** halt vs wait vs skip-until-code-changes vs
   skip-until-human-acts vs abandoned vs paused vs supersede. Subtle
   distinctions, easy to mix up.
4. **Decision verbs mix scope and intent.** `scope-approved`/`scope-rejected`
   are gate-specific; `resume` is generic; no symmetric "approve to continue"
   verb for other gates.
5. **Stage-name tense drift** across prompts, labels, markers, CLI args.
6. **Reason-token vocabulary is open.** No central registry; each addition is
   invisible to reviewers.
7. **Pivot vs rejection vs halt vs wait** (ENG-35 proposal) — overlapping
   semantics that are hard to keep distinct.

## 6. Approach: Level 2 simplification

The brainstorming triage produced three ambition levels:

- **Level 1** — rename and document only. Cheap (~1–2 days), modest relief
  (~40%). Doesn't actually reduce complexity.
- **Level 2** — collapse to fewer primitives. ~1 week + soak, 70–80% relief.
  Reduces complexity without rewriting the orchestrator.
- **Level 3** — ground-up FSM redesign. ~2–3 weeks + meaningful migration,
  >90% relief, but introduces FSM-design discipline as new cognitive cost.

**Decision: Level 2.** Reasons:

- The user does not yet have a strong FSM design in their head. Trying Level 3
  cold would burn the budget on FSM design rather than on reading-clarity wins.
- The closed event registry produced by Level 2 is the data model a future
  Level 3 interpreter would consume — Level 2 is therefore a strict prerequisite
  for Level 3, not a competing path.

## 7. Design

### 7.1 Two visually distinct comment families

Today's nine `pipeline-X` shapes collapse to two prefixes:

```
<!-- pipeline: <event-name> [key=value ...] -->     ← state-driving
<!-- meta: <kind> [key=value ...] -->               ← bookkeeping (not state)
```

The `pipeline:` vs `meta:` split is the load-bearing change. A reader (or
agent) can answer "does this drive state?" in one glance — solving confusion
source #1.

### 7.2 The closed event set under `pipeline:`

| Event | Writer (lane) | Replaces |
|---|---|---|
| `transition stage=<from>→<to>` | orchestrator (`PIPELINE_WRITER=orchestrator`) | `pipeline-transition` |
| `verdict result=pass stage=<stage>` | agent (`PIPELINE_WRITER=agent`) | `pipeline-stage-summary` |
| `verdict result=fail target=<stage>` | agent | `pipeline-rejection` |
| `verdict result=halt reason=<token>` | agent | `pipeline-halt` |
| `verdict result=wait reason=<token>` | agent | `pipeline-wait` |
| `verdict result=pivot target=<stage>` | agent | (slot reserved; ENG-35 deferred) |
| `decision action=continue` | operator (`PIPELINE_WRITER=human`) | `pipeline-decision: resume` |
| `decision action=approve gate=<gate>` | operator | `pipeline-decision: scope-approved` |
| `decision action=abandon gate=<gate>` | operator | `pipeline-decision: scope-rejected` |

Rationale for keeping `decision` as an umbrella event (parallel to `verdict`):

- Symmetry — both events take `action`/`result` + named modifiers.
- The umbrella reads as "operator's action on the system," matching how a new
  reader maps the event to a workflow role.
- Extensible to future operator actions without inventing top-level events.

**Implicit fields.** A `verdict result=fail target=...` does not carry a
`stage=` field — the source stage is the issue's current `stage:*` label
(orchestrator-canonical per ENG-56). Same convention as today's
`pipeline-rejection`. A `verdict result=halt` likewise omits stage; the latest
`pipeline-transition` defines the stage at which the halt occurred.

#### 7.2.1 Worked example: `verdict` followed by `decision`

A complete operator-intervention loop in the new vocabulary:

1. Implement agent finishes its commits and posts:
   ```
   <!-- pipeline: verdict result=pass stage=implementing -->
   ```
2. Orchestrator runs scope-check → SEVERE violation. Applies `pipeline:halted`.
3. Operator inspects the diff, judges the touches intentional, runs:
   ```
   bin/pipeline decide ENG-N --action approve --gate scope
   ```
   Which posts:
   ```
   <!-- pipeline: decision action=approve gate=scope -->
   ```
4. Next tick, scope-check reads the decision marker, returns 0 from
   `has-scope-approval`, dispatch proceeds to the next stage.

The `decision` event is **not** a verdict — there is no work to issue a
verdict on. It is an override of a downstream gate (scope-check). Conflating
the two would require relaxing ENG-41's lane fences and would break the
calibration shape's (ENG-39) ability to find divergence between agent
verdicts and human overrides.

### 7.3 The closed `meta:` set (bookkeeping)

| Kind | Replaces |
|---|---|
| `meta: dedup key=<ns/stage/issue>` | `pipeline-sig` |
| `meta: metric name=<name>` | `pipeline-metric` |
| `meta: evidence kind=<tdd-evidence\|...> stage=<stage>` | sig-namespaced bodies like `tdd-evidence/implement/ENG-N` |

Same combinations as today, but the family prefix removes the
visual-collision footgun.

`meta:` markers can appear anywhere in the comment body (same convention as
today's `pipeline-sig`). The verdict-handler scans by prefix; position within
the body is irrelevant.

### 7.4 Closed registry for reasons, results, verbs, gates

New file: `bin/pipeline-events.json` — single source of truth.

```json
{
  "verdict_results": ["pass", "fail", "halt", "wait", "pivot"],
  "halt_reasons": [
    "agent-blocked",
    "smoke-failed",
    "iteration-exhausted",
    "scope-violation",
    "protocol-violation",
    "dispatch-timeout",
    "pr-opened-too-early"
  ],
  "wait_reasons": ["awaiting-approval", "awaiting-ci"],
  "fail_targets": ["brainstorming", "planning", "implementing", "ui"],
  "pivot_targets": ["planning"],
  "decision_actions": ["continue", "approve", "abandon"],
  "decision_gates": ["scope", "build-cap"],
  "stages": [
    "brainstorming", "planning", "implementing", "ui",
    "reviewing", "qa", "building", "released"
  ]
}
```

Marker writers (`bin/post-verdict.sh`, `bin/halt.sh`, `bin/pipeline.sh`, etc.)
**validate against this registry and die loudly on unknown tokens.** Adding a
new reason becomes one PR that updates the registry — visible in code review,
can't sneak in via prompt drift. Solves confusion source #6.

### 7.5 Labels reduced to a closed enum

**Stage labels** stay 1:1 with the `stages` registry, gerund tense, applied
exclusively by the orchestrator (preserves ENG-56 invariant).

**Pipeline-namespace labels** reduce to two:

| Keep | Why |
|---|---|
| `pipeline:halted` | "blocked, human action required." Covers today's `halted` + `skip-until-human-acts` + `paused` + `scope-approval-needed`. The latest `pipeline: verdict` marker carries the discriminating reason. |
| `pipeline:abandoned` | terminal abandonment. |

| Drop | Where its job goes |
|---|---|
| `pipeline:supersede` | folds into `verdict result=fail` semantics. |
| `pipeline:skip-until-code-changes` | becomes a fingerprint field in `issue-state.json`; the label was redundant. |
| `pipeline:skip-until-human-acts` | folded into `pipeline:halted`. |
| `pipeline:scope-approval-needed` | legacy; folded into `pipeline:halted` + `verdict result=halt reason=scope-violation`. |
| `pipeline:paused` | legacy; same as above. |
| `pipeline:rule-reviewed` | retrospective concern, **kept as-is**, documented as orthogonal. |

Solves confusion source #3 and most of #2.

**Acknowledged tradeoff:** folding `skip-until-human-acts` into `halted`
removes a label-only signal that's currently visible at the Linear UI level.
The new way to discriminate "general halt" from "scope-violation halt" is to
read the latest `pipeline: verdict` marker. Accepted by the operator.

### 7.6 Single operator CLI

One entry point replaces `halt.sh`, `post-verdict.sh`, `scope-check.sh`
(operator-facing subcommand only — its post-stage gate role stays):

```
bin/pipeline status <issue>                                   # read-only summary
bin/pipeline event <issue> verdict <pass|fail|halt|wait|pivot> [args]
bin/pipeline event <issue> transition <from→to>               # orchestrator-internal
bin/pipeline decide <issue> --action <continue|approve|abandon> [--gate <gate>]
```

Old → new mapping:

| Old | New |
|---|---|
| `halt.sh resolve ENG-N --decision scope-approved` | `bin/pipeline decide ENG-N --action approve --gate scope` |
| `halt.sh resolve ENG-N --decision scope-rejected` | `bin/pipeline decide ENG-N --action abandon --gate scope` |
| `halt.sh resolve ENG-N --decision resume` | `bin/pipeline decide ENG-N --action continue` |
| `post-verdict.sh ENG-N stage-summary implement` | `bin/pipeline event ENG-N verdict pass --stage implementing` |
| `post-verdict.sh ENG-N rejection planning` | `bin/pipeline event ENG-N verdict fail --target planning` |
| `post-verdict.sh ENG-N halt agent-blocked` | `bin/pipeline event ENG-N verdict halt --reason agent-blocked` |

Old binaries become **thin wrappers** for one release cycle, each emitting a
deprecation log line on use. Removed at end of phase 3. Solves confusion
sources #4 and contributes to #2.

### 7.7 Stage-name tense: gerund everywhere

All five surfaces (prompts, labels, markers, CLI args, function names) align
on the gerund form: `brainstorming`, `planning`, `implementing`, `ui`,
`reviewing`, `qa`, `building`, `released`.

- Prompt section headers update: "§1. Brainstorm Agent" → "§1. Brainstorming
  Agent".
- CLI accepts gerund (`bin/pipeline event ENG-5 verdict pass --stage
  brainstorming`); a one-release alias accepts the verb form
  (`brainstorm` → `brainstorming`) with a deprecation log line.
- Function names in `bin/*.sh` are renamed in the same PR as the
  prompt-header update — see Q2 in §10 for the cost/scope tradeoff.

Solves confusion source #5.

### 7.8 Single canonical glossary page

`docs/pipeline-vocabulary.md` becomes the single source of truth. Generated
from `bin/pipeline-events.json` for the registry-derived sections (so it
cannot drift). Hand-written sections cover:

- The two-family split (`pipeline:` vs `meta:`).
- Worked examples for each `verdict` and `decision` shape.
- Migration notes (during phases 1–2 only).

`CLAUDE.md` removes inline vocabulary explanations and links to the glossary
instead. `AGENT_PROMPTS.md`'s "Verdict-marker protocol" preamble is replaced
by a short link to the glossary plus a one-paragraph reminder of the key
rules (latest-after-transition, lane fences).

### 7.9 Migration phases

Three phases, each its own PR, each reversible:

1. **Read both** (~1–2 days)
   - Marker parsers in `bin/verdict-handler.sh`, `bin/scope-check.sh`,
     `bin/run-stage.sh`, etc. accept old AND new shapes.
   - No agent or operator changes.
   - `bin/pipeline-events.json` lands; nothing yet validates against it.
   - Tests added for parser equivalence.

2. **Write new** (~2–3 days + 1 week soak)
   - `bin/pipeline.sh` lands as the canonical writer.
   - `bin/halt.sh` and `bin/post-verdict.sh` become deprecation-logging
     wrappers.
   - Agent prompts in `AGENT_PROMPTS.md` updated to emit new shapes.
   - Stage-name gerund alignment lands in the same PR.
   - In-flight issues drain naturally.
   - Pipeline-namespace label cleanup happens issue-by-issue as each
     completes (do not bulk-rename mid-flight). Specifically: when the
     orchestrator next applies a label to an issue, it removes any legacy
     pipeline-namespace label (`paused`, `scope-approval-needed`, `supersede`,
     `skip-until-code-changes`, `skip-until-human-acts`) in the same
     `linear.sh remove-label` call.

3. **Drop old** (~1 day)
   - Remove old-shape readers.
   - Delete `bin/halt.sh`, `bin/post-verdict.sh` wrappers.
   - Remove legacy labels from Linear via `bin/linear.sh delete-label`
     (one-time admin script).
   - Remove the deprecation log lines.

Total: ~5–6 work days + 1 week soak. No flag day.

## 8. Acceptance criteria

1. Every state-driving comment in new code uses `<!-- pipeline: <event> ... -->`.
2. Every bookkeeping comment uses `<!-- meta: <kind> ... -->`.
3. `bin/pipeline-events.json` exists; all marker writers validate against it
   and die on unknown tokens; `bin/dispatch-test.sh` (or equivalent) asserts
   the validation fires.
4. Pipeline-namespace labels reduced to `{halted, abandoned, rule-reviewed}`;
   legacy labels removed from Linear at end of phase 3.
5. Stage names use gerund tense in prompts, labels, markers, CLI; one-release
   alias preserved.
6. `docs/pipeline-vocabulary.md` exists; `CLAUDE.md`'s vocabulary sections
   link to it; `AGENT_PROMPTS.md`'s verdict-marker preamble is short and
   links out.
7. `bin/pipeline` CLI replaces `bin/halt.sh` and `bin/post-verdict.sh`; old
   binaries removed at end of phase 3.
8. All `bin/*-test.sh` tests pass with the new vocabulary; new fixtures cover
   the read-both-write-new transition and the registry validation.
9. No regression in ENG-41 lane fences or ENG-56 orchestrator-canonical-
   halted-applier behavior.

## 9. Rejected alternatives

### 9.1 Collapse `decision` into `verdict`

Operator posts `verdict result=pass stage=implementing` to mean "approve and
continue."

**Rejected.** Loses authorship signal, requires relaxing ENG-41 lane fences,
breaks the calibration shape's (ENG-39) ability to find divergence between
agent verdicts and human overrides.

### 9.2 Drop `decision` entirely; use labels for operator intent

Operator removes `pipeline:halted` to mean "resume," adds
`pipeline:scope-approved` to mean "approve scope."

**Rejected.** This is exactly how the harness worked before ENG-41/ENG-56 —
and it's what created the bugs (`save_issue` strips labels, label authority
is ambiguous, no audit comment). Reverting would undo a year of correctness
work.

### 9.3 Flatten `decision` into top-level events (`continue`, `approve gate=X`, `abandon gate=X`)

Per the brainstorming triage's "Option 2."

**Rejected.** Loses symmetry with `verdict`. Each shape would be
self-explanatory at first read, but the umbrella `decision` makes the
event-set table easier to scan as a closed set, and matches the
agent-vs-operator role split.

### 9.4 Move `meta-sig` to a Linear comment metadata field

Linear's API may support comment metadata fields that the dedup mechanism
could use, eliminating the need for `<!-- meta: dedup ... -->` in the comment
body.

**Deferred** (not rejected). Requires verifying Linear API surface and
back-compat behavior of `linear.sh::add-or-update-comment`. If the API
supports it cleanly, this is a future micro-simplification — file as a
follow-up after this work lands.

### 9.5 Positional syntax: `<!-- pipeline: verdict pass implementing -->`

Terser than `<!-- pipeline: verdict result=pass stage=implementing -->`.

**Rejected.** Goal #1 (new-reader comprehensibility) wins over Goal #3
(operator memorability). Key=value reads as self-documenting; positional
requires the reader to know the schema. The 20 extra characters are cheap.

### 9.6 Level 1 (rename only)

**Rejected.** Doesn't actually reduce complexity. Cumulative friction stays;
new readers still have to learn 9 shapes and 8 labels.

### 9.7 Level 3 (FSM interpreter)

**Deferred** (not rejected). Strict superset of Level 2. The closed event
registry from this work is a prerequisite for Level 3, so doing Level 2 now
makes future Level 3 cheaper.

## 10. Open questions

- **Q1 — `meta:` prefix collision risk.** Does any existing harness comment
  body legitimately start with `<!-- meta: ` for a non-harness reason (e.g.,
  pasted from external tooling)? Survey to do during phase 1 implementation:
  grep all Linear comments via `bin/linear.sh get-comments`.
- **Q2 — Stage-name change blast radius.** Updating function names (`run_stage`,
  `_dispatch_implement`, etc.) touches a lot of code. Is the gerund
  consistency worth a sweeping rename, or is the CLI-and-marker alignment
  sufficient and we leave function names as-is? **Provisional answer:** rename
  in the same PR as prompt headers; the cost is mechanical and the win is
  full consistency. Revisit if the rename PR balloons.
- **Q3 — `pipeline:rule-reviewed` keep-as-is.** Confirm with the operator
  that this label's semantics (retrospective rule approval) are unaffected
  by the pipeline-namespace cleanup. **Provisional answer:** yes, it's
  orthogonal — file as an explicit `## 11.` note.

## 11. Dependencies and orthogonal work

- **ENG-31 (dimensional grading)** — orthogonal. `verdict-<stage>.json` is a
  payload schema, not a marker shape. This work touches markers; ENG-31
  touches scoring. They land independently.
- **ENG-35 (pipeline-pivot)** — slot reserved in the registry; agent-side
  implementation deferred. ENG-35 picks up the deferred agent work after this
  lands.
- **ENG-58 (atomic halt resolve)** — depends on the new `pipeline: decision`
  shape. Re-scope ENG-58 to use the new vocabulary if this lands first.
- **ENG-59 (scope-check origin/main)** — orthogonal. No vocabulary
  interaction.
- **`pipeline:rule-reviewed`** — kept as-is; orthogonal to this work.

## 12. Migration guide for in-flight tooling

- Operators continue running `bin/halt.sh` and `bin/post-verdict.sh` during
  phases 1–2; they keep working via the wrapper shims.
- Agents see updated prompt language at phase-2 deploy time; they'll start
  emitting new shapes immediately.
- Existing in-flight Linear comments are NOT rewritten. The parser handles
  both shapes throughout phases 1–2.
- Legacy labels on existing issues are NOT bulk-removed. They're cleaned up
  during phase 3's one-time admin script, after no in-flight issue still
  references them.
