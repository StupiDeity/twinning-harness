---
linear: ENG-203
date: 2026-06-16
topic: Orchestrator-merge helper + content-only qa-payload + qa-predicate body sidecars (ENG-202 foundation child)
---

# Plan — Orchestrator-merge helper + content-only qa artifacts (ENG-203)

## Anti-anchoring check

- **Problem (operator-perspective):** "ENG-118 halted at `stage:qa` with
  `qa-payload-incomplete: missing required field qa_payload_schema_version`. The
  agent wrote a content-complete, clean-pass grading payload, then slipped on one
  envelope key. The operator had to repair the JSON by hand and force-transition
  the issue. Live memory `qa-agent-schema-version-field-slip` confirms this is a
  *class*, not an isolated case — the qa agent reliably mis-types invariant
  boilerplate." The fix removes the slip surface entirely: the agent never types
  envelope keys; the orchestrator merges them from already-trusted inputs.
- **Brainstorm framing:** matches one-for-one. Sidecar-merge mechanism (D-001),
  shared `merge_artifact_envelope` helper in `bin/common.sh` (D-002), §6 prompt
  edits replacing two write paths and adding a `--body` flag to `verify-qa.sh`
  (D-003 / D-004), `_clear_current_stage_slots` extension (D-005), post-dispatch
  sequencing before `_validate_qa_payload` (D-006). No reframing.
- **Proportionality:** three helper functions in `bin/common.sh` (~70 lines),
  one new orchestrator helper + sequencing wire-up + clear-extension in
  `bin/run-stage.sh` (~50 lines), `--body` flag + realpath fence + caller-side
  rc remap in `bin/verify-qa.sh` (~40 lines), two new resolvers + two `_RENDER_*`
  binds in `bin/render-prompt.sh` (~20 lines), two §6 step edits in
  `AGENT_PROMPTS.md` (~15 lines), unit + orchestration + prompt-content + verify-qa
  tests (~380 lines), one `metric_names` entry + sibling vocabulary-cleanliness
  pin, one §15 recovery runbook entry, one CLAUDE.md failure-mode row. Two load-
  bearing subsystems (dispatch/orchestrator primary, agent-prompts subordinate).
  Proportional. Proceed.

## Goal

Stop the qa agent from ever typing `qa_payload_schema_version`, `issue_id`, or
`dispatch_id`: the agent writes a content-only body (`verdict-qa.body.json`
and `qa-predicate-<ident>.body.json`), the orchestrator's
`merge_artifact_envelope` helper splices in a closed-keyset envelope built
from `$PIPELINE_DISPATCH_ID` + `$ident`, the existing `qa-payload-schema.sh`
and `verify-qa.sh` schema validators run on the merged canonical, and the
ENG-118 failure case (clean-pass dimensions body, zero boilerplate) no
longer halts.

## Assumption Inventory

**branch-base freshness:** `git log --oneline HEAD..origin/main` is NON-EMPTY
at plan time. Output:

    a74b7bc Merge pull request #171 from StupiDeity/fix/render-prompt-bash32-utf8-hang
    532f4a4 fix(render-prompt): byte-locale resolve_block_tokens to kill bash-3.2 UTF-8 hang

