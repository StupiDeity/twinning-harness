---
linear: ENG-81
date: 2026-05-14
topic: Parallel `claude -p` dispatch (K=2 per project) — counting semaphore + scheduler/worker split, repurposing `orchestrator.max_concurrent_features` as the per-project dispatch concurrency cap.
---

# Plan — ENG-81: Parallel `claude -p` dispatch (K=2 per project)

## Anti-anchoring check

- **Problem restatement.** Operator wants two Linear issues to advance through pipeline stages on the same 5-min tick instead of alternating across ticks; the binding constraint is structural serialization in `bin/run-local.sh` + `bin/poll.sh` + `bin/dispatch.sh`, not host CPU/RSS or the Claude subscription.
- **Brainstorm alignment.** The brainstorm at `docs/brainstorms/2026-05-14-eng-81-...-design.md` proposes a counting semaphore + per-issue in-flight lock + scheduler/worker split, repurposing existing `orchestrator.max_concurrent_features` (default 2). This addresses the user-visible problem directly — no reframing.
- **Solution proportionality.** ~700 LOC across 12 files (≈500 LOC tests + docs) for a structural lifecycle inversion. The brainstorm rejects simpler alternatives (run-local back-to-back, drop the mutex, real job queue) with concrete trade-offs (§3.2). The scheduler/worker split is the cheapest correct path for true wall-clock parallelism. Proportional.
- **Escalation:** none required. Proceed with planning.

## 1. Goal

Land K=2 concurrent `claude -p` dispatches per project per tick: scheduler/worker split in `bin/run-local.sh`, counting semaphore replaces the binary mutex in `bin/dispatch.sh`, per-issue `.in-flight.lock` prevents same-issue double-dispatch, `bin/poll.sh --max K` returns up to K decisions per call, `_resolve_K` reads `orchestrator.max_concurrent_features` (existing default 2) with `CLAUDE_MAX_CONCURRENT` env-var override; instrumentation via `gtime -v`-emitted `dispatch-resource-sample` metric backs the pre-flip baseline; `status.sh` surfaces concurrent-slot utilization. Verifiable outcome: with `max_concurrent_features=2`, two distinct ENG-N issues each produce a `local-YYYY-MM-DD-ENG-N.log` file in the same tick and both `usage-<stage>.json` files land under `$PROJECT_STATE_DIR/<ident>/` per dispatch.

## 2. Assumption Inventory

**Branch-base freshness.** Re-checked at plan-finalize time: `git log --oneline HEAD..origin/main` returns TWO commits — `aab49d5` ("Merge pull request #97 from StupiDeity/chore/condense-claude-md") and `ecac2e8` ("chore(docs): condense CLAUDE.md from 52k to 33k chars"). origin/main is now `aab49d55`. The drift is documentation-only (CLAUDE.md condensation 52k → 33k) — no code anchors disturbed, but line-number hints throughout this plan reference the pre-condensation file. **Task 0 (rebase onto origin/main) is mandatory** before any other Backend Task starts; all line-number hints below are informational only — content anchors (function names, distinctive surrounding text, fenced code blocks) are the load-bearing locators per the "Edit-boundary keys" plan rules. The CLAUDE.md sections this plan touches ("Per-issue state directory" tree, "Failure-mode quick reference" table, "What `--action continue` clears" subsection) all SURVIVE the condensation; verified against `git show origin/main:CLAUDE.md`.

| # | Assumption | Status | Evidence |
|---|---|---|---|
| A-001 | `bin/dispatch.sh::acquire_claude_mutex` is a binary mkdir lock at `$HARNESS_STATE_DIR/.claude-mutex.lock` with `CLAUDE_MUTEX_TIMEOUT=600` and the `[claude-mutex] waiting for lock held by <pid>` log line | verified | `bin/dispatch.sh:20-36` (mkdir loop; pid file at line 35) |
| A-002 | `bin/dispatch.sh::release_claude_mutex` is `rm -rf "$CLAUDE_MUTEX_DIR"` and is hooked via `trap 'release_claude_mutex' EXIT` immediately after acquire | verified | `bin/dispatch.sh:38-40, 475-476` |
| A-003 | `bin/run-local.sh` holds `$PROJECT_STATE_DIR/.run-local.lock` for the entire tick lifecycle and removes it via `cleanup_on_exit` EXIT trap | verified | `bin/run-local.sh:37, 51, 59-65` |
| A-004 | `bin/run-local.sh` calls `poll.sh` once and reads exactly one decision JSON object | verified | `bin/run-local.sh:149-153` (`decision="$(bash "$SCRIPT_DIR/poll.sh")"`; `jq -r '.issue_id // ""' <<<"$decision"`) |
| A-005 | `bin/poll.sh::main` returns one decision and `exit 0`s on the first hit via three case arms (held / wait_recallable / inbox) | verified | `bin/poll.sh:679-718` (the `while (( i < n ))` loop with three `exit 0` arms at lines 698, 708, 716) |
| A-006 | `_picker_build_pool` returns a sorted JSON array; sort key `[-stage_index, -priority_sort_rank, fifo_ts, .identifier]` | verified | `bin/poll.sh:459-527` (sort key at line 526) |
| A-007 | `bin/poll.sh::main` reads `orchestrator.max_concurrent_features` defensively, defaulting to 2 | verified | `bin/poll.sh:626-630` |
| A-008 | `orchestrator.max_concurrent_features` defaults to 2 in `bin/setup.sh::phase_config_defaults` | verified | `bin/setup.sh:530-531` |
| A-009 | `bin/run-local-helpers.sh::route_run_stage_exit` routes rc=24 to global counter, every other rc to per-issue (`$(issue_dir)/.consecutive-failures`) — ENG-69 lane split | verified | `bin/run-local-helpers.sh:388-430` (case `$rc` arms; per-issue `pic_file` at line 393) |
| A-010 | `bin/run-local-helpers.sh::halt_issue_for_self_leak` halts a single issue without tripping the global breaker | verified | `bin/run-local-helpers.sh:128-154` (calls `classify_failure` with `skip-until-human-acts`; never `trip_breaker`) |
| A-011 | `bin/common.sh::issue_dir <issue>` returns `$PROJECT_STATE_DIR/<issue>` | verified | `bin/common.sh:68-72` |
| A-012 | `bin/common.sh::acquire_lock <dir> [timeout]` is mkdir-based; `release_lock <dir>` is rmdir | verified | `bin/common.sh:395-408` (both exported via `export -f` at line 410) |
| A-013 | `bin/common.sh::allocate_dispatch_id` is per-issue-locked at `$(issue_dir)/.allocate.lock` (mkdir-based) and writes `current_dispatch_seq` / `current_dispatch_id` into `issue-state.json` | verified | `bin/common.sh:104-147` |
| A-014 | `bin/dispatch.sh::main` exports `PIPELINE_WRITER=agent`, `PIPELINE_DISPATCH_ID`, `PIPELINE_STAGE` into the agent subshell via the `env` block | verified | `bin/dispatch.sh:555-557` |
| A-015 | `bin/run-local.sh` mints `GITHUB_TOKEN` once per tick at `:101-103` and exports it; subprocesses inherit naturally | verified | `bin/run-local.sh:101-103` |
| A-016 | `bin/metrics.sh::main` writes a single `jq -cn ... >> file` line; line size 250-500 bytes (8 base fields + 0–6 cost flags) | verified | `bin/metrics.sh:53-74`. POSIX `O_APPEND` atomic-up-to-`PIPE_BUF` (4 KB on macOS); brainstorm §7.7 verifies size envelope. |
| A-017 | `bin/run-local.sh` runs cleanup-worktrees every 10 ticks at the END of the tick (post-dispatch); current call site at lines 444-447 | verified | `bin/run-local.sh:42, 444-447` |
| A-018 | `bin/run-local.sh:251` does the tick-start dirty-path snapshot vs `$dispatch_cwd` (per-issue worktree, NOT `$TARGET_REPO`) — ENG-67 invariant | verified | `bin/run-local.sh:244-256` (`die` at line 244 enforces the invariant) |
| A-019 | `bin/run-stage.sh::main` is the unit run by each worker, takes `<issue> <stage>`, allocates `dispatch_id` at `:1073` | verified | `bin/run-stage.sh:975-977, 1063-1075` |
| A-020 | `bin/run-local-helpers.sh::clean_scratch_dir <worktree>` is stage-agnostic and idempotent (no-op on missing dir) | verified | `bin/run-local-helpers.sh:310-322` |
| A-021 | `bin/run-local-helpers.sh::clean_self_leak_residue` and `stage_is_read_mostly` exist and are called from `bin/run-local.sh:357-364` | verified | `bin/run-local-helpers.sh:176-180, 215-272`; `bin/run-local.sh:357-364` |
| A-022 | The `& ... & wait` parallel-fork pattern is already in the codebase (`capture_core_bare_forensic`) — no new primitive | verified | `bin/run-local-helpers.sh:769-817` |
| A-023 | **`bin/setup.sh::phase_project_profile` ALSO mkdir's `$HARNESS_STATE_DIR/.claude-mutex.lock` directly (NOT via `acquire_claude_mutex`)** — the brainstorm missed this | verified | `bin/setup.sh:317-324, 346` (inline `mkdir`/`rm -rf`; matches the same dir as `dispatch.sh:20`) |
| A-024 | **`bin/mutex-test.sh:26,29` mkdir/rmdir the literal path `.claude-mutex.lock` to set up its 3-second contention scenario, and at `:36` greps for the literal text `claude-mutex.*waiting`** | verified | `bin/mutex-test.sh:26-38` (test-gate-closure: any rename of the dir or log message text breaks this test) |
| A-025 | `gtime` is NOT shipped by Homebrew `coreutils` — it lives in the separate `gnu-time` package; **`gtime` is absent on this dev host** (`/opt/homebrew/opt/gnu-time/bin/gtime` does not exist). The brainstorm's claim that "gtime is a transitive dep through gtimeout" is incorrect. | corrected | `which gtime` returns "not found" while `/opt/homebrew/bin/gtimeout` exists; `coreutils` ships `gtimeout`, `gnu-time` ships `gtime`. Soft-fail on absence (degraded metric) is mandatory. |
| A-026 | `CLAUDE.md` documents the global Claude mutex at `$HARNESS_STATE_DIR/.claude-mutex.lock/` in the "Per-issue state directory" section | verified | `CLAUDE.md:253` |
| A-027 | `bin/poll.sh::main`'s `held` slot accounting (`$held` JSON at line 647-650 sliced by `--argjson n "$max_concurrent"`) and the post-pool `(( held_count >= max_concurrent ))` idle gate at lines 721-723 are unchanged by this plan | verified | `bin/poll.sh:644-650, 721-723`. New `--max K` is an additive CLI arg; existing `max_concurrent_features` semantics in poll.sh stay identical (slot accounting + WIP cap). |
| A-028 | `bin/run-local.sh:259` invokes `run-stage.sh` inside a `set +e` / `set -e` block to capture rc; the post-call rc-gate `[[ $rc -ne 0 ]] && exit $rc` is at line 280 | verified | `bin/run-local.sh:258-280` |
| A-029 | `bin/run-stage.sh::main` exports `PIPELINE_ISSUE_ID` (used by `dispatch.sh::main` at line 467 to resolve the per-stage usage-file path); each worker's subshell inherits and re-exports per-issue env naturally | verified | `bin/run-stage.sh:1073` (`allocate_dispatch_id` exports PIPELINE_DISPATCH_ID) and `bin/dispatch.sh:467-473` (PIPELINE_ISSUE_ID gating) |
| A-030 | `failure_outcome_for_exit` (`bin/common.sh`) maps existing exit codes; this plan does NOT introduce any new exit code (semaphore timeout reuses the same `die` path as the existing mutex timeout) | verified | `bin/common.sh:212-...`; no new exit code in scope. |
| A-031 | `bin/dispatch.sh::main` invokes `claude -p` wrapped in `gtimeout --signal=TERM --kill-after=10 "$timeout_seconds"` at lines 558-565 (the `cmd` array) | verified | `bin/dispatch.sh:555-565` |
| A-032 | `bin/run-stage.sh::_validate_dispatch_envelope` runs after dispatch returns; the EXIT trap at `:1142` writes the dispatch-history end-row | verified | `bin/run-stage.sh:1119-1142` |
| A-033 | The exact log message text `[claude-mutex] waiting for lock held by <pid>` is asserted by `mutex-test.sh:36`'s grep — **must be preserved verbatim** for the existing test to keep passing (or the test must be updated in lockstep) | verified | `bin/dispatch.sh:29` + `bin/mutex-test.sh:36` |

