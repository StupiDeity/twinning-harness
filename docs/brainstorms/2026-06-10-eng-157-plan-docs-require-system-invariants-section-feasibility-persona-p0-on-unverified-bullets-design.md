---
linear: ENG-157
title: Plan docs — require `## System invariants` section + feasibility-persona P0 on unverified bullets
date: 2026-06-10
status: draft
---

# ENG-157 — Plan docs: require `## System invariants` section + feasibility persona P0 on unverified bullets

## 1. Overview (and the load-bearing surprise)

Six prior progress.md fixes (ENG-106, ENG-108, ENG-109, ENG-144, ENG-146,
plus ENG-155's `--add-dir` thread) each tightened the *agent's discipline*
around writing the per-issue progress notebook. None of them named the
runtime invariant that those fixes silently depended on:

> "The agent's tool universe (claude's per-session directory sandbox)
> must reach `$PROJECT_STATE_DIR/<slug>/<issue>/` so its `Edit` and
> `Write` calls against `progress.md` actually land on disk."

The invariant lived as tribal knowledge — implicit in the
`{progress_md_path}` prompt token, the orchestrator's pre-touch via
`_ensure_progress_md` (`bin/run-stage.sh:944-986`), and the detective at
`_assert_progress_md_entry` (`bin/dispatch.sh:358-...`) — but it was
never named in any *plan*. ENG-125 (planning, 2026-05-18) was the first
hard halt of the class, and even then the diagnosis required reading
the claude CLI changelog and the dispatch transcript side-by-side. The
fix in ENG-155 (added `--add-dir "$issue_state_dir"` to the `claude -p`
argv) landed only after that triage — three weeks of quieter denial
forms had been visible in failed-dispatch transcripts beforehand.

Today's planning success metric is "5 personas PASS, 0 P0" (see
`AGENT_PROMPTS.md:603-624`). The five personas review the **document**
(does the plan tell a coherent story, does the design respect crate
boundaries, do the tasks match the brainstorm, do the code-level facts
verify against current code) — they do not review the **runtime
contract** the plan implicitly depends on. The gap is structural: there
is no plan-time gate for "the assumptions this plan depends on are
themselves verified — either by an existing test, or by a task in this
very plan that adds one."

ENG-157 closes that gap by introducing one new doc section (`## System
invariants`) the plan agent MUST emit, one new validator pass in the
existing post-dispatch `plan-contract-invalid` detective, and one new
P0 finding in the existing feasibility persona's self-review sweep.
**No new persona, no new halt reason, no new exit code, no new
orchestrator hook.** The shape is the smallest possible extension of
existing precedent (ENG-122's plan-contract validator, ENG-135's add-side
test-gate-closure sweep) — that's the design constraint that makes the
ticket dispatchable as a one-shot rather than as an umbrella.

## 2. Forensic ground truth — the ENG-125 acceptance check

The Linear issue's AC#4 names a hard predicate:

> "The ENG-125-class invariant (`agent must be able to Edit
> {progress_md_path} under claude's sandbox`) would be caught by
> feasibility if named in a plan today."

What would the bullet have looked like in an ENG-125-era plan, and how
would feasibility have flagged it?

Hypothetical ENG-125 plan's `## System invariants` section:

```markdown
## System invariants

- The dispatched agent's `Edit` and `Write` tools can reach
  `$(progress_md_path <ident>)`, which lives under
  `$PROJECT_STATE_DIR/<slug>/<ident>/` outside the per-issue worktree
  cwd. `verified_by: task:T2`
```

Feasibility's resolution sweep would have walked the plan, found
no `### Task 2` whose `touches:` field included any of:

* `bin/dispatch.sh` (the `claude -p` argv composition site)
* `bin/run-stage.sh` (the pre-touch site)
* a sandbox-widening test

…and emitted: **"P0 — `verified_by: task:T2` references a task that
does not exist in this plan. The bullet names a runtime invariant
with no verifying owner."** The plan agent would then have had to
either add the task (which is exactly what ENG-155 eventually did) or
cite an existing test that pins the invariant (in 2026-05-18 there
wasn't one — the invariant had no test, which is the load-bearing
admission).

That hypothetical replay is the gate this ticket installs.

## 3. Scope (verbatim from the Linear issue, with structural callouts)

**IN:**

1. `AGENT_PROMPTS.md` §2 (Plan Agent) — extend the Completion checklist
   directive to require a `## System invariants` H2 section. Each
   bullet names an assumption the plan depends on AND includes a
   `verified_by:` field pointing at either an existing test
   (`<path>:<test-name>`) or a step in this plan that adds one
   (`task:T<N>`).
2. `bin/plan-schema.sh` — extend to require the section, ≥1 bullet,
   and a parseable `verified_by:` per bullet. (See §4.2 for the
   structural call: today's `plan-schema.sh` validates the *JSON*
   sibling; the System invariants section lives in the *markdown* plan.
   The extension takes a deliberate sub-command split rather than
   overloading `cmd_validate`.)
3. Feasibility-persona P0 list — extend so that any bullet whose
   `verified_by:` doesn't *resolve* to a real test or in-plan task
   is P0.
4. One INT test in `bin/run-stage-test.sh` exercising a plan missing
   the section → halt with `plan-contract-invalid`.

**OUT** (explicit carve-outs from the ticket body):

- Brainstorm-stage equivalent of this section — leave for a follow-up
  ticket once this beds in. The brainstorm carries `Assumption
  inventory` already (`AGENT_PROMPTS.md:278-289`) but does not require
  a `verified_by:` discipline; mirroring that to a 6-persona plan-time
  gate is a separate scope (different failure mode — brainstorms can
  document hypothetical invariants the plan will then implement).
- Adding more personas. Keep the count at 5; the new check is one more
  finding under the existing **feasibility** persona's self-review
  sweep, not a new persona.

**Flagged additions caught during brainstorm — surfaced, not silently
expanded:**

- Whether the new `## System invariants` section also belongs in the
  *.json* schema-v1 contract (e.g. as a top-level `system_invariants[]`
  array of `{ assumption, verified_by }` records). Tentatively NO (see
  D-002) — the section is human-authored prose with a one-line `verified_by:`
  token; embedding it in JSON would force the plan agent to render the
  same content twice and break the "JSON is for machine readers, MD is
  for human readers" split that ENG-122 deliberately established.
- Whether `verified_by: docs-only` (sentinel for plans that introduce
  no new runtime invariants) should be a permitted token. See §6
  Edge Cases — needs an explicit OQ resolution.

## 4. Decisions

### D-001 — Section name, bullet shape, `verified_by:` token grammar

