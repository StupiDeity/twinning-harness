---
linear: ENG-194
date: 2026-06-16
topic: Reviewer auto-defers out-of-plan-scope findings via shared matcher + ledger field
---

# ENG-194 — Reviewer is scope-aware: out-of-plan-scope findings auto-defer, never loop back

## Goal

Make the reviewing agent classify a major finding whose canonical-anchor file is
outside the plan's `## File Structure` as `blocks_ship=false defer_reason="out-of-plan-scope"`,
route it through ENG-191's `_post_deferred_majors_comment_if_eligible` (unchanged), and
exclude it from the `reviewing → implementing` loopback at iteration 1, with a shared
`bin/plan-scope.sh` matcher used by both `bin/scope-check.sh` and
`bin/review-ledger-schema.sh`'s rule-6 cross-check so the reviewer-defer and
scope-check-halt decisions cannot diverge.

## Assumption Inventory

**Branch-base freshness.** `git log --oneline HEAD..origin/main` at plan time is
NON-EMPTY (32 commits behind — ENG-118, ENG-193, ENG-119 follow-up fixes, the
2026-06-16 dispatch fix `9800da0`, and the 2026-06-16 render-prompt fix `532f4a4`).
The deltas are the predecessors this plan consumes (ENG-191 deferred-majors path,
ENG-193 auto-ticketing) plus orthogonal threshold-gating work. None rewrites the
sites this plan edits. Task 0 below rebases onto `origin/main` BEFORE any other
work; subsequent tasks use CONTENT anchors (section headers, distinctive function
signatures, quoted code fragments) so the `path:LINE` references survive both the
rebase and any pre-existing churn between this branch's drafting time and
implement-time.

All `path:LINE` excerpts below were Read against THIS branch's HEAD this dispatch;
the implementer re-verifies after Task 0's rebase.

