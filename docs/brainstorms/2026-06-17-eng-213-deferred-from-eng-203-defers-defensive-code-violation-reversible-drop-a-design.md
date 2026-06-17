---
linear: ENG-213
title: Drop the defensive `*)` arm from `_merge_qa_payload_envelope`'s rc→defect case
date: 2026-06-17
status: draft
---

# ENG-213 — Drop the defensive `*)` arm from `_merge_qa_payload_envelope`'s rc→defect case

## 1. Problem

ENG-203's review carried a deferred maintainability finding —
`maintainability:run-stage.sh:case-rc-fallthrough-defensive`
(dispatch `ENG-203-d0012`, iteration 2). The site is
`bin/run-stage.sh:2102-2106`, inside the qa-stage's
post-dispatch envelope-merge helper `_merge_qa_payload_envelope`
(`bin/run-stage.sh:2089-2112`):

```bash
case "$rc" in
  41) defect="qa-payload-missing" ;;
  39|42|50) defect="qa-payload-malformed" ;;
  *)  defect="qa-payload-malformed" ;;
esac
```

The `*)` arm assigns exactly the same value as the `39|42|50)`
arm — it is a literal no-op for every documented input. The
callee, `merge_artifact_envelope` (`bin/common.sh:713-744`),
publishes a closed exit-code set in its header comment
(`bin/common.sh:700-712`): rc ∈ {0, 39, 41, 42, 50}, with rc=0
filtered by the `(( rc != 0 ))` guard one line above the case
(`bin/run-stage.sh:2100`). The `*)` arm cannot fire on any
documented call path; its presence handles "scenarios that
can't happen."

Why this is a maintainability violation, not a portable safety
net:

- It contradicts the Claude system prompt directive — *"Don't
  add error handling, fallbacks, or validation for scenarios
  that can't happen. Trust internal code and framework
  guarantees."* — which the project operationalised
  prompt-side in **ENG-101**
  (`docs/brainstorms/2026-05-15-eng-101-prompt-side-defensive-code-restraint-clause-for-implement-review-agents-design.md`).
- The two arms agree on the defect string, so an unknown rc
  is silently relabelled `qa-payload-malformed` —
  bug-camouflage rather than diagnostic surface. If the
  helper's contract ever drifts (e.g. a new rc=43), the arm
  hides it instead of letting the contract violation manifest.
- It is reversible: the deferred-majors rubric in ENG-191
  explicitly marked this finding `reversible_post_ship: yes`,
  `has_workaround: yes (arm is no-op)`, `user_visible: no`.

Why the original review chose to defer rather than block ship:
the arm is genuinely a no-op for production today, so dropping
it is a polish PR (one-subsystem, zero behaviour change). It
landed in the deferred-majors bucket on PR #175 to keep
ENG-203's foundation merge focused.

## 2. Goal

After ENG-213 lands:

- AC#1: `bin/run-stage.sh:2102-2106` contains the case
  statement with exactly two arms — `41)` mapping to
  `qa-payload-missing` and `39|42|50)` mapping to
  `qa-payload-malformed`. No `*)` arm.
- AC#2: `bash bin/run-stage-test.sh` passes — in particular
  ENG-117 117-B, ENG-117 117-C, ENG-203 OS-1, ENG-203 OS-2,
  and ENG-203 OS-3 (the suite of qa-payload halt-shape pins,
  `bin/run-stage-test.sh:5955-5999, 9740-9807`).
- AC#3: Full `.githooks/pre-commit` suite green.
- AC#4: No companion changes to `bin/common.sh`,
  `bin/qa-payload-schema.sh`, `bin/verify-qa.sh`, the qa
  prompt body in `AGENT_PROMPTS.md`, or any operator runbook
  — this PR is one-file, ≤5-line deletion plus its test
  fixture (D-002).

## 3. Decisions

### D-001. Drop the `*)` arm entirely. Do not replace it with an `unexpected-rc` sentinel.

**The change.** Remove line 2105 (`*)  defect="qa-payload-malformed" ;;`)
from `bin/run-stage.sh`. The resulting case statement:

```bash
case "$rc" in
  41) defect="qa-payload-missing" ;;
  39|42|50) defect="qa-payload-malformed" ;;
esac
```

**Behaviour for documented rcs (39, 41, 42, 50).** Identical
to pre-fix — both rc=41 and rc∈{39,42,50} map to the same
defect tokens they map to today. ENG-117 117-B/-C and
ENG-203 OS-2/OS-3 continue to pass without test edits.

