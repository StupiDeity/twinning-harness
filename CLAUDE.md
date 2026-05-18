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

## PATH expectations on the launchd host

The plist (`launchd/com.twinning.pipeline.plist.template`) injects
`/opt/homebrew/{bin,sbin}:/usr/local/{bin,sbin}:/usr/{bin,sbin}:/{bin,sbin}` —
system + Homebrew (Apple Silicon + Intel), no `$HOME` segments.
`bin/run-local.sh` adds `$HOME/.bun/bin` and `$HOME/.npm-global/bin` for
dispatched agents on Bun/npm targets (harmless when absent).

Harness tools (`gtimeout`, `gh`, `claude`, `jq`, `awk`, `sed`, `git`,
`curl`) must resolve via Homebrew/system segments. Non-Homebrew installs
(MacPorts, Nix) and additional user-global bin dirs (`~/.cargo/bin`,
`~/go/bin`) need a manual plist edit + `launchctl bootstrap`.

`gtime` (Homebrew `gnu-time` package — distinct from `coreutils`, which
ships `gtimeout`) is required for the ENG-81 `dispatch-resource-sample`
metric. `bin/dispatch.sh` discovers it best-effort (`command -v gtime`);
absence logs a warning and skips the metric — no behavior change to the
dispatch itself, but the K-tuning baseline goes empty until installed.
Install with `brew install gnu-time`.

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

## Retrospective shapes (ENG-129)

The weekly retrospective binary (`bin/run-retrospective-local.sh`) is
being split into "shapes" — independently invocable sub-behaviors,
each with its own prompt body under `bin/retro-prompts/<name>.md`,
its own driver at `bin/retro-shape-<name>.sh`, and its own sibling
test at `bin/retro-shape-<name>-test.sh`. Shapes write a markdown
artifact under `$PROJECT_STATE_DIR/retrospective-${date}/<name>.md`;
the parent retrospective Reads each artifact via a
`{<name>_path}` token interpolated into AGENT_PROMPTS.md §9.

ENG-129 ships the first shape (`stage-failure-summary`). The other
§9 sub-behaviors stay inline in §9 until the coordinator ticket
ships. To add a shape: drop a new prompt body under `bin/retro-prompts/`,
write a driver + sibling test mirroring the `stage-failure-summary`
pair, and invoke the driver from `run-retrospective-local.sh::main`
before the §9 dispatch. Shapes reuse `dispatch.sh retrospective`'s
allowed-tools (no new arm in `allowed_tools_for`).

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

- **Every new ticket carries a type label at creation time.** Exactly one of
  `Bug` / `Feature` / `Improvement` MUST be set when the issue is filed:
  - `Bug` → `fix/<eng-n>-<slug>`
  - `Feature` / `Improvement` → `feat/<eng-n>-<slug>`

  Load-bearing — `branch-name.sh` re-evaluates the `Bug` label on every call.
  Adding/removing `Bug` after worktree creation causes branch-shape drift: the
  pushed branch has the old prefix, `branch-name.sh` returns the new one, and
  the PR-create hook silently fails (its `|| log` swallows it — see ENG-86).
  If unsure, ASK before creating; do not file unlabelled.

- **Mutate labels additively on existing issues.** Use `bash bin/linear.sh add-label`
  / `remove-label`. NEVER use Linear MCP `save_issue` to update an existing issue
  or mutate labels — it overwrites the entire label set, silently dropping
  `stage:*` / `pipeline:*` mid-flight. Creating new issues with `save_issue` IS
  expected (no prior labels to overwrite); set the type label and any initial
  labels in the create call's `labels` field.
- **Doc-to-issue ownership is YAML frontmatter, not prose.** `reconcile.sh` (lines ~68–77)
  greps the first 20 lines of `docs/brainstorms/*.md` and `docs/plans/*.md` for a literal
  `linear: ENG-N` line; that, plus a fallback H1 match, is what makes a doc the canonical
  artifact for an issue. Doc generators and any future docs-discovery code must emit this
  frontmatter or reconcile will treat the doc as fuzzy/non-canonical.
- **Brainstorm entry-state is `Todo`.** `poll.sh` only picks up issues whose Linear status
  is `Todo` AND which carry no `stage:*` label as fresh brainstorm candidates. Issues
  filed into `Backlog` (or any other state) are silently invisible to the poller until a
  human transitions them to Todo.

## Ticket sizing rubric (autonomy boundary)

Large tickets reliably need operator intervention to complete. File-time discipline
keeps the queue dispatchable. Two axes plus an umbrella veto.

**Axis 1 — Subsystems touched.** The harness has 7 separable subsystems:

| Subsystem | Files |
|---|---|
| orchestrator | `run-local.sh`, `poll.sh`, `run-stage.sh`, `reconcile.sh`, `classify-failure.sh`, `metrics.sh` |
| dispatch | `dispatch.sh`, `render-prompt.sh` |
| agent prompts | `AGENT_PROMPTS.md`, `learned-rules/` |
| Linear contract | `linear.sh`, markers, `pipeline-events.json`, labels |
| scope/sweep | `scope-check.sh`, `run-local-helpers.sh::partition_dirty_paths` |
| retrospective | `run-retrospective-local.sh`, retrospective-specific prompts |
| tests/fixtures | `bin/*-test.sh` |

- 1 subsystem → autonomy-safe; file as-is.
- 2 subsystems with one clearly subordinate → autonomy-safe IF the scope boundary is
  explicit in the ticket body.
