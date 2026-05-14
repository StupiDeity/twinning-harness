# twinning-harness

> An autonomous SDLC harness that drives a Linear-tracked project end to end —
> brainstorm → plan → implement → UI → review → QA → build → release — by
> dispatching headless `claude -p` agents at a target repo on a 5-minute tick.

`twinning-harness` is a collection of bash scripts plus two `launchd` agents.
The scripts hold no application code of their own. They sit between **Linear**
(your source of truth for what to build) and **GitHub** (where the code lives),
and orchestrate Claude Code agents that operate on a separate **target repo**.
The orchestrator handles the per-tick pipeline; a peer **retrospective agent**
runs weekly and proposes updates to the harness's own learned-rule files.

> **Status: alpha.** I run this against my own projects. It is pre-1.0,
> single-operator, macOS-only, and burns a non-trivial amount of Claude
> subscription compute. Treat the failure modes documented here as
> things-that-have-actually-happened-to-me, not theoretical edges.

## Is this for you

**Best for:**
- Solo developers (or very small teams with one designated operator)
- Projects already tracked in **Linear**, hosted on **GitHub**
- macOS Mac Studio / Mac mini / MacBook left running 24×7
- Workloads where you're willing to budget meaningful Claude subscription
  spend in exchange for autonomous progress on tickets you've specced clearly
- Authors who enjoy reading agent transcripts as much as writing code

**Not for:**
- Team-shared CI / multi-operator setups (a global mutex serializes dispatch)
- Non-Linear / non-GitHub workflows
- Linux or Windows hosts (macOS / `launchd` only — no portability layer)
- Projects where you can't comfortably write detailed Linear specs upfront —
  garbage in, garbage out, very expensively
- "Set it and forget it" expectations — you remain the operator-in-the-loop
  for halts, scope-approvals, and review

