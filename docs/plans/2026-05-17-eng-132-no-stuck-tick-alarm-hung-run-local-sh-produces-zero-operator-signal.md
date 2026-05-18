---
linear: ENG-132
date: 2026-05-17
topic: External heartbeat-observer launchd job that posts Slack when run-local.sh has not completed a tick within the configured threshold
---

# Plan — ENG-132 stuck-tick alarm (external observer of run-local.sh heartbeat)

## Anti-anchoring check

**Problem restatement (user view):** "When `run-local.sh` is wedged the
operator gets zero signal — every alarm path lives inside the wedged
tick, so silent multi-hour outages happen (5h 43m on 2026-05-15).
There needs to be a watcher running outside the stuck process."

**Does the brainstorm address this?** Yes. D-001 puts an atomic
heartbeat write at the success-log line and an *independent* launchd
job (`com.twinning.stuck-tick-alarm.<slug>`) that reads its mtime.
Everything else (D-002 config knob, D-003 Slack payload, D-004 plist,
D-005 metric, D-006 tests, D-007 doc) is in service of that one
decision. No reframing.

**Solution proportionality:** Two new files (`bin/stuck-tick-alarm.sh`,
`bin/stuck-tick-alarm-test.sh`), one new launchd template, one
heartbeat line in `bin/run-local.sh`, one `install_one` call in
`bin/install-launchd.sh` (plus the symmetric `uninstall_one` and the
`is_launchd_done` superset check the brainstorm didn't surface but
the codebase requires for setup-phase correctness), one new config
knob with the standard three-layer precedence, two operator-doc
edits. Mirrors the existing `_poll_emit_halt_sprawl_alert` pattern
exactly. **Proportional — proceed without escalation.**

## Branch-base freshness check

`git fetch origin main && git log --oneline HEAD..origin/main` was
NON-EMPTY at plan time. origin/main HEAD at plan time = `81a2206`.
Drift since this branch was cut spans ~30 commits across several
sibling tickets (ENG-145, ENG-146, ENG-131, ENG-135, ENG-133,
ENG-140, ENG-138, ENG-110, ENG-109, ENG-144, ENG-122, ENG-100,
ENG-103, ENG-87, ENG-94, ENG-77 follow-ups).

Material drift scan against this plan's File Structure:

- `bin/run-local.sh` — line numbers may shift; the heartbeat
  insert uses a unique literal-string content anchor
  (`log "== tick end (success, ${#_claimed_workers[@]} worker(s)) =="`)
  rather than a bare line number, so the insert survives the
  rebase.
- `bin/install-launchd.sh`, `bin/uninstall-launchd.sh`,
  `bin/setup.sh::is_launchd_done`, `bin/install-launchd-test.sh`,
  `bin/poll.sh::_poll_emit_halt_sprawl_alert`, `bin/slack.sh`,
  `bin/common.sh::_resolve_K`, `bin/metrics.sh`,
  `bin/dispatch.sh::_cfg_minutes`, `bin/halt-sprawl-test.sh`,
  `launchd/com.twinning.{pipeline,retrospective}.plist.template`,
  `docs/configuration.md`, `CLAUDE.md` — none of these are rewritten
  in the visible HEAD..origin/main range (sibling commits touch
  `bin/run-stage.sh`, `bin/dispatch.sh::_render_and_capture_stream`,
  `bin/guards.sh`, `bin/scope-check.sh`, prompt body of
  `AGENT_PROMPTS.md §3`, the planning prompt itself, and ENG-122's
  plan-schema files). Visual inspection of the post-rebase tree is
  still required (Task 0).

Per the planning prompt's "branch-base freshness check," Task 0
below mandates the rebase before any other task so subsequent
`path:line` hints (and the test-gate closure sweep) anchor against
the post-rebase tree. After rebase, the implement agent
re-verifies every content anchor in this plan still resolves
before applying its task; if any anchor has moved or been
rewritten, the implement agent halts per Task 0's stop-clause and
requests `pipeline:supersede`.

## 1. Goal

Add an external launchd-driven watcher
(`bin/stuck-tick-alarm.sh` + `launchd/com.twinning.stuck-tick-alarm.plist.template`)
that reads the mtime of a per-tick atomic heartbeat file written by
`bin/run-local.sh`, and Slack-pings via `bin/slack.sh warn` when the
heartbeat exceeds the configurable threshold
(`orchestrator.stuck_tick_alarm_minutes`, default 30, floor 10), so a
wedged tick surfaces in operator chat within ~30-45 min instead of
producing silent multi-hour outages.

Verifiable outcome:
- `bash bin/stuck-tick-alarm-test.sh` exits 0 (covers the 10 AC cases
  named in §6 of this plan: fresh / stale / debounced / missing
  heartbeat / malformed timestamp / config default / config override /
  config below floor / config non-integer / env override).
- `bash bin/install-launchd-test.sh` continues to pass after the
  third plist is added (covers plist render + bootstrap symmetry).
- `bash bin/run-local-content-test.sh` continues to pass after the
  `_write_tick_heartbeat` call is added at the success-log line
  (covers structural assertions against `bin/run-local.sh`).
- Manual smoke: `bash bin/stuck-tick-alarm.sh` from the CLI against a
  fresh heartbeat exits 0 silently; same invocation with the
  heartbeat backdated past threshold posts to the configured Slack
  webhook (or no-ops cleanly when `PIPELINE_SLACK_WEBHOOK_URL` is
  unset).

## 2. Assumption Inventory

Format: `[verified|assumed]` ITEM — `path:line` reference (or
`assumed/new` with the target path).

branch-base freshness: HEAD..origin/main NON-EMPTY at plan time
(~30 commits drift across sibling tickets, none rewriting this
plan's File Structure entries; Task 0 below mandates rebase before
any other task). origin/main HEAD at plan time = `81a2206`.

### Verified — quoted from the current tree

- `[verified]` `bin/run-local.sh:17` — `set -euo pipefail`. Edge case
  in §6 (heartbeat write failure under disk-full) requires explicit
  `|| log "..."` to avoid terminating the tick on a heartbeat error.
- `[verified]` `bin/run-local.sh:37-44` — declares `LOCK_DIR`,
  `FAIL_COUNTER`, `TICK_COUNTER`, `LOG_DIR`, `LOG_FILE` as
  `$PROJECT_STATE_DIR/.*` paths. The new heartbeat file
  (`$PROJECT_STATE_DIR/.last-tick-end`) follows the same pattern.
- `[verified]` `bin/run-local.sh:51-54` — silent-skip branch when
  `acquire_lock` returns 1. This is the bug-class branch the alarm
  surfaces: a wedged-but-alive holder makes every subsequent tick
  silent-skip with no alarm.
- `[verified]` `bin/run-local.sh:81` — `log "== tick start =="`.
- `[verified]` `bin/run-local.sh:504` (current end-of-script) —
  `log "== tick end (success, ${#_claimed_workers[@]} worker(s)) =="`.
  This is the LAST line of the success path. The heartbeat write
  inserts IMMEDIATELY AFTER this line. Content anchor: the literal
  string `log "== tick end (success, ${#_claimed_workers[@]} worker(s)) =="`.
- `[verified]` `bin/run-local-helpers.sh:916-934` — `acquire_lock`
  with the `kill -0 holder` stale-pid recovery at lines 925-931. The
  recovery fires ONLY on DEAD holders; a wedged-but-alive holder
  (e.g. blocked on `wait`) passes this check, which is exactly the
  failure mode ENG-132 surfaces.
- `[verified]` `bin/poll.sh:545-610` — `_poll_emit_halt_sprawl_alert`
  is the pattern this plan mirrors. Specifically:
  - `bin/poll.sh:573-574` — level-triggered metric every fire above
    threshold (`bash "$SCRIPT_DIR/metrics.sh" halt-sprawl "" "" alert 0
    "count=$count threshold=$threshold" || true`).
  - `bin/poll.sh:577` — debounce file at
    `$PROJECT_STATE_DIR/.halt-sprawl-last-alerted`.
  - `bin/poll.sh:580-589` — read previous stamp; unparseable content
    → `last_epoch=0` → next fire posts. `bin/stuck-tick-alarm.sh`
    re-uses this exact parsing shape.
  - `bin/poll.sh:592` — 24h gate (`(( now_epoch - last_epoch > 86400 ))`).
  - `bin/poll.sh:602` — `bash "$SCRIPT_DIR/slack.sh" warn "$msg" ||
    true` posture (`|| true` so a Slack failure doesn't terminate
    the alarm under `set -euo pipefail`).
  - `bin/poll.sh:604` — `date -u +%Y-%m-%dT%H:%M:%SZ > "$debounce_file"`
    after firing.
