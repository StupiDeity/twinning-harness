---
linear: ENG-113
date: 2026-06-10
topic: qa split — extract verification predicate from prompt body
---

# ENG-113 — Plan: qa split — extract verification predicate from prompt body

## 1. Goal

Land the verification-predicate contract surface so the QA agent emits a structured `qa-predicate-<ident>.json` document at dispatch start, and `bin/verify-qa.sh validate` executes that document without invoking claude — producing a JSONL pass/fail report — with malformed/incomplete/missing predicates halting QA via the new `qa-predicate-invalid` halt reason and codes 36/37/38.

## 2. Assumption Inventory

**Branch-base freshness pin:** `git log --oneline HEAD..origin/main` is **NON-EMPTY** at plan time — 100+ commits ahead on origin/main (most recent: `dff490c` feat(eng-151) linear.sh header line; relevant siblings: ENG-124 §6 plan.json contract, ENG-155 common.sh `assert_no_tool_with_input_path`, ENG-151 exit code 15, ENG-146 `strip_state_preserve_alloc`). Task 0 (Rebase onto origin/main) is added at the top of Backend Tasks; every step below uses content anchors, never bare line numbers, to survive the rebase. Line numbers cited are informational hints valid at pre-rebase HEAD (`223c3de`); the implement agent re-verifies anchors post-rebase. **Drift is clean** (not dirty) — the ENG-124 plan.json contract in §6 ALIGNS with this plan's design (the agent already sees `{plan_json}` inline; D-005 below adapts the agent's source-of-pass_criteria from "open the .json file" to "consume the embedded `<<<PLAN_JSON_BEGIN>>>` block already in your prompt context"). No upstream commit invalidates a brainstorm decision.

Every named symbol, path, exit code, and registry entry below is grep-verified against the current working tree.

