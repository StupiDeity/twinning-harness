---
title: ENG-41 trust-model fix — operator recovery runbook
date: 2026-04-27
---

# Recovery runbook — ENG-41 pipeline trust-model fix

Quick reference for fixing issues stuck in three modes caused by label/comment write-lane violations. For full context, see:
- Brainstorm: `docs/brainstorms/2026-04-27-pipeline-trust-model-enforce-write-lanes-design.md`
- Plan: `docs/plans/2026-04-27-eng-41-pipeline-trust-model-enforce-write-lanes.md`

---

## 1. Issue with multiple `stage:*` labels

An issue carries two or more `stage:*` labels simultaneously (e.g., `stage:brainstorming` AND `stage:implementing`). This prevents the poll from picking it up cleanly — it will dispatch the first label in workflow order and loop if the agent succeeds.

### Detect

**Via Linear UI:**
Open the issue in Linear. Inspect the labels panel. If you see multiple labels from the `stage:` namespace (e.g., `stage:brainstorming`, `stage:implementing`), the issue is affected.

**Via CLI:**
```bash
TARGET_REPO=/path/to/target bash bin/status.sh --json | jq '.issues[] | select(.identifier=="ENG-N") | .labels | map(select(startswith("stage:"))) | length'
```
If the result is > 1, the issue has multiple stage labels.

**Via linear.sh:**
```bash
bash bin/linear.sh stage-of ENG-N
```
If the output contains a space, there are multiple labels.

### Decide which label to keep

Read the issue's comment history in Linear, focusing on the most recent `<!-- pipeline-stage-summary: -->` and `<!-- pipeline-transition: -->` comments.

- The `pipeline-stage-summary` marker shows which stage the agent reported completing.
- The `pipeline-transition` marker (usually from the orchestrator) shows the intended next stage.

The **correct label** is the one that matches the most recent transition the orchestrator intended. Typically:
1. If there's a fresh `<!-- pipeline-transition: X → Y -->` comment, the correct stage is `Y`.
2. If the last summary says stage `X` is done but no transition followed it, the correct stage is `X` (the orchestrator may still be deciding next steps).

Cross-check the label against the `<!-- pipeline-stage-summary: -->` comments to ensure consistency.

### Remove the wrong label

Once you've identified the incorrect label(s), remove them. The `PIPELINE_WRITER=human` env var is **required** — it unlocks the human lane in `bin/linear.sh` which allows removal.

```bash
PIPELINE_WRITER=human bash bin/linear.sh remove-label ENG-N stage:<wrong>
```

Repeat for each wrong label:
```bash
PIPELINE_WRITER=human bash bin/linear.sh remove-label ENG-N stage:<another-wrong>
```

### Verify

Confirm the issue now has exactly one stage label:

```bash
bash bin/linear.sh stage-of ENG-N
```

Expected output: a single line with `stage:X` where X is the correct stage (no spaces, no multiple labels).

---

## 2. Forged transition comment from a misbehaving agent

An issue has a `<!-- pipeline-transition: -->` comment that was posted by the agent (forbidden under the write-lane fence) rather than by the orchestrator. This can poison the freshness window in `verdict_handler`, causing the orchestrator to mis-classify the issue's state.

Symptoms:
- A `<!-- pipeline-transition: -->` comment appears in the middle of the agent's run (check timestamps in comment history).
- The comment's author is not the harness orchestrator user.
- The stage labels don't match what the comment claims (e.g., comment says "planning → implementing" but labels show "brainstorming").
- `verdict_handler` logs mention "protocol-violation: no-marker" or "no fresh verdict found" despite the agent posting a stage summary.

### Detect via comment history

Open the issue in Linear. Scroll through comments and look for `<!-- pipeline-transition: -->` markers. For each one:
1. Check the timestamp — it should be recent if it's legitimate. A 2+ day old transition is suspicious.
2. Check the author — it should be the harness orchestrator user account. If it's the target user or another service, it's forged.
3. Cross-check the `from` stage in the comment against the current `stage:*` labels. If they disagree, the comment is stale or forged.

