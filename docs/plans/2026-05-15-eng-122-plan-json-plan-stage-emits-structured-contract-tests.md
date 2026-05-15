---
linear: ENG-122
date: 2026-05-15
topic: Plan stage emits sibling docs/plans/<issue>.json structured contract + post-dispatch validator + tests
---

# Plan — plan.json: plan stage emits structured contract + tests (ENG-122)

## Anti-anchoring check

- **Problem (operator-perspective):** "When planning produces a prose plan, downstream stages (implement, qa, build) parse it heuristically; subtle drift in the plan (a missing table row, a typo in a Task header) silently shrinks the work the next stage does and only surfaces as a halt comment many minutes later." ENG-30 names this; ENG-122 is the producer foundation.
- **Brainstorm framing:** matches the problem one-for-one. The solution ships a sibling `.json` containing the structured-contract fields (`features`, `pass_criteria` with `kind ∈ {smoke, file_exists, grep}`) the umbrella issue calls out, plus a post-dispatch validator that halts loudly when the JSON is missing/malformed. No readers (deferred to ENG-32 / ENG-38). No new prompt-side vocabulary beyond a single new halt reason.
- **Proportionality:** one new helper script (`bin/plan-schema.sh`), one new test script (`bin/plan-schema-test.sh`), one new validator function (`_validate_plan_contract` + `_post_plan_contract_halt`) wired into `bin/run-stage.sh`'s existing post-dispatch detective block (next to `_validate_dispatch_envelope`), three new exit codes (30/31/32 — the first free slots after 29), one new halt-reason token (`plan-contract-invalid`), one new AGENT_PROMPTS §2 Output bullet + inline schema reference. ≤ 5 functions added in production code. Proportional. Proceed.

## Goal

Plan-stage dispatches MUST produce a sibling `docs/plans/<basename>.json` alongside the existing `.md` prose plan; a post-dispatch validator (`bin/run-stage.sh::_validate_plan_contract`, gated to `stage=planning`) shells out to a new `bin/plan-schema.sh validate` CLI to enforce schema-1 shape and halts the dispatch with halt-reason `plan-contract-invalid` (exit codes 30 = malformed, 31 = incomplete, 32 = missing-file) when the JSON is absent or malformed — so that drift between the agent's commitment and the downstream stages' expectations surfaces at plan time, not at implement/qa time.

## Assumption Inventory

Format: `[verified|assumed]` ITEM — `path:line` reference.

**branch-base freshness:** `HEAD..origin/main` is NON-EMPTY at plan time (`55268f2` merge + `9cb9c65` `feat(ticekt sizing): added the ticket sizing rubric to claude.md`). The upstream commit only modifies `CLAUDE.md` (adding a ticket-sizing rubric — purely additive); none of the files this plan modifies (`bin/run-stage.sh`, `bin/common.sh`, `bin/dispatch.sh`, `bin/render-prompt.sh`, `bin/pipeline-events.json`, `AGENT_PROMPTS.md`, `bin/run-stage-test.sh`) are touched by `origin/main`. Clean drift. **Task 0** rebases onto `origin/main` before any other implement work and re-verifies the `path:line` excerpts below. Pin: `origin/main = 55268f2` at plan time.

### Verified — code paths quoted from current tree

- `[verified]` `bin/run-stage.sh:883-947` — `_validate_dispatch_envelope` function. The new `_validate_plan_contract` will be defined immediately AFTER this function's closing `}` (~line 947) and BEFORE the next function (`_dispatch_history_end_row` block-comment at line ~949). Content anchor: the line `_validate_dispatch_envelope() {` and the next block-comment `# ENG-87 review M1+M2: dispatch_history.jsonl end-row trap.` are both unique in the file.

- `[verified]` `bin/run-stage.sh:1553-1580` — caller block for `_validate_dispatch_envelope`. The new `_validate_plan_contract` call site goes immediately AFTER this `if (( ! skip_dispatch )); then case "$stage" in … esac; fi` block and BEFORE the `# Push branch BEFORE posting the completion comment …` block-comment at line 1582. Content anchor: the comment `# Push branch BEFORE posting the completion comment …` is unique in the file.

- `[verified]` `bin/run-stage.sh:1538-1551` — agent-contract validator (exit 25) — the precedent for the case-stage-gating shape we're reusing. Content anchor: the comment `# Agent-contract validator (ENG-7).` is unique in the file.

- `[verified]` `bin/run-stage.sh:25-32` — top-of-file sourcing block. `SCRIPT_DIR` is set at line 26; `source "$SCRIPT_DIR/common.sh"` at line 28. `_validate_plan_contract` invokes `bash "$SCRIPT_DIR/plan-schema.sh" validate <file>` and uses `issue_dir`, `log`, `die` from common.sh — all available.

- `[verified]` `bin/common.sh:212-239` — `failure_outcome_for_exit` table. Exit codes 10–29 + 124 are mapped today; 30/31/32 are the first free slots. Insertion point: AFTER the `29) printf 'envelope-violation' ;;` line, BEFORE `124) printf 'dispatch-timeout' ;;`. Content anchor: the line `29) printf 'envelope-violation' ;;` is unique in the file (the 29 token + literal `envelope-violation`).

- `[verified]` `bin/pipeline-events.json:10-20` — `halt_reasons` array. Today contains 9 entries ending with `"dispatch-envelope-violation"` on line 19. New entry `"plan-contract-invalid"` to be appended as the 10th. Content anchor: the literal `"dispatch-envelope-violation"` is unique in the file.

