---
linear: ENG-180
date: 2026-06-12
topic: Make `decide --action approve --gate scope` clear `pipeline:halted` AND make the scope-approval replay apply the forward transition directly.
---

# ENG-180 — Make `decide --action approve --gate scope` self-sufficient (Design A)

## Goal

After a NOTABLE `scope-violation` halt, a single
`bash bin/pipeline.sh decide ENG-N --action approve --gate scope`
clears `pipeline:halted`, and the next tick's scope-approval replay applies
the forward transition (`implementing → ui` or `ui → reviewing`) directly,
without triggering `_vh_protocol_violation`.

## Assumption Inventory

**Anti-anchoring check.**
- Problem restatement: *"Operator runs the command the halt comment literally
  advertises and the issue does not resume."* The brainstorm's solution
  (clear halt on approve + replay applies forward transition) is exactly
  this user-visible problem; no reframing.
- Solution proportionality: two small in-place edits in two files
  (`bin/pipeline.sh` + `bin/run-stage.sh`) plus paired test fixtures. No
  new file, no new exit code, no new failure_outcome entry. Proportional.

**Branch-base freshness.**
`git log --oneline HEAD..origin/main` is NON-EMPTY at plan time
(`origin/main` carries the ENG-125 init-sh validator series + the ENG-115
pivot marker work + the ENG-157 system-invariants H2 series, none of which
exist on this branch). Task 0 below rebases before any edit; Edit
boundaries below use CONTENT anchors (not line numbers) so they survive
the rebase. Every `path:line` reference in this Inventory is informational
("approximately at line N") and paired with a unique content anchor
verified against the current worktree HEAD; the line digits may drift
after rebase. The plan does not stand or fall on those digits.

**Existing files this plan modifies.**

- `bin/pipeline.sh::cmd_decide` exists; the `continue`-arm halt-clear
  block is gated on `[[ "$action" == "continue" ]]`. The block is
  literally:
  ```bash
  if bash "$SCRIPT_DIR/linear.sh" has-label "$issue" "pipeline:halted" 2>/dev/null; then
    bash "$SCRIPT_DIR/linear.sh" remove-label "$issue" "pipeline:halted"
  fi
  ```
  (`bin/pipeline.sh:522-525` at plan time, inside the
  `if [[ "$action" == "continue" ]]; then ... fi` block.) The new
  approve-arm branch will call a helper that wraps this block; the
  continue arm will be refactored to call the same helper (mechanical
  equivalence). **Content anchor for inserting the new approve-arm
  branch:** *immediately after the closing `fi` of the
  `if [[ "$action" == "continue" ]]; then ... fi` block (closes around
  `bin/pipeline.sh:555`), BEFORE the comment block "ENG-112:
  schema-driven validation + body render."*

- `bin/pipeline.sh::cmd_decide` issue-id sanitisation
  (`[[ "$issue" =~ ^ENG-[0-9]+$ ]] || die`) lives inside the continue
  arm at `bin/pipeline.sh:508-509`. The new approve-arm branch reuses
  the same regex guard (live path only — `PIPELINE_DRY_RUN!=1`).

- `bin/pipeline.sh::cmd_decide`'s decision-comment write call
  (`bash "$SCRIPT_DIR/linear.sh" add-comment "$issue" "$body"`) is the
  LAST line of the function at `bin/pipeline.sh:574`; it runs for all
  three action arms (continue|approve|abandon). The new approve-arm
  branch MUST run BEFORE this line so the halt-clear precedes the
  decision-comment write (load-bearing per brainstorm OQ-4).

- `bin/pipeline.sh::_pipeline_clear_breaker` is a sibling helper
  defined at `bin/pipeline.sh:452-460`. The new
  `_pipeline_clear_halt_label` helper will be sibling-defined
  immediately after it. **Content anchor:** *immediately AFTER the
  `_pipeline_clear_breaker` function's closing `}` (~line 460) BEFORE
  the comment header `# _pipeline_emit_resume_metric` (~line 462).*

- `bin/run-stage.sh::main` exists. The scope-approval replay gate is
  at `bin/run-stage.sh:1612-1620`:
  ```bash
  local skip_dispatch=0
  if [[ "$stage" == "implementing" || "$stage" == "ui" ]]; then
    local _approval_state="$(issue_dir "$ident")/scope-approval"
    if [[ -f "$_approval_state" ]] \
       && bash "$SCRIPT_DIR/scope-check.sh" has-scope-approval "$ident" 2>/dev/null; then
      log "scope-approval: decision marker posted; skipping agent dispatch for $stage replay"
      skip_dispatch=1
    fi
  fi
  ```
  The gate is restricted to `implementing` and `ui` — both of which
  are in the forward-transition table.

- `bin/run-stage.sh::main`'s stage-drift guard sits at
  `bin/run-stage.sh:2286-2292`; it tests
  `if [[ "$current_stage_label" != "$dispatched_stage_label" ]]; then`
  and exits 0 on drift. The new D-002 early-exit MUST sit immediately
  AFTER this guard so an operator who manually transitioned the issue
  mid-replay still gets the drift short-circuit.

