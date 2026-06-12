---
linear: ENG-180
date: 2026-06-12
topic: Make `decide --action approve --gate scope` self-sufficient — clear halt label and short-circuit the scope-approval replay to apply the forward transition directly
---

# Plan — ENG-180 · scope-approval resume self-sufficiency

## Goal

The command the halt comment advertises (`bash bin/pipeline.sh decide ENG-N --action approve --gate scope`) becomes truthful: after a NOTABLE scope-violation halt, a single invocation removes `pipeline:halted`, and the next launchd tick's scope-approval replay advances the stage (`implementing → ui` or `ui → reviewing`) — no second operator touch needed, no protocol-violation re-halt, no slot-stays-vacated symptom.

## Assumption Inventory

Branch-base freshness: `git log --oneline HEAD..origin/main` is **NON-EMPTY** at plan time — the branch is ~30 commits behind `origin/main` (most recent additions: ENG-125 init.sh validator series; SB-17 poll dispatch-id preservation). None of those commits rewrites the files in this plan's File Structure in a way that invalidates the design (verified by re-reading `bin/pipeline.sh::cmd_decide`, `bin/run-stage.sh::main` scope-approval gate + post-dispatch flow, `bin/verdict-handler.sh::apply_transition`/`_vh_lookup_forward`, and `bin/poll.sh::_poll_classify_labels` against the worktree). Task T0 below rebases the feature branch onto `origin/main` before any other implementation work; every `path:line` reference below MUST be re-verified by content anchor after the rebase. All Edit boundaries use content anchors per the prompt's "Edit-boundary keys" requirement; line numbers are informational hints only.

Every file referenced as MODIFIED below has its current target function/region verified against the worktree:

- **`bin/pipeline.sh::cmd_decide`** at `bin/pipeline.sh:472` (`cmd_decide() {`). Continue-arm gate at `bin/pipeline.sh:503` (`if [[ "$action" == "continue" ]]; then`). Inline halt-clear at `bin/pipeline.sh:523-525` — verified content:
  ```
  if bash "$SCRIPT_DIR/linear.sh" has-label "$issue" "pipeline:halted" 2>/dev/null; then
    bash "$SCRIPT_DIR/linear.sh" remove-label "$issue" "pipeline:halted"
  fi
  ```
  D-014 issue-id guard at `bin/pipeline.sh:508-509` (`[[ "$issue" =~ ^ENG-[0-9]+$ ]] || die`). Continue-arm close at `bin/pipeline.sh:555` (`fi`). Decision-comment post at `bin/pipeline.sh:574` (`bash "$SCRIPT_DIR/linear.sh" add-comment "$issue" "$body"`).
