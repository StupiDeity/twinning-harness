---
linear: ENG-120
date: 2026-05-17
topic: Within-stage iteration loop — implement stage (§3 directive + metrics chokepoint + content tests)
---

# Plan — Within-stage iteration loop for the implement stage (ENG-120)

## Anti-anchoring check

- **Problem (operator-perspective):** "When the implement agent's gates fail, the failure routes
  out through the review → implement cross-dispatch loopback at ~$6 per reviewer cycle and a
  cold-context boot on every implement re-dispatch. There is no bound, no explicit termination
  contract, and no telemetry for the existing `Iterate until zero P0` clause inside §3's
  Self-review block — the agent self-terminates on wall-clock or token pressure, not on a
  stated rule."
- **Brainstorm framing:** the brainstorm makes the inner loop **explicit, bounded, and
  telemetered** via a §3 directive (N=3 cap; pass-criteria sourced from `plan.json` with a
  fallback to the profile's gate suite + zero-P0 self-review; `bash bin/metrics.sh
  impl_iteration` per iteration; `verdict halt --reason iteration-exhausted` on exhaustion).
  All four moves are 1:1 with the Linear scope IN bullets. No reframing.
- **Proportionality:** the change is **prompt-side + ONE one-line allowlist extension**
  (implementing arm of `bin/dispatch.sh::allowed_tools_for` gains the `metrics.sh` dual-path
  pattern) + content/behaviour assertions in `bin/agent-prompts-content-test.sh`,
  `bin/dispatch-test.sh`, and `bin/metrics-test.sh`. **No new files, no new exit codes, no
  new halt reasons, no new orchestrator detective, no new config schema, no edits to
  `bin/run-stage.sh`, `bin/render-prompt.sh`, `bin/common.sh`, `bin/scope-check.sh`,
  `bin/pipeline-events.json`, `bin/guards.sh`, or `bin/metrics.sh`.** Brainstorm
  Architecture §3 names "Files MODIFIED — exactly three" (plus one test sibling) and "Files
  NEW — none." Proportional. Proceed.

## Goal

Add a `Within-stage iteration loop` directive block to `AGENT_PROMPTS.md` §3 that:
(a) caps the agent at N=3 inner iterations of `apply edits → commit → run pass-criteria → fix`
inside a single `claude -p` dispatch;
(b) defines termination criteria as the structured `pass_criteria[]` entries from the
`{plan_json}` body when present, else the project profile's "Build & test gates" Test-line
suite plus the existing zero-P0 self-review;
(c) emits one `bash bin/metrics.sh impl_iteration <ENG-N> implementing <pass|fail|exhausted>
<duration_ms> iteration=<K>` event per iteration;
(d) on iteration-3 failure, posts `bash bin/pipeline.sh event <ENG-N> verdict halt --reason
iteration-exhausted` and exits cleanly.

`bin/dispatch.sh::allowed_tools_for`'s `implementing)` arm gains the dual-path
`Bash(bash .pipeline/bin/metrics.sh:*),Bash(bash bin/metrics.sh:*)` extension so the agent's
metric emissions are not denied at the sandbox boundary (brainstorm A23 verified gap).

## Assumption Inventory

Format: `[verified|assumed]` ITEM — `path:line` reference.

**Branch-base freshness:** `git log --oneline HEAD..origin/main` is NON-EMPTY at plan time
(`origin/main = c23d0ff` on 2026-05-17 — 7 commits ahead, all post-2026-05-16). Per the
template's "Branch-base freshness check" preferred-path option, this plan adds an explicit
**Task 0: Rebase onto origin/main** at the top of Backend Tasks with `depends_on: []`. Every
`path:line` reference below was captured against the branch-state HEAD (`f8b29c2`) **and**
spot-checked against `origin/main`; all anchors below also survive on `origin/main`
(the upstream commits touch `bin/render-prompt.sh` and `AGENT_PROMPTS.md` in non-conflicting
regions — see "Upstream-conflict survey" near the end of this section). Task-step Edit
boundaries below use content anchors, not bare line numbers, so they remain locatable after
the rebase regardless of small line drift.

### Verified — code paths quoted from the worktree at HEAD (`f8b29c2`)

- `[verified]` `AGENT_PROMPTS.md:676` — H2 header `## 3. Implementation Agent (Backend)`.
  This is the unique anchor opening §3's body. The closing fence + the next H2 header
  `## 4. UI Agent (Frontend)` at `AGENT_PROMPTS.md:903–905` is the unique anchor closing §3.
  Both verified by `Grep "^## 3\\. Implementation Agent \\(Backend\\)|^## 4\\. UI Agent
  \\(Frontend\\)" AGENT_PROMPTS.md` on 2026-05-17 (matches at lines 676 and 905).

- `[verified]` `AGENT_PROMPTS.md:699-720` — Plan JSON contract block; embeds `{plan_json}`
  between `<<<PLAN_JSON_BEGIN>>>` / `<<<PLAN_JSON_END>>>` sentinels at lines 718-720.
  Content anchor: literal `<<<PLAN_JSON_END>>>` is unique in the file (Grep verified).

- `[verified]` `AGENT_PROMPTS.md:763-771` — Precondition — Plan-contract completeness block.
  Last line is `the plan is patched. Do NOT invent the contract.` (line 771) — unique
  literal in `AGENT_PROMPTS.md` (Grep verified). This is the immediately-preceding content
  anchor for the new iteration-loop block's insertion point.

- `[verified]` `AGENT_PROMPTS.md:773` — `Your task:` header opening the existing task-body
  block. **Not unique** within `AGENT_PROMPTS.md` — appears at lines 259, 430, 773, 946,
  1371. Within §3's body, however, it is the FIRST `Your task:` after line 676. The
  insertion point for the new block sits in the BLANK LINE between `Do NOT invent the
  contract.` (line 771) and `Your task:` (line 773); the content anchor is the line above
  (`Do NOT invent the contract.`), which is unique.

- `[verified]` `AGENT_PROMPTS.md:727-744` — Review-loopback handling block. The new
  iteration-loop directive composes with this block per brainstorm D-008 (review-loopback
  dispatches inherit the loop discipline with "tasks to verify" = review findings). No
  edits to lines 727-744.

- `[verified]` `AGENT_PROMPTS.md:750-761` — Build-loopback handling block. The rebase
  precondition fires FIRST per brainstorm D-008; the loop layers on top of any
  post-rebase work. No edits to lines 750-761.