- `[verified]` `bin/dispatch.sh:54, 142-144` — `_render_and_capture_stream` writes the envelope sidecar at `${issue_dir}/.envelope-transcript-${stage}`. The new validator does NOT read this sidecar (it reads `$wt/docs/plans/<basename>.json` — the agent's worktree artifact, not the transcript). No change required in `dispatch.sh`.

- `[verified]` `bin/render-prompt.sh:132-176` — `find_doc()` matches plan docs by `linear: <ID>` YAML-frontmatter on the first 20 lines, with filename-substring fallback. The validator uses an inline `find` glob (not `find_doc`) because it must derive the SIBLING JSON path from the matched `.md` basename. Function signature: `find_doc <dir> <issue_id> <slug>`; reusable but not strictly required.

- `[verified]` `bin/render-prompt.sh:41-54` — `PROMPT_RESOLVERS` registry. Tokens `issue_id`, `issue_id_lower`, `date`, `slug`, `plan_file`, `stage_summary_path`, `learned_rules_dir`, `brainstorm_file`, `dispatch_id` are all registered. The §2 Output bullet additions use only already-registered tokens; no new resolver function needed.

- `[verified]` `AGENT_PROMPTS.md:413` — current §2 Output bullet: `- Produce a plan at docs/plans/{date}-{issue_id_lower}-{slug}.md`. The new sibling-`.json` bullet is appended immediately after this line (or as part of an expanded "Output" subsection). Content anchor: the literal line `- Produce a plan at docs/plans/{date}-{issue_id_lower}-{slug}.md` is unique in the file.

- `[verified]` `AGENT_PROMPTS.md:600-601` (and four sibling occurrences at lines 339, 776, 917, 1340) — the agent-facing halt-reason allowlist: `where <reason> is one of: agent-blocked | smoke-failed | iteration-exhausted | scope-violation | protocol-violation | dispatch-timeout | pr-opened-too-early`. This is the agent's verdict-marker tabular — `plan-contract-invalid` is orchestrator-emitted (NOT agent-emitted; see D-004 in the brainstorm), so the agent's allowlist is **deliberately NOT extended** (the agent never emits this halt token; only the orchestrator's `_post_plan_contract_halt` does, via `bin/linear.sh add-comment`). The brainstorm's note about adding it to the §0 agent-facing reason allowlist is **superseded** by the architectural fact that the halt is detective-only and orchestrator-owned — adding it to the agent allowlist would invite agents to self-emit the reason, which the lane fence does NOT prevent (any writer can emit `verdict halt`).

- `[verified]` `bin/pipeline.sh:80-115` — `cmd_event_verdict` validates `--reason` against `bin/pipeline-events.json::halt_reasons` via `_validate_registry`. This means adding `plan-contract-invalid` to the registry IS required for any future operator/script that wants to emit it via `bash bin/pipeline.sh event ... verdict halt --reason plan-contract-invalid` (e.g. a manual re-emit during operator triage). The orchestrator's own emission path (`_post_plan_contract_halt → bin/linear.sh add-comment` raw-body) does NOT go through `pipeline.sh event` — same as `_validate_dispatch_envelope` at run-stage.sh:943. Adding the registry entry is correct documentation and unlocks the pipeline.sh path without forcing it.

- `[verified]` `bin/run-stage-test.sh:4093-4200` — existing `_validate_dispatch_envelope` test group (ENG-87 F/G/H/I/J). Mktemp-based `STUB_DIR` setup at lines 17-65; the new ENG-122 test group follows the same `pass_at` / `fail_at` / `reset_capture` shape and reuses the `linear.sh` stub. Insertion point: AFTER the last ENG-87 sub-case (line ~4200, the `Case 87-J` chained-command blind-spot test) and BEFORE the next group separator (`# ─── ENG-…`). Content anchor: the last `pass_at "ENG-87 J:` / `fail_at "ENG-87 J:` line in the file is unique.

- `[verified]` `bin/common.sh:178-195` — `assert_no_tool_invocation` helper. Hoisted to common.sh in ENG-87. Not used by this ticket (the plan-contract validator scans a worktree file, not the agent transcript). No change required.

- `[verified]` Sentinel pattern `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi` — required at the end of `bin/plan-schema.sh` so `bin/plan-schema-test.sh` can `source` it. Precedent: every existing `bin/*.sh` with a corresponding `bin/*-test.sh`.

- `[verified]` `bin/dispatch.sh:469-488` — `_cfg_minutes` resolver pattern (jq read from `.pipeline-config/config.json` with empty-fallthrough). The new validator does NOT read config — it reads the worktree artifact directly. Pattern referenced as the canonical jq+regex idiom for `bin/plan-schema.sh`'s internal field-type assertions.

- `[verified]` `bin/run-stage.sh:935-943` — envelope-validator's sanitisation+halt-emission shape. The literal `viol_str_safe="${viol_str_raw//<!--/<\\!--}"` (line 933) + the `printf '<!-- pipeline: verdict result=halt reason=… -->\n\n…' …` body + `bash "$SCRIPT_DIR/linear.sh" add-comment "$ident" "$body"` (line 943) ARE the pattern `_post_plan_contract_halt` will mirror.

- `[verified]` `bin/run-stage.sh:1538` — the `(( ! skip_dispatch ))` gate. The new validator inherits this gate (no run on scope-approval replay).

- `[verified]` `bin/run-stage.sh:1577` — sidecar cleanup at envelope-validator's clean-path exit. Pattern reference; the plan-contract validator removes the worktree artifact ONLY on the halt path (the `.json` file itself is in-scope `docs/plans/` content, never deleted by the validator — the agent committed it).

- `[verified]` `bin/run-stage.sh:69-95` — `_cost_flags_for` location, used by ENG-103. The plan-contract validator is NOT in this cost-telemetry block; it's a detective scan, slotted next to `_validate_dispatch_envelope` per D-004.

### Verified — file/dir existence and absence

- `[verified]` `bin/plan-schema.sh` — DOES NOT EXIST at HEAD. New file per D-003 of the brainstorm. `Glob 'bin/plan-schema*'` returns no matches.

- `[verified]` `bin/plan-schema-test.sh` — DOES NOT EXIST at HEAD. New file per D-006 of the brainstorm.

- `[verified]` `docs/plans/` — already exists; in `_always_include_paths` per CLAUDE.md "Always-include lockfile catalog" + project-profile File layout. `docs/plans/*.json` is in-scope for the planning stage's `partition_dirty_paths` sweep (the issue-id-in-basename predicate D-004 in `bin/run-local-helpers.sh` matches `eng-N` substring case-insensitively — both `.md` and `.json` qualify).

### Verified — runtime / dependency

- `[verified]` `jq` is a required runtime tool per the project profile Stack section. `require_bin jq` already runs in every dispatch path. `bin/plan-schema.sh` can rely on jq being present without an additional preflight.

### Assumed — to be verified during implement

- `[assumed]` The agent will produce the JSON via the `Write` tool inside the planning dispatch. `Write` is already in the stage-agnostic core tools (implicit, per the project profile's Tool allowlist section preamble — `Read, Write, Edit, Grep, Glob, …` listed). No new allowlist entry needed.

- `[assumed]` `classify_failure "$ident" "$stage" "skip-until-human-acts" "…" 30/31/32` applies `pipeline:halted` via the orchestrator's classify-failure pipeline (consistent with the exit-25 / exit-29 sites). Verify against `bin/classify-failure.sh::classify_failure` during implement; if the policy hand-off is materially different for 30/31/32, the implement agent posts a Linear comment and treats it as a P0 implement defect rather than silently working around it.

- `[assumed]` `bin/poll.sh::_poll_classify_labels` already routes `pipeline:halted` + `pipeline:skip-until-human-acts` into the `slot:"vacate", operator_action_required:true` branch (CLAUDE.md "Slot-occupancy contract"). Adding a new halt-reason token does not require a new classifier branch — verified at the design level in the brainstorm's §9 ADR stress test.

## File Structure

### Modified

- `bin/run-stage.sh` — add `_validate_plan_contract()` + `_post_plan_contract_halt()` after `_validate_dispatch_envelope`'s closing `}`; add a `case "$stage" in planning) … esac` block in `main`'s post-dispatch hook section, after the envelope-validator's caller block and before `push_branch_if_ahead`.
- `bin/common.sh` — extend `failure_outcome_for_exit`'s case statement with 30/31/32 → `plan-contract-malformed | plan-contract-incomplete | plan-contract-missing` outcome tokens.
- `bin/pipeline-events.json` — append `"plan-contract-invalid"` to the `halt_reasons` array.
- `AGENT_PROMPTS.md` — extend §2 Plan Agent's "Output" / "Your task" section with: (a) sibling-`.json` emission instruction at `docs/plans/{date}-{issue_id_lower}-{slug}.json`, (b) inline schema block (machine-readable, mirroring the existing API-Contract block pattern), (c) explicit instruction that the file MUST validate against `bin/plan-schema.sh` and that missing/malformed JSON halts the dispatch with `plan-contract-invalid`.
- `bin/run-stage-test.sh` — append a new test group (ENG-122 K/L/M/N) after the ENG-87 J case, covering integration tests INT1-INT4 from the brainstorm's §D-006.
- `docs/runbooks/recovery.md` *(optional, deferred)* — out-of-scope for this ticket; the operator-resume path is already documented via `--action continue`.

### New

- `bin/plan-schema.sh` — new standalone CLI with `validate <file> [--ident <ENG-N>]` subcommand. Returns 0 / 30 (malformed) / 31 (incomplete) / 32 (missing-file). Schema reference lives in the file's header comment. Ends with the source-and-test sentinel.
- `bin/plan-schema-test.sh` — new test file covering T1-T12 from the brainstorm's §D-006: well-formed, missing-file, malformed-syntax, top-level-not-object, missing-schema-version, wrong-type-issue-id, empty-features, empty-pass-criteria, bogus-kind, unknown-field-warning, issue-id-mismatch, schema-version-2.
- `docs/plans/2026-05-15-eng-122-plan-json-plan-stage-emits-structured-contract-tests.json` — the producer's first artifact (a fixture-of-self, validating the schema by example). Will be written by the implement agent itself as part of Task 6 (the inaugural plan.json). NOTE: This entry is the implement-agent's OWN plan.json — not a checked-in fixture for tests. Tests use mktemp.

## API Contract

No new FE↔BE API surface. The harness has no FE/BE split (Bash-only orchestration per the project profile's Stack section). The closest analogue is the new bash-level CLI surface of `bin/plan-schema.sh`:

- `bash bin/plan-schema.sh validate <file> [--ident <ENG-N>]` → exit 0 (clean) / 30 (malformed-syntax) / 31 (incomplete-required-field) / 32 (missing-file). Stdout: human-readable defect description on non-zero; empty on success.
- Schema-v1 shape (single source of truth = the file-header comment of `bin/plan-schema.sh`):
  ```json
  {
    "plan_schema_version": 1,
    "issue_id": "ENG-<NNN>",
    "features": [
      {
        "id": "F-<n>",
        "summary": "<non-empty string>",
        "pass_criteria": [
          { "kind": "smoke",       "command": "<non-empty>", "expect_exit": 0, "expect_stdout_match": "<regex|null>" },
          { "kind": "file_exists", "path": "<non-empty>" },
          { "kind": "grep",        "path": "<non-empty>", "pattern": "<non-empty>", "expect_match": true }
        ]
      }
    ]
  }
  ```
  Required: `plan_schema_version` (==1), `issue_id` (matches `^ENG-[0-9]+$`), `features[]` (len≥1). Per-feature required: `id` (non-empty string), `summary` (non-empty), `pass_criteria[]` (len≥1). Per-criterion required: `kind` ∈ {`smoke`, `file_exists`, `grep`} plus the kind-specific fields above. Unknown top-level / per-feature / per-criterion fields → exit 0 + stderr warning (D-005 permissive readers).

## Backend Tasks

### Task 0: Rebase onto origin/main

- `depends_on: []`
- `touches: working tree (no source edits)`
- [ ] In the implement worktree, run `git fetch origin main` (sandbox-allowed; `Bash(git fetch:*)` is in the core git family).
- [ ] Run `git rebase origin/main`. Expected: clean fast-forward / 3-way merge (only `CLAUDE.md` upstream, no overlap).
- [ ] Re-verify every `path:line` excerpt in Assumption Inventory by running `Grep` against each anchor token (e.g., `_validate_dispatch_envelope() {`, `29) printf 'envelope-violation' ;;`, `"dispatch-envelope-violation"`) to confirm the anchors still resolve uniquely post-rebase. If any anchor moves to a different line, the content-anchor approach below survives the drift; line-number hints are informational only.
- [ ] If a conflict arises (unexpected — the upstream commit only touches CLAUDE.md, no overlap with this plan's File Structure), STOP and `bash bin/pipeline.sh event ENG-122 verdict halt --reason agent-blocked` with a one-line Linear comment naming the conflict.

### Task 1: Add exit-code taxonomy entries (30/31/32)

- `depends_on: [0]`
- `touches: bin/common.sh::failure_outcome_for_exit`
- [ ] In `bin/common.sh`, locate the `case "$exit_code" in` block in `failure_outcome_for_exit` (anchor: the line `29) printf 'envelope-violation' ;;`). Insert three new case arms AFTER `29) printf 'envelope-violation' ;;` and BEFORE `124) printf 'dispatch-timeout' ;;` (~line 235-236):

  ```bash
  30) printf 'plan-contract-malformed' ;;
  31) printf 'plan-contract-incomplete' ;;
  32) printf 'plan-contract-missing' ;;
  ```
- [ ] Update the function's docblock immediately above (`# Map a run-stage.sh exit code …` at line ~197): no behavior change but if a list of codes is enumerated, add 30/31/32 to it.
- [ ] Update `bin/run-stage.sh`'s top-of-file exit-code legend (anchor: `# Exit codes: 0=success, 10=guards-tripped, ...` block at lines 4-18). Insert `30=plan-contract-malformed (json malformed; ENG-122), 31=plan-contract-incomplete (json missing required field; ENG-122), 32=plan-contract-missing (sibling .json absent post-plan; ENG-122),` AFTER the `29=envelope-violation ...` line and BEFORE the `124=dispatch-timeout ...` line.

### Task 2: Register the halt-reason token

- `depends_on: [0]`
- `touches: bin/pipeline-events.json::halt_reasons`
- [ ] Append `"plan-contract-invalid"` as the last entry of the `halt_reasons` array in `bin/pipeline-events.json` (anchor: the literal `"dispatch-envelope-violation"` is currently the last entry on line 19; add a comma and the new entry as line 20).

  Resulting array tail:
  ```json
  "dispatch-envelope-violation",
  "plan-contract-invalid"
  ```
- [ ] Run `jq '.halt_reasons | length' bin/pipeline-events.json` to confirm the array length increased by 1.

### Task 3: Create `bin/plan-schema.sh` validator CLI

- `depends_on: [1, 2]`
- `touches: bin/plan-schema.sh (new)`
- [ ] Create `bin/plan-schema.sh` with the project-standard preamble (`#!/usr/bin/env bash`, `set -euo pipefail`, `SCRIPT_DIR=…`, `source "$SCRIPT_DIR/common.sh"`).
- [ ] Header comment: include the canonical schema-v1 JSON shape as a fenced JSON block. This is the single source of truth; AGENT_PROMPTS §2's inline schema in Task 5 reproduces it verbatim and `bin/plan-schema-test.sh::T_schema_doc_sync` asserts the two stay in sync.
- [ ] Implement `cmd_validate <file> [--ident <ENG-N>]`:
  - [ ] Parse flags via the existing `while [[ $# -gt 0 ]]; do case … esac; done` idiom (precedent: `bin/pipeline.sh::cmd_event_verdict` at lines 93-101).
  - [ ] If `<file>` does not exist on disk → emit `plan-contract-missing: file not found: <path>` to stdout, return 32.
  - [ ] Run `jq -e 'type == "object"' "$file" >/dev/null 2>&1` to confirm JSON parses AND is a top-level object — non-zero rc → emit `plan-contract-malformed: …` to stdout, return 30. Capture jq's stderr for the message.
  - [ ] For each required top-level field (`plan_schema_version`, `issue_id`, `features`), run a jq existence + type check (precedent: `bin/dispatch.sh:474-481` for the resolve-then-regex pattern). Fail with `plan-contract-incomplete: missing/invalid field <name>: <detail>` → return 31.
  - [ ] Assert `plan_schema_version == 1` (literal integer; reject 2+ AND reject 0/missing/string-1) → on mismatch return 31.
  - [ ] If `--ident <ENG-N>` was passed, assert `.issue_id == <ENG-N>` (defense against stale-template cross-issue copy) → on mismatch return 31.
  - [ ] Iterate `.features[]`: assert `id` non-empty string, `summary` non-empty string, `pass_criteria` array of len≥1.
  - [ ] Iterate each `pass_criteria[]` element: dispatch on `.kind`:
    - [ ] `smoke` → require `command` (non-empty string), `expect_exit` (integer). Optional `expect_stdout_match` (string).
    - [ ] `file_exists` → require `path` (non-empty string).
    - [ ] `grep` → require `path` (non-empty string), `pattern` (non-empty string), `expect_match` (boolean).
    - [ ] Any other `kind` value → return 31 with `plan-contract-incomplete: unknown kind "<value>"`.
  - [ ] Sweep for unknown fields at all three levels (top-level, per-feature, per-criterion). Use jq's `keys - <allowlist>` filter; emit warnings to stderr (NOT stdout — stdout is reserved for the operator-facing defect description) and return 0 if no required-field errors were collected.
  - [ ] Emit `plan-contract-valid: <file>` to stdout on success path; exit 0.
- [ ] Implement `main`: dispatch on `$1` (`validate`); print usage on unknown subcommand and exit 1 (non-classified — the validator itself crashing falls into `_validate_plan_contract`'s catch-all `*) → return 30` branch per D-004).
- [ ] End the file with the source-and-test sentinel `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi`.
- [ ] `chmod +x bin/plan-schema.sh` (orchestrator dispatch already invokes via `bash bin/plan-schema.sh …`, so executable bit is convenience for operators).

### Task 4: Add `_validate_plan_contract` + `_post_plan_contract_halt` to `bin/run-stage.sh`

- `depends_on: [3]`
- `touches: bin/run-stage.sh::_validate_plan_contract, bin/run-stage.sh::_post_plan_contract_halt, bin/run-stage.sh::main`
- [ ] Define `_validate_plan_contract()` IMMEDIATELY AFTER the closing `}` of `_validate_dispatch_envelope` (anchor: the line `_validate_dispatch_envelope() {` opens the function at ~line 883; its closing `}` is at ~line 947, followed by the `# ENG-87 review M1+M2: dispatch_history.jsonl end-row trap.` block-comment). Insert the new function BEFORE that block-comment.

  Function body (key shape, mirrors brainstorm D-004):
  ```bash
  _validate_plan_contract() {
    local PIPELINE_WRITER=orchestrator
    export PIPELINE_WRITER
    local ident="$1"
    local wt; wt="$(issue_dir "$ident")/worktree"
    [[ -d "$wt" ]] || { log "plan-contract: no worktree dir; fail-open"; return 0; }
    local ident_lower; ident_lower="$(printf '%s' "$ident" | tr '[:upper:]' '[:lower:]')"
    local plan_md
    plan_md="$(cd "$wt" && find docs/plans -maxdepth 1 -type f -iname "*${ident_lower}*.md" 2>/dev/null | sort | head -1)"
    if [[ -z "$plan_md" ]]; then
      log "plan-contract: no plan .md found for $ident (handled upstream by exit-25 validator)"
      return 0
    fi
    local plan_json="${plan_md%.md}.json"
    if [[ ! -f "$wt/$plan_json" ]]; then
      _post_plan_contract_halt "$ident" "missing-file" "no sibling JSON found at $plan_json"
      return 32
    fi
    local schema_rc=0
    local schema_out
    schema_out="$(bash "$SCRIPT_DIR/plan-schema.sh" validate "$wt/$plan_json" --ident "$ident" 2>&1)" || schema_rc=$?
    case $schema_rc in
      0)  return 0 ;;
      30) _post_plan_contract_halt "$ident" "malformed"   "$schema_out" ; return 30 ;;
      31) _post_plan_contract_halt "$ident" "incomplete"  "$schema_out" ; return 31 ;;
      *)  _post_plan_contract_halt "$ident" "unknown"     "validator returned unexpected rc=$schema_rc; stdout: $schema_out" ; return 30 ;;
    esac
  }
  ```
- [ ] Define `_post_plan_contract_halt()` immediately after `_validate_plan_contract`'s closing `}` (still before the dispatch-history block-comment).

  Function body (mirrors run-stage.sh:933-943's sanitisation+emission pattern):
  ```bash
  _post_plan_contract_halt() {
    local ident="$1" defect="$2" raw="$3"
    local safe="${raw//<!--/<\\!--}"
    local body
    body="$(printf '<!-- pipeline: verdict result=halt reason=plan-contract-invalid -->\n\nPlan-contract validation failed on dispatch_id=%s stage=planning:\n\n- Defect: %s\n\n```\n%s\n```\n\nSchema source-of-truth: see header comment in `bin/plan-schema.sh`.\n\n**Resume:** fix the JSON (or the plan prompt'\''s emission step), commit on the feature branch, then run `bash bin/pipeline.sh decide %s --action continue`.' \
      "${PIPELINE_DISPATCH_ID:-unknown}" "$defect" "$safe" "$ident")"
    bash "$SCRIPT_DIR/linear.sh" add-comment "$ident" "$body" || true
  }
  ```
- [ ] Add the caller block in `main()` IMMEDIATELY AFTER the envelope-validator's caller block (anchor: the line `rm -f "$(issue_dir "$ident")/.envelope-transcript-${stage}" 2>/dev/null || true` is unique; the closing `;;` + `esac` + `fi` at ~line 1580 terminates the envelope block) and BEFORE the comment `# Push branch BEFORE posting the completion comment so any …` at ~line 1582.

  Caller body:
  ```bash
  # ENG-122: plan-contract validator. Halts plan dispatches whose
  # sibling .json is missing, malformed, or missing required fields.
  # Stage-gated to planning only; skip on scope-approval replay.
  if (( ! skip_dispatch )); then
    case "$stage" in
      planning)
        local _plan_rc=0
        _validate_plan_contract "$ident" || _plan_rc=$?
        case $_plan_rc in
          0) ;;
          30|31|32)
            classify_failure "$ident" "$stage" "skip-until-human-acts" \
              "plan-contract validation failed (rc=$_plan_rc, see linear comment for detail)" "$_plan_rc"
            exit "$_plan_rc"
            ;;
        esac
        ;;
    esac
  fi
  ```

### Task 5: Update `AGENT_PROMPTS.md §2 Plan Agent` to instruct emission

- `depends_on: [3]`
- `touches: AGENT_PROMPTS.md::§2 Plan Agent`
- [ ] In `AGENT_PROMPTS.md`, locate §2 Plan Agent's "Your task" section (anchor: the line `- Produce a plan at docs/plans/{date}-{issue_id_lower}-{slug}.md` at line ~413). Append the following bullets immediately after that line and before the next bullet `- Follow the format of existing plans …`:

  ```
  - Additionally produce a sibling structured contract at docs/plans/{date}-{issue_id_lower}-{slug}.json
    declaring the features the plan commits to building and the pass-criteria each feature must
    satisfy. The JSON is consumed by downstream stages (implement / qa / build) as the
    authoritative target. Schema v1 (single source of truth lives in the header comment of
    bin/plan-schema.sh; this block reproduces it for your convenience — drift between this
    block and the validator is asserted by bin/plan-schema-test.sh):

    ```plan-schema-v1
    {
      "plan_schema_version": 1,
      "issue_id": "{issue_id}",
      "features": [
        {
          "id": "F-1",
          "summary": "<one-line description>",
          "pass_criteria": [
            { "kind": "smoke",       "command": "<bash invocation>", "expect_exit": 0 },
            { "kind": "file_exists", "path": "<path-from-repo-root>" },
            { "kind": "grep",        "path": "<path>", "pattern": "<regex>", "expect_match": true }
          ]
        }
      ]
    }
    ```

    Rules:
    - `plan_schema_version` MUST be the literal integer `1`.
    - `issue_id` MUST equal `{issue_id}` exactly (defense against template-copy across issues).
    - `features[]` MUST contain ≥ 1 feature; each feature MUST have `id` (non-empty), `summary`
      (non-empty), and `pass_criteria[]` (≥ 1).
    - Each `pass_criteria[]` entry's `kind` MUST be one of `smoke | file_exists | grep`. Unknown
      kinds halt the plan stage with `plan-contract-invalid`.
    - Do NOT write scratch JSON fixtures elsewhere in the worktree; write the single canonical
      file at the path above (and only that path).

  - Missing or malformed JSON halts the plan dispatch with `<!-- pipeline: verdict result=halt
    reason=plan-contract-invalid -->`. The validator is detective-only (runs post-dispatch
    in bin/run-stage.sh::_validate_plan_contract); recovery is `bash bin/pipeline.sh decide
    {issue_id} --action continue` after the operator (or a re-dispatch) fixes the JSON.
  ```
- [ ] In §2's "Completion checklist" (anchor: the line `4. **Commit artifacts** (success path only): plan doc on the feature branch with message` at ~line 564), expand step 4 to commit BOTH `.md` AND `.json`:
  - Before: `chore(pipeline): plan for {issue_id}` (commits only the plan doc).
  - After: same commit message, but the staged set MUST include both `docs/plans/{date}-{issue_id_lower}-{slug}.md` AND `docs/plans/{date}-{issue_id_lower}-{slug}.json`.
- [ ] Confirm the fenced block count for §2 remains exactly 2 (the existing fences at lines 350 + 606). The nested ` ```plan-schema-v1 ` block does NOT count because `render-prompt.sh::extract_block`'s fence counter is column-0-only; the schema-v1 block above is indented 4 spaces inside the bulleted list (the "Do NOT use column-0 ``` fences inside a stage's body" rule from CLAUDE.md). Verify with `bash bin/render-prompt-test.sh` post-edit.

### Task 6: Author the inaugural `docs/plans/<basename>.json` (self-validation)

- `depends_on: [3]`
- `touches: docs/plans/2026-05-15-eng-122-plan-json-plan-stage-emits-structured-contract-tests.json (new)`
- [ ] The implement agent writes the JSON for ENG-122 itself, mirroring the structure described in §3's Goal. This serves as the first real plan.json + a fixture-of-self.

  Concrete content (single feature, three pass-criteria covering the three new files + the AGENT_PROMPTS update + the new validator function):
  ```json
  {
    "plan_schema_version": 1,
    "issue_id": "ENG-122",
    "features": [
      {
        "id": "F-1",
        "summary": "bin/plan-schema.sh validator CLI exists, ends with the source-and-test sentinel, and rejects schema-v2 documents",
        "pass_criteria": [
          { "kind": "file_exists", "path": "bin/plan-schema.sh" },
          { "kind": "grep", "path": "bin/plan-schema.sh", "pattern": "if \\[\\[ \"\\$\\{BASH_SOURCE\\[0\\]\\}\" == \"\\$\\{0\\}\" \\]\\]; then main \"\\$@\"; fi", "expect_match": true },
          { "kind": "smoke", "command": "bash bin/plan-schema.sh validate docs/plans/2026-05-15-eng-122-plan-json-plan-stage-emits-structured-contract-tests.json --ident ENG-122", "expect_exit": 0 }
        ]
      },
      {
        "id": "F-2",
        "summary": "bin/run-stage.sh has _validate_plan_contract + _post_plan_contract_halt wired into the post-dispatch hook block",
        "pass_criteria": [
          { "kind": "grep", "path": "bin/run-stage.sh", "pattern": "^_validate_plan_contract\\(\\) \\{", "expect_match": true },
          { "kind": "grep", "path": "bin/run-stage.sh", "pattern": "^_post_plan_contract_halt\\(\\) \\{", "expect_match": true },
          { "kind": "grep", "path": "bin/run-stage.sh", "pattern": "ENG-122: plan-contract validator", "expect_match": true }
        ]
      },
      {
        "id": "F-3",
        "summary": "Exit-code taxonomy includes 30/31/32 and halt_reasons registry includes plan-contract-invalid",
        "pass_criteria": [
          { "kind": "grep", "path": "bin/common.sh", "pattern": "30\\) printf 'plan-contract-malformed'", "expect_match": true },
          { "kind": "grep", "path": "bin/common.sh", "pattern": "31\\) printf 'plan-contract-incomplete'", "expect_match": true },
          { "kind": "grep", "path": "bin/common.sh", "pattern": "32\\) printf 'plan-contract-missing'", "expect_match": true },
          { "kind": "grep", "path": "bin/pipeline-events.json", "pattern": "plan-contract-invalid", "expect_match": true }
        ]
      },
      {
        "id": "F-4",
        "summary": "Tests cover well-formed + missing + malformed JSON, plus integration with run-stage's detective scan",
        "pass_criteria": [
          { "kind": "file_exists", "path": "bin/plan-schema-test.sh" },
          { "kind": "smoke", "command": "bash bin/plan-schema-test.sh", "expect_exit": 0 },
          { "kind": "smoke", "command": "bash bin/run-stage-test.sh", "expect_exit": 0 }
        ]
      }
    ]
  }
  ```

### Task 7: Add validator unit tests at `bin/plan-schema-test.sh`

- `depends_on: [3]`
- `touches: bin/plan-schema-test.sh (new)`
- [ ] Create `bin/plan-schema-test.sh` mirroring the source-and-stub pattern from `bin/scope-check-test.sh`. Top-of-file: `set -euo pipefail`, `PIPELINE_DRY_RUN=1`, mktemp `FIXTURE_DIR`, `pass_at` / `fail_at` helpers (precedent: `bin/scope-check-test.sh:1-40`).
- [ ] T1 — well-formed: write a valid schema-v1 JSON to `$FIXTURE_DIR/t1.json`, invoke `bin/plan-schema.sh validate $FIXTURE_DIR/t1.json --ident ENG-1`, expect exit 0.
- [ ] T2 — missing file: invoke with a non-existent path, expect exit 32.
- [ ] T3 — malformed (broken JSON syntax): write `{...,` (stray trailing comma), expect exit 30.
- [ ] T4 — malformed (not an object): write `[1, 2, 3]`, expect exit 30.
- [ ] T5 — incomplete (missing `plan_schema_version`): valid otherwise, expect exit 31.
- [ ] T6 — incomplete (`issue_id` is integer, not string): expect exit 31.
- [ ] T7 — incomplete (`features: []`): expect exit 31.
- [ ] T8 — incomplete (`features[0].pass_criteria: []`): expect exit 31.
- [ ] T9 — incomplete (`pass_criteria[0].kind == "bogus"`): expect exit 31.
- [ ] T10 — well-formed with unknown top-level field (`roadmap: "..."`): expect exit 0, stderr contains `warning` + `roadmap`.
- [ ] T11 — issue-id mismatch: JSON says `issue_id: "ENG-999"`, `--ident ENG-1` passed → expect exit 31.
- [ ] T12 — schema-version 2: `plan_schema_version: 2`, expect exit 31.
- [ ] T_schema_doc_sync — assert the schema-v1 block in `AGENT_PROMPTS.md §2` (delimited by ` ```plan-schema-v1 ` … ` ``` ` ) parses as valid JSON when its template-token `{issue_id}` is replaced with `ENG-1`, and that the parsed structure matches the canonical schema in `bin/plan-schema.sh`'s header comment by field-set equality. Catches drift between prompt and validator.
- [ ] End the file with the source-and-test sentinel.

### Task 8: Add integration tests in `bin/run-stage-test.sh`

- `depends_on: [4, 6]`
- `touches: bin/run-stage-test.sh`
- [ ] In `bin/run-stage-test.sh`, locate the end of the ENG-87 test group (anchor: the last `pass_at "ENG-87 J:` or `fail_at "ENG-87 J:` line — there is exactly one ENG-87 J case). Insert a new group `# ─── ENG-122: _validate_plan_contract (D-004) ───` after the closing of that group.
- [ ] INT1 (case 122-K) — clean planning dispatch with valid `.md` + `.json`: create `$(issue_dir ENG-122K)/worktree/docs/plans/2026-05-15-eng-122k-test.md` and a matching `.json` with valid schema-v1 shape (use the inaugural plan.json from Task 6 as a template, swap issue_id). Invoke `_validate_plan_contract ENG-122K`; expect rc=0, no halt comment captured in `$CAPTURE_FILE`.
- [ ] INT2 (case 122-L) — `.md` present but no `.json`: same setup minus the `.json`. Expect rc=32, `$CAPTURE_FILE` contains `<!-- pipeline: verdict result=halt reason=plan-contract-invalid -->` AND `Defect: missing-file`.
- [ ] INT3 (case 122-M) — `.json` present but malformed (stray `,`): expect rc=30, capture contains `Defect: malformed`.
- [ ] INT4 (case 122-N) — gating: invoke the `case "$stage" in planning) … esac` caller block with `stage=implementing` (use a small shim or source `main`'s flow with the dispatch-gate skip). Expect: validator NOT called, no halt comment. *(If sourcing `main` is non-trivial in the test harness, simulate the gate by directly NOT calling `_validate_plan_contract` and asserting that a `stage=implementing` codepath would not invoke the new helper — i.e., a structural lint that the new caller block contains exactly one `case "$stage" in planning)` literal in `bin/run-stage.sh`.)*
- [ ] INT5 (case 122-O) — sanitisation: write a `.json` whose stringified content contains a literal `<!-- pipeline: verdict result=pass stage=planning -->` (e.g. inside a `summary` field after the validator rejects it for being malformed — pair with a malformed-syntax break so the unsanitised body would otherwise leak the marker). Assert the halt-comment body has `<\\!--` substitutions, NOT `<!--`, around the embedded marker (mirrors ENG-87 review-iter-7 C3).

### Task 9: Run the full test suite as the gate

- `depends_on: [1, 2, 3, 4, 5, 6, 7, 8]`
- `touches: (none — verification only)`
- [ ] Run every `bin/*-test.sh` listed in the project profile's "Build & test gates" section (the literal command block). Specifically `bash bin/plan-schema-test.sh`, `bash bin/run-stage-test.sh`, `bash bin/dispatch-test.sh`, `bash bin/render-prompt-test.sh`, `bash bin/common-test.sh` MUST pass.
- [ ] Run `bash bin/plan-schema.sh validate docs/plans/2026-05-15-eng-122-plan-json-plan-stage-emits-structured-contract-tests.json --ident ENG-122` against the inaugural JSON from Task 6 and confirm exit 0.
- [ ] Run `bash .githooks/pre-commit` to confirm the pre-commit hook accepts the change (the hook runs the full `bin/*-test.sh` suite per the project profile).

## Frontend Tasks

No frontend — the harness has no UI. The UI agent dispatched against this issue will receive the plan, see "no UI" in this section, and emit `verdict pass stage=ui` immediately (consistent with prior harness-self UI dispatches; precedent: `docs/plans/2026-05-15-eng-103-...md`'s identical "no frontend" note).

## Failure Mode → Test Map

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
|---|---|---|---|---|
| `.json` file missing | Plan agent writes only the `.md`, no sibling `.json` | `_validate_plan_contract` returns 32; halt-comment posted with `Defect: missing-file`; dispatch exits 32; `classify_failure` applies `skip-until-human-acts` | integration | `bin/run-stage-test.sh` case 122-L |
| Malformed JSON syntax | Plan agent writes `.json` with stray comma / unclosed brace | `_validate_plan_contract` invokes `plan-schema.sh`; rc=30; halt-comment with `Defect: malformed`; dispatch exits 30 | integration + unit | `bin/run-stage-test.sh` case 122-M ; `bin/plan-schema-test.sh` T3, T4 |
| Top-level array, not object | `.json` body is `[…]` | `plan-schema.sh` returns 30 (malformed: not an object) | unit | `bin/plan-schema-test.sh` T4 |
| Missing required top-level field | `plan_schema_version` absent or `features` absent | `plan-schema.sh` returns 31; halt-comment with `Defect: incomplete` | unit + integration | `bin/plan-schema-test.sh` T5 ; integration via T9-on-shape (covered by T5 path) |
| Wrong type for required field | `issue_id` is integer, not string | `plan-schema.sh` returns 31 | unit | `bin/plan-schema-test.sh` T6 |
| Empty `features[]` | `features: []` | `plan-schema.sh` returns 31 (len≥1 enforced) | unit | `bin/plan-schema-test.sh` T7 |
| Empty `pass_criteria[]` | One feature with `pass_criteria: []` | `plan-schema.sh` returns 31 | unit | `bin/plan-schema-test.sh` T8 |
| Unknown `kind` in pass-criterion | `kind: "potato"` | `plan-schema.sh` returns 31 with `unknown kind` message | unit | `bin/plan-schema-test.sh` T9 |
| Unknown top-level field (forward-compat) | Extra `roadmap: "..."` field, otherwise valid | `plan-schema.sh` returns 0 + stderr warning naming the unknown field | unit | `bin/plan-schema-test.sh` T10 |
| `issue_id` mismatch (stale template) | `.json` `issue_id: "ENG-999"`, `--ident ENG-1` passed | `plan-schema.sh` returns 31 with `issue_id mismatch` message | unit | `bin/plan-schema-test.sh` T11 |
| Future-schema document | `plan_schema_version: 2` | `plan-schema.sh` returns 31 (this validator only handles v1) | unit | `bin/plan-schema-test.sh` T12 |
| Validator's stdout contains a `<!-- pipeline: verdict result=pass … -->` substring (agent-injected hijack attempt) | Malformed `.json` whose body contains the hijack substring | `_post_plan_contract_halt` sanitises with `<!--` → `<\\!--` and wraps in fenced code block; halt-comment body does NOT contain a parseable `result=pass` marker | integration | `bin/run-stage-test.sh` case 122-O |
| Validator runs on non-planning stage | `stage=implementing` dispatch | `_validate_plan_contract` is NOT invoked; no halt comment; no exit 30/31/32 | integration | `bin/run-stage-test.sh` case 122-N |
| Worktree directory missing post-dispatch | `_validate_plan_contract` called with no `$wt` directory | Returns 0 (fail-open, log warning) — caller's earlier preconditions handle it | unit (could fold into INT) | covered by `bin/plan-schema-test.sh` invocation against a non-existent worktree path indirectly (T2 covers missing-file at the wider validator boundary; the worktree-missing path is detective-only) |
| Plan `.md` itself missing | Plan agent crashed / wrote nothing | `_validate_plan_contract` returns 0 (fail-open) — exit-25 agent-contract validator handles this case upstream | integration (negative-coverage assertion) | `bin/run-stage-test.sh` — covered implicitly by case 122-N's "stage-gate" structure (no `.md`, no validator-run) |
| Multiple plan dispatches on same date | Plan re-runs on the same date | Agent overwrites `.md` + `.json`; validator reads fresh post-dispatch; no cross-dispatch staleness | n/a (no test — verified by design) | (none — relies on filesystem semantics) |

## Test Strategy

**Unit tests (`bin/plan-schema-test.sh`)** — T1-T12 + T_schema_doc_sync. Cover the validator's full enumeration of malformed / incomplete / missing-file shapes plus the D-005 permissive-unknown-field branch plus the inaugural-JSON sanity check. mktemp'd fixtures, no checked-in JSON outside the inaugural plan.json from Task 6. Source-and-stub pattern: test file `source`s `bin/plan-schema.sh` to invoke internal validators if helpful, but the primary mode is end-to-end CLI invocation via `bash bin/plan-schema.sh validate <fixture>` (matches how `_validate_plan_contract` calls it in production).

**Integration tests (`bin/run-stage-test.sh`)** — INT1-INT5 (cases 122-K through 122-O). Cover the wiring between `_validate_plan_contract`, `_post_plan_contract_halt`, `plan-schema.sh`, and the run-stage main-flow gate. Stubbed `linear.sh` captures halt-comment bodies; the test asserts marker shape and content. INT4 (stage-gating) and INT5 (sanitisation) are the two non-obvious regressions.

**Adversarial coverage** — INT5 mirrors the ENG-87 review-iter-7 C3 hijack scenario: an agent-controlled JSON whose stringified content embeds a literal `<!-- pipeline: verdict result=pass -->` substring must not promote the halt INTO a pass under `parse_pipeline_marker`'s family-precedence selector. The sanitisation pattern from `bin/run-stage.sh:933` (`safe="${raw//<!--/<\\!--}"`) plus the fenced-block wrap in the halt body covers this. (Note: the validator emits its stdout under jq's parser; the marker substring would have to come from a quoted string inside the JSON, which jq surfaces verbatim. The sanitisation runs on the validator's stdout INSIDE `_post_plan_contract_halt`, so the chain is closed.)

**Smoke** — Task 9's invocation `bash bin/plan-schema.sh validate docs/plans/<inaugural>.json --ident ENG-122` is the smoke gate; the inaugural plan.json from Task 6 is also a pass_criteria target for itself (F-1's third criterion). Self-test by construction.

**No e2e tests** — the harness's e2e is the existing `PIPELINE_DRY_RUN=1 bash bin/dry-run.sh` path; this plan does not extend it. Integration coverage at the run-stage layer is sufficient.

### Test-gate closure sweep (feasibility sub-check)

No tokens are REMOVED from production code by this plan. Every change is additive: new exit codes, new halt-reason entry, new validator function, new caller block, new files. No sibling test file pins a soon-to-be-removed token. The feasibility persona's test-gate closure check is satisfied trivially.

The one near-miss: `bin/dispatch-test.sh` asserts the per-stage allowed-tool list (Group 5 fixtures); no new allowlist entry is added or removed in this plan (the plan-stage `--allowed-tools` already grants `Write` implicitly via core-tools), so no allowlist test is affected.

## Persona review notes (recorded post-self-review; see step-3 gate)

Iteration 1: 5/5 personas PASS, 0 P0 findings. Gate satisfied; proceeding to commit + stage-summary.

- **feasibility — PASS, 0 P0.** Every `path:line` excerpt in the Assumption Inventory verified against the current tree. Branch-base freshness confirmed (`HEAD..origin/main` = `55268f2` + `9cb9c65`, CLAUDE.md-only, no overlap with this plan's File Structure). New files `bin/plan-schema.sh` and `bin/plan-schema-test.sh` absent at HEAD (correct). All Backend Task content anchors unique and present. Test-gate closure sweep clean: no tokens removed by this plan, no sibling test file pins a to-be-added token in a way that would force a same-PR update.
- **scope — PASS, 0 P0.** Every task and File Structure entry traces to a brainstorm decision (D-001 through D-006) or an explicit Linear scope bullet. No reader work, no schema-v2 speculation, no scaffold-subcommand creep. Task 6 (inaugural plan.json) is the deliverable per AC#1 (every plan dispatch produces a sibling .json), not gold-plating.
- **coherence — PASS, 0 P0.** Goal matches brainstorm §1 Problem + §2 Decisions. Every File Structure entry has task coverage (no orphans). Every brainstorm §5 Error Handling row + every §6 Edge Case has a corresponding Failure Mode → Test Map entry. Schema is consistent across AGENT_PROMPTS §2 block, validator CLI shape, and the inaugural plan.json (Task 6). T_schema_doc_sync (Task 7) enforces ongoing sync.
- **design — PASS, 0 P0** (after iteration-1 re-dispatch with a clarified brief; the first iteration's design persona misread its task and flagged the absence of yet-to-be-implemented files as "P0", which is an implementation-state observation, not a plan defect). Architectural rules respected: `_validate_plan_contract` lives in `run-stage.sh` (correct lane), halt-comments flow through `bin/linear.sh add-comment` (correct chokepoint), exit codes added to `failure_outcome_for_exit`, halt-reason added to `pipeline-events.json`, `bin/plan-schema.sh` follows the single-CLI-with-subcommands convention, sentinel pattern explicit. No circular deps. No missed allowlist additions (Write is implicit in stage-agnostic core).
- **product — PASS, 0 P0.** All three ACs concretely realised: AC#1 → Task 5 (prompt instructs emission) + Task 6 (inaugural). AC#2 → Task 3 + Task 4 + Task 1 (halt with structured failure reason). AC#3 → Task 7 + Task 8 (well-formed + missing + malformed coverage). User-recognisable language throughout (artifact name, halt-reason, validator script, exit codes). No problem drift; proportional scope.

Status line (for stage summary): `Personas: 5/5 PASS · gate P0: 0 · proceeding to implementing`.