- **`bin/pipeline.sh::_pipeline_clear_breaker`** at `bin/pipeline.sh:452-460` (sibling helper, naming template for the new `_pipeline_clear_halt_label`).
- **`bin/run-stage.sh`** scope-approval gate at `bin/run-stage.sh:1612-1620` — verified content:
  ```
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
- **`bin/run-stage.sh::main`** post-completion-comment block at `bin/run-stage.sh:2264-2272` (`case "$stage" in brainstorming|planning|implementing|ui|reviewing|qa|building) ... post_completion_comment ... ;; esac`). Stage-drift guard at `bin/run-stage.sh:2274-2292` — content anchors: comment line `# Stage-drift guard (ENG-41 §4.3)` and closing `fi` followed by inline `exit 0`. `_post_dispatch_apply_halt` call at `bin/run-stage.sh:2297` — anchor: leading comment `# Post-dispatch halt apply (ENG-56)`. `verdict_handler` call at `bin/run-stage.sh:2314` (`verdict_handler "$ident" "$vh_stage" || vh_rc=$?`). `vh_stage` resolved from `current_stage_label` at `bin/run-stage.sh:2304-2305`.
- **`bin/run-stage.sh` scope-check NOTABLE-approved branch** at `bin/run-stage.sh:1967-1970` — anchor: `log "scope-check: notable approved by scope-approve decision; clearing state and proceeding"`. Halt-comment body that advertises `--action approve --gate scope` at `bin/run-stage.sh:1985-1986` (UNMODIFIED by this plan).
- **`bin/verdict-handler.sh`** sourced at `bin/run-stage.sh:38` (`source "$SCRIPT_DIR/verdict-handler.sh"`). `_vh_lookup_forward` defined at `bin/verdict-handler.sh:40-43` (in scope to `run-stage.sh::main` via source; NOT in the `export -f` list at line 606, but accessible because the whole file is sourced). `_VH_FORWARD_TRANSITIONS` table at `bin/verdict-handler.sh:19-27` contains `implementing=ui` and `ui=reviewing`. `apply_transition` defined at `bin/verdict-handler.sh:311`, exported at `bin/verdict-handler.sh:606`, idempotent per the contract comment at `bin/verdict-handler.sh:309-310`, removes `pipeline:halted` as step 5 at `bin/verdict-handler.sh:430`.
- **`bin/pipeline-test.sh::PR-E`** at `bin/pipeline-test.sh:257-273` — existing continue-arm test that asserts `remove-label ENG-5801 pipeline:halted` appears in the capture (`bin/pipeline-test.sh:266`); will keep passing after refactor.
- **`bin/run-stage-test.sh::case-24`** at `bin/run-stage-test.sh:649-691` — existing D-011 fixture that calls `_replay_scope_approval` and asserts (a) usage-file removed and (b) zero cost-flags. UNMODIFIED by this plan; survives unchanged because new D-002 branch in `run-stage.sh::main` runs AFTER `_replay_scope_approval` already deleted the usage file.
- **`bin/verdict-handler-test.sh::case-12`** at `bin/verdict-handler-test.sh:413-434` — existing regression guard asserting `find_fresh_verdict` ignores `decision` markers (the most-recent verdict-shape marker stays `pipeline-halt`). UNMODIFIED contract-wise; the brainstorm's recast suggestion (re-cast as regression guard for the verdict-handler contract) is a one-line comment edit performed in this plan's Task T5.
- **`bin/scope-check.sh::has_scope_approval`** at `bin/scope-check.sh:221-259` returns 0 iff there's a `decision action=approve gate=scope` comment newer than the most recent scope-violation halt. UNMODIFIED.
- **`bin/poll.sh::_poll_classify_labels`** at `bin/poll.sh:240+`, halt-label arm at `bin/poll.sh:289-314` — classifies any issue with `pipeline:halted` as `slot:"vacate", advanceable:false, operator_action_required:true` regardless of `decision` markers. UNMODIFIED.
- **`bin/pipeline-events.json::decision_gates`** registers `scope` and `build-cap` at `bin/pipeline-events.json:46-49`. `events.verdict.linear_comment.writer_lane` is `"agent"` at `bin/pipeline-events.json:90`. UNMODIFIED.
- **`bin/common.sh::failure_outcome_for_exit`** maps exit 22 to `pr-opened-too-early`. The D-002 defensive unknown-forward branch reuses exit 22 (assumed-defensive; unreachable in current control flow per the gate at `bin/run-stage.sh:1613` restricting to `stage in (implementing, ui)`).
- **`CLAUDE.md` "Failure-mode quick reference"** table exists in the file. New row added for the post-ENG-180 expected behaviour (per brainstorm §Architecture).
- **`learned-rules/harness/project-profile.md`** "Build & test gates" `Test:` line — this plan adds NO new `bin/*-test.sh` files. All new fixtures land INSIDE existing files already covered by the pre-commit hook's `for t in bin/*-test.sh` loop (`.githooks/pre-commit:162`). The profile file is therefore NOT in File Structure (add-side test-gate closure sweep does not apply).
- **Test-gate closure (remove-side)**: this plan REMOVES no tokens from production code — the inline halt-clear block at `bin/pipeline.sh:523-525` becomes a call to the new helper, but the underlying `remove-label pipeline:halted` instruction is preserved character-for-character INSIDE the helper. No sibling test contains a soon-to-be-removed token. The grep `remove-label.*pipeline:halted` against `bin/pipeline-test.sh` finds line 266 (PR-E) which keeps passing because the refactored continue arm still issues that exact command via the helper. No P0 plan-completeness defect.

## System invariants

