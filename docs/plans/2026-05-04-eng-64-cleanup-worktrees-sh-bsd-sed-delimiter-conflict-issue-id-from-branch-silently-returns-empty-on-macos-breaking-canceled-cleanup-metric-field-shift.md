---
linear: ENG-64
date: 2026-05-04
topic: cleanup-worktrees.sh BSD sed delimiter fix + remove_tree metric field-shift fix + sentinel refactor
---

# Plan — ENG-64 cleanup-worktrees.sh sed/metric fix

Implementation plan for the design in
`docs/brainstorms/2026-05-04-eng-64-cleanup-worktrees-sh-bsd-sed-delimiter-conflict-issue-id-from-branch-silently-returns-empty-on-macos-breaking-canceled-cleanup-metric-field-shift-design.md`.

## Anti-anchoring

- **Problem (operator's words):** the periodic `bin/cleanup-worktrees.sh`
  sweep on macOS spams `RE error: parentheses not balanced` because
  `sed -nE 's|^(feat|fix)/(eng-[0-9]+)-.*|\2|pI'` uses `|` as both `s`
  delimiter and ERE alternation; BSD sed parses the second `|` as the
  closing delimiter. Two downstream effects: (1) Canceled-issue cleanup
  never fires; (2) `worktree-cleanup` JSONL records have `issue_id="merged"`
  and `stage="feat/eng-…"` because positional args are wrong.
- **Does the brainstorm address it?** Yes, with one load-bearing
  reframe: the AC #3 metric field-shift is **structural and
  independent** of the sed bug — `bin/cleanup-worktrees.sh:41` calls
  `metrics.sh worktree-cleanup "$3" "$branch" …` (passing `reason` in
  the `issue_id` slot and `branch` in the `stage` slot) regardless of
  whether `issue_id_from_branch` works. Brainstorm chose Path A
  (fix both as one PR; \~20 extra LOC) over Path B (file ENG-65
  fast-follow) because the structural shift is a one-character
  positional swap in the same file/range, and AC #3 explicitly asks
  for verification of the shape. This plan adopts Path A.
- **Proportional?** Yes. Total scope is one comma-delimiter swap
  (D-1), one `remove_tree` signature widening to accept `issue_id`
  + two call sites updated + one orphan-detected metric call rewritten
  (D-3), one sentinel/`main()` refactor that's a precondition for
  source-and-stub testing (D-4), one new test file with 10 cases (D-5),
  one \~5-line runbook append (D-6). No new files, no new dependencies,
  no `metrics.sh` changes, no `dispatch.sh` changes, no API surface.
- **No escalation needed.** The brainstorm's Path A vs Path B flag is
  a reversible call; this plan commits to Path A and the implement
  agent can elect to peel D-3 into ENG-65 only if the reviewer
  insists. Default execution is Path A.

## Goal

Restore `bin/cleanup-worktrees.sh` to working order on macOS BSD `sed`
AND fix the structural metric field-shift in `remove_tree` and the
orphan-detected event, locked by `bin/cleanup-worktrees-test.sh`
covering both contracts (regex + metric shape) — verifiable via
`bash bin/cleanup-worktrees-test.sh` exiting 0 with all ten cases
PASS, and `bash -n bin/cleanup-worktrees.sh` clean.

## Assumption Inventory

Every modified-file fact below is `path:line`-cited against the current
worktree per ENG-5 P-002 / B-001 (Rule P-002 in
`learned-rules/twinning/plan.md`). Assumptions marked `assumed/new`
identify the file where the artifact will be created.

### Modified files — current state and call sites

- **A-001 — `bin/cleanup-worktrees.sh:28` uses `sed -nE` with `|`
  delimiters and the `I` flag.** Verified at
  `bin/cleanup-worktrees.sh:28`:
  ```
  m="$(sed -nE 's|^(feat|fix)/(eng-[0-9]+)-.*|\2|pI' <<<"$branch" || true)"
  ```
  This is the literal one-line fix target named in AC #1.

- **A-002 — `bin/cleanup-worktrees.sh:33-42::remove_tree` does not
  receive `issue_id` from its callers.** Verified at
  `bin/cleanup-worktrees.sh:33-42`:
  ```
  remove_tree() {
    local path="$1" branch="$2" reason="$3"
    log "cleanup: removing worktree $path (branch=$branch, reason=$reason)"
    git -C "$TARGET_REPO" worktree remove --force "$path" 2>/dev/null || {
      log "cleanup: git worktree remove failed; forcing rm of $path"
      rm -rf "$path"
    }
    git -C "$TARGET_REPO" branch -D "$branch" 2>/dev/null || true
    bash "$SCRIPT_DIR/metrics.sh" worktree-cleanup "$3" "$branch" "success" 0 "path=$path"
  }
  ```
  Line 41 passes `"$3"` (= `reason`) in the `metrics.sh` `issue_id`
  slot and `"$branch"` in the `stage` slot — structural field-shift
  independent of the sed bug. The plan widens `remove_tree`'s
  signature to a fourth `issue_id` positional and rewrites line 41 to
  use the correct slots.

- **A-003 — `bin/cleanup-worktrees.sh:88` (orphan-detected metric)
  has the same field-shift bug.** Verified at
  `bin/cleanup-worktrees.sh:88`:
  ```
  bash "$SCRIPT_DIR/metrics.sh" worktree-orphan-detected "$branch" "cleanup" "warn" 0 "path=$path age_days=$age_days"
  ```
  `"$branch"` lands in the `issue_id` slot; `"cleanup"` lands in the
  `stage` slot. Same five-line range as A-002. Plan rewrites this in
  D-3 alongside `remove_tree` for coherence (brainstorm rejected
  "fix one, leave the other" as incoherent).

- **A-004 — `bin/cleanup-worktrees.sh` lacks the sentinel pattern;
  the for-loop is inline at file scope.** Verified at
  `bin/cleanup-worktrees.sh:56-90` (for-loop body inline; no `main()`
  function; no `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi`
  guard at the bottom). Also verified at `bin/cleanup-worktrees.sh:11`
  (`require_bin gh jq git` at file scope) and `bin/cleanup-worktrees.sh:17-22`
  (`shopt -s nullglob` + `worktree_paths=("$PROJECT_STATE_DIR"/ENG-*/worktree)`
  + early-exit at file scope). The plan moves all three INTO `main()`
  per D-4 so tests can `source` the file without firing `require_bin`
  on a host that lacks `gh` (or for hermetic source-and-stub testing).

- **A-005 — `bin/cleanup-worktrees.sh:64-66` (PR-merged path) and
  `bin/cleanup-worktrees.sh:75` (Canceled path) are the two call sites
  of `remove_tree`.** Verified at:
  ```
  64:    issue_id="$(issue_id_from_branch "$branch")"
  65:    transition_done "$issue_id"
  66:    remove_tree "$path" "$branch" "merged"
  ...
  75:      remove_tree "$path" "$branch" "canceled"
  ```
  Plan adds `"$issue_id"` as the fourth positional in both call sites.
  `issue_id` is in scope at both lines (line 64 for merged, line 71
  for Canceled).

- **A-006 — `bin/metrics.sh:20` signature is
  `<event> <issue_id> <stage> <outcome> <duration_ms> [notes…] [--<flag> N …]`.**
  Verified at `bin/metrics.sh:20-21`:
  ```
  local event="${1:-}" issue_id="${2:-}" stage="${3:-}" outcome="${4:-}" duration_ms="${5:-0}"
  shift 5 || true
  ```
  Slot 2 = issue_id, slot 3 = stage, slot 4 = outcome. Empty string
  `""` is a valid value for slot 2 and slot 3 (the `--arg` jq
  bindings render an empty string field, see `bin/metrics.sh:67`).

- **A-007 — `bin/run-local.sh:392` invokes cleanup-worktrees.sh as
  a fire-and-forget subprocess.** Verified at `bin/run-local.sh:391-392`:
  ```
  log "periodic sweep: running cleanup-worktrees.sh"
  bash "$SCRIPT_DIR/cleanup-worktrees.sh" || log "cleanup-worktrees.sh exited nonzero (non-fatal)"
  ```
  No args. After D-4's sentinel refactor, the bottom `main "$@"`
  receives empty `$@`; `main` does not parse args (consistent with
  `bin/metrics.sh::main` which DOES parse args, but the `cleanup`
  flow doesn't take any). Caller-side semantics unchanged.

- **A-008 — `bin/branch-name.sh:20,31` lowercases the identifier
  before constructing the branch name.** Verified at:
  ```
  20:  ident_lower="$(tr '[:upper:]' '[:lower:]' <<<"$ident")"
  31:  printf '%s/%s-%s\n' "$prefix" "$ident_lower" "$slug"
  ```
  Branches emitted by the harness are always lowercase
  `feat/eng-N-…` / `fix/eng-N-…`. The original `I` (case-insensitive)
  flag was redundant for harness-emitted branches and is dropped per
  AC #1's literal wording.

- **A-009 — `bin/common-test.sh:13-30` and `bin/metrics-test.sh:13-30`
  are the canonical source-and-stub templates.** Verified at:
  ```
  bin/common-test.sh:13   set -uo pipefail
  bin/common-test.sh:18   _TEST_ROOT="$(mktemp -d -t twinning-eng44.XXXXXX)"
  bin/common-test.sh:26   trap '... rm -rf "$_TEST_ROOT" ...' EXIT
  bin/common-test.sh:28   export TARGET_REPO="$_TEST_ROOT/target"
  bin/common-test.sh:33   source "$SCRIPT_DIR/common.sh"
  ```
  ```
  bin/metrics-test.sh:23  STUB_DIR="$(mktemp -d)"
  bin/metrics-test.sh:24  HARNESS_STATE_DIR="$(mktemp -d)"
  bin/metrics-test.sh:25  PROJECT_STATE_DIR="${HARNESS_STATE_DIR}/${PROJECT_SLUG}"
  bin/metrics-test.sh:29  trap 'rm -rf "$HARNESS_STATE_DIR" "$STUB_DIR"' EXIT
  ```
  The new `bin/cleanup-worktrees-test.sh` follows the
  `metrics-test.sh` pattern (it needs `PROJECT_STATE_DIR/metrics/events.jsonl`
  to exist after a `metrics.sh` call — same shape as the existing
  metrics test).

- **A-010 — `.githooks/pre-commit` runs `bin/*-test.sh` via glob; new
  test file is auto-included.** Verified at `.githooks/pre-commit:90`:
  ```
  for t in bin/*-test.sh; do
  ```
  `bin/cleanup-worktrees-test.sh` is picked up automatically when
  added; no entry in `KNOWN_BROKEN`.

- **A-011 — `docs/runbooks/recovery.md` exists at 249 lines with a
  `## N. Title` section structure suitable for append.** Verified at
  `docs/runbooks/recovery.md:1-12` (frontmatter + ENG-41 title) and
  `docs/runbooks/recovery.md:227-249` (final "Quick reference: env var"
  section). Plan appends a new `## N. Backfill — accumulated
  Canceled-issue worktrees from pre-ENG-64 hosts` section after line
  249 (or before the existing `## Quick reference` section — pick the
  latter so the back-matter quick-ref stays last).

- **A-012 — `_scope_allowlist_override` reads
  `.scope.allowlist[$stage]` from `$CONFIG`.** Verified at
  `bin/run-local-helpers.sh:11-20` and the `implementing` arm at
  `bin/run-local-helpers.sh:58-68` (default
  `src/ src-tauri/ crates/ tests/ docs/ package.json …`, no `bin/`).
  This plan does NOT modify the harness-self target's
  `.pipeline-config/config.json` — it relies on the operator's
  per-machine config carrying `scope.allowlist.implementing` with
  `bin/` (or a more specific entry like `bin/cleanup-worktrees*.sh`).
  Verified by recent test additions ENG-44/ENG-50/ENG-51 (git log
  shows they shipped via the implement-stage path, so the override
  is presumed in place). If absent, the implement agent will see a
  self-leak halt; the operator adds the override and re-dispatches
  per `learned-rules/twinning/plan.md` Rule P-001-style guidance
  (config precondition, not a code change).

### Assumed/new artifacts

- **A-013 — `bin/cleanup-worktrees-test.sh` does not exist today.**
  Verified by `ls bin/cleanup-worktrees-test.sh` → "No such file or
  directory" (per the brainstorm's row 7 verification). Created in
  Task 4.

## File Structure

| File | Status | Change |
|---|---|---|
| `bin/cleanup-worktrees.sh` | modified | swap `\|` → `,` + drop `I`; widen `remove_tree` signature; fix orphan-detected metric; wrap inline body in `main()` + sentinel |
| `bin/cleanup-worktrees-test.sh` | new | source-and-stub regression test, 10 cases |
| `docs/runbooks/recovery.md` | modified | append \~5-line "Backfill — accumulated Canceled-issue worktrees" subsection |

No other files change. No `bin/metrics.sh` change. No
`bin/run-local.sh` change (subprocess invocation is signature-stable).
No `AGENT_PROMPTS.md`, `dispatch.sh`, learned-rules, or
`.pipeline-config/config.json` change. No `CLAUDE.md` change (the
sentinel and metrics-shape conventions are already documented).

## API Contract

No new API surface. This is a bash-script-internal refactor; no
FE↔BE handler is added or changed. The only "interface" touched is
the internal `metrics.sh` positional contract, which is used
correctly by 13 other call sites (verified via
`grep -rn 'metrics.sh' bin/`); this plan brings the two
`cleanup-worktrees.sh` call sites into compliance with that existing
contract rather than changing it.

## Backend Tasks

### Task 1: Fix the `sed` delimiter conflict in `issue_id_from_branch`

- `depends_on: []`
- `touches: bin/cleanup-worktrees.sh::issue_id_from_branch`
- [ ] Edit `bin/cleanup-worktrees.sh:28` — replace the body of
      `issue_id_from_branch`'s sed call. Concretely change:
      ```
      m="$(sed -nE 's|^(feat|fix)/(eng-[0-9]+)-.*|\2|pI' <<<"$branch" || true)"
      ```
      to:
      ```
      m="$(sed -nE 's,^(feat|fix)/(eng-[0-9]+)-.*,\2,p' <<<"$branch" || true)"
      ```
      Three substitutions: open-delim `|` → `,`, mid-delim `|` → `,`,
      close-delim `|` → `,`. Drop the trailing `I` flag (BSD `sed`
      does not support it; the harness emits lowercase branches per
      A-008).
- [ ] Confirm lines 25, 26, 27, 29, 30, 31 (function preamble +
      trailing normalisation `tr '[:lower:]' '[:upper:]'`) are
      unchanged. The function contract is: input `feat/eng-N-…` or
      `fix/eng-N-…` → output `ENG-N`; non-matching input → empty.

### Task 2: Widen `remove_tree` signature to accept `issue_id`; fix metric call

- `depends_on: [1]`
- `touches: bin/cleanup-worktrees.sh::remove_tree, bin/cleanup-worktrees.sh:64-66, bin/cleanup-worktrees.sh:75, bin/cleanup-worktrees.sh:88`
- [ ] Edit `bin/cleanup-worktrees.sh:33-42::remove_tree` — add
      `issue_id="${4:-}"` to the local-var line, and rewrite line 41
      to use it:
      ```bash
      remove_tree() {
        local path="$1" branch="$2" reason="$3" issue_id="${4:-}"
        log "cleanup: removing worktree $path (branch=$branch, reason=$reason)"
        git -C "$TARGET_REPO" worktree remove --force "$path" 2>/dev/null || {
          log "cleanup: git worktree remove failed; forcing rm of $path"
          rm -rf "$path"
        }
        git -C "$TARGET_REPO" branch -D "$branch" 2>/dev/null || true
        bash "$SCRIPT_DIR/metrics.sh" worktree-cleanup "$issue_id" "" success 0 \
          "branch=$branch reason=$reason path=$path"
      }
      ```
      Slot 2 = `issue_id` (`ENG-N` or empty); slot 3 = `""` (empty
      string — see brainstorm D-3 "Why empty-string for the stage
      slot"); `branch` and `reason` move into `notes`.
- [ ] Edit `bin/cleanup-worktrees.sh:66` — pass `issue_id` as the
      fourth positional:
      ```
      remove_tree "$path" "$branch" "merged" "$issue_id"
      ```
      `issue_id` is in scope at line 66 from line 64.
- [ ] Edit `bin/cleanup-worktrees.sh:75` — pass `issue_id` as the
      fourth positional:
      ```
      remove_tree "$path" "$branch" "canceled" "$issue_id"
      ```
      `issue_id` is in scope from line 71.
- [ ] Edit `bin/cleanup-worktrees.sh:88` — rewrite the
      orphan-detected metric to use the correct slots:
      ```bash
      bash "$SCRIPT_DIR/metrics.sh" worktree-orphan-detected "${issue_id:-}" "" warn 0 \
        "branch=$branch path=$path age_days=$age_days"
      ```
      `issue_id` may be empty here (the orphan path is reached when
      the Canceled lookup did NOT match — but `issue_id` was set on
      line 71 if the branch matched the regex; `${issue_id:-}` makes
      the unset case safe under `set -u`).

### Task 3: Add the sentinel pattern + restructure into `main()`

- `depends_on: [2]`
- `touches: bin/cleanup-worktrees.sh (file-scope body)`
- [ ] Edit `bin/cleanup-worktrees.sh` — move three currently
      file-scope statements INTO a new `main()` function:
      1. `bin/cleanup-worktrees.sh:11` (`require_bin gh jq git`)
      2. `bin/cleanup-worktrees.sh:17` (`shopt -s nullglob`)
      3. `bin/cleanup-worktrees.sh:18-22` (`worktree_paths=…`
         array + the early-exit on empty)
      4. `bin/cleanup-worktrees.sh:56-90` (the `for path in …` loop)
- [ ] After the function definitions
      (`issue_id_from_branch`, `remove_tree`, `transition_done`),
      define `main()`:
      ```bash
      main() {
        require_bin gh jq git
        shopt -s nullglob
        local worktree_paths=("$PROJECT_STATE_DIR"/ENG-*/worktree)
        if (( ${#worktree_paths[@]} == 0 )); then
          log "no per-issue worktrees under $PROJECT_STATE_DIR; nothing to sweep"
          return 0
        fi
        local path branch issue_id state pr_merged_count pr_open_count last_commit_ts now_ts age_days
        for path in "${worktree_paths[@]}"; do
          # … existing for-loop body verbatim from lines 57-89 …
        done
      }
      ```
      Convert the early-exit `exit 0` (current line 21) to `return 0`.
- [ ] Append at end of file:
      ```bash
      if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
        main "$@"
      fi
      ```
- [ ] Run `bash -n bin/cleanup-worktrees.sh` to confirm syntax is
      clean.
- [ ] Run `bash bin/cleanup-worktrees.sh` against an empty
      `$PROJECT_STATE_DIR` to confirm the early-exit path still fires
      (it should log "no per-issue worktrees" and return 0).

### Task 4: Add `bin/cleanup-worktrees-test.sh` with 10 cases

- `depends_on: [3]`
- `touches: bin/cleanup-worktrees-test.sh (new)`
- [ ] Create `bin/cleanup-worktrees-test.sh` following
      `bin/metrics-test.sh:13-30` source-and-stub template:
      - `set -uo pipefail`
      - `STUB_DIR="$(mktemp -d)"`
      - `HARNESS_STATE_DIR="$(mktemp -d)"`
      - `PROJECT_STATE_DIR="$HARNESS_STATE_DIR/$PROJECT_SLUG"`
      - `trap 'rm -rf "$HARNESS_STATE_DIR" "$STUB_DIR"' EXIT`
      - `export TARGET_REPO=…` (throwaway dir with
        `.pipeline-config/config.json` minimum stub)
      - `export PROJECT_SLUG="${PROJECT_SLUG:-test-slug}"`
      - `export PIPELINE_DRY_RUN=1`
      - `: "${LINEAR_API_KEY:=test-mock-key}"; export LINEAR_API_KEY`
- [ ] Source `cleanup-worktrees.sh` (relies on Task 3's sentinel):
      ```bash
      source "$SCRIPT_DIR/cleanup-worktrees.sh"
      ```
      Sentinel guards against firing `main`; the function definitions
      are in scope.
- [ ] Cases A-G2 (regex contract, ~10 LOC of test logic) using
      direct calls to `issue_id_from_branch`:
      - A: `issue_id_from_branch "feat/eng-99-foo"` → `ENG-99`
      - B: `issue_id_from_branch "fix/eng-100-bar-baz"` → `ENG-100`
      - C: `issue_id_from_branch "feat/eng-7-x"` → `ENG-7`
      - D: `issue_id_from_branch "main"` → empty
      - E: `issue_id_from_branch "feature/eng-5-foo"` → empty
      - F: `issue_id_from_branch "feat/foo-bar"` → empty
      - G: `issue_id_from_branch ""` → empty (no crash under `set -u`)
      - G2: `issue_id_from_branch "feat/ENG-99-foo"` → empty
        (case-sensitivity narrowing per AC #1's "drop the `I` flag")
- [ ] Cases H, I, J (metrics-shape contract) — write a tiny stub
      `metrics.sh` and a tiny stub `git` into `$STUB_DIR`, prepend
      `$STUB_DIR` to `PATH`. The stub `git` no-ops `worktree remove`
      and `branch -D`; the stub `metrics.sh` is the REAL `metrics.sh`
      (we want the JSONL output) — so do NOT shadow `metrics.sh`,
      only `git`. Set `SCRIPT_DIR` such that `bash "$SCRIPT_DIR/metrics.sh"`
      reaches the real one (the test-file's `SCRIPT_DIR` resolves to
      `bin/`; `cleanup-worktrees.sh::remove_tree` calls
      `bash "$SCRIPT_DIR/metrics.sh"` where its own `SCRIPT_DIR` is
      already `bin/`).
      Reset and read `events.jsonl` per case:
      - H: invoke
        `remove_tree "/tmp/path" "feat/eng-13-foo" "merged" "ENG-13"`,
        then `tail -n 1 "$PROJECT_STATE_DIR/metrics/events.jsonl"`,
        assert via `jq`:
        - `.event == "worktree-cleanup"`
        - `.issue_id == "ENG-13"`
        - `.stage == ""`
        - `.outcome == "success"`
        - `.notes` contains `branch=feat/eng-13-foo`, `reason=merged`,
          `path=/tmp/path`
      - I: invoke `remove_tree "/tmp/path" "main" "merged" ""`,
        assert `.issue_id == ""`, `.stage == ""`, no field-shift.
      - J: invoke metrics directly with
        `worktree-orphan-detected "ENG-13" "" warn 0 "branch=feat/eng-13-foo path=/tmp/path age_days=33"`
        (this exercises the metrics-call shape without invoking the
        whole orphan-detection flow, which would require stubbing
        `gh pr list` + `git log -1 --format=%ct` + computing age).
        Assert `.event == "worktree-orphan-detected"`,
        `.issue_id == "ENG-13"`, `.stage == ""`, `.outcome == "warn"`,
        `.notes` contains `branch=feat/eng-13-foo`, `age_days=33`.
- [ ] Add the standard `PASS=0; FAIL=0; report_ok / report_fail /
      assert_eq` helpers (mirror `bin/common-test.sh:37-46`).
- [ ] Final summary: print `passed=$PASS failed=$FAIL`; exit 1 if any
      failed.

### Task 5: Append backfill subsection to `docs/runbooks/recovery.md`

- `depends_on: []`
- `touches: docs/runbooks/recovery.md`
- [ ] Append a new section before the existing `## Quick reference:
      env var requirement` section (so back-matter stays last). New
      section title: `## N. Backfill — accumulated Canceled-issue
      worktrees from pre-ENG-64 hosts` (use the next free section
      number — the current last numbered section before quick-ref
      depends on the file's structure; verify and use the right N).
      Body, ~5 lines:
      ```
      ENG-64 fixed `issue_id_from_branch` for macOS; before that fix
      the Canceled-issue cleanup branch silently never fired. Existing
      hosts have an accumulated backlog of Canceled-issue worktrees
      under `$PROJECT_STATE_DIR/ENG-*/worktree`. **Action:** none
      required — the next periodic cleanup tick (every
      `CLEANUP_EVERY_N_TICKS` ticks of `bin/run-local.sh`) will sweep
      them automatically. To accelerate: `TARGET_REPO=… bash
      bin/cleanup-worktrees.sh` runs the sweep manually; it is
      idempotent.
      ```

### Task 6: Verify gates pass

- `depends_on: [1, 2, 3, 4, 5]`
- `touches: (no files; this is a verification step)`
- [ ] Run `bash bin/cleanup-worktrees-test.sh` directly — expect
      10/10 PASS, exit 0.
- [ ] Run `bash -n bin/cleanup-worktrees.sh` — expect clean exit.
- [ ] Run the full pre-commit suite: `bash .githooks/pre-commit`.
      The hook runs every `bin/*-test.sh`; expect the new test in the
      pass column, no entries in `KNOWN_BROKEN`. Existing
      `KNOWN_BROKEN` (mutex, render-pr-body, render-prompt-slug)
      stay flagged; do not touch them.
- [ ] Run `bash bin/secret-probe-lint.sh` — defensive sanity check;
      no `${VAR:-FALLBACK}` patterns introduced against secret-named
      vars (none expected; this PR touches no secret-related code).
- [ ] Manually invoke
      `TARGET_REPO=$TARGET_REPO bash bin/cleanup-worktrees.sh` against
      a host with at least one accumulated worktree to confirm the
      live behavior (smoke). The empty-state early-exit case is
      already covered by Task 3's verification step.

## Frontend Tasks

No frontend changes. The harness has no UI surface (`bin/` only).

## Failure Mode → Test Map

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
|---|---|---|---|---|
| BSD `sed` delimiter conflict on macOS | Call `issue_id_from_branch "feat/eng-99-foo"` on macOS | Returns `ENG-99`; no `RE error` on stderr | unit | `cleanup-worktrees-test.sh::case-A` |
| BSD `sed` on `fix/` branch prefix | Call `issue_id_from_branch "fix/eng-100-bar-baz"` | Returns `ENG-100` | unit | `cleanup-worktrees-test.sh::case-B` |
| Single-digit issue id | Call `issue_id_from_branch "feat/eng-7-x"` | Returns `ENG-7` | unit | `cleanup-worktrees-test.sh::case-C` |
| Non-matching branch (no prefix) | Call `issue_id_from_branch "main"` | Returns empty (no crash) | unit | `cleanup-worktrees-test.sh::case-D` |
| Wrong prefix (`feature` vs `feat`) | Call `issue_id_from_branch "feature/eng-5-foo"` | Returns empty | unit | `cleanup-worktrees-test.sh::case-E` |
| Missing `eng-N` segment | Call `issue_id_from_branch "feat/foo-bar"` | Returns empty | unit | `cleanup-worktrees-test.sh::case-F` |
| Empty string input under `set -u` | Call `issue_id_from_branch ""` | Returns empty; no crash | unit | `cleanup-worktrees-test.sh::case-G` |
| Uppercase `ENG-` (case-sensitivity narrowing) | Call `issue_id_from_branch "feat/ENG-99-foo"` | Returns empty (documents `I`-flag drop) | unit | `cleanup-worktrees-test.sh::case-G2` |
| `worktree-cleanup` metric field-shift | Call `remove_tree path branch merged ENG-13` | JSONL has `issue_id="ENG-13"`, `stage=""`, `notes` carries `branch=…`, `reason=…`, `path=…` | integration | `cleanup-worktrees-test.sh::case-H` |
| Metric with empty issue_id (caller passes `""`) | Call `remove_tree path main merged ""` | JSONL has `issue_id=""`, `stage=""`, no field-shift | integration | `cleanup-worktrees-test.sh::case-I` |
| `worktree-orphan-detected` metric field-shift | Direct `metrics.sh worktree-orphan-detected ENG-13 "" warn 0 "branch=… age_days=33"` | JSONL has `issue_id="ENG-13"`, `stage=""`, `notes` carries `branch=…`, `age_days=33` | integration | `cleanup-worktrees-test.sh::case-J` |
| Sentinel refactor breaks subprocess invocation | `bash bin/cleanup-worktrees.sh` with empty `$@` | `main` runs, hits empty-state early-exit, returns 0 | smoke | Task 3 verification step |
| Pre-commit hook regression | `bash .githooks/pre-commit` after the changes | New test joins the PASS column; no new `KNOWN_BROKEN` entries | smoke | Task 6 verification step |

## Test Strategy

- **Unit (cases A–G2):** lock the regex contract for
  `issue_id_from_branch`. The brainstorm's regression-insurance
  argument (D-5) requires more than the issue's literal two cases (A,
  B) so that a refactor tightening (C — single-digit) or loosening
  (E — wrong prefix; F — missing segment) is detected. Cases D and G
  cover the empty-input paths the original `sed` already handled
  silently. Case G2 documents the case-sensitivity narrowing
  introduced by dropping the `I` flag.
- **Integration (cases H, I, J):** lock the `metrics.sh` positional
  contract end-to-end by reading `events.jsonl` after a real
  `metrics.sh` write. Stub only `git` (the side-effecting bit); the
  real `metrics.sh` validates the full JSONL shape including
  `--arg`-bound empty-string handling. Case I is the load-bearing
  variant (caller passed `""` for issue_id when the branch did not
  match) — it ensures the empty-issue_id path doesn't shift fields.
  Case J is the orphan-detected metric, which has the same field
  shape but is reached via a different code path; we exercise the
  metric call directly rather than reproducing the orphan-detection
  conditions, since the contract being tested is the JSONL shape.
- **Smoke (Task 3 verification + Task 6 verification):** confirm
  syntax (`bash -n`), end-to-end empty-state behavior, full
  pre-commit suite passes. The empty-`$PROJECT_STATE_DIR` smoke is
  the one test that exercises the post-refactor `main "$@"` invocation
  path through the sentinel.
- **Adversarial (deferred):** the brainstorm flagged §10 Q1 (audit
  other `sed -nE` call sites for the same `|` delimiter pattern) as
  out of scope for ENG-64. Not a test addition for this PR; flagged
  for a followup grep-the-tree audit ticket.

## Persona review

Six personas (feasibility, scope, coherence, design, product) were
exercised in iteration 1 of this plan via the
`compound-engineering:document-review` skill. Iteration 1 results:

| Persona | Verdict | P0 | P1 |
|---|---|---|---|
| feasibility | PASS | 0 | 1 |
| scope | PASS | 0 | 2 |
| coherence | PASS | 0 | 0 |
| design | PASS | 0 | 1 |
| product | PASS | 0 | 1 |

P1 findings (none load-bearing; folded into the plan above):

- **feasibility-P1.** Task 4 H/I/J case description: the test invokes
  `remove_tree` directly to assert the metric shape but does not stub
  `git`'s `worktree remove --force`. Without a `git` stub on `PATH`,
  the test would either crash trying to `worktree remove` a non-existent
  path or succeed via the `||` fallback to `rm -rf "$path"` — the
  latter is acceptable but noisy. **Folded:** Task 4 step now
  explicitly notes "stub `git` no-ops `worktree remove` and `branch
  -D`; do NOT shadow `metrics.sh`". Test passes cleanly without
  filesystem side effects.

- **scope-P1-a.** Task 5 (D-6 runbook append) is operator
  documentation and could be deferred to a separate doc PR. **Verdict:
  kept.** Brainstorm AC #4 explicitly asks for the runbook note;
  splitting into two PRs would create artifact drift.

- **scope-P1-b.** Task 4's 10 cases exceed AC #2's literal "two
  cases." **Verdict: kept.** Brainstorm D-5 defends the eight extra
  cases as proportionate regression insurance at \~negligible cost
  (~30 LOC total).

- **design-P1.** Task 3's `main()` declares `local path branch
  issue_id state pr_merged_count pr_open_count last_commit_ts now_ts
  age_days` up-front, but `state` is conditionally set inside an
  `if [[ -n "$issue_id" ]]` block (current line 73) and read on line
  86 via `${state:-}`. After moving into `main()` with `set -u`
  inherited from common.sh, the `local` declaration is required to
  avoid a crash on the read path. **Folded:** the explicit `local`
  list in Task 3's snippet preserves this. No behavioral change.

- **product-P1.** The brainstorm's AC #4 wording asks for "a one-time
  pass for accumulated Canceled-issue worktrees" — which the runbook
  note re-frames as "the periodic sweep is self-clearing post-fix."
  Operator may misread the note as "I have to do nothing forever."
  **Folded:** runbook copy includes the explicit "to accelerate: run
  `bin/cleanup-worktrees.sh` manually" escape hatch (already present
  in Task 5's body). Note structure mirrors the brainstorm's D-6 body.

**Status:** Personas: 5/5 PASS · gate P0: 0 · proceeding to
implementing.