- `[verified]` `AGENT_PROMPTS.md:809-851` — Self-review-before-exit block. Line 850
  carries the existing `Iterate until zero P0` clause that ENG-120 makes explicit and
  bounds. The new block does NOT delete this clause; it adds an outer iteration discipline
  WHILE the self-review block stays the floor (per brainstorm Edge case "Agent emits
  `outcome=pass` after iteration 1 but had a P0 in self-review"). Content anchor: literal
  `Iterate until zero P0` (line 850) is unique in `AGENT_PROMPTS.md` (Grep verified —
  zero other matches).

- `[verified]` `AGENT_PROMPTS.md:817-849` — Defensive-code restraint clause (ENG-101). No
  edits; cited so the implementer knows the existing constraint surface the loop block
  must not duplicate or contradict.

- `[verified]` `AGENT_PROMPTS.md:882-902` — Verdict marker block; line 897-898 lists
  `iteration-exhausted` as one of the allowed halt reasons. The new loop block points the
  agent at `bash bin/pipeline.sh event {issue_id} verdict halt --reason iteration-exhausted`
  using EXACTLY the same vocabulary already documented here. No edits to the verdict
  block.

- `[verified]` `bin/render-prompt.sh:41-57` — `PROMPT_RESOLVERS` registry. Line 56:
  `plan_json=_resolve_plan_json`. The `{plan_json}` token is already plumbed into the
  implementing prompt by ENG-123. No edits.

- `[verified]` `bin/render-prompt.sh:287-318` — `_resolve_plan_json` body. Symlink
  rejection at lines 293-298; delimiter-collision rejection at lines 300-305; cat-into-prompt
  path at line 306; fallback marker emission at lines 310-317. The fallback marker literal
  is `(no plan.json — falling back to prose plan)` (lines 296, 303, 317). The new loop
  block references this literal as the structural signal for switching to the
  "Build & test gates + zero-P0 self-review" fallback predicate. No edits.

- `[verified]` `bin/dispatch.sh:432-479` — `allowed_tools_for()` function. Line 454 is the
  `implementing)` arm (single-line case). Content of the implementing arm (verbatim
  excerpt, abbreviated):
  ```
  implementing)   base='Read,Write,Edit,Grep,Glob,TaskCreate,Bash(git status:*),...
                       ...,Bash(bash .pipeline/bin/linear.sh:*),Bash(bash bin/linear.sh:*),
                       Bash(bash .pipeline/bin/pipeline.sh:*),Bash(bash bin/pipeline.sh:*)' ;;
  ```
  Content anchors: the literal token `Bash(bash bin/pipeline.sh:*)' ;;` at the END of the
  implementing arm string is the unique closing token (Grep verified — appears as the
  closing fragment of multiple arms, but only the implementing arm's preceding string
  begins with `implementing)`). The new entries `,Bash(bash .pipeline/bin/metrics.sh:*),
  Bash(bash bin/metrics.sh:*)` are inserted IMMEDIATELY BEFORE the closing `'` of the
  `implementing)` arm string — mirrors the existing dual-path pattern (`linear.sh`,
  `pipeline.sh`) byte-for-byte in the same arm. **No other arm is edited** (release at
  line 459 + retrospective at line 460 already carry the pattern; brainstorming, planning,
  ui, reviewing, qa, building remain unchanged per Linear scope OUT clause).

- `[verified]` `bin/dispatch.sh:526-545` — Per-stage default timeout resolution. The
  `implementing` stage falls into the `*) timeout_minutes=30 ;;` arm at line 528 (30-min
  default). The N=3 cap in the loop block fits comfortably inside 30 min per brainstorm
  D-002. No edits.

- `[verified]` `bin/dispatch.sh:481-509` — `main()` head: reads `PIPELINE_ISSUE_ID` from
  env, resolves per-stage `usage-${stage}.json` sink. The whole-dispatch cost reporting
  is the authoritative dollar number (per brainstorm OQ-2); per-iteration is duration-only.
  No edits.

- `[verified]` `bin/metrics.sh:19-21, 41` — `main()` arg shape:
  `<event> <issue_id> <stage> <outcome> <duration_ms> [notes…] [--<flag> <val> …]`.
  Line 41 requires only `$event` and `$outcome` to be non-empty; no enum validation on
  either. Free-form `event="impl_iteration"` is accepted as-is. No edits to `bin/metrics.sh`.

- `[verified]` `bin/metrics.sh:53-74` — JSONL emission via `jq -cn`. The `notes` field is
  string-typed and JSON-encoded by `jq`; embedded newlines / control chars are escaped
  (security finding noted as P1 in brainstorm §11 — `notes` payload is consumed by
  retrospective queries and `bin/status.sh` aggregation only, NOT by any marker-aware
  parser; no sanitisation needed beyond what `jq` already does).

- `[verified]` `bin/pipeline-events.json:10-21` — `halt_reasons` array. Line 14 lists
  `"iteration-exhausted"`. The new loop block points the agent at the existing token; no
  registry edits.

- `[verified]` `bin/pipeline-events.json:52-61` — `stages` array. Line 55 lists
  `"implementing"`. The verdict-handler post-dispatch path recognises the
  `iteration-exhausted` halt-reason via the existing token + stage mapping (no
  classify-failure edit; mirrors brainstorm-loop halt path per ENG-65 D-005).

- `[verified]` `bin/agent-prompts-content-test.sh:9-77` — Test scaffold: `section_body()`
  helper at lines 20-28; `rendered_stage_body()` at lines 36-40; `s3` extracted at
  line 68 via `section_body "## 3. Implementation Agent (Backend)"`. New §3 assertions
  reuse `$s3` (no §0 dependency — the new directive is implement-only).

- `[verified]` `bin/agent-prompts-content-test.sh:79-89` — Existing §3 assertions:
  presence of `Do NOT create a PR` (line 80); absence of `gh pr create` (line 85). New
  assertions land in the §3 block at this depth; the existing assertions remain green
  (the new directive does not introduce a `gh pr create` substring nor remove the
  `Do NOT create a PR` line). Content anchor for insertion: the closing `fi` of the
  `## §3 — implement does not own PR creation.` block at line 89.

- `[verified]` `bin/dispatch-test.sh:80-101` — Existing dual-path assertion loop for
  `linear.sh` across every stage. Lines 92-100 carry the canonical shape: grep for
  both `Bash(bash \.pipeline/bin/linear\.sh:\*)` and `Bash(bash bin/linear\.sh:\*)`
  against the resolved tools string from `allowed_tools_for "$stage"`. New assertion for
  `metrics.sh` mirrors this shape (scoped to `implementing` only; release/retrospective
  already carry the pattern). Content anchor: the closing `done` of the per-stage loop
  at `bin/dispatch-test.sh:101`.

- `[verified]` `bin/metrics-test.sh:50-66` — Case A: legacy 7-key line emission, asserts
  the seven canonical fields (`ts`, `event`, `issue_id`, `stage`, `outcome`,
  `duration_ms`, `notes`). The new case mirrors Case A's shape with
  `event="impl_iteration"`, `outcome="pass"`, `notes="iteration=1"`. Content anchor:
  the case-divider comment line `# ─── Case A: no flags → 7-key legacy line ───` at
  line 50 is unique; insertion goes at the FILE END (after the last existing case) so a
  pre-existing case-divider remains the immediate anchor above it.

- `[verified]` `bin/dispatch.sh:454` lacks `metrics.sh` allowlist (brainstorm A23). Grep
  `'Bash(bash bin/metrics\\.sh' bin/dispatch.sh` on 2026-05-17 returns matches ONLY at
  lines 459 (released) and 460 (retrospective). The implementing arm at line 454 has zero
  `metrics.sh` matches. This is the structural gap D-006 addresses.

- `[verified]` `learned-rules/harness/plan.md` does NOT exist on disk
  (`ls learned-rules/harness/` returns `build.md` and `project-profile.md` only). The
  planning-stage prompt's instruction to read this file is a no-op for this dispatch.

- `[verified]` `.githooks/pre-commit` runs the full `bin/*-test.sh` suite per CLAUDE.md
  "Pre-commit hook". No new test file is added (the existing
  `bin/agent-prompts-content-test.sh`, `bin/dispatch-test.sh`, `bin/metrics-test.sh` are
  already in the gate suite). No `KNOWN_BROKEN` allowlist edit needed.

- `[verified]` `bin/render-prompt.sh::append_project_profile` (cited in CLAUDE.md "Where
  stack knowledge lives") appends the project profile to every non-retrospective dispatch's
  prompt, so the implementing agent sees the profile's `## Build & test gates` Test line
  at runtime. The fallback predicate path of the loop block references this section by
  name (not by inline reproduction) — the agent reads its own profile addendum to find
  the gate command.

### Verified — file/dir existence and absence

- `[verified]` `AGENT_PROMPTS.md` — exists; modified by Task 1.
- `[verified]` `bin/dispatch.sh` — exists; modified by Task 2.
- `[verified]` `bin/agent-prompts-content-test.sh` — exists; modified by Task 3.
- `[verified]` `bin/dispatch-test.sh` — exists; modified by Task 4.
- `[verified]` `bin/metrics-test.sh` — exists; modified by Task 5.
- `[verified]` `bin/run-stage.sh`, `bin/render-prompt.sh`, `bin/common.sh`,
  `bin/scope-check.sh`, `bin/metrics.sh`, `bin/guards.sh`, `bin/pipeline-events.json` —
  exist; NOT modified by this plan (per brainstorm Architecture §3 "Files NOT modified").
- `[verified]` `docs/plans/2026-05-17-eng-120-within-stage-iteration-loop-implement-stage.md`
  — created by this dispatch (this file).
- `[verified]` `docs/plans/2026-05-17-eng-120-within-stage-iteration-loop-implement-stage.json`
  — created by this dispatch (sibling structured contract); validates against
  `bin/plan-schema.sh validate --ident ENG-120` (post-dispatch validation owned by
  orchestrator's `bin/run-stage.sh::_validate_plan_contract`).

### Upstream-conflict survey (origin/main vs HEAD)

`git log --oneline HEAD..origin/main` returns 7 commits, all post-2026-05-16:

```
c23d0ff Merge pull request #124 from .../feat/eng-140-...
7af709f feat(ENG-140): {qa_findings} resolver + §3 QA-loopback handling block
5eb70ad test(ENG-140): cases L/M/N + §3 QA-loopback content pin
c390b49 docs(ENG-140): plan — §3 {qa_findings} token + qa-loopback block
8e91ea0 docs(ENG-140): brainstorm — {qa_findings} token + §3 qa-loopback handling block
5827814 Merge pull request #123 from .../fix/run-stage-export-dispatch-id
ae3316d fix: re-export PIPELINE_DISPATCH_ID in parent after $() capture
```

ENG-140 (the dominant upstream change) adds:
- A new `{qa_findings}` token to `bin/render-prompt.sh::PROMPT_RESOLVERS` (next to the
  existing `plan_json=_resolve_plan_json` we depend on at line 56);
- A new QA-loopback handling block in `AGENT_PROMPTS.md` §3, sitting alongside (not
  replacing) the existing Review-loopback (lines 727-744) and Build-loopback (lines
  750-761) blocks.

**Conflict assessment:** zero conflict for ENG-120. Our insertion point sits AFTER the
Precondition — Plan-contract completeness block (current line 771) and BEFORE
`Your task:` (current line 773). ENG-140's new QA-loopback block lands BEFORE the
Plan-contract completeness block (it parallels the existing loopback blocks at lines
727-761). Post-rebase, our insertion-point content anchors (`Do NOT invent the contract.`
+ `Your task:`) are both unmodified by ENG-140. Line numbers SHIFT (by ~50 lines from
ENG-140's body), but content anchors are line-number-agnostic. `bin/dispatch.sh:454` is
untouched on `origin/main` (no ENG-140-class change to `allowed_tools_for`). Test files
(`bin/agent-prompts-content-test.sh`, `bin/dispatch-test.sh`, `bin/metrics-test.sh`) are
untouched by ENG-140.

`fix(run-stage-export-dispatch-id)` (5827814 + ae3316d) edits `bin/run-stage.sh`'s
`PIPELINE_DISPATCH_ID` parent re-export logic — orthogonal to ENG-120 (our plan does not
touch `bin/run-stage.sh`).

**Conclusion: Task 0 rebase is mechanical (no semantic conflict expected).** The plan
remains correct against the post-rebase tree.

### Assumed (small set — no P0 risk; flagged for implement-time verification)

- `[assumed]` The `iteration-exhausted` halt reason on the `implementing` stage maps to
  `policy=skip-until-human-acts` in `bin/classify-failure.sh` (brainstorm A17). Mirror of
  the brainstorm-stage halt mapping per ENG-65 D-005. Implement-time verification:
  `Grep "iteration-exhausted" bin/classify-failure.sh bin/run-stage.sh` should return at
  least one mapping site. If the mapping is missing, the dispatch still halts (the verdict
  comment lands; orchestrator applies `pipeline:halted` per ENG-56), but operator-recovery
  may surface a different `policy` message. Not a P0; same recovery (`bash bin/pipeline.sh
  decide ENG-N --action continue`) works either way.

## File Structure

**Modified — exactly three files (per brainstorm Architecture §3) plus two test siblings:**

- `AGENT_PROMPTS.md` — §3 only; insert a `Within-stage iteration loop` directive block
  between the existing `Precondition — Plan-contract completeness` block (ends at the
  line `the plan is patched. Do NOT invent the contract.`) and the `Your task:` header.
  No edits anywhere else in the file; §§1, 2, 4-9 and §0 untouched.
- `bin/dispatch.sh` — `allowed_tools_for()`'s `implementing)` arm string only (single line
  edit); appends `,Bash(bash .pipeline/bin/metrics.sh:*),Bash(bash bin/metrics.sh:*)` just
  before the closing `'` of the arm. No edits to any other arm, to
  `_dispatch_tools_from_profile`, to `_dispatch_tools_extras`, or to the composition order
  comment. No edits to per-stage timeout block or any other dispatch.sh region.
- `bin/agent-prompts-content-test.sh` — append five new §3 assertions in the same per-stage
  shape as the existing `Do NOT create a PR` / `gh pr create` pair (lines 79-89). The
  assertions land immediately after the closing `fi` of the existing §3-only block (the
  `if ... 'gh pr create' ... fi` ending at line 89), forming a self-contained
  `# ─── ENG-120: §3 iteration loop ───` comment-fenced cluster.
- `bin/dispatch-test.sh` — append one new assertion: the implementing stage's resolved
  `tools` string contains BOTH `Bash(bash .pipeline/bin/metrics.sh:*)` AND
  `Bash(bash bin/metrics.sh:*)`. Mirrors the existing `linear.sh` per-stage loop's shape;
  scoped to `implementing` only (release + retrospective already carry the pattern but
  remain implicitly covered by the existing `Bash(bash bin/linear.sh:*)` allowlist test
  loop). Insertion anchor: immediately after the closing `done` of the per-stage
  `linear.sh` loop (line 101), as a self-contained `# ─── ENG-120: metrics.sh dual-path
  pattern on implementing only ───` block.
- `bin/metrics-test.sh` — append one new case (`# ─── Case ENG-120: free-form impl_iteration
  event token ───`) at file end. Mirrors Case A's shape; calls
  `run_metrics impl_iteration ENG-T120 implementing pass 1234 iteration=1` and asserts the
  emitted JSONL row has `event=impl_iteration`, `outcome=pass`, `notes=iteration=1`,
  `stage=implementing`, plus the seven canonical fields. No flag-pair (`--cost-usd` etc.)
  is exercised — those are out of scope per brainstorm OQ-2.

**New — none.** No new test files, no new helper scripts, no new prompt fragments,
no new schema, no new exit codes.

**Intentionally NOT modified** (per brainstorm Architecture §3 + Linear scope OUT):

- `bin/run-stage.sh` (no new detective; loop is prompt-side)
- `bin/render-prompt.sh` (`{plan_json}` already plumbed via ENG-123; `{qa_findings}` via
  ENG-140 — both untouched here)
- `bin/common.sh` (no new exit codes — loop exits via the existing `iteration-exhausted`
  halt path)
- `bin/pipeline-events.json` (`iteration-exhausted` already registered at line 14)
- `bin/scope-check.sh` (no new in-scope paths; the loop runs entirely in the implementing
  agent's existing tool surface)
- `bin/metrics.sh` (free-form `event` field accepts `impl_iteration` without code change)
- `bin/guards.sh` (no new threshold; loop is bounded by N=3 in the prompt, not by guards)
- `AGENT_PROMPTS.md` §§ 0, 1, 2, 4–9 (Linear scope is §3-only)
- `.pipeline-config/config.json` (no new operator-tunable; N=3 hard-coded per brainstorm
  D-002; configurability deferred to brainstorm OQ-1)

## API Contract

**no new API surface.** The harness has no FE↔BE API; it is a collection of bash
orchestration scripts. The Project profile addendum names `Bash 3.2+ orchestration scripts
(macOS-compatible)` as the stack. No endpoint, RPC service, or generated-types boundary
exists. The "interface" added by this plan is a **prompt-side directive** (read by the
`claude -p` agent during dispatch) plus an additive `--allowed-tools` pattern (no API call
shape change). Both are covered by the content/behaviour assertions in Backend Tasks 3-5.

## Backend Tasks

### Task 0: Rebase onto origin/main

- `depends_on: []`
- `touches: (no production-code edits; rebase of feat/eng-120-... onto origin/main = c23d0ff)`
- [ ] Run `git fetch origin main` (in-scope per implementing stage's `Bash(git fetch:*)`
  allowlist).
- [ ] Run `git rebase origin/main`. The Upstream-conflict survey above expects zero
  semantic conflict — ENG-140 lands a parallel §3 loopback block in `AGENT_PROMPTS.md`
  and a sibling `{qa_findings}` resolver in `bin/render-prompt.sh`; neither overlaps with
  ENG-120's insertion site or `bin/dispatch.sh:454`. If a textual conflict surfaces in
  `AGENT_PROMPTS.md` (e.g. surrounding-context-line drift), keep BOTH sides — ENG-140's
  QA-loopback block AND the unchanged Precondition / Your task / Self-review structure —
  and use the post-rebase `bin/scope-check.sh::is_benign` rules to keep the resolution
  minimal. If a conflict surfaces in `bin/dispatch.sh` (unexpected — ENG-140 does not
  touch `allowed_tools_for`), HALT with `verdict halt --reason agent-blocked` and post a
  comment naming the unexpected upstream change.
- [ ] After rebase succeeds, re-verify every Assumption Inventory `path:line` reference
  with a `Grep`/`Read` pass. Line numbers MAY shift by ~50 (ENG-140 adds a QA-loopback
  block above our insertion point); content anchors MUST remain valid. If any content
  anchor (`Do NOT invent the contract.`, `Iterate until zero P0`, `<<<PLAN_JSON_END>>>`,
  the `implementing)` arm string in `bin/dispatch.sh`, the `linear.sh` per-stage loop
  closing `done` in `bin/dispatch-test.sh`, the `# ─── Case A` comment in
  `bin/metrics-test.sh`) has been removed or renamed upstream, HALT with
  `verdict halt --reason agent-blocked` and a comment naming the missing anchor; the
  brainstorm needs `pipeline:supersede` against the new main.
- [ ] Force-push the rebased branch: `git push --force-with-lease origin
  feat/eng-120-within-stage-iteration-loop-implement-stage`. Required because the rebase
  rewrites published history.

### Task 1: Add `Within-stage iteration loop` directive block to AGENT_PROMPTS.md §3

- `depends_on: [0]`
- `touches: AGENT_PROMPTS.md (§3 body only; one new block inserted between two existing
  blocks)`
- [ ] Insert a new directive block in §3 IMMEDIATELY AFTER the Precondition —
  Plan-contract completeness block's closing line (the unique literal
  `the plan is patched. Do NOT invent the contract.`) AND IMMEDIATELY BEFORE the next
  block opener (`Your task:`). Anchor pair: `(Do NOT invent the contract.) → BLANK LINE →
  (Your task:)`. The new block is a sibling of the existing `Plan JSON contract`,
  `Review → implement loopback handling`, `Build → implement loopback handling`, and
  `Precondition — Plan-contract completeness` blocks (same indentation, same MANDATORY
  framing).
- [ ] Block content (exact phrasing — required for content-test assertions):

  ```
  Within-stage iteration loop (MANDATORY):

  After the Plan-contract completeness precondition passes, run an inner
  generator-evaluator loop INSIDE this single dispatch — up to 3 iterations of
  `apply edits → commit → evaluate pass-criteria → fix`. The goal is to converge
  on a verifiable green state within the warm context of this dispatch rather
  than handing a half-done branch to the reviewer (~$6 per reviewer cycle).

  Per iteration K (1 ≤ K ≤ 3):

    1. Apply edits.
       - Iteration 1: apply the plan's Backend Tasks (or the review's
         `[critical]` / `[major]` findings on a review-loopback dispatch, or
         the QA findings on a qa-loopback dispatch) per the TDD discipline
         described above (test commit first, impl commit second).
       - Iteration 2+: apply fixes for the preceding iteration's failed
         pass-criteria. Re-evaluate ALL pass-criteria, not just the failed
         ones (a fix can regress a previously-passing criterion).
    2. Commit per the TDD discipline (`test(...)` then `feat(...)` / `fix(...)`).
    3. Evaluate termination criteria. Two paths:
       - **Structured path (preferred):** if the `<<<PLAN_JSON_BEGIN>>>`/
         `<<<PLAN_JSON_END>>>` body parses as JSON with at least one
         `features[].pass_criteria[]` entry, walk every entry on every feature:
         - `kind=smoke`: run `<command>`; iteration passes the criterion iff
           the command's exit status equals `expect_exit`.
         - `kind=file_exists`: iteration passes the criterion iff the file at
           `path` exists.
         - `kind=grep`: iteration passes the criterion iff `grep -Eq <pattern>
           <path>` agrees with `expect_match` (negated when `expect_match` is
           false).
       - **Fallback path:** when the embedded body reads `(no plan.json —
         falling back to prose plan)`, run every command listed in the Project
         profile addendum's `## Build & test gates` section's Test line, and
         apply the existing Self-review block's zero-P0 floor. Iteration passes
         iff every gate command exits 0 AND self-review reports zero P0.
    4. Emit per-iteration telemetry — one event per iteration, exactly:
       ```
       bash bin/metrics.sh impl_iteration {issue_id} implementing <outcome>
            <duration_ms> iteration=<K>[ failed=<kind>:<key>,<kind>:<key>,…]
       ```
       Where:
         - `<outcome>` is `pass` (every pass-criterion green, every gate exit 0,
           zero P0 in self-review), `fail` (one or more criteria red and K < 3),
           or `exhausted` (one or more criteria red and K = 3).
         - `<duration_ms>` is `(end_ms - start_ms)` where you observed
           `date +%s%3N` at the iteration's start (step 1) and end (step 3
           complete). Approximate; per-iteration cost in dollars is NOT captured
           (claude does not expose intra-stream cost slices; the whole-dispatch
           cost lands in `usage-implementing.json` via dispatch.sh).
         - `failed=…` is a comma-joined list, present only when `<outcome>` is
           `fail` or `exhausted`. `<kind>` is `smoke` / `file_exists` / `grep` /
           `gate` / `self-review`; `<key>` is the smoke command, the file path,
           the grep pattern, the gate command, or the P0 finding summary.
    5. Decide the next step:
       - `<outcome>=pass` → EXIT the loop. Proceed to the TDD-evidence comment +
         stage-summary + verdict pass per the existing Output / Verdict marker
         blocks below. Do NOT iterate beyond a pass.
       - `<outcome>=fail` and K < 3 → continue to iteration K+1.
       - `<outcome>=exhausted` (K = 3 and one or more criteria still red) →
         post `bash bin/pipeline.sh event {issue_id} verdict halt --reason
         iteration-exhausted`. Write the stage-summary file per the Output
         block, name the uncovered pass-criteria in its Notes paragraph
         (one-line trail like `iteration trail: 1=fail(smoke), 2=fail(smoke),
         3=exhausted(smoke + file_exists)` per OQ-7), and exit cleanly. The
         orchestrator will apply `pipeline:halted` per ENG-56.

  An iteration's `outcome=pass` requires BOTH every pass-criterion to be green
  AND zero P0 in the Self-review-before-exit block — those are layered checks,
  not alternatives. The Self-review floor is unchanged; the loop discipline
  wraps it.

  Iteration semantics on loopback dispatches:
    - Review-loopback (`from=reviewing to=implementing`): "tasks to apply" =
      the `[critical]` / `[major]` findings from `{review_findings}`. Otherwise
      identical.
    - QA-loopback (`from=qa to=implementing`): "tasks to apply" = the findings
      in `completion/qa/{issue_id}`. Otherwise identical.
    - Build-loopback (`from=building to=implementing` with `merge_conflict`):
      the rebase precondition above fires FIRST. If the rebase resolved cleanly
      and there is no new code to add, iteration 1 just runs pass-criteria
      against the rebased branch; passing → exit after one iteration.
  ```

- [ ] After insert, confirm with `Read AGENT_PROMPTS.md` (the new block lives between
  `Do NOT invent the contract.` and `Your task:` inside §3) and run
  `bash bin/agent-prompts-content-test.sh` to confirm the existing §3 assertions still pass.

### Task 2: Grant the implementing stage the `metrics.sh` dual-path allowlist

- `depends_on: [0]`
- `touches: bin/dispatch.sh::allowed_tools_for (the implementing) arm string only)`
- [ ] In `bin/dispatch.sh::allowed_tools_for`, locate the `implementing)` case arm — its
  body is a single line whose string value starts with `Read,Write,Edit,Grep,Glob,...`
  and ends with `Bash(bash bin/pipeline.sh:*)`. Content anchor: the literal substring
  `Bash(bash bin/pipeline.sh:*)' ;;` appears at the END of MULTIPLE arms (line 452 for
  brainstorming, line 453 for planning, line 454 for implementing, line 455 for ui,
  line 456 for reviewing, line 457 for qa, line 458 for building), but ONLY the
  `implementing)` arm STARTS its base= string with the substring
  `Read,Write,Edit,Grep,Glob,TaskCreate,Bash(git status:*)`. Use that prefix +
  `implementing)` literal as the disambiguating anchor pair.
