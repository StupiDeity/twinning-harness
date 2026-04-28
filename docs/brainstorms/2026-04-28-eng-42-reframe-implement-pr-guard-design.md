---
linear: ENG-42
title: Reframe implement-stage PR-ownership guard — state-check → action-check + idempotent UI
date: 2026-04-28
status: draft
---

# Reframe implement-stage PR-ownership guard

## 1. Problem

`bin/run-stage.sh:373-384` halts the implement stage whenever
`gh pr list --head <branch> --state open` returns a count > 0:

```bash
if [[ "$stage" == "implement" ]]; then
  pr_count="$(gh pr list --head "$branch" --state open --json number --jq 'length' …)"
  if (( pr_count > 0 )); then
    bash "$SCRIPT_DIR/guards.sh" bump "$ident" implement_rejection || true
    classify_failure "$ident" "$stage" "skip-until-human-acts" \
      "implement stage opened a PR on $branch — UI stage should own PR creation" 22
    exit 22
  fi
fi
```

The guard exists to enforce the ENG-2 contract that PR creation belongs to the
UI stage, not implement. It does not work as designed:

### 1.1 Wrong signal

The contract says "implement should not *invoke* `gh pr create`." The guard
uses "an open PR exists" as a proxy. The proxy is lossy because:

- Humans can open PRs.
- A prior cycle's UI stage opened the PR (`reviewing → implementing` loopback).
- A future stage might open one and the implement stage re-runs.

State-of-the-world is not the contract question. Action-of-this-dispatch is.

### 1.2 Lane already prevents the threat

`bin/dispatch.sh::allowed_tools_for` for the implement stage:

```
Read,Write,Edit,Grep,Glob,TaskCreate,
Bash(git:*),Bash(cargo:*),Bash(bun:*),Bash(rustc:*),Bash(jq:*),Bash(awk:*),
Bash(bash .pipeline/bin/linear.sh:*)
```

No `Bash(gh:*)`. No `Agent` tool for sub-delegation. The implement agent is
structurally incapable of opening a PR. The guard cannot fire on a true
implement-stage violation; it can only fire on PRs opened by other actors —
i.e., on false positives.

### 1.3 Non-idempotent UI stage

The UI stage's contract is "open a PR." That's a one-shot action. The
pipeline's state machine has a designed `reviewing → implementing` transition
(verdict-handler.sh:25, request-changes loopback). On loopback:

1. Implement re-runs against a branch that already has a PR (from prior UI).
2. The state-check guard fires false-positive (§1.2).
3. If the issue eventually re-enters UI, UI tries to re-open a PR.

The whole class disappears if UI's contract is reframed to "ensure a PR
exists for this branch."

### 1.4 Empirical evidence (ENG-26)

Linear comments on ENG-26:

```
05:34  <!-- pipeline-metric: implement_rejection --> + halt #1 (false positive)
06:36  human resume
06:59  cycle proceeds: implement → ui → reviewing
13:47  review request-changes → reviewing → implementing
14:21  implement re-ran cleanly (commits + stage-summary)
14:22  <!-- pipeline-metric: implement_rejection --> + halt #2 (false positive,
       same evidence)
```

Same false positive twice. Each `--decision resume` is forgotten on the next
tick. (ENG-34 will start emitting human-decision events; auto-resume on
fingerprint match is a downstream consumer of that work — out of scope here.)

## 2. Decisions

- **D-001.** Delete `bin/run-stage.sh:373-384`. The lane already prevents the
  threat; the guard only fires false positives.

- **D-002.** UI stage idempotency is **prompt-level**. AGENT_PROMPTS.md UI
  section gets a precondition: "if `gh pr list --head {branch} --state open`
  returns ≥1, skip the `gh pr create` step and proceed to the rest of UI."
  No new tool-lane changes, no new guards — the agent's own preflight
  handles it. UI is allowed to invoke `gh pr create` in its lane; we don't
  forbid the tool, we just instruct idempotent use.

- **D-003.** No new Linear labels or markers. No protocol additions.

- **D-004.** No backwards-compat shim for the deleted guard. Existing tests
  that assert the bump (`bin/run-stage-test.sh` case-13 specifically) are
  rewritten or removed, not preserved.

