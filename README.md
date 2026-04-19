# Pipeline Operator Guide

> The pipeline is an automated SDLC harness that takes Linear issues through brainstorm →
> plan → implement → UI → review → QA → build → release. It runs locally on the Mac
> Studio via a launchd LaunchAgent and dispatches headless `claude -p` agents. GitHub
> Actions remains available for manual `workflow_dispatch` runs.

## Architecture at a glance

```
Linear (source of truth)           Local runtime (Mac Studio)
───────────────────────            ──────────────────────────────
 Issue status  ─────┐               ┌───  launchd: com.twinning.pipeline
 Labels       ──────┤  Linear API   │       ↓ every 5 min (StartInterval=300)
                    ├────────────────┼────► .pipeline/bin/run-local.sh
 Comments     ──────┘               │       ↓ lock + env + pause-check
                                    │       ↓
                                    ├────► .pipeline/bin/poll.sh
                                    │       ↓ decides (issue, stage)
                                    │       ↓
                                    └────► .pipeline/bin/run-stage.sh
                                            ↓ renders prompt
                                            ↓ calls: claude -p   (subscription auth)
                                            ↓ commits docs / opens PRs
                                            ↓ swaps stage:* label
```

## Required secrets

**Local runtime** — put in `.pipeline/.env.local` (gitignored; see `.env.local.example`):

| Var | Required | Purpose |
|---|---|---|
| `LINEAR_API_KEY` | Yes | Linear GraphQL auth. Personal API key (Settings → API). |
| `PIPELINE_SLACK_WEBHOOK_URL` | No | Slack incoming webhook. If omitted, `slack.sh` no-ops. |

`claude -p` uses the logged-in subscription session on the Mac Studio; no `ANTHROPIC_API_KEY` is needed locally.

**GitHub Actions manual dispatch** — configure under repo → Settings → Secrets → Actions:

| Secret | Required | Purpose |
|---|---|---|
| `LINEAR_API_KEY` | Yes | As above. |
| `ANTHROPIC_API_KEY` | Yes | Required in CI because the runner has no subscription session. |
| `PIPELINE_GH_PAT` | No | Fine-grained PAT with contents+pull-requests write, used so that pushes from the pipeline trigger other workflows (default `GITHUB_TOKEN` does not). |
| `PIPELINE_SLACK_WEBHOOK_URL` | No | Slack incoming webhook. |

## Local runtime (Mac Studio / launchd)

Install once on the Mac Studio:

```bash
cp .pipeline/.env.local.example .pipeline/.env.local
# edit .pipeline/.env.local — paste LINEAR_API_KEY
bash .pipeline/bin/install-launchd.sh
```

The installer renders `.pipeline/launchd/com.twinning.pipeline.plist.template` into
`~/Library/LaunchAgents/com.twinning.pipeline.plist`, loads the agent, and kicks
the first tick. From then on the agent fires every 5 min; sleep/logout pauses it,
wake resumes it on the next interval.

Observe:

```bash
launchctl list | grep com.twinning.pipeline                          # status / last exit
tail -f logs/pipeline/local-$(date -u +%Y-%m-%d).log                  # per-tick rolling log
tail -f logs/pipeline/launchd.err.log                                 # anything launchd captured
bash .pipeline/bin/status.sh                                          # dashboard (works regardless of runtime)
```

Stop / uninstall:

```bash
bash .pipeline/bin/uninstall-launchd.sh
```

### Circuit breaker

`run-local.sh` counts consecutive `run-stage.sh` failures in
`.pipeline/.consecutive-failures`. After **3** in a row it sets
`orchestrator.paused = true` in `config.json` and subsequent ticks skip until a
human resets the flag. Success clears the counter.

## Quickstart: run a specific issue

```bash
gh workflow run pipeline.yml -f issue_id=ENG-5 -f stage=brainstorm
```

Or kick the poller manually:

```bash
gh workflow run pipeline.yml
```

## Controlling an issue with labels

