---
linear: ENG-215
date: 2026-06-17
topic: Delete the dead scratch file bin/probe-test.sh (one git rm)
---

# Plan — Delete the dead scratch file `bin/probe-test.sh`

## Goal

`bin/probe-test.sh` is removed from the harness via one `git rm` + one
conventional-commit message; the post-rm pre-commit suite passes; no
other file is modified.

## Anti-anchoring check

- **Problem restatement (user view).** "The ENG-203 review-loopback
  dispatch left a 4-line scratch executable at `bin/probe-test.sh`; the
  reviewing agent deferred it under the ENG-191 selective-exit rubric.
  Now that PR #175 is merged, land the deferred cleanup." The
  brainstorm's solution — `git rm bin/probe-test.sh` — addresses
  exactly that. No reframing.
- **Solution proportionality.** A one-line removal of a self-described
  dead scratch file is the smallest possible change. No new tests, no
  allowlist edits, no helper refactor. Proportional.
- **Escalation.** Not needed — both checks pass.

## Assumption Inventory

Every fact below was verified against the current worktree at plan
time. Branch-base freshness: `HEAD..origin/main` is **NON-EMPTY** at
plan time (`d2a8968`); 13 commits ahead — the ENG-212 + ENG-213
deferred-from-ENG-203 cleanups merged in the gap. The drift touches
`bin/common.sh`, `bin/common-test.sh`, `bin/run-stage.sh`,
`bin/run-stage-test.sh` only — **no overlap** with `bin/probe-test.sh`
or with this plan's File Structure. `bin/probe-test.sh` is still
present on `origin/main` (verified via `git show
origin/main:bin/probe-test.sh` → identical 4-line content). Task 0
below rebases the branch onto `origin/main` before the deletion lands.

### Files this plan modifies (verified `path:line`)

- `bin/probe-test.sh:1-4` — the entire file. Content (verified by
  `Read`):

  ```
  #!/usr/bin/env bash
  # probe-test.sh — accidental scratch file from ENG-203 review-loopback dispatch.
  # Should be deleted by next clean run; sandbox prevented rm during dispatch.
  exit 0
  ```

  This is the only file the plan modifies. No other source-file edits.

### Files this plan depends on (verified, NOT modified)

- `.githooks/pre-commit:162` — `for t in bin/*-test.sh; do` (verified
  via `Read`). The hook iterates the glob over the post-rm working
  tree; `probe-test.sh`'s removal silently shrinks the iteration by
  one element. The KNOWN_BROKEN array at `.githooks/pre-commit:88-107`
  does NOT contain `probe-test.sh` (verified — entries are mutex,
  render-pr-body, render-prompt-slug, eng-81-reproducer only). Hook
  body, gate logic, and KNOWN_BROKEN list remain unchanged.
- `bin/dispatch.sh:464-477` — `_dispatch_tools_autotests` globs
  `bin/*-test.sh` from the worktree at dispatch time and emits one
  `Bash(bash <file>:*)` per match for `implementing|qa`. Removing one
  file silently shrinks the emitted argv by one token; no helper
  change required.
- `bin/dispatch.sh:651` — `implementing)` allowlist `base=` string
  (verified via `Grep "Bash(git rm" bin/dispatch.sh` → line 651).
  Includes literal `Bash(git rm:*)` AND `Bash(git commit:*)`. No
  allowlist edit required.
- `bin/dispatch-test.sh:2225-2294` — ENG-196 block asserts
  `_dispatch_tools_autotests` grants every `bin/*-test.sh` on disk;
  this remains true post-rm (one fewer file on disk, one fewer grant).
  No new assertion needed; no existing assertion needs inverting.
- `learned-rules/harness/project-profile.md:51` — `bin/` is the first
  bullet of `## File layout`, so `partition_dirty_paths` buckets any
  write/delete under `bin/` as in-scope for implementing. No profile
  edit required.
