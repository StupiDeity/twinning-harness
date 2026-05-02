---
linear: ENG-52
date: 2026-05-02
topic: Tauri-assumption residue cleanup — prompt rebalancing, stale post-ENG-49 CI references, slug catalog README
---

# Plan — ENG-52 Tauri-assumption residue cleanup (post-ENG-49)

> **For agentic workers:** REQUIRED SUB-SKILL — use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to walk this task-by-task. Steps use `- [ ]` for tracking.

Implementation plan for the design in
`docs/brainstorms/2026-05-02-eng-52-tauri-assumption-residue-cleanup-post-eng-49-design.md`.

## Anti-anchoring

- **Problem:** post-ENG-49, AGENT_PROMPTS.md and two bash docstrings still read
  Tauri-coupled in places where the *mechanism* is now stack-agnostic, and two
  Severity-C references point at a `pipeline-release.yml` CI workflow this repo no
  longer contains. Per the issue this is *cosmetic residue* — no behavior change.
- **Does the brainstorm address it?** Yes, directly: D-1 adds a Python/Flask
  example beside the Tauri one, D-2 reorders §7's config-scan list, D-3 makes
  §7's `release.yml` post-merge check profile-conditional, D-4 re-attributes
  §8's input list to `bin/run-release-observer.sh`, D-5 documents
  `on-new-release.sh::Part 1` as the safety-net for verdict-handler's primary
  path, D-6 fixes the `run-release-observer.sh:5` invocation-site docstring,
  D-7 adds `learned-rules/README.md` to disambiguate the slug catalog.
- **Proportional?** Yes: every change is a string-level edit inside an existing
  file plus one ~12-line README and four assertions in the existing
  `bin/agent-prompts-content-test.sh`. No refactor, no schema change, no flow change.
- **No escalation needed.**

## Goal

Edit the brainstorm's six surface points in `AGENT_PROMPTS.md` (§2 add Python/Flask
example; §7 reorder config-scan list; §7 make `release.yml` post-merge check
profile-conditional; §8 re-attribute inputs to `bin/run-release-observer.sh`) and
two bash docstrings (`bin/on-new-release.sh::Part 1`, `bin/run-release-observer.sh:5`),
add `learned-rules/README.md` documenting the slug-keyed catalog, and lock the
§2/§7/§8 prompt invariants with four new assertions in
`bin/agent-prompts-content-test.sh` — verifiable via
`bash bin/agent-prompts-content-test.sh && bash bin/render-prompt-test.sh && bash -n bin/on-new-release.sh && bash -n bin/run-release-observer.sh`
exiting 0 and `learned-rules/README.md` existing on the feature branch.

## Architecture

This work has no runtime architecture. It extends ENG-49's
*orchestrator-as-source-of-truth* principle to the **prompt and comment surface**:
documentation strings should attribute work to its actual current owner. The
underlying mechanism (verdict-handler owns transitions, run-local.sh owns the
release watcher, the project-profile addendum owns stack vocabulary) is already
in place. This ticket removes the prose that still attributes work elsewhere.

There is no `docs/VISION.md`, no `docs/knowledge/decisions.md`, no
`SYSTEM_ARCHITECTURE.md` in this repo (verified: `ls docs/` returns
`brainstorms/  plans/  runbooks/`). Governing constraints come from `CLAUDE.md`
and `learned-rules/harness/project-profile.md`.

## Tech stack

- Bash 3.2+ (Darwin default, harness target).
- `awk` (BSD-compatible) for `agent-prompts-content-test.sh::section_body` extraction.
- `grep` for content assertions.
- No new dependencies. No `jq` schema changes. No `dispatch.sh::allowed_tools_for` cases added.

## Assumption inventory

Every modified file is a content edit; the codebase facts below are required by
ENG-5 P-002 / B-001 to be quoted with `path:line`. All assumptions are *verified*
against current code; nothing is `assumed/new` (the only new artifact is
`learned-rules/README.md`).

