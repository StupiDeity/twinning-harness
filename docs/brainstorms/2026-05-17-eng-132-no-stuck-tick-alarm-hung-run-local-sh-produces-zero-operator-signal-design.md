---
linear: ENG-132
title: Stuck-tick alarm — external observer of run-local.sh heartbeat
date: 2026-05-17
status: draft
---

# Stuck-tick alarm — external observer of run-local.sh heartbeat

## 1. Problem

On 2026-05-15 a dispatch hung for 5h 43m past its 1h budget. Every
subsequent launchd tick (~68 of them at 5-min cadence) silent-skipped
because the tick lock's `kill -0` check at
`bin/run-local-helpers.sh:925` showed the holder shell still alive
(blocked on `wait`, not dead). Nothing alerted. The operator only
noticed via manual `ps -ef` inspection many hours later.

The underlying dispatch hang is filed separately (Bug). **This ticket
is the missing safety net.** Whatever future hang slips past the
dispatch-level fix should not produce silent multi-hour outages.

Today every alarm path the harness has runs **inside the tick**:

| Path | Location | When it fires |
|---|---|---|
| `_poll_emit_halt_sprawl_alert` | `bin/poll.sh:545-610` | Inside a running tick, halted-issue threshold breached, 24h debounce |
| `bin/slack.sh warn` | `bin/slack.sh:12-39` | Only when something inside the tick calls it |
| `== tick start ==` / `== tick end ==` log lines | `bin/run-local.sh:81, :504` | `$LOG_FILE` only — no consumer reads them |
| `.tick-counter` | `bin/run-local.sh:41` | Used for cleanup cadence (every N ticks), not as a heartbeat |
| launchd plist | `launchd/com.twinning.pipeline.plist.template` | Fires `run-local.sh`; no per-invocation deadline; no liveness observation |

If the tick is stuck, every alarm path is also stuck. The lock's
stale-pid recovery (`bin/run-local-helpers.sh:916-934`) only fires
when the holder is **dead** — a wedged-but-alive holder is
indistinguishable from a legitimate long-running tick. Result: silent
skip every 5 min, no log line going anywhere actionable, no Slack
message.

## 2. Decisions

- **D-001. Add a `.last-tick-end` heartbeat file written atomically at
  the end of every successful tick by `bin/run-local.sh`. An
  independent launchd job, `com.twinning.stuck-tick-alarm.<slug>`,
  runs every 15 minutes and POSTs to Slack via `bin/slack.sh warn`
  when `now - mtime(.last-tick-end) > ALARM_MINUTES`.**

  *Heartbeat write site:* immediately after the existing `log "== tick
  end (success, …)"` line at `bin/run-local.sh:504`. The write is
  atomic via temp + rename (`mv -f`); a crash mid-write does not leave
  a half-line. Path: `$PROJECT_STATE_DIR/.last-tick-end`. Content: a
  single ISO-8601 UTC timestamp (`date -u +%Y-%m-%dT%H:%M:%SZ`).

  Cost: one `date` invocation + one rename per tick. The file is
  per-project (lives under `$PROJECT_STATE_DIR`, parallel to
  `.tick-counter`, `.consecutive-failures`, `.halt-sprawl-last-alerted`).

  *Observer site:* new file `bin/stuck-tick-alarm.sh`. Reads
  `$PROJECT_STATE_DIR/.last-tick-end` mtime, compares against `date -u
  +%s`, fires `bin/slack.sh warn` when delta exceeds the configured
  threshold. Debounces per the halt-sprawl pattern
  (`bin/poll.sh:577-607`): write
  `$PROJECT_STATE_DIR/.stuck-tick-last-alerted` after firing; suppress
  subsequent alerts within a 24h window.

  *Reference to constraint:* CLAUDE.md "Runtime topology" — the
  orchestrator runs once per 5 min via `launchd`; the same pattern
  applies cleanly to the alarm. CLAUDE.md "When wiring a new script"
  — sourcing `common.sh`, using `log/die/require_env`, routing
  through `bin/slack.sh` and `bin/metrics.sh`.

  *Reference to product principle:* CLAUDE.md "Don't add features,
  refactor, or introduce abstractions beyond what the task requires"
  — D-001 adds one file write per tick, one bash script, one
  launchd plist, one config key. No new abstractions, no scheduler,
  no daemon. The pattern mirrors `_poll_emit_halt_sprawl_alert`
  (level-triggered metric + edge-triggered Slack + debounce file)
  exactly.

  *Rejected alternative — embed a `gtimeout` watchdog around the
  tick body inside `run-local.sh`:* this is what the existing
  `gtimeout` wrapper around `claude -p` already does at the
  dispatch level (ENG-65). It demonstrably did not fire on
  2026-05-15 (see memory note `gtimeout_watchdog_can_silently_fail.md`).
  Adding a SECOND `gtimeout` inside `run-local.sh` is a layer below
  the symptom: the entire tick is wedged on `wait`, including
  whatever watchdog runs inside it. The fix must be external to the
  process group.

  *Rejected alternative — replace the `kill -0` lock-aliveness check
  with a "lock + heartbeat" combo inside the lock dir:* would make
  `acquire_lock` reclaim "alive but stale" locks. Rejected because (a)
  reclaiming the lock kicks off a SECOND tick on top of the stuck one
  rather than alerting, multiplying the failure surface, and (b) it
  silently masks the underlying hang instead of surfacing it.
  Surfacing is the goal of this ticket.

  *Rejected alternative — a separate full daemon (Go binary,
  systemd-style supervisor):* rejected as scope creep. CLAUDE.md
  "Runtime topology" already uses launchd as the universal scheduler;
  adding a third launchd job costs one plist template and one install
  step. A daemon would add a build artifact, a binary distribution
  problem, and a new failure mode.

  *Rejected alternative — PagerDuty / Honeycomb / push-notification
  integration:* explicitly out of scope per Linear "Out of scope" §3
  ("Migrating to a different watchdog technology"). The existing
  `bin/slack.sh` is sufficient; matches the precedent set by
  `_poll_emit_halt_sprawl_alert`.

- **D-002. The threshold is configurable via
  `orchestrator.stuck_tick_alarm_minutes` in
  `.pipeline-config/config.json`. Default 30 (= 6× tick interval).
  Floor 10 (= 2× tick interval; below this, legitimate stage-overlap
  silent-skips would false-positive). Resolution precedence mirrors
  ENG-65 timeouts and ENG-103 model resolution.**

  Precedence (highest first):

  1. `STUCK_TICK_ALARM_MINUTES` env var (settable in the alarm plist's
     `EnvironmentVariables` block for emergency override).
  2. `.orchestrator.stuck_tick_alarm_minutes` in `config.json`.
  3. Built-in default `30`.

  Validation: integer regex `^[0-9]+$`, value `>= 10`. Invalid or
  out-of-range values fall through to the next layer with one `log`
  warning to stderr. Same fail-soft posture as
  `_cfg_minutes` (ENG-65, `bin/dispatch.sh:469-488`) and `_resolve_K`
  (ENG-81).

  *Rationale for 30-min default:* tick cadence is 5 min. Brainstorming
  and planning dispatches legitimately run up to 60 min (ENG-65
  per-stage timeout default). Other stages cap at 30 min. With K=2
  concurrent dispatches, one 60-min brainstorm overlapping with a
  short tick produces ~12 silent skips. 30 min absorbs that envelope
  plus normal jitter; anything past 30 min is genuinely anomalous.

  *Rationale for 10-min floor:* two consecutive tick intervals are the
  minimum that absorbs a single legitimate >5-min stage. A value below
  10 would alert on every K=1 long-stage tick.

  *Reference to constraint:* CLAUDE.md "Per-stage dispatch timeouts
  (ENG-65)" and "Per-project dispatch concurrency (ENG-81)" — both
  use the same three-layer resolution (env > config.json > built-in
  default). Stuck-tick alarm joins that family.

  *Rejected alternative — derive the threshold from `2 *
  max(dispatch_timeout_minutes_per_stage)`:* rejected because (a) it
  couples two unrelated knobs (the stuck-tick alarm is about
  liveness, not per-stage budget), (b) operators tuning the dispatch
  timeout would silently move the alarm threshold, and (c) the
  computed value would be 120 min by default (2 × 60), which is
  larger than what the operator actually wants for incident
  detection.

