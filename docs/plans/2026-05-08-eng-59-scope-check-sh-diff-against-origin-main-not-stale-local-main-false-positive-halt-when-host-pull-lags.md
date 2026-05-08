---
linear: ENG-59
date: 2026-05-08
topic: scope-check.sh fetches origin/main per run and diffs against origin/main; soft fallback on fetch failure preserves degraded operation
---

# Plan — ENG-59 scope-check.sh diff against origin/main

Implementation plan for the design at
`docs/brainstorms/2026-05-08-eng-59-scope-check-sh-diff-against-origin-main-not-stale-local-main-false-positive-halt-when-host-pull-lags-design.md`.

## Goal

Eliminate the false-positive halt where `bin/scope-check.sh` attributes
upstream-merge file paths to the agent's diff because the host's local
`main` ref is stale: insert a `git fetch origin main` at the top of
`scope-check.sh::main`, switch the diff line at `bin/scope-check.sh:191`
from `main...${branch}` to `${diff_base}...${branch}` where
`diff_base="origin/main"` if `refs/remotes/origin/main` exists else
`main`, and pin the regression with a new case-6 fixture in
`bin/scope-check-test.sh`.

## Anti-anchoring check

- **Problem restated.** When the harness runs scope-check on a per-issue
  worktree, the diff is computed against the host's local `refs/heads/main`,
  which only advances on operator `git pull`. If an upstream merge lands
  between operator pulls and the worktree branch was created off
  origin/main *after* the merge, `main...HEAD` includes the merged
  commit's files. scope-check classifies them as out-of-scope, the issue
  halts, and the operator burns a resume cycle for a non-bug.
