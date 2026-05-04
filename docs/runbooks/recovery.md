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
