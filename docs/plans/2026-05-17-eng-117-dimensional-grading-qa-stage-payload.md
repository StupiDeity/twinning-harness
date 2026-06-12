---
linear: ENG-117
date: 2026-05-17
topic: QA-stage dimensional grading — sibling verdict-qa.json + schema validator + post-dispatch detective
---

# Plan — Dimensional grading: qa-stage payload (ENG-117)

## Anti-anchoring check

- **Problem (operator-perspective):** "QA today exits with one bit of structured signal (a pass/fail/halt verdict marker); the per-dimension reasoning ('coverage was strong, but adversarial testing was thin') lives in prose and is lost to (a) the retrospective, (b) the threshold-logic sub-ticket that wants to gate on dimensional minimums, and (c) operators triaging why a qa pass actually represents." ENG-31 names this; ENG-117 is the producer foundation.
- **Brainstorm framing:** matches the problem one-for-one. Ship a sibling `verdict-qa.json` whose shape is the single source of truth for "what did qa grade and how," plus a post-dispatch detective that halts loudly when the file is missing/malformed. No readers (deferred to the threshold sub-ticket). No new prompt-side vocabulary beyond one new halt-reason and three new exit codes.
- **Proportionality:** one new helper script (`bin/qa-payload-schema.sh`), two new sibling tests (unit + adversarial), one new validator function pair (`_validate_qa_payload` + `_post_qa_payload_halt`) inserted next to ENG-122's plan-contract validator in `bin/run-stage.sh`, three new exit codes (36/37/38 — the first free slots after 35), one new halt-reason (`qa-payload-invalid`), one extension to `_clear_current_stage_slots` (one line), one §6 AGENT_PROMPTS update (step 8 + Output bullet), one allowlist enumeration update to the harness-self project profile. ≤ 5 functions touched in production code. Proportional. Proceed.

## Goal

QA-stage dispatches MUST produce a sibling `$(issue_dir <ENG-N>)/verdict-qa.json` describing per-dimension scores + rationale + thresholds-met booleans; a post-dispatch validator (`bin/run-stage.sh::_validate_qa_payload`, gated to `stage=qa`) shells out to a new `bin/qa-payload-schema.sh validate` CLI to enforce schema-v1 shape and halts the dispatch with halt-reason `qa-payload-invalid` (exit codes 36 = malformed, 37 = incomplete, 38 = missing-file) when the JSON is absent/malformed — so dimensional reasoning becomes a typed, enumerable artifact for the threshold-logic and retrospective sub-tickets to read at the next layer.

## Assumption Inventory

Format: `[verified|assumed]` ITEM — `path:line` reference.

**branch-base freshness:** `HEAD..origin/main` is NON-EMPTY at plan time (15 commits across three sibling tickets — ENG-138, ENG-110, ENG-144). Upstream-file deltas:

- ENG-138 (`444e752`/`5d35654`/`8882d95`/`e87c383`/`3ae45a4`/`706130d`/`ec96a01`/`ee3d62a`): edits `bin/guards.sh`, adds `bin/guards-test.sh` + `bin/guards-adversarial-test.sh`, edits `bin/run-stage.sh` (8 lines at `main`'s `guards.sh check` call — line range 1235-1242 only, far from this plan's insertion points at ~line 1085 and ~line 1836), `CLAUDE.md` (one Failure-Mode quick-ref row), plus a new ENG-138 brainstorm/plan pair.
- ENG-110 (`9b2fd80`/`ece2047`/`1c19a13`/`7fbc8b0`/`1533f00`): widens `bin/run-stage.sh::_validate_dispatch_envelope` (lines ~977-988) bypass-pattern list from 2 to 6, edits `bin/linear-test.sh` (agent-lane fixture), edits `AGENT_PROMPTS.md` ONE line in §0 preamble (line ~225 — NOT §6 QA Agent body, no overlap).
- ENG-144 (`d465849`/`15e2f01`): edits `AGENT_PROMPTS.md` §2 PLANNING agent (NOT §6 QA), edits `bin/agent-prompts-content-test.sh`. The commit message explicitly cites that THIS issue (ENG-117) halted at rc=29 because §2's progress.md prose was wrong; ENG-144 fixed that, and the operator resumed ENG-117 via `--action continue` (commit `ae81226` on this branch).

**Conflict analysis:** None of these touch §6 QA Agent's body (this plan's main AGENT_PROMPTS target), `_post_plan_contract_halt` or `_clear_current_stage_slots` (this plan's main run-stage.sh targets), `bin/common.sh::failure_outcome_for_exit`, `bin/pipeline-events.json::halt_reasons`, or any of the new files this plan creates. ENG-110's widening of `_validate_dispatch_envelope` shifts the byte offset of `_post_plan_contract_halt`'s definition (and consequently this plan's `_validate_qa_payload` insertion point) downward, but the CONTENT anchors (the literal `_post_plan_contract_halt() {` heading, the `# ENG-122: plan-contract validator. Post-dispatch; planning stage only.` block-comment, the `# Push branch BEFORE posting the completion comment` block-comment) remain unique in the file post-rebase. Clean drift.

**Task 0** rebases onto `origin/main` before any other implement work and re-verifies the `path:line` excerpts below. Pin: `origin/main = 15e2f01` at plan time.

### Verified — code paths quoted from current tree

- `[verified]` `bin/common.sh:68-72` — `issue_dir <ENG-N>` returns `$PROJECT_STATE_DIR/<ENG-N>`. `_validate_qa_payload` reads `$(issue_dir "$ident")/verdict-qa.json`; uses the same resolution.

- `[verified]` `bin/common.sh:245-279` — `failure_outcome_for_exit` table. Exit codes 0/10–35 + 124 mapped today; codes 36/37/38 are unallocated. Insertion point: AFTER the line `35) printf 'plan-contract-missing' ;;` (line 275) and BEFORE `124) printf 'dispatch-timeout' ;;` (line 276). Content anchor: the literal `35) printf 'plan-contract-missing' ;;` is unique in the file.

- `[verified]` `bin/run-stage.sh:931-939` — `_clear_current_stage_slots`. Removes `stage-summary-${stage}.md` and `wait-${stage}.json` from `$issue_dir` on every dispatch-start. Insertion point: BETWEEN the `rm -f "$d/wait-${stage}.json"` line (937) and the closing `return 0` (938). Content anchor: the literal `rm -f "$d/wait-${stage}.json"        2>/dev/null || true` is unique in the file.

- `[verified]` `bin/run-stage.sh:1036-1072` — `_validate_plan_contract` function (ENG-122). The architectural precedent that `_validate_qa_payload` mirrors closely: schema-out capture, exit-code switch, three halt branches + an unexpected-rc catch-all calling `_post_plan_contract_halt`. Content anchor: the comment `# ENG-122: plan-contract validator.` (line 1032) is unique in the file.

- `[verified]` `bin/run-stage.sh:1077-1084` — `_post_plan_contract_halt` function. Architectural precedent for `_post_qa_payload_halt`: sanitises `<!--` → `<\!--` in the raw validator output, wraps in `~~~` fenced block, posts via `bash "$SCRIPT_DIR/linear.sh" add-comment`. Content anchor: the comment `# Posts a halt comment for a plan-contract violation.` (line 1074) is unique in the file. The new `_post_qa_payload_halt` is defined IMMEDIATELY AFTER the closing `}` of `_post_plan_contract_halt` (~line 1084) AND BEFORE the next function definition (search for the next blank-line-`function-name(`-pair).

- `[verified]` `bin/run-stage.sh:1819-1835` — caller block for `_validate_plan_contract` (ENG-122 post-dispatch hook). Architectural precedent for the new qa caller block. Content anchor: the comment `# ENG-122: plan-contract validator. Post-dispatch; planning stage only.` (line 1819) is unique in the file. The new qa caller block is inserted IMMEDIATELY AFTER the `fi` closing line 1835 AND BEFORE the comment `# Push branch BEFORE posting the completion comment so any …` (line 1837). Content anchor: the literal `# Push branch BEFORE posting the completion comment` is unique in the file.

- `[verified]` `bin/run-stage.sh:1321` — `_clear_current_stage_slots` caller in `main()`. Lives inside `if (( ! skip_dispatch ))` block at line 1316. The extension in Task 1 (adding `rm -f verdict-${stage}.json`) is invoked here on EVERY dispatch — already correctly scoped; no change at the call site.

- `[verified]` `bin/run-stage.sh:4-21` — top-of-file exit-code legend. Insertion point: AFTER the line `35=plan-contract-missing (no sibling .json alongside plan .md; ENG-122),` (line 20) AND BEFORE the line `124=dispatch-timeout (gtimeout SIGTERM'd a wedged claude -p — ENG-48).` (line 21). Content anchor: the literal `35=plan-contract-missing (no sibling .json alongside plan .md; ENG-122),` is unique in the file.

