---
linear: ENG-180
title: scope-approval resume is broken — `decide --action approve --gate scope` never clears `pipeline:halted`, and `--action continue` can't advance the scope-approved/passed stage either
date: 2026-06-12
status: draft
---

# ENG-180 — Make `decide --action approve --gate scope` self-sufficient (Design A)

**Type:** `Bug` (Notable) · **Subsystems:** Linear contract / dispatch (`bin/pipeline.sh::cmd_decide`, `bin/run-stage.sh` scope-approval replay) + orchestrator (subordinate verification: `bin/poll.sh::_poll_classify_labels` re-dispatches once halt label is gone) · **Status:** design draft

## Problem

After a NOTABLE scope-violation halt, the orchestrator's own halt comment instructs the
operator:

> To approve and resume:
>
>     bash bin/pipeline.sh decide ENG-N --action approve --gate scope

(`bin/run-stage.sh:1985-1986` — the literal body of the halt comment.)

Running that command does **not** resume the issue. The slot stays at
`slot:"vacate", operator_action_required:true` for hours/indefinitely until an
operator notices. Empirically observed on ENG-113 (2026-06-10): operator posted
`decision action=approve gate=scope` at 09:15Z; the issue sat at
`stage:implementing + pipeline:halted` for ~7h with no further dispatch.

Even after the operator clears the halt by hand and runs
`bash bin/pipeline.sh decide ENG-113 --action continue`, the next replay tick logs:

```
scope-check: notable approved by scope-approve decision; clearing state and proceeding
post-dispatch: applying pipeline:halted (orchestrator-managed, ENG-56)
verdict-handler: protocol violation (no-marker): no fresh verdict marker on the issue
  (current_dispatch_id=<unset>). Resolution: ... --action continue ...
```

So **both** `approve` and `continue` fail to advance a stage whose work is complete and
whose scope is approved. The only manual recovery today is force-applying the transition
(`apply_transition <issue> implementing reviewing` after sourcing
`bin/verdict-handler.sh`), which is undocumented and not operator-facing.

This is the third instance of the "resolved gate doesn't recall the slot" class
(cf. ENG-178 wait-recallable, ENG-154/ENG-119 dimensional-grading state).

## Root cause — two coupled layers

### Layer 1 — `approve` doesn't clear the halt label

`bin/pipeline.sh::cmd_decide` (lines 472–575) gates the entire atomic-reset block on
`action == continue` (line 503). The block that removes `pipeline:halted` is part of
that gate (lines 523-525):

```bash
if [[ "$action" == "continue" ]]; then
  if [[ "${PIPELINE_DRY_RUN:-}" != "1" ]]; then
    ...
    if bash "$SCRIPT_DIR/linear.sh" has-label "$issue" "pipeline:halted" 2>/dev/null; then
      bash "$SCRIPT_DIR/linear.sh" remove-label "$issue" "pipeline:halted"
    fi
    ...
  fi
fi
# Then ALL three arms (continue|approve|abandon) fall through to add-comment.
bash "$SCRIPT_DIR/linear.sh" add-comment "$issue" "$body"
```

`bin/poll.sh::_poll_classify_labels` (lines 289-314) classifies any issue carrying
`pipeline:halted` as `slot:"vacate", operator_action_required:true` regardless of the
shape of any later `decision` marker. `find_fresh_verdict` (the helper poll consults at
line 291) filters comments where `.event == "verdict"` (line 183 of
`bin/verdict-handler.sh`), so `decision` markers are never visible to it. Net effect:
the scope-approve decision comment lands in Linear, but the poller's view of the slot
doesn't change. The slot stays vacated.

### Layer 2 — even after the halt is cleared, the scope-approval replay cannot emit forward progress

The replay path was deliberately designed (ENG-18 §scope-approval, then ENG-26 D-011) to
skip the agent dispatch to save tokens: `bin/run-stage.sh:1612-1620` sets
`skip_dispatch=1` when the sentinel file `$(issue_dir <ident>)/scope-approval` exists
*and* `scope-check.sh has-scope-approval <ident>` returns 0. The agent never runs, so
no fresh `verdict result=pass stage=...` marker is emitted during the replay.

Post-dispatch, the flow at `bin/run-stage.sh:1945-2035` runs scope-check again. With
the sentinel still present and the decision marker still in Linear, the NOTABLE
branch matches "approved by scope-approve decision; clearing state and proceeding"
(lines 1967-1970), deletes the sentinel, and falls through.

The rest of the post-dispatch flow runs:

1. `push_branch_if_ahead` and `post_completion_comment` (lines 2256-2272).
2. **`_post_dispatch_apply_halt`** (line 2297) — orchestrator-managed halt label
   re-application (ENG-56). Since no fresh wait verdict exists, it re-applies
   `pipeline:halted`. *This is the first log line in the empirical reproducer.*
3. **`verdict_handler "$ident" "$vh_stage"`** (line 2314). `find_fresh_verdict`
   looks for the latest `verdict result=(pass|fail|halt)` marker newer than the most
   recent transition comment (verdict-handler.sh:204-223 legacy fallback;
   verdict-handler.sh:175-200 strict-id path when dispatch markers exist on the
   issue). Either way:
   - The original implement-pass verdict (which earned the transition the
     operator now wants) is *older than* the recent `verdict result=halt
     reason=scope-violation` marker.
   - On the legacy fallback path: it's also older than the most-recent transition
     (including the operator-resume transition the `continue` arm posts at
     `bin/pipeline.sh:549`).
   - On the strict-id path: `skip_dispatch=1` skips the dispatch_id allocation
     block at `bin/run-stage.sh:1671-1750`, so `PIPELINE_DISPATCH_ID` is unset
     for the replay and `find_fresh_verdict` reports `current_dispatch_id=<unset>`
     in the diagnostic, matching the empirical log.
   - `find_fresh_verdict` returns empty.
4. `verdict_handler`'s empty-fresh branch (verdict-handler.sh:527-540) routes
   through `_vh_classify_no_fresh_reason` → `_vh_protocol_violation`, which
   posts the second log line (`verdict-handler: protocol violation
   (no-marker): no fresh verdict marker...`) AND re-applies `pipeline:halted`
   via `bin/verdict-handler.sh:58`.

So `approve --gate scope` is dead on arrival (Layer 1), and even after a manual
halt-clear the replay cannot advance (Layer 2). The two layers compound: even if we
fix Layer 1 in isolation, the very first replay tick would re-halt at Layer 2.

## Conceptual model

A scope-approval decision is the operator saying *"the work the agent produced is
fine; let the stage's already-earned pass count."* The pipeline already knows what
"earned" means — the source stage had a clean dispatch that produced a `verdict=pass`,
and the only blocker is one out-of-scope diff that the operator has now explicitly
sanctioned.

Today's machinery makes the replay re-derive the pass from Linear comments — but the
agent that emitted the pass is gone (dispatch id stale), and the replay deliberately
doesn't emit a new one. The orchestrator has all the information it needs *locally*
(scope was approved; the source stage label is on the issue), so it should not need
the comment ledger to re-derive a fact it already owns.

