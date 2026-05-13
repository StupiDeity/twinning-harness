---
linear: ENG-95
title: Make stage_output_paths consume project-profile File layout
date: 2026-05-13
status: draft
---

# ENG-95: profile-driven stage_output_paths

## 1. Problem

`bin/run-local-helpers.sh::stage_output_paths` (lines 202-241; the `implementing|ui|qa`
case-arm at lines 213-223; the actual `printf` of hardcoded paths at lines 219-222)
returns a hardcoded Tauri-shaped allowlist:

```
src/  src-tauri/  crates/  tests/  docs/
package.json  package-lock.json  bun.lock  bun.lockb
Cargo.toml  Cargo.lock
```

`partition_dirty_paths` (lines 288–354) consumes this list to bucket each
post-tick dirty path into one of three streams (in-scope / leaked-in-scope /
out-of-scope). A path that is bot-introduced AND falls outside the allowlist
is classified as **self-leak** → `halt_issue_for_self_leak` → `pipeline:halted`
on that issue.

For non-Tauri targets the agent legitimately writes to dirs the list does not
mention (`app/`, `lib/`, `cmd/`, `pkg/`, etc.). Each such write fires
`halt_issue_for_self_leak`. The operator-side `_scope_allowlist_override` hook
in `config.json::scope.allowlist.<stage>[]` exists (ENG-51) but is opt-in
prose configuration disjoint from the project-profile.md the operator already
authored at setup-time. The same path list is encoded twice — once in
`learned-rules/<slug>/project-profile.md::"## File layout"` (read by every
dispatched agent's prompt) and once in `config.json::scope.allowlist.<stage>[]`
(read by the sweep). The two surfaces drift; setup-time configuration is
not load-bearing for tick-time gates.

The umbrella ENG-92 calls this out as the "tauri-shaped scope rule" sub-bug.
ENG-95 is the smallest unit that resolves the false-positive halt class
without taking a hard dependency on the eventual structured (`schema_version: 2`)
profile work (deferred to T1 per the issue's blocked-by).

## 2. Goal

`stage_output_paths "$stage"` for `stage` ∈ `{implementing, ui, qa}` derives the
in-scope path list from `learned-rules/$PROJECT_SLUG/project-profile.md`'s
`## File layout` section, augmented by a small stack-agnostic always-include
set. The `_scope_allowlist_override` hook in `config.json` continues to win
when present (back-compat per issue AC #3).

Behavioural target: for every supported stack (Tauri, Rust workspace, Python
single-package, Go module, harness-self), an agent that writes legitimately
within the stack's canonical directories sees `matched_dir=1` in
`partition_dirty_paths` and lands in stream FD3 (in-scope). The retrospective's
"self-leak" rate on non-Tauri targets, currently dominated by stack-shape
misfit (per ENG-92 framing), drops to "genuine bot leaks" only.

## 3. Non-goals

- **Profile schema migration (T1).** Per the issue's blocked-by, T1 introduces
  the formal multi-stack profile schema (`schema_version: 2`). ENG-95 reads
  the existing v1 markdown `## File layout` section verbatim. If T1 promotes
  File layout to a structured key (e.g. JSON), ENG-95's parser MUST be
  updatable in one place; this is captured under §5 ADR-PROFILE-LAYOUT-SOURCE.
- **planning / retrospective stage paths.** The brainstorm/plan arms of
  `stage_output_paths` already derive correctly (docs/brainstorms/, docs/plans/,
  etc.) and the retrospective arm is hardcoded to a fixed set of
  `learned-rules`-adjacent files. Out of scope per AC.
- **dispatch.sh::allowed_tools_for.** The Bash-tool allowlist is a separate
  surface that ENG-51 already plumbed through `config.json::dispatch.tools.<stage>[]`.
  Out of scope for ENG-95.
- **Rewriting `_scope_allowlist_override`.** The hook continues to short-circuit
  ahead of profile parsing. The issue is additive, not a replacement.
- **Per-stage variants in the File layout.** ENG-95 reads one File layout list
  and applies it identically to `implementing | ui | qa`. If a future stack
  needs per-stage scope variants (e.g. `ui` can touch `static/` but
  `implementing` cannot), introduce per-stage keys in T1's structured schema.

## 4. Decisions

### D-001 — Parse `## File layout` from the existing v1 markdown profile

**Rationale.** ENG-95 is blocked by T1 (structured profile schema). The
issue body explicitly accepts an interim parse of the existing markdown
section ("Helper to parse `## File layout` section from project-profile.md").
The harness's discovery-time profile (`bin/setup-prompts/discovery.md`)
already requires the section to exist and to use the bullet form
``- `path/` — description ``.

The parser extracts every backtick-quoted token from the prefix of each
`- ` bullet (the part before the em-dash ` — `). This handles the
existing harness profile bullet
``- `docs/brainstorms/` and `docs/plans/` — canonical doc locations…``
without requiring a profile-format change. It also rejects backticked
tokens inside the description (after the em-dash), which would otherwise
sweep descriptive sub-paths like `` `build.rs` `` into the in-scope list
and grant false-positive top-level matches.

**Alternative (rejected): Wait for T1.** The umbrella ENG-92 sequences T1
before ENG-95, but T1 is unscoped today and the false-positive halt class
is biting non-Tauri targets *now*. Reading the existing v1 markdown is a
~30-line awk parser; the contract surface (one helper function) is small
enough that T1 can replace the parser body without churning callers.

**Alternative (rejected): Pure-`config.json` allowlist.** Requires every
operator to author the path list a second time after discovery already
wrote it into the profile. Violates "single source of truth" for stack
context — see §4 of `docs/brainstorms/2026-04-27-stack-aware-prompt-addendum-design.md`,
which made the profile *the* place where stack facts live.

### D-002 — Substitute `<slug>` → `$PROJECT_SLUG` in extracted paths

**Rationale.** The harness profile lists `learned-rules/<slug>/` — the
`<slug>` is a placeholder for the per-project namespace, not a literal
directory. The agent on harness-self writes to `learned-rules/harness/<stage>.md`,
which the literal token `learned-rules/<slug>/` would never match.
Substituting the env-known `$PROJECT_SLUG` resolves the placeholder to the
concrete path the agent will actually write.

**Alternative (rejected): Treat `<…>` as a wildcard.** Would technically
work but expands scope beyond the slug's own namespace — a harness-driven
agent could write to `learned-rules/twinning/` and pass the gate. Strict
substitution preserves the namespace boundary.

**Alternative (rejected): Skip lines with `<…>` and warn.** Would silently
exclude the harness profile's `learned-rules/<slug>/` entry, causing the
retrospective stage to leak when it edits `learned-rules/harness/build.md`.
Strict substitution preserves coverage.

This is the only placeholder ENG-95 substitutes. Future placeholders
(`<stage>`, `<issue>`) are not in any current profile and are deferred to
T1.

**Security: slug must be validated, not just substituted.** A `$PROJECT_SLUG`
that contains awk regex metacharacters (e.g. `a.b`, `foo[bar]`, `x|y`) or
backslashes would either inject metacharacter behavior into the substitution
or escape into adjacent text. Two layers of mitigation:

1. **Pre-substitution validation in `_parse_profile_file_layout`:** require
   `slug =~ ^[a-zA-Z0-9_-]+$`. A slug that fails the regex is treated as
   unset (substitution emits empty string into the path; the resulting
   `learned-rules//` matches no real path and the bullet effectively
   drops via the D-006 empty-token filter). This validation alone is
   *sufficient* — none of the awk replacement-string metacharacters
   (`&`, `\`) can pass the regex.
2. **Belt-and-braces escape in awk:** the parser still pre-escapes `&`
   and `\` in `slug` before passing it into `gsub`, in case the
   validation regex is ever loosened. Note that the awk pattern in
   `gsub(/<slug>/, slug_esc, token)` is a regex literal (`/<slug>/`)
   matching the four ASCII characters `<`, `s`, `l`, etc.; since none
   of those are regex metacharacters, the regex behaves as a literal
   string match. The defense-in-depth is on the *replacement* side
   (`slug_esc`), not the pattern side.

`PROJECT_SLUG` is frozen at first setup (`bin/setup-helpers.sh`) and
derived from `config.json::project.slug` (see CLAUDE.md table); the
expected shape is short-lowercase-alphanumeric. The validation regex
matches that shape; a malformed slug indicates configuration corruption
and the safe-empty behavior fails closed.

### D-003 — Always-include set: `docs/` plus a stack-agnostic manifest+lockfile catalog

**Rationale.** Per AC #1, "in-scope path list is composed from profile File
layout + always-included paths (`docs/`, lockfiles derived from build manifests)."

`docs/` is added unconditionally for `implementing | ui | qa` so an agent can
update `docs/architecture.md`, `docs/runbooks/`, etc. even when the profile's
File layout enumerates only sub-directories (`docs/brainstorms/`, `docs/plans/`).

The always-include lockfile catalog (executed alongside the profile-derived
list — order-of-precedence is "either-source matches → in-scope"):

| Stack | Manifest | Lockfile(s) |
|---|---|---|
| Rust | `Cargo.toml` | `Cargo.lock` |
| JS/TS (npm) | `package.json` | `package-lock.json` |
| JS/TS (bun) | `package.json` | `bun.lock`, `bun.lockb` |
| JS/TS (yarn) | `package.json` | `yarn.lock` |
| JS/TS (pnpm) | `package.json` | `pnpm-lock.yaml` |
| Python (poetry) | `pyproject.toml` | `poetry.lock` |
| Python (uv) | `pyproject.toml` | `uv.lock` |
| Python (pipenv) | `Pipfile` | `Pipfile.lock` |
| Go | `go.mod` | `go.sum` |
| Ruby | `Gemfile` | `Gemfile.lock` |

These are exact-match top-level filenames, so a profile that does not include
a manifest still allows the agent to refresh the corresponding lockfile when
a dependency changes. False-positive scope-grant risk is bounded: every
entry is a single literal filename at the repo root, not a directory prefix.

**Alternative (rejected): Derive lockfiles from manifests mentioned in the
profile.** Would require scanning the profile's prose (descriptions, narrative)
for manifest mentions — fragile and underspecified. The flat catalog above
is one explicit list to grep when adding a new stack; a future T1 schema
could move this catalog into the profile itself if structured.

**Alternative (rejected): No always-include set.** Forces every profile to
enumerate `docs/` and the appropriate lockfile combo. Acceptable in theory
but breaks back-compat with every existing profile (`learned-rules/twinning/project-profile.md`,
`learned-rules/harness/project-profile.md`) which lacks the `Cargo.lock`/`bun.lock`
entries inline. The always-include set keeps existing profiles working
post-migration.

### D-004 — Override hook (`_scope_allowlist_override`) wins absolutely

**Rationale.** AC #3 mandates back-compat. The existing hook reads
`config.json::scope.allowlist.<stage>[]`; today's operators (specifically
the harness-self target, which carries a custom allowlist for `bin/`
write access) MUST not regress. The new code path executes only when the
hook returns empty.

This means `_scope_allowlist_override` shadows the profile completely when
set — both the File-layout-derived list and the always-include set are
replaced. That is the existing contract (ENG-51) and changing it is out of
scope.

**Alternative (rejected): Merge override + profile.** Cleaner semantically
but breaks the established "override = full replacement" contract. If a
target wants partial override + profile, that target sets the full list in
`config.json` today. Status quo.

### D-005 — Fail-soft on missing or malformed profile

**Rationale.** `render-prompt.sh::append_project_profile` already dies on
missing-profile / unresolved-markers (it's a setup-time configuration error;
the orchestrator refuses to dispatch agents without a valid profile). But
`stage_output_paths` is sourced into tests (run-local-sweep-test.sh,
run-local-helpers-adversarial-test.sh, profile-allowlist-test.sh) where
no profile exists. Hard-failing breaks those tests.

Behaviour:
1. Profile file missing → fall back to **safety net**: `docs/` +
   always-include lockfile catalog only (no source dirs).
2. Profile exists but `## File layout` section missing or empty after parse
   → same fallback.
3. Profile contains `<<NEEDS-INPUT:>>` markers → fall back (the operator
   should have caught this at setup time; render-prompt.sh's die is the
   primary defense).

**Diagnostic logging (operator-visibility):** `stage_output_paths` emits
exactly one diagnostic via the existing `log` helper from `common.sh` when
the profile-derived list is empty AND the always-include set is the entire
output:
`stage_output_paths: profile-derived list empty for stage=<stage> (slug=<slug>, path=<profile_path>); falling back to docs/ + lockfile catalog. Run: bash bin/setup.sh project-profile`

This addresses the product-persona observability concern: operators see a
clear remediation hint in the per-stage transcript at
`$PROJECT_STATE_DIR/<ident>/logs/<stage>-*.log` and the tick log
`$PROJECT_STATE_DIR/<slug>/logs/local-YYYY-MM-DD.log` BEFORE the agent
self-leaks. The log is emitted from `stage_output_paths`, NOT from
`_parse_profile_file_layout` (the pure helper stays log-free for test
predictability). One-shot per call: no per-bullet warnings.

The safety-net fallback is intentionally narrow: docs and lockfiles only.
If the agent legitimately writes source code on a profile-less target, the
sweep classifies that write as self-leak → halt. The operator sees one halt,
runs `bash bin/setup.sh project-profile`, and the next tick proceeds.
Compared with the current Tauri-shaped fallback, the failure mode shifts
from silent-misclassification-on-non-Tauri to loud-halt-with-clear-remedy,
which is the principled trade.

**Alternative (rejected): Hard-die on missing profile.** Would break
existing tests and force every test fixture to mint a fake profile. The
fail-soft path costs ~5 lines and is consistent with how
`_scope_allowlist_override` handles a missing `CONFIG` (returns nothing,
caller's empty-check kicks in).

**Alternative (rejected): Fall back to the old Tauri-shaped list on
profile-missing.** Defeats the purpose of ENG-95 — non-Tauri targets
without a profile would still false-positive halt. Existing profiles will
be present in production; tests are the only profile-less environment, and
they don't care about source-dir scope.

### D-006 — Reject path-traversal and absolute paths during profile parse

**Rationale.** A profile-format adversary (or a discovery-agent mistake)
could write a bullet like `` - `../../etc/passwd` — caption `` and have the
parser surface that as an allowlist entry. `partition_dirty_paths` does
literal string matching against `git status -z --porcelain` output, which
emits repo-relative paths — so a literal `../../etc/passwd` would never
match a real dirty-path entry. But the principle of defense-in-depth says
"validate input before it reaches the matcher."

`_parse_profile_file_layout` rejects any extracted token that:
- begins with `/` (absolute path), or
- begins with `../` or contains `/../` (traversal), or
- contains a NUL byte (paranoid; awk handles NULs as line terminators on
  most builds anyway), or
- is empty after substitution + trimming.

Rejected tokens are silently dropped (the bullet is still parsed for any
remaining backticked tokens on the same line). This is a fail-closed posture
on adversarial profiles: a malicious profile widens scope by zero paths
rather than by one path the operator didn't notice in review.

**Alternative (rejected): Hard die on bad path.** Would create a
denial-of-service vector — an adversarial profile blocks every tick instead
of dropping one bullet. The drop-and-continue path is strictly safer.

**Alternative (rejected): Canonicalize via `realpath`.** Would resolve
symlinks and traversal, but `realpath` requires the path to exist on disk
and the parser is supposed to operate on profile text without filesystem
side effects. Reject-by-syntax is cheaper and adequate.

## 5. Architecture

### 5.1 New helper: `_parse_profile_file_layout` (in `bin/run-local-helpers.sh`)

```
_parse_profile_file_layout() {
  local profile_path="$1" slug="${2:-${PROJECT_SLUG:-}}"
  [[ -f "$profile_path" ]] || return 0

  # Validate slug shape; treat malformed values as empty (fail-closed).
  if [[ ! "$slug" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    slug=""
  fi
  # Escape awk gsub replacement metacharacters (& and \).
  local slug_esc; slug_esc="${slug//\\/\\\\}"; slug_esc="${slug_esc//&/\\&}"

  awk -v slug="$slug_esc" '
    /^## File layout[[:space:]]*$/ { in_section=1; next }
    in_section && /^## / { exit }
    in_section && /^- / {
      # Em-dash split: byte-string search for " — " (U+2014 = E2 80 94 in
      # UTF-8). awk on macOS/Linux treats the literal as bytes. Falls back
      # to whole-line if no em-dash present.
      prefix = $0
      em_pos = index(prefix, " \xe2\x80\x94 ")
      if (em_pos == 0) em_pos = index(prefix, "—")  # tolerate no-space form
      if (em_pos > 0) prefix = substr(prefix, 1, em_pos - 1)

      # Extract every backtick-quoted token from the prefix.
      while (match(prefix, /`[^`]+`/)) {
        token = substr(prefix, RSTART+1, RLENGTH-2)
        # gsub: pattern is a regex literal `/<slug>/` matching the four
        # ASCII chars literally (none are regex metacharacters); the
        # replacement is `slug` which the caller has pre-escaped for &/\.
        gsub(/<slug>/, slug, token)

        # Path validation (D-006):
        #   - drop empty after substitution
        #   - drop any remaining <...> placeholder
        #   - drop absolute paths (^/) and traversals (^../ or /../)
        if (token != "" && token !~ /</ && token !~ /^\// \
            && token !~ /^\.\.\// && token !~ /\/\.\.\//) {
          print token
        }
        prefix = substr(prefix, RSTART + RLENGTH)
      }
    }
  ' "$profile_path"
}
```

Pure function; reads the file, writes one path per stdout line; never
mutates state; safe to call from tests without stubs. No log output —
diagnostics live in the caller (D-005).

**Em-dash portability.** The literal `—` in the second `index()` call
covers locales where the bash-side variable was not encoded as raw bytes;
the byte-string `\xe2\x80\x94` covers the canonical UTF-8 case. macOS
awk and gawk both accept both literal forms in string context. The
implementation phase verifies via `bash bin/run-local-helpers-adversarial-test.sh`'s
em-dash test case under `LANG=C` and `LANG=en_US.UTF-8`.

### 5.2 New helper: `_always_include_paths` (in `bin/run-local-helpers.sh`)

```
_always_include_paths() {
  printf '%s\n' \
    'docs/' \
    'package.json' 'package-lock.json' 'yarn.lock' \
    'pnpm-lock.yaml' 'bun.lock' 'bun.lockb' \
    'Cargo.toml' 'Cargo.lock' \
    'pyproject.toml' 'poetry.lock' 'uv.lock' \
    'Pipfile' 'Pipfile.lock' \
    'go.mod' 'go.sum' \
    'Gemfile' 'Gemfile.lock'
}
```

Pure function; no inputs. Hardcoded catalog by design — see D-003.

### 5.3 Modified `stage_output_paths "$stage"` for `implementing|ui|qa`

```
implementing|ui|qa)
  local override
  override="$(_scope_allowlist_override "$stage")"
  if [[ -n "$override" ]]; then
    printf '%s\n' "$override"
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

`sort -u` deduplicates the union (e.g. if a profile lists `docs/` and
the always-include set also lists `docs/`).

**Normalization of trailing slashes.** `partition_dirty_paths` treats
entries ending in `/` as directory-prefix matches and entries without
`/` as exact-match. A profile that lists `docs` (no slash) would yield
an exact-match entry that never fires (real dirty paths are
`docs/foo.md`, not `docs`). To avoid this silent miss, the parser does
NOT normalize trailing slashes — the operator is expected to use `dir/`
in the profile per `bin/setup-prompts/discovery.md` schema
("`- \`path/\` — what lives here`"). If profile-format drift becomes
a recurring failure mode, a future change can either (a) add a parser
normalisation pass (`if path looks-like-a-directory append /`) or
(b) emit a discovery-time linter warning. Left out of ENG-95 scope.

### 5.4 No changes to `partition_dirty_paths`

The matcher logic (line 322: `if [[ "$entry" == */ ]]; then case "$path" in "$entry"?*) matched_dir=1`)
is unchanged. Entries ending in `/` are prefix-matched against `$path`;
entries without `/` are exact-matched. Both modes already exist; this PR
only changes the *source* of the entry list.

The D-004 brainstorm/plan basename-token check (lines 295-296: `case "$stage" in
brainstorming|planning) apply_d004=1`) is unaffected — `implementing|ui|qa`
never enter the D-004 branch.

### 5.5 No `assert_stage_allowlist_coverage` change

The startup assertion (lines 259-265) walks every stage and verifies
`stage_output_paths` returns non-empty for each. Post-change, `implementing|ui|qa`
still return non-empty (always-include set is always non-empty), so the
assertion still passes.

## 6. Data flow

```
project-profile.md::"## File layout"
      │
      ▼
_parse_profile_file_layout
      │
      ├─→ "src/"             ┐
      ├─→ "lib/"             │  per-stack paths
      ├─→ "tests/"           │
      └─→ "learned-rules/harness/"  ┘  (<slug> substituted)
                                  │
                       _always_include_paths
                                  │
                                  ├─→ "docs/"
                                  ├─→ "Cargo.toml"
                                  ├─→ "Cargo.lock"
                                  ├─→ "package.json"
                                  ├─→ … (manifest+lock catalog)
                                  │
                                  ▼
                              sort -u
                                  │
                                  ▼
                       stage_output_paths "$stage"   ← (or _scope_allowlist_override on $1)
                                  │
                                  ▼
                       partition_dirty_paths::allowlist[]
                                  │
                                  ▼
                       FD3 in-scope / FD4 leak / FD5 observed
```

Override path bypasses both helpers entirely (D-004); the rest is union.

## 7. Edge cases

| Case | Behaviour |
|---|---|
| Profile file missing | Fall back to always-include only (D-005); caller emits one diagnostic log. Agent's source-dir writes self-leak → halt with clear remedy. |
| `## File layout` section missing | Same as missing profile — `awk` exits with empty stream, union = always-include only, diagnostic log fires. |
| `## File layout` empty (no `- ` bullets) | Same as missing section. |
| Bullet with no backticked path (e.g. `- some prose`) | Skipped — `match` finds no backticks. |
| Bullet with backticks only in description (after em-dash) | Skipped — em-dash splits the line; description ignored. |
| Bullet with multiple backticks before em-dash | All extracted (handles the harness profile's `` `docs/brainstorms/` and `docs/plans/` `` bullet). |
| Bullet with `<slug>` placeholder | Substituted to `$PROJECT_SLUG`. |
| Bullet with other `<…>` placeholder | Skipped (defensive — prevents literal `<stage>/` from reaching the matcher). |
| Bullet with unbalanced backticks (e.g. `` - `src/` `docs/ ``) | `match()` matches the first closed pair, returns `src/`; the open backtick after `docs/` has no closing pair, so the second `match()` finds nothing and the inner while-loop exits cleanly. No partial-token leak; no abort. |
| Bullet with absolute-path adversary (`` - `/etc/passwd` ``) | Rejected by D-006 (starts with `/`). |
| Bullet with traversal adversary (`` - `../../etc/passwd` ``) | Rejected by D-006 (starts with `../`). |
| Bullet with embedded traversal (`` - `foo/../../bar` ``) | Rejected by D-006 (`/../` substring). |
| `PROJECT_SLUG` unset or shape-invalid (D-002 regex fails) | Substitution emits the empty string; the bullet may yield `learned-rules//` which is harmless (matches no real path) but the parser drops empty tokens (D-006). In production, `common.sh` guarantees `PROJECT_SLUG` is set; tests sourcing without common.sh see this benign fallback. |
| Slug contains awk metacharacters (`a.b`, `x|y`) | Pre-substitution regex validation (D-002) treats slug as invalid and emits empty substitution; bullet is dropped via D-006. |
| Same path in profile and always-include | `sort -u` deduplicates. |
| Profile with unresolved `<<NEEDS-INPUT:>>` markers | Parser still extracts non-marker bullets; render-prompt.sh remains the primary defense for marker-bearing profiles. |
| Filename with embedded space | awk pattern preserves it inside backticks — handled identically to existing `run-local-sweep-test.sh` case #7. |
| Filename with regex metachars | Returned verbatim; `partition_dirty_paths` does literal string comparison (no regex). |
| Override returns multi-line stream | Existing back-compat — unchanged. |
| Override returns single trailing newline only | Counts as empty per `[[ -n "$override" ]]` after expansion — falls through to profile path. |
| Override key is set to `[]` (empty array, ENG-51 fallback) | `_scope_allowlist_override` returns empty (per its existing contract, lines 14-19); caller falls through to profile parse + always-include. |

## 8. Error handling

`_parse_profile_file_layout` returns 0 unconditionally (a missing file is
expected on tests, not an error). The helper is pure — no `log` calls, no
state mutation, no filesystem writes. awk warnings are swallowed by the
caller's pipeline; the validation regex on `slug` and the path-syntax
filters (D-002, D-006) silently drop invalid input rather than failing
the whole parse.

`_always_include_paths` returns 0 unconditionally — printf can't meaningfully
fail at this size.

`stage_output_paths` is the diagnostic layer:

1. **Profile-derived list empty** (missing file, missing `## File layout`
   section, all bullets rejected) → emit one `log` line with the slug,
   profile path, and remediation hint (D-005). The fallback always-include
   set still emits, so the function never returns empty for `implementing|ui|qa`.
2. **Unknown stage** → die at line 238 (unchanged).
3. **`assert_stage_allowlist_coverage`** (line 259) — still passes; every
   stage's output remains non-empty.

The diagnostic log is operator-facing. It appears in:
- `$PROJECT_STATE_DIR/<slug>/logs/local-YYYY-MM-DD.log` (run-local tick log)
- `$PROJECT_STATE_DIR/<ident>/logs/<stage>-*.log` (per-stage transcript,
  if `stage_output_paths` is invoked downstream of a stage run)

The log fires at most once per `stage_output_paths` call. Operator's
remediation: `bash bin/setup.sh project-profile` (re-runs discovery) or
hand-edit `learned-rules/<slug>/project-profile.md`'s File layout section.

`PROJECT_SLUG` / `HARNESS_ROOT` invariants: both are set by `bin/common.sh`
at source time (see CLAUDE.md "Three locations every script touches"). If
either is empty at function call time, the path computation produces a
benign mis-formed path (`learned-rules//project-profile.md`) that fails the
`[[ -f ... ]]` test in `_parse_profile_file_layout`, triggers the fallback,
and emits the diagnostic log. This is consistent with the existing
common.sh source-time contract: in production, both are always set; tests
that source helpers without common.sh see fallback behavior.

## 9. Test plan

### 9.1 `bin/run-local-sweep-test.sh` — new fixtures

Each fixture sets `HARNESS_ROOT` to a tempdir containing
`learned-rules/<slug>/project-profile.md` and exercises one stack:

| Fixture | Stack | Profile File layout entries | Assertion |
|---|---|---|---|
| `profile_rust_workspace_inscope` | Rust multi-crate | `crates/`, `tests/` | `?? crates/twinning-foo/src/lib.rs` → in-scope |
| `profile_python_single_pkg_inscope` | Python single-pkg | `app/`, `tests/` | `?? app/handlers.py` → in-scope |
| `profile_go_module_inscope` | Go module | `cmd/`, `pkg/`, `internal/` | `?? cmd/server/main.go` → in-scope |
| `profile_harness_self_inscope` | harness-self | `bin/`, `learned-rules/<slug>/`, `AGENT_PROMPTS.md` | `?? bin/foo.sh` → in-scope; `?? learned-rules/harness/build.md` → in-scope (`<slug>` resolves) |
| `profile_python_lockfile_inscope` | Python | (only `app/`) | `?? poetry.lock` → in-scope via always-include |
| `profile_go_lockfile_inscope` | Go | (only `cmd/`) | `?? go.sum` → in-scope via always-include |
| `profile_docs_always_inscope` | (any) | (only `src/`) | `?? docs/anything.md` → in-scope via always-include |
| `profile_unknown_dir_out_of_scope` | Rust | (only `crates/`) | `?? app/leak.py` → self-leak/leaked-in-scope (depending on prior state) |
| `profile_missing_falls_back_to_always_include` | — | (no profile file) | `?? docs/foo.md` → in-scope; `?? src/leak.rs` → leak |
| `profile_file_layout_missing_falls_back` | — | (profile exists, no `## File layout`) | same as missing profile |
| `profile_override_shadows_layout` | Rust | `crates/` in profile, override = `[src/]` only | `?? src/foo.rs` → in-scope; `?? crates/foo.rs` → leak |

### 9.2 `bin/run-local-helpers-adversarial-test.sh` — new adversarial cases

| Case | Assertion |
|---|---|
| `parse_em_dash_split` | profile bullet `` - `src/` — note about `tests/` `` extracts ONLY `src/`, not `tests/` |
| `parse_multi_backtick_prefix` | profile bullet `` - `docs/brainstorms/` and `docs/plans/` — caption `` extracts both |
| `parse_slug_substitution` | profile bullet `` - `learned-rules/<slug>/` `` with `PROJECT_SLUG=foo` yields `learned-rules/foo/` |
| `parse_other_placeholder_skipped` | profile bullet `` - `<stage>/output/` `` yields no entries |
| `always_include_present_when_profile_minimal` | profile with one `` - `src/` `` still emits `docs/`, `Cargo.toml`, etc. |
| `always_include_dedup_with_profile` | profile lists `docs/`; helper output has one `docs/` (`sort -u` verified) |
| `override_empty_falls_through_to_profile` | `config.json::scope.allowlist.implementing = []` (empty array, ENG-51 fallback path) routes to profile |
| `parse_absolute_path_rejected` | profile bullet `` - `/etc/passwd` `` yields no entries (D-006) |
| `parse_traversal_prefix_rejected` | profile bullet `` - `../../etc/shadow` `` yields no entries (D-006) |
| `parse_embedded_traversal_rejected` | profile bullet `` - `foo/../../bar` `` yields no entries (D-006) |
| `parse_unbalanced_backticks_safe` | profile bullet `` - `src/` `docs/ `` extracts ONLY `src/`; parser does not abort, no partial-token leak |
| `parse_slug_regex_metachar_safe` | `PROJECT_SLUG=a.b` causes slug validation to fail; bullet `` - `learned-rules/<slug>/` `` yields no entries (or drops via D-006 after empty substitution) |
| `parse_slug_amp_metachar_safe` | `PROJECT_SLUG=foo` is normal; with the gsub-escape pre-pass, no awk replacement-string injection occurs (smoke test — actual injection paths blocked by validation regex) |
| `parse_no_em_dash_handled` | profile bullet `` - `src/` `` (no em-dash, no description) yields `src/` |
| `parse_log_fires_on_empty_profile_layout` | profile with no `## File layout` section triggers exactly one log line via `stage_output_paths` (assert with stderr capture); always-include set still emits |
| `parse_log_does_not_fire_on_valid_profile` | profile with non-empty File layout does NOT emit the diagnostic log |

### 9.3 Existing tests — back-compat verification

`bin/run-local-sweep-test.sh` cases 12 (`implement_stage_sweeps_rust_source`)
and 13 (`retrospective_pipeline_config_in_scope`) must still pass under the
twinning profile fixture (which lists `crates/` in its File layout) — they
exercise the same path classification but through the new derivation chain.

`bin/profile-allowlist-test.sh` cases that exercise
`_scope_allowlist_override` precedence must pass unchanged — the override
short-circuit is preserved bit-for-bit.

## 10. CLAUDE.md update

The "Sweep + scope partition (ENG-14)" section currently reads:

> Anything writing files outside the per-stage allowlist must update the
> partition rules in `run-local-helpers.sh` or it will trip the breaker.

Append:

> The `implementing | ui | qa` allowlist is derived from
> `learned-rules/$PROJECT_SLUG/project-profile.md`'s `## File layout`
> section, plus a stack-agnostic catalog of `docs/` and common
> manifest+lockfile filenames (`Cargo.lock`, `package-lock.json`,
> `poetry.lock`, `go.sum`, etc. — see `_always_include_paths` in
> `bin/run-local-helpers.sh`). The hardcoded Tauri shape (`src-tauri/`,
> `crates/`, `bun.lock*`) was removed in ENG-95.
>
> **Where to make scope changes (decision tree):**
>
> | Change shape | Edit | Notes |
> |---|---|---|
> | Permanent stack-shape change (new top-level dir like `app/`, `pkg/`) | `learned-rules/<slug>/project-profile.md::"## File layout"` | The profile is the canonical source of stack truth. Re-run `bash bin/setup.sh project-profile` to regenerate, or hand-edit. Visible to every dispatched agent's prompt AND the sweep allowlist. |
> | Per-target one-off (test-specific path, experimental dir) | `config.json::scope.allowlist.<stage>[]` | Overrides the profile-derived list completely for that stage; useful for granting scope without polluting the canonical profile. **This config is gitignored** — operator-local. |
> | Common lockfile catalog (e.g. add `bun.lockb` for a new package manager) | `_always_include_paths` in `bin/run-local-helpers.sh` | Hardcoded list; PR to the harness repo. Universal across slugs. |
>
> **Migration from pre-ENG-95 (existing Tauri targets):** Existing profiles
> that list the Tauri directories (`src/`, `src-tauri/`, `crates/`, `tests/`)
> in their `## File layout` section work unchanged. The new implementation
> reads your profile instead of a hardcoded list — same result. If your
> profile is missing entries, scope falls back to `docs/ + lockfile catalog`
> only and the agent self-leaks on the next source-dir write; the operator
> sees a diagnostic in `$PROJECT_STATE_DIR/<slug>/logs/local-*.log`:
>
>     stage_output_paths: profile-derived list empty for stage=implementing
>     (slug=<slug>, path=<...>); falling back to docs/ + lockfile catalog.
>     Run: bash bin/setup.sh project-profile
>
> **Always-include lockfile catalog scope.** The always-include set grants
> in-scope status for ALL common manifest+lockfile filenames
> (`Cargo.toml/lock`, `package.json/-lock.json`, `bun.lock/lockb`,
> `pyproject.toml + poetry.lock/uv.lock/Pipfile.lock`, `go.mod/sum`,
> `Gemfile/.lock`), regardless of whether your target uses that stack.
> This is intentional — false-positive scope is bounded to top-level
> single-file matches, never a directory prefix. If this is too broad for
> your repo, set `config.json::scope.allowlist.<stage>[]` to a tighter list.

## 11. Anti-bias checks

### 11.1 ADR stress test

The accepted ADR pressure points:

- **Stack-aware prompt addendum (docs/brainstorms/2026-04-27-stack-aware-prompt-addendum-design.md
  §4):** "missing or marker-bearing profiles fail render with a clear error". ENG-95
  introduces a **fail-soft** branch in `stage_output_paths` (D-005) — a profile-missing
  target falls back to a safety net rather than dying. This is NOT a contradiction:
  `render-prompt.sh::append_project_profile` still dies on missing profile, so the
  orchestrator still refuses to dispatch agents without a profile. The fail-soft branch
  exists exclusively for the test sourcing path. In production, `stage_output_paths`
  is only reached AFTER a successful render, which means profile must already be valid.
  The two surfaces are layered correctly.

- **ENG-69 per-issue counter contract (`route_run_stage_exit`, line 158-200):** the
  per-issue `.consecutive-failures` counter escalates same-issue agent failures.
  Post-ENG-95, a profile that misses a real-source-dir will halt the issue on first
  agent write (self-leak path → `pipeline:halted`, NO counter increment). This is
  consistent with ENG-69's contract: self-leak is one-shot halt, not threshold-based.
  No ADR pressure.

- **ENG-51 override contract (`_scope_allowlist_override`):** preserved verbatim per
  D-004. No pressure.

### 11.2 Simpler alternative inventory

Every decision lists ≥1 rejected alternative with reasoning. See D-001 through D-005.

### 11.3 Assumption inventory

| Assumption | Status | Evidence |
|---|---|---|
| `bin/run-local-helpers.sh::stage_output_paths` exists at the line range cited | verified | `bin/run-local-helpers.sh:202-241` |
| Hardcoded list contains `src-tauri/`, `crates/`, `bun.lock`, `bun.lockb`, `Cargo.toml`, `Cargo.lock` | verified | `bin/run-local-helpers.sh:213-223` (specifically lines 220-222) |
| `_scope_allowlist_override` reads `CONFIG::scope.allowlist[$s]` | verified | `bin/run-local-helpers.sh:11-20` |
| `partition_dirty_paths` uses prefix-match for `entry == */` and exact-match otherwise | verified | `bin/run-local-helpers.sh:321-328` |
| `apply_d004=1` only for `brainstorming|planning` | verified | `bin/run-local-helpers.sh:295-296` |
| `assert_stage_allowlist_coverage` walks 9 stages incl `implementing|ui|qa` | verified | `bin/run-local-helpers.sh:259-265` |
| `learned-rules/<slug>/project-profile.md` is the canonical profile path | verified | `bin/render-prompt.sh:149` (`profile_path="$HARNESS_ROOT/learned-rules/$PROJECT_SLUG/project-profile.md"`) |
| Existing profile schema has `## File layout` H2 section in 3rd position | verified | `bin/setup-helpers.sh:152-156` (validator) + `learned-rules/harness/project-profile.md:21-28` |
| Profile bullets use form `` - `path/` — description `` with em-dash U+2014 | verified | `learned-rules/harness/project-profile.md:23-28`; `learned-rules/twinning/project-profile.md:23-28` |
| Harness profile uses `<slug>` placeholder in `learned-rules/<slug>/` | verified | `learned-rules/harness/project-profile.md:25` |
| `_validate_project_profile_schema` validates frontmatter + 5 H2 sections | verified | `bin/setup-helpers.sh:128-159` |
| `render-prompt.sh::append_project_profile` dies on missing profile | verified | `bin/render-prompt.sh:150-156` |
| `HARNESS_ROOT` and `PROJECT_SLUG` are set by common.sh source-time | verified | `bin/common.sh` exports both before downstream scripts source it (see also CLAUDE.md "Three locations every script touches" table) |
| Existing test scaffold uses `STUB_DIR` + post-source override for `TARGET_REPO`/`SCRIPT_DIR` | verified | `bin/run-local-sweep-test.sh:6-11` (sources common.sh + helpers, sets `PROJECT_SLUG`); `bin/profile-allowlist-test.sh:42-66` (full pattern incl. `HARNESS_ROOT`) |
| `bash bin/run-local-sweep-test.sh` and `bash bin/run-local-helpers-adversarial-test.sh` are in the implementing/qa allowlists | verified | project-profile addendum's "Tool allowlist" section lines for `implementing` and `qa` both include them |
| `## File layout` bullets sometimes contain `` `foo/` and `bar/` `` (multi-path on one line) | verified | `learned-rules/harness/project-profile.md:27` (`` - `docs/brainstorms/` and `docs/plans/` — … ``) |
| Twinning profile `## File layout` bullet for `src-tauri/` contains many backticked descriptive paths after em-dash | verified | `learned-rules/twinning/project-profile.md:24` — `` - `src-tauri/` — Tauri shell crate: `src/`, `build.rs`, … `` confirms the em-dash-split design |
| ENG-51 `_scope_allowlist_override` empty-array fallback contract | verified | `bin/run-local-helpers.sh:14-19` (jq returns `empty` on empty array or non-array, caller's `[[ -n "$override" ]]` falls through) |
| `LC_ALL=C sort -u` is the existing in-tree pattern for stable sorted dedup | assumed | bash 3.2 + macOS coreutils `sort -u` is well-known stable; harness uses `awk` and `sort` widely. Implementation can verify against actual fixtures during the implement stage. |
| Em-dash character (U+2014) survives in awk under macOS's default LANG and `LANG=C` | assumed | awk on macOS handles UTF-8 in regex bodies as bytes; the literal "—" matches byte-for-byte. §5.1 hedges by using BOTH the UTF-8 byte sequence `\xe2\x80\x94` (canonical) AND the literal char (locale fallback). Implementation verifies via test cases `parse_em_dash_split` and `parse_no_em_dash_handled` under both LANG settings. |
| Awk `gsub` replacement-string metacharacters are `&` and `\`; pre-escaping these in the slug eliminates injection | verified | POSIX awk spec; same behavior on macOS BSD awk and gawk. The pre-substitution validation regex `^[a-zA-Z0-9_-]+$` already disallows both characters; the gsub-escape is belt-and-braces. |
| Path-traversal regex filters (`^/`, `^../`, `/../`) cover the documented injection vectors | assumed | These three patterns cover absolute paths and the standard `..` traversal forms. The implementation phase verifies via the adversarial cases `parse_absolute_path_rejected`, `parse_traversal_prefix_rejected`, `parse_embedded_traversal_rejected`. A future hardening pass could canonicalize via `realpath` (rejected in D-006 — adds filesystem coupling). |
| `log` helper from common.sh is safe to call from `stage_output_paths` (does not break the function's stdout discipline) | verified | `log` writes to stderr, not stdout; `stage_output_paths` callers only consume stdout (see `partition_dirty_paths` line 293 `done < <(stage_output_paths "$stage")`). No interference. |

No assumptions reference methods that don't exist yet. Two assumptions
remain marked "assumed" — both are portability details validated by the
test harness during the implement stage.

## 12. Open questions

1. **Should the always-include catalog be configurable?** A future T1 schema
   could move the lockfile catalog into the profile itself (per-stack
   schemas could carry their own manifest+lock pair). For ENG-95, the
   hardcoded catalog is one literal in one file — easy to extend, easy to
   replace under T1. **Resolution:** leave hardcoded; revisit in T1.

2. **Should `<slug>` substitution support nested placeholders like
   `learned-rules/<slug>/<stage>.md`?** The harness profile lists
   `learned-rules/<slug>/` (directory-prefix), which already covers any
   file under that dir via the existing prefix-match. So substituting
   `<slug>` is sufficient; no need to substitute `<stage>`. **Resolution:**
   substitute `<slug>` only.

3. **Should the parser warn on profile bullets it can't interpret?**
   Current design silently skips bullets without backticks (e.g. pure-prose
   bullets). A `log "stage_output_paths: skipped profile bullet 'foo'"`
   would help debug profile-format drift, but it would also fire on every
   tick for every legitimate prose bullet. **Resolution:** silent skip;
   if profile-format drift is a recurring failure mode, add a one-shot
   discovery-time linter (separate ticket).

4. **Does the change affect `auto_commit_in_scope`?** That helper at line
   383-479 calls `partition_dirty_paths` directly and depends on
   `stage_output_paths` returning a non-empty list for the stage. Post-ENG-95,
   `implementing|ui|qa` still return a non-empty list (always-include set
   ensures it). **Resolution:** verified safe; no changes to
   `auto_commit_in_scope`.

5. **Profile-format change discipline.** If T1 introduces a structured
   File-layout key (`schema_version: 2` with `file_layout: [...]` JSON
   array), `_parse_profile_file_layout` becomes a switch on schema
   version: markdown bullets for v1, JSON for v2. The contract surface
   (one helper function, one stage_output_paths arm) is small enough
   that the switch is a localized edit. **Resolution:** no action;
   noted for T1 owner.

## 13. Persona review

Reviewed under the 6-persona discipline. Gate: ≥5/6 PASS and feasibility (gating)
returns zero P0. Result: **6/6 PASS, feasibility P0 = 0**, gate satisfied.

| Persona | Iter 1 | Iter 2 | Notes |
|---|---|---|---|
| Design | PASS | — | Clean separation of concerns; UTF-8 portability + slash-normalization addressed in §5.1/§5.3 |
| Security | FAIL → PASS | PASS | P0s on path-traversal (D-006), slug regex injection (D-002 hardened), unbalanced backticks (§7 edge case + test) all resolved |
| Scope | PASS | — | All 5 ACs covered; correctly avoids T1 |
| Coherence | FAIL → PASS | PASS | P1 log-contradiction (D-005 vs §8) resolved by attributing log emission to `stage_output_paths` (caller), not `_parse_profile_file_layout` (pure helper); line-number citations corrected |
| Product | PASS w/ P0 → PASS | PASS | Decision-tree table + diagnostic-log spec + migration story + always-include guidance all added to §10/§8 |
| Feasibility | — | PASS | All codebase facts verified against on-disk code (17/17 references match) |

Key changes between iterations:
- Added D-006 (path-traversal/absolute reject) and tightened D-002 (slug regex validation + gsub-escape).
- Moved diagnostic log from the pure helper to `stage_output_paths` to keep `_parse_profile_file_layout` log-free for test predictability.
- Added decision-tree table and migration paragraph to §10.
- Corrected line citations for the twinning profile (24 vs 18) and the hardcoded list (219-222 vs 213-223).
- Added 9 new test cases to §9.2 covering the security validations and observability log.


