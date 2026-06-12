---
linear: ENG-27
date: 2026-06-12
topic: Wire Playwright MCP into ui and qa stage dispatches with artifacts_dir resolver, setup-time chromium install, and mandatory browser-verification gates in AGENT_PROMPTS.md
---

# ENG-27 — Wire Playwright MCP into ui and qa stages

## 1. Goal

`ui` and `qa` dispatches gain a `mcp__playwright__*` toolset and an `--mcp-config` argv segment (gated on stage ∈ {ui, qa} AND `config.json::mcp.playwright.enabled != false` AND not-dry-run) such that an agent can navigate, screenshot, and persist visual evidence under `$(issue_dir <issue>)/artifacts/` referenced by relative path from the stage-summary — driven by a MANDATORY `Browser verification:` outcome line in AGENT_PROMPTS.md §4 and §6.

## 2. Assumption Inventory

Every fact below is verified at the cited `path:line` in this worktree. Brainstorm assumptions A-1 through A-20 (`docs/brainstorms/2026-06-12-eng-27-...-design.md::§9`) were re-checked while drafting; deltas vs. the brainstorm's named lines are recorded inline below.

### Branch-base freshness

`git log --oneline HEAD..origin/main` NON-EMPTY at plan time. origin/main = `707b597` (ENG-125 init.sh-validator merge); HEAD = `92a7911 chore(pipeline): plan for ENG-27`. Roughly 24 commits ahead on origin/main, dominated by ENG-125 which touched `bin/dispatch.sh`, `bin/render-prompt.sh`, `bin/run-stage.sh`, `AGENT_PROMPTS.md`, `learned-rules/harness/project-profile.md`, and `bin/common.sh`. None of those changes are semantically incompatible with this plan (ENG-125 adds an init.sh validator at planning stage; our edits add MCP wiring at the ui/qa dispatch path — orthogonal subsystems). However, every `path:line` informational hint in §2 was captured against HEAD before the ENG-125 merge, so the line numbers may drift by ~10-30 lines per file post-rebase. **Mitigation:** Task 0 (added below) MUST run a clean `git fetch origin main && git rebase origin/main` before any other task, and every subsequent task uses CONTENT anchors (literal strings, comment markers, function signatures) as the load-bearing boundary; line numbers are informational only. Specifically, ENG-125 added:
- `bin/render-prompt.sh`: new `init_sh_path=_resolve_init_sh_path` PROMPT_RESOLVERS entry (~L57) and `_RENDER_INIT_SH_PATH="$(issue_dir "$issue_id")/init.sh"` binding in `main()` (~L579) — neither conflicts with this plan's `artifacts_dir` addition; they sit in the same regions and follow the same pattern.
- `bin/dispatch.sh`: collapsed planning-detective stanza (~L353-359) and new `_assert_init_sh_well_formed` helper — orthogonal to `allowed_tools_for` / `main()`'s argv build.
- `bin/run-stage.sh`: new `rc=39/40/41` arm in the dispatch_rc switch (~L1665) — orthogonal to the `mkdir -p` site at ~L1662.
- `AGENT_PROMPTS.md`: §2 renumbered to step 8 in its completion-checklist header — does NOT touch §4 or §6.
- `learned-rules/harness/project-profile.md`: `init-sh-validator-{test,adversarial-test}.sh` entries added to the implementing/qa allowlists and the Build & test gates Test command — does NOT touch `## File layout`.
None of these changes block the planned edits; the implement agent re-verifies all path:line hints after Task 0's rebase and falls back to content anchors (which are immune to line-number drift) for the actual edits.

### Codebase facts (verified against current HEAD)

