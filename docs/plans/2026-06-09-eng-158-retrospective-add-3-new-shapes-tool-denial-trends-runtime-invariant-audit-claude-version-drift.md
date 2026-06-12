---
linear: ENG-158
date: 2026-06-09
topic: Retrospective — add three new shapes (tool-denial-trends, runtime-invariant-audit, claude-version-drift) following the ENG-129 prompt + driver + sibling-test pattern.
---

# ENG-158 — Retrospective: add 3 new shapes

## 0. Anti-anchoring check

**Problem restatement (user lens):** the weekly retrospective only sees stage-halt
drift today (it consumes `events.jsonl::failure_outcome != ""`). Class-of-bug
patterns visible only in *successful* envelopes — silent sandbox denials the
agent recovered around, a claude-CLI upgrade that quietly changes behavior, and
runtime-invariant drift between prompts ↔ allowed-tools ↔ resolver paths —
never reach the learning loop. Three sibling shapes broaden the ingestion
spectrum. Each follows the ENG-129 pattern verbatim.

The brainstorm context in the Linear ticket is the authoritative scope source —
no standalone `docs/brainstorms/*.md` exists for ENG-158, per `grep -rl ENG-158
docs/`. Anti-anchoring checks pass: the proposal does NOT reframe the user
problem and the per-shape solution is proportional (one prompt body + one driver +
one sibling test per shape). No escalation.

**Sizing posture.** Per the rubric this ticket touches one subsystem
(retrospective) but carries three independent design decisions (one per shape).
The Linear context explicitly notes: "Filing as one tracking ticket per user
direction; treat as umbrella if split." We honor that direction and plan all
three shapes here. Each shape lands as its own self-contained drop (prompt +
driver + test + the §9 read-list + driver invocation in
`run-retrospective-local.sh::main`) so reviewers and the implement agent can
process them one at a time.

**Dependencies acknowledged.** Shape A depends on a separate "sandbox-denial
detective" ticket that emits `events.jsonl::sandbox_denial` rows carrying
`claude_version`; Shape C depends on a separate "pin claude CLI version" ticket
that creates a checked-in expected-version file. Neither ticket has shipped to
this branch — `grep -rn 'sandbox_denial' bin/` returns nothing and no
`.claude-version`-style file exists. Per the brainstorm-supplied Dependencies
section, the SHAPES still ship now; their drivers degrade gracefully when the
upstream artifacts are absent (Shape A's prompt body emits "no rows in period"
when the `sandbox_denial` selector yields nothing; Shape C's driver emits "no
expected version pinned" when the file is missing). When the dependency tickets
land, the shapes start surfacing findings without further code changes. AC #3's
qualifier ("if drift exists in the past 7 days") permits this graceful state.

## 1. Goal

Add three retrospective shapes — `tool-denial-trends`,
`runtime-invariant-audit`, `claude-version-drift` — each consisting of a prompt
body under `bin/retro-prompts/<name>.md`, a driver at
`bin/retro-shape-<name>.sh`, and a sibling test at
`bin/retro-shape-<name>-test.sh`. Wire all three drivers into
`bin/run-retrospective-local.sh::main` before the §9 dispatch and read each
artifact into the parent retrospective via a new `{<name>_path}` token in
`AGENT_PROMPTS.md` §9. The pre-commit test suite stays green; the project
profile's Build & test gates Test command lists every new sibling test;
`AGENT_PROMPTS.md` §9 keeps its two-fence schema invariant.

## 2. Assumption Inventory

Format: `[verified]` quote-from-current-tree, OR `[assumed/new]` file-to-create.

### Branch-base freshness

`git log --oneline HEAD..origin/main` returned 8 commits at plan time (last
fetched 2026-06-09): the most recent is `31c1b2e feat(eng-120): Within-stage
iteration loop: implement stage`. The drifted commits touch
`AGENT_PROMPTS.md` §3, `bin/dispatch.sh` (implementing arm: adds
`Bash(bash bin/metrics.sh:*)`), `bin/agent-prompts-content-test.sh`,
`bin/dispatch-test.sh`, `bin/metrics-test.sh`. NONE of those files are in
this plan's "modified" set EXCEPT for the project-profile's implementing
allowlist (which ENG-120 also extended): the rebase resolution may need to
re-apply ENG-120's `metrics.sh` line into `project-profile.md`. The drift is
**clean** for this plan: no file in our File Structure is rewritten by an
upstream commit, only adjacent regions of AGENT_PROMPTS.md §9 (unchanged
upstream) are read. Task 0 below rebases first; subsequent tasks use content
anchors so they survive the rebase.

### Verified — current-tree quotes

- `[verified]` `bin/run-retrospective-local.sh:51-101` — `main()` body. Today
  ENG-129 already invokes the first shape inline between lines 79-101 (after
  the working-branch checkout, before the §9 prompt extraction). New shapes
  slot into the same block, before the §9 prompt extraction at line 103.
- `[verified]` `bin/run-retrospective-local.sh:38-49` — `_compute_retro_period`
  emits ISO start/end on stdout (two lines). New shapes reuse the same period
  via the already-captured `$period_start_iso` / `$period_end_iso` locals at
  `bin/run-retrospective-local.sh:85-88`.
- `[verified]` `bin/run-retrospective-local.sh:111-115` — the existing post-
  extraction `sed -i.bak -e "s|{stage_failure_summary_path}|...|g"` pass that
  injects ENG-129's artifact path. New shapes piggyback by chaining
  additional `-e "s|{<name>_path}|...|g"` substitutions into the SAME `sed`
  invocation.
- `[verified]` `AGENT_PROMPTS.md:2025` — `## 9. Retrospective Agent
  (Scheduled)` header line; §9 starts here.
- `[verified]` `AGENT_PROMPTS.md:2044-2057` — "Read these files (in order)"
  numbered list (items 1-11). New shape artifact paths join as a 7a / 7b / 7c
  block immediately after item 7 (the `AGENT_PROMPTS.md` read line), preceding
  the per-section dispatch instructions.
- `[verified]` `AGENT_PROMPTS.md:2066-2070` — "Some sections below are
  pre-computed by retrospective shapes…" preamble paragraph (added by
  ENG-129); each new shape extends this by adding a parallel pre-computed
  section under the existing item 1's shape (§1).