The fix is to:

- **(D-001)** make `approve --gate scope` clear `pipeline:halted` so the poller
  re-dispatches the replay, and
- **(D-002)** make the scope-approval replay apply the forward transition
  directly from the source stage, bypassing the verdict-handler's
  fresh-verdict requirement (which the replay can never satisfy by design).

## Design — the change

Two small in-place edits in two files, plus paired tests.

### D-001 — `approve --gate scope` clears `pipeline:halted`

Factor the halt-clear block out of `cmd_decide`'s continue arm into a helper, and
call it from a new approve-arm branch. The continue arm keeps doing what it does
today; approve-arm gains *only* the halt-label removal (no drain of wait files, no
breaker clear, no operator-resume transition, no per-issue counter clear).

```bash
# bin/pipeline.sh — new helper sibling to _pipeline_clear_breaker.
# Idempotent: linear.sh remove-label is a no-op on missing label.
_pipeline_clear_halt_label() {
  local issue="$1"
  if bash "$SCRIPT_DIR/linear.sh" has-label "$issue" "pipeline:halted" 2>/dev/null; then
    bash "$SCRIPT_DIR/linear.sh" remove-label "$issue" "pipeline:halted"
  fi
}
```

In `cmd_decide` (after the existing `continue` block at line ~555, before the
decision-comment write at line ~574). **Order is load-bearing** (matches the
continue arm's halt-clear-before-comment-write sequence — see OQ-4 / §"Open
questions"): halt-clear runs first so a partial-failure mid-clear leaves
recoverable state (next run of `approve --gate scope` is idempotent), and the
decision comment writes last so `has_scope_approval` on the next replay tick
sees the marker only when the halt label is already cleared:

```bash
# ENG-180 D-001: approve --gate scope must clear pipeline:halted, otherwise
# poll.sh::_poll_classify_labels keeps the slot vacated and the replay never
# runs. Scope is intentionally narrow: only the halt label, not the full
# atomic reset (see brainstorm §"Out of scope" and §"Rejected alternative —
# mirror full continue reset").
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

The continue arm's identical halt-clear block (lines 523-525) is refactored to call
the helper too (mechanical equivalence; preserves the existing `if has-label` guard's
log noise behaviour). No behaviour change on the continue path.

**Why only `--gate scope`, not all approve actions?** The other registered gate is
`build-cap` (pipeline-events.json:46-49), and there is no symmetric "build-cap
halt-clear" need today (the build agent's wait path handles cap signalling without
applying `pipeline:halted`). Narrowing to `--gate scope` keeps the change in line
with the issue's stated scope (the halt comment specifically advertises `--gate
scope`); a future build-cap halt-clear can extend the branch when needed.

### D-002 — scope-approval replay applies the forward transition directly

In `bin/run-stage.sh::main`, between the stage-drift guard (line 2286-2292) and
`_post_dispatch_apply_halt` (line 2297), add a `skip_dispatch` early-exit:

```bash
# ENG-180 D-002: scope-approval replay directly applies the forward transition.
# The replay deliberately skips the agent dispatch (no fresh verdict marker is
# emitted), so verdict_handler's find_fresh_verdict will return empty and
# _vh_protocol_violation will re-halt. The source stage's prior clean pass already
# earned the transition; emit it here. Runs after post_completion_comment so the
# orchestrator's narrative post still lands; runs before _post_dispatch_apply_halt
# so the halt label is not re-applied; runs before verdict_handler so the
# protocol-violation path is not entered. vh_stage is the long-form stage from
# the current Linear label (resolved by the stage-drift guard above).
if (( skip_dispatch )); then
  local _fwd
  _fwd="$(_vh_lookup_forward "$vh_stage")"
  if [[ -z "$_fwd" ]]; then
    # Defensive — unreachable in current control flow: scope-approval replay
    # is gated to stages implementing|ui (run-stage.sh:1613), both of which
    # have forward rows in _VH_FORWARD_TRANSITIONS (verdict-handler.sh:19-27).
    # Future stages that join the gate without a forward row will fall here.
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

`_vh_lookup_forward` and `apply_transition` are both already in scope —
`bin/verdict-handler.sh` is sourced at `bin/run-stage.sh:38`, and both are
exported at `bin/verdict-handler.sh:606`. No new sourcing or import work.

`apply_transition` is idempotent (`bin/verdict-handler.sh:309-310` comment:
*"Each step is idempotent; resume_in_progress_transition can re-enter at any
point and finish cleanly"*) — re-running the replay after a partial-failure
re-enters cleanly via the resume path.

The `cost_flags` array is empty on this path (`_replay_scope_approval` deletes
`usage-${stage}.json` at `bin/run-stage.sh:314`), so the metrics call carries
no cost flags. This matches the D-011 contract (replays must omit cost fields —
asserted by case-24 at `bin/run-stage-test.sh:684-690`).

The early-exit is positioned *after* the stage-drift guard so that an operator who
manually transitions the issue mid-replay still gets the drift-guard short-circuit
(line 2289-2291) — the stage label observed at line 2285 already disagrees with the
dispatched stage label by then, so we never reach the new branch.

The dispatch_history.jsonl pairing invariant is preserved: the replay path never
allocated a dispatch_id (line 1671's `(( ! skip_dispatch ))` gate) so neither
start-row nor EXIT trap was installed, and the new exit point therefore does not
need to emit an end-row.

## Rejected alternatives

### Design B — make `poll.sh::_poll_classify_labels` consult `has-scope-approval`

Extend the poll-side `pipeline:halted` arm at `bin/poll.sh:289-314` to check
`scope-check.sh has-scope-approval <issue>` and, when true, treat the slot as
`hold, advanceable:true` even though the halt label is still on.

**Rejected because:**

- **Wrong layer for the fix.** The slot-occupancy contract (ENG-90) treats
  `pipeline:halted` as the canonical operator-attention flag; making the
  poller silently override that on a per-marker basis breaks the
  invariant "halt label ⇒ no agent compute will run" that ENG-90 D-003
  pinned. Operators reading `bin/status.sh` would see a halted issue
  that the orchestrator is nonetheless dispatching against, contradicting
  the halt-comment promise.
- **Doesn't solve Layer 2.** Even if the poller dispatches the replay,
  `find_fresh_verdict` still returns empty post-dispatch and the
  protocol-violation re-halt still fires. Design B would need Design A's
  Layer 2 fix *anyway*, while keeping the halt label cluttering Linear and
  `bin/status.sh` views indefinitely.
- **Couples the two surfaces.** Today scope-approval logic lives entirely
  on the orchestrator side (`run-stage.sh` + `scope-check.sh`); the poller
  is stack-neutral. Importing scope semantics into the poller adds a
  scope-shaped dependency to a file that otherwise reads only labels and
  Linear-state.

The Linear issue explicitly notes Design B was "considered and explicitly not chosen."

### Rejected — Synthesise a fresh `verdict=pass` marker in the replay

After scope-check approves, the replay could post a synthetic
`<!-- pipeline: verdict result=pass stage=$vh_stage --> Scope-approved replay.`
comment. `find_fresh_verdict` would then surface it, and `verdict_handler` would
transition normally.

**Rejected because:**

- **Lane violation.** `pipeline-events.json:90` declares `writer_lane: "agent"`
  for `verdict` events. The orchestrator posting a verdict crosses lanes; if
  ENG-41's lane fence is later tightened to enforce this at the chokepoint,
  the synthetic post would be rejected.
- **Dispatch-id confusion.** The replay has no allocated
  `PIPELINE_DISPATCH_ID`. Either we'd post the marker without auto-injection
  (no `<!-- meta: dispatch id=... -->` marker) — fine for the legacy fallback
  but it makes the strict-id path silently skip the synthetic pass on the
  next dispatch — or we'd allocate a synthetic dispatch_id solely for this
  one comment, polluting the per-issue counter for no agent run.
- **Indirection cost.** D-002's direct `apply_transition` call is one
  function call; the synthesis path is a comment-post round-trip plus
  re-parse plus transition. Same end state, more moving parts.

### Rejected — Mirror the full `continue` atomic reset on `approve --gate scope`

Have `approve --gate scope` call `_pipeline_drain_wait_files`,
`_pipeline_drain_skip_labels`, `_pipeline_drain_issue_state`,
`_pipeline_clear_breaker`, `auto_commit_in_scope`, and
`_pipeline_post_operator_transition` (i.e., the full continue arm), so the operator
gets a single command that resets everything.

**Rejected because:**

- The issue's scope guidance explicitly says: *"Keep approve idempotent
  (re-runnable) and scoped — it must not drain unrelated state (wait files,
  breaker, other-stage skip labels) the way continue does."*
- Operator semantics differ. `--action continue` is *"reset everything I touched,
  pick up where I left off"*; `--action approve` is *"sanction this specific gate,
  let the work-in-progress proceed"*. Conflating them removes the operator's
  ability to express the narrow approval.
- Posting an `operator-resume` transition would actually *worsen* Layer 2 on
  approve (the new transition timestamp becomes the new `last_transition_ts`
  for `find_fresh_verdict`, pushing the original pass further into the past).
  D-002 short-circuits the verdict-handler dependency, but adding an
  operator-resume marker here is gratuitous churn.

## Architecture — where code goes

- **`bin/pipeline.sh`** — new helper `_pipeline_clear_halt_label <issue>`
  (sibling to `_pipeline_clear_breaker`). New approve-arm branch inside
  `cmd_decide` (~5 lines, after the existing `continue` block at line ~555).
  Continue arm's inline halt-clear (lines 523-525) refactored to call the
  helper (mechanical, no behaviour change).
- **`bin/run-stage.sh::main`** — new `skip_dispatch` early-exit branch
  inserted between the stage-drift guard at line 2286-2292 and
  `_post_dispatch_apply_halt` at line 2297 (~15 lines, comment-heavy).
  Uses `_vh_lookup_forward` + `apply_transition` already in scope via the
  source at line 38.
- **No new file, no new exit code, no new failure_outcome entry.** Exit 22
  (`pr-opened-too-early`) is reused for the defensive unknown-forward
  branch — this is an extension of the existing pattern (other defensive
  `classify_failure` calls in `run-stage.sh` route 22 too). The defensive
  branch is unreachable in current control flow per the comment; if
  someone *does* hit it, a `pr-opened-too-early` label is wrong but the
  immediate halt + diagnostic in the comment body makes the cause
  recoverable.
- **`bin/pipeline-test.sh`** — new fixtures for the `approve --gate scope`
  halt-clear (mirror the existing continue-arm tests' shape).
- **`bin/run-stage-test.sh`** — new fixtures for the scope-approval replay
  forward-transition (extend the existing case-24 D-011 pattern at line
  ~649-691; add an integration test that asserts `apply_transition` was
  invoked with the expected `(from, to)` and that
  `_post_dispatch_apply_halt` / `verdict_handler` were NOT invoked).
- **`bin/verdict-handler-test.sh`** — one-line comment edit on case 12 at
  lines 413-434 to recast the assertion as a verdict-handler-contract
  regression guard (D-002 short-circuits the call site upstream;
  verdict-handler's response to a scope-approved-but-no-fresh-pass state is
  unchanged and still rejected here). See §Testing item 15.
- **CLAUDE.md "Failure-mode quick reference"** — new row contrasting the
  pre-ENG-180 "approved but stuck" symptom with the post-ENG-180 expected
  behaviour. Proposed row text (operator-readable; product persona P1):

  > **Symptom:** Issue at `stage:implementing` or `stage:ui` with `pipeline:halted`
  > after a NOTABLE scope-violation halt; operator ran
  > `bash bin/pipeline.sh decide <ENG-N> --action approve --gate scope` but the
  > slot sits at `vacate, operator_action_required=true` for ≥ 1 tick.
  >
  > **Where to look:** Inspect `bin/status.sh` row + the Linear thread for a
  > `decision action=approve gate=scope` marker. **Post-ENG-180 expected behaviour:**
  > the next tick's replay runs, scope-check logs `notable approved by scope-approve
  > decision; clearing state and proceeding`, the orchestrator emits
  > `stage <stage> complete for <ENG-N> (scope-approval-replay transitioned
  > <src> → <fwd>)`, and the issue advances. **Pre-ENG-180 symptom (legacy only):**
  > the second-to-last log line was
  > `post-dispatch: applying pipeline:halted (orchestrator-managed, ENG-56)`
  > followed by `verdict-handler: protocol violation (no-marker): no fresh
  > verdict marker on the issue (current_dispatch_id=<unset>)`. Recovery on
  > legacy code: source `bin/verdict-handler.sh` and run
  > `apply_transition <ENG-N> implementing ui` (or `ui reviewing`); then
  > `bash bin/linear.sh remove-label <ENG-N> pipeline:halted`. This escape
  > hatch is unnecessary post-ENG-180.

  Both halves (post-fix expected behaviour + legacy-only recovery) appear in
  the row so an operator on a not-yet-deployed host can still self-recover.
- **No new ADR.** This is a tightening of two existing flows (decide
  action-gating + scope-approval replay), both already documented in
  `docs/architecture.md` and `CLAUDE.md`. No architectural axis is added.

## Data flow

```
Operator:  bash bin/pipeline.sh decide ENG-N --action approve --gate scope
            │
            └─ cmd_decide
                ├─ validate action, gate
                ├─ if action==continue: (existing atomic reset, unchanged)
                ├─ ENG-180 D-001: if action==approve && gate==scope:
                │   └─ _pipeline_clear_halt_label ENG-N
                │       └─ linear.sh remove-label ENG-N pipeline:halted (idempotent)
                └─ linear.sh add-comment ENG-N "<!-- pipeline: decision action=approve gate=scope -->"

Next launchd tick:
  poll.sh: ENG-N labels = {stage:implementing} (halt cleared, decision marker present)
    └─ _poll_classify_labels: no pipeline:halted → falls to stage:implementing arm
        └─ slot:"hold", advanceable:true       (was vacate before D-001)

  run-stage.sh ENG-N implementing
    ├─ resolve worktree, pre-dispatch merge gate
    ├─ scope-approval gate (lines 1612-1620):
    │   └─ sentinel + has-scope-approval → skip_dispatch=1
    ├─ _replay_scope_approval (rm usage; emit replay metric)
    ├─ scope-check rc=1, NOTABLE-approved branch (lines 1967-1970):
    │   └─ "scope-check: notable approved by scope-approve decision; clearing state and proceeding"
    ├─ push_branch_if_ahead
    ├─ post_completion_comment (orchestrator-narrative)
    ├─ stage-drift guard (unchanged)
    ├─ ENG-180 D-002: if skip_dispatch:
    │   ├─ _vh_lookup_forward implementing → ui
    │   ├─ apply_transition ENG-N implementing → ui
    │   │   ├─ post "<!-- pipeline: transition from=implementing to=ui -->"
    │   │   ├─ add-label stage:ui
    │   │   ├─ remove-label stage:implementing
    │   │   ├─ drain legacy pipeline-namespace labels
    │   │   └─ remove-label pipeline:halted   (idempotent — D-001 already cleared)
    │   ├─ emit stage-end success "verdict=transitioned scope-approval-replay=1"
    │   └─ exit 0
    └─ (_post_dispatch_apply_halt + verdict_handler not reached)
```

The old broken flow took the same path through the scope-check NOTABLE-approved
branch, then hit `_post_dispatch_apply_halt` (re-applies halt) and `verdict_handler`
(protocol-violation halt). D-002 short-circuits before those two steps.

## Error handling

| Condition | Behaviour |
|---|---|
| `approve --gate scope` on a halted scope-violation issue | D-001: halt label cleared, decision comment posted. Next tick re-dispatches replay. |
| `approve --gate scope` on an issue with no halt label | D-001: no-op halt-clear (idempotent), decision comment posted. Same as today. |
| `approve --gate scope` with `PIPELINE_DRY_RUN=1` | Halt-clear suppressed (existing dry-run pattern). Decision comment also suppressed (existing dry-run pattern at line ~570). |
| `approve --gate scope` with invalid issue id | New `[[ $issue =~ ^ENG-[0-9]+$ ]]` guard dies BEFORE linear.sh call (mirrors continue arm's D-014 sanitisation at line 508-509). |
| `approve --gate build-cap` (other gate) | Unchanged. No halt-clear. The build-cap path is wait-shape, not halt-shape. |
| `approve` without `--gate` | Unchanged. `_validate_registry` at line 494 already dies on missing gate. |
| Scope-approval replay, `vh_stage` is implementing | D-002: forward to ui via `apply_transition`. |
| Scope-approval replay, `vh_stage` is ui | D-002: forward to reviewing via `apply_transition`. PR-create hook in `apply_transition` (verdict-handler.sh:350-410) fires idempotently. |
| Scope-approval replay, `vh_stage` is anything else | Defensive: classify_failure skip-until-human-acts, exit 22. Unreachable in current control flow (gate is `stage == implementing \|\| stage == ui` at line 1613). |
| Stage drifted mid-replay (operator manually transitioned) | Stage-drift guard at line 2286-2292 short-circuits before D-002. Existing behaviour preserved. |
| `apply_transition` partial-failure (Linear API down mid-call) | The next tick re-enters: poll sees `stage:implementing` (or `stage:ui`), runs the replay again, scope-check still passes (sentinel + decision marker present from prior approve), D-002 fires again, `apply_transition` re-runs idempotently (verdict-handler.sh:309-310 idempotency contract). Eventually completes. |
| `apply_transition` fails to emit the metric end-row | The metric call is `\|\| true`-safe in callers; we accept a missing end-row over a refusal to transition. Loss is forensic, not operational. |
| `_pipeline_clear_halt_label` linear.sh remove-label call fails | The `has-label` guard short-circuits the `remove-label` call if the API was responsive enough to answer the read; if the API is down both calls fail and the operator sees the error. Decision comment post (next step) will also fail loudly. Same failure mode as the existing continue arm. |

## Edge cases

1. **Operator runs `approve --gate scope` twice in a row.** First run: clears halt,
   posts decision marker. Second run: halt already cleared (`has-label` guard fires,
   no-op), posts a second decision marker. Decision markers accumulate (no
   deduplication in `bin/pipeline.sh`; same behaviour as today for continue).
   Acceptable — Linear thread carries two visible `decision action=approve gate=scope`
   comments; orchestrator behaviour is identical.

2. **Operator runs `approve --gate scope` then `continue` before the next tick.**
   Approve clears halt (Layer 1). `continue` runs full atomic reset over already-clean
   state (idempotent: drain helpers no-op when nothing to drain, breaker-clear no-op,
   halt-clear no-op, posts operator-resume transition). Replay runs at next tick,
   scope-check passes, D-002 transitions forward. Operator-resume transition becomes
   a no-op waypoint in Linear thread. No infinite loop, no double-transition.

3. **Operator runs `continue` *without* running `approve --gate scope` first.**
   continue clears halt, posts operator-resume transition. Next tick: replay runs.
   Scope-check NOTABLE branch: sentinel exists (from the original halt), but
   `has-scope-approval` returns false (no decision marker present). The NOTABLE
   else-branch fires (lines 1972-2009): re-emits the halt comment + re-applies the
   halt label. The issue returns to its prior halted state. The operator's visible
   surface is: identical halt comment posts again in Linear (same body, fresh
   timestamp), `pipeline:halted` label re-appears. There is no "I expected this
   to proceed" log emitted by the orchestrator today (the NOTABLE else-branch is
   structurally indistinguishable from a fresh scope-violation on the agent's
   run); the operator infers the cause from the repeat-halt and runs
   `approve --gate scope`. The new CLAUDE.md failure-mode row makes this
   explicit so they don't loop on `continue`. This is the *correct* behaviour:
   continue alone does not sanction an unapproved scope violation.

4. **Stage label says `stage:implementing` but `_vh_lookup_forward` is empty (defensive).**
   D-002's `[[ -z "$_fwd" ]]` arm fires: `classify_failure skip-until-human-acts`, exit
   22. Per the comment, unreachable in current control flow (the scope-approval gate at
   line 1613 restricts to `stage == implementing \|\| stage == ui`, both of which have
   forward rows in `_VH_FORWARD_TRANSITIONS` at verdict-handler.sh:19-27).

5. **`apply_transition` posts the transition waypoint comment but the label-flip
   call fails (mid-transition crash).** Next tick: `resume_in_progress_transition`
   at verdict-handler.sh:439-514 reads the latest transition comment, sees the
   `(from, to)` pair, and completes the label operations. Standard ENG-87 §4.3
   resume path. The dispatch_id-mismatch guard at line 466-485 is bypassed because
   the replay's transition comment has no `<!-- meta: dispatch id=... -->` marker
   (orchestrator-lane, no `PIPELINE_DISPATCH_ID` set on replay), so the
   `[[ -n "$_curr_id" ]]` guard at line 472 short-circuits. Resume completes.

6. **The replay's `_replay_scope_approval` deleted `usage-<stage>.json`, but the
   transition waypoint comment is what `apply_transition` posts via `add-comment`
   (orchestrator lane).** The lane-fence at `bin/linear.sh` allows orchestrator-lane
   writes without `PIPELINE_DISPATCH_ID` (see linear.sh:98-107 — only agent lane
   requires both vars). No envelope violation, no header-missing-inputs error.

7. **Multiple stage:* labels on the issue.** `apply_transition` calls
   `linear.sh add-label stage:ui` then `remove-label stage:implementing`. If a stale
   `stage:reviewing` label existed for some reason, it survives. This is the same as
   today's verdict-handler-led transition — neither the existing flow nor D-002
   does a sweep of stale stage labels. Acceptable; outside D-002's scope.

8. **PIPELINE_WRITER lane on `approve --gate scope`.** `cmd_decide` at line 565-567
   warns if `PIPELINE_WRITER != "human"` but does not abort. Operator-invocations
   from the CLI default to `PIPELINE_WRITER=human`; orchestrator-invoked
   `decide --action approve` (none today) would log a warning. Unchanged by D-001.

## Testing (TDD)

New / extended fixtures:

### `bin/pipeline-test.sh`

1. **DEC-APPROVE-SCOPE-1 (halt-clear fires):** Stub `linear.sh` with a fake
   `has-label` returning 0 (halted) and a `remove-label` capture. Call
   `cmd_decide ENG-T-APP1 --action approve --gate scope`. Assert
   `remove-label ENG-T-APP1 pipeline:halted` appears in the capture exactly
   once, and the decision-comment add-comment fires after the halt-clear.

2. **DEC-APPROVE-SCOPE-2 (halt-clear idempotent — no halt label present):**
   Stub `linear.sh` with `has-label` returning 1 (no halt). Call the same
   decide invocation. Assert NO `remove-label` call in the capture; decision
   comment still posts.

3. **DEC-APPROVE-SCOPE-3 (other gates unaffected):** Call `cmd_decide ENG-T-APP3
   --action approve --gate build-cap`. Assert NO `remove-label` call; only the
   decision comment posts (existing behaviour preserved).

4. **DEC-APPROVE-SCOPE-4 (dry-run suppresses halt-clear):** `PIPELINE_DRY_RUN=1`
   set in env. Assert the new log line `dry-run — halt-clear suppressed` fires and
   no `remove-label` call in the capture; decision comment dry-run printf also
   fires.

5. **DEC-APPROVE-SCOPE-5 (invalid issue id):** Call `cmd_decide INVALID-ID
   --action approve --gate scope`. Assert the new D-014-style guard dies with
   `expected ENG-<digits>`, no linear.sh calls.

6. **DEC-CONTINUE-REGRESSION (refactor regression guard):** Existing continue-arm
   tests that assert "remove-label pipeline:halted" exists in the capture must
   keep passing after the inline block is refactored to call
   `_pipeline_clear_halt_label`. Run the existing suite as-is.

### `bin/run-stage-test.sh`

7. **SCO-REPLAY-FORWARD-1 (implementing → ui):** Per-issue worktree setup,
   sentinel file at `$(issue_dir ENG-T-SR1)/scope-approval`, stub
   `scope-check.sh has-scope-approval` returning 0, stub
   `scope-check.sh` main returning rc=1 with a `notable\t...` line for the
   NOTABLE-approved branch, stub `linear.sh stage-of` returning
   `stage:implementing`. Drive `run-stage.sh ENG-T-SR1 implementing` with the
   D-002 branch. Assert:
   - `apply_transition` was called with `(ENG-T-SR1, implementing, ui, "")`.
   - `_post_dispatch_apply_halt` was NOT called.
   - `verdict_handler` was NOT called.
   - The replay exit code is 0.
   - `metrics.sh stage-end ... success ... verdict=transitioned scope-approval-replay=1`
     was emitted.

8. **SCO-REPLAY-FORWARD-2 (ui → reviewing):** Same shape as -1 but starting
   from `stage:ui`. Assert the transition is `(ui, reviewing, "")`.

9. **SCO-REPLAY-DEFENSIVE (unknown forward → halt):** Override the helper
   stub for `_vh_lookup_forward` to return empty. Assert the defensive
   classify_failure path fires and exit 22 is returned.

10. **SCO-REPLAY-STAGE-DRIFT (operator transitioned mid-replay):** Stub
    `linear.sh stage-of` returning a label different from the dispatched stage
    label. Assert the stage-drift guard at line 2286-2292 short-circuits
    BEFORE the D-002 branch (existing behaviour preserved — D-002 must not
    bypass stage-drift).

11. **SCO-REPLAY-IDEMPOTENT (re-entry after partial-failure):** Run the
    replay twice in sequence with the same fixture. Assert both runs complete
    without error (apply_transition's idempotency, second post_completion_comment
    is fine, etc.).

### Cross-suite

12. **SCO-REPLAY-CONTINUE-COMPOSITE (continue after a prior approve resolves):**
    Stub the issue with halt label present, scope-violation halt verdict in the
    comment stream, AND a `decision action=approve gate=scope` comment from a
    prior operator action, AND the sentinel file at
    `$(issue_dir <ident>)/scope-approval`. Run `cmd_decide ENG-T-CONT
    --action continue`. Assert halt label removed, operator-resume transition
    posted. Then drive `run-stage.sh ENG-T-CONT implementing` against the
    same per-issue state. Assert: scope-approval gate still fires (sentinel +
    has-scope-approval both true — `continue` did not touch the sentinel),
    D-002 transitions forward, no protocol-violation. Drives AC #4.

13. The existing case-24 D-011 test at `bin/run-stage-test.sh:649-691` must
    keep passing — the new D-002 branch runs AFTER `_replay_scope_approval`'s
    rm-f, so the usage-file-removed assertion still holds, and the
    cost-flags-absent assertion still holds (D-002's metric end-row receives
    no cost flags by construction).

14. The existing scope-check tests for `has_scope_approval` at
    `bin/scope-check-test.sh:526-545` are unchanged — D-002 does not modify
    the helper.

15. The existing verdict-handler test case 12 (scope-approve newer than halt
    still rejects pass) at `bin/verdict-handler-test.sh:413-434` is
    unchanged — D-002 fires in `run-stage.sh::main` BEFORE
    `verdict_handler` runs on the replay path, so case 12's premise (replay
    actually calls verdict_handler) no longer holds post-D-002. Verdict-handler
    case 12 should be re-cast as a *regression guard* (the verdict_handler
    contract is unchanged; D-002 short-circuits the call site, not the
    handler). The recast is a one-line comment edit in
    `bin/verdict-handler-test.sh` (added to §Architecture's file list).

Run the full `bin/*-test.sh` sweep (the pre-commit gate) green before commit.

## Out of scope

- Redesigning `find_fresh_verdict`'s freshness model (e.g., consulting
  `decision` markers, or making `pass` markers freshness-immune). Layer 2's
  fix is to *bypass* verdict_handler on the replay path, not to change its
  semantics. Out-of-scope per the issue body.
- The `pipeline:halted` not-drained-by-`apply_transition` invariant.
  `apply_transition` at verdict-handler.sh:430 already removes
  `pipeline:halted` as its final step; that path is unchanged and we rely
  on it without modification.
- Mirroring the full `continue` atomic reset on `approve --gate scope` (see
  "Rejected alternatives").
- Generalising D-002 to other "the orchestrator already knows the answer"
  short-circuits (e.g., wait-recallable replays). Each such replay has its
  own fresh-marker requirement; addressing them individually as
  failure-modes surface is the maintainable shape, not a unified abstraction.
- Refactoring the scope-approval gate at line 1612-1620 to declare its own
  forward-transition mapping. The mapping is implicit in
  `_VH_FORWARD_TRANSITIONS`; D-002's `_vh_lookup_forward` call is the right
  consumer.
- Adding a new exit code / failure_outcome for the defensive unknown-forward
  case in D-002. Exit 22 is reused per the §Architecture decision; if the
  defensive branch starts firing in the wild, a follow-up ticket can carve
  out a dedicated code.

## Acceptance criteria

1. After a NOTABLE scope-violation halt, a single
   `bash bin/pipeline.sh decide ENG-N --action approve --gate scope`
   command removes `pipeline:halted` (verified by inspecting the issue's
   Linear labels post-command) and the next tick re-dispatches the replay.
   (D-001; driven by DEC-APPROVE-SCOPE-1.)

2. The replay advances the stage cleanly (`implementing → ui` or `ui →
   reviewing`) with no `_vh_protocol_violation`, no re-applied
   `pipeline:halted`, no protocol-violation halt comment in Linear.
   (D-002; driven by SCO-REPLAY-FORWARD-1, SCO-REPLAY-FORWARD-2.)

2a. The replay is idempotent under partial-failure / re-entry: running the
    replay twice in sequence on the same fixture leaves the issue in the
    same end state as a single run (no double-transition, no duplicate
    completion comment beyond Linear's append-only ledger, no
    re-applied halt). (Driven by SCO-REPLAY-IDEMPOTENT — §Testing item 11.)

3. The halt comment's "To approve and resume" text remains accurate (no
   change to the body at `bin/run-stage.sh:1985-1986`).

4. `--action continue` remains a valid universal resume on the same
   state (halt + approve decision both present): `continue` clears halt
   and posts an operator-resume transition; next tick's replay still fires
   D-002 (sentinel + decision marker both present), transitions forward, no
   protocol-violation. (Driven by DEC-CONTINUE-REGRESSION + the new
   `SCO-REPLAY-CONTINUE-COMPOSITE` fixture defined in §Testing item 12.)

5. The transition emits exactly one
   `<!-- pipeline: transition from=implementing to=ui -->` (or ui→reviewing)
   waypoint comment via `apply_transition`'s step 1, and the
   `stage:implementing` (or `stage:ui`) label is removed and replaced by the
   forward label.

6. PR-create hook at `apply_transition`'s `to=="reviewing"` arm fires
   idempotently on the ui→reviewing case (existing behaviour preserved).

7. Metric end-row `success / verdict=transitioned scope-approval-replay=1`
   lands in `events.jsonl`; cost-flags are absent (D-011 contract preserved).

8. CLAUDE.md "Failure-mode quick reference" gains a row describing the
   pre-ENG-180 "approved but stuck" symptom and the post-ENG-180 expected
   behaviour; pre-ENG-180 force-apply escape hatch is documented as
   historical only.

9. Full `bin/*-test.sh` suite passes (the pre-commit gate). Eleven new
   fixtures land green: DEC-APPROVE-SCOPE-1..5 (pipeline-test.sh),
   SCO-REPLAY-FORWARD-1..2, SCO-REPLAY-DEFENSIVE, SCO-REPLAY-STAGE-DRIFT,
   SCO-REPLAY-IDEMPOTENT, SCO-REPLAY-CONTINUE-COMPOSITE (run-stage-test.sh).
   Existing case-24 D-011 (`bin/run-stage-test.sh:649-691`), existing
   `has_scope_approval` cases (`bin/scope-check-test.sh:526-545`), and
   continue-arm regression cases (DEC-CONTINUE-REGRESSION) stay green
   unchanged.

10. No new exit code, no new failure_outcome entry, no new ADR.

## Open questions

1. **OQ-1 — should `approve --gate scope` also remove the
   `pipeline:skip-until-code-changes` label, in case classify_failure ever
   started routing scope-violation through it?** Today, the NOTABLE
   scope-violation halt path at `bin/run-stage.sh:1971-2009` does NOT call
   classify_failure (it `exit 0`s after posting the halt verdict + label),
   so `pipeline:skip-until-code-changes` is never applied by the
   scope-violation halt path itself. But the SEVERE rc=3 path at lines
   2012-2022 calls `classify_failure ... skip-until-human-acts`, and
   `_pipeline_drain_skip_labels` in the continue arm drains
   `skip-until-code-changes` / `skip-until-human-acts` collectively.
   **Recommendation:** No — narrow scope to the halt label only. SEVERE
   scope-violation is operator-judgment territory and an `approve` action
   there should require `continue` (full reset) to express the operator's
   sanction of the severe violation. The `scope-approval` sentinel file
   exists only on NOTABLE; SEVERE doesn't write it.

2. **OQ-2 — should D-002 also work for an `agent-blocked` halt where the
   operator approved scope but the agent never produced a stage-summary?**
   Today `scope-approval` sentinel only gets written by the NOTABLE
   scope-violation halt (line 1972-1976). An agent-blocked halt without a
   scope-violation precedent wouldn't have the sentinel, so the replay
   gate at line 1612-1620 would not fire and the regular dispatch would
   run. **Recommendation:** No expansion. The agent-blocked case is the
   "agent stuck" recovery path documented in CLAUDE.md `pipeline:halted`
   row — `continue` is the right tool there.

3. **OQ-3 — should the `dispatch_history.jsonl` log get a synthetic row
   for the D-002 transition?** The pairing invariant requires
   start/end-row symmetry, and skip_dispatch elides both today. D-002's
   transition is a meaningful event but not a *dispatch* (no agent ran).
   **Recommendation:** No row — preserve the start-without-end invariant
   for replay. The metric `events.jsonl` row already carries the
   forensic signal. If the retrospective ever needs to count
   scope-approval replays, the `verdict=transitioned scope-approval-replay=1`
   label is the discriminator.

4. **OQ-4 — should the decision-comment post at the end of `cmd_decide`
   come BEFORE the halt-clear, so a partial-failure leaves the issue in a
   state where the decision marker exists but halt is still on (next tick
   stays halted, operator can re-run safely)?** The continue arm does the
   cleanup BEFORE the comment, so a partial-failure mid-cleanup leaves the
   issue in a half-reset state with no operator-resume marker (operator
   sees no decision comment, runs `continue` again, eventually succeeds).
   **Recommendation:** Match the continue arm's ordering (halt-clear
   before decision-comment). Re-runnable in both partial-failure shapes.
   The decision-marker-without-halt-clear shape is recoverable on a re-run
   (the next `approve --gate scope` halt-clear is idempotent); the
   halt-clear-without-decision-marker shape is also recoverable (next
   `approve --gate scope` posts the marker). Both are safe.

## Anti-bias checks

### ADR stress test

There is no formal ADR ledger at `docs/knowledge/decisions.md` (the directory
`docs/knowledge/` does not exist). The closest published invariants this change
touches are:

- **Single human-approval gate (ENG-54)** at `docs/architecture.md:233-243` —
  *"the pipeline collects human approval once, at build's P2 preflight"*.
  ENG-180 does not introduce a new human-approval gate; the scope-violation
  halt is the *existing* approval surface (already documented at
  `bin/run-stage.sh:1985-1989` and CLAUDE.md). D-001/D-002 just make the
  existing surface work. No conflict.
- **Slot-occupancy contract (ENG-90)** at `docs/architecture.md:212-231` —
  *"slot:hold, advanceable:false is not part of the contract."* D-001
  causes the issue to transition from `slot:vacate, oar=true` to
  `slot:hold, advanceable:true` (via removing the halt label, which
  drops the issue into the `stage:implementing` arm at `bin/poll.sh:380+`).
  This is within contract — no new branch added to `_poll_classify_labels`.
- **Atomic reset for `--action continue` (ENG-58 / ENG-60)** at
  `bin/pipeline.sh:498-555` — the "drain wait files, skip-until labels,
  issue-state, post operator-attributed transition waypoint" sequence.
  D-001 *deliberately does not* mirror this on `approve --gate scope`,
  per the issue's scope-narrowing directive. Operators who want the full
  reset still run `continue`. No invariant violated; the existing
  contract is extended, not weakened.
- **Cross-dispatch staleness contract (ENG-87)** at CLAUDE.md's ENG-87
  section. D-002 does not allocate `PIPELINE_DISPATCH_ID` for the replay
  (preserves the existing skip_dispatch path's elision at
  `bin/run-stage.sh:1671-1750`). `apply_transition`'s transition waypoint
  comment is therefore unmarked; that's compatible with the soft-fallback
  contract (D-005: legacy issues with no markers fall through to
  timestamp-window logic).

No ADR is overturned; no documented invariant is weakened.

### Simpler alternative

The simplest possible fix is to fully mirror the `continue` arm on
`approve --gate scope` (no D-002 needed: the operator-resume transition
posted by continue would become the most-recent transition; replay's next
tick's `find_fresh_verdict` would look for verdicts newer than that
transition; there's no fresh `pass` because the agent never ran; same
protocol-violation re-halt). So full mirroring still doesn't solve Layer
2 — D-002 is load-bearing. The "approve clears halt only" + "replay
transitions directly" pair is the minimal correct fix; either alone
leaves a known broken case.

A simpler-still option is the issue's documented workaround: tell operators
to run `apply_transition <issue> implementing reviewing` after sourcing
`bin/verdict-handler.sh`, plus `linear.sh remove-label`. Rejected because
that's the manual recovery the issue body explicitly calls "undocumented
and not operator-facing"; making it the documented path normalises a
verdict-handler internal as an operator command.

### Assumption inventory

Every item below is verified against the worktree at the file:line cited.

- `bin/pipeline.sh::cmd_decide` exists at lines 472-575 — **verified**
  (`bin/pipeline.sh:472`).
- The continue-arm halt-clear is at lines 523-525 — **verified**
  (`bin/pipeline.sh:523`).
- The continue-arm uses the issue-id sanitisation guard
  `[[ "$issue" =~ ^ENG-[0-9]+$ ]]` at line 508-509 — **verified**
  (`bin/pipeline.sh:508`).
- The decision comment post is at line 574 — **verified**
  (`bin/pipeline.sh:574`).
- `_pipeline_clear_breaker` is a sibling helper at lines 452-460 —
  **verified** (`bin/pipeline.sh:452`).
- The scope-approval replay gate is at `bin/run-stage.sh:1612-1620` —
  **verified** (`bin/run-stage.sh:1612`).
- `_replay_scope_approval` rm's `usage-<stage>.json` and emits a
  `scope-approval-replay` metric — **verified** (`bin/run-stage.sh:312-316`).
- The scope-check NOTABLE-approved branch at lines 1967-1970 fires when
  the sentinel file exists AND `has-scope-approval` returns 0 —
  **verified** (`bin/run-stage.sh:1967`).
- `_post_dispatch_apply_halt` at line 2297 re-applies `pipeline:halted`
  unconditionally (modulo the wait-shape carve-out) — **verified**
  (`bin/run-stage.sh:2297` calls helper at `bin/run-stage.sh:588-600`).
- `verdict_handler` is called at line 2314 — **verified**
  (`bin/run-stage.sh:2314`).
- `vh_stage` is resolved from the Linear label (long-form) at lines
  2304-2305 — **verified** (`bin/run-stage.sh:2304`).
- The stage-drift guard at lines 2286-2292 short-circuits when the label
  observed at line 2285 differs from `dispatched_stage_label` — **verified**
  (`bin/run-stage.sh:2286`).
- `verdict-handler.sh` is sourced at `bin/run-stage.sh:38` — **verified**
  (`bin/run-stage.sh:38`).
- `_vh_lookup_forward` is a function in `bin/verdict-handler.sh:40-43` —
  **verified** (`bin/verdict-handler.sh:40`). Not in the `export -f` list at
  line 606 (which exports the public surface `verdict_handler`,
  `find_fresh_verdict`, `find_fresh_wait_verdict`, `apply_transition`,
  `resume_in_progress_transition`), but `run-stage.sh:38` sources the
  whole file, so the underscore-prefixed helper is in scope to the caller
  without explicit export. Compatible with the D-002 call site.
- `apply_transition` is exported at `bin/verdict-handler.sh:606`,
  defined at lines 311-432, idempotent by contract (verdict-handler.sh:309-310
  comment) — **verified** (`bin/verdict-handler.sh:311`).
- `_VH_FORWARD_TRANSITIONS` table contains `implementing=ui` and `ui=reviewing` —
  **verified** (`bin/verdict-handler.sh:19-27`).
- `_vh_lookup_forward "implementing"` returns `ui`; `"ui"` returns `reviewing` —
  **verified by inspection of the awk at `bin/verdict-handler.sh:40-43`**.
- `find_fresh_verdict` filters by `.event == "verdict"` and excludes wait —
  **verified** (`bin/verdict-handler.sh:183-184` strict-id path,
  `bin/verdict-handler.sh:217-219` legacy fallback).
- `find_fresh_verdict`'s `last_transition_ts` is computed from comments
  with `.event == "transition"` only (decision markers ignored) —
  **verified** (`bin/verdict-handler.sh:206-211`).
- `find_fresh_verdict`'s strict-id path requires a non-empty
  `_curr_id` AND at least one `<!-- meta: dispatch id=` marker on the issue —
  **verified** (`bin/verdict-handler.sh:175`).
- `verdict_handler`'s empty-`find_fresh_verdict` branch routes through
  `_vh_protocol_violation`, which adds `pipeline:halted` — **verified**
  (`bin/verdict-handler.sh:52-64`, called from 538).
- `bin/scope-check.sh::has_scope_approval` returns 0 iff there's a
  decision marker with `action == "approve" && gate == "scope"`
  newer than the most recent scope-violation halt verdict — **verified**
  (`bin/scope-check.sh:221-259`).
- `bin/poll.sh::_poll_classify_labels` arms `pipeline:halted` at
  `bin/poll.sh:289-314`; with no fresh non-halt marker, classifies as
  `slot:vacate, advanceable:false, operator_action_required:true` —
  **verified** (`bin/poll.sh:289`, `bin/poll.sh:306`, `bin/poll.sh:313`).
- `pipeline-events.json::decision_gates` registers `scope` and
  `build-cap` — **verified** (`bin/pipeline-events.json:46-49`).
- `pipeline-events.json::events.verdict.linear_comment.writer_lane`
  is `"agent"` — **verified** (`bin/pipeline-events.json:90`).
- `bin/run-stage.sh` halt-comment body advertises
  `--action approve --gate scope` — **verified** (`bin/run-stage.sh:1985-1986`).
- `failure_outcome_for_exit 22` returns `pr-opened-too-early` — **verified**
  (`bin/common.sh:322`). *Caveat: D-002's defensive branch reuses exit 22; if
  that branch fires, the metric label will be `pr-opened-too-early` which
  is wrong semantically. The branch is unreachable in current control flow.
  If a future change makes it reachable, a follow-up ticket can add a
  dedicated exit code. Marked **assumed-defensive** rather than verified
  semantically — the call site is correct, only the label is misleading.*
- `bin/linear.sh::add-comment` lane-fence allows orchestrator-lane writes
  without `PIPELINE_DISPATCH_ID` (only agent-lane requires both) —
  **verified** (`bin/linear.sh:98-107`).
- `resume_in_progress_transition` re-enters mid-transition cleanly —
  **verified** (`bin/verdict-handler.sh:439-514`).
- `bin/run-stage-test.sh` case-24 D-011 fixture exercises
  `_replay_scope_approval` and asserts no cost-flags in metrics output —
  **verified** (`bin/run-stage-test.sh:649-691`).
- `bin/verdict-handler-test.sh` case-12 covers
  "decision approve gate=scope newer than scope-violation halt → handler
   still rejects pass (decision is not a verdict marker)" — **verified**
   (`bin/verdict-handler-test.sh:413-434`).
- CLAUDE.md has a "Failure-mode quick reference" table — **verified**
  (CLAUDE.md `## Failure-mode quick reference` section in the file).
- `docs/knowledge/decisions.md` does NOT exist — **verified**
  (`ls docs/knowledge/ → No such file or directory`). No ADR ledger to
  append to; no ADR proposed.

## Persona review

Six personas reviewed this brainstorm in order
design → security → scope → coherence → product → feasibility. All six
returned **PASS** with feasibility (the gating persona) reporting zero P0
findings. Summary:

| Persona | Verdict | P0 | P1 | P2 |
|---|---|---|---|---|
| design | PASS | 0 | 2 (exit-22 label mismatch; order-as-load-bearing call-out) | 2 |
| security | PASS | 0 | 0 | 1 (exit-22 label mismatch, already acknowledged) |
| scope | PASS | 0 | 0 | 2 (test count slightly high; CLAUDE.md row borderline doc creep — both defensible) |
| coherence | PASS | 0 | 2 (AC #4 dangling fixture; AC #2 idempotency gap) | 3 |
| product | PASS | 0 | 2 (CLAUDE.md row text not drafted; edge-case 3 log-line claim wrong) | 3 |
| feasibility | PASS | 0 | 2 (verdict-handler-test case 12-vs-13 line drift; case-24 start line off by 11) | 1 (`_vh_lookup_forward` "exported" attribution wrong — sourced not exported) |

P1 fixes applied in-iteration before locking the gate:

1. D-001 narrative now calls out halt-clear-before-comment-write ordering
   as load-bearing (was incidental; design P1).
2. Edge case 3 reworded to drop the non-existent "I expected this to
   proceed" log-line claim; now describes the real operator-visible
   surface (repeat halt comment + label) and points at the new
   CLAUDE.md row (product P1).
3. CLAUDE.md row text drafted inline in §Architecture (product P1).
4. AC #4 references the new SCO-REPLAY-CONTINUE-COMPOSITE fixture
   (was "extending SCO-REPLAY-FORWARD-1"); fixture added as §Testing
   item 12 (coherence P1).
5. New AC #2a covers idempotency dimension via SCO-REPLAY-IDEMPOTENT
   (coherence P1).
6. AC #9 fixture count corrected from "eight" to "eleven", with the
   per-suite split spelled out.
7. Feasibility line-drift findings resolved: verdict-handler test case
   reference corrected to case 12 / lines 413-434 (was case 13 /
   415-451); run-stage-test case-24 start line corrected to 649 (was
   660); §Architecture's file list now includes the
   `bin/verdict-handler-test.sh` edit.
8. Assumption inventory clarifies that `_vh_lookup_forward` is in
   scope via `source verdict-handler.sh` at run-stage.sh:38, not via
   the `export -f` list at line 606 (feasibility P2).

P2 nits left for plan stage (each justified in the persona notes):

- Exit-22 reuse for the D-002 defensive unknown-forward branch is
  semantically misleading (`pr-opened-too-early`); the branch is
  unreachable in current control flow, and adding a dedicated code is
  follow-up scope. Documented in §Architecture and Assumption
  inventory.
- Edge case 7's "stale `stage:*` labels survive `apply_transition`"
  observation is acknowledged out-of-scope (the design relies on
  `apply_transition`'s existing semantics without modification).
- OQ-3 (`dispatch_history.jsonl` synthetic row) could be promoted out
  of §Open questions to §Design rationale; harmless as-is.

Gate result: **5/6 PASS (in fact 6/6 PASS) AND feasibility 0 P0 →
clean gate, proceeding to planning.**

## References

- Linear ENG-180 (this issue).
- Linear ENG-113 (the 2026-06-10 reproducer).
- Linear ENG-178 (prior "resolved gate doesn't recall the slot" instance — picker).
- Linear ENG-154 / ENG-119 (prior instances — dimensional grading payloads).
- `docs/architecture.md::Slot-occupancy contract (ENG-90)` (the slot semantics
  D-001 relies on).
- `docs/architecture.md::Single human-approval gate (ENG-54)` (the
  build-stage human-approval surface — orthogonal to ENG-180).
- ENG-87 cross-dispatch staleness contract (CLAUDE.md) — the dispatch_id
  / find_fresh_verdict semantics D-002 short-circuits.
- ENG-58 / ENG-60 atomic-reset on `--action continue` (`bin/pipeline.sh`).
- ENG-18 scope-approval sentinel and `has_scope_approval` helper
  (`bin/scope-check.sh:221-259`).
- ENG-26 D-011 replay-must-omit-cost-flags contract
  (`bin/run-stage-test.sh:649-691`).