- **A-001 — §2 api-contract example block bounds.** The illustrative `api-contract`
  example occupies `AGENT_PROMPTS.md:390–405`, opening with a 4-space-indented
  ` ```api-contract` (line 390) and closing with a 4-space-indented ` ``` `
  (line 405). The §2 stage block itself is delimited by column-0 fences at
  lines 311 and 480 — verified via `Grep '^```' AGENT_PROMPTS.md`:
  ```
  311:```
  ...
  480:```
  ```
  The api-contract block's fences are 4-space-indented, so they do NOT count toward
  the column-0 fence-pair contract `render-prompt.sh::extract_block` enforces (the
  contract is per-section column-0 fence count exactly 2; see CLAUDE.md
  "AGENT_PROMPTS.md is load-bearing"). Adding more 4-space-indented content
  (including an additional indented ` ``` ` if it were ever needed) does NOT
  change the column-0 count. **Implementation contract:** D-1's Python/Flask
  example MUST stay 4-space-indented and MUST live INSIDE the existing single
  api-contract block (between line 390's open and line 405's close), so the
  column-0 fence count for §2 remains exactly 2.

- **A-002 — §7 config-scan list.** `AGENT_PROMPTS.md:1201–1203` reads:
  ```
      - Any change to runtime configuration files named in the profile (e.g.
        `tauri.conf.json`, `next.config.js`, `Caddyfile`, `nginx.conf`): scan for new
        hosts, new bundle identifiers, changed security policies.
  ```
  D-2 reorders + adds two items in place. Lives inside §7's column-0 fence
  pair (1087/1287); content-only edit.

- **A-003 — §7 release.yml post-merge check.** `AGENT_PROMPTS.md:1223–1226` reads:
  ```
  Post-merge verification (MANDATORY):
    - `gh run list --branch main --workflow release.yml --limit 1` — confirm the release
      workflow picked up the merge. If not present within 2 minutes, post a Linear
      comment `<!-- pipeline-metric: release_trigger_missing -->` and escalate.
  ```
  D-3 prefixes with a profile-conditional clause and adds a "skip if no profile
  release workflow" branch. Content-only edit inside §7's fence pair.

- **A-004 — §8 input-attribution list.** `AGENT_PROMPTS.md:1303–1306` reads:
  ```
  Inputs supplied by `pipeline-release.yml`:
    - `{version}` — the semantic-release version just cut (e.g. `1.19.4`).
    - `{tag}`     — the git tag just pushed (e.g. `v1.19.4`).
    - `{prev_tag}` — the previous tag, resolved via `git describe --tags --abbrev=0 {tag}^`.
  ```
  D-4 rewrites attribution to `bin/run-release-observer.sh` (env vars) and lists
  the env-var names. **Critical detail:** the body of §8 (lines 1311+) still uses
  the `{version}`, `{tag}`, `{prev_tag}` placeholder tokens that
  `render-prompt.sh:185–189` substitutes via `sed`. We do NOT remove or rename
  those placeholders — only the introductory list. Verified at
  `bin/render-prompt.sh:185–189`:
  ```
        | sed \
          -e "s|{version}|$version|g" \
          -e "s|{tag}|$tag|g" \
          -e "s|{prev_tag}|$prev_tag|g" \
  ```
  Lives inside §8's column-0 fence pair (1291/1396).

- **A-005 — `bin/run-release-observer.sh` exports the canonical env-var names.**
  Verified at `bin/run-release-observer.sh:21–23`:
  ```
    export PIPELINE_RELEASE_VERSION="$version"
    export PIPELINE_RELEASE_TAG="$tag"
    export PIPELINE_RELEASE_PREV_TAG="$prev_tag"
  ```
  These are the literal env-var names D-4's rewritten list cites; aligning the
  prompt's input names to the code's exported names is the AC2 stated benefit.

- **A-006 — `run-release-observer.sh:5` docstring is stale.** Verified at
  `bin/run-release-observer.sh:5`:
  ```
  # Invoked by .github/workflows/pipeline-release.yml AFTER the stage:building→released sweep.
  ```
  No file `.github/workflows/pipeline-release.yml` exists in this repo — verified
  via `ls .github/workflows/` returning only `secret-probe-lint.yml`. D-6 rewrites
  the line to point at `bin/on-new-release.sh` (which itself is invoked by
  `bin/run-local.sh`'s release watcher).

- **A-007 — `bin/run-local.sh:379` is the release-watcher invocation site.**
  Verified at `bin/run-local.sh:365–388` — the watcher reads `last-observed-release`,
  compares with `gh release list --limit 1`, and on diff calls
  `bash "$SCRIPT_DIR/on-new-release.sh" "$latest_version" "$latest_tag"` (line 379).

- **A-008 — `bin/on-new-release.sh:25–54` houses the Part-1 sweep.** Verified:
  the in-script comment block at lines 25–29 currently reads:
  ```
    # ─── Part 1: sweep stage:building → stage:released ───────────────────────
    # Any issue still sitting at stage:building when the release cuts gets flipped
    # to stage:released + Done with a "shipped in $tag" comment. In the happy path
    # the local build stage already advanced issues to stage:released, so this
    # usually finds nothing.
  ```
  D-5 rewrites to call out (a) the verdict-handler primary path, (b) the
  safety-net role, (c) the cross-reference to
  `bin/verdict-handler.sh::apply_transition` lines 159–167.

- **A-009 — `bin/verdict-handler.sh::apply_transition` performs the
  `released → Done` transition.** Verified at `bin/verdict-handler.sh:159–167`:
  ```
    elif [[ "$to" == "released" ]]; then
      local done_state
      done_state="$(jq -r '.linear.native_states.done // empty' "$CONFIG")"
      if [[ -n "$done_state" ]]; then
        bash "$_VH_SCRIPT_DIR/linear.sh" transition-state "$issue" "$done_state" || true
      else
        log "verdict-handler: skipping native-state hook to Done (config.linear.native_states.done not set)"
      fi
    fi
  ```
  D-5's comment cites this exact line range.

- **A-010 — `learned-rules/<slug>/` is resolved by `bin/render-prompt.sh:141,214`.**
  Verified:
  - `bin/render-prompt.sh:141` resolves the per-slug profile path:
    ```
    local profile_path="$HARNESS_ROOT/learned-rules/$PROJECT_SLUG/project-profile.md"
    ```
  - `bin/render-prompt.sh:214` resolves the per-slug rule directory used in
    `{learned_rules_dir}` substitution:
    ```
    learned_rules_dir="$HARNESS_ROOT/learned-rules/$PROJECT_SLUG"
    ```
  D-7's README cites both line numbers verbatim so a future operator can grep
  both directions.

- **A-011 — `learned-rules/twinning/` carries a full stage-rule set used by
  twinning-target dispatches.** Verified: `ls learned-rules/twinning/` returns
  `brainstorm.md  build.md  implementation.md  plan.md  project-profile.md
  qa.md  release.md  review.md  ui.md` — nine files, the harness's nine stages
  plus the profile. Dropping the directory would break twinning-target dispatch
  the moment a twinning operator pulls the harness; D-7's "document, do not
  remove" verdict is load-bearing.

- **A-012 — `bin/agent-prompts-content-test.sh` already locks §8 invariants
  via the `section_body` awk helper.** Verified at lines 17–24 (helper),
  lines 26–28 (s3/s4/s8 extraction), lines 60–67 (positive companion check
  on §8), and lines 69–73 (existing negative check on §8 obsolete phrase).
  D-8's four new assertions follow the same pattern: extract `s2`/`s7`/`s8`
  via `section_body`, grep with `-qF` (literal) or `-qE` (regex) and call
  `ok` / `nope`. Counter increments inherit existing PASS/FAIL bookkeeping
  at lines 12–14.

- **A-013 — §2 plan-agent body's H2 heading is the literal string
  `## 2. Plan Agent`.** Verified at `AGENT_PROMPTS.md:309`. D-8.1 will pass
  `## 2. Plan Agent` to `section_body` to extract `s2`. The existing test
  file uses the same pattern for `s3`/`s4`/`s5`/`s8`, so the helper is known
  to handle the H2 heading shape `## N. <Name> Agent[ (Backend|Frontend|Scheduled)]`.

- **A-014 — `render-prompt.sh::extract_block` requires exactly two column-0
  ` ``` ` fences per stage section, not more.** Captured indirectly: CLAUDE.md
  "AGENT_PROMPTS.md is load-bearing" states "and dies if the fence count is not
  exactly 2." `agent-prompts-content-test.sh::section_body` uses awk on H2
  boundaries (line 19–24), unaffected by indented fences. The Python/Flask
  example in D-1 stays inside the existing 4-space-indented fence pair, so
  no new column-0 fences are introduced.

- **A-015 — `bin/render-prompt-test.sh` already exists and tests the
  fence-extraction contract.** Verified by `Glob bin/render-prompt-test.sh`.
  Running it after the §2 edit is a regression backstop for "did D-1
  accidentally add a column-0 fence?" without writing a new test.

- **A-016 — `bin/dispatch-test.sh` exercises `allowed_tools_for` and is
  unaffected by this ticket.** No allowlist case is added or modified;
  the dispatch test is a no-op for ENG-52, listed only as a verify-after step.

- **A-017 — `learned-rules/README.md` does NOT exist today.** Verified by
  `ls learned-rules/` returning `harness  twinning` only. The README is a
  net-new file (sibling of the per-slug directories). `render-prompt.sh:141`
  reads the literal path `learned-rules/$PROJECT_SLUG/project-profile.md`,
  not `learned-rules/README.md`, so the new file is invisible to all current
  resolution code paths and cannot accidentally fire as a slug profile.

## File structure

```
bin/
  agent-prompts-content-test.sh   modified  — append four §2/§7/§8 invariant assertions (Task 5)
  on-new-release.sh               modified  — rewrite Part-1 in-script comment as safety-net documentation (Task 3)
  run-release-observer.sh         modified  — update :5 docstring to point at the local invocation chain (Task 4)

AGENT_PROMPTS.md                  modified  — §2 add Python/Flask example, §7 reorder + profile-conditional release.yml,
                                              §8 attribute inputs to bin/run-release-observer.sh (Tasks 1, 2)
learned-rules/
  README.md                       NEW       — document the slug-keyed catalog (~12 lines) (Task 6)
```

No changes to: `bin/render-prompt.sh`, `bin/run-local.sh`, `bin/verdict-handler.sh`,
`bin/dispatch.sh`, `bin/poll.sh`, `bin/run-stage.sh`, `bin/linear.sh`,
`bin/common.sh`, `bin/halt.sh`, `bin/setup.sh`, `bin/metrics.sh`, `bin/slack.sh`,
`bin/scope-check.sh`, `bin/classify-failure.sh`, `bin/render-prompt-test.sh`,
`bin/dispatch-test.sh`, `learned-rules/harness/*`, `learned-rules/twinning/*`,
`launchd/*`, `.github/workflows/*`, `docs/knowledge/*`.

## API contract

**No new API surface.** This ticket modifies only documentation strings, in-script
comments, and content-invariant tests. No CLI argv shapes, no env-var names, no
Linear-marker shapes, no exit codes, and no on-disk file shapes change. The
existing `{version}` / `{tag}` / `{prev_tag}` placeholder tokens substituted by
`render-prompt.sh:185–189` are preserved verbatim in §8's body — only the
introductory attribution list is rewritten.

---

## Backend Tasks

(The harness has only "backend" code in the bash-script sense — see *Frontend Tasks*
below for the no-op statement.)

### Task 1: Edit AGENT_PROMPTS.md §2 — add Python/Flask example beside the Tauri example

- `depends_on: []`
- `touches: AGENT_PROMPTS.md (lines 390–405)`

- [ ] In `AGENT_PROMPTS.md`, locate the api-contract example block at lines 390–405.
- [ ] Inside the existing 4-space-indented ` ```api-contract` block (open at 390,
      close at 405), keep the existing Tauri example as-is, then INSIDE the SAME
      indented fence append a horizontal-rule separator and a second
      Python/Flask + TypeScript-client example. The full replacement block must look
      like this (4-space indentation preserved on every line; column-0 fence count
      MUST stay at 0 for these lines so §2's column-0 fence-pair contract holds):

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
          # === Example 2 — Python/Flask + TypeScript client (HTTP-handler stack) ===

          # Backend handler (path per the profile's File layout)
          @app.route("/foo", methods=["POST"])
          def foo() -> tuple[FooResponse, int]:  # 200 on success
              ...

          # Backend types (module paths)
          @dataclass
          class FooResponse: id: str; items: list[FooItem]
          @dataclass
          class FooItem:     name: str; score: float

          # Frontend types (path per the profile's File layout)
          export type FooResponse = { id: string; items: FooItem[] };
          export type FooItem     = { name: string; score: number };
          ```
      ```

- [ ] Update the prose intro on line 388 from
      "Below is an illustrative example for a Tauri v2 + TypeScript stack — adapt it to your stack:"
      to
      "Below are two illustrative examples (Tauri v2 + TypeScript for a compiled-IPC stack, Python/Flask + TypeScript for an HTTP-handler stack) — adapt to your project profile:".
- [ ] Verify the column-0 fence count for §2 stays at exactly 2:
      `grep -n '^```' AGENT_PROMPTS.md | awk -F: '$1>=309 && $1<=482'`
      MUST print exactly two lines (311 open, ~480 close).
- [ ] Run `bash bin/render-prompt-test.sh` — must exit 0.

### Task 2: Edit AGENT_PROMPTS.md §7 + §8 — config-scan reorder, profile-conditional release.yml, env-var attribution

- `depends_on: []`
- `touches: AGENT_PROMPTS.md (lines 1201–1203, 1223–1226, 1303–1306)`

- [ ] **§7 line 1202 (D-2):** replace
      ``- Any change to runtime configuration files named in the profile (e.g.
      `tauri.conf.json`, `next.config.js`, `Caddyfile`, `nginx.conf`): scan for new
      hosts, new bundle identifiers, changed security policies.``
      with
      ``- Any change to runtime configuration files named in the profile (examples
      include `next.config.js`, `Caddyfile`, `nginx.conf`, `tauri.conf.json`,
      `pyproject.toml`, `go.mod`): scan for new hosts, new bundle identifiers,
      changed security policies.``
- [ ] **§7 lines 1223–1226 (D-3):** replace the current Post-merge verification
      bullet for `gh run list … --workflow release.yml` with the
      profile-conditional form:

      ```
      Post-merge verification (MANDATORY):
        - If the project profile names a release CI workflow (e.g. `release.yml`,
          `release.yaml`), invoke `gh run list --branch main --workflow <workflow-file>
          --limit 1` to confirm the release workflow picked up the merge. If not
          present within 2 minutes, post a Linear comment
          `<!-- pipeline-metric: release_trigger_missing -->` and escalate.
          **Skip this step if the profile names no release workflow** — in that case
          the orchestrator's release watcher (`bin/run-local.sh:379` →
          `bin/on-new-release.sh`) is the release-detection path and the post-merge
          CI watch on the next bullet is sufficient.
        - `gh run watch <run-id>` on the main-branch CI run started by the merge.
          [… leave the rest of the bullet unchanged …]
      ```

- [ ] **§8 lines 1303–1306 (D-4):** replace
      ```
      Inputs supplied by `pipeline-release.yml`:
        - `{version}` — the semantic-release version just cut (e.g. `1.19.4`).
        - `{tag}`     — the git tag just pushed (e.g. `v1.19.4`).
        - `{prev_tag}` — the previous tag, resolved via `git describe --tags --abbrev=0 {tag}^`.
      ```
      with
      ```
      Inputs supplied by `bin/run-release-observer.sh` (env vars; substituted into the placeholders below):
        - `PIPELINE_RELEASE_VERSION` (`{version}` in this prompt) — semantic-release version (e.g. `1.19.4`).
        - `PIPELINE_RELEASE_TAG` (`{tag}` in this prompt) — git tag (e.g. `v1.19.4`).
        - `PIPELINE_RELEASE_PREV_TAG` (`{prev_tag}` in this prompt) — previous tag (auto-resolved via `git describe --tags --abbrev=0 {tag}^` if empty).
      ```

      Note: the body of §8 (lines 1311+) keeps the `{version}` / `{tag}` /
      `{prev_tag}` placeholder tokens unchanged — `render-prompt.sh:185–189`
      sed-substitutes those in the rendered prompt.

- [ ] Verify §7 and §8 column-0 fence counts unchanged:
      `grep -n '^```' AGENT_PROMPTS.md` must still produce the line numbers
      `1087, 1287, 1291, 1396` for §7's open/close and §8's open/close (numbers
      may shift slightly due to D-3's added bullet; the COUNT must still be 2
      per section).
- [ ] Run `bash bin/render-prompt-test.sh` — must exit 0.

### Task 3: Rewrite `bin/on-new-release.sh:25–29` Part-1 comment as safety-net documentation

- `depends_on: []`
- `touches: bin/on-new-release.sh (lines 25–29)`

- [ ] In `bin/on-new-release.sh`, replace the comment block at lines 25–29 with
      this safety-net wording (keeps the box-drawing header line for visual parity
      with Part-2):

      ```bash
        # ─── Part 1: sweep stage:building → stage:released (safety net) ─────
        # Primary path: when the build agent posts <!-- pipeline-stage-summary:
        # building -->, verdict-handler.sh::apply_transition advances the issue
        # to stage:released and flips Linear native-state to Done (see
        # bin/verdict-handler.sh:159-167). This sweep is the SAFETY NET for
        # issues that didn't transition that way — for example, a build-agent
        # crash that left the issue stuck at stage:building, or a manually-
        # moved issue that bypassed the agent. In the happy path this loop
        # finds no issues and is a no-op.
      ```

- [ ] Leave executable code at lines 30–54 untouched.
- [ ] Run `bash -n bin/on-new-release.sh` — syntax must remain valid.

### Task 4: Update `bin/run-release-observer.sh:5` docstring to point at the local invocation chain

- `depends_on: []`
- `touches: bin/run-release-observer.sh (line 5)`

- [ ] In `bin/run-release-observer.sh`, replace line 5 from
      `# Invoked by .github/workflows/pipeline-release.yml AFTER the stage:building→released sweep.`
      to
      `# Invoked by bin/on-new-release.sh (which itself is invoked by bin/run-local.sh's release watcher) AFTER the stage:building→released sweep.`
- [ ] Leave the rest of the file (executable code 12–58) untouched.
- [ ] Run `bash -n bin/run-release-observer.sh` — syntax must remain valid.

### Task 5: Append four content-invariant assertions to `bin/agent-prompts-content-test.sh`

- `depends_on: [1, 2]`  *(asserts the §2/§7/§8 strings written by Tasks 1 and 2)*
- `touches: bin/agent-prompts-content-test.sh (two insertions: (a) `s2=`/`s7=` extractions near the existing `s3=`/`s4=`/`s8=` lines around 26–28; (b) four new ENG-52 assertion blocks appended below the current §8 block at line ~74, before the `── ENG-50 / ENG-54: §5 invariants ──` separator)`

- [ ] Add `s2="$(section_body "## 2. Plan Agent")"` and
      `s7="$(section_body "## 7. Build Agent")"` near the existing
      `s3=` / `s4=` / `s8=` extractions (around line 26–28). Reuse the same helper
      to keep style consistency.
- [ ] Append four new assertions after the existing §8 block (after line 73) and
      before the `── ENG-50 / ENG-54: §5 invariants ──` separator (line 76).
      Each follows the established `if grep …; then ok …; else nope … …; fi`
      shape:

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

      # ─── ENG-52: §7 release.yml check is profile-conditional ────────────────
      if printf '%s\n' "$s7" | grep -qF 'gh run list --branch main --workflow' \
         && printf '%s\n' "$s7" | grep -qF 'if the project profile names a release CI workflow'; then
        ok "§7 release.yml check is profile-conditional"
      else
        nope "§7 release.yml check is profile-conditional" \
             "either 'gh run list --branch main --workflow' missing OR 'if the project profile names a release CI workflow' missing"
      fi

      # ─── ENG-52: §8 attributes inputs to bin/run-release-observer.sh ────────
      if printf '%s\n' "$s8" | grep -qF 'bin/run-release-observer.sh' \
         && printf '%s\n' "$s8" | grep -qF 'PIPELINE_RELEASE_VERSION' \
         && ! printf '%s\n' "$s8" | grep -qE 'Inputs supplied by[[:space:]]+`pipeline-release\.yml`'; then
        ok "§8 attributes inputs to bin/run-release-observer.sh (env vars)"
      else
        nope "§8 attributes inputs to bin/run-release-observer.sh (env vars)" \
             "either 'bin/run-release-observer.sh' missing OR 'PIPELINE_RELEASE_VERSION' missing OR obsolete 'Inputs supplied by \`pipeline-release.yml\`' phrase still present"
      fi
      ```

- [ ] Run `bash bin/agent-prompts-content-test.sh` — must exit 0 (the four new
      assertions become four extra PASS lines in the green-path RESULTS line).

### Task 6: Add `learned-rules/README.md` documenting the slug-keyed catalog

- `depends_on: []`
- `touches: learned-rules/README.md (NEW)`

- [ ] Create `learned-rules/README.md` (≤15 lines, no emoji) with content like:

      ```markdown
      # learned-rules/

      Each subdirectory under this path is keyed by `PROJECT_SLUG` — the value
      set under `project.slug` in a target's `.pipeline-config/config.json`,
      frozen at first setup. Resolution happens in `bin/render-prompt.sh:141`
      (per-slug `project-profile.md` for the profile addendum) and
      `bin/render-prompt.sh:214` (`{learned_rules_dir}` substitution into stage
      prompts).

      Current slugs:

      - `harness/` — the harness-self target (this repo, when its own pipeline
        drives changes to itself).
      - `twinning/` — the Twinning desktop app, the original target this harness
        was built for.

      A subdirectory holds one `project-profile.md` plus zero-or-more
      `<stage>.md` files that the retrospective agent appends to dispatched
      stage prompts. Do not delete a slug directory unless you are certain no
      operator runs the harness against that target — the retrospective-agent
      rule history is non-recoverable from git short of a revert.
      ```

- [ ] Confirm the new file is the ONLY net-new path under `learned-rules/`:
      `git status -- learned-rules/` should show `learned-rules/README.md` as the
      only untracked addition.

---

## Frontend Tasks

**No frontend tasks.** The harness has no UI/frontend surface — it is bash
orchestration scripts (verified at `learned-rules/harness/project-profile.md:10–12`).
The "UI Agent" stage in the pipeline is a pass-through for harness-self
dispatches per `AGENT_PROMPTS.md §4`'s pass-through clause.

---

## Failure Mode → Test Map

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
|---|---|---|---|---|
| §2 second api-contract example accidentally raises §2 column-0 fence count to 4 (would crash `render-prompt.sh::extract_block`) | A future edit to D-1's example uses column-0 backticks instead of 4-space-indented backticks | `bin/render-prompt-test.sh` fails (fence-count contract enforced); ENG-52 implement stage stops on red test | unit | `bin/render-prompt-test.sh` (existing — runs as part of Task 1's verify-after) |
| §2 Python/Flask example deleted by future retrospective-agent edit | Edit to the api-contract block removes `@app.route` | New assertion `§2 contains non-Tauri (Python/Flask) api-contract example (@app.route)` fires `nope` and `bin/agent-prompts-content-test.sh` exits non-zero | unit | `bin/agent-prompts-content-test.sh` (Task 5 assertion 2) |
| §2 Tauri example dropped while the Python example is preserved (would satisfy AC1's letter but not its "Tauri example preserved" clause) | Edit removes `#[tauri::command]` | New assertion `§2 preserves Tauri api-contract example (#[tauri::command])` fires `nope` and the test exits non-zero | unit | `bin/agent-prompts-content-test.sh` (Task 5 assertion 1) |
| §7 `release.yml` check reverts to unconditional phrasing | Edit drops the literal phrase `if the project profile names a release CI workflow` | New assertion `§7 release.yml check is profile-conditional` fires `nope` and the test exits non-zero | unit | `bin/agent-prompts-content-test.sh` (Task 5 assertion 3) |
| §8 input-attribution prose silently reverts to `pipeline-release.yml` | Edit re-introduces ``Inputs supplied by `pipeline-release.yml` `` OR drops the `bin/run-release-observer.sh` reference OR drops `PIPELINE_RELEASE_VERSION` | New assertion `§8 attributes inputs to bin/run-release-observer.sh (env vars)` fires `nope` and the test exits non-zero | unit | `bin/agent-prompts-content-test.sh` (Task 5 assertion 4) |
| Profile addendum names a release workflow but the file does not exist on the target | `gh run list --workflow <name> --limit 1` returns empty | Already-existing build-agent fallback fires: post `<!-- pipeline-metric: release_trigger_missing -->` and escalate (no new code; behavior unchanged from pre-ticket) | integration | covered by existing build-stage handling — no new test needed |
| Operator deletes `learned-rules/twinning/` after reading the README and concluding they don't drive twinning | `bin/render-prompt.sh:141` resolves `learned-rules/$PROJECT_SLUG/project-profile.md` for the *active* slug only; missing `twinning/` is a no-op when `PROJECT_SLUG=harness` | No regression test — the README explicitly warns "do not delete unless you are certain"; this is a self-inflicted-wound class outside the harness's enforcement scope | n/a | (documented in §5 README; not test-locked) |
| `bin/on-new-release.sh::Part 1` documentation drifts when a future ENG-N changes the verdict-handler line numbers (`bin/verdict-handler.sh:159-167`) | Refactor of `apply_transition` shifts those lines | Comment becomes outdated but no behavior breaks; soft signal handled by future retrospectives — the comment is intentionally not test-locked (manual-review-verified per AC4) | n/a | (manual review at Task 3) |
| `bin/run-release-observer.sh:5` docstring re-acquires the stale `.github/workflows/pipeline-release.yml` reference | Refactor in unrelated work | Operator grepping for `pipeline-release.yml` once again hits a non-existent file (no behavior break) | n/a | (manual review at Task 4) |

The last three rows are intentionally not test-locked — they are bash-docstring
or filesystem-presence concerns outside the existing
`agent-prompts-content-test.sh` framework's scope. Per the brainstorm's §11
preamble, AC4 / AC5 / AC6 are manual-review verified, while AC1 / AC2 / AC3
are automated. (AC7 is a verification-gate AC the brainstorm adds in §11 — it
is not enumerated in the Linear issue's six-AC list, but the harness convention
of "every reflexive invariant gets a `*-test.sh`" makes it the natural
backstop. AC7 = `bash bin/agent-prompts-content-test.sh` exits 0 with the four
new assertions in PASS state.)

## Test Strategy

- **Unit (locked invariants).** Four new assertions in
  `bin/agent-prompts-content-test.sh` (Task 5) lock the §2/§7/§8 prompt
  invariants. Run via `bash bin/agent-prompts-content-test.sh`; success =
  RESULTS line shows `+4 PASS` versus the pre-ticket baseline. The existing
  PASS/FAIL bookkeeping at lines 12–14 handles the new assertions without
  framework changes.

- **Unit (fence-count regression backstop).** `bin/render-prompt-test.sh` is the
  authoritative test for the column-0 fence-pair contract per stage
  (`STAGE_TO_SECTION` × exactly-2-fences). Tasks 1 and 2 add content inside
  existing fences; running this test post-edit catches any accidental column-0
  fence introduction. No new assertions — the existing test is the regression
  backstop.

- **Syntax (interpreted-bash gate).** `bash -n bin/on-new-release.sh` and
  `bash -n bin/run-release-observer.sh` after Tasks 3 and 4 confirm the comment
  edits did not break script parsing. Listed as project-profile lint gate at
  `learned-rules/harness/project-profile.md:18`.

- **Integration / smoke.** A `PIPELINE_DRY_RUN=1 TARGET_REPO=… bash bin/render-prompt.sh plan ENG-52`
  invocation after Task 1 emits the §2 body with both api-contract examples
  rendered verbatim (no token substitution on the example content). This is a
  smoke verification, not a new automated test.

- **Adversarial.** None warranted. All changes are content edits inside fenced
  blocks; there is no new control flow, no new error path, no new env-var
  handling. The brainstorm explicitly avoids touching ENG-46 secret-handling
  surface (verified by the security persona's PASS).

- **Coverage map.** Failure-Mode rows 1–5 are unit-test-locked. Rows 6–9 are
  manual-review-verified per the brainstorm's AC table. Total automated
  coverage: 4 new assertions + 2 existing tests reused as regression backstops.
