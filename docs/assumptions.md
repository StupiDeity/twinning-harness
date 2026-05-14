# Assumptions

The harness is built on a small set of assumptions that, if violated,
break things in ways the breaker won't catch. Read this before adopting.

For the README's high-level summary, see the
[Assumptions section](../README.md#assumptions).

## Linear

### Issues enter at status `Todo`

`bin/poll.sh` only picks up issues whose Linear status is **`Todo`** AND
which carry no `stage:*` label as fresh brainstorm candidates. Issues
filed into `Backlog` (or any other state) are silently invisible to the
poller until a human transitions them to `Todo`.

**Failure mode:** "I filed an issue but nothing's happening." Check the
status — if it's `Backlog`, the harness will not see it.

### Every new issue carries a type label

Exactly one of `Bug` / `Feature` / `Improvement` MUST be set when the
issue is filed. This is **load-bearing**, not cosmetic. `bin/branch-name.sh`
re-evaluates the `Bug` label on every call to compute the branch shape:

| Label | Branch shape |
|---|---|
| `Bug` | `fix/<eng-n>-<slug>` |
| `Feature` / `Improvement` | `feat/<eng-n>-<slug>` |

**Failure mode:** Adding or removing `Bug` after the worktree is created
causes branch-shape drift — the pushed branch has the old prefix, but
`branch-name.sh` returns the new one, and the PR-create hook silently
fails with `gh pr create --head fix/...` against an unpushed branch (its
`|| log` swallows the failure). This drove ENG-86 (May 2026).

If you're unsure which label fits when filing, **ask before creating**.
Do not file unlabelled and "decide later."

### Labels are mutated additively only

Use `bash bin/linear.sh add-label <ENG-N> <label>` and `remove-label`.
**Never** reach for the Linear MCP `save_issue` from harness code or
from anything the harness invokes — that call overwrites the entire
label set and silently drops the `stage:*` / `pipeline:*` labels the
orchestrator is mid-flight on.

**Failure mode:** "The orchestrator forgot what stage this issue was in."
Cause: something called `save_issue` with a partial label list.

### Doc ownership is YAML frontmatter, not prose

`bin/reconcile.sh` greps the first 20 lines of `docs/brainstorms/*.md`
and `docs/plans/*.md` for a literal `linear: ENG-N` line; that, plus a
fallback H1 match, is what makes a doc the canonical artifact for an
issue. Doc generators and any future docs-discovery code MUST emit this
frontmatter, or reconcile will treat the doc as fuzzy / non-canonical.

```markdown
---
linear: ENG-59
title: scope-check.sh: diff against origin/main, not stale local main
---

# ...
```

### Pipeline labels owned by the harness

The pipeline-namespace labels the harness applies are:

| Label | Owner | Meaning |
|---|---|---|
| `pipeline:halted` | Harness | Issue halted at current stage; awaits operator action. |
| `pipeline:abandoned` | Harness | Issue terminal; never recalled. |
| `pipeline:rule-reviewed` | Operator | Retrospective approval gate (orthogonal to halts). |

Every other `pipeline:*` label seen in Linear is human-applied. The
legacy set (`paused`, `scope-approval-needed`, `supersede`,
`skip-until-code-changes`, `skip-until-human-acts`) is drained on every
transition.

## GitHub

### Branch naming is mechanical

Branch names are computed by `bin/branch-name.sh` from the issue's labels
and slug. Format: `<prefix>/<eng-n>-<slug>` where `<prefix>` is `fix/`
for `Bug` and `feat/` otherwise. The pushed branch and the locally-
computed branch must always match; if they drift, PR creation silently
fails.

### Code Owners drive build approval

The build agent's P2 preflight requires at least one `APPROVED` review
from a non-bot user. With branch protection + Code Owners, this becomes
"a Code Owner approved." If you don't have Code Owners configured,
**any** non-bot reviewer satisfies the gate — adopt Code Owners if you
want anything stronger.

### `gh pr merge` and worktrees collide

When the harness drives **its own** target repo (the harness-self
target), the build agent's `gh pr merge --auto --delete-branch` errors
with "main is already used by worktree" because the operator's main
checkout holds `main`. The fix: pass `--repo <owner>/<repo>` to skip
local-branch cleanup. ENG-83 added this. If you're driving any target
where the operator simultaneously holds the main branch checked out,
the same workaround applies.

## Platform

### macOS only

The runtime is `launchd`. There is no Linux / Windows port and no
portability layer. The plist templates assume macOS conventions
(`StartInterval`, `StartCalendarInterval`, `RunAtLoad`,
`KeepAlive=false`).

### Single operator, single host

A global mutex at `$HARNESS_STATE_DIR/.claude-mutex.lock/` serializes all
`claude -p` dispatches, and `bin/run-local.sh` holds a per-tick lock at
`$PROJECT_STATE_DIR/.run-local.lock/` to prevent overlapping ticks.

**This means:**
- Two operators on the same machine cannot share a harness install — they
  contend for the same locks.
- Two machines cannot share a harness state directory — there's no
  cross-host coordination.
- Cross-project ticks DO serialize correctly (the global mutex covers
  every project's dispatch).

**Failure mode:** If you sync `$XDG_STATE_HOME` across machines (e.g.
via cloud sync), you'll see corrupted lock dirs and confused state.
Don't.

### Required tooling

| Tool | Why |
|---|---|
| `bash` 4+ | Scripts use associative arrays. macOS ships 3.2 — install via Homebrew or use the `bash` from Xcode CLT. |
| `jq` | Every script uses it for Linear / config parsing. |
| `gtimeout` (`brew install coreutils`) | Per-stage dispatch timeout enforcement. |
| `gh` CLI, authenticated | Used by build/release agents and by the operator. |
| `claude` CLI, logged in | The agent. |
| `git` | Worktree dispatch. |

The harness does NOT bundle these — they're system pre-reqs.

## Auth

### Subscription Claude session, no API key

`claude -p` runs against the **logged-in subscription session** on the
host. `ANTHROPIC_API_KEY` must NOT be set — the harness deliberately
avoids burning API tokens on top of the subscription.

If the `claude` CLI session expires, all stages fail until `claude login`
is re-run. This shows up as repeated `dispatch-timeout` or
`agent-blocked` halts across multiple issues.

### GitHub credentials live as `gh auth` + GitHub App

- `gh auth` (used by setup phase 7) authenticates the operator's `gh`
  invocations.
- The GitHub App (Phase 6) is the bot's identity for PR auto-merge and
  branch-protection bypass. Its private key lives at
  `$HARNESS_CONFIG_DIR/<app-name>.pem` (mode `0600`).

The two are independent. Both must be present.

## Stack

### Per-stage allowed-tools is composed, not hardcoded

The argv composition order is
**stack-neutral base + profile-derived stack tools + operator-curated extras**:

- **Stack-neutral base** — `bin/dispatch.sh::allowed_tools_for` ships
  a stack-agnostic per-stage allowlist: Read/Write/Edit/Grep/Glob,
  the git family, `jq`, `awk`, `bash bin/linear.sh`,
  `bash bin/pipeline.sh`, etc. No language-specific tokens.
- **Profile-derived stack tools** — `learned-rules/<slug>/project-profile.md`
  carries a `## Tool allowlist` section authored by the discovery
  agent (`bash bin/setup.sh /path project-profile`, Phase 5b). The
  section is per-stage. Example for a Python target (`pyproject.toml`-shaped)
  `implementing`:

      ## Tool allowlist

      - implementing:
        - `Bash(pytest:*)`
        - `Bash(python:*)`
        - `Bash(ruff:*)`
        - `Bash(mypy:*)`
      - qa:
        - `Bash(pytest:*)`
        - `Bash(ruff:*)`
- **Operator-curated extras** — `.pipeline-config/config.json::dispatch.tools.<stage>[]`
  appends per-target one-offs (e.g. the harness-self target's
  enumerated `bin/*-test.sh` patterns) on top of the profile.

See [`configuration.md`](configuration.md#dispatchtools--per-stage-allowlist-extras)
for the full composition rules and the wildcard pitfall.

**Failure mode:** "Agent halts with permission denied invoking pytest /
go test / etc." Cause: the project profile's `## Tool allowlist`
section is missing those entries — re-run discovery
(`bash bin/setup.sh /path project-profile`) or hand-edit the profile.

### Project layout assumptions are minimal

The harness doesn't assume anything about your repo's directory
structure beyond:
- `docs/brainstorms/` and `docs/plans/` exist or are created (the
  brainstorm and plan agents write here).
- A `git` working tree at `$TARGET_REPO`.

Everything else (build commands, test commands, lint commands) is
discoverable by the agent from the target repo's own conventions
(`Cargo.toml`, `package.json`, `.github/workflows/`).

## Observability

### Comments are append-only with edit-in-place

Pipeline-authored Linear comments carry a hidden marker so repeats
edit-in-place instead of accumulating. Sigs follow `<class>/<stage>/<issue>`:

| Class | Sig |
|---|---|
| Halt / skip | `halt/<stage>/<issue>` |
| Scope approval pending | `scope-approval/<stage>/<issue>` |
| TDD evidence | `tdd-evidence/<stage>/<issue>` |
| Completion checklist | `completion/<stage>/<issue>` |
| Reconcile notice | `reconcile/<stage>/<issue>` |
| Release enrichment | `release-enrichment/<version>/<issue>` |

**Failure mode:** A comment's `createdAt` reflects FIRST emission only.
For the latest re-apply moment, check the `<!-- meta: reapplied at=… -->`
footer.

### Metrics are JSONL, append-only

`$PROJECT_STATE_DIR/metrics/events.jsonl` is the single source of truth
for the retrospective. Every tick appends `stage-start` / `stage-end`
events. Schema is implicit in the script that wrote it
(`bin/metrics.sh`).

**Don't rotate or truncate this file** — the retrospective uses the full
history. Disk pressure is the only legitimate reason to prune.
