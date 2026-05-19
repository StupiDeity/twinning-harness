---
linear: ENG-136
date: 2026-05-19
topic: §3 review-loopback — hoist minor/nit defer rule + add hard scope ceiling
---

# ENG-136 — Plan: §3 review-loopback defer-rule hoist + scope ceiling

## 1. Goal

Restructure `AGENT_PROMPTS.md` §3's review-loopback block so the
minor/nit defer rule is hoisted into a prominent labeled precondition
block immediately above the `Reviewing summary (verbatim):` header,
and add a hard scope ceiling that makes "cheap" mechanically defined
as "fix requires zero edits to files outside the plan's File
Structure table." Pin position + content with seven new assertions in
`bin/agent-prompts-content-test.sh`.

## 2. Assumption Inventory

| # | Assumption | Status | Evidence |
|---|---|---|---|
| A1 | §3's review-loopback block is at `AGENT_PROMPTS.md:741-762` (header + 5 steps + `{review_findings}` token) | **verified** | `grep -n "Review → implement loopback handling\|Reviewing summary" AGENT_PROMPTS.md`; header at 741, `Reviewing summary (verbatim):` at 760, `{review_findings}` at 762. |
| A2 | Step 1 (line 751) carries the current defer-rule sentence `[minor] and [nit] findings are best-effort — close them when cheap, defer with a one-line rationale in the stage-summary Notes otherwise.` | **verified** | direct Read of line 751. |
| A3 | Step 5 (line 755-758) is the scope-drift restraint with the ENG-123 concrete-failure paragraph at 758; the new block must insert AFTER 758 and BEFORE 760 | **verified** | direct Read of lines 755-760. |
| A4 | §3 has exactly two column-0 ` ``` ` fences and `render-prompt.sh::extract_block` dies if a third lands. The new block is plain prose (no code blocks). | **verified** | `bin/render-prompt.sh::extract_block` enforces fence_count == 2 per stage (`bin/render-prompt.sh:94-115`). The new block's bullet examples are inline (indented one space), not fenced. |
| A5 | `bin/agent-prompts-content-test.sh:91-101` is the canonical §3 content-pin shape (`printf '%s\n' "$s3" \| grep -qF '<phrase>'`); the test extracts `$s3` once and reuses it | **verified** | direct Read. The `$s3` variable is bound at the test file's section-extraction prelude. New pins follow the same shape. |
| A6 | The `bin/agent-prompts-content-test.sh` test file uses `ok` / `nope` helpers for assertions; sentinel-block insertion goes before the `# ─── ENG-140:` block (line 103) and is paired-block siblings of other ENG-N-tagged §3 pins | **verified** | direct Read of lines 91-118. |
| A7 | The pre-commit hook runs the full `bin/*-test.sh` suite (~30s) and blocks on failure (per CLAUDE.md "Pre-commit hook") | **verified** | `.githooks/pre-commit` exists; CLAUDE.md documents the gate. |
| A8 | The hoisted block does NOT need to live inside §0's fenced common-rules block — §3's per-stage fenced block delivers it to the implementing agent only, which is the only agent that consumes `{review_findings}` | **verified** | §3 line 690 opens `## 3. Implementation Agent (Backend)`; the fenced block extends to line ~938 (one of the two column-0 fences). The new block falls inside §3's fence. |
| A9 | Branch `fix/eng-136-…` was created on 2026-05-16 and is 0 ahead / 68 behind `origin/main` after `git fetch`; manual shepherd reset the branch to `origin/main` (commit 4a7a34c) before this plan was written; no implement-agent commits exist | **verified — UNTOUCHED by plan** | `git rev-list --count origin/main..HEAD` returned 0 at plan time; `git rev-list --count HEAD..origin/main` returned 68; after `git reset --hard origin/main`, HEAD == origin/main. Plan executes against fresh main; no rebase task needed. |
| A10 | The eng-136 slug-token is present in this plan doc's basename (`2026-05-19-eng-136-implement-loopback-minor-defer-rule-hoist-and-scope-ceiling.md`), satisfying `partition_dirty_paths::D-004` in-scope bucketing for `docs/plans/` writes | **verified** | basename contains literal `eng-136`. |