`origin/main` at plan time = `a74b7bc`. The upstream change touches
`bin/render-prompt.sh` and `bin/render-prompt-rc0-test.sh` — files that this
plan ALSO modifies (`bin/render-prompt.sh` gets two new `PROMPT_RESOLVERS`
entries and two `_RENDER_*` binds at line ~621). Drift is mechanical (locale
scoping inside `resolve_block_tokens` — line ~470 region per the merge
commit's `+16 lines` count) and does NOT collide with our edit boundaries
(line 40-63 `PROMPT_RESOLVERS` and line ~621 `_RENDER_QA_PREDICATE_PATH`
bind). Still: **Task 0 below mandates a `git fetch origin main && git
rebase origin/main` BEFORE any other implement work**, and all subsequent
`path:line` excerpts MUST be re-verified by content anchor after the rebase
lands. Every `### Task N` step uses CONTENT anchors (function names,
distinctive literals, comment markers) so the rebase is harmless to the
boundaries themselves; line numbers below are informational hints only.

### Verified — code paths quoted from current tree

- `[verified]` `bin/common.sh:68-93` — `issue_dir`, `progress_md_path`,
  `qa_predicate_path` are sibling per-artifact helpers. All resolve relative
  to `$PROJECT_STATE_DIR` via `issue_dir`. New helpers `qa_payload_body_path
  <ident>` and `qa_predicate_body_path <ident>` slot in the same block.
  Content anchor: the literal `qa_predicate_path() {`.
- `[verified]` `bin/common.sh:111-181` — `_validate_pass_criterion` is the
  shared cross-script library helper (sample of "common.sh as cross-script
  library" placement). Confirms D-002's "helper goes in common.sh, not a new
  script." Content anchor: `_validate_pass_criterion() {`.
- `[verified]` `bin/common.sh:699-747` — `failure_outcome_for_exit` taxonomy.
  Codes 39 → `qa-payload-malformed`, 41 → `qa-payload-missing`, 42 →
  `qa-predicate-malformed`, 50 → `review-ledger-missing`. **ENG-203 introduces
  NO new exit codes.** The merge helper's rc=39/41/42/50 map through this
  table unchanged (with the cosmetic mis-map on 42/50 documented in
  brainstorm D-006). Content anchor: `failure_outcome_for_exit() {`.
- `[verified]` `bin/common.sh:901` — the `export -f` list. Today exports
  `issue_dir compute_pipeline_content_hash failure_outcome_for_exit
  parse_pipeline_marker is_orchestrator_paused set_orchestrator_paused
  allocate_dispatch_id current_dispatch_id strip_state_preserve_alloc
  assert_no_tool_invocation progress_md_path assert_no_write_to_path
  assert_no_tool_with_input_path validate_init_sh qa_predicate_path
  _validate_pass_criterion _url_host_class_denied`. **Three new names
  appended:** `merge_artifact_envelope`, `qa_payload_body_path`,
  `qa_predicate_body_path`. Content anchor: the literal `export -f issue_dir`
  prefix.
- `[verified]` `bin/qa-payload-schema.sh:108-122` — schema validator enforces
  `qa_payload_schema_version == 1` and returns rc=40 on absence/wrong-type.
  Unchanged by ENG-203. Content anchor: the literal `qa_payload_schema_version`
  inside `_validate_payload_schema`.
- `[verified]` `bin/qa-payload-schema.sh:124-153` — `issue_id` regex
  `^ENG-[0-9]+$` and `dispatch_id` regex `^ENG-[0-9]+-d[0-9]+$` enforced;
  rc=40 on miss. Unchanged. Content anchor: `dispatch_id must be a non-empty
  string`.
- `[verified]` `bin/qa-payload-schema.sh:244-251` — unknown top-level fields
  → `_warn_unknown` (stderr, no halt). The merge-injected
  `qa_payload_schema_version`/`issue_id`/`dispatch_id` will sit alongside the
  agent's `verdict` + `dimensions[]`; no other keys land on the canonical
  by construction, so the unknown-field warning is never tripped by ENG-203
  outputs. Content anchor: the literal `"qa_payload_schema_version","issue_id","dispatch_id","verdict","dimensions"`.
- `[verified]` `bin/run-stage.sh:949-974` — `_clear_current_stage_slots`
  is the per-medium "clear-on-dispatch-start" primitive. Today clears
  `stage-summary-<stage>.md`, `wait-<stage>.json`, `.rendered-paths-<stage>`,
  and (qa-stage-gated) `verdict-qa.json`. NOT today: the qa-predicate
  canonical. ENG-203 grows the qa-stage branch by THREE `rm -f` lines
  (`verdict-qa.body.json`, `qa-predicate-<ident>.body.json`,
  `qa-predicate-<ident>.json` — the third is new behavior per D-005).
  Content anchor: the literal `if [[ "$stage" == "qa" ]]; then`.
- `[verified]` `bin/run-stage.sh:2073-2092` — `_validate_qa_payload` is
  the post-dispatch schema validator caller. Today: `local payload;
  payload="$(issue_dir "$ident")/verdict-qa.json"; if [[ ! -f "$payload" ]];
  then _post_qa_payload_halt … return 41; fi; out="$(bash
  $SCRIPT_DIR/qa-payload-schema.sh validate "$payload" --ident "$ident"
  --dispatch-id "${PIPELINE_DISPATCH_ID-}" 2>&1)"`. UNCHANGED by ENG-203
  — it runs against the MERGED canonical. The new
  `_merge_qa_payload_envelope` helper is wired in BEFORE this function.
  Content anchor: `_validate_qa_payload() {`.
- `[verified]` `bin/run-stage.sh:2097-2105` — `_post_qa_payload_halt`
  takes `<ident> <defect> <raw>`, sanitises `<!--` → `<\!--` on `$raw`,
  posts via `bash $SCRIPT_DIR/linear.sh add-comment "$ident" "$body" ||
  true`. ENG-203 reuses this helper for merge-failure halts (D-006 caller
  pattern). Content anchor: `_post_qa_payload_halt() {`.
- `[verified]` `bin/run-stage.sh:2981-2997` — post-dispatch qa-payload
  validator hook block. Shape: `if (( ! skip_dispatch )); then case "$stage"
  in qa) local _qa_payload_rc=0; _validate_qa_payload "$ident" ||
  _qa_payload_rc=$?; if (( _qa_payload_rc != 0 )); then classify_failure
  "$ident" "$stage" "skip-until-human-acts" "qa-payload-invalid:
  $(failure_outcome_for_exit "$_qa_payload_rc")" "$_qa_payload_rc"; exit
  "$_qa_payload_rc"; fi ;; esac fi`. ENG-203 inserts a NEW block
  IMMEDIATELY ABOVE this one with the same case-shape, calling
  `_merge_qa_payload_envelope "$ident"` and the same exit-on-rc-≠-0
  classify_failure path. Content anchor: the literal `# ENG-117: qa-payload
  validator. Post-dispatch; qa stage only.`.
- `[verified]` `bin/run-stage.sh:3003-3009` — qa-threshold gate
  (`_validate_qa_thresholds`) runs AFTER `_validate_qa_payload` on the merged
  canonical. Unchanged by ENG-203 — reads `.verdict` and `.dimensions[]`
  which are the body's content (envelope merge preserves them verbatim,
  brainstorm A28). Content anchor: the literal `_validate_qa_thresholds
  "$ident" || true`.
- `[verified]` `bin/verify-qa.sh:82-118` — `_parse_validate_argv` accepts
  `--ident <val>` and `--worktree <val>` plus the positional `<file>`.
  Rejects unknown `--*` flags with rc=42. ENG-203 adds a `--body <val>`
  arm BEFORE the `--*` rejection branch. Content anchor: the literal
  `_parse_validate_argv() {`.
- `[verified]` `bin/verify-qa.sh:130-163` — `_authority_check` realpath
  fence for `$ARG_FILE` against `$PROJECT_STATE_DIR`. The mirror fence for
  `$ARG_BODY` slots inside `cmd_validate` immediately after parse-argv (D-004
  "Mandatory --body realpath fence"). Content anchor: `_authority_check() {`.
- `[verified]` `bin/verify-qa.sh:42-51` — schema header documents
  `{qa_predicate_schema_version, issue_id, pass_criteria[]}` — no
  `dispatch_id` field. Confirms the qa-predicate envelope is two-keyed.
  Content anchor: `"qa_predicate_schema_version": 1,`.
- `[verified]` `bin/verify-qa.sh:600-679` — `cmd_validate` orchestrator.
  Today's phase sequence: parse argv → `_check_canonical_path_available`
  → `_authority_check` → `_worktree_fence` → snapshot → schema validate →
  execute. ENG-203 inserts a NEW phase between parse argv and authority
  check: when `$ARG_BODY` is non-empty, (a) fence `$ARG_BODY` realpath
  against `$PROJECT_STATE_DIR`, (b) construct envelope JSON `{
  qa_predicate_schema_version: 1, issue_id: $ARG_IDENT }`, (c) call
  `merge_artifact_envelope $ARG_BODY $env_json
  $(qa_predicate_path $ARG_IDENT)`, (d) remap rc=39 → 42, rc=41 → 44,
  rc=42 → 42, rc=50 → 42 (D-004 caller-side rc remap), (e) overwrite
  `ARG_FILE` to point at the canonical so phases 2-5 run unchanged.
  Content anchor: `cmd_validate() {`.
- `[verified]` `bin/render-prompt.sh:40-63` — `PROMPT_RESOLVERS` registry
  with 22 tokens. ENG-203 appends TWO new entries:
  `qa_payload_body_path=_resolve_qa_payload_body_path` and
  `qa_predicate_body_path=_resolve_qa_predicate_body_path`. Content anchor:
  the literal `qa_predicate_path=_resolve_qa_predicate_path` (insertion
  AFTER it preserves alphabetical-ish grouping).
- `[verified]` `bin/render-prompt.sh:283` — `_resolve_qa_predicate_path() {
  printf '%s' "$_RENDER_QA_PREDICATE_PATH"; }` is the exact shape the two
  new resolvers mirror. Content anchor: `_resolve_qa_predicate_path() {`.
- `[verified]` `bin/render-prompt.sh:621` — `_RENDER_QA_PREDICATE_PATH="$(qa_predicate_path
  "$issue_id")"` bind site inside `main()`. ENG-203 appends two sibling
  binds: `_RENDER_QA_PAYLOAD_BODY_PATH="$(qa_payload_body_path "$issue_id")"`
  and `_RENDER_QA_PREDICATE_BODY_PATH="$(qa_predicate_body_path
  "$issue_id")"`. Content anchor: `_RENDER_QA_PREDICATE_PATH="$(qa_predicate_path`.
- `[verified]` `bin/render-prompt.sh:103-117` —
  `_write_rendered_paths_sidecar` is the closed allowlist for path-shaped
  tokens that go into `.rendered-paths-<stage>`. The new body-path resolvers
  ARE path-shaped, so they MUST be enumerated here too (or the
  sandbox-denial detective at ENG-156 will not be able to match denied
  body-path writes against the contract surface). Two new lines:
  `[[ -n "${_RENDER_QA_PAYLOAD_BODY_PATH:-}" ]] && printf 'qa_payload_body_path\t%s\n'   "$_RENDER_QA_PAYLOAD_BODY_PATH"`
  and the predicate sibling. Content anchor: `_write_rendered_paths_sidecar() {`.
- `[verified]` `AGENT_PROMPTS.md:1932-1954` — §6 step 1 (qa-predicate write
  + validate). Today: agent writes JSON shape `{ qa_predicate_schema_version:
  1, issue_id: "{issue_id}", pass_criteria: [...] }` at `{qa_predicate_path}`,
  then runs `bash bin/verify-qa.sh validate {qa_predicate_path} --ident
  {issue_id}`. ENG-203 narrows the shape to `{ pass_criteria: [...] }` at
  `{qa_predicate_body_path}`, and the validator invocation becomes `bash
  bin/verify-qa.sh validate --body {qa_predicate_body_path} --ident
  {issue_id}`. Content anchor: the literal `Emit verification predicate`
  bold header.
- `[verified]` `AGENT_PROMPTS.md:2038-2073` — §6 step 9 (verdict-qa.json
  write). Today: agent writes `qa_payload_schema_version`, `issue_id`,
  `dispatch_id`, `verdict`, `dimensions[]` at
  `$(issue_dir {issue_id})/verdict-qa.json`. ENG-203 drops the first three
  from the required-fields enumeration and changes the write path to
  `{qa_payload_body_path}`. Content anchor: the literal `Emit dimensional
  grading payload`.
- `[verified]` `bin/pipeline-events.json:67-78` — `metric_names` array has
  10 entries today (last: `dimensional_threshold_coerced`). ENG-203 appends
  one: `envelope-overwrite` (brainstorm OQ-4 promotion). Content anchor:
  the literal `"dimensional_threshold_coerced"`.
- `[verified]` `bin/pipeline-events.json:16,28` — `halt_reasons` array
  contains `qa-payload-invalid`. ENG-203 uses this existing token for
  merge-failure halts; no new vocabulary required. Content anchor: the
  literal `"qa-payload-invalid"`.
- `[verified]` `bin/vocabulary-cleanliness-test.sh:198-208` — ENG-118 case-7
  block pins `dimensional_threshold_coerced` in `metric_names`. ENG-203
  appends a case-8 block (sibling shape) pinning `envelope-overwrite` in
  `metric_names`. Content anchor: the literal `case-7:
  dimensional_threshold_coerced in metric_names registry`.
- `[verified]` `bin/metrics.sh:19-44` — `main()` signature is positional:
  `metrics.sh <event> <issue_id> <stage> <outcome> <duration_ms> [notes…]`.
  ENG-203's helper-side emission shape: `bash "$SCRIPT_DIR/metrics.sh"
  "envelope-overwrite" "$ident" "$stage" "merged" "0"
  "count=$N keys=$csv body=$body"`. The brainstorm OQ-4 example
  (`event envelope-overwrite "$ident" "$stage" count=N keys=<csv>`) is
  inexact — the actual call uses positional args (event=envelope-overwrite,
  outcome=merged, duration_ms=0) with the count/keys carried in the
  free-form notes. Content anchor: `metrics.sh <event> <issue_id> <stage>
  <outcome>`.
- `[verified]` `bin/agent-prompts-content-test.sh:455-485` — ENG-113 §6
  prompt-content pins (`Emit verification predicate` + `{qa_predicate_path}`
  literal + multi-site count ≥ 2). ENG-203 adds sibling pins:
  - `{qa_predicate_body_path}` literal present in §6;
  - `qa_predicate_schema_version` NOT in §6 step 1's content-shape doc;
  - `{qa_payload_body_path}` literal present in §6;
  - `qa_payload_schema_version` NOT in §6 step 9's content-shape doc;
  - `dispatch_id` NOT in §6 step 9's content-shape doc;
  - exact-literal `bash bin/verify-qa.sh validate --body {qa_predicate_body_path}
    --ident {issue_id}` present in §6 (AP-7 / D-003 P1#2).
  The `s6="$(section_body "## 6. QA Agent")"` extraction in the file is the
  hook (already present at line 1861 and 76). Content anchor: the literal
  `# ─── ENG-113: §6 contains the new "Emit verification predicate" step ───`.
- `[verified]` `docs/runbooks/recovery.md` — sections 1-14 exist; §14 is
  `Dimensional threshold coercion (ENG-118)`. ENG-203 appends a §15
  entry `qa-payload merge failure (ENG-203)` covering the four halt
  shapes the merge helper can produce (body-missing rc=41, body-malformed
  rc=39, canonical-write-fail rc=50, envelope-not-object rc=42 — the
  last cosmetically mis-mapped to `qa-payload-malformed`). Content anchor:
  the literal `## 14. Dimensional threshold coercion (ENG-118)`.
- `[verified]` `CLAUDE.md` "Failure-mode quick reference" table — multi-row
  markdown table. ENG-203 appends ONE row: "Halt at rc=41 with halt-reason
  `qa-payload-invalid` and a defect string starting with `qa-payload-missing`"
  → §15 recovery pointer. Content anchor: the row currently keyed on
  `dimensional-threshold/<stage>/<ident>`.
- `[verified]` `bin/common-test.sh` is the cross-script library test surface
  (sample at lines 928-963 for `progress_md_path`). Currently ends at line
  1316 region with the ENG-106 rc=31 arm, and final summary lines write
  `common-test summary: %d passed, %d failed`. ENG-203 appends a new block
  before the summary header. Content anchor: the literal `eng125_rc_taxonomy`
  invocation at end of file.
- `[verified]` `bin/run-stage-test.sh` is the orchestration test surface;
  contains thousands of lines with named blocks (ENG-118 TH1-15, ENG-193
  W1-12 at line 8909+). ENG-203 appends a new block at end. Content anchor:
  the literal `# ─── QA-ADV-6: decision_factors=null row` (the last existing
  block header in the file).
- `[verified]` `bin/verify-qa-test.sh` is the verify-qa.sh test surface
  (file exists). ENG-203 appends new `--body`-flag cases.
- `[verified]` `learned-rules/harness/project-profile.md:14-17` — `## Build
  & test gates` Test command is `bash .githooks/pre-commit` which globs
  `bin/*-test.sh` (ENG-196). ENG-203 introduces NO new `bin/*-test.sh`
  files — all assertions extend existing siblings (common-test.sh,
  run-stage-test.sh, agent-prompts-content-test.sh, verify-qa-test.sh,
  vocabulary-cleanliness-test.sh). Therefore `learned-rules/harness/project-profile.md`
  is NOT in File Structure. Content anchor: the literal `## Build & test
  gates`.
- `[verified]` `bin/dispatch.sh` qa-stage allowlist contains `Bash(bash
  bin/verify-qa.sh:*)`. The `*` glob matches the new `--body ...` argv.
  No dispatch-tools edit needed. Content anchor: the literal
  `Bash(bash bin/verify-qa.sh:*)`.
- `[verified]` `bin/run-stage.sh::main` allocates `PIPELINE_DISPATCH_ID`
  via `allocate_dispatch_id` BEFORE `_clear_current_stage_slots` and
  BEFORE the agent dispatch (line 2353 region per brainstorm A23). The
  post-dispatch merge call therefore always has the id in env. Content
  anchor: the literal `allocate_dispatch_id` call site.
- `[verified]` jq's `+` on objects is right-biased (right operand keys
  overwrite left). Helper's `jq -n --slurpfile b ... --argjson env ... '$b[0]
  + $env'` therefore lets the envelope win on collision. (jq stdlib semantic;
  brainstorm A22.)

