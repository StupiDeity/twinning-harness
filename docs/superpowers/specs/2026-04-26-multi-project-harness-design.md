---
linear: ENG-TBD
title: Multi-project harness — single install, N target repos
date: 2026-04-26
status: draft
---

# Multi-project harness — single install, N target repos

## 1. Goal

Allow one harness installation on a single host to drive N independent target
repositories concurrently, with each project isolated from the others (own
breaker, own lock, own metrics, own logs, own launchd services).

A "project" is the tuple `(target_repo_path, linear.team_id, linear.project_id,
project.slug)`. The slug — derived once from `linear-ids.json::.project.name` —
is the namespace key for filesystem state and launchd labels.

## 2. Non-goals

- Cross-project orchestration (one issue spanning multiple repos).
- Per-project `learned-rules/` partitioning (deferred; v1 serializes the
  retrospective via the global mutex — see §5.5).
- macOS Keychain for secrets (deferred).
- `setup.sh --non-interactive` (deferred).
- GitHub App manifest auto-create (deferred).
- Cross-project status dashboard (`status.sh --all`) — `status.sh` stays
  single-project per `TARGET_REPO`.

## 3. Identity model

- `linear.team_id`, `linear.project_id` (UUIDs) live in
  `$TARGET_REPO/.pipeline-config/config.json` (already present).
- `project.slug` is a new field in the same `config.json`. It is **frozen
  at first setup** by reading `linear-ids.json::.project.name` and slugifying.
- Slugifier rules (deterministic):
  - Lowercase the name.
  - Replace any character outside `[a-z0-9-]` with `-`.
  - Collapse repeats; trim leading/trailing `-`.
  - Validate the result against `^[a-z][a-z0-9-]{1,38}[a-z0-9]$` — starts
    with a letter, ends with a letter or digit, total length 3–40 (the
    middle character class repeats 1–38 times, plus the two anchored chars).
    Fail loudly otherwise — the human renames the project in Linear or
    supplies a `--slug` override to `setup.sh`.
- The slug is never re-derived after first write. Linear renames are silent.
  Deliberate slug changes go through an explicit rename flow (out of scope for
  v1; documented as a manual chore: bootout agents, move state dir, edit
  `config.json`, reinstall).
- Collision check at slug-freeze time: if `$HARNESS_STATE_DIR/<slug>/` already
  exists with a different recorded `target-repo` sentinel inside it, refuse and
  print both paths in the error.

## 4. Filesystem layout

```
${XDG_CONFIG_HOME:-~/.config}/twinning-harness/      # shared, per-user
├── secrets.env              LINEAR_API_KEY, GH_APP_ID, GH_APP_PRIVATE_KEY_PATH,
│                            PIPELINE_SLACK_WEBHOOK_URL    (mode 0600)
└── github-app.pem           default location for GitHub App private key
                             (mode 0600; referenced by GH_APP_PRIVATE_KEY_PATH)

$TARGET_REPO/.pipeline-config/                       # per-project, in-repo
├── config.json              team_id, project_id, project.slug, workflow knobs
├── schemas/linear-ids.json  Linear ID cache
├── state.local.json         orchestrator.paused override
└── .env.local               GH_APP_INSTALLATION_ID  (+ per-project overrides)

${XDG_STATE_HOME:-~/.local/state}/twinning-harness/  # local runtime
├── .claude-mutex.lock/      cross-project single-flight around dispatch.sh
└── <slug>/
    ├── target-repo          plain-text absolute path; collision sentinel
    ├── .run-local.lock/     per-project tick lock
    ├── .consecutive-failures
    ├── .tick-counter
    ├── last-observed-release
    ├── logs/local-YYYY-MM-DD.log + per-stage transcripts
    ├── metrics/events.jsonl
    └── ENG-N/
        ├── worktree/
        ├── issue-state.json
        └── stage-summary-<stage>.md

~/Library/LaunchAgents/
├── com.twinning.pipeline.<slug>.plist
└── com.twinning.retrospective.<slug>.plist
```

`run-local.sh` source-order at tick start: `secrets.env` first (shared), then
`$TARGET_REPO/.pipeline-config/.env.local` (per-project; can override).

## 5. Components

### 5.1 `bin/common.sh` — minimal extension

After the existing `TARGET_REPO` resolution, add:

```bash
PROJECT_SLUG="$(jq -r '.project.slug // empty' "$CONFIG" 2>/dev/null)"
[[ -n "$PROJECT_SLUG" ]] || die "config.json::project.slug missing — run bin/setup.sh first"
PROJECT_STATE_DIR="$HARNESS_STATE_DIR/$PROJECT_SLUG"
HARNESS_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/twinning-harness"
export PROJECT_SLUG PROJECT_STATE_DIR HARNESS_CONFIG_DIR
```

`setup.sh` itself bypasses this guard while the slug is being established
(it sets `TWINNING_BOOTSTRAPPING=1` before sourcing common.sh, and common.sh
soft-fails the slug check under that flag).

### 5.2 `bin/setup.sh` (new) — one entry point for onboarding

`bash bin/setup.sh /path/to/target [phase]`

Phases (idempotent, resumable; re-running runs the first unsatisfied phase forward):

| # | Phase | Effect |
|---|---|---|
| 1 | `workspace` | Verify target repo. Create `.pipeline-config/`, `.pipeline-config/schemas/`. Create `$HARNESS_CONFIG_DIR` (mode 0700). |
| 2 | `linear-auth` | Read existing `LINEAR_API_KEY` from `secrets.env` if present; otherwise prompt. Verify with a `viewer { id name }` GraphQL query. Persist to `secrets.env` (mode 0600). |
| 3 | `linear-identity` | Query Linear for the user's teams; user picks. Query the team's projects; user picks (or follows a printed link to create one in Linear). Write `linear.team_id` and `linear.project_id` into `config.json`. |
| 4 | `linear-schema` | Invoke `bin/setup-labels.sh` (idempotent label creation). On success invoke `bin/linear.sh refresh-cache` to populate `linear-ids.json`. |
| 5 | `slug-freeze` | Read `linear-ids.json::.project.name`. Slugify per §3. Collision-check against `$HARNESS_STATE_DIR/<slug>/target-repo` if present. Write `project.slug` into `config.json`. Write `target-repo` sentinel inside the per-project state dir. |
| 6 | `github-app` | Print URL of the GitHub App creation page with required permissions checklist. Prompt for `GH_APP_ID` and `GH_APP_INSTALLATION_ID`. Prompt for path to private key `.pem` (default `$HARNESS_CONFIG_DIR/github-app.pem`); copy/move to that path with mode 0600. Persist `GH_APP_ID` + `GH_APP_PRIVATE_KEY_PATH` into `secrets.env`; persist `GH_APP_INSTALLATION_ID` into `.env.local`. Verify by minting a token via `bin/gh-app-token.sh`. |
| 7 | `gh-cli` | Run `gh auth status`; if unauthenticated, prompt user to run `gh auth login` and pause until they confirm. |
| 8 | `slack` (optional) | Prompt for `PIPELINE_SLACK_WEBHOOK_URL`, persist in `secrets.env`, or skip. |
| 9 | `config-defaults` | Ensure `config.json` has `orchestrator.paused: false`, `linear.stage_label_prefix: "stage:"`, `linear.workflow_stages: [...]`, `linear.native_states.active: "In Progress"`. Only writes missing keys; never overwrites human-set values. |
| 10 | `validate` | Run `bin/dry-run.sh` offline checks; report pass/fail. |
| 11 | `launchd` | Prompt: "Install launchd agents for `<slug>` now? [Y/n]". On Y, invoke `bin/install-launchd.sh /path/to/target`. |
| — | `migrate-state` (transitional) | One-time migration of an existing single-project install. Only invokable explicitly by `setup.sh /path migrate-state`; never run by the no-arg form. See §6 for the migration sequence. |

`setup.sh /path` (no phase arg) runs all unsatisfied phases 1–11.
`setup.sh /path <phase>` jumps to one phase. `setup.sh /path validate` is
the health-check shortcut. `setup.sh /path migrate-state` is the one-time
upgrade path (§6).

### 5.3 `bin/install-launchd.sh` — slug-aware

Signature change: takes the target repo path as an arg.

```
bash bin/install-launchd.sh /path/to/target
```

