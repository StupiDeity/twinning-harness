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

`launchd` hands the harness a minimal PATH via the plist's
`EnvironmentVariables/PATH` block. The template at
`launchd/com.twinning.pipeline.plist.template` injects
`/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin`
under the `<key>PATH</key>` entry — system defaults plus Homebrew dirs
(Apple Silicon and Intel), no `$HOME` segments.

The `export PATH=…` line in `bin/run-local.sh` belt-and-braces the
plist's PATH with additional segments for stack-specific user-global
bins (`$HOME/.bun/bin`, `$HOME/.npm-global/bin`) that the *dispatched
agent* may need on Bun- or npm-using targets. This is harmless on
hosts where those directories are absent — the shell ignores missing
PATH segments.

| Segment | Consumer | Notes |
|---|---|---|
| `/opt/homebrew/bin`, `/opt/homebrew/sbin` | harness's own tools | Apple Silicon Homebrew. Plist injects `bin`; `run-local.sh` adds `sbin`. |
| `/usr/local/bin`, `/usr/local/sbin` | harness's own tools | Intel Homebrew (or `/usr/local`-style installs). Plist injects `bin`; `run-local.sh` adds `sbin`. |
| `$HOME/.bun/bin` | dispatched agent's stack tools | Bun user-global bin. Only consumed on Bun-using targets (e.g. twinning's `bun tauri build`). |
| `$HOME/.npm-global/bin` | dispatched agent's stack tools | npm user-global bin (`npm install -g …`). Only consumed on npm-using targets. |
| `/usr/bin`, `/bin`, `/usr/sbin`, `/sbin` | system | Plist's tail. |

Tools the **harness itself** uses (`gtimeout`, `gh`, `claude`, `jq`,
`awk`, `sed`, `git`, `curl`) are assumed to be reachable via the
Homebrew / system segments above. Operators on non-Homebrew installs
(MacPorts, Nix) must edit the rendered plist's
`EnvironmentVariables/PATH` after `bin/install-launchd.sh` runs and
re-`launchctl bootstrap`. Targets that need additional user-global bin
dirs (`~/.cargo/bin`, `~/go/bin`, etc.) currently require a manual plist
edit; a profile-derived PATH mechanism is a deferred followup.

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

- **Every new ticket carries a type label at creation time.** Exactly one of
  `Bug` / `Feature` / `Improvement` MUST be set when the issue is filed. Mapping
  to branch shape (per `bin/branch-name.sh:26-29`):
  - `Bug` → `fix/<eng-n>-<slug>`
  - `Feature` / `Improvement` → `feat/<eng-n>-<slug>`

  This is **load-bearing, not cosmetic**. `branch-name.sh` re-evaluates the
  `Bug` label on every call (worktree creation, render-prompt, the orchestrator's
  `apply_transition` PR-create hook in `bin/verdict-handler.sh:206`). Adding or
  removing `Bug` after the worktree is created causes branch-shape drift: the
  pushed branch has the old prefix, but `branch-name.sh` returns the new one,
  and the PR-create hook silently fails with `gh pr create --head fix/...`
  against an unpushed branch (its `|| log` swallows the failure — see ENG-86,
  May 2026). If unsure which label fits when filing, ASK before creating;
  do not file the ticket unlabelled and "decide later."

- **Mutate labels additively on existing issues.** Use `bash bin/linear.sh add-label <ENG-N> <label>`
  and `remove-label`. Never use the Linear MCP `save_issue` to update an existing issue,
  and never use it to mutate labels by any path — that call overwrites the entire label
  set and will silently drop `stage:*` / `pipeline:*` labels that the orchestrator is
  mid-flight on. **Creating a new issue with `save_issue` is allowed and is the
  expected path** (there is no prior label set to overwrite); set the type label
  (`Bug` / `Feature` / `Improvement`) and any other initial labels in the create call's
  `labels` field per the convention above. Once the issue exists, all subsequent label
  changes go through `bin/linear.sh add-label` / `remove-label`.
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

`issue-state.json` is the durable state for the skip-label dance OR retry tracking —
`poll.sh` reads it on every tick and includes/excludes the issue based on `policy`
plus a recomputed `pipeline_content_hash` (sha256 over `bin/**`, `config.json`,
`AGENT_PROMPTS.md`) and branch-head SHA.

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