- **D-005.** No retroactive cleanup of historical
  `<!-- pipeline-metric: implement_rejection -->` markers on ENG-26 or
  elsewhere. Bump count is honored. Going forward they only fire on real
  action (i.e., on real protocol violations once the transcript-assertion
  follow-up lands; until then, the implement-stage `implement_rejection`
  bump path collapses to scope-violation only — see Task 3 of plan).

- **D-006.** Defense-in-depth via transcript-based assertion is deferred to
  ENG-43 (follow-up). Rationale: the implementation needs the stream-json
  capture infrastructure that lives on ENG-26's branch
  (`feat/eng-26-track-tokens-cost-and-cache-stats-per-stage`). Building a
  duplicate stream-json renderer on this branch would create a guaranteed
  merge conflict with ENG-26 and ship the same code twice. ENG-43 picks up
  after ENG-26 lands on main, when `$raw_capture` and the stream-json
  pipeline are available. The full design — `assert_no_tool_invocation`
  helper, six-fixture test suite, soft-fail on transcript absence,
  tool_use-only granularity — is captured below for ENG-43 to pick up
  verbatim.

  **Why this is acceptable.** The lane already prevents the threat (§1.2).
  The deleted guard's only true-positive class is "agent escapes its lane
  via some currently-unknown mechanism" — a hypothetical that the
  transcript assertion would catch. ENG-43 closes the defense-in-depth gap
  on a realistic timeline (next PR after ENG-26 merges) without forcing
  scope creep here.

### 2.1 Captured design for ENG-43 (transcript-based assertion)

When ENG-43 is picked up, build on stream-json capture from ENG-26 and add:

- **Helper `assert_no_tool_invocation <transcript> <pattern>` in
  `bin/dispatch.sh`.** Single jq fork (matches ENG-26's D-002 fork-budget
  constraint). Returns 0 on no-match; prints the matched command and
  returns 1 on first match.
- **Stream-json shape contract.** Match against
  `assistant.message.content[]?` blocks where
  `(.type == "tool_use" and .name == "Bash" and (.input.command // "") |
  startswith($pattern))`. Do NOT match agent narration in `text` fields,
  or JSON-escaped string content. `fromjson?` per line tolerates malformed
  and future event types.
- **Soft-fail on transcript absence.** Empty/missing `$raw_capture` →
  return 0. Avoids new false positives for dry-run / planning-only paths.
- **Match-failure mode.** Same exit code (22) and policy
  (`skip-until-human-acts`) as the deleted guard. Reason text:
  `implement-stage transcript invoked forbidden tool: <command>`.
- **Sequencing.** Run before `$raw_capture`'s `RETURN` trap fires (the
  trap is the existing cleanup; assertion just slots in before it).
- **Six test fixtures.** Tool_use match (positive), allowed-only-tool_uses
  (negative), agent narration prose (negative), JSON-escaped text
  (negative), malformed line tolerance (positive when other lines match),
  empty/missing transcript (negative — soft-fail).
- **Generalization later.** ENG-43 ships one call site (implement). Other
  "agent shouldn't have done X" guards — no `git push --force` from
  review, no `gh pr merge` outside build — are subsequent work that reuse
  the helper.

## 3. Rejected alternatives

