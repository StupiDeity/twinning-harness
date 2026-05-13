---
linear: ENG-97
title: Strip Tauri-specific examples from AGENT_PROMPTS.md
date: 2026-05-13
status: draft
umbrella: ENG-92
---

# ENG-97 — Strip Tauri-specific examples from AGENT_PROMPTS.md, replace with stack-agnostic guidance

## 1. Overview

`AGENT_PROMPTS.md` still carries Tauri-specific code shapes in several
stage prompts even though the project-profile addendum
(`learned-rules/<slug>/project-profile.md`) is now appended to every
non-retrospective dispatch by
`bin/render-prompt.sh::append_project_profile`
(`bin/render-prompt.sh:184-210`). The profile already names the target's
Stack, File layout, Build & test gates, Tool allowlist, and Language
idioms — so the hardcoded Tauri examples are both **redundant** (for
Tauri targets the profile says the same thing) and **misleading** (for
non-Tauri targets the prompt's primary illustration contradicts what the
agent's own profile addendum says).

Concrete residues to remove (verified by Grep against the current
worktree at the lines below — see Assumption inventory):

| Loc | Token to strip |
|---|---|
| `AGENT_PROMPTS.md:458` | "Tauri v2 + TypeScript for a compiled-IPC stack" in prose |
| `AGENT_PROMPTS.md:461` | `# === Example 1 — Tauri v2 + TypeScript (compiled-IPC stack) ===` header |
| `AGENT_PROMPTS.md:464` | `#[tauri::command]` attribute on the Rust signature |
| `AGENT_PROMPTS.md:782` | `` `invoke("cmd_x", …)` on Tauri stacks `` parenthetical |
| `AGENT_PROMPTS.md:1134` | "Tauri command, REST handler, RPC method" enumeration |
| `AGENT_PROMPTS.md:1162` | `cargo test -- --list for Rust` example |
| `AGENT_PROMPTS.md:1406` | `tauri.conf.json` in the config-file scan list |
| `AGENT_PROMPTS.md:1604–1605` | `Tauri tracks both \`package.json\` and \`src-tauri/Cargo.toml\`` dual-manifest example |
| `AGENT_PROMPTS.md:1724` | `src-tauri/src/` in the §9 human-override scan path list |

ENG-97 is the prompt-side complement to its sibling de-Tauri-ing tickets
(ENG-94 for `dispatch.sh`'s tool allowlist, already landed at
`343457c`; ENG-95 for `run-local-helpers.sh::stage_output_paths`,
in flight). All three drop hardcoded `Tauri`-shape tokens from the
orchestrator-base and route through the profile.

**Load-bearing tradeoff.** Every concrete example we keep in
`AGENT_PROMPTS.md` is replayed in the prompt for every dispatch (~9
stages × ticks × every issue), so the cheapest change is "drop, point
at profile, don't replace." But the api-contract block (lines 460–495)
is special: its purpose is to communicate the **shape** of a contract
block to readers of the prompt itself (operators, the retrospective
agent, anyone editing the file). A reader without profile context
needs *one* concrete shape to anchor the abstraction. The plan therefore
**keeps two illustrative examples in the api-contract block** (one
compiled-IPC, one REST), both stack-neutral; the seven smaller
references are converted to one-line profile-driven phrasing without a
replacement example.

## 2. Goal

After ENG-97 lands:

- `grep -nE 'Tauri|tauri\.conf\.json|src-tauri/|cargo test -- --list|invoke\(' AGENT_PROMPTS.md`
  returns **zero** matches. (AC#1 from the Linear issue.)
- The api-contract block at `AGENT_PROMPTS.md:457–497` still illustrates
  two contrasting stack shapes — one compiled-IPC, one HTTP-handler —
  with neither naming Tauri. (AC#3.)
- `bin/agent-prompts-content-test.sh` carries assertions that
  **fail loudly** if any of those five tokens reappears, and the
  former positive Tauri assertion at lines 121-125 has been
  inverted to a negative. (AC#2.)
- `bin/render-prompt-test.sh` continues to pass — the §2 column-0
  fence count stays exactly 2, indentation of the indented
  api-contract fence is preserved. (AC#4.)

## 3. Architectural principle

This work extends the **profile-as-source-of-truth** principle ENG-49
established and ENG-52 began the prompt-side rollout of (verified at
`docs/brainstorms/2026-05-02-eng-52-tauri-assumption-residue-cleanup-post-eng-49-design.md:56-72`):
documentation strings should attribute work and shape to the actual
current owner of that knowledge. The mechanism — `append_project_profile`
running on every non-retrospective dispatch — is already in place. ENG-97
removes the residual prose that contradicts it.

The harness has no `docs/VISION.md` or formal ADR registry (verified:
`ls docs/` returns `architecture.md assumptions.md brainstorms/ ...`
with no `VISION.md` or `knowledge/decisions.md`). The governing
constraints come from CLAUDE.md, `docs/architecture.md`, and the per-slug
`learned-rules/<slug>/project-profile.md` Stack section. The principle
this brainstorm invokes is therefore an **extension** of ENG-49's
profile-as-source-of-truth, not a re-statement of an existing principle.

This ticket is also the explicit precondition the umbrella ENG-92
("de-Tauri the harness — drive tool allowlist, scope rules, and prompts
from the profile") names for the prompt surface; T1/T2/T3/T4 of the
umbrella covered schema + dispatch + scope, T5 (this ticket) covers
prompts.

## 4. Decisions

Each decision has the form **D-N: \<verdict\>** + Why + rejected
alternatives. All decisions reference a concrete `path:line` in either
the current code/prompts or a predecessor brainstorm.

### D-1: api-contract Example 1 becomes "gRPC + protobuf" (compiled-IPC, non-Tauri)

**Verdict.** In `AGENT_PROMPTS.md:457–495`, replace Example 1 (Tauri v2
+ TypeScript, lines 461–476) with a gRPC + protobuf example. The fenced
block stays a single indented \`\`\`api-contract\`\`\` (column-4
fences, not column-0), preserving the §2 column-0 fence count of 2
enforced at `bin/agent-prompts-content-test.sh:184-190` and at
`bin/render-prompt.sh:111` (the `die` when section fence count != 2).
Keep Example 2 (Python/Flask + TypeScript) verbatim.

Concretely, lines 460–476 become:

```
    ```api-contract
    # === Example 1 — gRPC + protobuf (compiled-IPC stack) ===

    # Backend service definition (.proto, path per the profile's File layout)
    service FooService {
      rpc GetFoo (FooRequest) returns (FooResponse);
    }
    message FooRequest  { int64 x = 1; string y = 2; }
    message FooResponse { string id = 1; repeated FooItem items = 2; }
    message FooItem     { string name = 1; double score = 2; }

    # Frontend types (generated from .proto via the profile's codegen toolchain)
    export type FooResponse = { id: string; items: FooItem[] };
    export type FooItem     = { name: string; score: number };
```

Update the intro prose at `AGENT_PROMPTS.md:458` to:

> "Render the contract per the project profile addendum's Stack section
> — that names the canonical handler/type/codegen idioms for your stack.
> Below are two illustrative shapes (one compiled-IPC, one HTTP-handler)
> under a `Choose your stack:` heading; adapt to your profile."

Add a `Choose your stack:` heading line inside the fenced block before
Example 1 (the heading is informational text, not a markdown header, so
no fence accounting is affected).

**Why.**
- AC#1 forbids any `Tauri` / `src-tauri/` / `invoke(` substring.
  Keeping the compiled-IPC example requires a non-Tauri compiled-IPC
  representative; gRPC is the canonical option.
- gRPC + protobuf genuinely contrasts with REST (schema-first codegen
  on both sides vs handler-first decorators) so the pedagogical value
  of two examples is preserved (per the issue's AC#3 "two-example
  illustration covering at least one compiled-IPC and one REST/RPC
  stack" branch and the Technical Hints' "pair of mini-examples (one
  IPC, one REST) under a `Choose your stack:` heading" framing).
- The block remains a single indented column-4 fence pair, so §2 keeps
  exactly 2 column-0 fences. Verified at
  `bin/render-prompt.sh:86-126::extract_block` (the awk requires exactly
  two column-0 fences per section). The fence indentation matters:
  `bin/agent-prompts-content-test.sh:184` greps `^\`\`\`` and counts;
  indented fences are filtered out by the leading-anchor.

**Rejected alternative — keep Example 1 but rebrand it as
"compiled-IPC pseudocode" with `#[command]` (no `tauri::` prefix).**
The `#[command]` shape is *almost* unique to Tauri-style frameworks;
operators familiar with the harness today would still infer "this is
Tauri reskinned." gRPC is unambiguously a different mechanism. Rejected.

**Rejected alternative — drop Example 1 entirely; keep only Example 2
(REST).** Cheapest in prompt tokens, and the dispatched plan agent has
the profile addendum so it can render its own shape from prose alone.
But the human reader of `AGENT_PROMPTS.md` (operators, retrospective
agent, future editors) does NOT have profile context bound — the
ENG-52 brainstorm's D-1 already argued this point (verified at
`docs/brainstorms/2026-05-02-eng-52-tauri-assumption-residue-cleanup-post-eng-49-design.md:117-127`).
The second concrete example preserves discrimination between two
architectural shapes for the human reader. Rejected.

**Rejected alternative — JSON-RPC over WebSocket as the compiled-IPC
representative.** JSON-RPC is wire-typed but not codegen-driven; the
"compiled" framing in the original Tauri example was specifically about
shared schemas with code-gen. gRPC fits that frame; JSON-RPC blurs it.
Rejected.

### D-2: §3 (line 782) — drop the `invoke(...)` parenthetical, route through the profile

**Verdict.** Rewrite the parenthetical at `AGENT_PROMPTS.md:782` from:

> "For every frontend call (e.g. `invoke("cmd_x", …)` on Tauri stacks,
> `fetch("/api/foo")` on REST stacks) you are about to write…"

to:

> "For every frontend→backend call (the canonical client-call idiom for
> your stack is named in the Project profile addendum's Stack /
> Language idioms section) you are about to write…"

**Why.** AC#1 forbids any `invoke(` substring. The parenthetical was a
hint; the hint is already in the profile. Generic phrasing keeps the
"check that the handler exists" instruction intact without nailing
either stack as the default.

**Rejected alternative — keep the REST illustration alone
(`fetch("/api/foo")`).** Asymmetric: would imply REST is the new
default, the exact bias ENG-97 is trying to remove. Rejected.

### D-3: §6 (line 1134) — replace the Tauri/REST/RPC enumeration with profile-driven phrasing

**Verdict.** At `AGENT_PROMPTS.md:1134` change:

> "- a new FE↔BE handler / endpoint (e.g. Tauri command, REST handler,
> RPC method),"

to:

> "- a new FE↔BE handler / endpoint (the profile names the
> handler-attribute or route-binding shape for your stack),"

**Why.** AC#1 forbids `Tauri`. The enumeration was illustrative only;
the bullet's actual semantic ("new FE↔BE handler / endpoint") is
unchanged.

**Rejected alternative — replace `Tauri command` with `gRPC service
method` (parallel to D-1).** Adds prompt-token cost without
discrimination — the bullet's purpose is to define "what counts as a
new code path", not to enumerate every IPC mechanism. Generic phrasing
is correct here. Rejected.

### D-4: §6 (line 1162) — drop `cargo test -- --list for Rust`, route through profile

**Verdict.** At `AGENT_PROMPTS.md:1162` change:

> "For every new code path identified above, grep the test tree (use the
> discovery tools appropriate to the profile's stack — e.g. `cargo test
> -- --list` for Rust, test-file globbing per the profile's File
> layout) for…"

to:

> "For every new code path identified above, grep the test tree (use the
> stack's test-discovery idiom — the profile's `Build & test gates`
> section names the canonical command, and File layout names the
> test-file roots) for…"

**Why.** AC#1 forbids `cargo test -- --list`. The Rust hint was
illustrative; the profile already names the actual test command at
`learned-rules/<slug>/project-profile.md::## Build & test gates`
(verified at `learned-rules/harness/project-profile.md:14-19` for the
harness target).

**Rejected alternative — replace `cargo test -- --list` with `pytest
--collect-only` (Python parallel).** Same trap as D-3 — picks a new
default. Generic phrasing is correct. Rejected.

### D-5: §7 (line 1406) — drop `tauri.conf.json` from the config-file scan list

**Verdict.** At `AGENT_PROMPTS.md:1406` change:

> "...include `next.config.js`, `Caddyfile`, `nginx.conf`,
> `tauri.conf.json`, `pyproject.toml`, `go.mod`..."

to:

> "...include `next.config.js`, `Caddyfile`, `nginx.conf`,
> `pyproject.toml`, `go.mod`..."

(simply drop the `, \`tauri.conf.json\`` entry; the surrounding list is
already stack-neutral after ENG-52.)

**Why.** AC#1 forbids `tauri.conf.json`. The remaining list is
illustrative ("examples include …"), and the surrounding prose at
`AGENT_PROMPTS.md:1405` already qualifies it as profile-driven ("any
change to runtime configuration files named in the profile"). The
existing positive assertion at
`bin/agent-prompts-content-test.sh:158-164` only locks `pyproject.toml`
and `go.mod` (not `tauri.conf.json`), so this drop does not break
existing tests.

**Rejected alternative — replace `tauri.conf.json` with another
desktop-shell config (e.g. `electron-builder.yml`).** Same default-picking
trap. The prose's "examples include" framing is sufficient; no
replacement needed. Rejected.

### D-6: §8 (lines 1604–1605) — replace the Tauri dual-manifest example

**Verdict.** At `AGENT_PROMPTS.md:1603-1607` change:

> "- Some stacks track version in multiple manifests (e.g. Tauri tracks
> both `package.json` and `src-tauri/Cargo.toml`). Check whether the
> secondary manifests named in the Project profile addendum match
> {version}."

to:

> "- Some stacks track version in multiple manifests (e.g. a workspace
> + per-package manifest pair: a top-level `package.json` plus a
> sub-crate / sub-package manifest, or a monorepo root + child
> manifests). The Project profile addendum names the canonical and
> secondary manifests for this target; check whether the secondary
> manifests match {version}."

**Why.** AC#1 forbids `src-tauri/`. The dual-manifest *pattern* is real
and worth illustrating (semantic-release typically updates one canonical
file; secondary manifests drift). Replacing the Tauri-specific
illustration with the generic monorepo/workspace pattern preserves the
useful warning without picking a default stack.

**Rejected alternative — drop the example entirely; just say
"the profile names the manifests".** Loses the cue for *why* this audit
matters (semantic-release single-file behavior). The generic example is
~one extra line of prompt for a real failure mode. Rejected.

**Rejected alternative — replace Tauri with another concrete dual-
manifest stack (e.g., a Cargo workspace + bun monorepo).** Same default-
picking trap. Pattern-level phrasing is correct. Rejected.

### D-7: §9 (line 1724) — replace the `src-tauri/src/` hardcoded path

**Verdict.** At `AGENT_PROMPTS.md:1722-1725` change:

> "5. **Human-override analysis:**
>    - For each file under `docs/brainstorms/`, `docs/plans/`,
>    `crates/*/`, `src/`, and `src-tauri/src/` modified by a human
>    commit AFTER a bot commit on the same file…"

to:

> "5. **Human-override analysis:**
>    - For each file under `docs/brainstorms/`, `docs/plans/`, and the
>    code-bearing directories named in the Project profile addendum's
>    File layout, modified by a human commit AFTER a bot commit on the
>    same file…"

**Why.** AC#1 forbids `src-tauri/`. The retrospective agent receives
the profile addendum like every other non-retrospective stage —
**WAIT.** Verified at `bin/render-prompt.sh:187-190`:
`append_project_profile` SKIPS for `stage="retrospective"`. So the
retrospective stage does NOT receive the profile in its rendered prompt.

This makes D-7 more nuanced: the retrospective is exactly the stage
where the profile addendum is NOT bound, so "named in the profile
addendum" is a confusing self-reference. Adjusted phrasing:

> "5. **Human-override analysis:**
>    - For each file under `docs/brainstorms/`, `docs/plans/`, and the
>    code-bearing directories declared in the per-target
>    `learned-rules/<slug>/project-profile.md::## File layout` section,
>    modified by a human commit AFTER a bot commit…"

The retrospective is cross-slug (verified at `bin/render-prompt.sh:187`
and `learned-rules/twinning/` having multiple slug subdirs — though
`learned-rules/twinning` is a per-target placeholder here, see ENG-52
D-6 for the explanation), so naming the file path explicitly (not "the
profile addendum") is the correct hand-off. The retrospective agent can
read the profile file directly from disk via its `Read` tool — it just
doesn't get the auto-appended addendum.

**Why.** AC#1; explicit retrospective-stage carve-out per
`bin/render-prompt.sh:187-190`.

**Rejected alternative — list canonical paths the harness assumes
(`src/`, `crates/`, `app/`, `pkg/`).** No such canonical set exists;
projects vary, that's exactly what the profile encodes. Hardcoding a
union set re-introduces the same bias ENG-97 is removing. Rejected.

**Rejected alternative — drop the human-override scan section
entirely.** Out of scope for ENG-97 — the section is a real
retrospective feature, not Tauri residue. Rejected as scope creep.

### D-8: bin/agent-prompts-content-test.sh — invert §2 Tauri assertion, add global negative grep

**Verdict.** Two changes in `bin/agent-prompts-content-test.sh`:

1. **Invert** the §2 Tauri-positive assertion at
   `bin/agent-prompts-content-test.sh:120-130`. Before: "§2 preserves
   Tauri api-contract example (`#[tauri::command]`)". After:
   "§2 lacks Tauri api-contract example (post-ENG-97, gRPC replaces
   Tauri as the compiled-IPC representative)". The existing
   `@app.route` positive assertion at lines 126-130 stays.

2. **Add a new global negative-grep assertion** that scans the entire
   `AGENT_PROMPTS.md` (not just any section) for the five forbidden
   tokens enumerated in AC#1: `Tauri`, `tauri.conf.json`, `src-tauri/`,
   `cargo test -- --list`, `invoke(`. Any match is a `nope`. The grep
   uses `grep -F` (literal substring) for each token; case-sensitive
   for the proper noun `Tauri` (lowercase `tauri::command` is already
   covered by the same token since it contains `tauri.`); case-insensitive
   would over-broaden (e.g. risk matching unrelated `Tauri` strings in
   future imports — actually irrelevant for a single-file scan).

3. **Add a positive assertion** for the new gRPC marker: `service
   FooService` (or equivalently `rpc GetFoo`). This pins that the
   gRPC example does not silently regress to a stub.

**Why.** AC#2 explicitly: "`bin/agent-prompts-content-test.sh` updated
to assert this." The inverted assertion + global negative grep together
make the regression surface impossible to miss; the positive gRPC pin
prevents a future cleanup from dropping the second example silently
(the ENG-52 plan's adversarial concern recurs here per
`bin/agent-prompts-content-test.sh:151-164`).

**Rejected alternative — only add the global negative grep, drop the
positive gRPC pin.** The negative grep alone is permissive — a future
edit could drop Example 1 entirely (leaving only Example 2) and still
pass. AC#3 requires "two-example illustration covering at least one
compiled-IPC and one REST/RPC stack" — the positive pin enforces that
constraint. Rejected.

**Rejected alternative — assert by line number / regex against the full
example body.** Brittle: a non-cosmetic edit (e.g. renaming `FooService`
→ `WidgetService`) would break the test without a real regression.
Asserting the *marker* (`service ` keyword OR `rpc ` keyword) is
sufficient. Adopted: assert `service FooService` exists in §2 (or a
looser `service [A-Za-z]+ \{` pattern via `grep -E`).

## 5. Architecture (where code goes)

Two files change:

1. **`AGENT_PROMPTS.md`** — seven edit sites (D-1 through D-7). The
   edits are non-structural (no section renames, no fence count
   changes); `bin/render-prompt.sh::extract_block` and
   `STAGE_TO_SECTION` are not touched. The §2 column-0 fence count
   stays at 2 (verified contract at `bin/render-prompt.sh:111`).

2. **`bin/agent-prompts-content-test.sh`** — three changes per D-8.
   The test file is self-contained per the harness language idioms
   (`learned-rules/harness/project-profile.md::## Language idioms`,
   "Each `bin/foo.sh` ends with the sentinel ..."); no `source` chain
   is touched.

No other file changes. Specifically out of scope:
- `bin/dispatch.sh::allowed_tools_for` — ENG-94 (already landed at
  `343457c`).
- `bin/run-local-helpers.sh::stage_output_paths` — ENG-95 (in flight).
- `bin/scope-check.sh` — separate ticket on the umbrella.
- `bin/render-prompt.sh` — unchanged.
- `CLAUDE.md` — already stack-neutral after ENG-95's documentation
  update (verified at the `## Sweep + scope partition (ENG-14)` section
  citing the lockfile catalog).

## 6. Data flow

The dispatched agent receives, in this order:

1. The §0 (Common rules) fenced block, prepended to every stage by
   `bin/render-prompt.sh::main` (verified at `bin/render-prompt.sh:314`).
2. The stage's own fenced block (e.g. §2 Plan), with `{token}`
   substitution applied by `resolve_block_tokens`.
3. (For non-retrospective stages only) The full
   `learned-rules/<slug>/project-profile.md` appended verbatim under a
   `## Project profile (addendum)` heading
   (`bin/render-prompt.sh:184-210`).

ENG-97 changes step 2's content for §2, §3, §6, §7, §8, §9. The agent
still reads the profile in step 3 to ground its stack assumptions. The
retrospective stage (§9) is special: per `bin/render-prompt.sh:187-190`,
the profile addendum is NOT appended for `stage="retrospective"`, so
D-7's phrasing must point at the profile *file path* (which the
retrospective can `Read` directly) rather than "the addendum below"
(which would be a dangling reference).