The `implementing | ui | qa` allowlist is derived from
`learned-rules/$PROJECT_SLUG/project-profile.md`'s `## File layout`
section, plus a stack-agnostic catalog of `docs/` and common
manifest+lockfile filenames (`Cargo.lock`, `package-lock.json`,
`poetry.lock`, `go.sum`, etc. — see `_always_include_paths` in
`bin/run-local-helpers.sh`). The hardcoded Tauri shape (`src-tauri/`,
`crates/`, `bun.lock*`) was removed in ENG-95.

**Where to make scope changes (decision tree):**

| Change shape | Edit | Notes |
|---|---|---|
| Permanent stack-shape change (new top-level dir like `app/`, `pkg/`) | `learned-rules/<slug>/project-profile.md::"## File layout"` | The profile is the canonical source of stack truth. Re-run `bash bin/setup.sh project-profile` to regenerate, or hand-edit. Visible to every dispatched agent's prompt AND the sweep allowlist. |
| Per-target one-off (test-specific path, experimental dir) | `config.json::scope.allowlist.<stage>[]` | Overrides the profile-derived list completely for that stage; useful for granting scope without polluting the canonical profile. **This config is gitignored** — operator-local. |
| Common lockfile catalog (e.g. add `bun.lockb` for a new package manager) | `_always_include_paths` in `bin/run-local-helpers.sh` | Hardcoded list; PR to the harness repo. Universal across slugs. |

**Migration from pre-ENG-95 (existing Tauri targets):** Existing profiles
that list the Tauri directories (`src/`, `src-tauri/`, `crates/`, `tests/`)
in their `## File layout` section work unchanged. The new implementation
reads your profile instead of a hardcoded list — same result. If your
profile is missing entries, scope falls back to `docs/ + lockfile catalog`
only and the agent self-leaks on the next source-dir write; the operator
sees a diagnostic in `$PROJECT_STATE_DIR/<slug>/logs/local-*.log`:

    stage_output_paths: profile-derived list empty for stage=implementing
    (slug=<slug>, path=<...>); falling back to docs/ + lockfile catalog.
    Run: bash bin/setup.sh project-profile

**Always-include lockfile catalog scope.** The always-include set grants
in-scope status for ALL common manifest+lockfile filenames
(`Cargo.toml/lock`, `package.json/-lock.json`, `bun.lock/lockb`,
`pyproject.toml + poetry.lock/uv.lock/Pipfile.lock`, `go.mod/sum`,
`Gemfile/.lock`), regardless of whether your target uses that stack.
This is intentional — false-positive scope is bounded to top-level
single-file matches, never a directory prefix. If this is too broad for
your repo, set `config.json::scope.allowlist.<stage>[]` to a tighter list.

**ENG-96 — profile-driven `is_benign` lockfile set.** `bin/scope-check.sh::is_benign`
no longer hardcodes `Cargo.lock`; the lockfile basenames it auto-allows
are inferred per dispatch from
`learned-rules/$PROJECT_SLUG/project-profile.md`'s
`## Build & test gates` section (e.g. profile naming `poetry` →
`poetry.lock` is benign). Helper: `_profile_lockfile_basenames`
(token table at `_lockfile_for_pm`). To add a new stack: one case-arm
edit + one token in `_profile_lockfile_basenames`'s `for pm in ...`
loop. The `$SCOPE_CHECK_PROFILE_PATH` env-var override is **test-only**
— production callers must not set it. Missing profile / unknown PM
tokens degrade gracefully to "path-classes-only benign" with a `log`
warning, **strictly more restrictive** than today's hardcoded Cargo
carve-out on non-Rust stacks.

**Sanctioned agent scratch dir (`.scratch/`) — gated to allowlisted
stages.** For `implementing | ui | qa`, agents may need throwaway
fixtures alongside legitimate in-scope writes. `.scratch/` is the
carve-out:

- `partition_dirty_paths` (`bin/run-local-helpers.sh`) treats `.scratch/*`
  as invisible **only on `implementing | ui | qa`** — neither in-scope
  nor leaked nor observed.
- `is_benign` (`bin/scope-check.sh`) mirrors this for the agent-side
  scope-check inside the implementing stage's flow.
- `.scratch/` is in the repo's `.gitignore`, so even if an agent
  `git add`s the directory it never reaches a commit.

