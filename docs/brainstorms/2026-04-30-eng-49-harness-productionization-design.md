---
linear: ENG-49
title: Harness productionization — generalize for any target stack (8 gaps)
date: 2026-04-30
status: draft
---

# Harness productionization — generalize for any target stack

## 1. Context

Driving ENG-45 to `Done` on 2026-04-29 surfaced five compounding gaps in the
harness; the subsequent ENG-46 retrospective surfaced three more. All eight
share a single root: the harness's prompts, allowlists, idempotency
assumptions, and post-release flow were originally written for the Tauri
target and only partially generalized when the harness was extended to drive
itself. Each gap individually halts the pipeline; together they make any
target whose shape diverges from Tauri (backend-only, frontend-only,
harness-self) operator-driven.

The reframe that drives this design: **the harness must be generic enough
to drive any target stack.** Fixing for harness-self specifically would just
shift the same trap onto the next non-Tauri target. The fixes here remove
target-shape assumptions and centralize orchestration responsibilities so
every target gets correct behavior without per-target prompt branching.

## 2. Goals

- Any target ticket goes Todo → Done with at most:
  - one PR approval review,
  - one optional `halt.sh resolve --decision resume` on a deliberate halt.
- No manual marker posts.
- No Linear-state pushes by the operator.
- No `gh pr create` from the operator's account.
- No admin merges to bypass self-approval.

## 3. Architectural principle

**Side effects of stage transitions belong to the orchestrator
(`verdict-handler::apply_transition`), not to GitHub workflows or stage
agents.**

`apply_transition` already owns:

- Stage label swap (`stage:from → stage:to`).
- `pipeline:halted` removal post-transition.
- Linear native-state hook for `to == reviewing → In Review`.

This work extends the same primitive with two new responsibilities:

- Linear native-state hook for `to == released → Done` (Gap #4).
- PR creation hook for `to == reviewing` (Gap #1).

Stage agents (implement, UI) stop owning PR creation entirely. Their prompts
and allowlists shrink. The orchestrator becomes the single canonical PR-opener
for every target.

## 4. The eight gaps and their fixes

Gaps #1-#5 came from the issue description. Gaps #6, #7, #8 came from the
ENG-46 retrospective comment. Gap #8 is intentionally not fixed here — see §10.

### Gap #1 — UI pass-through doesn't open the PR

**Symptom:** For backend-only stacks, the UI agent enters its pass-through
clause, posts a verdict marker, and exits without opening a PR. The operator
opens it manually → PR author = operator → GitHub blocks self-approval → P2
permanently unreachable.

**Fix:** Move PR creation out of stage agents and into the orchestrator.

Files touched:

- `bin/verdict-handler.sh::apply_transition` — add a new conditional
  block, *after* the existing native-state hook block (which now handles
  both `to == reviewing` and `to == released` per Gap #4) and *before*
  `side_labels` processing. The new block fires when `to == reviewing`:
  run `gh pr list --head $branch --state open --json number --jq 'length'`,
  and if 0, run `gh pr create --title <T> --body <B>` where body is
  returned by the new `render_pr_body` helper. Title format:
  `<type>(<issue_id>): <linear issue title>` — `<type>` derived from the
  Linear issue label (`Bug → fix`, `Feature → feat`, default → `fix`);
  `<linear issue title>` taken verbatim from the issue's title field.
  Idempotent on repeat (existing PR → skip). Resilient: any failure logs
  and proceeds (`|| true`); the next tick's
  `resume_in_progress_transition` re-enters and `gh pr list` correctly
  skips re-creation.
- `bin/render-pr-body.sh` — **new file**, source-able with sentinel.
  Implemented in pure bash with `jq` / `grep` / `awk` (no external
  markdown parser). Defines `render_pr_body <issue> <branch>` returning
  the canonical body markdown. Reads:
  - Brainstorm doc (path resolved via reconcile-style frontmatter scan)
    → `## Overview` section bullets for the **Summary** section.
  - Linear stage-summary comments (`completion/<stage>/<issue>` sigs) for
    implement and UI → TL;DR + Notes for **Changes**.
  - Plan doc (path resolved similarly) → Failure Mode → Test Map row
    names + profile gates for **Test plan**.
  - "Screenshots: N/A — added by review if user-visible changes" placeholder.
  Graceful fallbacks for every input: missing brainstorm Overview falls
  back to Linear issue title; missing UI summary becomes
  "Frontend: pass-through (no-op)"; missing Test Map becomes a generic
  gates-only checklist.
- `AGENT_PROMPTS.md §3 (Implementation Agent)` — line 511 currently reads
  *"Do NOT create a PR. The UI agent opens the combined backend+frontend
  PR (or, on backend-only stacks, the review agent does — per the
  profile)."* Updated to *"Do NOT create a PR. The orchestrator opens the
  PR on transition to `reviewing` as a side-effect of `apply_transition`."*
- `AGENT_PROMPTS.md §4 (UI Agent)` — delete the entire "PR creation
  (at exit — UI stage owns PR creation for this branch)" section
  (lines 683-720). Replace with a single line: *"Do NOT create or edit
  the PR. The orchestrator opens it on transition to `reviewing`."* The
  existing pass-through clause (line 589) stays untouched — *"skip
  implementation, write a stage summary noting the no-op, post
  `<!-- pipeline-stage-summary: ui -->`, and exit"* is now correct without
  further edits.
- `bin/dispatch.sh::allowed_tools_for` — remove
  `Bash(gh pr create:*),Bash(gh pr view:*),Bash(gh pr edit:*)` from the
  `ui` case. Implement allowlist unchanged.

### Gap #2 — `halt.sh resolve` races verdict-handler

**Symptom:** `halt.sh resolve --decision resume` removes `pipeline:halted`
unconditionally — even when there's a fresh forward verdict marker that
verdict-handler would otherwise act on. `poll.sh:404` only invokes
verdict-handler when `pipeline:halted` is present, so the natural operator
workflow (post forward marker, then resolve) deadlocks: the resolve clears
the halt before verdict-handler can transition, and the next tick
re-dispatches the same stage instead of advancing.

**Fix:** `halt.sh::resolve` calls `verdict_handler` *before* clearing the
halt label. Three return-code paths:

- **rc=0** (transitioned): `apply_transition` step 5 already removed the
  halt label. `halt.sh` skips its own `remove-label` call.
- **rc=1** (halt-marker is the freshest verdict): proceed with current
  behavior — post `<!-- pipeline-decision: resume -->`, remove halt label.
- **rc=2** (protocol violation: `verdict_handler` re-applied
  `pipeline:halted` and posted a violation comment): `halt.sh` exits
  non-zero with a clear stderr message naming the violation and pointing
  to the Linear comment sig (e.g.
  `protocol-violation/<case_id>/<issue>`); the halt label is *not*
  removed by halt.sh. The operator must address the violation and
  re-run.

`--decision scope-approved` and `--decision scope-rejected` paths are
unchanged (no verdict-handler involvement; their semantics are operator
approval / rejection of an out-of-scope edit, not a forward advance).

Files touched:

- `bin/halt.sh::resolve` — source `verdict-handler.sh`, branch on
  `--decision`, integrate the rc handling. `current_stage` read via
  `bash linear.sh stage-of "$issue"`.

### Gap #3 — `<!--` history-expansion footgun

**Symptom:** Bash interactive shells run history expansion (`histexpand`,
on by default) and consume `!` from `<!-- pipeline-... -->`, mangling
operator-pasted marker bodies in double-quoted strings (e.g.
`<!-- pipeline-stage-summary: building -->` becomes `< pipeline-stage-summary:
building -->`). Verdict-handler's regex doesn't match the mangled body.

**Fix:** New helper `bin/post-verdict.sh` that constructs the marker via
heredoc (immune to history expansion) and validates the constructed body
against `find_fresh_verdict`'s grep regex before posting.

Files touched:

- `bin/post-verdict.sh` — **new file**. Usage:
  `post-verdict.sh <issue> <kind> <stage> [<reason>]` where
  `kind ∈ {stage-summary, rejection, halt}` and stage is one of
  `brainstorming|planning|implementing|ui|reviewing|qa|building|released`.
  Validates inputs, constructs marker via heredoc, asserts the body
  matches the verdict-handler regex, posts via `bash linear.sh
  add-comment`. `PIPELINE_WRITER=human` set inline.
  Sentinel-guarded for testability.
- `bin/post-verdict-test.sh` — new self-contained test.
- `CLAUDE.md` — single sentence under "Common commands" pointing to
  the helper as the safe way to post a verdict marker.

### Gap #4 — No `released → Done` transition

**Symptom:** `verdict-handler` advances the label `stage:building →
stage:released`, but the Linear *state* stays at `In Progress` because
the harness has no GitHub release workflow. The Tauri target's
`pipeline-release.yml` did this state swap; harness has no such file.

**Fix (mechanism changed from issue's original AC):** Extend
`apply_transition`'s native-state hook with a symmetric `to == released`
branch, mirroring the existing `to == reviewing → In Review`. No GitHub
workflow file is added to the harness.

Files touched:

- `bin/verdict-handler.sh::apply_transition` — extend the existing
  conditional that handles native-state hooks:

  ```bash
  if [[ "$to" == "reviewing" ]]; then
    ...transition to In Review...
  elif [[ "$to" == "released" ]]; then
    local done_state
    done_state="$(config_get '.linear.native_states.done')"
    if [[ -n "$done_state" && "$done_state" != "null" ]]; then
      bash "$_VH_SCRIPT_DIR/linear.sh" transition-state "$issue" "$done_state" || true
    else
      log "verdict-handler: skipping native-state hook to Done (config.linear.native_states.done not set)"
    fi
  fi
  ```

- `AGENT_PROMPTS.md §8 (Release Agent)` — update lines 1303-1305 wording
  from *"the `pipeline-release.yml` sweep already swapped
  `stage:building → stage:released` + status → Done"* to *"the
  orchestrator (`verdict-handler::apply_transition`) advances
  `stage:building → stage:released` and Linear native status → Done as
  transition side-effects."* Behavior of §8 unchanged: it remains an
  observer agent invoked by release tooling when present.

### Gap #5 — `FATAL: state not in cache: null`

**Symptom:** During the `ui → reviewing` transition,
`apply_transition`'s native-state hook calls
`bash linear.sh transition-state $issue $in_review_state`. If
`config.linear.native_states.in_review` is missing, `config_get` returns
the literal string `null`. `linear.sh:316` then dies with `state not in
cache: null`. The `|| true` in apply_transition swallows the exit code,
but the FATAL log fires.

**Fix:** Two-pronged.

1. **Defensive guard (symptom).** Inside both native-state hooks
   (`to == reviewing` and `to == released`), only call
   `transition-state` if the resolved state name is non-empty and not
   the literal "null". Otherwise emit a single `log` (not `die`) noting
   the missing config key.
2. **Root cause.** `bin/setup.sh` requires
   `config.linear.native_states.{in_review, done}` and dies loudly if
   either is missing post-setup. `bin/linear.sh refresh-cache`
   double-checks that both names resolve to non-null UUIDs.

Breaking change for harness installations that haven't re-run setup.
Single-machine blast radius today; setup is a one-line re-run.

Files touched:

- `bin/verdict-handler.sh::apply_transition` — defensive guards.
- `bin/setup.sh` — config-bootstrap requires `done` state name.
- `bin/linear.sh refresh-cache` — verify both native_states resolve.

### Gap #6 — `state.local.json::orchestrator.paused` override is a no-op

**Symptom:** CLAUDE.md documents `STATE_FILE` as the runtime override
for `orchestrator.paused`, with writes going to `state.local.json` so
target repos don't commit transient state. But `bin/poll.sh:351` and
`bin/run-local.sh:91` read directly from `$CONFIG` via `config_get`,
bypassing the `is_orchestrator_paused` helper that respects
`STATE_FILE`. Setting `paused=false` in `state.local.json` is silently
ignored when `config.json` has `paused=true`.

**Fix:** Replace both call sites with `is_orchestrator_paused`.

Files touched:

- `bin/poll.sh` line 351 — `paused="$(is_orchestrator_paused)"`.
- `bin/run-local.sh` line 91 — same.
- `bin/run-local-helpers-adversarial-test.sh` — regression case
  asserting the override is honored in both paths.

### Gap #7 — Allowlist vs prompt drift

**Symptom:** UI prompt §4 line 686 instructs the agent to run `gh pr
list`, but the UI allowlist in `dispatch.sh::allowed_tools_for ui` does
not include `Bash(gh pr list:*)`. The denial leaks into the agent's
heuristic ("the sandbox approval-gates everything"), causing it to
refuse other allowed Linear writes too. Operator-rescue post required.

Under our 1b architecture (Gap #1 fix), UI no longer needs *any*
`gh pr*` tools — the orchestrator owns PR creation. So the fix shape
shifts from "add `gh pr list` to UI" to "remove `gh pr create/view/edit`
from UI, and add a contract test that catches future drift."

**Fix:**

- `bin/dispatch.sh::allowed_tools_for` — remove `gh pr create/view/edit`
  from `ui`. Add `Bash(gh pr list:*)` to `qa` (parity with review/build,
  which already have it).
- `bin/dispatch-test.sh` — extend Group 1 with the new contract:
  *"For each stage S, every `gh pr <verb>` token appearing in
  `AGENT_PROMPTS.md §S` must be allowlisted in
  `allowed_tools_for(S)`."* Implemented by parsing the fenced block per
  stage, extracting `gh pr <verb>` tokens via a shell-shaped regex, and
  asserting allowlist coverage.

### Gap #8 — Bot self-review

**Explicit non-fix.** GitHub blocks `gh pr review` when reviewer ==
author. Under our design (and under any of the four design options
discussed in brainstorm), PR creation and review use the same single
GitHub App installation token — so review is always self-review, always
blocked. The actual fix requires a second bot identity (separate App
installation, or installation token routing per stage), which is an
infrastructure change orthogonal to ENG-49's scope.

**Action:** Leave a code comment in `bin/verdict-handler.sh` near the
new PR-creation hook flagging the trap. File a separate Linear ticket
post-merge, blocked-on ENG-49 to avoid double-shipping.

## 5. Test strategy

Each test file is a self-contained `bash bin/X-test.sh` per the harness
convention. No new test runner.

### Existing tests, extended

- **`bin/verdict-handler-test.sh`** — `to == released` triggers Linear
  state transition (stubbed `linear.sh`); `to == reviewing` triggers PR
  creation when stubbed `gh pr list` returns 0; `to == reviewing` skips
  PR creation when stubbed `gh pr list` returns ≥1; defensive guard
  logs (not dies) for empty/null state names.
- **`bin/dispatch-test.sh`** — Group 1 enforces the new
  prompt↔allowlist contract; UI no longer has `gh pr create`; QA has
  `gh pr list`.
- **`bin/run-local-helpers-adversarial-test.sh`** — Gap #6 regression:
  `state.local.json::orchestrator.paused=false` overrides
  `config.json::orchestrator.paused=true` in both poll and tick paths.

### New tests

- **`bin/render-pr-body-test.sh`** — full-stack, backend-only,
  missing-Overview, dry-run cases.
- **`bin/post-verdict-test.sh`** — valid (kind, stage) builds correct
  marker; invalid kind/stage dies; heredoc construction prevents `<`
  mangling; dry-run mode prints body.
- **`bin/halt-test.sh`** — covers Gap #2 rc=0/1/2 paths; verifies
  `--decision scope-*` paths unchanged.
- **`bin/agent-prompts-content-test.sh`** — asserts §3 contains *"Do
  NOT create a PR"*, §3 lacks `gh pr create`, §4 lacks `gh pr create`
  and lacks the *"PR creation"* heading, §4 pass-through clause is
  preserved verbatim, §8 lacks the obsolete *"`pipeline-release.yml`
  sweep already swapped"* phrase.

### Tests intentionally not added

- No live GitHub or live Linear integration tests; the verdict-handler
  unit tests stub both. The first harness-self ticket post-merge is the
  live smoke (AC8).
- No setup integration suite for the new `done` config key beyond a
  single assertion in `bin/setup-test.sh`.

### Coverage map

| Gap | Test file(s) |
|---|---|
| #1 | `verdict-handler-test.sh` + `render-pr-body-test.sh` + `agent-prompts-content-test.sh` + `dispatch-test.sh` |
| #2 | `halt-test.sh` |
| #3 | `post-verdict-test.sh` |
| #4 | `verdict-handler-test.sh` + `agent-prompts-content-test.sh` |
| #5 | `verdict-handler-test.sh` (defensive case) + `setup-test.sh` (config requirement) |
| #6 | `run-local-helpers-adversarial-test.sh` |
| #7 | `dispatch-test.sh` |
| #8 | None — explicit non-fix, doc-only |

## 6. PR shape and commit ordering

Single PR, multi-commit, branch `eng-49-harness-productionization`. PR
title: `fix(ENG-49): generalize harness for any target stack (8 gaps)`.

Commit ordering with dependencies:

| # | Commit | Files | Depends on |
|---|---|---|---|
| 1 | `fix(ENG-49): respect state.local.json paused override in poll and tick` | `bin/poll.sh`, `bin/run-local.sh`, `bin/run-local-helpers-adversarial-test.sh` | — |
| 2 | `fix(ENG-49): defensive guard for native-state hook in apply_transition` | `bin/verdict-handler.sh`, `bin/setup.sh`, `bin/verdict-handler-test.sh` | — |
| 3 | `feat(ENG-49): native-state hook for released → Done` | `bin/verdict-handler.sh`, `AGENT_PROMPTS.md §8`, `bin/verdict-handler-test.sh`, `bin/agent-prompts-content-test.sh` | #2 |
| 4 | `feat(ENG-49): render-pr-body helper for orchestrator-assembled PR bodies` | `bin/render-pr-body.sh`, `bin/render-pr-body-test.sh` | — |
| 5 | `feat(ENG-49): orchestrator opens PR on transition to reviewing` | `bin/verdict-handler.sh`, `AGENT_PROMPTS.md §3 + §4`, `bin/dispatch.sh`, `bin/verdict-handler-test.sh`, `bin/agent-prompts-content-test.sh`, `bin/dispatch-test.sh` | #4 |
| 6 | `fix(ENG-49): align stage allowlists with prompt instructions` | `bin/dispatch.sh`, `bin/dispatch-test.sh` | #5 |
| 7 | `fix(ENG-49): halt.sh resolve invokes verdict-handler before clearing halt` | `bin/halt.sh`, `bin/halt-test.sh` | — |
| 8 | `feat(ENG-49): bin/post-verdict.sh helper for safe marker posting` | `bin/post-verdict.sh`, `bin/post-verdict-test.sh`, `CLAUDE.md` | — |

**TDD discipline.** Per gap, write the test first, run red, write
implementation, run green, then commit. Test + impl land in the same
commit; the typed prefix (`fix` vs `feat`) signals intent.

**Pre-merge full-suite test run.** Before opening the PR, run every
`*-test.sh` from a clean checkout to catch suite-wide regressions.

## 7. Acceptance criteria

| AC | Verifies | Mechanism | Verification |
|---|---|---|---|
| AC1 (Gap #1) | Orchestrator opens PR on `ui → reviewing` | `apply_transition` runs `gh pr list`, then `gh pr create` (with body from `render_pr_body`) if 0; PR author = bot identity; idempotent | `verdict-handler-test.sh` (stubbed gh) + AC8 live |
| AC2 (Gap #2) | `halt.sh resolve --decision resume` honors fresh forward verdict | rc=0 → halt removed by apply_transition; rc=1 → halt.sh removes; rc=2 → halt.sh exits non-zero, halt preserved | `halt-test.sh` |
| AC3 (Gap #3) | Safe operator marker posting | `post-verdict.sh` heredoc + regex validation | `post-verdict-test.sh` |
| AC4 (Gap #4) | `stage:released → Linear status Done` | `apply_transition` `to == released` branch; **no `pipeline-release.yml` added** | `verdict-handler-test.sh` + AC8 live |
| AC5 (Gap #5) | `FATAL: state not in cache: null` is gone | Defensive guard in `apply_transition`; `setup.sh` requires `done` state | `verdict-handler-test.sh` + `setup-test.sh` + post-merge log inspection |
| AC6 (Gap #6) | `state.local.json::orchestrator.paused` override honored | `is_orchestrator_paused` in `poll.sh` + `run-local.sh` | `run-local-helpers-adversarial-test.sh` |
| AC7 (Gap #7) | Allowlist matches prompt per stage | dispatch-test contract; UI drops `gh pr create/view/edit`; QA gains `gh pr list` | `dispatch-test.sh` |
| AC8 (end-to-end) | First harness-self ticket post-merge goes Todo → Done with ≤1 manual halt-resolve | Live observation; PR opened by bot; no manual marker posts beyond `post-verdict.sh` if needed | Manual; capture timing for retrospective |

**Material changes vs the issue's original ACs:**

- AC4 mechanism: orchestrator hook, not workflow file.
- AC1 verification split into unit + AC8 live (UI no longer creates PRs
  under 1b, so there's nothing to verify in UI).
- AC6 and AC7 added (originally only in the comment).
- AC8 retargets the next harness-self ticket post-merge (ENG-46 is
  already Done).

## 8. Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| `gh pr create` inside `apply_transition` fails mid-transition | Medium | Idempotent re-entry via `resume_in_progress_transition`; `gh pr list` skips re-creation on next tick. |
| `render_pr_body` parser brittle to stage-summary or brainstorm Overview drift | Low | `agent-prompts-content-test.sh` asserts the contract; graceful fallbacks ensure body is always producible. |
| `dispatch-test` allowlist contract regex hits false positives on `gh pr X` in code examples | Low | Scope regex to command-shell-shaped instances; dry-run parser before commit. |
| `halt.sh::resolve` sourcing verdict-handler introduces import side-effects | Very low | verdict-handler is sentinel-guarded; only function definitions at top level. |
| `setup.sh` new required `done` config key breaks existing installs | Low blast radius (single machine) | One-line setup re-run; loud error names the missing key. |
| Gap #8 unfixed (bot self-review) | Certain — by design | Followup ticket filed, blocked-on ENG-49. |
| Tauri's `pipeline-release.yml` workflow + verdict-handler hook duplicate state swap | None | Both setting Done is idempotent; cleanup on Tauri side is optional. |

## 9. Out of scope

Intentionally not addressed in ENG-49:

1. **Gap #8 — separate bot identity for review.** Followup ticket.
2. **Sweep for other Tauri target assumptions in the harness.**
   Followup ticket.
3. **Generic release-tooling flow for the harness.** Whether/when the
   harness adopts semantic-release or another versioning mechanism is
   a separate product decision.
4. **`pipeline:abandoned` / `pipeline:supersede` flows.** Per the
   issue's OUT section.
5. **Commit authorship in dispatched agents.** Per the issue's OUT
   section.
6. **`pipeline:skip-until-human-acts` not auto-clearing on
   `pipeline_content_hash` change.** Doc-only fix; deferred.
7. **Review prompt writes to `$TMPDIR` not worktree.** Deferred.

## 10. Followup tickets to file post-merge

Two new Linear issues under project `harness`, both blocked-on ENG-49:

1. *Separate bot identities for PR-creator vs reviewer* (Gap #8).
2. *Audit harness for remaining Tauri-target assumptions
   (post-ENG-49 sweep).*
