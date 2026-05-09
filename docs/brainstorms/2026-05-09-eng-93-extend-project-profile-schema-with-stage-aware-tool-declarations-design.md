---
linear: ENG-93
title: Extend project-profile schema with stage-aware tool declarations
date: 2026-05-09
status: draft
---

# Extend project-profile schema with stage-aware tool declarations

## 1. Overview

`learned-rules/<slug>/project-profile.md` is the single source of stack
truth that the harness emits at setup time and appends to every
non-retrospective dispatch prompt
(`bin/render-prompt.sh:141-158`). Today it carries five H2 sections
(`Stack`, `Build & test gates`, `File layout`, `Language idioms`,
`Don'ts`) — none of which declare **which executables the orchestrator
should grant in `--allowed-tools` for `claude -p`**. As a result,
`bin/dispatch.sh::allowed_tools_for` (lines 302–340) hardcodes a
Tauri-shaped base (`Bash(cargo:*)`, `Bash(bun:*)`, `Bash(rustc:*)`,
`Bash(npx:*)`, `Bash(node:*)`) and per-target extras live in
gitignored `.pipeline-config/config.json::dispatch.tools.<stage>[]`
(ENG-51). Two project surfaces (`bin/run-local-helpers.sh:11-20`
scope-allowlist override + lines 213–223 hardcoded base,
`bin/scope-check.sh:22` notable-tier heuristic) also reach for Tauri
vocabulary directly.

ENG-92's umbrella moves the data into the profile and rewires
`dispatch.sh` (T2), `run-local-helpers.sh` (T3), and `scope-check.sh`
(T4) to read it. **ENG-93 is T1 — declaration only.** This brainstorm
designs the schema extension, the discovery prompt update, the
validator change, the test-fixture matrix, and the one-time backfill
mechanism. Consumption of the new section is explicitly out-of-scope.

The load-bearing tradeoff: bumping the schema introduces a
back-compat branch in the validator and a backfill ramp for existing
profiles. The cost is a small amount of validator complexity and one
upgrade prompt the operator must answer once. The benefit is that T2
can land cleanly with a hard signal (`schema_version=2`) for "this
profile has stack-aware tool declarations" vs "fall back to the
hardcoded base."

## 2. Goal

After this ticket lands:

- The discovery prompt instructs the agent to emit a sixth section,
  `## Tool allowlist`, between `Build & test gates` and `File layout`.
- The discovery prompt declares the new schema version as `2` and
  documents how to derive Bash patterns from the build/test commands
  it already extracts (`cargo test` → `Bash(cargo:*)`).
- `_validate_project_profile_schema` accepts `schema_version: 1`
  (legacy, five sections) AND `schema_version: 2` (new, six sections
  in the new order). Anything else is rejected.
- `bin/phase-project-profile-test.sh` covers fixtures for at least
  three stack shapes — Rust+Bun (Tauri), Python+pytest, Go+go-test —
  plus a v1-still-valid fixture for back-compat and a v2-missing-section
  fixture for the rejection path.
- `phase_project_profile` (`bin/setup.sh:257-359`) detects an existing
  v1 profile on next run, injects a stub `## Tool allowlist` section
  carrying `<<NEEDS-INPUT:>>` markers, bumps `schema_version` to `2`,
  and lets the existing `_resolve_profile_markers`
  (`bin/setup-helpers.sh:168-205`) loop drive the operator through the
  upgrade.
- `learned-rules/harness/project-profile.md` is hand-upgraded to v2 in
  this PR (acceptance criterion #5; the harness-self profile is the
  one we know about and can validate against the existing
  `.pipeline-config/config.json::dispatch.tools` extras).

## 3. Non-goals

- **Consumption.** `dispatch.sh::allowed_tools_for` keeps its hardcoded
  Tauri base; `dispatch.tools.<stage>[]` extras keep being read.
  Rewiring lands in T2.
- **Removal of Tauri vocabulary** from `dispatch.sh`,
  `run-local-helpers.sh:220`, `scope-check.sh:22`. Out-of-scope per the
  issue's "Scope Boundaries / OUT" section.
- **Re-discovery on upgrade.** We do NOT re-invoke `claude -p` to
  fill in the new section for existing v1 profiles. The backfill is a
  pure marker-injection — the operator answers interactively. (See
  D-5 for the rationale.)
- **YAML-only / frontmatter-only data shape.** The Tool allowlist is
  prose-readable bulleted markdown that's grep-extractable, not a
  JSON/YAML island in the frontmatter. The profile is appended to
  prompts as prose so agents can read it (`bin/render-prompt.sh:155-157`).
- **Stage-agnostic core tools.** The new section enumerates only the
  stack-specific patterns. `Read`, `Write`, `Edit`, `Grep`, `Glob`,
  `TaskCreate`, `git` family, `bash bin/linear.sh`, `bash bin/pipeline.sh`,
  `bash bin/guards.sh`, `bash bin/slack.sh`, `bash bin/metrics.sh` stay
  hardcoded in `dispatch.sh::allowed_tools_for`'s base — they are
  invariants of the harness contract, not stack-derived.

## 4. Architectural principle

The CLAUDE.md "Per-target dispatch.tools extras (ENG-51, ENG-53 #8)"
section names a working principle: "the per-target extras come from
config.json::dispatch.tools.<stage>[] and are appended (not replaced)
so a non-Tauri target can grant `pytest`, `go test`, `bash bin/*-test.sh`,
etc., without rewriting the base." ENG-93 extends that principle in two
ways:

1. **Promote the data from gitignored per-target config to versioned
   per-slug profile.** `.pipeline-config/` is gitignored — operator
   onboarding requires manually populating it after every clone. The
   `learned-rules/<slug>/` tree is checked in. Moving the
   stack-specific patterns into the profile means a fresh clone of the
   harness self-twin already has the right allowlist; operators don't
   replicate the regen-one-liner from CLAUDE.md by hand.
