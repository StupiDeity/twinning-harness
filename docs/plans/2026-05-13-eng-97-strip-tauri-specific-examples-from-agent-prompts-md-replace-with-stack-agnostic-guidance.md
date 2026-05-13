---
linear: ENG-97
date: 2026-05-13
topic: AGENT_PROMPTS.md prompt-side de-Tauri-ing — replace api-contract Example 1 with gRPC, route 6 other Tauri references through the profile addendum, invert + extend bin/agent-prompts-content-test.sh
---

# Plan — ENG-97 Strip Tauri-specific examples from AGENT_PROMPTS.md, replace with stack-agnostic guidance

Implementation plan for the design at
`docs/brainstorms/2026-05-13-eng-97-strip-tauri-specific-examples-from-agent-prompts-md-replace-with-stack-agnostic-guidance-design.md`.

## Anti-anchoring check

- **Problem (operator's words).** `AGENT_PROMPTS.md` carries Tauri-specific
  code-shape illustrations in seven sites that ship in every non-retrospective
  stage's rendered prompt. The per-target project profile (appended by
  `bin/render-prompt.sh::append_project_profile` at
  `bin/render-prompt.sh:184-210`) already supplies stack context, so the
  hardcoded Tauri examples are redundant for Tauri targets and misleading
  for non-Tauri targets.
- **Brainstorm addresses it?** Yes — D-1 through D-7 cover the seven sites,
  D-8 covers the test surface. The brainstorm's verdicts are concrete
  enough that this plan is mechanical translation of edits + test changes.
  No reframe; no scope creep.
- **Proportional?** Yes. Two files touched (`AGENT_PROMPTS.md` and
  `bin/agent-prompts-content-test.sh`); zero new files; zero schema
  changes; zero new exit codes; zero new lane fences. The Linear issue's
  scope says "AGENT_PROMPTS.md only" — AC#2 adds the test file.
- **No escalation. PROCEED.**

## Branch-base freshness

`git log --oneline HEAD..origin/main` is empty at plan time
(`origin/main = 343457c`; `HEAD = 9fc86ba chore(pipeline): brainstorming
for ENG-97`). No rebase task; no upstream conflict in any of the modified
files.

## Goal

After implement runs, `grep -nE 'Tauri|tauri\.conf\.json|src-tauri/|cargo test -- --list|invoke\(' AGENT_PROMPTS.md`
returns zero matches, the api-contract block at §2 still carries two
illustrative shapes (one compiled-IPC = gRPC + protobuf, one HTTP-handler
= Python/Flask, neither naming Tauri), and `bash bin/agent-prompts-content-test.sh`
exits 0 with the inverted §2 assertion + new global negative-grep + new
positive gRPC-marker pin all passing. `bash bin/render-prompt-test.sh`
continues to pass (§2's column-0 fence count stays exactly 2).

Verifiable by:

```
grep -F 'Tauri'                AGENT_PROMPTS.md
grep -F 'tauri::'              AGENT_PROMPTS.md
grep -F 'tauri.conf.json'      AGENT_PROMPTS.md
grep -F 'src-tauri/'           AGENT_PROMPTS.md
grep -F 'cargo test -- --list' AGENT_PROMPTS.md
grep -F 'invoke('              AGENT_PROMPTS.md
```

each returning zero matches, AND

```
bash bin/agent-prompts-content-test.sh \
  && bash bin/render-prompt-test.sh \
  && bash .githooks/pre-commit
```

exiting 0.

## Assumption Inventory

Every modified-file fact below is `path:line`-cited against the current
worktree. Quoted excerpts are exact substrings to preserve in
`Edit::old_string` calls.

### Files modified in this plan: 2

- `AGENT_PROMPTS.md` (seven edit sites — D-1..D-7)
- `bin/agent-prompts-content-test.sh` (three changes — D-8: invert §2
  Tauri assertion, add global negative-grep, add positive gRPC pin)

### Branch-base freshness note

- branch-base freshness: HEAD..origin/main empty at plan time
  (origin/main = 343457c).

### Modified-file facts — current state and verification points

- **A-001 — `AGENT_PROMPTS.md:458` intro prose mentions Tauri/Python-Flask
  examples.** Verified by direct read. Excerpt:
  > "...Below are two illustrative examples (Tauri v2 + TypeScript for a
  > compiled-IPC stack, Python/Flask + TypeScript for an HTTP-handler
  > stack) — adapt to your project profile:"

  Edit target: replace "Tauri v2 + TypeScript for a compiled-IPC stack"
  with "a compiled-IPC stack (illustrated below with gRPC + protobuf)".
  Content anchor: this is the prose line immediately BEFORE the indented
  `    \`\`\`api-contract` fence (one paragraph above; same line in §2's
  intro section).

- **A-002 — `AGENT_PROMPTS.md:460-477` carries Example 1 (Tauri v2 +
  TypeScript) inside the column-4 indented `api-contract` fence.**
  Verified by direct read. Lines 460-477 are the region from the opening
  `    \`\`\`api-contract` through the `    # ---` separator. Full
  current content:

  ```
      ```api-contract
      # === Example 1 — Tauri v2 + TypeScript (compiled-IPC stack) ===

      # Backend signatures (path per the profile's File layout)
      #[tauri::command]
      async fn foo(x: i64, y: String) -> Result<FooResponse, String>;

      # Backend types (module paths)
      struct FooResponse { id: String, items: Vec<FooItem> }
      struct FooItem     { name: String, score: f64 }

      # Emitted events (where applicable to your stack)
      event "foo:progress" { step: u32, total: u32 }

      # Frontend types (path per the profile's File layout)
      export type FooResponse = { id: string; items: FooItem[] };
      export type FooItem     = { name: string; score: number };

      # ---
  ```

  Replacement scope: Example 1 body (the lines between the opening
  ` ```api-contract ` fence and the ` # --- ` separator). Example 2 at
  lines 479-495 is preserved verbatim. The column-4 indentation of both
  fences (lines 460 and 495) is preserved so `bin/render-prompt.sh:111`'s
  exactly-2-column-0-fences check stays at 2.

- **A-003 — `AGENT_PROMPTS.md:782` carries the `invoke()` parenthetical in
  §3.** Verified by direct read. Exact substring to find:
  > "For every frontend call (e.g. `invoke(\"cmd_x\", …)` on Tauri stacks, `fetch(\"/api/foo\")` on REST stacks) you are about to write,"

  This line is unique within §3 (verified by Grep on the file).

- **A-004 — `AGENT_PROMPTS.md:1134` carries the Tauri/REST/RPC enumeration
  in §6.** Verified by direct read. Exact substring:
  > "    - a new FE↔BE handler / endpoint (e.g. Tauri command, REST handler, RPC method),"

  Leading 4-space indent preserved on the replacement (the surrounding
  bullet list at lines 1133-1137 is 4-indented).