### Detect via logs

Check the harness logs:
```bash
tail -100 ~/.local/state/twinning-harness/<project-slug>/logs/local-*.log
```

Look for entries around the suspected comment's timestamp. If you see no orchestrator log entry for `apply_transition` or `post-dispatch halt-check` at that time, but the comment exists in Linear, it's forged.

### Why you cannot delete the comment

Linear comments are append-only at the issue level — the API does not support comment deletion for historical audit reasons. The orchestrator retains comments as evidence. You cannot undo a forged comment; you can only work around it.

### Post a counter-marker

To advance the freshness window past the forged comment, post a new transition comment as the human lane. The orchestrator's `verdict_handler` will see the newer comment and use it instead.

```bash
PIPELINE_WRITER=human bash bin/linear.sh add-comment ENG-N "<!-- pipeline-transition: <correct-from> → <correct-to> -->

Manual correction by operator on $(date -u +%Y-%m-%dT%H:%M:%SZ)."
```

**Replace `<correct-from>` and `<correct-to>`** with:
- `<correct-from>`: the stage the issue should currently be in (check current `stage:*` labels).
- `<correct-to>`: the stage you want it to transition to next.

Example:
```bash
PIPELINE_WRITER=human bash bin/linear.sh add-comment ENG-26 "<!-- pipeline-transition: brainstorming → planning -->

Manual correction by operator on $(date -u +%Y-%m-%dT%H:%M:%SZ)."
```

The counter-marker doesn't change labels — it just resets the freshness boundary for the next `verdict_handler` run. The orchestrator will transition to the `to` stage on the next tick.

### Verify

Fetch the issue's comments and confirm the new marker is present:

```bash
bash bin/linear.sh get-comments ENG-N | jq -r '.[-5:][] | "\(.createdAt)  \(.body[:120])"'
```

Should show your new comment with the corrected transition. On the next poll tick (5 minutes), the orchestrator should pick up the issue and transition it to the `to` stage.

---

## 3. Stuck `pipeline:halted` with `protocol-violation` marker

An issue is permanently halted with the label `pipeline:halted` present and a `<!-- pipeline-halt: protocol-violation: ... -->` comment as the most recent halt marker. No fresh `<!-- pipeline-stage-summary: -->` exists newer than the latest `<!-- pipeline-transition: -->` comment, so `verdict_handler` cannot proceed.

### Detect

**Symptom 1: Label check**
```bash
bash bin/linear.sh has-label ENG-N pipeline:halted && echo "halted"
```
Expected output: `halted`.

**Symptom 2: Most recent halt marker is protocol-violation**
Open the issue in Linear and scroll to the most recent `<!-- pipeline-halt: -->` comment. It should contain `protocol-violation` in its marker.

**Symptom 3: No fresh stage-summary newer than transition**
In the comment history, find the most recent `<!-- pipeline-transition: -->` comment. Then look for a `<!-- pipeline-stage-summary: -->` comment newer than it. If none exists, the freshness window is empty — `verdict_handler` cannot find a verdict to advance.

### Diagnose the root cause

Before applying the fix, understand what went wrong:

```bash
tail -50 ~/.local/state/twinning-harness/<project-slug>/logs/local-*.log | grep -A 5 -B 5 "ENG-N"
```

Look for:
- Stage label changes not logged by the harness (evidence of forged transitions).
- `verdict_handler` returning "no fresh verdict found" or "stale comment" messages.
- Agent run times that don't correlate with the comments it posted.

If you find evidence of forged transitions (ENG-26 symptom), apply procedure 2 first (post a counter-marker). If the issue is stuck mid-transition with conflicting labels (ENG-24 symptom), identify the conflicting labels and apply procedure 1. Otherwise, proceed directly to remediation below.

### Remediation: resume via halt.sh

The simplest fix is to resume the issue:

```bash
bash bin/halt.sh resolve ENG-N --decision resume
```

The `halt.sh` script runs in the human lane internally, so it bypasses the lane fence. It will:
1. Remove `pipeline:halted`.
2. Remove any `pipeline:skip-until-*` labels.
3. Post a comment to Linear noting the manual resolution.

