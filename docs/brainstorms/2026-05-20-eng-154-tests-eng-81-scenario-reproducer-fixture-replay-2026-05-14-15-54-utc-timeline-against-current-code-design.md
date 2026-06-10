---
linear: ENG-154
title: ENG-81 scenario reproducer fixture — replay 2026-05-14 15:54 UTC timeline against current code
date: 2026-05-20
status: draft
---

# ENG-81 scenario reproducer fixture — replay 2026-05-14 15:54 UTC timeline against current code

## 1. Overview / Problem

The 2026-05-14 15:54 UTC incident on ENG-81 is the canonical instance the
ledger-fix family (ENG-104 umbrella; sub-tickets ENG-110, ENG-111, ENG-112,
plus the header/verdict-split/guards-reason follow-ups) was scoped against.
Within ~30 seconds an agent's `verdict pass` self-claim landed adjacent to
an orchestrator-side counter bump, then adjacent to a halt verdict whose
dedup-update silently rewrote a prior halt comment hours upstream. To
operators scanning the Linear feed top-down, the chronological story read
as "agent claimed pass → orchestrator bumped → halted hours ago," with
the load-bearing halt comment's `createdAt` pinned far above the current
moment.

ENG-104 closed as subsumed by the four sub-tickets. ENG-104's acceptance
criterion #7 — a regression fixture replaying the incident end-to-end —
did not land with any of the subs. ENG-154 ships it as the canonical
regression test for the ledger contract.

The fixture is **dependency-aware**: it pins what the ledger ALREADY
delivers today (three distinct chronological comments produced by the
three writer calls in fresh-store conditions; ENG-87 dispatch marker
on every body) and gates the assertions whose load-bearing tokens
haven't yet shipped (header line shape with stage+dispatch-id+iso-ts+actor;
agent-side `pipeline: stage-completion-claim` marker;
orchestrator-side `pipeline: verdict … author=orchestrator` marker;
`reason=…` / `threshold=N>=M` fields on counter-bump halts) behind
feature-flag probes. As each dependency ships the corresponding probe
trips and the assertion un-skips without rewriting the fixture setup.

**The "halt rewritten hours upstream" failure mode** is captured by a
separate test case (R-2 below) that pre-seeds a prior halt and asserts
the bug is *observable today* — `createdAt` of the canonical halt is
preserved across the third writer's in-place rewrite. Once a dependency
ticket changes the halt verdict's writer surface (append-only rather
than sig-deduped, per the verdict-split ticket), the bug-observation
assertion *inverts*: the probe trips, R-2's expectation flips to "three
distinct fresh comments." See D-004/D-007 below.

Acceptance criteria from the ticket, mapped to the design below:

| AC | What | Where covered |
|---|---|---|
| #1 | New test file (or section) commits and runs green against current code (skipping not-yet-shipped assertions). | D-001, D-005, §3.2 |
| #2 | Test is wired into `.githooks/pre-commit`'s test sweep. | D-001 (filename ends `-test.sh`; the hook globs at `.githooks/pre-commit:154`) |
| #3 | Test file header documents the ENG-81 incident, the date, and the four dependency tickets. | D-001 (header block) |
| #4 | As each dependency ticket lands, the corresponding assertion un-skips and the test extends without rewriting fixture setup. | D-005 (feature-flag probes), D-002 (in-memory comment store), §3.4 |

Out of scope (per the ticket):

- **The underlying behavioural changes.** Header line, verdict-split,
  guards-reason+threshold, and any of the four sibling tickets' code
  changes are owned by those tickets, not by ENG-154.
- **A live Linear network call.** The fixture exercises
  `add_or_update_comment` against a stubbed `linear_query` in the
  source-and-stub idiom that ENG-63 / ENG-87 / ENG-111 established
  in `bin/linear-test.sh:512-969`.
- **Refactoring the existing ENG-63/87/110/111 test blocks.** ENG-154
  adds a new test block; it does not edit ENG-111's B-001..B-006 or
  ENG-87's L-* / QA-* blocks.

## 2. Decisions

### D-001. New file `bin/eng-81-reproducer-test.sh`, not a section in `bin/linear-test.sh`.

**Decision.** Add a self-contained test file at
`bin/eng-81-reproducer-test.sh`. The file follows the source-and-stub
idiom (`#!/usr/bin/env bash`; `set -euo pipefail`; minimal target-repo
scaffold via `mktemp`; source `bin/linear.sh`; post-source override
`linear_query` + `_resolve_issue_uuid`; `PIPELINE_DRY_RUN=0` flip;
`pass_at` / `fail_at` accumulators; final `RESULTS: N passed, M failed`
summary). The header docblock names the incident date (2026-05-14 15:54
UTC), the issue (ENG-81), and the four dependency tickets whose acceptance
criteria the test enforces (header-line ticket, verdict-split ticket,
guards-reason+threshold ticket, and the ENG-104 umbrella; concrete IDs
filled in by the test file based on what has shipped at implement time).

**Why a separate file (not an in-place section in `bin/linear-test.sh`).**
Three load-bearing differences from ENG-111 D-006's "extend
linear-test.sh" precedent:

1. **Subject under test.** ENG-111 narrowly exercised
   `add_or_update_comment`'s breadcrumb branch — one function, one
   sig, one mutation. ENG-154 exercises the full ledger contract end-to-end:
   THREE writers producing THREE comments in sequence (agent self-claim
   → orchestrator counter bump → orchestrator halt verdict), with chronological
   correctness as the load-bearing invariant. The setup machinery is fixture-
   scaled (a synthetic comment store with `createdAt` tracking), not function-
   scaled.
2. **Dependency-aware lifecycle.** ENG-154 extends as four sibling tickets
   land. A separate file localises that churn — every dependency-ticket
   diff lands as edits to one file; the file's `_skipped_for` counter
   surfaces precisely which assertions are gated. Embedding inside
   `linear-test.sh` (1458 lines today) would scatter four future diffs
   across a large test surface that already serves ENG-41/55/63/87/110/111.
3. **Discoverability.** "ENG-81 reproducer" is what an operator searches
   for when a future regression replays this class. A file named
   `eng-81-reproducer-test.sh` is the discoverable artifact; the ticket's
   "or new file" clause explicitly allows this shape.

The ticket's body literally allows either shape. ENG-154 picks the
separate-file shape on the criteria above.

**Wire-up.** The pre-commit hook auto-globs `bin/*-test.sh`
(`.githooks/pre-commit:154` — `for t in bin/*-test.sh; do …`). A new
file ending in `-test.sh` is auto-wired into the sweep with no
explicit edit anywhere. AC #2 satisfied by filename alone.

**Rejected — embed as ENG-154 block inside `bin/linear-test.sh:970+`.**
Three-comment fixtures with a chronological comment store materially
inflate `linear-test.sh`'s setup surface. The dependency-aware lifecycle
forces four future edits to the same file alongside its unrelated
existing blocks. The discoverability argument also fails — a future
operator searching "ENG-81 regression" grep'ing file names finds nothing.