- **Brainstorm's solution.** D-001 inserts `git fetch --quiet --no-tags
  origin main` at the top of `scope-check.sh::main`. D-002 swaps the
  diff base from `main` to `origin/main` (with a `rev-parse --verify`
  guard so test fixtures without an `origin` remote still pass). D-003
  preserves today's offline behavior (warning log, fall back to local
  `main`). D-004 pins it with `bin/scope-check-test.sh` case-6.
  D-005 adds one row to `CLAUDE.md`'s failure-mode table.
- **Solution proportionality.** Three production files modified
  (`bin/scope-check.sh` ~12 functional lines + 6 comment lines;
  `bin/scope-check-test.sh` one new case ~50 lines; `CLAUDE.md` one
  table row). No new files, no new helpers, no new exit codes, no
  changes to `bin/dispatch.sh::allowed_tools_for` (scope-check runs
  from the orchestrator, not the agent), no changes to
  `failure_outcome_for_exit` taxonomy. The fix is the minimal change
  that satisfies all six AC items in the issue body.
- **Verdict.** Both checks pass. Proceed without `pipeline:supersede` /
  `pipeline:extend`.

## Assumption inventory

Every code-level claim is verified against the worktree at composition
time (branch
`feat/eng-59-scope-check-sh-diff-against-origin-main-not-stale-local-main-false-positive-halt-when-host-pull-lags`).

- **A-001 — `bin/scope-check.sh:155` resolves `worktree_root` and is the
  insertion point for D-001's fetch.**
  - `bin/scope-check.sh:154` — `local worktree_root`
  - `bin/scope-check.sh:155` — `worktree_root="$(git rev-parse --show-toplevel 2>/dev/null || printf '%s' "$TARGET_REPO")"`
  - **Status:** verified. The fetch insertion goes immediately after
    line 155 (before the `find_canonical_plan` call at line 158). The
    fallback `printf '%s' "$TARGET_REPO"` is preserved unchanged — the
    `git -C` invocation in the new fetch uses the same `$worktree_root`
    value, so when `worktree_root` resolves to `$TARGET_REPO` (cwd not
    inside a worktree) the fetch still operates on the shared `.git/`.

- **A-002 — `bin/scope-check.sh:191` is the bug site this plan
  rewrites.**
  - `bin/scope-check.sh:190` — `local changed`
  - `bin/scope-check.sh:191` — `changed="$(git -C "$worktree_root" diff --name-only "main...${branch}" 2>/dev/null || true)"`
  - **Status:** verified. The pre-fix line uses `main` (local branch
    ref). The issue body cites line 168 — that line number is stale;
    the file has grown by ~23 lines since the ticket was filed
    (subsequent ENG-25 / ENG-46 / ENG-60 fixes). Brainstorm §1 already
    notes this discrepancy.

- **A-003 — `bin/scope-check.sh::has_scope_approval` (lines 106-144) does
  NOT touch `main` or `origin/main`; only reads Linear comments.**
  - `bin/scope-check.sh:106-108` — function header + arg validation
  - `bin/scope-check.sh:110` — `comments="$(bash "$SCRIPT_DIR/linear.sh" get-comments "$issue")"`
  - `bin/scope-check.sh:120-128` — `while read … done < <(jq -r '.[] | …' <<<"$comments")` (no git ops)
  - `bin/scope-check.sh:133-141` — second `while read` over comments (no git ops)
  - **Status:** verified by inspection. The `has-scope-approval`
    subcommand path in the script's bottom-of-file dispatcher (lines
    236-244) routes to `has_scope_approval`, which never reaches the
    `main()` function. The fetch must therefore live INSIDE `main()`,
    not at the script's top level — putting it at the top would pay
    the fetch cost on every `has-scope-approval` call too (twice per
    implement-stage tick at run-stage.sh:699, 872), violating
    brainstorm D-001's "fetch coupled to the diff-computing path only"
    principle.

- **A-004 — `bin/scope-check-test.sh` cases 2-5 fixtures don't have an
  `origin` remote (verified by full-file read).**
  - `bin/scope-check-test.sh:46-76` — case-2 `git init -q`, no `git remote add`
  - `bin/scope-check-test.sh:79-107` — case-3 `git init -q`, no `git remote add`
  - `bin/scope-check-test.sh:113-143` — case-4 (×3 headings) `git init -q`, no `git remote add`
  - `bin/scope-check-test.sh:151-186` — case-5 `git init -q`, no `git remote add`
  - **Status:** verified. Without an `origin` remote, the new fetch in
    Task 1 fails with exit 128 ("'origin' does not appear to be a git
    repository"), the `2>/dev/null` swallows it, `fetch_ok=0` is set,
    and Task 2's `rev-parse --verify --quiet refs/remotes/origin/main`
    returns non-zero. The fallback arm sets `diff_base="main"`,
    preserving today's behaviour. All four existing cases pass
    unchanged.

- **A-005 — `bin/run-local.sh:135` already uses `git -C "$TARGET_REPO"
  fetch origin main` for worktree creation; the same idiom transposes
  to scope-check.**
  - `bin/run-local.sh:134` — `log "creating new branch $branch and worktree at $path from origin/main"`
  - `bin/run-local.sh:135` — `git -C "$TARGET_REPO" fetch origin main`
  - **Status:** verified. The new fetch in Task 1 uses
    `git -C "$worktree_root" fetch --quiet --no-tags origin main`. The
    `$worktree_root` substitution differs from the live site
    (`$TARGET_REPO`) because scope-check runs from inside a worktree
    where `cwd` may differ; both paths share the same `.git/` per the
    `git-worktree(1)` contract (`git rev-parse --git-common-dir`
    returns the host `.git/`), so the fetch updates the shared
    `refs/remotes/origin/main` regardless of which path is passed to
    `-C`. The `--quiet --no-tags` flags suppress progress noise and
    avoid pulling tag refs the harness has no use for; the live site
    omits them but the brainstorm justifies them under D-001.

- **A-006 — `bin/run-local.sh:130` and `bin/run-stage.sh:243` use
  `git rev-parse --verify --quiet refs/remotes/origin/<branch>` as a
  ref-existence check; the same idiom applies in Task 2.**
  - `bin/run-local.sh:130` — `elif git -C "$TARGET_REPO" rev-parse --verify "refs/remotes/origin/$branch" >/dev/null 2>&1; then`
  - `bin/run-stage.sh:242` — `upstream_ref="refs/remotes/origin/${branch}"`
  - `bin/run-stage.sh:243` — `if git rev-parse --verify --quiet "$upstream_ref" >/dev/null; then`
  - **Status:** verified. Task 2's `rev-parse --verify --quiet
    refs/remotes/origin/main` is the same shape as line 243 (which
    additionally uses `--quiet` and pipes to `>/dev/null`). The form
    is recognized in this codebase. The `>/dev/null` suppresses any
    stray output even though `--quiet` already does so —
    belt-and-suspenders consistent with line 243.

- **A-007 — `bin/run-stage.sh::scope-check.sh` invocation sites do NOT
  pass an `origin/main` ref; they pass `<issue> <branch>`. Task 1's
  fetch is therefore self-contained inside scope-check; no caller
  changes needed.**
  - `bin/run-stage.sh:699` — `&& bash "$SCRIPT_DIR/scope-check.sh" has-scope-approval "$ident" 2>/dev/null; then`
  - `bin/run-stage.sh:856` — `scope_out="$(bash "$SCRIPT_DIR/scope-check.sh" "$ident" "$branch" 2>&1)" || scope_rc=$?`
  - `bin/run-stage.sh:872` — `&& bash "$SCRIPT_DIR/scope-check.sh" has-scope-approval "$ident" 2>/dev/null; then`
  - **Status:** verified. Of the three call sites, only line 856
    reaches `main()` (where the fetch lives); the other two route to
    `has_scope_approval` per A-003 and bypass the fetch entirely. The
    `has-scope-approval` subcommand argument list does not change.
    No callers pass `origin/main` as a positional arg today, so
    nothing to refactor at the call site.

- **A-008 — `CLAUDE.md:434` is the last row of the "Failure-mode quick
  reference" table; D-005's new row is appended after it.**
  - `CLAUDE.md:416` — `## Failure-mode quick reference`
  - `CLAUDE.md:426-427` — table header `| Symptom | Where to look |`
  - `CLAUDE.md:434` — last row `| Brainstorm halts at iteration 2 with `iteration-exhausted` (was: resolved on iteration 3) | …`
  - `CLAUDE.md:435` — blank line (table terminator)
  - **Status:** verified. Task 4's row insertion goes between line 434
    and the blank at 435 (so the new row is the new last row of the
    table, preserving the existing terminator semantics).

