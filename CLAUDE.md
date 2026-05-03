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
TARGET_REPO=/path/to/target bash bin/run-stage.sh ENG-5 brainstorm

# Manual retrospective:
TARGET_REPO=/path/to/target bash bin/run-retrospective-local.sh

# Dashboard (read-only — Linear + gh + metrics jsonl):
TARGET_REPO=/path/to/target bash bin/status.sh

# Dry-run any of the above (no Linear writes, no `claude` call, no Slack):
PIPELINE_DRY_RUN=1 TARGET_REPO=/path/to/target bash bin/run-stage.sh ENG-5 brainstorm

# Resolve a halted issue (see docs/pipeline-vocabulary.md for decision tokens):
bash bin/halt.sh resolve ENG-XX --decision <scope-approved|scope-rejected|resume>

# Post a verdict marker manually (heredoc-constructed; safe from bash !-expansion):
bash bin/post-verdict.sh ENG-N stage-summary <stage> [<reason>]
bash bin/post-verdict.sh ENG-N rejection <target-stage> [<reason>]
bash bin/post-verdict.sh ENG-N halt <reason-token> [<reason>]

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

Legacy `bin/halt.sh` and `bin/post-verdict.sh` still work as wrappers
for one release; both log a `[deprecated]` line on use.

The four pipeline-namespace labels the harness applies are:
`pipeline:halted`, `pipeline:supersede`, `pipeline:skip-until-code-changes`,
`pipeline:abandoned`. Every other `pipeline:*` label seen in Linear is human-applied.

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

## When wiring a new script

- `source "$SCRIPT_DIR/common.sh"` first, before anything else. It enforces `TARGET_REPO`
  exists and exports the canonical paths.
- Use `log` / `die` / `require_env` / `require_bin` from common.sh — don't roll your own.
- Linear writes go through `bin/linear.sh` so dry-run and the `pipeline-sig` dedup
  (`add-or-update-comment <sig> <ident> <body>`) work uniformly.
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
flight at `stage:reviewing` with a `<!-- pipeline-wait: awaiting-approval
-->` marker as its latest comment will idle indefinitely under the new
contract (the wait shape no longer drives a re-dispatch from review).
Flush each such issue past the (now-removed) gate by applying
`pipeline:halted` and resolving:

```bash
bash bin/linear.sh add-label ENG-N pipeline:halted
bash bin/halt.sh resolve ENG-N --decision resume
```

The next tick resumes from review's clean-review path (Decision C),
emits `pipeline-stage-summary: reviewing`, and transitions to QA.
Issues at any other stage are unaffected.

## Failure-mode quick reference

| Symptom | Where to look |
|---|---|
| Tick is silent | `$PROJECT_STATE_DIR/logs/local-YYYY-MM-DD.log`, then per-stage transcript |
| Breaker tripped | `$PROJECT_STATE_DIR/.consecutive-failures` ≥ 3 and `orchestrator.paused=true` in `STATE_FILE` or `CONFIG`; flip back via `set_orchestrator_paused false` (or `jq`) and the next successful tick clears the counter |
| Issue stuck in `stage:X` | Linear comments under sigs `halt/<stage>/<issue>`, `scope-approval/<stage>/<issue>` |
| Wrong-target Linear writes | `git log` on `$TARGET_REPO/.pipeline-config/schemas/linear-ids.json` — stale cache is the usual cause |
| Kill switch | `bash bin/halt.sh resolve …` or set `orchestrator.paused=true` (takes effect next tick) |
