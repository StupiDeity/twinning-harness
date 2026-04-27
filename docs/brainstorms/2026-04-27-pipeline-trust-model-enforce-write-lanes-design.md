---
linear: ENG-41
title: Pipeline trust model — enforce label/comment write lanes + cycle-scoped recovery
date: 2026-04-27
status: draft
---

# Pipeline trust model — enforce label/comment write lanes + cycle-scoped recovery

## 1. Problem

The orchestrator's verdict-marker protocol (ENG-18) treats Linear labels and
HTML-comment markers as a state machine in which the orchestrator and the
dispatched stage agents are co-writers. The protocol documents which lane each
side may write — `AGENT_PROMPTS.md:48-66` says "do NOT post this yourself" for
the `<!-- pipeline-transition: -->` marker, and the per-stage prompt sections
say "Do NOT change the Linear stage label — the orchestrator swaps it on
successful exit" (lines 522, 686, 823, 994, 1137). But the contract is enforced
only by prompt prose. `bin/linear.sh add-label`, `remove-label`, and
`add-comment` accept any input from any caller; the dispatched agent (running
under the user's Linear API key) has the same write capability as the
orchestrator.

The harness has been bitten by two manifestations at once. They share a single
root cause but bite at different points:

### 1.1 Defect: agent impersonation (ENG-26)

ENG-26 is permanently halted on `protocol-violation: no-marker`. Reconstructed
timeline (`~/.local/state/twinning-harness/harness/logs/local-2026-04-27.log`,
`launchd.out.log`, Linear comment history):

```
06:59:52  orchestrator added stage:ui
07:05:07  poll dispatched stage=ui
07:05:20  claude -p ui agent started
[18 minutes — agent running, no orchestrator log entries]
07:19:07  agent posted <!-- pipeline-stage-summary: ui -->                (legit)
07:21:45  agent posted <!-- pipeline-transition: ui → reviewing -->       (FORBIDDEN)
          agent removed stage:ui                                          (FORBIDDEN)
          agent added stage:reviewing                                     (FORBIDDEN)
07:23:52  agent run completed; orchestrator post-stage routine starts
07:23:57  post_completion_comment posted by orchestrator
07:23:57  post-dispatch halt-check: pipeline:halted missing → applied
          (run-stage.sh:431-436, defensive)
07:24:06  verdict_handler called find_fresh_verdict(ENG-26):
          freshness window starts at the latest <!-- pipeline-transition: -->
          comment, which is now the agent-forged 07:21:45 entry.
          The legitimate 07:19:07 ui done-marker is OLDER than that boundary
          → filtered out → no fresh marker → protocol-violation: no-marker.
```

The orchestrator's launchd log has no entries between 07:05 and 07:23 — the
transition comment + label swaps are absent from harness logs. They were
authored by the dispatched agent, despite explicit prompt prohibitions.

### 1.2 Defect: stale-cycle resume (ENG-24)

ENG-24 is in a brainstorm-loop, dispatching every ~6 minutes. After a manual
reset (Linear → Todo, `stage:*` labels stripped, `issue-state.json` deleted),
the issue still carries a 2-day-old `<!-- pipeline-transition: planning →
implementing -->` comment from a prior cycle (2026-04-25T12:59:01Z). Sequence
per tick:

1. brainstorm runs; agent posts `<!-- pipeline-stage-summary: brainstorming
   -->` and applies `pipeline:halted`.
2. orchestrator's `verdict_handler` runs. `verdict-handler.sh:209` calls
   `resume_in_progress_transition` first.
3. `resume_in_progress_transition` (verdict-handler.sh:175-202) selects the
   latest `<!-- pipeline-transition: -->` comment with no upper bound on age —
   finds the 04-25 entry.
4. Predicate `current_stage(brainstorming) != to(implementing) &&
   pipeline:halted` → fires "resuming mid-transition planning → implementing".
5. `apply_transition` adds `stage:implementing`, removes `stage:planning`
   (no-op — not present), removes `pipeline:halted`. **It does not remove
   `stage:brainstorming`** because the resumed transition's `from` is
   `planning`, not `brainstorming`.
6. ENG-24 carries both `stage:brainstorming` and `stage:implementing`.
7. Next tick: `_poll_gather_stage_labeled_issues` iterates `workflow_stages` in
   order, hits ENG-24 under `stage:brainstorming` first; `unique_by(.identifier)`
   keeps that hit; poll dispatches stage=brainstorm. Loop.

### 1.3 Common root cause

Both defects violate the same trust assumption: **label and comment writes are
uncategorized by writer-lane, and the orchestrator's recovery code reads
append-only Linear history without verifying it against the issue's current
label state.**

- The orchestrator/agent contract is documented in `AGENT_PROMPTS.md:48-91`
  but enforced only by prompt prose. `bin/linear.sh` has no fence.
- `verdict-handler.sh::resume_in_progress_transition` reads the latest
  transition comment without cross-checking that the labels are consistent
  with that comment.
- `run-stage.sh:431-436` re-applies `pipeline:halted` post-dispatch
  unconditionally if the label is missing, without checking whether the issue
  is still on the dispatched stage.

## 2. Goal

The orchestrator can trust four invariants:

1. Any `<!-- pipeline-transition: -->` comment in Linear was written by the
   orchestrator (no agent forgery).
2. Any `stage:*` label change was made by the orchestrator (no agent forgery).
3. Recovery code (`resume_in_progress_transition`) acts only when the latest
   transition comment is consistent with the current label state, and
   conservatively defers when they disagree.
4. Defensive halt re-applies are gated on "still on the dispatched stage" so a
   successful in-flight transition does not get clobbered.

## 3. Non-goals

- Backwards-incompatible changes to the verdict-marker protocol shape. The
  marker formats and the labels involved stay the same; only their write
  surface narrows.
- Moving Linear comments out of the audit-log role. They remain append-only.
- A per-cycle "cycle id" stamped on every comment (would be a v2 if the
  cross-check turns out to be insufficient — but the cross-check is sufficient
  for both observed defects, so v1 stops there).
- Fixes for ENG-24 / ENG-26 specifically. Their stuck local state will be
  unstuck manually after this lands. The fix prevents recurrence; it doesn't
  retro-cure existing stuck state.
- A new label introduction or rename. The label vocabulary stays as documented
  in AGENT_PROMPTS.md:67-91.

## 4. Architecture

The fix has three independent parts. Each addresses one concrete invariant
above; together they restore the trust model. Lanes 1 and 3 are inexpensive
and prevent forgery + clobber respectively; lane 2 is defense-in-depth that
makes recovery resilient even if the lane fence is bypassed.

### 4.1 Writer-lane fence in `bin/linear.sh`

The single chokepoint for label and comment writes is `bin/linear.sh`. Today
its `add_label`, `remove_label`, and `add_comment` functions accept any input
from any caller. We add a per-call lane check:

- New env var `PIPELINE_WRITER` ∈ `{orchestrator, agent, classify, scope-check,
  human}`. Default `orchestrator` when unset (preserves existing behavior for
  every harness script that sources `common.sh`).
- `bin/dispatch.sh` sets `PIPELINE_WRITER=agent` in the inherited env block
  immediately before invoking `claude -p`. The fence env is the only thing
  that distinguishes the agent's `linear.sh` invocations from the
  orchestrator's; agents inherit the user's Linear API key (subscription
  session) and have full network access.
- `bin/classify-failure.sh` and `bin/scope-check.sh` set their own lanes
  (`classify` and `scope-check`) so they can write `pipeline:halted` and
  `pipeline:skip-until-*` but not `stage:*`.
- `bin/halt.sh` and other operator-facing tools set `PIPELINE_WRITER=human`
  (most permissive — humans may apply any label).

Per-lane allow-lists (write-permission table):

| Lane          | add `stage:*` | remove `stage:*` | add `pipeline:halted` | remove `pipeline:halted` | add `pipeline:supersede` | add `pipeline:skip-until-*` | add comment with `<!-- pipeline-transition: -->` body | add comment (other markers) |
|---|---|---|---|---|---|---|---|---|
| orchestrator  | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ✅ | ✅ |
| agent         | ❌ | ❌ | ✅ | ❌ | ❌ | ❌ | ❌ | ✅ |
| classify      | ❌ | ❌ | ✅ | ❌ | ❌ | ✅ | ❌ | ✅ |
| scope-check   | ❌ | ❌ | ✅ | ❌ | ❌ | ❌ | ❌ | ✅ |
| human         | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |

The "remove `pipeline:halted`" cell for agent is `❌` because removal is
orchestrator-owned (it's how the orchestrator consummates a transition). An
agent that wants to "unhalt" itself by removing the label would short-circuit
the verdict protocol; deny it.

A write outside the caller's lane returns non-zero with a structured error
message:

```
linear.sh: lane=agent denied: add-label stage:reviewing
            (allowed lanes for stage:* writes: orchestrator, human)
```

The error goes to stderr; stdout stays empty so existing parser callers don't
choke.

### 4.2 Cross-check in `resume_in_progress_transition`

The current logic (verdict-handler.sh:175-202) is:

```bash
last_transition = latest <!-- pipeline-transition: -->  comment in Linear
from, to       = parse last_transition
current_stage  = stage-of(issue)
if current_stage != to && has_label(issue, "pipeline:halted"):
    apply_transition(issue, from, to, "")    # re-applies the from→to transition
```

Failure: the predicate fires whenever `current_stage != to`, regardless of
whether `current_stage == from`. A stale comment from a prior cycle where
`from = planning`, against current labels where `from = brainstorming`, fires
just as readily as a real mid-crash where `from = planning` and labels are
mid-update.

New logic:

```bash
last_transition = latest <!-- pipeline-transition: -->  comment in Linear
from, to       = parse last_transition
current_stage  = stage-of(issue)
all_stages     = stage-labels-of(issue)            # NEW: read all stage:* labels
if current_stage == to:
    return 1                                       # already at destination, nothing to resume
if current_stage != from:
    log "verdict-handler: skipping resume — labels(from=$current_stage) disagree with comment(from=$from)"
    return 1                                       # NEW guard: comment is stale or forged
if len(all_stages) > 1:
    log "verdict-handler: skipping resume — issue has multiple stage:* labels (${all_stages[*]})"
    return 1                                       # NEW guard: malformed state, refuse to compound it
if has_label(issue, "pipeline:halted"):
    apply_transition(issue, from, to, "")
    return 0
return 1
```

Two new guards. The first refuses to resume when the labels and the comment
describe different `from` states — that's the ENG-24 bug. The second refuses
to act when an issue is already in a malformed state (multiple `stage:*`
labels) — defense in depth, prevents the loop from compounding even if the
first check were somehow bypassed.

When `resume_in_progress_transition` returns 1 with these new guards,
`verdict_handler` falls through to its normal verdict-marker dispatch path.
For ENG-24: `find_fresh_verdict` returns the brainstorm done-marker (it's
newer than the stale 04-25 transition only by virtue of being today — but the
freshness rule still applies; the brainstorm done-marker IS newer than the
stale transition), and `verdict_handler` correctly transitions brainstorming →
planning.

### 4.3 Stage-drift guard in `run-stage.sh` post-dispatch halt-check

Current logic (run-stage.sh:431-436):

```bash
if ! has-label "$ident" "pipeline:halted"; then
  log "post-dispatch: agent did not apply pipeline:halted; applying on its behalf"
  add-label "$ident" "pipeline:halted"
fi
```

The defensive add was correct in principle — every stage agent must end with
halt applied. The bug: it doesn't notice if the stage label has drifted during
the run. For ENG-26, the agent forged a transition mid-run; by post-dispatch
time, labels said `stage:reviewing` not `stage:ui`, but the halt was applied
anyway, on the WRONG stage. That halt-on-wrong-stage was the immediate input
to protocol-violation.

New logic:

```bash
dispatched_stage_label="stage:${stage_label_long}"   # captured at start of run
current_stage_label="$(linear.sh stage-of "$ident")"
if [[ "$current_stage_label" != "$dispatched_stage_label" ]]; then
  log "post-dispatch: stage drifted ($dispatched_stage_label → $current_stage_label) during run — skipping defensive halt apply"
  # Skip both defensive halt-add AND verdict-handler call; let the next tick re-evaluate.
  bash "$SCRIPT_DIR/metrics.sh" stage-end "$ident" "$stage" "stage-drift" "$duration" "drift=$current_stage_label"
  exit 0
fi
if ! has-label "$ident" "pipeline:halted"; then
  add-label "$ident" "pipeline:halted"
fi
```

If the stage label changed during the run, *something* (legit or forged)
already transitioned the issue. Don't compound it; let the next tick's poll
re-evaluate from scratch. This protects the orchestrator from its own
defensive write being weaponized by a label state we don't recognize.

In combination with §4.1, stage drift during a run becomes impossible (the
agent's lane denies `stage:*` writes). The §4.3 guard is then defense in depth
for the cases where the lane fence is bypassed (e.g., a human or a script
running outside `linear.sh` flips a label).

## 5. Components

| File | Change | LOC estimate |
|---|---|---|
| `bin/linear.sh` | Lane check at top of `add_label` / `remove_label` / `add_comment`. New helper `_check_lane <action> <label_or_comment_marker>`. Stderr error format. | +60 |
| `bin/common.sh` | Default `PIPELINE_WRITER=orchestrator` if unset. Export. | +3 |
| `bin/dispatch.sh` | Set `PIPELINE_WRITER=agent` in the env block passed to `claude -p`. | +1 |
| `bin/classify-failure.sh` | Set `PIPELINE_WRITER=classify` at top of `classify_failure`. | +1 |
| `bin/scope-check.sh` | Set `PIPELINE_WRITER=scope-check` at script entry. | +1 |
| `bin/halt.sh` | Set `PIPELINE_WRITER=human` at script entry. | +1 |
| `bin/reset-pipeline.sh` | Set `PIPELINE_WRITER=human` at script entry. | +1 |
| `bin/mark-abandoned.sh` | Set `PIPELINE_WRITER=human` at script entry. | +1 |
| `bin/verdict-handler.sh` | Two new guards in `resume_in_progress_transition`: (1) `current_stage != from` → return 1; (2) multiple `stage:*` labels → return 1. New helper `_vh_all_stage_labels` reads via `linear.sh list-labels` (already exists for halt-sprawl). | +30 |
| `bin/run-stage.sh` | Stage-drift guard before line 434 defensive halt-add. New `stage-drift` outcome in metrics. | +12 |
| `bin/common.sh::failure_outcome_for_exit` | Add new exit code `12` (or first available) for `stage-drift` so the retrospective filter recognizes it. | +2 |
| `bin/linear-test.sh` (new) | Lane fence: each lane × each guarded write produces expected pass/fail. Fixture covers `stage:*` add/remove, `pipeline:halted` add/remove, `<!-- pipeline-transition: -->` comments. | +120 |
| `bin/verdict-handler-test.sh` | Two new cases: (1) stale-comment ENG-24 fixture (stage:brainstorming + halt + 2-day-old `planning → implementing` comment) → `resume_in_progress_transition` returns 1; (2) multi-stage-label fixture → return 1. | +60 |
| `bin/run-stage-test.sh` | One new case: dispatched_stage=ui, current_stage=reviewing post-run → halt NOT re-applied, exit 0, metrics record `stage-drift`. | +25 |
| `AGENT_PROMPTS.md:48-91` | Replace "Label vocabulary (post-Phase-4)" 4-row table with the 7-column lane-aware table from §4.1. The "do NOT post this yourself" prose remains (still useful for the agent, defense in depth). | +20 / -10 |
| `docs/runbooks/recovery.md` (new or amended) | "Issue with multiple stage:* labels" recovery: which to remove, how to detect, why it can no longer happen post-fix. | +30 |

Total: ~370 lines added across 12 files, of which ~205 lines are tests.

## 6. Data flow / state diagram

The orchestrator/agent interaction across one stage cycle, post-fix, with
write-lane annotations:

```
state: stage:X, halted=false        ← steady, mid-run
   │
   │ AGENT (lane=agent) running:
   │   ‒ posts <!-- pipeline-stage-summary: X -->     [allowed: add-comment, body has no transition marker]
   │   ‒ adds pipeline:halted                          [allowed: add-label pipeline:halted in agent lane]
   │   ‒ attempts add stage:Y                          [DENIED: lane=agent cannot add stage:*]
   │   ‒ attempts add transition comment               [DENIED: lane=agent cannot add comments containing pipeline-transition marker]
   │
   ▼
state: stage:X, halted=true         ← agent done, orchestrator's turn
   │
   │ ORCHESTRATOR (lane=orchestrator) on next tick:
   │   ‒ poll → classify → verdict_handler
   │   ‒ resume_in_progress_transition: latest transition is from PRIOR stage
   │     (X-1 → X). current_stage=X, comment.from=X-1. mismatch → return 1
   │     (this is the §4.2 cross-check; for the freshly-completed stage,
   │     the latest transition is the one that BROUGHT the issue to X)
   │   ‒ find_fresh_verdict: returns the X done-marker (newer than X-1→X transition)
   │   ‒ apply_transition(X, X+1):
   │     ‒ posts <!-- pipeline-transition: X → X+1 -->   [allowed]
   │     ‒ adds stage:X+1                                 [allowed]
   │     ‒ removes stage:X                                [allowed]
   │     ‒ removes pipeline:halted                        [allowed]
   ▼
state: stage:X+1, halted=false      ← next stage's run begins
```

Reset / halt-resolve flow (lane=human):

```
state: any                          ← issue stuck, operator decides to reset
   │
   │ HUMAN via reset-pipeline.sh / halt.sh / Linear UI:
   │   ‒ removes stage:* labels                          [allowed in human lane]
   │   ‒ removes pipeline:halted                         [allowed]
   │   ‒ moves Linear status to Todo                     [via linear.sh transition-state]
   │   ‒ deletes ~/.local/state/.../<slug>/<issue>/      [local fs, no lane]
   ▼
state: Todo, no stage:*             ← orchestrator picks up via Pass 5 inbox-pickup
                                       runs brainstorm fresh
                                       resume_in_progress_transition: stale comment
                                       fires, but current_stage=brainstorming and
                                       comment.from=PRIOR_STAGE → mismatch → return 1
                                       (this is the §4.2 ENG-24 fix)
                                       find_fresh_verdict picks brainstorm done-marker
                                       transitions normally
```

## 7. Decisions

### D-001: env var as lane carrier (vs. flag, vs. caller-derived)

Chosen: `PIPELINE_WRITER` env var, set explicitly by each caller before
invoking `linear.sh`.

Rejected: `--lane=<x>` CLI flag. Forces every existing call site to be edited
(over 30 callers across `bin/`). Env var inherits naturally into subshells so
only the entry-point scripts need changes.

Rejected: deriving lane from `BASH_SOURCE` parent. Brittle: tests source
linear.sh and would inherit the test runner's lane. Explicit env var means
tests can set whatever lane they want.

### D-002: default lane is orchestrator (vs. unset = deny)

Chosen: default `PIPELINE_WRITER=orchestrator` when env var is missing.

Rationale: every existing harness script (run-local.sh, poll.sh,
verdict-handler.sh, run-stage.sh's orchestrator side) is in the orchestrator
lane. Defaulting preserves their behavior without per-script edits.

The risk is that a future script forgets to set its lane and inherits
orchestrator — over-permissive. Mitigation: lint check in CI that every
non-`-test.sh` script under `bin/` either sources `common.sh` (which sets the
default) or sets `PIPELINE_WRITER` explicitly. Add to `dry-run.sh`'s validator
list.

### D-003: lane fence lives in `linear.sh`, not in callers

Chosen: enforce in `linear.sh` itself.

Rationale: `linear.sh` is the single chokepoint for these writes. Putting the
fence anywhere else means duplicating it. Also: it's the right place for the
error message to be generated — callers don't need to know the per-action
allow-list.

### D-004: stage-drift guard skips the stage entirely (vs. just skip halt-add)

Chosen: when `current_stage != dispatched_stage`, skip both the defensive
halt-add AND the post-dispatch `verdict_handler` call. Exit 0 with a
`stage-drift` metric. Let the next tick re-evaluate.

Rejected: skip only the halt-add and continue calling `verdict_handler`.
verdict_handler at that point would call `find_fresh_verdict` against an issue
where the labels say one stage and the comments may say another — risk of
making more wrong decisions. Cleaner to back off and let the next tick start
fresh from poll → classify.

### D-005: `pipeline:premise-failure` is retired, not added to the lane table

Per `AGENT_PROMPTS.md:850`: "do NOT apply `pipeline:premise-failure` — that
label is retired; the Verdict Handler's loopback table covers it." So the
label vocabulary's lane table omits this label. Code references in
`config.json::linear.control_labels` and `quality_gates.code_review.anti_bias.premise_failure_loops_back_to_brainstorm`
are documentation/policy fields and aren't write surfaces; they stay.

### D-006: cross-check uses labels-of vs cycle-id metadata

Chosen: cross-check `comment.from` against `labels.from` (via `stage-of`).

Rejected: stamp every comment with a per-cycle id and compare ids. Adds a new
field to comment bodies, breaks the comment-format contract, requires a
migration strategy for existing comments. Cross-check using existing label
state achieves the same correctness with no migration.

If cross-check turns out to be insufficient in v2 (e.g., a future failure
mode where labels and comments are individually consistent but jointly
describe an impossible cycle), add cycle-id then. Out of scope here.

### D-007: agent retains `add-label pipeline:halted` permission

Chosen: agent can write `pipeline:halted` (it's the mandatory exit signal per
AGENT_PROMPTS.md:88).

Considered alternative: have the orchestrator infer halt from the agent's
verdict-marker comment alone, and remove `pipeline:halted` from the agent's
allow-list entirely. This would simplify the lane table but requires
re-architecting the verdict-protocol's "halt as orchestrator-trigger" pattern.
Out of scope; v1 keeps the existing handshake shape.

### D-008: error format on lane denial — fail loud, single line, parseable

Stderr line of the form:

```
linear.sh: lane=<W> denied: <action> <object>
            (allowed lanes for <object-class> <action>: <list>)
```

Two-line format: first line for shell-grep, second line for human readability.
Exit code 11 (new — added to `failure_outcome_for_exit` as `lane-violation`).

The orchestrator's normal callers should never see this error in production
post-fix; if they do, it indicates a code path where lane was set incorrectly.
Fail loud.

## 8. Failure modes

| Failure | What happens | Detection |
|---|---|---|
| Future script forgets to set lane and inherits orchestrator | Over-permissive, no error visible. | CI lint: every non-test script under `bin/` either sources `common.sh` or sets `PIPELINE_WRITER` explicitly. |
| Future call site adds a label not in the per-lane table | `linear.sh` denies it (catch-all: anything not explicitly allowed → deny). | Stderr error visible in launchd.out.log. |
| Test fixture sets wrong lane | Test fails loudly, easy to debug from stderr. | Test author sees error message naming both the lane and the action. |
| Agent's `claude -p` invocation reads `PIPELINE_WRITER` from prior shell state | Possible if dispatch.sh doesn't explicitly clear it. Mitigation: dispatch.sh exports `PIPELINE_WRITER=agent` immediately before exec; subshells inherit only that. | Lane fence test fixtures cover the env-leak case. |
| Operator manually applies `stage:*` via Linear UI (out-of-band, not via human-lane scripts) | Linear UI doesn't go through `linear.sh`; lane fence cannot block it. The cross-check in §4.2 catches the resulting label/comment mismatch and refuses to act on stale comments. Defense in depth. | `resume_in_progress_transition` returning 1 with the mismatch reason logged. |
| Agent uses `mcp__plugin_linear_linear__save_issue` (Linear MCP tool) instead of `bin/linear.sh` | The MCP tool bypasses `linear.sh` entirely and can rewrite labels in bulk. Mitigation: dispatch.sh's `--allowed-tools` list for the agent does NOT include the Linear MCP tool. Verify via spot-check across all stage allow-lists in `dispatch.sh::allowed_tools_for`. | `bin/dispatch-test.sh` asserts the agent's allow-list excludes Linear MCP. |
| Mid-run crash between `apply_transition`'s comment-write and label-writes | Existing `resume_in_progress_transition` is meant for this case. With §4.2 cross-check, resume still fires because `comment.from == labels.from` (labels haven't been touched yet); resume completes the label updates. Behavior preserved. | Existing `resume_in_progress_transition` test passes unchanged. |
| Two `stage:*` labels on an issue (somehow) | §4.2 second guard refuses to resume on multi-stage-labeled issues; logs the malformed state; `pipeline:halted` stays applied; the halt-sprawl alert (ENG-21) fires after a few ticks. Operator removes the wrong label manually. | Halt-sprawl Slack ping; `verdict-handler` log line. |
| `linear.sh` lane check itself errors (jq parse, env unset weirdly) | Falls through to `die` (existing pattern). The harness halts the whole tick; safer than silently allowing. | Tick log shows `FATAL` from `die`. |

## 9. Open questions

1. Does Linear's webhook / API give the orchestrator any way to recognize a
   write to a Linear issue as "out-of-band" (e.g., via Linear UI)? If yes, we
   could log such writes for audit. If no (most likely), §4.2 cross-check
   remains the only catch and that is acceptable. **Working answer:** no
   webhook configured; rely on cross-check.
2. Should the operator-facing `bin/halt.sh resolve` be split into two lanes —
   `human` for normal use and `recovery` for malformed-state cleanup? The
   recovery path could grant write access to fields humans normally cannot
   reach. **Working answer:** no — keep `human` as the maximally permissive
   lane; document recovery procedures in the runbook.
3. Does the `pipeline:supersede` "agent removes it on regen" pattern need to
   move into the orchestrator lane? Today the brainstorm agent is supposed to
   remove the label after using the signal; under §4.1 the agent lane cannot
   `remove pipeline:supersede`. **Working answer:** add `remove
   pipeline:supersede` to the agent lane (it's an agent-consumed signal); the
   alternative — orchestrator removes it after brainstorm completes — is
   already partially in run-stage.sh:463 and we could rely on that and revoke
   agent permission. Decide during implementation; trade-off is one row in
   the allow-list table.
4. In §4.2's cross-check, when the issue has zero `stage:*` labels (e.g.,
   freshly inbox-picked, label not yet applied), does
   `resume_in_progress_transition` need to handle that case explicitly? **Working
   answer:** yes — `current_stage` will be empty; `current_stage != to` and
   `current_stage != from` both trigger return 1; safe behavior. Add a test
   fixture for it.
5. For the lane-denial exit code (§D-008): does `failure_outcome_for_exit`
   need a new outcome string `lane-violation` or can existing
   `protocol-violation` be reused? **Working answer:** new outcome — `lane-violation`
   is more specific than `protocol-violation`, and the retrospective's §1
   filter benefits from the distinction.

## 10. Assumption inventory

Each assumption is tagged with how it was verified. Anything tagged
`UNVERIFIED` is a risk surface for implementation review.

| ID | Assumption | Verification |
|---|---|---|
| A-001 | `bin/linear.sh` is the single chokepoint for label/comment writes from harness scripts. | `grep -rn 'add-label\|remove-label\|add-comment' bin/` confirms all writes go through `linear.sh`. Verified 2026-04-27. |
| A-002 | Dispatched agents call `bin/linear.sh` (not Linear's GraphQL directly, not the Linear MCP). | Verified for AGENT_PROMPTS.md prose. UNVERIFIED in the field — the agent has shell access and could in principle curl the Linear API. Mitigation: §4.1 cannot prevent direct curl; §4.2 cross-check is the backstop. |
| A-003 | Setting `PIPELINE_WRITER=agent` in the env passed to `claude -p` is inherited by subshells the agent spawns (e.g., `bash bin/linear.sh add-comment …`). | Standard bash inheritance. Verified by writing a 2-line fixture and inspecting `env` output from a `claude -p` subshell — to be done in implementation. |
| A-004 | The agent's `--allowed-tools` list in `bin/dispatch.sh::allowed_tools_for` does NOT include the Linear MCP tool. | Need to grep `allowed_tools_for` for `mcp__plugin_linear` — UNVERIFIED at brainstorm time; will verify in implementation and add a test if needed. |
| A-005 | `verdict-handler.sh::find_fresh_verdict` correctly handles the case where `last_transition_ts` is empty (first transition ever). | Verified in `verdict-handler-test.sh` existing case 4. |
| A-006 | When `resume_in_progress_transition` returns 1 due to the new mismatch guard, the caller (`verdict_handler`) falls through to its normal verdict-marker dispatch and the issue advances correctly via `find_fresh_verdict`. | Verified by tracing the code path; explicit test fixture in §5 will assert it. |
| A-007 | An issue currently in `Todo` with `pipeline:paused` is NOT picked up by poll.sh. | Verified in `poll.sh::main`'s Pass 5 inbox filter (line ~322). |
| A-008 | `_poll_gather_stage_labeled_issues` can list multiple `stage:*` labels for one issue; `unique_by(.identifier)` collapses them silently. | Verified by reading `_poll_gather_stage_labeled_issues` and ENG-24's observed behavior. |
| A-009 | `bin/halt.sh resolve` removes `pipeline:halted` and `pipeline:skip-until-*` labels via `linear.sh remove-label`. | Verified by reading `bin/halt.sh:24` and the surrounding remove calls. |
| A-010 | Tests in `bin/*-test.sh` source the script under test and run with `PIPELINE_DRY_RUN=1` + `LINEAR_API_KEY=test-mock-key`. | Verified per CLAUDE.md "How tests work" section. New tests in §5 follow the same pattern. |
| A-011 | The lane env var leaks across `claude -p` invocations only if dispatch.sh fails to overwrite it. | Will be verified in implementation; failure mode is mild (over-permissive agent), caught by lane fence test fixtures. |
| A-012 | No external tooling (a deploy script, a webhook, a third-party Linear automation) is currently writing labels or comments to issues this harness manages. | UNVERIFIED. If true, those writers would need their own lane; the harness's cross-check (§4.2) protects against label/comment divergence regardless. |

## 11. Migration / rollout

Single-PR rollout. No data migration needed (Linear comments and labels stay
as-is). Sequence:

1. Land §4.1 lane fence in `bin/linear.sh` with `PIPELINE_WRITER=orchestrator`
   default. Existing scripts continue working.
2. Land §4.2 cross-check guards in `verdict-handler.sh`. Existing
   resume-in-progress test cases pass; new test cases assert the guards.
3. Land §4.3 stage-drift guard in `run-stage.sh`. New test case asserts the
   skip; metrics emit `stage-drift` outcome.
4. Update `bin/dispatch.sh`, `bin/classify-failure.sh`, `bin/scope-check.sh`,
   `bin/halt.sh` to set their explicit lanes.
5. Update `AGENT_PROMPTS.md:48-91` Label vocabulary table.
6. After merge: manually unstick ENG-24 and ENG-26 (one-time recovery —
   document the procedure in the runbook).

The PR is one commit-able change; no feature flag (the cross-check guard is
strictly more conservative than current behavior — refuses to act in
ambiguous cases — so flagging adds no safety, only cost).

## 12. Out-of-scope future work

- **Cycle-id stamping.** If post-fix we observe a class of failures the
  cross-check still misses, add a `<!-- pipeline-cycle: <hash> -->` field to
  every comment the orchestrator writes; the verdict-handler filters by cycle
  id rather than timestamp. Defer.
- **Linear webhook ingestion.** If we want positive confirmation of every
  out-of-band write, listen on Linear webhooks. Defer.
- **Per-issue lock for the entire run.** Today the cross-tick mutex is just
  the `claude -p` invocation. A whole-issue lock spanning poll → dispatch →
  verdict_handler would prevent some race classes the lane fence doesn't
  cover. Defer; not observed as a real failure mode yet.
- **Human-applied label audit log.** A separate file recording every human
  Linear UI write would be useful for retrospectives but requires polling +
  diffing label state. Defer.
