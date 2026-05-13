---
linear: ENG-95
date: 2026-05-13
topic: Replace the hardcoded Tauri-shaped allowlist in stage_output_paths' implementing|ui|qa arm with a profile-driven derivation (parse `## File layout` from `learned-rules/$PROJECT_SLUG/project-profile.md`) unioned with a stack-agnostic always-include catalog (`docs/` + manifest+lockfile filenames); preserve `_scope_allowlist_override` precedence.
---

# Plan — ENG-95 profile-driven `stage_output_paths`

Implementation plan for the brainstorm at
`docs/brainstorms/2026-05-13-eng-95-make-run-local-helpers-sh-stage-output-paths-consume-project-profile-file-layout-design.md`.

## Goal

For `stage ∈ {implementing, ui, qa}`, `bin/run-local-helpers.sh::stage_output_paths`
returns the union of (a) paths parsed from `learned-rules/$PROJECT_SLUG/project-profile.md`'s
`## File layout` section, after `<slug>` substitution and path-syntax filtering, plus
(b) a hardcoded stack-agnostic always-include catalog (`docs/` + common
manifest+lockfile filenames). The existing `_scope_allowlist_override` hook
short-circuits both when present (back-compat). The hardcoded
`src-tauri/ crates/ bun.lock bun.lockb Cargo.toml Cargo.lock` line is removed.

Verifiable outcome: `bash bin/run-local-sweep-test.sh` and
`bash bin/run-local-helpers-adversarial-test.sh` pass with new fixtures asserting
that (i) for each of the four stack profiles (Rust workspace, Python single-pkg,
Go module, harness-self) a stack-canonical path lands in FD3 (in-scope), and
(ii) parser hardening cases (path-traversal, slug-regex-metachar, em-dash split,
multi-backtick prefix, missing profile) behave per §7 of the brainstorm.

## Anti-anchoring check

- **Problem restated.** Non-Tauri targets self-leak/halt on legitimate writes
  because `stage_output_paths`'s `implementing|ui|qa` arm hardcodes a
  Tauri-shaped path list (`bin/run-local-helpers.sh:219-222`) — agents writing
  to `app/`, `lib/`, `cmd/`, `pkg/` etc. fail the allowlist check inside
  `partition_dirty_paths` and get classified as self-leak →
  `halt_issue_for_self_leak` → `pipeline:halted`. The operator already authored
  a `## File layout` section in the per-slug profile at discovery time, and
  every dispatched agent's prompt reads it; the sweep does not.
- **Brainstorm's solution.** Read `## File layout` from the existing v1
  markdown profile (interim parse — T1's structured schema would replace the
  parser body without churning callers), union with a stack-agnostic
  always-include catalog, preserve `_scope_allowlist_override`. Two new pure
  helpers (`_parse_profile_file_layout`, `_always_include_paths`) plus a
  ~15-line `stage_output_paths` arm refactor.
- **Solution proportionality.** ~30-line awk parser + ~10-line printf catalog
  + ~15-line case-arm rewrite in one file; new fixtures in two existing test
  files; one CLAUDE.md paragraph. No new files, no new env vars, no new config
  keys, no schema migration, no changes to `partition_dirty_paths`'s matcher.
- **Verdict.** Both checks pass. Proceed without `pipeline:supersede` /
  `pipeline:extend`.

## Assumption Inventory

Every code-level claim is verified against the worktree at composition time
(branch
`feat/eng-95-make-run-local-helpers-sh-stage-output-paths-consume-project-profile-file-layout`,
HEAD `29d4ea4`).

- **A-001 — `bin/run-local-helpers.sh::stage_output_paths` exists at lines 202-241,
  with the `implementing|ui|qa` arm at 213-223 emitting the hardcoded Tauri-shaped
  list at 219-222.**
  - `bin/run-local-helpers.sh:202` — `stage_output_paths() {`
  - `bin/run-local-helpers.sh:213` — `    implementing|ui|qa)`
  - `bin/run-local-helpers.sh:214-217` — override short-circuit (`override="$(_scope_allowlist_override "$stage")" … if [[ -n "$override" ]]; then printf '%s\n' "$override"`)
  - `bin/run-local-helpers.sh:219-222` — hardcoded fallback:
    `printf '%s\n' 'src/' 'src-tauri/' 'crates/' 'tests/' 'docs/' 'package.json' 'package-lock.json' 'bun.lock' 'bun.lockb' 'Cargo.toml' 'Cargo.lock'`
  - **Status:** verified by direct read.