**Behaviour for hypothetical undocumented rcs.** `case`
matches nothing → `local defect` (declared at line 2101)
remains the empty string → `_post_qa_payload_halt` posts a
halt body with a literal empty `- Defect: ` line, AND the
raw stderr passed via `$3` carries the actual
`merge_artifact_envelope failed (rc=N) for body=…` string
(`bin/run-stage.sh:2107-2108`). The operator sees both the
empty defect AND the raw rc — a louder forensic signal than
today's silent relabel. The halt outcome is still
`qa-payload-invalid`, the issue still parks at
`pipeline:halted`, recovery is unchanged: `bash
bin/pipeline.sh decide <ENG-N> --action continue`.

**Rationale — why no sentinel.** A simpler shape considered
and rejected: instead of dropping `*)`, replace its body with
`defect="qa-payload-unexpected-rc"`, mirroring the
`_validate_qa_payload` case at `bin/run-stage.sh:2129-2136`
(which emits `unexpected-rc`). Rejected because:

- The two cases are different in kind. `_validate_qa_payload`
  delegates to an *external* script,
  `bin/qa-payload-schema.sh`, whose exit-code set is owned
  by the script author and CAN drift independently of the
  caller; a sentinel arm is defense at a real trust boundary.
  `_merge_qa_payload_envelope` calls an *in-process bash
  function* in `bin/common.sh` — same repo, same PR-review
  surface, same pre-commit gate. No trust boundary, no
  defense needed. (Verified at `bin/common.sh:713-744` —
  closed rc set, file-local control.)
- Introducing `qa-payload-unexpected-rc` adds a new defect
  string to the operator's mental-model space (a new token
  to recognise in halt comments, a new keyword to grep). The
  Linear ticket explicitly bounds the change to "drop *
  arm"; expanding scope to a new defect token would move the
  ticket from "polish" to "taxonomy edit" without evidence
  of need.
- The empty-defect halt is louder, not quieter. An operator
  reading `Defect: ` followed by an explicit `(rc=N)` in
  the raw stderr will diagnose contract-violation faster than
  one reading `Defect: qa-payload-unexpected-rc` (the latter
  reads as a normal halt class).

**Principle reference.** ENG-101 self-review bullet —
*"Don't add error handling, fallbacks, or validation for
scenarios that can't happen"* — is the load-bearing principle.
The `*)` arm is precisely the shape ENG-101 told the implement
agent to avoid on every future dispatch; this PR removes a
pre-ENG-101 instance from the orchestrator code.

