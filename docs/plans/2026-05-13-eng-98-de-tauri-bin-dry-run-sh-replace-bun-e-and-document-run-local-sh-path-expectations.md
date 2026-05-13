---
linear: ENG-98
date: 2026-05-13
topic: Replace bin/dry-run.sh's `bun -e` YAML.parse with a pure-bash structural check (grep+awk on already-required harness runtime tools), expand bin/run-local.sh's PATH-augmentation comment to attribute each segment, document the PATH expectations in CLAUDE.md + docs/install.md, and pin AC1/AC3 with a new bin/dry-run-test.sh content-invariant test.
---

# Plan — ENG-98 de-Tauri `bin/dry-run.sh` + document `bin/run-local.sh` PATH expectations

Implementation plan for the brainstorm at
`docs/brainstorms/2026-05-13-eng-98-de-tauri-bin-dry-run-sh-replace-bun-e-and-document-run-local-sh-path-expectations-design.md`.

## Goal

After implement lands on the feature branch:

1. **D-1 in tree.** `bin/dry-run.sh:55-63`'s `check "YAML syntax: …" bash -c
   '… bun -e …'` block is replaced by a `check "GH Actions workflow structure:
   .github/workflows/*.yml" bash -c '…'` block whose body uses only `grep`,
   `awk`, and bash builtins (all enumerated as required harness runtime tools
   per `learned-rules/harness/project-profile.md:12`). The new body asserts
   three per-file invariants: non-empty, presence of top-level `^on[[:space:]]*:`
   AND `^jobs[[:space:]]*:`, no tab-indented lines.
2. **D-2 in tree.** `bin/run-local.sh:19-21`'s 3-line PATH comment is expanded
   to a ~9-line comment attributing each PATH segment to its consumer
   (Homebrew Apple Silicon / Intel, stack-specific user-global bins); the
   PATH assignment at line 22 is **unchanged**. CLAUDE.md gains a new
   sub-section under "Three locations every script touches" titled **"PATH
   expectations on the launchd host"**, and `docs/install.md` gains a
   corresponding **"### PATH expectations"** sub-section under "What you
   need before starting".
3. **D-3 in tree.** A new `bin/dry-run-test.sh` (executable, sentinel-shaped
   per `CLAUDE.md::Tests` §107-127) asserts (a) `bin/dry-run.sh` does NOT
   contain the literal token `bun -e`, and (b) `bin/dry-run.sh` DOES contain
   the literal token `GH Actions workflow structure`. Picked up automatically
   by `.githooks/pre-commit:154`'s `for t in bin/*-test.sh` glob — no hook
   edit required.

Verifiable outcome: on a host with no Bun installed (or with
`$HOME/.bun/bin` removed from PATH), `bash bin/dry-run.sh` prints
`✅ GH Actions workflow structure: …` in the offline-checks section and
exits 0 (AC1, AC3); `bash bin/dry-run-test.sh` prints two PASS lines and
exits 0 (AC4); `bash .githooks/pre-commit` reports a delta of +1 PASS for
the new test (AC4); `grep -rn 'PATH expectations' CLAUDE.md docs/install.md`
returns at least one hit per file (AC2).

## Anti-anchoring check

- **Problem (operator's words).** Two minor Tauri/Bun residues survive in
  orchestrator scripts: `bin/dry-run.sh:58` hard-requires `bun` for an
  inline YAML parse, and `bin/run-local.sh:22` injects `$HOME/.bun/bin` and
  `$HOME/.npm-global/bin` into PATH without documenting why. Operator wants
  the Bun dependency gone from harness self-test (AC1, AC3) and the PATH
  augmentation either profile-derived OR documented (AC2).
- **Brainstorm addresses it?** Yes — D-1 swaps `bun -e` for a `grep`+`awk`
  structural check using only already-required runtime tools; D-2 documents
  the PATH augmentation (explicitly NOT profile-deriving — schema-bump
  blast radius out of proportion to a 1-line PATH augmentation, deferred to
  brainstorm §10 #1); D-3 pins both invariants with a new content test;
  D-4 records the no-schema-change deferral as a numbered decision for
  traceability.
- **Proportional?** Yes. Three substantive file touches (one bash arm
  rewrite, one comment expansion, one new test ~30 lines) plus two doc
  additions (CLAUDE.md sub-section, docs/install.md sub-section). No new
  files except the test. No new env vars, no new config keys, no new exit
  codes, no schema migration, no changes to `dispatch.sh::allowed_tools_for`,
  `render-prompt.sh::STAGE_TO_SECTION`, `run-local-helpers.sh::partition_dirty_paths`,
  or `pipeline-events.json`.
- **No reframe; no scope creep; no escalation. PROCEED with implementation.**

## Assumption Inventory

Every code-level claim is verified against the worktree at plan time
(branch
`feat/eng-98-de-tauri-bin-dry-run-sh-replace-bun-e-and-document-run-local-sh-path-expectations`,
HEAD `583ec8a`). The branch-base freshness sweep was performed:
`git log --oneline origin/main..HEAD` returns exactly one commit
(`583ec8a chore(pipeline): brainstorming for ENG-98`) and
`git log --oneline HEAD..origin/main` returns empty. **branch-base
freshness: HEAD..origin/main empty at plan time (origin/main = `afbc59b`).**
No `### Task 0: Rebase` row is required.

- **A-001 — `bin/dry-run.sh:55-63` is wrapped in `check "YAML syntax:
  .github/workflows/*.yml" bash -c '...'`, with the inner body calling
  `bun -e "import fs … YAML.parse(…)"` and a trailing `|| exit 1`.**
  - `bin/dry-run.sh:55` — `check "YAML syntax: .github/workflows/*.yml" bash -c '`
  - `bin/dry-run.sh:56` — `  shopt -s nullglob`
  - `bin/dry-run.sh:57` — `  for f in .github/workflows/*.yml; do`
  - `bin/dry-run.sh:58` — `    bun -e "`
  - `bin/dry-run.sh:59-60` — `      import fs from \"fs\"; import YAML from \"yaml\"; / YAML.parse(fs.readFileSync(\"$f\",\"utf8\"));`
  - `bin/dry-run.sh:61` — `    " >/dev/null 2>&1 || exit 1`
  - `bin/dry-run.sh:62-63` — `  done / '`
  - **Status:** verified by direct read. The replacement (Task 1) anchors on
    the literal `check "YAML syntax:` opening line and the closing single
    quote at line 63 (content anchors, not bare line numbers).

- **A-002 — `bin/run-local.sh:19-21` is a 3-line `#`-prefixed comment block;
  `bin/run-local.sh:22` exports the PATH augmentation literally as
  `/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:$HOME/.bun/bin:$HOME/.npm-global/bin:$PATH`.**
  - `bin/run-local.sh:19` — `# launchd hands us a minimal PATH. Prepend the places the tools actually live on`
  - `bin/run-local.sh:20` — `# macOS (Homebrew on Apple Silicon + Intel, npm/bun user-global bins). The plist`
  - `bin/run-local.sh:21` — `# also sets PATH; this is belt-and-braces so the script works if invoked manually.`
  - `bin/run-local.sh:22` — `export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:$HOME/.bun/bin:$HOME/.npm-global/bin:$PATH"`
  - **Status:** verified by direct read. Task 2 replaces lines 19-21 only;
    line 22 (the actual PATH export) is untouched per D-2.

- **A-003 — `bin/dry-run.sh` declares `check()` locally (lines 19-30) and
  uses it for every offline assertion; the replacement YAML check fits this
  pattern by calling `check "<label>" bash -c '<body>'`.**
  - `bin/dry-run.sh:19-30` — `check() { local label="$1"; shift; if "$@" >/tmp/dry-run.out 2>&1; then … }`
  - **Status:** verified by direct read. Task 1's replacement preserves the
    `check "<label>" bash -c '…'` invocation shape verbatim.

- **A-004 — `.github/workflows/` contains exactly one file:
  `secret-probe-lint.yml`, 12 lines, with top-level `on:` at line 2 and
  `jobs:` at line 6.**
  - `.github/workflows/secret-probe-lint.yml:2` — `on:`
  - `.github/workflows/secret-probe-lint.yml:6` — `jobs:`
  - **Status:** verified by direct read AND by `Grep '^(on|jobs)[[:space:]]*:'`
    returning matches at lines 2 and 6. The proposed structural regex
    `^on[[:space:]]*:` / `^jobs[[:space:]]*:` matches this file's content
    exactly.

- **A-005 — `learned-rules/harness/project-profile.md::Stack` (line 12)
  enumerates `jq`, `awk`, `sed`, `gtimeout`, `git`, `gh`, `claude`, `curl`
  as required harness runtime tools, with NO `bun` entry.**
  - `learned-rules/harness/project-profile.md:12` — Stack paragraph quotes the
    full tool list.
  - **Status:** verified by direct read. Task 1's grep+awk-based replacement
    consumes only `grep` (universally available via POSIX) and `awk`
    (explicitly enumerated). No profile edit required.

- **A-006 — `.githooks/pre-commit:154` runs the full `bin/*-test.sh` suite
  via `for t in bin/*-test.sh; do … done`. A new `bin/dry-run-test.sh` is
  picked up automatically with NO hook edit.**
  - `.githooks/pre-commit:154` — `for t in bin/*-test.sh; do`
  - `.githooks/pre-commit:155-177` — body invokes each test, classifies
    pass/fail/skip.
  - **Status:** verified by direct read. Task 4's new test file requires no
    `.githooks/pre-commit` edit.

- **A-007 — `bin/agent-prompts-content-test.sh:1-30` is the canonical
  content-invariant test precedent: sources nothing external, derives
  `HARNESS_ROOT` from `SCRIPT_DIR/..`, defines `ok` / `nope` (PASS/FAIL
  counters), greps the target file, exits non-zero on failure.**
  - `bin/agent-prompts-content-test.sh:1-14` — sentinel pattern + counters.
  - **Status:** verified by direct read. Task 4's new test mirrors this
    pattern verbatim (header → PASS/FAIL counters → grep assertions).

- **A-008 — `CLAUDE.md::Three locations every script touches` lives at lines
  15-35; the next H2 is `## Runtime topology` at line 37. The new "PATH
  expectations on the launchd host" sub-section (Task 5) inserts BEFORE
  the `## Runtime topology` H2 (content anchor: the literal line
  `## Runtime topology`).**
  - `CLAUDE.md:15` — `## Three locations every script touches`
  - `CLAUDE.md:37` — `## Runtime topology`
  - **Status:** verified by direct read AND `Grep -n` returning both
    headers. The insertion boundary is the `## Runtime topology` line
    (content anchor, durable across rebases).

- **A-009 — `launchd/com.twinning.pipeline.plist.template:39` defines
  `EnvironmentVariables/PATH` as
  `/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin`
  — system minimal plus Homebrew dirs, NO `$HOME` segments.**
  - `launchd/com.twinning.pipeline.plist.template:39` — PATH value above.
  - **Status:** verified by direct read. CLAUDE.md and docs/install.md
    sub-sections (Tasks 5+6) reference this plist's PATH composition.

- **A-010 — `docs/install.md::What you need before starting` lives at
  lines 18-31; the next H2 is `## Phase 1: workspace` at line 33. The new
  "### PATH expectations" sub-section (Task 6) inserts BEFORE the
  `## Phase 1: workspace` H2 (content anchor).**
  - `docs/install.md:18` — `## What you need before starting`
  - `docs/install.md:33` — `## Phase 1: workspace`
  - **Status:** verified by direct read. Insertion boundary is the
    `## Phase 1: workspace` line.

- **A-011 — No existing file in `bin/` is named `dry-run-test.sh`. No
  collision risk for Task 4.**
  - `bin/dry-run*.sh` glob returns only `bin/dry-run.sh`.
  - **Status:** verified by shell `ls`.

- **A-012 — `bin/secret-probe-lint-test.sh` has three cases (10, 11, 12)
  that reference `bin/dry-run.sh` by path — none of them assert against the
  literal tokens `bun -e` or `YAML syntax`; they assert against (case 10)
  the `secret-probe-lint.sh` invocation wiring, (case 11) canonical gerund
  stage names, and (case 12) the `pipeline:paused` precondition probe skip.
  All three assertions survive Task 1 unchanged.**
  - `bin/secret-probe-lint-test.sh:259-275` — case 10 (`secret-probe-lint.sh`
    wiring).
  - `bin/secret-probe-lint-test.sh:277-300` — case 11 (canonical stage names).
  - `bin/secret-probe-lint-test.sh:302-320` — case 12 (`pipeline:paused`
    precondition skip).
  - **Status:** verified by direct read and Grep. Test-gate closure sweep
    PASSES: no sibling test pins `bun -e` or `YAML syntax` as a literal
    assertion target.

- **A-013 — No sibling test file in `bin/` other than the new
  `bin/dry-run-test.sh` (Task 4) asserts against the literal tokens
  `bun -e`, `YAML syntax`, or `GH Actions workflow structure`. Grep of
  `bin/*-test.sh` for these tokens returns zero hits.**
  - `Grep 'bun -e' bin/*-test.sh` → 0 hits.
  - `Grep 'YAML syntax' bin/*-test.sh` → 0 hits.
  - `Grep 'GH Actions workflow structure' bin/*-test.sh` → 0 hits.
  - **Status:** verified via Grep. Test-gate closure sweep confirms no
    existing test asserts against tokens this plan changes.

- **A-014 — `bin/run-local-sweep-test.sh:3` mentions `dry-run.sh` in a
  comment only (`# Wired into dry-run.sh.`) — no assertion against
  `dry-run.sh` content. `bin/common-test.sh:212` mentions `dry-run.sh` in
  a comment only. `bin/setup-test.sh:3` mentions `dry-run.sh` in a comment
  only. None of these break under Task 1's edit.**
  - All three confirmed via Grep.
  - **Status:** verified.

- **A-015 — `bin/reconcile.sh` accepts `linear: ENG-98` YAML frontmatter as
  canonical-doc claim, per `CLAUDE.md::Linear conventions the harness
  depends on` ("greps the first 20 lines … for a literal `linear: ENG-N`
  line"). The plan doc filename and frontmatter satisfy this.**
  - `CLAUDE.md::Linear conventions` documents the contract.
  - **Status:** verified via CLAUDE.md.

- **A-016 — `bin/run-local-helpers.sh::partition_dirty_paths::D-004` requires
  the basename of a brainstorm/plan path to contain a case-insensitive
  `eng-N` token; the plan doc's basename
  `2026-05-13-eng-98-de-tauri-bin-dry-run-sh-replace-bun-e-and-document-run-local-sh-path-expectations.md`
  contains literal `eng-98`.**
  - Filename match (eyeballed against §2 directive of the dispatcher prompt).
  - **Status:** verified.

- **A-017 — macOS BSD awk supports `\t` inside regex; `\t` matches a tab
  character. The harness is macOS-only per
  `learned-rules/harness/project-profile.md:12` ("macOS-compatible").**
  - **Status:** assumed; verified at implement-time by Task 7's smoke step
    (manual `bash bin/dry-run.sh` on the operator's host).

- **A-018 — `bin/dry-run.sh::check` swallows the inner command's stdout/
  stderr into `/tmp/dry-run.out` and re-prints it on failure (lines 22-29).
  The new structural check's `echo` diagnostics (`"empty file: $f"`, etc.)
  surface via this path; operator gets a clear error message instead of
  the current Bun stderr-suppressed-by-`>/dev/null 2>&1` blackout
  (`bin/dry-run.sh:61`).**
  - `bin/dry-run.sh:22-29` — check function body.
  - **Status:** verified by direct read.

All 18 load-bearing facts verify in the current worktree.

## File Structure

- **MODIFIED** `bin/dry-run.sh` — replace the `check "YAML syntax: …"
  bash -c '…'` block at lines 55-63 with a `check "GH Actions workflow
  structure: .github/workflows/*.yml" bash -c '…'` block using `grep`,
  `awk`, and bash builtins per D-1. Content anchors: the literal opening
  line `check "YAML syntax: .github/workflows/*.yml" bash -c '` (delete-
  start) and the closing single-quoted single-line `'` at line 63
  (delete-end). All other lines in `bin/dry-run.sh` are unchanged.
- **MODIFIED** `bin/run-local.sh` — replace the 3-line comment block at
  lines 19-21 with a ~9-line comment attributing each PATH segment per
  D-2. Content anchors: line 19's `# launchd hands us a minimal PATH.`
  (delete-start) and line 22's `export PATH="…"` (delete-end-exclusive;
  line 22 itself is unchanged). All other lines unchanged.
- **MODIFIED** `CLAUDE.md` — insert a new `## PATH expectations on the
  launchd host` H2 sub-section between the closing line of `## Three
  locations every script touches` (line 35, the paragraph ending `… `__VAR__`
  placeholders.`) and the H2 `## Runtime topology` at line 37. Content
  anchors: the literal line `## Runtime topology` (insert-before).
- **MODIFIED** `docs/install.md` — insert a new `### PATH expectations`
  H3 sub-section between the closing line of `## What you need before
  starting` (line 31, the bullet ending `… the `claude` CLI logged in to
  a subscription.`) and the H2 `## Phase 1: workspace` at line 33.
  Content anchor: the literal line `## Phase 1: workspace` (insert-before).
- **NEW** `bin/dry-run-test.sh` (~35 lines) — pins AC1/AC3 invariants per
  D-3. Sentinel-shaped (`if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main
  "$@"; fi`) for source-and-stub compatibility, but defines a simple
  `main()` that runs two literal-token asserts and exits non-zero on any
  failure. Mode `0755` (executable).

No new env vars. No new config keys. No `bin/pipeline-events.json` change.
No `bin/dispatch.sh::allowed_tools_for` change. No
`bin/run-local-helpers.sh::stage_output_paths` change. No
`learned-rules/harness/project-profile.md` change (Bun is not in the Stack
list; D-1 removes the Bun *consumer* without touching the *declared* tool
list). No `launchd/com.twinning.pipeline.plist.template` change (the
plist's PATH already excludes `$HOME` segments; D-2 documents this rather
than restructuring it).

## API Contract

no new API surface (this is a bash-orchestration repo with no FE↔BE API;
the only contract changes are internal text edits to bash scripts and
markdown docs).

## Backend Tasks

### Task 1: Replace `bun -e` YAML.parse with structural grep+awk check in `bin/dry-run.sh`

- `depends_on: []`
- `touches: bin/dry-run.sh::"YAML syntax: …" check block (renamed to "GH Actions workflow structure: …")`
- [ ] In `bin/dry-run.sh`, locate the block opening at the literal line
      `check "YAML syntax: .github/workflows/*.yml" bash -c '` (content
      anchor; informational line hint: ~line 55) and ending at the next
      column-0 closing single quote `'` standing alone on its own line
      (content anchor; informational line hint: ~line 63). This block is
      the inner argument to `check`; the entire 9-line span is replaced.
- [ ] Replace those 9 lines verbatim with:

      ```bash
      check "GH Actions workflow structure: .github/workflows/*.yml" bash -c '
        shopt -s nullglob
        for f in .github/workflows/*.yml; do
          [[ -s "$f" ]] || { echo "empty file: $f"; exit 1; }
          grep -qE "^on[[:space:]]*:" "$f" || { echo "missing top-level on: in $f"; exit 1; }
          grep -qE "^jobs[[:space:]]*:" "$f" || { echo "missing top-level jobs: in $f"; exit 1; }
          awk '\''/^\t/ { found=1 } END { exit found?1:0 }'\'' "$f" \
            || { echo "tab indentation (YAML forbids tabs): $f"; exit 1; }
        done
      '
      ```

      Per-line rationale (matches brainstorm D-1 §4):
      - `shopt -s nullglob` so an empty `.github/workflows/` directory makes
        the loop body unreachable (preserved behaviour from the existing
        block at `bin/dry-run.sh:56`).
      - `[[ -s "$f" ]]` rejects empty files (catches accidental
        `: > file.yml`); failure is a clear error message, surfaced by
        `check`'s `/tmp/dry-run.out` capture (A-018).
      - `grep -qE '^on[[:space:]]*:'` and `grep -qE '^jobs[[:space:]]*:'`
        assert presence of the two required top-level keys. Allows
        whitespace after `:` (e.g. `on: push`). Anchored at start-of-line
        so an `on:` inside a string value is not a false positive.
      - The awk script body is single-quoted via `'\''…'\''` to defend
        against a future edit introducing `$var` inside the awk expression
        (it would shell-expand before awk sees it under a double-quoted
        body); per security-persona P2 of the brainstorm. The body's
        logic: scan every line; if any starts with a tab (`/^\t/`), set
        `found=1`; END block exits 1 (truthy, awk semantics) when found,
        0 otherwise. The trailing `|| { echo … ; exit 1; }` fires when
        awk exits 1, i.e. when a tab WAS found.
- [ ] Verify the edit preserves the surrounding context by re-reading the
      function span around `check "GH Actions workflow structure": one
      blank line above, the existing `check "JSON syntax: config.json"`
      block immediately below (currently at `bin/dry-run.sh:65`).
- [ ] Run `bash -n bin/dry-run.sh` (syntax-only check; no execution
      required) to confirm the script still parses.

### Task 2: Expand `bin/run-local.sh:19-21` PATH-augmentation comment to attribute each segment

- `depends_on: []`
- `touches: bin/run-local.sh::lines 19-21 (3-line comment above PATH export)`
- [ ] In `bin/run-local.sh`, locate the 3-line comment block whose first
      line is the literal `# launchd hands us a minimal PATH. Prepend the
      places the tools actually live on` (content anchor; informational
      line hint: ~line 19) and whose closing line is the literal `# also
      sets PATH; this is belt-and-braces so the script works if invoked
      manually.` (content anchor; informational line hint: ~line 21).
      The immediately-following line is `export PATH="…"` (line 22,
      A-002) — this line is the delete-end-exclusive anchor and is **NOT
      touched**.
- [ ] Replace the 3-line block verbatim with the following 9-line
      comment (per brainstorm D-2 §4):

      ```bash
      # launchd hands us a minimal PATH. Prepend the places the harness's
      # own tools and the dispatched agent's stack tools live on macOS.
      # Belt-and-braces — the launchd plist's EnvironmentVariables/PATH
      # already covers /opt/homebrew/bin and /usr/local/bin; this line ALSO
      # covers /opt/homebrew/sbin, /usr/local/sbin, and stack-specific
      # user-global bins ($HOME/.bun/bin, $HOME/.npm-global/bin) that the
      # dispatched agent may need on Bun- or npm-using targets.
      # Harmless on Bun-less hosts: PATH segments to absent dirs are ignored.
      # See CLAUDE.md "PATH expectations on the launchd host" for the
      # operator-facing summary.
      ```

      Per brainstorm §9 design persona's P2 fold, the comment does NOT
      include a `launchd/com.twinning.pipeline.plist.template:38-39`
      line-number reference; source-code comments with `file:line` refs
      age poorly. CLAUDE.md (Task 5) carries the durable line-number
      context.
- [ ] Confirm `export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:$HOME/.bun/bin:$HOME/.npm-global/bin:$PATH"`
      at the line immediately following the new comment block is
      **unchanged** verbatim — this assertion satisfies D-2's "PATH
      assignment at line 22 stays unchanged".
- [ ] Run `bash -n bin/run-local.sh` to confirm the script still parses.

### Task 3: Add `## PATH expectations on the launchd host` peer-H2 section to CLAUDE.md

Note: the new section is a peer H2 of `## Three locations every script
touches`, NOT a nested H3 sub-section. The brainstorm's `D-2 §3` wording
("Add a new sub-section under CLAUDE.md") is loose; the canonical
placement is a peer H2 inserted between the closing paragraph of "Three
locations" and the opening of "Runtime topology". This keeps the
"PATH expectations" section discoverable as its own top-level concern.

- `depends_on: []`
- `touches: CLAUDE.md::between "Three locations every script touches" and "Runtime topology"`
- [ ] In `CLAUDE.md`, locate the H2 `## Runtime topology` (content anchor;
      informational line hint: ~line 37). The new section inserts
      IMMEDIATELY BEFORE this header.
- [ ] The preceding paragraph (the one ending with `…__VAR__ placeholders.`,
      informational line hint: ~line 35) is the delete-start-exclusive
      anchor — its line stays unchanged.
- [ ] Insert verbatim between those two anchors (preserve one blank line
      above and below the new H2). The INSERTION BEGINS at the next line
      below — paste through, and stop at the END_INSERT marker:

```
BEGIN_INSERT:
## PATH expectations on the launchd host

`launchd` hands the harness a minimal PATH via the plist's
`EnvironmentVariables/PATH` block. The template at
`launchd/com.twinning.pipeline.plist.template:36-39` injects
`/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin`
— system defaults plus Homebrew dirs (Apple Silicon and Intel), no
`$HOME` segments.

`bin/run-local.sh:22` belt-and-braces the plist's PATH with additional
segments for stack-specific user-global bins (`$HOME/.bun/bin`,
`$HOME/.npm-global/bin`) that the *dispatched agent* may need on Bun- or
npm-using targets. This is harmless on hosts where those directories are
absent — the shell ignores missing PATH segments.

| Segment | Consumer | Notes |
|---|---|---|
| `/opt/homebrew/bin`, `/opt/homebrew/sbin` | harness's own tools | Apple Silicon Homebrew. Plist injects `bin`; `run-local.sh:22` adds `sbin`. |
| `/usr/local/bin`, `/usr/local/sbin` | harness's own tools | Intel Homebrew (or `/usr/local`-style installs). Plist injects `bin`; `run-local.sh:22` adds `sbin`. |
| `$HOME/.bun/bin` | dispatched agent's stack tools | Bun user-global bin. Only consumed on Bun-using targets (e.g. twinning's `bun tauri build`). |
| `$HOME/.npm-global/bin` | dispatched agent's stack tools | npm user-global bin (`npm install -g …`). Only consumed on npm-using targets. |
| `/usr/bin`, `/bin`, `/usr/sbin`, `/sbin` | system | Plist's tail. |

Tools the **harness itself** uses (`gtimeout`, `gh`, `claude`, `jq`,
`awk`, `sed`, `git`, `curl`) are assumed to be reachable via the
Homebrew / system segments above. Operators on non-Homebrew installs
(MacPorts, Nix) must edit the rendered plist's
`EnvironmentVariables/PATH` after `bin/install-launchd.sh` runs and
re-`launchctl bootstrap`. Targets that need additional user-global bin
dirs (`~/.cargo/bin`, `~/go/bin`, etc.) currently require a manual plist
edit; a profile-derived PATH mechanism is a deferred followup.
END_INSERT
```

The `BEGIN_INSERT:` and `END_INSERT` lines are this plan's plain-text
delimiters and MUST NOT be pasted into CLAUDE.md. Paste only the lines
strictly between them (starting with `## PATH expectations on the
launchd host` and ending with the paragraph that closes `…deferred
followup.`).
- [ ] After inserting, re-read the surrounding CLAUDE.md context: the
      H2 `## Three locations every script touches` (line 15), its body
      through ~line 35, ONE blank line, the new H2 `## PATH expectations
      on the launchd host` and its body, ONE blank line, the next H2
      `## Runtime topology` (now ~line 37 + new-section length). The
      table should render as 5 rows (`/opt/homebrew/*`, `/usr/local/*`,
      `$HOME/.bun/bin`, `$HOME/.npm-global/bin`, `/usr/bin /bin /usr/sbin
      /sbin`) plus a header.

### Task 4: Add `### PATH expectations` sub-section to `docs/install.md`

- `depends_on: []`
- `touches: docs/install.md::"What you need before starting" section`
- [ ] In `docs/install.md`, locate the H2 `## Phase 1: workspace` (content
      anchor; informational line hint: ~line 33). The new sub-section
      inserts IMMEDIATELY BEFORE this header.
- [ ] The preceding bullet (the one ending `… the `claude` CLI logged in
      to a subscription.`, informational line hint: ~line 31) is the
      delete-start-exclusive anchor — it stays unchanged.
- [ ] Insert verbatim between those anchors (preserve one blank line
      above and below the new H3). The insertion BEGINS at the line
      below — paste through, and stop at the END_INSERT marker:

```
BEGIN_INSERT:
### PATH expectations

The launchd plist injects a minimal PATH (`/opt/homebrew/bin`,
`/usr/local/bin`, and system dirs — see
`launchd/com.twinning.pipeline.plist.template:36-39`).
`bin/run-local.sh:22` belt-and-braces additional segments for
stack-specific user-global bins (`$HOME/.bun/bin`,
`$HOME/.npm-global/bin`) that the *dispatched agent* may need on Bun-
or npm-using targets. Harmless on hosts that lack those dirs.

Operators on non-Homebrew installs (e.g. MacPorts, Nix) should edit
the rendered plist's `EnvironmentVariables/PATH` after
`bin/install-launchd.sh` runs and re-`launchctl bootstrap` to pick up
the change. Targets that need additional user-global bin dirs
(`~/.cargo/bin`, `~/go/bin`, etc.) currently require a manual plist
edit; a profile-derived PATH mechanism is a deferred followup.

See CLAUDE.md's "PATH expectations on the launchd host" section for
the full per-segment attribution.
END_INSERT
```

The `BEGIN_INSERT:` and `END_INSERT` lines are this plan's plain-text
delimiters and MUST NOT be pasted into `docs/install.md`. Paste only the
lines strictly between them (starting with `### PATH expectations` and
ending with the paragraph closing `…per-segment attribution.`).

Per brainstorm §9 product-persona P2 fold, this snippet does NOT cite
ENG-98 or any Linear ticket ID — operator-facing install docs that cite
ticket IDs age poorly.

### Task 5: Add `bin/dry-run-test.sh` content-invariant test

- `depends_on: [1]`
- `touches: bin/dry-run-test.sh (new file)`
- [ ] Create a new executable file at `bin/dry-run-test.sh` with mode
      `0755`. Body (modeled on
      `bin/agent-prompts-content-test.sh:1-30`, per A-007):

      ```bash
      #!/usr/bin/env bash
      # ENG-98: Invariants on bin/dry-run.sh content.
      #
      # Pins AC1/AC3: bin/dry-run.sh must not invoke `bun -e`, and the
      # replacement check must label itself as "GH Actions workflow
      # structure" so a future edit cannot silently revert D-1 (per the
      # ENG-98 brainstorm at docs/brainstorms/2026-05-13-eng-98-…-design.md).
      #
      # Picked up by .githooks/pre-commit's `for t in bin/*-test.sh` glob.
      set -euo pipefail
      SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
      HARNESS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
      DRY_RUN_PATH="$HARNESS_ROOT/bin/dry-run.sh"
      [[ -f "$DRY_RUN_PATH" ]] \
        || { printf 'FATAL: not found: %s\n' "$DRY_RUN_PATH" >&2; exit 1; }

      PASS=0; FAIL=0
      ok()   { printf 'OK: %s\n' "$1"; PASS=$((PASS+1)); }
      nope() { printf 'FAIL: %s\n  reason: %s\n' "$1" "$2" >&2; FAIL=$((FAIL+1)); }

      main() {
        # AC1 invariant: bun -e MUST NOT appear in dry-run.sh.
        if grep -qE 'bun[[:space:]]+-e' "$DRY_RUN_PATH"; then
          nope 'no-bun-e' \
            "bin/dry-run.sh contains 'bun -e' — D-1 (ENG-98) requires the \
      Bun-coupled YAML check to be replaced by a pure-bash structural check"
        else
          ok 'no-bun-e'
        fi

        # AC4 invariant: the replacement check's renamed label is present.
        if grep -qF 'GH Actions workflow structure' "$DRY_RUN_PATH"; then
          ok 'structural-check-present'
        else
          nope 'structural-check-present' \
            "bin/dry-run.sh missing literal 'GH Actions workflow structure' — \
      D-1 (ENG-98) replacement check label not present"
        fi

        printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
        (( FAIL == 0 ))
      }

      if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
      ```

      The grep patterns:
      - `'bun[[:space:]]+-e'` (ERE) matches `bun -e`, `bun  -e`, `bun\t-e`
        — defends against a future re-introduction that obfuscates with
        whitespace.
      - `-F 'GH Actions workflow structure'` is a fixed-string match
        (no regex metacharacters in the literal).
- [ ] Set the executable bit: `chmod +x bin/dry-run-test.sh`.
- [ ] Run the new test as a smoke verification (after Task 1 lands):
      `bash bin/dry-run-test.sh` should print `OK: no-bun-e`, `OK:
      structural-check-present`, then `2 passed, 0 failed`, and exit 0.
- [ ] Run `bash -n bin/dry-run-test.sh` to confirm syntax-validity.

### Task 6: Verify Task 1 edit by running `bash bin/dry-run.sh` end-to-end (smoke)

- `depends_on: [1]`
- `touches: (verification only; no file edits)`
- [ ] On the implement-stage host, run
      `PIPELINE_DRY_RUN=1 TARGET_REPO=<target> bash bin/dry-run.sh` and
      confirm the offline section prints
      `✅ GH Actions workflow structure: .github/workflows/*.yml` (the new
      label) and does NOT print
      `❌ YAML syntax: .github/workflows/*.yml` (the old failure mode).
- [ ] If Bun is installed on the host, temporarily prepend
      `PATH="$(echo "$PATH" | tr ':' '\n' | grep -v '\.bun/bin' | grep -v '\.npm-global' | paste -sd ':' -)"`
      to the command (or use `env -i PATH=… bash bin/dry-run.sh`) to
      simulate AC1's "Bun-less host" condition. Confirm the same PASS
      output (verifies the structural check uses ONLY `grep`+`awk`+bash
      builtins, per A-005).
- [ ] If the smoke check fails, halt with reason `smoke-failed` per the
      orchestrator's halt vocabulary (do NOT silently regress).

### Task 7: Verify the `.githooks/pre-commit` suite includes the new test

- `depends_on: [5]`
- `touches: (verification only; no file edits)`
- [ ] On the implement-stage host, run `bash .githooks/pre-commit` (the
      hook entry point — exits 0 on clean) and confirm the output lists
      `PASS bin/dry-run-test.sh` in the per-test summary block.
- [ ] Confirm the trailing summary line shows `N passed, 0 failed, M
      skipped` where N is one greater than pre-Task-1's count (i.e. the
      hook is picking up `bin/dry-run-test.sh` from the `bin/*-test.sh`
      glob per A-006).
- [ ] If the new test is NOT listed, re-check Task 5's filename matches
      the `bin/*-test.sh` glob and that the file's mode bits include
      `+x` (the hook invokes via `bash "$t"`, so the executable bit is
      strictly not required for the glob to include it, but standardising
      on `+x` matches the existing tests' convention).

## Frontend Tasks

The harness has no FE; the UI stage is a no-op for ENG-98. No frontend tasks.

## Failure Mode → Test Map

The brainstorm §7 ("Error handling") and §8 ("Edge cases") enumerate the
following failure modes; each binds to a concrete test layer below.

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
|---|---|---|---|---|
| `bun -e` re-introduced in `bin/dry-run.sh` (regression) | A future edit re-adds the literal `bun -e` | `bin/dry-run-test.sh` fails with `FAIL: no-bun-e`; `.githooks/pre-commit` blocks the commit | unit | `bin/dry-run-test.sh::no-bun-e` |
| "GH Actions workflow structure" label removed (regression) | A future edit reverts the rename | `bin/dry-run-test.sh` fails with `FAIL: structural-check-present`; pre-commit blocks | unit | `bin/dry-run-test.sh::structural-check-present` |
| Workflow file is empty | A future contributor accidentally truncates `.github/workflows/secret-probe-lint.yml` (`: > file.yml`) | `bin/dry-run.sh`'s GH Actions check fails with `empty file: …`; non-zero exit | smoke | `bash bin/dry-run.sh` (offline section); manually-triggered |
| Workflow file missing top-level `on:` key | Contributor renames `on:` → `triggers:` | Check fails with `missing top-level on: in <file>` | smoke | `bash bin/dry-run.sh` (offline section); manually-triggered |
| Workflow file missing top-level `jobs:` key | Truncated file with no jobs block | Check fails with `missing top-level jobs: in <file>` | smoke | `bash bin/dry-run.sh` (offline section); manually-triggered |
| Workflow file has tab indentation (YAML-forbidden) | Paste accident from a tab-indented source | Check fails with `tab indentation (YAML forbids tabs): <file>` | smoke | `bash bin/dry-run.sh` (offline section); manually-triggered |
| Host has no Bun installed (AC1, AC3) | Fresh harness clone on a non-Tauri-target operator's laptop | `bash bin/dry-run.sh` runs cleanly through the GH Actions check and continues | integration | Task 6's smoke step (manual on Bun-less host) |
| PATH lacks `$HOME/.bun/bin` (dispatched agent on Bun-using target) | Operator's launchd plist edited to drop Bun bin segments | `run-local.sh:22` re-adds the segment via belt-and-braces (D-2 status quo); dispatched agent on twinning succeeds | integration | (existing) `bash bin/dry-run.sh` + a real tick on twinning; verified at brainstorm composition time, no new test |
| Workflow YAML invalid in ways the structural check misses (unbalanced quote, bad scalar) | A future workflow file has subtle YAML error | GitHub Actions catches it on the next PR; `dry-run.sh` does not (hint-grade trade-off, accepted per D-1) | e2e | GitHub Actions on PR (existing) |
| CLAUDE.md / docs/install.md missing the "PATH expectations" section (AC2) | A future edit deletes the new sub-section | Manual review; no automated assertion (no markdown-content test exists today, and adding one for two doc paragraphs is disproportionate per brainstorm §11) | doc-review | (no automated test) |

The "doc-review" row is acknowledged: AC2 has no automated assertion.
This is consistent with brainstorm §11's stance that adding a markdown-
content test for two doc paragraphs is disproportionate. The plan
explicitly lists this as the unautomated row so QA's failure-mode-to-test
audit does not flag it as missing — the absence is deliberate per D-2.

## Test Strategy

**Unit (gated by pre-commit hook).** The new `bin/dry-run-test.sh` pins
two literal-token invariants on `bin/dry-run.sh`. Picked up automatically
by `.githooks/pre-commit:154`'s `for t in bin/*-test.sh` glob (A-006); no
hook edit required. Test-gate closure sweep verified: no sibling test
file pins the soon-to-be-removed `bun -e` or `YAML syntax` tokens as a
literal assertion (A-013); the three `bin/secret-probe-lint-test.sh`
cases that reference `bin/dry-run.sh` (cases 10, 11, 12 per A-012) pin
unrelated content (`secret-probe-lint.sh` wiring, canonical stage names,
`pipeline:paused` precondition skip) and pass unchanged under Task 1's
edit.

**Integration (manual smoke on operator host).** Task 6's smoke step
exercises `bash bin/dry-run.sh` end-to-end on the implement-stage host,
both with and without `$HOME/.bun/bin` on PATH. This is the AC1/AC3
verification; the new pure-bash structural check must pass on the
Bun-less variant. Task 7 verifies the pre-commit hook picks up the new
test.

**No new test layer.** No e2e test is added. The GitHub Actions YAML
parse on every PR is the authoritative validation for workflow file
content — this is the hint-grade trade-off D-1 takes on (brainstorm §4).
The structural check at `bin/dry-run.sh` is a hint, not a source of
truth; deeper validation lives in the CI pipeline that already runs on
every PR (`.github/workflows/secret-probe-lint.yml`).

**No regression coverage required for the PATH change.** D-2 changes
only the COMMENT block at `bin/run-local.sh:19-21`; the executable PATH
export at line 22 is identical pre- and post-plan. No runtime behaviour
changes, so no test pins the PATH segments. The CLAUDE.md and
docs/install.md additions are documentation; no automated test.

**Adversarial coverage intent (for the QA stage).** A QA adversarial
test should attempt to defeat Task 5's grep patterns: (a) introduce
`bun  -e` (two spaces) or `bun\t-e` (tab) into `bin/dry-run.sh` and
confirm the ERE `bun[[:space:]]+-e` catches it; (b) introduce the
fixed string `GH Actions workflow STRUCTURE` (capitalised) into the
file and confirm the `-F` literal match in
`bin/dry-run-test.sh::structural-check-present` correctly REJECTS it
(positive-case fixedness). Both are pure-string-match tests; no
real-world data needed.

## Persona review

This plan is subject to the 5-persona self-review under the
`compound-engineering:document-review` skill per the dispatcher prompt's
Completion checklist step 2. Personas: **feasibility** (codebase-fact
verification + dependency graph + test-gate closure sweep), **scope**
(brainstorm-traceability check on every File Structure entry + `touches`
audit), **coherence** (Goal ↔ brainstorm Overview + tasks ↔ Failure Mode
→ Test Map), **design** (crate/module boundaries; n/a here since this
is a bash repo, but the harness's stack-agnostic principle is the
analogue), **product** (does the plan deliver what ENG-98 asked for).
The clean-gate threshold is 4/5 PASS with zero P0 findings; the dispatch
prompt's Completion checklist step 3 enforces this.

## Persona verdicts (self-review pass, 2026-05-13 iteration 1)

| Persona | Verdict | P0 | P1 | P2 | Key findings |
|---|---|---|---|---|---|
| feasibility | PASS | 0 | 2 | 4 | Task 3 markdown trailing-fence artifact (folded — replaced with `BEGIN_INSERT`/`END_INSERT` delimiter convention); "sub-section vs peer-H2" terminology (folded — Task 3 retitled "peer-H2 section"). Branch-base freshness, test-gate closure, dependency graph, edit-boundary checks, A-001..A-018 all verified. |
| scope    | PASS | 0 | 0 | 3 | Every task and File Structure entry traces to D-1/D-2/D-3. Tasks 6+7 are verification-only with `touches: (verification only; no file edits)`. D-4 deferral honored. Linear IN/OUT scope respected: line 22 of run-local.sh is preserved verbatim by Task 2 step 3. |
| coherence| PASS | 0 | 2 | 2 | All `depends_on` references resolve. Goal ↔ brainstorm aligned. AC1/AC2/AC3/AC4 each have a named delivery task. Brainstorm has a stale `sanity` label reference (§6/§D-3); the plan resolves to the correct `structure` token throughout. |
| design   | PASS | 0 | 0 | 2 | Task 1 uses only `grep`+`awk`+bash builtins (all enumerated in `learned-rules/harness/project-profile.md:12`). No layering violation: only `bin/dry-run.sh`, `bin/run-local.sh`, `CLAUDE.md`, `docs/install.md`, and the new `bin/dry-run-test.sh`. awk single-quote escape `'\''…'\''` is canonical. Sentinel pattern in Task 5 is correct. |
| product  | PASS | 0 | 2 | 3 | Plan delivers what ENG-98 asked for in operator-recognisable language. AC1+AC3 unblock the Bun-less laptop scenario. AC2's "document" option is defensible per brainstorm's blast-radius rationale. The "bash + jq" preference is honored via the brainstorm's "use only already-required tools" interpretation. |

**Gate:** 5/5 PASS · gate P0: 0 · proceeding to implementing.

P1/P2 findings recurring across personas (Task 3 markdown delimiter
clarity, `sub-section` vs `peer-H2` terminology) are folded into the plan
in this revision. The brainstorm's residual stale `sanity` label
reference (`structure` is the correct token) is informational — the plan
uses `structure` consistently in Task 1, Task 5, Task 6, and the Failure
Mode → Test Map.

## AC4 provenance note

AC1–AC3 come verbatim from the Linear issue. **AC4** ("the new
`bin/dry-run-test.sh` pins the no-`bun -e` + structural-check-present
invariants") is added by the brainstorm (§11) as a verification gate the
issue does not enumerate, but that the harness convention requires —
per `CLAUDE.md::Pre-commit hook` (every reflexive invariant gets a
`*-test.sh`) and the precedent at `bin/agent-prompts-content-test.sh:1-4`
("future edits must preserve"). The plan's Goal references AC4 as the
shorthand for "Task 5 delivers the test, Task 7 confirms the hook picks
it up". The Linear issue's three ACs are unaffected.