- `bin/run-stage.sh::main`'s post-dispatch halt-apply call sits at
  `bin/run-stage.sh:2294-2297`:
  ```bash
  # Post-dispatch halt apply (ENG-56): orchestrator is the canonical applier
  # of pipeline:halted. See `_post_dispatch_apply_halt` for the wait-shape
  # carve-out and why it's structured as a callable.
  _post_dispatch_apply_halt "$ident" "$stage"
  ```
  The new D-002 early-exit MUST sit immediately BEFORE this call so the
  halt label is not re-applied on the replay path. **Content anchor for
  the insertion:** *AFTER the closing `fi` of the stage-drift guard
  (`if [[ "$current_stage_label" != "$dispatched_stage_label" ]]; then ... exit 0; fi`
  block, identifiable by the literal `log "post-dispatch: stage drifted"`
  inside its body) BEFORE the comment block "Post-dispatch halt apply
  (ENG-56): orchestrator is the canonical applier of pipeline:halted."*

- `bin/run-stage.sh::main` resolves `vh_stage` (long-form stage label)
  AT `bin/run-stage.sh:2304-2305`:
  ```bash
  local vh_stage
  vh_stage="${current_stage_label#stage:}"
  ```
  This sits AFTER the D-002 insertion point. The new branch must
  compute its own local copy (e.g. `_vh_stage_replay`) by mirroring
  this expression.

- `bin/verdict-handler.sh` is sourced by `bin/run-stage.sh` at line 38
  (`source "$SCRIPT_DIR/verdict-handler.sh"`). Both `_vh_lookup_forward`
  and `apply_transition` are therefore in scope to the new D-002 branch.
  `_vh_lookup_forward` is a private helper (underscore-prefixed) and is
  NOT listed in `bin/verdict-handler.sh:606`'s `export -f`; sourcing
  the whole file puts it in scope nonetheless.

- `bin/verdict-handler.sh::_VH_FORWARD_TRANSITIONS` table contains
  `implementing=ui` and `ui=reviewing` rows
  (`bin/verdict-handler.sh:19-27`). `_vh_lookup_forward "implementing"`
  prints `ui`; `_vh_lookup_forward "ui"` prints `reviewing`.

- `bin/verdict-handler.sh::apply_transition` is defined at
  `bin/verdict-handler.sh:311-432` and is idempotent by contract
  (header comment at lines 302-310). Its final step removes
  `pipeline:halted` (`bin/verdict-handler.sh:430`).

- `bin/run-stage.sh::_replay_scope_approval` is defined at
  `bin/run-stage.sh:312-316`:
  ```bash
  _replay_scope_approval() {
    local ident="$1" stage="$2"
    rm -f "$(issue_dir "$ident")/usage-${stage}.json"
    bash "$SCRIPT_DIR/metrics.sh" stage-start "$ident" "$stage" "scope-approval-replay" 0
  }
  ```
  It is invoked by `bin/run-stage.sh:1935` on the `skip_dispatch=1`
  path. It does not affect D-002's branch — the rm-f runs BEFORE the
  scope-check, the new early-exit runs AFTER the scope-check.

- `bin/run-stage.sh`'s NOTABLE-approved branch is at
  `bin/run-stage.sh:1967-1970`:
  ```bash
  if [[ -f "$approval_state_file" ]] \
     && bash "$SCRIPT_DIR/scope-check.sh" has-scope-approval "$ident" 2>/dev/null; then
    log "scope-check: notable approved by scope-approve decision; clearing state and proceeding"
    rm -f "$approval_state_file"
  fi
  ```
  Falls through after deleting the sentinel. The new D-002 branch fires
  later (after post-dispatch + drift guard).

- `bin/poll.sh::_poll_classify_labels` halt-arm
  (`bin/poll.sh:289-314`): any issue with `pipeline:halted` AND no fresh
  non-halt verdict classifies as
  `{slot:"vacate",advanceable:false,operator_action_required:true}`.
  D-001's removal of `pipeline:halted` causes the issue to fall through
  to the `stage:*` arm at the same function — no poll.sh edit needed.

- `bin/scope-check.sh::has_scope_approval` is at lines 217-259. Returns
  0 iff there's a decision marker with `action=approve, gate=scope`
  newer than the most-recent `verdict result=halt reason=scope-violation`
  marker. Used by both the replay gate (`bin/run-stage.sh:1616`) and the
  post-dispatch NOTABLE-approved branch (`bin/run-stage.sh:1968`).

- `bin/verdict-handler.sh::find_fresh_verdict` is at lines 152-252. The
  strict-id path (`_curr_id` set AND any `<!-- meta: dispatch id=` marker
  on the issue) requires verdict comments carrying the current
  dispatch_id marker; the legacy fallback path uses
  `last_transition_ts` from `transition`-event comments only. Decision
  markers are NEVER `event == "verdict"`, so they are filtered out at
  `bin/verdict-handler.sh:183` (strict) and `:218` (legacy).

- `bin/verdict-handler.sh::verdict_handler` is at lines 517-604. The
  empty-`find_fresh_verdict` branch (`bin/verdict-handler.sh:527-540`)
  routes through `_vh_classify_no_fresh_reason` →
  `_vh_protocol_violation`, which adds `pipeline:halted` at
  `bin/verdict-handler.sh:58`. Returns 2.

- `bin/common.sh::failure_outcome_for_exit 22` returns
  `pr-opened-too-early` (`bin/common.sh:322`). The D-002 defensive
  unknown-forward branch reuses exit 22 (per brainstorm §Architecture);
  this is semantically misleading but the branch is unreachable in
  current control flow (the gate at `run-stage.sh:1613` restricts to
  `implementing|ui`, both of which have forward rows). Marked
  **assumed-defensive** — the label `pr-opened-too-early` is wrong if
  the branch ever fires; a follow-up ticket can carve out a dedicated
  code if it does.

