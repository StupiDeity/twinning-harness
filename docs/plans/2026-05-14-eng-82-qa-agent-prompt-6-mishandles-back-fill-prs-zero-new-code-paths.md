---
linear: ENG-82
date: 2026-05-14
topic: AGENT_PROMPTS.md §6 — add back-fill branch-shape detection clause + canonical Decision-path D (codifies the workaround the QA agent rediscovered on ENG-79's 2026-05-08 dispatch); one pinning content-test block in bin/agent-prompts-content-test.sh
---

# Plan — ENG-82 QA agent prompt §6 mishandles back-fill PRs (zero new code paths)

Implementation plan for the design at
`docs/brainstorms/2026-05-14-eng-82-qa-agent-prompt-6-mishandles-back-fill-prs-zero-new-code-paths-design.md`.

## Anti-anchoring check

- **Problem (operator's words).** The QA agent prompt at `AGENT_PROMPTS.md`
  §6 assumes `git log main..HEAD` carries implementation commits. On a
  back-fill PR (issue scope = "document a fix already shipped on `main`";
  branch HEAD = brainstorm + plan only; diff vs main is docs-only), the
  prompt's contract is broken and the agent rediscovers the workaround
  every dispatch.
- **Brainstorm addresses it?** Yes — D-1 adopts Linear Shape A; D-2 names
  the detection signal (`git diff main..HEAD --name-only` → docs-only);
  D-3 adds Decision-path D with a canonical status line; D-4 pins three
  load-bearing tokens via `bin/agent-prompts-content-test.sh`; D-5 keeps
  the existing branch-description prose so the common-case agent is
  unaffected; D-6 picks the status-line vocabulary ("Back-fill verified",
  not "Static-verification-only"). No reframe; the brainstorm sticks
  to the issue's literal AC.
- **Proportional?** Yes. Two files touched (`AGENT_PROMPTS.md`,
  `bin/agent-prompts-content-test.sh`); zero `bin/` runtime code change;
  zero schema changes; zero new exit codes; zero new Linear labels; zero
  new verdict-registry entries (Decision-path D reuses
  `verdict pass --stage qa`). The Linear issue's Scope clause matches
  exactly: "AGENT_PROMPTS.md §6 prompt edit only (no `bin/` code
  change). One pinning content-test in `bin/agent-prompts-content-test.sh`."
- **No escalation. PROCEED.**

## Branch-base freshness

`git log --oneline HEAD..origin/main` is empty at plan time
(`origin/main = 1ea0b8d`; `HEAD = 9707571 chore(pipeline): brainstorming for ENG-82`).
No rebase task required; no upstream conflict on `AGENT_PROMPTS.md` or
`bin/agent-prompts-content-test.sh` since the brainstorm landed.

## Goal

After implement runs:

1. `bash bin/agent-prompts-content-test.sh` exits 0 with three new ENG-82
   assertions passing: §6 carries the substring `back-fill`, the literal
   detection command `git diff main..HEAD --name-only`, and the canonical
   status line prefix `Back-fill verified · 0 new code paths`.
2. `bash bin/render-prompt-test.sh` continues to exit 0 (§6 column-0 fence
   count stays at exactly 2 at lines ~1110 and ~1306 post-edit; both
   inserts go INSIDE the existing fenced block).
3. `bash .githooks/pre-commit` exits 0 (entire `bin/*-test.sh` suite green).
4. A future QA dispatch on a docs-only branch reads §6, detects the
   back-fill via the new clause, takes Decision-path D, runs the gates,
   verifies brainstorm-spec ↔ in-tree-code via Read+Grep, and emits the
   canonical `Back-fill verified · 0 new code paths · 0 adversarial tests
   added · proceeding to building` status line.

Verifiable by:

```
bash bin/agent-prompts-content-test.sh \
  && bash bin/render-prompt-test.sh \
  && bash .githooks/pre-commit
```

exiting 0.

## Brainstorm-deviation note (one location adjustment from §5)

The brainstorm §5 "Architecture (where code goes)" line says

> "**Insert** (~28 lines) at current line 1222 (between Decision-paths B and C): the new Decision-path D body (D-3)."

This contradicts the brainstorm's own detection-clause body (D-2), which
instructs the agent to "Skip to Decision path **D** at the end of this
section." The alphabetical and pedagogical ordering (A → flake; B → fail;
C → all-green normal; D → all-green back-fill) puts D AFTER C, not
between B and C.

This plan places D AFTER the existing path C's body
(content anchor: AFTER C's closing line "Orchestrator advances to `stage:building`."
BEFORE the existing "Do NOT change the Linear stage label yourself."
sentinel at line 1239 — see Task 2 below). The detection clause's "at
the end of this section" text remains accurate; the brainstorm §5
phrasing was a sloppy detail of the brainstorm, not a load-bearing
decision. Persona-review (`scope` + `coherence`) confirms this fits
within the brainstorm's verdict ("Insert a new Decision-path D" is the
load-bearing verdict; the exact in-section position is editorial).

## Assumption Inventory

Every modified-file fact below is `path:line`-cited against the current
worktree. Quoted excerpts are exact substrings to preserve in
`Edit::old_string` calls.

### Files modified in this plan: 2