| # | Assumption | Status | Evidence |
|---|---|---|---|
| A1 | `bin/render-prompt.sh::PROMPT_RESOLVERS` is the resolver registry; new token names land between the opening `PROMPT_RESOLVERS='` line and the closing `'` line. | **verified** | `bin/render-prompt.sh:41-58` (read directly). Current trailing entry: `plan_json=_resolve_plan_json`. **Content anchor for insertion:** the line `progress_md_path=_resolve_progress_md_path` is unique in the file; the new `qa_predicate_path=_resolve_qa_predicate_path` line inserts after it (or after `plan_json=_resolve_plan_json` — either grouping reads clean). |
| A2 | `bin/render-prompt.sh::_resolve_progress_md_path` is the path-shape resolver precedent: a one-liner returning a `_RENDER_*` global. | **verified** | `bin/render-prompt.sh:230` — `_resolve_progress_md_path() { printf '%s' "$_RENDER_PROGRESS_MD_PATH"; }`. **Content anchor for the new `_resolve_qa_predicate_path` body:** insert immediately after the `_resolve_progress_md_path` one-liner and before `_resolve_learned_rules_dir`. |
| A3 | `bin/render-prompt.sh::main()` binds `_RENDER_PROGRESS_MD_PATH` via `progress_md_path "$issue_id"`. | **verified** | `bin/render-prompt.sh:521` — `_RENDER_PROGRESS_MD_PATH="$(progress_md_path "$issue_id")"`. **Content anchor for the new `_RENDER_QA_PREDICATE_PATH` binding:** the literal line `_RENDER_PROGRESS_MD_PATH="$(progress_md_path "$issue_id")"` is unique; the new bind goes IMMEDIATELY AFTER it, separated by one comment line tagged ENG-113. |
| A4 | `bin/common.sh::progress_md_path` is the per-issue path-helper precedent (composes on `issue_dir`). | **verified** | `bin/common.sh:78-82` — `progress_md_path() { … printf '%s/progress.md' "$(issue_dir "$issue")"; }`. The new `qa_predicate_path` helper is byte-for-byte the same shape with the basename swapped. **Content anchor:** the closing `}` of `progress_md_path` followed by the `# Compute a stable sha256` comment opening `compute_pipeline_content_hash` — new helper inserts BETWEEN them. |
| A5 | `bin/common.sh::failure_outcome_for_exit` is the canonical exit-code taxonomy; codes 33/34/35 are mapped to `plan-contract-malformed/incomplete/missing`; codes 36/37/38 are free. | **verified** | `bin/common.sh:247-279` (read directly). Existing mapping: `33) printf 'plan-contract-malformed' ;; 34) printf 'plan-contract-incomplete' ;; 35) printf 'plan-contract-missing' ;;`. Codes 30/31/32/36/37/38 absent — 36/37/38 the brainstorm reserves are free. **Content anchor for insertion:** the literal `35) printf 'plan-contract-missing' ;;` line; new lines 36/37/38 insert IMMEDIATELY AFTER (before `124) printf 'dispatch-timeout' ;;` and the closing `*)` arm). |
| A6 | `bin/common.sh::export -f` list at line ~489 (post-ENG-155 drift +60 lines) lists every exported helper; the new `qa_predicate_path` MUST be appended. | **verified** | `bin/common.sh:489` (post-rebase). Pre-rebase reads the same line at `bin/common.sh:430`. Current list trails with `assert_no_write_to_path assert_no_tool_with_input_path`. **Content anchor:** the literal `export -f ` prefix is unique on this line. |
| A7 | `bin/pipeline-events.json::halt_reasons[]` is the closed-vocabulary registry for halt-reason tokens; `plan-contract-invalid` is already an entry. | **verified** | `bin/pipeline-events.json:10-20` (read directly). Current entries: `agent-blocked, agent-failure, smoke-failed, iteration-exhausted, scope-violation, protocol-violation, dispatch-timeout, pr-opened-too-early, dispatch-envelope-violation, plan-contract-invalid`. **Content anchor:** the literal `"plan-contract-invalid"` line; new `"qa-predicate-invalid"` line inserts AFTER it as the last element of the array (trailing comma replacement). |
| A8 | `bin/plan-schema.sh::cmd_validate` is the per-criterion validation source (~80 lines of jq + bash conditionals) at lines 181-260 — the refactor source for D-007's `_validate_pass_criterion`. | **verified** | `bin/plan-schema.sh:60-282` (read directly). The per-criterion for-loop at lines 181-260 handles `smoke / file_exists / grep` kinds with kind-specific field validation. **Content anchor for refactor:** the literal `for (( ci=0; ci<pc_len; ci++ )); do` loop opener on line 181; the loop body is lifted verbatim into `bin/common.sh::_validate_pass_criterion`, then replaced with a one-line call `_validate_pass_criterion "$file" "$fi" "$ci" --kinds smoke,file_exists,grep || return $?`. Closing `done` of the loop is the second anchor. |
| A9 | `bin/dispatch.sh::allowed_tools_for` qa case-arm is the per-stage Bash allowlist for `claude -p`; current base lacks `bin/verify-qa.sh`. | **verified** | `bin/dispatch.sh:457` (read directly). Current `qa` base: `Read,Write,Edit,Grep,Glob,TaskCreate,Agent,Bash(git:*),Bash(jq:*),Bash(awk:*),Bash(gh pr view:*),Bash(gh pr diff:*),Bash(gh pr comment:*),Bash(gh issue create:*),Bash(gh issue list:*),Bash(bash .pipeline/bin/linear.sh:*),Bash(bash bin/linear.sh:*),Bash(bash .pipeline/bin/pipeline.sh:*),Bash(bash bin/pipeline.sh:*),Bash(bash .pipeline/bin/guards.sh:*),Bash(bash bin/guards.sh:*)`. **Content anchor:** the literal `qa)             base='Read,Write,Edit,Grep,Glob,TaskCreate,Agent,Bash(git:*)…` opener is unique in the file. Append `,Bash(bash .pipeline/bin/verify-qa.sh:*),Bash(bash bin/verify-qa.sh:*)` before the closing `' ;;`. |
| A10 | `AGENT_PROMPTS.md §6` "Your task:" block contains a numbered step list starting at "1. **Flaky-pattern triage**"; the new step inserts BEFORE step 1 and renumbers existing steps 1→2 down by one. | **verified** | `AGENT_PROMPTS.md:1392-1444` pre-rebase / post-rebase shifts +173 lines per the ENG-124 drift but the **distinctive header** `Your task:` followed by `1. **Flaky-pattern triage` survives unchanged on origin/main. **Content anchors:** (a) the literal line `Your task:` is unique within §6's fenced block; (b) the literal `1. **Flaky-pattern triage (first pass — BEFORE running the suite):**` is unique. The new step inserts BETWEEN these two anchors. |
| A11 | §6 "Plan JSON contract" block (ENG-124, post-rebase) embeds `<<<PLAN_JSON_BEGIN>>>{plan_json}<<<PLAN_JSON_END>>>`; the QA agent sees plan.json verbatim in its prompt context. | **verified post-rebase** | `git show origin/main:AGENT_PROMPTS.md` shows the new §6 block at the `Plan JSON contract (MANDATORY when plan.json is present):` header (lines ~1502-1532 on origin/main). This INVALIDATES the brainstorm §D-005's "Read the plan's pass_criteria[] from docs/plans/{plan_file}'s sibling JSON" instruction — the agent's prompt ALREADY carries the embedded JSON. The plan's new step 1 instructs the agent to read pass_criteria FROM THE EMBEDDED BLOCK, NOT from disk. Falls back cleanly when the embedded body reads `(no plan.json — falling back to prose plan)`. |
| A12 | `bin/agent-prompts-content-test.sh` is the canonical content-pin shape; `printf '%s\n' "$s6" \| grep -qF '<phrase>'` is the established assertion. | **verified** | `bin/agent-prompts-content-test.sh:76` defines `s6="$(section_body "## 6. QA Agent")"`. The ENG-108 pin shape at lines 91-101 (`grep -qF '1. {progress_md_path}'`) is the pattern for the new ENG-113 pin (`grep -qF 'Emit verification predicate'`). **Content anchor for insertion:** the existing ENG-140-style "QA → implement loopback handling" pin block (line ~103-113); the new ENG-113 pin block inserts AFTER it. |
| A13 | `bin/render-prompt-rc0-test.sh` cases follow a letter-indexed pattern (G/H/I/J/K from ENG-139, L/M/N from ENG-140). Next free letter is **O**. | **verified** | `bin/render-prompt-rc0-test.sh:307,326,349,368,382,410,441,464` (grep `Case [G-N]\b` confirmed each letter present). Letter O is free. **Content anchor for insertion:** the existing Case N block ends with its closing `fi`; the new Case O inserts BETWEEN that closing `fi` and the `printf '\n━━━ Summary ━━━` footer (same insertion shape as cases L/M/N in ENG-140). |
| A14 | `bin/run-stage.sh::_clear_current_stage_slots` clears `stage-summary-${stage}.md` and `wait-${stage}.json` for the current stage only; OTHER stages' summaries are preserved across the dispatch's slot-clear. | **verified — UNTOUCHED by plan** | `bin/run-stage.sh:931-939` (read directly). Per brainstorm D-010 + §8, the slot-clearing is NOT extended to include `qa-predicate-<ident>.json` in ENG-113 — the agent's overwrite-on-every-dispatch contract (D-005, §0 Common rules) handles staleness without orchestrator slot integration. The slot-extension is the next sub-ticket's concern. |
| A15 | `_validate_plan_contract` (`bin/run-stage.sh:1056`) is the post-dispatch validator precedent shape ENG-113 does NOT replicate (D-010 scope boundary). | **verified — UNTOUCHED by plan** | `bin/run-stage.sh:1056-1092` (read directly). The brainstorm D-010 table explicitly lists `bin/run-stage.sh` as untouched: orchestrator-side integration of `verify-qa.sh` as a post-dispatch detective is the NEXT sub-ticket. ENG-113 ships `verify-qa.sh` as a standalone CLI only. |
| A16 | `bin/plan-schema-test.sh` is the test precedent for the new test file; uses `mktemp -d` fixture dir + source-and-stub + per-rc assertions. | **verified** | `bin/plan-schema-test.sh:1-100` (read directly). Tests T1-T18 cover well-formed/malformed/incomplete paths, including kind-specific rc=34 paths. The new `bin/verify-qa-test.sh` mirrors this structure: same fixture-dir + stub pattern + per-rc assertion shape. |
| A17 | `learned-rules/harness/project-profile.md` is the per-slug profile; `## Build & test gates` lists every `bin/*-test.sh` in the harness target's gate suite; `## Tool allowlist::implementing` and `## Tool allowlist::qa` each enumerate every test file. Adding `bin/verify-qa-test.sh` requires updating ALL THREE sites (test-gate ADD-side closure sweep — ENG-122 class). | **verified** | `learned-rules/harness/project-profile.md:14-20` (Build & test gates Test line) + `:30-72` (implementing allowlist) + `:75-116` (qa allowlist). Current Test line ends with `&& bash bin/common-test.sh`; both allowlists end with `Bash(bash bin/vocabulary-cleanliness-test.sh:*)`. **Content anchors:** the literal phrase `&& bash bin/common-test.sh` for the gate; the literal `Bash(bash bin/vocabulary-cleanliness-test.sh:*)` for each allowlist (both are end-of-list markers). |
| A18 | `eng-113` slug-token is present in this plan doc's basename, satisfying `partition_dirty_paths::D-004` in-scope bucketing for `docs/plans/` writes. | **verified** | basename: `2026-06-10-eng-113-qa-split-extract-verification-predicate-from-prompt-body.md` contains literal `eng-113`. The sibling JSON contract uses the same basename. |
| A19 | `bin/render-prompt.sh::_resolve_plan_json` was generalised in ENG-124 (origin/main) to use `_RENDER_STAGE` (was hardcoded `"implementing"`), so the `{plan_json}` token resolves cleanly on the qa stage's render — pass_criteria reach the QA agent verbatim. | **verified post-rebase** | `bin/render-prompt.sh:309-340` on origin/main: `local stage="${_RENDER_STAGE:-unknown}"` + `bash "$SCRIPT_DIR/metrics.sh" plan_json_present "$_RENDER_ISSUE_ID" "$stage" used 0` at line ~329. The `_RENDER_STAGE="$stage"` binding lands in `main()` at line ~530. |
| A20 | `bin/render-prompt-rc0-test.sh` ENG-87 / ENG-140 fixture pattern uses per-issue `ISSUE_DIR_*` setup; Case O for `{qa_predicate_path}` resolution uses the same `mkdir -p "$ISSUE_DIR_O"` + render-prompt invocation + `grep -qF "qa-predicate-ENG-"` assertion shape. | **verified** | `bin/render-prompt-rc0-test.sh:410-498` cases L/M/N follow this exact shape; Case O for the new path-token resolver test mirrors it (substituting `qa_predicate_path` for `qa_findings`, `qa-predicate-ENG-` literal substring for sentinel matching). |