**Rejected — `bin/eng-154-reproducer-test.sh`** (named after the test
ticket, not the incident). The fixture is replaying the ENG-81 timeline;
the test ticket number is incidental. `eng-81-reproducer` is the
discoverable name. The slug convention is harness-internal (filename in
`bin/`, never seen by Linear's per-ticket scope check), so the
non-ENG-154 slug here is safe — there's no `partition_dirty_paths`
basename gate on test filenames in `bin/`, only on docs/ paths. The
ENG-154 token does still need to appear in the doc filename — handled
by this brainstorm's filename.

### D-002. Fixture sets up a tempdir-backed JSON comment store with `createdAt` tracking, not a Linear-API mock.

**Decision.** The fixture maintains a JSON document on disk under
the per-test `mktemp -d` tempdir (path: `$_TS/comment-store.json`)
that models the Linear comment store as an ordered append-only
sequence. Storage on disk (via atomic `jq … > tmp && mv`) lets the
stubbed `linear_query` read consistent state across calls without
sharing bash globals. Each entry is `{id, body, createdAt}`. The
`linear_query` stub:

- For comments-fetch queries (`comments(first: 50, …)`) returns the
  current store as `{data: {issue: {comments: {nodes: [...] }}}}`.
- For `commentCreate` mutations appends a new entry with a fresh id
  (`cmt-<seq>` where `seq` is a monotonic counter) and a fresh
  `createdAt` (read from `date -u +%Y-%m-%dT%H:%M:%S.%NZ` — millisecond
  precision so three commits in 30s remain distinguishable).
- For `commentUpdate` mutations finds the existing entry by id and
  rewrites `body` in place — `createdAt` is **preserved** (this is the
  bug we are pinning the regression against).

After all three writer calls complete, the fixture inspects the store
and asserts the invariants in §3.2.

**Why a stateful store, not a per-call capture file.** The ENG-63/111
fixtures use a flat `_capture_file` that accumulates body strings via
`>>` redirection. That pattern is sufficient for asserting "one body
posted" or "two bodies posted with content X+Y" but cannot model the
`commentUpdate`-preserves-`createdAt` failure mode — every entry in a
flat capture is chronologically distinct by construction (each line is
a fresh write). To assert "the halt comment was an in-place update of
a prior canonical, so its `createdAt` did NOT advance," the fixture
must track create vs update separately. The store models the Linear
API contract; the assertions read from the model.

**Why `createdAt` (not `updatedAt`) is the load-bearing field.**
ENG-111's brainstorm §1 already establishes that Linear's web UI groups
by `createdAt`, not `updatedAt`, and that ENG-63's footer rotation
moves `updatedAt` but not `createdAt`. The ENG-81 incident's failure
mode is precisely this — the operator's top-down scan reads
`createdAt` order, sees the halt pinned hours upstream, misses the
in-place rewrite. The fixture must assert against `createdAt`.

**Rejected — exercise the real Linear API in a sandbox issue.** Network
flake, token management, and append-only-thread-litter (a probe
leaves a permanent comment on a real issue) make this a non-starter
for a CI gate. The harness's `add_or_update_comment` is the subject
under test, not Linear itself; mocking Linear's `commentCreate` /
`commentUpdate` shape is sufficient.

**Rejected — extend ENG-111's `_eng111_capture_file` pattern with a
sidecar `createdAt` array.** Two parallel data structures (one flat
file, one bash array) are harder to reason about than a single
ordered store. The fixture is replaying a timeline; one timeline
structure is the right shape.

### D-003. Three writer calls drive the fixture: agent self-claim PASS, orchestrator counter bump, orchestrator halt verdict. Two test cases (R-1 clean-store, R-2 pre-seeded prior halt) cover today's contract and today's bug separately.

**Decision.** The fixture's `replay_timeline()` helper makes three
chained calls in order:

1. **Agent self-claim (PASS).** Invokes `add_comment "$issue"
   --body "$pass_body"` under `PIPELINE_WRITER=agent
   PIPELINE_DISPATCH_ID=ENG-81R-d0001 PIPELINE_STAGE=implementing`.
   The body shape mirrors what the implement agent emits today (a
   `<!-- pipeline: verdict result=pass stage=implementing -->`
   marker plus a short prose summary, plus the auto-injected
   dispatch marker from ENG-87). After the verdict-split ticket
   ships, the body shape evolves to `<!-- pipeline:
   stage-completion-claim … -->`; D-005's feature-flag probe drives
   that swap without rewriting the helper.
2. **Orchestrator counter bump.** Invokes `add_comment "$issue"
   --body "$bump_body"` under `PIPELINE_WRITER=orchestrator
   PIPELINE_DISPATCH_ID=ENG-81R-d0001 PIPELINE_STAGE=implementing`.
   **Today** the counter bump does not have a dedicated `pipeline: …`
   marker — it lives in `bin/guards.sh` and is observable through the
   halt verdict's body. The fixture's call-2 uses `add_comment`
   (append-only) with a body that prose-narrates "Implement rejection
   counter: N of M" — a faithful synthetic of what an orchestrator-side
   bump comment WOULD look like under the post-split contract, but
   posted via the append-only path so no sig collision occurs against
   any current code surface. The body shape (reason + threshold) is
   gated by `_probe_guards_reason` (D-005); today the call's body is
   prose-only.
3. **Orchestrator halt verdict.** Invokes `add_or_update_comment
   "halt/implementing/$issue" "$issue" --body "$halt_body"` under
   the same `PIPELINE_WRITER=orchestrator` env. The body carries
   `<!-- pipeline: verdict result=halt reason=implement_rejection -->`.
   Sig `halt/implementing/<issue>` is the load-bearing canonical
   today (`bin/classify-failure.sh:146`, ENG-111 brainstorm A-002).
   In R-1 (clean-store) the store has no prior `halt/…` entry, so
   `add_or_update_comment` falls through to `commentCreate`; the
   third entry is a fresh chronological comment. In R-2 (pre-seeded)
   the store carries a prior halt under the same sig from 3 hours
   ago; `add_or_update_comment` hits the `commentUpdate` branch,
   preserving the pre-seed's `createdAt` — pinning the ENG-81
   failure mode for observation.

The fixture sleeps a small delay (~20ms) between calls so
`createdAt` ticks distinguishably for the create-path entries.

**Why three distinct writer lanes in one fixture.** The ENG-81 timeline
is the cross-lane mishmash. A fixture that only exercised agent writes
(or only orchestrator writes) would miss the contract surface ENG-104
was scoped against — three actors, three sigs, three chronologies,
one operator-facing feed. The PIPELINE_WRITER env swap on each call
exercises the lane-fence's per-class allow-decisions through the
canonical sigs.

**Why two test cases (R-1 and R-2), not one.** R-1 (clean store) is
the contract assertion: post-fix, three writer calls should produce
three distinct chronological comments. Today this holds because no
sig collides with the fresh store. The fixture pins this baseline so a
future refactor that introduces a regressive in-place rewrite on R-1
trips the gate.
R-2 (pre-seeded prior halt) is the bug observation: today's
`add_or_update_comment` rewrites the prior halt in place, preserving
its `createdAt` from 3 hours ago. R-2's primary P0 assertion today is
"the bug is observable" — i.e., the pre-seed entry's `createdAt` is
unchanged after call-3. When the verdict-split (or equivalent) dep
ticket lands and the halt verdict moves to append-only writing,
R-2's probe trips and the assertion inverts to "createdAt of the
third writer entry is fresh (now), not 3h-ago." Two cases, two
contracts, both ticking through the same `replay_timeline` machinery.

**Pre-seed mechanics (R-2 only).** The pre-seed step writes directly
to the in-memory store (NOT via `add_or_update_comment`) with a
`createdAt` set hours before the fixture's "now," via
`date -u -v-3H +%Y-%m-%dT%H:%M:%SZ` (macOS BSD `date` syntax —
in production at `bin/halt-sprawl-test.sh:281,285`, `bin/status.sh:227,306`,
`bin/run-retrospective-local.sh:46`).

**Rejected — replay the timeline via three separate test invocations
sharing a state file on disk.** Inter-test state on disk forces
ordering between test files and introduces cleanup churn. The fixture
is one self-contained run.

**Rejected — drive the timeline directly via `linear_query` stub
arms (skipping `add_comment` and `add_or_update_comment`).** That
would test the comment store, not the contract. The whole point is
to assert that the chokepoint functions produce the right three
distinct comments under the stated inputs.

### D-004. Assertions are tier-gated: P0 (load-bearing today), P1 (load-bearing after each dependency lands), P2 (audit-only).

**Decision.** The fixture's assertions are organised into three tiers.
P0 runs unconditionally and pins what the **current** code's contract
requires. P1 runs gated by a feature-flag probe per dependency ticket;
each P1 un-skips when its probe trips. P2 runs only when an operator
sets a `ENG_81R_AUDIT=1` env var — surfaces information about cross-cutting
concerns the test does not gate on.

**P0 (unconditional, pins today's behaviour):**

For **R-1 (clean store, no prior halt)**:

- **P0-1 (R-1).** Three distinct entries in the comment store after
  replay (no in-place rewrite). Today this PASSES — each writer call
  hits the create path because no sig collides.
  *Failure mode pinned:* a future refactor that routes the agent's
  PASS or the bump through a sig that collides with itself, silently
  rewriting across re-fires.
- **P0-2 (R-1).** `createdAt` order matches dispatch order (PASS <
  bump < halt). Today PASSES trivially because all three are
  create-path. Stated as strict inequalities on the store read.

For **R-2 (pre-seeded prior halt)**:

- **P0-3 (R-2, bug-observation today).** After the three writer
  calls, the pre-seed entry's `createdAt` is unchanged from the
  seed time (3h ago). This pins today's in-place-rewrite bug —
  call-3's `add_or_update_comment` hit the `commentUpdate` branch
  against the pre-seed sig. PASSES today by design.
  *Inverts on dep-ticket landing:* once the verdict-split (or
  sibling) ticket changes the halt verdict to append-only, this
  assertion's expectation flips — the pre-seed's `createdAt` is
  still preserved (commentUpdate didn't fire because there was no
  commentUpdate) AND a third writer entry appears with a fresh
  `createdAt`. The probe gates the inversion (D-005).

For both R-1 and R-2:

- **P0-4.** Each replay body carries the auto-injected ENG-87
  dispatch marker `<!-- meta: dispatch id=ENG-81R-d0001 stage=… -->`.
  Today PASSES because the chokepoint at `bin/linear.sh:514,595` is
  shipped.

**P1 (gated by per-dependency probes):**

- **P1-header.** Each of the three replay comments carries a header
  line of the form `**<stage>** <dispatch-id> <iso-ts> · author=<actor>`.
  Gated by probe: `_probe_header_line_supported`.
- **P1-completion-claim.** The agent's PASS body carries
  `<!-- pipeline: stage-completion-claim … -->` (not the legacy
  `<!-- pipeline: verdict result=pass … -->`). Gated by probe:
  `_probe_completion_claim_marker`.
- **P1-author-marker.** The halt body carries `author=orchestrator`
  inside its `<!-- pipeline: verdict … -->` marker. Gated by probe:
  `_probe_author_attribute`.
- **P1-reason-threshold.** The bump body carries
  `reason=<reason_token> threshold=N>=M` fields. Gated by probe:
  `_probe_guards_reason`.

**P2 (audit-only, opt-in via env):**

- **P2-breadcrumb.** When the halt's `commentUpdate` body genuinely
  differs from the pre-seeded body (it should — the new body carries
  a fresher dispatch-id marker), ENG-111's breadcrumb branch fires
  and posts a fourth chronological comment. The fixture asserts the
  store carries exactly that breadcrumb. This is REDUNDANT with
  ENG-111's B-002 but worth surfacing in the reproducer for
  cross-ticket observability — gated `ENG_81R_AUDIT=1` so it doesn't
  double-pay for the same assertion in the gating pre-commit run.

**Why three tiers, not two.** The ticket asks for "feature-flagged or
skipped" gating on assertions referencing not-yet-shipped tickets. P0
is the load-bearing today-pin (the only thing that gates the
pre-commit run); P1 is the lifecycle staircase the ticket explicitly
calls out. P2 captures cross-cutting overlap (the ENG-111 breadcrumb
fires inside this replay too) without forcing it into the gating
surface — operator-side observability via env, not test-side gating.

**Rejected — single tier with all assertions always-on, gating
failures only if dependency-ticket markers are present.** Conflates
"this assertion failed because the dependency hasn't shipped" with
"this assertion failed because the contract is broken." A pre-commit
operator reading "FAIL: header line missing on agent comment" cannot
distinguish the two states. Tiering with probes makes the gate's
verdict crisp.

**Rejected — two tiers (P0 + P1), no P2.** P2 covers the ENG-111
breadcrumb cross-pollination, which is genuine signal but not
load-bearing for ENG-154's contract. Audit-only opt-in is the right
shape — P2 lives in the file for future maintainers to find without
slowing the gate.

### D-005. Feature-flag probes are source-text greps against `bin/linear.sh`, `bin/pipeline.sh`, `bin/pipeline-events.json`, and the agent prompts.

**Decision.** Each P1 probe is a one-liner that inspects current
source for the presence of the dependency ticket's load-bearing
token. The probes are inverted: present = un-skip the assertion.
Each probe lives next to its tier guard at the top of the test file.

| Probe | Source check | Trips when… |
|---|---|---|
| `_probe_header_line_supported` | `[[ -f bin/run-stage.sh ]] && grep -qE '^[*]{2}.+[*]{2}.+author=' bin/run-stage.sh` (or the equivalent emit site) | header-line ticket ships and `post_completion_comment` emits the canonical header shape. |
| `_probe_completion_claim_marker` | `[[ -f bin/pipeline-events.json ]] && grep -qF 'stage-completion-claim' bin/pipeline-events.json` (the new event must be in the closed registry per ENG-60) | verdict-split ticket ships the marker. |
| `_probe_verdict_split_supported` | `[[ -f bin/pipeline-events.json ]] && grep -qF 'stage-completion-claim' bin/pipeline-events.json` (alias of the above — gates R-2's inverted assertion) | verdict-split ticket ships (halt verdict moves to append-only). |
| `_probe_author_attribute` | `[[ -f bin/pipeline.sh ]] && grep -qE 'author=(orchestrator\|agent\|classify)' bin/pipeline.sh` | author-attribute ticket ships. |
| `_probe_guards_reason` | `[[ -f bin/guards.sh ]] && grep -qE 'reason=[a-z_]+ threshold=' bin/guards.sh` (or wherever the bump emits) | guards-reason+threshold ticket ships. |

Each probe pre-asserts the target file's existence with `[[ -f ... ]]`
so a file rename (`bin/run-stage.sh` → `bin/run-stage/main.sh` etc.)
trips a distinct `BROKEN` state rather than silently SKIPping forever.
A `BROKEN` probe is logged as a P2 maintenance issue (visible in the
test output) but does not gate the suite (treated as a noisier SKIP).

Probes return 0 (un-skip) or non-zero (skip with a clear message
naming the dependency ticket and "still pending"). Output of a
skipped assertion is:

```
SKIP P1-header — <header-line-ticket-id-TBD> not shipped;
  _probe_header_line_supported did not find the header-line emit site in bin/run-stage.sh
```

The `<header-line-ticket-id-TBD>` placeholder is filled with the
actual Linear ticket ID at implement time (an ENG-154 implementer who
files the sibling tickets supplies the IDs at file-creation time;
if the sibling tickets are already filed, the IDs are filled directly).

**Why source-text greps (not env-var flags, not config-driven
toggles).** Each dependency ticket SHIPS the load-bearing token IN
THE SOURCE. The probe asks "does the source carry the token yet?"
and answers "yes/no" directly. Operators do not need to remember to
flip a flag after merging the dependency — the next pre-commit
auto-discovers the un-skip. This pattern matches `bin/dispatch-test.sh:2210,2231`'s
"SKIP if not present" precedent for environment-dependent guards
(e.g., `HARNESS_CONFIG` presence check).

**Why exact tokens (not regex-loose matches).** The probe must trip
ONLY when the dependency has actually shipped the contract surface.
A loose regex (e.g., `grep -qi 'completion'` in `bin/`) would trip
on existing `completion/<stage>/<issue>` sig strings. The probe needs
to anchor on the dependency-ticket-specific token — for
`stage-completion-claim` that's the literal hyphenated event name
inside `pipeline-events.json::stages` or its sibling registry.

**Probe maintenance contract.** When a dependency ticket lands, the
ticket-owner updates the probe to the exact token shape the ticket
shipped (file path may differ from the table above). ENG-154's
implementer codes the probes against the design's expected paths;
each dependency-ticket implementer is the natural reviewer for "does
this probe correctly detect my ship?"

**Rejected — single `$ENG_154_DEPS_SHIPPED` env var the operator
flips when all four deps ship.** Coarse-grained; an operator who
ships header-line but not the other three can't un-skip P1-header
without un-skipping the rest. The fixture lifecycle asks for
ticket-by-ticket un-skip; per-probe gates support that.

**Rejected — read a deps-status JSON file** (e.g., a hypothetical
`.pipeline-config/test-deps.json` listing each ticket as shipped:true/
false). Adds a file the operator must maintain in sync. Source-text
greps are self-maintaining: the dependency ticket lands its own
un-skip by definition.

### D-006. The fixture asserts each body is self-describing — readable in isolation — via three structural probes, not via a literal-string equality match.

**Decision.** The fixture's body-shape assertions test STRUCTURE,
not literal content. The three body-readability probes:

1. **Carries the per-stage `pipeline:` marker** with valid result
   tokens from `bin/pipeline-events.json::verdict_results`. Today
   the agent PASS carries `<!-- pipeline: verdict result=pass
   stage=implementing -->`; P1-completion-claim swaps the event
   name to `stage-completion-claim` once shipped. The probe uses
   `parse_pipeline_marker` (from `bin/common.sh`) to validate
   the marker's k=v shape.
2. **Carries the auto-injected ENG-87 dispatch marker**
   `<!-- meta: dispatch id=ENG-81R-d0001 stage=… -->`. This is
   load-bearing today (ENG-87 chokepoint is shipped) and the
   probe runs unconditionally as P0-4.
3. **The first non-blank prose line names the actor and the
   moment.** P1-header gates this; once shipped, the probe asserts
   the line shape matches the canonical header regex.

**Why structural assertions, not exact-string matches.** Exact-string
matches force the test to know the precise wording of every body —
fragile under any prose tweak. The fixture's contract is "three
distinct, self-describing comments readable in isolation," not "the
agent's body says the exact phrase X." Structural probes (markers
present, actors named, sigs honoured) capture the contract without
freezing the prose.

**Rejected — assert exact body contents per writer.** Locks in prose
that the dependency tickets will reshape. Every dependency-ticket diff
would force a body-string update in this test, defeating AC #4's
"no rewrite of fixture setup" promise.

### D-007. The fixture only uses Linear-side sigs that exist in current code today; future dep-ticket sigs are introduced by the dep ticket, not pre-assumed here.

**Decision.** The only sig the fixture references is
`halt/implementing/<issue>` — the load-bearing canonical that
`bin/classify-failure.sh:146` already emits today and that
`bin/linear.sh::add_or_update_comment` lookups already match
(A-012). The orchestrator counter bump in call-2 uses `add_comment`
(append-only) with no sig, sidestepping any sig-naming assumption.

**Why no sig invention.** ENG-154's ticket says "extends without
rewriting fixture setup" as dependency tickets land — that promise
is robust only if the fixture does not pre-commit to a sig naming
convention that the dependency ticket may diverge from. By keeping
the bump append-only, the only fixture surface a future dep ticket
touches is the body-shape probe (`_probe_guards_reason`) and the
gated assertion it un-skips. The sig and the writer-function choice
are not in ENG-154's surface.

If a future dep ticket splits the bump into its own sig'd comment
(`<some-sig>/<stage>/<issue>`), the new sig + writer-function lives
in that dep ticket's diff alongside the un-skipping of P1's
reason+threshold body-shape assertion. ENG-154 ships neither.

**Rejected — pre-commit to `counter-bump/<stage>/<issue>` as
"the documented-but-future-tense canonical."** Was the iter-1
position. Persona review flagged it as out-of-scope contract
prescription (scope persona P0). Walked back here.

### D-008. Per-test-case isolation; one shared replay across assertion tiers within a case.

**Decision.** Two scopes of state:

- **Across test cases** (e.g., R-1 → R-2): clean slate. Setup
  `_eng81r_reset_store()` truncates the in-memory comment store;
  teardown unsets PIPELINE_WRITER / PIPELINE_DISPATCH_ID /
  PIPELINE_STAGE. R-2's case picks up no residue from R-1's
  replay.
- **Within a test case** (P0 + P1 + P2 tiers): shared. One
  `replay_timeline()` call drives the three writer calls; each
  tier's assertions are read-only against the post-replay store.
  Tiers do not re-run the replay.

This mirrors ENG-111 B-001..B-006 (each test case truncates
`_eng111_capture_file` between cases; assertions within a case
read the same capture) and the ENG-87 L-* / QA-* blocks' per-case
env unset pattern.

**Why shared replay within a case.** The replay is the SOURCE for
all assertions in the case. Re-running the replay between tiers
would (a) double-emit metrics, (b) double-load Linear's
`commentCreate` stub, (c) defeat the P0-3-and-then-P1-x
ordering-of-events that the gated assertions sometimes rely on.
Read-only per-tier inspection of one replay is the clean shape.

**Why clean slate between cases.** Two cases differ by pre-seed
state. R-1 must run against a truly empty store to validate the
clean-store contract; R-2 must run with the pre-seed entry as the
ONLY prior comment. Sharing state would muddle both.

**Rejected — re-run `replay_timeline()` per tier within a case** (was
the iter-1 mis-stated alternative). Replaced by the above explicit
two-scope contract.

**Rejected — share state across cases (one shared store for R-1 +
R-2).** Would pollute R-1's clean-store assertions with R-2's
pre-seed. Per-case reset is load-bearing.

### D-009. The test file's header documents the dependency lifecycle as descriptive metadata, not prescriptive contract for unshipped tickets.

**Decision.** The header docblock of `bin/eng-81-reproducer-test.sh`
carries a section titled "Dependency lifecycle (descriptive)" naming
the four probes, the load-bearing token each looks for in current
source, and a note: when a dependency ticket lands a probe-tripping
contract surface, the dependency ticket's implementer is responsible
for un-skipping the corresponding P1 assertion as part of their own
ticket's acceptance criteria (the file's placeholder bodies make this
literal). The header does NOT prescribe what the dependency ticket
must ship — it only describes what the probe detects.

A concrete sentence for the dependency-ticket implementer (which an
ENG-154 implementer should also copy into each dep ticket's body
when filing): "**Dependency-ticket AC:** fill the placeholder body
in `bin/eng-81-reproducer-test.sh::<probe-name>` to assert the
contract surface this ticket ships. Probe trip without a filled
assertion is a no-op SKIP-as-PASS and defeats the gate's purpose."

**Why descriptive, not prescriptive.** Scope persona (iter-1) flagged
that prescribing contract surface for unshipped tickets from inside
a test fixture exceeds ENG-154's autonomy boundary. Descriptive
metadata documents the lifecycle without forcing a contract on
future work — the dep ticket implementer chooses the contract; the
probe detects it; the placeholder asks them to fill in the
assertion.

**Why this lives in the test file's header, not in a runbook.** The
test is the artifact; the lifecycle metadata is one-grep-away from
the assertions.

**Rejected — separate `docs/runbooks/eng-81-reproducer.md`.** Adds a
file the operator must hunt for; the test file's header is the
discoverable site.

**Rejected — iter-1 "canonical update site when a probe needs to
evolve" prescriptive framing.** Scope persona flagged. Walked back.

## 3. Architecture

### 3.1 Files modified / created

| File | Change |
|---|---|
| `bin/eng-81-reproducer-test.sh` | **NEW.** ~250-350 lines: header docblock with dependency lifecycle contract; minimal target-repo scaffold; source `bin/linear.sh`; in-memory comment store helpers; `replay_timeline()` driver; probes; tier-gated assertions; `RESULTS:` summary. |
| `.githooks/pre-commit` | **No change.** Auto-glob at `:154` picks up the new file by filename. |
| `bin/pipeline-events.json` | **No change.** Reproducer reads the registry; does not extend it. |
| `bin/linear.sh` | **No change.** Subject under test. |
| `docs/brainstorms/2026-05-20-eng-154-…-design.md` | **NEW.** This document. |

### 3.2 Fixture shape (pseudocode)

```bash
#!/usr/bin/env bash
# bin/eng-81-reproducer-test.sh
#
# ENG-81 scenario reproducer — replays the 2026-05-14 15:54 UTC ledger
# incident against the current code. Pins the chronological-correctness
# invariant the ENG-104 ledger family was scoped against.
#
# Incident: agent self-claim PASS landed adjacent to orchestrator
# counter bump adjacent to a halt verdict whose dedup-update silently
# rewrote a halt comment hours upstream.
#
# ENG-104 umbrella sub-tickets (6 total):
#   Shipped (their contract surfaces already pinned by P0-4 / today's R-1 P0-1):
#     - ENG-110 (dispatch-id stamp on every comment write)
#     - ENG-111 (breadcrumb on dedup body-change)
#     - ENG-112 (ledger schema in pipeline-events.json)
#   Pending (each gates one P1 assertion via a probe — see "Dependency
#   lifecycle (descriptive)" below):
#     - <header-line-ticket-id-TBD>
#     - <verdict-split-ticket-id-TBD>
#     - <guards-reason+threshold-ticket-id-TBD>
#
# The ticket body cites "four sibling tickets" — that is the count from
# ENG-154's filing moment, before ENG-110/111/112 had shipped. With those
# three landed, ENG-154 today gates against the THREE unshipped subs via
# the P1 probes; the THREE shipped subs are pinned via P0 directly.
#
# Dependency lifecycle (see D-005 in
# docs/brainstorms/2026-05-20-eng-154-…-design.md):
#   When a dependency ticket ships its load-bearing token, the matching
#   _probe_* function below trips and the corresponding P1 assertion
#   un-skips. No fixture setup edits required.

set -euo pipefail
SCRIPT_DIR_REAL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Scaffold (mirrors bin/linear-test.sh:11-87) ──────────────────────
export PIPELINE_DRY_RUN=0
: "${LINEAR_API_KEY:=test-mock-key}"; export LINEAR_API_KEY
export PROJECT_SLUG="${PROJECT_SLUG:-eng-81r-slug}"
_TT="$(mktemp -d)"; _TS="$(mktemp -d)"
# … (temp-path safety guard + trap; same idiom as linear-test.sh:22-40)
export TARGET_REPO="$_TT"
mkdir -p "$TARGET_REPO/.pipeline-config/schemas"
# … config.json + linear-ids.json (copied verbatim from linear-test.sh:48-71)
export HARNESS_STATE_DIR="$_TS/state"
export PROJECT_STATE_DIR="$HARNESS_STATE_DIR/$PROJECT_SLUG"
mkdir -p "$PROJECT_STATE_DIR/metrics"
: > "$PROJECT_STATE_DIR/metrics/events.jsonl"

source "$SCRIPT_DIR_REAL/linear.sh"
SCRIPT_DIR="$SCRIPT_DIR_REAL"  # so metrics.sh resolves via real bin/

# ─── In-memory comment store ──────────────────────────────────────────
# JSON document on disk so jq can update it atomically and the stub
# linear_query can read it in a single command. File path lives under
# the tempdir so the EXIT trap cleans it.
_STORE="$_TS/comment-store.json"
printf '%s' '{"comments":[],"seq":0}' > "$_STORE"

_store_add_create() {
  local body="$1" iso="$2"
  jq --arg body "$body" --arg iso "$iso" '
    .seq = (.seq + 1) |
    .comments += [{
      id: ("cmt-" + (.seq | tostring)),
      body: $body,
      createdAt: $iso
    }]
  ' "$_STORE" > "$_STORE.tmp" && mv "$_STORE.tmp" "$_STORE"
}

_store_update_by_id() {
  local id="$1" body="$2"
  # commentUpdate preserves createdAt — the load-bearing failure mode.
  jq --arg id "$id" --arg body "$body" '
    .comments |= map(if .id == $id then .body = $body else . end)
  ' "$_STORE" > "$_STORE.tmp" && mv "$_STORE.tmp" "$_STORE"
}

_store_preseed_halt() {
  # Pre-seed a "hours upstream" halt under sig halt/implementing/<issue>.
  local sig="$1" issue="$2" hours_ago="${3:-3}"
  local iso
  iso="$(date -u -v-"${hours_ago}"H +%Y-%m-%dT%H:%M:%SZ)"
  local body
  body=$'Halt body line\n\n<!-- meta: dedup key='"$sig"$' -->'
  _store_add_create "$body" "$iso"
}

# ─── linear_query stub ────────────────────────────────────────────────
# Reads/writes $_STORE. Distinguishes commentCreate, commentUpdate, and
# the 50-comment fetch query by regex on the GraphQL string. _resolve_
# issue_uuid is stubbed to a literal so the function reaches the
# existing-id path.
_resolve_issue_uuid() { printf 'uuid-mock'; }

linear_query() {
  local query="$1" variables="${2:-{\}}"
  local now_iso
  now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [[ "$query" =~ commentCreate ]]; then
    local body; body="$(jq -r '.body' <<<"$variables")"
    # Sleep a beat so subsequent creates have distinguishable createdAt.
    perl -e 'select(undef,undef,undef,0.02)'  # 20ms
    now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    _store_add_create "$body" "$now_iso"
    printf '{"data":{"commentCreate":{"success":true}}}\n'
    return 0
  fi
  if [[ "$query" =~ commentUpdate ]]; then
    local id; id="$(jq -r '.id' <<<"$variables")"
    local body; body="$(jq -r '.body' <<<"$variables")"
    _store_update_by_id "$id" "$body"
    printf '{"data":{"commentUpdate":{"success":true}}}\n'
    return 0
  fi
  # 50-comment fetch → return current store with url field per node (ENG-111).
  jq -c '{data:{issue:{comments:{nodes: [.comments[] | {id, body, url:""}]}}}}' "$_STORE"
}

# ─── Probes (D-005) ───────────────────────────────────────────────────
_probe_header_line_supported() {
  grep -qE '^\*\*[a-z]+\*\*.*author=' "$SCRIPT_DIR_REAL/run-stage.sh" 2>/dev/null
}
_probe_completion_claim_marker() {
  grep -qF 'stage-completion-claim' "$SCRIPT_DIR_REAL/pipeline-events.json" 2>/dev/null
}
_probe_author_attribute() {
  grep -qE 'author=(orchestrator|agent|classify)' "$SCRIPT_DIR_REAL/pipeline.sh" 2>/dev/null
}
_probe_guards_reason() {
  [[ -f "$SCRIPT_DIR_REAL/guards.sh" ]] || return 1
  grep -qE 'reason=[a-z_]+ threshold=' "$SCRIPT_DIR_REAL/guards.sh" 2>/dev/null
}

# ─── Test driver ──────────────────────────────────────────────────────
PASS=0; FAIL=0; SKIP=0
pass_at() { printf '  PASS %s\n' "$1"; PASS=$((PASS+1)); }
fail_at() { printf '  FAIL %s\n      %s\n' "$1" "$2" >&2; FAIL=$((FAIL+1)); }
skip_at() { printf '  SKIP %s — %s\n' "$1" "$2"; SKIP=$((SKIP+1)); }

replay_timeline() {
  local issue="$1" preseed_flag="${2:-no-preseed}"
  if [[ "$preseed_flag" == "preseed" ]]; then
    _store_preseed_halt "halt/implementing/$issue" "$issue" 3
  fi

  # Call 1: agent self-claim PASS (append-only)
  PIPELINE_WRITER=agent \
  PIPELINE_DISPATCH_ID=ENG-81R-d0001 \
  PIPELINE_STAGE=implementing \
  add_comment "$issue" --body $'PASS — implementing done\n\n<!-- pipeline: verdict result=pass stage=implementing -->'

  # Call 2: orchestrator counter bump (append-only — D-003/D-007 keep sig-naming out of ENG-154's surface)
  PIPELINE_WRITER=orchestrator \
  PIPELINE_DISPATCH_ID=ENG-81R-d0001 \
  PIPELINE_STAGE=implementing \
  add_comment "$issue" --body $'Implement rejection counter: 1 of 2'

  # Call 3: orchestrator halt verdict (sig=halt/implementing/<issue>)
  # - R-1 (no preseed): hits commentCreate (no prior sig match) → fresh entry
  # - R-2 (preseed):    hits commentUpdate against preseed → in-place rewrite (the bug)
  PIPELINE_WRITER=orchestrator \
  PIPELINE_DISPATCH_ID=ENG-81R-d0001 \
  PIPELINE_STAGE=implementing \
  add_or_update_comment "halt/implementing/$issue" "$issue" \
    --body $'Halt — implement_rejection threshold reached\n<!-- pipeline: verdict result=halt reason=implement_rejection -->\n\n<!-- meta: dedup key=halt/implementing/'"$issue"$' -->'
}

# Case R-1: clean-store replay → P0-1/P0-2/P0-4 + P1 + P2
printf '\n--- ENG-154 R-1: clean-store replay against current code ---\n'
_eng81r_reset_store
replay_timeline ENG-81R-1 no-preseed

# R-1 P0-1: 3 distinct entries (one per writer call); no in-place rewrites.
_n="$(jq '.comments | length' "$_STORE")"
_ids="$(jq '[.comments[].id] | unique | length' "$_STORE")"
if [[ "$_n" == "3" && "$_ids" == "3" ]]; then
  pass_at "R-1 P0-1: 3 distinct entries, no in-place rewrite"
else
  fail_at "R-1 P0-1: distinct entry count" "n=$_n ids=$_ids store=$(cat "$_STORE")"
fi

# R-1 P0-2: createdAt strictly increasing (pass < bump < halt).
_t_pass="$(jq -r '.comments[0].createdAt' "$_STORE")"
_t_bump="$(jq -r '.comments[1].createdAt' "$_STORE")"
_t_halt="$(jq -r '.comments[2].createdAt' "$_STORE")"
if [[ "$_t_pass" < "$_t_bump" && "$_t_bump" < "$_t_halt" ]]; then
  pass_at "R-1 P0-2: createdAt strictly increasing in dispatch order"
else
  fail_at "R-1 P0-2: createdAt order" "pass=$_t_pass bump=$_t_bump halt=$_t_halt"
fi

# R-1 P0-4: each body carries the auto-injected ENG-87 dispatch marker.
# (loop bodies, grep -qF '<!-- meta: dispatch id=ENG-81R-d0001 stage=' on each)

# Case R-2: preseeded prior halt → P0-3 bug-observation today; inverts when probe trips.
printf '\n--- ENG-154 R-2: preseeded prior halt (bug observation today) ---\n'
_eng81r_reset_store
_t_preseed_iso="$(date -u -v-3H +%Y-%m-%dT%H:%M:%SZ)"
replay_timeline ENG-81R-2 preseed

# R-2 P0-3: today's bug — call-3 hit commentUpdate against the preseed,
# preserving its createdAt. Probe-gated inversion: if the verdict-split
# (or sibling) dep ticket has shipped, the halt is append-only and the
# preseed createdAt is STILL preserved (because no update fired) AND a
# third writer-create entry appears.
_preseed_now="$(jq -r '.comments[0].createdAt' "$_STORE")"
if _probe_verdict_split_supported; then
  # Inverted assertion: 3+1=4 entries; preseed createdAt unchanged.
  _n_r2="$(jq '.comments | length' "$_STORE")"
  if [[ "$_n_r2" == "4" && "$_preseed_now" == "$_t_preseed_iso" ]]; then
    pass_at "R-2 P0-3 (inverted, post-verdict-split): preseed createdAt unchanged AND 3 fresh writer entries"
  else
    fail_at "R-2 P0-3 (inverted)" "n=$_n_r2 preseed_now=$_preseed_now expected=$_t_preseed_iso"
  fi
else
  # Today's assertion: 2 writer-create entries (pass + bump) + 1 in-place update.
  # Preseed entry's createdAt is preserved (3h ago); halt body is now the
  # rewrite (carries `result=halt`).
  _preseed_body="$(jq -r '.comments[0].body' "$_STORE")"
  if [[ "$_preseed_now" == "$_t_preseed_iso" ]] \
     && grep -qF 'result=halt' <<<"$_preseed_body"; then
    pass_at "R-2 P0-3 (today, bug-observation): preseed createdAt preserved across in-place halt rewrite"
  else
    fail_at "R-2 P0-3 (today)" "preseed_now=$_preseed_now expected=$_t_preseed_iso body=$_preseed_body"
  fi
fi

# P1-header: gated probe.
if _probe_header_line_supported; then
  # … assert each body's first non-blank line matches `**<stage>** <dispatch-id> <iso-ts> · author=<actor>`
  : # placeholder — dep-ticket implementer fills the assertion when the dependency lands (D-009)
else
  skip_at "P1-header" "<header-line-ticket-id-TBD> not shipped; _probe_header_line_supported did not trip"
fi

# P1-completion-claim, P1-author-marker, P1-reason-threshold: same shape with
# `<verdict-split-ticket-id-TBD>`, `<author-attribute-ticket-id-TBD>`,
# `<guards-reason-ticket-id-TBD>` in the SKIP messages.

# P2: ENG-111 breadcrumb cross-pollination — runs only when ENG_81R_AUDIT=1.
if [[ "${ENG_81R_AUDIT:-0}" == "1" ]]; then
  # assert one extra entry with `<!-- meta: breadcrumb sig=halt/implementing/ENG-81R … -->`
  :
fi

# ─── Summary ──────────────────────────────────────────────────────────
printf '\nRESULTS: %d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[[ "$FAIL" == 0 ]] || exit 1
exit 0
```

(The pseudocode above sketches the shape; the implementer fills the
inequality + body-marker assertions inline. Total file size projection:
250-350 lines.)

### 3.3 Per-call expected store transitions

**Case R-1 (clean store, no preseed):**

| Step | Caller | Function | Sig | Store delta |
|---|---|---|---|---|
| 1 | agent | `add_comment` | — (append-only) | +1 entry, `createdAt` = T |
| 2 | orchestrator | `add_comment` | — (append-only) | +1 entry, `createdAt` = T + ~20ms |
| 3 | orchestrator | `add_or_update_comment` | `halt/implementing/<issue>` | +1 entry (no prior sig match → commentCreate), `createdAt` = T + ~40ms |

Net store: **3 distinct entries**, `createdAt` strictly increasing.

**Case R-2 (preseed: a prior halt 3 hours upstream):**

| Step | Caller | Function | Sig | Store delta |
|---|---|---|---|---|
| 0 | fixture | `_store_preseed_halt` | `halt/implementing/<issue>` (in body) | +1 entry, `createdAt` = T − 3h |
| 1 | agent | `add_comment` | — (append-only) | +1 entry, `createdAt` = T |
| 2 | orchestrator | `add_comment` | — (append-only) | +1 entry, `createdAt` = T + ~20ms |
| 3 | orchestrator | `add_or_update_comment` | `halt/implementing/<issue>` | in-place commentUpdate of entry-0; `createdAt` unchanged at T − 3h |
| (P2 audit-only) ENG-111 breadcrumb fires because step 3's body changed → +1 entry, `createdAt` = T + ~40ms

Net store today: **3 entries** (preseed [updated] + agent + bump); 4 with P2 breadcrumb.
Net store post-verdict-split dep-ticket: 4 entries (preseed [unchanged] + agent + bump + fresh halt).

### 3.4 How a dependency-ticket landing extends this fixture

The flow when (e.g.) the header-line ticket ships:

1. Header-line ticket implementer ships their change. `bin/run-stage.sh`'s
   `post_completion_comment` (or wherever the header is generated) now
   emits the canonical header shape.
2. Operator runs the pre-commit suite. `bin/eng-81-reproducer-test.sh`'s
   `_probe_header_line_supported` greps `bin/run-stage.sh` and trips.
3. The previously-`SKIP P1-header` branch fires (the probe is now
   non-zero). The body inside the `if _probe_header_line_supported`
   block today is a no-op `:` placeholder — it PASSes trivially in
   the gate. THIS IS A HAZARD: a forgotten placeholder defeats the
   gate. The dep-ticket implementer's acceptance criterion (per
   D-009's sentence in the file header) is to replace the placeholder
   with the real assertion. The dep-ticket reviewer must verify the
   placeholder was filled.
4. No fixture **setup** edit is required. The single localised edit
   is filling in the placeholder assertion body
   (`: # placeholder — dep-ticket implementer fills the actual assertion`)
   which by D-009's contract is the dependency-ticket implementer's
   responsibility, not ENG-154's. ENG-154 ships the gate scaffold; the
   dependency-ticket fills the gated assertion's body.

A subtlety: step 4 is technically a "rewrite" of a placeholder. AC #4's
"no rewrite of fixture setup" is honoured because the fixture's
**setup** (comment store, replay driver, probes) does not change —
only the gated assertion body is filled in. This separation is documented
in D-009 and in the test file's header.

## 4. Data flow

```
test invocation: `bash bin/eng-81-reproducer-test.sh`
  │
  ├─ scaffold (tempdir, config, schemas, store JSON, metrics dir)
  │
  ├─ source bin/linear.sh (loads add_comment, add_or_update_comment, helpers)
  │
  ├─ stub overrides:
  │     _resolve_issue_uuid → returns literal
  │     linear_query → reads/writes $_STORE
  │
  ├─ replay_timeline ENG-81R
  │     │
  │     ├─ _store_preseed_halt halt/implementing/ENG-81R ENG-81R 3
  │     │     → $_STORE.comments += [pre-seed entry, createdAt = T-3h]
  │     │
  │     ├─ PIPELINE_WRITER=agent add_comment …
  │     │     → linear_query sees commentCreate → _store_add_create
  │     │     → $_STORE.comments += [agent PASS entry, createdAt = T]
  │     │
  │     ├─ PIPELINE_WRITER=orchestrator add_or_update_comment counter-bump/…
  │     │     → linear_query sees the 50-comment fetch → returns current store
  │     │     → existing_id lookup finds NO match (sig not in store)
  │     │     → falls through to commentCreate branch
  │     │     → $_STORE.comments += [bump entry, createdAt = T+20ms]
  │     │
  │     └─ PIPELINE_WRITER=orchestrator add_or_update_comment halt/…
  │           → linear_query sees the 50-comment fetch → returns current store
  │           → existing_id lookup MATCHES the pre-seed entry
  │           → ENG-63 strip → bodies differ → no footer rotation
  │           → commentUpdate against pre-seed entry's id
  │           → _store_update_by_id preserves createdAt
  │           → ENG-111 breadcrumb branch fires (P2 audit territory)
  │
  ├─ tier-gated assertions
  │     P0-1..4 (unconditional)
  │     P1-header, P1-completion-claim, P1-author-marker, P1-reason-threshold (probe-gated)
  │     P2-breadcrumb (env-gated)
  │
  └─ RESULTS: N passed, M failed, K skipped
```

## 5. Error handling

- **`_STORE.json` write fails between read and rename.** `jq … > tmp && mv`
  is atomic — on failure the original `_STORE` is intact and the next
  `linear_query` call sees consistent state. A failed write would
  cascade into the next assertion (the store wouldn't reflect the
  expected delta); `set -euo pipefail` aborts the script with non-zero
  rc and the assertion never runs. Pre-commit treats rc≠0 as FAIL.
- **`add_or_update_comment` itself dies** (e.g., due to a bug introduced
  by a dependency ticket). `set -euo pipefail` propagates rc≠0. The
  fixture's exit message is "test script aborted" rather than
  "assertion failed"; both are gate-blocking, so the pre-commit
  experience is the same.
- **Probe greps a missing source file.** `grep … 2>/dev/null` swallows
  the stderr; the probe returns non-zero (the file doesn't exist),
  which means the dependency hasn't shipped, so SKIP — correct
  behaviour.
- **Two probes simultaneously trip but the dependency tickets shipped
  conflicting body shapes** (worst case: header-line ticket and
  verdict-split ticket clash). The two P1 assertions run independently;
  if both fail, both surface in the gate output. The fixture surfaces
  conflict via two simultaneous FAILs, not silently masking either.
  Operator escalates by deciding which dependency's shape is canonical.
- **Pre-seeded `createdAt` parsing fails** (e.g., `date -u -v-3H`
  rejected by a future macOS Sequoia BSD `date` change). The seed
  value would be empty; `_store_add_create` would write `createdAt: ""`;
  the P0-2 inequality assertion would FAIL with a clear "createdAt
  empty" message. Operator-visible at gate time.
- **Stub `linear_query` is called with a query we didn't anticipate**
  (e.g., a future dependency ticket adds a third mutation type the
  stub doesn't handle). The stub's catch-all branch returns the store
  fetch payload, which is wrong but visible — the caller fails on
  parse, the test aborts, the operator updates the stub. Defensive
  shape: an `else die "unexpected query"` arm in the stub forces
  early visibility.

## 6. Edge cases

- **Pre-commit runs without `gnu-time` / `gtime`.** Irrelevant — the
  fixture does not invoke `gtime`. (`gtime` is used only by
  dispatch.sh per `bin/dispatch.sh:637`.)
- **Pre-commit runs without `perl` (the 20ms sleep helper).** macOS
  ships perl as part of the base system; the launchd PATH includes
  `/usr/bin`. If absent the sleep degrades to no-op, two
  `commentCreate` calls land within the same millisecond, and `createdAt`
  tie-breaks would need a fallback. Defensive shape: detect by using
  `command -v perl` and fall back to `sleep 0.02` (BSD `sleep`
  accepts fractional seconds on macOS); if neither, use
  `printf` to emit an explicit increment to a monotonic counter as
  part of the createdAt string suffix. Implementation discretion;
  the design records the fallback as a flagged Q-002.
- **The pre-seed `createdAt` happens to land in the future** (clock
  skew, BSD date interaction). `date -u -v-3H` returns "now minus
  3 hours" which is unambiguously in the past barring extreme clock
  drift; gate this as a defensive `[[ "$_t_preseed" < "$_t_now" ]]`
  precondition before the main assertions run.
- **A future dependency ticket flips `add_or_update_comment` to
  always call `commentCreate`** (i.e., abandons the in-place rewrite
  entirely). The fixture's P0-3 ("createdAt of pre-seed entry still
  matches seed time") would FAIL because the canonical now lives at
  a fresh `createdAt`. This is the OPPOSITE of the ENG-81 bug —
  catching it as FAIL surfaces a contract-shape change to the
  operator at gate time. If the change is intentional, the operator
  updates the fixture's invariants in the ticket that introduces
  the flip. Correct visibility.
- **A future dependency ticket renames the `pipeline:` event vocabulary**
  (e.g., `verdict` → `verdict-v2`). The fixture's body markers carry
  the literal event name `verdict`; a rename would break P0-4's
  marker presence assertion. Same visibility rationale — gate FAIL
  surfaces the rename.
- **Multibyte/Unicode in the agent's PASS body** (e.g., agent emits
  a `✅` emoji). The jq selectors operate on bytes; the `contains()`
  filters in P0-2 match literally; no Unicode-specific failure
  expected. ENG-63 AD-005 pinned this for `bin/linear-test.sh`'s
  capture-file path; the in-memory store is structurally equivalent.
- **Cross-test residue from the pre-commit suite's earlier files**
  (e.g., a prior test left `PIPELINE_DISPATCH_ID` exported in the
  environment). The fixture's `replay_timeline` sets PIPELINE_*
  inline on each `add_*` call (not via top-level export), so prior
  exports don't contaminate the replay. Setup also explicitly unsets
  PIPELINE_DISPATCH_ID / PIPELINE_STAGE before starting.

## 7. Persona review

Six personas dispatched in the mandated order (design → security →
scope → coherence → product → feasibility, feasibility gating). One
iteration of patches applied after iter-1 findings.

| Persona | Iter-1 Verdict | Iter-1 P0 | Iter-2 Verdict | Iter-2 changes |
|---|---|---|---|---|
| design | PASS | 1 (D-008 self-contradiction) | PASS | D-008 restructured into "Per-test-case isolation; one shared replay within a case" with explicit two-scope contract. P1 P0-2 ordering prose clarified; P1 axis-1-probe-collision-safety addressed in D-007 (sig-naming removed) + R-2 P0-3 design preflight. |
| security | PASS | 0 | PASS | (No iter-2 changes — defense-in-depth P2s noted in §6.) |
| scope | FAIL | 2 (axis-1 probe coupling; D-007/Q-001/D-009 out-of-scope contract prescription) | PASS | D-007 walked back from prescribing `counter-bump/<stage>/<issue>` to "no sig invention." Q-001 demoted to "RESOLVED — deferred." D-009 reframed as descriptive, not prescriptive (placeholder-fill is dep-ticket AC, not ENG-154's contract). Axis-1 read-only probe coupling acknowledged but kept — probes do not mutate other subsystems' surfaces; flagged as P2 in §11. |
| coherence | FAIL | 3 (D-008 contradiction; §7→§10 broken cross-ref; §3.2/§3.3 fabricate counter-bump sig that corrupts P0-1 count) | PASS | D-008 fixed (see design row). §10 placeholder removed; this §7 table is now the single verdict surface. §3.2/§3.3 restructured into R-1 (clean store, 3 entries) + R-2 (preseed, today's bug observation) — call-2 uses append-only `add_comment`, eliminating sig collision. Terminology drift fixed ("tempdir-backed JSON store"). AC #4 mapping now cites D-005 + D-009 + §3.4. Four-vs-six counting reconciled in §3.2 header docblock. |
| product | PASS | 0 | PASS | P1 SKIP-message-clarity addressed (`<header-line-ticket-id-TBD>` placeholder convention in §3.2 + D-005). P1 dep-author-realism addressed in D-009 (sentence about dep-ticket AC). P2s (un-skip noise, header incident link) noted for implement-stage discretion. |
| feasibility (gating) | PASS (0 P0) | 0 | PASS | All 20 code-fact items verified against current source. Pseudocode bash-3.2 compatible. P1 `${2:-{\}}` idiom matches existing harness convention; P2 ENG-63 A-013 citation refined to point at `bin/halt-sprawl-test.sh:281,285` etc. (the actual `-v-NH` precedent sites). |

**Gate:** Iter-2 6/6 PASS, feasibility 0 P0. Iter-1 was 4/6 PASS;
iter-2 patches applied the design P0 (D-008), the coherence P0s
(D-008 + §3 restructure + cross-ref), and the scope P0s
(D-007 walk-back + Q-001 deferral + D-009 reframe) inline. Threshold
(≥5/6 PASS AND feasibility P0=0) cleanly satisfied at iter-2.

## 8. Anti-bias checks

### 8.1 ADR stress test

- **One canonical comment per logical event** (ENG-60 vocabulary
  closure, reinforced by ENG-63 D-001, ENG-111 D-001). The fixture
  exercises three writer calls under three distinct sigs (agent's PASS
  has no sig — `add_comment`; counter bump has its own sig; halt has its
  own sig). The fixture asserts each canonical lives under exactly one
  entry — REINFORCES the invariant.
- **Closed `meta:` token registry** (ENG-60). The fixture's bodies
  reference existing tokens (`dedup`, `dispatch`); future dependency-
  ticket assertions reference tokens those tickets add. The fixture
  does NOT introduce new tokens. NO stress.
- **Lane fence write enforcement** (ENG-41). The fixture invokes the
  agent and orchestrator lanes via `PIPELINE_WRITER` env on each call.
  `_check_lane` runs for each `add_comment` / `add_or_update_comment`
  call inside the lane-fence allow-list. NO stress; in fact the
  fixture's three-lane shape exercises the fence beyond what
  ENG-41's own tests pin.
- **Linear comments are append-only** (`docs/runbooks/recovery.md`).
  The fixture's `commentUpdate` simulation models the harness-side
  in-place rewrite that ENG-104 + sub-tickets were scoped against;
  the fixture explicitly pins the failure-mode (P0-3) of preserving
  `createdAt` across an update. REINFORCES.
- **Dispatch-id auto-injection chokepoint** (ENG-87). The fixture
  sets `PIPELINE_DISPATCH_ID=ENG-81R-d0001` on each call; the
  chokepoint at `bin/linear.sh:514,595` auto-injects, and P0-4
  asserts each body carries the marker. REINFORCES.
- **Pre-commit hook auto-globs `bin/*-test.sh`** (`.githooks/pre-commit:154`).
  AC #2 is satisfied by filename alone. REINFORCES.

### 8.2 Simpler alternatives

Inline under each decision's "Rejected" blocks. Summary:

- D-001 rejected: embed as block in `linear-test.sh`; `bin/eng-154-reproducer-test.sh` naming.
- D-002 rejected: real Linear API; flat capture file + sidecar array.
- D-003 rejected: three separate test invocations sharing on-disk state; drive `linear_query` directly.
- D-004 rejected: single tier all-on; two tiers without P2.
- D-005 rejected: single env-var flag; deps-status JSON.
- D-006 rejected: exact body-string equality matches.
- D-007 rejected: pre-commit to `counter-bump/<stage>/<issue>` as the assumed canonical (was iter-1 stance; iter-2 walked back).
- D-008 rejected: re-run replay per tier within a case; share state across cases.
- D-009 rejected: runbook file; iter-1 prescriptive lifecycle framing.

### 8.3 Assumption inventory

| # | Assumption | Status | Verification |
|---|---|---|---|
| A-001 | `bin/linear.sh::add_comment` is the chokepoint for append-only writes; `add_or_update_comment` is the sig-deduped writer (lines 496-574 and 576-708 respectively). | verified | `Read bin/linear.sh:490-708` this session. |
| A-002 | `add_or_update_comment` uses `commentUpdate` for in-place rewrites and `commentCreate` only on first emission, preserving `createdAt` across updates. | verified | `Read bin/linear.sh:660-707` this session — `commentUpdate` mutation at `:667-670`, `commentCreate` at `:702-705`. |
| A-003 | The 50-comment fetch at `bin/linear.sh:620` includes `id body url` fields per node (ENG-111 extension); `existing_id` lookup at `:624-625` matches on the `dedup` marker. | verified | `Read bin/linear.sh:620-625` this session. |
| A-004 | `bin/linear.sh::_inject_dispatch_marker` is the ENG-87 chokepoint at lines 60-77; runs unconditionally at the top of `add_comment` (`:514`) and `add_or_update_comment` (`:595`); idempotent. | verified | Cited from ENG-111 brainstorm A-006 + cross-referenced in this session. |
| A-005 | `bin/pipeline-events.json::verdict_results` is `["pass","fail","halt","wait","pivot"]` and `meta_kinds` includes `"breadcrumb"` (post-ENG-111). | verified | `Read bin/pipeline-events.json:3-52` this session. |
| A-006 | `.githooks/pre-commit:154` auto-globs `bin/*-test.sh` so a new file ending in `-test.sh` is auto-wired into the sweep with no edit. | verified | `Read .githooks/pre-commit:151-177` this session. |
| A-007 | `bin/linear-test.sh:512-969` (ENG-63 + ENG-111 + ENG-87 test blocks) use the source-and-stub idiom with `linear_query` + `_resolve_issue_uuid` overrides and `PIPELINE_DRY_RUN=0` flip; same idiom is portable to a new file. | verified | `Read bin/linear-test.sh:512-969` this session. |
| A-008 | macOS BSD `date -u -v-3H +%Y-%m-%dT%H:%M:%SZ` produces a 3-hours-ago ISO-8601 UTC string; BSD `date` is the launchd-host runtime. | verified | Inherited from ENG-63 A-013 (already in production). |
| A-009 | The orchestrator counter-bump sig today is integrated into `halt/<stage>/<issue>` by `classify-failure.sh`; the guards-reason+threshold dependency ticket is expected to split it into `counter-bump/<stage>/<issue>`. The fixture's sig literal may need updating when that ticket ships. | assumed | Per the issue body: "guards-reason ticket" is named as a dependency but its sig name and emit site are not pinned in current code. Sole 'assumed' item; D-007 documents the localised update site. |
| A-010 | `parse_pipeline_marker` lives in `bin/common.sh` and parses both legacy and current marker shapes; the fixture can use it (after sourcing common.sh transitively via linear.sh) to validate marker k=v shape. | verified | Referenced from CLAUDE.md "Pipeline vocabulary"; cited in ENG-111 A-006 lineage. |
| A-011 | The `_classify_comment_body` function classifies the agent's PASS body (carrying `result=pass`) as a `verdict` comment-class and routes through `_check_lane "add" "verdict_comment"` (or equivalent); `PIPELINE_WRITER=agent` is allow for that class. | verified | `Read bin/linear.sh:84-120` lane-decision matrix; transitive — design relies on ENG-41 lane-fence allow-decisions for the writer/object pairs the fixture exercises. |
| A-012 | The pre-seed entry's `<!-- meta: dedup key=halt/implementing/<issue> -->` marker is what `existing_id` lookup matches on; `add_or_update_comment` matches both the new-shape (`meta: dedup key=`) and legacy-shape (`pipeline-sig:`) markers per `bin/linear.sh:601-603, 624-625`. | verified | `Read bin/linear.sh:601-605, 615-625` this session. |
| A-013 | Pre-commit hook tolerates a test file emitting `RESULTS: 0 passed, 0 failed, K skipped` (all P1 gated, P0 not yet implemented) by treating non-zero only on `detect_failure` which inspects rc OR `❌`/`FAIL`/`failed=[1-9]`. A test that exits 0 with K skips passes the gate. | verified | `Read .githooks/pre-commit:140-149,169-176` this session. |

A-009 is the only `assumed` item. The fixture degrades gracefully if
A-009 is wrong — the guards-reason+threshold ticket implementer
adjusts the sig literal at the same time as their probe ships,
inside their own ticket's diff.

## 9. Open questions

- **Q-001.** Should the fixture also assert against the ENG-110
  dispatch-id ledger schema (each comment carries a parseable
  `dispatch_id` in its auto-injected marker)? ENG-110 has shipped per
  the linear-test.sh ENG-110 block at `:1188-1241`. ENG-87's
  dispatch-marker presence is already pinned by P0-4 in this fixture
  (each body carries `<!-- meta: dispatch id=… stage=… -->`).
  **RESOLVED — deferred.** Scope persona iter-1 flagged Q-001 as
  scope creep; the dispatch-id parseability is exercised by ENG-110's
  own block at `linear-test.sh:1188-1241` and the marker-presence is
  already pinned by P0-4. No P0-5 added.
- **Q-002.** Sleep mechanism for sub-millisecond `createdAt`
  differentiation between two `commentCreate` calls in the same
  fixture run. perl-based 20ms sleep (preferred) vs BSD-`sleep` 0.02
  vs monotonic-counter suffix. Implementer's call; the design
  records the perl preference based on portability (perl ships on
  macOS base) and falls back as needed.
- **Q-003.** Should P2 (`ENG_81R_AUDIT=1` cross-cutting breadcrumb
  assertion) be promoted to P0 once ENG-111 is generally adopted? The
  breadcrumb is observable today (ENG-111 has shipped). Argument for:
  it's a load-bearing invariant. Argument against: ENG-111's own
  tests already pin the breadcrumb; double-asserting in the reproducer
  adds maintenance churn. RECOMMEND keep as P2.
- **Q-004.** When the verdict-split ticket ships
  `<!-- pipeline: stage-completion-claim … -->`, the agent's PASS
  body in this fixture needs to swap shape. The probe gates the
  assertion that checks the marker presence; does the
  `replay_timeline` driver also need a "use new event name" branch?
  Or does the agent body string literal stay as `result=pass` and
  the new-shape probe asserts the new shape EXISTS SOMEWHERE? The
  latter is less faithful to the timeline but doesn't force a
  parallel replay path. RECOMMEND: implementer decides during the
  verdict-split ticket's implement-stage based on the actual emit
  shape.
- **Q-005.** Does the fixture need a `--update-baselines` mode (mirroring
  snapshot-style tests) so the implementer can regenerate expected body
  strings when a dependency ticket lands? RECOMMEND NO — the
  fixture's contract is structural (markers present, sigs honoured,
  chronology correct), not literal-string, so there's nothing to
  baseline. If the implementer reaches for `--update-baselines`,
  that's a smell that the assertion has drifted to literal-string
  matching against AC #4's "no rewrite" promise.

## 10. Scope flags

Nothing in this brainstorm exceeds the issue's acceptance criteria:

- **AC #1 (test file commits + runs green skipping unshipped deps)** → D-001, D-004, D-005, §3.2 P0/P1/P2 tier structure.
- **AC #2 (wired into pre-commit)** → D-001 (filename auto-globbed by `.githooks/pre-commit:154`).
- **AC #3 (header documents incident + 4 deps)** → D-001 (header docblock) + D-009 (descriptive lifecycle in header).
- **AC #4 (deps un-skip without fixture-setup rewrite)** → D-005 (per-probe gates) + D-009 (descriptive lifecycle in header; dep-ticket fills placeholder) + §3.4 (lifecycle flow).

**Iter-2 scope-persona address.** The probes (D-005) read source from
`bin/run-stage.sh`, `bin/pipeline.sh`, `bin/pipeline-events.json`,
`bin/guards.sh` for feature detection — strictly READ-ONLY greps. No
mutation of those subsystems. The fixture's actual surface is one
file in `bin/`'s tests/fixtures subsystem. Axis-1: 1 subsystem touched
(tests/fixtures). The probe coupling is acknowledged as a soft coupling
that surfaces when a dep ticket renames an emit site — the `[[ -f ... ]]`
existence preflight (D-005 iter-2 addition) makes such rename surface
as a probe BROKEN state visible at the next pre-commit, not a silent
SKIP. P2 in §7.

**Iter-2 Q-001 disposition.** Removed from scope. ENG-110 contract is
already pinned by P0-4 (every body carries the ENG-87 dispatch marker);
no P0-5.

Q-003 (promote P2 to P0) deliberately stays at P2 — keeps the
reproducer focused on the ENG-104 family's load-bearing contract
without double-coverage of ENG-111's own tests.

## 11. Conflicts with existing architecture

None identified.

The dedup contract (one canonical comment per sig), the lane fence,
the closed `meta:` vocabulary, the append-only Linear-comment
property, the dispatch-id chokepoint discipline, the pre-commit
hook auto-glob, and the source-and-stub test idiom are all
preserved and exercised by the fixture. The fixture is a strict
information ADD: one new test file replays the canonical incident
against the current code, with a lifecycle for un-skipping assertions
as the four dependency tickets land.

ENG-104 closed as subsumed; ENG-154 owns this fixture as the
canonical regression for the ledger contract. The four sibling
tickets (header-line, verdict-split, guards-reason+threshold, plus
the umbrella) own their own behavioural changes; ENG-154 owns the
gate.