The new section is a single H2 with the exact heading
`## System invariants` (lowercase `i` to match the Linear scope text;
this is load-bearing — the validator pins the exact string). Body:
one or more markdown bullets (`- ...`); each bullet MUST contain a
`verified_by:` token followed by either:

* `<path>:<test-name>` — a path relative to the repo root and a
  test name (function name or test-block label) the validator/feasibility
  expects to find by literal `grep -F` inside that file, OR
* `task:T<N>` — a reference to an H3 task heading inside this same
  plan markdown (e.g. `### Task 5:`), where `<N>` is the task number.

Grammar (validator-facing, regex-equivalent):

```
verified_by:\s*(<path>:<test-name>|task:T[0-9]+)
```

The token MAY appear anywhere in the bullet body (start, middle,
trailing parenthetical) — only its lexical presence + parseability is
asserted by the validator. The validator's job stops at "is the bullet
well-formed?" — *resolution* (does the cited test or task actually
exist?) is the feasibility persona's job (D-005 below).

*Rationale:* The two-track grammar mirrors the two-track audience for
plan-time runtime invariants:

* `<path>:<test-name>` — when the invariant is already covered by a
  test, the plan is asserting "I checked; here's the existing
  guarantor."
* `task:T<N>` — when the invariant is *new* to this plan (no existing
  test), the plan must own the addition; the in-plan task is the
  guarantor.

The split closes the gap the Linear context names: six prior
progress.md tickets *had* invariants that no test pinned, but no plan
ever named the invariant explicitly, so no persona could ask "where's
the test?"

*References to constraint:* CLAUDE.md "Don't add features, refactor,
or introduce abstractions beyond what the task requires" — the
two-token grammar is the minimum that distinguishes "existing
guarantor" from "in-plan task adds the guarantor." A single-token
grammar (e.g. always `task:T<N>`, requiring even existing-test
invariants to wrap a no-op task) would force gratuitous tasks; a
free-form `verified_by:` (string only, no grammar) would make
feasibility's resolution sweep unprogrammable.

**Rejected alternative — require a multi-line YAML block per bullet
(`- invariant: ...; verified_by: ...; severity: ...; owner: ...`).**
Rejected because it imports YAML parsing into a markdown-prose
validator (jq-only today); breaks the
`- <prose statement with verified_by: <token>>` shape that operators
can write inline; over-engineers for a feature whose only two
load-bearing fields are the prose statement and the verifier reference.

**Rejected alternative — require a separate `### Verified by:` H3
under each invariant.** Rejected because it doubles the section's
vertical footprint, breaks list-as-a-table-of-contents skimmability,
and is structurally indistinguishable from "task with a single
checklist item" — which is the shape we're trying to keep separate.

### D-002 — Validator lives in `bin/plan-schema.sh` as a NEW sub-command (`validate-md`), not as an extension to existing `validate`

The Linear scope text says "`bin/plan-schema.sh` extends to require
the section." Today's `bin/plan-schema.sh:60-283` defines
`cmd_validate <file>` which validates JSON (the sibling `.json`
contract emitted alongside the plan markdown). The new check operates
on the *markdown* doc — same artifact pair, different file format,
different parsing surface.

Two implementation shapes:

1. **(Chosen)** Add `cmd_validate_md <file>` as a *sibling sub-command*.
   `bin/plan-schema.sh validate-md docs/plans/<basename>.md` returns
   `0 | 33 | 34 | 35` with the same exit-code taxonomy as `validate`.
   `_validate_plan_contract` in `bin/run-stage.sh:1074-1110` drives
   both validations sequentially; failure of either routes through
   the existing `_post_plan_contract_halt` (`bin/run-stage.sh:1115-1122`).

2. **(Rejected)** Overload `cmd_validate` to dispatch on file
   extension. Rejected because (a) the existing JSON entry-point has
   well-tested invariants (`bin/plan-schema-test.sh` +
   `bin/plan-schema-adversarial-test.sh` pin ~50+ assertions against
   it) — adding a markdown branch risks regressing them; (b) the
   markdown validator's defect tokens (`plan-md-incomplete:`,
   `plan-md-malformed:`) are semantically distinct from the JSON
   ones — separate sub-commands make the diagnostic strings
   unambiguous; (c) the unit-test surface for `validate-md` is a
   clean new test group rather than a fork inside the existing
   `T_*` suite.

*Reused tokens (no new vocabulary added):*

* Halt reason: `plan-contract-invalid` (already registered at
  `bin/pipeline-events.json:20`).
* Exit codes: rc=33 (malformed — section heading present but bullets
  malformed), rc=34 (incomplete — section missing OR bullet count = 0
  OR `verified_by:` absent on some bullet), rc=35 (missing-file —
  symmetry with JSON-validator; defensive).
* Halt comment template: `_post_plan_contract_halt`'s existing
  printf — the `Defect:` field carries `plan-md-incomplete:` /
  `plan-md-malformed:` strings emitted by `cmd_validate_md`.

*References to constraint:* CLAUDE.md "Per-stage allowed tool lists
are centralized in `dispatch.sh::allowed_tools_for`. New stages must
add a case there." — and by analogy, per-validator exit-code
discipline is centralized in `failure_outcome_for_exit` (`bin/common.sh`).
This decision reuses both surfaces without extending them.

**Rejected alternative — write a separate `bin/plan-md-schema.sh`.**
Rejected because (a) the validator lives next to the file it
validates by convention (both sit at `bin/plan-schema.sh`'s pairing
with `docs/plans/<basename>.{md,json}`), (b) introduces a second
helper with overlapping ownership (which validator does run-stage.sh
call first? when does only one run?), (c) the operator-facing
diagnostic at halt time gains nothing from the file split.

