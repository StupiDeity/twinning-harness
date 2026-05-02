---
linear: ENG-52
title: Tauri-assumption residue cleanup (post-ENG-49)
date: 2026-05-02
status: draft
---

# Tauri-assumption residue cleanup (post-ENG-49)

## 1. Overview

ENG-49 productionized the harness for any target stack (moved PR creation
into the orchestrator, made stage I/O profile-driven). ENG-50 reframed
the review stage. The core mechanisms are now stack-agnostic. What
remains is **documentation and example drift** — surface text that still
reads Tauri-coupled even though the underlying logic is generic, plus
two stale comments that point at a CI workflow path the harness no
longer uses.

This ticket is *cosmetic residue* (Severity-B/C/D/E in the audit). No
behavior changes. The implementation is a series of edits across one
markdown file (`AGENT_PROMPTS.md`) and three bash scripts
(`bin/on-new-release.sh`, `bin/run-release-observer.sh`, plus
`bin/agent-prompts-content-test.sh` to lock in the invariants).

The load-bearing tradeoff: every example we add to the prompt is a
permanent prompt-token cost on every dispatch. We add exactly one second
api-contract example (Python/REST), not three; we reorder the
config-file scan list rather than expanding it.

## 2. Goal

After this ticket lands:

- A stack-agnostic reader of the prompts can no longer infer "this
  pipeline only knows Tauri" from any Severity-B/C surface called out
  in the issue.
- The two stale "invoked by `pipeline-release.yml`" comments
  (`bin/on-new-release.sh:3`, `bin/run-release-observer.sh:5`) point at
  the actual local invocation site (`bin/run-local.sh:379` →
  `bin/on-new-release.sh` → `bin/run-release-observer.sh`).
- The §7 build prompt's `gh run list --workflow release.yml` line is
  scoped to "if the project profile names a release workflow" so a
  non-Tauri target without a CI release workflow does not read the
  step as mandatory.
- `bin/on-new-release.sh`'s sweep is documented in-script as the
  safety-net for issues that did not transition through the build
  agent's `pipeline-stage-summary: building` marker (the verdict-handler
  primary path).
- `learned-rules/twinning/` has an explicit explanation of its role
  (multi-target slug catalog) so a future operator does not delete it
  thinking it is dead Tauri residue.
- `bin/agent-prompts-content-test.sh` carries new assertions that lock
  the most regression-prone of the above invariants in place.

## 3. Architectural principle

This work extends the principle ENG-49 established —
*orchestrator-as-source-of-truth* — to the **prompt and comment surface**:
documentation strings should attribute work to the actual current owner
of that work, not to historical owners that were rotated out. The
mechanism (verdict-handler owns transitions, run-local.sh owns the
release watcher, profile addendum owns stack vocabulary) is already in
place. This ticket removes the residual prose that contradicts it.

There is no ARCHITECTURE.md or VISION.md in the harness repo (verified:
`ls docs/` returns only `brainstorms/  plans/  runbooks/`). The
governing constraints come from CLAUDE.md and from the
`learned-rules/harness/project-profile.md` Stack/Don'ts sections, both
of which are silent on prompt-content tone. The principle this brainstorm
invokes is therefore an *extension* of ENG-49's, not a re-statement of
an existing one.

## 4. Decisions

Each decision below has the form **D-N: \<verdict\>** plus a "Why" line
that names the constraint or principle motivating it, plus the rejected
alternative(s).

### D-1: Add ONE second api-contract example (Python/Flask), not multiple

**Verdict:** In `AGENT_PROMPTS.md §2 Plan` (line 388), keep the existing
Tauri block as the first illustrative example and add a second
Python/Flask handler + TypeScript client snippet **embedded inside the
existing single ```api-contract``` fenced block** (NOT as a new sibling
fence — that would raise the column-0 fence count from 2 to 4 in §2 and
trip `render-prompt.sh`'s exact-2 fence-count contract; see
CLAUDE.md:131–141 and Edge Cases below). Concretely: keep the existing
Tauri sub-section, append a horizontal rule (`# ---`) inside the same
fence, then a second sub-section labelled `# Example 2 — Python/Flask
+ TypeScript client (illustrative for an HTTP-handler stack)` with the
Python `@app.route` handler signature, return-type schema, and a
TypeScript type alias. Tag the api-contract intro line (currently line
388) as "illustrative for two stacks (compiled-IPC and HTTP-handler);
adapt to your project profile."