- **`find_fresh_verdict` filters by `event=="verdict"`; `decision` markers are never visible to it.** verified_by: `bin/verdict-handler-test.sh:case-12 halt-sh-resolve-posts-decision-and-clears-halt (decision is not a verdict marker)`
- **`has_scope_approval` returns true iff a `decision action=approve gate=scope` comment is newer than the most-recent `scope-violation` halt verdict.** verified_by: `bin/verdict-handler-test.sh:case-14 has-scope-approval-returns-true-when-decision-post-dates-halt (fixture shape)`
- **`apply_transition` is idempotent and removes `pipeline:halted` as its final step.** verified_by: `bin/verdict-handler-test.sh:case-13 building-conflict-loops-to-implementing` (existing assertion at `bin/verdict-handler-test.sh:443-450` covering `apply_transition`'s label-flip + halt-drain shape on a forward transition).
- **`_pipeline_clear_halt_label` is idempotent (no-op when label absent) and is the sole halt-label-removal call site invoked by both `continue` and `approve --gate scope` arms.** verified_by: `task:T2` (DEC-APPROVE-SCOPE-1/2 + the existing PR-E regression assert idempotency on both arms; new fixtures defined under `bin/pipeline-test.sh`).
- **The scope-approval replay's D-002 branch in `run-stage.sh::main` calls `apply_transition` directly, BYPASSING `_post_dispatch_apply_halt` and `verdict_handler`.** verified_by: `task:T3` (SCO-REPLAY-FORWARD-1 asserts apply_transition is invoked with `(implementing, ui, "")` AND `_post_dispatch_apply_halt`/`verdict_handler` are NOT invoked; defined under `bin/run-stage-test.sh`).
- **The D-002 metric end-row carries `verdict=transitioned scope-approval-replay=1` with zero cost-flags (D-011 contract).** verified_by: `task:T3` (SCO-REPLAY-FORWARD-1 asserts the metric tail exactly).
- **D-002's defensive unknown-forward branch is unreachable in current control flow** (the scope-approval gate at `bin/run-stage.sh:1613` restricts `skip_dispatch=1` to `stage in (implementing, ui)`, both of which have rows in `_VH_FORWARD_TRANSITIONS` at `bin/verdict-handler.sh:19-27`). verified_by: `task:T3` (SCO-REPLAY-DEFENSIVE forces the empty-forward path via a stubbed `_vh_lookup_forward` and asserts `exit 22` + `classify_failure skip-until-human-acts`).
- **Stage-drift guard runs BEFORE the new D-002 branch, so an operator who manually transitions mid-replay is short-circuited identically to today.** verified_by: `task:T3` (SCO-REPLAY-STAGE-DRIFT asserts drift exit fires BEFORE the D-002 branch is reached).

## File Structure

Modified:

- `bin/pipeline.sh` — new helper `_pipeline_clear_halt_label`; new `approve --gate scope` branch inside `cmd_decide`; existing inline halt-clear in the continue arm refactored to call the helper.
- `bin/run-stage.sh` — new `skip_dispatch` early-exit branch inside `main`, inserted between the stage-drift guard and `_post_dispatch_apply_halt`.
- `bin/pipeline-test.sh` — new fixtures DEC-APPROVE-SCOPE-1..5 (extends the existing PR-E pattern).
- `bin/run-stage-test.sh` — new fixtures SCO-REPLAY-FORWARD-1..2 + SCO-REPLAY-DEFENSIVE + SCO-REPLAY-STAGE-DRIFT + SCO-REPLAY-IDEMPOTENT + SCO-REPLAY-CONTINUE-COMPOSITE (extends the existing case-24 D-011 pattern).
- `bin/verdict-handler-test.sh` — one-line comment recast on case-12 narrating the new "regression guard for verdict-handler contract post-D-002" intent. No assertion change.
- `CLAUDE.md` — new "Failure-mode quick reference" row for the scope-approval-resume symptom (text drafted in the brainstorm §Architecture).

Newly created: none.

## API Contract

No new API surface. ENG-180 has no FE↔BE boundary — both touched files (`bin/pipeline.sh`, `bin/run-stage.sh`) are orchestration scripts. The pipeline-marker vocabulary (`pipeline-events.json`) is UNCHANGED; the new D-002 branch emits a standard `<!-- pipeline: transition from=X to=Y -->` waypoint via `apply_transition` (existing shape).

## Backend Tasks

### Task T0: Rebase onto origin/main + re-verify Assumption Inventory anchors
- `depends_on: []`
- `touches: bin/pipeline.sh, bin/run-stage.sh, bin/verdict-handler.sh, bin/scope-check.sh, bin/poll.sh, bin/pipeline-test.sh, bin/run-stage-test.sh, bin/verdict-handler-test.sh, CLAUDE.md`
- [ ] `git fetch origin main && git rebase origin/main` on the feature branch.
- [ ] Re-verify every `path:line` excerpt in Assumption Inventory survived the rebase. The brainstorm's line numbers were captured pre-rebase; after rebase, line numbers may drift. The content anchors named in Assumption Inventory (e.g. `if bash "$SCRIPT_DIR/linear.sh" has-label "$issue" "pipeline:halted" 2>/dev/null; then` for `cmd_decide`'s inline halt-clear; `log "scope-approval: decision marker posted; skipping agent dispatch for $stage replay"` for the scope-approval gate; `log "scope-check: notable approved by scope-approve decision; clearing state and proceeding"` for the NOTABLE-approved branch; `_post_dispatch_apply_halt "$ident" "$stage"` for the halt-apply call site; `verdict_handler "$ident" "$vh_stage" || vh_rc=$?` for the verdict-handler call site) MUST grep-match exactly once each in their respective files post-rebase. If any anchor moved or split, STOP and post a Linear comment requesting `pipeline:supersede` — the brainstorm is drafting against pre-rebase semantics.
- [ ] Resolve any conflicts in `bin/run-stage.sh` (highest risk file given the ENG-125 series touched it) by re-running the brainstorm's empirical reproducer mentally: scope-approval gate runs → `skip_dispatch=1` → post-dispatch scope-check NOTABLE-approved branch fires → stage-drift guard short-circuit OR fall through → INSERT POINT for D-002 → today's `_post_dispatch_apply_halt` + `verdict_handler` flow. The INSERT POINT must remain between the closing `fi` of the stage-drift guard and the call to `_post_dispatch_apply_halt`.

