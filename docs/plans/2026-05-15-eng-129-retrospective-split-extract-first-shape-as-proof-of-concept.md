---
linear: ENG-129
date: 2026-05-15
topic: Extract §1 stage-failure summary from the monolithic retrospective into the first independently-invocable "shape" (prompt + script + test + artifact)
---

# Plan — ENG-129 retrospective split (PoC: extract first shape)

## Anti-anchoring check

**Problem restatement (user view):** "The weekly retrospective is one big agent doing twelve things; one broken behavior blocks the whole PR, and we want to start splitting it up — prove the pattern on the smallest behavior before refactoring the rest."

**Does the brainstorm address this?** Yes. D-001 picks the smallest viable behavior (§1 stage-failure analysis — pure read of `events.jsonl`, no codebase grep, no rule-file mutation). D-002/D-003 introduce the shape directory + sibling-script convention. D-006 commits to actual delegation (the §1 paragraph in §9 moves into the shape) rather than a parallel-run experiment. D-010 explicitly fences §2-§12 out.

**Solution proportionality:** Three new files (`bin/retro-prompts/stage-failure-summary.md`, `bin/retro-shape-stage-failure-summary.sh`, `bin/retro-shape-stage-failure-summary-test.sh`) + ≤2 small edits each to `bin/run-retrospective-local.sh`, `AGENT_PROMPTS.md` §9, `CLAUDE.md`. No new dispatch case, no new vocabulary, no new metric. Matches the rubric (1 subsystem: retrospective; 1 design decision: shape-extraction pattern). **No reframing or disproportionality found — proceed without escalation.**

## Branch-base freshness check

`git log --oneline HEAD..origin/main` was EMPTY at plan time.
branch-base freshness: HEAD..origin/main empty at plan time (origin/main = 55268f2f7d5a0908e263ab4a4883cc8cd49b84db).
No Task 0 rebase needed; line-number hints are reasonably stable, but every Edit-boundary step below still names a content anchor in addition.

## 1. Goal

Extract the §1 *stage-failure analysis* behavior from `AGENT_PROMPTS.md` §9 into a standalone "shape" (prompt body at `bin/retro-prompts/stage-failure-summary.md`, executable at `bin/retro-shape-stage-failure-summary.sh`, sibling test at `bin/retro-shape-stage-failure-summary-test.sh`), have `bin/run-retrospective-local.sh::main` invoke the shape before the parent §9 dispatch, and have the §9 prompt Read the shape's artifact at `{stage_failure_summary_path}` instead of recomputing §1 — proving the shape-extraction pattern works end-to-end on one behavior while §2-§12 remain inline.