- `[verified]` `AGENT_PROMPTS.md:2075-2081` — §1 "Stage failure analysis
  (pre-computed)" block from ENG-129; the new shapes add §1a/§1b/§1c (or
  parallel placement) as additional pre-computed reads, preserving the
  fence-count invariant.
- `[verified]` `bin/render-prompt.sh:41-58` — `PROMPT_RESOLVERS` registry
  (per-issue resolvers). Retrospective shape tokens are NOT added here —
  they stay agent-runtime tokens (see next).
- `[verified]` `bin/render-prompt.sh:78` — `AGENT_RUNTIME_TOKENS=' file
  pr_number stage_failure_summary_path '` — the allow-list of tokens that
  `render-prompt.sh`'s residual unknown-token validator SKIPS (i.e. they are
  filled in by a non-render-prompt-sh caller). `stage_failure_summary_path`
  already lives here; the three new shape path tokens
  (`tool_denial_trends_path`, `runtime_invariant_audit_path`,
  `claude_version_drift_path`) extend this single space-fenced list.
- `[verified]` `bin/dispatch.sh:543` — `retrospective)` arm of
  `allowed_tools_for`. Includes `Read,Write,Edit,Grep,Glob,TaskCreate,Agent,
  Bash(git log:*),...,Bash(jq:*),Bash(awk:*),...,Bash(bash bin/metrics.sh:*)`.
  Sufficient for all three new shape dispatches; no allowlist edit needed.
- `[verified]` `bin/retro-prompts/stage-failure-summary.md:1-70` — the
  ENG-129 prompt body. New shape prompts MIRROR this structure: "## Inputs"
  + "## Insufficient-sample carve-out" + "## Task" + "## Output schema" +
  "## Mandatory exit instructions".
- `[verified]` `bin/retro-shape-stage-failure-summary.sh:1-114` — the
  ENG-129 driver. New shape drivers MIRROR this verbatim except for the
  per-shape token set, the per-shape prompt-template path, and (for Shape A)
  reading `events.jsonl::sandbox_denial`-shaped rows. Specifically: keep
  the `_parse_args`, `_render_prompt`, `_validate_no_unresolved_tokens`,
  `main()` flow; reuse `dispatch.sh retrospective`; reuse the dry-run
  placeholder path; reuse the test sentinel.
- `[verified]` `bin/retro-shape-stage-failure-summary-test.sh:1-579` — the
  ENG-129 sibling test. The three new sibling tests MIRROR this with shape-
  specific fixtures (Shape A: sandbox-denial-rows fixture; Shape B:
  prompts↔tools↔resolvers consistency fixture; Shape C: version-file present
  vs. absent fixture).
- `[verified]` `bin/metrics.sh:43,67-74` — events.jsonl shape:
  `{ts, event, issue_id, stage, outcome, duration_ms, notes, [tokens_in],
  [tokens_out], [cache_read], [cache_create], [cost_usd], [model]}`. There is
  NO `claude_version` column today; Shape A's prompt body documents that
  `claude_version` is populated only on `sandbox_denial`-event rows by the
  upstream detective ticket. The shape gracefully handles the field's
  absence (treats it as `unknown`).
- `[verified]` `CLAUDE.md:81-95` — "Retrospective shapes (ENG-129)" section
  documents the shape pattern. CLAUDE.md update extends this same section
  with a paragraph listing the three new shape names (one-line each).