On the next poll tick, the orchestrator will re-evaluate the issue from its current state and pick a fresh next stage.

### If resume is insufficient

If the issue remains stuck after `resume` (e.g., the labels are still malformed or the freshness window is still poisoned), fall back to procedure 2:

1. Identify the **correct** stage the issue should be in (check current `stage:*` labels and comment history).
2. Post a counter-marker with `PIPELINE_WRITER=human` to advance the freshness window.
3. Run `resume` again.

Example:
```bash
# Post counter-marker
PIPELINE_WRITER=human bash bin/linear.sh add-comment ENG-N "<!-- pipeline-transition: brainstorming → planning -->

Manual correction by operator on $(date -u +%Y-%m-%dT%H:%M:%SZ)."

# Resume
bash bin/halt.sh resolve ENG-N --decision resume
```

### Verify

After running `resume` (or `resume` + counter-marker), check that:

1. The `pipeline:halted` label is gone:
   ```bash
   bash bin/linear.sh has-label ENG-N pipeline:halted || echo "not halted"
   ```
   Expected output: `not halted`.

2. The issue has a single `stage:*` label (procedure 1 if not):
   ```bash
   bash bin/linear.sh stage-of ENG-N
   ```
   Expected output: single line, one label.

3. On the next poll tick (~5 minutes), the orchestrator picks it up and the stage advances. Check logs:
   ```bash
   tail -20 ~/.local/state/twinning-harness/<project-slug>/logs/local-*.log | grep ENG-N
   ```
   Should see poll + classify + dispatch entries for the next stage.

---

## 4. Halted issue with stale-looking halt comment timestamp

An issue carries `pipeline:halted` but the most-recent halt comment shows a `createdAt` timestamp from a much earlier occurrence. The thread looks as if the halt was already resolved (no fresh comment appears to mark a re-fire), yet the label is present.

### Symptom

- `bash bin/linear.sh has-label ENG-N pipeline:halted` returns 0.
- The most-recent `<!-- pipeline: verdict result=halt … -->` comment's `createdAt` is many minutes/hours/days older than the most recent `bash bin/pipeline.sh decide ENG-N --action continue` operator action.
- Linear's web UI does NOT reliably surface "(edited)" for API-driven `commentUpdate` calls; do not rely on the indicator. `createdAt` is the original first-emission moment regardless of any updates.

### Authoritative signal

**The `pipeline:halted` LABEL is the state of record.** Comment `createdAt` reflects only the FIRST emission of any given halt body; identical-body re-applies update the existing comment in place. ENG-63 introduced a `<!-- meta: reapplied at=<iso8601-utc> -->` footer that gives operators an inspectable signal of the latest re-apply moment.

### Recency evidence

Filter for the most recent halt comment and inspect its full body:

```bash
bash bin/linear.sh get-comments ENG-N \
  | jq -r '.[] | select(.body | contains("verdict result=halt")) | .body' \
  | tail -1
```

Look for a `<!-- meta: reapplied at=<ts> -->` line at the bottom of that comment body. The timestamp on that line is the most recent re-application moment (NOT the original `createdAt`).

### Operator decision tree

- **Footer present AND timestamp recent (< 1h)** → halt is FRESH. Investigate the halt's `reason=` token (read the full comment body) BEFORE running `bash bin/pipeline.sh decide ENG-N --action continue`. A bare `--action continue` will be silently re-halted within seconds.
- **Footer present BUT timestamp old (> 1h)** → halt has not re-fired since the footer's timestamp; safe to investigate at leisure or run `bash bin/pipeline.sh decide ENG-N --action continue` if the cause was external (CI flake, infrastructure outage).
- **Footer absent** → halt has only ever been emitted once at `createdAt`; treat per §3 guidance.

### Verify

After `--action continue`, re-fetch the comment thread and confirm:

1. `bash bin/linear.sh has-label ENG-N pipeline:halted || echo "not halted"` returns `not halted`.
2. The next 5-minute poll tick proceeds without re-applying `pipeline:halted` — check `$PROJECT_STATE_DIR/logs/local-*.log` for a successful dispatch entry on the next stage.

