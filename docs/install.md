# Detailed install

This is the deep walkthrough. For the quickstart, see the
[Install section](../README.md#install).

`bin/setup.sh` is the canonical entrypoint. It walks 11 idempotent
phases. You can re-run any phase any time. This doc explains what each
phase does, what credentials you need to have ready, and how to recover
when a phase rejects your input.

```bash
bash bin/setup.sh /path/to/your-target-repo            # all phases
bash bin/setup.sh /path/to/your-target-repo <phase>    # one phase only
bash bin/setup.sh /path/to/your-target-repo migrate    # special: upgrade single→multi-project
bash bin/setup.sh /path/to/your-target-repo validate   # special: re-run offline checks
```

## What you need before starting

Have these ready in browser tabs and on disk:

- **Linear**: a workspace with a project, and your personal API key
  (Settings → API → Create key).
- **GitHub**: a target repo, a separate bot user account, and admin
  access on the repo to create branch protection.
- **GitHub App** (you'll create it during setup): permissions
  `Contents=Read+Write`, `Pull requests=Read+Write`, `Issues=Read+Write`,
  `Metadata=Read`. No webhook needed.
- **Slack** (optional): an incoming webhook URL.
- **Tools installed**: `jq`, `gh`, `coreutils` (for `gtimeout`),
  `bash` 4+, `git`, the `claude` CLI logged in to a subscription.

### PATH expectations

The launchd plist injects a minimal PATH (`/opt/homebrew/bin`,
`/usr/local/bin`, and system dirs — see the `<key>PATH</key>` entry
under `EnvironmentVariables` in
`launchd/com.twinning.pipeline.plist.template`).
The `export PATH=…` line in `bin/run-local.sh` belt-and-braces
additional segments for stack-specific user-global bins
(`$HOME/.bun/bin`, `$HOME/.npm-global/bin`) that the *dispatched
agent* may need on Bun- or npm-using targets. Harmless on hosts that
lack those dirs.

Operators on non-Homebrew installs (e.g. MacPorts, Nix) should edit
the rendered plist's `EnvironmentVariables/PATH` after
`bin/install-launchd.sh` runs and re-`launchctl bootstrap` to pick up
the change. Targets that need additional user-global bin dirs
(`~/.cargo/bin`, `~/go/bin`, etc.) currently require a manual plist
edit; a profile-derived PATH mechanism is a deferred followup.

See CLAUDE.md's "PATH expectations on the launchd host" section for
the full per-segment attribution.

## Phase 1: workspace

Creates `$TARGET_REPO/.pipeline-config/{,schemas/}` and
`$HARNESS_CONFIG_DIR` (mode `0700`). Scaffolds an empty
`config.json` with `{"linear": {}, "orchestrator": {}}` if absent.

**Idempotency check:** Both directories exist and `config.json` is
present.

**Failure modes:** Permission errors on the target repo path. Check that
you have write access.

## Phase 2: linear-auth

Prompts for your Linear personal API key, verifies it with a `viewer`
GraphQL query, writes it to `$HARNESS_CONFIG_DIR/secrets.env` (mode
`0600`).

**Idempotency check:** Cached key still authenticates against Linear.
If the key has been revoked, re-running this phase prompts again.

**Failure modes:**
- Wrong key shape: must be raw, no `Bearer ` prefix.
- Network: `setup.sh` dies with `HTTP <code>` if Linear returns non-2xx.

## Phase 3: linear-identity

Lists Linear teams visible to your viewer, asks you to pick one, then
lists projects in that team and asks you to pick one (or create new).
Writes `linear.team_key`, `linear.team_id`, `linear.project_id` to
`config.json`.

**Idempotency check:** All three keys present in `config.json`.

**Failure modes:** "I picked the wrong project." Re-run this phase
explicitly: `bash bin/setup.sh /path linear-identity`. Slug is frozen at
Phase 5 — pick correctly here OR before Phase 5 runs.

## Phase 4: linear-schema

Verifies the Linear project has the labels and states the harness
needs. Reports any missing pieces. Currently checks for:

- States: `Todo`, `In Progress`, `In Review`, `Done`, `Cancelled`
- Labels (type): `Bug`, `Feature`, `Improvement`
- Labels (stage): `stage:brainstorming`, `stage:planning`,
  `stage:implementing`, `stage:ui`, `stage:reviewing`, `stage:qa`,
  `stage:building`, `stage:released`
- Labels (pipeline): `pipeline:halted`, `pipeline:abandoned`,
  `pipeline:rule-reviewed`

**Failure modes:** Missing labels — add them in Linear (Settings →
Workspace → Labels), then re-run.

After this phase succeeds, regenerate the IDs cache:

```bash
bash bin/linear.sh refresh-cache
```

## Phase 5: slug-freeze

Derives a project slug from the Linear project name (lowercase,
hyphenated, alphanum only) and writes it to `config.json::project.slug`.
This is the per-project namespace key. **Once frozen, do not edit by
hand.**

**Idempotency check:** `project.slug` present and non-empty.

**Failure modes:** "Slug is wrong." If pre-launchd, edit
`config.json::project.slug` and re-run validation. Post-launchd, run
`bash bin/setup.sh /path migrate` to relabel.

## Phase 5b: project-profile

Captures per-project profile metadata used by the dispatch tool
allowlist resolver. Sets sensible defaults for the target's stack.

## Phase 6: github-app

Walks you through creating (or re-using) a GitHub App, installing it on
the target repo, and capturing the private key. Prompts for:

1. **GitHub App ID** (numeric, from the App's settings page).
2. **Installation ID** (numeric, per-repo, from the install URL).
3. **Path to the `.pem` private key** — file is moved to
   `$HARNESS_CONFIG_DIR/github-app.pem` (mode `0600`).

Verifies by minting an installation token via
`bin/gh-app-token.sh`. Dies with a clear error if the App lacks
permissions or the Installation ID is wrong.

The GitHub App's required permissions:

| Resource | Access |
|---|---|
| Contents | Read + Write |
| Pull requests | Read + Write |
| Issues | Read + Write |
| Metadata | Read |

No webhook is required. The harness polls.

**Failure modes:**
- "App created but token mint fails": confirm the App is **installed** on
  the target repo (Phase 6's prompt #2) and the Installation ID matches.
- "Wrong App ID": Apps and Installations are different — Phase 6
  distinguishes by prompt order.

## Phase 7: gh-cli

Verifies `gh auth status` returns 0. If not, prompts you to run
`gh auth login` and re-tries.

The bot's GitHub identity (from Phase 6) is independent of `gh auth` —
the App handles PR auto-merge and branch-protection bypass; `gh auth`
handles operator-side `gh` calls.

## Phase 8: slack (optional)

Prompts for `PIPELINE_SLACK_WEBHOOK_URL`. Skip with an empty string.
When absent, `bin/slack.sh` no-ops; the harness still works fine.

## Phase 9: config-defaults

Applies sensible defaults to `config.json::orchestrator.*` and
`linear.*` sections that aren't already set. This is where the
per-stage-timeout and entry-conditions defaults land.

Phase 5b (`project-profile`) populates the per-stage Tool allowlist
for your target's stack. If you need additional operator-curated
tools on top of the profile-derived list (e.g. enumerated
`bin/*-test.sh` entries for harness-self), add them to
`dispatch.tools` per
[`configuration.md`](configuration.md#dispatchtools--per-stage-allowlist-extras).
This is not driven by setup; you edit `config.json` by hand.

## Phase 10: validate

Re-runs `bin/dry-run.sh` end-to-end with `PIPELINE_DRY_RUN=1`. Hits every
script's parse path, validates every config layer, exercises the
allowlist shape. No Linear writes, no `claude` invocations.

```bash
bash bin/setup.sh /path/to/target validate
```

Run this any time you suspect drift — after edits to `config.json`, after
adding a new `bin/*-test.sh`, after rotating credentials.

## Phase 11: playwright-install

Runs `npx playwright install chromium` so `ui`/`qa` dispatches can drive
the Playwright MCP browser toolset (ENG-27). The Chromium download is
≈30–250 MB on first run and cached afterwards; the phase is idempotent.

```bash
bash bin/setup.sh /path/to/target playwright-install
```

Skip it on targets that don't need browser verification with
`PIPELINE_SKIP_PHASES=playwright-install`.

**Failure modes:**
- "npx not on PATH": install Node.js (`brew install node`) or skip the
  phase via `PIPELINE_SKIP_PHASES=playwright-install`.
- "`npx playwright install chromium` exited non-zero": re-run after fixing
  the underlying error; the phase is idempotent.

## Phase 12: launchd

Renders `launchd/com.twinning.pipeline.plist.template` and
`launchd/com.twinning.retrospective.plist.template` into
`~/Library/LaunchAgents/com.twinning.{pipeline,retrospective}.<slug>.plist`,
substituting `__VAR__` placeholders for `$HARNESS_ROOT`, `$TARGET_REPO`,
`$HARNESS_STATE_DIR`, etc., then `launchctl bootstrap`s both.

Confirms by prompting `[Y/n]` — type `n` to defer (run
`bash bin/install-launchd.sh /path/to/target` later).

**Idempotency check:** Both `launchctl print` calls return 0.

**Failure modes:**
- "launchctl bootstrap failed": typically a stale plist from a previous
  install. Run `bash bin/uninstall-launchd.sh /path` first.
- "Process exits immediately on tick": check
  `$PROJECT_STATE_DIR/logs/launchd.err.log` — usually `gtimeout` not in
  PATH or `claude` session expired.

## Phase migrate (special)

One-shot upgrade for an existing single-project install:

```bash
bash bin/setup.sh /path/to/twinning migrate
```

Walks: slug freeze → secrets lift to `$HARNESS_CONFIG_DIR` → state-dir
relocation under `<slug>/` → learned-rules relocation → legacy launchd
bootout → slug-suffixed reinstall. **Idempotent.** Safe to re-run.

## After setup

Confirm the harness is running:

```bash
launchctl list | grep com.twinning.pipeline
# Expect: com.twinning.pipeline.<slug>  -  0  PID

bash bin/status.sh
# Expect: dashboard with current Linear state, no errors

tail -f "${XDG_STATE_HOME:-$HOME/.local/state}/twinning-harness/<slug>/logs/local-$(date -u +%Y-%m-%d).log"
# Watch the next tick fire (max wait: 5 minutes)
```

File a Linear issue — `Todo` status, exactly one of `Bug` / `Feature` /
`Improvement` — and watch it pick up.

## Multi-project layout details

A single harness checkout drives N target repos. Per-project state at:

```
${XDG_STATE_HOME:-~/.local/state}/twinning-harness/
├── .claude-semaphore/         # global counting semaphore — slot-<N>/pid each (cap from orchestrator.max_concurrent_features, default 2; ENG-81)
└── <slug-A>/                  # project A's state
    ├── .consecutive-failures
    ├── logs/
    ├── metrics/events.jsonl
    └── ENG-N/...
└── <slug-B>/...               # project B's state, fully isolated
```

Each project gets its own pair of `launchd` jobs:
- `com.twinning.pipeline.<slug>` (every 5 min)
- `com.twinning.retrospective.<slug>` (Mondays 09:00)

Cross-project ticks share the `.claude-semaphore/slot-<N>/`
counting semaphore — up to `orchestrator.max_concurrent_features`
(default 2) `claude -p` invocations may run system-wide at a time.
The retrospective scheduling is per-project, but the semaphore
covers it too.

Shared secrets live once at `$HARNESS_CONFIG_DIR/secrets.env`:
- `LINEAR_API_KEY` (one personal key works across all your Linear projects)
- `GH_APP_ID` + `GH_APP_PRIVATE_KEY_PATH` (one GitHub App can be
  installed on multiple repos)
- `PIPELINE_SLACK_WEBHOOK_URL` (one webhook, all projects)

Per-project `.env.local` only carries `GH_APP_INSTALLATION_ID` (varies
per target repo).

## Pre-commit hook

Optional but recommended:

```bash
bash bin/install-git-hooks.sh
```

Sets `core.hooksPath` to `.githooks/`. The pre-commit hook runs the full
`bin/*-test.sh` suite (~30 s) and blocks on any failure. Bypass a
single commit with `git commit --no-verify`.

A short `KNOWN_BROKEN` allowlist inside `.githooks/pre-commit` exempts
pre-existing failures from the gate (still run, surfaced as `SKIP`); fix
those and remove the entry rather than letting the list rot.

## Uninstalling

```bash
bash bin/uninstall-launchd.sh /path/to/target
```

Bootstraps both `launchd` agents out and removes the per-slug plists
from `~/Library/LaunchAgents/`. The harness checkout, target repo, and
per-project state directory are intact — remove by hand:

```bash
rm -rf "${XDG_STATE_HOME:-$HOME/.local/state}/twinning-harness/<slug>"
rm -rf /path/to/target/.pipeline-config

# Only if uninstalling the LAST target:
rm -rf "${XDG_CONFIG_HOME:-$HOME/.config}/twinning-harness"
```

To uninstall the GitHub App, do that in GitHub Settings → Applications →
Authorized GitHub Apps. Revoke the Linear personal API key in Linear
Settings → API.