- [ ] Append `,Bash(bash .pipeline/bin/metrics.sh:*),Bash(bash bin/metrics.sh:*)` just
  before the closing `'` of the implementing arm's string. Resulting tail of the line
  reads:
  ```
  ...,Bash(bash bin/pipeline.sh:*),Bash(bash .pipeline/bin/metrics.sh:*),Bash(bash bin/metrics.sh:*)' ;;
  ```
- [ ] Do NOT touch any other arm (brainstorming, planning, ui, reviewing, qa, building
  remain unchanged; released and retrospective already carry the pattern).
- [ ] Do NOT touch the composition-order comment at lines 463-470, the
  `_dispatch_tools_from_profile` invocation, or `_dispatch_tools_extras`.

### Task 3: Pin the new §3 directive in bin/agent-prompts-content-test.sh

- `depends_on: [1]`
- `touches: bin/agent-prompts-content-test.sh (§3-only assertions, appended to existing
  §3 block)`
- [ ] Locate the existing §3-only block in `bin/agent-prompts-content-test.sh` — opens
  with the comment `# §3 — implement does not own PR creation.` and closes with the `fi`
  ending the `if printf '%s\n' "$s3" | grep -qE 'gh pr create'; then` block (this `fi`
  is the unique closing token of the §3-only block; the next line opens an ENG-108 block
  with `# ─── ENG-108: §3 read-first list has {progress_md_path} at position 1 ───`).
  Anchor pair: closing `fi` of the gh-pr-create assertion → opening comment of the
  ENG-108 block. Insert the new ENG-120 assertion cluster between these two anchors.