**Branch-base freshness pin:** `HEAD == origin/main == 4a7a34c` at plan time (post-reset). No rebase task needed in §5.

## 3. File Structure

| File | Change | Status |
|---|---|---|
| `AGENT_PROMPTS.md` | Modify — (a) edit step 1 of §3 review-loopback block to drop the trailing defer-rule sentence and add a forward-reference; (b) insert a new "Minor/nit defer rule (MANDATORY — read BEFORE the findings list below; ENG-136):" block between the existing 5-step block (after step 5's "Concrete failure (ENG-123 iter 4-6)" paragraph) and the `Reviewing summary (verbatim):` header. | modified |
| `bin/agent-prompts-content-test.sh` | Modify — add seven assertions per brainstorm D-008: hoisted-header pin, position pin, scope-ceiling phrase pin, example-file-path pin, Notes-format pin, step-1 regression pin, forward-reference pin. | modified |
| `docs/brainstorms/2026-05-19-eng-136-implement-loopback-minor-defer-rule-hoist-and-scope-ceiling-design.md` | New (already written; reconcile.sh will discover via `linear: ENG-136` frontmatter). | new |
| `docs/plans/2026-05-19-eng-136-implement-loopback-minor-defer-rule-hoist-and-scope-ceiling.md` | New (this file). | new |
| `docs/plans/2026-05-19-eng-136-implement-loopback-minor-defer-rule-hoist-and-scope-ceiling.json` | New — schema-v1 plan-contract sibling. | new |

**Out of scope (NOT modified):** `bin/render-prompt.sh`, `bin/scope-check.sh`, `bin/run-stage.sh`, `bin/dispatch.sh`, `bin/linear.sh`, `bin/common.sh`, `AGENT_PROMPTS.md` §0 / §1 / §2 / §4 / §5 / §6 / §7 / §8 / §9, any `learned-rules/` file, any `docs/knowledge/` file, any `.pipeline-config/` file. Per brainstorm §3 Scope Boundaries.

## 4. API Contract

No new API surface. Pure prompt + test edit.

## 5. Backend Tasks

### Task 1: Edit step 1 of §3 review-loopback block

- `depends_on: []`
- `touches: AGENT_PROMPTS.md`
- [ ] Locate the line beginning `  1. Treat every \`[critical]\` and \`[major]\` finding as a contract you MUST close by code commits on \`{branch_name}\` before exit.` (currently `AGENT_PROMPTS.md:751`). Content anchor: the literal substring `\`{branch_name}\` before exit.`.
- [ ] Replace step 1's second sentence:
    - OLD: `\`[minor]\` and \`[nit]\` findings are best-effort — close them when cheap, defer with a one-line rationale in the stage-summary Notes otherwise.`
    - NEW: `(For \`[minor]\` and \`[nit]\` findings, see the **Minor/nit defer rule** block below.)`
- [ ] Step 1 final text:
  > 1. Treat every `[critical]` and `[major]` finding as a contract you MUST close by code commits on `{branch_name}` before exit. (For `[minor]` and `[nit]` findings, see the **Minor/nit defer rule** block below.)
- [ ] DO NOT modify steps 2, 3, 4, or 5.

### Task 2: Insert "Minor/nit defer rule" block between 5-step block and `Reviewing summary (verbatim):`

- `depends_on: [1]`
- `touches: AGENT_PROMPTS.md`
- [ ] Locate the line `Reviewing summary (verbatim):` (currently `AGENT_PROMPTS.md:760`). Content anchor: literal string `Reviewing summary (verbatim):` (unique to §3).
- [ ] Insert the following block IMMEDIATELY BEFORE `Reviewing summary (verbatim):`, separated by one blank line on each side. Block body (byte-for-byte from brainstorm D-002 / D-003 / D-004 / D-005 / D-006):

```
Minor/nit defer rule (MANDATORY — read BEFORE the findings list below; ENG-136):

A `[minor]` or `[nit]` finding is "cheap to close" ONLY if the fix requires ZERO edits to files outside the plan's File Structure table (see read-list item 9 — `docs/plans/{plan_file}`). If a fix would require touching ANY file not listed in File Structure — including but not limited to `learned-rules/<slug>/project-profile.md`, sibling test files (`bin/*-test.sh`), knowledge docs (`docs/knowledge/*`), config files (`.pipeline-config/config.json`, `.githooks/*`), or workflow definitions — DEFER the finding. Do not attempt the edit; do not extend File Structure on the fly; do not file a meta-marker as a substitute for the real edit.

For each deferred finding, append a single line to the **Notes** subsection of `stage-summary-implementing.md` in the format:

  `Deferred [<severity>] <finding-id>: <file-path-the-fix-would-touch> — <one-line rationale>`

Examples:

  `Deferred [minor] M4: learned-rules/harness/project-profile.md — outside plan File Structure; closure via next plan iteration (pipeline:extend).`
  `Deferred [nit] N2: bin/dispatch-test.sh — sibling test file outside plan File Structure; defer to follow-up ticket.`

The next plan iteration (or a `pipeline:extend` operator decision) is the correct closure path for deferred minor/nit findings. The agent MUST NOT use a review finding to authorize editing a file the plan did not list.

Concrete failure (ENG-122 implement-loopback, 2026-05-16): the implement agent attempted to close review minor #4 (`learned-rules/harness/project-profile.md:17` — Build & test gates list missing two new test scripts) on an implement-loopback dispatch. The profile file was not in the plan's File Structure. `bin/scope-check.sh` halted the dispatch as a self-leak, burning one implement-cycle on a fix the agent should have deferred. The rule above closes that failure mode by making the cheap/expensive judgment binary and mechanical: in-File-Structure → close it; out-of-File-Structure → defer it.
```

- [ ] After insertion, verify the §3 section still has EXACTLY two column-0 ` ``` ` fences via `awk 'BEGIN{c=0} /^## 3\./,/^## 4\./{ if (/^\`\`\`$/) c++ } END{print c}' AGENT_PROMPTS.md` → expected output `2`. If output is `>2`, an indentation slip allowed a ` ``` ` to land at column 0 inside the new block — fix before commit.

### Task 3: Add seven assertions to `bin/agent-prompts-content-test.sh`

- `depends_on: [2]`
- `touches: bin/agent-prompts-content-test.sh`
- [ ] Locate the line `# ─── ENG-140: §3 contains the new QA → implement loopback block ───` (currently `:103`). Content anchor: literal string `ENG-140: §3 contains the new QA → implement loopback block`.
- [ ] Insert the following block IMMEDIATELY BEFORE the ENG-140 block, separated by one blank line on each side:

```bash
# ─── ENG-136: §3 review-loopback minor/nit defer rule hoist + scope ceiling ───
# The defer-rule for [minor]/[nit] findings used to be the trailing
# sentence of step 1 in §3's review-loopback handling block. It was
# buried — the agent read the {review_findings} list immediately
# below and treated "close what the reviewer flagged" as the default.
# ENG-122's 2026-05-16 implement-loopback halted on a scope-check
# self-leak because the agent attempted to close a minor finding
# whose fix required editing learned-rules/harness/project-profile.md
# (outside the plan's File Structure).
#
# ENG-136 hoists the defer-rule into its own labeled block ABOVE
# `Reviewing summary (verbatim):` and adds a hard scope ceiling:
# minor/nit fixes touching files outside File Structure must be
# deferred (not closed). Seven assertions pin position + content.

# Pin 1: Hoisted-header presence.
if printf '%s\n' "$s3" | grep -qF 'Minor/nit defer rule (MANDATORY — read BEFORE the findings list below; ENG-136):'; then
  ok "§3 ENG-136: hoisted defer-rule header present"
else
  nope "§3 ENG-136: hoisted defer-rule header present" \
    "literal 'Minor/nit defer rule (MANDATORY — read BEFORE the findings list below; ENG-136):' missing from §3 — has the hoisted block been removed or its header renamed?"
fi

# Pin 2: Position — hoisted block sits AFTER the 5-step block (step 5's
# 'Concrete failure (ENG-123 iter 4-6)' anchor) AND BEFORE the
# 'Reviewing summary (verbatim):' header.
_eng136_header_ln="$(grep -nF 'Minor/nit defer rule (MANDATORY — read BEFORE the findings list below; ENG-136):' "$PROMPTS" | head -1 | cut -d: -f1)"
_eng136_step5_ln="$(grep -nF 'Concrete failure (ENG-123 iter 4-6)' "$PROMPTS" | head -1 | cut -d: -f1)"
_eng136_rev_ln="$(grep -nF 'Reviewing summary (verbatim):' "$PROMPTS" | head -1 | cut -d: -f1)"
if [[ -n "$_eng136_header_ln" && -n "$_eng136_step5_ln" && -n "$_eng136_rev_ln" \
      && "$_eng136_header_ln" -gt "$_eng136_step5_ln" \
      && "$_eng136_header_ln" -lt "$_eng136_rev_ln" ]]; then
  ok "§3 ENG-136: hoisted defer-rule block sits between 5-step block and Reviewing summary (lines $_eng136_step5_ln < $_eng136_header_ln < $_eng136_rev_ln)"
else
  nope "§3 ENG-136: hoisted defer-rule block positioned between 5-step block and Reviewing summary" \
    "expected step5<header<reviewing-summary; got step5=$_eng136_step5_ln header=$_eng136_header_ln reviewing-summary=$_eng136_rev_ln — has the block been moved above the 5-step block, below {review_findings}, or removed entirely?"
fi
unset _eng136_header_ln _eng136_step5_ln _eng136_rev_ln

# Pin 3: Scope-ceiling phrase — the binary-judgment language that
# makes the cheap/expensive call mechanical.
if printf '%s\n' "$s3" | grep -qF "ZERO edits to files outside the plan's File Structure"; then
  ok "§3 ENG-136: hard scope-ceiling language present ('ZERO edits to files outside the plan's File Structure')"
else
  nope "§3 ENG-136: hard scope-ceiling language present" \
    "literal 'ZERO edits to files outside the plan'\''s File Structure' missing from §3 — has the binary-judgment ceiling been softened back to fuzzy 'cheap'?"
fi

# Pin 4: Example file path — anchors the rule against the ENG-122
# failure mode named in the ticket's AC #3.
if printf '%s\n' "$s3" | grep -qF 'learned-rules/<slug>/project-profile.md'; then
  ok "§3 ENG-136: example path 'learned-rules/<slug>/project-profile.md' present"
else
  nope "§3 ENG-136: example path 'learned-rules/<slug>/project-profile.md' present" \
    "literal 'learned-rules/<slug>/project-profile.md' missing from §3 — has the ENG-122-anchored example been demoted to a generic phrasing?"
fi

# Pin 5: Notes-format prefix — the deferred-finding bookkeeping shape.
if printf '%s\n' "$s3" | grep -qF 'Deferred [<severity>] <finding-id>:'; then
  ok "§3 ENG-136: Notes format prefix 'Deferred [<severity>] <finding-id>:' present"
else
  nope "§3 ENG-136: Notes format prefix 'Deferred [<severity>] <finding-id>:' present" \
    "literal 'Deferred [<severity>] <finding-id>:' missing from §3 — has the structured Notes format been replaced with prose?"
fi

# Pin 6: Step-1 regression — the OLD buried defer-rule sentence
# must NOT remain in step 1. Catches a hoist that left the original
# sentence in place (two competing instructions).
if printf '%s\n' "$s3" | grep -qF 'best-effort — close them when cheap'; then
  nope "§3 ENG-136: step-1 regression — old buried defer-rule sentence removed" \
    "phrase 'best-effort — close them when cheap' still present in §3 — hoist left the original sentence in place; either the new block duplicates step 1 or the new block was added without removing the old sentence"
else
  ok "§3 ENG-136: step-1 regression — old buried defer-rule sentence removed"
fi

# Pin 7: Forward reference — step 1 carries the explicit pointer
# to the hoisted block so the 5-step list stays discoverable.
if printf '%s\n' "$s3" | grep -qF 'see the **Minor/nit defer rule** block below'; then
  ok "§3 ENG-136: step-1 forward reference to hoisted block present"
else
  nope "§3 ENG-136: step-1 forward reference to hoisted block present" \
    "literal 'see the **Minor/nit defer rule** block below' missing from §3 — step 1 lost the explicit pointer to the hoisted rule; a reader of step 1 alone would not know minor/nit handling is documented elsewhere"
fi
```

- [ ] Verify the new assertions all use the existing `ok`/`nope` helper shape (no new helpers introduced).

### Task 4: Run gate suite

- `depends_on: [1, 2, 3]`
- `touches: (no file edits — verification only)`
- [ ] Run `bash bin/agent-prompts-content-test.sh` → expect exit 0 with all seven new assertions passing.
- [ ] Run `bash bin/render-prompt-test.sh` → expect exit 0 (§3 fence count still == 2).
- [ ] Run `bash .githooks/pre-commit` (full suite) → expect exit 0. If a sibling unrelated test fails (KNOWN_BROKEN allowlist), confirm it's pre-existing on `origin/main` HEAD before commit.

## 6. Failure Mode → Test Map

| FM | Failure mode | Test |
|---|---|---|
| FM-1 | A future editor removes the hoisted block entirely | Pin 1 (hoisted-header presence) fails. |
| FM-2 | A future editor moves the hoisted block above the 5-step block or below `{review_findings}` | Pin 2 (position) fails — header line falls outside the `step5 < header < reviewing-summary` window. |
| FM-3 | A future editor softens "ZERO edits" back to "cheap/best-effort" prose | Pin 3 (scope-ceiling phrase) fails. |
| FM-4 | A future editor demotes the project-profile.md example to a generic phrasing, breaking the ENG-122 anchor | Pin 4 (example file path) fails. |
| FM-5 | A future editor replaces the structured Notes format with prose | Pin 5 (Notes format prefix) fails. |
| FM-6 | A future editor restores the old buried defer-rule in step 1 (leaving two competing instructions) | Pin 6 (step-1 regression) fails — phrase `best-effort — close them when cheap` is present. |
| FM-7 | A future editor removes the forward reference from step 1, regressing discoverability of the hoisted block | Pin 7 (forward reference) fails. |
| FM-8 | The new block introduces a column-0 ` ``` ` fence, breaking `render-prompt.sh::extract_block` | `bin/render-prompt-test.sh` fails (existing fence-count assertion). |

## 7. Pass criteria

All Pass-criteria listed in the sibling plan.json (`grep` + `smoke`
class). The smoke commands are `bash bin/agent-prompts-content-test.sh`
and `bash bin/render-prompt-test.sh`, both must exit 0.

## 8. Notes

This plan executes against a `--no-loopback` source dispatch — no
prior implement-stage summary exists for ENG-136. The branch was
reset to `origin/main` (commit `4a7a34c`) at shepherd start; no
earlier commits are inherited.