- **D-003. The alarm fires via `bin/slack.sh warn`; the payload
  includes heartbeat mtime + age, lock holder pid + `ps -ef`
  excerpt, and the tail of the current log file. No new transport.**

  Payload shape (markdown-flavored, sent verbatim to Slack):

  ```
  Stuck tick alarm: $PROJECT_SLUG has not completed a tick for <age> (last: <iso-ts>)
  Lock holder: pid=<pid> (alive=yes|no)
  ps -ef excerpt: <holder + first 5 children>
  Log tail (last 40 lines of $LOG_FILE): <…>
  ```

  Operator gets enough to triage from Slack alone (matches the
  halt-sprawl alert's "top3 halted issue identifiers" payload pattern
  at `bin/poll.sh:594-600`).

  *Reference to constraint:* CLAUDE.md "When wiring a new script" —
  "Linear writes go through `bin/linear.sh`... metric writes go
  through `bin/metrics.sh`." The alarm uses `bin/slack.sh` (same
  chokepoint convention) and emits a `stuck-tick` metric via
  `bin/metrics.sh` (same as halt-sprawl).

  *Rejected alternative — post to Linear instead of Slack:* rejected
  because (a) when the tick is stuck, the operator may have stopped
  monitoring Linear (halt-sprawl posts already use Slack for the
  same reason), (b) the alarm is harness-wide, not per-issue;
  Linear is a per-issue thread surface; there is no obvious
  per-issue host for the alarm, and (c) the issue tracker is not
  the incident response surface.

- **D-004. New launchd plist
  `launchd/com.twinning.stuck-tick-alarm.plist.template` installed by
  extending `bin/install-launchd.sh::install_one` with a third
  `install_one stuck-tick-alarm 0` invocation. Fires every 15 min
  (`StartInterval=900`), independent of the main pipeline plist.**

  The kickstart-on-install flag is `0` (do not fire at install time
  — first scheduled fire is enough; mirror retrospective behavior at
  `bin/install-launchd.sh:59`).

  *Why 15-min cadence (not 5):* a 30-min threshold + 5-min cadence
  would fire 6 times before stabilizing; a 15-min cadence + 30-min
  threshold fires twice maximum (first fire at 30-45 min wedged, next
  fire at 45-60 min suppressed by debounce). 15 min is the largest
  cadence that still detects within one extra interval of the
  threshold. (Alternative considered: 30-min cadence — rejected
  because the alert latency would compound the original wedge.)

  *Reference to constraint:* CLAUDE.md "Runtime topology" — launchd
  is the universal scheduler; CLAUDE.md "PATH expectations on the
  launchd host" — the alarm script needs the same PATH segments as
  the main plist (Homebrew + system) since it shells out to `ps`,
  `date`, `bash bin/slack.sh`.

  *Rejected alternative — re-use the main pipeline plist's
  StartInterval:* rejected because the entire bug class is "the
  pipeline plist's program is stuck." The alarm MUST run in an
  independent process tree, scheduled by an independent launchd
  entry, so launchd's keepalive remains the only thing it depends on
  (per Linear "Why an external job and not just adding to
  run-local.sh" §).

  *Rejected alternative — extend the retrospective plist (also runs
  outside the pipeline tick):* the retrospective fires Monday 09:00,
  not every 15 min. Re-purposing it would mean changing its
  cadence, which conflicts with its scheduled-cron nature. Separate
  plist is cleaner.

- **D-005. The alarm script emits a `stuck-tick` event via
  `bin/metrics.sh` on every fire (level-triggered), matching the
  halt-sprawl pattern at `bin/poll.sh:573-574`. Slack post is
  edge-triggered (debounced 24h).**

  Metric notes field carries `age=<seconds> threshold=<seconds>
  holder_pid=<pid>` so retrospective and `bin/status.sh` can mine the
  incident timeline.

  *Reference to constraint:* CLAUDE.md "When wiring a new script" —
  metric writes go through `bin/metrics.sh`. The retrospective's §1
  filter relies on `events.jsonl` for incident replay; emitting
  `stuck-tick` events makes hangs visible to that surface
  retroactively.

- **D-006. Test surface: new file `bin/stuck-tick-alarm-test.sh`
  follows the sentinel + source-and-stub pattern from CLAUDE.md
  "How tests work." Mocks `bin/slack.sh` and `bin/metrics.sh` via
  STUB_DIR.**

  Test cases (canonical AC-XYZ names mirror
  `bin/halt-sprawl-test.sh`):

  1. **AC-FRESH** — heartbeat mtime within threshold → no alert, no
     metric.
  2. **AC-STALE** — heartbeat mtime past threshold → metric emitted,
     Slack call recorded, debounce stamp written.
  3. **AC-DEBOUNCED** — heartbeat stale + recent debounce stamp →
     metric emitted (level-triggered), Slack call NOT recorded.
  4. **AC-MISSING-HEARTBEAT** — no `.last-tick-end` file → treated
     as worst-case stale → alert fires.
  5. **AC-MALFORMED-TIMESTAMP** — `.last-tick-end` contains invalid
     content (e.g., empty string, random bytes) → alert fires + `log`
     warning emitted.
  6. **AC-CONFIG-DEFAULT** — `config.json` absent → built-in default
     30 min applies.
  7. **AC-CONFIG-OVERRIDE** — `orchestrator.stuck_tick_alarm_minutes:
     45` → 45-min threshold applied.
  8. **AC-CONFIG-BELOW-FLOOR** — `stuck_tick_alarm_minutes: 5` →
     falls through to built-in default 30 (below floor of 10).
  9. **AC-CONFIG-NON-INTEGER** — `stuck_tick_alarm_minutes: "30m"`
     → falls through to built-in default 30.
  10. **AC-ENV-OVERRIDE** — `STUCK_TICK_ALARM_MINUTES=20` →
      env-value wins over config.

  Plus a separate `bin/install-launchd-test.sh` extension asserts
  the third plist gets rendered and bootstrapped via the
  `LAUNCHCTL_LOG` capture.

  *Reference to constraint:* CLAUDE.md "Tests" — sibling
  `*-test.sh` files, no test runner. Test must register in the
  pre-commit hook's discovery (`.githooks/pre-commit` already runs
  every `bin/*-test.sh`).

- **D-007. Operator-doc edit: new subsection in CLAUDE.md "Stuck-tick
  alarm (ENG-132)" alongside the existing "Per-stage dispatch
  timeouts (ENG-65)" and "Per-project dispatch concurrency (ENG-81)"
  sections. Mirror the depth and structure of those sections.**

  Coverage: heartbeat file location, alarm cadence, debounce window,
  config knob + precedence + validation, what the Slack payload
  looks like, how to silence (e.g., set
  `stuck_tick_alarm_minutes: 9999` during planned maintenance), how
  to trigger manually (`bash bin/stuck-tick-alarm.sh` from the CLI).
  Add a new row to the "Failure-mode quick reference" table:

  | Symptom | Where to look |
  |---|---|
  | Slack message "Stuck tick alarm" | `bin/run-local.sh` is wedged or `launchd` agent dead. Inspect `$PROJECT_STATE_DIR/.last-tick-end` mtime, `$PROJECT_STATE_DIR/.run-local.lock/pid`, then `ps -ef \| grep <pid>`. Recovery: `launchctl kickstart -k gui/$(id -u)/com.twinning.pipeline.$PROJECT_SLUG` (force-kill + restart) after confirming the holder is wedged. |

  Also add an entry to `docs/configuration.md` under
  `orchestrator.*` documenting the new config key.

  *Reference to constraint:* CLAUDE.md preamble — "Don't create
  documentation files (*.md) or README files unless explicitly
  requested by the User." Doc edits in this brainstorm are
  IN-PLACE edits to existing files (CLAUDE.md, docs/configuration.md),
  not new doc files. The brainstorm itself is the only new doc.

## 3. Architecture

### Files modified or created

1. **`bin/run-local.sh`** — D-001 heartbeat write.

   New helper `_write_tick_heartbeat` at the helpers block (around
   `bin/run-local.sh:127` near `resolve_worktree_path`). Body:

   ```bash
   _write_tick_heartbeat() {
     local heartbeat_file="$PROJECT_STATE_DIR/.last-tick-end"
     local tmp="${heartbeat_file}.tmp.$$"
     date -u +%Y-%m-%dT%H:%M:%SZ > "$tmp"
     mv -f "$tmp" "$heartbeat_file"
   }
   ```

   Called immediately after the existing `log "== tick end
   (success, …)"` line at `bin/run-local.sh:504`:

   ```bash
   log "== tick end (success, ${#_claimed_workers[@]} worker(s)) =="
   _write_tick_heartbeat
   ```

   Placement *after* the success-log line, not before, so a partial
   tick (e.g., release-watcher fail) STILL writes the heartbeat —
   the alarm is about liveness, not success. A truly stuck tick
   never reaches this line.

