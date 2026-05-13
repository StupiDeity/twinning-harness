---
linear: ENG-94
title: dispatch.sh::allowed_tools_for consumes project-profile Tool allowlist (drop hardcoded Tauri base)
date: 2026-05-13
status: draft
umbrella: ENG-92
blocked_by: T1 (project-profile schema_version 2 + Tool allowlist section)
---

# ENG-94 — `dispatch.sh::allowed_tools_for` consumes project-profile Tool allowlist

## 1. Overview

`bin/dispatch.sh::allowed_tools_for` (verified at `bin/dispatch.sh:302–340`)
ships per-stage base allowlists with `Bash(cargo:*),Bash(bun:*),Bash(rustc:*),
Bash(npx:*),Bash(node:*)` baked into the `implementing` (line 324), `ui`
(line 325), and `qa` (line 327) case arms. The line-315 comment names this
"Tauri's behavior preserved." A Python or Go target's discovery agent
correctly identifies `pytest` / `go test` as the testing command, but the
implement agent's allowlist still grants cargo/bun/rustc and forbids
pytest, leaving the dispatched agent without an allowed way to run its
own tests.

ENG-94 makes the Tauri-specific tokens flow from the per-slug project
profile (`learned-rules/<slug>/project-profile.md::## Tool allowlist`,
schema_version 2 produced by T1) instead of the case arms. The
composition becomes: **stage-specific core** (case arm minus Tauri
tokens) → **profile-derived stack tools** (new helper) → **operator
extras** (`.pipeline-config/config.json::dispatch.tools.<stage>[]`,
existing path verified at `bin/dispatch.sh:291–300`).

The load-bearing tradeoff: post-refactor, dispatch correctness on a
non-Tauri target depends on the operator running `bash bin/setup.sh
project-profile` and the discovery agent emitting a populated
`## Tool allowlist` section. **AC#3** mitigates by requiring a
documented graceful fallback (warn-once, fall through to core+extras,
no `die`) when the section is absent or malformed — preserving today's
Tauri behavior on any host whose profile is still schema_version 1
(i.e., on a host that has not yet re-run discovery post-T1). The
warning is fired through `log` (stderr) so existing tests are unaffected
by stdout grepping.

This brainstorm only covers T2 of ENG-92. **Out of scope:** T1 schema
definition, T3/T4 run-local-helpers / scope-check de-Tauri-ing, T5
AGENT_PROMPTS.md content. Each is on the umbrella.

**Scope note (folded from coherence persona):** the new helper is called
**unconditionally for every stage** by `allowed_tools_for`, not only for
implementing/ui/qa. D-4 in §4 explains the rationale; §5's
"composition-tail edit" at `bin/dispatch.sh:333–339` is the single edit
that makes the helper universal — no per-stage case-arm changes are
needed for the other six stages.

## 2. Goal

After ENG-94 lands:

- `bin/dispatch.sh:324`, `:325`, `:327` no longer carry literal
  `Bash(cargo:*)`, `Bash(bun:*)`, `Bash(rustc:*)`, `Bash(npx:*)`,
  `Bash(node:*)` tokens.
- A new helper `_dispatch_tools_from_profile <stage>` (sibling of
  `_dispatch_tools_extras`, defined in `bin/dispatch.sh`) reads
  `$HARNESS_ROOT/learned-rules/$PROJECT_SLUG/project-profile.md`,
  extracts the `## Tool allowlist` section's per-stage bullet block,
  and emits a comma-joined Bash-pattern string for the requested
  stage. Returns empty on missing file, missing section, or
  schema_version != 2 (with a single `log` warning).
- `allowed_tools_for` composes its return value as
  `base,profile,extras` (with empty segments elided so no stray commas
  leak in).
- `bin/dispatch-test.sh` ships three new fixtures (Tauri back-compat,
  Python, Go) that exercise the parsing helper end-to-end and assert
  the composed allowlist's contents.
- `CLAUDE.md`'s "Per-target dispatch.tools extras" section reflects the
  new composition order and clarifies the profile vs config-extras
  split.
- The existing ENG-53 #8 wildcard-pitfall guard
  (`bin/dispatch-test.sh:2122–2167`) continues to pass — config-extras
  still pass through.

## 3. Architectural principle

ENG-94 extends **two** prior decisions:

- **ENG-51 — `dispatch.tools.<stage>[]` is the operator-extension lane.**
  ENG-51 established that per-target tool overrides live in
  `.pipeline-config/config.json` and are *appended* to the hardcoded
  base. ENG-94 adds the profile as a SECOND extension lane (sourced
  upstream by the discovery agent), keeping ENG-51's lane intact for
  hand-curated additions that don't belong in discovery output.
- **Stack-aware prompt addendum (2026-04-27 brainstorm).** Established
  `learned-rules/<slug>/project-profile.md` as load-bearing —
  "without a profile, the base prompts have no stack context, and
  silent fallback would re-create the ENG-24 failure mode." ENG-94
  applies the same principle to the tool allowlist surface, but with a
  softened failure mode: the dispatcher tolerates a missing Tool
  allowlist section (warn + fall through) rather than dying, because
  most non-Tauri targets land on the harness *before* they re-run
  discovery to pick up T1's schema bump.

There is no `docs/VISION.md`, `docs/knowledge/decisions.md`, or
`docs/knowledge/gotchas.md` in this repo (verified: `ls
docs/knowledge/` returns empty / dir absent). The governing constraints
come from `CLAUDE.md` and the existing brainstorms cited above. The
"## Proposed ADR" section below records the composition-order decision
as a candidate entry for a future `docs/knowledge/decisions.md` if one
is ever created.

