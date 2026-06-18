---
linear: ENG-204
date: 2026-06-17
topic: Apply orchestrator-merge to plan.json — content-only body, schema envelope merged in-dispatch via a new `bin/plan-schema.sh prepare` subcommand.
---

# Plan — ENG-204: Apply orchestrator-merge to `plan.json`

## Goal

The planning agent emits a content-only `plan.body.json` at `$(issue_dir "$ident")/plan.body.json`; a new `bash bin/plan-schema.sh prepare --body … --md … --ident …` subcommand merges the schema envelope (`{plan_schema_version: 1, issue_id: "ENG-N"}`) onto the body via `merge_artifact_envelope` and writes the canonical `docs/plans/<date>-<eng>-<slug>.json` in the worktree; the agent commits `.md` + canonical `.json` exactly as today, and `_validate_plan_contract` (unchanged) gates the HEAD-committed merged canonical.

## Assumption Inventory

Branch-base freshness: `HEAD..origin/main` is NON-empty at plan time — `7396f31 feat(eng-215): …`, `84b7050 Merge pull request #180 …`, `f7e4e34 feat(ENG-214): drop paranoid [[ -x metrics.sh ]] guard from merge_artifact_envelope`, plus the ENG-214/ENG-215 plan/brainstorm chore commits. The one substantive upstream change to a file in this plan's File Structure is ENG-214's drop of the `[[ -x "$(dirname "${BASH_SOURCE[0]}")/metrics.sh" ]]` conjunct from `bin/common.sh::merge_artifact_envelope` line 736. The drop does NOT change the helper's signature, exit codes, or merge contract — it only widens the conditions under which the `envelope-overwrite` metric emits. ENG-204's caller (`cmd_prepare`) sees no behavioural diff. **Task 0 (rebase onto origin/main) is therefore CLEAN drift, not DIRTY drift**; no `pipeline:supersede` request needed. All `path:line` excerpts below are recorded against current branch HEAD (pre-rebase); content anchors are used everywhere so the references survive the rebase.

