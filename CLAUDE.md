# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

This is the **harness** — a collection of bash orchestration scripts that drives an SDLC
pipeline (`brainstorm → plan → implement → ui → review → qa → build → release`) against a
**separate target repo**. The harness itself contains no application code; it dispatches
headless `claude -p` agents that operate on the target's worktree.

A second binary, the **retrospective agent**, runs weekly and edits the rule files in
`learned-rules/`; those rules are appended to the base prompt at dispatch time.

## Three locations every script touches

`bin/common.sh` is sourced by every other script and resolves three roots from env vars
(refactored in ENG-23 — predecessor names like `REPO_ROOT` / `PIPELINE_ROOT` are gone):

| Variable | Default | Holds |
|---|---|---|
| `HARNESS_ROOT` | derived from `bin/common.sh` location | this repo (scripts + `AGENT_PROMPTS.md` + `learned-rules/`) |
| `TARGET_REPO` | **required, no default** | the target repo whose worktrees, branches, PRs are mutated |
| `HARNESS_STATE_DIR` | `${XDG_STATE_HOME:-~/.local/state}/twinning-harness` | per-issue dirs (`ENG-N/worktree/`, `issue-state.json`), tick lock, fail counter, logs, metrics |
| `HARNESS_CONFIG_DIR` | `${XDG_CONFIG_HOME:-~/.config}/twinning-harness` | shared secrets (`secrets.env`) and the GitHub App private key |
| `PROJECT_SLUG` | derived from `config.json::project.slug` | per-project namespace key (frozen at first setup) |
| `PROJECT_STATE_DIR` | `$HARNESS_STATE_DIR/$PROJECT_SLUG` | per-project state (issue dirs, breaker, lock, logs, metrics) |

Derived (do not override):
- `TARGET_CONFIG_DIR = $TARGET_REPO/.pipeline-config` — holds `config.json`, `schemas/linear-ids.json`, `.env.local`
- `STATE_FILE = $TARGET_CONFIG_DIR/state.local.json` — runtime override for `orchestrator.paused`; writes go here, not to `config.json`

Any script run by hand needs `TARGET_REPO` exported. The launchd plist templates inject
all three under `EnvironmentVariables` after `install-launchd.sh` substitutes the `__VAR__`
placeholders.

## Runtime topology

```
launchd (com.twinning.pipeline, every 5 min)
  └─ run-local.sh                    (tick: lock, env, breaker, release watcher)
      ├─ poll.sh                     (decide next (issue, stage) from Linear)
      ├─ reconcile.sh                (only for brainstorm/plan: existing-doc gate)
      └─ run-stage.sh                (per-stage executor — invoked from worktree)
          ├─ render-prompt.sh        (extract fenced block from AGENT_PROMPTS.md)
          ├─ dispatch.sh             (invoke `claude -p --allowed-tools …`)
          ├─ scope-check.sh          (post-agent: dirty-path scope gate)
          ├─ verdict-handler.sh      (read HTML markers from Linear comments)
          └─ classify-failure.sh     (write issue-state.json + post halt comment)

launchd (com.twinning.retrospective, Mon 09:00)
  └─ run-retrospective-local.sh     (one-shot retrospective agent → opens PR)
```

The agent always runs `claude -p` with the **logged-in subscription session** on the host
Mac. `ANTHROPIC_API_KEY` is intentionally never set.

## Common commands

All commands need `TARGET_REPO` exported (point it at the target repo on disk).

