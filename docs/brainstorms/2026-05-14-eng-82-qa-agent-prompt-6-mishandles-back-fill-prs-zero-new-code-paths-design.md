---
linear: ENG-82
title: QA agent §6 mishandles back-fill PRs (zero new code paths)
date: 2026-05-14
status: draft
---

# ENG-82 — QA agent prompt §6 mishandles back-fill PRs (zero new code paths)

## 1. Overview

`AGENT_PROMPTS.md` §6 (the QA agent) implicitly assumes the branch HEAD
carries implementation commits. Specifically:

- The branch-description prose at `AGENT_PROMPTS.md:1122` claims:
  > "Branch: \`{branch_name}\` (already carries backend + frontend
  > commits and the open PR from the review stage). Check it out; you
  > may commit additional test files here."
- The "Adversarial testing (MANDATORY — maker-checker within QA)" step
  at `AGENT_PROMPTS.md:1170-1183` requires "at least one test per
  category above … for each new code path."
- The Quality gates at `AGENT_PROMPTS.md:1200-1205` make "every new
  code path has boundary + failure-mode + concurrency tests" a hard
  pass requirement.
- The Decision path A/B/C at `AGENT_PROMPTS.md:1207-1238` does not name
  any "zero new code paths" exit; the implicit only-paths-out are
  flake-only, genuine-fail (→ implementing), or all-green (→ building).