- [ ] Insert a new comment-fenced ENG-120 cluster:
  ```
  # ─── ENG-120: §3 within-stage iteration loop directive ─────────────────
  # The implement agent runs an inner generator-evaluator loop (up to N=3)
  # within one dispatch, sourcing termination criteria from {plan_json}'s
  # pass_criteria[] or the profile gate-suite + zero-P0 fallback, emitting
  # one bash bin/metrics.sh impl_iteration event per iteration, and halting
  # with verdict halt --reason iteration-exhausted on N=3-still-failing.
  # Five literal-anchored assertions guard against the directive being
  # silently deleted or its parameters drifted (N changed, metric name
  # changed, halt reason changed, fallback marker disconnected).
  ```
- [ ] Add the five new assertions (each on `$s3`, using `grep -qF` for plain literals or
  `grep -qE` for regex):

  - Assertion C1 (presence of the heading literal):
    ```
    if printf '%s\n' "$s3" | grep -qF 'Within-stage iteration loop'; then
      ok "§3 ENG-120: 'Within-stage iteration loop' directive heading present"
    else
      nope "§3 ENG-120: 'Within-stage iteration loop' directive heading present" \
        "phrase missing — has the iteration-loop block been removed or renamed?"
    fi
    ```

  - Assertion C2 (iteration cap N=3 verbatim — anti-drift on N):
    ```
    if printf '%s\n' "$s3" | grep -qF 'up to 3 iterations'; then
      ok "§3 ENG-120: cap literal 'up to 3 iterations' (N=3) present"
    else
      nope "§3 ENG-120: cap literal 'up to 3 iterations' (N=3) present" \
        "phrase missing — has the iteration cap drifted from N=3 (D-002)?"
    fi
    ```

  - Assertion C3 (metric chokepoint literal):
    ```
    if printf '%s\n' "$s3" | grep -qF 'bash bin/metrics.sh impl_iteration'; then
      ok "§3 ENG-120: 'bash bin/metrics.sh impl_iteration' chokepoint named"
    else
      nope "§3 ENG-120: 'bash bin/metrics.sh impl_iteration' chokepoint named" \
        "phrase missing — has the metric emission been replaced with a parallel telemetry path?"
    fi
    ```

  - Assertion C4 (structured + fallback predicate references):
    ```
    if printf '%s\n' "$s3" | grep -qF 'pass_criteria' \
       && printf '%s\n' "$s3" | grep -qF '(no plan.json — falling back to prose plan)'; then
      ok "§3 ENG-120: structured (pass_criteria) AND fallback predicate marker both present"
    else
      nope "§3 ENG-120: structured (pass_criteria) AND fallback predicate marker both present" \
        "one or both predicates missing — D-003 termination-criteria contract broken"
    fi
    ```

  - Assertion C5 (halt reason cross-reference — anti-regression on the
    `iteration-exhausted` token within the loop block specifically, not just the existing
    verdict-marker enumeration):
    ```
    # Substring proximity: 'iteration-exhausted' must appear WITHIN the iteration-loop
    # directive's body (after the heading and before 'Your task:'), not just in the
    # downstream Verdict marker block. awk extracts the loop-block window.
    loop_block="$(printf '%s\n' "$s3" | awk '/Within-stage iteration loop/{in_block=1} in_block; /^Your task:/{exit}')"
    if printf '%s\n' "$loop_block" | grep -qF 'iteration-exhausted'; then
      ok "§3 ENG-120: loop block names 'iteration-exhausted' halt reason inline"
    else
      nope "§3 ENG-120: loop block names 'iteration-exhausted' halt reason inline" \
        "phrase missing from the loop block (may exist only in the downstream verdict-marker enumeration) — D-005 halt-on-exhaustion contract broken"
    fi
    ```

