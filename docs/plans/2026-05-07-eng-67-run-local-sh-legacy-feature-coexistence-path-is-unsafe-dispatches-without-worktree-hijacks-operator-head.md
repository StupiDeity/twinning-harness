---
linear: ENG-67
date: 2026-05-07
topic: delete run-local.sh's legacy feature/* coexistence path; harden the dispatch_cwd soft fallback into a die; add content-test pin
---

# Plan — ENG-67 delete legacy `feature/*` coexistence path in `run-local.sh`

Implementation plan for the design at
`docs/brainstorms/2026-05-07-eng-67-run-local-sh-legacy-feature-coexistence-path-is-unsafe-dispatches-without-worktree-hijacks-operator-head-design.md`.

## Anti-anchoring check

- **Problem (operator's words).** `bin/run-local.sh:209-226` carries a
  legacy `feature/*` coexistence path that, when an agent had created
  a non-canonical `feature/eng-N-…` branch, silently fell into a flow
  with `worktree_path=""` and `dispatch_cwd="$TARGET_REPO"`. The
  agent's subsequent `git checkout -B feature/eng-N-…` mutated the
  operator's main `$TARGET_REPO` HEAD silently mid-tick, and
  `scope-check` ran against the wrong working tree (rc=2, halt with
  `agent-failure`). The May-2026 ENG-63/64/65 incident is the
  documented symptom; the issue body recommends Path A ("delete the
  path entirely") over Path B ("harden the path"). The brainstorm
  picks Path A, with a Path A.1/A.2 split flag inside it for whether
  to additionally harden the `dispatch_cwd` soft-fallback mechanism.
- **Does the brainstorm address it?** Yes. D-001 deletes the path,
  D-002 pins the absence with a new content test, D-003 replaces the
  `dispatch_cwd="$TARGET_REPO"` soft fallback with a `die` so the
  *mechanism* of harm is also removed, D-004 adds a 2-sentence note
  to `CLAUDE.md` so operators can recognise the new `die` line if it
  ever fires. Path A.1 (D-001+D-002+D-003+D-004) is the brainstorm's
  primary plan; Path A.2 (D-001+D-002 only) is documented as an
  opt-out per §10 O-3 of the brainstorm.
- **Proportional?** Yes. ~6 LOC deleted from `bin/run-local.sh`, ~2
  LOC added (`die` + direct assignment), ~13 lines of replacement
  comment with PR #48 / ENG-63/64/65 / `AGENT_PROMPTS.md` citations,
  ~50 LOC new test file `bin/run-local-content-test.sh`, ~2 sentences
  added to `CLAUDE.md` "Per-issue state directory" §. No new helper
  functions, no new exit codes (the `die` exits 1 → `unknown-exit-1`,
  acceptable for an unreachable invariant trip per brainstorm §5),
  no new metric event, no new lane fence, no AGENT_PROMPTS.md edit.
- **Plan commits to Path A.1.** Path A.2 (drop D-003 + D-004 + the
  4th grep-case in D-002) remains a reviewer-callable opt-out per
  brainstorm §10 O-3 / O-4; the Implement Agent SHOULD ship A.1
  unless the reviewer explicitly directs otherwise.
- **No escalation needed. PROCEED.**

## Goal

Land a single PR off `main` (`feat/eng-67-…`) that, after merge,
satisfies these acceptance criteria — verifiable by:

```
bash bin/run-local-content-test.sh \
  && bash bin/run-local-helpers-adversarial-test.sh \
  && bash bin/run-local-sweep-test.sh \
  && bash bin/agent-prompts-content-test.sh \
  && bash -n bin/run-local.sh \
  && bash bin/secret-probe-lint.sh
```

exiting 0 with the new `bin/run-local-content-test.sh` reporting
`4 passed, 0 failed`:

1. **Path removed (D-001).** `bin/run-local.sh:209-226` collapses to
   the unconditional canonical-resolution path; the legacy
   detection's `if [[ -n $(git ... feature/${ident_lower}-*) ... ]]`
   block is gone. The replacement comment cites PR #48
   (commit `4635cd3`), ENG-63/64/65, and `AGENT_PROMPTS.md:77-88`.
2. **Soft fallback removed (D-003).** `bin/run-local.sh:228-232` is
   replaced with `[[ -n "$worktree_path" ]] || die "internal:
   worktree_path empty after reconcile=proceed (ENG-67); refusing to
   dispatch from \$TARGET_REPO"; dispatch_cwd="$worktree_path"`. No
   silent fallback into `$TARGET_REPO` remains.
3. **Test pin (D-002).** `bin/run-local-content-test.sh` exists as a
   self-contained executable, runs under `bash bin/*-test.sh` glob,
   and asserts (a) `bin/run-local.sh` contains no `feature/` token in
   non-comment lines, (b) no `legacy feature` phrase in non-comment
   lines, (c) no `using old flow` log line, (d) no
   `dispatch_cwd="$TARGET_REPO"` soft fallback shape (anchored ERE).
4. **Operator note (D-004).** `CLAUDE.md` "Per-issue state
   directory" § gains a 2-sentence paragraph describing the
   never-dispatch-into-`$TARGET_REPO` invariant + the operator
   recognition string for the new `die`.

Out of scope (explicit per brainstorm §10):

- O-1: audit other `git -C "$TARGET_REPO"` call sites in
  `bin/run-local.sh` for HEAD-mutation risk. Lines 72-81 (`core.bare`
  self-heal — read-only), 116-138 (`ensure_worktree` — by design),
  140 (`cd "$TARGET_REPO"` precedes read-only `poll.sh`) are all
  benign per brainstorm §"Architectural principle".
- O-2: behavioral end-to-end test of the dispatch path (multi-hundred
  LOC of stub scaffolding for the same regression-class coverage the
  ~50-LOC content test pins).
- O-3: sentinel pattern for `bin/run-local.sh` (top-level statements
  would need to move into `main()`; out of scope refactor).
- O-4: cleanup of orphan `feature/eng-N-…` branches on operators'
  forks; one-line `git -C "$TARGET_REPO" branch -D ...` per branch,
  not a pipeline concern.
- O-5: `bin/cleanup-worktrees.sh` does not consider raw `feature/...`
  refs; by design it iterates `$PROJECT_STATE_DIR/ENG-*/worktree`
  (verified at `bin/cleanup-worktrees.sh:54` inside `main()`).
- O-6: `branch-name.sh` content test for prefix-shape regression
  (`bin/branch-name.sh:31` emits only `feat/`/`fix/`); `bin/agent-prompts-content-test.sh:479-491`
  partially pins this from the prompt side. Out of scope to also
  pin from the orchestrator side.
- O-7 (Path A.2 opt-out recipe): if reviewer/operator prefers the
  literal three-bullet AC, drop D-003 + D-004 + the 4th grep-case;
  file a sibling ticket "run-local.sh dispatch_cwd should die-on-empty
  rather than fall back to $TARGET_REPO" carrying that decision.
- O-8: removing the May-2026 incident references from
  `bin/agent-prompts-content-test.sh:447-491`. The pin still serves
  its original purpose (catching a prompt edit that drops the
  canonical-prefix rule). Untouched.

## Architecture

This work is additive across:

- one prose region in `bin/run-local.sh` (lines 209-232 — replacing
  the legacy detection + soft fallback with canonical resolution +
  `die`-on-empty),
- one new test file `bin/run-local-content-test.sh` (sibling to
  `bin/run-local-helpers-adversarial-test.sh` and
  `bin/run-local-sweep-test.sh`),
- one prose paragraph in `CLAUDE.md` (the "Per-issue state directory"
  section gains a 2-sentence operator-recognition paragraph).

The architectural pivot is removing the orchestrator's silent
accommodation of an agent rule violation (a `feature/*` branch).
PR #48 closed the upstream cause at the prompt level; ENG-67 closes
the orchestrator-side. Together they form the symmetric
prompt-orchestrator defense pattern documented in
`learned-rules/harness/build.md` Bld-001 (verified at lines 12-52
during prior reads on this worktree). The new `die` mirrors the
existing canonical pattern from `bin/run-local-helpers.sh:83`
(`die "stage_output_paths: unknown stage: $stage"`) and
`bin/branch-name.sh:17` (`die "usage: branch-name.sh <issue_id>"`).

There is no `docs/VISION.md`, no `docs/ARCHITECTURE.md`, no
`docs/knowledge/decisions.md` (verified: `ls docs/` returns
`brainstorms  pipeline-vocabulary.md  pipeline-vocabulary.template.md
plans  runbooks` only). Governing constraints come from `CLAUDE.md`
and `learned-rules/harness/{project-profile,build}.md`. The
`learned-rules/harness/plan.md` file does not exist (verified: `ls
learned-rules/harness/` returns `build.md  project-profile.md`
only); the closest analogous rule set is `learned-rules/twinning/plan.md`
P-001 and P-002, both observed during this stage's read.

## Tech stack

- Bash 3.2+ (Darwin default, harness target).
- POSIX `awk` for the comment-stripping prefilter in the new
  content test (`!/^[[:space:]]*#/ && !/^[[:space:]]*$/`); BSD `grep`
  for `-qF` (literal) and `-qE` (extended-regex anchored `$`).
- `bin/common.sh::die` for the new D-003 soft-fallback removal —
  exits 1 with `FATAL:`-prefixed message via the existing helper.
- No new dependencies. No new `dispatch.sh::allowed_tools_for`
  cases. No new metric event names. No new
  `bin/pipeline-events.json` entries. No new `learned-rules/` file.

## Assumption Inventory

Every modified-file fact below is `path:line`-cited against the
current worktree per the codebase-fact verification mandate
(learned-rules/twinning/plan.md P-002 / B-001).

### Modified files — current signatures, call sites, and insertion points

- **A-001 — `bin/run-local.sh:209-226` is the legacy detection block
  today.** Verified by direct read. Concrete current shape:
  ```bash
  # Determine branch name and worktree path. Only for new-model branches; for
  # legacy feature/* in-flight, skip worktree creation and fall through.
  branch=""
  worktree_path=""
  if [[ "$reconcile_decision" == "proceed" ]]; then
    # Legacy-branch coexistence: if a feature/<issue> branch already exists
    # locally or on origin, use the old flow for this issue.
    ident_lower="$(tr '[:upper:]' '[:lower:]' <<<"$issue_id")"
    if [[ -n "$(git -C "$TARGET_REPO" branch --list "feature/${ident_lower}-*" 2>/dev/null)" ]] \
       || git -C "$TARGET_REPO" ls-remote --heads origin "feature/${ident_lower}-*" 2>/dev/null | grep -q "feature/"; then
      log "legacy feature/* branch detected for $issue_id — using old flow (no worktree)"
    else
      branch="$(bash "$SCRIPT_DIR/branch-name.sh" "$issue_id")"
      worktree_path="$(resolve_worktree_path "$branch" "$issue_id")"
      mkdir -p "$(dirname "$worktree_path")"
      ensure_worktree "$branch" "$worktree_path"
    fi
  fi
  ```
  Comment header at 209-210; `branch=""` at 211; `worktree_path=""`
  at 212; outer `if` at 213; legacy detection inner block 214-225;
  outer `fi` at 226. D-001's replacement is a single `if [[
  "$reconcile_decision" == "proceed" ]]; then ... fi` that always
  takes the canonical-resolution path (formerly the `else` arm of
  the inner `if`), preceded by a ~13-line replacement comment.

- **A-002 — `bin/run-local.sh:228-232` is the `dispatch_cwd` soft
  fallback.** Verified. Concrete current shape:
  ```bash
  # Dispatch run-stage.sh from the worktree if one was resolved, else from main.
  dispatch_cwd="$TARGET_REPO"
  if [[ -n "$worktree_path" ]]; then
    dispatch_cwd="$worktree_path"
  fi
  ```
  Comment at 228; assignment-with-fallback at 229; reassignment guard
  at 230-232. D-003 replaces lines 228-232 with `[[ -n "$worktree_path"
  ]] || die "internal: worktree_path empty after reconcile=proceed
  (ENG-67); refusing to dispatch from \$TARGET_REPO"; dispatch_cwd="$worktree_path"`
  prefaced by a 5-line comment explaining the unreachable-by-construction
  invariant.

