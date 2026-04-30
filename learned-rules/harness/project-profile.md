---
slug: harness
generated_at: 2026-04-29T00:00:00Z
generated_by: discovery-agent
schema_version: 1
---

# Project profile — twinning-harness

## Stack

Bash 3.2+ orchestration scripts (macOS-compatible). The repo contains no application code — it is the harness that drives an SDLC pipeline against a separate target repo. Runtime tools: `jq` (JSON), `awk`, `sed`, `gtimeout` (GNU coreutils), `git`, `gh` CLI, `claude` CLI, `curl`. Linear is reached via raw GraphQL through `bin/linear.sh`. GitHub App auth is obtained via `bin/gh-app-token.sh`. Tests are sibling shell scripts in `bin/*-test.sh`. There is no compiled artifact; the "build" is just shellcheck-style validity (`bash -n`).

## Build & test gates

- Build: `(n/a) — interpreted bash; no compile step`
- Test: `bash bin/dispatch-test.sh && bash bin/run-stage-test.sh && bash bin/poll-slot-test.sh && bash bin/scope-check-test.sh && bash bin/verdict-handler-test.sh && bash bin/classify-failure-test.sh && bash bin/halt-sprawl-test.sh && bash bin/halt-sprawl-adversarial-test.sh && bash bin/linear-test.sh && bash bin/metrics-test.sh && bash bin/mutex-test.sh && bash bin/setup-helpers-test.sh && bash bin/render-prompt-test.sh && bash bin/phase-project-profile-test.sh && bash bin/common-test.sh` *(every `bin/*-test.sh` is a self-contained executable; no test runner)*
- Lint/check: `bash -n bin/*.sh` *(syntax check only; no shellcheck in CI today)*
- Integration/E2E: `PIPELINE_DRY_RUN=1 TARGET_REPO=/path/to/target bash bin/dry-run.sh`

## File layout

- `bin/` — every orchestration script (`run-local.sh`, `run-stage.sh`, `dispatch.sh`, `poll.sh`, `verdict-handler.sh`, `classify-failure.sh`, `linear.sh`, `setup.sh`, etc.) plus their sibling `*-test.sh` files.
- `bin/setup-prompts/` — markdown prompt bodies token-interpolated by setup-time helpers (e.g. `discovery.md`).
- `learned-rules/<slug>/` — per-slug rule files appended to dispatched stage prompts; `<slug>/project-profile.md` carries stack context (this file), `<slug>/<stage>.md` carries retrospective-curated rules.
- `launchd/` — `*.plist.template` files rendered by `bin/install-launchd.sh` into `~/Library/LaunchAgents/`.
- `docs/brainstorms/` and `docs/plans/` — canonical doc locations the orchestrator's reconcile.sh treats as authoritative (frontmatter `linear: ENG-N` is the doc-to-issue ownership signal).
- `AGENT_PROMPTS.md` — nine numbered H2 sections, one per stage agent; `bin/render-prompt.sh` extracts the fenced block by section header.

## Language idioms

- Each `bin/foo.sh` ends with the sentinel `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi` so tests can `source` for function access without firing `main`.
- `set -euo pipefail` at the top of every script.
- Use `log` / `die` / `require_env` / `require_bin` from `common.sh`; don't roll your own.
- snake_case for function names; UPPER_CASE for env vars; per-stage `phase_*` and `is_*_done` follow the dynamic dispatch in `setup.sh::run_phase_or_skip`.
- All Linear writes go through `bin/linear.sh` so dry-run mode and the `pipeline-sig` dedup work uniformly.
- All metric writes go through `bin/metrics.sh` so they end up in the canonical `events.jsonl` stream.
- Per-stage allowed-tool lists are centralized in `dispatch.sh::allowed_tools_for`; new stages must add a case there or dispatch dies.
- Dispatched `claude -p` invocations carry isolation flags (`--setting-sources project,local`, `--disable-slash-commands`, `--disallowed-tools "<list>"`) plus a `gtimeout` watchdog (ENG-48).
- Tests use the source-and-stub pattern: stub helpers under `STUB_DIR`, post-source override of script-globals like `TARGET_REPO`/`SCRIPT_DIR`/`_CFS_SCRIPT_DIR`.

## Don'ts

- Never use `mcp__plugin_linear_linear__save_issue` for label changes — it overwrites the entire label set and silently strips `stage:*` / `pipeline:*` labels mid-flight. Use `bash bin/linear.sh add-label` / `remove-label`.
- Never use a column-0 ``` fence inside a stage's body in `AGENT_PROMPTS.md` — `render-prompt.sh` requires exactly two fences per stage block.
- Never rename `STAGE_TO_SECTION` keys without updating the table at the top of `render-prompt.sh`.
- Never use exit codes outside the taxonomy in `failure_outcome_for_exit` (`bin/common.sh`); a new code without a mapping routes to `unknown-exit-N` and the retrospective's §1 filter won't classify it.
- Never reference `REPO_ROOT` or `PIPELINE_ROOT` — those names were retired in ENG-23. Use `HARNESS_ROOT`, `TARGET_REPO`, `HARNESS_STATE_DIR`, `PROJECT_STATE_DIR`.
- Never read or write per-issue state via `$HARNESS_STATE_DIR/<issue>` directly — use `$PROJECT_STATE_DIR`. Cross-project shared state (the claude mutex, the project sentinel collision check) is the only legitimate use of `$HARNESS_STATE_DIR/`.
- Never write outside the per-stage allowlist in `run-local-helpers.sh::partition_dirty_paths` — the breaker classifies new untracked paths as self-leak and trips the consecutive-failures counter.
- Never let a dispatched agent write to `~/.claude/projects/.../memory/` — that's the operator's interactive auto-memory, not the agent's per-worktree context (ENG-48 surface).
