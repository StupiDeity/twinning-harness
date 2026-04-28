---
linear: ENG-42
topic: Reframe implement-stage PR-ownership guard — state-check → action-check + idempotent UI
date: 2026-04-28
status: draft
---

# Plan — ENG-42 reframe implement-stage PR-ownership guard

Implementation plan for the design in
`docs/brainstorms/2026-04-28-eng-42-reframe-implement-pr-guard-design.md`.

## Goal

Land a single PR off `main` that:

1. Deletes the false-positive state-check guard at `bin/run-stage.sh:373-384`.
2. Reframes the UI stage's PR-creation step in `AGENT_PROMPTS.md` as
   idempotent — skip `gh pr create` if a PR is already open on the branch.
3. Updates `bin/run-stage-test.sh` to drop the case that exercises the
   deleted guard.

After merge:
- ENG-26's halted implement stage advances cleanly via
  `bin/halt.sh resolve ENG-26 --decision resume`.
- Future `reviewing → implementing → ui → reviewing` loopbacks complete
  without firing the false positive.
- ENG-43 (follow-up) ships the transcript-based assertion as
  defense-in-depth on top of ENG-26's stream-json infrastructure once
  ENG-26 lands on main.

## Assumption inventory

- A-001: `bin/dispatch.sh::allowed_tools_for` for the implement stage does
  not include `Bash(gh:*)` and does not include `Agent`. Verified by
  reading `bin/dispatch.sh:44`. The lane already enforces the contract the
  guard was claiming to enforce.
- A-002: AGENT_PROMPTS.md's UI section has exactly one fenced ``` block
  enclosing the prompt body (the load-bearing fence-count contract from
  CLAUDE.md "AGENT_PROMPTS.md is load-bearing"). Edits must keep the count
  at exactly two fence lines in column 0 within the section.
- A-003: `gh pr list --head <branch> --state open --json number --jq 'length'`
  is the existing harness idiom for "is a PR open on this branch?" (used in
  the about-to-be-deleted guard at `bin/run-stage.sh:376`); the UI prompt
  reuses the same idiom for its preflight.
- A-004: `bin/run-stage-test.sh` follows the source-and-stub pattern from
  CLAUDE.md "How tests work" — case-13 is a self-contained block that can
  be removed without touching neighbours.
- A-005: `bin/dry-run.sh` validates AGENT_PROMPTS.md by extracting all 9
  stage prompts via `bin/render-prompt.sh`, which dies if the fence count
  is not exactly 2 per section. This is the smoke test for A-002.
- A-006: `bin/scope-check.sh` rcs 3 (SEVERE) and `*` (unknown) still bump
  `implement_rejection` after this PR (run-stage.sh lines 354 and 360,
  unchanged); cases 11 and 12 in run-stage-test.sh continue to cover
  those bump paths.
- A-007: `failure_outcome_for_exit 22 *` is mapped in common.sh
  (existing exit code from the deleted guard); no new outcome name is
  needed because no new halt path is added.

## File Structure

```
bin/
  run-stage.sh              modified  — delete lines 373-384 (PR-opened state-check guard)
  run-stage-test.sh         modified  — drop case-13 (PR-opened-too-early)

AGENT_PROMPTS.md            modified  — UI section: idempotent PR-creation precondition

docs/
  brainstorms/2026-04-28-eng-42-reframe-implement-pr-guard-design.md   NEW
  plans/2026-04-28-eng-42-reframe-implement-pr-guard.md                NEW (this file)
```

No changes to `bin/dispatch.sh`, `bin/dispatch-test.sh`, `CLAUDE.md`. Those
land in ENG-43 along with the transcript assertion.

## Command API contract

No CLI flag changes. `bin/run-stage.sh` argv shape unchanged. The
operator-facing surface for the deleted guard simply disappears — there is
no replacement halt code path in this PR. The implement stage's only
remaining halt sources are scope-check rcs (cases 11/12 in run-stage-test)
plus the agent-contract validator at `run-stage.sh:386-409` (exit 25 on
no-summary-no-marker), all unchanged.

