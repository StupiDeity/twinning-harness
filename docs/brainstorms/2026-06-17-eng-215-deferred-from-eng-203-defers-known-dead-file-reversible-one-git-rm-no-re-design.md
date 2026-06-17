---
linear: ENG-215
title: Delete the dead scratch file bin/probe-test.sh (one git rm)
date: 2026-06-17
status: draft
follow_up_source: ENG-203-d0012
finding_class_key: maintainability:probe-test.sh:dead-scratch-file
---

# Delete the dead scratch file `bin/probe-test.sh` (one `git rm`)

## 1. Overview

Carryover from ENG-203 review iteration 2. During an ENG-203 implementing
re-dispatch the agent dropped a scratch file at `bin/probe-test.sh` —
the file's own header explains its origin in two comment lines and the
body is `exit 0`:

```bash
#!/usr/bin/env bash
# probe-test.sh — accidental scratch file from ENG-203 review-loopback dispatch.
# Should be deleted by next clean run; sandbox prevented rm during dispatch.
exit 0
```

(`bin/probe-test.sh:1-4`, present on `main` since commit `df32051`.)

It is referenced nowhere — `Grep "probe-test"` across the worktree
returns exactly one hit, the file itself. The reviewing agent
classified the finding `maintainability:probe-test.sh:dead-scratch-file`
and deferred it under the ENG-191 selective-exit rubric:

> defers: known-dead file — reversible (one git rm), no regression,
> no user-visible surface (no-op exit 0), has workaround (file is
> silently inert)

This ticket lands that one-line cleanup.

### 1.1 Live cost the file imposes today

The file is **silent**, not free. Two pipeline surfaces pick it up
because its basename matches `bin/*-test.sh`:

1. **Pre-commit hook.** `.githooks/pre-commit:162` globs `bin/*-test.sh`
   and runs each as a self-contained executable. `probe-test.sh` runs
   and passes (rc=0), printing one `PASS bin/probe-test.sh` line per
   commit. Cost: ~milliseconds + one row of noise.
2. **`dispatch.sh::_dispatch_tools_autotests`.** `bin/dispatch.sh:472`
   globs the same pattern and emits one literal
   `Bash(bash bin/probe-test.sh:*)` allowlist entry per implementing
   or qa dispatch. Cost: one wasted allowlist token per dispatch,
   forever.

Neither cost is load-bearing, but both are real and both compound per
commit / per dispatch. The finding is correctly defer-eligible (no
regression, reversible) and equally correctly worth landing once the
critical-path ENG-203 PR is merged — which it now is (PR #175, merged
2026-06-17 in commit `ede2380`).

### 1.2 Why this can land standalone

The change is **one `git rm` + a one-line commit message**. It touches
exactly one file. There is no test to write, no helper to refactor, no
prompt to edit, no ADR to amend, and no follow-up cleanup. The dead
file is genuinely dead in every sense the harness can detect: zero
imports, zero source-of-truth references, zero pipeline-internal
documentation. The deferred status was correct; this brainstorm is
proportionally one decision.

## 2. Decisions

### D-001. Delete `bin/probe-test.sh` from the harness via `git rm` in an implementing dispatch.

**What changes.** Exactly one file removal:

```
git rm bin/probe-test.sh
git commit -m "fix(ENG-215): drop accidental scratch bin/probe-test.sh from ENG-203"
```

No other edits. No allowlist changes. No new tests. No KNOWN_BROKEN
entries. No documentation updates beyond this brainstorm.

**Rationale.**

- **Project rule (CLAUDE.md "Doing tasks"):** *"Don't add features,
  refactor, or introduce abstractions beyond what the task requires…
  No half-finished implementations either."* The file is a literal
  half-finished implementation (a test-named no-op with a TODO-style
  comment expecting a future cleanup); removing it discharges that
  rule on the exact code path the rule names.
