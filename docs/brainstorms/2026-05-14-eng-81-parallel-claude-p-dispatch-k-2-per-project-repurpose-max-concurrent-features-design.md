---
linear: ENG-81
title: Parallel claude -p dispatch (K=2 per project, repurpose max_concurrent_features)
date: 2026-05-14
status: draft
---

# Parallel `claude -p` dispatch — repurpose `max_concurrent_features` to drive concurrent dispatch (K=2 default)

## 1. Overview (and the load-bearing surprise)

Today the harness wakes every 5 min and dispatches **at most one**
`claude -p` invocation per project per tick. Two `stage:*`-labelled
issues alternate ticks rather than progressing in parallel. The
binding constraint is structural serialization in `bin/run-local.sh`
+ `bin/poll.sh`, NOT the host (RSS / CPU steady-state idle) and NOT
the Claude subscription. `claude -p` itself is I/O-bound on the
Anthropic API.

The serialization stack today:

| Layer | Where | Purpose | Today |
|---|---|---|---|
| launchd cadence | `launchd/com.twinning.pipeline.plist.template:19` | `StartInterval=300` — wakeups, not work | Unchanged |
| Per-project tick lock | `bin/run-local.sh:37,51` (`PROJECT_STATE_DIR/.run-local.lock`) | Single-flight: overlapping 5-min fires don't stack | Held for the entire tick (poll → reconcile → dispatch → sweep) |
| Global Claude mutex | `bin/dispatch.sh:20-39` (`HARNESS_STATE_DIR/.claude-mutex.lock`) | Serializes every `claude -p` host-wide | Binary mkdir lock, capacity 1 |
| Picker exit-on-first | `bin/poll.sh:698,708,716` (three `exit 0` arms in `main`'s while loop over `_picker_build_pool`'s output) | Returns ONE decision per tick | Pool already sorted; only the head is consumed |

Net effect: with `orchestrator.max_concurrent_features=2` (the
default at `bin/setup.sh:530-531`), two issues compete for one
dispatch per tick. Per-tick throughput is K=1 even though the
"max concurrent features" knob says K=2.

**The load-bearing surprise.** `max_concurrent_features` is
narrower than its name suggests. Today it caps **inbox-pickup pool
construction** in `_picker_build_pool` (`bin/poll.sh:470` —
`(( held_count < max_concurrent ))`) and is the WIP cap on held
slots (`bin/poll.sh:647-650`). It does NOT cap how many already-in-
flight issues advance per tick — that's hard-wired to 1 by `main`'s
`exit 0` after the first dispatch. The contract change in this
ticket is **rename-in-place**: same knob, same default, expanded
scope so it actually means what its name suggests.

## 2. Goals

After this ticket lands:

1. **G-1 (concurrent dispatch).** With
   `orchestrator.max_concurrent_features=2` (existing default), two
   distinct issues advance through pipeline stages on the same 5-min
   tick. `bin/poll.sh` returns up to K decisions; `bin/run-local.sh`
   forks K worker subprocesses; the global Claude mutex becomes a
   counting semaphore at capacity K.
2. **G-2 (per-issue isolation preserved).** One worker's halt does
   not freeze its sibling. The per-issue counter lane (ENG-69), the
   per-issue worktree (ENG-67), the per-issue cost telemetry
   (`usage-<stage>.json` under `$(issue_dir)`), and the per-issue
   `dispatch_id` (ENG-87) are already in place and form the entire
   isolation surface — this ticket adds NO new shared mutable state
   between workers.
3. **G-3 (rollback without deploy).** A new env var
   `CLAUDE_MAX_CONCURRENT` overrides `max_concurrent_features` for
   emergency rollback to K=1. Resolution precedence mirrors ENG-65
   timeouts: env var > config > built-in default (2). Non-integer or
   `< 1` values fall through to the next layer with a `log` warning.
4. **G-4 (no shared-resource regression).** Concurrent metric writes
   to `events.jsonl` produce a valid newline-delimited file (POSIX
   atomic append for ≤ `PIPE_BUF` per write — line size today is
   ~200–400 bytes, well under 4 KB). Concurrent worktree-cleanup
   does not race a worker (cleanup runs in the scheduler arm before
   fork). The `gh-app-token.sh`-minted `GITHUB_TOKEN` is exported
   once in the scheduler and inherited by all workers.
5. **G-5 (instrumented baseline).** A new `dispatch-resource-sample`
   metric event captures wall-clock + peak RSS + average CPU% per
   dispatch via `gtime -v` (`gtime` is already a transitive Homebrew
   dep through `gtimeout`). One week of data informs whether a
   future K=3 is safe.
6. **G-6 (phased rollout, behavior-preserving by default).**
   Phase 2 lands the counting-semaphore abstraction at capacity 1
   (no behavior change). Phase 3 lands the scheduler/worker split
   with default K=1 (no behavior change). Phase 4 flips the default
   to K=2 (the actual semantic change) — but `max_concurrent_features=2`
   was already shipping, so existing operator configs auto-inherit
   the new behavior; this is the deploy step that needs the loud
   upgrade note.

Non-goals (explicit):

- **Cross-project parallelism.** Semaphore capacity is the per-project
  K (not host-wide). Two projects each at K=2 would observe
  cross-project mutex contention. Deferred to a separate ticket once
  two-project dogfood data exists.
- **Dynamic K.** Static K=2 first; an adaptive controller is the
  natural follow-up the retrospective agent can compute weekly from
  the Phase 1 metric stream.
- **Splitting `max_concurrent_features` into queue-depth vs
  dispatch-cap.** Speculative until a real workload demands it; not
  paying for a new knob today.
- **Global host-wide concurrency knob (`harness.max_parallel_dispatches_global`).**
  Implied by the cross-project deferral above.

## 3. Anti-bias checks

### 3.1 ADR stress test

The existing architectural decisions this ticket pressure-tests:

| Decision | Pressure from this ticket | Cost |
|---|---|---|
| **ENG-67 D-003 (per-issue worktree invariant — `die` on empty `worktree_path`)** | Stronger, not weaker. Two parallel workers MUST each have their own worktree; the invariant guarantees that. No conflict. | None. |
| **ENG-69 (per-issue/global counter lane split)** | Strictly stronger. One worker's tip-over does not freeze another. The lane split is the SOLE prerequisite that made this ticket viable; absent it, three independent agent failures on three issues would still trip the global breaker. No conflict. | None. |
| **ENG-87 (`dispatch_id` per-issue monotonic)** | The id is per-issue and allocated under `allocate_dispatch_id`'s per-issue mkdir lock (`bin/common.sh:108-114`). Two parallel dispatches on DIFFERENT issues each allocate independently and atomically; two parallel dispatches on the SAME issue cannot happen because the per-issue in-flight lock (D-002 below) prevents it. No conflict. | None. |
| **ENG-90 (slot-occupancy contract — every `vacate` declares `operator_action_required`)** | The picker pool already encodes this. Extending the picker to return up to K decisions does not change classifier semantics — same `slot/operator_action_required` rules apply per row. No conflict. | None. |
| **ENG-91 (Pass 4U unified ranked picker)** | This is the layer the ticket extends. `_picker_build_pool` already returns a sorted JSON array; today only the head is consumed. The change is "consume up to K from the head" — it composes naturally with the unified ranking. No conflict. | None. |
| **ENG-86 (orchestrator entry-conditions gate)** | Each worker's pre-dispatch path runs the gate independently. No shared mutable state in the gate. No conflict. | None. |
| **ENG-21 (halt-sprawl alert)** | Reads `classified` only; never fails the tick. Counts vacate rows. Adding parallel dispatch increases tick throughput but does not change halt classification. No conflict. | None. |
| **ENG-77 D-001 (stage-summary file overwrite-on-every-dispatch)** | Per-issue file. Two parallel workers on different issues write different files. ENG-87's `_clear_current_stage_slots` runs at dispatch start per worker. No conflict. | None. |
| **`set -euo pipefail` everywhere** | Subshell-fork model preserves these semantics per worker. The scheduler MUST `set +e` around `wait` so a worker's non-zero rc doesn't kill the scheduler before sibling workers finish. Standard idiom. | Tiny — one `set +e/-e` block in scheduler. |
| **Bash trap is REPLACED, not stacked (CLAUDE.md "Bash traps are NOT stacked")** | Worker subshells inherit the parent's trap on EXIT. Workers MUST `trap` their OWN cleanup (per-issue lock release) AT WORKER ENTRY — overwriting the inherited scheduler trap. Discipline-only; no architectural conflict. | One trap line per worker. |