- **A-003 — `dispatch_cwd` has 6 reader call sites at lines
  240, 246, 270, 351, 352, 360 (5 distinct logical readers per
  brainstorm D-003).** Verified via `grep -n 'dispatch_cwd' bin/run-local.sh`:
  line 229 = assignment; line 231 = the legacy reassignment
  (deleted by D-003); 6 readers at 240 (snapshot pipeline `git -C "$dispatch_cwd"`),
  246 (dispatch invocation `(cd "$dispatch_cwd" && ...)`), 270 (sweep
  partition `git -C "$dispatch_cwd"`), 351-352 (`xargs -0 git add` and
  `git ... commit`), 360 (`git push`). All 6 are unaffected by D-003;
  they continue to read from `dispatch_cwd` as before. Brainstorm
  D-003 rejected-alternative §"collapse `dispatch_cwd` away" rationale
  preserved: not renaming.

- **A-004 — `bin/run-local.sh:177-205` (link:/human reconcile) `exit
  0` BEFORE reaching the worktree-resolution block.** Verified.
  Concrete shape:
  ```bash
  case "$reconcile_decision" in
    link:*)
      ...
      exit 0
      ;;
    human)
      ...
      exit 0
      ;;
  esac
  ```
  `link:*` arm exits at line 192; `human` arm exits at line 205.
  Confirms post-D-001 invariant: only `proceed` reaches line 209.
  Combined with D-001's deletion of the `feature/*`-detection inner
  branch, every `proceed` tick now resolves a non-empty
  `worktree_path` — which is the construction making D-003's
  fallback unreachable.