```bash
# Manual one-shot tick (same path launchd takes every 5 min):
TARGET_REPO=/path/to/target bash bin/run-local.sh

# Run one specific stage against one issue, bypassing the poller:
TARGET_REPO=/path/to/target bash bin/run-stage.sh ENG-5 brainstorming

# Manual retrospective:
TARGET_REPO=/path/to/target bash bin/run-retrospective-local.sh

# Dashboard (read-only — Linear + gh + metrics jsonl):
TARGET_REPO=/path/to/target bash bin/status.sh

# Dry-run any of the above (no Linear writes, no `claude` call, no Slack):
PIPELINE_DRY_RUN=1 TARGET_REPO=/path/to/target bash bin/run-stage.sh ENG-5 brainstorming

# Resolve a halted issue (see docs/pipeline-vocabulary.md for decision tokens):
bash bin/pipeline.sh decide ENG-XX --action <continue|approve|abandon> [--gate <gate>]

# Post a verdict marker manually (registry-validated; lane-fenced):
bash bin/pipeline.sh event ENG-N verdict pass --stage <stage>
bash bin/pipeline.sh event ENG-N verdict fail --target <stage>
bash bin/pipeline.sh event ENG-N verdict halt --reason <reason-token>
bash bin/pipeline.sh event ENG-N verdict wait --reason <reason-token>     # build only

# Read-only event log for an issue:
bash bin/pipeline.sh status ENG-N

# Refresh the Linear ID cache after adding states/labels:
LINEAR_API_KEY=… TARGET_REPO=/path/to/target bash bin/linear.sh refresh-cache
# then commit $TARGET_REPO/.pipeline-config/schemas/linear-ids.json
```

Install / uninstall the launchd agents (rendered into `~/Library/LaunchAgents/` from the
templates in `launchd/`):

```bash
bash bin/setup.sh /path/to/target          # full onboarding (recommended)
bash bin/install-launchd.sh /path/to/target  # just (re)install plists
bash bin/uninstall-launchd.sh /path/to/target  # bootout & remove plists
```

## Tests

Tests are sibling shell scripts named `*-test.sh` in `bin/`. There is no test runner —
each file is a self-contained executable.

```bash
bash bin/classify-failure-test.sh
bash bin/reconcile-test.sh
bash bin/run-stage-test.sh
bash bin/scope-check-test.sh
bash bin/verdict-handler-test.sh
bash bin/halt-sprawl-test.sh             # + halt-sprawl-adversarial-test.sh
bash bin/run-local-sweep-test.sh         # + run-local-helpers-adversarial-test.sh
bash bin/poll-slot-test.sh
bash bin/verdict-adversarial-test.sh
```

### Pre-commit hook

The repo ships a pre-commit hook at `.githooks/pre-commit` that runs the
entire `bin/*-test.sh` suite (~30 s) and blocks the commit on any failure.
Install once per clone (sets `core.hooksPath`):

```bash
bash bin/install-git-hooks.sh
```

Bypass a single commit with `git commit --no-verify`. A short
`KNOWN_BROKEN` allowlist inside the hook exempts a few pre-existing
failures from the gate (still run, surfaced as `SKIP`); fix those and
remove the entry rather than letting the list rot.

How tests work — important when adding new ones:

1. Each `bin/foo.sh` ends with the **sentinel**
   `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi`.
   That lets a test `source` the file to get its functions without firing `main`.
2. The test sets `PIPELINE_DRY_RUN=1` and `LINEAR_API_KEY=test-mock-key` before sourcing.
3. The test creates `STUB_DIR` with mock `linear.sh` / `slack.sh` / `metrics.sh` and
   **post-source overrides** the global `TARGET_REPO`, `SCRIPT_DIR`, or `_CFS_SCRIPT_DIR`
   to point at fixtures and stubs (top-level assignments in the sourced script are global,
   so this works).

When a new bash file is meant to be both executable and unit-testable, replicate the
sentinel pattern; otherwise tests cannot source it without side effects.

## AGENT_PROMPTS.md is load-bearing

`AGENT_PROMPTS.md` contains nine numbered H2 sections — one per stage agent — each with
exactly one fenced ``` block. `render-prompt.sh` extracts the fenced block by section
header and dies if the fence count is not exactly 2. **Do not** add column-0 ``` fences
inside a stage's body, and do not renumber sections without updating the
`STAGE_TO_SECTION` table at the top of `render-prompt.sh`.

