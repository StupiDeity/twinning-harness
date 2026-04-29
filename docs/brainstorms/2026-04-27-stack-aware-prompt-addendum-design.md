---
linear: ENG-TBD
title: Stack-aware prompt addendum via discovery-driven project profiles
date: 2026-04-27
status: draft
---

# Stack-aware prompt addendum

## 1. Problem

`AGENT_PROMPTS.md` ships one set of prompts hardcoded to *"Twinning, a desktop
app built with Tauri v2 + SvelteKit + Rust"* (§§ 1, 2 framing lines; §§ 3, 4
gates and idioms; §§ 5–8 oblique references like `cargo build`). Every project
the harness drives — including the harness itself when self-twinning — receives
those prompts verbatim. The result is observable in ENG-24: the implement
agent received Tauri/cargo/bun gates against a bash-only repo, refused to
invent a contract, and halted.

`render-prompt.sh::STAGE_TO_SECTION` keys only on stage. `dispatch.sh::allowed_tools_for`
keys only on stage. There is no `project.slug` branch anywhere in prompt
construction. `learned-rules/<slug>/<stage>.md` exists as a per-slug
addendum already, but it is purpose-built for retrospective-curated rules
("ENG-5 class errors") — not a place to encode static project context like
the build/test commands or file layout.

## 2. Goal

Make every stage prompt the harness dispatches stack-aware, with the stack
information sourced from a per-slug profile authored once at setup time by a
discovery agent that inspects the target repo. The base prompts in
`AGENT_PROMPTS.md` become stack-neutral; the per-slug profile is the single
source of truth for stack context.

## 3. Non-goals

- No per-stage addendum files. One profile per slug, applied to all
  non-retrospective stages.
- No machine-readable schema in v1 (no JSON/YAML for fields other than the
  required frontmatter). Profile is markdown that agents read as prose.
- No per-stack base prompt forks (no `AGENT_PROMPTS.{slug}.md`). Base prompts
  are one stack-neutral set; the profile carries all stack-specific framing.
- No automatic stack-change detection. Re-discovery is operator-triggered.
- Discovery is **not** a pipeline stage. It is a setup-time tool.

## 4. Architecture