- `bin/dispatch.sh::allowed_tools_for` is the per-stage tool chokepoint. UI case arm at `bin/dispatch.sh:549`; QA case arm at `bin/dispatch.sh:551`. Composition site (`base + profile_tools + extras`) at `bin/dispatch.sh:565-572`.
- `bin/dispatch.sh::main` builds the `cmd` argv from line 724 onward. The `env` block + optional `gtime` are at lines **724-730**. `gtimeout + claude -p + --output-format stream-json --verbose` block at lines **731-734**. Optional `--model` splice at lines **741-743**. ENG-155 `--add-dir "$issue_state_dir"` splice (gated on `$issue_state_dir` non-empty) at lines **753-755**. Isolation block (`--setting-sources project,local --disable-slash-commands --disallowed-tools "$denies" --allowed-tools "$tools"`) at lines **756-761**.
- `bin/dispatch.sh:668-687` is the `PIPELINE_DRY_RUN=1` short-circuit. It runs BEFORE the cmd-build (line 724) so any post-687 splice is automatically skipped in dry-run. The dry-run `log "[DRY_RUN] would invoke …"` echo on line 682 emits `--allowed-tools "$tools"` literally, so an MCP-wildcard entry added in `allowed_tools_for` is visible to a `grep mcp__playwright__\*` against the dry-run argv echo.
- `bin/run-stage.sh:1659` is the existing `mkdir -p "$(issue_dir "$ident")"` site that guarantees the per-issue state directory exists before any dispatch.sh invocation. Exact line: `mkdir -p "$(issue_dir "$ident")"`.
- `bin/run-stage.sh:1800-1802` is the `PIPELINE_ISSUE_ID="$ident" … bash "$SCRIPT_DIR/dispatch.sh" …` handoff. Hand-off env block at lines 1800-1802.
- `bin/render-prompt.sh::PROMPT_RESOLVERS` is the literal-string token-resolver registry at lines **40-58** (17 entries; `dispatch_id`, `progress_md_path`, `plan_json`, `verdict_review_path` are the most-recent additions).
- `bin/render-prompt.sh::_write_rendered_paths_sidecar` enumerates path-shaped resolvers at lines **89-120** for the ENG-156 detective contract. Adding a new path-shaped resolver requires both a `PROMPT_RESOLVERS` entry AND an explicit printf line in this enumeration.
- `bin/render-prompt.sh::main()` binds `_RENDER_*` globals at lines **546-580**. `_RENDER_STAGE_SUMMARY_PATH` is at line 555; `_RENDER_PROGRESS_MD_PATH` at line 556; the section-end at line 580 is the splice point for a new `_RENDER_ARTIFACTS_DIR` binding.
- `bin/render-prompt.sh:421` is the unknown-token validator: `die "render-prompt: unknown token '$t' in source — register a resolver in PROMPT_RESOLVERS"`. Any `{artifacts_dir}` token added to AGENT_PROMPTS.md without a sibling resolver registration will cause this `die` to fire and halt every ui/qa dispatch.
- `bin/setup.sh::ALL_PHASES` is the linear phase list at line **723**: `ALL_PHASES=(workspace linear-auth linear-identity linear-schema slug-freeze project-profile github-app gh-cli slack config-defaults validate launchd)`. Phase 11 is `validate` (`phase_validate` at line 572, `is_validate_done` at line 582); phase 12 is `launchd` (`phase_launchd` at line 585, `is_launchd_done` at line 600). The dynamic dispatcher `run_phase_or_skip` (lines 724-733) calls `phase_<name>` and `is_<name>_done`; new phases register by adding to `ALL_PHASES` and defining both functions.
- `AGENT_PROMPTS.md §4 "UI Agent (Frontend)"` H2 at line **1048**, fenced block runs to line **1208** (closing ``` at 1208). §6 "QA Agent" H2 at line **1522**, fenced block runs to line **1784** (closing ``` at 1784). Each stage block carries exactly TWO column-0 ``` fences per the render-prompt extraction contract.
- `AGENT_PROMPTS.md:1106-1122` is the §4 "Per-component UX checklist" block — 8 items, ≥7/8 pass required. `AGENT_PROMPTS.md:1162-1185` is the §4 Output block (stage-summary write + progress.md append). Insertion site for the new "Browser verification (per-route gate)" block: BEFORE the existing "Per-component UX checklist" anchor at line 1106 OR BETWEEN the existing checklist (1106-1122) and the "Second-reviewer pass" anchor at line 1124 — pick the latter so the new gate frames the second-reviewer pass (which can then read the screenshots).
- `AGENT_PROMPTS.md:1617-1656` is §6's task body (`### 3. Coverage audit` through `### 7. qa-patterns updates`). Insertion site for "§3.5 End-to-end verification (browser)": AFTER the closing `Missing → P0.` of §3 at line 1618, BEFORE the `**4. Regression-intent audit:**` anchor at line 1620.
- `bin/common.sh::issue_dir` (lines 68-72) returns `$PROJECT_STATE_DIR/$issue`. So `$(issue_dir "ENG-27")/artifacts/` resolves to `$PROJECT_STATE_DIR/ENG-27/artifacts/` — sibling of `worktree/`, OUTSIDE the worktree.
- `bin/run-local-helpers.sh::stage_output_paths` for `implementing|ui|qa` (line 470) falls through to the profile-derived `## File layout` allowlist. Adding a new top-level `mcp/` directory means committing files under `mcp/` will be classified `self-leak` (NEW untracked path) by `partition_dirty_paths` unless `mcp/` is added to the profile's `## File layout` section. **Delta vs. brainstorm A-9**: brainstorm assumed files in `$issue_dir/artifacts/` would not enter `partition_dirty_paths` because the dir is OUTSIDE the worktree (true — verified by the `.scratch/` precedent at `bin/run-local-helpers.sh:303-332`). But the brainstorm did NOT explicitly call out that committing `mcp/*.json` at the repo top level requires a profile update.
- `learned-rules/harness/project-profile.md::## File layout` at line **136** lists `bin/`, `bin/setup-prompts/`, `learned-rules/<slug>/`, `launchd/`, `docs/brainstorms/`, `docs/plans/`, `AGENT_PROMPTS.md`. `mcp/` is NOT present.
- `learned-rules/harness/project-profile.md::## Build & test gates` at line **14** declares the Test command at line **17** — a single long `&&`-chained string of `bash bin/*-test.sh` calls. Per ENG-122 add-side test-gate closure: a new `bin/*-test.sh` requires updating this string. **Delta vs. brainstorm §11**: brainstorm called out the new test but did NOT name the profile update — added below as Task 8.
- `bin/dispatch-test.sh:80-101` is the per-stage `mcp__*linear*` exclusion sweep. The same loop shape is the natural fixture for asserting `mcp__playwright__*` PRESENCE on `ui`/`qa` and ABSENCE on every other stage. **Delta vs. brainstorm §11**: brainstorm suggested either extending `bin/dispatch-test.sh` OR adding a new `bin/dispatch-playwright-test.sh`. This plan chooses the new sibling file so the four-cell coverage matrix lives in one focused test; `bin/dispatch-test.sh` continues to enforce only the no-Linear-MCP invariant.
- `bin/plan-schema.sh::cmd_validate_md` (lines 297-397) is the post-dispatch System-invariants section validator. Validator dies on missing H2 `## System invariants`, zero bullets, or any bullet whose first line lacks a parseable `verified_by:` token (`<path>:<test-name>` or `task:T<N>`).
- `bin/dispatch.sh::_dispatch_tools_from_profile` (lines 441-…) reads the profile's `## Tool allowlist` section. The harness profile lists `ui: (none)` and `qa: (none)` at `learned-rules/harness/project-profile.md:55,89` — so the profile-derived tool segment for both stages is empty today. Adding `mcp__playwright__*` via `_dispatch_mcp_enabled_for` keeps the profile section unchanged (the brainstorm's D-2 rationale stands; `mcp__*` wildcards are a structurally different surface from the Bash patterns the `## Tool allowlist` section is designed for).

### Existing tests that will gain assertions (test-gate closure — REMOVAL side)

This plan REMOVES no tokens from production code. No sibling test files contain assertions on tokens we are dropping.

### Existing tests that will gain assertions (test-gate closure — ADD side)

We add `bin/dispatch-playwright-test.sh`. Per ENG-122, `learned-rules/harness/project-profile.md` is listed in File Structure with a task updating the `## Build & test gates` Test command line to chain `&& bash bin/dispatch-playwright-test.sh` onto the existing string. The new test ALSO runs automatically via the pre-commit hook's `bin/*-test.sh` sweep (`.githooks/pre-commit`), so the gate string is the only profile-side update needed.

## 3. System invariants