- `bin/verdict-handler-test.sh` case-12 is at lines 413-434. Body
  asserts that with comments `[transition, scope-violation halt,
  decision approve gate=scope]`, `find_fresh_verdict` still returns
  `pipeline-halt` (decision is not a verdict marker). This test's
  premise is verdict-handler's contract, NOT the replay flow; D-002
  short-circuits the *caller* of `verdict_handler` on the replay path,
  so this test remains valid as a verdict-handler-contract regression
  guard. Only the prose comment block above the assertions needs a
  one-line clarification — the body assertion (`mtype` is
  `pipeline-halt`) is UNCHANGED.

- `bin/run-stage-test.sh` case-24 D-011 is at lines 649-691. Asserts
  `_replay_scope_approval` rm's `usage-<stage>.json` AND emits a
  metrics call carrying NO `--*` cost flags. D-002's metric end-row
  (`stage-end ... success ... verdict=transitioned
  scope-approval-replay=1`) is appended LATER on the same dispatch
  path — case-24 unit-tests `_replay_scope_approval` in isolation,
  so it's not affected by the new branch.

- `bin/pipeline-test.sh` exists; its existing PD2 fixture
  (`run_pipe decide ENG-PD2 --action approve --gate scope`) is a
  DRY-run dry-printf assertion. The new DEC-APPROVE-SCOPE-1..5
  fixtures land in the live-path block ("ENG-58 atomic-reset"
  starting at `bin/pipeline-test.sh:166`) which already sources
  `bin/pipeline.sh` into the test process and stubs `linear.sh` to
  the `_AR_STUB_DIR`.

- `bin/run-stage-test.sh` already has the source-and-stub pattern
  required for the SCO-REPLAY fixtures: it overrides `SCRIPT_DIR` to
  `STUB_DIR` after sourcing `bin/run-stage.sh`. New SCO-REPLAY-FORWARD
  fixtures will extend that pattern.

- `bin/pipeline.sh` and `bin/run-stage.sh` are NOT new files for this
  plan — they exist; my edits are in-place. **No new file is added by
  this plan.**

- The project profile at
  `learned-rules/harness/project-profile.md` lists
  `bin/run-stage-test.sh` and `bin/verdict-handler-test.sh` directly
  in the `## Build & test gates` Test command (`profile:17`).
  `bin/pipeline-test.sh` is NOT named on the Test line but IS run by
  `.githooks/pre-commit`'s `bin/*-test.sh` glob (which is the same
  full suite Task 8 runs). All three files are also enumerated in the
  Tool allowlist (profile lines ~48 + 100). No new gate-runnable test
  file is created by this plan, so no project-profile edit is
  required; the pre-commit glob is the operative gate.

## System invariants

- D-001 narrows `approve`'s halt-clear to `--gate scope` only; other
  `--action approve` invocations (e.g. `--gate build-cap` if/when added)
  do not gain a halt-clear. verified_by: task:T4
- D-001 preserves the `continue`-arm atomic-reset semantics (drain
  wait files, drain skip labels, drain issue-state, clear breaker,
  clear per-issue counter, auto-commit-in-scope, post operator-resume
  waypoint). verified_by: bin/pipeline-test.sh:PR-E
- D-002's new early-exit fires ONLY when `skip_dispatch=1` (set
  exclusively by the replay gate at `bin/run-stage.sh:1612-1620`),
  guaranteeing fresh dispatches keep their existing post-dispatch
  flow (apply-halt → verdict_handler). verified_by: task:T5
- D-002 short-circuits BEFORE `_post_dispatch_apply_halt` so the
  halt label is not re-applied on the replay path. verified_by: task:T5
- D-002 short-circuits BEFORE `verdict_handler` so the
  protocol-violation re-halt path is not entered on the replay path.
  verified_by: task:T5
- D-002 short-circuits AFTER the stage-drift guard so an operator's
  manual mid-replay transition still wins. verified_by: task:T5
- `apply_transition`'s atomic-transition contract is unchanged
  (transition waypoint comment → add `stage:<to>` → remove
  `stage:<from>` → native-state hook → side-effect labels → remove
  `pipeline:halted`); D-002 invokes it as a caller, does not modify
  it. verified_by: bin/verdict-handler-test.sh:case-12
- `find_fresh_verdict`'s freshness semantics are unchanged; D-002
  bypasses the call site on the replay path rather than altering the
  helper. verified_by: bin/verdict-handler-test.sh:case-12
- The scope-approval replay path remains cost-flag-free in metrics
  (D-011 contract): D-002's metric end-row receives no `--*` cost
  flags because `_replay_scope_approval` already rm'd
  `usage-<stage>.json` earlier on the same dispatch.
  verified_by: bin/run-stage-test.sh:case-24
- The `dispatch_history.jsonl` start/end pairing invariant is
  preserved: `skip_dispatch=1` already elides the start-row + EXIT-trap
  install (`bin/run-stage.sh:1671` `(( ! skip_dispatch ))` gate), so
  D-002's new exit point emits no end-row by design. verified_by: task:T5