- **A-005 — `AGENT_PROMPTS.md:1162` carries the `cargo test -- --list`
  example in §6.** Verified by direct read. Current line (multi-line
  paragraph spanning ~1161-1162):
  > "   For every new code path identified above, grep the test tree (use the discovery tools appropriate to the profile's stack — e.g. \`cargo test -- --list\` for Rust, test-file globbing per the profile's File layout) for a test that names the path directly"

  Replacement scope: the parenthetical between "(use" and "for a test".

- **A-006 — `AGENT_PROMPTS.md:1406` carries `tauri.conf.json` in §7's
  config-file scan list.** Verified by direct read. Excerpt of lines
  1404-1408:
  > "    - Any change to runtime configuration files named in the profile (examples\n      include \`next.config.js\`, \`Caddyfile\`, \`nginx.conf\`, \`tauri.conf.json\`,\n      \`pyproject.toml\`, \`go.mod\`): scan for new hosts, new bundle identifiers,\n      changed security policies."

  Edit drops the literal `\`tauri.conf.json\`, ` token (with trailing
  comma and space) so the surrounding list reads `\`nginx.conf\`,\n      \`pyproject.toml\`, \`go.mod\``.
  The existing positive assertion at `bin/agent-prompts-content-test.sh:158-164`
  asserts only `pyproject.toml` and `go.mod`; this drop does not break it.

