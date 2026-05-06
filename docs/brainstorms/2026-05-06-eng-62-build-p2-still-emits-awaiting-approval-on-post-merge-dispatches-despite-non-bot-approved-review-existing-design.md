---
linear: ENG-62
title: Build P2 still emits awaiting-approval on post-merge dispatches
date: 2026-05-06
status: draft
supersedes: docs/brainstorms/2026-05-03-eng-62-build-p2-still-emits-awaiting-approval-on-post-merge-dispatches-despite-non-bot-approved-review-existing-design.md
---

# ENG-62 — Build P2 emits awaiting-approval on post-merge dispatches despite a non-bot APPROVED review existing

## 1. Problem

`AGENT_PROMPTS.md` §7 P2 (the post-ENG-54 human-approval gate) checks
for a non-bot APPROVED review by reading per-review entries rather
than the brittle `reviewDecision` summary:

```
gh pr view <N> --json reviews --jq \
  '[.reviews[] | select(.state == "APPROVED" and (.author.login | test("\\[bot\\]$") | not))] | length >= 1'
```

This is correct in principle — `reviewDecision` is cleared to empty by
GitHub once a PR is merged, while individual `reviews[]` entries persist.
**Yet during the 2026-05-02 SDLC observation run the wait-loop symptom
persisted on multiple post-merge dispatches** for both ENG-43 (PR #41,
five wasted post-merge dispatches over ~67 min) and ENG-58 (PR #42,
five more before an operator manually flipped the stage label). Each
dispatch costs ≈ $1.50; observed waste across the session ≈ $22.

### 1.1 Why the symptom recurs

The orchestrator has no pre-dispatch awareness of merge state. The
flow for `stage:building` today is:

```
poll.sh: stage:building, no pipeline:halted, no fresh verdict marker
       → _poll_classify_labels else branch (poll.sh:266) → hold, advanceable=true
run-stage.sh: render-prompt + dispatch.sh → build agent runs P1..P7
            → agent emits <!-- pipeline: verdict result=wait reason=awaiting-approval -->
            → _fresh_wait_reason (run-stage.sh:301-344) detects wait
            → _handle_wait (run-stage.sh:381-470) bumps counter
            → orchestrator exits 0; pipeline:halted is NOT applied
              (wait-shape carve-out in _post_dispatch_apply_halt at
              run-stage.sh:360-372)
next tick: same triple → re-dispatch → repeat until either
            external_signal_budget exhausts (_handle_wait posts
            external-signal-budget-exhausted halt at run-stage.sh:454)
            OR on-new-release.sh's tag sweep (on-new-release.sh:25-58)
            advances the issue to stage:released.
```

The wait verdict is invisible to `find_fresh_verdict`
(verdict-handler.sh:113 explicitly skips `result == "wait"`), so the
orchestrator can't distinguish a legitimate pre-merge wait from a
post-merge prompt-following regression by looking at markers alone.

### 1.2 Why the agent emits `awaiting-approval` post-merge

Most plausible cause: **agent prompt-following regression** (Hypothesis
3 from the Linear issue). Post-merge:

- `gh pr list --head <branch> --state open` returns 0 PRs because
  `gh pr merge --auto --delete-branch` (AGENT_PROMPTS.md:1319) deleted
  the branch ref. Per the precondition-ordering clause at
  AGENT_PROMPTS.md:1208-1211, P1 fail must halt-for-human, not wait.
  The agent in production has been observed to emit wait anyway.
- `gh pr view <N> --json reviewDecision` (the brittle path the prompt
  was rewritten *away from* in commit 941218f9) returns empty for a
  merged PR — agents fall back to it from training-data habit.
- The current prompt's `gh pr view <N> --json reviews` (the correct
  path) still returns the historical reviews array with the APPROVED
  non-bot entry intact. An agent that follows the prompt literally
  would see P2 pass.

Hypothesis 1 (P5 mislabelling its wait reason as `awaiting-approval`)
and Hypothesis 2 (`_handle_wait` short-circuiting on subsequent ticks)
are disproved by code inspection:

- §7 P5's wait emits `verdict wait --reason awaiting-ci`
  (AGENT_PROMPTS.md:1268). The agent emits `awaiting-approval` —
  reason only on P2's wait path.
- `_handle_wait` (run-stage.sh:381-470) writes `wait-${stage}.json`
  and returns; the file is never consulted by `dispatch.sh` or by
  `verify_preconditions`, so the agent runs fresh every tick.

So the bug lives in the agent's actual evaluation, which we cannot
patch reliably from prompt text alone — observed evidence: prompt
already rewritten once (`reviewDecision` → `reviews[]`) and the
symptom still recurred on 2026-05-02. **This brainstorm therefore
moves the load-bearing fix to the orchestrator** and treats the
prompt change as defense-in-depth.

### 1.3 Why on-new-release.sh's sweep is not enough

`bin/on-new-release.sh:25-58` already flips stuck `stage:building`
issues to `stage:released` when a release tag is published. But:

- The sweep fires only when a downstream release pipeline publishes a
  tag. For a project with no release workflow (per
  AGENT_PROMPTS.md:1339-1342) the sweep never fires.
- Until it fires, the orchestrator wastes one agent dispatch per
  5-min tick. Cost regression is unbounded by anything cheaper than
  the next release tag publication.

The sweep is a backstop, not the cost-recovery mechanism.

## 2. Decisions

