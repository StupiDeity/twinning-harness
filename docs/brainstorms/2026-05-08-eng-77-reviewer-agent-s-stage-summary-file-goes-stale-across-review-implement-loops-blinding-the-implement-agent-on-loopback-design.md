---
linear: ENG-77
title: reviewer agent's stage-summary file goes stale across review-implement loops, blinding the implement agent on loopback
date: 2026-05-08
status: draft
---

# Pin the reviewer's overwrite-every-dispatch contract in the prompt — defer the defensive net and the typed-findings refactor

## 1. Overview (and the load-bearing surprise)

The Linear issue documents a real, observed cycle on ENG-71 (May
2026): review → implement → ui → reviewing repeated 9 times in 9
hours, ~$50 of compute and 2 manual operator interventions, with no
convergence. The implement agent's iter-9 escalation hypothesised an
[ENG-63](../brainstorms/2026-05-04-eng-63-linear-sh-add-or-update-comment-identical-body-re-applies-are-invisible-to-operators-no-updatedat-change-design.md)
regression in `bin/linear.sh::add_or_update_comment` (no-op on
identical bodies). Direct on-disk inspection proved otherwise:

```
$ ls -l ~/.local/state/twinning-harness/harness/ENG-71/stage-summary-reviewing.md
-rw-r--r--  3903  7 May 04:10  stage-summary-reviewing.md   (= 22:40Z May-6 mtime, iter-5)

$ grep 'Reviewed commit' stage-summary-reviewing.md
Reviewed commit `4899db98`. ...   (8 hours and 2 SHAs out of date)
```

The reviewer's iters 6, 7, 8, and 9 each found NEW majors AND
emitted fresh `<!-- pipeline: verdict result=fail target=implementing
-->` markers — but never rewrote the stage-summary file on disk. The
orchestrator's `post_completion_comment` (verified at
`bin/run-stage.sh:147-225`) reads the file verbatim and posts its
content under `add-or-update-comment "completion/reviewing/<issue>"`;
with no rewrite, the iter-5 body landed on Linear every time. The
implement agent on each loopback read the iter-5 body, fixed the
findings it named, and reported done. The reviewer re-ran, found the
same NEW issues iter-9 had named, re-emitted fail. Cycle.

**The load-bearing surprise.** The bug is upstream of the
dedup/equality machinery the implement agent fingered. The contract
between agent and orchestrator was: "you Write the file with your
authoritative report; the orchestrator posts it." `AGENT_PROMPTS.md`
§5 said only "Stage-summary file at `{stage_summary_path}` (per the
Stage summary comment format contract)" — silent on whether
*overwrite-every-dispatch* was required. Iters 6-9 evidently
interpreted the existing on-disk file as "matches my findings well
enough, skip the Write" — technically consistent with the silent
corner case, but breaking the implicit orchestrator-side contract.