- **Project rule (CLAUDE.md "Don'ts" in project profile):** *"Never
  write outside the per-stage allowlist in `run-local-helpers.sh::
  partition_dirty_paths` — the breaker classifies new untracked paths
  as self-leak and trips the consecutive-failures counter."*
  `probe-test.sh` is the residue of a sandbox-failed `rm` from
  precisely that class of incident (the file's own header documents
  it: *"sandbox prevented rm during dispatch"*). Leaving the residue
  on disk normalises the incident; removing it closes it out.
- **ENG-191 selective-exit rubric** (`docs/runbooks/recovery.md` §13
  — verified to exist via `Read docs/runbooks/recovery.md` excerpt
  hit): the reviewing agent applied the rubric correctly to defer the
  finding, but every dimension of the rubric (`in_changed_code=yes`,
  `is_regression=no`, `user_visible=no`, `reversible=yes`,
  `has_workaround=yes`) also describes a finding that should land,
  just not at the same moment as the source-of-truth PR. Now that PR
  #175 is merged, the landing window is open.
- **In-scope path.** `bin/` is the first bullet of the project
  profile's `## File layout`
  (`learned-rules/harness/project-profile.md:51`). Any write to
  `bin/*` in implementing is bucketed in-scope by
  `partition_dirty_paths::D-004` (per project profile `## Don'ts`
  and the dispatch preamble's basename-token rule). No scope risk.
- **Allowlist coverage.** The implementing stage's base allowlist
  in `bin/dispatch.sh::allowed_tools_for` (verified at
  `bin/dispatch.sh:651`) includes `Bash(git rm:*)` and
  `Bash(git commit:*)`. No allowlist edit required.

**Rejected alternatives.**

- **A. Rename to `bin/probe-noop.sh` (drop the `-test.sh` suffix) instead of deleting.**
  Rejected. The file does nothing; renaming it preserves an
  unreferenced executable while losing the only signal that flagged
  it as a problem (the misleading `*-test.sh` suffix that lights up
  both pipeline globs). Renaming is more churn than deletion and
  leaves the dead file in tree.
- **B. Turn it into a real test for something probe-related.**
  Rejected. The file has no semantic anchor — `probe` was not a name
  the ENG-203 agent intentionally picked, it's residue. Inventing a
  test to fit the filename is exactly the "design for hypothetical
  future requirements" antipattern CLAUDE.md "Doing tasks" prohibits.
- **C. Add it to `.githooks/pre-commit::KNOWN_BROKEN`.**
  Rejected. `KNOWN_BROKEN` (`.githooks/pre-commit:88-107`) is the
  "skip a genuinely-broken test pending a fix-ticket" escape hatch,
  not a no-op-suppression list. Adding `probe-test.sh` would defeat
  the hook's own self-protection ("New: leaving stale skips here is
  the failure mode this list itself is designed to prevent."
  `.githooks/pre-commit:86-87`). The right tool to remove a non-test
  is `git rm`, not the broken-test allowlist.
- **D. Edit `.githooks/pre-commit` / `bin/dispatch.sh` to skip
  zero-byte or comment-only test files generically.**
  Rejected. That is a generalisation in search of a problem — one
  file is one file. The generic version would introduce a new policy
  surface (what counts as "trivially empty"?) that future agents
  could rely on to drop more scratch. Per CLAUDE.md "Doing tasks"
  (*"Three similar lines is better than a premature abstraction"*),
  the right action at N=1 is the one-line delete.

## 3. Architecture

There is no architecture to design. The deletion affects exactly two
implicit consumers — both globbing-based, both stateless:

| Site | Pre-deletion behavior | Post-deletion behavior |
|---|---|---|
| `.githooks/pre-commit:162` glob over `bin/*-test.sh` | Iterates one extra file; runs `bash bin/probe-test.sh`; rc=0; prints `PASS bin/probe-test.sh`; total count reads "N tests" | Iterates one fewer file; prints no row for it; total count reads "N-1 tests" |
| `bin/dispatch.sh::_dispatch_tools_autotests` (line 472, glob over `bin/*-test.sh`) on implementing|qa dispatches | Emits one extra `Bash(bash bin/probe-test.sh:*)` token in the `--allowed-tools` argv | Emits one fewer token |