### Task T1: Add `_pipeline_clear_halt_label` helper and refactor `cmd_decide`'s continue arm to call it
- `depends_on: [T0]`
- `touches: bin/pipeline.sh::_pipeline_clear_halt_label (new), bin/pipeline.sh::cmd_decide (refactor continue arm)`
- [ ] In `bin/pipeline.sh`, AFTER the `_pipeline_clear_breaker() { ... }` block (content anchor: the closing `}` immediately preceding `_pipeline_emit_resume_metric() {`) and BEFORE `_pipeline_emit_resume_metric() {`, add:
  ```bash
  # ENG-180 D-001: shared halt-label-clear used by both continue and
  # approve --gate scope arms of cmd_decide. Idempotent: linear.sh
  # remove-label is a no-op on missing label; the has-label guard
  # short-circuits the call to keep the legacy log noise from the
  # continue arm's prior inline shape.
  _pipeline_clear_halt_label() {
    local issue="$1"
    if bash "$SCRIPT_DIR/linear.sh" has-label "$issue" "pipeline:halted" 2>/dev/null; then
      bash "$SCRIPT_DIR/linear.sh" remove-label "$issue" "pipeline:halted"
    fi
  }
  ```
- [ ] In `bin/pipeline.sh::cmd_decide` continue arm, REPLACE the inline halt-clear block (content anchor: the 3-line `if bash "$SCRIPT_DIR/linear.sh" has-label "$issue" "pipeline:halted" 2>/dev/null; then ... remove-label ... fi`) with a single line `_pipeline_clear_halt_label "$issue"`. This is a mechanical refactor — the helper's body is the same three lines verbatim. The PR-E regression test at `bin/pipeline-test.sh:257-273` keeps asserting `remove-label ENG-5801 pipeline:halted` in the linear-calls capture because the helper issues the identical command.