**Items left "assumed/new":**

- **`gtime` (`gnu-time` package) on the harness host PATH.** Phase 1 must include a `require_bin gtime` guard or graceful degraded mode (no metric emit, log warning) so an absent `gtime` does not break dispatch on hosts that haven't installed `gnu-time` (per A-025). Documented in Task 1.

## 3. File Structure

| Path | New / Modified | Purpose |
|---|---|---|
| `bin/dispatch.sh` | modified | A-001/A-002/A-014/A-031: extend `acquire_claude_mutex` / `release_claude_mutex` to counting semaphore (`slot-<N>` mkdirs); preserve `[claude-mutex]` log text (A-033); add `gtime -v` wrapper around `claude -p` and emit `dispatch-resource-sample` metric (Phase 1) |
| `bin/run-local.sh` | modified | A-003/A-004/A-015/A-017/A-018/A-028: refactor `main` body into scheduler arm (poll + reconcile + ensure-worktree + cleanup-worktrees) and worker subshell (snapshot + run-stage + sweep + commit/push); release tick lock BEFORE fork; per-worker log file; `_resolve_K` helper |
| `bin/poll.sh` | modified | A-005/A-006/A-007: add `--max <K>` CLI flag; emit JSON ARRAY of up to K decisions when K>1; preserve single-object emission when K==1 (the default; A-004 caller backward-compat) |
| `bin/setup.sh` | modified | A-023: replace inline `mkdir "$HARNESS_STATE_DIR/.claude-mutex.lock"` in `phase_project_profile` with a call to `acquire_claude_mutex` / `release_claude_mutex` so setup-time discovery uses the same counting semaphore as dispatch (single source of truth) |
| `bin/common.sh` | modified | New `_resolve_K` exported helper (A-007/A-008/A-024 precedence: env > config > default 2; integer ≥1 validation) |
| `bin/mutex-test.sh` | modified | A-024: parameterize on N=1 (legacy contention) AND add new cases for N=2 (two acquirers each get a slot; three contend → third waits) |
| `bin/poll-slot-test.sh` | modified | New AC-MAX-K-* fixtures: `--max 2` returns 2-element array when 2 helds exist; `--max 2` returns held + 1 inbox when held_count=1 + inbox≥1; `--max 1` returns single object (legacy preservation); `--max 0` falls through to `idle` |
| `bin/run-local-sweep-test.sh` | modified | New end-to-end fixture: K=2, two distinct ENG-N issues, both per-worker log files at expected paths, both per-issue counters update independently, no interleaved tick-log writes from worker arms |
| `bin/run-local-helpers-adversarial-test.sh` | modified | Three new adversarial fixtures: (a) two workers race for same per-issue `.in-flight.lock` → second skipped; (b) two workers writing concurrently to `events.jsonl` → file parses cleanly under `jq -c .`; (c) self-leak halt on worker A does NOT freeze worker B |
| `bin/dispatch-test.sh` | modified | New `Group 5` fixture (`Group 4` already taken by ENG-48): stub `gtime` in `STUB_DIR`, assert `dispatch-resource-sample` metric event lands in `events.jsonl` with non-empty `wall_seconds`/`max_rss_kb`/`cpu_pct` notes; assert `[claude-mutex]` log text preserved (A-033 regression coverage) |
| `bin/common-test.sh` | modified | New fixtures for `_resolve_K`: env > config > default precedence; non-integer / `<1` falls through with warning |
| `bin/status.sh` | modified | New row: "concurrent dispatches active" (count of `$HARNESS_STATE_DIR/.claude-semaphore/slot-*/pid` files) + "median dispatch RSS / CPU% (last 24h)" computed from `events.jsonl` `dispatch-resource-sample` events |
| `CLAUDE.md` | modified | A-026: update "Per-issue state directory" tree to show `.claude-semaphore/` instead of `.claude-mutex.lock/`; loud upgrade note on `max_concurrent_features` semantic change at Phase 4; add "Concurrent dispatches not running" failure-mode entry for Phase 5 |
| `docs/runbooks/operator-mental-model.md` | modified | Update "earlier-stage issue starves" entry: starvation now applies only when held_count ≥ K; add new entry "Concurrent slots invisible in Linear" with `ls $HARNESS_STATE_DIR/.claude-semaphore/slot-*/pid` inspection command; replace 3 `.claude-mutex.lock` references at lines 304/309/316 |
| `README.md` | modified | Doc-rot fix: replace `.claude-mutex.lock` references (currently line ~365) with `.claude-semaphore/slot-<N>` |
| `docs/architecture.md` | modified | Doc-rot fix: replace 4 `.claude-mutex.lock` references (currently lines 17, 290, 302, 340) with `.claude-semaphore/slot-<N>` |
| `docs/operations.md` | modified | Doc-rot fix: replace 1 `.claude-mutex.lock` reference (currently line ~216) with `.claude-semaphore/slot-<N>` |
| `docs/install.md` | modified | Doc-rot fix: replace 2 `.claude-mutex.lock` references (currently lines 258, 272) with `.claude-semaphore/slot-<N>` |
| `docs/assumptions.md` | modified | Doc-rot fix: replace 1 `.claude-mutex.lock` reference (currently line ~123) with `.claude-semaphore/slot-<N>` |

No new files. All changes are additive to existing files; no symbol or path is removed except the binary `.claude-mutex.lock` literal (replaced by `.claude-semaphore/slot-<N>` paths). The brainstorm's count of ~700 LOC across 12 files holds.

## 4. API Contract

No new API surface. The harness is a Bash orchestration layer; there is no FE↔BE contract in scope. The only operator-visible contract changes are:

- **CLI:** `bin/poll.sh` gains an optional `--max <K>` flag (default 1; backward-compatible).
- **Env var:** `CLAUDE_MAX_CONCURRENT` (new, optional; integer ≥1; default = config value).
- **Config:** `orchestrator.max_concurrent_features` semantics widen from "WIP cap on inbox-pickup pool" to "max concurrent dispatches per project per tick AND WIP cap" (rename-in-place per brainstorm §1).
- **Metric:** new `dispatch-resource-sample` event row in `events.jsonl` (no schema change — `metrics.sh` event names are an open vocabulary).

## 5. Backend Tasks

### Task 0: Rebase onto origin/main

- `depends_on: []`
- `touches: (no file edits — git operation only)`

- [ ] Run `git fetch origin main && git rebase origin/main` from the feature branch. The two upstream commits (`aab49d5`, `ecac2e8`) condense CLAUDE.md and do not modify any source file this plan touches; the rebase should apply cleanly with no conflicts. If a conflict surfaces, STOP and post a Linear comment requesting `pipeline:supersede` (the brainstorm should re-run against the new base, not be patched).
- [ ] After rebase, re-verify Assumption Inventory items A-026 (CLAUDE.md `.claude-mutex.lock/` line — was 253, now 225 in origin/main) and A-033 (the `[claude-mutex]` log text in `bin/dispatch.sh:29` — survives untouched). All content anchors still hit; only line-number hints in subsequent tasks shift. Implement agent must rely on the content anchors, not the bare line numbers.

### Task 1: Add `gtime -v` wrapper + `dispatch-resource-sample` metric (Phase 1, instrumentation only — no behavior change)

- `depends_on: [0]`
- `touches: bin/dispatch.sh::main, bin/dispatch-test.sh`

- [ ] In `bin/dispatch.sh::main`, AFTER the `acquire_claude_mutex` call (line 475) AND BEFORE the `cmd=(env ...)` array construction (~line 555), add `gtime` discovery:
  ```bash
  local _gtime_bin=""
  if command -v gtime >/dev/null 2>&1; then
    _gtime_bin="$(command -v gtime)"
  else
    log "[dispatch-resource-sample] gtime not on PATH; resource sample will be skipped (install: brew install gnu-time)"
  fi
  local _gtime_out=""
  if [[ -n "$_gtime_bin" ]]; then
    _gtime_out="$(mktemp -t pipeline-gtime-XXXXXX)"
  fi
  ```
  Anchor: insert AFTER the closing `local timeout_seconds=$(( timeout_minutes * 60 ))` line (currently line 514) AND BEFORE the `if [[ "$PIPELINE_DRY_RUN" == "1" ]]; then` block (currently line 516).