- 3+ subsystems → **split before filing.**

**Axis 2 — Independent design decisions in the brainstorm.**

- 1 decision → autonomy-safe.
- 2 decisions where one is clearly subordinate → autonomy-safe.
- 2+ independent decisions → **split before filing.**

**Umbrella veto.** Any ticket framed as a "class", "umbrella", "structural", or
"meta-" issue → automatically too large. File the underlying observed-instance
tickets first; add a tracking parent only after the first instance ships.

**Split mechanics.** When splitting an existing umbrella:

1. Keep the umbrella in `Backlog` (becomes the parent).
2. File sub-tickets via `save_issue` with `parentId` set to the umbrella's identifier.
3. First-ready sub-tickets go to `Todo`; dependent ones stay in `Backlog` until their
   predecessor merges.
4. Sub-tickets carry their own type label (`Bug` / `Feature` / `Improvement`) per the
   filing convention above.

ENG-100, ENG-104, ENG-87 were all LARGE tickets that consumed disproportionate
operator time before this rubric existed. The rubric was calibrated against the
2026-05-15 audit of the open queue (18 tickets — 9 were LARGE).

## Per-issue state directory

Per-issue scratch lives under `$PROJECT_STATE_DIR/ENG-N/`:

```
$HARNESS_STATE_DIR/
├── .claude-semaphore/          # global counting semaphore (slot-<N>/pid each); replaces .claude-mutex.lock (ENG-81)
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
        ├── stage-summary-<stage>.md
        └── progress.md         # append-only per-issue notebook (see docs/runbooks/progress-md.md)
```

`issue-state.json` is durable state for skip-label dance + retry tracking.
`poll.sh` reads it every tick and includes/excludes based on `policy` plus
a recomputed `pipeline_content_hash` (sha256 over `bin/**`, `config.json`,
`AGENT_PROMPTS.md`) and branch-head SHA.

`progress.md` is an append-only per-issue notebook with the OPPOSITE
lifecycle from `stage-summary-<stage>.md`: it accumulates across the
issue's entire lifetime, is never cleared on dispatch start, and
survives `--action continue` resume. Stage agents write entries; the
orchestrator never reads or writes the file. Schema and the
canonical heading shape (`## <dispatch-id> - <stage> -
<ISO-8601-UTC>`) live in `docs/runbooks/progress-md.md`. Path
resolves through `bin/common.sh::progress_md_path <ident>`.

The orchestrator NEVER dispatches into `$TARGET_REPO` — every dispatch resolves
a per-issue worktree first (ENG-67). If you see the canonical operator-recognition
phrase `FATAL: internal: worktree_path empty after reconcile=proceed (ENG-67); refusing to dispatch from $TARGET_REPO`,
that's the D-003 invariant — usually a Linear-API outage in `branch-name.sh`.
Inspect logs for the preceding error, fix the underlying cause, next tick
resumes. Do NOT bypass via soft fallback.

## Sweep + scope partition (ENG-14)

After a clean stage run, `run-local.sh` partitions tick-start vs tick-end
dirty paths into three streams via `partition_dirty_paths`:

1. **In-scope** → committed and pushed.
2. **Leaked-in-scope** → soft fail, increments `.consecutive-failures`.
3. **Out-of-scope** → if path was in tick-start snapshot → **observed** (info
   only); if NEW → **self-leak** → hard fail, no commit.

The `implementing | ui | qa` allowlist comes from
`learned-rules/$PROJECT_SLUG/project-profile.md`'s `## File layout` section,
plus a stack-agnostic catalog of `docs/` and common manifest+lockfile
filenames (see `_always_include_paths` in `bin/run-local-helpers.sh`).

**Where to make scope changes:**

| Change shape | Edit |
|---|---|
| Permanent stack-shape change (new top-level dir) | `learned-rules/<slug>/project-profile.md::"## File layout"` (or rerun `bash bin/setup.sh project-profile`) |
| Per-target one-off | `config.json::scope.allowlist.<stage>[]` (gitignored, operator-local; overrides profile completely) |
| Common lockfile catalog | `_always_include_paths` in `bin/run-local-helpers.sh` (PR to harness repo) |

If profile is missing entries, scope falls back to `docs/` + lockfile catalog
only and the agent self-leaks on source-dir writes; rerun
`bash bin/setup.sh project-profile`.

**Always-include lockfile catalog.** Grants in-scope status for ALL common
manifest+lockfile filenames (`Cargo.toml/lock`, `package.json/-lock.json`,
`bun.lock/lockb`, `pyproject.toml + poetry.lock/uv.lock/Pipfile.lock`,
`go.mod/sum`, `Gemfile/.lock`) regardless of stack. False-positive scope
is bounded to top-level single-file matches. Tighten with
`config.json::scope.allowlist.<stage>[]` if too broad.

**Profile-driven `is_benign` lockfile set (ENG-96).**
`bin/scope-check.sh::is_benign` infers lockfile basenames per dispatch from
the profile's `## Build & test gates` section. Missing profile / unknown PM
tokens degrade gracefully to "path-classes-only benign" with a `log` warning.
The `$SCOPE_CHECK_PROFILE_PATH` env-var override is **test-only**.

