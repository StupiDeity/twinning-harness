# Configuration reference

This is the deep dive for everything you can put in `config.json`,
`secrets.env`, and `.env.local`. For the README's high-level summary, see
the [Configuration section](../README.md#configuration).

## Where config lives

| Location | Scope | Holds |
|---|---|---|
| `${XDG_CONFIG_HOME:-~/.config}/twinning-harness/secrets.env` | Shared across all target repos | `LINEAR_API_KEY`, `GH_APP_ID`, `GH_APP_PRIVATE_KEY_PATH`, `PIPELINE_SLACK_WEBHOOK_URL`. `chmod 0600`. |
| `${XDG_CONFIG_HOME:-~/.config}/twinning-harness/<gh-app>.pem` | Shared | The GitHub App private key. `chmod 0600`. |
| `$TARGET_REPO/.pipeline-config/config.json` | Per target | Orchestrator behavior, dispatch overrides, allowed-tools extras. **Gitignored.** |
| `$TARGET_REPO/.pipeline-config/schemas/linear-ids.json` | Per target | Cached Linear state and label IDs. **Gitignored.** Regenerate with `bash bin/linear.sh refresh-cache`. |
| `$TARGET_REPO/.pipeline-config/.env.local` | Per target | Per-target overrides only — currently `GH_APP_INSTALLATION_ID`. **Gitignored.** |
| `$TARGET_REPO/.pipeline-config/state.local.json` | Per target | Runtime overrides for `orchestrator.paused`. Writes go here, never to `config.json`. |

`.pipeline-config/` is gitignored on purpose: each operator applies their
own config to their own copy of the target. This means **adopters must
recreate the per-target config on each fresh clone**.

## `config.json` schema

```json
{
  "project": {
    "slug": "<frozen at first setup; do not edit by hand>"
  },
  "linear": {
    "team_key": "ENG",
    "project_id": "<linear project UUID>"
  },
  "orchestrator": {
    "paused": false,
    "max_concurrent_features": 2,
    "dispatch_timeout_minutes": 30,
    "dispatch_timeout_minutes_per_stage": {
      "brainstorming": 60,
      "planning":      60
    },
    "entry_conditions": {
      "building": [
        { "name": "pr-approved-by-non-bot", "type": "github-pr-review" }
      ]
    }
  },
  "dispatch": {
    "tools": {
      "implementing": [ "Bash(...)" ],
      "qa":           [ "Bash(...)" ]
    }
  }
}
```

### `project.slug`

Frozen at first `bin/setup.sh` run. Derived from the Linear project name.
Used as the per-project namespace key for state directories and `launchd`
job labels (`com.twinning.pipeline.<slug>`). **Do not edit by hand** —
changing the slug orphans state and breaks the running `launchd` agents.
If you need to rename, use `bash bin/setup.sh <target> migrate`.

### `linear.team_key` / `linear.project_id`

Identify which Linear team and project the harness operates on. Set by
`setup.sh` Phase 3 (linear-identity). Wrong values here are the most
common cause of "wrong-target Linear writes" — see the [failure modes
table](../README.md#failure-modes-and-runbooks).

### `orchestrator.paused`

Boolean. When `true`, every tick exits without dispatching. The flag is
read from `state.local.json` if present (preferred at runtime) and falls
back to `config.json`. The global breaker writes `paused=true` here when
3 consecutive failures land. Resume with any of:

```bash
bash bin/pipeline.sh decide ENG-N --action continue   # also clears the breaker
# OR edit state.local.json:
jq '.orchestrator.paused = false' state.local.json | sponge state.local.json
```

### `orchestrator.dispatch_timeout_minutes`

Global default cap (in minutes) for every `claude -p` dispatch. The
built-in default is **30 min**, except brainstorming and planning, which
default to **60 min** in the script (see below).

This global override applies to **every stage** unless overridden by
`dispatch_timeout_minutes_per_stage`.

### `orchestrator.dispatch_timeout_minutes_per_stage` <a id="orchestratordispatch_timeout_minutes_per_stage"></a>

Per-stage override. Wins over the global. Wins over the built-in default.

```json
"dispatch_timeout_minutes_per_stage": {
  "brainstorming": 60,
  "planning":      60,
  "implementing":  45
}
```

**Validation rules:**
- Values must be **integers**. `"60"`, `"60m"`, `"1h"` all fail the
  `^[0-9]+$` regex guard and fall through to the next layer.
- A resolved value `< 1` is rejected (`gtimeout 0` means "no timeout",
  which silently disables the watchdog). The per-stage built-in default
  is restored.
- Stage keys are gerund form: `brainstorming`, `planning`, `implementing`,
  `ui`, `reviewing`, `qa`, `building`, `released`. **An unknown key fails
  silently** — `brainstorm` (missing `-ing`) falls through.

After applying an override, grep `gtimeout ... <seconds>` in the per-stage
transcript at `$PROJECT_STATE_DIR/<ident>/logs/<stage>-*.log` to confirm
it took effect.

### `orchestrator.max_concurrent_features` (ENG-81) <a id="orchestratormax_concurrent_features"></a>

Per-project cap on **simultaneous `claude -p` dispatches per tick**.
See **Dual role** below for the WIP-cap interaction.

**Default:** `2`.

**Resolution precedence** (mirrors `dispatch_timeout_minutes_per_stage`):

1. `CLAUDE_MAX_CONCURRENT` env var (set in
   `~/Library/LaunchAgents/com.twinning.pipeline.<slug>.plist`'s
   `EnvironmentVariables` block + `launchctl bootstrap`) — highest.
2. `.orchestrator.max_concurrent_features` in target's
   `.pipeline-config/config.json`.
3. Built-in default `2`.

**Validation rules:**
- Values must be **integers**. `"2"`, `"K=2"`, `"2 "` all fail the
  `^[0-9]+$` regex guard at `bin/common.sh::_resolve_K` and fall
  through to the next layer.
- A resolved value `< 1` falls through (cap=0 would disable every
  dispatch).
- Invalid values log a `_resolve_K: invalid …` warning to stderr,
  visible in `$PROJECT_STATE_DIR/logs/local-$(date -u +%Y-%m-%d).log`.

**Inspect live concurrency:**

```bash
ls $HARNESS_STATE_DIR/.claude-semaphore/slot-*/pid
bash bin/status.sh   # "Concurrent dispatches active" row
```

Each slot dir carries the owning `dispatch.sh` PID; an empty listing
means no live dispatches.

**Emergency rollback** — see
[`docs/runbooks/recovery.md`](runbooks/recovery.md#9-emergency-roll-back-concurrent-dispatches-to-k1)
for the host-wide / per-project K=1 recipe.

**Dual role.** The SAME knob is also the WIP cap on `stage:*`-labelled
issues (the pre-ENG-81 meaning, still in force). A target with
`max_concurrent_features=2` allows up to 2 issues simultaneously in
any active-development stage AND up to 2 simultaneous `claude -p`
dispatches per tick. Setting it to 1 reverts to the pre-ENG-81
behaviour for both.

For the full mechanism (counting-semaphore mkdir loop, slot reclaim,
cross-project semantics), see `CLAUDE.md` §"Per-project dispatch
concurrency".

### `orchestrator.entry_conditions` (ENG-86)

Config-driven pre-dispatch gates that run before render-prompt + agent
dispatch. Each entry is a named check; the orchestrator AND-gates results
and emits exactly one of `proceed`, `skip:<reason>`, `error:<check>`.

```json
"entry_conditions": {
  "building": [
    { "name": "pr-approved-by-non-bot", "type": "github-pr-review" }
  ]
}
```

Phase 1 ships exactly one check, `pr-approved-by-non-bot`. The
orchestrator skips the build-agent dispatch entirely (~100 ms vs ~2 min)
when the PR has zero non-bot APPROVED reviews. New checks land in
`bin/entry-conditions.sh::_entry_check_handler_for` without schema
migration.

**Validation rules:**
- Each entry's `name` MUST resolve in `_entry_check_handler_for`. Unknown
  names log via `log` and the entry is skipped (no-op, NOT a hard error)
  — a typo cannot lock the orchestrator out forever.
- Empty / null / absent → `proceed` (back-compat with pre-ENG-86).
- Stage keys: gerund form. Unknown keys fall through silently.
- On skip, `_handle_wait` runs so the ENG-45 `external_signal_budget`
  escalation still applies — a buggy predicate halts the issue within
  `max_attempts` ticks rather than spinning forever.
- On `gh` / `jq` outage, the check returns rc=2 and the orchestrator
  falls through to dispatch (D-010 fail-open). The agent's P2 (unchanged)
  is the defense-in-depth fallback.

The skip path emits paired `stage-start` + `stage-end` metric events with
outcome `dispatch-skipped`, so the retrospective's §1 event-pairing pass
sees no orphaned terminal event.

## `dispatch.tools` — per-stage allowlist extras <a id="dispatchtools--per-stage-allowlist-extras"></a>

Every `claude -p` invocation passes `--allowed-tools <comma-list>`. The
composition is
**stack-neutral base + profile-derived stack tools + operator-curated extras**:

- **stack-neutral base** — from `bin/dispatch.sh::allowed_tools_for`'s
  per-stage case arm. No language-specific tokens.
- **profile-derived stack tools** — from `learned-rules/<slug>/project-profile.md::## Tool allowlist`,
  authored by the discovery agent.
- **operator-curated extras** — from `.pipeline-config/config.json::dispatch.tools.<stage>[]`,
  for per-target one-offs that don't belong in the canonical profile.

Per-target stack tools are declared by the project profile, not
hardcoded here.

### The wildcard pitfall

Claude's `--allowed-tools` matcher does **NOT** expand `*` inside a
`Bash(<prefix>:*)` prefix as a shell glob — the `*` is treated literally.

```
Bash(bash bin/*-test.sh:*)   ← matches the literal string "bash bin/*-test.sh ..."
                                 NOT any actual test script
```

Patterns must enumerate every prefix with a fully-literal command:

```json
"dispatch": {
  "tools": {
    "implementing": [
      "Bash(bash .githooks/pre-commit:*)",
      "Bash(bash bin/secret-probe-lint.sh:*)",
      "Bash(bash bin/agent-prompts-content-test.sh:*)",
      "Bash(bash bin/classify-failure-test.sh:*)",
      "...one literal entry per bin/*-test.sh..."
    ],
    "qa": [
      "...same enumerated list..."
    ]
  }
}
```

This drove ENG-77's QA halt cascade (May 2026) and is the second-most
common cause of "agent ships without running tests."

### Regenerating the test allowlist <a id="regenerating-the-test-allowlist"></a>

When you add a new `bin/*-test.sh`, regenerate:

```bash
TESTS=$(ls bin/*-test.sh | sort | sed 's|^|Bash(bash |; s|$|:*)|')
LIST=$(printf '%s\n' \
  "Bash(bash .githooks/pre-commit:*)" \
  "Bash(bash bin/secret-probe-lint.sh:*)" \
  "$TESTS" | jq -R . | jq -s .)
jq --argjson l "$LIST" '.dispatch.tools = {"implementing": $l, "qa": $l}' \
  .pipeline-config/config.json > /tmp/c && mv /tmp/c .pipeline-config/config.json
```

`bin/dispatch-test.sh` asserts (a) no broken wildcard `Bash(bash bin/*-test.sh:*)`
is present, and (b) the enumerated count covers every `bin/*-test.sh` on disk.

### Stage keys and base lists

Stage keys are gerund form (matching `dispatch.sh::allowed_tools_for`'s case-arm names):

| Stage | Built-in tools (abbreviated) |
|---|---|
| `brainstorming` | Read, Write, Edit, Grep, Glob, TaskCreate, WebFetch, `bash bin/linear.sh`, `bash bin/pipeline.sh` |
| `planning` | Read, Write, Edit, Grep, Glob, TaskCreate, `git log/diff`, linear/pipeline scripts |
| `implementing` | Read, Write, Edit, Grep, Glob, TaskCreate, full git family, `jq`, `awk`, linear/pipeline scripts. Stack tools come from `learned-rules/<slug>/project-profile.md::## Tool allowlist`. |
| `ui` | Implementing's stack-neutral base + `Agent`. Stack tools (`npx`, `node`, etc.) come from the project profile. |
| `reviewing` | Read, Write, Grep, Glob, TaskCreate, Agent, `gh pr view/diff/list/review/comment`, `gh issue create`, linear/pipeline/guards scripts |
| `qa` | Read, Write, Edit, Grep, Glob, TaskCreate, Agent, full `git`, build tools, `gh pr/issue` family, linear/pipeline/guards scripts |
| `building` | Read, Write, Grep, Glob, `git fetch/clone/rebase`, `gh run/pr` family (`view`, `checks`, `edit`, `merge`), linear/pipeline/slack scripts |
| `released` | Read, Grep, Glob, `git log/show/rev-list/describe`, `gh release view/list`, linear/pipeline/slack/metrics scripts |

The `bash .pipeline/bin/<script>:*` and `bash bin/<script>:*` dual entries
date back to ENG-23 — both shapes are accepted for backwards-compat.

### Adding operator-curated extras

Append to `dispatch.tools.<stage>`. The entries are merged with the
stack-neutral base AND the profile-derived stack tools. The profile
is the canonical place to declare stack tools (run discovery to
populate); `dispatch.tools.<stage>` is for **operator-curated extras**
on top — typically per-test-script enumeration or per-target
one-offs. Examples:

- **Additional dev-tool patterns not declared in the profile** — for
  example, a per-target one-off `Bash(./scripts/migrate:*)` that doesn't
  belong in the canonical profile.
- **Harness self** — add the full enumerated `bin/*-test.sh` list (above).

## `secrets.env`

`KEY=VALUE` pairs at `$HARNESS_CONFIG_DIR/secrets.env`, mode `0600`:

| Key | Required | Purpose |
|---|---|---|
| `LINEAR_API_KEY` | Yes | Personal API key (Linear → Settings → API). Verified by `setup.sh` Phase 2. |
| `GH_APP_ID` | Yes (for build/release) | GitHub App numeric ID. |
| `GH_APP_PRIVATE_KEY_PATH` | Yes (for build/release) | Absolute path to the App's `.pem` private key (also under `$HARNESS_CONFIG_DIR/`, `0600`). |
| `PIPELINE_SLACK_WEBHOOK_URL` | No | Incoming webhook URL. If absent, `bin/slack.sh` no-ops. |

## Per-target `.env.local`

Currently a single key:

| Key | Purpose |
|---|---|
| `GH_APP_INSTALLATION_ID` | The installation ID for **this** target repo (each target installs the GitHub App separately, so this varies per target). |

## State runtime overrides — `state.local.json`

Runtime overrides for `orchestrator.paused`. The orchestrator reads this
in preference to `config.json` so that breaker writes don't pollute the
checked-in config:

```json
{ "orchestrator": { "paused": true } }
```

Writes go here. Reverting to `false` resumes within 5 minutes (next
tick).

## Validation

`bin/setup.sh validate` re-runs every offline check (no Linear / no
Claude API calls):

```bash
bash bin/setup.sh /path/to/target validate
```

This checks: required env vars, file permissions, `config.json`
parseability, schema cache freshness, allowed-tools shape (no broken
wildcards, test enumeration matches disk).

## Examples

### Minimal (defaults everywhere)

```json
{
  "project": { "slug": "myapp" },
  "linear":  { "team_key": "ENG", "project_id": "..." },
  "orchestrator": {}
}
```

### Tightened timeouts (cost-bound)

```json
{
  "orchestrator": {
    "dispatch_timeout_minutes": 20,
    "dispatch_timeout_minutes_per_stage": {
      "brainstorming": 45,
      "planning":      30,
      "implementing":  30
    }
  }
}
```

### Build cost-recovery enabled

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

### Constrained concurrency (single-slot)

Roll the per-project concurrent-dispatch cap back to 1 (the
pre-ENG-81 behaviour) for incident response, cost-bounding, or a
suspected race bug in an ENG-81-adjacent change. For host-wide
emergency rollback (affects every project on this Mac immediately),
use `CLAUDE_MAX_CONCURRENT=1` per
[`runbooks/recovery.md` §9](runbooks/recovery.md#9-emergency-roll-back-concurrent-dispatches-to-k1).

```json
{
  "orchestrator": {
    "max_concurrent_features": 1
  }
}
```

### Full harness-self profile

See the regen one-liner above plus:

```json
{
  "orchestrator": {
    "dispatch_timeout_minutes_per_stage": {
      "brainstorming": 60,
      "planning":      60
    },
    "entry_conditions": {
      "building": [
        { "name": "pr-approved-by-non-bot", "type": "github-pr-review" }
      ]
    }
  },
  "dispatch": {
    "tools": {
      "implementing": [ "...enumerated bin/*-test.sh list..." ],
      "qa":           [ "...enumerated bin/*-test.sh list..." ]
    }
  }
}
```