---

## 5. Backfill — accumulated Canceled-issue worktrees from pre-ENG-64 hosts

ENG-64 fixed `bin/cleanup-worktrees.sh::issue_id_from_branch` for macOS;
before that fix, the BSD `sed` delimiter collision in the regex caused
`issue_id_from_branch` to silently return empty for every branch, so the
Canceled-issue cleanup branch never fired. Existing hosts have an
accumulated backlog of Canceled-issue worktrees under
`$PROJECT_STATE_DIR/ENG-*/worktree`.

**Action:** none required — the next periodic cleanup tick (every
`CLEANUP_EVERY_N_TICKS` ticks of `bin/run-local.sh`) will sweep them
automatically. To accelerate: `TARGET_REPO=… bash bin/cleanup-worktrees.sh`
runs the sweep manually; it is idempotent.

---

## 6. Halted issue with `worktree-mutation-forbidden` exit code

An issue carries `pipeline:halted` after a build dispatch with the halt
comment body referencing "build-stage transcript invoked forbidden
worktree-HEAD-mutating tool" and an `events.jsonl` row with
`outcome=worktree-mutation-forbidden`.

### Symptom

- `bash bin/linear.sh has-label ENG-N pipeline:halted` returns 0.
- The most-recent `<!-- pipeline: verdict result=halt reason=agent-blocked -->`
  halt comment body contains: `build-stage transcript invoked forbidden
  worktree-HEAD-mutating tool: <command>`.
- `events.jsonl` shows a `stage-end` event with
  `outcome=worktree-mutation-forbidden` for the building stage.
- Optionally, an additional `<!-- meta: metric name=worktree-mutated-by-agent -->`
  comment exists if the chained-command bypass also fired the post-dispatch
  HEAD-detection (D-003 path); the worktree's HEAD will then be detached.

### Authoritative signal

The build agent's tool allowlist excludes `git checkout`, `git switch`,
`git pull`, and `git reset` (verified at `bin/dispatch.sh::allowed_tools_for
"building"`). A transcript that invoked any of these — standalone or
chained — indicates either a tool-lane matcher bypass or a prompt-side
drift. The dispatch-time assertion (ENG-71 D-002) is the contract test;
the orchestrator's post-dispatch HEAD-detection (ENG-71 D-003) is the
catch-net for chained-command variants the assertion's `startswith`
matcher does not catch.

### Recovery

1. Inspect the matched command in the halt comment body. Confirm it
   is one of the four forbidden patterns and was issued by the build
   agent (not by an operator manually stepping into the worktree).
2. If the worktree HEAD is detached (D-003 fired), no operator action
   is required for the worktree itself — `cleanup-worktrees.sh` will
   remove it on the next post-merge tick.
3. If the worktree HEAD is on `main` AND the operator's primary
   `~/code/<repo>/` checkout is locked (`fatal: 'main' is already used
   by worktree at …`), manually detach: `git -C
   <issue-worktree-path> checkout --detach`. This is the same operation
   D-003 performs automatically; running it manually is safe and
   idempotent.
4. Resume the issue: `bash bin/pipeline.sh decide ENG-N --action continue`.
   The next tick re-dispatches build; if the underlying matcher bypass
   persists, the assertion will fire again (idempotent).

### Verify

After `--action continue`:

1. `bash bin/linear.sh has-label ENG-N pipeline:halted || echo "not halted"`
   returns `not halted`.
2. The next 5-minute poll tick re-dispatches build. Inspect the new
   dispatch's transcript at
   `$PROJECT_STATE_DIR/<ident>/logs/building-*.log` to confirm the
   re-dispatch is clean (no rc=26 in the log).

---

## 7. Halted issue with `branch-creation-forbidden` exit code

An issue carries `pipeline:halted` after any-stage dispatch with the
halt comment body referencing "agent transcript invoked forbidden
branch-creation form" and an `events.jsonl` row with
`outcome=branch-creation-forbidden`.

### Symptom