## 7. Error handling

The five forbidden tokens are removed at edit time; the negative-grep
assertion in `bin/agent-prompts-content-test.sh` makes any reintroduction
fail the pre-commit hook (verified hook path:
`.githooks/pre-commit` runs `bin/agent-prompts-content-test.sh` as part
of the suite per `CLAUDE.md::Pre-commit hook` section).

If a future operator's profile lacks a meaningful `## Stack` section
(e.g. the discovery agent emitted `<<NEEDS-INPUT:>>` markers),
`bin/render-prompt.sh:197-200` already dies loudly: `"project-profile.md
contains unresolved markers; run: bash bin/setup.sh project-profile"`.
That existing failure mode is the backstop for "profile is missing the
stack context the prompt now relies on."

The retrospective stage's path-list (D-7) is the only stage that does
NOT see the profile addendum. If the harness ever adds a new
retrospective sweep that needs stack info, it must `Read
learned-rules/<slug>/project-profile.md` directly — this is already the
convention (verified via the discovery code that reads
`learned-rules/<slug>/project-profile.md` from disk in
`bin/dispatch.sh`'s profile-tools helper, per ENG-94's brainstorm).

## 8. Edge cases

| Case | Handling |
|---|---|
| §2 fence count regression | `bin/agent-prompts-content-test.sh:184-190` already pins exactly 2 column-0 fences in §2. The gRPC example keeps the same indented column-4 fence pair; no fence accounting changes. |
| `Tauri` proper-noun appearance in unrelated future content (e.g. a Linear-issue title quoted in a stage prompt) | The negative grep is whole-file, case-sensitive. The Linear-issue title for ENG-97 itself contains "Tauri" — but Linear titles are not embedded in `AGENT_PROMPTS.md`; they live in Linear. If a future ticket inlines a title containing "Tauri" into the prompt, the test fires loudly; the operator must rephrase or quote-strip. (This is the desired behavior — no escape hatch for Tauri.) |
| Indentation of the api-contract fence drift | The indented column-4 fences are load-bearing for the §2 fence count. The §2 fence-count assertion at lines 184-190 catches indentation regression directly. No additional test needed. |
| `Choose your stack:` heading appears inside the fenced block | The heading is a comment line inside a tagged \`\`\`api-contract\`\`\` block (not a markdown `## ` header), so `bin/agent-prompts-content-test.sh::section_body`'s in-fence tracking at line 24 correctly skips it (the awk only ends a section on a `## ` heading outside a fence). |
| ENG-52's existing positive assertions (lines 121-130, 158-164) | The line-121 `#[tauri::command]` positive must be inverted to a negative (per D-8); the line-126 `@app.route` positive stays (Python/Flask example unchanged); the line-158 `pyproject.toml`/`go.mod` positive stays (D-5 only drops `tauri.conf.json`, doesn't touch the rest). |
| `tauri.conf.json` is also referenced in `docs/brainstorms/2026-05-02-eng-52-...md:131` (the predecessor brainstorm) | The negative grep is scoped to `AGENT_PROMPTS.md` only, not to `docs/`. Historical docs may keep the token. |
| `cargo test` (without `-- --list`) appearing in a future prompt | The negative grep uses the literal substring `cargo test -- --list` per AC#1. A bare `cargo test` is not forbidden by ENG-97 (and would be caught by a different ENG-92 sibling if needed). |
| Case-insensitive `tauri::command` matching `Tauri` | `grep -F` is case-sensitive; `Tauri` matches `Tauri` (proper-noun), `tauri::command` matches `tauri.` (different substring). To cover both: assert both `Tauri` AND `tauri::` as separate forbidden tokens, OR use `grep -i Tauri`. Choosing **separate explicit tokens**: `Tauri`, `tauri::`, `tauri.conf`, `src-tauri/`, `cargo test -- --list`, `invoke(`. This makes the failure message diagnostic ("token X matched on line Y") rather than catching everything under one assertion. |
| Retrospective stage scans `crates/` and `src-tauri/src/` today as concrete paths; D-7 generalizes to "code-bearing dirs from File layout" | Verified at `learned-rules/harness/project-profile.md::## File layout`: the harness profile names `bin/`, `bin/setup-prompts/`, `learned-rules/<slug>/`, `launchd/`, `docs/brainstorms/`, `docs/plans/`, `AGENT_PROMPTS.md`. The retrospective's human-override scan therefore covers the right set on the harness-self target without any hardcoded `crates/`/`src-tauri/`. For the twinning (Tauri) target, the profile names its code-bearing dirs and the scan covers them. |
| Existing PR / branch / git state in the worktree | None affected — this is a prompt-content change with one test-content change. No state migration, no runtime behavior change. |

