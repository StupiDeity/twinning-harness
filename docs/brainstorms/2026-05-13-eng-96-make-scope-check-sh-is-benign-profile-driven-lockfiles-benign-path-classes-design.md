---
linear: ENG-96
title: Make scope-check.sh::is_benign profile-driven (lockfiles + benign-path classes)
date: 2026-05-13
status: draft
---

# ENG-96 — Make `scope-check.sh::is_benign` profile-driven (lockfiles + benign-path classes)

## 1. Problem

`bin/scope-check.sh::is_benign` (lines 74–92) hardcodes `Cargo.lock` as
auto-benign, alongside four always-benign path classes
(`.pipeline/metrics/*`, `docs/knowledge/*`, `docs/plans/*`,
`docs/brainstorms/*`). The hardcoding bakes a Tauri assumption into the
scope gate: any non-Rust target whose agent legitimately edits a
manifest file (`pyproject.toml`, `package.json`, `go.mod`, `Gemfile`,
etc.) and triggers an automatic regeneration of its lockfile
(`poetry.lock`, `package-lock.json`, `go.sum`, `Gemfile.lock`) gets a
SEVERE scope-violation from `scope-check.sh` even though the lockfile
churn is structurally the same as the Cargo case the carve-out was
built for.

Today, `is_benign` looks like this (`bin/scope-check.sh:74-92`):

```bash
is_benign() {
  local f="$1"
  case "$f" in
    .pipeline/metrics/*) return 0 ;;
    Cargo.lock)          return 0 ;;
    docs/knowledge/*)    return 0 ;;
    docs/plans/*)        return 0 ;;
    docs/brainstorms/*)  return 0 ;;
  esac
  # Integration tests under an in-scope crate.
  if [[ "$f" =~ ^(crates/[^/]+)/tests/ ]]; then
    local crate_dir="${BASH_REMATCH[1]}"
    if grep -qE "^${crate_dir}/" <<<"$allowed_files$allowed_dirs" 2>/dev/null; then
      return 0
    fi
  fi
  return 1
}
```

This is the fourth surface in the ENG-92 "de-Tauri" umbrella:

* **ENG-93 / T1 (done).** Added `## Tool allowlist` to the profile
  schema (`schema_version: 2`).
* **ENG-94 / T2 (in-progress).** Make `dispatch.sh::allowed_tools_for`
  consume the profile.
* **ENG-95 / T3 (done; on `main`, not yet in this branch).** Made
  `run-local-helpers.sh::stage_output_paths` consume the profile's
  `## File layout` section and added the stack-agnostic catalog
  `_always_include_paths` (lockfiles + `docs/`).
* **ENG-96 / T4 (this brainstorm).** Make `scope-check.sh::is_benign`
  profile-driven.

ENG-95 establishes the pattern this brainstorm follows: a small parser
(`_parse_profile_file_layout`) reads the profile, a stack-agnostic
catalog (`_always_include_paths`) supplies the fallback floor, and the
existing helper composes the two. ENG-96 adds the symmetric piece for
the lockfile half — but the issue is specific that the lockfile set
**derives from the package manager named in `## Build & test gates`**
(precision goal), so we infer lockfile basenames from PM tokens rather
than always unioning the full catalog.

### 1.1 Scope boundary set by the Linear issue

The Linear issue is explicit about what's IN and OUT:

* IN: refactor `is_benign`, profile-derived lockfile resolution helper,
  test coverage for non-Tauri profiles.