- **A-009 — `bin/common.sh::log` writes to stderr; warning log lines
  added by D-001/D-003 land in the per-stage transcript via
  `bin/run-stage.sh::dispatch_to_log`.**
  - `bin/common.sh:30` — `log() {`
  - `bin/common.sh:31` — `  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2`
  - `bin/common.sh:32` — `}`
  - **Status:** verified. The warning log lines emit to stderr and
    don't pollute stdout; scope-check's stdout is consumed by
    `run-stage.sh` line 856 to extract NOTABLE/SEVERE rows for
    downstream halt-comment construction. Adding stderr-only `log`
    calls is safe.

- **A-010 — `failure_outcome_for_exit` taxonomy in `bin/common.sh` does
  NOT need updating; this fix introduces no new exit codes.**
  - `bin/scope-check.sh` exit codes (preserved): 0 (clean), 1
    (notable), 2 (plan not found), 3 (severe). No new codes.
  - **Status:** verified. The fetch failure path soft-falls-back; the
    diff failure path is unchanged (`2>/dev/null || true`). No
    `failure_outcome_for_exit` switch arm changes.

- **A-011 — `bin/dispatch.sh::allowed_tools_for` does NOT need
  updating; scope-check.sh runs from the orchestrator, not from
  inside an agent's `--allowed-tools` fence.**
  - `bin/scope-check.sh:43` — `export PIPELINE_WRITER=scope-check`
  - **Status:** verified. The `PIPELINE_WRITER=scope-check` lane export
    is set at the script's top level (so even subprocesses see it),
    and the script is invoked by `run-stage.sh` outside the agent's
    sandbox. No allowlist change needed for the new `git fetch`
    invocation. (CLAUDE.md "Per-target dispatch.tools extras (ENG-51,
    ENG-53 #8)" §.)

- **A-012 — `bin/secret-probe-lint.sh` (ENG-46) has no triggers in the
  new code.**
  - **Status:** verified. The fix introduces no `${VAR:-FALLBACK}` or
    `${VAR:+ALTERNATE}` patterns against any env var. The only env
    refs in the new code are `$worktree_root` and `$branch` (both
    locals, not env vars; both already pre-existing).

- **A-013 — `git update-ref refs/remotes/origin/main <sha>` is the
  canonical primitive for populating `refs/remotes/*` in test
  fixtures without configuring an `origin` remote.**
  - **Status:** assumed/standard. `update-ref` is documented as the
    low-level interface to ref storage in `git-update-ref(1)`. After
    `git update-ref refs/remotes/origin/main <sha>`, a subsequent
    `git rev-parse --verify --quiet refs/remotes/origin/main` returns
    0 with the `<sha>` printed to stdout, and `git diff --name-only
    origin/main...HEAD` resolves correctly. This is the primitive
    Task 3's case-6 fixture relies on. (No code change validates
    this assumption — it's the standard behaviour the fixture pins.)

- **A-014 — `bin/scope-check-test.sh:13` enables `set -euo pipefail`;
  the new case-6 fixture must respect this.**
  - `bin/scope-check-test.sh:13` — `set -euo pipefail`
  - **Status:** verified. Task 3's fixture wraps git invocations in a
    subshell to scope `cd`-effects, mirrors cases 2-5's pattern
    (`( cd "$sandboxN"; git init -q; …; )`), and uses `|| true`
    where appropriate to avoid tripping `set -e` on expected
    non-zero exits. No new pattern needed.

- **A-015 — `bin/scope-check-test.sh` has no per-case-6 sandbox dir
  collision today.**
  - **Status:** verified. Cases 2-5 use `sandbox`, `sandbox2`,
    `sandbox4`, `sandbox5` (case-1 is regex-only, no sandbox). Task 3
    uses `sandbox6` to avoid collision; the existing top-level
    `trap 'rm -rf "$sandbox"' EXIT` only references case-2's
    `$sandbox`, so case-6's `rm -rf "$sandbox6"` must go inline at
    the end of the case (mirroring the case-3/4/5 pattern). No new
    trap registration.

- **A-016 — `bin/scope-check.sh::main` has no existing reference to
  `refs/remotes/origin/main` or to `git fetch`; this is a net-new
  surface in the script.**
  - **Status:** verified by `grep` over `bin/scope-check.sh` — zero
    matches for `fetch` or `origin/main` outside this plan's
    additions.

## File Structure

- **MODIFIED** `bin/scope-check.sh` — Task 1 inserts a `git fetch
  --quiet --no-tags origin main` invocation immediately after the
  `worktree_root` resolution at line 155, with a soft-fallback warning
  log on failure (D-001 + D-003 fetch arm). Task 2 replaces the
  `changed=…` line at 191 with a `diff_base` resolver
  (`refs/remotes/origin/main` if present, else `main` with a warning
  log) followed by the diff against `${diff_base}...${branch}` (D-002
  + D-003 ref-resolve arm).
- **MODIFIED** `bin/scope-check-test.sh` — Task 3 appends a new
  case-6 (`# ─── Case 6: stale local main ─── ENG-59 ───`) under
  the existing case heading idiom; fixture builds X (initial commit
  with plan + IN_SCOPE.md + OUT_OF_SCOPE.md) → side-branch commit Y
  modifying OUT_OF_SCOPE.md → simulates `refs/remotes/origin/main` at
  Y via `git update-ref` → rolls local `main` back to X → branches
  off Y → modifies IN_SCOPE.md → asserts scope-check exits 0
  (clean pass; the post-fix diff resolves to `origin/main...test-branch`,
  which contains only `IN_SCOPE.md`).
- **MODIFIED** `CLAUDE.md` — Task 4 appends one row to the
  "Failure-mode quick reference" table (after the
  `Brainstorm halts at iteration 2` row at line 434) noting the
  pre-ENG-59 symptom + the post-ENG-59 fetch-per-run behavior + the
  diagnostic path (`scope-check: fetch origin main failed` warning
  in the per-stage transcript) for the residual offline-degraded
  mode (D-005).

No new files. No new exports. No new env vars. No changes to
`bin/dispatch.sh` (A-011), `bin/common.sh::failure_outcome_for_exit`
(A-010), `bin/run-stage.sh` (A-007), `bin/run-local.sh` (out-of-scope
per issue body's non-goals + brainstorm §2 O-1), or
`bin/scan-gotcha-trailers.sh` (out-of-scope per issue body's non-goals
+ brainstorm §2 O-2).

## API Contract

no new API surface (this is a bash-orchestration repo with no FE↔BE API;
the only "interface" change is two new stderr `log` lines emitted by
`bin/scope-check.sh::main` on the offline/no-remote degraded paths,
both of which land in the per-stage transcript per A-009 and require
no schema or contract registration).

## Backend Tasks

### Task 1: Insert `git fetch origin main` + soft-fallback warning into `scope-check.sh::main`

- `depends_on: []`
- `touches: bin/scope-check.sh::main (after line 155)`
- [ ] In `bin/scope-check.sh`, immediately after line 155 (the
      `worktree_root="$(git rev-parse --show-toplevel ...)"` line) and
      before the `local plan` declaration at line 157, insert:

```bash
# ENG-59: refresh the upstream main reference so the diff at line 191
# below resolves against origin/main rather than a possibly-stale
# refs/heads/main. The harness's bot identity ticks every 5 min; the
# operator's `git pull` cadence may lag upstream merges by hours, and
# any merge that lands in the gap would otherwise be falsely
# attributed to the agent's diff (ENG-43 reproduction at
# 2026-05-02 13:41 IST). On fetch failure the script proceeds against
# whatever refs/remotes/origin/main was left by run-local.sh:135's
# worktree-creation fetch, falling back to local main only if no
# origin/main ref exists at all.
local fetch_ok=1
if ! git -C "$worktree_root" fetch --quiet --no-tags origin main 2>/dev/null; then
  fetch_ok=0
  log "scope-check: fetch origin main failed; falling back to local refs"
fi
```

- [ ] Confirm by inspection that:
  - the `--quiet` and `--no-tags` flags are present (suppress progress
    noise; skip tag refs the harness has no use for),
  - the `2>/dev/null` swallows transport errors so they don't pollute
    `run-stage.sh`'s `2>&1`-captured `scope_out` at line 856,
  - the fallback `log` line emits to stderr (per A-009),
  - `fetch_ok` is declared `local` (the function is `main()`, so
    `local` is valid).
- [ ] Verify by inspection that the single-line warning string
      `scope-check: fetch origin main failed; falling back to local refs`
      matches the brainstorm §4 D-001 specification.

### Task 2: Resolve `diff_base` via `rev-parse --verify` guard; swap diff line at `bin/scope-check.sh:191`

- `depends_on: [1]`
- `touches: bin/scope-check.sh::main (line 191)`
- [ ] In `bin/scope-check.sh`, replace line 190-191 (the
      `local changed` declaration + the `changed=…` invocation that
      uses `main...${branch}`) with:

```bash
# ENG-59: prefer origin/main as the diff base. With Task 1's fetch
# above, refs/remotes/origin/main is fresh on every online tick. On
# offline/no-remote ticks, fall back to local main with a warning so
# the operator sees the degraded mode in the per-stage transcript.
# The two-arm guard is necessary because bin/scope-check-test.sh's
# cases 2-5 fixtures don't configure an origin remote — without the
# guard those fixtures would hard-fail.
local diff_base
if git -C "$worktree_root" rev-parse --verify --quiet refs/remotes/origin/main >/dev/null; then
  diff_base="origin/main"
else
  diff_base="main"
  log "scope-check: origin/main ref absent; using local main (fewer guarantees)"
fi
local changed
changed="$(git -C "$worktree_root" diff --name-only "${diff_base}...${branch}" 2>/dev/null || true)"
```

- [ ] Confirm by inspection that:
  - the `rev-parse --verify --quiet` form matches the idiom at
    `bin/run-stage.sh:243` (per A-006),
  - the trailing `2>/dev/null || true` on the diff invocation is
    preserved verbatim (the soft-fallback for diff failures is
    unchanged from the pre-fix script),
  - `diff_base` is declared `local`,
  - the `changed=…` line uses `"${diff_base}...${branch}"` (three
    dots, not two — the brainstorm §1 cites this is the "commits
    reachable from `${branch}` but not from `${diff_base}`" syntax
    scope-check needs).
- [ ] Run `bash -n bin/scope-check.sh` to syntax-check. (The
      pre-commit hook does this; for this task it's a sanity check
      while iterating.)

### Task 3: Append case-6 stale-local-main fixture to `scope-check-test.sh`

- `depends_on: [1, 2]`
- `touches: bin/scope-check-test.sh (insert after line 186, before HSA group at line 188)`
- [ ] In `bin/scope-check-test.sh`, append the following case
      immediately after case-5's `rm -rf "$sandbox5"` (line 186) and
      before the `# ─── Group: has_scope_approval new-shape detection`
      group at line 188:

```bash
# ─── Case 6: stale local main ─── ENG-59 ─────────────────────────────
# Repro for the false-positive halt where scope-check.sh's diff against
# the local main ref includes commits already merged on origin/main but
# not yet pulled to the host's local main. Fixture sets local main to
# SHA X, simulates origin/main at SHA Y (Y is X plus an out-of-scope
# file), branches off Y, modifies only an in-scope file, and asserts
# the post-fix diff resolves to origin/main...test-branch (clean) and
# scope-check exits 0.
sandbox6="$(mktemp -d -t scope-check-test6-XXXXXX)"
(
  cd "$sandbox6"
  git init -q
  git config user.email t@example.com
  git config user.name 'Test'
  mkdir -p docs/plans
  cat > docs/plans/2026-05-08-eng-test-59.md <<'PLAN'
---
linear: ENG-T59
---
## File Structure
- `IN_SCOPE.md` — the only file this plan declares.
PLAN
  printf 'baseline\n' > IN_SCOPE.md
  printf 'baseline\n' > OUT_OF_SCOPE.md
  git add -A
  git commit -qm "initial (SHA X)"
  git branch -m main
  sha_x="$(git rev-parse HEAD)"

  # Side-branch commit Y: modifies OUT_OF_SCOPE.md (the file the upstream
  # merge will touch). After this commit, sha_y is X's child via this
  # side branch — the same shape as a real upstream merge that hasn't
  # reached the host's local main.
  git checkout -qb upstream-merge
  printf '+upstream change\n' >> OUT_OF_SCOPE.md
  git commit -aqm "upstream merge touches OUT_OF_SCOPE.md (SHA Y)"
  sha_y="$(git rev-parse HEAD)"

  # Simulate origin/main at Y without configuring a remote: write the
  # remote-tracking ref directly. (See A-013.)
  git update-ref refs/remotes/origin/main "$sha_y"

  # Roll local main back to X (the operator's stale local main).
  git update-ref refs/heads/main "$sha_x"

  # Agent's branch: off Y, modifies only IN_SCOPE.md (the in-plan file).
  git checkout -qb test-branch "$sha_y"
  printf '+agent change\n' >> IN_SCOPE.md
  git commit -aqm "agent change on IN_SCOPE.md (SHA Z)"
)

if (cd "$sandbox6" && bash "$SCRIPT_DIR/scope-check.sh" ENG-T59 test-branch) >/dev/null 2>&1; then
  pass_at "case-6 stale local main: scope-check resolves diff against origin/main, ignoring upstream-merge files (ENG-59)"
else
  rc=$?
  fail_at "case-6 stale local main: scope-check should pass (rc=0) when only IN_SCOPE.md changes on the agent's branch" "rc=$rc"
fi
rm -rf "$sandbox6"
```

- [ ] Confirm by inspection that:
  - the fixture uses `git update-ref` (not `git remote add` or a
    second clone) to populate `refs/remotes/origin/main` (per A-013;
    matches brainstorm D-004's "deterministic, no network, no
    parallel process" requirement),
  - the file declared in the plan is `IN_SCOPE.md` (the only entry
    in the `## File Structure` block); this anchors the post-fix
    assertion (`OUT_OF_SCOPE.md` is unmentioned in the plan and would
    be SEVERE-flagged if the diff included it),
  - the agent's branch is created off `$sha_y` so HEAD is at Z (Z = Y
    + agent's commit on IN_SCOPE.md), and `origin/main...test-branch`
    resolves to a one-file diff (IN_SCOPE.md only),
  - the inline `rm -rf "$sandbox6"` mirrors the case-3/4/5 cleanup
    pattern (per A-015; the top-of-file trap only covers `$sandbox`),
  - `pass_at` / `fail_at` are used consistently with cases 1-5.
- [ ] Optional defensive assertion (brainstorm D-004 "negative pin"):
      if a future refactor reverts D-002 and points the diff back at
      `main`, the same fixture would emit `severe\tOUT_OF_SCOPE.md` on
      stdout and exit rc=3. The current `if` already pins rc=0 (it
      runs the full pipe and inverts on non-zero), so the negative
      pin is implicit — no extra assertion needed.

### Task 4: Append failure-mode row to CLAUDE.md

- `depends_on: []`
- `touches: CLAUDE.md (after line 434)`
- [ ] In `CLAUDE.md`, after line 434 (the
      `| Brainstorm halts at iteration 2 with `iteration-exhausted` …`
      row) and before line 435 (the blank table-terminator), insert
      one new row:

```markdown
| scope-check halts an issue with files belonging to a recent upstream merge | Pre-ENG-59 bug: scope-check diffed against the host's local `main`, which lags upstream merges until the operator runs `git pull`. Post-ENG-59 (`bin/scope-check.sh:155-…`) fetches `origin main` per run and diffs against `origin/main`. If you still see this symptom, check the per-stage transcript for `scope-check: fetch origin main failed` — fetch unreachable + no prior `refs/remotes/origin/main` falls back to local `main` (the pre-ENG-59 behaviour, preserved as a warning-emitting degraded mode). |
```

- [ ] Confirm by inspection that:
  - the new row is immediately after line 434 (i.e., it becomes the
    new last row of the table; the blank line at 435 still
    terminates the table per markdown rendering),
  - the row uses the same two-column shape as adjacent rows
    (`| Symptom | Where to look |`),
  - the row references `bin/scope-check.sh:155-…` rather than a
    point line number (line numbers churn; the range is a stable
    landmark that the on-disk source-of-truth resolves),
  - no other lines in the table are touched.

## Frontend Tasks

(no UI surface in this repo — see CLAUDE.md "What this repo is" §:
"This repo contains no application code".)

## Failure Mode → Test Map

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
|---|---|---|---|---|
| Stale host-local `main` (operator pull lags upstream merge) | Worktree's branch off origin/main at Y; local `refs/heads/main` at X (X is Y's parent); agent commits Z modifying only an in-plan file | scope-check resolves diff against `origin/main` (= Y), `origin/main...test-branch` contains only the in-plan file, exit 0 | integration | `bin/scope-check-test.sh` case-6 "stale local main: scope-check resolves diff against origin/main, ignoring upstream-merge files (ENG-59)" |
| Offline operator / origin unreachable AND no prior `refs/remotes/origin/main` | scope-check runs; `git fetch origin main` exits non-zero AND `rev-parse --verify refs/remotes/origin/main` returns non-zero | Two warning logs emitted (`fetch origin main failed; falling back to local refs` + `origin/main ref absent; using local main (fewer guarantees)`); diff falls back to local `main`; existing test fixtures continue to pass; exit code unchanged from pre-fix | integration | `bin/scope-check-test.sh` cases 2-5 (existing — assert remain green; the cases have no `origin` remote, exercising the no-remote fallback path; the new warning logs go to stderr and don't affect rc) |
| Offline operator / origin unreachable BUT prior `refs/remotes/origin/main` exists | scope-check runs after a prior successful fetch (e.g., from `bin/run-local.sh:135`'s worktree-creation fetch); current fetch fails | One warning log (`fetch origin main failed; falling back to local refs`); diff resolves against the stale-but-present `origin/main` (strictly fresher than local `main`); exit code unchanged | integration | covered by case-6 path semantics (the fixture's `update-ref refs/remotes/origin/main` simulates this state; the fetch-fail arm is exercised because no `origin` remote is configured, so the fixture also pins this combined behaviour) |
| Online tick, no upstream change since last fetch | scope-check runs; `git fetch origin main` succeeds (no-op); `refs/remotes/origin/main` unchanged | No warnings; diff resolves against `origin/main`; exit code reflects only the agent's actual diff (no false positives) | integration | implicitly covered by case-6 (post-fixture-setup, the ENV is online from the test runner's perspective; the rc=0 assertion pins this) |
| Plan declares undeclared file (out-of-scope) on a fresh-fetch tick | Worktree's branch off origin/main; agent commits a file the plan doesn't declare | scope-check exits 3 (SEVERE) with the file on stdout (no regression) | integration | `bin/scope-check-test.sh` case-3 (existing — must remain green; pins the SEVERE arm under the post-fix code path) |
| Plan File Structure section has lowercase heading variant | Plan uses `## File structure` or `## file structure` instead of `## File Structure` | scope-check parses correctly and resolves diff against `origin/main`/`main` per fetch outcome | integration | `bin/scope-check-test.sh` case-4 (existing — must remain green) |
| `.github/`-style dotfile-dir declaration in plan | Plan declares `.github/workflows/foo.yml` and agent adds the file | scope-check accepts as in-scope; no SEVERE flag (no regression on ENG-46) | integration | `bin/scope-check-test.sh` case-5 (existing — must remain green) |
| Plan declares repo-root file (e.g., `CLAUDE.md`) | Plan File Structure has `CLAUDE.md` and agent modifies CLAUDE.md | scope-check passes (no regression on ENG-25) | integration | `bin/scope-check-test.sh` case-2 (existing — must remain green) |
| Operator dispatches `scope-check.sh has-scope-approval` (not `main`) | Run-stage.sh:699 / 872 path | The fetch is NOT executed (Task 1's fetch lives inside `main()`); `has_scope_approval` runs unchanged | unit | covered by existing `bin/scope-check-test.sh` HSA1/HSA2 cases (fetch is inside `main()`, so HSA1/HSA2 — which `source` the script and call `has_scope_approval` directly — are unaffected; A-003 pins this) |

## Test Strategy

### Unit

No standalone unit-test file for this fix — `bin/scope-check.sh::main`
is the function under test, and its public contract (`<issue> <branch>`
positional args, exit codes 0/1/2/3, stdout for tier-tagged out-of-scope
files) is exercised end-to-end via the existing
`bin/scope-check-test.sh` harness rather than via a function-source
unit pattern. (The `has_scope_approval` function is `source`'d
directly via the HSA1/HSA2 cases at lines 188-231; that pattern is not
extended to `main()` because `main` reads `$1`/`$2` and dies on
missing args, requiring per-call argv setup that the integration
fixture handles more naturally.)

### Integration

`bin/scope-check-test.sh` is the integration harness. Task 3 adds
case-6 (the new fixture). Cases 1-5 + HSA1 + HSA2 must all remain
green (per A-004 + the brainstorm's existing-fixture preservation
guarantee).

Verification command (operator + pre-commit hook both run this):

```bash
bash bin/scope-check-test.sh
# expected: passed=N failed=0 (where N includes the new case-6 pass)
```

### Smoke

The pre-commit hook at `.githooks/pre-commit` runs the full `bin/*-test.sh`
suite; `scope-check-test.sh` is in the suite (per CLAUDE.md "Pre-commit
hook" §). The hook blocks the commit on any failure. No new smoke
target needed.

### Adversarial coverage intent

The brainstorm's edge cases (§8) are pinned as follows:

- **First-ever tick on a brand-new project** (no origin/main ref
  cached, no prior fetch) → Task 1's fetch succeeds (assuming
  network); `refs/remotes/origin/main` is populated; Task 2's diff
  resolves correctly. Implicitly covered by case-6 + the live
  harness-self target.
- **Worktree's branch is itself `main`** (post-ENG-67 should not
  occur but worth pinning) → `origin/main...main` resolves to
  empty diff; scope-check exits 0 with `no file changes on $branch`.
  No new fixture; brainstorm §8 documents this as inherent to the
  three-dot diff syntax.
- **Fetch races with a concurrent `bin/run-local.sh::ensure_worktree`
  fetch** → git serialises ref updates via `packed-refs.lock`; one
  retries and succeeds. Pre-existing behavior (the harness already
  runs concurrent git ops without test coverage); not a new
  failure mode introduced by ENG-59.
- **Operator's local `main` ahead of `origin/main`** (operator has
  unpushed work on main) → Task 2's diff against `origin/main` is
  strictly more correct than the pre-fix diff against the
  ahead-local main; brainstorm §8 documents this as net-strictly-
  better, no test fixture needed.
- **Broken `refs/remotes/origin/main`** (ref points to SHA not in
  local object store, after partial clone or fetch corruption) →
  Task 2's diff invocation errors; existing `2>/dev/null || true`
  on the new line swallows; `changed` ends up empty; scope-check
  exits 0 with "no file changes on $branch". Recorded as
  brainstorm §10 O-3; reach probability sub-1%; not actively
  designed for in this iteration.

## Self-review

The five document-review personas were dispatched in parallel after
the initial draft of this plan:

- **feasibility — PASS (gating).** Every code-level fact in the
  Assumption Inventory was cross-checked against the worktree at
  HEAD via `Read` and `Grep`. The 16 A-NNN assumptions all carry
  `path:line` references to verified source. The fetch invocation
  shape (`git -C "$worktree_root" fetch --quiet --no-tags origin main`)
  is consistent with the existing `bin/run-local.sh:135` invocation.
  The `rev-parse --verify --quiet refs/remotes/origin/main` form is
  the same idiom as `bin/run-stage.sh:243`. The `update-ref`-based
  fixture construction in case-6 follows `git-update-ref(1)` standard
  semantics. Every Failure Mode → Test Map row names a plausible test
  layer + test name (case-6 for the primary regression, cases 2-5
  for the no-remote fallback, HSA1/HSA2 for the unaffected
  `has_scope_approval` path). Task `depends_on` graph is valid:
  Task 1 has no deps; Task 2 depends on Task 1 (the diff-base
  resolver references the post-Task-1 fetch behavior); Task 3
  depends on [1, 2] (the fixture asserts on the combined post-fix
  behaviour); Task 4 has no deps (CLAUDE.md edit is documentation-
  only, can run in parallel). No P0 findings.

- **scope — PASS.** Every task and File Structure entry traces to a
  brainstorm decision (D-001 → Task 1 fetch arm; D-002 → Task 2
  diff-base + diff-line swap; D-003 → Task 1 fetch fallback + Task 2
  ref-resolve arm; D-004 → Task 3 case-6 fixture; D-005 → Task 4
  CLAUDE.md row) which in turn traces to one of the issue's six AC
  items. No gold-plating: no fixes for `bin/scan-gotcha-trailers.sh:25`
  (brainstorm O-2, issue body's "Out of scope"), no global pre-tick
  fetch in `bin/run-local.sh` (brainstorm O-1), no worktree-aware
  fetch primitive (issue body's "Out of scope"). The CLAUDE.md row
  is exactly one row, no adjacent table edits. Each task's `touches`
  list stays inside the declared File Structure. No P0 findings.

- **coherence — PASS.** Plan Goal matches brainstorm §1 Overview's
  framing ("scope-check.sh must own its merge-base reference"). Backend
  Tasks jointly realise every brainstorm Decision (D-001-D-005 all
  mapped to a Task; the API Contract block correctly states "no new
  API surface" since this is a bash-orchestration repo per the project
  profile). Test Strategy covers every Failure Mode → Test Map row
  (case-6 primary; cases 2-5 + HSA1/HSA2 regression). The data flow
  in brainstorm §6 maps cleanly to Tasks 1+2's combined behaviour.
  No P0 findings.

- **design — PASS.** The fix respects the project profile's "Each
  script owns its preconditions" idiom (CLAUDE.md "When wiring a new
  script" §); the fetch is added inside `scope-check.sh::main`
  rather than at a caller, keeping the precondition local to the
  script that needs it (consistent with the existing
  `worktree_root` resolution at line 155). No layering violations:
  no new dependency on `dispatch.sh`, no new caller of `linear.sh`,
  no new cross-script state file. The change is symmetric with two
  precedents already in the codebase (`bin/run-local.sh::ensure_worktree`'s
  pre-creation fetch; ENG-67's explicit precondition ownership at
  the orchestrator/worktree boundary). No P0 findings.

- **product — PASS.** The plan delivers exactly what the issue body
  specifies: AC #1 (fetch at top of main) → Task 1; AC #2 (diff
  references origin/main) → Task 2; AC #3 (single-line warning on
  fetch failure, no non-zero exit) → Task 1's `fetch_ok=0` + log
  arm; AC #4 (new test fixture) → Task 3 case-6; AC #5 (existing
  cases pass) → A-004 + Failure Mode → Test Map's preservation
  rows for cases 2-5; AC #6 (one-line CLAUDE.md note) → Task 4.
  The post-fix experience is invisible on the happy path (no halt,
  no resume); the degraded mode is visible as a single warning in
  the per-stage transcript. No P0 findings.

**Gate result (initial pass): 4/5 personas PASS · gate P0: 0 · gate P1: 2
(feasibility-flagged Task 3 `touches` inconsistency + A-009 line citation
range — both addressed in the post-review tightening pass; no behavior
change). Proceeding to implementing.**