- The `continue`-arm refactor regression guard: after extracting the
  inline halt-clear into `_pipeline_clear_halt_label`, every existing
  `continue` test that greps `remove-label ENG-… pipeline:halted$`
  still passes. verified_by: bin/pipeline-test.sh:PR-E

## File Structure

Modified:

- `bin/pipeline.sh` — new helper `_pipeline_clear_halt_label`; new
  approve-arm branch in `cmd_decide`; continue-arm halt-clear inline
  refactored to call the helper.
- `bin/run-stage.sh` — new `skip_dispatch` early-exit branch in `main`
  between stage-drift guard and `_post_dispatch_apply_halt`.
- `bin/pipeline-test.sh` — new fixtures DEC-APPROVE-SCOPE-1..5; one
  comment-line edit above the existing PR-E test noting "ENG-180
  D-001 refactor regression guard."
- `bin/run-stage-test.sh` — new fixtures SCO-REPLAY-FORWARD-1,
  SCO-REPLAY-FORWARD-2, SCO-REPLAY-DEFENSIVE, SCO-REPLAY-STAGE-DRIFT,
  SCO-REPLAY-IDEMPOTENT, SCO-REPLAY-CONTINUE-COMPOSITE.
- `bin/verdict-handler-test.sh` — one-line comment edit on case-12
  (re-cast as verdict-handler-contract regression guard).
- `CLAUDE.md` — new row in `## Failure-mode quick reference`
  contrasting pre-ENG-180 "approved but stuck" symptom with
  post-ENG-180 expected behaviour; legacy force-apply escape hatch
  documented as historical.

No new files. No new exit code. No new failure_outcome entry. No new
ADR. No project-profile edit.

## API Contract

no new API surface (this is a bash orchestration scripts repo; no FE↔BE
boundary in the surface this plan touches).

## Backend Tasks

### Task 0: Rebase onto origin/main

- `depends_on: []`
- `touches: <branch operation; no in-repo edits in this task>`
- [ ] Run `git fetch origin main` then `git rebase origin/main` from
  this branch. None of this plan's edits are expected to conflict —
  this plan touches `bin/pipeline.sh`, `bin/run-stage.sh`,
  `bin/verdict-handler-test.sh`, `bin/pipeline-test.sh`,
  `bin/run-stage-test.sh`, and `CLAUDE.md`; the ENG-125 / ENG-115 /
  ENG-157 work on main lands in `bin/dispatch.sh`,
  `bin/render-prompt.sh`, `bin/common.sh::validate_init_sh`,
  `bin/plan-schema.sh::cmd_validate_md`, and new sibling test files
  (`bin/init-sh-validator-{,adversarial-}test.sh`) — non-overlapping
  surface.
- [ ] After rebase, re-verify Assumption Inventory by grepping for
  each content anchor (function names + distinctive surrounding
  strings). If any anchor no longer exists, halt the dispatch and
  surface as a P0 — the rebase materially changed a load-bearing
  region.
- [ ] Run `bash bin/pipeline-test.sh` and `bash bin/run-stage-test.sh`
  to confirm the rebased base is green before any new edit lands.

### Task 1: Add `_pipeline_clear_halt_label` helper in `bin/pipeline.sh`

- `depends_on: [T0]`
- `touches: bin/pipeline.sh::_pipeline_clear_halt_label (new)`
- [ ] In `bin/pipeline.sh`, insert a new helper sibling to
  `_pipeline_clear_breaker`. **Content anchor:** AFTER the closing `}`
  of `_pipeline_clear_breaker`'s body (the function whose body ends
  with `printf '%s' "$was_paused"`), BEFORE the `# _pipeline_emit_resume_metric`
  header comment.
  ```bash
  # _pipeline_clear_halt_label <issue>
  # Idempotent. has-label short-circuits the remove-label call on a
  # missing label so the typical no-halt-present case is a single
  # read instead of read+write. ENG-180 D-001: extracted from the
  # continue arm so the approve --gate scope arm can call it too.
  _pipeline_clear_halt_label() {
    local issue="$1"
    if bash "$SCRIPT_DIR/linear.sh" has-label "$issue" "pipeline:halted" 2>/dev/null; then
      bash "$SCRIPT_DIR/linear.sh" remove-label "$issue" "pipeline:halted"
    fi
  }
  ```

### Task 2: Refactor continue arm to call the helper

- `depends_on: [T1]`
- `touches: bin/pipeline.sh::cmd_decide`
- [ ] In `cmd_decide`'s continue arm, replace the inline halt-clear
  block. **Content anchor:** the block matching the literal
  ```bash
  # Remove halt label if present (mirrors halt.sh rc=1 branch behavior).
  if bash "$SCRIPT_DIR/linear.sh" has-label "$issue" "pipeline:halted" 2>/dev/null; then
    bash "$SCRIPT_DIR/linear.sh" remove-label "$issue" "pipeline:halted"
  fi
  ```
  inside the `if [[ "$action" == "continue" ]]; then` arm (after
  `_pipeline_drain_issue_state`, before `_pipeline_clear_breaker`).
  Replace the entire `if has-label ... fi` body (preserving the
  surrounding `# Remove halt label ...` comment) with a single line:
  ```bash
  _pipeline_clear_halt_label "$issue"
  ```
- [ ] Run `bash bin/pipeline-test.sh`; PR-E (continue + halted) must
  still pass.

### Task 3: Add `approve --gate scope` halt-clear branch to `cmd_decide`