### Task T2: Add `approve --gate scope` halt-clear branch to `cmd_decide`
- `depends_on: [T1]`
- `touches: bin/pipeline.sh::cmd_decide (new approve branch), bin/pipeline-test.sh (new DEC-APPROVE-SCOPE-1..5)`
- [ ] In `bin/pipeline.sh::cmd_decide`, INSERT a new approve-arm block AFTER the closing `fi` of the `if [[ "$action" == "continue" ]]; then ... fi` block (content anchor: that `fi` is immediately followed by the comment `# ENG-112: schema-driven validation + body render.` and the line `local _decide_args=("action=$action")`). The insert lands BEFORE `# ENG-112: schema-driven validation + body render.`:
  ```bash
  # ENG-180 D-001: approve --gate scope must clear pipeline:halted, otherwise
  # poll.sh::_poll_classify_labels keeps the slot vacated and the replay
  # never runs. Scope is intentionally narrow: only the halt label, not the
  # full atomic reset. Mirrors the continue arm's cleanup-before-comment
  # ordering (see brainstorm OQ-4) so partial-failure is recoverable on a
  # re-run: halt-clear runs first; the decision comment writes last via
  # the shared add-comment call at the function tail.
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
- [ ] In `bin/pipeline-test.sh`, AFTER the existing PR-E block (content anchor: the closing assertion line `pass_at "PR-E: continue atomic reset (wait+state cleared, labels removed, waypoint posted)"`) and the trailing fail_at, add a new `# ─── ENG-180 D-001: approve --gate scope → halt-label-clear ───` section with five fixtures using the existing `_ar_decide` / `_ar_seed` / `_AR_LINEAR_CALLS` plumbing:
  - **DEC-APPROVE-SCOPE-1 (halt-clear fires):** `LABELS_ON="pipeline:halted"` + `_ar_decide ENG-T-APP1 --action approve --gate scope`; assert exactly one `remove-label ENG-T-APP1 pipeline:halted` line in `$_AR_LINEAR_CALLS` AND one `add-comment ENG-T-APP1 ...decision action=approve gate=scope...` line, with the remove-label line appearing BEFORE the add-comment line.
  - **DEC-APPROVE-SCOPE-2 (idempotent on no-halt):** `LABELS_ON=""` + same call; assert ZERO `remove-label` lines AND one `add-comment` line.
  - **DEC-APPROVE-SCOPE-3 (other gate untouched):** `LABELS_ON="pipeline:halted"` + `_ar_decide ENG-T-APP3 --action approve --gate build-cap`; assert ZERO `remove-label` lines AND one `add-comment ENG-T-APP3 ...decision action=approve gate=build-cap...` line.
  - **DEC-APPROVE-SCOPE-4 (dry-run suppression):** `PIPELINE_DRY_RUN=1` + `_ar_decide ENG-T-APP4 --action approve --gate scope`; assert ZERO entries in `$_AR_LINEAR_CALLS` (existing dry-run pattern at `bin/pipeline.sh:569-572` is shared by the new arm).
  - **DEC-APPROVE-SCOPE-5 (invalid issue id):** `_ar_decide INVALID-ID --action approve --gate scope`; assert non-zero rc and `expected ENG-<digits>` on stderr; assert ZERO entries in `$_AR_LINEAR_CALLS`.

### Task T3: Add scope-approval replay forward-transition early-exit to `run-stage.sh::main`
- `depends_on: [T0]`
- `touches: bin/run-stage.sh::main (new skip_dispatch early-exit branch), bin/run-stage-test.sh (new SCO-REPLAY-FORWARD-1..2 + SCO-REPLAY-DEFENSIVE + SCO-REPLAY-STAGE-DRIFT + SCO-REPLAY-IDEMPOTENT + SCO-REPLAY-CONTINUE-COMPOSITE)`
- [ ] In `bin/run-stage.sh::main`, INSERT a new `(( skip_dispatch ))` branch AFTER the stage-drift guard's closing `fi` (content anchor: the line `bash "$SCRIPT_DIR/metrics.sh" stage-end "$ident" "$stage" "stage-drift" "$duration" \` followed by `"drift=${current_stage_label:-none}" || true` and `exit 0` and the closing `fi`) and BEFORE `_post_dispatch_apply_halt "$ident" "$stage"` (content anchor: the preceding comment `# Post-dispatch halt apply (ENG-56): orchestrator is the canonical applier`). The insert MUST also fall AFTER the `local vh_stage; vh_stage="${current_stage_label#stage:}"` resolution (content anchor: the line `vh_stage="${current_stage_label#stage:}"`) since the new branch references `$vh_stage`. Re-order if needed: move the `vh_stage` resolution UP to immediately after the stage-drift guard's closing `fi`, BEFORE the `# Post-dispatch halt apply (ENG-56)` block, so the new branch sees the resolved value. The two existing call sites (`_post_dispatch_apply_halt`, `verdict_handler "$ident" "$vh_stage"`) continue to see the same `$vh_stage` value:
  ```bash
  # ENG-180 D-002: scope-approval replay applies the forward transition
  # directly. The replay deliberately skips the agent dispatch (no fresh
  # verdict marker is emitted), so verdict_handler's find_fresh_verdict
  # would return empty and _vh_protocol_violation would re-halt. The
  # source stage's prior clean pass already earned the transition; emit
  # it here. Runs after post_completion_comment so the orchestrator's
  # narrative post still lands; runs before _post_dispatch_apply_halt so
  # the halt label is not re-applied; runs before verdict_handler so the
  # protocol-violation path is not entered. vh_stage is the long-form
  # stage from the current Linear label (resolved above).
  if (( skip_dispatch )); then
    local _fwd
    _fwd="$(_vh_lookup_forward "$vh_stage")"
    if [[ -z "$_fwd" ]]; then
      # Defensive — unreachable in current control flow: scope-approval
      # gate is restricted to implementing|ui (run-stage.sh scope-approval
      # gate above), both of which have forward rows in
      # _VH_FORWARD_TRANSITIONS. Future stages joining the gate without
      # a forward row will fall here.
      classify_failure "$ident" "$stage" "skip-until-human-acts" \
        "scope-approval-replay: no forward transition from $vh_stage" 22
      exit 22
    fi
    apply_transition "$ident" "$vh_stage" "$_fwd" ""
    t1="$(date +%s)"; duration=$(( (t1 - t0) * 1000 ))
    bash "$SCRIPT_DIR/metrics.sh" stage-end "$ident" "$stage" "success" "$duration" \
      "verdict=transitioned scope-approval-replay=1"
    log "stage $stage complete for $ident (scope-approval-replay transitioned $vh_stage → $_fwd)"
    exit 0
  fi
  ```