- `learned-rules/harness/project-profile.md:17` (Test command) and
  `learned-rules/harness/project-profile.md:31-47` (Tool allowlist) —
  the test command is `bash .githooks/pre-commit` which globs the
  remaining `bin/*-test.sh` set; no enumerated entry to retire. No
  profile edit required.
- `docs/brainstorms/2026-06-17-eng-215-...-design.md` — frontmatter
  `linear: ENG-215` already present; this plan is its downstream
  artifact. No brainstorm edit.

### Codebase precedent verified

- `Grep "probe-test"` worktree-wide returns exactly two hits:
  `bin/probe-test.sh` (the file itself) and the ENG-215 brainstorm.
  Zero source-of-truth references in `AGENT_PROMPTS.md`,
  `learned-rules/`, `docs/runbooks/`, or any sibling `bin/*.sh`.
- `git log --all --oneline --diff-filter=A -- bin/probe-test.sh`
  returns a single commit (verified in the brainstorm Assumption
  Inventory). No revival history.

### Assumed (validated at implement-time)

- `git rm bin/probe-test.sh` succeeds (file tracked, no unstaged
  working-tree edits at dispatch time). If it fails (file already
  removed by a sibling merge, or operator-staged mod), the implement
  agent halts with `agent-blocked` per §5.1 of the brainstorm.
- `.githooks/pre-commit` is wired (`core.hooksPath=.githooks`) on this
  clone — confirmed by the implement agent at commit time (commit
  succeeds → hook ran → suite green).

## System invariants