| # | Assumption | Status | Evidence |
|---|---|---|---|
| 1 | `bin/scope-check.sh::find_canonical_plan` matches frontmatter `linear: <ID>` over `find … docs/plans -maxdepth 1` and prints absolute path on stdout | **verified** | `bin/scope-check.sh:143-157` (Read this dispatch — awk body matches frontmatter `linear:` within 20-line cap) |
| 2 | `bin/scope-check.sh::extract_scope_section` extracts the body between `## File Structure` (or `### File Structure` / `## N. File Structure`) and the next sibling heading via awk depth tracking | **verified** | `bin/scope-check.sh:159-172` |
| 3 | `bin/scope-check.sh::main` parses `allowed_files` via `grep -oE '([a-zA-Z0-9_./-]+/)*[a-zA-Z0-9_.-]+\.[a-zA-Z0-9]+'` and `allowed_dirs` via `grep -oE '([a-zA-Z0-9_.-]+/){1,}'` + an awk filter that drops malformed `<basename>.<ext>/` captures (ENG-25 + ENG-46 fixes) | **verified** | `bin/scope-check.sh:297-314` |
| 4 | `bin/scope-check.sh::main`'s per-file in-scope loop is `grep -qxF "$f" <<<"$allowed_files"` (exact-match) followed by a per-line dir-prefix `case "$f" in "$d"*)` check | **verified** | `bin/scope-check.sh:356-366` |
| 5 | `bin/scope-check.sh::is_benign` reads `_BENIGN_PATH_CLASSES` array (5 globs), `SCOPE_BENIGN_LOCKFILES` array, and `crates/<name>/tests/` carve-out via dynamic-scope `$allowed_files$allowed_dirs` from `main()` | **verified** | `bin/scope-check.sh:174-207` (ENG-96 wired the lockfile array; remains UNCHANGED by this plan) |
| 6 | `bin/scope-check.sh:53` is `export PIPELINE_WRITER=scope-check` — the source-insertion site for `bin/plan-scope.sh` | **verified** | `bin/scope-check.sh:53` |
| 7 | `bin/scope-check.sh:59-65` defines `_BENIGN_PATH_CLASSES` as a 5-glob hardcoded array; insertion of `source plan-scope.sh` MUST go AFTER line 53 BEFORE line 59 so the helper is loaded before the benign-class array is referenced | **verified** | `bin/scope-check.sh:59-65` |
| 8 | `bin/render-prompt.sh::PROMPT_RESOLVERS` is a newline-separated `token=resolver_fn` registry at lines 40-63; adding a token requires (a) registering, (b) defining `_resolve_*` function, (c) emitting `{token}` in AGENT_PROMPTS.md | **verified** | `bin/render-prompt.sh:40-63` |
| 9 | `bin/render-prompt.sh::_resolve_review_converge_rounds` (lines 292-303) is the precedent for a NON-PATH resolver returning data — reads `config_get`, prints integer to stdout, NOT registered in `_write_rendered_paths_sidecar` | **verified** | `bin/render-prompt.sh:292-303` |
| 10 | `bin/render-prompt.sh::_write_rendered_paths_sidecar` enumerates path-shaped resolvers explicitly (lines 94-127); ENG-156 D-004 contract requires non-path resolvers stay OUT (no new sidecar entry for `plan_scope_allowed_paths`) | **verified** | `bin/render-prompt.sh:94-127` |
| 11 | `bin/render-prompt.sh:451` houses `die "render-prompt: unknown token '$t' in source — register a resolver in PROMPT_RESOLVERS"` — registering the new token will satisfy this guard | **verified** | `bin/render-prompt.sh:451` |
| 12 | `bin/review-ledger-schema.sh::sanitise_for_diag` defined at line 115; `_emit_incomplete` at 135; `_warn_unknown` at 145 — these three helpers handle agent-controlled string interpolation per ENG-190 D-009 contract | **verified** | `bin/review-ledger-schema.sh:115,135,145` |
| 13 | `bin/review-ledger-schema.sh::cmd_validate` has the ENG-191 deferability check block guarded by `if [[ "$as_val" == "major" \|\| "$as_val" == "critical" ]] && [[ -n "$dispatch_id_flag" && "$did_val" == "$dispatch_id_flag" ]]` — this is the schema-grace clause this plan's rule 2 + rule 3 hook off | **verified** | `bin/review-ledger-schema.sh:352-353` |
| 14 | `bin/review-ledger-schema.sh::cmd_validate` critical-floor-blocks-ship check is the `if [[ "$as_val" == "critical" && "$bs_val" != "true" ]]` block returning rc=49 with `critical-floor-blocks-ship-violation` — insertion point for the new closed-vocabulary check (rule 1) is immediately AFTER this block | **verified** | `bin/review-ledger-schema.sh:362-365` |
| 15 | `bin/review-ledger-schema.sh::cmd_validate` decision_factors-required check spans `df_type=` through `decision_factors keys must be boolean` — the entire block (lines 375-398) is wrapped by rule 3's `if [[ "$dr_val_for_df" != "out-of-plan-scope" ]]` guard | **verified** | `bin/review-ledger-schema.sh:375-398` |
| 16 | `bin/review-ledger-schema.sh::cmd_validate` known-fields allowlist is the inline jq expression `'(keys) - ["ledger_schema_version",...,"decision_factors"] \| .[]'` at line 404 — this is where `"defer_reason"` is appended | **verified** | `bin/review-ledger-schema.sh:401-407` |
| 17 | `bin/run-stage.sh::_post_deferred_majors_comment_if_eligible` reads ledger rows where `blocks_ship=false` regardless of `defer_reason` and posts under sig `deferred-majors/$ident` — UNCHANGED by this plan; new scope-deferred rows appear in the comment as flat bullets (AC #2 structurally satisfied) | **verified** | `bin/run-stage.sh:1483,1558` (definition + post-call site) |
| 18 | `bin/run-stage.sh:2432` invokes `_validate_review_ledger "$ident"` inside the reviewing-stage post-dispatch validator gate — this plan's new validator rules ride on the existing wiring; no change needed at the call site | **verified** | `bin/run-stage.sh:2432` |
| 19 | `AGENT_PROMPTS.md` §5 Review Agent body — `## 5. Review Agent` heading at line 1335; "Deferability adjudication (MANDATORY — ENG-191)" block opens at line 1439; the closing prose before the count-tuple is the paragraph ending `…justifies the decision. Examples: …blocks: irreversible API surface change.` ending at line 1479 (line 1480 is blank). Insertion site for the new "Plan-scope adjudication" block is the blank line 1480 — BEFORE the count-tuple emission's `Count-tuple emission (MANDATORY …` paragraph at line 1481 | **verified** | `AGENT_PROMPTS.md:1335,1439,1479-1481` |
| 20 | `AGENT_PROMPTS.md` §5 count-tuple emission `Findings: / Adjudicated: / Deferrable:` is at lines 1481-1500; `Deferrable:` line at 1486 | **verified** | `AGENT_PROMPTS.md:1481-1500` |
| 21 | `AGENT_PROMPTS.md` §5 Review-comment quality rubric MANDATES `path/to/file.ext:LINE` anchor as first body token after severity tag at lines 1572-1586 — this is the source of truth D-002 reads for the canonical fix-target | **verified** | `AGENT_PROMPTS.md:1572-1586` |
| 22 | `AGENT_PROMPTS.md` §5 Mechanical predicates block (path B / B′ / C / D) lives at lines 1614-1620; Path D one-line predicate at 1617-1618, Path B′ at 1619-1620 — both updated to add the extended OR / implicit complement per D-004 | **verified** | `AGENT_PROMPTS.md:1614-1620` |
| 23 | `AGENT_PROMPTS.md` §5 Output block contains the path-D verbose body `To ship with deferred majors (path D — …)` at line 1824 — parenthetical predicate extended for D-004 consistency | **verified** | `AGENT_PROMPTS.md:1824` |
| 24 | `bin/pipeline-events.json::pass_reasons` array contains `"ship-with-deferred-majors"` — this plan does NOT add a new reason token; the existing one is reused for the scope-deferred selective exit | **verified** | `bin/pipeline-events.json:10-11` (grep — `ship-with-deferred-majors`) |
| 25 | No existing code uses `defer_reason` or `out-of-plan-scope` anywhere in `bin/` or `AGENT_PROMPTS.md` — no field/token collision | **verified** | `grep -rn 'defer_reason\|out-of-plan-scope' bin/ AGENT_PROMPTS.md bin/pipeline-events.json` returned zero hits this dispatch. NOTE: the substring `plan_scope` already appears once in `AGENT_PROMPTS.md:1568` as `<!-- meta: metric name=plan_scope_silent -->` (unrelated `Scope-enforcement safety-valve` meta-marker). This does NOT collide with the new `plan_scope::*` shell namespace nor the `{plan_scope_allowed_paths}` token (the brace-wrapped token disambiguates by shape); recorded here for the implementer's awareness. |
| 26 | `plan_scope_allowed_paths` is NOT yet a registered resolver token in `PROMPT_RESOLVERS`; `plan_scope::*` is not a defined function namespace | **verified** | `grep plan_scope bin/render-prompt.sh bin/scope-check.sh bin/review-ledger-schema.sh` returned zero hits this dispatch |
| 27 | `bin/plan-scope.sh` does NOT exist yet | **verified** | `ls bin/plan-scope*.sh` → "No such file or directory" this dispatch |
| 28 | `bin/scope-check-test.sh`, `bin/review-ledger-schema-adversarial-test.sh`, `bin/agent-prompts-content-test.sh`, `bin/render-prompt-test.sh`, `bin/run-stage-test.sh` ALL exist in `bin/` and follow the sentinel `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi` pattern for sourceability | **verified** | `ls bin/{scope-check-test,review-ledger-schema-adversarial-test,agent-prompts-content-test,render-prompt-test,run-stage-test}.sh` this dispatch |
| 29 | The `.githooks/pre-commit` test runner globs `bin/*-test.sh` (ENG-196) — newly-added `bin/plan-scope-test.sh` is picked up automatically; the `dispatch.sh::_dispatch_tools_autotests` helper (ENG-196) grants `Bash(bash bin/plan-scope-test.sh:*)` to the implementing/qa stages in the same dispatch without an allowlist edit | **verified** | `learned-rules/harness/project-profile.md::"## Build & test gates"` + CLAUDE.md "Tool allowlist & probing" preamble |
| 30 | `learned-rules/harness/project-profile.md::"## Build & test gates"` Test command line reads `bash .githooks/pre-commit runs every bin/*-test.sh on disk` — the glob covers the new test file without a profile edit, satisfying the add-side test-gate closure sweep | **verified** | `learned-rules/harness/project-profile.md` (Read this dispatch); the glob shape means new sibling test files are auto-runnable (no per-file enumeration on the profile or in `config.json::dispatch.tools`) |

## System invariants

- **Reviewer + scope-check parse the plan's File Structure identically.** Byte-for-byte equality of `allowed_files` and `allowed_dirs` between `bin/scope-check.sh`'s refactored parse path and `bin/render-prompt.sh::_resolve_plan_scope_allowed_paths` is the structural assertion behind AC #4; divergence reintroduces the catch-22. `verified_by: task:T6` (Task 6's `bin/plan-scope-test.sh` test 5 — byte-for-byte cross-caller assertion).
- **Critical-floor invariant survives the new defer path.** A `cold_severity=critical` or `adjudicated_severity=critical` row MUST carry `blocks_ship=true` regardless of `defer_reason`; `bin/review-ledger-schema.sh`'s existing critical-floor-blocks-ship check (lines 362-365) keeps firing on critical+blocks_ship=false. `verified_by: task:T8` (Task 8's `bin/review-ledger-schema-adversarial-test.sh::AC-AD-14` — critical + blocks_ship=true + defer_reason=out-of-plan-scope informational, valid; the existing ENG-191 critical-floor fixture continues to fail any critical row with blocks_ship!=true).
- **`decision_factors` relaxation is gated strictly on `defer_reason == "out-of-plan-scope"`.** A row missing `decision_factors` when `defer_reason == "rubric"` (or absent) still trips rc=49 — the ENG-191 contract for rubric-deferred majors is preserved. `verified_by: task:T8` (Task 8's `bin/review-ledger-schema-adversarial-test.sh::AC-AD-11` — rubric+null decision_factors → rc=49).
- **Out-of-plan-scope agent claims are structurally cross-checked against the matcher.** A row with `defer_reason="out-of-plan-scope"` whose `ship_classification_rationale` either fails the anchored regex OR names a path the matcher reports as IN-plan halts the dispatch with rc=49 — closes the forge surface where an agent could fake the defer to bypass the convergence-rounds gate. `verified_by: task:T8` (Task 8's `bin/review-ledger-schema-adversarial-test.sh::AC-AD-15` and `::AC-AD-16`).
- **The new resolver token is registered in `PROMPT_RESOLVERS`.** Render-prompt's residual unknown-token validator at line 451 dies on any unregistered `{token}` — registering `plan_scope_allowed_paths` before AGENT_PROMPTS.md §5 references it is the structural pre-req. `verified_by: task:T5` (Task 5's `bin/render-prompt-test.sh::T_resolver_registered` — assert the resolver is registered AND `_resolve_plan_scope_allowed_paths` is defined).
- **`docs/plans/*` benign-path class is unchanged.** The reviewer's plan-scope adjudication does NOT consult benign-path classes; an out-of-plan finding against a `docs/knowledge/` / `docs/plans/` / `.scratch/` file gets auto-deferred (acceptable v1 cost per brainstorm §6 Edge case 8). `verified_by: task:T3` (Task 3's `bin/scope-check-test.sh::T_plan_scope_helper_sourced` — assert the refactor is behaviour-preserving on existing benign-path fixtures by sourcing scope-check.sh and re-running all `_BENIGN_PATH_CLASSES` fixtures unchanged; this plan does NOT modify the benign array itself).