**Branch-base freshness:** `HEAD..origin/main` non-empty at plan time. Origin/main HEAD = `dff490c` (ENG-151 header line). Task 0 below handles the rebase. If post-rebase the content anchors named above no longer survive (e.g. a sibling commit removes `_resolve_progress_md_path` or rewrites `failure_outcome_for_exit`'s exit-code triplet), implement halts with `verdict halt --reason agent-blocked` naming the missing anchor.

## 3. File Structure

| File | Change | Status |
|---|---|---|
| `bin/verify-qa.sh` | **NEW** — Standalone CLI: `validate <file> [--ident <ENG-N>] [--worktree <path>]`. Sources common.sh. Calls `_validate_pass_criterion` (D-007), then iterates pass_criteria executing each kind, emits JSONL pass/fail report on stdout. Authority surface: path-prefix check pins the predicate file under `$PROJECT_STATE_DIR`. | new |
| `bin/verify-qa-test.sh` | **NEW** — Cases V-1..V-9 covering rc=0/36/37/38 paths + kind execution coverage (smoke/file_exists/grep/http_get) + `--ident` mismatch + path-traversal rejection (D-013). Sibling sentinel + source-and-stub pattern. | new |
| `bin/common.sh` | Modify — add `qa_predicate_path <ident>` helper (one-liner like `progress_md_path`); add `_validate_pass_criterion <file> <fi> <ci> [--kinds <csv>]` lifted from `bin/plan-schema.sh:181-260` with optional `http_get` kind gated on `--kinds`; add exit codes 36 → `qa-predicate-malformed`, 37 → `qa-predicate-incomplete`, 38 → `qa-predicate-missing` to `failure_outcome_for_exit`; append both new helpers to `export -f` line. | modified |
| `bin/plan-schema.sh` | Modify — replace inline per-criterion validation loop (lines 181-260) with a single call to `_validate_pass_criterion "$file" "$fi" "$ci" --kinds smoke,file_exists,grep || return $?`. No behavior change. | modified |
| `bin/render-prompt.sh` | Modify — add `qa_predicate_path=_resolve_qa_predicate_path` to `PROMPT_RESOLVERS`; add one-line `_resolve_qa_predicate_path() { printf '%s' "$_RENDER_QA_PREDICATE_PATH"; }`; bind `_RENDER_QA_PREDICATE_PATH="$(qa_predicate_path "$issue_id")"` in `main()`. | modified |
| `bin/render-prompt-rc0-test.sh` | Modify — add Case O asserting `{qa_predicate_path}` token resolves to a concrete absolute path whose basename matches `qa-predicate-ENG-` on a qa-stage render. | modified |
| `bin/agent-prompts-content-test.sh` | Modify — pin §6 contains the distinctive phrase `Emit verification predicate`. | modified |
| `AGENT_PROMPTS.md` | Modify — §6 gains a new numbered "Step 1: Emit verification predicate" inserted BEFORE the existing "Flaky-pattern triage" step (which becomes step 2); steps 2-7 renumber 3-8. New step instructs the agent to copy pass_criteria from the inline `<<<PLAN_JSON_BEGIN>>>` block (post-ENG-124) into a JSON document written via `Write` to `{qa_predicate_path}`, with `qa_predicate_schema_version: 1` + `issue_id` + the predicate's own `pass_criteria[]` (plan's verbatim + optional QA-authored adversarial criteria). | modified |
| `bin/pipeline-events.json` | Modify — append `"qa-predicate-invalid"` to `halt_reasons[]` array. | modified |
| `learned-rules/harness/project-profile.md` | Modify — `## Build & test gates` Test line appends `&& bash bin/verify-qa-test.sh`; `## Tool allowlist::implementing` and `## Tool allowlist::qa` each append `Bash(bash bin/verify-qa-test.sh:*)` (test file allowlisted for both stages so the test-gate sweep runs in implementing/qa dispatches per the symmetric add-side closure rule). Note: `Bash(bash bin/verify-qa.sh:*)` (the runner CLI, not the test) lands in `bin/dispatch.sh::allowed_tools_for`'s qa case-arm (above), NOT in the profile, per brainstorm D-010. | modified |
| `docs/plans/2026-06-10-eng-113-qa-split-extract-verification-predicate-from-prompt-body.md` | New (this file). | new |
| `docs/plans/2026-06-10-eng-113-qa-split-extract-verification-predicate-from-prompt-body.json` | New — schema-v1 plan contract sibling. | new |

**Out of scope (NOT modified):** `bin/run-stage.sh` (no `_validate_qa_predicate` post-dispatch hook; the next sub-ticket adds it), `bin/verdict-handler.sh` (no new transitions; existing `qa|implementing|` row covers qa-fail loopback), `bin/poll.sh`, `bin/scope-check.sh`, `bin/run-local.sh`, `bin/run-local-helpers.sh`, `bin/classify-failure.sh`, `bin/metrics.sh`, `bin/linear.sh`, `bin/secret-probe-lint.sh`, `bin/setup.sh`, `bin/setup-prompts/*`, the Linear ticket and brainstorm doc themselves, all `docs/runbooks/*.md`, all `docs/knowledge/*.md`, `learned-rules/harness/qa.md` (does not exist; not creating it). Per brainstorm D-010 UNTOUCHED list. Scope-check halts on any deviation; the implement agent's `partition_dirty_paths` sweep flags an unlisted edit as self-leak.

## 4. API Contract

No new FE↔BE API surface. The harness has no FE↔BE API; `bin/verify-qa.sh` is a CLI consumed by the QA agent (today) and the orchestrator (next sub-ticket). The CLI's input contract (a JSON file at `{qa_predicate_path}`) and output contract (JSONL on stdout, structured exit codes) are documented in §2 (D-001 / D-012) of the brainstorm and surface in the verify-qa-test.sh fixtures.

## 5. Backend Tasks

### Task 0: Rebase onto origin/main

- `depends_on: []`
- `touches: (git history only — no file edits)`
- [ ] Run `git fetch origin main` then `git rebase origin/main` in the worktree. Resolve any conflicts in files listed in §3 File Structure (`bin/common.sh`, `bin/render-prompt.sh`, `bin/plan-schema.sh`, `AGENT_PROMPTS.md §6`, `bin/pipeline-events.json`, `learned-rules/harness/project-profile.md`) using the post-rebase `bin/scope-check.sh::is_benign` rules. If a conflict touches one of the content anchors named in Assumption Inventory (A2, A3, A4, A5, A8, A9, A10, A11, A12, A13, A17), STOP and halt with `verdict halt --reason agent-blocked` naming the conflicting upstream commit — the brainstorm should be re-validated against the new main, not patched.
- [ ] `git push --force-with-lease origin <branch_name>` — required because the rebase rewrites the published history.
- [ ] Re-verify content anchors survived. For each, run `grep -nF` against the literal anchor string; each MUST return at least one hit. Zero hits = halt with `agent-blocked` naming the missing anchor:
  - `_resolve_progress_md_path` in `bin/render-prompt.sh` (A2)
  - `_RENDER_PROGRESS_MD_PATH="$(progress_md_path` in `bin/render-prompt.sh` (A3)
  - `progress_md_path() {` in `bin/common.sh` (A4)
  - `35) printf 'plan-contract-missing'` in `bin/common.sh` (A5)
  - `export -f issue_dir` in `bin/common.sh` (A6)
  - `"plan-contract-invalid"` in `bin/pipeline-events.json` (A7)
  - `for (( ci=0; ci<pc_len; ci++ )); do` in `bin/plan-schema.sh` (A8)
  - `qa)             base='Read,Write,Edit,Grep,Glob,TaskCreate,Agent,Bash(git:*)` in `bin/dispatch.sh` (A9)
  - `Your task:` immediately followed (within ~3 lines) by `1. **Flaky-pattern triage` in `AGENT_PROMPTS.md` (A10)
  - `<<<PLAN_JSON_BEGIN>>>` in `AGENT_PROMPTS.md` (A11 — present post-rebase only)
  - `Bash(bash bin/vocabulary-cleanliness-test.sh:*)` in `learned-rules/harness/project-profile.md` (A17)

### Task 1: Add exit codes 36/37/38 + `qa_predicate_path` helper to `bin/common.sh`; lift `_validate_pass_criterion`

- `depends_on: [0]`
- `touches: bin/common.sh::failure_outcome_for_exit, bin/common.sh::qa_predicate_path (new), bin/common.sh::_validate_pass_criterion (new), bin/common.sh::export -f`
- [ ] **Exit-code triplet.** Locate the literal line `35) printf 'plan-contract-missing' ;;` inside `failure_outcome_for_exit`. Insert three lines IMMEDIATELY AFTER that anchor, BEFORE the `124) printf 'dispatch-timeout' ;;` line:
      ```bash
      36) printf 'qa-predicate-malformed' ;;
      37) printf 'qa-predicate-incomplete' ;;
      38) printf 'qa-predicate-missing' ;;
      ```