`learned-rules/<stage>.md` files are appended to the base prompt at dispatch time. They
are written by the retrospective agent and gated by human-approval labels
(`pipeline:rule-reviewed`); only edit them by hand if you are deliberately seeding rules.

## Pipeline vocabulary

Single source of truth: `docs/pipeline-vocabulary.md` (generated from
`bin/pipeline-events.json` via `bin/generate-vocabulary-doc.sh`). All
state-driving comments use `<!-- pipeline: <event> ... -->`; bookkeeping
uses `<!-- meta: <kind> ... -->`. Use `bin/pipeline.sh` to emit markers;
the helper validates against the registry.

The pipeline-namespace labels the harness applies are `pipeline:halted` and
`pipeline:abandoned` (per design §7.5; ENG-60 T2.13 drains the legacy set —
`paused`, `scope-approval-needed`, `supersede`, `skip-until-code-changes`,
`skip-until-human-acts` — on every transition). `pipeline:rule-reviewed` is
the orthogonal retrospective approval gate. Every other `pipeline:*` label
seen in Linear is human-applied.

## Linear conventions the harness depends on

- **Mutate labels additively.** Use `bash bin/linear.sh add-label <ENG-N> <label>` and
  `remove-label`. Never reach for the Linear MCP `save_issue` from harness code or from
  scripts the harness invokes — that call overwrites the entire label set and will silently
  drop `stage:*` / `pipeline:*` labels that the orchestrator is mid-flight on.
- **Doc-to-issue ownership is YAML frontmatter, not prose.** `reconcile.sh` (lines ~68–77)
  greps the first 20 lines of `docs/brainstorms/*.md` and `docs/plans/*.md` for a literal
  `linear: ENG-N` line; that, plus a fallback H1 match, is what makes a doc the canonical
  artifact for an issue. Doc generators and any future docs-discovery code must emit this
  frontmatter or reconcile will treat the doc as fuzzy/non-canonical.
- **Brainstorm entry-state is `Todo`.** `poll.sh` only picks up issues whose Linear status
  is `Todo` AND which carry no `stage:*` label as fresh brainstorm candidates. Issues
  filed into `Backlog` (or any other state) are silently invisible to the poller until a
  human transitions them to Todo.

## Per-issue state directory

Per-issue scratch lives under `$PROJECT_STATE_DIR/ENG-N/`:

```
$HARNESS_STATE_DIR/
├── .claude-mutex.lock/         # global single-flight around dispatch.sh
└── <slug>/                     # per-project
    ├── target-repo             # collision sentinel
    ├── .consecutive-failures
    ├── .run-local.lock/
    ├── .tick-counter
    ├── last-observed-release
    ├── logs/local-YYYY-MM-DD.log + per-stage transcripts
    ├── metrics/events.jsonl
    └── ENG-N/
        ├── worktree/
        ├── issue-state.json
        └── stage-summary-<stage>.md
```

`issue-state.json` is the durable state for the skip-label dance — `poll.sh` reads it on
every tick and includes/excludes the issue based on `policy` plus a recomputed
`pipeline_content_hash` (sha256 over `bin/**`, `config.json`, `AGENT_PROMPTS.md`) and
branch-head SHA.

The harness orchestrator NEVER dispatches an agent into the operator's `$TARGET_REPO`
checkout — every dispatch resolves a per-issue worktree first (ENG-67, May 2026). If
`bin/run-local.sh` ever logs `FATAL: internal: worktree_path empty after
reconcile=proceed (ENG-67); refusing to dispatch from $TARGET_REPO`, that is the
D-003 invariant `die`-ing — most likely a Linear-API outage in `branch-name.sh`,
which now blocks ticks loudly rather than silently dispatching from the operator's
checkout. Operator action: inspect `$PROJECT_STATE_DIR/<slug>/logs/local-*.log` for
the preceding error from `branch-name.sh`/`linear.sh`, fix the underlying cause
(network, API key, Linear status), and the next tick resumes; do NOT bypass the
`die` by re-introducing a soft fallback.

## Sweep + scope partition (ENG-14)

