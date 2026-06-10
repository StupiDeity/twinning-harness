---
linear: ENG-119
date: 2026-06-09
topic: Dimensional grading — review-stage emits structured per-dimension verdict payload + post-dispatch validator + tests
---

# Plan — Dimensional grading: review-stage payload (ENG-119)

## Anti-anchoring check

- **Problem (operator-perspective):** "Today the review agent collapses a multi-dimension assessment (correctness, testing, maintainability, scope, plus conditional security/perf/api-contract/premise) into a single `verdict pass|fail` bit. The umbrella ticket (ENG-31) wants per-dimension scores persisted alongside the verdict so future threshold logic (ENG-118), retrospective signal, and operator triage can read structured findings rather than scraping prose."
- **Brainstorm framing:** matches the problem one-for-one. The solution emits `$issue_dir/verdict-review.json` with per-dimension `score`/`rationale`/`thresholds_met[]`/`thresholds_missed[]`, adds a post-dispatch validator that halts on missing/malformed payload, and exposes a `{verdict_review_path}` token in `AGENT_PROMPTS.md` §5. No reader (threshold gating deferred to ENG-118; retrospective surface picks up the new file naturally). No threshold logic shipped.
- **Proportionality:** one new validator script (`bin/review-payload-schema.sh`), one new sibling test (`bin/review-payload-schema-test.sh`), one new validator function pair (`_validate_review_payload` + `_post_review_payload_halt`) wired into `bin/run-stage.sh`'s existing post-dispatch detective block (next to `_validate_plan_contract`), three new exit codes (36/37/38 — the next free slots after 33/34/35), one new halt-reason token (`review-payload-invalid`), one new `{verdict_review_path}` prompt resolver, one new `## 11. Resume from review-payload-invalid halt` runbook section, project-profile updates for the test-gate closure. ≤ 5 new functions in production code. Mirrors ENG-122 verbatim. Proportional. Proceed.

## Goal

Every review-stage dispatch MUST produce `$(issue_dir <ident>)/verdict-review.json` with `review_schema_version: 1`, top-level `issue_id` + `dispatch_id` + `sha` + `verdict` + a `dimensions{}` object covering at minimum the four required dimensions (correctness, testing, maintainability, scope); a post-dispatch validator (`bin/run-stage.sh::_validate_review_payload`, gated to `stage=reviewing`) shells out to a new `bin/review-payload-schema.sh validate` CLI and halts the dispatch with halt-reason `review-payload-invalid` (exit codes 36 = malformed, 37 = incomplete, 38 = missing-file) on any structural defect — so that structured per-dimension findings become a durable contract that downstream sub-tickets (ENG-118 threshold gating, retrospective) can read deterministically.

## Assumption Inventory

Format: `[verified|assumed]` ITEM — `path:line` reference.

**branch-base freshness:** `git log --oneline HEAD..origin/main` is NON-EMPTY at plan time (the branch is ~50+ commits behind `origin/main` — ENG-120, ENG-122, ENG-124, ENG-129, ENG-136, ENG-140, ENG-146, ENG-155, ENG-161 and others have landed since the branch was cut). Several materially touch files this plan will edit: `bin/dispatch.sh` (ENG-155 added `--add-dir` splice and D-003 orchestrator-owned-file detective loop), `bin/common.sh` (ENG-155 added `assert_no_tool_with_input_path`), `bin/run-stage.sh` (ENG-146 strip-not-delete issue-state), `bin/render-prompt.sh` (ENG-124 added `_resolve_plan_json` resolver), `AGENT_PROMPTS.md` (ENG-120 §3 iteration-loop directive, ENG-155 §3+§4 staging discipline, ENG-110 envelope-validator preamble, ENG-136 §3 minor-defer hoist, ENG-140 QA-loopback handling). None of these upstream commits inverts a fact this plan relies on; they all add ENG-119-neutral content at line offsets ABOVE the insertion points in this plan. **Task 0** rebases onto `origin/main` before any other implement work and re-verifies the `path:line` excerpts below. Pin: at plan time, `path:line` references are anchored against this branch's tip (`79357a7`); after rebase the absolute line numbers will shift but every Edit boundary in this plan uses CONTENT anchors (function names, header strings, unique substrings) so the rebase is harmless. Drift is **clean** — no sibling ticket touches `bin/review-payload-schema.sh` (does not exist yet), `bin/run-stage.sh::_validate_plan_contract` block (the immediate predecessor `_validate_review_payload` will live next to), or `AGENT_PROMPTS.md` §5 Output bullets in ways that materially conflict.

### Verified — code paths quoted from current tree

