# Pipeline Operator Guide

> The pipeline is an automated SDLC harness that takes Linear issues through brainstorm →
> plan → implement → UI → review → QA → build → release. It runs **entirely locally** on
> the Mac Studio via two launchd LaunchAgents and dispatches headless `claude -p` agents
> using the logged-in Claude subscription session. CI (`.github/workflows/release.yml`)
> only handles semantic-release version bumps and Mac/Windows binary builds — it never
> invokes an agent and never needs `ANTHROPIC_API_KEY`.

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

`claude -p` uses the logged-in subscription session on the Mac Studio; `ANTHROPIC_API_KEY` is **never** set — we deliberately avoid burning API tokens on top of the subscription. If the `claude` CLI session expires, all stages fail until `claude login` is re-run.

**GitHub Actions** — CI only runs `release.yml` (semantic-release + native binaries); no agent stages run in CI. Secrets needed under repo → Settings → Secrets → Actions:

| Secret | Required | Purpose |
|---|---|---|
| `PIPELINE_GH_PAT` | No | Fine-grained PAT with contents+pull-requests write, used by semantic-release to push the release commit to main. |

## Local runtime (Mac Studio / launchd)

### Install for a target repo

Run from the harness checkout:

```bash
bash bin/setup.sh /path/to/target-repo
```

`setup.sh` walks every onboarding phase idempotently — Linear auth,
team/project selection, label provisioning, slug freeze, GitHub App
credentials, `gh auth`, optional Slack, config defaults, validation, and
finally launchd installation. Re-run any time; satisfied phases are
skipped. To redo just one phase: `bash bin/setup.sh /path <phase>` (e.g.,
`linear-auth`, `slug-freeze`, `validate`).

The installer renders **both** launchd plist templates into `~/Library/LaunchAgents/`
and loads the agents:

| Agent | Cadence | What it does |
|---|---|---|
| `com.twinning.pipeline` | Every 5 min (`StartInterval=300`) | Runs `run-local.sh`: per-issue stage dispatch + release-watcher (detects new GitHub releases and invokes `on-new-release.sh` for the stage:building sweep and the release observer agent). |
| `com.twinning.retrospective` | Mondays 09:00 local (`StartCalendarInterval`) | Runs `run-retrospective-local.sh`: invokes the retrospective agent, opens a PR with any proposed rule/knowledge changes. |

Sleep/logout pauses both; wake resumes them on the next interval. A missed Monday
retrospective firing is handled by launchd's calendar-interval catch-up when the
Mac comes back online.

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

## Quickstart: run a specific issue / stage manually

Everything is local — there's no `gh workflow run` path anymore. Kick the full
per-tick poller once (it picks up whatever Linear says is next):

```bash
bash .pipeline/bin/run-local.sh
```

Or run one specific stage against one issue, bypassing the poller:

```bash
bash .pipeline/bin/run-stage.sh ENG-5 brainstorm
```

Run a weekly retrospective on demand:

```bash
bash .pipeline/bin/run-retrospective-local.sh
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
effect within 5 minutes with no commit required. Revert the flag to resume.

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

Set `PIPELINE_DRY_RUN=1` to exercise the harness without calling Claude or mutating Linear. `dispatch.sh` will print what it would invoke, `slack.sh` will no-op, `linear.sh` will suppress mutations but still perform reads.

```bash
PIPELINE_DRY_RUN=1 LINEAR_API_KEY=... bash .pipeline/bin/run-stage.sh ENG-5 brainstorm
```

## Multi-project layout

A single harness checkout drives N target repos by giving each a unique
project slug (derived once from the Linear project name and frozen in
`config.json::project.slug`). Per-project state lives at
`${XDG_STATE_HOME:-~/.local/state}/twinning-harness/<slug>/`. Each project
gets its own launchd pair: `com.twinning.pipeline.<slug>` and
`com.twinning.retrospective.<slug>`.

Shared secrets (`LINEAR_API_KEY`, `GH_APP_ID`, `GH_APP_PRIVATE_KEY_PATH`,
`PIPELINE_SLACK_WEBHOOK_URL`) live once at
`${XDG_CONFIG_HOME:-~/.config}/twinning-harness/secrets.env`. Per-project
`.env.local` only carries `GH_APP_INSTALLATION_ID`.

Cross-project `claude -p` calls are serialized via a global mutex at
`$HARNESS_STATE_DIR/.claude-mutex.lock/`, so two projects' ticks won't
overlap their agent calls.

### Migrating an existing single-project install

```bash
bash bin/setup.sh /path/to/twinning migrate
```

This single command performs the full upgrade — slug freeze, secrets
lift, state-dir relocation under `<slug>/`, learned-rules relocation
under `<slug>/`, legacy launchd bootout, and slug-suffixed reinstall.
Idempotent.

## Phase 2 (future) — not yet wired

- Linear webhook → local HTTP listener for instant pickup instead of 5-minute poll.
- Slack bot commands (approve/pause/resume) that write back to Linear.

## Minimal contributor workflow

When you want the pipeline to build a feature:

1. Write a well-specced Linear issue (use `.pipeline/LINEAR_ISSUE_TEMPLATE.md`).
2. Status starts as `Todo`. Leave it there — the poller picks it up.
3. Watch the issue comments for progress; PRs will be opened by the bot.
4. When a reconcile or guard requires you, add the appropriate label.
5. Review + merge the final PR like any other.

## Per-Issue State Directory (ENG-15)

All per-issue state lives under `~/.twinning-pipeline/ENG-N/`:

````
~/.twinning-pipeline/
├── .consecutive-failures    # global breaker counter
├── .run-local.lock/         # global tick lock
├── .tick-counter            # global tick counter
├── github.pem               # GitHub App private key
├── metrics/
│   └── events.jsonl         # pipeline-wide telemetry
└── ENG-N/                   # one dir per in-flight issue
    ├── worktree/            # git worktree for the feature branch
    ├── issue-state.json     # retry memory (ENG-15) — see schema below
    └── scope-approval       # optional, legacy scope-approval state
````

### issue-state.json schema

Written by `classify_failure` at every failure exit site in `run-stage.sh`; read by `poll.sh` on every tick; deleted on stage success.

```json
{
  "issue": "ENG-N",
  "stage": "implement",
  "policy": "skip-until-code-changes | skip-until-human-acts | retry-immediately",
  "reason": "human-readable cause copied into the Linear halt comment",
  "exit_code": 21,
  "exit_subcode": 2,
  "recorded_at": "2026-04-20T10:38:39Z",
  "retry_count": 0,
  "branch": "feat/eng-N-slug",
  "evidence": {
    "pipeline_content_hash": "sha256 of .pipeline/{bin/**, config.json, AGENT_PROMPTS.md}",
    "branch_head_sha": "git ls-remote origin <branch> at failure time"
  }
}
```

## Pipeline Comment Sig Registry (ENG-15)

Every pipeline-authored Linear comment that represents a "current state" of some (issue, stage, class) carries a hidden marker so repeats edit-in-place instead of accumulating.

| Class | Sig | Emitted by |
|---|---|---|
| Halt / skip | `halt/<stage>/<issue>` | classify_failure in classify-failure.sh |
| Scope approval pending | `scope-approval/<stage>/<issue>` | run-stage.sh (scope-check rc=1) |
| TDD evidence | `tdd-evidence/<stage>/<issue>` | implement + ui agents |
| Completion checklist | `completion/<stage>/<issue>` | orchestrator (run-stage.sh `post_completion_comment`) |
| Reconcile notice | `reconcile/<stage>/<issue>` | run-local.sh reconcile |
| Release enrichment | `release-enrichment/<version>/<issue>` | release agent |

New classes should follow `<class>/<stage>/<issue>`.