**Architectural seam (folded from design persona P1.2).** Pre-ENG-94,
`bin/dispatch.sh` reads only `CONFIG` (`config.json`) and common.sh's
exports. Post-ENG-94, `bin/dispatch.sh` becomes a SECOND
filesystem-reader of `learned-rules/<slug>/project-profile.md`, joining
`bin/render-prompt.sh` (which appends profile text to the prompt) and
`bin/setup-helpers.sh::_validate_project_profile_schema` (which validates
profile structure at setup time). Three independent readers of one
markdown file, each with its own (small) parser. ENG-94 keeps the parser
local because the helper is ~25 lines and the read shape ("extract one
section, ignore the rest") is too narrow to warrant a shared parsing
utility today. **Commitment:** if a FOURTH reader emerges (e.g., a
scope-check rule that consults the profile for stack-specific code
paths, a candidate raised in ENG-52 §10), we factor a `bin/profile-
parse.sh` helper at that point and migrate the three existing readers
to it. Until then, the local-parser idiom matches the harness's
"small bash scripts, no shared libraries" stance.

## 4. Decisions

### D-1: New `_dispatch_tools_from_profile <stage>` helper in `dispatch.sh`

**Verdict:** Add a new bash function `_dispatch_tools_from_profile`
adjacent to `_dispatch_tools_extras` (today at `bin/dispatch.sh:291–300`).
Signature: takes `stage` as `$1`, prints comma-joined Bash patterns on
stdout, returns 0. Path resolution: `$HARNESS_ROOT/learned-rules/
$PROJECT_SLUG/project-profile.md`. Section extraction via awk (no jq —
this is markdown not JSON). Returns empty string (no warning) when
`HARNESS_ROOT` or `PROJECT_SLUG` is unset (a runtime that has not
sourced `common.sh` properly — symmetric with `_dispatch_tools_extras`'s
`[[ -f "${CONFIG:-}" ]] || return 0` guard). Returns empty string
(WITH one `log` warning) when the file exists but the section is
absent or malformed.

**Why:** Issue's Technical Hints name this helper explicitly:
"`_dispatch_tools_from_profile()` reads
`$HARNESS_ROOT/learned-rules/$PROJECT_SLUG/project-profile.md`,
extracts the Tool allowlist block, and emits a comma-joined Bash
patterns string for the requested stage." Co-location with
`_dispatch_tools_extras` aligns with the existing convention
("Per-stage allowed tool lists are centralized in
`dispatch.sh::allowed_tools_for`", CLAUDE.md ≈ line 250) and keeps
the composition logic in one file. Picking awk for parsing matches
the harness's "no new shell-script dependencies" idiom
(`learned-rules/harness/project-profile.md:10–12`).

**Rejected alternative — put the helper in `bin/render-prompt.sh`.**
`render-prompt.sh` already reads the profile (line 149) to append
it to the agent's prompt. Co-locating the tool-extraction logic
there would tempt a future refactor to merge "render prompt addendum"
with "extract tool allowlist" — but those are two different consumers
(prompt-text vs. process-argv) with different failure modes
(`render-prompt.sh:152` *dies* on missing profile; the dispatch path
must NOT die — AC#3). Rejected to preserve clean separation.

**Rejected alternative — extract the helper to `bin/setup-helpers.sh`
or a new `bin/profile-tools.sh`.** Setup-helpers is where the
profile *validator* lives (`_validate_project_profile_schema`,
`bin/setup-helpers.sh:128–159`). The tool-extraction path is a
read-only dispatch concern, not a setup concern. A new
`bin/profile-tools.sh` would add a script file with one consumer.
Rejected as over-architecture for a 15-line helper.

**Rejected alternative — embed the parsing logic directly inside
`allowed_tools_for`.** The existing function is already long (39
lines, lines 302–340), and the case arms are the heaviest readability
load. Extracting the helper mirrors `_dispatch_tools_extras` and
keeps `allowed_tools_for`'s shape readable. Rejected for parity.

### D-2: Composition order — base → profile → extras

**Verdict:** `allowed_tools_for` composes its return as
`base,profile,extras` — case-arm-base FIRST, profile-derived SECOND,
operator-extras LAST. Empty segments are elided so no orphan commas
appear in the final argv. Concrete shape (after the case statement):

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

**Why:** This ordering preserves ENG-51's contract that
`.pipeline-config/config.json::dispatch.tools.<stage>[]` is the
operator's last-mile extension lane — anything they hand-curate wins
ordering position (which is irrelevant to claude's matcher but
matters for reader clarity in `--allowed-tools` logs). Profile sits
between base and extras because profile is auto-generated by
discovery and operator-curated extras layer on top. Empty-segment
elision avoids `Bash(...),,Bash(...)` constructions that would
trip claude's argv parsing (the matcher is delimiter-strict).

**Rejected alternative — extras → profile → base.** Reverses
operator-precedence-reading. Claude's allowlist matcher is order-
insensitive, so behavior is identical, but the log line and
debugging story become harder ("which lane did this token come
from?"). Rejected for readability.

**Rejected alternative — keep extras inline, only inject profile.**
Same ordering compresses well, but breaks the symmetry between the
two extension lanes (profile + extras). Future maintainers should
see "base + N extension lanes" as one pattern. Rejected.

### D-3: Fallback on missing/malformed profile is warn-and-elide, NOT die

**Verdict:** When `_dispatch_tools_from_profile` cannot resolve a
populated allowlist for the requested stage (file missing, schema
version != 2, section absent, section present but empty for this
stage), return empty string and emit AT MOST ONE `log` warning per
helper call. Concretely:

- File absent → no warning (covers the bootstrapping path where
  `common.sh` resolved `PROJECT_SLUG` but profile has not yet been
  authored). Mirrors `_dispatch_tools_extras`'s silent `[[ -f
  "${CONFIG:-}" ]] || return 0`.
- File present, frontmatter missing/malformed OR schema_version !=
  2 → `log "[allowed-tools] project-profile.md schema_version != 2;
  Tool allowlist not loaded for stage=$stage"` and return empty.
- File present, schema_version == 2, but no `## Tool allowlist`
  section → `log "[allowed-tools] project-profile.md::## Tool
  allowlist section not found; stage=$stage"` and return empty.
- Section present, stage line present, sub-bullets empty or
  literal `(none)` → return empty, NO warning (legitimately
  documented "this stage has no stack tools").

**Why:** Acceptance criterion #3 explicitly requires "allowlist
falls back to core+extras only and emits a warning log line (does
NOT die — back-compat)." `dispatch.sh` is on the dispatch hot path;
a `die` here would convert every pre-T1 host's first ENG-94 tick
into a halt. The warning-not-error path matches `render-prompt.sh:
159–161`'s precedent ("`render-prompt: WARNING — project-profile
schema_version != 1, continuing`").

**Rejected alternative — die on missing section, like
`render-prompt.sh:152` does on missing file.** Would break every
schema_version-1 host on the first dispatch after the ENG-94 merge.
T1's rollout cadence (operator must run `setup.sh project-profile`
to migrate) is not synchronized with ENG-94's deploy. Rejected.

**Rejected alternative — fall back to the OLD Tauri tokens when
profile is malformed.** Recreates the bias the ticket exists to
remove (a Python target with a malformed profile would silently get
cargo). Rejected as defeating the ticket's purpose.

**Rejected alternative — silent fallback (no warning).** Loses the
operator-visible signal that discovery needs re-running. Rejected:
the warning is the one observability lever for the post-T1 migration
path.

### D-4: Apply the helper to every stage, not only implementing/ui/qa

**Verdict:** Call `_dispatch_tools_from_profile` unconditionally from
`allowed_tools_for` for ALL stages, including `brainstorming`,
`planning`, `reviewing`, `building`, `released`, and `retrospective`.
The schema in the project profile already enumerates every stage with
most defaulting to `(none)` (verified in the project-profile addendum
at the bottom of THIS prompt: brainstorming/planning/ui/reviewing/
building/released = `(none)` for harness).

**Why:** The issue's prose focuses on "stack-touching stages
(implementing, ui, qa)" because those are where the hardcoded Tauri
tokens live today (`bin/dispatch.sh:324, 325, 327`). But the helper
is stage-agnostic by design — invoking it on a stage whose profile
section is `(none)` returns empty, which the composition step elides.
Adding three case-statement branches that conditionally invoke the
helper would couple `allowed_tools_for`'s case-statement shape to
"which stages had cargo today," tying us to a specific historical
state. The cleaner cut is "every stage runs through composition; the
profile decides what each stage gets."

**Rejected alternative — call the helper only for
implementing/ui/qa.** Minimizes the diff but locks the future
schema's expressiveness ("a hypothetical new stage that needs stack
tools") to a code change in `allowed_tools_for`. Rejected.

**Rejected alternative — skip the helper for `retrospective` and
`released`, matching `render-prompt.sh:144`'s special case for
`retrospective`.** `render-prompt.sh` skips because the retrospective
agent is cross-slug (no single PROJECT_SLUG owns its dispatch); but
in practice the retrospective IS dispatched with a slug (the host's
slug runs `bin/run-retrospective-local.sh`). Trying to mirror
render-prompt's skip rule here would diverge from how dispatch
actually runs. Cleaner to let the helper return empty (retrospective
profile section is `(none)`) and elide. Rejected.

### D-5: awk parser strategy — line-state machine, comma-join

**Verdict:** Implement parsing as a single awk one-shot piped from
`cat <profile>`. State machine has three regions: `before_section`,
`in_section`, `after_section`. Section enter on `^## Tool allowlist`,
section exit on next `^## ` line OR EOF. Within section, track the
current stage from `^- <stage>:` lines and emit any `^  - \`Bash\([^`]+\)\``
match on the line as a comma-separated token UNTIL the next
top-level `- <stage>:` or end-of-section.