- `[verified]` `bin/pipeline-events.json:10-21` — `halt_reasons` array. Currently 10 entries ending with `"plan-contract-invalid"` on line 20. New entry `"qa-payload-invalid"` appended as the 11th. Content anchor: the literal `"plan-contract-invalid"` on line 20 is unique in the file.

- `[verified]` `bin/plan-schema.sh:1-297` — the template `bin/qa-payload-schema.sh` mirrors. Header comment carries the canonical schema-v1 shape (lines 1-36); flag-parsing idiom at lines 64-79; per-required-field jq existence+type checks at lines 100-146; iteration over array fields at lines 150-270; unknown-field sweep at lines 272-279; sentinel at line 297.

- `[verified]` `AGENT_PROMPTS.md:1322` — `## 6. QA Agent` header. Fenced block opens at line 1324 (` ``` ` column-0). Fenced block closes at line 1515 (` ``` ` column-0). `## 7. Build Agent` header at line 1517 confirms terminator. The `render-prompt.sh::extract_block`'s "exactly 2 fences" invariant is preserved — the new step 8 + Output bullet are plain prose, no nested column-0 fences.

- `[verified]` `AGENT_PROMPTS.md:1481-1493` — `Output:` bullet list inside §6. Today enumerates 5 bullets: PR summary comment, Linear summary comment, test commits, no edits to qa-patterns.md, progress.md entry. The new `verdict-qa.json` bullet is appended as the 6th bullet, BEFORE the `**Append a progress.md entry**` bullet (line 1486). Content anchor: the literal `- No edits to qa-patterns.md (use the candidate marker comment).` (line 1485) is unique in the file.

- `[verified]` `AGENT_PROMPTS.md:1373` — `Your task:` heading for §6 QA Agent. Steps numbered 1-7 today (lines 1375-1425). The new step 8 is inserted AFTER step 7 (`qa-patterns updates (PROPOSE, do not write):` block ending at line 1425) AND BEFORE the `Quality gates (must all be true to advance):` heading (line 1427). Content anchor: the literal `Quality gates (must all be true to advance):` is unique in the file.

- `[verified]` `AGENT_PROMPTS.md:1494-1514` — verdict-marker emission protocol for §6 (the LAST step). New step 8 is inserted BEFORE this block; the marker emission remains the agent's terminal action.

- `[verified]` `AGENT_PROMPTS.md:1509-1510` — agent-facing halt-reason allowlist: `where <reason> is one of: agent-blocked | smoke-failed | iteration-exhausted | scope-violation | protocol-violation | dispatch-timeout | pr-opened-too-early`. This is the AGENT-emittable allowlist; `qa-payload-invalid` is ORCHESTRATOR-emitted (`_post_qa_payload_halt`, not via `pipeline.sh event`), so the agent allowlist is **deliberately NOT extended** (mirrors the ENG-122 plan precedent at the same paragraph).

- `[verified]` `bin/run-stage.sh:1797-1817` — `_validate_dispatch_envelope` caller block in `main()`. The new qa-payload validator sits AFTER the envelope validator AND AFTER the ENG-122 plan-contract block (line 1819-1835). Ordering: envelope (all stages) → plan-contract (stage=planning) → qa-payload (stage=qa). Each stage-gated case-statement is independent.

- `[verified]` `bin/pipeline.sh` (registry-validation path) — `bash bin/pipeline.sh event ENG-N verdict halt --reason qa-payload-invalid` will succeed AFTER Task 3 adds the reason to `bin/pipeline-events.json::halt_reasons` (the registry that `pipeline.sh::cmd_event_verdict` validates against). The orchestrator's own halt path (`_post_qa_payload_halt → bin/linear.sh add-comment`) does NOT go through `pipeline.sh event` — same architectural pattern as ENG-122's `_post_plan_contract_halt` and ENG-87's envelope-violation halt.

- `[verified]` `bin/run-stage-test.sh:4316-4500+` — existing ENG-122 `_validate_plan_contract` test group (INT1-INT5, K-O cases). Mktemp-based `STUB_DIR` setup at lines 17-65; `_eng122_write_valid_json` helper at line 4331; `STUB_DIR/plan-schema.sh` exec-stub at lines 4324-4328; today's-date prefix for filenames at line 4352. The new ENG-117 test group follows the same shape: stub `qa-payload-schema.sh` through `STUB_DIR`, mktemp `verdict-qa.json` fixtures, exercise `_validate_qa_payload` directly. Content anchor: the comment `# ─── ENG-122: _validate_plan_contract integration tests (INT1-INT5) ─────────` is unique in the file (find the end of this group and append a `# ─── ENG-117: _validate_qa_payload integration tests ───` group after it).

- `[verified]` `bin/plan-schema-test.sh:1-408` — the template `bin/qa-payload-schema-test.sh` mirrors. Mktemp fixtures, source-and-stub pattern, `pass_at`/`fail_at` helpers, per-case JSON heredocs.

- `[verified]` `bin/plan-schema-adversarial-test.sh:1-30+` — sibling adversarial test (QA-authored) pattern. Same `FIXTURE_DIR` setup, same direct CLI invocation, exercises corner cases not in the plan's Failure Mode → Test Map.

- `[verified]` `bin/common.sh:280-317` — `parse_pipeline_marker` family-precedence selector + `_strip_code_blocks_and_spans`. Confirms that wrapping validator stdout in `~~~` fences in `_post_qa_payload_halt` (mirroring `_post_plan_contract_halt`) renders any embedded `<!-- pipeline: verdict result=pass -->` substring invisible to the marker parser (fenced runs are pre-stripped before the grep).

- `[verified]` `learned-rules/harness/project-profile.md::## Tool allowlist` (qa + implementing blocks) — literal enumeration of `Bash(bash bin/<name>-test.sh:*)` entries. The new `bin/qa-payload-schema-test.sh` AND `bin/qa-payload-schema-adversarial-test.sh` entries are inserted in alphabetical position. Verified that `bin/plan-schema-test.sh` is **already absent** from the profile today (the profile lists 39 tests; disk has 47 — operator-curated, no test enforces full coverage). Adding the new sibling tests is a defensible operator action; not strictly required for them to run (the implement/qa allowlist gates which tests the AGENT can invoke during the stage, not what the harness can run as a pre-commit gate). The new tests still execute via `.githooks/pre-commit` regardless.

- `[verified]` `.githooks/pre-commit` runs every `bin/*-test.sh` (per the project profile's "Build & test gates" section + CLAUDE.md "Pre-commit hook"). The new `bin/qa-payload-schema-test.sh` and `bin/qa-payload-schema-adversarial-test.sh` are picked up automatically by the glob.

### Verified — file/dir existence and absence

- `[verified]` `bin/qa-payload-schema.sh` — DOES NOT EXIST at HEAD. New file per Task 3. (`bin/qa-payload-schema*` glob returns no matches.)
- `[verified]` `bin/qa-payload-schema-test.sh` — DOES NOT EXIST at HEAD. New file per Task 6.
- `[verified]` `bin/qa-payload-schema-adversarial-test.sh` — DOES NOT EXIST at HEAD. New file per Task 7.
- `[verified]` `jq` is required infrastructure per the project profile's Stack section; available unconditionally; no new preflight needed.

### Assumed — to be verified during implement

- `[assumed]` The qa agent writes the JSON via the implicit `Write` tool. `Write` is in the stage-agnostic core allowlist per the Project profile addendum preamble; no new tool entry needed.

- `[assumed]` `bin/poll.sh::_poll_classify_labels` already routes `pipeline:halted` + `pipeline:skip-until-human-acts` into the `slot:"vacate", operator_action_required:true` branch (CLAUDE.md "Slot-occupancy contract"). Adding a new halt-reason token does NOT require a new classifier branch — same as the ENG-122 plan-contract precedent.

- `[assumed]` `classify_failure "$ident" "$stage" "skip-until-human-acts" "<msg>" 36/37/38` applies `pipeline:halted` via the orchestrator's classify-failure pipeline. Verify against the existing 33/34/35 caller in `bin/run-stage.sh:1828-1832`; if the policy hand-off is materially different for 36/37/38 (no reason to think it would be — they're additional integer codes in the same taxonomy), the implement agent halts with `agent-blocked` and posts a Linear comment naming the divergence.

## File Structure

### Modified

- `bin/run-stage.sh` — (a) extend `_clear_current_stage_slots:931-939` to also `rm -f "$d/verdict-${stage}.json"`; (b) define `_validate_qa_payload()` + `_post_qa_payload_halt()` IMMEDIATELY AFTER `_post_plan_contract_halt`'s closing `}` (~line 1084) AND BEFORE the next function definition; (c) add a `case "$stage" in qa) … esac` caller block in `main`'s post-dispatch hook section, IMMEDIATELY AFTER the `fi` terminating ENG-122's plan-contract caller block (~line 1835) AND BEFORE the comment `# Push branch BEFORE posting the completion comment …` (~line 1837); (d) extend the top-of-file exit-code legend with 36/37/38 entries.