**Principle reference (Claude system prompt — quoted in
ENG-101's overview).** *"Trust internal code and framework
guarantees. Only validate at system boundaries (user input,
external APIs)."* `merge_artifact_envelope` is internal code
in the same crate-of-bash; the defensive arm violates the
"trust internal code" half.

### D-002. The change is one file, one logical line. No companion edits, no taxonomy work, no doc updates.

**Surface scoped to `bin/run-stage.sh:2102-2106`.** Verified
nothing else in the worktree depends on the `*)` arm firing:

- `bin/common.sh::merge_artifact_envelope` (the only callee)
  emits exactly the documented rc set — `bin/common.sh:715-737`
  shows every `return` statement and they are all in
  {0,39,41,42,50}. Verified `Grep` for `return [0-9]` within
  the function body.
- `bin/run-stage-test.sh` OS-1/OS-2/OS-3 exercise rc=0
  (success), rc=41 (missing body), and rc=39 (malformed
  body). No test exercises an undocumented rc; nothing
  asserts the `*)` arm fires. (Verified at
  `bin/run-stage-test.sh:9740-9807`.)
- `docs/runbooks/recovery.md` and `CLAUDE.md` reference the
  qa-payload-invalid halt class generically (`grep
  qa-payload` over docs returns prose about the halt reason,
  not about specific defect tokens). No doc change needed.

**Rationale.** Ticket-sizing rubric in CLAUDE.md: 1
subsystem (orchestrator) + 1 design decision = autonomy-safe.
Mirror ENG-102 (PR #95 polish) and ENG-115 (pivot-marker
single-line normalisation) — small-shape brainstorms produce
clean small PRs that ship in one review pass.

**Reference to constraint.** CLAUDE.md "Don't add features,
refactor, or introduce abstractions beyond what the task
requires." The deferred finding is one arm; the PR is one
arm. No co-located cleanup of `_validate_qa_payload`'s `*)`
arm (see Open Questions OQ-1 for why that one stays).

### D-003. Add one regression-pin test to `bin/run-stage-test.sh` that asserts the case-statement shape via AST-style grep.

**The test.** A new test block, sibling to OS-1/OS-2/OS-3,
that:

1. Greps `bin/run-stage.sh` for the literal case-arm region
   between `_merge_qa_payload_envelope()` and the closing
   `}`.
2. Asserts the captured block contains the two documented
   arms (`41)` and `39|42|50)`) AND does NOT contain a `*)`
   arm.

The shape mirrors OS-6b at `bin/run-stage-test.sh:9905-9910`
which already does AST-style grep on the same function body:

```bash
_eng213_body="$(awk '/^_merge_qa_payload_envelope\(\) \{/,/^\}/' \
  "$HARNESS_DIR/run-stage.sh" 2>/dev/null || true)"
if [[ "$_eng213_body" == *'41) defect="qa-payload-missing"'* ]] \
  && [[ "$_eng213_body" == *'39|42|50) defect="qa-payload-malformed"'* ]] \
  && [[ "$_eng213_body" != *'*)  defect='* ]] \
  && [[ "$_eng213_body" != *'*) defect='* ]]; then
  pass_at "ENG-213 OS-1: _merge_qa_payload_envelope case has no defensive *) arm"
else
  fail_at "ENG-213 OS-1: case shape" \
    "expected 41)+39|42|50) only; got: ${_eng213_body}"
fi
```

**Rationale — why pin the shape.** Without a pin, a future
defensive-coding regression (a reviewer or agent that
re-adds the `*)` arm "for safety") would not be detected by
any existing test. OS-1/OS-2/OS-3 pin the documented-rc
behaviour, not the case-statement shape. ENG-101's
prompt-side restraint reduces the probability but does not
eliminate it (the dispatched implementing agent is not the
only writer; the retrospective agent and human edits also
touch this file).

**Rationale — why grep, not behavioural.** Hitting the
hypothetical `*)` arm at runtime requires `merge_artifact_envelope`
to violate its own documented contract. We cannot mock that
without modifying `bin/common.sh`, which is out of scope.
AST-style grep is the cheapest pin that detects the
regression class.

**Reference to constraint.** ENG-97 D-8 pattern (cited in
ENG-101 brainstorm §1): positive-marker pins in
`bin/agent-prompts-content-test.sh` prevent silent strip on
prompts. The same shape applies to case-statement structure
in production code. The pin sits inside the existing OS
naming series (renumbered to ENG-213 OS-1 to avoid
collision with ENG-203's OS-N).

**Tradeoff (acknowledged).** The shape-pin couples the test
to the textual form of the case statement, so a benign
refactor (e.g. converting to an `if/elif` chain) would
require a test edit. Acceptable — the case statement is the
project-idiomatic shape for rc→defect maps (`grep -n 'case
"$rc"' bin/*.sh` shows four occurrences across run-stage.sh
and run-local.sh), so the refactor is unlikely without a
broader cross-cutting change that would update tests anyway.

## 4. Architecture (where the code lives)

| Site | File | Lines | Change |
|---|---|---|---|
| The defensive arm | `bin/run-stage.sh` | 2105 | DELETE one line |
| Regression-pin test | `bin/run-stage-test.sh` | (append, ~15 lines, after OS-8 at L9988-ish) | ADD |

No edits to:

- `bin/common.sh` — `merge_artifact_envelope` is unchanged.
- `bin/qa-payload-schema.sh` — schema validator is unchanged.
- `bin/verify-qa.sh` — predicate validator path is unchanged.
- `AGENT_PROMPTS.md` — qa prompt body is unchanged (the
  agent never sees the case statement; it owns the body
  sidecar, the orchestrator owns the envelope).
- `bin/run-local-helpers.sh::partition_dirty_paths` —
  scope-allowlist already permits writes to `bin/*.sh` for
  implementing.
- `learned-rules/harness/*.md` — no new retrospective rule
  needed (ENG-101's prompt clause covers the implementing-agent
  case; the human-author case is rare and the OS-1 pin
  catches it).

## 5. Data flow

`_merge_qa_payload_envelope`'s qa-payload halt flow,
unchanged except for the dropped arm:

```
qa-stage agent emits verdict-qa.body.json
  ↓ orchestrator hook (run-stage.sh post-dispatch sequence)
_merge_qa_payload_envelope <ident>
  ↓ constructs env_json {schema_version=1, issue_id, dispatch_id}
merge_artifact_envelope body env_json canonical
  ├─ rc=0  → return 0 (success; _validate_qa_payload runs next)
  ├─ rc=41 → case 41) → defect=qa-payload-missing → halt → exit 41
  ├─ rc=39 → case 39|42|50) → defect=qa-payload-malformed → halt → exit 39
  ├─ rc=42 → case 39|42|50) → defect=qa-payload-malformed → halt → exit 42
  └─ rc=50 → case 39|42|50) → defect=qa-payload-malformed → halt → exit 50
```

Pre-fix the diagram also had a `└─ rc=N (other)` branch
that resolved to `defect=qa-payload-malformed`. Post-fix
that branch resolves to `defect=""` and the raw stderr
carries the rc, giving the operator a louder signal.

## 6. Error handling

**`merge_artifact_envelope` contract drift (hypothetical
post-fix).** If a future PR extends the helper to emit, say,
rc=43, the case statement matches nothing, `defect` is
empty, the halt comment posts with an empty `Defect: ` line
and the raw stderr text. Operator triage:

- The halt-comment marker `verdict result=halt
  reason=qa-payload-invalid` still routes through
  `verdict-handler.sh` normally — issue gets
  `pipeline:halted` label.
- The empty defect token is the forensic signal — operator
  greps the day-log for `merge_artifact_envelope failed
  (rc=43)` and traces to the upstream change in
  `bin/common.sh`. Standard pre-commit gate (which runs the
  test suite on every commit) would have flagged the
  taxonomy gap in PR review.

**Pre-commit gate sanity.** The added OS-1 test runs in
`bin/run-stage-test.sh`, which is in the worktree-relative
`bin/*-test.sh` glob the pre-commit hook iterates
(`.githooks/pre-commit`). No `KNOWN_BROKEN` allowlist edit
needed (`run-stage` is not in the current allowlist —
verified).

## 7. Edge cases

| Edge case | Pre-fix | Post-fix |
|---|---|---|
| rc=0 (success) | gated out by `(( rc != 0 ))` at L2100; case never entered | Same — unchanged |
| rc=41 (body missing) | case 41) → `qa-payload-missing` | Same — unchanged |
| rc=39 (body malformed/oversize) | case 39\|42\|50) → `qa-payload-malformed` | Same — unchanged |
| rc=42 (body is symlink / envelope not JSON object) | case 39\|42\|50) → `qa-payload-malformed` | Same — unchanged |
| rc=50 (mktemp/jq/mv write failure) | case 39\|42\|50) → `qa-payload-malformed` | Same — unchanged |
| rc=N for any N ∉ {0,39,41,42,50} (contract violation) | case *) → `qa-payload-malformed` (silent relabel) | empty defect + raw stderr (louder signal) |
| Agent writes empty body file | merge returns 39 (size check) → 39\|42\|50) arm | Same — unchanged |
| Agent writes oversize body (>65536 bytes) | merge returns 39 (size check) → 39\|42\|50) arm | Same — unchanged |
| Concurrent envelope merges on same issue | per-issue lock serialises; mktemp is collision-proof | Same — unchanged |