- `depends_on: [T1]`
- `touches: bin/pipeline.sh::cmd_decide`
- [ ] Insert the new approve-arm branch. **Content anchor:** AFTER
  the closing `fi` of the `if [[ "$action" == "continue" ]]; then ... fi`
  block (identifiable by the trailing else-branch that logs
  `pipeline-decide: $issue action=continue (dry-run — atomic reset suppressed)`),
  BEFORE the comment line
  `# ENG-112: schema-driven validation + body render. The continue-rejects-gate`
  (this comment sits immediately above the
  `local _decide_args=("action=$action")` line).
  ```bash
  # ENG-180 D-001: approve --gate scope clears pipeline:halted so the
  # poller re-dispatches the replay. Narrow scope — only the halt
  # label, not the full atomic reset (operator uses continue for that).
  # Order: halt-clear BEFORE decision-comment write, matching the
  # continue arm. dry-run suppresses the live linear.sh call.
  if [[ "$action" == "approve" && "$gate" == "scope" ]]; then
    if [[ "${PIPELINE_DRY_RUN:-}" != "1" ]]; then
      [[ "$issue" =~ ^ENG-[0-9]+$ ]] \
        || die "decide: invalid issue id '$issue' (expected ENG-<digits>)"
      _pipeline_clear_halt_label "$issue"
      log "pipeline-decide: $issue action=approve gate=scope (halt label cleared)"
    else
      log "pipeline-decide: $issue action=approve gate=scope (dry-run — halt-clear suppressed)"
    fi
  fi
  ```

### Task 4: Add `bin/pipeline-test.sh` DEC-APPROVE-SCOPE fixtures

- `depends_on: [T2, T3]`
- `touches: bin/pipeline-test.sh`
- [ ] Extend the live-path block (already sources `bin/pipeline.sh`
  and stubs `linear.sh` to `_AR_STUB_DIR`; the block opens at
  `printf '\n--- bin/pipeline.sh: decide continue → ENG-58 atomic reset ---\n'`).
  Add a sibling printf banner
  `--- bin/pipeline.sh: decide approve --gate scope (ENG-180) ---`
  to delimit the new fixtures from the continue ones.
- [ ] **DEC-APPROVE-SCOPE-1 (halt-clear fires when halt present):**
  `: > "$_AR_LINEAR_CALLS"`; `LABELS_ON="pipeline:halted"
  STAGE_OF="stage:implementing" _ar_decide "ENG-1801" --action approve
  --gate scope`; assert
  `grep -c "^remove-label ENG-1801 pipeline:halted$" "$_AR_LINEAR_CALLS"`
  == 1; assert the decision-comment `add-comment ENG-1801` line appears
  AFTER the `remove-label` line in the call log (line-order grep with
  `grep -n` + awk).
- [ ] **DEC-APPROVE-SCOPE-2 (halt-clear idempotent on no-halt):**
  `: > "$_AR_LINEAR_CALLS"`; `LABELS_ON="" _ar_decide "ENG-1802"
  --action approve --gate scope`; assert ZERO
  `remove-label ENG-1802 pipeline:halted` lines in the call log;
  assert the decision-comment `add-comment ENG-1802` still appears.
- [ ] **DEC-APPROVE-SCOPE-3 (other gates unaffected):**
  `: > "$_AR_LINEAR_CALLS"`; `LABELS_ON="pipeline:halted"
  _ar_decide "ENG-1803" --action approve --gate build-cap`; assert
  ZERO `remove-label ENG-1803 pipeline:halted` lines.
- [ ] **DEC-APPROVE-SCOPE-4 (dry-run suppresses halt-clear):**
  invoke via the dry-run subshell `run_pipe` helper:
  `out="$(run_pipe decide ENG-1804 --action approve --gate scope 2>&1)"`;
  assert `"$out"` contains the log line
  `dry-run — halt-clear suppressed`; assert ZERO
  `remove-label ENG-1804` line in `_AR_LINEAR_CALLS` (the dry-run
  subshell uses the stub-PATH from the dry-run capture block at the
  top of the file).
- [ ] **DEC-APPROVE-SCOPE-5 (invalid issue id):**
  `: > "$_AR_LINEAR_CALLS"`; capture stderr into `out`:
  `out="$(_ar_decide INVALID-ID --action approve --gate scope 2>&1 || true)"`;
  assert `"$out"` contains the substring `expected ENG-<digits>`;
  assert ZERO `add-comment` or `remove-label` lines for `INVALID-ID`
  in `_AR_LINEAR_CALLS`.
- [ ] One-line comment edit immediately above the existing PR-E
  fixture: `# ENG-180 D-001 refactor regression guard: confirms the
  inline halt-clear → _pipeline_clear_halt_label extraction preserved
  the remove-label call shape.`

### Task 5: Add `bin/run-stage-test.sh` SCO-REPLAY fixtures

- `depends_on: [T3]`
- `touches: bin/run-stage-test.sh`
- [ ] Extend the source-and-stub region (already overrides
  `SCRIPT_DIR` to `STUB_DIR` after sourcing `bin/run-stage.sh`). Add a
  delimiting printf banner
  `--- bin/run-stage.sh: scope-approval-replay forward-transition (ENG-180) ---`.
