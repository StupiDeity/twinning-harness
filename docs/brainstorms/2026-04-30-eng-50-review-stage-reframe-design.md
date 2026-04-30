---
linear: ENG-50
title: Reframe review stage — agent reviews, human approves, orchestrator gates dispatch
date: 2026-04-30
status: draft
---

# Reframe review stage — agent reviews, human approves, orchestrator gates dispatch

## 1. Context

ENG-49 closed eight gaps in the harness, including the move of PR creation
into the orchestrator (`verdict-handler::apply_transition` on `to ==
reviewing`). That work made the orchestrator the canonical PR-opener but
exposed Gap #8: the GitHub App identity that opens the PR is the same
identity that runs the review-stage agent, and GitHub blocks
`gh pr review --approve` and `--request-changes` when reviewer == author.
ENG-49 deliberately left Gap #8 unresolved, with a placeholder followup
proposing two GitHub App identities (PR-creator vs reviewer separation).

That diagnosis was wrong. The actual issue isn't a missing identity —
it's that the review agent has two conflicting jobs:

1. Reviewing the code (analysis, persona checks, finding articulation).
2. Deciding when the pipeline advances past `stage:reviewing`.

Splitting those jobs eliminates the trap entirely. Under the reframe:
- The agent reviews and posts findings.
- Humans approve via GitHub's native PR review UI.
- The orchestrator transitions `reviewing → qa` only when a non-bot
  APPROVED review lands on the current branch HEAD.

No second bot identity is needed. Gap #8 is closed by reframing, not by
adding identity infrastructure.

## 2. Goal

For any harness-driven PR:

- Bot opens PR (already shipped via ENG-49 Task 5).
- Bot agent reviews and posts findings as PR comments.
- Bot agent NEVER posts `gh pr review --approve` or `gh pr review --request-changes`.
- Human reviewer approves via GitHub UI.
- Orchestrator detects the human approval on a subsequent tick and
  advances `reviewing → qa` automatically.
- Bot continues to drive loopback for clear defects via
  `pipeline-rejection: reviewing` markers (no human round-trip required
  for critical/major issues the agent finds).

## 3. Architectural principle (extension of ENG-49's)

ENG-49 established: *side effects of stage transitions belong to the
orchestrator (`verdict-handler::apply_transition`).* This work extends:
*the orchestrator also owns dispatch gating for review — deciding when
to dispatch the agent based on observable PR state.* The agent stays
canonical for verdict-marker authorship; the orchestrator gets smarter
about when to ask the agent to author one.

In the brainstorm we considered three shapes:

- **Shape 1**: orchestrator polls, orchestrator authors transitions
  directly. Eliminates agent dispatches entirely on no-change ticks but
  introduces new marker-protocol semantics (orchestrator-authored
  transitions). Rejected — too much new semantic surface.
- **Shape 2 (α)**: orchestrator dispatches every tick while at
  `stage:reviewing`; agent's preflight short-circuits on no-change.
  Pure pattern-parity with build's existing wait pattern. Rejected — too
  many wasted dispatches.
- **Shape β (chosen)**: orchestrator polls cheap GH state; gates dispatch
  on detected change. Agent still authors all markers. Smaller new
  semantic surface than Shape 1 (just smarter dispatch gating; no new
  marker authorship).

## 4. β mechanics

### Where the gating lives

New helper `bin/review-poll.sh` (sentinel-guarded, source-able from
`poll.sh`). Defines `review_should_dispatch <issue> <branch>` returning
shell-truthy/falsy. `poll.sh`'s existing classification step calls it
before deciding to dispatch a `stage:reviewing` issue. If it returns
false → idle, no dispatch this tick.

### What `review_should_dispatch` checks

Three signals from `gh pr view --json commits,reviews <branch>`:

| Signal | Action |
|---|---|
| PR HEAD SHA differs from `last-review-state.sha` | Dispatch — agent re-reviews on new commits |
| Most recent non-bot review is APPROVED on current HEAD AND `submittedAt > last_processed_approval_at` | Dispatch — agent posts `pipeline-stage-summary: reviewing` |
| Most recent non-bot review is CHANGES_REQUESTED on current HEAD AND `submittedAt > last_processed_cr_at` | Dispatch — agent re-reviews with CR comments as input |
| None of the above | Skip dispatch — issue idles |

The first dispatch into `stage:reviewing` (no `last-review-state` comment
exists yet) is always a dispatch. After that, the orchestrator updates
the `last-review-state` comment to reflect what was just seen.

### Where the state lives

Linear comment with sig `last-review-state/<issue>`, body is JSON:

```json
{
  "sha": "abc1234",
  "last_processed_approval_at": "2026-04-30T10:00:00Z",
  "last_processed_cr_at": null
}
```