The matrix above is exhaustive against
`merge_artifact_envelope`'s code paths
(`bin/common.sh:715-737`). Every `return` statement was
traced.

## 8. Open questions

**OQ-1. Should we also drop `_validate_qa_payload`'s `*)`
arm at `bin/run-stage.sh:2134-2136`?** No (out of scope, and
the cases are not symmetric). That arm calls an external
script `bin/qa-payload-schema.sh` whose exit codes are owned
by a separate file — a real trust boundary. The arm there
emits `unexpected-rc` (a distinct defect token, not a
silent relabel), and that token actively differentiates
contract-violation halts in the day-log. Keeping it is
correct per the ENG-101 boundary heuristic ("validate at
system boundaries"). The deferred finding scoped to the
in-process callee; the cross-script callee stays.

**OQ-2. Should we add a similar pin to other rc→defect case
statements in `bin/run-stage.sh`?** Defer. Three other case
statements exist (`bin/run-stage.sh:1411, 1453, 2129`), all
on different exit-code taxonomies. None have a duplicate
`*)`-equals-prior-arm shape today (spot-checked). A
cross-cutting "no defensive duplicate-arms" detective is a
larger ticket — the ENG-101 prompt rule already covers the
write-side; ENG-213's narrow shape-pin is sufficient for
the called-out site. If the regression class recurs, file a
sibling ticket and consider a generic detective (e.g.
`bin/case-shape-lint.sh`).

**OQ-3. Does this PR touch the deferred-majors bucket on
PR #175?** No. PR #175 is merged (`ede2380 Merge pull
request #175`); ENG-213 ships as a fresh PR on its own
feature branch. The original deferred entry in PR #175's
deferred-majors comment remains as the historical pointer
to this ticket.

**OQ-4. Operator-runbook update needed?** No. The
qa-payload-invalid halt class is documented generically in
`docs/runbooks/recovery.md` §15 and the failure-mode quick
reference in `CLAUDE.md`. Neither references the specific
`*)`-arm behaviour. Empty-defect halts (the new failure
mode for a hypothetical contract-violating rc) are
operator-recognisable as "merge helper returned undocumented
rc" via the raw stderr in the halt comment. If empty-defect
halts ever fire in practice, that's evidence of a
`merge_artifact_envelope` contract drift, not an
ENG-213-class regression.

## 9. Anti-bias checks

### ADR stress test

This PR puts no pressure on any prior architectural
decision. Specifically:

- **ENG-101 (defensive-code restraint clause).** Directly
  *supported* — ENG-213 removes a pre-existing instance of
  the shape ENG-101 told the implement agent never to
  introduce. Same direction, same principle.
- **ENG-87 (cross-dispatch staleness contract).** Not
  touched — the dispatch_id flow through
  `$PIPELINE_DISPATCH_ID` and the envelope-merge sidecar
  pattern are unchanged.
- **ENG-117 (qa-payload validator).** Not touched —
  `_validate_qa_payload` and `qa-payload-schema.sh` are
  unchanged. The two qa-payload halt-shape tests (117-B,
  117-C) continue to pass.
- **ENG-203 (orchestrator-merge helper).** Polish on a
  helper that shipped in ENG-203 (PR #175). No regression
  on the OS-N test series; the new ENG-213 OS-1 test sits
  alongside.
- **ENG-191 (deferred-majors ship-with-known-debt).** This
  ticket *exercises* the deferred-majors path — it is the
  follow-up created by the deferred-majors auto-creation
  flow that ENG-193 ships. Closing the ticket validates the
  ship-then-fix loop.

The harness has no formal ADR registry (verified at
ENG-101's §3 of its brainstorm); the relevant decisions
above are the ENG-N brainstorms themselves.

### Simpler alternatives considered

| Alternative | Why rejected |
|---|---|
| **Replace `*)` body with `defect="qa-payload-unexpected-rc"`** (mirror `_validate_qa_payload`) | The two functions are not symmetric — `_validate_qa_payload` delegates to an external script (real trust boundary); `_merge_qa_payload_envelope` calls in-process code. The deferred finding's scope is "drop * arm"; introducing a new defect token expands scope to taxonomy work without evidence of need. The empty-defect halt is louder than a sentinel relabel. See D-001 for the full argument. |
| **Drop the `*)` arm AND collapse `39\|42\|50)` into a single `*)` arm** (one-arm case) | Loses the missing-vs-malformed distinction. rc=41 needs its own defect string for operator triage. The two-arm shape preserves the actionable distinction the current code already makes. |
| **Add the `*)` arm to a centralised helper in `bin/common.sh`** ("case statements everywhere") | YAGNI per CLAUDE.md "Don't add features beyond what the task requires." Cross-cutting refactor needs evidence the regression class recurs at multiple sites. OQ-2 defers that work. |
| **Do nothing** (the deferred-majors disposition itself) | Leaves the violation in production code, sets a precedent that defensive arms can stay if they happen to be no-ops, and undermines the ENG-101 directive (an arm in the production tree the implement agent can read disregards the rule the agent is told to follow). The ticket files-and-closes the polish as a sub-3-LOC PR — cheap to ship. |
| **Defer indefinitely** (move the ticket to Backlog and let it rot) | Defeats the ENG-191 / ENG-193 ship-with-known-debt loop. The whole point of deferred-majors auto-creation is that the follow-up tickets DO ship; an indefinite-defer pattern would degrade the loop's signal. |

### Assumption inventory

| # | Assumption | Status | Evidence |
|---|---|---|---|
| A-1 | `_merge_qa_payload_envelope` exists at `bin/run-stage.sh:2089-2112` | verified | Read of `bin/run-stage.sh:2089-2112` — function definition present with documented header. |
| A-2 | The case statement at `bin/run-stage.sh:2102-2106` has three arms — `41)`, `39\|42\|50)`, `*)` — with `*)` assigning the same value as `39\|42\|50)` | verified | Read of `bin/run-stage.sh:2102-2106` — three arms confirmed; `*)` body identical to prior arm. |
| A-3 | `merge_artifact_envelope` lives at `bin/common.sh:713-744` | verified | Read of `bin/common.sh:700-744` — function header at 700, body 713-744. |
| A-4 | `merge_artifact_envelope` returns exactly {0, 39, 41, 42, 50} — closed rc set | verified | Read of `bin/common.sh:713-744` — every `return` statement enumerated: `41` (L715), `42` (L716), `39` (L719), `39` (L722), `42` (L724), `50` (L727), `50` (L729), `50` (L737), `0` (L743). No other return statements in the function. |
| A-5 | The `(( rc != 0 ))` guard at `bin/run-stage.sh:2100` ensures rc=0 never enters the case | verified | Read of `bin/run-stage.sh:2100` — `if (( rc != 0 )); then` wraps the case statement. |
| A-6 | OS-1/OS-2/OS-3 exercise rc=0, rc=41, and rc=39 respectively at `bin/run-stage-test.sh:9740-9807` | verified | Read of `bin/run-stage-test.sh:9740-9807` — OS-1 clean-merge roundtrip (rc=0), OS-2 absent body (rc=41), OS-3 malformed body (rc=39). No OS test exercises an undocumented rc. |
| A-7 | ENG-117 117-B and 117-C pin the halt-comment defect tokens at `bin/run-stage-test.sh:5955-5999` | verified | Read of `bin/run-stage-test.sh:5955-5999` — 117-B asserts `Defect: qa-payload-missing` in halt body; 117-C asserts `Defect: qa-payload-malformed`. |
| A-8 | `_validate_qa_payload` has a `*)` arm at `bin/run-stage.sh:2129-2136` that emits `unexpected-rc` (distinct defect, not silent relabel) | verified | Read of `bin/run-stage.sh:2129-2136` — `*)` body emits `defect="unexpected-rc"` and includes `rc=$rc` in the diagnostic message. |
| A-9 | ENG-101 is the canonical defensive-code restraint principle source | verified | Read of `docs/brainstorms/2026-05-15-eng-101-prompt-side-defensive-code-restraint-clause-for-implement-review-agents-design.md:10-35` — quotes the system-prompt rule and operationalises it for the implement and review agents. |
| A-10 | The harness has no formal ADR registry; brainstorm docs are the decision record | verified | Read of `docs/` — listing shows `architecture.md assumptions.md brainstorms/ configuration.md cost.md demos install.md operations.md pipeline-vocabulary.md pipeline-vocabulary.template.md plans/ runbooks/ security.md`; no `adr/` or `decisions.md`. ENG-101 brainstorm §3 confirms this explicitly. |
| A-11 | OS-6b at `bin/run-stage-test.sh:9905-9910` is the precedent AST-style grep pattern for the same function body | verified | Read of `bin/run-stage-test.sh:9905-9910` — uses `awk '/^_merge_qa_payload_envelope\(\) \{/,/^\}/'` to extract the function body for greppable assertions. The proposed OS-1 mirrors this shape exactly. |
| A-12 | Pre-commit hook (`.githooks/pre-commit`) iterates `bin/*-test.sh` and `run-stage` is not in `KNOWN_BROKEN` | assumed | Project-profile addendum states the hook globs all `bin/*-test.sh` and runs them. `KNOWN_BROKEN` per the profile contains `eng-81-reproducer, mutex, render-pr-body, render-prompt-slug`. The new OS-1 test sits inside `run-stage-test.sh` (already in the suite) — no new test file needed. Verify during implementation by running `bash .githooks/pre-commit` on a clean main. |
| A-13 | `partition_dirty_paths` permits writes to `bin/run-stage.sh` and `bin/run-stage-test.sh` on the `implementing` stage | assumed | CLAUDE.md "File layout" section grants the implementing stage write access to `bin/`; the project-profile's `## File layout` lists `bin/` as the canonical script directory. Verify during plan/implementation that scope-sweep does not classify the diff as leaked-in-scope. |
| A-14 | The two-line halt-body change (empty Defect:) for hypothetical undocumented rc is operator-acceptable | assumed | This case fires only on a `merge_artifact_envelope` contract violation, which the pre-commit suite catches at PR time. In production: empty Defect with raw stderr containing `rc=N` is a louder signal than the current silent relabel. Operator review of the runbook (`docs/runbooks/recovery.md` §15) during implementation can confirm; no documented qa-payload halt today asserts a non-empty defect via runbook prose. |

### Codebase-fact verification

All named code artifacts referenced above were verified by
opening the file and quoting a `path:line` reference:

- `_merge_qa_payload_envelope` — `bin/run-stage.sh:2089-2112`
- Case statement under test — `bin/run-stage.sh:2102-2106`
- `merge_artifact_envelope` (callee) — `bin/common.sh:713-744`
- Helper header documenting closed rc set — `bin/common.sh:700-712`
- rc=0 guard — `bin/run-stage.sh:2100`
- `_post_qa_payload_halt` — `bin/run-stage.sh:2142-2150`
- `_validate_qa_payload` (the asymmetric callsite) — `bin/run-stage.sh:2118-2137`
- ENG-117 117-B test — `bin/run-stage-test.sh:5955-5977`
- ENG-117 117-C test — `bin/run-stage-test.sh:5979-5999`
- ENG-203 OS-1 test — `bin/run-stage-test.sh:9740-9767`
- ENG-203 OS-2 test — `bin/run-stage-test.sh:9769-9787`
- ENG-203 OS-3 test — `bin/run-stage-test.sh:9789-9807`
- ENG-203 OS-6b grep precedent — `bin/run-stage-test.sh:9905-9910`
- ENG-101 brainstorm overview citing the system-prompt rule — `docs/brainstorms/2026-05-15-eng-101-prompt-side-defensive-code-restraint-clause-for-implement-review-agents-design.md:10-35`

The proposed ENG-213 OS-1 test is the only new artifact;
it is described as a regression-pin block in D-003 with the
literal bash text. It mirrors OS-6b's `awk` extraction and
glob-match assertion shape.

## 10. Persona review

Six personas were run in order: design → security → scope →
coherence → product → feasibility (gating).

### Persona 1 — design (PASS)

**Verdict.** PASS.

**Strengths.**

- One-decision, one-file PR with a tight scope boundary
  (D-002 explicitly enumerates the no-touch surfaces).
- The asymmetry argument between `_merge_qa_payload_envelope`
  and `_validate_qa_payload` (OQ-1, D-001) is the load-bearing
  design judgement — both could plausibly have the same shape;
  the brainstorm picks them apart on the trust-boundary axis
  rather than treating the deferred finding as a mechanical
  diff. That's the right level of design care.
- D-003's shape-pin test acknowledges its cost (textual
  coupling) and justifies it (the case-statement is project-
  idiomatic; refactor cost is realistic).

**No P0/P1 findings.**

### Persona 2 — security (PASS)

**Verdict.** PASS.

**Surface review.**

- No new user-facing input. No new env var reads. No new
  shell-quoting context. The deleted line is a static defect
  string assignment; no agent-controlled data flows through
  it before or after the change.
- The empty-defect halt comment in the hypothetical
  contract-violation case still routes through
  `bash bin/linear.sh add-comment` (the
  `_post_qa_payload_halt` callsite at `bin/run-stage.sh:2149`),
  which auto-injects the dispatch-id meta marker (ENG-87
  contract). No envelope bypass.
- The added shape-pin test (`bash bin/run-stage-test.sh`)
  reads `bin/run-stage.sh` via `awk` — no `eval`, no
  command substitution on file content.

**Adversarial check — could a malicious agent exploit the
empty-defect halt?** No. The defect string is consumed only
by `_post_qa_payload_halt`'s body construction (`bin/run-stage.sh:2147`),
which `printf`'s it into a fixed format string. An empty
defect renders as `- Defect: ` (trailing space) — no escape,
no parse-hijack, no exfiltration channel. The agent has no
way to force an undocumented rc from `merge_artifact_envelope`
unless they also corrupt `bin/common.sh`, which is outside
the agent's stage-allowlist.

**No P0/P1 findings.**

### Persona 3 — scope (PASS)

**Verdict.** PASS.

**Scope check.**

- Linear-stated scope: drop the `*)` arm at
  `bin/run-stage.sh:2102-2106` (deferred from ENG-203).
- Brainstorm scope: D-001 (drop the arm) + D-002 (no
  companion edits) + D-003 (one regression-pin test).
- Outside scope: `_validate_qa_payload`'s `*)` arm (OQ-1
  defers explicitly), generic case-shape detective (OQ-2
  defers explicitly), runbook updates (OQ-4 defers
  explicitly).

**Sub-axis — subsystems touched.** One (`orchestrator` —
just `bin/run-stage.sh` + its sibling test). Below the 3+
"split before filing" threshold from CLAUDE.md.

**Sub-axis — independent design decisions.** One (drop the
arm — the no-sentinel choice in D-001 is a sub-decision of
that decision, not an independent one).

**No P0/P1 findings.**

### Persona 4 — coherence (PASS)

**Verdict.** PASS.

**Coherence with existing patterns.**

- Naming: new test block titled `ENG-213 OS-1` — mirrors
  ENG-117 117-B/-C, ENG-203 OS-1..OS-8, ENG-191 ledger
  tests. Same prefix convention.
- Test placement: `bin/run-stage-test.sh` — sibling tests
  for `_merge_qa_payload_envelope` already live there.
- Pattern coherence: OS-6b at `bin/run-stage-test.sh:9905-9910`
  is the named precedent for AST-style grep on the same
  function body; OS-1 reuses the same `awk` extraction
  shape verbatim.
- The decision to keep `_validate_qa_payload`'s `*)` arm
  (OQ-1) is coherent with the broader principle in
  ENG-101's boundary-validation heuristic — defense at
  trust boundaries, no defense at internal call sites.

**One coherence note (not a finding).** The brainstorm
header chose `## 10. Persona review` to mirror the ENG-203
brainstorm pattern (the doc-review skill's standard
section). Confirmed by spot-check of three other
brainstorms (`2026-06-16-eng-203-…`, `2026-06-14-eng-118-…`,
`2026-06-13-eng-190-…`) — same `## N. Persona review`
heading idiom in each.

**No P0/P1 findings.**

### Persona 5 — product (PASS)

**Verdict.** PASS.

**Product surface.**

- User-visible? No. Halt-comment shape changes only for the
  hypothetical contract-violation case (empty Defect: vs
  silent-relabel `qa-payload-malformed`) — that case does
  not fire in production today.
- Operator-visible? Slightly louder forensic signal on the
  hypothetical case (raw rc in stderr, empty Defect line);
  no change on every documented case. Net positive.
- Pipeline behaviour? Unchanged for every documented rc.

**Outcome alignment with ENG-191 deferred-majors loop.**
The whole point of ENG-191's selective-exit + ENG-193's
auto-create-follow-up is that small polish items DO ship
in a tight follow-up cycle. ENG-213 is the first
deferred-majors-auto-created ticket to brainstorm. Shipping
it cleanly closes the loop and validates the workflow.

**No P0/P1 findings.**

### Persona 6 — feasibility (gating — PASS, zero P0)

**Verdict.** PASS. Zero P0 findings.

**Codebase-fact verification.** Every named artifact was
checked against current code with a `path:line` quote
(§9 "Codebase-fact verification"). All 14 assumptions in
the Assumption Inventory carry a verification status; the
three "assumed" entries (A-12, A-13, A-14) are flagged for
verification during implementation and do not block
brainstorm-stage progression (per rule B-001's intent —
"assumed" is acceptable when the file to verify against is
named and the check is mechanical).

**No phantom methods.** No invented function names. The
proposed OS-1 test references `awk`, `bin/run-stage.sh`,
and `merge_artifact_envelope` — all real. The proposed
edit deletes one existing line at a precise location.

**No phantom helpers.** No call to `common.sh` helpers
that do not exist. No reference to schema fields that do
not exist.

**No phantom CLAUDE.md sections.** "When wiring a new
script", "File layout", "Failure-mode quick reference",
"ticket-sizing rubric" — all real sections of CLAUDE.md
(verified by spot-grep). The brainstorm cites them by
quoted phrase; no fabricated guidance.

**No phantom ADRs.** ENG-101 is the only cross-referenced
brainstorm-as-ADR; verified at
`docs/brainstorms/2026-05-15-eng-101-…`. ENG-87, ENG-117,
ENG-191, ENG-193, ENG-203 are cited as named tickets
without quoting non-existent content (e.g. no reference to
a specific section of ENG-87 that doesn't exist).

**No P0 findings.**

### Gate

5/6 PASS required; **6/6 PASS** achieved.
Feasibility P0 floor: **0 P0 findings**.
Proceeding to planning.