- **I-1 — Toolset and MCP config presence agree.** `_dispatch_mcp_enabled_for(stage)` is the single gate for both the `mcp__playwright__*` allowlist append and the `--mcp-config <path>` argv splice — the two cannot diverge. *verified_by: `task:T6`* (T6's smoke test `T_mcp_gate_coherent` in the new `bin/dispatch-playwright-test.sh` asserts the four-cell matrix: ui/qa × config{absent,true,false} × dry-run{0,1}; the gate-runnable test file is listed in T6's `touches:`).
- **I-2 — Dry-run elides `--mcp-config` but PRESERVES the MCP allowlist entry.** Per D-5: the dry-run echo at `bin/dispatch.sh:682` must show `mcp__playwright__*` in `--allowed-tools` (test signal for wiring) but must NOT include `--mcp-config` (no MCP child spawn in dry-run). *verified_by: `task:T6`* (T6's `T_dry_run_keeps_allowlist` and `T_dry_run_skips_mcp_config` assertions in the new `bin/dispatch-playwright-test.sh`).
- **I-3 — Only `ui` and `qa` carry the MCP segment.** Other stages (`brainstorming`/`planning`/`implementing`/`reviewing`/`building`/`released`) MUST NOT include `mcp__playwright__*` in their allowed-tools nor receive `--mcp-config`. *verified_by: `task:T6`* (T6's `T_other_stages_no_mcp` per-stage loop in `bin/dispatch-playwright-test.sh` asserts absence on the six non-ui/qa stages).
- **I-4 — `{artifacts_dir}` token resolves OR render dies.** A `{artifacts_dir}` token in any stage's AGENT_PROMPTS.md body must have a registered resolver in `PROMPT_RESOLVERS` or the unknown-token validator at `bin/render-prompt.sh:421` halts the dispatch. *verified_by: `bin/render-prompt-test.sh:R5`* (the pre-existing "Case 87-R5" registry-coverage pin at `bin/render-prompt-test.sh:289-329` greps every `{token}` in `AGENT_PROMPTS.md` and asserts a `PROMPT_RESOLVERS` entry exists — the test surfaces the {artifacts_dir}-without-resolver regression at gate-run time).
- **I-5 — `mcp/playwright.json` exists at dispatch time when the gate fires.** Per the error-handling table row in §5 of this plan: if `_dispatch_mcp_enabled_for(stage)` returns truthy but the resolved config path is missing, `dispatch.sh::main` MUST `die` with the operator-actionable hint (commit the file OR set `config.mcp.playwright.enabled=false`) rather than silently passing a non-existent `--mcp-config`. *verified_by: `task:T6`* (T6's `T_missing_config_dies` adversarial case in `bin/dispatch-playwright-test.sh`).
- **I-6 — `mcp/` directory is in-scope for the harness profile.** `partition_dirty_paths` must classify `mcp/playwright.json` and `mcp/playwright-headful.json` as in-scope, NOT self-leak, when the implement agent commits them. *verified_by: `task:T8`* (Task 8 adds a `T_profile_file_layout_lists_mcp` structural assertion to `bin/profile-allowlist-test.sh`; the new test file appears in T8's `touches:` field and the project-profile gate string is also updated in T8 to chain the new dispatch-playwright test).

## 4. File Structure

Modify (production):
- `bin/dispatch.sh` (~L526-572 and ~L724-761) — add `_dispatch_mcp_enabled_for(stage)` helper just above `allowed_tools_for`; splice `mcp__playwright__*` into the `allowed_tools_for` composition (a fourth tier, after extras); splice `--mcp-config "$mcp_cfg_path"` into `main()`'s `cmd` argv between the `--add-dir` block (lines 753-755) and the isolation block (lines 756-761), gated on the helper AND `PIPELINE_DRY_RUN != 1`; the `mcp_cfg_path` is `$HARNESS_ROOT/mcp/playwright-headful.json` when `PLAYWRIGHT_HEADFUL=1` else `$HARNESS_ROOT/mcp/playwright.json`.
- `bin/render-prompt.sh` (L40-58, L89-120, L546-580) — add `artifacts_dir=_resolve_artifacts_dir` to `PROMPT_RESOLVERS`; implement `_resolve_artifacts_dir` returning `$(issue_dir "$_RENDER_ISSUE_ID")/artifacts/`; bind `_RENDER_ARTIFACTS_DIR` in `main()` between `_RENDER_PROGRESS_MD_PATH` (L556) and `_RENDER_LEARNED_RULES_DIR` (L557); add `artifacts_dir\t…` printf line to `_write_rendered_paths_sidecar` enumeration (L97-117).
- `bin/run-stage.sh` (~L1659) — add `mkdir -p "$(issue_dir "$ident")/artifacts/"` immediately AFTER the existing `mkdir -p "$(issue_dir "$ident")"` line, BEFORE `_ensure_progress_md`. Gated only on stage being ui/qa is unnecessary — the directory is cheap and the same code path runs for every stage; mirrors the brainstorm D-4 placement.
- `bin/setup.sh` (~L572-607, L723) — add `phase_playwright_install` and `is_playwright_install_done` between `phase_validate` / `is_validate_done` and `phase_launchd` / `is_launchd_done`; append `playwright-install` to `ALL_PHASES` between `validate` and `launchd`.
- `AGENT_PROMPTS.md` (§4 ~L1106-1124 and §6 ~L1617-1620) — insert a new MANDATORY "Browser verification (per-route gate)" block in §4 BETWEEN the "Per-component UX checklist" closing line at 1122 and the "Second-reviewer pass" anchor at 1124; insert "§3.5 End-to-end verification (browser)" in §6 BETWEEN the §3 "Coverage audit" closing line at 1618 and the §4 "Regression-intent audit" anchor at 1620; both blocks reference `{artifacts_dir}`; both prompt bodies append the D-10 mandatory `Browser verification: performed|skipped|failed · reason=<token>` line to the stage-summary Notes-section instructions (§4 stage-summary block at L1162-1174; §6 stage-summary blocks at L1718-1728 and L1737-1742).
- `learned-rules/harness/project-profile.md` (L17, L136-143) — append `&& bash bin/dispatch-playwright-test.sh` to the `## Build & test gates` Test command at line 17; add a new bullet `- \`mcp/\` — checked-in MCP server config files (playwright.json + playwright-headful.json) referenced by bin/dispatch.sh via $HARNESS_ROOT/mcp/.` to `## File layout` between the `launchd/` bullet (L141) and the `docs/brainstorms/` bullet (L142).

New (production):
- `mcp/playwright.json` — static MCP config (headless). Body:
  ```json
  {
    "mcpServers": {
      "playwright": {
        "command": "npx",
        "args": ["-y", "@playwright/mcp@latest", "--headless", "--browser", "chromium", "--viewport-size", "1280,800", "--isolated"]
      }
    }
  }
  ```
  Exact CLI arg names verified by OQ-2 at implement time (`npx @playwright/mcp@latest --help`); if upstream args differ the JSON body adapts but the file path / shape is fixed.
- `mcp/playwright-headful.json` — static MCP config (headful). Same body with `--headless` removed (or `--headed` added per upstream's flag spelling, resolved at OQ-2 time).

New (tests):
- `bin/dispatch-playwright-test.sh` — sourced-and-stubbed sibling test (source-and-stub pattern per CLAUDE.md). Covers the four-cell matrix (stage × config × dry-run) plus the missing-config `die` adversarial case. Tests carry the `T_<descriptor>` naming convention.

Modify (tests):
- `bin/profile-allowlist-test.sh` — add `T_profile_file_layout_lists_mcp` assertion to pin I-6 (mcp/ bullet present in profile File layout). Placed adjacent to existing `T_*` assertions per the file's existing source-and-stub pattern.

Out-of-scope (explicitly NOT touched):
- `bin/scope-check.sh` — unchanged. `partition_dirty_paths` invisibility for paths outside the worktree is a pre-existing invariant (the `.scratch/` precedent).
- `bin/run-local-helpers.sh::stage_output_paths` — unchanged. The harness profile's `## File layout` update covers in-scope-ness of `mcp/`.
- `bin/cleanup-worktrees.sh` — unchanged. Artifact directory persists for the full lifetime of `$issue_dir`.
- `bin/linear.sh` — unchanged. Screenshot Linear-attachment is explicitly deferred to a follow-up ticket per brainstorm D-9.

## 5. API Contract

No new FE↔BE API surface. The harness is a bash orchestration repo; the only "contracts" it exposes are:

- The `dispatch.sh` argv shape between dispatch and the spawned `claude -p` (extended here by `--mcp-config` + the `mcp__playwright__*` allowlist entry).
- The MCP server protocol between `claude -p` and the `npx @playwright/mcp@latest` child (defined by the upstream `@playwright/mcp` package; out-of-tree contract).
- The AGENT_PROMPTS.md token surface (extended here by `{artifacts_dir}`).

The first is exercised by Task 6's `bin/dispatch-playwright-test.sh`; the second is upstream's responsibility (OQ-2 verifies upstream args at implement time); the third is gated by `bin/render-prompt.sh:421`'s unknown-token validator.

## 6. Backend Tasks

### Task 0: Rebase onto origin/main

- `depends_on: []`
- `touches: (no files written; rebases the entire branch)`
- [ ] Run `git fetch origin main` from the per-issue worktree.
- [ ] Run `git rebase origin/main`. The brainstorm commit (`5e83ef8 chore(pipeline): brainstorming for ENG-27`) and plan commit (`92a7911 chore(pipeline): plan for ENG-27`) are the only commits ahead of base; both touch only `docs/brainstorms/` and `docs/plans/` and CANNOT conflict with ENG-125's `bin/` and `AGENT_PROMPTS.md` deltas. Rebase should be conflict-free. If a conflict surfaces, STOP and post `verdict halt --reason agent-blocked` with the conflicting file path — do NOT auto-resolve, because the conflict would indicate an unanticipated overlap with main that the brainstorm did not anticipate.
- [ ] After the rebase completes, re-verify every `path:line` informational hint in §2 (Assumption Inventory). For each hint, run a quick `grep -n` against the cited file to confirm the literal content anchor is present (the line number itself may have drifted, but the anchor MUST still exist). Specifically re-verify: `bin/dispatch.sh::allowed_tools_for() {`, `bin/dispatch.sh:`'s `--add-dir "$issue_state_dir"` block, the `--setting-sources project,local` line, the `PIPELINE_DRY_RUN` early-return block; `bin/render-prompt.sh::PROMPT_RESOLVERS=`, the closing `'` of the registry, `_resolve_progress_md_path()` definition, `_write_rendered_paths_sidecar` brace block; `bin/run-stage.sh:`'s existing `mkdir -p "$(issue_dir "$ident")"` line; `bin/setup.sh::ALL_PHASES=(`; `AGENT_PROMPTS.md`'s `## 4. UI Agent (Frontend)` and `## 6. QA Agent` headers, the `Per-component UX checklist` literal, the `Second-reviewer pass (MANDATORY` literal, the `Coverage audit (proxy since` literal, and the `Regression-intent audit` literal; `learned-rules/harness/project-profile.md::## File layout` and `## Build & test gates`.
- [ ] If ANY content anchor is missing after rebase (which would mean ENG-125 or another sibling ticket altered or removed the anchor), STOP, post `verdict halt --reason agent-blocked` with the missing-anchor surface, and request `pipeline:supersede` so this plan is re-drafted against the new main. Do NOT proceed to Tasks 1-8 with broken anchors.
- [ ] Force-push the rebased branch (`git push --force-with-lease origin <branch>`) so the dispatch.sh allow-listed git operations recognize it. The implement agent's `Bash(git push:*)` allowlist permits this.

### Task 1: Create `mcp/playwright.json` and `mcp/playwright-headful.json`

- `depends_on: [0, 5]` — profile must list `mcp/` in `## File layout` first (Task 5) so the implement agent's tick-end scope sweep classifies these as in-scope; rebase (Task 0) must run before anything.
- `touches: mcp/playwright.json, mcp/playwright-headful.json`
- [ ] Verify upstream `npx @playwright/mcp@latest --help` arg names. Brainstorm OQ-2: confirm `--headless` / `--headed` / `--browser` / `--viewport-size` / `--isolated` flags exist. If upstream's actual flag spelling differs, adapt the JSON `args` array. Do NOT speculate; run the help command locally first.
- [ ] Create `mcp/playwright.json` with the headless template body (see File Structure §4 for the canonical shape). `mcpServers.playwright.command` is `npx`; `mcpServers.playwright.args` is the verified-upstream argv list.
- [ ] Create `mcp/playwright-headful.json` as the headful sibling: identical body with the headless flag removed (or replaced by `--headed`, per upstream).
- [ ] Validate both files parse as JSON: `jq -e . mcp/playwright.json` and `jq -e . mcp/playwright-headful.json` both exit 0.

### Task 2: Add `artifacts_dir` resolver to `bin/render-prompt.sh`

- `depends_on: [0]`
- `touches: bin/render-prompt.sh::PROMPT_RESOLVERS, bin/render-prompt.sh::_resolve_artifacts_dir, bin/render-prompt.sh::_write_rendered_paths_sidecar, bin/render-prompt.sh::main`
- [ ] Edit `PROMPT_RESOLVERS` (the literal-string registry between lines 40-58): AFTER the existing `verdict_review_path=_resolve_verdict_review_path` entry (the closing entry before the trailing `'`), insert a new line `artifacts_dir=_resolve_artifacts_dir`. Content anchor: the closing `'` of the registry, which is the only single-quote at column 0 between lines 40-60.
- [ ] Add a new resolver function `_resolve_artifacts_dir() { printf '%s/artifacts/' "$(issue_dir "$_RENDER_ISSUE_ID")"; }` alongside the other `_resolve_*` functions. Content anchor: place adjacent to `_resolve_progress_md_path()` (find its definition via Grep; the function block starts with `_resolve_progress_md_path()` and ends with the matching `}`).
- [ ] Bind `_RENDER_ARTIFACTS_DIR` in `main()` BETWEEN the `_RENDER_PROGRESS_MD_PATH="$progress_md_path"` line (L556 informational hint; content anchor: the literal `_RENDER_PROGRESS_MD_PATH="$progress_md_path"` string) and the `_RENDER_LEARNED_RULES_DIR="$HARNESS_ROOT/learned-rules/$PROJECT_SLUG"` line (L557 informational hint; content anchor: the literal `_RENDER_LEARNED_RULES_DIR=` token). Note: `_resolve_artifacts_dir` reads `$_RENDER_ISSUE_ID` (already bound at L546), so no separate `artifacts_dir=…` local-variable binding is needed in `main()` — only the `_RENDER_*` global needs to exist to make the resolver value computable post-bind. The minimal binding line is `_RENDER_ARTIFACTS_DIR="$(issue_dir "$issue_id")/artifacts/"`.
- [ ] Add an enumeration line to `_write_rendered_paths_sidecar` (between lines 97-117): `[[ -n "${_RENDER_ARTIFACTS_DIR:-}" ]] && printf 'artifacts_dir\t%s\n' "$_RENDER_ARTIFACTS_DIR"`. Content anchor: place INSIDE the `{ ... } > "$sidecar_path"` braced block, immediately AFTER the existing `_RENDER_PROGRESS_MD_PATH` printf line at L102.
- [ ] Run `bash bin/render-prompt-test.sh` and confirm pass.

### Task 3: `mkdir -p artifacts/` in `bin/run-stage.sh`

- `depends_on: [0]`
- `touches: bin/run-stage.sh`
- [ ] Edit `bin/run-stage.sh` to add a new line `mkdir -p "$(issue_dir "$ident")/artifacts/"` immediately AFTER the existing line `mkdir -p "$(issue_dir "$ident")"` at line 1659. Content anchor: the literal `# Guarantee the per-issue state dir exists before dispatch so an agent's first` comment (above L1657) and the `mkdir -p "$(issue_dir "$ident")"` line at L1659. Place the new mkdir on the very next line.
- [ ] Run `bash bin/run-stage-test.sh` and confirm pass.

### Task 4: AGENT_PROMPTS.md — §4 UI browser-verification block + §6 QA §3.5 block + D-10 stage-summary line

- `depends_on: [0, 2]` — `{artifacts_dir}` token must be a registered resolver before the prompt body references it (else `bin/render-prompt.sh::resolve_block_tokens`'s unknown-token validator halts every ui/qa dispatch); rebase (Task 0) must run before anything.
- `touches: AGENT_PROMPTS.md::§4 UI Agent, AGENT_PROMPTS.md::§6 QA Agent`
- [ ] Edit §4 (UI). Insert a new H3-block immediately AFTER the "Per-component UX checklist" 8-item list's closing line `Require ≥7/8 items pass per component. Items 1, 3, 4 are P0 (never merge without them).` (L1122) and BEFORE the "Second-reviewer pass (MANDATORY — independent check):" anchor (L1124). Content anchor: the literal phrase `Require ≥7/8 items pass per component. Items 1, 3, 4 are P0 (never merge without them).`. Block title: `Browser verification (per-route gate) (MANDATORY when the profile names a frontend layer):`. Body:
  - Predicate (verbatim wording): *"the profile's Stack section names a frontend layer AND the plan's Frontend Tasks are not 'N/A' AND your work touched at least one route or component. If the predicate is false, skip THIS block but still emit the `Browser verification: skipped · reason=<token>` line below."*
  - Workflow: start the dev server in the background per the profile's "Build & test gates" Integration/E2E command; HTTP-poll the entry URL (curl HEAD against the configured port; allow ≤30s, then halt `smoke-failed`); call `mcp__playwright__browser_navigate` per changed route; call `mcp__playwright__browser_take_screenshot` with `filename={artifacts_dir}/ui-<route-slug>-<state>.png`. For each changed route, capture at minimum the default state; capture loading/error states if the component renders them.
  - Failure shape: dev-server-not-up / page-returns-console-error / network-failure → `bash bin/pipeline.sh event {issue_id} verdict halt --reason smoke-failed`.
  - Stage-summary reference: list screenshots by RELATIVE path under `artifacts/` (NOT absolute paths — the stage-summary is read by humans on the operator host, not the dispatch host).
- [ ] Edit §6 (QA). Insert a new H3-block titled `### 3.5 End-to-end verification (browser) (MANDATORY when the profile names a frontend layer and the diff touches user-visible routes):` immediately AFTER §3's closing line `... Missing → P0.` at line 1618 and BEFORE the `4. **Regression-intent audit:**` anchor at line 1620. Content anchor: the literal `4. **Regression-intent audit:**` line. Body parallels §4's block but scoped to verifying acceptance criteria render as expected per the plan's Failure Mode → Test Map rows that name user-visible behavior; same predicate, same workflow, same screenshot path convention.
- [ ] Edit §4 stage-summary Notes-slot (L1162-1174) and §6 stage-summary Notes-slot (Decision-path C at L1720-1728; Decision-path D at L1737-1742). For each, append a NEW MANDATORY line to the Notes section's contract: *"MANDATORY: include exactly one of `Browser verification: performed · routes=<list> · screenshots=<count> · path=artifacts/`, `Browser verification: skipped · reason=<no-frontend|docs-only-diff|profile-no-e2e-command|no-route-changed>`, or `Browser verification: failed · reason=<dev-server-not-up|navigation-error|screenshot-error> · details=<one-line>`. Missing this line on a ui/qa dispatch is a protocol-violation (caught at brainstorm/review time today; transcript detective deferred per brainstorm D-10)."* Content anchor for each insertion: the existing Notes paragraph text and the surrounding bullet list. Place the new MANDATORY line within the Notes-slot description block.
- [ ] Confirm AGENT_PROMPTS.md still has exactly TWO column-0 ``` fences in §4 (lines 1050 and 1208) AND exactly TWO in §6 (lines 1524 and 1784). The `render-prompt.sh` extraction contract dies if fence count is not exactly 2. Confirm via: `grep -cE '^\`\`\`$' AGENT_PROMPTS.md` returns the same total it returned pre-edit (i.e., 18 fences for 9 stages).
- [ ] Run `bash bin/agent-prompts-content-test.sh` and `bash bin/render-prompt-test.sh` and confirm pass.

### Task 5: project-profile.md `## File layout` — add `mcp/`

- `depends_on: [0]`
- `touches: learned-rules/harness/project-profile.md::## File layout`
- [ ] Edit `learned-rules/harness/project-profile.md`. Insert a new bullet `- \`mcp/\` — checked-in MCP server config files (e.g. \`playwright.json\` and \`playwright-headful.json\`) referenced by \`bin/dispatch.sh\` via \`$HARNESS_ROOT/mcp/\`. Per-stage MCP gating lives in \`bin/dispatch.sh::_dispatch_mcp_enabled_for\`; presence-check + die contract lives in \`dispatch.sh::main\`.` BETWEEN the `launchd/` bullet (L141 informational; content anchor: literal `\`launchd/\` — \`*.plist.template\`...`) and the `docs/brainstorms/` bullet (L142 informational; content anchor: literal `\`docs/brainstorms/\` and \`docs/plans/\`...`).
- [ ] Run `bash bin/profile-allowlist-test.sh` and confirm pass (no behavioural change — the test pins the H2 section presence + parsing shape).

### Task 6: `bin/dispatch.sh` — `_dispatch_mcp_enabled_for` helper + allowed-tools splice + main argv splice + new sibling test

- `depends_on: [0, 1]` — config files must exist on disk before the dispatch path's `[[ -f "$mcp_cfg_path" ]]` check passes (Task 1); rebase (Task 0) must run before anything.
- `touches: bin/dispatch.sh::_dispatch_mcp_enabled_for, bin/dispatch.sh::allowed_tools_for, bin/dispatch.sh::main, bin/dispatch-playwright-test.sh`
- [ ] Add helper `_dispatch_mcp_enabled_for(stage)` directly ABOVE the `allowed_tools_for() {` definition (content anchor: the literal `allowed_tools_for() {` at line 526). Body:
  - Stage gate: return non-zero unless stage is `ui` or `qa` (`case "$1" in ui|qa) ;; *) return 1 ;; esac`).
  - Config read: `[[ -f "${CONFIG:-}" ]] || { return 0; }` — missing CONFIG defaults to enabled (per brainstorm D-3 / issue decision #3: default true).
  - jq presence read: `local enabled; enabled="$(jq -r '.mcp.playwright.enabled // true' "$CONFIG" 2>/dev/null || printf 'true')"` — non-object / non-bool defaults to enabled.
  - Final gate: `[[ "$enabled" == "false" ]] && return 1 || return 0`.
- [ ] Splice MCP wildcard into `allowed_tools_for`. AFTER the existing `[[ -n "$extras" ]] && result="${result},${extras}"` line at L571 and BEFORE the `printf '%s' "$result"` line at L572 (content anchor: literal `[[ -n "$extras"`), insert:
  ```bash
  if _dispatch_mcp_enabled_for "$1"; then
    result="${result},mcp__playwright__*"
  fi
  ```
  Carries the ENG-94 4-tier composition order: `base + profile + extras + mcp` (per brainstorm §2 and D-1 rationale).
- [ ] Splice `--mcp-config` into `main()`. AFTER the existing `--add-dir` block ending at line 755 (content anchor: the `fi` that closes the `if [[ -n "$issue_state_dir" ]]; then` block at L753-755) and BEFORE the `cmd+=( \n --setting-sources project,local \n …` block opening at line 756 (content anchor: literal `--setting-sources project,local`), insert:
  ```bash
  if _dispatch_mcp_enabled_for "$stage"; then
    local mcp_cfg_path="$HARNESS_ROOT/mcp/playwright.json"
    [[ "${PLAYWRIGHT_HEADFUL-}" == "1" ]] && mcp_cfg_path="$HARNESS_ROOT/mcp/playwright-headful.json"
    [[ -f "$mcp_cfg_path" ]] || die "dispatch: MCP config missing at $mcp_cfg_path (commit the file or set config.mcp.playwright.enabled=false)"
    cmd+=(--mcp-config "$mcp_cfg_path")
  fi
  ```
  Note the splice site is AFTER the `PIPELINE_DRY_RUN=1` early-return (L668-687), so `--mcp-config` is never appended in dry-run — satisfying D-5. The `mcp__playwright__*` allowlist entry IS appended in dry-run because `allowed_tools_for` runs at L581 BEFORE the dry-run gate at L668 — also satisfying D-5.
- [ ] Add `bin/dispatch-playwright-test.sh`:
  - `T_mcp_gate_coherent` — for each (stage ∈ {ui, qa}) × (config ∈ {missing, true, false}) × (dry-run ∈ {0, 1}), assert the joint shape of `allowed_tools_for "$stage"` output AND the dry-run argv echo. When config != false AND dry-run=0: argv must contain BOTH `mcp__playwright__*` AND `--mcp-config <some-path-ending-in-.json>`. When config = false: NEITHER. When dry-run=1: `mcp__playwright__*` PRESENT but `--mcp-config` ABSENT.
  - `T_other_stages_no_mcp` — for each stage ∈ {brainstorming, planning, implementing, reviewing, building, released}, assert `mcp__playwright__*` ABSENT from `allowed_tools_for` AND `--mcp-config` ABSENT from the dry-run argv echo regardless of config.mcp.playwright.enabled value.
  - `T_missing_config_dies` — set up `HARNESS_ROOT` to point at a tree where `mcp/playwright.json` is intentionally MISSING; invoke dispatch on stage=ui with config-enabled and dry-run=0 via a stubbed `claude` binary; assert dispatch exits non-zero with stderr containing `dispatch: MCP config missing at`.
  - `T_headful_picks_sibling_config` — set `PLAYWRIGHT_HEADFUL=1`, create both `mcp/playwright.json` AND `mcp/playwright-headful.json`, assert the argv `--mcp-config` arg ends in `playwright-headful.json`. Unset (or set to anything other than `1`), assert it ends in `playwright.json`.
  - `T_dry_run_keeps_allowlist` / `T_dry_run_skips_mcp_config` — split fixtures of `T_mcp_gate_coherent`'s dry-run cells; named separately so I-2 traces to a discrete assertion.
  - Use the source-and-stub pattern (CLAUDE.md "Tests"): set `PIPELINE_DRY_RUN=1`, `LINEAR_API_KEY=test-mock-key`; create a `STUB_DIR` with mock `linear.sh` and stubbed `claude`/`gtimeout`/`jq`; post-source override `TARGET_REPO` / `SCRIPT_DIR` / `CONFIG` / `HARNESS_ROOT` globals.
- [ ] Run `bash bin/dispatch-test.sh` (pre-existing Linear-MCP exclusion guard — must still pass; MCP Playwright entry must NOT be misclassified as Linear) AND `bash bin/dispatch-playwright-test.sh` (new) and confirm both pass.

### Task 7: `bin/setup.sh` — `phase_playwright_install` + `ALL_PHASES` insert

- `depends_on: [0]`
- `touches: bin/setup.sh::phase_playwright_install, bin/setup.sh::is_playwright_install_done, bin/setup.sh::ALL_PHASES`
- [ ] Add `phase_playwright_install` function AFTER `is_validate_done` (content anchor: literal `is_validate_done() { return 1; }  # always re-run on demand`) and BEFORE the `# ── Phase 11: launchd ─────` H4 (content anchor: literal `# ── Phase 11: launchd`). Body:
  ```bash
  phase_playwright_install() {
    print_phase_header "playwright-install"
    if ! command -v npx >/dev/null 2>&1; then
      die "playwright-install: npx not on PATH. Install Node.js (brew install node) or unset this phase via PIPELINE_SKIP_PHASES=playwright-install."
    fi
    log "playwright-install: running 'npx playwright install chromium' (≈30-250 MB on first run; cached afterwards)"
    npx playwright install chromium || die "playwright-install: 'npx playwright install chromium' exited non-zero. Re-run after fixing the underlying error; the phase is idempotent."
  }
  ```
- [ ] Add `is_playwright_install_done` immediately after `phase_playwright_install`:
  ```bash
  is_playwright_install_done() {
    command -v npx >/dev/null 2>&1 || return 1
    npx playwright install --dry-run chromium >/dev/null 2>&1
  }
  ```
  Implementer to verify the `--dry-run` flag is correctly named by upstream at implement time. If absent in the upstream Playwright version, fall back to `return 1` (always re-run; the install step is idempotent enough that re-running on every setup invocation is acceptable).
- [ ] Update `ALL_PHASES` at line 723. Content anchor: literal `ALL_PHASES=(workspace linear-auth linear-identity linear-schema slug-freeze project-profile github-app gh-cli slack config-defaults validate launchd)`. Replace `validate launchd` with `validate playwright-install launchd`.
- [ ] Run `bash bin/setup-test.sh` and `bash bin/setup-helpers-test.sh` and confirm pass.

### Task 8: project-profile.md `## Build & test gates` + profile-allowlist test for I-6

- `depends_on: [0, 6]` — the new test file must exist before the gate command tries to run it (Task 6); rebase (Task 0) must run before anything.
- `touches: learned-rules/harness/project-profile.md::## Build & test gates, bin/profile-allowlist-test.sh::T_profile_file_layout_lists_mcp`
- [ ] Edit `learned-rules/harness/project-profile.md`. Append `&& bash bin/dispatch-playwright-test.sh` to the Test command string at line 17. Content anchor: the trailing closing-paren-and-comment that ends the Test command's `&&`-chain — specifically the literal `bash bin/retro-shape-claude-version-drift-test.sh\`` ending the chain. Insert `&& bash bin/dispatch-playwright-test.sh` BEFORE the closing backtick.
- [ ] Add an assertion to `bin/profile-allowlist-test.sh` named `T_profile_file_layout_lists_mcp` that greps the profile's `## File layout` section for a `mcp/` bullet and fails loudly if absent. Anchors I-6 to a runnable test. Place the new function adjacent to existing `T_*` assertions; use the file's existing source-and-stub pattern.
- [ ] Run `bash bin/profile-allowlist-test.sh` and confirm pass.

## 7. Frontend Tasks

N/A — the harness has no frontend layer. The profile's Stack section explicitly states `Bash 3.2+ orchestration scripts ... The repo contains no application code`. The UI agent's pass-through path at `AGENT_PROMPTS.md:1053` will fire for any harness-self ui dispatch. The `Browser verification: skipped · reason=no-frontend` line will be emitted by the agent per D-10 (covered by Task 4's §4 edits).

## 8. Failure Mode → Test Map

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
|---|---|---|---|---|
| `mcp/playwright.json` absent at dispatch time when MCP enabled | `_dispatch_mcp_enabled_for(stage)` returns truthy but `[[ -f "$mcp_cfg_path" ]]` fails | `die "dispatch: MCP config missing at $mcp_cfg_path (commit the file or set config.mcp.playwright.enabled=false)"` | unit (sourced bash) | `bin/dispatch-playwright-test.sh::T_missing_config_dies` |
| `npx -y @playwright/mcp@latest` fails to install at dispatch time (no network, npm down) | MCP child exits before agent's first tool call | Claude CLI surfaces the MCP child failure as a stream-json error event; agent's `mcp__playwright__*` calls return errors; agent halts with `verdict halt --reason agent-blocked` per existing protocol | (not covered by new test — runtime npm-failure shape lives in the prompt's instructions) | (none — relies on AGENT_PROMPTS.md §4/§6 halt path) |
| Chromium binary missing at runtime (host cache wiped) | First `mcp__playwright__browser_navigate` call fails with "browser not installed" Playwright error | Same as above — agent halts `agent-blocked`; operator remediation: re-run `bash bin/setup.sh playwright-install` | (not covered — runtime-side) | (none) |
| Agent forgets `{artifacts_dir}/` prefix when calling `mcp__playwright__browser_take_screenshot` | Screenshot lands in agent CWD = worktree | Post-dispatch `partition_dirty_paths` classifies `.png` at worktree root as `self-leak` (new untracked path) → hard fail per `bin/run-local.sh` self-leak gate (existing behavior, unchanged by this plan) | integration | (existing `bin/run-local-sweep-test.sh` self-leak case — covers any untracked path; no new test needed) |
| Dev server fails to come up | Agent's HTTP probe returns non-200 within 30s timeout | Agent halts with `verdict halt --reason smoke-failed` per AGENT_PROMPTS.md §4 block | (not covered — runtime-side; structural pin via AGENT_PROMPTS.md content) | `bin/agent-prompts-content-test.sh` (verifies §4 contains the literal `smoke-failed` halt token) |
| `PLAYWRIGHT_HEADFUL=1` set but `mcp/playwright-headful.json` missing | `[[ -f "$mcp_cfg_path" ]]` check fails for the headful path | `die "dispatch: MCP config missing at $mcp_cfg_path …"` (same die-shape as the headless path) | unit | `bin/dispatch-playwright-test.sh::T_missing_config_dies` (covers both paths under one assertion family) |
| `PIPELINE_DRY_RUN=1` echo argv missing `mcp__playwright__*` on ui/qa | Wiring regression in `allowed_tools_for` or its composition | argv echo MUST contain `mcp__playwright__*`; absence is a wiring regression | unit | `bin/dispatch-playwright-test.sh::T_dry_run_keeps_allowlist` |
| `PIPELINE_DRY_RUN=1` echo argv includes `--mcp-config` on ui/qa | Wiring regression in `main()`'s gating clause | argv echo MUST NOT contain `--mcp-config`; presence violates the dry-run contract | unit | `bin/dispatch-playwright-test.sh::T_dry_run_skips_mcp_config` |
| `config.mcp.playwright.enabled=false` but allowed-tools still has `mcp__playwright__*` | Composition order or gate-helper bug | `allowed_tools_for` must NOT include `mcp__playwright__*` when the gate helper returns 1 | unit | `bin/dispatch-playwright-test.sh::T_mcp_gate_coherent` (cell: ui × config=false → both absent) |
| Non-ui/qa stage carries MCP segment | Stage-gate predicate bug | `allowed_tools_for` MUST NOT include `mcp__playwright__*` for any of {brainstorming, planning, implementing, reviewing, building, released}; `--mcp-config` MUST NOT appear in dry-run argv | unit | `bin/dispatch-playwright-test.sh::T_other_stages_no_mcp` |
| `{artifacts_dir}` token in AGENT_PROMPTS.md without a resolver | Mis-edit of AGENT_PROMPTS.md leaving the token unregistered | `bin/render-prompt.sh:421` `die "render-prompt: unknown token '{artifacts_dir}'..."`; halts every ui/qa render | unit | `bin/render-prompt-test.sh` (existing test that asserts every `{token}` in `AGENT_PROMPTS.md` has a `PROMPT_RESOLVERS` entry — registry-coverage pin) |
| Profile's `## File layout` missing `mcp/` bullet | Profile not updated; mcp/*.json on the implementing branch counted as self-leak | `partition_dirty_paths` halts the dispatch; rapid feedback during T1 development | unit | `bin/profile-allowlist-test.sh::T_profile_file_layout_lists_mcp` (added in Task 8) |

## 9. Test Strategy

- **Unit (sourced shell)**: `bin/dispatch-playwright-test.sh` covers the four-cell gating matrix (stage × config × dry-run), the missing-config `die`, and the `PLAYWRIGHT_HEADFUL=1` selector. Stub `claude`, `gtimeout`, `jq` and post-source overrides per CLAUDE.md "Tests" → source-and-stub pattern. Sentinel-protected `main` ensures sourcing dispatch.sh does not fire its `main`.
- **Integration (existing)**: `bin/run-local-sweep-test.sh` already pins the self-leak path for any untracked file at the worktree root — no new test needed for the agent-forgets-the-prefix failure mode.
- **Content pins (existing)**: `bin/agent-prompts-content-test.sh` greps AGENT_PROMPTS.md for invariant tokens; extends naturally to assert the new MANDATORY `Browser verification:` outcome-line tokens in §4 and §6. `bin/render-prompt-test.sh` includes a registry-coverage pin (per render-prompt.sh L446 commentary) that asserts every `{token}` in AGENT_PROMPTS.md has a `PROMPT_RESOLVERS` entry; this catches a regression where the `{artifacts_dir}` resolver registration is dropped while the body still references the token.
- **Smoke (manual, post-implement)**: PIPELINE_DRY_RUN=1 dispatch of stage=ui against a real Linear issue (any existing ENG-N) should echo `mcp__playwright__*` in `--allowed-tools` and NOT include `--mcp-config`. Cross-check via `bash bin/status.sh` and the per-stage transcript.
- **Adversarial (negative)**: `T_missing_config_dies` covers the operator-stripped `mcp/` directory case; `T_other_stages_no_mcp` covers the "MCP segment leaks to a non-ui/qa stage" case.
- **Test-gate closure (REMOVAL side)**: No production tokens removed. Verified.
- **Test-gate closure (ADD side)**: `bin/dispatch-playwright-test.sh` is the only new sibling test file. `learned-rules/harness/project-profile.md::## Build & test gates` Test command is updated by Task 8 to include it. The pre-commit hook (`.githooks/pre-commit`) runs the entire `bin/*-test.sh` suite, so the new test runs automatically on commit regardless.
- **What is explicitly NOT tested by this plan**:
  - Live `npx -y @playwright/mcp@latest` invocation (deferred to OQ-1 / OQ-2 implement-time verification).
  - Cross-browser matrix (chromium-only per issue decision).
  - Visual regression / pixel diff (issue out-of-scope).
  - Agent-side prompt-discipline ("did the agent actually navigate?") — agent-side and prompt-content shaped, not bash-side. The MANDATORY `Browser verification:` outcome-line contract in §4/§6 is the v1 enforcement; a future transcript detective ticket (mentioned in brainstorm D-10) closes the gap.