- `[verified]` `bin/slack.sh:12-39` — chokepoint. `:16-19` no-ops
  when `PIPELINE_SLACK_WEBHOOK_URL` is unset. `:29-32` honours
  `PIPELINE_DRY_RUN=1`. The alarm pipes its payload through this
  helper unchanged.
- `[verified]` `bin/common.sh:7-62` — `HARNESS_ROOT`, `TARGET_REPO`,
  `HARNESS_STATE_DIR`, `PROJECT_SLUG`, `PROJECT_STATE_DIR`, `log`,
  `die` are exported. `bin/stuck-tick-alarm.sh` sources `common.sh`
  to inherit these. `set -euo pipefail` at line 7 propagates.
- `[verified]` `bin/common.sh:30-37` — `log` and `die` helpers.
- `[verified]` `bin/common.sh:619-642` — `_resolve_K`. Three-layer
  resolution precedent (env > config > built-in default) the new
  `_resolve_alarm_minutes` mirrors. Validates integer + `>= 1`; on
  failure falls through with a `log` warning. The new helper uses
  the same shape with floor `>= 10`.
- `[verified]` `bin/metrics.sh:19-41` — signature
  `<event> <issue_id> <stage> <outcome> <duration_ms> [notes…]`.
  ENG-132 uses `stuck-tick "" "" alert 0 "age=… threshold=… holder_pid=…"`
  matching the halt-sprawl call shape at `bin/poll.sh:573`.
- `[verified]` `bin/dispatch.sh:513-545` — `_cfg_minutes` block
  (`orchestrator.dispatch_timeout_minutes_per_stage` → global →
  default 60/30). This is the structural precedent for the new
  `_resolve_alarm_minutes` (note: the brainstorm cited the older
  range `:469-488`; current tree is `:513-545`. The pattern is
  unchanged — env-or-config-jq-read, `^[0-9]+$` regex guard,
  fall-through on failure).
- `[verified]` `bin/install-launchd.sh:30-56` — `install_one` helper
  parameterized on `kind`. Template path is resolved on line 33 as
  `$HARNESS_ROOT/launchd/com.twinning.${kind}.plist.template`; the
  new `com.twinning.stuck-tick-alarm.plist.template` is picked up
  automatically once `install_one stuck-tick-alarm 0` is added.
- `[verified]` `bin/install-launchd.sh:58-59` — exactly two existing
  `install_one` calls (`pipeline 1`, `retrospective 0`). Content
  anchor for the new call: AFTER `install_one retrospective 0`
  BEFORE the `cat <<EOF` heredoc.
- `[verified]` `bin/install-launchd.sh:61-67` — trailing summary
  heredoc that lists currently-installed labels. Must extend with a
  third line for the alarm label so the operator-visible summary
  stays accurate.
- `[verified]` `bin/uninstall-launchd.sh:46-47` — exactly two
  existing `uninstall_one` calls (`pipeline`, `retrospective`).
  Content anchor for the new call: AFTER `uninstall_one retrospective`
  (the last line of the file). Required for symmetry — without it
  `bash bin/uninstall-launchd.sh` would leave the alarm plist
  loaded indefinitely.
- `[verified]` `bin/setup.sh:601-603` — `is_launchd_done()` iterates
  `for label in "com.twinning.pipeline.$slug" "com.twinning.retrospective.$slug"`.
  Setup considers the launchd phase "done" only when both are
  loaded. The new alarm label MUST be added to this list or the
  phase becomes permanently incomplete on existing installs.
  Content anchor: the `for label in "com.twinning.pipeline.$slug"
  "com.twinning.retrospective.$slug"; do` line.
- `[verified]` `bin/install-launchd-test.sh:13-23` — stubs
  `launchctl` and appends every invocation to `LAUNCHCTL_LOG`. The
  new assertion in §6 reads this log to confirm the third
  `bootstrap … com.twinning.stuck-tick-alarm.foo.plist` row exists.
- `[verified]` `bin/install-launchd-test.sh:84-91` — existing
  `[[ -f "$HOME/Library/LaunchAgents/com.twinning.pipeline.foo.plist" ]]`
  and `[[ -f … retrospective.foo.plist ]]` assertions. The third
  plist's file-exists assertion lands here as a sibling.
- `[verified]` `bin/install-launchd-test.sh:113-117` — the uninstall
  surgical-removal assertion (`foo` gone, `bar` intact). Already
  exercises `bin/uninstall-launchd.sh`; the third uninstall_one
  call gets implicit coverage on the same path. An explicit
  assertion on `com.twinning.stuck-tick-alarm.foo.plist` absence
  after uninstall is added.
- `[verified]` `bin/halt-sprawl-test.sh:1-115` — source-and-stub
  fixture pattern: `STUB_DIR=$(mktemp -d)`, stub `linear.sh` /
  `metrics.sh` / `slack.sh` at `$STUB_DIR/*`, source `poll.sh`,
  post-source override `SCRIPT_DIR=$STUB_DIR`. `bin/stuck-tick-alarm-test.sh`
  uses the same shape (`linear.sh` stub is unnecessary — the alarm
  doesn't read Linear).
- `[verified]` `launchd/com.twinning.pipeline.plist.template` —
  template structure to copy. Key fields the new template
  preserves: `Label`, `ProgramArguments`, `WorkingDirectory`,
  `StartInterval` (300 → 900), `RunAtLoad` (true → false),
  `ThrottleInterval`, `StandardOut/ErrorPath`, `EnvironmentVariables`
  (PATH, HOME, TARGET_REPO, HARNESS_STATE_DIR, PROJECT_SLUG).
- `[verified]` `launchd/com.twinning.retrospective.plist.template:34-35`
  — `<key>RunAtLoad</key><false/>` (second reference for the
  no-fire-at-load shape).
- `[verified]` `.githooks/pre-commit:151-177` — globs `bin/*-test.sh`,
  runs each, fails the commit on any non-`KNOWN_BROKEN` failure.
  Adding `bin/stuck-tick-alarm-test.sh` automatically registers it
  in the gate — no hook edit needed.
- `[verified]` `bin/run-local-content-test.sh` exists and asserts
  structural properties of `bin/run-local.sh`. The new
  `_write_tick_heartbeat` call site is at the same line range that
  the test currently covers — see test-gate closure sweep below.
- `[verified]` `docs/configuration.md:84-103` — canonical per-knob
  documentation pattern (`orchestrator.dispatch_timeout_minutes` +
  `_per_stage` subsections). The new `orchestrator.stuck_tick_alarm_minutes`
  section mirrors this depth (~30 lines).
- `[verified]` `docs/configuration.md:123-154` —
  `orchestrator.max_concurrent_features` section (the immediate
  template for the new section). Content anchor for the new
  insertion: AFTER the `bash bin/status.sh` example block of the
  `max_concurrent_features` section BEFORE the next H3 heading.
- `[verified]` `CLAUDE.md:781-815` — "Per-project dispatch
  concurrency (ENG-81)" subsection. The new "Stuck-tick alarm
  (ENG-132)" subsection lands BETWEEN this section (ending with
  `**Emergency rollback** (no deploy needed)…`) and the
  "What `--action continue` clears (atomic):" block. Content
  anchor: AFTER `Per-project rollback: edit that target's
  \`config.json::orchestrator.max_concurrent_features\` to 1.`
  BEFORE `**What \`--action continue\` clears (atomic):**`.
- `[verified]` `CLAUDE.md:723-779` — "Failure-mode quick reference"
  table. The new "Slack message 'Stuck tick alarm'" row lands as
  the LAST row before the closing of the table (the markdown table
  continues until the next H2/H3 header at line 781). Content
  anchor: AFTER the existing `Concurrent dispatches not running…`
  row BEFORE the next `## ` header.
- `[verified]` `bin/pipeline-events.json` — `stuck-tick` is a
  metrics-event name, NOT a Linear marker; the events.jsonl event
  surface is open per `bin/metrics-test.sh` precedent
  (`dispatch-resource-sample`, `sweep-readonly-residue-cleaned`,
  `halt-sprawl` are not in the JSON registry either). No registry
  edit needed.
