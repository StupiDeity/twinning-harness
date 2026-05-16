---
linear: ENG-130
date: 2026-05-16
topic: Restructure bin/run-retrospective-local.sh into a deterministic bash coordinator that iterates a hard-coded SHAPES array, extract the 11 remaining §9 behaviors as independently-invocable shape scripts, aggregate per-shape artifacts into one PR, and delete AGENT_PROMPTS.md §9.
---

# Plan — ENG-130 retrospective split: coordinator + migrate remaining behavior

## Anti-anchoring check

**Problem restatement (user view):** "The first shape (`stage-failure-summary`) shipped as PoC. Now restructure the retrospective binary so all 12 behaviors live in shape scripts, the parent runs them as a deterministic loop, and one confused shape no longer blocks the other 11 from contributing to the weekly PR."

**Does the brainstorm address this?** Yes. D-001 deletes the inline `claude -p` from the coordinator (Linear AC #1). D-002 hard-codes the `SHAPES` array. D-003 mechanically extracts the eleven new shapes from §2–§12 of the pre-ENG-130 §9 monolith. D-005 supersedes ENG-129 D-006's halt-on-shape-failure with log-and-continue (required by AC #3's "some-shapes-skip" path). D-006 composes the PR body in bash (no synthesizing agent). D-010 ships the three AC #3 fixtures plus eight error/edge fixtures.

**Solution proportionality:** The coordinator restructure is one bash file edit; the eleven new shapes are mechanical replications of the ENG-129 PoC pattern (one prompt body + one driver + one sibling test each). 24 net-new files (11 prompts + 11 drivers + 11 tests + 1 coordinator test ≈ 34, with deduplication for already-shipped stage-failure-summary). No new vocabulary, no new metric event, no allowlist extension, no launchd plist change. Matches Ticket sizing rubric: 1 subsystem (retrospective), 1 design cluster (coordinator + shape replication template). **No reframing or disproportionality found — proceed without escalation.**

## Branch-base freshness check

`git log --oneline HEAD..origin/main` was EMPTY at plan time.
branch-base freshness: HEAD..origin/main empty at plan time (origin/main = fb3d1b76a6d3b67ac0a28505cfeaff26bf9f256b).
No Task 0 rebase needed; line-number hints below are reasonably stable, but every Edit-boundary step still names a content anchor in addition.

## 1. Goal

Restructure `bin/run-retrospective-local.sh::main` into a deterministic bash coordinator that iterates a hard-coded `SHAPES=(stage-failure-summary gotcha-recurrence convention-drift gotcha-promotion human-override expiry-verification confirmation-bias-audit recency-bias survivorship-bias knowledge-budget pipeline-health-score prompt-workflow-amendment)` array, dispatches each shape via `bash bin/retro-shape-<name>.sh`, catches per-shape rc!=0 as a non-blocking failure (log + continue), composes the PR body in bash by concatenating succeeded shapes' artifacts under a `## Period` preamble + `## Failed shapes` footer, opens exactly one PR iff `git diff --cached` shows non-zero tracked-file changes after all shapes run, and deletes AGENT_PROMPTS.md §9 in the same commit so the file's "sections 1–8 are dispatch stages" invariant becomes literally true.

Verifiable outcome:
- `bash bin/run-retrospective-local-test.sh` exits 0 (covers AC #3's three coordination paths plus 8 error/edge fixtures per D-010).
- All eleven `bash bin/retro-shape-<name>-test.sh` files exit 0 (covers shape-side argv parsing, dry-run placeholder, token resolution, dispatch failure, artifact-missing-die per D-003 fixture template).
- `bash bin/agent-prompts-content-test.sh` continues to pass (covers AGENT_PROMPTS.md §0–§8 fence-count + §0 cross-stage rules; the §9 deletion is reflected by dropping `## 9. Retrospective Agent (Scheduled)` from the six per-stage for-loops per the test-gate closure sweep in §7).
- `PIPELINE_DRY_RUN=1 TARGET_REPO=… bash bin/run-retrospective-local.sh` produces 12 placeholder artifacts under `$PROJECT_STATE_DIR/retrospective-${today}/`, composes `pr-body.md`, and exits 0 with no `gh pr create` invocation (covers AC #2's PR-shape end-to-end in dry-run).
- `grep -c '^## ' AGENT_PROMPTS.md | grep -c '^9\.'` returns 0 (§9 is gone; the "sections 1–8 are dispatch stages" invariant holds literally).

## 2. Assumption Inventory

Format: `[verified|assumed]` ITEM — `path:line` reference (or "assumed/new" with target path).

### Verified — quoted from the current tree

- `[verified]` `bin/run-retrospective-local.sh:51` — `main()` entrypoint opens with `local today branch log_file prompt_file`.
- `[verified]` `bin/run-retrospective-local.sh:38-49` — `_compute_retro_period` helper (introduced by ENG-129); D-008 reuses unchanged. The coordinator's loop calls this helper ONCE per run and passes the two ISO timestamps to every shape.
- `[verified]` `bin/run-retrospective-local.sh:52-55` — local declarations + `today="$(date -u +%Y-%m-%d)"`. The coordinator's artifact directory `$PROJECT_STATE_DIR/retrospective-${today}/` reuses this var.
- `[verified]` `bin/run-retrospective-local.sh:62-66` — fresh-checkout guard `die`s on a dirty `$TARGET_REPO`. Coordinator runs AFTER this guard (preserved verbatim).
- `[verified]` `bin/run-retrospective-local.sh:71-77` — branch checkout/reset off origin/main (idempotent on same-day re-run). Preserved verbatim.
- `[verified]` `bin/run-retrospective-local.sh:85-88` — `period_lines = _compute_retro_period; period_start_iso, period_end_iso = sed -n '1p'/'2p'`. The coordinator's loop iterates AFTER these three lines.
- `[verified]` `bin/run-retrospective-local.sh:89-101` — existing ENG-129 single-shape invocation block (`shape_artifact_dir`, `stage_failure_summary_path`, `mkdir -p`, `bash retro-shape-stage-failure-summary.sh ...`, `slack.sh error + exit 20` on rc != 0). **D-001 deletes lines 89–101** and replaces with the loop body of D-005.
- `[verified]` `bin/run-retrospective-local.sh:103-128` — existing §9 awk extraction + sed substitution + `bash dispatch.sh retrospective ... + exit 20 on dispatch failure + rm -f $prompt_file`. **D-001 deletes lines 103–128.**
- `[verified]` `bin/run-retrospective-local.sh:131-138` — existing no-changes branch (`git add -A`; `git diff --cached --quiet` → log + slack info + checkout main + branch -D). **D-007 preserves verbatim with one addition:** if `failed_shapes` is non-empty AND no diff, slack `error` carries the failure summary instead of `info`.
- `[verified]` `bin/run-retrospective-local.sh:140-149` — existing commit/push/`gh pr create --body "Automated weekly retrospective..."` block. **D-006 modifies line 146-148** to use `--body-file "$pr_body_path"` against the bash-composed PR body.
- `[verified]` `bin/run-retrospective-local.sh:156-158` — sentinel `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi`. Preserved.
- `[verified]` `AGENT_PROMPTS.md:1735` — `## 9. Retrospective Agent (Scheduled)` H2 header.
- `[verified]` `AGENT_PROMPTS.md:1737,1948` — §9's two column-0 fences (open at 1737, close at 1948). §9 spans the rest of the file; line 1948 is the file's last line.
- `[verified]` `AGENT_PROMPTS.md:1734` — blank line between §8's closing fence (`AGENT_PROMPTS.md:1733`) and §9's H2. **D-011 deletes from `AGENT_PROMPTS.md:1734` (the blank line) through `AGENT_PROMPTS.md:1948` (the closing fence) inclusive.** File ends at line 1733 post-deletion (`- No edits to any source files. You are a read-only observer plus Linear/Slack writer.` then closing fence `\`\`\``).
- `[verified]` `AGENT_PROMPTS.md` H2 inventory via `grep -n '^## ' AGENT_PROMPTS.md`: numbered sections at lines 212 (§0), 234 (§1), 348 (§2), 608 (§3), 797 (§4), 938 (§5), 1180 (§6), 1361 (§7), 1627 (§8), 1735 (§9). §9 is the LAST numbered section; deletion does not require renumbering.
- `[verified]` `bin/dispatch.sh:375-405` — `allowed_tools_for` per-stage case statement. Line 403 (`retrospective)`) base allowed-tools = `Read,Write,Edit,Grep,Glob,TaskCreate,Agent,Bash(git log:*),Bash(git diff:*),Bash(git show:*),Bash(git rev-list:*),Bash(git describe:*),Bash(jq:*),Bash(awk:*),Bash(bash .pipeline/bin/linear.sh:*),Bash(bash bin/linear.sh:*),Bash(bash .pipeline/bin/pipeline.sh:*),Bash(bash bin/pipeline.sh:*),Bash(bash .pipeline/bin/guards.sh:*),Bash(bash bin/guards.sh:*),Bash(bash .pipeline/bin/metrics.sh:*),Bash(bash bin/metrics.sh:*)`. **D-004 reuses verbatim — no allowlist edit.**
- `[verified]` `bin/dispatch.sh:439` — `if [[ -n "${PIPELINE_ISSUE_ID:-}" ]]; then` gates `usage-<stage>.json` write. Retrospective dispatches leave PIPELINE_ISSUE_ID unset; shapes inherit (no usage-shape-*.json telemetry).
- `[verified]` `bin/dispatch.sh:469-472` — per-stage timeout default `case "$stage" in brainstorming|planning) timeout_minutes=60;; *) timeout_minutes=30;; esac`. Each shape gets its own 30-min gtimeout boundary (better than today's monolith sharing one).
- `[verified]` `bin/retro-shape-stage-failure-summary.sh:1-115` — the shape driver pattern D-003 mirrors. Helpers: `_parse_args` (lines 16-40), `_render_prompt` (lines 42-53), `_validate_no_unresolved_tokens` (lines 55-74), `main` (lines 76-110). Sentinel at line 112-114.
- `[verified]` `bin/retro-shape-stage-failure-summary.sh:11-14` — argv globals `_ARTIFACT_PATH`, `_PERIOD_START_ISO`, `_PERIOD_END_ISO`, `_PREVIOUS_PERIOD_PATH=(none)`. Each new shape driver mirrors.
- `[verified]` `bin/retro-shape-stage-failure-summary.sh:46-53` — `sed -e "s|{token}|val|g"` chain with `|` delimiter. Each new shape's `_render_prompt` mirrors.
- `[verified]` `bin/retro-shape-stage-failure-summary.sh:55-74` — `_validate_no_unresolved_tokens` (per-token grep + residual `\{[a-z][a-z_]*[a-z]\}` scan). Each new shape mirrors with its own token list.
- `[verified]` `bin/retro-shape-stage-failure-summary.sh:90-95` — DRY_RUN branch: log + `printf '...placeholder...' > "$_ARTIFACT_PATH"; rm -f "$rendered"; return 0`. Each new shape mirrors.
- `[verified]` `bin/retro-shape-stage-failure-summary.sh:101-106` — `bash "$SCRIPT_DIR/dispatch.sh" retrospective "$rendered" "$log_file"` with rc capture. Each new shape mirrors.
- `[verified]` `bin/retro-shape-stage-failure-summary.sh:108-109` — artifact-written check (`[[ -f "$_ARTIFACT_PATH" ]] || die ...`). Each new shape mirrors.
- `[verified]` `bin/retro-shape-stage-failure-summary-test.sh:1-578` — sibling test pattern: ~17 fixtures using `_pass`/`_fail` helpers, source-and-stub via `source "$HARNESS_DIR/retro-shape-stage-failure-summary.sh"` + `SCRIPT_DIR="$STUB_DIR"` post-source override (lines 65-68). Each new test mirrors with ≥6 fixtures (argv-missing, dry-run-happy, token-resolution, dispatch-stub-not-invoked-in-dry-run, artifact-production, artifact-missing-die, dispatch-rc-non-zero-die, unknown-flag-die).
- `[verified]` `bin/retro-prompts/stage-failure-summary.md:1-70` — prompt body schema. Sections: `## Inputs` (token enumeration), `## Insufficient-sample carve-out` (where applicable), `## Task` (verbatim §N instruction set), `## Output schema` (the artifact's H2 layout), `## Mandatory exit instructions` (`Write {artifact_path}` + "Do NOT" rules). Each new prompt body mirrors.
- `[verified]` `bin/render-prompt.sh:13-22` — `STAGE_TO_SECTION` table; line 22 carries `retrospective=9. Retrospective Agent (Scheduled)`. **No call site exists** (verified by `grep -rE 'render-prompt\.sh.{1,30}retrospective' bin/` — zero non-doc matches). After §9 deletion the entry would point at a non-existent section; **Task 9 deletes line 22 for cleanliness**.
- `[verified]` `bin/render-prompt.sh:75` — `AGENT_RUNTIME_TOKENS=' file pr_number stage_failure_summary_path '`. The `stage_failure_summary_path` token only appears in §9 (verified by `grep -n stage_failure_summary_path AGENT_PROMPTS.md` showing lines 1778, 1786 — both inside §9). **Task 9 removes `stage_failure_summary_path` from this list** since the only consumer is being deleted.
- `[verified]` `bin/render-prompt.sh:91-130` — `extract_block` fence-count == 2 invariant. Sections 1–8 retain their fence count post-§9-deletion; the invariant is unaffected.
- `[verified]` `bin/render-prompt-test.sh:266-305` — case 87-R5 token-coverage test: every `{token}` in AGENT_PROMPTS.md must be in `PROMPT_RESOLVERS` OR `released_tokens` OR `AGENT_RUNTIME_TOKENS`. After §9 deletion, `{stage_failure_summary_path}` no longer appears in AGENT_PROMPTS.md; the AGENT_RUNTIME_TOKENS entry becomes orphaned but harmless. Removing the entry (Task 9) keeps the test passing because the entry-source (AGENT_PROMPTS.md) drives the scan, not the registry.
- `[verified]` `bin/render-prompt-test.sh:85-91` — case 6.3 `retrospective stage skips addendum` invokes `append_project_profile retrospective`. The function-side carve-out (`bin/render-prompt.sh:188-191`) does NOT depend on STAGE_TO_SECTION; case-6.3 still passes after Task 9.
- `[verified]` `bin/agent-prompts-content-test.sh:20-40` — `section_body` and `rendered_stage_body` helpers. `rendered_stage_body "## 9. ..."` after §9 deletion returns just §0's body (the §9 section_body is empty). Existing `grep -qE 'rule_phrase'` checks on §0-sourced phrases would still PASS but become meaningless for the §9 iteration. **Task 8 drops `## 9. Retrospective Agent (Scheduled)` from each per-stage for-loop** so the test surface tracks reality.
- `[verified]` `bin/agent-prompts-content-test.sh:441-477` — first per-stage for-loop (Tool allowlist & probing rule from §0); list ends with `## 9. Retrospective Agent (Scheduled)` at line 450.
- `[verified]` `bin/agent-prompts-content-test.sh:487-509` — second per-stage for-loop (ENG-56 `pipeline:halted` is orchestrator-managed); list ends with `## 9.` at line 496.
- `[verified]` `bin/agent-prompts-content-test.sh:522-554` — third per-stage for-loop (ENG-57 same-sig retry rule); list ends with `## 9.` at line 531.
- `[verified]` `bin/agent-prompts-content-test.sh:566-591` — fourth per-stage for-loop (ENG-74 env-var-prefix rule); list ends with `## 9.` at line 575.
- `[verified]` `bin/agent-prompts-content-test.sh:1019-1038` — fifth per-stage for-loop (ENG-74 round 2 — trigger→example→target linkage); list ends with `## 9.` at line 1028.
- `[verified]` `bin/agent-prompts-content-test.sh:1225-1241` — sixth per-stage for-loop (ENG-100 sub-agent debris rule, QA adversarial); list ends with `## 9. Retrospective Agent (Scheduled)` at line 1232.
- `[verified]` `bin/common.sh:30,34` — `log` / `die` helpers (used by coordinator + every shape driver).
- `[verified]` `bin/common.sh:478-484` — `CLAUDE_SEMAPHORE_DIR="$HARNESS_STATE_DIR/.claude-semaphore"`. K=2 default caps simultaneous dispatches; sequential shape loop consumes one slot at a time, leaving one for pipeline ticks.
- `[verified]` `bin/common.sh:56-62` — `PROJECT_STATE_DIR` resolution. Coordinator and every shape use this var verbatim.
- `[verified]` `bin/common.sh:617-622` — `require_env`, `require_bin`. Coordinator already calls `require_env LINEAR_API_KEY` + `require_bin claude gh git jq` (lines 29-30); preserved.
- `[verified]` `bin/slack.sh::main` accepts `info | error` + body — used by coordinator's end-of-run notification (per D-005).
- `[verified]` `launchd/com.twinning.retrospective.plist.template:12` — `ProgramArguments → bin/run-retrospective-local.sh`. **NOT modified** by ENG-130; external contract (Mondays 09:00 → PR) preserved.
- `[verified]` `CLAUDE.md` "Retrospective shapes (ENG-129)" section (~lines 78–95 — exact range may have shifted, anchor by header text). Names "the parent retrospective Reads each artifact via a `{<name>_path}` token interpolated into AGENT_PROMPTS.md §9." **Task 10 rewrites this paragraph** for the coordinator architecture.
- `[verified]` Repo lacks `docs/VISION.md`, `docs/knowledge/`, `learned-rules/harness/plan.md` (verified by directory listing). The brainstorm prompt's "skip if not present" clause applies.
- `[verified]` `learned-rules/harness/` contains only `build.md` + `project-profile.md` — no `plan.md` learned rules to follow.
- `[verified]` Existing files NOT being touched but cited by feasibility: `bin/render-prompt.sh:188-191` (`append_project_profile`'s `retrospective` carve-out — left in place for safety since `dispatch.sh retrospective` is invoked by shapes), `bin/render-prompt.sh:13-22` STAGE_TO_SECTION (line 22 deleted; lines 13-21 unchanged).

### Assumed — needs verification at implementation time

- `[assumed/new]` Eleven new prompt bodies under `bin/retro-prompts/` (`gotcha-recurrence.md`, `convention-drift.md`, `gotcha-promotion.md`, `human-override.md`, `expiry-verification.md`, `confirmation-bias-audit.md`, `recency-bias.md`, `survivorship-bias.md`, `knowledge-budget.md`, `pipeline-health-score.md`, `prompt-workflow-amendment.md`). Each is a verbatim move of the corresponding §N from the pre-ENG-130 `AGENT_PROMPTS.md` §9 body, restructured with the five ENG-129 template sections. Created by Task 2.
- `[assumed/new]` Eleven new shape drivers `bin/retro-shape-<name>.sh` (one per name above). Each ~110-130 lines mirroring `bin/retro-shape-stage-failure-summary.sh`. Created by Task 3.
- `[assumed/new]` Eleven new sibling tests `bin/retro-shape-<name>-test.sh`. Each ≥6 fixtures; ~250-350 lines (smaller than the PoC's 578 because the PoC over-covered argv permutations during pattern bring-up). Created by Task 4.
- `[assumed/new]` New coordinator-level test `bin/run-retrospective-local-test.sh` covering the 11 fixtures from D-010 (`cf-1` all-succeed-PR-opened through `cf-11` aggregator-orders-by-shapes-array). Created by Task 6.
- `[assumed]` Each shape's prompt body, when restructured per the ENG-129 template, produces output BYTE-COMPATIBLE with today's §N inline behavior. Behavioral claim — verifiable by inspection of each shape's output schema in PR review. The eleven moves are mechanical; drift risk is minor.
- `[assumed]` `gh pr create --body-file` is supported on the launchd host's `gh` version (since gh 2.0, 2022). Fallback path: `--body "$(cat pr-body.md)"` per brainstorm §5's "gh pr create fails" branch.
- `[assumed]` The harness-self target's `.pipeline-config/config.json::dispatch.tools.{implementing,qa}[]` is operator-owned and lives outside this worktree. After Task 4 lands, the operator regenerates the list per the CLAUDE.md "Wildcard pitfall" snippet to add the twelve new `bin/retro-shape-<name>-test.sh` files plus `bin/run-retrospective-local-test.sh`. The PR description flags this as an operator follow-up; it is NOT a code change in this PR (verified absent from the worktree at plan time).
- `[assumed]` Pre-commit hook (`.githooks/pre-commit`) runtime grows from ~30s today to ~60-90s after the 12 new test files. Borderline; if observed >60s in implementation, Task 11 documents the new baseline in CLAUDE.md.
- `[assumed]` `_resolve_previous_period_artifact`'s `find -maxdepth 1 -type d -name 'retrospective-*' | awk '$2 < today' | sort -r | head -1` shape is BSD/macOS portable. Test fixture cf-7 / cf-8 in coordinator-level test asserts the helper.

## 3. File Structure

### New files (24)

Prompt bodies (11) — `bin/retro-prompts/<name>.md`:
- `bin/retro-prompts/gotcha-recurrence.md` — verbatim move of §9 §2 (gotcha-hit / gotcha-avoided log analysis).
- `bin/retro-prompts/convention-drift.md` — verbatim move of §9 §3 (convention candidate harvest).
- `bin/retro-prompts/gotcha-promotion.md` — verbatim move of §9 §4 (new-gotcha promotion proposals).
- `bin/retro-prompts/human-override.md` — verbatim move of §9 §5 (twinning-pipeline-bot override diff).
- `bin/retro-prompts/expiry-verification.md` — verbatim move of §9 §6 (knowledge-file expiry checks).
- `bin/retro-prompts/confirmation-bias-audit.md` — verbatim move of §9 §7 (bias proposals; flag-only).
- `bin/retro-prompts/recency-bias.md` — verbatim move of §9 §8 (learned-rule recency classification).
- `bin/retro-prompts/survivorship-bias.md` — verbatim move of §9 §9 (abandoned-issue survivor analysis).
- `bin/retro-prompts/knowledge-budget.md` — verbatim move of §9 §10 (knowledge-file eviction).
- `bin/retro-prompts/pipeline-health-score.md` — verbatim move of §9 §11 (one-ratio + Δ).
- `bin/retro-prompts/prompt-workflow-amendment.md` — verbatim move of §9 §12 (prompt/config/workflow edits). OQ-5: drop §12's references to "§9 itself"; replace with "may propose edits to AGENT_PROMPTS.md §§1-8 and `bin/retro-prompts/<name>.md`".

Shape drivers (11) — `bin/retro-shape-<name>.sh` (`chmod 755`):
- `bin/retro-shape-gotcha-recurrence.sh`
- `bin/retro-shape-convention-drift.sh`
- `bin/retro-shape-gotcha-promotion.sh`
- `bin/retro-shape-human-override.sh`
- `bin/retro-shape-expiry-verification.sh`
- `bin/retro-shape-confirmation-bias-audit.sh`
- `bin/retro-shape-recency-bias.sh`
- `bin/retro-shape-survivorship-bias.sh`
- `bin/retro-shape-knowledge-budget.sh`
- `bin/retro-shape-pipeline-health-score.sh`
- `bin/retro-shape-prompt-workflow-amendment.sh`

Sibling tests (11) — `bin/retro-shape-<name>-test.sh` (`chmod 755`):
- one test sibling per driver above; same naming convention.

Coordinator-level test (1):
- `bin/run-retrospective-local-test.sh` (`chmod 755`) — covers the 11 fixtures of D-010 + the supporting helpers (`_resolve_previous_period_artifact` lookup, `_compute_retro_period` reuse).

### Modified files (4)

- `bin/run-retrospective-local.sh` — add `SHAPES` array (Task 1) + `_resolve_previous_period_artifact` helper (Task 1); rewrite `main()` (Task 5) to delete lines 89-128 (existing single-shape invocation + §9 awk extract + dispatch + cleanup), insert the shape-iteration loop (D-005), insert PR body composition (D-006), modify `gh pr create` (line 146-148) to use `--body-file` (D-006), and update the no-changes branch's slack semantics (D-005's failure-summary line). Touched functions: `main` only; new top-level functions: `SHAPES` (array, not function), `_resolve_previous_period_artifact`.
- `AGENT_PROMPTS.md` — delete `AGENT_PROMPTS.md:1734` (blank line) through `AGENT_PROMPTS.md:1948` (closing fence) inclusive (Task 7). File ends at line 1733 post-deletion. Validates via `bash bin/agent-prompts-content-test.sh` + `bash bin/render-prompt-test.sh`.
- `bin/render-prompt.sh` — Task 9: delete line 22 (`retrospective=9. Retrospective Agent (Scheduled)` from `STAGE_TO_SECTION`); modify line 75 (`AGENT_RUNTIME_TOKENS`) to drop `stage_failure_summary_path` from the space-separated list. Functions touched: top-level constants only (`STAGE_TO_SECTION`, `AGENT_RUNTIME_TOKENS`); no function body changes.
- `bin/agent-prompts-content-test.sh` — Task 8: drop `## 9. Retrospective Agent (Scheduled)` entries from the six per-stage for-loops at lines 450, 496, 531, 575, 1028, 1232. No new assertions; remove iterations whose target section no longer exists.
- `CLAUDE.md` — Task 10: rewrite the "Retrospective shapes (ENG-129)" section (~lines 78-95) to name the coordinator architecture: drop the "stay inline in §9 until the coordinator ticket ships" sentence and the "§9 token interpolated into AGENT_PROMPTS.md" claim; replace with "All twelve behaviors are independently-invocable shapes; `bin/run-retrospective-local.sh` iterates `SHAPES` and aggregates artifacts into one PR. To add a shape: drop a new prompt body under `bin/retro-prompts/`, write a driver + sibling test mirroring `bin/retro-shape-stage-failure-summary.sh`, append the name to `SHAPES`."

### NOT modified (intentional — recorded so reviewers don't expect changes)

- `bin/dispatch.sh` — D-004 reuses `retrospective` arm of `allowed_tools_for` at line 403; no new case, no new env var, no new timeout tier. Each shape inherits the existing 30-min gtimeout boundary (better than today's monolith sharing one budget across 12 behaviors).
- `bin/render-prompt.sh::append_project_profile` (lines 185-211) — the `retrospective` carve-out at line 188 stays (defensive: any direct `dispatch.sh retrospective` call from a shape inherits the carve-out via the existing dispatch path; render-prompt.sh is not actually invoked from shapes today, but the carve-out costs nothing).
- `bin/run-stage.sh` — shapes are NOT pipeline stages; no changes.
- `bin/pipeline-events.json` — no new vocabulary; shapes don't emit verdict markers.
- `bin/metrics.sh` — no new metric event (deferred per OQ-1).
- `launchd/com.twinning.retrospective.plist.template` — same binary entrypoint, same trigger.
- `bin/scope-check.sh`, `bin/run-local-helpers.sh::partition_dirty_paths` — shapes run inside the retrospective binary; no scope-sweep involvement.
- `learned-rules/<slug>/project-profile.md` — shapes are stack-agnostic.
- `docs/architecture.md` — two-binary topology unchanged.
- `.pipeline-config/config.json::dispatch.tools.{implementing,qa}[]` — operator-side regeneration after the PR merges (see Task 4 Notes); the file is gitignored / out-of-tree.

## 4. API Contract

No new API surface. The harness has no FE↔BE API; ENG-130 introduces no new endpoint, no new typed message, no new wire-format. Surface contracts:

- **CLI argv contract (per shape driver)** — five flags, four required + one optional:
  - `--artifact-path <abs-path>` (required) — where to Write the markdown summary.
  - `--period-start-iso <ISO-8601-UTC>` (required) — start of analysis period.
  - `--period-end-iso <ISO-8601-UTC>` (required) — end of analysis period.
  - `--previous-period-path <abs-path|"(none)">` (optional; defaults to literal `(none)`) — path to prior period's artifact for trend comparison.
  - All shapes accept the same five flags (per OQ-6: pass-always — unused flags are inert; conditional-passing complexity rejected).

- **Coordinator → shape invocation pseudocode** (canonical form for D-005):
  ```bash
  for shape in "${SHAPES[@]}"; do
    artifact="$PROJECT_STATE_DIR/retrospective-${today}/${shape}.md"
    prev="$(_resolve_previous_period_artifact "$shape" "$today")"
    if bash "$SCRIPT_DIR/retro-shape-${shape}.sh" \
         --artifact-path        "$artifact" \
         --period-start-iso     "$period_start_iso" \
         --period-end-iso       "$period_end_iso" \
         --previous-period-path "$prev"; then
      succeeded_shapes+=("$shape")
    else
      shape_rcs[$shape]=$?
      failed_shapes+=("$shape")
      log "coordinator: shape '$shape' failed; continuing with remaining shapes"
    fi
  done
  ```

- **PR body schema** (markdown; bash-side concatenation, no machine-readable fields):
  - `## Period\n<start-iso> → <end-iso>\n` preamble.
  - Per succeeded shape: `\n---\n\n` separator + verbatim artifact contents (each artifact's own `## <Shape name>` header surfaces as the section title — per D-006 / OQ-3 "shape owns its H2").
  - `## Failed shapes` footer (only if `failed_shapes` non-empty): bullet list of `- <shape> (rc=<rc>, log=<path>)`.

## 5. Backend Tasks

### Task 1: Add `SHAPES` array + `_resolve_previous_period_artifact` helper to coordinator

- `depends_on: []`
- `touches: bin/run-retrospective-local.sh (top-level constant SHAPES; new function _resolve_previous_period_artifact)`
- [ ] Open `bin/run-retrospective-local.sh`. Add SHAPES array between the closing `}` of `_compute_retro_period` (`bin/run-retrospective-local.sh:49`) and `main() {` (`bin/run-retrospective-local.sh:51`). Content anchor: AFTER the `_compute_retro_period` function's closing `}` (line ~49) BEFORE the `main() {` declaration:

  ```bash
  # ENG-130 D-002: hard-coded ordered shape registry. Order mirrors §1-§12
  # of the pre-ENG-130 AGENT_PROMPTS.md §9, which encoded the dependency
  # order chosen by humans (e.g., expiry decisions in §6 affect §10
  # budget counts; §3/§4 candidate harvesting before §7 bias audit).
  # Adding a shape: drop a new prompt body under bin/retro-prompts/, write
  # a driver + sibling test mirroring bin/retro-shape-stage-failure-summary.sh,
  # append the name here.
  SHAPES=(
    stage-failure-summary
    gotcha-recurrence
    convention-drift
    gotcha-promotion
    human-override
    expiry-verification
    confirmation-bias-audit
    recency-bias
    survivorship-bias
    knowledge-budget
    pipeline-health-score
    prompt-workflow-amendment
  )
  ```

- [ ] Add `_resolve_previous_period_artifact` helper IMMEDIATELY AFTER the SHAPES array (before `main() {`). Content anchor: AFTER the `SHAPES=( … )` array's closing `)` BEFORE the `main() {` declaration:

  ```bash
  # ENG-130 D-009: find the most-recent prior retrospective directory
  # (lexically earlier than today's date) that contains the named shape's
  # artifact. Emits absolute path, or literal "(none)" if no prior
  # artifact exists. Lexical sort is correct because dirname format is
  # frozen at retrospective-YYYY-MM-DD (ISO-8601).
  _resolve_previous_period_artifact() {
    local shape="$1" today="$2"
    local most_recent
    most_recent="$(
      find "$PROJECT_STATE_DIR" -maxdepth 1 -type d \
        -name 'retrospective-*' 2>/dev/null \
        | awk -F'/retrospective-' -v today="$today" \
            '$2 != "" && $2 < today { print $0 }' \
        | sort -r | head -1
    )"
    if [[ -n "$most_recent" && -f "$most_recent/${shape}.md" ]]; then
      printf '%s' "$most_recent/${shape}.md"
    else
      printf '%s' '(none)'
    fi
  }
  ```

- [ ] Run `bash -n bin/run-retrospective-local.sh` — confirm syntax check passes.

### Task 2: Author the eleven new shape prompt bodies

- `depends_on: []`
- `touches: bin/retro-prompts/{gotcha-recurrence,convention-drift,gotcha-promotion,human-override,expiry-verification,confirmation-bias-audit,recency-bias,survivorship-bias,knowledge-budget,pipeline-health-score,prompt-workflow-amendment}.md (all new files)`
- [ ] For each of the eleven new shape names, Read the corresponding §N from the pre-ENG-130 `AGENT_PROMPTS.md` §9 body. Source-§N mapping: `gotcha-recurrence ← §2`, `convention-drift ← §3`, `gotcha-promotion ← §4`, `human-override ← §5`, `expiry-verification ← §6`, `confirmation-bias-audit ← §7`, `recency-bias ← §8`, `survivorship-bias ← §9`, `knowledge-budget ← §10`, `pipeline-health-score ← §11`, `prompt-workflow-amendment ← §12`. (The §N numbering refers to the sub-headings inside the §9 fenced block, not file H2s.)
- [ ] For each new prompt body, Write the file with this five-section structure (mirroring `bin/retro-prompts/stage-failure-summary.md:1-70`):
  - **Preamble** (3 sentences): "You are the `<name>` retrospective shape …" + names inputs, output, period.
  - **`## Inputs`**: enumerate the five tokens (`{events_jsonl_path}`, `{period_start_iso}`, `{period_end_iso}`, `{artifact_path}`, `{previous_period_path}`). Shape-specific tokens may be added (e.g., human-override needs profile path); each new token must be resolved by the corresponding driver in Task 3.
  - **`## Insufficient-sample carve-out`** (where applicable per source-§N): "If <inputs absent or empty>, write a single-line artifact: '<no-findings stub>'. Then exit." Sources §2/§4/§5/§9/§11 all have explicit insufficient-sample stubs in the pre-ENG-130 §9 body — preserve verbatim. Other shapes (§3/§6/§7/§8/§10/§12) inherit the implicit "no findings → empty section" convention.
  - **`## Task`**: verbatim move of the source-§N instruction set, no rewording (D-003 + brainstorm OQ-4: behavioral equivalence is the goal).
  - **`## Output schema`**: declare the artifact's H2 layout (e.g., `## Gotcha recurrence` with sub-bullets); the coordinator's bash concatenation surfaces this as the PR-body section title (D-006 / OQ-3).
  - **`## Mandatory exit instructions`**: "Write your markdown summary to `{artifact_path}`. <shape-specific write-whitelist if applicable; e.g., expiry-verification adds 'You may also Edit files under `docs/knowledge/` and `{learned_rules_dir}/*.md`'>. Do NOT modify other files. Do NOT post Linear comments. Do NOT commit. Do NOT run `git` commands."
- [ ] For shapes that need extra tokens beyond the five baseline (currently only `expiry-verification` references `{learned_rules_dir}` per the source-§6 prose), document the added token at the top of the prompt body so Task 3's `_render_prompt` adds the matching `sed` substitution.
- [ ] Confirm via Read that each prompt body's tokens match the driver's substitution chain (cross-reference Task 3's per-shape driver code).

### Task 3: Implement the eleven new shape drivers

- `depends_on: [2]`
- `touches: bin/retro-shape-{gotcha-recurrence,convention-drift,gotcha-promotion,human-override,expiry-verification,confirmation-bias-audit,recency-bias,survivorship-bias,knowledge-budget,pipeline-health-score,prompt-workflow-amendment}.sh (all new files); functions main, _parse_args, _render_prompt, _validate_no_unresolved_tokens (per file)`
- [ ] For each of the eleven shape names, Write `bin/retro-shape-<name>.sh` as a near-verbatim mechanical copy of `bin/retro-shape-stage-failure-summary.sh:1-115`. The boilerplate (preamble, `set -euo pipefail`, `source common.sh`, argv globals, `_parse_args`, `_render_prompt` skeleton, `_validate_no_unresolved_tokens`, `main`, sentinel) is identical; only the per-shape substitutions in `_render_prompt` and the per-shape token list in `_validate_no_unresolved_tokens` change.
- [ ] Per-shape `_render_prompt` (mirroring `bin/retro-shape-stage-failure-summary.sh:42-53`):
  - `local template="$HARNESS_ROOT/bin/retro-prompts/<name>.md"` — substitute the shape's name verbatim.
  - `sed` chain resolves the five baseline tokens; add per-shape tokens as needed (e.g., `expiry-verification` adds `-e "s|{learned_rules_dir}|${HARNESS_ROOT}/learned-rules/${PROJECT_SLUG}|g"`).
- [ ] Per-shape `_validate_no_unresolved_tokens` (mirroring `bin/retro-shape-stage-failure-summary.sh:55-74`):
  - For-loop over the five baseline token names plus any per-shape extras (one entry added per per-shape token).
  - Residual scan grep regex extends the negative-list with per-shape extras (e.g., `expiry-verification`'s scan adds `learned_rules_dir` to the OR-list at line 69).
- [ ] Per-shape `main` body is byte-identical to `bin/retro-shape-stage-failure-summary.sh:76-110` except:
  - DRY_RUN log line at line 91 names the shape: `log "[DRY_RUN] would dispatch.sh retrospective with prompt=$rendered artifact=$_ARTIFACT_PATH (shape=<name>)"`.
  - DRY_RUN placeholder content at line 92 names the shape: `printf '%s\n' '[DRY_RUN placeholder] <name>' > "$_ARTIFACT_PATH"`.
  - log_file path at line 98 names the shape: `log_file="$PROJECT_STATE_DIR/logs/retro-shape-<name>-$(date -u +%Y%m%dT%H%M%SZ).log"`.
- [ ] `chmod 755` each new driver. End each file with the source-and-stub sentinel (mirrors `bin/retro-shape-stage-failure-summary.sh:112-114`).
- [ ] Run `bash -n bin/retro-shape-<name>.sh` for each new file — confirm syntax check passes.

### Task 4: Author the eleven sibling tests

- `depends_on: [3]`
- `touches: bin/retro-shape-{gotcha-recurrence,convention-drift,gotcha-promotion,human-override,expiry-verification,confirmation-bias-audit,recency-bias,survivorship-bias,knowledge-budget,pipeline-health-score,prompt-workflow-amendment}-test.sh (all new files)`
- [ ] For each of the eleven shape names, Write `bin/retro-shape-<name>-test.sh` mirroring the structure of `bin/retro-shape-stage-failure-summary-test.sh` but trimmed to ≥6 fixtures (the PoC's 17 fixtures over-covered argv permutations during pattern bring-up; new shapes ride the established pattern). Mandatory fixtures per shape:
  1. **Argv parsing — missing required flag** (e.g., `--artifact-path` omitted): expect rc != 0 + die-message names the missing flag.
  2. **Argv parsing — happy path in DRY_RUN**: invoke with all four required flags; expect rc == 0 + placeholder artifact exists at `$_ARTIFACT_PATH`.
  3. **Token resolution — non-DRY_RUN**: stub `dispatch.sh` to capture the rendered prompt path; assert the captured rendered prompt has NO `{[a-z_]+}` substrings remaining (covers all five baseline + any per-shape tokens).
  4. **DRY_RUN does not invoke dispatch**: with `PIPELINE_DRY_RUN=1`, assert the stubbed dispatch is NEVER called.
  5. **Artifact missing → die**: stub dispatch returns 0 but does NOT write `$_ARTIFACT_PATH`; assert shape dies with rc != 0 + message contains `artifact not written`.
  6. **Dispatch failure → die**: stub dispatch returns rc=29 (envelope-violation sentinel); assert shape dies with rc != 0 + message contains `rc=29`.
- [ ] Source-and-stub setup mirrors `bin/retro-shape-stage-failure-summary-test.sh:14-68`:
  - `SCRIPT_DIR`, `HARNESS_DIR`, `STUB_DIR=$(mktemp -d)`.
  - Stub `bin/dispatch.sh` under `$STUB_DIR/dispatch.sh` (write/touch the artifact based on argv).
  - Export `TARGET_REPO`, `HARNESS_ROOT`, `HARNESS_STATE_DIR`, `PROJECT_STATE_DIR` to temp dirs.
  - `source "$HARNESS_DIR/retro-shape-<name>.sh"` (sentinel-bypass via `$BASH_SOURCE != $0`).
  - Override `SCRIPT_DIR="$STUB_DIR"` AFTER source so `bash "$SCRIPT_DIR/dispatch.sh"` resolves to the stub.
- [ ] End the file with `_pass`/`_fail` accumulator + final `if (( FAIL == 0 )); then printf 'OK: …'; else printf 'FAIL …'; fi` (mirrors `bin/retro-shape-stage-failure-summary-test.sh:568-575`).
- [ ] `chmod 755` each new test. **Notes (operator follow-up after PR merge):** regenerate `.pipeline-config/config.json::dispatch.tools.{implementing,qa}[]` per the CLAUDE.md "Wildcard pitfall" snippet to add the twelve new test files (the eleven `bin/retro-shape-<name>-test.sh` plus `bin/run-retrospective-local-test.sh`). The PR description carries the regeneration command verbatim. This is operator-side; the file is gitignored.

### Task 5: Rewrite `bin/run-retrospective-local.sh::main()` to iterate SHAPES

- `depends_on: [1, 3]`
- `touches: bin/run-retrospective-local.sh::main`
- [ ] Open `bin/run-retrospective-local.sh`. The current `main()` body spans lines 51-154; the rewrite replaces lines 89-128 (existing single-shape block + §9 awk extract + dispatch) with the loop and the PR-body composition block.
- [ ] Remove the lines BETWEEN the existing `period_end_iso="$(printf '%s' "$period_lines"   | sed -n '2p')"` (`bin/run-retrospective-local.sh:88`) AND the existing `git -C "$TARGET_REPO" add -A` (`bin/run-retrospective-local.sh:131`). Content anchor: AFTER the `period_end_iso=...` assignment line (~line 88) BEFORE the `# If the agent produced no changes…` comment (~line 130).
- [ ] In place of the deleted block, insert (Edit boundaries: AFTER `period_end_iso=...` (~line 88) BEFORE `# If the agent produced no changes…` (~line 130)):

  ```bash
  local shape_artifact_dir="$PROJECT_STATE_DIR/retrospective-${today}"
  mkdir -p "$shape_artifact_dir"

  # ENG-130 D-005: per-shape failure semantics. Each shape is invoked
  # in turn; rc != 0 is logged and the loop continues. Surviving shapes
  # still contribute to the PR. After the loop, the coordinator opens
  # exactly one PR iff `git diff --cached` shows tracked-file changes.
  local -a succeeded_shapes=()
  local -a failed_shapes=()
  local -A shape_rcs=()  # bash 4+; harness host runs bash 5 per CLAUDE.md
  local shape artifact prev rc

  for shape in "${SHAPES[@]}"; do
    artifact="$shape_artifact_dir/${shape}.md"
    prev="$(_resolve_previous_period_artifact "$shape" "$today")"
    rc=0
    bash "$SCRIPT_DIR/retro-shape-${shape}.sh" \
      --artifact-path        "$artifact" \
      --period-start-iso     "$period_start_iso" \
      --period-end-iso       "$period_end_iso" \
      --previous-period-path "$prev" \
      || rc=$?
    if (( rc == 0 )); then
      succeeded_shapes+=("$shape")
    else
      failed_shapes+=("$shape")
      shape_rcs[$shape]="$rc"
      log "coordinator: shape '$shape' failed (rc=$rc); continuing with remaining shapes"
    fi
  done

  # ENG-130 D-006: bash-side PR body composition. Mechanical
  # concatenation under a `## Period` preamble + a `## Failed shapes`
  # footer. Shape artifacts that are zero-byte are skipped (D-006
  # `[[ -s ... ]]` guard).
  local pr_body_path="$shape_artifact_dir/pr-body.md"
  {
    printf '## Period\n'
    printf '%s → %s\n' "$period_start_iso" "$period_end_iso"
    for shape in "${succeeded_shapes[@]}"; do
      if [[ -s "$shape_artifact_dir/${shape}.md" ]]; then
        printf '\n---\n\n'
        cat "$shape_artifact_dir/${shape}.md"
      fi
    done
    if (( ${#failed_shapes[@]} > 0 )); then
      printf '\n---\n\n## Failed shapes\n\n'
      for shape in "${failed_shapes[@]}"; do
        printf '- %s (rc=%s, log=%s/logs/retro-shape-%s-*.log)\n' \
          "$shape" "${shape_rcs[$shape]}" "$PROJECT_STATE_DIR" "$shape"
      done
    fi
  } > "$pr_body_path"
  ```

- [ ] Update the no-changes branch (`bin/run-retrospective-local.sh:131-138`). Content anchor: AFTER the inserted PR-body composition `} > "$pr_body_path"` line BEFORE the existing `git -C "$TARGET_REPO" \ -c user.name=…` commit block (~line 140). The current branch has:

  ```bash
  git -C "$TARGET_REPO" add -A
  if git -C "$TARGET_REPO" diff --cached --quiet; then
    log "retrospective: no changes proposed this week"
    bash "$SCRIPT_DIR/slack.sh" info "Weekly retrospective: no changes proposed."
    git -C "$TARGET_REPO" checkout main
    git -C "$TARGET_REPO" branch -D "$branch" || true
    return 0
  fi
  ```

  Modify the `slack.sh info` call: when `failed_shapes` is non-empty, call `bash "$SCRIPT_DIR/slack.sh" error "Weekly retrospective: ${#failed_shapes[@]} of ${#SHAPES[@]} shapes failed: $(printf '%s,' "${failed_shapes[@]}" | sed 's/,$//'); no PR opened (no diff)."` instead of the existing info line. Otherwise leave the info call unchanged. Content anchor: REPLACE the single `bash "$SCRIPT_DIR/slack.sh" info "Weekly retrospective: no changes proposed."` line with an `if (( ${#failed_shapes[@]} > 0 )); then ... else bash "$SCRIPT_DIR/slack.sh" info ...; fi` conditional.

- [ ] Modify the `gh pr create` invocation (`bin/run-retrospective-local.sh:146-149`). Content anchor: REPLACE the literal `--body "Automated weekly retrospective run. …"` argument with `--body-file "$pr_body_path"`. Rest of the `gh pr create` argv (`--title`, `--label pipeline-retrospective`) unchanged.
- [ ] Add a final slack notification AFTER the existing `bash "$SCRIPT_DIR/slack.sh" info "Weekly retrospective opened a PR for review."` line (~line 151) — when `failed_shapes` is non-empty AND a PR was opened, switch the slack call to `error` level and name the failures: `bash "$SCRIPT_DIR/slack.sh" error "Weekly retrospective: PR opened with ${#succeeded_shapes[@]}/${#SHAPES[@]} shapes succeeded; ${#failed_shapes[@]} failed: $(printf '%s,' "${failed_shapes[@]}" | sed 's/,$//')."`. Content anchor: REPLACE the unconditional `slack.sh info` line with an `if (( ${#failed_shapes[@]} > 0 )); then slack error ... else slack info ...; fi` conditional.
- [ ] Wrap `gh pr create` in failure-handling per brainstorm §5: if it fails, slack `error "gh pr create failed; commit pushed to $branch but PR not opened"` + `exit 20`. Content anchor: REPLACE `gh pr create … --label "pipeline-retrospective"` (lines 146-149) with `if ! gh pr create … --body-file "$pr_body_path" … --label "pipeline-retrospective"; then bash "$SCRIPT_DIR/slack.sh" error "..."; exit 20; fi`.
- [ ] Run `bash -n bin/run-retrospective-local.sh` — syntax check.
- [ ] Smoke `PIPELINE_DRY_RUN=1 TARGET_REPO=… bash bin/run-retrospective-local.sh` from a fresh disposable target — expect 12 placeholder artifacts produced + `pr-body.md` composed + no `gh pr create` (dry-run). Document the smoke result in the PR description.

### Task 6: Write the coordinator-level test

- `depends_on: [5]`
- `touches: bin/run-retrospective-local-test.sh (new file)`
- [ ] Write `bin/run-retrospective-local-test.sh` following the source-and-stub pattern. Setup mirrors `bin/retro-shape-stage-failure-summary-test.sh:14-68`:
  - `STUB_DIR=$(mktemp -d)`; `mkdir -p "$STUB_DIR/bin"`.
  - For each shape name in `SHAPES`, write a stub `$STUB_DIR/bin/retro-shape-<name>.sh` that the test can configure per-fixture (success-with-edit, success-no-edit, failure).
  - Stub `bin/slack.sh`, `bin/dispatch.sh` (unused but referenced), `bin/linear.sh` (no-ops in dry-run).
  - Stub `gh` in PATH via `$STUB_DIR/gh` writing argv to a side-channel file.
  - Init a disposable `git init` repo as `TARGET_REPO`; commit a baseline file so `git add -A` / `git diff --cached` work.
  - `source "$HARNESS_DIR/run-retrospective-local.sh"` (sentinel-bypass).
  - Override `SCRIPT_DIR="$STUB_DIR/bin"` AFTER source so the loop's `bash "$SCRIPT_DIR/retro-shape-${shape}.sh"` resolves to the per-fixture stubs.
- [ ] Per-fixture sketch (twelve fixtures total — D-010's eleven plus `cf-12-gh-pr-create-fails-slack-error` from the Failure Mode → Test Map):
  - **`cf-1-all-shapes-succeed-pr-opened`**: every stub returns 0 + writes a tracked file in `$TARGET_REPO`. Assert: `gh pr create` called once with `--body-file <path>` AND the body file contains a `## Period` header AND every shape's name appears in the body.
  - **`cf-2-some-shapes-skip-pr-opened`**: 3 stubs return non-zero; 9 return 0 + write tracked files. Assert: `gh pr create` called once; body contains `## Failed shapes` footer naming the 3 failures; surviving shapes' sections present; `bash slack.sh error ...` was the final slack call (NOT `info`) and the error body names the 3 failed shape names.
  - **`cf-3-no-shape-produces-changes-no-pr`**: every stub returns 0 + writes ONLY the artifact (no `$TARGET_REPO` change). Assert: `gh pr create` NOT called; slack `info` "no changes proposed" sent; "no changes proposed" log line present.
  - **`cf-4-all-shapes-fail-no-pr`**: every stub returns non-zero. Assert: `gh pr create` NOT called (no diff); slack `error` listing all 12 failures sent.
  - **`cf-5-shape-array-is-the-source-of-truth`**: static check — assert `SHAPES` array contains exactly the 12 names enumerated in this plan AND each name resolves to an existing `bin/retro-shape-<name>.sh` (test reads the live `bin/` directory, not a stub).
  - **`cf-6-period-passed-to-every-shape`**: each stub records its argv to a side-channel file; assert each stub's argv carries the SAME `--period-start-iso` / `--period-end-iso` values.
  - **`cf-7-previous-period-helper-fallback`**: empty `$PROJECT_STATE_DIR`; call `_resolve_previous_period_artifact stage-failure-summary 2026-05-16`; assert returns literal `(none)`.
  - **`cf-8-previous-period-helper-finds-prior`**: fabricate `$PROJECT_STATE_DIR/retrospective-2026-05-09/<shape>.md`; assert helper returns absolute path.
  - **`cf-9-dry-run-no-git-commit-no-gh-pr`**: `PIPELINE_DRY_RUN=1`; assert no `git commit` / `git push` / `gh pr create` invocations recorded (stubs verify by argv-capture).
  - **`cf-10-pr-body-omits-empty-artifacts`**: one stub writes a zero-byte artifact; assert PR body does NOT include a section for that shape (D-006 `[[ -s ... ]]` guard).
  - **`cf-11-aggregator-orders-by-shapes-array`**: every stub writes a marker line (e.g., `MARKER-<name>`); assert PR body's marker order matches `SHAPES` array order, NOT filesystem order.
- [ ] End the file with the `_pass`/`_fail` accumulator + final `OK / FAIL` summary line (mirrors `bin/retro-shape-stage-failure-summary-test.sh:568-575`).
- [ ] `chmod 755 bin/run-retrospective-local-test.sh`.
- [ ] Run `bash bin/run-retrospective-local-test.sh` — confirm exits 0.

### Task 7: Delete AGENT_PROMPTS.md §9

- `depends_on: [5]`
- `touches: AGENT_PROMPTS.md (delete §9 H2 + fenced block)`
- **Ordering invariant** (P0 protection): Task 7 MUST run AFTER Task 5 in the same feature branch. Task 5's coordinator rewrite removes the awk extraction at `bin/run-retrospective-local.sh:103-128` that reads §9 from `AGENT_PROMPTS.md`. Deleting §9 BEFORE Task 5 lands would leave the still-existing awk block targeting a non-existent section — the binary would extract zero lines and dispatch an empty prompt. Both edits land in the same PR; the implementation agent runs tasks in `depends_on` order, so this ordering is enforced by the dependency declaration. If a reviewer ever splits this PR, Task 5 + Task 7 must stay coupled in one commit (or Task 5 lands first and Task 7 lands as a follow-up).
- [ ] Delete `AGENT_PROMPTS.md:1734` (the blank line BEFORE the §9 H2 — Edit boundary anchor: AFTER §8's closing fence at `AGENT_PROMPTS.md:1733` (literal text: `\`\`\`` immediately following the `- No edits to any source files. You are a read-only observer plus Linear/Slack writer.` line) BEFORE EOF) THROUGH `AGENT_PROMPTS.md:1948` (the §9 closing fence — Edit boundary anchor: the file's last line, the closing `\`\`\`` of the §9 fenced block) inclusive.
- [ ] Verify post-delete: `wc -l AGENT_PROMPTS.md` reports 1733; the file's last line is §8's closing fence; `grep -n '^## 9\.' AGENT_PROMPTS.md` returns no matches.
- [ ] Run `bash bin/render-prompt-test.sh` — case 87-R5 token-coverage test scans AGENT_PROMPTS.md; the `{stage_failure_summary_path}` token is no longer present, so the AGENT_RUNTIME_TOKENS allowlist entry becomes orphaned but harmless until Task 9 cleans it.

### Task 8: Drop §9 entries from `bin/agent-prompts-content-test.sh` per-stage for-loops

- `depends_on: [7]`
- `touches: bin/agent-prompts-content-test.sh (six per-stage for-loops at lines 450, 496, 531, 575, 1028, 1232)`
- [ ] For each of the six per-stage for-loops (at `bin/agent-prompts-content-test.sh:441-477`, `:487-509`, `:522-554`, `:566-591`, `:1019-1038`, `:1225-1241`), Edit to remove the trailing `\` continuation on the prior line + the `"## 9. Retrospective Agent (Scheduled)"` token. Content anchor for each: the loop's terminal section name `"## 9. Retrospective Agent (Scheduled)"; do` — REPLACE with `"## 8. Release Agent"; do` (drop the §9 line; the §8 line gains the `; do` terminator, dropping its trailing `\`).
- [ ] Verify post-edit: `grep -nE '## 9\. Retrospective Agent' bin/agent-prompts-content-test.sh` returns no matches in for-loop blocks (one comment reference at line 233 + one at line 602 may remain — both are descriptive prose, not iteration targets; leave untouched).
- [ ] Run `bash bin/agent-prompts-content-test.sh` — confirm exits 0.

### Task 9: Remove dead `retrospective` references from `bin/render-prompt.sh`

- `depends_on: [7]`
- `touches: bin/render-prompt.sh (STAGE_TO_SECTION line 22; AGENT_RUNTIME_TOKENS line 75)`
- [ ] Edit `bin/render-prompt.sh:22` — DELETE the line `retrospective=9. Retrospective Agent (Scheduled)`. Content anchor: BETWEEN `released=8. Release Agent` (line 21) AND the closing `'` on line 23. After the edit, `STAGE_TO_SECTION` ends with `released=8. Release Agent` then the closing `'`.
- [ ] Edit `bin/render-prompt.sh:75` — REPLACE `AGENT_RUNTIME_TOKENS=' file pr_number stage_failure_summary_path '` with `AGENT_RUNTIME_TOKENS=' file pr_number '`. Content anchor: the literal `stage_failure_summary_path` token between `pr_number ` and ` '`.
- [ ] Run `bash bin/render-prompt-test.sh` — confirm all cases pass (case 6.3 retrospective-stage carve-out at `append_project_profile` is unaffected by either edit; case 87-R5 token-coverage continues to pass because `{stage_failure_summary_path}` no longer appears in AGENT_PROMPTS.md after Task 7).
- [ ] Run `bash bin/render-prompt-rc0-test.sh` — confirm exits 0 (test mentions `retrospective` only in a prose comment at line 111).

### Task 10: Update CLAUDE.md "Retrospective shapes (ENG-129)" section

- `depends_on: [5, 7]`
- `touches: CLAUDE.md (Retrospective shapes section)`
- [ ] Locate the "## Retrospective shapes (ENG-129)" header in `CLAUDE.md` (header text anchor; line number ~78 may have shifted). Content anchor: BETWEEN the H2 `## Retrospective shapes (ENG-129)` (start) AND the next H2 `## Common commands` (end — verified at `CLAUDE.md` ~line 97 at plan time; if drifted, anchor by header text not line number). Replace the entire body BETWEEN those two headers (exclusive of both header lines).
- [ ] Replace the section body. New body:

  ```markdown
  The weekly retrospective binary (`bin/run-retrospective-local.sh`) is
  a deterministic bash coordinator that iterates a hard-coded `SHAPES`
  array of twelve "shapes" — independently-invocable sub-behaviors,
  each with its own prompt body under `bin/retro-prompts/<name>.md`,
  its own driver at `bin/retro-shape-<name>.sh`, and its own sibling
  test at `bin/retro-shape-<name>-test.sh`. Shapes write a markdown
  artifact under `$PROJECT_STATE_DIR/retrospective-${date}/<name>.md`;
  the coordinator concatenates succeeded shapes' artifacts under a
  `## Period` preamble + `## Failed shapes` footer to compose the PR
  body (no claude dispatch at the coordinator level — AC #1).

  Per-shape failures are non-blocking: rc != 0 is logged and the loop
  continues; surviving shapes still contribute to the PR. After all
  shapes run, the coordinator opens exactly one PR iff `git diff --cached`
  shows tracked-file changes. To add a shape: drop a new prompt body
  under `bin/retro-prompts/`, write a driver + sibling test mirroring
  `bin/retro-shape-stage-failure-summary.sh`, append the name to
  `SHAPES` in `bin/run-retrospective-local.sh`. Shapes reuse
  `dispatch.sh retrospective`'s allowed-tools (no new arm in
  `allowed_tools_for`).
  ```

- [ ] Verify by Read that the rewrite preserves CLAUDE.md's Markdown structure (no orphan list items; H2 boundaries clean).

### Task 11: (Optional — observed at smoke time) Document pre-commit hook runtime regression

- `depends_on: [4, 6]`
- `touches: CLAUDE.md (Pre-commit hook section, only if observed runtime > 60s)`
- [ ] Time the pre-commit hook before and after the new test files: `time bash .githooks/pre-commit` (run twice; record the second run to exclude cache effects).
- [ ] If runtime > 60s, Edit the CLAUDE.md "Pre-commit hook" section to update the documented baseline (currently `~30 s`). Content anchor: literal text `~30 s` in the section.
- [ ] If runtime ≤ 60s, skip this task (no doc change needed).

## 6. Frontend Tasks

No frontend work — the harness has no UI. Skip.

## 7. Failure Mode → Test Map

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
|---|---|---|---|---|
| Single shape exits non-zero (rc != 0) | Shape's internal `die` (e.g., artifact-missing) | Coordinator records failure; loop continues; PR body footer lists the shape | unit | `bin/run-retrospective-local-test.sh::cf-2-some-shapes-skip-pr-opened` |
| All shapes exit non-zero | All twelve stubs return non-zero | No tracked-file changes; no PR opened; slack `error` lists all 12 | unit | `bin/run-retrospective-local-test.sh::cf-4-all-shapes-fail-no-pr` |
| Shape returns 0 but did not write its artifact | Shape's `[[ -f "$_ARTIFACT_PATH" ]]` check fails | Shape dies with rc != 0; coordinator catches per the rc != 0 path | unit | `bin/retro-shape-<name>-test.sh::artifact-missing-die` (per shape) |
| Shape's prompt rendering leaves an unresolved `{token}` | `_validate_no_unresolved_tokens` greps a `{tok}` substring | Shape dies; coordinator catches per the rc != 0 path | unit | `bin/retro-shape-<name>-test.sh::token-resolution` (per shape) |
| Shape writes its artifact AND a checked-in edit, then crashes (rc != 0) | Stub writes artifact + tracked file, then `exit 1` | Coordinator records as failed; partial edit accumulates in `git status`; PR opens with the partial content (operator review surfaces it) | unit | `bin/run-retrospective-local-test.sh::cf-2-some-shapes-skip-pr-opened` (sub-assertion: succeeded shapes' edits land even if some shapes failed) |
| Period computation returns identical start and end ISO (degenerate empty period) | `_compute_retro_period` emits same value for start and end | Each shape's `## Insufficient-sample carve-out` emits stub; PR body composed from stubs; no tracked-file changes; no PR | integration | `bin/run-retrospective-local-test.sh::cf-3-no-shape-produces-changes-no-pr` (degenerate-period variant) |
| `gh pr create` fails (network / auth) | Stub `gh pr create` returns non-zero | Coordinator slacks `error` "gh pr create failed; commit pushed but PR not opened"; exits 20 | unit | `bin/run-retrospective-local-test.sh::cf-12-gh-pr-create-fails-slack-error` (additional fixture beyond D-010's 11) |
| `$PROJECT_STATE_DIR` directory write permission denied | `mkdir -p "$shape_artifact_dir"` returns non-zero | `set -euo pipefail` propagates; coordinator exits non-zero; launchd's next-fire is next Monday | smoke | covered by `set -e` propagation; no dedicated test (operator-environment failure) |
| A shape's claude dispatch SIGTERMs at the 30-min gtimeout boundary | Stub dispatch returns rc=124 | Coordinator catches; shape marked failed; successor shapes continue | unit | `bin/run-retrospective-local-test.sh::cf-2-some-shapes-skip-pr-opened` (rc=124 variant) |
| Concurrent retrospective + pipeline tick | K=2 claude-semaphore caps; sequential shape loop consumes one slot | Worst case ~6h wall-clock for 12 shapes × 30 min cap; acceptable for weekly job | integration | not in this plan (production-observed); OQ-2 follow-up if painful |
| Coordinator crashes mid-loop (e.g., disk full, OOM) | `set -euo pipefail` propagates failure | Working branch may have partial commits; same-day re-run reuses branch (line 71-74); no state leak | smoke | covered by `set -e` propagation + branch reset path |
| `_resolve_previous_period_artifact` returns the wrong directory because of timestamp drift | non-ISO date format injected into `$PROJECT_STATE_DIR` | Lexical sort breaks; helper may return wrong path | unit | `bin/run-retrospective-local-test.sh::cf-7-previous-period-helper-fallback` AND `cf-8-previous-period-helper-finds-prior` (positive + negative) |
| Two shapes try to edit the same file (e.g., §6 expiry + §10 budget both touch `docs/knowledge/gotchas.md`) | Both stubs edit same line | Second shape's Edit may fail; second shape returns non-zero; coordinator marks failed; first shape's edit stands | smoke | not unit-tested (operator-review surfaces in PR diff) |
| First-ever ENG-130 retrospective run (no prior dated dirs) | Empty `$PROJECT_STATE_DIR` | `_resolve_previous_period_artifact` returns `(none)` for every shape | unit | `bin/run-retrospective-local-test.sh::cf-7-previous-period-helper-fallback` |
| No shape produces any tracked-file changes | All twelve stubs write only artifacts | No diff; no PR; slack `info`; exit 0 | unit | `bin/run-retrospective-local-test.sh::cf-3-no-shape-produces-changes-no-pr` |
| Shape array contains a name that doesn't exist on disk | `bin/retro-shape-typo.sh` missing | `bash bin/retro-shape-typo.sh …` fails with "No such file or directory"; rc != 0; coordinator marks failed; continues | unit | covered structurally by `cf-2-some-shapes-skip-pr-opened`; `cf-5-shape-array-is-the-source-of-truth` static-checks `SHAPES` against disk to prevent regression |
| Shape array DOESN'T contain a name whose driver exists on disk | New shape driver added without registry update | Disk shape never runs | unit | `bin/run-retrospective-local-test.sh::cf-5-shape-array-is-the-source-of-truth` |
| `AGENT_PROMPTS.md` §9 is gone but operator's local prompt still references `{stage_failure_summary_path}` | Token grep finds zero non-test references | Token-coverage test (`bin/render-prompt-test.sh::case 87-R5`) continues to pass | unit | `bin/render-prompt-test.sh::case 87-R5` |
| A shape's prompt body grows new tokens (e.g., `{target_branch}`) but the driver wasn't updated | `_validate_no_unresolved_tokens` greps the new token | Shape dies; coordinator catches | unit | `bin/retro-shape-<name>-test.sh::token-resolution` (per shape) |
| PR body section order doesn't match `SHAPES` array order | Coordinator iterates `succeeded_shapes` (preserves insertion order) | Section order matches `SHAPES` order, NOT filesystem order | unit | `bin/run-retrospective-local-test.sh::cf-11-aggregator-orders-by-shapes-array` |
| Zero-byte artifact pollutes PR body | Shape writes empty file | D-006 `[[ -s ... ]]` guard skips zero-byte artifacts | unit | `bin/run-retrospective-local-test.sh::cf-10-pr-body-omits-empty-artifacts` |

## 8. Test Strategy

### Unit (per-shape)

- Each new `bin/retro-shape-<name>-test.sh` covers six fixtures (argv-missing, dry-run-happy, token-resolution, dispatch-stub-not-invoked-in-dry-run, artifact-missing-die, dispatch-rc-non-zero-die). Source-and-stub pattern; no live `claude -p`; no live `dispatch.sh`. Per-shape assertions cover the per-shape token list (any extras beyond the five baseline tokens get a dedicated token-resolution sub-fixture).
- Eleven new test files; each ~250-350 lines; runs in ≤2s each.

### Unit (coordinator)

- `bin/run-retrospective-local-test.sh` covers eleven fixtures from D-010 plus one extra (`cf-12-gh-pr-create-fails-slack-error`). Per-fixture stubs configure each shape's behavior (success-with-edit, success-no-edit, failure-rc) and assert PR-body composition + slack notification + `gh pr create` invocation count. Source-and-stub pattern; no live `git`/`gh`/`claude` (disposable git repo for `git add -A` / `git diff --cached`).
- One coordinator test file; ~500-700 lines; runs in ≤5s.

### Integration (existing tests)

- `bin/agent-prompts-content-test.sh` continues to pass after Task 8 drops the §9 entries from per-stage for-loops. The §0 cross-stage rule assertions (Tool allowlist & probing, ENG-56 `pipeline:halted` ban, ENG-57 same-sig retry, ENG-74 env-var-prefix, ENG-100 sub-agent debris) iterate over §§1-8 only; §0's content is unchanged.
- `bin/render-prompt-test.sh` continues to pass after Task 9 cleans the dead STAGE_TO_SECTION + AGENT_RUNTIME_TOKENS entries. Case 87-R5 token-coverage scans live AGENT_PROMPTS.md; `{stage_failure_summary_path}` is no longer present after Task 7, so the orphaned AGENT_RUNTIME_TOKENS entry's removal is harmless.
- `bin/render-prompt-rc0-test.sh` continues to pass; it mentions `retrospective` only in a prose comment.

### Smoke

- `PIPELINE_DRY_RUN=1 TARGET_REPO=… bash bin/run-retrospective-local.sh` against a disposable target — expect 12 placeholder artifacts produced under `$PROJECT_STATE_DIR/retrospective-${today}/`, `pr-body.md` composed, no `gh pr create` invoked. Documented in PR description by Task 5.
- `bash -n bin/run-retrospective-local.sh` and `bash -n bin/retro-shape-<name>.sh` (12 files) — syntax check.
- `time bash .githooks/pre-commit` (twice) — verify runtime regression vs the documented ~30s baseline; if >60s, Task 11 documents new baseline.

### Adversarial / edge

- `cf-5-shape-array-is-the-source-of-truth` is the regression backstop: enforces `SHAPES` array matches every `bin/retro-shape-<name>.sh` on disk (per ENG-94's profile-test precedent of asserting registry matches disk). A future shape added without registry update fails this test; a registry entry without a driver fails the runtime via "No such file or directory" + caught by `cf-2`.
- `cf-11-aggregator-orders-by-shapes-array` pins PR-body section order to the array order (not filesystem order). A coordinator refactor that switches to `for shape in $shape_artifact_dir/*.md` (filesystem-order iteration) would fail this fixture.
- Test-gate closure sweep: the test files affected by token / section removals are all enumerated in File Structure (`bin/agent-prompts-content-test.sh` Task 8; `bin/render-prompt-test.sh` covered by Task 9 — the case-87-R5 token-coverage works in directionality so removing `stage_failure_summary_path` from AGENT_RUNTIME_TOKENS does not require a test edit, only a comment that the orphaned entry's removal is intentional). No other sibling test pins the deleted tokens / sections.

## 9. Persona review (self-review)

Iteration 1, all five personas dispatched in parallel via the document-review pattern.

### feasibility — PASS (after iter-1 fixes)

Iter-1 raised three P0s and three P1s. Two P0s were resolved by clarifying anchors and ordering invariants in iter-2:

- **P0 (resolved):** Task 7's depends_on chain — clarified with an explicit "Ordering invariant" note in Task 7 that Task 5 + Task 7 land atomically in the same PR (see Task 7's first bullet).
- **P0 (false positive — already addressed in original draft):** Task 8 content anchors — the task spec already names the file via `touches:` AND each content anchor uses the literal terminator `"## 9. Retrospective Agent (Scheduled)"; do` for unambiguous matching. No change needed.
- **P0 (cosmetic — Assumption Inventory phrasing):** Narrative split between "deletes lines 89-101" + "deletes lines 103-128" — both refer to the same contiguous range deleted by Task 5. Tightened by Task 5's content anchor naming the contiguous range AFTER `period_end_iso=...` (~line 88) BEFORE `# If the agent produced no changes…` (~line 130).
- **P1 (resolved):** Task 6 fixture count — was "eleven fixtures from D-010" but Failure Mode → Test Map referenced cf-12. Task 6 spec now reads "twelve fixtures total — D-010's eleven plus `cf-12-gh-pr-create-fails-slack-error` from the Failure Mode → Test Map".
- **P1 (resolved):** Task 10 CLAUDE.md anchor — now names the next H2 explicitly (`## Common commands` at ~line 97, header-text anchored).

All `path:line` references in Assumption Inventory verified against current tree. Branch-base freshness re-verified at iter-2 close: `git log --oneline HEAD..origin/main` empty.

### scope — PASS

Zero findings. All 11 backend tasks trace to Linear AC #1-#3 or brainstorm decisions D-001 through D-012. All 24 net-new files + 4 modified files justified. Eight files in "NOT modified" list defensively recorded. Zero references to deferred items (calibration ENG-39, audit ENG-40, per-shape model tiering, parallel execution, structured PR body, auto-discovery, per-target disabling).

### coherence — PASS (one P1 resolved)

- **P1 (resolved):** Failure Mode → Test Map row 1 (`single shape exits non-zero`) needed the `cf-2` fixture spec to explicitly assert slack `error` (not `info`). Task 6's `cf-2` spec strengthened to: "`bash slack.sh error ...` was the final slack call (NOT `info`) and the error body names the 3 failed shape names."
- All other coherence axes pass: Goal matches brainstorm Problem statement; SHAPES order matches D-002; Task 9's token cleanup is consistent with Task 7's §9 deletion; depends_on graph is acyclic and causally ordered.

### design — PASS (one P1 noted; resolved by Task 10)

- **P1 (covered by Task 10):** CLAUDE.md "Retrospective shapes (ENG-129)" still contains pre-coordinator advisory paragraphs — **Task 10 is the dedicated rewrite that replaces the section body verbatim**. Grep verified zero other references to "ENG-129 D-006" or "halt on shape failure" anywhere in the tree (`grep -rn 'ENG-129 D-006\|halt on shape failure' .` → only in this plan's persona-review explanation).

Architectural axes pass: bash coordinator + 12 shape drivers respect HARNESS_ROOT / TARGET_REPO / HARNESS_STATE_DIR boundaries; no circular dependencies; `_resolve_previous_period_artifact` correctly placed in `bin/run-retrospective-local.sh` (retrospective-internal); D-005 supersedes ENG-129 D-006 cleanly.

### product — PASS

Zero blocking findings. Plan delivers exactly what Linear ticket asks for in operator language. Operator debugging story IMPROVES (per-shape logs, PR footer attribution, slack-named failures). Rollout / rollback safe (`git revert` of merge commit restores §9 + monolith atomically).

### Iteration 2 verdict

**5/5 PASS · gate P0: 0 · proceeding to implementing.**

