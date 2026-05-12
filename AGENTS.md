# Repository Guidelines

## Project Structure & Module Organization

This repository is a macOS-only bash orchestration harness. Runtime scripts live in `bin/`; most executable modules have a sibling `*-test.sh` file in the same directory. Operator and design documentation lives in `docs/`, with runbooks under `docs/runbooks/` and generated/planned artifacts under `docs/brainstorms/` and `docs/plans/`. Agent prompt source is `AGENT_PROMPTS.md`; retrospective rule files are in `learned-rules/`. LaunchAgent templates are in `launchd/`. This repo does not contain target application code; scripts act on a separate `TARGET_REPO`.

## Build, Test, and Development Commands

- `bash bin/setup.sh /path/to/target`: onboard a target repo and generate local config.
- `TARGET_REPO=/path/to/target bash bin/run-local.sh`: run one orchestrator tick.
- `TARGET_REPO=/path/to/target bash bin/run-stage.sh ENG-5 brainstorming`: dispatch one stage manually.
- `PIPELINE_DRY_RUN=1 TARGET_REPO=/path/to/target bash bin/run-stage.sh ENG-5 brainstorming`: exercise dispatch paths without Linear writes, Slack, or Claude calls.
- `bash bin/status.sh`: show the dashboard; export `TARGET_REPO` first for normal use.
- `bash bin/install-git-hooks.sh`: install the pre-commit hook that runs the shell test suite.

## Coding Style & Naming Conventions

Use bash with `set -euo pipefail`, two-space indentation, lowercase function names, and explicit `local` variables. Keep shared behavior in `bin/common.sh` or focused helper scripts rather than duplicating orchestration logic. Executable scripts that may be sourced by tests must end with:

```bash
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
```

Name issue IDs as `ENG-N`. Branch shape is controlled by `bin/branch-name.sh`: bugs use `fix/<eng-n>-<slug>`, features and improvements use `feat/<eng-n>-<slug>`.

## Testing Guidelines

Tests are self-contained shell scripts named `bin/*-test.sh`; there is no central test runner beyond the git hook. Run focused tests directly, for example `bash bin/verdict-handler-test.sh` or `bash bin/scope-check-test.sh`. New tests should set mock env such as `PIPELINE_DRY_RUN=1` and `LINEAR_API_KEY=test-mock-key`, create temporary fixtures, and source the script under test after stubbing external calls.

## Commit & Pull Request Guidelines

Recent history uses concise Conventional Commit style, for example `fix(git): added .claude directory to gitignore` and `docs(CLAUDE.md): narrow save_issue prohibition to existing-issue updates`. Keep commits scoped and imperative. Pull requests should describe the harness behavior changed, link the Linear issue, list tests run, and include transcript or screenshot evidence when user-visible pipeline behavior changes.

## Security & Configuration Tips

Do not commit secrets from `.pipeline-config/`, `secrets.env`, or local state. Most commands require `TARGET_REPO`; prefer `PIPELINE_DRY_RUN=1` while validating changes that would otherwise write to Linear, GitHub, Slack, or invoke `claude -p`.