* OUT: the **crate-tests carve-out** at lines 83–89. That carve-out
  ("integration tests under an in-scope crate are auto-benign even
  though the plan doesn't enumerate `tests/*`") is more nuanced —
  equivalent patterns for other stacks (Python `tests/conftest.py`,
  Node `__tests__/foo.spec.ts`, Go `*_test.go`) need their own
  brainstorm — and is left as-is. **A separate ticket may be filed
  later.**

This brainstorm honors that boundary: the crate-tests block is
preserved verbatim. Only the basename-shaped `case` arms in lines
76–82 and the implicit `Cargo.lock` row are touched.

## 2. Decisions

- **D-001. Compose the benign set as: (a) stack-agnostic *path-class*
  globs (unchanged) + (b) profile-derived *lockfile* basenames + (c)
  the Rust crate-tests regex carve-out (unchanged).** The hardcoded
  `Cargo.lock` arm is removed; in its place, `is_benign` consults a
  list populated once per invocation from
  `learned-rules/$PROJECT_SLUG/project-profile.md::Build & test gates`.

  *Why three independent layers.* The path-class globs (`docs/plans/`,
  `docs/brainstorms/`, `docs/knowledge/`, `.pipeline/metrics/`) are
  **harness-owned**: they exist on every project regardless of stack
  and are tied to orchestrator semantics (plan stage writes
  `docs/plans/`; retrospective stage writes `docs/knowledge/`;
  orchestrator writes `.pipeline/metrics/`). Mixing them into the
  profile-derived list would couple harness internals to the per-stack
  profile, which CLAUDE.md §"When wiring a new script" warns against
  (profile is per-target stack context, harness state lives in
  HARNESS_ROOT/PROJECT_STATE_DIR).

  The lockfile basenames are **stack-conditional**: precise membership
  depends on which package manager(s) the project uses, which is what
  the Linear issue asks us to encode.

  The Rust crate-tests block is **explicitly out of scope** per the
  Linear issue's OUT list (line 14). Leave the regex untouched.

  Rejected alternative (collapse all three into the profile). Rejected:
  the path-class globs are harness invariants, not per-stack facts.
  Moving them into the profile would force every operator to declare
  `docs/plans/`, `docs/brainstorms/`, `docs/knowledge/`,
  `.pipeline/metrics/` in their profile — and a profile that omits one
  silently breaks scope-check for that stage's outputs. The trade-off
  worsens with each future harness-owned path. Compare to ENG-95
  D-003's `_always_include_paths` catalog, which is explicitly
  hardcoded for the same reason ("Hardcoded by design — T1's
  structured schema may eventually move this catalog into per-stack
  profiles. False-positive scope is bounded: every entry is a single
  literal top-level filename (or `docs/`), never granting a broader
  directory prefix.").

  Rejected alternative (union profile-derived lockfiles with the full
  ENG-95 `_always_include_paths` catalog as a permissive fallback).
  Rejected: violates the Linear issue's precision requirement
  ("Each supported stack's primary lockfile is auto-benign **when the
  profile names that stack**" — emphasis added). A Rust project that
  somehow has a stray `package-lock.json` checked in should still see
  scope-check flag it. The catalog union is the simpler design — see
  §6 "Open questions" Q1 for the explicit trade-off.

- **D-002. Lockfile inference helper: parse `## Build & test gates`,
  word-grep for known PM CLI tokens, emit canonical lockfile
  basenames.** New helper `_profile_lockfile_basenames` in
  `bin/scope-check.sh`. Token → lockfile mapping (initial):

  | PM CLI token (word) | Lockfile basenames emitted |
  | --- | --- |
  | `cargo` | `Cargo.lock` |
  | `bun` | `bun.lock`, `bun.lockb` |
  | `pnpm` | `pnpm-lock.yaml` |
  | `yarn` | `yarn.lock` |
  | `npm`, `npx` | `package-lock.json` |
  | `poetry` | `poetry.lock` |
  | `pipenv` | `Pipfile.lock` |
  | `uv` | `uv.lock` |
  | `go` | `go.sum` |
  | `bundle`, `bundler` | `Gemfile.lock` |

  Matching is **word-boundary** (`grep -qwE "$pm"`) so e.g. "go" does
  not match inside "gone" / "longopt" / "tango"; it does match `go
  test`, `go build`, and the bare token (because `.` and whitespace
  are word boundaries in POSIX grep).

  *Why a small explicit token table, not a structured profile field.*
  Three reasons:

  1. The Linear issue says "lockfile inferred from package manager" —
     the inference is the design.
  2. The discovery agent already populates `## Build & test gates` with
     the actual build/test commands; adding a parallel "lockfiles:"
     field would require both a schema change (ENG-93 already shipped
     schema v2 without it) and a discovery-prompt update.
  3. The token mapping is small (10 PM tokens, 11 lockfile basenames)
     and stable. Adding a new stack is a 1-line edit to
     `_lockfile_for_pm`. Compare to ENG-95's `_always_include_paths`
     which uses the same shape (a hardcoded list of literals).

  Rejected alternative (add a structured `## Lockfiles` section to the
  profile schema). Rejected: schema churn, requires discovery-prompt
  update, and the inference is trivial. If a target ever has a
  non-standard lockfile name, operators can add it via a separate
  override path (see D-005 below).

  Rejected alternative (heuristic regex `grep -E '[a-zA-Z]+\.(lock|sum)'`
  over the section). Rejected: too permissive (would match e.g.
  arbitrary filenames inside backticks in descriptive prose), and
  doesn't encode the PM→lockfile mapping which is the design point.

  Rejected alternative (reuse ENG-95's `_always_include_paths` catalog
  directly). Rejected per D-001's precision requirement; revisit if
  the precision argument doesn't hold up in practice (see §6 Q1).

- **D-003. Memoize the profile-derived lockfile list once per `main()`
  invocation, store in a script-scope array `SCOPE_BENIGN_LOCKFILES`.**
  `is_benign` is called once per changed file in `main()`'s loop
  (`bin/scope-check.sh:223-245`). Re-parsing the profile per file
  would shell-out N times per dispatch (each `awk` + `grep` is a fork
  on macOS bash 3.2). Populate the array in `main()` immediately
  after `allowed_files` / `allowed_dirs` are computed (lines
  180–197); read it in `is_benign`.

  Bash dynamic-scoping note: array is declared at file scope (top of
  script), populated in `main()`, read in `is_benign` called from
  `main()`. Same pattern as `allowed_files` / `allowed_dirs` today,
  which `is_benign` already reads via dynamic scope
  (`bin/scope-check.sh:87`).

  Rejected alternative (compute in `is_benign` on first call, cache in
  a guard variable). Rejected: stateful function-local caching in
  bash 3.2 needs a `declare -g` (bash 4+) or a top-level array. The
  top-level array is simpler.

- **D-004. Path resolution: `$HARNESS_ROOT/learned-rules/$PROJECT_SLUG/project-profile.md`.
  Honor a `SCOPE_CHECK_PROFILE_PATH` env-var override (tests only).**
  The canonical path matches the precedent established by
  `bin/render-prompt.sh:149` and ENG-95's `_parse_profile_file_layout`
  call site (on `main`). The env-var override is a test escape hatch:
  end-to-end fixtures cannot easily plant files into the real
  `HARNESS_ROOT/learned-rules/<slug>/` without polluting the repo, and
  the existing `scope-check-test.sh` runs cases 2–6 as
  `(cd $sandbox; bash $SCRIPT_DIR/scope-check.sh …)` subshells that
  inherit the env-var.

  *Why not modify `common.sh` to honor a pre-set `HARNESS_ROOT`.*
  Touching common.sh widens blast radius far beyond ENG-96 — every
  script that sources common.sh would suddenly accept an external
  HARNESS_ROOT override. The narrow `SCOPE_CHECK_PROFILE_PATH` env var
  is opt-in and scoped to this one file.

  Rejected alternative (have tests plant fixture files at
  `$HARNESS_ROOT/learned-rules/test-slug/project-profile.md` and clean
  up afterward). Rejected: leaves litter when a test fails mid-run
  (no `trap EXIT` shields a `bash $SCRIPT_DIR/...` subshell crash);
  collides with concurrent test runs; relies on a hard-coded
  PROJECT_SLUG that might shadow a real slug under
  `learned-rules/`.

  Rejected alternative (refactor `_resolve_profile_path` into a
  sourced helper test can override). Rejected: cases 2–6 spawn fresh
  bash subshells via `bash $SCRIPT_DIR/scope-check.sh`, where
  post-source overrides don't take effect. Env vars cross the
  subshell boundary cleanly.

- **D-005. Missing / malformed profile → empty lockfile set, log
  warning, proceed.** Three failure modes the helper must tolerate
  without dying:

  1. Profile file does not exist (PROJECT_SLUG mismatch, fresh setup).
  2. Profile file exists but `## Build & test gates` section is
     missing.
  3. Section exists but no PM token matches.

  In all three, `_profile_lockfile_basenames` emits nothing.
  `is_benign` then only short-circuits on the path-class globs and
  the crate-tests carve-out — i.e., **strictly more restrictive than
  today's hardcoded behavior** (today auto-allows `Cargo.lock` even
  on a Python project; post-ENG-96 with no profile, nothing
  lockfile-shaped is auto-allowed). The trade-off is acceptable:
  setup is a prerequisite for the harness running anyway, and the
  warning surfaces a misconfiguration faster than silently being
  permissive.

  Emit one `log` line per dispatch (not per file) when profile is
  absent: `scope-check: profile-derived lockfile set empty (path=...; missing or no Build & test gates section); falling back to path-class benign only`.

  Rejected alternative (fall back to the ENG-95
  `_always_include_paths` catalog on profile-missing). Rejected
  per D-001's precision requirement and to keep one source of truth
  per surface. Operators can resolve the missing-profile case by
  running `bash bin/setup.sh project-profile` — same remediation
  path render-prompt.sh:152 documents.

- **D-006. Test coverage: unit tests for the helper (in-process,
  fixture-driven via `source` + env-var override) + end-to-end
  integration test for one non-Rust stack (Python/poetry).** The
  Linear issue's AC line 3 requires fixtures for "at least: Rust
  (Cargo.lock), Python (poetry.lock), Node (package-lock.json), Go
  (go.sum)." Four unit cases cover the four stacks; one end-to-end
  case pins the integration (Python is chosen because it's the most
  different from the current Rust default — establishes the
  generalization).

  Test inventory (added to `bin/scope-check-test.sh`):

  | # | Case | Shape | What it pins |
  | --- | --- | --- | --- |
  | T1 | Rust profile → `Cargo.lock` benign | unit (`source` + override) | Back-compat: today's hardcoded behavior is reproduced when profile has `cargo test` |
  | T2 | Node profile (`npm` token) → `package-lock.json` benign | unit | Generalization to npm |
  | T3 | Python profile (`poetry` token) → `poetry.lock` benign | unit | Generalization to poetry |
  | T4 | Go profile (`go` token) → `go.sum` benign | unit | Generalization to Go; pins word-boundary correctness |
  | T5 | Bun profile (`bun` token) → both `bun.lock` and `bun.lockb` benign | unit | Multi-lockfile PM (Bun has two formats) |
  | T6 | Profile missing → empty lockfile set | unit | D-005 fallback |
  | T7 | Profile present, no PM tokens (harness-self shape) → empty set | unit | D-005 same-output path; pins no-false-match on bash-only profiles |
  | T8 | End-to-end Python: plan declares `pyproject.toml`, branch modifies both `pyproject.toml` + `poetry.lock`, scope-check passes rc=0 | end-to-end (subshell) | Pins the full path through `main()` |
  | T9 | End-to-end: word-boundary regression — profile contains "tango cargo" or "ego" with no lockfile actually present (negative case) | unit | Pins that `cargo` matches only as a whole word |

  Existing cases 1–6 + QA-Adv-1..4 + HSA1/HSA2 are unaffected
  (they don't exercise `is_benign` directly except as a side effect
  of the per-file loop, and none of them produce a lockfile-shaped
  diff).

- **D-007. Cross-stage interaction with ENG-95
  `_always_include_paths`: NONE.** ENG-95's catalog lives in
  `bin/run-local-helpers.sh` and is consumed by `stage_output_paths`
  (the sweep partitioner's allowlist, post-stage). ENG-96's
  helper lives in `bin/scope-check.sh` and is consumed by
  `is_benign` (the scope-check gate that runs after agent dispatch
  and before sweep).

  *Why no shared catalog.* The two surfaces have **different
  precision contracts**:

  | Surface | Catalog shape | Precision contract |
  | --- | --- | --- |
  | `_always_include_paths` (ENG-95) | Full union of every supported lockfile + `docs/` | Stack-agnostic floor; any catalog lockfile is sweep-in-scope on every project. The catalog is the "stack-agnostic always-include" mentioned in ENG-95 D-003. |
  | `_profile_lockfile_basenames` (ENG-96) | Subset derived from this project's PM tokens | Stack-conditional precision; only this project's lockfiles are scope-check-benign. |

  Sharing the catalog would require breaking one of the two
  contracts. Per D-001 we honor the Linear issue's precision
  requirement here; ENG-95 already established the permissive floor
  for its surface.

  Future direction: if T1's structured `## Tool allowlist` schema
  (schema_version: 2) is extended in a future ticket to declare
  package managers explicitly (e.g., `package_managers: [cargo,
  bun]`), both surfaces could consume that same field. Out of scope
  for ENG-96.

## 3. Architecture (where code goes)

```
bin/scope-check.sh
  ├── (new) _BENIGN_PATH_CLASSES — top-level array of always-benign
  │     glob prefixes; replaces lines 77, 79–81 case arms.
  ├── (new) SCOPE_BENIGN_LOCKFILES — top-level array, populated in main().
  ├── (new) _lockfile_for_pm() — switch from PM token to one or more
  │     canonical lockfile basenames; emits nothing for unknown tokens.
  ├── (new) _profile_lockfile_basenames() — reads profile path arg,
  │     parses `## Build & test gates`, word-greps PM tokens, emits
  │     canonical basenames one per line, sorted-unique.
  ├── (new) _resolve_profile_path() — env-var override
  │     (SCOPE_CHECK_PROFILE_PATH) → slug-relative default
  │     ($HARNESS_ROOT/learned-rules/$PROJECT_SLUG/project-profile.md).
  ├── (modified) is_benign() — drop Cargo.lock arm; iterate
  │     _BENIGN_PATH_CLASSES; iterate SCOPE_BENIGN_LOCKFILES; keep
  │     the crates/<name>/tests/* regex carve-out.
  └── (modified) main() — between line 197 (allowed_dirs assignment)
        and line 218 (changed=...), call
        _profile_lockfile_basenames to populate SCOPE_BENIGN_LOCKFILES.

bin/scope-check-test.sh
  ├── (new) cases T1–T9 above; unit tests follow the HSA1/HSA2 fixture
  │     pattern (source scope-check.sh, set up tmp profile, call helper).
  └── (new) T8 end-to-end: extends the case-2-6 sandbox pattern with
        an additional SCOPE_CHECK_PROFILE_PATH env-var export before
        the `bash $SCRIPT_DIR/scope-check.sh ...` invocation.
```

No new files. No changes to dispatch.sh, run-local-helpers.sh,
poll.sh, run-stage.sh, common.sh, linear.sh, or pipeline.sh. No
changes to AGENT_PROMPTS.md.

CLAUDE.md gets one paragraph update under "Sweep + scope partition
(ENG-14)" — or a new dedicated row — pinning the new contract. (Plan
stage decides exact wording; brainstorm flags the doc-edit.)

## 4. Data flow

```
$HARNESS_ROOT/learned-rules/$PROJECT_SLUG/project-profile.md
  │  (or $SCOPE_CHECK_PROFILE_PATH if set — tests only)
  ▼
_resolve_profile_path()
  │  emits path on stdout
  ▼
_profile_lockfile_basenames "$path"
  │  awk extracts ## Build & test gates section
  │  loop: for pm in cargo bun pnpm yarn npm npx poetry pipenv uv go bundle bundler
  │    grep -qwE "$pm" → _lockfile_for_pm "$pm"
  │  sort -u
  ▼
SCOPE_BENIGN_LOCKFILES (array, populated once in main())
  ▼
is_benign($f)
  for cls in $_BENIGN_PATH_CLASSES; [[ $f == "$cls"* ]] → return 0
  for lf in $SCOPE_BENIGN_LOCKFILES; [[ $f == "$lf" ]] → return 0
  if $f =~ ^crates/<name>/tests/ && crate is in scope → return 0
  return 1
```

`is_benign` is called from `main()`'s per-file loop
(`bin/scope-check.sh:235`). Its inputs unchanged: the changed file
basename ($1) and the dynamic-scope variables `allowed_files` /
`allowed_dirs` (consumed only by the crate-tests block).

## 5. Error handling

| Failure | Handler |
| --- | --- |
| Profile path resolves to a non-existent file (D-005 case 1) | `_profile_lockfile_basenames` returns 0 silently; `main()` logs `scope-check: profile-derived lockfile set empty (...)`; `SCOPE_BENIGN_LOCKFILES` stays empty; only path-class + crate-tests benign |
| Profile file exists, no `## Build & test gates` section (D-005 case 2) | Same as above |
| Section exists, no recognised PM token (D-005 case 3 — e.g., harness-self profile, all `bash` commands) | Same as above |
| `awk` / `grep` not on PATH | `common.sh::require_bin` already gates this at script entry (any subsequent script using these tools shares the guarantee) |
| `PROJECT_SLUG` unset | `common.sh:53` already dies with "config.json::project.slug missing"; we never reach `_resolve_profile_path` |
| `HARNESS_ROOT` unset | `common.sh:9` always resolves from `${BASH_SOURCE[0]}/..`; if `bin/common.sh` is missing the whole script can't be sourced |
| `SCOPE_CHECK_PROFILE_PATH` set to a non-existent path (test misuse) | Same as D-005 case 1 — empty lockfile set + log warning |
| Profile contains a PM token in **prose** (e.g. inside a description backtick: `*(uses ` + `npm` + ` install on CI only)*`) | Currently treated as a positive match. False-positive cost is one extra lockfile in the benign set; the file is still only benign if it appears in the diff under that exact basename. Acceptable, see §6 Q3. |
| Test fixture sets `SCOPE_CHECK_PROFILE_PATH` to a profile with malformed YAML frontmatter | Profile parser doesn't read frontmatter; only the `## Build & test gates` section body. No-op |

The scope-check semantics already documented in `bin/scope-check.sh:9-13`
are preserved: exit 0 (clean / only benign), exit 1 (NOTABLE), exit 2
(plan parse failure), exit 3 (SEVERE). None of those exit codes are
affected by the profile-parsing path.

## 6. Edge cases & open questions

**Q1 (open).** Should we union profile-derived lockfiles with the
ENG-95 `_always_include_paths` catalog as a permissive fallback (i.e.,
"profile-derived precision, catalog floor")? Pro: zero false-positive
halts when a Rust project legitimately commits a stray
`package-lock.json` (shouldn't happen, but if it does the catalog
union absorbs it). Con: violates Linear AC line 2 ("Each supported
stack's primary lockfile is auto-benign **when the profile names that
stack**"). Default in this brainstorm: NO union. Revisit if false
positives appear in practice.

**Q2 (resolved).** What about projects that pin multiple package
managers (e.g., a monorepo with `cargo` AND `bun`, or `npm` AND
`pnpm`)? Resolution: the helper emits union of all matching PM tokens'
lockfiles. Twinning today is exactly this shape (`bun` + `cargo`); the
matrix above naturally handles it. Already implicit in D-002's "emit
one canonical lockfile basename per line for every package manager
whose CLI token appears as a word in the section."

**Q3 (open, low-priority).** PM-token false-positive in prose. The
section body is markdown; comments inside `*(...)*` or backticks may
mention tools as cross-references rather than active build commands.
Example fixture: `Test: \`cargo test\` (jest is run by CI but not
locally)` — `grep -qwE jest` would not fire today because we don't
have a jest token in the table, but if jest were added, the
cross-reference would falsely match. Mitigation if observed:
restrict to the value-side of `- Test:` / `- Build:` / `- Lint:`
lines (skip parenthetical commentary). Defer until observed.

**Q4 (resolved).** Word boundary correctness for `go`. POSIX
`grep -w` treats `[A-Za-z0-9_]` as word characters. The bash test
`echo "ego module" | grep -qwE 'go'` exits non-zero (no match);
`echo "go test" | grep -qwE 'go'` exits zero (match);
`echo "tango" | grep -qwE 'go'` exits non-zero. Verified at
brainstorm time on macOS BSD grep.

**Q5 (resolved).** What if a future stack adds a new PM token (e.g.,
`maven`, `gradle`, `composer`, `pdm`, `hatch`)? Adding a stack is a
two-line edit to `_lockfile_for_pm` (one case arm) and the iteration
list in `_profile_lockfile_basenames` (one token in the `for pm in
...` loop). The retrospective agent's per-stage learned-rules already
have a path for this kind of catalog drift; if a stack gets adopted
and starts halting on scope, file a separate ticket adding the token.

**Q6 (resolved).** What if the lockfile lives in a subdirectory
(e.g., `frontend/package-lock.json` in a polyrepo monorepo)? The
helper emits basenames; `is_benign` matches `[[ "$f" == "$lf" ]]` — a
strict equality on basename-only paths. A subdirectory lockfile would
NOT be auto-benign by this gate; it would be evaluated by
`is_notable` instead. This matches today's behavior — `Cargo.lock` in
a workspace member subdirectory is also not auto-benign today.
Acceptable: the plan's File Structure should declare the workspace
manifest paths explicitly for monorepos.

**Q7 (open, low-priority).** Should the helper consult `## Tool
allowlist` (schema_version: 2) as a forward-looking signal? E.g., a
profile that allowlists `Bash(cargo:*)` implies the project uses
cargo even if `## Build & test gates` is sparse. Defer: T1's tool
allowlist isn't populated for non-Tauri profiles yet (ENG-94 is
in-progress) and Build & test gates is the more universally populated
field today.

**Q8 (resolved).** Does the scope-check-test.sh case 1 regex-only
test need updating? No. Case 1 tests the `allowed_files` regex
(`bin/scope-check.sh:190`), not `is_benign`.

## 7. Anti-bias checks

### 7.1 ADR stress test

There is no formal ADR system in this repo (`docs/knowledge/decisions.md`
does not exist; brainstorms cross-reference each other and CLAUDE.md
directly). The implicit "ADR" for this surface is the ENG-95 brainstorm
pattern (parser + always-include catalog). This brainstorm honors that
pattern but with the **precision** twist instead of **permissiveness**
— see D-007. The pattern stress-test is: "Does D-007's no-shared-catalog
add load to the next surface that lands?" Possibly. The next surface
that would touch lockfiles is hypothetical (none on the umbrella);
revisit if/when one appears.

### 7.2 Simpler alternative

The single simplest alternative is **union with the ENG-95 catalog**
(see D-001 rejected alternative 2, and §6 Q1). It's strictly less code
(~30 lines saved: no token table, no awk parser, no env-var override
for tests because tests can just rely on the catalog floor). Why
rejected: the Linear issue explicitly demands precision
("...auto-benign **when the profile names that stack**"). The cost of
the rejected alternative is one fewer false-positive scenario at the
expense of less-specific gates. If precision goal proves overblown in
practice, future ticket can collapse to the simpler union.

A second simpler alternative: **hardcode all primary lockfiles in
`is_benign`** (no profile parsing — just expand the case arms to
cover all known stacks). This is even simpler than the union. Why
rejected: violates the umbrella's "de-Tauri" goal — instead of
removing Tauri-specific hardcoding, it just adds five more stacks of
hardcoding. The Linear issue explicitly calls for profile-driven
resolution ("derives from `project-profile.md::Build & test gates`").

### 7.3 Assumption inventory (verified-vs-assumed)

* **Verified** — `bin/scope-check.sh::is_benign` is at lines 74–92, contains a `Cargo.lock` case arm at line 78. Quoted above (§1).
* **Verified** — `bin/scope-check.sh::main` populates `allowed_files` (line 190) and `allowed_dirs` (line 196) inside `main()`; `is_benign` reads them via dynamic scope. Quoted at `bin/scope-check.sh:87`.
* **Verified** — `bin/scope-check.sh::main` calls `is_benign` once per changed file at line 235. Quoted.
* **Verified** — `bin/common.sh::9` derives `HARNESS_ROOT` from `${BASH_SOURCE[0]}/..` and exports it.
* **Verified** — `bin/common.sh::47-53` resolves `PROJECT_SLUG` from `config.json::project.slug` and dies if missing.
* **Verified** — `bin/render-prompt.sh:149` resolves profile path as `$HARNESS_ROOT/learned-rules/$PROJECT_SLUG/project-profile.md`; same path used here.
* **Verified** — `learned-rules/twinning/project-profile.md:14-19` has a `## Build & test gates` section containing `bun run build`, `cargo test --workspace`, `bun run check`, `cargo clippy`, `cargo fmt`, `bunx playwright`. Both `bun` and `cargo` are present; the helper would emit `Cargo.lock`, `bun.lock`, `bun.lockb`.
* **Verified** — `learned-rules/harness/project-profile.md:14-19` has `## Build & test gates` with `bash` commands only, no PM token. Helper emits empty set — correct for harness-self (no lockfile).
* **Verified** — `grep -qwE` word-boundary behavior on macOS BSD grep matches `go test` and rejects `tango` / `ego`. Sanity-checked at brainstorm time.
* **Verified** — `bin/scope-check-test.sh:413-414` source-and-stub pattern for `has_scope_approval` works post-source: `SCRIPT_DIR` is overridden to a stub dir and the helper reads from there. Same pattern applies to overriding `HARNESS_ROOT` or `SCOPE_CHECK_PROFILE_PATH`.
* **Verified** — `bin/scope-check-test.sh:15` defaults `PROJECT_SLUG=test-slug` if not set.
* **Verified** — `bin/run-local-helpers.sh` on `main` defines `_always_include_paths` at lines 72–87 (contains `Cargo.lock`, `Cargo.toml`, `pyproject.toml`, `poetry.lock`, `package.json`, `package-lock.json`, `yarn.lock`, `pnpm-lock.yaml`, `bun.lock`, `bun.lockb`, `uv.lock`, `Pipfile`, `Pipfile.lock`, `go.mod`, `go.sum`, `Gemfile`, `Gemfile.lock`, `docs/`). Read via `git show main:bin/run-local-helpers.sh`. The token→lockfile table in D-002 is a subset of this catalog (no manifest files like `Cargo.toml` because manifests are typically declared in the plan's File Structure).
* **Verified** — `bin/run-local-helpers.sh` on `main` defines `_parse_profile_file_layout` at lines 28–66 with the `## File layout` section parser. Read via `git show main:bin/run-local-helpers.sh`. ENG-96's `_profile_lockfile_basenames` parser uses the same awk structure but targets a different section (`## Build & test gates`).
* **Verified** — current worktree branch `feat/eng-96-...` was cut from `63a2764`, before ENG-95 was merged (`1e5a251`). The ENG-95 helpers are NOT in this worktree. This brainstorm describes building parallel parsing logic in `scope-check.sh`, not consuming ENG-95's parser. Rebase onto post-ENG-95 main is a planning concern, not brainstorm.
* **Verified** — `bin/scope-check.sh:155` resolves `worktree_root` via `git rev-parse --show-toplevel`. Profile path resolution uses `HARNESS_ROOT` (where the scripts live), not `worktree_root` (where the target's checkout lives). Important distinction; aligned with `render-prompt.sh:149`.
* **Verified** — `bin/scope-check.sh:43` exports `PIPELINE_WRITER=scope-check` for any Linear writes from this script. ENG-96's new code does not perform Linear writes; lane discipline is unaffected.
* **Verified** — `bin/dispatch.sh::allowed_tools_for` (per ENG-92 / ENG-94 description) is the consumer of `## Tool allowlist`. ENG-96 does not interact with that consumer.
* **Verified** — ENG-92 issue text lists scope-check.sh::is_benign as T4 (ENG-96): "Make scope-check.sh::is_benign profile-driven." Confirmed via `bash bin/linear.sh get-issue ENG-92`.
* **Verified** — ENG-93 (T1) is `stage:released`, schema_version: 2 has Tool allowlist; ENG-95 (T3) is `stage:released`. Confirmed via `bash bin/linear.sh get-issue ENG-93 ENG-95`.
* **Assumed** — POSIX `grep -w` is available on the target operator's macOS. Verified for BSD grep; assumed for GNU grep (universal). Tests will pin behavior.
* **Assumed** — No PM token in the matrix (`cargo bun pnpm yarn npm npx poetry pipenv uv go bundle bundler`) appears as a substring inside a PM CLI token for a *different* package manager. (E.g., "bun" is not a prefix of "bundler"; "bundle" is.) Manual inspection of the 12-token list: `bundle` and `bundler` overlap, but both map to `Gemfile.lock`. `go` is dangerous as a substring; `-w` word boundary handles it. `npm` and `npx` are distinct words. No conflicts.
* **Assumed** — Discovery agent's output for new stacks will include the canonical PM CLI token (not a fork like `corepack` or `volta`). If a future profile says `volta run npm ...`, the `npm` token still fires correctly. Sustained as long as compound commands contain the PM token as a whitespace-separated word.
* **Assumed** — `is_benign` is not called by any consumer outside `bin/scope-check.sh::main`. Verified via `grep -rn is_benign bin/` — only call site is at line 235; only definition is at line 74. No external consumer would observe the contract change.
* **Assumed** — No existing test downstream of `is_benign` exercises a non-Cargo lockfile in the diff. Verified by inspection of `bin/scope-check-test.sh` cases 1–6 + QA-Adv-1..4 + HSA1/HSA2 — none of them write a `package-lock.json` or `poetry.lock` to the test branch.

### 7.4 Codebase-fact verification (mandatory)

Every named code artifact in this brainstorm is cross-referenced
above against the current worktree. Specifically:

| Artifact | Cited as | Location verified |
| --- | --- | --- |
| `is_benign` | bash function | `bin/scope-check.sh:74-92` |
| `Cargo.lock` case arm | line 78 | `bin/scope-check.sh:78` |
| `_BENIGN_PATH_CLASSES` (new) | top-level array | to be added near line 35 |
| `SCOPE_BENIGN_LOCKFILES` (new) | top-level array | to be added near line 35 |
| `_lockfile_for_pm` (new) | bash function | to be added in scope-check.sh |
| `_profile_lockfile_basenames` (new) | bash function | to be added in scope-check.sh |
| `_resolve_profile_path` (new) | bash function | to be added in scope-check.sh |
| `SCOPE_CHECK_PROFILE_PATH` (new env var) | tests only | documented in helper |
| `allowed_files` | dynamic-scope var | `bin/scope-check.sh:190` (populated) and `:87` (read) |
| `allowed_dirs` | dynamic-scope var | `bin/scope-check.sh:196` (populated) and `:87` (read) |
| `main()` per-file loop | `bin/scope-check.sh:223-245` | verified |
| `HARNESS_ROOT` derivation | `bin/common.sh:9` | verified |
| `PROJECT_SLUG` derivation | `bin/common.sh:47-53` | verified |
| `render-prompt.sh::append_project_profile` profile path | `bin/render-prompt.sh:149` | verified |
| `_always_include_paths` (ENG-95) | `bin/run-local-helpers.sh:72-87` on `main` | verified via `git show main:bin/run-local-helpers.sh` |
| `_parse_profile_file_layout` (ENG-95) | `bin/run-local-helpers.sh:28-66` on `main` | verified via `git show main:bin/run-local-helpers.sh` |
| `bin/scope-check-test.sh` source-stub pattern | HSA1/HSA2 cases | `bin/scope-check-test.sh:413-446` |
| ENG-92 umbrella issue text | T4 description | verified via `bash bin/linear.sh get-issue ENG-92` |

No artifacts referenced as existing-in-code that are not actually
present. New artifacts are flagged "(new)" with their intended file
location.

## Persona review

Six personas were run in order on iteration 1 (2026-05-13). All six
returned **PASS**; feasibility returned **0 P0 findings**. Gate satisfied
(6/6 PASS, 0 feasibility P0). Plan-stage carries the surfaced P1/P2
items below.

| Persona | Verdict | Notes |
| --- | --- | --- |
| design | PASS | No P0/P1. P2: pin in §3/§5 that tests calling `is_benign` directly post-`source` must populate `SCOPE_BENIGN_LOCKFILES` themselves (D-003 array is `main()`-populated). |
| security | PASS | No P0. P1: (a) plan must add a code-comment invariant that `$pm` in `grep -qwE "$pm"` MUST come from the hardcoded token loop, never profile-derived; (b) pin awk parser behavior on large/binary/duplicate-header profiles; (c) document `SCOPE_CHECK_PROFILE_PATH` as test-only convention with loud near-code comment; (d) plan keeps a Tauri-profile-back-compat test (T1) mandatory. |
| scope | PASS | No P0/P1. P2: CLAUDE.md edit under "Sweep + scope partition (ENG-14)" is borderline-OUT — plan should treat as optional, land only if the new contract is non-obvious to future readers. |
| coherence | PASS | Internal consistency holds. Minor flag: D-002's `npm` AND `npx` both → `package-lock.json` — `npx` is technically a runner, not a manager, but a profile mentioning `npx playwright` implies npm-managed. Plan should add a one-line comment noting `npx` is included as an inference signal. Non-blocking. |
| product | PASS | Walk-throughs for Python (poetry) and Go (go.sum) both pass. Workflow improvement clear. Minor: consider adding a Go end-to-end fixture (cheap insurance against `go` word-boundary edge-case regressions); the brainstorm covers it via unit T4 + T9 but no end-to-end Go. |
| feasibility | PASS, 0 P0 | All 14 verified claims hold: scope-check.sh line numbers (74–92, 78, 87, 190, 196, 235), common.sh derivations (9, 47–53), render-prompt.sh:149, harness + twinning profile content, scope-check-test.sh pattern, ENG-95 helpers on `main` (lines 28, 72), `bun.lockb` legitimacy, `grep -qwE 'go'` BSD behavior, awk section-delimiter pattern. No codebase-fact errors. |

### Items the plan stage should pick up

These are NOT brainstorm gaps — they are concrete implementation notes
the plan should encode as tests, code comments, or task-rows:

1. **Code-comment invariant near `_profile_lockfile_basenames`**:
   `grep -qwE "$pm"` — `$pm` MUST originate from the hardcoded
   token loop, never from profile-derived content. (security P1a)
2. **`SCOPE_CHECK_PROFILE_PATH` is a test-only convention**:
   add a loud comment at `_resolve_profile_path` and a note in
   CLAUDE.md / scope-check.sh's docstring. (security P1c)
3. **Awk parser robustness fixtures**: large file, duplicate
   `## Build & test gates` header, CRLF endings. (security P1b)
4. **Tauri-profile-back-compat test (T1) is mandatory** — pins
   that today's hardcoded behavior (Cargo.lock benign on Rust
   profile) is preserved. (security P1d)
5. **Optional Go end-to-end fixture** — pin word-boundary
   correctness end-to-end (product). May be folded into T8 if
   cost-effective, otherwise add T8b.
6. **`npx` inclusion note** — one-line comment in `_lockfile_for_pm`
   stating `npx` is included as an inference signal for npm. (coherence)
7. **Test-author contract** — tests calling `is_benign` directly
   (post-`source`) must populate `SCOPE_BENIGN_LOCKFILES` themselves;
   the per-file loop in `main()` is the production caller. (design P2)
8. **`maven`/`gradle`/`composer`/`pdm`/`hatch` blind-spot note** —
   one-line code comment near `_lockfile_for_pm` stating the table
   is non-exhaustive and to extend when a new stack is adopted.
   (design P2)