- `bash bin/linear.sh has-label ENG-N pipeline:halted` returns 0.
- The most-recent `<!-- pipeline: verdict result=halt reason=agent-blocked -->`
  halt comment body contains: `agent transcript invoked forbidden
  branch-creation form: <command>`, where `<command>` starts with one
  of `git checkout -b`, `git checkout -B`, `git branch -m`, or
  `git switch -c`.
- `events.jsonl` shows a `stage-end` event with
  `outcome=branch-creation-forbidden` for the offending stage.

### Authoritative signal

`AGENT_PROMPTS.md` §3 rule 2 explicitly forbids these four
branch-creation forms; the orchestrator has already created the
canonical `feat/eng-N-…` (or `fix/eng-N-…`) branch and checked it out
in the per-issue worktree before the agent's dispatch. An agent that
ran one of the four forbidden forms has likely created an off-canon
branch (e.g. `feature/eng-N-…`); the worktree's HEAD may now be on
that wrong branch. ENG-66's cross-stage runtime defense
(`bin/dispatch.sh::_render_and_capture_stream`) is the runtime tripwire
on top of the prompt rule and the
`bin/agent-prompts-content-test.sh:505` content pin.

### Recovery

1. Inspect the matched command in the halt comment body. Confirm it
   starts with one of the four banned forms.
2. Inspect the worktree HEAD:
   ```bash
   git -C "$PROJECT_STATE_DIR/<slug>/ENG-N/worktree" status
   ```
3. If the worktree's HEAD is on a wrong-named branch (e.g.
   `feature/eng-N-…`):
   1. Switch back to the canonical branch (use
      `bash bin/branch-name.sh ENG-N` to derive the canonical name):
      ```bash
      git -C <wt> checkout feat/eng-N-<slug>
      ```
   2. Delete the wrong-named branch:
      ```bash
      git -C <wt> branch -D <wrong-branch>
      ```
   3. Confirm `git -C <wt> status` shows `On branch feat/eng-N-…`.
4. Resume the issue:
   ```bash
   bash bin/pipeline.sh decide ENG-N --action continue
   ```

### Build-stage collision note

On the build stage, an `rc=26` halt with
`outcome=worktree-mutation-forbidden` whose sidecar shows a
`-b`/`-B`/`-c` form is the same underlying branch-creation drift
surfaced via the ENG-71 ordering (D-006 collision case). Apply the
same recovery recipe — the operator-facing recovery is identical
regardless of which exit code fired.

### Verify

After `--action continue`:

1. `bash bin/linear.sh has-label ENG-N pipeline:halted || echo "not halted"`
   returns `not halted`.
2. The next 5-minute poll tick re-dispatches the offending stage.
   Inspect the new dispatch's transcript at
   `$PROJECT_STATE_DIR/<ident>/logs/<stage>-*.log` to confirm the
   re-dispatch is clean (no rc=23 in the log).

---

## 8. Dispatch envelope violation (ENG-87)

A stage dispatch halts with halt-token `dispatch-envelope-violation`
(exit code 29). The post-dispatch envelope validator
(`bin/run-stage.sh::_validate_dispatch_envelope`) detected an EGREGIOUS
bypass of `bin/linear.sh`'s auto-injection chokepoint.

### Symptom

- Latest comment on the issue carries
  `<!-- pipeline: verdict result=halt reason=dispatch-envelope-violation -->`.
- `pipeline:halted` label applied by the orchestrator.
- The halt comment body lists the violation tokens
  (e.g. `mcp__plugin_linear:bash bin/...; ...`).
- A transcript sidecar at
  `$PROJECT_STATE_DIR/<ident>/.envelope-transcript-<stage>` is preserved
  across the halt for forensic review. The next dispatch's pre-clean at
  `bin/dispatch.sh::_render_and_capture_stream` (line 83) removes it
  unconditionally before any agent runs, so the sidecar survives until
  the operator reads it OR until `--action continue` triggers the next
  fresh dispatch.
- `events.jsonl` row with `outcome=envelope-violation` (per
  `bin/common.sh::failure_outcome_for_exit` exit-code 29).