On a **back-fill PR** — an issue scope of "document a fix that has
already shipped on `main`" — the branch HEAD typically carries only the
brainstorm + plan commits; `git diff main..HEAD --name-only` is
docs-only; and the "implementation" of the new code path lives on
`main` (or further back in main's history) from a separate, earlier PR.
The QA agent then has to:

1. Recognize this is a back-fill (no clause tells it that this
   topology exists),
2. Decide which Decision-path branch to take (none names this case),
3. Decide how to satisfy "new code path has tests" when there ARE no
   new code paths in the PR diff (the requirement is vacuously true,
   but the prompt doesn't say so),
4. Decide what to put in the stage-summary status line (the canonical
   line `All gates green · K adversarial tests added · proceeding to
   building` implies a positive K; back-fills naturally have K=0).

This is exactly what played out on **ENG-79** during the 2026-05-08
monitoring run (verified by reading
`/Users/rajatgoyal/.local/state/twinning-harness/harness/qa-monitoring-2026-05-08.md`):
the second QA dispatch (14:22–14:30Z, post PR #70's allowlist fix)
spent several minutes of reasoning budget rediscovering the same
workaround the first halted dispatch had taken, then emitted
"static-verification-only · 0 adversarial tests added" — a status
shape **not in the canonical Decision-path C status line**.

The Linear issue body proposes two fix shapes. **Shape A** ("Codify
the back-fill path in §6") is the smaller, more targeted change and is
the issue's stated preference. This brainstorm adopts Shape A, with a
narrow detection clause and a canonical Decision-path D for back-fills.
**Shape B** (gate back-fills out at brainstorm/plan) is **rejected** —
covered in §4 D-2 with reasoning: back-fills have audit-trail value
(the retrospective agent learns from them — verified at the ENG-79
brainstorm's O-1 paragraph at
`docs/brainstorms/2026-05-08-eng-79-…:590-609`).

**Load-bearing tradeoff.** Adding a new Decision-path D ("back-fill
verification") inside §6 grows the QA prompt by ~15–25 lines per
dispatch — that's per-issue × per-tick cost. The alternative ("leave
the contract broken; agents self-discover the workaround") spent
~3–4 minutes of agent reasoning budget on the only back-fill we've
observed (ENG-79) **and** produced a non-canonical status line that
makes operator audit harder. ~20 lines of prompt is the cheaper trade
once the harness expects to see ≥1 back-fill per quarter (back-fills
are a structural pattern: any time an operator notices a bug, fixes
it manually before the pipeline picks it up, and files a ticket for
post-hoc audit — see also ENG-87 brainstorm `umbrella` framing where
several prior fixes shipped before the meta-ticket was filed).

## 2. Goal

After ENG-82 lands:

- `AGENT_PROMPTS.md` §6 contains a back-fill detection clause that
  classifies the PR as a back-fill iff `git diff main..HEAD
  --name-only | grep -vE '^docs/'` returns zero lines.
- §6 contains a new Decision-path **D. Back-fill verification** that
  names the canonical status line `Static-verification-only · 0
  adversarial tests added · proceeding to building` and explicitly
  exempts the path from the "≥1 boundary / ≥1 failure-mode / ≥1
  concurrency test per new code path" budget (vacuously satisfied —
  there are zero new code paths).
- `bin/agent-prompts-content-test.sh` carries one pinning assertion
  that fails loudly if the back-fill clause's load-bearing tokens
  ("back-fill", "docs-only", or the canonical status line)
  disappear from §6.
- No `bin/` runtime code change. The clause is a prompt edit;
  detection is done by the agent at dispatch time using its already-
  allowed implicit `git` tools (read-only).
- `bin/render-prompt-test.sh` continues to pass — §6 column-0 fence
  count stays exactly 2.

This matches the Linear issue's "Fix shapes (pick one) → A" + Scope:
"AGENT_PROMPTS.md §6 prompt edit only (no `bin/` code change). One
pinning content-test in `bin/agent-prompts-content-test.sh` to prevent
regression of the back-fill clause."

## 3. Architectural principle

The harness has no `docs/VISION.md` or formal ADR registry — verified:
`ls docs/` returns `architecture.md  assumptions.md  brainstorms/
configuration.md  cost.md  demos/  install.md  operations.md
pipeline-vocabulary.md  pipeline-vocabulary.template.md  plans/
runbooks/  security.md`; no `VISION.md`, no `docs/knowledge/`. The
governing constraints come from `CLAUDE.md`, `docs/architecture.md`,
and per-slug `learned-rules/<slug>/project-profile.md`.

This brainstorm extends three already-established principles:

1. **Make agent contracts explicit, not implicit.** ENG-71/ENG-77's
   prompt-side defense pattern (verified at
   `bin/agent-prompts-content-test.sh:336-388` "rendered, post-iter-7-M4"
   assertions) treats every load-bearing rule as something the agent
   must read in its prompt, not something it has to derive from
   structural cues. The current §6 derives "this PR has new code
   paths" from prose ("already carries backend + frontend commits"),
   which silently breaks on back-fills.

2. **Name every decision-path outcome explicitly.** Decision-path A/B/C
   at `AGENT_PROMPTS.md:1207-1238` follows the convention that every
   stage-completion exit must be a named, canonical path with a known
   verdict shape. "Static-verification-only" today is a coping path,
   not a canonical one — the operator can't tell if the agent took a
   well-considered branch or improvised.

3. **Per-stage status lines are part of the audit surface.** The Stage
   summary comment format contract at `AGENT_PROMPTS.md:164-211` and
   the per-stage Status-line slot ("All gates green · K adversarial
   tests added · proceeding to building") are how operators triage
   pass/fail across many issues at a glance. A non-canonical status
   line breaks `grep`-based audit on `completion/qa/ENG-N` comments.

No existing principle is overturned. No new ADR is proposed; the
principles this brainstorm extends are implicit-but-established.

## 4. Decisions

Each decision has the form **D-N: \<verdict\>** + Why + rejected
alternatives, with `path:line` evidence quoted in the Assumption
Inventory (§11).

### D-1: Adopt Fix Shape A (codify back-fill path in §6); reject Shape B

**Verdict.** Implement Shape A from the Linear issue: add a back-fill
detection clause and a canonical Decision-path D inside §6. Reject
Shape B (gate back-fills out at brainstorm/plan).

**Why.**
- The Linear issue's own framing names A as "the smaller, more
  targeted change" and recommends it ("A is the smaller, more targeted
  change.").
- Back-fills have audit-trail value. ENG-79's brainstorm explicitly
  flagged this at `docs/brainstorms/2026-05-08-eng-79-…:597-609`:
  "captured here to maintain the audit trail and to give the
  retrospective agent a brainstorm-shaped record to learn from."
  Eliminating back-fills also eliminates the retrospective's learning
  surface for that class of bug.
- Shape B requires editing AT LEAST §1 (Brainstorm) and §2 (Plan)
  prompts (the gate would need to fire at brainstorm-time, before
  budget is spent on the doc), and would need a new "is this issue
  worth running through the pipeline at all?" heuristic — a much
  larger surface for prompt drift.

**Rejected alternative — Shape B (discourage back-fills at brainstorm/
plan).** Larger surface (two stages, not one), removes the audit-trail
value, and converts the operator's existing habit ("file ENG-N for
post-hoc audit") into a procedural ask ("don't file for fixes already
shipped"). Procedural rules in a pipeline this size drift fast
(verified pattern: ENG-87's `umbrella` brainstorm at
`docs/brainstorms/2026-05-09-eng-87-…` catalogs six prior tickets
where structural defenses outperformed procedural rules). Rejected.

**Rejected alternative — Hybrid: detect at brainstorm-time, also
codify at QA.** Doubles the surface for one signal. The
brainstorm-time detection adds value only if it's allowed to ABORT —
which Shape B is, but then this collapses back into Shape B. If
it's allowed only to WARN, it's a deferrable polish that ENG-82
shouldn't bundle. Rejected as scope creep.

### D-2: Detect back-fill via `git diff main..HEAD --name-only` on docs-only paths

**Verdict.** In §6, add a precondition block (immediately after the
existing branch-description line at `AGENT_PROMPTS.md:1122-1123` and
before "Authoritative test manifest" at line 1125) that says:

> Branch-shape detection (MANDATORY, BEFORE running gates):
>
>   Determine whether this PR introduces new code paths by running:
>
>     git diff main..HEAD --name-only
>
>   - If every changed path matches `^docs/` (i.e., the command
>     `git diff main..HEAD --name-only | grep -vE '^docs/'` returns
>     zero lines), this is a **back-fill PR**: the issue scope is to
>     document a fix already shipped on `main`. Skip to Decision path
>     **D** at the end of this section.
>   - Otherwise, proceed normally with the gate runs, coverage audit,
>     and adversarial-testing budget below.

The detection command is read-only (`git diff --name-only`), implicit
in the stage-agnostic core tool list (verified at
`learned-rules/harness/project-profile.md::## Tool allowlist` opening
paragraph: "Stage-agnostic core tools (Read, Write, Edit, Grep, Glob,
TaskCreate, git family, …) are implicit and not declared here").

**Why.**
- `git diff main..HEAD --name-only` is the exact signal the operator
  used in the Linear issue body ("if `git diff main..HEAD --name-only`
  only matches `^docs/`") and the ENG-79 monitoring record corroborates
  ("the diff vs main is docs-only" at
  `qa-monitoring-2026-05-08.md:262`).
- The signal is unambiguous: if the PR diff has zero code-bearing
  paths, the new-code-path budget is vacuously satisfied. Boundary
  tests, failure-mode tests, and concurrency tests are defined per
  new code path; zero paths means zero required tests.
- The detection runs before gates, so the agent doesn't spend gate-run
  budget on a path that's going to be a back-fill anyway. Gates STILL
  RUN under Decision-path D (we need to confirm `main` hasn't
  regressed since the back-fill PR was opened), but the adversarial
  budget and coverage audit are skipped.
- The `^docs/` regex is correct for the harness target (the profile's
  `## File layout` names `docs/brainstorms/`, `docs/plans/`,
  `docs/knowledge/` etc. as the only doc roots). It also generalizes
  to non-harness targets because every target's profile lists code
  roots distinct from `docs/`; a PR touching only `docs/` is
  ipso-facto docs-only across stacks. The clause does NOT need to
  reference profile-specific paths — the negation is sufficient.

**Rejected alternative — Detect via commit count
(`git log --oneline main..HEAD | wc -l == 2`).** Conflates "back-fill"
with "exactly 2 commits" (brainstorm + plan). This breaks if the
brainstorm/plan stages emit follow-up commits (e.g., persona-review
iterations), or if a back-fill happens to have an extra fix-typo
commit. The path-set is the canonical signal; commit count is a
proxy. Rejected.

**Rejected alternative — Detect via Linear label
(`pipeline:back-fill`).** Adds a new label to the harness lexicon and
requires the operator to apply it manually at issue creation
(brainstorm-time). The signal we want is computed from the branch
shape at QA-time; a Linear label is informational metadata, not
evidence. Also: existing CLAUDE.md guidance reserves `pipeline:*` for
orchestrator-managed and human-approval-gate labels (verified at
`CLAUDE.md::## Pipeline vocabulary`:
"The pipeline-namespace labels the harness applies are `pipeline:halted`
and `pipeline:abandoned`"). Adding a new one is a larger surface than
this ticket warrants. Rejected.

**Rejected alternative — Detect via profile's `## File layout` code
roots.** Profile-driven detection is appealing (ENG-94/95/97
established this pattern), but inverts unnecessarily here: the only
question is "any code change?", which is the complement of "only docs
changes." Since `docs/` is the universal docs root across all targets
(verified for harness at `learned-rules/harness/project-profile.md`
File layout section, naming `docs/brainstorms/` + `docs/plans/`;
verified for the twinning target at `learned-rules/twinning/` similar
shape), the negation is sufficient and simpler. Rejected.

### D-3: Add canonical Decision-path D (back-fill verification)

**Verdict.** Insert a new Decision-path D between current paths B and
C at `AGENT_PROMPTS.md:1207-1238`. The path body reads:

```
  D. **Back-fill PR** (branch-shape detection above flagged this PR
     as docs-only — every path under `git diff main..HEAD --name-only`
     matches `^docs/`):
     - Run the gate commands listed in the Project profile addendum's
       "Build & test gates" section. The gates protect against a
       regression on `main` between when the original fix shipped and
       this PR opened; they must still pass.
     - SKIP the coverage audit (§3), the regression-intent audit
       (§4), and the adversarial-testing budget (§5). The new-code-path
       budget is vacuously satisfied — zero new code paths means zero
       required tests.
     - Verify the brainstorm's specification matches the in-tree
       implementation. Use Read + Grep on `main` to confirm the code
       described in the brainstorm exists at the paths the brainstorm
       names. If the brainstorm describes something that is NOT in
       the tree, this is a P0 finding — treat as Decision-path B
       (genuine failure, loop back to implementing).
     - Commit no new tests (none required).
     - Post a QA summary comment on the PR (gates green + back-fill
       confirmation: brainstorm spec ↔ in-tree code match).
     - Write the stage summary file at `{stage_summary_path}` —
       follow the Stage summary comment format contract (preamble).
       Overwrite-on-every-dispatch contract per §0; orchestrator posts
       it to Linear as `completion/qa/{issue_id}`. Stage-specific
       slots:
       - Artifact link: the PR URL.
       - TL;DR: 1–2 sentences confirming this is a back-fill PR and
         that the brainstorm spec matches the shipped code.
       - Status line (clean):
         `Back-fill verified · 0 new code paths · 0 adversarial tests
         added · proceeding to building`.
       - Notes (only on partial-match): one paragraph if the
         brainstorm spec is partially out of date relative to the
         shipped code; cite specific drift.
     - Orchestrator advances to `stage:building`.
```

**Why.**
- The status line `Back-fill verified · 0 new code paths · 0
  adversarial tests added · proceeding to building` is canonical
  shape: it follows the same `<head> · <budget> · <verdict>` pattern
  as path C (`All gates green · K adversarial tests added ·
  proceeding to building`), so operator triage tools that grep on
  `proceeding to building` keep working unchanged.
- The path explicitly REQUIRES gates to still pass — back-fills are
  not a free pass past regressions. `main` may have moved since the
  back-fill PR was opened, and the gate-run is the only structural
  check that catches that.
- The brainstorm-spec ↔ in-tree-code verification is the actual QA
  signal for a back-fill: the question "is the documented fix
  faithful to the shipped fix?" is what the operator wants checked.
  This was implicit in ENG-79's second QA dispatch — the agent
  verbatim said "Let me read the plan to understand what was
  supposed to be implemented" (`qa-monitoring-2026-05-08.md:110`).
  Codifying it removes the dispatch-to-dispatch variation.
- The "P0 if brainstorm spec ≠ in-tree code" clause routes a real
  failure mode (brainstorm describes intent that wasn't shipped) back
  to implementing — which is the right loopback because someone needs
  to either ship the rest of the fix or revise the brainstorm.

**Rejected alternative — Decision-path D is "just exit pass without
any verification."** The detection signal is necessary but not
sufficient. The brainstorm could describe a fix that wasn't actually
shipped (operator filed the back-fill ticket then forgot to merge the
fix PR); a free-pass exit silently advances a defective state. The
gate-run + brainstorm-spec verification is the load-bearing check.
Rejected.

**Rejected alternative — Make Decision-path D loop back to
brainstorm if spec ≠ shipped code.** Loops back to a stage that has
already run; the brainstorm agent has no facility for "fix your prior
brainstorm." The right loopback is implementing (which can either
edit code to match the brainstorm OR re-trigger the brainstorm via
a P0 finding). This is symmetric with Decision-path B's existing
`fail --target implementing`. Rejected.

**Rejected alternative — Add Decision-path D but skip even the
gate-run.** Gate-runs are the only structural protection against a
regression on `main` between back-fill open and QA dispatch. The
ENG-79 monitoring record shows the agent did want to run gates and
benefited from doing so (`qa-monitoring-2026-05-08.md:124-125`:
"confirmed all gates green with the new allowlist"). Skipping
unconditionally creates a different failure mode: shipped-broken
status with a green pipeline. Rejected.

### D-4: Add one pinning test in `bin/agent-prompts-content-test.sh`

**Verdict.** In `bin/agent-prompts-content-test.sh`, add a §6-scoped
assertion block (placed near the other ENG-N §6 assertions — verified
no §6-specific block exists today by `grep -n 'QA Agent' bin/agent-prompts-content-test.sh`
returning only the section-iteration loops at lines 447, 493, 528,
572, 609, 1025, 1110):

```bash
# ─── ENG-82: §6 back-fill detection clause + Decision-path D ────────
# Without this rule, the QA agent on a back-fill PR (issue scope =
# document a fix already shipped) spends reasoning budget rediscovering
# the workaround and emits a non-canonical status line. See
# docs/brainstorms/2026-05-14-eng-82-…-design.md.
s6="$(section_body "## 6. QA Agent")"
if printf '%s\n' "$s6" | grep -qiF 'back-fill'; then
  ok "§6 ENG-82: carries 'back-fill' detection clause"
else
  nope "§6 ENG-82: carries 'back-fill' detection clause" \
       "phrase missing — QA agent will re-derive the workaround per dispatch"
fi
if printf '%s\n' "$s6" | grep -qF 'git diff main..HEAD --name-only'; then
  ok "§6 ENG-82: cites detection command 'git diff main..HEAD --name-only'"
else
  nope "§6 ENG-82: cites detection command 'git diff main..HEAD --name-only'" \
       "without the exact command, agents may invent different signals"
fi
if printf '%s\n' "$s6" | grep -qF 'Back-fill verified · 0 new code paths'; then
  ok "§6 ENG-82: pins canonical status line 'Back-fill verified · 0 new code paths · …'"
else
  nope "§6 ENG-82: pins canonical status line 'Back-fill verified · 0 new code paths · …'" \
       "non-canonical status lines break grep-based operator audit on completion/qa/ENG-N comments"
fi
```

The block uses `section_body` (not `rendered_stage_body`) because the
clause is §6-specific, not §0-consolidated.

**Why.**
- AC ("One pinning content-test in
  `bin/agent-prompts-content-test.sh` to prevent regression of the
  back-fill clause") names this file specifically.
- Three assertions cover the three load-bearing tokens: detection
  trigger ("back-fill"), detection command (`git diff …`), canonical
  status line. Any silent prompt cleanup that drops one of the three
  fails the suite.
- The status-line assertion uses the literal `· 0 new code paths`
  prefix (not a regex) so a future edit that drops the explicit zero
  is also caught — a status line that omits the zero is informative,
  but the explicit zero is the load-bearing pedagogical detail
  (it tells the operator "the agent saw zero, didn't just skip the
  budget").

**Rejected alternative — only assert the canonical status line.** Too
permissive: a future cleanup could remove the detection clause itself
(replace with a "use your judgment" hedge) and still keep the status
line. The detection signal is the load-bearing part. Rejected.

**Rejected alternative — assert by full multi-line regex match
against the entire Decision-path D body.** Brittle to cosmetic
changes (re-flowing prose, renaming a sub-bullet). The three
single-token assertions are necessary AND sufficient for the failure
modes ENG-82 cares about. Rejected.

**Rejected alternative — add assertion to the ENG-77 §0-consolidated
"overwrite on every dispatch" mandate.** Out of scope; the back-fill
clause is §6-specific not §0-consolidated. Different concerns,
different assertion locations. Rejected.

### D-5: Do NOT rewrite §6's branch-description prose at line 1122

**Verdict.** Leave `AGENT_PROMPTS.md:1122-1123` unchanged:

> Branch: \`{branch_name}\` (already carries backend + frontend
> commits and the open PR from the review stage). Check it out; you
> may commit additional test files here.

**Why.**
- For non-back-fill PRs (the common case), the existing prose is
  factually correct: backend + frontend commits ARE on the branch,
  the PR IS open from the review stage. Rewriting the prose to be
  ambiguous ("may carry …") makes the common-case agent more
  defensive than needed.
- The new branch-shape detection clause (D-2) immediately follows
  this prose; an agent that reads top-to-bottom sees the
  branch-description line, then immediately the back-fill detection
  clause that explicitly handles the exception. The ordering is
  pedagogically correct: "default expectation, then the exception."
- ENG-79's QA agent's verbatim "the QA prompt claims 'already carries
  backend + frontend commits' — that contract is broken" was a
  symptom of NO branch on the exception, not a problem with the
  default-case prose itself. With Decision-path D in place, the
  agent reads "default = backend + frontend; exception = back-fill,
  see path D"; the "contract is broken" framing disappears.

**Rejected alternative — soften the prose to "the branch carries the
commits the prior stages produced (which may be docs-only on a
back-fill — see branch-shape detection below)."** Tighter coupling
between the prose and the new clause, but the prose grows from one
clean sentence to a two-clause hedge. The detection clause directly
below already adds the back-fill carve-out; doubling it adds prompt
tokens without information. Rejected.

**Rejected alternative — rewrite the prose to drop the "already
carries backend + frontend commits" claim entirely.** Loses the
default-case signal. Operators reading §6 cold need to know that the
default expectation is "code commits are present"; the back-fill
case is the documented exception. Rejected.

### D-6: Status-line vocabulary — "Back-fill verified" not "Static-verification-only"

**Verdict.** The canonical status line for Decision-path D uses the
prefix `Back-fill verified` (not the Linear-issue's suggested
"Static-verification-only").

**Why.**
- "Back-fill verified" describes what happened (the agent verified
  the back-fill: gates ran, brainstorm spec ↔ in-tree code match).
  Operators triaging the completion/qa comments will recognize it
  as a Decision-path D headline directly.
- "Static-verification-only" describes the negation (what didn't
  happen — no adversarial tests run, no failure-mode tests). It's
  less precise: a regression test run that finds nothing is also
  "static verification only" in some readings.
- Both phrasings convey the same semantic; "Back-fill verified" is
  shorter and self-documents.

**Rejected alternative — keep "Static-verification-only" verbatim
per the Linear issue body.** The Linear issue offered the phrasing as
an example, not a contract ("emit canonical status line `Static-
verification-only · 0 adversarial tests added · proceeding to
building`"). The exact tokens are a brainstorm-stage decision. The
shorter, more precise phrasing is preferred. Rejected.

**Rejected alternative — use both, joined: "Back-fill (static-
verification-only)".** Doubles the prefix; loses brevity. The
"static verification" framing is implicit in "back-fill verified"
because the new-code-path budget skip is documented in path D's body
already. Rejected.

## 5. Architecture (where code goes)

Two files change:

1. **`AGENT_PROMPTS.md`** — three edit sites in §6:
   - **Insert** (~10 lines) between current lines 1123 and 1125: the
     branch-shape detection clause (D-2).
   - **Insert** (~28 lines) at current line 1222 (between Decision-
     paths B and C): the new Decision-path D body (D-3).
   - **No changes** to lines 1122-1123 (D-5), the new-code-path
     definition at lines 1131-1144, the quality gates at 1200-1205,
     the existing Decision-paths A/B/C, or the verdict-marker
     section at 1247-1267.

   The edits are non-structural (no section renames, no fence count
   changes); `bin/render-prompt.sh::extract_block` and
   `STAGE_TO_SECTION` are not touched. §6's column-0 fence count
   stays at 2 (the existing pair at lines 1110 + 1268 wrapping the
   fenced block — verified at the contract in `bin/render-prompt.sh:111`
   "die … expected 2 column-0 fences").

2. **`bin/agent-prompts-content-test.sh`** — three new assertions in
   a single new ENG-82 block (D-4). The block uses the existing
   `section_body` helper at line 20-32; no helper changes.

No other file changes. Specifically out of scope:

- `bin/dispatch.sh` — unchanged. The detection command uses implicit
  core `git` tools (the QA stage's tool allowlist at
  `learned-rules/harness/project-profile.md::## Tool allowlist::qa`
  lists test-suite invocations only; the `git family` is in the
  stage-agnostic implicit set).
- `bin/run-local-helpers.sh::partition_dirty_paths` — unchanged. The
  brainstorm doc generated for this ticket is in scope per D-004's
  issue-ID-in-basename check (`eng-82` is in the basename).
- `bin/render-prompt.sh` — unchanged.
- `bin/scope-check.sh` — unchanged.
- `CLAUDE.md` — unchanged. The back-fill case is QA-stage-specific
  and lives in §6; mentioning it in CLAUDE.md would add a second
  surface that drifts (see CLAUDE.md's existing pattern: stage-
  specific contracts live in AGENT_PROMPTS.md, CLAUDE.md describes
  cross-cutting orchestration).
- `learned-rules/harness/qa.md` — does not exist today (verified by
  `ls learned-rules/harness/` returning `build.md` + `project-profile.md`
  only). Could be a future home for the rule once the retrospective
  agent observes a recurrence, but ENG-82 itself ships the rule via
  the base prompt edit, not via a learned-rule.

## 6. Data flow

Dispatched agent receives, in this order:

1. The §0 (Common rules) fenced block, prepended to every stage by
   `bin/render-prompt.sh::main` (verified at `bin/render-prompt.sh:314`).
2. The §6 (QA Agent) fenced block, with `{token}` substitution applied
   by `resolve_block_tokens`.
3. The full `learned-rules/<slug>/project-profile.md` appended
   verbatim under a `## Project profile (addendum)` heading
   (`bin/render-prompt.sh:184-210`).

ENG-82 changes step 2's content for §6 only. The agent then performs:

1. Read the linear issue, brainstorm, plan, qa-patterns, conventions,
   learned rules (unchanged).
2. **Branch-shape detection (new):**
   - Run `git diff main..HEAD --name-only`.
   - If output is empty OR every line matches `^docs/`, mark as
     back-fill → jump to Decision-path D.
   - Otherwise proceed normally.
3. If back-fill:
   - Run the gate commands listed in the profile addendum's
     `## Build & test gates` (still required).
   - Read the brainstorm doc; for each named code-bearing artifact,
     Read+Grep against the current tree (which includes the shipped
     fix on main, merged in by the orchestrator's
     `_pre_dispatch_merge_gate` flow) to confirm it exists.
   - If brainstorm spec doesn't match the tree: P0 finding → path B.
   - Otherwise: write stage summary file with the canonical Back-fill
     status line; emit `verdict pass --stage qa`; exit.
4. If not back-fill: existing flow (paths A/B/C unchanged).

The orchestrator-side flow is unchanged: a `verdict pass --stage qa`
marker advances `stage:qa → stage:building` regardless of which
Decision-path inside §6 produced it (verified by the orchestrator
transition log on ENG-79's monitoring record:
`qa-monitoring-2026-05-08.md:136` "Orchestrator transition log
(14:30:29 – 14:30:54Z): … `qa → building` applied").

## 7. Error handling

- **Detection-command failure (`git diff` exits non-zero).** Extremely
  unlikely (the worktree is on the branch by the orchestrator's
  invariant). If it does happen, the agent falls through to "not a
  back-fill" — i.e., proceeds normally. This is fail-open in the
  conservative direction: a back-fill that LOOKS like non-back-fill
  produces a wasted adversarial-test cycle but no incorrect verdict.
  A non-back-fill that LOOKS like back-fill (the failure mode we
  want to avoid) requires the `git diff` to emit empty stdout while
  succeeding — which only happens when there genuinely are zero
  diffs vs main, the back-fill condition.

- **Brainstorm spec ↔ in-tree code mismatch.** Routed via path B
  (`fail --target implementing`) — see D-3. The implementing agent
  on loopback can either (a) ship missing code to match the
  brainstorm, or (b) emit a wait/halt asking the operator whether
  the brainstorm should be revised. Both routes are existing flows;
  no new orchestrator branch is required.

- **Pre-existing failure modes (qa-patterns, regression-intent,
  scope-violation).** Unchanged. Decision-path D explicitly skips
  §3 (coverage audit) and §5 (adversarial budget); §1 (flaky-pattern
  triage), §2 (gate runs), and §4 (regression-intent) all still
  apply. The agent reads §6 top-to-bottom; the gate run in §2 is
  unconditional; only the things D's body says "skip" are skipped.

- **§6 fence count drift.** `bin/render-prompt.sh::extract_block`
  dies if §6's column-0 fence count != 2. The two new inserts both
  go INSIDE the existing fenced block (between lines 1110 and 1268),
  so the column-0 fence count stays at exactly 2. The §6-specific
  assertion in D-4 doesn't test fence count directly, but the
  existing universal §2-fence-count assertion at lines 184-190
  (`bin/agent-prompts-content-test.sh`) plus the implicit
  `render-prompt-test.sh` would catch §6 fence drift.

- **Detection clause grows over time (drift via future edits).** The
  three load-bearing tokens (D-4) are pinned by content-test
  assertions. Drift in any one of them fires the pre-commit hook
  immediately (`.githooks/pre-commit` runs the full `bin/*-test.sh`
  suite — verified at `CLAUDE.md::## Tests / Pre-commit hook`).

## 8. Edge cases

| Case | Handling |
|---|---|
| Back-fill PR with one trailing fix-typo commit that touches `bin/` | Detection fires "not back-fill" because `git diff main..HEAD --name-only` returns at least one non-`^docs/` path. Agent runs full QA flow. Acceptable false-negative (over-tests rather than under-tests). |
| PR that mixes docs + a single one-line code fix (e.g., bug fix + brainstorm in the same branch) | Detection fires "not back-fill" — the code change WILL bring a new code path that needs the adversarial budget. Acceptable: not a back-fill by design. |
| Back-fill where the in-tree code matches an OLDER version of the brainstorm (operator updated brainstorm after the fix shipped) | Brainstorm-spec ↔ in-tree-code match check in path D's body catches this. The agent quotes a `path:line` mismatch and returns path B (fail to implementing); implementing-agent loopback can either re-ship code or re-edit brainstorm. |
| Back-fill where the in-tree code does the SAME THING as the brainstorm but via a refactored path (function renamed, file moved) | Verified by grepping for the brainstorm's described BEHAVIOR not just exact names. If the brainstorm says "render-prompt.sh sources branch-name.sh" and the code does, the check passes. If the brainstorm says "uses fixed string `feature/`" but the code uses `feat/`, the check fails (correct — this is a real spec drift). |
| §6 contains the literal substring `back-fill` in unrelated future content (e.g., quoting another stage's prompt) | Test assertion at D-4 just checks presence — false positives don't fire. False negatives (the token gets renamed) DO fire — desired. |
| Operator manually applies `pipeline:back-fill` label (rejected in D-2 but might be requested as a follow-up) | Out of scope. The detection signal is structural (path-set), not metadata-driven. If the operator wants a halt-on-back-fill workflow, that's a separate ticket. |
| Two issues at `stage:qa` simultaneously, one back-fill and one normal | Each runs its own §6 detection independently. No cross-issue interaction. |
| Back-fill where the brainstorm wasn't committed yet (e.g., agent dispatch raced ahead of brainstorm commit) | Detection still works (the PR's branch has only the plan commit; `git diff` shows zero non-`^docs/` paths because the plan touched only `docs/`). But the brainstorm-spec ↔ in-tree-code check NEEDS the brainstorm; if it's absent, the agent can't run the check and must halt-for-human (`verdict halt --reason agent-blocked`). This is correct — back-fill verification requires a brainstorm to verify against. |
| `git diff main..HEAD --name-only` includes a renamed file (`R old → new`) where one path is `^docs/` and one isn't | `git diff --name-only` returns ONLY the new path after rename (verified by the standard `git diff` semantics; not by code-side test in this brainstorm). If the new path is `^docs/`, it counts as a docs change. If the new path is code, the negation regex catches it as not-docs. Correct behavior in both cases. |
| Empty `git diff main..HEAD --name-only` (zero changed files vs main) | Detection treats it as docs-only (vacuous: every line matches `^docs/` because there are no lines to violate). Decision-path D runs. The brainstorm-spec ↔ in-tree-code check is then the load-bearing verification. Operationally: zero-diff means even the brainstorm/plan docs aren't on the branch (orchestrator skipped them?) — almost certainly an operator-initiated edge case; path D's brainstorm-read would fail to find the brainstorm and halt. Acceptable.|
| Detection clause's `^docs/` regex misses a docs file outside `docs/` (e.g., a top-level `README.md` edit) | `README.md` does NOT match `^docs/`. If a back-fill PR includes a `README.md` change, detection fires "not back-fill" and the agent runs the full QA flow (which is a no-op for a README edit anyway, modulo wasted gate-run time). Acceptable trade-off; the alternative (a list of docs-like-paths) introduces more regex and more drift surface. |
| Tests on the branch (`bin/*-test.sh`) — the back-fill might have its own test changes | Tests live under `bin/` not `docs/`, so the detection fires "not back-fill" and the agent runs normally. This is the correct behavior: a PR with test changes has at least the new test as a new code path. |

## 9. Open questions

| OQ | Question | Default if not resolved |
|---|---|---|
| OQ-1 | Should the detection clause name-check `main` or `origin/main`? The harness uses `origin/main` for the scope sweep (per ENG-59 fix). | Use `main` per the Linear issue's literal phrasing. The agent operates inside a worktree where the orchestrator's `_pre_dispatch_merge_gate` has already ensured `main` is fresh; for QA we trust local `main`. If operators see drift, OQ-1 escalates to a follow-up. |
| OQ-2 | Should Decision-path D's gate-run be optional (skip if `main` is unchanged since back-fill PR opened)? | Default: gates always run. The savings are negligible (back-fill gate-runs are cheap relative to a full adversarial cycle), and the structural protection against `main`-regression is the load-bearing check. |
| OQ-3 | Should the back-fill detection clause also surface the original-fix commit SHA (`git log main --grep '<issue id>' --pretty=%H`) in the stage summary? | Default: not in v1 of the clause. Adds value for retrospective archaeology but is informational, not load-bearing for the verdict. Operator can grep `main` themselves if curious. |
| OQ-4 | Should the brainstorm-spec ↔ in-tree-code check be a "smoke" check (any reference to the brainstorm's named artifacts exists) or a "full" check (every named artifact matches by behavior)? | Default: smoke check — verify named artifacts exist by `Read` + `Grep`. Full behavior verification is what the brainstorm-spec WAS for at brainstorm-time; re-running it at QA-time duplicates work. The smoke check catches the "brainstorm describes nothing that exists" failure mode without burning agent budget on re-verification. |
| OQ-5 | Should `bin/agent-prompts-content-test.sh`'s ENG-82 assertions also pin Decision-path letter `D` (vs allowing future renumbering)? | Default: no letter pin. The status-line + back-fill + detection-command tokens are the load-bearing signals; letter renumbering is cosmetic. If a future ticket renumbers paths, the assertions still fire correctly. |
| OQ-6 | Should we add a `learned-rules/harness/qa.md` entry codifying the same rule, so it's enforced redundantly via the retrospective approval flow? | Default: no. The base prompt is the canonical home for stage-specific rules at ENG-82's time horizon. `learned-rules/<stage>.md` is where the retrospective agent writes rules in response to RECURRENCE — ENG-82 is the first occurrence to be codified, so it goes in the base prompt. If back-fills recur with the same workaround drift, the retrospective will surface a qa.md candidate. |

## 10. Out of scope

- **Shape B (gate back-fills out at brainstorm/plan).** Explicitly
  rejected in D-1. A separate ticket can pursue this if back-fills
  prove to have negative learning value over time.
- **Linear label `pipeline:back-fill`.** Explicitly rejected in D-2.
- **A new `learned-rules/harness/qa.md` rule.** Out of scope per
  OQ-6's default.
- **Changes to non-§6 stage prompts.** None required. The detection
  signal is QA-stage-specific; earlier stages don't have the
  `git diff main..HEAD` signal yet (brainstorm/plan create commits
  ON the branch; only at QA does the branch contain its full
  set of commits).
- **Changes to orchestrator-side code (`bin/run-stage.sh`,
  `bin/poll.sh`, `bin/verdict-handler.sh`).** None required. The
  Decision-path D verdict is `pass --stage qa`, identical to path C;
  the orchestrator can't tell them apart and doesn't need to.
- **Metrics — new `qa_back_fill` metric.** Not in this ticket; the
  retrospective can derive back-fill frequency by grepping
  `completion/qa/ENG-N` Linear comments for the `Back-fill verified`
  status line if needed.
- **CLAUDE.md updates documenting the back-fill case.** The case is
  prompt-stage-specific; documenting it in CLAUDE.md creates a
  drift surface (per the §5 rationale). Leave it documented only
  in §6 of AGENT_PROMPTS.md.

## 11. Assumption inventory

Every named file, function, line range, command, or contract
referenced in this brainstorm is verified against the current code.
"Verified" means the file/line was read directly in this dispatch
and the quote is correct as of HEAD on the working branch.

| # | Assumption | Status | Evidence (`path:line` or quote) |
|---|---|---|---|
| A-1 | `AGENT_PROMPTS.md:1108` is the H2 header `## 6. QA Agent` | **verified** | Read `AGENT_PROMPTS.md:1108`: `## 6. QA Agent` |
| A-2 | `AGENT_PROMPTS.md:1110` and `:1268` are the two column-0 ``` fences wrapping §6 | **verified** | Read `AGENT_PROMPTS.md:1110`: opening ```; `AGENT_PROMPTS.md:1268`: closing ```; the §6 body is bounded by these two lines |
| A-3 | `AGENT_PROMPTS.md:1122-1123` carries the "already carries backend + frontend commits and the open PR" prose | **verified** | Read `AGENT_PROMPTS.md:1122-1123`: "Branch: \`{branch_name}\` (already carries backend + frontend commits and the open PR from the review stage). Check it out; you may commit additional test files here." |
| A-4 | `AGENT_PROMPTS.md:1131-1144` is the "New-code-path definition" block with the three-test budget (boundary / failure-mode / concurrency) | **verified** | Read `AGENT_PROMPTS.md:1131-1144`: "New-code-path definition (replaces the legacy handwave): A 'new code path' is any of the following … Per new code path, the minimum test budget is: - ≥1 boundary test … - ≥1 failure-mode test … - ≥1 concurrency test … A new path that lacks any of these three is a P0 finding." |
| A-5 | `AGENT_PROMPTS.md:1170-1183` is the §5 (Adversarial testing) MANDATORY step | **verified** | Read `AGENT_PROMPTS.md:1170-1183`: "Adversarial testing (MANDATORY — maker-checker within QA): After happy-path and plan-enumerated tests pass, write NEW tests QA-authored: for each new code path …" |
| A-6 | `AGENT_PROMPTS.md:1200-1205` is the Quality gates block making "every new code path has boundary + failure-mode + concurrency tests" a hard requirement | **verified** | Read `AGENT_PROMPTS.md:1200-1205`: "Quality gates (must all be true to advance): … Every new code path has boundary + failure-mode + concurrency tests per the budget. No regressions without an explicit `Regression-intent:` trailer." |
| A-7 | `AGENT_PROMPTS.md:1207-1238` is the Decision-path A/B/C block | **verified** | Read `AGENT_PROMPTS.md:1207-1238`: "Decision path (apply exactly one): A. Flake-only failures … B. Genuine failures … C. All green: …" |
| A-8 | Decision-path C's canonical status line is `All gates green · K adversarial tests added · proceeding to building` | **verified** | Read `AGENT_PROMPTS.md:1232`: "Status line (clean): `All gates green · K adversarial tests added · proceeding to building`." |
| A-9 | `AGENT_PROMPTS.md:1247-1267` is the Verdict marker (MANDATORY at exit) block | **verified** | Read `AGENT_PROMPTS.md:1247-1267`: "Verdict marker (MANDATORY at exit): Post exactly ONE additional append-only comment with your verdict: On all-green (path C), run: `bash bin/pipeline.sh event {issue_id} verdict pass --stage qa` …" |
| A-10 | `bin/render-prompt.sh::extract_block` requires exactly 2 column-0 fences per section, else `die` | **verified** | Read `bin/render-prompt.sh:111-112`: `if [[ "$fence_count" != "2" ]]; then die "AGENT_PROMPTS.md schema error: section '$section' has $fence_count column-0 fences (expected 2)..."` |
| A-11 | `bin/agent-prompts-content-test.sh::section_body` is defined at line 20-32 and returns the body of a named section | **verified** | Read `bin/agent-prompts-content-test.sh:20`: `section_body() {`. Helper extracts the body of an `## N. <name>` section by awk-tracking H2 boundaries and in-fence state. |
| A-12 | `.githooks/pre-commit` runs the full `bin/*-test.sh` suite at commit time, blocking commits with new failures | **verified** | `CLAUDE.md::## Tests / Pre-commit hook` section: "The repo ships a pre-commit hook at `.githooks/pre-commit` that runs the entire `bin/*-test.sh` suite (~30 s) and blocks the commit on any failure." `bin/agent-prompts-content-test.sh` is a `bin/*-test.sh` file. |
| A-13 | `git diff main..HEAD --name-only` is a stage-agnostic core tool (no per-stage tool-allowlist entry required) | **verified** | `learned-rules/harness/project-profile.md::## Tool allowlist` opening paragraph: "Stage-agnostic core tools (Read, Write, Edit, Grep, Glob, TaskCreate, **git family**, `bash bin/linear.sh`, `bash bin/pipeline.sh`, `bash bin/guards.sh`, `bash bin/slack.sh`, `bash bin/metrics.sh`) are implicit and not declared here." `git diff` is in the git family. |
| A-14 | ENG-79's 2026-05-08 QA monitoring run is the source incident | **verified** | Read `/Users/rajatgoyal/.local/state/twinning-harness/harness/qa-monitoring-2026-05-08.md`. Specifically line 110 ("The QA prompt claims 'already carries backend + frontend commits' — that contract is broken. Let me read the plan to understand what was supposed to be implemented."), line 118 ("[likely worth filing as a follow-up] QA prompt contract drifts on back-fill PRs."), and line 262 ("[likely worth filing] QA prompt contract drifts on back-fill PRs. The QA agent's prompt assumes `git log main..HEAD` includes implementation commits …"). |
| A-15 | ENG-79's brainstorm explicitly framed the issue as a back-fill at the O-1 observation | **verified** | Read `docs/brainstorms/2026-05-08-eng-79-render-prompt-sh-212-hardcodes-branch-name-feature-issue-id-lower-slug-drifts-from-branch-name-sh-canonical-feat-shape-design.md:590-609`: "**O-1 (process — flag explicitly).** The fix described in this brainstorm is *already in the tree* at commit `7772687` … The brainstorm is therefore post-hoc documentation of an already-shipped fix — captured here to maintain the audit trail …" |
| A-16 | `bin/render-prompt.sh::append_project_profile` appends the project profile to every non-retrospective stage (including QA) | **verified** | Read `bin/render-prompt.sh:184-210`. Function checks `stage == "retrospective"` first (cat passthrough); else appends `learned-rules/$PROJECT_SLUG/project-profile.md` under `## Project profile (addendum)` header. QA is not `retrospective`, so the addendum IS appended. |
| A-17 | `bin/agent-prompts-content-test.sh` does not currently contain any §6-specific QA-agent block (the existing §6 references are all inside section-iteration loops, not §6-specific blocks) | **verified** | Read `bin/agent-prompts-content-test.sh` grepped for "QA Agent": all matches at lines 447, 493, 528, 572, 609, 1025, 1110 are inside `for stage_section in … do` loops or `assert_overwrite_mandate` calls; no `s6="$(section_body "## 6. QA Agent")"` block exists. |
| A-18 | The harness has no `docs/VISION.md` or `docs/knowledge/decisions.md` ADR registry | **verified** | `ls docs/` returns: `architecture.md  assumptions.md  brainstorms  configuration.md  cost.md  demos  install.md  operations.md  pipeline-vocabulary.md  pipeline-vocabulary.template.md  plans  runbooks  security.md`. No `VISION.md`, no `knowledge/` subdir. |
| A-19 | The orchestrator's per-issue worktree is already on `{branch_name}` at QA dispatch time (so `git diff main..HEAD` works without a checkout) | **verified** | `docs/architecture.md::## Per-issue state directory` (lines 323-340) describes the per-issue worktree directory; `CLAUDE.md::## Per-issue state directory` notes "The orchestrator NEVER dispatches into `$TARGET_REPO` — every dispatch resolves a per-issue worktree first (ENG-67)." The worktree is on the branch by construction. |
| A-20 | `bin/run-local-helpers.sh::partition_dirty_paths` requires `eng-N` (lowercase) in basename for D-004 in-scope check on brainstorming/planning | **verified** | Read `bin/run-local-helpers.sh:535-577`: `partition_dirty_paths()` sets `apply_d004=1` on `brainstorming|planning`, computes `issue_lower="$(printf '%s' "$issue_id" | tr '[:upper:]' '[:lower:]')"` and uses it as a regex match against basenames. The brainstorm filename for ENG-82 contains `eng-82` in its basename, so it will be classified in-scope. |
| A-21 | `bin/render-prompt.sh::STAGE_TO_SECTION` does not need to change for §6 edits | **verified** | Read `bin/render-prompt.sh:1-60` (the STAGE_TO_SECTION lookup table): keys are stage names (`brainstorming`, `planning`, …); values are H2 section names like `"## 6. QA Agent"`. ENG-82 keeps the section name unchanged. |
| A-22 | `bin/render-prompt-test.sh` does not assert §6-specific Tauri or back-fill content (so adding a back-fill clause doesn't break existing tests) | **verified** | Grep `bin/render-prompt-test.sh` for "QA\|back-fill\|qa-": no §6-specific content assertions; the file tests profile-addendum behavior, slug derivation, and fence-extraction invariants. |
| A-23 | `failure_outcome_for_exit` in `bin/common.sh` has no exit code for "back-fill verified" (no new code is needed — pass --stage qa works) | **verified** | `docs/architecture.md::## Failure taxonomy` table at lines 294-303: codes 0=success, 20=agent-blocked, 21=scope-violation, 22=protocol-violation, 23=dispatch-timeout, 24=linear-post-failed, 25=pr-opened-too-early, 26=iteration-exhausted. A successful Decision-path D exit is exit 0 (success), like path C. No new code needed. |
| A-24 | The orchestrator advances `stage:qa → stage:building` on `verdict pass --stage qa` regardless of which §6 Decision-path produced it | **verified** | ENG-79 monitoring record at `qa-monitoring-2026-05-08.md:136`: "`verdict result=pass stage=qa` posted at 14:30:07Z. … Orchestrator transition log (14:30:29 – 14:30:54Z): … `qa → building` applied. ENG-79 labels now: `["stage:building"]`." ENG-79's QA agent took the (non-canonical) "static-verification-only" coping path and the orchestrator still advanced normally. |
| A-25 | The §6 verdict marker section's `bash bin/pipeline.sh event {issue_id} verdict pass --stage qa` is the universal pass exit (no path-specific verdict variant exists) | **verified** | Read `AGENT_PROMPTS.md:1250-1252`: "On all-green (path C), run: `bash bin/pipeline.sh event {issue_id} verdict pass --stage qa`". The verdict registry has no "back-fill-pass" variant; pass --stage qa is the canonical advancement signal. |
| A-26 | `bin/pipeline.sh event` validates verdict tokens against `bin/pipeline-events.json` (so we cannot invent a new `verdict pass --stage qa --kind back-fill` variant without registry changes) | **verified** | Read `CLAUDE.md::## Pipeline vocabulary`: "Single source of truth: `docs/pipeline-vocabulary.md` (generated from `bin/pipeline-events.json` via `bin/generate-vocabulary-doc.sh`). All state-driving comments use `<!-- pipeline: <event> ... -->` … Use `bin/pipeline.sh` to emit markers; the helper validates against the registry." Decision-path D uses the existing `verdict pass --stage qa` marker, no new registry entry. |
| A-27 | The brainstorm filename `2026-05-14-eng-82-…-design.md` complies with the docs/brainstorms/ pattern and contains `eng-82` for D-004 | **verified** | Filename pattern matches existing brainstorms (`2026-MM-DD-eng-N-...-design.md`); basename contains `eng-82` lowercase per D-004 in-scope requirement (A-20). |
| A-28 | `git diff main..HEAD --name-only` semantics under rename: returns only the new path, not the old | **assumed** | Standard `git diff` semantics — verified by external git documentation, not by code in this repo. If wrong, the impact is bounded: an additional non-`^docs/` path appears in the output, fires "not back-fill," wasted adversarial cycle but no incorrect verdict (fail-conservative). |
| A-29 | `learned-rules/harness/qa.md` does not exist today | **verified** | `ls learned-rules/harness/` returns: `build.md  project-profile.md`. No `qa.md` file. |
| A-30 | The `## 6. QA Agent` section header line number (1108) is stable enough to insert content without renumbering | **verified** | Read `AGENT_PROMPTS.md` H2 list (via grep): `## 6. QA Agent` at line 1108, `## 7. Build Agent` at line 1270. Inserts inside §6 push the §7 start line down but do not change the section identifier (`bin/render-prompt.sh::STAGE_TO_SECTION` keys by name, not line number). |
| A-31 | The `^docs/` regex correctly captures every docs-only path in the harness layout | **verified** | `learned-rules/harness/project-profile.md::## File layout` names `docs/brainstorms/` and `docs/plans/` as the canonical doc roots; both match `^docs/`. The `docs/knowledge/` subdir does not exist today (A-18) but if added would also match `^docs/`. |
| A-32 | The brainstorm-spec ↔ in-tree-code verification can be performed with Read + Grep on the QA agent's tool set (no additional allowlist entries required) | **verified** | Read + Grep are stage-agnostic core tools per A-13. No new permission grant required for this dispatch shape. |

## 12. ADR stress test

The harness has no formal ADR registry (A-18). The implicit principles
this ticket extends:

1. **"Make agent contracts explicit, not implicit"** (ENG-71/ENG-77,
   verified at `bin/agent-prompts-content-test.sh:336-388`).
2. **"Name every decision-path outcome explicitly"** (Decision-path
   A/B/C convention at `AGENT_PROMPTS.md:1207-1238`).
3. **"Per-stage status lines are part of the audit surface"** (Stage
   summary comment format at `AGENT_PROMPTS.md:164-211`).

ENG-82 does NOT put pressure on any existing decision. The brand-new
Decision-path D is structurally identical to path C from the
orchestrator's perspective (same `verdict pass --stage qa` exit, same
`stage:qa → stage:building` transition); only the internal workflow
of §6 changes. No existing assertion in
`bin/agent-prompts-content-test.sh` is invalidated.

One subtle pressure point: the new-code-path budget at
`AGENT_PROMPTS.md:1131-1144` is universal in current §6 ("A new path
that lacks any of these three is a P0 finding"). Decision-path D
introduces an exception ("zero new paths means vacuously satisfied").
The framing in path D's body is careful to phrase this as "vacuously
satisfied" rather than "exempt" — the budget rule is mathematically
true (the universal quantifier over the empty set is trivially true),
just zero-cost. This preserves the principle.

No existing ADR is overturned. No new ADR is proposed; the implicit
principles this ticket extends are well-established by prior tickets.

## 13. Simpler-alternative inventory

For each major decision, the rejected alternative + why-rejected is
documented inline in §4. Summary table:

| Decision | Simpler alternative rejected | Why |
|---|---|---|
| D-1 (Shape A) | Shape B (gate back-fills out upstream) | Larger surface, eliminates audit-trail value |
| D-1 (Shape A) | Hybrid (B + A) | Collapses to Shape B if abort allowed |
| D-2 (`git diff` detection) | Commit count (`==2`) | Proxy, not the signal; breaks on iter follow-ups |
| D-2 (`git diff` detection) | Linear label `pipeline:back-fill` | Adds vocabulary, requires operator action |
| D-2 (`git diff` detection) | Profile File-layout code-roots | Inverts unnecessarily; `^docs/` is universal |
| D-3 (Decision-path D) | Free-pass exit | Misses brainstorm-spec ↔ shipped-code drift |
| D-3 (Decision-path D) | Loopback to brainstorm | Brainstorm agent has no fix-prior-brainstorm flow |
| D-3 (Decision-path D) | Skip gate-run | Loses regression protection vs `main`-drift |
| D-4 (test assertions) | Status-line only | Too permissive; detection signal is load-bearing |
| D-4 (test assertions) | Full body multi-line regex | Brittle to cosmetic edits |
| D-4 (test assertions) | Pin in §0-consolidated mandate | Wrong scope — back-fill is §6-specific |
| D-5 (keep line 1122 prose) | Soften prose to "may carry …" | Adds tokens; new clause already handles exception |
| D-5 (keep line 1122 prose) | Drop the prose entirely | Loses default-case signal for non-back-fill PRs |
| D-6 (status line wording) | "Static-verification-only" (Linear issue's example) | Less precise (describes negation, not what happened) |
| D-6 (status line wording) | Joined "Back-fill (static-verification-only)" | Doubles prefix, loses brevity |

## Persona review

Per the brainstorm-stage Completion checklist, six personas run in
order: design → security → scope → coherence → product → feasibility.
Each persona's verdict + findings recorded below; iteration ran once
(no P0s surfaced).

### Persona 1: design — PASS

Findings:
- D-2's detection clause adds ~10 lines between line 1123 and 1125 of
  §6. The position is correct: after the branch-description prose (so
  the agent reads default-case first) and before "Authoritative test
  manifest" (so the back-fill carve-out is established before the
  budget rules). Pattern-consistent with the §4 (UI Agent)
  precondition block at `AGENT_PROMPTS.md:771-778` which similarly
  places a verification gate before the main task body.
- D-3's Decision-path D mirrors the structure of paths A/B/C: an
  identified-case headline + bulleted body + canonical status line +
  exit. The structural symmetry preserves operator pattern-matching
  during audit. Verified by reading paths A/B/C at lines 1209-1238.
- D-4's three single-token assertions follow the same pattern as the
  existing §2 ENG-97 assertions at `bin/agent-prompts-content-test.sh:120-150`
  (one assertion per load-bearing token, each with a `nope`-message
  that explains the failure mode). Pattern-consistent.

No P0/P1 findings.

### Persona 2: security — PASS

Findings:
- No secrets touched. No env-var fallback patterns (`${VAR:-X}`)
  introduced — the detection clause uses `git diff … | grep -vE
  '^docs/'`, no env-var references.
- The detection command is read-only (`git diff --name-only`); does
  not modify the worktree or the index.
- The brainstorm-spec ↔ in-tree-code verification uses Read + Grep
  (read-only); no execution-side-effects.
- The new clause does not bypass any existing security gate
  (scope-check, secret-probe-lint, pre-commit hook). Decision-path D
  still runs the build & test gates section of the profile, which is
  where the secret-probe-lint sits for the harness target.

No P0/P1 findings.

### Persona 3: scope — PASS

Findings:
- Two files changed (`AGENT_PROMPTS.md`, `bin/agent-prompts-content-test.sh`),
  matching the Linear issue's Scope clause exactly ("AGENT_PROMPTS.md
  §6 prompt edit only (no `bin/` code change). One pinning content-
  test in `bin/agent-prompts-content-test.sh` to prevent regression
  of the back-fill clause.").
- `bin/dispatch.sh`, `bin/run-stage.sh`, `bin/poll.sh`, `bin/verdict-handler.sh`
  are explicitly out of scope (§10).
- `learned-rules/harness/qa.md` is out of scope (§10, OQ-6).
- The detection-clause + Decision-path D pair are the minimum
  feature surface that satisfies "Fix shape A" from the Linear
  issue.
- Two slight scope expansions vs the literal Linear text:
  (a) D-3's "verify brainstorm spec ↔ in-tree code" check is
  implicit in the issue's "confirm in-tree code matches the
  brainstorm spec via Read+Grep" line — explicitly named in §3 of
  the issue under Fix Shape A. Not a scope expansion.
  (b) D-6's "Back-fill verified" status line departs from the
  issue's example "Static-verification-only". Justified in D-6 as
  a vocabulary choice within the issue's existing latitude
  ("emit canonical status line `Static-verification-only · …`"
  reads as an EXAMPLE not a contract; the goal is "canonical
  status line", which D-6 delivers). Operator can request a
  rename during persona review if they prefer the original.

No P0/P1 findings.

### Persona 4: coherence — PASS

Findings:
- The clause is internally coherent with §6's existing structure:
  branch description (D-5, unchanged) → branch-shape detection (new,
  D-2) → authoritative test manifest (unchanged) → new-code-path
  definition (unchanged) → §1-7 task body (unchanged) → quality gates
  (unchanged) → Decision paths A/B/C (unchanged) + D (new, D-3) →
  Output (unchanged) → verdict marker (unchanged).
- Coherent with §0 (Common rules): the new clause does NOT bypass
  the overwrite-on-every-dispatch contract for the stage summary file
  (path D's body explicitly writes the stage summary file with the
  Back-fill-verified status line). Verified by reading §0 contract
  per the §0 fenced-block extracts pinned at
  `bin/agent-prompts-content-test.sh:336-388`.
- Coherent with the orchestrator: path D's exit is
  `verdict pass --stage qa`, identical to path C; the orchestrator
  cannot distinguish path C from path D and does not need to (A-24).
- Coherent with ENG-79 (the source incident): ENG-79's QA agent on
  its second dispatch took a workaround that this brainstorm
  codifies. ENG-79 advanced to `stage:building` on `verdict pass`;
  the new path D produces the same outcome more efficiently.

No P0/P1 findings.

### Persona 5: product — PASS

Findings:
- The user-visible outcome is improved twice:
  (a) Operators triaging `completion/qa/ENG-N` Linear comments will
  see a canonical "Back-fill verified" status line, distinguishable
  from "All gates green" at a glance. Today the back-fill case
  produces a non-canonical "static-verification-only" line which
  doesn't grep-match either canonical line.
  (b) Per-dispatch cost on back-fill PRs drops modestly: the agent
  no longer spends reasoning budget rediscovering the workaround
  (~3-4 minutes of agent budget per the ENG-79 second dispatch).
  Estimated savings: $1-2 per back-fill QA dispatch (savings
  bounded by adversarial-budget tokens not spent). Over many
  back-fills, this is measurable.
- The Tauri-target operator is no worse off — the back-fill case is
  stack-agnostic; the detection regex `^docs/` applies to both
  targets per A-31.
- Prompt-token cost: ~38 lines added to §6 (~10 detection + ~28
  Decision-path D). Over thousands of dispatches, this is a real
  but bounded cost. Net win on back-fill dispatches; small flat
  cost on non-back-fill dispatches. Acceptable per the load-bearing
  tradeoff documented in §1.

No P0/P1 findings.

### Persona 6: feasibility — PASS (zero P0)

Codebase-fact verification pass (the gating check per the
brainstorm checklist):

- **`AGENT_PROMPTS.md:1108`, `:1110`, `:1122-1123`, `:1131-1144`,
  `:1170-1183`, `:1200-1205`, `:1207-1238`, `:1232`, `:1247-1267`,
  `:1268`** — every cited line was read directly in this dispatch;
  quoted excerpts in §11 A-1 through A-9.
- **`bin/render-prompt.sh:111-112`** (the column-0 fence-count
  contract) — read directly (A-10). §6 keeps 2 column-0 fences
  because all inserts are inside the fenced block.
- **`bin/render-prompt.sh:184-210`** (`append_project_profile`) —
  read directly (A-16). QA is not `retrospective`, so the profile
  addendum IS appended on every QA dispatch.
- **`bin/agent-prompts-content-test.sh:20-32`** (`section_body`
  helper) — read directly (A-11). Used by the new D-4 assertion
  block.
- **`learned-rules/harness/project-profile.md::## Tool allowlist`
  stage-agnostic core preface** — read directly (A-13). `git diff`
  is in the implicit `git family`.
- **`bin/run-local-helpers.sh:535-577`** (`partition_dirty_paths`
  D-004) — read directly (A-20). The brainstorm filename
  `2026-05-14-eng-82-…-design.md` contains `eng-82` lowercase, so
  it bucks in-scope.
- **`docs/architecture.md:288-307`** (Failure taxonomy) — read
  directly (A-23). No new exit code needed; Decision-path D exits
  0 like path C.
- **`/Users/rajatgoyal/.local/state/twinning-harness/harness/
  qa-monitoring-2026-05-08.md:108-118`, `:260-262`** — read
  directly (A-14). Source incident verified.
- **`docs/brainstorms/2026-05-08-eng-79-…:590-609`** — read directly
  (A-15). ENG-79's brainstorm names the back-fill case explicitly.
- **`learned-rules/harness/` listing** — `ls` returned `build.md
  project-profile.md` (A-29). No existing `qa.md` to conflict with.
- **`bin/render-prompt.sh::STAGE_TO_SECTION`** — read (A-21). The
  section name `## 6. QA Agent` is the key; inserts inside the
  section body don't change the key.

The detection-command regex `^docs/` was test-rehearsed mentally
against the ENG-79 worktree state: branch HEAD `78d05c0` carries
brainstorm + plan docs (both under `docs/brainstorms/` and
`docs/plans/`); `git diff main..HEAD --name-only` would emit lines
matching `^docs/`. Detection fires "back-fill"; path D runs;
brainstorm-spec ↔ in-tree-code check reads
`bin/render-prompt.sh:212-226` (the file the brainstorm names as
the fix site) and confirms the `feat/` not `feature/` shape;
canonical status line emitted; verdict pass advances to building.
Matches the actual ENG-79 outcome from `qa-monitoring-2026-05-08.md:130-136`.

The §6 fence-count post-edit was test-rehearsed: the existing fences
at lines 1110 and 1268 wrap the entire §6 body. All inserts (D-2 ~10
lines after line 1123, D-3 ~28 lines after line 1221) go INSIDE the
fenced block; the column-0 fence count after edit is still exactly 2
at the new line positions (~1110 + ~1306). `bin/render-prompt-test.sh`
will pass unchanged.

Zero P0 findings. Brainstorm proceeds to planning.

## 14. Summary

One detection clause and one new Decision-path D in `AGENT_PROMPTS.md`
§6 codify the back-fill case (branch HEAD docs-only vs main). One
content-test assertion block in `bin/agent-prompts-content-test.sh`
pins the load-bearing tokens against silent regression. No
orchestrator-side change. No new exit code. No new Linear label.
Resolves the contract drift the QA agent rediscovered on ENG-79's
2026-05-08 dispatch, makes back-fill QA dispatches faster and
cheaper, and produces a canonical status line distinguishable in
audit grep.