**Sanctioned `.scratch/` carve-out — `implementing | ui | qa` only.**
`partition_dirty_paths` and `is_benign` treat `.scratch/*` as invisible
(neither in-scope nor leaked nor observed). On `brainstorming | planning`
the carve-out does NOT apply (cross-dispatch state-injection vector — D-004
issue-id constraint). The trailing slash is load-bearing — a top-level file
named `.scratchpad` is NOT carved out. `.scratch/` is `.gitignore`d.

**Docs-only + read-mostly stages auto-clean self-leak residue, never halt on it
(`brainstorming | planning | reviewing | building | released`).**
`stage_auto_cleans_self_leak` (`bin/run-local-helpers.sh`, ENG-100) is the
gate predicate at `bin/run-local.sh`'s self-leak branch — superset of the
legacy `stage_is_read_mostly` (SoT for "stage has no legitimate worktree
writes" — derived from `stage_output_paths` returning empty) extended with
the two doc-writing stages because their `--allowed-tools` surface has no
`Bash(rm:*)` (operator decision 2026-05-10). Unknown stages fall through
to NOT auto-clean.
`clean_self_leak_residue` runs *after* `partition_dirty_paths` has already
classified observed-vs-self-leak — operates only on paths NEW since
tick-start (C1 invariant — never touches operator's pre-existing 'observed'
edits). Per-path: tracked-modified → `git checkout --`; untracked →
`rm -rf`. Emits `sweep-readonly-residue-cleaned` metric with audit payload
(`count`, `branch`, `hashes` sha12-csv, `rm_fail`, `checkout_fail`); path
strings never reach Linear comments (adversarial-filename discipline).
Defensive guards: empty/missing-worktree/main-or-master/dry-run all no-op
safely. `implementing | ui | qa` are NOT affected — self-leak halts there
remain correct policy.

**Tick-end stage-agnostic `.scratch/` cleanup (`clean_scratch_dir`).**
`.scratch/` is `.gitignore`d so contents are invisible to `git status` on
every stage; without explicit cleanup, files persist into the next dispatch's
worktree where they could be `Read` by the next agent.
`clean_scratch_dir "$dispatch_cwd"` runs in `bin/run-local.sh`
**immediately after dispatch returns, before the rc-gate** —
load-bearing ordering pinned by `bin/run-local-helpers-adversarial-test.sh`
wire-up anchor #6. Placement downstream of the rc-gate would leak stale
payload across `--action continue` resume for every non-zero exit (timeout
rc=124, envelope rc=29, scope rc=21, crash). `rm -rf "$worktree/.scratch"`;
no-op if absent; dry-run logs only; failures non-blocking.

**Where stack knowledge lives.** The per-slug project profile at
`$HARNESS_ROOT/learned-rules/<slug>/project-profile.md` is the canonical
source of stack truth. It is authored by a one-shot discovery agent
during setup (`bash bin/setup.sh /path project-profile`) and consumed
by four sites: `dispatch.sh::_dispatch_tools_from_profile` (reads
`## Tool allowlist`), `run-local-helpers.sh::stage_output_paths`
(reads `## File layout` for the scope sweep),
`scope-check.sh::is_benign` (reads `## Build & test gates` to derive
the benign lockfile basename set — ENG-96), and
`render-prompt.sh::append_project_profile` (appends the entire
profile to every non-retrospective dispatch's prompt). Failure
asymmetry: the three dispatch-side consumers fall back stack-neutral
with a `log` warning (no `die`); the prompt-side
`render-prompt.sh::append_project_profile` dies loud on a missing or
malformed (unresolved `<<NEEDS-INPUT:>>`) profile with a
`bash bin/setup.sh /path project-profile` hint
(`bin/render-prompt.sh:184-200`). See docs/architecture.md "Discovery
and the project profile" for the full lifecycle.

## Per-target dispatch.tools extras and profile-derived tools (ENG-51, ENG-94)

`dispatch.sh::allowed_tools_for` ships a stack-neutral base allowlist per stage.
Per-target stack tools come from the profile's `## Tool allowlist` section
(`learned-rules/<slug>/project-profile.md`, schema_version 2). Operator-curated
extras come from `.pipeline-config/config.json::dispatch.tools.<stage>[]`.

Per-stage `--allowed-tools` argv composition (left-to-right):
**stack-neutral base + profile-derived stack tools + operator-curated extras**.
Empty segments elided. Claude's matcher is order-insensitive — ordering is
for log readability only.

**Fallback contract.** Missing profile / `schema_version != 2` / missing
`## Tool allowlist` → `_dispatch_tools_from_profile` returns empty, emits a
single `[allowed-tools]` warning to stderr, dispatch does NOT die.

**Wildcard pitfall.** Claude's matcher does NOT expand `*` inside a
`Bash(<prefix>:*)` prefix as a shell glob — `*` is treated literally.
`Bash(bash bin/*-test.sh:*)` matches *only* the literal string, not any actual
test script. Patterns must enumerate each script with a fully-literal prefix:

```json
{
  "dispatch": {
    "tools": {
      "implementing": [
        "Bash(bash .githooks/pre-commit:*)",
        "Bash(bash bin/secret-probe-lint.sh:*)",
        "Bash(bash bin/classify-failure-test.sh:*)",
        "...one literal entry per bin/*-test.sh..."
      ],
      "qa": [ "...same enumerated list..." ]
    }
  }
}
```

Stage keys are gerund form (`implementing`, `qa`). For the harness-self target
this is required (ENG-77 cascade May 2026). Regenerate when adding a test:

```bash
TESTS=$(ls bin/*-test.sh | sort | sed 's|^|Bash(bash |; s|$|:*)|')
LIST=$(printf '%s\n' \
  "Bash(bash .githooks/pre-commit:*)" \
  "Bash(bash bin/secret-probe-lint.sh:*)" \
  "$TESTS" | jq -R . | jq -s .)
jq --argjson l "$LIST" '.dispatch.tools = {"implementing": $l, "qa": $l}' \
  .pipeline-config/config.json > /tmp/c && mv /tmp/c .pipeline-config/config.json
```

`bin/dispatch-test.sh` asserts no broken wildcard is present and the enumerated
count covers every `bin/*-test.sh` on disk. The pitfall applies symmetrically
to the profile's `## Tool allowlist` section.

## Per-stage dispatch timeouts (ENG-65)

`dispatch.sh::main` wraps each `claude -p` with `gtimeout`. Defaults: **60 min
for `brainstorming`/`planning`** (persona-review iterations >30 min), **30 min
for every other stage**. Override precedence (highest first):

1. `orchestrator.dispatch_timeout_minutes_per_stage[<stage>]` — per-stage.
2. `orchestrator.dispatch_timeout_minutes` — global.
3. Per-stage built-in default.

```json
{
  "orchestrator": {
    "dispatch_timeout_minutes": 30,
    "dispatch_timeout_minutes_per_stage": {
      "brainstorming": 60,
      "planning": 60
    }
  }
}
```

Validation: integer regex `^[0-9]+$`, value `>= 1` (`gtimeout 0` would disable
the watchdog). Stage keys are gerund form (`brainstorming`, `planning`,
`implementing`, `ui`, `reviewing`, `qa`, `building`, `released`); unknown key
silently falls through. Confirm via `gtimeout ... <seconds>` in
`$PROJECT_STATE_DIR/<ident>/logs/<stage>-*.log`.

When SIGTERM fires before a `result` event lands, `_render_and_capture_stream`
sums per-message `assistant.message.usage.*` and writes a partial usage file
with `cost_usd: null` and `partial: true` (D-003 — distinguishes SIGTERM runs
from genuine zero-cost dispatches).

## Per-stage dispatch model (ENG-103)

`bin/run-stage.sh::_resolve_dispatch_model` resolves a Claude model
identifier and exports it as `PIPELINE_DISPATCH_MODEL` to
`bin/dispatch.sh::main`, which splices `--model "$VAR"` into the
`claude -p` argv when set. Resolution precedence (highest first):

1. `.pipeline-config/config.json::dispatch.model[<stage>]` — per-target
   operator pin.
2. Escalation override (implementing/ui only) when
   `_count_loopback_rejections_for_stage >= 1` since the most recent
   `<!-- pipeline: transition ... to=<stage> -->`. Fires on both
   rebase loopback (`building → implementing`) and review loopback.
3. Built-in default table:

| Stage | Default |
|---|---|
| `brainstorming` | `claude-opus-4-7` |
| `planning`      | `claude-opus-4-7` |
| `implementing`  | `claude-opus-4-7` (D-008: stays Opus until ENG-101 stabilises; flip to `claude-sonnet-4-6` once observed-good) |
| `ui`            | `claude-sonnet-4-6` |
| `reviewing`     | `claude-opus-4-7` |
| `qa`            | `claude-sonnet-4-6` |
| `building`      | `claude-haiku-4-5-20251001` |
| `released`      | (unset — subscription default) |

4. Unset (stage absent from default table) → no `--model` flag →
   subscription default.

```json
{
  "dispatch": {
    "model": {
      "implementing": "claude-opus-4-7[1m]",
      "qa": "claude-sonnet-4-6"
    }
  }
}
```

Validation: identifier regex `^[A-Za-z0-9._:-]+(\[[A-Za-z0-9._:-]+\])?$`
permits bracketed-suffix forms (`claude-opus-4-7[1m]`) and date-suffixed
forms (`claude-haiku-4-5-20251001`); rejects shell-meta payloads. Layer 1
also filters non-string config types at the jq layer (`strings` filter), so
`dispatch.model.implementing = 60` silently falls through to the default.
Stage keys are gerund form (`brainstorming, planning, implementing, ui,
reviewing, qa, building, released`); unknown key silently falls through.

Spot-check: `bash bin/status.sh` reads `events.jsonl::model` from
ENG-26 telemetry. Confirm post-ship that implementing rows show
`claude-sonnet-4-6` on first passes (after the D-008 flip),
`claude-opus-4-7` on retries, and building rows show
`claude-haiku-4-5-20251001`.

Operator-resolution log: `dispatch model=<resolved> (stage=<stage>)`
in `$PROJECT_STATE_DIR/<slug>/logs/<ident>-<stage>-*.log`. The
authoritative per-dispatch model is `usage-<stage>.json::model`
(what claude actually billed against) — they can diverge if the
subscription doesn't have access to the requested tier.

Escalation predicate sits next to (does NOT override) `guards.sh::check`'s
`implement_rejection` halt-threshold (default 2). After two failed
implement passes, the second one already escalated to Opus, then
guards trip and halt for human review.

Operator-tunable escalation thresholds (a future `dispatch.model_escalation[<stage>]`
config key) are deferred to a follow-up (brainstorm OQ-4); today's
predicate is hard-coded `>= 1`. An operator wanting to skip the cheap
cycle entirely can pin `dispatch.model[<stage>]` to `claude-opus-4-7`
directly, which wins over the escalation override per the precedence
table above.

## Orchestrator entry-conditions (ENG-86)

`bin/run-stage.sh::_entry_conditions_gate` is a config-driven pre-dispatch
gate (after `_pre_dispatch_merge_gate`, before render-prompt + dispatch).
Shells out to `bin/entry-conditions.sh::should_dispatch`, reads per-stage
checks from `.pipeline-config/config.json::orchestrator.entry_conditions[<stage>]`,
AND-gates results, prints `proceed` | `skip:<reason>` | `error:<check-name>`.

Phase 1 ships one check, `pr-approved-by-non-bot`, mirroring the agent-side
P2. Skips build-agent dispatch entirely (~100ms vs ~2min) when PR has zero
non-bot APPROVED reviews. New checks land in `_entry_check_handler_for`.

```json
{
  "orchestrator": {
    "entry_conditions": {
      "building": [
        { "name": "pr-approved-by-non-bot", "type": "github-pr-review" }
      ]
    }
  }
}
```

Validation:
- Unknown `name` is logged and skipped (no-op, NOT a hard error).
- Empty/null `entry_conditions` → `proceed` (back-compat).
- Stage keys are gerund form; unknown key silently falls through.
- On skip, gate calls `_handle_wait` so `external_signal_budget` halts a
  buggy predicate within `max_attempts` ticks.
- On `gh`/`jq` outage (rc=2 → `error:<check>`), orchestrator falls through
  to dispatch (D-010 fail-open). Agent's P2 is defense-in-depth.

Skip path emits paired `stage-start` + `stage-end` events with outcome
`dispatch-skipped`. Operator visibility: per-stage transcript
(`entry-conditions: skip` log) and `wait-building.json::attempts` — NOT
Linear comments (D-003 trade-off).

## Cross-dispatch staleness contract (ENG-87)

Six prior tickets (ENG-77, ENG-41 §1.1+§1.2, ENG-78, ENG-79, ENG-67) each
manifested the same structural failure: a fresh dispatch's reader treats
data written by a PRIOR dispatch as if it were current. ENG-87 ships a
unified hand-off contract.

**Glue: `PIPELINE_DISPATCH_ID`.** Allocated by `bin/run-stage.sh::main` once
per dispatch via `bin/common.sh::allocate_dispatch_id`. Format:
`ENG-N-d<NNNN>` (monotonic per issue). Persisted in
`issue-state.json::current_dispatch_id` + `current_dispatch_seq`. Exported
and inherited by `dispatch.sh`'s subshell, agent's `bash bin/linear.sh`
calls, and the post-dispatch envelope validator.

**Per-medium primitives:**

| Medium | Primitive | Site |
|---|---|---|
| Per-issue files | clear-on-dispatch-start | `bin/run-stage.sh::_clear_current_stage_slots` (current-stage only; OTHER stages preserved for loopback) |
| Linear comments | auto-inject `<!-- meta: dispatch id=… stage=… -->` | `bin/linear.sh::_inject_dispatch_marker` (idempotent) |
| Linear labels | lane fence | `bin/linear.sh::_check_lane` (ENG-41) |
| Prompt tokens | resolver registry + render-time validator | `bin/render-prompt.sh::PROMPT_RESOLVERS` |

**Reader-side filters.** `verdict-handler.sh::find_fresh_verdict` prefers
`dispatch_id`-equality over the timestamp window when ANY comment carries
the marker. `resume_in_progress_transition` rejects a transition whose
`meta: dispatch id=` disagrees with the current id. **Soft-fallback
(D-005):** legacy issues with no markers fall through to the existing
timestamp-window guard; expires the first time the orchestrator dispatches
post-cutover.

**Detective backstop.** `_validate_dispatch_envelope` scans the per-stage
transcript sidecar for `mcp__plugin_linear` or `curl https://api.linear.app`.
On match: emits `<!-- pipeline: verdict result=halt
reason=dispatch-envelope-violation -->` and exits 29. Fail-open on missing
sidecar (detective-only).

**`dispatch_history.jsonl`.** Per-issue append-only forensic log at
`$(issue_dir)/dispatch_history.jsonl`. Two rows per dispatch (start + end).
NEVER cleared; never read at runtime. Consumed by retrospective + manual
triage. **Accepted YAGNI cost** — captures forensic data starting at iter-1
to avoid back-fill when the first incident lands.

**Recovery.** `bash bin/pipeline.sh decide ENG-N --action continue` clears
the halt label and re-allocates a fresh `dispatch_id`. Transcript sidecar
preserved across the halt; removed by next dispatch's pre-clean.

**Forensic asymmetry post-resume.** After resume, strict id-match in
`find_fresh_verdict` filters the prior-dispatch halt comment OUT — its
marker mismatches the new id. Operator-triage tools (`bin/status.sh`,
manual grep) see "no fresh verdict" until the next verdict. Inspect prior
halts via `bin/linear.sh get-comments` + `verdict result=halt` filter;
`dispatch_history.jsonl` is intact across resume. D-005 trade-off:
forensic regression is the cost of strict id-match (vs V3 vulnerability).

**Operator gotcha — chained-command blind spot.** The envelope validator's
startswith prefix match is evaded by chained commands inside a single
`tool_use.input.command` string (e.g. `bash bin/linear.sh add-comment …;
mcp__plugin_linear …`). AGENT_PROMPTS.md preamble's "Dispatch identifier
and freshness contract" is the prompt-side defense.

## When wiring a new script

- `source "$SCRIPT_DIR/common.sh"` first. It enforces `TARGET_REPO` and exports
  canonical paths.
- Use `log` / `die` / `require_env` / `require_bin` from common.sh.
- Linear writes go through `bin/linear.sh` so dry-run + `meta: dedup`
  (`add-or-update-comment <sig> <ident> <body>`) work uniformly. The function
  emits `<!-- meta: dedup key=... -->` and looks up in-flight comments by both
  new and legacy shapes.
- Metric writes go through `bin/metrics.sh` (lands in `events.jsonl`).
- Per-stage allowed tool lists are centralized in
  `dispatch.sh::allowed_tools_for`. New stages must add a case there.
- For exit codes, use the `failure_outcome_for_exit` taxonomy (common.sh) —
  unmapped codes route to `unknown-exit-N` and the retrospective's §1 filter
  won't classify them.
- Per-project state must reference `$PROJECT_STATE_DIR`, never
  `$HARNESS_STATE_DIR/<issue>` directly. Cross-project shared state (claude
  mutex, project sentinel) is the only legitimate use of `$HARNESS_STATE_DIR/`.
- Defense-in-depth: when a stage's contract says "agent must not invoke tool X,"
  prefer a transcript-based assertion (`assert_no_tool_invocation` in
  `bin/dispatch.sh`) over a post-dispatch state check. State checks
  false-positive on actions taken by other actors. Today only implement uses
  this pattern (forbidding `gh pr create`).
- For scripts reading pipeline markers from Linear comments, use
  `parse_pipeline_marker` from `bin/common.sh` rather than hand-rolled
  contains/regex. Accepts both legacy (`pipeline-X: value`) and current
  (`pipeline: event k=v`) shapes. Closed vocabulary lives in
  `bin/pipeline-events.json`; schema in `docs/pipeline-vocabulary.md`.

## Single human-approval gate (ENG-54)

The pipeline collects human approval **once**, at build's P2 preflight on
the post-QA SHA. Review is agent-only — runs cold-pass reviewers, comments
on the PR, and either advances to QA or loops back to implement. It does
**not** wait for human approval; `_fresh_wait_reason` allow-lists the wait
shape for `build` only.

## Slot-occupancy contract (ENG-90)

`bin/poll.sh::_poll_classify_labels` is the slot-classification surface.
Every output declares one of:

- **`slot:"terminal"`** — `pipeline:abandoned`. Never recalled.
- **`slot:"hold", advanceable:true`** — Active development. Pass 4 will
  dispatch a `claude -p` agent on this tick.
- **`slot:"vacate", operator_action_required:true`** — Agent-idle, recall
  path requires operator action (label removal,
  `bin/pipeline.sh decide --action continue`, PR review). Counted by
  `_poll_emit_halt_sprawl_alert`'s threshold.
- **`slot:"vacate", operator_action_required:false`** — Agent-idle,
  recall is automatic (next-tick orchestrator-side state check:
  `review_should_dispatch`, `pipeline_content_hash`, `_handle_wait`'s
  budget). Excluded from halt-sprawl.

`slot:"hold", advanceable:false` is not part of the contract. If a new
branch needs to express "do not dispatch but keep the slot," it doesn't
exist — reach for `vacate` (with the appropriate `operator_action_required`
flag) instead.

Adding a new branch to `_poll_classify_labels` MUST set
`operator_action_required` for every `slot:"vacate"` output AND add a
fixture under `bin/poll-slot-test.sh::AC-OAR-*`. The adversarial
halt-sprawl test
(`bin/halt-sprawl-adversarial-test.sh::AC-ADV-MISSING-FLAG`) catches
silent omissions for the alert path; the poll-slot per-row fixtures
catch silent omissions for the classifier path.

## Failure-mode quick reference

For "this looks weird and I'm not sure why" mental-model gaps (slot
accounting surprises, disk vs Linear divergence, sig-dedup invisibility,
branch shape invariants, per-target setup gaps), see
[`docs/runbooks/operator-mental-model.md`](docs/runbooks/operator-mental-model.md)
— it catalogs the silently load-bearing assumptions that have repeatedly
cost operator time, with `grep` / `cat` / `bin/linear.sh` commands to
inspect each surface.

| Symptom | Where to look |
|---|---|
| Tick is silent | `$PROJECT_STATE_DIR/logs/local-YYYY-MM-DD.log`, then per-stage transcript |
| Tick is silent for ≥2 ticks (≥10 min) AND `bin/status.sh` shows the issue with `stage:*` but no fresh `dispatch.sh exit=` line in the day-log → suspect ENG-131-class hang | Pre-ENG-131 (≤ 2026-05-15): `bin/dispatch.sh`'s outer `cmd \| renderer` pipe could leave the reader blocked when MCP-server descendants reparented to launchd held the inherited fd1; the lock holder's `wait` blocked indefinitely; the tick lock stayed alive past the `gtimeout` watchdog. Post-ENG-131, operators should NOT see this symptom — `bin/dispatch.sh` exits within `kill_after + ε` (≤12s) of any `gtimeout` fire. **First check:** `tail -50 $PROJECT_STATE_DIR/<slug>/logs/local-$(date -u +%Y-%m-%d).log` for the last `dispatch.sh exit=` line. If no `exit=` line in the last ~30 min: `pgrep -af claude` enumerates orphan MCP descendants still alive; the holder pid in `$PROJECT_STATE_DIR/.run-local.lock/pid` is alive but `wait`-blocked (= bug recurrence). **If symptom recurs post-ENG-131:** root cause is a NEW hang class (different from the pipe-fd retention ENG-131 fixed); file a sibling ticket (sibling stuck-tick alarm ticket TBD). |
| Per-issue halt (self-leak / leaked-in-scope at threshold / N×same-issue failure) | Linear comments under sig `halt/<stage>/<issue>` (verdict `result=halt reason=agent-blocked`); `pipeline:halted` + `pipeline:skip-until-human-acts` labels; `$(issue_dir <issue>)/.consecutive-failures` carries per-issue count. Other issues keep polling — do NOT touch `orchestrator.paused`. **Recovery:** `bash bin/pipeline.sh decide <ENG-N> --action continue`. Self-leak halts only fire on `implementing | ui | qa`; on `brainstorming | planning | reviewing | building | released`, `clean_self_leak_residue` auto-cleans (check `sweep-readonly-residue-cleaned` metric). |
| Global breaker (infrastructure outage) | `$PROJECT_STATE_DIR/.consecutive-failures` ≥ 3 from `rc=24` (`linear-post-failed`); `orchestrator.paused=true`. Resolve with `set_orchestrator_paused false` or any `decide --action continue` (clears via `_pipeline_clear_breaker`). |
| Issue stuck in `stage:X` | Linear comments under sigs `halt/<stage>/<issue>`, `scope-approval/<stage>/<issue>`. Comment `createdAt` reflects FIRST emission only — check `<!-- meta: reapplied at=… -->` footer for latest identical re-apply (ENG-63), or grep for `<!-- meta: breadcrumb sig=… -->` comments for body-change history (ENG-111); see `docs/runbooks/recovery.md` §4. |
| Approved/ready ticket at later stage sits idle while earlier-stage/inbox issue dispatches each tick | Pre-ENG-91 the picker walked Pass 4→5→6 sequentially and exited after first dispatch. ENG-91's unified Pass 4U picker (`bin/poll.sh::_picker_build_pool`) sorts by `[-stage_index, -priority_sort_rank, fifo_ts]` and gates wait_recallable inclusion on `should_dispatch == proceed`. Inspect logs for `picker: wait_recallable <ENG-N> skipped (predicate not ready)`. Recovery: add `pipeline:paused` to held issue, let next tick re-pick the wait, then remove. |
| Wrong-target Linear writes | `git log` on `$TARGET_REPO/.pipeline-config/schemas/linear-ids.json` — stale cache is the usual cause |
| Kill switch | `bash bin/pipeline.sh decide <ENG-N> --action continue` (atomic reset) or set `orchestrator.paused=true` (next tick) |
| Brainstorm halts at iteration 2 with `iteration-exhausted` | ENG-65: voluntarily halts after 2 persona-review iterations with unresolved P0. Resume via `--action continue` or fix underlying P0. Bounded worst-case spend; one extra operator touch on slow-converging brainstorms. |
| scope-check halts on files from a recent upstream merge | Pre-ENG-59 bug; post-ENG-59 (`bin/scope-check.sh:155-…`) fetches `origin main` per run. If symptom persists, check transcript for `scope-check: fetch origin main failed` — fetch unreachable + no `refs/remotes/origin/main` falls back to local `main` (degraded mode with warning). |
| Issue at `stage:building` idles with `dispatch-skipped` events and no halt label | Inspect `wait-building.json::attempts` — ENG-86 entry-conditions gate firing skip per `gh pr view`. If PR is approved by a non-bot Code Owner, check whether `gh` is on PATH for launchd. If not approved, operator action is the underlying remedy. |
| Concurrent dispatches not running (expected K=2, observed K=1) | `bash bin/status.sh` "Concurrent dispatches active" row + "Dispatch resource baseline" tail; check `_resolve_K` resolved value in `$PROJECT_STATE_DIR/<slug>/logs/local-*.log` (look for `scheduler: K=…`); inspect `CLAUDE_MAX_CONCURRENT` env in the launchd plist; inspect `orchestrator.max_concurrent_features` in the target's `.pipeline-config/config.json`. |
| Issue stuck at one stage; `$(issue_dir <issue>)/.in-flight.lock` present | Scheduler-side pre-ENG-81 leak symptom: lock orphaned across a SIGKILL / oomkill / scheduler-error path. **Self-heal:** `try_acquire_lock` (common.sh) writes the holder pid+timestamp on every acquire and reclaims the lock on next attempt if `kill -0 $pid` fails — no operator action needed. If the holder pid IS alive but the issue still appears stuck, inspect `ps -p $(cat .in-flight.lock/pid)` and `.in-flight.lock/timestamp` (ISO-UTC); a manual `rm -rf` is the override of last resort. |
| `reviewing → qa` transition halts on `review_rejection(N>=2)` after a clean reviewing PASS | Pre-ENG-138 bug; post-ENG-138 (`bin/guards.sh::check`, gated on `stage == implementing`) the trip only fires at the next `implementing` dispatch. If symptom persists, check transcript for `guards: tripped on ENG-N: review_rejection`; recovery is the standard `bash bin/pipeline.sh decide <issue> --action continue` reset, but the bug itself should not recur post-ENG-138. |
| Slack message "Stuck tick alarm" arrived (alarm fired) | `bin/run-local.sh` is wedged — the alarm itself ran. Inspect `$PROJECT_STATE_DIR/.last-tick-end` mtime, `$PROJECT_STATE_DIR/.run-local.lock/pid`, then `ps -p <pid> -o pid,ppid,user,command`. Recovery: `launchctl kickstart -k gui/$(id -u)/com.twinning.pipeline.$PROJECT_SLUG` (force-kill + restart) after confirming the holder is wedged. |
| No Slack but `bin/status.sh` shows last tick stale > threshold | The `com.twinning.stuck-tick-alarm.<slug>` launchd agent itself is down (so no alarm can fire). Inspect `launchctl print gui/$(id -u)/com.twinning.stuck-tick-alarm.$PROJECT_SLUG` and `$PROJECT_STATE_DIR/logs/stuck-tick-alarm-launchd.err.log`. Recovery: `bash bin/install-launchd.sh /path/to/target` to re-render and re-bootstrap. |

## Per-project dispatch concurrency (ENG-81)

`orchestrator.max_concurrent_features` (default 2) caps **simultaneous
`claude -p` dispatches per project per tick** AND the WIP cap on issues
in any `stage:*` label. Pre-ENG-81 it only enforced the WIP cap; the
per-tick dispatch count was hardwired to 1 by `bin/run-local.sh`. After
ENG-81 a default config (`max_concurrent_features=2`) produces ~2× the
per-tick dispatch volume on busy days — operators upgrading should
expect this.

Resolution precedence (mirrors ENG-65 timeouts):

1. `CLAUDE_MAX_CONCURRENT` env var (set in
   `~/Library/LaunchAgents/com.twinning.pipeline.plist`'s
   `EnvironmentVariables` block + `launchctl bootstrap`) — highest.
2. `.orchestrator.max_concurrent_features` in target's
   `.pipeline-config/config.json`.
3. Built-in default 2.

Non-integer or `<1` falls through to the next layer with a `log` warning
on stderr (visible in `$PROJECT_STATE_DIR/<slug>/logs/local-*.log`).

Inspect live concurrency:

```
ls $HARNESS_STATE_DIR/.claude-semaphore/slot-*/pid
```

Each slot directory carries the `dispatch.sh` PID that owns it; an empty
listing means no live dispatches. `bash bin/status.sh` aggregates this
plus the recent `dispatch-resource-sample` baseline.

**Emergency rollback** (no deploy needed): `CLAUDE_MAX_CONCURRENT=1` in
the launchd plist + `launchctl bootstrap`. Per-project rollback: edit
that target's `config.json::orchestrator.max_concurrent_features` to 1.

## Stuck-tick alarm (ENG-132)

An independent launchd job (`com.twinning.stuck-tick-alarm.<slug>`, every 15 min) reads the
mtime of `$PROJECT_STATE_DIR/.last-tick-end` — an atomic heartbeat file written by
`bin/run-local.sh` immediately after each successful tick. When `now - mtime` exceeds the
configured threshold, `bin/stuck-tick-alarm.sh` posts to Slack via `bin/slack.sh warn`
with a triage payload (heartbeat age, lock-holder pid + `ps` excerpt, log tail).

**Resolution precedence** (matches `dispatch_timeout_minutes` / `max_concurrent_features`):

1. `STUCK_TICK_ALARM_MINUTES` env var (set in the alarm plist's `EnvironmentVariables`
   block + `launchctl bootstrap`) — highest.
2. `orchestrator.stuck_tick_alarm_minutes` in target's `.pipeline-config/config.json`.
3. Built-in default `30` (minutes).

**Validation:** value must be an integer `>= 10` (floor = 2× tick cadence). Invalid values
log a warning and fall through to the next layer.

```json
{
  "orchestrator": {
    "stuck_tick_alarm_minutes": 45
  }
}
```

- **K=2 long-brainstorm false-positive:** with K=2 and a 60-min brainstorm dispatch, the
  heartbeat can go stale for ~60 min, triggering the alarm once. The 24h debounce prevents
  Slack flood. Tune `stuck_tick_alarm_minutes: 75` to absorb the worst case.
- **Planned-maintenance silencing:** set `STUCK_TICK_ALARM_MINUTES=9999` in the alarm
  plist's `EnvironmentVariables` and run `launchctl bootstrap`; revert when done.
- **Manual smoke test:** `bash bin/stuck-tick-alarm.sh` from the CLI applies the full
  threshold + debounce logic (no harm if the heartbeat is fresh — exits 0 silently).
- **File paths:** heartbeat at `$PROJECT_STATE_DIR/.last-tick-end`; debounce stamp at
  `$PROJECT_STATE_DIR/.stuck-tick-last-alerted`; alarm cadence 15 min.

**What `--action continue` clears (atomic):**

1. `pipeline:halted` label
2. `pipeline:skip-until-code-changes` and `pipeline:skip-until-human-acts` labels
3. `$PROJECT_STATE_DIR/<ident>/wait-*.json` files
4. `issue-state.json` IFF its `.policy == "skip-until-human-acts"`
5. Global breaker: `orchestrator.paused=true` + `$PROJECT_STATE_DIR/.consecutive-failures` (via `_pipeline_clear_breaker`)
6. Per-issue counter: `$(issue_dir <issue>)/.consecutive-failures`
7. Posts `<!-- pipeline: transition from=<stage> to=<stage> reason=operator-resume -->` waypoint to reset rejection counter and `find_fresh_verdict` freshness.

**Idempotent — safe to re-run.** Operations are idempotent; the
operator-resume waypoint is posted LAST so a partial-failure leaves the
issue re-runnable.