- **A-002 — `_scope_allowlist_override` reads `CONFIG::scope.allowlist[$stage]` and
  returns empty (caller's `[[ -n "$override" ]]` falls through) for missing key,
  empty array, or non-array.**
  - `bin/run-local-helpers.sh:11-20` — function body; `jq -r --arg s "$stage" '(.scope.allowlist[$s] // []) as $arr | if ($arr | type) == "array" and ($arr | length) > 0 then $arr[] | select(type == "string") else empty end'`
  - **Status:** verified by direct read. ENG-51 hook contract preserved per AC#3
    and brainstorm D-004; this PR does NOT modify the function body.

- **A-003 — `partition_dirty_paths` (lines 288-354) consumes the
  `stage_output_paths "$stage"` output as the in-scope allowlist via
  the `while read; allowlist+=("$line")` loop at lines 290-293; the matcher
  at lines 320-328 prefix-matches entries ending in `/` and exact-matches
  entries without `/`.**
  - `bin/run-local-helpers.sh:290-293` — `local -a allowlist=(); while IFS= read -r line; do [[ -n "$line" ]] && allowlist+=("$line"); done < <(stage_output_paths "$stage")`
  - `bin/run-local-helpers.sh:322-326` — matcher: `if [[ "$entry" == */ ]]; then case "$path" in "$entry"?*) matched_dir=1; break ;; esac else [[ "$path" == "$entry" ]] && { matched_exact=1; break; } fi`
  - **Status:** verified by direct read. The matcher logic is unchanged by this
    PR (brainstorm §5.4 confirms); only the source list changes.

- **A-004 — `apply_d004=1` only fires for `brainstorming|planning`, so the
  `implementing|ui|qa` arm change does not interact with the basename-token
  ENG-N matcher.**
  - `bin/run-local-helpers.sh:295-296` — `local apply_d004=0; case "$stage" in brainstorming|planning) apply_d004=1 ;; esac`
  - **Status:** verified by direct read.

- **A-005 — `assert_stage_allowlist_coverage` walks 9 stages including
  `implementing ui qa` and asserts each has a non-empty `stage_output_paths`
  output; this PR's arm always returns at least the always-include catalog,
  so the assertion still passes.**
  - `bin/run-local-helpers.sh:259-265` — function body iterates
    `brainstorming planning implementing ui reviewing qa building released retrospective`
  - **Status:** verified by direct read. Post-change, the always-include set
    (≥17 entries; see `_always_include_paths` in §5.2 of the brainstorm)
    guarantees a non-empty output for the three relevant arms.

- **A-006 — `learned-rules/$PROJECT_SLUG/project-profile.md` is the canonical
  profile path, identical to `bin/render-prompt.sh::append_project_profile`'s
  `profile_path` resolution.**
  - `bin/render-prompt.sh:149` — `local profile_path="$HARNESS_ROOT/learned-rules/$PROJECT_SLUG/project-profile.md"`
  - **Status:** verified by direct read. Plan reuses the exact same construction
    in `stage_output_paths` (see Task 3) so a future profile-path migration
    only changes one literal in two places.

- **A-007 — Profile schema requires the `## File layout` H2 section in
  3rd position with bullets shaped `` - `path/` — description ``.**
  - `bin/setup-helpers.sh:153` — `_validate_project_profile_schema` enforces
    the exact 5-section ordered list including `## File layout`.
  - `bin/setup-prompts/discovery.md:53-56` — discovery prompt mandates
    `` - `path/` — what lives here `` form, 3-8 directories.
  - `learned-rules/harness/project-profile.md:21-28` — concrete instance,
    e.g. line 23 `` - `bin/` — every orchestration script (`run-local.sh`, …) ``.
  - `learned-rules/twinning/project-profile.md:21-28` — concrete instance.
  - **Status:** verified by direct read. The parser's regex (`/^## File layout[[:space:]]*$/ … /^## /`) and bullet pattern (`/^- /`) match this shape.

- **A-008 — Harness profile uses `<slug>` placeholder in
  `learned-rules/<slug>/`; `<slug>` substitution is the only token translation
  ENG-95 introduces.**
  - `learned-rules/harness/project-profile.md:25` — `` - `learned-rules/<slug>/` — per-slug rule files appended to dispatched stage prompts; … ``
  - **Status:** verified by direct read. D-002 substitutes `$PROJECT_SLUG` for
    `<slug>` after slug-shape validation; other placeholders (e.g. `<stage>`)
    are dropped via the bullet's `token !~ /</` filter (D-006 + D-002 belt-and-braces).

- **A-009 — Twinning profile's `src-tauri/` bullet contains many descriptive
  backticked tokens after the em-dash; the parser MUST split on em-dash and
  ignore description-side backticks to avoid sweeping `build.rs` etc. into
  the allowlist.**
  - `learned-rules/twinning/project-profile.md:24` — `` - `src-tauri/` — Tauri shell crate: `src/`, `build.rs`, `capabilities/`, `gen/`, `icons/`, `Entitlements.plist`. The Rust app entry point lives here. ``
  - **Status:** verified by direct read. Drives the em-dash split design in
    brainstorm §5.1; tested by adversarial case `parse_em_dash_split`.

- **A-010 — Harness profile bullet `` - `docs/brainstorms/` and `docs/plans/` — … ``
  has multiple backticked tokens BEFORE the em-dash; both must be extracted.**
  - `learned-rules/harness/project-profile.md:27` — `` - `docs/brainstorms/` and `docs/plans/` — canonical doc locations… ``
  - **Status:** verified by direct read. Drives the inner `while (match(prefix, /\`[^\`]+\`/))` loop in brainstorm §5.1; tested by adversarial case `parse_multi_backtick_prefix`.

- **A-011 — `bin/common.sh` exports `HARNESS_ROOT` (line 9, 20) and
  `PROJECT_SLUG` (line 62) at source time; both are set BEFORE
  `bin/run-local-helpers.sh` is sourced by `run-local.sh`/test fixtures,
  satisfying the §5.3 path construction
  `"${HARNESS_ROOT:-}/learned-rules/${PROJECT_SLUG:-}/project-profile.md"`.**
  - `bin/common.sh:9` — `HARNESS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"`
  - `bin/common.sh:20` — `export HARNESS_ROOT TARGET_REPO HARNESS_STATE_DIR …`
  - `bin/common.sh:47-55` — `PROJECT_SLUG` resolution (caller pre-set OR
    `TWINNING_BOOTSTRAPPING=1` soft-empty OR read from `config.json::project.slug`)
  - `bin/common.sh:62` — `export HARNESS_CONFIG_DIR PROJECT_SLUG PROJECT_STATE_DIR`
  - **Status:** verified by direct read. The `${VAR:-}` fallback in §5.3's path
    construction handles the test-source path where `PROJECT_SLUG` may not be
    populated; the resulting `learned-rules//project-profile.md` fails
    `[[ -f … ]]` and triggers the fallback (D-005).

- **A-012 — `log` from `common.sh` writes to stderr, not stdout, so the
  `stage_output_paths` diagnostic (D-005) does NOT pollute the path stream
  consumed by `partition_dirty_paths` at line 293.**
  - `bin/common.sh:30-32` — `log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }`
  - **Status:** verified by direct read. Diagnostic is operator-visible in
    `$PROJECT_STATE_DIR/<slug>/logs/local-YYYY-MM-DD.log` per D-005; harmless
    to the path stream.

- **A-013 — Existing test scaffold uses the source-and-stub pattern (sets
  `PROJECT_SLUG` BEFORE sourcing `common.sh` + `run-local-helpers.sh`).
  `HARNESS_ROOT` is NOT explicitly set by any of the three referenced
  tests — it is derived inside `common.sh:9` from the script's own location
  at source time. ENG-95's new fixtures EXTEND this pattern by overriding
  `HARNESS_ROOT` to a tempdir POST-source (per CLAUDE.md "post-source
  overrides … (top-level assignments in the sourced script are global,
  so this works)" pattern), restoring after each case to prevent
  state bleed.**
  - `bin/run-local-sweep-test.sh:6-11` — `SCRIPT_DIR=… ; export PROJECT_SLUG="${PROJECT_SLUG:-test-slug}" ; source "$SCRIPT_DIR/common.sh" ; source "$SCRIPT_DIR/run-local-helpers.sh"`
  - `bin/run-local-helpers-adversarial-test.sh:20-25` — same pattern.
  - `bin/profile-allowlist-test.sh:42-66` — exports `TARGET_REPO`,
    `HARNESS_STATE_DIR`, `PROJECT_STATE_DIR` pre-source; inherits
    `HARNESS_ROOT` from `common.sh:9` derivation. ENG-95's overrides extend
    this list with `HARNESS_ROOT` per-case.
  - **Status:** verified by direct read.

- **A-014 — `bash bin/run-local-sweep-test.sh` and
  `bash bin/run-local-helpers-adversarial-test.sh` are in BOTH the
  `implementing` and `qa` allowlists per the project-profile addendum's
  "Tool allowlist" section. `bash bin/profile-allowlist-test.sh:*` likewise.**
  - **Status:** verified per the addendum's `implementing` / `qa` allowlist
    bullets at the top of this prompt.

- **A-015 — `auto_commit_in_scope` (lines 383-479) calls `stage_output_paths`
  via the `[[ -z "$(stage_output_paths "$stage" 2>/dev/null || true)" ]]`
  guard at line 412 and again indirectly via `partition_dirty_paths` at
  line 430. Post-ENG-95, both arms still return non-empty for `implementing|ui|qa`
  (always-include set guarantees ≥17 entries), so the operator-resume auto-commit
  path continues to work.**
  - `bin/run-local-helpers.sh:412` — early-return guard
  - `bin/run-local-helpers.sh:430` — `partition_dirty_paths "$stage" "$issue"`
  - **Status:** verified by direct read; brainstorm §12 Open Question 4
    confirms the same. No `auto_commit_in_scope` edits.

- **A-016 — CLAUDE.md "Sweep + scope partition (ENG-14)" section lives at
  lines 251-263 and is the documented operator-facing reference for the
  per-stage allowlist; brainstorm §10 specifies an append.**
  - `CLAUDE.md:251-263` — section header + body + "Anything writing files
    outside the per-stage allowlist must update the partition rules in
    `run-local-helpers.sh` or it will trip the breaker."
  - **Status:** verified by direct read. Task 6 appends the brainstorm §10
    paragraph after line 263.

- **A-017 — There is no `learned-rules/harness/plan.md` at composition time;
  the dispatched plan agent inherits no per-slug rules for this stage.**
  - `learned-rules/harness/` contains only `build.md` and `project-profile.md`
    (verified via shell `ls`).
  - **Status:** verified. No `learned-rules/<slug>/plan.md` to honor; the
    five base personas drive the self-review per the dispatcher prompt's
    Completion checklist step 2.

All seventeen load-bearing facts verify in the current worktree.

## File Structure

- **MODIFIED** `bin/run-local-helpers.sh` —
  - ADD `_parse_profile_file_layout` near top (after `_scope_allowlist_override`,
    before `trip_breaker`; pure helper, no side effects). ~30 lines incl. awk body.
  - ADD `_always_include_paths` adjacent to the parser. ~12 lines.
  - REPLACE the `implementing|ui|qa)` arm body of `stage_output_paths` (lines
    213-223): keep the `_scope_allowlist_override` short-circuit at lines
    214-217 verbatim; replace lines 218-223 (the hardcoded fallback) with the
    profile-derived + always-include union (`sort -u`) and the D-005 diagnostic
    log fired only when `profile_list` is empty. ~15 lines.
- **MODIFIED** `bin/run-local-helpers-adversarial-test.sh` — append a new
  block (`# ─── ENG-95: profile-driven stage_output_paths ───`) covering the
  16 adversarial cases enumerated in brainstorm §9.2. Each case is a
  self-contained tempdir + fixture profile + `assert_eq` against
  `_parse_profile_file_layout` output OR an `assert_partition_counts` against
  `partition_dirty_paths` (for the override-precedence and log-fires cases).
- **MODIFIED** `bin/run-local-sweep-test.sh` — (a) append the 11 stack-fixture
  cases from brainstorm §9.1 (each sets `HARNESS_ROOT` to a tempdir
  containing a fixture `learned-rules/<slug>/project-profile.md` and asserts
  that a representative dirty path lands in the expected stream), AND
  (b) update existing case 12 (`implement_stage_sweeps_rust_source`) to seed a
  `learned-rules/test-slug/project-profile.md` fixture under a tempdir
  `HARNESS_ROOT` whose `## File layout` lists `crates/`, so the input
  `?? crates/twinning-pipeline/src/foo.rs` continues to land in-scope under
  the new derivation chain. Existing case 13
  (`retrospective_pipeline_config_in_scope`) is structurally untouched —
  the retrospective arm at lines 225-233 of `bin/run-local-helpers.sh` is
  outside ENG-95's scope (brainstorm §3 non-goal) and case 13 passes
  without modification. See Task 5's case-12 update step and the Failure
  Mode → Test Map's case-12 / case-13 rows for the regression argument.
- **MODIFIED** `CLAUDE.md` — append the §10 paragraph from the brainstorm
  to the "Sweep + scope partition (ENG-14)" section (lines 251-263);
  includes the decision-tree table, migration note, and always-include
  scope explanation.

No new files. No new exports. No new env vars. No new config keys. No
changes to `bin/pipeline-events.json`. No changes to `bin/dispatch.sh`,
`bin/run-stage.sh`, `bin/render-prompt.sh`, `bin/setup-helpers.sh`,
`bin/common.sh`, or any other orchestration script.

## API Contract

no new API surface (this is a bash-orchestration repo with no FE↔BE API;
the only contract change is the internal bash function signature for two
new pure helpers in `bin/run-local-helpers.sh`, both consumed only by
`stage_output_paths` in the same file and by the test scaffold).

## Backend Tasks

### Task 1: Add `_parse_profile_file_layout` pure helper to `bin/run-local-helpers.sh`

- `depends_on: []`
- `touches: bin/run-local-helpers.sh::_parse_profile_file_layout (new)`
- [ ] Insert the new helper into `bin/run-local-helpers.sh` immediately after
      `_scope_allowlist_override`'s closing `}` at line 20 and before
      `trip_breaker` at line 42 (sibling-helper placement; both are profile-side
      readers consumed by `stage_output_paths`). Function body verbatim per
      brainstorm §5.1 (signature: `_parse_profile_file_layout <profile_path>
      [<slug>]`; emits one path per stdout line; never logs; rc 0 unconditionally).
- [ ] Implement the slug-shape validation: `if [[ ! "$slug" =~ ^[a-zA-Z0-9_-]+$ ]]; then slug=""; fi`
      (D-002 fail-closed; a malformed slug yields empty substitution which
      the path-syntax filter D-006 then drops as an empty token).
- [ ] Implement the awk gsub-escape pre-pass on the slug:
      `local slug_esc; slug_esc="${slug//\\/\\\\}"; slug_esc="${slug_esc//&/\\&}"`
      (belt-and-braces; the validation regex already rejects `&` and `\`).
- [ ] Awk body per brainstorm §5.1:
  - Section gate: `/^## File layout[[:space:]]*$/ { in_section=1; next }`
  - Exit on next H2: `in_section && /^## / { exit }`
  - Bullet match: `in_section && /^- / { ... }`
  - Em-dash split (UTF-8 byte sequence + literal char fallback):
    `em_pos = index(prefix, " \xe2\x80\x94 "); if (em_pos == 0) em_pos = index(prefix, "—"); if (em_pos > 0) prefix = substr(prefix, 1, em_pos - 1)`
  - Backtick token extraction loop: `while (match(prefix, /\`[^\`]+\`/)) { token = substr(prefix, RSTART+1, RLENGTH-2); gsub(/<slug>/, slug, token); ... ; prefix = substr(prefix, RSTART + RLENGTH) }`
  - Path-syntax filter (D-006): `if (token != "" && token !~ /</ && token !~ /^\// && token !~ /^\.\.\// && token !~ /\/\.\.\//) { print token }`
- [ ] Add a 1-line file-existence guard at function entry:
      `[[ -f "$profile_path" ]] || return 0` (D-005 fail-soft for the test
      sourcing path).
- [ ] Add a 5-line block comment above the function citing
      `bin/render-prompt.sh:149` as the canonical-profile-path companion and
      noting the pure-helper / no-log discipline (operator-visible diagnostics
      live in `stage_output_paths`, per D-005).

### Task 2: Add `_always_include_paths` pure helper to `bin/run-local-helpers.sh`

- `depends_on: []`
- `touches: bin/run-local-helpers.sh::_always_include_paths (new)`
- [ ] Insert immediately after `_parse_profile_file_layout`. Body verbatim
      per brainstorm §5.2 — single `printf '%s\n'` emitting:
  - `'docs/'`
  - JS/TS catalog: `'package.json' 'package-lock.json' 'yarn.lock' 'pnpm-lock.yaml' 'bun.lock' 'bun.lockb'`
  - Rust catalog: `'Cargo.toml' 'Cargo.lock'`
  - Python catalog: `'pyproject.toml' 'poetry.lock' 'uv.lock' 'Pipfile' 'Pipfile.lock'`
  - Go catalog: `'go.mod' 'go.sum'`
  - Ruby catalog: `'Gemfile' 'Gemfile.lock'`
- [ ] Add a 4-line block comment citing brainstorm D-003 (rationale: catalog
      is hardcoded by design; T1 may move it into per-stack profile schemas;
      false-positive scope bound to single-file top-level matches).

### Task 3: Refactor `stage_output_paths` `implementing|ui|qa` arm

- `depends_on: [1, 2]`
- `touches: bin/run-local-helpers.sh::stage_output_paths (lines 213-223)`
- [ ] Replace lines 218-223 (the hardcoded `printf` fallback) with the new
      derivation per brainstorm §5.3:

      ```bash
      else
        local profile_path="${HARNESS_ROOT:-}/learned-rules/${PROJECT_SLUG:-}/project-profile.md"
        local profile_list
        profile_list="$(_parse_profile_file_layout "$profile_path")"
        if [[ -z "$profile_list" ]]; then
          log "stage_output_paths: profile-derived list empty for stage=$stage" \
              "(slug=${PROJECT_SLUG:-<unset>}, path=$profile_path);" \
              "falling back to docs/ + lockfile catalog." \
              "Run: bash bin/setup.sh project-profile"
        fi
        {
          printf '%s' "$profile_list"
          [[ -n "$profile_list" ]] && printf '\n'
          _always_include_paths
        } | LC_ALL=C sort -u
      fi
      ;;
      ```

- [ ] Keep lines 213-217 (the `implementing|ui|qa)` case head + override
      short-circuit) BIT-FOR-BIT unchanged. The brainstorm's D-004 mandates
      this back-compat preservation per AC#3.
- [ ] Verify by direct read post-edit: `grep -n "src-tauri\|bun.lock\|Cargo.toml\|Cargo.lock"
      bin/run-local-helpers.sh` prints ZERO matches inside `stage_output_paths`'s
      body (the always-include catalog still references `Cargo.toml`/`Cargo.lock`
      etc. inside `_always_include_paths`'s body — those matches are EXPECTED
      and not in `stage_output_paths`).
- [ ] Add a 6-line block comment above the rewritten arm citing brainstorm
      D-001 (profile-derived), D-003 (always-include catalog), D-004
      (override precedence), D-005 (fail-soft + diagnostic log), and the
      reason `sort -u` is the deduplication boundary (e.g. profile lists
      `docs/` and the catalog also lists `docs/` → one `docs/` entry).

### Task 4: Add adversarial unit fixtures to `bin/run-local-helpers-adversarial-test.sh`

- `depends_on: [1, 2, 3]`
- `touches: bin/run-local-helpers-adversarial-test.sh (new ENG-95 block)`
- [ ] Append a new section delimited by `# ─── ENG-95: profile-driven stage_output_paths ───`
      below the existing test cases, but ABOVE the final `report_summary` /
      exit-code section.
- [ ] For each case, build a fixture tempdir under `mktemp -d -t twinning-eng95.XXXXXX`,
      write a `learned-rules/<slug>/project-profile.md` with the requisite
      `## File layout` section, override `HARNESS_ROOT` to the tempdir,
      override `PROJECT_SLUG` to `test-slug` (or per-case as the regex
      validation requires), and assert via `assert_eq` against the sorted
      output of `_parse_profile_file_layout` OR via
      `assert_partition_counts` against `partition_dirty_paths`. Restore
      the original `HARNESS_ROOT`/`PROJECT_SLUG` after each case to prevent
      state bleed (mirrors the `qa_no_state_bleed_between_invocations` pattern
      at line 314 of the existing test).
- [ ] Implement the 16 cases per brainstorm §9.2:
  - `parse_em_dash_split`
  - `parse_multi_backtick_prefix`
  - `parse_slug_substitution`
  - `parse_other_placeholder_skipped`
  - `always_include_present_when_profile_minimal`
  - `always_include_dedup_with_profile`
  - `override_empty_falls_through_to_profile`
  - `parse_absolute_path_rejected`
  - `parse_traversal_prefix_rejected`
  - `parse_embedded_traversal_rejected`
  - `parse_unbalanced_backticks_safe`
  - `parse_slug_regex_metachar_safe`
  - `parse_slug_amp_metachar_safe`
  - `parse_no_em_dash_handled`
  - `parse_log_fires_on_empty_profile_layout` (capture stderr via
    `stage_output_paths implementing 2>"$tdir/stderr"` and assert
    the `stage_output_paths: profile-derived list empty` substring is
    present exactly once)
  - `parse_log_does_not_fire_on_valid_profile` (assert stderr is empty
    or contains no `profile-derived list empty` substring)
- [ ] Run `bash bin/run-local-helpers-adversarial-test.sh` and confirm
      summary line shows 0 FAIL across the union of pre-existing cases +
      16 new cases. Pre-existing cases must remain green (no test-state
      bleed from `HARNESS_ROOT`/`PROJECT_SLUG` overrides — restore after
      each case).

### Task 5: Add stack-fixture sweep cases to `bin/run-local-sweep-test.sh` and update case 12 for back-compat

- `depends_on: [3]`
- `touches: bin/run-local-sweep-test.sh (update case 12; append cases 14-24)`
- [ ] **Back-compat update for case 12** (`implement_stage_sweeps_rust_source` at
      lines 96-98). The existing test scaffold sources `common.sh` +
      `run-local-helpers.sh` at `bin/run-local-sweep-test.sh:7-11` with
      `PROJECT_SLUG=test-slug` and inherits `HARNESS_ROOT` from `common.sh`'s
      line-9 derivation. Post-ENG-95, with no `learned-rules/test-slug/project-profile.md`
      present in the harness repo, `_parse_profile_file_layout` returns empty
      and the always-include catalog is the only fallback — `crates/` is NOT
      in the catalog, so the input `?? crates/twinning-pipeline/src/foo.rs`
      would regress from in-scope to observed. Fix: BEFORE the case-12 line,
      build a tempdir + `learned-rules/test-slug/project-profile.md` fixture
      whose `## File layout` lists `` `crates/` ``, set `HARNESS_ROOT` to the
      tempdir for the case-12 invocation, run the existing assertion, restore
      `HARNESS_ROOT` afterwards. Use the same scaffold pattern the new cases
      14-24 use; share the tempdir construction via a small helper if it cuts
      duplication. The case-12 assertion `assert_partition implement_stage_sweeps_rust_source
      implementing ENG-14 1 0 0` does NOT change; only the surrounding fixture
      setup is added.
- [ ] **Case 13** (`retrospective_pipeline_config_in_scope` at lines 100-104) is
      structurally untouched — the retrospective arm at
      `bin/run-local-helpers.sh:225-233` is outside ENG-95's scope per
      brainstorm §3 non-goal. No edit. Confirm post-Task-3 by `grep -n
      "retrospective" bin/run-local-helpers.sh` returning the unchanged arm.
- [ ] Append 11 new cases below the existing case 13 (line 104), BEFORE the
      final `printf 'All sweep-test cases passed.\n'` at line 106. Each case:
  1. Builds a tempdir profile fixture per brainstorm §9.1's table.
  2. Overrides `HARNESS_ROOT` to the tempdir for the duration of the
     `printf … | assert_partition` invocation; restores after.
  3. Asserts the correct (in-scope, leaked, observed) tuple.
- [ ] Implement the 11 fixtures per brainstorm §9.1:
  - `profile_rust_workspace_inscope` — `crates/`, `tests/` → `?? crates/twinning-foo/src/lib.rs` in-scope
  - `profile_python_single_pkg_inscope` — `app/`, `tests/` → `?? app/handlers.py` in-scope
  - `profile_go_module_inscope` — `cmd/`, `pkg/`, `internal/` → `?? cmd/server/main.go` in-scope
  - `profile_harness_self_inscope` — `bin/`, `learned-rules/<slug>/`, `AGENT_PROMPTS.md` →
    two assertions: `?? bin/foo.sh` in-scope AND `?? learned-rules/test-slug/build.md`
    in-scope (asserts `<slug>` substitution against `PROJECT_SLUG=test-slug`)
  - `profile_python_lockfile_inscope` — only `app/` in profile → `?? poetry.lock` in-scope
  - `profile_go_lockfile_inscope` — only `cmd/` in profile → `?? go.sum` in-scope
  - `profile_docs_always_inscope` — only `src/` in profile → `?? docs/anything.md` in-scope
  - `profile_unknown_dir_out_of_scope` — only `crates/` in profile → `?? app/leak.py`
    leaked-in-scope (the matched_dir=0 + matched_exact=0 path goes to FD5/observed
    when path is NOT new since tick start; per brainstorm §9.1 fixture description
    "depending on prior state" — write the assertion as observed=1 to match
    `partition_dirty_paths`'s behavior on a `??` (untracked) record per the
    matcher arms at lines 320-352, since untracked paths with no allowlist
    match fall through to FD5)
  - `profile_missing_falls_back_to_always_include` — no profile file → `?? docs/foo.md`
    in-scope; `?? src/leak.rs` observed (out-of-scope, fall-through)
  - `profile_file_layout_missing_falls_back` — profile exists with no `## File
    layout` section → same as missing profile
  - `profile_override_shadows_layout` — `crates/` in profile, `config.json::scope.allowlist.implementing
    = ["src/"]` → `?? src/foo.rs` in-scope; `?? crates/foo.rs` observed
- [ ] Run `bash bin/run-local-sweep-test.sh` and confirm `All sweep-test
      cases passed.` is printed (cases 1-13 still green, cases 14-24 new and
      green).

### Task 6: Update `CLAUDE.md` "Sweep + scope partition (ENG-14)" section

- `depends_on: [3]`
- `touches: CLAUDE.md (after line 263)`
- [ ] Append the brainstorm §10 paragraph (verbatim) immediately after
      line 263 ("Anything writing files outside the per-stage allowlist must
      update the partition rules in `run-local-helpers.sh` or it will trip
      the breaker."), BEFORE the section break that introduces "## Per-target
      dispatch.tools extras (ENG-51, ENG-53 #8)" at line 265. The appended
      block contains:
  - One paragraph stating the new derivation (profile + always-include
    catalog) and the removed Tauri shape.
  - The decision-tree markdown table ("Where to make scope changes")
    distinguishing permanent stack-shape changes (edit profile), per-target
    one-offs (edit `config.json::scope.allowlist.<stage>[]`), and common
    lockfile catalog edits (edit `_always_include_paths` and PR the harness
    repo).
  - A migration paragraph for pre-ENG-95 Tauri targets (existing profiles
    work unchanged because they list the Tauri directories in their
    `## File layout`; missing entries trigger the diagnostic log).
  - The always-include lockfile catalog scope clarification (the catalog
    grants in-scope status for ALL common manifest+lockfile filenames
    regardless of stack; bounded false-positive risk; tighten via
    `config.json` if too broad).
- [ ] Verify the appended markdown does NOT introduce a new H2 (no `^## `
      line) — it stays inside the existing "## Sweep + scope partition
      (ENG-14)" section.

### Task 7: Run the full pre-commit test suite to catch regressions

- `depends_on: [4, 5, 6]`
- `touches: (test execution only — no file edits)`
- [ ] Run `bash .githooks/pre-commit` (per CLAUDE.md "Pre-commit hook" §;
      ~30 s total runtime; gates every commit on the full `bin/*-test.sh`
      suite). Expected outcome: every test other than `KNOWN_BROKEN`
      allowlist entries passes. The new test cases land in
      `run-local-helpers-adversarial-test.sh` (Task 4) and
      `run-local-sweep-test.sh` (Task 5), both already in the
      implementing/qa allowlists per A-014.
- [ ] If any non-`KNOWN_BROKEN` test fails, do NOT use `--no-verify` to
      bypass; investigate and fix in-scope. If the failure is in an
      unrelated test (i.e. neither a sweep-test nor adversarial-test
      regression), escalate via `bash bin/pipeline.sh event ENG-95
      verdict halt --reason agent-blocked` with a one-line description.

## Frontend Tasks

(no UI surface in this repo; the harness contains only bash orchestration
scripts per the project profile addendum's "Stack" §)

## Failure Mode → Test Map

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
|---|---|---|---|---|
| Profile file missing on disk | Test fixture omits `learned-rules/<slug>/project-profile.md` | Fall back to always-include only; one `log` line emitted via `stage_output_paths` (D-005); `_parse_profile_file_layout` returns rc 0 with empty stdout | unit | `bin/run-local-helpers-adversarial-test.sh::parse_log_fires_on_empty_profile_layout` (and integration: `bin/run-local-sweep-test.sh::profile_missing_falls_back_to_always_include`) |
| `## File layout` section missing in an otherwise-valid profile | Profile contains other H2 sections but no File layout | Same as missing profile — empty parse stream → fall back to always-include + log fires | unit / integration | `bin/run-local-sweep-test.sh::profile_file_layout_missing_falls_back` |
| Bullet with no backticked path (pure prose) | Profile bullet `- some prose only` | Skipped silently — no `match()` hit, inner loop exits cleanly | unit (covered by) | `bin/run-local-helpers-adversarial-test.sh::parse_em_dash_split` (the description-side prose case is the same control flow) |
| Bullet with backticked tokens only AFTER em-dash | Profile bullet `` - `src/` — note about `tests/` `` | Only `src/` extracted; description-side `tests/` ignored | unit | `bin/run-local-helpers-adversarial-test.sh::parse_em_dash_split` |
| Bullet with multiple backticked tokens BEFORE em-dash | Profile bullet `` - `docs/brainstorms/` and `docs/plans/` — caption `` | Both extracted | unit | `bin/run-local-helpers-adversarial-test.sh::parse_multi_backtick_prefix` |
| Bullet with `<slug>` placeholder | Profile bullet `` - `learned-rules/<slug>/` `` with `PROJECT_SLUG=foo` | Substituted to `learned-rules/foo/` | unit | `bin/run-local-helpers-adversarial-test.sh::parse_slug_substitution` (and integration: `bin/run-local-sweep-test.sh::profile_harness_self_inscope`) |
| Bullet with non-`<slug>` placeholder | Profile bullet `` - `<stage>/output/` `` | Skipped via D-006 `token !~ /</` filter (defensive) | unit | `bin/run-local-helpers-adversarial-test.sh::parse_other_placeholder_skipped` |
| Bullet with absolute path | Profile bullet `` - `/etc/passwd` `` | Skipped via D-006 `token !~ /^\//` filter | unit | `bin/run-local-helpers-adversarial-test.sh::parse_absolute_path_rejected` |
| Bullet with `../` traversal prefix | Profile bullet `` - `../../etc/shadow` `` | Skipped via D-006 `token !~ /^\.\.\//` filter | unit | `bin/run-local-helpers-adversarial-test.sh::parse_traversal_prefix_rejected` |
| Bullet with embedded `/../` traversal | Profile bullet `` - `foo/../../bar` `` | Skipped via D-006 `token !~ /\/\.\.\//` filter | unit | `bin/run-local-helpers-adversarial-test.sh::parse_embedded_traversal_rejected` |
| Bullet with unbalanced backticks | Profile bullet `` - `src/` `docs/ `` | First closed pair `src/` extracted; unclosed second backtick has no match → inner loop exits cleanly; no abort, no partial-token leak | unit | `bin/run-local-helpers-adversarial-test.sh::parse_unbalanced_backticks_safe` |
| `PROJECT_SLUG` contains awk regex metachars (`.`, `\|`, `[`, `\\`) | Test sets `PROJECT_SLUG=a.b` and parses bullet `` - `learned-rules/<slug>/` `` | Slug fails the `^[a-zA-Z0-9_-]+$` validation → empty substitution → `learned-rules//` → dropped by D-006 empty-token filter; no awk replacement-string injection | unit | `bin/run-local-helpers-adversarial-test.sh::parse_slug_regex_metachar_safe` |
| `PROJECT_SLUG` is empty (test path without `common.sh` source) | Bullet `` - `learned-rules/<slug>/` `` with `PROJECT_SLUG=""` | Empty substitution + D-006 drop → no entry; safe fallback (no crash) | unit (covered by) | `bin/run-local-helpers-adversarial-test.sh::parse_slug_regex_metachar_safe` (the empty-string case shares the validation-fail control flow) |
| Bullet with no em-dash at all | Profile bullet `` - `src/` `` (single backticked token, no description) | Whole-line treated as prefix; `src/` extracted | unit | `bin/run-local-helpers-adversarial-test.sh::parse_no_em_dash_handled` |
| Profile contains `<<NEEDS-INPUT:>>` markers | Test profile has unresolved markers + valid `## File layout` | Parser still extracts non-marker bullets; render-prompt.sh remains primary defense | (covered by existing tests for render-prompt.sh; ENG-95 parser is permissive — non-blocking) | n/a (defensive design; out of ENG-95 scope per brainstorm §7) |
| Same path appears in profile AND always-include set | Profile lists `docs/`; always-include also lists `docs/` | `sort -u` deduplicates; output has one `docs/` entry | unit | `bin/run-local-helpers-adversarial-test.sh::always_include_dedup_with_profile` |
| Profile minimal (only one source dir bullet) | Profile bullet `` - `src/` `` | Output union still includes always-include catalog (`docs/`, `Cargo.toml`, etc.) | unit | `bin/run-local-helpers-adversarial-test.sh::always_include_present_when_profile_minimal` |
| `_scope_allowlist_override` returns non-empty | `config.json::scope.allowlist.implementing = ["src/"]` only | Override wins absolutely; profile-derived list NOT consulted; profile's `crates/` becomes leak | integration | `bin/run-local-sweep-test.sh::profile_override_shadows_layout` |
| `_scope_allowlist_override` returns empty (`[]`) | `config.json::scope.allowlist.implementing = []` | Falls through to profile-derived path per ENG-51 contract | unit | `bin/run-local-helpers-adversarial-test.sh::override_empty_falls_through_to_profile` |
| Non-Tauri stack (Rust workspace, Python, Go, harness-self) writes legitimate path | Test fixture uses one of four stack-shaped profiles | In-scope path lands in FD3 | integration | `bin/run-local-sweep-test.sh::profile_rust_workspace_inscope`, `profile_python_single_pkg_inscope`, `profile_go_module_inscope`, `profile_harness_self_inscope` |
| Lockfile write on a stack whose profile omits the manifest | Profile lists only `app/`; agent writes `?? poetry.lock` | In-scope via always-include catalog; bounded false-positive (single literal filename, not a directory prefix) | integration | `bin/run-local-sweep-test.sh::profile_python_lockfile_inscope`, `profile_go_lockfile_inscope` |
| `docs/` write on any stack | Profile lists only `src/`; agent writes `?? docs/architecture.md` | In-scope via always-include `docs/` entry | integration | `bin/run-local-sweep-test.sh::profile_docs_always_inscope` |
| `assert_stage_allowlist_coverage` fails because a stage's output is empty | Edit that breaks `_always_include_paths` (e.g. drops every entry) | The assertion at lines 259-265 fails at startup; CI catches before any tick | unit | `bin/run-local-helpers-adversarial-test.sh::assert_stage_allowlist_coverage_happy_path` (line 148, existing — still passes post-change because always-include set guarantees ≥17 entries) |
| `auto_commit_in_scope` early-return regresses to "no allowlist → no-op" on `implementing|ui|qa` | Edit that returns empty for the three stages | `auto_commit_in_scope`'s line-412 guard treats stage as read-only and skips; operator-resume `decide --action continue` silently fails to push the brainstorm/plan doc | (covered indirectly) — `assert_stage_allowlist_coverage` catches the empty-output failure; explicit fixture not added | n/a (covered by `assert_stage_allowlist_coverage_happy_path` per A-005) |
| Diagnostic log misfires on a valid profile | Profile has populated `## File layout` | `stage_output_paths` does NOT emit the `profile-derived list empty` log | unit | `bin/run-local-helpers-adversarial-test.sh::parse_log_does_not_fire_on_valid_profile` |
| Pre-existing case 12 (`implement_stage_sweeps_rust_source`) regresses because the new derivation no longer covers `crates/` by default | The test-slug profile fixture seeded by Task 5's case-12 update step is missing or omits `crates/` | Case 12 input `?? crates/twinning-pipeline/src/foo.rs` regresses from in-scope to observed (no `crates/` in fallback always-include set) | back-compat (integration) | `bin/run-local-sweep-test.sh` case 12 — Task 5's case-12 update step seeds a `learned-rules/test-slug/project-profile.md` fixture under a tempdir `HARNESS_ROOT` whose `## File layout` lists `` `crates/` ``, restoring the original assertion `assert_partition implement_stage_sweeps_rust_source implementing ENG-14 1 0 0`. If the fixture is omitted or malformed, the case fails loudly with `expected: in=1 leaked=0 observed=0; got: in=0 leaked=0 observed=1` — implementation must include the seed step. |
| Same regression risk on pre-existing case 13 (`retrospective_pipeline_config_in_scope`) | Test invokes `partition_dirty_paths retrospective ENG-14` with `?? .pipeline-config/config.json` | The retrospective arm is NOT touched by ENG-95 (brainstorm §3 non-goal); case 13 still passes structurally — `stage_output_paths retrospective` returns the hardcoded list at lines 225-233 unchanged | back-compat (integration) | `bin/run-local-sweep-test.sh` case 13 — no edit required (the retrospective arm is untouched). Confirm by `grep -n "retrospective" bin/run-local-helpers.sh` post-edit; the arm body at lines 225-233 is bit-for-bit unchanged. |

## Test Strategy

### Unit (parser correctness — `bin/run-local-helpers-adversarial-test.sh`)

The 16 new cases per brainstorm §9.2 cover:
- **Format parsing**: em-dash split, multi-backtick prefix, no-em-dash handling.
- **Placeholder substitution**: `<slug>` substitution; non-`<slug>` placeholder rejection.
- **Path-syntax filters (D-006)**: absolute paths, `../` prefix, embedded `/../`,
  unbalanced backticks.
- **Slug-shape validation (D-002)**: regex-metachar slug → empty substitution
  → safe drop; gsub-escape pre-pass smoke.
- **Always-include union**: minimal profile still gets catalog; dedup with
  profile-listed `docs/`.
- **Override precedence**: empty-array override falls through to profile.
- **Diagnostic log behavior**: log fires once on empty profile; does NOT fire
  on valid profile.

Each case is self-contained (tempdir + fixture profile + post-source override
of `HARNESS_ROOT`/`PROJECT_SLUG` + restore). Pattern mirrors the existing
`qa_no_state_bleed_between_invocations` fixture at line 314.

### Integration (sweep partition — `bin/run-local-sweep-test.sh`)

The 11 new cases per brainstorm §9.1 exercise the full
`stage_output_paths → partition_dirty_paths` pipeline with realistic
stack-shaped profiles. Each fixture asserts the (in-scope, leaked, observed)
tuple for one representative dirty-path record under a Rust/Python/Go/
harness-self profile.

Back-compat: cases 12 (`implement_stage_sweeps_rust_source`) and 13
(`retrospective_pipeline_config_in_scope`) MUST be reviewed and updated as
called out in the Failure Mode table above. Case 12 likely needs a
`test-slug` profile fixture seeded under a tempdir `HARNESS_ROOT`; case 13
is structurally untouched (retrospective arm unchanged).

### Smoke / E2E (deferred — operator-driven)

No new smoke surface. The brainstorm's behavioural target is verified by
proxy through the integration fixtures:
- "Self-leak rate on non-Tauri targets drops to genuine bot leaks only" is
  a production-only metric trackable via `metrics/events.jsonl`'s
  `sweep-self-leak-out-of-scope` events. The test fixtures prove the
  classification mechanism is correct; the metric improvement requires real
  agent dispatches on non-Tauri targets, which is operator-driven and out
  of scope for the implement stage.

### Adversarial coverage

All 16 unit cases listed above carry adversarial inputs (path traversal,
absolute paths, regex-metachar slugs, unbalanced backticks). Two existing
defenses outside ENG-95's surface remain primary:
- `partition_dirty_paths` does literal string comparison (no regex), so a
  filename with regex metachars round-trips safely (existing behavior).
- `render-prompt.sh::append_project_profile` dies on missing-profile /
  unresolved-markers, so production agents never dispatch with a bad
  profile (the ENG-95 parser's fail-soft branch exists exclusively for
  the test-source path).

### Out-of-scope tests (deferred)

- **T1 structured-schema parser** (brainstorm §3 non-goal). When T1 ships,
  `_parse_profile_file_layout` becomes a switch on `schema_version` and
  the JSON branch needs its own fixture set. Not this PR.
- **Per-stage profile variants** (brainstorm §3 non-goal). If a future
  stack needs `ui` to touch `static/` but not `implementing`, T1's
  structured schema is the place. Not this PR.
- **Discovery-time linter for profile-format drift** (brainstorm §12
  Open Question 3). Currently silent skip on bullets without backticks;
  if this becomes a recurring failure mode, add a one-shot linter in a
  separate ticket. Not this PR.

## Self-review

Personas — feasibility, scope, coherence, design, product — will be run via
`compound-engineering:document-review` after this draft is committed.

Required gate: ≥4/5 PASS, zero P0 findings (codebase-fact errors, malformed
API contract block, missing `depends_on`/`touches` metadata, unbound Failure
Mode rows, File Structure entries feasibility cannot locate or justify as
new). Iterate at most 3 times.

Persona-specific notes:
- **Feasibility (gating)**: every code-level fact in §Assumption Inventory
  has a `path:line` reference verified against the current branch HEAD
  (`29d4ea4`). 17/17 facts verified.
- **Scope**: every Task and File Structure entry traces to a brainstorm
  §5 architecture section, AC line, or §10 CLAUDE.md update. No gold-plating.
- **Coherence**: Goal mirrors brainstorm §2; Backend Tasks 1+2+3 jointly
  realise §5.1+§5.2+§5.3; Test Strategy covers every Failure Mode row.
- **Design**: respects the harness's per-helper file boundary
  (`run-local-helpers.sh` is the sole owner of sweep-partition logic per
  CLAUDE.md "When wiring a new script" §); no new module, no cross-script
  dependency, no layering violation.
- **Product**: directly delivers what the Linear issue asked for —
  AC#1-#5 each map to a Task or File Structure entry per the table:
  - AC#1 (in-scope path list composed from File layout + always-include) →
    Tasks 1+2+3, integration fixtures in Task 5.
  - AC#2 (hardcoded Tauri lines removed) → Task 3's verify-grep step.
  - AC#3 (`_scope_allowlist_override` continues to win) → Task 3's
    verbatim preservation of lines 214-217 + Task 4's
    `override_empty_falls_through_to_profile` and Task 5's
    `profile_override_shadows_layout`.
  - AC#4 (test fixtures cover Rust workspace, Python, Go, harness-self) →
    Task 5's four stack-fixture cases.
  - AC#5 (CLAUDE.md "Sweep + scope partition (ENG-14)" section updated) →
    Task 6.