- `AGENT_PROMPTS.md` (two edit sites — Task 1 detection clause inserted
  after line 1123, Task 2 Decision-path D inserted after line 1237)
- `bin/agent-prompts-content-test.sh` (one new ENG-82 §6-scoped
  assertion block, three assertions)

### Branch-base freshness note

- branch-base freshness: `HEAD..origin/main` empty at plan time
  (`origin/main = 1ea0b8d`).

### Modified-file facts — current state and verification points

- **A-001 — `AGENT_PROMPTS.md:1108` is the H2 header `## 6. QA Agent`.**
  Verified by direct read. Exact text: `## 6. QA Agent`.

- **A-002 — `AGENT_PROMPTS.md:1110` and `:1268` are the two column-0
  ``` fences wrapping §6's body.** Verified by direct read. Line 1110
  is the opening ` ``` `; line 1268 is the closing ` ``` `. The §6 body
  spans lines 1111-1267 inclusive. `bin/render-prompt.sh::extract_block`
  requires exactly 2 column-0 fences per `## N.` section, else dies
  (see A-010).

- **A-003 — `AGENT_PROMPTS.md:1122-1123` carries the existing
  branch-description prose (preserved verbatim; brainstorm D-5).**
  Verified by direct read. Exact two-line substring:

  > Branch: \`{branch_name}\` (already carries backend + frontend commits and the open PR
  > from the review stage). Check it out; you may commit additional test files here.

  This text is NOT edited (brainstorm D-5). The Task 1 detection clause
  is inserted AFTER this two-line prose. Content anchor for Task 1's
  Edit `old_string`: the literal closing `from the review stage). Check it out; you may commit additional test files here.` plus the trailing blank line at 1124 and the `Authoritative test manifest:` header at 1125.

- **A-004 — `AGENT_PROMPTS.md:1125` is the `Authoritative test manifest:`
  header.** Verified by direct read. Exact line: `Authoritative test manifest:`.
  This header is the trailing content anchor for Task 1's Edit
  `old_string` — the insert goes BEFORE this header to land the
  detection clause between "additional test files here." and the
  manifest header.

- **A-005 — `AGENT_PROMPTS.md:1131-1144` is the "New-code-path
  definition" block; lines 1137-1144 enumerate the three-test budget
  (boundary / failure-mode / concurrency).** Verified by direct read.
  Excerpt (line 1131): `New-code-path definition (replaces the legacy handwave):`.
  Excerpt (line 1144): `  A new path that lacks any of these three is a P0 finding.`
  Decision-path D's body in Task 2 references this budget as
  "vacuously satisfied" (zero code paths → trivially zero required tests).

- **A-006 — `AGENT_PROMPTS.md:1170-1183` is the `5. **Adversarial testing
  (MANDATORY …)**` step.** Verified by direct read. Excerpt (line 1170):
  `5. **Adversarial testing (MANDATORY — maker-checker within QA):**`.
  Decision-path D explicitly skips this step (zero new code paths →
  no adversarial budget required).

- **A-007 — `AGENT_PROMPTS.md:1207-1238` is the Decision-path A/B/C
  block.** Verified by direct read. Line 1207: `Decision path (apply exactly one):`.
  Line 1209: `  A. **Flake-only failures**`. Line 1214: `  B. **Genuine failures**`.
  Line 1222: `  C. **All green:**`. Line 1237: `     - Orchestrator advances to \`stage:building\`.`
  Task 2 inserts Decision-path D between line 1237 and line 1239.

- **A-008 — `AGENT_PROMPTS.md:1232` carries Decision-path C's canonical
  status line.** Verified by direct read. Exact text:
  `       - Status line (clean): \`All gates green · K adversarial tests added · proceeding to building\`.`.
  Decision-path D's canonical status line shape (`Back-fill verified · 0
  new code paths · 0 adversarial tests added · proceeding to building`)
  is structurally symmetric: `<head> · <budget> · <verdict>`.

- **A-009 — `AGENT_PROMPTS.md:1239` is the `Do NOT change the Linear
  stage label yourself.` sentinel.** Verified by direct read. Exact
  text: `Do NOT change the Linear stage label yourself. The orchestrator owns state transitions.`.
  This is the trailing content anchor for Task 2's Edit — the
  Decision-path D body inserts BEFORE this sentinel.

- **A-010 — `bin/render-prompt.sh:111-112` requires exactly 2 column-0
  fences per `## N.` section, else `die`.** Verified by direct read:

  ```bash
  if [[ "$fence_count" != "2" ]]; then
    die "AGENT_PROMPTS.md schema error: section '$section' has $fence_count column-0 fences (expected 2). Check for stray \`\`\` lines or a missing closing fence."
  fi
  ```

  Both Task 1 and Task 2 inserts go INSIDE the existing fenced block
  (between lines 1110 and 1268); the column-0 fence count for §6 stays
  at exactly 2.

- **A-011 — `bin/render-prompt.sh:184-210` is `append_project_profile`;
  appends the per-slug profile to every non-retrospective stage prompt.**
  Verified by direct read. Function checks `stage == "retrospective"`
  first (passthrough); else appends `learned-rules/$PROJECT_SLUG/project-profile.md`
  under `## Project profile (addendum)`. QA is not retrospective, so
  the addendum IS delivered with every QA dispatch — Decision-path D's
  body references "the gate commands listed in the Project profile
  addendum's `Build & test gates` section" and that reference resolves
  at dispatch time.