After a clean stage run, `run-local.sh` does a tick-start vs tick-end dirty-path
diff and partitions changes into three streams via `partition_dirty_paths`:

1. **In-scope** → committed and pushed by the bot.
2. **Leaked-in-scope** → soft fail, increments `.consecutive-failures`, may trip breaker.
3. **Out-of-scope** → bucketed:
   - if path was in the tick-start snapshot → **observed** (info only — concurrent human work).
   - if NEW since tick start → **self-leak** → hard fail, breaker, no commit at all.

Anything writing files outside the per-stage allowlist must update the partition rules in
`run-local-helpers.sh` or it will trip the breaker.

## Per-target dispatch.tools extras (ENG-51, ENG-53 #8)

`dispatch.sh::allowed_tools_for` ships a Tauri-shaped base allowlist for each stage. To grant
extra Bash patterns for a non-Tauri target (e.g., `pytest` for Python, `go test` for Go,
`bash bin/*-test.sh` for harness-self), populate the target's `.pipeline-config/config.json`:

```json
{
  "dispatch": {
    "tools": {
      "implement": ["Bash(bash bin/*-test.sh:*)"],
      "qa":        ["Bash(bash bin/*-test.sh:*)"]
    }
  }
}
```

The entries are appended to the per-stage hardcoded base. `.pipeline-config/` is
gitignored, so each operator applies this on their own copy. For the harness-self target
specifically (the one driving this repo), this is required: without it, the implement and
qa agents have no allowlisted way to invoke `bash bin/<name>-test.sh` and ship without
running tests (the failure mode that drove ENG-53). Apply with:

```bash
jq '.dispatch.tools = {"implement":["Bash(bash bin/*-test.sh:*)"],"qa":["Bash(bash bin/*-test.sh:*)"]}' \
  .pipeline-config/config.json > /tmp/c && mv /tmp/c .pipeline-config/config.json
```

`bin/dispatch-test.sh` warns if the harness-self config exists locally but is missing
these entries (skipped silently when the config is absent — CI or non-harness operators).

## Per-stage dispatch timeouts (ENG-65)

`dispatch.sh::main` wraps each `claude -p` invocation with a `gtimeout` watchdog
(ENG-48). The cap defaults to **60 min for `brainstorming` and `planning`** (where
persona-review iterations legitimately span >30 min) and **30 min for every other
stage**. Two layers of override sit above those built-ins:

1. `orchestrator.dispatch_timeout_minutes_per_stage[<stage>]` — per-stage override
   in the target's `.pipeline-config/config.json`. Wins over both the global and
   the built-in default. Highest precedence.
2. `orchestrator.dispatch_timeout_minutes` — the existing global override (ENG-48).
   Applies to every stage.
3. Per-stage built-in default (above) — applied when neither override resolves.

```json
{
  "orchestrator": {
    "dispatch_timeout_minutes": 30,
    "dispatch_timeout_minutes_per_stage": {
      "brainstorming": 60,
      "planning":      60
    }
  }
}
```

Validation:
- Values must be **integers** (e.g. `60`, not `"60m"` or `"1h"`). Non-integer values
  fail the `^[0-9]+$` regex guard and fall through to the next layer.
- A resolved value `< 1` is rejected (gtimeout treats `0` as "no timeout", which
  would silently disable the watchdog). The per-stage built-in default is restored.

The canonical stage keys (gerund form per `dispatch.sh::allowed_tools_for`):
`brainstorming`, `planning`, `implementing`, `ui`, `reviewing`, `qa`, `building`,
`released`. **An unknown key (e.g. `brainstorm` missing `-ing`) silently falls
through** to the global, then to the built-in default — no warning is emitted.
After applying an override, grep `gtimeout ... <seconds>` in the per-stage
transcript at `$PROJECT_STATE_DIR/<ident>/logs/<stage>-*.log` to confirm the
override took effect.

