# Failure modes

This is the comprehensive symptom catalog. For the high-level summary,
see the [Failure modes section](../../README.md#failure-modes-and-runbooks).

For mental-model gaps that don't map to a clean symptom, see
[`operator-mental-model.md`](operator-mental-model.md). For the
ENG-41-specific trust-model recovery procedures, see
[`recovery.md`](recovery.md).

## How to read this catalog

Each entry has:

- **Symptom** — what you observe in Linear, in `bin/status.sh` output, or in the logs.
- **Diagnose** — what to check, in order, to confirm the cause.
- **Recover** — what to do.
- **Root cause** — why it happens (so you can prevent it).
- **Related** — ENG ticket(s) where this was first investigated.

When recovering, default to `bash bin/pipeline.sh decide ENG-N --action continue`
unless the recovery section says otherwise. It is atomic, idempotent,
and clears six pieces of state in one operation.

---

## Tick is silent

### Symptom

`launchctl list | grep com.twinning.pipeline` shows `0 PID` (or PID
keeps changing every 5 minutes), but no Linear comments, no log writes,
no metric events. `bash bin/status.sh` shows nothing changing.

### Diagnose

```bash
# Is launchd actually firing the agent?
launchctl print "gui/$(id -u)/com.twinning.pipeline.<slug>" | grep -E 'state|last exit code'

# Is the wrapper getting in?
tail -50 "$PROJECT_STATE_DIR/logs/local-$(date -u +%Y-%m-%d).log"

# Is it dying before logging?
tail -50 "$PROJECT_STATE_DIR/logs/launchd.err.log"

# Is the orchestrator paused?
jq -r '.orchestrator.paused' "$TARGET_REPO/.pipeline-config/state.local.json" 2>/dev/null
jq -r '.orchestrator.paused' "$TARGET_REPO/.pipeline-config/config.json"
```

### Recover

By cause:
- **`paused=true`** → `bash bin/pipeline.sh decide <any-halted-issue> --action continue`
  (clears the breaker globally), OR `jq '.orchestrator.paused = false'`
  on `state.local.json`.
- **launchd not firing** → `bash bin/uninstall-launchd.sh /path && bash bin/install-launchd.sh /path`.
- **Wrapper dying before logging** → check `launchd.err.log`. Common causes:
  `gtimeout` not on PATH (install `coreutils`), `claude` session expired
  (re-run `claude login`), `gh` not authenticated.

### Root cause

`bin/run-local.sh` exits silently when `orchestrator.paused == true`.
Other silent-exit paths: lock contention (another tick still running —
investigate `$PROJECT_STATE_DIR/.run-local.lock/` age), missing
prerequisite tools (the script dies before logger initialization).

### Related

ENG-15 (per-issue state dir established the logging contract), ENG-23
(env var refactor that made silent failures less likely).

---

## Per-issue halt

### Symptom

Linear issue carries `pipeline:halted` label. Latest comment is
`<!-- pipeline: verdict result=halt reason=... -->`. Issue stops
advancing.

### Diagnose

```bash
# What halted it?
bash bin/pipeline.sh status ENG-N | tail -5

# What does the halt comment say?
# (Look at the most recent comment in Linear — body has the reason.)

# What does on-disk state say?
cat "$(bash bin/pipeline.sh issue-dir ENG-N)/issue-state.json"
```

The `reason` token tells you which class of halt:

| Reason | Class |
|---|---|
| `agent-blocked` | Agent declared halt (most common; check the agent's narrative) |
| `scope-violation` | scope-check rejected dirty paths |
| `protocol-violation` | Marker / wait shape was invalid |
| `dispatch-timeout` | gtimeout fired SIGTERM |
| `iteration-exhausted` | Brainstorm hit the 2-iteration cap (ENG-65) |
| `pr-opened-too-early` | Implement agent created a PR (forbidden) |
| `smoke-failed` | Build agent's smoke checks failed |

### Recover

Universal:

```bash
bash bin/pipeline.sh decide ENG-N --action continue
```

Stage-specific alternatives:

- For `scope-violation` when the touches are intentional:
  ```bash
  bash bin/pipeline.sh decide ENG-N --action approve --gate scope
  ```
- For `iteration-exhausted` (brainstorm) — read the partial brainstorm
  doc at `$PROJECT_STATE_DIR/<ident>/worktree/docs/brainstorms/`,
  decide whether the underlying issue blocks proceeding, then either
  `--action continue` (re-dispatch with same spec) or rewrite the spec
  in Linear and `--action continue` (re-dispatch picks up new context).

### Root cause

The orchestrator emits `pipeline:halted` when a stage fails in a way
the harness cannot recover from automatically. By design, this requires
operator attention rather than blind retry.

### Related

ENG-15 (issue-state.json schema), ENG-58 (decide --action continue
atomicity), ENG-65 (brainstorm iteration cap), ENG-69 (per-issue
counter).

---

## Global breaker tripped

### Symptom

Multiple issues stop advancing simultaneously. `bash bin/status.sh`
shows `paused=true`. `$PROJECT_STATE_DIR/.consecutive-failures` exists
and contains a number ≥ 3.

### Diagnose

```bash
cat "$PROJECT_STATE_DIR/.consecutive-failures"
jq -r '.orchestrator.paused' "$TARGET_REPO/.pipeline-config/state.local.json"

# What kind of failures?
tail -100 "$PROJECT_STATE_DIR/logs/local-$(date -u +%Y-%m-%d).log" | grep -E 'rc=|failure='
```

Three consecutive `rc=24` (`linear-post-failed`) ticks trip it —
typically a Linear API outage, expired API key, or network problem.

### Recover

```bash
# Atomic: also clears any halted issue
bash bin/pipeline.sh decide ENG-N --action continue

# OR manual:
rm "$PROJECT_STATE_DIR/.consecutive-failures"
jq '.orchestrator.paused = false' state.local.json | sponge state.local.json
```

If the underlying cause is a bad `LINEAR_API_KEY`, fix the key first:

```bash
bash bin/setup.sh /path/to/target linear-auth
```

### Root cause

The breaker is intentionally aggressive — three consecutive
infrastructure failures stops the orchestrator before it can spam
Linear with retry comments or burn through subscription compute on a
broken pipeline.

### Related

ENG-15 (counter contract).

---

## Issue stuck in `stage:X`

### Symptom

Linear issue has a `stage:X` label and hasn't advanced for hours.
`bin/status.sh` doesn't show it as halted, but it's not picked up by
the poller either.

### Diagnose

```bash
# Is there a stuck wait?
ls "$(bash bin/pipeline.sh issue-dir ENG-N)/wait-*.json" 2>/dev/null

# Is the agent waiting on an external signal?
cat "$(bash bin/pipeline.sh issue-dir ENG-N)/wait-building.json" 2>/dev/null

# What sigs exist for this issue in Linear?
# (Search the comment thread for halt/<stage>/<issue> or scope-approval/<stage>/<issue>.)
```

The most recent re-apply moment is in the `<!-- meta: reapplied at=… -->`
footer, NOT the comment's visible `createdAt` (which reflects FIRST
emission only — see [`operator-mental-model.md`](operator-mental-model.md#sig-dedup)).

### Recover

By cause:
- **Build P2 awaiting human approval** → click Approve on the PR.
- **Wait budget exhausted** → `bash bin/pipeline.sh decide ENG-N --action continue`.
- **Scope-approval pending and forgotten** → either approve
  (`--action approve --gate scope`) or continue (`--action continue`).
- **Multiple `stage:*` labels** (rare, indicates a label-write race) →
  see [`recovery.md`](recovery.md#1-issue-with-multiple-stage-labels).

### Root cause

Most "stuck in stage" cases are the harness waiting correctly for an
external signal. A few are real bugs (label race conditions during
trust-model violations).

### Related

ENG-41 (trust-model fix), ENG-45 (external_signal_budget).

---

## Wrong-target Linear writes

### Symptom

The harness writes a comment or applies a label on an issue you didn't
expect — possibly on a project you didn't intend the harness to touch.

### Diagnose

```bash
# Is the cache stale?
cd "$TARGET_REPO"
git log -- .pipeline-config/schemas/linear-ids.json

# Is the cache pointing at the right project?
jq -r '.project_id' "$TARGET_REPO/.pipeline-config/schemas/linear-ids.json"
jq -r '.linear.project_id' "$TARGET_REPO/.pipeline-config/config.json"
```

If the cache and config disagree, the cache wins (the harness uses cache
IDs directly; config IDs are only used to validate the cache on
refresh).

### Recover

```bash
# Refresh the cache from Linear
LINEAR_API_KEY=… bash bin/linear.sh refresh-cache

# Verify
jq -r '.project_id' "$TARGET_REPO/.pipeline-config/schemas/linear-ids.json"

# If still wrong, edit config.json to point at the right project
# and re-run setup
bash bin/setup.sh /path linear-identity
```

### Root cause

`linear-ids.json` caches Linear's UUIDs for state, label, and project
references. If the cache was generated against a different Linear
project (e.g., during a setup phase against a sandbox project, then
re-pointed at production without refreshing), every Linear write goes
to the cached UUIDs.

### Related

The `linear-ids.json` cache contract is documented inline in
`bin/linear.sh::refresh-cache`.

---

## Build idles with `dispatch-skipped` events

### Symptom

Issue at `stage:building`. No `verdict` markers, but `events.jsonl`
shows repeated `dispatch-skipped` outcomes. Linear is silent.

### Diagnose

```bash
# How many skip ticks have fired?
jq -r 'select(.issue=="ENG-N" and .event=="stage-end" and .outcome=="dispatch-skipped") | .ts' \
  "$PROJECT_STATE_DIR/metrics/events.jsonl" | wc -l

# What does the wait file say?
cat "$(bash bin/pipeline.sh issue-dir ENG-N)/wait-building.json"

# Is the PR actually approved?
gh pr view <pr-number> --json reviews --jq '.reviews[] | {author: .author.login, state: .state}'

# Is gh on PATH for launchd?
launchctl print "gui/$(id -u)/com.twinning.pipeline.<slug>" | grep -i path
```

### Recover

By cause:
- **PR not approved by non-bot Code Owner** → human Code Owner approves.
- **PR has CHANGES_REQUESTED** → resolve the change requests first.
- **`gh` not on launchd's PATH** → ensure `gh` is in
  `/usr/local/bin/`, `/opt/homebrew/bin/`, or update the plist's
  `EnvironmentVariables.PATH`.

If the predicate is buggy and the issue should proceed regardless:

```bash
bash bin/pipeline.sh decide ENG-N --action approve --gate build-cap
```

### Root cause

The ENG-86 entry-conditions gate (per-stage pre-dispatch check) skips
the build agent dispatch when no non-bot Code Owner has approved the
PR. Saves ~$0.50/tick that the agent would burn on its P2 preflight,
but means a missing approval = silent backoff in Linear (the metric
events are the signal).

### Related

ENG-86 (entry-conditions gate), ENG-45 (external_signal_budget that
eventually escalates to halt-for-human).

---

## Brainstorm halts at `iteration-exhausted`

### Symptom

A new issue's brainstorm stage halts after two persona-review
iterations. Halt comment reason: `iteration-exhausted`. Partial
brainstorm doc exists in the worktree but has unresolved P0 findings.

### Diagnose

```bash
# Read the partial brainstorm
cat "$(bash bin/pipeline.sh issue-dir ENG-N)/worktree/docs/brainstorms/"*.md

# What did the personas flag?
# (The doc has a "P0 findings" section near the bottom; the halt comment
#  in Linear summarizes which gates the doc failed.)
```

### Recover

Two paths depending on whether the P0 is resolvable from the spec:

**Resolvable from spec** (the spec was vague enough that personas can't
agree on scope):

1. Edit the Linear issue body to clarify scope / acceptance criteria.
2. `bash bin/pipeline.sh decide ENG-N --action continue` — re-dispatch
   reads the new spec.

**Not resolvable, scope was wrong**:

1. Manually edit or rewrite the brainstorm doc in the worktree.
2. `bash bin/pipeline.sh decide ENG-N --action continue` — re-dispatch
   sees the operator-edited doc and treats it as canonical via
   reconcile.

### Root cause

ENG-65 introduced a 2-iteration cap on persona-review to bound
worst-case spend. Without the cap, a bad spec could loop indefinitely
at $4–$8 per iteration.

### Related

ENG-65 (per-stage timeouts + iteration cap).

---

## Concurrent dispatches not running (expected K=2, observed K=1)

### Symptom

`bash bin/status.sh` shows fewer concurrent dispatches than the cap
you configured — e.g. only 1 `slot-*/pid` directory under
`$HARNESS_STATE_DIR/.claude-semaphore/` despite
`orchestrator.max_concurrent_features=2`. Per-tick dispatch volume
is half what you'd expect.

### Diagnose

```bash
# 1. What did _resolve_K resolve to on the most recent tick?
grep 'scheduler: K=' \
  "$PROJECT_STATE_DIR/logs/local-$(date -u +%Y-%m-%d).log" \
  | tail -3

# 2. Is CLAUDE_MAX_CONCURRENT set in the launchd plist? (env wins over config)
launchctl print "gui/$(id -u)/com.twinning.pipeline.<slug>" \
  | grep -i CLAUDE_MAX_CONCURRENT

# 3. What does config say?
jq '.orchestrator.max_concurrent_features' \
  "$TARGET_REPO/.pipeline-config/config.json"

# 4. Are there live slots right now?
ls "$HARNESS_STATE_DIR/.claude-semaphore/"slot-*/pid 2>/dev/null
```

Cross-check `bin/common.sh::_resolve_K`'s precedence (env >
config > built-in 2) against what you read above; a
`_resolve_K: invalid …` line in the same log file flags any
non-integer or `<1` value that fell through.

**Rule out first — eligible-issue pool smaller than the cap.** Not a
bug. The scheduler only dispatches issues whose `slot:hold,
advanceable:true` classification fires; when fewer issues are
advanceable than the cap allows, observed concurrency is the smaller
of the two. Confirm via `bash bin/status.sh` (Pipeline state +
slot-occupancy rows) before treating the symptom as a misconfiguration.

### Recover

By cause:

- **`CLAUDE_MAX_CONCURRENT` unintentionally `1`** → edit the launchd
  plist's `EnvironmentVariables` block (or `launchctl unsetenv`),
  then `launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/com.twinning.pipeline.<slug>.plist`.
- **Config explicitly `1`** → `jq '.orchestrator.max_concurrent_features = 2' "$TARGET_REPO/.pipeline-config/config.json" > /tmp/c && mv /tmp/c "$TARGET_REPO/.pipeline-config/config.json"`.
- **Non-integer / `<1` resolved value silently fell through** → fix
  the offending value at whichever tier emitted the
  `_resolve_K: invalid …` warning (env or config).

### Root cause

`bin/common.sh::_resolve_K` resolves the cap with env > config >
built-in precedence and is fail-soft on invalid values (logs a
warning and falls through). Operators upgrading from pre-ENG-81 may
leave a stale `CLAUDE_MAX_CONCURRENT=1` in the plist from a prior
rollback; non-integer values get silently dropped.

### Related

ENG-81 (per-project parallel dispatch + counting semaphore),
ENG-90 (slot-occupancy contract). See `CLAUDE.md` §"Per-project
dispatch concurrency" for the full resolution-precedence model.

---

## Issue stuck at one stage; `.in-flight.lock` present

### Symptom

An issue with a `stage:*` label hasn't advanced for one or more
ticks. `bin/status.sh` shows it as held but no dispatch fires. A
directory `$(bash bin/pipeline.sh issue-dir ENG-N)/.in-flight.lock/`
exists with `pid` and `timestamp` files inside.

### Diagnose

```bash
issue_dir="$(bash bin/pipeline.sh issue-dir ENG-N)"

# 1. Confirm the lock dir is present
ls "$issue_dir/.in-flight.lock"

# 2. Inspect the holder pid + timestamp
cat "$issue_dir/.in-flight.lock/pid"          # pid that claimed it
cat "$issue_dir/.in-flight.lock/timestamp"    # ISO-8601 UTC

# 3. Is the holder pid actually alive?
holder=$(cat "$issue_dir/.in-flight.lock/pid")
if kill -0 "$holder" 2>/dev/null; then echo "alive"; else echo "DEAD"; fi
```

### Recover

**Common case (holder pid is dead).** No operator action is
required. `bin/common.sh::try_acquire_lock` self-heals on the next
acquire attempt: it reads `$dir/pid`, sees `kill -0 $pid` fails,
and reclaims via `rm -rf $dir` + re-mkdir + post-mkdir
pid-readback. The next tick (≤ 5 min) picks the issue up
automatically. Inspect the local log on the next tick for a
`try_acquire_lock: reclaiming stale lock at …` line — confirms
the self-heal fired.

**Rare case (holder pid IS alive but issue still appears stuck).**
Implies the holder is hung rather than orphaned. Inspect:

```bash
ps -fp "$holder"   # what is the holder doing?
cat "$issue_dir/.in-flight.lock/timestamp"   # how long has it held?
```

If the holder is a runaway `dispatch.sh` or `gtimeout claude -p`
that has exceeded its per-stage cap, `kill $holder` first; the
next tick reclaims via `try_acquire_lock`.

**Override of last resort.** Only if both the holder is dead AND
something has broken `try_acquire_lock`'s self-heal (rare;
typically an interrupted pid-readback that left the dir in a weird
state):

```bash
rm -rf "$issue_dir/.in-flight.lock"
```

### Root cause

Pre-ENG-81's scheduler/worker split could leak an orphan
`.in-flight.lock/` if the worker was SIGKILLed / oomkilled /
host-rebooted between `mkdir` and `release_lock`. ENG-81 added
self-healing recovery to `try_acquire_lock`: every acquire attempt
that finds the dir present reads the recorded holder pid and
reclaims if `kill -0 $pid` fails. The pid-readback after re-mkdir
handles concurrent reclaim races.

### Related

ENG-81 (per-issue lock contract + self-heal recovery),
`bin/common.sh::try_acquire_lock` (the helper). See `CLAUDE.md`
§"Failure-mode quick reference" row "Issue stuck at one stage;
`.in-flight.lock` present".

---

## scope-check halts on upstream merge files

### Symptom

scope-check halts an issue with files in the diff that the agent did
not touch — typically files modified by an upstream merge that landed
between the operator's last `git pull` and this dispatch.

### Diagnose

```bash
# Did the per-stage transcript log a fetch failure?
grep -i 'fetch origin main' \
  "$PROJECT_STATE_DIR/<ident>/logs/<stage>-*.log"
```

### Recover

This is the bug ENG-59 fixes. If you're seeing it on post-ENG-59 code,
check whether the per-stage transcript shows
`scope-check: fetch origin main failed` — fetch unreachable + no prior
`refs/remotes/origin/main` falls back to local `main` (the pre-ENG-59
behavior, preserved as a degraded warning-emitting mode).

```bash
# Fetch by hand from the operator's checkout
cd "$TARGET_REPO"
git fetch origin main

# Resume the issue
bash bin/pipeline.sh decide ENG-N --action continue
```

### Root cause

Pre-ENG-59: scope-check diffed against the host's local `main` ref,
which only advances when the operator pulls. Post-ENG-59: scope-check
fetches `origin main` per run and diffs against `origin/main`. The
degraded mode (offline) is the only remaining path that can hit this.

### Related

ENG-59 (the dogfooded demo in the README).

---

## Common-cause table

| Cause | Symptoms it produces | Fix |
|---|---|---|
| Stale `linear-ids.json` cache | Wrong-target Linear writes | `bash bin/linear.sh refresh-cache` |
| Expired `claude` session | Cascading halts across all issues, all with `dispatch-timeout` or `agent-blocked` | `claude login` |
| `gtimeout` missing from PATH | Per-stage transcripts show "command not found"; agent runs without timeout | `brew install coreutils` |
| `gh` missing from launchd PATH | Build idles with `dispatch-skipped`; `entry-conditions error:gh` in transcripts | Update plist PATH or symlink `gh` to `/usr/local/bin/` |
| Operator forgot `git pull` (pre-ENG-59) | scope-check halts on upstream files | `git fetch origin main` (post-ENG-59 does this automatically) |
| New `bin/*-test.sh` not in allowed-tools list | QA halts with permission denied; agent ships untested | Regenerate `dispatch.tools` list (see [`configuration.md`](../configuration.md#regenerating-the-test-allowlist)) |
| `Bug` label added/removed mid-flight | Branch-shape drift; PR creation silently fails | Don't change type labels post-creation; if unavoidable, manually rebase the branch and `--action continue` |

## When to escalate

Most failures recover with `--action continue`. Escalate (open a fresh
issue, file a bug against the harness) when:

- A halt's reason token is **not** in the registry (look in
  [`pipeline-vocabulary.md`](../pipeline-vocabulary.md) — if the halt
  comment shows a token not listed there, the orchestrator is broken).
- The same recovery procedure works once and then fails on the next
  identical scenario (indicates a state-management bug).
- `events.jsonl` shows orphan `stage-start` events with no matching
  `stage-end` (the retrospective will catch this; manual investigation
  warranted in real-time).
- Disk and Linear disagree on which stage an issue is in (the canonical
  source is `stage:X` label in Linear; on-disk state should match).