Body also includes a marker `<!-- pipeline-state: last-review-state -->`
so the agent (and humans) can grep for the comment when reading
`get-comments`. The dedup sig is `last-review-state/<issue>`; the body
marker is the in-stream identifier — double-channel by design.

Posted via
`bash linear.sh add-or-update-comment last-review-state/<issue> <issue> <body>`.

### Who writes the state

The orchestrator, NOT the agent. Update site: a new helper
`bin/review-state.sh::update_review_state <issue>`, called from
`bin/run-stage.sh` post-dispatch when `stage == reviewing` AND the
agent exited cleanly (regardless of the marker shape it posted —
advance, rejection, or wait).

Bootstrap: when `apply_transition` advances `ui → reviewing`, it also
calls `bootstrap_review_state <issue>` to seed an all-null
`last-review-state` comment. First dispatch sees the bootstrap and
runs as a full review.

### Tick frequency

Same 5-min tick as everything else. No new tick frequency.

### `poll.sh` integration

Single new branch in `_poll_classify_all`'s per-issue logic: for issues
at `stage:reviewing`, source `review-poll.sh` and call
`review_should_dispatch`. If false, classify as `idle`. Otherwise,
classify as advanceable (existing flow).

## 5. Verdict-marker semantics under β

**No new marker types.** All four existing markers are reused. The
change is *when* the agent posts each one.

| Dispatch trigger | What agent does | Marker posted |
|---|---|---|
| First dispatch (bootstrap) | Full review | `pipeline-rejection: reviewing` (+ target `implementing`) if critical/major issues found; else `pipeline-wait: awaiting-approval` (informational) |
| New PR HEAD SHA detected | Full re-review on new code | Same outcomes as bootstrap |
| New non-bot APPROVED on current SHA | Brief preflight: re-confirm approval still on HEAD; advance | `pipeline-stage-summary: reviewing` |
| New non-bot CHANGES_REQUESTED on current SHA | Re-review treating CR comments as additional input | Same outcomes as bootstrap |
| Agent crash / unrecoverable error | (existing path) | `pipeline-halt: agent-blocked` |

### Loopback semantics (preserved)

`pipeline-rejection: reviewing` + `pipeline-rejection-target:
implementing` triggers the existing loopback. The implement agent
re-runs, lands new commits, the new SHA triggers the next
`review_should_dispatch` to fire, review re-runs, cycle continues until
either clean review + human approval lands OR human resolves things via
direct PR commits.

### Premise-failure path (preserved)

`pipeline-rejection: reviewing` + `pipeline-rejection-target:
brainstorming` still loops back to brainstorm for fundamental rethinks.
β doesn't touch this.

### `pipeline-wait: awaiting-approval` is purely informational

`verdict-handler.sh::find_fresh_verdict` ignores `pipeline-wait:`
markers (only matches `pipeline-stage-summary`, `pipeline-rejection`,
`pipeline-halt`). Confirmed by reading
`bin/verdict-handler.sh:84-90`. The `last-review-state` Linear comment
is the orchestrator's source of truth; the wait-marker is for human /
dashboard visibility.

The wait-marker body includes the reviewed SHA explicitly. No
`tick_at:` line is needed (build uses it because build dispatches every
tick under its existing wait pattern; β only dispatches on change).

### Race-condition handling for approval detection

Between `poll.sh`'s "new approval detected" check and the agent's
actual run (~30 seconds typically), the human could push new commits.
The agent's preflight re-confirms the approval is on the current HEAD
SHA before posting `pipeline-stage-summary: reviewing`. If HEAD has
moved past the approval, the agent treats this as a "new SHA"
dispatch instead and re-reviews.

## 6. Review prompt §5 changes

Four targeted spots in `AGENT_PROMPTS.md §5`:

### 6.1 New "Preflight (β)" section at top of fenced block

Inserted after the existing `Read these files first` block:

```
Preflight (MANDATORY — determines what kind of dispatch this is):

  1. Read PR HEAD SHA:
       head_sha=$(gh pr view {branch_name} --json commits --jq '.commits[-1].oid')
  2. Read most recent non-bot review and its commit_id + submittedAt:
       gh pr view {branch_name} --json reviews \
         | jq '[.reviews[] | select(.author.login | test("\\[bot\\]$") | not)] | sort_by(.submittedAt) | last'
  3. Read last-review-state from Linear:
       bash .pipeline/bin/linear.sh get-comments {issue_id} \
         | jq '[.[] | select(.body | contains("<!-- pipeline-state: last-review-state -->"))] | last.body'
       Parse the JSON payload {sha, last_processed_approval_at, last_processed_cr_at}.
  4. Branch on comparison:
     a. APPROVED on current HEAD AND submittedAt > last_processed_approval_at:
        → Skip multi-persona review.
        → Write a brief stage-summary file noting: "Human {login} approved
          on commit {sha[:8]}. Advancing to qa."
        → Post <!-- pipeline-stage-summary: reviewing --> marker.
        → Exit.
     b. CHANGES_REQUESTED on current HEAD AND submittedAt > last_processed_cr_at:
        → Run multi-persona review with the human's CR comments as
          additional input (read via gh pr view --json reviews,comments).
        → Decide: rejection or wait-marker (see Decision path below).
     c. Current HEAD ≠ last-review-state.sha (new commits):
        → Run multi-persona review on the new code.
        → Decide: rejection or wait-marker.
     d. Otherwise (defensive):
        → Post wait-marker, exit. Log the unexpected state.
```

### 6.2 Decision paths A/B/C rewritten + path D added

Today's lines 854-869 (Decision path A/B/C) are rewritten:

```
A. Premise failure (UNCHANGED).
   - Apply pipeline:premise-failure label.
   - Post the premise_failure marker comment.
   - Post <!-- pipeline-rejection: reviewing -->
        + <!-- pipeline-rejection-target: brainstorming -->
   - Exit.

B. Changes requested (rewritten for β).
   - Post a consolidated COMMENTED-state review with all findings via:
       gh pr review {pr_number} --comment --body "<full summary>"
     Body contains severity-prefixed, path:line-anchored findings.
   - Post Linear add-or-update-comment with sig
     completion/reviewing/{issue_id} (mirrors body).
   - Bump counter: bash .pipeline/bin/guards.sh bump {issue_id} review_rejection.
   - Post <!-- pipeline-rejection: reviewing -->
        + <!-- pipeline-rejection-target: implementing -->
   - Exit.

C. Clean review, awaiting human approval (NEW under β).
   - Post a consolidated COMMENTED-state review via gh pr review --comment
     with summary "Reviewed commit {sha[:8]}. N personas: PASS. 0 critical,
     0 major. Awaiting human Code Owner approval." (Plus minor/nit
     observations as severity-prefixed bullets in the body.)
   - Post Linear summary via add-or-update-comment with sig
     completion/reviewing/{issue_id}.
   - Post <!-- pipeline-wait: awaiting-approval --> with body that
     explicitly names the reviewed SHA.
   - Exit. Issue idles at stage:reviewing.

D. Approval just landed (NEW under β — preflight branch (a) outcome).
   - As described in Preflight step 4(a). Post <!-- pipeline-stage-summary:
     reviewing -->. Exit.
```

### 6.3 Review-comment quality rubric item 1 reworded

Today: `file:line anchor via gh pr review comment mechanism.`

Under β: `file:line anchor as an explicit "path/to/file.ext:LINE" reference at the start of the comment body, after the severity token.`

Items 2-4 (severity token, concrete suggestion, "why" rationale) stay
unchanged.

### 6.4 Output section rewritten

Today's "Output" lines 877-883 mention `gh pr review verdict posted on
the PR (approve / request-changes / neither on premise failure)`.
Replace:

```
Output:
- Per-finding PR review comments via `gh pr review --comment`
  (severity-prefixed, path:line-anchored, with concrete suggestion +
  "why" rationale).
- Consolidated review summary as a Linear add-or-update-comment with sig
  completion/reviewing/{issue_id}.
- Stage-summary file at {stage_summary_path} (per the Stage summary
  comment format contract — abbreviated on path D when no review work
  was done).
- Verdict marker per Decision path (A premise-failure, B
  changes-requested, C wait-for-approval, D approval-detected).
- Do NOT post `gh pr review --approve` or `gh pr review --request-changes`.
  The agent does not approve or request-changes via GitHub's review API;
  humans do.