### Assumed — to be verified during implement

- `[assumed]` `bin/run-stage-test.sh` source-and-stub pattern for the new
  orchestration cases (OS-1..OS-5). Mirror the ENG-193 W-block pattern at
  line 8909+: stub `linear.sh` and `verify-qa.sh` callbacks under
  `STUB_DIR`; source `run-stage.sh`; override `_post_qa_payload_halt` to
  capture the halt body into a temp file. Verifiable at implement time.
- `[assumed]` The `merge_artifact_envelope` helper's `mktemp
  "${canonical}.tmp.XXXXXX"` and `mv tmp canonical` is atomic on the same
  filesystem as the canonical (POSIX rename). Since body and canonical
  share `issue_dir`, the same filesystem is guaranteed in production. Test
  U-9 (canonical write target unwritable) exercises this.

## System invariants

- The qa agent never types `qa_payload_schema_version`, `issue_id`, or
  `dispatch_id` into any artifact it Writes. The orchestrator constructs
  the envelope from `$PIPELINE_DISPATCH_ID` + `$ident` and merges it onto
  the agent's body via `merge_artifact_envelope` before the schema
  validator runs. **verified_by:** task:T2 (adds AP-1/AP-2/AP-4/AP-5
  prompt-content assertions in `bin/agent-prompts-content-test.sh`).
- `merge_artifact_envelope <body> <env-json> <canonical>` is a pure
  structural function (read body, jq-merge envelope right-biased, atomic
  mv to canonical). Exit codes 0/39/41/42/50 stay within
  `failure_outcome_for_exit`'s qa-payload range; the caller (not the
  helper) owns envelope-keyset discipline. **verified_by:** task:T1
  (adds U-1..U-10 helper cases in `bin/common-test.sh`).
- `_clear_current_stage_slots` qa-stage branch clears both body sidecars
  AND both canonical files (`verdict-qa.json`, `verdict-qa.body.json`,
  `qa-predicate-<ident>.json`, `qa-predicate-<ident>.body.json`) on
  qa-stage dispatch start, honoring the ENG-87 per-medium primitive.
  Other stages' files are preserved for loopback. **verified_by:**
  task:T4 (adds OS-4 in `bin/run-stage-test.sh`).
- Merge runs BEFORE `_validate_qa_payload`. On merge failure, the
  orchestrator halts with `qa-payload-invalid: <subcode>` (using
  `failure_outcome_for_exit` mapping); the validator never sees a
  body-only document. **verified_by:** task:T4 (adds OS-1..OS-3 in
  `bin/run-stage-test.sh`).
- `verify-qa.sh validate --body <path>` enforces a realpath fence on the
  body path against `$PROJECT_STATE_DIR` (mirroring the existing
  `$ARG_FILE` fence), merges in-dispatch via the shared helper, and
  validates the merged canonical. Without `--body` the existing
  no-flag form is byte-identical to today. **verified_by:** task:T3
  (adds VQ-1..VQ-5 in `bin/verify-qa-test.sh`).
- `envelope-overwrite` is registered in
  `bin/pipeline-events.json::metric_names` and emitted by the helper
  on key-overlap (forensic signal only; no Linear comment, no halt).
  **verified_by:** task:T6 (adds case-8 in
  `bin/vocabulary-cleanliness-test.sh`).

## File Structure

| Path | Action | Why |
|---|---|---|
| `bin/common.sh` | modify | add `qa_payload_body_path`, `qa_predicate_body_path`, `merge_artifact_envelope`; append all three to line-901 `export -f` |
| `bin/run-stage.sh` | modify | add `_merge_qa_payload_envelope`; wire it into the qa-stage post-dispatch sequence before `_validate_qa_payload`; extend qa-stage branch of `_clear_current_stage_slots` to clear all four qa-stage files (verdict-qa.json + verdict-qa.body.json + qa-predicate-<ident>.json + qa-predicate-<ident>.body.json) — the qa-predicate canonical clear is NEW behavior per D-005, a load-bearing consequence of the sidecar-merge architecture (without it, a stale prior-dispatch canonical could survive when the agent forgets to call verify-qa.sh on re-dispatch) |
| `bin/verify-qa.sh` | modify | add `--body` flag to `_parse_validate_argv`; add realpath fence + envelope-merge phase to `cmd_validate`; caller-side rc remap (39→42, 41→44, 42→42, 50→42) |
| `bin/render-prompt.sh` | modify | register two new `PROMPT_RESOLVERS`; add `_resolve_qa_payload_body_path` + `_resolve_qa_predicate_body_path`; bind `_RENDER_QA_PAYLOAD_BODY_PATH` + `_RENDER_QA_PREDICATE_BODY_PATH` in `main()`; extend `_write_rendered_paths_sidecar`'s closed allowlist with the two new path-shaped tokens |
| `AGENT_PROMPTS.md` | modify | §6 step 1 drops `qa_predicate_schema_version`+`issue_id` from required fields; flips path token from `{qa_predicate_path}` → `{qa_predicate_body_path}`; flips validator invocation to `validate --body {qa_predicate_body_path} --ident {issue_id}`. §6 step 9 drops `qa_payload_schema_version`/`issue_id`/`dispatch_id` from required fields; flips path from `$(issue_dir {issue_id})/verdict-qa.json` to `{qa_payload_body_path}`; both steps add "the orchestrator merges schema envelope keys before validation" sentence |
| `bin/pipeline-events.json` | modify | append `envelope-overwrite` to `metric_names` |
| `bin/common-test.sh` | modify | add U-1..U-10 (helper unit tests) |
| `bin/run-stage-test.sh` | modify | add OS-1..OS-7 (orchestration + caller-side envelope-keyset tests) |
| `bin/verify-qa-test.sh` | modify | add VQ-1..VQ-5 (`--body` flag cases incl. realpath fence + caller-side rc remap) |
| `bin/agent-prompts-content-test.sh` | modify | add AP-1..AP-7 (§6 prompt-content pins) |
| `bin/vocabulary-cleanliness-test.sh` | modify | add case-8: `envelope-overwrite in metric_names registry` |
| `docs/runbooks/recovery.md` | modify | append §15 `qa-payload merge failure (ENG-203)` |
| `CLAUDE.md` | modify | append one row to "Failure-mode quick reference" pointing at §15 |

## API Contract

no new API surface (this is internal-harness plumbing; no FE↔BE handler change).

## Backend Tasks

### Task 0: Rebase onto origin/main

- `depends_on: []`
- `touches: (worktree-level operation; no source files modified)`
- [ ] Run `git fetch origin main` then `git rebase origin/main`. Resolve any
      conflicts; expected: NONE (the two upstream commits touch
      `bin/render-prompt.sh::resolve_block_tokens` body region and
      `bin/render-prompt-rc0-test.sh`; ENG-203's `bin/render-prompt.sh`
      edits sit at lines 40-63 / 283 / 621 — mechanically disjoint).
- [ ] Re-verify every Assumption-Inventory `path:line` reference still
      resolves to the same function/anchor it cited. Any mismatch → STOP
      and halt with `bash bin/pipeline.sh event ENG-203 verdict halt
      --reason agent-blocked` plus a Linear comment naming the drifted
      anchor.
- [ ] Run `bash .githooks/pre-commit` once after rebase to confirm the
      pre-existing test suite still passes pre-edit (baseline). KNOWN_BROKEN
      allow-list will absorb the four flagged failures.

### Task 1: Add the shared helper + body-path resolvers to `bin/common.sh`

- `depends_on: [0]`
- `touches: bin/common.sh, bin/common-test.sh`
- [ ] Add `qa_payload_body_path <ident>` and `qa_predicate_body_path <ident>`
      helpers IMMEDIATELY AFTER the `qa_predicate_path` function. Each mirrors
      the existing `qa_predicate_path` shape: `[[ -n "$issue" ]] || die
      "...: missing issue id"; printf '%s/<filename>' "$(issue_dir "$issue")"`.
      Filenames: `verdict-qa.body.json` (for payload) and
      `qa-predicate-<issue>.body.json` (for predicate — includes the issue
      slug in the basename to mirror the canonical). Content anchor: AFTER
      the `qa_predicate_path() {` block's closing `}` (~line 93) BEFORE the
      `_validate_pass_criterion()` header comment (~line 94-110).
- [ ] Add `merge_artifact_envelope <body-path> <env-json-string>
      <canonical-path>` as a new function. Insert AFTER the `_url_host_class_denied`
      block (the last per-artifact helper before `failure_outcome_for_exit`)
      and BEFORE the `failure_outcome_for_exit` function. Body:

      merge_artifact_envelope() {
        local body="$1" env_json="$2" canonical="$3"
        [[ -f "$body" ]] || { printf 'merge: body missing: %s\n' "$body" >&2; return 41; }
        [[ -L "$body" ]] && { printf 'merge: body is symlink: %s\n' "$body" >&2; return 42; }
        local sz; sz="$(wc -c <"$body" 2>/dev/null | tr -d ' ')"
        if [[ -z "$sz" ]] || (( sz <= 0 || sz > 65536 )); then
          printf 'merge: body size out of range: %s bytes\n' "${sz:-0}" >&2; return 39
        fi
        jq -e 'type == "object"' "$body" >/dev/null 2>&1 \
          || { printf 'merge: body is not a JSON object: %s\n' "$body" >&2; return 39; }
        jq -e 'type == "object"' <<<"$env_json" >/dev/null 2>&1 \
          || { printf 'merge: envelope is not a JSON object\n' >&2; return 42; }
        local tmp
        tmp="$(mktemp "${canonical}.tmp.XXXXXX" 2>/dev/null)" \
          || { printf 'merge: mktemp failed for %s\n' "$canonical" >&2; return 50; }
        if ! jq -n --slurpfile b "$body" --argjson env "$env_json" '$b[0] + $env' > "$tmp" 2>/dev/null; then
          rm -f "$tmp"; printf 'merge: jq failed\n' >&2; return 50
        fi
        # Forensic signal: count overlap keys before swap. Best-effort; jq
        # failure here is non-fatal (the merge already succeeded).
        local overlap_csv overlap_n
        overlap_csv="$(jq -nr --slurpfile b "$body" --argjson env "$env_json" \
          '($b[0] | keys) - (($b[0] | keys) - ($env | keys)) | join(",")' 2>/dev/null || printf '')"
        overlap_n=0
        [[ -n "$overlap_csv" ]] && overlap_n="$(awk -F, '{print NF}' <<<"$overlap_csv")"
        mv "$tmp" "$canonical" \
          || { rm -f "$tmp"; printf 'merge: atomic mv failed\n' >&2; return 50; }
        if (( overlap_n > 0 )) && [[ -n "${PIPELINE_ISSUE_ID:-}" ]] && [[ -x "$(dirname "${BASH_SOURCE[0]}")/metrics.sh" ]]; then
          bash "$(dirname "${BASH_SOURCE[0]}")/metrics.sh" "envelope-overwrite" \
            "${PIPELINE_ISSUE_ID}" "${PIPELINE_STAGE:-unknown}" "merged" "0" \
            "count=$overlap_n keys=$overlap_csv body=$body" >/dev/null 2>&1 || true
        fi
        return 0
      }

      Content anchor: BEFORE the `# Map dispatch.sh exit codes` header (~line 686-697) AFTER the existing `_url_host_class_denied` block's closing `}`.