A new setup phase `project-profile` runs a `claude -p` discovery agent against
the target repo to author `learned-rules/<slug>/project-profile.md` — a
five-section markdown file (Stack, Build & test gates, File layout, Language
idioms, Don'ts). The agent emits `<<NEEDS-INPUT: question>>` markers for any
field it cannot confidently fill; the phase loops over markers, prompts the
operator at the terminal, splices answers in. `render-prompt.sh` appends the
resolved profile to every non-retrospective stage prompt at dispatch time.
The base prompts in `AGENT_PROMPTS.md` are stripped of Twinning/Tauri specifics
so the profile is the single source of stack truth.

The profile is **load-bearing**: missing or marker-bearing profiles fail
render with a clear error, forcing the operator to (re-)run discovery. This
is intentional — without a profile, the base prompts have no stack context,
and silent fallback would re-create the ENG-24 failure mode.

The launchd-installation invariant is enforced at two points:
`phase_launchd` checks `is_project_profile_done` before invoking
`install-launchd.sh`, and `install-launchd.sh` itself refuses to run if the
profile is missing or marker-bearing. The operator cannot start the
orchestrator on an incompletely-set-up project.

## 5. Components

### 5.1 `bin/setup.sh::phase_project_profile` (new)

Slots into `ALL_PHASES` between `slug-freeze` (phase 5) and `github-app`
(phase 6). Earliest phase that can run: depends on `slug-freeze` (needs
`learned-rules/<slug>/` to exist) and on `claude` CLI being available; does
not depend on github-app, gh-cli, or slack.

Behavior:

1. If `learned-rules/<slug>/project-profile.md` exists, parses cleanly against
   the schema (frontmatter + 5 H2 sections), and contains no
   `<<NEEDS-INPUT:>>` markers → skip (already done).
2. If file exists with valid schema but contains markers → skip the
   `claude -p` call, go straight to step 5 (marker resolution).
3. Acquire `$HARNESS_STATE_DIR/.claude-mutex.lock/` (same lock dispatch.sh uses).
4. Invoke `claude -p` with the discovery prompt (rendered from
   `bin/setup-prompts/discovery.md` via inline `sed` token interpolation),
   passing an explicit `--allowed-tools` list (Read, Glob, Grep, Bash with
   read-only subverbs, Write to the single output path). Capture stdout/stderr
   to `$PROJECT_STATE_DIR/logs/setup-discovery-<date>.log`.
5. Validate output file structure: frontmatter present, `schema_version: 1`,
   five required H2 sections in order. On schema fail: remove the partial
   file, die with the captured log path. Operator re-runs.
6. Loop over `<<NEEDS-INPUT: question>>` markers via `_resolve_profile_markers`
   helper:
   - For each marker, prompt the operator at the terminal with the question
     verbatim.
   - Replace the marker line with the answer (single-line answers only; the
     marker line is replaced, not edited inline mid-line).
   - Empty answer triggers re-prompt (≤3 retries, then abort with non-zero;
     file retains markers; setup re-enters phase on next invocation).
7. Optional `$EDITOR` review (gated by `--editor` flag or
   `PIPELINE_PROFILE_EDIT=1`). Default: skip.
8. Release mutex.

Idempotency: `is_project_profile_done` returns true iff file exists with
valid schema and no markers. Explicit phase invocation
(`bash bin/setup.sh project-profile`) bypasses the idempotency check per
existing setup contract.

### 5.2 `bin/setup-prompts/discovery.md` (new)

Plain markdown prompt body for the discovery agent. **Not** a section in
`AGENT_PROMPTS.md`. **Not** registered in `STAGE_TO_SECTION`. **Not** a stage.

Token interpolation (done by `phase_project_profile` via `sed`):
- `{date}` — current ISO-8601 UTC date
- `{slug}` — `project.slug` from config.json
- `{learned_rules_dir}` — `$HARNESS_ROOT/learned-rules/<slug>`
- `{target_repo_path}` — `$TARGET_REPO`

Prompt skeleton:

```
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
   - Top-level config files (package.json, Cargo.toml, Gemfile,
     pyproject.toml, go.mod, build.gradle, Makefile, justfile, *.toml,
     *.yaml).
   - README and any docs/ directory (one paragraph each).
   - CI configuration (.github/workflows, .circleci, etc.) — extract
     canonical build/test/lint commands. CI is more authoritative than
     READMEs.
   - Repo shape: where source lives, where tests live, where docs live.
   - At least 3 representative source files to understand idioms.
   Do NOT read secrets.env, .env*, github-app.pem, or any file under
   .pipeline-config/.

2. Write {learned_rules_dir}/project-profile.md following the schema below.
   Include the YAML frontmatter exactly as shown.

3. For any field you cannot determine with confidence, replace the value
   with: <<NEEDS-INPUT: one short specific question for the operator>>
   - Prefer marker over guessing. The operator will resolve markers
     interactively after you exit.
   - Marker is a single line; question is verbatim, ≤120 chars.

4. Exit. Do NOT post Linear comments, do NOT commit, do NOT push.

## Schema (REQUIRED — emit exactly this structure)
[the 5-section template — see §6]

## Confidence rules
- "Build & test gates": prefer commands found in CI workflows over README.
  If CI has none, fall back to README; if neither exists, emit a marker.
- "Don'ts": only emit findings backed by evidence (a CONTRIBUTING.md note,
  a CODEOWNERS warning, an obvious anti-pattern fixed in the last 50
  commits via `git log --oneline -50`). Otherwise leave the section as
  `(none observed)` — do NOT invent don'ts.
- "File layout": list 3–8 directories; do not enumerate every dir.

## Self-twinning detection
If TARGET_REPO == HARNESS_ROOT (i.e. the harness profiling itself), the
profile MUST identify the bash orchestration as the stack and gates as
`bash bin/<name>-test.sh` per CLAUDE.md. Do not describe a Tauri app.
```

### 5.3 `bin/render-prompt.sh` (modified)

After `extract_block` succeeds, for stages in
`{brainstorm, plan, implement, ui, review, qa, build, release}`:

1. Read `$HARNESS_ROOT/learned-rules/$PROJECT_SLUG/project-profile.md`.
2. If missing: `die "no project-profile.md for slug=$PROJECT_SLUG; run: bash bin/setup.sh project-profile"`.
3. If contains `<<NEEDS-INPUT:`: `die "project-profile.md contains unresolved markers; run: bash bin/setup.sh project-profile"`.
4. If `schema_version` ≠ 1: log warning to stderr, continue.
5. Append to the rendered prompt:

```
\n\n---\n\n## Project profile (addendum)\n\n<file contents>\n
```

For stage `retrospective`: skip addendum entirely (retrospective is meta and
operates across stages/runs).

For stage `release`: addendum is appended (stack context is relevant to
release notes / changelog generation).

Token interpolation in the rendered prompt is unchanged — the addendum is
appended **after** interpolation, so any `{token}` literals inside the
profile are not interpolated. (This is intentional: profile content is
operator-authored prose, not template.)

### 5.4 `bin/dispatch.sh` (unchanged)

`allowed_tools_for` gets no new case. Discovery is not a stage and is not
dispatched by `dispatch.sh`. `phase_project_profile` invokes `claude -p`
directly with its own allowed-tools list.

### 5.5 `AGENT_PROMPTS.md` §§ 1–9 (rewritten)

Strip Twinning/Tauri/SvelteKit/Rust references from framing lines and stage
bodies; replace with neutral phrasing pointing at the addendum.

Examples (illustrative, not final wording):

§1 (Brainstorm) — before:
> *You are brainstorming a solution for Twinning, a desktop app built with Tauri v2 + SvelteKit + Rust.*

§1 — after:
> *You are brainstorming a solution for the project described in the **Project profile** addendum at the bottom of this prompt. Internalize the Stack, File layout, and Don'ts before proposing approaches.*

§2 (Plan): same pattern.

§4 (UI): currently SvelteKit-specific by name. Re-frame as "frontend stage —
applies if the Project profile describes a frontend layer." Whether/how the
UI stage should self-skip on backend-only projects is **out of scope for v1**
— v1 ships the addendum, the rewritten framing, and lets the operator
control which stages run via existing Linear `stage:*` labels.

§§ 5–8 (Review, QA, Build, Release): replace inline `cargo build` /
`bun run check` examples with references to the profile's "Build & test
gates" section. Stage-specific intent (verdict markers, completion
checklists, gate ordering) is preserved verbatim.