### Interpretation

One of three causes:

1. **Linear MCP plugin invocation.** The agent ran
   `mcp__plugin_linear_*` (e.g. `mcp__plugin_linear_linear__save_issue`).
   This is forbidden because (a) `save_issue` overwrites the entire
   label set and silently strips `stage:*` / `pipeline:*` labels mid-flight
   (CLAUDE.md "Linear conventions the harness depends on" §), and (b) it
   bypasses the auto-injection chokepoint at
   `bin/linear.sh::_inject_dispatch_marker`, breaking the
   cross-dispatch staleness contract. Investigate
   `bin/dispatch.sh::allowed_tools_for` for accidental MCP-tool
   inclusion (verified absent at ENG-87 ship time, but a future
   regression could re-introduce).

2. **Direct `curl https://api.linear.app` invocation.** The agent
   bypassed `bin/linear.sh` entirely with a raw HTTP call to the Linear
   GraphQL API. Likely a prompt regression that re-introduced a
   "wrong-way" example, OR a learned-rules entry that surfaced an old
   curl recipe. Inspect the per-stage transcript at the sidecar path
   above; grep for `https://api.linear.app` in
   `learned-rules/<slug>/<stage>.md`.

3. **Allocator failed and the chokepoint logged unstamped comments.**
   Rare. Inspect `$PROJECT_STATE_DIR/<ident>/logs/<stage>-*.log` for
   `bin/common.sh::allocate_dispatch_id` errors (jq parse failures on
   `issue-state.json`, mv-f failures, missing `$PROJECT_STATE_DIR`).
   The agent then ran legitimately but the env var was empty, so the
   chokepoint emitted unstamped bodies. Investigate the allocator
   logs; an upstream JSON-corruption fix usually unblocks.

### Recovery

Inspect the transcript sidecar:

```bash
cat "$PROJECT_STATE_DIR/<ident>/.envelope-transcript-<stage>" | jq -c 'select(.type=="assistant") | .message.content[]? | select(.type=="tool_use" and (.input.command? // "" | startswith("mcp__plugin_linear") or startswith("curl https://api.linear.app")))'
```

Fix the underlying cause (allowlist edit in
`.pipeline-config/config.json::dispatch.tools`, prompt fix to
`AGENT_PROMPTS.md` or learned-rules, or allocator bug fix). Resume:

```bash
bash bin/pipeline.sh decide ENG-N --action continue
```

The atomic resume clears `pipeline:halted`, drops the per-issue
counter, and posts an operator-resume waypoint that resets the
freshness floor for the next dispatch (which re-allocates a fresh
`dispatch_id`). The transcript sidecar is removed by the next clean
dispatch's envelope validator.

### Why this halt exists

Defense-in-depth on top of the lane fence (ENG-41) and the chokepoint
auto-injection at `bin/linear.sh`. The auto-injection is the
preventive primitive — it stamps every comment posted via the
sanctioned path. The envelope validator catches any agent that
bypasses the chokepoint entirely (MCP fork or raw curl). Without this
backstop, a bypassing agent's writes would land on Linear unstamped,
and the next dispatch's `find_fresh_verdict` would treat them as the
operator-manual lane (no marker = legacy fallback to timestamp window),
defeating the cross-dispatch contract for that issue.

The chained-command blind spot — `bash bin/linear.sh add-comment …; mcp__plugin_linear …`
inside a single `tool_use.input.command` string — is documented at
`bin/run-stage.sh:867-881` and accepted as a trade-off (the `assert_no_tool_invocation`
helper uses startswith semantics and does not split on `;` / `&&`).
The AGENT_PROMPTS.md preamble's "Dispatch identifier and freshness
contract" subsection is the prompt-side defense for that gap.

### Forensic asymmetry post-resume

After `--action continue` clears the halt label and the next tick allocates
a fresh dispatch_id (e.g. d0008 replacing d0007), `find_fresh_verdict`'s
strict id-match path filters the d0007 halt comment OUT (its dispatch
marker says `id=d0007`, mismatching the current `id=d0008`). The issue
resumes correctly — the agent emits a fresh d0008 verdict that the
strict path picks up — but `bin/status.sh` and operator-triage workflows
that read verdict history will report "no fresh verdict" between the
`--action continue` and the next dispatch's first verdict emission.