**Rejected alternative — move the validation to a post-render-prompt
detective that fires inside the agent's prompt rendering phase (analog
of `bin/render-prompt.sh::append_project_profile`'s "die loud on
malformed profile" — `bin/render-prompt.sh:184-200`).** Rejected
because (a) the plan-stage agent hasn't been dispatched yet at
prompt-render time; (b) the existing `_validate_plan_contract`
post-dispatch surface is the right architectural layer (mirrors
ENG-87's envelope validator); (c) ENG-122 deliberately chose
post-dispatch over pre-dispatch.

### D-003 — Defect taxonomy

Sub-command `cmd_validate_md` emits these diagnostics to stdout (the
caller `_validate_plan_contract` captures `$schema_out` and inlines
it into the halt comment via `_post_plan_contract_halt`):

| Condition | Exit code | Diagnostic |
|---|---|---|
| File argument missing | 33 | `plan-md-malformed: file argument required` |
| File does not exist | 35 | `plan-md-missing: file not found: <path>` |
| `## System invariants` heading absent | 34 | `plan-md-incomplete: required H2 section "## System invariants" missing` |
| Section heading present but body has zero `- ` bullets | 34 | `plan-md-incomplete: "## System invariants" section has 0 bullets (expected ≥1)` |
| Any bullet missing `verified_by:` token | 34 | `plan-md-incomplete: bullet N (1-indexed) lacks parseable "verified_by:" reference` |
| Token present but unparseable (neither `<path>:<test-name>` nor `task:T<N>`) | 33 | `plan-md-malformed: bullet N "verified_by: <token>" matches neither <path>:<test> nor task:T<N>` |
| All bullets well-formed | 0 | `plan-md-contract-valid: <path>` |

*Rationale for the split between 33 (malformed) and 34
(incomplete):* mirrors `bin/plan-schema.sh`'s existing taxonomy —
`malformed` means the validator could not parse the structure
(presence-of-data error), `incomplete` means the data was parseable
but a required field was missing or empty (absence-of-data error).
The split lets the operator reading the halt comment know whether to
fix a typo in a `verified_by:` token (rc=33, single-line edit) or
add a whole new bullet (rc=34, content addition).

### D-004 — Acceptance of the new section is a HARD halt (consistent with ENG-122 precedent)

The post-dispatch validator halts on absence/malformation rather than
emitting a warning. This is consistent with how ENG-122's JSON
validator behaves (`_validate_plan_contract` → exit 33/34/35 →
`classify_failure ... skip-until-human-acts` →
`pipeline:halted`). The operator-facing recovery path is the standard
single-command resume: `bash bin/pipeline.sh decide ENG-N --action
continue` after fixing the plan markdown.

*Rationale:* The Linear AC#2 ("`bin/plan-schema.sh validate` halts
on missing/malformed section with a clear operator-facing message") is
explicit. A softer signal (warn-only, or persona-only) would
reproduce the failure mode this ticket exists to prevent — the
feasibility persona can be wrong (ENG-122's brainstorm noted P2-level
persona lapses); a deterministic post-dispatch validator cannot.

### D-005 — Feasibility persona's resolution semantics

The feasibility persona's existing "Codebase-fact verification"
sweep (`AGENT_PROMPTS.md:556-572`) gains one new P0 row in the gate
list at `AGENT_PROMPTS.md:608-624`:

> **For every bullet in `## System invariants`:**
>
> * If `verified_by:` is `<path>:<test-name>`: open `<path>` and
>   verify `<test-name>` appears literally (a function definition,
>   test-block label, or grep-anchored assertion). Unresolved
>   reference → P0.
> * If `verified_by:` is `task:T<N>`: locate `### Task <N>:` in the
>   plan markdown. Verify the task's `touches:` field names at least
>   one file matching the project's gate-runnable glob (per the
>   project profile's "Build & test gates" Test command) — i.e., the
>   task adds a test that pins the invariant. Unresolved reference,
>   missing task, or task that touches no test file → P0.

*Why this lives in the persona and NOT in `cmd_validate_md`:* The
validator has access only to the markdown plan; it cannot read the
target files cited by `<path>:<test-name>` because those paths could
be anywhere in the repo (or even on different branches once the
plan rebases). The feasibility persona is the layer that runs inside
the agent's tool universe with Read/Grep against the whole tree —
that's the right resolution surface. The split is symmetric with
ENG-135's "test-gate closure" sweep (the validator doesn't grep
sibling test files either; feasibility does).

*Rejected alternative — implement the resolution in `cmd_validate_md`
too, walking the cited paths.* Rejected because (a) post-dispatch
validators in run-stage.sh have access only to the dispatched
worktree's state, not the agent's logical tool universe (e.g., a
`<path>` outside `docs/plans/` is valid in a bullet but might be a
not-yet-created file the plan adds — only the agent's running
context can disambiguate); (b) the persona-resolved P0 is exactly
the kind of "judgment under uncertainty" persona review exists for;
(c) the validator's deterministic structural check + persona's
resolution check is layered defense — validator catches lexical
defects always, persona catches semantic defects always; neither
masks the other.

### D-006 — Pin the §2 directive shape so a future edit cannot drift the gate

`bin/agent-prompts-content-test.sh` already pins several §2
load-bearing literals (see `bin/agent-prompts-content-test.sh:488-500`
for the ENG-135 precedent). This ticket adds one new pin assertion
to that test file:

```bash
# ENG-157: §2 carries System-invariants section directive
if printf '%s\n' "$s2" | grep -qF '## System invariants' && \
   printf '%s\n' "$s2" | grep -qF 'verified_by:'; then
  ok "§2 ENG-157: System-invariants directive present (heading + verified_by: token)"
else
  nope "§2 ENG-157: System-invariants directive present" \
       "literal '## System invariants' or 'verified_by:' missing from §2 — has the directive been deleted or relocated?"
fi
```

*Rationale:* Without the pin, a future retrospective-driven rewrite
of §2 could quietly remove the directive (e.g., merging the
System-invariants section into a generic "Assumption Inventory"
table), the gate goes quiet, and the failure mode this ticket fixes
silently re-opens. ENG-135's add-side sweep ran this exact playbook
(literal pin in the content test) and it caught one pre-merge typo.

## 5. Architecture (where code goes)

```
AGENT_PROMPTS.md §2 (Plan Agent)
├── Completion checklist (lines 600-665)
│   └── NEW: step 0.5 (between "Required sections" and "Codebase-fact
│       verification") — add `## System invariants` to the required-
│       sections enumeration at AGENT_PROMPTS.md:462-471
└── Self-review block (lines 554-597)
    └── NEW: feasibility persona's bullet list extended with
        System-invariants resolution rule (D-005)

bin/plan-schema.sh (extended)
├── EXISTING: cmd_validate <file>  (JSON validator, unchanged)
└── NEW:      cmd_validate_md <file>  (~80-120 LoC awk/grep)
    └── awk pass: find "## System invariants" H2 block; extract
        bullets; for each bullet, regex-match verified_by:<token>;
        emit defect strings to stdout; return rc 0/33/34/35

bin/run-stage.sh::_validate_plan_contract (lines 1074-1110)
└── EXTENDED: after the existing JSON validate call (which already
    handles plan_md absent), invoke `cmd_validate_md "$wt/$plan_md"`;
    on non-zero, route through the existing _post_plan_contract_halt
    with the new Defect token (plan-md-incomplete: ... etc).