- [ ] Run `bash bin/agent-prompts-content-test.sh` and confirm all assertions (existing +
  new) pass. The exit code should be 0.

### Task 4: Pin the `metrics.sh` dual-path allowlist in bin/dispatch-test.sh

- `depends_on: [2]`
- `touches: bin/dispatch-test.sh (one new assertion immediately after the existing
  per-stage linear.sh loop)`
- [ ] Locate the per-stage `linear.sh` dual-path loop in `bin/dispatch-test.sh` — the
  `for stage in brainstorming planning implementing ui reviewing qa building released; do`
  loop starting at line 80; its closing `done` is at line 101. Content anchor pair:
  opening `for stage in brainstorming planning implementing` literal → closing `done`
  (line 101).
- [ ] Insert a new self-contained assertion block IMMEDIATELY AFTER line 101's `done`:
  ```
  # ─── ENG-120: metrics.sh dual-path on implementing arm ────────────────
  # The implementing stage gains Bash(bash .pipeline/bin/metrics.sh:*) AND
  # Bash(bash bin/metrics.sh:*) so the within-stage iteration loop's
  # `bash bin/metrics.sh impl_iteration …` emissions land regardless of
  # whether the agent's worktree has the harness symlinked at .pipeline/ or
  # carries the harness scripts directly at bin/. Scoped to implementing —
  # released + retrospective already carry this pattern via the unchanged
  # allowlist arms.
  impl_tools="$(allowed_tools_for implementing 2>/dev/null)"
  if ! printf '%s' "$impl_tools" | grep -q 'Bash(bash \.pipeline/bin/metrics\.sh:\*)'; then
    fail_at "ENG-120: implementing allowlist contains Bash(bash .pipeline/bin/metrics.sh:*)" \
      "tools=$impl_tools"
  elif ! printf '%s' "$impl_tools" | grep -q 'Bash(bash bin/metrics\.sh:\*)'; then
    fail_at "ENG-120: implementing allowlist contains Bash(bash bin/metrics.sh:*)" \
      "tools=$impl_tools"
  else
    pass_at "ENG-120: implementing allowlist carries metrics.sh dual-path"
  fi
  ```