This is a forensic regression, not control-flow-breaking. The pre-ENG-87
timestamp-window code would have surfaced the d0007 halt; the strict
path does not. To inspect a halted issue's prior-dispatch halts after
resume, query the comment history directly:

```bash
bash bin/linear.sh get-comments ENG-N \
  | jq -r '.[] | select(.body | contains("verdict result=halt")) | "\(.createdAt) \(.body[:200])"'
```

The `dispatch_history.jsonl` audit log
(`$(issue_dir <issue>)/dispatch_history.jsonl`) is also intact across
the halt — start/end rows for the d0007 dispatch survive the
`--action continue`.

---

## 9. Emergency: roll back concurrent dispatches to K=1

Roll the per-host (or per-project) `claude -p` concurrency cap back
to 1 — the pre-ENG-81 single-slot behaviour. Use this when:

- **Linear API rate-limit symptoms** — sudden cascade of `linear-post-failed`
  halts across multiple projects.
- **Unexpected `claude` subscription quota burns** — 5-hour rolling
  window saturated faster than budgeted.
- **Suspected race or bug in an ENG-81-adjacent change** — slot
  collision, lock-recovery loop, or new `_resolve_K` regression.

Two paths, neither requires a deploy: a host-wide env-var override
(below) or a per-project `config.json` edit.

### Host-wide rollback (preferred under acute incident)