- [ ] **`qa_predicate_path` helper.** Locate the closing `}` of `progress_md_path` (the one-liner ending `printf '%s/progress.md' "$(issue_dir "$issue")"`). Locate the next comment block opening `# Compute a stable sha256 over the set of files that drive pipeline behavior`. Insert the new helper BETWEEN these two anchors, separated by one blank line above and a comment line tagged `# ENG-113: per-issue qa-predicate JSON path. Mirrors progress_md_path; consumed by bin/verify-qa.sh and the {qa_predicate_path} prompt resolver.`:
      ```bash
      qa_predicate_path() {
        local issue="$1"
        [[ -n "$issue" ]] || die "qa_predicate_path: missing issue id"
        printf '%s/qa-predicate-%s.json' "$(issue_dir "$issue")" "$issue"
      }
      ```
- [ ] **`_validate_pass_criterion` helper.** Lift the per-criterion validation loop body from `bin/plan-schema.sh:181-260` (the body INSIDE the `for (( ci=0; ci<pc_len; ci++ )); do … done` loop — the case statement on `kind` covering `smoke / file_exists / grep / *)`). Land it as a NEW function in `bin/common.sh` (placed AFTER the new `qa_predicate_path` helper, BEFORE `compute_pipeline_content_hash`). Function shape:
      ```bash
      # ENG-113 D-007: shared per-pass_criterion validator; lifted from
      # bin/plan-schema.sh:181-260. Callers: plan-schema.sh::cmd_validate
      # (plan.json) and verify-qa.sh::cmd_validate (qa-predicate JSON). The
      # --kinds CSV restricts the allowed kind set; plan-schema passes
      # "smoke,file_exists,grep"; verify-qa passes "smoke,file_exists,grep,http_get".
      # The `http_get` kind validates `url` (non-empty string), `expect_status`
      # (integer), and optional `expect_body_match` (string|null).
      # The `file_exists` and `grep` kinds additionally enforce D-013
      # path-traversal hardening: reject leading `/` and any `../` segment;
      # exempt `smoke` (commands run any binary) and `http_get` (URLs are
      # not filesystem paths). Returns rc=34 (incomplete) on any failure
      # with the same `plan-contract-incomplete:` / `qa-predicate-incomplete:`
      # diagnostic shape — caller-side `_emit_incomplete` shim still owns
      # the prefix string.
      _validate_pass_criterion() {
        local file="$1" fi="$2" ci="$3"
        shift 3
        local kinds_csv="smoke,file_exists,grep"
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --kinds) kinds_csv="$2"; shift 2 ;;
            *) shift ;;
          esac
        done
        # … (full body lifted from plan-schema.sh:181-260, with the case
        # arms gated on `kinds_csv` containing the kind name; adds an
        # `http_get` arm validating url+expect_status[+expect_body_match];
        # extends `file_exists`/`grep` arms with the D-013 traversal guard).
      }
      ```
   Implement the case body verbatim from `plan-schema.sh:189-258` for `smoke/file_exists/grep`; add the `http_get` arm gated on `kinds_csv contains "http_get"`; for the `*)` fallthrough kind, gate the error message on `kinds_csv` so the diagnostic reads `(allowed: $kinds_csv)`.