**No existing ADR is overturned.** The single durable assumption
this ticket disturbs is the implicit "one dispatch per tick" model
operators have learned by inspection. Phase 4 is the deploy step
where that mental model needs to flip; CLAUDE.md + operator-mental-
model runbook updates carry the load.

### 3.2 Simpler alternatives considered

| Alternative | Why rejected |
|---|---|
| **Run two `bin/run-local.sh` instances back-to-back inside one launchd fire** (sequential serial-2× per tick) | Doubles tick wall-clock under contention; the tick lock makes this a no-op (second invocation skips). And it doesn't actually parallelize — sequential dispatches still alternate stages within the doubled tick. |
| **Drop the global Claude mutex entirely; rely on Anthropic's API rate limiting** | Surrenders the host-side audit point (the `[claude-mutex] waiting for lock held by <pid>` log line); concedes graceful queueing under burst; loses the hard cap operators trust. The counting semaphore preserves all three at minimal LOC cost over the existing mkdir pattern. |
| **Move to a real job queue (Redis, SQS, file-based fifo)** | Massive scope creep. Bash mkdir-locks + a per-issue lock and a counting semaphore are already POSIX-atomic, observable via `ls`, and survive crashes (release-on-trap + stale-pid recovery). Adding a queue would require `brew install redis`, secret management, a new failure mode (queue down → no dispatch), and a runbook update. |
| **Hold the project tick lock through dispatch (i.e. keep today's lifecycle, just dispatch K things sequentially)** | Two ticks back-to-back can dispatch 2 issues today already (one per tick). The point of K=2 is that two issues progress on the SAME 5-min wall-clock — wall-clock parallelism is what reduces queue depth. Holding the lock through dispatch precludes that. |
| **Per-stage K** (e.g., K=3 for brainstorm, K=1 for implement) | Speculative. The Phase 1 instrumentation will reveal whether stages have meaningfully different resource profiles. Defer to a follow-up if data justifies it. |
| **Don't add `CLAUDE_MAX_CONCURRENT` env var; require `state.local.json` edit for rollback** | Operator must edit a JSON file mid-incident; env var is one-line in `~/Library/LaunchAgents/com.twinning.pipeline.plist`'s `EnvironmentVariables` block + `launchctl bootstrap`. Cheap insurance against an Anthropic-side concurrency cap discovered the hard way in Phase 5. |
| **Skip Phase 1 instrumentation** | Without a baseline, Phase 5's "watch-week" predicate is "did it not catch fire?" — no quantitative claim. Phase 1 is half a day of work for the diagnostic surface that lets us answer the K=3 question later. |

### 3.3 Assumption inventory

Every named identifier below has been read against the current
checkout. `path:line` references quote what's there now; the
distinction "verified" / "assumed" indicates whether the code
exists today vs what the implementation must add.

| Assumption | Status | Evidence |
|---|---|---|
| `bin/dispatch.sh::acquire_claude_mutex` is a binary mkdir lock at `$HARNESS_STATE_DIR/.claude-mutex.lock` | verified | `bin/dispatch.sh:20-36` (`mkdir "$CLAUDE_MUTEX_DIR" 2>/dev/null` loop with `CLAUDE_MUTEX_TIMEOUT=600`) |
| `bin/dispatch.sh::release_claude_mutex` is `rm -rf "$CLAUDE_MUTEX_DIR"` and is hooked via `trap 'release_claude_mutex' EXIT` | verified | `bin/dispatch.sh:38-40,476` |
| `bin/dispatch.sh::main` writes `$$` to `$CLAUDE_MUTEX_DIR/pid` for the existing diagnostic log line | verified | `bin/dispatch.sh:35` |
| `bin/run-local.sh` holds `$PROJECT_STATE_DIR/.run-local.lock` for the entire tick lifecycle | verified | `bin/run-local.sh:37,51` (acquire) and the `cleanup_on_exit` trap at line 59-65 (rm -rf on EXIT) |
| `bin/run-local.sh` calls `poll.sh` once and treats its single decision JSON as authoritative | verified | `bin/run-local.sh:149-158` (`decision="$(bash "$SCRIPT_DIR/poll.sh")"`; `issue_id=$(jq -r '.issue_id // ""' <<<"$decision")`) |
| `bin/poll.sh::main` exits 0 on first dispatched candidate via three `exit 0` arms (held / wait_recallable / inbox) | verified | `bin/poll.sh:698, 708, 716` (each case-arm in the `while (( i < n ))` loop) |
| `_picker_build_pool` already returns a sorted JSON array of candidates with `picker_source ∈ {held, wait_recallable, inbox}` | verified | `bin/poll.sh:459-527`; sort key `[-stage_index, -priority_sort_rank, fifo_ts, .identifier]` at line 526 |
| `orchestrator.max_concurrent_features` defaults to 2 in `bin/setup.sh::write_config` | verified | `bin/setup.sh:530-531` |
| `poll.sh::main` reads `max_concurrent_features` defensively (defaults to 2 if unset) | verified | `bin/poll.sh:626-630` |
| `bin/run-local-helpers.sh::route_run_stage_exit` routes rc=24 to global counter, every other rc to per-issue (`$(issue_dir)/.consecutive-failures`) | verified | `bin/run-local-helpers.sh:388-430` (case `$rc` arms; per-issue `pic_file` at line 393) |
| `bin/run-local-helpers.sh::halt_issue_for_self_leak` halts a single issue without tripping the global breaker | verified | `bin/run-local-helpers.sh:128-154` (calls `classify_failure` with `skip-until-human-acts`; no `trip_breaker`) |
| `bin/common.sh::issue_dir <issue>` returns `$PROJECT_STATE_DIR/<issue>` | verified | `bin/common.sh:68-72` |
| `bin/common.sh::allocate_dispatch_id` is per-issue locked via `acquire_lock "$lock_dir" 60` | verified | `bin/common.sh:104-121` (mkdir at `$(issue_dir)/.allocate.lock`); read-modify-write in `_allocate_dispatch_id_locked` at line 123-147 |
| `bin/common.sh::acquire_lock` accepts an optional timeout and is mkdir-based (POSIX-atomic) | verified | `bin/common.sh:395-403` |
| `bin/dispatch.sh::main` env block exports `PIPELINE_DISPATCH_ID`, `PIPELINE_WRITER=agent`, `PIPELINE_STAGE` into the agent subshell | verified | `bin/dispatch.sh:555-557` |
| `bin/dispatch.sh::_render_and_capture_stream` writes `usage-<stage>.json` at `$(issue_dir)` mode 0600 | verified | `bin/dispatch.sh:117-125` (umask 077; conditional jq extract) |
| `bin/run-local.sh` mints `GITHUB_TOKEN` once per tick at `:101` and exports it; subprocesses inherit naturally | verified | `bin/run-local.sh:101-103` |
| `bin/metrics.sh::main` writes a single jq line via `>>` (POSIX `O_APPEND`); single line ≤ ~400 bytes | verified | `bin/metrics.sh:53-74`. Atomic-append guaranteed for writes ≤ `PIPE_BUF` (4 KB on macOS); a sample line above has 8 fields plus 4–6 cost flags = ~250–500 bytes. |
| `bin/run-local.sh` calls `cleanup-worktrees.sh` every 10 ticks via `CLEANUP_EVERY_N_TICKS=10` at `:42` and runs it at line 444-447 (END of tick after dispatch) | verified | `bin/run-local.sh:42, 438-448` |
| `bin/run-local.sh::cleanup_on_exit` (`:59-65`) is `trap`'d on EXIT and removes the project lock + sweep tempfiles | verified | `bin/run-local.sh:54-65` (CLAUDE.md notes: "Bash traps are NOT stacked — a later `trap ... EXIT` REPLACES this one") |
| `bin/run-local.sh:251` does the tick-start dirty-path snapshot against `$dispatch_cwd` (the per-issue worktree, not `$TARGET_REPO`) | verified | `bin/run-local.sh:251-256` |
| Per-issue scratch lives at `$PROJECT_STATE_DIR/<issue>/{worktree, issue-state.json, dispatch_history.jsonl, ...}` | verified | CLAUDE.md "Per-issue state directory" §; `bin/common.sh::issue_dir` at `:68-72` |
| `gtime` (GNU coreutils) is on the harness host PATH (transitively through `gtimeout` which is already required) | assumed | `gtimeout` is required at `bin/dispatch.sh:524` (`require_bin claude gtimeout`); both ship in `coreutils`. Phase 1 will add `require_bin gtime` adjacent to the existing call. |
| Concurrent `mkdir slot-N` for `1..N` is racy-safe: at most one process succeeds per slot | verified (POSIX) | `mkdir(2)` is atomic; the existing `acquire_claude_mutex` already relies on this for the binary case. |
| `bash -c '(...)' &` forks a subshell; `wait` blocks until all background jobs complete | verified (Bash spec) | Standard Bash behavior; used in `capture_core_bare_forensic` (`bin/run-local-helpers.sh:769-817`) for parallel artifact captures, so the pattern already lives in the codebase. |
| Stage-keys in CLAUDE.md "Per-stage dispatch timeouts" table are gerund form (`brainstorming`, `planning`, …) | verified | `bin/dispatch.sh::allowed_tools_for` case arms at `:421-432`; CLAUDE.md "Per-stage dispatch timeouts (ENG-65)" §. |
| `bin/run-stage.sh::main` is the unit run by each worker (takes `<issue> <stage>`) | verified | `bin/run-stage.sh:975-977` |
| `bin/poll.sh` already validated that wait_recallable inclusion is gated on `_picker_predicate_ready` (ENG-91) | verified | `bin/poll.sh:483-491` |

**Items left "assumed":**

- `gtime` resident on macOS Homebrew installs (Phase 1 will guard
  with `require_bin gtime`; degraded mode emits the metric without
  rss/cpu fields).

## 4. Architecture

The contract has **one glue and three new mechanisms**.

### 4.1 The glue: `K`, the per-project dispatch concurrency

```
K = ${CLAUDE_MAX_CONCURRENT-}                      # env var (P3.5)
K = K, fall through if empty / non-integer / < 1
K = orchestrator.max_concurrent_features (config)  # P4
K = K, fall through if missing / non-integer / < 1
K = 2                                              # built-in default
```

K is read **once per tick** in the scheduler. It controls:

- The **number of decisions** `bin/poll.sh --max K` returns.
- The **number of forks** the scheduler creates.
- The **capacity of the Claude semaphore** during this tick (each
  worker tries to acquire one of slots `1..K`).

K is **not stored on disk**; it's computed each tick and lives only
for the tick's lifetime. There's no per-worker "slot id" surfaced
above the semaphore — the semaphore owns slot accounting, the
scheduler owns "spawn K workers", and the worker is unaware of its
slot number.

### 4.2 The three new mechanisms

| Mechanism | Lives in | Purpose |
|---|---|---|
| **Counting semaphore** (replaces binary mutex) | `bin/dispatch.sh::acquire_claude_mutex` / `release_claude_mutex` | Replace single `mkdir $HARNESS_STATE_DIR/.claude-mutex.lock` with `mkdir $HARNESS_STATE_DIR/.claude-semaphore/slot-<N>` for the first free `N ∈ 1..K`. mkdir-atomic; rmdir on release. Holder pid stays in `slot-<N>/pid` for the existing diagnostic log line. The single mkdir lock at `$HARNESS_STATE_DIR/.claude-semaphore/` directory itself is the parent that lets the per-slot mkdirs happen — created idempotently, never released. |
| **Per-issue in-flight lock** | New: `$(issue_dir <issue>)/.in-flight.lock` (mkdir-based, trap-released by worker) | Prevents the scheduler from forking two workers against the same issue if a tick's poll output happens to repeat an identifier (defense-in-depth) AND prevents a long-running worker from being clobbered by the next tick's scheduler picking the same issue (today's tick lock prevents this; per-issue lock is the post-split equivalent that survives release-of-tick-lock-before-fork). |
| **Scheduler/worker split in `bin/run-local.sh`** | `bin/run-local.sh::main` (refactor) | Lifecycle inversion: scheduler holds the project tick lock for ~seconds (poll → reconcile → ensure-worktree → fork); workers hold ZERO global locks, only their own per-issue in-flight lock + their own claude-semaphore slot. `wait` for all workers; THEN release the tick lock + run cleanup-worktrees. |

### 4.3 The five smaller, additive changes

Each is one of: (a) extension of an existing primitive, (b) new
metric event, (c) doc edit. None of them is on the scheduler/worker
critical path.

| Change | File | Phase | LOC |
|---|---|---|---|
| `dispatch-resource-sample` metric event via `gtime -v` wrapping `claude -p` | `bin/dispatch.sh` (`main`) + `bin/metrics.sh` (event taxonomy is open — no schema change needed) | P1 | +25 |
| Per-worker log file `$LOG_DIR/local-YYYY-MM-DD-<issue>.log` (stop tee'ing into the shared daily log from inside workers) | `bin/run-local.sh` (worker arm) | P3c | +5 |
| Mint `GITHUB_TOKEN` once in scheduler; export to workers via env | `bin/run-local.sh` (no change — `export` is already there at `:102`; subshell forks inherit naturally) | P3 | 0 (verify only) |
| `bin/poll.sh --max <K>` flag; emit a JSON array of decisions when `K > 1`; legacy single-object output preserved when `K == 1` (the default) | `bin/poll.sh::main` | P3a | +25 |
| `bin/status.sh` row: "concurrent dispatches active right now" (count semaphore slots present) + "median dispatch RSS / CPU% (last 24h)" from `events.jsonl` | `bin/status.sh` | P5 | +30 |

### 4.4 Lifecycle diagram (post-Phase-3)

```
T0  launchd fires (every 5 min)
    │
    └─ run-local.sh starts
       │
       ├─ acquire_lock $PROJECT_STATE_DIR/.run-local.lock (project tick lock)
       │  trap cleanup_on_exit EXIT  (release tick lock + sweep tempfiles)
       │
       ├─ load secrets, mint GITHUB_TOKEN, export
       │
       ├─ check is_orchestrator_paused
       │
       ├─ K = resolve_K()                                      ← new in P4
       │
       ├─ decisions = bash poll.sh --max $K                    ← new in P3a
       │              (returns JSON array of up to K decisions)
       │
       ├─ for each decision:
       │    issue, stage = decision.issue_id, decision.stage
       │    acquire $(issue_dir issue)/.in-flight.lock  (skip if held)
       │    if reconcile yields link:/human → handle in scheduler, release lock
       │    else ensure_worktree
       │
       ├─ release_lock $PROJECT_STATE_DIR/.run-local.lock      ← new ordering: BEFORE fork
       │
       ├─ run cleanup-worktrees.sh (every 10 ticks)            ← scheduler-side, before fork (P3d)
       │
       ├─ for each claimed (issue, stage, worktree):
       │    fork worker subshell:
       │      trap 'release_lock $(issue_dir issue)/.in-flight.lock' EXIT
       │      tick-start dirty-path snapshot vs $worktree
       │      log to $LOG_DIR/local-YYYY-MM-DD-$issue.log via exec >() 2>&1
       │      run-stage.sh $issue $stage              ← inside acquire/release_claude_mutex
       │                                                   (now counting semaphore, P2)
       │      clean_scratch_dir $worktree
       │      route_run_stage_exit $issue $stage $rc  ← per-issue counter (ENG-69)
       │      partition_dirty_paths → in_scope / leaked / out_of_scope
       │      halt / commit / push as today
       │      release_lock $(issue_dir issue)/.in-flight.lock (via trap)
       │      exit
       │    & (background)
       │
       ├─ wait                                                 ← block on all workers
       │
       ├─ release watcher: `gh release list` (scheduler-side, post-wait)
       │
       └─ trap fires: release_lock $PROJECT_STATE_DIR/.run-local.lock + reap tempfiles
```

The scheduler holds the **project tick lock** for ~seconds (poll +
reconcile + worktree provisioning); the **counting semaphore** is
held only during a worker's `claude -p` invocation; the
**per-issue in-flight lock** is held for a worker's full lifetime.

### 4.5 Slot-ordering semantics under K>1 (no change)

`_picker_build_pool` already sorts by `[-stage_index,
-priority_sort_rank, fifo_ts, .identifier]`. The "first match wins"
semantics today extends naturally to "top-K wins" — same sort, just
take more entries. The operator-mental-model entry in §1
("earlier-stage issue starves") becomes "earlier-stage issues
starve only when held_count ≥ K", which matches operator intuition
for a WIP cap.

## 5. Components

### 5.1 The `K` glue

| File | Change | Phase | LOC |
|---|---|---|---|
| `bin/run-local.sh` | New `_resolve_K()` helper: env var > config > default 2; integer ≥ 1 validation with fallback. Caller in scheduler arm computes K once. | P4 | +25 |
| `bin/dispatch.sh` | `acquire_claude_mutex` reads `CLAUDE_MAX_CONCURRENT` (defaults to 1 in Phase 2 → resolves to scheduler's K in Phase 4). | P2 / P4 | +10 |

### 5.2 The counting semaphore

| File | Change | Phase | LOC |
|---|---|---|---|
| `bin/dispatch.sh::acquire_claude_mutex` | Loop over `slot ∈ 1..N`; first successful `mkdir $HARNESS_STATE_DIR/.claude-semaphore/slot-<N>` wins; record slot path in a function-local var; write pid into `slot-<N>/pid`. Existing `[claude-mutex] waiting for lock held by <pid>` log line preserved (now "lock held by …" reads slot-1's pid as the eldest holder). `CLAUDE_MUTEX_TIMEOUT` and the loud-die-on-timeout preserved verbatim. | P2 | +25 |
| `bin/dispatch.sh::release_claude_mutex` | rmdir the same `slot-<N>` (passed via function-local). | P2 | +5 |
| `bin/dispatch.sh` (parent dir creation) | `mkdir -p $HARNESS_STATE_DIR/.claude-semaphore` once at script entry (idempotent). | P2 | +1 |
| `bin/mutex-test.sh` | New cases: (a) two acquirers contend at N=1 (existing behavior preserved), (b) two acquirers each get a slot at N=2, (c) three acquirers at N=2 → third waits. Existing test (the 3-second sleep contention test at line 26-38) parameterized on N. | P2 | +60 |

### 5.3 The per-issue in-flight lock

| File | Change | Phase | LOC |
|---|---|---|---|
| `bin/run-local.sh` (scheduler arm) | After per-decision `ensure_worktree`, attempt `acquire_lock "$(issue_dir issue)/.in-flight.lock" 0` (timeout=0 → return immediately on contention). On contention: log + skip this decision, continue to next. | P3 | +10 |
| `bin/run-local.sh` (worker arm) | `trap 'release_lock $(issue_dir issue)/.in-flight.lock' EXIT` at worker entry (REPLACES the inherited scheduler trap; CLAUDE.md "Bash traps are NOT stacked"). | P3 | +3 |

The lock is sibling to `$(issue_dir)/.allocate.lock` (ENG-87,
`bin/common.sh:108`) — same mkdir pattern, same `release_lock`
helper. No new primitive.

### 5.4 The scheduler/worker split

| File | Change | Phase | LOC |
|---|---|---|---|
| `bin/run-local.sh::main` (today: linear script body lines 1-451) | Refactor into `_scheduler` and `_worker` functions called by `main`. Scheduler runs decisions loop + ensure_worktree, releases tick lock, forks K workers via `( _worker $issue $stage $worktree ) &`, `wait`s. Worker contains everything from tick-start snapshot through partition sweep through commit/push. | P3 | +200 / -150 |
| `bin/run-local-helpers.sh` | No change. The existing helpers (`partition_dirty_paths`, `halt_issue_for_self_leak`, `tally_leaked_in_scope_failure`, `route_run_stage_exit`, `clean_scratch_dir`, `clean_self_leak_residue`) are already pure functions and are called per-issue. | P3 | 0 |
| `bin/poll.sh::main` | `--max <K>` argument (default 1). When K>1, emit a JSON array of up to K decisions instead of a single object. The walk loop preserves the existing per-arm logic (held / wait_recallable / inbox); only the `exit 0` → `continue` after appending each decision changes. | P3a | +30 |

### 5.5 The per-worker log file

| File | Change | Phase | LOC |
|---|---|---|---|
| `bin/run-local.sh` (worker arm) | `local _worker_log="$LOG_DIR/local-$(date -u +%Y-%m-%d)-$issue.log"; mkdir -p "$LOG_DIR"; exec > >(tee -a "$_worker_log") 2>&1` at worker entry. The scheduler still tees to `$LOG_FILE` (the shared daily log) for its own scheduler-side messages — operator can `cat $LOG_DIR/local-$(date -u +%Y-%m-%d)*.log \| sort` for a unified view. | P3c | +5 |

### 5.6 The instrumentation

| File | Change | Phase | LOC |
|---|---|---|---|
| `bin/dispatch.sh::main` | Wrap the `claude -p` invocation in `gtime -v -o "$gtime_out"`; post-dispatch parse the gtime output for `Maximum resident set size` + `Percent of CPU this job got` + `Elapsed (wall clock) time`; emit `bash bin/metrics.sh dispatch-resource-sample $issue $stage measured 0 "wall_seconds=… max_rss_kb=… cpu_pct=…"`. Soft-fail on missing gtime — log a warning and skip the metric (no behavior change). | P1 | +30 |
| `bin/status.sh` | New row: median RSS + median CPU% over the last 24h of `dispatch-resource-sample` events; new row "concurrent dispatches active" = count of `$HARNESS_STATE_DIR/.claude-semaphore/slot-*/pid` files. | P5 | +30 |

### 5.7 Tests

| File | Change | Phase | LOC |
|---|---|---|---|
| `bin/mutex-test.sh` | Three new cases for capacity 1 / 2 (see §5.2). | P2 | +60 |
| `bin/poll-slot-test.sh` | New fixtures: `--max 2` with two held → returns 2-element array; `--max 2` with one held + two inbox → returns held + 1 inbox in priority order; `--max 1` returns single object (legacy preservation). | P3a | +80 |
| `bin/run-local-sweep-test.sh` (or new `bin/run-local-parallel-test.sh`) | E2E fixture: K=2, two distinct issues, both worker logs present at expected paths, both per-issue counters update independently, no interleaved writes to the project tick log, both `usage-<stage>.json` files present. | P3 | +120 |
| `bin/run-local-helpers-adversarial-test.sh` | New fixture: two workers race to acquire the SAME per-issue lock (e.g., a stale carryover from a prior tick). Second observer sees contention; scheduler skips; no double-dispatch; metric emitted for the skip. | P3 | +50 |
| `bin/run-local-helpers-adversarial-test.sh` | New fixture: two workers writing concurrently to `events.jsonl` produce a valid newline-delimited file (parse with `jq -c .` on every line; assert non-zero count and zero parse errors). | P3 | +40 |
| `bin/run-local-helpers-adversarial-test.sh` | New fixture: self-leak halt on worker A does NOT freeze worker B (regression coverage for the ENG-69 lesson — direct test that two parallel workers' fates are independent). | P3 | +50 |
| `bin/dispatch-test.sh` | Stub `gtime` to emit a fixture output; assert `dispatch-resource-sample` metric event lands. | P1 | +40 |

### 5.8 Documentation

| File | Change | Phase | LOC |
|---|---|---|---|
| `CLAUDE.md` "Three locations every script touches" | Note that the global Claude mutex at `$HARNESS_STATE_DIR/.claude-mutex.lock` is now `$HARNESS_STATE_DIR/.claude-semaphore/slot-<N>` (counting semaphore). | P2 | +10 |
| `CLAUDE.md` "Failure-mode quick reference" | New row: "Concurrent dispatches not running" → check `_resolve_K` log line, check `CLAUDE_MAX_CONCURRENT` env var, check `orchestrator.max_concurrent_features`. | P5 | +5 |
| `CLAUDE.md` near the existing `max_concurrent_features` documentation surface | Loud upgrade note: "The default of 2 now drives 2 parallel dispatches per tick. To roll back, set `CLAUDE_MAX_CONCURRENT=1` in the launchd plist's `EnvironmentVariables` block." | P4 | +10 |
| `docs/runbooks/operator-mental-model.md` §1 | Update the "earlier-stage issue starves" entry: starvation now applies only when held_count ≥ K, which is the documented WIP cap. | P5 | +5 |
| `docs/runbooks/operator-mental-model.md` (new entry) | "Concurrent slots invisible in Linear" — operators inspect `ls $HARNESS_STATE_DIR/.claude-semaphore/slot-*/pid`. | P5 | +15 |

**Total**: ~700 LOC across 12 files, of which ~500 LOC are tests +
docs. No new vocabulary terms (the existing `outcome` field on
metrics.sh accepts `measured` for `dispatch-resource-sample`). No
new exit codes.

## 6. Data flow

### 6.1 Single-issue tick (K=1, today's behavior preserved by default)

```
T0  scheduler: acquire tick lock; load env; mint GITHUB_TOKEN.
T1  scheduler: K = _resolve_K() → 1 (default until P4)
T2  scheduler: poll.sh --max 1 → single decision JSON object
T3  scheduler: acquire_lock $(issue_dir)/.in-flight.lock → succeeds
T4  scheduler: ensure_worktree
T5  scheduler: release tick lock; cleanup-worktrees if 10th tick
T6  scheduler: fork ONE worker; wait
       worker: tick-start snapshot, log → per-issue file
       worker: acquire claude semaphore slot-1 (capacity 1)
       worker: run-stage.sh
       worker: release slot-1; partition; halt/commit/push
       worker: release in-flight lock; exit
T7  scheduler: trap fires; reap.
```

Identical to today modulo (a) the tick lock is released earlier
(before fork), (b) the worker has its own log file. No observable
behavior change at K=1.

### 6.2 Two-issue tick (K=2, post-Phase-4 default)

```
T0  scheduler: acquire tick lock; load env; mint GITHUB_TOKEN.
T1  scheduler: K = _resolve_K() → 2
T2  scheduler: poll.sh --max 2 → JSON array of 2 decisions
       e.g., [{"issue_id":"ENG-71","stage":"reviewing","entry_action":"run"},
              {"issue_id":"ENG-83","stage":"implementing","entry_action":"run"}]
T3  scheduler: for each decision:
       acquire_lock $(issue_dir ENG-71)/.in-flight.lock → succeeds
       acquire_lock $(issue_dir ENG-83)/.in-flight.lock → succeeds
       ensure_worktree (per-issue, parallel-safe; git worktree add is atomic on the index)
T4  scheduler: release tick lock; cleanup-worktrees if 10th tick
T5  scheduler: fork TWO workers in parallel:
       worker A (ENG-71):                    worker B (ENG-83):
         tick-start snapshot                   tick-start snapshot
         log → local-2026-05-14-ENG-71.log     log → local-2026-05-14-ENG-83.log
         allocate dispatch_id (per-issue)      allocate dispatch_id (per-issue, no contention)
         acquire slot-1 (mkdir succeeds)       acquire slot-2 (mkdir succeeds, slot-1 held)
         claude -p (~10-30 min)                claude -p (~10-30 min, in parallel)
         metrics.sh dispatch-resource-sample   metrics.sh dispatch-resource-sample
                                               (both append to events.jsonl atomically)
         release slot-1                        release slot-2
         partition + halt/commit/push          partition + halt/commit/push
         release in-flight lock                release in-flight lock
         exit                                  exit
T6  scheduler: wait → blocks for both
T7  scheduler: release watcher
T8  scheduler: trap fires; reap tick lock + tempfiles.
```

### 6.3 Contention (K=2, three issues ready, only two slots)

```
T0  poll.sh --max 2 → returns top-2 by sort key; third issue stays
    in the pool but isn't dispatched this tick. It re-emerges on
    the next tick if it's still ready.
```

This matches today's "first-match wins; rest drop" semantics
extended to "top-K wins; rest drop." No new starvation surface.

### 6.4 Worker A halts (self-leak), worker B continues

```
T0  worker A: partition_dirty_paths → self_leak_paths > 0
T1  worker A: halt_issue_for_self_leak ENG-71 → classify_failure
       writes pipeline:halted on ENG-71 ONLY; no global breaker trip.
       worker A's per-issue counter increments.
       worker A: rc=27, exits.
T2  worker B: continues running unaffected.
       Anthropic API call still in flight.
T3  worker B: completes normally; rc=0.
T4  scheduler: wait returns; trap fires.
T5  Next tick: poll sees ENG-71 with pipeline:halted → vacate;
       ENG-83 (or another) progresses. ENG-71 is dormant until
       operator's --action continue.
```

Per-issue isolation (G-2) verified by the existing per-issue counter
+ per-issue worktree primitives. ENG-69's lesson is the
prerequisite that made this scenario benign.

### 6.5 rc=24 on worker A (linear-post-failed) — global breaker still applies

```
T0  worker A: rc=24 (linear-post-failed); route_run_stage_exit
       increments global FAIL_COUNTER.
T1  worker B: completes normally; rc=0; route_run_stage_exit clears
       its OWN per-issue counter only — but does it clear the global?
       (Today: rc=0 path clears both global and per-issue counters
       — `bin/run-local-helpers.sh:394-397`.)
T2  POTENTIAL ANOMALY: worker B's clear races worker A's increment.
       The two operations are not serialized.
```

**Resolution.** In the routing helper at `bin/run-local-helpers.sh:388-430`,
the rc=0 branch unconditionally `rm -f`'s `$FAIL_COUNTER`. Two
parallel workers — one with rc=0 and one with rc=24 — could
interleave such that the rc=24 increment lands AFTER the rc=0
clear, leaving the breaker counter at 1 when the operator's mental
model says "rc=24 fired and the breaker counter is now incremented
to 1, plus the previous (cleared by another worker) value of 0 = 1"
— same outcome by accident. The race is benign for two workers but
deserves a defensive note: the rc=0 clear should remain
unconditional (idempotent), and breaker accounting at K=2 is
"as-if-serialized" only at the rc=24 increment site.

A future K=3 with two rc=24 events on the same tick would actually
benefit from atomic increment (`flock` or `mv -f` of an
incremented temp), but at K=2 the worst-case mis-count is at most
one. Tracked under §9 OQ-3.

## 7. Error handling

### 7.1 Worker subshell crashes (set -e, die, classify_failure exit)

The worker is a subshell `( ... ) &`. Any `exit N` from inside
returns N from the subshell to `wait $pid` in the scheduler. The
scheduler examines per-worker rc only for telemetry; per-issue
state mutations (counter, halt label, comments) are already done
by the worker BEFORE exit (via `route_run_stage_exit`,
`halt_issue_for_self_leak`, `tally_leaked_in_scope_failure`). The
scheduler does not aggregate worker rcs into a tick-level rc;
instead each worker is independent.

Trap order: worker entry replaces the inherited scheduler trap.
The worker's own EXIT trap releases the per-issue in-flight lock
and (if the worker held a semaphore slot at the time of crash) the
semaphore slot is released by `dispatch.sh`'s own `trap
'release_claude_mutex' EXIT` at `:476`. Two-level cleanup, both
trap-driven, both idempotent.

### 7.2 Scheduler crash before fork (poll fails, ensure_worktree dies)

The tick lock is held and the project lock release fires via the
scheduler's `cleanup_on_exit` trap. No workers were started; no
in-flight locks acquired. Same recovery as today.

### 7.3 Scheduler crash AFTER fork, BEFORE wait

Hard to engineer (the `wait` is the next statement after `fork`),
but: workers run to completion (they don't depend on the scheduler
process for anything but the GITHUB_TOKEN env, which they
inherited at fork). Per-issue locks release via worker traps. Tick
lock release via scheduler's cleanup_on_exit trap. Next tick's
scheduler observes no leaked state. No new failure mode.

### 7.4 Worker A's claude semaphore acquire times out (CLAUDE_MUTEX_TIMEOUT=600)

Worker A `die`s after 10 min of waiting. The semaphore times out
ONLY if both slots are held by other host processes — at K=2 with
this scheduler, that means another launchd fire's workers (e.g.,
two ticks overlap because tick N's workers ran >5 min). The tick
lock prevents tick N+1's scheduler from running while tick N's
scheduler is alive — but tick N's workers may outlive the
scheduler (`wait` blocks the scheduler, then the trap releases the
tick lock). So tick N+1 can fire while tick N's workers are still
holding semaphore slots. **Deliberate** — that's the K=2 contract:
up to K dispatches concurrently, regardless of which tick spawned
them.

If wait+timeout still trips (e.g., a wedged claude process holding
a slot for >10 min beyond the gtimeout's wall budget — gtimeout is
30 or 60 min), the semaphore acquire dies loud. Operator inspects
`$HARNESS_STATE_DIR/.claude-semaphore/slot-*/pid` to find the
holder.

### 7.5 Per-issue lock contention at scheduler

If `acquire_lock $(issue_dir issue)/.in-flight.lock 0` returns 1
(another worker still owns it from a prior tick that hasn't
finished), the scheduler logs and SKIPS this decision. The next
tick's poll likely picks a different decision; if it picks the
same issue and the lock is still held, it skips again. No
infinite loop, no halt: the issue is effectively "in flight" until
its prior worker finishes.

This is the post-split equivalent of today's tick-lock-held skip.

### 7.6 Worker A's gtimeout fires (wall-clock budget exceeded)

Existing behavior: `claude -p` receives SIGTERM, exits 124,
`route_run_stage_exit` accumulates against the per-issue counter.
The worker's semaphore slot releases via dispatch.sh's EXIT trap.
Worker B unaffected. No new failure mode.

### 7.7 `events.jsonl` concurrent-write atomicity

`bin/metrics.sh:67-74` is a single `jq -cn '...' >> file`. Bash's
`>>` opens with `O_APPEND`; jq writes the JSON line via stdio in
one or two flushes. POSIX guarantees writes ≤ `PIPE_BUF` (4 KB on
macOS) are atomic against concurrent `O_APPEND` writers.

A typical metrics line is 8 base fields (`ts`, `event`, `issue_id`,
`stage`, `outcome`, `duration_ms`, `notes`, plus 0-6 cost fields)
~250-500 bytes. Well under the 4 KB ceiling. The atomicity test
in §5.7 confirms this empirically by writing a wide notes payload
in one worker concurrently with another and asserting `jq -c .`
parses every line.

### 7.8 `dispatch_history.jsonl` concurrent writes

Same primitive (`>>`), same issue, same atomicity — but each
worker writes to its OWN `$(issue_dir <issue>)/dispatch_history.jsonl`
(per-issue file). No cross-worker concurrent access on this file.

## 8. Edge cases

### E-1. Tick N's workers outlive tick N+1's launchd fire

Today this can't happen (tick lock prevents tick N+1). Post-split,
tick N+1 can fire while tick N's workers run. **Deliberate** —
that's the parallelism. Tick N+1's scheduler's poll may see the
in-flight issues with `stage:*` labels already (they haven't
completed); they're held but already locked by tick N's worker;
tick N+1's `acquire_lock $(issue_dir)/.in-flight.lock 0` returns 1,
scheduler skips, falls through to next decision.

This is the per-issue lock's load-bearing case. Without it, tick
N+1 would re-dispatch an in-flight issue.

### E-2. K=2, only 1 advanceable issue this tick

`poll.sh --max 2` returns a 1-element array. Scheduler forks 1
worker. Same as today. Confirms the rename-in-place doesn't break
the underutilized case.

### E-3. K=2, one of the two decisions is `inbox` (entry_action=apply-stage-label)

Scheduler runs the `apply-stage-label` side effect for the inbox
decision in the SCHEDULER (today's behavior, `bin/run-local.sh:160-171`),
THEN forks the worker for that issue's brainstorm dispatch. Same
side effects, same order, just done inside a per-decision loop.

### E-4. K=2, one of the two decisions is brainstorming/planning that needs reconcile

`reconcile.sh` is run in the SCHEDULER per existing `bin/run-local.sh:174-176`.
If reconcile yields `link:` or `human`, the scheduler short-circuits
THAT decision (logs, posts Linear comment, releases per-issue
in-flight lock) and continues to the next. The other decision still
proceeds to the worker fork.

### E-5. Concurrent `gh release list` in scheduler

Release watcher runs in the SCHEDULER post-`wait` (today's location
preserved at `bin/run-local.sh:413-436`). Single call, no concurrency.

### E-6. Two workers both want to commit to origin (same branch? different branches.)

Each worker's branch is distinct (per-issue worktree, per-issue
branch via `bin/branch-name.sh`). `git push -u origin HEAD` from
two workers targets two different remote refs; no contention.

### E-7. Two workers both halt simultaneously with rc=24 (linear-post-failed)

Both increment global `FAIL_COUNTER` non-atomically. Worst-case
under-count of 1 (two increments race; one read-modify-write loses).
Acceptable at K=2: the breaker still trips at threshold ≥3, just
takes one extra tick to get there. §9 OQ-3 captures the K=3+
implication.

### E-8. Worker A reads worker B's `usage-<stage>.json` accidentally

Cannot happen: `usage-<stage>.json` lives at
`$(issue_dir <issue>)/usage-<stage>.json`, and `<issue>` differs
between workers. Per-issue isolation.

### E-9. `cleanup-worktrees.sh` runs concurrently with a worker

Cleanup runs in the SCHEDULER arm BEFORE fork (P3d). Workers are
not yet alive when cleanup runs. The cleanup script targets
worktrees whose branches are no longer extant; in-flight workers'
worktrees have a corresponding non-deleted branch by construction
(the worker's `git push -u origin HEAD` just created it, or an
earlier dispatch did). Cleanup-of-concurrent-worktree race:
impossible.

### E-10. K=2 with `_picker_build_pool` returning helds + waits + inbox totalling >K

Pool is sorted; we slice the top K. The cap respects the existing
WIP semantics of `held_count < max_concurrent` — if K already-held
items beat all wait_recallable + inbox arrivals on the sort key,
inbox waits its turn. Same scope-control surface as today.

### E-11. Two workers A and B both want to dispatch the SAME (issue, stage)

Cannot happen: `_picker_build_pool`'s sort by `.identifier`
deduplicates implicitly, and `_poll_gather_stage_labeled_issues`
already calls `unique_by(.identifier)` at `bin/poll.sh:167`. The
per-issue in-flight lock is the second line of defense.

### E-12. `CLAUDE_MAX_CONCURRENT=0` (operator typos a 0 thinking it disables)

`_resolve_K` rejects `< 1` and falls through to next layer with a
`log` warning. Mirrors ENG-65 timeout-validation pattern. The
operator's intent ("disable parallel dispatch") is achieved by
`CLAUDE_MAX_CONCURRENT=1` (revert to today's behavior); 0 is
nonsensical because 0 dispatches/tick ≠ "parallel disabled" — it's
"orchestrator effectively paused", which is what
`orchestrator.paused=true` is for.

### E-13. Pre-commit hook contention

The pre-commit hook runs `.githooks/pre-commit` in operator
context, not in any worker. Workers never run the pre-commit hook
(they're not making operator-side commits). No new failure mode.

### E-14. `set -euo pipefail` and `wait`

`set -e` doesn't kill the shell on a background command's failure
that's reaped via `wait`. `wait $pid` returns the child's exit
code; the scheduler MUST inspect or `|| true` it to avoid `set -e`
killing the scheduler. Standard idiom: wrap `wait` in `set +e; …;
set -e` block (small precision is fine).

## 9. Open questions

### OQ-1: Does the Anthropic subscription have a concurrent-session ceiling?

Unknown empirically. The brainstorm assumes "I/O-bound on the API,
not on local resources" — true for CPU/RSS, but the ceiling on
concurrent sessions per subscription is not documented in the
material at hand. Phase 5 watch-week is the empirical answer; if a
ceiling exists and we hit it at K=2, the Anthropic side returns
some error (likely 429 or session-rejected); `claude -p` would
exit non-zero; `route_run_stage_exit` accumulates into the
per-issue counter. The retrospective would observe a clustered
failure pattern and the rollback envar is the immediate response.

**Resolution:** soft — empirical, watch-week answers it. **Risk
mitigation:** `CLAUDE_MAX_CONCURRENT=1` env-var rollback.

### OQ-2: Should the scheduler hold the project tick lock AT ALL post-fork?

The current design releases the tick lock before fork. This means
two ticks' worth of workers can be alive simultaneously (tick N's
workers running, tick N+1's scheduler running). The per-issue
in-flight lock prevents same-issue double-dispatch; the counting
semaphore caps total in-flight at K. So holding the tick lock
post-fork is strictly redundant.

**Resolution:** release before fork (the design choice in §4.4).

### OQ-3: At K≥3, atomic global FAIL_COUNTER increments?

§7.7 / E-7 noted that two simultaneous rc=24 increments can race
and under-count by 1. At K=2 worst-case mis-count is 1; at K=3,
2; at K=4, 3. The breaker still trips eventually (each subsequent
tick adds another increment). For K≥3 we should add `flock`-based
atomic increment to the global counter. **Defer to a follow-up
ticket** that goes with the K=3 decision — out of scope for K=2.

### OQ-4: Do the test fixtures need a real `gtime` binary, or can they stub it?

`gtime` is an external Homebrew binary; tests run on macOS with
Homebrew installed. The `dispatch-test.sh` fixture should stub
`gtime` (PATH-prefix stub via `STUB_DIR/gtime`) emitting a fixed
`-v` output to stderr, so the test asserts metric emission without
depending on `gtime`'s presence on every dev's host. Pattern
mirrors how other tests stub `claude` (PIPELINE_DRY_RUN bypass) and
`linear.sh` (STUB_DIR shim).

**Resolution:** stub. Codified in §5.7's `dispatch-test.sh` row.

### OQ-5: Does the per-worker log file approach change `status.sh`'s log-aggregation surface?

`bin/status.sh:8` says it aggregates four sources, and per its
comment "this is the canonical events.jsonl stream". The daily log
file is NOT one of those four sources today. Per-worker log split
has no consumer change for `status.sh`.

**Resolution:** no change needed. Verified by re-reading
`bin/status.sh` lines 1-50.

### OQ-6: Should the `_resolve_K` helper be in `common.sh` or `run-local.sh`?

Three callers eventually want K: (a) `run-local.sh` scheduler, (b)
`poll.sh --max` CLI parsing (could call `_resolve_K` itself
instead of taking K from caller), (c) `dispatch.sh::acquire_claude_mutex`'s
slot-loop. Today `dispatch.sh` only needs the upper bound (K) when
contending; `poll.sh` only needs K as a CLI arg. Putting
`_resolve_K` in `common.sh` makes it reusable; in `run-local.sh`
keeps the surface area smaller.

**Resolution:** `common.sh` (one-line export); preserves
testability and avoids duplicate impls.

### OQ-7: Should brainstorm/planning stages get K=1 implicit cap?

Brainstorm/plan iterate persona-review and can run >30 min each
(ENG-65). Two parallel brainstorms double the wall-clock-spend
risk if both go long. Counterargument: brainstorm is the intake
queue; throttling it to K=1 just shifts the queue depth elsewhere.

**Resolution:** no per-stage cap. K=2 applies uniformly. The
gtimeout per-stage budget (ENG-65) bounds worst-case wall-clock per
agent; K=2 just means two of those budgets can fire concurrently.

### OQ-8: What if `poll.sh --max 2` returns 0 decisions?

Same as today's "no work this tick" branch. Scheduler logs, no
fork, exits via trap. No anomaly.

### OQ-9: Operator wants to suspend a single project's parallelism without affecting others

`CLAUDE_MAX_CONCURRENT=1` is a host-wide env (set in launchd
plist). Per-project rollback is via that project's
`orchestrator.max_concurrent_features=1` in the target repo's
`config.json`. Documented in the upgrade note (§5.8).

**Resolution:** env var is host-wide; config is per-project. Both
documented.

## 10. Scope flagging

### 10.1 Items inside Linear-issue scope (no flag)

All five phases as enumerated in the issue body. Each phase maps
to specific decisions / components above.

### 10.2 Items the brainstorm DEFERS that the issue mentions

- **Cross-project semaphore tuning.** Issue body explicitly lists
  this in "Out of scope"; brainstorm preserves that boundary.
  See §2 non-goals + §9 OQ-9.
- **Dynamic K.** Same — issue calls it out as out of scope.

### 10.3 Items the brainstorm ADDS beyond the issue body

| Item | Why added | Could be deferred? |
|---|---|---|
| **Per-issue in-flight lock at `$(issue_dir)/.in-flight.lock`** | Issue body mentions per-issue lock at §3b but doesn't explicitly list it as a separate component. The brainstorm makes it a load-bearing primitive (D-002, §5.3). | No — required for E-1 (tick overlap). |
| **OQ-3 (K≥3 atomic FAIL_COUNTER)** | Issue body doesn't acknowledge the race. The brainstorm flags it explicitly so a future K=3 ticket isn't surprised. Action: defer fix to that ticket. | Yes (already deferred). |
| **`_resolve_K` in `common.sh`** | Issue body proposes scattered config reads; brainstorm centralizes for testability. | Yes — could inline in `run-local.sh` if reviewer prefers (1 caller until P4). |
| **Stub `gtime` in `dispatch-test.sh`** | Issue body just says "test fixtures need a stub"; brainstorm specifies the pattern. | No — required for P1 acceptance. |

### 10.4 Items the brainstorm MIGHT cut to reduce risk

- **Phase 1 (instrumentation) could be deferred to post-rollout.**
  But then Phase 5 watch-week has no quantitative baseline. Keep.
- **Per-worker log file (P3c) could stay shared with line-buffered
  tee.** Bash-level line-buffered tee is unreliable across processes;
  per-worker file is the simplest correct design. Keep.

## 11. Conflicts with existing architecture

**No hard conflict.** The ticket extends layered primitives that
are already designed for per-issue isolation:

- **ENG-67 worktrees are per-issue.** Two parallel workers reach
  for two different worktrees. ✓
- **ENG-69 counters are per-issue.** Two parallel workers tally
  independently. ✓ (one global-counter race noted, §7.7 / OQ-3.)
- **ENG-87 dispatch_id is per-issue, allocated under a per-issue
  mkdir lock.** Two parallel workers allocate independently. ✓
- **ENG-90/91 picker is sorted and ranked per-tick.** Extends to
  top-K naturally. ✓
- **ENG-65 timeouts are per-(stage, dispatch) and run inside
  `gtimeout`.** Per-process; no host-wide shared budget. ✓

**One soft tension.** The existing `bin/run-local.sh` is a flat
script; the scheduler/worker split moves substantial logic into
two new code paths inside `main`. The diff is large (~200 LOC, see
§5.4) but structurally additive — no helper signature changes.
Reviewer should expect a P3 PR substantially larger than the other
phases combined.

## 12. Phasing summary (re-stated for clarity)

| Phase | Adds | Behavior change at default config | Risk | Wall-clock |
|---|---|---|---|---|
| P1 | `gtime` wrapper + `dispatch-resource-sample` metric | None | Low (pure observability) | 0.5 day |
| P2 | Counting semaphore at capacity 1 | None | Low (mechanical refactor + tests) | 0.5 day |
| P3 | Scheduler/worker split, per-issue in-flight lock, per-worker log, `poll.sh --max K` | None at K=1 default | Medium-high (lifecycle inversion + test churn) | 3-5 days impl, 1-2 days tests |
| P4 | `_resolve_K` plumbed; default flips to 2 | **Existing operator configs at default 2 start producing 2× per-tick dispatches** | Moderate (real concurrency exposure) | 1 day + upgrade-note PR |
| P5 | Watch-week, status.sh row, docs | None (observability + docs) | Moderate (first contact with real Anthropic API concurrency) | 1 calendar week |

Total impl: ~6-9 dev days + 1 watch-week. The scheduler/worker
split (P3) is the load-bearing chunk; everything else is bracketing.

## 13. Persona review

Run on this brainstorm in the order: **design → security → scope →
coherence → product → feasibility**. Verdicts and findings inline.

### 13.1 Design — PASS

- The contract is small and named: K, counting semaphore, per-issue
  in-flight lock, scheduler/worker split.
- Each layer reuses an existing primitive (mkdir-lock, `acquire_lock`
  helper, `partition_dirty_paths`); no new abstractions invented.
- Layered phasing maps cleanly to risk: instrumentation → mechanical
  refactor → structural change → semantic flip → watch.
- One design note: §7.7 / E-7 explicitly acknowledges the
  global-counter race and bounds it to "worst-case under-count of 1
  at K=2" with a deferred fix for K≥3. This is the correct level of
  rigour for a structural change at this scale.

**No P0. No P1.**

### 13.2 Security — PASS

- No new secret-handling surface. `GITHUB_TOKEN` mint stays in
  scheduler; `LINEAR_API_KEY` stays sourced from secrets.env (`bin/run-local.sh:91-93`).
  Workers inherit env naturally — no key materialization in argv,
  no `${VAR:-FALLBACK}` patterns in new code (compliant with
  ENG-46 / `bin/secret-probe-lint.sh`).
- Per-issue lock files contain only PIDs (numeric integers); no
  secret leakage on `ls` or in audit logs.
- The semaphore directory at `$HARNESS_STATE_DIR/.claude-semaphore`
  is created with default umask (0755-ish); `slot-<N>/pid` files
  contain the parent's pid (also numeric). No secret material.
- `dispatch_history.jsonl` writes are per-issue (no cross-worker
  read access); ENG-87's existing fields shape is preserved.
- New `dispatch-resource-sample` metric event carries
  `wall_seconds`, `max_rss_kb`, `cpu_pct` — pure numeric telemetry,
  no secret-adjacent data.
- The per-worker log file path follows the existing daily-log
  pattern (`local-YYYY-MM-DD-<issue>.log`); no path-injection
  surface (`<issue>` is constrained by `^ENG-[0-9]+$` validation in
  the helpers).

**No P0. No P1.**

### 13.3 Scope — PASS

- The brainstorm sticks to the issue's five phases. Out-of-scope
  items (cross-project, dynamic K) are deferred consistently in §2,
  §9, and §10.
- Three additions over the issue body (per-issue in-flight lock,
  OQ-3 K≥3 race, `_resolve_K` centralization) are flagged in §10.3
  and justified.
- The post-stage sweep allowlist is unchanged. The brainstorm doc
  itself is in `docs/brainstorms/` (matches CLAUDE.md
  "Doc-to-issue ownership is YAML frontmatter, not prose"); the
  `eng-81` token is in the basename per D-004 partitioning.

**No P0. No P1.**

### 13.4 Coherence — PASS

- The brainstorm aligns with prior brainstorms in this repo: same
  YAML frontmatter shape, same Decisions / Architecture / Data flow
  sections, same failure-mode-quick-reference cross-link convention.
- Cross-references to ENG-67, ENG-69, ENG-87, ENG-90, ENG-91, ENG-65,
  ENG-86 are all citation-accurate (§3.1).
- The §1 "load-bearing surprise" framing matches ENG-90's framing
  for naming silently-load-bearing semantics; the §3.1 ADR-stress
  table matches the recent `eng-95`/`eng-96` brainstorm style.

**No P0. No P1.**

### 13.5 Product — PASS

- The user-visible promise is "two issues progress on the same
  5-min tick" — matches the issue's stated goal verbatim.
- The default change in P4 is loud: the operator's mental model of
  `max_concurrent_features=2` becomes "2 parallel dispatches per
  tick" rather than "2-WIP cap with 1 dispatch per tick". The
  upgrade note in §5.8 carries the burden.
- The rollback path (`CLAUDE_MAX_CONCURRENT=1`) is documented in
  the same place. No "operator must edit JSON mid-incident" gotcha.
- Status.sh visibility ("concurrent dispatches active right now")
  closes the operator-question "is the parallelism actually working?"
  — would be invisible without it.

**No P0. No P1.**

### 13.6 Feasibility — PASS, zero P0

This is the gating persona — codebase-fact errors are P0 by
contract. Every named identifier in §3.3 was checked against the
current checkout with `path:line` references.

- **Verified files / functions exist with the claimed signatures:**
  `bin/dispatch.sh::acquire_claude_mutex` (`:23-36`),
  `bin/dispatch.sh::release_claude_mutex` (`:38-40`),
  `bin/dispatch.sh::main`'s env block (`:555-557`),
  `bin/dispatch.sh::_render_and_capture_stream`'s `usage-<stage>.json`
  write (`:117-125`),
  `bin/run-local.sh:37,51` (project tick lock),
  `bin/run-local.sh:42` (`CLEANUP_EVERY_N_TICKS=10`),
  `bin/run-local.sh:101-102` (GITHUB_TOKEN mint + export),
  `bin/run-local.sh:251` (tick-start snapshot vs `$dispatch_cwd`),
  `bin/run-local-helpers.sh:128-154` (`halt_issue_for_self_leak`),
  `bin/run-local-helpers.sh:388-430` (`route_run_stage_exit`
  per-issue/global lane split),
  `bin/poll.sh:459-527` (`_picker_build_pool` returns a sorted
  array; sort key documented at `:526`),
  `bin/poll.sh:626-630` (`max_concurrent` defensive default to 2),
  `bin/poll.sh:698, 708, 716` (the three `exit 0` arms),
  `bin/setup.sh:530-531` (default `max_concurrent_features=2`),
  `bin/common.sh:104-121` (`allocate_dispatch_id` per-issue mkdir
  lock at `$(issue_dir)/.allocate.lock`),
  `bin/common.sh:395-403` (`acquire_lock` helper, mkdir-based,
  optional timeout),
  `bin/common.sh:68-72` (`issue_dir`),
  `bin/metrics.sh:53-74` (single jq line via `>>`),
  `bin/run-stage.sh:975-977` (`main` takes `<issue> <stage>`).
- **One assumption left "assumed":** `gtime` (GNU coreutils) on
  Homebrew. The brainstorm's mitigation is a `require_bin gtime`
  guard with degraded mode (skip metric, log warning) so absence
  doesn't break dispatch. Acceptable.
- **No referenced item proven absent.**

**No P0.**

---

### Persona-review summary

| Persona | Verdict | P0 | Notes |
|---|---|---|---|
| Design | PASS | 0 | Layered + reuses existing primitives. |
| Security | PASS | 0 | No new secret surface; PID-only lock files. |
| Scope | PASS | 0 | Three additions over issue body, all flagged. |
| Coherence | PASS | 0 | Matches recent brainstorm style + cross-refs. |
| Product | PASS | 0 | Loud upgrade note + rollback documented. |
| Feasibility | PASS | 0 | Every cited `path:line` verified against current code. |

**Gate:** 6/6 PASS, feasibility P0 = 0 → proceed to planning.