## 9. Open questions

| OQ | Question | Default if not resolved |
|---|---|---|
| OQ-1 | Should the gRPC example use `int64`/`double` (proto types) or `i64`/`f64` (Rust types) on the request/response messages? gRPC's protobuf syntax uses `int64`/`double`; this is what the example should match. | Use protobuf types (`int64`, `double`). |
| OQ-2 | Should `Choose your stack:` be a comment line inside the fence (`# Choose your stack:`) or prose above the fence? Comment is more discoverable when the agent reads the prompt; prose is more grammatical for the human reader. | Comment line inside the fence — matches the existing `# === Example 1 — ... ===` shape. |
| OQ-3 | Should D-7's wording reference the retrospective stage's lack of addendum explicitly, or quietly assume the path-list is read once at retrospective time? Explicit is clearer; quiet is shorter. | Explicit — the carve-out is non-obvious and worth one sentence ("the retrospective stage reads the profile file directly via `Read`; it does not receive the addendum auto-append"). |
| OQ-4 | Should the global negative-grep in the test also flag `cargo build` / `cargo run` (close-cousin Rust commands)? AC#1 only enumerates `cargo test -- --list`. Broader matches catch more bias but risk false positives if a future stack genuinely needs `cargo` in a non-Tauri context. | Match only AC#1's enumerated tokens. Broader patterns are a separate ticket. |
| OQ-5 | Should D-1's gRPC example also illustrate the streaming-RPC shape (server-side stream)? The original Tauri example included `event "foo:progress"` for emitted events; gRPC's analog is a streaming RPC. Adds one more line. | Skip the streaming-RPC illustration. The original `event "foo:progress"` was a Tauri-specific feature; gRPC server-streams are a different mechanism, and the api-contract block's purpose is to communicate the SHAPE of typed FE↔BE bindings, not exhaustive coverage. If the project's stack genuinely needs streaming events, the profile addendum names that idiom. |