- **A-012 — `bin/agent-prompts-content-test.sh:20-32` defines the
  `section_body` helper used by every §N-scoped assertion.** Verified
  by direct read:

  ```bash
  section_body() {
    local heading="$1"
    awk -v h="$heading" '
      BEGIN{in_section=0; in_fence=0}
      /^```/{if (in_section) in_fence = !in_fence}
      /^## /{ if (in_section && !in_fence) exit; if (!in_section && index($0, h)) {in_section=1; next} }
      in_section{print}
    ' "$PROMPTS"
  }
  ```

  Task 3's new ENG-82 block uses `s6="$(section_body "## 6. QA Agent")"`
  — the heading literal `## 6. QA Agent` matches A-001.

- **A-013 — `bin/agent-prompts-content-test.sh` has no §6-specific
  positive-assertion block today.** Verified by `grep -n 'QA Agent\|##
  6\|s6=' bin/agent-prompts-content-test.sh`: all matches are inside
  per-stage `for stage_section in …` loops at lines 447, 493, 528, 572,
  609, 1025 or in `assert_overwrite_mandate "## 6. QA Agent" qa` at
  line 1110. None bind `s6="$(section_body "## 6. QA Agent")"`. Task 3's
  new block is the first §6-specific positive-assertion block.

- **A-014 — `bin/agent-prompts-content-test.sh:13-14` defines the `ok`
  and `nope` helpers used by every assertion.** Verified by direct
  read:

  ```bash
  ok()   { printf 'OK: %s\n' "$1"; PASS=$((PASS+1)); }
  nope() { printf 'FAIL: %s\n  reason: %s\n' "$1" "$2" >&2; FAIL=$((FAIL+1)); }
  ```

  Task 3's new assertions call these helpers identically to the
  existing assertions at lines 126-140 (ENG-97 §2 pattern).

- **A-015 — `bin/agent-prompts-content-test.sh:1240` is the final
  results printf + exit gate.** Verified by direct read:

  ```bash
  printf '\nRESULTS: %d passed, %d failed\n' "$PASS" "$FAIL"
  [[ "$FAIL" == 0 ]] || exit 1
  ```

  Task 3's new block must be inserted BEFORE this final printf;
  insertion point is between line 1238 (`unset _iter7_m4_total`) and
  line 1240. Specifically: BEFORE the `# ─── ENG-87: token-coverage`
  block at line 1188 is a poor anchor (the token-coverage block is
  conceptually separate); a clean anchor is "immediately after
  `assert_overwrite_mandate \"## 7. Build Agent\" building` at line
  1111" so the new ENG-82 §6 block sits with other §6-targeted
  assertions. Reaffirmed in Task 3 step 3.1.