| # | Assumption | Evidence (verified by direct read at HEAD) |
|---|---|---|
| A1 | `bin/plan-schema.sh:113-127` requires `plan_schema_version == 1` and emits `plan-contract-incomplete: plan_schema_version must be 1` rc=34 on miss. | Read confirms `_emit_incomplete "plan_schema_version must be 1, got: $ver"; return 34` at line 125-126; the surrounding numeric-type guard is at lines 120-123. |
| A2 | `bin/plan-schema.sh:129-140` enforces `issue_id` regex `^ENG-[0-9]+$`; emits `plan-contract-incomplete: issue_id must be …` rc=34 on miss/malformed. | Read confirms `[[ "$issue_id_val" =~ ^ENG-[0-9]+$ ]]` at line 137 and emit/return 34 at lines 138-139. |
| A3 | `bin/plan-schema.sh::main` dispatcher at lines 371-382 uses a `case "$subcmd"` over `{validate, validate-md}`; ELSE arm prints usage + `exit 33`. New `prepare)` arm slots between `validate-md)` and `*)`. | Read confirms the exact shape at lines 371-382; the `*)` arm is the only block to push. |
| A4 | `bin/plan-schema.sh:51-55` sources `bin/common.sh`, so `merge_artifact_envelope` and `issue_dir` are in scope for any new function. | Read confirms `source "$SCRIPT_DIR/common.sh"` at line 55 (after `set -euo pipefail` at 51). |
| A5 | `bin/common.sh::merge_artifact_envelope` (lines 713-742) takes `<body> <env-json> <canonical>` and returns 0/39 (body malformed)/41 (body missing)/42 (body symlink)/50 (mktemp / jq / mv write fail). Body size cap is `0 < sz <= 65536` (line 718). `mktemp` lands beside `$canonical` (line 724), so the `mv` is intra-FS. | Read confirms each branch. |
| A6 | `bin/common.sh::issue_dir <ident>` returns `$PROJECT_STATE_DIR/<ident>` (line 71). | Read confirms `printf '%s/%s' "$PROJECT_STATE_DIR" "$issue"`. |
| A7 | `bin/common.sh::qa_payload_body_path` at lines 99-103 is the sibling shape for the new `plan_body_path` helper. Both are exported via the `export -f` list at line 961. | Read confirms; line 961 currently enumerates `qa_payload_body_path qa_predicate_body_path` at the tail. |
| A8 | `bin/common.sh::failure_outcome_for_exit` (lines 759+) maps `33 → plan-contract-malformed`, `34 → plan-contract-incomplete`, `35 → plan-contract-missing`. No new codes needed for ENG-204. | Verified by tracing the existing `_post_plan_contract_halt` case-arms at `bin/run-stage.sh:1376-1378` (`33 → plan-contract-malformed`, `34 → plan-contract-incomplete`, `35 → plan-contract-missing`); the failure_outcome table is the inverse of those arms. |
| A9 | `bin/render-prompt.sh::PROMPT_RESOLVERS` is a newline-separated `token=function` string at lines 40-66; resolver functions live at lines 274-310; main() binds `_RENDER_*` globals at lines 683-695. The exact sibling shape `_RENDER_QA_PAYLOAD_BODY_PATH="$(qa_payload_body_path "$issue_id")"` is at line 687. | Read confirms PROMPT_RESOLVERS contents (lines 40-66), the `_resolve_qa_payload_body_path`/`_resolve_qa_predicate_body_path` shape at lines 289-290, and the main() binding at lines 687-688. |
| A10 | `bin/render-prompt.sh::_write_rendered_paths_sidecar` at lines 97-132 is the **closed-allowlist contract surface** (ENG-156 D-004). The block lists path-shaped resolvers explicitly — DRYing into a loop would break the closed-allowlist contract per the in-file comment at lines 101-104. The qa-body siblings are at lines 113-114. | Read confirms; the function head at line 97 and the comment block at 101-104 are the contract-surface anchor. |
| A11 | `bin/run-stage.sh::_clear_current_stage_slots` (lines 949-981) clears `stage-summary-${stage}.md`, `wait-${stage}.json`, `.rendered-paths-${stage}` uniformly; stage-gated extensions exist for `reviewing` (line 962-964) and `qa` (line 975-980). NO planning-stage branch today. | Read confirms; the `if [[ "$stage" == "reviewing" ]]` and `if [[ "$stage" == "qa" ]]` branches are the existing pattern to mirror. |
| A12 | `bin/run-stage.sh::_validate_plan_contract` (lines 1303-1382) gates the planning→implementing transition on a HEAD-committed `.md` (via `git ls-tree -r HEAD -- docs/plans/`) + sibling `.json` (via `git ls-tree --name-only -r HEAD -- "$plan_json"`), then runs `bash "$SCRIPT_DIR/plan-schema.sh" validate "$wt/$plan_json" --ident "$ident"` (line 1355-1356) and `validate-md` (line 1366). NO code change for ENG-204. | Read confirms; the `_post_plan_contract_halt` calls + return-codes 33/34/35 are at lines 1376-1378. |
| A13 | `bin/dispatch.sh::allowed_tools_for` case-arm for planning is at line 650, base list `Read,Write,Edit,Grep,Glob,TaskCreate,Bash(git log:*),…,Bash(bash bin/pipeline.sh:*)` — does NOT include `plan-schema.sh`. The dual-path convention (`.pipeline/bin/X.sh` AND `bin/X.sh`) is documented at lines 622-633. | Read confirms; the appended sibling pair `Bash(bash .pipeline/bin/plan-schema.sh:*),Bash(bash bin/plan-schema.sh:*)` matches every other dual-path entry in the same line. |
| A14 | `AGENT_PROMPTS.md` §2 lives at lines 371-735 (next H2 `## 3.` is at line 736). The `Your task:` body at line 435 instructs: (line 436) "Produce a plan at docs/plans/{date}-{issue_id_lower}-{slug}.md", (line 437) "Additionally produce a sibling structured contract at docs/plans/{date}-{issue_id_lower}-{slug}.json …". The `plan-schema-v1` fenced block sits at lines 442-458 with the boilerplate keys at lines 444 (`plan_schema_version`) and 445 (`issue_id`). The "Required: …" sentence is at line 460. | Read confirms; `grep -n "^## "` shows §2 spans 371→735, and `grep -n plan-schema-v1` returns line 442. |
| A15 | `bin/verify-qa.sh::cmd_validate` at lines 625-680 is the canonical in-dispatch merge subcommand template (`--body` flag with `merge_artifact_envelope` call at line 671 and caller-side rc remap at lines 673-680: 39→42, 41→44, 42→42, 50→42). The ENG-204 `cmd_prepare` mirrors this pattern verbatim with 39→33, 41→35, 42→33, 50→33. | Read confirms; the `--body` symlink/realpath/PROJECT_STATE_DIR fence pattern at lines 640-665 is the security template to copy. |
| A16 | `bin/plan-schema-test.sh::T_schema_doc_sync` is at lines 226-265 and hardcodes `canonical_keys="features,issue_id,plan_schema_version"` at line 253; it extracts the `plan-schema-v1` fenced block from `AGENT_PROMPTS.md` (line 236-240) and asserts the prompt block keys equal the canonical keys. Post-ENG-204 the prompt block keyset shrinks to `{features}` while the validator's keyset stays `{features, issue_id, plan_schema_version}` — the assertion at line 254 MUST be reframed (see Task T6). | Read confirms line numbers and the literal `canonical_keys=…` string at line 253. |
| A17 | `bin/agent-prompts-content-test.sh` is the prompt-content assertion surface; ENG-203 added AP-2..AP-4 (line 540-553) anchoring `s6="$(section_body "## 6. QA Agent")"` (line 76 / 2046). The `s2="$(section_body "## 2. Plan Agent")"` anchor is at lines 67 and 1535 — the ENG-204 PC-1..PC-7 cases attach to those `s2` blocks. | Read confirms; the test uses `grep -qF` against the §-body string. |
| A18 | `bin/run-stage-test.sh::ENG-87 _clear_current_stage_slots` cases start at line 4645; the ENG-119 reviewing-stage clear cases at lines 5809-5836 are the sibling shape to mirror for planning (seed file, call helper with target stage, assert absent / present). | Read confirms `_clear_current_stage_slots ENG-119P reviewing` at line 5815 and the cross-stage preservation case at line 5828. |
| A19 | jq `+` on objects is right-biased (right operand wins); `merge_artifact_envelope` at line 726 uses `$b[0] + $env` with `$env` (the orchestrator-constructed envelope) on the right, so a body that mistakenly emits `plan_schema_version: "v1"` or `issue_id: "ENG-99"` is silently overwritten by the canonical envelope values. The `envelope-overwrite` metric fires for forensic surfacing (lines 729-740). | Read confirms; ENG-203's design memory + the `qa-payload fix is ENG-203 not prompt` operator memory entry pin this contract on the qa side. |
| A20 | `partition_dirty_paths` scope (CLAUDE.md "Sweep + scope partition" + ENG-87 D-004 issue-id constraint): `docs/plans/<date>-<eng>-<slug>.{md,json}` is in-scope on planning by the always-include `docs/` catalog. The new `$(issue_dir)/plan.body.json` lives under `$PROJECT_STATE_DIR`, OUTSIDE the worktree, so the post-stage sweep never sees it. | Verified by `bin/common.sh::issue_dir` returning `$PROJECT_STATE_DIR/…` (line 71) and CLAUDE.md "Sweep + scope partition" stating sweep operates on `$TARGET_REPO`-relative dirty paths. |
| A21 | `bin/run-stage.sh::_clear_current_stage_slots` is invoked at line 2405 immediately before dispatch — so the body sidecar is cleared before render-prompt resolves `{plan_body_path}`. Loopback `planning → brainstorming` (verdict fail) clears brainstorming's slots, NOT planning's — by the same stage-gating that protects qa-files from being wiped on implementing dispatches. | Read confirms; the gate at line 962 (`if [[ "$stage" == "reviewing" ]]`) is the stage-gating pattern. |
| A22 | The new `Bash(bash bin/plan-schema.sh:*)` pattern is matchable by claude's sandbox under the same shape as the existing `Bash(bash bin/verify-qa.sh:*)` (granted for qa via `bin/dispatch.sh:654`). The matcher anchors on the FIRST token (`bash`) and treats the rest as a prefix that admits any post-`bash bin/plan-schema.sh` argv. | **assumed** — consistent with how `Bash(bash bin/verify-qa.sh:*)` already matches `verify-qa.sh validate --body …` in qa dispatches. Implementation verifies via the existing dispatch test's fixture run. |
| A23 | `bin/dispatch.sh::_dispatch_tools_autotests` at line ~672-679 globs `bin/*-test.sh` and emits one literal `Bash(bash <file>:*)` per script for `implementing`/`qa`. New test files (`bin/plan-schema-adversarial-test.sh` if absent — see Task T7) are picked up with NO allowlist edit; the pre-commit hook also globs every `bin/*-test.sh`. | Read confirms autotests are gated to implementing/qa and globbed from worktree cwd. |
| A24 | `bin/plan-schema-adversarial-test.sh` exists today (referenced by the brainstorm at §D-009); cases PA-1..PA-3 attach there. | `ls bin/plan-schema-adversarial-test.sh` (verified by Glob in Task #1). |
| A25 | `learned-rules/harness/project-profile.md::"## Build & test gates" Test command` runs every `bin/*-test.sh` on disk via `bash .githooks/pre-commit` — this is GLOB-based, not enumerated. Adding a new `bin/*-test.sh` requires NO profile edit. The test-gate add-side closure sweep is therefore VACUOUS for this plan (no new test file is added; all new tests slot into existing `bin/plan-schema-test.sh`, `bin/plan-schema-adversarial-test.sh`, `bin/agent-prompts-content-test.sh`, `bin/run-stage-test.sh`, `bin/render-prompt-test.sh`). | CLAUDE.md "Tests" section + the existing pre-commit hook globbing pattern documented in Project profile addendum. |
| A26 | Test-gate **removal-side** closure sweep: this plan REMOVES the literal `plan_schema_version` and `issue_id` from `AGENT_PROMPTS.md`'s `plan-schema-v1` fenced block. `bin/plan-schema-test.sh::T_schema_doc_sync` (line 253) contains `canonical_keys="features,issue_id,plan_schema_version"` — the substring `plan_schema_version` and `issue_id` appear inside the canonical_keys string. The test file IS listed in File Structure (Task T6 reframes the assertion to a body-only keyset plus a separate validator-vs-envelope-union assertion). NO other sibling test contains the removed tokens. | `grep -rn "plan_schema_version\|issue_id" bin/*-test.sh` returns only `plan-schema-test.sh:253` (canonical_keys), `agent-prompts-content-test.sh:540-545` (the ENG-203 `dispatch_id` AP-2 case — DIFFERENT token, unrelated), and uses of `issue_id` inside generic test-fixture payloads (which remain valid post-ENG-204 because the FIXTURES still need to write a full plan.json for the validator to test). |

## System invariants

- INV-1: The plan canonical `.json` MUST be in branch HEAD (committed) before `_validate_plan_contract` runs, OR the validator halts with `plan-contract-missing`. ENG-204 preserves this by leaving the agent's `git add` + `git commit` flow unchanged — only the *writer* of the canonical bytes changes (helper instead of agent's `Write`). `verified_by: bin/run-stage.sh:_validate_plan_contract`
- INV-2: The envelope keyset MUST be exactly `{plan_schema_version: 1, issue_id: "<ident>"}` (two keys). Any third envelope key would silently overwrite a body content key under jq's right-biased merge. `verified_by: task:T8` (plan-schema-test.sh P-1 envelope-keyset-closure case asserts the env_json constructed by `cmd_prepare` has exactly two keys via `jq -r 'keys | sort | join(",")'` on the merged canonical minus `features`).
- INV-3: The `prepare` subcommand's body and `--md` argv paths MUST be fenced against symlinks and realpath escapes (body → must resolve under `$PROJECT_STATE_DIR`; --md → must end in `.md`, not be a symlink, and resolve under cwd). The canonical destination is derived from the **post-realpath** `--md` path, NOT the unresolved argv literal (security defense-in-depth against a future stage gaining `Bash(ln:*)` / `Bash(mv:*)`). `verified_by: task:T8` (plan-schema-test.sh P-7/P-13/P-14/P-15 cases pin each fence).
- INV-4: The body sidecar lives at `$(issue_dir "$ident")/plan.body.json` — under `$PROJECT_STATE_DIR`, OUTSIDE the worktree. `partition_dirty_paths` never sees it; the post-stage sweep cannot misclassify it. `verified_by: task:T8` (render-prompt-test.sh R-1 asserts `_resolve_plan_body_path` returns `$(issue_dir ident)/plan.body.json` — the resolved path lives under `$PROJECT_STATE_DIR` because `issue_dir` composes that way per A6).
- INV-5: The body sidecar is **cleared on every planning-stage dispatch start** (ENG-87 cross-dispatch staleness primitive). The orchestrator's `_clear_current_stage_slots` planning-stage extension MUST `rm -f "$d/plan.body.json"` AND MUST NOT clear it on other stages (preserves the body across loopback `planning → brainstorming → planning`, matching the ENG-87 contract "current-stage only"). `verified_by: task:T8` (run-stage-test.sh OS-1 asserts clear on planning; OS-3 asserts non-clear on implementing/qa/reviewing).
- INV-6: The `{plan_body_path}` resolver MUST appear in the `_write_rendered_paths_sidecar` closed-allowlist (ENG-156 D-004 contract surface) — otherwise a sandbox denial against the body path produces no row in the `.rendered-paths-<stage>` sidecar and the post-dispatch Phase B detective has no contract surface to match. `verified_by: task:T8` (render-prompt-test.sh R-2 asserts `plan_body_path\t<value>` appears in the sidecar when `_RENDER_PLAN_BODY_PATH` is bound).
- INV-7: `merge_artifact_envelope` is taxonomy-agnostic; per-caller rc remap is mandatory. `cmd_prepare` maps helper's `39 → 33`, `41 → 35`, `42 → 33`, `50 → 33` to stay within plan-schema's `{33, 34, 35}` taxonomy and preserve `failure_outcome_for_exit`'s existing mapping (`33 → plan-contract-malformed`, `34 → plan-contract-incomplete`, `35 → plan-contract-missing`). `verified_by: task:T8` (P-2/P-4/P-5/P-6/P-8/P-16 each exercise a helper rc and assert the remapped cmd_prepare rc).