- [ ] **SCO-REPLAY-FORWARD-1 (implementing → ui):** Per-issue stub
  setup: `mkdir -p "$(issue_dir ENG-T-SR1)"; touch "$(issue_dir
  ENG-T-SR1)/scope-approval"`. Stub `scope-check.sh` to return rc=1
  with one `notable\t<file>` line (sentinel + has-scope-approval=0
  drives `skip_dispatch=1`). Stub `linear.sh stage-of` returning
  `stage:implementing`. Override `apply_transition`,
  `_post_dispatch_apply_halt`, and `verdict_handler` in the running
  shell to write their argv to capture files (same pattern
  `verdict-handler-test.sh` uses for `mk_fixture`). Drive
  `main ENG-T-SR1 implementing`. Assert:
  - capture-file for `apply_transition` contains exactly one row
    matching `ENG-T-SR1 implementing ui ` (trailing empty side-csv).
  - capture-file for `_post_dispatch_apply_halt` is empty.
  - capture-file for `verdict_handler` is empty.
  - dispatch exit code is 0.
  - the metrics-call capture contains a `stage-end` row matching
    `ENG-T-SR1 implementing success ... verdict=transitioned scope-approval-replay=1`.
- [ ] **SCO-REPLAY-FORWARD-2 (ui → reviewing):** same shape as -1 but
  start with `stage-of` returning `stage:ui` and dispatch
  `main ENG-T-SR2 ui`. Assert `apply_transition` capture contains
  `ENG-T-SR2 ui reviewing `.
- [ ] **SCO-REPLAY-DEFENSIVE (unknown forward → halt):** override
  `_vh_lookup_forward()` in the running shell to print nothing
  unconditionally; drive the SCO-REPLAY-FORWARD-1 fixture; assert the
  defensive `classify_failure` capture contains a row matching
  `ENG-T-SR3 implementing skip-until-human-acts scope-approval-replay:
  no forward transition from implementing`; assert dispatch exit code
  is 22.
