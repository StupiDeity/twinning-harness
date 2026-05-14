# Day-to-day operation

This is the deep operator handbook. For the README's high-level summary,
see the [Day-to-day section](../README.md#day-to-day-operation).

For symptom-to-fix recovery, see
[`runbooks/recovery.md`](runbooks/recovery.md). For mental-model gaps,
see [`runbooks/operator-mental-model.md`](runbooks/operator-mental-model.md).

## Filing a Linear issue the harness will pick up

The harness picks up issues that satisfy **all** of:

1. Status is `Todo`.
2. Exactly one type label: `Bug` / `Feature` / `Improvement`.
3. No `stage:*` label yet.
4. Belongs to the configured Linear project (`config.json::linear.project_id`).

Use the body template at
[`LINEAR_ISSUE_TEMPLATE.md`](../LINEAR_ISSUE_TEMPLATE.md). The brainstorm
agent's output quality is bounded by the spec quality. Worth re-reading:

- **Title** — verb-first, specific.
- **Problem statement** — written from the user's perspective.
- **Desired outcome** — concrete, testable.
- **Scope boundaries** — explicit IN and OUT.
- **Acceptance criteria** — numbered, testable.

A vague spec will produce a vague brainstorm and a wrong implementation,
expensively. Spending 10 minutes on the spec saves 30 minutes of
operator-resume cycles.

## Inspecting status

```bash
bash bin/status.sh
```

Read-only dashboard combining Linear issue states + recent `gh` PR
activity + the metrics jsonl. No mutations. Run any time.

JSON output for scripting:

```bash
bash bin/status.sh --json | jq '...'
```

## Reading Linear comment markers

Every pipeline-driving comment carries an HTML marker. Two families:

- **`<!-- pipeline: <event> ... -->`** — drives state. Read by the orchestrator.
- **`<!-- meta: <kind> ... -->`** — bookkeeping. Read by individual scripts.

The most common markers you'll see in a thread:

| Marker shape | Means |
|---|---|
| `<!-- pipeline: transition from=X to=Y -->` | Stage advance. Posted by orchestrator. |
| `<!-- pipeline: verdict result=pass stage=X -->` | Stage X passed. Agent or orchestrator. |
| `<!-- pipeline: verdict result=fail target=X reason=R -->` | Stage failed; loopback to X. |
| `<!-- pipeline: verdict result=halt reason=R -->` | Halted; needs operator action. |
| `<!-- pipeline: verdict result=wait reason=awaiting-approval -->` | Build P2 waiting. |
| `<!-- pipeline: decision action=continue -->` | Operator resumed. |
| `<!-- meta: dedup key=halt/<stage>/<issue> -->` | This comment edits in place. |
| `<!-- meta: reapplied at=2026-05-08T19:37:31Z -->` | Latest re-apply moment (the visible `createdAt` is FIRST emission). |

Full registry at [`pipeline-vocabulary.md`](pipeline-vocabulary.md).

## Resolving a halt <a id="resolving-a-halt"></a>

The single canonical command:

```bash
bash bin/pipeline.sh decide ENG-N --action continue
```

This is **atomic and idempotent**. It clears:

1. `pipeline:halted` label
2. `pipeline:skip-until-code-changes`, `pipeline:skip-until-human-acts` labels
3. `$PROJECT_STATE_DIR/<ident>/wait-*.json` files
4. `$PROJECT_STATE_DIR/<ident>/issue-state.json` if its `policy ==
   "skip-until-human-acts"`
5. Global breaker: `orchestrator.paused=true` (cleared) and
   `$PROJECT_STATE_DIR/.consecutive-failures` (removed)
6. Per-issue counter: `$PROJECT_STATE_DIR/<ident>/.consecutive-failures`
7. Posts a `<!-- pipeline: transition from=<stage> to=<stage>
   reason=operator-resume -->` waypoint to reset the rejection counter
   and freshness checks.

The waypoint posts LAST, so a partial-failure during cleanup leaves the
issue re-runnable.

### Approving a scope violation

When scope-check fires SEVERE on intentional cross-cutting work:

```bash
bash bin/pipeline.sh decide ENG-N --action approve --gate scope
```

Next tick, scope-check sees the approval and bypasses the gate.

### Approving a build (human-approval gate)

The build agent waits for at least one `APPROVED` review from a
non-bot user. You don't run a CLI for this — you click Approve on the
PR like any reviewer. The next tick, the build agent's P2 sees the
approval and proceeds to merge.

If you want to bypass the human gate (e.g., for a hotfix where you
trust the bot):

```bash
bash bin/pipeline.sh decide ENG-N --action approve --gate build-cap
```

### Abandoning an issue

If an issue was filed in error or has been superseded:

```bash
bash bin/pipeline.sh decide ENG-N --action abandon
```

Applies `pipeline:abandoned`. Issue is terminal; never recalled. Slot is
vacated.

## Pausing and resuming

### Pause one issue

Apply `pipeline:halted` in Linear:

```bash
bash bin/linear.sh add-label ENG-N pipeline:halted
```

Resume with the standard `decide --action continue`.

### Pause everything (kill switch)

Edit `$TARGET_REPO/.pipeline-config/state.local.json`:

```json
{ "orchestrator": { "paused": true } }
```

Or:

```bash
jq '.orchestrator.paused = true' state.local.json | sponge state.local.json
```

Takes effect within 5 minutes (next tick). Revert to `false` to resume.

The breaker writes `paused=true` here automatically when 3 consecutive
ticks fail with `rc=24` (`linear-post-failed`). A `decide --action
continue` against any halted issue clears it.

## Running a stage manually

Bypass the poller and run one stage against one issue:

```bash
TARGET_REPO=/path/to/target bash bin/run-stage.sh ENG-5 brainstorming
```

Stage names are gerund form: `brainstorming`, `planning`, `implementing`,
`ui`, `reviewing`, `qa`, `building`, `released`.

Useful for:
- Re-running a stage after fixing the underlying spec.
- Testing prompt changes without waiting for the next tick.
- Forcing forward progress on a stuck issue.

This invokes the same code path as the launchd tick — same
allowed-tools, same scope-check, same verdict handling. The only
difference is the orchestrator-side single-flight lock might briefly
contend if a tick is in flight.

## Dry-run mode

Set `PIPELINE_DRY_RUN=1` on any command. Suppresses:

- Linear writes (reads still happen)
- `claude -p` invocation (echoes what it would invoke)
- Slack webhook posts

```bash
PIPELINE_DRY_RUN=1 TARGET_REPO=/path bash bin/run-stage.sh ENG-5 brainstorming
PIPELINE_DRY_RUN=1 TARGET_REPO=/path bash bin/run-local.sh
```

The `bin/dry-run.sh` script uses this internally to validate the entire
harness end-to-end without side effects — it's what `setup.sh validate`
runs.

## Artifact locations <a id="artifact-locations"></a>

```
$HARNESS_ROOT/                       (this repo)
$TARGET_REPO/                        (your project, mutated by agents)
  └─ .pipeline-config/               (gitignored)
      ├─ config.json                 (orchestrator behavior)
      ├─ state.local.json            (runtime overrides — paused flag)
      ├─ schemas/linear-ids.json     (cached Linear IDs)
      └─ .env.local                  (per-target overrides)

$HARNESS_CONFIG_DIR/                 ($XDG_CONFIG_HOME/twinning-harness)
  ├─ secrets.env                     (LINEAR_API_KEY, GH_APP_*)
  └─ github-app.pem                  (App private key, 0600)

$HARNESS_STATE_DIR/                  ($XDG_STATE_HOME/twinning-harness)
  ├─ .claude-semaphore/              (global counting semaphore — slot-<N>/pid; cap from orchestrator.max_concurrent_features, default 2; ENG-81)
  └─ <slug>/                         (= $PROJECT_STATE_DIR)
      ├─ target-repo                 (collision sentinel)
      ├─ .consecutive-failures       (global breaker counter)
      ├─ .run-local.lock/            (per-tick lock)
      ├─ .tick-counter
      ├─ last-observed-release
      ├─ logs/
      │   ├─ local-YYYY-MM-DD.log    (per-tick rolling log)
      │   ├─ <stage>-<issue>-<ts>.log (per-stage agent transcripts)
      │   └─ launchd.{out,err}.log   (launchd captures)
      ├─ metrics/events.jsonl        (telemetry, append-only)
      └─ ENG-N/                      (per-issue state)
          ├─ worktree/               (git worktree, feature branch)
          ├─ issue-state.json        (retry memory + failure policy)
          ├─ .consecutive-failures   (per-issue counter)
          ├─ stage-summary-*.md      (agent-authored summaries)
          ├─ wait-<stage>.json       (wait-budget tracking)
          └─ usage-<stage>.json      (cost telemetry per dispatch)
```

### `issue-state.json` schema <a id="issue-statejson-schema"></a>

Written by `classify_failure` at every failure exit site in
`run-stage.sh`. Read by `poll.sh` on every tick. Deleted on stage
success.

```json
{
  "issue": "ENG-N",
  "stage": "implementing",
  "policy": "skip-until-code-changes | skip-until-human-acts | retry-immediately",
  "reason": "human-readable cause copied into the Linear halt comment",
  "exit_code": 21,
  "exit_subcode": 2,
  "recorded_at": "2026-04-20T10:38:39Z",
  "retry_count": 0,
  "branch": "feat/eng-N-slug",
  "evidence": {
    "pipeline_content_hash": "sha256 of bin/**, config.json, AGENT_PROMPTS.md",
    "branch_head_sha": "git ls-remote origin <branch> at failure time"
  }
}
```

### `events.jsonl`

JSONL, append-only. Each line is a metric event:

```json
{"ts":"2026-04-17T12:34:56Z","event":"stage-end","issue":"ENG-5","stage":"brainstorming","outcome":"success","duration_ms":84210,"cost_usd":1.42,"notes":"next=planning"}
```

Common event types:

| Event | Emitted when |
|---|---|
| `stage-start` | Orchestrator dispatches an agent |
| `stage-end` | Stage completes (any outcome) |
| `dispatch-skipped` | Entry-conditions gate skipped dispatch |
| `breaker-tripped` | 3 consecutive failures landed |
| `transient-retry` | Recoverable failure, retry next tick |

The retrospective reads the full history. **Don't truncate or rotate**
— prune only under disk pressure.

## Failure modes (quick reference)

| Symptom | First place to look |
|---|---|
| Tick is silent | `$PROJECT_STATE_DIR/logs/local-YYYY-MM-DD.log`, then per-stage transcript |
| Per-issue halt | Linear comments under sig `halt/<stage>/<issue>`. Resume: `bash bin/pipeline.sh decide ENG-N --action continue` |
| Global breaker tripped | `$PROJECT_STATE_DIR/.consecutive-failures ≥ 3`; `orchestrator.paused=true`. Reset: any `--action continue`, or set `paused=false` |
| Issue stuck in `stage:X` | `halt/<stage>/<issue>` or `scope-approval/<stage>/<issue>` sigs; check `<!-- meta: reapplied at=… -->` for latest re-apply |
| Wrong-target Linear writes | `git log` on `linear-ids.json` — stale cache |
| Brainstorm halts at `iteration-exhausted` | New ENG-65 behavior: voluntary halt after 2 persona-review iterations. Resume after fixing P0. |
| Build idles with `dispatch-skipped` events | `wait-building.json::attempts` is climbing — entry-conditions gate firing skip per `gh pr view`. Likely PR not approved by Code Owner, or `gh` not on PATH for `launchd` |
| scope-check halts on upstream merge files | Pre-ENG-59 bug. Post-ENG-59 fetches `origin main` per run. If still seeing this: per-stage transcript will say `scope-check: fetch origin main failed` |

Detailed recovery procedures: [`runbooks/recovery.md`](runbooks/recovery.md).

## Cost monitoring

Per-dispatch cost lands in `$PROJECT_STATE_DIR/<ident>/usage-<stage>.json`:

```json
{
  "stage": "implementing",
  "cost_usd": 4.12,
  "input_tokens": 142000,
  "output_tokens": 8200,
  "cache_read_tokens": 380000,
  "model": "claude-opus-4-7"
}
```

Per-issue cumulative cost is the sum across stages. Cross-issue
aggregation: `events.jsonl` carries `cost_usd` per `stage-end`.

```bash
# Total cost for an issue:
jq -r 'select(.issue=="ENG-5" and .event=="stage-end") | .cost_usd' \
  "$PROJECT_STATE_DIR/metrics/events.jsonl" | awk '{s+=$1} END{print s}'

# Total cost this week:
jq -r 'select(.event=="stage-end" and .ts >= "2026-05-05") | .cost_usd' \
  "$PROJECT_STATE_DIR/metrics/events.jsonl" | awk '{s+=$1} END{print s}'
```

When SIGTERM fires before a `result` event lands (dispatch timeout),
the renderer writes a partial `usage-<stage>.json` with `cost_usd: null`
and `partial: true`. The retrospective uses `partial: true` as the
discriminator for SIGTERM-captured runs.

## Watching the next tick

```bash
tail -f "${XDG_STATE_HOME:-$HOME/.local/state}/twinning-harness/<slug>/logs/local-$(date -u +%Y-%m-%d).log"
```

A normal tick:

```
2026-05-08T20:15:00Z poll: choosing next (issue, stage)
2026-05-08T20:15:00Z poll: ENG-N stage:implementing slot=hold advanceable=true
2026-05-08T20:15:01Z run-stage: ENG-N implementing
2026-05-08T20:15:01Z dispatch: gtimeout 1800 claude -p ... (stage=implementing)
... (agent transcript) ...
2026-05-08T20:32:14Z verdict: pass stage=implementing
2026-05-08T20:32:14Z scope-check: clean
2026-05-08T20:32:15Z transition: implementing → reviewing
2026-05-08T20:32:15Z tick complete (rc=0)
```

Anything else (halts, breaker writes, errors) shows up here first.