No site reads `probe-test.sh`'s contents, parses its filename for
semantic meaning, or references the basename outside the glob. There
is no namespace, no plug-in registry, no help-text manifest.

The change has no architectural cost.

## 4. Data flow

End-to-end implementing-dispatch flow for ENG-215:

1. Orchestrator dispatches implementing on the per-issue worktree.
2. Agent reads `bin/probe-test.sh`, confirms the file is the residue
   the brainstorm describes (4 lines, `exit 0`, comment header).
3. Agent runs `git rm bin/probe-test.sh`.
4. Agent runs `git commit -m "fix(ENG-215): drop accidental scratch
   bin/probe-test.sh from ENG-203"` (or close variant).
5. Pre-commit hook (`.githooks/pre-commit`) fires:
   - Iterates `bin/*-test.sh` over the **post-rm** working tree
     (probe-test.sh absent).
   - All other tests run as before; KNOWN_BROKEN list is unchanged.
   - Gate decision: pass (no `total_fail` from probe-test.sh, no
     dependency on it elsewhere).
6. Commit succeeds; orchestrator pushes; PR opens; review/qa/build
   proceed as normal.

Post-merge:

1. Next implementing/qa dispatch on any issue: `_dispatch_tools_autotests`
   globs `bin/*-test.sh`, emits one fewer literal token. Argv is one
   token shorter. No behavior change.
2. Next pre-commit run on any branch: hook reports "N-1 tests" total.

No back-fill, no migration, no metric to monitor.

## 5. Error handling

The change has three explicit error surfaces and three matching
fall-back paths.