- [ ] **Add D-013 path-traversal guard** inside the `file_exists` and `grep` arms (before the existing path-non-empty check). Bash conditional — match leading `/` (absolute) OR any `..` path-segment (separator-bounded so `foo..bar` filenames don't false-positive):
      ```bash
      if [[ "$path_val" == /* \
            || "$path_val" == ../* \
            || "$path_val" == */../* \
            || "$path_val" == */.. ]]; then
        _emit_incomplete "features[$fi].pass_criteria[$ci] ($kind): path must be worktree-relative (no leading '/' and no '..' path-segment), got: $path_val"
        return 34
      fi
      ```
- [ ] **Export.** Append `qa_predicate_path _validate_pass_criterion` to the `export -f` line (locate via the literal `export -f issue_dir compute_pipeline_content_hash`). Order within the line is for readability only; the matcher is order-insensitive.

### Task 2: Refactor `bin/plan-schema.sh::cmd_validate` to call `_validate_pass_criterion`

- `depends_on: [1]`
- `touches: bin/plan-schema.sh::cmd_validate (lines 181-260 region)`
- [ ] **Replace the per-criterion loop body.** Locate the literal line `for (( ci=0; ci<pc_len; ci++ )); do` inside `cmd_validate`. The loop's existing body (the `local kind; …; case "$kind" in smoke|file_exists|grep|*) … esac`) is replaced by a single call:
      ```bash
      for (( ci=0; ci<pc_len; ci++ )); do
        _validate_pass_criterion "$file" "$fi" "$ci" --kinds smoke,file_exists,grep || return $?
      done
      ```
   Net delta: -~80 LOC inside the loop, +1 call site. Preserve the `for` header and `done` exactly as today; only the body changes.
- [ ] **No `_emit_incomplete` rename required.** `_validate_pass_criterion` calls `_emit_incomplete` directly (defined in plan-schema.sh AND will be sourced into common.sh's namespace via `_validate_pass_criterion`'s caller scope) — but the diagnostic prefix shape differs between plan-contract and qa-predicate. Resolution: `_validate_pass_criterion` reads an optional caller-set env var `_PASS_CRITERION_CALLER` (defaults to `plan-contract`); plan-schema.sh leaves it unset; verify-qa.sh sets `_PASS_CRITERION_CALLER=qa-predicate` before calling. Inside `_validate_pass_criterion`, emit via `printf '%s-incomplete: %s\n' "${_PASS_CRITERION_CALLER:-plan-contract}" "$msg"`. Both `_emit_incomplete` shims in their respective callers become unnecessary inside the loop; the caller's `_emit_incomplete` definition stays for the top-level pre-loop calls (version, issue_id, features-len, etc.) — only the per-criterion error messages migrate.
- [ ] Run `bash bin/plan-schema-test.sh` standalone after the refactor. All T1-T18 tests MUST still pass — the refactor is behavior-preserving.

### Task 3: Add `_resolve_qa_predicate_path` + `_RENDER_QA_PREDICATE_PATH` to `bin/render-prompt.sh`

- `depends_on: [1]`
- `touches: bin/render-prompt.sh::PROMPT_RESOLVERS, bin/render-prompt.sh::_resolve_qa_predicate_path (new), bin/render-prompt.sh::main`
- [ ] **Registry entry.** Locate the literal line `progress_md_path=_resolve_progress_md_path` inside the `PROMPT_RESOLVERS='...'` heredoc. Insert `qa_predicate_path=_resolve_qa_predicate_path` on the line IMMEDIATELY AFTER it.
- [ ] **Resolver body.** Locate the literal one-line definition `_resolve_progress_md_path() { printf '%s' "$_RENDER_PROGRESS_MD_PATH"; }`. Insert the new resolver IMMEDIATELY AFTER it (no blank line between siblings; matches the existing `_resolve_progress_md_path` / `_resolve_learned_rules_dir` adjacency):
      ```bash
      _resolve_qa_predicate_path() { printf '%s' "$_RENDER_QA_PREDICATE_PATH"; }
      ```
- [ ] **`main()` binding.** Locate the literal line `_RENDER_PROGRESS_MD_PATH="$(progress_md_path "$issue_id")"`. Insert the new binding IMMEDIATELY AFTER it, on its own line, with a leading comment line tagged ENG-113:
      ```bash
      # ENG-113: per-issue qa-predicate path resolved at render time.
      _RENDER_QA_PREDICATE_PATH="$(qa_predicate_path "$issue_id")"
      ```
   Secret-handling pin: `qa_predicate_path` returns a plain path string; no env-var defaults. The new line uses `$(qa_predicate_path …)` directly, not `${VAR:-…}` — secret-probe-lint compliance is automatic.
- [ ] Run `bash bin/render-prompt-test.sh` after the edit to confirm the registry parses, the new token resolves without dying on the unknown-token residual scan.

### Task 4: Add `qa-predicate-invalid` to `bin/pipeline-events.json::halt_reasons[]`

- `depends_on: [0]`
- `touches: bin/pipeline-events.json`
- [ ] **Append entry.** Locate the literal line `"plan-contract-invalid"` inside the `halt_reasons` array. The current line ends WITHOUT a trailing comma (closing array element). Two edits at this anchor:
      1. Append a comma after `"plan-contract-invalid"` to convert it from terminal element to non-terminal.
      2. Insert `"qa-predicate-invalid"` (no trailing comma) on the next line as the new terminal element.
- [ ] Run `jq -e '.halt_reasons | index("qa-predicate-invalid")' bin/pipeline-events.json` — MUST return a non-null index (parse-valid + entry-present). Run `bash bin/pipeline-test.sh` if present (event-registry parser coverage); silently no-op if the test file is absent.

### Task 5: Extend `bin/dispatch.sh::allowed_tools_for` qa case-arm to allowlist the runner CLI

- `depends_on: [0]`
- `touches: bin/dispatch.sh::allowed_tools_for (qa case)`
- [ ] **Allowlist extension.** Locate the literal line opener `    qa)             base='Read,Write,Edit,Grep,Glob,TaskCreate,Agent,Bash(git:*)` (unique in the file). Inside the single-quoted `base='…'` string, BEFORE the closing `' ;;`, append: `,Bash(bash .pipeline/bin/verify-qa.sh:*),Bash(bash bin/verify-qa.sh:*)`. Dual-path matches the existing `bash .pipeline/bin/linear.sh:* / bash bin/linear.sh:*` convention.
- [ ] Run `bash bin/dispatch-test.sh` to confirm allowlist composition still validates against the existing enumerate-vs-wildcard checks.

### Task 6: Author `bin/verify-qa.sh validate` CLI

- `depends_on: [1, 4]`
- `touches: bin/verify-qa.sh (new)`
- [ ] **File header + sentinel.** Mirror `bin/plan-schema.sh`'s shape: `set -euo pipefail`, `SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"`, source common.sh. End with the sibling-test sentinel `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi`. Header comment documents the new exit codes (0/36/37/38), schema version `qa_predicate_schema_version: 1`, and the `qa_predicate_path` resolution rule.
- [ ] **`cmd_validate <file> [--ident <ENG-N>] [--worktree <path>]`.** Parse positional + flags (`--ident`, `--worktree`). On missing file → exit 38 (`qa-predicate-missing`).
- [ ] **Path-prefix authority check (D-011).** Resolve the predicate file's realpath; resolve `$PROJECT_STATE_DIR`'s realpath. If the file's realpath does not start with the prefix's realpath + `/`, emit `qa-predicate-malformed: predicate file must live under $PROJECT_STATE_DIR; got <file>` to stdout and exit 36.
- [ ] **Schema validation.** Set `_PASS_CRITERION_CALLER=qa-predicate`. Validate top-level: JSON parse error → exit 36; not an object → exit 36; `qa_predicate_schema_version != 1` → exit 37; `issue_id` missing/non-string/non-matching `^ENG-[0-9]+$` → exit 37; `--ident` cross-check → exit 37; `pass_criteria` not an array or empty → exit 37. For each criterion, call `_validate_pass_criterion "$file" 0 $ci --kinds smoke,file_exists,grep,http_get || return $?` (note: qa-predicate uses a FLAT `pass_criteria[]` array at the top level, NOT nested under `features[]` — pass feature-index `0` as the loop's `fi` arg for diagnostic positioning).
- [ ] **Per-criterion execution.** After schema validation passes, iterate `pass_criteria[]` and emit one JSONL line per criterion:
      - `smoke`: `bash -c "<command>"`; capture exit; `pass: exit == expect_exit && (expect_stdout_match == null || stdout matches expect_stdout_match)`. `detail` carries `actual_exit` on mismatch.
      - `file_exists`: anchor to `--worktree` if supplied, else `$TARGET_REPO`. `pass: [[ -e "<resolved-path>" ]]`. `detail: "missing: <path>"` on miss.
      - `grep`: anchor similarly. `grep -Eq "<pattern>" "<path>"`; `pass: (grep rc == 0) == expect_match`. `detail: "regex compile error"` on grep rc=2; `detail: "no match"` on miss-expected-true.
      - `http_get`: `curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "<url>"`. `pass: code == expect_status && (expect_body_match == null || curl --max-time 10 -sS "<url>" matches expect_body_match)`. `detail: "connection refused" | "timeout" | "got <code>"` on miss.
      JSONL line shape (per criterion): `{"index": <int>, "kind": "<kind>", "pass": <bool>, "detail": <string|null>}`.
- [ ] **Summary line.** After all criteria executed, emit a final JSONL line: `{"summary": true, "total": <int>, "passed": <int>, "failed": <int>, "duration_ms": <int>}`. `duration_ms` from `date +%s%N` deltas (BSD-portable: `$(($(date +%s%N) - START_NS)) / 1000000`); approximate is fine.
- [ ] **Return code.** ALWAYS exit 0 after the summary line is emitted (regardless of pass/fail counts) — the caller reads the summary line to decide verdict per D-008/D-012. Only schema/path-prefix violations exit non-zero (36/37/38).
- [ ] **`main` dispatch.** `case "$subcmd" in validate) cmd_validate "$@" ;; *) printf 'Usage: bash bin/verify-qa.sh validate <file> [--ident <ENG-N>] [--worktree <path>]\n' >&2; exit 36 ;; esac`. Same shape as `bin/plan-schema.sh::main`.
- [ ] `chmod +x bin/verify-qa.sh`.

### Task 7: Author `bin/verify-qa-test.sh`

- `depends_on: [6]`
- `touches: bin/verify-qa-test.sh (new)`
- [ ] **File header.** Mirror `bin/plan-schema-test.sh:1-30` setup: `set -uo pipefail`, `SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"`, `PIPELINE_DRY_RUN=1`, `LINEAR_API_KEY=test-mock-key`, mktemp fixture dir, stub `TARGET_REPO` + `PROJECT_SLUG`, `trap 'rm -rf "$FIXTURE_DIR"' EXIT`. Set `PROJECT_STATE_DIR=$FIXTURE_DIR/project-state`; place predicate fixtures under that prefix so the path-prefix check passes.
- [ ] **V-1: predicate file absent → rc=38.** `bash $VERIFIER validate "$FIXTURE_DIR/nonexistent.json"`. Assert `rc == 38`. Assert stdout contains `qa-predicate-missing`.
- [ ] **V-2: predicate file present, JSON parse error → rc=36.** Write `{,}\n` to `$PROJECT_STATE_DIR/qa-predicate-ENG-1.json`. Assert `rc == 36`. Assert stdout contains `qa-predicate-malformed`.
- [ ] **V-3: schema-incomplete (missing `pass_criteria`) → rc=37.** Write `{"qa_predicate_schema_version":1,"issue_id":"ENG-1"}`. Assert `rc == 37`. Stdout contains `qa-predicate-incomplete`.
- [ ] **V-4: valid, all pass → rc=0, summary `pass: true`.** Predicate with one `file_exists` criterion pointing at a real worktree file. Assert `rc == 0`. Last JSONL stdout line is `{"summary": true, …, "failed": 0}`.
- [ ] **V-5: valid, one smoke fails → rc=0, summary `failed >= 1`.** Predicate with a smoke criterion `command: "exit 1"`, `expect_exit: 0`. Per-criterion JSONL line has `pass: false` + `detail` naming `actual_exit: 1`. Summary line `failed: 1`.
- [ ] **V-6: valid, `file_exists` path absent → rc=0, summary `failed >= 1`.** Predicate file_exists points at a nonexistent path. Per-criterion line `pass: false`, summary `failed: 1`.
- [ ] **V-7: valid `grep` criterion matches when `expect_match: true` → rc=0, `pass: true`.** Fixture grep for a present pattern in a worktree file. Summary `failed: 0`.
- [ ] **V-8: `http_get` with stubbed curl returning 200 → rc=0, `pass: true`.** Stub `curl` in `STUB_DIR` (prepend to `$PATH`); stub returns `200\n` on `--write-out '%{http_code}'` shape. Predicate `http_get` with `expect_status: 200`. Per-criterion `pass: true`. (Mirrors `bin/linear-test.sh`'s curl-stub precedent.)
- [ ] **V-9: `--ident ENG-2` flag passed but JSON's `issue_id` is `ENG-1` → rc=37.** Stdout contains `qa-predicate-incomplete: issue_id mismatch`.
- [ ] **V-10 (D-013 path-traversal — file_exists with `../` → rc=37).** Predicate `file_exists` with `path: "../escape.txt"`. Stdout contains `path must be worktree-relative`.
- [ ] **V-11 (D-013 path-traversal — grep with absolute path → rc=37).** Predicate `grep` with `path: "/etc/passwd"`. Stdout contains `path must be worktree-relative`.
- [ ] **V-12 (D-011 path-prefix — predicate file outside `$PROJECT_STATE_DIR` → rc=36).** Write predicate at `$FIXTURE_DIR/escape/qa-predicate-ENG-1.json` (NOT under PROJECT_STATE_DIR). Stdout contains `predicate file must live under`.
- [ ] **Summary line.** End-of-test: `printf '\n━━━ Summary ━━━\nPASS: %d / FAIL: %d\n' "$PASS" "$FAIL"`; exit non-zero if `FAIL > 0`. Mirror `bin/plan-schema-test.sh`'s footer shape.

### Task 8: Insert new "Step 1: Emit verification predicate" into `AGENT_PROMPTS.md` §6

- `depends_on: [3]`
- `touches: AGENT_PROMPTS.md §6 (Your task: block)`
- [ ] **Block placement.** Locate the literal line `Your task:` inside §6's fenced block. Locate the literal line `1. **Flaky-pattern triage (first pass — BEFORE running the suite):**`. Insert the new numbered step BETWEEN these two anchors — AFTER `Your task:` + its trailing blank line, BEFORE the existing step 1's bold header. The new step is numbered `1.` and the existing steps 1-7 renumber to 2-8.
- [ ] **New step body** (prose Markdown, no fenced code blocks — §6 retains exactly 2 column-0 fences):
      ```
      1. **Emit verification predicate (MANDATORY — BEFORE any other QA work):**

         The plan stage may have emitted a structured plan.json sibling. When present, its contents are already embedded above between the `<<<PLAN_JSON_BEGIN>>>` and `<<<PLAN_JSON_END>>>` delimiters (ENG-124). Build the verification predicate from THAT embedded block — do NOT open the .json file from disk; the embedded body is authoritative for this dispatch.

         Write a JSON document via the `Write` tool at `{qa_predicate_path}` (resolved by the orchestrator to an absolute path under `$PROJECT_STATE_DIR` — outside the worktree; partition_dirty_paths will NOT see it). Document shape:

             {
               "qa_predicate_schema_version": 1,
               "issue_id": "{issue_id}",
               "pass_criteria": [
                 ...
               ]
             }

         The `pass_criteria[]` array is a SUPERSET of the plan's: (a) copy every `pass_criteria` entry from each `features[]` element of the embedded plan.json verbatim, and (b) OPTIONALLY add QA-authored smoke / file_exists / grep / http_get criteria that name additional deterministic checks for this issue. Reuse the schema-v1 `kind` taxonomy: `smoke` (`command`, `expect_exit`, optional `expect_stdout_match`), `file_exists` (`path` — worktree-relative, no leading `/`, no `../`), `grep` (`path`, `pattern`, `expect_match`), `http_get` (`url`, `expect_status`, optional `expect_body_match`).

         Overwrite-on-every-dispatch contract (§0): use `Write`; pre-existing predicate from a prior QA dispatch is replaced.

         When the embedded plan.json body reads `(no plan.json — falling back to prose plan)`, the plan stage did not emit structured data: derive `pass_criteria[]` from the prose plan's Failure Mode → Test Map and the Project profile's "Build & test gates" Test commands. The predicate file MUST still be written.

         On Decision-path D (back-fill PR — see end of section), the predicate is written with the plan's pass_criteria verbatim; QA-authored adversarial criteria are not required.

         Validate your predicate before continuing: `bash bin/verify-qa.sh validate {qa_predicate_path} --ident {issue_id}`. Read the final summary JSONL line: if `failed > 0`, address the failing checks BEFORE running the remaining numbered steps; if any per-criterion line has `pass: false`, that's QA's signal that a plan-acceptance criterion is not yet met and the appropriate response is `Decision path B` below (genuine failure → `verdict fail --target implementing`).

      ```
- [ ] **Renumber existing steps.** The current numbered list:
      - `1. **Flaky-pattern triage** …` → `2. **Flaky-pattern triage** …`
      - `2. **Run the gate commands** …` → `3. **Run the gate commands** …`
      - `3. **Coverage audit** …` → `4. **Coverage audit** …`
      - `4. **Regression-intent audit** …` → `5. **Regression-intent audit** …`
      - `5. **Adversarial testing** …` → `6. **Adversarial testing** …`
      - `6. **Bug dedup** …` → `7. **Bug dedup** …`
      - `7. **qa-patterns updates** …` → `8. **qa-patterns updates** …`
      Use `Edit` per-line (one edit per renumber) OR use `Edit --replace_all` on each canonical `N. **<bold-header>**:` pattern — both shapes are safe because each step's bold-header text is unique within §6.
- [ ] After insertion, run `grep -c '^```' AGENT_PROMPTS.md` and confirm the column-0 fence count is unchanged from pre-edit (no new fences introduced inside the §6 block).

### Task 9: Add Case O for `{qa_predicate_path}` to `bin/render-prompt-rc0-test.sh`

- `depends_on: [3, 8]`
- `touches: bin/render-prompt-rc0-test.sh (case O insertion)`
- [ ] **Locate insertion point.** Content anchor: the existing `# Case N:` block ends with its closing `fi` and a blank line. The next line is the literal `printf '\n━━━ Summary ━━━\nPASS: %d / FAIL: %d\n' "$PASS" "$FAIL"` summary footer. The new Case O block inserts BETWEEN the `fi` ending case N and the summary footer.
- [ ] **Case O (qa stage render → `{qa_predicate_path}` resolves to a concrete absolute path containing `qa-predicate-ENG-`).** Mirror case L's render-prompt-invocation shape (`bin/render-prompt-rc0-test.sh:410-440`) but substitute the assertion. Setup: `ISSUE_DIR_O="$FIXTURE_DIR/ENG-87R6X-O"`; `mkdir -p "$ISSUE_DIR_O"`. Invoke `bash $SCRIPT_DIR/render-prompt.sh qa ENG-87R6X-O 2>/dev/null > "$out_o"`. Assert `grep -qF "qa-predicate-ENG-87R6X-O.json" "$out_o"`. Pass message names ENG-113.
- [ ] **Negative control (does the resolver value reach the prompt?).** Confirm that on a STAGE that doesn't use `{qa_predicate_path}` (e.g. brainstorming — which has no §6 block at all), the resolver still binds but the token text doesn't surface (because §1's body has no `{qa_predicate_path}` literal). This is the SAME shape as ENG-140's case L regression-intent assertion for `{review_findings}`. Skip the negative control as an explicit test case if the §1 prompt body genuinely contains no `{qa_predicate_path}` literal post-edit (confirm with `grep '{qa_predicate_path}' AGENT_PROMPTS.md` — expected hits only inside the §6 fence).
- [ ] Run `bash bin/render-prompt-rc0-test.sh` standalone — all prior cases plus Case O must pass.

### Task 10: Add §6 content pin to `bin/agent-prompts-content-test.sh`

- `depends_on: [8]`
- `touches: bin/agent-prompts-content-test.sh`
- [ ] **Locate insertion point.** Content anchor: the existing `# ─── ENG-140: §3 contains the new QA → implement loopback block ───` block at lines ~103-113 ends with its closing `fi` and a blank line. The new ENG-113 pin block inserts AFTER it (the §3 pin remains a peer block; the §6 pin is a sibling at the section level). Alternative content anchor: the literal line `s6="$(section_body "## 6. QA Agent")"` is unique in the file — the new pin uses `s6` as its source, so placement near the s6 binding is also acceptable.
- [ ] **Pin body** (byte-for-byte ENG-108 shape):
      ```bash
      # ─── ENG-113: §6 contains the new "Emit verification predicate" step ───
      # The QA prompt MUST instruct the agent to emit a structured verification
      # predicate at dispatch start so the verification half of QA is scriptable
      # without invoking claude. Pin the distinctive bold-header phrase so a
      # future edit that removes the step trips here.
      if printf '%s\n' "$s6" | grep -qF 'Emit verification predicate'; then
        ok "§6 ENG-113: 'Emit verification predicate' step present"
      else
        nope "§6 ENG-113: 'Emit verification predicate' step present" \
          "literal 'Emit verification predicate' phrase missing from §6 — has the step been removed or its bold header renamed?"
      fi
      ```
- [ ] Run `bash bin/agent-prompts-content-test.sh` standalone; all prior pins plus the new one must pass.

### Task 11: Update `learned-rules/harness/project-profile.md`

- `depends_on: [7]`
- `touches: learned-rules/harness/project-profile.md::"## Build & test gates", "## Tool allowlist::implementing", "## Tool allowlist::qa"`
- [ ] **`## Build & test gates` Test line.** Locate the literal trailing fragment `&& bash bin/common-test.sh` on the Test: line. Append ` && bash bin/verify-qa-test.sh` immediately AFTER it (BEFORE the trailing italicised parenthetical `*(every bin/*-test.sh is a self-contained executable; no test runner)*`).
- [ ] **`## Tool allowlist::implementing` list.** Locate the literal terminal entry `  - \`Bash(bash bin/vocabulary-cleanliness-test.sh:*)\`` under the `- implementing:` section header. Append a new sibling list entry IMMEDIATELY AFTER it: `  - \`Bash(bash bin/verify-qa-test.sh:*)\``. Preserve list ordering (alphabetical was approximated; appending at end is acceptable for one new entry).
- [ ] **`## Tool allowlist::qa` list.** Same shape as above but under the `- qa:` section header. Append `  - \`Bash(bash bin/verify-qa-test.sh:*)\`` after the existing terminal `vocabulary-cleanliness-test.sh` entry.
- [ ] Do NOT add `Bash(bash bin/verify-qa.sh:*)` (the runner CLI) to the profile — per brainstorm D-010, that lives in `bin/dispatch.sh::allowed_tools_for`'s qa case-arm (Task 5 above) and the profile's allowlist is for *test files only* per the existing convention.
- [ ] Run `bash bin/profile-allowlist-test.sh` to confirm the allowlist parses and the new entries are tested against the on-disk file set.

### Task 12: Run the full gate suite + final TDD discipline check

- `depends_on: [2, 5, 7, 9, 10, 11]`
- `touches: (no file edits — gate suite invocation)`
- [ ] Run the profile's "Build & test gates" Test command — verbatim per the updated profile (now includes `bash bin/verify-qa-test.sh` per Task 11). Plus `bash bin/secret-probe-lint.sh bin/verify-qa.sh bin/render-prompt.sh bin/common.sh` to confirm the new code is secret-handling-compliant. Plus `bash .githooks/pre-commit` before the final commit.
- [ ] **TDD discipline.** Per §3 of AGENT_PROMPTS.md: each task with a Failure-Mode-Map row must have its `test(ENG-113): <task summary>` commit BEFORE the corresponding `feat(ENG-113): <task summary>` commit. Specifically: Task 7 (verify-qa-test.sh) is the test commit for Task 6 (verify-qa.sh). Task 9 (Case O) is the test commit for Task 3 (resolver). Task 10 (§6 pin) is the test commit for Task 8 (prompt step). Commit order across the production-code changes: (a) Task 7 test file first (RED — verify-qa.sh does not exist yet); (b) Task 6 verify-qa.sh implementation (GREEN); (c) Task 9 Case O before Task 3 resolver; (d) Task 10 pin before Task 8 prompt step. Minimum 2 commits across these task pairs. Task 1 (common.sh), Task 2 (plan-schema.sh refactor), Task 4 (pipeline-events.json), Task 5 (dispatch.sh), Task 11 (profile) are infrastructure tasks — group with the closest implementation pair to preserve test-first order.
- [ ] **Commit-message convention.** Every commit must cite `ENG-113` in the subject line.

## 6. Frontend Tasks

No frontend tasks. The harness has no UI component and no UI agent dispatches on harness-self targets. Per the project profile, the `ui` stage's allowlist is `(none)` and the harness self-hosts no frontend.

## 7. Failure Mode → Test Map

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
|---|---|---|---|---|
| Predicate file absent at validate time | `bin/verify-qa.sh validate <missing-path>` | rc=38, stdout contains `qa-predicate-missing` | unit | `verify-qa-test.sh` V-1 |
| Predicate file present, JSON parse error | Stray comma or non-object body | rc=36, stdout contains `qa-predicate-malformed` | unit | `verify-qa-test.sh` V-2 |
| Predicate file present, schema incomplete (missing `pass_criteria`) | Required top-level field absent | rc=37, stdout contains `qa-predicate-incomplete` | unit | `verify-qa-test.sh` V-3 |
| Predicate file present, all criteria pass | Well-formed predicate; file_exists points at a real file | rc=0; final JSONL summary line has `failed: 0` | unit | `verify-qa-test.sh` V-4 |
| Predicate file present, smoke command fails | Predicate smoke with `command: "exit 1"`, `expect_exit: 0` | rc=0; per-criterion line `pass: false` with `detail` naming `actual_exit`; summary `failed: 1` | unit | `verify-qa-test.sh` V-5 |
| Predicate file present, `file_exists` path absent | Predicate names a nonexistent worktree file | rc=0; per-criterion `pass: false`; summary `failed: 1` | unit | `verify-qa-test.sh` V-6 |
| Predicate file present, `grep` criterion matches when expected | Predicate `grep` for present pattern with `expect_match: true` | rc=0; per-criterion `pass: true`; summary `failed: 0` | unit | `verify-qa-test.sh` V-7 |
| Predicate file present, `http_get` to stubbed 200 endpoint | Curl stubbed; `expect_status: 200` matches | rc=0; per-criterion `pass: true`; summary `failed: 0` | unit | `verify-qa-test.sh` V-8 |
| `--ident` flag does not match JSON's `issue_id` | Stale template / wrong predicate passed | rc=37, stdout contains `qa-predicate-incomplete: issue_id mismatch` | unit | `verify-qa-test.sh` V-9 |
| D-013 path-traversal: `file_exists` with `../` | Malicious predicate asserts escape path | rc=37, stdout contains `path must be worktree-relative` | unit | `verify-qa-test.sh` V-10 |
| D-013 path-traversal: `grep` with absolute path | Malicious predicate asserts `/etc/passwd` | rc=37, stdout contains `path must be worktree-relative` | unit | `verify-qa-test.sh` V-11 |
| D-011 authority surface: predicate file outside `$PROJECT_STATE_DIR` | Operator supplies predicate from `/tmp` | rc=36, stdout contains `predicate file must live under` | unit | `verify-qa-test.sh` V-12 |
| §6 "Emit verification predicate" step silently removed by a future refactor | A future commit removes/renames the bold header | `agent-prompts-content-test.sh` ENG-113 pin trips with `nope` naming the missing phrase | unit | `agent-prompts-content-test.sh` ENG-113 pin |
| `{qa_predicate_path}` token fails to resolve on a qa render | Resolver binding broken or registry entry missing | `render-prompt-rc0-test.sh` Case O fails: rendered prompt does not contain `qa-predicate-ENG-87R6X-O.json` | unit | `render-prompt-rc0-test.sh` Case O |
| `plan-schema.sh` refactor regresses behavior | `_validate_pass_criterion` extraction changes plan-schema outputs | `plan-schema-test.sh` T1-T18 fail | unit | `plan-schema-test.sh` (existing; behavior-preserving refactor must pass) |
| `qa-predicate-invalid` halt-reason unknown to event registry | A `bash bin/pipeline.sh event verdict halt --reason qa-predicate-invalid` call rejected | `jq -e '.halt_reasons | index("qa-predicate-invalid")' bin/pipeline-events.json` returns non-null | unit | inline jq assertion in Task 4 |
| Profile's `## Build & test gates` Test line missing `bin/verify-qa-test.sh` | Implement loopback runs the gate suite; new test file silently excluded | `profile-allowlist-test.sh` (existing) catches divergence between profile-declared gate set and on-disk `bin/*-test.sh` glob | unit | `profile-allowlist-test.sh` (existing) |
| Profile's `## Tool allowlist::qa` missing `Bash(bash bin/verify-qa-test.sh:*)` | QA agent cannot invoke the test on its allowlist | Sandbox denial on the agent's `bash bin/verify-qa-test.sh` invocation — caught at dispatch-time, not by a unit test (manual repro via PIPELINE_DRY_RUN=1) | integration | manual smoke (no automated assertion — agent's runtime sandbox is the contract enforcer) |

## 8. Test Strategy

**Unit (the primary surface):**

- `bin/verify-qa-test.sh` cases V-1 through V-12 cover every documented exit code (0/36/37/38), every kind (smoke/file_exists/grep/http_get), the D-011 path-prefix authority surface, the D-013 path-traversal hardening, and the `--ident` cross-check. Mirrors `bin/plan-schema-test.sh`'s T1-T18 structure: source-and-stub pattern (CLAUDE.md "How tests work"), mktemp fixture dir, per-rc assertions with `printf`-driven JSON fixture files. The curl-stub pattern (V-8) mirrors `bin/linear-test.sh`'s existing precedent — no new test-time dependency added.
- `bin/render-prompt-rc0-test.sh` Case O covers the path-token resolver. Mirrors cases L/M/N (ENG-140) for the per-issue fixture-dir pattern and the per-case literal sentinel approach.
- `bin/agent-prompts-content-test.sh` ENG-113 pin covers the §6 prompt step's presence; mirrors the ENG-108 / ENG-140 pin shape.
- `bin/plan-schema-test.sh` (existing) re-runs unchanged and validates the behavior-preserving refactor. T1-T18 must remain green; their failure on the rebase would indicate the `_validate_pass_criterion` lift broke the per-criterion validation for plan-contract callers.

**Integration:** None new. The `PIPELINE_DRY_RUN=1 TARGET_REPO=… bash bin/dry-run.sh` path through `run-stage.sh` does not exercise the verify-qa.sh CLI today (it's not wired into the post-dispatch detective — that's the next sub-ticket per D-010). Manual repro of the verify-qa.sh CLI from operator console is the integration test for this iteration: `bash bin/verify-qa.sh validate $(issue_dir ENG-N)/qa-predicate-ENG-N.json --ident ENG-N` after a QA dispatch.

**Smoke / E2E:** None. The harness has no smoke / E2E gates beyond the bash test suite. The `bin/dry-run.sh` path is the closest analogue and does not yet exercise verify-qa.sh.

**Adversarial coverage (delegated to QA stage):** The QA agent's §6 step 6 (post-renumber: "Adversarial testing") will write QA-authored adversarial cases for verify-qa.sh — sub-agent-discovered failures map to additional V-* cases in a follow-up ticket. ENG-113 ships the deterministic floor (V-1..V-12); QA adversarial coverage builds on top.

**Test-gate closure (REMOVE-side sweep — feasibility persona):** No tokens are removed from production code by this plan. The `plan-schema.sh` refactor moves the per-criterion case body into `common.sh::_validate_pass_criterion` but the case body's *behavior* is preserved verbatim; no sibling test file pins a token that disappears.

**Test-gate closure (ADD-side sweep):** `bin/verify-qa-test.sh` is a NEW file under the `bin/*-test.sh` glob. Per the ENG-122 closure rule, `learned-rules/harness/project-profile.md` MUST appear in File Structure with a task updating both `## Build & test gates` and `## Tool allowlist::implementing|qa`. Task 11 does exactly this.

## 9. Plan-vs-ship drift (post-ship audit — m10 from review iter-2)

The plan above was authored against the dff490c base; rebase + two review iterations introduced drift each intentionally taken but worth recording as a faithful ship-state mirror.

- **Exit codes 36/37/38 → 39/40/41** (drift documented in commit 8df8fef): codes 36/37/38 were already held by ENG-119 (review-payload-malformed/incomplete/missing). To avoid collision, the qa-predicate triplet moved to the next unused range. `failure_outcome_for_exit` in `bin/common.sh` carries the new mapping.
- **`_PASS_CRITERION_CALLER` env var → `--caller` flag (iter-1) → dropped entirely (iter-2)**: the iter-1 review flagged the env-var as a hidden contract; it was converted to a `--caller` flag. The iter-2 review (M7) flagged the flag as YAGNI because it only flipped a diagnostic prefix string the caller already knows. Final shape: `_validate_pass_criterion` sets `$_VALIDATE_CRIT_DIAG` on rc=34; each caller prepends its own `<contract>-incomplete:` prefix.
- **`duration_ms` → `duration_s`** (drift documented in commit 8df8fef): the iter-1 review showed the millisecond field was actually `seconds × 1000` (always 0/1000/2000); the field was renamed and the unit corrected to match its denominator. `bin/verify-qa-test.sh` V-17 pins this.
- **`_QA_PREDICATE_MAX_CRITERIA=64` cap removed (iter-2 M8)**: replaced with `_QA_PREDICATE_MAX_BYTES=65536` byte-size cap at the authority phase. The criteria-count cap did not bound wall-clock (64×60s smoke = 64 min, past the 30 min dispatch watchdog) — bytes-per-parse is the cost that actually matters for DoS. V-16 was rewritten accordingly.
- **`_resolve_inside_anchor` hand-rolled walker → `_canonical_path` (grealpath -m / realpath -m)** (iter-2 C2+M6): the walker resolved at most ONE symlink hop, leaving `a -> b -> /etc/passwd` chain bypass open. `realpath -m` canonicalises the full chain in a single call. macOS BSD `realpath` lacks `-m`; the helper prefers Homebrew coreutils' `grealpath` (already required for the existing gtimeout dependency).
- **Single-curl http_get** (iter-2 M9): the prior shape did two curl requests (`-o /dev/null` for status, then a separate body fetch). A/B-tested servers can return different bodies between the two requests; the new shape uses `curl -o "$body_tmp" -w '%{http_code}'` once and greps the temp.
- **TOCTOU snapshot to `$PROJECT_STATE_DIR/.verify-qa-snap/predicate.XXXXXX`** (iter-2 M5): schema validation and execution now read the same bytes (snapshot-then-validate-then-execute).
- **`--worktree` fence widened + auto-derive** (iter-2 C1): pre-fix fence rejected every per-issue worktree because the path lives at `$PROJECT_STATE_DIR/<ident>/worktree`, not under `$TARGET_REPO`. Accept-list now includes `$PROJECT_STATE_DIR` subpaths; when `--worktree` is omitted, the validator auto-derives from `PIPELINE_ISSUE_ID`. AGENT_PROMPTS.md §6 invokes without `--worktree`, so the auto-derive is what makes the documented invocation work.
- **C4 host-class denylist** (iter-2): added a `_url_host_class_denied` gate to `_validate_pass_criterion`'s `http_get` arm; rejects loopback, RFC1918, link-local, IMDS (`169.254.169.254`), and IPv6 ULA hosts. The brainstorm threat model named "no out-of-worktree access" but did not enumerate host-class; this is a deny-by-default tightening within that intent. A `plan_gap` follow-up was filed so the brainstorm catches up.