2. **`bin/stuck-tick-alarm.sh`** — NEW file. D-001 + D-002 + D-003 +
   D-005.

   Skeleton:

   ```bash
   #!/usr/bin/env bash
   set -euo pipefail
   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
   source "$SCRIPT_DIR/common.sh"

   _resolve_alarm_minutes() {
     # env > config > default 30; validate ^[0-9]+$ and >= 10
   }
   _heartbeat_age_seconds() { ... }
   _lock_holder_pid()      { ... }
   _ps_excerpt_for_pid()   { ... }
   _log_tail_for_today()   { ... }
   _debounced()            { ... }
   _stamp_debounce()       { ... }

   main() {
     local threshold age payload
     threshold="$(_resolve_alarm_minutes)"
     age="$(_heartbeat_age_seconds)"   # very large if file missing

     if (( age <= threshold * 60 )); then
       return 0
     fi

     # Level-triggered metric every fire.
     bash "$SCRIPT_DIR/metrics.sh" stuck-tick "" "" alert 0 \
       "age=$age threshold=$((threshold * 60)) holder_pid=$(_lock_holder_pid)" || true

     if _debounced; then
       log "stuck-tick: slack suppressed by debounce"
       return 0
     fi

     payload="$(printf 'Stuck tick alarm: %s has not completed a tick for %s (threshold %sm)\nLock holder pid: %s\nps excerpt:\n%s\nLog tail:\n%s' \
       "$PROJECT_SLUG" "$age sec" "$threshold" "$(_lock_holder_pid)" \
       "$(_ps_excerpt_for_pid)" "$(_log_tail_for_today)")"
     bash "$SCRIPT_DIR/slack.sh" warn "$payload" || true
     _stamp_debounce
   }

   if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
     main "$@"
   fi
   ```

   Sources `common.sh` to inherit `HARNESS_ROOT`, `PROJECT_STATE_DIR`,
   `log`, `die`, `require_env`. Sentinel pattern at the bottom enables
   the test harness to `source` it without firing `main`.

3. **`launchd/com.twinning.stuck-tick-alarm.plist.template`** — NEW
   file. D-004.

   Modeled on `com.twinning.pipeline.plist.template`. Diffs from the
   pipeline plist:

   - `Label` → `com.twinning.stuck-tick-alarm.__PROJECT_SLUG__`.
   - `ProgramArguments` → `/bin/bash __HARNESS_ROOT__/bin/stuck-tick-alarm.sh`.
   - `StartInterval` → `900` (15 min, vs 300 for pipeline).
   - `RunAtLoad` → `false` (no need to fire at boot before any tick has
     completed).
   - `StandardOutPath` / `StandardErrorPath` →
     `__HARNESS_STATE_DIR__/__PROJECT_SLUG__/logs/stuck-tick-alarm-launchd.{out,err}.log`.
   - `EnvironmentVariables` identical to pipeline plist (PATH, HOME,
     TARGET_REPO, HARNESS_STATE_DIR, PROJECT_SLUG).

4. **`bin/install-launchd.sh`** — D-004 install integration.

   Two-line edit at `bin/install-launchd.sh:58-59`:

   ```bash
   install_one pipeline         1
   install_one retrospective    0
   install_one stuck-tick-alarm 0    # NEW
   ```

   Existing `install_one` helper already parameterizes on `kind`; the
   `$kind.plist.template` resolution at `bin/install-launchd.sh:33`
   picks up the new template automatically with no further changes.

   Also extend the trailing `cat <<EOF` summary block at
   `bin/install-launchd.sh:61-66` with the new agent label.

5. **`bin/stuck-tick-alarm-test.sh`** — NEW file. D-006 test cases.

   Source-and-stub pattern: stub `bin/slack.sh`, `bin/metrics.sh`,
   pre-set `PROJECT_STATE_DIR` to a `mktemp -d`, write fixture
   heartbeat files with controlled `touch -d` mtimes, then call
   `main` and assert against the stub-capture files.

6. **`bin/install-launchd-test.sh`** — D-006 extension.

   Add one assertion to the existing test verifying the third
   `LAUNCHCTL_LOG` row for `bootstrap … com.twinning.stuck-tick-alarm.foo.plist`
   exists, mirroring the existing pipeline + retrospective assertions.
   Also seed the third template file resolution.

7. **`CLAUDE.md`** — D-007 doc edit.

   New ~25-line subsection "Stuck-tick alarm (ENG-132)" inserted
   between "Per-project dispatch concurrency (ENG-81)" and
   "Failure-mode quick reference." New row in the failure-mode
   table at the documented row anchor.

8. **`docs/configuration.md`** — D-007 doc edit.

   New `orchestrator.stuck_tick_alarm_minutes` subsection mirroring
   the existing `orchestrator.dispatch_timeout_minutes` subsection
   (~30 lines: schema, precedence, validation, examples).

9. **`.githooks/pre-commit`** — no edit required. The hook globs
   `bin/*-test.sh` automatically and picks up
   `bin/stuck-tick-alarm-test.sh`.

10. **`bin/setup.sh`** — no edit required. `install-launchd.sh` is
    called from setup's launchd phase; the new plist is rendered
    transparently.

### Files NOT modified (intentional)

- **`bin/run-stage.sh`** — the alarm is harness-wide, not per-stage.
  No `_resolve_dispatch_model`-style per-stage hook needed.
- **`bin/poll.sh`** — separate alarm path, separate debounce file,
  separate threshold. Symmetric pattern, NOT shared code (per
  CLAUDE.md "Don't add features... beyond what the task requires" —
  shared abstraction is premature at one caller).
- **`bin/run-local-helpers.sh::acquire_lock`** — unchanged. The lock's
  contract is "at most one tick at a time on this host"; that's still
  correct. The alarm is the missing observability surface, not a
  lock-protocol change.
- **`bin/pipeline-events.json`** — no new vocabulary. `stuck-tick` is
  a metrics-event name, not a Linear marker.
- **`learned-rules/<slug>/project-profile.md`** — profile drives
  stack-specific allowlists; this is harness-wide, not stack-specific.

## 4. Data flow

Two flows, plus the install path.

### Flow 1: healthy heartbeat (no alarm)

```
launchd com.twinning.pipeline.<slug>  (every 5 min)
  → run-local.sh
    → acquire_lock → ok
    → main tick body (poll, reconcile, dispatch K workers, sweep, …)
    → log "== tick end (success, N worker(s)) =="
    → _write_tick_heartbeat
        → date -u +%Y-%m-%dT%H:%M:%SZ > $PROJECT_STATE_DIR/.last-tick-end.tmp.$$
        → mv -f $PROJECT_STATE_DIR/.last-tick-end.tmp.$$ $PROJECT_STATE_DIR/.last-tick-end

launchd com.twinning.stuck-tick-alarm.<slug>  (every 15 min, independent)
  → stuck-tick-alarm.sh
    → _resolve_alarm_minutes → 30
    → _heartbeat_age_seconds → 480  (8 min, fresh)
    → 480 <= 30 * 60 → return 0
```

### Flow 2: stuck tick (alarm fires)

```
launchd com.twinning.pipeline.<slug>  (every 5 min)
  → run-local.sh tick T0: acquires lock, dispatches a hung agent
  → ticks T1, T2, …, T6 (over 30 min): silent-skip via acquire_lock
    (kill -0 holder == ok because shell is alive on `wait`)
  → heartbeat stays at T0's mtime

launchd com.twinning.stuck-tick-alarm.<slug>  fires
  → stuck-tick-alarm.sh
    → _resolve_alarm_minutes → 30
    → _heartbeat_age_seconds → 1830  (30.5 min)
    → 1830 > 30 * 60 → proceed
    → metrics.sh stuck-tick "" "" alert 0 "age=1830 threshold=1800 holder_pid=12345"
        → events.jsonl row
    → _debounced → false (first fire)
    → slack.sh warn "Stuck tick alarm: harness has not completed a tick for 30 min (threshold 30m)
                    Lock holder pid: 12345
                    ps excerpt: <holder + 5 children>
                    Log tail: <last 40 lines of local-2026-05-17.log>"
    → _stamp_debounce → write $PROJECT_STATE_DIR/.stuck-tick-last-alerted

Next stuck-tick-alarm fire (15 min later, still wedged):
  → metric emitted (level-triggered)
  → _debounced → true → slack suppressed
```