- [ ] Extend the `export -f` list on line 901 to append three names:
      `merge_artifact_envelope qa_payload_body_path qa_predicate_body_path`.
      Content anchor: the literal `_validate_pass_criterion _url_host_class_denied`
      (insertion AFTER this token, before the closing newline).
- [ ] In `bin/common-test.sh`, append a new block IMMEDIATELY BEFORE the
      `printf '\ncommon-test summary` line. Block header: `# ─── ENG-203:
      merge_artifact_envelope helper (U1-U10) ────`. Cases:
      - **U-1** body `{"verdict":"pass","dimensions":[]}` + envelope
        `{"qa_payload_schema_version":1,"issue_id":"ENG-1","dispatch_id":"ENG-1-d0001"}`
        → rc=0; assert canonical contains all five keys with envelope values.
      - **U-2** collision: body `{"issue_id":"ENG-99","verdict":"pass","dimensions":[]}`
        + envelope `{"issue_id":"ENG-1",...}` → rc=0; canonical `issue_id == "ENG-1"`.
      - **U-3** body missing → rc=41.
      - **U-4** body is JSON array `[{"verdict":"pass"}]` → rc=39 ("not an object").
      - **U-5** body is JSON parse error `{not json` → rc=39.
      - **U-6** body is symlink → rc=42.
      - **U-7** body size > 64 KiB (generate via `printf '%.0s ' {1..65540} > body`) → rc=39.
      - **U-8** envelope arg is non-object JSON string `"hi"` → rc=42.
      - **U-9** canonical write target unwritable (chmod 0500 parent dir) → rc=50.
      - **U-10** adversarial caller: envelope `{"verdict":"fail"}` (content key) with
        body `{"verdict":"pass","dimensions":[]}` → rc=0 + canonical `.verdict == "fail"`.
        Header comment: "The helper is NOT the safety net; callers must construct
        envelopes from identity keys only. This test pins the right-bias contract
        so callers know to validate their envelope keyset."