**Why:** The Linear issue acceptance criterion #1 explicitly requires "a
second non-Tauri illustrative example (e.g., Python or Go REST), with
the existing Tauri example preserved." Adding *one* second example
balances the prompt without inflating prompt tokens — every line of
AGENT_PROMPTS.md is replayed on every dispatch (~9 stages × ticks). A
second stack covers the dichotomy (compiled-IPC vs. HTTP-handler);
adding a third (Go) doesn't add new information.

**Rejected alternative — multiple stack examples (3+).** Each additional
example adds ~15 prompt lines and risks reader fatigue without buying
discrimination beyond the IPC-vs-HTTP-handler split. The dispatched
agent already reads the project profile; the example's job is to
illustrate the SHAPE of an api-contract block, not to be exhaustive.
Rejected.

**Rejected alternative — drop the Tauri example, replace with abstract
pseudocode.** The Tauri example is concrete and tested; abstract
pseudocode would force every reader to do their own concretization. The
issue explicitly calls out "with the existing Tauri example preserved."
Rejected.

**Rejected alternative — drop the second concrete example entirely;
just amend the prose ("here are illustrative shapes for various stacks
— see the project profile addendum for yours").** Cheapest in prompt
tokens. Rejected because the issue's framing of the bias ("the api-
contract example is Tauri-only") is corrected by *seeing* a second
concrete shape, not by being told one would exist if the reader knew
their stack. The dispatched plan agent has the profile addendum but the
*reader* of AGENT_PROMPTS.md (operators, retrospective agent, future
edits) does not — the second concrete example serves that human reader.

### D-2: Reorder §7's config-file scan list, not expand it

**Verdict:** In `AGENT_PROMPTS.md §7 Build` line 1202, change the
list `tauri.conf.json, next.config.js, Caddyfile, nginx.conf` to a more
neutral ordering with a leading "examples include" qualifier. Concretely:
`(e.g. \`next.config.js\`, \`Caddyfile\`, \`nginx.conf\`,
\`tauri.conf.json\`, \`pyproject.toml\`, \`go.mod\`)`. Web-server configs
first, language-package manifests second, Tauri last. Add `pyproject.toml`
and `go.mod` so Python and Go targets see themselves represented.

**Why:** Same prompt-token-cost constraint as D-1 — list reorder + 2 new
items is a 0-line add (the change fits on the existing line). Reordering
+ adding two items removes the Tauri-default impression at zero token
cost. Aligns with the project-profile-driven mechanism already established.

**Rejected alternative — split into a structured table per language.**
Over-engineering for a list that is already qualified ("scan for new
hosts, new bundle identifiers, changed security policies"). The
mechanism reads the profile's File layout for *which* configs exist;
the prompt list is hint-only. Rejected.

### D-3: Make §7's `release.yml` post-merge check profile-conditional

**Verdict:** In `AGENT_PROMPTS.md §7 Build` lines 1223–1225, rephrase the
`gh run list --branch main --workflow release.yml --limit 1` step as:

> If the project profile names a release CI workflow (e.g.
> `release.yml`, `release.yaml`), invoke `gh run list --branch main
> --workflow <workflow-file> --limit 1` to confirm the release workflow
> picked up the merge. **Skip this step if the profile names no release
> workflow** — in that case the orchestrator's release watcher
> (`bin/run-local.sh:379` → `bin/on-new-release.sh`) is the
> release-detection path and the post-merge CI watch on the
> immediately-prior step is sufficient.

**Why:** Acceptance criterion #3. The current line treats `release.yml`
as universal. For the harness-self target there is NO release CI
workflow at all (the harness has no compiled artifact —
`learned-rules/harness/project-profile.md:12,16`); the agent would post
`pipeline-metric: release_trigger_missing` on every harness-self merge.
Profile-conditional phrasing prevents the false-positive.

**Rejected alternative — drop the post-merge release-workflow check
entirely.** It is genuinely useful for stacks that DO have a release CI
workflow (twinning has `.github/workflows/release.yml` per
`learned-rules/twinning/project-profile.md:12`). Dropping it would make
release-trigger failures silent on those stacks. Rejected.

**Rejected alternative — read the workflow filename from the project
profile addendum at render time and substitute it via
`render-prompt.sh`.** Pulls `render-prompt.sh` into a parsing role
(extracting "release workflow file" from a free-form profile blob) that
it currently does not have. Larger blast radius than the issue calls
for. Rejected for this ticket; flagged in §10 Out-of-scope.

### D-4: Update §8's "Inputs supplied by `pipeline-release.yml`" attribution

**Verdict:** In `AGENT_PROMPTS.md §8 Release` line 1303, replace the
prose `Inputs supplied by` `pipeline-release.yml`:` with `Inputs
supplied by` `bin/run-release-observer.sh` `(env vars):` and rename the
listed inputs to their actual env-var names:

```
- `PIPELINE_RELEASE_VERSION` — semantic-release version (e.g. `1.19.4`).
- `PIPELINE_RELEASE_TAG` — git tag (e.g. `v1.19.4`).
- `PIPELINE_RELEASE_PREV_TAG` — previous tag (auto-resolved if empty).
```

**Why:** Acceptance criterion #2. Verified at
`bin/run-release-observer.sh:21–23` — those are the literal env-var
names exported before the `dispatch.sh` call. Aligning the prompt's
input names to the code's exported names lets a debugging operator grep
both directions.

**Rejected alternative — leave as-is and add a parenthetical note.**
Wastes prompt tokens to apologize for stale prose. Rejected.

### D-5: Document `on-new-release.sh::Part 1` as the safety-net for the verdict-handler primary path (do not remove it)

**Verdict:** Keep the sweep in `bin/on-new-release.sh:25–54`. Update its
in-script comment to read:

```bash
# ─── Part 1: sweep stage:building → stage:released (safety net) ─────
# Primary path: when the build agent posts <!-- pipeline-stage-summary:
# building -->, verdict-handler.sh::apply_transition advances the issue
# to stage:released and flips Linear native-state to Done (see
# bin/verdict-handler.sh:159-167). This sweep is the SAFETY NET for
# issues that didn't transition that way — for example, a build-agent
# crash that left the issue stuck at stage:building, or a manually-
# moved issue that bypassed the agent. In the happy path this loop
# finds no issues and is a no-op.
```

**Why:** Acceptance criterion #4 lists "reconcile" or "document" as the
two options. Reconciling would require either (a) deleting the sweep
(losing the safety net for stuck issues) or (b) merging it into
verdict-handler (cross-cutting refactor with no behavior win). The
two paths are triggered by different events — the agent's marker fires
synchronously in the per-tick run-stage flow, the sweep fires when
`gh release list` shows a new tag in the periodic release-watcher pass.
That is intentional defense in depth. Documentation, not consolidation,
is the right answer for cosmetic residue.

**Rejected alternative — delete the sweep, rely on verdict-handler
exclusively.** A build-agent crash mid-dispatch leaves issues stuck at
`stage:building` with no marker; the sweep catches them on the next
release cut. Removing it eliminates the safety net for the
exact case (agent crashes) where the safety net matters most. Rejected.

**Rejected alternative — fold the sweep into verdict-handler.** The
sweep is triggered by an external event (semantic-release tag), not by
a stage-completion marker. verdict-handler is per-issue per-tick;
on-new-release sweeps cross-issue per-release. Different cadences,
different inputs, different ownership. Forcing them into one function
would obscure the safety-net role rather than clarify it. Rejected.

### D-6: Update `run-release-observer.sh:5` docstring to point at the local invocation site

**Verdict:** Replace the line `# Invoked by .github/workflows/pipeline-release.yml AFTER the stage:building→released sweep.` with `# Invoked by bin/on-new-release.sh (which itself is invoked by bin/run-local.sh's release watcher) AFTER the stage:building→released sweep.`

**Why:** Acceptance criterion #5. Verified at
`bin/run-local.sh:365–388` (release watcher) and `bin/on-new-release.sh:60`
(sweep then observer). The current docstring points at a CI workflow
path that no longer exists in this repo — `find … -name pipeline-release.yml`
returns nothing under `.github/workflows/` for the harness.

**Rejected alternative — delete the line entirely.** A docstring with a
stale reference is misleading; a docstring with the current invocation
chain is a navigation aid for the next operator. Replacing is cheaper
than deleting + leaving the file headless. Rejected.

### D-7: Document `learned-rules/twinning/` as a multi-target slug catalog (Option C); do not move or delete

**Verdict:** Add a `learned-rules/README.md` (~12 lines) explaining that
each subdirectory under `learned-rules/` is keyed by `PROJECT_SLUG`
(set in the target's `.pipeline-config/config.json`) and that the
existing `harness/` and `twinning/` subdirs are the two slugs whose
operators consume this repo. Cite `bin/render-prompt.sh:141,214` as
the resolution site.

**Why:** Acceptance criterion #6 names three options (drop, move,
document) and asks for a decision. The existing structure is
load-bearing — `bin/render-prompt.sh:214` resolves
`$HARNESS_ROOT/learned-rules/$PROJECT_SLUG` directly. Dropping
`learned-rules/twinning/` would break twinning-target dispatches the
moment a twinning operator pulls a fresh harness checkout (the
retrospective agent's accumulated rules disappear). Moving to
`target-profiles/` would require updating `render-prompt.sh:141,214`,
the retrospective agent's rule-write path, and any tests that hardcode
`learned-rules/<slug>/` — out of proportion to the documentation
benefit. Adding a one-page README is the lowest-touch option that
removes "is this dead code?" ambiguity.

**Rejected alternative — drop `learned-rules/twinning/` entirely.**
Breaks the twinning-target dispatch path; the retrospective agent's
accumulated rules are non-recoverable from git history (they evolved
through PRs). Operator may not know to re-seed them. Rejected.

**Rejected alternative — move to `target-profiles/<slug>/`.**
Cross-cutting rename across `render-prompt.sh`, the retrospective
agent's PR-write path, and any tests that touch the dir literal.
Behavior change disguised as a doc cleanup. Rejected.

### D-8: Lock the §2/§7/§8 invariants into `agent-prompts-content-test.sh`

**Verdict:** Append four new assertions to
`bin/agent-prompts-content-test.sh`:

1. `§2 contains BOTH a Tauri AND a non-Tauri api-contract example.`
   Asserted as TWO sub-checks: (a) §2's body contains the existing
   `#[tauri::command]` token (locks Tauri-preservation per AC1's
   second clause) AND (b) §2's body contains `@app.route` (Python/Flask
   sentinel for the new example). Both must pass; either failing fails
   the test. This guards against a future edit that drops the Tauri
   example while satisfying the "non-Tauri example present" letter of
   AC1 but not its spirit.
2. `§7 release.yml check is profile-conditional.` Asserted as: §7's
   body containing the `gh run list --branch main --workflow` token
   ALSO contains the literal phrase `if the project profile names a
   release CI workflow`.
3. `§8 attributes inputs to bin/run-release-observer.sh.` Asserted as:
   §8's body contains the literal token `bin/run-release-observer.sh`
   AND the env-var name `PIPELINE_RELEASE_VERSION` AND does NOT
   contain the obsolete phrase `Inputs supplied by` followed by
   `pipeline-release.yml`.
4. `§8 lacks bare \`pipeline-release.yml\` attribution for inputs.`
   Asserted as: §8 body lacks the sub-string `pipeline-release.yml\`:`
   (the colon after the backtick is the giveaway of input-attribution
   prose, distinguishing from the existing test that asserts §8 lacks
   `pipeline-release.yml sweep`).

**Why:** The existing test file
(`bin/agent-prompts-content-test.sh:69–73`) already locks the §8
"sweep" attribution — that pattern is reusable. Without test-locked
invariants, the next retrospective-agent PR or human edit can silently
revert these changes. The harness convention is "every reflexive
invariant gets a `*-test.sh`" (`CLAUDE.md:100–129`).

**Rejected alternative — no test, rely on code review.** The whole
class of fixes is one round of code review away from regression.
History (`bin/agent-prompts-content-test.sh:1–4` — "ENG-49: Invariants
on AGENT_PROMPTS.md content … future edits must preserve") shows the
team has already chosen test-locked invariants for this exact file.
Rejected.

### D-9: Severity-D Tauri comments — defer

**Verdict:** Do NOT touch:
- `bin/scope-check.sh:21` (comment listing `crates`, `src-tauri`, `src` as path examples)
- `AGENT_PROMPTS.md §9 line 1482` (`src-tauri/src/` in the human-override-analysis path glob)
- `AGENT_PROMPTS.md §9 line 1506–1507` ("cargo cult" wording)

**Why:** The Linear issue marks Surface 4 as a "judgment call" and the
"cargo cult" reference is the English idiom (cargo-cult programming),
not the Cargo (Rust) tool — verified at `AGENT_PROMPTS.md:1505–1507`
where the surrounding context is "any knowledge entry with ≥3 renewals
in its history and no new citations → flag for human review as
potential cargo cult." Removing it would weaken the metaphor without
removing any Tauri assumption. The §9 path glob (`src-tauri/src/`) is
genuinely Tauri-specific and warrants either profile-aware path
extraction (out of proportion for §9 retrospective-agent code) or no
change. The `bin/scope-check.sh:21` comment is documenting actual
historical examples and is harmless. Defer all three to the
profile-extraction followup tracked in §10.

**Rejected alternative — drop them with a regex sweep.** Risk of
collateral edits in surrounding logic, no behavior win, and the
"cargo cult" case is a true-positive false-positive. Rejected.

**Rejected alternative — fix all three with profile-aware paths.**
Out-of-scope for a Severity-D cosmetic ticket. Rejected.

## 5. Architecture (where code goes)

Edits live in five files; no new files except the README:

| File | What changes | Decision |
|---|---|---|
| `AGENT_PROMPTS.md` (§2 ~line 388) | append second `api-contract` example block | D-1 |
| `AGENT_PROMPTS.md` (§7 line 1202) | reorder + extend config-scan list | D-2 |
| `AGENT_PROMPTS.md` (§7 lines 1223–1225) | profile-conditional release-workflow check | D-3 |
| `AGENT_PROMPTS.md` (§8 line 1303–1306) | re-attribute inputs to `bin/run-release-observer.sh` (env vars) | D-4 |
| `bin/on-new-release.sh` (lines 25–29) | rewrite Part-1 comment as safety-net documentation | D-5 |
| `bin/run-release-observer.sh` (line 5) | update invocation-site docstring | D-6 |
| `learned-rules/README.md` (NEW, ~12 lines) | document slug-keyed multi-target convention | D-7 |
| `bin/agent-prompts-content-test.sh` (append) | four new content-invariant assertions | D-8 |

No bash function signatures change. No `dispatch.sh::allowed_tools_for`
case changes. No `verdict-handler.sh` flow changes. No
`render-prompt.sh::STAGE_TO_SECTION` changes. The surface area is
purely additive (one new README, four test assertions) and string-level
edits in existing prose.

## 6. Data flow

There is no runtime data flow change. The doc describes a sequence of
text edits, not a feature.

For verification: a manual `PIPELINE_DRY_RUN=1 TARGET_REPO=…
bash bin/render-prompt.sh build` (after the AGENT_PROMPTS.md edits)
should emit the new prose verbatim — `render-prompt.sh:217` does literal
substitution on `{learned_rules_dir}` etc. and does not re-flow content.

## 7. Error handling

- If the new `agent-prompts-content-test.sh` assertions fail in CI (or
  in the local `bash bin/agent-prompts-content-test.sh` invocation),
  the ENG-52 implement stage stops. Standard test-failure flow.
- If a future edit reverts the §2 second example, assertion D-8.1
  fires.
- If a future retrospective-agent PR drops the literal phrase "if the
  project profile names a release CI workflow", assertion D-8.2 fires.
- All other failure modes are existing behaviors of the modified files;
  this ticket touches none of them.

## 8. Edge cases

| Case | Behavior |
|---|---|
| The Python/Flask example block accidentally adds a third column-0 \`\`\` fence to §2 | `render-prompt.sh` will die — fence count must be exactly 2. **Mitigation:** the new example is fenced as ```api-contract``` (a non-empty info-string) and the existing Tauri example uses the same form, so both render as one logical block to most parsers, BUT `render-prompt.sh` counts column-0 \`\`\` lines literally regardless of info-string. The new example MUST be embedded INSIDE the existing fence (i.e., a single ```api-contract``` block containing both backend examples concatenated) to avoid raising the fence count. Locked by `bin/render-prompt-test.sh` (existing). |
| `bin/agent-prompts-content-test.sh` PASS count drifts | Existing pattern: each assertion increments PASS or FAIL counters, prints OK/FAIL, exits non-zero on any FAIL (lines 12–14). Four new assertions add four to PASS in the green path. |
| Operator deletes `learned-rules/twinning/` after reading the README and deciding they don't drive the twinning target | No harm — `bin/render-prompt.sh:141` reads `$HARNESS_ROOT/learned-rules/$PROJECT_SLUG/project-profile.md` for the active slug only; a missing `twinning/` directory affects nothing as long as `PROJECT_SLUG=harness`. Operator deleting their *own* slug is a self-inflicted wound, not addressed by this ticket. |
| Profile addendum names a release workflow but file does not exist | `gh run list --workflow <name>` returns empty; build agent already handles "no run found within 2 minutes → escalate" path (`AGENT_PROMPTS.md:1224–1226`). No new code required. |
| `bin/on-new-release.sh::Part 1` documentation drift after a future ENG-N changes the verdict-handler path | The README + comment cross-references explicit line numbers. Test invariant D-8 does NOT lock the comment text; it locks the AGENT_PROMPTS.md side. A drift between code and doc is a soft signal handled by future retrospectives. |

## 9. Persona review

Six personas dispatched in two parallel batches; gate cleared on
iteration 1 (6/6 PASS, 0 P0 findings). Iteration-1 P1 findings have
been folded back into the brainstorm in this revision (D-1 verdict text
made consistent with the Edge-Cases fence-count constraint; D-8.1
expanded to assert Tauri-preservation as well as Python presence; a
third rejected alternative added to D-1 covering the prose-only
option; AC7-vs-issue-AC-count and bash-docstring-vs-test-coverage
clarified in §11 preamble).

### Persona: design — PASS (0 P0, 2 P1)
- P1: D-1's "embed inside existing fence" mitigation pushes against the
  one-fence-per-stack convention. Folded: D-1 verdict text now spells
  out the embed-inside contract explicitly with the horizontal-rule
  separator inside the fence, so the reader sees the constraint up
  front rather than discovering it in Edge Cases.
- P1: `learned-rules/README.md` placement is a non-rule file inside the
  rules-resolution tree. Acceptable: the README filename does not match
  any `<slug>/` pattern and `bin/render-prompt.sh:141` reads only
  `$PROJECT_SLUG/project-profile.md` literal paths. No code surprise.

### Persona: security — PASS (0 P0, 0 P1)
- No findings. The proposed edits are doc/comment changes plus four
  test assertions; no new bash invocations, no env-var handling, no
  argument-passing surface that would touch the ENG-46 secret-handling
  rules.

### Persona: scope — PASS (0 P0, 2 P1)
- P1: AC count discrepancy (issue says 6, brainstorm has 7). Folded:
  §11 preamble now states AC7 is a verification-gate AC the issue does
  not enumerate but that the harness convention requires.
- P1: D-8.4 is one assertion past minimum (the obsolete-phrase
  negative-assertion). Acknowledged: this is the same defensive pattern
  as the existing `bin/agent-prompts-content-test.sh:69–73` lock and is
  proportionate to "tests are the regression backstop for prompt edits"
  per the file's existing convention.

### Persona: coherence — PASS (0 P0, 2 P1)
- P1: AC1 verifies §2 *preserves* the Tauri example but D-8.1 only
  asserted the Python sentinel. Folded: D-8.1 split into two sub-checks
  (Tauri-preservation + Python-presence), both required to pass.
- P1: §1 Overview said "lock the invariants" without qualifying that
  bash-docstring text is not test-locked. Folded: §11 preamble now
  states AC4/AC5 are intentionally manual-review verified.

### Persona: product — PASS (0 P0, 1 P1)
- P1: D-1 missing the "drop the second concrete example, just amend
  prose" rejected-alternative. Folded: third rejected alternative added
  to D-1 covering the prose-only option, with rationale (the human
  reader of AGENT_PROMPTS.md is who the second example serves; the
  dispatched agent has the profile addendum, the human reader does not).

### Persona: feasibility — PASS (0 P0, 1 P1; gating)
- P1: D-1 verdict text said "append a second fenced block" while Edge
  Cases corrected to "embed inside" — internal inconsistency in the
  same document. Folded: D-1 verdict rewritten to specify the
  embed-inside contract up front. Verified codebase facts (all 16+
  citations) all matched; no codebase-fact errors.

**Status:** Personas: 6/6 PASS · gate P0: 0 · proceeding to planning.

## 10. Open questions / out of scope

1. **Profile-aware path extraction in §9 retrospective.** Replacing
   the hardcoded `src-tauri/src/` glob in
   `AGENT_PROMPTS.md §9 line 1482` with a profile-aware code-path glob
   is genuinely useful but requires either a new `code_paths` field on
   the project profile addendum or a parser that extracts code-bearing
   directories from the existing File layout section. Out of scope for
   ENG-52 (cosmetic). Followup ticket.
2. **`render-prompt.sh` reading a structured field from the profile.**
   D-3's profile-conditional release-workflow phrasing relies on the
   AGENT to read the addendum and decide; an alternative is for
   `render-prompt.sh` to extract a `release.workflow_file` token from
   the profile and substitute `{release_workflow_file}` into the
   prompt. Cleaner but pulls render-prompt into a parsing role it
   currently does not have. Followup ticket.
3. **Should the project profile schema gain a `release.workflow_file`
   field?** Same root question as #2. The discovery agent's
   `bin/setup-prompts/discovery.md` would need to elicit it. Followup.
4. **Documenting harness-self vs. cross-target operator workflows.**
   The README in D-7 documents the slug-keyed convention but does not
   document the broader question "what is harness-self vs target-of-
   harness?" That is broader than ENG-52. Followup.
5. **Severity-D Tauri comments (D-9 deferred).** Tracked here so a
   future Severity-D-cleanup ticket has a starting point.

## 11. Acceptance criteria

The Linear issue lists 6 acceptance criteria (AC1–AC6). The brainstorm
table below adds AC7 ("test invariants pass") as a verification gate
the issue does not enumerate but that the harness convention requires
(per `bin/agent-prompts-content-test.sh:1–4` — "future edits must
preserve" the locked invariants). AC4 and AC5 are intentionally
verified by manual review rather than by automated assertion: the
edits live in bash docstrings (not the AGENT_PROMPTS.md surface the
existing test framework covers) and adding a bash-docstring-content
test would be disproportionate to a Severity-D cosmetic fix.


| AC | Verifies | Verification |
|---|---|---|
| AC1 | §2 has a second non-Tauri api-contract example, Tauri example preserved | `bin/agent-prompts-content-test.sh` D-8.1 (both sub-checks) |
| AC2 | §8's "Inputs supplied by" attributes to `bin/run-release-observer.sh` | `bin/agent-prompts-content-test.sh` D-8.3 + D-8.4 |
| AC3 | §7's `release.yml` check is profile-conditional | `bin/agent-prompts-content-test.sh` D-8.2 |
| AC4 | `bin/on-new-release.sh::Part 1` documents the safety-net role + cross-references verdict-handler | manual review of `bin/on-new-release.sh:25–54` after edit |
| AC5 | `bin/run-release-observer.sh:5` docstring points at `bin/on-new-release.sh` (and run-local.sh upstream) | manual review of `bin/run-release-observer.sh:5` after edit |
| AC6 | `learned-rules/twinning/` is documented (not dropped, not moved) via `learned-rules/README.md` | `learned-rules/README.md` exists and references both `harness/` and `twinning/` |
| AC7 | `bin/agent-prompts-content-test.sh` passes with the four new assertions | `bash bin/agent-prompts-content-test.sh` exits 0 |

## 12. Anti-bias checks

### ADR stress test

There is no `docs/knowledge/decisions.md` in the repo (verified:
`ls docs/`). No accepted ADR exists for this brainstorm to put pressure
on. The only architectural commitments to interact with are:

- ENG-49's *orchestrator-as-source-of-truth* — this ticket REINFORCES
  it (D-4, D-5, D-6 push attribution back toward the orchestrator).
- ENG-23's renaming of `REPO_ROOT`/`PIPELINE_ROOT` — this ticket
  touches none of those paths.
- ENG-51's *per-target dispatch.tools extras* — D-3 leans on the same
  profile-driven principle but does not extend the config schema; the
  prompt simply references whatever the profile says.

No ADR is destabilized.

### Simpler-alternative table

| Decision | Simpler alt | Why rejected |
|---|---|---|
| D-1 (add 1 second example) | Add 0 examples; rely on profile | Issue AC#1 explicitly requires a second example; absence is the bias being corrected |
| D-2 (reorder list) | Drop the list entirely | List is genuinely useful as a hint; reordering preserves the hint without the bias |
| D-3 (profile-conditional) | Drop the post-merge check | Genuinely useful for stacks WITH a release workflow |
| D-4 (env-var attribution) | Leave as-is + parenthetical | Wastes prompt tokens on a stale apology; rewrite is shorter |
| D-5 (document sweep) | Delete the sweep | Loses the safety net for crashed-agent stuck issues |
| D-6 (update docstring) | Delete the line | Replacing keeps a navigation aid; deleting leaves the file headless |
| D-7 (README, leave dirs alone) | Drop `learned-rules/twinning/` | Breaks twinning-target dispatch path |
| D-8 (test the invariants) | Code review only | History shows code-review-only invariants regress; ENG-49 already chose test-locked for this file |
| D-9 (defer Severity-D) | Fix Severity-D in this ticket | Out of proportion to a cosmetic ticket; one item is a non-issue (cargo-cult idiom) |

### Assumption inventory

| # | Assumption | Status | Evidence |
|---|---|---|---|
| 1 | `AGENT_PROMPTS.md §2 line 388` introduces the api-contract example block; the Tauri example occupies lines 388–405 | verified | `AGENT_PROMPTS.md:387–407` (read directly) |
| 2 | `AGENT_PROMPTS.md §7 line 1202` lists `tauri.conf.json, next.config.js, Caddyfile, nginx.conf` | verified | `AGENT_PROMPTS.md:1202` (grep + read) |
| 3 | `AGENT_PROMPTS.md §7 lines 1223–1225` contain the `gh run list --branch main --workflow release.yml` step | verified | `AGENT_PROMPTS.md:1223–1226` |
| 4 | `AGENT_PROMPTS.md §8 line 1303` reads `Inputs supplied by` `pipeline-release.yml` `:` | verified | `AGENT_PROMPTS.md:1303–1306` |
| 5 | `bin/run-release-observer.sh` exports `PIPELINE_RELEASE_VERSION`, `PIPELINE_RELEASE_TAG`, `PIPELINE_RELEASE_PREV_TAG` | verified | `bin/run-release-observer.sh:21–23` |
| 6 | `bin/run-release-observer.sh:5` docstring claims invocation by `.github/workflows/pipeline-release.yml` | verified | `bin/run-release-observer.sh:5` |
| 7 | `bin/run-local.sh:379` invokes `bin/on-new-release.sh "$latest_version" "$latest_tag"` | verified | `bin/run-local.sh:365–388` |
| 8 | `bin/on-new-release.sh:60` invokes `bin/run-release-observer.sh "$version" "$tag"` | verified | `bin/on-new-release.sh:60` |
| 9 | `bin/verdict-handler.sh::apply_transition` performs the `building → released` Linear-state transition (line 159–167) | verified | `bin/verdict-handler.sh:159–167` |
| 10 | `bin/render-prompt.sh:141` resolves `learned-rules/$PROJECT_SLUG/project-profile.md` | verified | `bin/render-prompt.sh:141` |
| 11 | `bin/render-prompt.sh:214` resolves `$HARNESS_ROOT/learned-rules/$PROJECT_SLUG` for `{learned_rules_dir}` substitution | verified | `bin/render-prompt.sh:214` |
| 12 | `bin/agent-prompts-content-test.sh:69–73` already locks the §8 "pipeline-release.yml sweep" invariant; same pattern reusable | verified | `bin/agent-prompts-content-test.sh:69–73` |
| 13 | `bin/agent-prompts-content-test.sh` uses a `section_body` awk helper to extract a single H2 section's body | verified | `bin/agent-prompts-content-test.sh:17–24` |
| 14 | `bin/reconcile.sh` accepts `linear: ENG-52` frontmatter as canonical-doc claim | verified | `bin/reconcile.sh:67–80` |
| 15 | The harness has no `.github/workflows/pipeline-release.yml` file in this repo (so the docstring is stale, not pointing at a real file) | verified | `find … -name pipeline-release.yml` returns nothing; only references are in comments and tests |
| 16 | `learned-rules/twinning/project-profile.md:12` describes the twinning target as Tauri v2 + SvelteKit and names `.github/workflows/release.yml` as the release driver | verified | `learned-rules/twinning/project-profile.md:12` |
| 17 | `learned-rules/harness/project-profile.md:12,16` describes the harness as bash-only with no compiled artifact | verified | `learned-rules/harness/project-profile.md:12,16` |
| 18 | "cargo cult" at `AGENT_PROMPTS.md:1506–1507` is the English idiom, not a Cargo (Rust) reference | verified | surrounding context: "any knowledge entry with ≥3 renewals … flag for human review as potential cargo cult" — clearly the metaphor |
| 19 | `render-prompt.sh` requires exactly two column-0 \`\`\` fences per stage block; adding a second \`\`\`api-contract\`\`\` block inside §2 would raise the fence count | verified | `CLAUDE.md:131–141` ("DO NOT add column-0 \`\`\` fences inside a stage's body") + `render-prompt.sh` fence count check |
| 20 | The §2 second api-contract example must therefore be embedded INSIDE the existing fence (one logical block, two language sub-examples), not as a sibling fence | derived from #19 | implementation contract noted in Edge Cases |

All assumptions verified. No "assumed" entries — every claim has a path:line citation in the current code.