- `bin/common.sh` — extend `failure_outcome_for_exit`'s case statement with three new arms (36/37/38 → `qa-payload-malformed | qa-payload-incomplete | qa-payload-missing`), inserted AFTER the `35) printf 'plan-contract-missing' ;;` line and BEFORE the `124) printf 'dispatch-timeout' ;;` line.

- `bin/pipeline-events.json` — append `"qa-payload-invalid"` as the 11th entry of the `halt_reasons` array (after `"plan-contract-invalid"`).

- `AGENT_PROMPTS.md` — extend §6 QA Agent with: (a) a new step 8 (`Emit dimensional grading payload (verdict-qa.json)`) inserted AFTER step 7's body (~line 1425) AND BEFORE the `Quality gates (must all be true to advance):` heading (~line 1427); (b) one new `Output` bullet naming the file path + overwrite contract, inserted AFTER the `- No edits to qa-patterns.md (use the candidate marker comment).` bullet (~line 1485) AND BEFORE the `- **Append a `progress.md` entry**` bullet (~line 1486).

- `bin/run-stage-test.sh` — append a new test group `# ─── ENG-117: _validate_qa_payload integration tests ───` AFTER the closing of the ENG-122 plan-contract group (the last `pass_at "ENG-122 INT5 …"` / `fail_at "ENG-122 INT5 …"` block). New cases: 117-A through 117-F (clean / missing / malformed / incomplete / sanitisation / stage-gate).

- `learned-rules/harness/project-profile.md` — under `## Tool allowlist`, insert `Bash(bash bin/qa-payload-schema-test.sh:*)` AND `Bash(bash bin/qa-payload-schema-adversarial-test.sh:*)` (alphabetical order) into BOTH the `implementing:` and `qa:` blocks. Mirrors the literal-enumeration pattern already in place.

- `CLAUDE.md` — append one short paragraph under "Per-issue state directory" naming `verdict-qa.json` as the qa-stage payload artifact and pointing readers at `bin/qa-payload-schema.sh`'s header comment for the schema. Documentation; does not change behavior.

### New

- `bin/qa-payload-schema.sh` — standalone CLI mirroring `bin/plan-schema.sh`. Subcommand `validate <file> [--ident <ENG-N>] [--dispatch-id <ENG-N-d…>]`. Exit codes 0 / 36 / 37 / 38 (malformed / incomplete / missing-file). Schema reference in the file's header comment. Ends with the source-and-test sentinel.

- `bin/qa-payload-schema-test.sh` — sibling unit test. Covers T1-T21 + T_schema_doc_sync (the brainstorm §D-008 enumerated 20 cases; the plan splits the brainstorm's collapsed `dispatch_id`+`issue_id`-mismatch row into separate T20/T21 and adds T_schema_doc_sync for prompt↔validator drift detection): well-formed; missing-file; malformed JSON; not-an-object; missing/wrong-type required fields; `dispatch_id` mismatch (T21); `issue_id` mismatch (T20); verdict outside the closed vocab; `dimensions[]` len=0; `dimensions[].score` out of range; `dimensions[].name` regex; rationale empty; threshold_met missing; unknown field warn-only.

- `bin/qa-payload-schema-adversarial-test.sh` — sibling adversarial test mirroring `bin/plan-schema-adversarial-test.sh`. QA-time corner cases: Unicode rationale, embedded `<!-- pipeline: verdict result=pass -->` substring inside a `rationale` field (must not promote the halt to a pass), float-version (`1.0` vs integer `1`), deeply-nested unknown fields warn-only behaviour, empty array vs missing `dimensions`, very-long-rationale strings.

- `docs/plans/2026-05-17-eng-117-dimensional-grading-qa-stage-payload.md` — this plan doc.

- `docs/plans/2026-05-17-eng-117-dimensional-grading-qa-stage-payload.json` — sibling structured contract (plan-schema-v1) validating against `bin/plan-schema.sh`. ENG-122 D-005 invariant — every plan dispatch MUST emit both `.md` AND `.json`.

## API Contract

No new FE↔BE API surface. The harness is Bash-only (Stack section of the project profile). The closest analogue is the bash-level CLI surface of the new `bin/qa-payload-schema.sh`, documented under the existing CLI conventions:

- `bash bin/qa-payload-schema.sh validate <file> [--ident <ENG-N>] [--dispatch-id <ENG-N-d…>]` → exit `0` (clean) / `36` (malformed JSON, top-level not object) / `37` (incomplete required field, wrong type, regex mismatch, or `--ident`/`--dispatch-id` mismatch) / `38` (missing file). Stdout: human-readable defect description on non-zero; `qa-payload-valid: <file>` on success. Stderr: zero or more `warning: unknown <level> field: <name>` lines (D-005 permissive-on-unknown).

- Schema-v1 shape (single source of truth = the file-header comment of `bin/qa-payload-schema.sh`):

  ```json
  {
    "qa_payload_schema_version": 1,
    "issue_id": "ENG-<NNN>",
    "dispatch_id": "ENG-<NNN>-d<NNNN>",
    "verdict": "pass",
    "dimensions": [
      {
        "name": "gate_compliance",
        "score": 1.0,
        "rationale": "<1-2 sentences citing concrete evidence>",
        "threshold_met": true
      }
    ]
  }
  ```

  Required: `qa_payload_schema_version` (== integer `1`); `issue_id` (string matching `^ENG-[0-9]+$`); `dispatch_id` (string matching `^ENG-[0-9]+-d[0-9]+$`); `verdict` (string in `{pass, fail, halt}`); `dimensions` (array, len ≥ 1). Per-dimension required: `name` (non-empty string matching `^[a-z][a-z0-9_]*$`); `score` (number, `0.0 ≤ x ≤ 1.0`); `rationale` (non-empty string); `threshold_met` (boolean). Unknown fields at any level → exit 0 + stderr warning (D-005 permissive readers).

## Backend Tasks

### Task 0: Rebase onto origin/main

- `depends_on: []`
- `touches: working tree (no source edits)`
- [ ] Run `git fetch origin main` (sandbox-allowed; `Bash(git fetch:*)` is in the core git family).
- [ ] Run `git rebase origin/main`. Expected: clean fast-forward / 3-way merge. The upstream commits at plan time (`origin/main = 15e2f01`) are ENG-138 (guards-stage scoping; touches `bin/guards.sh` + `bin/run-stage.sh` line 1235 only — far above this plan's insertion points at ~line 1085 and ~line 1836), ENG-110 (widens `bin/run-stage.sh::_validate_dispatch_envelope` from 2 to 6 bypass patterns at lines ~977-988 + one-line edit to `AGENT_PROMPTS.md §0` preamble line ~225 — neither overlaps with this plan's targets), and ENG-144 (edits `AGENT_PROMPTS.md §2 planning agent` prose + `bin/agent-prompts-content-test.sh` regression loop — does NOT touch §6 QA). No overlap with this plan's File Structure.
- [ ] Re-verify each `path:line` excerpt in Assumption Inventory by `Grep`ing for the named content anchors (`# ENG-122: plan-contract validator.`, `35) printf 'plan-contract-missing' ;;`, `"plan-contract-invalid"`, `rm -f "$d/wait-${stage}.json"`, `# Push branch BEFORE posting the completion comment`, `- No edits to qa-patterns.md`, `Quality gates (must all be true to advance):`, `## 6. QA Agent`, `_post_plan_contract_halt() {`). Each anchor MUST resolve to exactly one match post-rebase. If any anchor moves to a different line, the content-anchor approach below survives — line-number hints are informational only.
- [ ] If a conflict arises (unexpected — none of the changed upstream files overlap with this plan's insertion points beyond `bin/run-stage.sh`'s far-upstream `_validate_dispatch_envelope` widening and `guards.sh check` call), STOP and run `bash bin/pipeline.sh event ENG-117 verdict halt --reason agent-blocked` with a one-line Linear comment naming the conflict file.

### Task 1: Extend `_clear_current_stage_slots` to clear `verdict-${stage}.json`

- `depends_on: [0]`
- `touches: bin/run-stage.sh::_clear_current_stage_slots`
- [ ] In `bin/run-stage.sh`, locate `_clear_current_stage_slots` (anchor: the function opens at `_clear_current_stage_slots() {`, line 931 today). Insert one new line AFTER `rm -f "$d/wait-${stage}.json"        2>/dev/null || true` (anchor: this literal line is unique in the file) AND BEFORE `return 0`:

  ```bash
    rm -f "$d/verdict-${stage}.json"     2>/dev/null || true
  ```

  This generalises the ENG-87 clear-on-dispatch-start primitive so the parallel review-payload sub-ticket (sibling) reuses it as a near-no-op — the `${stage}` placeholder already parametrises the filename per stage. Belt-and-braces with the `dispatch_id` cross-check in Task 3's validator (orthogonal failure modes — see brainstorm §D-006 mitigation table).

### Task 2: Add exit-code taxonomy entries (36/37/38)

- `depends_on: [0]`
- `touches: bin/common.sh::failure_outcome_for_exit, bin/run-stage.sh (top-of-file legend)`
- [ ] In `bin/common.sh::failure_outcome_for_exit`, locate the `case "$exit_code" in` block (anchor: the literal line `35) printf 'plan-contract-missing' ;;` is unique in the file). Insert three new case arms AFTER it AND BEFORE the `124) printf 'dispatch-timeout' ;;` line:

  ```bash
    36) printf 'qa-payload-malformed' ;;
    37) printf 'qa-payload-incomplete' ;;
    38) printf 'qa-payload-missing' ;;
  ```

- [ ] In `bin/run-stage.sh`'s top-of-file exit-code legend (anchor: the literal `35=plan-contract-missing (no sibling .json alongside plan .md; ENG-122),` on line 20 is unique in the file). Insert three new entries AFTER that line AND BEFORE the `124=dispatch-timeout (gtimeout SIGTERM'd a wedged claude -p — ENG-48).` line:

  ```bash
  #             36=qa-payload-malformed (verdict-qa.json fails jq parse; ENG-117),
  #             37=qa-payload-incomplete (verdict-qa.json parses but missing required field; ENG-117),
  #             38=qa-payload-missing (no verdict-qa.json post-qa-dispatch; ENG-117),
  ```

### Task 3: Register the halt-reason token

- `depends_on: [0]`
- `touches: bin/pipeline-events.json::halt_reasons`
- [ ] Append `"qa-payload-invalid"` as the 11th entry of the `halt_reasons` array in `bin/pipeline-events.json` (anchor: the literal `"plan-contract-invalid"` is currently the last entry on line 20). Add a comma after the existing last entry and append the new entry:

  ```json
  "plan-contract-invalid",
  "qa-payload-invalid"
  ```

- [ ] Smoke: `jq '.halt_reasons | length' bin/pipeline-events.json` returns `11`. `jq -e '.halt_reasons | index("qa-payload-invalid") != null' bin/pipeline-events.json` exits 0.

### Task 4: Create `bin/qa-payload-schema.sh` validator CLI

- `depends_on: [2, 3]`
- `touches: bin/qa-payload-schema.sh (new)`
- [ ] Create `bin/qa-payload-schema.sh` with the project-standard preamble: `#!/usr/bin/env bash`, header comment, `set -euo pipefail`, `SCRIPT_DIR=…`, `source "$SCRIPT_DIR/common.sh"`. Mirror the file shape of `bin/plan-schema.sh` (1-297).