Affects every project on this Mac immediately on next tick (each
project's plist injects the same env var):

```bash
# 1. Edit the plist for each project to add CLAUDE_MAX_CONCURRENT
plist="$HOME/Library/LaunchAgents/com.twinning.pipeline.<slug>.plist"

# Inside <key>EnvironmentVariables</key>'s <dict>, add:
#   <key>CLAUDE_MAX_CONCURRENT</key>
#   <string>1</string>

# 2. Reload the launchd job (bootout first; bootstrap fails on already-loaded service)
domain="gui/$(id -u)"
label="$(basename "$plist" .plist)"
if launchctl print "$domain/$label" >/dev/null 2>&1; then
  launchctl bootout "$domain/$label" || true
fi
launchctl bootstrap "$domain" "$plist"
```

Repeat per slug if you run multiple projects.

### Per-project rollback (when one project's bug should not affect others)

```bash
jq '.orchestrator.max_concurrent_features = 1' \
  "$TARGET_REPO/.pipeline-config/config.json" \
  > /tmp/c && mv /tmp/c "$TARGET_REPO/.pipeline-config/config.json"
```

The next tick (≤ 5 min) picks this up automatically.

### Verify

On the next tick, the local log MUST show `scheduler: K=1`:

```bash
grep 'scheduler: K=' \
  "$PROJECT_STATE_DIR/logs/local-$(date -u +%Y-%m-%d).log" \
  | tail -1
```

Only one `slot-*/pid` directory should exist under
`$HARNESS_STATE_DIR/.claude-semaphore/` at any moment:

```bash
ls "$HARNESS_STATE_DIR/.claude-semaphore/"slot-*/pid 2>/dev/null | wc -l
# → 0 or 1
```

### Restore (post-incident)

Host-wide: remove the `CLAUDE_MAX_CONCURRENT` entry from each plist
`EnvironmentVariables` block, then re-run the bootout-then-bootstrap
pattern above (bare `launchctl bootstrap` fails on an already-loaded
service).
Per-project: `jq '.orchestrator.max_concurrent_features = 2' …`
(or delete the key for the built-in default 2).

### See also

`CLAUDE.md` §"Per-project dispatch concurrency" for the full
resolution-precedence model + slot-occupancy interaction;
[`configuration.md` §`orchestrator.max_concurrent_features`](../configuration.md#orchestratormax_concurrent_features)
for the canonical config reference.

---

## Quick reference: env var requirement

Commands that write `stage:*` labels, remove `pipeline:halted`, or post transition comments require the `PIPELINE_WRITER=human` env var:

```bash
# Required:
PIPELINE_WRITER=human bash bin/linear.sh remove-label ENG-N stage:wrong
PIPELINE_WRITER=human bash bin/linear.sh add-comment ENG-N "<!-- pipeline-transition: ... -->"

# Not required:
bash bin/linear.sh has-label ENG-N pipeline:halted     # read-only
bash bin/linear.sh stage-of ENG-N                      # read-only
bash bin/halt.sh resolve ENG-N --decision resume       # sets lane internally
```

Without the env var, lane-denial errors will appear on stderr:
```
linear.sh: lane=orchestrator denied: remove-label stage:wrong
            (allowed lanes for stage:* remove: orchestrator, human)
```

If you see this, re-run the command with `PIPELINE_WRITER=human` prefix.

---

## ENG-68 follow-up: `core.bare` recurrence after fix

PR landing ENG-68 ships **preventative measures** that block the H1
trigger class (agent-dispatch invokes a `core.bare`-touching git form)
starting on the first dispatch post-merge: enumerated allowlist on
implement/ui (D-002) and a transcript-based assertion across all
stages (D-003), plus forensic capture (D-001) at both self-heal sites
for any non-H1 recurrence. The 30-day window starting from PR-merge
date is a **confirmation observation period** — if zero recurrences
fire, H1 was the root cause and the fix is complete; if ≥2 recurrences
fire without H1 signatures, we escalate to ENG-68-2 with the forensic
data set as the input.

### Decision rule

Count the number of times the `WARNING: $_git_dir had core.bare=true`
log line fires in `$PROJECT_STATE_DIR/logs/local-*.log` (or
`[pre-commit] WARNING: harness main repo had core.bare=true` in the
hook's stderr) during the 30 days post-merge.

| Recurrences in 30 days | Forensic class | Disposition |
|---|---|---|
| 0 | n/a | Close ENG-68 as "trigger class identified, fix shipped." Self-heal stays as belt-and-braces. |
| 1 | `recent-stage-transcripts` shows a tool_use with `.input.command` matching one of D-003's five patterns | Confirms H1; close ENG-68 with same disposition. The transcript assertion (D-003) was the prevention; the heal + forensic dump together prove the cause. |
| ≥ 2 | None of the dumps show a matching tool_use | Escalate. Open ENG-68-2 with the forensic dirs as the data-set, working through H2 / H3 / H4 in priority order (brainstorm §6). Do NOT auto-ship filesystem write-protection — that path lands on the new ticket. |

### Inspecting a forensic dump

```bash
ls $PROJECT_STATE_DIR/forensics/                   # list incidents
ls $PROJECT_STATE_DIR/forensics/core-bare-flip-<ts>/  # nine artifacts
cat $PROJECT_STATE_DIR/forensics/core-bare-flip-<ts>/config.before
cat $PROJECT_STATE_DIR/forensics/core-bare-flip-<ts>/reflog-HEAD
cat $PROJECT_STATE_DIR/forensics/core-bare-flip-<ts>/recent-stage-transcripts.list
```

Cross-reference fields to discriminate hypotheses (brainstorm §6):

- `config-mtime` — exact wall-clock of the write
- `recent-stage-transcripts` — was a stage active during the window?
- `ps-snapshot` — was a GUI tool active?
- `env-snapshot` — was `GIT_DIR` poisoned?

### Configuring the Linear announcement

Forensic dumps include a Linear comment heads-up (sig `core-bare-flip/<utc-iso-day>`)
IFF `LINEAR_API_KEY` and `PIPELINE_FORENSIC_FALLBACK_ISSUE` (or `PIPELINE_ISSUE_ID`)
are set when the helper fires. For the harness-self target, add to
`~/.config/twinning-harness/secrets.env`:

```bash
PIPELINE_FORENSIC_FALLBACK_ISSUE=ENG-68
```

Cross-project operators leave the env var unset and rely on the dir +
the `[forensic] core.bare=true detected … dump at …` line in the tick
log.