## Backend tasks

(Bash harness — no Tauri/Rust backend.)

### Task 1 — Delete `bin/run-stage.sh:373-384`

**depends_on:** []

Remove the entire block:

```bash
if [[ "$stage" == "implement" ]]; then
  if command -v gh >/dev/null 2>&1; then
    local pr_count
    pr_count="$(gh pr list --head "$branch" --state open --json number --jq 'length' 2>/dev/null || printf '0')"
    if (( pr_count > 0 )); then
      bash "$SCRIPT_DIR/guards.sh" bump "$ident" implement_rejection || true
      classify_failure "$ident" "$stage" "skip-until-human-acts" \
        "implement stage opened a PR on $branch — UI stage should own PR creation" 22
      exit 22
    fi
  fi
fi
```

Replace with nothing — control flow falls straight from the
gotcha-trailer scan to the agent-contract validator. No block, no
comment-stub, no TODO reference to ENG-43 in code (the brainstorm + plan
docs carry that reference; code stays clean).

### Task 2 — Drop run-stage-test.sh case-13

**depends_on:** []

Remove lines 338-356 of `bin/run-stage-test.sh` (the "Case 13:
pr-opened-too-early bumps implement_rejection" block, including the
`reset_capture` / `reset_guards_capture` setup and the assertion). The
case is purely a behavioral mirror of the deleted run-stage.sh block; with
the guard gone, there is no behavior to mirror.

Do **not** renumber subsequent cases (cases 14-24). The ENG-26 review
already flagged renumbering risk as a nit (cases 19-24 inserted before
case-15 deliberately); leave the gap rather than churn line numbers.
Add a `# Case 13: removed in ENG-42 (PR-opened-too-early guard deleted)`
sentinel comment in place so the gap is self-explanatory.

### Task 3 — UI stage idempotent PR-creation in AGENT_PROMPTS.md

**depends_on:** []

In the UI Agent section, edit the `PR creation (at exit — UI stage owns
PR creation for this branch):` block (currently lines 663-691). Insert an
**Idempotency** sub-bullet before the `Open the PR against main from
{branch_name} using this template:` line:

```
PR creation (at exit — UI stage owns PR creation for this branch):

  Idempotency precondition (MANDATORY, BEFORE `gh pr create`):
  - Run: gh pr list --head {branch_name} --state open --json number --jq 'length'
  - If the result is 0, proceed with `gh pr create …` per the template below.
  - If the result is ≥ 1, a PR already exists on this branch (typically
    from a prior cycle's UI stage that was rerun via a `reviewing →
    implementing → ui` loopback). Skip `gh pr create` entirely; do NOT
    attempt to re-create or amend the PR. Proceed to the rest of the UI
    stage (stage summary, push, completion). The existing PR's number is
    available via the same `gh pr list` call with `--json number`.

  Open the PR against main from `{branch_name}` using this template:
    …
```

Constraint: the section's enclosing fenced ``` block (which wraps the
entire UI prompt) must remain intact — exactly two column-0 ``` fences
inside the `## 4. UI Agent` section. The Idempotency sub-bullet's prose
contains no triple-backtick fences.

## Failure mode → test map

| Failure mode | Layer | Test |
|---|---|---|
| Pre-existing PR on branch causes false halt on implement | (was: integration case-13) | **Removed**: the guard that produced the halt is deleted; the failure mode no longer exists. ENG-26 advancing post-merge is the manual confirmation. |
| UI stage re-enters with PR already open | manual / dry-run | `bin/dry-run.sh` confirms AGENT_PROMPTS.md still parses (fence count = 2 per section); manual confirmation when ENG-26's UI stage re-runs post-merge. |
| Scope-violation rc=3 still bumps `implement_rejection` | unit | `bin/run-stage-test.sh` case-11 (unchanged). |
| Scope-violation unknown rc still bumps `implement_rejection` | unit | `bin/run-stage-test.sh` case-12 (unchanged). |
| Implement agent escapes its lane and invokes `gh pr create` | hypothetical | Deferred to ENG-43 (transcript-based assertion). The lane denies the tool, so the only way to hit this is a future lane misconfig — covered when ENG-43 lands. |