It reads `project.slug` from the target's `config.json`. Templates are
substituted with one extra placeholder `__PROJECT_SLUG__`. Output filenames:
`com.twinning.pipeline.<slug>.plist`, `com.twinning.retrospective.<slug>.plist`.
The plist `Label` becomes the same. `StandardOutPath` and `StandardErrorPath`
become `$HARNESS_STATE_DIR/<slug>/logs/launchd.{out,err}.log`.
`EnvironmentVariables` includes `TARGET_REPO`, `HARNESS_STATE_DIR`, and
`PROJECT_SLUG`. Bootout-then-bootstrap targets only the slug-suffixed labels —
sibling projects' agents are untouched.

`bin/uninstall-launchd.sh` accepts one of three argument forms:
- `bin/uninstall-launchd.sh /path/to/target` — resolves slug from the
  target's `config.json`.
- `bin/uninstall-launchd.sh --slug <slug>` — direct slug, useful when the
  target repo path is no longer accessible.
- `bin/uninstall-launchd.sh --legacy` — removes the un-suffixed
  `com.twinning.pipeline` and `com.twinning.retrospective` agents, used
  exactly once during the migration in §6.

In every form, only the named labels are bootouted and only their plists
removed; sibling projects' agents are untouched.

### 5.4 `bin/run-local.sh` — minimal changes

- Lock dir: `$PROJECT_STATE_DIR/.run-local.lock/` (was top-level).
- Breaker counter, tick counter, last-observed-release, logs all become
  per-project automatically by virtue of swapping `$HARNESS_STATE_DIR/...` for
  `$PROJECT_STATE_DIR/...` in the existing path-deriving call sites.
- Metrics: `$PROJECT_STATE_DIR/metrics/events.jsonl`.
- Source order: `secrets.env` then `.env.local`.
- New: a single-flight mutex implemented **inside `bin/dispatch.sh`** (the
  one and only caller of `claude -p`). On entry, dispatch.sh acquires
  `$HARNESS_STATE_DIR/.claude-mutex.lock/` (cross-project) with a configurable
  timeout (default 600s = one tick window) and releases it on exit via a trap.
  Logs `[claude-mutex] waiting for lock held by <pid>` while blocked. Putting
  the mutex inside dispatch.sh — rather than at the run-stage.sh call site —
  means every consumer of the agent is automatically serialized, including
  the weekly retrospective and any future direct dispatch caller.

### 5.5 `learned-rules/` — v1 stopgap, deferred fix

The retrospective agent edits files in `$HARNESS_ROOT/learned-rules/`. With N
projects each running a Monday retrospective in parallel, two retrospectives
could race against the same files.

**v1 stopgap is automatic** because the retrospective runs through `dispatch.sh`
like every other agent, and the §5.4 mutex serializes all `claude -p` calls
across projects. So overlapping Monday retrospectives queue rather than race —
no extra wiring needed.

**Real fix (deferred)**: namespace the rules per project as
`learned-rules/<slug>/`, update `render-prompt.sh` to concatenate the
slug-specific rules into the per-stage base prompt, and update the
retrospective agent's prompt to write to its own slug's directory. Filed as
ENG-followup; not blocking this spec.

### 5.6 Other scripts — pass-through, mechanical sweep

`poll.sh`, `reconcile.sh`, `run-stage.sh`, `classify-failure.sh`, `dispatch.sh`,
`linear.sh`, `metrics.sh`, `cleanup-worktrees.sh`, `verdict-handler.sh`,
`scope-check.sh`, `halt.sh`, `status.sh` need no functional changes. They
already path-derive everything from `TARGET_REPO`/`HARNESS_STATE_DIR` via
common.sh. The change is mechanical: every direct reference to
`$HARNESS_STATE_DIR/<issue>/` or `$HARNESS_STATE_DIR/{logs,metrics,...}`
becomes `$PROJECT_STATE_DIR/...`. Single grep + sed pass, one PR.

## 6. Migration (existing single-project install)

The current Mac Studio install is single-project, so a one-time migration is
required. Documented in CLAUDE.md and the Linear issue body:

1. `bash bin/setup.sh /path/to/twinning slug-freeze` — derives + writes
   `project.slug` for the existing target.