### Flow 3: install

```
bash bin/setup.sh /path/to/target
  → … → install-launchd.sh
    → install_one pipeline 1
        → render com.twinning.pipeline.<slug>.plist → bootstrap → kickstart
    → install_one retrospective 0
        → render com.twinning.retrospective.<slug>.plist → bootstrap
    → install_one stuck-tick-alarm 0
        → render com.twinning.stuck-tick-alarm.<slug>.plist → bootstrap
```

## 5. Error handling

### Heartbeat file missing

If `.last-tick-end` does not exist (first ever run, or operator wiped
the project state dir), `_heartbeat_age_seconds` returns a very large
sentinel (`99999999`) so the alarm treats absence as worst-case stale
and fires. Operator sees the alarm immediately after first install if
the first tick hasn't completed within `threshold` minutes — that IS
the correct signal (something is wrong if a fresh install can't
complete one tick in 30 min).

To suppress on planned bootstrap windows: set the env var
`STUCK_TICK_ALARM_MINUTES=9999` in the plist and `launchctl bootstrap`
the alarm plist.

### Heartbeat file with malformed content

The file should contain a single ISO-8601 UTC timestamp. The alarm
reads `mtime` (via `stat`), NOT the file content, so even garbage
content does not affect the alarm decision. The content is for
operator triage (`cat .last-tick-end` shows the last good tick's
timestamp). If content is malformed, the alarm still fires correctly
based on mtime.

### Config file missing

`_resolve_alarm_minutes` reads
`jq -r '.orchestrator.stuck_tick_alarm_minutes // empty' "$CONFIG"
2>/dev/null || true`. Missing file or unreadable returns empty;
falls through to built-in default 30. Same `_cfg_minutes` fail-soft
shape (`bin/dispatch.sh:469-488`).

### Malformed config (non-integer, below floor)

Validation: `[[ "$value" =~ ^[0-9]+$ ]] && (( value >= 10 ))`. On
failure, fall through to default with one `log` warning. Same
fail-soft posture as ENG-65 / ENG-81.

### Slack webhook unset

`bin/slack.sh:16-19` already handles this: no `PIPELINE_SLACK_WEBHOOK_URL`
→ logs and returns 0. The alarm script does NOT die on no-op Slack;
the metric still fires (the events.jsonl row is the durable record
even when Slack is unconfigured).

### `bin/slack.sh` fails (network outage, malformed webhook)

The alarm calls `bash "$SCRIPT_DIR/slack.sh" warn "$payload" || true`.
Failure is logged by `slack.sh` itself and the alarm continues to
write the debounce stamp. Worst case: Slack outage during an alarm
window suppresses the post (but the metric row remains for
retrospective replay). Matches `_poll_emit_halt_sprawl_alert`'s
`|| true` posture at `bin/poll.sh:602`.

### Debounce stamp corrupted

`bin/poll.sh:582-589` already established the pattern: invalid stamp
content → `last_epoch` stays 0 → next tick fires Slack. Same shape
here. The corruption auto-heals on the next fire that overwrites the
stamp.

### Alarm plist's own process gets wedged

The alarm script runs `bash`, `date`, `jq`, `stat`, `ps`, `tail`,
`curl` (via slack.sh). None of these block on user input or external
locks. The script has no `wait` call, no `claude -p` invocation, no
network call other than the Slack POST (which `curl -fsS` times out
at the OS level). Worst-case path: a `bash` invocation hangs on a
zombie shell — `launchctl` will fire a fresh instance on the next
StartInterval; bash zombies do not stack indefinitely under launchd's
default ThrottleInterval. Not a known failure mode for any of these
commands.

### PROJECT_STATE_DIR missing

`common.sh::55-60` dies loud if `PROJECT_SLUG` is unresolvable. If
the directory exists but `.last-tick-end` doesn't, the alarm proceeds
per "Heartbeat file missing" above. The alarm script does NOT create
`PROJECT_STATE_DIR`; that's `run-local.sh`'s responsibility.

### Lock holder pid file missing or invalid

`_lock_holder_pid` reads `$PROJECT_STATE_DIR/.run-local.lock/pid`. If
absent (no tick currently holds the lock), the alarm still fires (the
stale heartbeat is the trigger; the holder info is decoration). The
payload reports `holder_pid=none`. This case arises when the tick
crashed without writing the heartbeat AND released the lock — both
true if a tick segfaults early; the alarm correctly surfaces that the
tick died.

### `ps -ef | grep <pid>` accidentally matches other processes

`_ps_excerpt_for_pid` should use `ps -p <pid> -ef` (or `pgrep -P
<pid>` for descendants) to scope the output, not `grep <pid>` which
would match arbitrary processes containing the pid as a substring.
Implementation detail flagged for the plan stage.

## 6. Edge cases

1. **First-ever install on a fresh project.** `.last-tick-end` does
   not exist. The alarm plist's first fire (15 min after install)
   sees an absent heartbeat and alerts. This IS the right behavior:
   if 15 min after install no tick has completed successfully,
   something is misconfigured (likely missing secrets, wrong
   `TARGET_REPO`). The alert's payload shows "Lock holder pid: none"
   pointing at "install didn't bootstrap cleanly."

2. **Planned maintenance / dispatch storm.** Operator wants to
   suppress alerts while running `bash bin/dry-run.sh` against a
   large fixture set. Set `STUCK_TICK_ALARM_MINUTES=9999` in the
   alarm plist + `launchctl bootstrap` the alarm. Revert when done.

3. **K=2 long brainstorm + short tick overlap.** Brainstorm at K=2
   with `dispatch_timeout_minutes_per_stage.brainstorming: 60` runs
   for up to 60 min. The tick that dispatched it returns once the
   brainstorm completes (subshell `wait`); during those 60 min,
   intervening ticks silent-skip. Heartbeat stays old for ~60 min.
   Threshold 30 min means the alarm fires at 30 min into the
   brainstorm. **Trade-off explicitly accepted:** legitimate slow
   brainstorms will produce one Slack notification. Operator can
   inspect, observe the holder pid is still running `claude -p`, and
   move on. Pre-ENG-132, the operator had zero signal at all; one
   acknowledgeable Slack ping is strictly better. Operators
   experiencing a high false-positive rate can tune
   `stuck_tick_alarm_minutes: 75` to absorb the 60-min worst case
   plus 15-min cushion. **This is documented in CLAUDE.md per
   D-007.**

4. **K=1 (rolled back per ENG-81 emergency recipe).** Single-slot
   dispatch is the worst case for tick blocking (no concurrency
   amortization). Threshold still 30 min; a single 60-min brainstorm
   still produces an alert. Same trade-off as edge case 3; same
   resolution.

5. **Heartbeat written during partial-success tick (e.g.,
   release-watcher failed).** The placement after `log "== tick end
   (success, …)"` means a tick that reached the success log line
   writes the heartbeat. A tick that crashed in the worker subshell
   or earlier does NOT — and the alarm fires after the threshold.
   **Correct:** crashed ticks are the failure mode we're surfacing.

6. **Clock skew across the launchd host.** Both heartbeat write and
   alarm read use `date -u`. NTP drift on a Mac is bounded to
   seconds. Even a 10-min skew is absorbed by the 30-min threshold.