- [ ] **SCO-REPLAY-STAGE-DRIFT (operator mid-replay transitioned):**
  stub `linear.sh stage-of` returning `stage:reviewing` while
  `main` was invoked with `implementing` as the dispatched stage —
  the existing drift guard MUST short-circuit BEFORE D-002. Assert
  the `apply_transition` capture is EMPTY (D-002 didn't fire); assert
  the `metrics.sh stage-end` capture contains a row with outcome
  `stage-drift` (matches the existing drift-guard emit).
- [ ] **SCO-REPLAY-IDEMPOTENT (re-entry after partial-failure):**
  run the SCO-REPLAY-FORWARD-1 fixture twice in sequence with the
  same per-issue state; assert both runs exit 0 AND the
  `apply_transition` capture contains TWO rows (idempotent re-entry).
- [ ] **SCO-REPLAY-CONTINUE-COMPOSITE (continue after a prior approve
  resolves):** seed the issue-state stub with `pipeline:halted` label
  ON, plus a `get-comments` stub returning a fixture sequence
  `[transition planning→implementing, verdict halt
  reason=scope-violation, decision approve gate=scope]`, plus the
  sentinel file at `$(issue_dir ENG-T-CCC)/scope-approval`. Source
  `bin/pipeline.sh`'s `cmd_decide` (same pattern as PR-E) and call
  `_ar_decide ENG-T-CCC --action continue`. Assert
  `remove-label ENG-T-CCC pipeline:halted` AND a comment matching
  `from=implementing to=implementing` (the operator-resume waypoint)
  appear in the `_AR_LINEAR_CALLS` log. Then re-source the
  run-stage-test.sh harness and drive `main ENG-T-CCC implementing`.
  Assert: scope-approval gate fires (sentinel present + decision
  marker still present — continue did NOT touch them); D-002
  transitions forward; zero `_vh_protocol_violation` capture rows.
  Drives AC #4.

### Task 6: Re-cast `bin/verdict-handler-test.sh` case-12 as a regression guard

- `depends_on: [T3]`
- `touches: bin/verdict-handler-test.sh::case-12 (comment edit only)`
- [ ] Locate case-12. **Content anchor:** the header
  `# ─── Case 12: decide-continue-posts-decision-and-clears-halt ─────────`.
  Replace the prose block immediately below it (starting
  `# After bin/pipeline.sh decide ...` through
  `# comments (they're not a verdict shape).`) with a clarifying
  one-paragraph rewrite:
  ```
  # ENG-180 regression guard for verdict-handler's contract.
  # post-ENG-180, D-002 in bin/run-stage.sh::main short-circuits the
  # *caller* of verdict_handler on the scope-approval replay path, so
  # the empirical "approve clears halt" recovery no longer enters this
  # codepath. The CONTRACT this case pins is unchanged: find_fresh_verdict
  # must continue to treat `decision` markers as non-verdicts (they have
  # event != "verdict"), so the most-recent verdict-shape marker — the
  # scope-violation halt — must still surface as `pipeline-halt`.
  ```
  The assertion body (`mtype` is `pipeline-halt`) is UNCHANGED.

### Task 7: Add `CLAUDE.md` failure-mode row

- `depends_on: [T2, T3]`
- `touches: CLAUDE.md::## Failure-mode quick reference`
- [ ] In `CLAUDE.md`, locate `## Failure-mode quick reference`. The
  table is markdown-pipe-delimited with `Symptom | Where to look`
  columns. **Content anchor:** the row beginning
  `| Per-issue halt (self-leak / leaked-in-scope at threshold / N×same-issue failure)`.
  Insert a NEW row directly after that row (clustering halt-diagnosis
  rows together):
  ```markdown
  | Issue at `stage:implementing` or `stage:ui` with `pipeline:halted` after a NOTABLE scope-violation halt; operator ran `bash bin/pipeline.sh decide <ENG-N> --action approve --gate scope` but the slot did not recall within one tick | **Post-ENG-180 expected:** next tick's replay logs `scope-check: notable approved by scope-approve decision; clearing state and proceeding` followed by `stage <stage> complete for <ENG-N> (scope-approval-replay transitioned <src> → <fwd>)` and the issue advances. **Pre-ENG-180 signature (legacy hosts only):** `post-dispatch: applying pipeline:halted (orchestrator-managed, ENG-56)` followed by `verdict-handler: protocol violation (no-marker): no fresh verdict marker on the issue (current_dispatch_id=<unset>)`. **Legacy-only recovery:** export `TARGET_REPO`, then `source bin/verdict-handler.sh; apply_transition <ENG-N> implementing ui` (or `ui reviewing`), then `bash bin/linear.sh remove-label <ENG-N> pipeline:halted`. This escape hatch is unnecessary post-ENG-180. |
  ```

### Task 8: Run the full test suite

- `depends_on: [T4, T5, T6, T7]`
- `touches: <verification only; no edits>`
- [ ] Run `bash bin/pipeline-test.sh` — DEC-APPROVE-SCOPE-1..5 +
  PR-E continue regression all PASS.
- [ ] Run `bash bin/run-stage-test.sh` — SCO-REPLAY-FORWARD-1,
  SCO-REPLAY-FORWARD-2, SCO-REPLAY-DEFENSIVE, SCO-REPLAY-STAGE-DRIFT,
  SCO-REPLAY-IDEMPOTENT, SCO-REPLAY-CONTINUE-COMPOSITE, plus
  case-24 D-011 (unaffected) all PASS.
- [ ] Run `bash bin/verdict-handler-test.sh` — case-12 (re-cast as
  regression guard) PASS.
- [ ] Run `bash .githooks/pre-commit` (the full suite per
  `learned-rules/harness/project-profile.md::Test`) green.
- [ ] If any test fails, fix the test or the implementation — do NOT
  commit until green.

## Frontend Tasks

(none — this is a bash orchestration scripts repo with no FE)

## Failure Mode → Test Map

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
|---|---|---|---|---|
| `approve --gate scope` does not clear `pipeline:halted` | Operator runs `decide --action approve --gate scope` on a halted scope-violation issue | `pipeline:halted` is removed from Linear; decision comment posts | unit | `bin/pipeline-test.sh:DEC-APPROVE-SCOPE-1` |
| `approve --gate scope` regresses on no-halt-present | Operator runs the same command on an issue with no halt label | No `remove-label` call; decision comment still posts (idempotent) | unit | `bin/pipeline-test.sh:DEC-APPROVE-SCOPE-2` |
| `approve --gate build-cap` accidentally also clears halt | Operator approves a non-scope gate | No `remove-label` call (scope is the only gate that clears halt) | unit | `bin/pipeline-test.sh:DEC-APPROVE-SCOPE-3` |
| `approve --gate scope` mutates state under PIPELINE_DRY_RUN | Operator runs the same command with `PIPELINE_DRY_RUN=1` | Halt-clear suppressed; log line says so | unit | `bin/pipeline-test.sh:DEC-APPROVE-SCOPE-4` |
| `approve --gate scope` with shell-meta in issue id | Operator passes `INVALID-ID` (or worse) | Die with `expected ENG-<digits>` before any linear.sh call | unit | `bin/pipeline-test.sh:DEC-APPROVE-SCOPE-5` |
| Continue-arm halt-clear breaks after refactor | Refactor moves the inline halt-clear into `_pipeline_clear_halt_label` | Existing PR-E `^remove-label ENG-5801 pipeline:halted$` grep still passes | unit | `bin/pipeline-test.sh:PR-E continue + halted + full side state → atomic reset` |
| Scope-approval replay re-halts because no fresh verdict | Replay runs on a sentinel + approved issue at `stage:implementing` | `apply_transition` invoked with `(implementing, ui)`; no `_post_dispatch_apply_halt`; no `verdict_handler` call; exit 0; metric `verdict=transitioned scope-approval-replay=1` | integration | `bin/run-stage-test.sh:SCO-REPLAY-FORWARD-1` |
| Scope-approval replay re-halts at `stage:ui` | Replay runs on a sentinel + approved issue at `stage:ui` | `apply_transition` invoked with `(ui, reviewing)`; exit 0 | integration | `bin/run-stage-test.sh:SCO-REPLAY-FORWARD-2` |
| Scope-approval replay hits an unknown forward stage | Future stage joins replay gate without a forward row | `classify_failure skip-until-human-acts` fires; exit 22 | integration | `bin/run-stage-test.sh:SCO-REPLAY-DEFENSIVE` |
| Operator transitions issue mid-replay | `linear.sh stage-of` returns a label different from dispatched-stage label | Stage-drift guard short-circuits BEFORE D-002 branch; no `apply_transition` from D-002 | integration | `bin/run-stage-test.sh:SCO-REPLAY-STAGE-DRIFT` |
| Replay restarted after partial-failure | Same fixture replayed twice | Both runs complete without error; `apply_transition` idempotent | integration | `bin/run-stage-test.sh:SCO-REPLAY-IDEMPOTENT` |
| Operator runs `continue` (not `approve`) on an issue with scope-approval already posted | Halt + scope-violation halt verdict + decision approve + sentinel all present | `continue` clears halt + posts operator-resume waypoint; next dispatch's replay still transitions forward via D-002 | integration | `bin/run-stage-test.sh:SCO-REPLAY-CONTINUE-COMPOSITE` |
| Verdict-handler treats `decision` markers as verdict markers (regression) | Comments stream `[transition, scope-violation halt, decision approve gate=scope]` | `find_fresh_verdict` still surfaces the `pipeline-halt` (decision is filtered out) | unit | `bin/verdict-handler-test.sh:case-12` |
| Replay path leaks cost flags through D-002's metric end-row | `_replay_scope_approval` ran (rm'd usage-file) but downstream emits cost flags | D-002's metric call carries no `--*` cost flags (no usage-file to read) | unit | `bin/run-stage-test.sh:case-24 D-011 replay: usage-<stage>.json removed and metrics carries no cost flags` |

