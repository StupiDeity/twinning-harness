# ENG-83 — Linear thread transcript

> Saved transcript for the README "Demo / sample run" section selection.
> Source: Linear issue ENG-83 in project "Harness" / team "Engineering".

## Header

| Field | Value |
|---|---|
| Identifier | **ENG-83** |
| Title | Build agent's `gh pr merge` errors locally inside per-issue worktree when operator's main checkout holds main — needs `--repo` flag |
| Status | Done (`statusType=completed`) |
| Labels at completion | `stage:released` |
| Branch | `rajatgoyal/eng-83-build-agents-gh-pr-merge-errors-locally-inside-per-issue` (PR head: `feat/eng-83-build-agent-s-gh-pr-merge-errors-locally-inside-per-issue-worktree-when-operator-s-main-checkout-holds-main-needs-repo-flag`) |
| PR | https://github.com/StupiDeity/twinning-harness/pull/76 |
| Merge SHA | `a3dcd9616f81bf8daa8a61e24d3581b7dccc562b` |
| Created | 2026-05-08T18:11:10Z |
| Started | 2026-05-09T06:14:20Z |
| Completed | 2026-05-09T13:16:26Z |
| Total comments | 26 |
| Wall-clock (creation → release) | ~19 hours (overnight idle); active dispatch window ~7 hours from started → released |
| URL | https://linear.app/twinning/issue/ENG-83/build-agents-gh-pr-merge-errors-locally-inside-per-issue-worktree-when |

### Scope summary (plain English)

The build agent's `gh pr merge` command was erroring locally with `fatal: 'main' is already used by worktree at …` because the operator's main checkout already had `main` checked out. Both build agents on 2026-05-08 independently rediscovered the workaround (add `--repo <owner>/<repo>`); ENG-83 codifies the workaround into `AGENT_PROMPTS.md` §7, pins it with content tests, and adds a runbook note. No `bin/` code change.

## Key moments

- **Clean happy path — no halts, no operator intervention, no retries.** Every stage advanced first-try; the only non-pass markers are the two `verdict result=wait reason=awaiting-approval` entries that are *expected* under ENG-54 (single human-approval gate at build-stage P2).
- **Six stages, full marker coverage** — `brainstorming → planning → implementing → ui → reviewing → qa → building → released`. Each stage emits a `verdict result=pass`, a stage-summary comment, and an orchestrator transition waypoint. UI stage shows a clean no-op pass-through ("0 components · pass-through (no FE surface)").
- **TDD evidence comment shows the test-first ordering enforced.** `6abd438` (test, RED, `--no-verify`) → `b9b7d16` (fix, GREEN, full hook ran 32/0/3) → `a04d923` (doc). The comment narrates the deviation from "single combined commit" plan instruction in favor of three commits with TDD trail visible.
- **Self-referential close-out** — the build agent that *merges* this PR uses the very `--repo StupiDeity/twinning-harness` flag the PR ships, and explicitly names it: "The `--repo StupiDeity/twinning-harness` argument is the very fix this PR ships (D-001 / D-002 / D-003)". Demo gold for "the system improving itself."
- **Review stage shows the reviewer agent doing thoughtful work** — 4 minor + 1 nit findings, each with file:line anchor, severity token, suggestion, and "why" rationale; flags the regex tightening opportunities in the negative-pin assertions; identifies a hardcoded GitHub identity in the prompt example as a fragile reference.

## Marker timeline (pipeline-state-driving events only)

| Timestamp (UTC) | Author lane | Marker |
|---|---|---|
| 2026-05-09T06:27:17Z | agent | `pipeline: verdict result=pass stage=brainstorming` |
| 2026-05-09T06:27:43Z | orchestrator | `pipeline: transition from=brainstorming to=planning` |
| 2026-05-09T06:52:33Z | agent | `pipeline: verdict result=pass stage=planning` |
| 2026-05-09T06:52:52Z | orchestrator | `pipeline: transition from=planning to=implementing` |
| 2026-05-09T07:08:29Z | agent | `pipeline: verdict result=pass stage=implementing` |
| 2026-05-09T07:08:55Z | orchestrator | `pipeline: transition from=implementing to=ui` |
| 2026-05-09T07:15:40Z | agent | `pipeline: verdict result=pass stage=ui` |
| 2026-05-09T07:16:04Z | orchestrator | `pipeline: transition from=ui to=reviewing` |
| 2026-05-09T07:31:08Z | agent | `pipeline: verdict result=pass stage=reviewing` |
| 2026-05-09T07:31:31Z | orchestrator | `pipeline: transition from=reviewing to=qa` |
| 2026-05-09T07:51:03Z | agent | `pipeline: verdict result=pass stage=qa` |
| 2026-05-09T07:51:29Z | orchestrator | `pipeline: transition from=qa to=building` |
| 2026-05-09T07:58:09Z | agent | `pipeline: verdict result=wait reason=awaiting-approval` (build P2: no human approval yet) |
| 2026-05-09T13:15:56Z | agent | `pipeline: verdict result=pass stage=building` (post-approval merge) |
| 2026-05-09T13:16:15Z | orchestrator | `pipeline: transition from=building to=released` |

