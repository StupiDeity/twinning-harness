---
linear: ENG-180
date: 2026-06-12
topic: Make `decide --action approve --gate scope` self-sufficient (halt-clear + replay forward-transition)
---

# ENG-180 — Make `decide --action approve --gate scope` self-sufficient

> **For agentic workers:** Implement task-by-task in `depends_on` order. Steps use `- [ ]` checkboxes for tracking.

## 1. Goal

After a NOTABLE `scope-violation` halt, a single `bash bin/pipeline.sh decide ENG-N --action approve --gate scope` removes `pipeline:halted` and the next tick's scope-approval replay applies the forward stage transition (`implementing → ui` or `ui → reviewing`) cleanly, with no `_vh_protocol_violation` re-halt.

## 2. Assumption Inventory

Every fact below is verified at the cited `path:line` against this worktree (HEAD = `2edc025`, origin/main = `c6722bc`). Branch-base freshness: `git log --oneline HEAD..origin/main` empty at plan time (origin/main = `c6722bc`).

### Codebase facts (verified against current HEAD)

- `bin/pipeline.sh::cmd_decide` is defined at `bin/pipeline.sh:472` with signature `cmd_decide() { local issue="${1:-}"; shift || true; ... }` — verified `bin/pipeline.sh:472`.
- The `continue`-only atomic-reset gate opens at `bin/pipeline.sh:503` (`if [[ "$action" == "continue" ]]; then`) and closes at `bin/pipeline.sh:555` (the trailing `fi`) — verified `bin/pipeline.sh:503, 555`.
- The continue-arm inline halt-clear is at `bin/pipeline.sh:523-525`:
  ```bash
  if bash "$SCRIPT_DIR/linear.sh" has-label "$issue" "pipeline:halted" 2>/dev/null; then
    bash "$SCRIPT_DIR/linear.sh" remove-label "$issue" "pipeline:halted"
  fi
  ```
  — verified `bin/pipeline.sh:523-525`.
- The continue-arm issue-id D-014 guard is at `bin/pipeline.sh:508-509`:
  ```bash
  [[ "$issue" =~ ^ENG-[0-9]+$ ]] \
    || die "decide: invalid issue id '$issue' (expected ENG-<digits>)"
  ```
  — verified `bin/pipeline.sh:508-509`.
- `_pipeline_clear_breaker` sibling helper definition is at `bin/pipeline.sh:452-460` — verified.
- The decision-comment write (post-arm-fall-through) is at `bin/pipeline.sh:574`: `bash "$SCRIPT_DIR/linear.sh" add-comment "$issue" "$body"` — verified `bin/pipeline.sh:574`.
- The dry-run fork on the decision-comment is at `bin/pipeline.sh:569-572` — verified.
- No symbol `_pipeline_clear_halt_label` exists anywhere in `bin/` — verified via `grep -rn "_pipeline_clear_halt_label" bin/` returns no rows. The helper is NEW.
- The scope-approval replay gate is at `bin/run-stage.sh:1612-1620`:
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
  — verified.