- **A-016 — `.githooks/pre-commit` runs the full `bin/*-test.sh` suite
  at commit time.** Verified per `CLAUDE.md::## Tests / Pre-commit hook`
  section ("runs the entire `bin/*-test.sh` suite (~30 s) and blocks
  the commit on any failure"). `bin/agent-prompts-content-test.sh`
  IS a `bin/*-test.sh` file; the implement agent's pre-commit gate
  catches any §6 regression.

- **A-017 — `bin/render-prompt-test.sh` does not assert §6-specific
  content.** Verified by `Grep` for `back-fill|QA Agent|qa-` (returns
  zero matches in `bin/render-prompt-test.sh`). The Task 1 and Task 2
  edits do NOT break `bin/render-prompt-test.sh`.

- **A-018 — Test-gate closure sweep: tokens REMOVED from
  `AGENT_PROMPTS.md` by this plan.** This plan REMOVES zero tokens
  from `AGENT_PROMPTS.md`. It only INSERTS content. So the test-gate
  closure sweep has no removals to verify.

  Tokens ADDED (defensive check — confirm they aren't pinned-absent
  anywhere): the additions are:
  - `Branch-shape detection (MANDATORY, BEFORE running gates):` —
    `Grep -F 'Branch-shape detection'` on `bin/*-test.sh` returns zero
    matches; no test pins this phrase as ABSENT. Safe.
  - `git diff main..HEAD --name-only` — `Grep -F 'git diff main..HEAD'`
    on `bin/*-test.sh` returns zero matches. Safe.
  - `back-fill` (literal, lowercase, hyphenated) — `Grep -F 'back-fill'`
    on `bin/*-test.sh` returns zero matches; `Grep -i 'back-fill'` on
    `bin/*-test.sh` also returns zero. Safe.
  - `Back-fill verified · 0 new code paths` — `Grep -F 'Back-fill
    verified'` on `bin/*-test.sh` returns zero matches. Safe.
  - `Decision-path D` / `path D` letter — the existing
    `bin/agent-prompts-content-test.sh` does not currently restrict
    the count or naming of Decision-path letters in §6 (no test pins
    "exactly 3 paths" or "no path D"). Safe.

  Tokens whose ABSENCE is asserted that this plan must not violate:
  - `bin/agent-prompts-content-test.sh:148` runs the ENG-97
    `forbidden_token` loop over `Tauri`, `tauri::`, `tauri.conf.json`,
    `src-tauri/`, `cargo test -- --list`, `invoke(`. Task 1 and Task 2
    inserts contain NONE of these tokens (the detection clause uses
    `git diff main..HEAD --name-only` only; the Decision-path D body
    uses stack-agnostic phrasing: "the gate commands listed in the
    Project profile addendum's `Build & test gates` section", "Use
    Read + Grep on `main`"). Safe.
  - `bin/agent-prompts-content-test.sh:161` runs the case-insensitive
    `tauri` scan on the whole prompt file. Neither insert contains
    any `tauri` substring (case-insensitive). Safe.
  - `bin/agent-prompts-content-test.sh:1065` forbids
    `env VAR=val bash bin/...` shape anywhere in `AGENT_PROMPTS.md`.
    Neither insert contains an env-var-prefixed bash invocation. Safe.
  - `bin/agent-prompts-content-test.sh:1176-1185` (ENG-87 iter-7 M4)
    caps occurrences of `MANDATORY — overwrite on every dispatch`
    phrase at ≤2 across the file. Neither insert adds this phrase
    (Decision-path D's body refers to the stage-summary contract in
    one sentence: "Write the stage summary file at
    `{stage_summary_path}` — follow the Stage summary comment format
    contract (preamble)." — does NOT use the literal "MANDATORY —
    overwrite on every dispatch" wording). Safe.

  **Conclusion:** zero test-gate closure defects. No sibling test
  file needs editing.

- **A-019 — `git diff main..HEAD --name-only` is a stage-agnostic core
  tool (no per-stage tool-allowlist entry needed).** Verified per
  `learned-rules/harness/project-profile.md::## Tool allowlist`
  opening: "Stage-agnostic core tools (Read, Write, Edit, Grep, Glob,
  TaskCreate, **git family**, `bash bin/linear.sh`, …) are implicit
  and not declared here." `git diff` is in the implicit `git family`.
  The agent will be able to run the detection command at dispatch
  time without any allowlist change.

- **A-020 — `bin/run-local-helpers.sh::partition_dirty_paths::D-004`
  requires `eng-N` (lowercase) in the doc basename for in-scope
  bucketing on brainstorming/planning.** Verified per
  `CLAUDE.md::## Sweep + scope partition (ENG-14)` and brainstorm A-20.
  The plan filename `2026-05-14-eng-82-qa-agent-prompt-6-mishandles-back-fill-prs-zero-new-code-paths.md`
  contains `eng-82` lowercase in the basename. Plan doc will bucket
  in-scope. ✓

- **A-021 — `bin/render-prompt.sh::STAGE_TO_SECTION` does not need to
  change.** Verified per brainstorm A-21. STAGE_TO_SECTION keys §6 by
  the section name `## 6. QA Agent` (unchanged); inserting content
  inside the §6 body does not change the section identifier.

- **A-022 — `bin/pipeline-events.json` (the verdict registry) does
  not need to change.** Verified per brainstorm A-26. Decision-path D
  exits with the existing `verdict pass --stage qa` marker; no new
  registry entry required. The existing §6 Verdict marker block at
  `AGENT_PROMPTS.md:1247-1267` is unchanged.

- **A-023 — `failure_outcome_for_exit` in `bin/common.sh` does not
  need a new exit code.** Verified per brainstorm A-23. Decision-path
  D's clean exit is exit 0 (success), identical to path C. No new
  taxonomy entry needed.

- **A-024 — `bin/render-prompt-slug-test.sh` does not pin any §6
  content.** Verified by `Grep -E 'back-fill|QA Agent|qa-' bin/render-prompt-slug-test.sh`:
  zero matches. The Task 1 and Task 2 edits do not break this test.

- **A-025 — Per-stage transcript path and stage-summary file path used
  in Decision-path D's body match the existing §6 path C convention.**
  Verified per A-008: path C writes `{stage_summary_path}` and posts
  to `completion/qa/{issue_id}`. Decision-path D uses the same
  token names verbatim (already declared in `PROMPT_RESOLVERS` per
  the §0 token-coverage assertion at line 1188-1233). No new token
  needed.

## File Structure

Modified files only — no new files, no new test scripts, no new
dependencies.

- `AGENT_PROMPTS.md` — two edit sites inside §6:
  - Task 1: insert ~10 lines between line 1123 (end of branch-description
    prose) and line 1125 (`Authoritative test manifest:` header) — the
    branch-shape detection clause (brainstorm D-2).
  - Task 2: insert ~28 lines between line 1237 (end of Decision-path C
    body, `- Orchestrator advances to \`stage:building\`.`) and line
    1239 (the `Do NOT change the Linear stage label yourself.` sentinel)
    — the new Decision-path D body (brainstorm D-3).
  - No edits to lines 1108 (header), 1110 (opening fence), 1122-1123
    (branch-description prose — brainstorm D-5), 1131-1144 (new-code-path
    definition), 1170-1183 (adversarial-testing step), 1200-1205 (quality
    gates), 1207-1237 (Decision paths A/B/C), 1239-1267 (verdict marker
    block), 1268 (closing fence).
  - Column-0 fence count for §6 stays at exactly 2 (both inserts go
    INSIDE the existing fenced block).
- `bin/agent-prompts-content-test.sh` — one new ENG-82 §6-scoped
  assertion block inserted after line 1111 (`assert_overwrite_mandate "##
  7. Build Agent" building`). Three assertions: (a) §6 carries the
  substring `back-fill`; (b) §6 cites the literal detection command
  `git diff main..HEAD --name-only`; (c) §6 pins the canonical status
  line prefix `Back-fill verified · 0 new code paths`. Uses the
  existing `section_body` helper (A-012); no helper changes.

Explicitly out of scope (per brainstorm §10 + Linear Scope clause):

- `bin/dispatch.sh` — unchanged. Detection uses implicit core `git`
  tools.
- `bin/run-local-helpers.sh`, `bin/scope-check.sh`, `bin/render-prompt.sh`,
  `bin/run-stage.sh`, `bin/poll.sh`, `bin/verdict-handler.sh`, `bin/linear.sh`,
  `bin/common.sh` — unchanged.
- `CLAUDE.md` — unchanged (§6's contract is prompt-stage-specific;
  documenting it in CLAUDE.md adds a drift surface).
- `learned-rules/harness/qa.md` — does not exist; not created by this
  ticket. Future retrospective may surface it if recurrence justifies.
- `bin/pipeline-events.json` — unchanged (no new verdict variant).
- `bin/common.sh::failure_outcome_for_exit` — unchanged (no new exit
  code).

## API Contract

no new API surface

(The harness has no FE↔BE surface of its own — it is a bash orchestration
toolkit. The `api-contract` block being edited LIVES INSIDE
`AGENT_PROMPTS.md` as illustrative prompt content for the Plan agent's
output schema; it is not the harness's own API. Decision-path D's
prompt addition does not introduce or change any FE↔BE shape.)

## Backend Tasks

Task 1 and Task 2 have no content-anchor overlap (Task 1's anchor lives
near line 1123-1125; Task 2's anchor lives near line 1237-1239) and can
be applied in any order. Task 3 (test changes) depends on Tasks 1+2
because its assertions verify the §6 edits landed. The implement agent
SHOULD apply Tasks 1+2 first (in any order), then Task 3, then run the
gate suite.

### Task 1: Insert branch-shape detection clause in AGENT_PROMPTS.md §6 (brainstorm D-2)

- `depends_on: []`
- `touches: AGENT_PROMPTS.md` — §6 between line 1123 and 1125

Steps:

- [ ] **1.1** Use a single `Edit` call with multi-line `old_string`
  anchored on the unique closing line of the branch-description prose
  AND the trailing `Authoritative test manifest:` header. Content
  anchor (unique substring within file — both pieces below appear
  exactly once in `AGENT_PROMPTS.md`):

  - START anchor: the literal trailing `from the review stage). Check it out; you may commit additional test files here.` (the closing fragment of the branch-description sentence at line 1123)
  - END anchor: the literal `Authoritative test manifest:` header (line 1125)
  - The intermediate blank line at 1124 is preserved.

  Exact `old_string` (3 lines as they appear in the file):

  ```
  from the review stage). Check it out; you may commit additional test files here.

  Authoritative test manifest:
  ```

  Exact `new_string` (replacement — inserts the detection clause as a
  paragraph between the two anchors, preserving both bounding lines):

  ```
  from the review stage). Check it out; you may commit additional test files here.

  Branch-shape detection (MANDATORY, BEFORE running gates):
    Determine whether this PR introduces new code paths by running:
      git diff main..HEAD --name-only
    - If every changed path matches `^docs/` (i.e., `git diff main..HEAD --name-only | grep -vE '^docs/'` returns zero lines), this is a **back-fill PR**: the issue scope is to document a fix already shipped on `main`. Skip to Decision path **D** at the end of this section.
    - Otherwise, proceed normally with the gate runs, coverage audit, and adversarial-testing budget below.

  Authoritative test manifest:
  ```

  Notes:
  - The clause is plain-prose (no fenced sub-block, no column-0 ```);
    `bin/render-prompt.sh::extract_block`'s column-0 fence count for
    §6 stays at exactly 2 (the existing fences at lines 1110 and 1268
    are unaffected).
  - The clause is read-only (`git diff --name-only`); no Bash tool
    allowlist change required (A-019).
  - The leading `MANDATORY, BEFORE running gates` phrasing mirrors
    the existing `5. **Adversarial testing (MANDATORY — maker-checker
    within QA):**` rhetorical shape at line 1170 — the agent is
    primed by the same MANDATORY signal.

- [ ] **1.2** Verify by reading back `AGENT_PROMPTS.md:1118-1135` after
  the Edit. Confirm: (a) line 1123 still ends with `additional test
  files here.`; (b) the new `Branch-shape detection (MANDATORY, BEFORE
  running gates):` header appears immediately below; (c) the
  `Authoritative test manifest:` header is preserved further below;
  (d) no column-0 ` ``` ` appears inside the inserted block (no fences
  in plain-prose body).

### Task 2: Insert canonical Decision-path D body in AGENT_PROMPTS.md §6 (brainstorm D-3)

- `depends_on: []`
- `touches: AGENT_PROMPTS.md` — §6 between line 1237 and 1239

Steps:

- [ ] **2.1** Use a single `Edit` call with multi-line `old_string`
  anchored on the unique closing line of Decision-path C's body AND
  the trailing `Do NOT change the Linear stage label yourself.`
  sentinel. Content anchor (unique substring within file):

  - START anchor: the literal `     - Orchestrator advances to \`stage:building\`.` (Decision-path C's last bullet at line 1237)
  - END anchor: the literal `Do NOT change the Linear stage label yourself. The orchestrator owns state transitions.` (line 1239)
  - The intermediate blank line at 1238 is preserved.

  Exact `old_string` (3 lines as they appear in the file):

  ```
       - Orchestrator advances to `stage:building`.

  Do NOT change the Linear stage label yourself. The orchestrator owns state transitions.
  ```

  Exact `new_string` (replacement — inserts the Decision-path D body
  between the two anchors, preserving both bounding lines):

  ```
       - Orchestrator advances to `stage:building`.

    D. **Back-fill PR** (branch-shape detection above flagged this PR as docs-only — every path under `git diff main..HEAD --name-only` matches `^docs/`):
       - Run the gate commands listed in the Project profile addendum's "Build & test gates" section. The gates protect against a regression on `main` between when the original fix shipped and this PR opened; they must still pass.
       - SKIP the coverage audit (§3), the regression-intent audit (§4), and the adversarial-testing budget (§5). The new-code-path budget is vacuously satisfied — zero new code paths means zero required tests.
       - Verify the brainstorm's specification matches the in-tree implementation. Use Read + Grep on `main` to confirm the code described in the brainstorm exists at the paths the brainstorm names. If the brainstorm describes something that is NOT in the tree, this is a P0 finding — treat as Decision-path B (genuine failure, loop back to implementing).
       - Commit no new tests (none required).
       - Post a QA summary comment on the PR (gates green + back-fill confirmation: brainstorm spec ↔ in-tree code match).
       - Write the stage summary file at `{stage_summary_path}` — follow the Stage summary comment format contract (preamble). Orchestrator posts it to Linear as `completion/qa/{issue_id}`. Stage-specific slots:
         - Artifact link: the PR URL.
         - TL;DR: 1–2 sentences confirming this is a back-fill PR and that the brainstorm spec matches the shipped code.
         - Status line (clean): `Back-fill verified · 0 new code paths · 0 adversarial tests added · proceeding to building`.
         - Notes (only on partial-match): one paragraph if the brainstorm spec is partially out of date relative to the shipped code; cite specific drift.
       - Orchestrator advances to `stage:building`.

  Do NOT change the Linear stage label yourself. The orchestrator owns state transitions.
  ```

  Notes:
  - Placement is AFTER path C (alphabetical + pedagogical ordering;
    matches the detection clause's "Skip to Decision path D at the end
    of this section" text from Task 1). The brainstorm §5's "between B
    and C" location was a sloppy detail; see "Brainstorm-deviation note"
    above. Persona-review confirms this fits the brainstorm's verdict.
  - The body uses the SAME indentation (2 spaces for the `D.` headline,
    5 spaces for its bullets, 7 spaces for sub-bullets) as paths A/B/C
    at lines 1209-1237. Verify by visual diff with path C's body
    after the Edit.
  - The body does NOT use the literal "MANDATORY — overwrite on every
    dispatch" phrase (caps the ENG-87 iter-7 M4 occurrence count at ≤2;
    see A-018).
  - The body references `{stage_summary_path}` and `{issue_id}` — both
    are existing prompt tokens already in `PROMPT_RESOLVERS` (see
    `bin/render-prompt.sh:212-219`); no new token registry entry needed
    (A-025).
  - The body's literal `· 0 new code paths` substring is what Task 3's
    third assertion pins; preserve exact spacing and the middle-dot
    `·` character (U+00B7).

- [ ] **2.2** Verify by reading back `AGENT_PROMPTS.md:1232-1265` after
  the Edit. Confirm: (a) path C's body ends with `Orchestrator advances
  to \`stage:building\`.`; (b) the new `D. **Back-fill PR** (…)`
  headline appears immediately below path C; (c) the canonical
  status line `Back-fill verified · 0 new code paths · 0 adversarial
  tests added · proceeding to building` appears in path D's body;
  (d) the `Do NOT change the Linear stage label yourself.` sentinel
  is preserved further below; (e) no column-0 ` ``` ` appears inside
  the inserted block.

- [ ] **2.3** Confirm §6 fence count is unchanged. Run (mentally or
  via grep):

  ```
  awk '/^## /{c=0} /^```/{c++} END{print c}' AGENT_PROMPTS.md
  ```

  is NOT a perfect check (counts all-file fences), but the
  load-bearing check is what `bin/render-prompt-test.sh` exercises at
  test time — `bash bin/render-prompt-test.sh` after the Edit MUST
  exit 0.

### Task 3: Add ENG-82 §6 pinning assertion block in bin/agent-prompts-content-test.sh (brainstorm D-4)

- `depends_on: [1, 2]`
- `touches: bin/agent-prompts-content-test.sh` — insert one new
  assertion block after line 1111

Steps:

- [ ] **3.1** Use a single `Edit` call with multi-line `old_string`
  anchored on the unique line `assert_overwrite_mandate "## 7. Build
  Agent" building` (line 1111 — the last call in the
  `assert_overwrite_mandate` cluster). Content anchor:

  - START anchor: `assert_overwrite_mandate "## 7. Build Agent"                    building`
  - END anchor: the blank line immediately following, then the next
    block's leading comment `# ─── ENG-87 review-iter-7 C2: dispatch-id contract delivered to agents ──`

  Exact `old_string` (3 lines as they appear in the file):

  ```
  assert_overwrite_mandate "## 7. Build Agent"                    building

  # ─── ENG-87 review-iter-7 C2: dispatch-id contract delivered to agents ──
  ```

  Exact `new_string` (inserts the ENG-82 block between the
  `assert_overwrite_mandate` cluster and the ENG-87 iter-7 C2 block,
  preserving both bounding lines):

  ```
  assert_overwrite_mandate "## 7. Build Agent"                    building

  # ─── ENG-82: §6 back-fill detection clause + Decision-path D ────────
  # Without this rule, the QA agent on a back-fill PR (issue scope =
  # document a fix already shipped) spends reasoning budget rediscovering
  # the workaround and emits a non-canonical status line. See
  # docs/brainstorms/2026-05-14-eng-82-…-design.md and ENG-79's
  # 2026-05-08 monitoring run for the source incident.
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
  unset s6

  # ─── ENG-87 review-iter-7 C2: dispatch-id contract delivered to agents ──
  ```

  Notes:
  - The block uses `section_body` (not `rendered_stage_body`) because
    the clause is §6-specific, not §0-consolidated (A-012, brainstorm
    D-4 rationale).
  - The first assertion uses `grep -qiF 'back-fill'` (case-insensitive
    + fixed-string). The detection clause inserted by Task 1 contains
    the literal `back-fill` (hyphenated, lowercase); a future edit
    that capitalises or de-hyphenates the token is still caught by
    case-insensitive matching only if the substring remains
    "back-fill" or "Back-fill". The status-line assertion below
    independently pins the capitalised `Back-fill verified` form.
  - The second assertion uses `grep -qF 'git diff main..HEAD --name-only'`
    (fixed-string) — preserves the exact command shape. A future
    edit that changes to `git diff origin/main..HEAD` (rejected
    OQ-1) trips this.
  - The third assertion uses `grep -qF 'Back-fill verified · 0 new
    code paths'` (fixed-string) — the middle-dot `·` (U+00B7) MUST
    be preserved in the prompt body for this match. The literal
    `· 0 new code paths` substring is the load-bearing pedagogical
    detail (operators reading `completion/qa/ENG-N` comments grep
    for `0 new code paths` to count back-fills).
  - The `unset s6` line is added defensively to avoid s6 leaking to
    later assertions (consistent with `unset _iter7_m4_total` at
    line 1238 of the existing file).
  - The block is placed AFTER the `assert_overwrite_mandate` cluster
    (it's a §6-positive assertion family — same conceptual cluster as
    the §6 overwrite-mandate at line 1110) and BEFORE the ENG-87
    iter-7 C2 dispatch-id block (which targets a different stage's
    rendered body).

- [ ] **3.2** Verify by running `bash bin/agent-prompts-content-test.sh`
  in dry-run mode (i.e., locally on the worktree before commit). Expected
  output: three new `OK:` lines for the ENG-82 assertions; total
  `RESULTS: <N> passed, 0 failed`.

- [ ] **3.3** Run the full pre-commit gate: `bash .githooks/pre-commit`
  MUST exit 0 (this runs `bin/agent-prompts-content-test.sh` AND every
  other `bin/*-test.sh` AND `bin/render-prompt-test.sh`). If any test
  fails, do NOT commit; investigate and fix.

## Frontend Tasks

The harness has no frontend. UI Agent is a pass-through stage for this
target. No frontend tasks.

## Failure Mode → Test Map

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
|---|---|---|---|---|
| `back-fill` token silently dropped from §6 | A future prompt cleanup pass removes the back-fill detection clause | Assertion fires loud: `FAIL: §6 ENG-82: carries 'back-fill' detection clause` | unit | Task 3 assertion 1 in `bin/agent-prompts-content-test.sh` (the `grep -qiF 'back-fill'` check) |
| Detection command shape changes | A future edit changes `git diff main..HEAD --name-only` to e.g. `git diff origin/main..HEAD` (rejected OQ-1) or to a different signal | Assertion fires: `FAIL: §6 ENG-82: cites detection command 'git diff main..HEAD --name-only'` | unit | Task 3 assertion 2 in `bin/agent-prompts-content-test.sh` (the `grep -qF 'git diff main..HEAD --name-only'` check) |
| Canonical status line drops the explicit `0 new code paths` | A future edit collapses Decision-path D's status line to `Back-fill verified · proceeding to building` (loses the budget-zero pedagogical detail) | Assertion fires: `FAIL: §6 ENG-82: pins canonical status line 'Back-fill verified · 0 new code paths · …'` | unit | Task 3 assertion 3 in `bin/agent-prompts-content-test.sh` (the `grep -qF 'Back-fill verified · 0 new code paths'` check) |
| §6 column-0 fence count drifts after the inserts | Task 1 or Task 2 accidentally adds a column-0 ` ``` ` line inside the §6 body | `bin/render-prompt.sh::extract_block` dies at next dispatch render with `AGENT_PROMPTS.md schema error: section '6. QA Agent' has N column-0 fences (expected 2)` | unit | Existing `bin/render-prompt-test.sh` fence-count invariant + pre-commit hook |
| §6 header renamed (e.g. `## 6. Quality Agent`) | A future edit drifts the H2 heading | `s6="$(section_body "## 6. QA Agent")"` returns empty; all three new assertions trivially `nope` (the §6-positive check fires because the empty `$s6` doesn't contain `back-fill`); operator sees three explicit failures | unit | Task 3 assertions 1-3 (each `grep -qiF` on empty `$s6` returns false, triggering the `nope`) |
| Decision-path D body present but uses the rejected vocabulary `Static-verification-only` | Future edit reverts to the Linear issue's example phrasing | Assertion 3 fires: status line check expects `Back-fill verified` prefix; `Static-verification-only · …` does not contain `Back-fill verified · 0 new code paths` substring | unit | Task 3 assertion 3 |
| Real-world: back-fill QA dispatch on a docs-only branch takes the wrong path (e.g., enters path C and reports `K=0` instead of taking path D) | Agent ignores the new detection clause | Operator audit grep on `completion/qa/ENG-N` for `Back-fill verified · 0 new code paths` returns zero matches AND for `All gates green · 0 adversarial tests added` returns one match with no new code paths in the PR | smoke | Manual post-deploy smoke (next back-fill ticket; no automated test for agent behavior — verifiable by reading the next `completion/qa/ENG-N` comment and checking the status line is the new canonical) |
| Brainstorm-spec ↔ in-tree-code drift detected by Decision-path D body | Decision-path D's body's Read+Grep check finds the brainstorm describes code that's not in the tree | Agent emits `verdict fail --target implementing` per path D's body; orchestrator loops back to implementing (existing path B semantics — no new orchestrator branch) | smoke | Manual post-deploy smoke (next mismatched back-fill; agent emits path B verdict; existing `bin/verdict-handler.sh` test suite already covers `verdict fail --target implementing` semantics — no new test required) |

## Test Strategy

**Unit (3 new):**

Three new `bin/agent-prompts-content-test.sh` assertions (Task 3) cover
the three load-bearing tokens added by Tasks 1+2:

1. §6 carries the literal substring `back-fill` (case-insensitive
   fixed-string match) — verifies the detection clause exists.
2. §6 carries the literal substring `git diff main..HEAD --name-only`
   (fixed-string match) — verifies the detection command shape is
   preserved.
3. §6 carries the literal substring `Back-fill verified · 0 new code
   paths` (fixed-string match) — verifies the canonical status line
   prefix is preserved.

Failure of any assertion fires loud via the `nope` helper (A-014);
`.githooks/pre-commit` blocks the commit (A-016). The full pre-commit
gate (`bash .githooks/pre-commit`) runs `bin/agent-prompts-content-test.sh`
along with every other `bin/*-test.sh` — total ~30s.

**Integration (existing — unchanged):**

`bin/render-prompt-test.sh` continues to verify §6's column-0 fence
count and the prompt's renderability. Both Task 1 and Task 2 inserts go
INSIDE the existing fenced block; no new fences introduced; existing
test continues to exit 0.

`bin/render-prompt-slug-test.sh` does not pin §6-specific content
(A-024); existing test continues to exit 0.

**Smoke (manual, post-deploy):**

Two qualitative smoke checks live in the Failure Mode → Test Map
table above (rows 7 and 8). Both are observed at the next back-fill
QA dispatch by reading the resulting `completion/qa/ENG-N` Linear
comment. The harness has no automated agent-behavior testing surface
today; the assertion-based unit tests are the structural defense.

**Adversarial (existing — unchanged, defensive overlap):**

The existing ENG-97 `forbidden_token` loop at
`bin/agent-prompts-content-test.sh:148-154` and the case-insensitive
`tauri` scan at line 161 continue to ensure no Tauri-specific token
slips into the new Decision-path D body (verified by inspection in
A-018: the new body contains zero `Tauri`/`tauri`/`src-tauri/`/`cargo
test -- --list`/`invoke(` substrings).

**Test-gate closure (per the checklist's mandatory sweep):**

This plan REMOVES zero tokens from `AGENT_PROMPTS.md`; only INSERTS.
The mandatory sweep (per A-018) found zero sibling test files needing
edits. No test file outside `bin/agent-prompts-content-test.sh` is in
scope.

**No new tests against agent behavior at runtime.** The
brainstorm-spec ↔ in-tree-code Read+Grep step in Decision-path D's
body is agent-side behavior; verifying it would require fixturing a
dispatched `claude -p` call, which is outside this ticket's prompt-only
scope. The three pinning assertions catch the load-bearing
prompt-content drift; the agent's exercise of the new path is
observed post-deploy on the next back-fill issue.