## File Structure

### Modified (in-place edits)

- `bin/plan-schema.sh` — add `cmd_prepare` function (sibling of `cmd_validate` / `cmd_validate_md`); add `prepare)` case-arm in `main()`; extend header-comment usage doc with `prepare` and its 33/34/35 exit codes. ~80 added.
- `bin/common.sh` — add `plan_body_path <ident>` helper (sibling of `qa_payload_body_path`); append `plan_body_path` to the `export -f` list. ~6 added.
- `bin/render-prompt.sh` — add `plan_body_path=_resolve_plan_body_path` row to `PROMPT_RESOLVERS`; add `_resolve_plan_body_path` function (sibling of `_resolve_qa_payload_body_path`); bind `_RENDER_PLAN_BODY_PATH="$(plan_body_path "$issue_id")"` in `main()` (sibling of the qa-body lines); add `plan_body_path` row to `_write_rendered_paths_sidecar`'s closed-allowlist block. ~5 added.
- `bin/dispatch.sh` — append `,Bash(bash .pipeline/bin/plan-schema.sh:*),Bash(bash bin/plan-schema.sh:*)` to the planning case-arm in `allowed_tools_for`. ~1 changed.
- `bin/run-stage.sh` — extend `_clear_current_stage_slots` with a planning-stage branch (`if [[ "$stage" == "planning" ]]; then rm -f "$d/plan.body.json" 2>/dev/null || true; fi`). ~3 added.
- `AGENT_PROMPTS.md` (§2 plan) — strip `"plan_schema_version": 1,` and `"issue_id": "{issue_id}",` from the `plan-schema-v1` fenced block; rewrite the "Additionally produce a sibling structured contract …" paragraph to instruct body-write at `{plan_body_path}` + `prepare` invocation; rewrite the "Required: …" paragraph to drop envelope-key mentions; add a `prepare` rc-handling step before commit. ~20 changed, no new fences.
- `bin/plan-schema-test.sh` — reframe `T_schema_doc_sync` (line 253) to split into two assertions: (1) prompt-block keyset equals body keyset (`{features}`); (2) validator's expected keyset equals body keyset ∪ envelope keyset (`{features, plan_schema_version, issue_id}`). Add new cases P-1..P-16 for `cmd_prepare`. ~200 added, ~15 changed.
- `bin/plan-schema-adversarial-test.sh` — add cases PA-1 (body envelope-key collision silently overwritten), PA-2 (unknown content key permitted), PA-3 (full prepare → validate chain end-to-end). ~80 added.
- `bin/agent-prompts-content-test.sh` — add §2 prompt-content cases PC-1..PC-7 (boilerplate-key absence from fenced block; `{plan_body_path}` token present; literal `prepare …` invocation shape; `features` keyword retained; `prepare` rc-handling sentence present). ~80 added.
- `bin/run-stage-test.sh` — add `_clear_current_stage_slots` cases OS-1..OS-4 (planning-stage clears `plan.body.json`; preserved on other stages; doesn't touch qa/review siblings; merged canonical passes `_validate_plan_contract` end-to-end). ~120 added.
- `bin/render-prompt-test.sh` — add R-1 (`_resolve_plan_body_path` returns `$(issue_dir ident)/plan.body.json` when `_RENDER_PLAN_BODY_PATH` bound) and R-2 (`_write_rendered_paths_sidecar` emits `plan_body_path\t<value>`). ~40 added.
- `docs/runbooks/recovery.md` — add §16 "plan-contract merge failure" entry: agent body missing/malformed → `prepare` rc≠0 → agent halts (per the new prompt step) OR orchestrator's `_validate_plan_contract` re-fires halt-reason `plan-contract-invalid`; recovery `bash bin/pipeline.sh decide <ENG-N> --action continue`. Include a grep recipe pointing at `$PROJECT_STATE_DIR/<slug>/logs/<ident>-planning-*.log` for the `prepare`'s stderr. ~25 added.

### NOT modified (explicitly preserved)

- `bin/run-stage.sh::_validate_plan_contract` — gates run on the merged canonical unchanged.
- `bin/run-stage.sh::_post_plan_contract_halt` — `<!--` sanitisation already covers helper stderr verbatim.
- `bin/common.sh::merge_artifact_envelope` — ENG-203 helper reused as-is.
- `bin/common.sh::failure_outcome_for_exit` — 33/34/35 mappings unchanged.
- `bin/pipeline-events.json` — `envelope-overwrite` metric token (ENG-203) covers the planning case via `PIPELINE_STAGE=planning`; no new vocabulary.
- `bin/reconcile.sh` / `bin/reconcile-test.sh` — frontmatter `linear: ENG-N` doc-to-issue ownership unchanged.
- `learned-rules/harness/project-profile.md` — no new gate-runnable test file added, no profile edit needed (A25).

## API Contract

No new API surface. (The harness has no FE↔BE API; `cmd_prepare` is a Bash CLI subcommand, not a transport-layer endpoint. Its argv/exit-code contract is documented in `bin/plan-schema.sh`'s header comment and pinned by Task T6.)

## Backend Tasks

### Task 0: Rebase onto origin/main

- `depends_on: []`
- `touches: <none — git workflow only>`
- [ ] Run `git fetch origin main` from the worktree root.
- [ ] Run `git rebase origin/main` from the worktree root.
- [ ] Resolve any conflicts (NONE expected — origin/main's only substantive change to a touched file is ENG-214's `[[ -x ]]` guard drop in `bin/common.sh::merge_artifact_envelope`, which does NOT conflict with this plan's adjacent additions to `bin/common.sh` `plan_body_path` or the line-961 `export -f` extension).
- [ ] Re-verify Assumption Inventory `path:line` references survived the rebase by spot-checking `bin/plan-schema.sh:113-140` (envelope-key validators), `bin/common.sh:99-103` (qa_payload_body_path sibling), `bin/render-prompt.sh:97-132` (sidecar allowlist), `bin/run-stage.sh:949-981` (`_clear_current_stage_slots`), `AGENT_PROMPTS.md:442-465` (plan-schema-v1 fenced block). If ANY anchor has drifted, halt and re-plan (do not attempt a partial fix).

### Task 1: Add `plan_body_path` helper to `bin/common.sh`

- `depends_on: [0]`
- `touches: bin/common.sh::plan_body_path, bin/common.sh::export -f list (line ~961)`
- [ ] In `bin/common.sh`, AFTER the `qa_predicate_body_path()` function definition (content anchor: the closing `}` of the function that follows the `qa_predicate_body_path() {` opener), add a new sibling function `plan_body_path()` that takes `<ident>` positional, dies on empty arg, and prints `$(issue_dir "$issue")/plan.body.json`. Match the exact comment/shape of the qa-body siblings.
- [ ] In the `export -f issue_dir compute_pipeline_content_hash …` line (content anchor: the only `export -f` line in the file; currently tail enumerates `… qa_payload_body_path qa_predicate_body_path`), append ` plan_body_path` after `qa_predicate_body_path`.

### Task 2: Add `cmd_prepare` subcommand to `bin/plan-schema.sh`

- `depends_on: [1]`
- `touches: bin/plan-schema.sh::cmd_prepare (new), bin/plan-schema.sh::main case (line ~371)`
- [ ] In `bin/plan-schema.sh`, AFTER the `cmd_validate_md()` function (content anchor: the closing `}` of `cmd_validate_md` — BEFORE the `main()` function definition that starts `main() {`), insert a new `cmd_prepare()` function with the exact shape documented in the brainstorm §D-003 code block. Argv parser captures `--body`, `--md`, `--ident`; validator stages: (a) all three required (rc=34 on miss/empty); (b) `--ident` matches `^ENG-[0-9]+$` (rc=34); (c) `--md` ends in `.md` (rc=33); (d) `--body` not symlink + `-f` exists + realpath under `$PROJECT_STATE_DIR` (rc=33 / rc=35 for missing); (e) `--md` not symlink + parent dir resolves + realpath under cwd (rc=33). Then `canonical="${md_real%.md}.json"` (post-realpath); `env_json="$(jq -nc --arg ii "$ARG_IDENT" '{plan_schema_version: 1, issue_id: $ii}')"`; `PIPELINE_ISSUE_ID="$ARG_IDENT" PIPELINE_STAGE=planning merge_artifact_envelope "$ARG_BODY" "$env_json" "$canonical" || merge_rc=$?`. Caller-side rc remap: `0 → 0` (prints `plan-contract-prepared: <canonical>`), `39 → 33`, `41 → 35`, `42 → 33`, `50 → 33`, `* → 33`.
- [ ] In `bin/plan-schema.sh::main`'s `case "$subcmd"` block (content anchor: the literal `validate-md) cmd_validate_md "$@" ;;` line — the new `prepare)` arm slots immediately after it, BEFORE the `*)` arm), add `prepare)    cmd_prepare "$@" ;;`.
- [ ] In the same `case` block's `*)` arm's `printf 'Usage: …'`, update the usage string to include `prepare --body <body> --md <md> --ident <ENG-N>`.
- [ ] In `bin/plan-schema.sh`'s header comment block (content anchor: the line `#   bash bin/plan-schema.sh validate <file> [--ident <ENG-N>]`), add a third `bash bin/plan-schema.sh prepare --body <body> --md <md> --ident <ENG-N>` line and an exit-code table for prepare (`0` success → prints `plan-contract-prepared: <path>`; `33` body parse/symlink/realpath/write-fail; `34` flag missing or ident regex; `35` `--body` file not found).

### Task 3: Add `plan_body_path` token + resolver + sidecar entry to `bin/render-prompt.sh`

- `depends_on: [1]`
- `touches: bin/render-prompt.sh::PROMPT_RESOLVERS, bin/render-prompt.sh::_resolve_plan_body_path (new), bin/render-prompt.sh::_write_rendered_paths_sidecar, bin/render-prompt.sh::main() resolver-binding stanza`
- [ ] In `bin/render-prompt.sh`'s `PROMPT_RESOLVERS` block (content anchor: the line `qa_predicate_body_path=_resolve_qa_predicate_body_path`), add a new line `plan_body_path=_resolve_plan_body_path` immediately after (BEFORE the closing `'` of the registry string).
- [ ] In the resolver-function cluster (content anchor: the line `_resolve_qa_predicate_body_path() { printf '%s' "$_RENDER_QA_PREDICATE_BODY_PATH"; }`), insert `_resolve_plan_body_path() { printf '%s' "$_RENDER_PLAN_BODY_PATH"; }` immediately after.
- [ ] In `bin/render-prompt.sh::_write_rendered_paths_sidecar`'s closed-allowlist block (content anchor: the line `[[ -n "${_RENDER_QA_PREDICATE_BODY_PATH:-}" ]] && printf 'qa_predicate_body_path\t%s\n' "$_RENDER_QA_PREDICATE_BODY_PATH"`), add a new sibling line `[[ -n "${_RENDER_PLAN_BODY_PATH:-}" ]] && printf 'plan_body_path\t%s\n' "$_RENDER_PLAN_BODY_PATH"` immediately after.
- [ ] In `bin/render-prompt.sh::main()`'s resolver-binding stanza (content anchor: the line `_RENDER_QA_PREDICATE_BODY_PATH="$(qa_predicate_body_path "$issue_id")"`), insert `_RENDER_PLAN_BODY_PATH="$(plan_body_path "$issue_id")"` immediately after.

### Task 4: Add `bin/plan-schema.sh:*` to planning's allowlist in `bin/dispatch.sh`

- `depends_on: [2]`
- `touches: bin/dispatch.sh::allowed_tools_for "planning" base list`
- [ ] In the `allowed_tools_for` function's `case "$1" in` block (content anchor: the `planning)` arm line beginning `planning)       base='Read,Write,Edit,Grep,Glob,TaskCreate,Bash(git log:*),`, with sibling pair `Bash(bash .pipeline/bin/pipeline.sh:*),Bash(bash bin/pipeline.sh:*)' ;;` at the end), append `,Bash(bash .pipeline/bin/plan-schema.sh:*),Bash(bash bin/plan-schema.sh:*)` IMMEDIATELY BEFORE the closing `'` of the `base=` string (preserves the dual-path convention documented at lines 622-633).

### Task 5: Add planning-stage branch to `bin/run-stage.sh::_clear_current_stage_slots`

- `depends_on: [1]`
- `touches: bin/run-stage.sh::_clear_current_stage_slots`
- [ ] In `bin/run-stage.sh::_clear_current_stage_slots`, AFTER the `qa` stage-gated branch's closing `fi` (content anchor: the `fi` that closes the `if [[ "$stage" == "qa" ]]; then` block containing `rm -f "$d/qa-predicate-${ident}.body.json"` — the LAST `fi` before `return 0`), add a new stage-gated block: `# ENG-204: clear plan body sidecar on planning-stage dispatch start.` then `if [[ "$stage" == "planning" ]]; then` / `rm -f "$d/plan.body.json" 2>/dev/null || true` / `fi`. Match the comment and indentation of the existing ENG-119 reviewing and ENG-117/203 qa branches.

### Task 6: Rewrite `AGENT_PROMPTS.md` §2 (plan) for body-only emission

- `depends_on: [2, 3, 5]`
- `touches: AGENT_PROMPTS.md §2 (lines ~436-465)`
- [ ] In `AGENT_PROMPTS.md` (content anchor: the line beginning `- Additionally produce a sibling structured contract at docs/plans/{date}-{issue_id_lower}-{slug}.json` — the bullet that introduces the `plan-schema-v1` fenced block), rewrite the bullet to instruct: "Additionally produce a content-only body sidecar at `{plan_body_path}` containing the JSON shape below (features[] only — `plan_schema_version` and `issue_id` are MERGED ONTO THE BODY BY THE ORCHESTRATOR; do not emit those keys yourself). After writing the body, run `bash bin/plan-schema.sh prepare --body {plan_body_path} --md docs/plans/{date}-{issue_id_lower}-{slug}.md --ident {issue_id}` to materialize the canonical `docs/plans/{date}-{issue_id_lower}-{slug}.json` in your worktree. The `prepare` command exits with rc=33/34/35 (plan-contract-malformed / -incomplete / -missing) if the body is malformed; on success its stdout prints `plan-contract-prepared: <path>`."
- [ ] INSIDE the `plan-schema-v1` fenced block (content anchor: the literal opening line `  ```plan-schema-v1` — the four-space-indented fence), remove the line `    "plan_schema_version": 1,` and the line `    "issue_id": "{issue_id}",`. The block now opens with `{` directly followed by `  "features": [`. Do NOT remove the fence info-string `plan-schema-v1` (the literal anchor is preserved for the prompt-content test).
- [ ] In the "Required: …" paragraph (content anchor: the line beginning `  Required: \`plan_schema_version\` (integer 1), \`issue_id\` (matches`), rewrite to: "Required body keys: `features[]` (len≥1). Per-feature: `id`, `summary`, `pass_criteria[]` (len≥1). Per-criterion: `kind` in `{smoke, file_exists, grep}` plus kind-specific fields. The orchestrator-merged canonical adds `plan_schema_version: 1` and `issue_id: \"{issue_id}\"`. Unknown fields: permitted (warning only). Missing or malformed body halts the dispatch via `prepare`'s rc; the post-dispatch `bin/run-stage.sh::_validate_plan_contract` continues to gate the merged canonical against the full schema."
- [ ] BEFORE the line `- Also produce \`{init_sh_path}\` — a per-issue smoke-discipline script.` (content anchor: that exact line, which is the next top-level bullet after the prepare paragraph), insert a NEW bullet: "- If `bash bin/plan-schema.sh prepare …` exits non-zero, do NOT `git add` / `git commit` — instead run `bash bin/pipeline.sh event {issue_id} verdict halt --reason agent-blocked` and post a one-line follow-up comment naming `prepare`'s stderr, then exit." (Pinned by PC-7 in Task 9.)

### Task 7: Add adversarial cases to `bin/plan-schema-adversarial-test.sh`

- `depends_on: [2]`
- `touches: bin/plan-schema-adversarial-test.sh`
- [ ] PA-1: body contains a key named `plan_schema_version` with value `"v1"` (string, wrong type). `cmd_prepare --body --md --ident` returns rc=0; merged canonical's `plan_schema_version` is integer `1` (envelope wins per A19); `cmd_validate` on the canonical returns rc=0.
- [ ] PA-2: body contains a content key named `linear_issue_id` (typo). `cmd_prepare` returns rc=0; `cmd_validate` on the merged canonical emits an "unknown top-level field" warning to stderr but returns rc=0 (permissive — `bin/plan-schema.sh:219-227` contract).
- [ ] PA-3: end-to-end chain — `Write` a body fixture, run `cmd_prepare`, run `cmd_validate` on the produced canonical, assert all three steps return rc=0 and the canonical file lives at `${md_real%.md}.json`.
- [ ] Each case: `mktemp -d` + `trap "rm -rf $tmp" EXIT`; sandbox `$PROJECT_STATE_DIR=$tmp/project_state`; `cd "$tmp/worktree"` before invoking `cmd_prepare` so the `--md` cwd-fence resolves.

### Task 8: Add unit + orchestration test cases

- `depends_on: [2, 3, 4, 5]`
- `touches: bin/plan-schema-test.sh, bin/run-stage-test.sh, bin/render-prompt-test.sh`

`bin/plan-schema-test.sh`:

- [ ] Reframe `T_schema_doc_sync` (content anchor: the line `      canonical_keys="features,issue_id,plan_schema_version"`). Replace with two assertions: (a) `prompt_keys == "features"` (body keyset only); (b) compute `validator_keys="features,issue_id,plan_schema_version"` separately and assert `validator_keys == prompt_keys ∪ {plan_schema_version, issue_id}` (i.e. confirm exactly those two envelope keys are added by the helper). Update the assertion-failure message strings accordingly.
- [ ] P-1 envelope keyset closure — assert `cmd_prepare`'s constructed env_json has exactly `{plan_schema_version, issue_id}` (read the merged canonical and assert `keys - ["features"] | sort == ["issue_id", "plan_schema_version"]`).
- [ ] P-2 body+envelope merge happy path — body = `{"features":[{"id":"F-1","summary":"x","pass_criteria":[{"kind":"file_exists","path":"x"}]}]}`; `cmd_prepare --body … --md … --ident ENG-1` returns rc=0; canonical has all three top-level keys; `cmd_validate` on canonical returns rc=0.
- [ ] P-3 body collision: body has `issue_id: "ENG-99"`, `--ident ENG-1`; canonical has `issue_id: "ENG-1"` (envelope wins).
- [ ] P-4 body file missing → rc=35.
- [ ] P-5 body top-level array → rc=33.
- [ ] P-6 body JSON parse error → rc=33.
- [ ] P-7 body is symlink → rc=33.
- [ ] P-8 body > 64 KiB → rc=33 (helper rc=39 remapped).
- [ ] P-9 `--ident` missing → rc=34.
- [ ] P-10 `--ident` malformed (`eng-1`, `ENG-`, `ENGG-1`) → rc=34.
- [ ] P-11 `--md` missing → rc=34.
- [ ] P-12 `--md` does not end in `.md` → rc=33.
- [ ] P-13 `--md` is symlink → rc=33.
- [ ] P-14 `--md` resolves outside cwd (absolute `/tmp/x.md`) → rc=33.
- [ ] P-15 `--body` resolves outside `$PROJECT_STATE_DIR` → rc=33.
- [ ] P-16 canonical destination not writable (chmod 0500 parent) → rc=33 (helper rc=50 remapped).
- [ ] Each P-N: `mktemp -d` + `trap`; sandbox `$PROJECT_STATE_DIR`; `cd` to a tmp worktree before `cmd_prepare`.

`bin/run-stage-test.sh`:

- [ ] OS-1: seed `$(issue_dir ENG-1)/plan.body.json`; call `_clear_current_stage_slots ENG-1 planning`; assert file absent.
- [ ] OS-2: seed `verdict-qa.json`, `verdict-qa.body.json`, `qa-predicate-ENG-1.json`, `qa-predicate-ENG-1.body.json`, `verdict-review.json`; call `_clear_current_stage_slots ENG-1 planning`; assert all five files SURVIVE (planning-stage clear must not bleed into qa/review state).
- [ ] OS-3: seed `plan.body.json`; call `_clear_current_stage_slots ENG-1 implementing`, then ENG-1 qa, then ENG-1 reviewing, then ENG-1 brainstorming; assert the body survives all four calls.
- [ ] OS-4 (end-to-end orchestration): fixture a worktree with a body-only `plan.body.json` written + the corresponding `.md` committed + the merged canonical (post-`prepare`) committed; call `_validate_plan_contract ENG-1`; assert rc=0. This is the **AC#2 / AC#3** regression-pinning case.

`bin/render-prompt-test.sh`:

- [ ] R-1: bind `_RENDER_PLAN_BODY_PATH=/tmp/expected`; call `_resolve_plan_body_path`; assert stdout equals `/tmp/expected`.
- [ ] R-2: bind `_RENDER_PLAN_BODY_PATH=/tmp/expected` (and the other path-resolvers as needed for the existing sidecar contract); call `_write_rendered_paths_sidecar /tmp/sidecar`; assert the file contains a line `plan_body_path\t/tmp/expected`.

### Task 9: Add prompt-content cases to `bin/agent-prompts-content-test.sh`

- `depends_on: [6]`
- `touches: bin/agent-prompts-content-test.sh`
- [ ] PC-1: the `plan-schema-v1` fenced block (extracted from `s2` via the same awk pattern used in `bin/plan-schema-test.sh::T_schema_doc_sync`) does NOT contain the literal string `plan_schema_version`.
- [ ] PC-2: same block does NOT contain `issue_id`.
- [ ] PC-3: same block contains the literal `features`.
- [ ] PC-4: `s2` contains the literal `{plan_body_path}` token.
- [ ] PC-5: `s2` contains the literal prepare invocation shape `bash bin/plan-schema.sh prepare --body {plan_body_path} --md docs/plans/{date}-{issue_id_lower}-{slug}.md --ident {issue_id}` (OR its `.pipeline/bin/plan-schema.sh` sibling — `grep -qF` either form).
- [ ] PC-6: `s2` retains the literal substring `features[]` in the "Required body keys" paragraph.
- [ ] PC-7: `s2` contains the literal sentence beginning "If `bash bin/plan-schema.sh prepare`" (OR its `.pipeline/` sibling — `grep -qF` either form). Pins the rc-handling discipline added by Task 6.

### Task 10: Add recovery.md §16 entry

- `depends_on: [2, 5, 6]`
- `touches: docs/runbooks/recovery.md`
- [ ] After the last existing recovery section (content anchor: the last `## §<N>` heading in the file — append a NEW `## §16 plan-contract merge failure (ENG-204)`). Describe the four halt paths: (a) body missing → `prepare` rc=35 / validator `plan-contract-missing` rc=35; (b) body malformed (parse error / not object / oversize / symlink / realpath escape) → `prepare` rc=33 / validator `plan-contract-malformed`; (c) `--ident` malformed → `prepare` rc=34; (d) write failure (disk full / chmod) → `prepare` rc=33. Recovery: `bash bin/pipeline.sh decide <ENG-N> --action continue`. Include a grep recipe pointing at `$PROJECT_STATE_DIR/<slug>/logs/<ident>-planning-*.log` for the `prepare` stderr line ("plan-schema.sh: …") because the `_post_plan_contract_halt` Linear comment body only carries the orchestrator's post-dispatch validator stderr (NOT the in-dispatch `prepare`'s stderr — those land in the per-stage transcript only).

## Frontend Tasks

No frontend. (The harness has no UI; the UI agent is not dispatched on harness tickets.)

## Failure Mode → Test Map

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
|---|---|---|---|---|
| Body file does not exist | Agent forgot to `Write` the body before invoking `prepare`. | `cmd_prepare` rc=35 (helper 41 remapped). Validator's `plan-contract-missing` path also halts post-dispatch if agent committed `.md` alone. | unit | `bin/plan-schema-test.sh::P-4` |
| Body is JSON-parse-error | Agent emitted malformed JSON. | `cmd_prepare` rc=33 (helper 39 remapped). | unit | `bin/plan-schema-test.sh::P-6` |
| Body is top-level array, not object | Agent confused `{features: [...]}` with `[...]`. | `cmd_prepare` rc=33. | unit | `bin/plan-schema-test.sh::P-5` |
| Body > 64 KiB | Agent dumped a huge features array. | `cmd_prepare` rc=33 (helper 39 remapped). | unit | `bin/plan-schema-test.sh::P-8` |
| Body 0 bytes | Agent `Write`'d an empty file. | `cmd_prepare` rc=33 (size cap `sz <= 0`). | unit | covered by P-8's size-cap path (parametrise) |
| Body is symlink | Pathological / adversarial. | `cmd_prepare` rc=33 (symlink fence before helper). | unit | `bin/plan-schema-test.sh::P-7` |
| Body resolves outside `$PROJECT_STATE_DIR` | Agent passed an absolute path under `/tmp` or worktree. | `cmd_prepare` rc=33. | unit | `bin/plan-schema-test.sh::P-15` |
| `--md` missing flag | Agent forgot the flag. | `cmd_prepare` rc=34. | unit | `bin/plan-schema-test.sh::P-11` |
| `--md` not `.md` extension | Agent passed `docs/plans/foo.markdown`. | `cmd_prepare` rc=33. | unit | `bin/plan-schema-test.sh::P-12` |
| `--md` symlink | Pathological. | `cmd_prepare` rc=33. | unit | `bin/plan-schema-test.sh::P-13` |
| `--md` outside cwd | Agent passed `/etc/passwd.md`. | `cmd_prepare` rc=33. | unit | `bin/plan-schema-test.sh::P-14` |
| `--ident` missing | Agent forgot the flag. | `cmd_prepare` rc=34. | unit | `bin/plan-schema-test.sh::P-9` |
| `--ident` malformed (`eng-1`, `ENG-`) | Agent typo. | `cmd_prepare` rc=34. | unit | `bin/plan-schema-test.sh::P-10` |
| Body emits wrong-type envelope key | Body has `plan_schema_version: "v1"`. | Envelope's `1` wins (right-biased merge); canonical passes validator; `envelope-overwrite` metric emits. | adversarial | `bin/plan-schema-adversarial-test.sh::PA-1` |
| Body has unknown content key | Agent emits `features[].extra_note`. | `cmd_prepare` rc=0; `cmd_validate` warns + rc=0. | adversarial | `bin/plan-schema-adversarial-test.sh::PA-2` |
| End-to-end: body→prepare→validate→commit→`_validate_plan_contract` | The full clean-path flow. | All steps rc=0; validator accepts the HEAD-committed merged canonical. | integration | `bin/run-stage-test.sh::OS-4` |
| Body sidecar survives across stage dispatches incorrectly | Hypothetical bug where `_clear_current_stage_slots` over-clears. | Planning-stage clear removes the body; other-stage clears preserve it. | integration | `bin/run-stage-test.sh::OS-1, OS-3` |
| qa/review state collateral-cleared by planning clear | Hypothetical bug in the new branch. | Files SURVIVE. | integration | `bin/run-stage-test.sh::OS-2` |
| Render-prompt resolver returns wrong value | Bug in `_resolve_plan_body_path`. | Returns `$(issue_dir ident)/plan.body.json`. | unit | `bin/render-prompt-test.sh::R-1` |
| Sidecar missing the new row | Bug in `_write_rendered_paths_sidecar`. | Row `plan_body_path\t<value>` present. | unit | `bin/render-prompt-test.sh::R-2` |
| Prompt block still names envelope keys | Bug in §2 edit. | PC-1/PC-2 fail. | unit | `bin/agent-prompts-content-test.sh::PC-1, PC-2` |
| Prompt block missing the prepare invocation | Bug in §2 edit. | PC-5 fails. | unit | `bin/agent-prompts-content-test.sh::PC-5` |
| Prompt block missing the rc-handling sentence | Bug in §2 edit. | PC-7 fails. | unit | `bin/agent-prompts-content-test.sh::PC-7` |
| `T_schema_doc_sync` still asserts old canonical keyset | Bug in Task 6's reframe. | Test fails on the post-ENG-204 prompt block (body-only). | unit | `bin/plan-schema-test.sh::T_schema_doc_sync` (reframed) |
| Pre-commit gate fails (any test red) | Composition bug. | All `bin/*-test.sh` blocked; the `.githooks/pre-commit` glob catches every test. | smoke | `bash .githooks/pre-commit` |

## Test Strategy

**Unit (`bin/plan-schema-test.sh`).** Sixteen new `cmd_prepare` cases (P-1..P-16) pin every argv-validator, fence, and rc-remap branch. The `T_schema_doc_sync` reframe (split into prompt-block-vs-body and validator-vs-envelope-union assertions) keeps the prompt-vs-validator drift gate honest for future schema-v2 evolution and any envelope-key migration. The body fixture discipline (`mktemp -d` + `trap` cleanup + sandboxed `$PROJECT_STATE_DIR`) mirrors the existing `bin/verify-qa-test.sh` PROJECT_STATE_DIR-isolation pattern (security persona Iter-1 P1-3 from the brainstorm).

**Adversarial (`bin/plan-schema-adversarial-test.sh`).** PA-1 pins the right-bias silent-repair contract (envelope overrides body on collision). PA-2 pins the permissive-on-unknown contract. PA-3 exercises the full prepare→validate chain end-to-end on a freshly-built fixture worktree.

**Integration (`bin/run-stage-test.sh`).** OS-1..OS-3 pin the `_clear_current_stage_slots` planning branch (clear on planning; preserve on every other stage; do not collateral-touch qa/review state). OS-4 is the AC#2/AC#3 regression-pinning end-to-end: HEAD-committed `.md` + merged canonical `.json` → `_validate_plan_contract` rc=0.

**Prompt-content (`bin/agent-prompts-content-test.sh`).** PC-1..PC-7 close the AGENT_PROMPTS.md drift gate — they catch a future edit that re-introduces envelope keys to the fenced block, renames `{plan_body_path}`, alters the prepare invocation shape, or drops the rc-handling sentence. The fenced-block extraction reuses the same awk pattern as `T_schema_doc_sync` so the section locator is stable across both test files.

**Render-prompt (`bin/render-prompt-test.sh`).** R-1 pins the resolver function; R-2 pins the closed-allowlist contract surface (ENG-156 D-004) so a sandbox-denial against the new body path produces a row in the `.rendered-paths-<stage>` sidecar and the post-dispatch Phase B detective has a contract surface to match.

**Smoke.** `bash .githooks/pre-commit` (the implementing/qa allowlist's pre-commit-hook grant) globs every `bin/*-test.sh` on disk and blocks on any failure outside the hook's `KNOWN_BROKEN` allowlist. The plan-schema tests are NOT in KNOWN_BROKEN today, so a regression in any added case fails the implement-stage's first pre-commit. Manual spot-check: `bash bin/plan-schema-test.sh`, `bash bin/plan-schema-adversarial-test.sh`, `bash bin/agent-prompts-content-test.sh`, `bash bin/run-stage-test.sh`, `bash bin/render-prompt-test.sh` each as a standalone invocation during iteration.

**Test-gate closure (test-gate add-side).** No new gate-runnable test file is created — all new cases slot into existing `bin/plan-schema-test.sh`, `bin/plan-schema-adversarial-test.sh`, `bin/agent-prompts-content-test.sh`, `bin/run-stage-test.sh`, `bin/render-prompt-test.sh`. The pre-commit hook's `bin/*-test.sh` glob and the harness profile's "Test command" both pick them up automatically (A25). No `learned-rules/harness/project-profile.md` edit needed.

**Test-gate closure (remove-side).** This plan removes the literal `plan_schema_version` and `issue_id` lines from `AGENT_PROMPTS.md` §2's `plan-schema-v1` fenced block. The substring `plan_schema_version` and `issue_id` is referenced by `bin/plan-schema-test.sh:253`'s `canonical_keys="features,issue_id,plan_schema_version"`; that file IS in File Structure with the `T_schema_doc_sync` reframe in Task T8 (A26). No other sibling test asserts against the boilerplate strings being PRESENT in the fenced block.
