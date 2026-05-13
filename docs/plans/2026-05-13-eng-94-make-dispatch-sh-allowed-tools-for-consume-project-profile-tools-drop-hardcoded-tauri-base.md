---
linear: ENG-94
date: 2026-05-13
topic: dispatch.sh::allowed_tools_for composes base + profile-derived (new helper) + extras; cargo/bun/rustc/npx/node tokens removed from implementing/ui/qa case arms
---

# Plan — ENG-94 `dispatch.sh::allowed_tools_for` consumes project-profile Tool allowlist (drop hardcoded Tauri base)

Implementation plan for the design at
`docs/brainstorms/2026-05-13-eng-94-make-dispatch-sh-allowed-tools-for-consume-project-profile-tools-drop-hardcoded-tauri-base-design.md`.

## Anti-anchoring check

- **Problem (operator's words).** `bin/dispatch.sh::allowed_tools_for`
  ships a hardcoded Tauri-shaped base (`Bash(cargo:*),Bash(bun:*),
  Bash(rustc:*),Bash(npx:*),Bash(node:*)` in `implementing` / `ui` /
  `qa` case arms). The discovery agent's `learned-rules/<slug>/
  project-profile.md` already names per-stage Tool allowlist patterns
  per stack, but `dispatch.sh` ignores them — a Python target's
  implement agent gets cargo allowlisted and pytest blocked.
- **Brainstorm addresses it?** Yes. D-1 introduces a new helper
  `_dispatch_tools_from_profile <stage>` that reads
  `$HARNESS_ROOT/learned-rules/$PROJECT_SLUG/project-profile.md`,
  extracts the `## Tool allowlist` per-stage bullet block, and emits
  comma-joined `Bash(...)` patterns. D-2 composes the return value as
  `base,profile,extras` with empty-segment elision. D-3 fails soft on
  missing/malformed profile (warn-and-fall-through, never `die` — per
  issue AC#3). D-4 applies the helper uniformly to all stages via the
  single composition-tail edit (no per-stage case-arm conditional).
  D-5 picks awk for parsing (already a documented harness runtime
  dependency). D-6 ships 5 fixtures (the three issue-mandated stack
  shapes + two AC#3 discrimination fixtures). D-7 rewrites the
  `CLAUDE.md` "Per-target dispatch.tools extras" section to document
  the new composition order. D-8 adds defense-in-depth shell-metachar
  rejection inside the awk parser.
- **Proportional?** Yes. Three files touched: a ~25-line new helper +
  ~10-line case-arm cleanups + a ~10-line composition-tail rewrite in
  `bin/dispatch.sh`; ~150-line test-fixture append to
  `bin/dispatch-test.sh`; a ~30-line documentation rewrite in
  `CLAUDE.md`. No new files, no new bash scripts, no new dependencies,
  no schema changes (T1 owns those), no new exit code, no new metric,
  no new lane fence.
- **No reframe; no scope creep; no escalation. PROCEED with implementation.**

## Goal

After the implement stage runs, the harness will have on the feature
branch:

1. **D-1 / D-3 / D-5 / D-8 in tree.** `bin/dispatch.sh` carries a new
   helper `_dispatch_tools_from_profile <stage>` (inserted between
   `_dispatch_tools_extras` at `bin/dispatch.sh:291–300` and
   `allowed_tools_for` at `bin/dispatch.sh:302–340`). The helper
   resolves `$HARNESS_ROOT/learned-rules/$PROJECT_SLUG/project-profile.md`,
   awk-extracts the `## Tool allowlist` section's per-stage sub-bullet
   patterns (state machine: `before_section` / `in_section` /
   `after_section`, current-stage tracker via `^- <stage>:` bullets,
   pattern match against backtick-fenced `Bash(...)` tokens), defends
   against shell-metachar payloads (rejects `;`, `&`, `|`, `` ` ``,
   `$(`, `>`, `<`, newline, paren-imbalance per D-8), and emits a
   comma-joined string on stdout. Fail-soft surface per D-3:
   - file absent / `PROJECT_SLUG` empty / `HARNESS_ROOT` empty → empty
     string, NO warning (symmetric with `_dispatch_tools_extras`
     `[[ -f "${CONFIG:-}" ]] || return 0` at line 293).
   - frontmatter missing OR `schema_version != 2` → empty string + ONE
     `log "[allowed-tools] project-profile.md schema_version != 2;
     Tool allowlist not loaded for stage=$stage"` line.
   - schema_version 2 but `## Tool allowlist` section absent → empty +
     ONE `log "[allowed-tools] project-profile.md::## Tool allowlist
     section not found; stage=$stage"` line.
   - section present, stage line absent OR sub-bullets empty OR
     `(none)` → empty string, NO warning.
   - awk one-shot returns non-zero → empty + ONE `log "[allowed-tools]
     awk parse failure for stage=$stage"` line (defensive).
   - **NEVER** include the matched pattern text in any warning (per
     D-8's "Why" + ENG-46 secret-handling rule).

2. **D-1 case-arm cleanup in tree.** `bin/dispatch.sh:324, 325, 327`
   no longer carry `Bash(cargo:*)`, `Bash(bun:*)`, `Bash(rustc:*)`,
   `Bash(npx:*)`, or `Bash(node:*)` tokens. Each case arm's surviving
   tokens (Read/Write/Edit/Grep/Glob, the `Bash(git ...)` family, the
   `Bash(jq:*)`, `Bash(awk:*)`, and the dual-path linear/pipeline/etc.
   wrappers) are preserved verbatim. The `qa` arm's wide `Bash(git:*)`
   is preserved verbatim (per the brainstorm §11
   "Deliberately-not-narrowed" carve-out — separate ticket).

3. **D-2 / D-4 composition-tail rewrite in tree.** `bin/dispatch.sh:
   333–339` (current shape: `extras`-only conditional concat) becomes
   a three-way composition that invokes `_dispatch_tools_from_profile`
   AND `_dispatch_tools_extras` for every stage, elides empty
   segments, and emits `base,profile,extras` left-to-right. Concrete
   shape:

   ```bash
   local profile_tools
   profile_tools="$(_dispatch_tools_from_profile "$1")"
   local extras
   extras="$(_dispatch_tools_extras "$1")"
   local result="$base"
   [[ -n "$profile_tools" ]] && result="$result,$profile_tools"
   [[ -n "$extras"        ]] && result="$result,$extras"
   printf '%s' "$result"
   ```

4. **D-6 fixtures in tree.** `bin/dispatch-test.sh` gains 5 new
   fixture groups (appended after the existing ENG-53 #8 block at
   lines 2122–2168, before the final RESULTS block at line 2170):
   Tauri profile (back-compat — implementing/ui/qa get cargo/bun/
   rustc back via profile), Python profile (pytest/pip/python3 in
   implementing/qa; no cargo), Go profile (`Bash(go test:*)` /
   `Bash(go build:*)` / `Bash(go vet:*)` / `Bash(gofmt:*)`; no
   cargo), fallback (schema_version 1 — captures stderr, asserts
   exactly one `[allowed-tools]` warning fires and the composed
   string lacks `Bash(cargo:*)`), and empty-section (schema_version
   2 with `- implementing: (none)` — captures stderr, asserts NO
   warning fires). Each fixture uses the canonical source-and-override
   pattern (post-source override of `HARNESS_ROOT` to a `mktemp -d`
   layout holding a stubbed `learned-rules/<slug>/project-profile.md`).

5. **D-7 docs rewrite in tree.** `CLAUDE.md`'s `## Per-target
   dispatch.tools extras (ENG-51, ENG-53 #8)` section (currently
   lines 265–318) is rewritten as `## Per-target dispatch.tools
   extras and profile-derived tools (ENG-51, ENG-53 #8, ENG-94)`.
   The opening paragraph's "ships a Tauri-shaped base allowlist" is
   replaced with "ships a stack-neutral base allowlist; per-target
   stack tools come from the project profile's Tool allowlist
   section (ENG-94)." A new paragraph documents the
   `base → profile → extras` composition order and the warn-and-
   fall-through fallback contract. The "Wildcard pitfall" callout
   (lines 271–293) and the regeneration one-liner (lines 303–313)
   are preserved verbatim — both apply equally to extras AND
   (post-ENG-94) profile-derived patterns.

6. **Test gate green.** Every `bin/*-test.sh` exits 0 (in particular
   `bash bin/dispatch-test.sh` exits 0 with the five new fixture
   groups passing AND the pre-existing ENG-53 #8 wildcard guard at
   lines 2122–2168 continuing to pass per AC#5); `bash -n
   bin/dispatch.sh` exits 0; `bash bin/secret-probe-lint.sh` exits 0;
   `bash .githooks/pre-commit` exits 0.

Verifiable by:

```
bash bin/dispatch-test.sh \
  && bash bin/secret-probe-lint.sh \
  && bash .githooks/pre-commit
```

exiting 0.

Out of scope (explicit per issue "Scope Boundaries OUT" + brainstorm §11):

- **T1 schema definition.** `bin/setup-helpers.sh::_validate_project_profile_schema`
  at `bin/setup-helpers.sh:128–159` currently enforces 5 H2 sections
  + `schema_version: 1`. T1 (separate ticket) extends to 6 sections
  (`## Tool allowlist`) + bumps to `schema_version: 2`. ENG-94 reads
  the v2 shape but does NOT bump or validate it; the helper's D-3
  warn-and-elide behavior is the bridge.
- **T3 / T4 / T5.** `bin/run-local-helpers.sh::partition_dirty_paths`,
  `bin/scope-check.sh`, and `AGENT_PROMPTS.md` are not touched.
- **`bin/render-prompt.sh`.** `render-prompt.sh:149,159–161`'s profile-
  prompt-append path is untouched; ENG-94 is a SECOND profile reader
  (per brainstorm §3 "Architectural seam") with its own (small) parser
  rather than a shared helper. Future-fourth-reader extraction commitment
  recorded in brainstorm §3; not a deliverable here.
- **Narrowing the `qa` case arm's wide `Bash(git:*)`.** Asymmetric with
  `implementing` / `ui` (which enumerate ~25 individual `Bash(git
  <verb>:*)` tokens). Deliberately preserved per brainstorm §11
  "Deliberately-not-narrowed" carve-out (qa stages legitimately
  invoke `git fetch`, `git rebase`, possibly `git rerere`).
- **Operator-mental-model runbook entry for the T1 + ENG-94 rollout
  coordination.** Brainstorm §10 OQ-6 flags the future-work runbook
  entry; not in this plan's File Structure.
- **`learned-rules/harness/build.md` hand-edit.** Retrospective owns
  this file's mutations per the `pipeline:rule-reviewed` gate.

## Architecture

Three files change. No new files. No new test scripts. No new
dependencies. The architectural pivot is "add a sibling extension
lane to ENG-51's extras lane, sourced from the project profile that
T1 already authors."

There is no `docs/VISION.md`, no `docs/knowledge/decisions.md`, no
`docs/knowledge/gotchas.md` (verified: `ls docs/` returns
`architecture.md  assumptions.md  brainstorms/  configuration.md
cost.md  demos/  install.md  operations.md  pipeline-vocabulary.md
pipeline-vocabulary.template.md  plans/  runbooks/  security.md` —
no `knowledge/` subdir). Governing constraints come from `CLAUDE.md`,
the brainstorm itself, ENG-51's precedent (`_dispatch_tools_extras`
shape), and the 2026-04-27 stack-aware brainstorm (which established
the project profile as load-bearing).

Three layers, three independent regression guards:

- **Code layer** (`bin/dispatch.sh`): the new helper, the case-arm
  cleanups, and the three-way composition tail. This is the authoritative
  site for `--allowed-tools` argv shape.
- **Test layer** (`bin/dispatch-test.sh`): 5 fixtures that exercise
  the parser end-to-end against stubbed profile files. Each fixture
  uses an isolated `HARNESS_ROOT` override per the source-and-stub
  pattern documented in `bin/render-prompt-slug-test.sh:32–63`. The
  existing ENG-53 #8 block at lines 2122–2168 continues to PASS
  without edit (config-extras still pass through verbatim — AC#5).
- **Documentation layer** (`CLAUDE.md` § "Per-target dispatch.tools
  extras and profile-derived tools"): operator-facing prose explaining
  the new composition order, the warn-and-fall-through fallback, and
  the preserved wildcard-pitfall + regeneration callouts.

## Tech stack

- Bash 3.2+ (Darwin default).
- `awk` for markdown parsing (already a documented harness runtime
  dependency per `learned-rules/harness/project-profile.md:12`).
  Specifically: macOS BSD awk and GNU awk are both supported by the
  proposed grammar (the regex uses `match($0, /<pat>/, m)` which is
  gawk-specific; the helper falls back to `awk '<pat>/ {...}'` with a
  capture-via-substr approach for BSD awk — see Task 1 Step 1.2
  below). **However**, the existing harness's awk usage (e.g.,
  `bin/setup-helpers.sh:134–148`) already uses BSD-compatible awk
  patterns (no `match(..., m)` array-capture form), and the proposed
  helper will follow the same idiom: capture by line-prefix-strip via
  `sub()` rather than regex capture groups. Detailed grammar in Task 1.
- `_dispatch_tools_extras`'s existing jq-based contract (`bin/dispatch.sh:
  291–300`) is preserved unchanged.
- `log` from `bin/common.sh:30–32` writes to stderr (`printf '...' >&2`)
  — the warning lands in `$PROJECT_STATE_DIR/<ident>/logs/<stage>-*.log`
  per brainstorm OQ-3.

## Assumption Inventory

Every modified-file fact below is `path:line`-cited against the current
worktree per the codebase-fact verification mandate. Each entry quotes
the relevant region (or signature) so the implement agent can confirm
the target without re-deriving it.

### Files modified in this plan: 3

- `bin/dispatch.sh` (D-1 new helper; D-1 case-arm cleanups at lines
  324, 325, 327; D-2/D-4 composition-tail rewrite at lines 333–339)
- `bin/dispatch-test.sh` (D-6 five new fixture groups appended after
  line 2168, before the final RESULTS block at line 2170)
- `CLAUDE.md` (D-7 section rewrite at lines 265–318)

### Modified-file facts — current state, signatures, and verification points

- **A-001 — `bin/dispatch.sh:302` opens `allowed_tools_for` and
  `bin/dispatch.sh:331` carries the `*) die "no allowed-tools
  profile for stage: $1" ;;` default-case.** Verified by direct read.
  The function signature is parameterless-by-position (uses `$1`
  inline; no local-rebinding). Insertion points:
  - new helper `_dispatch_tools_from_profile` between
    `bin/dispatch.sh:300` (closing `}` of `_dispatch_tools_extras`)
    and `bin/dispatch.sh:302` (`allowed_tools_for() {` opening).
  - case-arm token edits inline at lines 324, 325, 327.
  - composition-tail rewrite replacing lines 333–339.

- **A-002 — `bin/dispatch.sh:324` (`implementing` case arm) carries
  `Bash(cargo:*),Bash(bun:*),Bash(rustc:*)` literally.** Verified by
  direct read:
  ```
  implementing)   base='Read,Write,Edit,Grep,Glob,TaskCreate,Bash(git status:*),Bash(git log:*),Bash(git diff:*),Bash(git show:*),Bash(git add:*),Bash(git rm:*),Bash(git mv:*),Bash(git restore:*),Bash(git commit:*),Bash(git checkout:*),Bash(git switch:*),Bash(git fetch:*),Bash(git pull:*),Bash(git push:*),Bash(git rebase:*),Bash(git merge:*),Bash(git branch:*),Bash(git stash:*),Bash(git ls-files:*),Bash(git rev-parse:*),Bash(git rev-list:*),Bash(git for-each-ref:*),Bash(git tag:*),Bash(git describe:*),Bash(cargo:*),Bash(bun:*),Bash(rustc:*),Bash(jq:*),Bash(awk:*),Bash(bash .pipeline/bin/linear.sh:*),Bash(bash bin/linear.sh:*),Bash(bash .pipeline/bin/pipeline.sh:*),Bash(bash bin/pipeline.sh:*)' ;;
  ```
  Cleanup removes `Bash(cargo:*),Bash(bun:*),Bash(rustc:*),`
  (note the trailing comma; the surviving `Bash(jq:*),Bash(awk:*)`
  continues immediately after, joined by a single comma). Note that
  `implementing` carries `Bash(cargo:*),Bash(bun:*),Bash(rustc:*)` but
  NOT `Bash(npx:*),Bash(node:*)` (the latter two appear in `ui` and
  `qa`, not in `implementing`).

- **A-003 — `bin/dispatch.sh:325` (`ui` case arm) carries
  `Bash(cargo:*),Bash(bun:*),Bash(npx:*),Bash(node:*)` literally.**
  Verified by direct read:
  ```
  ui)             base='Read,Write,Edit,Grep,Glob,TaskCreate,Agent,Bash(git status:*),Bash(git log:*),Bash(git diff:*),Bash(git show:*),Bash(git add:*),Bash(git rm:*),Bash(git mv:*),Bash(git restore:*),Bash(git commit:*),Bash(git checkout:*),Bash(git switch:*),Bash(git fetch:*),Bash(git pull:*),Bash(git push:*),Bash(git rebase:*),Bash(git merge:*),Bash(git branch:*),Bash(git stash:*),Bash(git ls-files:*),Bash(git rev-parse:*),Bash(git rev-list:*),Bash(git for-each-ref:*),Bash(git tag:*),Bash(git describe:*),Bash(cargo:*),Bash(bun:*),Bash(npx:*),Bash(node:*),Bash(jq:*),Bash(awk:*),Bash(bash .pipeline/bin/linear.sh:*),Bash(bash bin/linear.sh:*),Bash(bash .pipeline/bin/pipeline.sh:*),Bash(bash bin/pipeline.sh:*)' ;;
  ```
  Cleanup removes `Bash(cargo:*),Bash(bun:*),Bash(npx:*),Bash(node:*),`
  (the trailing comma is dropped because `Bash(jq:*),Bash(awk:*)`
  immediately follows). Note: ui does NOT carry `Bash(rustc:*)`
  (rustc was implementing-only).

- **A-004 — `bin/dispatch.sh:327` (`qa` case arm) carries
  `Bash(cargo:*),Bash(bun:*),Bash(npx:*),Bash(node:*)` AND wide
  `Bash(git:*)` literally.** Verified by direct read:
  ```
  qa)             base='Read,Write,Edit,Grep,Glob,TaskCreate,Agent,Bash(git:*),Bash(cargo:*),Bash(bun:*),Bash(npx:*),Bash(node:*),Bash(jq:*),Bash(awk:*),Bash(gh pr view:*),Bash(gh pr diff:*),Bash(gh pr comment:*),Bash(gh issue create:*),Bash(gh issue list:*),Bash(bash .pipeline/bin/linear.sh:*),Bash(bash bin/linear.sh:*),Bash(bash .pipeline/bin/pipeline.sh:*),Bash(bash bin/pipeline.sh:*),Bash(bash .pipeline/bin/guards.sh:*),Bash(bash bin/guards.sh:*)' ;;
  ```
  Cleanup removes `Bash(cargo:*),Bash(bun:*),Bash(npx:*),Bash(node:*),`
  (after `Bash(git:*),`); `Bash(git:*)` and `Bash(jq:*),Bash(awk:*)`
  are PRESERVED. The asymmetry with implementing/ui's enumerated
  `git <verb>` tokens is deliberate per brainstorm §11.

- **A-005 — `_dispatch_tools_extras` is defined at `bin/dispatch.sh:
  291–300` and reads `CONFIG`'s `.dispatch.tools[$stage]`.** Verified
  by direct read:
  ```bash
  _dispatch_tools_extras() {
    local stage="$1"
    [[ -f "${CONFIG:-}" ]] || return 0
    jq -r --arg s "$stage" '
      (.dispatch.tools[$s] // []) as $arr
      | if ($arr | type) == "array"
        then $arr | map(select(type == "string")) | join(",")
        else "" end
    ' "$CONFIG" 2>/dev/null || true
  }
  ```
  The new `_dispatch_tools_from_profile` MUST mirror this contract:
  same parameter shape (`stage="$1"`), same return convention (empty
  string on missing/malformed input, no `die`), same use of `local`
  inside the function, and same defensive `[[ -f ... ]] || return 0`
  guard for the missing-file case (per D-3 first bullet).

- **A-006 — `allowed_tools_for` composition tail at `bin/dispatch.sh:
  333–339`.** Verified by direct read:
  ```bash
    local extras
    extras="$(_dispatch_tools_extras "$1")"
    if [[ -n "$extras" ]]; then
      printf '%s,%s' "$base" "$extras"
    else
      printf '%s' "$base"
    fi
  ```
  The rewrite replaces this 7-line block with the 8-line three-way
  composition described in Goal §3 and Task 2 Step 2.2 below.
  Function-trailing brace at line 340 is preserved verbatim.

- **A-007 — `bin/common.sh:9` exports `HARNESS_ROOT`; lines 47–62
  resolve `PROJECT_SLUG`.** Verified by direct read:
  - `bin/common.sh:9`: `HARNESS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"`
  - `bin/common.sh:20`: `export HARNESS_ROOT TARGET_REPO HARNESS_STATE_DIR ...`
  - `bin/common.sh:47–55`: `PROJECT_SLUG` resolution from `CONFIG`'s
    `.project.slug` (or pre-set env, or empty under `TWINNING_BOOTSTRAPPING`).
  - `bin/common.sh:62`: `export HARNESS_CONFIG_DIR PROJECT_SLUG PROJECT_STATE_DIR`

  The new helper relies on BOTH being populated post-`source common.sh`.
  When either is empty (the TWINNING_BOOTSTRAPPING path or a test
  fixture without slug), the helper returns empty silently (NO warning)
  — per D-3 second-to-last and last bullets.

- **A-008 — `bin/common.sh:30–32` defines `log`.** Verified by direct
  read:
  ```bash
  log() {
    printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
  }
  ```
  `log` writes to stderr — the helper's warning lands in
  `$PROJECT_STATE_DIR/<ident>/logs/<stage>-*.log` via `run-stage.sh`'s
  2>&1 capture, NOT in the day-log (per brainstorm OQ-3).

- **A-009 — `learned-rules/harness/project-profile.md` currently has
  `schema_version: 1` and lacks a `## Tool allowlist` section.**
  Verified by direct read:
  - line 5: `schema_version: 1`
  - the H2 headings in order are: `## Stack`, `## Build & test
    gates`, `## File layout`, `## Language idioms`, `## Don'ts` (5
    sections per `bin/setup-helpers.sh:128–159`'s current contract).
  - No `## Tool allowlist` section exists on disk today; T1 will
    add it.

  The helper's `[[ -f ... ]]` guard returns empty when the file
  exists but lacks the section (per D-3 third bullet, fires the
  "section not found" warning); when `schema_version != 2`, the
  first warn branch fires regardless of section presence. **A
  schema-v1 host running ENG-94 code gets the schema-version warning
  and the helper returns empty**, so composition collapses to
  `base + extras` (the same as today, but with cargo/bun/rustc
  removed from base — i.e., a Tauri host without re-discovery loses
  cargo/bun on the first ENG-94 tick; this is the OQ-6 rollout-
  coordination tradeoff documented in brainstorm §10).

- **A-010 — `bin/dispatch-test.sh:1–66` is the test scaffold.**
  Verified by direct read. Key globals exported at the file's top:
  - `TARGET_REPO="$_TEST_TARGET_DIR"` (a `mktemp -d` path)
  - `PROJECT_SLUG="${PROJECT_SLUG:-test-slug}"`
  - `HARNESS_STATE_DIR="$_TEST_STUB_DIR/state"`
  - `PROJECT_STATE_DIR="${HARNESS_STATE_DIR}/${PROJECT_SLUG}"`

  The script then runs `source "$SCRIPT_DIR/dispatch.sh"` (line 70)
  to import `allowed_tools_for` for direct invocation. The D-6
  fixtures will follow the SAME pattern but with per-fixture
  `HARNESS_ROOT` overrides — `HARNESS_ROOT` is set by `source
  common.sh` (via dispatch.sh's line 18), and as a script-global
  it CAN be re-assigned post-source for fixture isolation (the
  documented source-and-override pattern; verified by precedent in
  `bin/render-prompt-slug-test.sh:32–35` which uses
  `HARNESS_REPO_ROOT="$(cd "$HARNESS_DIR/.." && pwd)"` then
  `mkdir -p "$HARNESS_REPO_ROOT/learned-rules/test-slug"`).

- **A-011 — `bin/dispatch-test.sh:2090` carries the existing local
  `HARNESS_ROOT` re-assignment.** Verified by direct read:
  `HARNESS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"`. This is the existing
  Gap-7 contract-check block; it establishes that re-assigning
  `HARNESS_ROOT` post-source is a documented in-test idiom. The D-6
  fixtures use the same idiom but point at fixture roots (a `mktemp
  -d`-based `learned-rules/<slug>/project-profile.md`).

- **A-012 — `bin/dispatch-test.sh:2122–2168` is the ENG-53 #8 block.**
  Verified by direct read. The block opens at line 2122 with
  `# ─── ENG-53 #8: harness target's dispatch.tools populated ─` and
  closes at line 2168 with the `else printf 'SKIP ENG-53#8: ...';
  fi` clause. The final `printf '\nRESULTS: ...'` summary block sits
  at lines 2170–2172. D-6's five new fixture groups insert between
  line 2168 (closing `fi` of the ENG-53 #8 block) and line 2170
  (the `# ─── Summary ─` comment). This block must NOT be modified
  per AC#5 — the wildcard pitfall guard continues to work.

- **A-013 — Worktree's `learned-rules/<slug>/project-profile.md`
  files do NOT yet have schema_version 2.** Verified: `cat
  learned-rules/harness/project-profile.md | head -6` returns
  `schema_version: 1`. The helper's logic is designed against the
  addendum-shape spec in THIS prompt's project-profile addendum
  (verified by reading the addendum: `## Tool allowlist` section
  format is `- <stage>:` top-level bullets with `  - \`Bash(...)\``
  sub-bullets — matched by the awk grammar in Task 1 Step 1.2). If
  T1 chooses a different micro-format at implementation time, the
  awk regex in Task 1 needs alignment. **Marked assumed/T1-dependent.**

- **A-014 — `_validate_project_profile_schema` at `bin/setup-helpers.sh:
  128–159` enforces schema_version 1 + 5 H2 sections today.**
  Verified by direct read. T1 (separate ticket) bumps to v2 and adds
  the 6th section. ENG-94 does NOT modify this validator (per Out of
  Scope; T1 owns it).

- **A-015 — `render-prompt.sh:144–166` profile-append path.**
  Verified by direct read. `render-prompt.sh:152` dies on missing
  profile; `render-prompt.sh:159–161` warns (non-fatal) on
  `schema_version != 1`. ENG-94 does NOT modify this — the helper
  lives in `dispatch.sh` per D-1 (rejected alternative was
  co-location in `render-prompt.sh`). Post-T1, render-prompt's
  warning will fire on every dispatch until either (a) T1 also
  updates `render-prompt.sh:159` to accept v2, or (b) operators
  accept the harmless warning. **Brainstorm §10 OQ-4 defers this
  decision to T1.** ENG-94 is unaffected by either outcome.

- **A-016 — `awk` is in the harness's documented runtime toolset.**
  Verified by reading `learned-rules/harness/project-profile.md:12`:
  `Runtime tools: jq (JSON), awk, sed, gtimeout (GNU coreutils), ...`.
  No new runtime dependency; the helper uses the same awk as
  `bin/setup-helpers.sh:134–148`'s frontmatter check.

- **A-017 — `bin/dispatch-test.sh:2170–2172` is the file trailer.**
  Verified by direct read:
  ```bash
  # ─── Summary ────────────────────────────────────────────────────────────
  printf '\nRESULTS: %d passed, %d failed\n' "$PASS" "$FAIL"
  [[ "$FAIL" == 0 ]] || exit 1
  ```
  D-6's fixture insert at line 2169 sits before this trailer and
  does not alter it. The fixtures increment `PASS` via the existing
  `pass_at` helper at line 75; `FAIL` counts are unchanged on a
  green run.

- **A-018 — `CLAUDE.md:265–318` is the "Per-target dispatch.tools
  extras (ENG-51, ENG-53 #8)" section.** Verified by direct read.
  Block structure:
  - line 265: `## Per-target dispatch.tools extras (ENG-51, ENG-53 #8)`
  - lines 267–269: opening paragraph naming "Tauri-shaped base"
  - lines 271–293: "Wildcard pitfall" callout + JSON example
  - lines 295–301: stage-key convention + harness-self requirement
  - lines 303–313: regeneration one-liner (the TESTS / LIST / jq pipeline)
  - lines 315–318: closing paragraph naming the `bin/dispatch-test.sh`
    static check.

  D-7 rewrites the heading and the opening paragraph, INSERTS a new
  paragraph documenting the composition order, PRESERVES the
  wildcard-pitfall callout + JSON example + regen one-liner + closing
  paragraph verbatim, and INSERTS a sentence clarifying that the
  regen one-liner applies symmetrically to the profile's Tool
  allowlist (auto-curated) and extras (operator-curated).

- **A-019 — Plan filename carries the `eng-94` token in its basename.**
  The plan doc at
  `docs/plans/2026-05-13-eng-94-make-dispatch-sh-allowed-tools-for-consume-project-profile-tools-drop-hardcoded-tauri-base.md`
  carries the `eng-94` substring per `partition_dirty_paths::D-004`'s
  in-scope bucketing requirement (consistent with all other plan docs
  in `docs/plans/`).

- **A-020 — No new files outside `docs/plans/`.** This plan adds
  exactly one new file (the plan doc itself); D-1 / D-2 / D-3 / D-4
  / D-5 / D-6 / D-7 / D-8 all edit existing files in place. The
  new helper `_dispatch_tools_from_profile` is inserted inside the
  existing `bin/dispatch.sh`, not a new script.

- **A-021 — Brainstorm assumption-inventory rows 11 and 12 are
  T1-dependent and marked assumed.** Verified by reading brainstorm
  §13 lines 902–903 of the brainstorm doc. The plan inherits both:
  the awk grammar in Task 1 Step 1.2 is designed against the
  addendum-shape (`## Tool allowlist` section with `- <stage>:` top-
  level bullets and `  - \`Bash(...)\`` sub-bullets) and may need
  alignment if T1's final micro-format differs. **No code-level
  certainty here; T1 ships before ENG-94 can be exercised on a real
  v2 profile.** The empty-string fallback per D-3 covers the
  schema-skew case.

- **A-022 — `bin/dispatch-test.sh` `PROJECT_SLUG` resolution.**
  Verified at `bin/dispatch-test.sh:18`: `export PROJECT_SLUG=
  "${PROJECT_SLUG:-test-slug}"`. Each new fixture sets a unique
  per-fixture slug (e.g., `eng94-tauri-slug`, `eng94-python-slug`,
  `eng94-go-slug`, `eng94-fallback-slug`, `eng94-empty-slug`) and
  re-assigns the global before invoking `allowed_tools_for`. After
  each fixture, the slug is reset to `test-slug` (the file-scope
  default) so subsequent pre-existing assertions are unaffected.

## File Structure

```
bin/
  dispatch.sh                                MODIFIED — D-1, D-2, D-4, D-5, D-8.
                                                        New helper _dispatch_tools_from_profile
                                                        (~25 lines) inserted between
                                                        _dispatch_tools_extras (lines 291–300)
                                                        and allowed_tools_for (line 302).
                                                        Case-arm cleanups at lines 324, 325,
                                                        327 (remove Bash(cargo:*),Bash(bun:*),
                                                        Bash(rustc:*),Bash(npx:*),Bash(node:*)
                                                        tokens). Composition tail rewrite at
                                                        lines 333–339 (extras-only → base +
                                                        profile + extras with empty-segment
                                                        elision).

  dispatch-test.sh                           MODIFIED — D-6. Five fixture groups appended
                                                        after line 2168 (closing fi of ENG-53
                                                        #8 block) and before line 2170
                                                        (RESULTS summary): Tauri back-compat,
                                                        Python, Go, fallback (schema_version 1
                                                        warn branch), empty-section
                                                        (schema_version 2 no-warn branch).
                                                        File grows from ~2173 lines to ~2330
                                                        lines.

CLAUDE.md                                    MODIFIED — D-7. Section heading rewritten at
                                                        line 265 (adds ENG-94 to title).
                                                        Opening paragraph at lines 267–269
                                                        rewritten ("stack-neutral base" not
                                                        "Tauri-shaped base"). New paragraph
                                                        documenting base → profile → extras
                                                        composition order inserted after
                                                        line 269. New paragraph documenting
                                                        the warn-and-fall-through fallback
                                                        contract inserted. Wildcard pitfall
                                                        block (lines 271–293) and regen
                                                        one-liner (lines 303–313) preserved
                                                        verbatim. Closing paragraph at lines
                                                        315–318 gains a sentence clarifying
                                                        symmetry with profile-derived patterns.

docs/
  plans/
    2026-05-13-eng-94-make-dispatch-sh-allowed-tools-for-consume-project-profile-tools-drop-hardcoded-tauri-base.md
                                             NEW — this file. Written at planning exit.
                                                   Bucketed in-scope via the eng-94 basename
                                                   token per partition_dirty_paths::D-004
                                                   (A-019).
```

No changes to: `bin/render-prompt.sh` (per A-015 / Out of Scope —
profile-append path untouched), `bin/setup-helpers.sh` (T1 owns the
schema validator), `bin/setup-prompts/discovery.md` (T1 owns the
discovery prompt), `bin/run-stage.sh`, `bin/run-local-helpers.sh`,
`bin/scope-check.sh`, `bin/verdict-handler.sh`, `bin/classify-failure.sh`,
`bin/metrics.sh`, `bin/poll.sh`, `bin/common.sh`, `bin/pipeline.sh`,
`bin/linear.sh`, `bin/branch-name.sh`, `AGENT_PROMPTS.md`,
`learned-rules/**` (the on-disk profile is still v1 — T1 ships the v2
shape), `launchd/**`, `.githooks/pre-commit`, `docs/runbooks/**`,
`docs/pipeline-vocabulary.md`, `bin/pipeline-events.json`.

## API Contract

**No new API surface.** The harness has no FE↔BE API surface (this
is a bash orchestration repo with no application code per the project
profile addendum: "The repo contains no application code"). The change
is an internal command-line argv composition update:

- No new `dispatch.sh::allowed_tools_for` case (existing eight cases
  are preserved; the helper is invoked uniformly).
- No new exit code (no new bash error path; the helper soft-fails to
  empty string + warning).
- No new metric event name.
- No new comment-body shape.
- No new orchestrator hook.
- No new lane fence.
- No new `bin/pipeline-events.json` registry entry.
- No `docs/pipeline-vocabulary.md` regeneration.
- The `--allowed-tools` argv shape is internal to the
  orchestrator-↔-claude subprocess invocation, not an external API.

## Backend Tasks

This plan commits to five concrete edits across three files (the new
helper, the case-arm cleanups, the composition-tail rewrite, the five
fixture groups, the CLAUDE.md rewrite) plus a verification step. The
implement agent runs the six tasks below; Task 0 is a baseline check,
Tasks 1, 4, and 5 can each run independently after Task 0 (they touch
different files), Tasks 2 and 3 depend on Task 1 (same file), Task 6
verifies all.

### Task 0: Confirm baseline (no-op verification)

- `depends_on: []`
- `touches: bin/dispatch.sh (read-only); bin/dispatch-test.sh (read-only); CLAUDE.md (read-only); learned-rules/harness/project-profile.md (read-only)`

- [ ] **Step 0.1.** Read `bin/dispatch.sh:291–340` and confirm:
  - lines 291–300: `_dispatch_tools_extras` function body matches
    A-005's quoted shape.
  - lines 302–340: `allowed_tools_for` function with eight case arms
    (lines 322–330), default `*) die ... ;;` (line 331), and
    extras-only composition tail (lines 333–339) matching A-006.
  - line 324 (`implementing` case arm) carries `Bash(cargo:*),
    Bash(bun:*),Bash(rustc:*)` per A-002. Note: implementing does
    NOT carry npx/node.
  - line 325 (`ui` case arm) carries `Bash(cargo:*),Bash(bun:*),
    Bash(npx:*),Bash(node:*)` per A-003. Note: ui does NOT carry
    rustc.
  - line 327 (`qa` case arm) carries `Bash(git:*),Bash(cargo:*),
    Bash(bun:*),Bash(npx:*),Bash(node:*)` per A-004. The wide
    `Bash(git:*)` is PRESERVED per brainstorm §11.

  If any line has drifted (another change merged between brainstorm
  and now), STOP and re-read the brainstorm §4 D-1/D-2/D-4 rationale
  before proceeding — the edits may need to merge with the new state.

- [ ] **Step 0.2.** Read `bin/dispatch-test.sh:2090–2172` and confirm:
  - line 2090: local `HARNESS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"`
    re-assignment per A-011 (the documented post-source override
    idiom).
  - lines 2122–2168: ENG-53 #8 block per A-012 (must NOT be modified
    per AC#5).
  - lines 2170–2172: file trailer per A-017.

- [ ] **Step 0.3.** Read `CLAUDE.md:265–318` and confirm the
  five-block structure per A-018 (heading + opening + wildcard
  pitfall + regen one-liner + closing).

- [ ] **Step 0.4.** Read `learned-rules/harness/project-profile.md`
  and confirm `schema_version: 1` at line 5 and the absence of any
  `## Tool allowlist` section per A-009 / A-013. This confirms the
  test fixtures cannot rely on the on-disk profile and MUST stub
  their own profile files under a fixture HARNESS_ROOT.

- [ ] **Step 0.5.** Run `git diff main...HEAD` and confirm zero
  delta on the three target files (`bin/dispatch.sh`,
  `bin/dispatch-test.sh`, `CLAUDE.md`). The feature branch was
  created off `origin/main` per `bin/run-local.sh::ensure_worktree`;
  any pre-existing delta on these three files means a stale worktree
  (escalate via `verdict halt --reason agent-blocked`).

### Task 1: D-1 / D-5 / D-8 — insert `_dispatch_tools_from_profile` helper in `bin/dispatch.sh`

- `depends_on: [0]`
- `touches: bin/dispatch.sh`

- [ ] **Step 1.1.** Use the Edit tool to insert the following helper
  function in `bin/dispatch.sh` BETWEEN the closing `}` of
  `_dispatch_tools_extras` at line 300 and the opening `allowed_tools_for() {`
  at line 302. The `old_string` should be the unambiguous boundary
  text spanning line 300's closing `}` + the blank line at 301 + the
  opening of line 302. The `new_string` adds the helper in between:

      # ENG-94: read the per-stage Tool allowlist block from the slug-aware
      # project profile and emit a comma-joined string ready to splice into
      # allowed_tools_for's base+extras composition. Sibling of
      # _dispatch_tools_extras; same soft-fail contract (empty string on
      # missing/malformed input, no die).
      #
      # Resolution: $HARNESS_ROOT/learned-rules/$PROJECT_SLUG/project-profile.md
      #
      # Fail-soft branches (D-3):
      #   - file absent OR HARNESS_ROOT/PROJECT_SLUG empty → empty, NO warning.
      #   - frontmatter missing OR schema_version != 2 → empty + ONE log warn.
      #   - schema_version 2, '## Tool allowlist' section absent → empty + ONE log warn.
      #   - section present, stage line absent OR sub-bullets empty/"(none)" → empty, NO warn.
      #   - awk parse failure → empty + ONE log warn.
      #
      # SEC (D-8): awk-side hygiene rejects Bash patterns containing shell
      # metacharacters (;, &, |, `, $(, >, <, newline, paren-imbalance) as
      # defense-in-depth against a profile commit that smuggles a chained
      # command into the allowlist. The warning text NEVER includes the
      # matched pattern text (ENG-46 secret-handling) — the pattern could
      # legitimately contain a $VAR reference that log's expansion would
      # leak into the per-stage transcript.
      _dispatch_tools_from_profile() {
        local stage="$1"
        [[ -n "${HARNESS_ROOT:-}" && -n "${PROJECT_SLUG:-}" ]] || return 0
        local profile_path="${HARNESS_ROOT}/learned-rules/${PROJECT_SLUG}/project-profile.md"
        [[ -f "$profile_path" ]] || return 0

        # Schema-version gate. Must be exactly `schema_version: 2` inside
        # frontmatter. Anything else (missing frontmatter, v1, malformed)
        # falls through with one warning. Use awk for the frontmatter
        # check to mirror bin/setup-helpers.sh:143–146's idiom.
        local has_v2
        has_v2="$(awk '
          NR==1 && $0=="---" { in_fm=1; next }
          in_fm && $0=="---" { exit }
          in_fm && /^schema_version:[[:space:]]+2[[:space:]]*$/ { print "yes"; exit }
        ' "$profile_path" 2>/dev/null)"
        if [[ "$has_v2" != "yes" ]]; then
          log "[allowed-tools] project-profile.md schema_version != 2; Tool allowlist not loaded for stage=$stage"
          return 0
        fi

        # Section presence gate. If '## Tool allowlist' header is absent,
        # warn and fall through.
        if ! grep -qE '^## Tool allowlist[[:space:]]*$' "$profile_path"; then
          log "[allowed-tools] project-profile.md::## Tool allowlist section not found; stage=$stage"
          return 0
        fi

        # Extract this stage's patterns. State machine: track section
        # presence, track current stage (top-level `- <stage>:` bullets),
        # emit any sub-bullet matching `^  - `Bash(...)`` for the
        # requested stage. D-8 hygiene rejects shell-metachar payloads.
        # BSD-awk compatible (no match($0, /<pat>/, m) capture groups —
        # capture via sub() prefix-strip instead).
        local result
        result="$(awk -v STAGE="$stage" '
          BEGIN { in_section=0; current_stage=""; first=1 }
          # Strip CRLF for cross-platform editor tolerance.
          { sub(/\r$/, "") }
          # Enter the Tool allowlist section.
          /^## Tool allowlist[ \t]*$/ { in_section=1; next }
          # Any subsequent H2 closes the section.
          in_section && /^## / { in_section=0; next }
          !in_section { next }
          # Top-level `- <stage>:` bullets switch the current stage.
          /^- [a-z]+:/ {
            line = $0
            sub(/^- /, "", line)
            sub(/:.*$/, "", line)
            current_stage = line
            next
          }
          # Sub-bullet `  - `Bash(...)`` lines belong to current_stage.
          current_stage == STAGE && /^  - `Bash\(/ {
            line = $0
            # Strip leading "  - `"
            sub(/^  - `/, "", line)
            # Strip trailing "`" plus anything after (paranoia).
            sub(/`.*$/, "", line)
            # line is now "Bash(<inner>)". Extract <inner> for hygiene.
            inner = line
            sub(/^Bash\(/, "", inner)
            sub(/\)$/, "", inner)
            # D-8 hygiene: reject shell metachars and command-substitution.
            if (inner ~ /[;&|`<>]/) next
            if (inner ~ /\$\(/) next
            if (inner ~ /\n/)   next
            # Paren-balance check.
            tmp = inner; opens = 0; closes = 0
            while (match(tmp, /\(/)) { opens++; tmp = substr(tmp, RSTART+1) }
            tmp = inner
            while (match(tmp, /\)/)) { closes++; tmp = substr(tmp, RSTART+1) }
            if (opens != closes) next
            # Emit Bash(<inner>) joined by commas.
            if (!first) printf ","
            printf "Bash(%s)", inner
            first = 0
          }
        ' "$profile_path" 2>/dev/null)" || {
          log "[allowed-tools] awk parse failure for stage=$stage"
          return 0
        }

        printf '%s' "$result"
      }

  Indentation: function body at 2-space indent. No tabs; spaces only
  (matching `_dispatch_tools_extras` at lines 291–300). Sentinel
  exclusion: the helper is NOT exported (matches `_dispatch_tools_extras`'s
  convention). The leading underscore signals "private to dispatch.sh".

- [ ] **Step 1.2.** Confirm the helper landed: run `grep -n
  '_dispatch_tools_from_profile()' bin/dispatch.sh` and expect exactly
  one match — the function definition. Then run `awk '/^_dispatch_tools_from_profile/,
  /^}$/' bin/dispatch.sh | wc -l` and expect a line count between 60
  and 90 (the helper body is ~75 lines including comments).

- [ ] **Step 1.3.** Confirm syntactic validity: run `bash -n
  bin/dispatch.sh` and expect exit 0.

### Task 2: D-1 case-arm cleanups in `bin/dispatch.sh`

- `depends_on: [1]`
- `touches: bin/dispatch.sh (lines 324, 325, 327)`

- [ ] **Step 2.1.** Use the Edit tool to remove `Bash(cargo:*),Bash(bun:*),Bash(rustc:*),`
  from line 324 (the `implementing` case arm). The `old_string` should
  span unambiguous context — specifically `Bash(git describe:*),Bash(cargo:*),Bash(bun:*),Bash(rustc:*),Bash(jq:*)`
  — and the `new_string` should be `Bash(git describe:*),Bash(jq:*)` (the
  three Tauri tokens removed, surrounding tokens preserved). The
  preceding `Bash(git describe:*)` token verifies via A-002's full
  line quote — it is `git describe`, not bare `describe`.

- [ ] **Step 2.2.** Use the Edit tool to remove `Bash(cargo:*),Bash(bun:*),Bash(npx:*),Bash(node:*),`
  from line 325 (the `ui` case arm). The `old_string` should span
  `Bash(git describe:*),Bash(cargo:*),Bash(bun:*),Bash(npx:*),Bash(node:*),Bash(jq:*)`
  and the `new_string` should be `Bash(git describe:*),Bash(jq:*)`.

- [ ] **Step 2.3.** Use the Edit tool to remove `Bash(cargo:*),Bash(bun:*),Bash(npx:*),Bash(node:*),`
  from line 327 (the `qa` case arm). The `old_string` should span
  `Bash(git:*),Bash(cargo:*),Bash(bun:*),Bash(npx:*),Bash(node:*),Bash(jq:*)`
  and the `new_string` should be `Bash(git:*),Bash(jq:*)` (the wide
  `Bash(git:*)` is PRESERVED per brainstorm §11; only the four
  Tauri tokens between it and `Bash(jq:*)` are removed).

- [ ] **Step 2.4.** Confirm AC#1: run
  `grep -nE 'Bash\((cargo|bun|rustc|npx|node):\*\)' bin/dispatch.sh`
  and expect zero hits in the case-arm region (lines 320–331). If
  hits appear OUTSIDE the case-arm region (e.g., in code comments,
  unlikely but possible), inspect to confirm they are not regressions.
  The brainstorm §1 ticket framing specifically targets the case arms;
  any incidental comment references can stay.

- [ ] **Step 2.5.** Confirm syntactic validity: run `bash -n
  bin/dispatch.sh` and expect exit 0.

### Task 3: D-2 / D-4 composition-tail rewrite in `bin/dispatch.sh`

- `depends_on: [1, 2]`
- `touches: bin/dispatch.sh (lines 333–339)`

(Strict sequencing — Task 2 and Task 3 both edit `bin/dispatch.sh`;
Task 3 runs after Task 2 so the Edit-tool boundaries Task 3 keys on
in the composition tail are not shifted by Task 2's case-arm token
removals. The line numbers cited in `:333–339` refer to the
PRE-Task-2 file; Task 2's token removals on lines 324/325/327 do
shorten those lines but do NOT remove any line, so the composition
tail's relative position is preserved and the `old_string` block
quoted in Step 3.1 below matches verbatim either way.)

- [ ] **Step 3.1.** Use the Edit tool to replace the current
  extras-only composition tail at `bin/dispatch.sh:333–339` (per
  A-006's quoted shape) with the three-way composition. The
  `old_string` is:
  ```bash
    local extras
    extras="$(_dispatch_tools_extras "$1")"
    if [[ -n "$extras" ]]; then
      printf '%s,%s' "$base" "$extras"
    else
      printf '%s' "$base"
    fi
  ```
  The `new_string` is:
  ```bash
    # ENG-94 composition order (D-2, D-4): base (case arm) → profile
    # (auto-discovered from learned-rules/<slug>/project-profile.md)
    # → extras (operator-curated via .pipeline-config/config.json::
    # dispatch.tools.<stage>[]). Empty segments are elided so no stray
    # commas leak into the --allowed-tools argv (claude's matcher is
    # delimiter-strict). The helper is invoked for EVERY stage; stages
    # whose profile section is `(none)` or absent return empty and
    # collapse to base+extras (pre-ENG-94 behavior preserved).
    local profile_tools
    profile_tools="$(_dispatch_tools_from_profile "$1")"
    local extras
    extras="$(_dispatch_tools_extras "$1")"
    local result="$base"
    [[ -n "$profile_tools" ]] && result="${result},${profile_tools}"
    [[ -n "$extras"        ]] && result="${result},${extras}"
    printf '%s' "$result"
  ```

  Indentation: 2-space (matching the rest of the function body).
  No tabs; spaces only. The closing `}` of `allowed_tools_for` at
  line 340 is preserved (the new block sits ABOVE it).

- [ ] **Step 3.2.** Confirm syntactic validity: run `bash -n
  bin/dispatch.sh` and expect exit 0.

- [ ] **Step 3.3.** Smoke-check the composition end-to-end by
  invoking `allowed_tools_for` in a sub-shell after sourcing
  dispatch.sh under the existing test scaffold's setup:
  ```bash
  (
    export PIPELINE_DRY_RUN=1
    export LINEAR_API_KEY=test-mock-key
    export PROJECT_SLUG=test-slug
    TGT=$(mktemp -d); mkdir -p "$TGT/.pipeline-config/schemas"
    printf '{"linear":{},"project":{"slug":"test-slug"},"orchestrator":{}}\n' > "$TGT/.pipeline-config/config.json"
    printf '{}\n' > "$TGT/.pipeline-config/schemas/linear-ids.json"
    export TARGET_REPO="$TGT"
    source bin/dispatch.sh
    allowed_tools_for implementing
  )
  ```
  The output must (a) NOT contain `Bash(cargo:*)`, (b) start with
  `Read,Write,Edit,Grep,Glob,TaskCreate,`, (c) end with the linear /
  pipeline dual-path wrappers, (d) not have a trailing comma. This
  is a quick sanity check before Task 4 ships the formal fixtures.

### Task 4: D-6 — five fixture groups in `bin/dispatch-test.sh`

- `depends_on: [3]`
- `touches: bin/dispatch-test.sh (insert after line 2168, before line 2170)`

This task adds five fixture groups. Each fixture follows the same
shape (set per-fixture `PROJECT_SLUG` + override `HARNESS_ROOT` to a
`mktemp -d` fixture root containing a stubbed
`learned-rules/<slug>/project-profile.md`; invoke `allowed_tools_for
<stage>`; assert composed output; reset overrides). The fixtures are
sequential to avoid `HARNESS_ROOT` cross-contamination across tests
(each fixture's trap cleans its own tempdir).

- [ ] **Step 4.1.** Use the Edit tool to insert the fixture block
  IMMEDIATELY AFTER line 2168 (the closing `fi` of the ENG-53 #8
  block per A-012) and BEFORE line 2170 (the `# ─── Summary ─` header
  per A-017). The `old_string` should be the unambiguous boundary —
  specifically the `fi` at line 2168 plus the blank line and the
  `# ─── Summary ─` header at line 2170. The `new_string` adds the
  fixture block in between.

  The fixture block opens with:
  ```bash
  # ─── ENG-94: dispatch.sh::allowed_tools_for consumes project-profile Tool allowlist ───
  # Five fixtures exercising _dispatch_tools_from_profile + composition tail:
  #   1. Tauri profile (back-compat) — implementing/ui/qa regain cargo/bun/rustc/npx/node
  #      via profile, NOT via base.
  #   2. Python profile — implementing/qa get pytest, NOT cargo.
  #   3. Go profile — implementing/qa get `go test`, NOT cargo.
  #   4. Fallback fixture (AC#3 warn branch) — schema_version 1 → empty + warning.
  #   5. Empty-section fixture (AC#3 no-warn branch) — schema_version 2 with
  #      `- implementing: (none)` → empty + NO warning.
  #
  # Each fixture overrides HARNESS_ROOT to a mktemp -d layout (matching the
  # source-and-override pattern documented in bin/render-prompt-slug-test.sh:32–63).
  # The pre-existing HARNESS_ROOT (set at line 2090 for the Gap-7 contract check)
  # is restored at the end of each fixture so subsequent assertions are unaffected.
  printf '\n--- ENG-94: project-profile Tool allowlist composition ---\n'
  _ENG94_SAVED_HARNESS_ROOT="$HARNESS_ROOT"
  _ENG94_SAVED_PROJECT_SLUG="$PROJECT_SLUG"
  ```

- [ ] **Step 4.2 — Fixture 1 (Tauri back-compat).** Append:
  ```bash
  # Fixture 1 — Tauri profile (back-compat). Stub a schema_version 2 profile
  # listing cargo/bun/rustc for implementing, cargo/bun/npx/node for ui, and
  # cargo/bun/npx/node for qa. Assert each stage's composed return value
  # contains the Tauri tokens via PROFILE (not via base).
  _ENG94_TAURI_ROOT="$(mktemp -d)"
  mkdir -p "$_ENG94_TAURI_ROOT/learned-rules/eng94-tauri-slug"
  cat > "$_ENG94_TAURI_ROOT/learned-rules/eng94-tauri-slug/project-profile.md" <<'PROFILE'
  ---
  slug: eng94-tauri-slug
  generated_at: 2026-05-13T00:00:00Z
  generated_by: eng94-test
  schema_version: 2
  ---

  # Project profile — eng94-tauri-slug

  ## Stack
  Tauri (test fixture).

  ## Build & test gates
  - Build: `bun tauri build`
  - Test: `cargo test`
  - Lint/check: `cargo clippy`
  - Integration/E2E: `(n/a)`

  ## Tool allowlist
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
  - test fixture.

  ## Language idioms
  - test.

  ## Don'ts
  - none.
  PROFILE
  HARNESS_ROOT="$_ENG94_TAURI_ROOT"
  PROJECT_SLUG="eng94-tauri-slug"
  _ENG94_TAURI_IMPL="$(allowed_tools_for implementing 2>/dev/null)"
  _ENG94_TAURI_UI="$(allowed_tools_for ui 2>/dev/null)"
  _ENG94_TAURI_QA="$(allowed_tools_for qa 2>/dev/null)"

  for token in 'Bash(cargo:*)' 'Bash(bun:*)' 'Bash(rustc:*)'; do
    if [[ "$_ENG94_TAURI_IMPL" == *"$token"* ]]; then
      pass_at "ENG-94 Fixture 1 (Tauri): implementing carries $token via profile"
    else
      fail_at "ENG-94 Fixture 1 (Tauri): implementing missing $token" "got: $_ENG94_TAURI_IMPL"
    fi
  done
  for token in 'Bash(cargo:*)' 'Bash(bun:*)' 'Bash(npx:*)' 'Bash(node:*)'; do
    if [[ "$_ENG94_TAURI_UI" == *"$token"* ]]; then
      pass_at "ENG-94 Fixture 1 (Tauri): ui carries $token via profile"
    else
      fail_at "ENG-94 Fixture 1 (Tauri): ui missing $token" "got: $_ENG94_TAURI_UI"
    fi
    if [[ "$_ENG94_TAURI_QA" == *"$token"* ]]; then
      pass_at "ENG-94 Fixture 1 (Tauri): qa carries $token via profile"
    else
      fail_at "ENG-94 Fixture 1 (Tauri): qa missing $token" "got: $_ENG94_TAURI_QA"
    fi
  done
  # Pin AC#1: base no longer carries the tokens (the profile is the sole source).
  # The composition is base,profile,extras — base should NOT contain cargo etc.
  # We assert this by clearing the profile and re-checking:
  HARNESS_ROOT="$_TEST_STUB_DIR/empty-root"  # no profile path → empty
  mkdir -p "$HARNESS_ROOT"
  _ENG94_BARE_IMPL="$(allowed_tools_for implementing 2>/dev/null)"
  if [[ "$_ENG94_BARE_IMPL" != *'Bash(cargo:*)'* ]]; then
    pass_at "ENG-94 AC#1: implementing base (no profile) does NOT contain Bash(cargo:*)"
  else
    fail_at "ENG-94 AC#1: implementing base still carries Bash(cargo:*) after case-arm cleanup" \
      "got: $_ENG94_BARE_IMPL"
  fi
  HARNESS_ROOT="$_ENG94_TAURI_ROOT"  # restore for any subsequent reference
  rm -rf "$_ENG94_TAURI_ROOT"
  ```

- [ ] **Step 4.3 — Fixture 2 (Python).** Append a near-identical
  block with `_ENG94_PYTHON_ROOT`, slug `eng94-python-slug`, and a
  profile that lists `Bash(pytest:*)`, `Bash(pip:*)`,
  `Bash(python3:*)` for implementing AND qa (other stages `(none)`).
  Assertions:
  - `implementing` composed output CONTAINS `Bash(pytest:*)`.
  - `implementing` composed output DOES NOT contain `Bash(cargo:*)`.
  - `qa` composed output CONTAINS `Bash(pytest:*)`.
  - `qa` composed output DOES NOT contain `Bash(cargo:*)`.

- [ ] **Step 4.4 — Fixture 3 (Go).** Append a near-identical block
  with `_ENG94_GO_ROOT`, slug `eng94-go-slug`, and a profile that
  lists `Bash(go test:*)`, `Bash(go build:*)`, `Bash(go vet:*)`,
  `Bash(gofmt:*)` for implementing AND qa. Assertions:
  - `implementing` composed output CONTAINS `Bash(go test:*)`.
  - `implementing` composed output DOES NOT contain `Bash(cargo:*)`.
  - `qa` composed output CONTAINS `Bash(go test:*)`.
  - `qa` composed output DOES NOT contain `Bash(cargo:*)`.

- [ ] **Step 4.5 — Fixture 4 (Fallback / AC#3 warn branch).**
  Append a block that stubs a schema_version 1 profile (no Tool
  allowlist section). Capture stderr to a tempfile when invoking
  `allowed_tools_for implementing`. Assertions:
  - composed output DOES NOT contain `Bash(cargo:*)` (case-arm
    cleanup applied).
  - composed output DOES NOT contain `Bash(pytest:*)` (no profile
    contribution).
  - stderr contains exactly ONE line matching `\[allowed-tools\]
    project-profile.md schema_version != 2`.
  - `allowed_tools_for` returns 0 (does NOT die).

  Concrete shape:
  ```bash
  _ENG94_FB_ROOT="$(mktemp -d)"
  mkdir -p "$_ENG94_FB_ROOT/learned-rules/eng94-fallback-slug"
  cat > "$_ENG94_FB_ROOT/learned-rules/eng94-fallback-slug/project-profile.md" <<'PROFILE'
  ---
  slug: eng94-fallback-slug
  schema_version: 1
  ---
  # Project profile — eng94-fallback-slug
  ## Stack
  test fixture.
  PROFILE
  HARNESS_ROOT="$_ENG94_FB_ROOT"
  PROJECT_SLUG="eng94-fallback-slug"
  _ENG94_FB_STDERR="$(mktemp)"
  _ENG94_FB_OUT="$(allowed_tools_for implementing 2>"$_ENG94_FB_STDERR")"
  _ENG94_FB_RC=$?
  if (( _ENG94_FB_RC == 0 )); then
    pass_at "ENG-94 Fixture 4 (Fallback): allowed_tools_for returns 0 (does NOT die on schema v1)"
  else
    fail_at "ENG-94 Fixture 4 (Fallback): allowed_tools_for exited non-zero (rc=$_ENG94_FB_RC)" ""
  fi
  if [[ "$_ENG94_FB_OUT" != *'Bash(cargo:*)'* ]]; then
    pass_at "ENG-94 Fixture 4 (Fallback): composed output lacks Bash(cargo:*) (AC#3 + AC#1)"
  else
    fail_at "ENG-94 Fixture 4 (Fallback): composed output unexpectedly contains Bash(cargo:*)" "got: $_ENG94_FB_OUT"
  fi
  _ENG94_FB_WARN_COUNT="$(grep -cE '\[allowed-tools\] project-profile.md schema_version != 2' "$_ENG94_FB_STDERR" || printf 0)"
  if [[ "$_ENG94_FB_WARN_COUNT" == "1" ]]; then
    pass_at "ENG-94 Fixture 4 (Fallback): exactly one schema-version warning fired"
  else
    fail_at "ENG-94 Fixture 4 (Fallback): expected 1 schema-version warning, got $_ENG94_FB_WARN_COUNT" \
      "stderr: $(cat "$_ENG94_FB_STDERR")"
  fi
  rm -f "$_ENG94_FB_STDERR"
  rm -rf "$_ENG94_FB_ROOT"
  ```

- [ ] **Step 4.6 — Fixture 5 (Empty-section / AC#3 no-warn branch).**
  Append a block that stubs a schema_version 2 profile with a present
  but empty Tool allowlist for `implementing` (`- implementing:
  (none)`). Assertions:
  - composed output DOES NOT contain `Bash(cargo:*)` (case-arm
    cleanup applied) AND DOES NOT contain any new tokens from the
    profile.
  - stderr contains ZERO lines matching `\[allowed-tools\]`.
  - `allowed_tools_for` returns 0.

  Concrete shape:
  ```bash
  _ENG94_ES_ROOT="$(mktemp -d)"
  mkdir -p "$_ENG94_ES_ROOT/learned-rules/eng94-empty-slug"
  cat > "$_ENG94_ES_ROOT/learned-rules/eng94-empty-slug/project-profile.md" <<'PROFILE'
  ---
  slug: eng94-empty-slug
  schema_version: 2
  ---
  # Project profile — eng94-empty-slug
  ## Stack
  test fixture.

  ## Tool allowlist
  - brainstorming: (none)
  - planning: (none)
  - implementing: (none)
  - ui: (none)
  - reviewing: (none)
  - qa: (none)
  - building: (none)
  - released: (none)
  PROFILE
  HARNESS_ROOT="$_ENG94_ES_ROOT"
  PROJECT_SLUG="eng94-empty-slug"
  _ENG94_ES_STDERR="$(mktemp)"
  _ENG94_ES_OUT="$(allowed_tools_for implementing 2>"$_ENG94_ES_STDERR")"
  if [[ "$_ENG94_ES_OUT" != *'Bash(cargo:*)'* ]]; then
    pass_at "ENG-94 Fixture 5 (Empty-section): composed output lacks Bash(cargo:*)"
  else
    fail_at "ENG-94 Fixture 5 (Empty-section): composed output unexpectedly contains Bash(cargo:*)" "got: $_ENG94_ES_OUT"
  fi
  _ENG94_ES_WARN_COUNT="$(grep -cE '\[allowed-tools\]' "$_ENG94_ES_STDERR" || printf 0)"
  if [[ "$_ENG94_ES_WARN_COUNT" == "0" ]]; then
    pass_at "ENG-94 Fixture 5 (Empty-section): no [allowed-tools] warning fired (no-warn discrimination)"
  else
    fail_at "ENG-94 Fixture 5 (Empty-section): unexpected [allowed-tools] warning(s) fired" \
      "stderr: $(cat "$_ENG94_ES_STDERR")"
  fi
  rm -f "$_ENG94_ES_STDERR"
  rm -rf "$_ENG94_ES_ROOT"
  ```

- [ ] **Step 4.7 — Restore overrides.** Append:
  ```bash
  HARNESS_ROOT="$_ENG94_SAVED_HARNESS_ROOT"
  PROJECT_SLUG="$_ENG94_SAVED_PROJECT_SLUG"
  unset _ENG94_SAVED_HARNESS_ROOT _ENG94_SAVED_PROJECT_SLUG
  ```
  This ensures subsequent tests (or future appended fixtures) inherit
  the pre-fixture environment.

- [ ] **Step 4.8 — Sanity checks.**
  - Run `bash -n bin/dispatch-test.sh` and expect exit 0 (syntactic
    validity after the multi-block insert).
  - Run `grep -nE '^# ─── ENG-94:' bin/dispatch-test.sh` and expect
    exactly one match (the new block's header — not somehow inserted
    twice).
  - Run `awk '/^# ─── Summary/{print NR; exit}' bin/dispatch-test.sh`
    and confirm the Summary header is still present and now sits
    AFTER the new ENG-94 block (its line number should be ~2330,
    not 2170).

### Task 5: D-7 — rewrite the `CLAUDE.md` "Per-target dispatch.tools extras" section

- `depends_on: [0]`
- `touches: CLAUDE.md (lines 265–318)`

- [ ] **Step 5.1.** Use the Edit tool to replace the section heading
  at line 265. `old_string`: `## Per-target dispatch.tools extras
  (ENG-51, ENG-53 #8)`; `new_string`: `## Per-target dispatch.tools
  extras and profile-derived tools (ENG-51, ENG-53 #8, ENG-94)`.

- [ ] **Step 5.2.** Use the Edit tool to replace the opening
  paragraph at lines 267–269. `old_string`:
  ```
  `dispatch.sh::allowed_tools_for` ships a Tauri-shaped base allowlist for each stage. To grant
  extra Bash patterns for a non-Tauri target (e.g., `pytest` for Python, `go test` for Go,
  the test-runner suite for harness-self), populate the target's `.pipeline-config/config.json`.
  ```
  `new_string`:
  ```
  `dispatch.sh::allowed_tools_for` ships a stack-neutral base allowlist for each stage. Per-target
  stack tools (`cargo` for Tauri, `pytest` for Python, `go test` for Go, etc.) flow from the
  project profile's `## Tool allowlist` section (`learned-rules/<slug>/project-profile.md`,
  schema_version 2; ENG-94). Operator-curated extras (e.g., the harness-self target's
  per-test-script enumeration for `bin/*-test.sh`) still come from the target's
  `.pipeline-config/config.json::dispatch.tools.<stage>[]` (ENG-51).

  The per-stage `--allowed-tools` argv is composed in left-to-right order:
  **base** (the stage's hardcoded case arm — Read/Write/Edit/Grep/Glob, git family, dual-path
  linear/pipeline/etc. wrappers) → **profile** (auto-discovered from the slug's project profile
  by `_dispatch_tools_from_profile`) → **extras** (operator-curated, ENG-51). Empty segments
  are elided so no stray commas leak into the argv. Claude's allowlist matcher is order-
  insensitive, so the ordering is for log-readability and reasoning clarity, not behavioral
  correctness.

  **Fallback contract.** If the profile is missing, has `schema_version != 2`, or lacks the
  `## Tool allowlist` section, `_dispatch_tools_from_profile` returns empty and emits a single
  `[allowed-tools]` warning to stderr. The composition collapses to `base + extras`; dispatch
  does NOT die (AC#3). The warning lands in `$PROJECT_STATE_DIR/<ident>/logs/<stage>-*.log`
  per ENG-94 OQ-3. Operator runbook entry for the T1 + ENG-94 rollout coordination is tracked
  as ENG-94 OQ-6 (future work).
  ```

- [ ] **Step 5.3.** Confirm the wildcard-pitfall callout at lines
  ~271–293 (post-edit line numbers will have shifted) is preserved
  verbatim. Run `grep -nF 'Wildcard pitfall.' CLAUDE.md` and expect
  exactly one match. The JSON example must remain unchanged.

- [ ] **Step 5.4.** Confirm the regeneration one-liner at lines
  ~303–313 is preserved verbatim. Run `grep -nF 'TESTS=$(ls bin/*-test.sh'
  CLAUDE.md` and expect exactly one match.

- [ ] **Step 5.5.** Use the Edit tool to amend the closing paragraph
  at lines ~315–318 by appending a sentence clarifying symmetry with
  profile patterns. `old_string`:
  ```
  `bin/dispatch-test.sh` asserts (a) no broken wildcard `Bash(bash bin/*-test.sh:*)` is
  present, and (b) the enumerated count covers every `bin/*-test.sh` on disk — catches
  drift when a new test is added but not allowlisted (skipped silently when
  `.pipeline-config/config.json` is absent — CI or non-harness operators).
  ```
  `new_string`:
  ```
  `bin/dispatch-test.sh` asserts (a) no broken wildcard `Bash(bash bin/*-test.sh:*)` is
  present, and (b) the enumerated count covers every `bin/*-test.sh` on disk — catches
  drift when a new test is added but not allowlisted (skipped silently when
  `.pipeline-config/config.json` is absent — CI or non-harness operators). The wildcard
  pitfall and the regeneration guidance apply symmetrically to the profile's `## Tool allowlist`
  section: discovery-emitted patterns must enumerate each script literally (no `Bash(bash
  bin/*-test.sh:*)` shape).
  ```

- [ ] **Step 5.6.** Sanity check: run
  `grep -nF 'ships a stack-neutral base allowlist' CLAUDE.md` and
  expect exactly one match. Run `grep -nF 'ships a Tauri-shaped base
  allowlist' CLAUDE.md` and expect ZERO matches (the old phrasing is
  fully removed).

### Task 6: Run the full test gate

- `depends_on: [2, 3, 4, 5]`
- `touches: (verification only — no file edits)`

- [ ] **Step 6.1 — Syntactic checks.** Run:
  ```
  bash -n bin/dispatch.sh && bash -n bin/dispatch-test.sh
  ```
  Both must exit 0.

- [ ] **Step 6.2 — Direct test invocation.** Run:
  ```
  bash bin/dispatch-test.sh
  ```
  Must exit 0 with a `RESULTS: <N+M> passed, 0 failed` line where
  `<N>` is the pre-edit `passed` count and `<M>` is the number of
  new asserts (a rough count: 3 cargo+bun+rustc asserts × 1 stage
  + 4 cargo+bun+npx+node asserts × 2 stages × 2 (carries via
  profile + base does not carry) ≈ 14 from Fixture 1, ~4 each from
  Fixtures 2 and 3, ~3 from Fixture 4, ~2 from Fixture 5 → roughly
  27 new pass lines). The pre-existing ENG-53 #8 block (lines
  2122–2168) must still PASS — AC#5.

- [ ] **Step 6.3 — Verify AC#5 (config-extras passthrough).**
  Scrutinize the test output for the ENG-53 #8 block's pass lines:
  ```
  bash bin/dispatch-test.sh 2>&1 | grep -E 'ENG-53#8'
  ```
  Must show pass lines, no fail lines.

- [ ] **Step 6.4 — Pre-commit hook end-to-end.** Run:
  ```
  bash .githooks/pre-commit
  ```
  Must exit 0. The hook runs the full `bin/*-test.sh` suite (~30 s);
  `dispatch-test.sh` is in the suite.

- [ ] **Step 6.5 — Secret-probe lint.** Run:
  ```
  bash bin/secret-probe-lint.sh
  ```
  Must exit 0. ENG-94's edits reference no secret-shaped env var.

- [ ] **Step 6.6 — Diff hygiene.** Run:
  ```
  git diff main...HEAD --stat
  ```
  Must show exactly four files changed: `bin/dispatch.sh`,
  `bin/dispatch-test.sh`, `CLAUDE.md`, and
  `docs/plans/2026-05-13-eng-94-...md` (the plan doc itself,
  written at planning-stage exit). If any other paths appear, the
  agent has introduced churn — investigate and revert before
  committing.

### Task 7: Stage commit + summary

- `depends_on: [6]`
- `touches: (commit only); $PROJECT_STATE_DIR/ENG-94/stage-summary-implementing.md`

- [ ] **Step 7.1.** Confirm `git status --porcelain` shows only the
  three target files plus the plan doc as modified/added (no
  untracked `.review-body.md` / `.qa-pr-comment.md` scratch files at
  the worktree root, per the §0 prohibition).
- [ ] **Step 7.2.** Stage the three modified files via
  `git add bin/dispatch.sh bin/dispatch-test.sh CLAUDE.md`. The
  plan doc was staged at planning-stage exit by the orchestrator's
  commit (`chore(pipeline): plan for ENG-94`).
- [ ] **Step 7.3.** Commit with message
  `feat(ENG-94): dispatch.sh::allowed_tools_for consumes project-profile Tool allowlist (drop hardcoded Tauri base)`.
  The pre-commit hook re-runs the full suite. If the commit fails
  hook-side, fix the underlying issue per CLAUDE.md's "Git Safety
  Protocol" (do NOT amend; create a NEW commit after fix).
- [ ] **Step 7.4 — Implement agent stage summary.** Write the
  implement-stage summary file to
  `$PROJECT_STATE_DIR/ENG-94/stage-summary-implementing.md` per the
  §0 overwrite-on-every-dispatch contract.

## Frontend Tasks

No UI surface; the harness has no frontend (per the project profile
addendum: "The repo contains no application code"). **No frontend
tasks.**

## Failure Mode → Test Map

Pulled from brainstorm §7 (Error handling) and §8 (Edge cases). Each
row binds to a concrete test layer + test name. The five new fixture
groups in `bin/dispatch-test.sh` are the durable regression guards;
operational paths (post-T1 deploy) are documented but not synthetically
tested.

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
|---|---|---|---|---|
| Hardcoded Tauri tokens re-introduced in `implementing`/`ui`/`qa` case arms (regression) | Future edit re-adds `Bash(cargo:*)` etc. to `bin/dispatch.sh:324/325/327` | Fixture 1's "base (no profile) does NOT contain Bash(cargo:*)" assert fails | unit | `bin/dispatch-test.sh` ENG-94 Fixture 1 AC#1 assert |
| Profile-derived tokens missing from composed output on Tauri target | Helper's awk parser bug; helper returns empty; case-arm cleanup orphans Tauri tokens | Fixture 1's per-stage cargo/bun/rustc/npx/node carries-via-profile asserts fail | unit | `bin/dispatch-test.sh` ENG-94 Fixture 1 token-presence asserts |
| Python profile's pytest token missing from composed output | Parser fails on non-Tauri stack patterns (regex too narrow) | Fixture 2's `pytest` carries assertion fails | unit | `bin/dispatch-test.sh` ENG-94 Fixture 2 |
| Go profile's `go test` token (pattern with space + colon) missing or mangled | awk parser fails on patterns containing a space; or D-8 hygiene incorrectly rejects `go test` | Fixture 3's `Bash(go test:*)` carries assertion fails | unit | `bin/dispatch-test.sh` ENG-94 Fixture 3 |
| Missing profile causes dispatch to die (regression — D-3 violated) | Helper introduces a `die` on parse failure | Fixture 4's `allowed_tools_for returns 0` assert fails (non-zero exit propagates) | unit | `bin/dispatch-test.sh` ENG-94 Fixture 4 rc check |
| Schema-version warning fires more than once per call OR fails to fire on schema v1 | Helper warns on every awk line OR silently swallows the warn | Fixture 4's `exactly one schema-version warning fired` assert fails | unit | `bin/dispatch-test.sh` ENG-94 Fixture 4 warning-count check |
| Schema v2 profile with `(none)` sub-bullets unexpectedly fires a warning | Helper's empty-stage discrimination is broken | Fixture 5's `no [allowed-tools] warning fired` assert fails | unit | `bin/dispatch-test.sh` ENG-94 Fixture 5 no-warn check |
| `_dispatch_tools_extras` (config-extras path) broken by the composition refactor | Composition tail mis-routes extras; or extras disappear when profile is empty | Pre-existing ENG-53 #8 block at lines 2122–2168 fails (the harness-self enumerated test list no longer reaches dispatch) | unit | `bin/dispatch-test.sh` ENG-53 #8 block (existing — AC#5) |
| Composition emits stray commas when one or two segments are empty | Empty-segment elision logic broken | Fixture 1's AC#1 assert (composed output's shape) and Fixtures 4/5 (which check for cargo absence and no-trailing-comma side-effects implicitly via grep) catch this | unit | `bin/dispatch-test.sh` ENG-94 Fixtures 1, 4, 5 (composite check) |
| Profile contains a Bash pattern with shell metacharacters (`Bash(echo X; rm -rf /:*)`) — security regression | Malicious or careless profile commit | D-8 awk hygiene rejects the pattern; the pattern is dropped from emitted output (no test asserts this directly in this plan — future work) | n/a | brainstorm §8 documents; no synthetic test (a malicious profile commit is a `learned-rules/` PR review surface, not a dispatch-time surface) |
| Pattern with internal commas (`Bash(go test,go vet:*)`) splits into two tokens | Discovery agent emits comma-inside-parens; claude's `--allowed-tools` splitter sees two tokens | Documented as brainstorm OQ-1; same hazard as today's case-arm tokens; no defense in ENG-94 | n/a | brainstorm §8 / OQ-1 (deferred) |
| Tauri host that has not re-run discovery (still on schema_version 1) loses cargo/bun on first ENG-94 tick | Operator runs ENG-94 code before T1 migration | Helper fires schema-version warning + returns empty; composition collapses to `base + extras` without Tauri tokens; implement agent halts on first `cargo` invocation with permission denial; operator's recovery is `bash bin/setup.sh project-profile` per OQ-6 | smoke | covered by Fixture 4 at the unit level; behavioral test is empirical on the first post-deploy Tauri tick |
| `CLAUDE.md` "Per-target dispatch.tools extras" section now reads "stack-neutral base" but the wildcard pitfall / regen one-liner blocks are also accidentally dropped | Task 5's overlapping edits drop content | Step 5.3 / 5.4 sanity-checks fail (`grep -nF 'Wildcard pitfall.' CLAUDE.md` returns zero hits, or `grep -nF 'TESTS=$(ls bin/*-test.sh' CLAUDE.md` returns zero) | smoke | Step 5.3 + Step 5.4 grep checks within Task 5 |
| `bin/dispatch.sh` syntactic regression from the helper insert or case-arm edits | A stray quote / unterminated string in the helper body | `bash -n bin/dispatch.sh` exits non-zero | smoke | Task 6.1 syntactic check; also Task 1.3, Task 2.5, Task 3.2 inline checks |
| `partition_dirty_paths` rejects the plan doc as out-of-scope | Plan doc filename does not contain the issue identifier | Plan doc rejected; partition fires self-leak; breaker trips | unit | covered by `partition_dirty_paths::D-004` (basename-token check); plan doc filename `2026-05-13-eng-94-...` carries `eng-94` per A-019 — bucketed in-scope |

## Test Strategy

### Unit / fixture tests (D-6)

The five new `bin/dispatch-test.sh` fixture groups (Task 4) are the
primary regression guard. Together they pin:

1. **Fixture 1 (Tauri back-compat):** AC#2 (composition correctness)
   + AC#1 (case-arm cleanup). Two-sided assertion: profile-fed
   tokens reach composed output; base (no profile) does NOT carry
   them.
2. **Fixture 2 (Python):** AC#4 (Python coverage). Asserts pytest
   reaches `implementing`/`qa`; cargo does not.
3. **Fixture 3 (Go):** AC#4 (Go coverage). Asserts `Bash(go test:*)`
   reaches `implementing`/`qa`; cargo does not. The `go test`
   pattern's internal space exercises the awk regex's tolerance
   of multi-word command names.
4. **Fixture 4 (Fallback):** AC#3 (schema-v1 warn branch).
   Three-sided assertion: composed output is empty of stack tokens,
   exactly one warning fires, helper returns 0 (does NOT die).
5. **Fixture 5 (Empty-section):** AC#3 (schema-v2 no-warn branch).
   Two-sided assertion: composed output is empty of stack tokens,
   ZERO warnings fire (the no-warn discrimination per D-3 fourth
   bullet).

The pre-existing ENG-53 #8 block (lines 2122–2168) is preserved
verbatim (AC#5) — extras-path correctness is unchanged.

### Smoke (syntactic) tests

- `bash -n bin/dispatch.sh` (Task 1.3 / 2.5 / 3.2 inline; Task 6.1
  end-to-end) confirms the file remains valid bash after the helper
  insert + case-arm cleanups + composition rewrite.
- `bash -n bin/dispatch-test.sh` (Task 4.8 inline; Task 6.1 end-to-end)
  confirms the fixture block insert is syntactically valid.
- `bash bin/render-prompt-test.sh` is unaffected (the profile-prompt-
  append path in `render-prompt.sh:144–166` is untouched per A-015);
  no new assertion required here.

### Sibling tests (existing, untouched)

- `bin/dispatch-test.sh:2122–2168` (existing ENG-53 #8 wildcard
  guard) — unaffected. Task 4's fixtures insert AFTER this block;
  the extras-path composition continues to work because the
  `_dispatch_tools_extras` helper is preserved verbatim (per A-005).
- `bin/dispatch-test.sh:2090–2120` (existing ENG-49 Gap-7 contract
  check) — unaffected. The prompt-vs-allowlist contract is checked
  per-stage by name; the per-stage allowlist contents have new
  Bash patterns flowing in via profile, but the contract is a
  "every gh-pr verb in the prompt section is allowlisted"
  one-way pin; the new patterns ADD to the allowlist and never
  subtract a previously-checked verb.
- `bin/render-prompt-test.sh` — unaffected. The profile-prompt-
  append path is untouched.
- `bin/setup-helpers-test.sh` — unaffected. The schema validator
  (`_validate_project_profile_schema`) is untouched; T1 owns it.

### Pre-commit / regression gate

- `bash .githooks/pre-commit` (Task 6.4) runs the full
  `bin/*-test.sh` suite end-to-end, including the five new ENG-94
  fixture groups. ~30 s walltime. This is the canonical gate.
- `bash bin/secret-probe-lint.sh` (Task 6.5) confirms no
  secret-shaped env var is referenced (none expected; the helper
  uses `HARNESS_ROOT`, `PROJECT_SLUG`, neither of which matches
  the `*KEY|*TOKEN|*SECRET|ANTHROPIC*|GITHUB*|LINEAR*` regex).

### Adversarial / E2E coverage (deferred)

- **Profile commit with shell-metachar Bash pattern.** D-8 hygiene
  rejects metachars; the brainstorm §"Security persona" P1 records
  this as defense-in-depth. No synthetic test in this plan — adding
  a fixture that confirms `Bash(echo X; rm -rf /:*)` is dropped
  would require a profile with a malicious pattern, which (a) the
  `secret-probe-lint` regex might flag, (b) the test file's
  source-and-stub setup may not isolate cleanly. Tracked as future
  hardening — likely a separate fixture if a real metachar regression
  ever lands.
- **Tauri host first-tick behavior post-deploy.** Brainstorm OQ-6.
  Empirical on first Tauri tick; documented in this plan's Goal §5
  and the CLAUDE.md rewrite.
- **Multi-line / multi-fixture HARNESS_ROOT cross-contamination.**
  Each fixture explicitly resets its overrides after running (Step
  4.7); sequential fixtures cannot bleed into each other.

### Test gate (committed to in §"Goal")

```
bash bin/dispatch-test.sh \
  && bash bin/secret-probe-lint.sh \
  && bash .githooks/pre-commit
```

The pre-commit hook (`bash .githooks/pre-commit`) is a strict
superset of the first two commands and is the canonical
run-it-all gate.

## Self-review summary (5 personas)

Five personas dispatched against this plan in parallel: feasibility,
scope, coherence, design, product.

### Iteration 1

| Persona | Verdict | P0 | P1 |
|---|---|---|---|
| feasibility | PASS | 0 | 1 |
| scope | PASS | 0 | 0 |
| coherence | PASS | 0 | 0 |
| design | PASS | 0 | 1 |
| product | PASS | 0 | 1 |

**Status:** Personas: 5/5 PASS · gate P0: 0 · proceeding to implementing.

Gate criterion (≥4/5 PASS, zero P0) cleared at iteration 1. P1
advisories below are recorded for transparency; none rise to a
blocking concern.

Persona findings:

- **feasibility (PASS, 0 P0, 1 P1).** All 22 assumption-inventory
  entries (A-001 through A-022) `path:line`-cited against the current
  worktree. Modified-file targets verified: `bin/dispatch.sh:291–340`
  for `_dispatch_tools_extras` / `allowed_tools_for` shape;
  `bin/dispatch-test.sh:2090–2172` for the insert boundary;
  `CLAUDE.md:265–318` for the rewrite block. `depends_on` graph
  correct: Task 0 (baseline) → Task 1 (helper) → Tasks 2 + 3 (same
  file, dependent on helper) + Tasks 4 + 5 (different files, can
  parallelise after Task 1 / Task 0) → Task 6 (verification) →
  Task 7 (commit + summary). Every Failure Mode row names a concrete
  test layer + test name (the five new fixtures + the existing
  ENG-53 #8 block).
  - **P1 (recorded):** A-013 marks the awk grammar as `assumed/T1-
    dependent` — the parser is designed to the addendum-shape spec
    in this prompt's project-profile addendum (the schema-v2 form),
    which is NOT on disk in any `learned-rules/<slug>/project-
    profile.md` today. If T1 lands a different micro-format (e.g.,
    `*` instead of `-` for bullets, or no backtick-fenced patterns),
    the awk regex in Task 1 Step 1.1 needs alignment. The
    implementer should re-verify against the on-disk profile at
    implementation time and adjust if drift is detected — the
    helper's structure (warn-and-fallback, co-location with
    `_dispatch_tools_extras`) is robust to grammar tweaks.

- **scope (PASS, 0 P0, 0 P1).** Every File Structure entry traces
  back to brainstorm decisions D-1 through D-8 cleanly. The
  `touches` lists on each task match the File Structure declarations
  (no out-of-scope file appears). No gold-plating:
  - No new bash file (the helper sits inside `bin/dispatch.sh`, not
    a new `bin/profile-tools.sh` — per brainstorm §4 D-1's rejected
    alternative).
  - No `bin/render-prompt.sh` modification (per A-015 / brainstorm
    §3 "Architectural seam" — second-reader pattern, no shared
    parser today).
  - No `bin/setup-helpers.sh` modification (T1 owns the validator).
  - No `learned-rules/` modification (T1 owns the schema bump;
    retrospective owns rule files).
  - No `AGENT_PROMPTS.md` modification (T5).
  - No `bin/scope-check.sh` / `bin/run-local-helpers.sh` modification (T3 / T4).
  - No new metric event / exit code / lane fence / vocabulary entry.

- **coherence (PASS, 0 P0, 0 P1).** Plan Goal §1–§6 mirrors brainstorm
  decisions D-1 (helper + parser + hygiene) / D-2 (composition order)
  / D-3 (fail-soft) / D-4 (apply universally) / D-5 (awk grammar) /
  D-6 (five fixtures) / D-7 (CLAUDE.md rewrite) / D-8 (shell-metachar
  hygiene). Backend Tasks 1 / 2 / 3 / 4 / 5 each realize a discrete
  brainstorm decision (or pair: Task 1 covers D-1 / D-5 / D-8 because
  the parser hygiene lives inside the helper body); Task 0 is the
  defensive baseline; Task 6 runs the test gate; Task 7 commits and
  writes the stage summary. Failure Mode → Test Map covers every
  brainstorm §7 error-handling row + §8 edge-case row that has a
  concrete test surface (rows without a synthetic test — OQ-1
  internal-comma, security persona's profile-commit-trust-model — are
  marked `n/a` with brainstorm cross-references). The `_dispatch_tools_from_profile`
  function name + signature are used consistently across Goal §1,
  Tasks 1–3, and the §"Tech stack" / §"File Structure" descriptions
  — no drift.

- **design (PASS, 0 P0, 1 P1).** No new abstractions, no new
  dependencies, no new exit codes. The helper follows the existing
  `_dispatch_tools_*` underscore-private idiom and parameter-by-
  position contract (`$1`). The case-arm cleanups are minimal-impact
  (token-removal only; surrounding tokens preserved). The composition
  rewrite is a tight 9-line block that elides empty segments with
  the same `[[ -n "$x" ]] && result="..."` shape used throughout the
  harness (cf. `bin/run-stage.sh::_fresh_wait_reason`).
  - **P1 (recorded):** The helper adds a SECOND profile-reader in
    `bin/dispatch.sh` (the FIRST being `render-prompt.sh:149`'s
    profile-prompt-append). Brainstorm §3 commits to extracting a
    shared `bin/profile-parse.sh` if a fourth reader emerges; that
    threshold is not crossed by ENG-94 alone. The implementer should
    NOT extract a shared helper today; the cost is a 25-line in-
    place parser duplicated once. Recorded so a future maintainer
    knows the seam exists and the extraction policy is documented.

- **product (PASS, 0 P0, 1 P1).** The plan delivers what the Linear
  issue asked for: a non-Tauri target's discovery-derived stack
  tools (pytest, go test, etc.) reach the implement agent's allowlist
  without an operator hand-editing `.pipeline-config/config.json`.
  The composition order + fail-soft contract preserve operator
  agency (extras still win position; profile is auto-applied).
  - **P1 (recorded):** First-tick behavior on a Tauri host that has
    NOT re-run `bash bin/setup.sh project-profile` is a regression
    vector — the host loses cargo/bun until the operator re-runs
    discovery (brainstorm OQ-6). This plan's CLAUDE.md rewrite
    (Task 5.2) DOES name the rollout-coordination requirement;
    the runbook entry (the canonical operator-mental-model surface)
    is brainstorm-deferred and would close this P1 fully. Tracked
    for a follow-up ticket.

All code-level assumptions verified against the current worktree at
the time of plan-writing. Two assumptions (A-013, A-021) are
explicitly marked `assumed/T1-dependent`; the implementer should
re-verify the awk grammar against T1's final profile shape at
implementation time if T1 has landed since this plan was written.
