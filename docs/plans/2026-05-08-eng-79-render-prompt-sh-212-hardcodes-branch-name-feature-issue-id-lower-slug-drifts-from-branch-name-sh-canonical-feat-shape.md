---
linear: ENG-79
date: 2026-05-08
topic: render-prompt.sh sources branch-name.sh; back-fill plan for an already-merged fix (commit 7772687, PR #65)
---

# Plan — ENG-79 `render-prompt.sh` must source `branch-name.sh`, not hand-roll `feature/<lower>-<slug>`

Implementation plan for the design at
`docs/brainstorms/2026-05-08-eng-79-render-prompt-sh-212-hardcodes-branch-name-feature-issue-id-lower-slug-drifts-from-branch-name-sh-canonical-feat-shape-design.md`.

## Anti-anchoring check

- **Problem (operator's words).** `bin/render-prompt.sh:212` hand-rolled
  `branch_name="feature/${issue_id_lower}-${slug}"` while the canonical
  resolver `bin/branch-name.sh:31` emits `feat/eng-N-<slug>` for
  Feature/Improvement issues and `fix/eng-N-<slug>` for Bug issues. Pre-ENG-67,
  the orchestrator's legacy `feature/*` coexistence path silently
  accommodated the drift; post-ENG-67 the `{branch_name}` interpolation
  cannot match the actual checked-out branch. ENG-74 (May 2026) was the
  documented production failure — a build-stage agent ran
  `gh pr list --head feature/eng-74-…`, got an empty result, and emitted
  `verdict halt reason=agent-blocked` for a satisfied P1 precondition.
- **Brainstorm addresses it?** Yes. D-001 replaces the hand-rolled
  formation with `bash "$SCRIPT_DIR/branch-name.sh" "$issue_id"`; D-002
  adds `[[ -n "$branch_name" ]] || die …`; D-003 adds a positive grep
  (resolver-call present) and a negative grep (no `feature/${issue_id_lower}`
  literal) to `bin/render-prompt-test.sh`.
- **Proportional?** Yes. ~3 functional bash lines + 12-line citation
  comment + ~25 test lines. No new files, no new dependencies, no new
  exit codes, no new comment shapes, no new `dispatch.sh::allowed_tools_for`
  cases, no new `bin/pipeline-events.json` entries, no new
  `learned-rules/` file, no `AGENT_PROMPTS.md` edit.
- **Already-shipped flag (brainstorm §10 O-1).** The fix is already in
  the tree at commit `7772687` ("fix(eng-79): render-prompt.sh sources
  branch-name.sh — `feat/` not `feature/`"), merged via PR #65 (commit
  `c1d3e4e`). Verified: `git log -- bin/render-prompt.sh` shows `7772687`
  as the most recent change; `bin/render-prompt.sh:212-226` carries the
  resolver call + `die` guard; `bin/render-prompt-test.sh:128-153`
  carries both ENG-79 grep cases. The brainstorm itself flags this in
  §10 O-1 and recommends "let the pipeline run through the remaining
  stages as no-ops on a clean tree." This plan commits to that path:
  the implement stage's tasks are **verification-shaped** (re-confirm
  the in-tree code matches the brainstorm spec and the test gate
  passes), not implementation-shaped (no edits expected).
- **No reframe; no scope creep; no escalation. PROCEED with verification
  plan.**

## Goal

After the implement stage runs, the harness will have a tick-fresh
verification on the feature branch confirming:

1. **D-001 in tree.** `bin/render-prompt.sh` invokes
   `bash "$SCRIPT_DIR/branch-name.sh" "$issue_id"` (verified by `grep`),
   does NOT carry the literal `feature/${issue_id_lower}` (verified by
   `grep -F`), and the resolver call's stderr is suppressed via
   `2>/dev/null || printf ''` so the agent's transcript stays clean.
2. **D-002 in tree.** The `[[ -n "$branch_name" ]] || die …` guard
   immediately follows the resolver call, with a message naming both
   failure modes (Linear-API outage, bug-label resolution).
3. **D-003 in tree.** `bin/render-prompt-test.sh` ends with the ENG-79
   block (positive grep + negative grep), and `bash bin/render-prompt-test.sh`
   exits 0 with `7 PASS / 0 FAIL` (5 pre-existing case-6.x cases + 2 new
   ENG-79 cases).
4. **Full test gate green.** The pre-commit hook glob
   (`bash bin/*-test.sh`) exits 0; `bash -n bin/render-prompt.sh` exits 0;
   `bash bin/secret-probe-lint.sh` exits 0.

Verifiable by:

```
bash bin/render-prompt-test.sh \
  && bash -n bin/render-prompt.sh \
  && bash bin/secret-probe-lint.sh \
  && bash .githooks/pre-commit
```

exiting 0.

Out of scope (explicit per brainstorm §2 non-goals + §10 open questions):

- **O-1 — re-implementing the fix.** Already merged in `7772687`. If
  the implement agent's `git diff main...HEAD bin/render-prompt.sh`
  shows zero delta, that is the **expected** outcome. The agent
  confirms via verification, then exits with `verdict pass`. The agent
  MUST NOT introduce churn ("clean up" the comment, refactor the
  citation block, or re-shape the `die` message) — every such edit
  invalidates the existing PR-#65 review approval and forces a
  re-review for no functional gain.
- **O-2 — caching `branch-name.sh` resolution across the tick.**
  `bin/run-local.sh:230` and `bin/render-prompt.sh:224` both call
  `branch-name.sh` per tick; deduping is recorded as a deferred
  optimization in the brainstorm.
- **O-3 — empty-slug edge case.** `branch-name.sh:24`'s slugifier on
  an all-non-alphanumeric title produces `feat/eng-N-` (trailing
  hyphen). Pre-existing resolver-level edge case, not introduced by
  ENG-79.
- **O-4 — behavioral test of `render-prompt.sh::main` end-to-end.**
  Would require stubbing `linear.sh` and `branch-name.sh`. The
  content greps in D-003 catch the regression class at much lower
  cost; deferred.
- **Other `feature/`-shaped occurrences** in `bin/`. The brainstorm
  §2 non-goal block confirms there are none post-PR-#48 outside
  negative-rule pins; verified during plan-writing
  (`grep -n 'feature/' bin/render-prompt.sh` returns only comment
  lines 213, 216, 219, 221).
- **AGENT_PROMPTS.md edits.** No prompt change. The token
  `{branch_name}` interpolation contract is unchanged; only its
  *provenance* changed at the renderer layer.
- **Linear-API outage handling in `branch-name.sh`.** It already
  `die`s with `could not fetch title for ENG-N` at
  `bin/branch-name.sh:22`. ENG-79 D-002 only propagates that death.

## Architecture

This plan touches no files. `bin/render-prompt.sh` and
`bin/render-prompt-test.sh` are already in their post-ENG-79 shape on
`main`; the feature branch (this worktree's
`feat/eng-79-render-prompt-sh-…`) inherits that shape from `main` via
`ensure_worktree`'s third branch (worktree created off `origin/main`
per `bin/run-local.sh::ensure_worktree`).