```

### 6.5 Review allowlist

`bin/dispatch.sh::allowed_tools_for review` keeps `Bash(gh pr review:*)`
(needed for `--comment`). The agent prompt and content tests enforce
that `--approve` and `--request-changes` are never used.

## 7. Test strategy

Each test file is a self-contained `bash bin/X-test.sh` per harness
convention.

### New test files

- **`bin/review-poll-test.sh`** — covers `review_should_dispatch`:
  - Bootstrap (no last-review-state) → truthy.
  - HEAD SHA changed → truthy.
  - New APPROVED on current HEAD, newer than processed → truthy.
  - New CHANGES_REQUESTED on current HEAD, newer than processed → truthy.
  - APPROVED on old SHA → truthy (HEAD differs path).
  - Nothing changed → falsy.
  - APPROVED already processed → falsy.

- **`bin/review-state-test.sh`** — covers `update_review_state` and
  `bootstrap_review_state`:
  - Writes Linear comment with sig `last-review-state/<issue>` and body
    marker `<!-- pipeline-state: last-review-state -->`.
  - Idempotent on subsequent calls (overwrites via add-or-update-comment).
  - `read_review_state` parses correctly.
  - Bootstrap writes initial all-null state.

### Existing tests, extended

- **`bin/agent-prompts-content-test.sh`** — §5 invariants:
  - `§5 contains 'Preflight (MANDATORY'`.
  - `§5 lacks 'gh pr review --approve'`.
  - `§5 lacks 'gh pr review --request-changes'`.
  - `§5 contains 'gh pr review --comment'`.
  - `§5 contains '<!-- pipeline-wait: awaiting-approval -->'`.
- **`bin/dispatch-test.sh`** — prompt↔allowlist contract still passes;
  `gh pr review` in §5 (for `--comment`) is satisfied by the existing
  allowlist token.
- **`bin/poll-slot-test.sh`** — for stage:reviewing issues with
  `review_should_dispatch == false`, poll classifies as idle (no slot
  held, no advance). For `true`, classifies as advanceable.
- **`bin/run-stage-test.sh`** — after a successful review dispatch,
  `update_review_state` is called. On agent crash / non-zero exit,
  `update_review_state` is NOT called.
- **`bin/verdict-handler-test.sh`** — `pipeline-wait: awaiting-approval`
  is correctly ignored by `find_fresh_verdict` (regression).

### Tests intentionally not added

- No live `gh pr view` smoke. Reviews require real PRs + real human
  approvals; unit tests stub `gh`.
- No race-condition simulation. Agent's preflight defends against the
  approval-on-stale-SHA race; we test the preflight, not concurrent races.
- No load test for poll-tick GH API rate. Single-issue throughput today
  is well within limits.

## 8. Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| `gh pr view` API rate limit on busy ticks | Low | Single-issue throughput today; revisit if concurrent reviews become routine. |
| `last-review-state` Linear comment race | Very low | Existing claude-mutex prevents concurrent dispatches per issue. |
| Race: human pushes between poll.sh check and agent run | Low | Agent preflight re-confirms approval on current HEAD before advancing. |
| `gh pr review --comment` blocked by org GitHub policy | Very low | Fallback to `gh pr comment` (already allowlisted). |
| Wait-marker spam from over-eager dispatch | Low | `review-poll-test.sh` Case F asserts the false-return path. |
| Stale `last-review-state` after partial agent failure | Medium | Moot: issue has already moved past stage:reviewing via the marker; stale state doesn't affect correctness. |
| Per-line annotations missing on PR (Option α) | Certain (by choice) | Followup ticket if UX matters. |

## 9. Out of scope

1. **Apply β to build's wait pattern.** Build still dispatches every
   tick when waiting on P2 (human approval) or P5 (CI). The same
   `should_dispatch`-style gating could apply. Followup ticket if/when
   token cost becomes noticeable.
2. **Per-line inline PR annotations.** `gh api`-based payload with
   `comments[]` for native per-file:line review annotations. UX
   nice-to-have. Followup ticket if the consolidated summary becomes
   too noisy.
3. **Bot-identity infrastructure.** β makes the originally-planned
   "two GitHub Apps" line of work entirely unnecessary. That followup
   is closed-without-action; this design supersedes it.
4. **CR-comment ingestion sophistication.** β's preflight branch (b)
   treats human CR comments as plain-text "additional input" for
   re-review. We don't define a structured ingestion format.
5. **Review-rejection escalation budget tuning.** Existing
   `review_rejection` counter and any escalation budget logic carry
   over unchanged. Tuning for β's behavior is a separate ops concern.

## 10. Acceptance criteria

| AC | Verifies | Verification |
|---|---|---|
| AC1 | Review agent never invokes `gh pr review --approve` or `--request-changes` | `bin/agent-prompts-content-test.sh` assertions |
| AC2 | `review_should_dispatch` returns falsy when nothing has changed | `bin/review-poll-test.sh` Case F + Case G |
| AC3 | `update_review_state` writes the canonical Linear comment | `bin/review-state-test.sh` |
| AC4 | `poll.sh` skips dispatch when `review_should_dispatch` is false | `bin/poll-slot-test.sh` |
| AC5 | Verdict-marker protocol unchanged | Existing `bin/verdict-handler-test.sh` + `bin/verdict-adversarial-test.sh` |
| AC6 | End-to-end: bot-authored PR + human approval → orchestrator advances `reviewing → qa` | Manual; first ENG-50-post-merge harness-self ticket |
