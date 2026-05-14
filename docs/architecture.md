# Architecture

Deep dive on runtime topology, dispatch lifecycle, and the structural
invariants the harness depends on. For the README's high-level summary,
see [How it works](../README.md#how-it-works).

## Two binaries, peer roles

The harness ships two `launchd` agents:

| Binary | Cadence | Entrypoint | Reads | Writes |
|---|---|---|---|---|
| **Orchestrator** | Every 5 min (`StartInterval=300`) | `bin/run-local.sh` | Linear (status, labels, comments), GitHub (PRs, checks), `$PROJECT_STATE_DIR` | Linear (markers, labels), GitHub (commits, PRs), `$PROJECT_STATE_DIR/{logs,metrics,ENG-N/...}` |
| **Retrospective** | Mondays 09:00 (`StartCalendarInterval`) | `bin/run-retrospective-local.sh` | `$PROJECT_STATE_DIR/metrics/events.jsonl`, per-stage transcripts, `learned-rules/*.md` | A PR proposing edits to `learned-rules/*.md` |

They share nothing except the global Claude mutex
(`$HARNESS_STATE_DIR/.claude-mutex.lock/`), which serializes their
`claude -p` invocations system-wide.

The retrospective is a **peer**, not a footnote. It's how the harness
learns from its own runs: every week, an agent reads the metric stream
+ failed-stage transcripts and proposes edits to the rule files that
get appended to base prompts at dispatch time. You review the PR; if
you merge, future agent runs see the updated prompts.

## Three roots, three storage tiers

Every script sources `bin/common.sh`, which resolves three roots:

| Variable | Default | Holds |
|---|---|---|
| `HARNESS_ROOT` | derived from `bin/common.sh` location | this repo (scripts, prompts, learned rules) |
| `TARGET_REPO` | **required, no default** | the project being driven |
| `HARNESS_STATE_DIR` | `${XDG_STATE_HOME:-~/.local/state}/twinning-harness` | per-issue state, locks, logs, metrics |
| `HARNESS_CONFIG_DIR` | `${XDG_CONFIG_HOME:-~/.config}/twinning-harness` | shared secrets, GitHub App private key |
| `PROJECT_SLUG` | derived from `config.json::project.slug` | per-project namespace key (frozen at first setup) |
| `PROJECT_STATE_DIR` | `$HARNESS_STATE_DIR/$PROJECT_SLUG` | per-project state |

Derived (do not override):

- `TARGET_CONFIG_DIR = $TARGET_REPO/.pipeline-config` — `config.json`,
  `schemas/linear-ids.json`, `.env.local`, `state.local.json`
- `STATE_FILE = $TARGET_CONFIG_DIR/state.local.json` — runtime override
  for `orchestrator.paused`; writes go here, not to `config.json`

## Discovery and the project profile

The orchestrator is stack-neutral. Per-target stack knowledge lives in
`$HARNESS_ROOT/learned-rules/<slug>/project-profile.md` — a markdown
file with a YAML frontmatter `schema_version: 2` and six H2 sections
(Stack, Build & test gates, Tool allowlist, File layout, Language
idioms, Don'ts).

The profile is authored by a **one-shot discovery agent** run via
`bash bin/setup.sh /path/to/target project-profile` (Phase 5b of
setup). The discovery prompt at `bin/setup-prompts/discovery.md` walks
the target's manifests, `.github/workflows/`, and dotfiles to elicit
the six sections. The result is checked into the harness repo (NOT
the target) under `learned-rules/<slug>/`.

The profile drives three things:

| Consumer | Reads | Effect |
|---|---|---|
| `bin/dispatch.sh::_dispatch_tools_from_profile` | `## Tool allowlist` | Per-stage `--allowed-tools` argv composition (the profile-derived middle tier of **stack-neutral base + profile-derived stack tools + operator-curated extras**) |
| `bin/run-local-helpers.sh::stage_output_paths` | `## File layout` | Per-stage scope allowlist for the post-dispatch sweep |
| `bin/render-prompt.sh::append_project_profile` | Entire file | Appended to every non-retrospective dispatch's prompt |

If a profile is missing or its schema is wrong, dispatch falls back to
**stack-neutral base + operator-curated extras** (the middle tier
drops out) and emits one `[allowed-tools]` warning per stage to
stderr. The target keeps working on the universal lockfile catalog +
`docs/` scope allowlist (see Sweep + scope partition below) until the
operator re-runs discovery.

The profile is the canonical source of stack truth. To change the
stack (add a manifest, swap a test runner), edit the profile and
commit; the next dispatch picks it up automatically.

## Harness vs target — the load-bearing distinction

This repo holds **no application code**. It's pure orchestration. The
harness `bin/` scripts run on the host; they spawn `claude -p` agents
that operate on a separate target repo.

```
┌─ Host machine (your Mac) ──────────────────────────────────┐
│                                                            │
│  ┌─ $HARNESS_ROOT (this repo) ─────────────┐               │
│  │                                          │               │
│  │  bin/run-local.sh                        │               │
│  │  bin/poll.sh                             │               │
│  │  bin/run-stage.sh                        │               │
│  │  bin/dispatch.sh                         │               │
│  │  bin/scope-check.sh                      │               │
│  │  AGENT_PROMPTS.md                        │               │
│  │  learned-rules/                          │               │
│  │                                          │               │
│  └──────────────────────────────────────────┘               │
│                  │                                          │
│                  │  fork claude -p --allowed-tools          │
│                  │  with CWD = per-issue worktree           │
│                  ↓                                          │
│  ┌─ $TARGET_REPO (your project) ────────────────────┐      │
│  │                                                   │      │
│  │  src/                                             │      │
│  │  tests/                                           │      │
│  │  Cargo.toml / package.json / pyproject.toml / ... │      │
│  │  .pipeline-config/                                │      │
│  │     ├─ config.json                                │      │
│  │     ├─ state.local.json                           │      │
│  │     └─ schemas/linear-ids.json                    │      │
│  │                                                   │      │
│  │  $PROJECT_STATE_DIR/ENG-N/worktree/  (per-issue)  │      │
│  │                                                   │      │
│  └───────────────────────────────────────────────────┘      │
│                                                            │
└────────────────────────────────────────────────────────────┘
```

The orchestrator never writes target-repo source code directly. It
only:
1. Creates / locates a per-issue worktree on the target.
2. Renders a per-stage prompt and dispatches `claude -p` with the
   worktree as CWD.
3. Reads what the agent did (commits, files, transcript).
4. Runs scope/verdict/classify gates on the result.
5. Posts pipeline markers to Linear.
6. Swaps the `stage:*` label and tries the next stage on the next tick.

This separation has two properties worth knowing:

- **The orchestrator NEVER dispatches an agent into the operator's
  `$TARGET_REPO` checkout** — every dispatch resolves a per-issue
  worktree first (ENG-67, May 2026). If
  `bin/run-local.sh` ever logs `FATAL: internal: worktree_path empty
  after reconcile=proceed (ENG-67); refusing to dispatch from
  $TARGET_REPO`, that's the D-003 invariant `die`-ing.
- **No cross-target state leakage**: each target has its own
  `$PROJECT_STATE_DIR`, its own `.pipeline-config/`, its own pair of
  launchd jobs. The only shared thing is the global Claude mutex.

## Dispatch lifecycle (one tick)

```
launchd fires (every 5 min)
  └─ bin/run-local.sh
      ├─ acquire $PROJECT_STATE_DIR/.run-local.lock/      [single-flight per project]
      ├─ source common.sh, resolve roots
      ├─ check orchestrator.paused → exit if true
      ├─ check global breaker (.consecutive-failures ≥ 3) → exit if tripped
      ├─ release-watcher: poll for new GitHub release, invoke on-new-release.sh
      │
      ├─ bin/poll.sh
      │   ├─ list Linear issues for project
      │   ├─ classify each (slot, advanceable, operator_action_required)
      │   ├─ pick (issue, stage) — first hold/advanceable wins
      │   └─ emit halt-sprawl alert if vacate count exceeds threshold
      │
      ├─ bin/reconcile.sh                                  [brainstorm/plan only]
      │   └─ existing-doc gate: scan docs/{brainstorms,plans} for `linear: ENG-N`
      │      ├─ doc found, accept-as-canonical: skip dispatch, transition
      │      └─ doc absent or fuzzy: proceed
      │
      ├─ bin/run-stage.sh ENG-N <stage>
      │   ├─ resolve worktree (create if absent)
      │   ├─ pre-dispatch merge gate (rebase/merge if branch is behind)
      │   ├─ entry-conditions gate (ENG-86)               [building only, default]
      │   │   └─ skip:<reason> | proceed | error:<check>
      │   ├─ bin/render-prompt.sh
      │   │   ├─ extract fenced ``` block from AGENT_PROMPTS.md by stage section
      │   │   └─ append learned-rules/<stage>.md
      │   ├─ bin/dispatch.sh
      │   │   ├─ acquire global Claude mutex
      │   │   ├─ gtimeout <stage-cap> claude -p --allowed-tools <list>
      │   │   ├─ stream-json renderer: prose to log, raw to capture, usage-<stage>.json on result
      │   │   └─ release Claude mutex
      │   ├─ bin/scope-check.sh                            [post-agent]
      │   │   └─ partition dirty paths: in-scope / leaked-in-scope / out-of-scope
      │   ├─ bin/verdict-handler.sh
      │   │   └─ parse pipeline marker comments emitted by the agent
      │   ├─ classify-failure.sh on non-success path
      │   │   └─ write issue-state.json + post halt comment
      │   └─ on success: transition stage label, post completion marker
      │
      └─ release lock, emit metric events
```

## Slot-occupancy contract (ENG-90)

`bin/poll.sh::_poll_classify_labels` is the slot-classification
surface. Every output declares one of:

| `slot` | `advanceable` | `operator_action_required` | Meaning |
|---|---|---|---|
| `terminal` | — | — | `pipeline:abandoned`. Never recalled. |
| `hold` | `true` | — | Active development. Pass 4 dispatches an agent this tick. |
| `vacate` | — | `true` | Agent-idle, recall requires operator action (label removal, decide --action continue, PR review). Counted by halt-sprawl alert. |
| `vacate` | — | `false` | Agent-idle, recall is automatic (next-tick orchestrator-side state check). Excluded from halt-sprawl. |

`slot:hold, advanceable:false` is **not** part of the contract. Adding
a new branch that wants to express "hold the slot but don't dispatch"
must reach for `vacate` (with the appropriate
`operator_action_required` flag) instead.

This contract is what allows the harness to bound work-in-progress (ENG-81
limits to K=2 concurrent issues) without losing track of operator-
attention-required vs orchestrator-recoverable states.

## Single human-approval gate (ENG-54)

The pipeline collects human approval **once**, at the build stage's P2
preflight, on the post-QA SHA. The review stage is agent-only — it
runs cold-pass reviewers, comments on the PR, and either advances to QA
or loops back to implement. It does **not** wait for human approval.

`bin/run-stage.sh::_fresh_wait_reason` allow-lists the wait shape for
`build` only. Any other stage emitting `verdict result=wait` is rejected
as a protocol violation.

## Sweep + scope partition (ENG-14)

After a clean stage run, `run-local.sh` does a tick-start vs tick-end
dirty-path diff and partitions changes into three streams via
`partition_dirty_paths`:

1. **In-scope** → committed and pushed by the bot.
2. **Leaked-in-scope** → soft fail, increments `.consecutive-failures`,
   may trip breaker.
3. **Out-of-scope** → bucketed:
   - if path was in the tick-start snapshot → **observed** (info only —
     concurrent human work).
   - if NEW since tick start → **self-leak** → hard fail, breaker, no
     commit at all.

Anything writing files outside the per-stage allowlist must update the
partition rules in `run-local-helpers.sh` or it will trip the breaker.

## Per-stage dispatch timeouts (ENG-65)

Each `claude -p` invocation is wrapped by `gtimeout`. Cap resolution:

1. `orchestrator.dispatch_timeout_minutes_per_stage[<stage>]` (highest)
2. `orchestrator.dispatch_timeout_minutes` (global)
3. Built-in default: 60 min for brainstorming/planning, 30 min for everything else

When SIGTERM fires before a `result` event lands, the renderer falls
back to summing per-message `assistant.message.usage.*` and writes a
partial `usage-<stage>.json` with `cost_usd: null` and `partial: true`.
The on-disk `partial: true` field is the discriminator the
retrospective uses to distinguish SIGTERM-captured runs from genuine
zero-cost dispatches.

## AGENT_PROMPTS.md structure

`AGENT_PROMPTS.md` contains nine numbered H2 sections — one per stage
agent — each with exactly one fenced ``` block.
`bin/render-prompt.sh` extracts the fenced block by section header and
dies if the fence count is not exactly 2.

**Do not** add column-0 ``` fences inside a stage's body, and do not
renumber sections without updating the `STAGE_TO_SECTION` table at the
top of `render-prompt.sh`.

`learned-rules/<stage>.md` files are appended to the base prompt at
dispatch time. They are written by the retrospective agent and gated by
human-approval labels (`pipeline:rule-reviewed`).

## Failure taxonomy <a id="failure-taxonomy"></a>

`failure_outcome_for_exit` in `common.sh` maps script exit codes to
named failure outcomes:

| Code | Outcome | Meaning |
|---|---|---|
| 0 | `success` | Stage passed |
| 20 | `agent-blocked` | Agent halted itself with a halt verdict |
| 21 | `scope-violation` | scope-check rejected dirty paths |
| 22 | `protocol-violation` | Agent emitted invalid marker / wrong wait shape |
| 23 | `dispatch-timeout` | gtimeout fired SIGTERM |
| 24 | `linear-post-failed` | Linear API write failed (counts toward global breaker) |
| 25 | `pr-opened-too-early` | Implement agent created a PR (forbidden by transcript-assertion) |
| 26 | `iteration-exhausted` | Brainstorm exceeded persona-review iteration cap |

Adding a new exit code without updating this switch routes it to
`unknown-exit-N` and the retrospective's §1 filter will not classify
it.

## Defense-in-depth: transcript-based assertions

Some stage contracts say "agent must not invoke tool X." For these, the
harness uses `bin/dispatch.sh::assert_no_tool_invocation` which scans
the agent's NDJSON transcript for `tool_use` blocks matching a forbidden
prefix.

Today only the implement stage uses this pattern (forbidding `gh pr
create`); generalising to other stages is a separate refactor.

This is preferred over state-of-the-world checks because state checks
false-positive on actions taken by other actors (humans, prior stages,
future agents); transcript checks answer the contract question
directly.

## Per-issue state directory

```
$PROJECT_STATE_DIR/ENG-N/
├── worktree/                  (git worktree for the feature branch)
├── issue-state.json           (retry memory + failure policy)
├── .consecutive-failures      (per-issue counter, sibling of global)
├── stage-summary-<stage>.md   (agent-authored stage summary, persists across ticks)
├── wait-<stage>.json          (wait-budget tracking, ENG-45 external_signal_budget)
└── usage-<stage>.json         (cost telemetry per dispatch)
```

`issue-state.json` is the durable state for the skip-label dance. The
poller reads it on every tick and includes/excludes the issue based on
`policy` plus a recomputed `pipeline_content_hash` (sha256 over
`bin/**`, `config.json`, `AGENT_PROMPTS.md`) and branch-head SHA.
Schema in [`operations.md#issue-statejson-schema`](operations.md#issue-statejson-schema).

## Cross-cutting: the Claude mutex

A directory-based mutex at `$HARNESS_STATE_DIR/.claude-mutex.lock/`
serializes every `claude -p` invocation, system-wide:

- Across stages of the same issue (impossible in practice — one tick
  runs one stage)
- Across issues of the same project (the per-tick lock makes this
  impossible too)
- Across **projects** (this is the load-bearing case — two projects'
  ticks won't fire `claude -p` simultaneously)
- Across the orchestrator and the retrospective

Holds for `CLAUDE_MUTEX_TIMEOUT` seconds (default 600) before dying.
PID is recorded in `$HARNESS_STATE_DIR/.claude-mutex.lock/pid` for
debugging.

## Retrospective lifecycle

```
launchd fires (Mondays 09:00, $HARNESS_STATE_DIR/<slug>)
  └─ bin/run-retrospective-local.sh
      ├─ acquire $PROJECT_STATE_DIR/.run-local.lock/  [shared with orchestrator]
      ├─ ensure-on-main: checkout main, pull
      ├─ create branch: chore/<slug>-retro-YYYY-MM-DD
      ├─ dispatch retrospective agent
      │   ├─ reads $PROJECT_STATE_DIR/metrics/events.jsonl (full history)
      │   ├─ reads per-stage transcripts under $PROJECT_STATE_DIR/<slug>/logs/
      │   ├─ analyzes failure patterns, scope drifts, timeout hits
      │   └─ proposes edits to learned-rules/<stage>.md
      ├─ commit + push branch
      ├─ open PR with diff summary
      └─ release lock
```

The PR is labeled `pipeline:rule-reviewed` only after you review and
merge. Until then, the next dispatch still uses the unchanged rule file.

## Slug-derived isolation

Per-project slug isolation is the multi-project foundation:

| Resource | Per-project shape |
|---|---|
| State directory | `$HARNESS_STATE_DIR/<slug>/` |
| launchd job labels | `com.twinning.pipeline.<slug>`, `com.twinning.retrospective.<slug>` |
| target-repo sentinel | `$PROJECT_STATE_DIR/target-repo` (collision check) |

Shared resources (cross-project):

| Resource | Location |
|---|---|
| Claude mutex | `$HARNESS_STATE_DIR/.claude-mutex.lock/` |
| Secrets | `$HARNESS_CONFIG_DIR/secrets.env` |
| GitHub App private key | `$HARNESS_CONFIG_DIR/github-app.pem` |

There is no cross-project orchestration logic — each project's
launchd tick is independent. They contend only on the Claude mutex.
