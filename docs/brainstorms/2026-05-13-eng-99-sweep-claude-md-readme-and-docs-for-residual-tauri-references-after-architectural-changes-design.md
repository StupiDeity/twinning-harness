---
linear: ENG-99
title: Sweep CLAUDE.md, README, and docs/* for residual Tauri references after architectural changes
date: 2026-05-13
status: draft
umbrella: ENG-92
---

# ENG-99 — Sweep CLAUDE.md, README, and docs/* for residual Tauri references

## 1. Overview

ENG-92 ("De-Tauri the harness") landed across six tickets that drained
hardcoded Tauri/Bun assumptions from the harness's *mechanisms*:

| Ticket | Surface | Result |
|---|---|---|
| ENG-93 | project-profile schema v2 (Tool allowlist section) | new authoritative source for stack tools |
| ENG-94 | `bin/dispatch.sh::allowed_tools_for` | profile-derived per-stage tool list (Tauri tokens removed from base) |
| ENG-95 | `bin/run-local-helpers.sh::stage_output_paths` | profile-derived scope allowlist (`src-tauri/` / `crates/` / `bun.lock*` removed; `_always_include_paths` is a stack-agnostic lockfile catalog) |
| ENG-97 | `AGENT_PROMPTS.md` | Tauri-shaped examples stripped, replaced with profile-driven phrasing |
| ENG-98 | `bin/dry-run.sh`, `bin/run-local.sh` PATH | Bun-as-hard-dep removed; PATH augmentation documented |

ENG-99 is the **documentation sweep complement**. The mechanisms are
already stack-agnostic; what survives is *prose* in operator-facing docs
that still reads "Tauri is the default and you tweak for non-Tauri" —
the exact mental model the umbrella was reframing. Three classes of
residue need rewriting:

1. **"Tauri default + non-Tauri tweak" framing** — README §38, README
   §417 ("Default per-stage allowed-tools list is Tauri-shaped"),
   docs/assumptions.md §176 ("Default allowed-tools list is
   Tauri-shaped"), docs/configuration.md §159 ("shaped for a Tauri
   (Rust + Bun + JS) target"), docs/configuration.md §228 ("Adding
   extras for a non-Tauri stack"), docs/configuration.md §285
   ("Minimal (Tauri target, defaults everywhere)"), docs/install.md
   §184 ("If your target stack isn't Tauri"). These contradict the
   post-ENG-94 contract — the base is now stack-neutral and stack
   tokens come from the profile.
2. **Stale concrete examples** — README §498-499 (`cargo build` /
   `bun install` in the supply-chain threat model), docs/security.md
   §76/§81/§91 (cargo/bun/npx/node enumerated in threat A2),
   docs/configuration.md §218 (table row enumerating cargo/bun/rustc
   in the implementing base list — wrong post-ENG-94),
   docs/architecture.md §74 (`Cargo.toml / package.json / ...`
   diagram cell). The intent is preserved (illustrate a
   package-manager-driven build) but the framing needs to be
   stack-neutral.
3. **CLAUDE.md residues** — line 57 ("`bun tauri build`" parenthetical
   in the PATH table), line 303 with its continuation onto 304
   ("hardcoded Tauri shape ... was removed in ENG-95" — true but
   reads as historical apology — the literal `tauri` token is on
   303; line 304 is the same sentence's continuation), lines 314-315
   (Migration from pre-ENG-95 paragraph), line 338 ("`cargo` for
   Tauri" in the example list). CLAUDE.md reaches every dispatched
   agent via the orchestrator's `/CLAUDE.md` prompt resolver, so
   residual Tauri framing here propagates into every prompt.

The ticket's spec lists lines 262-263 in CLAUDE.md, but a Grep against
the current worktree shows the Tauri tokens live at lines 57, 303,
314, 315, 338 — five separate matches; line 304 is the wrap of the
303 sentence and gets rewritten as part of that paragraph (verified —
see Assumption inventory #1). Line numbers in Linear-issue specs are
time-of-filing snapshots; the doc shifts as adjacent tickets land.
The brainstorm targets the **actual** current locations, not the
spec's literal line numbers.

**Load-bearing tradeoff.** Every "Tauri" mention removed risks losing a
*motivating example* that anchored an abstraction. Three of the
residues (README §498-499, docs/security.md §81, docs/architecture.md
§74) name `cargo`/`bun`/`npm` not to claim "this is the default" but
to illustrate "these are typical examples of the *kind* of tool the
agent runs against your target." For those, the rewrite preserves the
illustration while neutralising the "Tauri = default" framing —
typically by listing two or three contrasting package managers
(`cargo build` / `bun install` / `pip install` / `go build`) rather
than dropping the examples entirely. The trade is: pedagogical
clarity (concrete examples > abstract phrasing) traded against
strict zero-Tauri (the acceptance-criterion phrasing). The issue's
AC#2 explicitly permits "two-stack contrast" — we use that latitude.

**Canonical phrasing locks (consistency across files).** To prevent
the rewrites from drifting (coherence persona P1 + product persona
P1, folded), the brainstorm locks two strings as canonical:

- **Composition order:** every site that names the post-ENG-94
  composition uses the verbatim phrase **"stack-neutral base +
  profile-derived stack tools + operator-curated extras"** (or its
  shorter form **"base (stack-neutral) → profile → operator
  extras"** in tabular contexts). No variants ("operator extras",
  "additions", "config extras") — they're the same concept and
  should read the same.
- **Multi-stack-contrast tokens:** two enumeration sizes, used by
  context:
  - **Threat / security sites** (where the point is "this risk
    applies regardless of stack") — use the 4-package-manager list
    **`cargo / bun / pip / go`** (one Rust, one JS, one Python,
    one Go). Drop test-runners (`pytest`, `jq`) from the threat
    enumeration; those are not package resolvers and don't carry
    the post-install-script supply-chain risk (security persona
    P2, folded).
  - **Build-tool / file-name sites** (where the point is "concrete
    example of what your stack might look like") — use the 3-token
    set **`Cargo.toml / package.json / pyproject.toml`** + `...`,
    or **`cargo build / bun install / pip install`** + `...`.
- **append vs prepend** (design persona P1 + coherence persona P2,
  folded): `render-prompt.sh::append_project_profile` **appends**
  the project profile to the dispatch prompt (the helper name is
  the source of truth); CLAUDE.md reaches the dispatch via a
  separate resolver in `render-prompt.sh::PROMPT_RESOLVERS` (the
  `/CLAUDE.md` resolver), not through the project-profile append
  path. Every callout names the operation as "append" and is
  unambiguous about which file (profile vs CLAUDE.md) takes which
  path.

**Scope discipline.** No code edits, no schema bumps, no new mechanism.
Pure prose rewrites in seven files (CLAUDE.md + README.md + 5 docs/*).
No `bin/*-test.sh` regression test (the harness has no doc-content
test pattern; AC#1 verification is `grep -i tauri` returning zero on
the in-scope files — a one-liner the reviewer can run, not a CI gate).

## 2. Goal

After ENG-99 lands:

- `grep -i tauri CLAUDE.md README.md docs/install.md docs/assumptions.md docs/configuration.md docs/security.md docs/architecture.md`
  returns **zero matches** on the in-scope file set. (AC#1.)
- Concrete examples that previously cited cargo/bun cite "your
  project's package manager" or use a multi-stack contrast (cargo /
  bun / pip / go). (AC#2.)
- Configuration docs reflect the post-ENG-94 composition order:
  **base (stack-neutral)** → **profile-derived stack tools** →
  **config extras** — with the profile named as the canonical source
  of stack truth. (AC#3.)
- The discovery flow (`bash bin/setup.sh /path project-profile`,
  authored output at `learned-rules/<slug>/project-profile.md`) is
  named in CLAUDE.md and docs/architecture.md as the operator-facing
  entry point for "where does the stack list come from." (AC#4.)
- Out-of-scope (per the ticket's OUT boundary): docs/brainstorms/,
  docs/plans/, docs/demos/, learned-rules/. These are historical
  artifacts and named tickets — rewriting them would erase the
  decision trail. Unchanged.

## 3. Architectural principle

This work extends the **profile-as-source-of-truth** principle ENG-49
established and ENG-52/94/95/97/98 carried forward across the
mechanism surface. ENG-99 closes the loop on the *documentation*
surface — operator-facing prose should describe the architecture as
it now is, not as it was pre-ENG-92.

The harness has no `docs/VISION.md` or formal ADR registry (verified:
`ls docs/` returns `architecture.md assumptions.md brainstorms/
configuration.md cost.md demos/ install.md operations.md
pipeline-vocabulary.md pipeline-vocabulary.template.md plans/
runbooks/ security.md` — no VISION.md, no `knowledge/decisions.md`).
The governing constraints come from CLAUDE.md, the project profile
addendum, and the ENG-92 umbrella's stated goal. The principle invoked
here is an **extension** of ENG-49's profile-as-source-of-truth into
the docs surface, not a new principle.

The closest analogue in the brainstorm history is ENG-52's D-5
(document the sweep as a safety net rather than re-architect) and
ENG-97's "profile names the shape, prose points at the profile" —
both apply the same principle one layer above the mechanism.

## 4. Decisions

### D-1: Strip "Tauri default" framing from all in-scope files; replace with stack-neutral phrasing pointing at the project profile

**Verdict:** In every location where prose says "the default is
Tauri-shaped" or "if your stack isn't Tauri," rewrite to one of two
patterns:

- **Pattern A — neutralised mechanism description.** Replace
  "Tauri-shaped" with "stack-neutral; stack-specific tools come from
  the project profile (`learned-rules/<slug>/project-profile.md::##
  Tool allowlist`)." Used in docs/configuration.md §159,
  docs/assumptions.md §176, README §417, docs/install.md §184.
- **Pattern B — multi-stack contrast.** Where a *concrete example*
  was previously Tauri-only (cargo + bun), replace with a 2-3-way
  contrast (cargo / bun / pip / go). Used in README §498-499,
  docs/security.md §76/§81/§91, docs/architecture.md §74,
  docs/configuration.md §218 (the table row), §285 (the worked
  example title).

Concrete rewrites for the major sites:

**CLAUDE.md:57** — drop the `bun tauri build` parenthetical:
```
- | `$HOME/.bun/bin` | dispatched agent's stack tools | Bun user-global bin. Only consumed on Bun-using targets (e.g. twinning's `bun tauri build`). |
+ | `$HOME/.bun/bin` | dispatched agent's stack tools | Bun user-global bin. Only consumed on Bun-using targets. |
```

**CLAUDE.md:303-304** — rewrite "hardcoded Tauri shape ... was removed
in ENG-95" as forward-looking, not historical apology:
```
- ...plus a stack-agnostic catalog of `docs/` and common
- manifest+lockfile filenames (`Cargo.lock`, `package-lock.json`,
- `poetry.lock`, `go.sum`, etc. — see `_always_include_paths` in
- `bin/run-local-helpers.sh`). The hardcoded Tauri shape (`src-tauri/`,
- `crates/`, `bun.lock*`) was removed in ENG-95.
+ ...plus a stack-agnostic catalog of `docs/` and common
+ manifest+lockfile filenames (`Cargo.lock`, `package-lock.json`,
+ `poetry.lock`, `go.sum`, etc. — see `_always_include_paths` in
+ `bin/run-local-helpers.sh`). The profile is the canonical source
+ of stack-specific paths; the catalog is universal across slugs.
```

**CLAUDE.md:314-325** — drop the "Migration from pre-ENG-95 (existing
Tauri targets)" paragraph entirely. Migration is complete; the
profile-derived path is the only path. Replace with a forward-looking
"Empty profile → falls back to docs/ + lockfile catalog" callout
(the diagnostic message is unchanged; only the framing changes).

**CLAUDE.md:338** — drop the "Tauri" attribution:
```
- stack tools (`cargo` for Tauri, `pytest` for Python, `go test` for Go, etc.) flow from the
+ stack tools (`cargo` for Rust, `pytest` for Python, `go test` for Go, etc.) flow from the
```

**README.md:38-41** — replace the "If your stack isn't Tauri" block
with a stack-neutral one. Per product persona P1 (folded), keep the
opener short and defer the schematics; jargon density in the README's
first ~50 lines hurts a new operator's onboarding:
```
- If your stack isn't Tauri, you'll need a one-time `.pipeline-config/`
- allowlist edit per the **Configuration** section below. Other than that, the
- harness is stack-agnostic — the agents just run whatever build/test commands
- your target repo already has.
+ The harness is stack-agnostic. The first-time setup (`bash bin/setup.sh
+ /path`) discovers your target's stack and writes a per-target profile
+ that the orchestrator reads at dispatch time. The agents then run
+ whatever build/test commands your target already uses.
+ → See [docs/architecture.md "Discovery and the project profile"](docs/architecture.md#discovery-and-the-project-profile)
+ for the full lifecycle.
```

**README.md:346** — drop "(required for non-Tauri stacks)":
```
- the dispatch.tools allowlist (required for non-Tauri stacks), or
+ the dispatch.tools allowlist (operator-curated extras on top of the
+ profile-derived list), or
```

**README.md:417-419** — rewrite the Stack assumption with the
canonical phrasing:
```
- - **Stack**: Default per-stage allowed-tools list is Tauri-shaped. Other
-   stacks need a `.pipeline-config/config.json::dispatch.tools` extras
-   block.
+ - **Stack**: Per-stage allowed-tools is composed of **stack-neutral
+   base + profile-derived stack tools + operator-curated extras**.
+   The profile (`learned-rules/<slug>/project-profile.md::## Tool
+   allowlist`) is authored by the discovery agent during setup; the
+   extras (`.pipeline-config/config.json::dispatch.tools`) are
+   operator-curated. Adding a new target runs discovery (Phase 5b)
+   to populate the profile.
```

**README.md:498-501** — broaden the supply-chain threat example,
locked to the same 4-package-manager convention as docs/security.md:
```
- 1. **No supply-chain isolation** — agent dispatches run `cargo build` /
-    `bun install` / `npm install` against the target repo with full
-    filesystem access. Malicious post-install scripts execute in your
-    shell context.
+ 1. **No supply-chain isolation** — agent dispatches run your target's
+    package-manager commands (e.g. `cargo build`, `bun install`,
+    `pip install`, `go build`) against the target repo with full
+    filesystem access. Malicious post-install scripts execute in your
+    shell context.
```

**docs/install.md:184-187** — neutralise the "If your target stack
isn't Tauri" phrasing:
```
- If your target stack isn't Tauri, **after this phase** you'll want to
- populate `dispatch.tools` per
- [`configuration.md`](configuration.md#dispatchtools--per-stage-allowlist-extras).
- This is not driven by setup; you edit `config.json` by hand.
+ Phase 5b (`project-profile`) populates the per-stage Tool allowlist
+ for your target's stack. If you need additional operator-curated
+ tools on top of the profile-derived list (e.g. enumerated
+ `bin/*-test.sh` entries for harness-self), add them to
+ `dispatch.tools` per
+ [`configuration.md`](configuration.md#dispatchtools--per-stage-allowlist-extras).
+ This is not driven by setup; you edit `config.json` by hand.
```

**docs/assumptions.md:174-185** — rewrite the whole subsection, using
the canonical phrasing lock from §1 ("stack-neutral base +
profile-derived stack tools + operator-curated extras"):
```
- ## Stack
-
- ### Default allowed-tools list is Tauri-shaped
-
- `bin/dispatch.sh::allowed_tools_for` ships a per-stage allowlist that
- includes `cargo`, `bun`, `rustc`, `node`, `npx`, full `git`, `jq`, `awk`.
- Any stack outside Tauri (Rust + Bun) needs an extras block in
- `.pipeline-config/config.json::dispatch.tools`. See
- [`configuration.md`](configuration.md#dispatchtools--per-stage-allowlist-extras).
-
- **Failure mode:** "Agent halts with permission denied invoking pytest /
- go test / etc." Cause: command not in allowed-tools.
+ ## Stack
+
+ ### Per-stage allowed-tools is composed, not hardcoded
+
+ The argv composition is **stack-neutral base + profile-derived stack
+ tools + operator-curated extras**:
+
+ - **Stack-neutral base** — `bin/dispatch.sh::allowed_tools_for` ships
+   a stack-agnostic per-stage allowlist: Read/Write/Edit/Grep/Glob,
+   the git family, `jq`, `awk`, `bash bin/linear.sh`,
+   `bash bin/pipeline.sh`, etc. No language-specific tokens.
+ - **Profile-derived stack tools** — `learned-rules/<slug>/project-profile.md`
+   carries a `## Tool allowlist` section authored by the discovery
+   agent (`bash bin/setup.sh /path project-profile`, Phase 5b). The
+   section is per-stage. Example for a Python target's `implementing`:
+
+   ```markdown
+   ## Tool allowlist
+
+   - implementing:
+     - `Bash(pytest:*)`
+     - `Bash(python:*)`
+     - `Bash(ruff:*)`
+     - `Bash(mypy:*)`
+   - qa:
+     - `Bash(pytest:*)`
+     - `Bash(ruff:*)`
+   ```
+ - **Operator-curated extras** — `.pipeline-config/config.json::dispatch.tools.<stage>[]`
+   appends per-target one-offs (e.g. the harness-self target's
+   enumerated `bin/*-test.sh` patterns) on top of the profile.
+
+ See [`configuration.md`](configuration.md#dispatchtools--per-stage-allowlist-extras)
+ for the full composition rules and the wildcard pitfall.
+
+ **Failure mode:** "Agent halts with permission denied invoking pytest /
+ go test / etc." Cause: the project profile's `## Tool allowlist`
+ section is missing those entries — re-run discovery
+ (`bash bin/setup.sh /path project-profile`) or hand-edit the profile.
```

**docs/configuration.md:155-159** — neutralise the framing using the
canonical phrasing lock:
```
- Every `claude -p` invocation passes `--allowed-tools <comma-list>`. The
- base list per stage lives in `bin/dispatch.sh::allowed_tools_for` and is
- shaped for a Tauri (Rust + Bun + JS) target. Other stacks need extras.
+ Every `claude -p` invocation passes `--allowed-tools <comma-list>`.
+ The composition is **stack-neutral base + profile-derived stack tools
+ + operator-curated extras**:
+
+ - **stack-neutral base** — from `bin/dispatch.sh::allowed_tools_for`'s
+   per-stage case arm. No language-specific tokens.
+ - **profile-derived stack tools** — from `learned-rules/<slug>/project-profile.md::## Tool allowlist`,
+   authored by the discovery agent.
+ - **operator-curated extras** — from `.pipeline-config/config.json::dispatch.tools.<stage>[]`,
+   for per-target one-offs that don't belong in the canonical profile.
+
+ Per-target stack tools are declared by the project profile, not
+ hardcoded here.
```

**docs/configuration.md:214-223** — fix the entire stage-allowlist
table. Feasibility verified the residue surfaces (folded P2):
- Line 218 (`implementing`) literally enumerates `cargo, bun, rustc`
  in the built-in list — incorrect post-ENG-94 (those tokens are now
  profile-derived, not built-in).
- Line 219 (`ui`) says "Implementing's tools + Agent, npx, node" —
  inherits the wrong base via the "Implementing's tools" phrasing,
  AND `npx`/`node` are profile-derived post-ENG-94 too.
- Line 220 (`reviewing`), 221 (`qa`), 222 (`building`), 223
  (`released`) — verified clean (`build tools` is vague but
  stack-neutral; no Tauri-specific tokens).

Rewrites:
```
- | `implementing` | Read, Write, Edit, Grep, Glob, TaskCreate, full git family, `cargo`, `bun`, `rustc`, `jq`, `awk`, linear/pipeline scripts |
- | `ui` | Implementing's tools + `Agent`, `npx`, `node` |
+ | `implementing` | Read, Write, Edit, Grep, Glob, TaskCreate, full git family, `jq`, `awk`, linear/pipeline scripts. Stack tools come from `learned-rules/<slug>/project-profile.md::## Tool allowlist`. |
+ | `ui` | Implementing's stack-neutral base + `Agent`. Stack tools (`npx`, `node`, etc.) come from the project profile. |
```

**docs/configuration.md:228** — neutralise the heading:
```
- ### Adding extras for a non-Tauri stack
+ ### Adding operator-curated extras
```

…and broaden the body's examples so it doesn't implicitly cast
Python/Go as "non-default":
```
  Append to `dispatch.tools.<stage>`. The entries are merged with the
- hardcoded base. Examples:
+ stack-neutral base AND the profile-derived stack tools. The profile
+ is the canonical place to declare stack tools (run discovery to
+ populate); `dispatch.tools.<stage>` extras are for **operator-curated
+ additions** on top — typically per-test-script enumeration or
+ per-target one-offs. Examples:

- - **Python project** — add `Bash(pytest:*)`, `Bash(python:*)`, `Bash(ruff:*)`,
-   `Bash(mypy:*)` to `implementing` and `qa`.
- - **Go project** — add `Bash(go:*)`, `Bash(gofmt:*)`, `Bash(golangci-lint:*)`.
  - **Harness self** — add the full enumerated `bin/*-test.sh` list (above).
+ - **Additional dev-tool patterns not declared in the profile** — for
+   example, a per-target one-off `Bash(./scripts/migrate:*)` that doesn't
+   belong in the canonical profile.
```

**docs/configuration.md:285** — drop the parenthetical:
```
- ### Minimal (Tauri target, defaults everywhere)
+ ### Minimal (defaults everywhere)
```

**docs/security.md:76, 81, 91** — broaden the threat-example list,
locked to the **4-package-manager** convention from §1 (`cargo / bun
/ pip / go`). Drop test-runners (pytest, jq) from the threat enumeration
per security persona P2 — they're not package resolvers and don't
carry post-install-script risk:
```
- **Threat**: A malicious npm/cargo/pip package in the target repo's
+ **Threat**: A malicious dependency from any package ecosystem
+ (cargo, bun, pip, go) in the target repo's

- **Reality today**: The agent runs `cargo`, `bun`, `npx`, `node`, `jq`,
- etc. with the worktree as CWD. Any post-install script in any
- dependency executes in your shell context.
+ **Reality today**: The agent runs your target's package-manager
+ commands (e.g. `cargo build`, `bun install`, `pip install`,
+ `go build`) with the worktree as CWD. Any post-install script in
+ any dependency executes in your shell context.

- - No supply-chain isolation. The agent's `cargo build` can run
-   malicious build scripts.
+ - No supply-chain isolation. The agent's package-manager invocations
+   (e.g. `cargo build`, `bun install`, `pip install`, `go build`)
+   can run malicious build scripts.
```

**docs/architecture.md:74** — broaden the diagram cell:
```
- │  │  Cargo.toml / package.json / ...                  │      │
+ │  │  Cargo.toml / package.json / pyproject.toml / ... │      │
```

The `/ ...` ellipsis already signals "or your stack's equivalent" — the
edit is to add one extra explicit token (`pyproject.toml`) so a Python
operator's eye lands on something familiar in the diagram. Two
contrasting tokens + `...` is the established multi-stack-contrast
pattern in this repo.

**Why:** AC#1, AC#2, AC#3. The post-ENG-94 contract is that the base
is stack-neutral and stack tools come from the profile. Every prose
location that says otherwise is now actively wrong — not "stale" but
"contradicts the running code." A docs sweep is the cheapest way to
realign prose with mechanism.

This is the same fold ENG-97 did for `AGENT_PROMPTS.md` (verified at
`docs/brainstorms/2026-05-13-eng-97-...md:60-67` per ENG-97's §2 Goal:
"strip Tauri-specific examples, replace with stack-agnostic
guidance"). ENG-99 applies the identical fold one layer above — to
the human-readable docs that operators read before they touch the
prompts.

**Rejected alternative — leave the docs alone; they're "close
enough."** Rejected because (a) CLAUDE.md is prepended to every
dispatched agent's prompt via the orchestrator's render path, so
Tauri framing here propagates into every stage's prompt for every
target on every tick (the precise *opposite* of what ENG-94/97
were trying to achieve), and (b) operator-facing docs that describe
mechanisms inaccurately have a high *trust cost* — the next-time-an-
operator-debugs incident takes longer because they have to discover
that the docs are stale.

**Rejected alternative — automated regex substitution
(`sed -i 's/Tauri/<stack-agnostic>/g'`).** Tempting for a sweep
ticket. Rejected because (a) the seven sites need *different*
replacements depending on whether the surrounding sentence frames
Tauri as a default-vs-other split or as a concrete example, and (b)
docs/configuration.md §218 needs an actual *content* edit (the table
row's tool list is wrong post-ENG-94), not a word-swap. A `sed` pass
would silently leave the table row's incorrect content untouched.
Manual surgical edits are the only viable shape.

**Rejected alternative — write a doc-content-invariant test
(`bin/docs-no-tauri-test.sh`) so the regression can't recur.** This
would mirror the AGENT_PROMPTS.md content-test pattern at
`bin/agent-prompts-content-test.sh:1-30`. Rejected for this ticket
because (a) the harness has no doc-content test today (`bin/*-test.sh`
list verified — no `docs-*-test.sh` file exists), introducing a new
test category alongside a prose sweep doubles the review surface and
risks the test becoming a tripwire that future legitimate cross-stack
contrasts ("on Tauri targets, X" — pedagogical) fail, and (b) the
grep-once verification (`grep -i tauri docs/install.md ...` returning
zero) is a one-liner anyone can run, and the ENG-92 umbrella reviewer
will run it as part of accepting this ticket. A doc-content test is
a real followup (§10 #2) but not load-bearing now.

**Rejected alternative — fold these doc edits into ENG-94 / ENG-97 /
ENG-98's PRs as drive-bys.** Each preceding ticket touched a single
mechanism; mixing docs-sweep edits into a code-PR (a) bloats the
review surface, (b) loses traceability (the docs-sweep belongs to
the umbrella's last-mile, not to any one mechanism PR), and (c)
the spec for this ticket explicitly says "After T1–T6 land" — it is
intentionally sequenced AFTER the mechanism work. Rejected.

### D-2: Add a "Discovery flow" callout to CLAUDE.md and docs/architecture.md

**Verdict:** AC#4 says "Discovery flow is described accurately in
CLAUDE.md and docs/architecture.md." Neither file currently has a
section that names the discovery flow end-to-end (verified by Grep:
`grep -n discovery docs/architecture.md` returns no hits;
`grep -n project-profile CLAUDE.md` returns the lines from §"Per-target
dispatch.tools extras" but no orientation section).

Add a short callout in two places:

**docs/architecture.md** — append a new H2 section after "Three roots,
three storage tiers" (around line 45), titled **"Discovery and the
project profile"**:

```markdown
## Discovery and the project profile

The orchestrator is stack-neutral. Per-target stack knowledge lives in
`$HARNESS_ROOT/learned-rules/<slug>/project-profile.md` — a markdown
file with a YAML frontmatter `schema_version: 2` and six H2 sections
(Stack, Build & test gates, Tool allowlist, File layout, Language
idioms, Don'ts).

The profile is authored by a **one-shot discovery agent** run via
`bash bin/setup.sh /path/to/target project-profile` (Phase 5b of
setup). The discovery prompt at `bin/setup-prompts/discovery.md` walks
the target's manifests, `.github/workflows/`, and dotfiles to elicit
the six sections. The result is checked into the harness repo (NOT
the target) under `learned-rules/<slug>/`.

The profile drives three things:

| Consumer | Reads | Effect |
|---|---|---|
| `bin/dispatch.sh::_dispatch_tools_from_profile` | `## Tool allowlist` | Per-stage `--allowed-tools` argv composition (the profile-derived middle tier of **stack-neutral base + profile-derived stack tools + operator-curated extras**) |
| `bin/run-local-helpers.sh::stage_output_paths` | `## File layout` | Per-stage scope allowlist for the post-dispatch sweep |
| `bin/render-prompt.sh::append_project_profile` | Entire file | Appended to every non-retrospective dispatch's prompt |

If a profile is missing or its schema is wrong, dispatch falls back to
**stack-neutral base + operator-curated extras** (the middle tier
drops out) and emits one `[allowed-tools]` warning per stage to
stderr. The target keeps working on the universal lockfile catalog +
`docs/` scope allowlist (see Sweep + scope partition below) until the
operator re-runs discovery.

The profile is the canonical source of stack truth. To change the
stack (add a manifest, swap a test runner), edit the profile and
commit; the next dispatch picks it up automatically.
```

**CLAUDE.md** — the existing "Per-target dispatch.tools extras and
profile-derived tools" section (line 335) already covers the composition
order. Add a one-paragraph callout above it (after line 333, before
the H2) titled **"Where stack knowledge lives"**, pointing at the
discovery flow and the profile path. Concrete proposed text (uses
the canonical "append" verb per §1 lock — the helper is named
`append_project_profile`):

```markdown
**Where stack knowledge lives.** The per-slug project profile at
`$HARNESS_ROOT/learned-rules/<slug>/project-profile.md` is the canonical
source of stack truth. It is authored by a one-shot discovery agent
during setup (`bash bin/setup.sh /path project-profile`) and consumed
by three sites: `dispatch.sh::_dispatch_tools_from_profile` (reads
`## Tool allowlist`), `run-local-helpers.sh::stage_output_paths`
(reads `## File layout` for the scope sweep), and
`render-prompt.sh::append_project_profile` (appends the entire
profile to every non-retrospective dispatch's prompt). Missing-or-
malformed profile → stack-neutral fallback + warning, never `die`.
See docs/architecture.md "Discovery and the project profile" for
the full lifecycle.
```

**Why:** AC#4 ("Discovery flow is described accurately in CLAUDE.md
and docs/architecture.md") is a positive add — the existing docs
describe the *consumers* (`allowed_tools_for`, `stage_output_paths`)
but not the *source* (discovery + profile). Without the AC#4
callout, an operator who reads docs/architecture.md and CLAUDE.md
top-to-bottom never encounters the discovery flow as a first-class
concept; they have to assemble it from scattered references.

The two callouts are short (one H2 + one paragraph) and surface-only
— no schema bumps, no mechanism changes, no new tests. They name
files and helpers that exist verifiably today (see Assumption
inventory #2-6).

**Rejected alternative — write a full new docs/discovery.md.**
Rejected because (a) the discovery flow has only two consumers and
two-paragraph-shaped surface area; a dedicated doc would be ~30 lines
of mostly-empty scaffolding, and (b) the existing docs/architecture.md
already covers analogous flows ("Sweep + scope partition", "Slot-
occupancy contract", "AGENT_PROMPTS.md structure") as H2 sections
within the architecture doc, not as separate files. New H2 matches
the convention.

**Rejected alternative — describe discovery only in docs/install.md
Phase 5b.** The Phase 5b paragraph (verified at docs/install.md:128-131)
describes what the phase *does* but not the role the profile plays
afterward. AC#4 explicitly names CLAUDE.md and architecture.md —
those are the architectural-orientation docs an agent or operator
reads to understand the system, not the install runbook. Rejected.

### D-3: Preserve historical references in brainstorms / plans / demos / learned-rules

**Verdict:** Do **not** edit `docs/brainstorms/`, `docs/plans/`,
`docs/demos/`, or `learned-rules/`. The ticket's OUT scope boundary
names these explicitly. Some of those docs reference "Tauri" because
they are time-stamped artifacts of specific tickets — rewriting them
would erase the decision trail.

**Why:** OUT scope. Also: the brainstorms in question (ENG-49,
ENG-52, ENG-94, ENG-95, ENG-97, ENG-98) describe past architectural
decisions where "the previous design assumed Tauri" is a load-bearing
*premise* — silently removing those references would make those
brainstorms unintelligible. The `learned-rules/twinning/`-derived
profile is itself a *Tauri target* profile (the harness's primary
dogfood target); the Tauri tokens there describe an actual real-world
Tauri stack, not a default-assumption.

**Rejected alternative — also sweep docs/brainstorms/ for "ENG-95
removed Tauri shape" residues so the historical paper trail is
"consistent."** Rejected because (a) that's not what the spec asks
for and (b) brainstorms are dated and immutable by convention — they
are read as historical snapshots, not as ongoing documentation. The
right time-stamped frame is "as of 2026-05-13 we documented
post-ENG-92 prose to match post-ENG-92 mechanism," not "we
retroactively rewrote ENG-94's brainstorm."

### D-4: No regression test (no `bin/docs-no-tauri-test.sh`)

**Verdict:** Ship the prose sweep without a doc-content test. AC#1
verification is the one-liner
`grep -i tauri CLAUDE.md README.md docs/install.md docs/assumptions.md docs/configuration.md docs/security.md docs/architecture.md`
returning zero matches — runnable by any reviewer, not gated on CI.

**Why:** The harness has no precedent for a doc-content test today.
`bin/agent-prompts-content-test.sh` exists because `AGENT_PROMPTS.md`
is *executable input* to the dispatch path (the agent reads it
verbatim every tick). CLAUDE.md is prepended to dispatches via
`render-prompt.sh::append_project_profile` (verified — that helper
appends the project profile, not CLAUDE.md; the prepend is actually
the system-reminder block injected by the orchestrator's
`/CLAUDE.md` resolver inside `render-prompt.sh::PROMPT_RESOLVERS`).
Either way, CLAUDE.md is read by humans first and agents second; an
operator reading the file is the highest-fidelity regression detector
already. A `*-test.sh` that greps "no Tauri tokens" risks false-
positives on legitimate two-stack-contrast text (the issue's AC#2
explicitly permits "two-stack contrast pedagogically"), and any
exception list becomes its own maintenance burden.

The 0-Tauri-hit grep is captured in §11 as AC#1's verification step.
A future doc-content-test followup is captured in §10 #2 with
explicit criteria for when it would be worth the maintenance cost
(e.g., if the harness gains 3+ doc-Tauri regressions in subsequent
tickets, the test is justified).

D-4 is a deferral-style decision (declines work). It is recorded as
a numbered slot rather than folded silently into §10 to be honest
that "no test" was a considered choice, not an oversight.

**Rejected alternative — add the test now.** As above; mixing a new
test category (`docs-*-test.sh`) with the sweep doubles the review
surface and risks the false-positive failure mode. Rejected.

## 5. Architecture (where prose goes)

Edits live in seven files. No mechanism changes; no new files; no
test additions; no schema changes.

| File | Sections touched | Decision |
|---|---|---|
| `CLAUDE.md` | line 57 (PATH table row — drop `bun tauri build` parenthetical), 303 with continuation onto 304 (sweep+scope paragraph — rewrite forward-looking), 314-325 (Migration paragraph — delete), 333 area (new "Where stack knowledge lives" callout), 338 ("cargo for Tauri" → "cargo for Rust") | D-1, D-2 |
| `README.md` | lines 38-41 ("If your stack isn't Tauri" block — softened opener + forward-link), 346 ("required for non-Tauri stacks" → operator-curated extras), 417-419 (Stack assumption rewrite — canonical phrasing), 498-501 (supply-chain threat — 4-token enumeration) | D-1 |
| `docs/install.md` | lines 184-187 (Phase 9 → Phase 5b reframe) | D-1 |
| `docs/assumptions.md` | lines 174-185 (entire "Default allowed-tools list is Tauri-shaped" subsection — rewrite as composition + concrete Python `## Tool allowlist` snippet) | D-1 |
| `docs/configuration.md` | lines 155-159 (intro paragraph — canonical phrasing), 214-223 (table rows — implementing + ui both have post-ENG-94 residue; reviewing/qa/building/released verified clean), 228 + body (heading + examples), 285 (heading) | D-1 |
| `docs/security.md` | lines 76, 81, 91 (4-package-manager enumeration: cargo / bun / pip / go; test-runners dropped) | D-1 |
| `docs/architecture.md` | line 74 (diagram cell — add pyproject.toml), new H2 "Discovery and the project profile" after line 45 | D-1, D-2 |

**Line-number caveat.** Per feasibility persona P1 (folded), line
numbers above are time-of-brainstorm snapshots; the implementing
agent MUST `grep` for the literal token text (e.g. `bun tauri build`,
`Default allowed-tools list is Tauri-shaped`) rather than blindly
trusting the line number. Adjacent tickets that land between this
brainstorm and the implement stage may shift the line numbers.

No bash function signatures change. No `bin/*` files are edited. No
`learned-rules/<slug>/project-profile.md` files are edited. No
`docs/brainstorms/`, `docs/plans/`, `docs/demos/` files are edited.

## 6. Data flow

No runtime data flow change. This is pure documentation.

For verification, after the edits:

1. `grep -in tauri CLAUDE.md README.md docs/install.md docs/assumptions.md docs/configuration.md docs/security.md docs/architecture.md`
   should return **0 matches**.
2. `grep -in "Tauri-shaped\|isn't Tauri\|non-Tauri" .` (in-scope files
   only) should return **0 matches**.
3. `grep -in "## Discovery" docs/architecture.md` should return **1
   match** (the new H2 from D-2).
4. `grep -in "Where stack knowledge lives" CLAUDE.md` should return
   **1 match** (the new callout from D-2).
5. The seven edited files all render correctly as markdown (visual
   inspection during PR review).
6. The post-ENG-94 composition order (base + profile + extras) is
   stated *consistently* across CLAUDE.md, README.md,
   docs/assumptions.md, and docs/configuration.md. (Manual review;
   AC#3.)

## 7. Error handling

There is no runtime error path. The risk surface is **prose
correctness**, mitigated by:

- Cross-reference reviewer pass — every claim about a code path
  (e.g. "stack-neutral base + profile-derived + extras") is
  checked against the actual code at the path:line citations in
  §12 Assumption inventory.
- The PR-review human acts as the gate (AC#1 is grep, AC#2-4 are
  prose-review). The umbrella ENG-92 reviewer is the same human who
  reviewed ENG-94/95/97/98 — they have the context to validate that
  the rewrites are accurate.
- If a future ENG-XX adds a new Tauri reference in one of the
  in-scope files, the umbrella's last-pass grep should catch it
  during code review; if it slips through, a followup ticket
  re-sweeps. D-4 captures the "doc-content test is a real followup
  if regressions accumulate" deferral.

## 8. Edge cases

| Case | Behavior |
|---|---|
| A reviewer searches `grep -i tauri` *recursively* (`-r`) and gets hits from `docs/brainstorms/`, `docs/plans/`, `docs/demos/`, `learned-rules/twinning/` | Expected. Those are OUT scope and have legitimate historical / target-profile references. AC#1's grep is on the **in-scope file set**, not recursive. The ACs explicitly allow brainstorm/plan/demo references. |
| A reviewer reads CLAUDE.md and asks "what happens to existing operators with v1 profiles?" | The "Migration from pre-ENG-95" paragraph is deleted by D-1. The fallback contract ("missing profile → stack-neutral fallback + warning") is preserved in the existing "Fallback contract" subsection at CLAUDE.md:352. No regression — the fallback covers the same case the deleted Migration paragraph covered. |
| Two-stack-contrast text in a rewritten section uses "Rust + Bun" — does that count as a Tauri reference? | No. AC#2 explicitly permits "two-stack contrast pedagogically." `Rust + Bun` names two stack ecosystems; it does not imply "Tauri is the default." The brainstorm's rewrites use `cargo / bun / pip / go` (four contrasting tokens) or `Rust / Python / Go` (three), never "Tauri" specifically. |
| A future ticket renames `learned-rules/<slug>/project-profile.md` to a different path | The new CLAUDE.md "Where stack knowledge lives" callout and docs/architecture.md "Discovery and the project profile" section both name the literal path. A rename would need both to be updated; this is a normal docs-maintenance cost. |
| Operator skipping Phase 5b leaves the profile unwritten | The fallback contract (CLAUDE.md:352 "Fallback contract" subsection — unchanged by this ticket) handles this: stack-neutral base + extras, one warning per stage. The docs/architecture.md "Discovery and the project profile" section names this fallback explicitly. |
| A non-Tauri operator (e.g. Python project) reads README.md after the edit | The opening "How it works" section names discovery as the entry point. The Stack assumption (line 417 area, rewritten) does not imply "Tauri default." Operator's mental model is "I run discovery once for my stack" rather than "I edit config.json to override the Tauri default." Aligns with AC#3. |
| The `cargo / bun / pip / go` example list in the security threat-model gets one token wrong (e.g. `npm` swapped with `nodejs`) | Prose-only error. PR review catches it. No runtime impact. |
| The new H2 in docs/architecture.md breaks an existing `<a id="...">` anchor that something else links to | Verified no anchors are removed; the new H2 is *added* between existing sections. Existing anchor `<a id="failure-taxonomy">` at line 235 area is unchanged. |
| A future ENG-XX ticket re-introduces "Tauri-shaped" framing | No automated catch (per D-4). Reviewer pass + umbrella owner's grep is the regression-prevention mechanism. §10 #2 captures the doc-content test as a real followup if this fails. |

## 9. Persona review

This section records the dispatched persona-review pass on this
brainstorm. Six personas (design, security, scope, coherence,
product, feasibility) were dispatched. **Iteration-1 verdict:**
5/6 PASS or PASS-with-CONCERNS, feasibility PASS with 0 P0. The
gate (≥5/6 PASS AND feasibility 0 P0) was met. P1 findings were
folded back into the brainstorm in this revision; the verdicts below
note the fold or acknowledged-but-preserved disposition.

### Persona: design — PASS (0 P0, 2 P1, 1 P2)
- P1 (folded): D-2's CLAUDE.md callout text named
  `render-prompt.sh::append_project_profile` as "prepended to every
  dispatch's prompt" — verb mismatch (the helper is named *append*).
  Folded: §1 now locks "append" as the canonical verb; D-2's
  callout text uses "appends the entire profile to every
  non-retrospective dispatch's prompt." The architecture.md H2 table
  was also reviewed and corrected from "Prepended" to "Appended."
- P1 (folded): coherence persona's "verify other table rows" fold
  was named in the brainstorm but the §5 architecture table only
  enumerated the implementing row's edit. Folded: §5 table now
  explicitly enumerates the docs/configuration.md edit as "lines
  214-223 (table rows — implementing + ui both have post-ENG-94
  residue; reviewing/qa/building/released verified clean)" so the
  implementing agent has a concrete site list.
- P2 (folded): assumption-inventory #1 phrasing implied
  docs/security.md has zero Tauri-literal hits, which is true but
  reads as if the file is out-of-scope for AC#1. Folded: §11 AC table
  now clarifies AC#1 vs AC#2 — docs/security.md edits serve AC#2
  (multi-stack contrast on cargo/bun/npm examples), not AC#1; the
  literal `Tauri` token doesn't appear in docs/security.md today.

### Persona: design — CLAUDE.md:303-304 historical-discoverability concern (preserved)
- The "Migration from pre-ENG-95 (existing Tauri targets)" paragraph
  deletion in D-1 means ENG-95 is no longer named in CLAUDE.md. The
  next operator who searches for "ENG-95" in CLAUDE.md gets zero hits.
  This is **acknowledged-but-preserved**: §10 #3 captures the
  intended discoverability path (brainstorm-filename grep:
  `ls docs/brainstorms/ | grep -i eng-95`). A future "Recent
  architectural tickets" index could be added (also captured in §10
  #3) but is not load-bearing now.

### Persona: security — PASS (0 P0, 0 P1, 2 P2)
- P2 (folded): the proposed docs/security.md:81 enumeration
  included `pytest` and `jq` — but those are test-runners /
  data-processors, NOT package resolvers, so they don't carry
  post-install-script supply-chain risk. Including them in a
  supply-chain-threat enumeration muddies the threat. Folded:
  the §1 canonical phrasing lock for security sites uses the
  4-package-manager list (`cargo / bun / pip / go`); D-1's
  security.md rewrites tightened to that list, dropping pytest/jq.
- P2 (preserved): broadening the threat enumeration from "Tauri
  default" to "any package ecosystem" does NOT understate the risk
  — it more accurately conveys universality (the threat applies
  regardless of stack). Verified: mitigations-in-place (ENG-67
  worktree-not-main-checkout) and mitigations-NOT-in-place (no
  supply-chain isolation, no sandbox) preserved verbatim in the
  rewrites.

### Persona: scope — PASS (0 P0, 1 P1, 1 P2)
- P1 (folded): AC#1-vs-AC#2 clarity for docs/security.md — the
  literal `Tauri` token doesn't appear in security.md today; the
  edits serve AC#2 (multi-stack contrast on cargo/bun/npm). A
  reviewer might assume the security.md edits are AC#1 sweep work
  and be confused. Folded: §11 AC table now annotates which AC each
  file's edits primarily serve. docs/security.md → AC#2; docs/
  install.md → AC#1+AC#3 (the "Tauri" token is at line 184); CLAUDE.md
  → AC#1+AC#3+AC#4; etc.
- P2 (preserved): D-1's CLAUDE.md:314-325 deletion of the "Migration
  from pre-ENG-95" paragraph is the only place crossing from "sweep
  stale framing" into "delete operator-facing content." The fallback
  contract at CLAUDE.md:352-358 covers the same case (verified — see
  Assumption inventory #10), so no operator-facing capability is
  lost. Preserved as-is; the deletion is intentional, not collateral.

### Persona: scope — D-2 H2 scope-creep check (acknowledged-but-preserved)
- D-2's "Discovery and the project profile" H2 in
  docs/architecture.md is a new *positive* documentation section,
  not a sweep. AC#4 ("Discovery flow is described accurately in
  CLAUDE.md and docs/architecture.md") explicitly requires this; the
  H2 is the minimum surface area that satisfies AC#4. The §11 AC
  table annotates AC#4 as a *positive add*, not a *sweep* — both
  shapes belong to this ticket.

### Persona: coherence — PASS (0 P0, 2 P1, 1 P2)
- P1 (folded): multi-stack-contrast tokens were inconsistent across
  D-1 rewrites — README §498-501 used 4 tokens, security.md §81 used
  6 (with `npm` and `pytest`), security.md §76 used 5 (with `Gem`).
  Folded: §1 now locks two canonical lists — **threat / security
  sites** use `cargo / bun / pip / go` (4 package managers,
  test-runners dropped per security persona P2); **build-tool /
  file-name sites** use the same 4-token build-command list or
  `Cargo.toml / package.json / pyproject.toml / ...`. Every D-1
  rewrite was tightened to follow one of those two lists.
- P1 (folded): composition-order terminology drifted across sites
  ("operator-curated extras" vs "operator extras" vs "additions" vs
  "config extras"). Folded: §1 locks the canonical phrase
  **"stack-neutral base + profile-derived stack tools +
  operator-curated extras"**. Every D-1 rewrite uses this verbatim;
  CLAUDE.md, docs/configuration.md, docs/assumptions.md, README.md
  all match.
- P2 (folded): "append" vs "prepend" verb mismatch — D-2's CLAUDE.md
  callout said "prepended" but the architecture.md H2 table said
  "Appended"; the helper is named `append_project_profile`. Folded:
  §1 locks "append" as canonical; both sites now use "append."

### Persona: product — PASS-with-CONCERNS (0 P0, 2 P1, 1 P2)
- P1 (folded): D-2's CLAUDE.md "Where stack knowledge lives"
  paragraph abstracted the discovery flow without grounding a
  non-Tauri operator. A Python/Go operator reading it for the first
  time had no sense of what the profile *looks like*. Folded: the
  docs/assumptions.md rewrite (D-1) now includes a concrete 12-line
  Python `## Tool allowlist` markdown snippet so a new operator sees
  the actual shape. CLAUDE.md and architecture.md keep the abstract
  callout (those are orientation docs); assumptions.md carries the
  concrete example (the right place for it — it's where an operator
  goes when troubleshooting "agent halts with permission denied
  invoking pytest").
- P1 (folded): README.md:38 rewrite packed too much jargon into the
  first ~50 lines ("Phase 5b", "one-shot agent",
  "`learned-rules/<slug>/...`", section list). Folded: D-1's
  README.md:38-41 rewrite now opens with two short sentences ("The
  harness is stack-agnostic. The first-time setup discovers your
  target's stack and writes a per-target profile that the
  orchestrator reads at dispatch time.") and defers the schematics
  to a forward-link at architecture.md "Discovery and the project
  profile."
- P2 (folded): coherence persona's "verify qa/ui table rows" left as
  reviewer-pass TODO rather than committed edit. Folded:
  feasibility persona ran the audit; §5 architecture table now
  enumerates `implementing` + `ui` as residue-bearing rows and
  `reviewing/qa/building/released` as verified clean.

### Persona: feasibility — PASS (0 P0, 1 P1, 2 P2; gating)
- P1 (folded): the brainstorm cites line numbers throughout. Line
  numbers drift as adjacent tickets land. Risk: the implementing-
  stage agent edits the wrong line because the doc has shifted.
  Folded: §5 architecture table's "Line-number caveat" callout now
  explicitly tells the implementing agent to Grep for the literal
  token text (e.g. `bun tauri build`, `Default allowed-tools list
  is Tauri-shaped`) rather than trusting line numbers.
- P2 (folded): the §1 Overview enumerated CLAUDE.md lines as
  "57, 303, 304, 314, 315, 338" but feasibility verified that
  literal `tauri` only matches at 57, 303, 314, 315, 338 (5 hits, not
  6 — line 304 is the wrap of the 303 sentence). Folded: §1 now
  states this precisely as "line 303 with its continuation onto
  304" and the assumption inventory matches.
- P2 (verified): D-2's docs/architecture.md "Discovery and the
  project profile" H2 references three helpers. Feasibility verified
  each (see "Codebase facts spot-verified" below). All names
  resolve.

Codebase facts spot-verified (path:line citations):
  - `bin/dispatch.sh::_dispatch_tools_from_profile`: confirmed at
    `bin/dispatch.sh:318-401`.
  - `bin/dispatch.sh::allowed_tools_for`: confirmed at
    `bin/dispatch.sh:403`.
  - `bin/run-local-helpers.sh::_always_include_paths`: confirmed at
    `bin/run-local-helpers.sh:72-82` (lockfile catalog: bun.lock,
    Cargo.lock, package-lock.json, pyproject.toml, etc.).
  - `bin/run-local-helpers.sh::stage_output_paths`: confirmed at
    `bin/run-local-helpers.sh:264`.
  - `bin/render-prompt.sh::append_project_profile`: confirmed at
    `bin/render-prompt.sh:184`.
  - `bin/setup.sh::phase_project_profile`: confirmed at
    `bin/setup.sh:257`.
  - `bin/setup-prompts/discovery.md`: file exists.
  - `learned-rules/harness/project-profile.md::schema_version: 2`:
    confirmed at `learned-rules/harness/project-profile.md:5`.
  - CLAUDE.md "Fallback contract" subsection at lines 352-358:
    confirmed (8-line span).
  - `docs/architecture.md` has no "discovery" or "project-profile"
    hits today: confirmed via Grep (the new H2 in D-2 is genuinely
    new content).
  - Tauri-residue line numbers in CLAUDE.md (57, 303, 314, 315,
    338): confirmed via Grep — 5 hits, with 303's sentence wrapping
    onto 304 (continuation, not a separate hit).
  - Tauri-residue line numbers in README.md (38, 346, 417,
    498-499): confirmed via Grep.
  - Tauri-residue line numbers in docs/install.md (184),
    docs/assumptions.md (176, 180), docs/configuration.md (159,
    218, 228, 285): confirmed via Grep.
  - docs/security.md and docs/architecture.md contain `cargo/bun/npm`
    examples but no literal `tauri` token; the edits there serve
    AC#2 (multi-stack contrast), not AC#1 (sweep).

No codebase-fact errors. Implementation is feasible as written.

**Status (iteration-1, post-fold):** Personas: 5/6 PASS + 1
PASS-with-CONCERNS (product) · gate P0: 0 · feasibility PASS with
0 P0 · gate met · proceeding to planning.

**Re-verification (this dispatch, 2026-05-14):** Spot-checked every
codebase fact cited in §12. All path:line citations still resolve:
`bin/dispatch.sh::_dispatch_tools_from_profile` at line 318;
`bin/dispatch.sh::allowed_tools_for` at line 403;
`bin/run-local-helpers.sh::_always_include_paths` at line 72;
`bin/run-local-helpers.sh::stage_output_paths` at line 264;
`bin/render-prompt.sh::append_project_profile` at line 184;
`bin/setup.sh::phase_project_profile` at line 257;
`learned-rules/harness/project-profile.md:5` (`schema_version: 2`);
CLAUDE.md:352 "Fallback contract"; docs/architecture.md has no
"discovery" or "project-profile" hits; no `bin/docs-*-test.sh`
exists. Tauri-residue line numbers re-verified in CLAUDE.md (57,
303, 314, 315, 338), README.md (38, 346, 417, 498-499),
docs/install.md (184), docs/assumptions.md (176, 180),
docs/configuration.md (159, 228, 285). Gate remains met. Assumption
#12 upgraded from assumed → verified via direct read of
`bin/setup-prompts/discovery.md`.

## 10. Open questions / out of scope

1. **Profile-derive the PATH augmentation (`bin/run-local.sh:22`).**
   ENG-98 §10 #1 captured this; ENG-99 inherits the deferral. Not in
   scope.
2. **Doc-content test (`bin/docs-no-tauri-test.sh`).** Would lock the
   AC#1 invariant in CI. Deferred per D-4 — re-evaluate if a future
   sweep ticket reveals that doc-Tauri regressions are recurring.
   Specifically: if 3+ ENG-XX tickets in the next ~6 months land
   prose with "Tauri" tokens in the in-scope file set, the test is
   justified.
3. **Brainstorm cross-references to ENG-9X tickets.** The deleted
   "Migration from pre-ENG-95" paragraph in CLAUDE.md (D-1) means
   ENG-95 is no longer named in CLAUDE.md. The intended
   discoverability path is `docs/brainstorms/*.md` filenames
   (`grep -l ENG-95 docs/brainstorms/`), not CLAUDE.md search. If a
   future ticket needs ENG-9X discoverability via CLAUDE.md, a
   "Recent architectural tickets" index could be added — followup.
4. **Operator-resume / migration runbook for adopters mid-rollout.**
   The "Migration from pre-ENG-95" paragraph being deleted assumes
   all existing operators have re-run discovery to populate
   schema_version 2 profiles. If any operator is still on a v1
   profile, the fallback path kicks in (warning + stack-neutral
   base + extras). The docs/runbooks/ index could grow a "post-ENG-92
   migration" note pointing at `bash bin/setup.sh /path
   project-profile`. Followup if needed.
5. **Cross-target consistency: `learned-rules/twinning/project-profile.md`
   is a real Tauri target; its `cargo` / `bun` / `tauri.conf.json`
   tokens are legitimate stack descriptions, not framings to remove.**
   Out of scope per the OUT boundary (`learned-rules/`).

## 11. Acceptance criteria

The Linear issue lists four acceptance criteria. AC#1 / AC#2 / AC#3 /
AC#4 are listed below. AC#5 ("regression test pins AC#1 invariant")
is **NOT added** — per D-4 deliberation, the no-test path is the
chosen trade.

| AC | Source | Verifies | Verification |
|---|---|---|---|
| AC#1 | Linear | `grep -i tauri` over CLAUDE.md, README.md, docs/install.md, docs/assumptions.md, docs/configuration.md, docs/security.md, docs/architecture.md returns zero matches | Run the literal grep command from §6 verification step 1; expect 0 hits |
| AC#2 | Linear | Concrete cargo/bun examples replaced with "your project's package manager" or multi-stack contrast | Manual review of seven files for `cargo / bun / pip / go` style enumerations in security, threat-model, and example sites |
| AC#3 | Linear | Configuration docs reflect post-ENG-94 composition: base + profile-derived + config-extras | Review CLAUDE.md, docs/configuration.md, docs/assumptions.md, README.md — each names all three ingredients consistently |
| AC#4 | Linear | Discovery flow described accurately in CLAUDE.md and docs/architecture.md | docs/architecture.md has a new H2 "Discovery and the project profile"; CLAUDE.md has a new "Where stack knowledge lives" callout |

## 12. Anti-bias checks

### ADR stress test

There is no `docs/knowledge/decisions.md` in the repo (verified —
`ls docs/` returns no `knowledge/` subdir; the architecture-level
docs are `docs/architecture.md`, `docs/assumptions.md`,
`docs/security.md`, `docs/operations.md`, etc.). No accepted ADR
exists for this brainstorm to put pressure on.

The architectural commitments this ticket interacts with:

- **ENG-49's orchestrator-as-source-of-truth.** Reinforced — D-1
  rewrites prose that contradicted this principle into prose that
  describes it.
- **ENG-94's profile-derived dispatch tool list.** Reinforced — D-1
  removes "Tauri-shaped" prose that contradicted the post-ENG-94
  composition; D-2's "Where stack knowledge lives" callout makes
  the profile-as-source-of-truth explicit at the architectural
  orientation layer.
- **ENG-95's profile-derived stage_output_paths.** Reinforced — D-1
  removes "hardcoded Tauri shape" historical phrasing.
- **ENG-97's prompt-side de-Tauri.** Parallel — both tickets fold
  the same principle into different doc surfaces (prompts vs
  operator docs).
- **ENG-98's `bin/run-local.sh` PATH augmentation deferral.**
  Inherited — §10 #1 references the deferral without re-arguing it.
- **ENG-92's umbrella scope.** ENG-99 is named in the umbrella
  ("After T1–T6 land, the docs need a sweep") — this ticket closes
  the umbrella's last task.

No ADR is destabilized. Every architectural commitment is *more*
accurately stated in prose after this ticket than before.

### Simpler-alternative table

| Decision | Simpler alt | Why rejected |
|---|---|---|
| D-1 (manual surgical rewrites) | Automated `sed` replacement | Seven sites need different rewrites depending on context; docs/configuration.md §218 needs content edit (tool list wrong), not word-swap |
| D-1 | Leave docs alone | CLAUDE.md propagates into every dispatch's prompt context; trust cost of stale operator docs is high |
| D-1 | Fold into preceding mechanism PRs (ENG-94/95/97/98) | Spec explicitly sequences this AFTER T1-T6; mixes review surfaces |
| D-2 (new H2 in architecture.md + callout in CLAUDE.md) | New `docs/discovery.md` file | Existing architecture.md covers analogous flows as H2 sections, not separate files; new H2 matches convention |
| D-2 | Describe discovery only in docs/install.md Phase 5b | AC#4 explicitly names CLAUDE.md and architecture.md; install.md is runbook, not orientation |
| D-3 (preserve brainstorms) | Sweep brainstorms too for "ENG-95 removed Tauri shape" residues | Brainstorms are dated immutable snapshots; rewriting erases decision trail |
| D-4 (no doc-content test) | Add `bin/docs-no-tauri-test.sh` | No precedent for doc-content tests; false-positive risk on legitimate two-stack contrasts; grep one-liner suffices for now |

### Assumption inventory

| # | Assumption | Status | Evidence |
|---|---|---|---|
| 1 | `grep -in tauri CLAUDE.md README.md docs/install.md docs/assumptions.md docs/configuration.md docs/security.md docs/architecture.md` returns matches at CLAUDE.md:57,303,314,315,338; README.md:38,346,417; docs/install.md:184; docs/assumptions.md:176,180; docs/configuration.md:159,228,285; docs/security.md (none — `cargo/bun/npm` only); docs/architecture.md (none — `Cargo.toml/package.json` only). | verified | Grep output ran during brainstorm authoring; full output reproduced in §1 Overview |
| 2 | `bin/dispatch.sh::_dispatch_tools_from_profile` exists and resolves profile-derived stack tools | verified | `bin/dispatch.sh:318-401` (function definition + schema-gate + section-gate + extraction awk + emit) |
| 3 | `bin/dispatch.sh::allowed_tools_for` composes base + profile + extras | verified | `bin/dispatch.sh:403-...` (case arms per stage; profile call at composition tail) |
| 4 | `bin/run-local-helpers.sh::_always_include_paths` is a stack-agnostic lockfile catalog | verified | `bin/run-local-helpers.sh:72-82` (catalog of `Cargo.lock`, `package-lock.json`, `bun.lock`, `poetry.lock`, `go.sum`, etc.) |
| 5 | `bin/run-local-helpers.sh::stage_output_paths` reads `## File layout` section from profile + always-include catalog | verified | `bin/run-local-helpers.sh:300-302` (concatenates `_always_include_paths` after profile-derived list); ENG-95 brainstorm + landed commit |
| 6 | `bin/setup.sh` has a `phase_project_profile` (Phase 5b) that authors `learned-rules/<slug>/project-profile.md` via discovery agent | verified | `bin/setup.sh:252-360` (phase function definition); `bin/setup-prompts/discovery.md` exists |
| 7 | `learned-rules/<slug>/project-profile.md` schema_version is currently `2` (post-ENG-93) | verified | `learned-rules/harness/project-profile.md:5` (frontmatter `schema_version: 2`) |
| 8 | docs/architecture.md has no existing H2 named "Discovery" or referencing the project profile flow end-to-end | verified | `grep -n -E "discovery\|profile" docs/architecture.md` returns no hits |
| 9 | CLAUDE.md has no existing "Where stack knowledge lives" callout — only the consumer-side "Per-target dispatch.tools extras and profile-derived tools" section | verified | `grep -n "Where stack" CLAUDE.md` returns no hits; the existing §"Per-target dispatch.tools extras" is at line 335 |
| 10 | The fallback contract ("missing-or-malformed profile → stack-neutral base + extras + warning, no `die`") is documented at CLAUDE.md:352-358 (subsection "Fallback contract") | verified | CLAUDE.md:352-358 read directly |
| 11 | `bin/render-prompt.sh::append_project_profile` is the helper that appends the project profile to every non-retrospective dispatch's prompt | verified | Cross-referenced in CLAUDE.md:336-339 ("base — profile — extras" composition); existence pattern confirmed in ENG-97 brainstorm cross-ref |
| 12 | The discovery prompt at `bin/setup-prompts/discovery.md` elicits Stack, File layout, Build & test gates, Tool allowlist, Language idioms, Don'ts | verified | `bin/setup-prompts/discovery.md` emits H2 sections at lines 42 (`## Stack`), 46 (`## Build & test gates`), 53 (`## Tool allowlist`), 72 (`## File layout`), 77 (`## Language idioms`), 81 (`## Don'ts`) — all six profile sections present |
| 13 | `learned-rules/twinning/project-profile.md` exists as the dogfood Tauri target and is OUT of scope | verified | OUT scope boundary names `learned-rules/`; the harness has two slugs (`harness/`, `twinning/`) |
| 14 | `bin/reconcile.sh` accepts `linear: ENG-99` frontmatter as canonical-doc claim | verified | CLAUDE.md §"Linear conventions the harness depends on" ("Doc-to-issue ownership is YAML frontmatter, not prose") |
| 15 | The basename of this brainstorm doc literally contains `eng-99` (case-insensitive token required by `partition_dirty_paths::D-004`) | verified | filename starts with `2026-05-13-eng-99-…` |
| 16 | The Linear-issue spec's line numbers (CLAUDE.md 262-263) do not match the current worktree's actual Tauri residues (57, 303-304, 314-315, 338) | verified | Grep against current worktree; §1 Overview documents this drift explicitly |
| 17 | The ticket OUT boundary excludes `docs/brainstorms/`, `docs/plans/`, `docs/demos/`, `learned-rules/` | verified | Linear-issue body, "Scope Boundaries" section |
| 18 | AC#2 explicitly permits "two-stack contrast pedagogically" | verified | Linear-issue body, AC2 |
| 19 | The harness has no doc-content test today (no `docs-*-test.sh` in `bin/`) | verified | `ls bin/docs-*-test.sh` returns no files |
| 20 | `bin/agent-prompts-content-test.sh` is the precedent for content-invariant tests on doc-shaped files | verified | `bin/agent-prompts-content-test.sh` exists; pattern documented at CLAUDE.md:96-107 |

All 20 assumptions are now verified against the current code with
path:line citations. No "assumed" entries remain. No "claimed but
unchecked" entries.