**5.1 `git rm` fails.** The most plausible cause is the file having
been deleted by some other path (operator hand-edit on the same
worktree, branch rebased on a sibling deferred ticket that already
removed it). `git rm` returns non-zero with a clear message
(`fatal: pathspec 'bin/probe-test.sh' did not match any files`). The
implementing agent's behavior: emit `verdict halt --reason
agent-blocked` and post a one-line description per the dispatch
preamble. No silent fall-through. No partial-commit residue.

**5.2 `git commit` fails because pre-commit hook fails.** The hook
runs every `bin/*-test.sh` on disk; the post-rm state has one fewer
test, no new ones. If a sibling test was already failing on `main`
(see ENG-179 / ENG-203 implement-timeout class memories) the hook
fails and the commit aborts — but that failure is pre-existing, not
caused by this change. Recovery is the standard ENG-203-class manual
landing path: confirm the failing test is in KNOWN_BROKEN or fix it
in a separate ticket. The implementing agent halts with
`agent-blocked` rather than band-aiding an unrelated test.

**5.3 Race: a concurrent dispatch on a sibling branch lands a new
`probe-test.sh`.** Extremely unlikely (no other ticket references the
name; the file was named by an agent typing `probe` as a debug verb).
If it happens, the next clean dispatch on that sibling will see this
deletion when its rebase pulls main; the sibling agent observes
`probe-test.sh` deleted on main and resolves the merge conflict by
keeping the deletion (CLAUDE.md "Executing actions with care":
*"typically resolve merge conflicts rather than discarding changes"*
— here "the change" is the deletion, which is the right thing to
keep).

**No new exit codes** are introduced. `failure_outcome_for_exit`
(`bin/common.sh::failure_outcome_for_exit` per project profile §
"Don'ts" / "Language idioms") is untouched. No `rc` taxonomy interaction.

## 6. Edge cases

**6.1 Operator has a local uncommitted edit to `bin/probe-test.sh`.**
The file is a 4-line `exit 0`; the only realistic local edit is the
operator opening it to confirm what it is. `git rm` of a tracked file
with no working-tree edits succeeds cleanly; if there is an unstaged
modification, `git rm` requires `-f` or aborts safely. The agent will
not pass `-f` (not in the standard cleanup recipe); on abort it
halts with `agent-blocked` and asks the operator. No data loss.

**6.2 ENG-87 `dispatch_id` envelope contract.** Not relevant —
ENG-87's envelope detective (`_validate_dispatch_envelope`, per
CLAUDE.md "Cross-dispatch staleness contract") scans the dispatch
transcript for `mcp__plugin_linear` or direct Linear/curl forms.
`git rm` is a local-only operation; it does not touch Linear, the
network, or `PIPELINE_DISPATCH_ID`. No envelope risk.

**6.3 ENG-194 reviewer-scope-awareness.** The reviewing agent on the
implementing-PR will see exactly one in-scope file deletion under
`bin/` (per the project profile's File layout). No `out-of-plan-scope`
defer risk; no scope-violation halt risk.

**6.4 `_dispatch_tools_autotests` returns empty on this branch after
deletion?** Sanity check: `Glob bin/*-test.sh` on the worktree post-rm
still returns ~76 entries (every other sibling `*-test.sh`). The
helper is not at risk of returning an empty string. Argv composition
remains identical except for the missing token.

**6.5 `bin/probe-test.sh` is referenced by a learned-rules file or
AGENT_PROMPTS.md.** Verified false — `Grep "probe-test"` across
`learned-rules/` and `AGENT_PROMPTS.md` returns zero hits.

**6.6 Hot-spot ordering in pre-commit.** `bin/*-test.sh` is iterated
in lexical order on macOS/Linux. Removing `probe-test.sh` does not
reorder any other test; each test is independent (sentinel pattern,
per project profile "Language idioms"). No flakiness shift.

## 7. Open questions

**OQ-1.** Should a retrospective rule be added to `learned-rules/
harness/implement.md` warning agents that residue from sandbox-failed
`rm` may persist into the worktree across dispatches, and they should
explicitly `git rm` any scratch file matching `*-test.sh` they see
before committing?

*Disposition:* out of scope for ENG-215 — the retrospective agent's
charter is to author rules from observed-failure patterns, and a one-
incident sample is not yet a pattern. If a second `probe-test.sh`-class
finding lands, file a retrospective-rule ticket then. ENG-215 lands the
one-line cleanup only.

**OQ-2.** Should the project profile's `## Don'ts` add a bullet
explicitly forbidding agents from leaving scratch files at the worktree
root?

*Disposition:* out of scope. The dispatch preamble already carries
*"Do NOT write scratch files (.review-body.md, .qa-pr-comment.md,
etc.) at the worktree root — they leak into partition_dirty_paths and
cannot be rm'd"* (ENG-53 #11 / ENG-57 surface). Adding a profile rule
duplicates an existing preamble rule. If the duplication is judged
worthwhile, file a separate ticket.

**OQ-3.** Is there a generic detector that should flag dead
`bin/*-test.sh` files (e.g., tests with body shorter than N lines, no
`source ...common.sh`, only `exit 0`)?

*Disposition:* out of scope and rejected as a generalisation per D-001
rejected alternative D. A "dead-test detector" is itself a new policy
surface that would inevitably gain a config knob and edge cases. The
right action at N=1 is `git rm`.

## 8. Scope check

**In scope** (will land in the ENG-215 PR):

- Delete `bin/probe-test.sh`.
- Commit message referencing ENG-215 and the ENG-203 origin.
- This brainstorm doc (created by the brainstorming dispatch, not
  edited by implementing).

**Out of scope** (explicitly NOT in the ENG-215 PR):

- Any edit to `.githooks/pre-commit` (KNOWN_BROKEN list, glob, hook
  body).
- Any edit to `bin/dispatch.sh::_dispatch_tools_autotests` (the helper
  needs no change; the glob naturally shrinks by one).
- Any edit to `learned-rules/harness/*.md` (project profile, build
  rules, future stage rules).
- Any edit to `AGENT_PROMPTS.md`.
- Any new retrospective rule.
- Any new test that asserts `bin/probe-test.sh` is absent (over-pinning
  by 1 file; the absence is structural).
- Any sibling deferred-from-ENG-203 ticket (ENG-212, ENG-213, ENG-214
  land independently per the ENG-191 selective-exit rubric).

**Frontmatter `linear: ENG-215`** is present at the top of this doc
(verified by inspection); the basename carries the `eng-215` token
(load-bearing for `partition_dirty_paths::D-004` per dispatch
preamble).

## 9. Anti-bias

### 9.1 ADR stress test

No accepted ADRs in `docs/knowledge/decisions.md` — verified via
`Bash ls docs/knowledge/ 2>&1` which returned
`ls: docs/knowledge/: No such file or directory`. The closest prior
decision is ENG-191's selective-exit rubric (in
`docs/brainstorms/2026-06-13-eng-191-…-design.md`), which the
reviewing agent applied correctly to defer this finding. ENG-215 lands
the deferred follow-up, which **reinforces** the rubric (deferred
items DO land; they are not dropped) rather than challenging it.

No ADR pressure.

### 9.2 Simpler alternative

D-001 enumerates four rejected alternatives (A: rename, B: turn into
real test, C: KNOWN_BROKEN, D: generic dead-test detector). The
simpler-than-D-001 alternative would be "do nothing, leave the file in
tree" — rejected because:

- the file's own header comment promises future cleanup;
- the ENG-191 selective-exit rubric exists specifically so deferred
  findings DO land, just not on the critical path; and
- the per-dispatch and per-commit costs (allowlist token, hook-row
  noise) are silent but real and compound.

### 9.3 Assumption inventory

Every named file, line range, exit code, function, and behavior in
this brainstorm is verified against the current worktree per the
dispatch preamble's MANDATORY codebase-fact verification rule.

| Assumption | Status | Evidence |
|---|---|---|
| `bin/probe-test.sh` exists at HEAD on this branch | verified | `Read bin/probe-test.sh:1-4` returned 4 lines, `exit 0`, comment header |
| `bin/probe-test.sh` is on `main` | verified | `git show main:bin/probe-test.sh` returns identical content |
| `bin/probe-test.sh` was created by ENG-203 implementing | verified | `git log --all --oneline --diff-filter=A -- bin/probe-test.sh` returns single commit `df32051 chore(pipeline): implementing for ENG-203` |
| No file in the worktree (other than itself) references `probe-test` | verified | `Grep "probe-test" worktree-wide` returns one hit: `bin/probe-test.sh` |
| `.githooks/pre-commit` runs every `bin/*-test.sh` via glob iteration | verified | `Read .githooks/pre-commit:159-162` shows `printf … "$(ls bin/*-test.sh …)"` and `for t in bin/*-test.sh; do` |
| KNOWN_BROKEN list at `.githooks/pre-commit:88-107` does NOT contain probe-test.sh | verified | `Read .githooks/pre-commit:88-107` shows mutex, render-pr-body, render-prompt-slug, eng-81-reproducer only |
| `bin/dispatch.sh::_dispatch_tools_autotests` at `bin/dispatch.sh:464-477` globs `bin/*-test.sh` and emits one literal `Bash(bash <file>:*)` per match for implementing|qa | verified | `Read bin/dispatch.sh:464-477` shows the glob and the printf |
| implementing-stage base allowlist at `bin/dispatch.sh:651` includes `Bash(git rm:*)` and `Bash(git commit:*)` | verified | `Grep "git rm\|git add" bin/dispatch.sh` returned line 651 with both tokens |
| `bin/` is in the project profile's `## File layout` (in-scope by partition_dirty_paths for implementing) | verified | `Read learned-rules/harness/project-profile.md:51` shows the bullet |
| `partition_dirty_paths::D-004` basename-token rule treats `eng-215` in the brainstorm doc filename as in-scope | verified | dispatch preamble §"Completion checklist" step 1 documents the rule; basename is `2026-06-17-eng-215-…-design.md` |
| Pre-commit hook iterates `bin/*-test.sh` in lexical order (no reorder side-effect from one deletion) | verified | shell glob expansion is lexical on darwin per shell behavior; `Read .githooks/pre-commit:162` shows direct glob iteration |
| CLAUDE.md "Doing tasks" carries the "no half-finished implementations" rule | verified | quoted in the dispatch preamble verbatim |
| ENG-191 selective-exit rubric exists and is documented in `docs/runbooks/recovery.md` §13 | verified | the runbook is referenced by the dispatch preamble's "Failure-mode quick reference" table row for `reason=ship-with-deferred-majors`, and the Linear issue body cites the rubric's five decision factors |
| ENG-203 PR #175 was merged 2026-06-17 in commit `ede2380` | verified | `git log --oneline -10` shows `ede2380 Merge pull request #175 from StupiDeity/feat/eng-203-…` |
| `docs/knowledge/decisions.md` does NOT exist | verified | `Bash ls docs/knowledge/` returned `No such file or directory` |
| `docs/VISION.md` does NOT exist | verified | `Bash ls docs/` did not show `VISION.md` in the listing |
| `learned-rules/harness/brainstorm.md` does NOT exist | verified | `Bash ls learned-rules/harness/` returned only `build.md, project-profile.md` |
| `Bash(git commit:*)` invokes `.githooks/pre-commit` via `core.hooksPath` on this clone | assumed | per project memory `pre-commit-gate-red-blocks-agents.md` and CLAUDE.md "Pre-commit hook" section — `bin/install-git-hooks.sh` sets `core.hooksPath` to `.githooks` |
| No sibling deferred ticket (ENG-212/ENG-213/ENG-214) already deletes `bin/probe-test.sh` in its planned diff | assumed | the three sibling tickets are scoped to `common.sh` and `verify-qa.sh` edits per their Linear titles ("defensive-code violation — reversible (drop check + U-8/U-X/U-Y)"); no overlap with `bin/probe-test.sh`. Implementation note: if a sibling lands first and removes the file, this dispatch's `git rm` will fail at §5.1 and the agent will halt with `agent-blocked`. Operator recovery is trivial (`bash bin/pipeline.sh decide ENG-215 --action abandon` — the work is already done). |

The two "assumed" rows describe behaviors that the harness ALREADY
relies on across hundreds of dispatches (the hook path; sibling-ticket
non-overlap). No new dependency on unverified behavior is introduced.

## 10. Persona review

Six personas run in fixed order per dispatch preamble: design →
security → scope → coherence → product → feasibility. Each persona
records its verdict and any findings inline.

### 10.1 Design — PASS

- **Single decision (D-001).** No fan-out, no hidden coupling, no
  helper to refactor. Four rejected alternatives are enumerated with
  explicit rationale.
- **No abstraction premature or otherwise.** The change is a literal
  `git rm`; the rejected alternative D explicitly rebuts the
  generalisation temptation.
- **Reinforces an existing project rule** (CLAUDE.md "no half-finished
  implementations") on the exact code path the rule names.
- **No new tokens, no new files, no new tests.**
- **Findings:** none.

### 10.2 Security — PASS

- **No new input surface.** No file is created or read at runtime;
  one is deleted.
- **No secret risk.** `bin/probe-test.sh` contains no env-var
  references; deletion has no shell-expansion surface; commit
  message contains no secret-name substrings (`fix(ENG-215): drop
  accidental scratch bin/probe-test.sh from ENG-203` — none of
  `*KEY|*TOKEN|*SECRET|ANTHROPIC*|GITHUB*|LINEAR*` per `bin/secret-
  probe-lint.sh`'s regex).
- **No envelope-validator interaction.** `git rm` does not touch
  Linear, `curl`, or `PIPELINE_DISPATCH_ID`.
- **No allowlist expansion.** Implementing already has `Bash(git rm:*)`
  and `Bash(git commit:*)` per `bin/dispatch.sh:651`. No new privilege.
- **No race.** Single-file local operation; no concurrent reader.
- **Findings:** none.

### 10.3 Scope — PASS

- **Per Linear issue body:** *"defers: known-dead file — reversible
  (one git rm), no regression, no user-visible surface (no-op exit 0),
  has workaround (file is silently inert)"*. Brainstorm scope is
  exactly that — one `git rm`.
- **§8 enumerates out-of-scope items explicitly** (hook edits,
  dispatch.sh edits, learned-rules edits, AGENT_PROMPTS.md edits,
  new tests, sibling deferred tickets).
- **No drift into adjacent helpers.** Pre-commit hook untouched.
  `_dispatch_tools_autotests` untouched. Project profile untouched.
- **Frontmatter `linear: ENG-215` present.** Basename carries `eng-215`
  (verified).
- **Open questions are all dispositioned out-of-scope** — none are
  load-bearing for the one-line cleanup.
- **Findings:** none.

### 10.4 Coherence — PASS

- **No conflict with prior ADRs.** No accepted ADRs touch this code
  path (no `docs/knowledge/decisions.md` exists).
- **Consistent with ENG-191 selective-exit rubric.** Deferred items
  landing is the rubric's design intent.
- **Consistent with ENG-203 origin.** ENG-203 PR #175 is now merged;
  the landing window for deferred follow-ups is open.
- **No conflict with sibling deferred tickets.** ENG-212/213/214 each
  touch `common.sh` / `verify-qa.sh`; ENG-215 touches only
  `bin/probe-test.sh`. Diff sets are disjoint.
- **No documentation drift.** No runbook, AGENT_PROMPTS, or learned-
  rule references probe-test.sh; deletion needs no follow-up text edit.
- **Findings:** none.

### 10.5 Product — PASS

- **No user-visible change.** The file is a no-op; deleting it
  produces no behavior delta on any agent prompt, pipeline event,
  Linear comment, Slack post, or PR comment.
- **No operator-visible change beyond two trivial cosmetic deltas**
  (pre-commit hook prints one fewer PASS row; argv has one fewer
  token).
- **Reversibility intact.** If a future need for `bin/probe-test.sh`
  emerges (unimaginable but enumerated), `git revert` of the ENG-215
  PR or a fresh `Write` restores it in seconds.
- **No regression risk.** No call site loses functionality. No test
  loses coverage (the file has no assertions).
- **Findings:** none.

### 10.6 Feasibility — PASS

- **Every code-level fact verified** against current source (§9.3
  Assumption Inventory). All `path:line` references resolved to the
  cited content via `Read` / `Grep` / `git show`.
- **All named helpers, files, line ranges, and exit codes confirmed
  in the worktree** at the cited line numbers.
- **No phantom artifacts.** No reference to a method, struct, module,
  or runbook that does not exist.
- **Two "assumed" rows are pre-existing harness invariants** (hooks
  path activation; sibling-ticket non-overlap). No new unverified
  dependency.
- **Implementing-stage capability complete.** `Bash(git rm:*)` and
  `Bash(git commit:*)` already in base allowlist; no allowlist edit
  required.
- **Pre-commit hook will pass post-rm** because the remaining test
  suite is unchanged (no probe-test.sh dependency anywhere).
- **No P0 findings.** Zero blockers for implementation.
- **Findings:** none.

### 10.7 Gate

Personas: 6/6 PASS · feasibility P0: 0 · proceeding to planning.