2. **Single source of stack truth, single setup-time author.** ENG-49's
   stack-aware addendum (`docs/brainstorms/2026-04-27-stack-aware-prompt-addendum-design.md`)
   established that the discovery agent is the single author of stack
   context at setup time. Tool allowlist is stack context. It belongs
   in the profile, authored by the same agent that already extracts
   `cargo test` / `bun run check` / `bash bin/foo-test.sh` from CI
   workflows.

There is no `docs/VISION.md` or `docs/architecture.md` ADR section in
this repo (verified — `ls docs/` shows `architecture.md` as a runtime
narrative, not an ADR ledger; `docs/knowledge/decisions.md` does not
exist). The principle this brainstorm cites is therefore an extension
of ENG-49's stack-aware-addendum design + ENG-51's per-target-extras
design, both of which live in `docs/brainstorms/`.

## 5. Decisions

### D-1: New section is **`## Tool allowlist`**, inserted after `## Build & test gates`

**Verdict:** The schema's H2 section list grows from 5 to 6, and the
new section sits in position 3 (1=Stack, 2=Build & test gates,
3=Tool allowlist, 4=File layout, 5=Language idioms, 6=Don'ts).

**Why:** The discovery agent's instruction is "derive Bash patterns
from the Build & test gates commands." Adjacency reinforces the
derivation: an operator reading the profile sees `cargo test
--workspace` in §2 and immediately reads `Bash(cargo:*)` in §3.
Putting Tool allowlist at the end (after Don'ts) would visually
separate the data from its source.

**Rejected alternative:** Append at end (position 6, after Don'ts).
Rejected because (a) Don'ts is the natural closing section
("anti-patterns") and inserting after it forces operators to re-read
to validate the derivation; (b) it would make the v1→v2 diff three
lines longer (insert section + move Don'ts down) instead of one
(insert section, push File layout/Language idioms/Don'ts down by one
position each).

**Constraint reference:** ENG-49's stack-aware addendum design §6
defines the schema. ENG-93 is the first schema bump since v1.

### D-2: Bump `schema_version` from `1` → `2`; v1 stays valid

**Verdict:** The discovery prompt emits `schema_version: 2` going
forward. `_validate_project_profile_schema` reads the version and
branches: v1 requires the original 5 sections; v2 requires 6 sections
in the order from D-1. Any other version (`3`, `0`, missing) is
rejected with a one-line reason on stderr.

**Why:** Acceptance criterion #3 explicitly mandates this back-compat
shape: "rejects profiles missing this section UNLESS the file has the
schema_version=1 prefix (legacy back-compat)." A version bump is the
cleanest signal for downstream code (T2 `dispatch.sh` rewire) to know
which contract the profile honors. `bin/render-prompt.sh:151-153`
already tolerates `schema_version != 1` with a non-fatal warning, so
no immediate change to render-prompt is needed (the warning string
will become misleading once v2 is the default — see Edge Case E-2).

**Rejected alternative:** Keep `schema_version: 1` and make Tool
allowlist optional in v1. Rejected because (a) downstream T2 cannot
distinguish "operator hasn't upgraded" from "operator declared empty
allowlist" without an explicit version signal; (b) "valid v1 file
that happens to lack the new section" is exactly the legacy
back-compat case the issue calls out — collapsing it into a single
schema makes the validator's branching invisible.

**Rejected alternative #2:** Bump to `2` and reject v1 outright (force
re-discovery for all existing profiles). Rejected because operators
who curated v1 profiles by hand (resolved markers, edited Don'ts)
would lose work. Hard rejection of v1 also breaks the
`learned-rules/twinning/project-profile.md` profile that we don't
upgrade in this PR (it is in scope for the operator running the
backfill on next setup).

**Constraint reference:** Acceptance criterion #3.

### D-3: Tool allowlist body is a **per-stage bulleted list of code-fenced Bash patterns**

**Verdict:** The section body is one top-level bullet per
canonical-gerund stage (`brainstorming`, `planning`, `implementing`,
`ui`, `reviewing`, `qa`, `building`, `released`), each with either
the literal string `(none)` (no stage-specific extras; the
hardcoded base allowlist applies unchanged at T2 dispatch time) or
sub-bullets carrying backtick-fenced Bash patterns (extras to be
appended to the base). All eight canonical-gerund stages MUST be
present — omission is a validation error. The schema permits
sub-bullets on any stage; D-4's derivation rule decides which stages
get `(none)` vs. real entries by default.

```markdown
## Tool allowlist

Per-stage Bash patterns the orchestrator grants to `claude -p` at
dispatch. Stage-agnostic core tools (Read, Write, Edit, Grep, Glob,
TaskCreate, git family, `bash bin/linear.sh`, `bash bin/pipeline.sh`,
`bash bin/guards.sh`, `bash bin/slack.sh`, `bash bin/metrics.sh`) are
implicit and not declared here.

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
```

**Why:** Three properties:
1. **Prose-readable.** The profile is appended verbatim to dispatch
   prompts (`bin/render-prompt.sh:155-157`). Agents read it as
   documentation; an `## Tool allowlist` H2 with bullets parses as
   English to the LLM.
2. **Grep-extractable for T2.** `awk '/^## Tool allowlist/,/^## /'`
   followed by per-line scanning lets T2's parser pull the data without
   a YAML library. The `Bash(...)` pattern delimiter is unambiguous.
3. **Compact for the harness-self case.** The harness-self profile
   needs ~15 enumerated `Bash(bash bin/<test>-test.sh:*)` entries (per
   CLAUDE.md "Per-target dispatch.tools extras"). Sub-bullets stay
   under 80 chars per line; a single comma-joined line would be
   unreadable.

**Rejected alternative:** Fenced YAML block inside the section.

```yaml
implementing:
  - "Bash(cargo:*)"
```

Rejected because (a) YAML's stricter syntax (quoting rules, indent
arithmetic) raises the bar for the discovery agent and for operators
hand-upgrading; (b) the rest of the profile is bulleted markdown, so
a YAML island would be inconsistent; (c) T2 can grep-parse the bullet
form trivially — YAML is over-engineering for ~10 lines of data.

**Rejected alternative #2:** Single comma-joined line per stage:
`- implementing: \`Bash(cargo:*)\`, \`Bash(bun:*)\``. Rejected for
the harness-self case (15+ entries break readability and grep parsing
on commas embedded in patterns is fragile if a pattern ever contains
a comma — `Bash(awk:*)` doesn't but a future `Bash(foo --bar=a,b:*)`
would).

**Constraint reference:** `bin/render-prompt.sh:155-157` (profile is
appended as prose to dispatch prompts).

### D-4: Discovery prompt instructs derivation `<command>` → `Bash(<binary>:*)`

**Verdict:** `bin/setup-prompts/discovery.md` gains a new schema slot
(after `Build & test gates` in §"Schema (REQUIRED — emit exactly this
structure)") and a new sub-section in §"Confidence rules" with the
derivation contract:

> "Tool allowlist": for each stage that runs build/test/lint commands
> (implementing, ui, qa), tokenize the canonical commands in §"Build &
> test gates" by whitespace, take the first token of each, and emit
> `Bash(<token>:*)`. Drop tokens that name shell built-ins (`bash`,
> `sh`, `env`) UNLESS they invoke an allowlisted harness script under
> `bin/` (the only carve-in: `bash bin/<name>.sh` →
> `Bash(bash bin/<name>.sh:*)`, where `<name>` is a literal filename
> with no leading `-`). The carve-in does NOT extend to `bash -c`,
> `bash -l`, `bash -x`, `bash <other-path>/...`, `bash -<flag> ...`,
> or any form where the second token starts with `-` — emit
> `<<NEEDS-INPUT:>>` for those instead. Stages that don't run code
> (brainstorming, planning) emit `(none)`. The reviewing stage emits
> `(none)` UNLESS the project's lint command requires invocation under
> review (rare). The building stage emits `(none)` — building uses
> `gh` exclusively, which is in the implicit base. The released stage
> emits `(none)`. Patterns must be ASCII-only (no smart quotes, no
> trailing `\r`); the trailing `:*` is mandatory. If you cannot
> confidently tokenize a command, emit `<<NEEDS-INPUT:>>` for that
> stage.

**Why:** Acceptance criterion #2 names the derivation rule
explicitly. Tokenize-first-word + `Bash(<x>:*)` is the
lowest-cost-to-implement and matches what the harness's own existing
allowlist patterns use (`Bash(cargo:*)`, `Bash(bun:*)`,
`Bash(jq:*)`). The `bash bin/<script>:*` exception preserves the
ENG-53 "no broken wildcard `Bash(bash bin/*-test.sh:*)`" lesson —
patterns must be fully literal up to the trailing `:*`.

**Rejected alternative:** Have the discovery agent freeform-author the
list with no derivation rule. Rejected because (a) without rules, two
discovery runs on the same repo could produce different outputs;
(b) operators reviewing the profile have no contract to validate
against; (c) the issue's hint section explicitly says "instruct it
to derive tool patterns from those commands."

**Constraint reference:** Acceptance criterion #2; CLAUDE.md
"Per-target dispatch.tools extras" §"Wildcard pitfall."

### D-5: Backfill = inject `## Tool allowlist` with `<<NEEDS-INPUT:>>` markers + bump schema_version

**Verdict:** `phase_project_profile` (`bin/setup.sh:257-359`) gains a
new branch BEFORE the existing "valid file, no markers → done" branch
(line 267). **Branch ordering is load-bearing:** the new branch MUST
run before the line-267 complete check, otherwise any v1 profile that
is "complete-by-v1-standards" returns immediately and the backfill
never fires. Order matters; document the invariant in the source as
a comment.

```bash
# v1 → v2 backfill: existing valid profile, no markers, but missing
# Tool allowlist. Inject a stub section with NEEDS-INPUT markers and
# bump schema_version. The existing _resolve_profile_markers loop
# below picks up the markers and prompts the operator.
# MUST run BEFORE the line-267 "complete" check; otherwise v1 profiles
# return early and never get upgraded.
local _v
_v="$(_profile_schema_version "$profile_path" 2>/dev/null || true)"
if [[ -f "$profile_path" ]] \
   && _validate_project_profile_schema "$profile_path" 2>/dev/null \
   && ! grep -q '<<NEEDS-INPUT:' "$profile_path" \
   && [[ "$_v" == "1" ]]; then
  log "project-profile: detected v1 profile at $profile_path"
  log "project-profile: upgrading to v2 (Tool allowlist) — 3 prompts will follow"
  log "project-profile: Ctrl-C now to defer; file is NOT mutated until you continue"
  _inject_tool_allowlist_section "$profile_path"
  # fall through to marker-resolution branch (line 275)
fi
```

The `log` lines fire BEFORE `_inject_tool_allowlist_section` mutates
the file, giving the operator a clean exit (Ctrl-C leaves the v1
file untouched). Once injection commits, the file is at
`schema_version: 2` with markers; if the operator Ctrl-Cs DURING
marker resolution, E-3 covers the recovery (resume on next setup run).

`_inject_tool_allowlist_section` is a new helper in
`bin/setup-helpers.sh` that:
1. reads the existing file
2. inserts a `## Tool allowlist` section after `## Build & test gates`
   carrying one `<<NEEDS-INPUT:>>` marker per stage that typically
   has stack-specific patterns (implementing, ui, qa) plus literal
   `(none)` for the others — so the operator only answers ~3 prompts,
   not 8
3. rewrites `schema_version: 1` → `schema_version: 2` in the
   frontmatter
4. atomically replaces the file via `atomic_write_file` (already in
   `setup-helpers.sh:27-36`)

**Why:** Acceptance criterion: "One-time backfill mechanism for
existing project-profile.md files (NEEDS-INPUT marker injection on
next setup run)" — verbatim. The marker shape is what the existing
`_resolve_profile_markers` loop expects (line-anchored
`<<NEEDS-INPUT: question>>`), so the marker-resolution UX is
unchanged. Operators run `bash bin/setup.sh project-profile`, see 3
prompts, answer them, and the v2 profile is now complete.

**Rejected alternative:** Re-invoke `claude -p` for the missing
section. Rejected because (a) added complexity (a second
discovery-style dispatch); (b) the operator already has the v1
profile in front of them — they know what their build/test commands
are. The marker question is "what binaries do `cargo test --workspace`
and `bunx playwright test` invoke?" which the operator can answer in
seconds.

**Rejected alternative #2:** Hard-fail v1 profiles, force operator to
delete + re-run discovery. Rejected — see D-2 alternative #2 (data
loss on operator-curated content).

**Constraint reference:** Issue's "Scope Boundaries / IN" — backfill
is in scope.

### D-6: `_validate_project_profile_schema` reads schema_version and branches; both v1 and v2 share the same frontmatter check

**Verdict:** The validator's structure becomes:

1. Frontmatter present at top? (unchanged)
2. Read `schema_version` value (currently "is it `1`?", new:
   "extract the integer").
3. If version == 1: 5 sections in original order (unchanged).
4. If version == 2: 6 sections in new order
   (Stack, Build & test gates, Tool allowlist, File layout, Language
   idioms, Don'ts).
5. Else: reject with `unsupported schema_version: <n>`.

The current implementation uses `head -5` for section extraction; v2
uses `head -6`. Two awk programs, one switch on version.

**Why:** Single function, single signature, idempotent. Tests
exercise both branches with explicit fixtures.

**Rejected alternative:** Two separate validators
(`_validate_project_profile_schema_v1` and `_v2`) with a dispatcher.
Rejected for premature abstraction — the two branches share 80% of
the logic (frontmatter + ordered-section assertion). One function
with a `case "$version"` is shorter and the test surface is the same.

**Constraint reference:** Acceptance criterion #3 + CLAUDE.md "When
wiring a new script" §"don't roll your own" — keep the existing helper
shape; extend, don't fork.

### D-7: Validator rejects patterns containing shell metacharacters (defense at check-in time)

**Verdict:** When the v2 branch fires, after asserting the section is
present and ordered, `_validate_project_profile_schema` walks the
lines under `## Tool allowlist` (until the next `## ` heading) and
rejects the file if any line containing a backtick-fenced pattern
fails this regex:

```
^[[:space:]]*-?[[:space:]]*`Bash\([A-Za-z0-9_./[:space:]:-]+:\*\)`
```

Patterns that include `$`, backticks-inside-pattern, `;`, `&&`, `||`,
`|`, `>`, `<`, newlines, U+2018/U+2019 smart quotes, or any character
outside the regex's character class are rejected with
`pattern at line N has shell metacharacters: <line>`. Lines
matching `^- <stage>: \(none\)$` and the prose intro paragraph are
skipped by the walker.

**Why:** `learned-rules/<slug>/project-profile.md` is git-tracked and
read by `claude -p` dispatch (after T2). T2 will trust the data and
splice it into `--allowed-tools`. The defense-in-depth principle
(CLAUDE.md "When wiring a new script") says: validate at the
boundary that's closest to the data's authority. The validator runs
at setup time AND on every render-prompt invocation
(`bin/render-prompt.sh:144` calls validator-equivalent grep checks),
so rejecting malformed patterns at check-in beats letting them flow
into argv. Cost is one regex check per pattern line per validation
call — sub-millisecond.

**Rejected alternative:** Defer all pattern-shape defense to T2.
Rejected because (a) T2 is consumption — it should be allowed to
trust the validator's output; (b) a malformed v2 profile would
silently render-prompt-warn but pass validation, only failing at T2
dispatch — much later, harder to diagnose; (c) git-tracked data
needs check-in-time rejection so PR review can catch it.

**Constraint reference:** ENG-46 secret-handling discipline
(boundary validation), ENG-53 #11 wildcard-pitfall lesson
(literal-prefix matching).

### D-8: Test fixtures cover three stack shapes plus two version paths

**Verdict:** `bin/phase-project-profile-test.sh` gains five new
fixtures (in addition to the existing `GOOD_PROFILE`/`MARKED_PROFILE`/
`INVALID_PROFILE`):

1. **`V2_RUST_TAURI_PROFILE`** — full v2 with Rust+Bun (Tauri-shape)
   patterns; passes validation, drives a happy-path stub-claude run.
2. **`V2_PYTHON_PYTEST_PROFILE`** — v2 with `Bash(python:*)`,
   `Bash(pytest:*)`, `Bash(pip:*)` patterns; passes validation.
3. **`V2_GO_GOTEST_PROFILE`** — v2 with `Bash(go:*)`,
   `Bash(golangci-lint:*)`; passes validation.
4. **`V1_LEGACY_PROFILE`** — schema_version=1, 5 sections, no Tool
   allowlist; passes validation (back-compat check).
5. **`V2_MISSING_TOOL_ALLOWLIST`** — schema_version=2, 5 sections (no
   Tool allowlist); fails validation with explicit reason on stderr.

Plus a new test case for the backfill path:

6. **case-backfill-end-to-end: v1 → v2 backfill.** Pre-populate fixture from
   V1_LEGACY_PROFILE; run `phase_project_profile` with
   stub-claude removed (must NOT re-invoke discovery); supply 3
   answers on stdin (one per implementing/ui/qa marker); assert the
   resulting file has `schema_version: 2`, has the 6 sections in
   v2 order, and contains the answers under `## Tool allowlist`.

**Why:** Acceptance criterion #4 names the three stack shapes
explicitly. Cases 4 and 5 cover the validator's branching surface;
case 6 covers the backfill mechanism end-to-end.

**Rejected alternative:** Cover only the three positive stacks (skip
v1/v2 negative cases). Rejected because the validator's branching is
the load-bearing change — testing only v2 leaves the v1 back-compat
path unverified.

**Constraint reference:** Acceptance criterion #4.

## 6. Architecture (where code lives)

| Change | File | Lines (current) | Action |
|---|---|---|---|
| Schema definition | `bin/setup-prompts/discovery.md` | 30–65 | Insert `## Tool allowlist` slot after `## Build & test gates`; bump `schema_version: 1` → `schema_version: 2`; add §"Confidence rules" entry per D-4. |
| Validator branching | `bin/setup-helpers.sh::_validate_project_profile_schema` | 128–159 | Read `schema_version` value; switch on version 1 or 2; v2 uses 6-section ordered match. |
| Backfill helper | `bin/setup-helpers.sh::_inject_tool_allowlist_section` | new | Read v1 profile, splice `## Tool allowlist` after `## Build & test gates`, bump frontmatter version to 2, atomic-write back. |
| Schema-version reader | `bin/setup-helpers.sh::_profile_schema_version` | new | Tiny awk that emits the integer value of `schema_version` from frontmatter, or empty on miss. |
| Setup-phase backfill branch | `bin/setup.sh::phase_project_profile` | 266–280 | New branch BEFORE the "complete" check: detect valid v1, call `_inject_tool_allowlist_section`, fall through to marker resolution. |
| Test fixtures | `bin/phase-project-profile-test.sh` | 42–96, 130–172 | Add 5 fixtures (per D-8); add `case-backfill-end-to-end` for the v1→v2 path. Renumber surrounding cases as needed (existing case-5.4 stays at 5.4). |
| Pattern-shape gate fixture | `bin/phase-project-profile-test.sh` | new | Add `V2_BAD_PATTERN_PROFILE` covering `Bash($(curl evil):*)`, `Bash(cargo;rm:*)`, smart-quoted patterns; assert validator rejects (per D-7). |
| Harness-self profile upgrade | `learned-rules/harness/project-profile.md` | 1–52 | **Preferred path:** run the backfill flow itself (`bash bin/setup.sh project-profile` against the harness-self target) on the implementer's machine, answer the 3 prompts using the live `.pipeline-config/config.json::dispatch.tools` enumerated test list as the source of truth, and commit the resulting v2 file. This dogfoods the same UX every other operator will see, validates the backfill helper end-to-end against real data, and avoids the "hand-edit references gitignored config the implementer can't read from the worktree" hazard (A-15). **Fallback (only if backfill helper not yet implemented):** hand-edit, then verify by reading the operator's local `.pipeline-config/config.json` and copying the literal patterns. |
| (Out of scope, T2) | `bin/dispatch.sh::allowed_tools_for` | 302–340 | NOT touched in ENG-93. |
| (Out of scope, T2) | `bin/render-prompt.sh:151-153` | 151–153 | Schema_version warning string still says "schema_version != 1"; could be relaxed in T2 once v2 is consumed. Left alone here to keep the diff minimal. |

## 7. Data flow

### 7.1 Fresh setup (new operator, new project)

```
operator runs: bash bin/setup.sh project-profile
└─ phase_project_profile (setup.sh:257)
   └─ profile_path doesn't exist → fresh discovery
      └─ render discovery.md prompt (now v2 schema in template)
         └─ claude -p inspects target repo, emits v2 profile with Tool allowlist
            └─ _validate_project_profile_schema (v2 branch) passes
               └─ _resolve_profile_markers fires only if agent left markers
                  └─ profile complete at v2
```

### 7.2 Upgrade existing v1 (operator who set up before ENG-93)

```
operator runs: bash bin/setup.sh project-profile
└─ phase_project_profile
   └─ profile_path exists, valid v1, no markers
      └─ NEW: detect v1, call _inject_tool_allowlist_section
         └─ atomic_write_file rewrites profile with:
            - schema_version: 2 in frontmatter
            - "## Tool allowlist" section after "## Build & test gates"
            - "<<NEEDS-INPUT:>>" markers for implementing/ui/qa
            - "(none)" for brainstorming/planning/reviewing/building/released
      └─ fall through to "valid + has markers" branch
         └─ _resolve_profile_markers prompts operator (3 questions)
            └─ profile complete at v2
```

### 7.3 Already at v2 (ideal steady state)

```
operator runs: bash bin/setup.sh project-profile
└─ phase_project_profile
   └─ profile_path exists, valid v2, no markers
      └─ "complete" branch fires; no work
```

### 7.4 Validation failure shapes

| Profile state | Expected validator output |
|---|---|
| schema_version=1, 5 sections, original order | OK (v1 back-compat) |
| schema_version=1, has Tool allowlist injected | rejected — incidental rejection by ordered-section mismatch: v1 branch's `head -5` of `^## ` lines now reads `Stack \| Build & test gates \| Tool allowlist \| File layout \| Language idioms \|` (Don'ts pushed off the end), which fails the v1 expected-section equality. The validator does not have a separate "v1 must NOT have Tool allowlist" rule; the rejection emerges from the ordered-section invariant. |
| schema_version=2, 6 sections, new order | OK |
| schema_version=2, 5 sections (no Tool allowlist) | rejected: `_validate_project_profile_schema: schema_version=2 but missing ## Tool allowlist` |
| schema_version=2, 6 sections, malformed pattern (e.g., `Bash($(curl evil):*)`) | rejected: `_validate_project_profile_schema: pattern at line N has shell metacharacters` (per D-7) |
| schema_version=3 | rejected: `_validate_project_profile_schema: unsupported schema_version: 3` |
| schema_version missing | rejected: `_validate_project_profile_schema: schema_version missing` |

## 8. Error handling

- **Validator** keeps the existing one-line-on-stderr-then-rc=1
  contract. New error strings are namespaced
  (`schema_version=2 but missing ## Tool allowlist`,
  `unsupported schema_version: <n>`).
- **`_inject_tool_allowlist_section`** uses `atomic_write_file` so a
  partial-failure leaves the original v1 profile intact. If the
  injection awk fails (e.g., no `## Build & test gates` heading
  found — should never happen for a v1 profile that passed validation,
  but defensive), the helper returns rc=1 and the caller
  (`phase_project_profile`) emits a `die` with the underlying reason.
- **`_resolve_profile_markers`** is unchanged. If the operator hits 3
  consecutive blank answers, the existing rc=1 + abort path fires.
  The half-upgraded file at this point has `schema_version: 2` AND
  `<<NEEDS-INPUT:>>` markers, so subsequent setup runs see
  "v2-with-markers" and re-enter the marker-resolution loop without
  re-injecting.
- **`render-prompt.sh::append_project_profile`** at line 151–153
  emits a non-fatal warning when `schema_version != 1`. After ENG-93,
  every fresh-discovery profile is v2, so the warning fires on every
  dispatch — informational, non-fatal, no behavior change. The fix
  (relax the regex to accept `1` or `2`) is consumption-side and
  **deferred to T2** per the issue's scope-OUT clause. Operators
  will see the warning in transcripts during the T1→T2 window;
  document this in the PR description.

## 9. Edge cases

### E-1: Operator hand-edits a v1 profile to add `## Tool allowlist` without bumping version

**Behavior:** Validator's v1 branch checks for exactly 5 sections via
`head -5`. A 6th section after Don'ts wouldn't trip the check. A 6th
section between Build & test gates and File layout would push File
layout out of position 3, failing the v1 ordered-match.

**Mitigation:** Document in CLAUDE.md "When wiring a new script" or
in the discovery prompt: "to add Tool allowlist to an existing v1
profile, bump schema_version to 2 AND insert the section in v2 order.
Or simpler: re-run `bash bin/setup.sh project-profile` and let the
backfill do it." We won't add a runtime detector for "v1 with extra
section" — the validator's strict ordered-match catches the in-between
case (6th section in the wrong slot fails validation).

### E-2: `render-prompt.sh:151-153` "schema_version != 1, continuing" warning becomes noisy after ENG-93

**Behavior:** Line 151 grep is `^schema_version:[[:space:]]+1[[:space:]]*$`.
For v2 profiles, the warning fires on every dispatch — once per agent
run. The warning is informational and non-fatal; the dispatch path
is unchanged.

**Decision: defer to T2.** The issue's "Scope Boundaries / OUT" list
groups all consumption-side changes (anything that reads / branches
on the new section, including the version-aware warning regex) under
T2. Relaxing the regex in this PR would smuggle in consumption-side
behavior under a declaration-only banner. Accept the per-dispatch
warning during the T1→T2 window; document it in the PR description
so reviewers don't read it as a regression. The fix in T2 is a
one-line regex relaxation.

### E-3: Operator re-runs `bash bin/setup.sh project-profile` after backfill but mid-marker-resolution (Ctrl-C'd)

**Behavior:** File is at `schema_version: 2` with `<<NEEDS-INPUT:>>`
markers. `phase_project_profile` re-enters: validator passes (v2 with
6 sections is structurally valid even with markers), the
"valid + has markers" branch (`bin/setup.sh:275`) fires and runs
`_resolve_profile_markers` again. **No re-injection** — the new
backfill branch's `_profile_schema_version == "1"` guard is `2`, so
the branch is skipped. Operator answers the remaining markers. ✓

### E-4: Backfill on a profile that doesn't have `## Build & test gates` (corrupt v1)

**Behavior:** `_inject_tool_allowlist_section` would fail to locate
the insertion anchor. Defensive: emit rc=1 with
`could not locate '## Build & test gates' in <path>; profile may be
corrupt — run discovery to rebuild`. `phase_project_profile`
propagates as `die`. Operator deletes the profile and re-runs.

### E-5: Discovery agent emits Tool allowlist with malformed patterns (e.g., `Bash(cargo)` missing `:*`)

**Behavior:** ENG-93 doesn't validate pattern shape — that's a T2
concern. The validator only checks structure (section presence,
ordering). T2's parser will fail closed (skip malformed entries) per
the existing `dispatch.sh:_dispatch_tools_extras` defensive pattern
(line 296 — `select(type == "string")`).

**Decision:** Out-of-scope for ENG-93. Document in the discovery prompt
the canonical pattern shape (`Bash(<binary>:*)` or
`Bash(bash bin/<script>:*)`) so the agent emits the right shape; rely
on T2's parser for runtime defense.

### E-6: `learned-rules/twinning/project-profile.md` (the second checked-in profile) stays at v1 after this PR lands

**Behavior:** twinning is the second-known slug catalog (the upstream
target). We don't hand-upgrade it in this PR (acceptance criterion
#5 names only harness-self). Next time anyone runs
`bash bin/setup.sh project-profile` with `TARGET_REPO=<twinning>`,
the backfill branch fires and generates the v2 upgrade interactively.
✓ This is the expected path for any non-harness-self target.

### E-7: A multi-line NEEDS-INPUT marker in the injected backfill

**Behavior:** `_resolve_profile_markers` (`bin/setup-helpers.sh:177`)
reads line-by-line and matches `*<<NEEDS-INPUT:*` on a single line.
Our injected markers are single-line per stage. ✓ No multi-line
marker handling needed.

## 10. Open questions

1. **Should the discovery agent emit `Bash(jq:*)` and `Bash(awk:*)` in
   the Tool allowlist, or are those implicit base?** Current
   `dispatch.sh::allowed_tools_for` includes them in the implementing
   / ui / qa hardcoded base. They're not really stack-specific (jq is
   a JSON tool, awk is a text tool). **Proposed answer:** keep them
   implicit (in the hardcoded base), do NOT have discovery emit them.
   The Tool allowlist is for stack-derived patterns only. Document
   this in the discovery prompt's stage-agnostic-implicit list.

2. **Does the building stage ever need stack-specific patterns?**
   Today the hardcoded base for building is `gh` (PR ops) plus
   `git fetch/clone/rebase` and `mktemp`/`jq`. No stack-specific
   binaries. **Proposed answer:** the schema permits `building` to
   carry sub-bullets, but the discovery agent's derivation rule
   (D-4) emits `(none)` by default for building. If a future stack
   needs a build-stage extra (e.g., a target that runs `bun install`
   pre-merge), the operator hand-edits the section.

3. **Should we emit `Bash(<command_runner>:*)` for command runners
   like `make`, `just`, `task`?** A target with `Makefile` → runs
   `make test` → would need `Bash(make:*)`. **Proposed answer:** yes,
   covered by D-4's tokenize-first-word rule. Document an explicit
   example in the discovery prompt: `make test` → `Bash(make:*)`. **No
   additional fixture** — acceptance criterion #4 names exactly three
   stacks (Rust+Bun, Python+pytest, Go+go-test), and tokenize-rule
   coverage is exercised by D-4's prompt unit, not by another fixture
   parade.

4. **`released` stage reads from `git describe`, `gh release view`,
   etc. — same set as building. Confirm nothing stack-specific?**
   **Proposed answer:** yes, `(none)` for released across all
   stacks. The release stage is intentionally stack-neutral (it
   reads release metadata; it doesn't compile or test).

## 11. Anti-bias self-check

### 11.1 ADR stress test

- **ENG-49 (stack-aware addendum, schema_version 1 spec):** ENG-93
  bumps the schema version. ENG-49's design says "v1 schema is
  load-bearing; missing or marker-bearing profiles fail render with a
  clear error" — this remains true for both v1 and v2. ENG-93 extends
  the schema; it does not contradict ENG-49.
- **ENG-51 (per-target dispatch.tools extras in `.pipeline-config`):**
  ENG-93 does NOT remove the `.pipeline-config/config.json::dispatch.tools[]`
  path — that removal is T2. After this PR, BOTH paths exist:
  hardcoded base + gitignored extras (current). Operators can opt into
  the v2 profile path by re-running setup; no behavior change at
  dispatch time. **No ADR conflict.**
- **CLAUDE.md "Per-target dispatch.tools extras" §"Wildcard pitfall":**
  The lesson "patterns must be fully literal up to the trailing `:*`"
  is encoded into the discovery prompt (D-4). **Reinforces, doesn't
  contradict.**
- **ENG-23 (rename REPO_ROOT → HARNESS_ROOT):** This ticket touches
  `learned-rules/<slug>/project-profile.md` paths via `HARNESS_ROOT`,
  not `REPO_ROOT`. ✓
- **ENG-46 (secret-handling lint):** No `${VAR:-FALLBACK}` constructs
  added. The injection helper uses `atomic_write_file`. ✓

### 11.2 Simpler alternative for every major decision

Logged inline under each Decision (D-1 through D-8).

### 11.3 Assumption inventory

| # | Assumption | Status | Verification |
|---|---|---|---|
| A-1 | `bin/setup-prompts/discovery.md` is the source of the discovery prompt template | verified | Read at lines 1–76; schema is at lines 30–65. |
| A-2 | `_validate_project_profile_schema` lives in `bin/setup-helpers.sh:128-159` | verified | Read; current shape uses awk for frontmatter, grep -E + head -5 + tr for sections. |
| A-3 | `_resolve_profile_markers` reads line-by-line and matches `*<<NEEDS-INPUT:*` | verified | `bin/setup-helpers.sh:168-205`. |
| A-4 | `phase_project_profile` has the branch shape "valid + no markers → done; valid + markers → resolve; else fresh discovery" | verified | `bin/setup.sh:267-280`. |
| A-5 | `bin/render-prompt.sh::append_project_profile` appends profile prose to all non-retrospective stages and warns (non-fatal) on `schema_version != 1` | verified | Lines 133–158, esp. 151–153. |
| A-6 | `dispatch.sh::allowed_tools_for` hardcodes a Tauri-shaped base for each stage | verified | Lines 302–340. |
| A-7 | `dispatch.sh::_dispatch_tools_extras` reads `.dispatch.tools.<stage>[]` from `$CONFIG` and silently drops non-strings | verified | Lines 291–300. |
| A-8 | `bin/phase-project-profile-test.sh` tests 5.1–5.4 cover happy/skip/marker/invalid paths | verified | Lines 130–172. |
| A-9 | `learned-rules/harness/project-profile.md` is a v1 schema with the 5 H2 sections | verified | Read; line 5 = `schema_version: 1`; all 5 sections present. |
| A-10 | `learned-rules/twinning/project-profile.md` is also v1 (we don't upgrade in this PR) | verified | Read; line 5 = `schema_version: 1`. |
| A-11 | `bin/run-local-helpers.sh::_scope_allowlist_override` exists but is out-of-scope (T3) | verified | Lines 11–20. |
| A-12 | `bin/scope-check.sh:22` carries Tauri vocabulary (`crates`, `src-tauri`) but is out-of-scope (T4) | verified | Read line 22. |
| A-13 | The discovery prompt is rendered by `_render_discovery_prompt` and substitutes `{learned_rules_dir}`, `{slug}`, `{date}`, `{target_repo_path}` only | verified | `bin/setup-helpers.sh:211-220`. |
| A-14 | `atomic_write_file` is available in setup-helpers.sh for safe in-place rewrites | verified | Lines 27–36. |
| A-15 | The harness-self target's `.pipeline-config/config.json::dispatch.tools.implementing[]` already enumerates ~15 `Bash(bash bin/<test>-test.sh:*)` patterns | assumed | CLAUDE.md "Per-target dispatch.tools extras" §, lines 260–308 documents this is required and references the regen one-liner. We trust the docstring; the actual file is gitignored and we cannot read it from the worktree. **Validation step at implementation time:** the implementer should `cat $TARGET_REPO/.pipeline-config/config.json` and copy the literal list into the upgraded `learned-rules/harness/project-profile.md` to keep behavior identical. |
| A-16 | `bin/render-prompt.sh:151` regex `^schema_version:[[:space:]]+1[[:space:]]*$` is the only consumer that ties to a specific version | verified | grep across `bin/` shows two consumers: `setup-helpers.sh:146,148` (validator we're updating) and `render-prompt.sh:151-152` (E-2). No other version pin. |
| A-17 | `docs/knowledge/decisions.md` does not exist | verified | `ls docs/knowledge/` returns nothing (the directory itself doesn't exist). No ADR ledger to append to; this brainstorm IS the proposed ADR. |
| A-18 | The Linear issue's "schema_version=1 prefix (legacy back-compat)" wording means "v1 stays valid without the new section" rather than "the literal text 'schema_version=1' anywhere in the file" | assumed | Most plausible reading; alternative reading would be a non-sense check. **Validation step:** if the implementer reads it differently, halt and confirm with the operator before coding. |

### 11.4 Codebase-fact verification

Every named function, file, line range, and helper referenced above
has been opened and quoted by `path:line` in the Assumption Inventory
table. The implementation surfaces are exactly five files:
`bin/setup-prompts/discovery.md`, `bin/setup-helpers.sh`,
`bin/setup.sh`, `bin/phase-project-profile-test.sh`, and
`learned-rules/harness/project-profile.md`. `render-prompt.sh:151`
is **deferred to T2** per the scope decision in §9 E-2.

## 12. Scope flags

- **In-scope (per Linear issue):** schema extension, validator update
  (including the D-7 pattern-shape gate as defense-in-depth at
  check-in time), test fixtures (3 stacks plus version-negative and
  pattern-shape-negative cases), backfill helper, harness-self
  profile upgrade.
- **Explicitly out-of-scope (T2 / T3 / T4):** `dispatch.sh` rewire,
  `bin/render-prompt.sh:151-153` schema_version warning regex
  relaxation (E-2), `run-local-helpers.sh:11-20` /
  `:213-223` Tauri-shaped allowlist rewire, `scope-check.sh:22`
  notable-tier Tauri vocabulary cleanup, removal of the gitignored
  `.pipeline-config/config.json::dispatch.tools[]` path.
- **Operational status (not design questions):** ENG-93 is the first
  ENG-92 child. T2 / T3 / T4 are blocked-by ENG-93 by data
  dependency; their sequencing is the operator's call, not the
  implementer's.

## 13. ADR note

`docs/knowledge/decisions.md` does not exist in this repo (verified —
A-17). No standalone ADR is created in this PR; the canonical record
of the decision is this brainstorm itself plus the §11.1 ADR stress
test. If a future ticket establishes the decisions ledger, this
brainstorm's `linear: ENG-93` frontmatter is the natural backreference.

## 14. Persona review

Run order: design → security → scope → coherence → product →
feasibility. Feasibility runs last as the gating persona
(codebase-fact errors are P0 by definition). Two iterations were
required; iteration 2 cleared the gate.

| Persona | Iter 1 | Iter 2 | Notes |
|---|---|---|---|
| design | PASS (P0=0, P1=3, P2=3) | — | P1s addressed: D-3 `(none)` semantics made explicit; D-5 backfill UX hardened with pre-mutation log + Ctrl-C escape; E-2 contradiction collapsed to a clean defer-to-T2. |
| security | PASS (P0=0, P1=2, P2=3) | PASS (P0=0, P1=0) | P1s addressed: D-4 tokenize rule tightened with explicit `bash` carve-in / carve-out (rejects `bash -c`, `bash <other-path>`, second-token-starts-with-`-`, etc.); new D-7 adds a check-in-time validator regex rejecting shell metacharacters in patterns, with a `V2_BAD_PATTERN_PROFILE` fixture. |
| scope | FAIL (P0=1, P1=2, P2=2) | PASS (P0=0, P1=0) | P0 addressed: E-2 (`render-prompt.sh:151` regex relaxation) firmly deferred to T2 across §6, §8, §9, §11.4, §12 — no smuggle. P1s addressed: Q3 fixture-parade creep pruned (no `V2_MAKE_PROFILE`); Q5 PM-chatter removed. §13 ADR section trimmed to a brief note. |
| coherence | PASS (P0=0, P1=4, P2=3) | — | P1s addressed: D-5 pseudocode bash syntax fixed to use `[[ "$(_profile_schema_version "$path")" == "1" ]]`; three-way E-2 contradiction collapsed; §7.4 v1+TolAllowlist rejection made explicit (incidental ordered-section mismatch); branch-ordering invariant documented as load-bearing. |
| product | PASS (P0=0, P1=3, P2=3) | — | P1s addressed: D-5 backfill logs + Ctrl-C escape BEFORE mutating; §6 harness-self upgrade row recommends dogfooding the backfill helper (Preferred path) over blind hand-edit (Fallback); Q5 sequencing chatter moved to §12. |
| feasibility | PASS (P0=0, P1=1, P2=2) | PASS (P0=0, P1=0, P2=0) | Iter 1 P1 (A-15 self-flagged unverifiable claim) mitigated by Iter 2 §6 dogfooding recommendation. All codebase facts re-verified post-iter-2 edits: D-7 awk+regex shape consistent with existing validator at `setup-helpers.sh:128-159`; `case-5.1`–`case-5.4` confirmed at `phase-project-profile-test.sh:130-172`; heredoc fixture pattern confirmed at lines 42-96; `_scope_allowlist_override` confirmed at `run-local-helpers.sh:11-20`. |

**Final tally:** 6/6 PASS, feasibility P0=0. Proceed to planning.