- [ ] In `bin/run-stage-test.sh`, AFTER the existing case-24 block (content anchor: the closing `fi` of the case-24 if/then; followed by the `# ─── Case 25:` comment header), add six new fixtures under a `# ─── ENG-180 D-002: scope-approval-replay forward transition ───` section. Use the existing case-24 plumbing (`STUB_DIR`, `METRICS_CAPTURE_F`, source-with-stub pattern) extended with stubs for `_vh_lookup_forward` / `apply_transition` (capture-only stubs) and a stub `linear.sh stage-of` returning `stage:implementing` / `stage:ui` as needed:
  - **SCO-REPLAY-FORWARD-1 (implementing → ui):** sentinel file + `has-scope-approval` returns 0 + scope-check stubs to rc=1 with `notable\t...` line + `linear.sh stage-of` returns `stage:implementing`. Drive `run-stage.sh::main` (sourced not invoked) with `stage=implementing`. Assert: `apply_transition ENG-T-SR1 implementing ui ""` is in the capture; `_post_dispatch_apply_halt` was NOT called (capture contains zero `_post_dispatch_apply_halt` invocations); `verdict_handler` was NOT called; exit code is 0; metrics capture contains `stage-end ENG-T-SR1 implementing success ... verdict=transitioned scope-approval-replay=1`.
  - **SCO-REPLAY-FORWARD-2 (ui → reviewing):** same shape, `stage=ui`, assert `apply_transition ENG-T-SR2 ui reviewing ""`.
  - **SCO-REPLAY-DEFENSIVE (unknown forward):** override `_vh_lookup_forward` stub to return empty for the dispatched stage; assert `classify_failure ENG-T-SR3 ... skip-until-human-acts ... scope-approval-replay: no forward transition from <vh_stage>` in the capture and exit 22.
  - **SCO-REPLAY-STAGE-DRIFT:** `linear.sh stage-of` returns `stage:ui` while `stage=implementing` is dispatched; assert stage-drift early-exit fires (capture contains `stage-end ENG-T-SR4 implementing stage-drift ...`) and the D-002 branch is NOT reached (no `apply_transition` in capture).
  - **SCO-REPLAY-IDEMPOTENT:** run the same SCO-REPLAY-FORWARD-1 fixture twice in sequence; both runs exit 0; second run's `apply_transition` capture entry is identical to the first (apply_transition is idempotent per `bin/verdict-handler.sh:309-310`).
  - **SCO-REPLAY-CONTINUE-COMPOSITE:** seed halt label + scope-violation halt verdict comment + `decision action=approve gate=scope` comment + scope-approval sentinel file; call `cmd_decide ENG-T-SR6 --action continue` (sourced via the same source-pipeline.sh pattern as PR-E); assert halt removed + operator-resume transition posted; then drive `run-stage.sh::main` against the same per-issue state with `stage=implementing`; assert scope-approval gate fires (sentinel + has-scope-approval both true), D-002 branch fires, `apply_transition ENG-T-SR6 implementing ui ""` is in the capture, no protocol-violation.

