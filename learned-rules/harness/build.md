# Learned Rules — Build Agent

> **Who writes:** Retrospective agent (from failed merges, broken post-merge CI, and
>                 config-drift incidents).
> **Who reads:** Build agent (appended to base prompt at dispatch time).
> **Format:** Each rule is a directive the agent must follow, with context on why.
> **Shelf life:** 60 days. If the problem hasn't recurred, the rule may be unnecessary.
> **Human checkpoint:** New rules require human approval before commit (see .pipeline/config.json).

---

### Rule Bld-001: post-merge dispatches must short-circuit on `state == MERGED`
**Added:** 2026-05-06
**Expires:** 2026-09-04
**Last verified:** 2026-07-06
**Source:** ENG-62 — five wasted dispatches per merged PR observed on
            ENG-43 (PR #41) and ENG-58 (PR #42), 2026-05-02. Agent
            emitted `verdict wait --reason awaiting-approval` post-merge
            despite a non-bot APPROVED review existing and the prompt
            being correctly written against `gh pr view --json reviews`
            (per commit 941218f9).

**Rule:** Before evaluating P1–P7, run

    gh pr list --head {branch_name} --state all --json state \
      --jq '.[0].state // ""'

If the result is `MERGED`, run

    bash bin/pipeline.sh event {issue_id} verdict pass --stage building

and exit. The orchestrator's pre-dispatch gate
(`bin/run-stage.sh::_pre_dispatch_merge_gate`) uses the IDENTICAL query
and short-circuits BEFORE you are dispatched in this state; this rule
is the agent-side belt to the orchestrator's braces. The symmetric
query shape is load-bearing — divergent definitions of "post-merge"
(e.g., one path uses `gh pr view --json state` which requires a PR
number) would inevitably drift.

**Why:** Post-merge, `gh pr list --head <branch> --state open` returns
0 PRs because `gh pr merge --auto --delete-branch` deletes the branch
ref. The precondition-ordering clause says P1 fail should halt-for-
human, but agents in production have been observed to fall back to
`gh pr view --json reviewDecision` (the brittle pre-941218f9 path) and
emit a wait verdict instead. The orchestrator gate eliminates the
dispatch cost; this prompt-side rule is defense-in-depth for any future
code path that invokes `dispatch.sh` outside `run-stage.sh::main`.

**Evidence:** docs/brainstorms/2026-05-06-eng-62-build-p2-still-emits-awaiting-approval-on-post-merge-dispatches-despite-non-bot-approved-review-existing-design.md
§1.2; metrics events `outcome=merged-pre-dispatch` in
`$PROJECT_STATE_DIR/metrics/events.jsonl` after the gate ships.