### Task 2: Edit AGENT_PROMPTS.md §6 (step 1 + step 9) + prompt-content tests

- `depends_on: [1]`
- `touches: AGENT_PROMPTS.md, bin/agent-prompts-content-test.sh`
- [ ] In `AGENT_PROMPTS.md` §6 step 1, replace the JSON document-shape
      from:

      {
        "qa_predicate_schema_version": 1,
        "issue_id": "{issue_id}",
        "pass_criteria": [...]
      }

      with:

      {
        "pass_criteria": [...]
      }

      AND change the Write path token from `{qa_predicate_path}` to
      `{qa_predicate_body_path}`. AND change the validator invocation from
      `bash bin/verify-qa.sh validate {qa_predicate_path} --ident {issue_id}`
      to `bash bin/verify-qa.sh validate --body {qa_predicate_body_path}
      --ident {issue_id}`. ADD a sentence below the document shape: "The
      orchestrator merges the schema envelope (`qa_predicate_schema_version`,
      `issue_id`) onto your body before validation; do not emit those keys
      yourself." Content anchor: the bold header `Emit verification predicate`.
- [ ] In `AGENT_PROMPTS.md` §6 step 9, replace the required-fields
      enumeration from:

      qa_payload_schema_version  integer, must be 1
      issue_id                   "{issue_id}"
      dispatch_id                "{dispatch_id}"   (exported into your env)
      verdict                    one of: pass | fail | halt
      dimensions[]               at least one entry; each must have: ...

      with the trimmed enumeration (verdict + dimensions[] only). AND change
      the Write path from `$(issue_dir {issue_id})/verdict-qa.json` to
      `{qa_payload_body_path}`. ADD a sentence: "The orchestrator merges the
      schema envelope (`qa_payload_schema_version`, `issue_id`, `dispatch_id`)
      onto your body before validation; do not emit those keys yourself."
      Content anchor: the bold header `Emit dimensional grading payload`.
- [ ] **First, rewrite the existing ENG-113 `{qa_predicate_path}` multi-site
      pin in `bin/agent-prompts-content-test.sh` (lines ~473-485 region)** so
      it asserts presence + count≥2 of `{qa_predicate_body_path}` instead of
      `{qa_predicate_path}`. The §6 prompt edit above removes `{qa_predicate_path}`
      from §6 entirely (Write target + validator invocation both flip to
      `{qa_predicate_body_path}`), so the existing assertion's literal would
      fail after Task 2. Edit both `grep -qF '{qa_predicate_path}'` (line 473)
      and `grep -cF '{qa_predicate_path}'` (line 479) to use
      `{qa_predicate_body_path}`; update the assertion labels to
      `§6 ENG-113/ENG-203: '{qa_predicate_body_path}' …` (preserve the ENG-113
      heritage; add ENG-203 to mark the renamed contract). Content anchor:
      the literal `qa_pred_count="$(printf '%s\n' "$s6" | grep -cF
      '{qa_predicate_path}'`. Note: `{qa_predicate_path}` itself remains a
      valid render-prompt token (still resolved for non-§6 consumers like
      `verify-qa.sh::cmd_validate` which calls `qa_predicate_path "$ARG_IDENT"`
      to compute the canonical path); only its §6 prompt usage is gone, so
      the resolver and `_RENDER_QA_PREDICATE_PATH` bind stay live.
- [ ] **Then, append a block** IMMEDIATELY AFTER the rewritten ENG-113/ENG-203
      block (insertion AFTER the surrounding `fi`).
      Block header: `# ─── ENG-203: §6 content-only body contract ───`.
      Cases:
      - **AP-1** §6 does NOT contain `qa_payload_schema_version` in the
        content-shape doc. Implementation: extract the §6 step 9 region by
        anchoring on the bold header `Emit dimensional grading payload` and
        a forward window of ~30 lines (the step body); assert
        `grep -qF 'qa_payload_schema_version' "$step9_window"` returns false.
      - **AP-2** Same window: `grep -qF 'dispatch_id' "$step9_window"`
        returns false within the content-shape sub-block (the explanatory
        sentence may still mention these keys; narrow the assertion to the
        required-fields enumeration sub-block via a second anchor on
        `dimensions[]`).
      - **AP-3** §6 contains the literal `{qa_payload_body_path}` token.
      - **AP-4** §6 step 1 window: `grep -qF 'qa_predicate_schema_version'
        "$step1_window"` returns false within the content-shape sub-block.
      - **AP-5** §6 contains the literal `{qa_predicate_body_path}` token.
      - **AP-6** §6 step 1's verify-qa.sh invocation uses `--body`: assert
        `printf '%s\n' "$s6" | grep -qF -- '--body {qa_predicate_body_path}'`.
      - **AP-7** §6 contains the EXACT literal `bash bin/verify-qa.sh validate
        --body {qa_predicate_body_path} --ident {issue_id}` (the
        copy-pastable shape — pins the flag-positional order so an agent
        that copies the example cannot drift into a no-`--body` form).
      Use `s6="$(section_body "## 6. QA Agent")"` (already present in the
      file at lines 76 and 1861) as the extraction primitive. Reuse the
      existing `ok` / `nope` helpers.

### Task 3: Add `--body` flag to `bin/verify-qa.sh`