### Task T4: Add CLAUDE.md failure-mode row
- `depends_on: [T0]`
- `touches: CLAUDE.md::"## Failure-mode quick reference"`
- [ ] In `CLAUDE.md`, locate the row in the failure-mode quick-reference table for `Halt at rc=29 with sidecar` (content anchor: the table cell starting `| Halt at rc=29 with sidecar` near the bottom of the table). INSERT a new row BEFORE the `| Kill switch |` row, AFTER the existing `Issue stuck in stage:X` row, with the body drafted in the brainstorm §Architecture's "Proposed row text" block. The two-symptom shape (post-ENG-180 expected behaviour + pre-ENG-180 legacy recovery via `apply_transition <ENG-N> implementing ui` + `remove-label pipeline:halted`) is preserved verbatim so an operator on a not-yet-deployed host can still self-recover.

### Task T5: Recast verdict-handler-test case-12 as a regression guard
- `depends_on: [T0]`
- `touches: bin/verdict-handler-test.sh::case-12`
- [ ] In `bin/verdict-handler-test.sh`, locate case-12 (content anchor: the comment line `# ─── Case 12: decide-continue-posts-decision-and-clears-halt ─────────`). UPDATE the leading comment to read: `# ─── Case 12: regression guard — find_fresh_verdict ignores decision events ─────────` and append one sentence to the description block: `Post-ENG-180 D-002: this case remains the contract guard that find_fresh_verdict treats <!-- pipeline: decision ... --> as non-verdict-shape; the production call site previously exposed by this contract (scope-approval replay) is now short-circuited in run-stage.sh::main BEFORE verdict_handler runs, so this case no longer guards a live failure mode — but the verdict-handler contract itself is unchanged and still pinned here.` No assertion change; the test stays green.

### Task T6: Full bin/*-test.sh suite green via .githooks/pre-commit
- `depends_on: [T1, T2, T3, T4, T5]`
- `touches: (verification — no code change)`
- [ ] Run `bash .githooks/pre-commit` from the worktree. All `bin/*-test.sh` files (except the KNOWN_BROKEN list at `.githooks/pre-commit:88-110`) must exit 0. The new fixtures DEC-APPROVE-SCOPE-1..5, SCO-REPLAY-FORWARD-1..2, SCO-REPLAY-DEFENSIVE, SCO-REPLAY-STAGE-DRIFT, SCO-REPLAY-IDEMPOTENT, SCO-REPLAY-CONTINUE-COMPOSITE must all pass; existing case-24, case-12, case-13, case-14, case-15, PR-E and downstream cases must stay green.

## Frontend Tasks

None. ENG-180 has no UI surface. The harness has no frontend.

## Failure Mode → Test Map

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
|---|---|---|---|---|
| Operator runs `approve --gate scope` on a halted scope-violation issue | NOTABLE scope-violation halt + sentinel + decision comment NOT yet posted | `_pipeline_clear_halt_label` removes `pipeline:halted`; decision comment posts | unit | `bin/pipeline-test.sh::DEC-APPROVE-SCOPE-1` |
| Operator runs `approve --gate scope` on an issue with no halt label | idempotency check | no `remove-label` call; decision comment still posts | unit | `bin/pipeline-test.sh::DEC-APPROVE-SCOPE-2` |
| Operator runs `approve --gate build-cap` (non-scope gate) | back-compat | no halt-clear; decision comment posts (existing behaviour) | unit | `bin/pipeline-test.sh::DEC-APPROVE-SCOPE-3` |
| `approve --gate scope` under `PIPELINE_DRY_RUN=1` | dry-run discipline | halt-clear AND decision comment both suppressed | unit | `bin/pipeline-test.sh::DEC-APPROVE-SCOPE-4` |
| `approve --gate scope` with invalid issue id | D-014 path-traversal guard | dies with `expected ENG-<digits>`; no linear.sh calls | unit | `bin/pipeline-test.sh::DEC-APPROVE-SCOPE-5` |
| `continue` arm halt-clear regression after T1 helper refactor | helper-call mechanical equivalence | existing PR-E test stays green; `remove-label pipeline:halted` still emitted | regression | `bin/pipeline-test.sh::PR-E` |
| Scope-approval replay on `stage:implementing` | sentinel + `has-scope-approval` true post-D-001 | D-002 branch fires; `apply_transition implementing → ui`; no halt re-apply; no verdict_handler | integration | `bin/run-stage-test.sh::SCO-REPLAY-FORWARD-1` |
| Scope-approval replay on `stage:ui` | same with stage=ui | `apply_transition ui → reviewing`; PR-create hook fires idempotently | integration | `bin/run-stage-test.sh::SCO-REPLAY-FORWARD-2` |
| D-002 defensive: forward-stage lookup returns empty | unreachable in current control flow | `classify_failure skip-until-human-acts` + exit 22 | integration | `bin/run-stage-test.sh::SCO-REPLAY-DEFENSIVE` |
| Stage-drifted mid-replay (operator manually transitioned) | drift guard precedence | stage-drift exit 0 fires BEFORE D-002 branch | integration | `bin/run-stage-test.sh::SCO-REPLAY-STAGE-DRIFT` |
| D-002 idempotency under re-entry | partial-failure recovery | second run is no-op-equivalent; `apply_transition` is idempotent | integration | `bin/run-stage-test.sh::SCO-REPLAY-IDEMPOTENT` |
| `continue` run on `approve --gate scope` state (composite resume) | belt-and-braces | continue clears halt + posts operator-resume; next replay fires D-002; no protocol-violation | integration | `bin/run-stage-test.sh::SCO-REPLAY-CONTINUE-COMPOSITE` |
| `find_fresh_verdict` regression — decision events leak into verdict-shape | verdict-handler contract guard | most-recent verdict-shape marker stays `pipeline-halt` despite later decision | unit | `bin/verdict-handler-test.sh::case-12` (recast) |
| Stale `usage-<stage>.json` on scope-approval replay | D-011 carry-forward guard | usage file removed; replay metric carries no cost flags | integration | `bin/run-stage-test.sh::case-24` (unchanged) |