**On `brainstorming | planning`** the carve-out does NOT apply — those
stages have a tight `docs/{brainstorms,plans}/` allowlist and D-004
issue-id constraint. Letting them silently drop `.scratch/*` would
create a cross-dispatch state-injection vector (planted file readable
by later-stage agents via `Read`). Brainstorm/plan `.scratch/*` writes
flow through to out-of-scope and self-leak halt.

The trailing slash is load-bearing in both case globs (`.scratch/*`), so
a top-level file literally named `.scratchpad` is NOT carved out — only
paths under the directory.

**Read-mostly stages auto-clean self-leak residue, never halt on it.**
For `reviewing | building | released`, `stage_output_paths` returns
empty *by design* — the contract is "no worktree writes." Stage
summaries go to `$(issue_dir)/stage-summary-<stage>.md` (outside the
worktree), Linear comments go via `bin/linear.sh`, gh/git operations
target origin or sibling state dirs. There is no legitimate in-worktree
write.

The single source of truth for "stage is read-mostly" lives in
`stage_is_read_mostly` (`bin/run-local-helpers.sh`), which is just
`[[ -z "$(stage_output_paths "$stage")" ]]` — no duplicate stage list
to drift. A future stage added with empty `stage_output_paths` is
automatically picked up.

Intervention point is **inside the self-leak handler** in
`bin/run-local.sh`, *after* `partition_dirty_paths` has already done
the snapshot-based observed-vs-self-leak classification. The partition
guarantees `self_leak_paths` is by construction the set of paths NEW
since tick-start — operator's pre-existing 'observed' edits are NEVER
in that list and are therefore NEVER touched by the clean. This is
the C1 correctness invariant from the cold-pass review.

`clean_self_leak_residue` (`bin/run-local-helpers.sh`) per-path:
- Tracked-modified (`git ls-files --error-unmatch` succeeds):
  `git checkout -- <path>` reverts to index.
- Untracked (anything else): `rm -rf "$worktree/<path>"`.

Emits `sweep-readonly-residue-cleaned` with the full audit payload —
event, issue, stage, outcome, exit-code, then notes that include
`count=N branch=<b> hashes=<sha12-csv> rm_fail=N checkout_fail=N`.
The sha12 list is the forensic reconstruction surface the
retrospective consumes; path strings themselves never reach Linear
comments (matches `halt_issue_for_self_leak`'s adversarial-filename
discipline).

Result: the harness advances autonomously through reviewing → qa →
building → released even when those agents drop verification residue.
Eliminates the ENG-96-shape operator-touch halt (reviewer left
`.scratch/bte_*.md` + root-level `tmp-awk-dup-test.md` to verify a
parser, sweep self-leaked, operator had to manually `decide --action
continue` to recover).

Defensive guards: empty path list → no-op (no metric); missing
worktree → no-op + warn; main/master/empty branch → defensive refuse
+ warn; dry-run mode logs without mutating; per-path failures are
non-blocking and surface in the metric's `rm_fail` / `checkout_fail`
counters.

`implementing | ui | qa` are NOT affected — their allowlists are real
signal, self-leak halts there remain the correct policy (operator
must inspect; an agent that wrote source files to wrong paths is
real evidence of a bug).

## Per-target dispatch.tools extras and profile-derived tools (ENG-51, ENG-53 #8, ENG-94)

`dispatch.sh::allowed_tools_for` ships a stack-neutral base allowlist for each stage. Per-target
stack tools (`cargo` for Tauri, `pytest` for Python, `go test` for Go, etc.) flow from the
project profile's `## Tool allowlist` section (`learned-rules/<slug>/project-profile.md`,
schema_version 2; ENG-94). Operator-curated extras (e.g., the harness-self target's
per-test-script enumeration for `bin/*-test.sh`) still come from the target's
`.pipeline-config/config.json::dispatch.tools.<stage>[]` (ENG-51).

The per-stage `--allowed-tools` argv is composed in left-to-right order:
**base** (the stage's hardcoded case arm — Read/Write/Edit/Grep/Glob, git family, dual-path
linear/pipeline/etc. wrappers) → **profile** (auto-discovered from the slug's project profile
by `_dispatch_tools_from_profile`) → **extras** (operator-curated, ENG-51). Empty segments
are elided so no stray commas leak into the argv. Claude's allowlist matcher is order-
insensitive, so the ordering is for log-readability and reasoning clarity, not behavioral
correctness.