- [ ] In the `cmd=(env ...)` array (currently lines 555-565), conditionally prepend `gtime -v -o "$_gtime_out"` BEFORE `gtimeout --signal=TERM --kill-after=10 "$timeout_seconds"`:
  ```bash
  local cmd=()
  cmd+=(env PIPELINE_WRITER=agent
    "PIPELINE_DISPATCH_ID=${PIPELINE_DISPATCH_ID-}"
    "PIPELINE_STAGE=$stage")
  if [[ -n "$_gtime_bin" ]]; then
    cmd+=("$_gtime_bin" -v -o "$_gtime_out")
  fi
  cmd+=(gtimeout --signal=TERM --kill-after=10 "$timeout_seconds"
    claude -p ...)
  ```
  Anchor: REPLACE the existing `local cmd=(env PIPELINE_WRITER=agent ... gtimeout ... claude -p ...)` array literal (currently spans lines 555-565). The replacement preserves every existing argument; it only inserts the optional `gtime` prefix between the `env` block and `gtimeout`.
- [ ] AFTER the `if [[ -n "$log_file" ]]; ... else ...; fi` claude-invocation block (currently ends line 589), AND BEFORE the closing `}` of `main` (line 590), add post-dispatch parse + metric emit:
  ```bash
  if [[ -n "$_gtime_out" && -s "$_gtime_out" && -n "${PIPELINE_ISSUE_ID:-}" ]]; then
    local _wall_s _rss_kb _cpu_pct
    _wall_s="$(awk -F': ' '/Elapsed \(wall clock\) time/ {print $2}' "$_gtime_out" | head -1)"
    _rss_kb="$(awk -F': ' '/Maximum resident set size/ {print $2}' "$_gtime_out" | head -1)"
    _cpu_pct="$(awk -F': ' '/Percent of CPU this job got/ {print $2}' "$_gtime_out" | tr -d '%' | head -1)"
    bash "$SCRIPT_DIR/metrics.sh" dispatch-resource-sample \
      "$PIPELINE_ISSUE_ID" "$stage" measured 0 \
      "wall=${_wall_s:-?} rss_kb=${_rss_kb:-?} cpu_pct=${_cpu_pct:-?}" \
      || log "[dispatch-resource-sample] metric emit failed (non-blocking)"
    rm -f "$_gtime_out"
  fi
  ```
  Anchor: insert AFTER the closing `fi` of the inner `if [[ -n "$usage_file" && -n "$issue_state_dir" ]]` block (currently line 588 inside the `else` branch, line 580 in the named-log-file branch — there are TWO closing `fi`s; insert AFTER the OUTER `fi` that closes the `if [[ -n "$log_file" ]]` block at line 589) AND BEFORE the closing `}` of `main` at line 590.