- `depends_on: [1]`
- `touches: bin/verify-qa.sh, bin/verify-qa-test.sh`
- [ ] In `_parse_validate_argv` add a new `--body` arm. Insert BEFORE
      the `--*)` rejection branch:

      --body)
        if [[ $# -lt 2 ]]; then
          printf 'verify-qa.sh: --body requires a value\n' >&2; return 42
        fi
        if [[ "$2" == --* ]]; then
          printf 'verify-qa.sh: --body requires a non-flag value, got: %s\n' "$2" >&2; return 42
        fi
        ARG_BODY="$2"; shift 2 ;;

      AND add `ARG_BODY=""` to the initialisation at the top of the
      function. Content anchor: the existing `ARG_FILE=""; ARG_IDENT="";
      ARG_WORKTREE=""` line. Change the trailing
      `[[ -n "$ARG_FILE" ]] || { ... }` requirement to allow `--body` to
      substitute for `$ARG_FILE`: when `ARG_BODY` is non-empty and
      `ARG_FILE` is empty, defer the file requirement (the merge step
      below populates `ARG_FILE` from `qa_predicate_path "$ARG_IDENT"`);
      reject when both are empty.
- [ ] In `cmd_validate`, IMMEDIATELY AFTER `_parse_validate_argv "$@" ||
      return $?` and BEFORE `_check_canonical_path_available`, insert the
      body-merge phase:

      if [[ -n "$ARG_BODY" ]]; then
        # Mandatory --body realpath fence (mirrors lines 140-159 fence on
        # $ARG_FILE). Reject symlink, then anchor body realpath under
        # $PROJECT_STATE_DIR.
        if [[ -L "$ARG_BODY" ]]; then
          printf 'qa-predicate-malformed: --body must not be a symlink: %s\n' "$ARG_BODY" >&2
          return 42
        fi
        if [[ ! -f "$ARG_BODY" ]]; then
          printf 'qa-predicate-missing: --body file not found: %s\n' "$ARG_BODY" >&2
          return 44
        fi
        local body_dir body_parent_real body_real
        body_dir="$(dirname "$ARG_BODY")"
        if ! body_parent_real="$(cd "$body_dir" 2>/dev/null && pwd -P)"; then
          printf 'qa-predicate-malformed: cannot resolve realpath of --body parent: %s\n' "$body_dir" >&2
          return 42
        fi
        body_real="$body_parent_real/$(basename "$ARG_BODY")"
        local prefix_real
        prefix_real="$(cd "$PROJECT_STATE_DIR" && pwd -P)"
        if [[ "$body_real" != "$prefix_real"/* ]]; then
          printf 'qa-predicate-malformed: --body must resolve under $PROJECT_STATE_DIR; got %s\n' "$body_real" >&2
          return 42
        fi
        # Require --ident so we can build the canonical path.
        [[ -n "$ARG_IDENT" ]] || {
          printf 'qa-predicate-incomplete: --body requires --ident <ENG-N>\n' >&2; return 43
        }
        local canonical env_json merge_rc=0
        canonical="$(qa_predicate_path "$ARG_IDENT")"
        env_json="$(jq -nc --arg ii "$ARG_IDENT" \
          '{qa_predicate_schema_version: 1, issue_id: $ii}')"
        PIPELINE_ISSUE_ID="$ARG_IDENT" PIPELINE_STAGE=qa \
          merge_artifact_envelope "$ARG_BODY" "$env_json" "$canonical" \
          || merge_rc=$?
        case "$merge_rc" in
          0)  ARG_FILE="$canonical" ;;
          39) return 42 ;;  # body malformed → qa-predicate-malformed
          41) return 44 ;;  # body missing → qa-predicate-missing
          42) return 42 ;;  # envelope-not-object (caller bug; cannot fire)
          50) return 42 ;;  # write failure
          *)  return 42 ;;
        esac
      fi

      Content anchor: the literal `_parse_validate_argv "$@" || return $?`
      inside `cmd_validate`. The remaining phases (authority check,
      worktree fence, snapshot, schema validate, execute) run against
      `$ARG_FILE` UNCHANGED.
- [ ] In `bin/verify-qa-test.sh`, append a new block at end of file.
      Block header: `# ─── ENG-203: --body flag (VQ1-VQ5) ────`. Cases:
      - **VQ-1** `--body $valid_body --ident ENG-1` writes canonical at
        `qa_predicate_path ENG-1`, merge yields envelope keys + body
        keys, downstream validation passes (rc=0).
      - **VQ-2** `--body $missing_body --ident ENG-1` → rc=44.
      - **VQ-3** `--body $body_with_array_top --ident ENG-1` → rc=42
        (caller-side remap of helper's rc=39).
      - **VQ-4** `--body /tmp/poisoned.json --ident ENG-1` (body OUTSIDE
        `$PROJECT_STATE_DIR`) → rc=42 with stderr matching
        `--body must resolve under \$PROJECT_STATE_DIR`.
      - **VQ-5** no `--body` flag (legacy form: `validate $file --ident
        ENG-1`) → byte-identical behaviour to today.

### Task 4: Wire orchestrator merge + extend dispatch-start clear in `bin/run-stage.sh`

- `depends_on: [1]`
- `touches: bin/run-stage.sh, bin/run-stage-test.sh`
- [ ] Add `_merge_qa_payload_envelope` function. Insert IMMEDIATELY BEFORE
      `_validate_qa_payload` (content anchor: `_validate_qa_payload() {`).
      Body:

      _merge_qa_payload_envelope() {
        local ident="$1"
        local d; d="$(issue_dir "$ident")"
        local body="$d/verdict-qa.body.json"
        local canonical="$d/verdict-qa.json"
        local env_json
        env_json="$(jq -nc --arg ii "$ident" --arg di "${PIPELINE_DISPATCH_ID:-}" \
          '{qa_payload_schema_version: 1, issue_id: $ii, dispatch_id: $di}')"
        local rc=0 raw=""
        raw="$(PIPELINE_ISSUE_ID="$ident" PIPELINE_STAGE=qa \
          merge_artifact_envelope "$body" "$env_json" "$canonical" 2>&1)" || rc=$?
        if (( rc != 0 )); then
          local defect
          case "$rc" in
            41) defect="qa-payload-missing" ;;
            39|42|50) defect="qa-payload-malformed" ;;
            *)  defect="qa-payload-malformed" ;;
          esac
          _post_qa_payload_halt "$ident" "$defect" \
            "merge_artifact_envelope failed (rc=$rc) for body=$body${raw:+ — $raw}"
          return "$rc"
        fi
        return 0
      }

- [ ] Wire `_merge_qa_payload_envelope` into the qa-stage post-dispatch
      sequence. Insert a NEW block BEFORE the existing `# ENG-117: qa-payload
      validator. Post-dispatch; qa stage only.` block and AFTER the ENG-118
      reviewing-stage threshold gate's closing `fi`. Shape:

      # ENG-203: qa-payload envelope merge. Post-dispatch; qa stage only.
      # Reads $(issue_dir)/verdict-qa.body.json (agent-authored, content
      # only), splices orchestrator-constructed envelope onto a fresh
      # canonical verdict-qa.json, halts with qa-payload-invalid on
      # merge failure (body missing → rc=41, body malformed → rc=39,
      # write failure → rc=50, envelope-not-object → rc=42). The
      # downstream _validate_qa_payload runs on the merged canonical.
      if (( ! skip_dispatch )); then
        case "$stage" in
          qa)
            local _qa_merge_rc=0
            _merge_qa_payload_envelope "$ident" || _qa_merge_rc=$?
            if (( _qa_merge_rc != 0 )); then
              classify_failure "$ident" "$stage" "skip-until-human-acts" \
                "qa-payload-invalid: $(failure_outcome_for_exit "$_qa_merge_rc")" \
                "$_qa_merge_rc"
              exit "$_qa_merge_rc"
            fi
            ;;
        esac
      fi

      Content anchor: the literal `# ENG-117: qa-payload validator.
      Post-dispatch; qa stage only.` (insertion BEFORE this comment).
- [ ] Extend the qa-stage branch of `_clear_current_stage_slots`. Replace
      the body of the `if [[ "$stage" == "qa" ]]; then` block (currently
      one `rm -f` for `verdict-qa.json`) with FOUR `rm -f` lines:

      if [[ "$stage" == "qa" ]]; then
        rm -f "$d/verdict-qa.json"                      2>/dev/null || true
        rm -f "$d/verdict-qa.body.json"                 2>/dev/null || true
        rm -f "$d/qa-predicate-${ident}.json"           2>/dev/null || true
        rm -f "$d/qa-predicate-${ident}.body.json"      2>/dev/null || true
      fi

      Content anchor: the literal `if [[ "$stage" == "qa" ]]; then` inside
      `_clear_current_stage_slots`.
- [ ] In `bin/run-stage-test.sh`, append a new block. Block header:
      `# ─── ENG-203: orchestrator-merge + clear-on-start (OS1-OS7) ────`.
      Mirror the ENG-193 W-block source-and-stub setup (line 8909+). Cases:
      - **OS-1** (AC#4 ENG-118 regression) body
        `{"verdict":"pass","dimensions":[{"name":"coverage","score":0.9,
        "rationale":"...","threshold_met":true}]}` (no envelope keys),
        `_merge_qa_payload_envelope` returns 0, canonical has all five
        keys, `_validate_qa_payload` returns 0.
      - **OS-2** body file absent → merge rc=41 → halt-comment posted
        with reason `qa-payload-invalid: qa-payload-missing`.
      - **OS-3** body file is parse-error → merge rc=39 → halt reason
        `qa-payload-invalid: qa-payload-malformed`.
      - **OS-4** Pre-seed all four qa-stage slot files (verdict-qa.json,
        verdict-qa.body.json, qa-predicate-ENG-1.json,
        qa-predicate-ENG-1.body.json) plus a reviewing-stage file
        (verdict-review.json). Call `_clear_current_stage_slots ENG-1 qa`.
        Assert all four qa files absent post-clear AND verdict-review.json
        still present (loopback preservation).
      - **OS-5** In-dispatch verify-qa.sh `--body` flag merges and
        validates predicate. Body has only `pass_criteria[]`; verify-qa
        called with `--body $body --ident ENG-1` succeeds (rc=0) and
        canonical at `qa_predicate_path ENG-1` exists with merged
        envelope.
      - **OS-6** caller-side: `_merge_qa_payload_envelope`'s
        constructed envelope contains exactly `{qa_payload_schema_version,
        issue_id, dispatch_id}`. Probe by stubbing `merge_artifact_envelope`
        to capture the env_json arg and asserting via
        `jq -r 'keys | sort | join(",")' <<<"$captured"` equals
        `dispatch_id,issue_id,qa_payload_schema_version`.
      - **OS-7** caller-side: verify-qa.sh `--body`'s constructed envelope
        contains exactly `{qa_predicate_schema_version, issue_id}`. Same
        stub-capture shape.

### Task 5: `bin/render-prompt.sh` resolver registry + sidecar allowlist

- `depends_on: [1]`
- `touches: bin/render-prompt.sh`
- [ ] Append two entries to `PROMPT_RESOLVERS`:
      `qa_payload_body_path=_resolve_qa_payload_body_path` and
      `qa_predicate_body_path=_resolve_qa_predicate_body_path`. Insert AFTER
      the existing `qa_predicate_path=_resolve_qa_predicate_path` line (~line
      60). Content anchor: the literal `qa_predicate_path=_resolve_qa_predicate_path`.
- [ ] Add the two resolver functions (mirror `_resolve_qa_predicate_path`):

      _resolve_qa_payload_body_path() { printf '%s' "$_RENDER_QA_PAYLOAD_BODY_PATH"; }
      _resolve_qa_predicate_body_path() { printf '%s' "$_RENDER_QA_PREDICATE_BODY_PATH"; }

      Content anchor: the line `_resolve_qa_predicate_path() { printf '%s'
      "$_RENDER_QA_PREDICATE_PATH"; }`.
- [ ] In `main()`, bind the two new `_RENDER_*` globals AFTER the existing
      `_RENDER_QA_PREDICATE_PATH="$(qa_predicate_path "$issue_id")"` bind:

      _RENDER_QA_PAYLOAD_BODY_PATH="$(qa_payload_body_path "$issue_id")"
      _RENDER_QA_PREDICATE_BODY_PATH="$(qa_predicate_body_path "$issue_id")"

      Content anchor: the literal `_RENDER_QA_PREDICATE_PATH="$(qa_predicate_path`.
- [ ] Extend `_write_rendered_paths_sidecar` with two new conditional
      `printf` lines:

      [[ -n "${_RENDER_QA_PAYLOAD_BODY_PATH:-}" ]]   && printf 'qa_payload_body_path\t%s\n'   "$_RENDER_QA_PAYLOAD_BODY_PATH"
      [[ -n "${_RENDER_QA_PREDICATE_BODY_PATH:-}" ]] && printf 'qa_predicate_body_path\t%s\n' "$_RENDER_QA_PREDICATE_BODY_PATH"

      Insert AFTER the existing `_RENDER_REVIEW_LEDGER_PATH` line in the
      same closed allowlist (~line 109). Content anchor: the literal
      `printf 'review_ledger_path\t%s\n'`.

### Task 6: Register `envelope-overwrite` in pipeline-events.json + vocabulary-cleanliness pin

- `depends_on: [1]`
- `touches: bin/pipeline-events.json, bin/vocabulary-cleanliness-test.sh`
- [ ] Append `envelope-overwrite` to the `metric_names` array in
      `bin/pipeline-events.json`. Insert AFTER `"dimensional_threshold_coerced"`
      (the last existing entry). Content anchor: the literal
      `"dimensional_threshold_coerced"`.
- [ ] In `bin/vocabulary-cleanliness-test.sh`, append a new case-8 block
      AFTER the existing ENG-118 case-7 block and BEFORE the
      `# ─── Summary ───` header:

      # ─── ENG-203: envelope-overwrite in metric_names registry ──
      if jq -e '.metric_names | index("envelope-overwrite") != null' "$REG" >/dev/null 2>&1; then
        pass_at "case-8: envelope-overwrite in metric_names registry"
      else
        fail_at "case-8: envelope-overwrite in metric_names registry" \
          "expected \"envelope-overwrite\" in .metric_names array of $REG"
      fi

      Content anchor: the literal `case-7: dimensional_threshold_coerced in
      metric_names registry`.

### Task 7: Recovery runbook + CLAUDE.md failure-mode row

- `depends_on: [1]`
- `touches: docs/runbooks/recovery.md, CLAUDE.md`
- [ ] Append §15 to `docs/runbooks/recovery.md` AFTER the
      §14 dimensional-threshold-coercion section. Section header: `## 15.
      qa-payload merge failure (ENG-203)`. Body covers the four halt
      shapes (body-missing rc=41, body-malformed rc=39, write-fail rc=50,
      envelope-not-object rc=42) and the recovery recipe `bash
      bin/pipeline.sh decide <ENG-N> --action continue`. Cite that
      `_clear_current_stage_slots` pre-cleans both body files at next
      qa-dispatch, so a hand-edit on the body file before resume is
      erased — operators wanting to repair the body must edit the
      canonical instead and force-transition. **Also document the
      deploy-cutover edge case (brainstorm D-008 "In-progress dispatch at
      deploy time"):** an issue already in `stage:qa` when the operator
      rolls out ENG-203 will halt on its next post-dispatch with
      `qa-payload-invalid: qa-payload-missing` because the in-flight
      agent ran under the old prompt and never wrote `verdict-qa.body.json`.
      Recovery is the same `--action continue` — the next qa dispatch
      runs the new prompt, agent writes the body, merge succeeds. Bounded
      to one issue (the one currently in qa). Content anchor: the literal
      `## 14. Dimensional threshold coercion (ENG-118)`.
- [ ] Append one row to `CLAUDE.md` "Failure-mode quick reference" table:
      "Halt at rc=41 with halt-reason `qa-payload-invalid` and a defect
      string starting with `qa-payload-missing` → ENG-203 merge helper
      tripped (agent did not write `verdict-qa.body.json`); see
      `docs/runbooks/recovery.md` §15. **Recovery:** `bash bin/pipeline.sh
      decide <ENG-N> --action continue`." Content anchor: the existing row
      keyed on `dimensional-threshold/<stage>/<ident>`.

## Frontend Tasks

no frontend layer (harness is bash-only; no UI surface).

## Failure Mode → Test Map

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
|---|---|---|---|---|
| Body missing post-dispatch | Agent did not Write `verdict-qa.body.json` | Helper rc=41 → orchestrator halts with `qa-payload-invalid: qa-payload-missing` | unit + integration | U-3, OS-2 |
| Body is JSON parse error | Agent wrote truncated/invalid JSON | Helper rc=39 → halt `qa-payload-malformed` | unit + integration | U-5, OS-3 |
| Body top-level is array, not object | Agent wrote `[{...}]` | Helper rc=39 → halt `qa-payload-malformed` | unit | U-4 |
| Body is symlink | Path-pivot attack | Helper rc=42 → halt `qa-payload-malformed` | unit | U-6 |
| Body exceeds 64 KiB | DoS-meaningful payload | Helper rc=39 → halt `qa-payload-malformed` | unit | U-7 |
| Envelope arg is non-object (caller bug) | Caller passed a JSON string | Helper rc=42 → halt | unit | U-8 |
| Canonical write target unwritable | Disk full / permissions | Helper rc=50 → halt `qa-payload-malformed` | unit | U-9 |
| Caller's envelope contains content key (right-bias contract) | Future caller drift | Helper merges envelope-wins; content key silently overwritten | unit (documentary) | U-10 |
| ENG-118 regression: clean body, zero boilerplate, payload valid | Agent emits the §6-trimmed shape | Merge yields valid canonical; `_validate_qa_payload` returns 0 | integration | OS-1 |
| Stale body / canonical from prior dispatch survives across qa-stage clear | Next-dispatch staleness | All four qa files cleared by `_clear_current_stage_slots`; reviewing-stage file preserved | integration | OS-4 |
| verify-qa.sh `--body` in-dispatch merge | Agent invokes new flag with body-only predicate | Canonical predicate built; downstream validation passes | integration | OS-5, VQ-1 |
| `--body` realpath outside `$PROJECT_STATE_DIR` | Body-path pivot | rc=42 with `--body must resolve under $PROJECT_STATE_DIR` | integration | VQ-4 |
| `--body` file missing | Operator typo / pre-clean race | rc=44 | integration | VQ-2 |
| Legacy verify-qa.sh invocation (no `--body`) | Operator manual triage | byte-identical to pre-ENG-203 behavior | integration | VQ-5 |
| Caller-side envelope-keyset discipline (qa-payload side) | Future drift in `_merge_qa_payload_envelope`'s env_json construction | Test asserts envelope keys ARE exactly `{qa_payload_schema_version, issue_id, dispatch_id}` | integration | OS-6 |
| Caller-side envelope-keyset discipline (qa-predicate side) | Future drift in verify-qa.sh `--body` env_json | Test asserts keys ARE exactly `{qa_predicate_schema_version, issue_id}` | integration | OS-7 |
| §6 step 9 reintroduces `qa_payload_schema_version` / `dispatch_id` (prompt drift) | Future AGENT_PROMPTS.md edit re-types boilerplate into the content-shape doc | Prompt-content test FAILS | unit | AP-1, AP-2 |
| §6 step 1 reintroduces `qa_predicate_schema_version` (prompt drift) | Same | Prompt-content test FAILS | unit | AP-4 |
| §6 strips `--body` from validator invocation | Future prompt edit | AP-6 + AP-7 FAIL (literal flag-positional pin) | unit | AP-6, AP-7 |
| `envelope-overwrite` removed from `metric_names` | Future vocab churn | vocab-cleanliness case-8 FAILS | unit | case-8 |

## Test Strategy

**Unit (`bin/common-test.sh`):** U-1..U-10 pin the helper's contract in
isolation — empty/missing/oversize/symlink/parse-error/array-top-level
inputs, envelope-wins right-bias semantics, write-failure path. The U-10
adversarial case explicitly documents that callers (not the helper) own
envelope-keyset discipline; future readers extending the helper to plan/
review can see the contract pinned.

**Integration (`bin/run-stage-test.sh`):** OS-1..OS-7 cover the
orchestration: ENG-118 regression baseline (OS-1, AC#4), halt paths
(OS-2/3), dispatch-start clear of all four qa-stage files (OS-4, AC of
D-005), verify-qa.sh `--body` in-dispatch merge (OS-5), and caller-side
envelope-keyset assertions on both call sites (OS-6/7).

**Integration (`bin/verify-qa-test.sh`):** VQ-1..VQ-5 cover the new
`--body` flag end-to-end: merge-then-validate (VQ-1), body-missing
(VQ-2), body-malformed remap (VQ-3), realpath-fence violation (VQ-4),
legacy invocation byte-identical to today (VQ-5).

**Prompt-content (`bin/agent-prompts-content-test.sh`):** AP-1..AP-7
prevent §6 drift: positive presence of the new tokens
(`{qa_payload_body_path}`, `{qa_predicate_body_path}`), negative absence
of the now-orchestrator-owned envelope keys, exact-literal pin on the
`bash bin/verify-qa.sh validate --body ... --ident ...` shape so an
agent that copy-pastes can't drop the flag.

**Vocabulary cleanliness (`bin/vocabulary-cleanliness-test.sh`):** case-8
pins `envelope-overwrite` in `metric_names`. The forensic signal stays
discoverable as the helper's silent-repair audit.

**Test-gate closure (remove-side sweep — feasibility persona "test-gate
closure"):** This plan REMOVES (a) the literal strings
`qa_payload_schema_version`, `issue_id` line, and `dispatch_id` line
from the §6 step-9 required-fields enumeration; (b) the literal
`qa_predicate_schema_version` line from §6 step-1's required-fields
enumeration; AND (c) ALL `{qa_predicate_path}` occurrences from §6
(both the Write target and the validator invocation flip to
`{qa_predicate_body_path}`). Grep against all sibling test files for
these tokens:
- `bin/agent-prompts-content-test.sh` — IS in File Structure. Task 2 (a)
  adds inverted assertion AP-1/AP-2/AP-4 for the removed envelope keys,
  AND (b) **rewrites the existing ENG-113 `{qa_predicate_path}` multi-site
  pin at lines 473-485 to assert `{qa_predicate_body_path}` instead** —
  without this rewrite, the existing pin would fail because §6 no longer
  contains `{qa_predicate_path}` after Task 2's prompt edit (feasibility
  persona P0 finding 2026-06-16, plan iter 1).
- `bin/qa-payload-schema-test.sh` / `bin/qa-payload-schema-adversarial-test.sh`
  — these files assert the SCHEMA still requires the envelope keys on the
  MERGED canonical. Those assertions stay positive (the merged file MUST
  have the envelope keys; only the AGENT shouldn't type them). The
  validator itself is unchanged. No File Structure addition needed.
- `bin/render-prompt-test.sh` — the test surface uses
  `{qa_predicate_path}` as a registered token in the resolver registry.
  The token still resolves at render time (still used by
  `verify-qa.sh::cmd_validate` to compute the canonical path); only the
  §6 PROMPT usage switches to `{qa_predicate_body_path}`. The render-prompt
  registry entry + bind stay live but become §6-unused — acceptable cost
  (feasibility P1 finding 2026-06-16; called out so a future reader does
  not remove `qa_predicate_path` as dead code without realising
  `common.sh::qa_predicate_path` is still load-bearing for verify-qa.sh).
  No File Structure addition needed.
- Other `bin/*-test.sh` — no other test grep-matches these tokens.

**Test-gate closure (add-side sweep — feasibility persona):** This plan
adds NO new `bin/*-test.sh` files. All new assertions extend existing
sibling tests. Per the pre-commit hook's glob-of-`bin/*-test.sh` (ENG-196)
and `learned-rules/harness/project-profile.md::"## Build & test gates"`,
no profile edit is required. The profile file is correctly NOT in File
Structure.

**System-invariants resolution sweep (feasibility persona):** Each
`verified_by:` token in `## System invariants` above resolves to a real
task in this plan (T1..T5) whose `touches:` field names at least one
file matching `bin/*-test.sh` (the gate-runnable glob for the harness
target). No `<path>:<test-name>` form is used; all invariants are
verified by tasks in this plan.