§9 (Retrospective): unchanged (no addendum applies).

### 5.6 `bin/install-launchd.sh` (modified)

At entry, before any plist substitution, check
`is_project_profile_done` (or its equivalent inline). If false: die with
"profile missing/incomplete; run `bash bin/setup.sh project-profile`
before installing launchd agents." This guards the case where an operator
skips `setup.sh` and runs `install-launchd.sh` directly.

### 5.7 `bin/setup.sh::phase_launchd` (modified)

At entry, add the same `is_project_profile_done` check. Belt-and-suspenders
alongside the `ALL_PHASES` ordering — ordering covers the happy path; the
explicit guard catches `bash bin/setup.sh launchd` invocations that skip
earlier phases.

## 6. File schema

Path: `learned-rules/<slug>/project-profile.md`

```markdown
---
slug: <slug>
generated_at: <ISO-8601 UTC>
generated_by: discovery-agent
schema_version: 1
---

# Project profile — <project name>

## Stack

<one paragraph: language(s), runtime, framework, package manager, key
external services>

## Build & test gates

- Build: `<command>` *(run from repo root; CI-equivalent)*
- Test: `<command>` *(runs the full unit suite)*
- Lint/check: `<command>` *(types, format, static analysis)*
- Integration/E2E: `<command>` *(or `(n/a) — reason`)*

## File layout

- `path/` — what lives here
- `path/` — what lives here
- (3–8 lines, focused on where source, tests, configs live)

## Language idioms

<bulleted: naming conventions, recurring patterns, framework-specific
idioms agents should mirror>

## Don'ts

<bulleted: anti-patterns, bypasses, libraries to avoid, things that have
burned this codebase before>
```