bin/plan-schema-test.sh (extended)
└── NEW: test group "ENG-157 V1-V8" exercising cmd_validate_md
    against fixtures: valid one-bullet, valid multi-bullet,
    missing section, zero bullets, missing verified_by:,
    unparseable verified_by:, missing file, large fixture (≥50
    bullets — confirms awk pass doesn't degrade).

bin/run-stage-test.sh (extended)
└── NEW: test "ENG-157 INT6" — fixture worktree with a plan .md
    lacking the "## System invariants" section + a valid sibling .json;
    invoke _validate_plan_contract; assert rc=34, halt comment
    carries plan-contract-invalid marker, Defect: plan-md-incomplete: ...

bin/agent-prompts-content-test.sh (extended)
└── NEW: ENG-157 §2 content pin (D-006)
```

## 6. Data flow

```
                  ┌─────────────────────────────────┐
                  │ Plan agent dispatch (claude -p) │
                  └────────────┬────────────────────┘
                               ▼
                  Writes docs/plans/<basename>.md   (NEW: contains "## System invariants")
                  Writes docs/plans/<basename>.json (existing)
                               ▼
                  Self-review (5 personas in parallel + serial gate)
                               ▼
                  ┌─────────────────────────────────┐
                  │ feasibility persona:            │
                  │ - existing: codebase-fact + ... │
                  │ - NEW (D-005): resolve every    │
                  │   verified_by: reference        │
                  └────────────┬────────────────────┘
                               ▼ (PASS or P0 → loopback within the persona iteration loop)
                  Agent commits both artifacts on feature branch
                               ▼
                  Agent exits cleanly
                               ▼
                  ┌─────────────────────────────────┐
                  │ Orchestrator post-dispatch hook │
                  │ run-stage.sh::                  │
                  │   _validate_plan_contract       │
                  │     ├── validate .json (existing)│
                  │     └── NEW: validate-md        │
                  └────────────┬────────────────────┘
                               ▼
                  If EITHER validation fails:
                    _post_plan_contract_halt → Linear comment with
                    <!-- pipeline: verdict result=halt
                      reason=plan-contract-invalid -->
                    Defect: plan-md-incomplete: ... (or plan-md-malformed: ...)
                  Else: stage advances to implementing
```

## 7. Error handling & operator UX

### 7.1 Halt comment shape

`_post_plan_contract_halt` already emits a structured Linear comment
template (see `bin/run-stage.sh:1115-1122`). With the new defect
token strings (D-003), the comment body for a missing-section halt
reads:

```
<!-- pipeline: verdict result=halt reason=plan-contract-invalid -->

Plan-contract validation failed on dispatch_id=ENG-N-d0001 stage=planning:

- Defect: plan-md-incomplete: required H2 section "## System invariants" missing

~~~
(validator stdout — full diagnostic with bullet numbers)
~~~

Schema source-of-truth: see header comment in `bin/plan-schema.sh`.

**Resume:** fix the plan markdown (or the plan prompt's emission step), commit on the feature branch, then run `bash bin/pipeline.sh decide ENG-N --action continue`.
```

The string `plan-md-` (defect-token prefix) discriminates the new
markdown-side defects from the existing JSON-side ones (`Defect:
plan-contract-malformed`, `plan-contract-missing`,
`plan-contract-incomplete`) — operators reading the halt comment
know immediately which file to edit.

### 7.2 Sanitization

The halt comment body wraps validator stdout in a fenced block.
ENG-122 review-iter-2 added `<!--` → `<\!--` escaping to
`_post_plan_contract_halt` (`bin/run-stage.sh:1117`) to prevent
agent-controlled validator input (e.g., a malicious `issue_id`
containing a literal verdict marker) from hijacking the verdict
family. The same escaping covers the new defect strings since they
all flow through `_post_plan_contract_halt`'s existing `safe="${raw//<!--/<\\!--}"`
substitution — no new sanitization site needed.

### 7.3 Recovery path

Standard `bash bin/pipeline.sh decide ENG-N --action continue` (see
CLAUDE.md "What `--action continue` clears (atomic)"). The plan
markdown stays on the feature branch; the operator edits it locally,
amends or adds a commit, then runs the resume command. Next tick:
re-dispatch of planning stage → same `_validate_plan_contract` pass
→ if fixed, advance.

## 8. Edge cases & risks

### 8.1 "No new runtime invariants" plans (documentation-only changes)

**Concrete example:** This very ticket (ENG-157) is a meta change to
the plan stage; its plan's `## System invariants` section is
arguably "no new runtime invariants — the plan only edits markdown
and bash scripts in well-tested surfaces."

**Two paths to handle this:**

A. *Require a single sentinel bullet* —
   `- This plan introduces no new runtime invariants beyond those
   already pinned by the existing test suite. verified_by:
   bin/agent-prompts-content-test.sh:T_run_full`
   The bullet still has a `verified_by:` reference (to the gate that
   protects the surfaces being edited), so the validator passes
   trivially and the persona resolves it cheaply.

B. *Permit an explicit `none` token* —
   `verified_by: none (justification: docs-only change; no runtime
   contract introduced)`
   The validator's regex would accept `none` as a literal token; the
   persona would NOT P0 it (special-cased) but WOULD require a
   prose justification after the parenthesis.

**Choice (D-001 above):** Path A. Permitting `none` introduces a
soft path the agent can over-use (every plan becomes "no runtime
invariants" if the discipline isn't enforced). Path A keeps the
discipline 1:1 with a real test — even a docs-only plan must name
the test that pins its document surface. Op cost: one line of
boilerplate.

See **OQ-1** below for the explicit deferral if Path A turns out to
be too friction-heavy in practice.

### 8.2 Section heading typo

The validator pins the exact string `## System invariants`
(lowercase `i`, plural `invariants`). Reasonable typos:

* `## System Invariants` (capital I) → validator emits
  `plan-md-incomplete: required H2 section "## System invariants" missing`,
  halts. Operator's halt comment shows the *expected* string verbatim
  — the fix is obvious.
* `## System Invariant` (singular) → same path; same diagnostic.
* `### System invariants` (H3 instead of H2) → same path.
* `## system invariants` (lowercase S) → validator strict on
  exact-string match; halts.

The validator MUST emit the expected heading literally in the halt
diagnostic so the operator's edit is single-character.

### 8.3 Validator regex robustness

The `verified_by:` token grammar (D-001) is:

```
verified_by:\s*(<path>:<test-name>|task:T[0-9]+)
```

Edge inputs:

* `verified_by:bin/foo.sh:T_thing` (no whitespace) → match.
* `verified_by: bin/foo.sh:T_thing` (one space) → match.
* `verified_by:   bin/foo.sh:T_thing` (multiple spaces) → match.
* `verified_by: task:T05` (zero-padded) → match (`[0-9]+`).
* `verified_by: task:T` (no number) → no match → rc=33 malformed.
* `verified_by: bin/foo.sh` (path but no `:<test-name>`) → no match →
  rc=33.
* Two bullets, each with their own `verified_by:` → both checked.
* Bullet with two `verified_by:` tokens → match the FIRST; warn on
  the second (out of scope for v1; OQ).
* Bullet with `verified_by:` inside a code-fence (e.g., `verbatim
  example` quoted in the prose) → match (the validator doesn't
  parse fences). Acceptable noise (operator's responsibility to
  not write misleading prose).

### 8.4 Plan markdown lives in nested folders

`bin/plan-schema.sh::cmd_validate_md` takes the absolute path passed
in by `_validate_plan_contract`. The caller already resolves the
canonical path under `<worktree>/docs/plans/<basename>.md`
(`bin/run-stage.sh:1090`). No path-traversal handling needed beyond
the caller's existing `find docs/plans -maxdepth 1 -type f -iname ...`.

### 8.5 Multi-byte / unicode characters in bullets

`awk`'s default `[[:space:]]` matching handles ASCII whitespace.
Unicode-aware bullets (em-dashes, smart quotes, accented characters
in invariant prose) are fine — the validator only pattern-matches
the literal `## System invariants` heading and the `verified_by:`
token. The bullet body is opaque to it.

### 8.6 Race: agent edits plan.md after `_validate_plan_contract` reads it

Not possible — the validator runs *post-dispatch* (the agent's
`claude -p` process has exited). The worktree state is stable from
the validator's perspective.

### 8.7 Interaction with the JSON validator's existing call

`_validate_plan_contract` runs both validators sequentially. Failure
modes:

* JSON valid, MD invalid → halt with `plan-md-*` defect.
* JSON invalid, MD valid → halt with `plan-contract-*` defect
  (existing).
* Both invalid → halt with **first** failure (JSON, mirroring
  short-circuit). Document this in the validator's header comment so
  operators reading two consecutive halts on the same plan know to
  re-run after each fix.

*Rationale for short-circuit (not "validate both, emit combined
report"):* simpler implementation, matches existing single-defect
halt comment template, operator can iterate one defect at a time.

### 8.8 The system invariant bullet itself becomes the test (self-reference loop)

A plan could write a bullet like:

```
- The `cmd_validate_md` regex parses `verified_by:` correctly.
  verified_by: bin/plan-schema-test.sh:T_validate_md_token
```

That's the legitimate shape — the plan adds the test in Task N
and the bullet cites it. Feasibility resolves the task, finds the
file in `touches:`, confirms. No loop.

### 8.9 Plan-time vs implement-time divergence

A plan's `verified_by: task:T<N>` claim is *forward-looking* — the
test doesn't exist yet at plan-time; it gets added during implement.
What if implement drops the task (e.g., scope-reduces under loopback
pressure)?

**Out of scope for ENG-157.** The implement-stage agent already
follows the plan's task list verbatim; dropping a task is a
review-stage P0 by current convention. This ticket doesn't add a
new detective at implement-time. (Surface as Open Question OQ-3.)

## 9. Open questions

* **OQ-1.** Should `verified_by: none` be permitted with a prose
  justification (Path B in §8.1)? Deferred; revisit after observing
  ≥3 dispatches under the new gate. If the docs-only sentinel
  becomes idiomatic, codify; if it becomes overused, keep Path A.

* **OQ-2.** Should the `## System invariants` section also live in
  the `.json` schema-v1 contract as a top-level `system_invariants[]`
  array (so machine readers — implement loop, qa verification, build
  preflight — can consume it without markdown parsing)? Tentatively
  NO (§3 flagged callout): the section is human-authored prose with
  a single token; rendering it twice (md + json) doubles the agent's
  write surface and adds a divergence vector. Revisit if ENG-32
  (implement-loop verification) or ENG-38 (qa-refactor) gains a
  use-case for it.

* **OQ-3.** Implement-time enforcement: should a transcript detective
  fail dispatch when implement drops a `task:T<N>` referenced by a
  plan's `## System invariants` bullet? Out of scope; surface as a
  follow-up ticket if observed.

* **OQ-4.** Brainstorm-stage equivalent: should brainstorm docs
  carry a parallel section (different shape — brainstorms posit
  hypothetical invariants the plan then translates into runtime
  checks)? Explicit Linear OUT; this ticket leaves it deferred.

## 10. Assumption inventory

Every `path:line` excerpt below was verified against the worktree
HEAD on 2026-06-10. Quoted excerpts (where included) are exact
substrings safe to pass to `Edit::old_string`.

### Verified — existing code surfaces this brainstorm depends on

- **A-001 — `bin/plan-schema.sh` exists and exports `cmd_validate <file>` at lines 60-283; sub-command dispatch at lines 285-295.** Verified by direct read (`bin/plan-schema.sh:60-295`). The new `cmd_validate_md` sub-command will sit immediately after `cmd_validate` and be added to the `case` in `main()` at line 288.

- **A-002 — `bin/run-stage.sh::_validate_plan_contract` exists at lines 1074-1110; caller block (planning-stage-only gate) at lines 1865-1881.** Verified by direct read. The MD-side validator call slots in immediately after the existing JSON validator call (`bin/run-stage.sh:1100-1109`) — same try/case-on-rc shape, same routing to `_post_plan_contract_halt`.

- **A-003 — `bin/run-stage.sh::_post_plan_contract_halt` exists at lines 1115-1122; carries the `<!--` → `<\!--` sanitization at line 1117.** Verified by direct read. New MD defects flow through this site unchanged; sanitization covers the new defect strings.

- **A-004 — `bin/pipeline-events.json::halt_reasons` already registers `plan-contract-invalid` at line 20.** Verified by direct read. No new halt-reason needed.

- **A-005 — `failure_outcome_for_exit` in `bin/common.sh` maps rc=33/34/35 to plan-contract failure-class strings.** Inferred from `bin/run-stage.sh:1876`'s call `failure_outcome_for_exit "$_plan_rc"` (existing pattern; the new MD-side rc values reuse the same range).
  *Verify-during-implement:* open `bin/common.sh::failure_outcome_for_exit` and confirm rc=33/34/35 each map to a non-`unknown-exit-N` token. If not, the implement stage's Task list must add the mappings (per CLAUDE.md "for exit codes, use the `failure_outcome_for_exit` taxonomy ... unmapped codes route to `unknown-exit-N`").

- **A-006 — `AGENT_PROMPTS.md` §2 (Plan Agent) spans lines 366-687.** Verified by direct read. The required-sections enumeration is at lines 462-471 (the new H2 section is added there); the feasibility persona block is at lines 556-572 (the new resolution rule is appended there); the Completion checklist's P0 list is at lines 608-624 (the new P0 row is added there).

- **A-007 — `bin/agent-prompts-content-test.sh` ENG-135 add-side pin at lines 488-500.** Verified by direct read. The new ENG-157 pin (D-006) follows the same `printf | grep -qF` shape and is placed immediately after the ENG-135 block.

- **A-008 — `bin/run-stage-test.sh::ENG-122 INT1-INT5` integration tests at lines 4384-4519+.** Verified by direct read. The new INT6 test for ENG-157 slots in immediately after INT5 using the same source-and-stub pattern (`STUB_DIR/plan-schema.sh` delegates to the real validator at `$HARNESS_DIR/plan-schema.sh`).

- **A-009 — `bin/plan-schema-test.sh` exists** (file listed at `ls bin/plan-schema-test.sh`); ENG-122 created the file with `T_*` test groups for `cmd_validate`.
  *Verify-during-implement:* open `bin/plan-schema-test.sh` and confirm a `pass_at`/`fail_at` helper convention is already in place. If yes, the new `T_validate_md_*` group reuses it. If the helper convention differs from `bin/run-stage-test.sh`, the implementer must reconcile.

- **A-010 — ENG-122's INT4 (case 122-N) structural-lint pattern is the precedent for the new INT6 stage-gate.** Verified at `bin/run-stage-test.sh:4495-4519`. The new INT6 uses the same `awk '/Post-dispatch; planning stage only/ { in_block=1 }'` to confirm the new MD-validator call also lives inside the `planning)` arm.

- **A-011 — CLAUDE.md "Sub-agent debris (ENG-100)" ban on scratch-file writes outside the per-stage output allowlist** (CLAUDE.md "Sub-agent debris" section). Verified by reading the active dispatch prompt. The brainstorm doc is the ONLY output of this stage that is not stage-summary or progress.md; no fixture/scratch files are written.

- **A-012 — `bin/dispatch.sh::_assert_progress_md_entry` is the post-dispatch detective that halts on missing progress.md entries (rc=31).** Verified by `grep -n` (`bin/dispatch.sh:347` and `bin/dispatch.sh:358`). Referenced in §1 as the existing surface that ENG-125 tripped under sandbox denial.

- **A-013 — `bin/run-stage.sh::_ensure_progress_md` exists (referenced in §1).** Verified by `grep -n` — function definition at `bin/run-stage.sh:960`; section comment at `:944`; pre-dispatch caller at `:1347`. Referenced as the pre-touch site whose existence ENG-125-era plans implicitly relied on.

- **A-014 — ENG-155 brainstorm at `docs/brainstorms/2026-05-19-eng-155-dispatch-sh-thread-add-dir-...-design.md` documents the ENG-125 ground-truth (forensic §2 of that doc).** Verified by reading lines 42-75. Confirms ENG-125's halt was rc=31, not rc=34/29/etc — the new System-invariants gate would have caught the *plan-time* gap rather than the dispatch-time symptom.

- **A-015 — ENG-135 brainstorm at `docs/brainstorms/2026-05-17-eng-135-plan-test-gate-closure-add-side-sweep-design.md`** is the closest structural precedent (one new persona bullet, one new content-test pin, no new halt reason / exit code / orchestrator hook). Verified by reading §3.1-3.3 of that doc.

- **A-016 — `bin/plan-schema-adversarial-test.sh` exists** (`ls bin/plan-schema-adversarial-test.sh`). The new MD-validator's adversarial coverage (e.g., regex-evasion in `verified_by:` tokens, embedded `<!--` markers) lands in this file rather than the non-adversarial `bin/plan-schema-test.sh`.
  *Verify-during-implement:* open `bin/plan-schema-adversarial-test.sh` and confirm its convention. (May be similar T_* names with an adversarial prefix.)

### Assumed — claims that must be verified during implement

- **A-017 — ASSUMED: awk on macOS bash 3.2+ handles the multi-line block-extraction pattern needed for "find `## System invariants` heading, accumulate following lines until next H2 or EOF, walk bullets."** macOS ships BSD awk; the pattern below should work but the implementer must verify on a macOS host (the harness's primary target):

  ```awk
  /^## System invariants[[:space:]]*$/ { in_section=1; next }
  in_section && /^## / { in_section=0 }
  in_section && /^- / { bullet_count++; ... }
  ```

  *Verify-during-implement:* run a minimal awk fixture on macOS bash 3.2 before generalising. If BSD awk balks at `[[:space:]]`, fall back to explicit `[ 	]` (space-tab) class. If the heading-detection needs multi-line awareness, prefer two passes (one to find the line range, one to walk bullets) over awk pattern complexity.

- **A-018 — ASSUMED: the planning agent's claude tool universe today INCLUDES `Read` access to the project's existing test files** (so the feasibility persona's resolution sweep at D-005 can grep them). Today's planning stage's tool allowlist is "(none)" stack-specific (per the project profile addendum) — meaning the base allowlist applies, which includes `Read` and `Grep` (stage-agnostic core tools per the profile's "Tool allowlist" section header). This is standard.
  *Verify-during-implement:* confirm `Read` and `Grep` are core tools (CLAUDE.md "Stage-agnostic core tools" enumeration at the project profile's "Tool allowlist" section header).

- **A-019 — ASSUMED: the persona-review document-review skill the planning agent uses today supports adding a new finding rule to an existing persona without re-defining the persona.** ENG-135 did this successfully (extended feasibility's existing test-gate closure rule with the add-side mirror); ENG-157 follows the same pattern.
  *Verify-during-implement:* the directive lives in `AGENT_PROMPTS.md` §2's feasibility bullet text itself, not in any external skill file — the document-review skill consumes the prompt body verbatim.

- **A-020 — ASSUMED: `_validate_plan_contract` running both validators sequentially does NOT exceed any timeout budget.** Today's call costs one `jq -r` invocation per validation; adding an awk pass costs a similar order. The whole post-dispatch validator block is sub-second on a normal-sized plan markdown.
  *Verify-during-implement:* time the new pass against a representative plan markdown (~2000 lines, ENG-106-class). If the awk pass exceeds 500ms, switch to a streamed implementation.

- **A-021 — ASSUMED: the existing `_validate_plan_contract` short-circuit (returns on first non-zero rc) is acceptable in the operator-UX sense.** §8.7 notes the trade-off; operator may face two consecutive halts (fix JSON, fix MD) but only on plans that fail both validators simultaneously — empirically rare.
  *Confirm during product persona review:* the trade-off is documented; operator workflow is unchanged from today's single-halt path.

### Code-reference verification table

| Reference | path:line(s) | Status |
|---|---|---|
| `bin/plan-schema.sh::cmd_validate` | `bin/plan-schema.sh:60` | verified (HEAD 2026-06-10) |
| `bin/plan-schema.sh::main` (sub-command dispatch) | `bin/plan-schema.sh:285-295` | verified |
| `bin/run-stage.sh::_validate_plan_contract` | `bin/run-stage.sh:1074-1110` | verified |
| `bin/run-stage.sh::_post_plan_contract_halt` | `bin/run-stage.sh:1115-1122` | verified (sanitization line 1117) |
| `bin/run-stage.sh` caller block | `bin/run-stage.sh:1865-1881` | verified (planning-stage gate) |
| `bin/pipeline-events.json::halt_reasons` | `bin/pipeline-events.json:10-21` | verified (`plan-contract-invalid` at line 20) |
| `AGENT_PROMPTS.md` §2 Plan Agent | `AGENT_PROMPTS.md:366` | verified |
| `AGENT_PROMPTS.md` §2 required sections | `AGENT_PROMPTS.md:462-471` | verified |
| `AGENT_PROMPTS.md` §2 feasibility persona | `AGENT_PROMPTS.md:556-572` | verified |
| `AGENT_PROMPTS.md` §2 Completion P0 list | `AGENT_PROMPTS.md:608-624` | verified |
| `bin/agent-prompts-content-test.sh` ENG-135 pin | `bin/agent-prompts-content-test.sh:488-500` | verified |
| `bin/run-stage-test.sh` ENG-122 INT block | `bin/run-stage-test.sh:4384-4519+` | verified |
| `bin/dispatch.sh::_assert_progress_md_entry` | `bin/dispatch.sh:347, 358` | verified |
| `bin/run-stage.sh::_ensure_progress_md` | `bin/run-stage.sh:944` | verified |
| ENG-155 forensic ground truth on ENG-125 | `docs/brainstorms/2026-05-19-eng-155-...md:42-75` | verified |
| ENG-135 structural precedent | `docs/brainstorms/2026-05-17-eng-135-...md` | verified |
| `bin/plan-schema-test.sh` | `bin/plan-schema-test.sh` (file exists) | verified (file presence; helper convention to confirm during implement) |
| `bin/plan-schema-adversarial-test.sh` | `bin/plan-schema-adversarial-test.sh` (file exists) | verified (file presence; convention to confirm during implement) |

## 11. ADR stress test

The ticket adds a new doc gate. Does it put pressure on any accepted
ADR?

* **CLAUDE.md "Don't add features ... beyond what the task requires":**
  The ticket explicitly carves out brainstorm-equivalent and persona
  expansion. The chosen design (one new sub-command, one persona
  bullet, one content pin, one INT test) is the minimum that
  satisfies the four ACs. No pressure.

* **ENG-122 plan-contract-invalid taxonomy:** Reusing the same halt
  reason for a markdown-side defect (vs. the JSON-side defect ENG-122
  introduced) is a deliberate consolidation. The defect-token prefix
  (`plan-md-` vs. existing) discriminates without proliferating halt
  reasons. Mild pressure on diagnostic readability, mitigated by D-003's
  token-prefix discipline and §7.1's worked-example halt comment.

* **CLAUDE.md "Per-stage allowed tool lists are centralized in
  `dispatch.sh::allowed_tools_for`":** The new validator runs in
  `run-stage.sh` post-dispatch — agent-side tools unchanged. The
  feasibility persona uses `Read`/`Grep` which are stage-agnostic
  core tools (already implicit per the project profile addendum's
  "Tool allowlist" preamble). No allowlist edits required. No
  pressure.

* **CLAUDE.md "Exit codes use the `failure_outcome_for_exit` taxonomy":**
  Reusing rc=33/34/35 keeps the taxonomy unchanged. A-005 above
  notes the verify-during-implement check. No pressure.

* **ENG-135 add-side test-gate closure sweep (mirror precedent):**
  ENG-157 follows the exact ENG-135 shape — one new persona bullet,
  one content pin, no orchestrator changes. The two rules sit
  side-by-side in feasibility's bullet list; both flag P0 on the
  same severity scale. No pressure; ENG-135 is the explicit pattern
  this ticket extends.

* **CLAUDE.md "Stage summary file — overwrite-on-every-dispatch":**
  Independent surface. No interaction.

## 12. Conflicts with existing architecture

None identified. The design is additive at every surface:

* `bin/plan-schema.sh` — new sub-command, existing one unchanged.
* `bin/run-stage.sh::_validate_plan_contract` — new validator call
  added after the existing one; existing call path unchanged on
  the JSON-valid + MD-valid happy path.
* `AGENT_PROMPTS.md` §2 — new required section row, new persona
  bullet, new P0 row; existing required sections and persona bullets
  unchanged.
* `bin/agent-prompts-content-test.sh` — new pin assertion; existing
  pins unchanged.
* `bin/run-stage-test.sh` — new INT6 test; existing INT1-INT5
  unchanged.
* `bin/plan-schema-test.sh` — new T_validate_md_* test group;
  existing groups unchanged.
* `bin/plan-schema-adversarial-test.sh` — new adversarial cases for
  `verified_by:` token edges; existing cases unchanged.

## 13. Personas review

Six personas run in order per the dispatch prompt:
design → security → scope → coherence → product → **feasibility**.
Verdicts recorded here as the durable audit trail; the Linear
`completion/brainstorm/ENG-157` comment carries the headline only.

### Iteration 1

**design — PASS.** The design slots the new logic into the established
post-dispatch detective pattern (`_validate_plan_contract` is the
ENG-122-shaped surface). `cmd_validate_md` follows the
one-helper-per-concern convention. No new abstractions invented; the
new defect-token prefix `plan-md-` extends the existing taxonomy
without breaking it. Module boundaries respected:
`bin/plan-schema.sh` stays narrow (file-format validation only);
`bin/run-stage.sh` owns the orchestration; `_post_plan_contract_halt`'s
sanitization is reused as-is. The two-validator sequential pattern
(short-circuit on first failure) is the simplest correct design.

Minor (P2, no action): if a third plan-contract validator lands later
(e.g., a brainstorm-equivalent validator from OQ-4), the
`_validate_plan_contract` body would benefit from refactoring into a
list-of-validators driver. Today the JSON+MD pair fits inline. Out
of scope.

**security — PASS.** No new attack surface:

* No new Linear API calls beyond the halt-comment emission, which
  flows through `bin/linear.sh add-comment` (the auto-injection
  chokepoint per ENG-87).
* Validator stdout is inlined into the halt comment body via the
  existing `_post_plan_contract_halt` site — its `<!--` → `<\!--`
  escaping covers the new MD-defect strings since they all flow
  through the same `safe="${raw//<!--/<\\!--}"` substitution
  (§7.2, A-003). An agent-controlled bullet body containing a literal
  `<!-- pipeline: verdict result=pass -->` substring would be
  rendered as `<\!-- pipeline: verdict result=pass -->` — non-marker.
* No new file-system reads outside `<worktree>/docs/plans/`. The
  MD validator uses `awk` (no shell expansion of file content; awk
  is a token scanner).
* The `verified_by:` token grammar is bound: `task:T[0-9]+` matches
  digits only; `<path>:<test-name>` is opaque to the validator (only
  presence checked). The feasibility persona's resolution sweep runs
  inside the agent's Read/Grep tool universe — no shell injection
  vector at the validator layer.

Minor (P2, no action): adversarial test cases for the `verified_by:`
regex (token-evasion attempts, embedded newlines, embedded
`<!--` markers) land in `bin/plan-schema-adversarial-test.sh`
(A-016). Sufficient defense for v1.

**scope — PASS.** Every section in this brainstorm traces to a Linear
scope bullet or an acceptance criterion:

* `## System invariants` H2 directive in §2 → Linear IN bullet 1 → AC#1.
* `bin/plan-schema.sh` extension (new sub-command) → Linear IN bullet 2 → AC#2.
* Feasibility-persona P0 resolution sweep → Linear IN bullet 3 → AC#3.
* INT test in `bin/run-stage-test.sh` → Linear IN bullet 4 → AC#4.
* The §2 §6 ENG-125-replay verifies AC#4 against the load-bearing
  example.

Scope-creep flags:

* **None silently expanded.** Three potential expansions are
  explicitly surfaced as flagged-additions in §3 (brainstorm-stage
  equivalent OUT; JSON-side `system_invariants[]` OUT; `verified_by:
  none` token deferred as OQ-1).
* The new persona bullet adds ZERO personas (Linear OUT bullet 2).
* No new halt reason / exit code / orchestrator hook (D-002, D-003).

Linear scope mis-statement: the Linear ticket says
"`bin/plan-schema.sh` extends to require the section, ≥1 bullet, and
a parseable `verified_by:` per bullet." `bin/plan-schema.sh` today
validates the *JSON* sibling; the System invariants section lives in
the *markdown* plan. §4.2 (D-002) justifies the resolution
(new sub-command `validate-md` rather than overloading `validate`).
Headline for the stage-summary footnote.

**coherence — PASS.** Goal (§1 + §3) — "close the structural gap that
no plan-time gate names runtime invariants" — matches the AC list
(§3). Data flow §6 covers agent write → personas → validator → halt
or advance. Error Handling §7 maps each defect to a recovery path
(§7.3). Edge Cases §8 covers nine concrete shapes. Architecture
sketch §5 names every file modified + created and which functions
change in each.

Minor (P2, no action): §8.1 ("no new runtime invariants" plans)
leaves the resolution as Path A with OQ-1 carry. That's acceptable;
the iteration loop on Path A is bounded (a single sentinel bullet).

**product — PASS.** The user impact ladder:

1. *Today:* plan-time invariants live as tribal knowledge; the
   first dispatched-agent dispatch that violates one halts mid-stage
   with no plan-time signal (ENG-125 took three weeks of latent
   denials before a hard halt).
2. *Post-ENG-157:* the plan agent must name each runtime invariant
   the plan depends on, with a `verified_by:` reference. Feasibility
   resolves the reference; the post-dispatch validator pins the
   structural shape. A missing reference fails plan-time, not
   dispatch-time.
3. *Long-term:* the `## System invariants` section becomes the place
   future retrospectives mine for "what runtime contracts has the
   harness implicitly accumulated?" — a queryable inventory.

The product principle (CLAUDE.md "Don't add features ... beyond what
the task requires") is honored: ONE new doc section, ONE new
sub-command, ONE persona bullet, ONE content pin, ONE INT test. No
new personas, no new halt reason, no new exit code, no
orchestrator-side surface. Nothing speculative — three OQs are all
deferred to follow-up tickets with clear escape hatches.

The ticket name itself ("Plan docs: require System Invariants section
+ feasibility-persona P0 on unverified bullets") is verbatim
the deliverable.

**feasibility — PASS, zero P0.** Every code-level claim verified
against the worktree at HEAD on 2026-06-10. §10 Assumption Inventory
quotes 16 verified `path:line` references + 5 explicit "assumed"
items each with a verify-during-implement hand-off. The code-reference
verification table at §10 enumerates 18 references, each marked
verified or with a documented verify-during-implement check.

Spot-checks performed (re-read inside this iteration):

* `bin/plan-schema.sh:60-295` — `cmd_validate` body + `main` dispatch
  confirmed; new sub-command slot is unambiguous.
* `bin/run-stage.sh:1074-1110` + `1115-1122` + `1865-1881` —
  three-site change confirmed; sanitization at line 1117 covers new
  defect strings.
* `bin/pipeline-events.json:10-21` — `plan-contract-invalid` already
  registered at line 20. No registry edit needed.
* `AGENT_PROMPTS.md:366`, `:462-471`, `:556-572`, `:598-624` — four
  edit sites confirmed; each is additive (insert new row / append new
  bullet); no existing content is rewritten.
* `bin/agent-prompts-content-test.sh:488-500` — ENG-135 pin shape
  confirmed; new ENG-157 pin follows the same `printf | grep -qF`
  pattern.
* `bin/run-stage-test.sh:4384-4519+` — ENG-122 INT1-INT5 source-and-stub
  pattern confirmed; new INT6 reuses `STUB_DIR/plan-schema.sh`.
* CLAUDE.md "Sub-agent debris (ENG-100)" — confirmed no scratch-file
  writes proposed in this brainstorm.

The two `verified_by:` formats (`<path>:<test-name>` and `task:T<N>`)
are simple enough that the awk-pass implementation is straightforward
(A-017 with the BSD-awk verify-during-implement). No
codebase-fact errors. All `path:line` references resolve. All cited
prior brainstorms (ENG-122, ENG-135, ENG-155) read for structural
precedent, not for code-level facts.

**Verdict: 6/6 PASS, 0 P0. Gate satisfied. Proceeding to plan stage.**

(No P1 items; two P2 notes — design persona's "list-of-validators
driver" future refactor and §8.1 sentinel-bullet ergonomics — both
explicitly out of scope and documented as such.)