- The pre-commit hook iterates `bin/*-test.sh` via shell glob, so a
  deleted test file shrinks the iteration set silently and no
  hand-maintained list needs touching. verified_by: .githooks/pre-commit:bin/*-test.sh
- `_dispatch_tools_autotests` globs `bin/*-test.sh` from the worktree
  at dispatch time and emits one `Bash(bash <file>:*)` per match for
  `implementing|qa`; removing `bin/probe-test.sh` silently shrinks
  the emitted argv by one token. verified_by: bin/dispatch-test.sh:ENG-196
- The implementing-stage base allowlist in `dispatch.sh` already
  contains `Bash(git rm:*)` and `Bash(git commit:*)`; no allowlist
  expansion is required for this plan. verified_by: bin/dispatch.sh:allowed_tools_for
- `bin/probe-test.sh` is referenced by zero source files outside
  itself (verified by worktree-wide grep at plan time); its deletion
  cannot break any caller, import, or learned-rule reference. verified_by: task:T1

## File Structure

Modified (existing files):

- *(none — this plan modifies zero existing files; the only operation
  is a tracked-file deletion via `git rm`)*

Deleted:

- `bin/probe-test.sh` — the entire 4-line scratch file (verified
  dead per Assumption Inventory).

No new files. No renames. No new tests. No allowlist edits. No
learned-rules edits. No `AGENT_PROMPTS.md` edits. No project-profile
edits.

## API Contract

No new API surface. The change is a single tracked-file deletion in a
bash orchestration repo with no FE↔BE wire format, no IPC protocol,
no HTTP route, no protobuf schema, no generated types.

## Backend Tasks

### Task 0: Rebase onto `origin/main`

- `depends_on: []`
- `touches: (git working tree only — no source-file edits)`

`HEAD..origin/main` is NON-EMPTY at plan time (13 commits ahead — see
Assumption Inventory). The drift is structurally clean: `origin/main`
touches `bin/common.sh`, `bin/common-test.sh`, `bin/run-stage.sh`,
`bin/run-stage-test.sh` only (verified via `git diff --stat
HEAD..origin/main -- bin/`). None of those files appear in this plan's
File Structure; the dropped file `bin/probe-test.sh` is untouched on
`origin/main`. Rebasing now keeps the implement agent aligned with the
ENG-212/ENG-213 cleanups that landed in the gap.

Steps:

- [ ] Run `git fetch origin main` then `git rebase origin/main`.
  Expect zero conflicts (no overlapping file edits per the drift
  analysis above).
- [ ] After the rebase, re-verify `bin/probe-test.sh` is still present
  by running `git ls-files bin/probe-test.sh` (expect one line of
  output) AND `cat bin/probe-test.sh | head -4` (expect the four
  lines quoted in Assumption Inventory). If the file is absent after
  rebase, a sibling ticket already landed the cleanup — halt the
  dispatch via `bash bin/pipeline.sh event ENG-215 verdict halt
  --reason agent-blocked` and post a one-line comment naming the
  upstream SHA that removed it; the operator can then `decide
  --action abandon` since the work is done.
- [ ] Re-verify `.githooks/pre-commit:162` still contains the literal
  `for t in bin/*-test.sh; do` via `grep -n 'for t in bin/\*-test.sh'
  .githooks/pre-commit` (expect a single match). If the line moved or
  the iteration shape changed, re-derive the System invariants
  resolution before proceeding to Task 1.

### Task 1: Delete `bin/probe-test.sh` and commit

- `depends_on: [0]`
- `touches: bin/probe-test.sh (delete)`

Steps:

- [ ] Confirm `bin/probe-test.sh` is the four-line scratch file
  quoted in Assumption Inventory. **Edit-boundary key (content
  anchor):** the file's body must contain BOTH the literal comment
  `accidental scratch file from ENG-203 review-loopback dispatch` AND
  the literal `exit 0` body. If either anchor is absent (file
  rewritten by an interleaving change), HALT — do NOT delete a file
  whose content no longer matches the brainstorm's description.
- [ ] Run `git rm bin/probe-test.sh`. Expect rc=0 and the file to be
  staged for deletion. Confirm via `git status` — exactly one entry
  reading `deleted: bin/probe-test.sh` (no other staged changes).
- [ ] Run `git diff --cached --stat`. Expect exactly one line:
  `bin/probe-test.sh | 4 ----`. If any other file appears in the
  staged diff, HALT — the rebase in Task 0 must have left local
  changes; investigate before committing.
- [ ] Run `git commit -m "fix(ENG-215): drop accidental scratch
  bin/probe-test.sh from ENG-203"`. The pre-commit hook fires
  automatically (per `core.hooksPath=.githooks`); the suite must
  report all tests pass / SKIP only on KNOWN_BROKEN. If the hook
  fails on a sibling test that is NOT `probe-test.sh`-related, that
  failure is pre-existing; halt with `agent-blocked` rather than
  modifying KNOWN_BROKEN or any other file (this is the ENG-203
  implement-timeout-on-oversized-foundation-tickets memory class —
  agents that band-aid pre-commit reds compound the problem).
- [ ] Run `git log --oneline -1`. Expect a single new commit with the
  ENG-215 message. Run `git show --stat HEAD`. Expect exactly one
  changed file: `bin/probe-test.sh | 4 ----` (deletion).

## Frontend Tasks

*(none — the harness has no UI surface; this is a bash orchestration
repo per the project profile §Stack)*

## Failure Mode → Test Map

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
|---|---|---|---|---|
| `git rm` fails because file already removed by sibling | Concurrent merge or operator hand-edit removed `bin/probe-test.sh` before Task 1 ran | `git rm` returns rc=128 with `did not match any files`; implement agent halts with `verdict halt --reason agent-blocked` per §5.1 of brainstorm; no partial-commit residue | smoke | manual operator inspection — no programmatic test (one-shot deletion, not a regression-prone surface) |
| Pre-commit hook fails on an unrelated sibling test | A pre-existing test on `main` is red (e.g., session-limit-induced KNOWN_BROKEN drift) at dispatch time | `git commit` aborts with hook-failure output; implement agent halts with `agent-blocked` rather than editing KNOWN_BROKEN or unrelated files | smoke | `.githooks/pre-commit` itself is the gate (no separate test); operator inspects hook output |
| `_dispatch_tools_autotests` returns empty after rm | Post-rm worktree has zero `bin/*-test.sh` files | The helper returns empty string (soft, no `bin/*-test.sh` literal leak) | unit | `bin/dispatch-test.sh:2282-2287` — already pins the empty-worktree case |
| Sibling test grant set drifts because rm leaks into the wrong glob | A new test file with name collision is added in parallel | `_dispatch_tools_autotests` continues to glob `bin/*-test.sh` and emit one entry per match | unit | `bin/dispatch-test.sh:2237-2250` — AC1 disk-coverage assertion |
| Hook iterates a non-`*-test.sh` file because rm corrupted the glob | Filesystem inode reuse on macOS (theoretical) | The hook's glob picks up only post-rm `bin/*-test.sh` files; the iteration order is lexical and deterministic | smoke | post-rm `.githooks/pre-commit` run during Task 1 commit; operator inspects the printed test count |
| Plan-contract validator halts because the JSON sibling is malformed | This plan's `.json` sibling is missing or non-conforming | `bin/run-stage.sh::_validate_plan_contract` halts the planning dispatch with `plan-contract-invalid` | unit | `bin/plan-schema-test.sh` — exercises the validator on every commit via the pre-commit hook |

## Test Strategy

**Unit.** No new unit tests are required. The two pinning surfaces
(`bin/dispatch-test.sh:ENG-196` for `_dispatch_tools_autotests`, and
the project's pre-commit hook for `.githooks/pre-commit`) already
pin the glob-based iteration contracts the plan depends on; both
continue to pass post-rm because:

- The ENG-196 AC1 assertion globs `bin/*-test.sh` at runtime and
  checks every member is granted. Removing one element shrinks both
  the disk set and the autotests output simultaneously; the
  cardinality-match check stays green.
- The pre-commit hook's `for t in bin/*-test.sh; do` likewise
  iterates the post-rm set with one fewer element; no per-element
  assertion exists.

**Integration.** None. There is no FE↔BE surface, no IPC layer, no
HTTP route — nothing to integration-test.

**Smoke.** The implement agent runs `git status` + `git diff --cached
--stat` + `git log --oneline -1` + `git show --stat HEAD` during
Task 1 (per the step list) as cheap structural smokes. The
pre-commit hook is itself a per-commit smoke that runs the entire
`bin/*-test.sh` suite — this is the broadest gate the deletion
crosses. Plan-side smokes encoded in the sibling `.json` per-feature
pass_criteria: `file_exists` on the deletion target (asserting it
was previously present), a `grep`-style anti-pin asserting no
worktree file outside `bin/probe-test.sh` and the brainstorm
references the literal `probe-test` token, and a `smoke` rc=0 run of
`.githooks/pre-commit` end-to-end.

**Adversarial coverage.** The brainstorm's §5 (Error handling) and §6
(Edge cases) enumerate six pre-considered adversarial paths:
race-with-sibling-deletion, operator-local-edit, ENG-87
envelope-validator interaction, ENG-194 reviewer-scope-awareness,
post-rm autotests empty edge, and learned-rules/AGENT_PROMPTS
reference. All six are addressed by the §Test Strategy entries above
(unit + smoke combo) or by the Failure Mode → Test Map (`git rm`
failure path + pre-commit hook failure path). The QA stage will
exercise the deletion end-to-end via the post-implement pre-commit
gate; no new adversarial test is warranted at N=1 cleanup (per the
brainstorm's D-001 rejected alternative D — "generic dead-test
detector" was explicitly rejected as gold-plating).

**Test-gate closure sweep result.** No production token is removed
from any non-deleted file (the deletion removes the entire file, not
a token within it). The add-side closure does not apply (no new
`bin/*-test.sh` file). The project-profile file therefore needs no
edit. Verified via `Grep "probe-test"` returning only
`bin/probe-test.sh` and the ENG-215 brainstorm.