- **D-001. Pre-dispatch merge-detection gate in `run-stage.sh::main`,
  stage-gated to `building`.** Before rendering the prompt, the
  orchestrator queries:

  ```
  gh pr list --head <branch> --state all --json state \
    --jq '.[0].state // ""'
  ```

  If the value is `MERGED`, the gate:
  1. Writes a minimal `stage-summary-building.md` for retrospective
     archaeology (mirrors run-stage.sh:147-148's path scheme).
  2. Removes `wait-building.json` and `issue-state.json`
     (success-path semantics, parallel to run-stage.sh:851-855).
  3. Calls `apply_transition "$ident" "building" "released" ""`
     directly. `apply_transition` is sourced from `verdict-handler.sh`
     at run-stage.sh:21-22 and is in scope. It posts the
     `<!-- pipeline: transition from=building to=released -->`
     waypoint (verdict-handler.sh:160-161), swaps stage labels
     (verdict-handler.sh:164-166), drains legacy pipeline-namespace
     labels (verdict-handler.sh:165 → `_vh_drain_legacy_labels`),
     and runs the released native-state hook
     (verdict-handler.sh:176-184).
  4. Emits `metrics.sh stage-end <ident> building merged-pre-dispatch`
     and `exit 0`.

  *Why pre-dispatch (not post-dispatch override).* The load-bearing
  goal is **eliminating the agent dispatch cost**. A post-dispatch
  override (read merge state after the agent already ran, override
  its wait verdict to pass) saves nothing — the $1.50 has already
  been spent. The gate must run BEFORE `dispatch.sh`.

  *Why `--state all` (not `--state open`).* `gh pr merge ... --auto
  --delete-branch` deletes the branch ref post-merge, so
  `--state open` silently returns 0 PRs even though the merged PR
  record persists. `--state all` returns the merged record — the
  only path that surfaces the load-bearing `MERGED` value. The
  `gh pr list --state {open,all}` fallback pattern is identical to
  the one already in use at run-stage.sh:159-160 for `pr_url`
  derivation, so no new shell idiom enters the codebase.

  *Why call `apply_transition` directly (not "post pass marker, then
  call verdict_handler").* The orchestrator is the AUTHOR of this
  transition; making it synthesize a `verdict pass --stage building`
  marker so `verdict_handler` can read it back through Linear is
  orchestrator-talks-to-Linear-about-itself overhead. The marker
  contract exists for AGENT → ORCHESTRATOR signalling; the
  orchestrator is not its own audience here. Calling
  `apply_transition` directly posts exactly one
  `pipeline: transition` waypoint (the audit trail), applies the
  label swap, and runs the native-state Done hook — same five-step
  idempotent shape as the agent-driven path, just without the verdict
  round-trip. This also eliminates the read-after-write-consistency
  question on Linear's comment API.

  Rejected alternative (post pass marker, call verdict_handler).
  Rejected: extra Linear round-trip; depends on within-tick
  read-after-write consistency on Linear's comment API; orchestrator
  becomes its own audience.

  Rejected alternative (defer transition to next tick: post pass
  marker, exit, let poll.sh pick up the fresh marker). Rejected: if
  the gate posts the pass marker and exits without transitioning,
  the next tick sees `stage:building` + fresh pass marker + no
  `pipeline:halted`. `_poll_classify_labels`'s else branch
  (poll.sh:265-267) returns `advanceable=true`, run-stage.sh fires
  again, the gate re-detects MERGED, posts ANOTHER pass marker, and
  the loop never terminates without external intervention.

- **D-002. Prompt belt-and-braces: add a "P0 — merge state precheck"
  clause to `AGENT_PROMPTS.md` §7 above P1, using the IDENTICAL query
  shape as D-001's gate.** New text:

  > **P0. Merge state precheck.** Before evaluating P1–P7, run:
  >   `gh pr list --head {branch_name} --state all --json state --jq '.[0].state // ""'`
  > If this returns `MERGED`, the PR is already merged. Run:
  >   `bash bin/pipeline.sh event {issue_id} verdict pass --stage building`
  > and exit. Do NOT evaluate P1–P7. The orchestrator's pre-dispatch
  > gate (ENG-62) normally fires before you are dispatched in this
  > state, so this clause is defense-in-depth.

  Both D-001 and D-002 use the **same** query (`gh pr list --head …
  --state all --json state --jq '.[0].state // ""'`), the same
  comparison (`== MERGED`), and the same outcome (transition to
  released). Symmetry is load-bearing: divergent definitions of
  "post-merge" (e.g., one path uses `gh pr view --json state` which
  requires a PR number) would inevitably drift.

  *Why both at all.* The agent path is reachable when the gate is
  bypassed: future code paths that invoke `dispatch.sh` outside
  `run-stage.sh::main` (a hypothetical retry script, an operator
  manually running dispatch in dry-run mode). The gate is the load-
  bearing primitive; the prompt P0 is the redundant agent-side
  contract that ensures the agent's behaviour cannot diverge from
  the gate's even if dispatched in the post-merge state.

  Rejected alternative (drop D-002 entirely; orchestrator-only fix).
  Rejected because the prompt's existing precondition-ordering clause
  already says P1 fail → halt-for-human, but agents in production
  have been observed to emit wait instead. Leaving the agent's
  behaviour unchanged means any future dispatch-outside-the-gate path
  perpetuates the bug.

  Rejected alternative (prompt-only fix, e.g., reword P2's jq).
  Rejected: the prompt was already rewritten once (`reviewDecision`
  → `reviews[]`, commit 941218f9) and the symptom still recurred;
  prompt rewrites are not a reliable lever.

- **D-003. Regression test in `bin/run-stage-test.sh`** using the
  existing source-and-stub pattern. Six cases:

  - **Case A (gate fires on MERGED).** `_pre_dispatch_merge_gate`
    returns 0 when the `gh` stub emits `MERGED`. Assert: stage-summary
    file written; `wait-building.json` removed when present;
    `apply_transition`'s observable side effects landed
    (`linear.sh add-label stage:released`,
    `linear.sh remove-label stage:building`, transition waypoint
    posted).
  - **Case B (gate skips on non-MERGED).** Returns 1 when the stub
    emits `OPEN`, `CLOSED`, empty, or errors; no calls to
    `linear.sh add-label`/`remove-label` captured.
  - **Case C (stage allow-list).** `_pre_dispatch_merge_gate` rejects
    non-`building` stages (`reviewing`, `qa`, `implementing`, `ui`)
    even with a `MERGED` stub — security parallel to
    `_fresh_wait_reason`'s build-only gate.
  - **Case D (branch derivation failure).** `branch-name.sh` stub
    returns empty → gate returns 1 (fail-open per D-006).
  - **Case E (apply_transition partial-failure idempotency).** A
    `linear.sh add-label` stub returns nonzero on the first invocation
    (Linear outage); the gate still returns 0 (every step in
    `apply_transition` is wrapped in `|| true` at
    verdict-handler.sh:161/164/166/172/180). Second invocation with
    `linear.sh` recovered → gate succeeds idempotently.
  - **Case F (gate skips when `gh` not in PATH).** `command -v gh`
    returns 1 → gate returns 1 → dispatch proceeds as today.

  Cases A–D are minimum-viable per AC-1. Cases E and F pin the two
  failure-mode invariants the design relies on (partial-failure
  recovery; fail-open on tooling absence). All cheap stub variants
  using the existing pattern; no new fixture infrastructure.

- **D-004. Hand-seeded `learned-rules/harness/build.md`** (NEW file
  under the `harness` slug; `learned-rules/harness/` currently
  contains only `project-profile.md`). Body sketch:

  ```
  ### Rule Bld-001: post-merge dispatches must short-circuit on `state == MERGED`
  Added: 2026-05-06
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
  Evidence: docs/brainstorms/2026-05-06-eng-62-…-design.md
  ```

  Per AC-2, the `pipeline:rule-reviewed` label gate applies — the
  hand-seeded entry lands as part of the implementation PR with the
  label applied at merge time. The brainstorm itself does not write
  `learned-rules/harness/build.md`; the implementation PR does.

- **D-005. Explicit non-changes (scope discipline).**
  - `_fresh_wait_reason` and `_handle_wait`: unchanged. Still detect
    and meter wait verdicts emitted by the agent during legitimate
    pre-merge waits (P2 pre-merge "no approval yet"; P5 pre-merge
    "CI still running"). Those code paths remain load-bearing for
    the ENG-45 contract.
  - `on-new-release.sh` sweep: unchanged. Continues as the long-tail
    safety net for issues that escape the gate (e.g., persistent `gh`
    outage at every tick between merge and the next release tag).
  - `bin/poll.sh` classification: unchanged. The else branch at
    `poll.sh:265-267` still returns `advanceable=true` for
    `stage:building` + no halt + no fresh marker — the trigger that
    causes run-stage.sh to fire and the gate to run.
  - Other stages: no analogous gate. `reviewing` already has
    `review_should_dispatch` (`bin/review-poll.sh`) for new-commit
    gating; that is different semantics ("was new code reviewed?")
    and out of scope.
  - `bin/pipeline-events.json`: unchanged. The transition uses the
    existing `transition` event shape; no new vocabulary.
  - `bin/dispatch.sh::allowed_tools_for`: unchanged. Build's tool
    list already permits `gh pr` calls.
  - `bin/halt-sprawl-test.sh` / `bin/run-local-sweep-test.sh`: no
    changes (the gate is independent of the breaker).

- **D-006. Failure mode of the gate is fail-open.** The gate's `gh`
  query is wrapped in `2>/dev/null || printf ''`; an empty result is
  not `MERGED`, so the gate returns 1 (do not fire) and dispatch
  proceeds as today. A `gh` outage cannot fabricate a pass
  transition. The cost regression returns until `gh` recovers, but
  the issue cannot be silently advanced past `stage:building`.

  *Why fail-open.* A fail-closed gate (treat unknown `gh` state as
  "do not dispatch") would silently halt every build issue during a
  GitHub-API outage. The cost regression is observable and
  recoverable; a halted issue is not. Dispatch-on-error is the safer
  default.

## 3. Architecture

### 3.1 Files modified

| File | Change |
| --- | --- |
| `bin/run-stage.sh` | New helper `_pre_dispatch_merge_gate` (§3.2). |
| `bin/run-stage.sh` | Insert gate-firing block in `main()` (§3.3) between the `skip_dispatch` block (run-stage.sh:534-541) and `mkdir -p "$(issue_dir "$ident")"` (run-stage.sh:546). |
| `AGENT_PROMPTS.md` | Insert "P0 — merge state precheck" above P1 (currently AGENT_PROMPTS.md:1213). One paragraph (§3.4). |
| `learned-rules/harness/build.md` | NEW file (D-004 body). |
| `bin/run-stage-test.sh` | Add cases A–F (§D-003). Extend the existing `gh` stub at run-stage-test.sh:46-52 with a `MOCK_GH_PR_STATE` env var. |

### 3.2 Helper sketch — `_pre_dispatch_merge_gate`

Returns 0 if the gate fires AND `apply_transition` ran end-to-end
(caller MUST `exit 0` after). Returns 1 otherwise (caller proceeds to
dispatch). Pure side-effect-on-success: no caller-visible state change
on the rc=1 path beyond the read-only `gh` query.

```bash
# ENG-62: pre-dispatch merge-detection gate.
# Returns 0 = gate fired and transition applied (caller must exit).
# Returns 1 = gate did not fire (caller proceeds to render-prompt + dispatch).
# Stage-gated to "building" — the only stage with PR-merge semantics today.
# Fail-open on gh outage / branch-derivation failure (D-006).
_pre_dispatch_merge_gate() {
  # Lane attribution (security): mirror _handle_wait at run-stage.sh:382-383.
  # Inherited default from common.sh is correct today, but explicit
  # assignment prevents silent lane-violation if a future caller invokes
  # this helper from an agent sub-shell.
  local PIPELINE_WRITER=orchestrator
  export PIPELINE_WRITER

  local ident="$1" stage="$2"
  case "$stage" in building) ;; *) return 1 ;; esac
  command -v gh >/dev/null 2>&1 || return 1

  local _branch
  _branch="$(bash "$SCRIPT_DIR/branch-name.sh" "$ident" 2>/dev/null || printf '')"
  [[ -n "$_branch" ]] || return 1

  # --state all so a --delete-branch'd merged PR is still found. Mirrors
  # run-stage.sh:160's --state all fallback for pr_url.
  local _pr_state
  _pr_state="$(gh pr list --head "$_branch" --state all --json state \
                --jq '.[0].state // ""' 2>/dev/null || printf '')"
  [[ "$_pr_state" == "MERGED" ]] || return 1

  log "build pre-dispatch: PR for $_branch is MERGED; transitioning building → released without invoking agent (ENG-62)"

  # Stage-summary for retrospective archaeology.
  local _summary_path
  _summary_path="$(issue_dir "$ident")/stage-summary-${stage}.md"
  mkdir -p "$(dirname "$_summary_path")"
  printf 'Pre-dispatch merge detection (ENG-62): PR on `%s` was already MERGED at orchestrator entry. Transitioned `building → released` without invoking the build agent.\n' \
    "$_branch" > "$_summary_path"

  # Success-path state cleanup, mirroring run-stage.sh:851-855.
  rm -f "$(issue_dir "$ident")/wait-${stage}.json" 2>/dev/null || true
  rm -f "$(issue_dir "$ident")/issue-state.json"     2>/dev/null || true

  # Apply the transition directly. Each step in apply_transition is
  # idempotent (verdict-handler.sh:154-184); on partial failure
  # (Linear add-label outage) the next tick re-enters cleanly.
  apply_transition "$ident" "building" "released" "" || true

  return 0
}
```

### 3.3 Insertion point in `run-stage.sh::main`

Structural anchors (resilient to unrelated edits):

- AFTER: the `skip_dispatch` scope-approval-replay block at
  run-stage.sh:534-541.
- BEFORE: `mkdir -p "$(issue_dir "$ident")"` at run-stage.sh:546.

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

`apply_transition` is in scope at this insertion point (sourced at
run-stage.sh:21-22). `t0` was set at run-stage.sh:500.

### 3.4 §7 Build Agent prompt change

Insert immediately before the existing P1 (currently
AGENT_PROMPTS.md:1213). The query shape is **identical** to D-001's
gate:

```
  P0. **Merge state precheck.** Before evaluating P1–P7, run:
        gh pr list --head {branch_name} --state all --json state \
          --jq '.[0].state // ""'
      If this returns `MERGED`, the PR is already merged. Do NOT
      evaluate P1–P7. Run:
        bash bin/pipeline.sh event {issue_id} verdict pass --stage building
      and exit. The orchestrator's pre-dispatch gate (ENG-62) normally
      fires before you are dispatched in this state, so this clause is
      defense-in-depth.

      If the query returns empty (no PR record at all on this branch),
      proceed to evaluate P1–P7; P1 will catch the missing PR and the
      precondition-ordering clause routes to the agent-blocked halt.
```

Also add one sentence to the precondition-ordering clause at
AGENT_PROMPTS.md:1208-1211 referencing P0:

> If P0 already determined `state == MERGED`, you do not reach this
> ordering clause — exit per P0. Otherwise, if P1, P3, P4, P6, or P7
> fail, …

## 4. Data flow

### 4.1 Happy path (PR is freshly merged)

```
launchd tick N (PR MERGED at tick N-1)
  poll.sh
    → ENG-N has stage:building, no halt label, fresh wait marker (from
      tick N-1's agent emission), no fresh pass/fail/halt verdict
      (wait shape invisible to find_fresh_verdict per
      verdict-handler.sh:113).
    → _poll_classify_labels else branch (poll.sh:265-267) → hold,
      advanceable=true
    → emit decision: (ENG-N, build, run)

run-stage.sh ENG-N building
  → verify_preconditions → 0
  → skip_dispatch=0
  → _pre_dispatch_merge_gate ENG-N building:
      branch = fix/eng-N-…
      gh pr list --head fix/eng-N-… --state all --json state → "MERGED"
      → write stage-summary-building.md
      → rm wait-building.json, rm issue-state.json
      → apply_transition ENG-N building released "":
          → post <!-- pipeline: transition from=building to=released -->
          → add-label stage:released
          → drain legacy labels (pipeline:supersede, …)
          → remove-label stage:building
          → if config.linear.native_states.done set → flip Linear state
      → return 0
  → metrics stage-end "merged-pre-dispatch" duration
  → exit 0

next tick N+1
  poll.sh: ENG-N now has stage:released (terminal per poll.sh:34).
  Issue is no longer in the polled set. No agent dispatch ever fires.
```

Result: zero agent cost for this transition; transition completed
in the same tick that detects the merge. Linear thread shows exactly
one new comment for the transition (the `pipeline: transition`
waypoint posted by `apply_transition`'s step 1) — no synthesised
verdict marker.

### 4.2 Pre-merge tick (PR not yet merged) — gate skips, dispatch proceeds

```
tick M
  _pre_dispatch_merge_gate:
    gh pr list --head … --state all --json state → "OPEN"
    → return 1 (gate did not fire)
  → render-prompt + dispatch.sh → existing flow unchanged
```

### 4.3 `gh` outage tick — gate fails open

```
tick M
  _pre_dispatch_merge_gate:
    gh pr list … 2>/dev/null returns "" (network error)
    → _pr_state = ""
    → "" != "MERGED" → return 1 (fail open)
  → dispatch proceeds as today
```

A persistent `gh` outage means the agent runs every tick and the
cost regression returns until `gh` recovers — but no false
transitions occur.

### 4.4 In-flight migration

When the fix lands:

1. **Healthy in-flight issues at `stage:building`** (no
   `pipeline:halted`, just an idle wait counter). Hit the gate on
   the very next tick and transition cleanly. No migration step
   needed.

2. **Halted issues at `stage:building`** (operator-applied
   `pipeline:halted`, OR `_handle_wait`-applied
   `pipeline:halted` after budget exhausted). Do NOT auto-recover
   — `poll.sh:217-233` vacates them. Operator runs the standard
   recovery:

       bash bin/pipeline.sh decide ENG-N --action continue

   On the next tick the gate fires cleanly. Same primitive operators
   already use for ENG-58's atomic-resume contract — no new operator
   workflow.

## 5. Error handling

- **`gh pr list` returns non-MERGED states (`OPEN`, `CLOSED`,
  `DRAFT`).** Gate returns 1, dispatch proceeds. The MERGED-vs-CLOSED
  distinction matters: a manually-CLOSED-but-not-merged PR is a
  human signal; the orchestrator should not skip the agent.

- **`gh pr list` errors (network, auth).** `2>/dev/null || printf
  ''` → empty string → not equal to `MERGED` → gate returns 1.
  Fail-open per D-006.

- **`branch-name.sh` returns empty.** Gate returns 1 — same defensive
  shape as `post_completion_comment`'s empty-branch handling at
  run-stage.sh:157-158.

- **`gh` not in PATH.** Gate returns 1 (early `command -v` check).

- **`apply_transition` partial failure** (e.g., transient Linear
  add-label outage). Each step is wrapped in `|| true`
  (verdict-handler.sh:161/164/166/172/180); a failure leaves the
  issue partially transitioned (waypoint posted, stage label not yet
  swapped). On the next tick the gate runs `apply_transition` again.
  Every step is idempotent: `add-label stage:released` is a no-op if
  already present, `remove-label stage:building` is a no-op if
  already removed, transition-state is a no-op if already set, the
  waypoint comment is appended again (one extra comment, harmless).

- **Race: PR merges between gate query and dispatch start.** Window
  is the time between `_pre_dispatch_merge_gate`'s `gh` call and the
  `dispatch.sh` invocation that follows on the next tick. Possible
  but rare: PR merges in tick M after the gate already decided "not
  merged"; dispatch proceeds; agent emits a wait marker (or, with
  D-002's P0, emits pass directly). On tick M+1 the gate catches it.
  Cost: at most one extra dispatch.

- **Race: PR merges DURING the agent dispatch.** The agent's
  existing `gh run watch` flow handles this
  (AGENT_PROMPTS.md:1343-1346). Unchanged.

- **Multiple PRs on the same branch (manually re-opened).**
  `--jq '.[0].state // ""'` returns the most recent PR's state.
  If most recent is OPEN, gate returns 1 (correct). If MERGED, gate
  returns 0 (correct).

## 6. Edge cases

- **Branch-name characters.** `branch-name.sh:31` produces
  `feat/<id-lower>-<slug>` or `fix/<id-lower>-<slug>` where slug is
  `[a-z0-9-]+`. No special-quoting concerns.

- **`stage:released` is terminal** (poll.sh:34). After the gate
  fires, the issue is not polled again. Gate is consumed exactly
  once per merge.

- **Issue at `stage:building` with `pipeline:halted` already
  applied.** `poll.sh::_poll_classify_labels` lines 217-233:
  `pipeline:halted` + fresh `pipeline-halt` marker → vacate,
  advanceable=false. run-stage.sh isn't dispatched. Gate doesn't run.
  Operator must clear the halt via
  `pipeline.sh decide --action continue` first; on the next tick
  the gate fires cleanly.

- **Operator manually applied `stage:released` before fix landed.**
  Gate doesn't run (issue is at `stage:released`, not
  `stage:building`, and `stage:released` is terminal). No double
  transition.

- **PR merged manually (outside `gh pr merge --auto`).** Same
  result — `gh pr list --json state` still returns `MERGED`. Gate
  fires.

- **PR merged via squash, not merge-commit.** Doesn't matter for
  the state query. (`--merge` is the project convention per
  AGENT_PROMPTS.md:1322-1324, but the gate doesn't care.)

- **`config.json` lacks `linear.native_states.done`.** The
  released-state hook logs and skips
  (verdict-handler.sh:181-183); stage label still swaps. Issue
  moves to `stage:released`, native state stays as-is. Same
  behaviour as today's normal building → released path.

- **Build dispatched against an issue with no PR (UI stage failed
  to open one).** `gh pr list --head <branch> --state all` returns
  0 PRs → `.[0].state // ""` → empty → gate returns 1 → dispatch
  proceeds. Agent's existing P1 catches this and halts (or, after
  D-002, the new P0's empty-result fallback handles it).

- **Concurrent ticks on the same issue.** Cross-issue serialisation
  is via `.claude-mutex.lock/` (CLAUDE.md). Within an issue the
  per-issue dir's mutations are serialised by the orchestrator's
  per-tick single-flight; gate's `linear.sh` calls are individually
  idempotent.

## 7. Open questions

- **Q1 (metrics outcome name).** New literal `merged-pre-dispatch`
  — distinguishes from `success` (agent-driven build success) and
  `halt-for-human`. Need to confirm `bin/run-retrospective-local.sh`'s
  §1 filter does not silently drop unknown outcome names. **Action:**
  confirm during implementation by running the retrospective once
  in dry-run after the fix lands.

- **Q2 (telemetry — track avoided cost AND gate-firing health).**
  Each gate fire saves ≈ $1.50. Two operator queries (no infra
  change required):

  (a) **Avoided-cost counter:**
  ```
  jq -c 'select(.outcome=="merged-pre-dispatch")' \
    $PROJECT_STATE_DIR/metrics/events.jsonl | wc -l
  ```
  Multiplying by $1.50 gives the dispatches-avoided estimate.

  (b) **Health check: did the gate fire at all this week?**
  ```
  jq -c 'select(.outcome=="merged-pre-dispatch") |
    select(.timestamp >= (now - 7*24*3600) | tostring)' \
    $PROJECT_STATE_DIR/metrics/events.jsonl | wc -l
  ```
  If this drops to 0 in a week where merged PRs exist, the gate has
  stopped firing (likely a persistent `gh` outage). The plan phase
  should fold these into `docs/runbooks/recovery.md` as a documented
  manual check; promote to automated tripwire only if the gate is
  observed to silently fail in the field.

- **Q3 (status.sh outcome rendering).** `bin/status.sh` color-codes
  by outcome name; `merged-pre-dispatch` falls into the default
  uncolored bucket. **Decision for v1:** leave default; the metrics
  row is the durable record. Add a row-styling case in a follow-up
  if operators report that the saved dispatches blur into the rest
  of the table.

- **Q4 (D-002 prompt change risk).** Adding P0 changes the agent's
  evaluation entry point. If the new clause is misread (e.g., agent
  sees `state=OPEN` and incorrectly emits pass), we get a false
  advance. Mitigation: P0 is a single-field exact-equality check
  (`state == MERGED`) — the simplest possible primitive. The
  orchestrator gate (D-001) is the load-bearing check; D-002 is
  defense-in-depth, bypassable in failure modes.

## 8. Anti-bias checks

### 8.1 ADR / prior-art stress test

The harness has no `docs/knowledge/decisions.md`; the closest analogues
are prior brainstorms.

- `2026-04-28-build-agent-soft-preconditions-p2-p5-should-re-dispatch-not-halt-for-human-design.md`
  (ENG-45). Defines the wait-marker contract this brainstorm extends.
  D-005 explicitly preserves `_fresh_wait_reason` / `_handle_wait`
  for the legitimate pre-merge wait case; the gate runs upstream of
  them, so neither contract is broken.
- `2026-05-02-eng-58-halt-sh-resolve-atomic-state-reset-clean-wait-skip-until-rejection-counter-side-state-design.md`
  (ENG-58, merged). Defines `pipeline.sh decide --action continue`
  as the atomic-resume primitive. §4.4 leans on this primitive
  unchanged.
- `2026-05-02-pipeline-vocabulary-simplification-design.md` (ENG-60,
  merged). Establishes the closed `verdict pass --stage X` shape and
  the `bin/pipeline-events.json` registry. D-001's transition is
  registry-compliant (uses the existing `transition` event). The
  reason-string `external-signal-budget-exhausted` (used by
  `_handle_wait` at run-stage.sh:454) is NOT registered in
  `halt_reasons` (pipeline-events.json:10-19), but that's a
  pre-existing gap (out of scope for ENG-62; logged as a
  follow-up in §9).
- `2026-04-30-eng-50-review-stage-reframe-design.md` and ENG-54.
  Moved the human-approval gate from review to build P2. This
  brainstorm leaves the build-stage P2 contract in place and adds a
  P0 above it.
- `2026-05-03-eng-62-build-p2-still-emits-awaiting-approval-…-design.md`
  (predecessor; same Linear ticket). 6/6 PASS at the time, but the
  issue was re-routed back to brainstorm via operator-resume; this
  doc supersedes it (frontmatter `supersedes:`). Design is materially
  identical with the same load-bearing gate; presented refreshed and
  re-verified against current code.

Tradeoff surfaced: the orchestrator gate adds another stage-keyed
short-circuit path to `run-stage.sh::main`. The file already has
several (`skip_dispatch`, wait-shape detection, stage-drift guard).
One more is acceptable; the alternative (gate in `poll.sh`, similar
to `review_should_dispatch`) widens the blast radius (poll.sh tests,
slot-classification tests). The run-stage.sh approach concentrates
the change in one place.

### 8.2 Simpler alternatives considered

- **A. Prompt-only fix (rewrite §7 P2's jq).** Rejected: prompt
  already rewritten once (`reviewDecision` → `reviews[]`) and the
  symptom recurred.
- **B. Strengthen `_handle_wait` to detect post-merge case and
  override the wait verdict to pass.** Rejected: detection happens
  AFTER `dispatch.sh` returns — the $1.50 cost has already been
  spent. The load-bearing goal is *avoiding* the dispatch.
- **C. Gate inside `poll.sh::_poll_classify_labels`** (next to
  `review_should_dispatch`). Rejected: poll.sh is a hot path
  evaluated for every issue every tick; adding a `gh pr list` call
  per `stage:building` issue per tick widens per-tick latency and
  blast radius. The run-stage.sh gate runs only when an issue is
  actually being dispatched.
- **D. Suppress dispatch for the immediate post-merge tick by
  recording the merge-completion timestamp in
  `stage-summary-building.md`.** Rejected: bug observed across
  MULTIPLE post-merge dispatches (5+ ticks), not just the first.
- **E. Add a new marker shape (`verdict done`) and teach the agent
  to emit it.** Rejected: the existing `verdict pass --stage
  building` shape already means "advance the issue". Better to
  *make the agent unnecessary* than to expand the protocol.
- **F. Use `gh pr view --json state` instead of `gh pr list`.**
  Rejected: `gh pr view` requires a PR number, and post-`--delete-
  branch` we lose the branch ref → no clean way to derive the PR
  number without `gh pr list` first.

### 8.3 Assumption inventory

| Assumption | Status | Evidence / Action |
| --- | --- | --- |
| `bin/poll.sh::_poll_classify_labels` else branch returns `slot=hold, advanceable=true` for `stage:building` + no halt + no fresh marker | **verified** | poll.sh:265-267 (`else class='{"slot":"hold","advanceable":true}'`). |
| `bin/poll.sh:34` excludes `stage:released` from polling | **verified** | poll.sh:34 (`stage:released is terminal — not polled`). |
| `bin/run-stage.sh::_handle_wait` does not short-circuit dispatch on subsequent ticks | **verified** | run-stage.sh:381-470: writes `wait-${stage}.json` and returns; the file is not consulted by `dispatch.sh` or `verify_preconditions`. |
| `bin/verdict-handler.sh::find_fresh_verdict` does NOT match `result=wait` markers | **verified** | verdict-handler.sh:113 (`[[ … "wait" ]] && continue`). |
| `bin/verdict-handler.sh::apply_transition` is idempotent across all five steps | **verified** | verdict-handler.sh:154-184: every step uses idempotent verbs (`add-label`, `remove-label`, `add-comment`); legacy-label drain wrapped in `|| true`. |
| `bin/verdict-handler.sh::_VH_FORWARD_TRANSITIONS` includes `building=released` | **verified** | verdict-handler.sh:25-26. |
| `bin/run-stage.sh:21-22` sources `verdict-handler.sh` so `apply_transition` is callable from `main()` | **verified** | run-stage.sh:21-22 (`source "$SCRIPT_DIR/verdict-handler.sh"`). |
| `bin/run-stage.sh:158-160` already uses `gh pr list --head <branch> --state {open,all} --json url --jq '.[0].url // ""'` (proven invocation pattern; we mirror for `state`) | **verified** | run-stage.sh:159-160. |
| `bin/branch-name.sh` returns `feat/<id-lower>-<slug>` or `fix/<id-lower>-<slug>` | **verified** | branch-name.sh:31. |
| `bin/on-new-release.sh` is a backstop for stuck stage:building issues at the next release tag | **verified** | on-new-release.sh:25-58. |
| `gh pr merge --auto --delete-branch` deletes the branch ref post-merge but preserves the PR record (queryable via `--state all`) | **verified externally** | GitHub CLI documented behaviour; matches AGENT_PROMPTS.md:1318-1331's prescribed merge strategy. |
| `gh pr view --json state` returns `MERGED` for merged PRs (D-002 prompt change relies on this) | **verified externally** | Standard `gh` JSON field. |
| `bin/dispatch.sh::allowed_tools_for` for `building` already permits `gh pr` calls (D-002 prompt P0 needs no allowlist change) | **verified** | AGENT_PROMPTS.md §7 already prescribes `gh pr` calls (P1, P2, P3, P5, P6, merge command itself); the build-stage allowlist permits them. |
| `bin/run-stage.sh::issue_dir` resolves to `$PROJECT_STATE_DIR/<ident>/` | **verified** | `issue_dir` is in common.sh; PROJECT_STATE_DIR is the canonical per-project root per CLAUDE.md. |
| `bin/run-stage-test.sh:46-52` `gh` stub pattern is extensible to `gh pr list … --json state` | **verified** | run-stage-test.sh:47-51 (existing comment scopes to `--json url`, but the stub body just emits `${MOCK_GH_PR_URL:-}`; adding a `MOCK_GH_PR_STATE` arm is a one-line case branch on the `--json` argument). |
| Source-and-stub test pattern can test new helpers without firing `main()` | **verified** | run-stage.sh:879-881 sentinel; existing ENG-45 cases in run-stage-test.sh source-and-stub the same way (e.g., run-stage-test.sh:907+ for `_fresh_wait_reason`). |
| `bin/run-retrospective-local.sh`'s §1 filter accepts a new metrics outcome string `merged-pre-dispatch` without silent-drop | **assumed** | Tracked as Q1; verify during implementation by running the retrospective in dry-run after the fix lands. |
| `apply_transition` is callable directly from outside `verdict_handler` and produces the same end state as the agent-driven path | **verified** | verdict-handler.sh:154-184 — `apply_transition <issue> <from> <to> <side_labels_csv>` is one of the file's three public functions per the header docstring at verdict-handler.sh:6-10. |

### 8.4 Codebase-fact verification

Every named code artifact is grounded in the current worktree
(`/Users/rajatgoyal/.local/state/twinning-harness/harness/ENG-62/worktree/`):

| Name | Quoted location |
| --- | --- |
| Build agent prompt §7 header | `AGENT_PROMPTS.md:1191` |
| §7 P1 prose | `AGENT_PROMPTS.md:1213-1216` |
| §7 P2 prose (the `reviews[]` filter — refactored in 941218f9) | `AGENT_PROMPTS.md:1218-1223` |
| §7 P2 wait-exit instructions (`reason=awaiting-approval`) | `AGENT_PROMPTS.md:1225-1246` |
| §7 P5 prose (CI green check) | `AGENT_PROMPTS.md:1256-1262` |
| §7 P5 wait-exit instructions (`reason=awaiting-ci`) | `AGENT_PROMPTS.md:1268-1283` |
| §7 precondition-ordering clause (P1/P3/P4/P6/P7 fail → halt) | `AGENT_PROMPTS.md:1208-1211` |
| §7 merge-strategy clause (`gh pr merge --auto --delete-branch`) | `AGENT_PROMPTS.md:1319-1331` |
| `bin/run-stage.sh::_fresh_wait_reason` (build-only allow-list) | `bin/run-stage.sh:301-344` |
| `bin/run-stage.sh::_post_dispatch_apply_halt` (wait-shape carve-out) | `bin/run-stage.sh:360-372` |
| `bin/run-stage.sh::_handle_wait` (counter + budget) | `bin/run-stage.sh:381-470` |
| `bin/run-stage.sh::main` `verify_preconditions` call | `bin/run-stage.sh:503` |
| `bin/run-stage.sh::main` `skip_dispatch` block (insertion-point boundary) | `bin/run-stage.sh:534-541` |
| `bin/run-stage.sh::main` `mkdir -p "$(issue_dir "$ident")"` (insertion-point boundary) | `bin/run-stage.sh:546` |
| `bin/run-stage.sh::main` dispatch.sh call | `bin/run-stage.sh:562-565` |
| `bin/run-stage.sh::main` wait-shape detection block (ENG-45) | `bin/run-stage.sh:702-741` |
| `bin/run-stage.sh::main` agent-contract validator | `bin/run-stage.sh:753-766` |
| `bin/run-stage.sh::main` `_post_dispatch_apply_halt` invocation | `bin/run-stage.sh:813` |
| `bin/run-stage.sh::main` `verdict_handler` call (success path) | `bin/run-stage.sh:823` |
| `bin/run-stage.sh::main` success-path state cleanup | `bin/run-stage.sh:851-855` |
| `bin/run-stage.sh:21-22` source verdict-handler.sh | `bin/run-stage.sh:21-22` |
| `bin/run-stage.sh:147-148` `summary_path` derivation pattern | `bin/run-stage.sh:147-148` |
| `bin/run-stage.sh:158-160` existing `gh pr list --head … --state {open,all} --json url` invocation | `bin/run-stage.sh:158-160` |
| `bin/run-stage.sh::_handle_wait` halt-marker post (linear.sh add-comment direct-body pattern) | `bin/run-stage.sh:454-456` |
| `bin/run-stage.sh` source-and-stub sentinel | `bin/run-stage.sh:879-881` |
| `bin/poll.sh:34` stage:released terminal comment | `bin/poll.sh:34` |
| `bin/poll.sh::_poll_classify_labels` halted branch (vacate on pipeline-halt marker) | `bin/poll.sh:217-233` |
| `bin/poll.sh::_poll_classify_labels` reviewing branch (review_should_dispatch gate) | `bin/poll.sh:234-264` |
| `bin/poll.sh::_poll_classify_labels` else branch (advanceable=true for stage:building no-halt no-marker) | `bin/poll.sh:265-267` |
| `bin/verdict-handler.sh` public-functions docstring | `bin/verdict-handler.sh:6-10` |
| `bin/verdict-handler.sh::_VH_FORWARD_TRANSITIONS` (building=released row) | `bin/verdict-handler.sh:25-26` |
| `bin/verdict-handler.sh::find_fresh_verdict` wait-shape exclusion | `bin/verdict-handler.sh:113` |
| `bin/verdict-handler.sh::apply_transition` (idempotent five-step, post_waypoint param) | `bin/verdict-handler.sh:154-184` |
| `bin/verdict-handler.sh::apply_transition` waypoint post | `bin/verdict-handler.sh:158-162` |
| `bin/verdict-handler.sh::apply_transition` add-label / drain / remove-label | `bin/verdict-handler.sh:164-166` |
| `bin/verdict-handler.sh::apply_transition` released native-state Done hook | `bin/verdict-handler.sh:176-184` |
| `bin/branch-name.sh` (returns `feat/<id-lower>-<slug>` or `fix/<id-lower>-<slug>`) | `bin/branch-name.sh:31` |
| `bin/on-new-release.sh` Part 1 sweep (stage:building → stage:released safety net) | `bin/on-new-release.sh:25-58` |
| `bin/run-stage-test.sh::gh` stub | `bin/run-stage-test.sh:46-52` |
| `bin/run-stage-test.sh::linear.sh` stub (rebuild used by ENG-45 cases) | `bin/run-stage-test.sh:885-905` |
| `bin/pipeline-events.json::halt_reasons` registry | `bin/pipeline-events.json:10-19` |
| `bin/pipeline-events.json::wait_reasons` registry | `bin/pipeline-events.json:20-23` |
| `bin/pipeline-events.json::stages` registry (includes `building`) | `bin/pipeline-events.json:47-56` |
| `learned-rules/harness/` slug dir (only `project-profile.md` currently) | `learned-rules/harness/project-profile.md` (build.md added by D-004) |
| `learned-rules/twinning/build.md` (header convention + `Rule Bld-NNN` template referenced by D-004) | `learned-rules/twinning/build.md` |

Predecessor brainstorms used as prior art:

| Name | Path |
| --- | --- |
| ENG-45 (build-agent soft preconditions) | `docs/brainstorms/2026-04-28-build-agent-soft-preconditions-p2-p5-should-re-dispatch-not-halt-for-human-design.md` |
| ENG-54 (single human-approval gate at build P2) | `docs/brainstorms/2026-04-30-eng-50-review-stage-reframe-design.md` |
| ENG-58 (atomic resume) | `docs/brainstorms/2026-05-02-eng-58-halt-sh-resolve-atomic-state-reset-clean-wait-skip-until-rejection-counter-side-state-design.md` |
| ENG-60 (vocabulary simplification) | `docs/brainstorms/2026-05-02-pipeline-vocabulary-simplification-design.md` |
| ENG-62 predecessor (this ticket, earlier draft) | `docs/brainstorms/2026-05-03-eng-62-build-p2-still-emits-awaiting-approval-on-post-merge-dispatches-despite-non-bot-approved-review-existing-design.md` |

No referenced item is non-existent or speculative.

## 9. Scope check vs Linear issue

The Linear issue's IN list maps to:

- ✅ **AC-1.** Add a regression test that simulates a post-merge PR
  with one non-bot APPROVED review and asserts that P2 does NOT emit
  a wait. **D-003 covers this** — the orchestrator gate ensures the
  wait is never emitted (the agent is never dispatched). The test
  asserts on the orchestrator side: `gh` stub returns `MERGED` → no
  `dispatch.sh` invocation, transition applied. This is a faithful
  superset of AC-1's intent ("the agent should proceed to verify
  merge state and emit verdict pass") — the orchestrator does that
  step on the agent's behalf.
- ✅ **AC-2.** Document the observed-vs-prompt discrepancy and the
  prevailing hypothesis in `learned-rules/harness/build.md`. **D-004
  commits to this**; the file is created in the implementation phase
  under the `pipeline:rule-reviewed` gate. The rule body should also
  include a one-line note about the new comment-thread shape
  (transition waypoint appearing without a preceding `verdict pass`
  marker), so future operators recognise it as ENG-62's fingerprint
  and not a protocol violation.
- ✅ **AC-3.** After fix, the next merged PR transitions to
  `stage:released` on the FIRST post-merge tick. **D-001 fires on
  the first tick where `state == MERGED`**, calls `apply_transition`
  directly. **Operator verification recipe:**

  1. After the next merged PR (call it ENG-N), wait one tick (≤ 5
     min) and run:
     ```
     bash bin/pipeline.sh status ENG-N
     ```
     Expected event sequence ends with:
     ```
     <ts>  {"event":"transition","from":"building","to":"released"}
     ```
     With **no preceding `verdict result=pass stage=building`**
     comment in the same tick window — that absence is ENG-62's
     fingerprint (the orchestrator gate fired, no agent involved).

  2. Confirm the metrics row landed:
     ```
     jq -c 'select(.issue=="ENG-N" and .outcome=="merged-pre-dispatch")' \
       $PROJECT_STATE_DIR/metrics/events.jsonl | tail -1
     ```
     Expected: a single JSON object with
     `outcome:"merged-pre-dispatch"`, `stage:"building"`, non-zero
     `duration_ms`. Absence means the gate did not fire — investigate
     `gh` reachability.

  3. Confirm the issue's stage label transitioned cleanly:
     ```
     bash bin/linear.sh stage-of ENG-N
     ```
     Expected: `stage:released`.

OUT list (no scope sprawl):

- ✅ No changes to `_fresh_wait_reason` / `_handle_wait` (D-005).
- ✅ No changes to `bin/poll.sh` (D-005).
- ✅ No changes to `bin/halt-sprawl-test.sh` /
  `bin/run-local-sweep-test.sh` (D-005).
- ✅ No new marker shape or registry entry (D-005).
- ✅ No changes to `bin/dispatch.sh::allowed_tools_for` (D-005).
- ✅ No retrofit of analogous gates to other stages (out of scope per
  the Linear issue's narrow framing).

**Pre-existing observation logged for follow-up (NOT in scope):**
`bin/run-stage.sh:454`'s `_handle_wait` halt body uses reason
`external-signal-budget-exhausted`, which is NOT in
`bin/pipeline-events.json::halt_reasons`. The marker is posted via
`linear.sh add-comment` directly (bypassing `pipeline.sh event`'s
registry validation), so runtime works — but parsers that walk the
registry to interpret halt comments will not recognise the reason.
**File a separate Linear issue** rather than bundling here. Recommended
title: "Register `external-signal-budget-exhausted` in
`pipeline-events.json::halt_reasons` or migrate `_handle_wait` to a
registered reason." This is the pre-existing gap also flagged in the
2026-05-03 predecessor brainstorm (§9); leaving it buried risks
treating it as either fixed or deliberately tolerated.

## 10. Persona review

This section records each persona's verdict (PASS / CONCERN / FAIL)
and a one-paragraph summary of resolved findings.

### Iteration 1

- **Design lens — PASS.** D-001 + D-002 + D-005 are mutually
  reinforcing. The pre-dispatch gate is the load-bearing primitive;
  the prompt P0 is symmetric (identical query shape) so the two
  paths cannot drift. The direct-`apply_transition` call eliminates
  the orchestrator-talking-to-itself round-trip and the consequent
  read-after-write-consistency assumption. Insertion point is
  structurally anchored (after the `skip_dispatch` block, before
  `mkdir -p $(issue_dir …)`) — resilient to unrelated edits in the
  same neighbourhood. The file already has several stage-keyed
  short-circuit paths; one more is acceptable and cleaner than
  widening the blast radius into `poll.sh`.

- **Security lens — PASS.** Stage-keyed gate (`case "$stage" in
  building) ;; *) return 1 ;; esac`) prevents cross-stage forgery.
  Explicit `local PIPELINE_WRITER=orchestrator; export PIPELINE_WRITER`
  in the helper mirrors `_handle_wait`'s defensive lane attribution
  (run-stage.sh:382-383) — inherited default is correct today, but
  explicit assignment prevents silent lane-violation if a future
  caller invokes the helper from an agent sub-shell. No new env-var
  surface. No new tool-allowlist entry (build's existing allowlist
  already permits `gh pr` calls). No new state file. The transition
  waypoint body posted via `apply_transition` is constructed from
  string literals plus the `from`/`to` stage names; no
  user-controlled fragment can land in the marker. Fail-open on `gh`
  outage is the safer default for an availability-vs-silent-halt
  tradeoff.

- **Scope guardian — PASS.** D-005 enumerates non-changes
  exhaustively (poll.sh, _fresh_wait_reason, _handle_wait,
  classify-failure.sh, scope-check.sh, lane fence, registry,
  on-new-release sweep, dispatch.sh tool allowlist). The
  pre-existing `external-signal-budget-exhausted` registry gap is
  surfaced as out-of-scope follow-up rather than bundled. The
  prompt change is minimal (one new precondition above P1, one
  one-sentence reference in the precondition-ordering clause).

- **Coherence — PASS.** D-001 + D-002 share the same `gh pr list
  --head <branch> --state all --json state --jq '.[0].state // ""'`
  query and the same `== MERGED` comparison; symmetry is explicitly
  noted as load-bearing. The §6 race-window analysis is consistent
  with the §3 happy-path data flow (gate runs in the same tick that
  detects merge; agent never dispatches). The §4.4 in-flight
  migration uses the existing ENG-58 atomic-resume primitive —
  consistent with §8.1's prior-art note. The fail-open contract
  (D-006) is consistent with the §5 error-handling table.

- **Product lens — PASS.** Cost recovery is concrete (≈ $1.50/tick
  saved, $22 wasted in the observed session reduced to ~$0). Operator-
  facing surface is unchanged (`pipeline.sh decide --action
  continue` still works for the halted-population recovery, no new
  label, no new sig). The fix is invisible to operators in the
  happy case and visible only as a new metrics outcome
  (`merged-pre-dispatch`) when it fires. Q2's two operator queries
  give ops a documented post-deploy verification path and a manual
  health-check tripwire, with promotion to automated only if the
  gate is observed to silently fail in the field.

- **Feasibility lens — PASS.** Every cited path:line in §8.4 was
  re-verified against the current worktree before this iteration.
  Key items confirmed: `bin/run-stage.sh:301-344` (`_fresh_wait_reason`),
  `bin/run-stage.sh:381-470` (`_handle_wait`), `bin/run-stage.sh:454-456`
  (linear.sh add-comment direct-body pattern), `bin/run-stage.sh:702-741`
  (wait-shape detection), `bin/run-stage.sh:823` (verdict_handler call),
  `bin/run-stage.sh:534-541` and `bin/run-stage.sh:546` (insertion-point
  boundaries), `bin/poll.sh:265-267` (else branch), `bin/poll.sh:34`
  (terminal released), `bin/verdict-handler.sh:25-26` (building=released),
  `bin/verdict-handler.sh:113` (wait exclusion),
  `bin/verdict-handler.sh:154-184` (apply_transition idempotency),
  `bin/verdict-handler.sh:6-10` (apply_transition is a documented
  public function), `AGENT_PROMPTS.md:1213-1246` (P1 + P2 prose +
  wait-exit), `AGENT_PROMPTS.md:1208-1211` (precondition ordering),
  `bin/pipeline-events.json:10-19` and `:20-23` and `:47-56` (registry
  shape unchanged post-ENG-60). The helper sketch fits the existing
  source-and-stub test pattern; no new test infrastructure needed.
  Q1 (retrospective §1 outcome filter) is the only "assumed" item;
  it's a straightforward dry-run verification during implementation,
  not a blocker.

**Final tally for iteration 1: 6/6 PASS, gate P0 = 0.** Proceeding
to planning.
