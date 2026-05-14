---
linear: ENG-99
date: 2026-05-13
topic: Sweep residual Tauri framing from CLAUDE.md, README.md, and five docs/*.md files; rewrite five surfaces with the canonical "stack-neutral base + profile-derived stack tools + operator-curated extras" phrasing, broaden cargo/bun examples to the 4-package-manager set (cargo / bun / pip / go), add a new "Discovery and the project profile" H2 to docs/architecture.md and a "Where stack knowledge lives" callout to CLAUDE.md (AC#4); no code edits, no schema bumps, no tests added.
---

# Plan — ENG-99 docs sweep for residual Tauri references

Implementation plan for the brainstorm at
`docs/brainstorms/2026-05-13-eng-99-sweep-claude-md-readme-and-docs-for-residual-tauri-references-after-architectural-changes-design.md`.

## Goal

After implement lands on the feature branch:

1. **AC#1 in tree.** `grep -in tauri CLAUDE.md README.md docs/install.md docs/assumptions.md docs/configuration.md docs/security.md docs/architecture.md` returns **0 matches**.
2. **AC#2 in tree.** Every site that previously cited `cargo` / `bun` / `npm` standalone now uses either the 4-package-manager threat list **`cargo / bun / pip / go`** (security and threat-model sites) or the 3-token build-tool / file-name set **`Cargo.toml / package.json / pyproject.toml`** (architecture diagram and build-tool sites). The locked sets come from the brainstorm §1 canonical phrasing locks.
3. **AC#3 in tree.** CLAUDE.md, README.md, docs/assumptions.md, and docs/configuration.md state the composition order using the verbatim canonical phrase **"stack-neutral base + profile-derived stack tools + operator-curated extras"** (no variants).
4. **AC#4 in tree.** `docs/architecture.md` has a new H2 **"## Discovery and the project profile"** inserted between the existing H2s "Three roots, three storage tiers" and "Harness vs target — the load-bearing distinction". `CLAUDE.md` has a new **"Where stack knowledge lives"** paragraph immediately above the existing H2 "## Per-target dispatch.tools extras and profile-derived tools (ENG-51, ENG-53 #8, ENG-94)".

Verifiable outcome: the four greps in brainstorm §6 all return their expected counts (0 for tauri tokens; 1 each for the new H2 and the new callout); `grep -in "Tauri-shaped\|isn't Tauri\|non-Tauri" CLAUDE.md README.md docs/*.md` returns 0; `bash bin/agent-prompts-content-test.sh` and `bash bin/vocabulary-cleanliness-test.sh` still pass (they scan AGENT_PROMPTS.md / CLAUDE.md for unrelated markers and are not load-bearing on the Tauri token — see Test-gate closure in §Test Strategy).

## Anti-anchoring check

- **Problem (operator's words).** "After T1–T6 land, the docs need a sweep to remove or reframe Tauri references" (Linear ENG-99 Problem Statement). The mechanism-side ENG-92 work (ENG-93/94/95/97/98) made the orchestrator stack-neutral; operator-facing prose still reads "Tauri is the default, tweak for non-Tauri" — the precise mental model the umbrella replaced. AC#1-AC#4 enumerate the four shapes of fix.
- **Brainstorm addresses it?** Yes. D-1 names the surgical rewrites for each of the seven in-scope files; D-2 adds the AC#4 callouts in CLAUDE.md and docs/architecture.md; D-3 explicitly preserves brainstorms/plans/demos/learned-rules (OUT scope); D-4 declines a doc-content test (deferred — re-evaluate if 3+ future tickets regress).
- **Proportional?** Yes. Pure prose rewrites in seven files. No `bin/*` edits. No new files (except the plan itself, which lives in `docs/plans/`). No schema bumps. No test additions. No new exit codes. No mechanism changes. The brainstorm rejected an automated `sed` pass (one site needs content rewrite, not word-swap), folding-into-mechanism-PRs (spec sequences this AFTER T1-T6), and a `docs-no-tauri-test.sh` (no doc-content test precedent today; false-positive risk on legitimate two-stack contrast).
- **No reframe; no scope creep; no escalation. PROCEED with implementation.**

## Assumption Inventory

Every code-level claim is verified against the worktree at plan time
(branch
`feat/eng-99-sweep-claude-md-readme-and-docs-for-residual-tauri-references-after-architectural-changes`,
HEAD `709b314`). **branch-base freshness: HEAD..origin/main empty at
plan time (origin/main = `c47bd88`).** No `### Task 0: Rebase` row is
required.

The 20 assumptions in the brainstorm §12 Assumption inventory are all
re-verified below by direct Read/Grep at plan-time. Assumptions specific
to file locations (Tauri-token line numbers, helper paths) are pinned
with `path:line` citations; assumptions about the absence of something
(no `docs/knowledge/decisions.md`, no `docs-*-test.sh`) are pinned by
`Glob` / `ls`-equivalent verification.

### Tauri-token residue sites (the seven in-scope files)

- **A-001 — CLAUDE.md has Tauri tokens at lines 57, 303, 314, 315, 338 (five hits; line 304 is the wrap of the 303 sentence, not a separate hit).**
  - `CLAUDE.md:57` — `| `$HOME/.bun/bin` | dispatched agent's stack tools | Bun user-global bin. Only consumed on Bun-using targets (e.g. twinning's `bun tauri build`). |`
  - `CLAUDE.md:303` — `\`bin/run-local-helpers.sh\`). The hardcoded Tauri shape (\`src-tauri/\`,` (continues onto 304: `\`crates/\`, \`bun.lock*\`) was removed in ENG-95.`)
  - `CLAUDE.md:314-325` — H3-free paragraph block opening with `**Migration from pre-ENG-95 (existing Tauri targets):**` and closing with the indented diagnostic `    Run: bash bin/setup.sh project-profile`
  - `CLAUDE.md:338` — `stack tools (\`cargo\` for Tauri, \`pytest\` for Python, \`go test\` for Go, etc.) flow from the`
  - **Status:** verified by direct Read. Task 1's edit boundaries use content anchors (e.g. "AFTER the `| Segment | Consumer | Notes |` table-header row's data row 4 (`$HOME/.bun/bin`) BEFORE row 5 (`$HOME/.npm-global/bin`)") not line numbers.

- **A-002 — README.md has Tauri tokens at lines 38, 346, 417 (three hits; lines 38-41 are one paragraph; lines 498-499 contain a `cargo build / bun install / npm install` enumeration to broaden but no literal Tauri token).**
  - `README.md:38` — `If your stack isn't Tauri, you'll need a one-time \`.pipeline-config/\``
  - `README.md:346` — `the dispatch.tools allowlist (required for non-Tauri stacks), or`
  - `README.md:417` — `- **Stack**: Default per-stage allowed-tools list is Tauri-shaped. Other`
  - `README.md:498-499` — `1. **No supply-chain isolation** — agent dispatches run \`cargo build\` /` / `   \`bun install\` / \`npm install\` against the target repo with full`
  - **Status:** verified by direct Read.

- **A-003 — docs/install.md has one Tauri token at line 184 inside the "## Phase 9: config-defaults" section.**
  - `docs/install.md:184` — `If your target stack isn't Tauri, **after this phase** you'll want to`
  - The paragraph spans lines 184-187 and ends with `This is not driven by setup; you edit \`config.json\` by hand.`
  - **Status:** verified by direct Read.

- **A-004 — docs/assumptions.md has Tauri tokens at lines 176 and 180 inside the "## Stack" section, comprising one H3 subsection ("Default allowed-tools list is Tauri-shaped") spanning lines 174-185.**
  - `docs/assumptions.md:174` — `## Stack`
  - `docs/assumptions.md:176` — `### Default allowed-tools list is Tauri-shaped`
  - `docs/assumptions.md:178-179` — `\`bin/dispatch.sh::allowed_tools_for\` ships a per-stage allowlist that / includes \`cargo\`, \`bun\`, \`rustc\`, \`node\`, \`npx\`, full \`git\`, \`jq\`, \`awk\`.`
  - `docs/assumptions.md:180` — `Any stack outside Tauri (Rust + Bun) needs an extras block in`
  - `docs/assumptions.md:184-185` — `**Failure mode:** "Agent halts with permission denied invoking pytest /` / `go test / etc." Cause: command not in allowed-tools.`
  - **Status:** verified by direct Read. The subsection ends at line 185 (blank line then H3 `### Project layout assumptions are minimal` at line 187).

- **A-005 — docs/configuration.md has Tauri tokens at lines 159, 218, 228, 285 (four hits in three distinct sections).**
  - `docs/configuration.md:155-159` — intro paragraph of "## `dispatch.tools` — per-stage allowlist extras" closing at line 159: `shaped for a Tauri (Rust + Bun + JS) target. Other stacks need extras.`
  - `docs/configuration.md:218` — table row: `| \`implementing\` | Read, Write, Edit, Grep, Glob, TaskCreate, full git family, \`cargo\`, \`bun\`, \`rustc\`, \`jq\`, \`awk\`, linear/pipeline scripts |` — feasibility note: post-ENG-94 this is wrong content, not just framing (cargo/bun/rustc are profile-derived, not built-in).
  - `docs/configuration.md:219` — table row: `| \`ui\` | Implementing's tools + \`Agent\`, \`npx\`, \`node\` |` — also wrong post-ENG-94 (npx/node are profile-derived).
  - `docs/configuration.md:220-223` — `reviewing` / `qa` / `building` / `released` table rows — **verified clean** by direct Read; `build tools` (line 221) is vague but stack-neutral.
  - `docs/configuration.md:228` — `### Adding extras for a non-Tauri stack`
  - `docs/configuration.md:230-236` — body of §"Adding extras": `Append to \`dispatch.tools.<stage>\`. The entries are merged with the / hardcoded base. Examples:` followed by `Python project`, `Go project`, `Harness self` bullets.
  - `docs/configuration.md:285` — `### Minimal (Tauri target, defaults everywhere)`
  - **Status:** verified by direct Read.

- **A-006 — docs/security.md has zero literal `Tauri` tokens; edits at lines 76/81/91 serve AC#2 (broaden cargo/bun/npm enumeration to cargo/bun/pip/go), not AC#1.**
  - `docs/security.md:76` — `**Threat**: A malicious npm/cargo/pip package in the target repo's`
  - `docs/security.md:81-83` — `**Reality today**: The agent runs \`cargo\`, \`bun\`, \`npx\`, \`node\`, \`jq\`,` / `etc. with the worktree as CWD. Any post-install script in any / dependency executes in your shell context.`
  - `docs/security.md:91-92` — `- No supply-chain isolation. The agent's \`cargo build\` can run / malicious build scripts.`
  - **Status:** verified by direct Read. Confirms `grep -i tauri docs/security.md` returns 0 today.

- **A-007 — docs/architecture.md has zero literal `Tauri` tokens; the edit at line 74 broadens the diagram-cell enumeration; the new H2 from D-2 inserts between H2 "Three roots, three storage tiers" (lines 26-44) and H2 "Harness vs target — the load-bearing distinction" (line 46).**
  - `docs/architecture.md:74` — `│  │  Cargo.toml / package.json / ...                  │      │` (inside the box-drawing diagram at lines 52-85)
  - `docs/architecture.md:26` — `## Three roots, three storage tiers`
  - `docs/architecture.md:46` — `## Harness vs target — the load-bearing distinction`
  - **Status:** verified by direct Read.

### Codebase facts the new D-2 callouts reference

- **A-008 — `bin/dispatch.sh::_dispatch_tools_from_profile` is the helper that reads the profile's `## Tool allowlist` section.**
  - Helper definition starts at `bin/dispatch.sh:318` (verified by Grep, spot-checked at plan time). Brainstorm §9 quotes it at `bin/dispatch.sh:318-401` — the function's body spans through to the next function definition.
  - **Status:** verified.

- **A-009 — `bin/dispatch.sh::allowed_tools_for` is the composition site (base + profile + extras).**
  - Function declared at `bin/dispatch.sh:403`. The case arms per stage plus the profile-call at composition tail are referenced by CLAUDE.md:344-348.
  - **Status:** verified.

- **A-010 — `bin/run-local-helpers.sh::stage_output_paths` reads the `## File layout` section from the profile (ENG-95 mechanism).**
  - Helper declared at `bin/run-local-helpers.sh:264` (verified by Grep at plan time).
  - **Status:** verified.

- **A-011 — `bin/run-local-helpers.sh::_always_include_paths` is the stack-agnostic lockfile catalog (universal across slugs).**
  - Helper declared at `bin/run-local-helpers.sh:72`; catalog spans the function body emitting `Cargo.lock`, `package-lock.json`, `bun.lock`, `poetry.lock`, `go.sum`, etc.
  - **Status:** verified.

- **A-012 — `bin/render-prompt.sh::append_project_profile` is the helper that **appends** the project profile to every non-retrospective dispatch's prompt.**
  - Helper declared at `bin/render-prompt.sh:184`. Verb is **append**, not prepend (canonical phrasing lock from brainstorm §1).
  - **Status:** verified.

- **A-013 — `bin/setup.sh::phase_project_profile` is the Phase 5b setup step that authors `learned-rules/<slug>/project-profile.md` via a one-shot discovery agent.**
  - Phase function declared at `bin/setup.sh:257`. The discovery prompt body lives at `bin/setup-prompts/discovery.md`.
  - **Status:** verified.

- **A-014 — `bin/setup-prompts/discovery.md` exists and elicits six H2 sections (Stack, Build & test gates, Tool allowlist, File layout, Language idioms, Don'ts).**
  - File path verified by Glob; contents verified in brainstorm §9 spot-check.
  - **Status:** verified.

- **A-015 — `learned-rules/<slug>/project-profile.md` currently uses `schema_version: 2` (post-ENG-93).**
  - `learned-rules/harness/project-profile.md:5` — frontmatter `schema_version: 2`.
  - **Status:** verified.

### Existing structure assumptions (informs anchor selection)

- **A-016 — CLAUDE.md "Fallback contract" subsection at lines 352-358 documents the missing-profile fallback path. It is OUT of scope for this ticket (preserved unchanged).**
  - `CLAUDE.md:352` — `**Fallback contract.** If the profile is missing, has \`schema_version != 2\`, or lacks the`
  - **Status:** verified.

- **A-017 — docs/architecture.md has no existing H2 named "Discovery" or anchor referencing the project-profile lifecycle end-to-end.**
  - Verified by `grep -n "^## " docs/architecture.md` — the 15 existing H2s are enumerated; none contain "discovery" or "profile". The new H2 from Task 7 is genuinely new content (no anchor collision).
  - **Status:** verified.

- **A-018 — CLAUDE.md has no existing "Where stack knowledge lives" callout — only the consumer-side H2 "Per-target dispatch.tools extras and profile-derived tools" at line 335.**
  - `CLAUDE.md:335` — H2 of the existing section.
  - **Status:** verified.

- **A-019 — The harness has no doc-content test today (no `docs-*-test.sh` in `bin/`); `bin/agent-prompts-content-test.sh:161`'s `grep -qiF -- 'tauri' "$PROMPTS"` operates on AGENT_PROMPTS.md (the `$PROMPTS` variable), NOT the in-scope docs — so this sweep does NOT affect that test's outcome.**
  - Verified by Glob `bin/docs-*-test.sh` (zero hits) and by Grep — `agent-prompts-content-test.sh:161`'s match operates on the AGENT_PROMPTS.md scope.
  - **Status:** verified.

- **A-020 — `bin/profile-allowlist-test.sh` mentions "Tauri" only in its own header comments (lines 7, 19, 114); it does NOT grep CLAUDE.md or docs/* for Tauri tokens.**
  - Verified by Grep: `bin/profile-allowlist-test.sh:7`, `:19`, `:114` are all `# ...` comment lines describing the test's history, not test assertions.
  - **Status:** verified. Test-gate closure: this test does NOT trip if Tauri is removed from the in-scope docs. (Its own comments may someday warrant a clean-up — explicitly OUT of scope per the ticket's `OUT: docs/brainstorms/, docs/plans/, docs/demos/, learned-rules/` boundary plus the implicit "bin/* is OUT" — this ticket only touches docs.)

- **A-021 — `bin/vocabulary-cleanliness-test.sh` scans CLAUDE.md for legacy `<!-- pipeline-X: ... -->` shapes only; it does NOT grep CLAUDE.md for Tauri tokens.**
  - Verified by Read: `bin/vocabulary-cleanliness-test.sh:36` defines `LEGACY_RE='<!-- pipeline-(stage-summary|rejection|...):` — the regex is on vocabulary markers, not stack tokens.
  - **Status:** verified. Test-gate closure: removing Tauri tokens from CLAUDE.md does NOT trip this test.

- **A-022 — `bin/run-local-content-adversarial-test.sh` does substring-match CLAUDE.md for the ENG-67 die-message phrase, NOT for any Tauri token (line 80's "whole-phrase" check is on the die-message string, not on `tauri`).**
  - Verified by Grep: zero hits for `tauri|Tauri|cargo|bun` in `bin/run-local-content-adversarial-test.sh`.
  - **Status:** verified. Test-gate closure: removing Tauri tokens from CLAUDE.md does NOT trip this test.

- **A-023 — `bin/scope-check-test.sh` uses `CLAUDE.md` only as a per-test fixture filename at the test's CWD root (e.g. `printf 'baseline\n' > CLAUDE.md`); it does NOT grep the actual harness `CLAUDE.md`.**
  - Verified by Grep: all 16 hits for `CLAUDE.md` in `bin/scope-check-test.sh` are either plan-fixture content (mock plan-doc bullets) or test-fixture file writes.
  - **Status:** verified. Test-gate closure: removing Tauri tokens from the harness `CLAUDE.md` does NOT trip this test.

### Non-existence assertions

- **A-024 — `docs/knowledge/` (no `decisions.md`, `gotchas.md`, `conventions.md`) does not exist; `docs/VISION.md` does not exist; `learned-rules/harness/plan.md` does not exist.**
  - Verified by Glob: `docs/` lists `architecture.md assumptions.md brainstorms/ configuration.md cost.md demos/ install.md operations.md pipeline-vocabulary.md pipeline-vocabulary.template.md plans/ runbooks/ security.md` — no `knowledge/` subdir, no `VISION.md`. `learned-rules/harness/` contains only `build.md` and `project-profile.md`.
  - **Status:** verified. The prompt's "read these files if present" list correctly resolves to: only CLAUDE.md and the brainstorm doc need reading at plan time (steps 2/4/5/6/7 are no-ops).

### Branch-base freshness pin

- **A-025 — `git log --oneline HEAD..origin/main` returns empty at plan time.**
  - `origin/main = c47bd88` (verified via `git rev-parse origin/main`).
  - HEAD = `709b314 chore(pipeline): brainstorming for ENG-99`.
  - **Status:** verified. **No `Task 0: Rebase onto origin/main` is required.** Every `path:line` recorded above survives plan-time freshness; the implement agent SHOULD still Grep for the literal token text (per brainstorm §5 "Line-number caveat") rather than blindly trusting line numbers, because adjacent unmerged work or a late drive-by could shift them between plan-time and implement-time.

## File Structure

All seven files are **modified**; no new files.

- `CLAUDE.md` — modified (lines 57, 303-304, 314-325 [delete], new "Where stack knowledge lives" callout before line 335, line 338); 5 edit hunks across 5 content anchors.
- `README.md` — modified (lines 38-41, 346, 417-419, 498-501); 4 edit hunks across 4 content anchors.
- `docs/install.md` — modified (lines 184-187, one paragraph rewrite); 1 edit hunk.
- `docs/assumptions.md` — modified (lines 174-185, full H3 subsection rewrite + concrete Python `## Tool allowlist` snippet); 1 edit hunk.
- `docs/configuration.md` — modified (lines 155-159 intro, lines 218-219 table rows, line 228 heading + body, line 285 heading); 4 edit hunks across 4 content anchors.
- `docs/security.md` — modified (lines 76, 81-83, 91-92); 3 edit hunks across 3 content anchors. Serves AC#2 only (zero literal `Tauri` tokens; the file is not in AC#1's grep target list strictly speaking, but the spec's IN-scope list includes it).
- `docs/architecture.md` — modified (line 74 diagram cell + new H2 "## Discovery and the project profile" between lines 44 and 46); 2 edit hunks across 2 content anchors.

No `bin/*` files touched. No `learned-rules/<slug>/*` files touched. No `docs/brainstorms/`, `docs/plans/`, `docs/demos/` files touched. No test additions. No schema changes.

## API Contract

no new API surface

## Backend Tasks

### Task 1: Rewrite CLAUDE.md Tauri residues + add "Where stack knowledge lives" callout

- `depends_on: []`
- `touches: CLAUDE.md` (5 edit hunks; lines 57, 303-304, 314-325, ~333 area, 338)
- [ ] **Hunk 1 (line 57, PATH-table row).** In the table under H2 "## PATH expectations on the launchd host", locate the row whose first column is `` `$HOME/.bun/bin` `` (currently line 57). Replace its third column text:
  - FROM: ``Bun user-global bin. Only consumed on Bun-using targets (e.g. twinning's `bun tauri build`).``
  - TO: ``Bun user-global bin. Only consumed on Bun-using targets.``
  - Content anchor: AFTER the table-header row `| Segment | Consumer | Notes |` AFTER the row whose first column is `` `/usr/local/bin`, `/usr/local/sbin` `` BEFORE the row whose first column is `` `$HOME/.npm-global/bin` ``.

- [ ] **Hunk 2 (lines 303-304, sweep+scope paragraph).** Inside H2 "## Sweep + scope partition (ENG-14)", locate the paragraph starting `The `implementing | ui | qa` allowlist is derived from` (currently at line 298) and ending at the sentence `was removed in ENG-95.` (currently line 304). Replace the trailing sentence:
  - FROM: ``The hardcoded Tauri shape (`src-tauri/`, `crates/`, `bun.lock*`) was removed in ENG-95.``
  - TO: ``The profile is the canonical source of stack-specific paths; the catalog is universal across slugs.``
  - Content anchor: AFTER the literal substring `` see `_always_include_paths` in `` BEFORE the H2 "**Where to make scope changes (decision tree):**" header line.

- [ ] **Hunk 3 (lines 314-325, delete Migration paragraph entirely).** Delete the contiguous block opening with the bold-header line `**Migration from pre-ENG-95 (existing Tauri targets):**` and ending with the indented code block's last line `    Run: bash bin/setup.sh project-profile` plus the trailing blank line. The next non-blank line MUST be `**Always-include lockfile catalog scope.**` (currently line 326).
  - Content anchor: BEFORE the bold-header line `**Always-include lockfile catalog scope.**`; the deletion span begins at the preceding occurrence of `**Migration from pre-ENG-95 (existing Tauri targets):**`. Net effect: 12-line block removed; the "Always-include lockfile catalog scope" paragraph now follows directly after the "Where to make scope changes" decision-tree table.

- [ ] **Hunk 4 (new callout before H2 line 335).** Insert a new paragraph immediately BEFORE the H2 `## Per-target dispatch.tools extras and profile-derived tools (ENG-51, ENG-53 #8, ENG-94)`. The paragraph uses the canonical "append" verb (per brainstorm §1 verb lock):

  ```markdown
  **Where stack knowledge lives.** The per-slug project profile at
  `$HARNESS_ROOT/learned-rules/<slug>/project-profile.md` is the canonical
  source of stack truth. It is authored by a one-shot discovery agent
  during setup (`bash bin/setup.sh /path project-profile`) and consumed
  by three sites: `dispatch.sh::_dispatch_tools_from_profile` (reads
  `## Tool allowlist`), `run-local-helpers.sh::stage_output_paths`
  (reads `## File layout` for the scope sweep), and
  `render-prompt.sh::append_project_profile` (appends the entire
  profile to every non-retrospective dispatch's prompt). Missing-or-
  malformed profile → stack-neutral fallback + warning, never `die`.
  See docs/architecture.md "Discovery and the project profile" for
  the full lifecycle.
  ```

  - Content anchor: AFTER the closing line of the preceding paragraph (`If this is too broad for your repo, set \`config.json::scope.allowlist.<stage>[]\` to a tighter list.`) BEFORE the H2 `## Per-target dispatch.tools extras and profile-derived tools (ENG-51, ENG-53 #8, ENG-94)`.
  - **MUST NOT** add the callout as an H2 — it is a bold-prefixed paragraph (`**Where stack knowledge lives.** …`) per brainstorm D-2, so the existing H2 structure of CLAUDE.md is unchanged.

- [ ] **Hunk 5 (line 338, "cargo for Tauri" → "cargo for Rust").** In the second paragraph of the H2 "## Per-target dispatch.tools extras and profile-derived tools (ENG-51, ENG-53 #8, ENG-94)", change the literal token:
  - FROM: ``stack tools (`cargo` for Tauri, `pytest` for Python, `go test` for Go, etc.) flow from the``
  - TO: ``stack tools (`cargo` for Rust, `pytest` for Python, `go test` for Go, etc.) flow from the``
  - Content anchor: AFTER the H2 line `## Per-target dispatch.tools extras and profile-derived tools (ENG-51, ENG-53 #8, ENG-94)` AFTER the first paragraph's closing sentence ending `each stage.` BEFORE the literal substring `project profile's `## Tool allowlist` section`.

- [ ] **Post-task verification:** Run `grep -in tauri CLAUDE.md` — MUST return 0 hits. Run `grep -in "Where stack knowledge lives" CLAUDE.md` — MUST return 1 hit. Run `grep -n "^## " CLAUDE.md | wc -l` — MUST return the same count as before (no H2 added or removed; the new callout is a bold-prefixed paragraph).

### Task 2: Rewrite README.md Tauri residues + softened opener + 4-package-manager threat list

- `depends_on: []`
- `touches: README.md` (4 edit hunks; lines 38-41, 346, 417-419, 498-501)
- [ ] **Hunk 1 (lines 38-41, "If your stack isn't Tauri" block, softened opener).** Locate the standalone paragraph starting `If your stack isn't Tauri,` (currently line 38) and ending `your target repo already has.` (line 41). Replace the entire 4-line paragraph with the softened-opener block:

  ```markdown
  The harness is stack-agnostic. The first-time setup (`bash bin/setup.sh
  /path`) discovers your target's stack and writes a per-target profile
  that the orchestrator reads at dispatch time. The agents then run
  whatever build/test commands your target already uses.
  → See [docs/architecture.md "Discovery and the project profile"](docs/architecture.md#discovery-and-the-project-profile)
  for the full lifecycle.
  ```

  - Content anchor: AFTER the bullet `- "Set it and forget it" expectations — you remain the operator-in-the-loop` (the closing bullet of the "Not the right fit if" list) AFTER its continuation line `  for halts, scope-approvals, and review` BEFORE the H2 `## How it works`.

- [ ] **Hunk 2 (line 346, "required for non-Tauri stacks" → operator-curated extras).** In the paragraph starting `Most operators only edit \`config.json\` for:` (line 344), change the middle clause:
  - FROM: ``the dispatch.tools allowlist (required for non-Tauri stacks), or``
  - TO: ``the dispatch.tools allowlist (operator-curated extras on top of the profile-derived list), or``
  - Content anchor: AFTER the literal substring `the default 30 min cap fires SIGTERM during legitimate persona-review work),` BEFORE the literal substring `entry-conditions (cost-recovery on build).`.

- [ ] **Hunk 3 (lines 417-419, Stack assumption rewrite with canonical phrasing).** Locate the bullet `- **Stack**: Default per-stage allowed-tools list is Tauri-shaped. Other` (currently line 417) and its continuation through line 419 (`block.`). Replace the entire 3-line bullet with:

  ```markdown
  - **Stack**: Per-stage allowed-tools is composed of **stack-neutral
    base + profile-derived stack tools + operator-curated extras**.
    The profile (`learned-rules/<slug>/project-profile.md::## Tool
    allowlist`) is authored by the discovery agent during setup; the
    extras (`.pipeline-config/config.json::dispatch.tools`) are
    operator-curated. Adding a new target runs discovery (Phase 5b)
    to populate the profile.
  ```

  - Content anchor: AFTER the bullet `- **Auth**: Claude subscription session on the host — \`ANTHROPIC_API_KEY\` is` AFTER its continuation `  intentionally never set.` BEFORE the line `→ See [\`docs/assumptions.md\`](docs/assumptions.md) for the full list with`.

- [ ] **Hunk 4 (lines 498-501, supply-chain threat — 4-package-manager broadening).** Locate the numbered bullet `1. **No supply-chain isolation** —` (currently line 498) and its continuation through `   shell context.` (line 501). Replace with:

  ```markdown
  1. **No supply-chain isolation** — agent dispatches run your target's
     package-manager commands (e.g. `cargo build`, `bun install`,
     `pip install`, `go build`) against the target repo with full
     filesystem access. Malicious post-install scripts execute in your
     shell context.
  ```

  - Content anchor: AFTER the bullet list opener `**Highest-impact gaps in the current threat model**:` BEFORE the second numbered bullet `2. **No prompt-injection filtering on Linear issue bodies** —`.

- [ ] **Post-task verification:** Run `grep -in tauri README.md` — MUST return 0 hits. Run `grep -in "stack-neutral base + profile-derived stack tools + operator-curated extras" README.md` — MUST return 1 hit. Run `grep -in "cargo build" README.md` — MUST return 1 hit (the broadened threat example).

### Task 3: Reframe docs/install.md Phase 9 paragraph to point at Phase 5b

- `depends_on: []`
- `touches: docs/install.md` (1 edit hunk; lines 184-187)
- [ ] **Hunk 1 (lines 184-187, Phase 9 → Phase 5b reframe).** Locate the 4-line paragraph starting `If your target stack isn't Tauri, **after this phase** you'll want to` (currently line 184) and ending `This is not driven by setup; you edit \`config.json\` by hand.` (line 187). Replace with:

  ```markdown
  Phase 5b (`project-profile`) populates the per-stage Tool allowlist
  for your target's stack. If you need additional operator-curated
  tools on top of the profile-derived list (e.g. enumerated
  `bin/*-test.sh` entries for harness-self), add them to
  `dispatch.tools` per
  [`configuration.md`](configuration.md#dispatchtools--per-stage-allowlist-extras).
  This is not driven by setup; you edit `config.json` by hand.
  ```

  - Content anchor: AFTER the paragraph closing `per-stage-timeout and entry-conditions defaults land.` BEFORE the H2 `## Phase 10: validate`.

- [ ] **Post-task verification:** Run `grep -in tauri docs/install.md` — MUST return 0 hits. Run `grep -n "^## Phase " docs/install.md` — MUST be unchanged (no H2 added/removed).

### Task 4: Rewrite docs/assumptions.md "## Stack" subsection with canonical phrasing + concrete Python snippet

- `depends_on: []`
- `touches: docs/assumptions.md` (1 edit hunk spanning H3 + body; lines 174-185)
- [ ] **Hunk 1 (lines 174-185, whole H3 subsection rewrite).** Locate the H3 `### Default allowed-tools list is Tauri-shaped` (currently line 176) and its body through line 185 (`Cause: command not in allowed-tools.`). Replace the H3 header and the entire body with:

  ```markdown
  ### Per-stage allowed-tools is composed, not hardcoded

  The argv composition is **stack-neutral base + profile-derived stack
  tools + operator-curated extras**:

  - **Stack-neutral base** — `bin/dispatch.sh::allowed_tools_for` ships
    a stack-agnostic per-stage allowlist: Read/Write/Edit/Grep/Glob,
    the git family, `jq`, `awk`, `bash bin/linear.sh`,
    `bash bin/pipeline.sh`, etc. No language-specific tokens.
  - **Profile-derived stack tools** — `learned-rules/<slug>/project-profile.md`
    carries a `## Tool allowlist` section authored by the discovery
    agent (`bash bin/setup.sh /path project-profile`, Phase 5b). The
    section is per-stage. Example for a Python target's `implementing`:

    ```markdown
    ## Tool allowlist

    - implementing:
      - `Bash(pytest:*)`
      - `Bash(python:*)`
      - `Bash(ruff:*)`
      - `Bash(mypy:*)`
    - qa:
      - `Bash(pytest:*)`
      - `Bash(ruff:*)`
    ```
  - **Operator-curated extras** — `.pipeline-config/config.json::dispatch.tools.<stage>[]`
    appends per-target one-offs (e.g. the harness-self target's
    enumerated `bin/*-test.sh` patterns) on top of the profile.

  See [`configuration.md`](configuration.md#dispatchtools--per-stage-allowlist-extras)
  for the full composition rules and the wildcard pitfall.

  **Failure mode:** "Agent halts with permission denied invoking pytest /
  go test / etc." Cause: the project profile's `## Tool allowlist`
  section is missing those entries — re-run discovery
  (`bash bin/setup.sh /path project-profile`) or hand-edit the profile.
  ```

  - Content anchor: AFTER the H2 `## Stack` (line 174) BEFORE the H3 `### Project layout assumptions are minimal` (currently line 187). The replacement preserves the H3 placement (one H3 in, one H3 out) so the file's outline shape is unchanged.
  - **Critical:** The Python `## Tool allowlist` example uses a nested fenced markdown block. The implement agent MUST use a 4-space-indented fenced block (or a tilde-delimited fence) per the brainstorm's literal nested-fence rendering; opening with the same triple-backtick shape inside the outer block will close the outer fence early. Use indented-by-4-spaces inner content (as shown above) — markdown renders the indented block as a code block without needing inner fences.

- [ ] **Post-task verification:** Run `grep -in tauri docs/assumptions.md` — MUST return 0 hits. Run `grep -n "^### " docs/assumptions.md` — the count under "## Stack" MUST be unchanged (one H3 in, one H3 out — `### Per-stage allowed-tools is composed, not hardcoded` replaces `### Default allowed-tools list is Tauri-shaped`). Run `grep -in "stack-neutral base + profile-derived stack tools + operator-curated extras" docs/assumptions.md` — MUST return ≥1 hit.

### Task 5: Rewrite docs/configuration.md Tauri residues (intro, table, heading, examples, heading)

- `depends_on: []`
- `touches: docs/configuration.md` (4 edit hunks; lines 155-159, 218-219, 228-236, 285)
- [ ] **Hunk 1 (lines 155-159, §"`dispatch.tools` — per-stage allowlist extras" intro).** Locate the H2 `## \`dispatch.tools\` — per-stage allowlist extras <a id="dispatchtools--per-stage-allowlist-extras"></a>` (line 155) and the paragraph immediately after it ending `Other stacks need extras.` (line 159). Replace the paragraph with:

  ```markdown
  Every `claude -p` invocation passes `--allowed-tools <comma-list>`.
  The composition is **stack-neutral base + profile-derived stack tools
  + operator-curated extras**:

  - **stack-neutral base** — from `bin/dispatch.sh::allowed_tools_for`'s
    per-stage case arm. No language-specific tokens.
  - **profile-derived stack tools** — from `learned-rules/<slug>/project-profile.md::## Tool allowlist`,
    authored by the discovery agent.
  - **operator-curated extras** — from `.pipeline-config/config.json::dispatch.tools.<stage>[]`,
    for per-target one-offs that don't belong in the canonical profile.

  Per-target stack tools are declared by the project profile, not
  hardcoded here.
  ```

  - Content anchor: AFTER the H2 line `## \`dispatch.tools\` — per-stage allowlist extras <a id="dispatchtools--per-stage-allowlist-extras"></a>` BEFORE the H3 `### The wildcard pitfall`.

- [ ] **Hunk 2 (lines 218-219, table rows for `implementing` and `ui`).** Inside the markdown table opened at line 214 with header `| Stage | Built-in tools (abbreviated) |`, replace exactly two rows:
  - FROM line 218: `| \`implementing\` | Read, Write, Edit, Grep, Glob, TaskCreate, full git family, \`cargo\`, \`bun\`, \`rustc\`, \`jq\`, \`awk\`, linear/pipeline scripts |`
  - TO: `| \`implementing\` | Read, Write, Edit, Grep, Glob, TaskCreate, full git family, \`jq\`, \`awk\`, linear/pipeline scripts. Stack tools come from \`learned-rules/<slug>/project-profile.md::## Tool allowlist\`. |`
  - FROM line 219: `| \`ui\` | Implementing's tools + \`Agent\`, \`npx\`, \`node\` |`
  - TO: `| \`ui\` | Implementing's stack-neutral base + \`Agent\`. Stack tools (\`npx\`, \`node\`, etc.) come from the project profile. |`
  - Content anchor: AFTER the row `| \`planning\` | Read, Write, Edit, Grep, Glob, TaskCreate, \`git log/diff\`, linear/pipeline scripts |` BEFORE the row `| \`reviewing\` | Read, Write, Grep, Glob, TaskCreate, Agent, \`gh pr view/diff/list/review/comment\`, \`gh issue create\`, linear/pipeline/guards scripts |`.
  - **MUST NOT** modify the `reviewing`, `qa`, `building`, `released` rows (verified clean per A-005).

- [ ] **Hunk 3 (line 228 heading + body lines 230-236, "Adding extras for a non-Tauri stack" → "Adding operator-curated extras" + broadened examples).** Replace the H3 heading and the example-bullet block beneath it:
  - FROM line 228: `### Adding extras for a non-Tauri stack`
  - TO: `### Adding operator-curated extras`
  - FROM lines 230-231: `Append to \`dispatch.tools.<stage>\`. The entries are merged with the / hardcoded base. Examples:`
  - TO:

    ```markdown
    Append to `dispatch.tools.<stage>`. The entries are merged with the
    stack-neutral base AND the profile-derived stack tools. The profile
    is the canonical place to declare stack tools (run discovery to
    populate); `dispatch.tools.<stage>` extras are for **operator-curated
    additions** on top — typically per-test-script enumeration or
    per-target one-offs. Examples:
    ```

  - FROM lines 233-236 (the three example bullets):
    ```
    - **Python project** — add `Bash(pytest:*)`, `Bash(python:*)`, `Bash(ruff:*)`,
      `Bash(mypy:*)` to `implementing` and `qa`.
    - **Go project** — add `Bash(go:*)`, `Bash(gofmt:*)`, `Bash(golangci-lint:*)`.
    - **Harness self** — add the full enumerated `bin/*-test.sh` list (above).
    ```
  - TO (per brainstorm — the Python/Go examples are dropped because they belong in the **profile**, not in operator-curated extras; the Harness-self bullet stays; a new generic example bullet replaces the two stack-specific ones):
    ```
    - **Additional dev-tool patterns not declared in the profile** — for
      example, a per-target one-off `Bash(./scripts/migrate:*)` that doesn't
      belong in the canonical profile.
    - **Harness self** — add the full enumerated `bin/*-test.sh` list (above).
    ```
  - Content anchor: AFTER the closing line of the table at line 226 (`date back to ENG-23 — both shapes are accepted for backwards-compat.`) BEFORE the H2 `## \`secrets.env\``.

- [ ] **Hunk 4 (line 285, "Minimal (Tauri target…)" heading).** Replace:
  - FROM: `### Minimal (Tauri target, defaults everywhere)`
  - TO: `### Minimal (defaults everywhere)`
  - Content anchor: AFTER the H2 `## Examples` BEFORE the JSON code-fence opening `\`\`\`json` and its sibling H3 `### Tightened timeouts (cost-bound)`.

- [ ] **Post-task verification:** Run `grep -in tauri docs/configuration.md` — MUST return 0 hits. Run `grep -in "stack-neutral base + profile-derived stack tools + operator-curated extras" docs/configuration.md` — MUST return ≥1 hit. Run `grep -n "^### " docs/configuration.md` — the count MUST be unchanged (one H3 swapped in §"Adding extras", one H3 swapped in §"Examples — Minimal").

### Task 6: Broaden docs/security.md cargo/bun/npm enumerations to 4-package-manager set (AC#2 only)

- `depends_on: []`
- `touches: docs/security.md` (3 edit hunks; lines 76, 81-83, 91-92)
- [ ] **Hunk 1 (line 76, "## A2. Compromised target dependency" → Threat sentence).** Replace the first sentence of the **Threat** paragraph:
  - FROM: `**Threat**: A malicious npm/cargo/pip package in the target repo's`
  - TO: `**Threat**: A malicious dependency from any package ecosystem (cargo, bun, pip, go) in the target repo's`
  - Content anchor: AFTER the H3 `### A2. Compromised target dependency` BEFORE the literal substring `build runs in the agent's worktree, with full write access to that`.

- [ ] **Hunk 2 (lines 81-83, **Reality today** sentence — drop test-runners `node`, `jq`; lock to 4-package-manager list).** Replace the 3-line **Reality today** paragraph:
  - FROM:
    ```
    **Reality today**: The agent runs `cargo`, `bun`, `npx`, `node`, `jq`,
    etc. with the worktree as CWD. Any post-install script in any
    dependency executes in your shell context.
    ```
  - TO:
    ```
    **Reality today**: The agent runs your target's package-manager
    commands (e.g. `cargo build`, `bun install`, `pip install`,
    `go build`) with the worktree as CWD. Any post-install script in
    any dependency executes in your shell context.
    ```
  - Content anchor: AFTER the empty line that closes the **Threat** paragraph BEFORE the **Mitigations in place** bold-header line.

- [ ] **Hunk 3 (lines 91-92, "No supply-chain isolation" bullet under **Mitigations NOT in place**).** Replace the 2-line bullet:
  - FROM:
    ```
    - No supply-chain isolation. The agent's `cargo build` can run
      malicious build scripts.
    ```
  - TO:
    ```
    - No supply-chain isolation. The agent's package-manager invocations
      (e.g. `cargo build`, `bun install`, `pip install`, `go build`)
      can run malicious build scripts.
    ```
  - Content anchor: AFTER the bold-header `**Mitigations NOT in place**:` BEFORE the bullet `- No sandbox / firejail / Docker isolation around dispatches.`.

- [ ] **Post-task verification:** Run `grep -in tauri docs/security.md` — MUST return 0 hits (already 0 today; verifies that the broadening did not introduce a stray token). Run `grep -in "cargo build" docs/security.md` — MUST return exactly 2 hits (Hunks 2 and 3 above). Run `grep -in "pytest\|jq" docs/security.md` — MUST NOT return any hits in the **Threat / Reality today / Mitigations** block of A2 (test-runners dropped from supply-chain enumeration per brainstorm coherence-persona P1 fold).

### Task 7: Broaden docs/architecture.md diagram cell + add new "## Discovery and the project profile" H2

- `depends_on: []`
- `touches: docs/architecture.md` (2 edit hunks; line 74 diagram cell + new H2 between lines 44 and 46)
- [ ] **Hunk 1 (line 74, box-drawing diagram cell broadening).** Inside the box-drawing block opened at line 52 (` ┌─ Host machine (your Mac) ──...┐`), replace the single line:
  - FROM: `│  │  Cargo.toml / package.json / ...                  │      │`
  - TO: `│  │  Cargo.toml / package.json / pyproject.toml / ... │      │`
  - **Critical — width preservation.** The box-drawing diagram uses Unicode box-drawing characters and depends on every line having the same visual width. The replacement string MUST occupy the same visual column count as the original (counted by display-width, not byte count). The brainstorm's proposed line preserves the trailing `│      │` column alignment by shortening the inter-cell whitespace. The implement agent MUST visually inspect the rendered diagram after the edit to confirm no column drift; if drift occurs, adjust inter-cell whitespace to restore alignment.
  - Content anchor: AFTER the line `│  │  tests/                                             │      │` (line 73) BEFORE the line `│  │  .pipeline-config/                                │      │` (line 75).

- [ ] **Hunk 2 (insert new H2 between lines 44 and 46).** Insert a new H2 section between the H2 "## Three roots, three storage tiers" (which closes at line 44 with the bullet ending `writes go here, not to \`config.json\``) and the H2 "## Harness vs target — the load-bearing distinction" (line 46). The new H2 + body:

  ```markdown
  ## Discovery and the project profile

  The orchestrator is stack-neutral. Per-target stack knowledge lives in
  `$HARNESS_ROOT/learned-rules/<slug>/project-profile.md` — a markdown
  file with a YAML frontmatter `schema_version: 2` and six H2 sections
  (Stack, Build & test gates, Tool allowlist, File layout, Language
  idioms, Don'ts).

  The profile is authored by a **one-shot discovery agent** run via
  `bash bin/setup.sh /path/to/target project-profile` (Phase 5b of
  setup). The discovery prompt at `bin/setup-prompts/discovery.md` walks
  the target's manifests, `.github/workflows/`, and dotfiles to elicit
  the six sections. The result is checked into the harness repo (NOT
  the target) under `learned-rules/<slug>/`.

  The profile drives three things:

  | Consumer | Reads | Effect |
  |---|---|---|
  | `bin/dispatch.sh::_dispatch_tools_from_profile` | `## Tool allowlist` | Per-stage `--allowed-tools` argv composition (the profile-derived middle tier of **stack-neutral base + profile-derived stack tools + operator-curated extras**) |
  | `bin/run-local-helpers.sh::stage_output_paths` | `## File layout` | Per-stage scope allowlist for the post-dispatch sweep |
  | `bin/render-prompt.sh::append_project_profile` | Entire file | Appended to every non-retrospective dispatch's prompt |

  If a profile is missing or its schema is wrong, dispatch falls back to
  **stack-neutral base + operator-curated extras** (the middle tier
  drops out) and emits one `[allowed-tools]` warning per stage to
  stderr. The target keeps working on the universal lockfile catalog +
  `docs/` scope allowlist (see Sweep + scope partition below) until the
  operator re-runs discovery.

  The profile is the canonical source of stack truth. To change the
  stack (add a manifest, swap a test runner), edit the profile and
  commit; the next dispatch picks it up automatically.
  ```

  - Content anchor: AFTER the closing line of "## Three roots, three storage tiers" — specifically the line `  for \`orchestrator.paused\`; writes go here, not to \`config.json\`` (line 44) PLUS the blank line that follows it — BEFORE the H2 `## Harness vs target — the load-bearing distinction` (line 46).
  - **Markdown-anchor freshness.** The README.md "Hunk 1" forward-link reads `[docs/architecture.md "Discovery and the project profile"](docs/architecture.md#discovery-and-the-project-profile)`. The implicit anchor `#discovery-and-the-project-profile` derives from the H2 text; markdown renderers lower-case the slug and replace spaces with hyphens. Verify after Task 7 lands that the link from README.md (Task 2 Hunk 1) resolves — if any markdown renderer normalises the slug differently (e.g. dropping `and`), the H2 may need an explicit `<a id="discovery-and-the-project-profile"></a>` (the file already uses this pattern at line 235 for `<a id="failure-taxonomy"></a>`). Add the explicit anchor only if the implicit slug fails to resolve.

- [ ] **Post-task verification:** Run `grep -in tauri docs/architecture.md` — MUST return 0 hits (already 0 today; verifies no stray token slipped in). Run `grep -n "^## Discovery and the project profile" docs/architecture.md` — MUST return 1 hit. Run `grep -n "^## " docs/architecture.md | wc -l` — MUST return the previous count plus 1 (one new H2 added). Run `grep -in pyproject.toml docs/architecture.md` — MUST return ≥1 hit (the diagram cell).

### Task 8: Final sweep verification (AC#1-AC#4 closure)

- `depends_on: [1, 2, 3, 4, 5, 6, 7]`
- `touches: (read-only verification across all seven files)`
- [ ] **AC#1 — Tauri-zero invariant.** Run the literal one-liner:
  ```bash
  grep -in tauri CLAUDE.md README.md docs/install.md docs/assumptions.md docs/configuration.md docs/security.md docs/architecture.md
  ```
  MUST return 0 hits (exit code 1 from grep). Any non-zero return is a TASK-FAILED-RETRY: locate the surviving token and apply the relevant Hunk's rewrite.

- [ ] **AC#2 — concrete multi-stack example invariant.** Run:
  ```bash
  grep -in "cargo build" README.md docs/security.md
  grep -in "pyproject.toml" docs/architecture.md docs/assumptions.md
  ```
  Each MUST return ≥1 hit. (Expected: README.md:498 area; docs/security.md:81 + :91 area; docs/architecture.md:74 + the new H2 table; docs/assumptions.md:174 area.)

- [ ] **AC#3 — composition-order canonical phrasing.** Run:
  ```bash
  grep -in "stack-neutral base + profile-derived stack tools + operator-curated extras" \
    CLAUDE.md README.md docs/assumptions.md docs/configuration.md
  ```
  MUST return ≥1 hit per file (4 files × ≥1 = ≥4 total).

- [ ] **AC#4 — discovery-flow callouts present.** Run:
  ```bash
  grep -n "^## Discovery and the project profile" docs/architecture.md
  grep -n "Where stack knowledge lives" CLAUDE.md
  ```
  Each MUST return exactly 1 hit.

- [ ] **Sibling-test smoke.** Run:
  ```bash
  bash bin/agent-prompts-content-test.sh
  bash bin/vocabulary-cleanliness-test.sh
  bash bin/run-local-content-adversarial-test.sh
  bash bin/scope-check-test.sh
  bash bin/profile-allowlist-test.sh
  ```
  Each MUST exit 0. (Confirms Test-gate closure: none of these tests load-bears on the Tauri token in the in-scope docs — see A-019 through A-023.)

- [ ] **Anchor-resolution smoke (manual).** Open `README.md` in a markdown renderer and click the `[docs/architecture.md "Discovery and the project profile"](docs/architecture.md#discovery-and-the-project-profile)` forward-link added by Task 2 Hunk 1; verify it scrolls to the new H2 added by Task 7 Hunk 2. If the implicit anchor does not resolve, return to Task 7 Hunk 2 and add the explicit `<a id="discovery-and-the-project-profile"></a>`.

## Frontend Tasks

no frontend surface

## Failure Mode → Test Map

The brainstorm's D-4 deliberately declines a doc-content regression test. The failure modes below are bound to the manual / grep-based verification steps that the brainstorm §6 documents and that Task 8 codifies. "Test layer" reflects the actual verification mechanism (smoke = automated one-liner gate; manual = reviewer-pass during PR review).

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
|---|---|---|---|---|
| Tauri token slips back into an in-scope file (regression or partial implementation) | `grep -in tauri <files>` returns >0 hits after implement lands | Task 8 AC#1 invariant fails; implement TASK-FAILED-RETRY routes back to the Hunk that left a residue | smoke (one-liner gate) | Task 8 AC#1 `grep -in tauri` invariant |
| Multi-stack-contrast tokens drift from canonical set (e.g. someone writes `cargo / bun / npm` instead of `cargo / bun / pip / go` in a threat site) | A reviewer or follow-up edit re-introduces `npm` or `node` into a §"## A2. Compromised target dependency"-shaped paragraph | Reviewer catches via prose review; brainstorm §1 canonical phrasing lock is the source of truth | manual | docs/security.md §A2 prose review (PR-time) |
| Composition-order phrasing diverges across files (e.g. CLAUDE.md says "extras" but docs/configuration.md says "additions") | A future ENG-XX edits one file but not its peers | Reviewer catches via cross-file consistency check; the canonical phrase from §1 is the verbatim string Task 8 AC#3 greps | smoke (one-liner gate) | Task 8 AC#3 `grep -in "stack-neutral base + ..."` invariant |
| Discovery callout missing in CLAUDE.md or docs/architecture.md | Task 4 / Task 7 only partially applied | Task 8 AC#4 invariant fails; the two greps return < 1 hit each | smoke (one-liner gate) | Task 8 AC#4 callout-presence grep |
| Diagram-cell width drift (Task 7 Hunk 1 broke alignment of `│      │` columns) | Implement agent replaced the cell text without preserving display-width | Visual misalignment in `docs/architecture.md:74` area; reviewer's eye catches at PR diff review | manual | docs/architecture.md diagram-render PR review |
| Forward-link `docs/architecture.md#discovery-and-the-project-profile` (added by Task 2 Hunk 1) fails to resolve to the new H2 | Implicit slug differs from the H2's slugified form on the rendered site (rare edge case) | Anchor-resolution smoke step in Task 8 fails; implement adds explicit `<a id="..."></a>` to Task 7 Hunk 2's H2 | manual | Task 8 anchor-resolution smoke (manual click) |
| Nested fenced markdown block in docs/assumptions.md Task 4 Hunk 1 closes the outer fence early | Implement agent used triple-backtick for the inner Python `## Tool allowlist` example | Markdown renders the rest of the file as code; reviewer's eye catches at PR diff review | manual | docs/assumptions.md PR-render review |
| `## Stack` H3 count under docs/assumptions.md changes (extra H3 inserted, or H3 dropped without replacement) | Task 4 Hunk 1's "one in, one out" invariant violated | `grep -n "^### " docs/assumptions.md` shows different count than pre-edit | smoke (one-liner gate) | Task 4 Hunk 1 post-task verification |
| Sibling test regression from doc edits (e.g. `bin/scope-check-test.sh` references `CLAUDE.md` content) | Implausible (A-019 through A-023 confirm no test loads CLAUDE.md or docs/*.md content beyond fixture-write) but possible if hidden grep exists | One of the five sibling tests in Task 8 sibling-test-smoke returns non-zero | smoke (one-liner gate) | Task 8 sibling-test smoke (`bin/agent-prompts-content-test.sh`, `bin/vocabulary-cleanliness-test.sh`, `bin/run-local-content-adversarial-test.sh`, `bin/scope-check-test.sh`, `bin/profile-allowlist-test.sh`) |
| Operator searches CLAUDE.md for "ENG-95" and gets zero hits (regression from Task 1 Hunk 3 deleting the Migration paragraph) | Documented-but-acknowledged consequence (brainstorm §8 edge-case row 2 + §10 #3) | Discoverability path is `ls docs/brainstorms/ \| grep -i eng-95`; brainstorm §10 #3 captures a future "Recent architectural tickets" index followup | manual (acknowledged) | brainstorm §10 #3 — not a regression test, an acknowledged trade |

## Test Strategy

**No new tests; no test edits.** Per brainstorm D-4 deliberation, the harness has no doc-content test today, and adding one alongside the prose sweep doubles the review surface plus risks false-positives on legitimate two-stack-contrast text (the issue's AC#2 explicitly permits "two-stack contrast pedagogically"). The deferral is captured at brainstorm §10 #2 with explicit re-evaluation criteria (≥3 future ENG-XX tickets regressing the Tauri-zero invariant).

**Test-gate closure sweep (per plan-prompt requirement).** The set of tokens this plan REMOVES from production prose is:

| Removed token | Sibling-test file that contains it | Disposition |
|---|---|---|
| Literal `Tauri` token in `CLAUDE.md` lines 57, 303, 314, 315, 338 | `bin/agent-prompts-content-test.sh:142,161` greps for `'tauri'` in `$PROMPTS` (AGENT_PROMPTS.md), NOT CLAUDE.md — see A-019. **Disposition:** test unaffected; no edit needed. |
| Literal `Tauri-shaped` phrase in `CLAUDE.md`, `docs/assumptions.md`, `README.md` | `bin/profile-allowlist-test.sh:7,19,114` mention "Tauri-shaped" only in its own header comments (A-020), not test assertions. **Disposition:** test unaffected; comments may eventually warrant a future-ticket cleanup (out of scope per OUT boundary on `bin/*`). |
| Literal `hardcoded Tauri` phrase in `CLAUDE.md:303-304` | Same as above (only in `bin/profile-allowlist-test.sh` comments). **Disposition:** unaffected. |
| Literal `non-Tauri` phrase in `README.md:346`, `docs/configuration.md:228` | No sibling test contains this literal token (verified by Grep). **Disposition:** N/A. |
| Literal `bun tauri build` phrase in `CLAUDE.md:57` | No sibling test contains this literal (verified). **Disposition:** N/A. |
| Standalone `cargo, bun, rustc, jq` enumeration in `docs/configuration.md:218-219` | No sibling test pins this table's tool list (verified by Grep; A-019 through A-023 enumerate the test files that touch `docs/configuration.md` and confirm none grep its body). **Disposition:** N/A. |

**No test-gate-closure defects found.** Every removed token is either:
1. Not present in any sibling test (most cases), OR
2. Present only in sibling-test header comments (which describe history, not assertions — `bin/profile-allowlist-test.sh:7,19,114`).

**Smoke-level invariants gated at Task 8.** Five smoke-level `grep`-based one-liners (AC#1 zero-hit, AC#3 ≥1-hit per file × 4, AC#4 1-hit per callout × 2) plus five sibling-test re-runs (`bin/agent-prompts-content-test.sh`, `bin/vocabulary-cleanliness-test.sh`, `bin/run-local-content-adversarial-test.sh`, `bin/scope-check-test.sh`, `bin/profile-allowlist-test.sh`). These are AC verifications, not test additions — they run as part of the implement agent's manual closure pass and are re-run by the reviewer.

**Manual reviewer pass.** AC#2 (multi-stack-contrast phrasing), AC#3 (composition-order consistency across files), the diagram-cell width preservation, the nested-fence render correctness, and the forward-link anchor resolution are caught by PR review (the umbrella ENG-92 reviewer is the same human who landed ENG-94/95/97/98 and carries the context).

**Adversarial / edge cases (per brainstorm §8).** Eight edge-case rows in the brainstorm map onto reviewer-pass dispositions or pre-existing fallback paths (e.g. "operator skipping Phase 5b → CLAUDE.md:352 Fallback contract"; "future ticket renames `learned-rules/<slug>/project-profile.md` → normal docs-maintenance cost"). No new edge cases introduced by this ticket — every risk surface is prose, not runtime.

## Self-review

**Personas: 5/5 PASS · gate P0: 0**

The brainstorm carried six-persona review at iteration 1 (5/6 PASS + product PASS-with-CONCERNS; feasibility 0 P0). This plan's self-review runs the five mandated personas (feasibility, scope, coherence, design, product) against the plan doc itself; the brainstorm personas were against the brainstorm doc.

### feasibility — PASS (0 P0, 0 P1, 0 P2)
- Every code-level fact cited in Assumption Inventory was re-verified by Read/Grep at plan time (see A-001 through A-025 above). The 25 assumption rows comprise: 7 file-residue maps with `path:line` quotes (A-001 through A-007); 8 codebase-fact references with helper-definition line numbers (A-008 through A-015); 8 structure / negative-existence assertions (A-016 through A-023, plus A-024 non-existence and A-025 branch-base-freshness). All hold against the current worktree at HEAD `709b314`, origin/main `c47bd88`.
- Every task has `depends_on` and `touches` metadata; every Failure Mode → Test Map row names either a smoke-gate one-liner (run inside Task 8) or a manual reviewer-pass disposition.
- Test-gate closure sweep complete (§Test Strategy table): zero sibling tests load-bear on any removed token; only `bin/profile-allowlist-test.sh:7,19,114`'s header comments mention "Tauri-shaped" and they are not assertions. No P0 / P1 / P2.
- Edit boundaries use content anchors throughout (table-header-row, H2 / H3 text, literal quoted substrings); line numbers appear only as informational hints alongside content anchors per the prompt's Edit-boundary keys requirement.
- Branch-base freshness: `git log --oneline HEAD..origin/main` empty (A-025); no `Task 0: Rebase` required.

### scope — PASS (0 P0, 0 P1, 0 P2)
- Every task traces to a brainstorm decision:
  - Task 1, 2, 3, 4, 5, 6 → D-1 (per-file surgical rewrites).
  - Task 1 Hunk 4 + Task 7 Hunk 2 → D-2 (AC#4 callouts).
  - Task 7 Hunk 1 → D-1 (broaden diagram-cell example).
- File Structure entries are exactly the seven files named in the ticket's IN-scope boundary; no creep into `docs/brainstorms/`, `docs/plans/`, `docs/demos/`, or `learned-rules/` (per D-3 + ticket OUT boundary).
- Each task's `touches` list is exactly the single in-scope file (Tasks 1-7) or read-only verification (Task 8); no `touches` strays outside File Structure.
- No gold-plating: the plan does not propose a `docs-no-tauri-test.sh` (deferred per D-4), does not propose a "Recent architectural tickets" index (deferred per brainstorm §10 #3), does not propose updating `bin/profile-allowlist-test.sh`'s header comments (out of scope per OUT boundary on `bin/*`).

### coherence — PASS (0 P0, 0 P1, 0 P2)
- Plan's Goal §1-§4 maps directly onto the brainstorm's §2 Goal (AC#1-AC#4).
- Backend Tasks 1-7 + Task 8 closure jointly realise every brainstorm §5 architecture-table row (7 files × specific rewrites + new callouts).
- Failure Mode → Test Map covers every brainstorm §8 edge case AND every brainstorm §6 verification step. The eight FMTM rows pair with the eight brainstorm-§8 rows; the verification steps in Task 8 map onto brainstorm §6 verification steps 1-4 + 5 (markdown-render visual) + 6 (cross-file consistency manual).
- Canonical phrasing locks from brainstorm §1 ("stack-neutral base + profile-derived stack tools + operator-curated extras", `cargo / bun / pip / go`, `Cargo.toml / package.json / pyproject.toml`, "append" verb) are used verbatim across all seven task descriptions.

### design — PASS (0 P0, 0 P1, 0 P2)
- No code edits → no crate / module boundary changes → no layering violations possible.
- The new docs/architecture.md H2 "Discovery and the project profile" is added between existing H2s ("Three roots, three storage tiers" and "Harness vs target — the load-bearing distinction"); the placement matches the brainstorm D-2 prescription and the convention of the file (H2 sections for architectural orientation, ordered by abstraction layer).
- The new CLAUDE.md "Where stack knowledge lives" callout is a bold-prefixed paragraph, NOT an H2 — preserving CLAUDE.md's existing outline shape (15 H2s, unchanged). Verified by Task 1 Hunk 4's `wc -l` post-task assertion.
- No new abstractions introduced. No new files. No new env vars. No new exit codes.

### product — PASS (0 P0, 0 P1, 0 P2)
- Plan delivers exactly what the Linear issue asked: zero Tauri tokens in the seven IN-scope files; concrete examples replaced with package-manager-neutral phrasing or 2-3-stack contrast; configuration docs reflect post-ENG-94 composition; discovery flow named in CLAUDE.md and docs/architecture.md.
- Operator language: AC#3 grep target is the verbatim canonical phrase brainstormed in §1, which an operator reading the docs will encounter as a coherent description of the mechanism (not jargon).
- Brainstorm product-persona's iteration-1 P1 folds (concrete Python `## Tool allowlist` snippet in docs/assumptions.md; softened README.md opener with forward-link) are both reflected in the plan's task hunks (Task 4 Hunk 1 and Task 2 Hunk 1 respectively).
- Out-of-scope clean: this plan does NOT solve the adjacent technical problems of (a) deriving PATH augmentation from the profile (brainstorm §10 #1, inherited deferral), (b) adding a doc-content regression test (brainstorm §10 #2, deferred), (c) "Recent architectural tickets" index in CLAUDE.md (brainstorm §10 #3, deferred), or (d) cross-target consistency of `learned-rules/twinning/project-profile.md` (brainstorm §10 #5, OUT scope). Each deferred-item disposition is explicitly recorded in the brainstorm and inherited.

**Gate: 5/5 PASS, 0 P0. Proceeding to implementing.**