The harness is stack-agnostic. The first-time setup (`bash bin/setup.sh
/path`) discovers your target's stack and writes a per-target profile
that the orchestrator reads at dispatch time. The agents then run
whatever build/test commands your target already uses.
→ See [docs/architecture.md "Discovery and the project profile"](docs/architecture.md#discovery-and-the-project-profile)
for the full lifecycle.

## How it works

```
Linear (source of truth)            Local runtime (your Mac)
────────────────────────            ───────────────────────────────
 Issue status, labels   ─┐         ┌─  launchd: com.twinning.pipeline.<slug>
 Comments               ─┼─Linear──┤   (StartInterval=300 — every 5 min)
                         │  API    │      ↓
                         │         │     bin/run-local.sh           [tick]
                         │         │      ↓
                         │         │     bin/poll.sh                [decide next (issue, stage)]
                         │         │      ↓
                         │         │     bin/run-stage.sh           [render prompt + dispatch]
                         │         │      ↓
                         │         │     claude -p --allowed-tools  [headless agent in worktree]
                         │         │      ↓
                         │         │     scope-check / verdict / classify-failure
                         │         │
                         │         └─  launchd: com.twinning.retrospective.<slug>
                         │             (StartCalendarInterval — Mondays 09:00)
                         │              ↓
                         └─Linear─────  bin/run-retrospective-local.sh
                                        [reads metrics, proposes rule updates, opens PR]
```

Two binaries, peer roles:

- **Orchestrator** (every 5 min): picks one ready (issue, stage), opens a
  per-issue git worktree on the target repo, dispatches a Claude agent with
  the per-stage prompt + allowed-tools, runs scope/verdict gates on what the
  agent did, swaps the `stage:*` label, posts pipeline markers.
- **Retrospective** (Mondays 09:00): one-shot agent that reads the week's
  metrics + transcripts, proposes edits to `learned-rules/*.md` (which are
  appended to base prompts at dispatch time), and opens a PR you review.

The orchestrator never writes target-repo code directly — it only dispatches
agents and reads what they produced. The harness/target separation is
load-bearing: this repo holds *no* application code; it's pure orchestration.

→ See [`docs/architecture.md`](docs/architecture.md) for runtime topology,
dispatch lifecycle, the slot-occupancy contract, and the worktree dispatch
invariant.

## Demo

The harness drives its own tickets, end to end. The two transcripts
below are unedited Linear threads — one showing the system catching a
real false-positive on its own fix branch, the other showing the
boring, predictable shape of a clean run.

### ENG-59 — scope-check halts itself, operator unsticks it in one command

The bug: `bin/scope-check.sh` was diffing the agent's branch against
the operator's *local* `main`, which only advances when the operator
runs `git pull`. When upstream merges land between pulls, scope-check
mis-attributes those upstream commits' files to the agent's diff and
false-halts the issue.

The implement agent finished cleanly and posted its verdict:

```html
<!-- pipeline: verdict result=pass stage=implementing -->
```

The orchestrator's post-stage scope-check then halted the issue:

> ```html
> <!-- pipeline: verdict result=halt reason=agent-blocked -->
>
> Pipeline: `implementing` stage halted — SEVERE scope violation on
> feat/eng-59-…: - `docs/runbooks/recovery.md`
>
> **Policy:** skip-until-human-acts
> ```

The agent's branch did **not** touch `docs/runbooks/recovery.md` —
that file was modified by an upstream merge that landed between the
operator's last `git pull` and this dispatch. **The very bug being
fixed caused the halt**: the pre-fix scope-check ran against the host's
stale local `main` and attributed an unrelated upstream commit's edit
to this branch.

One operator command:

```bash
bash bin/pipeline.sh decide ENG-59 --action continue
```

posts an operator-resume waypoint and a `decision` marker:

> ```html
> <!-- pipeline: transition from=implementing to=implementing reason=operator-resume -->
> <!-- pipeline: decision action=continue -->
> ```

Next tick the agent re-dispatched, re-asserted its work, and the
pipeline rolled forward to release in ~40 minutes:

| Time (UTC) | Author | Marker |
|---|---|---|
| 17:40 | agent | `verdict result=pass stage=brainstorming` |
| 17:40 | orch | `transition from=brainstorming to=planning` |
| 17:57 | agent | `verdict result=pass stage=planning` |
| 17:57 | orch | `transition from=planning to=implementing` |
| 18:13 | agent | `verdict result=pass stage=implementing` (1st attempt) |
| 18:13 | orch | **`verdict result=halt reason=agent-blocked`** (false positive) |
| 18:55 | operator | `transition reason=operator-resume` + `decision action=continue` |
| 19:00 | agent | `verdict result=pass stage=implementing` (2nd attempt — clean) |
| 19:01 → 19:22 | … | `ui → reviewing → qa` (each stage: pass + transition) |
| 19:24 | agent | `verdict result=wait reason=awaiting-approval` (build P2) |
| 19:29 | agent | `verdict result=wait reason=awaiting-approval` (next tick) |
| 19:37 | agent | `verdict result=pass stage=building` (post-approval merge) |
| 19:37 | orch | `transition from=building to=released` |

The implement agent's TDD evidence comment narrated the dogfooding
explicitly:

> Notably, `docs/runbooks/recovery.md` is **not** in the diff (despite
> the prior dispatch's halt comment citing it); that flag was the
> dogfooding manifestation of the very bug ENG-59 fixes — the
> orchestrator-side `scope-check.sh` was running the pre-fix diff
> against the host's stale local `main` and attributing upstream
> `recovery.md` commits to this branch.

And the build agent that merged the PR flagged a *separate* gotcha along
the way — the empirical observation that drove ENG-83 the next day:

> Required `--repo StupiDeity/twinning-harness` to bypass harness-self
> local-worktree cleanup error.

Full annotated transcript: [`docs/demos/eng-59-thread.md`](docs/demos/eng-59-thread.md)
(33 comments, 22 pipeline-state markers).

### ENG-83 — what a clean run looks like

ENG-83 codified the `--repo` workaround that ENG-59's build agent
flagged. No halts, no operator intervention, no retries. The only
non-pass markers are the two `verdict result=wait reason=awaiting-approval`
entries that are **expected** under the single-human-approval gate at
build P2.

| Time (UTC) | Author | Marker |
|---|---|---|
| 06:27 → 07:51 | agent + orch | `brainstorming → planning → implementing → ui → reviewing → qa` (each: pass + transition) |
| 07:58 | agent | `verdict result=wait reason=awaiting-approval` |
| 13:15 | agent | `verdict result=pass stage=building` (post-approval) |
| 13:16 | orch | `transition from=building to=released` |

Self-referential close-out from the build agent that merged the PR:

> The `--repo StupiDeity/twinning-harness` argument is the very fix this
> PR ships.

Full annotated transcript: [`docs/demos/eng-83-thread.md`](docs/demos/eng-83-thread.md)
(26 comments, 15 pipeline-state markers).

## Install

### Prerequisites

| Requirement | Why |
|---|---|
| macOS (any recent) | `launchd` is the runtime; no Linux/Windows port. |
| `claude` CLI, logged in to a Claude subscription | All agent dispatch goes through `claude -p` against the subscription session. **`ANTHROPIC_API_KEY` must NOT be set** — the harness deliberately uses subscription compute. |
| `gh` CLI, authenticated | Used by build/release agents and by the operator. |
| `jq`, `gtimeout` (`brew install coreutils`) | Required by every script; `gtimeout` enforces per-stage dispatch caps. |
| Linear workspace + personal API key | Source of truth; harness reads/writes via GraphQL. |
| GitHub repo with bot user | The harness commits and opens PRs under a separate GitHub identity. |
| Disk: ~5 GB headroom | Per-issue worktrees, transcripts, and logs accumulate. |

### Quickstart

```bash
# 1. Clone the harness somewhere stable.
git clone https://github.com/<you>/twinning-harness ~/code/twinning-harness
cd ~/code/twinning-harness

# 2. Run setup against your target repo. Walks 11 idempotent phases:
#    workspace, linear-auth, linear-identity, linear-schema, slug-freeze,
#    project-profile, github-app, gh-cli, slack (optional), config-defaults,
#    validate, launchd. Re-run any time; satisfied phases skip.
bash bin/setup.sh /path/to/your-target-repo

# 3. (Optional) Install the pre-commit hook that runs the bin/*-test.sh suite.
bash bin/install-git-hooks.sh

# 4. Watch the next tick fire.
launchctl list | grep com.twinning.pipeline
tail -f "${XDG_STATE_HOME:-$HOME/.local/state}/twinning-harness/<slug>/logs/local-$(date -u +%Y-%m-%d).log"
```

Re-run a single phase (e.g. after rotating credentials):

```bash
bash bin/setup.sh /path/to/target linear-auth
bash bin/setup.sh /path/to/target validate
```

### Multi-project layout

A single harness checkout drives N target repos. Each gets a unique project
slug (frozen at first setup) and its own per-project state dir at
`$HARNESS_STATE_DIR/<slug>/` plus its own pair of `launchd` agents
(`com.twinning.pipeline.<slug>` and `com.twinning.retrospective.<slug>`).

Shared secrets live once at
`${XDG_CONFIG_HOME:-~/.config}/twinning-harness/secrets.env`; per-project
`.env.local` carries only what genuinely varies per target.

Migrate an existing single-project install:

```bash
bash bin/setup.sh /path/to/target migrate
```

→ See [`docs/install.md`](docs/install.md) for: detailed Linear setup
(states, labels, project), GitHub bot user + GitHub App private key + code
owners, target repo `.pipeline-config/` (config.json, allowed-tools regen,
per-stage timeouts, entry-conditions), and the full `launchd` plist
substitutions.

## Uninstall

```bash
bash bin/uninstall-launchd.sh /path/to/target
```

This bootstraps both `launchd` agents out and removes the per-slug plists
from `~/Library/LaunchAgents/`. The harness checkout, target repo, and per-
project state directory are left intact — remove them by hand if you want a
clean uninstall:

```bash
rm -rf "${XDG_STATE_HOME:-$HOME/.local/state}/twinning-harness/<slug>"
rm -rf /path/to/target/.pipeline-config
# Shared config (only if uninstalling the LAST target):
rm -rf "${XDG_CONFIG_HOME:-$HOME/.config}/twinning-harness"
```

## Day-to-day operation

The orchestrator runs autonomously. Most days you do nothing except watch
Linear; occasionally you'll need to:

| Workflow | What you do |
|---|---|
| File a feature/bug | New Linear issue with status `Todo` and exactly one of `Bug` / `Feature` / `Improvement` labels. The poller picks it up next tick. Use `LINEAR_ISSUE_TEMPLATE.md` to write the body — quality of brainstorm output is bounded by quality of the spec. |
| Inspect status | `bash bin/status.sh` — read-only dashboard combining Linear + `gh` + metrics. |
| Resolve a halt | `bash bin/pipeline.sh decide ENG-N --action continue` — atomic resume. Clears halt label, skip labels, per-issue counter, posts an operator-resume waypoint. |
| Approve a scope violation | `bash bin/pipeline.sh decide ENG-N --action approve --gate scope` |
| Approve a build | The build agent waits for a non-bot `Approved` review on its PR. You review the PR like any other. |
| Pause one issue | Apply the `pipeline:halted` label in Linear. |
| Pause everything | Set `orchestrator.paused: true` in `$TARGET_CONFIG_DIR/state.local.json`. Takes effect next tick. |
| Run a stage manually | `TARGET_REPO=… bash bin/run-stage.sh ENG-N <stage>` — bypasses the poller. |
| Dry-run anything | Prefix with `PIPELINE_DRY_RUN=1` — suppresses Linear writes, the `claude` call, and Slack. |

→ See [`docs/operations.md`](docs/operations.md) for: reading Linear comment
markers, interpreting metrics, recovering from each failure class, and
reading per-stage transcripts.

## Commands

A cheatsheet of every operator-facing entrypoint. All commands assume
`TARGET_REPO=/path/to/target` is exported (or you pass the path as the first
positional argument where supported).

| Category | Command | Purpose |
|---|---|---|
| Setup | `bash bin/setup.sh <target> [phase]` | Onboard / reconfigure a target repo. Idempotent. With no phase: runs all unsatisfied phases in order. With a phase: runs that one only. |
| Setup | `bash bin/setup.sh <target> migrate` | Upgrade an existing single-project install to the multi-project layout. |
| Setup | `bash bin/install-launchd.sh <target>` | (Re)install the per-slug `launchd` plists only. |
| Setup | `bash bin/install-git-hooks.sh` | Install the pre-commit hook that runs the `bin/*-test.sh` suite. |
| Day-to-day | `bash bin/run-local.sh` | One manual orchestrator tick (same path `launchd` takes every 5 min). |
| Day-to-day | `bash bin/run-stage.sh ENG-N <stage>` | Run one specific stage against one issue, bypassing the poller. |
| Day-to-day | `bash bin/run-retrospective-local.sh` | One-shot retrospective run (same path the Monday 09:00 plist takes). |
| Day-to-day | `bash bin/status.sh` | Read-only dashboard (Linear + `gh` + metrics jsonl). |
| Day-to-day | `PIPELINE_DRY_RUN=1 …` | Modifier that prefixes any of the above. Suppresses Linear writes, `claude` invocation, Slack. |
| Halt resolution | `bash bin/pipeline.sh decide ENG-N --action continue` | Atomic halt resume. |
| Halt resolution | `bash bin/pipeline.sh decide ENG-N --action approve --gate <scope\|build-cap>` | Approve a specific gate. |
| Halt resolution | `bash bin/pipeline.sh decide ENG-N --action abandon` | Mark issue terminal. |
| Pipeline events | `bash bin/pipeline.sh event ENG-N verdict <pass\|fail\|halt\|wait\|pivot> [--stage X --target Y --reason Z]` | Emit a registry-validated marker by hand. |
| Pipeline events | `bash bin/pipeline.sh status ENG-N` | Read-only event log for one issue. |
| Linear | `bash bin/linear.sh refresh-cache` | Regenerate `$TARGET_CONFIG_DIR/schemas/linear-ids.json` after adding states/labels in Linear. |
| Linear | `bash bin/linear.sh add-label ENG-N <label>` | Additive label mutation (use this; never the MCP `save_issue` — it overwrites). |
| Linear | `bash bin/linear.sh remove-label ENG-N <label>` | Additive label removal. |
| Uninstall | `bash bin/uninstall-launchd.sh <target>` | Bootout + remove the per-slug plists. |

## Configuration

Two locations:

- **Shared config** at `${XDG_CONFIG_HOME:-~/.config}/twinning-harness/`:
  `secrets.env` (Linear API key, GitHub App credentials, optional Slack
  webhook) and the GitHub App private key file.
- **Per-target config** at `$TARGET_REPO/.pipeline-config/`: `config.json`
  (orchestrator behavior, per-stage timeouts, allowed-tools extras,
  entry-conditions), `schemas/linear-ids.json` (cached state/label IDs),
  `.env.local` (per-target overrides like `GH_APP_INSTALLATION_ID`).
  `.pipeline-config/` is gitignored — each operator applies it on their
  copy.

Most operators only edit `config.json` for: per-stage dispatch timeouts (if
the default 30 min cap fires SIGTERM during legitimate persona-review work),
the dispatch.tools allowlist (operator-curated extras on top of the profile-derived list), or
entry-conditions (cost-recovery on build).

→ See [`docs/configuration.md`](docs/configuration.md) for the full
`config.json` schema, the wildcard pitfall, the allowlist regen one-liner,
validation rules, and worked examples.

## Artifacts and locations

```
$HARNESS_ROOT/                       (this repo — scripts, prompts, learned rules)
$TARGET_REPO/                        (your project, mutated by agents)
  └─ .pipeline-config/               (gitignored; config.json + linear-ids cache + .env.local)

$HARNESS_CONFIG_DIR/                 ($XDG_CONFIG_HOME/twinning-harness)
  ├─ secrets.env                     (LINEAR_API_KEY, GH_APP_*, …)
  └─ <gh-app>.pem                    (GitHub App private key)

$HARNESS_STATE_DIR/                  ($XDG_STATE_HOME/twinning-harness)
  ├─ .claude-mutex.lock/             (global single-flight around dispatch)
  └─ <slug>/                         (= $PROJECT_STATE_DIR — per-project)
      ├─ .consecutive-failures       (global breaker counter)
      ├─ .run-local.lock/            (per-tick lock)
      ├─ logs/                       (local-YYYY-MM-DD.log + per-stage transcripts)
      ├─ metrics/events.jsonl        (telemetry — what the retrospective reads)
      └─ ENG-N/                      (per-issue state)
          ├─ worktree/               (git worktree for the feature branch)
          ├─ issue-state.json        (retry memory; failure policy)
          ├─ .consecutive-failures   (per-issue counter, sibling of global)
          └─ stage-summary-*.md
```

→ See [`docs/operations.md#artifact-locations`](docs/operations.md#artifact-locations)
for the `issue-state.json` schema, log file conventions, and the metrics
jsonl format.

## Vocabulary

The pipeline state machine is driven by HTML comment markers in Linear
issues. There are two families:

- **`<!-- pipeline: <event> ... -->`** — drives state. Read by the orchestrator.
- **`<!-- meta: <kind> ... -->`** — bookkeeping (dedup, evidence, metric counters).

The closed registries (verdict results, halt reasons, wait reasons, fail
targets, decision actions, gates, meta kinds, stage names) are generated
from `bin/pipeline-events.json`.

→ See [`docs/pipeline-vocabulary.md`](docs/pipeline-vocabulary.md) for the
full registry, marker anatomy, who-writes-what matrix, and worked examples
of both happy-path and halt-and-resume flows.

## Assumptions

The harness is built on a small set of load-bearing assumptions. Violating
any of these silently breaks things in confusing ways:

- **Linear**: Issues enter the pipeline at status `Todo` with no `stage:*`
  label. Each carries exactly one of `Bug` / `Feature` / `Improvement` — this
  drives branch shape (`fix/eng-N-slug` vs `feat/eng-N-slug`). Labels are
  mutated additively only — never via the Linear MCP `save_issue` (it
  overwrites the entire label set).
- **GitHub**: The bot user has push access; PRs are opened against `main`.
  Code Owners drive the build-stage approval gate.
- **Doc ownership**: `docs/brainstorms/*.md` and `docs/plans/*.md` use YAML
  frontmatter (`linear: ENG-N`) to bind documents to issues. The reconcile
  pass relies on this.
- **Platform**: macOS, `launchd`, single operator. Cross-tick concurrency is
  serialized via a global mutex; cross-machine concurrency is not supported.
- **Auth**: Claude subscription session on the host — `ANTHROPIC_API_KEY` is
  intentionally never set.
- **Stack**: Per-stage allowed-tools is composed of **stack-neutral
  base + profile-derived stack tools + operator-curated extras**.
  The profile (`learned-rules/<slug>/project-profile.md::## Tool
  allowlist`) is authored by the discovery agent during setup; the
  extras (`.pipeline-config/config.json::dispatch.tools`) are
  operator-curated. Adding a new target runs discovery (Phase 5b)
  to populate the profile.

→ See [`docs/assumptions.md`](docs/assumptions.md) for the full list with
the failure mode each assumption defends against.

## Failure modes and runbooks

Most failures recover with one command:

```bash
bash bin/pipeline.sh decide ENG-N --action continue
```

This is atomic and idempotent — clears halt labels, skip labels,
wait files, the per-issue counter, the global breaker, and posts an
operator-resume waypoint, all in one operation. Re-run safely.

The most common symptoms:

| Symptom | First place to look |
|---|---|
| Tick is silent | `$PROJECT_STATE_DIR/logs/local-YYYY-MM-DD.log`, then per-stage transcript. |
| Per-issue halt | `pipeline:halted` label, halt comment under sig `halt/<stage>/<issue>`. |
| Global breaker tripped | `$PROJECT_STATE_DIR/.consecutive-failures ≥ 3`; `orchestrator.paused=true`. |
| Issue stuck in `stage:X` | `wait-*.json` files in the per-issue dir; or a forgotten scope-approval. |
| Wrong-target Linear writes | Stale `linear-ids.json` cache. |
| Build idles with `dispatch-skipped` events | ENG-86 entry-conditions skip — usually missing Code Owner approval. |
| Brainstorm halts at `iteration-exhausted` | ENG-65 voluntary halt after 2 persona-review iterations. |

→ See [`docs/runbooks/failure-modes.md`](docs/runbooks/failure-modes.md)
for the full catalog: per-symptom diagnosis steps, recovery procedures,
root causes, and related ENG tickets. Companions:
[`operator-mental-model.md`](docs/runbooks/operator-mental-model.md)
(silently load-bearing assumptions) and
[`recovery.md`](docs/runbooks/recovery.md) (ENG-41 trust-model
recovery).

## Cost expectations

> **Honest disclosure**: I'm running this against a Claude Opus
> subscription, not a metered API key. Numbers below are approximate
> and based on my own usage during 2026-Q2. They will drift as model
> pricing changes.

Order-of-magnitude per-issue cost (subscription-equivalent — what
you'd pay on the API for the same compute):

| Issue shape | Typical cost |
|---|---|
| Small (1-day developer-equivalent) | **$5–$15** |
| Complex feature with one halt-and-resume cycle | **$20–$60** |
| Retrospective (weekly) | **$2–$5** |

The biggest cost lever is not config — it's writing better Linear
specs. Vague specs produce expensive brainstorm iterations and
re-dispatches. A 10-minute spec edit can save $10+ per issue.

→ See [`docs/cost.md`](docs/cost.md) for: per-stage p50/p90 ranges,
worked-example trajectories (small ticket vs complex feature), monthly
budget projections, the full cost-telemetry schema in `usage-<stage>.json`,
optimization strategies (timeout caps, entry-conditions, scope tightening),
and subscription-vs-API tradeoffs.

## Security and threat model

**Trust boundary**: the host Mac is fully trusted. The harness is
explicitly designed for **solo developers running on trusted hardware
against their own projects**. There is no privilege separation
between the harness and the operator shell — anyone with shell access
to the host can read every secret.

**What the bot has access to:**
- Linear GraphQL (full workspace via the personal API key)
- GitHub (repo write via the bot user + a GitHub App for PR auto-merge)
- The Claude subscription session
- Your local filesystem under `$TARGET_REPO`, `$HARNESS_STATE_DIR`,
  `$HARNESS_CONFIG_DIR`

**Highest-impact gaps in the current threat model**:
1. **No supply-chain isolation** — agent dispatches run your target's
   package-manager commands (e.g. `cargo build`, `bun install`,
   `pip install`, `go build`) against the target repo with full
   filesystem access. Malicious post-install scripts execute in your
   shell context.
2. **No prompt-injection filtering on Linear issue bodies** — if you
   accept issues from untrusted authors, malicious specs can manipulate
   the agent.
3. **No cost rate limit** — a halt-resume loop can burn meaningful
   subscription compute before per-issue counters trip.

**If you're running in any threat model harder than "solo developer on
trusted hardware against own projects," this is not the right tool yet.**

→ See [`docs/security.md`](docs/security.md) for the full threat model:
attack surfaces (A1–A7) with reality / mitigations / recommendations,
secrets layout, hardening recommendations for post-alpha, and an
incident-response checklist.

## Contributing

Issues and PRs welcome. The harness is small enough (~10k LOC of bash) to
read end-to-end in an afternoon.

- Run the test suite before pushing: `find bin -name '*-test.sh' -exec bash {} \;`
  (or just rely on the pre-commit hook from `bin/install-git-hooks.sh`).
- Bash scripts that should be unit-testable end with the
  `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi` sentinel so
  tests can `source` them without firing `main`.
- Linear writes go through `bin/linear.sh`; metric writes go through
  `bin/metrics.sh`; pipeline markers go through `bin/pipeline.sh`. Roll
  nothing custom.

→ See [`CLAUDE.md`](CLAUDE.md) for the full contributor guide (it's
addressed to Claude Code agents working on this repo, but humans benefit
from the same conventions).

## License

GPL-3.0 — see [`LICENSE`](LICENSE).