- **3.1 Cycle-aware skip on the existing state-check guard.** ("If a prior
  `<!-- pipeline-stage-summary: ui -->` exists, skip the guard.") Rejected
  because it papers over §1.2 — the guard still cannot catch a true
  violation. We'd be making a broken guard slightly less wrong.

- **3.2 Time-gate the existing guard.** ("Snapshot PR count at dispatch
  start; halt only if it grew.") Better than the current guard but still
  uses a state proxy. A human creating a PR mid-dispatch would still
  false-positive. Loses to D-001+ENG-43 because the transcript directly
  answers the contract question.

- **3.3 Lock `gh pr create` out of UI's lane and let implement own PR
  creation.** Rejected: ENG-2's split exists for review-stage reasons (the
  review agent expects to find a PR ready when reviewing starts; UI's "open
  PR" is the synchronization point). Reshuffling stage ownership is a much
  larger change than this PR's scope.

- **3.4 Halt-fingerprint cache for auto-resume.** Discussed in conversation
  with the user; depends on ENG-34's `human-decision` event emission. ENG-34
  is in backlog. Filed as a follow-up (not in this PR).

- **3.5 Stack ENG-42 on top of ENG-26's branch to ship #1+#2+#3 together.**
  Rejected because (a) it creates a stacked-PR ordering dependency
  (ENG-26 must merge first), and (b) the immediate value of ENG-42 is
  unsticking ENG-26 — a stacked PR can't unstick its own base. Splitting
  ENG-42 into "this PR off main" + "ENG-43 after ENG-26 lands" removes the
  ordering hazard at the cost of one extra PR.

- **3.6 Reimplement minimal stream-json capture on this branch.** Rejected
  as guaranteed merge-conflict with ENG-26.

- **3.7 Generalize the transcript assertion across all stages on day one
  (in ENG-43).** Out-of-scope flag for ENG-43 itself. One concrete call
  site (implement) in ENG-43 v1 makes the pattern reviewable;
  generalization is a separate refactor with its own tests.

## 4. Test strategy preview

- **Integration (run-stage-test.sh):**
  - Drop case-13 (PR-opened-too-early state-check); the guard it tested is
    deleted. The implement-stage `implement_rejection` bump path now only
    fires from scope-check rcs 3 and `*` (cases 11, 12 still cover those).
  - No new positive case is added in this PR — exercising "implement runs
    cleanly with a pre-existing PR on the branch" requires the dispatch
    transcript scaffolding that lands with ENG-43.
  - Keep cases 11, 12 (SEVERE / unknown-rc scope-violation bumps).

- **Prompt-fence (dry-run.sh):** AGENT_PROMPTS.md edit must keep exactly
  one fenced ``` block in the UI stage section (the load-bearing fence
  count contract from CLAUDE.md). Verified by `bin/dry-run.sh`'s
  render-prompt 9-stage extraction.

- **Smoke (dry-run.sh):** confirms full bash syntax + offline path, no
  regressions in the existing offline section.

## 5. Failure modes (preview; full table in plan doc)

| Failure mode | Severity | Test |
|---|---|---|
| Pre-existing PR on branch causes false halt on implement loopback | critical (current bug) | manual: ENG-26 advances cleanly after `halt.sh resolve --decision resume` |
| UI agent re-enters with PR already open | high | manual + dry-run: UI prompt fence stays valid; agent's preflight skips `gh pr create` |
| Implement agent escapes its lane via an unknown mechanism | hypothetical | deferred to ENG-43 (transcript assertion) |
| Scope-violation rc=3 still bumps `implement_rejection` | covered by existing test | run-stage-test.sh case-11 |
| Scope-violation unknown rc still bumps `implement_rejection` | covered by existing test | run-stage-test.sh case-12 |

## 6. Out of scope

- Auto-resume on prior human decisions (depends on ENG-34).
- Generalizing the transcript assertion library to all stages.
- Halt-fingerprint persistent cache.
- Refactoring the stage chain to a DAG-of-tasks-with-preconditions.
- Closing the open PR on `reviewing → implementing` loopback. We want it
  open — the review thread lives there.

## 7. Why this also unsticks ENG-26

ENG-26 is currently halted at exit 22 / `skip-until-human-acts` with reason
"implement stage opened a PR on feat/eng-26-… — UI stage should own PR
creation." That reason text is generated by the very lines (run-stage.sh:373-384)
this PR deletes. After merge, the next tick on ENG-26:

1. Reads `issue-state.json` (still says skip-until-human-acts) → skipped.
2. Operator runs `bash bin/halt.sh resolve ENG-26 --decision resume` →
   removes `pipeline:halted`, posts decision marker.
3. Next tick: `verdict_handler` advances ENG-26 from `stage:implementing` to
   `stage:ui`. The UI stage runs idempotently (D-002), sees PR #12 already
   open, no-ops the `gh pr create` step, posts the UI stage-summary.
4. Cycle proceeds: ui → reviewing → (review re-checks the new commits).

No further intervention. The same path also unsticks any future
`reviewing → implementing` loopback.