- `_replay_scope_approval` (the helper called when `skip_dispatch=1`) is defined at `bin/run-stage.sh:312-316`; it `rm -f`s `$(issue_dir <ident>)/usage-<stage>.json` and emits a `stage-start ... scope-approval-replay 0` metric — verified.
- The dispatch-id allocation block is gated on `(( ! skip_dispatch ))` at `bin/run-stage.sh:1671`; on the replay path `PIPELINE_DISPATCH_ID` stays unset — verified `bin/run-stage.sh:1671-1699`.
- The post-dispatch scope-check NOTABLE-approved branch fires at `bin/run-stage.sh:1967-1970` (`log "scope-check: notable approved by scope-approve decision; clearing state and proceeding"`) — verified.
- The post-completion comment fires at `bin/run-stage.sh:2266` (`post_completion_comment "$ident" "$stage"`) — verified.
- The stage-drift guard at `bin/run-stage.sh:2283-2292` short-circuits when `current_stage_label != dispatched_stage_label` — verified (`local dispatched_stage_label="stage:$stage_label_long"` at `bin/run-stage.sh:2283`; the guard's `exit 0` at `bin/run-stage.sh:2291`).
- `_post_dispatch_apply_halt "$ident" "$stage"` is called at `bin/run-stage.sh:2297` — verified.
- `vh_stage` resolution is at `bin/run-stage.sh:2304-2305`: `local vh_stage; vh_stage="${current_stage_label#stage:}"` — verified.
- `verdict_handler "$ident" "$vh_stage" || vh_rc=$?` is called at `bin/run-stage.sh:2314` — verified.
- `verdict-handler.sh` is sourced at `bin/run-stage.sh:38` (via `# shellcheck source=verdict-handler.sh` and `source "$SCRIPT_DIR/verdict-handler.sh"`) — verified by grep `^source.*verdict-handler` in `bin/run-stage.sh:38`.
- `_VH_FORWARD_TRANSITIONS` table at `bin/verdict-handler.sh:19-27` includes rows `implementing=ui` and `ui=reviewing` — verified.
- `_vh_lookup_forward()` is defined at `bin/verdict-handler.sh:40-43` (not in the `export -f` list at line 606 — it is in scope to `run-stage.sh::main` only because the whole file is `source`d). — verified.
- `apply_transition()` is defined at `bin/verdict-handler.sh:311-432`; the docstring at `bin/verdict-handler.sh:302-310` declares the 5 steps idempotent ("Each step is idempotent; resume_in_progress_transition can re-enter at any point and finish cleanly"); step 5 at `bin/verdict-handler.sh:430` is `bash "$_VH_SCRIPT_DIR/linear.sh" remove-label "$issue" "pipeline:halted" || true` — verified.
- `apply_transition` is in the exported set at `bin/verdict-handler.sh:606`: `export -f verdict_handler find_fresh_verdict find_fresh_wait_verdict apply_transition resume_in_progress_transition` — verified.
- `find_fresh_verdict`'s strict-id path at `bin/verdict-handler.sh:175-200` skips wait verdicts and requires a `<!-- meta: dispatch id=$_curr_id` marker on the comment body — verified. With `PIPELINE_DISPATCH_ID` unset on the replay (per the `(( ! skip_dispatch ))` gate above) the strict path returns empty.
- `find_fresh_verdict`'s legacy-fallback path at `bin/verdict-handler.sh:201-224` computes `last_transition_ts` from `event == "transition"` comments only (decision markers ignored) and filters verdicts older than the most recent transition — verified at `bin/verdict-handler.sh:206-211, 214-215`.
- `verdict_handler`'s empty-`find_fresh_verdict` branch routes through `_vh_classify_no_fresh_reason` then `_vh_protocol_violation` (`bin/verdict-handler.sh:52-64`), which `add-label "$issue" "pipeline:halted"` — verified `bin/verdict-handler.sh:58`.
- `bin/scope-check.sh::has_scope_approval` (`bin/scope-check.sh:217-259`) returns 0 iff a `<!-- pipeline: decision action=approve gate=scope -->` marker is newer than the most recent `verdict result=halt reason=scope-violation` marker — verified.
- `bin/poll.sh::_poll_classify_labels` at `bin/poll.sh:289-314` classifies `pipeline:halted` (no fresh non-halt marker) as `slot:"vacate", advanceable:false, operator_action_required:true` — verified.
- `pipeline-events.json::decision_gates` registers exactly `["scope", "build-cap"]` — verified `bin/pipeline-events.json:46-49`.
- The NOTABLE halt comment body at `bin/run-stage.sh:1985-1986` advertises `bash %s/bin/pipeline.sh decide %s --action approve --gate scope` — verified.
- `failure_outcome_for_exit 22` returns `pr-opened-too-early` — verified `bin/common.sh:322`. (Documented caveat: D-002's defensive unknown-forward branch reuses exit 22; that branch is unreachable in current control flow because the scope-approval gate at `bin/run-stage.sh:1613` restricts to `stage in (implementing, ui)`, both of which have rows in `_VH_FORWARD_TRANSITIONS`.)
- `_replay_scope_approval` runs at `bin/run-stage.sh:1935` (else-arm of the dispatch-vs-replay if) — verified.

### Existing test fixtures (verified)

- `bin/pipeline-test.sh::PR-E` (`bin/pipeline-test.sh:258-276`) asserts the continue-arm atomic reset removes `pipeline:halted` (`grep -c "^remove-label ENG-5801 pipeline:halted$"` ≥ 1). This is the continue-arm regression guard the refactor must keep green.
- `bin/pipeline-test.sh::PD2` at line `bin/pipeline-test.sh:141-142` covers `decide ENG-PD2 --action approve --gate scope` dry-run body emission. Pre-ENG-180 it does NOT exercise the live-path halt-clear (the dry-run arm returns before any halt-clear code runs); after ENG-180 it still passes (D-001's new branch sits inside the live-path block which is dry-run-suppressed).
- `bin/pipeline-test.sh::PD4` at `bin/pipeline-test.sh:149-150` covers "approve without --gate → rejected" — unchanged by ENG-180.
- `bin/pipeline-test.sh::PD6` at `bin/pipeline-test.sh:156-158` covers "bogus gate rejected" — unchanged.
- `bin/run-stage-test.sh` case-24 (`bin/run-stage-test.sh:649-691`) drives `_replay_scope_approval` directly and asserts (a) the usage-file is gone and (b) the metrics call carries no `--`-prefixed cost flags. D-002's new metrics-end-row inherits the same no-cost-flags property (the empty `cost_flags` array on the replay path is unchanged).
- `bin/verdict-handler-test.sh` case-12 (`bin/verdict-handler-test.sh:413-434`) asserts `find_fresh_verdict` ignores `decision` markers (scope-approve newer than scope-violation halt → fresh marker stays `pipeline-halt`). D-002 short-circuits the verdict-handler call site on replay, so case-12's premise (verdict_handler runs on replay) no longer holds for the replay path. The verdict-handler contract under case-12 is unchanged; the test is recast as a regression guard for the contract itself (one-line comment edit).
- `bin/scope-check-test.sh::has_scope_approval` cases (around `bin/scope-check-test.sh:526-545`) are unchanged — D-002 does not modify the helper.

### Test-gate closure sweep (removal side)

Tokens this plan REMOVES from production code:
- The inline `if bash "$SCRIPT_DIR/linear.sh" has-label ... ; then bash "$SCRIPT_DIR/linear.sh" remove-label ... ; fi` block at `bin/pipeline.sh:523-525` (replaced by a call to the new `_pipeline_clear_halt_label` helper).

Grep across all `bin/*-test.sh` for token coupling:
- `bin/pipeline-test.sh` asserts on `remove-label ENG-5801 pipeline:halted` (PR-E at line 266) and similar siblings (PR-N at 325 captures a metric line, not the literal). The refactor preserves the EXACT same `add-comment` / `remove-label` argv shape because the helper just wraps the same two `bash "$SCRIPT_DIR/linear.sh"` calls — capture-file assertions continue to match. No File Structure addition needed for `bin/pipeline-test.sh` beyond the new DEC-APPROVE-SCOPE-* fixtures.
- No other `bin/*-test.sh` greps on the inline-block byte sequence; the refactor is mechanical.

### Test-gate closure sweep (add side)

This plan adds NO new files under any gate-runnable glob. All new fixtures are added in-place to existing `bin/pipeline-test.sh` and `bin/run-stage-test.sh`, both already listed in `learned-rules/harness/project-profile.md::## Build & test gates` (the gate command line). Therefore `learned-rules/harness/project-profile.md` is NOT modified by this plan — verified by reading the profile's Test command, which already runs `bin/pipeline-test.sh` (implicit via the suite — confirmed by inspecting the gate command at `learned-rules/harness/project-profile.md::## Build & test gates`).

### Branch-base freshness

`git log --oneline HEAD..origin/main` empty at plan time (origin/main = `c6722bc7b147cca2a9611d560332211cd845d021`); HEAD = `2edc0257fbfa5bbd49a221ed61a9520ac8b24491 chore(pipeline): brainstorming for ENG-180`. No Task 0 rebase required.

## 3. System invariants

- `pipeline:halted` is the canonical "no agent compute will run" flag — `poll.sh::_poll_classify_labels` classifies the slot as `vacate, operator_action_required:true` whenever the label is present (regardless of `decision` markers). `verified_by: bin/poll-slot-test.sh:AC-2` (the "halt-for-human vacates slot" case at `bin/poll-slot-test.sh:258`).
- `find_fresh_verdict` only surfaces `event=="verdict"` comments newer than the most recent transition (legacy path) OR carrying the current `dispatch_id` marker (strict path); `decision` markers are ignored by both code paths. `verified_by: bin/verdict-handler-test.sh:case-12`.
- `apply_transition` is idempotent across all 5 steps and re-entry via `resume_in_progress_transition` completes cleanly. `verified_by: bin/verdict-handler-test.sh:case-9` (the "resume-in-progress-transition" case at `bin/verdict-handler-test.sh:347`, which asserts step-5 `remove pipeline:halted` is idempotently completed after a partial-failure crash mid-transition). D-002's replay-side idempotency is additionally covered by `task:T4` (SCO-REPLAY-IDEMPOTENT).
- The scope-approval replay path (`bin/run-stage.sh:1671`'s `(( ! skip_dispatch ))` gate) intentionally does NOT allocate `PIPELINE_DISPATCH_ID`; the replay must NEVER post agent-lane Linear comments, only orchestrator-lane ones. `verified_by: task:T3` (SCO-REPLAY-FORWARD-1 asserts `apply_transition`'s transition waypoint is posted via the orchestrator-lane chokepoint, with no `PIPELINE_DISPATCH_ID` envelope violation).
- `_replay_scope_approval` always runs BEFORE any post-stage scope-check / completion code, removing `usage-<stage>.json` so the replay-path metrics call cannot carry stale cost fields (D-011). `verified_by: bin/run-stage-test.sh:case-24`.
- The NOTABLE scope-violation halt-comment body's "To approve and resume" text (`bin/run-stage.sh:1985-1986`) MUST stay accurate post-ENG-180: a single `decide --action approve --gate scope` resumes the issue without further operator action. `verified_by: task:T1` (DEC-APPROVE-SCOPE-1 asserts halt-clear fires from approve-arm; combined with task:T3 the full advertised path is exercised end-to-end).
- The `cmd_decide` "decision comment writes LAST" ordering is load-bearing for partial-failure recoverability: halt-clear precedes decision-comment so a mid-call API failure leaves either both-effects-not-yet-fired or halt-cleared-but-no-marker (both re-runnable). `verified_by: task:T1` (DEC-APPROVE-SCOPE-1 asserts the capture-file's `remove-label` line precedes the `add-comment` line).

## 4. File Structure

Modify (production):
- `bin/pipeline.sh` — add `_pipeline_clear_halt_label <issue>` helper (sibling to `_pipeline_clear_breaker`, ~6 lines); refactor the continue-arm inline halt-clear at `bin/pipeline.sh:523-525` to call the helper (mechanical, no behaviour change); add a new branch in `cmd_decide` AFTER the existing continue gate closes at `bin/pipeline.sh:555` and BEFORE the schema-validation block at `bin/pipeline.sh:557-561` that runs `_pipeline_clear_halt_label "$issue"` iff `action == approve && gate == scope`. Decision-comment write at `bin/pipeline.sh:574` is unchanged.
- `bin/run-stage.sh` — insert a `(( skip_dispatch ))` early-exit branch BETWEEN the stage-drift guard at `bin/run-stage.sh:2283-2292` and `_post_dispatch_apply_halt` at `bin/run-stage.sh:2297`. The new block resolves the forward stage via `_vh_lookup_forward "$vh_stage"`, calls `apply_transition "$ident" "$vh_stage" "$_fwd" ""`, emits the success metric end-row with `verdict=transitioned scope-approval-replay=1`, logs `stage $stage complete for $ident (scope-approval-replay transitioned $vh_stage → $_fwd)`, and `exit 0`. Both `_vh_lookup_forward` and `apply_transition` are in scope via the existing `source "$SCRIPT_DIR/verdict-handler.sh"` at `bin/run-stage.sh:38`. NOTE: `vh_stage` is defined at line 2304 (AFTER the stage-drift guard, BEFORE `_post_dispatch_apply_halt`). The new branch reorders one line — `vh_stage` resolution must move UP to immediately AFTER the stage-drift guard so it is in scope at the new branch's call site. See Task 2 Step 2 for the content-anchored relocation.

Modify (tests):
- `bin/pipeline-test.sh` — append five new fixtures after the existing decide-section (DEC-APPROVE-SCOPE-1 through DEC-APPROVE-SCOPE-5) plus the implicit PR-E regression guard (PR-E already exists at lines 258-276 and continues to assert continue-arm halt-clear; no changes needed). New fixtures live in the `_AR_*` live-path test region (after the `_AR_STUB_DIR` setup at ~line 234) so they reuse the existing `_AR_LINEAR_CALLS` capture, `_ar_decide` invoker, and `LABELS_ON` / `STAGE_OF` env-stub mechanism.
- `bin/run-stage-test.sh` — append SCO-REPLAY-FORWARD-1 (implementing → ui), SCO-REPLAY-FORWARD-2 (ui → reviewing), SCO-REPLAY-DEFENSIVE (unknown-forward → halt), SCO-REPLAY-STAGE-DRIFT (operator transitioned mid-replay), SCO-REPLAY-IDEMPOTENT (re-entry after partial-failure), and SCO-REPLAY-CONTINUE-COMPOSITE (continue after a prior approve resolves). Place after case-24 (`bin/run-stage-test.sh:649-691`) and before the next existing case block. Case-24 itself is UNCHANGED (still asserts no cost flags; D-002's metric end-row inherits this).
- `bin/verdict-handler-test.sh` — one-line comment edit on case-12 (`bin/verdict-handler-test.sh:413-434`) clarifying that the case is a regression guard for `find_fresh_verdict`'s verdict-vs-decision contract, NOT an end-to-end assertion on the scope-approval replay (D-002 short-circuits the call site upstream).

Modify (docs):
- `CLAUDE.md` — add a row to the "Failure-mode quick reference" table at `CLAUDE.md:803-820` describing the pre-ENG-180 "approved but stuck" symptom, the post-ENG-180 expected log lines, and the legacy force-apply escape hatch (kept as historical only). Inserted after the existing "Issue at `stage:building` idles with `dispatch-skipped`" row (~line 817) and before the existing "Concurrent dispatches not running" row.

No new files; no new exit codes; no new ADR.

## 5. API Contract

No new API surface. The harness has no FE↔BE contract; the only "API" affected is `bin/pipeline.sh::cmd_decide`'s argv shape, which is unchanged (`--action approve --gate scope` was already registered in `pipeline-events.json::decision_gates` and was already a valid invocation pre-ENG-180; only its in-process side-effects are widened).

## 6. Backend Tasks

### Task 1: Add `_pipeline_clear_halt_label` helper and wire approve-arm halt-clear

- `depends_on: []`
- `touches: bin/pipeline.sh::_pipeline_clear_halt_label (new), bin/pipeline.sh::cmd_decide`

- [ ] **Step 1:** In `bin/pipeline.sh`, locate the function `_pipeline_clear_breaker` (content anchor: the comment header line `# ... breaker on the same tick, so resume needed two operator commands. The` immediately above `_pipeline_clear_breaker() {` at `bin/pipeline.sh:452`). Insert a new helper IMMEDIATELY AFTER `_pipeline_clear_breaker`'s closing `}` (content anchor: the line `}` at `bin/pipeline.sh:460`) and BEFORE the next function's header comment (content anchor: `# _pipeline_emit_resume_metric <issue> <stage> <wf> <sl> <sf> <waypoint_posted> [<breaker_was_paused>] [<auto_commit_count>]` at `bin/pipeline.sh:462`). New code:

  ```bash
  # ENG-180 D-001: factor the continue-arm's inline halt-clear into a
  # callable helper so the approve --gate scope arm can reuse it without
  # duplicating the has-label / remove-label pair. linear.sh remove-label
  # is a no-op on a missing label, so the has-label guard is a log-noise
  # optimisation (mirrors the continue-arm's pre-existing shape; behaviour
  # unchanged).
  _pipeline_clear_halt_label() {
    local issue="$1"
    if bash "$SCRIPT_DIR/linear.sh" has-label "$issue" "pipeline:halted" 2>/dev/null; then
      bash "$SCRIPT_DIR/linear.sh" remove-label "$issue" "pipeline:halted"
    fi
  }
  ```

- [ ] **Step 2:** Refactor the continue-arm's inline halt-clear. Locate the three-line block at `bin/pipeline.sh:523-525` (content anchor: the leading comment `# Remove halt label if present (mirrors halt.sh rc=1 branch behavior).` at `bin/pipeline.sh:522`, and the immediately-following `if bash "$SCRIPT_DIR/linear.sh" has-label "$issue" "pipeline:halted" 2>/dev/null; then` line). Replace the three lines `if bash "$SCRIPT_DIR/linear.sh" has-label "$issue" "pipeline:halted" 2>/dev/null; then` / `  bash "$SCRIPT_DIR/linear.sh" remove-label "$issue" "pipeline:halted"` / `fi` with a single call:

  ```bash
  _pipeline_clear_halt_label "$issue"
  ```

  Keep the leading comment at `bin/pipeline.sh:522` (`# Remove halt label if present (mirrors halt.sh rc=1 branch behavior).`) intact — it now annotates the helper call.

- [ ] **Step 3:** Add the approve-arm halt-clear branch. Locate the closing `fi` of the continue gate at `bin/pipeline.sh:555` (content anchor: the line `fi` immediately preceded by `else log "pipeline-decide: $issue action=continue (dry-run — atomic reset suppressed)"` at `bin/pipeline.sh:553`). Locate the next block opener at `bin/pipeline.sh:557-558` (content anchor: the comment `# ENG-112: schema-driven validation + body render. The continue-rejects-gate` followed by `# exclusion above stays inline (D-002 in plan); schema is inclusion-only.`). Insert the new approve-arm branch BETWEEN the continue-gate's closing `fi` and the ENG-112 comment block:

  ```bash
  # ENG-180 D-001: approve --gate scope must clear pipeline:halted; otherwise
  # poll.sh::_poll_classify_labels keeps the slot vacated indefinitely and
  # the replay never runs (the halt comment's "To approve and resume" text
  # then becomes a lie). Scope is intentionally narrow: only the halt label,
  # not the full atomic reset — operators wanting the full reset still run
  # --action continue. Order is load-bearing: halt-clear precedes the
  # decision-comment write below so a mid-call API failure leaves the
  # invocation re-runnable in both partial-failure shapes (helper is
  # idempotent; decision-comment is append-only).
  if [[ "$action" == "approve" && "$gate" == "scope" ]]; then
    if [[ "${PIPELINE_DRY_RUN:-}" != "1" ]]; then
      # D-014: validate issue id BEFORE any linear.sh call to guard against
      # path-interpolation in the helper's stub-test path (mirrors the
      # continue arm's guard at L508-509).
      [[ "$issue" =~ ^ENG-[0-9]+$ ]] \
        || die "decide: invalid issue id '$issue' (expected ENG-<digits>)"
      _pipeline_clear_halt_label "$issue"
      log "pipeline-decide: $issue action=approve gate=scope (halt label cleared)"
    else
      log "pipeline-decide: $issue action=approve gate=scope (dry-run — halt-clear suppressed)"
    fi
  fi
  ```

  Rationale for each piece:
  - `action == "approve" && gate == "scope"`: narrows to the gate explicitly advertised by the halt-comment body at `bin/run-stage.sh:1985-1986`. The other registered gate `build-cap` (`bin/pipeline-events.json:48`) has no symmetric halt-shape need today.
  - The `PIPELINE_DRY_RUN` fork mirrors the continue arm's dry-run pattern at `bin/pipeline.sh:552-553`; both arms keep dry-run side-effect-free.
  - The `[[ $issue =~ ^ENG-[0-9]+$ ]]` guard echoes the continue-arm's D-014 sanitisation at `bin/pipeline.sh:508-509`; the helper itself does no path-interp but the guard is cheap and defends against future helper extensions.
  - `_pipeline_clear_halt_label` is idempotent: `has-label` returns 1 (false) on missing label, the `remove-label` line never runs, exit 0. Safe to call on issues with no halt label.

- [ ] **Step 4:** Syntax-check:
  ```bash
  bash -n bin/pipeline.sh
  ```
  Expect exit 0.

### Task 2: Insert the scope-approval-replay forward-transition early-exit

- `depends_on: []`
- `touches: bin/run-stage.sh::main (post-completion-comment region)`

- [ ] **Step 1:** In `bin/run-stage.sh`, locate the stage-drift guard (content anchor: the comment `# Stage-drift guard (ENG-41 §4.3): if the stage label changed during the` at `bin/run-stage.sh:2274`). Confirm its `exit 0` line is at `bin/run-stage.sh:2291` and its closing `fi` is at `bin/run-stage.sh:2292`. Confirm `_post_dispatch_apply_halt "$ident" "$stage"` is at `bin/run-stage.sh:2297` and `local vh_stage` is at `bin/run-stage.sh:2304`.

- [ ] **Step 2:** Hoist the `vh_stage` resolution above `_post_dispatch_apply_halt`. Locate the block at `bin/run-stage.sh:2304-2305`:

  ```bash
  local vh_stage
  vh_stage="${current_stage_label#stage:}"
  ```

  Cut both lines. Reinsert them IMMEDIATELY AFTER the stage-drift guard's closing `fi` at `bin/run-stage.sh:2292` (content anchor: the closing `fi` preceded by `exit 0`) and BEFORE the `# Post-dispatch halt apply (ENG-56): orchestrator is the canonical applier` comment at `bin/run-stage.sh:2294`. After this move, the source lines read:

  ```bash
    fi                                        # closing fi of stage-drift guard
                                              # (blank line)
    # Resolve vh_stage (long-form) for both the ENG-180 scope-approval
    # replay forward-transition branch below AND the existing
    # verdict_handler call after _post_dispatch_apply_halt. Hoisted out
    # of the legacy post-_post_dispatch_apply_halt position to make
    # vh_stage in-scope for the new branch.
    local vh_stage
    vh_stage="${current_stage_label#stage:}"
                                              # (blank line)
    # Post-dispatch halt apply (ENG-56): orchestrator is the canonical applier
    # ...
  ```

  Also DELETE the original `local vh_stage` / `vh_stage="${current_stage_label#stage:}"` lines at the legacy position (the move leaves only one definition; the original comment "Resolve the current stage from the Linear label (long form) rather than ..." at `bin/run-stage.sh:2299-2303` can stay as legacy context above the now-relocated definition's old slot, but since the variable is gone from that slot, prune those four comment lines along with the `vh_stage` block — they read as orphan otherwise).

- [ ] **Step 3:** Insert the D-002 early-exit branch. Locate the new `vh_stage` block from Step 2 (content anchor: the line `vh_stage="${current_stage_label#stage:}"`). Insert AFTER that line and BEFORE the `# Post-dispatch halt apply (ENG-56)` comment:

  ```bash
  # ENG-180 D-002: scope-approval replay applies the forward transition
  # directly. The replay deliberately skipped the agent dispatch (no
  # fresh verdict marker is emitted), so verdict_handler's
  # find_fresh_verdict would return empty and _vh_protocol_violation
  # would re-halt. The source stage's prior clean pass already earned
  # the transition; emit it here. Runs after post_completion_comment so
  # the orchestrator's narrative post still lands; runs before
  # _post_dispatch_apply_halt so the halt label is not re-applied; runs
  # before verdict_handler so the protocol-violation path is not entered.
  # apply_transition's step 5 (remove pipeline:halted) is idempotent
  # against D-001's prior clear.
  if (( skip_dispatch )); then
    local _fwd
    _fwd="$(_vh_lookup_forward "$vh_stage")"
    if [[ -z "$_fwd" ]]; then
      # Defensive — unreachable in current control flow: the scope-approval
      # gate at L1613 restricts to (implementing, ui), both of which have
      # rows in _VH_FORWARD_TRANSITIONS (verdict-handler.sh:19-27). A
      # future stage that joins the gate without a forward row falls here.
      # Exit 22 (pr-opened-too-early) is reused for the metric label; the
      # halt comment's text makes the actual cause recoverable. A
      # dedicated exit code is follow-up scope.
      classify_failure "$ident" "$stage" "skip-until-human-acts" \
        "scope-approval-replay: no forward transition from $vh_stage" 22
      exit 22
    fi
    apply_transition "$ident" "$vh_stage" "$_fwd" ""
    t1="$(date +%s)"; duration=$(( (t1 - t0) * 1000 ))
    bash "$SCRIPT_DIR/metrics.sh" stage-end "$ident" "$stage" "success" "$duration" \
      "verdict=transitioned scope-approval-replay=1" || true
    log "stage $stage complete for $ident (scope-approval-replay transitioned $vh_stage → $_fwd)"
    exit 0
  fi
  ```

  Rationale for each piece:
  - `(( skip_dispatch ))`: the replay flag was set at `bin/run-stage.sh:1618` (single source of truth). The branch fires for both `implementing` and `ui` stages by the gate at `bin/run-stage.sh:1613`.
  - `_vh_lookup_forward`: in scope via `source "$SCRIPT_DIR/verdict-handler.sh"` at `bin/run-stage.sh:38`. Not in the exported set at line 606, but the source line makes the underscore-prefixed helper callable from the same shell.
  - `apply_transition "$ident" "$vh_stage" "$_fwd" ""`: the empty 4th arg is `side_labels`, matching the forward-transition row in `_VH_FORWARD_TRANSITIONS` (no side labels for forward transitions). The 5th arg `post_waypoint` defaults to `1` (`bin/verdict-handler.sh:313`), so the `<!-- pipeline: transition from=X to=Y -->` waypoint is posted by `apply_transition` step 1. The PR-create hook (`bin/verdict-handler.sh:343-410`) fires idempotently when `to == "reviewing"` (ui→reviewing case).
  - Metric end-row: `verdict=transitioned scope-approval-replay=1` mirrors `case-24`'s assertion shape; the cost-flags array on the replay path is empty by construction (`_replay_scope_approval` rm'd the usage file at `bin/run-stage.sh:314`), so no `--`-prefixed cost flags are appended.
  - `exit 0`: matches the success-path semantics of the legacy `vh_rc==0` arm at `bin/run-stage.sh:2343-2346`. The dispatch_history.jsonl pairing invariant is preserved — the start-row was never written (gated on `(( ! skip_dispatch ))` at `bin/run-stage.sh:1671`), so the EXIT trap (also gated on the same flag in `_append_dispatch_end_row`) does not emit an end-row.

- [ ] **Step 4:** Syntax-check:
  ```bash
  bash -n bin/run-stage.sh
  ```
  Expect exit 0.

### Task 3: Add `bin/pipeline-test.sh` fixtures for approve-arm halt-clear

- `depends_on: [1]`
- `touches: bin/pipeline-test.sh`

- [ ] **Step 1:** In `bin/pipeline-test.sh`, locate the `_AR_*` live-path test region's last existing case (content anchor: the section header `printf '\n--- bin/pipeline.sh: decide continue → ENG-58 atomic reset ---\n'` at ~`bin/pipeline-test.sh:176`, and the PR-N case at `bin/pipeline-test.sh:320-339`). The new approve-arm fixtures need the same `_AR_STUB_DIR` / `_AR_LINEAR_CALLS` machinery already set up by lines 178-237. Insert a new section header AFTER the LAST existing PR-* fixture's `_ar_clear` line (content anchor: scan downward from line 320 for the last `_ar_clear "ENG-58<N>"` line before any non-PR test section; insert the new section there). Use the section header:

  ```bash
  printf '\n--- bin/pipeline.sh: decide approve --gate scope → ENG-180 halt-clear ---\n'
  ```

- [ ] **Step 2:** Add DEC-APPROVE-SCOPE-1 (halt-clear fires when halt label is present):

  ```bash
  # DEC-APPROVE-SCOPE-1: approve --gate scope clears pipeline:halted.
  # The capture file must contain a `remove-label ENG-T-APP1 pipeline:halted`
  # line AND that line must precede the `add-comment ... decision ... -->`
  # line (load-bearing order — halt-clear before decision comment).
  : > "$_AR_LINEAR_CALLS"
  LABELS_ON="pipeline:halted" STAGE_OF="stage:implementing" \
    _ar_decide "ENG-T-APP1" --action approve --gate scope || true
  remove_line_no="$(grep -n "^remove-label ENG-T-APP1 pipeline:halted$" "$_AR_LINEAR_CALLS" | head -1 | cut -d: -f1)"
  comment_line_no="$(grep -n "^add-comment ENG-T-APP1 .*decision action=approve gate=scope" "$_AR_LINEAR_CALLS" | head -1 | cut -d: -f1)"
  if [[ -n "$remove_line_no" && -n "$comment_line_no" && "$remove_line_no" -lt "$comment_line_no" ]]; then
    pass_at "DEC-APPROVE-SCOPE-1: approve --gate scope clears halt before decision comment"
  else
    fail_at "DEC-APPROVE-SCOPE-1: approve --gate scope" \
      "remove_line=$remove_line_no comment_line=$comment_line_no calls=$(cat "$_AR_LINEAR_CALLS")"
  fi
  ```

- [ ] **Step 3:** Add DEC-APPROVE-SCOPE-2 (idempotent when no halt label):

  ```bash
  # DEC-APPROVE-SCOPE-2: idempotent — no halt label present means
  # has-label returns 1, remove-label is NEVER called, decision-comment
  # still posts.
  : > "$_AR_LINEAR_CALLS"
  LABELS_ON="" STAGE_OF="stage:implementing" \
    _ar_decide "ENG-T-APP2" --action approve --gate scope || true
  remove_count="$(grep -c "^remove-label ENG-T-APP2 pipeline:halted$" "$_AR_LINEAR_CALLS" || true)"
  comment_count="$(grep -c "^add-comment ENG-T-APP2 .*decision action=approve gate=scope" "$_AR_LINEAR_CALLS" || true)"
  if [[ "$remove_count" == "0" && "$comment_count" -ge "1" ]]; then
    pass_at "DEC-APPROVE-SCOPE-2: approve --gate scope idempotent on missing halt label"
  else
    fail_at "DEC-APPROVE-SCOPE-2" \
      "remove_count=$remove_count comment_count=$comment_count calls=$(cat "$_AR_LINEAR_CALLS")"
  fi
  ```

- [ ] **Step 4:** Add DEC-APPROVE-SCOPE-3 (other gates unaffected):

  ```bash
  # DEC-APPROVE-SCOPE-3: --gate build-cap does NOT clear halt (scoped
  # narrowly to --gate scope per brainstorm §D-001).
  : > "$_AR_LINEAR_CALLS"
  LABELS_ON="pipeline:halted" STAGE_OF="stage:building" \
    _ar_decide "ENG-T-APP3" --action approve --gate build-cap || true
  remove_count="$(grep -c "^remove-label ENG-T-APP3 pipeline:halted$" "$_AR_LINEAR_CALLS" || true)"
  comment_count="$(grep -c "^add-comment ENG-T-APP3 .*decision action=approve gate=build-cap" "$_AR_LINEAR_CALLS" || true)"
  if [[ "$remove_count" == "0" && "$comment_count" -ge "1" ]]; then
    pass_at "DEC-APPROVE-SCOPE-3: approve --gate build-cap does NOT clear halt"
  else
    fail_at "DEC-APPROVE-SCOPE-3" \
      "remove_count=$remove_count comment_count=$comment_count calls=$(cat "$_AR_LINEAR_CALLS")"
  fi
  ```

- [ ] **Step 5:** Add DEC-APPROVE-SCOPE-4 (dry-run suppresses halt-clear). This fixture uses the EARLIER dry-run-only `run_pipe` helper (`bin/pipeline-test.sh:50-53`) rather than the live-path `_ar_decide`, because dry-run mode is verified by checking the printed stderr/stdout, not the capture file:

  ```bash
  # DEC-APPROVE-SCOPE-4: PIPELINE_DRY_RUN=1 suppresses halt-clear AND
  # the decision-comment write; both ride the same dry-run log
  # printf path.
  out="$(run_pipe decide ENG-T-APP4 --action approve --gate scope 2>&1)"
  if [[ "$out" == *"action=approve gate=scope (dry-run — halt-clear suppressed)"* ]] \
     && [[ "$out" == *"would post on ENG-T-APP4"* ]]; then
    pass_at "DEC-APPROVE-SCOPE-4: dry-run suppresses halt-clear"
  else
    fail_at "DEC-APPROVE-SCOPE-4" "out=$out"
  fi
  ```

- [ ] **Step 6:** Add DEC-APPROVE-SCOPE-5 (invalid issue id dies):

  ```bash
  # DEC-APPROVE-SCOPE-5: D-014 issue-id guard dies BEFORE any
  # linear.sh call; mirrors continue-arm's guard at L508-509.
  : > "$_AR_LINEAR_CALLS"
  rc=0
  LABELS_ON="pipeline:halted" STAGE_OF="stage:implementing" \
    _ar_decide "INVALID-ID" --action approve --gate scope 2>/dev/null || rc=$?
  call_count="$(wc -l < "$_AR_LINEAR_CALLS" | tr -d ' ')"
  if [[ "$rc" -ne 0 && "$call_count" == "0" ]]; then
    pass_at "DEC-APPROVE-SCOPE-5: invalid issue id dies before linear.sh call"
  else
    fail_at "DEC-APPROVE-SCOPE-5" "rc=$rc call_count=$call_count"
  fi
  ```

- [ ] **Step 7:** Syntax-check:
  ```bash
  bash -n bin/pipeline-test.sh
  ```
  Expect exit 0.

### Task 4: Add `bin/run-stage-test.sh` fixtures for scope-approval replay forward-transition

- `depends_on: [2]`
- `touches: bin/run-stage-test.sh`

- [ ] **Step 1:** In `bin/run-stage-test.sh`, locate the closing of case-24 (content anchor: the `fail_at "case-24 D-011 replay" ...` block at `bin/run-stage-test.sh:689-691`, terminated by the next case header `# ─── Case 25: _cost_flags_for tolerates corrupt JSON (review blocker 1) ──` at `bin/run-stage-test.sh:693`). Insert the new SCO-REPLAY-* block AFTER case-24's closing `fi` and BEFORE case-25's section header.

- [ ] **Step 2:** Add SCO-REPLAY-FORWARD-1 (implementing → ui). The test drives `bin/run-stage.sh::main` end-to-end against a stubbed environment: stubs `scope-check.sh` (returns rc=1 plus `has-scope-approval` rc=0), `linear.sh` (stage-of returns `stage:implementing`; capture every write), `metrics.sh` (capture every write). The sentinel file `$(issue_dir ENG-T-SR1)/scope-approval` is pre-created so the replay gate at `bin/run-stage.sh:1612-1620` fires.

  ```bash
  # ─── ENG-180 SCO-REPLAY-FORWARD-1 (implementing → ui via apply_transition) ─
  # Drives the full bin/run-stage.sh::main path under PIPELINE_DRY_RUN=0 with
  # stubbed claude / linear / scope-check / metrics. Asserts:
  #   (a) apply_transition's transition-waypoint comment was posted with
  #       from=implementing to=ui shape.
  #   (b) stage:ui label was added; stage:implementing was removed.
  #   (c) metrics.sh stage-end was called with success + scope-approval-replay=1.
  #   (d) _post_dispatch_apply_halt was NOT reached (no extra add-label
  #       pipeline:halted line beyond apply_transition's step-5 remove).
  #   (e) verdict_handler was NOT reached (no protocol-violation comment).
  printf '\n--- ENG-180 SCO-REPLAY-FORWARD-1: implementing → ui ---\n'
  # [seed sentinel, stub scope-check.sh / linear.sh / metrics.sh / claude,
  #  invoke bash bin/run-stage.sh ENG-T-SR1 implementing, scan captures]
  # (Implementation detail: reuse the existing case-24 stubbing pattern
  #  for metrics.sh capture; extend with linear.sh + scope-check.sh stubs
  #  mirroring the _AR_* shape from bin/pipeline-test.sh. Full literal
  #  source omitted from this plan to keep it under ~5 functions per task;
  #  the agent reuses the case-24 idiom plus bin/pipeline-test.sh's
  #  _AR_STUB_DIR / _AR_LINEAR_CALLS pattern.)
  ```

  Fixture structure: pre-create `$(issue_dir ENG-T-SR1)/scope-approval`; PATH-prepend a stub dir whose `linear.sh` echoes invocations to `$SR_LINEAR_CALLS` and whose `stage-of` returns `stage:implementing`; whose `scope-check.sh` returns rc=1 + has-scope-approval rc=0; whose `metrics.sh` captures argv; invoke `bash "$SCRIPT_DIR/run-stage.sh" ENG-T-SR1 implementing`; assert:
  - `grep -q "^add-comment ENG-T-SR1 .*transition from=implementing to=ui" "$SR_LINEAR_CALLS"`
  - `grep -q "^add-label ENG-T-SR1 stage:ui$" "$SR_LINEAR_CALLS"`
  - `grep -q "^remove-label ENG-T-SR1 stage:implementing$" "$SR_LINEAR_CALLS"`
  - `grep -q "^stage-end ENG-T-SR1 implementing success .*scope-approval-replay=1" "$SR_METRICS_CALLS"`
  - `! grep -q "verdict result=halt reason=protocol-violation" "$SR_LINEAR_CALLS"`

- [ ] **Step 3:** Add SCO-REPLAY-FORWARD-2 (ui → reviewing). Mirror SCO-REPLAY-FORWARD-1 with `stage-of` returning `stage:ui` and the dispatched stage argument `ui`. Add a `gh` stub (under `$SR_STUB_DIR/gh`) that captures invocations to `$SR_GH_CALLS` and returns 0. Assert transition is `ui → reviewing`; the PR-create hook fires (`grep -q "^pr create --head .* --title 'fix\\(eng-t-sr2\\)" "$SR_GH_CALLS"` — verify a `pr create` capture line exists with a properly-cased title scope); add-label is `stage:reviewing`; remove-label is `stage:ui`. The `gh pr create` assertion guards AC #6 (PR-create idempotency); without it, a future refactor that drops the hook on the replay path would regress silently.

- [ ] **Step 4:** Add SCO-REPLAY-DEFENSIVE (unknown forward → halt). Override the in-process `_vh_lookup_forward` by sourcing a stub before invoking — the simplest path is to use a stub `verdict-handler.sh` (under the test's STUB_DIR) whose `_vh_lookup_forward` returns empty. Assert exit code 22 and a `classify_failure ... skip-until-human-acts` capture line.

- [ ] **Step 5:** Add SCO-REPLAY-STAGE-DRIFT (operator transitioned mid-replay). Stub `linear.sh stage-of` to return `stage:reviewing` while the dispatched stage is `implementing`. Assert the stage-drift guard's `exit 0` fires BEFORE the D-002 branch (no `apply_transition` capture line; metric end-row outcome is `stage-drift`, not `success`).

- [ ] **Step 6:** Add SCO-REPLAY-IDEMPOTENT (re-entry after partial-failure). Run the SCO-REPLAY-FORWARD-1 fixture TWICE in sequence; on the second run the issue is already at `stage:ui` (per the first run's apply_transition) so the dispatched-stage `implementing` no longer matches `stage-of` → stage-drift guard fires on the second run. Acceptable; this asserts apply_transition's idempotent re-entry is structurally invisible (no double-transition, no duplicate stage:ui label add beyond what add-label idempotency permits).

- [ ] **Step 7:** Add SCO-REPLAY-CONTINUE-COMPOSITE (continue after a prior approve resolves). Two-stage fixture: (a) seed sentinel + decision approve comment + halt label, run `_ar_decide ENG-T-COMP --action continue` (from `bin/pipeline-test.sh`'s machinery, copied to the run-stage-test.sh stub dir or invoked via subprocess), assert halt cleared + operator-resume transition waypoint posted; (b) invoke `bash bin/run-stage.sh ENG-T-COMP implementing`, assert the SCO-REPLAY-FORWARD-1 success captures. Drives AC #5.

- [ ] **Step 8:** Syntax-check:
  ```bash
  bash -n bin/run-stage-test.sh
  ```
  Expect exit 0.

### Task 5: Recast `bin/verdict-handler-test.sh` case-12 as a contract regression guard

- `depends_on: []`
- `touches: bin/verdict-handler-test.sh`

- [ ] **Step 1:** In `bin/verdict-handler-test.sh`, locate case-12 (content anchor: the comment header `# ─── Case 12: decide-continue-posts-decision-and-clears-halt ─────────` at `bin/verdict-handler-test.sh:413`). The case body (lines 414-434) is structurally unchanged; only the docstring is updated.

- [ ] **Step 2:** Replace the docstring block at `bin/verdict-handler-test.sh:414-420`:

  ```
  # After `bin/pipeline.sh decide --action continue` posts a decision
  # comment newer than the scope-violation halt, the verdict handler still
  # sees the halt marker as the most recent verdict-shape marker, so rc
  # stays 1. decide itself is the actor that removes pipeline:halted —
  # not verdict_handler. What this case asserts is that find_fresh_verdict
  # IGNORES decision-event markers
  # comments (they're not a verdict shape).
  ```

  with:

  ```
  # ENG-180 (recast): regression guard for find_fresh_verdict's contract —
  # decision-event markers are NEVER surfaced as a fresh verdict, regardless
  # of the timestamp window. After ENG-180 D-002 the scope-approval replay
  # path no longer reaches verdict_handler at all (the new branch in
  # bin/run-stage.sh::main short-circuits before _post_dispatch_apply_halt
  # and verdict_handler), so this case no longer covers the end-to-end
  # "approve clears halt" flow. The verdict-handler internal contract
  # (find_fresh_verdict ignores `event == decision`) is still load-bearing
  # for find_fresh_wait_verdict and for any future caller, so the assertion
  # stays as a pure contract guard.
  ```

- [ ] **Step 3:** No other lines in case-12 are modified. Run the test file:
  ```bash
  bash bin/verdict-handler-test.sh
  ```
  Expect case-12 to PASS unchanged.

### Task 6: Document the new "approved but stuck (pre-ENG-180)" failure-mode row in CLAUDE.md

- `depends_on: [1, 2]`
- `touches: CLAUDE.md::## Failure-mode quick reference`

- [ ] **Step 1:** In `CLAUDE.md`, locate the "Failure-mode quick reference" table (content anchor: the H2 `## Failure-mode quick reference` at `CLAUDE.md:793`, and the row header `| Symptom | Where to look |` at `CLAUDE.md:803`). Identify the row immediately preceding the `| Concurrent dispatches not running (expected K=2, observed K=1) |` row (content anchor: the row starting `| Issue at \`stage:building\` idles with \`dispatch-skipped\` events and no halt label |` at ~CLAUDE.md:817).

- [ ] **Step 2:** Insert a new table row IMMEDIATELY AFTER the `dispatch-skipped` row and BEFORE the `Concurrent dispatches not running` row (preserve table structure — no blank line between rows):

  ```markdown
  | Issue at `stage:implementing` or `stage:ui` with `pipeline:halted` after a NOTABLE scope-violation halt; operator ran `bash bin/pipeline.sh decide <ENG-N> --action approve --gate scope` but the slot sits at `vacate, operator_action_required=true` for ≥ 1 tick | Pre-ENG-180 bug. Post-ENG-180: grep the per-stage transcript for the **terminal success line** `stage <stage> complete for <ENG-N> (scope-approval-replay transitioned <src> → <fwd>)` (e.g., `implementing → ui`). If that line is present the resume worked. Earlier-in-the-tick lines you will see: `scope-check: notable approved by scope-approve decision; clearing state and proceeding` (scope-check arm), and the `apply_transition` waypoint comment in Linear. **Pre-ENG-180 legacy symptom (host not yet updated):** the second-to-last log line was `post-dispatch: applying pipeline:halted (orchestrator-managed, ENG-56)` followed by `verdict-handler: protocol violation (no-marker): no fresh verdict marker on the issue (current_dispatch_id=<unset>)`. **Legacy recovery (pre-ENG-180 only):** source `bin/verdict-handler.sh` and run `apply_transition <ENG-N> implementing ui` (or `ui reviewing`); then `bash bin/linear.sh remove-label <ENG-N> pipeline:halted`. Post-ENG-180 this escape hatch is unnecessary. |
  ```

- [ ] **Step 3:** Verify the table renders correctly by counting `|` characters: each row has exactly 3 pipes (start, between, end). Verify no rows were displaced by a stray newline.

## 7. Frontend Tasks

No frontend tasks — harness has no UI. The harness is bash orchestration scripts only.

## 8. Failure Mode → Test Map

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
|---|---|---|---|---|
| `approve --gate scope` does not clear `pipeline:halted` (Layer 1) | NOTABLE scope-violation halt + operator runs `decide ENG-N --action approve --gate scope` | `pipeline:halted` removed; decision comment posted; halt-clear precedes decision-comment | integration | `bin/pipeline-test.sh::DEC-APPROVE-SCOPE-1` |
| Halt-clear runs against an already-clean issue | `decide --action approve --gate scope` on issue with no halt label | `remove-label` NOT called (has-label guard short-circuits); decision comment still posts | integration | `bin/pipeline-test.sh::DEC-APPROVE-SCOPE-2` |
| Halt-clear over-fires on `--gate build-cap` | `decide --action approve --gate build-cap` | `remove-label` NOT called; decision comment still posts | integration | `bin/pipeline-test.sh::DEC-APPROVE-SCOPE-3` |
| Halt-clear runs under dry-run | `PIPELINE_DRY_RUN=1 decide --action approve --gate scope` | `[DRY_RUN]` log line; NO `remove-label` call; NO `add-comment` call | integration | `bin/pipeline-test.sh::DEC-APPROVE-SCOPE-4` |
| Halt-clear with invalid issue id path-interp | `decide INVALID-ID --action approve --gate scope` | `die` BEFORE any `linear.sh` call | unit | `bin/pipeline-test.sh::DEC-APPROVE-SCOPE-5` |
| Scope-approval replay reaches `_vh_protocol_violation` (Layer 2) | Sentinel + decision marker + halt cleared → replay tick → no fresh `pass` verdict | New D-002 branch fires; `apply_transition implementing → ui` posts waypoint + label flip; no protocol-violation re-halt | integration | `bin/run-stage-test.sh::SCO-REPLAY-FORWARD-1` |
| Scope-approval replay on UI stage forwards to reviewing | Sentinel + decision marker + `stage:ui` label | `apply_transition ui → reviewing`; PR-create hook fires idempotently | integration | `bin/run-stage-test.sh::SCO-REPLAY-FORWARD-2` |
| Forward stage lookup returns empty (future stages joining the gate) | `_vh_lookup_forward` returns empty for the source stage | `classify_failure skip-until-human-acts`; exit 22 | unit | `bin/run-stage-test.sh::SCO-REPLAY-DEFENSIVE` |
| Operator manually transitioned mid-replay | `stage-of` returns a stage label different from the dispatched-stage label | Stage-drift guard's `exit 0` fires BEFORE D-002 branch; no `apply_transition` call | integration | `bin/run-stage-test.sh::SCO-REPLAY-STAGE-DRIFT` |
| Replay re-runs after partial-failure (apply_transition crashed mid-flight) | Two consecutive SCO-REPLAY-FORWARD-1 dispatches against the same fixture | Second run sees `stage:ui` from first run's apply_transition; stage-drift guard fires; no double-transition, no duplicate waypoint at the same `(from, to)` pair beyond Linear's append-only ledger | integration | `bin/run-stage-test.sh::SCO-REPLAY-IDEMPOTENT` |
| `continue` after a prior `approve --gate scope` (composite recovery) | Halt + decision-approve marker + sentinel; operator runs `--action continue`, then next tick's replay fires | `continue`'s atomic reset clears halt + posts operator-resume transition; next replay sees sentinel + has-scope-approval → D-002 transitions forward; no protocol-violation | integration | `bin/run-stage-test.sh::SCO-REPLAY-CONTINUE-COMPOSITE` |
| `find_fresh_verdict` regression: someone makes `decision` markers visible | Test fixture posts `decision action=approve gate=scope` newer than scope-violation halt | `find_fresh_verdict` returns marker shape `pipeline-halt` (NOT a decision-shape marker) | unit | `bin/verdict-handler-test.sh::case-12` (recast as contract guard) |
| Continue-arm regression: refactor breaks the inline halt-clear | `--action continue` on a halted issue | `remove-label pipeline:halted` capture line ≥ 1 (existing assertion) | integration | `bin/pipeline-test.sh::PR-E` (unchanged; serves as refactor-guard) |
| Replay-path metrics carry stale cost flags (D-011 regression) | `_replay_scope_approval` runs against a fixture with an existing `usage-<stage>.json` | usage file removed; metrics call carries zero `--`-prefixed cost flags | integration | `bin/run-stage-test.sh::case-24` (unchanged; serves as D-011 guard for the new D-002 metric end-row) |

## 9. Test Strategy

### Unit-layer focus

- `bin/pipeline.sh::_pipeline_clear_halt_label` — covered indirectly by DEC-APPROVE-SCOPE-1..3 (the helper is too small to merit a standalone unit test; capture-file assertions exercise its `has-label` + `remove-label` chokepoint shape).
- `bin/pipeline.sh::cmd_decide` approve-arm D-014 guard — DEC-APPROVE-SCOPE-5 asserts the guard dies BEFORE any `linear.sh` call.
- `_vh_lookup_forward "unknown"` returning empty — SCO-REPLAY-DEFENSIVE asserts the D-002 defensive branch fires; the helper's behaviour itself is pinned by its existing in-place definition (`bin/verdict-handler.sh:40-43`).

### Integration-layer focus

- Full `bin/run-stage.sh::main` path under the replay flag — SCO-REPLAY-FORWARD-1 and -2 drive the entry-to-exit flow with stubbed external dependencies (claude, linear, scope-check, metrics). The assertions cross-validate D-002 against (a) `apply_transition`'s 5-step contract, (b) `_post_dispatch_apply_halt` being unreachable on this path, and (c) `verdict_handler` being unreachable.
- Composite operator flow `approve → continue → replay` — SCO-REPLAY-CONTINUE-COMPOSITE chains `cmd_decide --action continue` into a `run-stage.sh` invocation on the same per-issue state to assert the documented operator escape ramp still works post-ENG-180 (AC #5).
- Stage-drift survival — SCO-REPLAY-STAGE-DRIFT confirms D-002 does not bypass the existing stage-drift safety; this is critical because D-002's branch sits IMMEDIATELY AFTER the drift guard and could be miswritten to skip it.

### Smoke-layer focus

- End-to-end on a real Linear-stubbed worktree via `PIPELINE_DRY_RUN=1 bash bin/pipeline.sh decide ENG-PD2 --action approve --gate scope` (PD2 in `bin/pipeline-test.sh:141-142`) — already exists; serves as the dry-run smoke test for the new approve-arm log line.

### Adversarial coverage intent

- DEC-APPROVE-SCOPE-3 verifies the narrow `--gate scope` scoping is NOT accidentally widened to `--gate build-cap` (an operator approving a build-cap halt with `approve --gate build-cap` must NOT have `pipeline:halted` cleared as a side-effect, because the build-cap halt has different semantics).
- SCO-REPLAY-DEFENSIVE asserts the unknown-forward defensive branch fires cleanly even though it is unreachable in current control flow; this guards against a future stage joining the scope-approval gate at `bin/run-stage.sh:1613` without a row in `_VH_FORWARD_TRANSITIONS`.
- SCO-REPLAY-IDEMPOTENT exercises the operator-resume scenario where `apply_transition` partially succeeded then was re-driven; this guards against the case-24 D-011 contract (no double-counted cost / no double-emitted metrics) regressing in the presence of D-002.
- The `bin/verdict-handler-test.sh::case-12` recast leaves the assertion shape unchanged — it specifically guards against a future "make decision markers freshness-aware" refactor regressing the `find_fresh_verdict` ignore-decision contract that D-002 relies on for partial-failure recoverability.

### Removed-token closure (post-implement gate readiness)

Tokens this plan removes from production code (re-stated for the implement agent's grep-validation pass after Task 1 lands):
- The three-line block at `bin/pipeline.sh:523-525` (replaced by `_pipeline_clear_halt_label "$issue"`).

Grep across all `bin/*-test.sh` after Task 1:
- `grep -F 'bash "$SCRIPT_DIR/linear.sh" has-label "$issue" "pipeline:halted"' bin/*-test.sh` should return zero matches outside of any test that intentionally fixtures the helper's chokepoint (currently zero such tests; the assertion is on the capture-file argv shape, not the source-text literal).

The full `bin/*-test.sh` suite (the pre-commit gate at `.githooks/pre-commit` — `for t in bin/*-test.sh; do ...`) must run green before commit. The pre-commit hook iterates the `bin/*-test.sh` glob, so `bin/pipeline-test.sh`, `bin/run-stage-test.sh`, and `bin/verdict-handler-test.sh` are all covered in practice even though the documented Test command line in `learned-rules/harness/project-profile.md::## Build & test gates` does not enumerate every test by name.

### Regression-guard intent: halt-comment body text

AC #3 (the NOTABLE halt comment's "To approve and resume" text remains accurate) is implicitly verified by the SCO-REPLAY-* fixtures (they only succeed against the unchanged advertised-command shape) and by the §2 Assumption Inventory's `verified` claim against `bin/run-stage.sh:1985-1986`. No standalone grep-pin is added — modifying the halt body would also require flipping every approve-arm fixture in `bin/pipeline-test.sh`, so the regression chain is structurally closed without an explicit body-text assertion. (If a future ticket softens this chain, file a follow-up to add a `grep -F "decide %s --action approve --gate scope" bin/run-stage.sh` assertion in `bin/run-stage-test.sh`.)

## Persona review summary

Five personas reviewed this plan in parallel (feasibility, scope, coherence, design, product). All five returned **PASS** with zero P0 findings.

| Persona | Verdict | P0 | P1 | P2 |
|---|---|---|---|---|
| feasibility | PASS | 0 | 3 | 3 |
| scope | PASS | 0 | 1 | 3 |
| coherence | PASS | 0 | 2 | 3 |
| design | PASS | 0 | 2 | 3 |
| product | PASS | 0 | 1 | 2 |

P1 fixes applied in-iteration:

1. System Invariants `verified_by:` tokens hardened to real anchors: `bin/poll-slot-test.sh:AC-2` (verified at `bin/poll-slot-test.sh:258`) and `bin/verdict-handler-test.sh:case-9` (verified at `bin/verdict-handler-test.sh:347`) — closes feasibility P1 #1 / coherence P1 #2.
2. Task 4 Step 3 (SCO-REPLAY-FORWARD-2) gained an explicit `gh pr create` capture assertion — closes coherence P2 (AC #6 was nominally covered, now explicitly).
3. CLAUDE.md row (Task 6) reworded so the terminal success log line is the primary grep target — closes product P1.
4. Added Test Strategy section "Regression-guard intent: halt-comment body text" addressing coherence P1 #1 (AC #3 was implicitly covered; now documented).

P2 nits left as-is (each justified):

- Exit-22 reuse for D-002's defensive unknown-forward branch (design P2) — unreachable in current control flow; dedicated exit code is follow-up scope.
- "Brainstorm-drafted row text vs plan-collapsed cell" (scope P1) — plan row is denser but semantically equivalent; honors all 5 operator-promise checks.
- Other line-anchor minor drifts (feasibility P1 #2 — `bin/pipeline-test.sh` coverage is via pre-commit glob, not via the profile's Test command line) — clarified in Test Strategy.

Gate result: **5/5 PASS AND zero P0 → clean gate, proceeding to implementing.**