- `[verified]` `bin/run-stage.sh:931-939` — `_clear_current_stage_slots()` body. Today it removes `$d/stage-summary-${stage}.md` and `$d/wait-${stage}.json` for the current stage. Insertion point for D-008 pre-clean: a third `rm -f` line for `$d/verdict-review.json`, gated to `stage == reviewing`. Content anchor: the line `rm -f "$d/wait-${stage}.json"        2>/dev/null || true` is unique in the file.
- `[verified]` `bin/run-stage.sh:966-1030` — `_validate_dispatch_envelope()` function (ENG-87 detective). Sets the precedent for the `_validate_review_payload` shape: `local PIPELINE_WRITER=orchestrator; export PIPELINE_WRITER` preamble, `[[ -s "$sidecar" ]] || return 0` fail-open guard, single-purpose violation classification, `return 29` on hit. Content anchor: the line `_validate_dispatch_envelope() {` is unique.
- `[verified]` `bin/run-stage.sh:1036-1072` — `_validate_plan_contract()` function (ENG-122 detective). Exact precedent for `_validate_review_payload` shape: shell out to validator subcommand, case on rc, call sibling `_post_*_halt`. Content anchor: the line `_validate_plan_contract() {` is unique.
- `[verified]` `bin/run-stage.sh:1077-1084` — `_post_plan_contract_halt()` function. Precedent for `_post_review_payload_halt`: `${raw//<!--/<\\!--}` sanitisation, tilde-fenced `printf` body, `bash "$SCRIPT_DIR/linear.sh" add-comment "$ident" "$body"` posting. Content anchor: the line `_post_plan_contract_halt() {` is unique.
- `[verified]` `bin/run-stage.sh:1797-1817` — envelope-validator caller arm in `main()`'s post-dispatch hook block. Wraps the call in `if (( ! skip_dispatch )); then case "$stage" in brainstorming|planning|implementing|ui|reviewing|qa|building) ... esac; fi`. Content anchor: the line `_validate_dispatch_envelope "$ident" "$stage" || _env_rc=$?` is unique.
- `[verified]` `bin/run-stage.sh:1819-1835` — plan-contract validator caller arm. Wraps `_validate_plan_contract "$ident" || _plan_rc=$?` in `if (( ! skip_dispatch )); then case "$stage" in planning) ... esac; fi`. The new `_validate_review_payload` arm slots IMMEDIATELY AFTER this block. Content anchor: the line `_validate_plan_contract "$ident" || _plan_rc=$?` is unique.
- `[verified]` `bin/run-stage.sh:1837-1845` — `push_branch_if_ahead` block (post-dispatch sequence anchor). The new review-payload validator arm goes BEFORE this block. Content anchor: the comment `# Push branch BEFORE posting the completion comment so any...` is unique.
- `[verified]` `bin/run-stage.sh:1321` — call site for `_clear_current_stage_slots "$ident" "$stage"` inside `main()`'s dispatch-start sequence. Unchanged by this plan — the pre-clean addition is local to `_clear_current_stage_slots`'s body, not its caller.
- `[verified]` `bin/common.sh:247-279` — `failure_outcome_for_exit()` case statement. Exit codes 10–35 and 124 are mapped today; 32 is intentionally skipped (flat-namespace allocation, no callers); 36/37/38 are the next free contiguous slots. Insertion point: AFTER `35) printf 'plan-contract-missing' ;;` and BEFORE `124) printf 'dispatch-timeout' ;;`. Content anchor: the line `35) printf 'plan-contract-missing' ;;` is unique.
- `[verified]` `bin/pipeline-events.json:10-21` — `halt_reasons` array. Currently 10 entries ending with `"plan-contract-invalid"` on line 20. New entry `"review-payload-invalid"` appended as the 11th. Content anchor: the literal `"plan-contract-invalid"` is unique in the file. **Rebase note:** ENG-112 (`feat(ENG-112): ledger schema in pipeline-events.json`) extended this file on `origin/main` with a new `meta_kinds` entry (`breadcrumb`) and an `events` object. The `halt_reasons` array shape is unchanged on main; the same `"plan-contract-invalid"` content anchor applies post-rebase. Trailing-comma discipline preserved.
- `[verified]` `bin/render-prompt.sh:41-57` — `PROMPT_RESOLVERS` registry. Today registers `issue_id, issue_id_lower, issue_title, issue_description, date, slug, brainstorm_file, plan_file, branch_name, stage_summary_path, learned_rules_dir, dispatch_id, review_findings, progress_md_path, plan_json`. New entry `verdict_review_path=_resolve_verdict_review_path` slots after `plan_json` (the last entry). Content anchor: the line `plan_json=_resolve_plan_json` is unique.
- `[verified]` `bin/render-prompt.sh:228` — `_resolve_stage_summary_path() { printf '%s' "$_RENDER_STAGE_SUMMARY_PATH"; }`. Precedent for `_resolve_verdict_review_path()`'s one-line shape. Content anchor: the literal function definition line is unique.
- `[verified]` `bin/render-prompt.sh:237` — `_resolve_dispatch_id() { printf '%s' "${_RENDER_DISPATCH_ID-}"; }`. Confirms the resolver registry shape extends naturally. Content anchor: the literal line is unique.
- `[verified]` `bin/render-prompt.sh:484-485` — `_RENDER_STAGE_SUMMARY_PATH="$stage_summary_path"` and `_RENDER_PROGRESS_MD_PATH="$progress_md_path"` bindings inside `main()`. New `_RENDER_VERDICT_REVIEW_PATH="$(issue_dir "$issue_id")/verdict-review.json"` binding slots adjacent. Content anchor: the line `_RENDER_STAGE_SUMMARY_PATH="$stage_summary_path"` is unique.
- `[verified]` `bin/linear.sh:60-77` — `_inject_dispatch_marker()` chokepoint. Auto-injects `<!-- meta: dispatch id=... stage=... -->` when `PIPELINE_DISPATCH_ID` is set. Idempotent. Confirms the halt-comment body posted by `_post_review_payload_halt` will carry the dispatch marker automatically — no agent-side or detective-side marker emission needed.
- `[verified]` `bin/linear.sh:496-514` — `add_comment()` calls `_inject_dispatch_marker` (line 514) before posting. The detective's halt body MUST go through `add-comment` (NOT `add-or-update-comment`) so the marker is append-only per CLAUDE.md "Verdict-marker protocol" — mirrors ENG-122 `_post_plan_contract_halt`.
- `[verified]` `bin/plan-schema.sh:1-298` — ENG-122 validator template. Headers comment carries canonical schema; `main()` dispatches `validate` subcommand; `cmd_validate` parses positional + `--ident` flag, returns 0 / 33 / 34 / 35. Sentinel at line 297: `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi`. `bin/review-payload-schema.sh` mirrors this structure exactly with three changes: (a) accepts an additional `--dispatch-id` flag, (b) validates `verdict` enum + `dimensions` object shape, (c) returns 36/37/38.
- `[verified]` `bin/plan-schema-test.sh` — exists; sibling test for `bin/plan-schema.sh` using the source-and-stub pattern (sentinel-gated `main`, `STUB_DIR`-based linear.sh stub). Precedent for `bin/review-payload-schema-test.sh`.
- `[verified]` `bin/common.sh::issue_dir` — referenced in CLAUDE.md "Per-issue state directory" and `export -f issue_dir compute_pipeline_content_hash failure_outcome_for_exit ...` at `bin/common.sh:433`. Confirms `issue_dir` is available in `bin/render-prompt.sh` (sources `common.sh`) and `bin/run-stage.sh` (sources `common.sh`). Resolves to `$PROJECT_STATE_DIR/<ident>/`.
- `[verified]` `AGENT_PROMPTS.md:1064` — `## 5. Review Agent` H2 header. Section runs 1064-1320. Fenced block at line 1066 (` ``` `) opens the body. Content anchor: the H2 header line itself is unique.
- `[verified]` `AGENT_PROMPTS.md:1265-1294` — review-stage `Output:` bullet list. Bullets enumerate per-finding PR review comments, Linear consolidated review summary, stage-summary file at `{stage_summary_path}`, verdict per Decision path, append-progress.md. New bullet for `verdict-review.json` write slots AFTER the stage-summary bullet (line 1280 closing) and BEFORE the verdict bullet (line 1281 `- Verdict per Decision path ...`). Content anchor: the line `- Stage-summary file at {stage_summary_path} (per the Stage` is unique.
- `[verified]` `AGENT_PROMPTS.md:1214-1255` — Decision paths A/B/C body. New "Dimension scoring" guidance (the per-dimension rubric + example payload) slots IMMEDIATELY BEFORE `Decision path (apply exactly one):` at line 1214, so the agent reads it before invoking the path-specific writers. Content anchor: the line `Decision path (apply exactly one):` is unique.
- `[verified]` `bin/run-local-helpers.sh:508-510` — `stage_output_paths` returns empty for `reviewing|building|released`. Confirms `verdict-review.json` written OUTSIDE the worktree (at `$issue_dir/`) does NOT enter the scope sweep — it's per-issue state, not worktree dirty path. Mirrors D-001.
- `[verified]` `learned-rules/harness/project-profile.md:14-19` — `## Build & test gates` Test command currently enumerates `bin/dispatch-test.sh && bin/run-stage-test.sh && ... && bin/common-test.sh`. New `&& bash bin/review-payload-schema-test.sh` appended to the end of the chain. Content anchor: the literal `bash bin/common-test.sh` at end of the test command line is unique.
- `[verified]` `learned-rules/harness/project-profile.md:21-118` — `## Tool allowlist` section. `implementing:` and `qa:` arms enumerate every `Bash(bash bin/<file>-test.sh:*)` pattern explicitly (per CLAUDE.md "Wildcard pitfall"). New entry `Bash(bash bin/review-payload-schema-test.sh:*)` added to BOTH the `implementing:` arm (insertion point: alphabetically between `Bash(bash bin/render-prompt-test.sh:*)` and `Bash(bash bin/review-poll-test.sh:*)`) AND the `qa:` arm (same alphabetic position). Content anchor: the lines `- \`Bash(bash bin/render-prompt-test.sh:*)\`` (twice — once per arm) are unique within their respective arms.
- `[verified]` `docs/runbooks/recovery.md:1-722` — runbook with 10 numbered H2 sections ending at `## 10. rc=31 — \`progress-md-entry-missing\` (plan-stage progress.md detective halt)` (line 635). New `## 11. rc=36/37/38 — \`review-payload-invalid\` (review-stage payload detective halt)` section appended AFTER `## 10` body and BEFORE the `## Quick reference: env var requirement` block (line 688). Content anchor: the literal H2 line `## 10. rc=31 — \`progress-md-entry-missing\` ...` is unique.

### Verified — file/dir existence and absence

- `[verified]` `bin/review-payload-schema.sh` — DOES NOT EXIST at HEAD (`ls bin/review-payload-schema*` returns no matches). New file per D-003.
- `[verified]` `bin/review-payload-schema-test.sh` — DOES NOT EXIST at HEAD. New file per architecture's "tests/fixtures" subsystem.
- `[verified]` `bin/plan-schema.sh` and `bin/plan-schema-test.sh` — EXIST. Template + test precedent.
- `[verified]` `docs/runbooks/recovery.md` — EXISTS. Has no current `plan-contract-invalid` section (ENG-122 deferred the runbook update); this ticket establishes the `review-payload-invalid` precedent and operators can backfill the plan-contract entry later if desired (NOT in scope for ENG-119).

### Verified — runtime / dependency

- `[verified]` `jq` is a required runtime tool per the project profile Stack section. `require_bin jq` already runs in every dispatch path. `bin/review-payload-schema.sh` relies on jq being present without an additional preflight (same as `bin/plan-schema.sh`).

### Assumed — to be verified during implement

- `[assumed]` The agent will produce the JSON via the `Write` tool inside the reviewing dispatch. `Write` is in the stage-agnostic core tools per the project profile preamble — no new allowlist entry needed.
- `[assumed]` `classify_failure "$ident" "$stage" "skip-until-human-acts" "..." 36/37/38` applies `pipeline:halted` via the orchestrator's classify-failure pipeline (consistent with the exit-29 envelope-violation and exit-33/34/35 plan-contract sites). Verify against `bin/classify-failure.sh::classify_failure` during implement; if the policy hand-off is materially different for 36/37/38, the implement agent posts a Linear comment and treats it as a P0 implement defect rather than silently working around it.
- `[assumed]` `bin/poll.sh::_poll_classify_labels` already routes `pipeline:halted` + `pipeline:skip-until-human-acts` into the `slot:"vacate", operator_action_required:true` branch (CLAUDE.md "Slot-occupancy contract"). Adding a new halt-reason token does not require a new classifier branch — verified at the design level in the brainstorm's §9 ADR stress test.
- `[assumed]` The retrospective agent reads `$issue_dir/*.json` shapes generically (no per-file plumbing for `usage-*.json` / `wait-*.json`). Brainstorm §11 row #13. Not blocking; the file lands at the canonical location either way.

## File Structure

### Modified

- `bin/run-stage.sh` — (a) extend `_clear_current_stage_slots()` to `rm -f` `$d/verdict-review.json` when `stage == reviewing`; (b) add `_validate_review_payload()` + `_post_review_payload_halt()` mirroring the ENG-122 plan-contract pair (insertion point: AFTER `_post_plan_contract_halt`'s closing brace, BEFORE the `# ENG-87 review M1+M2: dispatch_history.jsonl end-row trap.` block-comment); (c) add a new `case "$stage" in reviewing) ... esac` arm in `main()`'s post-dispatch hook section, IMMEDIATELY AFTER the plan-contract arm (`# ENG-122: plan-contract validator. ... esac; fi` block ending ~line 1835) and BEFORE the `# Push branch BEFORE posting the completion comment ...` block.
- `bin/common.sh` — extend `failure_outcome_for_exit`'s case statement with 36/37/38 → `review-payload-malformed | review-payload-incomplete | review-payload-missing` outcome tokens (insertion point: AFTER `35) printf 'plan-contract-missing' ;;`, BEFORE `124) printf 'dispatch-timeout' ;;`).
- `bin/pipeline-events.json` — append `"review-payload-invalid"` to the `halt_reasons` array (insertion: AFTER the `"plan-contract-invalid"` element, preserving JSON trailing-comma discipline). Run `bash bin/generate-vocabulary-doc.sh` to regenerate `docs/pipeline-vocabulary.md`.
- `bin/render-prompt.sh` — (a) register `verdict_review_path=_resolve_verdict_review_path` in `PROMPT_RESOLVERS` (insertion: AFTER `plan_json=_resolve_plan_json` on line 56, BEFORE the closing `'` on line 57); (b) define `_resolve_verdict_review_path() { printf '%s' "$_RENDER_VERDICT_REVIEW_PATH"; }` (insertion: ADJACENT to `_resolve_stage_summary_path` at line 228); (c) bind `_RENDER_VERDICT_REVIEW_PATH="$(issue_dir "$issue_id")/verdict-review.json"` in `main()` (insertion: ADJACENT to the existing `_RENDER_STAGE_SUMMARY_PATH="$stage_summary_path"` binding at line 484).
- `AGENT_PROMPTS.md` — extend §5 Review Agent with: (a) new "Dimension scoring" subsection in the prompt body (insertion: IMMEDIATELY BEFORE `Decision path (apply exactly one):` at line 1214) explaining the four required dimensions, the three-state score rubric (`pass`/`concern`/`fail`), the four conditional dimensions, the relationship between score and the existing severity ladder (`critical`/`major`/`minor`/`nit`), and an example payload block; (b) new Output bullet for `Write {verdict_review_path}` (insertion: IMMEDIATELY AFTER the `Stage-summary file at {stage_summary_path} ...` bullet ending around line 1280, BEFORE the `- Verdict per Decision path ...` bullet). No new H2 sections; no nested fences.
- `bin/run-stage-test.sh` — append a new test group (ENG-119 X1-X6) after the ENG-122 test group, covering integration tests: (X1) reviewing-stage dispatch with valid payload passes; (X2) missing payload halts with rc=38; (X3) malformed JSON halts with rc=36; (X4) `dispatch_id` mismatch halts with rc=37; (X5) `--action continue` resume on planning stage does NOT invoke `_validate_review_payload`; (X6) `_clear_current_stage_slots "ENG-N" "reviewing"` removes `verdict-review.json` from `$issue_dir/`.
- `bin/render-prompt-test.sh` — append two cases: `_resolve_verdict_review_path` returns the bound path; render-time validator rejects an unbound `{verdict_review_path}` token (mirror existing `stage_summary_path` test shape).
- `learned-rules/harness/project-profile.md` — (a) extend `## Build & test gates`'s Test command line to append `&& bash bin/review-payload-schema-test.sh` at the end; (b) add `- \`Bash(bash bin/review-payload-schema-test.sh:*)\`` to BOTH the `## Tool allowlist::implementing:` arm and the `qa:` arm (alphabetic insertion between `render-prompt-test.sh` and `review-poll-test.sh`). Required by the test-gate closure rule — the new sibling test file MUST appear in both the gate command line AND every per-stage allowlist that runs the gate.
- `docs/runbooks/recovery.md` — append new `## 11. rc=36/37/38 — \`review-payload-invalid\` (review-stage payload detective halt)` section AFTER `## 10` body, BEFORE `## Quick reference: env var requirement`. Mirrors `## 10` (progress-md-entry-missing) shape: Symptom / Detect / Diagnose / Remediation (`--action continue` clears and re-dispatches) / Verify subsections.

### New

- `bin/review-payload-schema.sh` — standalone CLI validator. Subcommand: `validate <file> [--ident <ENG-N>] [--dispatch-id <id>]`. Returns 0 / 36 (malformed) / 37 (incomplete) / 38 (missing-file). Schema source-of-truth lives in the file header comment (per D-002). Validates: `review_schema_version == 1`, `issue_id` is `^ENG-[0-9]+$` and matches `--ident` if supplied, `dispatch_id` is `^ENG-[0-9]+-d[0-9]{4}$` and matches `--dispatch-id` if supplied (else skip), `sha` is non-empty string, `verdict` in `{approve, request-changes, premise-failure, halt}`, `dimensions` is an object with at minimum the four required keys (`correctness, testing, maintainability, scope`); per-dimension: `score` in `{pass, concern, fail}`, `rationale` is non-empty string, `thresholds_met[]` and `thresholds_missed[]` are arrays (may be empty). Unknown top-level / per-dimension fields produce `_warn_unknown` stderr warnings + exit 0 (permissive). Ends with the source-and-test sentinel `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi`.

- `bin/review-payload-schema-test.sh` — sibling self-contained test mirroring `bin/plan-schema-test.sh`. Cases: (T1) well-formed payload with all four required dimensions returns 0; (T2) malformed JSON (parse error) returns 36; (T3) missing required top-level field (`review_schema_version` absent) returns 37; (T4) missing required dimension (`scope` absent) returns 37; (T5) `verdict` enum violation returns 37; (T6) per-dimension `score` enum violation returns 37; (T7) missing file returns 38; (T8) `--ident` mismatch returns 37; (T9) `--dispatch-id` mismatch returns 37; (T10) `--dispatch-id` empty/unset is fail-open (returns 0); (T11) unknown top-level field warns to stderr + returns 0; (T12) unknown per-dimension field warns + returns 0; (T13) conditional dimensions (`security, performance, api_contract, premise`) accepted when present.

## API Contract

No new API surface. ENG-119 is a harness-internal change: bash + jq orchestration only. No FE↔BE handler, no protobuf, no JSON-over-HTTP route. The on-disk JSON payload `verdict-review.json` IS the contract, but its schema lives in `bin/review-payload-schema.sh`'s header comment (per D-002) — not in this plan's API Contract block, which is reserved for FE↔BE surfaces per the prompt's stage profile guidance.

## Backend Tasks

### Task 0: Rebase onto origin/main

- `depends_on: []`
- `touches: <git-only — no source edits>`

- [ ] Run `git fetch origin main && git rebase origin/main` from the worktree root. Resolve any conflicts conservatively (most likely candidates: `bin/pipeline-events.json` if ENG-112 extends the `halt_reasons` array; `bin/common.sh` if ENG-155 added new functions near `failure_outcome_for_exit`; `bin/run-stage.sh` if ENG-146 changed the post-dispatch hook block). Each conflict should be a textual addition near (but not in) the insertion points this plan calls out — accept both sides and reorder so the upstream code lands as-is.
- [ ] Re-verify the Assumption Inventory `path:line` excerpts by spot-checking three anchors with `grep -n`:
  - `grep -n '_validate_plan_contract() {' bin/run-stage.sh` — confirm exactly one match.
  - `grep -n '35) printf .plan-contract-missing.' bin/common.sh` — confirm exactly one match.
  - `grep -n '"plan-contract-invalid"' bin/pipeline-events.json` — confirm exactly one match.
- [ ] If any of the three anchors returns zero or more-than-one matches, STOP. Post a Linear comment naming the conflicting upstream change and request `pipeline:supersede` — the brainstorm should be re-run against the new main.
- [ ] All subsequent tasks operate on the rebased tree. Edit-boundary content anchors (function names, header strings) are stable across the rebase by design.

### Task 1: Extend the exit-code taxonomy and halt-reason registry

- `depends_on: [0]`
- `touches: bin/common.sh, bin/pipeline-events.json, docs/pipeline-vocabulary.md`

- [ ] In `bin/common.sh`, inside `failure_outcome_for_exit()` (the function starting `failure_outcome_for_exit() {` and containing the `case "$exit_code" in` block), insert three new arms IMMEDIATELY AFTER the `35) printf 'plan-contract-missing' ;;` line and BEFORE `124) printf 'dispatch-timeout' ;;`:
  ```
      36) printf 'review-payload-malformed' ;;
      37) printf 'review-payload-incomplete' ;;
      38) printf 'review-payload-missing' ;;
  ```
- [ ] In `bin/pipeline-events.json`, inside the `halt_reasons` array (anchored on the literal `"plan-contract-invalid"` line), append `"review-payload-invalid"` as the last entry (preserving the JSON-array trailing-comma discipline — comma after `"plan-contract-invalid"`, no comma after the new entry).
- [ ] Run `bash bin/generate-vocabulary-doc.sh` from the repo root to regenerate `docs/pipeline-vocabulary.md`. Commit the regenerated file.

### Task 2: Create the validator script and its sibling test

- `depends_on: [0]`
- `touches: bin/review-payload-schema.sh, bin/review-payload-schema-test.sh`

- [ ] Create `bin/review-payload-schema.sh`. Use `bin/plan-schema.sh` as the literal template — copy its overall structure (header comment with canonical schema, `set -euo pipefail`, sentinel `main` dispatcher, `cmd_validate` arg parser, kind-specific validation arms) and adapt to the review-payload schema. Replace plan-contract diagnostics with review-payload diagnostics:
  - `_emit_incomplete` → prints `review-payload-incomplete: <message>`
  - `_emit_malformed` → prints `review-payload-malformed: <message>`
  - `_warn_unknown` → identical shape
  - `cmd_validate` accepts positional `<file>`, `--ident <ENG-N>`, **and new** `--dispatch-id <ENG-N-dNNNN>`
  - `main` dispatches `validate` to `cmd_validate`
- [ ] In the validator body, enforce in order:
  - File exists → else exit 38 with `review-payload-missing: file not found: <path>`.
  - `jq -r 'type'` returns `object` → else exit 36 with `review-payload-malformed: ...`.
  - `.review_schema_version == 1` (and is type `number`) → else exit 37.
  - `.issue_id` matches `^ENG-[0-9]+$` (and is type `string`) → else exit 37; if `--ident` supplied and mismatched → exit 37.
  - `.dispatch_id` matches `^ENG-[0-9]+-d[0-9]{4}$` → else exit 37; if `--dispatch-id` supplied AND non-empty AND mismatched → exit 37. Empty `--dispatch-id` is fail-open (skip the cross-check) per brainstorm Edge case 3.
  - `.sha` is type `string` and non-empty → else exit 37.
  - `.verdict` is one of `approve`, `request-changes`, `premise-failure`, `halt` → else exit 37.
  - `.dimensions` is type `object` and contains at minimum the four keys `correctness`, `testing`, `maintainability`, `scope` → else exit 37.
  - For each dimension key present in `.dimensions`: `score` in `{pass, concern, fail}`, `rationale` is non-empty string, `thresholds_met` is array, `thresholds_missed` is array → else exit 37.
- [ ] Permissive on unknown top-level keys (outside `{review_schema_version, issue_id, dispatch_id, sha, verdict, dimensions}`) and unknown per-dimension keys (outside `{score, rationale, thresholds_met, thresholds_missed}`): emit `_warn_unknown` to stderr; exit 0.
- [ ] On success, print `review-payload-valid: <file>` to stdout and return 0.
- [ ] End the file with the sentinel `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi`.
- [ ] Create `bin/review-payload-schema-test.sh` using `bin/plan-schema-test.sh` as the template. Set `PIPELINE_DRY_RUN=1` and `LINEAR_API_KEY=test-mock-key` before sourcing. Stub `linear.sh` under a `STUB_DIR`. Source `bin/review-payload-schema.sh` and assert against `cmd_validate` directly. Cover T1-T13 (see File Structure / New).
- [ ] Run `bash bin/review-payload-schema-test.sh` from the worktree root — must exit 0. If it fails, fix the validator OR the test until both align.

### Task 3: Wire the detective into run-stage.sh

- `depends_on: [1, 2]`
- `touches: bin/run-stage.sh`

- [ ] In `bin/run-stage.sh`, extend `_clear_current_stage_slots()` (function body anchored by the line `_clear_current_stage_slots() {`). AFTER the existing `rm -f "$d/wait-${stage}.json"        2>/dev/null || true` line and BEFORE the `return 0` line, insert:
  ```
    if [[ "$stage" == "reviewing" ]]; then
      rm -f "$d/verdict-review.json"     2>/dev/null || true
    fi
  ```
- [ ] In `bin/run-stage.sh`, ADD a new function pair AFTER `_post_plan_contract_halt`'s closing brace (anchored by the function body block ending with `bash "$SCRIPT_DIR/linear.sh" add-comment "$ident" "$body" || true\n}`) and BEFORE the `# ENG-87 review M1+M2: dispatch_history.jsonl end-row trap.` block-comment (~line 1086). Insert:
  ```
  # ENG-119: review-payload validator. Runs after dispatch for stage=reviewing only.
  # Locates the payload at $issue_dir/verdict-review.json, then shells out to
  # bin/review-payload-schema.sh validate with --ident and --dispatch-id flags.
  # Returns 0 = valid, 36 = malformed, 37 = incomplete, 38 = missing-file.
  # Caller must gate to stage=reviewing.
  _validate_review_payload() {
    local ident="$1"
    local payload; payload="$(issue_dir "$ident")/verdict-review.json"
    if [[ ! -f "$payload" ]]; then
      _post_review_payload_halt "$ident" "review-payload-missing" \
        "no verdict-review.json at $payload"
      return 38
    fi
    local schema_out schema_rc=0
    schema_out="$(bash "$SCRIPT_DIR/review-payload-schema.sh" validate "$payload" \
      --ident "$ident" --dispatch-id "${PIPELINE_DISPATCH_ID-}")" || schema_rc=$?
    case "$schema_rc" in
      0)  return 0 ;;
      36) _post_review_payload_halt "$ident" "review-payload-malformed"  "$schema_out" ; return 36 ;;
      37) _post_review_payload_halt "$ident" "review-payload-incomplete" "$schema_out" ; return 37 ;;
      38) _post_review_payload_halt "$ident" "review-payload-missing"    "$schema_out" ; return 38 ;;
      *)  _post_review_payload_halt "$ident" "unexpected-rc" \
            "validator returned unexpected rc=$schema_rc; stdout: $schema_out" ; return 36 ;;
    esac
  }

  # Posts a halt comment for a review-payload violation. Mirrors _post_plan_contract_halt's
  # sanitisation pattern: replace `<!--` with `<\!--` in agent-controlled text before
  # embedding in the Linear comment body to prevent marker hijacking. Wraps the validator
  # output in tilde-fenced block so the marker parser strips it (defense-in-depth).
  _post_review_payload_halt() {
    local ident="$1" defect="$2" raw="$3"
    local safe="${raw//<!--/<\\!--}"
    local body
    body="$(printf '<!-- pipeline: verdict result=halt reason=review-payload-invalid -->\n\nReview-payload validation failed on dispatch_id=%s stage=reviewing:\n\n- Defect: %s\n\n~~~\n%s\n~~~\n\nSchema source-of-truth: see header comment in `bin/review-payload-schema.sh`.\n\n**Resume:** fix the agent prompt (or re-render the payload by hand), then run `bash bin/pipeline.sh decide %s --action continue`.' \
      "${PIPELINE_DISPATCH_ID:-unknown}" "$defect" "$safe" "$ident")"
    bash "$SCRIPT_DIR/linear.sh" add-comment "$ident" "$body" || true
  }
  ```
- [ ] In `bin/run-stage.sh::main()`, ADD a new case arm IMMEDIATELY AFTER the plan-contract validator block (anchored by the closing `fi` of the `if (( ! skip_dispatch )); then case "$stage" in planning) ... esac; fi` block, which itself follows the `# ENG-122: plan-contract validator. ...` comment around line 1819) and BEFORE the `# Push branch BEFORE posting the completion comment ...` block-comment around line 1837. Insert:
  ```
  # ENG-119: review-payload validator. Post-dispatch; reviewing stage only.
  # Halts with review-payload-invalid if $issue_dir/verdict-review.json is absent,
  # malformed, or fails schema-v1 validation. Exit codes 36/37/38 map to the
  # failure_outcome_for_exit taxonomy entries added in Task 1.
  if (( ! skip_dispatch )); then
    case "$stage" in
      reviewing)
        local _rev_rc=0
        _validate_review_payload "$ident" || _rev_rc=$?
        if (( _rev_rc != 0 )); then
          classify_failure "$ident" "$stage" "skip-until-human-acts" \
            "review-payload-invalid: $(failure_outcome_for_exit "$_rev_rc")" "$_rev_rc"
          exit "$_rev_rc"
        fi
        ;;
    esac
  fi
  ```

### Task 4: Wire the `verdict_review_path` token into render-prompt

- `depends_on: [0]`
- `touches: bin/render-prompt.sh, bin/render-prompt-test.sh`

- [ ] In `bin/render-prompt.sh`, inside `PROMPT_RESOLVERS` (anchored by the line `PROMPT_RESOLVERS='`), insert a new line `verdict_review_path=_resolve_verdict_review_path` AFTER `plan_json=_resolve_plan_json` and BEFORE the closing `'` of the string.
- [ ] In `bin/render-prompt.sh`, ADJACENT to `_resolve_stage_summary_path() { printf '%s' "$_RENDER_STAGE_SUMMARY_PATH"; }` (anchored by that literal line), add:
  ```
  _resolve_verdict_review_path() { printf '%s' "$_RENDER_VERDICT_REVIEW_PATH"; }
  ```
- [ ] In `bin/render-prompt.sh::main()`, ADJACENT to the existing `_RENDER_STAGE_SUMMARY_PATH="$stage_summary_path"` binding (anchored by that literal line), add:
  ```
  _RENDER_VERDICT_REVIEW_PATH="$(issue_dir "$issue_id")/verdict-review.json"
  ```
- [ ] In `bin/render-prompt-test.sh`, append two cases mirroring the existing `stage_summary_path` resolver tests: (a) source `bin/render-prompt.sh`, set `_RENDER_VERDICT_REVIEW_PATH=/tmp/x`, assert `_resolve_verdict_review_path` prints `/tmp/x`; (b) construct a fixture block containing `{verdict_review_path}` and assert `resolve_block_tokens` substitutes it correctly (or, if unbound, dies with the residual-token error).

### Task 5: Update §5 of AGENT_PROMPTS.md

- `depends_on: [4]`
- `touches: AGENT_PROMPTS.md`

- [ ] In `AGENT_PROMPTS.md`, inside `## 5. Review Agent`'s fenced block, IMMEDIATELY BEFORE the line `Decision path (apply exactly one):` (anchored by that literal line — unique in §5), insert a new "Dimension scoring (MANDATORY)" subsection. Content shape:
  - Introduce the four required dimensions: `correctness`, `testing`, `maintainability`, `scope`.
  - Introduce the four conditional dimensions: `security`, `performance`, `api_contract`, `premise`. Emit each only when its triggering condition fires.
  - State the three-state `score` rubric: `pass` (no findings worse than `minor`), `concern` (≥1 `major` finding), `fail` (≥1 `critical` finding). Cite the existing severity ladder in the prompt body.
  - State that `rationale` is a short non-empty string; `thresholds_met[]` and `thresholds_missed[]` are arrays of free-text narrative strings intended for retrospective trend analysis (NOT a closed vocabulary; ENG-118 threshold gating will read only `score`).
  - Embed an example payload block (JSON-fenced inside the prompt) showing the canonical shape — match the brainstorm §2 D-002 sketch.
  - State that the payload MUST validate against `bin/review-payload-schema.sh` and that missing/malformed payload halts the dispatch with `review-payload-invalid`.
- [ ] In §5's `Output:` bullet list, IMMEDIATELY AFTER the `Stage-summary file at {stage_summary_path} ...` bullet (anchored by the literal line `- Stage-summary file at {stage_summary_path} (per the Stage`) and BEFORE the `- Verdict per Decision path ...` bullet, insert a new bullet:
  ```
  - Per-dimension payload file at {verdict_review_path} (per the Dimension scoring
    subsection above). Use `Write` to emit on ALL three Decision paths (A/B/C);
    overwrite-on-every-dispatch contract per §0. The orchestrator's post-dispatch
    detective halts with `review-payload-invalid` if the file is missing, malformed,
    or fails schema-v1 validation.
  ```
- [ ] Verify no nested column-0 ``` fences were introduced (the prompt body must remain a single fenced block per CLAUDE.md "AGENT_PROMPTS.md is load-bearing"). The example payload block inside the prompt body uses INDENTED fences or tilde-fenced (`~~~`) blocks — NOT column-0 triple-backticks. Run `bash bin/render-prompt-test.sh` to confirm the fence-count invariant holds.

### Task 6: Extend run-stage tests (X1-X6)

- `depends_on: [3]`
- `touches: bin/run-stage-test.sh`

- [ ] Append a new test group "ENG-119 X1-X6" AFTER the ENG-122 group (anchored by the last `Case 122-` test in the file). Reuse the existing `STUB_DIR`-based linear.sh stub. Source `bin/run-stage.sh` (sentinel-gated). Cases:
  - X1: `_validate_review_payload <ident>` with a well-formed payload at `$issue_dir/verdict-review.json` returns 0.
  - X2: `_validate_review_payload <ident>` with no payload file returns 38 and posts a halt comment via the stub.
  - X3: `_validate_review_payload <ident>` with `{` (truncated JSON) returns 36.
  - X4: `_validate_review_payload <ident>` with mismatched `dispatch_id` returns 37.
  - X5: `_clear_current_stage_slots <ident> planning` does NOT remove `verdict-review.json` (only `reviewing` triggers the cleanup).
  - X6: `_clear_current_stage_slots <ident> reviewing` DOES remove `verdict-review.json`.

### Task 7: Update the project profile (test-gate closure)

- `depends_on: [2]`
- `touches: learned-rules/harness/project-profile.md`

- [ ] In `learned-rules/harness/project-profile.md`, extend the `## Build & test gates` Test command line (anchored by the literal `bash bin/common-test.sh` at end of the test command line — unique in the file). Append `&& bash bin/review-payload-schema-test.sh` to the chain.
- [ ] In `## Tool allowlist::implementing:` arm, insert `- \`Bash(bash bin/review-payload-schema-test.sh:*)\`` alphabetically between `Bash(bash bin/render-prompt-test.sh:*)` and `Bash(bash bin/review-poll-test.sh:*)` (anchored by the literal `- \`Bash(bash bin/render-prompt-test.sh:*)\`` line — appears once per arm).
- [ ] In `## Tool allowlist::qa:` arm, insert the same `- \`Bash(bash bin/review-payload-schema-test.sh:*)\`` line at the same alphabetic position.
- [ ] **No agent-side allowlist update for the reviewing stage** — per D-007, `dispatch.sh::allowed_tools_for "reviewing"` is NOT widened (the validator runs orchestrator-side, not agent-side).

### Task 8: Append the runbook section

- `depends_on: [3]`
- `touches: docs/runbooks/recovery.md`

- [ ] In `docs/runbooks/recovery.md`, append a new H2 section AFTER the `## 10. rc=31 — \`progress-md-entry-missing\` (plan-stage progress.md detective halt)` section's body and BEFORE the `## Quick reference: env var requirement` block (anchored by the literal H2 line `## Quick reference: env var requirement`). Heading: `## 11. rc=36/37/38 — \`review-payload-invalid\` (review-stage payload detective halt)`. Body subsections (mirroring §10 shape): Symptom (per-stage transcript shows `_validate_review_payload` halting with one of three exit codes; Linear halt comment carries `<!-- pipeline: verdict result=halt reason=review-payload-invalid -->`); Detect (`grep _validate_review_payload $PROJECT_STATE_DIR/.../logs/<ident>-reviewing-*.log`); Diagnose (read `$issue_dir/verdict-review.json` if present; if missing, agent emitted nothing; if malformed, agent emitted bad bytes; if incomplete, structural defect); Remediation (`bash bin/pipeline.sh decide <ENG-N> --action continue` — clears the halt and re-dispatches the review; the orchestrator pre-cleans the stale payload on next dispatch start per D-008); Verify (next-tick log shows `_validate_review_payload` returning 0 OR the new dispatch's halt has a different defect token).

### Task 9: Run the full test gate

- `depends_on: [1, 2, 3, 4, 5, 6, 7, 8]`
- `touches: <no source edits>`

- [ ] From the worktree root, run the full Test command line from `learned-rules/harness/project-profile.md::Build & test gates` (now extended with `bash bin/review-payload-schema-test.sh`). All tests must exit 0.
- [ ] Run `bash -n bin/review-payload-schema.sh bin/review-payload-schema-test.sh bin/run-stage.sh bin/common.sh bin/render-prompt.sh` — syntax check must exit 0 for each file.
- [ ] Run `bash .githooks/pre-commit` from the worktree root — the pre-commit hook runs the full bin/*-test.sh suite and must pass before any commit is allowed. If it fails, fix the underlying issue (no `--no-verify`).

## Frontend Tasks

No frontend. ENG-119 is harness-internal bash + jq only; no UI surface, no FE bundle, no FE↔BE contract. The UI Agent does not dispatch for this ticket — the orchestrator's `poll.sh` skips the `ui` stage for issues whose plan has an empty Frontend Tasks section (per CLAUDE.md / brainstorm precedent).

## Failure Mode → Test Map

Every Edge Case from brainstorm §6 plus every halt path from brainstorm §5 maps to a concrete test.

| Failure mode                                                            | Trigger                                                          | Expected behavior                                                                                                                | Test layer  | Test name                                            |
|-------------------------------------------------------------------------|------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------|-------------|------------------------------------------------------|
| Missing payload file                                                    | Reviewing dispatch exits without writing `verdict-review.json`   | `_validate_review_payload` returns 38; halt comment posted; `pipeline:halted` applied via classify_failure                        | unit + integration | `review-payload-schema-test.sh::T7` + `run-stage-test.sh::X2` |
| Malformed JSON (parse error)                                            | Agent writes `{` (truncated) or non-JSON content                 | `_validate_review_payload` returns 36; halt comment posted                                                                       | unit + integration | `review-payload-schema-test.sh::T2` + `run-stage-test.sh::X3` |
| Missing required top-level field                                        | Agent omits `review_schema_version`, `verdict`, etc.             | `_validate_review_payload` returns 37; halt diagnostic names the missing field                                                   | unit        | `review-payload-schema-test.sh::T3`                  |
| Missing required dimension                                              | Agent omits `scope` from `dimensions{}`                          | `_validate_review_payload` returns 37; halt diagnostic names the missing dimension                                               | unit        | `review-payload-schema-test.sh::T4`                  |
| `verdict` enum violation                                                | Agent writes `verdict: "approve-with-caveats"` (not in enum)     | `_validate_review_payload` returns 37                                                                                            | unit        | `review-payload-schema-test.sh::T5`                  |
| Per-dimension `score` enum violation                                    | Agent writes `correctness.score: "weak"` (not in enum)           | `_validate_review_payload` returns 37                                                                                            | unit        | `review-payload-schema-test.sh::T6`                  |
| `issue_id` mismatch (cross-issue paste / stale template)                | Payload has `"issue_id": "ENG-200"` but `--ident ENG-119`        | `_validate_review_payload` returns 37                                                                                            | unit        | `review-payload-schema-test.sh::T8`                  |
| `dispatch_id` mismatch (stale file from prior dispatch)                 | Payload has `"dispatch_id": "ENG-119-d0001"` but flag is d0003   | `_validate_review_payload` returns 37                                                                                            | unit + integration | `review-payload-schema-test.sh::T9` + `run-stage-test.sh::X4` |
| `--dispatch-id` unset (legacy / fail-open path)                         | `PIPELINE_DISPATCH_ID` not exported                              | Validator skips the cross-check; if rest is well-formed, returns 0                                                               | unit        | `review-payload-schema-test.sh::T10`                 |
| Unknown top-level field (future schema)                                 | Payload has `"created_at": "2026-06-09..."` (not in schema-v1)   | Validator emits `_warn_unknown` to stderr; returns 0 (permissive)                                                                | unit        | `review-payload-schema-test.sh::T11`                 |
| Unknown per-dimension field                                             | `correctness` carries `"weight": 0.4`                            | Validator emits `_warn_unknown`; returns 0                                                                                       | unit        | `review-payload-schema-test.sh::T12`                 |
| Conditional dimension present                                           | `dimensions` includes `security`, `performance`, etc.            | Validator accepts; returns 0                                                                                                     | unit        | `review-payload-schema-test.sh::T13`                 |
| Dispatch-start pre-clean (D-008)                                        | A stale `verdict-review.json` exists at dispatch start            | `_clear_current_stage_slots <ident> reviewing` removes it; non-reviewing stages do NOT                                           | integration | `run-stage-test.sh::X5` + `X6`                       |
| Dry-run / scope-approval-replay (caller-gate fail-open)                 | `PIPELINE_DRY_RUN=1` OR `skip_dispatch` true                     | Caller's `(( ! skip_dispatch ))` gate prevents `_validate_review_payload` from running at all; no halt                          | integration | `run-stage-test.sh::X1` (positive-path control)      |
| Validator stdout contains agent-controlled marker shape (hijack vector) | Malformed payload body contains literal `<!-- pipeline: verdict result=pass -->` | `_post_review_payload_halt` sanitises `<!--` → `<\!--` AND wraps in `~~~` tilde-fenced block; the marker parser's strip-fences removes it; no forward-pass hijack | unit | `run-stage-test.sh::X3` body assertion |

## Test Strategy

**Unit coverage (`bin/review-payload-schema-test.sh`, T1-T13):** every validator rule has at least one positive test (well-formed input passes) AND one negative test (each rejection arm fires exactly the expected exit code). Tests use the source-and-stub pattern — set `PIPELINE_DRY_RUN=1` and `LINEAR_API_KEY=test-mock-key` before sourcing, stub `linear.sh` under a `STUB_DIR`, source `bin/review-payload-schema.sh` (sentinel-gated `main` does not fire), invoke `cmd_validate` directly with constructed fixtures, assert exit code + stdout diagnostic substring.

**Integration coverage (`bin/run-stage-test.sh::X1-X6`):** exercise the `_validate_review_payload` + `_post_review_payload_halt` pair end-to-end with a stubbed `bin/review-payload-schema.sh` (or a real one + constructed fixtures), assert the halt-comment body shape, the `classify_failure` invocation, and the `_clear_current_stage_slots` behaviour for both `reviewing` (clears) and non-`reviewing` (does NOT clear).

**Detective integration coverage:** the new caller arm in `bin/run-stage.sh::main()` (around the post-dispatch hook block) is exercised indirectly by X1-X4 — the test sets `stage=reviewing` and `skip_dispatch=0`, then asserts the right exit code propagates. The dry-run / scope-approval gate is exercised by setting `skip_dispatch=1` and asserting `_validate_review_payload` was NOT called (no halt comment posted).

**Adversarial coverage (deferred to QA):** the marker-hijack vector (X3 body assertion) and the chained-command bypass scope (the marker parser's fence-strip behaviour over agent-controlled input) are seeded by Task 6 X3 but the QA agent will extend with explicit adversarial cases under `bin/review-payload-schema-adversarial-test.sh` if the brainstorm §6 OQ-7 residual edge materialises.

**Test-gate closure sweep (verified):**
- **Remove-side:** this plan REMOVES no production-code tokens that any sibling test currently pins. The new validator + tests are all *additive*. Verified by inspection: there is no existing `bin/*-test.sh` that asserts `36)` or `37)` or `38)` would NOT exist in `bin/common.sh::failure_outcome_for_exit` (the existing tests assert what IS mapped, not what is NOT).
- **Add-side:** `bin/review-payload-schema-test.sh` is a NEW file under the `bin/*-test.sh` glob. The project profile (`learned-rules/harness/project-profile.md::Build & test gates`) Test command line is extended in Task 7 to include it. The `## Tool allowlist::implementing:` and `::qa:` arms are also extended so the agent can run the new test under its dispatch allowlist when verifying fixes during implement / QA.

**Pre-commit gate:** Task 9 runs `bash .githooks/pre-commit` which executes the full `bin/*-test.sh` suite. Any test failure here is a P0 implement defect.