- `[verified]` `learned-rules/harness/project-profile.md:14-17` — `## Build
  & test gates` Test command lists every `bin/*-test.sh` that the discovery
  agent included; new sibling tests join this line (also paralleled in
  `.pipeline-config/config.json::dispatch.tools.{implementing,qa}[]` per
  ENG-94's regeneration snippet in CLAUDE.md).
- `[verified]` `.githooks/pre-commit:151-177` — the pre-commit hook runs
  `bin/*-test.sh` (glob expansion). New tests are picked up automatically
  by the glob; no edit to the hook needed.
- `[verified]` `bin/profile-allowlist-test.sh:194-211` — assertions on
  per-stage `stage_output_paths` for `retrospective`. None of our changes
  touch retrospective's profile-allowlist behavior.

### Assumed — files to be created

- `[assumed/new]` `bin/retro-prompts/tool-denial-trends.md` — Shape A prompt
  body.
- `[assumed/new]` `bin/retro-prompts/runtime-invariant-audit.md` — Shape B
  prompt body.
- `[assumed/new]` `bin/retro-prompts/claude-version-drift.md` — Shape C
  prompt body.
- `[assumed/new]` `bin/retro-shape-tool-denial-trends.sh` — Shape A driver.
- `[assumed/new]` `bin/retro-shape-runtime-invariant-audit.sh` — Shape B
  driver.
- `[assumed/new]` `bin/retro-shape-claude-version-drift.sh` — Shape C
  driver.
- `[assumed/new]` `bin/retro-shape-tool-denial-trends-test.sh` — Shape A
  sibling test.
- `[assumed/new]` `bin/retro-shape-runtime-invariant-audit-test.sh` —
  Shape B sibling test.
- `[assumed/new]` `bin/retro-shape-claude-version-drift-test.sh` — Shape C
  sibling test.

### Assumed — external dependencies

- `[assumed/external]` `events.jsonl::sandbox_denial` rows (with optional
  `claude_version` column) — produced by the sandbox-denial detective
  ticket. Until that ticket lands, Shape A's prompt body's
  insufficient-sample carve-out fires ("No sandbox_denial rows in period").
- `[assumed/external]` checked-in expected claude version file path —
  produced by the pin-claude-version ticket. Shape C's driver reads from
  `$HARNESS_ROOT/.claude-cli-version` as the convention; on missing-file
  the shape's artifact records "no expected version pinned" and exits 0.
  If the upstream ticket picks a different path, the shape's driver gets a
  one-line edit and its sibling test updates.

## 3. File Structure

### New files (9)

- `bin/retro-prompts/tool-denial-trends.md` — Shape A prompt template (~60 lines).
- `bin/retro-prompts/runtime-invariant-audit.md` — Shape B prompt template (~70 lines).
- `bin/retro-prompts/claude-version-drift.md` — Shape C prompt template (~45 lines).
- `bin/retro-shape-tool-denial-trends.sh` — Shape A driver, mirrors `retro-shape-stage-failure-summary.sh`.
- `bin/retro-shape-runtime-invariant-audit.sh` — Shape B driver, mirrors same.
- `bin/retro-shape-claude-version-drift.sh` — Shape C driver, mirrors same.
- `bin/retro-shape-tool-denial-trends-test.sh` — Shape A sibling test.
- `bin/retro-shape-runtime-invariant-audit-test.sh` — Shape B sibling test.
- `bin/retro-shape-claude-version-drift-test.sh` — Shape C sibling test.

### Modified files (5)

- `bin/run-retrospective-local.sh` — invoke the three new drivers between
  ENG-129's `stage-failure-summary` block (ends ~line 101) and the §9 prompt
  extraction (starts at line 103); extend the `sed -i.bak` substitution at
  lines 113-115 to interpolate the three new `{<name>_path}` tokens.
- `AGENT_PROMPTS.md` — extend §9 "Read these files (in order)" with the
  three new shape artifact paths and add three new "(pre-computed)" analysis
  sections after §1 (or interleaved per the Coherence persona's guidance,
  see Task 7). Fence count stays at 2.
- `bin/render-prompt.sh` — extend `AGENT_RUNTIME_TOKENS` (line 78) with the
  three new token names so the residual unknown-token validator skips them.
- `learned-rules/harness/project-profile.md` — extend the `## Build & test
  gates` Test command line with the three new sibling tests so the gate-
  runnable test set stays aligned with the on-disk test files (test-gate
  add-side closure per the planning prompt's feasibility sweep).
- `CLAUDE.md` — append a paragraph to the existing "Retrospective shapes
  (ENG-129)" section naming the three new shapes (one line each).

### Files NOT modified (intentional)

- `bin/dispatch.sh` — D-004 of ENG-129 holds: the new shapes reuse the
  `retrospective` allowed-tools arm. No new case.
- `bin/render-prompt.sh::PROMPT_RESOLVERS` — shape path tokens are NOT
  per-issue; they belong in `AGENT_RUNTIME_TOKENS` only.
- `bin/dispatch-test.sh` — no allowed-tools change.
- `bin/metrics.sh` — Shape A reads existing-schema rows; no new metric
  emission.
- `bin/pipeline-events.json` — no new verdict vocabulary.
- `.pipeline-config/config.json::dispatch.tools.{implementing,qa}[]` —
  CLAUDE.md's regen snippet covers this on the operator side; the harness
  itself's per-target config.json is gitignored (state.local.json) and not
  in the harness repo.
- `.githooks/pre-commit` — picks up new tests via the `bin/*-test.sh` glob;
  no edit needed.

## 4. API Contract

no new API surface (this is harness orchestration — no FE↔BE API).

## 5. Backend Tasks

### Task 0: Rebase onto origin/main

- `depends_on: []`
- `touches: (rebase only)`
- [ ] Run `git fetch origin main && git rebase origin/main` from the worktree
  root. The plan-time `HEAD..origin/main` log contained 8 commits (ENG-120
  series). Resolve conflicts mechanically — none of those commits touch the
  files this plan creates; they only touch adjacent regions of
  `AGENT_PROMPTS.md`, `bin/dispatch.sh` (implementing arm), and three sibling
  tests we do not modify.
- [ ] Re-verify every `path:line` reference in §2 Assumption Inventory still
  resolves after rebase. If a §2 reference has moved (e.g. lines shifted in
  `AGENT_PROMPTS.md` §9), re-locate via the named content anchors (e.g.
  "`## 9. Retrospective Agent (Scheduled)` header") and use the shifted line
  numbers as informational hints only.
- [ ] Re-run `bash bin/render-prompt-test.sh && bash
  bin/agent-prompts-content-test.sh && bash bin/dispatch-test.sh` to confirm
  the rebase did not break invariants this plan also touches.

### Task 1: Add Shape A — `tool-denial-trends` prompt body

- `depends_on: [0]`
- `touches: bin/retro-prompts/tool-denial-trends.md`
- [ ] Create `bin/retro-prompts/tool-denial-trends.md` mirroring the structure
  of `bin/retro-prompts/stage-failure-summary.md`. Sections in order:
  - `## Inputs` — declare five tokens: `{events_jsonl_path}`,
    `{period_start_iso}`, `{period_end_iso}`, `{artifact_path}`, and
    `{previous_period_path}` (the same five used by ENG-129's shape; the
    period-comparison input is reused).
  - `## Insufficient-sample carve-out` — when `events.jsonl` is absent OR
    `jq -c 'select(.event == "sandbox_denial")' {events_jsonl_path}` emits
    zero rows in `[period_start_iso, period_end_iso]`, write the carve-out
    string `No sandbox_denial events in period; detective may not be
    deployed yet.` to `{artifact_path}` and exit.
  - `## Task` — describe the bucketing: parse rows with `event ==
    "sandbox_denial"` filtered by `ts`, group by `(claude_version || "unknown")
    × stage`, count denials per bucket, and identify the gradient (which
    `(version, stage)` pair has the highest denial count and which has the
    largest period-over-period delta).
  - `## Output schema` — markdown with two H2 headers:
    `## Denials by (claude_version × stage)` (table or bulleted list) and
    `## Top gradient finding` (one-line statement: "<version> × <stage> shows
    <N> denials, up from <M> prior period" OR "none — distribution flat").
  - `## Mandatory exit instructions` — boilerplate copied verbatim from
    ENG-129: write to `{artifact_path}`, do NOT modify other files, do NOT
    post Linear comments, do NOT commit.

### Task 2: Add Shape A — `tool-denial-trends` driver

- `depends_on: [1]`
- `touches: bin/retro-shape-tool-denial-trends.sh`
- [ ] Create `bin/retro-shape-tool-denial-trends.sh` by copying
  `bin/retro-shape-stage-failure-summary.sh` and changing:
  - The header comment (one line: "Shape: tool-denial-trends. Pre-computes
    claude_version × stage tool-denial gradient...").
  - The template path inside `_render_prompt`: substitute the literal
    `stage-failure-summary` token with `tool-denial-trends` (AFTER the
    `local template=` assignment, BEFORE the `[[ -f "$template" ]] || die`
    line — content anchor: `local template="$HARNESS_ROOT/bin/retro-prompts/`).
  - Keep the existing five-token `sed -e "s|{...}|...|g"` substitutions
    verbatim (same five tokens used).
  - Keep `_validate_no_unresolved_tokens` verbatim (same five tokens).
  - Keep the log-file path's basename matching the shape name
    (`retro-shape-tool-denial-trends-...`).
  - Keep the test sentinel at EOF.

### Task 3: Add Shape A — `tool-denial-trends` sibling test

- `depends_on: [2]`
- `touches: bin/retro-shape-tool-denial-trends-test.sh`
- [ ] Create `bin/retro-shape-tool-denial-trends-test.sh` by copying
  `bin/retro-shape-stage-failure-summary-test.sh` and:
  - Replace every `stage-failure-summary` substring with `tool-denial-trends`
    (driver path, sibling test name, fixture names).
  - Drop ENG-129's fixture-10 (the `_compute_retro_period` helper test) —
    it tests `run-retrospective-local.sh`, already covered by ENG-129's
    sibling test.
  - Add a Shape-A-specific fixture: stub `events.jsonl` containing one
    `sandbox_denial` row + one unrelated row; assert the rendered prompt
    references the events.jsonl path and the dispatch stub is invoked once.
  - Add a Shape-A-specific fixture covering the insufficient-sample
    carve-out path: stub events.jsonl with NO `sandbox_denial` rows; assert
    the shape's behavior matches the carve-out string assertion in fixture-9
    of ENG-129 (the prompt-body carries the carve-out text — fixture content
    grep, not behavior round-trip).

### Task 4: Add Shape B — `runtime-invariant-audit` prompt body

- `depends_on: [0]`
- `touches: bin/retro-prompts/runtime-invariant-audit.md`
- [ ] Create `bin/retro-prompts/runtime-invariant-audit.md` mirroring ENG-129's
  prompt body structure. Inputs differ — Shape B does NOT read events.jsonl:
  - `## Inputs` — declare four tokens: `{agent_prompts_md_path}`,
    `{dispatch_sh_path}`, `{render_prompt_sh_path}`, `{artifact_path}`. (No
    period needed; the audit is over current-tree state.)
  - `## Insufficient-sample carve-out` — n/a; the inputs always exist. Use
    a "Sanity check" subsection instead: if any of the three input paths is
    absent, write `Inputs absent: <path>` and exit.
  - `## Task` — enumerate three sub-audits:
    1. **Resolver-path coverage:** for each token registered in
       `PROMPT_RESOLVERS` (lines ~41-58) that resolves to a filesystem path
       (heuristic: resolver name ends in `_dir` or `_file` or `_path`), grep
       the dispatch call sites for `--add-dir` and confirm the resolved path
       is listed. Flag any drift.
    2. **Bash(<x>:*) referenced-but-not-allowed:** scan AGENT_PROMPTS.md for
       literal `Bash(<bin>:*)` patterns; intersect with each stage's
       `allowed_tools_for` arm; flag any stage that references a tool in its
       prompt body without listing it in its allowlist.
    3. **Stage-section table consistency:** confirm every header in
       `STAGE_TO_SECTION` (`render-prompt.sh:13-22`) matches a `## N.
       <Stage>` heading in AGENT_PROMPTS.md and vice versa.
  - `## Output schema` — markdown with three H2 headers (one per sub-audit),
    each listing findings or `none — invariant holds`.
  - `## Mandatory exit instructions` — boilerplate (same as Shape A).

### Task 5: Add Shape B — `runtime-invariant-audit` driver

- `depends_on: [4]`
- `touches: bin/retro-shape-runtime-invariant-audit.sh`
- [ ] Create `bin/retro-shape-runtime-invariant-audit.sh` by copying
  `bin/retro-shape-stage-failure-summary.sh` and adapting:
  - `_parse_args` accepts the same `--artifact-path`, `--period-start-iso`,
    `--period-end-iso` flags but ignores the period values internally (kept
    for consistency with the parent caller's invocation site). Optional
    flags: `--agent-prompts-path`, `--dispatch-sh-path`, `--render-prompt-sh-path`
    default to `$HARNESS_ROOT/AGENT_PROMPTS.md`, `$HARNESS_ROOT/bin/dispatch.sh`,
    `$HARNESS_ROOT/bin/render-prompt.sh` respectively.
  - `_render_prompt` substitutes four tokens (the three paths +
    `{artifact_path}`) into the new template.
  - `_validate_no_unresolved_tokens` enumerates those four token names (not
    the ENG-129 five).
  - Keep the dispatch call shape verbatim (`dispatch.sh retrospective ...`).
  - Keep the dry-run placeholder write and test sentinel.

### Task 6: Add Shape B — `runtime-invariant-audit` sibling test

- `depends_on: [5]`
- `touches: bin/retro-shape-runtime-invariant-audit-test.sh`
- [ ] Create `bin/retro-shape-runtime-invariant-audit-test.sh` mirroring
  ENG-129's test:
  - Reuse the source-and-stub pattern + fixture-1 (missing argument dies),
    fixture-2 (dry-run happy path), fixture-3 (token resolution — adapted
    to four tokens), fixture-4 (dry-run skips dispatch), fixture-5 (artifact
    production), fixture-6 (artifact-missing die), fixture-8 (dispatch rc
    non-zero), fixture-11 (unresolved token), fixture-12 (parent dir missing).
  - Drop fixtures 7, 9, 10, 13 (previous-period default — N/A since no period
    used; prompt-body carve-out text — different carve-out shape; period
    helper — covered by ENG-129; same-day rerun — covered structurally).
  - Add a Shape-B-specific fixture asserting the prompt template references
    the three sub-audit names (`Resolver-path coverage`, `Bash(<x>:*)
    referenced-but-not-allowed`, `Stage-section table consistency`) — grep
    against the prompt template at `bin/retro-prompts/runtime-invariant-audit.md`.

### Task 7: Add Shape C — `claude-version-drift` prompt body

- `depends_on: [0]`
- `touches: bin/retro-prompts/claude-version-drift.md`
- [ ] Create `bin/retro-prompts/claude-version-drift.md`:
  - `## Inputs` — declare three tokens: `{observed_version}`,
    `{expected_version}`, `{artifact_path}`. (The driver runs
    `claude --version` and reads the expected-version file in bash BEFORE
    dispatching, so the agent receives strings, not file paths — same shape
    as ENG-129's pre-computation principle.)
  - `## No-pin carve-out` — if `{expected_version}` is the literal string
    `(unpinned)`, write `No expected version pinned; see ENG-XXX
    (pin-claude-version ticket).` to `{artifact_path}` and exit.
  - `## Task` — compare `{observed_version}` vs `{expected_version}` as a
    string (claude versions follow `<major>.<minor>.<patch>` and may include
    a date suffix). If equal, write `Claude CLI version matches expected
    ({expected_version}).`. If different, write a one-paragraph notice
    naming both versions and recommending the operator either pin the new
    version or roll back.
  - `## Output schema` — single H2 header `## Observation` followed by the
    one-paragraph result.
  - `## Mandatory exit instructions` — boilerplate.

### Task 8: Add Shape C — `claude-version-drift` driver

- `depends_on: [7]`
- `touches: bin/retro-shape-claude-version-drift.sh`
- [ ] Create `bin/retro-shape-claude-version-drift.sh` mirroring ENG-129's
  driver, with these adaptations:
  - `main()` runs `claude --version 2>/dev/null` BEFORE dispatch and stores
    the trimmed output in a local `_OBSERVED_VERSION`. If the `claude`
    binary is unavailable, default to the literal `(unavailable)`.
  - `main()` reads `$HARNESS_ROOT/.claude-cli-version` if present (strip
    leading whitespace and trailing newline) into `_EXPECTED_VERSION`.
    Missing file → `(unpinned)`.
  - `_render_prompt` substitutes three tokens (`{observed_version}`,
    `{expected_version}`, `{artifact_path}`) into the template.
  - `_validate_no_unresolved_tokens` enumerates those three.
  - Keep the dispatch + dry-run + sentinel pattern.

### Task 9: Add Shape C — `claude-version-drift` sibling test

- `depends_on: [8]`
- `touches: bin/retro-shape-claude-version-drift-test.sh`
- [ ] Create `bin/retro-shape-claude-version-drift-test.sh`:
  - Reuse ENG-129's fixture-1 (argv missing dies), fixture-2 (happy path
    dry-run), fixture-3 (token resolution — three tokens), fixture-4
    (dry-run path), fixture-5 (artifact production), fixture-6 (artifact
    missing), fixture-8 (dispatch rc non-zero), fixture-11 (unresolved
    token), fixture-12 (parent dir missing).
  - Add Shape-C-specific fixture: pre-create `$HARNESS_ROOT/.claude-cli-version`
    in a tempdir, stub `claude --version` via a shim on PATH, assert the
    rendered prompt carries both the observed and expected strings (grep
    for `{observed_version}` and `{expected_version}` resolution).
  - Add Shape-C-specific fixture: with NO `.claude-cli-version` file, assert
    the rendered prompt carries the literal `(unpinned)` for the expected
    token (the no-pin carve-out is triggered downstream).

### Task 10: Wire all three drivers into `run-retrospective-local.sh::main`

- `depends_on: [2, 5, 8]`
- `touches: bin/run-retrospective-local.sh`
- [ ] Edit `bin/run-retrospective-local.sh::main`. Content anchor: AFTER
  the existing ENG-129 block ending in `if (( shape_rc != 0 )); then ... exit 20
  fi` (~line 98-101) AND BEFORE the comment `# Extract the retrospective block
  from AGENT_PROMPTS.md.` (~line 103). Append a single block:

  ```bash
  # ENG-158: pre-compute three additional shape artifacts. Same halt-on-failure
  # policy as ENG-129's shape — a half-retrospective is worse than a re-run.
  local tool_denial_trends_path="${shape_artifact_dir}/tool-denial-trends.md"
  local runtime_invariant_audit_path="${shape_artifact_dir}/runtime-invariant-audit.md"
  local claude_version_drift_path="${shape_artifact_dir}/claude-version-drift.md"

  for _shape_pair in \
      "tool-denial-trends:$tool_denial_trends_path" \
      "runtime-invariant-audit:$runtime_invariant_audit_path" \
      "claude-version-drift:$claude_version_drift_path"; do
    _name="${_shape_pair%%:*}"
    _path="${_shape_pair#*:}"
    shape_rc=0
    bash "$SCRIPT_DIR/retro-shape-${_name}.sh" \
      --artifact-path     "$_path" \
      --period-start-iso  "$period_start_iso" \
      --period-end-iso    "$period_end_iso" \
      || shape_rc=$?
    if (( shape_rc != 0 )); then
      bash "$SCRIPT_DIR/slack.sh" error "Weekly retrospective shape ${_name} failed (rc=$shape_rc)"
      exit 20
    fi
  done
  ```

- [ ] Extend the existing `sed -i.bak -e "s|{stage_failure_summary_path}|...|g"
  "$prompt_file"` block (content anchor: the line
  `-e "s|{stage_failure_summary_path}|${stage_failure_summary_path}|g" \`,
  ~line 114). Add three additional `-e "s|...|...|g"` clauses inside the
  same `sed` invocation for `{tool_denial_trends_path}`,
  `{runtime_invariant_audit_path}`, `{claude_version_drift_path}`.

### Task 11: Wire shape artifact tokens into `AGENT_PROMPTS.md` §9

- `depends_on: [10]`
- `touches: AGENT_PROMPTS.md`
- [ ] Edit `AGENT_PROMPTS.md` §9 (content anchor: the H2 header `## 9.
  Retrospective Agent (Scheduled)`, immediate next ` ``` ` opens the fenced
  block; line ~2025). Inside the fenced body, locate the "Read these files (in
  order):" enumeration (item 1 = events.jsonl, item 11 = last `git log` input).
  AFTER item 11, append three new top-level items `12. The pre-computed
  tool-denial-trends artifact at {tool_denial_trends_path}`, `13. The
  pre-computed runtime-invariant-audit artifact at
  {runtime_invariant_audit_path}`, `14. The pre-computed claude-version-drift
  artifact at {claude_version_drift_path}`. Rationale: items 1-11 form a
  contiguous "raw inputs" group; pre-computed shape artifacts are a NEW
  class of input that belongs after the raw block (per coherence
  persona's P1; mirrors how ENG-129 left §1 placement untouched in the
  existing flow but added a "pre-computed" preamble at L2066-2070).
- [ ] In the "Your analysis" enumeration (content anchor: the line `Your
  analysis (every pass below must produce at least "none found"`), after
  the `1. **Stage failure analysis (pre-computed):**` block and BEFORE the
  `2. **Gotcha recurrence check…**` block, insert three new pre-computed
  blocks (each a single sentence pointing at the artifact path token).
  Number them `1a`, `1b`, `1c` to preserve the existing 2–12 numbering.
- [ ] Run `bash bin/render-prompt-test.sh` and confirm §9's fence count
  stays at 2 (the `extract_block` schema invariant). Run
  `bash bin/agent-prompts-content-test.sh` to confirm the §9 content
  assertions still pass.

### Task 12: Register new tokens in `AGENT_RUNTIME_TOKENS`

- `depends_on: [11]`
- `touches: bin/render-prompt.sh`
- [ ] Edit `bin/render-prompt.sh` line 78 (content anchor: the literal
  `AGENT_RUNTIME_TOKENS=' file pr_number stage_failure_summary_path '`).
  Replace with `AGENT_RUNTIME_TOKENS=' file pr_number
  stage_failure_summary_path tool_denial_trends_path
  runtime_invariant_audit_path claude_version_drift_path '`. Preserve the
  leading + trailing single space (the substring-match assumes word-fenced
  names — see the comment at lines 75-77).

### Task 13: Update `project-profile.md` Build & test gates

- `depends_on: [3, 6, 9]`
- `touches: learned-rules/harness/project-profile.md`
- [ ] Edit `learned-rules/harness/project-profile.md` line 17 (content
  anchor: the literal `- Test: ` followed by the `&&`-chained test list).
  Append three new `&&`-chained entries:
  `&& bash bin/retro-shape-tool-denial-trends-test.sh && bash
  bin/retro-shape-runtime-invariant-audit-test.sh && bash
  bin/retro-shape-claude-version-drift-test.sh`. This is the test-gate
  add-side closure sweep — new tests under a gate-runnable glob require the
  profile gate command to enumerate them, otherwise the discovery-agent /
  retrospective gate command drifts from the on-disk test set.

### Task 14: Document the new shapes in CLAUDE.md

- `depends_on: [13]`
- `touches: CLAUDE.md`
- [ ] Edit `CLAUDE.md` (content anchor: the section header `## Retrospective
  shapes (ENG-129)`, paragraph at lines 81-95). Append a single short
  paragraph naming the three new shapes and the dependencies they each
  carry:
  `ENG-158 ships three additional shapes: tool-denial-trends (reads
  events.jsonl::sandbox_denial rows, requires the sandbox-denial detective
  ticket to be deployed before findings appear), runtime-invariant-audit
  (cross-checks AGENT_PROMPTS.md ↔ dispatch.sh allow-lists ↔ render-prompt
  resolver paths; always runnable), and claude-version-drift (compares
  claude --version against $HARNESS_ROOT/.claude-cli-version; requires the
  pin-claude-version ticket).`

## 6. Frontend Tasks

n/a — no frontend (the harness is bash orchestration only).

## 7. Failure Mode → Test Map

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
|---|---|---|---|---|
| Shape A driver invoked without `--artifact-path` | argv missing | Die with message containing `artifact-path` | unit | `bin/retro-shape-tool-denial-trends-test.sh::fixture-1-argv-missing-artifact-path` |
| Shape A dry-run | `PIPELINE_DRY_RUN=1` | Placeholder artifact created; no `dispatch.sh` call | unit | `bin/retro-shape-tool-denial-trends-test.sh::fixture-4-dryrun-path` |
| Shape A dispatch returns non-zero | stub `dispatch.sh` exits 29 | Driver dies with message containing `rc=29`; no artifact | unit | `bin/retro-shape-tool-denial-trends-test.sh::fixture-8-dispatch-rc-non-zero` |
| Shape A artifact missing post-dispatch | stub returns 0 but writes nothing | Driver dies `artifact not written` | unit | `bin/retro-shape-tool-denial-trends-test.sh::fixture-6-artifact-missing` |
| Shape A prompt template token leak | rendered prompt contains `{events_jsonl_path}` | Driver dies `unresolved token` | unit | `bin/retro-shape-tool-denial-trends-test.sh::fixture-11-unresolved-token-die` |
| Shape A insufficient-sample carve-out text present | grep prompt body | `absent or empty`-style sentinel found | unit | `bin/retro-shape-tool-denial-trends-test.sh::fixture-9-prompt-body-carries-carve-out` |
| Shape A `sandbox_denial` filter selector present in prompt | grep prompt body | literal `sandbox_denial` selector found | unit | `bin/retro-shape-tool-denial-trends-test.sh::fixture-shapeA-selector-present` |
| Shape B driver invoked without `--artifact-path` | argv missing | Die with message containing `artifact-path` | unit | `bin/retro-shape-runtime-invariant-audit-test.sh::fixture-1-argv-missing-artifact-path` |
| Shape B dry-run | `PIPELINE_DRY_RUN=1` | Placeholder artifact; no dispatch | unit | `bin/retro-shape-runtime-invariant-audit-test.sh::fixture-4-dryrun-path` |
| Shape B dispatch non-zero | stub returns 29 | Driver dies | unit | `bin/retro-shape-runtime-invariant-audit-test.sh::fixture-8-dispatch-rc-non-zero` |
| Shape B artifact missing | stub returns 0, no write | Driver dies | unit | `bin/retro-shape-runtime-invariant-audit-test.sh::fixture-6-artifact-missing` |
| Shape B token leak | unresolved `{token}` in rendered prompt | Driver dies | unit | `bin/retro-shape-runtime-invariant-audit-test.sh::fixture-11-unresolved-token-die` |
| Shape B prompt enumerates three sub-audits | grep prompt body | the three audit-section H2 headers present | unit | `bin/retro-shape-runtime-invariant-audit-test.sh::fixture-shapeB-sub-audit-headers` |
| Shape C driver missing argv | argv missing | Die | unit | `bin/retro-shape-claude-version-drift-test.sh::fixture-1-argv-missing-artifact-path` |
| Shape C dry-run | `PIPELINE_DRY_RUN=1` | Placeholder; no dispatch | unit | `bin/retro-shape-claude-version-drift-test.sh::fixture-4-dryrun-path` |
| Shape C dispatch rc non-zero | stub returns 29 | Die | unit | `bin/retro-shape-claude-version-drift-test.sh::fixture-8-dispatch-rc-non-zero` |
| Shape C artifact missing | stub returns 0, no write | Die | unit | `bin/retro-shape-claude-version-drift-test.sh::fixture-6-artifact-missing` |
| Shape C `.claude-cli-version` present | file created at $HARNESS_ROOT/.claude-cli-version | rendered prompt carries expected-version string | unit | `bin/retro-shape-claude-version-drift-test.sh::fixture-shapeC-version-file-present` |
| Shape C `.claude-cli-version` absent (no-pin) | file absent | rendered prompt carries literal `(unpinned)` for expected token | unit | `bin/retro-shape-claude-version-drift-test.sh::fixture-shapeC-version-file-absent` |
| Shape C `claude --version` unavailable | shim absent on PATH | rendered prompt carries literal `(unavailable)` for observed token | unit | `bin/retro-shape-claude-version-drift-test.sh::fixture-shapeC-claude-binary-unavailable` |
| `run-retrospective-local.sh` halt on Shape A failure | non-zero shape_rc for Shape A | `slack.sh error` + `exit 20` | integration | (manual smoke via `PIPELINE_DRY_RUN=1 bash bin/run-retrospective-local.sh` — covered by existing dry-run test path) |
| AGENT_PROMPTS.md §9 fence-count drift | accidental third fence in §9 body | `bin/render-prompt.sh::extract_block` dies with `expected 2` | integration | `bin/render-prompt-test.sh` (existing) |
| AGENT_PROMPTS.md §9 content assertions | new pre-computed sections inserted | content assertions still match | integration | `bin/agent-prompts-content-test.sh` (existing) |
| `AGENT_RUNTIME_TOKENS` unknown-token validator regression | one of the new tokens left out | render-time validator dies on `{tool_denial_trends_path}` etc. | integration | `bin/render-prompt-test.sh` (existing — validator path) |
| project-profile.md gate command drift | new tests not enumerated | gate command runs old test set; new test omitted from CI gate | integration | post-merge — manual; rebuild profile via `bash bin/setup.sh project-profile` |

## 8. Test Strategy

**Unit coverage (per shape).** Each new sibling test
(`bin/retro-shape-<name>-test.sh`) mirrors the ENG-129 source-and-stub pattern:
PIPELINE_DRY_RUN=1, LINEAR_API_KEY mocked, STUB_DIR with a fake `dispatch.sh`,
post-source override of `SCRIPT_DIR`. Per-shape fixtures cover argv parsing,
dry-run path, token resolution, dispatch rc handling, artifact production,
and shape-specific assertions (selector in prompt body for Shape A, sub-audit
headers in prompt body for Shape B, version-file presence/absence for
Shape C). Coverage matches AC #2 ("each shape's sibling test passes") and
AC #1's pattern conformance.

**Integration coverage.** The pre-commit hook (`bin/*-test.sh` glob)
picks up all three new tests automatically. `bin/render-prompt-test.sh`
and `bin/agent-prompts-content-test.sh` (both existing) gate the §9 edits
— any fence-count drift or unresolved-token regression fires on commit.
The project profile's Build & test gates Test command (Task 13) enumerates
the three new tests so the discovery agent's snapshot and the
retrospective's audit both see the same set.

**Smoke coverage.** AC #3 ("a live retrospective run consumes all three
artifacts and surfaces at least one finding per shape if drift exists in
the past 7 days") is verified by running `PIPELINE_DRY_RUN=1
TARGET_REPO=… bash bin/run-retrospective-local.sh` from the worktree and
inspecting `$PROJECT_STATE_DIR/retrospective-${today}/` for the three new
artifact files. Until the upstream dependency tickets ship (sandbox-denial
detective, pin-claude-version), the artifacts will contain the carve-out
sentinels described in §3 — that is the expected steady state, not a test
failure.

**Adversarial coverage intent.**
- Adversarial: a future commit adds a new `{<x>_path}` to AGENT_PROMPTS.md
  §9 without updating `AGENT_RUNTIME_TOKENS` → render-time validator
  catches it (the existing path; no new adversarial test needed).
- Adversarial: a future commit adds a new test under `bin/*-test.sh` but
  does NOT add it to project-profile.md's Build & test gates Test command
  → the gate-runnable set drifts; this is the same closure failure mode
  caught by the feasibility test-gate-closure sweep in self-review. The
  retrospective Shape B (runtime-invariant-audit) is itself the catch
  for this class in production going forward.
- Adversarial: a future `claude --version` upgrade changes Shape C's
  observed string format → the prompt body's string-compare semantics
  still produce a "differs" finding; the recommendation block names both
  versions verbatim so the operator can decide whether to re-pin.

**Test-gate closure (remove side).** This plan REMOVES no production
tokens — every change is additive. The remove-side sweep is empty.

**Test-gate closure (add side).** This plan ADDS three new files under the
`bin/*-test.sh` glob; per CLAUDE.md's "Build & test gates" guidance and
the planning prompt's add-side closure rule, `learned-rules/harness/project-profile.md`
appears in File Structure (Task 13) with the gate-command edit. The
operator-side `.pipeline-config/config.json::dispatch.tools.{implementing,qa}[]`
list is gitignored (per `state.local.json` convention) and not in this
plan; the regen snippet in CLAUDE.md is what operators run locally.

---

## Self-review queue

This plan goes through the `compound-engineering:document-review` skill
next: dispatch all five personas (feasibility, scope, coherence, design,
product) in parallel. Iterate until 4/5 PASS and zero P0 findings.
