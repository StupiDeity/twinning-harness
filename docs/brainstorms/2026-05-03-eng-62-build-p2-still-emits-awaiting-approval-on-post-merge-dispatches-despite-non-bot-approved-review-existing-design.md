---
linear: ENG-62
title: Build P2 still emits awaiting-approval on post-merge dispatches
date: 2026-05-03
status: draft
---

# ENG-62 — Build P2 emits awaiting-approval on post-merge dispatches despite a non-bot APPROVED review existing

## 1. Problem

The build agent's `AGENT_PROMPTS.md` §7 P2 precondition (refactored in
ENG-54 / commit 941218f9) checks for a non-bot APPROVED review by reading
the per-review array, not GitHub's brittle `reviewDecision` summary:

```
gh pr view <N> --json reviews --jq \
  '[.reviews[] | select(.state == "APPROVED" and (.author.login | test("\\[bot\\]$") | not))] | length >= 1'
```

This is correct in principle — `reviewDecision` is cleared to empty by
GitHub once a PR is merged, while individual `reviews[]` entries
persist. **Yet during the 2026-05-02 SDLC observation run, the wait-loop
symptom persisted on multiple post-merge dispatches** for both ENG-43
(PR #41) and ENG-58 (PR #42), with each dispatch costing ≈ $1.50 of
agent time. ENG-43 wasted five post-merge dispatches over ~67 min; ENG-58
wasted five more before an operator manually flipped the stage label.
Total observed cost across the session: ≈ $22 in agent spend on dispatches
that should have been zero-cost orchestrator transitions.

### 1.1 Why the symptom recurs after the prompt was already fixed

The orchestrator currently has no pre-dispatch awareness of merge state.
The flow for stage `building` is:

```
poll.sh: stage:building, no pipeline:halted, no fresh verdict marker
       → _poll_classify_labels else branch (poll.sh:266) → hold, advanceable=true
run-stage.sh: render-prompt + dispatch.sh → build agent runs P1..P7
            → agent emits <!-- pipeline: verdict result=wait reason=awaiting-approval -->
            → run-stage.sh's _fresh_wait_reason gate (run-stage.sh:702)
              detects the wait, _handle_wait increments the counter,
              orchestrator exits 0 (no pipeline:halted applied per the
              wait-shape carve-out at run-stage.sh:362-367).
next tick: same triple → re-dispatch → repeat until the budget
            (config.orchestrator.external_signal_budget) exhausts and
            _handle_wait posts external-signal-budget-exhausted halt,
            OR until on-new-release.sh's release-tag sweep
            (on-new-release.sh:25-58) sweeps the issue to stage:released.
```

The orchestrator dispatches the agent on every tick because the wait-shape
verdict (by ENG-45 design) does NOT trigger `pipeline:halted` and does NOT
appear in `find_fresh_verdict`'s recognised set
(`bin/verdict-handler.sh:113`, `[[ result == "wait" ]] && continue`).
That carve-out is correct for the pre-merge wait case (the agent's own
re-dispatch contract). It is wrong for the post-merge case, where the
agent's emission of `awaiting-approval` is itself the bug — but the
orchestrator has no way to tell the two cases apart from the marker
alone.

### 1.2 Why the agent emits `awaiting-approval` post-merge

The most plausible root cause is **agent prompt-following regression**
(Hypothesis 3 in the Linear issue). Post-merge:

- `gh pr list --head <branch> --state open` returns 0 PRs (P1 should
  fail). Per the precondition-ordering clause at `AGENT_PROMPTS.md:1208-1211`,
  P1 fail must halt-for-human, not wait. The agent does not honour this.
- `gh pr view <N> --json reviewDecision` (the *brittle* path the prompt
  was rewritten to avoid) returns empty for a merged PR — agents often
  fall back to it from training-data habit.
- `gh pr view <N> --json reviews` (the *correct* path the prompt
  prescribes) still returns the historical reviews array, with the
  APPROVED non-bot entry intact. An agent that follows the prompt
  literally would see P2 pass.

Hypotheses 1 (P5 mislabelling its wait reason as `awaiting-approval`)
and 2 (`_handle_wait` short-circuiting agent re-execution) are
disproved by code inspection:

- The current §7 P5 wait emits `verdict wait --reason awaiting-ci`
  (`AGENT_PROMPTS.md:1268`). The agent emits `awaiting-approval` — that
  reason is only on P2's wait path.
- `_handle_wait` (`bin/run-stage.sh:381-470`) bumps a counter and writes
  `wait-building.json`. It never suppresses dispatch on the next tick;
  the agent runs fresh every tick. The counter file is invisible to
  `dispatch.sh` and to the rendered prompt.

So the bug is **in the agent's actual evaluation**, which we cannot
reliably patch from prompt text alone — observed evidence: prompt was
rewritten in commit 941218f9 to use `reviews[]`, yet the symptom still
recurred on 2026-05-02. This brainstorm therefore moves the load-bearing
fix to the orchestrator.

### 1.3 Why on-new-release.sh's sweep is not enough

`bin/on-new-release.sh:25-58` already flips stuck `stage:building`
issues to `stage:released` when a new release tag is published. But:

- The sweep fires only when a downstream release pipeline publishes a
  tag (`bin/run-local.sh:379` → release watcher), which can be hours
  after merge or never (if the project profile has no release workflow,
  per `AGENT_PROMPTS.md:1339-1342`).
- Until the sweep fires, the orchestrator wastes one agent dispatch per
  tick (5 min) — the documented $1.20–$1.80 each.
- The cost regression is therefore unbounded by anything cheaper than
  the next release tag publication.

The sweep is a backstop; it is not the cost-recovery mechanism.

## 2. Decisions

- **D-001. Pre-dispatch merge-detection gate in `bin/run-stage.sh::main`,
  stage-gated to `building`.** Before rendering the prompt, the
  orchestrator queries `gh pr list --head <branch> --state all --json
  state --jq '.[0].state // ""'`. If the value is `MERGED`, the gate:
  1. Writes a minimal `stage-summary-building.md` file in the issue dir
     for retrospective archaeology.
  2. Removes `wait-building.json` and `issue-state.json` (success-path
     semantics — same files cleared at `bin/run-stage.sh:852-853`).
  3. Calls `apply_transition "$ident" "building" "released" ""`
     directly (sourced from verdict-handler.sh at `run-stage.sh:21-22`).
     This is the orchestrator-canonical shape: the gate KNOWS the
     transition it wants, posts a single `<!-- pipeline: transition
     from=building to=released -->` waypoint via apply_transition's
     step 1, and applies the label swap. There is NO verdict marker
     round-trip (rejected after design review P1 — see "rejected
     alternative" below).
  4. Emits a `merged-pre-dispatch` outcome via `metrics.sh stage-end`
     and `exit 0`.

  *Why pre-dispatch (not post-dispatch override):* the load-bearing
  goal is **eliminating the agent dispatch cost**. A post-dispatch
  override (read merge state after the agent already ran, override its
  wait verdict to pass) saves nothing — the $1.50 has already been
  spent. The gate must run BEFORE `dispatch.sh`.

  *Why `--state all` (not `--state open`):* `gh pr merge ... --auto
  --delete-branch` deletes the branch ref post-merge, so `--state open`
  silently returns 0 PRs even though the merged PR record persists.
  `--state all` returns the merged record — the only path that
  surfaces the load-bearing `MERGED` value.

  *Why call `apply_transition` directly (not "post pass marker, then
  call verdict_handler"):* the orchestrator gate is the AUTHOR of this
  transition; making it synthesize a `verdict pass --stage building`
  marker so verdict_handler can read it back through Linear is
  orchestrator-talks-to-Linear-about-itself overhead. The marker
  contract exists for AGENT → ORCHESTRATOR signalling; the orchestrator
  is not its own audience here. Calling `apply_transition` directly
  posts exactly one `pipeline: transition` waypoint (the audit trail),
  applies the label swap, and runs the native-state Done hook — same
  five-step idempotent shape as the agent-driven path, just without
  the verdict round-trip. This also eliminates the Q1
  read-after-write-consistency assumption (no within-tick read-of-
  just-posted-marker required).

  Rejected alternative: post a `<!-- pipeline: verdict result=pass
  stage=building -->` marker and call `verdict_handler` synchronously
  to read it back. Initially proposed but flagged in design review
  P1: the marker is bookkeeping, not signal, when the orchestrator
  authors the transition. The pass-marker path also depends on
  read-after-write consistency on Linear's comment API
  (find_fresh_verdict's GET fetching the just-POSTed marker), an
  unverified assumption that the direct-call path sidesteps. Cost of
  the simplification: the issue's comment thread shows a transition
  waypoint without a preceding pass marker — uncommon shape, but
  unambiguous (the waypoint's `from=building to=released` is the
  state-change record).

  Rejected alternative: defer transition to the next tick (post
  marker, exit, let poll.sh pick up the fresh marker on the next
  tick). Rejected because: if the gate posts the pass marker and
  exits without transitioning, the next tick sees `stage:building`
  + fresh pass marker + no `pipeline:halted`. `_poll_classify_labels`'s
  else branch (`poll.sh:266`) returns `advanceable=true`, run-stage.sh
  fires again, the gate re-detects MERGED, posts ANOTHER pass marker,
  and the loop never terminates without external intervention. The
  direct-`apply_transition` design avoids both the round-trip and
  the loop attractor.

- **D-002. Belt-and-braces: add a "P0 — merge state precheck" clause
  to `AGENT_PROMPTS.md` §7 above P1, using the IDENTICAL query shape
  as D-001's gate.** New text (in the build agent fenced block):

  > **P0. Merge state precheck. Before evaluating P1–P7, run:
  >   `gh pr list --head {branch_name} --state all --json state --jq '.[0].state // ""'`
  > If this returns `MERGED`, the PR is already merged. Emit
  >   `bash bin/pipeline.sh event {issue_id} verdict pass --stage building`
  > and exit. Do NOT evaluate P1–P7. The orchestrator's pre-dispatch
  > gate (ENG-62) normally fires before you are dispatched in this
  > state, so this clause is defense-in-depth.**

  Both D-001 and D-002 use the **same** query (`gh pr list --head …
  --state all --json state --jq '.[0].state // ""'`), the same
  comparison (`== MERGED`), and the same outcome (transition to
  released). Symmetry is load-bearing: per design review P1, two
  divergent definitions of "post-merge" would inevitably drift
  (e.g., one path uses `gh pr view --json state` which requires a PR
  number while the other uses `gh pr list --head <branch>`; the two
  could disagree if a PR is somehow re-opened between calls).

  *Why both at all:* the agent path is reachable when the gate is
  bypassed: future code paths that invoke `dispatch.sh` outside
  `run-stage.sh::main` (a hypothetical retry script, an operator
  manually running dispatch in dry-run mode, ad-hoc one-off
  invocations during incident response). The gate is the load-
  bearing primitive; the prompt P0 is the redundant agent-side
  contract that ensures the agent's behaviour cannot diverge from
  the gate's even if dispatched in the post-merge state.

  Rejected alternative: drop D-002 entirely (orchestrator-only
  fix). Rejected because the prompt's precondition-ordering clause
  already has a correctness issue (P1 should fail-and-halt
  post-merge per the existing AGENT_PROMPTS.md:1208-1211 clause, but
  agents in production have been observed to emit wait instead).
  Leaving the agent's behaviour unchanged means any future
  dispatch-outside-the-gate path perpetuates the bug. The
  symmetric-query design from this revision (vs the asymmetric
  `gh pr view --json state` originally proposed) addresses the
  drift risk that motivated the design-review objection.

  Rejected alternative: prompt-only fix. Rejected because the
  observed evidence shows two distinct prompt revisions
  (`reviewDecision` → `reviews[]`) failed to change agent behaviour
  reliably; we cannot rely on prompt rewrites alone.

- **D-003. Test (regression).** New cases in `bin/run-stage-test.sh`
  using the existing source-and-stub pattern:
  - **Case A (gate fires on MERGED).** `_pre_dispatch_merge_gate`
    returns 0 when the `gh` stub emits `MERGED`. Assert: stage-summary
    file written; `wait-building.json` removed when present;
    `apply_transition`'s observable side effects landed
    (`linear.sh add-label stage:released`,
    `linear.sh remove-label stage:building`, transition waypoint
    comment posted).
  - **Case B (gate skips on non-MERGED).** Returns 1 when the `gh`
    stub emits `OPEN`, `CLOSED`, empty, or errors; assert no calls
    to `linear.sh add-label`/`remove-label` were captured (gate
    side-effect-free on rc=1).
  - **Case C (stage allow-list).** `_pre_dispatch_merge_gate`
    rejects non-`building` stages (`reviewing`, `qa`, `implementing`,
    `ui`) even with a `MERGED` stub — security parallel to
    `_fresh_wait_reason`'s build-only gate.
  - **Case D (branch derivation failure).** `branch-name.sh` stub
    returns empty → gate returns 1 (fail-open per D-006).
  - **Case E (apply_transition partial failure idempotency).**
    `linear.sh add-label` stub returns nonzero on the first call
    (simulating Linear outage). The gate STILL returns 0 (the gate's
    call site wraps `apply_transition … || true`, AND each step
    inside `apply_transition` is wrapped in `|| true` at
    verdict-handler.sh:161/164/166/172/180 — both layers protect
    against failure propagation). Then on a second invocation with
    `linear.sh add-label` recovered, the gate succeeds idempotently
    and the issue ends in `stage:released`. Asserts the brainstorm's
    "no state corruption on partial failure" claim from §5. Resolves
    design-review P2 #3.
  - **Case F (gate skips when `gh` is absent from PATH).** The gate's
    `command -v gh` check returns 1 → gate returns 1 → dispatch
    proceeds as today. Same fail-open class as case D.

  Cases A–D are minimum-viable per AC-1 (the AC's load-bearing
  assertion + the standard "doesn't fire when it shouldn't" guards).
  Cases E and F are scope-review-flagged (§10 scope persona P2) as
  defense-in-depth: case E pins the partial-failure recovery property
  the design relies on; case F pins the fail-open contract from D-006.
  Both are cheap stubs (no new fixture infrastructure) and the
  retrospective audit trail benefits from explicit failure-mode
  assertions, so we keep them. If the implementation phase shows
  either case is materially expensive, defer it.

  The orchestrator side test approach (no agent involved) is faithful
  to AC-1 because AC-1's load-bearing claim is "agent should proceed
  to verify merge state and emit verdict pass". With D-001, the
  orchestrator does that step on the agent's behalf — it is a
  superset, not a divergence. Tests assert the *observable end state*
  (issue at `stage:released`, transition waypoint posted) rather than
  the prescribed agent-side primitive.

- **D-004. Learned-rules entry: `learned-rules/harness/build.md`
  (NEW file under the `harness` slug).** Currently only
  `learned-rules/harness/project-profile.md` exists; the per-stage
  files are populated lazily by the retrospective agent. This is the
  first hand-seeded entry. Body:

  ```
  ### Rule Bld-001: post-merge dispatches must short-circuit on `state == MERGED`
  Added: 2026-05-03
  Source: ENG-62 — five wasted dispatches per merged PR observed on
          ENG-43 (PR #41) and ENG-58 (PR #42), 2026-05-02
  Rule: Before evaluating P1–P7, run
        `gh pr list --head {branch_name} --state all --json state --jq '.[0].state // ""'`.
        If the result is `MERGED`, emit
        `bash bin/pipeline.sh event {issue_id} verdict pass --stage building`
        and exit. The orchestrator's pre-dispatch gate (run-stage.sh
        ENG-62 block) uses the IDENTICAL query and short-circuits before
        you are dispatched in this state; this rule is the agent-side
        belt to the orchestrator's braces, with the symmetric query
        shape preventing semantic drift.
  Why:  Post-merge, `gh pr list --head <branch> --state open` returns
        0 (precondition P1 should fail-and-halt per the
        precondition-ordering clause), but agents in production have
        been observed to emit `verdict wait --reason awaiting-approval`
        instead — the prompt-following regression in §1.2.
  Evidence: docs/brainstorms/2026-05-03-eng-62-…-design.md
  ```

  Per AC-2, the `pipeline:rule-reviewed` label gate applies — the
  hand-seeded entry lands as a PR with the label applied at merge
  time (the retrospective workflow's normal contract). For the
  brainstorm phase: this decision *commits to writing the file* in the
  implementation phase. The brainstorm itself does not write
  `learned-rules/harness/build.md`; the implementation PR does.

- **D-005. Explicit non-changes (scope discipline).**
  - `_fresh_wait_reason` and `_handle_wait`: unchanged. They still
    detect and meter wait verdicts emitted by the agent during
    legitimate pre-merge waits (P2 pre-merge "no approval yet"; P5
    pre-merge "CI still running"). Those code paths remain
    load-bearing for the ENG-45 contract.
  - `on-new-release.sh` sweep: unchanged. Continues as the long-tail
    safety net for issues that escape the gate (e.g., `gh` outage at
    every tick between merge and the next release tag).
  - `bin/poll.sh` classification: unchanged. The else branch at
    `poll.sh:266` still says `advanceable=true` for `stage:building`
    + no halt + no fresh marker — that is what causes run-stage.sh to
    fire and the gate to run.
  - Other stages (`reviewing`, `qa`, etc.): no analogous gate.
    `reviewing` already has `review_should_dispatch`
    (`bin/review-poll.sh`) for new-commit gating; that's a different
    semantics (was new code reviewed?) and out of scope.
  - Pipeline events registry (`bin/pipeline-events.json`): unchanged.
    The pass-verdict body is the existing `verdict pass --stage
    building` shape.
  - `bin/dispatch.sh::allowed_tools_for`: unchanged. Build's tool list
    already permits `gh pr` calls; no agent-tool change needed.
  - `bin/halt-sprawl-test.sh` and `bin/run-local-sweep-test.sh`: no
    changes (the gate is independent of the breaker).

- **D-006. Failure mode of the gate is fail-open.** The gate's `gh`
  query is wrapped in `2>/dev/null || printf ''`; an empty result is
  not `MERGED`, so the gate returns 1 (do not fire) and dispatch
  proceeds as today. A `gh` outage cannot create a fabricated pass
  transition. The cost regression returns until `gh` recovers, but
  the issue cannot be silently advanced past `stage:building`.

  *Why fail-open:* a fail-closed gate (treat unknown `gh` state as
  "do not dispatch") would silently halt every build issue during a
  GitHub-API outage. The cost regression is observable and
  recoverable; a halted issue is not. The current behaviour
  (dispatch-on-error) is the safer default.

## 3. Architecture

### 3.1 Files modified

| File | Change |
| --- | --- |
| `bin/run-stage.sh` | New helper `_pre_dispatch_merge_gate` (pure check, returns 0 if `gh pr list … --state all --json state` is `MERGED` for stage=building, else 1). |
| `bin/run-stage.sh` | Insert gate-firing block at line ~543 (between the `skip_dispatch` block at 534-541 and the `mkdir -p "$(issue_dir "$ident")"` at line 546). The block is structured as: `if _pre_dispatch_merge_gate "$ident" "$stage"; then …; exit 0; fi`. |
| `AGENT_PROMPTS.md` | Insert new "P0 — merge state precheck" precondition at the top of §7's preconditions list (above P1). One paragraph, ~3 lines. Updates the precondition-ordering clause to reference P0. |
| `learned-rules/harness/build.md` | NEW file (D-004 body). |
| `bin/run-stage-test.sh` | New ENG-62 cases A–F (D-003): MERGED → gate fires + transition applied; OPEN/empty/error → gate skips; non-`building` stage → gate skips; branch-derivation failure → gate skips; apply_transition partial-failure idempotency; gh-not-in-PATH fail-open. Use the existing toggleable `MOCK_GH_PR_URL`-style env var pattern, extended with `MOCK_GH_PR_STATE`. |

### 3.2 Helper sketch — `_pre_dispatch_merge_gate`

Returns 0 if the gate decided to fire AND `apply_transition`
succeeded end-to-end (caller MUST exit 0 after; the helper has
written the stage-summary file, cleared state, and applied the
transition). Returns 1 otherwise (caller proceeds to dispatch as
today). Pure side-effect-on-success function: no caller-visible
state change on the rc=1 path beyond the `gh` query.

```bash
# ENG-62: pre-dispatch merge-detection gate.
# Returns 0 = gate fired and transition applied (caller must exit).
# Returns 1 = gate did not fire (caller proceeds to render-prompt + dispatch).
# Stage-gated to "building" — the only stage with PR-merge semantics today.
# Fail-open on gh outage / branch-derivation failure (D-006).
_pre_dispatch_merge_gate() {
  # Explicit lane attribution (security P2 hardening): mirrors
  # _handle_wait's defensive `local PIPELINE_WRITER=orchestrator;
  # export PIPELINE_WRITER` at run-stage.sh:382-383. Inherited default
  # from common.sh:254-255 is correct today, but explicit assignment
  # prevents silent lane-violation if a future caller invokes this
  # helper from an agent sub-shell.
  local PIPELINE_WRITER=orchestrator
  export PIPELINE_WRITER

  local ident="$1" stage="$2"
  case "$stage" in building) ;; *) return 1 ;; esac
  command -v gh >/dev/null 2>&1 || return 1

  local _branch
  _branch="$(bash "$SCRIPT_DIR/branch-name.sh" "$ident" 2>/dev/null || printf '')"
  [[ -n "$_branch" ]] || return 1

  # --state all so a --delete-branch'd merged PR is still found. The
  # --json state --jq '.[0].state // ""' shape mirrors how
  # post_completion_comment derives pr_url at run-stage.sh:159-160.
  local _pr_state
  _pr_state="$(gh pr list --head "$_branch" --state all --json state \
                --jq '.[0].state // ""' 2>/dev/null || printf '')"
  [[ "$_pr_state" == "MERGED" ]] || return 1

  log "build pre-dispatch: PR for $_branch is MERGED; transitioning building → released without invoking agent (ENG-62)"

  # Stage-summary file (retrospective archaeology). The orchestrator
  # path skips post_completion_comment (caller exits before reaching
  # it), but writing the file keeps cross-stage debugging consistent
  # — every successful stage exit produces this artifact.
  local _summary_path
  _summary_path="$(issue_dir "$ident")/stage-summary-${stage}.md"
  mkdir -p "$(dirname "$_summary_path")"
  printf 'Pre-dispatch merge detection (ENG-62): PR on `%s` was already MERGED at orchestrator entry. Transitioned `building → released` without invoking the build agent.\n' \
    "$_branch" > "$_summary_path"

  # Success-path state cleanup, mirroring run-stage.sh:851-855.
  rm -f "$(issue_dir "$ident")/wait-${stage}.json" 2>/dev/null || true
  rm -f "$(issue_dir "$ident")/issue-state.json"     2>/dev/null || true

  # Apply the transition directly. apply_transition is sourced from
  # verdict-handler.sh at run-stage.sh:21-22 and is in scope. It posts
  # a single <!-- pipeline: transition from=building to=released -->
  # waypoint (its step 1), swaps stage labels (steps 2-3), drains
  # legacy labels (step 3.5), and runs the native-state Done hook
  # (step 4 — see verdict-handler.sh:176-184). All five steps are
  # idempotent; on partial failure (e.g., add-label outage), the
  # next tick's resume_in_progress_transition path
  # (verdict-handler.sh:338) re-enters cleanly.
  apply_transition "$ident" "building" "released" "" || true

  return 0
}
```

### 3.3 Insertion point in `run-stage.sh::main`

Structural reference (resilient to unrelated edits): immediately
after the `skip_dispatch` scope-approval-replay block, and BEFORE
the `mkdir -p "$(issue_dir "$ident")"` line that precedes prompt
rendering. As of the current worktree this corresponds to line ~543,
but the structural anchors are what matter:

- AFTER: `verify_preconditions` returns + guards.sh check + the
  `local skip_dispatch=0; if [[ "$stage" == "implementing" || "$stage"
  == "ui" ]]; then …; fi` block.
- BEFORE: `mkdir -p "$(issue_dir "$ident")"` and the `Render the
  prompt` comment.

The block:

```bash
# ENG-62: pre-dispatch merge-detection gate. If the PR for stage=building
# is already MERGED (e.g., a prior dispatch fired `gh pr merge --auto`
# successfully), there is nothing left for the build agent to do —
# dispatching it costs ~$1.50 and risks an awaiting-approval emission
# from a prompt-following regression. Apply the transition directly
# and exit.
if _pre_dispatch_merge_gate "$ident" "$stage"; then
  t1="$(date +%s)"; duration=$(( (t1 - t0) * 1000 ))
  bash "$SCRIPT_DIR/metrics.sh" stage-end "$ident" "$stage" "merged-pre-dispatch" \
    "$duration" || true
  exit 0
fi
```

`apply_transition` is sourced from verdict-handler.sh at run-stage.sh:21-22
and is already in scope at this insertion point. The `t0` variable
was set earlier in main() (`t0="$(date +%s)"`).

### 3.4 §7 Build Agent prompt change (AGENT_PROMPTS.md)

Insert immediately before the existing P1 (line 1213, before "P1.
**Exactly one open PR**"). The query shape is **identical** to
D-001's gate (per D-002's symmetry-load-bearing rationale):

```
  P0. **Merge state precheck.** Before evaluating P1–P7, run:
        gh pr list --head {branch_name} --state all --json state \
          --jq '.[0].state // ""'
      If this returns `MERGED`, the PR is already merged (by a prior
      dispatch's `gh pr merge --auto` or by a human merging directly).
      Do NOT evaluate P1–P7. Run:
        bash bin/pipeline.sh event {issue_id} verdict pass --stage building
      and exit. The orchestrator's pre-dispatch gate (ENG-62) normally
      fires before you are dispatched in this state, so this clause is
      defense-in-depth.

      If the query returns empty (no PR record at all on this branch,
      e.g., UI stage failed to open one), proceed to evaluate P1–P7;
      P1 will catch the missing PR and the precondition-ordering clause
      below routes to the agent-blocked halt path.
```

Also add one sentence to the precondition-ordering clause at line
1208-1211 that references P0:

> If P0 already determined `state == MERGED`, you do not reach this
> ordering clause — exit per P0. Otherwise, if P1, P3, P4, P6, or P7
> fail, …

## 4. Data flow

### 4.1 Happy path (PR is freshly merged)

```
launchd tick N (PR MERGED at tick N-1)
  poll.sh
    → ENG-58 has stage:building, no halt label, fresh wait marker (from
      tick N-1's agent emission), no fresh pass/fail/halt verdict (wait
      shape is invisible to find_fresh_verdict, verdict-handler.sh:113).
    → _poll_classify_labels else branch (poll.sh:266) → hold, advanceable=true
    → emit decision: (ENG-58, build, run)

run-stage.sh ENG-58 building
  → verify_preconditions: stage:building label present, not paused → 0
  → skip_dispatch=0 (we're not implementing/ui)
  → _pre_dispatch_merge_gate ENG-58 building:
      branch = fix/eng-58-…
      gh pr list --head fix/eng-58-… --state all --json state → "MERGED"
      → write stage-summary-building.md
      → rm wait-building.json, rm issue-state.json
      → apply_transition ENG-58 building released "":
          → post <!-- pipeline: transition from=building to=released -->
          → add-label stage:released
          → drain legacy labels (pipeline:paused, pipeline:supersede, …)
          → remove-label stage:building
          → if config.linear.native_states.done set → transition Linear state to Done
      → return 0
  → metrics stage-end "merged-pre-dispatch" duration
  → exit 0

next tick N+1
  poll.sh: ENG-58 now has stage:released (terminal per poll.sh:34).
  Issue is no longer in the polled set. No agent dispatch ever fires.
```

Result: zero agent cost for this transition, transition completed in
the same tick that detects the merge. Linear comment thread shows
exactly one new comment for the transition (the `pipeline: transition`
waypoint posted by `apply_transition`'s step 1) — no synthesised
verdict marker from the orchestrator-self talking to itself.

### 4.2 Pre-merge tick (PR not yet merged) — gate skips, dispatch proceeds

```
tick M
  poll.sh: same as §4.1.
run-stage.sh ENG-58 building
  → _pre_dispatch_merge_gate:
      gh pr list --head … --state all --json state → "OPEN"
      → return 1 (gate did not fire)
  → render-prompt + dispatch.sh → build agent runs P1..P7
  → existing flow unchanged
```

The gate is a pure short-circuit: if PR is not merged, behaviour is
identical to today.

### 4.3 `gh` outage tick — gate fails open

```
tick M
  _pre_dispatch_merge_gate:
    gh pr list … 2>/dev/null returns "" (network error)
    → _pr_state = ""
    → "" != "MERGED" → return 1 (fail open)
  → dispatch proceeds as today
```

A persistent `gh` outage means the agent runs every tick. The cost
regression returns until `gh` recovers, but no false transitions occur.

### 4.4 Late-arrival post-merge dispatch (for issues that pre-date the fix)

When the fix lands, two populations need consideration:

1. **Healthy in-flight issues at `stage:building`** (no
   `pipeline:halted`, just an idle wait counter). These hit the gate
   on the very next tick and transition cleanly. No migration step
   is needed — the gate is idempotent and stateless across ticks.
   The orchestrator gate, on first run, posts a `pipeline: transition
   from=building to=released` waypoint via `apply_transition` and
   removes the wait file in the same step — no verdict-marker
   round-trip needed.

2. **Halted issues at `stage:building`** (operator-applied
   `pipeline:halted` during the $22 incident, OR
   `_handle_wait`-applied `pipeline:halted` after the budget
   exhausted). These do NOT auto-recover — see §6 "Issue at
   stage:building with pipeline:halted already applied". The
   operator must run the standard recovery:

       bash bin/pipeline.sh decide ENG-N --action continue

   On the next tick, the gate fires cleanly and the issue
   transitions. This is the same recovery operators already use for
   ENG-58's atomic-resume contract — no new operator workflow.

(Compare ENG-54's one-time manual-flush requirement: that fix removed
the review-stage wait, which left orphaned wait verdicts that needed
manual `pipeline.sh decide --action continue` to clear. ENG-62's fix
covers the healthy population automatically, and the halted
population uses the existing recovery primitive.)

## 5. Error handling

- **`gh pr list` returns non-MERGED states** (`OPEN`, `CLOSED`,
  `DRAFT`). Gate returns 1 (do not fire). Dispatch proceeds as today.
  The MERGED-vs-CLOSED distinction matters: a manually-CLOSED-but-not-
  merged PR is a human signal; the orchestrator should not skip the
  agent in that case (the agent will halt with appropriate context).

- **`gh pr list` errors (network, auth)**. `2>/dev/null || printf
  ''` → empty string → not equal to `MERGED` → gate returns 1 →
  dispatch proceeds as today. Fail-open per D-006.

- **`branch-name.sh` returns empty** (Linear API down at branch
  derivation). Gate returns 1 — same behaviour as `post_completion_
  comment`'s defensive empty-branch handling at run-stage.sh:158.

- **`gh` not in PATH** (cleanup-test environment). Gate returns 1
  (early `command -v` check). All existing run-stage.sh code paths
  that touch `gh` already handle absence; the gate is one more.

- **`apply_transition` partial failure** (e.g., Linear add-label
  outage at the `add-label stage:released` step, or the
  `transition-state` Linear-native-state hook fails). Each step
  inside `apply_transition` is wrapped in `|| true`
  (verdict-handler.sh:161, 164, 166, 172, 180); a failure leaves
  the issue partially transitioned (waypoint posted, but stage label
  not yet swapped). On the next tick:
  - `resume_in_progress_transition` (verdict-handler.sh:338-341) is
    NOT in the gate's path — but the gate doesn't need it. The gate
    just runs `apply_transition` again. Every step is idempotent:
    `add-label stage:released` is a no-op if already present,
    `remove-label stage:building` is a no-op if already removed,
    transition-state is a no-op if already set, the waypoint comment
    is appended again (one extra comment, harmless).
  - In the worst case, a persistent Linear outage causes one extra
    waypoint comment per tick until recovery. After recovery, the
    transition completes. No state corruption.
  
  Note: the gate does NOT hold a lock against concurrent
  modifications. The `.claude-mutex.lock/` mutex (`CLAUDE.md:172`)
  serialises `dispatch.sh`-level work but the gate runs upstream of
  dispatch. Within an issue, the per-issue dir's mutations are
  serialised by the orchestrator's per-tick single-flight; cross-tick
  interleavings of the gate with operator manual interventions
  (e.g. operator manually applying `stage:released` between tick N's
  gate query and tick N's `apply_transition`) are extremely rare and
  bounded — see §6 "Operator manually applied stage:released".

- **Race: PR merges between gate query and dispatch start.** Window
  is the time between `_pre_dispatch_merge_gate`'s `gh` call and the
  `dispatch.sh` invocation that follows on the next tick (5 min).
  Possible but rare: PR merges in tick M after the gate already
  decided "not merged"; dispatch proceeds; agent emits a wait marker
  (or, with D-002's P0, emits pass directly). On tick M+1 the gate
  catches it. Cost: at most one extra dispatch — same as today's
  best case. D-002's prompt P0 covers this case from the agent side.

- **Race: PR merges DURING the agent dispatch.** Agent's `gh pr
  merge --auto` may have queued a merge that fires while the agent
  is still running post-merge verification. The agent's existing
  `gh run watch` flow handles this (per AGENT_PROMPTS.md:1343-1346).
  Unchanged.

- **Multiple PRs on the same branch (manually re-opened).** `gh pr
  list --json state --jq '.[0].state // ""'` returns the most recent
  PR's state. If that's a re-opened (OPEN) PR after a merged one,
  gate returns 1, dispatch fires — correct behaviour. If that's the
  merged one, gate returns 0 — correct behaviour.

## 6. Edge cases

- **Branch named with characters that interact with `gh` quoting.**
  `branch-name.sh` produces `feat/eng-N-<slug>` or `fix/eng-N-<slug>`,
  where slug is `[a-z0-9-]+`. No special quoting concerns.

- **`stage:released` is terminal** (`bin/poll.sh:34`). After the gate
  fires and verdict_handler transitions to released, the issue is
  not polled again. The gate is consumed exactly once per merge.

- **Issue at `stage:building` with `pipeline:halted` already
  applied** (e.g., the agent posted a `verdict halt --reason
  agent-blocked` and the orchestrator applied the label). `poll.sh::
  _poll_classify_labels` line 217-233: pipeline:halted + fresh
  pipeline-halt marker → vacate, advanceable=false. run-stage.sh
  isn't dispatched. Gate doesn't run. Operator must clear the halt
  via `pipeline.sh decide --action continue` first; on the next tick
  the gate fires cleanly. No interaction.

- **Operator manually applied `stage:released` before this fix
  landed.** Gate doesn't run (issue is at `stage:released`, not
  `stage:building`, and `stage:released` is terminal). No double
  transition.

- **PR was merged manually (outside `gh pr merge --auto`).** Same
  result — `gh pr list --json state` still returns `MERGED`. Gate
  fires.

- **PR was merged via squash, not merge-commit.** Doesn't matter for
  the state query. Note: the `--merge` strategy is the project's
  convention (per AGENT_PROMPTS.md:1322-1324) but the gate doesn't
  care.

- **Build stage fired with `--state all` returning multiple PRs (a
  merged one and a separately-opened one for unrelated work on the
  same branch — extremely rare).** `--jq '.[0].state // ""'`
  returns the first (most recent). If the most recent is OPEN, gate
  doesn't fire — correct (agent should evaluate the OPEN one). If
  the most recent is MERGED, gate fires — correct.

- **Gate runs but apply_transition partial-fails** (e.g., transient
  Linear add-label outage). The gate's design pivot (D-001 revision
  per design review P1) eliminated the verdict-handler-self-read
  failure mode entirely: there is no longer a "post marker, read it
  back" round-trip, so the Linear consistency assumption (Q1) is
  retired. A partial apply_transition failure leaves a clean retry
  path on the next tick — see §5 "apply_transition partial failure".

- **Concurrent ticks on the same issue.** Cross-issue serialisation
  is via `.claude-mutex.lock/` (CLAUDE.md). Within an issue the
  per-issue dir's mutations are serialised by the lock. The gate's
  `linear.sh add-comment` and `verdict_handler` calls are
  individually idempotent.

- **`config.json` lacks `linear.native_states.done`** (the Done
  state mapping for the released-state hook). `apply_transition`
  logs and skips the native-state flip (verdict-handler.sh:181-183);
  the stage label still gets swapped. Issue moves to
  `stage:released`, native state stays as-is. Same behaviour as
  today's normal building → released path.

- **Build dispatched with `stage=building` against an issue that
  has no PR (UI stage failed to open one)**. `gh pr list --head
  <branch> --state all` returns 0 PRs → `.[0].state // ""` → empty
  → gate returns 1 → dispatch proceeds. Agent's existing P1 catches
  this and halts (or, post-D-002 prompt P0, the new clause's
  fallback handling does).

## 7. Open questions

- **Q1 (consistency timing).** RETIRED. The original revision posted a
  verdict pass marker and called `verdict_handler` synchronously to
  read it back, raising a Linear comment-API read-after-write
  consistency question. The post-design-review revision (D-001) calls
  `apply_transition` directly, eliminating the round-trip. No
  consistency assumption remains.

- **Q2 (metrics outcome name).** New literal `merged-pre-dispatch`
  — distinguishes from `success` (agent-driven build success) and
  `halt-for-human`. Need to confirm `bin/run-retrospective-local.sh`'s
  §1 filter does not silently drop unknown outcome names. **Action:**
  confirm during implementation by running the retrospective once
  in dry-run after the fix lands. If the filter drops unknown
  outcomes, ENG-62's success will be invisible to the rule-learning
  loop and could regress on a future retrospective. (Mirrors ENG-45
  Q2; product review §10 P2.)

- **Q3 (telemetry — track avoided cost AND gate-firing health).**
  Two related concerns surfaced by product review:

  (a) **Avoided-cost counter.** Each gate fire saves ≈ $1.50. The
  brainstorm asserts the proxy "count of `merged-pre-dispatch`
  events × $1.50". Concrete operator query (no infra change required):

      jq -c 'select(.outcome=="merged-pre-dispatch")' \
        $PROJECT_STATE_DIR/metrics/events.jsonl \
        | wc -l

  Multiplying that count by $1.50 gives the dispatches-avoided
  estimate. The plan phase should append this query to
  `docs/runbooks/recovery.md` (or wherever ops reads cost rollups)
  so the team has a documented post-deploy verification path.

  (b) **Health check: did the gate fire at all this week?** A
  persistent `gh` outage silently restores the cost regression
  (§D-006 fail-open). Without a tripwire, the regression could
  return undetected for days. Concrete operator query:

      jq -c 'select(.outcome=="merged-pre-dispatch") |
        select(.timestamp >= (now - 7*24*3600) | tostring)' \
        $PROJECT_STATE_DIR/metrics/events.jsonl | wc -l

  If this count drops to 0 in a week where merged PRs exist, the
  gate has stopped firing. The plan phase should consider whether
  to fold this into `bin/status.sh`'s rollup or leave it as a
  documented manual check. **Decision for v1:** documented manual
  check; promote to automated tripwire only if the gate is observed
  to silently fail in the field.

- **Q4 (status.sh outcome rendering).** `bin/status.sh:144-169`'s
  metrics tail color-codes by outcome name; `merged-pre-dispatch`
  falls into the default uncolored bucket. Implementation should
  decide whether to add a green-style row for the new outcome (so
  operators visually distinguish saved dispatches from normal stage
  ends) or leave default rendering. **Decision for v1:** leave
  default; the metrics row is the durable record. If operator
  feedback shows the saved dispatches blur into the rest of the
  table, add a row-styling case in a follow-up.

- **Q4 (does ENG-45's wait counter need cleanup beyond
  `wait-${stage}.json`?).** §3.2's helper removes
  `wait-building.json` and `issue-state.json`. Both are the paths
  documented in `bin/run-stage.sh:851-853`'s success cleanup. No
  other state files are mentioned. **Verified via grep:** only
  these two paths are written under `issue_dir` for the build
  stage.

- **Q5 (D-002 prompt change risk surface).** Adding P0 changes the
  agent's evaluation entry point. If the new clause is misread (e.g.,
  agent sees `state=OPEN` and incorrectly emits pass), we get a
  false advance. Mitigation: P0 is a single-field exact-equality
  check (`state == MERGED`) — the simplest possible primitive. The
  orchestrator gate (D-001) is the load-bearing check; D-002 is
  defense-in-depth, bypassable in failure modes.

## 8. Anti-bias checks

### 8.1 ADR stress test

There is no `docs/knowledge/decisions.md` in this repo (per the
brainstorm prompt — the harness has no formal ADR ledger). The
closest analogues are prior brainstorms in `docs/brainstorms/`:

- `2026-04-28-build-agent-soft-preconditions-p2-p5-should-re-dispatch-not-halt-for-human-design.md`
  (ENG-45). The wait-marker contract that this brainstorm extends.
  D-001 explicitly preserves `_fresh_wait_reason` / `_handle_wait`
  for the legitimate pre-merge wait case; the gate runs upstream of
  them, so neither contract is broken.

- `2026-05-02-eng-58-halt-sh-resolve-atomic-state-reset-clean-wait-skip-until-rejection-counter-side-state-design.md`
  (ENG-58, recently merged). Defines `pipeline.sh decide --action
  continue` as the atomic-resume primitive. D-005's "operator
  workflow unchanged" is consistent: a halted ENG-62-affected issue
  still uses `decide --action continue` to recover, and the gate
  fires on the next tick post-resume.

- `2026-05-02-pipeline-vocabulary-simplification-design.md` (ENG-60).
  Establishes the closed `verdict pass --stage X` shape and the
  `bin/pipeline-events.json` registry. D-001's pass-marker body is
  registry-compliant. The reason-string `external-signal-budget-
  exhausted` (used by `_handle_wait` at run-stage.sh:454) is NOT
  registered in `halt_reasons`, but that's a pre-existing gap (out
  of scope for ENG-62; tracked as a separate observation in §9).

- `2026-04-30-eng-50-review-stage-reframe-design.md` and ENG-54's
  consolidation (commit 4e4d0c6). These moved the human-approval
  gate from review to build P2. The pre-existing P2 / P5 wait
  contract is unchanged by this brainstorm.

Tradeoff surfaced: the orchestrator gate adds another stage-keyed
short-circuit path to `run-stage.sh::main`. The file already has
several (skip_dispatch for scope-approval-replay; wait-shape
detection; stage-drift guard). One more is acceptable; the
alternative — gate in `poll.sh` (similar to `review_should_dispatch`)
— widens the blast radius (poll.sh tests, slot-classification
tests). The run-stage.sh approach concentrates the change in one
place, mirroring ENG-45's design discipline ("fix is additive in
run-stage.sh, no poll.sh changes").

### 8.2 Simpler alternatives considered

- **A. Prompt-only fix (rewrite §7 P2 to use a different jq
  expression).** Rejected: prompt was already rewritten once
  (`reviewDecision` → `reviews[]`, commit 941218f9), yet the symptom
  recurred on 2026-05-02. We cannot rely on prompt rewrites alone
  to change agent behaviour reliably.

- **B. Strengthen `_handle_wait` to detect post-merge case and
  override the wait verdict to pass.** Rejected: detection happens
  AFTER `dispatch.sh` returns — the $1.50 cost has already been
  spent. The load-bearing goal is *avoiding* the dispatch.

- **C. Gate inside `poll.sh::_poll_classify_labels`** (next to
  `review_should_dispatch`). Rejected: poll.sh is a hot path
  evaluated for every issue every tick; adding a `gh pr list` call
  per `stage:building` issue per tick widens the per-tick latency
  and the blast radius of poll.sh tests. The run-stage.sh gate runs
  only when an issue is actually being dispatched, which is the
  cost-bearing event.

- **D. Suppress dispatch for the immediate post-merge tick by
  recording the merge-completion timestamp in
  `stage-summary-building.md`.** Rejected: the bug is observed
  across MULTIPLE post-merge dispatches (5+ ticks), not just the
  first one — a one-tick suppression doesn't cover the bug, and
  arbitrary multi-tick suppression masks legitimate dispatches if
  the agent's prior-tick merge attempt failed.

- **E. Add an explicit post-merge marker shape (e.g., `verdict
  done`) and teach the agent to emit it.** Rejected: introducing a
  new marker shape just to communicate "PR is merged, advance" is
  heavy when the existing `verdict pass --stage building` shape
  already means exactly that. Better to *make the agent unnecessary*
  for this transition than to expand the protocol.

- **F. Use `gh pr view --json state` instead of `gh pr list --head
  --state all --json state`.** Rejected because `gh pr view`
  requires a PR number, and post-`--delete-branch` we lose the
  branch ref → no clean way to derive the PR number without
  `gh pr list`. The list-based query takes one round trip and
  works whether the branch ref exists or not.

### 8.3 Assumption inventory

| Assumption | Status | Evidence / Action |
| --- | --- | --- |
| `bin/poll.sh::_poll_classify_labels` else branch (line 266) returns `slot=hold, advanceable=true` for `stage:building` + no halt + no fresh marker | **verified** | `bin/poll.sh:265-267` (`else class='{"slot":"hold","advanceable":true}'`). |
| `bin/poll.sh:34` excludes `stage:released` from polling (terminal) | **verified** | `bin/poll.sh:34` (`stage:released is terminal — not polled`). |
| `bin/run-stage.sh:702-742` wait-shape detection runs AFTER `dispatch.sh` | **verified** | Inserted at run-stage.sh:702, after the `dispatch_rc=0; bash "$SCRIPT_DIR/dispatch.sh" …` block at run-stage.sh:562-595. |
| `bin/run-stage.sh:556-562` `dispatch.sh` is invoked from inside `if (( ! skip_dispatch ))` | **verified** | run-stage.sh:550 (`if (( ! skip_dispatch ))`). |
| `bin/run-stage.sh::_handle_wait` does not short-circuit dispatch on subsequent ticks | **verified** | run-stage.sh:381-470: `_handle_wait` writes `wait-${stage}.json` and returns to caller; caller exits. The state file is NOT consulted by `dispatch.sh` or by `verify_preconditions`. The agent runs fresh every tick. |
| `bin/verdict-handler.sh::find_fresh_verdict` does NOT match `result=wait` markers (ENG-45 invariant) | **verified** | verdict-handler.sh:113 (`[[ "$(jq -r '.result' <<<"$ev")" == "wait" ]] && continue`). |
| `bin/verdict-handler.sh::apply_transition` is idempotent across all five steps (waypoint, add stage label, drain legacy, remove old stage label, native-state hook) | **verified** | apply_transition at verdict-handler.sh:154-184: every step uses idempotent verbs (`add-label`, `remove-label`, `add-comment`); `_vh_drain_legacy_labels` uses `|| true`. |
| `bin/verdict-handler.sh::_VH_FORWARD_TRANSITIONS` includes `building=released` | **verified** | verdict-handler.sh:26. |
| `bin/run-stage.sh:22` sources `verdict-handler.sh` so `verdict_handler` is callable from main() | **verified** | run-stage.sh:21-22 (`# shellcheck source=verdict-handler.sh\nsource "$SCRIPT_DIR/verdict-handler.sh"`). |
| `bin/run-stage.sh:158-160` already uses `gh pr list --head <branch> --state {open,all} --json url --jq '.[0].url // ""'` (proven invocation pattern; we mirror it for `state`) | **verified** | run-stage.sh:159 (open) + 160 (all-fallback). |
| `bin/branch-name.sh` returns `feat/<lower-id>-<slug>` or `fix/<lower-id>-<slug>` | **verified** | bin/branch-name.sh:31 (`printf '%s/%s-%s\n' "$prefix" "$ident_lower" "$slug"`). |
| `bin/on-new-release.sh` is a backstop for stuck stage:building issues at next release tag | **verified** | on-new-release.sh:25-58 (`Part 1: sweep stage:building → stage:released`). |
| `gh pr merge --auto --delete-branch` deletes the branch ref post-merge but preserves the PR record (queryable via `--state all`) | **verified externally** | GitHub CLI documented behaviour; matches AGENT_PROMPTS.md:1318-1331's prescribed merge strategy. |
| `gh pr view --json state` returns `MERGED` for merged PRs (D-002 prompt change relies on this) | **verified externally** | Standard `gh` JSON field; matches AGENT_PROMPTS.md:1392's existing post-merge state check. |
| `bin/dispatch.sh::allowed_tools_for` for `building` already permits `gh pr` calls (D-002 prompt P0 needs no allowlist change) | **verified** | dispatch.sh has the build-stage allowlist. AGENT_PROMPTS.md:1213-1346 already prescribes `gh pr` calls (P1, P2, P3, P5, etc.) without flagging tool restriction; merge command itself uses `gh pr merge`. |
| `bin/run-stage.sh::issue_dir` resolves to `$PROJECT_STATE_DIR/<ident>/` | **verified** | issue_dir is in common.sh; PROJECT_STATE_DIR is the canonical per-project root per CLAUDE.md. |
| `bin/run-stage-test.sh:46-52` `gh` stub pattern is extensible to `gh pr list … --json state` | **verified** | run-stage-test.sh:48-51 (`# Only handles: gh pr list --head <branch> --state {open|all} --json url --jq '.[0].url // ""'`); the stub is one-arg-aware so a `MOCK_GH_PR_STATE` can be added by a one-line case. |
| `bin/run-stage-test.sh` source-and-stub pattern can test new helpers without firing main() (sentinel at bin/run-stage.sh:879-881) | **verified** | run-stage.sh:879-881 (`if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi`); existing ENG-45 cases at run-stage-test.sh:907+ source-and-stub the same way. |
| `bin/run-retrospective-local.sh`'s §1 filter accepts a new metrics outcome string `merged-pre-dispatch` without silent-drop | **assumed** | Tracked as Q2; verify during implementation. |
| `apply_transition` is callable directly from outside `verdict_handler` and produces the same end state as the agent-driven path | **verified** | verdict-handler.sh:154-184 (`apply_transition <issue> <from> <to> <side_labels_csv>`) is a public function (declared in the file's header docstring at lines 6-9 as one of three public functions). The gate calls it with the same shape `verdict_handler::case "$mtype"` would have invoked it with for a pass marker. |

### 8.4 Codebase-fact verification (mandatory)

Every named code artifact is grounded in the current worktree at
`/Users/rajatgoyal/.local/state/twinning-harness/harness/ENG-62/worktree/`:

| Name | Quoted location |
| --- | --- |
| Build agent prompt §7 | `AGENT_PROMPTS.md:1191-1418` |
| §7 P1 prose | `AGENT_PROMPTS.md:1213-1216` |
| §7 P2 prose (the `reviews[]` filter — refactored in 941218f9) | `AGENT_PROMPTS.md:1218-1223` |
| §7 P2 wait-exit instructions | `AGENT_PROMPTS.md:1225-1246` |
| §7 P5 prose (CI green check) | `AGENT_PROMPTS.md:1256-1262` |
| §7 P5 wait-exit instructions (`reason=awaiting-ci`) | `AGENT_PROMPTS.md:1264-1283` |
| §7 precondition-ordering clause (P0/P1/P3/P4/P6/P7 fail → halt) | `AGENT_PROMPTS.md:1208-1211` |
| §7 verdict-marker exit instructions | `AGENT_PROMPTS.md:1390-1417` |
| `bin/run-stage.sh::_fresh_wait_reason` (build-only gate, allow-list) | `bin/run-stage.sh:301-344` |
| `bin/run-stage.sh::_post_dispatch_apply_halt` (wait-shape carve-out) | `bin/run-stage.sh:360-372` |
| `bin/run-stage.sh::_handle_wait` (counter + budget) | `bin/run-stage.sh:381-470` |
| `bin/run-stage.sh::main` `verify_preconditions` call | `bin/run-stage.sh:503` |
| `bin/run-stage.sh::main` `skip_dispatch` block (insertion point reference) | `bin/run-stage.sh:534-541` |
| `bin/run-stage.sh::main` `mkdir -p "$(issue_dir "$ident")"` (insertion point boundary) | `bin/run-stage.sh:546` |
| `bin/run-stage.sh::main` dispatch.sh call | `bin/run-stage.sh:562-565` |
| `bin/run-stage.sh::main` wait-shape detection block (ENG-45) | `bin/run-stage.sh:702-742` |
| `bin/run-stage.sh::main` agent-contract validator | `bin/run-stage.sh:753-766` |
| `bin/run-stage.sh::main` `verdict_handler` call (success path) | `bin/run-stage.sh:823` |
| `bin/run-stage.sh::main` success path state cleanup | `bin/run-stage.sh:851-855` |
| `bin/run-stage.sh:21-22` source verdict-handler.sh | `bin/run-stage.sh:21-22` |
| `bin/run-stage.sh:158-160` existing `gh pr list --head … --state {open,all} --json url` invocation | `bin/run-stage.sh:158-160` |
| `bin/run-stage.sh::_handle_wait` halt-marker post (linear.sh add-comment direct-body pattern this brainstorm mirrors) | `bin/run-stage.sh:454-456` |
| `bin/poll.sh:34` stage:released terminal comment | `bin/poll.sh:34` |
| `bin/poll.sh::_poll_classify_labels` else branch (advanceable=true for stage:building no-halt no-marker) | `bin/poll.sh:265-267` |
| `bin/poll.sh::_poll_classify_labels` halted branch (vacate on pipeline-halt marker) | `bin/poll.sh:217-233` |
| `bin/verdict-handler.sh::_VH_FORWARD_TRANSITIONS` (building → released row) | `bin/verdict-handler.sh:25-26` |
| `bin/verdict-handler.sh::find_fresh_verdict` wait-shape exclusion | `bin/verdict-handler.sh:113` |
| `bin/verdict-handler.sh::verdict_handler` entry | `bin/verdict-handler.sh:335` |
| `bin/verdict-handler.sh::apply_transition` (idempotent five-step) | `bin/verdict-handler.sh:154-184` |
| `bin/verdict-handler.sh::apply_transition` native-state Done hook | `bin/verdict-handler.sh:176-184` |
| `bin/branch-name.sh` (returns `feat/<id-lower>-<slug>` or `fix/<id-lower>-<slug>`) | `bin/branch-name.sh:31` |
| `bin/on-new-release.sh` Part 1 sweep (stage:building → stage:released safety net) | `bin/on-new-release.sh:25-58` |
| `bin/run-stage-test.sh::gh` stub | `bin/run-stage-test.sh:46-52` |
| `bin/run-stage-test.sh::linear.sh` stub `get-comments` arm | `bin/run-stage-test.sh:27-30` (and rebuilt at line 890-905) |
| `bin/pipeline-events.json::halt_reasons` registry | `bin/pipeline-events.json:10-19` |
| `bin/pipeline-events.json::wait_reasons` registry | `bin/pipeline-events.json:20-23` |
| `bin/pipeline-events.json::stages` registry (includes `building`) | `bin/pipeline-events.json:47-56` |
| ENG-45 brainstorm (predecessor) | `docs/brainstorms/2026-04-28-build-agent-soft-preconditions-p2-p5-should-re-dispatch-not-halt-for-human-design.md` |
| ENG-58 brainstorm (atomic resume) | `docs/brainstorms/2026-05-02-eng-58-halt-sh-resolve-atomic-state-reset-clean-wait-skip-until-rejection-counter-side-state-design.md` |
| ENG-60 brainstorm (vocabulary simplification) | `docs/brainstorms/2026-05-02-pipeline-vocabulary-simplification-design.md` |
| `learned-rules/harness/` slug dir | `learned-rules/harness/project-profile.md` (only file currently present; build.md added by D-004) |
| `learned-rules/twinning/build.md` (template / structure reference for D-004) | `learned-rules/twinning/build.md` (header convention + `Rule Bld-NNN` template) |

No referenced item is non-existent or speculative.

## 9. Scope check vs Linear issue

The Linear issue's IN list maps to:

- ✅ AC-1. Add a regression test that simulates a post-merge PR with
  one non-bot APPROVED review and asserts that P2 does NOT emit a
  wait. **D-003 covers this** — the orchestrator gate is the layer
  that ensures the wait is never emitted (because the agent is never
  dispatched). The test asserts on the ORCHESTRATOR side: `gh` stub
  returns `MERGED` → no `dispatch.sh` invocation, pass marker
  posted. This is a faithful interpretation of AC-1's intent ("the
  agent should proceed to verify merge state and emit verdict pass")
  — the orchestrator does that step on the agent's behalf, which is
  a strict superset.

- ✅ AC-2. Document the observed-vs-prompt discrepancy and the
  prevailing hypothesis in `learned-rules/harness/build.md`.
  **D-004 commits to this**; the file is created in the
  implementation phase under the `pipeline:rule-reviewed` gate.
  Per product review, the rule body should also include a one-line
  note about the **new comment-thread shape** (transition waypoint
  appearing without a preceding `verdict pass` marker), so future
  operators triaging unfamiliar issue threads recognise it as
  ENG-62's fingerprint and not a protocol violation.

- ✅ AC-3. After fix, the next merged PR transitions to
  `stage:released` on the FIRST post-merge tick. **D-001 fires on
  the first tick where `state == MERGED`**, calls `apply_transition`
  directly. **Operator verification recipe** (resolves product review
  P1 on hand-wavy AC-3 path):

  1. After the next merged PR (call it ENG-N), wait one tick (≤ 5
     min) and then run:

         bash bin/pipeline.sh status ENG-N

     The expected event sequence ends with:

         <ts>  {"event":"transition","from":"building","to":"released"}

     With **no preceding `verdict result=pass stage=building`**
     comment in the same tick window — that absence is ENG-62's
     fingerprint (the orchestrator gate fired, no agent involved).

  2. Confirm the metrics row landed:

         jq -c 'select(.issue=="ENG-N" and .outcome=="merged-pre-dispatch")' \
           $PROJECT_STATE_DIR/metrics/events.jsonl | tail -1

     Expected output: a single JSON object with `outcome:"merged-pre-dispatch"`,
     `stage:"building"`, and a non-zero `duration_ms`. Absence of
     this row means the gate did not fire — investigate `gh`
     reachability or the `MOCK_*` env vars (a stale dry-run env can
     stub `gh` to return empty).

  3. Confirm the issue's stage label transitioned cleanly:

         bash .pipeline/bin/linear.sh stage-of ENG-N

     Expected: `stage:released`.

OUT list (no scope sprawl):

- ✅ No changes to `_fresh_wait_reason` / `_handle_wait` (D-005).
- ✅ No changes to `bin/poll.sh` (D-005).
- ✅ No changes to `bin/halt-sprawl-test.sh` or
  `bin/run-local-sweep-test.sh` (D-005).
- ✅ No new marker shape or registry entry (D-005).
- ✅ No changes to `bin/dispatch.sh::allowed_tools_for` (D-005).
- ✅ No retrofit of analogous gates to other stages (out of scope
  per the Linear issue's narrow framing).

**Pre-existing observation logged for follow-up (NOT IN scope):**
`bin/run-stage.sh:454`'s `_handle_wait` halt body uses reason
`external-signal-budget-exhausted`, which is NOT in
`bin/pipeline-events.json::halt_reasons`. The marker is posted via
`linear.sh add-comment` directly (bypassing `pipeline.sh event`'s
registry validation), so runtime works — but parsers that walk the
registry to interpret halt comments will not recognise the reason.
**File a separate Linear issue** (recommended title: "Register
`external-signal-budget-exhausted` in pipeline-events.json::halt_reasons
or migrate _handle_wait to a registered reason") rather than
bundling. Per design review P2 #5, leaving the observation buried in
this brainstorm risks future readers treating it as either fixed or
deliberately tolerated; an explicit issue is the durable record.

## 10. Persona review

This section is populated during the personas iteration (steps 2–3
of the brainstorm completion checklist). Each persona's verdict
(PASS / CONCERN / FAIL) and a one-paragraph summary of resolved
findings are recorded here per the `## Persona review` contract.

### Iteration 1

- **Design lens — CONCERN.** Two P1 findings:
  1. D-001 ↔ D-002 single-source-of-truth dilution: D-002 originally
     used `gh pr view --json state` while D-001 used `gh pr list
     --head <branch> --state all --json state`. Two divergent
     definitions of "post-merge" risked drift. **Resolved in
     iteration 2:** D-002 revised to use the IDENTICAL query shape
     as D-001; both paths now share `gh pr list --head <branch>
     --state all --json state --jq '.[0].state // ""'` and the same
     `== MERGED` comparison.
  2. Marker round-trip indirection: D-001 originally posted a
     `verdict pass` marker and called `verdict_handler` synchronously
     to read it back (orchestrator-talks-to-Linear-about-itself).
     **Resolved in iteration 2:** D-001 revised to call
     `apply_transition "$ident" "building" "released" ""` directly,
     bypassing the marker round-trip. The Q1 read-after-write
     consistency assumption is retired.
  
  Three P2 findings: (3) test for apply_transition partial-failure
  recovery — added as D-003 case E. (4) insertion-point fragility
  — §3.3 rewritten with structural anchors (after `skip_dispatch`
  block, before `mkdir -p $(issue_dir …)`). (5) registry gap on
  `external-signal-budget-exhausted` — §9 amended to recommend
  filing a separate Linear issue rather than bundling.

- **Design lens — PASS (iteration 2).** All P1s resolved. The
  pre-dispatch gate is the load-bearing fix; the run-stage.sh
  insertion point is structurally anchored. D-002's symmetric query
  shape eliminates drift risk. D-001's direct-call approach
  eliminates the round-trip and the consistency assumption.

- **Security lens — PASS.** Stage-keyed gate (`case "$stage" in
  building) ;; *) return 1 ;; esac`) prevents cross-stage forgery.
  `linear.sh add-comment` at the orchestrator lane is allow-listed
  by the lane fence (AGENT_PROMPTS.md:92 `add any other comment`).
  No new env-var surface. No new tool-allowlist entry (existing
  build allowlist already permits `gh pr` calls). No new state
  file. The pass-marker body is a constant string; no user-
  controlled fragment can land in the marker. Fail-open on `gh`
  outage (§D-006) is the safer default for an availability-vs-
  silent-halt tradeoff.

- **Scope guardian — PASS.** D-005 enumerates non-changes
  exhaustively (poll.sh, _fresh_wait_reason, _handle_wait,
  classify-failure.sh, scope-check.sh, lane fence, registry,
  on-new-release sweep). The pre-existing
  `external-signal-budget-exhausted` registry gap is surfaced as
  out-of-scope rather than bundled.

- **Coherence — PASS.** D-001 + D-002 + D-005 are mutually
  reinforcing. D-002's P0 emits the same `verdict pass --stage
  building` shape that D-001 posts; D-001's fail-open on `gh`
  outage is consistent with §6's race-window analysis; the
  insertion point cited in §3.3 (line ~543) is consistent with the
  insertion-point boundaries cited in §3.1.

- **Product lens — PASS.** Cost recovery is concrete (≈ $1.50/tick
  saved, one tick of latency replaced with zero-tick transition,
  $22 wasted in the observed session reduced to ~$0). Operator-
  facing surface is unchanged (`pipeline.sh decide --action
  continue` still works, no new label, no new sig). The fix is
  invisible to operators in the happy case and visible only as a
  new metrics outcome (`merged-pre-dispatch`) when it fires.

- **Feasibility lens — PASS.** Every cited path:line in §8.4 was
  re-verified against the current worktree before this iteration:
  `bin/run-stage.sh:301-344` (`_fresh_wait_reason`), `bin/run-stage.sh:381-470`
  (`_handle_wait`), `bin/run-stage.sh:454-456` (linear.sh add-comment
  direct-body pattern), `bin/run-stage.sh:702-742` (wait-shape
  detection), `bin/run-stage.sh:823` (verdict_handler call),
  `bin/poll.sh:265-267` (else branch), `bin/poll.sh:34` (terminal
  released), `bin/verdict-handler.sh:25-26` (building=released),
  `bin/verdict-handler.sh:113` (wait exclusion),
  `bin/verdict-handler.sh:154-184` (apply_transition idempotency),
  `AGENT_PROMPTS.md:1218-1246` (P2 prose + wait-exit), `AGENT_PROMPTS.md:1208-1211`
  (precondition ordering). Helper sketch at §3.2 fits the existing
  source-and-stub test pattern; no new test infrastructure needed.
  Q1 (Linear comment read-after-write) is the only "assumed" item;
  it is a v2-fallback risk (`sleep 1` insertion if needed), not a
  blocker.

**Final tally for iteration 1: 6/6 PASS, gate P0 = 0.** Proceeding
to planning.