## File Structure

NEW:

- `bin/plan-scope.sh` — shared in-plan-scope matcher (5 `plan_scope::*` functions + sentinel-gated `main()` for CLI dispatch).
- `bin/plan-scope-test.sh` — sibling test for `bin/plan-scope.sh`: parse-files snapshot, parse-dirs snapshot, path-match battery, shared-function sourcing assertion, byte-for-byte cross-caller assertion.

MODIFIED:

- `bin/scope-check.sh` — source `bin/plan-scope.sh`; refactor parse + match sites to delegate; preserve `find_canonical_plan` / `extract_scope_section` as back-compat wrappers; KEEP `is_benign` / `is_notable` / SEVERE/NOTABLE tier logic in place.
- `bin/scope-check-test.sh` — add one case asserting the helper is sourced.
- `bin/render-prompt.sh` — register `plan_scope_allowed_paths=_resolve_plan_scope_allowed_paths` in `PROMPT_RESOLVERS`; add `_resolve_plan_scope_allowed_paths` body (sources `bin/plan-scope.sh`, emits `#ALLOWED_FILES#` / `#ALLOWED_DIRS#` two-section payload; soft-fail to empty sets on plan-absent).
- `bin/render-prompt-test.sh` — fixture asserting the new resolver renders non-empty payload from a fixture plan + empty-header payload + soft-fail log on plan-absent.
- `bin/review-ledger-schema.sh` — extend the inline known-fields allowlist with `"defer_reason"`; add closed-vocabulary check (rule 1), defer_reason-required-on-deferred-major check (rule 2), wrap the existing `decision_factors`-required block in `if [[ "$dr_val_for_df" != "out-of-plan-scope" ]]` (rule 3), add the matcher cross-check (rule 6) with anchored-regex parse + plan_scope::path_in_scope re-run + fail-CLOSED on unparseable rationale.
- `bin/review-ledger-schema-adversarial-test.sh` — append `AC-AD-10` through `AC-AD-18` per brainstorm D-005.
- `AGENT_PROMPTS.md` — §5 Review Agent: insert "Plan-scope adjudication" block immediately before "Count-tuple emission"; update Mechanical predicates block (path D + path B′); update Output block's path-D verbose body for predicate consistency; update Output block's ledger-row instruction to emit `defer_reason` on `blocks_ship=false` major rows.
- `bin/agent-prompts-content-test.sh` — seven new prompt-content pins per brainstorm D-008.
- `bin/run-stage-test.sh` — AC #1, AC #3, AC #5 fixtures: orchestrator-side fixtures asserting the ledger row appears in the deferred-majors comment (AC #2 satisfaction) and the path-D decision-tuple shape end-to-end.
- `docs/runbooks/recovery.md` — append §14 "Scope-deferred majors (ENG-194)" — operator audit recipe.
- `CLAUDE.md` — extend the existing ENG-191 "Issue at `stage:qa` with verdict comment `reason=ship-with-deferred-majors`" failure-mode row with a one-line addendum naming the scope-deferred sub-class.
- `learned-rules/harness/project-profile.md` — REVIEW ONLY; the existing `bash .githooks/pre-commit` glob covers `bin/plan-scope-test.sh` without an edit, so no profile change required. Listed here for the add-side test-gate-closure sweep to find.

## API Contract

No new API surface — the harness has no FE↔BE contract. The reviewer's in-prompt
classification + ledger-row schema extension are agent-output contracts, not
service-to-service contracts. The relevant contract surfaces are the ledger row
shape (`defer_reason` field per D-003) and the prompt token (`{plan_scope_allowed_paths}`
per D-007) — both described in System invariants and in Backend Tasks below.

## Backend Tasks

### Task 0: Rebase onto origin/main

- `depends_on: []`
- `touches: (worktree-wide rebase only — no files edited in this task)`
- [ ] `git fetch origin main && git rebase origin/main` from the per-issue worktree root.
- [ ] After rebase, re-Read each modified-file `path:LINE` excerpt in Assumption Inventory and confirm the cited content still appears at the cited line OR (preferred) was relocated but is still identifiable by its CONTENT anchor (function name, distinctive comment, quoted code fragment). If any anchor cannot be located, halt with `bash bin/pipeline.sh event ENG-194 verdict halt --reason agent-blocked` and post a Linear comment naming the missing anchor.
- [ ] Confirm `bin/run-stage.sh::_post_deferred_majors_comment_if_eligible` is still defined (line number may shift; the helper name + sig pattern survive). Same for `_validate_review_ledger`. These are read-only assumptions — this plan does NOT edit them.
- [ ] Smoke: `bash bin/secret-probe-lint.sh && bash -n bin/*.sh` after the rebase to confirm no syntax regression from upstream churn.

### Task 1: Create `bin/plan-scope.sh` with five `plan_scope::*` functions and a sentinel-gated `main`

- `depends_on: [0]`
- `touches: bin/plan-scope.sh`
- [ ] Create the file with `#!/usr/bin/env bash` + `set -euo pipefail` + `SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"` + `source "$SCRIPT_DIR/common.sh"` header, matching the idiom at `bin/scope-check.sh:45-48`.
- [ ] Add `plan_scope::find_plan <issue_id> <worktree_root>` — body is the awk frontmatter matcher from `bin/scope-check.sh::find_canonical_plan` (lines 143-157), unchanged. Returns absolute path on stdout; rc=1 on no match.
- [ ] Add `plan_scope::extract_section <plan_path>` — body is the awk depth-tracking extractor from `bin/scope-check.sh::extract_scope_section` (lines 159-172), unchanged. Empty stdout iff the section is absent.
- [ ] Add `plan_scope::parse_allowed_files <body>` — wraps the `grep -oE '([a-zA-Z0-9_./-]+/)*[a-zA-Z0-9_.-]+\.[a-zA-Z0-9]+' <<<"$body" | sort -u || true` pipeline from `bin/scope-check.sh:307`. Preserves the trailing `|| true` for `set -o pipefail` safety on no-match.
- [ ] Add `plan_scope::parse_allowed_dirs <body>` — wraps the `grep -oE '([a-zA-Z0-9_.-]+/){1,}' <<<"$body" | awk '!/^[a-zA-Z0-9_-][a-zA-Z0-9_.-]*\.[a-zA-Z0-9]+\/$/' | sort -u || true` pipeline from `bin/scope-check.sh:313-314`. Preserves the ENG-46 dotfile-dir-safe awk anchor.
- [ ] Add `plan_scope::path_in_scope <path> <allowed_files> <allowed_dirs>` — exact-match against `allowed_files` (via `grep -qxF`) then per-line dir-prefix loop against `allowed_dirs` (via `case "$f" in "$d"*)`); body mirrors `bin/scope-check.sh:358-366`. Returns 0=in-scope, 1=out-of-scope. STRICTLY structural — does NOT consult benign-path classes or stack-conditional lockfiles.
- [ ] Add `main()` dispatching `find-plan` / `extract-section` / `parse-allowed-files` / `parse-allowed-dirs` / `path-in-scope` sub-commands by `$1` for CLI use.
- [ ] Add the sourceability sentinel at end: `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi`.

### Task 2: Refactor `bin/scope-check.sh` to source `bin/plan-scope.sh` and delegate parse + match