Trade-off: a longer cap wastes more spend on a stalled agent before the watchdog
fires; a tighter cap risks SIGTERM mid-iteration on legitimate persona-review
work (the failure mode that drove ENG-65). Brainstorm's prompt-side 2-iteration
cap (D-001) bounds the persona path to ~36–60 min, so 60 min for brainstorming
is the upper bound — not a green light to widen further.

When SIGTERM fires before a `result` event lands, `_render_and_capture_stream`
falls back to summing per-message `assistant.message.usage.*` and writes a
partial usage file with `cost_usd: null` and `partial: true` (D-003). The
on-disk `partial: true` field is the discriminator the retrospective uses to
distinguish SIGTERM-captured runs from genuine zero-cost dispatches; the flag
stream emitted by `_cost_flags_for` shows `--cost-usd 0` (jq `// 0` coercion).

## When wiring a new script

- `source "$SCRIPT_DIR/common.sh"` first, before anything else. It enforces `TARGET_REPO`
  exists and exports the canonical paths.
- Use `log` / `die` / `require_env` / `require_bin` from common.sh — don't roll your own.
- Linear writes go through `bin/linear.sh` so dry-run and the `meta: dedup`
  (`add-or-update-comment <sig> <ident> <body>`) work uniformly. The function
  emits the new-shape `<!-- meta: dedup key=... -->` marker and looks up
  in-flight comments by both new and legacy shapes, so existing threads
  posted under the legacy `<!-- pipeline-sig: ... -->` writer are still
  updated in place rather than duplicated.
- Metric writes go through `bin/metrics.sh` so they end up in `events.jsonl` and on the
  retrospective's input.
- Per-stage allowed tool lists are centralized in `dispatch.sh::allowed_tools_for`. New
  stages must add a case there or dispatch dies.
- For exit codes, use the taxonomy in `failure_outcome_for_exit` (common.sh) — adding a new
  exit code without updating that switch routes it to `unknown-exit-N` and the
  retrospective's §1 filter will not classify it.
- New scripts that read or write per-project state must reference
  `$PROJECT_STATE_DIR`, never `$HARNESS_STATE_DIR/<issue>` directly.
  Cross-project shared state (the claude mutex, the project sentinel
  collision check) is the only legitimate use of `$HARNESS_STATE_DIR/`.
- Defense-in-depth on top of tool-lane denials: when a stage's contract says
  "agent must not invoke tool X," prefer a transcript-based assertion
  (`assert_no_tool_invocation` in `bin/dispatch.sh`) over a state-of-the-world
  check after dispatch. State checks false-positive on actions taken by other
  actors (humans, prior stages, future agents); transcript checks answer the
  contract question directly. Today only the implement stage uses this
  pattern (forbidding `gh pr create`); generalising to other stages is a
  separate refactor.
- For any new script that reads pipeline markers from Linear comments, use
  `parse_pipeline_marker` from `bin/common.sh` rather than hand-rolling
  contains-checks or regex extraction. The helper accepts both legacy
  (`pipeline-X: value`) and current (`pipeline: event k=v`) shapes and
  returns a uniform JSON event. The closed event vocabulary lives in
  `bin/pipeline-events.json`; the human-readable schema is in
  `docs/pipeline-vocabulary.md`.

## Single human-approval gate (ENG-54)

The pipeline collects human approval **once**, at the build stage's P2
preflight, on the post-QA SHA. The review stage is agent-only — it runs
cold-pass reviewers, comments on the PR, and either advances to QA or
loops back to implement. It does **not** wait for human approval, and
`bin/run-stage.sh::_fresh_wait_reason` allow-lists the wait shape for
`build` only.

**One-time migration when deploying ENG-54:** any issue currently in
flight at `stage:reviewing` with a `<!-- pipeline: verdict result=wait
reason=awaiting-approval -->` marker (or its legacy `<!-- pipeline-wait:
awaiting-approval -->` predecessor) as its latest comment will idle
indefinitely under the new contract (the wait shape no longer drives a
re-dispatch from review). Flush each such issue past the (now-removed)
gate by applying `pipeline:halted` and resolving:

```bash
bash bin/linear.sh add-label ENG-N pipeline:halted
bash bin/pipeline.sh decide ENG-N --action continue
```

The next tick resumes from review's clean-review path (Decision C),
emits `<!-- pipeline: verdict result=pass stage=reviewing -->`, and
transitions to QA. Issues at any other stage are unaffected.

## Failure-mode quick reference

| Symptom | Where to look |
|---|---|
| Tick is silent | `$PROJECT_STATE_DIR/logs/local-YYYY-MM-DD.log`, then per-stage transcript |
| Per-issue halt (self-leak / leaked-in-scope at threshold / N×same-issue failure) | Linear comments under sig `halt/<stage>/<issue>` (verdict `result=halt reason=agent-blocked`); `pipeline:halted` + `pipeline:skip-until-human-acts` labels; `$(issue_dir <issue>)/.consecutive-failures` carries the per-issue count. Other issues continue to be polled — do NOT touch `orchestrator.paused`. **One-command recovery:** `bash bin/pipeline.sh decide <ENG-N> --action continue` (clears halt label, skip labels, per-issue counter, issue-state, posts operator-resume waypoint). |
| Global breaker (infrastructure outage) | `$PROJECT_STATE_DIR/.consecutive-failures` ≥ 3 from `rc=24` (`linear-post-failed`) accumulated across ticks; `orchestrator.paused=true` in `STATE_FILE` or `CONFIG`. Resolve with `set_orchestrator_paused false` (or any `decide --action continue`, which also clears the breaker via `_pipeline_clear_breaker`). The next clean tick clears the global counter. |
| Issue stuck in `stage:X` | Linear comments under sigs `halt/<stage>/<issue>`, `scope-approval/<stage>/<issue>` (comment `createdAt` reflects FIRST emission only; check the `<!-- meta: reapplied at=… -->` footer for the latest re-apply moment — see `docs/runbooks/recovery.md` §4) |
| Wrong-target Linear writes | `git log` on `$TARGET_REPO/.pipeline-config/schemas/linear-ids.json` — stale cache is the usual cause |
| Kill switch | `bash bin/pipeline.sh decide <ENG-N> --action continue` (atomic reset, see below) or set `orchestrator.paused=true` (takes effect next tick) |
| Brainstorm halts at iteration 2 with `iteration-exhausted` (was: resolved on iteration 3) | New ENG-65 behavior: brainstorm voluntarily halts after 2 persona-review iterations with unresolved P0 instead of starting iteration 3. Inspect `$PROJECT_STATE_DIR/<ident>/worktree/docs/brainstorms/`; resume via `--action continue` or fix the underlying P0 in the plan. Bounded worst-case spend, costs one extra operator touch on slow-converging brainstorms. |

**What `--action continue` clears (atomic, ENG-58 ported to ENG-60; ENG-69 added per-issue counter clear):**

1. `pipeline:halted` label
2. `pipeline:skip-until-code-changes` and `pipeline:skip-until-human-acts` labels
3. `$PROJECT_STATE_DIR/<ident>/wait-*.json` files
4. `$PROJECT_STATE_DIR/<ident>/issue-state.json` IFF its `.policy == "skip-until-human-acts"`
5. Global breaker: `orchestrator.paused=true` cleared and `$PROJECT_STATE_DIR/.consecutive-failures` removed (via `_pipeline_clear_breaker`)
6. Per-issue counter: `$(issue_dir <issue>)/.consecutive-failures` removed (sibling of the global counter; written by `tally_leaked_in_scope_failure` and `route_run_stage_exit`'s per-issue arm)
7. Posts a `<!-- pipeline: transition from=<stage> to=<stage> reason=operator-resume -->` waypoint to reset `count_marker_since_last_transition` (rejection counter) and `find_fresh_verdict` freshness.

**Idempotent — safe to re-run.** Every operation (remove-label, rm -f,
add-comment) is idempotent; the operator-resume waypoint is posted
LAST so a partial-failure leaves the issue in a re-runnable state.