7. **Operator manually invokes `bash bin/stuck-tick-alarm.sh`.** The
   sentinel runs `main` exactly as launchd does; if the heartbeat is
   stale, the alarm fires (operator's own Slack channel). Used for
   smoke-testing the install. The threshold + debounce apply
   uniformly.

8. **Concurrent fire (alarm plist + manual invocation).** Both
   processes read the same `.stuck-tick-last-alerted` file. The
   `mv -f` debounce write is atomic; worst case is one extra Slack
   post if both processes pass the debounce check simultaneously.
   Not a correctness issue — Slack receives one extra alert, no
   data corruption.

9. **Heartbeat write fails (disk full, permission error).** The
   `mv -f` would fail; `run-local.sh` is currently under `set -euo
   pipefail`, so an uncaught failure here would terminate the
   process. **Mitigation:** wrap `_write_tick_heartbeat`'s body in
   `|| log "heartbeat write failed"` so the tick still exits 0. The
   alarm then fires on the absent (or stale) heartbeat — operator
   sees BOTH the alarm and the failed-write log. Acceptable.

10. **`com.twinning.stuck-tick-alarm.<slug>` launchd agent is dead
    (not loaded).** The alarm never fires; the harness regresses to
    pre-ENG-132 behavior (silent multi-hour outages). This is the
    "watching the watcher" problem; outside the scope of this
    ticket per CLAUDE.md "Don't add features... beyond what the
    task requires." Defense: setup.sh's launchd phase verifies the
    plist is loaded; `bash bin/setup.sh validate` (a future
    extension) could spot-check. **Filed as OQ-1 below; not
    blocking.**

11. **Per-project alarm in a multi-project install.** Each project
    slug gets its own alarm plist (`com.twinning.stuck-tick-alarm.<slug>`),
    each reading its own `$PROJECT_STATE_DIR/.last-tick-end`. The
    label scoping mirrors `com.twinning.pipeline.<slug>`. No
    cross-project interference. (`PROJECT_SLUG` is resolved at
    plist render time per `bin/install-launchd.sh:37-43`.)

12. **Same-tick race between heartbeat write and alarm read.** The
    alarm runs every 15 min; the heartbeat is written at most every
    5 min (one per tick). Worst case: the alarm fires the instant
    after a heartbeat write; reads the fresh mtime; no alert.
    Correct.

## 7. Open Questions

1. **OQ-1. Should we monitor the alarm plist's own liveness ("watch
   the watcher")?** The alarm depends on launchd firing it; if
   launchd unloaded the alarm agent, the alarm itself goes silent.
   Defense options: (a) the main pipeline tick could update a
   "alarm seen alive" timestamp by reading
   `$PROJECT_STATE_DIR/.stuck-tick-last-alerted` and warning if too
   stale; (b) a third launchd agent monitors the second... infinite
   regress. **Recommended posture:** out of scope. Treat launchd's
   `launchctl list` introspection as the source of truth; document
   "check `launchctl list | grep com.twinning.stuck-tick-alarm`" in
   the recovery runbook as the operator escape hatch. Not blocking.

2. **OQ-2. Should the alarm cadence (15 min) be configurable?**
   Today the plist hardcodes `StartInterval=900`. Operators with
   very tight SLAs might want 5 min, very relaxed ones 30 min.
   **Recommended posture:** keep hardcoded. The cadence + threshold
   relationship is calibrated (15 min cadence + 30 min threshold
   alerts within 30-45 min wedged). Operators tuning either knob
   in isolation will degrade detection latency. If a configurable
   cadence becomes necessary, it can land in a follow-up via the
   same plist-render mechanism as `StartInterval=__INTERVAL__`. Not
   blocking.

3. **OQ-3. Should the heartbeat path include `holder_pid` so the
   alarm can detect "lock held but heartbeat stale" vs "no lock,
   heartbeat stale"?** Both surface as "stuck"; the holder-pid
   inspection in the payload already distinguishes them for the
   operator. No need to encode the distinction into the file path.
   Not blocking.

4. **OQ-4. Should the alarm payload include retrospective context
   (recent halt rate, recent failure outcome distribution)?** That
   would make the Slack post a mini-status report. **Recommended
   posture:** scope creep. The triage path is "alert → operator
   runs `bash bin/status.sh`." Don't duplicate the dashboard in
   every alert. Not blocking.

5. **OQ-5. Should `bin/setup.sh validate` cover the alarm plist
   load state?** Today validate covers env vars, file permissions,
   config parseability. Adding "alarm agent is in `launchctl list`"
   would close the watch-the-watcher gap for the manual validation
   path. Out of scope for ENG-132 (validate is `bin/setup.sh`'s
   surface, not the alarm's). File as a follow-up if the alarm
   regresses to dead-agent silent failures in practice. Not
   blocking.

## 8. ADR stress test

This brainstorm interacts with five existing decisions:

- **ENG-8 (run-local.sh single-flight lock, `mkdir`-based).** ENG-132
  does NOT change lock semantics. The lock continues to prevent
  overlapping ticks; the heartbeat is a parallel signal added after
  the success path. The alarm reads the lock's holder-pid file as
  decoration in the payload but does NOT manipulate the lock. Net
  pressure on ENG-8: zero.

- **ENG-21 / halt-sprawl alert (`_poll_emit_halt_sprawl_alert`).**
  ENG-132's alarm mirrors halt-sprawl's structure exactly:
  level-triggered metric + edge-triggered Slack + 24h debounce
  stamp. The two alarms are orthogonal (halt-sprawl: too many
  halted issues; stuck-tick: harness not running at all) and use
  separate debounce files (`.halt-sprawl-last-alerted` vs
  `.stuck-tick-last-alerted`). Net pressure on ENG-21: zero;
  rather, it's a positive reuse of the pattern.

- **ENG-65 (`gtimeout` per-stage dispatch wrapper).** ENG-65 is the
  agent-side watchdog (kills runaway `claude -p`). ENG-132 is the
  scheduler-side watchdog (alerts on stuck `run-local.sh` ticks).
  Layered defenses: ENG-65 catches the common case (dispatch hang);
  ENG-132 catches what slips past ENG-65 (whole-tick wedge). The
  2026-05-15 incident is documented evidence that ENG-65 alone is
  insufficient. Net pressure on ENG-65: zero; ENG-132 fills the
  exact gap memory note `gtimeout_watchdog_can_silently_fail.md`
  names.

- **ENG-81 (per-project dispatch concurrency, K=2 default).** With
  K=2, two long brainstorms could legitimately wedge the heartbeat
  for ~60 min. ENG-132's default threshold (30 min) means K=2
  concurrent legit brainstorms will produce one Slack alert. **This
  is a known false-positive cost, documented as a knob trade-off
  in D-002 / D-007.** Operators tune up to ~75 min to absorb the
  worst case. The alternative (no alarm at all) is the bug we're
  fixing. Net pressure on ENG-81: small documented operator-tuning
  cost; not a structural conflict.

- **ENG-67 (per-issue worktree invariant — never dispatch from
  `$TARGET_REPO`).** Unrelated surface. The alarm reads
  `$PROJECT_STATE_DIR`, not `$TARGET_REPO`. Net pressure on ENG-67:
  zero.

No existing ADR is overturned. The ENG-81 K=2 false-positive cost is
the only operator-visible coupling and is bounded by one config knob.

## 9. Assumption inventory

Format: `[verified|assumed]` ITEM — `path:line` reference (or "needs
to be created" for assumed items).

### Verified — code paths quoted from the current tree

- `[verified]` `bin/run-local.sh:81` writes `log "== tick start =="`.
- `[verified]` `bin/run-local.sh:504` writes `log "== tick end
  (success, ${#_claimed_workers[@]} worker(s)) =="` and is the LAST
  line of the success path before script exit.
- `[verified]` `bin/run-local.sh:37-44` declares `LOCK_DIR`,
  `TICK_COUNTER`, `FAIL_COUNTER`, `LOG_DIR`, `LOG_FILE` — the new
  `_write_tick_heartbeat` follows the same `$PROJECT_STATE_DIR/.*`
  pattern as `.tick-counter`.
- `[verified]` `bin/run-local.sh:51-54` is the silent-skip branch
  when `acquire_lock` fails — the bug class this ticket addresses.
- `[verified]` `bin/run-local-helpers.sh:916-934` is `acquire_lock`,
  with the `kill -0 holder` stale-pid recovery at lines 925-931.
  This recovers DEAD holders only; a wedged-but-alive holder
  (`wait`-blocked shell) passes the check.
- `[verified]` `bin/poll.sh:545-610` is `_poll_emit_halt_sprawl_alert`
  — the pattern ENG-132 mirrors: level-triggered metric on every
  fire above threshold (line 573-574), edge-triggered Slack with
  24h debounce (lines 577-607), debounce stamp at
  `$PROJECT_STATE_DIR/.halt-sprawl-last-alerted` (line 577).
- `[verified]` `bin/poll.sh:602` posts via `bash "$SCRIPT_DIR/slack.sh"
  warn "$msg" || true` — the `|| true` posture ENG-132 inherits.
- `[verified]` `bin/slack.sh:12-39` is the Slack chokepoint;
  `bin/slack.sh:16-19` no-ops when `PIPELINE_SLACK_WEBHOOK_URL` is
  unset, line 29-32 honors `PIPELINE_DRY_RUN=1`.
- `[verified]` `bin/common.sh:7-62` exports `HARNESS_ROOT`,
  `TARGET_REPO`, `HARNESS_STATE_DIR`, `PROJECT_SLUG`,
  `PROJECT_STATE_DIR`, `log`, `die`, `require_env`. Sourceable by
  `bin/stuck-tick-alarm.sh` for the same env contract every other
  script enjoys.
- `[verified]` `bin/metrics.sh:19-41` accepts
  `<event> <issue_id> <stage> <outcome> <duration_ms> [notes]` —
  ENG-132's `stuck-tick "" "" alert 0 "age=… …"` matches the
  signature (halt-sprawl uses the same empty-issue/empty-stage
  shape at `bin/poll.sh:573`).
- `[verified]` `launchd/com.twinning.pipeline.plist.template` and
  `launchd/com.twinning.retrospective.plist.template` are the two
  existing templates; `bin/install-launchd.sh:30-56` is the
  `install_one` helper, `bin/install-launchd.sh:58-59` is the two
  install calls. Adding a third template + third call is a literal
  copy-extend.
- `[verified]` `bin/install-launchd.sh:33` resolves `$kind.plist.template`
  by parameter — no hardcoded template names. `install_one
  stuck-tick-alarm 0` will resolve
  `$HARNESS_ROOT/launchd/com.twinning.stuck-tick-alarm.plist.template`.
- `[verified]` `bin/install-launchd-test.sh:13-23` stubs `launchctl`
  and captures invocations to `LAUNCHCTL_LOG` — the test extension
  asserts on a third row.
- `[verified]` `bin/halt-sprawl-test.sh:50-96` is the canonical
  source-and-stub fixture pattern: stub `linear.sh`, `metrics.sh`,
  `slack.sh`, then assert on capture files. `bin/stuck-tick-alarm-test.sh`
  uses the same shape (no Linear stub needed; the alarm doesn't
  read Linear).
- `[verified]` `bin/run-local.sh:17` sets `set -euo pipefail`. Edge
  case 9 (heartbeat write failure) requires explicit
  `|| log "heartbeat write failed"` to avoid terminating the script
  on disk-full.
- `[verified]` `bin/dispatch.sh:469-488`'s `_cfg_minutes` is the
  three-layer config precedence pattern (env > config > built-in
  default) — `_resolve_alarm_minutes` mirrors it.
- `[verified]` `bin/dispatch.sh:469-488` validates integer + range
  via `[[ "$v" =~ ^[0-9]+$ ]] && (( v >= 1 ))` — the alarm uses
  `>= 10` for the floor.
- `[verified]` `.githooks/pre-commit` runs every `bin/*-test.sh`
  automatically (per CLAUDE.md "Pre-commit hook") — no hook edit
  needed for the new test.
- `[verified]` Test sentinel pattern: `bin/run-local.sh` ends
  WITHOUT a `main` function (it runs top-level), so the sentinel
  doesn't apply to it. `bin/stuck-tick-alarm.sh` will follow the
  sentinel pattern (`if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"; fi`) per CLAUDE.md "How tests work."
- `[verified]` `docs/configuration.md:84-117` is the canonical
  per-stage knob documentation pattern (timeouts); the new section
  for `stuck_tick_alarm_minutes` follows the same shape.
- `[verified]` `docs/brainstorms/2026-05-15-eng-103-…-design.md` is
  the format precedent (frontmatter `linear: ENG-N`, numbered
  sections, persona-review at the end, assumption inventory with
  `path:line` references).
- `[verified]` The `bin/run-local-helpers.sh::acquire_lock` lock
  file format: directory `$LOCK_DIR/` containing `pid` file with
  the holder's PID. `_lock_holder_pid` reads
  `$PROJECT_STATE_DIR/.run-local.lock/pid`.
- `[verified]` `bin/run-local.sh:14` documents the 5-min launchd
  cadence ("every 5 minutes"); plist `StartInterval=300` at
  `launchd/com.twinning.pipeline.plist.template:20`.
- `[verified]` `bin/install-launchd.sh:46-49` calls `launchctl bootout`
  before bootstrap — operates per-label; adding a third label is a
  separate bootout cycle and doesn't disturb the existing two.
- `[verified]` `docs/knowledge/decisions.md` does NOT exist in this
  tree (`Glob 'docs/knowledge/*.md'` returns nothing); per
  brainstorm prompt's "skip if not present," proposed ADRs live
  in §10 below.
- `[verified]` `bin/pipeline-events.json:10-21` lists `halt_reasons`
  — `iteration-exhausted` and `agent-blocked` are the valid tokens
  for the verdict-halt path (used in §11 if needed).
- `[verified]` Memory note `gtimeout_watchdog_can_silently_fail.md`
  records the 2026-05-15 incident as 5h 43m past 1h budget — this
  brainstorm's motivating incident.

### Assumed — needs verification or new code

- `[assumed]` `stat -f %m "$file"` (macOS) returns mtime in epoch
  seconds; `$(date -u +%s) - $(stat -f %m "$file")` gives the age.
  **TODO during implement:** verify on the launchd host; fallback
  is `stat -f %m` (macOS BSD) vs `stat -c %Y` (GNU). The script
  should `command -v stat | xargs stat -f %m "$file"` style
  branch, or simply use `awk` / `date -r "$file" +%s` (the
  latter works on macOS and is one-shot).
- `[assumed]` `launchctl bootstrap gui/$(id -u) <plist>` with a
  third plist alongside the existing two does not produce label
  collisions. Verified by inspection: labels are
  `com.twinning.pipeline.<slug>`, `com.twinning.retrospective.<slug>`,
  `com.twinning.stuck-tick-alarm.<slug>` — three distinct prefixes.
  **TODO during implement:** smoke-test `launchctl list | grep
  com.twinning` post-install to confirm all three load.
- `[assumed]` `ps -p <pid> -ef` (or equivalent) returns the holder
  process line. `pgrep -P <pid>` lists children. Both are available
  on macOS by default. **TODO during implement:** verify exact
  flags on the macOS `ps` (BSD), since GNU `ps -ef` and BSD `ps -ef`
  differ subtly. The simplest correct form is `ps -p <pid> -o
  pid,ppid,user,command` for the holder line, separately invoked.
- `[assumed]` The alarm script's `tail -n 40 "$LOG_FILE"` invocation
  on the current day's `local-YYYY-MM-DD.log` returns recent context.
  If the wedge spans midnight, the log file rolled over and the tail
  shows the new day's (empty) log. **TODO during implement:** read
  the file with mtime closest to the heartbeat mtime, or read both
  current and previous day's tails. Bounded to a few extra lines;
  not a correctness issue.
- `[assumed]` The alarm payload's Slack-friendly markdown rendering
  is reasonable. Slack's webhook accepts the `{"text": "…"}` shape
  `bin/slack.sh:34-37` already uses; line-break-separated content
  renders as a multi-line message. **TODO during implement:**
  smoke-test the payload formatting via a one-shot manual invocation
  against a dev Slack channel.
- `[assumed]` `mv -f "$tmp" "$heartbeat_file"` is atomic on the
  underlying APFS filesystem (standard POSIX rename guarantees on
  macOS). Verified by inspection: `bin/common.sh::140-154`
  (`_allocate_dispatch_id_locked`) uses the same `mv -f` pattern
  for `issue-state.json` — established precedent.
- `[assumed]` Test fixture for "fresh heartbeat" uses `touch -d`
  to backdate mtime. macOS `touch -d` accepts ISO-8601 format. If
  not, use `touch -t YYYYMMDDhhmm.SS`. **TODO during test
  authoring:** confirm exact flags.
- `[assumed]` The 30-min default threshold absorbs ~6 silent skips
  per the K=2 K=1 calculus. Realistic operator data from the
  ENG-81 production rollout would refine this. **Post-merge
  spot-check:** observe Slack volume for 7 days; if false positives
  exceed ~1/week per project, raise the default to 45 min.

## 10. Proposed ADRs

Filed inline here because `docs/knowledge/decisions.md` does not
exist (per the brainstorm prompt's "skip if not present" clause).

### ADR-001 (proposed): External heartbeat-observer for run-local.sh liveness

**Status:** proposed
**Date:** 2026-05-17
**Context:** Every alarm path in the harness today runs inside the
tick (`_poll_emit_halt_sprawl_alert`, in-tick `slack.sh` calls,
`gtimeout` around `claude -p`). When the entire tick is wedged
(e.g., the 2026-05-15 dispatch hang), all in-tick alarms are also
wedged. The lock's stale-pid recovery fires only on DEAD holders;
a wedged-but-alive holder is silent.
**Decision:** Add a per-tick atomic heartbeat write to
`$PROJECT_STATE_DIR/.last-tick-end` plus an independent launchd
agent (`com.twinning.stuck-tick-alarm.<slug>`, every 15 min) that
observes the heartbeat mtime and POSTs to Slack via
`bin/slack.sh warn` when age > threshold. Mirror the halt-sprawl
alert's pattern: level-triggered `metrics.sh` event on every fire +
edge-triggered Slack with 24h debounce.
**Consequences:**
- Recovery: hangs surface in operator Slack within 30-45 min vs
  multi-hour silent outages today.
- Cost: one `date` + one rename per tick; one launchd plist; one
  bash script + sibling test; ~30 lines of CLAUDE.md/configuration.md
  doc.
- Risk: K=2 concurrent legitimate slow brainstorms could produce one
  false-positive Slack alert per stuck-tick window. Bounded by one
  config knob (`orchestrator.stuck_tick_alarm_minutes`, default 30,
  floor 10). Operators with high false-positive rates tune up to
  ~75 min.
- Operator surface: one config knob, one Slack channel, one
  CLAUDE.md subsection + one failure-mode-table row.
**Alternatives rejected:** Embed `gtimeout` inside `run-local.sh`
(same process tree, silently fails the same way the dispatch-level
`gtimeout` did). Replace lock's `kill -0` with "alive but stale"
reclaim (masks the wedge rather than surfacing it). Build a daemon
or PagerDuty integration (scope creep beyond CLAUDE.md
"Don't add features... beyond what the task requires").

### ADR-002 (proposed): Heartbeat write site immediately after success-log line

**Status:** proposed
**Date:** 2026-05-17
**Context:** The heartbeat write must distinguish "tick completed"
from "tick wedged or crashed." Placement determines what kinds of
incomplete-tick states surface as alarms vs are masked.
**Decision:** Write the heartbeat IMMEDIATELY AFTER the existing
`log "== tick end (success, …)"` line at `bin/run-local.sh:504`,
not before. A tick that reaches the success log line has finished
its critical-path work; one that hasn't has wedged or crashed.
Wrap the write in `|| log "heartbeat write failed"` so a disk-full
condition doesn't terminate the script under `set -euo pipefail`.
**Consequences:**
- Crashed early-tick paths (env-load failure, breaker trip, lock
  acquire fail) do NOT write a heartbeat; alarm fires after the
  threshold elapses. **Correct** — these are surfaceable failures.
- Tick that completes successfully but fails the release-watcher
  (post-success) still gets a fresh heartbeat (write happens
  before the release-watcher). The release-watcher's own failure
  surface (log line) is the appropriate signal there.
- Atomic write (temp + rename) prevents a torn line on
  concurrent reader.
**Alternatives rejected:** Write at every tick boundary regardless
of success (would mask the wedge — same shape as the existing
`.tick-counter` write at line 442, which doesn't help here). Write
only inside `cleanup_on_exit` (would write even on `acquire_lock`
fail, masking the wedge case).

## 11. Persona review

Personas applied in the mandated order:
design → security → scope → coherence → product → feasibility
(gating).

### Iteration 1

#### design — PASS

D-001 (heartbeat + external observer), D-002 (config knob), D-003
(Slack payload), D-004 (launchd plist), D-005 (metric), D-006 (test
surface), D-007 (operator doc) compose cleanly: D-001 is the "what
to detect" decision; D-002 is the "how sensitive" decision; D-003
is the "what does the alert contain" decision; D-004 is the "how
the observer runs" decision; D-005, D-006, D-007 are observability,
verification, and operator-facing surfaces.

The pattern (level-triggered metric + edge-triggered Slack +
debounce stamp) mirrors `_poll_emit_halt_sprawl_alert`
(`bin/poll.sh:545-610`) exactly. The three-layer config precedence
(env > config > default) mirrors ENG-65's `_cfg_minutes`
(`bin/dispatch.sh:469-488`) and ENG-81's `_resolve_K`. No new
abstractions, no new modules, no daemon.

The placement of the heartbeat write (after the success log line,
not in a trap or earlier) correctly distinguishes "tick completed"
from "tick wedged" — the discriminating signal the alarm reads.

No P0 / P1. One P2: D-006's AC-MISSING-HEARTBEAT and
AC-MALFORMED-TIMESTAMP cases overlap conceptually (both end in
"alarm fires"); the test fixture should clearly distinguish
"absent file" from "present but malformed" so a future regression
that handles only one is caught. Acceptable.

#### security — PASS

No new auth surface. No secret material in the heartbeat file (just
an ISO timestamp). The Slack payload contains `holder_pid` and a
`ps -ef` excerpt — `ps` output may surface environment variables
to the operator's Slack channel. **Mitigation:** use `ps -p <pid>
-o pid,ppid,user,command` rather than `ps -ef | grep`, which scopes
output to non-secret columns. The `command` column may itself
contain CLI args; the harness's `claude -p` invocation does NOT
pass secrets via argv (`ANTHROPIC_API_KEY` is intentionally never
set per CLAUDE.md). Safe.

ENG-46 secret-handling: the new script does NOT use any
`${VAR:-FALLBACK}` form against secret-named env vars
(`STUCK_TICK_ALARM_MINUTES` is non-secret; the `${VAR-}` empty-fallback
form is canonical-safe). `bin/secret-probe-lint.sh` will catch any
drift.

The new launchd plist's `EnvironmentVariables` block does NOT
inject `LINEAR_API_KEY` or `GH_APP_*` (the alarm doesn't talk to
Linear or GitHub). Reduces blast-radius for the alarm plist.

No P0 / P1. One P1 flagged → mitigated inline (`ps -p <pid> -o`
rather than `ps -ef | grep`).

#### scope — PASS

The brainstorm addresses every AC from the Linear issue's
"Proposed fix shape" §:

- Fix shape §1 (heartbeat file write): D-001.
- Fix shape §2 (alarm script reads mtime + Slack + debounce):
  D-001 + D-003 + D-005.
- Fix shape §3 (independent launchd plist every 15 min): D-004.
- Fix shape §4 (alert payload with mtime/age, lock pid + ps,
  log tail): D-003.
- Config (orchestrator.stuck_tick_alarm_minutes, default 30,
  min 10): D-002.
- Tests (stuck-tick-alarm-test.sh with 5 specific cases): D-006
  (expanded to 10 cases for fuller coverage including env override
  and config validation, but all 5 mandated cases are present —
  AC-FRESH, AC-STALE, AC-DEBOUNCED, AC-MISSING-HEARTBEAT,
  AC-MALFORMED-TIMESTAMP map 1:1).
- "Why external" rationale: D-001's rejected-alternatives section
  + ADR-001 context.

Nothing implemented beyond the Linear ticket's scope:

- Per-issue stuck-stage alarms — explicitly out of scope per Linear
  "Out of scope" §2.
- PagerDuty / Honeycomb migration — explicitly out of scope per
  Linear "Out of scope" §3.
- Underlying dispatch hang — explicitly out of scope per Linear
  problem statement (filed separately as Bug).
- Configurable cadence — OQ-2 defers.
- Alarm-watching-the-alarm — OQ-1 defers.
- Retrospective context in alert payload — OQ-4 defers.

The brainstorm extends slightly past minimum scope only on tests
(10 cases vs 5 named in the issue). Justified because the extra 5
cover config validation and env-override paths the ENG-65 / ENG-81
precedent treats as load-bearing — same pattern, same coverage
expectation.

No P0 / P1 / P2 findings.

#### coherence — PASS

Internal consistency check:

- D-001's heartbeat path
  (`$PROJECT_STATE_DIR/.last-tick-end`) follows the pattern
  of every other per-project state file (`.tick-counter`,
  `.consecutive-failures`, `.halt-sprawl-last-alerted`,
  `.run-local.lock`). No new directory.
- D-002's config key (`orchestrator.stuck_tick_alarm_minutes`)
  sits alongside `orchestrator.dispatch_timeout_minutes`,
  `orchestrator.max_concurrent_features`, `orchestrator.paused`,
  `orchestrator.alert_on_halted_over`, `orchestrator.entry_conditions`
  in the same namespace. Precedence (env > config > default)
  matches ENG-65 / ENG-81 / ENG-86. Resolution helper name
  (`_resolve_alarm_minutes`) mirrors `_resolve_K` /
  `_resolve_dispatch_model`.
- D-003's payload structure matches the `_poll_emit_halt_sprawl_alert`
  payload (top-N identifiers + count + threshold). Decoration
  fields (holder pid, ps excerpt, log tail) are alarm-specific
  but follow the "operator can triage from Slack alone" principle.
- D-004's plist template extends the existing two; the
  `install_one` helper already parameterizes correctly without
  modification (verified at `bin/install-launchd.sh:33`).
- D-005's metric event name (`stuck-tick`) follows the existing
  kebab-case convention for metric event names
  (`halt-sprawl`, `stage-start`, `stage-end`, `dispatch-resource-sample`,
  `sweep-readonly-residue-cleaned`).
- D-006's test follows the source-and-stub pattern
  (`bin/halt-sprawl-test.sh:50-106`).

Vocabulary check: `stuck-tick` is a metrics-event name, not a Linear
marker. `bin/pipeline-events.json:44-51`'s `meta_kinds` (`dedup,
metric, evidence, reapplied, forensic, dispatch`) is the Linear
HTML-comment vocabulary, not the metrics event vocabulary. The
metrics.sh event surface is open per
`bin/metrics-test.sh` precedent (events like `dispatch-resource-sample`
are not in the JSON registry either). No registry edit needed.

Lane check (per CLAUDE.md "Label vocabulary"): the alarm script runs
under launchd, not as an agent. It does NOT write to Linear. The
`PIPELINE_WRITER` env var is irrelevant (no Linear writes occur).
The alarm's only external surface is Slack; Slack is lane-free.

No P0 / P1 / P2 findings.

#### product — PASS

Operator workflow audit:

1. **Today (pre-ENG-132):** stuck-tick incidents are silent for
   hours. Operator notices via dashboard inspection or external
   complaint. MTTD measured in hours.
2. **After ENG-132:** stuck-tick incidents fire a Slack alert within
   30-45 min of the wedge. Payload includes enough triage info that
   the operator can either `launchctl kickstart -k …` the pipeline
   plist (force restart) or investigate the holder process.
3. **False-positive cost:** at K=2 with a 60-min brainstorm and
   30-min threshold, the operator gets ONE Slack message per
   stuck-tick window. The 24h debounce prevents flood; the operator
   sees one alert per legitimate slow brainstorm at most per day.
   Operators can tune `stuck_tick_alarm_minutes: 75` to absorb the
   worst K=2 case if the false-positive rate is bothersome.
4. **No regression for the happy path:** healthy harnesses see no
   alerts. The heartbeat write costs <10ms per tick.

CLAUDE.md doc edit (D-007) gives operators the recovery recipe
(`launchctl kickstart -k`) and the config-tuning knob in one place.

No P0 / P1 / P2 findings.

#### feasibility (gating) — PASS

Codebase-fact verification re-run against the current tree (every
`path:line` in §3 Architecture and §9 Assumption Inventory was
opened and quoted during draft):

- `bin/run-local.sh:81` — `log "== tick start =="` ✓
- `bin/run-local.sh:504` — `log "== tick end (success, …) =="` ✓
  (verified end-of-script line; `_write_tick_heartbeat` inserts
  immediately after).
- `bin/run-local.sh:17` — `set -euo pipefail` ✓ (edge case 9
  requires explicit `|| log` to handle write failure).
- `bin/run-local.sh:37-44` — `PROJECT_STATE_DIR/.*` state file
  pattern ✓.
- `bin/run-local.sh:51-54` — silent-skip on lock acquire fail ✓
  (the bug-class branch).
- `bin/run-local-helpers.sh:916-934` — `acquire_lock` with
  `kill -0 holder` stale-pid recovery ✓.
- `bin/poll.sh:545-610` — `_poll_emit_halt_sprawl_alert` (mirror
  pattern for the alarm) ✓.
- `bin/poll.sh:573-574` — level-triggered metric pattern ✓.
- `bin/poll.sh:577` — debounce file at
  `$PROJECT_STATE_DIR/.halt-sprawl-last-alerted` ✓.
- `bin/poll.sh:602` — `bash "$SCRIPT_DIR/slack.sh" warn "$msg" ||
  true` pattern ✓.
- `bin/slack.sh:12-39` — chokepoint; `:16-19` no-op when webhook
  unset; `:29-32` dry-run handling ✓.
- `bin/common.sh:7-62` — env contract (HARNESS_ROOT, TARGET_REPO,
  PROJECT_STATE_DIR, log, die, require_env) ✓.
- `bin/metrics.sh:19-41` — accepts `<event> <issue> <stage>
  <outcome> <duration_ms> [notes]` signature ✓.
- `bin/dispatch.sh:469-488` — `_cfg_minutes` three-layer
  resolution precedent for `_resolve_alarm_minutes` ✓.
- `launchd/com.twinning.pipeline.plist.template` — template
  structure to copy for the new plist ✓.
- `launchd/com.twinning.retrospective.plist.template` — second
  reference for `RunAtLoad: false` shape ✓.
- `bin/install-launchd.sh:30-56` — `install_one` helper,
  parameterized on `kind` ✓ (template resolution at line 33 picks
  up any `com.twinning.$kind.plist.template`).
- `bin/install-launchd.sh:58-59` — two existing `install_one` calls
  ✓ (adding a third is a one-line edit).
- `bin/install-launchd-test.sh:13-23` — `launchctl` stub + capture
  pattern ✓.
- `bin/halt-sprawl-test.sh:50-106` — source-and-stub test pattern
  ✓.
- `bin/pipeline-events.json:10-21` — halt_reasons registry ✓
  (irrelevant to the alarm but referenced for §11 verdict tokens).
- `docs/configuration.md:84-117` — per-stage knob doc precedent ✓.
- `docs/brainstorms/2026-05-15-eng-103-…-design.md` — brainstorm
  format precedent ✓.
- `docs/knowledge/decisions.md` — DOES NOT EXIST (confirmed via
  Glob); ADRs filed inline in §10 per the brainstorm prompt's
  "skip if not present" clause ✓.
- Memory note `gtimeout_watchdog_can_silently_fail.md` — 5h 43m
  hang on 2026-05-15 is the motivating incident ✓.

Outstanding assumed items in §9:

- `stat -f %m` (macOS BSD) vs `date -r FILE +%s` for mtime
  extraction — high-confidence, both are macOS-default. **NOT a
  P0** because the failure mode is graceful (script exits non-zero;
  launchd retries next interval). Test fixture pins behavior.
- `launchctl bootstrap` of a third plist alongside two existing —
  high-confidence (distinct labels). **NOT a P0** because
  `install-launchd-test.sh` captures the bootstrap call.
- `ps -p <pid> -o pid,ppid,user,command` flag combination —
  high-confidence (POSIX-portable). **NOT a P0** because malformed
  ps output degrades the payload (operator still sees the alert
  with the holder PID), not the alarm decision.
- Slack payload formatting — high-confidence (text-mode webhooks
  accept newline-separated content). **NOT a P0** because the
  metric row remains the durable record even if Slack formatting
  surprises.
- `mv -f` atomicity on APFS — already-precedent at
  `bin/common.sh:140-154` for `issue-state.json`. **NOT a P0.**
- 30-min default threshold — operational tuning. **NOT a P0**
  because the knob is config-tunable per D-002.

No P0 findings. Every code-level reference resolves to a real line
in the current tree. Every named function / file / template /
config key exists or is being explicitly proposed as a new file.
The proposed edits are local additions to existing helpers
(`install_one` reused as-is, three-layer config precedence reused
verbatim, halt-sprawl pattern reused verbatim) — no structural
rewrites.

### Iteration 1 verdict

| Persona | Verdict | P0 | P1 |
|---|---|---|---|
| design | PASS | 0 | 0 |
| security | PASS | 0 | 0 |
| scope | PASS | 0 | 0 |
| coherence | PASS | 0 | 0 |
| product | PASS | 0 | 0 |
| feasibility (gating) | PASS | 0 | 0 |

**6/6 PASS · gate P0: 0** — gate cleared on iteration 1. No iteration
2 needed.

### Final verdict

`status = clean` — proceeding to planning. The brainstorm proposes
seven composable changes (D-001 heartbeat write + external observer,
D-002 config knob, D-003 Slack payload, D-004 launchd plist, D-005
metric, D-006 test surface, D-007 operator doc) bounded by the seven
ACs in the Linear issue's "Proposed fix shape" §, mirroring three
established patterns (halt-sprawl alert, ENG-65 / ENG-81 config
precedence, source-and-stub tests), with no overturned ADRs and one
documented K=2-brainstorm-overlap false-positive trade-off bounded
by one config knob.