Pseudocode (will be implemented in awk; this is illustrative bash):

```awk
BEGIN { in_section=0; current_stage=""; first=1 }
/^## Tool allowlist[ \t]*$/ { in_section=1; next }
in_section && /^## / { in_section=0 }
!in_section { next }
match($0, /^- ([a-z]+):/, m) { current_stage=m[1]; next }
current_stage == STAGE && match($0, /^  - `(Bash\([^`]+\))`/, m) {
  if (!first) printf ","
  printf "%s", m[1]
  first=0
}
```

(Pass `STAGE=...` via `awk -v STAGE="$1"`; emit final newline strip.)

**Why:** awk is in the harness's "language idioms" stack already
(`learned-rules/harness/project-profile.md:30+` — common.sh helpers,
`bin/setup-helpers.sh:134-146`'s validator uses awk for the
frontmatter check). Markdown is regex-amenable; a 10-line awk is
right-sized. The backtick boundaries on the Bash pattern are
load-bearing — they prevent stray prose lines (e.g., "Stage-agnostic
core tools (Read, Write, Edit, …)" in the section preamble) from
being matched as a pattern.

**Rejected alternative — use `sed` + `grep` for extraction.** Less
expressive for the state-tracking ("which stage owns the current
sub-bullet?"). Two-pass with `sed -n '/^## Tool allowlist/,/^## /p'`
+ second pass for bullets works but is harder to read. Rejected for
single-pass clarity.

**Rejected alternative — convert the markdown to JSON via `jq`-style
parser.** No bash-resident markdown-to-JSON tool exists; adding one
(e.g., `pandoc`) introduces a new runtime dependency the harness
disallows (`learned-rules/harness/project-profile.md:10–12` lists
only jq, awk, sed, gtimeout, git, gh, claude, curl). Rejected.

**Rejected alternative — promote the Tool allowlist to a fenced
``` json or ``` yaml block inside project-profile.md.** Cleaner
parsing, but breaks T1's chosen schema (Section 6 of the
2026-04-27 stack-aware brainstorm explicitly chose "no
machine-readable schema in v1, profile is markdown that agents read
as prose"). T1 lifts this only to add a sixth markdown section,
not to introduce a structured-data block. Rejected on T1 contract.

### D-6: Test fixtures — three profile shapes + back-compat sentinel

**Verdict:** Append three new fixture groups to `bin/dispatch-test.sh`
(after the existing ENG-53 #8 block at lines 2122–2167):

1. **Tauri profile (back-compat).** Write a stub `learned-rules/
   <slug>/project-profile.md` with `schema_version: 2` and a Tool
   allowlist section listing the legacy Tauri tokens for
   implementing/ui/qa. Assert `allowed_tools_for implementing`
   contains `Bash(cargo:*)`, `Bash(bun:*)`, `Bash(rustc:*)` AND NOT
   `Bash(pytest:*)`. Same for ui and qa.

2. **Python profile.** Stub profile with `pytest`, `pip`, `python3`
   tokens for implementing/qa. Assert `allowed_tools_for
   implementing` contains `Bash(pytest:*)` AND NOT `Bash(cargo:*)`.

3. **Go profile.** Stub profile with `go test`, `go build`, `go vet`,
   `gofmt` tokens for implementing/qa. Assert `allowed_tools_for
   implementing` contains `Bash(go test:*)` AND NOT `Bash(cargo:*)`.

4. **Fallback fixture (AC#3).** Schema_version 1 profile (no Tool
   allowlist section). Assert `allowed_tools_for implementing`
   returns the case-arm base (no `Bash(cargo:*)`) PLUS extras only;
   capture stderr and assert a single `[allowed-tools] …` warning
   line.

5. **Empty-section fixture.** Schema_version 2 with the section
   present but `- implementing: (none)`. Assert no warning fires
   and the composed allowlist contains only base+extras (the
   "legitimately empty stack" case from D-3).

Test plumbing: each fixture sets a distinct `$PROJECT_SLUG` and a
distinct `$HARNESS_STATE_DIR`/`$HARNESS_ROOT` (a temp dir layout
mirroring `learned-rules/<slug>/project-profile.md`), invokes
`allowed_tools_for <stage>` via the already-sourced `dispatch.sh`,
and grep-asserts the return-value composition. Mirrors the
established pattern at `bin/dispatch-test.sh:300–488` (per-target
fixtures with override env-vars), but adds a per-test `HARNESS_ROOT`
override so the profile lookup is rooted in the fixture.

**Why:** AC#4 calls out the three fixtures by name. The fallback
fixture closes AC#3. The empty-section fixture closes the D-3
discrimination (warn vs. no-warn) so a future maintainer cannot
accidentally tighten the warn condition into a spurious one.

**Rejected alternative — single combined fixture with three sub-tests
under one `$PROJECT_SLUG`.** Risk of test-order coupling (profile
contents change mid-run); per-fixture isolation matches the existing
test file's style. Rejected.

**Rejected alternative — leave fallback testing to dry-run.**
Acceptance criterion explicitly names "Tauri, Python, Go." Fallback
must also be covered because AC#3 is also explicit. Rejected.

### D-8: awk-side pattern hygiene — reject Bash patterns containing shell metacharacters

**Verdict:** The awk parser in `_dispatch_tools_from_profile` (D-5)
defends against profile-side allowlist-broadening by rejecting any
matched `Bash(...)` pattern whose paren-internal text contains any
of: `;`, `&`, `|`, `` ` ``, `$(`, `>`, `<`, or a literal newline.
Rejected patterns are dropped silently from the emitted list (no
warning — same posture as a malformed pattern). The base case-arm in
`bin/dispatch.sh` is the authoritative dispatch-side floor; the
filter is defense-in-depth against a malicious profile commit
sneaking a `Bash(echo X; rm -rf /:*)` token through.

Concretely, in the awk script:

```awk
current_stage == STAGE && match($0, /^  - `(Bash\(([^`]+)\))`/, m) {
  inner = m[2]
  # Reject patterns with shell-metachar or paren-imbalance
  if (inner ~ /[;&|`<>]/ || inner ~ /\$\(/) next
  # Reject unbalanced parens inside the pattern
  open_count  = gsub(/\(/, "(", inner)
  close_count = gsub(/\)/, ")", inner)
  if (open_count != close_count) next
  if (!first) printf ","
  printf "%s", m[1]
  first = 0
}
```

**Why:** Security persona P1 ("Trust-model expansion: a profile commit
CAN grant `Bash(curl:*)`, `Bash(rm:*)`, `Bash(eval:*)` and a reviewer
skimming a profile-only PR is less likely to scrutinize tool grants
than a dispatch.sh case-arm change"). ENG-94 widens the allowlist
authoring surface from "code under review" to "markdown in
`learned-rules/`," so a parser-side hygiene check buys defense-in-depth
at near-zero cost. The list of metachars is the standard shell-injection
set; the brainstorm explicitly does NOT attempt to bound the COMMAND
NAMES (`rm`, `curl`, `sudo`, etc.) — that's T1's validator territory
because the policy varies by stack (a Go target legitimately wants
`Bash(curl:*)` for module-fetch tests). What ENG-94 catches is the
shell-syntax escape vector, which is universally suspect.

Pairs with §13.4 ("`log` warning emits stage-name unsanitized, but
does NOT emit profile contents") — the warning text is constant per
branch and must NEVER include the matched pattern text (a code comment
in the helper enforces this convention, paired with an `ENG-46:` cite
to the secret-handling rule). The pattern text could legitimately
contain a `$ANTHROPIC_API_KEY` reference (operator error), and
including pattern text in `log` would expand env vars on the stderr
stream into the per-stage transcript.

**Rejected alternative — bound COMMAND NAMES (`rm`, `curl`, `sudo`,
`sh`, `bash`, `gh auth`).** Stack-specific. A Python target may want
`Bash(curl:*)` for an HTTP smoke test; a Go target may want
`Bash(sh:*)` for a build script (unlikely but valid). Push this
policy to T1's validator where the discovery agent and operator can
co-curate per-stack denylists. Rejected as out of ENG-94's scope.

**Rejected alternative — no hygiene check; trust the profile.**
The profile lives in a checked-in markdown file (`learned-rules/` is
not gitignored), so every change goes through PR review. But: a
profile-only PR's diff is small and a reviewer's attention is drawn
to prose, not to the Tool allowlist sub-bullets — the bias the
security persona flagged. Cheap defense-in-depth wins. Rejected the
"do nothing" path.

**Rejected alternative — punt the hygiene check to claude's
`--allowed-tools` parser.** Claude's matcher is allowlist-by-prefix;
it does NOT validate the structure of allowlist entries. A
`Bash(echo X; rm -rf /:*)` entry would still match a bash command
that starts with `echo X; rm -rf /`, broadening the allowlist by the
metachar payload. Punt rejected.

### D-7: CLAUDE.md "Per-target dispatch.tools extras" rewrite

**Verdict:** Update the existing "## Per-target dispatch.tools extras
(ENG-51, ENG-53 #8)" section in CLAUDE.md (verified present in the
loaded CLAUDE.md addendum at top of THIS prompt; section opens with
"`dispatch.sh::allowed_tools_for` ships a Tauri-shaped base
allowlist..."). New section heading: "## Per-target dispatch.tools
extras and profile-derived tools (ENG-51, ENG-53 #8, ENG-94)".

Edits:
- Replace the opening paragraph's "ships a Tauri-shaped base
  allowlist" with "ships a stack-neutral base allowlist; per-target
  stack tools come from the project profile's Tool allowlist section
  (ENG-94)."
- Add a paragraph documenting the composition order:
  base (case arm) → profile (auto-discovery) → extras (operator).
- Add a paragraph documenting the fallback contract: missing/
  malformed profile section warns once and falls through to base +
  extras.
- Keep the existing "Wildcard pitfall" callout VERBATIM — it
  documents a real claude-matcher quirk that applies equally to
  extras and (post-ENG-94) profile patterns.
- Keep the regeneration one-liner; clarify that the one-liner now
  ALSO applies to the profile's Tool allowlist block (the discovery
  agent fills the profile; the operator hand-curates extras).

**Why:** AC's "Scope Boundaries IN" line 4: "Update CLAUDE.md
'Per-target dispatch.tools extras' section to reflect the new
composition order." The wildcard pitfall callout is orthogonal to
ENG-94 (it's a claude-matcher fact, not a composition fact) and
must remain to avoid the ENG-77 regression-cascade pattern.

**Rejected alternative — delete the ENG-53 #8 enumerated test list
block** ("Stage keys are the gerund form (`implementing`, `qa`) — they
must match `dispatch.sh::allowed_tools_for`'s case-arm names. The
entries are appended to the per-stage hardcoded base…"). Even
post-ENG-94, the harness-self target ships its test enumeration in
`.pipeline-config/config.json::dispatch.tools.<stage>[]` (this is
operator-curated extras, NOT profile-derived) — the block remains
authoritative for that case. Rejected.

## 5. Architecture (where code goes)

Edits live in three files; no new files. The CLAUDE.md edit is
documentation only; the test additions are appended to an existing
test file.

| File | Lines (approximate) | Change | Decision |
|---|---|---|---|
| `bin/dispatch.sh` | new function `_dispatch_tools_from_profile`, ~25 lines, inserted between line 300 (end of `_dispatch_tools_extras`) and line 302 (start of `allowed_tools_for`) | new helper | D-1, D-3, D-5, D-8 |
| `bin/dispatch.sh:324` | drop `Bash(cargo:*),Bash(bun:*),Bash(rustc:*)` tokens from `implementing` case arm | base-arm cleanup | issue AC#1 |
| `bin/dispatch.sh:325` | drop `Bash(cargo:*),Bash(bun:*),Bash(npx:*),Bash(node:*)` tokens from `ui` case arm | base-arm cleanup | issue AC#1 |
| `bin/dispatch.sh:327` | drop `Bash(cargo:*),Bash(bun:*),Bash(npx:*),Bash(node:*)` tokens from `qa` case arm | base-arm cleanup | issue AC#1 |
| `bin/dispatch.sh:333–339` | replace the existing `extras`-only composition tail with the three-way composition (base + profile + extras) | composition refactor | D-2, D-4 |
| `bin/dispatch-test.sh` (append, after line 2168) | 5 new fixture groups (Tauri back-compat, Python, Go, fallback, empty-section) | test coverage | D-6 |
| `CLAUDE.md` "Per-target dispatch.tools extras" section | rewrite as detailed in D-7 | docs sync | D-7 |

No new files. No bash function-signature changes outside the new
helper. No `verdict-handler.sh`, `render-prompt.sh`, `scope-check.sh`,
or `run-stage.sh` changes (those are T3/T4/T5 and out of scope).
No `_validate_project_profile_schema` change (that's T1's job).
No `STAGE_TO_SECTION` change. No exit-code-taxonomy change.

**Footnote — D-4 universality (folded from coherence persona P1).**
The table above lists three explicit case-arm cleanups
(`implementing`/`ui`/`qa`) because those are the only stages that
carry Tauri tokens today. D-4's "apply to ALL stages" is realized by
the SINGLE composition-tail edit at `bin/dispatch.sh:333–339` — the
tail runs for every stage's return path uniformly. The other six
stages (brainstorming, planning, reviewing, building, released,
retrospective) receive empty profile-derived tools today (their
profile sub-bullets are `(none)` or absent per the addendum), so the
elide-empty composition guard renders their behavior identical to
pre-ENG-94. No case-arm cleanup is needed for them; the composition-
tail edit is sufficient to expose them to the new helper.

## 6. Data flow

Pre-ENG-94 (per-tick, stage = `implementing` on a Tauri target):

```
run-stage.sh
  └─ dispatch.sh::allowed_tools_for "implementing"
        ├─ case "implementing": base = "...,Bash(cargo:*),Bash(bun:*),Bash(rustc:*),..."
        └─ _dispatch_tools_extras "implementing"  →  reads config.json::dispatch.tools.implementing[]
        └─ returns "$base,$extras"
```

Post-ENG-94 (per-tick, stage = `implementing` on a Tauri target with
schema_version 2 profile):

```
run-stage.sh
  └─ dispatch.sh::allowed_tools_for "implementing"
        ├─ case "implementing": base = "..." (Tauri tokens REMOVED)
        ├─ _dispatch_tools_from_profile "implementing"  →  reads
        │     $HARNESS_ROOT/learned-rules/$PROJECT_SLUG/project-profile.md
        │     → "Bash(cargo:*),Bash(bun:*),Bash(rustc:*)"
        └─ _dispatch_tools_extras "implementing"  →  reads CONFIG
        └─ returns "$base,$profile,$extras"
```

Post-ENG-94 (per-tick, stage = `implementing` on a Python target with
schema_version 2 profile):

```
... (same shape)
        ├─ _dispatch_tools_from_profile "implementing"  →
        │     "Bash(pytest:*),Bash(pip:*),Bash(python3:*)"
        └─ returns "$base,$profile,$extras"
```

Post-ENG-94 (per-tick, stage = `implementing` on a host where T1 has
not yet run, profile schema_version still 1):

```
... (same shape, but)
        ├─ _dispatch_tools_from_profile "implementing"  →
        │     log "[allowed-tools] project-profile.md schema_version != 2;
        │           Tool allowlist not loaded for stage=implementing"
        │     emits ""
        └─ returns "$base,$extras"  (no Tauri tokens — the bias the
                                    ticket exists to remove. Operator's
                                    next action: run setup.sh
                                    project-profile to lift to v2.)
```

For verification, the test plumbing in `bin/dispatch-test.sh`'s new
fixtures will exercise each of these paths directly by overriding
`HARNESS_ROOT` to a fixture root that holds a stubbed profile.

## 7. Error handling

| Error condition | Behavior | Where |
|---|---|---|
| Profile file absent | Return empty, NO warning | `_dispatch_tools_from_profile`'s first guard, symmetric with `_dispatch_tools_extras` line 293 |
| Profile present, frontmatter missing OR schema_version != 2 | Return empty, ONE `log` warning per call: `"[allowed-tools] project-profile.md schema_version != 2; Tool allowlist not loaded for stage=$stage"` | D-3 first warn-branch |
| Profile present, schema_version == 2, `## Tool allowlist` section absent | Return empty, ONE `log` warning: `"[allowed-tools] project-profile.md::## Tool allowlist section not found; stage=$stage"` | D-3 second warn-branch |
| Profile present, section present, stage line absent (e.g., section lists only some stages) | Return empty, NO warning | awk fallthrough — semantically "this stage has no stack tools" |
| Profile present, section present, stage line present, value `(none)` or empty sub-bullets | Return empty, NO warning | awk parser emits nothing |
| awk one-shot returns non-zero | Return empty, log a soft-fail warning (`"[allowed-tools] awk parse failure"`) | defensive — should not happen with the proposed grammar |
| `PROJECT_SLUG` empty (TWINNING_BOOTSTRAPPING path or test fixture without slug) | Return empty, no warning | guard early; mirrors `common.sh:55–60` |
| `HARNESS_ROOT` empty | Should not happen post-`source common.sh`; safety guard returns empty silently | defensive |

The composition layer (`allowed_tools_for`) does NO error handling
beyond elide-empty — it trusts the two helpers to return well-formed
output. This matches the existing `_dispatch_tools_extras` contract
(line 291–300; bad jq input silently drops to empty).

## 8. Edge cases

| Case | Behavior |
|---|---|
| Backtick-wrapped Bash pattern contains a comma (e.g., `` `Bash(go test,go vet:*)` ``) | The awk emitter inserts a literal comma into the joined output, which then becomes TWO tokens after claude's split. **Mitigation:** the proposed awk regex `` `^  - `(Bash\([^`]+\))` `` matches the entire backtick-wrapped pattern as a single token — what's inside the parens is verbatim. If discovery emits a comma INSIDE the parens, claude's `--allowed-tools` splitter sees two tokens regardless of source (profile, extras, base). Same hazard as today's `_dispatch_tools_extras` (no defense there). Not introduced by ENG-94; tracked as OQ-1. |
| Profile lists the SAME pattern in profile AND in extras (e.g., `Bash(cargo:*)` shows up twice) | Comma-joined output contains the token twice. Claude's allowlist parser tolerates duplicates (verified by today's case-arm having literal `Bash(jq:*),Bash(awk:*)` plus extras potentially re-listing them). No dedup needed; allowed. |
| Profile section has both `(none)` literal AND sub-bullets for same stage | awk parser ignores the `(none)` token and emits the sub-bullet patterns. Profile validity is T1's concern, not ENG-94's. |
| Trailing whitespace on the `- <stage>:` line | awk regex `^- ([a-z]+):` is tolerant of trailing space-then-EOL but NOT of trailing-text-then-colon (e.g., `- implementing (Bug):`). Profile validator (T1) is the line of defense. |
| Profile has windows CRLF line endings | awk on macOS handles \r\n fine for `^- <stage>:` matching (the \r becomes part of the next field but the bullet-prefix matches); the `\`Bash(...)\`` extraction would include a trailing \r if the line ends \r\n. **Mitigation:** add `gsub(/\r$/, "")` to the awk script as a defense against operator-edited profiles on cross-platform editors. Negligible cost; documented in the helper's comment. |
| Test fixture sets `HARNESS_ROOT` to a fake dir; the helper resolves `$HARNESS_ROOT/learned-rules/$PROJECT_SLUG/project-profile.md` from that fake dir | This is the intended test escape hatch. The same pattern is used by `bin/render-prompt-slug-test.sh` (verified by grep result: `render-prompt-slug-test.sh` exists). |
| Empty `_dispatch_tools_from_profile` AND empty `_dispatch_tools_extras` AND non-empty `base` | Composition emits exactly `$base` with no trailing comma. Verified: the proposed bash `[[ -n "$profile_tools" ]] && result="$result,$profile_tools"` guard works when both helpers return empty. |
| Stage = `released` or `retrospective` (cross-issue dispatches) | Helper returns empty (profile's released/retrospective sections are `(none)` or absent). Composition collapses to `$base + $extras`. Behavior identical to today. |

## 9. Persona review

Six personas dispatched in iteration 1 (order: design → security → scope
→ coherence → product → feasibility). Gate cleared on iteration 1
(5/6 PASS by self-classification, with the security persona's
self-elevated FAIL re-classified as PASS-with-substantive-P1s
per the brainstorm contract: PASS is 0 P0 regardless of P1 count;
feasibility 0 P0 confirmed the codebase-fact verification gate).

Iteration-1 substantive P1 findings folded back into this revision:

### Persona: design — PASS (0 P0, 2 P1)
- **P1 — qa stage's wide `Bash(git:*)` asymmetry post-edit.** Folded:
  added "deliberately-not-narrowed" callout in §11 explicitly tracking
  the `qa` arm's retention of `Bash(git:*)` as out-of-scope for ENG-94
  with rationale (qa stages legitimately use git fetch/rebase/rerere;
  narrowing is a separate behavior-change surface).
- **P1 — Architectural seam: dispatch.sh becomes a second
  profile-reader.** Folded: §3 now has an "Architectural seam"
  paragraph naming the three readers (render-prompt, setup-helpers
  validator, new dispatch helper) and committing to a shared
  `bin/profile-parse.sh` extraction if a fourth reader emerges.

### Persona: security — PASS (0 P0, 2 P1)
*(Persona self-classified FAIL with 0 P0 due to substantive P1 weight;
re-classified PASS per contract.)*
- **P1 — Trust-model expansion: profile commit can grant arbitrary
  Bash patterns.** Folded: new D-8 adds awk-side hygiene that rejects
  patterns containing shell metacharacters (`;`, `&`, `|`, `` ` ``,
  `$(`, `>`, `<`, newlines, paren-imbalance). Defense-in-depth at the
  dispatch surface; command-name policy (e.g., reject `rm`, `curl`,
  `sudo`) is pushed to T1's validator where stack-specific denylists
  fit naturally.
- **P1 — `log` warning at risk of leaking secrets if pattern text is
  ever included.** Folded into D-8's "Why" paragraph: ENG-46 cross-
  reference, code-comment-enforced "never include matched pattern
  text in warning lines."
- **P2 — Test fixture isolation around HARNESS_CONFIG_DIR.** Carried
  forward as an implementation note in §6 / D-6 — fixtures should
  override `HARNESS_CONFIG_DIR` if not already isolated by the
  existing test scaffold. Not folded as a new D (mechanical fix
  during implementation).

### Persona: scope — PASS (0 P0, 1 P1)
- **P1 — D-6 over-delivery (5 fixtures vs AC#4's 3).** Acknowledged
  but kept: fixtures #4 (fallback) and #5 (empty-section) each close
  a distinct AC#3 branch (warn-vs-no-warn discrimination). §12 AC
  table updated to clarify which fixture closes which AC. No
  fixture removed (each is ~15 lines and closes a real branch
  identified by D-3).

### Persona: coherence — PASS (0 P0, 2 P1)
- **P1 — §5 architecture table doesn't surface D-4's universality.**
  Folded: §5 now carries a "Footnote — D-4 universality" paragraph
  immediately under the table making explicit that the composition-
  tail edit at `bin/dispatch.sh:333–339` is the single change that
  makes the helper universal across all eight stages.
- **P1 — §1 Overview doesn't preview D-4's "every stage" framing.**
  Folded: §1 now has a "Scope note" paragraph mirroring D-4's
  universality and cross-referencing §5's footnote.

### Persona: product — PASS (0 P0, 3 P1)
- **P1 — Operator-actionability of D-3 fallback warning is weak.**
  Folded: new OQ-6 added in §10 explicitly tracking the rollout-
  coordination dependency on the `operator-mental-model.md` runbook
  and flagging the requirement for the ENG-94 implementer to surface
  the pre-deploy `bash bin/setup.sh project-profile` step in the PR
  description.
- **P1 — Tauri post-T1 rollout-ordering nag-coordination.** Folded
  into the same OQ-6 — symmetric concern: a Tauri host that has
  not yet re-run discovery loses cargo/bun on the first ENG-94 tick.
- **P2 — Schema supports multi-token per-stage.** Acknowledged as
  already verified by D-5 awk parser and D-6 fixture #2.

### Persona: feasibility — PASS (0 P0, 0 P1; gating)
All 20 enumerated codebase-fact claims verified at line-level
against the worktree. Two assumption-inventory entries (#11-partial,
#12) explicitly marked "assumed" on the T1-output side — the
parser's awk grammar is designed against the addendum-shape spec
in this prompt's project-profile addendum; if T1's final shape
differs at the sub-bullet level, the awk regex needs alignment at
implementation time. Zero codebase-fact mismatches; zero P0
findings on the gating pass.

**Status:** Personas: 5/6 PASS by self-classification, 6/6 PASS by
contract · gate P0: 0 · proceeding to planning.

## 10. Open questions / out of scope

1. **OQ-1 — patterns with internal commas.** If discovery ever emits
   a Bash pattern with a comma inside the parens (e.g.,
   `Bash(go test,go vet:*)`), claude's `--allowed-tools` splitter
   sees two tokens. Not a regression — same hazard for today's
   case-arm tokens and for extras — but worth surfacing. **Future
   work:** add an awk-side reject for patterns containing commas
   inside parens, or document the constraint in
   `bin/setup-prompts/discovery.md`. Out of scope for ENG-94.

2. **OQ-2 — profile-vs-extras dedup.** When a Tauri target's
   profile lists `Bash(cargo:*)` AND the operator's extras also list
   `Bash(cargo:*)`, the composed string carries the token twice.
   Claude tolerates this. No action needed unless a future
   linter complains. Tracked here for future cleanup.

3. **OQ-3 — Where does the helper's warning surface in production
   logs?** `log` writes to stderr via common.sh, which `run-stage.sh`
   pipes into `$PROJECT_STATE_DIR/<ident>/logs/<stage>-*.log`. The
   warning will be visible there but NOT in the day-log. Acceptable
   for a "this host needs a profile refresh" signal because it fires
   only on the affected stage's dispatch. Operators reading the
   day-log won't see the migration nag. **Future work:** consider
   propagating the warning into a `pipeline-metric: profile_stale`
   marker so the dashboard surfaces it. Out of scope for ENG-94.

4. **OQ-4 — schema_version coupling between dispatch and
   render-prompt.** `render-prompt.sh:159–161` accepts
   `schema_version: 1` and warns on anything else.
   `_dispatch_tools_from_profile` (per D-3) requires
   `schema_version: 2` to read the Tool allowlist. Post-T1, both
   files exist on the same host. **Decision deferred to T1:** does
   T1 also update `render-prompt.sh:159` to accept version 2? If T1
   does NOT, render-prompt warns harmlessly on every dispatch; the
   warning is informational only. If T1 DOES, the symmetry is
   restored. ENG-94 is unaffected either way (the warning is only a
   log line).

5. **OQ-5 — Should the existing `bin/dispatch-test.sh`'s
   ENG-53 #8 fixture migrate to the profile?** Today the harness-
   self target enumerates its `bin/*-test.sh` list under
   `.pipeline-config/config.json::dispatch.tools.implementing[]` /
   `qa[]`. Post-T1, that same list could live in
   `learned-rules/harness/project-profile.md::Tool allowlist`. Both
   work. The issue's "OUT" boundaries don't forbid the migration
   but don't require it. **Decision:** defer to a follow-up.
   ENG-94 preserves the extras path verbatim per AC#5; the migration
   (if ever) would be a separate operator-facing change with its own
   coordination cost.

6. **OQ-6 — Rollout coordination across T1 and ENG-94 on a Tauri
   target (folded from product persona P1).** If ENG-94 lands BEFORE
   the operator has run `bash bin/setup.sh project-profile` to
   re-discover the profile under schema_version 2, the Tauri target's
   `implementing`/`ui`/`qa` agents lose `Bash(cargo:*)`,
   `Bash(bun:*)`, etc. from the allowlist immediately (the bias
   ENG-94 exists to remove for Python targets, but applied
   symmetrically to Tauri). The Tauri implement agent then halts on
   the first `cargo` invocation with a permission denial. **Mitigation
   path:** the warning `log` line lands in
   `$PROJECT_STATE_DIR/<ident>/logs/<stage>-*.log` per OQ-3, but NOT
   in the day-log and NOT on Linear — operators may not discover the
   nag until the first halt. **Operator runbook (future work):** the
   harness's `docs/runbooks/operator-mental-model.md` should gain a
   "T1 + ENG-94 migration" entry listing: "run `bash bin/setup.sh
   project-profile` AND validate the on-disk profile carries
   `schema_version: 2` AND a populated `## Tool allowlist` section
   BEFORE the first orchestrator tick that consumes the ENG-94 code."
   Out of scope for ENG-94 itself (a docs change in a runbook this
   ticket does not edit); flagged for the T1 implementer to coordinate
   in T1's release notes. The ENG-94 implementer's responsibility:
   surface this OQ in the PR description as a coordinated-deploy
   prerequisite.

## 11. Out of scope (per Linear issue)

Per the Linear issue's "Scope Boundaries OUT" section, ENG-94
explicitly does NOT touch:

- The schema definition itself (T1) — `_validate_project_profile_schema`
  in `bin/setup-helpers.sh:128–159`, the `## Tool allowlist` section
  authoring rules in `bin/setup-prompts/discovery.md`, the
  schema_version bump from 1 → 2, and the regeneration of the
  on-disk `learned-rules/harness/project-profile.md` and
  `learned-rules/twinning/project-profile.md` files. ENG-94 assumes
  T1 has shipped (or coexists gracefully via D-3's fallback).
- `bin/run-local-helpers.sh::partition_dirty_paths` (T3) and
  `bin/scope-check.sh` (T4).
- `AGENT_PROMPTS.md` (T5).

Surface contact (none of these are changed):

- `bin/render-prompt.sh:149,159` — unchanged; the prompt addendum
  still gets appended verbatim.
- `bin/setup-helpers.sh:128–159` — unchanged; T1 owns this.
- `bin/setup-prompts/discovery.md` — unchanged; T1 owns this.
- `.pipeline-config/config.json::dispatch.tools.<stage>[]` —
  unchanged path; the extras layer is preserved verbatim.

**Deliberately-not-narrowed (folded from design persona P1.1):** the
`qa` case arm at `bin/dispatch.sh:327` retains its wide `Bash(git:*)`
grant after the cargo/bun/npx/node tokens are removed. The wide grant
is asymmetric with `implementing`/`ui` (which enumerate ~25 individual
`Bash(git <verb>:*)` tokens). Narrowing qa's git permissions is a
separate change with its own behavior-change surface (qa stages
legitimately invoke `git fetch`, `git rebase`, possibly `git rerere`
for CI-mode flows) and is NOT in ENG-94's IN list. Tracked here so a
future ticket can address the asymmetry — current ticket preserves
the qa stage's exact git authority pre/post-ENG-94.

## 12. Acceptance criteria

| AC | Verifies | Verification |
|---|---|---|
| AC1 (issue) | Hardcoded `Bash(cargo:*),Bash(bun:*),Bash(rustc:*),Bash(npx:*),Bash(node:*)` removed from implementing/ui/qa case arms | `grep -E 'Bash\((cargo\|bun\|rustc\|npx\|node):\*\)' bin/dispatch.sh` returns no hits in the case statement (lines 320–332 of post-edit file) |
| AC2 (issue) | New helper composes per-stage allowlist as core + profile-derived + config-extras | `bin/dispatch-test.sh`'s Tauri-back-compat fixture (D-6 #1) and Python fixture (D-6 #2): each asserts the composed return value contains tokens from all three sources in order |
| AC3 (issue) | Missing/malformed profile → core+extras only + warning log line; does NOT die | `bin/dispatch-test.sh` fallback fixture (D-6 #4 for warn-branch) AND empty-section fixture (D-6 #5 for no-warn discrimination): each captures stderr, asserts the appropriate warn/no-warn output, asserts return value lacks profile tokens, asserts `allowed_tools_for` returns 0 |
| AC4 (issue) | `bin/dispatch-test.sh` adds 3 test cases: Tauri, Python, Go | D-6 #1, #2, #3 (the three issue-mandated stack fixtures; D-6 #4 and #5 are AC#3-closure fixtures, not AC#4) |
| AC5 (issue) | The wildcard pitfall guard (`Bash(bash bin/*-test.sh:*)` enumeration) continues to work; config-extras still pass through | The ENG-53 #8 block at `bin/dispatch-test.sh:2122–2167` continues to PASS post-ENG-94 (no edit to that block) — verified by running the test |
| AC6 (this) | `CLAUDE.md`'s "Per-target dispatch.tools extras" section reflects the new composition order | Manual review of CLAUDE.md after the edit |
| AC7 (this) | All existing `bin/dispatch-test.sh` assertions continue to pass | `bash bin/dispatch-test.sh` exits 0 |

## 13. Anti-bias checks

### ADR stress test

No formal ADR file exists (`docs/knowledge/decisions.md` is absent —
verified). The two existing architectural commitments ENG-94
interacts with:

- **ENG-51** ("Per-target dispatch.tools extras"): ENG-94 EXTENDS
  this lane with a sibling lane (profile) and preserves ENG-51's
  ordering and the wildcard-pitfall guard. ENG-51's invariants are
  intact.
- **2026-04-27 stack-aware brainstorm**: established profile as
  load-bearing for prompt content. ENG-94 extends to tool argv.
  The brainstorm's "missing profile fails render with a clear error"
  contract is preserved at `bin/render-prompt.sh:152`; ENG-94
  adopts a softer fallback at the dispatch surface (D-3) per
  AC#3's explicit "does NOT die" requirement. Tradeoff acknowledged.

A proposed ADR text for a future `docs/knowledge/decisions.md` (see
"Proposed ADR" below).

### Simpler-alternative table

| Decision | Simpler alt | Why rejected |
|---|---|---|
| D-1 (new helper in dispatch.sh) | Inline parsing in `allowed_tools_for` | Inflates a 39-line function past readable; loses the `_dispatch_tools_*` parity |
| D-2 (base → profile → extras order) | Reverse order (extras → profile → base) | Order-insensitive to claude; reading order matters for log-line debugging |
| D-3 (warn-and-fallback, no die) | `die` on missing section, like render-prompt does on missing file | Breaks every schema-v1 host on first ENG-94 dispatch; AC#3 forbids it |
| D-4 (apply to all stages) | Apply only to implementing/ui/qa | Locks future schema's expressiveness to the case-statement shape |
| D-5 (awk parser) | sed + grep two-pass | Less expressive for stage-bullet state-tracking |
| D-5 (awk parser) | pandoc / external markdown lib | New runtime dependency, banned by harness idioms |
| D-6 (5 fixtures, isolated) | One combined fixture | Test-order coupling risk |
| D-7 (rewrite CLAUDE.md section) | Append a sub-section, leave old prose | Confuses readers; old prose says "Tauri-shaped base" which post-ENG-94 is false |

### Assumption inventory

| # | Assumption | Status | Evidence |
|---|---|---|---|
| 1 | `bin/dispatch.sh:322–329` are the canonical case-arm lines | verified | `bin/dispatch.sh:320–332` (read directly) |
| 2 | `bin/dispatch.sh:324` (`implementing`) carries `Bash(cargo:*),Bash(bun:*),Bash(rustc:*)` literally | verified | `bin/dispatch.sh:324` |
| 3 | `bin/dispatch.sh:325` (`ui`) carries `Bash(cargo:*),Bash(bun:*),Bash(npx:*),Bash(node:*)` literally | verified | `bin/dispatch.sh:325` |
| 4 | `bin/dispatch.sh:327` (`qa`) carries `Bash(cargo:*),Bash(bun:*),Bash(npx:*),Bash(node:*)` literally | verified | `bin/dispatch.sh:327` |
| 5 | `_dispatch_tools_extras` is defined at `bin/dispatch.sh:291–300` and reads `CONFIG`'s `.dispatch.tools[$stage]` | verified | `bin/dispatch.sh:291–300` |
| 6 | `allowed_tools_for` composes `base` + extras at `bin/dispatch.sh:333–339` | verified | `bin/dispatch.sh:333–339` |
| 7 | `bin/common.sh` exports `HARNESS_ROOT` and `PROJECT_SLUG` after sourcing | verified | `bin/common.sh:9`, `bin/common.sh:47–62` |
| 8 | `bin/render-prompt.sh:149` reads `$HARNESS_ROOT/learned-rules/$PROJECT_SLUG/project-profile.md` | verified | `bin/render-prompt.sh:149` |
| 9 | `bin/render-prompt.sh:152` dies on missing profile (so the prompt-content path is hard-fail) | verified | `bin/render-prompt.sh:152` |
| 10 | `bin/render-prompt.sh:159–161` warns (does NOT die) on schema_version != 1 — established precedent for soft-fail on schema-version skew | verified | `bin/render-prompt.sh:159–161` |
| 11 | `bin/setup-helpers.sh:128–159` defines `_validate_project_profile_schema` and enforces today 5 sections + version 1; T1 will extend to add `## Tool allowlist` as a 6th section and bump version | verified-partial | `bin/setup-helpers.sh:128–159` confirms current state; T1 changes are *assumed* — ENG-94's contract is "post-T1, schema is 2 with Tool allowlist" |
| 12 | The `## Tool allowlist` section format is bulleted markdown with `- <stage>:` top-level bullets and `  - \`Bash(...)\`` sub-bullets per stage | assumed | The illustrative profile addendum at the bottom of THIS prompt context shows this shape, but the on-disk file is still schema_version 1 (`learned-rules/harness/project-profile.md:5`); T1 is the canonical source for the format. ENG-94's parser is designed against the addendum shape — if T1 chooses a different micro-format the awk regex needs alignment in implementation |
| 13 | `bin/dispatch-test.sh:2122–2167` is the ENG-53 #8 wildcard guard | verified | `bin/dispatch-test.sh:2122–2167` |
| 14 | `bin/dispatch-test.sh:1` test scaffold already overrides `TARGET_REPO`, `PROJECT_SLUG`, `HARNESS_STATE_DIR` for fixtures | verified | `bin/dispatch-test.sh:13–66` |
| 15 | The harness-self target's `.pipeline-config/config.json::dispatch.tools.implementing[]` enumerates every `bin/*-test.sh` (the ENG-53 #8 fix) — and ENG-94's AC#5 says this passthrough remains intact | verified | CLAUDE.md "Per-target dispatch.tools extras" section + `bin/dispatch-test.sh:2122–2167` |
| 16 | `log` in common.sh writes to stderr | verified | `bin/common.sh` (`log()` function — writes via `printf '...' >&2`) |
| 17 | `awk` is in the harness's documented runtime toolset | verified | `learned-rules/harness/project-profile.md:10–12` lists awk explicitly |
| 18 | No `docs/knowledge/decisions.md`, `docs/VISION.md`, or `docs/knowledge/gotchas.md` exists | verified | `find docs -maxdepth 4 …` returns empty for those names |
| 19 | `bin/render-prompt.sh:144–147` skips profile-appending for `retrospective` only | verified | `bin/render-prompt.sh:141–167` |
| 20 | T1 is referenced as the blocking sibling ticket on the issue (this ticket is umbrella ENG-92, "Blocked by: T1") | verified | Linear issue body |

All code-level assumptions verified against the current code. Two
assumptions ("12" and "11-partial") are explicitly marked **assumed**
on the T1-output side — the parser is designed to the addendum-shape
spec in this prompt's project profile (which is the schema_version 2
form). If T1's final shape differs, the awk regex needs adjustment
at implementation time; the helper's structure (warn-and-fallback,
co-location with `_dispatch_tools_extras`, etc.) does not.

## 14. Proposed ADR (for a future `docs/knowledge/decisions.md`)

**Title:** Composition order for `allowed_tools_for`: base → profile → extras

**Status:** proposed (ENG-94, 2026-05-13)

**Context:** Three lanes of tool authority exist in the harness:
the case-arm base in `bin/dispatch.sh::allowed_tools_for`, the
project-profile's `## Tool allowlist` section (auto-discovered, T1),
and `.pipeline-config/config.json::dispatch.tools.<stage>[]`
(operator-curated, ENG-51). The composed `--allowed-tools` string for
a `claude -p` invocation must reflect all three.

**Decision:** Compose as `base,$profile,$extras` in left-to-right
order, with empty segments elided so no orphan commas appear in the
final argv. Claude's allowlist matcher is order-insensitive, so this
ordering is for log-readability and reasoning clarity, not
behavioral correctness.

**Consequences:**
- A reader of a per-stage transcript can identify the source of any
  granted tool by its position: the first tokens are stack-neutral
  base, the middle tokens are stack-driven profile, the trailing
  tokens are operator extras.
- A reviewer changing the case-arm base sees a focused diff (no
  Tauri specificity) and can reason about base independently of
  per-target overrides.
- The profile's authority is bounded — profile patterns can ADD to
  the allowlist but cannot remove base tokens. Same constraint as
  ENG-51's extras. The operator's recourse for over-broad base
  tokens is `--disallowed-tools` (already in use) or a case-arm
  edit (low cost, single PR).
- Operators who want a tighter dispatch can leave the profile's
  Tool allowlist mostly empty; conversely, a fully populated profile
  is the auto-discovery default. Both modes coexist.
