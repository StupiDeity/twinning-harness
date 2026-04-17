# Pipeline Operator Guide

> The pipeline is an automated SDLC harness that takes Linear issues through brainstorm →
> plan → implement → UI → review → QA → build → release. It runs on GitHub Actions
> and dispatches headless `claude -p` agents.

## Architecture at a glance

```
Linear (source of truth)           GitHub Actions (runtime)
───────────────────────            ──────────────────────────────
 Issue status  ─────┐               ┌───  .github/workflows/pipeline.yml
 Labels       ──────┤  Linear API   │       ↓ every 15 min
                    ├────────────────┼────► .pipeline/bin/poll.sh
 Comments     ──────┘               │       ↓ decides (issue, stage)
                                    │       ↓
                                    └────► .pipeline/bin/run-stage.sh
                                            ↓ renders prompt
                                            ↓ calls: claude -p
                                            ↓ commits docs / opens PRs
                                            ↓ swaps stage:* label
```

## Required secrets

Configure under repo → Settings → Secrets → Actions:

| Secret | Required | Purpose |
|---|---|---|
| `LINEAR_API_KEY` | Yes | Linear GraphQL auth. Personal API key (Settings → API). |
| `ANTHROPIC_API_KEY` | Yes | Headless `claude -p` invocations. |
| `PIPELINE_GH_PAT` | No | Fine-grained PAT with contents+pull-requests write, used so that pushes from the pipeline trigger other workflows (default `GITHUB_TOKEN` does not). |
| `PIPELINE_SLACK_WEBHOOK_URL` | No | Slack incoming webhook. If omitted, `slack.sh` no-ops. |

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

Commit and push. `poll.sh` will exit with an `idle` record and no stages will dispatch.
Revert the flag to resume.

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

1. **Workflow run red?** Open the GitHub Actions run. The failing step's log is the source of truth.
2. **Stage dispatched but Linear state didn't advance?** Check `docs/knowledge/pipeline-metrics.md` for the last event on that issue. If `outcome=failed`, find the `log=` path in the notes and read the agent transcript.
3. **Issue stuck in `stage:X` for hours?** Inspect the issue's Linear comments — `guards.sh` and `reconcile.sh` post diagnostic comments. If nothing there, trigger `workflow_dispatch` with the explicit stage to retry.
4. **Unexpected Linear writes or label flips?** Check git history on `.pipeline/schemas/linear-ids.json` — a stale cache is the most common cause of wrong-target mutations.
5. **Kill switch:** flip `orchestrator.paused: true` in `config.json`.

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