| Label | Meaning |
|---|---|
| `stage:brainstorming` … `stage:released` | Current pipeline stage. The orchestrator swaps this as it advances. Do not set manually except to re-enter the pipeline. |
| `pipeline:paused` | Halt advancement on **this issue** until removed. |
| `pipeline:supersede` | On a reconcile-human decision: treat any pre-existing brainstorm/plan as stale; generate fresh. |
| `pipeline:extend` | On reconcile: generate fresh, but agent should read the pre-existing doc as context. |
| `pipeline:ignore` | On reconcile: the pre-existing doc is canonical; link it and advance without regenerating. |
| `pipeline:reviewed` | Human ack: review-rejection threshold acknowledged, resume. |
| `pipeline:knowledge-reviewed` | Human ack: gotcha-trigger threshold acknowledged, resume. |
| `pipeline:rule-reviewed` | Human ack: learned-rule renewal threshold acknowledged, resume. |

## Pausing the whole pipeline

Edit `.pipeline/config.json` and set:

```json
"orchestrator": { "paused": true, ... }
```

Local runtime reads `config.json` at the start of each tick, so the change takes
effect within 5 minutes with no commit required. For GHA `workflow_dispatch` runs
to respect it, commit and push. Revert the flag to resume.

## Reading metrics

`docs/knowledge/pipeline-metrics.md` is append-only. Each line is a timestamped event:

```
- `2026-04-17T12:34:56Z` event=stage-end issue=ENG-5 stage=brainstorm outcome=success duration_ms=84210 notes="next=planning"
```

Grep by `issue=` to trace a specific feature; grep by `outcome=failed` to find incidents.

## Regenerating the Linear ID cache

Run locally:

```bash
LINEAR_API_KEY=... bash .pipeline/bin/linear.sh refresh-cache
```

Commit the updated `.pipeline/schemas/linear-ids.json` if the set of states or labels changed.

## Failure playbook

1. **Tick failing on the Mac Studio?** Read `logs/pipeline/local-YYYY-MM-DD.log` for the wrapper's view, then the per-stage transcript under `logs/pipeline/<ISSUE>-<stage>-<ts>.log`.
2. **Circuit breaker tripped?** `orchestrator.paused` will be `true` and `.pipeline/.consecutive-failures` will be ≥3. Diagnose the underlying stage failures, then flip `paused` back to `false`. The counter is cleared on the next successful tick.
3. **Stage dispatched but Linear state didn't advance?** Check `docs/knowledge/pipeline-metrics.md` for the last event on that issue. If `outcome=failed`, find the `log=` path in the notes and read the agent transcript.
4. **Issue stuck in `stage:X` for hours?** Inspect the issue's Linear comments — `guards.sh` and `reconcile.sh` post diagnostic comments. If nothing there, trigger `workflow_dispatch` with the explicit stage to retry.
5. **Unexpected Linear writes or label flips?** Check git history on `.pipeline/schemas/linear-ids.json` — a stale cache is the most common cause of wrong-target mutations.
6. **Kill switch:** flip `orchestrator.paused: true` in `config.json` (local takes effect next tick; commit+push for GHA).

## Dry-run mode

Set `PIPELINE_DRY_RUN=1` (or pass `dry_run: true` to `workflow_dispatch`) to exercise the harness without calling Claude or mutating Linear. `dispatch.sh` will print what it would invoke, `slack.sh` will no-op, `linear.sh` will suppress mutations but still perform reads.

```bash
PIPELINE_DRY_RUN=1 LINEAR_API_KEY=... bash .pipeline/bin/run-stage.sh ENG-5 brainstorm
```

## Phase 2 (future) — not yet wired

- Linear webhook → `repository_dispatch` for instant pickup instead of 15-minute cron.
- Dedicated retrospective runner invoking the retrospective agent on schedule.
- Slack bot commands (approve/pause/resume) that write back to Linear.

## Minimal contributor workflow

When you want the pipeline to build a feature:

1. Write a well-specced Linear issue (use `.pipeline/LINEAR_ISSUE_TEMPLATE.md`).
2. Status starts as `Todo`. Leave it there — the poller picks it up.
3. Watch the issue comments for progress; PRs will be opened by the bot.
4. When a reconcile or guard requires you, add the appropriate label.
5. Review + merge the final PR like any other.