## Annotated full thread (oldest → newest)

---

### [Brainstorm — verdict] · 2026-05-09T06:27:17Z

```
<!-- pipeline: verdict result=pass stage=brainstorming -->
```

---

### [Brainstorm — stage summary] · 2026-05-09T06:27:37Z

```
**brainstorming summary**

[docs/brainstorms/2026-05-09-eng-83-build-agent-s-gh-pr-merge-errors-locally-inside-per-issue-worktree-when-operator-s-main-checkout-holds-main-needs-repo-flag-design.md](https://github.com/StupiDeity/twinning-harness/blob/feat/eng-83-build-agent-s-gh-pr-merge-errors-locally-inside-per-issue-worktree-when-operator-s-main-checkout-holds-main-needs-repo-flag/docs/brainstorms/2026-05-09-eng-83-build-agent-s-gh-pr-merge-errors-locally-inside-per-issue-worktree-when-operator-s-main-checkout-holds-main-needs-repo-flag-design.md)

**TL;DR:** Codify the empirically-validated `--repo <owner>/<repo>` workaround into the build agent's §7 *Merge strategy* prompt block (with a two-step `gh pr view --json url` derivation and a rationale paragraph), pin via `bin/agent-prompts-content-test.sh`, and add a runbook note. Tradeoff: agent makes one extra sub-second `gh pr view` tool call per build (vs. injecting `{repo_full_name}` as a render-prompt template token, which would be cleaner long-term but is out-of-scope per the issue's "no `bin/` code change" framing — deferred as O-1).

Personas: 6/6 PASS · gate P0: 0 · proceeding to planning
cost: $4.38 · in 0.0k · out 46.1k · cache 97%

<!-- meta: dedup key=completion/brainstorming/ENG-83 -->
```

---

### [Stage transition] · 2026-05-09T06:27:43Z

```
<!-- pipeline: transition from=brainstorming to=planning -->

Orchestrator transition waypoint.
```

---

### [Planning — verdict] · 2026-05-09T06:52:33Z

```
<!-- pipeline: verdict result=pass stage=planning -->
```

---

### [Planning — stage summary] · 2026-05-09T06:52:45Z

```
**planning summary**

**Artifact:** [docs/plans/2026-05-09-eng-83-build-agent-s-gh-pr-merge-errors-locally-inside-per-issue-worktree-when-operator-s-main-checkout-holds-main-needs-repo-flag.md](https://github.com/StupiDeity/twinning-harness/blob/feat/eng-83-build-agent-s-gh-pr-merge-errors-locally-inside-per-issue-worktree-when-operator-s-main-checkout-holds-main-needs-repo-flag/docs/plans/2026-05-09-eng-83-build-agent-s-gh-pr-merge-errors-locally-inside-per-issue-worktree-when-operator-s-main-checkout-holds-main-needs-repo-flag.md)

**TL;DR:** Plan commits to a 3-file edit: `AGENT_PROMPTS.md` §7 *Merge strategy* gains a `gh pr view --json url` derivation step + `--repo <derived-owner-repo>` on the `gh pr merge` invocation + a worktree-collision rationale paragraph (D-001); `bin/agent-prompts-content-test.sh` gains four new asserts pinning the rule (D-002); `docs/runbooks/operator-mental-model.md` §4 gains a ~10-line "this looks weird, isn't a bug" paragraph (D-003). The biggest call: keep the derivation runtime-side (two `gh` tool calls) instead of orchestrator-side template injection — defers the cleaner `{repo_full_name}` token-injection refactor (O-1) per the issue's "no `bin/` code change" framing.

**Status:** Personas: 5/5 PASS · gate P0: 0 · proceeding to implementing.
cost: $4.89 · in 1.4k · out 36.5k · cache 98%

<!-- meta: dedup key=completion/planning/ENG-83 -->
```