- [ ] In `bin/dispatch-test.sh`, add a new fixture. **`Group 4` is already taken by ENG-48's "isolation flags reach claude -p invocation" case (around line 187); name this `Group 5`.** Anchor: insert AFTER the LAST printf header of an existing group (currently Group 4 at line ~187) AND BEFORE the trailing `printf 'PASS=$PASS FAIL=$FAIL\n'` summary at the file's tail.
  ```bash
  printf '\n--- Group 5: dispatch-resource-sample emission with stubbed gtime ---\n'
  STUB_GTIME="$_TEST_STUB_DIR/gtime"
  cat > "$STUB_GTIME" <<'SH'
  #!/usr/bin/env bash
  # Find the -o output path argument and emit a fixture gtime -v output.
  for ((i=1; i<=$#; i++)); do
    if [[ "${!i}" == "-o" ]]; then
      j=$((i+1))
      cat > "${!j}" <<'GTIME'
  	Elapsed (wall clock) time (h:mm:ss or m:ss): 0:42.10
  	Maximum resident set size (kbytes): 384256
  	Percent of CPU this job got: 28%
  GTIME
      break
    fi
  done
  # ... pass through args after the gtime-specific ones to invoke the wrapped command.
  SH
  chmod +x "$STUB_GTIME"
  PATH="$_TEST_STUB_DIR:$PATH" PIPELINE_ISSUE_ID=ENG-T-COST \
    bash "$SCRIPT_DIR/dispatch.sh" brainstorming "$PROMPT_FILE" 2>&1 \
    | grep -q '\[dispatch-resource-sample\]' \
    && pass_at "dispatch-resource-sample emitted with stubbed gtime" \
    || fail_at "dispatch-resource-sample" "expected stub gtime path to fire metric"
  ```
  Anchor: insert AFTER the closing `done` of the existing Group 3 fixture loop, BEFORE the trailing `printf 'PASS=...\n'` summary (the file's tail).

### Task 2: Convert binary mutex → counting semaphore at capacity 1 (Phase 2 — no behavior change at default)

- `depends_on: [1]`
- `touches: bin/dispatch.sh::acquire_claude_mutex, bin/dispatch.sh::release_claude_mutex, bin/setup.sh::phase_project_profile, bin/mutex-test.sh, CLAUDE.md`

- [ ] In `bin/dispatch.sh`, REPLACE the existing `CLAUDE_MUTEX_DIR` / `acquire_claude_mutex` / `release_claude_mutex` block (lines 20-40):
  - **Anchor:** the entire region between `# Note CLAUDE_MUTEX_DIR …` (currently absent — use the literal `CLAUDE_MUTEX_DIR="$HARNESS_STATE_DIR/.claude-mutex.lock"` line as the start anchor at line 20) AND the closing `}` of `release_claude_mutex` (line 40).
  - Replace with:
    ```bash
    CLAUDE_SEMAPHORE_DIR="$HARNESS_STATE_DIR/.claude-semaphore"
    CLAUDE_MUTEX_TIMEOUT="${CLAUDE_MUTEX_TIMEOUT:-600}"
    CLAUDE_MAX_CONCURRENT_DEFAULT_PHASE2=1   # Phase 2 ships at capacity 1 (default); Phase 4 widens via _resolve_K.
    _ACQUIRED_SLOT_DIR=""

    acquire_claude_mutex() {
      mkdir -p "$CLAUDE_SEMAPHORE_DIR"
      local cap="${CLAUDE_MAX_CONCURRENT:-$CLAUDE_MAX_CONCURRENT_DEFAULT_PHASE2}"
      [[ "$cap" =~ ^[0-9]+$ ]] || cap="$CLAUDE_MAX_CONCURRENT_DEFAULT_PHASE2"
      (( cap < 1 )) && cap="$CLAUDE_MAX_CONCURRENT_DEFAULT_PHASE2"
      local waited=0 slot
      while :; do
        for (( slot=1; slot <= cap; slot++ )); do
          local d="$CLAUDE_SEMAPHORE_DIR/slot-$slot"
          if mkdir "$d" 2>/dev/null; then
            printf '%s\n' "$$" > "$d/pid"
            _ACQUIRED_SLOT_DIR="$d"
            return 0
          fi
        done
        if (( waited == 0 )); then
          # Preserve the exact log text that mutex-test.sh:36 greps for.
          local holder=""
          [[ -f "$CLAUDE_SEMAPHORE_DIR/slot-1/pid" ]] \
            && holder="$(cat "$CLAUDE_SEMAPHORE_DIR/slot-1/pid" 2>/dev/null || true)"
          log "[claude-mutex] waiting for lock held by ${holder:-<unknown>}"
        fi
        (( waited >= CLAUDE_MUTEX_TIMEOUT )) \
          && die "[claude-mutex] timeout after ${CLAUDE_MUTEX_TIMEOUT}s (cap=$cap, all slots held)"
        sleep 1
        waited=$((waited + 1))
      done
    }

    release_claude_mutex() {
      [[ -n "$_ACQUIRED_SLOT_DIR" ]] || return 0
      rm -rf "$_ACQUIRED_SLOT_DIR"
      _ACQUIRED_SLOT_DIR=""
    }
    ```
  - The `[claude-mutex]` log text MUST be preserved verbatim (A-033) so `mutex-test.sh:36`'s grep keeps passing.
- [ ] In `bin/setup.sh::phase_project_profile`, REPLACE the inline mutex block at lines 314-324 (start anchor: the comment `# Hold the claude-mutex tightly around the claude call only;`, end anchor: the line `printf '%s\n' "$$" > "$mutex/pid"`) with a `source` of `dispatch.sh`'s helpers + a single `acquire_claude_mutex` call:
  ```bash
  # ENG-81: route through the shared counting semaphore so setup-time
  # discovery contends for a slot just like dispatch does. Phase 2 cap=1
  # preserves today's strict serialization between setup-discovery and
  # dispatched stage runs.
  # shellcheck source=dispatch.sh
  # `source` reuses acquire_claude_mutex / release_claude_mutex without
  # firing dispatch.sh::main (sentinel guard at the file tail).
  source "$SCRIPT_DIR/dispatch.sh"
  log "project-profile: waiting for claude-semaphore"
  acquire_claude_mutex
  ```
  And REPLACE the matching release at line 346 (`rm -rf "$mutex"`) with `release_claude_mutex`. The local `mutex=` variable becomes unused and should be deleted along with the inline mkdir.
- [ ] In `bin/mutex-test.sh`, REPLACE the literal `mkdir "$HARNESS_STATE_DIR/.claude-mutex.lock"` (line 26) and the matching `rmdir` (line 29) with the new semaphore-slot path:
  - Anchor: the comment `# Slow-down dispatch.sh so the second invocation actually contends.` at line 23 begins the block; end anchor is the `) &` background-process closer at line 30.
  - New block:
    ```bash
    mkdir -p "$HARNESS_STATE_DIR/.claude-semaphore"
    mkdir "$HARNESS_STATE_DIR/.claude-semaphore/slot-1"
    (
      sleep 3
      rmdir "$HARNESS_STATE_DIR/.claude-semaphore/slot-1"
    ) &
    ```
- [ ] In `bin/mutex-test.sh`, add new test cases AFTER the existing "OK (waited ${elapsed}s)" line (the file currently exits after one assertion — extend to a multi-case form):
  ```bash
  # AC-N2-FREE-SLOT-2: with cap=2 and slot-1 held, second acquirer takes slot-2 immediately.
  rm -rf "$HARNESS_STATE_DIR/.claude-semaphore"
  mkdir -p "$HARNESS_STATE_DIR/.claude-semaphore"
  mkdir "$HARNESS_STATE_DIR/.claude-semaphore/slot-1"
  start="$(date +%s)"
  CLAUDE_MAX_CONCURRENT=2 bash "$HARNESS_DIR/dispatch.sh" brainstorm "$PROMPT" >/dev/null 2>&1
  elapsed=$(( $(date +%s) - start ))
  (( elapsed < 2 )) || { echo "FAIL AC-N2: cap=2 with slot-1 held should not wait (elapsed=$elapsed)"; exit 1; }
  rmdir "$HARNESS_STATE_DIR/.claude-semaphore/slot-1" 2>/dev/null || true

  # AC-N2-CONTEND: with cap=2 and BOTH slots held, third acquirer waits.
  rm -rf "$HARNESS_STATE_DIR/.claude-semaphore"
  mkdir -p "$HARNESS_STATE_DIR/.claude-semaphore"
  mkdir "$HARNESS_STATE_DIR/.claude-semaphore/slot-1"
  mkdir "$HARNESS_STATE_DIR/.claude-semaphore/slot-2"
  ( sleep 3; rmdir "$HARNESS_STATE_DIR/.claude-semaphore/slot-1" ) &
  start="$(date +%s)"
  CLAUDE_MAX_CONCURRENT=2 bash "$HARNESS_DIR/dispatch.sh" brainstorm "$PROMPT" >/dev/null 2>&1
  elapsed=$(( $(date +%s) - start ))
  (( elapsed >= 3 )) || { echo "FAIL AC-N2-CONTEND: should have waited (elapsed=$elapsed)"; exit 1; }

  echo "OK (Phase-2 capacity=1 + Phase-2-with-CLAUDE_MAX_CONCURRENT=2 contention covered)"
  ```
- [ ] In `CLAUDE.md`, update line 253 (anchor: the literal `├── .claude-mutex.lock/` inside the "Per-issue state directory" tree) to:
  ```
  ├── .claude-semaphore/        # global counting semaphore (slot-<N>/pid each); replaces .claude-mutex.lock
  ```

### Task 3: Add `bin/poll.sh --max <K>` CLI flag (Phase 3a — additive; default 1 preserves legacy callers)

- `depends_on: [2]`
- `touches: bin/poll.sh::main, bin/poll-slot-test.sh`

- [ ] In `bin/poll.sh::main` (currently `main()` at line 619), add CLI parsing AFTER `require_env LINEAR_API_KEY` (line 620) AND BEFORE the `paused="$(is_orchestrator_paused)"` line (line 623):
  ```bash
  local _max_decisions=1
  while (( $# > 0 )); do
    case "$1" in
      --max) _max_decisions="${2:-1}"; shift 2 ;;
      *)     shift ;;
    esac
  done
  [[ "$_max_decisions" =~ ^[0-9]+$ ]] || _max_decisions=1
  (( _max_decisions < 1 )) && _max_decisions=1
  ```
- [ ] In the `while (( i < n )); do ... done` loop (lines 673-718), REPLACE the THREE `exit 0` statements (currently at lines 698, 708, 716) with `continue` arms gated on a per-decision counter, AND collect emitted decisions into a `_emitted` JSON array variable:
  - Anchor: each of the three `jq -nc \ ... \ '{issue_id:..., stage:..., entry_action:..., reason:...}'` blocks immediately followed by `exit 0 ;;`.
  - For EACH of the three case arms, replace `exit 0 ;;` with:
    ```bash
    _emitted="$(jq -nc --argjson p "$_emitted" --argjson x "$_d" '$p + [$x]')"
    _decisions_count=$((_decisions_count + 1))
    if (( _decisions_count >= _max_decisions )); then break; fi
    i=$((i+1)); continue ;;
    ```
    — and assign each `jq -nc \ ... '{...}'` block's output to `_d` first (capture the per-decision JSON) before appending. Initialise `local _emitted='[]' _decisions_count=0` at the top of the function (next to the `pool=...` line, ~line 670).
- [ ] AFTER the `while (( i < n ))` loop (i.e. AFTER line 718's `done`) AND BEFORE the `if (( held_count >= max_concurrent ))` idle gate (line 721), emit:
  ```bash
  if (( _decisions_count > 0 )); then
    if (( _max_decisions == 1 )); then
      jq -c '.[0]' <<<"$_emitted"   # legacy single-object output
    else
      printf '%s\n' "$_emitted"     # new array output
    fi
    exit 0
  fi
  ```
- [ ] In `bin/poll-slot-test.sh`, add new fixtures AFTER the last existing AC-* assertion (anchor: search for the last `pass_at` invocation in the file, append before the trailing `printf 'PASS=...\n'` summary):
  ```bash
  # AC-MAX-K-LEGACY-1: --max 1 emits single object (back-compat with run-local.sh:149).
  reset_fixtures
  write_label_fixture stage:reviewing 'ENG-A1|In Progress|3|stage:reviewing'
  out="$(main --max 1)"
  jq -e 'type == "object"' <<<"$out" >/dev/null \
    && pass_at "AC-MAX-K-LEGACY-1: --max 1 emits object" \
    || fail_at "AC-MAX-K-LEGACY-1" "expected object, got: $out"

  # AC-MAX-K-2-HELDS: --max 2 with two ready helds emits 2-element array.
  reset_fixtures
  write_label_fixture stage:reviewing 'ENG-A1|In Progress|3|stage:reviewing'
  write_label_fixture stage:implementing 'ENG-A2|In Progress|3|stage:implementing'
  out="$(main --max 2)"
  count="$(jq 'length' <<<"$out")"
  (( count == 2 )) \
    && pass_at "AC-MAX-K-2-HELDS: 2 helds returns 2-element array" \
    || fail_at "AC-MAX-K-2-HELDS" "expected length 2, got $count"

  # AC-MAX-K-DEFAULT: omitted --max defaults to 1.
  reset_fixtures
  write_label_fixture stage:reviewing 'ENG-A1|In Progress|3|stage:reviewing'
  out="$(main)"
  jq -e 'type == "object"' <<<"$out" >/dev/null \
    && pass_at "AC-MAX-K-DEFAULT: no --max defaults to single object" \
    || fail_at "AC-MAX-K-DEFAULT" "expected object, got: $out"
  ```

### Task 4: Add per-issue `.in-flight.lock` primitive + `_resolve_K` (Phase 3b foundations — no fork yet)

- `depends_on: [2]`
- `touches: bin/common.sh::_resolve_K, bin/run-local-helpers-adversarial-test.sh`

- [ ] In `bin/common.sh`, AFTER the `release_lock` function (anchor: the `export -f acquire_lock release_lock` line at line 410) AND BEFORE the `PIPELINE_DRY_RUN=` block (line 412), add:
  ```bash
  # _resolve_K — per-tick concurrency cap (ENG-81).
  # Precedence: env CLAUDE_MAX_CONCURRENT > config orchestrator.max_concurrent_features > default 2.
  # Non-integer / <1 falls through to next layer with a log warning (mirrors ENG-65 timeout pattern).
  _resolve_K() {
    local k=""
    if [[ -n "${CLAUDE_MAX_CONCURRENT-}" ]]; then
      if [[ "$CLAUDE_MAX_CONCURRENT" =~ ^[0-9]+$ ]] && (( CLAUDE_MAX_CONCURRENT >= 1 )); then
        printf '%s\n' "$CLAUDE_MAX_CONCURRENT"
        return 0
      else
        log "_resolve_K: invalid CLAUDE_MAX_CONCURRENT=$CLAUDE_MAX_CONCURRENT (ignoring; falling through)"
      fi
    fi
    if [[ -f "${CONFIG:-}" ]]; then
      k="$(jq -r '.orchestrator.max_concurrent_features // empty' "$CONFIG" 2>/dev/null || printf '')"
      if [[ "$k" =~ ^[0-9]+$ ]] && (( k >= 1 )); then
        printf '%s\n' "$k"
        return 0
      elif [[ -n "$k" ]]; then
        log "_resolve_K: invalid orchestrator.max_concurrent_features=$k (ignoring; falling through)"
      fi
    fi
    printf '%s\n' "2"
  }
  export -f _resolve_K
  ```
- [ ] In `bin/run-local-helpers-adversarial-test.sh`, add a new fixture (anchor: append after the last existing `pass_at` invocation, before the trailing summary):
  ```bash
  # AC-INFLIGHT-LOCK: two concurrent acquires of the SAME issue's .in-flight.lock — second returns 1.
  EH_DIR="$(mktemp -d)"
  mkdir -p "$EH_DIR/issue-state-test/ENG-99"
  PROJECT_STATE_DIR="$EH_DIR/issue-state-test" \
    bash -c 'source "$HARNESS_DIR/common.sh"; acquire_lock "$(issue_dir ENG-99)/.in-flight.lock" 0 || echo SECOND_FAILED' \
    > "$EH_DIR/out1" 2>&1
  # First acquire (no contention): succeeds with empty stdout.
  [[ -z "$(cat "$EH_DIR/out1")" ]] && pass_at "AC-INFLIGHT-LOCK first-acquire" \
    || fail_at "AC-INFLIGHT-LOCK" "first acquire produced output: $(cat "$EH_DIR/out1")"
  # Now hold + try second acquire — must observe contention.
  mkdir "$EH_DIR/issue-state-test/ENG-99/.in-flight.lock"
  PROJECT_STATE_DIR="$EH_DIR/issue-state-test" \
    bash -c 'source "$HARNESS_DIR/common.sh"; acquire_lock "$(issue_dir ENG-99)/.in-flight.lock" 0 || echo SECOND_FAILED' \
    > "$EH_DIR/out2" 2>&1
  grep -q SECOND_FAILED "$EH_DIR/out2" \
    && pass_at "AC-INFLIGHT-LOCK second-acquire-blocked" \
    || fail_at "AC-INFLIGHT-LOCK" "second acquire should have failed: $(cat "$EH_DIR/out2")"
  rm -rf "$EH_DIR"
  ```

### Task 4b: Add `_resolve_K` test fixtures in `bin/common-test.sh`

- `depends_on: [4]`
- `touches: bin/common-test.sh`

- [ ] In `bin/common-test.sh` (the file exists in the harness target's test list per the project profile's "Build & test gates"), add a new test region (anchor: append after the last existing `pass_at` invocation, before the trailing `printf 'PASS=...\n'` summary):
  ```bash
  printf '\n--- _resolve_K precedence ---\n'

  # AC-RK-DEFAULT: no env, no config → 2.
  unset CLAUDE_MAX_CONCURRENT
  CONFIG=/tmp/nonexistent-$$ ; got="$(_resolve_K)"
  [[ "$got" == "2" ]] && pass_at "AC-RK-DEFAULT" || fail_at "AC-RK-DEFAULT" "got=$got"

  # AC-RK-ENV-WINS: env=3 with config=2 → 3.
  CFG="$(mktemp)"; jq -n '{orchestrator:{max_concurrent_features:2}}' > "$CFG"
  CLAUDE_MAX_CONCURRENT=3 CONFIG="$CFG" got="$(_resolve_K)"
  [[ "$got" == "3" ]] && pass_at "AC-RK-ENV-WINS" || fail_at "AC-RK-ENV-WINS" "got=$got"

  # AC-RK-CONFIG: no env, config=4 → 4.
  unset CLAUDE_MAX_CONCURRENT
  CFG="$(mktemp)"; jq -n '{orchestrator:{max_concurrent_features:4}}' > "$CFG"
  CONFIG="$CFG" got="$(_resolve_K)"
  [[ "$got" == "4" ]] && pass_at "AC-RK-CONFIG" || fail_at "AC-RK-CONFIG" "got=$got"

  # AC-RK-ZERO-FALLTHROUGH: env=0 with no config → falls through to default 2 with warning.
  unset CLAUDE_MAX_CONCURRENT
  CONFIG=/tmp/nonexistent-$$
  got="$(CLAUDE_MAX_CONCURRENT=0 _resolve_K 2>/dev/null)"
  [[ "$got" == "2" ]] && pass_at "AC-RK-ZERO-FALLTHROUGH" || fail_at "AC-RK-ZERO-FALLTHROUGH" "got=$got"

  # AC-RK-NONINT-FALLTHROUGH: env=abc → falls through with warning.
  got="$(CLAUDE_MAX_CONCURRENT=abc _resolve_K 2>/dev/null)"
  [[ "$got" == "2" ]] && pass_at "AC-RK-NONINT-FALLTHROUGH" || fail_at "AC-RK-NONINT-FALLTHROUGH" "got=$got"
  ```

### Task 5: Refactor `bin/run-local.sh` into scheduler + worker arms (Phase 3 core — the largest diff)

- `depends_on: [2, 3, 4, 4b]`   <!-- Task 2 explicit: scheduler/worker fork-and-wait depends on the semaphore shape (`acquire_claude_mutex` slot accounting) being in place; transitive via 3+4 but called out for clarity -->

- `touches: bin/run-local.sh, bin/run-local-sweep-test.sh`

- [ ] In `bin/run-local.sh`, factor the existing linear body (lines 147-450) into two functions called from a thin `main`. The refactor preserves every existing side effect; it only inverts the lock lifecycle + adds K-fold worker fanout. Use these content-anchored boundaries:
  - **Scheduler arm** owns: lines 147-235 (poll → reconcile → ensure_worktree). Anchor start: `cd "$TARGET_REPO"` (line 147). Anchor end: the closing `}` of the for-each-decision loop (new code).
  - **Worker arm** owns: lines 247-411 (snapshot → run-stage → partition sweep → halt/commit/push). Anchor start: the comment `# Tick-start dirty-path snapshot for self-leak detection (ENG-14 D-4).` (line 247). Anchor end: the closing of section 4 — the `if (( ${#observed_buckets[@]} > 0 )); then ... fi` block (currently ends line 411).
  - **Scheduler arm (post-fork)** owns: lines 413-450 (release watcher + cleanup-worktrees). The cleanup-worktrees call MUST move to BEFORE the worker fork (per brainstorm §4.4 / Phase 3d).
- [ ] Replace the body (lines 147-450) with this structure:
  ```bash
  cd "$TARGET_REPO"

  # ── Scheduler arm: pick K decisions, claim per-issue locks, fork workers ──
  K="$(_resolve_K)"
  log "scheduler: K=$K (concurrency cap)"

  # poll.sh emits an array when --max > 1; a single object when --max == 1.
  if (( K == 1 )); then
    decision="$(bash "$SCRIPT_DIR/poll.sh")"
    decisions_json="[$decision]"
  else
    decisions_json="$(bash "$SCRIPT_DIR/poll.sh" --max "$K")"
  fi
  log "poll decisions: $decisions_json"

  # Filter null/empty (idle) decisions.
  decisions_json="$(jq -c '[.[] | select(.issue_id != null and .issue_id != "")]' <<<"$decisions_json")"
  decisions_count="$(jq 'length' <<<"$decisions_json")"
  if (( decisions_count == 0 )); then
    log "no work this tick"
    exit 0
  fi

  # Per-decision: reconcile + acquire .in-flight.lock + ensure_worktree.
  # Releases the per-issue lock if this decision short-circuits in scheduler.
  declare -a _claimed_workers=()   # parallel arrays: each entry is "<issue>|<stage>|<worktree>|<lock_dir>"
  for di in $(seq 0 $((decisions_count - 1))); do
    decision="$(jq -c ".[$di]" <<<"$decisions_json")"
    issue_id="$(jq -r '.issue_id' <<<"$decision")"
    stage="$(jq -r '.stage' <<<"$decision")"
    entry_action="$(jq -r '.entry_action // "run"' <<<"$decision")"

    # Per-issue in-flight lock (ENG-81 D-002) — acquire with timeout=0 (skip on contention).
    inflight_lock="$(issue_dir "$issue_id")/.in-flight.lock"
    mkdir -p "$(issue_dir "$issue_id")"
    if ! acquire_lock "$inflight_lock" 0; then
      log "scheduler: $issue_id .in-flight.lock held by prior tick worker; skipping this decision"
      continue
    fi

    # Reconcile + entry-action side effects (UNCHANGED logic from lines 160-214).
    if [[ "$entry_action" == "apply-stage-label" ]]; then
      case "$stage" in
        brainstorming|planning|implementing|ui|reviewing|qa|building|released|retrospective) label_suffix="$stage" ;;
        *) label_suffix="$stage" ;;
      esac
      active_state="$(config_get '.linear.native_states.active')"
      bash "$SCRIPT_DIR/linear.sh" transition-state "$issue_id" "$active_state"
      bash "$SCRIPT_DIR/linear.sh" add-label "$issue_id" "stage:$label_suffix"
    fi

    reconcile_decision="proceed"
    if [[ "$stage" == "brainstorming" || "$stage" == "planning" ]]; then
      reconcile_decision="$(bash "$SCRIPT_DIR/reconcile.sh" "$issue_id" "$stage")"
      log "reconcile decision ($issue_id): $reconcile_decision"
    fi

    case "$reconcile_decision" in
      link:*)
        doc_path="${reconcile_decision#link:}"
        bash "$SCRIPT_DIR/linear.sh" add-comment "$issue_id" \
          "Pipeline reconcile: existing $stage doc is canonical: \`$doc_path\`. Advancing without regeneration."
        case "$stage" in
          brainstorming) nxt_label="planning" ;;
          planning)      nxt_label="implementing" ;;
          *)             nxt_label="" ;;
        esac
        [[ -n "$nxt_label" ]] && bash "$SCRIPT_DIR/linear.sh" swap-stage "$issue_id" "$nxt_label"
        bash "$SCRIPT_DIR/metrics.sh" stage-end "$issue_id" "$stage" "linked" 0 "doc=$doc_path"
        release_lock "$inflight_lock"
        continue
        ;;
      human)
        bash "$SCRIPT_DIR/linear.sh" add-comment "$issue_id" \
          "Pipeline reconcile: an existing $stage doc appears to cover this topic. Apply one of: \`pipeline:supersede\`, \`pipeline:extend\`, or \`pipeline:ignore\`."
        bash "$SCRIPT_DIR/metrics.sh" stage-start "$issue_id" "$stage" "reconcile-human" 0
        bash "$SCRIPT_DIR/metrics.sh" stage-end "$issue_id" "$stage" \
          "reconcile-human" 0 "awaiting=supersede-or-extend-or-ignore" || true
        release_lock "$inflight_lock"
        continue
        ;;
    esac

    branch="$(bash "$SCRIPT_DIR/branch-name.sh" "$issue_id")"
    worktree_path="$(resolve_worktree_path "$branch" "$issue_id")"
    mkdir -p "$(dirname "$worktree_path")"
    ensure_worktree "$branch" "$worktree_path"
    [[ -n "$worktree_path" ]] || die "internal: worktree_path empty after reconcile=proceed (ENG-67)"

    _claimed_workers+=("${issue_id}|${stage}|${worktree_path}|${inflight_lock}")
  done

  # ── Scheduler-side cleanup (BEFORE fork — Phase 3d) ──
  tick_count=0
  [[ -f "$TICK_COUNTER" ]] && tick_count="$(cat "$TICK_COUNTER")"
  tick_count=$((tick_count + 1))
  if (( tick_count % CLEANUP_EVERY_N_TICKS == 0 )); then
    log "periodic sweep: running cleanup-worktrees.sh (scheduler arm, pre-fork)"
    bash "$SCRIPT_DIR/cleanup-worktrees.sh" || log "cleanup-worktrees.sh exited nonzero (non-fatal)"
  fi
  printf '%s\n' "$tick_count" > "$TICK_COUNTER"

  # ── Release tick lock BEFORE forking workers ──
  # `release_lock` is rmdir + `|| true`; on the existing scheduler exit
  # path, `cleanup_on_exit` calls `rm -rf "$LOCK_DIR"` which is idempotent
  # if the dir is already gone. Therefore we do NOT clear the EXIT trap —
  # the trap may still need to reap any TWINNING_SWEEP_TMPS the SCHEDULER
  # itself populated. Today's scheduler arm (post-Phase-3 refactor)
  # populates TWINNING_SWEEP_TMPS in NONE of its code paths (snapshot +
  # partition tempfiles all moved into _run_worker), but keeping the trap
  # registered preserves defensive coverage if a future scheduler-side
  # tempfile is added. cleanup_on_exit's `rm -rf "$LOCK_DIR"` after we
  # already released is a benign no-op.
  release_lock "$LOCK_DIR"

  # ── Fork workers in parallel; wait for all ──
  if (( ${#_claimed_workers[@]} == 0 )); then
    log "no workers claimed this tick (all decisions short-circuited in scheduler)"
    exit 0
  fi

  for spec in "${_claimed_workers[@]}"; do
    IFS='|' read -r w_issue w_stage w_worktree w_lock <<<"$spec"
    (
      # Worker subshell entry: REPLACE inherited scheduler trap with our own.
      trap 'release_lock "'"$w_lock"'"' EXIT
      _run_worker "$w_issue" "$w_stage" "$w_worktree"
    ) &
  done

  # set +e around wait so a worker's nonzero rc does not kill the scheduler
  # before sibling workers finish. Each worker's per-issue mutations (counter,
  # halt label, comments) are already done BEFORE the subshell exits.
  set +e
  wait
  set -e

  # Release watcher: detect newly-published GitHub releases (UNCHANGED — scheduler-side).
  LAST_RELEASE_FILE="$PROJECT_STATE_DIR/last-observed-release"
  if command -v gh >/dev/null 2>&1; then
    latest_release_json="$(gh release list --limit 1 --json tagName,name 2>/dev/null || printf '[]')"
    latest_tag="$(jq -r '.[0].tagName // ""' <<<"$latest_release_json")"
    if [[ -n "$latest_tag" ]]; then
      prev_tag=""
      [[ -f "$LAST_RELEASE_FILE" ]] && prev_tag="$(cat "$LAST_RELEASE_FILE")"
      if [[ "$latest_tag" != "$prev_tag" ]]; then
        latest_version="${latest_tag#v}"
        log "release watcher: detected new release $latest_tag (was: ${prev_tag:-none})"
        if bash "$SCRIPT_DIR/on-new-release.sh" "$latest_version" "$latest_tag"; then
          printf '%s\n' "$latest_tag" > "$LAST_RELEASE_FILE"
        else
          log "on-new-release.sh exited nonzero for $latest_tag; will retry next tick"
        fi
      fi
    fi
  else
    log "release watcher: gh CLI not on PATH; skipping"
  fi

  log "== tick end (success, ${#_claimed_workers[@]} worker(s)) =="
  ```
- [ ] DEFINE `_run_worker` as a new function in `bin/run-local.sh`. Anchor: insert AFTER `ensure_worktree()` (which currently ends at line 145) AND BEFORE the `cd "$TARGET_REPO"` line (which is now inside the scheduler arm above):
  ```bash
  # _run_worker — runs in a forked subshell, one per claimed (issue, stage).
  # Performs everything that used to live between snapshot (line 247) and
  # the end of section 4's observed-buckets emit (line 411). Per-issue
  # locks/state mutations are done by called helpers (route_run_stage_exit,
  # halt_issue_for_self_leak, tally_leaked_in_scope_failure) — workers do
  # NOT mutate TWINNING_SWEEP_TMPS or any shared scheduler state.
  _run_worker() {
    local issue_id="$1" stage="$2" dispatch_cwd="$3"

    # Per-worker log file (Phase 3c) — replaces the shared daily log INSIDE
    # the worker subshell. Scheduler-side messages still land in $LOG_FILE.
    local worker_log="$LOG_DIR/local-$(date -u +%Y-%m-%d)-${issue_id}.log"
    exec > >(tee -a "$worker_log") 2>&1
    log "== worker start: $issue_id / $stage =="

    # Per-worker tick-start snapshot (UNCHANGED logic from lines 251-256).
    local snapshot_file
    snapshot_file="$(mktemp -t twinning-snapshot.XXXXXX)"
    local _worker_tmps=("$snapshot_file")
    git -C "$dispatch_cwd" status -z --porcelain \
      | awk 'BEGIN{RS="\\0"} skip==1 { print; skip=0; next }
             length >= 4 { print substr($0, 4); if ($0 ~ /^(R|C)/) skip=1 }' \
      | sort -u > "$snapshot_file"

    set +e
    (cd "$dispatch_cwd" && bash "$SCRIPT_DIR/run-stage.sh" "$issue_id" "$stage")
    local rc=$?
    set -e

    clean_scratch_dir "$dispatch_cwd"
    route_run_stage_exit "$issue_id" "$stage" "$rc"
    if (( rc != 0 )); then
      rm -f "${_worker_tmps[@]}"
      log "== worker end: $issue_id / $stage (rc=$rc) =="
      return "$rc"
    fi

    # 3-stream partition sweep (UNCHANGED logic from lines 282-411).
    local in_scope_file leaked_file out_scope_file
    in_scope_file="$(mktemp -t twinning-inscope.XXXXXX)"
    leaked_file="$(mktemp -t twinning-leaked.XXXXXX)"
    out_scope_file="$(mktemp -t twinning-outscope.XXXXXX)"
    _worker_tmps+=("$in_scope_file" "$leaked_file" "$out_scope_file")
    : > "$in_scope_file" "$leaked_file" "$out_scope_file"

    git -C "$dispatch_cwd" status -z --porcelain \
      | partition_dirty_paths "$stage" "$issue_id" \
          3>"$in_scope_file" 4>"$leaked_file" 5>"$out_scope_file"

    local in_scope_count leaked_count observed_count
    in_scope_count="$(tr -cd '\0' < "$in_scope_file" | wc -c | tr -d ' ')"
    leaked_count="$(tr -cd '\0' < "$leaked_file" | wc -c | tr -d ' ')"
    observed_count="$(tr -cd '\0' < "$out_scope_file" | wc -c | tr -d ' ')"

    local -a observed_buckets=()
    local -a self_leak_hashes=() self_leak_paths=()
    if (( observed_count > 0 )); then
      while IFS= read -r -d '' p; do
        if grep -qxF -- "$p" "$snapshot_file"; then
          local b
          b="$(bucket_for_path "$p")"
          if (( ${#observed_buckets[@]} == 0 )); then
            observed_buckets+=("$b")
          else
            local seen=0 existing
            for existing in "${observed_buckets[@]}"; do
              [[ "$existing" == "$b" ]] && { seen=1; break; }
            done
            (( seen )) || observed_buckets+=("$b")
          fi
        else
          self_leak_hashes+=("$(sha12 "$p")")
          self_leak_paths+=("$p")
        fi
      done < "$out_scope_file"
    fi

    clean_scratch_dir "$dispatch_cwd"

    if (( ${#self_leak_hashes[@]} > 0 )); then
      if stage_is_read_mostly "$stage"; then
        clean_self_leak_residue "$issue_id" "$stage" "$dispatch_cwd" "${self_leak_paths[@]}"
      else
        halt_issue_for_self_leak "$issue_id" "$stage" "${self_leak_hashes[@]}"
        if [[ "$PIPELINE_DRY_RUN" != "1" ]]; then
          rm -f "${_worker_tmps[@]}"
          log "== worker end: $issue_id / $stage (self-leak halt) =="
          return 1
        fi
      fi
    fi

    if (( leaked_count > 0 )); then
      local leaked_hashes="" h p
      while IFS= read -r -d '' p; do
        h="$(sha12 "$p")"
        leaked_hashes="${leaked_hashes:+${leaked_hashes},}${h}"
      done < "$leaked_file"
      tally_leaked_in_scope_failure "$issue_id" "$stage" "$leaked_count" "$leaked_hashes"
      if [[ "$PIPELINE_DRY_RUN" != "1" ]]; then
        rm -f "${_worker_tmps[@]}"
        log "== worker end: $issue_id / $stage (leaked-in-scope tally) =="
        return 1
      fi
    fi

    if (( in_scope_count > 0 )); then
      if [[ "$PIPELINE_DRY_RUN" == "1" ]]; then
        log "[DRY_RUN] would git add -- ($in_scope_count paths):"
        tr '\0' '\n' < "$in_scope_file" | sed 's/^/[DRY_RUN]   /' >&2
      else
        log "committing pipeline artifacts for $issue_id / $stage ($in_scope_count paths)"
        (cd "$dispatch_cwd" && xargs -0 git add -- < "$in_scope_file")
        git -C "$dispatch_cwd" \
          -c user.name="$BOT_NAME" \
          -c user.email="$BOT_EMAIL" \
          commit -m "chore(pipeline): $stage for $issue_id"
        git -C "$dispatch_cwd" push -u origin HEAD
      fi
    else
      log "no in-scope artifacts to commit"
    fi

    if (( ${#observed_buckets[@]} > 0 )); then
      local observed_buckets_csv="" b
      for b in "${observed_buckets[@]}"; do
        observed_buckets_csv="${observed_buckets_csv:+${observed_buckets_csv},}${b}"
      done
      bash "$SCRIPT_DIR/metrics.sh" sweep-observed-out-of-scope "$issue_id" "$stage" \
        "observed" 0 "count=${#observed_buckets[@]} buckets=${observed_buckets_csv}" \
        || log "metrics.sh sweep-observed-out-of-scope emission failed (non-blocking)"
    fi

    rm -f "${_worker_tmps[@]}"
    log "== worker end: $issue_id / $stage (success) =="
    return 0
  }
  ```
- [ ] In `bin/run-local-sweep-test.sh`, add a new K=2 end-to-end fixture (anchor: append after the last existing fixture, before the trailing summary):
  ```bash
  # AC-K2-PARALLEL-WORKERS: K=2 with two distinct issues produces two
  # per-worker log files and two independent .consecutive-failures rows.
  # Pre-seed two .in-flight-eligible issues in fixtures; run a tick;
  # assert both worker log files exist + per-issue counters disjoint.
  K2_DIR="$(mktemp -d)"
  CLAUDE_MAX_CONCURRENT=2 PROJECT_STATE_DIR="$K2_DIR" \
    bash "$HARNESS_DIR/run-local.sh" >/dev/null 2>&1 || true
  d="$(date -u +%Y-%m-%d)"
  [[ -f "$K2_DIR/logs/local-$d-ENG-K2A.log" && -f "$K2_DIR/logs/local-$d-ENG-K2B.log" ]] \
    && pass_at "AC-K2-PARALLEL-WORKERS: both per-worker logs present" \
    || fail_at "AC-K2-PARALLEL-WORKERS" "expected both ENG-K2A and ENG-K2B logs"
  rm -rf "$K2_DIR"
  ```
  (Concrete fixture wiring — Linear stub responses, branch-name stubs, dispatch.sh `PIPELINE_DRY_RUN` short-circuits — follows the existing pattern in this file; QA agent fills in details against the same stub primitives the rest of the file uses.)

### Task 6: Add adversarial coverage for parallel-write contention (Phase 3 hardening)

- `depends_on: [5]`
- `touches: bin/run-local-helpers-adversarial-test.sh`

- [ ] In `bin/run-local-helpers-adversarial-test.sh`, append two adversarial fixtures (anchor: after Task 4's AC-INFLIGHT-LOCK fixture):
  ```bash
  # AC-METRICS-CONCURRENT-WRITE: two parallel writers to events.jsonl
  # produce a valid newline-delimited file (POSIX O_APPEND atomic ≤ PIPE_BUF).
  MC_DIR="$(mktemp -d)"
  PROJECT_STATE_DIR="$MC_DIR" mkdir -p "$MC_DIR/metrics"
  for i in $(seq 1 50); do
    PROJECT_STATE_DIR="$MC_DIR" \
      bash "$HARNESS_DIR/metrics.sh" stage-start "ENG-W1" "implementing" "test" 0 "iter=$i" &
    PROJECT_STATE_DIR="$MC_DIR" \
      bash "$HARNESS_DIR/metrics.sh" stage-start "ENG-W2" "implementing" "test" 0 "iter=$i" &
  done
  wait
  # Assert every line parses as JSON (no torn writes).
  bad=0
  while IFS= read -r line; do
    jq -e . <<<"$line" >/dev/null 2>&1 || bad=$((bad + 1))
  done < "$MC_DIR/metrics/events.jsonl"
  total="$(wc -l < "$MC_DIR/metrics/events.jsonl")"
  (( bad == 0 && total >= 100 )) \
    && pass_at "AC-METRICS-CONCURRENT-WRITE: $total lines, 0 torn" \
    || fail_at "AC-METRICS-CONCURRENT-WRITE" "$bad torn lines (total=$total)"
  rm -rf "$MC_DIR"

  # AC-WORKER-ISOLATION: simulate worker A halting via halt_issue_for_self_leak
  # while worker B's per-issue counter remains untouched.
  WI_DIR="$(mktemp -d)"
  mkdir -p "$WI_DIR/ENG-WIA" "$WI_DIR/ENG-WIB"
  PROJECT_STATE_DIR="$WI_DIR" PIPELINE_DRY_RUN=1 \
    bash -c 'source "$HARNESS_DIR/common.sh"; source "$HARNESS_DIR/classify-failure.sh"; source "$HARNESS_DIR/run-local-helpers.sh"; halt_issue_for_self_leak ENG-WIA implementing abc123def456' \
    >/dev/null 2>&1
  # ENG-WIB's per-issue counter file should NOT exist post-halt of ENG-WIA.
  [[ ! -f "$WI_DIR/ENG-WIB/.consecutive-failures" ]] \
    && pass_at "AC-WORKER-ISOLATION: ENG-WIB counter untouched by ENG-WIA halt" \
    || fail_at "AC-WORKER-ISOLATION" "ENG-WIB counter should not exist"
  rm -rf "$WI_DIR"
  ```

### Task 7: Wire `_resolve_K` into `dispatch.sh` and flip Phase 2's default (Phase 4 — semantic change)

- `depends_on: [4, 5, 6]`
- `touches: bin/dispatch.sh::acquire_claude_mutex, CLAUDE.md`

- [ ] In `bin/dispatch.sh::acquire_claude_mutex`, REPLACE the Phase-2 inline `cap` resolution:
  - Anchor START: the line `local cap="${CLAUDE_MAX_CONCURRENT:-$CLAUDE_MAX_CONCURRENT_DEFAULT_PHASE2}"` (introduced in Task 2).
  - Anchor END: the line `(( cap < 1 )) && cap="$CLAUDE_MAX_CONCURRENT_DEFAULT_PHASE2"` (also introduced in Task 2).
  - Replace those THREE lines with a single call to `_resolve_K`:
    ```bash
    local cap
    cap="$(_resolve_K)"
    ```
  - Remove the now-unused `CLAUDE_MAX_CONCURRENT_DEFAULT_PHASE2=1` constant declaration (immediately above the `_ACQUIRED_SLOT_DIR=""` line introduced in Task 2).
- [ ] In `CLAUDE.md`, near the existing `max_concurrent_features` documentation surface (anchor: search for the literal `orchestrator.max_concurrent_features` string — there is no current CLAUDE.md entry for this knob, so add a new subsection AFTER the "Failure-mode quick reference" table, BEFORE the "What `--action continue` clears" §):
  ```markdown
  ## Per-project dispatch concurrency (ENG-81)

  `orchestrator.max_concurrent_features` (default 2) caps **simultaneous
  `claude -p` dispatches per project per tick** AND the WIP cap on issues
  in any `stage:*` label. Pre-ENG-81 it only enforced the WIP cap; the
  per-tick dispatch count was hardwired to 1 by `bin/run-local.sh`. After
  ENG-81 a default config (`max_concurrent_features=2`) produces 2× the
  per-tick dispatch volume on busy days — operators upgrading should
  expect this.

  Resolution precedence (mirrors ENG-65 timeouts):
  1. `CLAUDE_MAX_CONCURRENT` env var (set in
     `~/Library/LaunchAgents/com.twinning.pipeline.plist`'s
     `EnvironmentVariables` block + `launchctl bootstrap`) — highest.
  2. `.orchestrator.max_concurrent_features` in target's
     `.pipeline-config/config.json`.
  3. Built-in default 2.

  Non-integer or `<1` falls through to the next layer with a `log` warning
  in `$PROJECT_STATE_DIR/<slug>/logs/local-*.log`.

  **Emergency rollback** (no deploy needed): `CLAUDE_MAX_CONCURRENT=1` in
  the launchd plist + `launchctl bootstrap`. Per-project rollback: edit
  that target's `config.json::orchestrator.max_concurrent_features` to 1.
  ```

### Task 8: Add `bin/status.sh` row + watch-week observability hooks (Phase 5)

- `depends_on: [7]`
- `touches: bin/status.sh, CLAUDE.md, docs/runbooks/operator-mental-model.md`

- [ ] In `bin/status.sh`, add a new section AFTER the "events.jsonl tail" section (anchor: search for `section "Last 10 events"` or the equivalent JSONL-section header; insert immediately after its closing `}` of the helper function):
  ```bash
  show_concurrent_dispatches() {
    section "Concurrent dispatches active right now"
    local sem_dir="$HARNESS_STATE_DIR/.claude-semaphore"
    if [[ ! -d "$sem_dir" ]]; then
      printf '  %s(no semaphore dir; harness has not run yet)%s\n' "$C_DIM" "$C_RST"
      return 0
    fi
    local n=0 slot pid
    for slot in "$sem_dir"/slot-*/; do
      [[ -d "$slot" ]] || continue
      n=$((n + 1))
      pid="$(cat "$slot/pid" 2>/dev/null || printf '?')"
      printf '  slot=%s pid=%s\n' "$(basename "$slot" | sed 's/slot-//')" "$pid"
    done
    (( n == 0 )) && printf '  %s(no active dispatches)%s\n' "$C_DIM" "$C_RST"
  }

  show_resource_baseline() {
    section "Dispatch resource baseline (last 24h, from dispatch-resource-sample)"
    local ev="$PROJECT_STATE_DIR/metrics/events.jsonl"
    [[ -f "$ev" ]] || { printf '  %s(no events.jsonl)%s\n' "$C_DIM" "$C_RST"; return 0; }
    jq -r '
      select(.event == "dispatch-resource-sample")
      | .notes
    ' "$ev" 2>/dev/null | tail -20 \
      | sed 's/^/  /' \
      || printf '  %s(no samples yet)%s\n' "$C_DIM" "$C_RST"
  }
  ```
  And invoke them from `main` (anchor: existing `show_*` invocations near the bottom of the file). Add `show_concurrent_dispatches` and `show_resource_baseline` calls in the same group.
- [ ] In `CLAUDE.md`, add a new row to the "Failure-mode quick reference" table (anchor: the existing `| Symptom | Where to look |` table). Insert immediately AFTER the existing "Issue at `stage:building` idles..." row:
  ```markdown
  | Concurrent dispatches not running (expected K=2, observed K=1) | `bin/status.sh` "Concurrent dispatches active" row; check `_resolve_K` resolved value in `$PROJECT_STATE_DIR/<slug>/logs/local-*.log` (look for `scheduler: K=…`); inspect `CLAUDE_MAX_CONCURRENT` env in launchd plist; inspect `orchestrator.max_concurrent_features` in target's `.pipeline-config/config.json`. |
  ```
- [ ] In `docs/runbooks/operator-mental-model.md`, find the existing "earlier-stage issue starves" entry. Anchor: the literal text `The earlier-stage one is starved.` (currently line 65 in the file). Append immediately AFTER that sentence (in the same paragraph or as a follow-on sentence):
  ```
  After ENG-81, this starvation applies only when `held_count ≥ K` — the documented WIP cap (see CLAUDE.md "Per-project dispatch concurrency"). At K=2 (the post-ENG-81 default), two earlier-stage helds advance per tick.
  ```
  Add a NEW entry at the END of the file (anchor: append after the last existing entry; the document is a flat list of mental-model entries, easy to extend) titled "Concurrent slots invisible in Linear":
  ```markdown
  ## Concurrent slots invisible in Linear

  Linear's UI never shows that two dispatches are running on the same tick — both issues just transition state independently. To inspect live concurrency:

      ls $HARNESS_STATE_DIR/.claude-semaphore/slot-*/pid

  Each slot directory holds the dispatch.sh pid that owns it. Empty output ⇒ no live dispatches. `bash bin/status.sh` aggregates this plus the recent `dispatch-resource-sample` baseline.
  ```
- [ ] In each of `README.md`, `docs/architecture.md`, `docs/operations.md`, `docs/install.md`, `docs/assumptions.md`, `docs/runbooks/operator-mental-model.md` (lines 304, 309, 316), find every literal `.claude-mutex.lock` reference and replace with `.claude-semaphore/slot-<N>` (single-flight per slot; the directory name itself is `.claude-semaphore`, slots live under it). Anchor for each occurrence: the literal substring `.claude-mutex.lock` — confirmed via `grep -rln '\.claude-mutex\.lock' README.md docs/` to live ONLY in the operator-facing doc files (the `docs/brainstorms/` and `docs/plans/` references are historical archives that record the pre-ENG-81 state and MUST NOT be edited). Use `Edit ... replace_all: true` per file.

## 6. Frontend Tasks

No FE work — this is a Bash orchestration project (per the project profile's Stack section). All operator-visible surfaces are CLI / config / log / Linear / metrics.

## 7. Failure Mode → Test Map

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
|---|---|---|---|---|
| Two acquirers contend at K=1 (legacy) | Pre-acquire slot-1; second `dispatch.sh` invocation | Second waits ≥3s, observes `[claude-mutex] waiting for lock held by <pid>` log | unit | `bin/mutex-test.sh` (existing case, preserved) |
| Two acquirers, K=2, both slots free | `CLAUDE_MAX_CONCURRENT=2`; pre-acquire slot-1; invoke dispatch | Second takes slot-2 in <2s | unit | `bin/mutex-test.sh::AC-N2-FREE-SLOT-2` |
| Three acquirers contend at K=2 | Pre-acquire slot-1 + slot-2; invoke dispatch | Third waits ≥3s | unit | `bin/mutex-test.sh::AC-N2-CONTEND` |
| `--max 1` legacy emission | Single held; `poll.sh --max 1` | JSON object on stdout (back-compat) | integration | `bin/poll-slot-test.sh::AC-MAX-K-LEGACY-1` |
| `--max 2` with two helds | Two `stage:*`-labeled issues; `poll.sh --max 2` | 2-element JSON array on stdout | integration | `bin/poll-slot-test.sh::AC-MAX-K-2-HELDS` |
| `--max` flag absent | No CLI args | Single object (default 1) | integration | `bin/poll-slot-test.sh::AC-MAX-K-DEFAULT` |
| Per-issue `.in-flight.lock` contention | First holder mkdir's the lock; second `acquire_lock … 0` | Second returns rc=1 (skip) | unit | `bin/run-local-helpers-adversarial-test.sh::AC-INFLIGHT-LOCK` |
| Two K=2 workers writing to `events.jsonl` simultaneously | 50× pairs of `metrics.sh stage-start` in parallel | Every line parses as JSON; ≥100 total lines | unit | `bin/run-local-helpers-adversarial-test.sh::AC-METRICS-CONCURRENT-WRITE` |
| Worker A halts via self-leak; worker B counter untouched | Call `halt_issue_for_self_leak ENG-WIA …` | `$(issue_dir ENG-WIB)/.consecutive-failures` does not exist | unit | `bin/run-local-helpers-adversarial-test.sh::AC-WORKER-ISOLATION` |
| K=2 end-to-end, two issues, two workers | `CLAUDE_MAX_CONCURRENT=2`; two seeded `stage:*` issues | Both `local-YYYY-MM-DD-ENG-N.log` files exist; both per-issue counters separate | integration | `bin/run-local-sweep-test.sh::AC-K2-PARALLEL-WORKERS` |
| `gtime` absent on host | Stub PATH excluding `gtime` | Dispatch proceeds; warning logged; no metric emit | unit | `bin/dispatch-test.sh` Group 5 (degraded path — assert log line, no metric) |
| `gtime` present (stubbed); metric emits | Stub `gtime` writes fixture `-v` output | `dispatch-resource-sample` event in `events.jsonl` with non-empty fields | unit | `bin/dispatch-test.sh::Group-5` |
| `[claude-mutex]` log text regression | Same as legacy K=1 contention case | Log line text unchanged | unit | `bin/mutex-test.sh` (regression coverage via existing grep at line 36) |
| `CLAUDE_MAX_CONCURRENT=0` (operator typo) | Set env to 0, run scheduler | `_resolve_K` falls through to config (or default 2); warning logged | unit | covered by `_resolve_K`'s embedded validation; add direct fixture in `bin/common-test.sh` if it exists (verify and add per Test Strategy §) |
| `_resolve_K` non-integer env | `CLAUDE_MAX_CONCURRENT=abc` | Falls through; warning | unit | `bin/common-test.sh` (sourced helper) |
| Tick N+1 fires while tick N's worker still holds the per-issue lock | Hold `.in-flight.lock` from a prior tick simulation; run scheduler | Scheduler logs skip, picks next decision, no double-dispatch | integration | covered by `AC-INFLIGHT-LOCK` (post-source pattern) |
| `set -e` + `wait` interaction | Worker exits non-zero | Scheduler reaches release-watcher cleanly (set +e/-e bracket around wait) | integration | covered by `AC-K2-PARALLEL-WORKERS` (one worker fails, scheduler still runs release watcher) |
| `cleanup-worktrees.sh` runs concurrent with worker | (cannot happen post-Phase-3d — cleanup runs in scheduler arm pre-fork) | No race possible | structural | not testable; verified by code inspection in `_run_worker` ordering (Task 5) |
| `setup.sh::phase_project_profile` and `dispatch.sh::main` contend for the same slot | Run setup phase while dispatch is in flight | Setup waits via `acquire_claude_mutex`; same `[claude-mutex]` log | integration | covered by Phase 2 acquire helper test (`bin/mutex-test.sh`) — both call sites use the same primitive after Task 2 |

## 8. Test Strategy

### Unit (sourced-helper assertions)

- **`bin/mutex-test.sh`** — extended with N=2 contention cases (Task 2). Existing K=1 grep on `[claude-mutex] waiting` preserved verbatim (A-033 regression coverage).
- **`bin/run-local-helpers-adversarial-test.sh`** — three new fixtures: `AC-INFLIGHT-LOCK` (per-issue lock contention), `AC-METRICS-CONCURRENT-WRITE` (POSIX `O_APPEND` atomicity), `AC-WORKER-ISOLATION` (ENG-69 lane-split regression coverage under parallel).
- **`bin/dispatch-test.sh`** — new Group 5 fixture (Group 4 is taken by ENG-48) stubs `gtime` in `STUB_DIR`, asserts `dispatch-resource-sample` lands in `events.jsonl`. Tests both the success path (gtime present, fixture output parses) and the degraded path (gtime absent, log warning emitted, dispatch still succeeds).
- **`bin/common-test.sh`** — verify the file exists in the harness target's test list (per the profile's "Build & test gates" — yes, it's listed). Add fixtures for `_resolve_K`: `CLAUDE_MAX_CONCURRENT=2 _resolve_K` returns 2; `CLAUDE_MAX_CONCURRENT=0` falls through; `CLAUDE_MAX_CONCURRENT=abc` falls through with warning; missing config returns 2.

### Integration (CLI-driven, stubs for Linear/metrics/slack)

- **`bin/poll-slot-test.sh`** — three new AC-MAX-K-* fixtures cover the array-vs-object emission contract (Task 3). The existing AC-OAR-* / AC-PICK-* fixtures continue to drive the unchanged held/wait/inbox classification logic.
- **`bin/run-local-sweep-test.sh`** — new AC-K2-PARALLEL-WORKERS fixture: K=2 + two seeded issues + assertion on per-worker log files + per-issue counter independence.

### Smoke (post-merge dogfood — Phase 5 watch-week, manual)

- One-week soak on the harness-self target with `max_concurrent_features=2`. Watch:
  - `events.jsonl` for `rc=24` clusters (Linear API rate-limit signal).
  - `dispatch-resource-sample` distribution vs. Phase 1 baseline (no regression ≥2× expected).
  - Self-leak rate (per-issue counter trips) — should not increase ≥2×.
  - `pipeline:halted` label count via `_poll_emit_halt_sprawl_alert` — no cross-issue causality (a halt on one issue does not produce halts on others).
- **Rollback path:** `CLAUDE_MAX_CONCURRENT=1` env in launchd plist + `launchctl bootstrap`. No deploy needed.

### Adversarial (Phase 3 hardening — already covered above)

- `AC-INFLIGHT-LOCK`: defends against tick-N-tick-N+1 overlap re-dispatching the same issue.
- `AC-METRICS-CONCURRENT-WRITE`: defends against torn `events.jsonl` writes.
- `AC-WORKER-ISOLATION`: defends against the regression-of-ENG-69 lane split under K>1.

### Test-gate closure (sweep performed during planning)

The plan REMOVES exactly one production token: the literal directory name `.claude-mutex.lock` (replaced by `.claude-semaphore/slot-<N>`). Sweep results (via `grep -rln '\.claude-mutex\.lock'` against `bin/`, `README.md`, `docs/`):

- **Test files containing the token:** `bin/mutex-test.sh:26,29,36` — addressed by Task 2 (test setup updated to `.claude-semaphore/slot-1`; the `[claude-mutex]` log text grep at line 36 is preserved by Task 2's deliberate text retention per A-033). No other `bin/*-test.sh` files reference this token.
- **Operator-facing docs containing the token:** `README.md`, `docs/architecture.md` (4 refs), `docs/operations.md`, `docs/install.md`, `docs/assumptions.md`, `docs/runbooks/operator-mental-model.md` (3 refs) — addressed by Task 8's doc-rot fix step. All listed in File Structure.
- **Historical archives containing the token (NOT touched):** `docs/brainstorms/*.md`, `docs/plans/*.md` — these are point-in-time records that document the pre-ENG-81 state and MUST remain unedited.

The `[claude-mutex]` log message text is preserved verbatim (per A-033) so no other test breaks from log-text drift. No other production token is removed; all source-code changes are additive.

### Stages of validation that gate merge

1. `bash bin/mutex-test.sh` (Phase 2 done).
2. `bash bin/poll-slot-test.sh` (Phase 3a done).
3. `bash bin/run-local-helpers-adversarial-test.sh` (Phase 3 hardening done).
4. `bash bin/run-local-sweep-test.sh` (Phase 3 end-to-end done).
5. `bash bin/dispatch-test.sh` (Phase 1 instrumentation done).
6. `bash .githooks/pre-commit` (full suite — every `bin/*-test.sh`, ~30s, gates the commit).
7. Phase 5 watch-week (post-merge, ~7 calendar days).

## Persona-review notes

(Filled in during the self-review pass — see step 3 of the completion checklist.)