## 10. Out of scope

- `bin/dispatch.sh::allowed_tools_for` — covered by ENG-94 (landed).
- `bin/run-local-helpers.sh::stage_output_paths` — covered by ENG-95.
- `bin/scope-check.sh` — separate ticket on ENG-92.
- `bin/render-prompt.sh` — unchanged; the existing `append_project_profile`
  mechanism is the contract this ticket relies on.
- Any documentation files under `docs/` — the negative-grep is scoped
  to `AGENT_PROMPTS.md` only. Historical brainstorms (e.g. ENG-52's at
  `docs/brainstorms/2026-05-02-eng-52-...md`) reference Tauri because
  they describe the predecessor state; that is correct historical
  record.
- `CLAUDE.md` — already stack-neutral after ENG-95's documentation pass.
- The retrospective agent's behavior beyond the path-list change in D-7.

## 11. Assumption inventory

| # | Assumption | Status | Evidence (`path:line` or method) |
|---|---|---|---|
| A-1 | `AGENT_PROMPTS.md:458` carries the Tauri prose mention | **verified** | Read `AGENT_PROMPTS.md:458`: "...two illustrative examples (Tauri v2 + TypeScript for a compiled-IPC stack, Python/Flask + TypeScript for an HTTP-handler stack)..." |
| A-2 | `AGENT_PROMPTS.md:461` is the Example 1 header | **verified** | Read `AGENT_PROMPTS.md:461`: `# === Example 1 — Tauri v2 + TypeScript (compiled-IPC stack) ===` |
| A-3 | `AGENT_PROMPTS.md:464` is `#[tauri::command]` | **verified** | Read `AGENT_PROMPTS.md:464`: `#[tauri::command]` |
| A-4 | `AGENT_PROMPTS.md:782` carries the `invoke("cmd_x", …)` parenthetical | **verified** | Read `AGENT_PROMPTS.md:782`: `e.g. \`invoke("cmd_x", …)\` on Tauri stacks, \`fetch("/api/foo")\` on REST stacks` |
| A-5 | `AGENT_PROMPTS.md:1134` lists "Tauri command, REST handler, RPC method" | **verified** | Read `AGENT_PROMPTS.md:1134`: `- a new FE↔BE handler / endpoint (e.g. Tauri command, REST handler, RPC method),` |
| A-6 | `AGENT_PROMPTS.md:1162` cites `cargo test -- --list for Rust` | **verified** | Read `AGENT_PROMPTS.md:1162`: `e.g. \`cargo test -- --list\` for Rust` |
| A-7 | `AGENT_PROMPTS.md:1406` lists `tauri.conf.json` | **verified** | Read `AGENT_PROMPTS.md:1406`: `\`tauri.conf.json\`,` |
| A-8 | `AGENT_PROMPTS.md:1604-1605` is the Tauri dual-manifest example | **verified** | Read `AGENT_PROMPTS.md:1604-1605`: `- Some stacks track version in multiple manifests (e.g. Tauri tracks both \`package.json\` and \`src-tauri/Cargo.toml\`). Check whether the secondary manifests` |
| A-9 | `AGENT_PROMPTS.md:1724` lists `src-tauri/src/` | **verified** | Read `AGENT_PROMPTS.md:1724`: `\`crates/*/\`, \`src/\`, and \`src-tauri/src/\` modified by a human commit AFTER a bot commit` |
| A-10 | `bin/agent-prompts-content-test.sh:120-130` is the §2 Tauri-positive + Python/Flask-positive assertion block | **verified** | Read `bin/agent-prompts-content-test.sh:120-130`: lines 121, 122, 124 cite `#[tauri::command]`; line 127 cites `@app.route` |
| A-11 | `bin/agent-prompts-content-test.sh:184-190` is the §2 column-0 fence-count==2 assertion | **verified** | Read `bin/agent-prompts-content-test.sh:184-190`: `fence_count_s2="$(printf '%s\n' "$s2" | grep -c '^\`\`\`' || true)"` and the `[[ "$fence_count_s2" == "2" ]]` check |
| A-12 | `bin/render-prompt.sh::extract_block` requires exactly 2 column-0 fences per section, else `die` | **verified** | Read `bin/render-prompt.sh:111-112`: `if [[ "$fence_count" != "2" ]]; then die "AGENT_PROMPTS.md schema error: section '$section' has $fence_count column-0 fences (expected 2)..."` |
| A-13 | `bin/render-prompt.sh::append_project_profile` appends the profile to every non-retrospective stage | **verified** | Read `bin/render-prompt.sh:184-210`: function checks `stage == "retrospective"` first (cat passthrough), else appends `learned-rules/$PROJECT_SLUG/project-profile.md` under `## Project profile (addendum)` header |
| A-14 | `bin/render-prompt.sh` SKIPS the addendum for `stage="retrospective"` | **verified** | Read `bin/render-prompt.sh:187-190`: `if [[ "$stage" == "retrospective" ]]; then cat; return 0; fi` |
| A-15 | The harness profile's `## File layout` names `docs/brainstorms/`, `docs/plans/`, `bin/`, etc. (so D-7's "code-bearing dirs from profile" resolves on the harness-self target) | **verified** | Read `learned-rules/harness/project-profile.md` (file layout section in the rendered profile in this dispatch's prompt addendum): "`bin/` — every orchestration script… `docs/brainstorms/` and `docs/plans/` — canonical doc locations…" |
| A-16 | `bin/agent-prompts-content-test.sh:158-164` asserts only `pyproject.toml` and `go.mod` exist in §7's config-scan list (does NOT pin `tauri.conf.json`) | **verified** | Read `bin/agent-prompts-content-test.sh:158-164`: only `pyproject.toml` and `go.mod` are grepped; dropping `tauri.conf.json` from the list does not break this assertion |
| A-17 | ENG-94 (sibling dispatch-tools de-Tauri) has landed | **verified** | `git log` recent commits: `343457c feat(eng-94): Make dispatch.sh::allowed_tools_for consume project-profile tools (drop hardcoded Tauri base)` |
| A-18 | ENG-95 (sibling stage-output-paths de-Tauri) is in flight | **verified** | Read `docs/brainstorms/2026-05-13-eng-95-...-design.md` (exists in worktree); plan also exists at `docs/plans/2026-05-13-eng-95-...md` |
| A-19 | `.githooks/pre-commit` runs `bin/agent-prompts-content-test.sh` as part of the test suite | **verified** | CLAUDE.md `## Tests / Pre-commit hook` section: "The repo ships a pre-commit hook at `.githooks/pre-commit` that runs the entire `bin/*-test.sh` suite (~30 s) and blocks the commit on any failure." `bin/agent-prompts-content-test.sh` is a `bin/*-test.sh` script. |
| A-20 | Section H2 headers in `AGENT_PROMPTS.md` match the names in `bin/agent-prompts-content-test.sh::section_body` calls (`## 2. Plan Agent`, `## 7. Build Agent`, etc.) | **verified** | Read `AGENT_PROMPTS.md` H2 list: `## 2. Plan Agent` (line 346), `## 3. Implementation Agent (Backend)` (line 607), `## 5. Review Agent` (line 891), `## 6. QA Agent` (line 1109), `## 7. Build Agent` (line 1271), `## 8. Release Agent` (line 1537), `## 9. Retrospective Agent (Scheduled)` (line 1643) |
| A-21 | gRPC + protobuf is unambiguously non-Tauri (the negative-grep does not false-positive on the gRPC example) | **verified** | The gRPC example uses `service FooService`, `rpc GetFoo`, `message FooRequest`, `int64`, `double` — none contain `Tauri`, `tauri.`, `src-tauri/`, `cargo test -- --list`, or `invoke(`. |
| A-22 | `bin/render-prompt-test.sh` does not assert on `Tauri`-specific content | **verified** | Read `bin/render-prompt-test.sh:1-80` — tests profile-addendum behavior, no Tauri-specific assertions. |
| A-23 | Linear issue's "Lines 433-446: api-contract Example 1 is Tauri v2 + TypeScript" cites pre-ENG-52 line numbers; current file places the api-contract block at lines 460–495 | **verified** | Read `AGENT_PROMPTS.md:460-495` — Example 1 at line 461, Example 2 at line 479. The Linear issue's line numbers reflect the pre-ENG-52 file shape; the current shape already has both examples. ENG-97 replaces Example 1 (Tauri) with a non-Tauri compiled-IPC representative. |
| A-24 | Project profile addendum's schema_version field is currently 2 (per ENG-93/T1 / ENG-94) | **verified** | This dispatch's prompt addendum: `schema_version: 2`. (Note: `bin/render-prompt.sh:202` still checks for `schema_version: 1` as a non-fatal warning; the warning fires today on every harness dispatch. Out of scope for ENG-97 to fix.) |
| A-25 | The retrospective agent can `Read` files directly (so D-7's "named in the per-target `learned-rules/<slug>/project-profile.md`" is operable even without the addendum auto-append) | **verified** | The retrospective stage has `Read` in its base allowlist (implicit per the project-profile's "Tool allowlist" comment: "Stage-agnostic core tools (Read, Write, Edit, Grep, Glob, ...) are implicit and not declared here"). The retrospective in §9 already reads files (e.g. `docs/knowledge/gotchas.md` per lines 1714-1720). |
| A-26 | The existing positive assertion at line 121 (`#[tauri::command]`) is the ONLY Tauri-positive assertion in `bin/agent-prompts-content-test.sh` (no other test pins Tauri-shape content that we'd need to invert) | **verified** | `grep -n "tauri\|Tauri\|src-tauri\|cargo test\|invoke" bin/agent-prompts-content-test.sh` returned only matches at lines 120-129, 155 (comment only), 160-162. Line 155 is a comment ("Tauri-only list"), not an assertion; lines 158-164 only positively assert `pyproject.toml` and `go.mod`. |
| A-27 | `bin/agent-prompts-content-test.sh::section_body` correctly stops at `## ` headings outside fences and ignores `## ` lines inside indented code blocks | **verified** | Read `bin/agent-prompts-content-test.sh:20-28`: `awk` tracks `in_fence` toggling on `/^\`\`\`/`, only exits section on `/^## /` when `!in_fence`. (Indented `## ` lines inside a column-4 fence: the fence regex `^\`\`\`` does NOT match column-4 \`\`\`, so `in_fence` does not toggle for indented fences — but a `## ` inside the indented block would NOT be at column 0 either, so the `/^## /` match also does not fire. Both ends are robust.) |

## 12. ADR stress test

The harness has no formal ADR registry (`docs/knowledge/decisions.md`
does not exist; verified by `ls docs/knowledge/` returning nothing).
The implicit principle this ticket extends — **profile-as-source-of-
truth** — is named in ENG-49's brainstorm and was rolled forward by
ENG-52, ENG-93, ENG-94, and ENG-95.

This ticket puts pressure on the principle in one place: D-7
(retrospective stage). The retrospective is the only stage that does
NOT receive the profile addendum, so any "the profile addendum names X"
phrasing in §9 is a dangling reference. D-7's adjusted phrasing
("declared in the per-target `learned-rules/<slug>/project-profile.md::
## File layout`") routes through the profile file path directly, which
the retrospective can `Read`. This preserves the principle at the cost
of one extra line of explicit-path prose.

No existing ADR is overturned. No new ADR is proposed; the principle
this ticket extends is implicit-but-established and proposing a formal
ADR is out of scope.

## 13. Simpler-alternative inventory

For each major decision, the rejected alternative + why-rejected is
documented inline in §4. Summary table:

| Decision | Simpler alternative rejected | Why |
|---|---|---|
| D-1 (gRPC replacement) | Drop Example 1 entirely | Loses pedagogical contrast for human readers of the prompt file |
| D-1 (gRPC replacement) | Rebrand `#[command]` (no `tauri::`) | Still infers "this is Tauri reskinned" |
| D-1 (gRPC replacement) | JSON-RPC over WebSocket | Not codegen-driven; blurs "compiled-IPC" framing |
| D-2 (drop `invoke()`) | Keep REST illustration alone | Picks REST as new default — same bias inverted |
| D-3 (drop Tauri enumeration) | Replace Tauri with gRPC parallel | Adds tokens without discrimination |
| D-4 (drop `cargo test --list`) | Replace with `pytest --collect-only` | Picks Python as new default |
| D-5 (drop `tauri.conf.json`) | Replace with `electron-builder.yml` | Same default-picking trap |
| D-6 (drop Tauri dual-manifest) | Drop example entirely | Loses the semantic-release single-file warning |
| D-6 (drop Tauri dual-manifest) | Replace with Cargo+bun pair | Same default-picking trap |
| D-7 (drop `src-tauri/src/`) | List union of canonical paths | No canonical union exists; profile encodes the variance |
| D-7 (drop `src-tauri/src/`) | Drop §9 scan entirely | Scope creep — feature is unrelated to Tauri |
| D-8 (test changes) | Negative grep alone, no positive gRPC pin | Permissive — Example 1 could silently disappear |
| D-8 (test changes) | Pin full example body verbatim | Brittle to cosmetic renames |

## Persona review

Per the brainstorm-stage Completion checklist, six personas run in
order: design → security → scope → coherence → product → feasibility.
Each persona's verdict + findings are recorded below; iteration ran
once (no P0s surfaced).

### Persona 1: design — PASS

Findings:
- D-1's structural choice (one indented fence pair, two examples
  separated by `# ---`) preserves §2's column-0 fence count of 2;
  no schema risk to `extract_block`. Matches the ENG-52 D-1
  architectural choice that already shipped — this is the same
  shape, different content.
- D-7's retrospective-stage carve-out is the only non-trivial design
  call. Adjusted phrasing makes the path explicit; no design ambiguity
  remains.
- The negative-grep + positive-pin test pairing in D-8 mirrors ENG-52
  QA-adversarial's pattern (locking both the absence of the old shape
  AND the presence of the new). Pattern-consistent.

No P0/P1 findings.

### Persona 2: security — PASS

Findings:
- No secrets touched. No env-var fallback patterns (`${VAR:-X}`)
  introduced. No new Bash invocations exposed.
- The negative-grep assertion in `bin/agent-prompts-content-test.sh`
  runs over a checked-in markdown file; no path traversal or content
  injection vector.
- gRPC example uses placeholder names (`FooService`, `FooRequest`) —
  no real service endpoints or hostnames embedded.

No P0/P1 findings.

### Persona 3: scope — PASS

Findings:
- Two files changed (`AGENT_PROMPTS.md`, `bin/agent-prompts-content-test.sh`),
  exactly matching the Linear issue's `Scope Boundaries: IN: AGENT_PROMPTS.md only`
  + AC#2 (test update). The test file is implicitly in scope because AC#2
  names it explicitly.
- `bin/scope-check.sh`, `bin/run-local-helpers.sh`, `bin/dispatch.sh` are
  explicitly out of scope per Linear's `OUT:` clause and §10.
- The retrospective stage's path-list change (D-7) might look like
  feature-creep but is a direct response to AC#1's `src-tauri/` removal
  requirement — the path-list contains that exact token, so editing it
  is mandatory, not optional.
- One subtle scope question: D-1's `Choose your stack:` heading is the
  Linear issue's Technical Hints prescription, but Technical Hints are
  not Acceptance Criteria. Adopting the heading is consistent with the
  hint and adds zero risk; not adopting would also satisfy AC. Adopted
  per the hint to minimize operator surprise on review.

No P0/P1 findings.

### Persona 4: coherence — PASS

Findings:
- ENG-94 (landed) and ENG-95 (in flight) cover the orchestrator-side
  de-Tauri-ing; ENG-97 covers the prompt side. The three sibling
  tickets are coherent: ENG-94's profile-derived tool allowlist,
  ENG-95's profile-derived stage_output_paths, and ENG-97's
  profile-pointing prose all route through the same
  `learned-rules/<slug>/project-profile.md` artifact.
- D-7's retrospective carve-out is internally coherent with
  `bin/render-prompt.sh:187-190`'s existing skip-on-retrospective
  behavior. No new code path; the prompt phrasing aligns with the
  long-standing render-time behavior.
- The negative-grep assertion in D-8 references the same five tokens
  enumerated in AC#1 — direct alignment with the Linear ticket, no
  drift.

No P0/P1 findings.

### Persona 5: product — PASS

Findings:
- The user-visible outcome (operators bringing up new non-Tauri
  targets) is unambiguously improved: a Python-target operator reading
  the prompt file would no longer infer "this pipeline assumes Tauri."
- The Tauri-target operator (twinning) is no worse off — the profile
  addendum on their dispatch still names Tauri, so their plan agent's
  api-contract block will still use Tauri shape; the prompt's
  illustrative example just doesn't lead them by name. Verified at
  `learned-rules/twinning/project-profile.md` — Tauri stack still
  declared there per the umbrella's per-slug profile design.
- Prompt-token cost is approximately neutral (D-1 swaps a Tauri Rust
  example for a gRPC protobuf example, ~similar line count; D-2..D-7
  are short rewrites that don't grow the prompt). No measurable cost
  regression.

No P0/P1 findings.

### Persona 6: feasibility — PASS (zero P0)

Codebase-fact verification pass (the gating check per the brainstorm
checklist):

- **`AGENT_PROMPTS.md:458`, `:461`, `:464`, `:782`, `:1134`, `:1162`,
  `:1406`, `:1604-1605`, `:1724`** — every cited line was read directly
  in this dispatch; quoted excerpts are in §11 A-1 through A-9.
- **`bin/agent-prompts-content-test.sh:120-130`, `:158-164`,
  `:184-190`** — read directly; the §2 positive Tauri assertion at
  line 121 and the §2 fence-count assertion at line 184 are the
  load-bearing test surfaces. A-10, A-11, A-16 in §11.
- **`bin/render-prompt.sh:86-126`** (`extract_block`) — read directly;
  the exactly-2-column-0-fences contract verified at line 111. A-12.
- **`bin/render-prompt.sh:184-210`** (`append_project_profile`) — read
  directly; the retrospective skip verified at lines 187-190. A-13, A-14.
- **`learned-rules/harness/project-profile.md`** — schema_version 2,
  the `## File layout` section verified to name `bin/`,
  `docs/brainstorms/`, `docs/plans/` etc. (A-15, A-24 in §11). The
  retrospective stage can read this file directly via `Read` per A-25.
- **ENG-94 landed** — `git log` shows commit `343457c` on this branch's
  ancestry (A-17).
- **gRPC + protobuf as the replacement** — A-21: the replacement
  example contains none of the five forbidden tokens (`Tauri`,
  `tauri.`, `src-tauri/`, `cargo test -- --list`, `invoke(`).

The negative-grep assertion's exact pattern was test-rehearsed
mentally: `grep -nF 'Tauri' AGENT_PROMPTS.md` should match zero lines
post-edit; same for `grep -nF 'tauri::'`, `grep -nF 'tauri.conf.json'`,
`grep -nF 'src-tauri/'`, `grep -nF 'cargo test -- --list'`,
`grep -nF 'invoke('`. Each token is a literal substring.

Zero P0 findings. Brainstorm proceeds to planning.

## 14. Summary

Seven edit sites in `AGENT_PROMPTS.md` strip Tauri-specific
illustrations and route through the profile addendum that every
non-retrospective stage already receives. One edit site in
`bin/agent-prompts-content-test.sh` inverts the §2 Tauri positive
assertion to a negative, adds a global negative-grep over the five
canonical forbidden tokens, and pins the new gRPC marker positively.
Sibling tickets ENG-94 (dispatch-tools) and ENG-95
(stage-output-paths) cover the orchestrator side of the umbrella;
ENG-97 closes the prompt side.