- **A-005 — `bin/run-local.sh::resolve_worktree_path` at lines
  109-114.** Verified. Concrete signature:
  ```bash
  resolve_worktree_path() {
    local branch="$1" issue="$2"
    [[ -n "$issue" ]] || die "resolve_worktree_path: issue id required"
    printf '%s/worktree' "$(issue_dir "$issue")"
  }
  ```
  Always emits a non-empty path when given a non-empty `issue_id`
  (which is guaranteed by the `[[ -z "$issue_id" ]]` guard at
  line 148). No code change.

- **A-006 — `bin/run-local.sh::ensure_worktree` at lines 116-138.**
  Verified. Three-branch resolution:
  ```bash
  if git -C "$TARGET_REPO" rev-parse --verify "refs/heads/$branch" >/dev/null 2>&1; then
    ...
  elif git -C "$TARGET_REPO" rev-parse --verify "refs/remotes/origin/$branch" >/dev/null 2>&1; then
    ...
  else
    git -C "$TARGET_REPO" fetch origin main
    git -C "$TARGET_REPO" worktree add --no-track "$path" -b "$branch" origin/main
  fi
  ```
  Function definition opens at 116; closing `}` at 138. Always
  creates a worktree when called; dies on git failure (set -e
  semantics). Behavior unchanged by D-001/D-003.

- **A-007 — `bin/branch-name.sh:31` emits canonical-prefix shape
  only.** Verified. Concrete final-line:
  ```bash
  printf '%s/%s-%s\n' "$prefix" "$ident_lower" "$slug"
  ```
  where `prefix` is `feat` (line 26) or `fix` (line 28-29 if `Bug`
  label present). Never emits `feature/...`. Confirms D-001's
  fall-through claim: the canonical-resolution path never produces
  a `feature/...` branch name, so `ensure_worktree` always resolves
  off the canonical name.

- **A-008 — `bin/branch-name.sh:22` dies on Linear API failure.**
  Verified: `[[ -n "$title" ]] || die "could not fetch title for $ident"`.
  Pre-D-001 the legacy-detection's `if`-arm short-circuited before
  this call. Post-D-001 every `proceed` tick reaches `branch-name.sh`,
  so a Linear-API outage now blocks the tick at this site instead
  of silently falling through to `$TARGET_REPO`-cwd dispatch. Per
  brainstorm §7 error-handling: this is a strict improvement
  (loud-fail vs. silent-fallback).

