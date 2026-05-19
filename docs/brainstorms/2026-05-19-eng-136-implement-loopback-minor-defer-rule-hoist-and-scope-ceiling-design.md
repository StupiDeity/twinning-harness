---
linear: ENG-136
title: §3 review-loopback — hoist minor/nit defer rule + add hard scope ceiling
date: 2026-05-19
status: draft
---

# ENG-136 — §3 review-loopback minor/nit defer rule hoist + scope ceiling

## 1. Overview

`AGENT_PROMPTS.md` §3 (Implementation Agent) currently buries the
minor/nit defer rule as the trailing clause of step 1 in the
review-loopback handling block:

> 1. Treat every `[critical]` and `[major]` finding as a contract you MUST
>    close by code commits on `{branch_name}` before exit. `[minor]` and
>    `[nit]` findings are best-effort — close them when cheap, defer with
>    a one-line rationale in the stage-summary Notes otherwise.

Two compounding weaknesses cause the agent to ignore the rule in
practice:

1. **Structural underweighting.** The rule is one half-sentence inside
   step 1 of a 5-step block. The `{review_findings}` interpolation
   point sits immediately below the block and presents an explicit list
   of findings the agent reads top-down. The agent's instinct to
   "close what the reviewer flagged" outweighs a single buried
   defer-rule.
2. **No scope ceiling.** "Close them when cheap" is a fuzzy judgment.
   "Cheap" has no anchor — the agent decides "this is a one-line edit,
   that's cheap" even when the edit touches a file outside the plan's
   File Structure.

Concrete failure (ENG-122 implement-loopback, 2026-05-16): the implement
agent attempted to close review minor #4 (`learned-rules/harness/project-profile.md:17`
— Build & test gates list missing two new test scripts) on an
implement-loopback dispatch. The profile file was not in the plan's
File Structure. `bin/scope-check.sh` halted the dispatch as a self-leak,
burning one implement-cycle on a fix the agent should have deferred.

ENG-136 closes this failure mode with two prompt-only edits to §3:

- **A. Hoist the defer-rule.** Move the minor/nit handling instruction
  OUT of step 1 and into a prominent labeled precondition block
  ("Minor/nit defer rule (MANDATORY — read BEFORE the findings list
  below; ENG-136):") that sits between the existing 5-step block and
  the `Reviewing summary (verbatim):` header. The agent reads the
  rule visually adjacent to the `{review_findings}` token, not
  hidden inside step 1.
- **B. Add a hard scope ceiling.** Define "cheap" mechanically: a
  minor/nit fix is "cheap to close" ONLY if the fix requires ZERO
  edits to files outside the plan's File Structure table. Outside →
  defer. Inside → close.

This makes the judgment binary and locator-based instead of
subjective.

## 2. Decisions