- `depends_on: [1]`
- `touches: bin/scope-check.sh::find_canonical_plan, bin/scope-check.sh::extract_scope_section, bin/scope-check.sh::main`
- [ ] Insert `# shellcheck source=plan-scope.sh` + `source "$SCRIPT_DIR/plan-scope.sh"` AFTER the line `export PIPELINE_WRITER=scope-check` (CONTENT anchor: the literal line ending the comment block headed `# ENG-41 T3: scope-check lane`), BEFORE the comment block headed `# ENG-96: benign-path classes are the four harness-owned globs` (CONTENT anchor). Placement mirrors the `source "$SCRIPT_DIR/common.sh"` line above (informational: ~line 53-54).
- [ ] Replace the BODY of `find_canonical_plan` (CONTENT anchor: between `find_canonical_plan() {` and its matching closing `}`) with a single line: `plan_scope::find_plan "$1" "$2"`. The function name stays live for back-compat callers in `bin/scope-check-test.sh`.
- [ ] Replace the body of `extract_scope_section` (CONTENT anchor: `extract_scope_section() {` opening) similarly with `plan_scope::extract_section "$1"`.
- [ ] In `main()`, replace the two-line `allowed_files=$(grep -oE …)` / `allowed_dirs=$(grep -oE … | awk …)` assignment block (CONTENT anchors: the comment `# ENG-25: \`*\` (not \`+\`) on the directory-prefix group` opening the block; the line `awk '!/^[a-zA-Z0-9_-]` closing the awk filter) with two calls: `allowed_files="$(plan_scope::parse_allowed_files "$body")"` and `allowed_dirs="$(plan_scope::parse_allowed_dirs "$body")"`. Preserve the trailing empty-set check (`if [[ -z "$allowed_files$allowed_dirs" ]]`) verbatim.
- [ ] In the per-file loop (CONTENT anchor: opening `while IFS= read -r f; do` ending before `if is_benign "$f"; then`), replace the `grep -qxF "$f" <<<"$allowed_files"` + the inner `while IFS= read -r d; do … done <<<"$allowed_dirs"` block with a single call: `if plan_scope::path_in_scope "$f" "$allowed_files" "$allowed_dirs"; then continue; fi`. The subsequent `is_benign` / `is_notable` / SEVERE/NOTABLE branches MUST stay untouched — `is_benign` reads `allowed_files` / `allowed_dirs` via dynamic scope (assumption 5), so renaming or hoisting them would break the Rust crates-tests carve-out at lines 200-205.

### Task 3: Add `bin/scope-check-test.sh` case asserting the helper is sourced

- `depends_on: [2]`
- `touches: bin/scope-check-test.sh::T_plan_scope_helper_sourced (new function)`
- [ ] Locate the existing test-function naming pattern (the existing tests use names like `case_*` / `test_*` — match whatever shape is present at HEAD post-rebase). Append a new test that sources `bin/scope-check.sh` (under `PIPELINE_DRY_RUN=1` + a `LINEAR_API_KEY=test-mock-key` stub) and asserts `declare -f plan_scope::path_in_scope` succeeds. Failure mode: prints `FAIL: plan_scope helper not sourced` and exits 1.
- [ ] As regression coverage for the System invariant "`docs/plans/*` benign-path class is unchanged": within the same test, source the file and grep `${_BENIGN_PATH_CLASSES[@]}` for the literal entries `docs/knowledge/*`, `docs/plans/*`, `docs/brainstorms/*` to confirm the refactor did not touch the array.

### Task 4: Add the `plan_scope_allowed_paths` resolver to `bin/render-prompt.sh`

- `depends_on: [1]`
- `touches: bin/render-prompt.sh::PROMPT_RESOLVERS, bin/render-prompt.sh::_resolve_plan_scope_allowed_paths`
- [ ] Append `plan_scope_allowed_paths=_resolve_plan_scope_allowed_paths` to the `PROMPT_RESOLVERS` registry — CONTENT anchor: AFTER the existing line `review_converge_rounds=_resolve_review_converge_rounds` (last entry of the heredoc-quoted multi-line string), BEFORE the closing single-quote on its own line that terminates the heredoc. Adding INSIDE the heredoc so the registry string includes the new token.
- [ ] Add `_resolve_plan_scope_allowed_paths()` immediately AFTER `_resolve_review_converge_rounds()` (CONTENT anchor: AFTER the closing `}` of `_resolve_review_converge_rounds`, BEFORE `_resolve_learned_rules_dir() { printf '%s' "$_RENDER_LEARNED_RULES_DIR"; }`). Body sources `bin/plan-scope.sh`, calls `plan_scope::find_plan` against `$_RENDER_ISSUE_ID` and `$(git rev-parse --show-toplevel 2>/dev/null || printf '%s' "${TARGET_REPO-}")` for `worktree_root`. On plan-absent OR empty section: emit the two headers with empty bodies and `log "[render] plan_scope_allowed_paths: no plan for $issue_id; emitting empty sets" >&2`; return 0. On success: emit `#ALLOWED_FILES#\n<parse_allowed_files output>\n#ALLOWED_DIRS#\n<parse_allowed_dirs output>\n`.
- [ ] Do NOT add the new token to `_write_rendered_paths_sidecar` — the resolver returns a structured manifest, not a path (assumption 10 + ENG-156 D-004 sidecar contract).

### Task 5: Extend `bin/render-prompt-test.sh` with new-resolver fixtures

- `depends_on: [4]`
- `touches: bin/render-prompt-test.sh::T_resolver_registered, bin/render-prompt-test.sh::T_plan_scope_allowed_paths_render`
- [ ] Add `T_resolver_registered` (or sibling test matching existing naming pattern): source `bin/render-prompt.sh`; assert `[[ "$PROMPT_RESOLVERS" == *plan_scope_allowed_paths=_resolve_plan_scope_allowed_paths* ]]` AND `declare -f _resolve_plan_scope_allowed_paths` succeeds.
- [ ] Add `T_plan_scope_allowed_paths_render`: construct a tmp worktree fixture with `docs/plans/<date>-eng-194-foo.md` containing the frontmatter + a `## File Structure` block listing `bin/foo.sh` + `docs/`. Set `_RENDER_ISSUE_ID=ENG-194`; call `_resolve_plan_scope_allowed_paths`; assert the output contains the literal lines `#ALLOWED_FILES#`, `bin/foo.sh`, `#ALLOWED_DIRS#`, `docs/` in that order.
- [ ] Add a third case asserting the soft-fail: when `docs/plans/` is empty, the resolver prints `#ALLOWED_FILES#\n#ALLOWED_DIRS#\n` to stdout and a `[render] plan_scope_allowed_paths: no plan for ENG-194` warning to stderr; rc=0.

### Task 6: Create `bin/plan-scope-test.sh` with the AC #4 byte-for-byte cross-caller assertion