Verifiable outcome:
- `bash bin/retro-shape-stage-failure-summary-test.sh` exits 0 (covers shape invocation, artifact production, dry-run support per AC #3).
- `PIPELINE_DRY_RUN=1 TARGET_REPO=… bash bin/run-retrospective-local.sh` produces a placeholder artifact at `$PROJECT_STATE_DIR/retrospective-${today}/stage-failure-summary.md` AND emits the existing dry-run trace for the §9 dispatch (covers AC #1 — the new shape-script architecture runs end-to-end).
- `bash bin/agent-prompts-content-test.sh` continues to pass (covers AC #2 — §9 fence count + §0 cross-stage rules unchanged; the §1 paragraph rewording is invisible to existing test assertions per the test-gate closure sweep in §7).

## 2. Assumption Inventory

Format: `[verified|assumed]` ITEM — `path:line` reference (or "assumed/new" with target path).

### Verified — quoted from the current tree

- `[verified]` `bin/run-retrospective-local.sh:32-34` — `main()` opens; `today="$(date -u +%Y-%m-%d)"` is the date stamp the shape's artifact subdir reuses.
- `[verified]` `bin/run-retrospective-local.sh:41-45` — fresh-checkout guard `die`s on a dirty `$TARGET_REPO`. The shape runs AFTER this guard; no interaction.
- `[verified]` `bin/run-retrospective-local.sh:47-58` — fetch `origin main` then `checkout -b $branch` (or reuse). The shape MUST run AFTER line 58 so it sees the working branch but BEFORE the §9 prompt extraction at line 60.
- `[verified]` `bin/run-retrospective-local.sh:60-66` — awk extraction of §9 fenced block into `$prompt_file`. The plan inserts a `sed` substitution AFTER this awk (interpolating `{stage_failure_summary_path}` into `$prompt_file`).
- `[verified]` `bin/run-retrospective-local.sh:72-76` — `bash "$SCRIPT_DIR/dispatch.sh" retrospective "$prompt_file" "$log_file"` is the existing dispatch call; on rc!=0, `slack.sh error` + `exit 20`. The shape's pre-dispatch invocation reuses this same exit code on failure.
- `[verified]` `AGENT_PROMPTS.md:1722` — `## 9. Retrospective Agent (Scheduled)`. Section start.
- `[verified]` `AGENT_PROMPTS.md:1724,1929` — `## 9` block has exactly TWO column-0 fences (file is 1929 lines; `## 9` opens at 1722 with a fence on 1724, body ends at file EOF inside a closing fence — `extract_block`'s schema check at `bin/render-prompt.sh:91-113` will continue to find fence_count == 2 after the in-place §1 paragraph swap).
- `[verified]` `AGENT_PROMPTS.md:1766-1773` — §9 §1 "Stage failure analysis" bullet block. The plan replaces these 8 lines in place with a 4-line "Read the artifact" paragraph (same fence count, same outer paragraph structure).
- `[verified]` `AGENT_PROMPTS.md:1756-1761` — §9 "Period of analysis" paragraph naming `git log --merges --format='%H %s' | grep 'weekly retrospective' | head -1` as the source-of-truth shape and the `last 30 days or inception` fallback. The shape's `_compute_retro_period` helper computes the same period in bash and passes the result to BOTH the shape's claude AND (via the existing path) the parent retrospective.
- `[verified]` `bin/dispatch.sh:375-422` — `allowed_tools_for` per-stage case statement. The `retrospective` arm at line 403 already includes `Read,Write,Edit,Grep,Glob,TaskCreate,Agent,Bash(jq:*),Bash(awk:*)`, etc. — strict superset of what the shape needs.
- `[verified]` `bin/dispatch.sh:424-526` — `main()` argv parsing, `acquire_claude_mutex` (line 451), per-stage timeout resolution (lines 468-489 — retrospective defaults to 30 min), DRY_RUN branch at lines 511-526. The shape's call to `dispatch.sh retrospective` inherits all of these.
- `[verified]` `bin/dispatch.sh:439` — `[[ -n "${PIPELINE_ISSUE_ID:-}" ]]` gates `usage-<stage>.json` write. Retrospective dispatches leave `PIPELINE_ISSUE_ID` unset; the shape inherits this — no `usage-shape-*.json` written, no ENG-26 impact.
- `[verified]` `bin/dispatch.sh:563-566` — `local cmd=(env PIPELINE_WRITER=agent "PIPELINE_DISPATCH_ID=${PIPELINE_DISPATCH_ID-}" "PIPELINE_STAGE=$stage" …)`. Single-dash empty-fallback per ENG-46; retrospective leaves `PIPELINE_DISPATCH_ID` unset so no Linear marker injection — symmetric for the shape.
- `[verified]` `bin/metrics.sh:43` — `local jsonl_file="$PROJECT_STATE_DIR/metrics/events.jsonl"`. Canonical path the shape's `{events_jsonl_path}` token resolves to.
- `[verified]` `bin/metrics.sh:67` — JSONL row shape `{ts:$ts, event:$event, issue_id:$issue_id, stage:$stage, outcome:$outcome, duration_ms:$duration_ms, notes:$notes}` (plus optional cost fields per the conditional `+ (if … then …)` block on lines 68-73). The shape's prompt body relies on `outcome` + `stage` per-row.
- `[verified]` `bin/setup-prompts/discovery.md:1-30` — plain-markdown prompt body precedent; tokens `{target_repo_path}`, `{slug}`, `{date}`, `{learned_rules_dir}` are interpolated by `_render_discovery_prompt`. The shape's `bin/retro-prompts/stage-failure-summary.md` mirrors this layout.
- `[verified]` `bin/setup.sh:302-308` — `_render_discovery_prompt "$prompt_template" "$TARGET_REPO" "$slug" "$date" "$profile_dir" > "$rendered_prompt"` after `mktemp -t discovery-prompt-XXXXXX.md`. The shape script mirrors this `mktemp + sed-substitute > file` shape.
- `[verified]` `bin/setup-helpers.sh:341-350` — `_render_discovery_prompt()` body: `sed -e "s|{token}|val|g"` chain with `|` delimiter (safe against paths containing `/`). The shape's `_render_prompt` adopts the same delimiter + sed-chain pattern.
- `[verified]` `bin/common.sh:9-12` — `HARNESS_ROOT` resolution + `: "${TARGET_REPO:?…}"` death-on-missing. The shape's `set -euo pipefail` + `source common.sh` preamble inherits the guard.
- `[verified]` `bin/common.sh:30-37` — `log` / `die` helpers; shape uses both per the CLAUDE.md "When wiring a new script" rule.
- `[verified]` `bin/common.sh:56-62` — `PROJECT_STATE_DIR="${PROJECT_STATE_DIR:-${HARNESS_STATE_DIR}/${PROJECT_SLUG}}"`. The shape's artifact path uses this var verbatim.
- `[verified]` `bin/render-prompt.sh:13-22` — `STAGE_TO_SECTION` table. **NOT modified** by this plan (per D-007 — shape rendering bypasses render-prompt.sh).
- `[verified]` `bin/render-prompt.sh:91-113` — `extract_block`'s fence-count == 2 invariant. The §9 in-place edit preserves the count.
- `[verified]` `bin/render-prompt.sh:226` — `_resolve_learned_rules_dir() { printf '%s' "$_RENDER_LEARNED_RULES_DIR"; }`. Cited only as the path-token-injection precedent (the shape's `{stage_failure_summary_path}` follows the same idea but lives in `run-retrospective-local.sh`'s sed chain, NOT in render-prompt.sh — D-007).
- `[verified]` `bin/agent-prompts-content-test.sh:441-477,487-509,522-549,1019-1038,1196-1241` — every per-stage loop iterates `## 1` through `## 9. Retrospective Agent (Scheduled)` checking phrases that live in §0 (Common rules) via `rendered_stage_body`. **None of the tested phrases match the §1 paragraph being replaced** — assertions are for "Tool allowlist & probing", "verdict halt --reason agent-blocked", "Sub-agent debris (ENG-100)", "do not probe", "retry with the same sig", "Do NOT prepend env-var assignments … PIPELINE_WRITER=agent … bash bin/", "Dispatch identifier and freshness contract", "MANDATORY — overwrite on every dispatch" — all §0-content sourced. The §9 §1 paragraph rewording leaves these tests passing as-is. (See test-gate closure sweep in §7.)
- `[verified]` `docs/architecture.md:7-25` — "Two binaries, peer roles" table — orchestrator vs retrospective. The retrospective binary's external contract (Mondays 09:00 → PR with learned-rules edits) is unchanged; its INTERNAL structure splits to one shape + the existing monolith for §2-§12.
- `[verified]` Repo lacks `docs/VISION.md`, `docs/knowledge/` (verified by `ls docs/` showing `architecture.md, assumptions.md, brainstorms, configuration.md, cost.md, demos, install.md, operations.md, pipeline-vocabulary.md, pipeline-vocabulary.template.md, plans, runbooks, security.md`). The brainstorm prompt's "skip if not present" clause applies.
- `[verified]` `learned-rules/harness/` contains only `build.md` + `project-profile.md` — no `plan.md` learned rules to follow today.

### Assumed / new — created by this plan

- `[assumed/new]` `bin/retro-prompts/` directory does NOT yet exist (confirmed by `ls bin/setup-prompts/` showing only `discovery.md`, no sibling `bin/retro-prompts/`). Created by Task 1.
- `[assumed/new]` `bin/retro-prompts/stage-failure-summary.md` — new file, created by Task 1. Content is a verbatim move (D-001 + OQ-4) of the §9 §1 instruction set, wrapped with token references and an explicit "Write to {artifact_path} and exit" footer.
- `[assumed/new]` `bin/retro-shape-stage-failure-summary.sh` — new file, created by Task 2. Sources `common.sh`, parses `--artifact-path/--period-start-iso/--period-end-iso/--previous-period-path` argv, renders the prompt via `_render_prompt`, validates unresolved tokens, dispatches `bash $SCRIPT_DIR/dispatch.sh retrospective`, validates artifact written, supports `PIPELINE_DRY_RUN=1` placeholder write, ends with the source-and-stub sentinel.
- `[assumed/new]` `bin/retro-shape-stage-failure-summary-test.sh` — new file, created by Task 3. Source-and-stub pattern per `bin/run-stage-test.sh` precedent: stubs `bin/dispatch.sh` under `$STUB_DIR`, fixtures for token-resolution, dry-run, artifact-production, missing-artifact-die, and `--previous-period-path` optional handling.
- `[assumed]` Adding the new test sibling to `bin/*-test.sh` triggers the pre-commit hook (per `.githooks/pre-commit`'s enumeration) and may require operator-side regeneration of `.pipeline-config/config.json::dispatch.tools.{implementing,qa}[]` per CLAUDE.md "Per-target dispatch.tools extras and profile-derived tools" — the regeneration snippet is documented in CLAUDE.md and is OPERATOR-OWNED (not a code change in this PR). Task 6's Notes section flags this for the operator.
- `[assumed]` `bin/agent-prompts-content-test.sh` test-gate closure: no tested phrase intersects the §1 paragraph rewording — verified by feasibility sweep in §7. Re-running the test post-edit is the gate.
- `[assumed]` The shape's claude invocation in non-dry-run mode will Write the artifact at the path the prompt instructs. Worst case: the agent writes nowhere, the shape's `[[ -f "$artifact_path" ]]` post-check fails, shape `die`s with rc != 0, parent halts at line 72's existing branch — bounded failure (Edge case 4 in §6 of brainstorm).
- `[assumed]` `bin/run-retrospective-local.sh` running on the harness-self target keeps the launchd plist's `EnvironmentVariables` intact (TARGET_REPO, etc.); the shape script inherits the same env via the parent's existing `set -a; source $ENV_FILE; set +a` block.

## 3. File Structure

New files:
- `bin/retro-prompts/stage-failure-summary.md` — plain markdown prompt body for the first shape. Contains the verbatim §1 instruction set (D-001 + OQ-4: verbatim move, no rewording in PoC), the five tokens (`{events_jsonl_path}`, `{period_start_iso}`, `{period_end_iso}`, `{artifact_path}`, `{previous_period_path}`), the closed outcome set, and the "Write to {artifact_path} and exit. Do NOT modify other files. Do NOT post Linear comments. Do NOT commit." footer.
- `bin/retro-shape-stage-failure-summary.sh` — executable shape script (chmod 755). Functions: `main`, `_parse_args`, `_render_prompt`, `_validate_no_unresolved_tokens`. Sentinel at EOF.
- `bin/retro-shape-stage-failure-summary-test.sh` — sibling test. Source-and-stub pattern; fixtures listed in §5 Task 3.

Modified files:
- `bin/run-retrospective-local.sh` — add `_compute_retro_period` helper, insert shape invocation between branch-checkout (line 58) and §9-prompt extraction (line 60), add one `sed` substitution after the awk extract to interpolate `{stage_failure_summary_path}` into `$prompt_file`. New local variable `shape_artifact_dir` + `stage_failure_summary_path` + `period_start_iso` + `period_end_iso` in `main()`. Same exit-code shape on shape failure (Slack error → exit 20) as the existing line-72-76 dispatch failure path.
- `AGENT_PROMPTS.md` §9 — replace the §1 stage-failure-analysis bullet block (lines 1766-1773) with a "Read the pre-computed artifact at `{stage_failure_summary_path}`" paragraph. Add one sentence at the §9 prelude (after the existing "Period of analysis" paragraph) noting "Some §1-§N sections are pre-computed by retrospective shapes; read the artifact at the named path rather than recomputing."
- `CLAUDE.md` — append a "Retrospective shapes" subsection under the existing "Runtime topology" topic (after the launchd subsection), pointing at `bin/retro-prompts/` and naming the shape pattern. ~10 lines; mirrors the depth of existing "Per-target dispatch.tools extras" or "Per-stage dispatch timeouts" paragraphs.

Not modified (intentional — recorded so reviewers don't expect changes):
- `bin/render-prompt.sh` (D-007 — shape token resolution happens locally in `bin/retro-shape-stage-failure-summary.sh`, NOT in the per-issue PROMPT_RESOLVERS registry).
- `bin/dispatch.sh` (D-004 — reuses `retrospective` arm of `allowed_tools_for`; no new case, no new env var, no new timeout tier).
- `bin/run-stage.sh` (shapes are NOT pipeline stages — D-003).
- `bin/pipeline-events.json` (no new vocabulary).
- `bin/metrics.sh` (no new metric event — D-010 / brainstorm §8 "no per-shape `shape-end` event in PoC").
- `learned-rules/harness/project-profile.md` (shapes are stack-agnostic).
- `launchd/com.twinning.retrospective.plist.template` (same binary, same trigger).
- `docs/architecture.md` (two-binary contract unchanged — INTERNAL structure changes only).

## 4. API Contract

No new API surface. The harness has no FE↔BE API; this PoC introduces no new endpoint, no new typed message, no new wire-format. The only interface surfaces involved are:
- **Argv contract** for `bin/retro-shape-stage-failure-summary.sh` (`--artifact-path <path> --period-start-iso <iso> --period-end-iso <iso> [--previous-period-path <path>]`) — documented in §5 Task 2.
- **Token surface** for `bin/retro-prompts/stage-failure-summary.md` — five named tokens listed in §3.
- **Markdown-artifact schema** — declared inline in the shape's prompt body, not a wire-format.

## 5. Backend Tasks

### Task 1: Author the shape prompt body

- `depends_on: []`
- `touches: bin/retro-prompts/stage-failure-summary.md (new file)`
- [ ] Create the directory `bin/retro-prompts/` by way of writing the prompt file (git tracks files, not empty dirs — no `.gitkeep` needed because the directory has content from the first commit).
- [ ] Write `bin/retro-prompts/stage-failure-summary.md` with the verbatim §9 §1 instruction set (per D-001 + OQ-4 — no rewording in PoC). Structure:
  - **Preamble**: "You are the `stage-failure-summary` retrospective shape …" (3 sentences naming inputs, output, period).
  - **Inputs**:
    - `{events_jsonl_path}` — absolute path to the events JSONL stream.
    - `{period_start_iso}` / `{period_end_iso}` — UTC ISO 8601 bounds for the analysis period.
    - `{previous_period_path}` — absolute path to the prior period's `stage-failure-summary.md` for trend comparison (may be the literal string `(none)` if no prior run).
  - **Task** (verbatim copy of `AGENT_PROMPTS.md:1767-1772`):
    - "Parse events.jsonl events: which stages produced outcome ∈ {failed, paused, scope-violation, pr-opened-too-early, premise-failure, merge_conflict, reconcile-human, guards-tripped, dispatch-failed, linear-post-failed, scope-approval-pending} most often?"
    - "Compare this period's counts vs the previous period."
    - "For each stage with ≥3 rejections, name the top 2 recurring reasons."
  - **Insufficient-sample carve-out**: "If `{events_jsonl_path}` does not exist or is empty, write a single-line artifact: 'No events in period: events.jsonl absent or empty.' Then exit." (mirrors `AGENT_PROMPTS.md:1761`).
  - **Output footer**: "Write your markdown summary to `{artifact_path}`. Do NOT modify other files. Do NOT post Linear comments. Do NOT commit. Do NOT run `git` commands."
  - **Artifact schema** (within the body): two top-level headers — `## Outcome breakdown (period vs previous)` and `## Recurring reasons (stages with ≥3 rejections)`.
- [ ] Confirm via Read that `{events_jsonl_path}`, `{period_start_iso}`, `{period_end_iso}`, `{artifact_path}`, `{previous_period_path}` each appear at least once in the file (the shape's render-time validator catches any missing token before dispatch — see Task 2).

### Task 2: Implement the shape script

- `depends_on: [1]`
- `touches: bin/retro-shape-stage-failure-summary.sh (new file); functions main, _parse_args, _render_prompt, _validate_no_unresolved_tokens`
- [ ] Write `bin/retro-shape-stage-failure-summary.sh` with `chmod 755`. Skeleton:

  ```bash
  #!/usr/bin/env bash
  # Shape: stage-failure-summary. Pre-computes §1 of the weekly retrospective.
  # Output: a markdown artifact at $artifact_path consumed by the parent
  # retrospective's §9 prompt via {stage_failure_summary_path} interpolation.

  set -euo pipefail
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=common.sh
  source "$SCRIPT_DIR/common.sh"

  _parse_args() { … }              # populates _ARTIFACT_PATH / _PERIOD_START_ISO / _PERIOD_END_ISO / _PREVIOUS_PERIOD_PATH
  _render_prompt() { … }           # sed-substitute the 5 tokens, write to $rendered
  _validate_no_unresolved_tokens() { … }  # grep -n '{[a-z_]\+}' $rendered; die on hit
  main() { … }                     # parse args, render, dispatch or dry-run, validate artifact

  if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
  fi
  ```
- [ ] `_parse_args` accepts `--artifact-path`, `--period-start-iso`, `--period-end-iso`, `--previous-period-path` (optional; defaults to literal `(none)`). Validates each non-empty (via the pattern of `bin/common.sh::require_env`-style die-on-empty checks). Argv consumed positionally via a `while` loop (matches the existing `bin/pipeline.sh` argv style).
- [ ] `_render_prompt` reads `$HARNESS_ROOT/bin/retro-prompts/stage-failure-summary.md` (path resolved relative to `$SCRIPT_DIR/..`; `HARNESS_ROOT` is exported by common.sh). Writes to a `mktemp -t retro-shape-stage-failure-summary-XXXXXX.md` file. Uses the `sed -e "s|{token}|val|g"` chain (same delimiter + chain shape as `bin/setup-helpers.sh:341-350::_render_discovery_prompt`). Resolves all 5 tokens:
  - `{events_jsonl_path}` → `$PROJECT_STATE_DIR/metrics/events.jsonl` (matches `bin/metrics.sh:43`).
  - `{period_start_iso}` → `$_PERIOD_START_ISO`.
  - `{period_end_iso}` → `$_PERIOD_END_ISO`.
  - `{artifact_path}` → `$_ARTIFACT_PATH`.
  - `{previous_period_path}` → `$_PREVIOUS_PERIOD_PATH`.
- [ ] `_validate_no_unresolved_tokens`: `if grep -nE '\{[a-z_]+\}' "$rendered" >/dev/null 2>&1; then die "shape: unresolved tokens in rendered prompt"; fi` (mirrors `bin/render-prompt.sh`'s residual-scan posture).
- [ ] `main`:
  1. Call `_parse_args "$@"`.
  2. Ensure `$(dirname "$_ARTIFACT_PATH")` exists; `die` clearly if not (per brainstorm Edge case 8: validate, do not silently `mkdir -p` to avoid creating typo'd directories).
  3. `local rendered; rendered="$(mktemp -t retro-shape-stage-failure-summary-XXXXXX.md)"`.
  4. `_render_prompt > "$rendered"`.
  5. `_validate_no_unresolved_tokens "$rendered"`.
  6. If `PIPELINE_DRY_RUN=1`: `log "[DRY_RUN] would dispatch.sh retrospective with prompt=$rendered artifact=$_ARTIFACT_PATH"`; `printf '%s\n' '[DRY_RUN placeholder] stage-failure-summary' > "$_ARTIFACT_PATH"`; `rm -f "$rendered"`; `return 0`. (Placeholder content satisfies the parent retrospective's downstream Read in end-to-end dry-runs.)
  7. Else: `local log_file="$PROJECT_STATE_DIR/logs/retro-shape-stage-failure-summary-$(date -u +%Y%m%dT%H%M%SZ).log"`; `mkdir -p "$(dirname "$log_file")"`.
  8. `local rc=0; bash "$SCRIPT_DIR/dispatch.sh" retrospective "$rendered" "$log_file" || rc=$?`.
  9. `rm -f "$rendered"`.
  10. `(( rc == 0 )) || die "shape: dispatch.sh retrospective failed rc=$rc (log: $log_file)"`.
  11. `[[ -f "$_ARTIFACT_PATH" ]] || die "shape: artifact not written at $_ARTIFACT_PATH (log: $log_file)"`.
- [ ] End the file with the source-and-stub sentinel (per `bin/run-retrospective-local.sh:105-107` precedent).
- [ ] Make executable: `chmod 755 bin/retro-shape-stage-failure-summary.sh`.

### Task 3: Write the shape's sibling test

- `depends_on: [2]`
- `touches: bin/retro-shape-stage-failure-summary-test.sh (new file)`
- [ ] Write `bin/retro-shape-stage-failure-summary-test.sh` following the source-and-stub pattern (per CLAUDE.md "How tests work" §). Boilerplate parallels `bin/run-stage-test.sh:1-50` (`STUB_DIR` setup, `PIPELINE_DRY_RUN=1` + `LINEAR_API_KEY=test-mock-key` exports, stub helpers).
- [ ] Source the shape script via the sentinel-bypass: `source "$SCRIPT_DIR/retro-shape-stage-failure-summary.sh"`. Override `SCRIPT_DIR` post-source so the test's stub `dispatch.sh` resolves first on `bash "$SCRIPT_DIR/dispatch.sh" …`.
- [ ] Fixtures (one per acceptance bullet + edge case):
  1. **Argv parsing — missing `--artifact-path`**: invoke `main --period-start-iso 2026-05-08T00:00:00Z --period-end-iso 2026-05-15T00:00:00Z`; expect rc != 0 + die-message contains `artifact-path`.
  2. **Argv parsing — happy path**: invoke with all required flags + a tmpdir artifact path; expect rc == 0 in dry-run + placeholder artifact exists.
  3. **Token resolution**: stub `bash "$SCRIPT_DIR/dispatch.sh"` (writes `$2` — the rendered prompt path — to a side-channel file); invoke `main` non-dry-run; read the captured rendered prompt; assert NO `{[a-z_]+}` substrings remain (covers all 5 tokens).
  4. **Dry-run path (PIPELINE_DRY_RUN=1)**: invoke `main` with `PIPELINE_DRY_RUN=1`; assert (a) stub dispatch was NEVER invoked, (b) placeholder artifact exists with non-empty content, (c) log line contains `[DRY_RUN]` prefix.
  5. **Artifact production — happy path**: stub dispatch that touches `$_ARTIFACT_PATH` (the artifact path is passed in via argv, so the stub reads its own argv to recover the path from the rendered prompt — alternatively the test exports the expected path via env var to the stub); assert post-call `[[ -f "$_ARTIFACT_PATH" ]]` returns true and shape exits 0.
  6. **Artifact missing — die path**: stub dispatch that returns 0 but DOES NOT write the artifact; assert shape dies with rc != 0 + message containing `artifact not written`.
  7. **Optional `--previous-period-path` default**: omit the flag; assert the rendered prompt's `{previous_period_path}` resolves to literal `(none)`.
  8. **Dispatch failure — die path**: stub dispatch returning rc=29 (envelope-violation sentinel); assert shape dies with rc != 0 + message containing `rc=29`.
- [ ] End the file with `printf 'OK: shape stage-failure-summary tests\n' && exit 0` on PASS path; non-zero on FAIL.
- [ ] Make executable: `chmod 755 bin/retro-shape-stage-failure-summary-test.sh`.

### Task 4: Add the `_compute_retro_period` helper to the retrospective driver

- `depends_on: []`
- `touches: bin/run-retrospective-local.sh::_compute_retro_period (new helper)`
- [ ] Add a new helper to `bin/run-retrospective-local.sh` between the `require_bin` line (line 30) and `main()` (line 32) — content anchor: AFTER the `require_bin claude gh git jq` line BEFORE `main() {`:

  ```bash
  # _compute_retro_period — emits two ISO 8601 UTC timestamps on stdout
  # (one per line: start, then end). Period semantics mirror
  # AGENT_PROMPTS.md §9 "Period of analysis":
  #   - Start: timestamp of the last weekly retrospective merge, or
  #     30 days ago if none.
  #   - End: now (UTC).
  _compute_retro_period() {
    local end_iso start_iso last_merge_unix
    end_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    last_merge_unix="$(git -C "$TARGET_REPO" log --merges --format='%ct %s' \
      | grep 'weekly retrospective' | head -1 | awk '{print $1}')"
    if [[ -n "$last_merge_unix" && "$last_merge_unix" =~ ^[0-9]+$ ]]; then
      start_iso="$(date -u -r "$last_merge_unix" +%Y-%m-%dT%H:%M:%SZ)"
    else
      start_iso="$(date -u -v-30d +%Y-%m-%dT%H:%M:%SZ)"
    fi
    printf '%s\n%s\n' "$start_iso" "$end_iso"
  }
  ```
- [ ] Verify (Read after edit) that the helper sits above `main()` so it is in scope when `main()` calls it; macOS `date -u -r` / `date -u -v-30d` shapes match the harness's BSD-date posture (per the existing `today="$(date -u +%Y-%m-%d)"` at line 34).

### Task 5: Wire the shape into `bin/run-retrospective-local.sh::main`

- `depends_on: [2, 4]`
- `touches: bin/run-retrospective-local.sh::main`
- [ ] Edit `bin/run-retrospective-local.sh::main`. Content anchor: AFTER the `else git -C "$TARGET_REPO" checkout -b "$branch" origin/main; fi` block (line ~58 — the closing `fi` of the if/else that creates-or-reuses the branch) BEFORE the `# Extract the retrospective block from AGENT_PROMPTS.md.` comment (line ~60). Insert:

  ```bash
  # ENG-129: pre-compute stage-failure-summary as a shape artifact.
  # The parent retrospective Reads the artifact (via the
  # {stage_failure_summary_path} token interpolated into the §9 prompt
  # below) and incorporates §1 verbatim. Shape failures HALT the
  # retrospective for operator review — partial retrospectives are
  # worse than re-running next week.
  local period_lines period_start_iso period_end_iso
  period_lines="$(_compute_retro_period)"
  period_start_iso="$(printf '%s' "$period_lines" | sed -n '1p')"
  period_end_iso="$(printf '%s' "$period_lines"   | sed -n '2p')"
  local shape_artifact_dir="$PROJECT_STATE_DIR/retrospective-${today}"
  local stage_failure_summary_path="${shape_artifact_dir}/stage-failure-summary.md"
  mkdir -p "$shape_artifact_dir"
  local shape_rc=0
  bash "$SCRIPT_DIR/retro-shape-stage-failure-summary.sh" \
    --artifact-path     "$stage_failure_summary_path" \
    --period-start-iso  "$period_start_iso" \
    --period-end-iso    "$period_end_iso" \
    || shape_rc=$?
  if (( shape_rc != 0 )); then
    bash "$SCRIPT_DIR/slack.sh" error "Weekly retrospective shape stage-failure-summary failed (rc=$shape_rc)"
    exit 20
  fi
  ```
- [ ] Edit the existing prompt-extraction block. Content anchor: AFTER the closing `' "$HARNESS_ROOT/AGENT_PROMPTS.md" > "$prompt_file"` line (line ~66 — close of the awk extract) BEFORE the `log "retrospective: rendered prompt …"` line (line ~67). Insert one sed substitution that interpolates the path into the extracted prompt:

  ```bash
  # ENG-129: inject the shape artifact path into the §9 prompt so the
  # parent Reads the pre-computed §1 instead of recomputing it.
  sed -i.bak \
    -e "s|{stage_failure_summary_path}|${stage_failure_summary_path}|g" \
    "$prompt_file"
  rm -f "${prompt_file}.bak"
  ```
- [ ] Run `bash -n bin/run-retrospective-local.sh` after the edit to confirm no syntax error.
- [ ] Verify (Read after edit) that nothing else in `main()` references `$today`, `$branch`, `$log_file`, or `$prompt_file` BEFORE the inserted block (it doesn't — the block sits below line 34's `today=` and lines 35-37's `branch`/`log_file`/`mkdir`, but above line 60's awk extract).

### Task 6: Edit `AGENT_PROMPTS.md` §9 to consume the shape artifact

- `depends_on: [5]`
- `touches: AGENT_PROMPTS.md (§9 only)`
- [ ] Edit `AGENT_PROMPTS.md` §9 prelude. Content anchor: AFTER the line `numeric score; otherwise emit "insufficient-sample: N=<n>, need ≥5".` (the closing line of "Period of analysis" at ~line 1761) BEFORE the line `Your analysis (every pass below must produce at least "none found" …` (~line 1763). Insert one blank line + one sentence:

  ```
  Some sections below are pre-computed by retrospective shapes (see
  bin/retro-prompts/ in the harness). When a section references
  `{stage_failure_summary_path}` (or similar `{…_path}` token), Read
  the artifact at that path verbatim instead of recomputing the
  analysis.
  ```
- [ ] Replace the §9 §1 bullet block. Content anchor: AFTER the heading line `1. **Stage failure analysis:**` (line ~1766) BEFORE the heading line `2. **Gotcha recurrence check (wired via commit trailers):**` (line ~1774). Replace the four bullet sub-lines (the `- Parse events.jsonl …`, `- Compare this period's counts …`, `- For each stage with ≥3 rejections …` lines on 1767-1772) with this paragraph (preserve the existing `1. **Stage failure analysis (pre-computed):**` heading shape — change only the body, keep the leading numeral and bold heading):

  Replace heading + bullets with:

  ```
  1. **Stage failure analysis (pre-computed):**
     - Read the pre-computed artifact at `{stage_failure_summary_path}`.
     - The artifact contains: the period's outcome breakdown, a
       period-to-period comparison, and (for each stage with ≥3
       rejections) the top 2 recurring reasons.
     - Incorporate the artifact's findings verbatim into your "Systemic
       findings (top 3)" section. Do NOT recompute the analysis.
  ```
- [ ] Run `bash bin/agent-prompts-content-test.sh` (allowed at the worktree root via the implementing-stage allowlist) to confirm fence count stays at 2 and no §0-rule assertions break (none should — see §7 sweep).

### Task 7: Document the shape pattern in CLAUDE.md

- `depends_on: [5, 6]`
- `touches: CLAUDE.md (new "Retrospective shapes" subsection)`
- [ ] Edit `CLAUDE.md`. Content anchor: AFTER the closing line of the "Runtime topology" section's launchd cron block (the line `└─ run-retrospective-local.sh     (one-shot retrospective agent → opens PR)` near the start of the file) BEFORE the next H2 heading `## Common commands`. Insert a new H2 subsection (or H3 under "Runtime topology" — match the surrounding nesting depth):

  ```
  ## Retrospective shapes (ENG-129)

  The weekly retrospective binary (`bin/run-retrospective-local.sh`) is
  being split into "shapes" — independently invocable sub-behaviors,
  each with its own prompt body under `bin/retro-prompts/<name>.md`,
  its own driver at `bin/retro-shape-<name>.sh`, and its own sibling
  test at `bin/retro-shape-<name>-test.sh`. Shapes write a markdown
  artifact under `$PROJECT_STATE_DIR/retrospective-${date}/<name>.md`;
  the parent retrospective Reads each artifact via a
  `{<name>_path}` token interpolated into AGENT_PROMPTS.md §9.

  ENG-129 ships the first shape (`stage-failure-summary`). The other
  §9 sub-behaviors stay inline in §9 until the coordinator ticket
  ships. To add a shape: drop a new prompt body under `bin/retro-prompts/`,
  write a driver + sibling test mirroring the `stage-failure-summary`
  pair, and invoke the driver from `run-retrospective-local.sh::main`
  before the §9 dispatch. Shapes reuse `dispatch.sh retrospective`'s
  allowed-tools (no new arm in `allowed_tools_for`).
  ```
- [ ] Read the file after edit to confirm the new heading sits in a sensible location and does not break adjacent markdown.

## 6. Frontend Tasks

No UI in this PoC. The harness has no frontend; the retrospective binary's product surface is a PR diff + Slack message, both already covered by the existing `bin/run-retrospective-local.sh::main` flow.

## 7. Failure Mode → Test Map

Pulled from brainstorm §5 (Error handling) and §6 (Edge cases). Each row binds a failure mode to a concrete test (unit-level shell test or integration dry-run).

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
|---|---|---|---|---|
| Shape claude invocation fails (`dispatch.sh` rc != 0) | Stub dispatch returning rc=29 | Shape `die`s rc != 0, message contains `rc=29`; parent halts at line 72 path (Slack error + exit 20) | unit | `bin/retro-shape-stage-failure-summary-test.sh::fixture-8-dispatch-rc-non-zero` |
| Artifact not written by claude (rc=0 but no file) | Stub dispatch returns 0 without writing `$_ARTIFACT_PATH` | Shape `die`s rc != 0, message contains `artifact not written` | unit | `bin/retro-shape-stage-failure-summary-test.sh::fixture-6-artifact-missing` |
| `events.jsonl` missing or empty | (Behavior is internal to claude; not in scope for shape script — covered by prompt body, asserted at lint level via existence of the carve-out paragraph in `bin/retro-prompts/stage-failure-summary.md`) | Prompt body contains the "No events in period" carve-out | unit | `bin/retro-shape-stage-failure-summary-test.sh::fixture-9-prompt-body-carries-empty-events-carve-out` (Read + grep on the prompt file path) |
| Period computation fails (no prior retrospective merge) | Empty `git log --merges … 'weekly retrospective'` output | `_compute_retro_period` falls back to 30-days-ago → now | unit | `bin/retro-shape-stage-failure-summary-test.sh::fixture-10-period-fallback-no-prior-merge` (test sources `bin/run-retrospective-local.sh` for `_compute_retro_period`, stubs `git -C` to emit empty output, asserts start is `~30d` before end) |
| Tokens unresolved in rendered prompt | Mutate the prompt template to add `{bogus_token}`; run shape | Shape `die`s rc != 0, message contains `unresolved tokens` | unit | `bin/retro-shape-stage-failure-summary-test.sh::fixture-11-unresolved-token-die` |
| Operator manually invokes shape with non-existent artifact parent dir | Pass `--artifact-path /no-such-dir/x.md` | Shape `die`s rc != 0, message contains `parent directory` | unit | `bin/retro-shape-stage-failure-summary-test.sh::fixture-12-parent-dir-missing-die` |
| Optional `--previous-period-path` flag omitted | Invoke without the flag | Rendered prompt's `{previous_period_path}` resolves to literal `(none)` | unit | `bin/retro-shape-stage-failure-summary-test.sh::fixture-7-previous-period-default` |
| Same-day re-run overwrites prior artifact | Invoke twice on the same `${today}` | Second invocation overwrites; no error; second artifact reflects fresh inputs | unit | `bin/retro-shape-stage-failure-summary-test.sh::fixture-13-same-day-rerun-overwrites` (write a sentinel via the stub on call 1; on call 2 stub writes different content; assert post-call-2 file content is from call 2) |
| Dry-run end-to-end on parent retrospective | `PIPELINE_DRY_RUN=1 bash bin/run-retrospective-local.sh` | Shape's placeholder artifact lands in `$PROJECT_STATE_DIR/retrospective-${today}/stage-failure-summary.md`; parent dispatch's dry-run trace still emits | smoke | Manual smoke verified during implementation per the Goal section's verifiable outcome bullet 2 (documented in the implementing-stage TDD evidence comment; no automated harness for whole-retrospective dry-run today) |
| §9 fence count drift after edit | `bin/agent-prompts-content-test.sh` runs as part of pre-commit hook | Fence count == 2 stays true; existing §0-content assertions stay green | unit | `bin/agent-prompts-content-test.sh::all` (pre-existing test, exercised via pre-commit hook) |
| Concurrent retrospective + pipeline tick (semaphore wait) | Pipeline at K=2 when retrospective fires | Shape's `dispatch.sh` call queues via `acquire_claude_mutex`; eventually proceeds | (n/a — behavior is `dispatch.sh`'s; covered by `bin/mutex-test.sh`) | `bin/mutex-test.sh` (pre-existing) |

### Test-gate closure sweep (mandatory)

Tokens this plan removes from production code:
- `AGENT_PROMPTS.md:1766-1773` — the §1 stage-failure-analysis bullet block (replaced in place). Sibling-test grep across `bin/*-test.sh` for the candidate phrases — "Stage failure analysis", "Parse events.jsonl events", "scope-violation, pr-opened-too-early", "stage with ≥3 rejections" — returns ZERO hits in any test file. `bin/agent-prompts-content-test.sh` per-stage loops (lines 441-477, 487-509, 522-549, 1019-1038, 1196-1241) iterate every section including §9 but assert phrases sourced from §0 (Common rules) via `rendered_stage_body`. None of those phrases live in the §1 paragraph being replaced. **No File Structure entry needs to invert an assertion.** Closure: clean.

No other production code surface is reduced.

## 8. Test Strategy

**Unit (mandatory — runs in pre-commit hook):**
- New: `bin/retro-shape-stage-failure-summary-test.sh` — 11 fixtures listed in Task 3 + §7's Failure Mode table. Source-and-stub pattern; no claude invocation; runs in < 5 s. Joins the `.githooks/pre-commit` enumeration automatically (the hook iterates `bin/*-test.sh`).
- Pre-existing, exercised post-edit: `bin/agent-prompts-content-test.sh` — confirms §9 fence count stays 2, §0 cross-stage rules still reach §9's rendered body (the §1 paragraph rewording is invisible to these assertions per the test-gate closure sweep above).
- Pre-existing, no change: `bin/render-prompt-test.sh` (covers per-issue PROMPT_RESOLVERS; the shape's token surface is local, not registered there — D-007).

**Integration (mandatory — manual gate before commit):**
- Run `PIPELINE_DRY_RUN=1 TARGET_REPO=/Users/rajatgoyal/code/twinning-harness bash bin/run-retrospective-local.sh` against the harness-self target on a clean checkout. Expected: (a) `bin/retro-shape-stage-failure-summary.sh` invoked; (b) placeholder artifact lands at `$PROJECT_STATE_DIR/retrospective-${today}/stage-failure-summary.md`; (c) `[DRY_RUN]` line for the §9 dispatch; (d) no claude invocation; (e) script exits 0. Document the result + a paste of the relevant log lines in the implementing-stage TDD evidence comment.

**Smoke (recommended — operator follow-up):**
- After merge, the next Monday 09:00 retrospective fires automatically via launchd. Inspect `$PROJECT_STATE_DIR/retrospective-${that-monday}/stage-failure-summary.md` for non-empty content and inspect the PR body's "Systemic findings" section for §1-derived content matching the artifact. This is the AC #2 "output is unchanged" verification — covered post-merge, not in the test suite.

**Adversarial (covered by fixtures):**
- Fixture 6 (artifact missing) covers the brainstorm §5 "agent claimed success but didn't write" failure mode.
- Fixture 8 (rc=29 dispatch) covers the parent halt-on-rc!=0 path.
- Fixture 11 (unresolved tokens) covers the brainstorm §5 "{foo} left unsubstituted" rail.
- Fixture 12 (parent dir missing) covers the brainstorm §6 edge case 8 (operator invokes with bogus artifact path).

**Local-gate caveat (per the implementing-sandbox memo in operator memory):**
- The implementing-stage `--allowed-tools` permits `Bash(bash bin/<test>.sh:*)` for all the listed test files but NOT for newly-created `bin/retro-shape-stage-failure-summary-test.sh` (until the operator regenerates `.pipeline-config/config.json::dispatch.tools.{implementing,qa}[]` per the snippet in CLAUDE.md's "Per-target dispatch.tools extras"). The implement agent should document the gate-blocked state in its TDD evidence comment; pre-commit hook will exercise the new test in the operator's local environment regardless.

---

## Self-review

Self-review covers five personas per the prompt's "Self-review (MANDATORY)" instruction. Verdicts inline; full finding lists were resolved in place during plan drafting.

### Persona: feasibility — PASS · P0: 0

Codebase-fact verification, sweep against current tree (Read + Grep on each cited file). Every `path:line` in §2 was re-confirmed at draft time (`bin/run-retrospective-local.sh:32-34/41-58/60-66/72-76`, `AGENT_PROMPTS.md:1722/1724-1929 fence count/1756-1773`, `bin/dispatch.sh:375-422/439/468-489/511-526/563-566`, `bin/metrics.sh:43/67`, `bin/setup-prompts/discovery.md:1-30`, `bin/setup.sh:302-308`, `bin/setup-helpers.sh:341-350`, `bin/common.sh:9-12/30-37/56-62`, `bin/render-prompt.sh:13-22/91-113/226`). Every Edit-boundary step in Tasks 4-7 names a content anchor + a tilde-prefixed line hint; no bare-line-number-only step. Every task's `depends_on` is correct (Task 1 → Task 2 → Tasks 3/5; Task 4 is independent of 1-3 but is depended on by Task 5; Task 6 → Tasks 5; Task 7 → 5, 6). Every Failure Mode row names a concrete unit fixture or pre-existing test. **Test-gate closure sweep clean** — the §1 paragraph rewording sheds no tokens any sibling test asserts on. **Branch-base freshness** — empty `HEAD..origin/main` recorded against SHA `55268f2f7d5a0908e263ab4a4883cc8cd49b84db`; no Task 0 rebase needed.

### Persona: scope — PASS · P0: 0

Every File Structure entry traces to a brainstorm decision: `bin/retro-prompts/stage-failure-summary.md` → D-001/D-002; `bin/retro-shape-stage-failure-summary.sh` → D-003; `bin/retro-shape-stage-failure-summary-test.sh` → D-009; `bin/run-retrospective-local.sh` edit → D-006/D-008; `AGENT_PROMPTS.md` §9 edit → D-006; `CLAUDE.md` edit → §3 brainstorm "Files added/modified" item 7. The plan does NOT introduce a coordinator (correctly fenced by D-010), does NOT touch `bin/dispatch.sh`/`bin/run-stage.sh`/`bin/render-prompt.sh`/`bin/pipeline-events.json`/`bin/metrics.sh`/`launchd/*` (matches brainstorm §3 "Files NOT modified"). Tasks' `touches` lists stay inside the declared File Structure. No gold-plating — period-computation helper is the one bash-side enrichment over today's prompt-side computation, justified by D-008. **No scope drift.**

### Persona: coherence — PASS · P0: 0

Goal sentence ("Extract the §1 stage-failure analysis behavior … into a standalone shape … proving the shape-extraction pattern works end-to-end on one behavior while §2-§12 remain inline.") matches brainstorm Overview/Problem (§1: monolithic retrospective; PoC: extract one). Backend Tasks 1-7 jointly realise every row of the brainstorm §3 "Files added" + "Files modified" list. Test Strategy covers every Failure Mode → Test Map row (every row has a concrete fixture name + a test layer). API Contract correctly states "no new API surface" — brainstorm has no FE↔BE wire surface either.

### Persona: design — PASS · P0: 0

The shape script respects `docs/architecture.md`'s two-binary topology (retrospective remains a peer; INTERNAL split only). It uses the shared semaphore the same way every claude dispatch does (`dispatch.sh retrospective` route, sequential not concurrent — brainstorm §8 ENG-81 stress-test). It does NOT introduce a layering violation: the shape sits LATERAL to `bin/run-retrospective-local.sh`, both invoking `dispatch.sh` — the dependency direction is shape script → dispatch.sh (existing arrow). No circular deps. The new `bin/retro-prompts/` directory mirrors `bin/setup-prompts/` exactly (precedent: discovery prompt) — no new module boundary, just a parallel one. `_compute_retro_period` lives in the caller (`run-retrospective-local.sh`), which is the right scope: it's retrospective-binary-internal, not used by orchestrator-side code. The decision to NOT register tokens in `bin/render-prompt.sh::PROMPT_RESOLVERS` is correct per D-007 — render-prompt has per-issue semantics that don't apply to retrospective period-based shapes.

### Persona: product — PASS · P0: 0

Linear ticket asks for: "Pick the smallest current retrospective sub-behavior … Create AGENT_PROMPTS.md section for the new shape (or learned-rules retrospective-specific prompt file) … New bin/retro-shape-<name>.sh that invokes claude with the shape prompt and produces its output artifact … Existing run-retrospective-local.sh DELEGATES to the new shape script for that one behavior; remaining behaviors stay inline … Tests cover: shape invocation, artifact production, dry-run support". Plan delivers each: smallest behavior chosen (D-001), new prompt file under `bin/retro-prompts/` (Task 1) — the ticket's parenthetical "learned-rules retrospective-specific prompt file" is satisfied by the parallel `bin/setup-prompts/` precedent, NOT by writing to `learned-rules/` (which is reserved for retrospective-curated rules, not shape prompts), shape script with claude invocation + artifact production (Task 2), delegation via the §9 edit (Task 6), tests for invocation/artifact/dry-run (Task 3 fixtures 2/3/4/5/6). AC #1 (one behavior runs via shape-script architecture) → Task 5 wiring. AC #2 (existing output unchanged) → D-001's verbatim move + Task 6's "incorporate verbatim" instruction. AC #3 (tests cover invocation/artifact/dry-run) → Task 3 fixtures.

### Gate result

**5/5 personas PASS · zero P0 findings · proceeding to commit + stage-summary.**