Frontmatter keys (all required):

| key | value |
|---|---|
| `slug` | matches `project.slug` in config.json |
| `generated_at` | ISO-8601 UTC timestamp; updated on each regeneration |
| `generated_by` | `discovery-agent` (literal) for v1; future may distinguish hand-edits |
| `schema_version` | integer, currently `1` |

Required H2 sections, in order:
1. Stack
2. Build & test gates
3. File layout
4. Language idioms
5. Don'ts

A section may be `(n/a) — reason` if it does not apply, but the heading
must be present. `(none observed)` is the canonical body for an empty
"Don'ts" section.

`<<NEEDS-INPUT: question>>` may appear anywhere in the body. Render refuses
to dispatch while any remain. Marker is a single line; question is verbatim
and ≤120 characters.

## 7. Edge cases and failure modes

| Scenario | Behavior |
|---|---|
| Discovery agent crashes mid-write | Partial file. setup validates structure; on fail, removes file and dies. Operator re-runs phase. |
| Operator `^C`s during marker prompts | Markers remain. Next setup tick fails `is_project_profile_done`, re-enters phase, re-prompts (skips fresh discovery since file already has 5 sections). |
| Skip-discovery rule | If file exists, parses as valid schema, but has markers → `phase_project_profile` skips the `claude -p` call and goes straight to marker prompting. Saves a Claude invocation. |
| Stack changes after profile generated | Operator re-runs `bash bin/setup.sh project-profile` explicitly — explicit phase invocation always re-runs. User can also delete the file to force regeneration. |
| Render-prompt called for a slug with no profile | Dies cleanly with documented remediation. Pipeline halts via existing classify-failure path. |
| Render-prompt called and profile has markers | Same `die` pattern, distinct error message. |
| Retrospective stage | Exempted from addendum. |
| `install-launchd.sh` invoked without finishing setup | Refuses with documented remediation. |
| `phase_launchd` invoked explicitly without earlier phases | Same refusal. |
| Schema version mismatch | Render-prompt logs a warning (not die) if `schema_version != 1`. Forward-compat. |
| Multiple operators / racy setup | Mutex lock around the `claude -p` call (re-uses `.claude-mutex.lock/`). Marker prompts not under lock — terminal-bound and single-user. |
| Profile contains secrets | Discovery prompt explicitly forbids reading `secrets.env` / `.env*` / `github-app.pem` / `.pipeline-config/`. Final file optionally reviewed in `$EDITOR`. |
| Token-bearing content in profile | Profile is appended **after** prompt interpolation; literal `{tokens}` inside the profile are not interpolated. |
| Discovery returns the wrong stack (false positive) | Operator catches in optional `$EDITOR` review or via marker prompts; can also delete and re-run. No automatic detection. |

## 8. Testing

Three new test files, one extension:

1. **`bin/render-prompt-test.sh`** (new). Sources `render-prompt.sh` (sentinel
   pattern), exercises:
   - Profile present, no markers → output ends with `## Project profile (addendum)`; addendum content matches file.
   - Profile missing → dies with the documented remediation message.
   - Profile contains marker → dies with markers-specific message.
   - Retrospective stage → no addendum appended even when profile exists.
   - Schema-version mismatch → warning to stderr, addendum still appended.

2. **`bin/setup-helpers-test.sh`** (extend). Adds `_resolve_profile_markers`
   tests:
   - Single marker, single answer → replaced inline.
   - Three markers, three answers → all replaced, in order.
   - Empty answer → re-prompt (≤3 retries, then abort non-zero).
   - Marker with embedded `:` in question → not split prematurely.
   - Idempotent re-run on a clean file → no prompts, exit 0.

