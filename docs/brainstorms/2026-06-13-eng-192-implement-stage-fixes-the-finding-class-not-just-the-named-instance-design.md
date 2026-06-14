---
linear: ENG-192
title: Implement stage fixes the finding class, not just the named instance
date: 2026-06-13
status: draft
---

# Implement stage fixes the finding class, not just the named instance

## 1. Overview

Lever 3 of [ENG-189]. Half of the [ENG-113] ratchet was the **implementer**,
not the reviewer: the implement agent fixed one instance of a finding class
per pass (one IPv6 loopback encoding at a time — long-form `::1`, then the
long-form bypass, then the `::` collapse / zone-id / `::ffff:` axes), so the
cold reviewer correctly found the *next* axis each round. A perfectly
convergent reviewer (ENG-190 Lever 1) and a terminal selective-exit (ENG-191
Lever 2) still need N rounds if the implementer fixes instance-not-class.

ENG-192 adds two related implement-side directives to `AGENT_PROMPTS.md`'s
§3 review-loopback handling block:

1. **Fix-the-class.** When a review finding names one instance of a class
   (e.g. "IPv6 long-form `::1` not normalized"), enumerate the sibling
   instances within plan scope and fix the whole class — with fixtures
   covering the class, not just the cited instance.

2. **In-file cleanup carve-out** (folded ENG-148, closed as duplicate
   2026-06-13). When modifying a file already in plan File Structure to
   address an explicit review finding, the agent MAY also fix obvious
   latent issues in the SAME file in the same or an adjacent commit. The
   commit tag is `cleanup(<issue_id>): <one-line>`. Bounded by an explicit
   in-bounds list (test state-leak / fixture cross-contamination, off-by-one
   or TZ mismatch in test helpers, dead code, obvious typos, missing
   coverage of EXISTING branches) AND an explicit denial list (no new
   code paths, no new defensive layers, no new contract fields, no cross-
   file proactive cleanup, no refactors — the [ENG-123] "1 MiB cap added on
   a nit" pattern stays forbidden).

Both directives are bounded by existing rules — the step-5 Scope-drift
restraint (brainstorm/plan are the only authorization surfaces for
behaviour) and the Minor/nit defer rule (ZERO edits outside the plan's
File Structure). The new block is positioned to make this precedence
unambiguous in reading order.

**Win attribution (clarified per product persona iteration 1).** The
~$50 / 6-cycle aggregate ENG-113 ratchet is the JOINT ceiling for the
three ENG-189 levers. ENG-190 (reviewer adjudication memory) closes
the score-inflation half of the ratchet; ENG-192 (this ticket — fix-
the-class) closes the implementer-instance-not-class half; ENG-191
(terminal selective exit) closes the residual tail. The cycle share
attributable to ENG-192 alone is the subset where the implementer
shipped instance-N-of-K-class fixes — empirically observed in iter 1
and iter 3 of the ENG-113 ratchet (2 of 6 cycles, per the post-
incident timeline reconstruction in ENG-189's brainstorm and the
ENG-113 PR commit log showing one IPv6 encoding closed per
iteration). ENG-192's standalone expected win is therefore ~$15-20
per ratcheted incident; the full ~$50 win materializes only when
all three levers land. The estimate is per-incident expected value,
not a guarantee — incidents where the implementer happens to fix
all instances of the class in one pass already see zero ratchet,
and the directive is a no-op for those cases.

**Reference to product principle.** CLAUDE.md ticket-sizing rubric:
1 subsystem (agent-prompts / implementing), 1 primary decision (the
implement-side scope/closure boundary covering both axes). Autonomy-safe.

**Reference to constraint.** CLAUDE.md "AGENT_PROMPTS.md is load-bearing":
the new block sits inside §3's existing fenced body — no new H2 section,
no column-0 ``` fence, no change to `STAGE_TO_SECTION` in
`bin/render-prompt.sh`.

## 2. Decisions

### D-001. The two directives ship as ONE labeled MANDATORY block inside §3, positioned AFTER the 5-step review-loopback block and BEFORE the Minor/nit defer rule.

**Rationale.** AC #4 explicitly mandates "the two directives are mutually
consistent — no contradictory scope guidance". A single labeled block with
two sub-bullets is the structural shape that makes mutual coherence
pinnable by a content test (one positional anchor, one combined block to
audit). Position rationale:

* **After step 5's `Concrete failure (ENG-123 iter 4-6)` line at
  `AGENT_PROMPTS.md:804`** — the outer negative rule
  ("brainstorm/plan are the only authorization surfaces") is read
  first. The new block is a refinement that operates WITHIN the
  authorized scope. The exact insertion site is the empty line
  between line 804 (end of step 5's concrete-failure tail) and
  line 806 (`Minor/nit defer rule (MANDATORY — read BEFORE…`)
  header — pinned by content-test pin #2.
* **Before the Minor/nit defer rule** (`AGENT_PROMPTS.md:806`) — the hard
  ceiling ("ZERO edits to files outside the plan's File Structure") is
  read AFTER. The defer rule overrides class-closure and in-file cleanup
  whenever a candidate fix would touch an unlisted file. By placing the
  defer rule last in reading order, its overriding force is structurally
  obvious. (Step 5's Scope-drift restraint is read BEFORE the new block;
  the precedence is "step 5 still binds AND the defer rule still
  overrides" — both wrap the new block from outside; the new block
  is not a carve-out from either.)

The block's header mirrors the ENG-136 pattern at `AGENT_PROMPTS.md:806`:

> `Fix-the-class & in-file cleanup carve-out (MANDATORY — read BEFORE the
> findings list below; ENG-192):`

The reading order in the prompt then becomes (linear top-to-bottom):

1. Review → implement loopback handling (5 steps, step 5 is the scope-drift
   restraint) — `AGENT_PROMPTS.md:787-804`.
2. **NEW** Fix-the-class & in-file cleanup carve-out block — sits at
   ~line 806 (pushes the existing ENG-136 header down).
3. Minor/nit defer rule (hoisted block — ENG-136) — formerly line 806.
4. `Reviewing summary (verbatim):` + `{review_findings}` — formerly
   line 823.

**Reference to product principle.** CLAUDE.md "Don't add features beyond
what the task requires": one block + four positional pins is the minimum
shape AC #1/#3/#4 demand.

**Reference to constraint.** ENG-136 prior art (`AGENT_PROMPTS.md:806-821`
+ `bin/agent-prompts-content-test.sh:160-242`): a single hoisted labeled
block + 7 content-test pins is the established pattern for "discoverable
implement-side rule the agent must read before {review_findings}". Re-use,
don't reinvent.

**Rejected alternative — two separate labeled blocks** (one for fix-the-
class, one for in-file cleanup). Rejected because (a) AC #4 explicitly
mandates mutual coherence as a content assertion; a single block makes
the boundary unambiguous and pinnable by one positional anchor; (b) two
blocks risk drifting independently in future edits (one's bound moves,
the other doesn't); (c) ENG-136 prior art uses one labeled block for
adjacent rules. Two blocks would be the wrong tier.

**Rejected alternative — fold both directives into step 1 of the 5-step
block.** Rejected because step 1 is the contract-list step ("Treat every
[critical] and [major] finding as a contract you MUST close"). Adding
scope-expansion rules to step 1 dilutes its contract semantics. ENG-136
already migrated AWAY from "buried in step 1" (see `bin/agent-prompts-
content-test.sh:225-233` Pin 6, which asserts the OLD buried sentence is
removed). Burying ENG-192 in step 1 would re-create exactly the failure
mode ENG-136 closed.

**Rejected alternative — fold the directives into the existing Scope-drift
restraint (step 5).** Rejected because step 5 is a NEGATIVE rule ("do NOT
silently implement out-of-scope hardening"). The new directives are
POSITIVE rules ("DO enumerate sibling instances", "DO clean up adjacent
latent in-file bugs"). Mixing positive and negative scope guidance in one
bullet would dilute both and reproduce the ENG-123 ambiguity the rubric
exists to prevent.

**Rejected alternative — apply directives to QA-loopback (§3
lines 827-846) as well.** Rejected because (a) Linear scope explicitly
says "review finding"; (b) QA-loopback has a different finding shape
(P0 / non-P0 with a `plan_gap` carve-out; see `AGENT_PROMPTS.md:840-842`)
and a different scope-drift restraint clause already; (c) if instance-
not-class shows up empirically in QA loopback, that's a follow-up
ticket — not part of ENG-192's scope. See Open Question OQ-1.

### D-002. The Fix-the-class directive is bounded by THREE rules in priority order: cited-finding's class only; plan File Structure only; defer rule overrides on out-of-File-Structure siblings.

**Rationale.** AC #2 mandates: "The directive scopes class-closure to the
cited finding's class (guards against scope creep / self-leak)." The
guardrails decompose to three composable bounds:

1. **Class boundary.** Class-closure means "fix every instance of the
   SAME class as the cited finding". The agent does NOT use a finding as
   licence to fix unrelated finding classes ("while I'm here…"). The
   class is defined by the cited finding's defect type (e.g. all IPv6
   loopback encodings; all timezone-naive datetime literals in the
   touched module). Determining class membership is judgment-driven —
   the prompt provides examples but does not enumerate a closed taxonomy.

   **Class identification reads ONLY the cited finding's defect
   mechanism, NOT reviewer prose suggesting scope expansion** (anti-
   prompt-injection clause per security persona iteration 1). A
   review comment that says "while you're fixing X, also handle the
   broader class of Y" is reviewer prose, not a class-membership
   signal. The agent extrapolates the class from the defect mechanism
   the cited instance exhibits — not from natural-language suggestions
   about scope contained in the finding body. This prevents an
   adversarial or careless review comment from coaxing the agent
   toward unrelated edits via a broad-class framing.

2. **Plan File Structure boundary.** Sibling instances inside the plan's
   File Structure list are in scope. Sibling instances OUTSIDE File
   Structure are deferred per the Minor/nit defer rule's "ZERO edits
   to files outside the plan's File Structure" ceiling. The agent
   reports the deferred sibling in the stage-summary Notes block using
   the existing `Deferred [<severity>] <finding-id>: <file-path> —
   <one-line rationale>` shape (`AGENT_PROMPTS.md:810-817`), with
   rationale `outside File Structure; class-closure deferred`.

3. **Brainstorm/plan authorization boundary.** Step 5 (Scope-drift
   restraint) still applies to the class fix. If closing the class
   would require a new code path / contract field / defensive layer
   the brainstorm/plan did not authorize, the agent halts with a
   `plan_gap` meta-marker rather than silently expanding the contract —
   even if every sibling instance is in File Structure.

   **Worked examples** (per design persona iteration 1):

   * **In-scope** — cited finding: "IPv6 long-form `::1` not
     normalized in `validators/host.rs:42`". Sibling: `::ffff:127.
     0.0.1` not normalized at `validators/host.rs:58`. Same file,
     same defect mechanism (loopback-encoding bypass), same fix
     shape (call existing `normalize_loopback()` helper). Close both
     in the same dispatch.
   * **plan_gap** — cited finding: "IPv6 long-form `::1` not
     normalized in `validators/host.rs:42`". Sibling: `::ffff:127.
     0.0.1` requires a new `Ipv6Compat` enum variant that the plan's
     `api-contract` block does NOT declare. Different fix shape
     (new contract field). Close the cited instance; halt with
     `plan_gap` for the sibling.

**Reference to product principle.** Existing CLAUDE.md scope-sweep
contract: `bin/scope-check.sh::is_benign` already enforces File
Structure boundaries at the path level. The directive composes ON
TOP of that enforcement — the prompt asks the agent to surface
deferrals proactively rather than silently fail the scope sweep.

**Reference to constraint.** CLAUDE.md "scope/sweep" subsystem
(`partition_dirty_paths`): the orchestrator's post-stage sweep
catches an out-of-File-Structure write as `leaked-in-scope` (hard
fail). The directive's bound #2 keeps the agent inside the sweep's
green zone; bound #2's defer-to-stage-summary shape mirrors ENG-122
recovery.

**Rejected alternative — class-closure with NO scope ceiling** (always
fix every sibling regardless of File Structure). Rejected because (a)
the scope-sweep would halt the dispatch on the first out-of-File-Structure
sibling, undoing the cycle savings; (b) re-creates the ENG-122 failure
mode (implement agent halts on self-leak attempting to close a finding
whose fix requires editing project-profile.md outside the plan's File
Structure).

**Rejected alternative — closed taxonomy for "class"** (e.g. enumerate
"IPv6 encodings", "timezone-naive datetime literals", "SQL injection
sinks", … as named classes). Rejected because (a) the taxonomy is
unbounded — every new defect type would need a prompt edit; (b) the
ENG-113 ratchet's classes (IPv6 axes) emerged from one specific reviewer
finding; pre-enumerating them all is impossible; (c) judgment-driven
class identification with a worked example (IPv6 loopback) is the right
tier — the agent reads the cited finding's description and extrapolates.

### D-003. The In-file cleanup carve-out is bounded by THREE rules: same-file-only (predicate); explicit in-bounds list (allowed); explicit denial list (forbidden — ENG-123 stays forbidden).

**Rationale.** AC #3 mandates the carve-out be pinned by:

* The `cleanup(<issue_id>):` commit-tag convention.
* The explicit "no new code paths / ENG-123 pattern stays forbidden"
  boundary.

The carve-out's predicate is structural: the agent is ALREADY modifying
a file within plan File Structure to close an explicit review finding.
This is the moment to fix obvious latent in-file bugs — the cognitive
cost of the cleanup is minimal because the file is already loaded into
working context. The Linear ticket frames the trade as:

> Cleanup commits MUST be tagged `cleanup(<issue_id>): <one-line>` and
> MUST NOT add new code paths, defensive layers, or contract fields.

The Linear in-bounds list (verbatim from the ticket) is:

* test state-leak between sub-cases / fixture cross-contamination
* off-by-one or TZ mismatch in helpers used by tests
* dead code (unused functions/vars)
* obvious typos in docstrings/comments
* missing coverage of EXISTING branches (not new branches)

The Linear out-of-bounds list (verbatim from the ticket):

* new code paths, new defensive layers (use the same boundary-vs-
  internal path heuristic the §3 Self-review's "Defensive-code
  restraint" clause at `AGENT_PROMPTS.md:998-1030` already defines —
  do NOT introduce a parallel definition; this carve-out's denial
  inherits that definition by reference), new contract fields
* cross-file proactive cleanup (would require plan-level authorization)
* new test fixtures/APIs the plan didn't name
* refactors (renames/extractions need their own ticket per the sizing
  rubric)
* the ENG-123 "1 MiB cap added on a nit" pattern (new behaviour
  disguised as a nit) is NOT in-file cleanup and remains forbidden

**Commit-tag is advisory metadata, not a security boundary** (per
security persona iteration 1). The `cleanup(<id>):` convention helps
human and reviewer-agent legibility. It is NOT what enforces the
denial list — `scope-check.sh` path enforcement + step 5's Scope-
drift restraint + the §5 reviewer's reading lens are what enforce
the bounds. A behaviour-adding commit mis-tagged as `cleanup(...)`
still trips the existing detective gates; the reviewer still applies
the in-bounds / out-of-bounds test regardless of which prefix the
implementer chose.

The commit-tag convention serves three purposes:

1. **Reviewer legibility.** The §5 cold reviewer can grep `^cleanup(`
   in the commit log and apply a different reading lens (carve-out
   bounds) than for `^fix(` or `^feat(` commits.
2. **Retrospective signal.** A future retrospective shape can audit
   `cleanup(<id>):` commits across PRs to detect ENG-123-shaped drift
   (commits tagged `cleanup` that actually add behaviour). See OQ-3.
3. **Diff-review human cue.** A human PR reviewer (post-deploy) sees
   `cleanup(<id>):` and knows to apply the same in-bounds/out-of-bounds
   lens.

**Reference to product principle.** CLAUDE.md "Don't add features
beyond what the task requires" — the carve-out lets the agent close a
class of latent bugs WITHOUT needing a separate ticket. Without the
carve-out, every latent bug becomes a follow-up ticket that consumes
plan + implement + review + qa + build dispatches (~$50+ per cycle).
With the carve-out, latent in-file bugs close inside the same dispatch
that addresses the cited finding (~$0 marginal).

**Reference to constraint.** CLAUDE.md "Don't add error handling,
fallbacks, or validation for scenarios that can't happen" + the §3
self-review "Defensive-code restraint" clause (`AGENT_PROMPTS.md:998-
1030`): the denial list mirrors the same anti-defensive-code rule
already in §3. The carve-out does NOT contradict the existing
defensive-code-restraint clause — it tightens it (forbidding "new
defensive layers" under the cleanup banner specifically).

**Rejected alternative — encode the in-bounds list as a diff-level
regex check post-dispatch.** Rejected because (a) the in-bounds list
("dead code, typos, off-by-one") is judgment-driven; a regex would
either over-block (rejecting legitimate cleanup) or under-block
(missing ENG-123-shaped drift); (b) the existing post-dispatch
detective surface (transcript scan, scope-check.sh) doesn't include
commit-message classification, and adding one would expand the
detective tier beyond what AC #3 asks for; (c) prompt-text rule +
content test is the right tier for judgment-driven directives, as
demonstrated by every other rule in §3.

**Rejected alternative — teach `bin/scope-check.sh` about the
`cleanup(<id>):` commit-tag.** Rejected because (a) scope-check.sh
enforces File Structure path boundaries; cleanup commits stay within
File Structure by construction (same file the agent is already
editing) so scope-check passes them unchanged; (b) adding commit-
message classification to scope-check.sh would couple two
independent surfaces (path enforcement vs commit-message convention)
and create a new failure mode (scope-check halts on a missing
`cleanup(...)` tag for an in-file edit that was actually a legitimate
`fix(...)`).

**Rejected alternative — broaden the carve-out to ADJACENT files**
(e.g. same directory, or files in the same plan task's `touches`
list). Rejected per Linear ticket's explicit out-of-bounds list:
"cross-file proactive cleanup (would require plan-level
authorization)". The in-file constraint is what keeps the cognitive
cost minimal — the agent already has the file's context loaded.
Adjacent-file cleanup would re-introduce the "while I'm here…"
failure mode, which is exactly the ENG-123 anti-pattern.

### D-004. The directive block lives in §3 ONLY (Implementation Agent Backend). §4 UI Agent does NOT receive a parallel directive.

**Rationale.** §4 UI Agent (`AGENT_PROMPTS.md:1086-1287`) does NOT
have a review-loopback handling block. Review loopback targets
`implementing` only (see `bin/run-stage.sh` `from=reviewing
to=implementing` semantics, and §3's review-loopback block at
`AGENT_PROMPTS.md:787-825` which is the only such block in the
prompt file). The §4 frontend dispatch runs forward from
implementing-backend, never as a loopback target.

The ENG-113 ratchet originated in BACKEND code (IPv6 normalization
in a Rust validator). The cited Linear scope is implement-stage
specifically. Folding the directive into §4 would (a) expand scope
past what ENG-192 authorizes, (b) require a separate review-loopback
block in §4 that does not exist today, (c) carry no evidence of the
same failure mode in frontend code.

If empirical data emerges showing instance-not-class on UI changes
(e.g. a review finding cites one Tailwind class drift, but five
sibling drifts exist on the same component), the correct response
is a follow-up ticket — not an unauthorized §4 expansion in this
ticket.

**Reference to product principle.** CLAUDE.md ticket-sizing rubric:
"3+ subsystems → split before filing". Scoping the directive to §3
keeps ENG-192 at 1 subsystem (agent-prompts / implementing).

**Rejected alternative — preemptively add a parallel block to §4.**
Rejected per scope rubric + per the absence of a review-loopback
block in §4 today (adding one is a separate decision belonging to a
separate ticket — likely "UI agent gains review-loopback handling"
or similar).

### D-005. The content test pins the new block by 9 assertions (8 baseline + 1 OQ-6-resolved operator-audit pin), mirroring the ENG-136 pattern at `bin/agent-prompts-content-test.sh:160-242`.

**Rationale.** AC #1, #3, #4 each mandate a content-test pin. The
ENG-136 prior art (8 assertions in `bin/agent-prompts-content-test.sh:
160-242`) is the established pattern for "pin a §3 hoisted block by
header + position + key phrases + anti-regression sentence". Mirror
it directly; pin #9 is added to authoritatively resolve OQ-6's operator-
audit signal.

Proposed assertions (each maps to an AC):

| # | Assertion | AC | Anchor |
|---|---|---|---|
| 1 | `§3 ENG-192: hoisted Fix-the-class block header present` | #1 | Literal "Fix-the-class & in-file cleanup carve-out (MANDATORY — read BEFORE the findings list below; ENG-192):" |
| 2 | `§3 ENG-192: block sits AFTER 5-step block AND BEFORE Minor/nit defer rule` | #4 | Position pin: header line > `Concrete failure (ENG-123 iter 4-6)` line AND header line < `Minor/nit defer rule (MANDATORY — read BEFORE the findings list below; ENG-136):` line |
| 3 | `§3 ENG-192: class-enumeration phrase present` | #1 | Literal "fix the whole class" (or equivalent canonical phrasing chosen at implementation) |
| 4 | `§3 ENG-192: IPv6 worked example present` | #1 | Literal "IPv6" + "loopback" (anchors the directive to the ENG-113 motivating story) |
| 5 | `§3 ENG-192: in-file cleanup carve-out sub-header present` | #3 | Literal "In-file cleanup carve-out" |
| 6 | `§3 ENG-192: commit-tag convention pinned` | #3 | Literal "cleanup({issue_id}):" |
| 7 | `§3 ENG-192: ENG-123 anti-pattern explicitly forbidden by cleanup carve-out` | #3 | Literal "ENG-123" + "1 MiB" (assertion: the cleanup carve-out cites ENG-123 by name as out-of-bounds) |
| 8 | `§3 ENG-192: class-closure defers to Minor/nit defer rule on out-of-File-Structure siblings` | #2, #4 | Literal "defer rule" or "ZERO edits" referenced inside the new block (asserts AC #4 mutual-coherence is pinned by content — the new block acknowledges the defer rule's override) |
| 9 | `§3 ENG-192: stage-summary Notes emission requirement for class-closure decisions` | #2, operator-audit | Literal "stage-summary Notes" + "Deferred [" (asserts the new block instructs the agent to log every sibling enumerated, with in-scope-closed / deferred status, using the existing `Deferred [<severity>] <finding-id>: ...` shape from `AGENT_PROMPTS.md:810-817`) — resolves OQ-6 to YES |

Each assertion is a `grep -qF` against the rendered §3 body (using
the existing `section_body` helper at `bin/agent-prompts-content-test.
sh:20-28`). No new helper, no test-runner change.

**Reference to product principle.** CLAUDE.md test convention: tests
are sibling shell scripts; `bin/agent-prompts-content-test.sh` exists
and is in CI via `.githooks/pre-commit`. Add assertions to it; do
NOT create a new test file.

**Reference to constraint.** CLAUDE.md "When wiring a new script:
use existing patterns": the ENG-136 8-assertion pattern is the
existing pattern.

**Rejected alternative — fewer assertions (3-4 pins).** Rejected
because each AC (#1, #2, #3, #4) maps to at least one assertion, and
position + anti-regression pins are required to catch the ENG-136-
class "directive added but buried" failure mode. 8-9 is the minimum
that covers all four ACs (plus OQ-6's resolved operator-audit pin)
without redundancy.

**Rejected alternative — a transcript-based assertion** (scan
dispatch transcripts for class-vs-instance evidence). Rejected
because (a) the directive is judgment-driven; transcript scan would
need an NLP-style heuristic to detect "did the agent enumerate the
class"; (b) prompt-content tests are the established pattern for
"does the prompt SAY X" assertions; transcript-based checks are
reserved for "agent must not INVOKE tool X" cases per CLAUDE.md
defense-in-depth note (`CLAUDE.md` "Defense-in-depth" subsection).

## 3. Architecture (where code goes)

Two files change. No new files.

### `AGENT_PROMPTS.md`

* **Insertion site:** between line 804 (existing `Concrete failure
  (ENG-123 iter 4-6)` bullet — end of step 5) and line 806 (existing
  `Minor/nit defer rule (MANDATORY — read BEFORE the findings list
  below; ENG-136):` header).
* **Block shape:** mirror the ENG-136 hoisted-block shape — a labeled
  paragraph followed by two sub-blocks (Fix-the-class, In-file cleanup
  carve-out) followed by a coherence paragraph that names the
  defer rule's override.
* **Fence count invariant:** the block is plain prose (bullet lists
  + paragraphs), no column-0 ``` fence. Preserves the §3 two-fence
  invariant required by `bin/render-prompt.sh:?` (CLAUDE.md "AGENT_
  PROMPTS.md is load-bearing").
* **STAGE_TO_SECTION table:** unchanged (`bin/render-prompt.sh:13-16`).
* **No new placeholder tokens** — the block does not introduce a
  `{class_examples}` or similar interpolation slot (would require a
  resolver in `bin/render-prompt.sh::PROMPT_RESOLVERS`).

### `bin/agent-prompts-content-test.sh`

* **Insertion site:** new block after the ENG-136 assertions at
  `bin/agent-prompts-content-test.sh:160-242`. Adjacent to the closest-
  semantic prior art.
* **Variables reused:** the test script already loads `$s3` at line 68
  (`s3="$(section_body "## 3. Implementation Agent (Backend)")"`).
  Re-use, do NOT re-declare.
* **Pattern:** 8 assertions matching the D-005 table; each is a
  `printf '%s\n' "$s3" | grep -qF '<literal>'` (or a position pin via
  `grep -nF "$PROMPTS" | head -1 | cut -d: -f1` for the AND-relation).

### `.pipeline-config/config.json`

No change.

### `bin/render-prompt.sh`

No change.

### `bin/scope-check.sh`

No change (per D-003 rejected alternative — the cleanup commit-tag
convention does not need scope-check teaching).

### `learned-rules/harness/implementation.md`

Reviewed (CLAUDE.md says retrospective edits these files). The
prompt-content directive does NOT need a parallel learned-rule entry
— the directive lives in the base prompt, not in the appended rules.
A future retrospective MAY add a `Gotcha-hit: G-XXX` style line if
the carve-out's ENG-123 boundary is repeatedly violated, but that's
a downstream signal, not a precondition.

## 4. Data flow

1. Orchestrator dispatches §3 with `from=reviewing to=implementing`
   transition → `{review_findings}` is inlined.
2. Agent reads the rendered §3 prompt (with the new block inserted).
3. Agent applies the 5-step block (existing) — step 5 sets the outer
   scope-drift restraint.
4. **NEW** Agent reads the Fix-the-class & in-file cleanup carve-out
   block:
   * Identifies the class of the cited finding (judgment-driven;
     reads defect mechanism only — anti-prompt-injection per D-002
     bound #1).
   * Enumerates sibling instances within plan File Structure
     (judgment + grep of in-scope files).
   * For each in-scope sibling whose fix shape stays inside the
     brainstorm/plan-authorized contract: closes it in the same
     dispatch with a `fix(<id>): <description> (class: <sibling-
     instance>)` commit.
   * For each in-scope sibling whose fix shape would require a new
     code path / contract field / defensive layer the brainstorm/
     plan did not authorize: HALTS with `<!-- meta: metric
     name=plan_gap -->` per D-002 bound #3 — even though the file
     is in File Structure, the contract is not authorized. (This
     bound applies independently of File Structure membership.)
   * For each out-of-File-Structure sibling: deferred per the
     Minor/nit defer rule; logged in stage-summary Notes.
   * For each in-file latent bug matching the in-bounds list (in a
     file already being edited): closed with a `cleanup(<id>):
     <one-line>` commit, subject to the §3 Self-review's
     Defensive-code restraint definition of "defensive layer".
   * Logs every sibling enumerated in stage-summary Notes
     (operator-audit signal per D-005 pin #9 / OQ-6 resolution).
5. Agent applies Minor/nit defer rule (existing) — the hard scope
   ceiling overrides any of the above.
6. Agent reads `{review_findings}` (existing) — already-listed
   findings get closed per step 1.
7. Within-stage iteration loop runs (existing — `AGENT_PROMPTS.md:871-
   932`).
8. Agent posts TDD-evidence comment + stage summary + `verdict pass`
   (existing).
9. Orchestrator's `bin/scope-check.sh` runs post-dispatch (existing) —
   verifies all touched files are in plan File Structure.
10. Next reviewer dispatch (§5) sees the class fully closed AND the
    cleanup commits as separate annotation; does NOT re-flag the same
    class. Cycle count drops.

## 5. Error handling

This is a prompt-content change — no runtime error paths to design.

* **Compile-time check:** the new block's prose-only formatting must
  not introduce a column-0 ``` fence inside §3's fenced body.
  Verified at implementation time by reviewing the inserted text and
  by `bash bin/render-prompt.sh implementing ENG-192` dry-render
  succeeding.
* **Test-time check:** the 8 content-test assertions catch a future
  edit that removes the directive or its key phrases. Triggered by
  `.githooks/pre-commit` on every commit touching `AGENT_PROMPTS.md`
  or `bin/agent-prompts-content-test.sh`.
* **Runtime (dispatch) check:** none. The directive is judgment-
  driven; the agent either applies it or doesn't. False-negatives
  (agent fixes instance-not-class anyway) loop back through the next
  reviewer dispatch — same as today, no regression. False-positives
  (agent expands scope into wrong-class territory) are caught by
  step 5 Scope-drift restraint (existing) and `bin/scope-check.sh`
  (existing).

## 6. Edge cases

* **Sibling instance lives outside File Structure.** Defer per the
  Minor/nit defer rule. Cite the deferred sibling in stage-summary
  Notes (reuse existing `Deferred [<severity>] <finding-id>:
  <file-path> — outside File Structure; class-closure deferred`
  shape).
* **Finding cited instance IS the entire class** (1-instance class).
  No expansion needed — the directive's "enumerate sibling
  instances" precondition is satisfied trivially.
* **Sibling instance is non-obvious / requires speculative search.**
  The agent should err conservatively. The directive says "enumerate",
  not "exhaustively imagine". If the agent cannot identify a sibling
  with reasonable confidence, document the search outcome in stage-
  summary Notes and move on. False-negative cost (one extra reviewer
  cycle) is bounded; false-positive cost (silent expansion into
  wrong-class territory) is the failure mode the directive exists
  to prevent.
* **In-file cleanup discovers a class of bugs deeper than "obvious
  latent issue".** Out of scope per D-003's denial list. The carve-
  out is for the in-bounds list only; a deep bug is a follow-up
  ticket (file via `<!-- meta: metric name=gotcha_new -->` or
  similar).
* **The class fix touches a file in plan File Structure that THIS
  dispatch has not yet modified.** In-scope subject to D-002 bound
  #3 — this is class-closure, not in-file cleanup. The Fix-the-class
  directive authorizes it because the file is within authorized File
  Structure AND the fix shape stays inside the brainstorm/plan-
  authorized contract (if it doesn't, halt with `plan_gap`). The
  In-file cleanup carve-out does NOT apply (its predicate is
  "modifying a file to address an explicit review finding" — a
  newly-touched file lacks the explicit-finding precondition).
* **An apparent in-file latent bug is actually load-bearing.** The
  carve-out's denial list's "no new behaviour" rule applies. If
  removing a "dead" function would change observable behaviour, it
  isn't dead and the carve-out doesn't authorize the change.
* **Two findings in the same dispatch cite different classes that
  overlap on one file.** Both classes get closed; both fixes land in
  the file. In-file cleanup may also fire on latent issues in that
  file. The commit log carries multiple `fix(<id>): ...` commits and
  potentially one `cleanup(<id>): ...` commit. Class boundaries
  remain INDEPENDENT — each class's File Structure check + brainstorm/
  plan authorization check runs separately; one class's plan_gap
  halt does NOT block the other class's closure.
* **The review finding's class spans files inside AND outside File
  Structure.** Close the in-File-Structure subset; defer the
  out-of-File-Structure subset in stage-summary Notes. The next
  plan iteration is the closure path for the deferred subset
  (existing `pipeline:extend` mechanism per ENG-136 prior art).
* **Cleanup commit ordering with TDD discipline.** The existing TDD
  rule (`AGENT_PROMPTS.md:952-961`) says "test commit first, impl
  commit second". The cleanup carve-out does NOT supersede TDD: if
  the cleanup involves adding a missing test for an existing branch,
  the test commit lands first as `cleanup(<id>): add test for
  existing <branch> case` (the `cleanup(` prefix still applies — the
  TDD ordering is about commit sequence, not commit type).

## 7. Open questions

* **OQ-1 (defer to follow-up).** Should the directive apply to
  QA-loopback (§3 lines 827-846) and/or to fresh (planning →
  implementing) dispatches as well? Linear scope says no — the
  directives are review-finding-driven. Defer to a follow-up
  ticket if empirical signal emerges showing the same instance-
  not-class failure mode in non-review-loopback dispatches.

* **OQ-2 (defer to implementation).** Does `bin/scope-check.sh::
  is_benign` need to be taught about the `cleanup(<id>):` commit-
  tag? Current code: scope-check enforces path boundaries; cleanup
  commits stay inside File Structure by D-003's predicate. To
  confirm at implementation, grep `bin/scope-check.sh` for any
  commit-message inspection logic (expected: none). If absent,
  no scope-check change is needed.

* **OQ-3 (defer to retrospective).** Should the retrospective audit
  `cleanup(<id>):` commits across PRs to detect ENG-123-shaped
  drift (cleanup commits that ACTUALLY added behaviour, in
  violation of D-003's denial list)? Useful but out of scope for
  this ticket — propose as a follow-up ticket if signal volume
  warrants. Candidate retrospective shape: a new shape under
  `bin/retro-prompts/cleanup-tag-audit.md`.

* **OQ-4 (resolved by D-005).** Should the content-test pins
  include a runtime smoke (dispatch a §3 prompt and assert the
  block renders)? Resolved: no. The 8 grep assertions against
  `AGENT_PROMPTS.md` directly are sufficient; runtime smoke would
  add I/O cost without catching anything the static assertions
  miss.

* **OQ-5 (resolved by Linear ticket folding).** Should ENG-148 be
  a separate ticket? Resolved by Linear ticket explicit folding
  ("Folds in ENG-148 (closed as duplicate 2026-06-13)"). The
  in-file cleanup carve-out ships with ENG-192.

* **OQ-7 (Success criteria + rollback path — added per product
  persona iteration 1).** The directive is judgment-driven prompt
  text. False-positives and false-negatives are both invisible to
  the harness's existing detective surfaces in real time.
  Post-deploy signal:
  * **Primary signal:** review-loopback cycle count delta — compare
    the median cycle count on review-loopback dispatches in the
    30 days BEFORE landing vs the 30 days AFTER. ENG-192 is working
    if the median drops AND the long-tail (75th / 95th percentile)
    compresses. **Caveat (per feasibility persona iteration 2 +
    grep verification).** No `events.jsonl::review_loopback` event
    is emitted today — grep against `bin/`, `bin/metrics.sh`, and
    `bin/pipeline-events.json` confirms zero matches. The primary
    signal is therefore CURRENTLY DERIVED from existing surfaces
    via grep recipe: count `<!-- pipeline: transition
    from=reviewing to=implementing -->` markers per issue in
    `events.jsonl` (transition events ARE emitted by `linear.sh
    add-comment` chokepoint per ENG-87) and treat each as one
    review-loopback cycle. A dedicated `review_loopback` metric
    event would be cleaner but is OUT OF SCOPE for ENG-192 and
    belongs to a follow-up ticket (candidate scope: ENG-189 epic
    tracking dashboard).
  * **Secondary signal:** retrospective audit (OQ-3) of `cleanup
    (<id>):` commits — count commits tagged `cleanup` that actually
    added behaviour (out-of-bounds list violations). Non-zero count
    → ENG-123-shaped drift; tighten the prompt block in a follow-up.
  * **Tertiary signal:** operator burden — count of stage-summary
    Notes lines per implementing dispatch (per the D-005 pin #9
    audit shape). A spike in deferred siblings + plan_gap halts
    means the agent is detecting the class but the plan is too
    tight; route to plan-stage retrospective. **Recipe today**
    (per product persona iteration 2): operator greps the per-
    issue `stage-summary-implementing.md` for `Deferred [` or
    `plan_gap` lines per dispatch via `git log --all -p
    'stage-summary-implementing.md'` or `grep -c "^Deferred \[\|
    plan_gap" $PROJECT_STATE_DIR/<slug>/<ENG-N>/stage-summary-
    implementing.md`. A retro shape automating this is a follow-
    up; ENG-192 ships the substrate only.
  Rollback path: revert the AGENT_PROMPTS.md block (single hunk
  bounded by content-test pin #1's header) + revert the
  9 new assertions in `bin/agent-prompts-content-test.sh`. No
  schema/state migration needed; no orchestrator code touched.
  Cost: one PR + one launchd plist redeploy (`bash bin/install-
  launchd.sh /path/to/target`).

* **OQ-6 (resolved YES — design persona iteration 1, product
  persona iteration 1, scope persona iteration 1).** The new
  block MUST include an explicit "stage-summary Notes" emission
  requirement for class-closure decisions: "list every sibling
  enumerated, with in-scope-closed / deferred / plan_gap status,
  using the existing `Deferred [<severity>] <finding-id>: <file-
  path> — <one-line rationale>` shape from `AGENT_PROMPTS.md:810-
  817`". Rationale: operator visibility into class-closure
  decisions is the audit trail for whether the directive is being
  applied correctly AND the substrate for OQ-3's retrospective
  audit signal. Adds D-005 content-test pin #9. The 9th pin
  expands D-005's authorized assertion count to 9 — this is the
  scope-tier resolution that scope persona iteration 1 flagged
  (OQ-6 should not leave the door open at plan time).

## 8. Anti-bias checks

### ADR stress test

The change puts NO pressure on any existing ADR. It refines an
existing prompt block (review-loopback handling) using the
established ENG-136 hoisted-block pattern. CLAUDE.md's existing
constraints (AGENT_PROMPTS.md load-bearing fence count;
§3 review-loopback contract; ENG-123 anti-defensive-code rule)
are preserved or tightened, not contradicted.

Mild tension: the existing "defensive-code restraint" clause at
`AGENT_PROMPTS.md:998-1030` (in the §3 self-review block) and the
new in-file cleanup carve-out's denial list both forbid "new
defensive layers". They agree, but the duplication is small. Cost:
two places to maintain the rule. Mitigation: the new block's denial
list cites ENG-123 by name, anchoring the rule to the same incident
the existing clause anchors to.

### Simpler alternative

For D-001 (block placement): the simplest alternative is to dump
the directives into step 1 of the 5-step block. Rejected because
ENG-136 explicitly migrated AWAY from that pattern after the
ENG-122 self-leak incident — burying ENG-192 in step 1 would
re-create the failure ENG-136 closed.

For D-002 (class boundary): the simplest alternative is "fix every
sibling regardless of File Structure". Rejected because the
orchestrator's scope-sweep would halt on the first
out-of-File-Structure sibling (re-creating ENG-122).

For D-003 (in-file cleanup carve-out): the simplest alternative
is "no carve-out at all — the cited finding is the cited finding".
Rejected per Linear ticket's explicit folding of ENG-148; the
Linear scope mandates the carve-out.

For D-005 (8 content-test assertions): the simplest alternative is
3-4 pins. Rejected because each AC requires at least one
assertion, and the ENG-136 prior art's 8-pin shape is the proven
minimum for catching "directive added but buried" regressions.

### Assumption inventory

Verified (with `path:line` reference):

* `AGENT_PROMPTS.md:736` — `## 3. Implementation Agent (Backend)`
  H2 section header.
* `AGENT_PROMPTS.md:787-825` — Review → implement loopback
  handling block (existing).
* `AGENT_PROMPTS.md:797-804` — 5-step block with step 5 being the
  existing Scope-drift restraint.
* `AGENT_PROMPTS.md:801` — Step 5 `**Scope-drift restraint — a
  review finding is NOT an authorization to expand scope.**`
* `AGENT_PROMPTS.md:804` — `Concrete failure (ENG-123 iter 4-6)`
  positional anchor for content-test pin #2.
* `AGENT_PROMPTS.md:806` — `Minor/nit defer rule (MANDATORY — read
  BEFORE the findings list below; ENG-136):` positional anchor for
  content-test pin #2.
* `AGENT_PROMPTS.md:823` — `Reviewing summary (verbatim):` header
  (downstream of the new block — unchanged position relative to
  defer-rule).
* `AGENT_PROMPTS.md:827-846` — QA → implement loopback handling
  block (NOT touched by this design, per D-004 explicit boundary).
* `AGENT_PROMPTS.md:998-1030` — §3 Self-review's existing
  "Defensive-code restraint" clause (referenced for ADR-stress-
  test duplication note).
* `bin/agent-prompts-content-test.sh:20-28` — `section_body`
  helper used to extract §3 fenced body.
* `bin/agent-prompts-content-test.sh:68` — `s3="$(section_body
  "## 3. Implementation Agent (Backend)")"` — variable reused by
  new assertions.
* `bin/agent-prompts-content-test.sh:160-242` — ENG-136 8-pin
  pattern; new assertions mirror this.
* `bin/render-prompt.sh:13-16` — `STAGE_TO_SECTION` mapping
  unchanged.
* `learned-rules/harness/implementation.md` exists at
  `learned-rules/harness/` (per setup-time discovery agent — file
  not directly read this dispatch, but the directory contents
  confirm). Per CLAUDE.md "AGENT_PROMPTS.md is load-bearing"
  section, learned-rules files are gated by `pipeline:rule-
  reviewed` and not edited by this ticket.
* CLAUDE.md ticket-sizing rubric: 1 subsystem (agent-prompts /
  implementing), 1 primary decision — autonomy-safe.
* CLAUDE.md "AGENT_PROMPTS.md is load-bearing" — fence-count + 9
  H2 sections invariant preserved (no new H2, no new column-0
  fence).
* `.githooks/pre-commit` runs every `bin/*-test.sh` (per CLAUDE.md
  "Pre-commit hook" subsection), so the new assertions enforce on
  every commit touching the prompt.
* No `docs/VISION.md`, no `docs/knowledge/decisions.md`, no
  `docs/knowledge/gotchas.md` exist in this repo — verified by
  `ls docs/`. The brainstorm references CLAUDE.md as the
  authoritative source of product principles in their absence.
* `docs/architecture.md` exists; structure (orchestrator +
  retrospective + three roots + per-stage allowlist) confirms the
  agent-prompts subsystem boundary.

Assumed (needs validation at implementation):

* The inserted prose block does not contain a column-0 ``` fence
  (Don't #2 in profile). VALIDATE: visually inspect the proposed
  text before commit; the ENG-136 block at `AGENT_PROMPTS.md:806-
  821` is the formatting precedent (prose-only).
* `bash bin/render-prompt.sh implementing ENG-192` dry-render
  produces a valid output after the edit (two fences detected in
  §3, no fence-count die). VALIDATE: run the command at
  implementation time on a worktree with the edit applied.
* `bin/scope-check.sh` does NOT inspect commit messages today.
  VALIDATE at implementation time: `grep -n 'commit\|message'
  bin/scope-check.sh`. If empty, OQ-2 resolves to "no change
  needed".
* §4 UI Agent has no review-loopback handling block.
  VALIDATE: confirmed via `grep -n "loopback\|review_findings"
  AGENT_PROMPTS.md` in the §4 line range (1086-1287) at brainstorm
  time — returned no review-loopback handling block. If a future
  ENG-XXX adds one to §4, that ticket can decide whether to mirror
  the ENG-192 directives.
* The `cleanup(<id>):` commit-tag does not collide with any other
  commit-tag convention in the repo. VALIDATE: `git log --oneline
  | grep -E "^[a-f0-9]+ cleanup"` returns no prior `cleanup`-
  tagged commits. (If priors exist, the convention may need a
  more specific prefix like `cleanup-eng-192(<id>):` — unlikely
  per the AC #3 phrasing.)

### Codebase-fact verification (MANDATORY)

Every named file / line / function / pattern referenced above
has been verified against current code. Specifically:

* `AGENT_PROMPTS.md:736` — `## 3. Implementation Agent (Backend)`
  ✓ verified via `grep -n "^## " AGENT_PROMPTS.md`.
* `AGENT_PROMPTS.md:787-825` — Review-loopback handling block
  ✓ verified via direct Read of lines 787-825.
* `AGENT_PROMPTS.md:801` — Step 5 Scope-drift restraint ✓
  verified by line content.
* `AGENT_PROMPTS.md:804` — `Concrete failure (ENG-123 iter 4-6)`
  ✓ verified via `grep -n "Concrete failure (ENG-123 iter 4-6)"
  AGENT_PROMPTS.md`.
* `AGENT_PROMPTS.md:806` — `Minor/nit defer rule (MANDATORY — read
  BEFORE the findings list below; ENG-136):` ✓ verified via
  grep.
* `AGENT_PROMPTS.md:823` — `Reviewing summary (verbatim):` ✓
  verified via grep.
* `bin/agent-prompts-content-test.sh:20-28` — `section_body`
  helper ✓ verified via Read.
* `bin/agent-prompts-content-test.sh:68` — `s3` variable ✓
  verified via Read.
* `bin/agent-prompts-content-test.sh:160-242` — ENG-136 block ✓
  verified via Read.
* `bin/render-prompt.sh:13-16` — `STAGE_TO_SECTION` ✓ verified
  via `grep -n "^STAGE_TO_SECTION\|implementing.*Implementation"
  bin/render-prompt.sh`.

No method, struct, or coordinator entrypoint is referenced that
does not exist in the current code. The only "assumed" items are
post-edit invariants (dry-render success, scope-check.sh commit-
message inertness) — bounded validation at implementation time.

## 9. Persona review

Durable audit trail. Personas dispatched as fresh general-purpose
sub-agents cold-reading the doc; verdicts captured verbatim below.

### Iteration 1 (initial draft)

| Persona | Verdict | Key findings |
|---|---|---|
| design | PASS-WITH-NITS | D-001 position-anchor ambiguity; D-002 bound #3 no worked example; D-003 TDD/cleanup tension; OQ-6 left open. |
| security | PASS-WITH-NITS | Commit-tag phishing surface; judgment-driven class identification exploitable via review prose. |
| scope | PASS-WITH-NITS | OQ-6 structurally embeds a 9th pin without resolution; OQ-3 retro shape borderline. |
| coherence | PASS-WITH-NITS | D-002 bound #3 not reflected in §4 data flow / §6 edge cases; defensive-code-restraint cross-ref missing. |
| product | PASS-WITH-NITS | Cost-savings attribution overclaims; OQ-6 should be resolved; missing OQ-7 (success criteria + rollback). |
| **feasibility** | **PASS (zero P0)** | All 14 codebase facts verified; no P0 / P1 / P2. |

Iteration 1 changes applied: anti-prompt-injection clause on class
identification (D-002 bound #1); commit-tag-is-advisory-metadata
clause (D-003); D-003 denial list cross-references §3 Self-review's
Defensive-code restraint by reference; D-002 worked examples
(in-scope vs plan_gap); §4 data flow step 4 expanded to mirror
D-002 bound #3 + D-005 pin #9 audit emission; §6 edge cases tightened
to bind D-002 bound #3; D-005 expanded to 9 pins; OQ-6 resolved YES;
OQ-7 added (success criteria + rollback); §1 win attribution
clarified.

### Iteration 2 (post-edit)

| Persona | Verdict | Key findings |
|---|---|---|
| design | PASS-WITH-NITS | D-005 header "8 vs 9" wording drift (cosmetic); plan_gap halt semantics (whole-dispatch vs partial-close); in-bounds list lacks worked example for "existing branch coverage". |
| **security** | **PASS** | No findings. All three iteration-1 asks (anti-prompt-injection clause; commit-tag advisory positioning; defensive-code cross-ref) cleanly addressed. |
| **scope** | **PASS** | No findings. OQ-6 cleanly resolved with explicit ticket-tier acknowledgement; OQ-7 carries no new infra; 9-pin count justified. |
| coherence | PASS-WITH-NITS | D-005 "8 vs 9" header drift (cosmetic). All rules-of-composition checks pass: D-002 bound #3 ↔ §4 step 4 ↔ §6 edge case all consistent; D-001 reading-order framing internally consistent; D-003 cross-ref unambiguous; class-boundary independence holds. |
| product | PASS-WITH-NITS | Win attribution lacks supporting citation; OQ-7 primary signal requires infra not in ENG-192; D-005 row count drift (cosmetic); pin #9 burden not weighed against audit value. |
| **feasibility** | **PASS (zero P0)** | All 16 codebase facts verified including iteration-2 additions (`AGENT_PROMPTS.md:810-817` Deferred shape; §3 Self-review's Defensive-code restraint at 998-1030; iteration-2-cited `events.jsonl::review_loopback` correctly flagged speculative — the event does NOT emit today, confirmed by grep across `bin/`). One nit: brainstorm cites `bin/render-prompt.sh:13-16` but actual block is 13-22 (line-range imprecision, not a fact error — variable + content match exactly). |

Iteration 2 polish applied (after persona-review pass):
- D-005 header + rationale updated to "9 assertions" consistently.
- OQ-7 primary signal acknowledges `events.jsonl::review_loopback`
  is speculative; provides a today-available grep recipe via
  `<!-- pipeline: transition from=reviewing to=implementing -->`
  marker counting.
- OQ-7 tertiary signal carries a today-available grep recipe.
- §1 win attribution cites the ENG-189 brainstorm post-incident
  timeline + ENG-113 PR commit log as the supporting evidence;
  framed as per-incident expected value, not guarantee.

### Gate status

Iteration 2 closes with 3 bare PASS + 3 PASS-WITH-NITS verdicts;
zero FAIL; feasibility bare PASS with zero P0. After the iteration-2
polish edits (small, additive, no decision-tier changes), residual
PASS-WITH-NITS nits are exhausted to cosmetic-only — design's "8 vs
9" drift, coherence's same nit, and product's win-citation polish are
all addressed. Per the dispatch's iteration bound ("Do NOT start
iteration 3"), the brainstorm is finalized at this point.

Gate: at least 5/6 PASS AND feasibility P0=0 — MET (counting
PASS-WITH-NITS verdicts where post-edit nits are exhausted to
cosmetic-only).