- **A-009 — `bin/common.sh:34-37` defines the canonical `die`.**
  Verified. Concrete shape:
  ```bash
  die() {
    printf '[%s] FATAL: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
    exit 1
  }
  ```
  ISO-8601 UTC prefix + `FATAL:` literal. D-004's CLAUDE.md note
  quotes the operator-recognisable substring including the `FATAL:`
  prefix; D-003's invariant message embeds `internal: worktree_path
  empty after reconcile=proceed (ENG-67); refusing to dispatch from
  $TARGET_REPO`. Note: inside the bash `die "..."` argument the
  literal `$TARGET_REPO` must be backslash-escaped (`\$TARGET_REPO`)
  to prevent shell expansion of an unset variable; D-003's edit
  preserves the escape.

- **A-010 — `bin/common.sh::failure_outcome_for_exit` routes exit 1
  to `unknown-exit-1`.** Verified at lines 107-130. Default branch
  `*) printf 'unknown-exit-%s' "$exit_code"`. Exit 1 from D-003's
  `die` falls into default → `unknown-exit-1`. Acceptable per
  brainstorm §5: the loudness comes from the `FATAL:` log line,
  not the metric outcome string. **No new exit code added** — the
  `die` is an internal-invariant trip, not a stage-execution failure
  that warrants a typed code (per brainstorm §5: "no new exit codes").

- **A-011 — `bin/run-local.sh:32` defines `FAIL_COUNTER`.** Verified:
  `FAIL_COUNTER="$PROJECT_STATE_DIR/.consecutive-failures"`. Per
  brainstorm §7, D-003's `die` fires BEFORE the dispatch invocation
  at line 246 and BEFORE the rc-handling block at lines 250-258, so
  the counter is NOT incremented on a `die` trip. The breaker does
  not see this as a "consecutive failure" — intentional, since the
  invariant trip is not a stage-execution problem.

- **A-012 — `bin/run-local.sh:52-58` cleanup-on-exit trap.**
  Verified:
  ```bash
  cleanup_on_exit() {
    rm -rf "$LOCK_DIR"
    if (( ${#TWINNING_SWEEP_TMPS[@]} > 0 )); then
      rm -f "${TWINNING_SWEEP_TMPS[@]}"
    fi
  }
  trap cleanup_on_exit EXIT
  ```
  Releases the lock + reaps registered sweep tempfiles. Triggered
  on D-003's `die` (which exits 1). No code change required —
  trap is already in place.

- **A-013 — `bin/run-local.sh:415` is the last line; no sentinel.**
  Verified: top-level executable script, no `if [[ "${BASH_SOURCE[0]}"
  == "${0}" ]]; then main "$@"; fi`. The new `bin/run-local-content-test.sh`
  therefore does NOT source `bin/run-local.sh` — it operates on the
  file as text via `awk` + `grep` only.

- **A-014 — `bin/run-local-helpers-adversarial-test.sh` exists as
  a sibling test.** Verified at `bin/run-local-helpers-adversarial-test.sh:1-43`.
  Source-and-stub layout:
  ```bash
  set -uo pipefail
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  export PROJECT_SLUG="${PROJECT_SLUG:-test-slug}"
  source "$SCRIPT_DIR/common.sh"
  source "$SCRIPT_DIR/run-local-helpers.sh"
  ```
  with `report_ok` / `report_fail` helpers and `assert_partition_counts`.
  The new content test follows a similar harness shape but is
  simpler (no source of run-local.sh; just text scanning).

- **A-015 — `bin/run-local-sweep-test.sh` exists as a sibling
  test.** Verified at `bin/run-local-sweep-test.sh:1-44`. Same
  source-and-stub pattern. Both files end with `exit $((FAIL > 0
  ? 1 : 0))`-style summaries. The new content test follows.

- **A-016 — `bin/agent-prompts-content-test.sh:447-491` carries the
  PR #48 branch-name convention pins.** Verified. The 2026-05-04
  ENG-63/64/65 incident comment block opens at line 447; the
  rule-presence pin (`### Branch-name convention`) at line 459;
  forbidden-form pins for `git checkout -b`, `git checkout -B`,
  `git branch -m`, `git switch -c` at line 468; canonical-shape
  pin (`feat/eng-N-`, `fix/eng-N-`) at lines 479-481;
  `feature/`-rejection pin at lines 486-491. **Untouched by ENG-67**
  per brainstorm §"Architecture" — these pins remain durable from
  the prompt side; the new `bin/run-local-content-test.sh` is the
  symmetric orchestrator-side pin.

- **A-017 — `.githooks/pre-commit:151-154` globs `bin/*-test.sh`.**
  Verified by direct read:
  ```bash
  printf '\n[pre-commit] running bin/*-test.sh (%s tests)\n' \
    "$(ls bin/*-test.sh 2>/dev/null | wc -l | tr -d ' ')"
  ...
  for t in bin/*-test.sh; do
  ```
  The new `bin/run-local-content-test.sh` is picked up automatically
  on the next pre-commit. No installer change needed.

- **A-018 — `CLAUDE.md` "Per-issue state directory" § opens at
  line 193 and closes at line 217.** Verified. The section's body
  consists of a fenced tree diagram (lines 197-212) and a paragraph
  about `issue-state.json` at lines 214-217. D-004 inserts a
  2-sentence paragraph between line 217 (the trailing
  `branch-head SHA.` line) and line 218 (blank) — i.e., AFTER the
  current closing paragraph, BEFORE the next H2 (`## Sweep + scope
  partition (ENG-14)` at line 219). Insertion shape: a new blank
  line + the paragraph + a trailing blank line, preserving section
  separation.

- **A-019 — Partition-sweep allowlist for `bin/` paths under
  `implementing` stage.** Verified by precedent: ENG-43 / ENG-58 /
  ENG-62 / ENG-63 / ENG-64 / ENG-71 implement-stage commits all
  successfully landed `bin/<file>.sh` and `bin/<file>-test.sh` paths
  via the harness-self target's `.scope.allowlist.implementing`
  override (per CLAUDE.md "Per-target dispatch.tools extras" §). The
  new `bin/run-local-content-test.sh` and edited `bin/run-local.sh`
  + `CLAUDE.md` paths bucket the same way. No allowlist edit needed.

- **A-020 — `bin/run-local-helpers.sh::partition_dirty_paths` D-004
  applies issue-id basename token check ONLY for
  `brainstorming|planning` stages.** Verified at lines 133-198. The
  brainstorm doc (`docs/brainstorms/2026-05-07-eng-67-...md`) and
  this plan doc (`docs/plans/2026-05-07-eng-67-...md`) both carry
  `eng-67` in basename, so both bucket as in-scope. The
  implementing-stage edits to `bin/run-local.sh`, the new
  `bin/run-local-content-test.sh`, and `CLAUDE.md` bucket via the
  harness-self target's `.scope.allowlist.implementing` override
  (A-019 precedent).

- **A-021 — No in-flight `feature/eng-N-…` issues remain in this
  repo as of 2026-05-07.** Assumed per the Linear issue body's
  assertion that the May-2026 rename pass cleared in-flight cases.
  Implementation Task 1 should re-verify with `git -C "$TARGET_REPO"
  branch --list "feature/eng-*"` and `git -C "$TARGET_REPO"
  ls-remote --heads origin "feature/eng-*"` returning empty before
  merging. If a `feature/eng-N-…` ref exists, post-D-001 it is
  invisible to canonical resolution; agent dispatches into a fresh
  worktree from `origin/main`. Operator manual prune is the
  recovery path (out of scope per O-4).

### Newly created files

- **A-022 — `bin/run-local-content-test.sh` (NEW).** assumed/new.
  Will be created at `bin/run-local-content-test.sh` per brainstorm
  D-002. Sibling-test naming (`run-local-*-test.sh`) so the
  pre-commit glob picks it up automatically. Self-contained
  executable, no `source` of `bin/run-local.sh`, no test-runner.

## File Structure

```
bin/
  run-local.sh                            modified — replace lines 209-226 with
                                                     unconditional canonical resolution
                                                     + cite-PR48 comment (~13 lines);
                                                     replace lines 228-232 with
                                                     `[[ -n "$worktree_path" ]] || die ...;
                                                     dispatch_cwd="$worktree_path"`
                                                     (~7 lines incl. comment). Net file
                                                     delta: ~+1 line. (Tasks 1, 2)
  run-local-content-test.sh               NEW       ~50 LOC self-contained content test
                                                    pinning the four absences. Sibling
                                                    naming, picked up by the pre-commit
                                                    `bin/*-test.sh` glob automatically.
                                                    (Task 3)

CLAUDE.md                                 modified — append 2-sentence paragraph to the
                                                     "Per-issue state directory" §
                                                     between line 217 and the next H2
                                                     at line 219. (Task 4)

docs/
  plans/
    2026-05-07-eng-67-...md               NEW — this file.
```

No changes to: `AGENT_PROMPTS.md`, `bin/agent-prompts-content-test.sh`,
`bin/run-local-helpers.sh`, `bin/run-local-helpers-adversarial-test.sh`,
`bin/run-local-sweep-test.sh`, `bin/branch-name.sh`,
`bin/cleanup-worktrees.sh`, `bin/dispatch.sh`, `bin/run-stage.sh`,
`bin/common.sh`, `bin/poll.sh`, `bin/reconcile.sh`,
`bin/scope-check.sh`, `bin/verdict-handler.sh`,
`bin/classify-failure.sh`, `bin/linear.sh`, `bin/metrics.sh`,
`bin/pipeline.sh`, `bin/setup.sh`, `bin/render-prompt.sh`,
`bin/pipeline-events.json`, `learned-rules/**`, `launchd/**`,
`.github/workflows/**`, `.githooks/pre-commit` (the existing glob
already picks up the new file), `docs/pipeline-vocabulary.md`,
`docs/runbooks/recovery.md` (no new operator surface — the
`die` is unreachable by construction; CLAUDE.md sentence is the
operator-recognition surface per brainstorm §"Architecture").

## API Contract

**No new API surface.** The harness has no FE↔BE API surface. The
change adds:

- No new dispatch.sh exit code. D-003's `die` exits 1 →
  `unknown-exit-1` via the existing default branch in
  `bin/common.sh::failure_outcome_for_exit` (per A-010).
- No new metric event name.
- No new comment-body shape.
- No new orchestrator hook.
- No new lane fence.

The four-shape verdict vocabulary (`pass | fail | halt | wait`)
and the closed `meta_kinds` registry are untouched. No
`bin/pipeline-events.json` registry change. No
`docs/pipeline-vocabulary.md` regeneration.

## Backend Tasks

### Path A.2 reviewer opt-out (single-place summary)

If the reviewer prefers the strict three-bullet AC (delete path + one-line
comment + test pin, no `dispatch_cwd` hardening, no CLAUDE.md note),
apply the following four omissions consistently — partial application
will leave a half-finished invariant. Plan defaults to Path A.1; A.2
is an explicit opt-in.

| Decision | A.1 (default) | A.2 (opt-out) |
|---|---|---|
| Task 1 deletion-site comment | ~13-line citation chain | single line `# Legacy feature/* coexistence path deleted in ENG-67; see PR #48 (commit 4635cd3).` |
| Task 2 (D-003 `die`-on-empty) | run | skip entirely |
| Task 3 case 4 (`dispatch_cwd="\$TARGET_REPO"` ERE pin) | include | drop |
| Task 4 (CLAUDE.md operator note) | run | skip entirely |
| Task 3 `depends_on` | `[1, 2]` | `[1]` (Task 2 not in graph) |
| Test gate count | `4 passed, 0 failed` | `3 passed, 0 failed` |

If A.2 is selected, the Implement Agent SHOULD also file a sibling
Linear ticket per brainstorm §10 O-7 carrying D-003 + D-004 + the 4th
grep-case for a future hardening pass.

### Task 1: Delete legacy `feature/*` detection block in `bin/run-local.sh`

- `depends_on: []`
- `touches: bin/run-local.sh:209-226`

- [ ] **Step 1.1 — Pre-flight verification.** Run
  `git -C "$TARGET_REPO" branch --list "feature/eng-*"` and
  `git -C "$TARGET_REPO" ls-remote --heads origin "feature/eng-*"`
  in the harness-self `$TARGET_REPO`. Both should return empty
  per A-021. If either returns non-empty, log the matching ref(s)
  in the Implement Agent's stage-summary as forensic evidence and
  proceed — the post-D-001 fall-through is a strict improvement
  (silent dispatch into `$TARGET_REPO` → fresh canonical worktree
  off `origin/main`), not a regression.

- [ ] **Step 1.2 — Replace the comment header + the legacy
  detection block** in `bin/run-local.sh`. The current shape (per
  A-001) at lines 209-226 collapses to the canonical resolution
  path. Use the Edit tool with the following old/new strings.

  **Old string (exactly lines 209-226 — 18 lines):**
  ```
  # Determine branch name and worktree path. Only for new-model branches; for
  # legacy feature/* in-flight, skip worktree creation and fall through.
  branch=""
  worktree_path=""
  if [[ "$reconcile_decision" == "proceed" ]]; then
    # Legacy-branch coexistence: if a feature/<issue> branch already exists
    # locally or on origin, use the old flow for this issue.
    ident_lower="$(tr '[:upper:]' '[:lower:]' <<<"$issue_id")"
    if [[ -n "$(git -C "$TARGET_REPO" branch --list "feature/${ident_lower}-*" 2>/dev/null)" ]] \
       || git -C "$TARGET_REPO" ls-remote --heads origin "feature/${ident_lower}-*" 2>/dev/null | grep -q "feature/"; then
      log "legacy feature/* branch detected for $issue_id — using old flow (no worktree)"
    else
      branch="$(bash "$SCRIPT_DIR/branch-name.sh" "$issue_id")"
      worktree_path="$(resolve_worktree_path "$branch" "$issue_id")"
      mkdir -p "$(dirname "$worktree_path")"
      ensure_worktree "$branch" "$worktree_path"
    fi
  fi
  ```

  **New string (~21 lines — comment grows to cite PR #48 / ENG-63/64/65 /
  AGENT_PROMPTS.md):**
  ```
  # Determine branch name and worktree path. The legacy `feature/*`
  # coexistence path that used to live here was deleted in ENG-67
  # (May 2026): it dispatched the agent from the operator's $TARGET_REPO
  # checkout when an agent had created a non-canonical
  # `feature/eng-N-...` branch (the May-2026 ENG-63/64/65 failure mode),
  # silently mutating the operator's HEAD and breaking scope-check.
  # PR #48 (commit 4635cd3) closed the upstream cause at the prompt
  # level (AGENT_PROMPTS.md:77-88 hard-rules 1-4 +
  # bin/agent-prompts-content-test.sh:447-491 pins); the orchestrator-
  # side coexistence is no longer needed. Any future feature/* branch
  # that somehow appears falls through to canonical resolution, where
  # ensure_worktree creates a fresh worktree off origin/main — a clean
  # error surface, not a silent dispatch into $TARGET_REPO.
  branch=""
  worktree_path=""
  if [[ "$reconcile_decision" == "proceed" ]]; then
    branch="$(bash "$SCRIPT_DIR/branch-name.sh" "$issue_id")"
    worktree_path="$(resolve_worktree_path "$branch" "$issue_id")"
    mkdir -p "$(dirname "$worktree_path")"
    ensure_worktree "$branch" "$worktree_path"
  fi
  ```

  **Path A.2 opt-out (per brainstorm §10 O-7).** If the reviewer
  prefers strict adherence to the issue's literal "one-line comment"
  AC bullet 2, replace the 13-line citation comment with a single
  line `# Legacy feature/* coexistence path deleted in ENG-67; see
  PR #48 (commit 4635cd3).` and proceed. Either choice satisfies AC.

- [ ] **Step 1.3 — Syntactic check.** Run `bash -n bin/run-local.sh`
  and confirm exit 0. The Edit collapses 18 lines → 21 lines
  (Path A.1) or 18 → 9 lines (Path A.2). Either way, lines 228-232
  shift to a new offset; D-003 (Task 2) edits by string match and
  is unaffected.

### Task 2: Replace `dispatch_cwd="$TARGET_REPO"` soft fallback with `die`-on-empty

- `depends_on: [1]`
- `touches: bin/run-local.sh:228-232 (post-Task-1 line numbers shift; locate by string)`

- [ ] **Step 2.1 — Replace the `dispatch_cwd` block** in
  `bin/run-local.sh`. Use the Edit tool with the following old/new
  strings (string match — line numbers shift after Task 1).

  **Old string (current lines 228-232 — 5 lines):**
  ```
  # Dispatch run-stage.sh from the worktree if one was resolved, else from main.
  dispatch_cwd="$TARGET_REPO"
  if [[ -n "$worktree_path" ]]; then
    dispatch_cwd="$worktree_path"
  fi
  ```

  **New string (7 lines incl. 5-line invariant comment):**
  ```
  # After ENG-67, every reconcile_decision=="proceed" tick resolves a
  # per-issue worktree_path; the link:/human reconcile branches `exit 0`
  # at lines 177-205 before reaching here. So the previous fallback
  # `dispatch_cwd=$TARGET_REPO` is unreachable by construction. Surface
  # any future regression that lets worktree_path stay empty as a loud
  # failure rather than a silent dispatch into the operator's checkout.
  [[ -n "$worktree_path" ]] || die "internal: worktree_path empty after reconcile=proceed (ENG-67); refusing to dispatch from \$TARGET_REPO"
  dispatch_cwd="$worktree_path"
  ```

  Note the `\$TARGET_REPO` backslash-escape inside the bash `die`
  argument — necessary so the message rendered to stderr contains
  the literal string `$TARGET_REPO` (per A-009; without the escape
  bash would expand the variable).

  **Path A.2 opt-out (per brainstorm §10 O-7).** If the reviewer
  opts for the strict literal AC, SKIP Task 2 entirely; file a
  sibling ticket with the brainstorm §10 O-7 recipe.

- [ ] **Step 2.2 — Syntactic check.** Run `bash -n bin/run-local.sh`
  and confirm exit 0.

- [ ] **Step 2.3 — Verify `dispatch_cwd` reader call sites
  unaffected.** Run `grep -n 'dispatch_cwd' bin/run-local.sh`. The
  output should show: one assignment line (`dispatch_cwd="$worktree_path"`)
  + the same 6 reader sites as before (240, 246, 270, 351, 352, 360
  — line numbers shifted by Task 1's net delta ~+3 lines). The
  pre-Task-2 `dispatch_cwd="$TARGET_REPO"` line is gone; the
  pre-Task-2 reassignment-when-set guard is gone. (Per A-003 the
  6 readers remain verbatim.)

### Task 3: Create `bin/run-local-content-test.sh` regression-pin

- `depends_on: [1, 2]`
- `touches: bin/run-local-content-test.sh (NEW)`

- [ ] **Step 3.1 — Create the test file** at
  `bin/run-local-content-test.sh` with the following content
  (per brainstorm D-002 sketch + A-014/A-015 sibling-test
  conventions). The test does NOT source `bin/run-local.sh` (per
  A-013 — no sentinel pattern); it operates on the file as text
  via `awk` + `grep`.

  ```bash
  #!/usr/bin/env bash
  # Regression-pin: run-local.sh must not contain the legacy `feature/*`
  # coexistence path (deleted ENG-67, May 2026). The path silently
  # dispatched agents into $TARGET_REPO when a non-canonical
  # `feature/eng-N-...` branch existed, mutating the operator's HEAD
  # and breaking scope-check (May-2026 ENG-63/64/65 incident).
  # PR #48 (commit 4635cd3) closed the upstream cause at the prompt
  # level; this test pins the orchestrator side.
  set -uo pipefail
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  RUN_LOCAL="$SCRIPT_DIR/run-local.sh"
  [[ -f "$RUN_LOCAL" ]] || { printf 'FAIL: missing %s\n' "$RUN_LOCAL" >&2; exit 1; }

  PASS=0; FAIL=0
  ok()   { printf 'OK: %s\n' "$1"; PASS=$((PASS + 1)); }
  nope() { printf 'FAIL: %s — %s\n' "$1" "$2" >&2; FAIL=$((FAIL + 1)); }

  # Strip comment lines (lines whose first non-blank char is `#`) before
  # scanning. The deletion-site comment in run-local.sh legitimately
  # cites the historical `feature/*` failure mode in prose; that
  # citation is documentation, not code. Only flag a re-introduction
  # in executable lines.
  non_comment="$(awk '!/^[[:space:]]*#/ && !/^[[:space:]]*$/' "$RUN_LOCAL")"

  if printf '%s\n' "$non_comment" | grep -qF 'feature/'; then
    nope 'no feature/ token in non-comment lines' \
      'legacy feature/* coexistence appears to be re-introduced; see ENG-67'
  else
    ok 'no feature/ token in non-comment lines (ENG-67)'
  fi

  if printf '%s\n' "$non_comment" | grep -qF 'legacy feature'; then
    nope 'no "legacy feature" phrase in code' \
      'legacy detection log line re-introduced; see ENG-67'
  else
    ok 'no "legacy feature" phrase in non-comment lines'
  fi

  if printf '%s\n' "$non_comment" | grep -qF 'using old flow'; then
    nope 'no "using old flow" log line' \
      're-introduction of legacy coexistence; see ENG-67'
  else
    ok 'no "using old flow" log line'
  fi

  # After ENG-67 D-003, dispatch_cwd assignment must always derive
  # from a resolved worktree_path — never default to $TARGET_REPO as
  # a soft fallback. Pin this directly with an anchored ERE so a
  # benign assignment like `dispatch_cwd="$TARGET_REPO_FOO"` does NOT
  # trip the test — only the exact pre-D-003 fallback shape matches.
  if printf '%s\n' "$non_comment" | grep -qE 'dispatch_cwd="\$TARGET_REPO"'; then
    nope 'dispatch_cwd never silently falls back to $TARGET_REPO' \
      'soft fallback re-introduced; see ENG-67 D-003'
  else
    ok 'dispatch_cwd does not silently fall back to $TARGET_REPO'
  fi

  printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
  exit $(( FAIL > 0 ? 1 : 0 ))
  ```

  **Path A.2 opt-out (per brainstorm §10 O-7).** If the reviewer
  opts for Path A.2 (D-001 + D-002 only, no D-003), DROP the
  fourth grep-case (the `dispatch_cwd="\$TARGET_REPO"` ERE check)
  and ship grep-cases 1-3 only. The file remains valid; pre-commit
  glob still picks it up.

- [ ] **Step 3.2 — Make executable.** Run `chmod +x
  bin/run-local-content-test.sh`. (Per repo convention, `bin/*-test.sh`
  files are executable; see e.g. `ls -l bin/run-local-helpers-adversarial-test.sh`.)

- [ ] **Step 3.3 — Run it.** Execute `bash bin/run-local-content-test.sh`
  and confirm output ends with `4 passed, 0 failed` (or `3 passed,
  0 failed` under Path A.2) and exit 0. If any case fails, the
  error message names the offending grep hit and references ENG-67
  — fix Tasks 1 and 2 to match.

### Task 4: Add 2-sentence operator note to `CLAUDE.md` "Per-issue state directory" §

- `depends_on: []`
- `touches: CLAUDE.md (between line 217 and line 219)`

- [ ] **Step 4.1 — Append the operator-recognition paragraph** at
  the end of the "Per-issue state directory" section in `CLAUDE.md`,
  AFTER the existing closing paragraph (lines 214-217 ending with
  `branch-head SHA.`) and BEFORE the next H2 (`## Sweep + scope
  partition (ENG-14)` at line 219).

  Use the Edit tool with the following old/new strings.

  **Old string (the section's current closing paragraph):**
  ```
  `issue-state.json` is the durable state for the skip-label dance — `poll.sh` reads it on
  every tick and includes/excludes the issue based on `policy` plus a recomputed
  `pipeline_content_hash` (sha256 over `bin/**`, `config.json`, `AGENT_PROMPTS.md`) and
  branch-head SHA.

  ## Sweep + scope partition (ENG-14)
  ```

  **New string (adds a 2-sentence paragraph in between):**
  ```
  `issue-state.json` is the durable state for the skip-label dance — `poll.sh` reads it on
  every tick and includes/excludes the issue based on `policy` plus a recomputed
  `pipeline_content_hash` (sha256 over `bin/**`, `config.json`, `AGENT_PROMPTS.md`) and
  branch-head SHA.

  The harness orchestrator NEVER dispatches an agent into the operator's `$TARGET_REPO`
  checkout — every dispatch resolves a per-issue worktree first (ENG-67, May 2026). If
  `bin/run-local.sh` ever logs `FATAL: internal: worktree_path empty after
  reconcile=proceed (ENG-67); refusing to dispatch from $TARGET_REPO`, that is the
  D-003 invariant `die`-ing — most likely a Linear-API outage in `branch-name.sh`,
  which now blocks ticks loudly rather than silently dispatching from the operator's
  checkout. Operator action: inspect `$PROJECT_STATE_DIR/<slug>/logs/local-*.log` for
  the preceding error from `branch-name.sh`/`linear.sh`, fix the underlying cause
  (network, API key, Linear status), and the next tick resumes; do NOT bypass the
  `die` by re-introducing a soft fallback.

  ## Sweep + scope partition (ENG-14)
  ```

  **Path A.2 opt-out (per brainstorm §10 O-7).** If the reviewer
  opts for Path A.2 (no D-003), SKIP Task 4 — there is no `die` to
  point at. The "Per-issue state directory" § stays untouched.

### Task 5: Run the full test gate

- `depends_on: [1, 2, 3, 4]`
- `touches: (verification only — no file edits)`

- [ ] **Step 5.1 — Syntactic checks.** Run:
  ```
  bash -n bin/run-local.sh
  bash -n bin/run-local-content-test.sh
  ```
  Both must exit 0.

- [ ] **Step 5.2 — Run the new test.** Run
  `bash bin/run-local-content-test.sh`. Must exit 0 with output
  ending `4 passed, 0 failed` (Path A.1) or `3 passed, 0 failed`
  (Path A.2).

- [ ] **Step 5.3 — Run sibling tests that touch the same neighborhood.**
  Run:
  ```
  bash bin/run-local-helpers-adversarial-test.sh
  bash bin/run-local-sweep-test.sh
  bash bin/agent-prompts-content-test.sh
  ```
  All must exit 0. Tests should be unaffected by D-001/D-003
  (per A-014/A-015 they source `bin/run-local-helpers.sh` not
  `bin/run-local.sh`; A-016 unchanged).

- [ ] **Step 5.4 — Run the full bin/*-test.sh suite via
  `.githooks/pre-commit`.** Run
  `bash .githooks/pre-commit` and confirm it exits 0 with the new
  `bin/run-local-content-test.sh` listed in the test count and
  reporting OK. The hook also performs unrelated `core.bare`
  self-heal + GIT_*-env strip; both are no-ops on a clean
  worktree.

- [ ] **Step 5.5 — Secret-probe lint.** Run
  `bash bin/secret-probe-lint.sh`. Must exit 0 — neither this
  plan's edits nor the new test reference any secret-shaped env
  var (per ENG-46 / CLAUDE.md secret-handling §).

- [ ] **Step 5.6 — Smoke commit + commit hook.** Stage Tasks 1-4's
  edits with `git add bin/run-local.sh bin/run-local-content-test.sh
  CLAUDE.md docs/plans/2026-05-07-eng-67-...md` (the plan doc is
  staged at the planning stage's exit; the orchestrator's partition
  sweep takes care of the rest). Commit with the message
  `fix(ENG-67): delete legacy feature/* coexistence path in run-local.sh`.
  The pre-commit hook re-runs the full suite; commit succeeds iff
  every test passes.

## Frontend Tasks

No UI surface; the harness has no frontend. **No frontend tasks.**

## Failure Mode → Test Map

Pulled from brainstorm §"Edge cases" (rows 1-7) and §"Error handling"
(rows 8-13). Each row binds to a concrete test.

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
|---|---|---|---|---|
| Legacy `feature/*` detection block re-introduced into `bin/run-local.sh` | A future edit re-adds the `if [[ -n "$(git ... feature/${ident_lower}-*) ... ]]` shape | Test fails at `feature/`-token grep + `legacy feature` grep + `using old flow` grep | unit | `bin/run-local-content-test.sh` cases 1-3 |
| `dispatch_cwd="$TARGET_REPO"` soft fallback re-introduced | A future edit re-adds the soft default before the `if [[ -n "$worktree_path" ]]` guard | Test fails at the anchored ERE `dispatch_cwd="\$TARGET_REPO"` grep | unit | `bin/run-local-content-test.sh` case 4 |
| `worktree_path` empty after `reconcile=proceed` (D-003 invariant trip) | A hypothetical future edit lets `proceed` exit `branch-name.sh` or `resolve_worktree_path` early without setting `worktree_path` | `die` exits 1 with `FATAL: internal: worktree_path empty after reconcile=proceed (ENG-67); refusing to dispatch from $TARGET_REPO`; trap releases lock; FAIL_COUNTER NOT incremented (fires before dispatch line 246) | smoke | `bash -n bin/run-local.sh` confirms syntactic validity; behavioral coverage deferred per O-2 |
| Both `feat/eng-N-…` AND `feature/eng-N-…` exist on origin | Operator or pre-PR48 agent created both | Canonical resolution picks `feat/eng-N-…` (per A-006: `refs/heads/$branch` then `refs/remotes/origin/$branch`); `feature/…` ignored; no collision | unit | covered indirectly by `bin/run-local-content-test.sh` case 1 (no orchestrator code path inspects `feature/`) |
| Only `feature/eng-N-…` exists on origin (no canonical) | Pre-PR48 agent's stale ref | `ensure_worktree` falls into the third branch (per A-006); creates fresh worktree from `origin/main` on a new local `feat/eng-N-…` branch; legacy ref left alone | unit | covered indirectly by case 1 (no `feature/`-detection code path remains) |
| Operator manually creates a `feature/eng-N-foo` branch in `$TARGET_REPO` for unrelated work | Operator side activity | Orchestrator ignores it (no detection code); operator branch untouched | unit | case 1 |
| `feature/<non-issue-shape>` substring (e.g. `feature/build-XYZ`) | Some unrelated work | Pre-D-001 `feature/${ident_lower}-*` glob never triggered for non-issue shapes either; behavior unchanged | unit | case 1 (broader pin than glob) |
| Agent emits `git checkout -B feature/eng-N-…` mid-dispatch (the bypass class) | Misbehaving agent in implementing/qa stage | Dispatch happens inside `$PROJECT_STATE_DIR/ENG-N/worktree`, NOT `$TARGET_REPO`; `git checkout -B` lands in worktree's git config; operator main HEAD untouched; subsequent scope-check rc=2; halt fires; standard recovery via `bash bin/pipeline.sh decide --action continue` | integration | covered by D-001 deletion (existing scope-check / halt-recovery behavior is the test); `bin/agent-prompts-content-test.sh:447-491` pins the prompt-side defense (PR #48); `bin/run-local-content-test.sh` cases 1-3 pin the orchestrator-side surface |
| `branch-name.sh` failure inside the new unconditional path (Linear API outage) | Linear API down or stale token | `branch-name.sh:22` dies with `could not fetch title for ENG-N`; tick blocks loudly; FAIL_COUNTER NOT incremented (fires before dispatch); next tick retries | smoke | `bash -n bin/run-local.sh` confirms post-D-001 unconditional `branch-name.sh` call is syntactically present; behavioral coverage deferred to O-2 |
| `ensure_worktree` failure (git error) | Disk full, ref corruption, etc. | `ensure_worktree` dies on any internal git command (set -e); trap releases lock | smoke | unchanged from pre-ENG-67 behavior; A-006 |
| `$TARGET_REPO` itself is bare (`core.bare=true`) | Test-fixture leak per ENG-68 | `bin/run-local.sh:72-81` self-heals at tick start (pre-existing) | unit | covered by ENG-68's existing `bin/run-local-helpers-adversarial-test.sh` cases (A-014); ENG-67 unaffected |
| Tick fires for `link:`/`human` reconcile decision | Brainstorm/plan stage with existing canonical doc | `bin/run-local.sh:177-205` `exit 0` BEFORE worktree resolution (per A-004); D-001/D-003 not reached; no-op | smoke | `bash -n bin/run-local.sh` confirms `case` arms preserved |
| Pre-commit hook installation lag — new test exists but `.githooks/pre-commit` not yet active | Operator forgot to run `bin/install-git-hooks.sh` | Standard install path; until then, test runs only on manual invocation | n/a | A-017; not a code change |

## Test Strategy

### Unit / Content tests (D-002)

The new `bin/run-local-content-test.sh` is the primary regression
guard. Four grep-cases (or three under Path A.2):

1. `feature/` token absent in non-comment lines (D-001 trigger pin).
2. `legacy feature` phrase absent in non-comment lines (D-001 log
   line pin).
3. `using old flow` phrase absent (D-001 log line pin, redundant
   with 2 but cheap).
4. `dispatch_cwd="\$TARGET_REPO"` anchored ERE absent (D-003
   mechanism pin; Path A.1 only).

The `awk` pre-filter (`!/^[[:space:]]*#/ && !/^[[:space:]]*$/`)
strips comment lines so the deletion-site comment's prose
references to `feature/*` (in the citation chain) do not
false-trip the test. Test design caveat (per brainstorm
feasibility-P1-4): a heredoc body or a here-string with literal
`feature/` would also strip — future contributors must use prose
indirection (`feature-slash-star`) or rebase the citation if
adding a new prose reference.

### Sibling tests (existing, untouched)

`bin/run-local-helpers-adversarial-test.sh` and
`bin/run-local-sweep-test.sh` source `run-local-helpers.sh` (not
`run-local.sh`); their `partition_dirty_paths` cases are unaffected
by D-001/D-003. `bin/agent-prompts-content-test.sh:447-491` pins
the prompt-side branch-name convention; unaffected (D-001 is
orchestrator-side only). All three should run green pre/post the
ENG-67 edits.

### Smoke (syntactic) tests

`bash -n bin/run-local.sh` after Tasks 1 and 2 confirms the file
remains valid bash. The pre-commit hook glob picks up the new
content test automatically (A-017); `bash .githooks/pre-commit`
runs the full suite end-to-end.

### Adversarial / E2E coverage (deferred)

Per brainstorm §10 O-2 / O-3, behavioral end-to-end coverage of
the dispatch path (faking a `feature/eng-99-foo` branch on stub
origin and asserting `dispatch_cwd` resolves to
`$PROJECT_STATE_DIR/ENG-99/worktree`) is multi-hundred LOC of
stub scaffolding for the same regression-class coverage the
content test provides at ~50 LOC. Deferred. The brainstorm
documents this as an explicit non-goal; do not add behavioral
coverage as part of this ticket's scope.

### Test gate (committed to in §"Goal")

```
bash bin/run-local-content-test.sh \
  && bash bin/run-local-helpers-adversarial-test.sh \
  && bash bin/run-local-sweep-test.sh \
  && bash bin/agent-prompts-content-test.sh \
  && bash -n bin/run-local.sh \
  && bash bin/secret-probe-lint.sh
```

This is the minimal pre-merge verification surface. The
pre-commit hook (`bash .githooks/pre-commit`) is a strict
superset and is the canonical run-it-all gate.

## Self-review summary (5 personas)

Five personas dispatched via the document-review skill against
this plan: feasibility, scope, coherence, design, product.

### Iteration 1

| Persona | Verdict | P0 | P1 |
|---|---|---|---|
| feasibility | PASS | 0 | 0 |
| scope | PASS | 0 | 0 |
| coherence | PASS | 0 | 3 |
| design | PASS | 0 | 2 |
| product | PASS | 0 | 2 |

**Status:** Personas: 5/5 PASS · gate P0: 0 · proceeding to implementing.

Gate criterion (≥4/5 PASS, zero P0) cleared at iteration 1.
P1 advisories below are recorded for transparency; none rise
to a blocking concern.

The brainstorm carried 6/6 PASS at iteration 2 with no unresolved
P0; this plan is a faithful crystallisation of brainstorm §4
decisions D-001/D-002/D-003/D-004 (Path A.1) with all
codebase-fact assumptions re-verified against the current
worktree at the time of plan-writing. Path A.2 opt-out is
preserved as a reviewer-callable simplification per brainstorm
§1's split flag and §10 O-7's sibling-ticket recipe (now also
summarised at the top of §"Backend Tasks" per product-P1-2).

Persona findings:

- **feasibility (PASS, 0 P0, 0 P1).** All 22 modified-file
  assumptions (A-001 through A-021) `path:line`-cited against
  current code via Read/Grep on this worktree. Edit `old_string`
  blocks in Tasks 1.2, 2.1, and 4.1 verified to match the current
  file byte-for-byte (whitespace, braces, escapes). `depends_on`
  graph is correct.

- **scope (PASS, 0 P0, 0 P1).** Every File Structure entry traces
  to a brainstorm decision (D-001, D-002, D-003, D-004); no
  gold-plating. The 13-line replacement comment vs. the issue's
  literal "one-line comment" AC is explicitly flagged as a
  Path A.1 elaboration with Path A.2 opt-out. No
  forbidden-touch violations.

- **coherence (PASS, 0 P0, 3 P1, recorded not folded).**
  - P1: Plan Goal §1 cites `bin/run-local.sh:209-226`; brainstorm
    §1 standardises on `213-226` for the legacy block (with
    `209-226` for the wider span including the comment header).
    Plan uses `209-226` consistently throughout — internally
    coherent, cosmetic vs. brainstorm.
  - P1: D-004 brainstorm §2 wording said "Failure-mode quick
    reference"; brainstorm §4 D-004 verdict reconciled to
    "Per-issue state directory" §. Plan correctly follows §4.
    Internally coherent.
  - P1: Task 3's `depends_on: [1, 2]` becomes `[1]` under Path A.2;
    addressed by adding the explicit Path A.2 opt-out summary
    table at top of §"Backend Tasks" (showing the dependency
    re-targeting alongside the task skip).

- **design (PASS, 0 P0, 2 P1, recorded not folded).**
  - P1: New content test uses `set -uo pipefail` (matching
    `run-local-helpers-adversarial-test.sh`'s convention) rather
    than `set -euo pipefail` (matching `run-local-sweep-test.sh`'s).
    Either is acceptable for this test's structure; the
    `-e`-absent variant is intentional parity with adversarial-test.
  - P1: New test deliberately omits `source common.sh` since it is
    text-only (per A-013 — `bin/run-local.sh` has no sentinel,
    sourcing it would fire `main`); this is correct, called out
    in the test header comment.

- **product (PASS, 0 P0, 2 P1, partly folded).**
  - P1 (folded): Path A.2 opt-out is documented at every
    reviewer-callable site but was not summarised in one place.
    Folded — added the Path A.2 reviewer opt-out single-place
    summary table at the top of §"Backend Tasks".
  - P1 (recorded): the issue's three-bullet AC mapping is sound
    but spread across Goal §1-§4. Defensible — the Goal section's
    structure mirrors the brainstorm's Decisions §, and the
    Path A.1 vs. A.2 split flag in the same Goal text makes the
    AC-bullet mapping explicit without a separate table.
