You are profiling a software project so that downstream pipeline agents
(brainstorm, plan, implement, ui, review, qa, build, release) understand
the stack, conventions, and gates of this specific repo.

## Inputs

- TARGET_REPO: {target_repo_path}
- SLUG: {slug}
- DATE: {date}
- Output path: {learned_rules_dir}/project-profile.md

## What to do

1. Inspect the repo with Read/Glob/Grep. Look at:
   - Top-level config files (package.json, Cargo.toml, Gemfile, pyproject.toml, go.mod, build.gradle, Makefile, justfile, *.toml, *.yaml).
   - README and any docs/ directory (one paragraph each).
   - CI configuration (`.github/workflows/`, `.circleci/`, etc.) — extract canonical build/test/lint commands. CI is more authoritative than READMEs.
   - Repo shape: where source lives, where tests live, where docs live.
   - At least 3 representative source files to understand idioms.
   - Do NOT read `secrets.env`, `.env*`, `github-app.pem`, or any file under `.pipeline-config/`.

2. Write `{learned_rules_dir}/project-profile.md` following the schema below. Include the YAML frontmatter exactly as shown.

3. For any field you cannot determine with confidence, replace the value with `<<NEEDS-INPUT: one short specific question for the operator>>`.
   - Prefer marker over guessing. The operator will resolve markers interactively after you exit.
   - Marker is a single line; question is verbatim, ≤120 chars.

4. Exit. Do NOT post Linear comments. Do NOT commit. Do NOT push.

## Schema (REQUIRED — emit exactly this structure)

```markdown
---
slug: {slug}
generated_at: {date}T00:00:00Z
generated_by: discovery-agent
schema_version: 1
---

# Project profile — <project name>

## Stack

<one paragraph: language(s), runtime, framework, package manager, key external services>

## Build & test gates

- Build: `<command>` *(run from repo root; CI-equivalent)*
- Test: `<command>` *(runs the full unit suite)*
- Lint/check: `<command>` *(types, format, static analysis)*
- Integration/E2E: `<command>` *(or `(n/a) — reason`)*

## File layout

- `path/` — what lives here
- (3–8 lines, focused on where source, tests, configs live)

## Language idioms

<bulleted: naming conventions, recurring patterns, framework-specific idioms agents should mirror>

## Don'ts

<bulleted: anti-patterns, bypasses, libraries to avoid, things that have burned this codebase before>
```

## Confidence rules

- "Build & test gates": prefer commands found in CI workflows over README. If CI has none, fall back to README; if neither exists, emit a marker.
- "Don'ts": only emit findings backed by evidence (a CONTRIBUTING.md note, a CODEOWNERS warning, an obvious anti-pattern fixed in the last 50 commits via `git log --oneline -50`). Otherwise leave the section as `(none observed)` — do NOT invent don'ts.
- "File layout": list 3–8 directories; do not enumerate every dir.

## Self-twinning detection

If `{target_repo_path}` is the harness repo itself (i.e. the repo containing this discovery prompt under `bin/setup-prompts/`), the profile MUST identify the bash orchestration as the stack and gates as `bash bin/<name>-test.sh` per the harness's CLAUDE.md. Do not describe a Tauri app.