## Test Strategy

- **Unit:** `bin/pipeline-test.sh` exercises `cmd_decide`'s approve-arm + continue-arm in-process by sourcing `bin/pipeline.sh` and overriding `SCRIPT_DIR` to a stub dir (existing pattern at `bin/pipeline-test.sh:192-237`). Five new DEC-APPROVE-SCOPE fixtures cover the halt-clear shape, idempotency, gate-narrowing, dry-run suppression, and the D-014 issue-id guard. The existing PR-E test is the regression guard for the T1 helper refactor (no new fixture needed; the refactor preserves the legacy `remove-label` call via the helper).
- **Integration:** `bin/run-stage-test.sh` drives `run-stage.sh::main` through the scope-approval replay path. Six new fixtures cover (a) forward-transition for both `implementing` and `ui` source stages, (b) the unreachable-defensive branch via a stubbed `_vh_lookup_forward`, (c) stage-drift precedence, (d) idempotency under re-entry, and (e) the continue-then-replay composite. Stubs follow the existing case-24 pattern: capture-only `metrics.sh`, capture-only Linear stubs, captured `apply_transition` invocations.
- **Cross-suite:** `bin/verdict-handler-test.sh::case-12`'s assertion stays green unchanged; only its leading-comment narrative is recast (T5). `bin/run-stage-test.sh::case-24` (D-011) and `bin/scope-check-test.sh::has_scope_approval` cases are UNMODIFIED.
- **Adversarial coverage intent:** the D-002 defensive unknown-forward branch + SCO-REPLAY-STAGE-DRIFT + SCO-REPLAY-IDEMPOTENT triple-cover the failure modes a future contributor might regress (skipping the drift guard, dropping the defensive branch, breaking apply_transition's idempotency).
- **Test-gate closure (remove-side):** see Assumption Inventory — this plan removes no token from production code that any sibling test pins. `grep -nE 'remove-label.*pipeline:halted' bin/*-test.sh` finds `bin/pipeline-test.sh:266` (PR-E) which keeps passing because the refactored helper issues that exact command. No additional file needs to land in File Structure.
- **Test-gate closure (add-side):** no new `bin/*-test.sh` file is created — all new fixtures land inside existing files (`bin/pipeline-test.sh`, `bin/run-stage-test.sh`, `bin/verdict-handler-test.sh`) already covered by `.githooks/pre-commit:162`'s `for t in bin/*-test.sh` loop. The `learned-rules/harness/project-profile.md`'s "Build & test gates" `Test:` line is not in File Structure for this reason.
- **System invariants resolution sweep:** every `verified_by:` token in "## System invariants" resolves to either (a) a real `bin/verdict-handler-test.sh::case-N` (case-12, case-13, case-14 — verified present at the cited line ranges) or (b) a `task:T<N>` (T2, T3) whose `touches:` field names a gate-runnable file (`bin/pipeline-test.sh` for T2; `bin/run-stage-test.sh` for T3 — both under `bin/*-test.sh`).