## Test plan

- [ ] `bash bin/run-stage-test.sh` — all cases except removed case-13
  pass; cases 11 and 12 still cover the remaining `implement_rejection`
  bump paths. Pre-existing latent `REPO_ROOT: unbound variable` at
  line ~391 is unrelated (ENG-23 leftover, also fails on `main`); the
  EXIT trap masks the rc and the script still exits 0.
- [ ] `bash bin/dispatch-test.sh` — unchanged; still passes.
- [ ] `bash bin/scope-check-test.sh` — unchanged; still passes.
- [ ] `bash bin/verdict-handler-test.sh` — unchanged; still passes.
- [ ] `bash bin/halt-sprawl-test.sh` — unchanged; still passes.
- [ ] `bash bin/halt-sprawl-adversarial-test.sh` — unchanged; still passes.
- [ ] `bash bin/run-local-sweep-test.sh` — unchanged; still passes.
- [ ] `bash bin/run-local-helpers-adversarial-test.sh` — unchanged; still passes.
- [ ] `bash bin/classify-failure-test.sh` — unchanged; still passes.
- [ ] `bash bin/poll-slot-test.sh` — unchanged; still passes.
- [ ] `bash bin/verdict-adversarial-test.sh` — unchanged; still passes.
- [ ] `bash bin/mutex-test.sh` — unchanged; still passes.
- [ ] `bash bin/dry-run.sh` (offline section) — bash syntax + render-prompt
  9-stage extraction (validates A-002).
- [ ] Manual (post-merge): operator runs
  `bash bin/halt.sh resolve ENG-26 --decision resume`; ENG-26 advances
  cleanly through `stage:implementing → stage:ui → stage:reviewing`. UI
  stage's preflight observes PR #12 is open and skips `gh pr create`.

## Frontend tasks

No frontend tasks. This is a bash harness; there is no UI surface in this
repo.

## Rollout

- Single PR off `main`. No flags. No phased rollout.
- Merge order: this PR can merge before, in parallel with, or after
  ENG-26 — they touch disjoint files (`bin/run-stage.sh` lines 373-384
  here; `bin/dispatch.sh` + `bin/run-stage.sh` cost-flag plumbing in
  ENG-26's diff). The ENG-26 PR's review-rejection loopback unsticks
  itself once this lands and an operator runs `halt.sh resolve`.
- After merge, file ENG-43 with the captured design from the brainstorm
  §2.1 and re-engage the harness on it.
- Post-merge cleanup: the harness orchestrator was tripped to
  `orchestrator.paused=true` by the consecutive-failure breaker during
  ENG-42's implement-stage `plan_gap` halt (3 consecutive failures —
  ENG-42 plus prior). Operator unpauses by setting
  `orchestrator.paused=false` in the state file; the next successful
  tick clears the breaker counter.

## Open questions

None. The implementation is mechanical (one delete, one prose edit, one
test removal). The architectural decisions are settled in the brainstorm.

## Implementation history note

An earlier revision of this plan included Tasks 1-2 for an
`assert_no_tool_invocation` helper in `bin/dispatch.sh`. The harness's
implement agent picked up ENG-42 from Linear, observed that those tasks
referenced the `_render_and_capture_stream` and `$raw_capture`
infrastructure that lives only on ENG-26's branch (not on `main`), and
halted with `<!-- pipeline-metric: plan_gap -->` per the prompt's
plan-gap precondition. The agent saved a project-state memory
(`project_eng42_eng26_chicken_and_egg`) and posted a 3-defect summary to
ENG-42. The current plan reflects the narrowed scope decided after that
halt (brainstorm D-006); the deferred work moves to ENG-43.