- [ ] Header comment: include the canonical schema-v1 JSON shape AS A FENCED JSON BLOCK (column-0 inside the comment is fine — this file is not parsed by `render-prompt.sh`). This block is the single source of truth; the AGENT_PROMPTS §6 step 8 inline schema in Task 7 reproduces it as plain prose (NO column-0 ``` fences inside §6, per CLAUDE.md "AGENT_PROMPTS.md is load-bearing").

- [ ] Implement `cmd_validate <file> [--ident <ENG-N>] [--dispatch-id <ENG-N-d…>]`:
  - [ ] Parse flags via the same `while [[ $# -gt 0 ]]; do case … esac; done` idiom as `bin/plan-schema.sh:60-79`. Add `--dispatch-id` alongside `--ident`. Unknown flag → emit to stderr, return 36.
  - [ ] If `<file>` does not exist → emit `qa-payload-missing: file not found: <path>` to stdout, return 38.
  - [ ] `jq -r 'type' "$file"` — capture stderr+rc. Non-zero rc → emit `qa-payload-malformed: JSON parse error: <stderr>`, return 36. Non-object top-level → emit `qa-payload-malformed: top-level JSON is not an object (got: <type>)`, return 36.
  - [ ] Required top-level field checks (mirror `bin/plan-schema.sh:100-146`):
    - `qa_payload_schema_version` MUST be integer-typed AND `== 1`. Reject string `"1"`, float `1.5`, missing, etc. → return 37.
    - `issue_id` MUST be a string matching `^ENG-[0-9]+$` → return 37 on mismatch.
    - If `--ident <ENG-N>` was supplied, assert `.issue_id == <ENG-N>` → return 37 with `issue_id mismatch: JSON has 'X' but --ident 'Y' was passed (stale template?)`.
    - `dispatch_id` MUST be a string matching `^ENG-[0-9]+-d[0-9]+$` → return 37 on mismatch.
    - If `--dispatch-id <ENG-N-d…>` was supplied, assert `.dispatch_id == <ENG-N-d…>` → return 37 with `dispatch_id mismatch: JSON has 'X' but --dispatch-id 'Y' was passed (stale dispatch?)`.
    - `verdict` MUST be a string in `{pass, fail, halt}` → return 37 on mismatch (cross-references `bin/pipeline-events.json::verdict_results`).
    - `dimensions` MUST be an array with len ≥ 1 → return 37.
  - [ ] Iterate `.dimensions[]` (mirror `bin/plan-schema.sh:150-270`):
    - `name` MUST be a non-empty string matching `^[a-z][a-z0-9_]*$` → return 37 with `dimensions[i].name fails regex`.
    - `score` MUST be a number in `[0.0, 1.0]` → return 37 with `dimensions[i].score out of range`.
    - `rationale` MUST be a non-empty string → return 37.
    - `threshold_met` MUST be a boolean → return 37.
    - Sweep unknown per-dimension fields → stderr warning, do NOT fail.
  - [ ] Sweep unknown top-level fields → stderr warning, do NOT fail.
  - [ ] Emit `qa-payload-valid: <file>` to stdout on success, return 0.
- [ ] Implement `main`: dispatch on `$1` (`validate`); print usage on unknown subcommand and exit 36 (the catch-all; `_validate_qa_payload` halts with rc=36 on `unexpected-rc`).
- [ ] End the file with the sentinel `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi`.
- [ ] `chmod +x bin/qa-payload-schema.sh` (consistent with `bin/plan-schema.sh`'s mode bit; orchestrator invokes via `bash …`, so this is operator convenience).

### Task 5: Add `_validate_qa_payload` + `_post_qa_payload_halt` to `bin/run-stage.sh`

- `depends_on: [4]`
- `touches: bin/run-stage.sh::_validate_qa_payload, bin/run-stage.sh::_post_qa_payload_halt, bin/run-stage.sh::main`
- [ ] Define `_validate_qa_payload()` IMMEDIATELY AFTER `_post_plan_contract_halt`'s closing `}` (anchor: the literal `bash "$SCRIPT_DIR/linear.sh" add-comment "$ident" "$body" || true` followed by the closing `}` is unique to that helper at ~line 1083-1084). Insert the new function definition BEFORE the next function definition.

  Function body (mirrors brainstorm D-004):

  ```bash
  # ENG-117: qa-payload validator. Runs post-dispatch for stage=qa only.
  # Locates $(issue_dir <ident>)/verdict-qa.json, shells out to
  # bin/qa-payload-schema.sh validate. Returns 0 = valid, 36 = malformed,
  # 37 = incomplete, 38 = missing-file. Caller must gate to stage=qa.
  _validate_qa_payload() {
    local ident="$1"
    local d; d="$(issue_dir "$ident")"
    local payload="$d/verdict-qa.json"

    if [[ ! -f "$payload" ]]; then
      _post_qa_payload_halt "$ident" "qa-payload-missing" \
        "verdict-qa.json not found at $payload"
      return 38
    fi

    local schema_out schema_rc=0
    schema_out="$(bash "$SCRIPT_DIR/qa-payload-schema.sh" validate "$payload" \
      --ident "$ident" --dispatch-id "${PIPELINE_DISPATCH_ID:-}")" || schema_rc=$?
    case "$schema_rc" in
      0)  return 0 ;;
      36) _post_qa_payload_halt "$ident" "qa-payload-malformed"  "$schema_out" ; return 36 ;;
      37) _post_qa_payload_halt "$ident" "qa-payload-incomplete" "$schema_out" ; return 37 ;;
      38) _post_qa_payload_halt "$ident" "qa-payload-missing"    "$schema_out" ; return 38 ;;
      *)  _post_qa_payload_halt "$ident" "unexpected-rc" \
            "validator returned unexpected rc=$schema_rc; stdout: $schema_out" ; return 36 ;;
    esac
  }
  ```

- [ ] Define `_post_qa_payload_halt()` IMMEDIATELY AFTER `_validate_qa_payload`'s closing `}`. Mirror `_post_plan_contract_halt`'s sanitise-and-emit pattern (anchor: line 1077-1084 in HEAD):

  ```bash
  # Posts a halt comment for a qa-payload violation. Mirrors
  # _post_plan_contract_halt's sanitisation pattern: replace `<!--` with
  # `<\!--` in agent-controlled text and wrap in `~~~` fenced block to
  # prevent marker hijacking via embedded `<!-- pipeline: verdict … -->`
  # substrings inside a malformed payload.
  _post_qa_payload_halt() {
    local ident="$1" defect="$2" raw="$3"
    local safe="${raw//<!--/<\\!--}"
    local body
    body="$(printf '<!-- pipeline: verdict result=halt reason=qa-payload-invalid -->\n\nqa-payload validation failed on dispatch_id=%s stage=qa:\n\n- Defect: %s\n\n~~~\n%s\n~~~\n\nSchema source-of-truth: see header comment in `bin/qa-payload-schema.sh`.\n\n**Resume:** fix verdict-qa.json (or the qa prompt'\''s emission step), then run `bash bin/pipeline.sh decide %s --action continue`.' \
      "${PIPELINE_DISPATCH_ID:-unknown}" "$defect" "$safe" "$ident")"
    bash "$SCRIPT_DIR/linear.sh" add-comment "$ident" "$body" || true
  }
  ```

- [ ] Add the caller block in `main()` IMMEDIATELY AFTER the closing `fi` of ENG-122's plan-contract caller block (anchor: the comment `# ENG-122: plan-contract validator. Post-dispatch; planning stage only.` opens that block at ~line 1819; the closing `fi` is at ~line 1835) AND BEFORE the comment `# Push branch BEFORE posting the completion comment so any …` (~line 1837).

  Caller body:

  ```bash
  # ENG-117: qa-payload validator. Post-dispatch; qa stage only.
  # Halts with qa-payload-invalid if $(issue_dir)/verdict-qa.json is absent,
  # malformed, or fails schema-v1 validation. Exit codes 36/37/38 map to
  # the failure_outcome_for_exit taxonomy entries added in Task 2.
  if (( ! skip_dispatch )); then
    case "$stage" in
      qa)
        local _qa_payload_rc=0
        _validate_qa_payload "$ident" || _qa_payload_rc=$?
        if (( _qa_payload_rc != 0 )); then
          classify_failure "$ident" "$stage" "skip-until-human-acts" \
            "qa-payload-invalid: $(failure_outcome_for_exit "$_qa_payload_rc")" "$_qa_payload_rc"
          exit "$_qa_payload_rc"
        fi
        ;;
    esac
  fi
  ```

### Task 6: Add unit tests at `bin/qa-payload-schema-test.sh`

- `depends_on: [4]`
- `touches: bin/qa-payload-schema-test.sh (new)`
- [ ] Create `bin/qa-payload-schema-test.sh` mirroring `bin/plan-schema-test.sh`'s shape: `set -uo pipefail`; `PIPELINE_DRY_RUN=1`; mktemp `FIXTURE_DIR`; `pass_at` / `fail_at` helpers; per-test heredoc fixture writes.
- [ ] T1 — well-formed schema-v1 doc → rc=0.
- [ ] T2 — missing file → rc=38.
- [ ] T3 — malformed JSON (stray comma `{,}`) → rc=36.
- [ ] T4 — top-level is an array → rc=36.
- [ ] T5 — `qa_payload_schema_version` missing → rc=37.
- [ ] T6 — `qa_payload_schema_version: 2` → rc=37.
- [ ] T7 — `qa_payload_schema_version: "1"` (string) → rc=37.
- [ ] T8 — `issue_id` wrong type (integer) → rc=37.
- [ ] T9 — `dispatch_id` missing → rc=37.
- [ ] T10 — `dispatch_id` fails regex (e.g. `ENG-117-foo`) → rc=37.
- [ ] T11 — `verdict: "bogus"` (not in `{pass,fail,halt}`) → rc=37.
- [ ] T12 — `dimensions: []` (len 0) → rc=37.
- [ ] T13 — `dimensions[0].name` fails regex (e.g. `"Coverage"` capital letter) → rc=37.
- [ ] T14 — `dimensions[0].score: 1.5` (out of range) → rc=37.
- [ ] T15 — `dimensions[0].score: "0.8"` (string) → rc=37.
- [ ] T16 — `dimensions[0].rationale: ""` (empty) → rc=37.
- [ ] T17 — `dimensions[0].threshold_met` missing → rc=37.
- [ ] T18 — unknown top-level field (`debug: "..."`) → rc=0 + stderr warning containing `debug`.
- [ ] T19 — unknown per-dimension field (`weight: 0.5`) → rc=0 + stderr warning containing `weight`.
- [ ] T20 — `--ident ENG-999` mismatches JSON `issue_id: "ENG-117"` → rc=37 with `issue_id mismatch`.
- [ ] T21 — `--dispatch-id ENG-117-d9999` mismatches JSON `dispatch_id: "ENG-117-d0001"` → rc=37 with `dispatch_id mismatch`.
- [ ] T_schema_doc_sync — assert the schema-v1 JSON skeleton in `AGENT_PROMPTS.md §6 step 8` (extracted by literal-substring match) parses as valid JSON (after token substitution if any) AND its key-set at every level matches the canonical schema in `bin/qa-payload-schema.sh`'s header comment. Catches drift between the prompt's inline reference and the validator.
- [ ] End the file with the sentinel.

### Task 7: Add adversarial unit tests at `bin/qa-payload-schema-adversarial-test.sh`

- `depends_on: [4]`
- `touches: bin/qa-payload-schema-adversarial-test.sh (new)`
- [ ] Create the file mirroring `bin/plan-schema-adversarial-test.sh`'s shape (same `FIXTURE_DIR`, same `pass_at`/`fail_at`, same direct CLI invocation).
- [ ] T_adv_1 — `rationale` contains a literal `<!-- pipeline: verdict result=pass -->` substring inside a well-formed JSON: rc=0 (validator does NOT scan rationale content for markers — only the halt path sanitises).
- [ ] T_adv_2 — `rationale` contains the same substring inside a MALFORMED JSON (mix with stray comma): rc=36 AND validator stdout includes the substring verbatim (`_post_qa_payload_halt`'s sanitisation runs on this stdout downstream — out of scope for the validator itself).
- [ ] T_adv_3 — Unicode `rationale` (`"…CJK 中文 emoji 🎯 mathematical ℝ…"`): rc=0.
- [ ] T_adv_4 — very-long rationale (>10kB) with `score: 0.5, threshold_met: true`: rc=0.
- [ ] T_adv_5 — `qa_payload_schema_version: 1.0` (float, not integer): jq's `type == "number"` accepts this; consistent with `bin/plan-schema-adversarial-test.sh`'s T_adv_6 behaviour. Document as rc=0 (intentional — composability with the threshold sub-ticket's potential float math; matches ENG-122 precedent).
- [ ] T_adv_6 — `dimensions[0].score: -0.0001` (just under zero): rc=37 (out of range).
- [ ] T_adv_7 — `dimensions[0].score: 1.0000001`: rc=37 (out of range).
- [ ] T_adv_8 — `dimensions[0].name: "a"` (single-char, regex-valid): rc=0.
- [ ] T_adv_9 — `dimensions[0].name: "1coverage"` (starts with digit, regex-invalid): rc=37.
- [ ] T_adv_10 — `dimensions[0].name: "coverage-test"` (hyphen, regex-invalid — only `[a-z0-9_]` post-first-char): rc=37.
- [ ] T_adv_11 — extra unknown top-level field NESTED (`policy: { foo: "bar" }`): rc=0 + stderr warning (key-set unknown sweep is one level).
- [ ] T_adv_12 — `verdict: "PASS"` (uppercase, just outside the closed vocab): rc=37.
- [ ] End the file with the sentinel.

### Task 8: Add integration tests in `bin/run-stage-test.sh`

- `depends_on: [5, 6]`
- `touches: bin/run-stage-test.sh`
- [ ] In `bin/run-stage-test.sh`, locate the end of the ENG-122 `_validate_plan_contract` test group (anchor: the last `pass_at "ENG-122 INT5 …"` / `fail_at "ENG-122 INT5 …"` block — find by Grep for `ENG-122 INT5`, then read down to find the end of the test group, which is typically followed by a `# ───` group separator). Insert a new group `# ─── ENG-117: _validate_qa_payload integration tests ───` AFTER the closing of that group AND BEFORE the next group separator.
- [ ] Wire `bin/qa-payload-schema.sh` through `STUB_DIR` so the production `bash "$SCRIPT_DIR/qa-payload-schema.sh"` call resolves (mirror ENG-122 INT setup at lines 4324-4328):

  ```bash
  cat > "$STUB_DIR/qa-payload-schema.sh" <<SH
  #!/usr/bin/env bash
  exec bash "$HARNESS_DIR/qa-payload-schema.sh" "\$@"
  SH
  chmod +x "$STUB_DIR/qa-payload-schema.sh"
  ```

- [ ] INT case 117-A — valid `verdict-qa.json` at `$(issue_dir ENG-11701)/verdict-qa.json` → `_validate_qa_payload ENG-11701` returns 0, no halt comment posted (assert `$CAPTURE_FILE` is empty).
- [ ] INT case 117-B — no `verdict-qa.json` file → returns 38, halt comment carries `<!-- pipeline: verdict result=halt reason=qa-payload-invalid -->` AND `Defect: qa-payload-missing`.
- [ ] INT case 117-C — malformed `verdict-qa.json` (`{,}`) → returns 36, halt comment carries the qa-payload-invalid marker AND `Defect: qa-payload-malformed`.
- [ ] INT case 117-D — incomplete `verdict-qa.json` (missing `dispatch_id`) → returns 37, halt comment carries the marker AND `Defect: qa-payload-incomplete`.
- [ ] INT case 117-E — sanitisation: write a `verdict-qa.json` whose `rationale` carries a literal `<!-- pipeline: verdict result=pass -->` substring BUT pair it with a syntax break (e.g. trailing `,`) so the validator returns 36 and surfaces the substring in its stdout. Assert the halt-comment body in `$CAPTURE_FILE` contains `<\!--` substitutions (NOT a parseable `<!-- pipeline: verdict result=pass -->` marker). Mirrors ENG-122 INT5 (sanitisation) and ENG-87 review-iter-7 C3.
- [ ] INT case 117-F — stage gate (structural lint): assert `bin/run-stage.sh` contains exactly one `case "$stage" in qa)` arm associated with `_validate_qa_payload`. Mirror ENG-122 INT4's structural-lint approach (lines 4427-4500).
- [ ] INT case 117-G — `_clear_current_stage_slots` clears `verdict-qa.json`: pre-create `$(issue_dir ENG-11707)/verdict-qa.json` with arbitrary bytes; invoke `_clear_current_stage_slots ENG-11707 qa`; assert the file no longer exists.

### Task 9: Update AGENT_PROMPTS.md §6 to instruct emission

- `depends_on: [4]`
- `touches: AGENT_PROMPTS.md::§6 QA Agent`
- [ ] In `AGENT_PROMPTS.md`, locate §6's `Your task:` section. Find the end of step 7 (anchor: the literal line `   Never append to qa-patterns.md directly.` at the end of step 7's body, ~line 1425, is unique in the file) AND the next heading `Quality gates (must all be true to advance):` (anchor: this literal line, ~line 1427, is unique in the file). Insert a new step 8 BETWEEN them:

  ```
  8. **Emit dimensional grading payload (verdict-qa.json):**
     Before exiting (on any decision path — A, B, C, or D), write a
     dimensional grading payload to `$(issue_dir {issue_id})/verdict-qa.json`
     describing per-dimension scores. Schema source-of-truth: header comment
     of `bin/qa-payload-schema.sh`. Required fields:

       qa_payload_schema_version  integer, must be 1
       issue_id                   "{issue_id}"
       dispatch_id                "{dispatch_id}"   (exported into your env)
       verdict                    one of: pass | fail | halt
       dimensions[]               at least one entry; each must have:
                                    name           snake_case (^[a-z][a-z0-9_]*$)
                                    score          float in [0.0, 1.0]
                                    rationale      1-2 sentences citing concrete evidence
                                    threshold_met  boolean (your judgment)

     Suggested starter dimensions for the qa stage (not mandated; the
     threshold-logic sub-ticket will decide the canonical set):
     `gate_compliance`, `coverage`, `regression_intent`,
     `adversarial_coverage`, `plan_alignment`, `flake_dismissal_integrity`.
     Include a dimension only if you can cite concrete evidence; omit
     rather than fabricate.

     The post-dispatch detective scan in
     `bin/run-stage.sh::_validate_qa_payload` will halt the dispatch with
     `qa-payload-invalid` if the file is missing, malformed, or fails
     schema validation. The threshold sub-ticket will later gate the
     dispatch verdict on dimensional minimums; today the payload is
     recorded forensically without gating.

     Overwrite-on-every-dispatch contract per §0; use `Write` (not Edit)
     against the canonical path; do NOT write scratch fixtures elsewhere
     in the worktree.
  ```

- [ ] In §6's `Output:` bullet list, locate the bullet `- No edits to qa-patterns.md (use the candidate marker comment).` (anchor: this literal line at ~line 1485 is unique in the file) AND the bullet `- **Append a `progress.md` entry**` at ~line 1486. Insert a new bullet BETWEEN them:

  ```
  - `verdict-qa.json` written to `$(issue_dir {issue_id})/verdict-qa.json`
    on every decision path (A, B, C, or D). Overwrite-on-every-dispatch
    contract per §0; orchestrator's detective scan validates it before
    advancing.
  ```

- [ ] Confirm the §6 fence count remains exactly 2 (anchors: the opening ` ``` ` at line 1324, the closing ` ``` ` at line 1515 — the new content is plain prose with NO column-0 fences). Run `bash bin/render-prompt-test.sh` post-edit; it asserts the §6 block extracts cleanly.

### Task 10: Update `learned-rules/harness/project-profile.md` tool allowlist

- `depends_on: [6, 7]`
- `touches: learned-rules/harness/project-profile.md::## Tool allowlist`
- [ ] In `learned-rules/harness/project-profile.md`, locate the `## Tool allowlist` section's `implementing:` block. Find the line `- Bash(bash bin/profile-allowlist-test.sh:*)` (anchor: this literal line is unique in the file). Insert TWO new entries in alphabetical position:
  - `- Bash(bash bin/qa-payload-schema-adversarial-test.sh:*)`
  - `- Bash(bash bin/qa-payload-schema-test.sh:*)`

  (Note: alphabetical order puts `qa-payload-schema-adversarial-test.sh` BEFORE `qa-payload-schema-test.sh`; both go AFTER `profile-allowlist-test.sh` AND BEFORE `progress-md-cross-stage-test.sh`.)

- [ ] Repeat the same insertion in the `qa:` block (search for the same anchor `- Bash(bash bin/profile-allowlist-test.sh:*)` within the qa block — the two appearances differ only by their containing block; insert into both).

- [ ] Smoke: `grep -c 'Bash(bash bin/qa-payload-schema-test.sh:\*)' learned-rules/harness/project-profile.md` returns `2`. `grep -c 'Bash(bash bin/qa-payload-schema-adversarial-test.sh:\*)' learned-rules/harness/project-profile.md` returns `2`.

### Task 11: Append paragraph to CLAUDE.md

- `depends_on: [4]`
- `touches: CLAUDE.md::"Per-issue state directory"`
- [ ] In `CLAUDE.md`, locate the `## Per-issue state directory` heading (anchor: this literal heading is unique in the file). Inside the directory-tree code block, locate the line listing `stage-summary-<stage>.md` (or the closest equivalent). Append a short paragraph AFTER the closing of that code block AND BEFORE the next subsection. The paragraph names `verdict-qa.json` as the qa-stage dimensional-grading payload artifact (one-per-dispatch, cleared by `_clear_current_stage_slots`, validated by `_validate_qa_payload`) and points to `bin/qa-payload-schema.sh`'s header comment as the schema source-of-truth.

  Suggested wording (no need to match verbatim; the goal is correctness, not style):

  ```
  `verdict-qa.json` (ENG-117) is a per-dispatch dimensional-grading
  payload written by the qa agent under `$(issue_dir <ident>)/`. Schema
  source-of-truth lives in `bin/qa-payload-schema.sh`'s header comment;
  the post-dispatch detective scan in `bin/run-stage.sh::_validate_qa_payload`
  halts the dispatch with `qa-payload-invalid` on missing/malformed
  payloads. Cleared on every dispatch-start by
  `_clear_current_stage_slots` (same primitive as
  `stage-summary-<stage>.md` and `wait-<stage>.json`).
  ```

### Task 12: Run the full test suite + smoke the new validator

- `depends_on: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]`
- `touches: (none — verification only)`
- [ ] Run `bash bin/qa-payload-schema-test.sh`; expect all T1-T21 + T_schema_doc_sync pass.
- [ ] Run `bash bin/qa-payload-schema-adversarial-test.sh`; expect all T_adv_* pass.
- [ ] Run `bash bin/run-stage-test.sh`; expect all 117-A through 117-G pass alongside existing ENG-87, ENG-122, ENG-138 tests.
- [ ] Run `bash bin/render-prompt-test.sh`; expect §6 fence count remains 2 and the block extracts cleanly with the new step 8 + Output bullet.
- [ ] Run `bash bin/common-test.sh`; expect `failure_outcome_for_exit` mapping for 36/37/38 is asserted (if not already; if not, the test stays clean since the new arms are additive).
- [ ] Run `bash bin/dispatch-test.sh`; expect the profile-driven Tool allowlist composition tests still pass (the project profile now includes the two new test entries; the existing tests do not pin the count, so the additions are benign).
- [ ] Run `bash bin/plan-schema.sh validate docs/plans/2026-05-17-eng-117-dimensional-grading-qa-stage-payload.json --ident ENG-117`; expect exit 0 (validates this plan's sibling JSON).
- [ ] Run `bash .githooks/pre-commit`; expect the full `bin/*-test.sh` glob (including the two new files) passes.

## Frontend Tasks

No frontend — the harness has no UI. The UI agent dispatched against this issue will see "no UI" in this section and emit `verdict pass --stage ui` immediately (precedent: `docs/plans/2026-05-15-eng-122-...md` etc).

## Failure Mode → Test Map

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
|---|---|---|---|---|
| `verdict-qa.json` file missing post-dispatch | QA agent writes nothing to the canonical path | `_validate_qa_payload` returns 38; `_post_qa_payload_halt` posts halt comment with `Defect: qa-payload-missing`; dispatch exits 38; `classify_failure` applies `skip-until-human-acts` | integration | `bin/run-stage-test.sh` case 117-B |
| Malformed JSON syntax | QA agent writes `verdict-qa.json` with stray comma / unclosed brace | `qa-payload-schema.sh` returns 36; halt-comment with `Defect: qa-payload-malformed` | integration + unit | `bin/run-stage-test.sh` case 117-C ; `bin/qa-payload-schema-test.sh` T3 |
| Top-level JSON is an array | `verdict-qa.json` body is `[…]` | `qa-payload-schema.sh` returns 36 (`top-level JSON is not an object`) | unit | `bin/qa-payload-schema-test.sh` T4 |
| Missing required top-level field (`qa_payload_schema_version`) | `qa_payload_schema_version` absent | `qa-payload-schema.sh` returns 37 with `missing required field` message | unit | `bin/qa-payload-schema-test.sh` T5 |
| Wrong schema version (`qa_payload_schema_version: 2`) | Validator only handles v1 | `qa-payload-schema.sh` returns 37 with `must be 1` message | unit | `bin/qa-payload-schema-test.sh` T6 |
| Schema version is string `"1"` instead of integer | Agent typo | `qa-payload-schema.sh` returns 37 (type assertion) | unit | `bin/qa-payload-schema-test.sh` T7 |
| `issue_id` wrong type / regex mismatch | Agent emits integer or bad token | `qa-payload-schema.sh` returns 37 | unit | `bin/qa-payload-schema-test.sh` T8 |
| `dispatch_id` missing | Agent forgets the staleness invariant | `qa-payload-schema.sh` returns 37 | unit | `bin/qa-payload-schema-test.sh` T9 |
| `dispatch_id` regex mismatch | Agent emits `ENG-117-foo` | `qa-payload-schema.sh` returns 37 | unit | `bin/qa-payload-schema-test.sh` T10 |
| `dispatch_id` cross-check fails (stale dispatch) | Agent copy-pastes prior run's dispatch_id; `--dispatch-id` flag passed by orchestrator | `qa-payload-schema.sh` returns 37 with `dispatch_id mismatch` | unit | `bin/qa-payload-schema-test.sh` T21 |
| `issue_id` cross-check fails (cross-issue template) | Agent copy-pastes another issue's JSON; `--ident` flag passed | `qa-payload-schema.sh` returns 37 with `issue_id mismatch` | unit | `bin/qa-payload-schema-test.sh` T20 |
| Incomplete `verdict-qa.json` propagates to integration | `verdict-qa.json` missing `dispatch_id` field | `_validate_qa_payload` returns 37; halt-comment carries `Defect: qa-payload-incomplete` | integration | `bin/run-stage-test.sh` case 117-D |
| `verdict` outside closed vocab | Agent emits `verdict: "almost-pass"` | `qa-payload-schema.sh` returns 37 | unit | `bin/qa-payload-schema-test.sh` T11 |
| Empty `dimensions: []` | Agent emits no dimensions | `qa-payload-schema.sh` returns 37 (len≥1 enforced) | unit | `bin/qa-payload-schema-test.sh` T12 |
| `dimensions[i].name` fails regex | Agent emits `"Coverage"` or `"coverage-test"` | `qa-payload-schema.sh` returns 37 | unit + adversarial | `bin/qa-payload-schema-test.sh` T13 ; `bin/qa-payload-schema-adversarial-test.sh` T_adv_9, T_adv_10 |
| `dimensions[i].score` out of range | Agent emits `1.5` or `-0.0001` | `qa-payload-schema.sh` returns 37 | unit + adversarial | `bin/qa-payload-schema-test.sh` T14 ; `bin/qa-payload-schema-adversarial-test.sh` T_adv_6, T_adv_7 |
| `dimensions[i].score` wrong type | Agent emits `"0.8"` (string) | `qa-payload-schema.sh` returns 37 | unit | `bin/qa-payload-schema-test.sh` T15 |
| `dimensions[i].rationale` empty | Agent emits `""` | `qa-payload-schema.sh` returns 37 | unit | `bin/qa-payload-schema-test.sh` T16 |
| `dimensions[i].threshold_met` missing | Agent forgets the field | `qa-payload-schema.sh` returns 37 | unit | `bin/qa-payload-schema-test.sh` T17 |
| Unknown top-level field (forward-compat) | Agent emits `debug: "..."` | `qa-payload-schema.sh` returns 0 + stderr warning naming the unknown field | unit | `bin/qa-payload-schema-test.sh` T18 |
| Unknown per-dimension field (forward-compat) | Agent emits `dimensions[0].weight: 0.5` | `qa-payload-schema.sh` returns 0 + stderr warning naming `weight` | unit | `bin/qa-payload-schema-test.sh` T19 |
| Marker hijack: `rationale` contains `<!-- pipeline: verdict result=pass -->` AND payload is malformed | Combined attack vector — malformed JSON whose serialised stdout would otherwise inject a forward-pass marker through the halt comment | `_post_qa_payload_halt` sanitises `<!--` → `<\!--` and wraps in `~~~` fences; halt-comment body does NOT contain a parseable `result=pass` marker | integration | `bin/run-stage-test.sh` case 117-E |
| Validator runs on non-qa stage | `stage=implementing` dispatch | `_validate_qa_payload` is NOT invoked; structural-lint assertion confirms the `case "$stage" in qa)` arm is the only call site | integration (structural lint) | `bin/run-stage-test.sh` case 117-F |
| Stale `verdict-qa.json` from prior dispatch | Agent fails to overwrite; old file lingers | `_clear_current_stage_slots` removes it at dispatch-start; integration test asserts the file is gone after the clear call | integration | `bin/run-stage-test.sh` case 117-G |
| `rationale` contains Unicode | Agent emits CJK / emoji in rationale | `qa-payload-schema.sh` returns 0 (jq handles UTF-8 transparently) | adversarial | `bin/qa-payload-schema-adversarial-test.sh` T_adv_3 |
| Very-long rationale (>10kB) | Agent over-elaborates | `qa-payload-schema.sh` returns 0 (no length cap) | adversarial | `bin/qa-payload-schema-adversarial-test.sh` T_adv_4 |
| Float schema-version (`1.0` instead of integer `1`) | jq `type == "number"` accepts it | `qa-payload-schema.sh` returns 0 (intentional — composability with the threshold sub-ticket's potential float math); documented in adversarial test | adversarial | `bin/qa-payload-schema-adversarial-test.sh` T_adv_5 |
| `qa` stage halted mid-stream (agent-side halt, payload absent) | Agent emits `verdict halt --reason iteration-exhausted` AND does not write verdict-qa.json | Detective fires: missing file → rc=38 + qa-payload-invalid halt comment. May double-halt (agent halt + validator halt); operator triages via the latest `<!-- meta: dispatch id=… -->` marker per ENG-87. Acceptable noise (brainstorm §6 acknowledgement). | n/a (no test) | (none — relies on the existing single-stage halt classifier; not in scope) |

## Test Strategy

**Unit tests (`bin/qa-payload-schema-test.sh`)** — T1-T21 + T_schema_doc_sync. Cover the validator's full enumeration of malformed / incomplete / missing-file shapes plus the D-005 permissive-unknown-field branch plus the `--ident` / `--dispatch-id` cross-check defenses. Mktemp'd fixtures, no checked-in JSON outside this plan's sibling `.json`. Source-and-stub pattern: end-to-end CLI invocation via `bash bin/qa-payload-schema.sh validate <fixture>`, matching how `_validate_qa_payload` calls it in production.

**Adversarial unit tests (`bin/qa-payload-schema-adversarial-test.sh`)** — T_adv_1 through T_adv_12. QA-time corner cases: marker-hijack substring inside `rationale`, Unicode, very-long payloads, score-boundary edges, regex-edge name patterns, deep-nested unknown fields. Pattern mirrors `bin/plan-schema-adversarial-test.sh`. Required by §5 of AGENT_PROMPTS §6 (qa agent commits adversarial tests for new code paths); we file them upfront to ship complete coverage in one PR.

**Integration tests (`bin/run-stage-test.sh`)** — cases 117-A through 117-G. Cover the wiring between `_validate_qa_payload`, `_post_qa_payload_halt`, `qa-payload-schema.sh`, the run-stage main-flow gate, AND the `_clear_current_stage_slots` extension. Stubbed `linear.sh` captures halt-comment bodies; tests assert marker shape, defect-token content, and the `<\!--` sanitisation substitution. The sanitisation case (117-E) and the stage-gate structural lint (117-F) are the two non-obvious regressions; 117-G pins the dispatch-start clear primitive.

**Smoke** — Task 12 includes `bash bin/plan-schema.sh validate docs/plans/<this-plan>.json --ident ENG-117` against the sibling plan.json (self-validating). Plus `.githooks/pre-commit` runs the entire `bin/*-test.sh` glob; the new test files are picked up automatically.

**No e2e tests** — the harness's e2e is the existing `PIPELINE_DRY_RUN=1 bash bin/dry-run.sh` path; this plan does not extend it. Integration coverage at the run-stage layer is sufficient.

### Operator failure narrative (end-to-end recovery flow)

When the qa agent forgets to emit `verdict-qa.json` (or emits malformed JSON), the operator sees:

1. **Agent run completes.** `claude -p` exits clean (the agent posted a verdict marker via `bash bin/pipeline.sh event ENG-N verdict pass --stage qa`).
2. **Post-dispatch detective fires.** `bin/run-stage.sh::_validate_qa_payload` runs (stage-gated to `qa`); it sees no `verdict-qa.json` (or jq cannot parse it / a required field is missing / `dispatch_id` cross-check fails) and shells out to `bin/qa-payload-schema.sh validate` which returns 36/37/38.
3. **Halt comment lands.** `_post_qa_payload_halt` posts a Linear comment containing `<!-- pipeline: verdict result=halt reason=qa-payload-invalid -->` + `- Defect: qa-payload-{missing|malformed|incomplete}` + a fenced `~~~` block with the validator's defect detail + the recovery one-liner `bash bin/pipeline.sh decide ENG-N --action continue`.
4. **`classify_failure` writes state.** `issue-state.json` carries `policy: skip-until-human-acts`; the orchestrator post-dispatch applies the `pipeline:halted` and `pipeline:skip-until-human-acts` Linear labels (ENG-56).
5. **Operator triages.** The latest `<!-- meta: dispatch id=ENG-N-d<NNNN> -->` marker pinpoints the dispatch; the `Defect:` token identifies which of the three failure modes fired; the validator's stdout (inside the `~~~` block) names the exact field that failed.
6. **Operator resumes.** `bash bin/pipeline.sh decide ENG-N --action continue` clears the halt label, the per-issue counter, and re-allocates a fresh `dispatch_id`. The next tick's qa dispatch re-runs the agent; `_clear_current_stage_slots` removes any stale `verdict-qa.json` at dispatch-start so the fresh agent's emission is unambiguous.

This narrative is implemented by Task 5 (the halt comment body) + Task 11 (the CLAUDE.md "Per-issue state directory" paragraph). The Failure Mode → Test Map's first three rows assert each step lands its visible signal (halt rc, marker shape, Defect token).

### Test-gate closure sweep (feasibility sub-check)

No tokens are REMOVED from production code by this plan. Every change is additive: new exit codes (36/37/38), new halt-reason entry (`qa-payload-invalid`), new validator functions (`_validate_qa_payload`, `_post_qa_payload_halt`), new files (`bin/qa-payload-schema.sh`, two new tests), one new line inside `_clear_current_stage_slots`, one new step in AGENT_PROMPTS §6, two new Output bullets, one new paragraph in CLAUDE.md, two new entries in the project profile's tool allowlist. No sibling test file pins a soon-to-be-removed token. Sweep clean.

The closest near-miss: `bin/dispatch-test.sh` and `bin/profile-allowlist-test.sh` exercise the profile-driven Tool allowlist composition; neither test pins a count of entries (verified by Grep — they assert specific tokens are present/absent, not the cardinality), so adding two new entries to the profile is benign.

## Persona review notes (recorded post-self-review; see step-3 gate)

Iteration 2 (post-resume; prior dispatch halted on ENG-144 progress-md regression, resumed via `--action continue` after upstream fix landed): 5/5 personas PASS, 0 P0 findings. Branch-base freshness pin refreshed to `origin/main = 15e2f01`; no anchor drift. Gate satisfied; proceeding to commit + stage-summary.

Iteration 1: 5/5 personas PASS, 0 P0 findings. Gate satisfied; proceeding to commit + stage-summary.

- **feasibility — PASS, 0 P0.** Branch-base freshness verified (`origin/main = 444e752`; 8 upstream commits all touch `bin/run-stage.sh` only at line 1235 — far from this plan's insertion points at 1077 and 1819). Every Assumption Inventory `path:line` content anchor resolves uniquely in the file. New files `bin/qa-payload-schema*` absent from HEAD as claimed. Edit boundaries use content anchors throughout (no bare line numbers as sole boundary). Task dependency graph is sound. JSON contract structurally validates against `bin/plan-schema.sh`'s schema-v1 shape (6 features, valid kinds, required fields per kind). Test-gate closure sweep clean — plan is purely additive. P1: off-by-one mention of "T1-T20" in File Structure (since fixed; now reads "T1-T21 + T_schema_doc_sync").
- **scope — PASS, 0 P0.** Every File Structure entry and every task `touches` list traces to a brainstorm Decision (D-001 through D-008) or an explicit Linear scope bullet. No reader work, no threshold-logic gating, no review-payload work, no schema-v2 speculation, no dimension-vocab closure. Adversarial-test task (Task 7) justified by AGENT_PROMPTS §6's mandatory-adversarial-budget clause; not gold-plating. P1: Task 10 (project profile tool allowlist) is a mild scope nudge beyond what the brainstorm strictly mandates but is operator-tooling hygiene; flagged P1, accepted.
- **coherence — PASS, 0 P0.** Goal matches brainstorm §1 Problem + §2 Decisions. Every File Structure entry has task coverage (no orphans). Backend Tasks jointly realise every Decision D-001 through D-008. Failure Mode → Test Map covers every brainstorm §5 Error Handling row + every §6 Edge Case. Test Strategy enumerates every named test. Schema is consistent across API Contract block, AGENT_PROMPTS §6 step 8 (Task 9), and validator header (Task 4); T_schema_doc_sync enforces ongoing drift detection. Belt-and-braces staleness story (D-006 clear + D-002 dispatch_id cross-check) is described coherently across Tasks 1, 4, 5.
- **design — PASS, 0 P0.** Architectural lanes respected: dispatch.sh stays thin, run-stage.sh owns post-dispatch detective scans, common.sh extends narrowly (3 new exit-code arms), Linear writes flow through `bin/linear.sh` (the ENG-87 chokepoint), per-issue state under `$(issue_dir <ident>)` only, new files end with the source-and-test sentinel. ENG-122 parallelism is one-for-one: `bin/qa-payload-schema.sh` ↔ `bin/plan-schema.sh`; `_validate_qa_payload` ↔ `_validate_plan_contract`; exit codes 36/37/38 slot cleanly after 33/34/35. ENG-87 cross-dispatch staleness contract honored (D-006 clear-on-dispatch-start + D-002 `dispatch_id` cross-check, belt-and-braces). ENG-46 secret-handling clean (`${PIPELINE_DISPATCH_ID:-unknown}` is a non-secret env var). AGENT_PROMPTS §6 invariant respected (no column-0 fences in §6's body — Task 9 explicitly asserts this and the post-edit `bin/render-prompt-test.sh` run gates it).
- **product — PASS, 0 P0.** All three ACs delivered: AC1 → Task 9 (prompt instructs emission on every decision path). AC2 → Tasks 2/3/4/5 (exit codes, halt reason, validator, run-stage detective; halt comment names recovery one-liner). AC3 → Tasks 6/7/8 (unit + adversarial + integration coverage of well-formed / missing / malformed / sanitisation / stage-gate / dispatch-start clear). No problem drift (the plan does NOT solve threshold-logic, NOT solve the review-payload sibling, NOT refactor qa.md). Parallel-safety with the review-payload sibling preserved (the only shared touchpoint, `_clear_current_stage_slots`, is parameterised on `${stage}` per D-006). P1 (now addressed): added "Operator failure narrative" subsection to Test Strategy walking the end-to-end recovery flow.

Status line (for stage summary): `Personas: 5/5 PASS · gate P0: 0 · proceeding to implementing`.