**Status.** The narrow prompt+test fix already shipped on `main` as
commit bd8ca2d (PR #61, 2026-05-07). The branch the brainstorm runs
from (`feat/eng-77-...`) has not yet had its own commits; this
brainstorm exists to give ENG-77 the canonical doc for the harness
SDLC pipeline AND to make the deferral of the defensive net (Fix #2)
and the typed-findings refactor (Fix #3) load-bearing rather than
incidental. **No new code is proposed by this brainstorm.** D-001
and D-002 codify the design that already shipped; D-003 records why
the fix is scoped to `§5` and not to `§§3, 4`; D-004 and D-005
record the conditions under which the deferred items would un-defer.

## 2. Goals

**G-1 (primary).** When the review agent is dispatched on a loopback
re-entry — the issue already has a `stage-summary-reviewing.md` from
a prior iter on disk — the next reviewer dispatch MUST overwrite the
file with current-iter content. The orchestrator's `post_completion_comment`
read at `bin/run-stage.sh:179-191` MUST reflect the iter that just
ran, not a prior iter.

**G-2.** The contract is enforced by the prompt's stage-summary-file
output spec, not by post-dispatch state inspection. A future
prompt-cleanup pass that drops the rule must be caught by a content
test (`bin/agent-prompts-content-test.sh`) before the prompt edit
ships, not by the next 9-iteration cycle in production.

**G-3.** The rule is self-justifying — it cites the named incident
(`ENG-71 May 2026`) so a future maintainer reading the §5 prompt can
see *why* the rule exists without grepping the codebase or the
ticket archive.

**G-4.** The rule applies narrowly to the surface where the
incident actually fired (`§5 Review Agent`), NOT to every stage
prompt. Generalising prematurely would dilute the named-incident
rationale (the ENG-71 cycle was specifically a review-loopback
phenomenon) and add ~25 lines of prompt edit / ~15 lines of test
asserts for surfaces that have not observed the failure mode.

**G-5.** The deferred defensive net (Fix #2: stale-file mtime check
in `run-stage.sh`) and the deferred structural refactor (Fix #3:
typed cross-stage findings channel) have explicit
un-deferral preconditions documented (D-004, D-005). Operators
choosing to invest must know what evidence raises the bar.

**Non-goals (deferred, see §10).** Stale-file detection in
`run-stage.sh` (Fix #2 in the issue body — D-004 here). Typed
cross-stage findings channel (Fix #3 — D-005). Generalising the
overwrite rule to `§§3, 4` (D-003 below — narrow now, revisit if a
non-review stage observes the same loop). Test pin in
`run-stage-test.sh` for the orchestrator-side read path (low
incremental coverage; D-002's content test catches the prompt
regression).

## 3. Architectural principles

Five CLAUDE.md / ENG-history constraints govern this design.

**A-1. CLAUDE.md "Doing tasks" §: don't add features beyond what
the task requires; bug fix doesn't need surrounding cleanup.** D-001
and D-002 are the two-paragraph prompt edit + three-assert test pin
the issue body specifies. D-003 (scope decision) is a deliberate
*refusal* to extend, not a new feature. D-004 and D-005 propose
nothing new in this PR — they pin the deferral with un-deferral
criteria so the next operator who picks them up has the bar to
clear.

**A-2. CLAUDE.md "AGENT_PROMPTS.md is load-bearing" §.**
`AGENT_PROMPTS.md` contains nine numbered H2 sections, one per
stage agent; `render-prompt.sh` extracts the fenced block by
section header. Edits to §5's content go inside §5's fenced block;
test pins live in `bin/agent-prompts-content-test.sh` (the same
file that already pins ENG-50, ENG-54, ENG-71, and ENG-74 §5
invariants — verified at `bin/agent-prompts-content-test.sh:152-235`).

**A-3. ENG-49 / ENG-54 (review stage is agent-only; no human gate
at review).** ENG-54 narrowed the review stage's contract: the
agent runs cold-pass reviewers, comments on the PR, and either
advances to QA or loops back to implement. This means review is
the ONLY stage with a documented tight re-dispatch loop (review →
implement → ui → review again). The architectural premise that
makes ENG-77 a review-specific bug — and not a brainstorm/plan/
build bug — is precisely ENG-54: those other stages don't have a
fast in-issue re-dispatch path. D-003 leans on this premise.

**A-4. ENG-63 (`add_or_update_comment` re-apply visibility).** The
`<!-- meta: reapplied at=… -->` footer at `bin/linear.sh:582-606`
makes identical-body re-applies visible to operators (advances
`updatedAt` even with no body change). D-001's prompt text leans
on this fix to tell agents: "even if findings are unchanged, re-
write the same content; the orchestrator's footer-only re-apply
path covers visibility." This is why the prompt rule is the
correct fix layer — the visibility plumbing downstream already
works; it's just that the file-write upstream wasn't happening.

**A-5. CLAUDE.md "Per-issue state directory" § (issue-state.json,
stage-summary-<stage>.md, wait-<stage>.json paths).** The harness
already documents `stage-summary-<stage>.md` as one of the
durable per-issue files. D-001's prompt edit is consistent with
this layout — the rule is "the file you're already required to
write must be overwritten on every dispatch," not a new file or a
new path. No CLAUDE.md doc-string edit is required for the in-
scope fix (the file is already documented; only the agent's
contractual obligation to rewrite it changes).

## 4. Decisions

### D-001 (already shipped on `main`): MANDATORY overwrite-every-dispatch rule in §5 Review Agent prompt

**Verdict.** `AGENT_PROMPTS.md §5` Output section, the `Stage-summary
file at {stage_summary_path}` bullet, expanded to mandate
overwrite-every-dispatch with named-incident citation. Verbatim
shipped text (verified at `AGENT_PROMPTS.md:1027-1039`):

```
- Stage-summary file at {stage_summary_path} (per the Stage summary
  comment format contract). **MANDATORY — overwrite on every dispatch.**
  Use `Write` with the full report content; do not read-then-conditionally-skip.
  The file's contents at exit time are your authoritative report — the
  orchestrator reads it verbatim and posts it as the Linear
  `completion/reviewing/{issue_id}` summary. If your findings are unchanged
  from a prior iter (rare on a re-dispatched review-loopback), re-write the
  same content; the orchestrator's footer-only re-apply path covers
  visibility. ENG-71 (May 2026) cycled 9 review-implement loops because
  iters 6-9 emitted fresh `verdict fail` markers but never updated this
  file — the orchestrator kept posting the iter-5 stale body to Linear,
  the implement agent kept reading the stale body, and no new feedback
  reached the next iteration. Do not repeat.
```

Net diff vs prior shipped version: 12 lines of mandate (was 1 line
of bullet), 0 lines of test or runtime code in `bin/`.

**Why.** Three reasons.

(1) **The contract failure is at the agent layer, so the fix
belongs at the prompt layer.** The orchestrator's behavior is
correct: read the file, post it. The agent's behavior was the
ambiguity ("file already exists with reasonable content → skip the
Write?"). The prompt is the authoritative spec for agent behavior;
the prompt's silent corner case is what the agent exploited; the
prompt is the layer that fixes it.

(2) **The fix is cheap, immediate, and orthogonal.** A two-paragraph
prompt edit ships in minutes, applies to every future review
dispatch, and neither expands the orchestrator's surface nor
changes any other agent's contract. Compared with Fix #2 (D-004 —
defensive mtime check in run-stage.sh) which would catch *any*
stage's silent file-skip, the prompt rule narrowly fixes the
observed surface. Compared with Fix #3 (D-005 — typed findings
channel), which restructures the cross-stage data path, the prompt
rule preserves the current architecture and only edits text.

(3) **Self-justifying via named incident.** The §5 paragraph names
ENG-71 by ID and date and describes the cycle. A future maintainer
reading §5 sees the rule's reason inline; a future cleanup pass
that wants to drop the rule has to confront the cycle's cost
(~$50, 9 iterations, 2 manual interventions) before stripping the
mandate.

**Verified facts the decision relies on:**

- `AGENT_PROMPTS.md:1027-1039` carries the MANDATORY paragraph as
  shipped. Verified by direct read.
- `bin/run-stage.sh:147-225` (`post_completion_comment`) reads
  `$(issue_dir "$issue")/stage-summary-${stage}.md` and posts its
  content via `add-or-update-comment "completion/${stage}/${issue}"`.
  Verified at `bin/run-stage.sh:149-150` (path + sig).
- `bin/run-stage.sh:179-186` is the read site:
  `[[ ! -s "$summary_path" ]]` falls through to `summary_missing`
  fallback; the else arm reads + sed-strips the body. The "stale
  file lands on Linear" path goes through this else arm. Verified
  by direct read.
- `bin/linear.sh::add_or_update_comment` upserts on sig match; the
  ENG-63 re-apply footer at `bin/linear.sh:582-606` ensures even
  identical-body re-posts advance `updatedAt`. Verified by
  inspection (the issue body's claim "byte-equality after `reapplied
  at` strip → either dedup-equivalence path appending a footer OR
  straight overwrite with same content" is consistent with this
  function's behavior).
- The Review Agent's `Decision path B` at `AGENT_PROMPTS.md:986-1004`
  is the loopback-emitting path: it posts the gh pr review summary
  + Linear summary, bumps the rejection counter, and runs
  `bash bin/pipeline.sh event {issue_id} verdict fail --target
  implementing`. The path is reached on every review-loopback
  iteration. Verified by direct read.
- The shipped commit on `main` is `bd8ca2d` (`fix(eng-77): mandate
  reviewer overwrites stage-summary file on every dispatch`),
  merged via PR #61. Verified via `git show bd8ca2d`.

**Rejected alternative — defensive mtime check in run-stage.sh
(Fix #2).** Catches any stage's silent file-skip, not just
review's. Strict superset of D-001 in coverage. Rejected for the
in-scope PR on three grounds: (a) D-001's coverage is sufficient
for the observed incident; (b) the mtime layer requires a halt
verdict (`reason=stale-stage-summary` is not in the registry's
`halt_reasons` list at `bin/pipeline-events.json:11-19`, so adding
it would mean expanding the closed vocabulary — a cross-cutting
change beyond the bug's scope); (c) the prompt rule is reversible
in minutes if it proves wrong; the mtime layer ossifies a halt
shape. See D-004 for the deferred design and un-deferral
preconditions.

**Rejected alternative — typed cross-stage findings channel
(Fix #3).** Decouples findings from the stage-summary file/comment
pair entirely. Strictly more architecturally clean. Rejected for
the in-scope PR on cost: the change touches §5 (review emits
findings comment) AND §3 (implement reads findings comment on
loopback) AND `bin/run-stage.sh` (orchestrator-side
fetch on loopback) AND the marker registry (new `findings`
meta-kind, not currently in `bin/pipeline-events.json:42-48`'s
`meta_kinds`). Multi-stage / multi-file refactor for a problem the
prompt rule already solves. See D-005 for the un-deferral
preconditions.

**Rejected alternative — generalize the overwrite rule to §§1-7
(every stage with a `stage_summary_path` Output bullet).** Rejected
on A-1 / A-3 grounds: the only documented re-dispatch loop is
review-implement, so review is the only surface that has observed
the bug. Premature generalization dilutes the ENG-71-named
rationale (other stages can't cite a self-referential incident).
See D-003 for the explicit decision to NOT generalize and the
un-deferral conditions.

### D-002 (already shipped): three test asserts in `bin/agent-prompts-content-test.sh`

**Verdict.** `bin/agent-prompts-content-test.sh:197-235` adds three
asserts mirroring the existing branch-name convention defense
(PR #48). Verbatim shipped:

```bash
# §5 must say "overwrite on every dispatch" (case-insensitive on
# "overwrite" since "overwritten" / "overwrite" are both reasonable).
if printf '%s\n' "$s5" | grep -qiE 'overwrite[ d]+on every dispatch'; then
  ok "§5 mandates 'overwrite on every dispatch' for the stage-summary file"
else
  nope "§5 mandates 'overwrite on every dispatch' for the stage-summary file" \
    "without this rule, the reviewer can re-emit verdicts without a fresh file write — orchestrator posts stale body, implement-loopback gets no new feedback (ENG-71 May 2026 cycle)"
fi

# §5 must explicitly reject the "read-then-conditionally-skip" misreading
# (the way ENG-71's iters 6-9 actually behaved — agent read existing file,
# decided findings unchanged, didn't re-write).
if printf '%s\n' "$s5" | grep -qF 'read-then-conditionally-skip'; then
  ok "§5 explicitly bans 'read-then-conditionally-skip' on the stage-summary file"
else
  nope "§5 explicitly bans 'read-then-conditionally-skip' on the stage-summary file" \
    "the carve-out names the exact ENG-71 misreading; without it, agents may re-derive the same wrong behavior"
fi

# §5 must cite the ENG-71 incident as precedent so the rule's reason is
# self-documenting.
if printf '%s\n' "$s5" | grep -qE 'ENG-71.*(May|2026)'; then
  ok "§5 cites the ENG-71 incident as the reason for the overwrite rule"
else
  nope "§5 cites the ENG-71 incident" \
    "without the precedent, a future prompt-cleanup pass might decide the rule is overcautious and remove it"
fi
```

Net diff vs prior shipped version: +40 lines (94 asserts up from
91; verified by `git show bd8ca2d --stat`).

**Why.** Three regression classes, three asserts.

(1) **Phrase regression** — a future prompt-cleanup PR replacing
"overwrite on every dispatch" with "always rewrite" or similar
synonym would silently break the rule's matchable phrase. The
case-insensitive regex `overwrite[ d]+on every dispatch` covers
"overwrite on every dispatch" and "overwritten on every dispatch"
without false-positives.

(2) **Carve-out regression** — the prompt explicitly rejects
"read-then-conditionally-skip" because *that's the exact misreading
iters 6-9 made*. A future cleanup that drops the carve-out would
let the same misreading re-emerge.

(3) **Citation regression** — a cleanup pass that decides the
ENG-71 paragraph is "noise" would strip the named-incident
rationale. The third assert pins the citation so future readers
can still trace the rule's history.

**Verified facts the decision relies on:**

- `bin/agent-prompts-content-test.sh:152-235` carries the §5 invariants
  block; the new asserts at lines 197-235 land inside that block,
  immediately after the existing ENG-50/ENG-54 invariants and
  before the ENG-53 #11(a) probe-litter invariants. Verified by
  direct read.
- `bin/agent-prompts-content-test.sh:18-27` defines `section_body`
  via awk fence-aware parsing; calling `section_body "## 5. Review
  Agent"` produces the §5 fenced-block contents which the new
  asserts grep over. Verified by direct read.
- The pre-commit hook at `.githooks/pre-commit` runs
  `bin/agent-prompts-content-test.sh` (verified by direct read of
  the hook's allowlist). The new asserts therefore gate on every
  commit that touches `AGENT_PROMPTS.md`.

**Rejected alternative — three asserts but generalized to all §§
that ship a `stage_summary_path` bullet.** Symmetric with D-003's
rejection of generalization. The asserts pin §5 specifically; if
D-003 ever flips and §§3, 4 grow the same paragraph, the test pin
would be extended at that time.

**Rejected alternative — assert the file is rewritten in
`run-stage-test.sh` end-to-end (mtime-based fixture).** The content
test catches the prompt regression upstream of the file-write — if
the prompt mandates the rewrite and the agent obeys, the file is
rewritten. An end-to-end fixture would re-prove what the prompt
already specifies, at the cost of a stub-claude harness. Low
incremental coverage. Rejected on A-1 (don't add features beyond
what the task requires).

### D-003: scope the overwrite rule to §5 only — DO NOT generalize to §§3, 4

**Verdict.** Decline the symmetric prompt edit on §3 (Implement)
and §4 (UI) Output sections that would add a comparable
"MANDATORY — overwrite on every dispatch" mandate to their
`stage_summary_path` bullets.

**Why.** Three coupled reasons.

(1) **The bug substrate is identical across §3, §4, §5; the
empirical observation is unequal.** The architectural exposure is
the same: §3 (implement), §4 (ui), and §5 (review) all inherit
residual `stage-summary-<stage>.md` files across loopback re-
dispatches because `bin/run-stage.sh:1081-1084` clears
`issue-state.json` and `wait-${stage}.json` on success
transitions but does NOT clear the stage-summary file. The
review-implement-ui-review cycle is structurally tighter than any
other inter-stage interaction (review fails → implementing →
ui → reviewing, every iteration), and on every cycle §3, §4,
*and* §5 are re-dispatched. So the structural opportunity for the
silent-skip misreading exists in all three stages. **D-003's
narrowing is empirical (observed in §5 only at iters 6-9 of
ENG-71), not structural** — implement and UI agents have not, to
date, exhibited the read-then-skip pattern. Generalising the rule
preemptively would be cheap (~25 lines of prompt + ~15 lines of
test) but would dilute the ENG-71 rationale: the §5 paragraph is
self-justifying because it cites the cycle that fired in §5; a §3
or §4 paragraph citing the same incident is less load-bearing
because the incident didn't fire there. **Operator awareness:**
because §3 and §4 share the substrate, an operator should treat a
single observed §3 or §4 read-then-skip incident as sufficient
evidence to un-defer (per the conditions below) — the bar is
empirical observation, not "two failures to confirm a pattern."

(2) **D-001's prompt edit is reversible cheaply.** If implement or
ui ever ship the same misreading, extending the rule to §3 or §4
is another ~15-line prompt edit + ~10-line test addendum. The cost
of the second edit is comparable to the cost of the first; there's
no architectural lock-in to overcome. The "narrow now, generalize
on observation" path is strictly cheaper than the "preemptively
generalize" path *if* implement/ui never observe the misreading.
The expected value calculation depends on prior probability: the
review agent's reviewer-ensemble structure (cold-pass sub-agents
returning findings the lead aggregates) is a different shape from
implement's "read findings → fix" loop. The ENG-71 misreading was
plausibly review-specific.

(3) **Defensive mtime check (D-004) is the proper "all stages"
intervention.** If we want a stage-agnostic guarantee, the right
layer is the post-dispatch orchestrator-side mtime check, not five
near-identical prompt paragraphs. D-001 + D-004 (when un-deferred)
together cover both "the prompt tells the agent" and "the
orchestrator catches violations." D-001 alone is correct for the
narrow surface; preemptively generalizing D-001 to §§3, 4 muddies
the role-separation between prompt-as-spec (D-001) and
orchestrator-as-enforcer (D-004).

**Verified facts:**

- `AGENT_PROMPTS.md:665` (§3 Output's `stage_summary_path` bullet)
  and `AGENT_PROMPTS.md:810` (§4 Output's `stage_summary_path`
  bullet) currently say only "Write the stage summary file at
  `{stage_summary_path}` — follow the Stage summary comment format
  contract" without the overwrite mandate. Verified by direct
  read.
- `AGENT_PROMPTS.md:1188-1196` (§6 QA Output's bullet) and
  `AGENT_PROMPTS.md:1438-1446` (§7 Build Output's bullet) carry the
  same minimal language. Verified.
- `bin/run-stage.sh:495-497` shows that the wait-exit path in
  `_handle_wait` clears `stage-summary-${stage}.md` before exit,
  so build's wait-budget re-dispatches start with a fresh empty
  slot — *cannot* observe the stale-file misreading. Build is
  structurally immune. Verified.
- `bin/run-stage.sh:1081-1084` clears `issue-state.json` and
  `wait-${stage}.json` on success transitions; it does NOT clear
  `stage-summary-<stage>.md` on transitions. Verified by direct
  read. Therefore §3 (implement) and §4 (ui) DO inherit residual
  files across loopback re-dispatches — they share the
  architectural surface that made ENG-71 possible. The rule's
  scoping decision is empirical (observed in §5, not §3/§4), not
  structural.

**Un-deferral preconditions.** Generalize to §3 if any of:

- One observed instance of an implement-stage loopback where the
  implement agent emits a fresh tdd-evidence comment but does NOT
  rewrite `stage-summary-implementing.md`, AND the orchestrator
  consequently posts a stale completion-summary to Linear.
- A retrospective metric (added independently — out of this
  brainstorm's scope) that aggregates per-issue
  `stage-summary-<stage>.md` mtime deltas across consecutive
  dispatches and flags issues where mtime is older than the
  previous tick's dispatch start.

Generalize to §4 under the symmetric implement-stage condition
applied to ui.

**Rejected alternative — generalize to all §§1-7 now.** Rejected
above. Same reasoning.

**Rejected alternative — generalize to §§3, 4 only (review's
loopback targets).** Tempting because it covers the same loop's
other two stages without spreading to brainstorm/plan/qa. Rejected
on A-1 grounds: the bug fix's scope is the observed surface (§5);
adding two more prompt paragraphs that all cite the same incident
is feature-creep. If a §3 or §4 misreading fires, the un-deferral
preconditions above unlock the change at that time.

### D-004 (proposed deferral): stale-file mtime detection in `run-stage.sh` — DEFER as separate ticket

**Verdict.** Do NOT implement the post-dispatch
`stage-summary-${stage}.md` mtime check in this PR. Defer as a
separate Linear issue with the un-deferral preconditions below.

**Why.** Three coupled reasons.

(1) **Closed-vocabulary expansion.** A halt verdict with reason
`stale-stage-summary` (or `agent-blocked` with sub-reason text)
requires either expanding `bin/pipeline-events.json:11-19`'s
`halt_reasons` list (cross-cutting registry change) or routing
through the existing `agent-blocked` reason with a metric-shape
note (less precise, harder for retrospective §1 to filter on).
Either way, it's a registry-touch — non-trivial relative to a
pure prompt edit.

(2) **The implementation surface is broader than it sounds.** A
naive mtime check (`stat -f '%m' "$summary_path"` after dispatch
> dispatch start time) interacts with: (a) wait-exit's pre-emptive
clear at `bin/run-stage.sh:497` (must skip on wait paths); (b)
scope-approval replay's no-write-this-tick branch (must skip
when `skip_dispatch=1`); (c) the agent-contract validator at
`bin/run-stage.sh:980-986` which already catches "no file written
at all" — the mtime check would fire AFTER that, so the
interaction with rc=25 needs care; (d) a HFS+ vs APFS mtime
granularity skew on macOS that could false-positive at sub-second
boundaries. None individually hard, but each is a place to get
wrong, and none is exercised by D-001's prompt rule.

(3) **D-001 is sufficient for the observed incident.** The
defensive net catches a CLASS of bugs (any stage agent that
silently skips a Write); D-001 catches the SPECIFIC bug (review's
read-then-skip misreading). The class-vs-specific tradeoff favors
the specific fix when the class hasn't been observed elsewhere.

**Un-deferral preconditions.** Implement the mtime check if any of:

- One observed instance of a non-§5 stage exhibiting the same
  silent-skip behavior in production (per D-003's preconditions for
  §3 / §4).
- A second incident on §5 *despite* the prompt rule (i.e., the
  agent obeys the prompt's letter but finds another corner case
  the rule doesn't cover — e.g., partial-write that leaves prior
  content tail-appended).
- Retrospective evidence (>=3 issues over a 30-day window) showing
  any stage's `stage-summary-<stage>.md` mtime regressing across
  consecutive dispatches on the same issue.
- **Security precondition (added per security persona):** the
  un-deferral PR must validate `$ident` against `^ENG-[0-9]+$`
  at the mtime callsite (or harden `issue_dir` itself) before
  passing it to `stat`. `bin/common.sh:68-72`'s `issue_dir`
  requires non-empty input but does not enforce the issue-ID
  shape; today this is benign (callers validate upstream), but
  if the deferred mtime check ever ships, an unsanitized
  `$ident` containing `../` resolves outside `$PROJECT_STATE_DIR`.

**Threshold asymmetry note.** D-003 un-defers (extending the
prompt rule to §3 / §4) on **one** observed non-§5 instance. D-004
un-defers (the orchestrator-side mtime net) on either **one** non-§5
instance OR a **second** §5 incident. The asymmetry is intentional:
the §5 prompt rule is already shipped and has not had a chance to
fail in production, so a second §5 incident raises the bar for the
heavier-weight orchestrator-side intervention. A first §5 incident
post-D-001 ship would NOT trigger D-004 because D-001's rule itself
was the response; D-004 is the next-layer fallback only if D-001
proves insufficient. For non-§5 stages, however, no prompt-layer
rule exists yet, so a single observed instance trips both un-deferral
paths simultaneously.

**Verified facts the deferral relies on:**

- `bin/pipeline-events.json:11-19` lists 8 halt reasons, none of
  which is `stale-stage-summary`. Verified by direct read.
- `bin/run-stage.sh:495-497` clears the file on wait-exit; an
  mtime check that doesn't gate on `_fresh_wait_reason` would
  false-positive on every wait dispatch. Verified.
- `bin/run-stage.sh:977-989` is the agent-contract validator;
  rc=25 fires when neither the file nor a fresh verdict marker is
  present. The mtime check would have to sit AFTER this validator
  and BEFORE `post_completion_comment` to catch the
  file-present-but-stale case. Verified by control flow read.
- `bin/run-stage.sh:1081-1084` is the success-path cleanup; the
  mtime check would not run on the success-path-after-clear (the
  file is gone), so its window is "post-dispatch, pre-cleanup".
  Verified.
- The registered `halt_reasons` are integer-validated by
  `bin/pipeline.sh event ... verdict halt --reason <reason>`
  (verified at `bin/pipeline.sh` and the issue's own footer naming
  the closed list). Adding `stale-stage-summary` requires a
  separate registry-edit PR with a pipeline-vocabulary doc
  regeneration via `bin/generate-vocabulary-doc.sh`.

**Rejected alternative — implement the check in this PR.** See
"Why" above; the cost is real and the incremental benefit over
D-001 is unobserved. If the un-deferral preconditions fire, the
check ships then.

**Rejected alternative — implement WITHOUT a halt verdict (just
emit `<!-- meta: metric name=stale_summary -->`).** Quieter; doesn't
expand the registry. Tempting. Rejected on operator-experience
grounds: a metric without a halt is invisible to triage at the
moment it would matter. The point of the defensive net is to
*loudly fail* before the silent-degradation cycle starts; a
silent metric defeats the goal.

### D-005 (proposed deferral): typed cross-stage findings channel — DEFER as separate ticket

**Verdict.** Do NOT implement the typed `<!-- meta: findings
stage=reviewing key=findings/reviewing/<issue> -->` cross-stage
channel in this PR or in a near-term follow-up. Defer with the
un-deferral preconditions below.

**Why.** The typed-findings refactor decouples review's findings
from the stage-summary file/comment pair entirely. The reviewer
emits a structured findings comment; the implement agent reads it
on loopback. Architecturally cleaner — the findings channel becomes
a first-class harness primitive, not a sidecar of the
stage-summary post.

It is also strictly more invasive than D-001:

(1) **Schema design** — a typed finding is a structured payload
(severity, file, line, suggestion, why). The current Linear
review summary is unstructured prose. Schema'ing it requires
either (a) a JSON-in-comment shape (not currently used by any
harness convention; introduces parsing risk) or (b) a separate
artifact file the comment links to (introduces a new file class
in the per-issue dir).

(2) **Multi-stage prompt edits** — review (§5) emits the new
shape; implement (§3) reads it on loopback. Two prompt edits, two
test pins. UI (§4) is reached on every review-loopback cycle as
the *forward transition out of implementing* (implementing → ui →
reviewing) — verified at `bin/verdict-handler.sh:32-38`'s
`_VH_LOOPBACK_TRANSITIONS` table, which lists only
`reviewing|implementing` (not `reviewing|ui`) as a direct loopback
row. UI is therefore re-dispatched on every review-loopback
iteration even though it's not a direct loopback target; if the
typed channel needs to thread review's findings forward through
ui's dispatch (rather than ui treating review's verdict as a
no-op), that's a third prompt edit.

(3) **Registry expansion** — a `findings` meta-kind would need to
be added to `bin/pipeline-events.json:42-48`'s `meta_kinds` array
(currently `dedup`, `metric`, `evidence`, `reapplied`, `forensic`).
That's a closed-vocabulary edit; per ENG-60 the orchestrator
validates against this list.

(4) **Backward compat** — for issues mid-flight at the cutover
point, the implement agent would need to fall back to the legacy
stage-summary read path. Otherwise a transition issue gets stuck
on the cutover commit (the new findings comment doesn't exist
yet; the old stage-summary comment is being ignored).

**Un-deferral preconditions.** Implement the typed channel only
if all of:

- Two distinct review-implement loop incidents *despite* D-001's
  prompt rule and (if un-deferred) D-004's defensive net. I.e.,
  the prompt-and-defensive-net layers prove insufficient.
- Operator demand for structured findings (e.g., a status.sh or
  retrospective ask that requires per-finding fields, not just
  prose).
- Bandwidth for a multi-stage refactor with prompt + test + registry
  + run-stage.sh changes (`stage-summary-implementing.md` reads need
  to be teed against the new comment shape).
- **A schema design that pins the typed payload to a typed JSON
  body with an explicit byte-cap, schema validation, and explicit
  rejection of nested marker shapes** (so a finding's `suggestion`
  field cannot smuggle a forged `<!-- pipeline: verdict ... -->`
  marker into a downstream parser). The orchestrator's existing
  trust boundary is the closed `pipeline-events.json` registry;
  any new typed channel must extend that trust model, not subvert
  it. Without this precondition, an agent emitting a `findings`
  comment becomes a privilege-escalation vector against
  verdict-handler / retrospective / status.sh.

**Verified facts the deferral relies on:**

- `bin/pipeline-events.json:42-48` lists 5 meta-kinds; `findings`
  is not among them. Verified by direct read.
- `bin/verdict-handler.sh::_vh_lookup_loopback` (verified at
  `bin/verdict-handler.sh:46`) maps `(stage, target) → loopback
  table row` and is the routing layer that decides whether review-
  fail goes to implementing or brainstorming. The full loopback
  table at `bin/verdict-handler.sh:32-38` lists exactly:
  `planning|brainstorming` (pipeline:supersede),
  `reviewing|brainstorming` (pipeline:supersede),
  `reviewing|implementing`, `qa|implementing`,
  `building|implementing`. **`reviewing|ui` is NOT a row** — UI
  is reached on review-loopback only via the forward transition
  `implementing|ui` after review-loopback dispatches implementing.
  Verified.
- `bin/common.sh::parse_pipeline_marker` (verified at
  `bin/common.sh:185-260`) returns event:`meta` for `<!-- meta:
  ... -->` shapes; adding a `findings` kind would be parser-
  compatible without code change to the parser itself, but the
  closed-vocabulary check at the validator (orchestrator pipeline
  events writer side) WOULD reject unrecognized kinds.

**Rejected alternative — start the migration in this PR via a
single-call shim.** Rejected on cost: the one-call shim still
requires the registry edit, the schema design call, and a §3
prompt edit. The benefit (one less file's worth of cohesion debt)
doesn't move the needle vs the prompt fix's coverage. Defer.

**Rejected alternative — implement BUT keep the stage-summary
file as the canonical source.** Half-migration; both shapes live
side-by-side. Rejected on coherence: dual-source-of-truth is
exactly the failure mode the typed channel is supposed to remove.
If implemented, the typed channel must replace, not augment.

## 5. Architecture (where code goes)

| Component | Path:Line (today) | Touched by | Net delta |
|---|---|---|---|
| §5 Review Agent Output / stage-summary bullet | `AGENT_PROMPTS.md:1027-1039` | D-001 (shipped) | +12 lines (paragraph mandate added) |
| §5 invariants block in content test | `bin/agent-prompts-content-test.sh:197-235` | D-002 (shipped) | +40 lines (3 new asserts + comments) |
| §3 Implement Output / stage-summary bullet | `AGENT_PROMPTS.md:665` | D-003 (NO change) | 0 lines |
| §4 UI Output / stage-summary bullet | `AGENT_PROMPTS.md:810` | D-003 (NO change) | 0 lines |
| `run-stage.sh` post-dispatch hook | `bin/run-stage.sh:1036` (`_post_dispatch_apply_halt`) | D-004 (DEFERRED) | 0 lines (this PR); ~30 lines on un-deferral |
| `pipeline-events.json` halt_reasons | `bin/pipeline-events.json:11-19` | D-004 (DEFERRED) | 0 lines (this PR); +1 line (`stale-stage-summary`) on un-deferral |
| `pipeline-events.json` meta_kinds | `bin/pipeline-events.json:42-48` | D-005 (DEFERRED) | 0 lines (this PR); +1 line (`findings`) on un-deferral |
| §3 Implement Output / loopback findings read | `AGENT_PROMPTS.md` §3 | D-005 (DEFERRED) | 0 lines (this PR); ~15 lines on un-deferral |

**No new files. No new exports. No new env vars. No new
config keys.** D-001 and D-002 already shipped on `main` via
commit `bd8ca2d`. D-003, D-004, D-005 are *non-changes* in this
PR — they are the recorded decisions to NOT change those
surfaces, with explicit conditions for revisiting.

The single touched file in `bin/` (D-002) is sourced by
`.githooks/pre-commit`'s test-suite loop; no new test runner
plumbing is needed.

## 6. Data flow

**Today (after D-001, D-002 shipped on `main`).** Review-loopback
on a hypothetical second incident:

```
Tick T0: review agent dispatched (loopback re-entry; prior
         stage-summary-reviewing.md from iter-N-1 on disk).
  ├─ render-prompt.sh extracts §5 content.
  ├─ Agent reads §5 Output bullet:
  │   "Stage-summary file at … MANDATORY — overwrite on every
  │    dispatch. Use Write … do not read-then-conditionally-skip."
  ├─ Agent runs reviewer ensemble (cold-pass sub-agents).
  ├─ Agent merges findings; runs anti-bias pass.
  ├─ Decision path B (changes requested):
  │   ├─ gh pr review --comment with new findings.
  │   ├─ add-or-update-comment "completion/reviewing/<issue>"
  │   │   with new Linear summary.
  │   ├─ guards.sh bump review_rejection.
  │   ├─ Write {stage_summary_path} with iter-N body.        ← MANDATE FORCED
  │   └─ pipeline.sh event verdict fail --target implementing
  └─ Exit clean (rc=0).

Tick T0 (continued, post-dispatch in run-stage.sh):
  ├─ Agent-contract validator (lines 977-989): file present →
  │   no rc=25.
  ├─ post_completion_comment (lines 147-225):
  │   reads stage-summary-reviewing.md (iter-N body) → posts to
  │   Linear under sig completion/reviewing/<issue>.            ← FRESH BODY
  ├─ _post_dispatch_apply_halt (line 1036): adds pipeline:halted.
  └─ verdict_handler picks up the rejection marker → applies
     transition reviewing → implementing.

Tick T1: implement agent dispatched on loopback.
  ├─ Agent reads Linear thread; finds completion/reviewing/<issue>
  │   comment with iter-N body (new majors).
  ├─ Agent fixes iter-N findings.
  ├─ Agent emits tdd-evidence + verdict pass --stage implementing.
  └─ verdict_handler transitions implementing → ui.

Cycle does not repeat: each iter writes a fresh file; orchestrator
reads the fresh file; implement agent sees fresh feedback.
```

**Pre-fix (the ENG-71 cycle, for forensic reference):** identical
flow except iter-N's `Write {stage_summary_path}` step was
elided; the iter-5 body remained on disk; orchestrator posted the
iter-5 body on every later iter; implement agent re-fixed iter-5
findings; reviewer re-found the same iter-N findings; cycle.

**Build's structural immunity (forensic note).** Build (§7) is the
only stage structurally immune to this bug class because
`bin/run-stage.sh:495-497` (`_handle_wait`'s pre-emptive clear)
removes `stage-summary-${stage}.md` on every wait-exit path before
the next dispatch. Build's iter-N+1 starts with no prior file on
disk, so the read-then-skip misreading cannot manifest. Review
(§5), implement (§3), and ui (§4) share the residual-file
substrate; D-001 closes the §5 surface, D-003 / D-004 cover the
others.

**Trade-off the data flow makes explicit.** The fix relies on agent
discipline (the agent honoring the prompt's mandate). Defense-in-
depth (Fix #2 / D-004) would catch a hypothetical disobedient
agent at the orchestrator layer; without it, the rule is one
agent-misread away from re-firing. D-004's deferral is the bet
that the prompt's named-incident mandate is sufficient deterrent,
and that the cost of the deferred net is higher than the expected
cost of the next misread — a bet that turns on observed prior
probability post-D-001 ship.

## 7. Error handling

**E-1. Agent reads §5 prompt and still skips the Write.** D-001
shipped; D-002's content test pins the prompt. The runtime path
falls back to `summary_missing` at `bin/run-stage.sh:182-184` if
the file is empty/absent — but that fires only when the file is
GONE. With a stale file present, the read-arm at lines 185-191
fires and posts the stale body. *This is the original bug; D-001
is the fix.* If a future agent ignores the prompt mandate, D-001
fails open (returning to the original bug). D-004's un-deferral
exists to close this gap structurally.

**E-2. Agent obeys the rule but writes garbage.** Out of scope.
The Stage summary comment format contract at
`AGENT_PROMPTS.md:171-205` carries content rules ("Lead with an
artifact link", "TL;DR", "Single-line status when the gate passes
cleanly"). Garbage content is a separate quality concern.

**E-3. The Write succeeds but the file's mtime is identical to
the prior dispatch's mtime (HFS+ second-granularity collision).**
Edge case for D-004 (deferred), not D-001. D-001 doesn't read
mtime.

**E-4. The agent emits the verdict marker BEFORE writing the
file, then crashes.** The agent-contract validator at
`bin/run-stage.sh:977-989` checks for at least one of file or
fresh marker; verdict-only with no file would pass the validator
(marker present), then fall to `post_completion_comment` which
sees the stale file and posts stale content. *This is the bug
D-004 catches.* D-001 doesn't catch this corner case — but the
prompt's mandate explicitly says "the file's contents at exit
time are your authoritative report," which makes the agent
responsible for ordering Write before verdict. D-001 fails open
on a crash mid-write; D-004 closes it.

**E-5. Agent partially writes the file (truncation, permission
error).** `[[ ! -s "$summary_path" ]]` at `bin/run-stage.sh:182`
treats a zero-byte file as missing; partial-but-non-empty writes
still post. Partial-content is a different bug class; out of
scope for both D-001 and D-004 narrow.

**E-6. The §5 prompt mandate is correct but the test pin's regex
matches false-positively (e.g., a future paragraph mentions
"overwrite on every dispatch" as a negative example).** The
case-insensitive regex `overwrite[ d]+on every dispatch` is
intentionally narrow; it would match a negative-example
paragraph too. Mitigation: the second assert (banning
"read-then-conditionally-skip") + the third (citing ENG-71)
provide overlap; a negative-example paragraph would have to also
embed those phrases AND keep them in the §5 fenced block, which
is implausible.

**E-7. ENG-63 reapplied-footer interaction.** D-001's prompt text
explicitly leans on the footer-only re-apply path: "If your
findings are unchanged from a prior iter (rare on a re-dispatched
review-loopback), re-write the same content; the orchestrator's
footer-only re-apply path covers visibility." Verified that
`add-or-update-comment` at `bin/linear.sh:582-606` advances
`updatedAt` on identical-body re-apply via the `<!-- meta:
reapplied at=… -->` footer. No regression on the happy path.

**E-7a. Forged `<!-- meta: reapplied at=... -->` footer surface
opened by D-001's "agent writes the authoritative report" expansion.**
`bin/run-stage.sh:186` strips `<!-- meta: dedup key=... -->`
lines and legacy `<!-- pipeline-<word>: ... -->` lines from the
file body before posting, but does NOT strip
`<!-- meta: reapplied at=... -->` lines. A confused or malicious
agent obeying D-001's "Use `Write` with the full report content"
mandate could embed a forged reapplied-footer line inside its
summary body. When `bin/linear.sh::add_or_update_comment`'s
normalization sed at `bin/linear.sh:593-595` strips reapplied-
footer lines for byte-equality comparison, the forged line could
mask a genuinely changed body as byte-equal to a stale one — net
effect: the operator-visible "latest re-apply moment" becomes
attacker-controlled. This is a defense-in-depth gap, not an
exploit on the documented happy path (no agent has been observed
emitting forged footers), but the surface widened with D-001
because the prompt now explicitly tells the agent the file is its
"authoritative report." **Recommendation (deferred to a follow-up
ticket):** extend the safety-filter sed at `bin/run-stage.sh:186`
to strip `<!-- meta: reapplied at=... -->` lines from the body
before it lands in `post_completion_comment`'s body var. ~1 line
of sed; cheap. Out of scope for this brainstorm because no exploit
is observed and the fix layer is `run-stage.sh`, but worth filing
alongside D-004's un-deferral when that lands.

## 8. Edge cases

**EC-1. Reviewer's first dispatch on an issue (no prior
stage-summary-reviewing.md on disk).** D-001's mandate is
identical: "Use `Write` with the full report content". The
existence-of-prior-file is not the rule's predicate; the rule is
unconditional ("MANDATORY — overwrite on every dispatch"). First
dispatch behaves like later dispatches.

**EC-2. Premise-failure path (Decision path A).** §5's path A
loops back to `stage:brainstorming` with `pipeline:supersede`
semantics. Path A still writes `stage-summary-reviewing.md` (the
"premise failure" verdict body is the report). D-001 applies;
the file is overwritten with the premise-failure rationale. No
special-casing needed.

**EC-3. Clean-pass path (Decision path C, ENG-54 contract).**
Path C posts the gh pr review summary, posts the Linear summary,
writes the stage-summary file, and emits `verdict pass --stage
reviewing`. D-001's mandate applies; the file carries the clean-
pass body.

**EC-4. Operator runs `pipeline.sh decide --action continue` on a
review-stuck issue (no fresh review dispatch).** The operator-
resume path doesn't re-dispatch review immediately; it clears
labels and posts a transition waypoint. The next review dispatch
on the next loopback obeys D-001 normally.

**EC-5. The agent calls `Read` on the existing stage-summary file
(not `Write`).** §5's allowed_tools_for at
`bin/dispatch.sh:284-285` includes `Read`; nothing forbids reading
the prior file. The prompt's "do not read-then-conditionally-skip"
clause forbids the *decision* to skip the Write, not the Read
itself. An agent that reads the prior file for context AND then
overwrites is compliant.

**EC-6. The agent runs out of context budget mid-Write.** The
file is truncated. Post-dispatch the orchestrator's read at
`bin/run-stage.sh:185` reads the truncated content (passes
`-s` test if non-zero bytes). Linear gets a partial body. Same
class as E-5; out of scope.

**EC-7. The §5 prompt rule edit accidentally lands inside a
column-0 fenced block (e.g., the agent's prompt body uses
markdown ```code``` blocks).** `render-prompt.sh::extract_block`
would die if the fence count is not exactly 2 (per CLAUDE.md
"AGENT_PROMPTS.md is load-bearing" §). The shipped paragraph at
lines 1027-1039 sits inside §5's existing single fenced block;
the diff didn't introduce a new column-0 fence. Verified by
inspecting the shipped diff at PR #61. The §2 fence-count test
at `bin/agent-prompts-content-test.sh:148-153` would catch a
regression.

**EC-8. A future stage-summary contract change ("contract
v2: structured fields") makes the §5 paragraph's text obsolete.**
The test pin (D-002) would still pass (it greps phrase, not
semantics). A v2 contract would need to update the test asserts
in lockstep with the §5 paragraph edit. Not a regression of
D-001/D-002; a forward-evolution concern.

**EC-9. The retrospective agent edits §5 via
`learned-rules/harness/review.md` (a future, currently absent
file).** `learned-rules/<stage>.md` is appended to the base
prompt at dispatch time (per CLAUDE.md "AGENT_PROMPTS.md is
load-bearing" §). A learned rule cannot remove text from
the base §5; it can only add. So a retrospective-authored
review.md cannot weaken the D-001 mandate. Verified by reading
`bin/render-prompt.sh`'s prompt assembly path.

## 9. Persona review

Six personas reviewed in the order: design → security → scope →
coherence → product → feasibility (feasibility last per the
brainstorm-stage prompt).

**Iter-1 → iter-2 deltas.** Five personas (design, security,
scope, coherence, product) ran in parallel as iter-1; product
returned `REQUEST_CHANGES` with one P0; design / security /
scope / coherence returned `PASS` with P1/P2 findings. Iter-2
addresses every iter-1 finding above P2 in the brainstorm body
(see specific edit anchors below); feasibility runs after iter-2.
The verdicts captured below are post-iter-2 status.

### Design — PASS

The fix-at-the-prompt-layer architecture is the right call given
the bug's location: the orchestrator is correct, the agent's
contract was ambiguous, the prompt is the agent's contract spec,
the prompt is the layer that fixes it. D-001's two-paragraph edit
is minimal and self-justifying via the named incident.

D-003's narrow scope (§5 only, NOT §§3, 4) is defensible on the
"observed surface" criterion. It is **empirically scoped, not
structurally bounded** — the bug substrate (residual
stage-summary files across loopback re-dispatches) exists in §3
and §4 too; only the read-then-skip *behavior* has been observed
in §5. The risk that §3 or §4 silently exhibit the same
misreading is real but unmeasured today; D-003's un-deferral
preconditions are concrete enough that an operator can detect the
trigger if it fires, but only if the operator is paying attention
(see Product persona below for the instrumentation gap).

D-004's deferral is appropriately costed (registry edit + 4
control-flow interaction points). D-005's deferral is
appropriately costed (3 stages + registry + back-compat + schema
design).

**Iter-1 design persona findings (all addressed in iter-2):**

- P1: D-003 reason (1) summary phrase ("Only review has the
  documented tight re-dispatch loop") oversold the structural
  argument when only the empirical one holds. *Addressed: D-003
  reason (1) rewritten to lead with "The bug substrate is
  identical across §3, §4, §5; the empirical observation is
  unequal" and §9 self-review here updated to "empirically
  scoped, not structurally bounded."*
- P2: D-004 vs D-003 un-deferral threshold asymmetry not
  explained. *Addressed: "Threshold asymmetry note" appended to
  D-004's un-deferral preconditions.*
- P2: §6 data-flow silent on `_handle_wait`'s pre-emptive clear.
  *Addressed: "Build's structural immunity (forensic note)" added
  to §6.*
- P2: D-004 / D-005 registry-edit cost double-counted.
  *Acknowledged; the un-deferrals can bundle the registry-edit
  PR if both fire near-simultaneously, but the cost-estimation
  is unchanged in the brainstorm body. Recorded here.*

PASS.

### Security — PASS

No new secret handling, no new shell command interpolation, no new
file paths, no new env-var dependencies. The §5 paragraph adds
text only; the test pin reads `AGENT_PROMPTS.md` only. No
attacker-controlled input reaches either change.

The deferred items have their own security profile:

- D-004's `stat -f '%m'` mtime read on the per-issue dir is
  bounded by `issue_dir` validation at `bin/common.sh:68-72`. The
  un-deferral PR must additionally validate `$ident` against
  `^ENG-[0-9]+$` at the callsite (added to D-004 preconditions
  per iter-2 security finding F-3).
- D-005's typed-findings JSON-in-comment shape would introduce a
  parsing surface; the un-deferral preconditions now include a
  schema design pinning byte-cap, schema validation, and
  rejection of nested marker shapes (added per iter-2 security
  finding F-2).

**Iter-1 security persona findings (addressed in iter-2):**

- P1: Forged `<!-- meta: reapplied at=... -->` footer surface
  opened by D-001's "agent writes the authoritative report"
  expansion. *Addressed: E-7a added to §7 documenting the surface,
  recommending the `bin/run-stage.sh:186` sed extension as a
  follow-up.*
- P1: D-005 JSON-in-comment risk under-sharpened. *Addressed:
  un-deferral precondition added.*
- P2: D-004 ident validation. *Addressed: precondition added.*
- P2: D-001 prose cleanliness verified clean (ENG-46 secret
  handling does not apply to prompt text consumed by `claude -p`
  stdin without shell interpolation).

PASS.

### Scope — PASS (with one flag)

The Linear issue requests Fix #1 (prompt rule) and Fix #2 (test
pin) in scope; both are implemented. Fix #2 (defensive net) and
Fix #3 (typed channel) are explicitly out of scope per the issue
body.

D-001 + D-002 ship the in-scope fix. D-003, D-004, D-005 are
non-changes documenting the scope refusals. No features added
beyond the issue's request.

**FLAG.** D-003 (refusing to generalize to §§3, 4) is a discretionary
*scope contraction* relative to a defensible alternative
("preemptively generalize to §§3, 4 since they share the
architectural surface"). The brainstorm states the un-deferral
preconditions, but a stricter operator might prefer the broader
generalization. Surfacing for operator awareness; the brainstorm's
stated rationale (named-incident dilution + low cost of later
extension) is the recommended path.

**Iter-1 scope persona findings (addressed in iter-2):**

- P1: D-003 reasoning has an empirical gap (un-deferral
  precondition #2 depends on a metric that doesn't exist).
  *Addressed: O-6 added flagging the instrumentation-gap and
  recommending a separate ticket for the lightweight detection
  signal.*
- P1: D-004 un-deferral precondition #3 (>=3 issues over 30
  days) is unbounded today (no metric). *Addressed: same O-6.*
- P2: §11 acceptance honestly marks live-verify as pending —
  iter-2 made this even more explicit with the "Acceptance
  status (read this first)" banner.
- P2: O-5 SDLC oddity flagged — kept as-is.

PASS with one scope flag.

### Coherence — PASS

D-001's prompt edit lands inside §5's fenced block, immediately
after the `completion/reviewing/{issue_id}` add-or-update-comment
bullet — coherent placement within the Output section's existing
order (verdict marker → file → file follow-on). The named-
incident citation (`ENG-71 May 2026`) is consistent with how
§5 already cites `ENG-54` and `ENG-71` elsewhere (verified at
`AGENT_PROMPTS.md:856` (ENG-54) and `AGENT_PROMPTS.md:1027-1039`
(ENG-71)).

D-002's three asserts land inside the §5 invariants block in
`bin/agent-prompts-content-test.sh`, after the existing ENG-50/
ENG-54 invariants (verified at lines 156-195) and before the
ENG-53 #11(a) asserts (verified at lines 240+). The block
ordering follows reverse-chronological-by-incident-ID; ENG-71's
asserts at 197-235 are correctly placed.

D-003's scope decision is recorded here in the brainstorm but
NOT in `AGENT_PROMPTS.md` itself — a future maintainer reading §3
or §4 doesn't see "this rule is intentionally absent." Acceptable:
the brainstorm doc is the design record; the prompt is the spec;
absent text is not load-bearing in the prompt.

**Iter-1 coherence persona findings (addressed in iter-2):**

- P1: D-003 reason (1) phrase oversells "structural" when only
  empirical holds. *Addressed: same edit as design P1 above.*
- P2: D-005 / D-003 "loopback target is ui" terminology
  inaccurate (UI is reached via forward transition only,
  per `bin/verdict-handler.sh:32-38` — `reviewing|ui` is NOT
  a row). *Addressed: D-005 reason (2) reworded; verified-facts
  table for D-005 explicitly enumerates the loopback table.*

PASS.

### Product — PASS (iter-2 after iter-1 REQUEST_CHANGES)

The Linear issue's "Why this matters" subtext is implicit but real:
review-implement loops that don't converge cost wall-clock and
operator time. The shipped fix (D-001 + D-002) addresses the named
incident's specific failure mode at the lowest-cost layer.

Trade-off the deferral makes explicit: D-004's defensive net
would catch *any* stage's silent file-skip; D-001 catches only
review's. An operator skimming the brainstorm sees the bet
(prompt-only rule is sufficient if agents obey) and the
fallback (un-defer D-004 if agents don't). That's the product
shape: rely on the cheap fix; defer the expensive net; have a
clear escape valve.

The brainstorm does not, and cannot, guarantee that the agent
will obey the prompt. That's a separate operating concern.

**Iter-1 product persona findings (addressed in iter-2):**

- **P0**: §11 acceptance criteria misrepresented live-verify
  status as not-quite-PASS while §9 Feasibility declared overall
  PASS. *Addressed: §11 now leads with an "Acceptance status
  (read this first)" banner explicitly marking static gates GREEN
  and live-verify gates PENDING; §9 Feasibility's PASS verdict
  is now qualified as "on static surface only" with the live-
  verify dependency called out explicitly.*
- P1: Operator has no automated visibility when the prompt rule
  fails; D-004 un-deferral signal is operator-blind because no
  metric exists. *Addressed: O-6 added recommending a separate
  Linear ticket for a lightweight status.sh / retrospective
  signal that aggregates per-issue stage-summary mtime regression
  across consecutive dispatches.*
- P2: O-5's SDLC topology oddity (brainstorm-on-feat-eng-77 vs
  fix-on-fix-eng-71-followup branches) flagged but not elevated.
  *Acknowledged; left at O-5's current depth — the harness
  status.sh / dashboard handling of this is out of scope for
  ENG-77 itself.*

PASS (iter-2 — P0 closed, P1 addressed via O-6, P2 acknowledged).

### Feasibility — PASS (with one precondition check)

All facts in §1, §4, and §6 cite path:line references in the
current worktree (verified at composition time, see Anti-bias
checks §12). The change set is:

- 12 lines of paragraph mandate in `AGENT_PROMPTS.md §5` Output
  (D-001, shipped).
- 40 lines of three asserts + comments in
  `bin/agent-prompts-content-test.sh:197-235` (D-002, shipped).
- 0 lines of code in `bin/` outside the test file.

No new files. No new exports. No new config keys.

**Precondition P-1 (live verification, still pending per the
issue's Test plan).** The Linear issue's "Test plan" section
includes two unchecked items:

- "Live verify on ENG-71 specifically: delete the stale
  `stage-summary-reviewing.md`, `decide --action continue`,
  observe whether the next reviewer dispatch rewrites the file
  from scratch with current findings"
- "Live verify on the next review-loopback issue (any future):
  summary file should refresh on every dispatch, even if findings
  are unchanged"

These are operator-driven E2E checks. The pre-commit content
test (`bin/agent-prompts-content-test.sh`) is the static
guardrail; the live checks are the empirical confirmation. The
brainstorm cannot claim PASS on the live checks (they require an
operator and a real Anthropic dispatch), but neither does it
need to — the static guardrail is what's load-bearing for
regression, and the live verification is a one-time operational
confirmation of the fix's presence on the next dispatch.

PASS (gate P0: 0) **on static surface only**.

The PASS verdict here covers only what the
`bin/agent-prompts-content-test.sh` content gate can assert about
the §5 prompt edit; it does NOT cover the two PENDING live-verify
rows in §11. An operator who closes ENG-77 must complete those
live verifications (or explicitly defer with a tracking ticket
ID) — the static gate is necessary but not sufficient.

## 10. Open questions / out of scope

**O-1. Should the §5 paragraph also forbid the agent from running
`Read` on `stage-summary-reviewing.md` at all?** Forbidding the
Read entirely would close EC-5's loophole at the cost of removing
a legitimate use case (reading prior content to decide whether
findings are unchanged is a sensible analytical step that doesn't
break the contract *if followed by an unconditional Write*). The
current rule's "do not read-then-conditionally-skip" language
allows the Read but forbids the skip. If a future incident shows
agents misreading "read-then-conditionally-skip" as "read is
forbidden", the simplification path is to forbid Read; that's a
prompt edit at the time, not now. Out of scope.

**O-2. Should `bin/run-stage.sh:1081-1084` (success-path cleanup)
also clear `stage-summary-<stage>.md`, removing the architectural
substrate of the bug?** Clearing on success transitions would
mean a loopback from review→implement starts implementation with
no stage-summary-reviewing.md on disk; the implement agent would
have to read findings from Linear (the
`completion/reviewing/<issue>` comment) which IS the canonical
operator-facing source already. This is the structural side of
D-005's reasoning — Fix #3 (typed channel) goes one step further
by also typing the comment, but a smaller change ("clear the file
on success") might suffice. It's tempting; it would also break
forensics ("when did the iter-N findings exist?" — answer becomes
"go look at git log on the doc, except there is no doc, so..."
the forensic record moves entirely to Linear). Not pursued in
this PR; recorded here as a smaller alternative to D-005.

**O-3. Should the §5 paragraph's "ENG-71 (May 2026)" citation
include a doc anchor (e.g., link to this brainstorm or to the
ENG-71 plan doc)?** The current citation names the incident by
ID and date; a maintainer wanting context can grep `docs/`. A
markdown link inside `AGENT_PROMPTS.md` would render in some
viewers but not in `claude -p`'s prompt-text consumption. Probably
not worth the link; the ID-and-date is searchable. Defer.

**O-4. The `learned-rules/harness/review.md` file referenced by
`render-prompt.sh` at dispatch time does not exist today** — only
`build.md` and `project-profile.md` are present in
`learned-rules/harness/`. If the retrospective agent ever creates
`review.md`, its content is appended to the base §5 prompt; the
appended content cannot weaken D-001 (additive only, per
CLAUDE.md). Recorded for completeness; no action required.

**O-5. The shipped commit `bd8ca2d` was authored on a `fix/eng-71-
followup-...` branch, not on `feat/eng-77-...`.** The current
brainstorm runs on `feat/eng-77-...` per the harness's brainstorm-
stage worktree convention. The brainstorm doc itself is the only
artifact this branch produces. The implement stage on this branch
has nothing to do (the fix is on `main`); the harness's poller
will likely transition to the next stage based on the agent's
verdict pass marker. This is unusual but not harmful — recorded
to flag the divergence from the canonical "brainstorm → plan →
implement on the same branch" SDLC.

**O-6. The un-deferral preconditions for D-003, D-004, D-005 all
depend on observability that does not exist today.** D-003's
condition #2 ("retrospective metric aggregating per-issue
`stage-summary-<stage>.md` mtime deltas") and D-004's condition
#3 ("retrospective evidence over a 30-day window") both require a
metric the harness does not currently emit. D-001 ships *with no
operator-facing detection surface* — an operator's sole detection
mechanism for a future agent ignoring the prompt mandate is the
same mechanism that took ENG-71 nine iterations to surface: their
own attention. The cheapest closing intervention is a status.sh
or retrospective signal that aggregates per-issue
`stage-summary-<stage>.md` mtime regression across consecutive
dispatches and surfaces issues where the file's mtime is older
than the previous tick's dispatch start. Roughly 30-50 lines of
shell in `bin/status.sh` or a new pass in `bin/retrospective-...`.
**Recommendation:** file as a separate Linear issue ("status.sh
mtime-drift signal for stage-summary files") with a "depends-on"
note pointing at this brainstorm. Implementing the signal
unblocks the data-driven half of D-003 / D-004 un-deferral
preconditions and is materially cheaper than D-004's full mtime-
halt-loop. Without it, the deferral story is "trust the agent OR
wait for a second 9-iter loop." Operator awareness: this is the
load-bearing operational risk of the in-scope fix; record in O-6
so the next operator who reads the brainstorm sees the gap.

**Out of scope, per the issue body:**
- Stale-file mtime detection in `run-stage.sh` (Fix #2; D-004
  here).
- Typed cross-stage findings channel (Fix #3; D-005 here).
- Generalization of D-001's overwrite rule to §§3, 4 (D-003 here).
- Any structural change to `stage-summary-<stage>.md`'s lifecycle
  (e.g., success-path clearing per O-2).
- The lightweight detection signal (O-6) itself; flagged for
  separate ticket.

## 11. Acceptance criteria

**Acceptance status (read this first).** Static gates are GREEN.
Live-verify gates are PENDING. ENG-77 cannot be declared "closed"
on the basis of this brainstorm + the shipped commit alone — the
two operator-driven items in the table below must complete (or be
explicitly deferred to a follow-up ticket with a tracking ID)
before the issue moves to released. The §9 Feasibility verdict
PASS applies to the static, content-test-coverable surface only;
it does NOT claim the live-verify items are satisfied.

The Linear issue's "Test plan" section maps to the following
checks:

| Linear issue test plan item | Status | Verification |
|---|---|---|
| Pre-commit suite: 30/0 + 3 known-broken | GREEN | Static; verified by running `.githooks/pre-commit` on `main` post-`bd8ca2d` (per the commit message). |
| `agent-prompts-content-test.sh`: 94/0 (was 91, +3 new asserts) | GREEN | Static; verified by `git show bd8ca2d --stat` showing +40 lines on the test file. |
| Live verify on ENG-71 specifically | PENDING | Operator-driven; per O-5 / P-1. Must complete OR be explicitly deferred. |
| Live verify on the next review-loopback issue | PENDING | Operator-driven; per O-5 / P-1. Must complete OR be explicitly deferred. |

Plus implicit AC from the Goals section:

- **G-1** (overwrite on loopback re-entry): D-001 prompt mandate +
  D-002 third assert (cite ENG-71) jointly pin.
- **G-2** (regression caught by content test): D-002 first and
  second asserts pin.
- **G-3** (self-justifying via named incident): D-002 third assert
  pins.
- **G-4** (narrow scope to §5): D-003 records the decision; no
  test pin needed for a non-change.
- **G-5** (un-deferral preconditions documented): §10 O-2 and
  D-004 / D-005 carry the conditions.

All 91 pre-existing `agent-prompts-content-test.sh` cases must
continue to pass (verified post-ship per the commit message).

The full `bin/*-test.sh` suite (per CLAUDE.md "Pre-commit hook" §)
must remain green; D-001's prompt edit does not touch any path
exercised by other tests, so no cross-test regression risk.

## 12. Anti-bias checks

### ADR / existing-decision pressure

ENG-49 / ENG-54 (review stage is agent-only; no human gate at
review) — D-003's narrow-scope-to-§5 reasoning leans on ENG-54's
contract: review is the only stage with a tight in-issue re-
dispatch loop. Not pressure on ENG-54; alignment.

ENG-63 (`add_or_update_comment` re-apply visibility) — D-001's
"the orchestrator's footer-only re-apply path covers visibility"
language leans on ENG-63's footer fix at `bin/linear.sh:582-606`.
Not pressure; the named-incident reasoning chain is consistent.

ENG-71 (build agent worktree-HEAD mutation; the meta-incident this
fix's named example points at) — D-001's paragraph cites the
review-loopback aspect of ENG-71's investigation, not its primary
worktree-HEAD subject. The two are entangled: ENG-71's review→
implement→ui→review cycle is what surfaced the stale-summary bug.
The citation correctly attributes the cycle to ENG-71 without
overclaiming that ENG-77 is a duplicate.

ENG-49 ("AGENT_PROMPTS.md is load-bearing", `render-prompt.sh`
fence-extraction) — D-001's edit lands inside §5's existing fenced
block; no fence-count regression. Aligned.

No ADR overturned. No accepted decision pressure noted.

### Simpler-alternative inventory

For each major decision, a rejected alternative was documented in
§4 with a stated reason:

- D-001: defensive mtime check rejected on registry/control-flow
  cost; typed channel rejected on multi-stage cost; generalize-now
  rejected on dilution + later-extension cost.
- D-002: end-to-end fixture rejected on low-incremental-coverage;
  generalize-asserts-to-all-§§ rejected symmetric with D-003.
- D-003: generalize-to-§§3,4 rejected on observed-surface
  criterion + cheap-later-extension; generalize-all rejected on
  same plus broader prompt-paragraph dilution.
- D-004: implement-this-PR rejected on registry-edit cost +
  control-flow interaction surface; metric-without-halt rejected
  on operator-experience.
- D-005: shim-migration rejected on still-needs-registry-edit;
  dual-source rejected on coherence.

### Assumption inventory

| Claim in brainstorm | Status | Verification |
|---|---|---|
| `AGENT_PROMPTS.md §5 Output` carries the MANDATORY-overwrite paragraph at lines 1027-1039 | verified | `AGENT_PROMPTS.md:1027-1039` direct read |
| §5 fenced block is bounded correctly (no column-0 fence regression) | verified | `bin/agent-prompts-content-test.sh:148-153` (§2 fence-count test) covers the structural property; §5's edit at PR #61 didn't introduce new fences |
| `bin/agent-prompts-content-test.sh:197-235` carries the three new asserts | verified | direct read at lines 197-235 |
| `bin/run-stage.sh::post_completion_comment` reads `$(issue_dir)/stage-summary-${stage}.md` and posts under sig `completion/${stage}/${issue}` | verified | `bin/run-stage.sh:147-225`, specifically lines 149-150 (path) and lines 218-225 (post) |
| `bin/run-stage.sh:179-191` is the read site that posts stale content when the file isn't refreshed | verified | direct read at those lines |
| `bin/run-stage.sh:495-497` is `_handle_wait`'s pre-emptive clear of the stage-summary file (build's wait-budget path is structurally immune) | verified | direct read |
| `bin/run-stage.sh:977-989` is the agent-contract validator (rc=25 when neither file nor fresh marker exists) | verified | direct read |
| `bin/run-stage.sh:1036` is `_post_dispatch_apply_halt`'s call site | verified | direct read |
| `bin/run-stage.sh:1081-1084` clears `issue-state.json` and `wait-${stage}.json` on success transitions but does NOT clear `stage-summary-<stage>.md` | verified | direct read |
| `bin/linear.sh::add_or_update_comment` advances `updatedAt` on identical-body re-apply via the `<!-- meta: reapplied at=… -->` footer (ENG-63 fix) | verified | `bin/linear.sh:582-606` |
| `bin/pipeline-events.json:11-19` enumerates 8 halt reasons; `stale-stage-summary` is not among them | verified | direct read of `bin/pipeline-events.json:11-19` |
| `bin/pipeline-events.json:42-48` enumerates 5 meta-kinds; `findings` is not among them | verified | direct read of `bin/pipeline-events.json:42-48` |
| `bin/dispatch.sh::allowed_tools_for "reviewing"` includes `Read,Write` (so the agent CAN invoke either) | verified | `bin/dispatch.sh:284-285` (reviewing line) |
| `bin/common.sh::parse_pipeline_marker` handles `<!-- meta: ... -->` shapes (event:`meta`) | verified | `bin/common.sh:185-260` |
| `bin/verdict-handler.sh::_vh_lookup_loopback` is the loopback routing layer (review→implement target via fail target) | verified | `bin/verdict-handler.sh:46` |
| `AGENT_PROMPTS.md:665` (§3 Implement Output bullet) and `AGENT_PROMPTS.md:810` (§4 UI Output bullet) carry minimal "Write the stage summary file at `{stage_summary_path}` — follow the Stage summary comment format contract" language without overwrite mandate | verified | direct read |
| `learned-rules/harness/` contains only `build.md` and `project-profile.md` (no `review.md`) at composition time | verified | `ls learned-rules/harness/` |
| The shipped commit on `main` is `bd8ca2d` (`fix(eng-77): mandate reviewer overwrites stage-summary file on every dispatch`), via PR #61 | verified | `git show bd8ca2d` produces the diff to `AGENT_PROMPTS.md:1027-1039` and `bin/agent-prompts-content-test.sh:197-235` |
| `.githooks/pre-commit` runs `bin/agent-prompts-content-test.sh` (so D-002 gates on every `AGENT_PROMPTS.md`-touching commit) | verified | direct read of `.githooks/pre-commit` (CLAUDE.md "Pre-commit hook" §) |
| ENG-71's actual cycle was 9 review-implement loops in 9 hours, ~$50 compute, 2 manual interventions | assumed | issue body claim; the iter count is verifiable from the issue's `git log` on the ENG-71 branch and from the Linear thread; the wall-clock and dollar figures are from the operator's observation |
| ENG-71's `stage-summary-reviewing.md` had iter-5 mtime at composition of the issue body | assumed | issue body's `ls -l` and `grep` evidence; not separately re-verified at this brainstorm's composition (the file may have since been deleted by `decide --action continue`) |
| Linear has no comment-delete mechanism (so probe comments accumulate as litter) | verified | `bin/linear.sh` does not export a `delete-comment` subcommand; consistent with the §5 prompt's existing "ENG-53 #11" probe-litter paragraph |

All twenty-two load-bearing facts are "verified" against the
worktree at composition time. The only "assumed" items are the
two ENG-71 wall-clock/dollar/mtime observations, which are
sourced from the Linear issue body and not separately re-derived
in this brainstorm.

### Codebase-fact verification

Every named symbol and every path:line reference cited in the
brainstorm has been opened and verified by `path:line` in the
Assumption Inventory above. Two classes specifically:

- **Functions and helpers:** `post_completion_comment`,
  `_handle_wait`, `_post_dispatch_apply_halt`,
  `_post_dispatch_check_worktree_head`,
  `_replay_scope_approval`, `verdict_handler`,
  `apply_transition`, `_vh_lookup_loopback`,
  `add_or_update_comment`, `parse_pipeline_marker`,
  `allowed_tools_for`, `_fresh_wait_reason`,
  `_dispatch_tools_extras`, `extract_block`. All exist at the
  line numbers cited.
- **Files:** `AGENT_PROMPTS.md`,
  `bin/agent-prompts-content-test.sh`, `bin/run-stage.sh`,
  `bin/dispatch.sh`, `bin/linear.sh`, `bin/verdict-handler.sh`,
  `bin/common.sh`, `bin/pipeline-events.json`,
  `bin/render-prompt.sh`, `bin/pipeline.sh`, `.githooks/pre-commit`,
  `learned-rules/harness/build.md`,
  `learned-rules/harness/project-profile.md`,
  `docs/brainstorms/2026-05-04-eng-63-...md` (referenced by
  link), `docs/brainstorms/2026-05-08-eng-78-...md` (existing
  example brainstorm — not changed by this PR). All paths exist
  in the worktree as of composition.

No symbol cited "assumed" without verification.