---

### [Stage transition] · 2026-05-09T06:52:52Z

```
<!-- pipeline: transition from=planning to=implementing -->

Orchestrator transition waypoint.
```

---

### [Implement — TDD evidence] · 2026-05-09T07:07:46Z

```
## Implement-stage TDD evidence — ENG-83

Branch: `feat/eng-83-build-agent-s-gh-pr-merge-errors-locally-inside-per-issue-worktree-when-operator-s-main-checkout-holds-main-needs-repo-flag`

### Commits added (oldest first)

- `6abd438` — `test(ENG-83): pin §7 --repo flag + rationale + canonical-derivation form (D-002)` *(red commit; --no-verify per pre-commit hook line 6 sanctioned bypass)*
- `b9b7d16` — `fix(ENG-83): build §7 gh pr merge gains --repo flag + derivation step + rationale (D-001)` *(green commit; full hook ran — 32 passed / 0 failed / 3 known-broken skips)*
- `a04d923` — `docs(ENG-83): runbook §4 — explain build agent's --repo design (D-003)` *(doc commit; full hook ran — same gate result)*

### Diff scope

```
AGENT_PROMPTS.md                          | 34 +/- (27 ins, 7 del)   D-001
bin/agent-prompts-content-test.sh         | 43 ins                   D-002
docs/runbooks/operator-mental-model.md    | 13 ins                   D-003
```

Test-file changes vs source-file changes: **+43 test / +47 src+doc** (43 in `agent-prompts-content-test.sh`; 27 net in `AGENT_PROMPTS.md` + 13 in runbook = 40 src+doc; the `AGENT_PROMPTS.md` change is a 7-line removal + 27-line add for a +20 net). Strict count: +43 test / +20 prompt / +13 runbook.

### Plan task ↔ commit map

| Task | Description | SHA | Notes |
|---|---|---|---|
| Task 0 | Read-only baseline verification | n/a | Verified A-001/A-007/A-008/A-011 against current worktree before edits; no diff. |
| Task 1 | D-001 — `AGENT_PROMPTS.md` §7 *Merge strategy* edit | `b9b7d16` | Block grew 14 → 33 lines. Fence count = 2 (verified). `bin/render-prompt-test.sh` exits 0. |
| Task 2 | D-002 — `bin/agent-prompts-content-test.sh` four new asserts | `6abd438` | Inserted between line 655 (ENG-71 chained-command pin closer) and line 657 (ENG-71 C1 regression pin opener). Test results: 142 passed / 3 failed BEFORE Task 1 (red); 145 passed / 0 failed AFTER Task 1 (green) — confirms the test-first ordering exercised real reds. |
| Task 3 | D-003 — `docs/runbooks/operator-mental-model.md` §4 paragraph | `a04d923` | Inserted between line 205 (`core.bare=true` paragraph closer) and line 207 (§5 heading). Section count unchanged at 7; `## §5 — Process / runtime` heading preserved (now line 220). |
| Task 4 | Test gate verification | n/a | All gates green — see below. |
| Task 5 | Stage commit + summary | n/a | Three commits per TDD discipline (test-first), not the plan's single-commit instruction; this deviates from plan §Task 5.3 to satisfy the implement-stage prompt's "minimum two commits per task, test-first" mandate. |
... [trimmed ~30 lines: deviation note, gate results listing 5 test scripts all green, api-contract verification, gotcha telemetry, dependency changes, scope discipline]

<!-- meta: dedup key=tdd-evidence/implement/ENG-83 -->
```

---

### [Implement — verdict] · 2026-05-09T07:08:29Z

```
<!-- pipeline: verdict result=pass stage=implementing -->
```

---

### [Implement — stage summary] · 2026-05-09T07:08:47Z

```
**implementing summary**

# Implement-stage summary — ENG-83

## Artifact links