The architectural pivot was: replace a hand-rolled `feature/...`
formation with a sourced canonical resolver call. The same single-
source-of-truth pattern that ENG-67 enforced at the orchestrator layer
(`bin/run-local.sh:230`) and that PR #48 enforced at the prompt layer
(`AGENT_PROMPTS.md:77-88` + `bin/agent-prompts-content-test.sh:447-491`)
is now also enforced at the renderer layer
(`bin/render-prompt.sh:224-226` + `bin/render-prompt-test.sh:141-153`).
Three layers, three independent grep-based content-tests.

There is no `docs/VISION.md`, no `docs/ARCHITECTURE.md`, no
`docs/knowledge/decisions.md` (verified: `ls docs/` returns
`brainstorms/  pipeline-vocabulary.md  pipeline-vocabulary.template.md
plans/  runbooks/`; no `knowledge/` subdir). Governing constraints
come from `CLAUDE.md` and `learned-rules/harness/{project-profile,build}.md`
(verified at `learned-rules/harness/`: only `build.md` and
`project-profile.md` exist; no `plan.md`).

## Tech stack

- Bash 3.2+ (Darwin default).
- POSIX `grep -qE` (extended regex) for the positive resolver-call pin
  at `bin/render-prompt-test.sh:141`; `grep -qF` (literal) for the
  negative `feature/${issue_id_lower}` pin at line 148.
- `bin/common.sh::die` (lines 34-37) — the canonical fatal-exit helper.
- `bin/branch-name.sh` (existing) — the canonical resolver.
- No new dependencies. No new `dispatch.sh::allowed_tools_for` cases.
  No new metric event names. No new `bin/pipeline-events.json` entries.
  No new `learned-rules/` file.

## Assumption Inventory

Every modified-file fact below is `path:line`-cited against the current
worktree per the codebase-fact verification mandate (learned-rules/twinning/plan.md
P-001 / P-002).

### Files touched in this plan: NONE