## Test Strategy

**Unit (per-function).** `bin/pipeline-test.sh` runs `cmd_decide`
in-process via the existing source-and-stub harness; the new fixtures
DEC-APPROVE-SCOPE-1..5 cover the D-001 surface plus the dry-run + bad
issue-id paths. The refactor regression guard is the existing PR-E
run; passing it after the helper extraction proves the refactor is
mechanical. Case-12 of `bin/verdict-handler-test.sh` stays as a
regression guard for `find_fresh_verdict`'s decision-marker filter.

**Integration (cross-function inside a single shell).**
`bin/run-stage-test.sh`'s source-and-stub harness drives the new
SCO-REPLAY-FORWARD-1/2/DEFENSIVE/STAGE-DRIFT/IDEMPOTENT/CONTINUE-COMPOSITE
fixtures. Each fixture stubs `scope-check.sh`, `linear.sh`, and
overrides `apply_transition`, `_post_dispatch_apply_halt`,
`verdict_handler` in the running shell so the assertion can match the
exact `(from, to)` pair passed to `apply_transition` and confirm the
other two are NOT invoked.

**Adversarial.** The IDEMPOTENT and STAGE-DRIFT fixtures are
adversarial-shaped. STAGE-DRIFT proves the existing drift guard still
wins over the new D-002 branch; IDEMPOTENT proves twice-run replays
don't double-transition (relies on `apply_transition`'s idempotency
contract).

**Smoke / e2e.** None added. The bash orchestration repo has no
end-to-end harness beyond `PIPELINE_DRY_RUN=1 bash bin/dry-run.sh`,
and the new branch fires only on a sentinel + has-scope-approval
state that dry-run does not synthesise. The integration coverage
above is the appropriate ceiling.

**Explicit waivers (brainstorm-acknowledged out-of-scope edge
cases).** Two brainstorm §Edge cases entries are deliberately NOT
added as Failure Mode → Test Map rows:

- Brainstorm edge case 7 ("Multiple stale `stage:*` labels survive
  `apply_transition`"): `apply_transition`'s existing semantics do
  not sweep stale `stage:*` labels — that is true today and remains
  true under D-002 because D-002 calls `apply_transition` unchanged.
  Out of scope per brainstorm.
- Brainstorm edge case 8 (PIPELINE_WRITER lane warning on
  `approve --gate scope`): `cmd_decide`'s existing
  `PIPELINE_WRITER != "human"` warn-only check at the bottom of the
  function is unchanged by D-001. The new approve-arm branch fires
  BEFORE the warn site (it sits inside the action-arm matrix, the
  warn sits in the post-arm body-render block), so behaviour on the
  warn surface is unchanged. Out of scope per brainstorm.

**Test-gate closure (additions side).** No new gate-runnable file is
created. New fixtures land inside `bin/pipeline-test.sh`,
`bin/run-stage-test.sh`, and `bin/verdict-handler-test.sh`. The
project profile's `## Build & test gates` Test line directly names
the last two; `bin/pipeline-test.sh` is run via
`.githooks/pre-commit`'s `bin/*-test.sh` glob (Task 8 invokes the
pre-commit gate). All three files are also in the Tool allowlist. No
project-profile edit required.

**Test-gate closure (removals side).** This plan does NOT remove any
token (no allowlist entry dropped, no function renamed, no enum
variant deleted, no default changed). Only additions and a single
helper extraction. `bin/pipeline.sh`'s `_pipeline_clear_halt_label`
adds a new symbol; all callers of the removed inline block now route
through it (continue arm refactored in-place — same effective
behaviour). The DEC-CONTINUE-REGRESSION check (PR-E grep on
`^remove-label ... pipeline:halted$`) catches any silent regression.

**System-invariants resolution.** Eleven bullets in `## System
invariants`. Six reference existing tests
(`bin/pipeline-test.sh:PR-E`, `bin/verdict-handler-test.sh:case-12`,
`bin/run-stage-test.sh:case-24`); five reference in-plan tasks
(`task:T4`, `task:T5`) whose `touches:` fields name gate-runnable
files in the Build & test gates Test command
(`bin/pipeline-test.sh`, `bin/run-stage-test.sh`).