**Fallback contract.** If the profile is missing, has `schema_version != 2`, or lacks the
`## Tool allowlist` section, `_dispatch_tools_from_profile` returns empty and emits a single
`[allowed-tools]` warning to stderr. The composition collapses to `base + extras`; dispatch
does NOT die (AC#3). The warning lands in `$PROJECT_STATE_DIR/<ident>/logs/<stage>-*.log`
per ENG-94 OQ-3. Operator runbook entry for the T1 + ENG-94 rollout coordination is tracked
as ENG-94 OQ-6 (future work).

**Wildcard pitfall.** Claude's `--allowed-tools` matcher does NOT expand `*` inside a
`Bash(<prefix>:*)` prefix as a shell glob — the `*` is treated literally. So
`Bash(bash bin/*-test.sh:*)` matches *only* the literal string `bash bin/*-test.sh ...`,
not any actual test script. Patterns must enumerate each script with a fully-literal prefix:

```json
{
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
}
```

Stage keys are the gerund form (`implementing`, `qa`) — they must match
`dispatch.sh::allowed_tools_for`'s case-arm names. The entries are appended to the
per-stage hardcoded base. `.pipeline-config/` is gitignored, so each operator applies this
on their own copy. For the harness-self target specifically (the one driving this repo),
this is required: without it, the implement and qa agents have no allowlisted way to
invoke `bash bin/<name>-test.sh` and ship without running tests (the failure mode that
drove ENG-53; the wildcard incarnation drove ENG-77's QA halt cascade in May 2026).

Regenerate the list whenever a new `bin/*-test.sh` is added:

```bash
TESTS=$(ls bin/*-test.sh | sort | sed 's|^|Bash(bash |; s|$|:*)|')
LIST=$(printf '%s\n' \
  "Bash(bash .githooks/pre-commit:*)" \
  "Bash(bash bin/secret-probe-lint.sh:*)" \
  "$TESTS" | jq -R . | jq -s .)
jq --argjson l "$LIST" '.dispatch.tools = {"implementing": $l, "qa": $l}' \
  .pipeline-config/config.json > /tmp/c && mv /tmp/c .pipeline-config/config.json
```

`bin/dispatch-test.sh` asserts (a) no broken wildcard `Bash(bash bin/*-test.sh:*)` is
present, and (b) the enumerated count covers every `bin/*-test.sh` on disk — catches
drift when a new test is added but not allowlisted (skipped silently when
`.pipeline-config/config.json` is absent — CI or non-harness operators). The wildcard
pitfall and the regeneration guidance apply symmetrically to the profile's `## Tool allowlist`
section: discovery-emitted patterns must enumerate each script literally (no `Bash(bash
bin/*-test.sh:*)` shape).

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

## Orchestrator entry-conditions (ENG-86)

`bin/run-stage.sh::_entry_conditions_gate` is a config-driven pre-dispatch
gate that runs after `_pre_dispatch_merge_gate` and before render-prompt +
agent dispatch. It shells out to `bin/entry-conditions.sh::should_dispatch`,
which reads a per-stage check list from
`.pipeline-config/config.json::orchestrator.entry_conditions[<stage>]`, runs
each named check in declaration order, AND-gates the results, and prints
exactly one of `proceed`, `skip:<reason>`, or `error:<check-name>` on stdout.

Phase 1 ships exactly one check, `pr-approved-by-non-bot`, mirroring the
agent-side P2 at `AGENT_PROMPTS.md:1287-1289`. The orchestrator skips the
build-agent dispatch entirely (~100 ms vs ~2 min) when the PR has zero
non-bot APPROVED reviews — saving ~$0.5–0.7 per tick and freeing the
ENG-81 K=2 slot for other ready work. New checks land in
`_entry_check_handler_for` without schema migration.

```json
{
  "orchestrator": {
    "entry_conditions": {
      "building": [
        {
          "name": "pr-approved-by-non-bot",
          "type": "github-pr-review"
        }
      ]
    }
  }
}
```

Validation:
- Each entry's `name` MUST resolve in `_entry_check_handler_for`. An
  unknown name is logged via `log` and the entry is skipped (treated as
  a no-op, NOT a hard error) so a typo cannot lock the orchestrator out
  of dispatching forever.
- Empty/null/absent `entry_conditions` → `proceed` (back-compat — the
  pre-ENG-86 dispatch path is unchanged).
- Stage keys are gerund form (`building`, `implementing`, …). An
  unknown key (e.g. `build` missing `-ing`) silently falls through —
  `// []` returns the empty array, so `should_dispatch` prints
  `proceed`. Same trade-off as ENG-65 per-stage timeouts; no warning
  is emitted.
- On skip, the gate calls `_handle_wait` so the ENG-45
  `external_signal_budget` escalation still applies — a buggy predicate
  halts the issue within `max_attempts` ticks rather than spinning
  forever.
- On `gh`/`jq` outage, the check returns rc=2 and `should_dispatch`
  prints `error:<check-name>`; the orchestrator falls through to
  dispatch (D-010 fail-open). The agent's P2 (unchanged) is the
  defense-in-depth fallback when the orchestrator gate cannot
  evaluate.

The skip path emits paired `stage-start` + `stage-end` metric events
with outcome `dispatch-skipped` (mirrors the `merged-pre-dispatch`
pairing template), so the retrospective's §1 event-pairing pass does
not see an orphaned terminal event.

`.pipeline-config/` is gitignored — each operator opts in
independently. For the harness-self target, regenerate the local
`.pipeline-config/config.json` with the stanza above (the
`## Per-target dispatch.tools extras` section's regen one-liner already
covers the test-list enumeration; the `entry_conditions` stanza is a
one-time manual add). Operator visibility is via the per-stage
transcript (the `entry-conditions: skip` log line) and
`$PROJECT_STATE_DIR/<ident>/wait-building.json`'s `attempts` field — NOT
via Linear comments (D-003 trade-off: cost-recovery vs Linear-thread
silence).

## Cross-dispatch staleness contract (ENG-87)

Six prior tickets (ENG-77, ENG-41 §1.1+§1.2, ENG-78, ENG-79, ENG-67)
each manifested the same structural failure: a fresh dispatch's reader
treats data written by a PRIOR dispatch as if it were current. Each
prior fix patched one medium (per-issue file, Linear comment freshness,
Linear label, prompt token, worktree path) with that medium's natural
primitive. ENG-87 ships a unified hard hand-off contract.

**Glue: `PIPELINE_DISPATCH_ID`.** Allocated by `bin/run-stage.sh::main`
once per dispatch via `bin/common.sh::allocate_dispatch_id`. Format:
`ENG-N-d<NNNN>` (4-digit zero-padded; monotonic per issue). Persisted
in `$PROJECT_STATE_DIR/<ident>/issue-state.json::current_dispatch_id`
+ `current_dispatch_seq`. Exported as `PIPELINE_DISPATCH_ID` and
inherited by `bin/dispatch.sh`'s `env`-block subshell, the agent's
`bash bin/linear.sh` calls, and the orchestrator's post-dispatch
envelope validator. The reader-side helper `current_dispatch_id <issue>`
returns the persisted id (or empty string if unallocated, e.g. legacy
pre-cutover issues).

**Per-medium primitives.** Each cheapest for its medium:

| Medium | Primitive | Site |
|---|---|---|
| Per-issue local files | clear-on-dispatch-start | `bin/run-stage.sh::_clear_current_stage_slots` (current-stage `stage-summary-*.md` + `wait-*.json`; OTHER stages preserved for loopback reads) |
| Linear comments | auto-inject `<!-- meta: dispatch id=… stage=… -->` at chokepoint | `bin/linear.sh::_inject_dispatch_marker` (idempotent; skipped when env unset → operator-manual lane) |
| Linear labels | lane fence | `bin/linear.sh::_check_lane` (ENG-41 — already shipped) |
| Prompt tokens | resolver registry + render-time validator | `bin/render-prompt.sh::PROMPT_RESOLVERS` (twelve resolvers; unknown `{token}` dies loud) |

**Reader-side filters.** `bin/verdict-handler.sh::find_fresh_verdict`
prefers a `dispatch_id`-equality match over the timestamp window when
ANY comment on the issue carries a `meta: dispatch id=` marker.
`bin/verdict-handler.sh::resume_in_progress_transition` rejects a
`pipeline: transition` whose `meta: dispatch id=` disagrees with the
current dispatch id. **Soft-fallback (D-005):** legacy issues with no
markers anywhere fall through to the existing timestamp-window /
labels-cross-check code (preserves ENG-41 §4.2's guard); the fallback
expires the first time the orchestrator dispatches the issue
post-cutover (the dispatch's auto-injection puts a marker on the next
comment, and subsequent ticks take the strict id-match path).

**Detective backstop.** `bin/run-stage.sh::_validate_dispatch_envelope`
runs after the rc=25 agent-contract validator and before
`post_completion_comment`. It scans the per-stage transcript sidecar
(`$(issue_dir)/.envelope-transcript-<stage>`) for invocations matching
`mcp__plugin_linear` (Linear MCP forks) or `curl https://api.linear.app`
(direct Linear HTTP). On any match: emits
`<!-- pipeline: verdict result=halt reason=dispatch-envelope-violation -->`
via `bin/pipeline.sh event` and exits 29. The validator is fail-open
on a missing sidecar (detective-only; not a primary defense). Halt
reason `dispatch-envelope-violation` (registered in
`bin/pipeline-events.json::halt_reasons`) and exit code 29
(`envelope-violation` in `failure_outcome_for_exit`).

**`dispatch_history.jsonl`.** New per-issue append-only forensic log
at `$(issue_dir)/dispatch_history.jsonl`. Two rows per dispatch
(start + end). NEVER cleared; never read at runtime by decision-making
code. Consumed by retrospective + manual triage; surfacing in
`bin/status.sh` is a separate ticket. **Accepted YAGNI cost.** The
~95 LOC writer + 8 module globals + idempotency sentinel ship without
a runtime consumer (the retrospective is the first reader, and that
ticket is open as ENG-92). Trade-off: paying the maintenance cost now
to capture forensic data starting at iter-1 of the contract avoids
having to back-fill missing `dispatch_id`-stamped history rows the
moment a real incident lands. Reviewers should NOT trim the writer
absent a separate decision to defer the forensic capture surface.

**Recovery.** `bash bin/pipeline.sh decide ENG-N --action continue`
(see "Failure-mode quick reference" §) clears the halt label and
re-allocates a fresh `dispatch_id` on the next tick. The transcript
sidecar at `$(issue_dir)/.envelope-transcript-<stage>` is preserved
across the halt for forensic review and removed by the next dispatch's
pre-clean at `bin/dispatch.sh::_render_and_capture_stream` (line 83).
The `dispatch_history.jsonl` audit log carries the halted dispatch's
start+end rows past the resume.

**Forensic asymmetry post-resume.** After `--action continue` allocates
a fresh `dispatch_id` (e.g. d0008 supersedes d0007), the strict
id-match path in `find_fresh_verdict` filters the d0007 halt comment
OUT — its `meta: dispatch id=d0007` marker mismatches the current d0008.
The issue resumes correctly (the next dispatch's verdict is auto-
injected with d0008 and surfaces normally), but operator-triage tools
that read verdict history (`bin/status.sh`, manual `find_fresh_verdict`
grep) will see "no fresh verdict" between the resume and the next
dispatch's first verdict. Inspect prior halts directly via
`bin/linear.sh get-comments` + a `verdict result=halt` filter; the
`dispatch_history.jsonl` audit log is also intact across resume.
Trade-off accepted (D-005): forensic regression is the cost of strict
id-match; loosening to accept "previous-dispatch-id" halts as visible-
but-superseded would re-introduce the V3 vulnerability the strict path
prevents.

**Operator gotchas.** A dispatch that crashes mid-flight between
`allocate_dispatch_id` and `_clear_current_stage_slots` leaves a
`dispatch_history.jsonl` start row without an end row; the next tick's
allocator increments past it monotonically. The clear-on-start fires
unconditionally on every fresh dispatch, so a stale `stage-summary-*.md`
or `wait-*.json` from the crashed dispatch is gone before the agent
starts. The chained-command blind spot in `assert_no_tool_invocation`
(documented at `bin/run-stage.sh:867-881` and `A-020` in the plan)
applies to the envelope validator too — `bash bin/linear.sh add-comment …; mcp__plugin_linear …`
inside a single `tool_use.input.command` string evades the startswith
prefix match. AGENT_PROMPTS.md preamble's "Dispatch identifier and
freshness contract" subsection is the prompt-side defense for that gap.

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
| Per-issue halt (self-leak / leaked-in-scope at threshold / N×same-issue failure) | Linear comments under sig `halt/<stage>/<issue>` (verdict `result=halt reason=agent-blocked`); `pipeline:halted` + `pipeline:skip-until-human-acts` labels; `$(issue_dir <issue>)/.consecutive-failures` carries the per-issue count. Other issues continue to be polled — do NOT touch `orchestrator.paused`. **One-command recovery:** `bash bin/pipeline.sh decide <ENG-N> --action continue` (clears halt label, skip labels, per-issue counter, issue-state, posts operator-resume waypoint). **NOTE:** self-leak halts only fire on `implementing | ui | qa`. On `reviewing | building | released`, `clean_self_leak_residue` auto-cleans the residue and the tick advances without halting (see "Sweep + scope partition" section). If you expected a halt on those stages and didn't see one, that's working as designed; check the `sweep-readonly-residue-cleaned` metric for what was cleaned. |
| Global breaker (infrastructure outage) | `$PROJECT_STATE_DIR/.consecutive-failures` ≥ 3 from `rc=24` (`linear-post-failed`) accumulated across ticks; `orchestrator.paused=true` in `STATE_FILE` or `CONFIG`. Resolve with `set_orchestrator_paused false` (or any `decide --action continue`, which also clears the breaker via `_pipeline_clear_breaker`). The next clean tick clears the global counter. |
| Issue stuck in `stage:X` | Linear comments under sigs `halt/<stage>/<issue>`, `scope-approval/<stage>/<issue>` (comment `createdAt` reflects FIRST emission only; check the `<!-- meta: reapplied at=… -->` footer for the latest re-apply moment — see `docs/runbooks/recovery.md` §4) |
| Approved/ready ticket at later stage (e.g. `stage:building` post-approval, or `stage:reviewing` post-PR-mergeable) sits idle while an earlier-stage or inbox issue dispatches each tick | Pre-ENG-91 the picker walked Pass 4 (held) → Pass 5 (inbox) → Pass 6 (wait re-pickup) sequentially and `exit 0`'d after the first dispatch — a later-stage wait_recallable could starve behind an earlier-stage held even when its recall predicate was ready. ENG-91's unified Pass 4U picker (`bin/poll.sh::_picker_build_pool`) sorts by `[-stage_index, -priority_sort_rank, fifo_ts]` and gates wait_recallable inclusion on `bin/entry-conditions.sh::should_dispatch == proceed`. Inspect `$PROJECT_STATE_DIR/<slug>/logs/local-YYYY-MM-DD.log` for `picker: wait_recallable <ENG-N> skipped (predicate not ready)` lines — that is the gate firing. If the predicate is `proceed` and the issue still loses to an earlier-stage / inbox issue, the picker sort is the bug — see ENG-91. Recovery while waiting for a fix: `bash bin/linear.sh add-label <held-issue> pipeline:paused`, let the next tick re-pick the wait, then `remove-label`. |
| Wrong-target Linear writes | `git log` on `$TARGET_REPO/.pipeline-config/schemas/linear-ids.json` — stale cache is the usual cause |
| Kill switch | `bash bin/pipeline.sh decide <ENG-N> --action continue` (atomic reset, see below) or set `orchestrator.paused=true` (takes effect next tick) |
| Brainstorm halts at iteration 2 with `iteration-exhausted` (was: resolved on iteration 3) | New ENG-65 behavior: brainstorm voluntarily halts after 2 persona-review iterations with unresolved P0 instead of starting iteration 3. Inspect `$PROJECT_STATE_DIR/<ident>/worktree/docs/brainstorms/`; resume via `--action continue` or fix the underlying P0 in the plan. Bounded worst-case spend, costs one extra operator touch on slow-converging brainstorms. |
| scope-check halts an issue with files belonging to a recent upstream merge | Pre-ENG-59 bug: scope-check diffed against the host's local `main`, which lags upstream merges until the operator runs `git pull`. Post-ENG-59 (`bin/scope-check.sh:155-…`) fetches `origin main` per run and diffs against `origin/main`. If you still see this symptom, check the per-stage transcript for `scope-check: fetch origin main failed` — fetch unreachable + no prior `refs/remotes/origin/main` falls back to local `main` (the pre-ENG-59 behaviour, preserved as a warning-emitting degraded mode). |
| Issue at `stage:building` idles with `dispatch-skipped` events and no halt label | inspect `$PROJECT_STATE_DIR/<ident>/wait-building.json`'s `attempts` field — the ENG-86 entry-conditions gate is firing skip per `gh pr view`. If the PR has been approved by a non-bot Code Owner, check whether `gh` is on PATH for launchd's environment (the stale-predicate fail-mode that the `external_signal_budget` halts after `max_attempts` ticks). If not approved, the operator's action is the underlying remedy. |

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
