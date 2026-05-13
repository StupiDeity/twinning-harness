---
linear: ENG-96
date: 2026-05-13
topic: Profile-driven lockfile resolution in scope-check.sh::is_benign
---

# ENG-96 — Make `scope-check.sh::is_benign` profile-driven

## 1. Goal

Replace the hardcoded `Cargo.lock` arm in `bin/scope-check.sh::is_benign` with
a profile-derived lockfile set parsed from
`learned-rules/$PROJECT_SLUG/project-profile.md::Build & test gates`, such that
`bash bin/scope-check-test.sh` passes new fixtures asserting auto-benign
treatment of the primary lockfile for at least the Rust (Cargo.lock),
Python/poetry (poetry.lock), Node/npm (package-lock.json), and Go (go.sum)
stacks named in the Linear issue's AC3.

## 2. Assumption Inventory

**Branch-base freshness:** `git fetch origin main` succeeds; `git log
--oneline HEAD..origin/main` is NON-EMPTY (the branch was cut from
`63a2764` before ENG-95 / ENG-93 / ENG-87 / ENG-94 / docs-agent / plan-agent-
hardening landed). Top of `origin/main` at plan time = `ffb0598` (Merge
pull request #88 from StupiDeity/feat/plan-agent-hardening). Task 0 below
rebases this branch onto `origin/main` before any other implementation
work; every `path:line` excerpt in this Inventory was verified against the
current worktree (pre-rebase), but Task 0's rebase explicitly mandates a
post-rebase re-verification step, and every Edit boundary in §5 uses
content anchors (per the plan template's "Edit-boundary keys" contract)
to survive any drift the rebase introduces.

**Sibling tickets pulled in by the rebase that touch related surfaces:**

* `1e5a251` (ENG-95) — adds `_parse_profile_file_layout` and
  `_always_include_paths` to `bin/run-local-helpers.sh`. ENG-96 does NOT
  consume either helper (per brainstorm D-007: ENG-96 builds parallel
  parsing logic targeting a different section, `## Build & test gates`,
  with a different precision contract). The post-rebase `is_benign` will
  coexist with ENG-95's catalog; the brainstorm's §1.1 verifies the
  decision.
* `b921eda` (plan-agent-hardening) — adds test-gate-closure, content-
  anchor, branch-freshness checks to the plan agent's pre-commit. This
  plan complies (Task 0 rebase, content-anchored Edit boundaries, sibling
  test-file sweep in §8.2 below).
* `ffb0598` umbrella merges — no behavioral change for ENG-96 surfaces.

**Codebase-fact verification (post-rebase line numbers may shift by ±2;
content anchors below survive):**

| Artifact | Verified at | Excerpt / signature |
| --- | --- | --- |
| `is_benign()` definition | `bin/scope-check.sh:73-92` | `is_benign() { local f="$1"; case "$f" in .pipeline/metrics/*) return 0 ;; Cargo.lock) return 0 ;; docs/knowledge/*) return 0 ;; docs/plans/*) return 0 ;; docs/brainstorms/*) return 0 ;; esac; ... if [[ "$f" =~ ^(crates/[^/]+)/tests/ ]]; then ... fi; return 1; }` |
| Hardcoded `Cargo.lock` case arm (to be removed) | `bin/scope-check.sh:78` | `Cargo.lock) return 0 ;;` |
| Crate-tests carve-out (OUT of scope — preserved verbatim) | `bin/scope-check.sh:83-90` | `# Integration tests under an in-scope crate. ... if [[ "$f" =~ ^(crates/[^/]+)/tests/ ]]; then local crate_dir="${BASH_REMATCH[1]}"; if grep -qE "^${crate_dir}/" <<<"$allowed_files$allowed_dirs" 2>/dev/null; then return 0; fi; fi` |
| `allowed_files` populated in main() | `bin/scope-check.sh:190` | `allowed_files="$(grep -oE '([a-zA-Z0-9_./-]+/)*[a-zA-Z0-9_.-]+\.[a-zA-Z0-9]+' <<<"$body" \| sort -u \|\| true)"` |
| `allowed_dirs` populated in main() | `bin/scope-check.sh:196-197` | `allowed_dirs="$(grep -oE '([a-zA-Z0-9_.-]+/){1,}' <<<"$body" \| awk '!/^[a-zA-Z0-9_-][a-zA-Z0-9_.-]*\.[a-zA-Z0-9]+\/$/' \| sort -u \|\| true)"` |
| `is_benign` call site (per-file loop) | `bin/scope-check.sh:235` | `if is_benign "$f"; then` |
| `is_benign` reads `$allowed_files$allowed_dirs` via dynamic scope | `bin/scope-check.sh:87` | `grep -qE "^${crate_dir}/" <<<"$allowed_files$allowed_dirs" 2>/dev/null` |
| Script-top docstring listing benign classes (must update) | `bin/scope-check.sh:15-21` | `# - BENIGN (silently allowed, ...): * .pipeline/metrics/** ... * Cargo.lock ...` |
| `HARNESS_ROOT` derivation | `bin/common.sh:9` | `HARNESS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"` |
| `PROJECT_SLUG` derivation + die | `bin/common.sh:47-53` | `[[ -n "$PROJECT_SLUG" ]] \|\| die "config.json::project.slug missing — run bin/setup.sh /path/to/target first"` |
| Profile path precedent | `bin/render-prompt.sh:149` | `local profile_path="$HARNESS_ROOT/learned-rules/$PROJECT_SLUG/project-profile.md"` |
| Source-and-stub pattern (test-author contract) | `bin/scope-check-test.sh:410-414` | `source "$SCRIPT_DIR/scope-check.sh" 2>/dev/null \|\| true` followed by post-source override of `SCRIPT_DIR` |
| `PROJECT_SLUG` test default | `bin/scope-check-test.sh:15` | `export PROJECT_SLUG="${PROJECT_SLUG:-test-slug}"` |
| Sentinel pattern | `bin/scope-check.sh:263-273` | `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then case "${1:-}" in has-scope-approval) ...; *) main "$@" ;; esac; fi` |
| Harness project-profile content (no PM tokens → empty set fallback) | `learned-rules/harness/project-profile.md:14-19` | `## Build & test gates\n- Build: (n/a) — interpreted bash; no compile step\n- Test: bash bin/dispatch-test.sh && ...` |
| ENG-95 `_always_include_paths` (assumed-new; on origin/main, not this branch) | `bin/run-local-helpers.sh:71-83` on origin/main | `_always_include_paths() { printf '%s\n' 'docs/' 'package.json' ... 'Cargo.lock' ... 'go.sum' ... 'Gemfile.lock'; }` — verified via `git show origin/main:bin/run-local-helpers.sh` |
| ENG-95 `_parse_profile_file_layout` (parallel parser; NOT reused per D-007) | `bin/run-local-helpers.sh:28-66` on origin/main | `_parse_profile_file_layout() { ... awk -v slug="$slug_esc" '/^## File layout[[:space:]]*$/ { in_section=1; next } ...' "$profile_path"; }` |
| Sibling test pinning `Cargo.lock` lock-by-name (will it regress?) | `bin/profile-allowlist-test.sh:113` | `TAURI_EXPECTED='Cargo.lock,Cargo.toml,bun.lock,bun.lockb,crates/,docs/,package-lock.json,package.json,src-tauri/,src/,tests/'` — this asserts the ENG-95 *sweep* surface (`stage_output_paths`), NOT `is_benign`; ENG-96 does not change that surface, so the assertion remains valid post-ENG-96. Confirmed by reading the test header (`Surface 1: stage_output_paths`). **NOT in File Structure**: deliberate exclusion documented in §8.2 below. |
| Sibling test for benign / Cargo.lock in scope-check-test.sh | `grep -n 'Cargo\.lock\|cargo' bin/scope-check-test.sh` → no matches | No existing fixture pins the `Cargo.lock`-hardcode behaviour; the brainstorm's T1 (added in this plan) becomes the first explicit pin and the back-compat anchor. |
| `is_benign` is only called from `main()` per-file loop | `grep -n is_benign bin/` → only `bin/scope-check.sh:74` (def) + `:235` (call) | Confirms no external consumer; refactor blast radius bounded to this file. |

**Branch-base note:** `git log --oneline HEAD..origin/main` returned ~68
commits at plan time. Task 0 (Rebase onto origin/main) is mandatory.
After Task 0 the implement agent MUST re-grep for `Cargo.lock`,
`is_benign`, and each anchor token in §5 below and confirm content
anchors still match.

## 3. File Structure

**Modified:**

- `bin/scope-check.sh` — refactor `is_benign`; add `_BENIGN_PATH_CLASSES` array, `SCOPE_BENIGN_LOCKFILES` array, `_lockfile_for_pm` / `_profile_lockfile_basenames` / `_resolve_profile_path` helpers; populate `SCOPE_BENIGN_LOCKFILES` from `main()`; update script-top docstring (lines 15–21) to reflect the new contract.
- `bin/scope-check-test.sh` — append fixtures T1–T9 (brainstorm D-006) using the existing HSA1/HSA2 source-and-stub pattern (for unit cases) and the case-2–6 sandbox pattern (for the end-to-end Python case).
- `CLAUDE.md` — minor paragraph update under "Sweep + scope partition (ENG-14)" (or a new dedicated row, plan-stage prerogative per brainstorm §3) pinning the new profile-driven contract. Brainstorm flagged this; scope persona at brainstorm time marked it "optional, only if new contract is non-obvious." This plan opts IN (one paragraph, ~6 lines): the contract IS non-obvious — future readers must know the lockfile set is profile-derived, not hardcoded, and must understand the test-only env-var override.

**Created:**

None. No new files.

**Out-of-scope but referenced:**

- `bin/profile-allowlist-test.sh` (origin/main, line 113) — asserts the **sweep** surface (`stage_output_paths`), not `is_benign`. The `Cargo.lock` token there pins a different code path (ENG-95's `_always_include_paths`). ENG-96 does NOT modify that surface or that test. Documented here so feasibility's test-gate-closure sweep can verify no implicit pin exists.
- `bin/run-local-helpers.sh` (origin/main) — `_always_include_paths` and `_parse_profile_file_layout` live here. ENG-96 builds parallel parsing logic in `scope-check.sh` per brainstorm D-007. Not touched.

## 4. API Contract

no new API surface

(The harness has no FE↔BE API surface. The "contract" widening is a script-internal function signature in `bin/scope-check.sh`, captured by the Edit boundaries and code snippets in §5.)

## 5. Backend Tasks

### Task 0: Rebase onto origin/main

- `depends_on: []`
- `touches: (the entire branch HEAD; resolves conflicts if any against ENG-95 / ENG-93 / ENG-94 / plan-agent-hardening landings)`

- [ ] Run `git fetch origin main`.
- [ ] Run `git rebase origin/main` from the worktree root.
- [ ] If a conflict surfaces in `bin/scope-check.sh` or `bin/scope-check-test.sh` (none expected — ENG-95 / ENG-93 / ENG-94 do not touch this file), resolve preserving the current pre-rebase content; ENG-96 will rewrite the affected regions in Tasks 1–7 below.
- [ ] If a conflict surfaces in `CLAUDE.md` (possible if plan-agent-hardening edited the same section), resolve manually: keep upstream's plan-agent-hardening content + plan to add ENG-96's paragraph in Task 8.
- [ ] Re-grep for `Cargo.lock`, `is_benign`, and the anchor tokens listed in Tasks 1–7 below; confirm they still match. If any anchor moved or was renamed, STOP and post a Linear comment on ENG-96 reporting the drift; do NOT proceed with stale anchors.
- [ ] Re-verify `bin/scope-check.sh::is_benign` definition is still in the line-78 region (±5 lines) and the surrounding docstring at lines 15–21 still names `Cargo.lock`. If either has been rewritten upstream (no evidence at plan time but check anyway), halt with a Linear note.

### Task 1: Add file-scope arrays + benign-path-class refactor scaffolding

- `depends_on: [0]`
- `touches: bin/scope-check.sh — top-of-file scope (between SCRIPT_DIR/source common.sh and find_canonical_plan)`

- [ ] In `bin/scope-check.sh`, AFTER the `export PIPELINE_WRITER=scope-check` line (currently line 43, content anchor: the literal line `export PIPELINE_WRITER=scope-check`) AND BEFORE the `find_canonical_plan()` function header (content anchor: `find_canonical_plan() {`), insert two file-scope array declarations and a brief comment block. Example:

  ```bash
  # ENG-96: benign-path classes are the four harness-owned globs that are
  # always benign regardless of stack (orchestrator owns these paths:
  # docs/{knowledge,plans,brainstorms}/, .pipeline/metrics/). Compare to
  # the lockfile array below, which is profile-derived and stack-conditional.
  _BENIGN_PATH_CLASSES=(
    '.pipeline/metrics/*'
    'docs/knowledge/*'
    'docs/plans/*'
    'docs/brainstorms/*'
  )

  # ENG-96: profile-derived lockfile basenames, populated once per main()
  # invocation by _profile_lockfile_basenames. Empty when no profile or no
  # recognised PM token (D-005 fallback). is_benign reads via dynamic scope.
  # TEST-AUTHOR CONTRACT: tests that source scope-check.sh and call
  # is_benign directly MUST populate this array themselves; the
  # production caller is main()'s per-file loop.
  SCOPE_BENIGN_LOCKFILES=()
  ```

  (Rationale: brainstorm D-001 / D-003 / D-006-design-P2. The "TEST-AUTHOR
  CONTRACT" comment satisfies design persona P2.)

- [ ] Verify the file still parses with `bash -n bin/scope-check.sh`.

### Task 2: Add `_lockfile_for_pm` helper

- `depends_on: [1]`
- `touches: bin/scope-check.sh — between Task 1's new arrays and the existing find_canonical_plan() definition`

- [ ] Insert `_lockfile_for_pm()` AFTER Task 1's `SCOPE_BENIGN_LOCKFILES=()` declaration (content anchor: the literal line `SCOPE_BENIGN_LOCKFILES=()`) and BEFORE the `find_canonical_plan() {` function header (content anchor: `find_canonical_plan() {`). Brainstorm D-002 token table is authoritative:

  ```bash
  # ENG-96: map a single PM CLI token (cargo, npm, ...) to one or more
  # canonical lockfile basenames, emitted one per line. Unknown tokens
  # emit nothing. The token table is the de-Tauri inference surface;
  # extending to a new stack is a single case-arm edit.
  # NOTE: npx is included as an inference signal — a profile mentioning
  # `npx playwright` implies npm-managed; npx itself is not a manager.
  # NOTE: the table is non-exhaustive; maven/gradle/composer/pdm/hatch
  # land via separate tickets when a stack adoption surfaces them.
  _lockfile_for_pm() {
    case "$1" in
      cargo)             printf '%s\n' 'Cargo.lock' ;;
      bun)               printf '%s\n' 'bun.lock' 'bun.lockb' ;;
      pnpm)              printf '%s\n' 'pnpm-lock.yaml' ;;
      yarn)              printf '%s\n' 'yarn.lock' ;;
      npm|npx)           printf '%s\n' 'package-lock.json' ;;
      poetry)            printf '%s\n' 'poetry.lock' ;;
      pipenv)            printf '%s\n' 'Pipfile.lock' ;;
      uv)                printf '%s\n' 'uv.lock' ;;
      go)                printf '%s\n' 'go.sum' ;;
      bundle|bundler)    printf '%s\n' 'Gemfile.lock' ;;
    esac
  }
  ```

- [ ] Verify the file still parses with `bash -n bin/scope-check.sh`.

### Task 3: Add `_resolve_profile_path` helper

- `depends_on: [2]`
- `touches: bin/scope-check.sh — immediately after _lockfile_for_pm`

- [ ] Insert `_resolve_profile_path()` AFTER the closing `}` of `_lockfile_for_pm` (content anchor: the function's closing `}` line, immediately preceded by the `esac`) and BEFORE `find_canonical_plan() {` (content anchor). Brainstorm D-004:

  ```bash
  # ENG-96: resolve the profile path. Honors a $SCOPE_CHECK_PROFILE_PATH
  # env-var override (TEST-ONLY convention; production callers must NOT
  # set this). Falls back to the canonical slug-relative path matching
  # bin/render-prompt.sh:149.
  _resolve_profile_path() {
    if [[ -n "${SCOPE_CHECK_PROFILE_PATH:-}" ]]; then
      printf '%s' "$SCOPE_CHECK_PROFILE_PATH"
      return 0
    fi
    printf '%s' "$HARNESS_ROOT/learned-rules/$PROJECT_SLUG/project-profile.md"
  }
  ```

  (Rationale: brainstorm D-004 documents the env-var as a test escape
  hatch. Security persona P1c — "loud comment, test-only convention" —
  satisfied by the inline `TEST-ONLY` annotation.)

- [ ] Verify the file still parses with `bash -n bin/scope-check.sh`.

### Task 4: Add `_profile_lockfile_basenames` parser

- `depends_on: [3]`
- `touches: bin/scope-check.sh — immediately after _resolve_profile_path`

- [ ] Insert `_profile_lockfile_basenames()` AFTER the closing `}` of `_resolve_profile_path` (content anchor: `_resolve_profile_path() {` block's terminating `}`) and BEFORE `find_canonical_plan() {` (content anchor):

  ```bash
  # ENG-96: parse `## Build & test gates` from a profile, word-grep for
  # known PM CLI tokens, emit canonical lockfile basenames (one per line,
  # sorted-unique). Returns 0 with empty stdout on:
  #   - missing profile file (D-005 case 1)
  #   - missing `## Build & test gates` section (D-005 case 2)
  #   - present section, no recognised PM token (D-005 case 3 — harness-self)
  #
  # SECURITY INVARIANT: $pm in `grep -qwE "$pm"` MUST originate from this
  # function's hardcoded `for pm in ...` loop. NEVER pass profile-derived
  # content into the regex — that would allow a malicious profile to
  # inject arbitrary patterns into the scope-check gate.
  _profile_lockfile_basenames() {
    local profile_path="$1"
    [[ -f "$profile_path" ]] || return 0

    local section
    section="$(awk '
      /^## Build & test gates[[:space:]]*$/ { in_section=1; next }
      in_section && /^## / { exit }
      in_section { print }
    ' "$profile_path")"
    [[ -n "$section" ]] || return 0

    local pm
    {
      for pm in cargo bun pnpm yarn npm npx poetry pipenv uv go bundle bundler; do
        if grep -qwE "$pm" <<<"$section"; then
          _lockfile_for_pm "$pm"
        fi
      done
    } | sort -u
  }
  ```

  (Rationale: brainstorm D-002 + D-005. Security P1a invariant is
  explicit in the comment block. Awk parser uses the same shape as
  ENG-95's `_parse_profile_file_layout` but targets `## Build & test
  gates` instead of `## File layout`.)

- [ ] Verify the file still parses with `bash -n bin/scope-check.sh`.

### Task 5: Refactor `is_benign` — drop hardcode, consume arrays

- `depends_on: [4]`
- `touches: bin/scope-check.sh — the is_benign() function body (current lines 73-92)`

- [ ] Replace the `is_benign()` function body. Content anchor BEFORE the change: the line `is_benign() {` immediately preceded by the comment `# Does $1 look benign regardless of plan?` (currently line 73; the anchor pair `# Does $1 look benign regardless of plan?` + `is_benign() {` is unique in the file). The replacement body iterates the file-scope arrays from Task 1 and preserves the crate-tests carve-out verbatim:

  ```bash
  # Does $1 look benign regardless of plan?
  is_benign() {
    local f="$1"
    # (a) stack-agnostic harness-owned path classes (ENG-96 D-001)
    local cls
    for cls in "${_BENIGN_PATH_CLASSES[@]}"; do
      # shellcheck disable=SC2053
      case "$f" in $cls) return 0 ;; esac
    done
    # (b) profile-derived lockfile basenames (ENG-96 D-002 / D-003)
    local lf
    for lf in "${SCOPE_BENIGN_LOCKFILES[@]}"; do
      [[ "$f" == "$lf" ]] && return 0
    done
    # (c) Rust crate-tests carve-out (OUT of ENG-96 scope per Linear; preserved verbatim).
    # Requires $allowed_files / $allowed_dirs from main scope.
    if [[ "$f" =~ ^(crates/[^/]+)/tests/ ]]; then
      local crate_dir="${BASH_REMATCH[1]}"
      if grep -qE "^${crate_dir}/" <<<"$allowed_files$allowed_dirs" 2>/dev/null; then
        return 0
      fi
    fi
    return 1
  }
  ```

  Notes for the implement agent:
  - The `case "$f" in $cls)` form intentionally relies on `$cls` being
    unquoted so the glob expands; the `# shellcheck disable=SC2053`
    line preserves intent against a literal-string warning.
  - The crate-tests block must be **byte-for-byte identical** to the
    pre-refactor block at lines 83–90 except for the new "(c)" /
    "OUT of ENG-96 scope" comment header. The implement agent should
    diff manually before committing.

- [ ] Verify the file still parses with `bash -n bin/scope-check.sh`.

### Task 6: Populate `SCOPE_BENIGN_LOCKFILES` from `main()`

- `depends_on: [5]`
- `touches: bin/scope-check.sh — main() function body, after the empty-set-exit-2 guard and before the diff-base resolution`

- [ ] In `main()`, insert a population block AFTER the empty-set guard's closing `fi` (content anchor: the `if [[ -z "$allowed_files$allowed_dirs" ]]; then ... exit 2; fi` block — anchor on its closing `fi` line immediately preceded by `exit 2`) and BEFORE the `# ENG-59: prefer origin/main as the diff base.` comment (content anchor: that exact comment header is unique in the file). Placing AFTER the empty-set guard means the warning log line does not fire when the script is about to `exit 2` for unparseable plans (design persona P2). Insert:

  ```bash
    # ENG-96: populate the profile-derived lockfile array once per dispatch.
    # Read in is_benign via dynamic scope (same pattern as $allowed_files /
    # $allowed_dirs). D-005: missing profile / missing section / no PM token
    # → empty array + one warning log line.
    local _profile_path
    _profile_path="$(_resolve_profile_path)"
    # mapfile not portable on bash 3.2; use read-while loop.
    SCOPE_BENIGN_LOCKFILES=()
    local _lf
    while IFS= read -r _lf; do
      [[ -n "$_lf" ]] && SCOPE_BENIGN_LOCKFILES+=("$_lf")
    done < <(_profile_lockfile_basenames "$_profile_path")
    if (( ${#SCOPE_BENIGN_LOCKFILES[@]} == 0 )); then
      log "scope-check: profile-derived lockfile set empty (path=$_profile_path; missing or no Build & test gates section); falling back to path-class benign only"
    fi
  ```

  (Rationale: brainstorm D-003 — memoize once per main(); D-005 — empty-
  set fallback + warning. macOS bash 3.2 lacks `mapfile`, so the read-
  while loop is required.)

- [ ] Verify the file still parses with `bash -n bin/scope-check.sh`.

### Task 7: Update script-top docstring (lines 15–21)

- `depends_on: [5]`
- `touches: bin/scope-check.sh — header comment block (current lines 14-24)`

- [ ] Replace the BENIGN bullet list. Content anchor BEFORE: the line `#   - BENIGN (silently allowed, counted toward exit 0):` (unique in file). Content anchor AFTER: the line `#   - NOTABLE: top-level path segment ...` (unique). Update the inner bullets to reflect that lockfiles are profile-derived:

  ```
  #   - BENIGN (silently allowed, counted toward exit 0):
  #       * `.pipeline/metrics/**`        — orchestrator-owned telemetry
  #       * `docs/knowledge/**`           — learned-rules / knowledge-doc updates
  #       * `docs/plans/**`               — plan docs (cannot self-reference pre-creation)
  #       * `docs/brainstorms/**`         — brainstorm docs (authored before the plan)
  #       * `<profile-derived lockfile>`  — lockfile churn from in-scope dep edits;
  #                                         basenames inferred per dispatch from
  #                                         learned-rules/<slug>/project-profile.md's
  #                                         `## Build & test gates` section (ENG-96).
  #                                         E.g. `cargo` token → `Cargo.lock`;
  #                                         `poetry` token → `poetry.lock`; etc.
  #       * `crates/<name>/tests/**`      — integration tests under an in-scope crate
  #                                         (Rust-specific; not yet generalised)
  ```

- [ ] Verify the file still parses with `bash -n bin/scope-check.sh`.

### Task 8: CLAUDE.md paragraph

- `depends_on: [5]`
- `touches: CLAUDE.md — "Sweep + scope partition (ENG-14)" section`

- [ ] In `CLAUDE.md`, AFTER the existing "Sweep + scope partition (ENG-14)" section's closing paragraph (content anchor: the section header `## Sweep + scope partition (ENG-14)` is unique; the section ends at the next `##` header — content anchor: the next `##` header line). Append a ~6-line paragraph before the next `##` boundary:

  ```markdown
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
  ```

### Task 9: Add unit fixtures T1–T7 + T9 to `scope-check-test.sh`

- `depends_on: [5, 6]`
- `touches: bin/scope-check-test.sh — append after the HSA1/HSA2 block, before the final summary print`

- [ ] Locate the insertion point. Content anchor BEFORE: the line `has_scope_approval ENG-HSA2 \` followed two lines later by the `fail_at "HSA2" "new-shape halt + new-shape decision approve not detected"` line (the closing of fixture HSA2 is unique in the file). Content anchor AFTER: the line `echo` followed by `echo "scope-check-test: passed=$PASS failed=$FAIL"` — the final summary block. Insert a new group between them.

- [ ] Add a new group header and seven cases (T1–T7 + T9). The fixtures source `scope-check.sh` (already sourced at line 414 in the HSA group), then for each case write a tmp profile to a path, export `SCOPE_CHECK_PROFILE_PATH`, call `_profile_lockfile_basenames` and `_resolve_profile_path` directly, and assert the array contents. Shape:

  ```bash
  # ─── Group: ENG-96 profile-driven lockfile inference ──────────────
  printf '\n--- ENG-96: profile-driven _profile_lockfile_basenames ---\n'

  ENG96_DIR="$(mktemp -d -t scope-check-eng96-XXXXXX)"
  trap 'rm -rf "$HSA_STUB_DIR" "$ENG96_DIR"' EXIT  # extend the existing trap

  _eng96_write_profile() {
    local path="$1" gates="$2"
    mkdir -p "$(dirname "$path")"
    cat > "$path" <<EOF
  ---
  slug: test
  ---
  ## Build & test gates

  $gates

  ## File layout
  - bin/
  EOF
  }

  _eng96_assert_basenames() {
    local case_name="$1" profile_path="$2" expected="$3"  # expected: comma-sep
    SCOPE_CHECK_PROFILE_PATH="$profile_path" \
      got="$(_profile_lockfile_basenames "$profile_path" | LC_ALL=C sort -u | paste -sd, -)"
    if [[ "$got" == "$expected" ]]; then
      pass_at "$case_name (expected=$expected got=$got)"
    else
      fail_at "$case_name" "expected=$expected got=$got"
    fi
  }

  # T1: Rust profile → Cargo.lock benign (back-compat anchor; security P1d)
  _eng96_write_profile "$ENG96_DIR/T1.md" '- Test: `cargo test --workspace`'
  _eng96_assert_basenames 'T1 Rust(cargo)→Cargo.lock' "$ENG96_DIR/T1.md" 'Cargo.lock'

  # T2: Node (npm) → package-lock.json
  _eng96_write_profile "$ENG96_DIR/T2.md" '- Test: `npm test` and `npm run lint`'
  _eng96_assert_basenames 'T2 Node(npm)→package-lock.json' "$ENG96_DIR/T2.md" 'package-lock.json'

  # T3: Python (poetry) → poetry.lock
  _eng96_write_profile "$ENG96_DIR/T3.md" '- Build: `poetry build`; Test: `poetry run pytest`'
  _eng96_assert_basenames 'T3 Python(poetry)→poetry.lock' "$ENG96_DIR/T3.md" 'poetry.lock'

  # T4: Go → go.sum (pins word-boundary correctness)
  _eng96_write_profile "$ENG96_DIR/T4.md" '- Test: `go test ./...`'
  _eng96_assert_basenames 'T4 Go(go)→go.sum' "$ENG96_DIR/T4.md" 'go.sum'

  # T5: Bun → both bun.lock and bun.lockb (multi-lockfile PM)
  _eng96_write_profile "$ENG96_DIR/T5.md" '- Test: `bun test`'
  _eng96_assert_basenames 'T5 Bun(bun)→bun.lock+bun.lockb' "$ENG96_DIR/T5.md" 'bun.lock,bun.lockb'

  # T6: Profile missing → empty set
  rm -f "$ENG96_DIR/T6-missing.md"  # ensure absent
  _eng96_assert_basenames 'T6 missing profile→empty' "$ENG96_DIR/T6-missing.md" ''

  # T7: Profile present, no PM tokens (harness-self shape) → empty
  _eng96_write_profile "$ENG96_DIR/T7.md" '- Test: `bash bin/dispatch-test.sh && bash bin/run-stage-test.sh`'
  _eng96_assert_basenames 'T7 bash-only profile→empty' "$ENG96_DIR/T7.md" ''

  # T9: Word-boundary regression — "tango" and "ego" must NOT match cargo/go
  _eng96_write_profile "$ENG96_DIR/T9.md" '- Build: `tango build`; Test: my-ego-tool'
  _eng96_assert_basenames 'T9 word-boundary tango/ego→empty' "$ENG96_DIR/T9.md" ''
  ```

  (Rationale: brainstorm D-006 table T1–T9. T9 covers the security
  persona's word-boundary regression concern + brainstorm Q4. Note the
  existing `trap 'rm -rf "$HSA_STUB_DIR"' EXIT` at line 408 must be
  extended to also clean up `$ENG96_DIR`.)

- [ ] Verify the test file still parses with `bash -n bin/scope-check-test.sh`.

### Task 10: Add end-to-end Python fixture (T8) + Go word-boundary end-to-end (T8b, product persona)

- `depends_on: [9]`
- `touches: bin/scope-check-test.sh — append after the Task 9 group, before the summary print`

- [ ] Insert AFTER the Task 9 group (content anchor: the last `_eng96_assert_basenames 'T9 ...'` invocation line; unique) and BEFORE the `echo` + `echo "scope-check-test: passed=$PASS failed=$FAIL"` summary block (content anchor):

  ```bash
  # ─── T8: end-to-end Python (poetry) — plan declares pyproject.toml,
  # branch modifies pyproject.toml + poetry.lock, scope-check exits 0.
  # Pins the full path through main() including the SCOPE_BENIGN_LOCKFILES
  # population (D-005 happy path).
  sandbox_t8="$(mktemp -d -t scope-check-t8-XXXXXX)"
  profile_t8="$ENG96_DIR/T8-profile.md"
  _eng96_write_profile "$profile_t8" '- Build: `poetry build`; Test: `poetry run pytest`'
  (
    cd "$sandbox_t8"
    git init -q
    git config user.email t@example.com
    git config user.name 'Test'
    mkdir -p docs/plans
    cat > docs/plans/2026-05-13-eng-test-96.md <<'PLAN'
  ---
  linear: ENG-T96
  ---
  ## File Structure
  - `pyproject.toml` — bump a dep version.
  PLAN
    printf '[tool.poetry]\nname = "x"\n' > pyproject.toml
    printf 'baseline\n' > poetry.lock
    git add -A
    git commit -qm "initial"
    git branch -m main
    git checkout -qb test-branch
    printf '[tool.poetry]\nname = "x-updated"\n' > pyproject.toml
    printf 'baseline + churn\n' > poetry.lock
    git commit -aqm "agent change"
  )
  t8_rc=0
  (cd "$sandbox_t8" && SCOPE_CHECK_PROFILE_PATH="$profile_t8" \
    bash "$SCRIPT_DIR/scope-check.sh" ENG-T96 test-branch) >/dev/null 2>&1 || t8_rc=$?
  [[ "$t8_rc" == "0" ]] \
    && pass_at "T8 end-to-end Python: pyproject.toml in-plan + poetry.lock benign → rc=0" \
    || fail_at "T8 end-to-end Python" "rc=$t8_rc (expected 0)"
  rm -rf "$sandbox_t8"

  # ─── T8b: end-to-end Go (product persona insurance) — pins go.sum
  # word-boundary behavior end-to-end through main(). Identical shape
  # to T8 but with the Go token + go.sum lockfile.
  sandbox_t8b="$(mktemp -d -t scope-check-t8b-XXXXXX)"
  profile_t8b="$ENG96_DIR/T8b-profile.md"
  _eng96_write_profile "$profile_t8b" '- Test: `go test ./...`'
  (
    cd "$sandbox_t8b"
    git init -q
    git config user.email t@example.com
    git config user.name 'Test'
    mkdir -p docs/plans
    cat > docs/plans/2026-05-13-eng-test-96b.md <<'PLAN'
  ---
  linear: ENG-T96B
  ---
  ## File Structure
  - `go.mod` — bump a module version.
  PLAN
    printf 'module x\n' > go.mod
    printf 'baseline\n' > go.sum
    git add -A
    git commit -qm "initial"
    git branch -m main
    git checkout -qb test-branch
    printf 'module x-updated\n' > go.mod
    printf 'baseline + churn\n' > go.sum
    git commit -aqm "agent change"
  )
  t8b_rc=0
  (cd "$sandbox_t8b" && SCOPE_CHECK_PROFILE_PATH="$profile_t8b" \
    bash "$SCRIPT_DIR/scope-check.sh" ENG-T96B test-branch) >/dev/null 2>&1 || t8b_rc=$?
  [[ "$t8b_rc" == "0" ]] \
    && pass_at "T8b end-to-end Go: go.mod in-plan + go.sum benign → rc=0" \
    || fail_at "T8b end-to-end Go" "rc=$t8b_rc (expected 0)"
  rm -rf "$sandbox_t8b"
  ```

  (Rationale: brainstorm D-006 T8 + product persona's optional Go end-
  to-end. T8b is fully independent of T8 — duplicating the sandbox
  scaffold is cheaper than refactoring into a helper function for two
  callers.)

- [ ] Verify `bash -n bin/scope-check-test.sh` passes.

### Task 11: Add awk-parser robustness fixture (security persona P1b)

- `depends_on: [10]`
- `touches: bin/scope-check-test.sh — between Task 9's T9 fixture and Task 10's T8 sandbox setup`

- [ ] Task 11 depends on Task 10 because its BEFORE anchor references the `sandbox_t8=` line that Task 10 creates. Insert immediately AFTER the T9 fixture (content anchor: `'T9 word-boundary tango/ego→empty'`) and BEFORE the Task 10 T8 sandbox setup (content anchor: `sandbox_t8="$(mktemp -d -t scope-check-t8-XXXXXX)"`):

  ```bash
  # T10: awk parser robustness — duplicate `## Build & test gates` header
  # exits at the first one (awk loops until next `## `, prints first body).
  # Asserts no crash + correct PM token detection on first section.
  cat > "$ENG96_DIR/T10.md" <<'EOF'
  ---
  slug: test
  ---
  ## Build & test gates

  - Test: `cargo test`

  ## Other heading

  ## Build & test gates

  - Test: `poetry run pytest`

  ## File layout
  - bin/
  EOF
  _eng96_assert_basenames 'T10 duplicate header→first section wins (cargo)' "$ENG96_DIR/T10.md" 'Cargo.lock'

  # T11: CRLF line endings — awk's default record separator handles \n,
  # so \r\n leaves trailing \r on captured tokens. Asserts behavior is
  # benign (no crash; either matches with \r-stripped or fails to match
  # cleanly — both acceptable). The contract: helper does NOT crash.
  printf -- '---\nslug: test\n---\n## Build & test gates\n\n- Test: `cargo test`\n\n## File layout\n- bin/\n' \
    | tr '\n' '~' | sed 's/~/\r\n/g' | tr -d '~' > "$ENG96_DIR/T11.md" || true
  # We don't assert a specific basename — we assert no crash.
  if _profile_lockfile_basenames "$ENG96_DIR/T11.md" >/dev/null 2>&1; then
    pass_at "T11 CRLF endings → no crash"
  else
    fail_at "T11 CRLF endings" "_profile_lockfile_basenames crashed on CRLF input"
  fi
  ```

  (Rationale: security persona P1b — large/binary/duplicate-header
  robustness. Large-file fixture omitted because awk streams; a
  duplicate-header fixture is the more informative case and CRLF is the
  most likely real-world malformation. The CRLF fixture does not pin
  the exact result — that's a deliberate "no crash" contract per §5
  Error handling row for malformed profiles.)

### Task 12: Run the full test suite and the pre-commit hook

- `depends_on: [7, 8, 11]`
- `touches: (no file mutation; CI gate enforcement)`

- [ ] Run `bash bin/scope-check-test.sh` and confirm passed=N failed=0 with the new T1–T11 fixtures present alongside the existing cases.
- [ ] Run the harness's full test gate per `learned-rules/harness/project-profile.md::Build & test gates`:
  ```
  bash bin/dispatch-test.sh && bash bin/run-stage-test.sh && \
  bash bin/poll-slot-test.sh && bash bin/scope-check-test.sh && \
  bash bin/verdict-handler-test.sh && bash bin/classify-failure-test.sh && \
  bash bin/halt-sprawl-test.sh && bash bin/halt-sprawl-adversarial-test.sh && \
  bash bin/linear-test.sh && bash bin/metrics-test.sh && \
  bash bin/mutex-test.sh && bash bin/setup-helpers-test.sh && \
  bash bin/render-prompt-test.sh && bash bin/phase-project-profile-test.sh && \
  bash bin/common-test.sh
  ```
  All gates must exit 0.
- [ ] Run `bash .githooks/pre-commit` from a staged-diff context (or accept the implicit `git commit` invocation) and confirm zero failures across the full suite plus the `KNOWN_BROKEN` allowlist.

## 6. Frontend Tasks

No frontend in this repo (per "Stack: Bash 3.2+ orchestration scripts… no application code"). Plan-stage UI agent is a no-op for ENG-96.

## 7. Failure Mode → Test Map

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
| --- | --- | --- | --- | --- |
| Profile file absent (D-005 case 1) | PROJECT_SLUG mismatch or fresh setup before `bin/setup.sh project-profile` runs | `_profile_lockfile_basenames` emits nothing; `SCOPE_BENIGN_LOCKFILES` is empty; `main()` logs `scope-check: profile-derived lockfile set empty (...)`; only path-class globs + crate-tests are benign | unit | T6 missing profile→empty |
| `## Build & test gates` section absent (D-005 case 2) | Profile exists but discovery never populated the section (operator misedit) | Same as above | (covered by T6 / T7 via empty-section behaviour) | T6 + T7 |
| No PM token in section (D-005 case 3 — harness-self) | Section contains only `bash bin/...` commands | Empty `SCOPE_BENIGN_LOCKFILES`; warning logged | unit | T7 bash-only profile→empty |
| Rust profile back-compat | Profile names `cargo` in any command | `Cargo.lock` is auto-benign (pre-ENG-96 behavior preserved) | unit | T1 Rust(cargo)→Cargo.lock |
| Node profile (npm) | Profile names `npm` | `package-lock.json` benign | unit | T2 Node(npm)→package-lock.json |
| Python profile (poetry) | Profile names `poetry` | `poetry.lock` benign | unit | T3 Python(poetry)→poetry.lock |
| Go profile | Profile names `go` (as a word, e.g. `go test`) | `go.sum` benign | unit | T4 Go(go)→go.sum |
| Bun profile | Profile names `bun` | both `bun.lock` and `bun.lockb` benign | unit | T5 Bun(bun)→bun.lock+bun.lockb |
| Word-boundary regression (`go` substring) | Profile prose mentions `tango`, `ego`, `mongo` etc. without the bare `go` token | `go.sum` NOT added (false-positive guard) | unit | T9 word-boundary tango/ego→empty |
| End-to-end happy path (Python) | Real git sandbox, plan declares `pyproject.toml`, branch modifies `pyproject.toml` + `poetry.lock`, profile names poetry | scope-check exits 0 (rc=0) | end-to-end (integration) | T8 end-to-end Python |
| End-to-end happy path (Go) | Same as T8 but with `go.mod` + `go.sum` and Go profile | scope-check exits 0 | end-to-end (integration) | T8b end-to-end Go |
| Duplicate `## Build & test gates` header in profile (security P1b) | Operator misedit / discovery double-write | Helper does NOT crash; awk stops at next `## ` so the first body wins | unit | T10 duplicate header→first section wins |
| CRLF line endings in profile (security P1b) | Profile authored on Windows / pasted from a CRLF source | Helper does NOT crash (behavior on the matched token is unconstrained — could match with `\r` stripped or not match cleanly; either is acceptable) | unit | T11 CRLF endings → no crash |
| Multi-PM monorepo (twinning shape: `bun` + `cargo`) | Profile names both PMs in `## Build & test gates` | Helper emits union: `Cargo.lock` + `bun.lock` + `bun.lockb` | (covered implicitly by T1 + T5 separately; explicit union test deferred — Q2 in brainstorm marks this resolved, no separate fixture) | (none — brainstorm Q2) |
| Subdirectory lockfile (`frontend/package-lock.json`) | Polyrepo monorepo writes lockfile in a sub-package | NOT auto-benign by `is_benign`; falls through to `is_notable` (same as pre-ENG-96 for `Cargo.lock` in workspace member subdirs — brainstorm Q6) | n/a — preserves existing behavior | (none — Q6 documents this is by design; plan's File Structure must declare the subdirectory manifest) |
| `SCOPE_CHECK_PROFILE_PATH` set to non-existent path (test misuse) | Test sets the env var to a path that doesn't exist | Same as D-005 case 1 (empty set + warning) | unit | T6 (the missing-path branch covers both default and override) |
| `is_benign` called from a sourced test context without `SCOPE_BENIGN_LOCKFILES` populated | Test author skips manual population | Array iteration is empty (zero elements), function returns 1 for any lockfile-shaped file unless it matches a path-class glob | (design persona P2 contract documented as code comment in Task 1; not a separately testable failure mode because every T1–T11 fixture in this plan calls `_profile_lockfile_basenames` directly and asserts its output, not `is_benign`'s composite output through SCOPE_BENIGN_LOCKFILES) | (covered by code comment in Task 1) |

## 8. Test Strategy

### 8.1 Layer coverage

* **Unit** — `_profile_lockfile_basenames` is exercised directly via `source bin/scope-check.sh` + `SCOPE_CHECK_PROFILE_PATH` fixtures (T1–T7, T9–T11). Eight fixtures cover the four Linear-AC-mandated stacks (Rust/Python/Node/Go), plus Bun (multi-lockfile PM), the three D-005 fallback paths, the word-boundary regression, and two awk robustness shapes.
* **Integration / end-to-end** — T8 (Python) and T8b (Go) run the full `scope-check.sh main()` path inside a tmp git sandbox, exercising the SCOPE_BENIGN_LOCKFILES population block (Task 6) and `is_benign`'s composite behavior end-to-end.
* **Smoke** — N/A for harness scripts (there is no compiled artifact); the pre-commit hook in Task 12 functions as the smoke gate.
* **Adversarial** — T9 (word-boundary), T10 (duplicate header), T11 (CRLF) cover the three security-persona robustness items (P1a is enforced via code comment, P1b via T10/T11, P1c via test-only env-var convention + comment, P1d via T1 back-compat anchor).

### 8.2 Test-gate closure sweep (mandatory per plan template)

Tokens this plan REMOVES from production code:

- `Cargo.lock)          return 0 ;;` — the literal case-arm body in `bin/scope-check.sh:78`.
- The substring `Cargo.lock` inside the script-top BENIGN docstring at `bin/scope-check.sh:17`.

Sibling test files containing either of those tokens (grep run against the post-rebase tree as of plan time):

| File | Tokens present | Listed in File Structure? | Rationale |
| --- | --- | --- | --- |
| `bin/scope-check-test.sh` | No matches for `Cargo.lock` or `cargo` (verified by `grep -n` at plan time) | Yes (Task 9–11 fixtures) | The test currently does NOT pin the soon-to-be-removed `Cargo.lock` hardcode — there is nothing to invert. Task 9's T1 fixture becomes the FIRST explicit pin of the Rust back-compat behavior. |
| `bin/profile-allowlist-test.sh` (line 113 contains `Cargo.lock` inside `TAURI_EXPECTED`) | `Cargo.lock` substring present | **Intentionally NOT listed in File Structure** | The token there pins ENG-95's `stage_output_paths` sweep allowlist (a different surface). ENG-96 does not modify that surface or its helpers. The token is benign on a different code path; the assertion remains valid post-ENG-96. Verified by reading the test header: `# Surface 1: stage_output_paths`. |
| `bin/run-local-helpers.sh` (post-rebase, line ~222 inside `_always_include_paths`) | `Cargo.lock` substring present | **Intentionally NOT listed in File Structure** | Same rationale — ENG-95's catalog is consumed by `stage_output_paths`, not by `is_benign`. ENG-96 D-007 explicitly preserves no shared catalog. |

No other bin/*-test.sh file matches `Cargo.lock` or `is_benign` (verified by `grep -rln 'Cargo\.lock\|is_benign' bin/*-test.sh` at plan time). No test-gate closure defect.

### 8.3 Self-review record

This plan is submitted for the document-review skill personas (feasibility, scope, coherence, design, product) per the completion checklist. The brainstorm already passed a 6-persona review (design, security, scope, coherence, product, feasibility — all PASS, 0 P0); items 1–8 surfaced by that review are encoded as plan tasks or code comments:

| Brainstorm review item | Encoding in this plan |
| --- | --- |
| 1. Security P1a: $pm-must-come-from-hardcoded-loop invariant | Code comment in Task 4 (`SECURITY INVARIANT:` block) |
| 2. Security P1c: SCOPE_CHECK_PROFILE_PATH test-only convention | Code comment in Task 3 + `TEST-AUTHOR CONTRACT` comment in Task 1 + CLAUDE.md paragraph in Task 8 |
| 3. Security P1b: awk parser robustness fixtures | Task 11 (T10 duplicate header + T11 CRLF) |
| 4. Security P1d: Tauri-back-compat T1 is mandatory | Task 9 T1 fixture |
| 5. Product: optional Go end-to-end fixture | Task 10 T8b |
| 6. Coherence: `npx` inclusion note | Code comment in Task 2 |
| 7. Design P2: test-author contract for SCOPE_BENIGN_LOCKFILES | Code comment in Task 1 |
| 8. Design P2: maven/gradle/composer/pdm/hatch blind-spot | Code comment in Task 2 |

All eight brainstorm-surfaced items are encoded as concrete plan content (code comments, fixtures, or CLAUDE.md text) so the implement and QA agents have unambiguous targets.