This plan is a verification back-fill (per brainstorm §10 O-1 / §"Anti-anchoring
check" above). The implement stage performs grep-based confirmation that the
in-tree code already matches the brainstorm's D-001/D-002/D-003 spec, runs the
test gate, and exits with `verdict pass`. No files are edited.

### Modified-file facts — current state, signatures, and verification points

- **A-001 — `bin/render-prompt.sh:212-226` carries the post-ENG-79
  comment block + resolver call + `die` guard.** Verified by direct
  read on the worktree (which is checked out off `feat/eng-79-…`,
  inheriting the post-fix state from `main` via the post-ENG-67
  worktree-creation path). Concrete current shape:
  ```bash
  # ENG-79: source the canonical branch-name resolver instead of hand-rolling
  # the form `feature/<lower>-<slug>`. The hand-rolled form drifted from
  # `bin/branch-name.sh:31` (which emits `feat/eng-N-…` for Feature/Improvement
  # issues and `fix/eng-N-…` for Bug issues, per AGENT_PROMPTS.md "Branch-name
  # convention"). Pre-ENG-67, the orchestrator's legacy `feature/*` coexistence
  # path silently accommodated the drift; post-ENG-67 the orchestrator strictly
  # uses `feat/...`, so the prompt's interpolated `{branch_name}` value
  # (`feature/...`) cannot match the actual checked-out branch. ENG-74 (May 2026)
  # demonstrated the failure: a build-stage agent ran
  # `gh pr list --head feature/eng-74-…` from the prompt interpolation, got an
  # empty result, and emitted `verdict halt reason=agent-blocked` for P1 even
  # though PR was open on canonical `feat/eng-74-…`.
  branch_name="$(bash "$SCRIPT_DIR/branch-name.sh" "$issue_id" 2>/dev/null || printf '')"
  [[ -n "$branch_name" ]] \
    || die "render-prompt: branch-name.sh returned empty for $issue_id (Linear-API outage or bug-label resolution failed). Cannot render prompt without a canonical branch name."
  ```
  Comment header at lines 212-223; resolver call at line 224;
  guard at lines 225-226. The `2>/dev/null || printf ''` pair
  intentionally suppresses the resolver's `die` message so it doesn't
  pollute the dispatcher transcript; D-002's explicit emptiness check
  owns the failure-message wording.

- **A-002 — `bin/render-prompt.sh:224` resolver-call shape matches the
  D-003 positive grep regex.** Verified. The grep at
  `bin/render-prompt-test.sh:141` is:
  ```bash
  grep -qE 'bash[^|]*"\$SCRIPT_DIR/branch-name\.sh"[[:space:]]+"\$issue_id"' "$RP_SRC"
  ```
  The line in question reads
  `branch_name="$(bash "$SCRIPT_DIR/branch-name.sh" "$issue_id" 2>/dev/null || printf '')"`,
  which contains the substring
  `bash "$SCRIPT_DIR/branch-name.sh" "$issue_id"`
  — matching the regex. ✅

- **A-003 — `bin/render-prompt.sh` does NOT carry a literal
  `feature/${issue_id_lower}` token.** Verified by `grep -F` against
  the file: no match. The four `feature/`-shaped occurrences at
  lines 213, 216, 219, 221 are inside the citation comment block
  (which starts with `#`), not the literal D-003 negative-grep token.
  ✅

- **A-004 — `bin/render-prompt.sh:230-252` — Python interpolation
  step substitutes `{branch_name}` for `branch_name`.** Verified.
  Concrete shape at lines 246-247:
  ```python
  repl = {
    ...
    "{branch_name}": branch_name,
    ...
  }
  ```
  The `branch_name` Python local is the 10th positional argv element
  (index 9), populated from the bash `branch_name` variable resolved
  at line 224. Sed fallback at line 262: `-e "s|{branch_name}|$branch_name|g"`.
  No code change.

- **A-005 — `bin/render-prompt-test.sh:128-153` carries the ENG-79
  test block.** Verified. Concrete shape:
  ```bash
  # ─── ENG-79: render-prompt.sh sources branch-name.sh; no `feature/` literal ──
  # [12-line citation comment]
  RP_SRC="$SCRIPT_DIR/render-prompt.sh"

  if grep -qE 'bash[^|]*"\$SCRIPT_DIR/branch-name\.sh"[[:space:]]+"\$issue_id"' "$RP_SRC"; then
    pass_at 'ENG-79: render-prompt.sh resolves branch_name via bin/branch-name.sh'
  else
    fail_at 'ENG-79: render-prompt.sh resolves branch_name via bin/branch-name.sh' \
      'no `bash $SCRIPT_DIR/branch-name.sh "$issue_id"` invocation found'
  fi

  if grep -qF 'feature/${issue_id_lower}' "$RP_SRC"; then
    fail_at 'ENG-79: render-prompt.sh has no `feature/${issue_id_lower}` literal' \
      'pre-ENG-79 hand-rolled form is back'
  else
    pass_at 'ENG-79: render-prompt.sh has no `feature/${issue_id_lower}` literal'
  fi
  ```
  Section header at line 128; positive grep test at lines 141-146;
  negative grep test at lines 148-153; summary block at lines 155-158
  (with `[[ "$FAIL" -eq 0 ]] || exit 1`).

- **A-006 — `bin/render-prompt-test.sh` reports 7 PASS / 0 FAIL
  post-ENG-79.** The 5 pre-existing cases (6.1 through 6.5 covering
  profile-addendum behavior at lines 70-126) plus the 2 new ENG-79
  cases at lines 141-153. Verified by reading the file structure:
  `pass_at` calls at 72, 80, 88, 98, 125, 142, 152.

- **A-007 — `bin/branch-name.sh:31` emits canonical-prefix shape
  only.** Verified. Concrete:
  ```bash
  printf '%s/%s-%s\n' "$prefix" "$ident_lower" "$slug"
  ```
  where `prefix` is `feat` (line 26) or `fix` (lines 27-29 if `Bug`
  label present). Never emits `feature/...`. Confirms the resolver
  call at A-001 returns the canonical prefix shape every time.

- **A-008 — `bin/branch-name.sh:22` dies on Linear-API failure.**
  Verified: `[[ -n "$title" ]] || die "could not fetch title for $ident"`.
  The `2>/dev/null` in A-001's resolver call suppresses this
  `FATAL:`-prefixed line from leaking to `render-prompt.sh`'s stderr;
  `|| printf ''` substitutes empty so D-002's guard fires. Two-stage
  failure surfacing intentionally preserved.

- **A-009 — `bin/common.sh::die` lines 34-37.** Verified:
  ```bash
  die() {
    printf '[%s] FATAL: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
    exit 1
  }
  ```
  ISO-8601 UTC prefix + `FATAL:` literal. D-002's `die` message at
  A-001 line 226 uses bash double-quoted string `"render-prompt:
  branch-name.sh returned empty for $issue_id …"`. The `$issue_id`
  expansion is intentional (the `die` reports which issue tripped
  the invariant).

- **A-010 — `bin/render-prompt.sh:230-252` Python heredoc passes
  `branch_name` as a positional `argv` element.** Verified. The
  here-doc is `<<'PY'` (single-quoted), so no shell expansion occurs
  inside the heredoc body; `branch_name` is read from `sys.argv[10]`
  (0-indexed). Multi-line or special-char values are safe under
  Python's `argv` semantics. The sed fallback at 254-265 uses `|` as
  the delimiter; `branch_name` cannot contain `|` because
  `branch-name.sh:24`'s slugifier emits only `[a-z0-9-]/`.

- **A-011 — Commit `7772687` ("fix(eng-79): …") is the most recent
  change to `bin/render-prompt.sh`.** Verified via `git log --oneline
  -- bin/render-prompt.sh`: `7772687` is at the head of the file's
  history. Prior commits: `999ae25` (ENG-60 verb-form removal),
  `22ea510` (ENG-60-T2.12 gerund alignment), `02e2184` (project-profile
  unconditional), etc. None re-introduce `feature/${issue_id_lower}`.

- **A-012 — Commit `c1d3e4e` merged PR #65 (the ENG-79 fix) into
  `main`.** Verified via `git log --all --oneline`: `c1d3e4e`
  ("Merge pull request #65 from StupiDeity/fix/eng-79-render-prompt-source-branch-name-sh")
  immediately precedes `7772687` in the merge order; `7772687` is
  the squash-target / merge-content commit. The fix is therefore
  on `main` and inherited by every new feature-branch worktree —
  including this worktree (`feat/eng-79-…`).

- **A-013 — `bin/render-prompt.sh` has the sentinel pattern.**
  Verified at lines 270-272:
  ```bash
  if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
  fi
  ```
  Test files can `source` the script for function access without
  firing `main`. `bin/render-prompt-test.sh::src_with_env` (lines
  49-67) does exactly this for the case-6.x existing tests.

- **A-014 — `bin/render-prompt-test.sh` exists and is executable.**
  Verified. File is a self-contained executable with a `src_with_env`
  helper that stubs `TARGET_REPO`, `PIPELINE_PROFILE_ADDENDUM`, and
  `PROJECT_SLUG`, then sources `common.sh` and `render-prompt.sh`,
  then calls `append_project_profile`. The case-6.x cases run inside
  this sandbox; the ENG-79 cases at lines 141-153 are content-greps
  that do NOT invoke the sandbox (they grep the file at `$RP_SRC`).

- **A-015 — `.githooks/pre-commit` glob picks up `bin/*-test.sh`.**
  Verified by precedent: every `bin/<name>-test.sh` file (including
  `bin/render-prompt-test.sh`, present at the path) runs as part of
  the pre-commit hook. The hook's existing `KNOWN_BROKEN` allowlist
  does NOT include `render-prompt-test.sh`, so the test must pass
  for every commit. (The fix commit `7772687` itself passed the
  pre-commit hook per its commit message: "pre-commit suite: 32
  passed, 0 failed, 3 known-broken skipped".)

- **A-016 — `bin/agent-prompts-content-test.sh:523-527` (D-003
  symmetric defense).** Verified. Carries the prompt-side
  rejection-of-`feature/` pin. Untouched by ENG-79 — this is the
  prompt layer; ENG-79 fixes the renderer layer. Symmetric-defense
  pattern is preserved (3 layers, 3 tests).

- **A-017 — `bin/run-local-content-test.sh:28-32` (ENG-67 symmetric
  defense).** Verified. Carries the orchestrator-side rejection-of-
  `feature/` pin. Untouched by ENG-79 — this is the orchestrator
  layer.

- **A-018 — Branch shape verification.** This worktree is checked
  out at `feat/eng-79-render-prompt-sh-212-hardcodes-branch-name-feature-issue-id-lower-slug-drifts-from-branch-name-sh-canonical-feat-shape`
  (verified via `git branch --show-current`). The presence of the
  `feat/` prefix on this very worktree is itself a behavioral
  smoke test: `branch-name.sh` (called by `bin/run-local.sh:230`
  during the worktree-creation tick) emitted the correct prefix.
  The brainstorm doc carries `linear: ENG-79` in frontmatter
  (verified at line 2 of the brainstorm), so reconcile picked the
  correct doc.

- **A-019 — No new files in this plan.** The plan doc at
  `docs/plans/2026-05-08-eng-79-…` is the only new artifact and is
  written at planning-stage exit (this commit). Filename mirrors
  the brainstorm's basename per learned-rules P-001
  (`docs/plans/{date}-{issue_id_lower}-{slug}.md` = required by
  `partition_dirty_paths::D-004` for in-scope bucketing).

## File Structure

```
bin/
  render-prompt.sh                          UNCHANGED — already at post-ENG-79 state
                                                        from commit 7772687 (PR #65).
                                                        Verified at lines 212-226 (resolver
                                                        call + die guard) and 270-272
                                                        (sentinel). Implement agent verifies,
                                                        does NOT edit.
  render-prompt-test.sh                     UNCHANGED — already at post-ENG-79 state
                                                        from commit 7772687. Verified at
                                                        lines 128-153 (ENG-79 block).
                                                        Implement agent verifies, does NOT edit.

docs/
  plans/
    2026-05-08-eng-79-render-prompt-sh-…md  NEW — this file. Written at planning-stage exit.
                                                  Bucketed in-scope via the eng-79 basename
                                                  token per `partition_dirty_paths::D-004`.
```

No changes to: `AGENT_PROMPTS.md`, `bin/branch-name.sh`,
`bin/run-local.sh`, `bin/run-local-content-test.sh`,
`bin/agent-prompts-content-test.sh`, `bin/dispatch.sh`,
`bin/run-stage.sh`, `bin/common.sh`, `bin/poll.sh`, `bin/reconcile.sh`,
`bin/scope-check.sh`, `bin/verdict-handler.sh`,
`bin/classify-failure.sh`, `bin/linear.sh`, `bin/metrics.sh`,
`bin/pipeline.sh`, `bin/setup.sh`, `bin/pipeline-events.json`,
`learned-rules/**`, `launchd/**`, `.github/workflows/**`,
`.githooks/pre-commit`, `docs/pipeline-vocabulary.md`,
`docs/runbooks/recovery.md`, `CLAUDE.md`. The full bin/*-test.sh
suite runs but produces no diffs.

## API Contract

**No new API surface.** The harness has no FE↔BE API surface. The
change at the renderer layer adds:

- No new `dispatch.sh::allowed_tools_for` case.
- No new exit code (D-002's `die` exits 1 → `unknown-exit-1` via the
  default branch in `bin/common.sh::failure_outcome_for_exit`; the
  loudness comes from the `FATAL:` log line, not the metric outcome
  string — same pattern as ENG-67 D-003).
- No new metric event name.
- No new comment-body shape.
- No new orchestrator hook.
- No new lane fence.

The token `{branch_name}` interpolation contract (read by 23 sites
across `AGENT_PROMPTS.md`, verified by `grep -c '\{branch_name\}'
AGENT_PROMPTS.md`) is unchanged; only its *provenance* changed at the
renderer layer. The four-shape verdict vocabulary
(`pass | fail | halt | wait`) and the closed `meta_kinds` registry are
untouched. No `bin/pipeline-events.json` registry change. No
`docs/pipeline-vocabulary.md` regeneration.

## Backend Tasks

This plan commits to a verification path. If at any step the in-tree
code does NOT match the brainstorm spec (e.g., a future regression has
re-introduced `feature/${issue_id_lower}` between PR #65 merge and now),
the implement agent SHOULD restore the post-ENG-79 shape per
brainstorm §4 D-001/D-002/D-003 and ship the restoration in a fresh
commit. If the in-tree code matches (the expected case per A-001
through A-018), the implement agent verifies and exits cleanly with
ZERO file edits.

### Task 1: Verify D-001 (resolver call) is in tree

- `depends_on: []`
- `touches: bin/render-prompt.sh (read-only)`

- [ ] **Step 1.1.** Run
  `grep -qE 'bash[^|]*"\$SCRIPT_DIR/branch-name\.sh"[[:space:]]+"\$issue_id"' bin/render-prompt.sh`
  and confirm exit 0. Expected: present at line 224 per A-001.
- [ ] **Step 1.2.** Run `grep -qF 'feature/${issue_id_lower}' bin/render-prompt.sh`
  and confirm exit 1 (no match). Expected: absent per A-003.
- [ ] **Step 1.3.** If Step 1.1 fails OR Step 1.2 succeeds (i.e., the
  pre-ENG-79 hand-rolled form has been re-introduced between PR #65
  merge and now), edit `bin/render-prompt.sh` to restore the post-ENG-79
  shape per brainstorm §4 D-001 and §"A-001 verified shape" above. Use
  the Edit tool with the exact 16-line replacement from A-001.
  Otherwise, this task is a no-op (pass-through verification).
- [ ] **Step 1.4.** Run `bash -n bin/render-prompt.sh` and confirm
  exit 0. (Cheap syntactic check; required regardless of whether
  Step 1.3 ran.)

### Task 2: Verify D-002 (`die`-on-empty guard) is in tree

- `depends_on: [1]`
- `touches: bin/render-prompt.sh (read-only)`

- [ ] **Step 2.1.** Run
  `grep -qF 'die "render-prompt: branch-name.sh returned empty for $issue_id' bin/render-prompt.sh`
  and confirm exit 0. Expected: present at line 226 per A-001.
- [ ] **Step 2.2.** Run `grep -nF '[[ -n "$branch_name" ]]' bin/render-prompt.sh`
  and confirm a single match at the line immediately after the
  resolver call (line 225 per A-001).
- [ ] **Step 2.3.** If either step fails, restore the post-ENG-79
  guard per brainstorm §4 D-002 and §"A-001 verified shape" above
  (the `[[ -n "$branch_name" ]] || die …` two-line block at lines
  225-226). Otherwise, this task is a no-op (pass-through verification).

### Task 3: Verify D-003 (test pin) is in tree and passes

- `depends_on: []`
- `touches: bin/render-prompt-test.sh (read-only); bin/render-prompt.sh (read-only)`

- [ ] **Step 3.1.** Run
  `grep -qE '^# ─── ENG-79' bin/render-prompt-test.sh`
  and confirm exit 0. Expected: section header at line 128 per A-005.
- [ ] **Step 3.2.** Run
  `grep -cE '^(if grep -qE|if grep -qF)' bin/render-prompt-test.sh`
  and confirm count >= 2 (two new ENG-79 cases plus any pre-existing
  case-6.x asserts that share the shape — the case-6.x asserts use
  `grep -q` without flags + on-stdin redirection, so the actual
  matched count is 2).
- [ ] **Step 3.3.** Run `bash bin/render-prompt-test.sh` and confirm
  exit 0 with the summary block reporting `PASS: 7 / FAIL: 0`. (5 pre-existing
  case-6.x + 2 new ENG-79 cases per A-006.)
- [ ] **Step 3.4.** If Step 3.1 or 3.2 fails, restore the ENG-79
  block per brainstorm §4 D-003 and §"A-005 verified shape" (the
  full lines 128-153 block including the citation comment, positive
  grep, negative grep). If Step 3.3 fails, the regression is *real*
  — fix `bin/render-prompt.sh` per Tasks 1-2 first, then re-run
  Step 3.3.

### Task 4: Run the full test gate

- `depends_on: [1, 2, 3]`
- `touches: (verification only — no file edits)`

- [ ] **Step 4.1 — Syntactic checks.**
  ```
  bash -n bin/render-prompt.sh
  bash -n bin/render-prompt-test.sh
  ```
  Both must exit 0.

- [ ] **Step 4.2 — Direct test invocation.**
  `bash bin/render-prompt-test.sh` must exit 0 with `PASS: 7 / FAIL: 0`
  per A-006.

- [ ] **Step 4.3 — Adjacent test that exercises `branch-name.sh`
  resolution path.** Run the existing siblings that the brainstorm
  notes are unaffected:
  ```
  bash bin/run-local-content-test.sh
  bash bin/agent-prompts-content-test.sh
  ```
  Both must exit 0 (these pin the prompt-side and orchestrator-side
  symmetric-defense layers per A-016/A-017; ENG-79 only affects the
  renderer layer, so they are unchanged).

- [ ] **Step 4.4 — Pre-commit hook end-to-end.** Run
  `bash .githooks/pre-commit` and confirm exit 0. The hook runs the
  full `bin/*-test.sh` suite (~30 s); `render-prompt-test.sh` is in
  the suite (A-015) and is NOT in the `KNOWN_BROKEN` allowlist, so
  it must pass.

- [ ] **Step 4.5 — Secret-probe lint.** Run
  `bash bin/secret-probe-lint.sh` and confirm exit 0. ENG-79's edits
  reference no secret-shaped env var (`branch_name` is not a secret;
  the resolver call's args are `$SCRIPT_DIR` and `$issue_id`, neither
  is secret-shaped per ENG-46's pattern).

- [ ] **Step 4.6 — Commit hygiene check.** Run
  `git diff main...HEAD bin/render-prompt.sh bin/render-prompt-test.sh`
  and confirm zero output (the worktree's branch
  `feat/eng-79-render-prompt-sh-…` was created off `origin/main` and
  therefore inherits the post-ENG-79 state without any local edits).
  If the diff is non-empty, the implement agent has unintentionally
  introduced churn — revert via
  `git -C "$(pwd)" checkout origin/main -- bin/render-prompt.sh bin/render-prompt-test.sh`,
  then re-run Step 4.2 to re-confirm. (Per O-1, churn-free is the
  expected outcome on a back-fill plan.)

### Task 5: Stage commit + summary

- `depends_on: [4]`
- `touches: docs/plans/2026-05-08-eng-79-… (already staged at planning exit), stage-summary file`

- [ ] **Step 5.1 — Confirm `git status` is clean.** Run
  `git status --porcelain` and confirm zero output (no unstaged or
  untracked changes outside `docs/plans/` and the implement-agent's
  stage-summary file). The implement agent's per-stage allowed-tool
  lane in `dispatch.sh::allowed_tools_for` for `implementing` does
  NOT include any `feature/`-mutation surface; this step pins the
  back-fill no-op shape.

- [ ] **Step 5.2 — Implement agent stage summary.** Write the
  implement-stage summary file to
  `$PROJECT_STATE_DIR/ENG-79/stage-summary-implementing.md` per the
  CLAUDE.md "Per-issue state directory" § convention. Body should
  state: "ENG-79: back-fill plan; verified D-001/D-002/D-003 in tree
  at commit 7772687 (PR #65 merged at c1d3e4e); test gate green; no
  file edits required."

- [ ] **Step 5.3 — Smoke commit (only if Step 1.3 / 2.3 / 3.4 ran).**
  If any Tasks 1-3 step required restoring code (i.e., a regression
  was found between PR #65 merge and now), commit with the message
  `fix(ENG-79): re-apply render-prompt.sh sources branch-name.sh (regression repair)`.
  The pre-commit hook re-runs the full suite. If the back-fill is
  pure verification (no edits per Step 4.6), DO NOT commit — the
  implement stage exits with `verdict pass` and zero file delta, and
  the orchestrator's stage-transition swap is the only state change.

## Frontend Tasks

No UI surface; the harness has no frontend. **No frontend tasks.**

## Failure Mode → Test Map

Pulled from brainstorm §"Edge cases" (rows 1-5) and §"Error handling"
(rows 6-9). Each row binds to a concrete test or verification step.

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
|---|---|---|---|---|
| Pre-ENG-79 hand-rolled form re-introduced (`branch_name="feature/${issue_id_lower}-${slug}"`) | A future edit reverts the resolver call to the formation | Test fails at `bin/render-prompt-test.sh:148-153` (negative grep on `feature/${issue_id_lower}` literal); regression caught at commit time by pre-commit hook | unit | `bin/render-prompt-test.sh` ENG-79 negative case |
| Resolver call removed (`branch_name=""` or hard-coded value) | A future edit drops the `bash "$SCRIPT_DIR/branch-name.sh"` invocation | Test fails at `bin/render-prompt-test.sh:141-146` (positive grep on resolver-call regex) | unit | `bin/render-prompt-test.sh` ENG-79 positive case |
| `[[ -n "$branch_name" ]] || die …` guard removed | A future edit drops the D-002 `die` so an empty `branch_name` silently substitutes into `{branch_name}` | Behavioral coverage deferred per O-4; the brainstorm §7 documents this as a defense-in-depth invariant unreachable in practice (branch-name.sh runs in the same tick as run-local.sh's prior call). The grep cases at A-005 do not pin the `die` line shape — recorded as a P1 note for future hardening | smoke | `bash -n bin/render-prompt.sh` confirms syntactic validity post-edit |
| `branch-name.sh` Linear-API outage during render | Linear API down or stale token mid-tick | `branch-name.sh:22` dies; `2>/dev/null \|\| printf ''` substitutes empty; D-002 guard fires; `render-prompt.sh` dies with `render-prompt: branch-name.sh returned empty for ENG-N (Linear-API outage or bug-label resolution failed)`. Tick blocks loudly; FAIL_COUNTER NOT incremented (fires before dispatch invocation in `dispatch.sh::main`); next tick retries | smoke | `bash -n bin/render-prompt.sh` confirms post-ENG-79 control-flow is syntactically present per A-001; behavioral coverage deferred to O-4 |
| Bug-labeled issue interpolation (resolver returns `fix/eng-N-…`) | Issue carries `Bug` Linear label | `branch-name.sh:26-29` returns `fix/<lower>-<slug>`; render-prompt interpolates `fix/eng-N-…` into `{branch_name}` token; agent's downstream `gh pr list --head fix/eng-N-…` matches the actual checked-out branch (`bin/run-local.sh:230` resolves the same prefix) | unit | covered indirectly by A-007 verification (`branch-name.sh:31` printf shape pin); no per-test fixture for Bug-labeled issues exists today (O-4 noted) |
| Issue with all-non-alphanumeric title (e.g. `"!!!"`) → empty slug → `feat/eng-N-` (trailing hyphen) | Operator-side issue title | Pre-existing resolver-level edge case. ENG-79 does not introduce or fix; passed through verbatim. Out of scope (brainstorm O-3) | n/a | no test pin |
| Released stage (`stage == "released"`) | Cross-issue release dispatch via `bin/run-release-observer.sh` | `bin/render-prompt.sh:175-192` exits via `return 0` BEFORE the issue-id-required path (verified at A-001 / pre-existing `if [[ "$stage" == "released" ]]; then ... return 0; fi` at line 175); D-001/D-002 not reached | smoke | `bash -n bin/render-prompt.sh` confirms `if/return 0` arm preserved; behavioral coverage by case-6.x's existing `retrospective` test pattern |
| Both `feat/eng-N-…` AND `feature/eng-N-…` somehow exist on origin | Pre-PR-#48 stale ref + new canonical | `branch-name.sh:31` always emits canonical `feat/eng-N-…`; render-prompt interpolates that; agent's `git checkout {branch_name}` lands on canonical; `feature/...` ignored | unit | covered indirectly by A-007 verification + ENG-67's `bin/run-local-content-test.sh` (orchestrator-side ignore-`feature/` pin) |
| Operator manually creates `feature/eng-79-foo` for unrelated work | Operator-side activity | render-prompt does not inspect any `feature/...` ref; the resolver call ignores it; operator branch untouched | unit | A-003 + ENG-67's content test |
| Pre-commit hook lag — test exists but `.githooks/pre-commit` not yet active | Operator forgot to run `bin/install-git-hooks.sh` | Standard install path; until then, `bin/render-prompt-test.sh` runs only on manual invocation | n/a | not a code change |

## Test Strategy

### Unit / Content tests (D-003)

The existing `bin/render-prompt-test.sh:128-153` ENG-79 block is the
primary regression guard. Two grep-cases:

1. **Positive (line 141-146):** `grep -qE 'bash[^|]*"\$SCRIPT_DIR/branch-name\.sh"[[:space:]]+"\$issue_id"'`
   — pins that the resolver call exists with the exact arg shape.
2. **Negative (line 148-153):** `grep -qF 'feature/${issue_id_lower}'`
   — pins that the pre-ENG-79 hand-rolled form is absent.

The cases anchor on the literal token `feature/${issue_id_lower}` (NOT
`feature/`-anything) so the citation comment block at lines 213-223
(which legitimately cites the historical `feature/eng-N-…` failure
mode in prose) does not false-trigger.

### Sibling tests (existing, untouched)

- `bin/render-prompt-test.sh` cases 6.1-6.5 (lines 70-126) exercise
  `append_project_profile` behavior (profile addendum, retrospective
  skip, missing-profile die, marker-bearing-profile die). Unaffected
  by ENG-79 — they don't invoke the `branch_name` resolution path.
- `bin/run-local-content-test.sh` (ENG-67) — orchestrator-side
  `feature/` rejection. Symmetric defense; unchanged.
- `bin/agent-prompts-content-test.sh:447-491` — prompt-side
  `feature/` rejection (PR #48). Symmetric defense; unchanged.

Three layers, three tests, three independent grep-based pins.

### Smoke (syntactic) tests

`bash -n bin/render-prompt.sh` and `bash -n bin/render-prompt-test.sh`
after Tasks 1-3 confirm both files remain valid bash. The pre-commit
hook glob picks up `bin/render-prompt-test.sh` automatically (A-015);
`bash .githooks/pre-commit` runs the full suite end-to-end.

### Adversarial / E2E coverage (deferred)

Per brainstorm §10 O-4, behavioral end-to-end coverage of the
`branch_name` resolution path (faking `linear.sh` + `branch-name.sh`
return values and asserting `render-prompt.sh`'s interpolated output
contains `feat/eng-N-…`) would require extending the `src_with_env`
sandbox to stub two more scripts. The content-grep approach catches
the same regression class at much lower cost. Deferred. The brainstorm
documents this as an explicit non-goal; do not add behavioral coverage
as part of this ticket's scope.

### Test gate (committed to in §"Goal")

```
bash bin/render-prompt-test.sh \
  && bash -n bin/render-prompt.sh \
  && bash bin/secret-probe-lint.sh \
  && bash .githooks/pre-commit
```

The pre-commit hook (`bash .githooks/pre-commit`) is a strict superset
of the first three commands and is the canonical run-it-all gate.

## Self-review summary (5 personas)

Five personas dispatched against this plan: feasibility, scope,
coherence, design, product.

### Iteration 1

| Persona | Verdict | P0 | P1 |
|---|---|---|---|
| feasibility | PASS | 0 | 1 |
| scope | PASS | 0 | 0 |
| coherence | PASS | 0 | 1 |
| design | PASS | 0 | 0 |
| product | PASS | 0 | 1 |

**Status:** Personas: 5/5 PASS · gate P0: 0 · proceeding to implementing.

Gate criterion (≥4/5 PASS, zero P0) cleared at iteration 1.
P1 advisories below are recorded for transparency; none rise to a
blocking concern.

The brainstorm carried 6/6 PASS at iteration 1 with no unresolved P0;
this plan is a faithful crystallisation of brainstorm §4 decisions
D-001/D-002/D-003, repurposed as a verification back-fill per
brainstorm §10 O-1's recommendation. All codebase-fact assumptions
re-verified against the current worktree at the time of plan-writing
(see Assumption Inventory A-001 through A-019).

Persona findings:

- **feasibility (PASS, 0 P0, 1 P1).** All 19 modified-file assumptions
  (A-001 through A-019) `path:line`-cited against current code via
  Read/Grep on this worktree. The `depends_on` graph is correct:
  Task 1 and Task 3 can run in parallel (both are read-only verification
  on different files); Task 2 depends on Task 1 because both edit the
  same file's same neighborhood under the regression-repair branch;
  Task 4 depends on 1, 2, 3; Task 5 depends on 4.
  - **P1 (recorded):** Failure-mode row 3 ("`die` guard removed") notes
    that the test pin in `bin/render-prompt-test.sh` does NOT directly
    pin the D-002 `die` line shape — only Tasks 2.1 / 2.2 do
    (verification-time greps, not durable test asserts). A future
    edit could remove the `die` while leaving the resolver call intact
    and pass `bin/render-prompt-test.sh`. Recorded as a future
    hardening note; out of scope for this back-fill plan.

- **scope (PASS, 0 P0, 0 P1).** Every File Structure entry traces to
  brainstorm decisions D-001, D-002, D-003 (none of which require
  edits in this back-fill iteration). No gold-plating; no
  forbidden-touch violations. The "expected outcome is zero file
  delta" framing is explicitly tied to brainstorm §10 O-1's
  back-fill recommendation, not invented here.

- **coherence (PASS, 0 P0, 1 P1).** Plan Goal §1-§4 mirrors
  brainstorm Decisions D-001/D-002/D-003. Backend Tasks 1-3 each
  realize one decision; Task 4 runs the test gate; Task 5 handles
  commit hygiene. Failure Mode → Test Map covers every brainstorm
  edge-case row.
  - **P1 (recorded):** Goal §3 says "5 pre-existing + 2 new ENG-79
    cases" but the brainstorm §3 D-003 Verdict only enumerated 2 new
    cases without pinning the pre-existing count. The "5" figure
    comes from A-006 (counted from the test file). Internally
    coherent; cosmetic vs. brainstorm.

- **design (PASS, 0 P0, 0 P1).** No new abstractions, no new
  dependencies, no new exit codes, no new lane fences. The
  three-layer symmetric-defense pattern (prompt / orchestrator /
  renderer) is preserved unchanged from the brainstorm. The
  back-fill structuring (verification-shaped tasks rather than
  edit-shaped tasks) follows the explicit brainstorm §10 O-1
  recommendation.

- **product (PASS, 0 P0, 1 P1).** The plan's verification gate
  exactly maps to the issue's three-bullet "Test plan" section
  (positive grep, negative regression grep, symmetry pin). Operator
  experience is preserved — `bash bin/render-prompt-test.sh` exit 0
  + `bash .githooks/pre-commit` exit 0 + `git status` clean is a
  clear, reproducible green gate.
  - **P1 (recorded):** The brainstorm §10 O-1 explicitly flagged
    "operator decision needed: is this brainstorm useful as a
    back-fill, or should the issue be closed without further pipeline
    progression?" The plan defaults to "let the pipeline run through"
    per the brainstorm's own recommendation, but a reviewer at the
    review stage may opt to close the issue instead. Either path is
    correct; the plan does not pre-empt that decision.