3. **`bin/phase-project-profile-test.sh`** (new). Stubs `claude` via
   `STUB_DIR`, drives:
   - First-run path: stub-claude writes a draft with one marker, stdin feeds
     the answer, final file is marker-free.
   - Re-run path with valid marker-less file → discovery skipped (no `claude`
     invocation in stub); function exits 0.
   - Re-run with markers but valid schema → discovery skipped; only marker
     resolution loop runs.
   - Schema-invalid output from stub-claude → file removed, function dies.
   - Mutex contention: pre-create `.claude-mutex.lock/` → function blocks/fails
     per existing dispatch contract.

4. **`bin/dry-run.sh`** (extend, no new test file). Adds a check that
   `learned-rules/$slug/project-profile.md` exists and is marker-free.
   Surfaces incomplete profiles during `setup validate` instead of at first
   dispatch.

No mocking of `claude` itself — tests stub the binary via `STUB_DIR` per the
existing CLAUDE.md convention.

## 9. Migration

`phase_migrate` (existing, in `bin/setup.sh`) already calls `phase_slug_freeze`
and creates `learned-rules/<slug>/`. The migration delta:

1. After the existing `phase_slug_freeze` call inside `phase_migrate`, insert
   a call to `phase_project_profile` (gated: only run if profile missing or
   has markers).
2. The migrate doc (`docs/brainstorms/2026-04-26-multi-project-harness.md`)
   gets an amendment noting the new step.
3. Self-twinning install (slug `harness`): the discovery agent's
   "Self-twinning detection" rule makes it identify the bash stack correctly
   without operator intervention. Markers are unlikely.
4. Twinning-Tauri install (slug `twinning`): discovery picks up Cargo.toml +
   package.json + svelte.config and emits a Tauri-flavored profile. Likely no
   markers; if any, operator answers them.

ENG-24 unblocks once the harness slug has a populated profile and the base
prompts are stack-stripped.

## 10. Rollout sequencing

The four code touchpoints have a sharp ordering constraint: **the
`AGENT_PROMPTS.md` stack-strip must NOT land before render-prompt is
profile-aware AND every active slug has a populated profile**, or every
running pipeline goes contextless on the next tick.

Ordered steps:

1. Add `bin/setup-prompts/discovery.md` + `phase_project_profile` +
   launchd-phase guards. No `dispatch.sh` changes. No new `AGENT_PROMPTS.md`
   section.
2. Add `render-prompt.sh` addendum logic, default-off via env flag
   `PIPELINE_PROFILE_ADDENDUM=1`. Tests pass with flag both on and off.
3. Run `bash bin/setup.sh project-profile` against both live slugs
   (`harness`, `twinning`); land the resulting profile files.
4. Flip the default on (remove the flag check); re-run `dry-run.sh` for both
   slugs to confirm.
5. Strip Twinning/Tauri framing from `AGENT_PROMPTS.md` §§ 1–8.

Each step is independently revertable. ENG-24 unblocks at step 3.

## 11. Open questions

- v1 ships markdown only. A future schema_version=2 may promote `gates.*`
  to a structured frontmatter block consumable by `dispatch.sh::allowed_tools_for`
  or by scope-check rules. Not in scope for v1.
- The optional `$EDITOR` review step requires `$EDITOR` to be set and to
  exit cleanly. v1 default is skip; the env flag is opt-in. Behavior on
  `$EDITOR` non-zero exit: leave file as-is, treat phase as not-done.
- The discovery agent's "at least 3 representative source files" guidance is
  a heuristic. A future iteration may add a fixed exemplar list per detected
  language family. Not in scope for v1.
- UI-stage auto-skip for backend-only projects (no frontend layer in the
  profile) is deferred. v1 leaves UI-stage routing to the existing
  `stage:*` label flow controlled by orchestrator/operator.