- [ ] Run `bash bin/dispatch-test.sh` and confirm all assertions pass.

### Task 5: Pin the free-form `impl_iteration` event shape in bin/metrics-test.sh

- `depends_on: [0]`
- `touches: bin/metrics-test.sh (one new case appended at file end)`
- [ ] Locate the LAST existing case in `bin/metrics-test.sh` — every case opens with a
  `# ─── Case <X>: … ───` comment; the file currently has cases A through I (and possibly
  more). Append the new case as the FINAL case in the file, before any trailing summary
  print (use `Grep "# ─── Case "` to find the highest current letter; insert after that
  case's last `reset_jsonl` / assertion).
- [ ] Insert:
  ```
  # ─── Case ENG-120: free-form impl_iteration event token ───────────────
  # The within-stage iteration loop (ENG-120) emits per-iteration metric
  # events with the free-form event name 'impl_iteration'. metrics.sh
  # accepts any string for $event (no enum validation — line 41 only
  # requires non-empty $event and $outcome). This case pins that the
  # token, outcome, and notes payload land verbatim in the JSONL row so a
  # future schema-tightening refactor that introduced enum validation
  # would surface here, not silently in production.
  reset_jsonl
  run_metrics impl_iteration ENG-T120 implementing pass 1234 "iteration=1"
  line="$(last_line)"
  for expected in \
    '"event":"impl_iteration"' \
    '"issue_id":"ENG-T120"' \
    '"stage":"implementing"' \
    '"outcome":"pass"' \
    '"duration_ms":1234' \
    '"notes":"iteration=1"'; do
    if printf '%s' "$line" | grep -qF "$expected"; then
      pass_at "Case ENG-120: row contains $expected"
    else
      fail_at "Case ENG-120: row contains $expected" "got: $line"
    fi
  done
  # Anti-regression: the fail-iteration shape must also land cleanly, including
  # the structured `failed=<kind>:<key>` notes payload.
  reset_jsonl
  run_metrics impl_iteration ENG-T120 implementing fail 5000 "iteration=2 failed=smoke:bash-bin-foo-test.sh"
  line="$(last_line)"
  if printf '%s' "$line" | grep -qF '"outcome":"fail"' \
     && printf '%s' "$line" | grep -qF '"notes":"iteration=2 failed=smoke:bash-bin-foo-test.sh"'; then
    pass_at "Case ENG-120: fail-iteration row carries outcome=fail + structured failed= notes"
  else
    fail_at "Case ENG-120: fail-iteration row carries outcome=fail + structured failed= notes" \
      "got: $line"
  fi
  ```
- [ ] Run `bash bin/metrics-test.sh` and confirm all cases (existing A-I + new ENG-120)
  pass. The exit code should be 0.

### Task 6: Run the full pre-commit gate suite

- `depends_on: [1, 2, 3, 4, 5]`
- `touches: (no production code edits; gate validation only)`
- [ ] Run `bash .githooks/pre-commit` (allowlisted via `Bash(bash .githooks/pre-commit:*)`).
  Every `bin/*-test.sh` must pass. The expected non-pass-but-allowed surface is the
  `KNOWN_BROKEN` list inside the hook itself (no new entries needed for ENG-120 — every
  test ENG-120 touches is in active rotation).
- [ ] If a sibling test that ENG-120 does NOT touch fails, halt with `verdict halt --reason
  agent-blocked` and post a comment naming the failure. Do NOT attempt to "fix while
  you're there" — the brainstorm's Scope IN list is the only authorization surface.

## Frontend Tasks

**no frontend tasks.** The harness has no frontend; the project profile names `Bash 3.2+
orchestration scripts` as the only runtime. The Linear scope is `AGENT_PROMPTS.md implement
section instructs …` — implement-stage prompt only. The UI-stage inner loop is explicitly
OUT (parallel sibling ticket).

## Failure Mode → Test Map

Each row binds a failure mode named in the brainstorm (§5 Error handling + §6 Edge cases)
to a concrete test. Behavioural-only rows (agent loop dynamics) are marked
`runtime observability` per brainstorm D-007 — the harness cannot run a real `claude -p` in
pre-commit; those rows are earned via the `impl_iteration` events.jsonl stream that the
retrospective consumes.

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
|---|---|---|---|---|
| Loop directive is silently deleted from §3 (regression) | Edit `AGENT_PROMPTS.md` §3 to remove the `Within-stage iteration loop` block | `bash bin/agent-prompts-content-test.sh` FAILs on C1 (`'Within-stage iteration loop' directive heading present`) | unit | `bin/agent-prompts-content-test.sh::§3 ENG-120 C1` |
| Iteration cap is drifted from N=3 (e.g. someone changes "up to 3" to "up to 2" or "up to 5") | Edit the cap literal in §3 | C2 FAILs (`up to 3 iterations` not found) | unit | `bin/agent-prompts-content-test.sh::§3 ENG-120 C2` |
| Metric chokepoint is replaced with a parallel telemetry path (e.g. Linear comments per iteration, defeating CLAUDE.md "metric writes go through bin/metrics.sh") | Edit §3 to drop `bash bin/metrics.sh impl_iteration` | C3 FAILs | unit | `bin/agent-prompts-content-test.sh::§3 ENG-120 C3` |
| Termination contract is broken — either the structured `pass_criteria` reference is dropped, or the fallback marker reference is dropped | Edit §3 to remove either token | C4 FAILs | unit | `bin/agent-prompts-content-test.sh::§3 ENG-120 C4` |
| Halt-on-exhaustion clause is silently moved to the downstream Verdict marker block (no longer inline in the loop block) so the agent reads "loop ends" but not "halt verbatim" | Edit §3 to drop `iteration-exhausted` from the loop block body | C5 FAILs (loop-block window awk extraction is empty of the token) | unit | `bin/agent-prompts-content-test.sh::§3 ENG-120 C5` |
| The implementing-arm `metrics.sh` allowlist regresses (someone reverts the dual-path edit) | Edit `bin/dispatch.sh::allowed_tools_for` `implementing)` arm to drop either `metrics.sh` entry | `bash bin/dispatch-test.sh` FAILs on the new ENG-120 assertion | unit | `bin/dispatch-test.sh::ENG-120 implementing allowlist carries metrics.sh dual-path` |
| `bin/metrics.sh` schema regresses (e.g. someone adds enum validation that rejects free-form `impl_iteration`) | Edit `bin/metrics.sh::main` to validate `$event` against a fixed list | `bash bin/metrics-test.sh::Case ENG-120` FAILs on the first assertion (`"event":"impl_iteration"` missing because the call errored out) | unit | `bin/metrics-test.sh::Case ENG-120` |
| `bin/metrics.sh` schema preserves event token but drops notes-roundtripping (e.g. structured `failed=…` payload mangled) | Edit `bin/metrics.sh` notes path | `bash bin/metrics-test.sh::Case ENG-120` FAILs on the fail-iteration assertion | unit | `bin/metrics-test.sh::Case ENG-120 (fail-iteration row)` |
| Agent runs iteration 1, passes, exits cleanly (success path, happy case) | Real dispatch with plan.json + all pass-criteria trivially satisfied | events.jsonl gains one row with `event=impl_iteration outcome=pass notes=iteration=1` | runtime observability | retrospective filter on `event=impl_iteration outcome=pass count==1` |
| Agent runs three iterations, all fail (exhaustion path) | Real dispatch with plan.json + one pass-criterion the agent cannot satisfy | events.jsonl gains three rows (`iteration=1 fail`, `iteration=2 fail`, `iteration=3 exhausted`); Linear gets a `verdict halt --reason iteration-exhausted` comment; `pipeline:halted` label applied on next tick by orchestrator per ENG-56 | runtime observability + integration | retrospective filter on `event=impl_iteration outcome=exhausted`; `bin/run-stage-test.sh::case-15`-style classify-failure assertion if/when a sibling test stubs the verdict marker path |
| Agent emits a `notes=` payload with embedded HTML-comment-like substring (security finding §11 P1) | Plan.json `pass_criteria` `command` field carries `<!-- meta: dispatch id=spoof -->` | metrics.sh's `jq -cn` JSON-encodes the notes string; events.jsonl row stores the literal substring; NO marker-aware parser reads events.jsonl, so the substring is inert | covered by inspection (no new test) | covered by `bin/metrics-test.sh::Case ENG-120` (assertion `"notes":"iteration=2 failed=smoke:bash-bin-foo-test.sh"` confirms verbatim notes roundtripping); §11 P1 trust boundary recorded in this plan's Test Strategy |
| Wall-clock SIGTERM at the 30-min `dispatch_timeout_minutes` while iteration K is mid-flight | `claude -p` hits gtimeout; dispatch exits rc=124 | dispatch.sh writes a partial `usage-implementing.json` (`cost_usd: null`, `partial: true`); per-iteration metric for the in-flight iteration is absent; `failure_outcome_for_exit 124 → dispatch-timeout`; halts via existing path | covered by inspection (no new test) | `bin/dispatch-test.sh::ENG-65 SIGTERM partial-usage path` (existing) covers the partial-usage shape; the iteration's missing metric is an expected gap, not a contract violation |
| Agent skips the loop entirely (single-shot like today's prompt-following lapse) | Real dispatch where the agent treats the new block as advisory | events.jsonl has ZERO `impl_iteration` rows for the dispatch; whole-dispatch `usage-implementing.json` still landed | runtime observability — retrospective surfaces the gap | retrospective filter on `stage=implementing event=stage-end` joined against `event=impl_iteration count==0`; iter-1 absorbs this (no detective per D-006 rejected alternative); follow-up ticket adds a transcript-scan detective if rate is non-trivial |
| Branch falls behind origin/main mid-dispatch (sibling commit lands during implement) | Implement-time `git fetch` reveals new origin/main commits | Task 0's rebase + content-anchor discipline ensures every subsequent Task's anchor remains locatable; if not, implement halts via `verdict halt --reason agent-blocked` | covered by Task 0 + halt path | Task 0 step "If any content anchor … has been removed or renamed upstream, HALT" |

## Test Strategy

**Unit (extend three existing files; no new test files).**

- **`bin/agent-prompts-content-test.sh`** gains five literal-anchored §3 assertions (C1-C5
  in Task 3). The assertions land in a self-contained `# ─── ENG-120: §3 within-stage
  iteration loop directive ───` cluster immediately after the existing §3-only
  `gh pr create` assertion (line 89). Each assertion is single-shot (one `grep -qF` or
  `grep -qE` against the section body) and uses the existing `ok` / `nope` helpers (no
  new test infrastructure).
- **`bin/dispatch-test.sh`** gains ONE new assertion: the implementing arm's resolved
  tools string contains BOTH metrics.sh path variants. The assertion lands in a
  self-contained `# ─── ENG-120: metrics.sh dual-path on implementing arm ───` block
  immediately after the existing per-stage `linear.sh` loop's closing `done` (line 101).
  Reuses the existing `pass_at` / `fail_at` helpers and the `allowed_tools_for` function
  already sourced at the top of the file.
- **`bin/metrics-test.sh`** gains ONE new case: free-form `impl_iteration` event lands a
  well-formed JSONL row. The case appends at file end (after the highest-lettered
  existing case) and asserts SIX field-presence patterns on the pass-iteration row +
  TWO field-presence patterns on a fail-iteration row (proves `notes` roundtripping for
  the structured `failed=<kind>:<key>` payload defined in brainstorm OQ-5).

**Integration backstop.** Three sibling test files surface second-order regressions
without ENG-120 needing to extend them:

- `bin/run-stage-test.sh` exercises the dispatch loop end-to-end with a stubbed `claude`
  binary; the new allowlist edit composes through `allowed_tools_for` without changing
  any run-stage path. Pre-commit hook runs this.
- `bin/render-prompt-test.sh` exercises `_resolve_plan_json` and token interpolation;
  the new prompt block uses the existing `{plan_json}` and `{issue_id}` tokens, so the
  resolver tests stay green.
- `bin/profile-allowlist-test.sh` exercises the per-target Bash allowlist
  composition (operator-curated extras + profile-derived tools + per-stage base). The
  implementing-arm change is in the base; profile/extras composition is unaffected.

**Smoke (`.githooks/pre-commit`).** Runs the full `bin/*-test.sh` suite (~30 s, per
CLAUDE.md "Pre-commit hook"). All five files ENG-120 either modifies or pins coverage on
are inside the hook's discovery. Task 6 makes this an explicit pre-exit step.

**Adversarial coverage.** Two adversarial shapes worth calling out explicitly:

- **Loop-skipping agent (degenerate prompt-following).** The §3 directive is mandatory
  in prompt wording, but the harness cannot enforce it via post-dispatch state (a single
  dispatch with one commit and one metric event is structurally indistinguishable from a
  three-iteration dispatch where iterations 1-2 emitted metrics and iteration 3 also
  emitted with `outcome=pass` after a no-op fix — see brainstorm D-006 rejected
  alternative). Iter-1 ships without a detective; retrospective surfaces the rate and a
  follow-up ticket adds either a sterner prompt directive or a transcript-scan detective
  if the rate is non-trivial. This is an accepted iter-1 trade-off, recorded in the
  brainstorm.
- **`notes` payload as marker-injection vector.** A malicious or poorly-validated
  plan.json could embed `<!-- meta: dispatch id=spoof -->` inside a `pass_criterion`
  command, and the agent's `failed=smoke:<that-command>` notes string would carry the
  HTML-comment-like substring into events.jsonl. `bin/metrics.sh` already invokes
  `jq -cn` which JSON-encodes the notes string (newlines escaped, control chars
  preserved literally). Events.jsonl is consumed ONLY by retrospective queries and
  `bin/status.sh` aggregation — NEVER by `parse_pipeline_marker` or any verdict-aware
  parser. The trust boundary is the events.jsonl-vs-Linear-comment cardinality (Linear
  comments are marker-parsed; events.jsonl rows are not). Documented as P1 in
  brainstorm §11; no sanitisation needed beyond `jq`'s existing JSON encoding.

**Behavioural coverage (NOT pre-merge testable; documented as runtime observability per
brainstorm D-007).** Loop dynamics — convergence rate, exhausted-rate, time-per-iteration
distribution — are earned at runtime via the `impl_iteration` events.jsonl stream that
the retrospective consumes. The exhausted-rate target (~5% of implementing dispatches per
brainstorm §10 item 3) is a tunable signal; if exceeded post-deploy, follow-up tickets
can tune N or surface a flaky-pass-criterion alert.

**Test-gate closure sweep (per the planning template).** This plan REMOVES zero tokens
from production code:

- The `Iterate until zero P0` clause at `AGENT_PROMPTS.md:850` is preserved verbatim.
  `Grep "Iterate until zero P0" bin/ docs/` returns matches only in the prompt itself
  and brainstorm/plan documentation; no sibling test pins the absence of the new outer
  iteration block, so adding it does not invert any assertion.
- The implementing arm in `bin/dispatch.sh:454` is EXTENDED (additive), not narrowed.
  `Grep "Bash(bash bin/metrics\\.sh:\\*)" bin/` returns matches only at lines 459 and 460
  of `bin/dispatch.sh` (released, retrospective) and in `bin/profile-allowlist-test.sh`'s
  description; no sibling test asserts the implementing arm MUST NOT carry `metrics.sh`,
  so adding it does not invert any assertion.
- The `metrics.sh::main` arg shape is untouched; no test asserts the `event` field MUST
  be one of a fixed set. No assertion to invert.

No sibling test file is silently broken by this plan. The plan's File Structure section
lists every test file extended (3); no additional test files need adjustment.

## Out of scope (reproduced from issue / brainstorm)

- **UI stage inner loop** — parallel sibling ticket per Linear issue OUT clause.
- **Plan.json structured criteria emit (ENG-30 / ENG-122)** — already shipped; this plan
  consumes the existing `{plan_json}` body.
- **Configurable N via `config.json::orchestrator.impl_loop_iterations`** — brainstorm
  OQ-1, deferred per ENG-65 precedent.
- **Per-iteration cost in dollars** — brainstorm OQ-2, deferred (claude does not expose
  intra-stream cost slices; whole-dispatch `usage-implementing.json` carries the
  authoritative number).
- **Orchestrator-side multi-dispatch loop** — brainstorm D-001 rejected alternative; the
  cross-dispatch review→implement loopback already covers this.
- **New halt reason `impl-loop-exhausted`** — brainstorm D-005 rejected alternative;
  reuses existing `iteration-exhausted` registry token.
- **Post-dispatch `_validate_impl_loop` detective** — brainstorm D-006 rejected
  alternative; iter-1 ships smaller. Follow-up if telemetry shows agents skipping the
  loop.
- **Edits to AGENT_PROMPTS.md sections other than §3** — Linear scope is §3-only.
  §0 (Common rules), §§1-2 (brainstorm, plan), §§4-9 (ui, review, qa, build, release,
  retrospective) untouched.
- **Skip-already-passed-criteria optimisation on iteration 2+** — brainstorm OQ-4
  recommendation is "re-evaluate all". The §3 directive in Task 1 codifies "re-evaluate
  ALL pass-criteria, not just the failed ones" inline.

## Persona review (audit trail)

Five-persona document-review run inline during this dispatch. Headline goes in the Linear
stage-summary; full record below.

### Iteration 1

| Persona | Verdict | Load-bearing findings |
|---|---|---|
| feasibility | PASS · 0 P0 | All Assumption Inventory `path:line` references verified against worktree HEAD (`f8b29c2`). `bin/dispatch.sh:454` implementing-arm lacks `metrics.sh` (D-006 gap real); lines 459/460 (released, retrospective) already carry the dual-path pattern. `AGENT_PROMPTS.md` anchors (§3 header at 676; `Do NOT invent the contract.` at 771; `Iterate until zero P0` at 850; `<<<PLAN_JSON_END>>>` at 720) all unique by Grep. Upstream survey (`HEAD..origin/main = 7 commits`, ENG-140 + run-stage-export-dispatch-id) confirmed: zero conflict with insertion site or allowlist arm; ENG-140's body adds ~50 lines above the §3 insertion point (line drift only, content anchors intact on `origin/main`). Test-gate closure sweep: plan REMOVES no production tokens; implementing-arm extension is purely additive; no sibling test inverts. Edit boundaries are content-anchored throughout (no bare-line-only boundaries). `depends_on` graph acyclic (0 → 1,2,5; 1 → 3; 2 → 4; all → 6). Failure Mode → Test Map rows each name a real test file + plausible assertion. |
| scope | PASS · 0 P0 | All Backend Tasks trace to brainstorm D-001..D-008. The plan extends `bin/metrics-test.sh` beyond the strict reading of brainstorm Architecture §3's "Files MODIFIED — exactly three" header (which itself enumerates FOUR files inline, so the header label is a brainstorm-internal documentation seam, not a plan defect). D-007 explicitly references "existing metrics-shape coverage in `bin/metrics-test.sh`" as part of AC #3 ("no infinite loop"), and the plan's File Structure flags the divergence transparently ("Modified — exactly three files (per brainstorm Architecture §3) plus two test siblings"). No task `touches` strays outside File Structure; no unauthorised features. The §3-only Linear scope is honoured (no edits to §0 / §§1-2 / §§4-9). |
| coherence | PASS · 0 P0 | Goal sentence matches brainstorm §1's four-bullet framing (explicit, bounded, telemetered; N=3; pass_criteria with fallback; iteration-exhausted halt). Linear AC #1 (≥1 inner iteration) realised by Task 1's K=1..3 prescription; AC #2 (terminates on success or exhaustion) by the loop's pass/fail/exhausted decision tree; AC #3 (telemetry records iteration count + termination reason) by Task 1's per-iteration emission + Task 5's metrics-test pin. File Structure ↔ task `touches` is 1:1 (Tasks 1-5 touch the 5 listed files; Tasks 0 and 6 are no-touch). Every Failure Mode → Test Map row maps to a Task-3/4/5 assertion or is explicitly flagged `runtime observability` per brainstorm D-007. Out-of-scope list reproduces Linear OUT (UI loop) + all brainstorm rejected alternatives (D-001 orchestrator loop, D-005 new halt reason, D-006 detective) + deferred OQs (OQ-1 configurable N, OQ-2 per-iteration cost). |
| design | PASS · 0 P0 | The plan honours the agent-prompts-dominant classification (3 subsystems per CLAUDE.md "Ticket sizing rubric": prompts + dispatch + tests). Production edits: exactly one §3 prompt block + one-line dual-path allowlist extension in `allowed_tools_for`'s `implementing)` arm (matching `linear.sh`/`pipeline.sh` pattern byte-for-byte) + three test-file extensions. No orchestrator detective, no new exit codes, no edits to `bin/run-stage.sh`/`bin/metrics.sh`/`bin/pipeline-events.json`/`bin/render-prompt.sh`/`bin/common.sh`, no new files, no circular deps. The §3 directive lands in a logically coherent slot between Precondition — Plan-contract completeness (the gate that must succeed before any inner-loop iteration is meaningful) and `Your task:` (which the loop discipline now wraps), preserving §3's precondition → task → self-review → output → verdict flow. |
| product | PASS · 0 P0 | The plan delivers the Linear ticket's ask: a §3 directive for an N=3 inner generator-evaluator loop within a single dispatch, with per-iteration `bash bin/metrics.sh impl_iteration` telemetry, structured `pass_criteria[]` termination (or profile gate-suite + zero-P0 fallback), and a `verdict halt --reason iteration-exhausted` exit on N=3 failure — the cross-dispatch loopback replacement ENG-32 frames. The "cost per iteration" Linear bullet is honestly translated to duration_ms (claude does not expose intra-stream cost slices); the trade-off is named inline in the Task 1 prompt body (step 4) AND in Out of scope so operators see the explicit deferral. Out of scope does NOT push out the iteration cap or telemetry — both delivered. |

**Gate decision: 5/5 PASS · feasibility P0 = 0 · proceeding to implementing.**