- `depends_on: [1, 2, 4]`
- `touches: bin/plan-scope-test.sh (new file)`
- [ ] Header: `#!/usr/bin/env bash` + `set -euo pipefail` + source the helper under `STUB_DIR` setup + `PIPELINE_DRY_RUN=1` per the source-and-stub idiom documented in CLAUDE.md "Tests".
- [ ] Test 1 (`parse_allowed_files` snapshot): construct a fixture body containing `bin/setup.sh`, `docs/install.md`, `CLAUDE.md` (repo-root), `bin/dispatch.sh`. Assert `plan_scope::parse_allowed_files` output is byte-equal to `CLAUDE.md\nbin/dispatch.sh\nbin/setup.sh\ndocs/install.md\n` (sort -u order — `CLAUDE.md` sorts before `bin/...` because uppercase precedes lowercase under default `LC_COLLATE=C`).
- [ ] Test 2 (`parse_allowed_dirs` snapshot): construct a fixture body containing `docs/`, `.github/workflows/`, `bin/`. Assert output is byte-equal to `.github/workflows/\nbin/\ndocs/\n`. Pin includes the ENG-46 dotfile-dir case.
- [ ] Test 3 (`path_in_scope` battery): with `allowed_files="bin/setup.sh\nCLAUDE.md"`, `allowed_dirs="docs/\n.github/workflows/"`, assert rc=0 for `bin/setup.sh`, `CLAUDE.md`, `docs/install.md`, `.github/workflows/ci.yml`; rc=1 for `bin/setup.sh.bak`, `random.txt`. (Note: `docs/install.md.bak` would still match the `docs/` prefix because `case` does literal prefix-match; this is intentional and matches scope-check.sh's pre-refactor behaviour.)
- [ ] Test 4 (sourcing assertion — AC #4 first half): source `bin/scope-check.sh` (with stubs); assert `declare -f plan_scope::path_in_scope` succeeds. Then source `bin/render-prompt.sh` (with stubs) in a SUBSHELL (so the bash state doesn't leak); assert the same.
- [ ] Test 5 (byte-for-byte cross-caller — AC #4 second half): construct a fixture plan file at `$tmp/docs/plans/2026-06-16-eng-194-foo.md` with frontmatter `linear: ENG-194` + a `## File Structure` body. Invoke scope-check's refactored parse via `bash -c 'source bin/scope-check.sh; body="$(extract_scope_section …)"; allowed_files="$(plan_scope::parse_allowed_files "$body")"; printf "%s\n" "$allowed_files"'`. Invoke the resolver's parse via `_RENDER_ISSUE_ID=ENG-194 _resolve_plan_scope_allowed_paths` (then sed-extract the `#ALLOWED_FILES#` section). Assert the two outputs are byte-equal via `diff -q`.

### Task 7: Add `defer_reason` to ledger schema validator with closed-vocabulary + conditional + cross-check rules

- `depends_on: [1]`
- `touches: bin/review-ledger-schema.sh::cmd_validate`
- [ ] **Rule 1 (closed-vocabulary check)**: Insert immediately AFTER the critical-floor-blocks-ship block (CONTENT anchor: the line `_emit_incomplete "$line_no" "critical-floor-blocks-ship-violation: …` followed by its `return 49` and the closing `fi` of the `if [[ "$as_val" == "critical" && "$bs_val" != "true" ]]` conditional). Add the closed-vocabulary check from brainstorm D-005:
  ```bash
  local dr_type dr_val
  dr_type="$(jq -r '.defer_reason | type' <<<"$line" 2>/dev/null || printf 'missing')"
  if [[ "$dr_type" != "null" && "$dr_type" != "missing" ]]; then
    dr_val="$(jq -r '.defer_reason' <<<"$line" 2>/dev/null || printf '')"
    if [[ "$dr_val" != "out-of-plan-scope" && "$dr_val" != "rubric" ]]; then
      _emit_incomplete "$line_no" "defer_reason must be 'out-of-plan-scope' or 'rubric' (closed vocabulary), got '$(sanitise_for_diag "$dr_val")'" "$fck"
      return 49
    fi
  fi
  ```
  Sits INSIDE the existing `if [[ "$as_val" == "major" || "$as_val" == "critical" ]] && [[ -n "$dispatch_id_flag" && "$did_val" == "$dispatch_id_flag" ]]; then` block so schema-grace applies. Variable `dr_val` is reused by rule 6 and rule 2 below.
- [ ] **Rule 6 (matcher cross-check + fail-CLOSED on unparseable rationale)**: Insert immediately AFTER rule 1's closing `fi`. Per brainstorm D-005 rule 6:
  ```bash
  if [[ "${dr_val:-}" == "out-of-plan-scope" ]]; then
    local scr fix_target worktree_root plan body af ad
    scr="$(jq -r '.ship_classification_rationale // ""' <<<"$line" 2>/dev/null || printf '')"
    # Anchored start+end (^...$): trailing-prose forgery fails the parse.
    fix_target="$(printf '%s' "$scr" \
      | sed -nE "s/^out-of-plan-scope:[[:space:]]+([^[:space:]]+)[[:space:]]+not in plan's File Structure\$/\1/p")"
    if [[ -z "$fix_target" ]]; then
      _emit_incomplete "$line_no" "out-of-plan-scope-rationale-malformed: defer_reason=out-of-plan-scope but rationale does not match mandated shape, got '$(sanitise_for_diag "$scr")'" "$fck"
      return 49
    fi
    # shellcheck source=plan-scope.sh
    source "$SCRIPT_DIR/plan-scope.sh"
    worktree_root="$(git rev-parse --show-toplevel 2>/dev/null || printf '%s' "${TARGET_REPO-}")"
    plan="$(plan_scope::find_plan "$ident" "$worktree_root" 2>/dev/null || printf '')"
    if [[ -z "$plan" ]]; then
      log "[review-ledger-schema] cross-check: plan absent for $ident; skipping matcher verification on row $line_no" >&2
    else
      body="$(plan_scope::extract_section "$plan" 2>/dev/null || printf '')"
      af="$(plan_scope::parse_allowed_files "$body" 2>/dev/null || printf '')"
      ad="$(plan_scope::parse_allowed_dirs "$body" 2>/dev/null || printf '')"
      if plan_scope::path_in_scope "$fix_target" "$af" "$ad"; then
        _emit_incomplete "$line_no" "defer-reason-claim-disagrees-with-plan-scope: agent claimed out-of-plan-scope but matcher classifies path=$(sanitise_for_diag "$fix_target") as IN-plan" "$fck"
        return 49
      fi
    fi
  fi
  ```
- [ ] **Rule 2 (defer_reason required on this-dispatch deferred-major rows)**: Insert immediately AFTER rule 6's closing `fi`. Add:
  ```bash
  if [[ "$as_val" == "major" && "$bs_val" == "false" ]] && [[ "$dr_type" == "null" || "$dr_type" == "missing" ]]; then
    _emit_incomplete "$line_no" "defer_reason-missing-on-deferred-major: adjudicated_severity=major blocks_ship=false" "$fck"
    return 49
  fi
  ```
  The schema-grace clause already gates the outer block. Note: `bs_val` is in scope from the earlier `bs_val="$(jq -r '.blocks_ship // "MISSING"' …)"`.
- [ ] **Rule 3 (decision_factors relaxation)**: wrap the existing decision_factors-required block (CONTENT anchor: from the opening comment `# (d) decision_factors: object with all five required boolean keys.` through the closing `fi` of the `decision_factors keys must be boolean` block) in a conditional `if [[ "${dr_val:-}" != "out-of-plan-scope" ]]; then … fi`. The inner block stays UNCHANGED. The `${dr_val:-}` form suppresses unbound-variable errors under `set -u` when `dr_type == "null"` or `"missing"` (rule 1 leaves `dr_val` unset on those branches).
- [ ] **Add `"defer_reason"` to the known-fields jq allowlist**: in the jq expression (CONTENT anchor: the literal substring `"decision_factors"] | .[]'`), append `,"defer_reason"` immediately before the closing `]`. Result: `…,"decision_factors","defer_reason"] | .[]`. This silences the `_warn_unknown` for the new field on every row.
- [ ] **Optional efficiency note**: rule 6's `source "$SCRIPT_DIR/plan-scope.sh"` lives inside the per-row block — bash function-redefinition is idempotent so this is correctness-safe, but the implementer MAY hoist the source line to top-of-file (alongside the existing `source "$SCRIPT_DIR/common.sh"` line) to avoid re-executing the source on every row. Not required; either placement is acceptable.

### Task 8: Add adversarial fixtures `AC-AD-10` through `AC-AD-18` to `bin/review-ledger-schema-adversarial-test.sh`

- `depends_on: [7]`
- `touches: bin/review-ledger-schema-adversarial-test.sh`
- [ ] Add 9 fixtures per brainstorm D-005 (verbatim from §2 D-005 "Adversarial test cases"):
  - `AC-AD-10`: scope-deferred major + `decision_factors:null` + correct rationale shape + path actually out-of-plan in the fixture plan → rc=0 valid.
  - `AC-AD-11`: rubric-deferred major + `decision_factors:null` → rc=49 `decision_factors must be object` (ENG-191 rule preserved).
  - `AC-AD-12`: `defer_reason="bogus-token"` → rc=49 closed-vocabulary diagnostic.
  - `AC-AD-13`: scope-deferred major + `defer_reason` MISSING (this-dispatch row) → rc=49 `defer_reason-missing-on-deferred-major`.
  - `AC-AD-14`: critical + `blocks_ship=true` + `defer_reason="out-of-plan-scope"` → rc=0 valid (informational on critical+blocking).
  - `AC-AD-15`: scope-deferred + rationale with trailing prose (`"out-of-plan-scope: /etc/passwd not in plan but bin/setup.sh"`) → rc=49 `out-of-plan-scope-rationale-malformed` (fail-CLOSED).
  - `AC-AD-16`: scope-deferred + rationale naming a path the fixture plan DOES scope (e.g. `bin/setup.sh`) → rc=49 `defer-reason-claim-disagrees-with-plan-scope`.
  - `AC-AD-17`: scope-deferred + malformed rationale BUT `dispatch_id != --dispatch-id` (prior-dispatch row) → rc=0 valid (schema-grace).
  - `AC-AD-18`: scope-deferred + correct rationale BUT `docs/plans/` is empty (plan-absent) → rc=0 valid + stderr contains `cross-check: plan absent`.
- [ ] Each fixture constructs a tmp ledger jsonl file + a tmp worktree with the appropriate plan file (or no plan for AD-18) and invokes `bash bin/review-ledger-schema.sh validate --ident ENG-194 --dispatch-id ENG-194-d0001 <ledger>` then asserts rc + stdout/stderr substring match. Follow the existing fixture pattern in `bin/review-ledger-schema-adversarial-test.sh`.

### Task 9: Insert the "Plan-scope adjudication" block + path-D/B′ predicate updates in `AGENT_PROMPTS.md` §5

- `depends_on: [4, 7]`
- `touches: AGENT_PROMPTS.md §5`
- [ ] **New "Plan-scope adjudication" block.** Insert immediately AFTER the existing "Deferability adjudication" block's closing example paragraph (CONTENT anchor: the literal text `blocks: irreversible API surface change.` is the last line of the prior block) and BEFORE the heading paragraph starting `Count-tuple emission (MANDATORY — ENG-133 + ENG-190 + ENG-191):` (CONTENT anchor). The block MUST contain the literal phrases (pinned by Task 10's prompt-content tests):
  - heading line: `**Plan-scope adjudication (MANDATORY — ENG-194): out-of-plan-scope findings short-circuit the rubric.**`
  - `{plan_scope_allowed_paths}` token reference (rendered with two newline-separated section headers `#ALLOWED_FILES#` and `#ALLOWED_DIRS#`).
  - the exact rule: for each `adjudicated_severity ∈ {major, critical}` finding, extract the canonical fix-target file (the `path/to/file.ext:LINE` token immediately after the severity tag per the Review-comment quality rubric — trim the `:LINE`). Match against `#ALLOWED_FILES#` (exact-match) AND `#ALLOWED_DIRS#` (prefix-match). If OUT-of-plan-scope AND severity=major: set `blocks_ship=false`, set `defer_reason="out-of-plan-scope"`, set `ship_classification_rationale` to the EXACT shape `"out-of-plan-scope: <path> not in plan's File Structure"` (the `: <path>` colon-space-path tail is structurally required — validator parses it back out via anchored start+end regex), and SKIP the five-question rubric for that finding. `decision_factors` MAY be OMITTED or emitted as `null`. If OUT-of-plan-scope AND severity=critical: the critical-floor invariant UNCONDITIONALLY requires `blocks_ship=true`; the agent MAY emit `defer_reason="out-of-plan-scope"` informationally; path B (loopback) fires unchanged.
  - the multi-target finding tie-break rule: the canonical anchor (FIRST `path/to/file.ext:LINE` token after the severity tag) is the SOLE fix-target; secondary file references in the finding body are informational and NOT consulted.
  - the missing-anchor fallthrough: findings without a clear fix-target (anchor absent) fall through to the five-question rubric.
- [ ] **Path D predicate extension.** In the `Mechanical predicates` block (CONTENT anchor: `Mechanical predicates (mutually exclusive; exactly one path fires):`), replace the existing Path D bullet (CONTENT anchor: the line starting `- Path D (ship-with-debt) — fires iff` and its single backticked predicate clause that ends with `>= {review_converge_rounds}\`.`) with the extended OR predicate:
  ```
  - Path D (ship-with-debt) — fires iff
    `Adjudicated critical == 0 AND Adjudicated major > 0 AND blocking_majors == 0
     AND ( convergence_rounds_at_zero_critical >= {review_converge_rounds}
           OR  every adjudicated-major row has defer_reason == "out-of-plan-scope" )`.
  ```
- [ ] **Path B′ predicate clarification.** In the same `Mechanical predicates` block, update the existing Path B′ bullet (CONTENT anchor: the line starting `- Path B′ (convergence-waiting) — fires iff` ending with `< {review_converge_rounds}\`.`) to the implicit-complement formulation:
  ```
  - Path B′ (convergence-waiting) — fires iff
    `Adjudicated critical == 0 AND Adjudicated major > 0 AND blocking_majors == 0
     AND convergence_rounds_at_zero_critical < {review_converge_rounds}
     AND at least one adjudicated-major row has defer_reason == "rubric"`.
  ```
- [ ] **Path D verbose body update.** In the Output block's path-D paragraph (CONTENT anchor: the literal line `To ship with deferred majors (path D — Adjudicated critical=0, all adjudicated majors deferrable, convergence rounds satisfied):`), extend the parenthetical to `(path D — Adjudicated critical=0, all adjudicated majors deferrable, AND (convergence rounds satisfied OR every deferred major has defer_reason="out-of-plan-scope"))` for consistency with the predicate.
- [ ] **Output block ledger-row instruction.** In the Output block's ledger-row-emission paragraph (CONTENT anchor: the literal substring `"decision_factors": {` introducing the ENG-191 decision_factors documentation), add the literal sentence — placed AFTER the `decision_factors` object documentation and BEFORE the next field instruction — `For blocks_ship=false major rows you MUST also emit "defer_reason": "out-of-plan-scope" or "rubric". When defer_reason is "out-of-plan-scope", decision_factors MAY be OMITTED or emitted as null.` Both the literal substrings `OMITTED` and `null` appear in this sentence (pinned by Task 10 pin #4).
- [ ] Schema discipline: no new column-0 ``` fence added; no new `## ` heading added; the block sits INSIDE §5's existing fenced body. `bin/render-prompt.sh::extract_block`'s fence-count == 2 invariant holds.

### Task 10: Add seven prompt-content pins to `bin/agent-prompts-content-test.sh`

- `depends_on: [9]`
- `touches: bin/agent-prompts-content-test.sh`
- [ ] Pin #1: §5 contains the literal phrase `Plan-scope adjudication`.
- [ ] Pin #2: §5 contains the literal token `{plan_scope_allowed_paths}`.
- [ ] Pin #3: §5 contains the literal phrase `defer_reason="out-of-plan-scope"`.
- [ ] Pin #4: §5 contains BOTH literal substrings `OMITTED` and `null` (the decision_factors relaxation rule).
- [ ] Pin #5: §5 contains the literal substring `OR  every adjudicated-major row has defer_reason == "out-of-plan-scope"` (the extended OR clause in the path-D predicate; double-space matches the brainstorm's quoted shape).
- [ ] Pin #6: positional check — extract §5 body via the section-header awk-extractor; assert the line number of `Plan-scope adjudication` is LESS than the line number of `Findings:` (count-tuple heading) within §5.
- [ ] Pin #7: §5 contains the multi-target finding rule — assert the literal substrings `canonical anchor` AND `SOLE fix-target` (case-sensitive) both appear in §5's body.
- [ ] Each pin uses `grep -F` (literal substring) over the AGENT_PROMPTS.md §5 body extracted via the existing test helper (whatever section-extractor the file uses); follow the existing pin pattern at HEAD post-rebase.
- [ ] **MANDATORY — relax pre-existing `ENG-191-pin-path-d-predicate` pin.** Locate the existing pin (CONTENT anchor: the line `# ENG-191-pin-path-d-predicate: literal path-D mechanical predicate.`). The current `grep -qF 'Adjudicated critical == 0 AND Adjudicated major > 0 AND blocking_majors == 0 AND convergence_rounds_at_zero_critical >= {review_converge_rounds}'` asserts the OLD one-line literal — Task 9 splits the predicate across multiple lines (`AND ( convergence_rounds_at_zero_critical >= …` on a new line), which breaks this `grep -qF` flat-string match. Replace the single-line `grep -qF` invocation with TWO assertions that survive the multi-line shape: (a) the un-broken prefix substring `Adjudicated critical == 0 AND Adjudicated major > 0 AND blocking_majors == 0` (still present verbatim in the new shape's first line); (b) the suffix substring `convergence_rounds_at_zero_critical >= {review_converge_rounds}` (still present verbatim on the new shape's second line). Combine with `&&` like the existing `ENG-191-pin-five-question-rubric` pattern (lines 1010-1014). Keep the pin's `ok`/`nope` labelling intact for retrospective traceability. This step is the remove-side test-gate closure for the path-D predicate reshape.

### Task 11: Add AC #1, AC #3, AC #5 fixtures to `bin/run-stage-test.sh`

- `depends_on: [7]`
- `touches: bin/run-stage-test.sh::T_AC1_scope_deferred_in_comment, ::T_AC3_inplan_unchanged, ::T_AC5_eng27_e2e`
- [ ] **AC #1 fixture**: construct a fixture issue dir + ledger with one this-dispatch row `{"adjudicated_severity":"major","blocks_ship":false,"defer_reason":"out-of-plan-scope","ship_classification_rationale":"out-of-plan-scope: docs/install.md not in plan's File Structure","decision_factors":null,…}` + a fixture verdict marker with `reason=ship-with-deferred-majors`. Source `bin/run-stage.sh` (stubs in place); invoke `_post_deferred_majors_comment_if_eligible <ident>`. Assert the post body contains a bullet referencing `docs/install.md` (AC #2 — the row appears in the comment, not silently dropped). The `defer_reason` is NOT required to be visible in the rendered comment body in v1 — the assertion is the bullet's presence.
- [ ] **AC #3 fixture**: construct a fixture ledger with one this-dispatch row `{"adjudicated_severity":"major","blocks_ship":false,"defer_reason":"rubric","decision_factors":{"in_changed_code":true,"is_regression":false,"user_visible":true,"reversible_post_ship":true,"has_workaround":true},…}`. Invoke `_post_deferred_majors_comment_if_eligible`. Assert the bullet renders WITH the five decision factors visible (regression check — ENG-191 D-005 behaviour preserved on rubric-deferred rows).
- [ ] **AC #5 fixture** (ENG-27-class end-to-end): construct a fixture worktree with `docs/plans/2026-06-16-eng-27-foo.md` (frontmatter `linear: ENG-27`) scoping ONLY `bin/setup.sh` in its `## File Structure`. Construct a fixture branch diff modifying ONLY `bin/setup.sh`. Construct a synthesised ledger row with the scope-deferred `docs/install.md` finding. Invoke the validator `bash bin/review-ledger-schema.sh validate --ident ENG-27 --dispatch-id ENG-27-d0001 <ledger>` — assert rc=0 (the matcher cross-check passes because `docs/install.md` is genuinely out-of-plan). Then invoke `_post_deferred_majors_comment_if_eligible ENG-27` — assert the resulting body contains the `docs/install.md` bullet. The decision-path arithmetic (path D fires) is asserted via the count-tuple line shape NOT runtime; prompt-content tests in Task 10 cover the prompt rules.

### Task 12: Append `docs/runbooks/recovery.md` §14 "Scope-deferred majors (ENG-194)"

- `depends_on: []`
- `touches: docs/runbooks/recovery.md::§14`
- [ ] Append a `## 14. Scope-deferred majors (ENG-194)` H2 after the existing §13. Body: 4 paragraphs.
  - (1) **v1 visual limitation.** State explicitly that the deferred-majors Linear comment renders scope-deferred bullets and rubric-deferred bullets as a single flat list — they are NOT visually distinguished in the comment body in v1. The distinction lives in the ledger row's `defer_reason` field. (Grouping by `defer_reason` is ENG-194-A follow-up.)
  - (2) **Audit recipe.** `jq -r 'select(.defer_reason == "out-of-plan-scope") | "\(.finding_class_key)\t\(.ship_classification_rationale)"' $(issue_dir <ident>)/review-findings-ledger.jsonl` lists the scope-deferred rows and their named fix-target paths.
  - (3) **Plan-amend path.** If the operator concludes the plan SHOULD have scoped the file → amend `docs/plans/<plan>.md`'s `## File Structure` to add it, commit, then `bash bin/pipeline.sh decide <ENG-N> --action continue` to let the next dispatch re-evaluate.
  - (4) **No-action path.** If the operator concludes the finding is bogus → no action needed; the deferred-majors comment names the row and ENG-193 has filed (or will file) the follow-up ticket. Note the critical+out-of-plan residual: critical findings still loop back per the critical-floor invariant and halt with `scope-violation`; recovery follows §7 (scope-violation) — and observe the ENG-180 caveat (scope-approval-resume is broken; force-transition may be required until ENG-180 ships).

### Task 13: Extend `CLAUDE.md`'s failure-mode quick reference

- `depends_on: []`
- `touches: CLAUDE.md (Failure-mode quick reference table — ENG-191 deferred-majors row)`
- [ ] Locate the row whose Symptom column starts with the literal substring `Issue at stage:qa with verdict comment reason=ship-with-deferred-majors and a fresh deferred-majors/<ENG-N> Linear comment` (CONTENT anchor — ENG-191 row added in CLAUDE.md). Append to the same row's `Where to look` cell ONE additional sentence: `ENG-194: rows whose defer_reason="out-of-plan-scope" name a path NOT in the plan's File Structure — the reviewer auto-deferred rather than looping back; the deferred-majors comment renders both kinds as a flat list (use jq on the ledger to distinguish). Critical findings whose fix-target is out-of-plan still loop back (critical-floor invariant) and surface as a scope-violation halt — recovery follows the scope-violation row in this table, with the ENG-180 caveat that decide --action approve --gate scope is currently broken. See docs/runbooks/recovery.md §14.` Do NOT add a new row; do NOT renumber the table.

## Frontend Tasks

No UI / frontend work — the harness has no FE. Skip the UI agent dispatch entirely.

## Failure Mode → Test Map

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
|---|---|---|---|---|
| Major finding fix-target out-of-plan | reviewer extracts canonical anchor, matches against `{plan_scope_allowed_paths}` → out | auto-classify `blocks_ship=false defer_reason="out-of-plan-scope"`, skip rubric, emit anchored rationale | unit | `bin/agent-prompts-content-test.sh::Pin_3_4_7` (prompt rule) + `bin/review-ledger-schema-adversarial-test.sh::AC-AD-10` (validator accept) |
| Major finding fix-target in-plan | matcher → in | rubric runs unchanged, `decision_factors` required | unit | `bin/review-ledger-schema-adversarial-test.sh::AC-AD-11` (rubric+null decision_factors → rc=49) |
| Critical finding fix-target out-of-plan | critical-floor invariant | `blocks_ship=true` unconditional; agent MAY emit `defer_reason="out-of-plan-scope"` informationally; path B fires; implementer attempts; scope-check halts; operator triages | unit | `bin/review-ledger-schema-adversarial-test.sh::AC-AD-14` (critical+blocks_ship=true+defer_reason=oops valid) |
| Reviewer fakes `defer_reason="out-of-plan-scope"` on an in-plan path | adversarial bypass attempt | validator's rule 6 cross-check disagrees with matcher → rc=49 `defer-reason-claim-disagrees-with-plan-scope` | unit | `bin/review-ledger-schema-adversarial-test.sh::AC-AD-16` |
| Agent emits `defer_reason="out-of-plan-scope"` with malformed rationale | trailing-prose forgery, missing tail | rule 6 fail-CLOSED on anchored regex → rc=49 `out-of-plan-scope-rationale-malformed` | unit | `bin/review-ledger-schema-adversarial-test.sh::AC-AD-15` |
| Agent emits unknown `defer_reason` value | typo / drift (`"out-of-scope"` instead of `"out-of-plan-scope"`) | rule 1 closed-vocabulary check → rc=49 with sanitised diagnostic naming the bad value | unit | `bin/review-ledger-schema-adversarial-test.sh::AC-AD-12` |
| Agent omits `defer_reason` on a `blocks_ship=false` major this-dispatch row | rule 2 firing | rc=49 `defer_reason-missing-on-deferred-major` | unit | `bin/review-ledger-schema-adversarial-test.sh::AC-AD-13` |
| Prior-dispatch row missing `defer_reason` | schema-grace clause | rc=0 valid (the new rules gate on `dispatch_id == --dispatch-id`) | unit | `bin/review-ledger-schema-adversarial-test.sh::AC-AD-17` |
| Plan deleted mid-dispatch / no `docs/plans/` entry | resolver soft-fail | resolver emits empty `#ALLOWED_FILES#` + `#ALLOWED_DIRS#` headers + stderr warning; validator rule 6 skips cross-check with `cross-check: plan absent` log; row PASSES | unit | `bin/render-prompt-test.sh::T_plan_scope_allowed_paths_render` (soft-fail case) + `bin/review-ledger-schema-adversarial-test.sh::AC-AD-18` |
| Render-time unknown token (`{plan_scope_allowed_paths}` not registered) | regression check — registry forgotten | render-prompt dies with `unknown token 'plan_scope_allowed_paths'` | unit | `bin/render-prompt-test.sh::T_resolver_registered` (positive assertion the registration exists) |
| Reviewer-defer ≠ scope-check parse | byte-divergence regression | parse outputs disagree | unit | `bin/plan-scope-test.sh::test_5_cross_caller_byte_for_byte` |
| ENG-27-class E2E (in-plan setup.sh + out-of-plan install.md flagged) | the live incident | scope-deferred bullet in deferred-majors comment; path D fires at iter 1 | integration | `bin/run-stage-test.sh::T_AC5_eng27_e2e` |
| Out-of-plan major appears in deferred-majors comment | AC #2 satisfaction | bullet referencing the path is present in the rendered post body | integration | `bin/run-stage-test.sh::T_AC1_scope_deferred_in_comment` |
| In-plan rubric-deferred major still renders five decision factors | regression — ENG-191 behaviour preserved | bullet contains the five factor keys | integration | `bin/run-stage-test.sh::T_AC3_inplan_unchanged` |
| `bin/scope-check.sh` and `bin/plan-scope.sh` ship without the source-line wire-up | implementation slip | `declare -f plan_scope::path_in_scope` after sourcing scope-check.sh fails | unit | `bin/scope-check-test.sh::T_plan_scope_helper_sourced` |
| Reviewer mis-classifies an OUT-of-plan finding as IN-plan (and applies the rubric) | agent-side judgment slip — the matcher's prompt-side check would have to be ignored | downstream implement-stage scope-check.sh halts when the agent touches the out-of-plan file; the original catch-22 returns for this one finding | (none — accepted v1 risk) | (no test — structural defense is the prompt-side `{plan_scope_allowed_paths}` token rendering plus Task 10 pin #2 confirming the token reaches §5; brainstorm §5 "Halt cases" explicitly documents this as not-validator-detectable in v1; tighter coverage requires a transcript-based check deferred to ENG-194-D follow-up) |

## Test Strategy

**Unit layer.**

- `bin/plan-scope-test.sh` (NEW) — five tests pinning the helper's parse + match contract and the AC #4 byte-for-byte cross-caller assertion. Sourceable via the standard CLAUDE.md "Tests" source-and-stub idiom.
- `bin/scope-check-test.sh` (EXTENDED) — all existing fixtures pass UNCHANGED (the refactor is behaviour-preserving). One new test asserts the helper is sourced AND the benign-path-class array is untouched.
- `bin/review-ledger-schema-adversarial-test.sh` (EXTENDED) — nine new fixtures `AC-AD-10` through `AC-AD-18` covering closed-vocabulary, missing field, schema-grace exemption, critical informational case, fail-CLOSED on malformed rationale, matcher disagreement, plan-absent soft-fail.
- `bin/agent-prompts-content-test.sh` (EXTENDED) — seven literal-string pins on §5 covering the new block heading, the resolver token, the `defer_reason` literal, the OMITTED+null decision_factors relaxation phrase, the extended OR clause, the positional ordering (block before count-tuple), and the canonical-anchor tie-break.
- `bin/render-prompt-test.sh` (EXTENDED) — three fixtures: token registered, rendered payload shape, soft-fail on plan-absent.

**Integration layer.**

- `bin/run-stage-test.sh` (EXTENDED) — three end-to-end fixtures binding the orchestrator-side comment post + validator gating to AC #1 / AC #3 / AC #5. Heavily mocked per ENG-191 D-008 prior art — the agent's in-prompt arithmetic is asserted via the count-tuple line shape and verdict marker shape, not by running `claude -p`.

**Smoke layer.**

- `bash bin/secret-probe-lint.sh` + `bash -n bin/*.sh` after every edit (covered by `init.sh` and the pre-commit hook). `bash bin/plan-scope.sh path-in-scope bin/setup.sh "bin/setup.sh" ""` is the sentinel CLI smoke for the new helper.

**Adversarial layer.**

- All `AC-AD-*` fixtures listed above target forge surfaces: malformed rationale, mismatched matcher, bogus defer_reason values. Rule 6's fail-CLOSED design and the anchored start+end regex are the structural defenses; AC-AD-15 and AC-AD-16 are the witness tests.
- The orthogonal plan-mutation attack (reviewer edits `docs/plans/<plan>.md` mid-dispatch to fake an in-plan path) is documented as bounded v1 weakness in brainstorm §6 Edge case 17 and deferred to ENG-194-D — NOT covered by this plan's tests.

**Test-gate closure sweeps.**

- **Remove-side.** This plan does not REMOVE any token from production code, but Task 9's Path D + Path B′ predicate edits RESHAPE the existing single-line backticked predicates into multi-line backticked predicates (adding the OR clause for path D, the AND-defer-reason-rubric clause for path B′). One sibling test pins the OLD single-line literal verbatim: `bin/agent-prompts-content-test.sh::ENG-191-pin-path-d-predicate` (line ~1031). The remove-side closure is delivered by Task 10's MANDATORY bullet which splits the single `grep -qF` flat-string match into a prefix+suffix `grep -F && grep -F` shape that survives the multi-line reshape. `bin/agent-prompts-content-test.sh` is in File Structure as MODIFIED for this reason in addition to the seven new pins.
- **Add-side.** This plan ADDS `bin/plan-scope.sh` and `bin/plan-scope-test.sh` under the harness's `bin/*-test.sh` gate-runnable glob. Per assumption 29 + assumption 30, the existing `bash .githooks/pre-commit` Test command in `learned-rules/harness/project-profile.md::"## Build & test gates"` globs `bin/*-test.sh` literally — the new test file is picked up without a profile edit. The profile file is named in File Structure under "REVIEW ONLY" precisely so this sweep finds it; no implementation task touches it.
- **System invariants resolution.** Each `verified_by:` token in `## System invariants` resolves: `task:T3`, `task:T5`, `task:T6`, `task:T8` (multiple) cite tasks present in the plan with `touches:` fields naming gate-runnable test files (`bin/plan-scope-test.sh`, `bin/scope-check-test.sh`, `bin/render-prompt-test.sh`, `bin/review-ledger-schema-adversarial-test.sh`).