- `[verified]` `bin/run-local-helpers.sh:459-513` — `stage_output_paths`
  case for `planning` returns `docs/plans/` only. The plan doc and
  sibling JSON contract (this plan's File Structure) both fit
  within that allowlist; the implement-stage scope sweep (run
  during ENG-132's own implementing dispatch) reads the same case's
  `implementing` arm (profile + always-include catalog), and the
  new files at `bin/stuck-tick-alarm.sh` / `bin/stuck-tick-alarm-test.sh`
  / `launchd/com.twinning.stuck-tick-alarm.plist.template` resolve
  to scope-allowed paths via the harness-slug profile's `bin/` and
  `launchd/` File-layout entries.
- `[verified]` `docs/knowledge/decisions.md` does NOT exist (`docs/`
  has only `architecture.md, assumptions.md, brainstorms, configuration.md,
  cost.md, demos, install.md, operations.md, pipeline-vocabulary.md,
  pipeline-vocabulary.template.md, plans, runbooks, security.md`).
  No ADR file to consult; brainstorm's §10 carries proposed ADRs
  inline.
- `[verified]` `docs/VISION.md` does NOT exist (per the brainstorm
  prompt's "skip if not present" clause).
- `[verified]` `learned-rules/harness/plan.md` does NOT exist (only
  `build.md` and `project-profile.md` present under
  `learned-rules/harness/`). No plan-stage learned rules to follow.
- `[verified]` `learned-rules/harness/project-profile.md` ::
  `## Build & test gates` — `Test:` is an enumerated `&&`-joined
  list of `bash bin/<name>-test.sh` invocations (NOT a glob).
  Adding `bin/stuck-tick-alarm-test.sh` requires extending the
  list explicitly, per the add-side test-gate closure sweep
  precedent (ENG-122 / ENG-135). Content anchor: the literal
  trailing `&& bash bin/common-test.sh` token (unique within the
  file).
- `[verified]` `learned-rules/harness/project-profile.md` ::
  `## Tool allowlist` — `implementing` and `qa` stages each
  enumerate every `bin/*-test.sh` as a literal
  `Bash(bash bin/<name>-test.sh:*)` entry. Adding the new test
  requires sibling entries under both stages so the
  implement-stage and qa-stage agents can invoke the new test
  through the harness's `--allowed-tools` argv (per the
  CLAUDE.md "Per-target dispatch.tools extras and
  profile-derived tools (ENG-51, ENG-94)" section's wildcard
  pitfall). Content anchors: the literal
  `Bash(bash bin/vocabulary-cleanliness-test.sh:*)` line (last
  entry in alphabetical order) under each stage section.

### Assumed / new — created or modified by this plan

- `[assumed/new]` `bin/stuck-tick-alarm.sh` — new file (Task 2).
  Structure per §3 below. Sources `common.sh`. Sentinel pattern at
  EOF so `bin/stuck-tick-alarm-test.sh` can `source` for function
  access without firing `main`.
- `[assumed/new]` `bin/stuck-tick-alarm-test.sh` — new sibling test
  (Task 6). Source-and-stub pattern mirroring `bin/halt-sprawl-test.sh`.
- `[assumed/new]` `launchd/com.twinning.stuck-tick-alarm.plist.template`
  — new file (Task 3). Templated like the pipeline plist with the
  diffs listed in §3.
- `[assumed]` macOS `stat -f %m "$file"` returns mtime in epoch
  seconds, AND `date -r "$file" +%s` is equivalent. The alarm uses
  `date -r "$file" +%s` (single-call, BSD/GNU portable on macOS,
  and avoids the `stat -f` vs `stat -c` branching the brainstorm
  flagged for resolution at implement time).
- `[assumed]` `mv -f "$tmp" "$heartbeat"` is atomic on APFS
  (POSIX rename guarantee). Established precedent at
  `bin/common.sh:140-154` (`_allocate_dispatch_id_locked` for
  `issue-state.json`).
- `[assumed]` `ps -p <pid> -o pid,ppid,user,command` (no `-ef`) is
  the portable form on BSD `ps` (macOS default). Wraps in
  `|| printf '<ps unavailable for pid=%s>\n' "$pid"` so an invalid
  pid degrades the payload string but never the alarm decision.
- `[assumed]` Slack accepts newline-separated multi-line payloads
  via the existing `{"text": "…"}` JSON shape at `bin/slack.sh:34-37`.
  Verified by existing halt-sprawl Slack payload at
  `bin/poll.sh:600` (single line) and inspection of `slack.sh`'s
  `jq -cn` payload assembly — `\n` in the text field renders as a
  line break in Slack.

## 3. File Structure

New files:
- `bin/stuck-tick-alarm.sh` — alarm script. Functions: `main`,
  `_resolve_alarm_minutes`, `_heartbeat_age_seconds`,
  `_lock_holder_pid`, `_ps_excerpt_for_pid`, `_log_tail_for_today`,
  `_debounced`, `_stamp_debounce`. Sentinel at EOF.
- `bin/stuck-tick-alarm-test.sh` — sibling test (chmod 755).
  Source-and-stub pattern; 10 AC cases per §6 Test Strategy.
- `launchd/com.twinning.stuck-tick-alarm.plist.template` — new
  launchd template. Mirrors `com.twinning.pipeline.plist.template`
  with `StartInterval=900`, `RunAtLoad=false`,
  `ProgramArguments→/bin/bash __HARNESS_ROOT__/bin/stuck-tick-alarm.sh`,
  `StandardOut/ErrorPath→…/logs/stuck-tick-alarm-launchd.{out,err}.log`,
  `Label=com.twinning.stuck-tick-alarm.__PROJECT_SLUG__`.

Modified files:
- `bin/run-local.sh` — one new helper `_write_tick_heartbeat` (Task
  1) and one call site after the existing
  `log "== tick end (success, …) =="` line.
- `bin/install-launchd.sh` — one new `install_one stuck-tick-alarm 0`
  call (Task 4) plus one extra line in the trailing summary heredoc.
- `bin/uninstall-launchd.sh` — one new `uninstall_one stuck-tick-alarm`
  call (Task 4).
- `bin/setup.sh` — extend the `for label in …` loop of
  `is_launchd_done()` to include the alarm label (Task 4).
- `bin/install-launchd-test.sh` — extend fixtures + assertions to
  cover the third plist (Task 7).
- `learned-rules/harness/project-profile.md` — extend
  `## Build & test gates` Test command to include
  `bash bin/stuck-tick-alarm-test.sh`, and extend
  `## Tool allowlist` for `implementing` and `qa` to include
  `Bash(bash bin/stuck-tick-alarm-test.sh:*)` (Task 9). Required by
  the add-side test-gate closure sweep (ENG-122 / ENG-135).
- `CLAUDE.md` — new "Stuck-tick alarm (ENG-132)" subsection + one
  row in "Failure-mode quick reference" (Task 8).
- `docs/configuration.md` — new `orchestrator.stuck_tick_alarm_minutes`
  subsection (Task 8).

Not modified (intentional — recorded so reviewers don't expect changes):
- `bin/run-stage.sh` — alarm is harness-wide, not per-stage.
- `bin/poll.sh` — symmetric pattern reused, NOT shared code (one
  caller is not yet abstraction-justifying per CLAUDE.md
  "Don't add features… beyond what the task requires").
- `bin/run-local-helpers.sh::acquire_lock` — lock contract
  unchanged.
- `bin/dispatch.sh` — alarm doesn't dispatch `claude -p`.
- `bin/render-prompt.sh` — alarm is not a stage prompt.
- `bin/pipeline-events.json` — `stuck-tick` is a metrics-event name.
- `.githooks/pre-commit` — the `bin/*-test.sh` glob discovers the
  new test automatically.

## 4. API Contract

No new API surface. The harness has no FE↔BE wire interface;
ENG-132 introduces:
- A bash CLI script (`bin/stuck-tick-alarm.sh`) with implicit
  zero-arg invocation from launchd plus optional manual `bash bin/stuck-tick-alarm.sh`.
- An optional env-var (`STUCK_TICK_ALARM_MINUTES`) and one config
  key (`orchestrator.stuck_tick_alarm_minutes`) — both documented
  in §8.
- One new metrics event name (`stuck-tick`), one new debounce file
  (`$PROJECT_STATE_DIR/.stuck-tick-last-alerted`), and one new
  heartbeat file (`$PROJECT_STATE_DIR/.last-tick-end`).

## 5. Backend Tasks

### Task 0: Rebase onto origin/main

- `depends_on: []`
- `touches: working tree only (no file edits)`
- [ ] Run `git fetch origin main && git rebase origin/main` in the
  worktree. Resolve any conflicts (none expected — drift is two
  commits in `bin/run-stage.sh` + `bin/run-stage-test.sh` ONLY,
  outside this plan's File Structure).
- [ ] Re-read the `bin/run-local.sh:504`, `bin/poll.sh:545-610`,
  `bin/install-launchd.sh:30-67`, `bin/uninstall-launchd.sh:46-47`,
  `bin/setup.sh:601-603`, and `CLAUDE.md` content anchors named in
  §2 Assumption Inventory and confirm the literal-string anchors
  still appear in the post-rebase tree.
- [ ] If any anchor has moved or been rewritten by a sibling
  commit, STOP and post a comment on ENG-132 with the conflicting
  upstream change; request `pipeline:supersede`. Otherwise proceed
  to Task 1.

### Task 1: Add `_write_tick_heartbeat` helper + call site in `bin/run-local.sh`

- `depends_on: [0]`
- `touches: bin/run-local.sh::_write_tick_heartbeat (new helper); bin/run-local.sh tick-end call site`
- [ ] Add the helper definition BEFORE the `acquire_lock` call in
  `bin/run-local.sh`. Content anchor: AFTER the `mkdir -p
  "$HARNESS_STATE_DIR"` line (~line 49, before `if ! acquire_lock`)
  BEFORE the `if ! acquire_lock "$LOCK_DIR"; then` block. Body:

  ```bash
  _write_tick_heartbeat() {
    local heartbeat_file="$PROJECT_STATE_DIR/.last-tick-end"
    local tmp="${heartbeat_file}.tmp.$$"
    if date -u +%Y-%m-%dT%H:%M:%SZ > "$tmp" 2>/dev/null \
       && mv -f "$tmp" "$heartbeat_file" 2>/dev/null; then
      return 0
    fi
    log "heartbeat write failed (continuing tick)"
    rm -f "$tmp" 2>/dev/null || true
    return 0
  }
  ```

  The `return 0` is load-bearing under `set -euo pipefail`:
  whichever failure mode hits, the tick continues to its normal exit
  and the alarm fires on the absent (or stale) heartbeat — see Edge
  case 9 in §6 of the brainstorm.
- [ ] Add the call site immediately AFTER the existing
  `log "== tick end (success, ${#_claimed_workers[@]} worker(s)) =="`
  line. Content anchor: that literal log string is unique within
  the file (verified by grep on the current tree). Inserted text:

  ```bash
  _write_tick_heartbeat
  ```

  Placement *after* the success-log line is load-bearing: a tick
  that crashed before the log line never reaches the heartbeat
  write, so a crash surfaces as an alarm-eligible silence (Edge
  case 5 in §6 of the brainstorm).
- [ ] Smoke: `PIPELINE_DRY_RUN=1 TARGET_REPO=<fixture> bash bin/run-local.sh`
  is NOT a viable smoke at this layer (the script does a great deal
  of orchestration). Instead, verify by re-running
  `bash bin/run-local-content-test.sh` if it has a content
  assertion covering the success-log line; if not, rely on the
  integration coverage from the alarm test in §6.

### Task 2: Create `bin/stuck-tick-alarm.sh`

- `depends_on: [0]`
- `touches: bin/stuck-tick-alarm.sh (new file); functions main, _resolve_alarm_minutes, _heartbeat_age_seconds, _lock_holder_pid, _ps_excerpt_for_pid, _log_tail_for_today, _debounced, _stamp_debounce`
- [ ] Create `bin/stuck-tick-alarm.sh` with `chmod 755`. Skeleton
  (full body specified by the bullets below; this is structural
  only):

  ```bash
  #!/usr/bin/env bash
  # External observer of run-local.sh's per-tick heartbeat. Posted by
  # com.twinning.stuck-tick-alarm.<slug> every 15 min. ENG-132.

  set -euo pipefail
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=common.sh
  source "$SCRIPT_DIR/common.sh"

  HEARTBEAT_FILE="$PROJECT_STATE_DIR/.last-tick-end"
  DEBOUNCE_FILE="$PROJECT_STATE_DIR/.stuck-tick-last-alerted"
  DEBOUNCE_WINDOW_SECONDS=86400   # mirror halt-sprawl's 24h
  ALARM_MINUTES_DEFAULT=30
  ALARM_MINUTES_FLOOR=10

  _resolve_alarm_minutes() { … }
  _heartbeat_age_seconds() { … }
  _lock_holder_pid() { … }
  _ps_excerpt_for_pid() { … }
  _log_tail_for_today() { … }
  _debounced() { … }
  _stamp_debounce() { … }
  main() { … }

  if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
  fi
  ```
- [ ] `_resolve_alarm_minutes`: three-layer resolution (env >
  config > default). Mirror `bin/common.sh:619-642::_resolve_K`:
  - Read `${STUCK_TICK_ALARM_MINUTES-}` (single-dash empty fallback
    per the ENG-46 secret-handling preamble; this env var is
    NON-secret but the single-dash form is the canonical safe
    pattern).
  - If non-empty AND `=~ ^[0-9]+$` AND `>= ALARM_MINUTES_FLOOR`,
    `printf '%s\n'` and return 0. Else `log` a warning and fall
    through.
  - If `[[ -f "$CONFIG" ]]`, read
    `jq -r '.orchestrator.stuck_tick_alarm_minutes // empty' "$CONFIG"`.
    Validate same as above; printf+return on success; log+fall on
    failure.
  - Final fallback: `printf '%s\n' "$ALARM_MINUTES_DEFAULT"`.
- [ ] `_heartbeat_age_seconds`: returns the number of seconds since
  `$HEARTBEAT_FILE`'s mtime via stdout. If the file is missing or
  unreadable, returns a large sentinel (`99999999`) so the alarm
  treats absence as worst-case stale. Implementation:

  ```bash
  _heartbeat_age_seconds() {
    local mtime now
    if [[ -f "$HEARTBEAT_FILE" ]]; then
      mtime="$(date -r "$HEARTBEAT_FILE" +%s 2>/dev/null || printf '0')"
      [[ "$mtime" =~ ^[0-9]+$ ]] || mtime=0
    else
      mtime=0
    fi
    now="$(date -u +%s)"
    if (( mtime <= 0 )); then
      printf '%s\n' '99999999'
    else
      printf '%s\n' "$(( now - mtime ))"
    fi
  }
  ```
- [ ] `_lock_holder_pid`: reads
  `$PROJECT_STATE_DIR/.run-local.lock/pid` if present, else prints
  literal `none`. The pid file format is established at
  `bin/run-local-helpers.sh:918-919` (`printf '%s\n' $$ > "$lock_dir/pid"`).
- [ ] `_ps_excerpt_for_pid`: takes `$1` as a pid (may be literal
  `none`). If `$1 == none`, prints `<no live tick holder>`.
  Otherwise: `ps -p "$1" -o pid,ppid,user,command 2>/dev/null ||
  printf '<ps unavailable for pid=%s>\n' "$1"`. Per the brainstorm
  security review: avoids the `ps -ef | grep <pid>` substring-match
  pitfall.
- [ ] `_log_tail_for_today`: prints `tail -n 40
  "$PROJECT_STATE_DIR/logs/local-$(date -u +%Y-%m-%d).log"`,
  silenced on missing file (`2>/dev/null || true`). Bounded fan-out;
  if the wedge spans midnight the operator sees the new day's
  (mostly empty) tail and the existing heartbeat-age value carries
  the temporal context.
- [ ] `_debounced`: reads `$DEBOUNCE_FILE` (parsing identical to
  `bin/poll.sh:580-589`). Returns 0 (debounced — suppress Slack)
  if `now - last_epoch <= DEBOUNCE_WINDOW_SECONDS`; returns 1
  otherwise.
- [ ] `_stamp_debounce`: writes `date -u +%Y-%m-%dT%H:%M:%SZ >
  "$DEBOUNCE_FILE"` (mirrors `bin/poll.sh:604`).
- [ ] `main`:
  1. `local threshold age holder_pid payload`
  2. `threshold="$(_resolve_alarm_minutes)"`
  3. `age="$(_heartbeat_age_seconds)"`
  4. `if (( age <= threshold * 60 )); then return 0; fi`
  5. `holder_pid="$(_lock_holder_pid)"`
  6. Emit level-triggered metric:

     ```bash
     bash "$SCRIPT_DIR/metrics.sh" stuck-tick "" "" alert 0 \
       "age=$age threshold=$((threshold * 60)) holder_pid=$holder_pid" \
       || true
     ```
  7. `if _debounced; then log "stuck-tick: slack suppressed by
     debounce ($age sec age, $((DEBOUNCE_WINDOW_SECONDS)) sec window)";
     return 0; fi`
  8. Build payload (multi-line, baked literal so no `$(date)`
     expansion inside the quoted heredoc — secret-handling preamble):

     ```bash
     local last_iso
     last_iso="$(cat "$HEARTBEAT_FILE" 2>/dev/null || printf '<none>')"
     payload="$(printf 'Stuck tick alarm: %s has not completed a tick for %s sec (threshold %sm; last good %s)\nLock holder: pid=%s\nps excerpt:\n%s\nLog tail:\n%s' \
       "$PROJECT_SLUG" "$age" "$threshold" "$last_iso" \
       "$holder_pid" "$(_ps_excerpt_for_pid "$holder_pid")" \
       "$(_log_tail_for_today)")"
     ```
  9. `bash "$SCRIPT_DIR/slack.sh" warn "$payload" || true` (mirror
     `bin/poll.sh:602`'s posture).
  10. `_stamp_debounce`.
- [ ] End with the sentinel pattern (`if [[ "${BASH_SOURCE[0]}" ==
  "${0}" ]]; then main "$@"; fi`).
- [ ] `chmod 755 bin/stuck-tick-alarm.sh`.

### Task 3: Create `launchd/com.twinning.stuck-tick-alarm.plist.template`

- `depends_on: []`
- `touches: launchd/com.twinning.stuck-tick-alarm.plist.template (new file)`
- [ ] Copy `launchd/com.twinning.pipeline.plist.template` to the
  new path. Apply these diffs (and only these):
  - `Label`: `com.twinning.stuck-tick-alarm.__PROJECT_SLUG__`
  - `ProgramArguments[1]`: `__HARNESS_ROOT__/bin/stuck-tick-alarm.sh`
  - `StartInterval`: `900`
  - `RunAtLoad`: `<false/>` (mirroring
    `launchd/com.twinning.retrospective.plist.template:34-35`)
  - `StandardOutPath`:
    `__HARNESS_STATE_DIR__/__PROJECT_SLUG__/logs/stuck-tick-alarm-launchd.out.log`
  - `StandardErrorPath`:
    `__HARNESS_STATE_DIR__/__PROJECT_SLUG__/logs/stuck-tick-alarm-launchd.err.log`
- [ ] Keep `EnvironmentVariables` identical to the pipeline plist
  template (PATH + HOME + TARGET_REPO + HARNESS_STATE_DIR +
  PROJECT_SLUG). The alarm script needs `TARGET_REPO` because
  `common.sh:11` dies on its absence; the other three are required
  for `PROJECT_STATE_DIR` resolution.
- [ ] Keep `ThrottleInterval=60` (same as the pipeline plist) so a
  crash loop is rate-limited by launchd.

### Task 4: Wire installs + setup launchd-done check

- `depends_on: [2, 3]`
- `touches: bin/install-launchd.sh; bin/uninstall-launchd.sh; bin/setup.sh::is_launchd_done`
- [ ] In `bin/install-launchd.sh`, add the new install call.
  Content anchor: AFTER the literal line `install_one retrospective 0`
  BEFORE the line `cat <<EOF`. Inserted text:

  ```bash
  install_one stuck-tick-alarm 0
  ```
- [ ] In the same file's trailing `cat <<EOF` summary block, insert
  one new line BEFORE the existing `Logs:` line. Content anchor:
  AFTER the literal line
  `  com.twinning.retrospective.$PROJECT_SLUG  — Mondays 09:00`
  BEFORE the literal line `  Logs: $PROJECT_STATE_DIR/logs/launchd.{out,err}.log`.
  Inserted text:

  ```
    com.twinning.stuck-tick-alarm.$PROJECT_SLUG  — every 15 min
  ```
- [ ] In `bin/uninstall-launchd.sh`, add the symmetric uninstall
  call. Content anchor: AFTER the literal LAST line of the file
  (`uninstall_one retrospective`). Inserted text:

  ```bash
  uninstall_one stuck-tick-alarm
  ```
- [ ] In `bin/setup.sh::is_launchd_done`, extend the iteration
  list. Content anchor: the literal line
  `for label in "com.twinning.pipeline.$slug" "com.twinning.retrospective.$slug"; do`
  (unique in `bin/setup.sh`). Replace with:

  ```bash
  for label in "com.twinning.pipeline.$slug" "com.twinning.retrospective.$slug" "com.twinning.stuck-tick-alarm.$slug"; do
  ```

  Without this edit, existing installs would report the launchd
  phase incomplete forever after upgrade (alarm label is not loaded
  on the pre-upgrade install). The migration step at
  `bin/setup.sh:708-709` already shells out to
  `install-launchd.sh`, which now installs all three; this edit
  closes the symmetry loop on the readiness predicate.
- [ ] No edit to `bin/setup.sh:698` (`for label in
  com.twinning.pipeline com.twinning.retrospective`). That loop
  bootouts *legacy un-suffixed* pre-multi-project labels. No
  unsuffixed `com.twinning.stuck-tick-alarm` ever existed; nothing
  to bootout.

### Task 5: Configuration knob threading

- `depends_on: [2]`
- `touches: bin/stuck-tick-alarm.sh::_resolve_alarm_minutes (already covered in Task 2); no code edit here — this is a verification task`
- [ ] Confirm via re-reading the implemented `_resolve_alarm_minutes`
  (Task 2) that the precedence is env > config > default 30, the
  floor of 10 applies to BOTH the env and config layers, and
  invalid values fall through with a `log` warning rather than die.
  No additional code; this task exists in the plan so the
  test-strategy section's AC-CONFIG-* tests have an explicit owner
  for verification.

### Task 6: Sibling test `bin/stuck-tick-alarm-test.sh`

- `depends_on: [2]`
- `touches: bin/stuck-tick-alarm-test.sh (new file)`
- [ ] Create the test file (`chmod 755`). Follow the source-and-stub
  pattern from `bin/halt-sprawl-test.sh:1-115`:
  - Boilerplate: `set -euo pipefail`, allocate `_TEST_HARNESS_STATE_DIR`
    and `_TEST_STUB_DIR` under `mktemp -d`, write a `_test_safe_rm`
    trap (same shape as halt-sprawl-test.sh's lines 20-35), export
    `PIPELINE_DRY_RUN=1`, `LINEAR_API_KEY=test-mock-key`,
    `PROJECT_SLUG=test-slug`, `HARNESS_STATE_DIR="$_TEST_HARNESS_STATE_DIR"`,
    `PROJECT_STATE_DIR="$HARNESS_STATE_DIR/$PROJECT_SLUG"`.
  - Set up a minimal target repo under `$(mktemp -d)/target/.pipeline-config/`
    with a `config.json` containing `{"project":{"slug":"test-slug"},
    "linear":{...},"orchestrator":{}}` so `common.sh`'s
    `TARGET_REPO` check passes.
  - Stub `bin/metrics.sh` (write to `$METRICS_CAPTURE`) and
    `bin/slack.sh` (write `level\tmessage` to `$SLACK_CAPTURE`),
    chmod 755 each.
  - `source "$SCRIPT_DIR_REAL/stuck-tick-alarm.sh"` (sentinel
    bypass — file's `main` does NOT auto-run when sourced). Then
    `SCRIPT_DIR="$STUB_DIR"` so `bash "$SCRIPT_DIR/metrics.sh" …`
    and `bash "$SCRIPT_DIR/slack.sh" …` resolve to the stubs.
  - Override `HEARTBEAT_FILE`, `DEBOUNCE_FILE` post-source as needed
    per AC.
- [ ] Implement the 10 AC cases (per brainstorm D-006). Each case
  resets capture files and re-invokes `main`:

  - **AC-FRESH** — `touch "$HEARTBEAT_FILE"` (mtime ≈ now); call
    `main`; assert `$METRICS_CAPTURE` empty AND `$SLACK_CAPTURE`
    empty AND no debounce stamp.
  - **AC-STALE** — back-date heartbeat via `touch -t YYYYMMDDhhmm.SS`
    or `touch -A -<seconds>` to 31 minutes ago; call `main`; assert
    `$METRICS_CAPTURE` has one `stuck-tick` line AND `$SLACK_CAPTURE`
    has one `warn` line AND `$DEBOUNCE_FILE` exists.
  - **AC-DEBOUNCED** — heartbeat stale, debounce stamp set to "now"
    (`date -u … > $DEBOUNCE_FILE`); assert `$METRICS_CAPTURE` has
    one `stuck-tick` line (level-triggered) AND `$SLACK_CAPTURE` is
    empty (edge-triggered, suppressed).
  - **AC-MISSING-HEARTBEAT** — `rm -f "$HEARTBEAT_FILE"`; assert
    both captures populated AND debounce stamp written.
  - **AC-MALFORMED-TIMESTAMP** — write garbage to `$HEARTBEAT_FILE`,
    but back-date its mtime past threshold (`touch -t`); assert
    alarm STILL fires (mtime is what's read, content is decoration).
    Reverse case: write garbage with fresh mtime; assert NO alarm
    (mtime fresh).
  - **AC-CONFIG-DEFAULT** — config.json with no
    `orchestrator.stuck_tick_alarm_minutes` key; back-date heartbeat
    to 31 min; assert alarm fires (default 30 applies).
  - **AC-CONFIG-OVERRIDE** — config.json with
    `orchestrator.stuck_tick_alarm_minutes: 45`; back-date
    heartbeat to 31 min; assert NO alarm. Re-run with 46 min stale;
    assert alarm fires.
  - **AC-CONFIG-BELOW-FLOOR** — config.json with `5`; assert
    falls-through (final default 30 applies). Drive both sub-cases
    (heartbeat at 6 min stale → no alarm; at 31 min stale → alarm).
  - **AC-CONFIG-NON-INTEGER** — config.json with `"30m"`; assert
    same fall-through (default 30 applies).
  - **AC-ENV-OVERRIDE** — `STUCK_TICK_ALARM_MINUTES=20`; back-date
    heartbeat to 21 min; assert alarm fires (env wins over default
    30).
- [ ] Tail: `printf '\n  passed: %d\n  failed: %d\n' "$PASS"
  "$FAIL"; (( FAIL == 0 ))` (pattern from `bin/install-launchd-test.sh:119-120`).
- [ ] `chmod 755 bin/stuck-tick-alarm-test.sh`.

### Task 7: Extend `bin/install-launchd-test.sh` for the third plist

- `depends_on: [3, 4]`
- `touches: bin/install-launchd-test.sh`
- [ ] Add a file-exists assertion next to the existing pipeline +
  retrospective asserts. Content anchor: AFTER the literal block

  ```bash
  [[ -f "$HOME/Library/LaunchAgents/com.twinning.retrospective.foo.plist" ]] \
    && pass_at "retrospective plist rendered with slug 'foo'" \
    || fail_at "retrospective plist rendered" "missing"
  ```

  BEFORE the next test (`grep -q 'com.twinning.pipeline.foo' …`).
  Inserted text:

  ```bash
  [[ -f "$HOME/Library/LaunchAgents/com.twinning.stuck-tick-alarm.foo.plist" ]] \
    && pass_at "stuck-tick-alarm plist rendered with slug 'foo'" \
    || fail_at "stuck-tick-alarm plist rendered" "missing"
  ```
- [ ] Add an explicit assertion that the third plist is gone after
  uninstall, sibling to the existing uninstall surgical check.
  Content anchor: AFTER the literal block

  ```bash
  [[ ! -f "$HOME/Library/LaunchAgents/com.twinning.pipeline.foo.plist" \
     && -f "$HOME/Library/LaunchAgents/com.twinning.pipeline.bar.plist" ]] \
    && pass_at "uninstall surgical: foo gone, bar intact" \
    || fail_at "uninstall surgical" "wrong files removed"
  ```

  BEFORE the trailing `printf` summary. Inserted text:

  ```bash
  [[ ! -f "$HOME/Library/LaunchAgents/com.twinning.stuck-tick-alarm.foo.plist" \
     && -f "$HOME/Library/LaunchAgents/com.twinning.stuck-tick-alarm.bar.plist" ]] \
    && pass_at "uninstall surgical: stuck-tick-alarm.foo gone, bar intact" \
    || fail_at "uninstall surgical (stuck-tick-alarm)" "wrong files removed"
  ```
- [ ] No `seed_profile` extension needed — the existing fixture
  populates the project-profile for slugs `foo` and `bar`, and the
  new launchd template's render path does NOT depend on the profile
  (`install-launchd.sh:17-23` only checks the profile exists +
  marker-free, not its contents).

### Task 8: Operator-doc edits

- `depends_on: [4, 7]`
- `touches: CLAUDE.md; docs/configuration.md`
- [ ] In `CLAUDE.md`, insert the new "Stuck-tick alarm (ENG-132)"
  subsection. Content anchor: AFTER the literal line
  `that target's \`config.json::orchestrator.max_concurrent_features\` to 1.`
  (the LAST line of the ENG-81 "Per-project dispatch concurrency"
  section) BEFORE the literal line
  `**What \`--action continue\` clears (atomic):**`. Section body
  follows the depth + structure of "Per-project dispatch
  concurrency (ENG-81)":
  - One paragraph: what the alarm is + where it fires (Slack).
  - Numbered resolution-precedence list (env > config > default 30)
    + floor 10.
  - JSON config snippet showing
    `orchestrator.stuck_tick_alarm_minutes`.
  - One bullet on the K=2 long-brainstorm false-positive cost (per
    brainstorm Edge case 3) and the operator's tuning recipe
    (`stuck_tick_alarm_minutes: 75`).
  - One bullet on planned-maintenance silencing
    (`STUCK_TICK_ALARM_MINUTES=9999` in the alarm plist +
    `launchctl bootstrap`).
  - One bullet on manual smoke
    (`bash bin/stuck-tick-alarm.sh` from the CLI).
  - One bullet on file paths (`.last-tick-end`,
    `.stuck-tick-last-alerted`, alarm cadence 15 min).
- [ ] In `CLAUDE.md`'s "Failure-mode quick reference" table, add a
  new row at the END of the table. Content anchor: AFTER the
  literal row beginning
  `| Issue stuck at one stage; \`$(issue_dir <issue>)/.in-flight.lock\` present |`
  (the actual last row of the table — ~line 779) BEFORE the
  blank line that separates the table from the next H2 (`##
  Per-project dispatch concurrency (ENG-81)`). Row body (per
  brainstorm D-007):

  ```
  | Slack message "Stuck tick alarm" | `bin/run-local.sh` is wedged or the launchd agent is dead. Inspect `$PROJECT_STATE_DIR/.last-tick-end` mtime, `$PROJECT_STATE_DIR/.run-local.lock/pid`, then `ps -p <pid> -o pid,ppid,user,command`. Recovery: `launchctl kickstart -k gui/$(id -u)/com.twinning.pipeline.$PROJECT_SLUG` after confirming the holder is wedged. |
  ```
- [ ] In `docs/configuration.md`, insert the new
  `### orchestrator.stuck_tick_alarm_minutes` subsection. Content
  anchor: AFTER the literal block ending
  ``ls $HARNESS_STATE_DIR/.claude-semaphore/slot-*/pid`` +
  ``bash bin/status.sh   # "Concurrent dispatches active right now" row``
  (the closing fenced block of the
  `orchestrator.max_concurrent_features` section) BEFORE the next
  `### ` heading. Subsection body mirrors the depth of
  `orchestrator.dispatch_timeout_minutes_per_stage`:
  - Purpose: what the knob controls (threshold for the external
    alarm).
  - Default 30, floor 10. Resolution precedence (env > config >
    default). Validation: `^[0-9]+$` AND `>= 10`.
  - JSON example.
  - Inspection: how to confirm an override took effect (`grep
    'threshold' "$PROJECT_STATE_DIR/logs/stuck-tick-alarm-launchd.*"`
    + manual `bash bin/stuck-tick-alarm.sh`).
  - Silencing recipe (`STUCK_TICK_ALARM_MINUTES=9999` env in the
    plist + `launchctl bootstrap`).

### Task 9: Update `learned-rules/harness/project-profile.md` Build & test gates + Tool allowlist

- `depends_on: [6]`
- `touches: learned-rules/harness/project-profile.md::## Build & test gates; learned-rules/harness/project-profile.md::## Tool allowlist (implementing + qa stages)`
- [ ] In `learned-rules/harness/project-profile.md`'s
  `## Build & test gates` section, extend the `Test:` command's
  `&&`-joined list to include the new sibling test. Content anchor:
  the literal trailing `&& bash bin/common-test.sh` token (unique
  within the file). Replace it with:

  ```
  && bash bin/common-test.sh && bash bin/stuck-tick-alarm-test.sh
  ```

  Required by the add-side test-gate closure sweep (ENG-122 /
  ENG-135): when a new `bin/*-test.sh` lands in a project whose
  profile enumerates its gate tests, that file's name MUST also
  land in the enumerated list.
- [ ] In the same file's `## Tool allowlist` section, add the new
  test as a sibling allowlist entry under BOTH the `implementing:`
  stage block and the `qa:` stage block. Content anchor (per
  block): the literal line `- \`Bash(bash bin/vocabulary-cleanliness-test.sh:*)\``
  (alphabetical-last entry within each block). Insert AFTER it,
  in alphabetical order — since `stuck-tick-alarm` sorts BEFORE
  `vocabulary-cleanliness`, the insertion is actually one entry
  EARLIER. Concretely: locate
  `- \`Bash(bash bin/setup-test.sh:*)\`` (alphabetical predecessor
  of `stuck-tick-alarm`) and insert AFTER it BEFORE
  `- \`Bash(bash bin/test-isolation-test.sh:*)\``:

  ```
    - `Bash(bash bin/stuck-tick-alarm-test.sh:*)`
  ```

  Apply the SAME insert under both `implementing:` and `qa:`
  stage sections. The CLAUDE.md "Per-target dispatch.tools extras
  and profile-derived tools (ENG-51, ENG-94) — Wildcard pitfall"
  guidance is why the entry must be enumerated literally and NOT
  rolled into a `bin/*-test.sh` wildcard.
- [ ] Smoke: re-run `bash bin/profile-allowlist-test.sh` to confirm
  the profile schema is still parseable (the test pins the
  schema_version + the enumerated-vs-glob convention; it does not
  assert on specific test names).

### Frontend Tasks

The harness has no frontend (Stack section of the Project profile:
"Bash 3.2+ orchestration scripts… The repo contains no application
code"). No frontend tasks.

## 6. Failure Mode → Test Map

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
|---|---|---|---|---|
| Healthy tick, fresh heartbeat | Tick wrote `$PROJECT_STATE_DIR/.last-tick-end` <30 min ago | Alarm returns 0; no metric; no Slack | unit | AC-FRESH (`bin/stuck-tick-alarm-test.sh`) |
| Wedged tick, heartbeat stale | mtime > 30 min ago AND no recent debounce stamp | Metric emitted; Slack posted; debounce stamp written | unit | AC-STALE (`bin/stuck-tick-alarm-test.sh`) |
| Wedged tick, recent debounce stamp | Stale heartbeat + debounce file mtime within 24h | Metric emitted (level-triggered); Slack suppressed | unit | AC-DEBOUNCED (`bin/stuck-tick-alarm-test.sh`) |
| First-ever install / wiped state dir | `$PROJECT_STATE_DIR/.last-tick-end` absent | Treated as worst-case stale; alarm fires | unit | AC-MISSING-HEARTBEAT (`bin/stuck-tick-alarm-test.sh`) |
| Heartbeat content garbled | File present but contents are not a valid ISO-8601 string | Alarm decision read from mtime, not content; behaviour matches mtime | unit | AC-MALFORMED-TIMESTAMP (`bin/stuck-tick-alarm-test.sh`) |
| `config.json` lacks `stuck_tick_alarm_minutes` | Key absent (or `config.json` itself absent) | Built-in default 30 applies | unit | AC-CONFIG-DEFAULT (`bin/stuck-tick-alarm-test.sh`) |
| Operator-set override | `orchestrator.stuck_tick_alarm_minutes: 45` | 45-min threshold applied | unit | AC-CONFIG-OVERRIDE (`bin/stuck-tick-alarm-test.sh`) |
| Below-floor config value | `orchestrator.stuck_tick_alarm_minutes: 5` | Falls through to default 30 with log warning | unit | AC-CONFIG-BELOW-FLOOR (`bin/stuck-tick-alarm-test.sh`) |
| Non-integer config value | `orchestrator.stuck_tick_alarm_minutes: "30m"` | Falls through to default 30 with log warning | unit | AC-CONFIG-NON-INTEGER (`bin/stuck-tick-alarm-test.sh`) |
| Emergency env override | `STUCK_TICK_ALARM_MINUTES=20` in the alarm plist | 20-min threshold applied (env wins) | unit | AC-ENV-OVERRIDE (`bin/stuck-tick-alarm-test.sh`) |
| Disk full / permission error on heartbeat write | `mv -f` fails inside `_write_tick_heartbeat` | Tick continues (no `set -euo pipefail` exit); alarm fires after threshold | integration | Manual smoke (no automated test — disk-full is host-environmental); covered conceptually by AC-MISSING-HEARTBEAT |
| Slack webhook unset | `PIPELINE_SLACK_WEBHOOK_URL` empty when alarm tries to post | `bin/slack.sh:16-19` returns 0; metric still emitted | unit | AC-STALE (the test asserts metric WITHOUT requiring webhook env — Slack stub logs the call but the alarm's `\|\| true` makes webhook-absence non-fatal) |
| Slack webhook fails | `curl` returns non-zero | `bin/slack.sh:38` logs but returns 0; `bash …slack.sh \|\| true` in the alarm makes failure non-fatal | unit | Stub-driven (the `slack.sh` stub in the test returns 0; covered structurally by AC-STALE) |
| Third plist render at install | `bash bin/install-launchd.sh /path/to/target` | All three plists rendered + bootstrap; `is_launchd_done` returns 0 | integration | `bin/install-launchd-test.sh` (extended in Task 7) |
| Third plist removed at uninstall | `bash bin/uninstall-launchd.sh /path/to/target` | `com.twinning.stuck-tick-alarm.<slug>.plist` removed; sibling slugs untouched | integration | `bin/install-launchd-test.sh` (extended in Task 7) |
| Heartbeat write present in run-local.sh after the success log | Re-run `bin/run-local.sh` end-to-end (DRY_RUN) | `_write_tick_heartbeat` call follows the success-log line; tick exits 0 | smoke | Manual `grep -n '_write_tick_heartbeat' bin/run-local.sh` (no dedicated unit test — the call is one line wedged between two log lines; covered structurally by inspection and by `bin/run-local-content-test.sh` if its assertions touch this region) |

## 7. Test Strategy

### Unit

`bin/stuck-tick-alarm-test.sh` is the primary surface (Task 6). 10
AC cases exercise the threshold, debounce, missing-heartbeat,
malformed-content, and config-precedence paths. All run under
`PIPELINE_DRY_RUN=1` against `$STUB_DIR` mocks for `bin/slack.sh`
and `bin/metrics.sh`. No Linear stub needed.

### Integration

`bin/install-launchd-test.sh` (extended in Task 7) covers
end-to-end install + uninstall of all three plists against a
stubbed `launchctl`. The existing test already verifies
file-substitution + bootstrap symmetry; the extension adds the
third plist to those assertions.

### Smoke

Manual operator smoke:
- `bash bin/stuck-tick-alarm.sh` against a fresh heartbeat exits 0
  silently.
- `touch -A -1800 "$PROJECT_STATE_DIR/.last-tick-end"` (back-date 30
  min on macOS); re-run `bash bin/stuck-tick-alarm.sh`; observe
  metric + Slack post.
- Re-run within 24h; observe metric WITHOUT a second Slack post.

### Adversarial

Edge cases 8 (concurrent alarm fire), 10 (alarm plist dead), and
11 (multi-project install) from the brainstorm §6 do NOT have
dedicated tests — they're either structurally impossible to lose
data on (atomic `mv -f` debounce write), explicitly out of scope
(OQ-1: watch-the-watcher), or covered by the install-launchd test's
sibling-slug isolation check.

### Test-gate closure sweep

This plan REMOVES no production tokens. It ADDS:
- `_write_tick_heartbeat` (new function in `bin/run-local.sh`)
- `stuck-tick` (new metrics event name)
- `_resolve_alarm_minutes`, `_heartbeat_age_seconds`,
  `_lock_holder_pid`, `_ps_excerpt_for_pid`, `_log_tail_for_today`,
  `_debounced`, `_stamp_debounce` (new functions in
  `bin/stuck-tick-alarm.sh`)
- `orchestrator.stuck_tick_alarm_minutes` (new config key)
- `STUCK_TICK_ALARM_MINUTES` (new env var)
- `com.twinning.stuck-tick-alarm.*` (new launchd label prefix)
- `$PROJECT_STATE_DIR/.last-tick-end`,
  `$PROJECT_STATE_DIR/.stuck-tick-last-alerted` (new state files)

Sweep of `bin/*-test.sh` for any of these tokens (grep -F before
ship) is empty by construction (no test references a not-yet-added
token). The two existing sibling tests that exercise files this
plan modifies — `bin/install-launchd-test.sh` and
`bin/run-local-content-test.sh` — are explicitly extended (or
unaffected, respectively) per Tasks 7 and 1:
- `bin/install-launchd-test.sh` is in File Structure → Task 7
  inverts/extends its assertions for the third plist.
- `bin/run-local-content-test.sh` is the only `bin/*-test.sh` that
  asserts against `bin/run-local.sh`'s structural content. Spot-check
  (verified at plan time): the test does NOT pin any literal that
  Task 1's two-line insert removes — Task 1 ADDS without removing or
  rewording any existing line. No assertion inversion needed.
- `bin/halt-sprawl-test.sh` is the *pattern* this plan mirrors but
  does NOT exercise any code this plan changes — no modification
  needed.

**Add-side closure (ENG-122 / ENG-135).** The new
`bin/stuck-tick-alarm-test.sh` lands under the
`bin/*-test.sh` glob the harness profile gates on via an
**enumerated** Test command (not a glob). Task 9 closes the
add-side sweep by extending both
`learned-rules/harness/project-profile.md::## Build & test gates`
(so the gate command runs the new test) and
`learned-rules/harness/project-profile.md::## Tool allowlist`
(so `implementing` and `qa` dispatches can invoke the test
through `--allowed-tools`). Without Task 9, the
post-merge profile-allowlist drift caught in ENG-122
would recur and `bin/dispatch-test.sh`'s wildcard-pitfall
assertion would fail on the next gate run.

### Stability under rebase

Every Edit-boundary step above uses a content anchor (a literal
unique string surrounding the insert point), not a bare line number.
The line-number ranges in §2 Assumption Inventory are informational
hints only. After Task 0's rebase, the implement agent re-verifies
each anchor still resolves before applying its task; if any anchor
has moved or been rewritten, halt per Task 0's stop-clause.

## 8. Persona review

### feasibility (gating) — PASS

Code-level facts re-verified against the current tree (worktree
HEAD = pre-rebase, but every named path resolves on-disk now):

- `bin/run-local.sh:504` — literal `log "== tick end (success,
  ${#_claimed_workers[@]} worker(s)) =="` confirmed unique in the
  file (Grep). Content anchor for Task 1's insert.
- `bin/run-local.sh:17` — `set -euo pipefail` confirmed.
- `bin/run-local-helpers.sh:916-934` — `acquire_lock` with the
  `kill -0 holder` stale-pid recovery confirmed.
- `bin/poll.sh:545-610` — `_poll_emit_halt_sprawl_alert` matches
  the pattern this plan mirrors (level-triggered metric +
  edge-triggered Slack + 24h debounce stamp).
- `bin/slack.sh:12-39` — chokepoint shape confirmed; `:16-19`
  no-ops on missing webhook; `:29-32` honors `PIPELINE_DRY_RUN=1`.
- `bin/common.sh:619` — `_resolve_K` function (the three-layer
  resolution precedent the new `_resolve_alarm_minutes` mirrors).
  The plan cited `:619-642`; verified `_resolve_K` starts at 619
  and ends with `export -f _resolve_K` at 642. ✓
- `bin/setup.sh:597,601` — `is_launchd_done()` defined at 597, the
  `for label in "com.twinning.pipeline.$slug" "com.twinning.retrospective.$slug"`
  loop at line 601. The plan cited `:601-603` — the loop body
  spans those lines. Content anchor is the literal line, not the
  number, so the small range shift is harmless. ✓
- `bin/uninstall-launchd.sh:46-47` — `uninstall_one pipeline` and
  `uninstall_one retrospective` calls confirmed. Last line of the
  file is `:47`. Plan inserts a third call AFTER `:47`. ✓
- `bin/metrics.sh:19-41` — signature
  `<event> <issue_id> <stage> <outcome> <duration_ms> [notes…]`
  confirmed.
- `bin/dispatch.sh::_cfg_minutes` — current range is `:526-538`
  (post-rebase drift from the brainstorm's `:469-488` and the
  plan's `:513-545` reference). The pattern is unchanged; the
  plan's content-anchor approach absorbs this drift. ✓
- `learned-rules/harness/project-profile.md::## Build & test gates`
  — Test command is enumerated `&&`-joined list, NOT a glob.
  Trailing `&& bash bin/common-test.sh` confirmed unique. ✓
- `learned-rules/harness/project-profile.md::## Tool allowlist` —
  implementing + qa stages enumerate every `bin/*-test.sh` as a
  literal `Bash(bash bin/<name>-test.sh:*)` entry. Alphabetical
  insertion point for `stuck-tick-alarm-test.sh` is AFTER
  `setup-test` BEFORE `test-isolation-test`. ✓

Every task has explicit `depends_on` and `touches` metadata.
Every Failure Mode → Test Map row names a concrete test layer +
test name (or marks "Manual smoke / no automated test" with an
explicit conceptual cover).

**Test-gate closure (add-side):** `bin/stuck-tick-alarm-test.sh`
is the new gate-runnable file. The harness profile enumerates
tests rather than globbing them, so the profile MUST appear in
File Structure. Task 9 + the new F-5 pass criterion close this.
Verified by inspection: pre-Task-9 plan was a P0 plan-completeness
defect; post-Task-9 it is not.

**Test-gate closure (remove-side):** This plan REMOVES no tokens
from production code. Empty sweep. ✓

No P0 findings. Plan-time `path:line` drift in `bin/dispatch.sh`
is bounded — content anchors absorb it; Task 0 mandates the
rebase before any other task.

### scope — PASS

Every task and every File Structure entry traces to a decision:

- Task 0 (rebase) → planning-prompt branch-base freshness check.
- Task 1 (heartbeat write) → brainstorm D-001 (write site) +
  ADR-002 (placement after success-log line).
- Task 2 (alarm script) → brainstorm D-001 + D-002 + D-003 +
  D-005.
- Task 3 (launchd template) → brainstorm D-004.
- Task 4 (install/uninstall + `is_launchd_done`) → brainstorm
  D-004 + the codebase-required `is_launchd_done` symmetry the
  brainstorm did not surface (caught at plan time during
  Assumption Inventory). Documented in §3 Architecture's
  "Files modified" list of this plan.
- Task 5 (config knob threading) → brainstorm D-002. Verification
  task, no new code beyond Task 2.
- Task 6 (sibling test) → brainstorm D-006.
- Task 7 (install-launchd-test extension) → brainstorm D-006
  (covers the third plist render + bootstrap symmetry).
- Task 8 (operator-doc edits) → brainstorm D-007.
- Task 9 (project-profile update) → CLAUDE.md "Per-target
  dispatch.tools extras and profile-derived tools (ENG-51,
  ENG-94)" + ENG-122 / ENG-135 add-side test-gate closure
  precedent. Required by the planning prompt's feasibility-
  persona "add-side test-gate closure" sweep.

No gold-plating: no tasks for the explicitly-deferred OQ-1
(watch-the-watcher), OQ-2 (configurable cadence), OQ-4
(retrospective context in payload), OQ-5 (validate alarm load).
No file in File Structure strays outside the brainstorm's §3
"Files modified or created" list, with Task 9's profile addition
as the one explicit superset entry (justified inline).

### coherence — PASS

- Plan Goal (§1) matches brainstorm Overview (§1 Problem):
  "wedged tick surfaces in operator chat within ~30-45 min
  instead of producing silent multi-hour outages."
- Backend Tasks (§5) collectively realise every "Files modified
  or created" entry from brainstorm §3 PLUS the profile update
  the brainstorm omitted.
- Failure Mode → Test Map (§6) covers every brainstorm §5 Error
  handling row and every §6 Edge cases row.
- Test Strategy (§7) covers every Failure Mode row at the named
  layer; Adversarial subsection explicitly enumerates the edges
  that do NOT get dedicated tests with justification.
- Vocabulary check: `stuck-tick` is a metrics-event name (open
  vocabulary per `bin/metrics-test.sh`), NOT a Linear marker
  (closed vocabulary in `bin/pipeline-events.json`). The plan
  does NOT touch `bin/pipeline-events.json`; coherent.

### design — PASS

- Crate / module boundaries respected: alarm script lives next to
  its sibling test in `bin/`; launchd template lives in `launchd/`;
  no cross-directory or cross-module abstractions introduced.
- No layering violations: alarm reads `$PROJECT_STATE_DIR`
  state files + `$LOG_FILE` (read-only); does NOT call
  `bin/run-local.sh`, `bin/dispatch.sh`, or any orchestrator
  internals.
- No circular deps: alarm sources `common.sh` only; `common.sh`
  does not source any of the alarm files.
- Pattern reuse: mirrors `_poll_emit_halt_sprawl_alert`
  (`bin/poll.sh:545-610`) verbatim (level-triggered metric +
  edge-triggered Slack + 24h debounce stamp). Mirrors
  `_resolve_K` (`bin/common.sh:619-642`) for the three-layer
  config precedence. Mirrors `install_one` parameterization
  (`bin/install-launchd.sh:30-56`) without changing the helper.
  No premature shared abstraction (single caller).

### product — PASS

- Operator workflow today: stuck-tick incidents are silent for
  hours; operator notices via dashboard or external complaint.
- Operator workflow after ENG-132: a wedge surfaces in Slack
  within 30-45 min with enough triage info (holder pid + ps
  excerpt + log tail) to act from Slack alone.
- False-positive cost: K=2 with a 60-min brainstorm + 30-min
  threshold → one Slack alert per stuck-tick window. Bounded by
  the 24h debounce and the config knob (`75` absorbs the worst
  case). Documented in CLAUDE.md per Task 8.
- No regression for the happy path: healthy harnesses see zero
  alerts; heartbeat write is <10ms per tick.
- The plan delivers exactly what the Linear issue asked for in
  its "Proposed fix shape" §: heartbeat file + external observer
  + Slack alert with triage payload + config knob + tests + docs.

### Iteration 1 verdict

| Persona | Verdict | P0 | P1 |
|---|---|---|---|
| feasibility (gating) | PASS | 0 | 0 |
| scope                | PASS | 0 | 0 |
| coherence            | PASS | 0 | 0 |
| design               | PASS | 0 | 0 |
| product              | PASS | 0 | 0 |

**5/5 PASS · gate P0: 0** — gate cleared on iteration 1.
`status = clean` — proceeding to implementing.
