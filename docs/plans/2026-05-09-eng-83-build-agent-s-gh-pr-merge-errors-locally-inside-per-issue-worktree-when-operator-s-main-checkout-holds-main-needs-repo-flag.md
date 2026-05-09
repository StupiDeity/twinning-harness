---
linear: ENG-83
date: 2026-05-09
topic: build agent's `gh pr merge` always carries `--repo <owner>/<repo>` so gh skips the local-cleanup `git checkout main` that errors against the operator's main worktree
---

# Plan — ENG-83 build agent §7 *Merge strategy* gains the `--repo` flag, content-test pin, and runbook note

Implementation plan for the design at
`docs/brainstorms/2026-05-09-eng-83-build-agent-s-gh-pr-merge-errors-locally-inside-per-issue-worktree-when-operator-s-main-checkout-holds-main-needs-repo-flag-design.md`.

## Anti-anchoring check

- **Problem (operator's words).** The build agent fires `gh pr merge <N>
  --merge --auto --delete-branch -t "…" -b "…"` from inside the per-issue
  worktree. `gh`'s `--delete-branch` post-merge cleanup runs `git
  checkout main` to delete the source branch locally, which collides with
  the operator's main checkout (which already holds `main` as a worktree
  at `~/code/twinning-harness`). git refuses with `fatal: 'main' is
  already used by worktree at …`, and `gh pr merge` errors. Both build
  agents on 2026-05-08 (ENG-77, ENG-79) hit this and recovered the same
  way: append `--repo <owner>/<repo>` so `gh` treats the operation as
  cross-repo and skips the local cleanup.
- **Brainstorm addresses it?** Yes. D-001 codifies the `--repo` flag and
  a two-call derivation step in `AGENT_PROMPTS.md` §7's *Merge
  strategy* block. D-002 pins the rule + rationale + canonical
  derivation form via four greps in `bin/agent-prompts-content-test.sh`
  and a negative grep against the allowlist-unsafe `$(gh ...)` shape.
  D-003 adds a "this looks weird, isn't a bug" paragraph to
  `docs/runbooks/operator-mental-model.md` §4. The brainstorm does not
  reframe — it solves exactly the problem the issue named.
- **Proportional?** Yes. Three files touched: a ~25-line prompt edit, a
  ~30-line test block, a ~10-line runbook paragraph. No `bin/` code
  change. No new dispatch lane, no new exit code, no new metric event,
  no new ADR, no new `learned-rules/harness/build.md` entry (deferred to
  retrospective per ENG-71 / ENG-79 precedent).
- **No reframe; no scope creep; no escalation. PROCEED with implementation.**

## Goal

After the implement stage runs, the harness will have on the feature branch:

1. **D-001 in tree.** `AGENT_PROMPTS.md` §7's *Merge strategy* block
   (currently `AGENT_PROMPTS.md:1387-1400`) instructs the agent to (a)
   first derive `<owner>/<repo>` via
   `gh pr view <N> --json url --jq '.url | split("/")[3:5] | join("/")'`,
   capturing the result as a literal string, and (b) pass that literal
   as `--repo <derived-owner-repo>` on the `gh pr merge` invocation. A
   rationale paragraph names the worktree-collision failure mode so a
   future "cleanup" pass cannot strip the unfamiliar flag without
   context. The existing `--merge`, `--auto`, `--delete-branch`,
   `-t/-b` semantics are preserved verbatim; only `--repo
   <derived-owner-repo>` is appended and a derivation step prepended.
2. **D-002 in tree.** `bin/agent-prompts-content-test.sh` gains four
   new asserts after the existing ENG-71 §7 pin (line 655): positive
   grep that §7 names `--repo` on `gh pr merge`, positive grep that §7
   carries the `worktree-locks-main` rationale phrase, negative grep
   that §7 lacks the allowlist-unsafe `$(gh pr view ...)` shape,
   positive grep that §7 names the canonical `gh pr view <N> --json
   url` derivation form. The test runs in <1 s and is picked up by the
   `.githooks/pre-commit` glob.
3. **D-003 in tree.** `docs/runbooks/operator-mental-model.md` §4
   (Branch / git invariants, after the `core.bare=true` paragraph at
   line 205) gains a ~10-line paragraph titled "Build agent's `gh pr
   merge` always carries `--repo <owner>/<repo>`" explaining the
   worktree collision and confirming the flag is by design.
4. **Test gate green.** Every `bin/*-test.sh` exits 0 (in particular
   `bash bin/agent-prompts-content-test.sh` exits 0 with the four new
   asserts passing); `bash -n` on any modified bash file exits 0;
   `bash bin/secret-probe-lint.sh` exits 0; `bash .githooks/pre-commit`
   exits 0.

Verifiable by:

```
bash bin/agent-prompts-content-test.sh \
  && bash bin/secret-probe-lint.sh \
  && bash .githooks/pre-commit
```

exiting 0.

Out of scope (explicit per brainstorm §2 non-goals + §10 open questions):

- **O-1 — `{repo_full_name}` token injection in `bin/render-prompt.sh`.**
  Cleaner long-term shape (single source of truth in the orchestrator,
  mirrors `{branch_name}` per ENG-79). Out of scope per the issue's
  "no `bin/` code change" framing. File a follow-up ticket.
- **O-3 — Transcript-based assertion in `bin/dispatch.sh` enforcing
  `--repo` on every `gh pr merge` invocation.** Defense-in-depth on a
  low-impact failure mode (agents recover on their own); ENG-71's
  chained-command blind spot suggests the same matcher would have its
  own gaps. Defer.
- **O-5 — Cross-stage audit for similar local-cleanup-vs-worktree
  collisions** (`gh pr comment`, `gh pr edit`, `gh pr close`,
  `gh release create`). None of these issue local checkouts; exposure
  is theoretical, not observed. Defer.
- **`learned-rules/harness/build.md` Bld-002 hand-edit.** Brainstorm-time
  hand-edits bypass the `pipeline:rule-reviewed` retrospective gate.
  The retrospective may add Bld-002 on its next weekly run; this plan
  does not preempt that.
- **`bin/dispatch.sh` allowlist additions.** `Bash(gh pr view:*)`,
  `Bash(gh pr merge:*)`, `Bash(jq:*)` are already present at
  `bin/dispatch.sh:328` (verified — see Assumption Inventory A-004).
  No new pattern needed.

## Architecture

Three files change. No new files. No new test scripts. No new
dependencies.

The architectural pivot is "codify a discovered workaround in the
prompt, pin it via content test, document the operator-side weirdness."
Three layers, three independent regression guards:

- **Prompt layer** (`AGENT_PROMPTS.md` §7 *Merge strategy* block): the
  authoritative site for the `gh pr merge` command shape — the
  orchestrator never invokes `gh pr merge` (verified at A-009: `grep
  -rn "gh pr merge" bin/` returns no hits in `bin/`), so symmetric
  prompt-orchestrator pins (ENG-62 Bld-001 / ENG-71) do not apply.
- **Test layer** (`bin/agent-prompts-content-test.sh`): four greps
  (positive / positive / negative / positive) that fail the pre-commit
  hook if a future edit drops the `--repo` flag, removes the rationale,
  re-introduces the allowlist-unsafe `$(gh ...)` shape, or drops the
  canonical derivation form.
- **Runbook layer** (`docs/runbooks/operator-mental-model.md` §4): a
  paragraph that prevents an operator scratching their head over the
  unfamiliar flag in a Linear comment or PR description. The runbook
  is the canonical site for "looks weird, isn't a bug" notes per
  ENG-80 / CLAUDE.md "Failure-mode quick reference" §.

There is no `docs/VISION.md`, no `docs/ARCHITECTURE.md`, no
`docs/knowledge/decisions.md` (verified: `ls docs/` returns
`brainstorms/  pipeline-vocabulary.md  pipeline-vocabulary.template.md
plans/  runbooks/`; no `knowledge/` subdir). Governing constraints come
from `CLAUDE.md`, `learned-rules/harness/{project-profile,build}.md`
(verified: only `build.md` and `project-profile.md` exist; no `plan.md`),
and the brainstorm itself.

## Tech stack

- Bash 3.2+ (Darwin default).
- POSIX `grep -qE` (extended regex) for the positive `gh pr merge.*--repo`
  pin and the negative `\$(gh|repo_full=` pin; `grep -qF` (literal) for
  the rationale-substring pin and the canonical-derivation-form pin.
- `bin/agent-prompts-content-test.sh::section_body` (the existing
  awk-based H2 extractor at lines 20-28); the existing `s7` extractor
  at line 33; the existing `ok()` / `nope()` helpers at lines 13-14.
- `gh` CLI tool patterns already in the building tool allowlist:
  `Bash(gh pr view:*)` and `Bash(gh pr merge:*)` at
  `bin/dispatch.sh:328`. `--jq` is a sub-flag of `gh pr view`, not a
  separate `jq` invocation; the embedded jq filter is part of the argv
  passed to `gh`.

## Assumption Inventory

Every modified-file fact below is `path:line`-cited against the current
worktree per the codebase-fact verification mandate. Each entry quotes
the relevant region so the implement agent can confirm the target
without re-deriving it.

### Files modified in this plan: 3

- `AGENT_PROMPTS.md` (D-001 prompt edit at lines 1387-1400)
- `bin/agent-prompts-content-test.sh` (D-002 test block insertion after line 655)
- `docs/runbooks/operator-mental-model.md` (D-003 paragraph insertion after line 205)

### Modified-file facts — current state, signatures, and verification points

- **A-001 — `AGENT_PROMPTS.md:1387-1400` is the §7 *Merge strategy*
  block, currently 14 lines.** Verified by direct read. Concrete
  current shape:
  ```
  Merge strategy (FIXED — no alternative; per ENG-13 D-008):
    - `gh pr merge <N> --merge --auto --delete-branch -t "<conventional-title>" -b "<body>"`
      where <conventional-title> is the PR title (which P7 ensures is conventional-commits
      formatted).
    - Use `--merge` (regular merge commit), NOT `--squash`. Regular merges preserve
      feature-branch history reachable from main via the merge commit's second parent,
      which is load-bearing for retrospective archaeology (`git log --all` queries).
    - `--auto` queues the merge to fire once required checks pass (P5) AND a human
      Code Owner has approved (P2 strengthened).
    - `--delete-branch` removes `{branch_name}` post-merge. The periodic
      `cleanup-worktrees.sh` sweep detects the merged state and removes the local
      worktree on a subsequent tick.
    - Do NOT perform any worktree cleanup here — it is centralized in the sweep
      for uniformity.
  ```
  D-001 replaces lines 1387-1400 with a longer block (derivation step
  prepended; `--repo <derived-owner-repo>` added to the merge command;
  rationale paragraph appended; `--merge` / `--auto` / `--delete-branch`
  semantics preserved verbatim). Exact replacement text in Backend
  Task 1 below.

- **A-002 — `AGENT_PROMPTS.md:1402-1416` (immediately after the *Merge
  strategy* block) is the *Post-merge verification* block.** Verified
  by direct read. The block opens with `Post-merge verification
  (MANDATORY):` at line 1402. D-001's longer *Merge strategy* block
  shifts this header down by ~10 lines but does NOT modify it. The
  Edit tool's `old_string` for D-001 must NOT span past line 1400
  (the trailing `for uniformity.` line); the `new_string` must end
  with the same blank-line discriminator as line 1401 so the
  Post-merge verification header still anchors correctly.

- **A-003 — `AGENT_PROMPTS.md:1238` opens the §7 fenced block.**
  Verified: line 1238 is the literal triple-backtick opening fence
  for §7's prompt body. The closing fence sits at the end of §7
  (before §8's `## 8. Release Agent` heading). `bin/render-prompt.sh`
  enforces "exactly two fences per §7" (CLAUDE.md "AGENT_PROMPTS.md is
  load-bearing" §). D-001's edit MUST NOT introduce any column-0
  triple-backtick fence inside §7's body — the *Merge strategy*
  block's content must be plain prose / indented bash snippets, not
  a nested fenced code block.

- **A-004 — `bin/dispatch.sh:328` building base allowlist.** Verified
  by direct read:
  ```bash
  building)       base='Read,Write,Grep,Glob,Bash(git fetch:*),Bash(git clone:*),Bash(git rebase:*),Bash(gh run:*),Bash(gh pr list:*),Bash(gh pr view:*),Bash(gh pr checks:*),Bash(gh pr edit:*),Bash(gh pr merge:*),Bash(jq:*),Bash(mktemp:*),Bash(bash .pipeline/bin/linear.sh:*),Bash(bash bin/linear.sh:*),Bash(bash .pipeline/bin/pipeline.sh:*),Bash(bash bin/pipeline.sh:*),Bash(bash .pipeline/bin/slack.sh:*),Bash(bash bin/slack.sh:*)' ;;
  ```
  All three patterns the agent needs for D-001's two-call derivation
  + merge are present: `Bash(gh pr view:*)` (for T1), `Bash(gh pr
  merge:*)` (for T2), and `Bash(jq:*)` (only relevant if a future
  agent factors the embedded `--jq` filter out as a piped invocation;
  the canonical D-001 form uses `gh pr view --jq` so jq is not
  invoked as a separate process). No allowlist edit needed.

- **A-005 — `AGENT_PROMPTS.md:1243` (§7 secret-handling preamble) and
  the embedded `$(cmd)` ban.** Verified by direct read. The relevant
  substring at line 1243:
  > Common allowlist-parser pitfalls: `$(cmd)` and backticks inside
  > Bash arguments are rejected — pass argument values as literal
  > text…
  This is the rule D-002's negative grep keys on. D-001's prompt
  text must instruct the agent to capture the T1 result as a
  literal string and substitute it into T2 verbatim, NOT as
  `--repo "$(gh pr view ...)"`.

- **A-006 — `AGENT_PROMPTS.md:1245` (the ENG-71 MANDATORY worktree-HEAD
  rule paragraph).** Verified by direct read. Names `gh pr view <N>
  --json mergeCommit` as the SHA-verification path. D-001 does NOT
  modify this paragraph — only the *Merge strategy* block 142 lines
  later. The two paragraphs are independent.

- **A-007 — `bin/agent-prompts-content-test.sh:33` carries the §7
  extractor.** Verified by direct read:
  ```bash
  s7="$(section_body "## 7. Build Agent")"
  ```
  D-002 reuses this extractor without modification — the four new
  asserts pipe `printf '%s\n' "$s7"` into `grep`, identical to the
  pattern used by the existing ENG-71 §7 pin at lines 633-655.

- **A-008 — `bin/agent-prompts-content-test.sh:633-655` is the
  existing ENG-71 §7 pin block.** Verified by direct read. Pattern:
  six `if printf '%s\n' "$s7" | grep …; then ok …; else nope …; fi`
  blocks plus a `for` loop over four banned `git` commands. D-002's
  new block follows the same shape — four asserts, each ~5-7 lines.
  The new block must be inserted AFTER the existing ENG-71 block
  (line 655 — the closing `fi` of the chained-command worked-example
  pin) and BEFORE the next pre-existing comment block ("ENG-71 C1
  regression pin") which starts at line 657. Insertion point:
  immediately before line 657's blank line / comment header.

- **A-009 — Orchestrator does NOT invoke `gh pr merge` anywhere.**
  Verified by `grep -rn "gh pr merge" bin/` (zero hits in `bin/`).
  The only orchestrator-side `gh pr` invocation is `bin/run-stage.sh`'s
  `gh pr view --json commits` (verified at the brainstorm's A-009
  reference; not re-citing the line because the orchestrator code is
  not modified by this plan). Symmetry pins (ENG-62 / ENG-71) do not
  apply: there is no orchestrator-side merge command shape to keep
  in lockstep with the prompt's.

- **A-010 — `bin/agent-prompts-content-test.sh` total length is 827
  lines.** Verified by `wc -l`. D-002's ~30-line insert grows the
  file to ~857 lines. The summary block at lines 825-827
  (`printf '\nRESULTS: %d passed, %d failed\n' …`; `[[ "$FAIL" == 0
  ]] || exit 1`; `exit 0`) is the file's last block — the insertion
  at line 657 sits well before this trailer and does not alter it.

- **A-011 — `docs/runbooks/operator-mental-model.md:165-205` is §4
  *Branch / git invariants*.** Verified by direct read. The section
  opens at line 165 with `## §4 — Branch / git invariants`; the
  `core.bare=true` paragraph runs lines 190-205; the `## §5 — Process
  / runtime` heading sits at line 207. D-003's new paragraph inserts
  between line 205 (the closing `git -C /path/to/twinning-harness
  config core.bare false` snippet) and line 207 (the §5 heading) —
  the blank line at 206 is the natural boundary.

- **A-012 — `docs/runbooks/operator-mental-model.md` total length is
  325 lines.** Verified by `wc -l`. D-003's ~10-line paragraph grows
  the file to ~335 lines. No file-trailer trailer is at risk.

- **A-013 — `bin/render-prompt.sh:255-265` token-substitution table.**
  Verified by precedent in the brainstorm's Assumption Inventory. The
  current token set is `{issue_id}`, `{issue_id_lower}`, `{date}`,
  `{slug}`, `{brainstorm_file}`, `{plan_file}`, `{branch_name}`,
  `{stage_summary_path}`, `{learned_rules_dir}`. No `{repo_full_name}`
  token exists today. D-001 explicitly does NOT introduce a new
  token (O-1 deferred); the agent derives `<owner>/<repo>` at
  runtime via `gh pr view`. No edit to `bin/render-prompt.sh`.

- **A-014 — Filename mirrors the brainstorm's basename.** The plan
  doc at
  `docs/plans/2026-05-09-eng-83-build-agent-s-gh-pr-merge-errors-locally-inside-per-issue-worktree-when-operator-s-main-checkout-holds-main-needs-repo-flag.md`
  carries the `eng-83` token in its basename per the prompt's "in-scope
  bucketing" requirement (`partition_dirty_paths::D-004`). This file
  is the only new artifact; D-001 / D-002 / D-003 modify existing
  files in place.

- **A-015 — `.githooks/pre-commit` picks up `bin/agent-prompts-content-test.sh`.**
  Verified by precedent (the test is part of the existing pre-commit
  glob; the ENG-71 §7 pin block at line 633 is exercised on every
  commit and PR #65, #66 builds confirmed it as part of the suite).
  D-002's four new asserts run automatically without any glob change.

- **A-016 — No `bin/render-prompt.sh` edit means the existing fence
  contract is preserved.** The §7 fenced block (open at A-003's line
  1238; close at the end of §7) must stay exactly two fences per the
  `render-prompt.sh::section_body` extractor. D-001's prompt edit
  uses indented bash snippets (4-space indent, no column-0 fences),
  not nested fenced blocks. The brainstorm §4 D-001's draft text
  (quoted here in Backend Task 1) demonstrates the canonical
  4-space-indented form.

- **A-017 — No `learned-rules/harness/build.md` edit.** Verified by
  reading `learned-rules/harness/build.md`'s 60-day-shelf-life header
  (per the brainstorm Assumption Inventory). Brainstorm-time
  hand-edits bypass the `pipeline:rule-reviewed` gate; the
  retrospective owns this file's mutations. The plan does NOT touch
  `learned-rules/harness/build.md`.

- **A-018 — Issue body's "fix shape" matches D-001 exactly.** Issue
  body's *Fix shapes* §:
  > Codify in `AGENT_PROMPTS.md` §7 (Build Agent). The merge
  > invocation should always pass `--repo <owner>/<repo>` to force
  > server-side merge: `gh pr merge <PR> --repo <owner>/<repo>
  > --merge --auto --delete-branch`. The `<owner>/<repo>` value is
  > already available — derivable from `gh pr view <PR> --json
  > headRepository,baseRepository` or just hardcoded in the prompt
  > for the harness-self target.
  D-001 picks the `gh pr view --json url` derivation form (per
  brainstorm §4 D-001 rationale: `--json url` is universally
  supported across gh versions; `--json headRepository,baseRepository`
  is gh-version-dependent). The hardcoded fallback is rejected per
  brainstorm §9 alternative #1 (brittle on multi-target deployments).
  The choice is documented in brainstorm §4 D-001's "Why `gh pr view
  --json url` and not `--json baseRepository`?" subsection.

- **A-019 — No new files outside `docs/plans/`.** This plan adds
  exactly one new file (the plan doc itself); D-001 / D-002 / D-003
  all edit existing files in place. No new test scripts, no new
  helper bash files, no new fixtures.

## File Structure

```
AGENT_PROMPTS.md                              MODIFIED — D-001. §7 Merge strategy
                                                          block at lines 1387-1400
                                                          gains a derivation step,
                                                          --repo on the merge command,
                                                          and a rationale paragraph.
                                                          Existing --merge / --auto /
                                                          --delete-branch / -t / -b
                                                          semantics preserved verbatim.
                                                          Block grows from ~14 to ~25
                                                          lines.

bin/
  agent-prompts-content-test.sh               MODIFIED — D-002. Four new asserts
                                                          inserted after the existing
                                                          ENG-71 §7 pin (line 655).
                                                          Reuses the existing s7
                                                          extractor (line 33) and
                                                          ok/nope helpers (lines 13-14).
                                                          File grows from 827 to ~857 lines.

docs/
  runbooks/
    operator-mental-model.md                  MODIFIED — D-003. ~10-line paragraph
                                                          inserted at end of §4
                                                          (Branch / git invariants),
                                                          after the core.bare=true
                                                          paragraph at line 205. File
                                                          grows from 325 to ~335 lines.
  plans/
    2026-05-09-eng-83-build-agent-s-gh-pr-merge-errors-locally-inside-per-issue-worktree-when-operator-s-main-checkout-holds-main-needs-repo-flag.md
                                              NEW — this file. Written at planning
                                                    exit. Bucketed in-scope via the
                                                    eng-83 basename token per
                                                    partition_dirty_paths::D-004.
```

No changes to: `bin/dispatch.sh` (allowlist already complete per A-004),
`bin/render-prompt.sh` (no new template token per A-013),
`bin/run-stage.sh`, `bin/common.sh`, `bin/linear.sh`,
`bin/pipeline.sh`, `bin/poll.sh`, `bin/reconcile.sh`,
`bin/scope-check.sh`, `bin/verdict-handler.sh`,
`bin/classify-failure.sh`, `bin/metrics.sh`, `bin/setup.sh`,
`bin/branch-name.sh`, `bin/run-local.sh`,
`bin/run-local-helpers.sh`, `bin/pipeline-events.json`,
`launchd/**`, `.github/workflows/**`, `.githooks/pre-commit`,
`docs/pipeline-vocabulary.md`, `docs/runbooks/recovery.md`,
`learned-rules/**`, `CLAUDE.md`.

## API Contract

**No new API surface.** The harness has no FE↔BE API surface (this is
a bash orchestration repo with no application code per the project
profile addendum). The change is a documentation and content-test
update only:

- No new `dispatch.sh::allowed_tools_for` case (existing patterns
  cover both T1 and T2 per A-004).
- No new exit code (no bash error path added; `gh pr merge` failures
  remain on the existing P-precondition path through
  `failure_outcome_for_exit`).
- No new metric event name.
- No new comment-body shape.
- No new orchestrator hook.
- No new lane fence.
- No new `bin/pipeline-events.json` registry entry.
- No `docs/pipeline-vocabulary.md` regeneration.
- The `gh pr merge` command shape is the *agent's* tool invocation, not
  a programmatic API surface. The two-step derivation (T1: `gh pr view`,
  T2: `gh pr merge --repo`) executes inside the dispatched `claude -p`
  session under the existing building tool allowlist.

## Backend Tasks

This plan commits to three concrete file edits (D-001, D-002, D-003)
plus a verification step. The implement agent runs the four tasks below
in order; Tasks 1, 2, and 3 can each run independently after Task 0;
Task 4 verifies all three.

### Task 0: Confirm baseline (no-op verification)

- `depends_on: []`
- `touches: AGENT_PROMPTS.md (read-only); bin/agent-prompts-content-test.sh (read-only); docs/runbooks/operator-mental-model.md (read-only)`

- [ ] **Step 0.1.** Read `AGENT_PROMPTS.md:1387-1400` and confirm the
  current *Merge strategy* block matches A-001's quoted shape verbatim
  (no `--repo` flag, 14 lines, opens with `Merge strategy (FIXED — no
  alternative; per ENG-13 D-008):`). If the block has drifted (e.g.,
  another change merged between brainstorm and now), STOP and re-read
  the brainstorm §4 D-001's rationale before proceeding — the edit may
  need to merge with the new state.
- [ ] **Step 0.2.** Read `bin/agent-prompts-content-test.sh:633-655`
  and confirm the existing ENG-71 §7 pin matches the brainstorm
  Assumption Inventory's quoted shape (final assert is the
  chained-command worked-example pin closing at line 655 with `fi`).
- [ ] **Step 0.3.** Read `docs/runbooks/operator-mental-model.md:200-207`
  and confirm the `core.bare=true` paragraph closes at line 205 with
  `git -C /path/to/twinning-harness config core.bare false` followed
  by ` ``` ` on line 205-ish, blank line at 206, and `## §5 — Process
  / runtime` at line 207. The insertion point for D-003 is between
  205 (end of §4) and 207 (start of §5).
- [ ] **Step 0.4.** Run `git diff main...HEAD` and confirm zero
  delta on the three target files. The feature branch was created off
  `origin/main` per `bin/run-local.sh::ensure_worktree`; any pre-existing
  delta means a stale worktree (escalate via `verdict halt --reason
  agent-blocked`).

### Task 1: D-001 — `AGENT_PROMPTS.md` §7 *Merge strategy* edit

- `depends_on: [0]`
- `touches: AGENT_PROMPTS.md`

- [ ] **Step 1.1.** Use the Edit tool to replace lines 1387-1400 (the
  current 14-line *Merge strategy* block) with the following 25-line
  block. The `old_string` must be the EXACT contents of A-001's
  current shape; the `new_string` is:

      Merge strategy (FIXED — no alternative; per ENG-13 D-008, ENG-83):
        - First derive the canonical <owner>/<repo> string for the --repo flag:
            gh pr view <N> --json url --jq '.url | split("/")[3:5] | join("/")'
          Capture the result (e.g. "StupiDeity/twinning-harness"). Substitute
          it as a literal in the next command — do NOT use $(...) shell
          substitution; the allowlist matcher rejects $(...) and backticks
          inside Bash arguments (per the secret-handling preamble above).
        - Then merge:
            gh pr merge <N> --repo <derived-owner-repo> --merge --auto \
              --delete-branch -t "<conventional-title>" -b "<body>"
          where <conventional-title> is the PR title (P7 ensures it is
          conventional-commits formatted) and <derived-owner-repo> is the
          literal value captured in the previous step.
        - The `--repo` flag is MANDATORY (ENG-83). Without it, gh CLI's
          post-merge local cleanup runs `git checkout main` to delete the
          source branch; that errors with "fatal: 'main' is already used by
          worktree at '/Users/<user>/code/<project>'" because the operator's
          main checkout already holds main as a worktree, blocking the gh
          invocation before the server-side merge fires. With `--repo`, gh
          treats the operation as cross-repo and skips the local cleanup
          attempt; the server-side merge fires unconditionally and the
          `--delete-branch` removes the remote ref via the API. Local
          worktree cleanup is owned by the periodic `cleanup-worktrees.sh`
          sweep; it is NOT this agent's job.
        - Use `--merge` (regular merge commit), NOT `--squash`. Regular
          merges preserve feature-branch history reachable from main via the
          merge commit's second parent, which is load-bearing for
          retrospective archaeology (`git log --all` queries).
        - `--auto` queues the merge to fire once required checks pass (P5)
          AND a human Code Owner has approved (P2 strengthened).
        - `--delete-branch` removes `{branch_name}` from origin post-merge.
          The periodic `cleanup-worktrees.sh` sweep detects the merged state
          and removes the local worktree on a subsequent tick.
        - Do NOT perform any worktree cleanup here — it is centralized in
          the sweep for uniformity.

  Indentation: the block is rendered inside §7's outer fence (which
  opens at A-003's line 1238). Each bullet is 2-space-indent under
  `Merge strategy (FIXED ...):`; sub-items are 4-space-indent. No
  column-0 triple-backtick fences inside the block (per A-016).
- [ ] **Step 1.2.** Confirm the edit landed: run `grep -nF '--repo
  <derived-owner-repo>' AGENT_PROMPTS.md` and expect exactly one hit
  in the §7 *Merge strategy* block.
- [ ] **Step 1.3.** Confirm fence count: run `awk '/^```/ && /## 7\./
  {found=1} /^## 8\./{exit} found{c+=/^```/ ? 1 : 0} END{print c}'
  AGENT_PROMPTS.md` and expect output `2` (one open + one close fence
  in §7). If the count is not 2, the edit accidentally introduced a
  column-0 fence — undo and re-apply with strict 4-space indentation
  on the bash snippets.
- [ ] **Step 1.4.** Run `bash bin/render-prompt.sh ENG-83 building`
  (dry-render) and confirm exit 0. (The script fails with a clear
  error if the §7 fence count is wrong; this is the canonical sanity
  check.)

### Task 2: D-002 — `bin/agent-prompts-content-test.sh` four new asserts

- `depends_on: [0]`
- `touches: bin/agent-prompts-content-test.sh`

- [ ] **Step 2.1.** Use the Edit tool to insert the following block
  IMMEDIATELY AFTER the existing ENG-71 §7 chained-command pin (after
  line 655's closing `fi`) and BEFORE the next pre-existing comment
  block at line 657 (`# ENG-71 C1 regression pin`). The `old_string`
  for the Edit should be the unambiguous boundary text (e.g., the
  closing `fi` of the chained-command pin plus the next blank line and
  the start of the C1 regression comment). The `new_string` adds the
  block in between:

      # ─── ENG-83: §7 build agent merge command must include --repo flag ────
      # Without --repo, gh CLI's post-merge local cleanup tries `git checkout
      # main` and errors when the operator's main checkout already holds main
      # as a worktree (the canonical operator setup; see
      # docs/runbooks/operator-mental-model.md §4). Pin the rule + rationale
      # so a future "cleanup" pass can't strip the unfamiliar flag without
      # context. Mirrors the ENG-71 §7 pin shape above.

      # Positive: §7 names --repo on the gh pr merge command line.
      if printf '%s\n' "$s7" | grep -qE 'gh pr merge.*--repo'; then
        ok "§7 names --repo flag on gh pr merge invocation"
      else
        nope "§7 names --repo flag on gh pr merge invocation" \
          "without --repo, gh's local cleanup errors against the operator's main worktree (ENG-83)"
      fi

      # Positive: §7 explains the rationale (worktree-locks-main).
      if printf '%s\n' "$s7" | grep -qE 'main is already used by worktree|local cleanup'; then
        ok "§7 explains --repo rationale (worktree-locks-main / local cleanup)"
      else
        nope "§7 explains --repo rationale" \
          "rationale paragraph missing — a future cleanup pass might strip --repo without realising"
      fi

      # Negative: §7 must NOT contain a $(gh pr view ...) shape — the
      # allowlist matcher rejects $() in Bash arguments (per ENG-83 §1
      # and the secret-handling preamble above).
      if printf '%s\n' "$s7" | grep -qE 'repo_full="\$\(gh|--repo "\$\(gh'; then
        nope "§7 lacks \$(gh ...) shell-substitution shape" \
          "allowlist matcher rejects \$() in Bash arguments — agent must derive in two separate tool calls (ENG-83)"
      else
        ok "§7 lacks \$(gh ...) shell-substitution shape (allowlist-safe)"
      fi

      # Positive: §7 instructs the two-step derivation (gh pr view first,
      # then gh pr merge with the literal). Pin the canonical command form.
      if printf '%s\n' "$s7" | grep -qF 'gh pr view <N> --json url'; then
        ok "§7 names canonical owner/repo derivation (gh pr view --json url)"
      else
        nope "§7 names canonical owner/repo derivation" \
          "without the --json url derivation, the agent has no allowlist-safe path to compute <owner>/<repo>"
      fi

  Indentation: 0 column for the comment header, 0 column for the `if`
  / `else` / `fi` lines. No tabs; spaces only (matching the existing
  style — see lines 633-655's indentation). The four blocks are
  separated by single blank lines, mirroring the existing ENG-71 §7
  pin structure.
- [ ] **Step 2.2.** Run `bash -n bin/agent-prompts-content-test.sh`
  and confirm exit 0 (syntactic check; required after any
  bash-source edit).
- [ ] **Step 2.3.** Run `bash bin/agent-prompts-content-test.sh` and
  confirm exit 0 with all four new asserts in `OK:` lines (no `FAIL:`
  lines for any ENG-83 assert). The total `RESULTS:` line should
  show four more `passed` than the pre-edit baseline (the four new
  positive/positive/negative/positive asserts each add one to PASS;
  none are expected to FAIL given Task 1's prompt edit).
- [ ] **Step 2.4.** Confirm pre-existing assert count is unchanged:
  the `RESULTS:` line's `failed` count must remain 0 (no other
  asserts regressed; the §7 prompt edit from Task 1 should not break
  any pre-existing pin — in particular the ENG-71 worktree-HEAD rule
  paragraph at line 1245 is untouched, so the four `git checkout` /
  `git switch` / `git pull` / `git reset` for-loop pins still pass).

### Task 3: D-003 — `docs/runbooks/operator-mental-model.md` §4 paragraph

- `depends_on: [0]`
- `touches: docs/runbooks/operator-mental-model.md`

- [ ] **Step 3.1.** Use the Edit tool to insert the following ~12-line
  paragraph between the end of §4's `core.bare=true` paragraph (which
  closes at line 205 with the indented snippet `git -C
  /path/to/twinning-harness config core.bare false` inside a fenced
  block, then a closing ` ``` ` on line 205) and the `## §5 — Process
  / runtime` heading at line 207. The `old_string` for the Edit should
  span the closing ` ``` ` of the §4 final fenced block plus the blank
  line at 206 plus the `## §5` heading at 207, ensuring a unique match.
  The `new_string` adds the paragraph in between, preserving the
  blank-line discriminator and the §5 heading:

      **Build agent's `gh pr merge` always carries `--repo <owner>/<repo>`.**
      Without `--repo`, gh's `--delete-branch` post-merge cleanup runs `git
      checkout main` to delete the source branch locally; that errors with
      "fatal: 'main' is already used by worktree at ..." because the
      operator's main checkout in `~/code/<project>` already holds main as
      a worktree. With `--repo`, gh treats the operation as cross-repo and
      skips the local cleanup; the server-side merge fires unconditionally,
      and `cleanup-worktrees.sh` handles the local worktree removal on a
      subsequent tick. Operators reviewing build-stage Linear comments will
      see `--repo <owner>/<repo>` in the merge command — that is by design
      (ENG-83), not a debug artifact. Pinned in §7 of `AGENT_PROMPTS.md`
      and `bin/agent-prompts-content-test.sh`.

  Indentation: 0 column (matches §4's existing prose style). No new
  fenced code blocks. The bold-leading-sentence form mirrors the
  existing §4 paragraphs (`**Worktree branch MUST match...**`,
  `**`core.bare=true` flips occur mysteriously...**`).
- [ ] **Step 3.2.** Confirm the insertion preserved §5's heading: run
  `grep -nF '## §5 — Process / runtime'
  docs/runbooks/operator-mental-model.md` and expect exactly one
  match at the new line ~219 (after the ~12-line paragraph insert).
- [ ] **Step 3.3.** Confirm no markdown structural regression: run
  `grep -cE '^## §' docs/runbooks/operator-mental-model.md` and
  expect the same count as before the edit (the file's section count
  is unchanged; D-003 only ADDS prose to §4, does not split or
  rename sections).

### Task 4: Run the full test gate

- `depends_on: [1, 2, 3]`
- `touches: (verification only — no file edits)`

- [ ] **Step 4.1 — Syntactic checks.** Run:
  ```
  bash -n bin/agent-prompts-content-test.sh
  ```
  Must exit 0. (`AGENT_PROMPTS.md` and `docs/runbooks/operator-mental-
  model.md` are not bash; no `bash -n` applicable.)
- [ ] **Step 4.2 — Direct test invocation.** Run:
  ```
  bash bin/agent-prompts-content-test.sh
  ```
  Must exit 0 with `RESULTS: <N+4> passed, 0 failed` where `<N>` is
  the pre-edit `passed` count. The four new ENG-83 asserts appear as
  `OK:` lines.
- [ ] **Step 4.3 — Render-prompt smoke check.** Run:
  ```
  bash bin/render-prompt-test.sh
  ```
  Must exit 0. (The §7 fenced-block contract is enforced by
  `render-prompt.sh::section_body`; if Task 1 introduced a column-0
  fence, this test fails. Task 1.3's awk-based fence-count check is
  the proximate guard, but `render-prompt-test.sh` is the canonical
  end-to-end coverage.)
- [ ] **Step 4.4 — Pre-commit hook end-to-end.** Run:
  ```
  bash .githooks/pre-commit
  ```
  Must exit 0. The hook runs the full `bin/*-test.sh` suite (~30 s);
  `agent-prompts-content-test.sh` is in the suite (A-015) and is NOT
  in the `KNOWN_BROKEN` allowlist, so it must pass.
- [ ] **Step 4.5 — Secret-probe lint.** Run:
  ```
  bash bin/secret-probe-lint.sh
  ```
  Must exit 0. ENG-83's edits reference no secret-shaped env var
  (`<owner>/<repo>` is a public identifier; the brainstorm §11
  Security persona PASS confirmed this).
- [ ] **Step 4.6 — Diff hygiene.** Run:
  ```
  git diff main...HEAD --stat
  ```
  Must show exactly four files changed:
  `AGENT_PROMPTS.md`, `bin/agent-prompts-content-test.sh`,
  `docs/runbooks/operator-mental-model.md`, and
  `docs/plans/2026-05-09-eng-83-...md` (the plan doc itself, written
  at planning exit). No other paths. If any other paths appear, the
  agent has introduced churn — investigate and revert before
  committing.

### Task 5: Stage commit + summary

- `depends_on: [4]`
- `touches: (commit only); $PROJECT_STATE_DIR/ENG-83/stage-summary-implementing.md`

- [ ] **Step 5.1.** Confirm `git status --porcelain` shows only the
  three target files plus the plan doc as modified/added (no untracked
  `.review-body.md` / `.qa-pr-comment.md` scratch files, per the §7
  preamble's prohibition against worktree-root scratch files).
- [ ] **Step 5.2.** Stage the three modified files via `git add
  AGENT_PROMPTS.md bin/agent-prompts-content-test.sh
  docs/runbooks/operator-mental-model.md`. The plan doc was staged at
  planning-stage exit by the orchestrator's commit (
  `chore(pipeline): plan for ENG-83`).
- [ ] **Step 5.3.** Commit with message
  `fix(ENG-83): build §7 gh pr merge --repo flag + content-test pin + runbook note`.
  The pre-commit hook re-runs the full suite. If the commit fails
  hook-side, fix the underlying issue per CLAUDE.md's "Git Safety
  Protocol" (do NOT amend; create a NEW commit after fix).
- [ ] **Step 5.4 — Implement agent stage summary.** Write the
  implement-stage summary file to
  `$PROJECT_STATE_DIR/ENG-83/stage-summary-implementing.md` per the
  CLAUDE.md "Per-issue state directory" § convention. Body should
  state: "ENG-83: §7 *Merge strategy* gains `--repo` derivation and
  rationale (D-001); content-test pins added (D-002, four asserts);
  operator runbook §4 paragraph added (D-003). Test gate green."

## Frontend Tasks

No UI surface; the harness has no frontend (per the project profile
addendum: "The repo contains no application code"). **No frontend
tasks.**

## Failure Mode → Test Map

Pulled from brainstorm §7 (Error handling) and §8 (Edge cases). Each
row binds to a concrete test layer + test name. Behavioral coverage
of the agent's actual `gh pr merge` invocation is empirically
exercised on every build-stage tick (no synthetic test fixture); the
content-test asserts are the durable regression guards.

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
|---|---|---|---|---|
| `--repo` flag stripped from §7 *Merge strategy* block (future "cleanup" pass) | Edit removes `--repo <derived-owner-repo>` from the gh pr merge example | `bin/agent-prompts-content-test.sh` first ENG-83 assert (positive grep on `gh pr merge.*--repo`) fails; pre-commit hook fails | unit | `bin/agent-prompts-content-test.sh` ENG-83 assert 1 (positive `gh pr merge.*--repo`) |
| Rationale paragraph stripped from §7 (the `worktree-locks-main` explanation) | Edit removes the rationale prose without removing `--repo` | `bin/agent-prompts-content-test.sh` second ENG-83 assert (positive grep on `main is already used by worktree\|local cleanup`) fails | unit | `bin/agent-prompts-content-test.sh` ENG-83 assert 2 (rationale grep) |
| Allowlist-unsafe `$(gh pr view ...)` shell-substitution shape introduced into §7 | Edit re-writes the derivation as `--repo "$(gh pr view ...)"` (which would be rejected by the allowlist matcher per A-005) | `bin/agent-prompts-content-test.sh` third ENG-83 assert (negative grep) fails; pre-commit hook fails | unit | `bin/agent-prompts-content-test.sh` ENG-83 assert 3 (negative `$(gh` grep) |
| Canonical `gh pr view <N> --json url` derivation form removed (replaced with hard-coded value or alternative `--json` field) | Edit replaces the derivation with `--json baseRepository` or hardcoded `<owner>/<repo>` | `bin/agent-prompts-content-test.sh` fourth ENG-83 assert (positive grep on `gh pr view <N> --json url`) fails | unit | `bin/agent-prompts-content-test.sh` ENG-83 assert 4 (canonical-derivation grep) |
| `gh pr view <N> --json url` returns malformed URL | Network glitch / GHE deployment with non-standard URL shape | T1's jq filter returns empty; T2 fails with `gh: invalid repository format`; agent emits `verdict halt --reason agent-blocked` | smoke | `bash bin/agent-prompts-content-test.sh` (canonical-derivation pin); behavioral path documented in brainstorm §7 / §8 E-2 / E-3, not synthetically tested |
| `gh pr merge --repo <X>` API rejects merge (concurrent merge by another actor; mid-tick approval revocation) | External GitHub state change between P-precondition check and merge invocation | Existing P0/P1/P3/P4 paths handle re-classification on next dispatch; P0 catches `state == MERGED` (idempotent skip); no new failure mode introduced | smoke | covered by existing P0/P1/P3/P4 verifications in §7 (no new test) |
| `gh pr merge --repo <X> --delete-branch` skips remote branch deletion | gh CLI behavior change (regression in cross-repo `--delete-branch`) | Stale remote branch ref persists; `cleanup-worktrees.sh` does NOT clean remote branches (only local worktrees); brainstorm §"Assumption inventory" flags this as `[assumed]` and worth empirical confirmation on first ENG-83 implementation tick | n/a | empirical confirmation post-merge (inspect first build using new prompt rule); no automated test |
| Single-checkout operator (no `~/code/<project>` main checkout) hits the new prompt rule | Operator without the canonical multi-checkout setup runs the build stage | `--repo` becomes a harmless no-op; gh's local cleanup would have succeeded anyway (no worktree collision); merge fires; no operator-visible difference | n/a | brainstorm §8 E-7 documents; no test required (rule remains correct in this setup) |
| `partition_dirty_paths` rejects the plan doc as out-of-scope | Plan doc filename does not contain the issue identifier | Plan doc rejected; partition fires self-leak; breaker trips | unit | covered by `partition_dirty_paths::D-004` (basename-token check); plan doc filename `2026-05-09-eng-83-...` carries `eng-83` per A-014 — bucketed in-scope |
| §7 fenced-block boundary broken by Task 1's edit (column-0 ` ``` ` accidentally introduced) | Task 1 edit indents incorrectly | `bin/render-prompt.sh::section_body` extractor sees fence count != 2; render dies; `bin/render-prompt-test.sh` exits non-zero | smoke | `bash bin/render-prompt-test.sh` (Task 4.3); also `awk` fence-count check at Task 1.3 |
| Pre-commit hook lag — content test exists but `.githooks/pre-commit` not active | Operator forgot `bash bin/install-git-hooks.sh` on a fresh clone | Standard install path documented in CLAUDE.md; manual `bash bin/agent-prompts-content-test.sh` exercise still works | n/a | not a code change |

## Test Strategy

### Unit / content tests (D-002)

The four new `bin/agent-prompts-content-test.sh` asserts (Task 2)
are the primary regression guard. Together they pin:

1. **Positive (assert 1):** `grep -qE 'gh pr merge.*--repo'` — the
   `--repo` flag is named on the gh pr merge command.
2. **Positive (assert 2):** `grep -qE 'main is already used by
   worktree|local cleanup'` — the rationale phrase is present.
3. **Negative (assert 3):** `grep -qE 'repo_full="\$\(gh|--repo "\$\(gh'`
   — the allowlist-unsafe `$(gh ...)` shape is absent.
4. **Positive (assert 4):** `grep -qF 'gh pr view <N> --json url'` —
   the canonical derivation form is named.

The four-grep approach catches every plausible regression vector:
flag-strip, rationale-strip, allowlist-unsafe-substitution, alternative
derivation form. The asserts run on every commit via `.githooks/pre-commit`
and on every dispatch via the test gate (Task 4).

### Sibling tests (existing, untouched)

- `bin/agent-prompts-content-test.sh:633-655` (existing ENG-71 §7
  pin) — unaffected. The §7 prompt edit (Task 1) does not modify the
  ENG-71 worktree-HEAD rule paragraph at line 1245 (verified at
  A-006); the four ENG-71 grep cases (3 fixed strings + 1 chained-command
  worked example) all continue to pass.
- `bin/agent-prompts-content-test.sh:447-491` (PR #48's prompt-side
  rejection-of-`feature/`) — unaffected. The §7 *Merge strategy*
  block does not contain the `feature/` literal; D-001's text uses
  `{branch_name}` (the canonical token) and `<derived-owner-repo>`
  (a placeholder, not a literal branch).
- `bin/render-prompt-test.sh` — unaffected. The §7 fence count is
  preserved (Task 1.3's awk check + Task 4.3's end-to-end smoke).
  No template-token additions (per A-013), so the substitution
  table is unchanged.

### Smoke (syntactic) tests

- `bash -n bin/agent-prompts-content-test.sh` (Task 4.1) confirms
  the file remains valid bash after Task 2's insert.
- `bash bin/render-prompt-test.sh` (Task 4.3) confirms the §7
  fence contract is preserved after Task 1's prompt edit.

### Pre-commit / regression gate

- `bash .githooks/pre-commit` (Task 4.4) runs the full
  `bin/*-test.sh` suite end-to-end, including the four new ENG-83
  asserts. ~30 s walltime. This is the canonical gate.
- `bash bin/secret-probe-lint.sh` (Task 4.5) confirms no
  secret-shaped env var is referenced (none expected).

### Adversarial / E2E coverage (deferred)

- **`gh pr merge --repo <X> --delete-branch` actually deletes the
  remote branch.** Brainstorm §"Assumption inventory" `[assumed]`
  row, worth empirical confirmation on the first post-ENG-83 build.
  No synthetic test (would require live GitHub state). The
  retrospective agent's weekly aggregation will surface any
  anomalous "remote branch persisted post-merge" pattern via metric
  events.
- **Cross-stage audit** of `gh pr comment`, `gh pr edit`, `gh pr
  close`, `gh release create` for similar local-cleanup-vs-worktree
  collisions. Brainstorm §10 O-5 defers to a future audit; not
  exercised by this ticket.
- **Behavioral test of agent's actual two-call derivation** in a
  sandboxed `claude -p` invocation. Out of scope per the issue's
  "no `bin/` code change" framing; production builds (every ENG-N
  tick that reaches the build stage) exercise the path empirically.

### Test gate (committed to in §"Goal")

```
bash bin/agent-prompts-content-test.sh \
  && bash bin/secret-probe-lint.sh \
  && bash .githooks/pre-commit
```

The pre-commit hook (`bash .githooks/pre-commit`) is a strict superset
of the first two commands and is the canonical run-it-all gate.

## Self-review summary (5 personas)

Five personas dispatched against this plan: feasibility, scope,
coherence, design, product.

### Iteration 1

| Persona | Verdict | P0 | P1 |
|---|---|---|---|
| feasibility | PASS | 0 | 1 |
| scope | PASS | 0 | 0 |
| coherence | PASS | 0 | 0 |
| design | PASS | 0 | 0 |
| product | PASS | 0 | 1 |

**Status:** Personas: 5/5 PASS · gate P0: 0 · proceeding to implementing.

Gate criterion (≥4/5 PASS, zero P0) cleared at iteration 1. P1
advisories below are recorded for transparency; none rise to a
blocking concern.

The brainstorm carried 6/6 PASS at iteration 1 with no unresolved P0;
this plan is a faithful crystallisation of brainstorm §4 decisions
D-001 / D-002 / D-003. All codebase-fact assumptions re-verified
against the current worktree at the time of plan-writing (see
Assumption Inventory A-001 through A-019).

Persona findings:

- **feasibility (PASS, 0 P0, 1 P1).** All 19 modified-file assumptions
  (A-001 through A-019) `path:line`-cited against current code. The
  `depends_on` graph is correct: Task 0 is read-only baseline; Tasks
  1, 2, 3 each touch a different file and can run in parallel after
  Task 0; Task 4 verifies all three; Task 5 is the commit + summary.
  Every Failure Mode → Test Map row names a concrete test layer and
  test name (asserts 1-4 cover the four most common regression
  vectors).
  - **P1 (recorded):** Failure-mode row 7 ("`gh pr merge --repo <X>
    --delete-branch` skips remote branch deletion") flags this as
    `[assumed]` per the brainstorm — the assertion that `--repo`
    preserves `--delete-branch`'s remote-API behavior is empirically
    supported by ENG-77's PR #67 (which DID get its remote branch
    deleted post-merge per the operator monitoring record cited in
    brainstorm §"Assumption inventory") but not formally documented
    in gh CLI man pages. If a future gh release regresses this
    behavior, the harness would silently leave stale remote refs
    (cleaned up by `cleanup-worktrees.sh`'s pruning logic on a
    subsequent tick if the sweep is configured for remote-prune;
    currently the sweep cleans only local worktrees per CLAUDE.md
    "Per-issue state directory" §). Recorded as a future hardening
    note; out of scope for this ticket.

- **scope (PASS, 0 P0, 0 P1).** Every File Structure entry traces
  back to brainstorm decisions D-001 / D-002 / D-003 cleanly. No
  gold-plating: no new `learned-rules/` file (deferred to retrospective),
  no `bin/dispatch.sh` allowlist additions (already complete per
  A-004), no `bin/render-prompt.sh` token injection (deferred per
  O-1), no transcript-based assertion (deferred per O-3). The plan
  respects the issue's "AGENT_PROMPTS.md §7 prompt edit only (no
  `bin/` code change)" framing — the `bin/agent-prompts-content-test.sh`
  edit is a *content test* asserting on `AGENT_PROMPTS.md`, not a
  code change to `bin/` orchestration logic. The runbook addition
  is doc, not code.

- **coherence (PASS, 0 P0, 0 P1).** Plan Goal §1-§4 mirrors brainstorm
  Decisions D-001 / D-002 / D-003 (with §4 adding the test-gate
  green criterion as a cross-cutting verification). Backend Tasks
  1-3 each realize one decision; Task 0 is a defensive baseline
  check; Task 4 runs the test gate; Task 5 commits and writes the
  stage summary. Failure Mode → Test Map covers every brainstorm
  edge-case row that has a concrete test surface (E-1 / E-2 / E-3 /
  E-7 noted as documentation rather than tests, consistent with
  brainstorm §8). The `gh pr view --json url --jq '.url |
  split("/")[3:5] | join("/")'` form is used consistently across
  Goal, Tasks, and Failure Mode rows — no drift.

- **design (PASS, 0 P0, 0 P1).** No new abstractions, no new
  dependencies, no new exit codes, no new lane fences, no new
  metric events, no new comment shapes. The three-layer pattern
  (prompt / test / runbook) follows the established ENG-71 / ENG-79
  / ENG-62 precedent for "codify a discovered workaround into the
  prompt + pin via content test + document operator-side
  weirdness." The plan respects crate boundaries (there are no
  crate boundaries in this bash project; the analogous discipline
  is the source-and-stub testing pattern, which D-002 follows by
  reusing the existing `s7` extractor and `ok`/`nope` helpers).

- **product (PASS, 0 P0, 1 P1).** The plan delivers exactly what
  the issue asked for: the build agent's `gh pr merge` invocation
  carries `--repo <owner>/<repo>` to bypass the local-cleanup
  worktree collision. Operator-visible: a slightly longer merge
  command in build-stage Linear comments (one extra flag); D-003's
  runbook paragraph documents this. Build-agent-visible: the
  workaround is documented, not rediscovered each time (saving
  ~1-2 min of reasoning + one wasted `gh pr merge` attempt per
  build, per brainstorm §11 product persona). Future-stricter-agent-
  visible: agents that fail-closed on the local-cleanup error (vs.
  reasoning through to the workaround) will follow the prompt rule
  and skip the failure mode.
  - **P1 (recorded):** Brainstorm §10 O-2 flags an unresolved
    timing question: does the `gh pr merge` (without `--repo`) call
    fire the API merge BEFORE or AFTER the local-cleanup error? The
    issue body asserts "before"; the operator monitoring record is
    ambiguous. Either way, the `--repo` fix is correct
    (preventatively skips the local cleanup), but the timing
    matters for understanding the failure mode precisely. Not a
    blocker; recorded for future investigation if a regression
    surfaces.

No P0 findings across any persona. Personas: 5/5 PASS · gate P0: 0
· proceeding to implementing.