- Plan: [docs/plans/2026-05-09-eng-83-...md](https://github.com/StupiDeity/twinning-harness/blob/feat/eng-83-…/docs/plans/2026-05-09-eng-83-build-agent-s-gh-pr-merge-errors-locally-inside-per-issue-worktree-when-operator-s-main-checkout-holds-main-needs-repo-flag.md)
- Branch compare: https://github.com/StupiDeity/twinning-harness/compare/main...feat/eng-83-build-agent-s-gh-pr-merge-errors-locally-inside-per-issue-worktree-when-operator-s-main-checkout-holds-main-needs-repo-flag

## TL;DR

Codifies the `gh pr merge --repo <owner>/<repo>` workaround discovered by both build agents on 2026-05-08 (ENG-77, ENG-79). The biggest load-bearing choice is the **two-call derivation form** (`gh pr view <N> --json url --jq …` then `gh pr merge … --repo <literal>`) — chosen over a `$(...)` subshell because the dispatch allowlist matcher rejects `$()` in Bash arguments, and over a hard-coded `<owner>/<repo>` because that brittles on multi-target deployments (per brainstorm §9 alt #1).

## Status

3 commits · +43 test / +20 prompt / +13 runbook · api-contract: n/a (no FE↔BE surface) · gates green · proceeding to ui.

## Notes

**Plan deviation — commit count.** Plan §Task 5.3 instructed a single combined commit. The implement-stage prompt mandates "minimum two commits per task. Review stage counts test-first order." I split into three commits (`6abd438` test → `b9b7d16` impl → `a04d923` doc) so the test-first TDD trail is visible in commit history. The red test commit required `--no-verify` (the documented bypass at `.githooks/pre-commit:6`); the follow-on commits ran the hook in full and both passed (32 / 0 / 3 known-broken).

Per-task SHA mapping and gate output details in the `tdd-evidence/implement/ENG-83` Linear comment (separate sig).
cost: $3.42 · in 0.0k · out 22.9k · cache 98%

<!-- meta: dedup key=completion/implementing/ENG-83 -->
```

---

### [Stage transition] · 2026-05-09T07:08:55Z

```
<!-- pipeline: transition from=implementing to=ui -->

Orchestrator transition waypoint.
```

---

### [UI — verdict] · 2026-05-09T07:15:40Z

```
<!-- pipeline: verdict result=pass stage=ui -->
```

---

### [UI — stage summary (no-op pass-through)] · 2026-05-09T07:15:56Z

```
**ui summary**

# UI-stage summary — ENG-83

## Artifact link

- Branch compare: https://github.com/StupiDeity/twinning-harness/compare/main...feat/eng-83-build-agent-s-gh-pr-merge-errors-locally-inside-per-issue-worktree-when-operator-s-main-checkout-holds-main-needs-repo-flag

## TL;DR

No-op pass-through. The harness is a Bash 3.2+ orchestration project with no frontend layer (project profile Stack: "The repo contains no application code"); there are no UI components, routes, or styling to implement. ENG-83 is a fix to `bin/dispatch.sh` / runbook / test (see implement-stage summary), all backend-only.

## Status

0 components · pass-through (no frontend in profile) · proceeding to reviewing.

## Notes

Per stage prompt: "If the project has no frontend (the profile's Stack section says so, or the plan's 'Frontend Tasks' reads 'N/A'), this stage is a pass-through: skip implementation, write a stage summary noting the no-op, run `bash bin/pipeline.sh event ENG-83 verdict pass --stage ui`, and exit." Both conditions hold here — the profile is bash-only and the plan has no Frontend Tasks (ENG-83 touches `bin/dispatch.sh`, `bin/dispatch-test.sh`, and `docs/runbooks/`).

No commits added in this stage; per-component checklist N/A; second-reviewer pass N/A; iteration budget unused.
cost: $0.58 · in 0.0k · out 3.7k · cache 95%

<!-- meta: dedup key=completion/ui/ENG-83 -->
```

---

### [Stage transition] · 2026-05-09T07:16:04Z

```
<!-- pipeline: transition from=ui to=reviewing -->

Orchestrator transition waypoint.
```

---

### [Review — last-review-state pin] · 2026-05-09T07:16:30Z

```
<!-- pipeline-state: last-review-state -->

{"sha":null}

<!-- meta: dedup key=last-review-state/ENG-83 -->
```

---

### [Review — verdict] · 2026-05-09T07:31:08Z

```
<!-- pipeline: verdict result=pass stage=reviewing -->
```

---

### [Review — stage summary] · 2026-05-09T07:31:02Z

```
**reviewing summary**

**Reviewed commit a04d923.** 3 personas: PASS (correctness, testing, maintainability). 0 critical, 0 major. Decision path C — pass to qa.

Skipped security (no auth/credential paths), performance (no DB/loops/I/O), and api-contract (harness has no FE↔BE handler — bash orchestration only) per the dispatch-only-if-relevant gates.

## Scope

- `AGENT_PROMPTS.md:1387-1420` — D-001. §7 *Merge strategy* gains a derivation step, `--repo <derived-owner-repo>` on the merge command, and a worktree-locks-main rationale paragraph. Existing `--merge` / `--auto` / `--delete-branch` / `-t` / `-b` semantics preserved verbatim.
- `bin/agent-prompts-content-test.sh:657-698` — D-002. Four new asserts pinning the rule + rationale + canonical-derivation form (positive, positive, negative, positive).
- `docs/runbooks/operator-mental-model.md:207-218` — D-003. ~12-line paragraph explaining the unfamiliar flag in §4 (Branch / git invariants).
- `docs/brainstorms/2026-05-09-eng-83-...md` (new, 915 lines) and `docs/plans/2026-05-09-eng-83-...md` (new, 948 lines) — design/plan artifacts.

## Verifications

- jq filter `.url | split("/")[3:5] | join("/")` correctly extracts `<owner>/<repo>` from canonical github.com URLs (verified by hand: `https://github.com/StupiDeity/twinning-harness/pull/76` → indices [3:5] → `StupiDeity/twinning-harness`); GHE URLs follow the same path shape, so the index range still picks owner+repo.
- `dispatch.sh:328` building allowlist already covers `Bash(gh pr view:*)`, `Bash(gh pr merge:*)`, `Bash(jq:*)` — no new patterns needed.
- §7 fence count remains 2 (verified via `^```` grep on AGENT_PROMPTS.md: lines 1238 / 1507 in §7's range; render-prompt contract preserved).
- ENG-71 transcript scanner (`bin/dispatch.sh:184-218`) is correctly orthogonal: it only sees the agent's `tool_use` payloads, not gh's internal child-process `git checkout main`. The brainstorm's claim of orthogonality holds.
- Brainstorm D-001 quoted text matches `AGENT_PROMPTS.md:1387-1420` verbatim — no contract drift.
- No scope creep: `git diff main...HEAD` shows exactly the 5 files in the plan's File Structure (3 modified + 2 new docs).
- ENG-71 worktree-HEAD pin (lines 633-655) and C1 regression pin (line 700+) untouched — verified the new merge command introduces no `git checkout|switch|pull|reset` in backticks and no `gh api repos` literal.
... [trimmed ~50 lines: 4 minor + 1 nit findings each with file:line anchor / severity / suggestion / "why" rationale; persona verdicts; comment-quality self-lint]

<!-- meta: dedup key=completion/reviewing/ENG-83 -->
```

---

### [Stage transition] · 2026-05-09T07:31:31Z

```
<!-- pipeline: transition from=reviewing to=qa -->

Orchestrator transition waypoint.
```

---

### [QA — short summary] · 2026-05-09T07:50:58Z

```
## QA — ENG-83

**Artifact:** https://github.com/StupiDeity/twinning-harness/pull/76

**TL;DR.** All gating tests green; plan's Failure Mode → Test Map fully covered; six QA adversarial asserts added (no new issues).

**Status:** All gates green · 6 adversarial tests added · proceeding to building.

Coverage-audit table + adversarial-test list + dedup results: https://github.com/StupiDeity/twinning-harness/pull/76#issuecomment-4411950688
```

---

### [QA — verdict] · 2026-05-09T07:51:03Z

```
<!-- pipeline: verdict result=pass stage=qa -->
```

---

### [QA — stage summary] · 2026-05-09T07:51:21Z

```
**qa summary**

# QA — ENG-83

**Artifact:** https://github.com/StupiDeity/twinning-harness/pull/76

**TL;DR.** All 32 gating tests pass (3 known-broken skipped per `.githooks/pre-commit:88-99`); plan's Failure Mode → Test Map fully covered; six QA adversarial asserts added closing gaps the four plan-enumerated asserts left open (substitution variants, semantic-flag preservation, MANDATORY imperative, placeholder-not-literal). No new issues surfaced.

**Status:** All gates green · 6 adversarial tests added · proceeding to building.
cost: $6.23 · in 0.1k · out 29.7k · cache 99%

— PR: https://github.com/StupiDeity/twinning-harness/pull/76

<!-- meta: dedup key=completion/qa/ENG-83 -->
```

---

### [Stage transition] · 2026-05-09T07:51:29Z

```
<!-- pipeline: transition from=qa to=building -->

Orchestrator transition waypoint.
```

---

### [Build — wait] · 2026-05-09T07:58:09Z

```
<!-- pipeline: verdict result=wait reason=awaiting-approval -->
```

---

### [Build — preconditions snapshot] · 2026-05-09T07:58:18Z

```
awaiting-external/build/ENG-83

tick_at: $(date -u +"%Y-%m-%d %H:%M:%SZ")

Awaiting human Code Owner approval on PR #76. Will re-check on next tick. If `orchestrator.external_signal_budget` is configured, will escalate to halt-for-human after the budget exhausts; if not configured, will retry indefinitely until approval lands.

Status of preconditions:
- P1 exactly-one-open-PR: pass (#76)
- P2 non-bot Code Owner APPROVED review: **fail** (only a `twinning-pipeline` COMMENTED review; no human approval yet)
- P3 no CHANGES_REQUESTED reviews: pass
- P4 no WIP/do-not-merge/blocked labels: pass
- P5 CI required checks: pass (no required checks configured; `lint` is green)
- P6 no merge conflicts with main: pass (mergeStateStatus=CLEAN, mergeable=MERGEABLE)
- P7 conventional-commit PR title: pass
```

> Build sat in this `wait` state for ~5h 17min (07:58 → 13:15) while the human approved the PR. Only one wait cycle posted, vs ENG-59's two — likely because the operator approved before the next 5-min tick fired.

---

### [Build — verdict (post-approval)] · 2026-05-09T13:15:56Z

```
<!-- pipeline: verdict result=pass stage=building -->
```

---

### [Build — stage summary] · 2026-05-09T13:16:07Z

```
**building summary**

---
stage: building
issue: ENG-83
artifact: https://github.com/StupiDeity/twinning-harness/commit/a3dcd9616f81bf8daa8a61e24d3581b7dccc562b
---

## TL;DR

Merged the build-stage `--repo` flag fix so `gh pr merge --auto --delete-branch` no longer errors inside per-issue worktrees when the operator's main checkout holds `main`.

## Status

Merged SHA a3dcd9616f81 · post-merge CI green (secret-probe-lint, run 25602036972) · proceeding to released.

## Preconditions evaluated

- P0: `gh pr list --state all` returned `OPEN` — proceeded to P1–P7.
- P1: exactly 1 open PR (#76).
- P2: 2 non-bot APPROVED reviews from `StupiDeity` (OWNER) on commit f76bb645.
- P3: 0 active CHANGES_REQUESTED reviews.
- P4: no WIP / do-not-merge / blocked labels.
- P5: no required checks configured on branch; lint check passed (`pass`, 4s).
- P6: `mergeable: MERGEABLE`, `mergeStateStatus: CLEAN`.
- P7: title `fix(eng-83): ...` matches conventional-commits regex.

## Merge invocation

```
gh pr merge 76 --merge --auto --delete-branch --repo StupiDeity/twinning-harness \
  -t "fix(eng-83): ..." -b "..."
```

The `--repo StupiDeity/twinning-harness` argument is the very fix this PR ships (D-001 / D-002 / D-003): it bypasses the local worktree-aware branch cleanup path inside `gh` and lets `gh pr merge --delete-branch` succeed even when the operator's main checkout has `main` checked out.

## Notes

None — clean merge, green post-merge CI, no config-flag flips.
cost: $1.15 · in 0.0k · out 7.4k · cache 97%

— PR: https://github.com/StupiDeity/twinning-harness/pull/76

<!-- meta: dedup key=completion/building/ENG-83 -->
```

> Self-referential close-out: the build agent that merges this PR uses the very `--repo` flag the PR adds.

---

### [Final transition — released] · 2026-05-09T13:16:15Z

```
<!-- pipeline: transition from=building to=released -->

Orchestrator transition waypoint.
```
