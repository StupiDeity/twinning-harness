---
linear: ENG-131
date: 2026-05-17
topic: bin/dispatch.sh — replace cmd→renderer pipe with sequential capture file; wrap cmd under /usr/bin/perl POSIX::setsid so EXIT trap can kill the pgrp; preserve AC-TRAP-BEFORE-ACQUIRE via composed _dispatch_cleanup
---

# Plan — ENG-131 gtimeout watchdog can hang dispatch indefinitely (orphan pipe FDs)

Implementation plan for the design at
`docs/brainstorms/2026-05-17-eng-131-gtimeout-watchdog-can-hang-dispatch-indefinitely-orphan-pipe-fds-design.md`.

## Anti-anchoring check

- **Problem (operator's words).** A `claude -p` dispatch ran 5h 43m past
  its 1h `gtimeout` budget on 2026-05-15. The watchdog fired but the
  harness stayed wedged: every subsequent tick silent-skipped because
  the lock holder shell was alive but blocked on `wait`. Operator had
  no visible signal until they manually inspected `ps`.
- **Brainstorm addresses it?** Yes. D-001 (Layer A) replaces the
  `cmd | renderer` pipe with `cmd > capture; renderer < capture` so
  orphan MCP descendants holding the inherited write-end fd cannot
  block our reader. D-002 (Layer B) wraps `cmd` under a perl-setsid
  shim so dispatch.sh's EXIT trap can `kill -- -$pgid` the descendant
  tree. Together they close BOTH the hang root cause (A) and the
  resource-leak root cause (B) named in the Linear issue body.
- **Proportional?** Yes. Brainstorm §5 sizes the change at one
  production file (`bin/dispatch.sh`), one test file
  (`bin/dispatch-test.sh`), and one documentation row (`CLAUDE.md`'s
  Failure-mode quick reference). 1 subsystem, 2 design decisions with
  B subordinate to A — matches the issue's own sizing claim.
- **No anti-anchoring escalation** (problem unchanged; solution
  proportional). PROCEED.

### Deviations from the brainstorm (documented, not escalated)

None. The brainstorm's iter-2 PASS gate (6/6 personas, 0 P0) already
absorbed every persona finding inline. The four residual P1s listed in
brainstorm §10 "Residual P1s carried into planning" are addressed
below:

1. **P1: "Plan stage enumerates `_render_and_capture_stream` test
   fixture sites rather than pinning a count."** Done — Assumption
   Inventory item A-005 below enumerates all 45 call sites with a
   `grep -n` reproducer rather than a fragile integer.
2. **P1: "§5 CLAUDE.md row prose is dense; plan stage may split into a
   multi-line bullet runbook."** Done — Task 6 below specifies a
   multi-line bullet row.
3. **P1: "G-1 post-fix log-line shape — plan stage pins the literal
   log shape."** Done — the brainstorm's G-1 paragraph already names
   the literal `dispatch.sh exit=124` substring. Test fixture T-A
   below pins it as an `expect_stdout_match`.
4. **P1: "OQ-6 sibling stuck-tick alarm — plan stage links the sibling
   ticket id."** Deferred — the sibling ticket has not yet been
   filed at plan time. CLAUDE.md row written in Task 6 uses the
   placeholder `(sibling stuck-tick alarm ticket TBD)` so the operator
   can substitute the id when the ticket lands. This is documentation
   text, not load-bearing behavior.

## Branch-base freshness

`git log --oneline HEAD..origin/main` returned NON-EMPTY:

```
fe66b5c Merge pull request #121 from StupiDeity/fix/eng-109-ensure-progress-md-bare-dry-run-set-u-violation
1f4b483 fix(eng-109): _ensure_progress_md set -u clean when PIPELINE_DRY_RUN unset
```

This branch is 2 commits behind `origin/main`. Drift is **clean**: both
drifted commits touch `bin/run-stage.sh::_ensure_progress_md` (the
ENG-109 progress-md plumbing). Neither commit touches `bin/dispatch.sh`,
`bin/dispatch-test.sh`, `bin/common.sh`'s exit-code taxonomy, or
`CLAUDE.md` — none of the files this plan modifies. No File Structure
conflict. **`Task 0: Rebase onto origin/main` is mandatory** and is
the first task in Backend Tasks.

All `path:line` excerpts in Assumption Inventory below are anchored to
**this branch's HEAD plus the two clean upstream commits** — i.e.
the post-rebase state, which because neither upstream commit touches
the files we modify is byte-identical to the current branch for all
anchored paths. Task 0 verifies anchors survive.

## Goal

After implement runs:

1. `bash bin/dispatch-test.sh` exits 0 with two new ENG-131 fixtures
   passing:
   - **T-A (no-hang)**: simulate the orphan-writer scenario; assert
     `dispatch.sh` exits within `≤ 12 s` of `gtimeout`'s SIGKILL with
     `dispatch_rc=124` and the log file containing the literal substring
     `[cost] no result event found in stream` OR
     `[cost] partial usage captured`.
   - **T-B (no-orphan)**: spawn a fake-claude descendant tree
     (3-level `sh -c 'sleep 9999'` chain); assert that `≤ 1.5 s` after
     dispatch exits, `pgrep -g <captured_pgid>` returns empty (rc=1,
     stdout empty).
2. The existing AC-TRAP-BEFORE-ACQUIRE structural invariant in
   `bin/dispatch-test.sh::3007-3035` continues to PASS, **updated** to
   accept the composed shape `trap _dispatch_cleanup EXIT` (unquoted —
   the form is byte-identical to Task 2.2's production replacement
   and to Task 3.1's expected-prior-line literal so the test's
   literal-equality check matches) as the non-empty predecessor line
   to `acquire_claude_mutex` (the test's semantic invariant — release
   on every die() between trap-install and acquire — is preserved
   because `_dispatch_cleanup` calls `release_claude_mutex` internally).
3. All 27 enumerated `_render_and_capture_stream` direct-call test
   sites in `bin/dispatch-test.sh` (lines 549, 625, 640, 661, 716,
   736, 761, 783, 806, 825, 849, 887, 917, 998, 1009, 1476, 1504,
   1629, 1658, 1693, 1730, 1759, 1822, 1848, 1939, 2022, 2050 — every
   site that feeds NDJSON via stdin heredoc / `< file` / `</dev/null`)
   continue to pass without modification.
4. `bash .githooks/pre-commit` exits 0 (the full `bin/*-test.sh`
   gate suite passes).
5. A 2026-05-15-class incident, if it recurs, produces an
   operator-visible signal: per-stage log line `dispatch.sh exit=124`
   within `kill_after + ε` (≤ ~12 s) of the watchdog firing, followed
   by `run-stage.sh`'s rc=124 branch posting the
   `dispatch wall-clock timeout` halt comment with the worktree-resume
   hint (`bin/run-stage.sh:1454-1455`).

Verifiable by:

```
bash bin/dispatch-test.sh && bash .githooks/pre-commit
```

exiting 0.

## Assumption Inventory

Every modified-file fact below is verified by direct Read at plan time
against the worktree's HEAD. The two upstream commits in
`HEAD..origin/main` do NOT touch any file or line cited below, so each
anchor survives the Task 0 rebase byte-identically. Bare line numbers
appear ONLY as informational hints alongside a content anchor; the
literal content-anchor strings are what the Edit calls match.

branch-base freshness: HEAD..origin/main NON-EMPTY at plan time
(origin/main = `fe66b5c`); Task 0 rebases the feature branch onto
origin/main before any other task; all anchors below were verified
against current HEAD and survive the rebase because both upstream
commits touch only `bin/run-stage.sh::_ensure_progress_md` — a file
and function not modified by this plan.

### Files modified in this plan: 3 (1 production, 1 test, 1 docs)

- `bin/dispatch.sh` — three edit sites (capture-file plumbing,
  perl-setsid wrap of `cmd`, composed `_dispatch_cleanup` trap that
  replaces the existing `release_claude_mutex` trap).
- `bin/dispatch-test.sh` — two edit sites (new T-A + T-B fixtures
  appended; one in-place update to AC-TRAP-BEFORE-ACQUIRE's
  expected-prior-line string).
- `CLAUDE.md` — one edit site (new row in "Failure-mode quick
  reference" table for ENG-131-class silent-hang).

### Modified-file facts — current state and verification points

- **A-001 — `bin/dispatch.sh:507-508` carries the pre-acquire
  release trap.** Lines 507-508 read:

  ```bash
    trap 'release_claude_mutex' EXIT
    acquire_claude_mutex
  ```

  The `AC-TRAP-BEFORE-ACQUIRE` test at `bin/dispatch-test.sh:3007-3035`
  pins the literal string `trap 'release_claude_mutex' EXIT` as the
  non-empty predecessor line. Task 2 below replaces this trap-install
  with `trap _dispatch_cleanup EXIT` and Task 3 updates the test's
  expected-prior-line string accordingly. **Single-phase upgrade**:
  there is exactly ONE trap install (the original line is replaced,
  not paired with a second trap), so the invariant the test guards
  (no die() between trap install and acquire can leak the mutex) is
  preserved because `_dispatch_cleanup` calls `release_claude_mutex`
  internally on every exit path.

  Content anchor for Task 2's Edit site 1: the literal two-line block
  `    trap 'release_claude_mutex' EXIT\n    acquire_claude_mutex`
  (exact whitespace; appears EXACTLY ONCE in the file — verified by
  grep of the longer line `acquire_claude_mutex` which appears only
  at line 508).

- **A-002 — `bin/dispatch.sh:620-645` builds the `cmd` array.**
  Lines 620-645 (verbatim, current):

  ```bash
    local cmd=(env PIPELINE_WRITER=agent
      "PIPELINE_DISPATCH_ID=${PIPELINE_DISPATCH_ID-}"
      "PIPELINE_STAGE=$stage"
    )
    if [[ -n "$_gtime_bin" ]]; then
      cmd+=("$_gtime_bin" -v -o "$_gtime_out")
    fi
    cmd+=(gtimeout --signal=TERM --kill-after=10 "$timeout_seconds"
      claude -p
      --output-format stream-json --verbose
    )
    …
    if [[ -n "${PIPELINE_DISPATCH_MODEL:-}" ]]; then
      cmd+=(--model "$PIPELINE_DISPATCH_MODEL")
    fi
    cmd+=(
      --setting-sources project,local
      --disable-slash-commands
      --disallowed-tools "$denies"
      --allowed-tools "$tools"
    )
  ```

  The `cmd` array shape is preserved unchanged. The perl-setsid wrap
  (D-002) is inserted at the INVOCATION site (line 654+ — see A-003),
  NOT as a prefix to `cmd`. This is a deliberate choice: prepending
  perl into the `cmd` array would change the `cmd` array's first-token
  shape that the dry-run preview log line at line 578 echoes, and
  would also force the perl wrapper into the DRY_RUN-bypass path.
  Wrapping at the invocation site is surgical.

  Content anchor for Task 2's Edit sites 2 and 3: the literal closing
  `)\n  --allowed-tools "$tools"\n  )` of the `cmd` array build is the
  unique upstream boundary; the invocation-site arms at 654-668 (see
  A-003) are the actual edit targets.

- **A-003 — `bin/dispatch.sh:646-669` is the cmd→renderer pipe at
  four invocation arms.** Current shape (lines 646-669, verbatim):

  ```bash
    if [[ -n "$log_file" ]]; then
      mkdir -p "$(dirname "$log_file")"
      log "dispatching stage=$stage, log=$log_file"
      …
      if [[ -n "$usage_file" && -n "$issue_state_dir" ]]; then
        "${cmd[@]}" < "$prompt_file" \
          | _render_and_capture_stream "$usage_file" "$issue_state_dir" "$stage" \
          > "$log_file"
      else
        "${cmd[@]}" < "$prompt_file" > "$log_file"
      fi
    else
      log "dispatching stage=$stage"
      if [[ -n "$usage_file" && -n "$issue_state_dir" ]]; then
        "${cmd[@]}" < "$prompt_file" \
          | _render_and_capture_stream "$usage_file" "$issue_state_dir" "$stage"
      else
        "${cmd[@]}" < "$prompt_file"
      fi
    fi
  ```

  Four arms total. The two "renderer-gated" arms (lines 654-657,
  663-665) are the bug-bearing pipe shapes; the two "no-renderer"
  arms (lines 658-660, 666-668 — used by ungated callers: release /
  retrospective / mutex-test / dry-run-self-check) do NOT pipe to the
  renderer but DO inherit the same orphan-fd-retention risk. **All
  four arms** must adopt the perl-setsid wrap (D-002) for the
  pgrp-kill cleanup to apply uniformly; the renderer's sequential
  read (D-001) applies only to the renderer-gated arms.

  Content anchor for Task 2's Edit site 4 (THE invocation rewrite):
  the literal multi-line block from line 646 (`if [[ -n "$log_file" ]]; then`)
  through line 669 (the closing `fi`), inclusive. The opening `if [[ -n "$log_file" ]]; then`
  conditional appears multiple times in the file; the four-arm block
  is uniquely anchored by the literal triplet
  `      "${cmd[@]}" < "$prompt_file" > "$log_file"` (the no-renderer
  log_file arm at line 659; verified unique by grep). The implement
  agent MUST anchor on the full 24-line block to avoid partial-match
  ambiguity.

- **A-004 — `_render_and_capture_stream` reads NDJSON from stdin
  (`bin/dispatch.sh:47-159`) and is unchanged by this plan.** Verified
  by direct read. The renderer takes 3 positional args
  (`usage_file`, `issue_dir`, `stage`) and reads its NDJSON input from
  stdin via the implicit `tee "$raw_capture" | jq -nRr --unbuffered '… inputs …'`
  pipeline starting at line 66. After D-001, the renderer's stdin is
  the captured file (via `< "$_capture_path"`) instead of the
  upstream `"${cmd[@]}"` process; the renderer's positional contract
  is preserved. **No renderer code changes in this plan.**

- **A-005 — `_render_and_capture_stream` is referenced 45 times in
  `bin/dispatch-test.sh`** (verified by
  `grep -c '_render_and_capture_stream' bin/dispatch-test.sh` = 45 at
  plan time). 27 of those 45 are direct-call sites of the form
  `_render_and_capture_stream "$USAGE_…" …` (the remainder are
  comment references). The 27 direct-call sites live at lines 549,
  625, 640, 661, 716, 736, 761, 783, 806, 825, 849, 887, 917, 998,
  1009, 1476, 1504, 1629, 1658, 1693, 1730, 1759, 1822, 1848, 1939,
  2022, 2050 (verified by `grep -n` of the function name filtered to
  lines that read `_render_and_capture_stream "$USAGE_…" …`).
  **Every one of these feeds NDJSON via stdin heredoc**
  (`<<'NDJSON'`, `<<NDJSON`, `< "$NDJSON_…"`, or `</dev/null`); none
  feed NDJSON via a pipe from a `cmd`-like upstream. **A's pipe
  removal is invisible to these fixtures by construction** — the
  renderer's stdin contract is preserved.

  Reproducer at implement time:

  ```bash
  grep -c '_render_and_capture_stream' bin/dispatch-test.sh
  grep -n '_render_and_capture_stream "\$USAGE' bin/dispatch-test.sh | wc -l
  ```

  Both counts MUST equal 45 and 27 respectively at implement time (a
  drift signals an unrelated test added in the meantime — non-blocking
  but the implement agent should re-verify A-005's "preserved by
  construction" claim against any new fixtures).

- **A-006 — `bin/dispatch-test.sh:3007-3035` is the
  AC-TRAP-BEFORE-ACQUIRE invariant test.** Verbatim block:

  ```bash
  # ─── AC-TRAP-BEFORE-ACQUIRE ────────────────────────────────────────────
  # Commit 4f81492 ("install release_claude_mutex trap BEFORE acquire")
  # fixed a slot-leak: a die() between the acquire and the trap-install
  # would have leaked the slot dir for the rest of the dispatch.sh
  # subshell's life. Pin the structural invariant — the non-empty line
  # immediately preceding `acquire_claude_mutex` in dispatch.sh must be
  # `trap 'release_claude_mutex' EXIT`. A future reorder regression would
  # fail silently otherwise.
  _TBA_ACQUIRE_LINE="$(grep -n '^[[:space:]]*acquire_claude_mutex[[:space:]]*$' "$SCRIPT_DIR/dispatch.sh" | head -1 | cut -d: -f1)"
  if [[ -z "$_TBA_ACQUIRE_LINE" ]]; then
    fail_at "AC-TRAP-BEFORE-ACQUIRE" "no top-level acquire_claude_mutex call found in dispatch.sh"
  else
    _TBA_PRIOR=""
    _TBA_PROBE=$((_TBA_ACQUIRE_LINE - 1))
    while (( _TBA_PROBE > 0 )); do
      _TBA_LINE_CONTENT="$(sed -n "${_TBA_PROBE}p" "$SCRIPT_DIR/dispatch.sh")"
      _TBA_TRIMMED="${_TBA_LINE_CONTENT#"${_TBA_LINE_CONTENT%%[![:space:]]*}"}"
      if [[ -n "$_TBA_TRIMMED" && "$_TBA_TRIMMED" != "#"* ]]; then
        _TBA_PRIOR="$_TBA_TRIMMED"
        break
      fi
      _TBA_PROBE=$((_TBA_PROBE - 1))
    done
    if [[ "$_TBA_PRIOR" == "trap 'release_claude_mutex' EXIT" ]]; then
      pass_at "AC-TRAP-BEFORE-ACQUIRE: dispatch.sh installs release trap on the line immediately preceding acquire_claude_mutex (line $_TBA_ACQUIRE_LINE)"
    else
      fail_at "AC-TRAP-BEFORE-ACQUIRE" "expected prior non-blank/non-comment line to be \"trap 'release_claude_mutex' EXIT\", got: $_TBA_PRIOR"
    fi
  fi
  ```

  Two surgical updates needed (Task 3 below):

  1. The literal expected-prior-line string
     `trap 'release_claude_mutex' EXIT` becomes
     `trap _dispatch_cleanup EXIT`. The PASS message becomes
     "AC-TRAP-BEFORE-ACQUIRE: dispatch.sh installs _dispatch_cleanup
     trap on the line immediately preceding acquire_claude_mutex
     (line $_TBA_ACQUIRE_LINE); _dispatch_cleanup composes release_claude_mutex".
  2. A new sibling assertion (Task 3 below) verifies
     `_dispatch_cleanup` is defined upstream of the trap-install
     line AND calls `release_claude_mutex` inside its body — preserves
     the SEMANTIC invariant the test guards.

  Content anchor for Task 3's Edit: the literal block above
  (lines 3007-3035). The two unique strings inside the block —
  `# ─── AC-TRAP-BEFORE-ACQUIRE` (header, file-unique) and
  `expected prior non-blank/non-comment line to be \"trap 'release_claude_mutex' EXIT\"`
  (fail message, file-unique) — both anchor the edit. Implement
  agent MUST use the multi-line block as `old_string` to avoid
  bare-string ambiguity.

- **A-007 — `bin/common.sh::failure_outcome_for_exit` exit-code
  taxonomy includes 124 → `dispatch-timeout`.** `bin/common.sh:276`:

  ```bash
      124) printf 'dispatch-timeout' ;;
  ```

  This plan does NOT modify the taxonomy. The brainstorm verifies
  (G-3) that A+B preserve the existing taxonomy: 124 on gtimeout
  SIGKILL, 22/23/26/29/31 on transcript-scan violations, 0 on clean.
  Reference only.

- **A-008 — `bin/run-stage.sh:1444-1457` is the rc=124 dispatch
  arm.** Verbatim:

  ```bash
      if (( dispatch_rc == 124 )); then
        # ENG-48: gtimeout SIGTERM'd a wedged dispatch. …
        classify_failure "$ident" "$stage" "skip-until-human-acts" \
          "dispatch wall-clock timeout — agent exceeded budget without exiting. Partial worktree artifacts may resume cleanly. Inspect: $(issue_dir "$ident")/worktree/. If the artifact looks complete, run: bash bin/pipeline.sh decide $ident --action continue" 124
        rm -f "$prompt_file"
        exit 124
      elif (( dispatch_rc == 22 )); then
  ```

  This plan does NOT modify `bin/run-stage.sh`. The rc=124 path is
  what surfaces today's silent-hang as an operator-visible halt
  *once dispatch.sh actually exits* — A+B remove the precondition
  blocker. Reference only; verified to confirm Goal #5 holds.

- **A-009 — `bin/run-local.sh:51-54` is the silent-skip path on lock
  contention.** Verbatim:

  ```bash
  if ! acquire_lock "$LOCK_DIR"; then
    # Silent skip: overlapping tick is expected if a stage runs >5 min.
    exit 0
  fi
  ```

  Unchanged by this plan. The silent-skip is correct behavior; the
  bug is that pre-A the lock holder stayed alive indefinitely. Once
  A ensures dispatch.sh exits within `kill_after + ε`, the silent-skip
  path correctly recovers within ~12 s. Reference only.

- **A-010 — `bin/run-local-helpers.sh:916-934` is `acquire_lock` with
  `kill -0` aliveness check.** Verbatim:

  ```bash
  acquire_lock() {
    local lock_dir="$1"
    if mkdir "$lock_dir" 2>/dev/null; then
      printf '%s\n' $$ > "$lock_dir/pid"
      return 0
    fi
    # Existing lock: break it if the holder process is gone.
    local holder
    holder="$(cat "$lock_dir/pid" 2>/dev/null || echo 0)"
    if [[ "$holder" =~ ^[0-9]+$ ]] && (( holder > 0 )) && ! kill -0 "$holder" 2>/dev/null; then
      rm -rf "$lock_dir"
      …
    fi
    return 1
  }
  ```

  Unchanged by this plan. `kill -0` correctly refuses to break a live
  holder's lock; the bug is that the live holder is `wait`-blocked,
  not dead. A+B fix the upstream blocker.

- **A-011 — `set -euo pipefail` at `bin/common.sh:7`.** Verbatim:

  ```bash
  set -euo pipefail
  ```

  Constraint cited by brainstorm A-6: A's sequential rewrite MUST
  capture rc explicitly (`|| dispatch_rc=$?`) at each step so a
  non-zero `gtimeout` rc doesn't abort dispatch.sh before the
  renderer's post-stream extraction runs. Task 2's invocation rewrite
  applies this pattern at every cmd-invocation arm.

- **A-012 — `/usr/bin/perl` is present on stock macOS; POSIX module
  ships at `/System/Library/Perl/5.34/darwin-thread-multi-2level/POSIX.pm`.**
  Verified at plan time on the dispatch host by `type perl` (returns
  `perl is /usr/bin/perl`) and Glob of `/System/Library/Perl/**/POSIX.pm`
  (returns `/System/Library/Perl/5.34/darwin-thread-multi-2level/POSIX.pm`).
  `POSIX::setsid` is a sub of the POSIX module so its availability
  follows from the module file's presence. Defensive: the new test
  fixture T-A's preamble runs
  `/usr/bin/perl -MPOSIX -e 'POSIX::setsid; print "ok\n"'` as a
  precondition probe; on rc!=0 the test SKIPs with a clear message
  (no plan-side regression).

- **A-013 — `setsid` is NOT on stock macOS.** Verified at plan time
  by `type setsid` returning `setsid not found` (exit 1). Confirms
  D-002's perl-based shim is the right primitive (vs. Alt-B1
  Homebrew util-linux's `gsetsid` which would add a third `g`-prefixed
  platform tool).

- **A-014 — `CLAUDE.md` "Failure-mode quick reference" table
  exists.** Verified by the system-prompt addendum (it ships the table
  verbatim). The table is a markdown two-column `| Symptom | Where to
  look |` grid. Task 6 inserts ONE new row.

  Content anchor for Task 6's Edit: the literal row whose Symptom
  cell starts `| Tick is silent |` (the FIRST table row; appears
  EXACTLY ONCE in CLAUDE.md per grep). The new ENG-131 row is
  inserted IMMEDIATELY AFTER this first row so the silent-hang case
  is co-located with the "Tick is silent" generic case operators
  already check first. The exact `old_string` anchor is the full
  multi-line cell text including the trailing newline; see Task 6
  body for the literal.

- **A-015 — Test-gate closure sweep — REMOVALS.** This plan REMOVES
  exactly ONE token from production+test code:

  1. **`bin/dispatch-test.sh:3030` literal string
     `trap 'release_claude_mutex' EXIT`** in the `if [[ "$_TBA_PRIOR"
     == ... ]]; then` comparison AND the matching fail message at
     line 3033. Task 3 below replaces both with `trap _dispatch_cleanup EXIT`.
     **Sibling-test sweep:** `grep -rn "trap 'release_claude_mutex' EXIT" bin/*-test.sh`
     returns exactly the two sites above (the `==` comparand and the
     fail-message literal — both in the same AC-TRAP-BEFORE-ACQUIRE
     block, both in `bin/dispatch-test.sh`). NO other test file pins
     the literal string. Verified by direct grep at plan time. Task 3
     captures both. **Zero unaddressed closure defects.**

  2. **`bin/dispatch.sh:507` `trap 'release_claude_mutex' EXIT`**
     production line is replaced by `trap _dispatch_cleanup EXIT`
     (Task 2). `grep -rn "trap 'release_claude_mutex' EXIT" bin/`
     returns three sites: the production line (507) and the two
     test-file references just enumerated. All three are captured by
     Tasks 2+3.

- **A-016 — Test-gate closure sweep — ADDITIONS.** New tokens
  introduced (defensive check that no sibling test pins their
  ABSENCE):

  - `_dispatch_cleanup` function name — new. `grep -rn _dispatch_cleanup bin/`
    at plan time returns zero matches (only the brainstorm-doc body
    references it). No sibling test pins absence. Safe.
  - `/usr/bin/perl` literal — new. `grep -rn '/usr/bin/perl' bin/`
    at plan time returns zero matches. No sibling test pins absence.
    Safe.
  - `POSIX::setsid` literal — new. `grep -rn 'POSIX::setsid' bin/` at
    plan time returns zero matches. Safe.
  - `_cmd_pgid` variable name — new internal to dispatch.sh main().
    No sibling pins. Safe.
  - `_capture_path` variable name — new internal to dispatch.sh main().
    No sibling pins. Safe.
  - `.cmd-capture-${stage}.ndjson.tmp` filename pattern — new dot-prefixed
    artifact under `$issue_state_dir`. `grep -rn 'cmd-capture' bin/`
    at plan time returns zero matches. No sibling test pins ABSENCE
    of this artifact. Safe.

  **Conclusion:** zero conflicting absence pins; no additional closure
  defects.

- **A-017 — Plan doc basename satisfies `partition_dirty_paths::D-004`.**
  Basename `2026-05-17-eng-131-gtimeout-watchdog-can-hang-dispatch-indefinitely-orphan-pipe-fds.md`
  carries `eng-131` (lowercase) per the prompt's basename requirement.
  Sibling JSON `…orphan-pipe-fds.json` mirrors the slug. ✓

- **A-018 — Branch prefix matches Bug label.** Branch
  `fix/eng-131-gtimeout-watchdog-can-hang-dispatch-indefinitely-orphan-pipe-fds`
  matches the `fix/` prefix mandated for Bug per CLAUDE.md "Linear
  conventions the harness depends on." ✓

- **A-019 — `learned-rules/harness/plan.md` does not exist.**
  Verified by Glob `learned-rules/harness/*.md` returning only
  `build.md` and `project-profile.md`. Skip per prompt's "skip if not
  present" guidance for plan-stage learned rules.

- **A-020 — No `.pipeline-config/config.json` exists for the
  harness-self target.** Verified — brainstorm A-022 cross-reference
  also confirms (this target is operator-local). No config.json edits
  are needed because Layer A+B introduce no new tunables.

- **A-021 — Renderer's internal `tee "$raw_capture" | jq …` pipe
  stays in place (D-001 / EC-2b).** `bin/dispatch.sh:66-67`:

  ```bash
    tee "$raw_capture" \
      | jq -nRr --unbuffered '
  ```

  This INTERNAL renderer pipe is NOT removed. `tee` is a known-
  terminating writer that reads to EOF from its (now file-backed)
  stdin and exits; it spawns no descendants. The brainstorm pins
  this distinction in §EC-2b ("the bug class A fixes is *long-lived
  descendants of `cmd` holding fd1 across SIGKILL* — `tee` is
  short-lived and well-behaved by construction"). Task 2's diff
  comment MUST inline this pinning so a future reader doesn't widen
  the rule. Reference only; no edit at this site.

- **A-022 — Capture-file location: `${issue_state_dir}/.cmd-capture-${stage}.ndjson.tmp`.**
  Per brainstorm D-001 / OQ-2 resolution. Sibling of the renderer's
  existing internal `${issue_dir}/.raw-stream.ndjson.tmp` and
  `${issue_dir}/.envelope-transcript-${stage}` artifacts; same per-issue
  scoping, mode 0600 via `umask 077`. Distinct filename
  (`cmd-capture` vs `raw-stream`) — no overlap. Both dot-prefixed so
  artifact-scanner invisible. **Ungated callers** (no
  `issue_state_dir` — release / retrospective / mutex-test) fall back
  to `mktemp -t pipeline-cmd-XXXXXX` under `umask 077`; per
  brainstorm, those callers don't emit cost telemetry and have no
  forensic-continuity requirement.

- **A-023 — `_render_and_capture_stream` writes the envelope sidecar
  at `bin/dispatch.sh:142-144`.** Verbatim:

  ```bash
    if [[ -s "$raw_capture" && -n "$stage" ]]; then
      cp "$raw_capture" "$envelope_sidecar" 2>/dev/null || true
    fi
  ```

  This sidecar at `${issue_dir}/.envelope-transcript-${stage}` is read
  post-dispatch by `bin/run-stage.sh::_validate_dispatch_envelope`. A's
  pipe-to-file refactor preserves this sidecar — the renderer still
  runs (just reading from a file now); its `cp` to the envelope
  sidecar still fires. Verified by inspection of the renderer's logic
  flow (the `cp` is a function-tail step, not pipe-conditional). No
  edit; reference only.

## File Structure

Modified or new files only. No new exit codes (124 is preserved). No
new Linear labels. No new pipeline-events.json tokens. No new schema
files. No new test files (T-A and T-B append to `bin/dispatch-test.sh`).
No new prompt tokens. No AGENT_PROMPTS.md changes (orchestrator-only
fix; A-4 architectural constraint).

- **`bin/dispatch.sh`** — three edit sites (one file, three logical
  changes; one Edit call per site to keep diff hunks reviewable):
  - **Site 1 (Task 2.1):** insert `_dispatch_cleanup` function
    definition at the END of common.sh function imports block — i.e.
    AFTER `source "$SCRIPT_DIR/common.sh"` (line 18) and BEFORE the
    `_render_and_capture_stream` function definition (line 47). Hint:
    ~line 19-46. New function body composes (a) `_cmd_pgid` integer-
    validated pgrp signal, (b) `_capture_path` removal, (c)
    `release_claude_mutex` invocation. ~15 lines.
  - **Site 2 (Task 2.2):** replace the pre-acquire trap line at line
    507 (`trap 'release_claude_mutex' EXIT`) with
    `trap _dispatch_cleanup EXIT`. ~1 line. Anchor per A-001.
  - **Site 3 (Task 2.3):** rewrite the four invocation arms at lines
    646-669 (per A-003) to: (a) declare `_capture_path` per A-022
    placement rules; (b) install the unified trap (already done at
    Site 2); (c) wrap the `cmd` invocation under
    `/usr/bin/perl -e 'use POSIX qw(setsid); setsid; exec @ARGV'` per
    D-002; (d) capture `_cmd_pgid=$!`; (e) `wait "$_cmd_pgid" || dispatch_rc=$?`;
    (f) run the renderer (or no-renderer fallback) reading from
    `< "$_capture_path"`. ~30-40 lines net (replaces ~24 existing lines).
- **`bin/dispatch-test.sh`** — two edit sites:
  - **Site 1 (Task 3):** update the AC-TRAP-BEFORE-ACQUIRE block at
    lines 3007-3035 (per A-006) — replace the literal expected-prior-
    line string and PASS/FAIL messages, AND append a sibling
    assertion that `_dispatch_cleanup` is defined upstream of the
    trap-install line AND its function body contains a
    `release_claude_mutex` call (preserves SEMANTIC invariant). ~10
    lines net change.
  - **Site 2 (Task 4 and Task 5):** append T-A (no-hang) and T-B
    (no-orphan) fixtures IMMEDIATELY BEFORE the final summary block
    at end of file. Both fixtures source `bin/dispatch.sh` indirectly
    via subprocess (so dispatch.sh's `main` runs in full) and rely on
    a synthesised fake-claude shim script written to `$_TEST_STUB_DIR`.
    ~80-100 lines total appended.
- **`CLAUDE.md`** — one edit site:
  - **Task 6:** insert one new row in the "Failure-mode quick
    reference" table immediately AFTER the existing "Tick is silent"
    row (per A-014). The new row's Symptom cell names ENG-131-class
    silent-hangs; the "Where to look" cell is a multi-line bullet
    runbook per brainstorm §10 residual P1 #2. ~5-8 lines.

Explicitly out of scope (per Linear "Out of scope" §, brainstorm
§D-004, and the architectural-constraint sweep):

- `bin/run-stage.sh` — UNCHANGED. The rc-dispatch table at lines
  1444-1567 handles rc=124 correctly today; A+B fix the upstream
  blocker so the existing arm fires.
- `bin/common.sh` — UNCHANGED. `failure_outcome_for_exit:276` already
  maps 124 → `dispatch-timeout`.
- `AGENT_PROMPTS.md` — UNCHANGED. Orchestrator-only fix; stage prompts
  are agnostic to dispatch.sh's capture shape (A-4 constraint).
- `bin/run-local.sh` — UNCHANGED. Silent-skip at `:51-54` is correct;
  A+B prevent the live-`wait`-block precondition.
- `bin/run-local-helpers.sh` — UNCHANGED. `acquire_lock:916-934`
  correctly refuses to break a live-holder lock — preserved by design.
- `bin/pipeline-events.json` — UNCHANGED. No new verdict / reason
  tokens.
- `learned-rules/harness/project-profile.md` — UNCHANGED. No new test
  file is added (T-A and T-B append to `bin/dispatch-test.sh` which
  is already in the allowlist); no new dispatch tool requirements.
- `bin/dispatch.sh::allowed_tools_for` — UNCHANGED. No new agent-side
  tool requirements.
- `docs/runbooks/recovery.md` — UNCHANGED. The rc=124 recovery recipe
  (`bash bin/pipeline.sh decide $ident --action continue`) already
  documented at `bin/run-stage.sh:1454-1455`; A+B make rc=124
  reliably reachable.
- Sibling stuck-tick alarm (D-004 #1) — separate ticket; not this PR.
- Migration off `gtimeout` (D-004 #2) — separate ticket; not this PR.
- MCP server lifecycle changes (D-004 #3) — upstream `claude` CLI
  concern; not addressable in the harness.

## API Contract

no new API surface

(The harness has no FE↔BE API surface of its own — it is a Bash
orchestration toolkit. ENG-131 changes a single Bash file's internal
invocation shape and adds two sibling tests. The `_dispatch_cleanup`
function is dispatch.sh-private (not exported via `export -f`).
There are no new prompt tokens, no new Linear comment shapes, no
new metrics events, no new pipeline-event verdicts. Renderer
contract preserved (G-4). Exit-code taxonomy preserved (G-3).)

## Backend Tasks

Task ordering: Task 0 (rebase) MUST be first (per "Branch-base
freshness check"); Task 1 (re-verify anchors) MUST follow
immediately. Then Tasks 2-6 follow the natural dependency graph below.
Task 7 (gates) depends on all the others.

Task 0 → Task 1 → Task 4 (T-A failing fixture — write FIRST per
D-003 TDD) → Task 2 (implement A: pipe→capture-file AND install
composed trap; AND wrap cmd under perl-setsid for B) → Task 3 (update
AC-TRAP-BEFORE-ACQUIRE) → Task 5 (T-B failing fixture; then re-run
all dispatch-tests) → Task 6 (CLAUDE.md runbook row) → Task 7
(full gate suite).

**TDD discipline (per brainstorm D-003).** Task 4 (T-A failing first)
is intentionally ordered BEFORE Task 2's implementation, even though
Task 2 implements BOTH A and B. The TDD precedent is preserved by
running T-A in failing state once (rc!=0; hang or unbounded wait)
BEFORE Task 2's Edits, capturing the failure mode, then implementing
Task 2 and re-running T-A. Similarly Task 5 (T-B) runs in failing
state once BEFORE Task 2 (T-B should hang or pgrep returns non-empty)
to capture the failure mode. This is a manual discipline; the
implement agent SHOULD record the failing-rc capture in the dispatch
transcript as evidence of TDD compliance.

### Task 0: Rebase onto origin/main

- `depends_on: []`
- `touches: <branch state only — git rebase>`

Steps:

- [ ] **0.1** Run `git fetch origin main && git rebase origin/main`.
  The worktree's current HEAD is 2 commits behind origin/main. Both
  drifted commits touch `bin/run-stage.sh::_ensure_progress_md` (ENG-109
  follow-up) — files NOT modified by this plan. Clean drift; no
  conflicts expected.
- [ ] **0.2** Verify the rebase succeeded with no conflicts:
  `git status --porcelain` returns empty AND
  `git log --oneline HEAD..origin/main` returns empty.
- [ ] **0.3** Re-verify every Assumption Inventory anchor at the
  post-rebase HEAD. Re-grep one canonical literal per file:
  - `bin/dispatch.sh` — `grep -c "trap 'release_claude_mutex' EXIT" bin/dispatch.sh`
    MUST return exactly 1 (anchors A-001 + A-015).
  - `bin/dispatch-test.sh` — `grep -c "^# ─── AC-TRAP-BEFORE-ACQUIRE" bin/dispatch-test.sh`
    MUST return exactly 1 (anchor A-006).
  - `CLAUDE.md` — `grep -c "^| Tick is silent |" CLAUDE.md`
    MUST return exactly 1 (anchor A-014).
- [ ] **0.4** If the rebase produces ANY conflict OR any anchor
  count drifts from the expected value, halt with
  `bash bin/pipeline.sh event ENG-131 verdict halt --reason agent-blocked`
  and a Linear comment naming the conflict/drift. Do NOT resolve
  silently.

### Task 1: Re-verify Assumption Inventory + probe perl POSIX::setsid

- `depends_on: [0]`
- `touches: <read-only — no file edits>`

Steps:

- [ ] **1.1** For each of A-001, A-002, A-003, A-006, A-007, A-008,
  A-014, A-021, A-023: re-grep the file for the literal content-anchor
  string named in the inventory entry. Each MUST match exactly once
  (or the documented count). If any matches zero times OR more than
  once, halt with `agent-blocked` and a Linear comment naming the
  drift.
- [ ] **1.2** Probe `/usr/bin/perl -MPOSIX -e 'POSIX::setsid; print "ok\n"'`.
  Expected: rc=0 and stdout literal `ok`. The probe forks once
  (perl spawns a new session/pgrp during the `setsid` call) so it
  exits 0 only when POSIX::setsid actually works. If rc!=0, halt with
  `agent-blocked` and a Linear comment naming the perl/POSIX absence
  — falls back to Homebrew gsetsid as Alt-B1 (out-of-scope manual
  re-plan).
- [ ] **1.3** Confirm `bin/dispatch.sh` line 7 (or thereabouts in the
  header comment block) has NOT acquired any new shebang variants
  since plan time; the per-file `set -euo pipefail` inherited from
  common.sh:7 is preserved.

If all three pass, proceed to Task 4 (T-A failing fixture).

### Task 4: Write T-A failing-first fixture for the no-hang assertion

- `depends_on: [1]`
- `touches: bin/dispatch-test.sh`

Per brainstorm D-003: TDD. Write the failing test BEFORE Task 2's
implementation lands.

Steps:

- [ ] **4.1** Append a new fixture group titled `T-A — ENG-131
  no-hang (orphan-writer scenario)` at the end of
  `bin/dispatch-test.sh`, IMMEDIATELY BEFORE the file's final summary
  block. Content anchor: the file-tail `# ─── Summary ───` comment
  header (file-unique per ENG-109 plan A-020 cross-reference).
- [ ] **4.2** The fixture's shape (sketch — implement agent picks
  exact bash form consistent with the file's existing fixture style
  per AT1-AT10 conventions at lines 1683+):

  ```bash
  # T-A — ENG-131 no-hang: orphan-writer scenario.
  # Construct a fake-claude shim that exits cleanly but leaves a
  # background writer (sleep 9999 1>&1 &) holding the inherited fd1.
  # Assert dispatch.sh exits within kill_after + ε (≤ 12 s) of
  # gtimeout's SIGKILL with rc=124 AND log file contains the literal
  # substring "[cost] no result event found in stream" OR
  # "[cost] partial usage captured".

  printf '\n--- T-A: ENG-131 no-hang (orphan-writer scenario) ---\n'
  TA_FAKE_CLAUDE="$_TEST_STUB_DIR/fake-claude-ta"
  cat > "$TA_FAKE_CLAUDE" <<'FAKE'
  #!/usr/bin/env bash
  # Emit one NDJSON system-init event then spawn an orphan writer
  # holding fd1 inherited from us (the parent gtimeout-managed proc).
  printf '%s\n' '{"type":"system","subtype":"init","session_id":"taXXXXXX","model":"test"}'
  ( sleep 9999 1>&1 ) &   # background writer keeps fd1 open after we exit
  exit 0
  FAKE
  chmod +x "$TA_FAKE_CLAUDE"
  # Override PATH so dispatch.sh's `require_bin claude` finds the shim.
  # Use a fast 5-second budget (gtimeout 0:00:05) so SIGKILL fires
  # within test-runtime tolerance; the per-stage default cap is
  # 30 min which would obscure the no-hang assertion.
  TA_BUDGET_SECONDS=5
  # … (full fixture body: invoke dispatch.sh under PATH-override + a
  # CONFIG that pins dispatch_timeout_minutes to a small fractional
  # value, OR via _PIPELINE_GTIMEOUT_SECONDS_OVERRIDE if such a hook
  # already exists — implement agent verifies at coding time. Assert
  # dispatch.sh exits within 12 s wall-clock with rc=124. Assert the
  # log file (or capture-file location, per A-022) contains the
  # expected cost-renderer substring. Assert no orphan writer is
  # left after the test cleanup phase.)
  ```

- [ ] **4.3** Verify the fixture FAILS before Task 2 lands: run
  `bash bin/dispatch-test.sh 2>&1 | grep -A2 "T-A:"`; expected: a
  FAIL line or a timeout-via-test-framework (whichever comes first).
  Capture the failure mode in the dispatch transcript.

  **Critical:** the failing run may itself hang (this is the bug
  class we're catching). The implement agent SHOULD wrap the failing
  T-A run under `gtimeout 60s bash bin/dispatch-test.sh` to bound
  the failing-run capture. If the test framework already has its
  own outer budget (per `dispatch-test.sh`'s existing AT10
  large-fixture handling), the existing wrapper suffices.

  If T-A unexpectedly PASSES before Task 2's implementation, the
  bug-class hypothesis is wrong; halt with `agent-blocked` and a
  Linear comment naming the divergence.

### Task 2: Implement A (pipe→capture) + B (perl-setsid) + composed trap

- `depends_on: [4]`
- `touches: bin/dispatch.sh`

Three Edit sites (one logical per site to keep hunks reviewable).
Each Edit's `old_string` MUST anchor on the multi-line literal listed
in the named Assumption Inventory entry; bare line numbers are
informational only.

Steps:

- [ ] **2.1 (Site 1)** Insert the `_dispatch_cleanup` function
  definition. Content anchor: AFTER the literal line
  `source "$SCRIPT_DIR/common.sh"` (line 18, file-unique) AND BEFORE
  the literal line `# ─── Stream-json renderer (ENG-26 D-002) ──`
  (line 20, file-unique). The two anchors fence the insertion site
  without ambiguity. The new function body:

  ```bash
  # _dispatch_cleanup — composed EXIT trap (ENG-131 D-001 + D-002).
  # Single trap that:
  #  1. Signals the cmd's process-group (D-002 pgrp reap of MCP orphans).
  #     `_cmd_pgid` is set after the cmd subshell spawns; guards make
  #     this no-op safely when cmd never spawned (die-before-spawn path).
  #  2. Removes the per-issue capture file (D-001 cleanup).
  #  3. Calls release_claude_mutex (preserves AC-TRAP-BEFORE-ACQUIRE
  #     invariant — release on EVERY exit path between trap install
  #     and any later die()).
  # Integer-validate _cmd_pgid before `kill -- -$pgid` (defense against
  # future regressions that could leave it empty / non-numeric).
  _dispatch_cleanup() {
    if [[ -n "${_cmd_pgid:-}" && "$_cmd_pgid" =~ ^[0-9]+$ ]]; then
      kill -TERM -- "-$_cmd_pgid" 2>/dev/null || true
      sleep 1
      kill -KILL -- "-$_cmd_pgid" 2>/dev/null || true
    fi
    if [[ -n "${_capture_path:-}" && -f "$_capture_path" ]]; then
      rm -f "$_capture_path"
    fi
    release_claude_mutex
  }
  ```

- [ ] **2.2 (Site 2)** Replace the pre-acquire trap line per A-001.
  Edit: `old_string` is the literal two-line block
  `    trap 'release_claude_mutex' EXIT\n    acquire_claude_mutex`;
  `new_string` is `    trap _dispatch_cleanup EXIT\n    acquire_claude_mutex`.
  Whitespace exact (4-space indent inherited from `main()` scope).

- [ ] **2.3 (Site 3)** Rewrite the four invocation arms at lines
  646-669 per A-003. Content anchor: the literal 24-line block from
  `if [[ -n "$log_file" ]]; then` through the closing `fi` of the
  outer if/else (uniquely anchored by the inner-arm literal
  `      "${cmd[@]}" < "$prompt_file" > "$log_file"` per A-003). The
  new body:

  ```bash
    # ENG-131 D-001 + D-002: sequential capture file + perl-setsid wrap
    # of cmd. The cmd's stdout is captured to a per-issue ndjson file;
    # the renderer reads it post-process. perl exec's into setsid then
    # the gtimeout/claude chain so the wrapped tree is its own session +
    # pgrp leader ($! IS the leader's PID — verified because `exec` is
    # used INSIDE the &-backgrounded subshell). dispatch_rc captures
    # gtimeout's 124 / claude's rc / etc. The EXIT trap installed at
    # site 2 (_dispatch_cleanup) signals the pgrp on exit. The renderer's
    # internal `tee | jq` pipe (line 66-67) stays — its writer is `tee`,
    # a short-lived non-spawning process, so orphan-fd retention is
    # impossible there (EC-2b). Distinct from the OUTER `cmd | renderer`
    # pipe we removed, whose writer was the long-lived MCP-descendant
    # tree.
    local _capture_path=""
    if [[ -n "$issue_state_dir" ]]; then
      _capture_path="${issue_state_dir}/.cmd-capture-${stage}.ndjson.tmp"
      ( umask 077; : > "$_capture_path" )    # pre-clean stale (EC-1b)
    else
      _capture_path="$( umask 077; mktemp -t pipeline-cmd-XXXXXX )"
    fi

    local dispatch_rc=0
    local _cmd_pgid=""
    if [[ -n "$log_file" ]]; then
      mkdir -p "$(dirname "$log_file")"
      log "dispatching stage=$stage, log=$log_file"
    else
      log "dispatching stage=$stage"
    fi

    ( exec /usr/bin/perl -e 'use POSIX qw(setsid); setsid; exec @ARGV' \
        "${cmd[@]}" < "$prompt_file" > "$_capture_path" ) &
    _cmd_pgid=$!
    if ! [[ "$_cmd_pgid" =~ ^[0-9]+$ ]]; then
      log "[dispatch] _cmd_pgid not numeric ($_cmd_pgid); pgrp cleanup disabled"
      _cmd_pgid=""
    fi
    wait "$_cmd_pgid" || dispatch_rc=$?

    local render_rc=0
    if [[ -n "$usage_file" && -n "$issue_state_dir" ]]; then
      if [[ -n "$log_file" ]]; then
        _render_and_capture_stream "$usage_file" "$issue_state_dir" "$stage" \
          < "$_capture_path" > "$log_file" || render_rc=$?
      else
        _render_and_capture_stream "$usage_file" "$issue_state_dir" "$stage" \
          < "$_capture_path" || render_rc=$?
      fi
    else
      # No-renderer arms (ungated callers — release / retro / mutex-test):
      # forward the captured ndjson to log_file (if set) or stdout.
      if [[ -n "$log_file" ]]; then
        cat "$_capture_path" > "$log_file" 2>/dev/null || true
      else
        cat "$_capture_path" 2>/dev/null || true
      fi
    fi

    # Renderer rc takes precedence over dispatch rc (mirrors today's
    # pipefail "rightmost non-zero" semantics — renderer's transcript-
    # scan halts 22/23/26/29/31 override gtimeout's 124 when both fire).
    if (( render_rc != 0 )); then
      dispatch_rc=$render_rc
    fi
  ```

  **Post-edit invariants the implement agent MUST verify** (`grep`
  reproducer commands at edit time):

  - `grep -c "${cmd\[@\]} < \"\$prompt_file\" | _render_and_capture_stream" bin/dispatch.sh`
    MUST return 0 (the old pipe shape is gone).
  - `grep -c "/usr/bin/perl -e 'use POSIX qw(setsid)" bin/dispatch.sh`
    MUST return 1 (exactly one perl-setsid wrap).
  - `grep -c "trap _dispatch_cleanup EXIT" bin/dispatch.sh`
    MUST return 1 (exactly one composed trap).
  - `grep -c "trap 'release_claude_mutex' EXIT" bin/dispatch.sh`
    MUST return 0 (the old trap is gone).
  - `bash -n bin/dispatch.sh` exits 0 (syntax-clean).

- [ ] **2.4** Run `bash bin/dispatch-test.sh 2>&1 | tail -50` and
  verify T-A now PASSES. If it doesn't, do NOT proceed to Task 3 —
  iterate Task 2 until T-A passes. The expected pass message names
  the literal `rc=124` and the `[cost]` substring per Task 4.2.

### Task 3: Update AC-TRAP-BEFORE-ACQUIRE for the composed trap

- `depends_on: [2]`
- `touches: bin/dispatch-test.sh`

Steps:

- [ ] **3.1** Edit `bin/dispatch-test.sh` at the AC-TRAP-BEFORE-ACQUIRE
  block per A-006. Content anchor: the literal block
  `# ─── AC-TRAP-BEFORE-ACQUIRE ──` through the matching `fi` closing
  the outer if/else. The `old_string` is the full multi-line block
  (lines 3007-3035, ~29 lines); `new_string` is the same block with
  FOUR substitutions (all four — verified by `grep -n "trap 'release_claude_mutex' EXIT" bin/dispatch-test.sh`
  returning lines 3013, 3030, 3033 at plan time):

  - Substitution 1 (prose comment at line ~3013): the rationale
    paragraph reads
    `# immediately preceding `acquire_claude_mutex` in dispatch.sh must be\n# `trap 'release_claude_mutex' EXIT`. A future reorder regression would`
    — update the literal cited form to
    `# immediately preceding `acquire_claude_mutex` in dispatch.sh must be\n# `trap _dispatch_cleanup EXIT` (the unified composed-cleanup trap;\n# preserves the original `release_claude_mutex` semantic via\n# `_dispatch_cleanup`'s internal call). A future reorder regression would`.
    Documentation hygiene — keeps the comment self-consistent with
    the assertion.
  - Substitution 2 (comparison literal at line ~3030):
    `if [[ "$_TBA_PRIOR" == "trap 'release_claude_mutex' EXIT" ]]; then`
    becomes `if [[ "$_TBA_PRIOR" == "trap _dispatch_cleanup EXIT" ]]; then`.
  - Substitution 3 (PASS message): the PASS message
    `"AC-TRAP-BEFORE-ACQUIRE: dispatch.sh installs release trap on the line immediately preceding acquire_claude_mutex (line $_TBA_ACQUIRE_LINE)"`
    becomes
    `"AC-TRAP-BEFORE-ACQUIRE: dispatch.sh installs _dispatch_cleanup trap on the line immediately preceding acquire_claude_mutex (line $_TBA_ACQUIRE_LINE); _dispatch_cleanup composes release_claude_mutex"`.
  - Substitution 4 (FAIL message at line ~3033):
    `"expected prior non-blank/non-comment line to be \"trap 'release_claude_mutex' EXIT\", got: $_TBA_PRIOR"`
    becomes
    `"expected prior non-blank/non-comment line to be \"trap _dispatch_cleanup EXIT\", got: $_TBA_PRIOR"`.

  **Quote-form pin (load-bearing).** Production replacement (Task
  2.2) writes the bare form `trap _dispatch_cleanup EXIT` (no single
  quotes around the function name); Substitutions 2 and 4 above use
  the bare form. The two MUST match byte-for-byte because the
  AC-TRAP-BEFORE-ACQUIRE test does literal-string equality
  (`if [[ "$_TBA_PRIOR" == "trap _dispatch_cleanup EXIT" ]]`); a
  quoted-vs-unquoted mismatch flips PASS to FAIL. Implement agent
  MUST verify the byte-identity by post-edit grep:
  `grep -c "^[[:space:]]*trap _dispatch_cleanup EXIT[[:space:]]*$" bin/dispatch.sh`
  and `grep -c '"trap _dispatch_cleanup EXIT"' bin/dispatch-test.sh`
  both return >=1.

- [ ] **3.2** Append a sibling SEMANTIC-invariant assertion
  IMMEDIATELY AFTER the AC-TRAP-BEFORE-ACQUIRE block's closing `fi`
  AND BEFORE the next test group's `# ─── ENG-109:` comment header
  (file-unique anchor). New assertion: verify `_dispatch_cleanup` is
  defined upstream of the trap-install line in `bin/dispatch.sh` AND
  the function body calls `release_claude_mutex`. Sketch:

  ```bash
  # ─── ENG-131: AC-DISPATCH-CLEANUP-COMPOSES-RELEASE ─────────────────
  # The AC-TRAP-BEFORE-ACQUIRE invariant above guards the literal
  # trap-install line. The SEMANTIC invariant the test was originally
  # written to protect (release_claude_mutex runs on every exit path
  # between trap-install and any later die()) is preserved by the
  # composed shape ONLY IF _dispatch_cleanup actually calls
  # release_claude_mutex. Pin both: (a) _dispatch_cleanup is defined
  # upstream of the trap-install line; (b) _dispatch_cleanup's body
  # contains release_claude_mutex.
  _DC_TRAP_LINE="$(grep -n '^[[:space:]]*trap _dispatch_cleanup EXIT[[:space:]]*$' "$SCRIPT_DIR/dispatch.sh" | head -1 | cut -d: -f1)"
  _DC_DEF_LINE="$(grep -n '^_dispatch_cleanup()' "$SCRIPT_DIR/dispatch.sh" | head -1 | cut -d: -f1)"
  if [[ -z "$_DC_DEF_LINE" || -z "$_DC_TRAP_LINE" ]]; then
    fail_at "AC-DISPATCH-CLEANUP-COMPOSES-RELEASE" "missing _dispatch_cleanup definition or trap install"
  elif (( _DC_DEF_LINE >= _DC_TRAP_LINE )); then
    fail_at "AC-DISPATCH-CLEANUP-COMPOSES-RELEASE" \
      "_dispatch_cleanup defined at line $_DC_DEF_LINE but trap installs at $_DC_TRAP_LINE; definition must be upstream"
  else
    # Probe body for release_claude_mutex (function spans definition through
    # closing brace `^}` at column 0).
    _DC_BODY="$(awk -v def="$_DC_DEF_LINE" '
      NR == def { in_fn = 1 }
      in_fn { print }
      in_fn && /^\}/ { exit }
    ' "$SCRIPT_DIR/dispatch.sh")"
    if printf '%s\n' "$_DC_BODY" | grep -q 'release_claude_mutex'; then
      pass_at "AC-DISPATCH-CLEANUP-COMPOSES-RELEASE: _dispatch_cleanup body calls release_claude_mutex (def line $_DC_DEF_LINE, trap line $_DC_TRAP_LINE)"
    else
      fail_at "AC-DISPATCH-CLEANUP-COMPOSES-RELEASE" \
        "_dispatch_cleanup body does NOT contain release_claude_mutex; AC-TRAP-BEFORE-ACQUIRE semantic invariant violated"
    fi
  fi
  ```

- [ ] **3.3** Run `bash bin/dispatch-test.sh 2>&1 | grep "AC-TRAP\|AC-DISPATCH-CLEANUP"`
  and verify both PASS messages appear.

### Task 5: Write T-B fixture for the no-orphan assertion

- `depends_on: [2]`
- `touches: bin/dispatch-test.sh`

Per brainstorm D-003: write T-B AFTER Task 2 because T-B requires
dispatch.sh to actually exit (which only happens post-A).

Steps:

- [ ] **5.1** Append a new fixture group titled `T-B — ENG-131
  no-orphan (descendant-tree reap)` at the end of `bin/dispatch-test.sh`,
  IMMEDIATELY AFTER the T-A block from Task 4 (which itself sits
  immediately before the file-final summary block).
- [ ] **5.2** The fixture's shape (sketch — implement agent picks
  exact bash form consistent with AT-style fixtures at lines 1683+):

  ```bash
  # T-B — ENG-131 no-orphan: descendant-tree reap.
  # Synthesise a fake-claude shim that spawns a 3-level deep sleep
  # tree (sh -c "sh -c \"sleep 9999\" &" &), then exits cleanly.
  # After dispatch.sh's EXIT trap fires (which signals the pgrp),
  # assert pgrep -g <captured_pgid> returns empty (rc=1, no stdout)
  # within 1.5 s. The captured pgid is read from the fake-claude shim's
  # init NDJSON event (the shim writes its own setpgid leader's pgid
  # into the system-init event's session_id field via /bin/ps).

  printf '\n--- T-B: ENG-131 no-orphan (descendant-tree reap) ---\n'
  TB_FAKE_CLAUDE="$_TEST_STUB_DIR/fake-claude-tb"
  cat > "$TB_FAKE_CLAUDE" <<'FAKE'
  #!/usr/bin/env bash
  # Our PID == our PGID because perl-setsid put us in a new session.
  # Emit our PGID via the init event so the test can pgrep -g <pgid>.
  PGID="$$"
  printf '%s\n' "{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"tb${PGID}\",\"model\":\"test\"}"
  # Three-level descendant tree; each `&` reparents up the chain.
  ( sh -c '( sh -c "sleep 9999" & ) &' ) &
  exit 0
  FAKE
  chmod +x "$TB_FAKE_CLAUDE"
  # Run dispatch.sh via the PATH-override shim path; capture the
  # transcript's first system-init session_id (which encodes the pgid).
  # … (full fixture body. The assertion: after dispatch.sh exits,
  # `pgrep -g $TB_PGID 2>&1` returns rc=1 within 1.5 s. The "within
  # 1.5 s" tolerance allows for the 1-second sleep inside
  # _dispatch_cleanup between SIGTERM and SIGKILL plus syscall
  # latency.)
  ```

- [ ] **5.3** Run the full `bash bin/dispatch-test.sh` and verify ALL
  three new ENG-131 assertions PASS (T-A, T-B, AC-DISPATCH-CLEANUP-
  COMPOSES-RELEASE) AND the existing AC-TRAP-BEFORE-ACQUIRE PASSES
  AND zero existing fixtures regressed. If ANY regression, halt
  immediately — do NOT proceed to Task 6.

### Task 6: Add CLAUDE.md "Failure-mode quick reference" row

- `depends_on: [5]`
- `touches: CLAUDE.md`

Steps:

- [ ] **6.1** Edit `CLAUDE.md` to insert ONE new row in the
  "Failure-mode quick reference" table, IMMEDIATELY AFTER the
  existing first row `| Tick is silent | $PROJECT_STATE_DIR/logs/local-YYYY-MM-DD.log, then per-stage transcript |`.
  Content anchor: the literal full text of that first row (verified
  unique in CLAUDE.md by grep). The Edit's `new_string` is the first
  row PLUS a newline PLUS the new ENG-131 row.

  New row body (multi-line bullet runbook per residual P1 #2):

  ```
  | Tick is silent for >2 ticks (≥10 min) AND `bin/status.sh` shows the issue with `stage:*` but no fresh dispatch log → suspect ENG-131-class hang | Pre-ENG-131 (≤ 2026-05-15): `bin/dispatch.sh`'s outer `cmd \| renderer` pipe could leave reader blocked when MCP-server descendants orphaned to launchd held the inherited fd1; the lock holder's `wait` blocked indefinitely; tick lock stayed alive. Post-ENG-131 operators should NOT see this symptom — dispatch.sh exits within `kill_after + ε` of any `gtimeout` fire. **First check:** `cat $PROJECT_STATE_DIR/<slug>/logs/local-$(date -u +%Y-%m-%d).log \| tail -50` for the last `dispatch.sh exit=` line. If no `exit=` line in last 30 min: `pgrep -af claude` enumerates orphan MCP descendants; the holder pid in `$PROJECT_STATE_DIR/.run-local.lock/pid` is alive but `wait`-blocked. **If symptom recurs post-ENG-131:** root cause is a NEW hang class (different from the pipe-fd retention ENG-131 fixed); file a sibling ticket (sibling stuck-tick alarm ticket TBD). |
  ```

- [ ] **6.2** Verify the table still parses as a markdown grid:
  `grep -c '^|' CLAUDE.md` returns a value one greater than before
  the edit (one new row added).

### Task 7: Run the full gate suite

- `depends_on: [3, 5, 6]`
- `touches: <read-only — gate execution only>`

Steps:

- [ ] **7.1** Run `bash .githooks/pre-commit`. MUST exit 0.
- [ ] **7.2** Run `bash bin/dispatch-test.sh` explicitly (covered by
  .7.1 but called out separately because it is the load-bearing
  test for this ticket). MUST exit 0 with new T-A, T-B, and
  AC-DISPATCH-CLEANUP-COMPOSES-RELEASE rows all PASS.
- [ ] **7.3** Spot-check the full bash-syntax pass:
  `bash -n bin/dispatch.sh && bash -n bin/dispatch-test.sh`. Both
  MUST exit 0.
- [ ] **7.4** Commit changes with message
  `fix(eng-131): sequentialise dispatch capture + reap MCP orphans via pgrp cleanup`.
  Stage only the three files in File Structure
  (`bin/dispatch.sh`, `bin/dispatch-test.sh`, `CLAUDE.md`) — do NOT
  use `git add -A` (per CLAUDE.md "Git Safety Protocol"). Pre-commit
  hook fires and runs the gate suite again; if it fails, fix and
  re-stage.

## Frontend Tasks

No frontend tasks. The harness has no UI surface. ENG-131 is an
orchestrator-only change.

## Failure Mode → Test Map

Pulled from brainstorm §7 (Error handling / exit-code propagation)
and §8 (Edge cases).

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
|---|---|---|---|---|
| Clean dispatch | cmd exits 0; renderer extracts a result event | dispatch.sh exits 0; usage-<stage>.json written; capture-file removed by _dispatch_cleanup | unit | existing `_render_and_capture_stream USAGE_A` fixture (line 549) — preserved unchanged |
| gtimeout SIGKILL on MCP orphan-writer scenario | cmd spawns descendant holding fd1, then exits; gtimeout fires SIGTERM→SIGKILL | dispatch.sh exits 124 within `≤ 12 s`; log carries `[cost] no result event found in stream` OR `[cost] partial usage captured` | integration | **T-A (NEW)** — Task 4 |
| MCP descendant tree leaks on gtimeout SIGKILL | cmd spawns 3-level deep `sh -c sleep 9999` tree; gtimeout fires | After dispatch.sh exits, `pgrep -g <captured_pgid>` returns empty within 1.5 s | integration | **T-B (NEW)** — Task 5 |
| Agent invoked `gh pr create` (implementing) | renderer's ENG-43 detective fires | dispatch.sh exits 22; run-stage.sh classifies as pr-opened-too-early | unit | existing AS1-AS6 (no change) |
| Agent invoked banned branch-creation | renderer's ENG-66 detective fires | dispatch.sh exits 23; run-stage.sh classifies as protocol-violation | unit | existing BC1-BC8 (no change) |
| Build agent did `git checkout main` | renderer's ENG-71 detective fires | dispatch.sh exits 26; run-stage.sh classifies as protocol-violation | unit | existing AT-fixtures (no change) |
| Agent posted Linear via MCP/curl | dispatch envelope validator fires | dispatch.sh exits 29 (renderer) or run-stage post-validator exits 29 | unit | existing fixtures (no change) |
| Plan agent missing progress.md entry | _assert_progress_md_entry detective fires | dispatch.sh exits 31 | unit | existing fixtures (no change) |
| Capture-file mktemp failed (ungated caller, no $TMPDIR write) | `mktemp -t` fails | dispatch.sh dies via `set -e` before cmd spawns; rc=1; trap not yet armed at that point → run-stage classifies as unknown-exit-1 → retry-immediately | unit | NOT specifically tested — set -e exit path is bash-language behavior; brainstorm §7 EC-row notes this falls through to existing retry path |
| Capture-file disk-full mid-write | cmd's `> "$_capture_path"` returns non-zero | dispatch_rc captures the write error; renderer may run against partial NDJSON | NOT TESTED (out of scope per brainstorm "Out of scope" — no synthetic disk-full fixture; behavior follows existing pipefail semantics) | — |
| `_cmd_pgid` empty when EXIT trap fires (cmd never spawned) | die() between trap install (Site 2) and cmd spawn (Site 3) | _dispatch_cleanup's `[[ -n "${_cmd_pgid:-}" ]]` guard returns false; pgrp kill skipped; release_claude_mutex still fires | unit | **AC-DISPATCH-CLEANUP-COMPOSES-RELEASE (NEW)** — Task 3.2 (covers the structural invariant; runtime path is exercised by existing AC-TRAP-BEFORE-ACQUIRE die-before-acquire path) |
| perl wrapper missing (/usr/bin/perl removed) | perl absent at runtime | dispatch.sh exits with `command not found` rc=127; run-stage classifies as unknown-exit-127 → halt | integration | NOT TESTED — perl is OS-bundled; absence is a corrupted-OS scenario; precondition probe at Task 1.2 catches at plan time |
| AC-TRAP-BEFORE-ACQUIRE structural invariant | someone re-orders `trap` and `acquire_claude_mutex` | test fails fast at gate time with literal `_TBA_PRIOR` mismatch | unit | existing AC-TRAP-BEFORE-ACQUIRE (UPDATED) — Task 3.1 |
| Composed-trap semantic invariant | someone defines `_dispatch_cleanup` but omits `release_claude_mutex` call | test fails fast at gate time with `body does NOT contain release_claude_mutex` | unit | **AC-DISPATCH-CLEANUP-COMPOSES-RELEASE (NEW)** — Task 3.2 |
| Existing renderer-stdin contract (G-4) | feed NDJSON via stdin heredoc to `_render_and_capture_stream` | renderer's prose-on-STDOUT, raw-capture mirror, post-stream extractor all behave identically to pre-ENG-131 | unit | All 27 existing `_render_and_capture_stream "$USAGE_*"` direct-call sites (no change) — preserved by construction per A-005 |
| PIPELINE_DRY_RUN=1 bypass | dry-run branch skips cmd invocation | `[DRY_RUN] would invoke: gtimeout …` line emitted; no perl wrap, no capture file | unit | existing dry-run fixtures (no change) — bypass branch at lines 568-583 unchanged |

## Test Strategy

**Unit coverage** (sourced + stub pattern; lives in
`bin/dispatch-test.sh`):

- All 27 enumerated `_render_and_capture_stream "$USAGE_*" …`
  direct-call sites preserved unchanged (per A-005, G-4 from the
  brainstorm). Verifies the renderer's positional + stdin contract
  survives the pipe→file refactor.
- AC-TRAP-BEFORE-ACQUIRE structural invariant updated for the
  composed `trap _dispatch_cleanup EXIT` shape (Task 3.1).
- AC-DISPATCH-CLEANUP-COMPOSES-RELEASE new semantic invariant: pins
  `_dispatch_cleanup` upstream of trap-install AND calls
  `release_claude_mutex` (Task 3.2).
- All existing transcript-scan detective fixtures (AS1-AS6 ENG-43,
  BC1-BC10 ENG-66, AT1-AT10 ENG-71, CB7-CB8 ENG-43 e2e, plus
  CHECK_FOR_CORE_BARE ENG-68, EW1-EW2 ENG-109) preserved unchanged.
  The renderer reads from a file post-A but emits the same rc values
  and writes the same violation files.

**Integration coverage** (process-level; lives in
`bin/dispatch-test.sh` as bash-shelled `dispatch.sh` invocations):

- **T-A (no-hang)** — Task 4. Constructs the bug-class scenario
  (orphan writer holding inherited fd1) and asserts dispatch.sh
  exits within ~12 s of `gtimeout`'s SIGKILL with rc=124. **TDD
  failing-first** per brainstorm D-003.
- **T-B (no-orphan)** — Task 5. Constructs the resource-leak
  scenario (3-level descendant tree) and asserts `pgrep -g <pgid>`
  empty within 1.5 s of dispatch.sh exit.

**Smoke coverage** (full gate suite):

- `bash .githooks/pre-commit` (Task 7.1) — runs every
  `bin/*-test.sh` plus secret-probe-lint plus syntax check.
  Verifies the refactor doesn't regress any sibling test.

**Adversarial coverage** (deferred — out of scope per brainstorm
D-004):

- Stuck-tick alarm (sibling ticket TBD) — adversarial test for
  ANY future hang-class slipping past A+B. Out of scope.
- Capture-file disk-full / mktemp-fail synthetic fixtures — out
  of scope; behavior follows existing pipefail / set -e semantics
  per brainstorm §7 EC table.

**Test-gate closure assertions** (per Assumption Inventory A-015,
A-016):

- The ONE token removed (`trap 'release_claude_mutex' EXIT` literal
  string) is captured by Task 3's update to AC-TRAP-BEFORE-ACQUIRE.
  No other sibling test file pins this token; verified by `grep -rn`
  at plan time. The production line in `bin/dispatch.sh` is captured
  by Task 2.2.
- All new tokens (`_dispatch_cleanup`, `/usr/bin/perl`,
  `POSIX::setsid`, `_cmd_pgid`, `_capture_path`, `.cmd-capture-`
  filename pattern) are not pinned absent by any sibling test;
  verified by `grep -rn` at plan time. No closure defects.