- **D-001. Edit shape: hoist, not rewrite.** Remove the second sentence
  of step 1 (the `[minor]` and `[nit]` clause). Insert a new labeled
  block BETWEEN the existing 5-step block (after step 5's "Concrete
  failure (ENG-123 iter 4-6)" paragraph) and the `Reviewing summary
  (verbatim):` header. The block contains: (a) restated defer-rule,
  (b) scope ceiling with example file paths, (c) Notes-format
  specification with two worked examples, (d) ENG-122 concrete-failure
  paragraph anchoring why the ceiling exists.

  This is the lowest-risk diff shape: the 5-step block's other
  semantics (commit-message trailer, NOOP-loopback prevention, dedup
  warning, scope-drift restraint) are unchanged; only the
  half-sentence about minor/nit handling moves. The rest of §3 is
  untouched.

- **D-002. Block label spells the freshness contract.** Header text:
  `Minor/nit defer rule (MANDATORY — read BEFORE the findings list below; ENG-136):`.
  Three load-bearing tokens:
    1. `MANDATORY` — matches the existing severity vocabulary of §3
       (the review-loopback header itself reads `(MANDATORY when
       present — ENG-105 follow-up)`).
    2. `read BEFORE the findings list below` — explicit
       reading-order instruction. The agent processes prompt top-down;
       this header tells it to internalize the rule before it ingests
       the `{review_findings}` payload.
    3. `ENG-136` — backreference; identical to how §3 names
       ENG-105/ENG-122/ENG-139/ENG-140 elsewhere.

- **D-003. Scope ceiling text — binary, locator-based.** The
  ceiling defines "cheap" as a mechanical predicate over the plan's
  File Structure table:

  > A `[minor]` or `[nit]` finding is "cheap to close" ONLY if the fix
  > requires ZERO edits to files outside the plan's File Structure
  > table (see §3 read-list item 9 — `docs/plans/{plan_file}`). If a
  > fix would require touching ANY file not listed in File Structure
  > — including but not limited to `learned-rules/<slug>/project-profile.md`,
  > sibling test files (`bin/*-test.sh`), knowledge docs
  > (`docs/knowledge/*`), config files
  > (`.pipeline-config/config.json`, `.githooks/*`), or workflow
  > definitions — DEFER the finding.

  The example list anchors the rule against the ENG-122 failure mode
  (`project-profile.md` is named first) AND enumerates four other
  classes the agent has historically been tempted to "just edit
  cheaply" (sibling tests, knowledge docs, config, workflows).

- **D-004. Defer-bookkeeping shape — single-line Notes entry.**
  Mandate one line per deferred finding, appended to the **Notes**
  subsection of `stage-summary-implementing.md`:

      Deferred [<severity>] <finding-id>: <file-path-the-fix-would-touch> — <one-line rationale>

  Two worked examples both anchored on plausible scenarios:

      Deferred [minor] M4: learned-rules/harness/project-profile.md — outside plan File Structure; closure via next plan iteration (pipeline:extend).
      Deferred [nit] N2: bin/dispatch-test.sh — sibling test file outside plan File Structure; defer to follow-up ticket.

  Why one-line: the existing review-loopback rule already said
  "defer with a one-line rationale in the stage-summary Notes
  otherwise" (the half-sentence we're hoisting). D-004 preserves
  that quantity contract — no scope creep into "structured defer
  manifest with severity counts" or similar. The reviewer reading
  the prior stage-summary on the next iter can grep the literal
  `Deferred [` prefix.

- **D-005. Anti-pattern guardrail.** Append three negative directives
  to the block:

  > Do not attempt the edit; do not extend File Structure on the fly;
  > do not file a meta-marker as a substitute for the real edit.

  Rationale:
    - "Do not attempt the edit" — closes the ENG-122 path (try the
      out-of-File-Structure edit, get halted by scope-check).
    - "Do not extend File Structure on the fly" — closes a plausible
      bypass (agent edits the plan markdown to add the file, then
      edits the file, claiming it's now in scope). The plan is
      authored by §2; §3 has no authorization to expand it.
    - "Do not file a meta-marker as a substitute for the real edit"
      — closes a degenerate compliance path (agent posts a
      `<!-- meta: metric name=plan_gap -->` comment AND ALSO edits
      the file). The `plan_gap` marker is for the scope-drift
      restraint (step 5); deferring a minor finding doesn't need
      one because the finding itself is already captured in
      `{review_findings}`. Adding the marker doesn't make the edit
      legal.

- **D-006. Closure path — point to plan iteration.** End the block
  with:

  > The next plan iteration (or a `pipeline:extend` operator decision)
  > is the correct closure path for deferred minor/nit findings. The
  > agent MUST NOT use a review finding to authorize editing a file
  > the plan did not list.

  Two purposes: (a) tells the agent what TO do (defer for next plan)
  not just what NOT to do; (b) names `pipeline:extend` as the
  operator escape hatch — the label exists today (per
  `docs/runbooks/recovery.md`) and is the canonical way to expand
  scope mid-flight.

- **D-007. Step 1 — minimal edit, preserve forward reference.**
  Today step 1 reads:

  > 1. Treat every `[critical]` and `[major]` finding as a contract
  >    you MUST close by code commits on `{branch_name}` before exit.
  >    `[minor]` and `[nit]` findings are best-effort — close them
  >    when cheap, defer with a one-line rationale in the
  >    stage-summary Notes otherwise.

  After ENG-136, step 1 reads:

  > 1. Treat every `[critical]` and `[major]` finding as a contract
  >    you MUST close by code commits on `{branch_name}` before exit.
  >    (For `[minor]` and `[nit]` findings, see the **Minor/nit defer
  >    rule** block below.)

  The forward reference (in parentheses) keeps step 1 self-contained
  for the agent reading the 5-step block — they know minor/nit is
  handled, and the explicit pointer makes the new block findable.

- **D-008. Test surface — content pins + step-1 regression check.**
  Add to `bin/agent-prompts-content-test.sh`:
    1. **Hoisted-header pin.** Assert §3 contains the literal phrase
       `Minor/nit defer rule (MANDATORY — read BEFORE the findings list below; ENG-136):`.
    2. **Position pin.** Assert the hoisted header appears AFTER the
       review-loopback 5-step block (i.e., after step 5's "Concrete
       failure (ENG-123 iter 4-6)" sentence) AND BEFORE the
       `Reviewing summary (verbatim):` header. Implementation: compare
       line numbers via `grep -n` on `$PROMPTS`. Using line numbers
       on the FULL file (not §3-only) is fine because the literal
       headers are unique to §3.
    3. **Scope-ceiling phrase pin.** Assert the literal phrase
       `ZERO edits to files outside the plan's File Structure` is
       present in §3. This is the binary-judgment language that makes
       D-003 mechanical.
    4. **Example-file-path pin.** Assert the literal path
       `learned-rules/<slug>/project-profile.md` is present in §3.
       Anchors the rule against the ENG-122 failure mode named in
       the ticket's AC #3.
    5. **Notes-format pin.** Assert the literal format prefix
       `Deferred [<severity>] <finding-id>:` is present in §3.
    6. **Step-1 regression pin.** Assert that step 1 of the §3
       review-loopback block no longer contains the phrase
       `best-effort — close them when cheap`. This is the
       negative-case guard that catches a future editor who restores
       the buried rule but forgets to remove the hoisted block, OR
       who hoists but leaves the original sentence in place
       (resulting in two competing instructions).
    7. **Forward-reference pin.** Assert step 1 contains the literal
       phrase `see the **Minor/nit defer rule** block below`. This
       catches a future editor who removes the forward pointer
       (regressing discoverability).

  Position assertion (item 2) is the structural correctness gate:
  if a future editor moves the block back ABOVE the 5-step block
  or BELOW `{review_findings}`, the test fails and the regression
  is caught at pre-commit.

- **D-009. No scope-check / linear.sh / dispatch.sh edits.** ENG-136
  is a pure prompt edit. The defense-in-depth (`scope-check.sh`
  halt on self-leak) stays as-is and is correct policy — the
  prompt change makes the agent NOT trip scope-check by deferring
  the finding, but the scope-check itself remains the load-bearing
  enforcement layer.

- **D-010. Iter-1 ship as a brainstorm-only ticket; class-bug
  observation noted.** ENG-136's halt at brainstorming on
  2026-05-16 was caused by the class-wide `_ensure_progress_md`
  set -u bug (1f4b483, fixed 2026-05-17). The 2026-05-17 retro
  caught it and the same fix unblocked 15 brainstorm-stage
  issues. ENG-136 itself is now dispatchable. The pre-existing
  worktree had no commits — the bug crashed every brainstorm in
  ~7s. The manual shepherd resets the branch to current
  `origin/main` and rebuilds from the brainstorm.

## 3. Scope Boundaries

**IN:**
- `AGENT_PROMPTS.md` §3 — restructure review-loopback block per
  D-001/D-002/D-003/D-004/D-005/D-006/D-007.
- `bin/agent-prompts-content-test.sh` — add seven assertions per D-008.
- `docs/brainstorms/2026-05-19-eng-136-…-design.md` (this file).
- `docs/plans/2026-05-19-eng-136-….md` and `.json` (sibling plan
  artifacts).

**OUT:**
- §3 build-loopback / qa-loopback handling (untouched).
- §3 scope-drift restraint (step 5; untouched).
- `bin/scope-check.sh` enforcement (defense-in-depth stays as-is).
- §2 plan agent, §5 review agent, §6 QA agent (separate tickets if
  needed).
- `learned-rules/*` (rules are written by the retrospective; not a
  manual edit surface).
- Any `bin/render-prompt.sh` token-resolver work — ENG-136 does NOT
  introduce a new token; `{review_findings}` is already the surface.

## 4. Open Questions

- **OQ-1. Should the block include a "do close it" example?** Today
  the block enumerates what to defer. A symmetric "examples of cheap
  closures" subsection (e.g. "renaming a local variable in a file
  already in File Structure → close it") would complete the rubric.
  Resolution: NOT in iter-1. The risk is over-specification — listing
  positive examples invites the agent to enumerate-compare instead of
  applying the binary rule. The negative examples + binary rule are
  sufficient for closure of the ENG-122 failure mode. Revisit if
  observed-good on next 5 review-loopback dispatches.

- **OQ-2. Should `pipeline:extend` be more than a name-drop in the
  block?** D-006 names `pipeline:extend` as the closure path. The
  block could include the operator-side command
  (`bash bin/pipeline.sh decide ENG-N --action continue --gate scope`?)
  to make it actionable. Resolution: NOT in iter-1.
  `pipeline:extend` is the operator's surface; the agent prompt
  should name it but not script the operator's workflow.

## 5. Acceptance Criteria mapping

Mapping the ticket's six ACs onto deliverables:

| AC | Deliverable | D-ref |
|---|---|---|
| 1. §3 review-loopback block restructured so defer-rule appears in prominent precondition before `{review_findings}`. | New "Minor/nit defer rule (MANDATORY …)" block inserted between 5-step block and `Reviewing summary (verbatim):` header. | D-001, D-002 |
| 2. Defer-rule includes explicit scope ceiling: minor/nit fixes touching files outside File Structure must be deferred. | Scope-ceiling paragraph + example file paths. | D-003 |
| 3. Example file paths include `learned-rules/<slug>/project-profile.md`. | Path is FIRST in the example list, anchoring against ENG-122. | D-003 |
| 4. Stage-summary Notes format specified. | `Deferred [<severity>] <finding-id>: <file-path> — <rationale>` + two worked examples. | D-004 |
| 5. Sibling test asserts hoisted position AND scope-ceiling language. | Seven assertions in `bin/agent-prompts-content-test.sh`. | D-008 |
| 6. Hand-trace of ENG-122 dispatch context with this change would unambiguously direct: "minor #4 requires editing project-profile.md → outside File Structure → DEFER." | Block text + ENG-122 concrete-failure paragraph at end of block; trace: agent reads block → reads `{review_findings}` showing minor #4 → maps `learned-rules/harness/project-profile.md` against File Structure → file is absent → DEFER. | D-001 through D-006 |

## 6. Risk

- **R-1. Future editor undoes the hoist.** A maintainer cleaning up
  §3 could merge the hoisted block back into step 1 "to reduce
  duplication" without realizing the structural placement is
  load-bearing. Mitigation: D-008 position assertion + step-1
  regression pin. The pre-commit hook runs
  `bin/agent-prompts-content-test.sh` and blocks the merge.
- **R-2. False-positive scope ceiling.** The binary "outside File
  Structure → defer" rule could defer a legitimately cheap fix
  (e.g., a typo in a sibling test that's actually IN the plan's
  test target list). Mitigation: D-003's wording says "files
  outside the plan's File Structure table" — if a sibling test
  IS listed in File Structure, it's in scope. The plan stage
  controls this surface.
- **R-3. Block bloat.** The new block adds ~25 lines of prose to
  §3. Mitigation: §3 already runs 250+ lines; the new block is
  proportionate to its load-bearing role.

## 7. Personas review (P0 sweep)

- **Correctness** — pass. The hoist is structural, not semantic;
  the binary scope ceiling is mechanical; D-008 tests pin both
  position and content.
- **Maintainability** — pass. Single new labeled block;
  forward-reference from step 1 keeps the 5-step list readable;
  seven content pins make future drift detectable.
- **Performance / Cost** — pass. Prompt-only edit; no new tokens
  consumed at render time; ~25-line block adds ~150 tokens to every
  implementing dispatch's prompt (the prompt is already ~30 KB —
  +0.5%).
- **Reliability** — pass. Defense-in-depth via `scope-check.sh`
  stays. New block is additive — the worst case (agent ignores
  the hoist) is no worse than today.
- **Testability** — pass. D-008 lists seven concrete grep-anchored
  assertions; position assertion uses line-number comparison on
  the full file (literal headers are unique to §3).
- **Security** — pass. No new tools, no new tokens, no new I/O.
  Block is text-only.
- **No P0 unresolved.**