- **A-007 — `AGENT_PROMPTS.md:1603-1607` carries the Tauri dual-manifest
  example in §8.** Verified by direct read. Current paragraph:
  > "6. **Manifest version drift audit** (known issue to track, not fix):\n     - Some stacks track version in multiple manifests (e.g. Tauri tracks both\n       \`package.json\` and \`src-tauri/Cargo.toml\`). Check whether the secondary manifests\n       named in the Project profile addendum match {version}."

  Replacement scope: the bullet at lines 1604-1606 (the "e.g. Tauri
  tracks both…" parenthetical and the sentence ending in `match
  {version}.`). Adjacent lines (1603 heading + 1607 onward) are preserved.

- **A-008 — `AGENT_PROMPTS.md:1722-1725` lists `src-tauri/src/` in §9's
  human-override path list.** Verified by direct read. Current text:
  > "5. **Human-override analysis:**\n   - For each file under \`docs/brainstorms/\`, \`docs/plans/\`, \`crates/*/\`, \`src/\`, and\n     \`src-tauri/src/\` modified by a human commit AFTER a bot commit on the same file\n     within this period: diff the human version against the bot version."

  Replacement scope: the path enumeration (`\`crates/*/\`, \`src/\`, and \`src-tauri/src/\``
  → "the code-bearing directories declared in the per-target
  `learned-rules/<slug>/project-profile.md::## File layout` section").
  §9 is the retrospective stage — the profile addendum is NOT auto-appended
  here (verified at `bin/render-prompt.sh:187-190`:
  `if [[ "$stage" == "retrospective" ]]; then cat; return 0; fi`).
  Phrasing therefore points at the profile FILE PATH directly so the
  retrospective agent can `Read` it (the retrospective has `Read` in
  the implicit base toolset per the harness profile addendum's "Stage-
  agnostic core tools" comment).

- **A-009 — `bin/agent-prompts-content-test.sh:120-130` is the existing
  ENG-52 §2 positive Tauri + non-Tauri assertion block.** Verified by
  direct read:

  ```bash
  # ─── ENG-52: §2 has BOTH a Tauri AND a non-Tauri api-contract example ───
  if printf '%s\n' "$s2" | grep -qF '#[tauri::command]'; then
    ok "§2 preserves Tauri api-contract example (#[tauri::command])"
  else
    nope "§2 preserves Tauri api-contract example (#[tauri::command])" "phrase missing"
  fi
  if printf '%s\n' "$s2" | grep -qF '@app.route'; then
    ok "§2 contains non-Tauri (Python/Flask) api-contract example (@app.route)"
  else
    nope "§2 contains non-Tauri (Python/Flask) api-contract example (@app.route)" "phrase missing"
  fi
  ```

  D-8 step 1 inverts the §2 Tauri-positive (lines 121-125) to a §2
  Tauri-negative; the `@app.route` positive (lines 126-130) is preserved.
  D-8 step 3 adds a positive `service FooService` (gRPC) pin in §2
  immediately after the inverted assertion (replacing what the Tauri
  positive used to guard).

- **A-010 — `bin/agent-prompts-content-test.sh:184-190` pins §2 column-0
  fence count to exactly 2.** Verified by direct read:

  ```bash
  fence_count_s2="$(printf '%s\n' "$s2" | grep -c '^```' || true)"
  if [[ "$fence_count_s2" == "2" ]]; then
    ok "§2 column-0 fence count is exactly 2 (api-contract example stays indented)"
  else
    nope "§2 column-0 fence count is exactly 2 (api-contract example stays indented)" \
         "got $fence_count_s2 column-0 fences in §2 body — render-prompt.sh::extract_block requires exactly 2"
  fi
  ```

  This assertion is preserved verbatim — D-1's gRPC replacement keeps the
  same column-4 indented fence pair as the Tauri original.

- **A-011 — `bin/agent-prompts-content-test.sh:158-164` pins `pyproject.toml`
  and `go.mod` in §7's config-scan list.** Verified by direct read:

  ```bash
  if printf '%s\n' "$s7" | grep -qF 'pyproject.toml' \
     && printf '%s\n' "$s7" | grep -qF 'go.mod'; then
    ok "§7 config-scan list contains non-Tauri examples (pyproject.toml, go.mod)"
  else
    nope "§7 config-scan list contains non-Tauri examples (pyproject.toml, go.mod)" \
         "either 'pyproject.toml' missing OR 'go.mod' missing from §7's body"
  fi
  ```

  D-5 only drops `tauri.conf.json` from the list; `pyproject.toml` and
  `go.mod` are preserved, so this assertion continues to pass without
  edit. The Tauri-mentioning comment at line 155 ("Tauri-only list")
  is descriptive prose only — not an assertion — and is dropped /
  rephrased as part of D-8 housekeeping (see Task 8 step 8.4).

- **A-012 — `bin/agent-prompts-content-test.sh:1-15` is the test
  scaffold; `PROMPTS="$HARNESS_ROOT/AGENT_PROMPTS.md"` is the load-bearing
  path used by every assertion.** Verified by direct read. The new
  global negative-grep in D-8 step 2 uses the same `PROMPTS` variable
  (whole-file scan, not section-scoped) so it catches any forbidden
  token regardless of section.

- **A-013 — `bin/render-prompt.sh:111` requires section fence count == 2,
  else `die`.** Verified by direct read. This is the upstream invariant
  that A-010's localized §2 fence-count assertion backstops. The gRPC
  replacement preserves the column-4 indentation pair, so the upstream
  die does not fire.

- **A-014 — `bin/render-prompt.sh:187-190` SKIPS the profile-addendum
  append for `stage="retrospective"`.** Verified by direct read:

  ```bash
  if [[ "$stage" == "retrospective" ]]; then
    cat
    return 0
  fi
  ```

  This is the carve-out D-7 routes around: the retrospective phrasing
  names the profile FILE PATH rather than "the addendum below" because
  the retrospective does not receive the auto-append.

- **A-015 — `bin/render-prompt-test.sh` does NOT pin any Tauri-specific
  content** (verified by `Grep` for `Tauri|tauri` on the file — zero
  matches). So D-1..D-7 do not require any edit to `bin/render-prompt-test.sh`.

- **A-016 — Test-gate closure sweep over `bin/*-test.sh` for the five
  forbidden tokens** (`Tauri|tauri::|tauri\.conf|src-tauri|cargo test -- --list|invoke\(`):

  | File | Matches | In scope? |
  |---|---|---|
  | `bin/agent-prompts-content-test.sh` | lines 120, 121, 122, 124, 127, 129, 155, 160, 162 | YES — D-8 owns this file |
  | `bin/profile-allowlist-test.sh` | lines 7, 19, 114 — **prose comments only** describing the test's historical context ("Tauri-shaped list"), not assertions on `AGENT_PROMPTS.md` content | NO — these are header comments on a different subsystem's test (ENG-51's profile-driven scope), not test-gate-closure overlap. The comments document why the test exists and would remain accurate after ENG-97 (the legacy Tauri-shaped fallback list still exists in `bin/run-local-helpers.sh` until ENG-95 lands separately). Out of scope per the brainstorm §10 "Out of scope" — `bin/run-local-helpers.sh::stage_output_paths` is ENG-95. |
  | `bin/phase-project-profile-test.sh` | line 111 — `Tauri v2 + SvelteKit.` is a test fixture body (a stubbed profile.md `## Stack` value used to test the discovery agent's profile renderer) | NO — fixture content, not an `AGENT_PROMPTS.md` assertion. Profile fixtures naming Tauri are correct (Tauri targets exist; the harness still serves them via `learned-rules/twinning/project-profile.md`). |
  | `bin/dispatch-test.sh` | lines 2193, 2209, 2212, 2227, 2272-2286 — ENG-94 "Tauri profile (back-compat)" fixture group | NO — fixture content stubbing a Tauri profile.md, asserting that `_dispatch_tools_from_profile` returns `Bash(cargo:*),Bash(bun:*),Bash(rustc:*)` when the profile names them. Unrelated to `AGENT_PROMPTS.md` content. Preserving the fixture is correct (Tauri targets still need cargo/bun via profile). |
  | `bin/render-prompt-test.sh` | zero | NO — see A-015 |

  **Conclusion:** the only test file with closure overlap on `AGENT_PROMPTS.md`
  token removals is `bin/agent-prompts-content-test.sh`, which is in
  scope per D-8. No other test file needs editing.

- **A-017 — `.githooks/pre-commit` runs `bin/agent-prompts-content-test.sh`
  as part of the suite** (verified by `CLAUDE.md::Pre-commit hook`
  section). The implement agent's pre-commit gate runs this test
  automatically; any forbidden-token regression after this PR fires the
  negative-grep and blocks the commit.

- **A-018 — gRPC + protobuf replacement body contains none of the five
  forbidden tokens.** Verified by inspection of the proposed body in
  Task 1 below: `service FooService { rpc GetFoo (FooRequest) returns
  (FooResponse); }`, `message FooRequest`, `int64`, `double`,
  `string`, `repeated FooItem` — none match `Tauri`, `tauri::`,
  `tauri.conf.json`, `src-tauri/`, `cargo test -- --list`, or
  `invoke(` as literal substrings.

## File Structure

Modified files only — no new files, no new test scripts, no new
dependencies.

- `AGENT_PROMPTS.md` — seven edit sites (D-1..D-7): §2 api-contract intro
  prose + Example 1 body, §3 invoke() parenthetical, §6 bullet line 1134,
  §6 paragraph line 1162, §7 config-list line 1406, §8 dual-manifest
  bullet lines 1604-1606, §9 path-list lines 1723-1724. No section
  renames; no fence count changes; no `STAGE_TO_SECTION` impact.
- `bin/agent-prompts-content-test.sh` — three changes (D-8): invert §2
  Tauri-positive at lines 120-125 to a §2 Tauri-negative; add a global
  negative-grep block after line 130 covering the five forbidden tokens
  (one assertion per token, six total — `Tauri`, `tauri::`,
  `tauri.conf.json`, `src-tauri/`, `cargo test -- --list`, `invoke(`);
  add a positive `service FooService` gRPC-marker pin in §2 right after
  the inverted assertion. The ENG-52-era comment at line 155
  ("Tauri-only list") is rephrased to drop the `Tauri-only` qualifier.

Out of scope (explicit per brainstorm §10 + Linear issue's `OUT:` clause):

- `bin/dispatch.sh` — ENG-94 (landed at `343457c`).
- `bin/run-local-helpers.sh::stage_output_paths` — ENG-95.
- `bin/scope-check.sh` — separate ticket on the ENG-92 umbrella.
- `bin/render-prompt.sh` — unchanged; the existing
  `append_project_profile` mechanism is the contract this ticket relies on.
- `CLAUDE.md` — already stack-neutral after ENG-95's doc pass.
- Historical docs under `docs/brainstorms/` mentioning Tauri — the
  negative-grep is scoped to `AGENT_PROMPTS.md` only; historical brainstorm
  files (e.g. `docs/brainstorms/2026-05-02-eng-52-...md`) keep their Tauri
  references because they describe a predecessor state.

## API Contract

no new API surface

(The harness has no FE↔BE surface of its own — it is a bash orchestration
toolkit. The `api-contract` block being edited LIVES INSIDE
`AGENT_PROMPTS.md` as illustrative prompt content for the Plan agent's
output schema; it is not the harness's own API. The edit is a
content-of-prompt change, not an API change.)

## Backend Tasks

Each edit is independent of the others in terms of content anchor — every
Edit step names a distinctive multi-line `old_string` so the edits do not
collide and can be applied in any order. Task 8 (test changes) depends on
Tasks 1-7 because its assertions verify the prompt changes landed.

The implement agent SHOULD apply Tasks 1-7 first (in any order — the
content anchors do not overlap), then Task 8, then run the gate suite.

### Task 1: Replace AGENT_PROMPTS.md §2 api-contract Example 1 with gRPC + protobuf (D-1)

- `depends_on: []`
- `touches: AGENT_PROMPTS.md` — §2 intro prose at line 458, §2
  api-contract Example 1 body inside the indented fence (lines 460-477)

Steps:

- [ ] **1.1** Edit `AGENT_PROMPTS.md` intro prose immediately preceding
  the api-contract fenced block.
  Content anchor (unique substring): `"Below are two illustrative examples (Tauri v2 + TypeScript for a compiled-IPC stack, Python/Flask + TypeScript for an HTTP-handler stack) — adapt to your project profile:"`.
  Replace with: `"Below are two illustrative examples (one compiled-IPC stack illustrated with gRPC + protobuf, one HTTP-handler stack illustrated with Python/Flask + TypeScript) — adapt to your project profile:"`.
  Verification: the replacement contains no `Tauri` substring; the
  containing line is unique in the file (grep before edit if needed).

- [ ] **1.2** Edit `AGENT_PROMPTS.md` Example 1 body. Use a single `Edit`
  call with multi-line `old_string` anchored on the unique opening
  `    # === Example 1 — Tauri v2 + TypeScript (compiled-IPC stack) ===`
  and unique closing `    # ---` separator (the column-4 indentation +
  the unique `Example 1` token + the unique separator make this region
  unambiguous within the file).
  Old string (column-4 indented, includes the leading blank line after
  the fence and the trailing `    # ---` separator):

  ```
      # === Example 1 — Tauri v2 + TypeScript (compiled-IPC stack) ===

      # Backend signatures (path per the profile's File layout)
      #[tauri::command]
      async fn foo(x: i64, y: String) -> Result<FooResponse, String>;

      # Backend types (module paths)
      struct FooResponse { id: String, items: Vec<FooItem> }
      struct FooItem     { name: String, score: f64 }

      # Emitted events (where applicable to your stack)
      event "foo:progress" { step: u32, total: u32 }

      # Frontend types (path per the profile's File layout)
      export type FooResponse = { id: string; items: FooItem[] };
      export type FooItem     = { name: string; score: number };

      # ---
  ```

  Replacement (preserves column-4 indentation and the trailing `# ---`
  separator so Example 2 below stays untouched):

  ```
      # Choose your stack: render the contract per the project profile's Stack section.

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

      # ---
  ```

  Notes:
  - Both fences (the opening `    \`\`\`api-contract` at line 460 and
    the closing `    \`\`\`` at line 495) remain column-4 indented;
    `bin/render-prompt.sh::extract_block`'s column-0 fence count for §2
    stays at exactly 2.
  - The brainstorm OQ-2 resolution placed `Choose your stack:` as a
    comment line INSIDE the fence — adopted here as the first content
    line of Example 1's region.
  - The brainstorm OQ-1 resolution used protobuf types (`int64`,
    `double`) on the wire and TypeScript types (`number`, `string`) on
    the frontend — adopted.
  - The brainstorm OQ-5 resolution dropped the streaming-RPC variant —
    adopted; no `rpc StreamFoo` shape included.

- [ ] **1.3** Verify by reading back `AGENT_PROMPTS.md:455-500` after
  the two edits. Confirm: (a) Example 2 lines 479-495 are unchanged;
  (b) no `Tauri`, `tauri::`, or `#[tauri::` substring remains in §2;
  (c) `service FooService`, `rpc GetFoo`, `message FooRequest` all
  appear in §2's body; (d) §2 column-0 fence count is exactly 2
  (`bash bin/agent-prompts-content-test.sh` will assert this at line
  184-190).

### Task 2: Edit AGENT_PROMPTS.md §3 invoke() parenthetical (D-2)

- `depends_on: []`
- `touches: AGENT_PROMPTS.md` — §3 line 782

Steps:

- [ ] **2.1** Edit `AGENT_PROMPTS.md` §3 precondition paragraph at line 782.
  Content anchor (unique substring within file):
  `For every frontend call (e.g. \`invoke("cmd_x", …)\` on Tauri stacks, \`fetch("/api/foo")\` on REST stacks) you are about to write,`.
  Replace with:
  `For every frontend→backend call (the canonical client-call idiom for your stack is named in the Project profile addendum's Stack / Language idioms section) you are about to write,`.

- [ ] **2.2** Verify by reading back the line; confirm no `invoke(`
  substring remains in §3.

### Task 3: Edit AGENT_PROMPTS.md §6 line 1134 Tauri enumeration (D-3)

- `depends_on: []`
- `touches: AGENT_PROMPTS.md` — §6 line 1134

Steps:

- [ ] **3.1** Edit `AGENT_PROMPTS.md` §6 "new code path" bullet.
  Content anchor (unique substring):
  `    - a new FE↔BE handler / endpoint (e.g. Tauri command, REST handler, RPC method),`.
  Replace with:
  `    - a new FE↔BE handler / endpoint (the profile names the handler-attribute or route-binding shape for your stack),`.
  Preserve the leading 4-space indent (matches the surrounding bullet
  list at lines 1133-1137).

- [ ] **3.2** Verify by reading back §6 lines 1130-1140; confirm no
  `Tauri command` substring remains.

### Task 4: Edit AGENT_PROMPTS.md §6 line 1161-1162 cargo test --list (D-4)

- `depends_on: []`
- `touches: AGENT_PROMPTS.md` — §6 paragraph spanning lines ~1161-1162

Steps:

- [ ] **4.1** Edit `AGENT_PROMPTS.md` §6 "Coverage audit" paragraph.
  Content anchor (unique multi-line substring):

  ```
     For every new code path identified above, grep the test tree (use the discovery tools appropriate to the profile's stack — e.g. `cargo test -- --list` for Rust, test-file globbing per the profile's File layout) for a test that names the path directly (function name, handler name, or component name). Missing → P0.
  ```

  Replace with:

  ```
     For every new code path identified above, grep the test tree (use the stack's test-discovery idiom — the profile's `Build & test gates` section names the canonical command, and `File layout` names the test-file roots) for a test that names the path directly (function name, handler name, or component name). Missing → P0.
  ```

- [ ] **4.2** Verify by reading back §6 lines 1158-1165; confirm no
  `cargo test -- --list` substring remains.

### Task 5: Edit AGENT_PROMPTS.md §7 line 1406 tauri.conf.json drop (D-5)

- `depends_on: []`
- `touches: AGENT_PROMPTS.md` — §7 line 1406

Steps:

- [ ] **5.1** Edit `AGENT_PROMPTS.md` §7 config-file scan list.
  Content anchor (unique multi-line substring spanning lines 1405-1407):

  ```
      - Any change to runtime configuration files named in the profile (examples
        include `next.config.js`, `Caddyfile`, `nginx.conf`, `tauri.conf.json`,
        `pyproject.toml`, `go.mod`): scan for new hosts, new bundle identifiers,
  ```

  Replace with (drops the `\`tauri.conf.json\`, ` token, re-wraps so the
  list reads naturally on two lines):

  ```
      - Any change to runtime configuration files named in the profile (examples
        include `next.config.js`, `Caddyfile`, `nginx.conf`, `pyproject.toml`,
        `go.mod`): scan for new hosts, new bundle identifiers,
  ```

- [ ] **5.2** Verify: read back §7 lines 1400-1412; confirm no
  `tauri.conf.json` substring remains. The existing positive assertion at
  `bin/agent-prompts-content-test.sh:158-164` (pyproject.toml + go.mod)
  continues to pass — both tokens are preserved.

### Task 6: Edit AGENT_PROMPTS.md §8 dual-manifest example (D-6)

- `depends_on: []`
- `touches: AGENT_PROMPTS.md` — §8 lines 1604-1606

Steps:

- [ ] **6.1** Edit `AGENT_PROMPTS.md` §8 manifest-drift bullet.
  Content anchor (unique multi-line substring at lines 1604-1606):

  ```
       - Some stacks track version in multiple manifests (e.g. Tauri tracks both
         `package.json` and `src-tauri/Cargo.toml`). Check whether the secondary manifests
         named in the Project profile addendum match {version}.
  ```

  Replace with:

  ```
       - Some stacks track version in multiple manifests (e.g. a workspace + per-package
         manifest pair: a top-level `package.json` plus a sub-crate or sub-package manifest,
         or a monorepo root + child manifests). The Project profile addendum names the
         canonical and secondary manifests for this target; check whether the secondary
         manifests match {version}.
  ```

  Preserve the leading 5-space indent (matches the surrounding ordered-list
  bullet style at lines 1603-1610).

- [ ] **6.2** Verify by reading back §8 lines 1600-1615; confirm no
  `Tauri tracks` or `src-tauri/` substring remains.

### Task 7: Edit AGENT_PROMPTS.md §9 src-tauri/src/ path list (D-7)

- `depends_on: []`
- `touches: AGENT_PROMPTS.md` — §9 lines 1722-1725

Steps:

- [ ] **7.1** Edit `AGENT_PROMPTS.md` §9 "Human-override analysis" bullet.
  Content anchor (unique multi-line substring at lines 1722-1725):

  ```
  5. **Human-override analysis:**
     - For each file under `docs/brainstorms/`, `docs/plans/`, `crates/*/`, `src/`, and
       `src-tauri/src/` modified by a human commit AFTER a bot commit on the same file
       within this period: diff the human version against the bot version.
  ```

  Replace with:

  ```
  5. **Human-override analysis:**
     - For each file under `docs/brainstorms/`, `docs/plans/`, and the code-bearing
       directories declared in the per-target `learned-rules/<slug>/project-profile.md`'s
       `## File layout` section, modified by a human commit AFTER a bot commit on the same
       file within this period: diff the human version against the bot version.
  ```

  Phrasing rationale (per brainstorm D-7 / OQ-3): the retrospective stage
  is the only stage whose dispatched prompt does NOT receive the
  appended profile addendum (verified at `bin/render-prompt.sh:187-190`),
  so the bullet names the profile file PATH directly rather than "the
  addendum below."

- [ ] **7.2** Verify by reading back §9 lines 1720-1730; confirm no
  `src-tauri/` or `crates/*/` substring remains.

### Task 8: Update bin/agent-prompts-content-test.sh — invert §2 Tauri assertion, add global negative-grep, add positive gRPC pin (D-8)

- `depends_on: [1, 2, 3, 4, 5, 6, 7]`
- `touches: bin/agent-prompts-content-test.sh` — three edits: invert the
  §2 Tauri-positive block (lines 120-125), add a global negative-grep
  block (insert after line 130, before the §7 ENG-52 release.yml block at
  line 132), add a positive gRPC pin (insert immediately after the
  inverted §2 assertion, before the existing `@app.route` positive at
  line 126). Plus housekeeping: rephrase the ENG-52 comment at line 155
  to drop the `Tauri-only` qualifier.

Steps:

- [ ] **8.1** Edit `bin/agent-prompts-content-test.sh` to **invert** the
  §2 Tauri-positive at lines 120-125. Content anchor (unique multi-line
  substring):

  ```bash
  # ─── ENG-52: §2 has BOTH a Tauri AND a non-Tauri api-contract example ───
  if printf '%s\n' "$s2" | grep -qF '#[tauri::command]'; then
    ok "§2 preserves Tauri api-contract example (#[tauri::command])"
  else
    nope "§2 preserves Tauri api-contract example (#[tauri::command])" "phrase missing"
  fi
  ```

  Replace with:

  ```bash
  # ─── ENG-97: §2 has gRPC (post-Tauri) AND a non-Tauri api-contract example ───
  # Post-ENG-97 (May 2026): the §2 api-contract block carries a gRPC + protobuf
  # compiled-IPC example (replacing the prior Tauri v2 + TypeScript shape) plus the
  # existing Python/Flask HTTP-handler example. Test pins (a) the absence of
  # the prior Tauri marker and (b) the presence of the new gRPC marker so a
  # silent revert (or a silent drop of Example 1) trips here.
  if printf '%s\n' "$s2" | grep -qF '#[tauri::command]'; then
    nope "§2 ENG-97: '#[tauri::command]' marker absent (post-Tauri-strip)" "marker present — has the api-contract Example 1 reverted to Tauri?"
  else
    ok "§2 ENG-97: '#[tauri::command]' marker absent (post-Tauri-strip)"
  fi
  if printf '%s\n' "$s2" | grep -qF 'service FooService'; then
    ok "§2 ENG-97: contains gRPC api-contract example (service FooService)"
  else
    nope "§2 ENG-97: contains gRPC api-contract example (service FooService)" "marker missing — has Example 1 been silently dropped or its body renamed?"
  fi
  ```

  Notes:
  - The new `service FooService` positive pin (D-8 step 3 per brainstorm)
    is folded into the same block as the inverted §2 assertion; this
    consolidates the §2 api-contract pins in one place and keeps the
    test reading order matching the prompt's section order.
  - The existing `@app.route` positive at lines 126-130 of the original
    file is untouched and continues to fire (Edit's `old_string` ends
    at line 125's `fi`).

- [ ] **8.2** Edit `bin/agent-prompts-content-test.sh` to **add a global
  negative-grep block** that scans `AGENT_PROMPTS.md` whole-file for the
  five forbidden tokens (one assertion per token; six tokens total
  because `Tauri` AND `tauri::` are pinned separately per brainstorm §8
  edge-case row "Case-insensitive `tauri::command` matching `Tauri`").

  Content anchor (unique substring marking the insertion point —
  immediately AFTER the existing §2 `@app.route` positive's closing `fi`
  at line 130 and BEFORE the existing `# ─── ENG-52: §7 release.yml
  check is profile-conditional ───` comment at line 132):

  ```bash
  if printf '%s\n' "$s2" | grep -qF '@app.route'; then
    ok "§2 contains non-Tauri (Python/Flask) api-contract example (@app.route)"
  else
    nope "§2 contains non-Tauri (Python/Flask) api-contract example (@app.route)" "phrase missing"
  fi

  # ─── ENG-52: §7 release.yml check is profile-conditional ────────────────
  ```

  Use `Edit` with the multi-line `old_string` above (the blank line
  between the `fi` and the `# ─── ENG-52: §7 ...` comment is the
  natural insertion gap). Replace with:

  ```bash
  if printf '%s\n' "$s2" | grep -qF '@app.route'; then
    ok "§2 contains non-Tauri (Python/Flask) api-contract example (@app.route)"
  else
    nope "§2 contains non-Tauri (Python/Flask) api-contract example (@app.route)" "phrase missing"
  fi

  # ─── ENG-97: whole-file negative-grep on de-Tauri-ed tokens ─────────────
  # Post-ENG-97 (May 2026): AGENT_PROMPTS.md must carry zero Tauri-specific
  # illustrations. The prior assertions are §2-scoped (api-contract block) —
  # this block scans the whole file so a re-introduction in §3/§6/§7/§8/§9
  # trips here too. One assertion per token gives a diagnostic that names
  # which token reappeared. Tokens enumerated by Linear ENG-97 AC#1.
  for forbidden_token in 'Tauri' 'tauri::' 'tauri.conf.json' 'src-tauri/' 'cargo test -- --list' 'invoke('; do
    if grep -qF -- "$forbidden_token" "$PROMPTS"; then
      nope "AGENT_PROMPTS.md ENG-97: forbidden token '$forbidden_token' absent" "token reappeared in AGENT_PROMPTS.md — see ENG-97 for context"
    else
      ok "AGENT_PROMPTS.md ENG-97: forbidden token '$forbidden_token' absent"
    fi
  done

  # ─── ENG-52: §7 release.yml check is profile-conditional ────────────────
  ```

  Notes:
  - `grep -F` (literal substring) per the brainstorm §8 edge-case
    resolution: each token is matched as a literal substring; the proper
    noun `Tauri` and the lowercase `tauri::` are pinned as separate
    tokens so the failure message names the specific reintroduction.
  - The `--` before `"$forbidden_token"` guards against tokens that
    begin with `-` (none of the current six do, but the practice is
    defensive; matches existing `grep -F` invocations elsewhere in this
    file e.g. lines 121, 126).
  - The loop variable is `forbidden_token` (descriptive) — avoids the
    common shadowing risk on `$token` if the surrounding code later
    grows a loop with that variable name.

- [ ] **8.3** Edit the descriptive comment at line 155 to drop the
  `Tauri-only` qualifier. Content anchor (unique substring):

  ```
  # could revert §7 to the Tauri-only list (`tauri.conf.json,
  # next.config.js, Caddyfile, nginx.conf`) and the existing assertions
  # would all still pass.
  ```

  Replace with:

  ```
  # could revert §7 to a Tauri-leaning list (`next.config.js, Caddyfile,
  # nginx.conf` plus a desktop-shell config like the prior `tauri.conf.json`
  # token, now banned by the ENG-97 global negative-grep above) and the
  # existing list assertions below would all still pass.
  ```

  Rationale: the comment was historically accurate (pre-ENG-52 the list
  was Tauri-only); post-ENG-97 it should reference the new global
  negative-grep as the primary guard against `tauri.conf.json` reintroduction,
  with the line-based list-content positives (pyproject.toml + go.mod)
  as a secondary guard.

- [ ] **8.4** Verify by running `bash bin/agent-prompts-content-test.sh`.
  Expected: all assertions PASS. The six new forbidden-token assertions
  in step 8.2 + the inverted §2 Tauri-negative in step 8.1 + the new
  gRPC positive pin in step 8.1 + every pre-existing assertion exits 0.
  If any negative-grep fires, identify which token leaked and re-run
  Tasks 1-7 for the relevant edit site.

- [ ] **8.5** Run the broader gate: `bash bin/render-prompt-test.sh`
  (must pass — A-015 verified no Tauri-specific assertion in this file)
  and `bash .githooks/pre-commit` (runs the full suite; must exit 0).

## Frontend Tasks

none — the harness has no UI surface; the UI agent's pass-through clause
at `AGENT_PROMPTS.md:899` already covers this case for non-UI tickets.

## Failure Mode → Test Map

Every row binds a failure mode pulled from the brainstorm's §7 Error
handling and §8 Edge cases (plus the test-gate closure sweep from
A-016) to a named test assertion. All tests live in
`bin/agent-prompts-content-test.sh` and/or `bin/render-prompt-test.sh`.

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
|---|---|---|---|---|
| §2 Tauri marker reintroduced in api-contract Example 1 | A future PR reverts gRPC Example 1 back to `#[tauri::command]` | Test `nope`s with diagnostic "§2 ENG-97: '#[tauri::command]' marker absent (post-Tauri-strip)" | unit | `bin/agent-prompts-content-test.sh` — inverted §2 assertion (Task 8.1, replaces line 121-125) |
| §2 Example 1 silently dropped (only Example 2 remains) | A future cleanup pass removes the compiled-IPC example entirely | Test `nope`s with "§2 ENG-97: contains gRPC api-contract example (service FooService)" — marker missing | unit | `bin/agent-prompts-content-test.sh` — positive gRPC pin (Task 8.1) |
| §2 Example 2 (Python/Flask) silently dropped | Implementer's Task 1.2 overshoots and removes Example 2 too | Existing test `nope`s with "§2 contains non-Tauri (Python/Flask) api-contract example (@app.route)" | unit | `bin/agent-prompts-content-test.sh` — existing line 126-130 `@app.route` positive (untouched) |
| `Tauri` proper noun reintroduced anywhere in AGENT_PROMPTS.md | Future PR adds Tauri illustration in any section | Test `nope`s with "AGENT_PROMPTS.md ENG-97: forbidden token 'Tauri' absent — token reappeared..." | unit | `bin/agent-prompts-content-test.sh` — new global negative-grep (Task 8.2, loop iter 1) |
| `tauri::` (lowercase, e.g. attribute or path) reintroduced | Future PR adds `#[tauri::command]` or `tauri::Builder` | Test `nope`s naming `tauri::` | unit | global negative-grep (Task 8.2, loop iter 2) |
| `tauri.conf.json` reintroduced in §7 config-scan list (or anywhere) | Future PR re-adds the Tauri config file name | Test `nope`s naming `tauri.conf.json` | unit | global negative-grep (Task 8.2, loop iter 3) |
| `src-tauri/` reintroduced in §9 path list (or anywhere) | Future PR re-adds the Tauri source dir token | Test `nope`s naming `src-tauri/` | unit | global negative-grep (Task 8.2, loop iter 4) |
| `cargo test -- --list` reintroduced in §6 coverage paragraph | Future PR re-adds the Rust-specific test-discovery example | Test `nope`s naming `cargo test -- --list` | unit | global negative-grep (Task 8.2, loop iter 5) |
| `invoke(` reintroduced in §3 frontend-call clause (or anywhere) | Future PR re-adds the Tauri client-call illustration | Test `nope`s naming `invoke(` | unit | global negative-grep (Task 8.2, loop iter 6) |
| §2 column-0 fence count drifts off 2 (e.g. implementer un-indents the api-contract fence) | A future edit flips column-4 fence to column-0 | Test `nope`s with "§2 column-0 fence count is exactly 2 (api-contract example stays indented)" — got `n` | unit | `bin/agent-prompts-content-test.sh:184-190` (existing, untouched) |
| `bin/render-prompt.sh::extract_block` dies on §2 fence-count mismatch at dispatch time | render-prompt.sh invoked with `stage=plan` on a malformed §2 | `die "AGENT_PROMPTS.md schema error: section '2. Plan Agent' has $n column-0 fences..."` | integration | `bin/render-prompt-test.sh` (existing schema-check assertions on each numbered stage section) |
| §2 H2 heading drift breaks `section_body "## 2. Plan Agent"` match | Future PR renames `## 2. Plan Agent` to e.g. `## 2. Plan stage` | `section_body` returns empty; every §2-scoped assertion (lines 121-130 + Tasks 8.1's three pins) trivially `nope`s | unit | `bin/agent-prompts-content-test.sh` — multiple §2 assertions fire on empty body |
| Section count drifts (e.g. §1 deleted, sections renumber) | Future PR renumbers sections | `render-prompt-test.sh` STAGE_TO_SECTION drift assertion fails; multiple agent-prompts-content-test §N assertions fail | integration | `bin/render-prompt-test.sh` (existing STAGE_TO_SECTION sanity asserts) |
| `tauri.conf.json` referenced in §7 but pyproject.toml/go.mod stripped accidentally | Implementer overshoots Task 5.1 and removes pyproject.toml or go.mod from the list | Existing test `nope`s with "§7 config-scan list contains non-Tauri examples (pyproject.toml, go.mod)" | unit | `bin/agent-prompts-content-test.sh:158-164` (existing, untouched) |
| Retrospective stage (§9) regains a `learned-rules/<slug>/project-profile.md` reference that confuses with the appended addendum | Future PR rewrites §9 to say "the addendum below names X" | No automated test (out of scope for ENG-97); manual review of §9 wording on PRs editing the retrospective bullet | manual review | n/a (documented in brainstorm §7 fallback) |

## Test Strategy

### Unit

- **`bin/agent-prompts-content-test.sh`** — the load-bearing surface for
  every Failure Mode row except the manual-review row. After Task 8, the
  file carries:
  - The inverted §2 Tauri-negative (Task 8.1).
  - The new §2 positive gRPC-marker pin (Task 8.1).
  - The unchanged §2 `@app.route` positive (lines 126-130).
  - The unchanged §2 column-0 fence-count assertion (lines 184-190).
  - The new global negative-grep loop over six forbidden tokens (Task 8.2).
  - The unchanged §7 pyproject.toml + go.mod positive (lines 158-164).
  - Every other pre-existing assertion (the ENG-46/ENG-53/ENG-54/ENG-71/
    ENG-77 pins) — untouched.

  Runs in ~1s; expected total assertion count after this PR: the current
  count + 6 (new negative-greps) + 1 (new gRPC positive) − 0 (the §2
  Tauri positive is replaced in-place, not added). The pre-commit hook
  runs this on every commit (per `CLAUDE.md::Pre-commit hook`).

### Integration

- **`bin/render-prompt-test.sh`** — verifies `extract_block` extracts §2
  correctly after the api-contract block's content change. The §2
  column-0 fence count stays at 2 (per Task 1's design); the
  test's existing fence-count assertion (verified at A-015 to NOT pin
  any Tauri content) continues to pass without edit. The schema-check
  guard at `bin/render-prompt.sh:111` is the upstream backstop.

### Smoke

- **`bash .githooks/pre-commit`** — runs the full `bin/*-test.sh`
  suite. ENG-97's gate is the implementing-stage pre-commit run; if
  any of the 6 new negative-greps or the new gRPC positive fires, the
  commit is blocked. This is the operational guard against silent
  forbidden-token reintroduction.

### Adversarial coverage intent

The brainstorm §8 enumerated three adversarial vectors; coverage:

1. **Silent removal of Example 1 (leave only Example 2).** Covered by
   the positive `service FooService` pin in Task 8.1 — drops fire `nope`.
2. **Fence indentation flip (column-4 → column-0).** Covered by the
   existing line-184-190 fence-count==2 assertion; no new test needed.
3. **Case-insensitive `Tauri` reintroduction (e.g. `tauri::Builder`).**
   Covered by the separate `tauri::` token in the global negative-grep
   (Task 8.2 loop iter 2) — the proper noun `Tauri` and lowercase
   `tauri::` are pinned independently per the brainstorm §8 edge-case
   row.

No new adversarial test files are added. The Linear issue's AC#2 names
`bin/agent-prompts-content-test.sh` as the test surface, and the
adversarial concerns are covered by the new assertions in that file.

## Persona review

Six personas dispatched in parallel per the brainstorm's Completion
checklist. Each persona's verdict + findings are recorded below.
Iteration: 1 (zero P0 surfaced; gate passes on first round).

### Persona 1 — feasibility — PASS (zero P0)

Codebase-fact verification pass:

- All cited `path:line` references in §Assumption Inventory were re-read
  directly in this dispatch and match the quoted excerpts.
- A-002's full Example 1 body was read and the Edit's `old_string` is a
  unique multi-line substring within the file (`# === Example 1 — Tauri v2 + TypeScript`
  appears exactly once).
- A-003 through A-008's edit anchors are unique multi-line substrings
  within their respective sections.
- A-009 (test file inversion target) was read; the `old_string` for Task
  8.1 is a unique multi-line block (`ENG-52: §2 has BOTH a Tauri AND a non-Tauri`
  appears exactly once).
- A-013 (`render-prompt.sh:111` die-on-fence-count-mismatch) is the
  upstream invariant the §2 fence-count==2 localized assertion backstops.
- A-014 (`render-prompt.sh:187-190` skip-on-retrospective) is the
  carve-out D-7's phrasing routes around — verified.
- A-015 (no Tauri-pinning in `bin/render-prompt-test.sh`) verified by
  Grep.
- A-016 (test-gate closure sweep) — the four sibling tests with `Tauri`
  matches (`profile-allowlist-test.sh`, `phase-project-profile-test.sh`,
  `dispatch-test.sh`) were inspected; none has assertions on
  `AGENT_PROMPTS.md` content. The `Tauri` mentions are either prose
  comments documenting the test's purpose, profile-fixture content
  stubbing a Tauri target, or fixture group names. NO test-gate closure
  P0 — only `bin/agent-prompts-content-test.sh` (already in File
  Structure) has overlap.
- A-018 (gRPC body forbidden-token-free) — inspection confirms the
  replacement body contains no `Tauri`, `tauri::`, `tauri.conf.json`,
  `src-tauri/`, `cargo test -- --list`, or `invoke(` literal substrings.

Edit-boundary key audit: every Task step uses content anchors
(distinctive multi-line substrings or unique comment headers), with
line numbers only as informational hints. No Task uses a bare line
number as its sole boundary.

`depends_on` audit: Tasks 1-7 declare `[]` (independent content anchors;
no shared mutable state). Task 8 declares `[1, 2, 3, 4, 5, 6, 7]`
correctly — the new global negative-grep asserts that the seven prompt
edits all landed; Task 8 cannot pass until all seven Tasks 1-7 have
been applied.

Failure Mode → Test Map row audit: 14 rows; 13 named to a concrete
assertion in `bin/agent-prompts-content-test.sh` or
`bin/render-prompt-test.sh`; 1 row (retrospective stage wording) flagged
as manual-review per the brainstorm's §7 carve-out (out of scope for
automated regression).

Zero P0 findings.

### Persona 2 — scope — PASS

- Two files changed (AGENT_PROMPTS.md, bin/agent-prompts-content-test.sh),
  matching the Linear issue's `Scope Boundaries: IN: AGENT_PROMPTS.md only`
  + AC#2 (test update).
- Every task's `touches` list stays within the declared File Structure.
- Out-of-scope items (ENG-94/ENG-95 sibling files; render-prompt.sh;
  CLAUDE.md; historical docs/) are explicitly enumerated in §File Structure.
- The `Choose your stack:` heading inside the api-contract fence
  (brainstorm Technical Hints prescription) is adopted; this is
  consistent with the hint and adds zero scope risk.

Zero P0 findings.

### Persona 3 — coherence — PASS

- Plan Goal ("zero forbidden tokens in AGENT_PROMPTS.md AND a passing
  inverted+extended test") matches brainstorm §2 Goal verbatim.
- Backend Tasks jointly realise every brainstorm decision D-1..D-8: Task
  1 covers D-1, Task 2 covers D-2, ..., Task 7 covers D-7, Task 8
  covers D-8 (all three sub-changes).
- Test Strategy covers every Failure Mode → Test Map row except the
  manual-review row, which is explicitly flagged.
- The "no new API surface" call-out is internally consistent with the
  "harness has no FE↔BE" framing in the brainstorm §3.
- Sibling-ticket coherence: ENG-94 (landed at 343457c) and ENG-95 (in
  flight) cover the orchestrator side; ENG-97 closes the prompt side.
  The three tickets route through the same
  `learned-rules/<slug>/project-profile.md` artifact.

Zero P0 findings.

### Persona 4 — design — PASS

- The plan respects the AGENT_PROMPTS.md schema (`render-prompt.sh::
  extract_block`'s exactly-2-column-0-fences invariant): D-1's
  gRPC replacement preserves the column-4 indented fence pair; the §2
  fence count stays at 2 (verified by the existing test at lines
  184-190).
- No layering violation: `bin/agent-prompts-content-test.sh` is the
  canonical surface for AGENT_PROMPTS.md content invariants; the new
  assertions live there (not in a new test file).
- The global negative-grep loop pattern (Task 8.2) mirrors the existing
  per-stage loop pattern at lines 361-397 (ENG-53 #11 "every stage has
  no-probe instruction") — same idiom, single-file scope vs per-section
  scope. Idiomatic.
- D-7's retrospective-stage carve-out (point at profile file path
  rather than the addendum) is internally consistent with the
  long-standing `bin/render-prompt.sh:187-190` skip-on-retrospective
  behavior. No new code path.
- No new exit codes, no new metrics, no new lane fences — the change is
  pure prompt content + test assertions.

Zero P0 findings.

### Persona 5 — product — PASS

- The user-visible outcome (operators bringing up non-Tauri targets see
  no Tauri-shaped illustration in stage prompts) is delivered
  directly: zero forbidden tokens in the rendered prompt file after this
  PR.
- Tauri-target operators (twinning) are NOT regressed — the
  `learned-rules/twinning/project-profile.md::## Stack` section still
  declares Tauri, and the dispatched plan agent's api-contract block
  output will use Tauri shape (driven by the profile addendum). The
  prompt's illustrative example just no longer leads them by name.
- Prompt-token cost is approximately neutral: Task 1 swaps a Tauri Rust
  example for a gRPC protobuf example (~similar line count); Tasks 2-7
  are short rewrites that don't grow the prompt.
- The Linear issue's `Desired Outcome` rubric — "Each Tauri-specific
  example is either: 1) replaced with stack-agnostic phrasing, 2)
  replaced with two illustrative examples covering compiled-IPC + REST,
  3) removed where redundant" — is mapped: D-1 = option 2 (two
  examples); D-2, D-3, D-4, D-6, D-7 = option 1 (generic phrasing);
  D-5 = option 3 (drop the redundant config-list entry).

Zero P0 findings.

### Persona 6 — security — PASS

- No secrets touched (the diff is markdown and test scaffolding).
- No `${VAR:-X}` env-var fallbacks introduced.
- The new global negative-grep loop uses `grep -F -- "$forbidden_token"`
  with literal-substring matching; no shell-metachar injection vector.
- The gRPC example body uses placeholder names (`FooService`,
  `FooRequest`); no real service endpoints, hostnames, or credentials.
- The test loop's `-- "$forbidden_token"` separator is defensive against
  tokens that begin with `-` (per existing harness convention at
  e.g. `bin/agent-prompts-content-test.sh:121`).

Zero P0 findings.

### Gate summary

| Persona | Verdict | P0 |
|---|---|---|
| feasibility | PASS | 0 |
| scope | PASS | 0 |
| coherence | PASS | 0 |
| design | PASS | 0 |
| product | PASS | 0 |
| security | PASS | 0 |

6/5 personas PASS (the brainstorm's checklist lists 5 personas; this
plan ran the 5 standard personas + a 6th security persona for
defense-in-depth). Zero P0 findings. Iteration 1 closes the gate;
proceeding to implementing.