2. `bash bin/setup.sh /path/to/twinning migrate-state` — a phase used only on
   this transition:
   - Detects top-level `$HARNESS_STATE_DIR/ENG-N/` dirs and the global files
     `.consecutive-failures`, `.run-local.lock`, `.tick-counter`,
     `last-observed-release`, `logs/`, `metrics/`.
   - Moves them under `$HARNESS_STATE_DIR/<slug>/`.
   - Idempotent: skip files already migrated.
3. `bash bin/uninstall-launchd.sh --legacy` — bootouts the un-suffixed
   `com.twinning.pipeline` and `com.twinning.retrospective`.
4. `bash bin/install-launchd.sh /path/to/twinning` — installs the slug-
   suffixed pair.

After the migration phase has been run once, the `migrate-state` phase
remains a no-op on subsequent invocations and can be removed in a later
spring-cleaning PR.

## 7. Testing

- `bin/setup-test.sh` (new). Mocks `linear.sh` and `gh-app-token.sh` via
  `STUB_DIR`. Each phase exercised in three orderings: missing precondition →
  success → idempotent re-run. Atomic-write + mode-0600 assertions for
  `secrets.env` and `config.json`.
- `bin/install-launchd-test.sh` (new). Renders into a fixture
  `LaunchAgents` directory; asserts `__PROJECT_SLUG__` substitution; asserts
  uninstall-by-slug is surgical (a sibling slug's plist remains).
- `bin/mutex-test.sh` (new). Two concurrent `dispatch.sh` calls under
  `PIPELINE_DRY_RUN=1` serialize via `.claude-mutex.lock/`; the second
  observes the first's PID in its log line.
- Existing tests (`run-stage-test.sh`, `run-local-sweep-test.sh`,
  `reconcile-test.sh`, `poll-slot-test.sh`, etc.) get a one-line fixture
  change: their per-test stub layout already overrides `HARNESS_STATE_DIR`
  to a tempdir; we additionally export `PROJECT_SLUG=test-slug` so common.sh
  derives `PROJECT_STATE_DIR=<tempdir>/test-slug`. The existing post-source
  override pattern (per CLAUDE.md "How tests work") makes this a one-line
  change per file.

## 8. Failure modes

| Symptom | Cause | Diagnostic / remediation |
|---|---|---|
| `setup.sh` fails at `linear-auth` | bad `LINEAR_API_KEY` | rewind to `linear-auth`; key auth response printed |
| `setup.sh` collision at `slug-freeze` | another target uses this slug | error includes the conflicting `target-repo` sentinel path |
| `install-launchd.sh` fails "project.slug missing" | setup.sh not run yet | message points at `bin/setup.sh /path` |
| Tick fails "secrets.env missing" | shared file deleted or never written | message points at `bin/setup.sh /path linear-auth` |
| Two projects' ticks contend on claude | mutex held by sibling | log line `[claude-mutex] waiting for lock held by <pid>`; subsequent tick will pick up |
| Sibling project tripped breaker | per-project `.consecutive-failures` ≥ 3 | only that slug's `state.local.json` flips paused; other slugs unaffected |
| Linear rename after install | `.project.name` drifts from frozen slug | non-fatal warning in tick log; rename procedure documented |

## 9. Open questions / followups (out of v1 scope, filed as separate ENG)

- Per-project `learned-rules/<slug>/` (§5.5).
- macOS Keychain for `LINEAR_API_KEY` and the GitHub App private key.
- `setup.sh --non-interactive` for automation.
- GitHub App manifest auto-create flow (one-click create-and-install).
- `status.sh --all` cross-project dashboard.

---

## 10. Linear issue body (drop-in)

### Title
Multi-project harness — single install, N target repos

### Type
feature

### Problem Statement
Today the harness is rigorously single-target: `TARGET_REPO` is one path,
`HARNESS_STATE_DIR` is one global namespace, and the launchd plists hardcode
one repo at install time. Driving a second project from the same Mac requires
either uninstall + reinstall or two fully separate harness clones. Issue IDs
(e.g. `ENG-5`) collide across projects in the shared state dir, the single
breaker counter pauses healthy projects when a flaky one trips it, and there
is no mechanism for "list all projects this harness is running."

Onboarding a project today is also a manual checklist scattered across README,
commit messages, and tribal knowledge — Linear API key, two Linear UUIDs,
fifteen labels, GitHub App creation/install, three GH env vars, a `gh auth
login`, an optional Slack webhook, several config defaults, and only then the
launchd install. Easy to get the order wrong and end up debugging confusing
failures.

### Desired Outcome
1. A single `bin/setup.sh /path/to/target` walks a fresh project through every
   onboarding step idempotently. Re-runnable without destroying state.
2. The harness can drive N independent target repos concurrently from one
   install. Each project gets its own launchd pair (`com.twinning.pipeline.<slug>`,
   `com.twinning.retrospective.<slug>`), its own state directory, its own
   breaker, lock, metrics, and logs.
3. Project identity (`project.slug`) is derived once from
   `linear-ids.json::.project.name` and frozen in `config.json`. Linear renames
   are silent.
4. Shared user credentials (Linear API key, GitHub App private key, Slack
   webhook) live once at `${XDG_CONFIG_HOME:-~/.config}/twinning-harness/` and
   are sourced by every project's tick.
5. A single global mutex serializes `claude -p` calls across projects so the
   subscription session isn't pummeled by concurrent headless agents.

### Scope Boundaries

**IN:**
- `bin/setup.sh` with the eleven phases listed in the spec.
- `bin/install-launchd.sh` and `bin/uninstall-launchd.sh` slug-aware.
- `bin/common.sh` derives `PROJECT_SLUG`, `PROJECT_STATE_DIR`,
  `HARNESS_CONFIG_DIR`.
- `run-local.sh` per-project paths + claude mutex wrapper.
- One-time migration phase for the existing single-project install.
- Tests: setup, install-launchd, mutex; existing tests namespaced under a
  fixture slug.

**OUT (filed as separate ENG):**
- Per-project `learned-rules/<slug>/`.
- macOS Keychain integration.
- `setup.sh --non-interactive`.
- GitHub App manifest auto-create.
- Cross-project status dashboard.

### Acceptance Criteria
1. On a fresh checkout, `bash bin/setup.sh /path/to/target-A` walks all eleven
   phases interactively and produces a working install (a tick succeeds).
2. Running `bash bin/setup.sh /path/to/target-A` again is a no-op
   (every phase reports "already satisfied").
3. Running `bash bin/setup.sh /path/to/target-B` with a different
   `linear.project_id` derives a different slug, never touches target-A's
   state, and produces a second working install.
4. With both A and B installed, `launchctl list | grep com.twinning` shows
   four labels (two per project). Tripping A's breaker leaves B running.
5. Running A's and B's ticks at overlapping wall-clock times serializes the
   `claude -p` subprocess via `.claude-mutex.lock/`; non-claude work runs in
   parallel.
6. `bash bin/uninstall-launchd.sh /path/to/target-A` removes only A's two
   plists and leaves B intact.
7. `bash bin/setup.sh /path/to/twinning slug-freeze` followed by
   `migrate-state` cleanly upgrades the existing single-project install with
   no lost ENG-N dirs, breaker counter, or metrics history.
8. All existing `bin/*-test.sh` tests pass after the namespacing pass.
9. New tests: `setup-test.sh`, `install-launchd-test.sh`, `mutex-test.sh` all
   pass.

### Technical Hints
- See `docs/superpowers/specs/2026-04-26-multi-project-harness-design.md` for
  the full design.
- Slug freeze location is `config.json::project.slug`; collision sentinel is
  `$HARNESS_STATE_DIR/<slug>/target-repo` (plain text).
- XDG conventions: shared config at `${XDG_CONFIG_HOME:-~/.config}/twinning-harness/`,
  state at `${XDG_STATE_HOME:-~/.local/state}/twinning-harness/<slug>/`.
- `common.sh` is the choke point for path namespacing — most call sites adapt
  by referencing `$PROJECT_STATE_DIR` instead of `$HARNESS_STATE_DIR/<issue>`.

### Related Issues / Context
- ENG-23 (env-var refactor) established `HARNESS_ROOT` / `TARGET_REPO` /
  `HARNESS_STATE_DIR`; this builds on that boundary.
- The `linear.sh refresh-cache` work that lifts `project.name` from Linear
  metadata is the prerequisite for slug derivation.

### Priority Rationale
Blocks adopting the harness on a second target repo (the harness's own
development loop, plus any second target the operator wants to drive). Without
this, the operator runs two separate Mac users or maintains parallel harness
clones — both fragile.
