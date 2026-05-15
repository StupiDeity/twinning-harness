---
linear: ENG-101
date: 2026-05-15
topic: AGENT_PROMPTS.md §3 (Implementation Agent) + §5 (Review Agent) — add Defensive-code restraint clause (write-side bullet inside Self-review block; review-side paragraph inside Anti-bias pass) operationalising the system-prompt rule against internal-invariant defensiveness; four positive-marker pins in bin/agent-prompts-content-test.sh
---

# Plan — ENG-101 Prompt-side defensive-code restraint clause for implement + review agents

Implementation plan for the design at
`docs/brainstorms/2026-05-15-eng-101-prompt-side-defensive-code-restraint-clause-for-implement-review-agents-design.md`.

## Anti-anchoring check

- **Problem (operator's words).** The Claude Code system prompt carries
  the rule "Don't add error handling, fallbacks, or validation for
  scenarios that can't happen. Trust internal code and framework
  guarantees. Only validate at system boundaries." `AGENT_PROMPTS.md`
  does not cite this rule today. The dispatched implement agent
  therefore drifts toward defensive coding (`try/except`, nil-guards,
  validation of internal invariants), which bloats diffs, triggers
  reviewer pushback, and burns review-loop iterations.
- **Brainstorm addresses it?** Yes — D-1 adds a write-side bullet in
  §3's "Self-review before exit" block; D-2 adds a review-side
  paragraph in §5's "Anti-bias pass" block; D-3 adds four
  positive-marker pins in `bin/agent-prompts-content-test.sh`; D-4
  documents the decline-to-hoist to §0 (the two directives are
  asymmetric — write-side vs review-side — so per-section placement
  is correct). No reframe; the brainstorm sticks to the issue's
  literal AC.
- **Proportional?** Yes. Two files touched (`AGENT_PROMPTS.md`,
  `bin/agent-prompts-content-test.sh`); zero `bin/` runtime code
  change; zero schema changes; zero new exit codes; zero new Linear
  labels; zero new verdict-registry entries; zero new `{token}`
  substrings introduced (`PROMPT_RESOLVERS` registry untouched). The
  Linear issue's "What ships" clause matches exactly: §3 clause, §5
  check, no code changes outside `AGENT_PROMPTS.md`. The brainstorm
  adds the test-pin file (`bin/agent-prompts-content-test.sh`) as a
  prompt-content invariant — that is the existing harness pattern
  (ENG-46 / ENG-53 / ENG-57 / ENG-74 / ENG-77 / ENG-82 / ENG-87 /
  ENG-97 all pin clauses in this same file). Not scope creep.
- **No escalation. PROCEED.**

## Branch-base freshness

`git fetch origin main` succeeded at plan time. `git log --oneline
HEAD..origin/main` is NOT empty — two upstream commits ahead of this
branch:

```
06aa03b Merge pull request #101 from StupiDeity/fix/dispatch-trailing-gtime-cleanup-set-e-safe
9905326 fix(dispatch): trailing gtime cleanup must be set -e safe
```

Files changed upstream: `CLAUDE.md`, `README.md`, `bin/dispatch-test.sh`,
`bin/dispatch.sh`. **None of these files are in this plan's File
Structure.** The clean-drift path applies — Task 0 (rebase) is added
to Backend Tasks; all `path:line` references in this plan's
Assumption Inventory remain stable across rebase because the upstream
commits touch dispatch.sh + dispatch-test.sh + CLAUDE.md + README.md,
none of which are referenced anywhere below.

Edit-boundary keys throughout this plan use content anchors (literal
substrings unique within the target file) and treat any `path:line`
number citation as informational only. This guards against rebase-time
line-number drift even though the upstream commits do not touch the
files we edit.

## Goal

After implement runs:

1. `bash bin/agent-prompts-content-test.sh` exits 0 with four new
   ENG-101 assertions passing: (a) §3 carries the literal substring
   `**Defensive-code restraint:**`; (b) §3 carries the AVOID example
   token `try/except: pass`; (c) §3 carries both boundary heuristic
   tokens `controllers/` AND `internal/`; (d) §5 carries the
   `**Defensive-code restraint:**` bold header AND the `[major]`
   severity token co-occurring in the same body block.
2. `bash bin/render-prompt-test.sh` continues to exit 0 (§3 and §5
   column-0 fence counts stay at exactly 2; both inserts are inside
   the existing fenced blocks).
3. `bash bin/render-prompt-rc0-test.sh` continues to exit 0 (every
   dispatch-time stage — `brainstorming planning implementing ui
   reviewing qa building` — exec()s `bash bin/render-prompt.sh
   <stage> ENG-X` with rc=0).
4. `bash .githooks/pre-commit` exits 0 (entire `bin/*-test.sh` suite
   green).
5. A future implementing dispatch reads the §3 bullet during
   self-review and either removes added internal-invariant defensive
   code OR commits a `Defensive: <reachable-failure-mode>` justification
   in the commit body. A future reviewing dispatch reads the §5
   paragraph and flags uncited internal-site defensive code as
   `[major]` (triggering review-loopback to implementing per the
   path-B decision branch).

Verifiable by:

```
bash bin/agent-prompts-content-test.sh \
  && bash bin/render-prompt-test.sh \
  && bash bin/render-prompt-rc0-test.sh \
  && bash .githooks/pre-commit
```

exiting 0.

## Plan-stage refinement (resolves OQ-3 from brainstorm §9)

The brainstorm §9 OQ-3 flagged "should the rule explicitly carve out
test code?" as a plan-stage refinement. **Decision:** add a one-line
carve-out to BOTH the §3 bullet body and the §5 paragraph body. Test
assertions look like defensive code by shape (`assert x is not None`,
`expect(x).toBeDefined()`) but ARE the validation, not guards against
non-occurring conditions. The carve-out wording is identical in both
sites to keep the implementer and reviewer aligned:

> Test code (paths under `tests/`, `__tests__/`, `*-test.sh`,
> `*_test.go`, `*.spec.*`) is exempt — test assertions ARE the
> validation, not defensive guards.

The exact §3 + §5 new_string blocks below incorporate this carve-out.

## Assumption Inventory

Every modified-file fact below is `path:line`-cited against the
current worktree HEAD. Quoted excerpts are exact substrings to
preserve in `Edit::old_string` calls. Bare line numbers appear ONLY
as informational hints alongside a content anchor; the literal
content-anchor strings are what the Edit calls match.

### Files modified in this plan: 2

- `AGENT_PROMPTS.md` (two edit sites — Task 2 §3 Self-review bullet
  inserted between the "Gate commands" bullet and the "Iterate until
  zero P0" closing bullet; Task 3 §5 Anti-bias paragraph inserted
  between the "Simplicity check" paragraph close and the
  "Scope enforcement" paragraph header)
- `bin/agent-prompts-content-test.sh` (one new ENG-101 §3/§5-scoped
  assertion block, four assertions)

### Branch-base freshness note

- branch-base freshness: `HEAD..origin/main` NOT empty at plan time
  (`origin/main = 06aa03b`; two commits ahead — `06aa03b` merge +
  `9905326 fix(dispatch): trailing gtime cleanup must be set -e safe`).
  Files changed upstream: `CLAUDE.md`, `README.md`,
  `bin/dispatch-test.sh`, `bin/dispatch.sh`. None overlap this plan's
  File Structure. Task 0 (rebase) is in Backend Tasks; all Edit calls
  use content anchors, so subsequent tasks survive the rebase.

### Modified-file facts — current state and verification points

- **A-001 — `AGENT_PROMPTS.md` H2 `## 3. Implementation Agent (Backend)`
  exists; §3's column-0 fence count is exactly 2.** Verified by
  `grep -n '^## ' AGENT_PROMPTS.md` (returned `606:## 3. Implementation
  Agent (Backend)` and `749:## 4. UI Agent (Frontend)`) and
  `grep -n '^\`\`\`' AGENT_PROMPTS.md` (returned `608` and `747`
  bracketing §3's body). Two column-0 fences for §3, line range
  608–747 inclusive.

- **A-002 — `AGENT_PROMPTS.md` §3 contains the "Self-review before
  exit" block.** Verified by direct read. The block opens with the
  literal line `Self-review before exit (MANDATORY — drive P0
  findings to zero):` (~line 686) and contains four bullets — `Premise-match`
  (~line 687-689), `Contract match` (~line 690), `Test-map match`
  (~line 691-692), `Gate commands` (~line 693) — plus a closing
  bullet `- Iterate until zero P0. If you cannot, STOP, comment
  \`<!-- meta: metric name=impl_escalate -->\` with what is failing,
  and exit without advancing.` (~line 694-695). The closing bullet
  is the universal escalation that applies to all preceding bullets.

- **A-003 — `AGENT_PROMPTS.md` §3 Self-review block trailing
  insertion anchor.** Content anchor for Task 2's Edit (the literal
  closing line of `Gate commands` and the literal opening of `Iterate
  until zero P0`, both unique within `AGENT_PROMPTS.md`):

  - START anchor (preserved as bookend): the literal bullet
    `  - **Gate commands:** every gate listed in the profile's "Build & test gates" section passes.`
  - END anchor (preserved as bookend): the literal closing bullet
    `  - Iterate until zero P0. If you cannot, STOP, comment \`<!-- meta: metric name=impl_escalate -->\``

  The new Defensive-code restraint bullet is inserted between these
  two anchors. Both anchor strings appear EXACTLY ONCE in the file
  (verified by Grep on both strings — see Task 2 verification step).

- **A-004 — `AGENT_PROMPTS.md` H2 `## 5. Review Agent` exists; §5's
  column-0 fence count is exactly 2.** Verified by
  `grep -n '^## ' AGENT_PROMPTS.md` (returned `890:## 5. Review Agent`
  and `1108:## 6. QA Agent`) and `grep -n '^\`\`\`' AGENT_PROMPTS.md`
  (returned `892` and `1106` bracketing §5's body). Two column-0
  fences for §5, line range 892–1106 inclusive.

- **A-005 — `AGENT_PROMPTS.md` §5 "Anti-bias pass" block contains
  the Premise challenge / Workaround detection / Simplicity check /
  Scope enforcement / Review-comment quality rubric paragraphs in
  that order.** Verified by direct read of lines 948–996. Block opens
  with `Anti-bias pass (MANDATORY — do this YOURSELF; do not
  delegate to ensemble):` (~line 948). Subsequent paragraphs:
  - `**Premise challenge:**` (~line 950)
  - `**Workaround detection:**` (~line 961)
  - `**Simplicity check:** Could this PR be 30 % smaller and still
    achieve the goal? Any abstraction used only once? Any increase
    in crate / module / indirection count unjustified by the plan?`
    (~line 966–968)
  - `**Scope enforcement (HARD REJECT, with safety valve):**` (~line 970)
  - `**Review-comment quality rubric (MANDATORY — applies to every
    PR comment you post):**` (~line 981)

- **A-006 — `AGENT_PROMPTS.md` §5 Anti-bias pass insertion anchor
  between Simplicity check and Scope enforcement.** Content anchor
  for Task 3's Edit (both anchor strings appear EXACTLY ONCE in the
  file):

  - START anchor (preserved as bookend): the literal closing
    sentence of the Simplicity check paragraph —
    `**Simplicity check:** Could this PR be 30 % smaller and still achieve the goal? Any`
    + the next two lines forming the full Simplicity check paragraph.
    Full 3-line excerpt as it appears in the file:
    ```
    **Simplicity check:** Could this PR be 30 % smaller and still achieve the goal? Any
      abstraction used only once? Any increase in crate / module / indirection count
      unjustified by the plan?
    ```
  - END anchor (preserved as bookend): the literal Scope enforcement
    header — `**Scope enforcement (HARD REJECT, with safety valve):**`
  - The blank line between Simplicity check and Scope enforcement is
    preserved (the new paragraph + a blank line is inserted in place
    of the single bookkeeping blank line).

- **A-007 — `bin/render-prompt.sh::extract_block` dies on any section
  whose column-0 fence count is not exactly 2.** Verified by direct
  read of `bin/render-prompt.sh:111-113`:

  ```bash
  if [[ "$fence_count" != "2" ]]; then
    die "AGENT_PROMPTS.md schema error: section '$section' has $fence_count column-0 fences (expected 2). Check for stray \`\`\` lines or a missing closing fence."
  fi
  ```

  Both Task 2 and Task 3 inserts are inside the existing fenced
  blocks (§3 between fences 608/747; §5 between fences 892/1106).
  The new bullet body in §3 and the new paragraph in §5 contain NO
  column-0 ` ``` ` lines — only indented prose. The fence counts for
  §3 and §5 stay at exactly 2.

- **A-008 — `bin/render-prompt.sh::resolve_block_tokens` dies on any
  `{token}` substring in the rendered output not in PROMPT_RESOLVERS
  or AGENT_RUNTIME_TOKENS.** Verified per
  `bin/agent-prompts-content-test.sh:1232-1265` (the ENG-87
  token-coverage assertion at the end of the file). The new §3 bullet
  and §5 paragraph contain ZERO `{token}` substrings — the body text
  refers to "the profile's File layout" as prose (not a token),
  `Defensive: <why this is a real-world reachable failure mode>` (the
  `<>` shape is plain-prose placeholder, not a `{token}`), and uses
  literal Markdown like `` `try/except: pass` ``. No `PROMPT_RESOLVERS`
  registry entry is needed.

- **A-009 — `bin/agent-prompts-content-test.sh` structure: helpers
  `section_body`, `rendered_stage_body`, `ok`, `nope` defined at
  lines 13–40; final results gate at lines 1267–1269.** Verified by
  direct read. `wc -l bin/agent-prompts-content-test.sh` returned
  `1269`. Task 4's new ENG-101 block is inserted BEFORE the final
  results printf at line 1267; specifically, anchored AFTER the
  ENG-87 token-coverage block at line 1265 (the `fi` closing the
  outer `if [[ -f "$RENDER_PROMPT_SH" ]]`) so the new block sits at
  the end of the test file, adjacent to other prompt-content
  invariants.

- **A-010 — `bin/agent-prompts-content-test.sh` final exit gate.**
  Verified by direct read of lines 1267–1269:

  ```bash
  printf '\nRESULTS: %d passed, %d failed\n' "$PASS" "$FAIL"
  [[ "$FAIL" == 0 ]] || exit 1
  exit 0
  ```

  Task 4's insertion point is BEFORE this final printf. Content
  anchor (literal three-line excerpt, appears exactly once in the
  file): the closing brace `fi` of the ENG-87 token-coverage block
  at line 1265, followed by the blank line at line 1266, followed by
  `printf '\nRESULTS: %d passed, %d failed\n' "$PASS" "$FAIL"` at
  line 1267. The new ENG-101 assertion block is inserted between the
  `fi` and the `printf` line.

- **A-011 — `bin/agent-prompts-content-test.sh:20-28` defines the
  `section_body` helper used by every §N-scoped assertion.** Verified
  by direct read:

  ```bash
  section_body() {
    local heading="$1"
    awk -v h="$heading" '
      BEGIN{in_section=0; in_fence=0}
      /^```/{if (in_section) in_fence = !in_fence}
      /^## /{ if (in_section && !in_fence) exit; if (!in_section && index($0, h)) {in_section=1; next} }
      in_section{print}
    ' "$PROMPTS"
  }
  ```

  Task 4's new block uses `s3="$(section_body "## 3. Implementation
  Agent (Backend)")"` (matches the heading at line 606) and
  `s5_eng101="$(section_body "## 5. Review Agent")"` (matches the
  heading at line 890). Both heading literals exist exactly once.

- **A-012 — `bin/agent-prompts-content-test.sh:13-14` defines the
  `ok` and `nope` helpers.** Verified by direct read:

  ```bash
  ok()   { printf 'OK: %s\n' "$1"; PASS=$((PASS+1)); }
  nope() { printf 'FAIL: %s\n  reason: %s\n' "$1" "$2" >&2; FAIL=$((FAIL+1)); }
  ```

  Task 4's four new assertions call these helpers identically to the
  existing ENG-82 §6 block at lines 1113–1138 (which is the
  most-recently-added per-stage positive-marker pin set, and is the
  shape Task 4 mirrors).

- **A-013 — `bin/render-prompt-test.sh` does not assert §3 or §5
  content-level pins; only resolver behavior + addendum behavior.**
  Verified by `Grep` for `defensive|try/except|controllers/|nil-guard|
  Defensive-code` in `bin/render-prompt-test.sh`: zero matches. The
  Task 2 and Task 3 §3/§5 inserts do NOT break
  `bin/render-prompt-test.sh`.

- **A-014 — `bin/render-prompt-rc0-test.sh` is 119 lines and at line
  113 iterates every dispatch-time stage (`brainstorming planning
  implementing ui reviewing qa building`).** Verified by direct read
  of full file. Each stage exec()s `bash bin/render-prompt.sh
  <stage> ENG-X` and asserts rc=0. A column-0 fence regression in §3
  or §5 (introduced by an errant Task 2/Task 3 Edit) would die at
  `extract_block` (per A-007) and the corresponding stage assertion
  would fail. End-to-end backstop is in place.

- **A-015 — `.githooks/pre-commit` runs the full `bin/*-test.sh`
  suite at commit time.** Verified per
  `CLAUDE.md::## Tests / Pre-commit hook`. All three test files
  (`bin/agent-prompts-content-test.sh`, `bin/render-prompt-test.sh`,
  `bin/render-prompt-rc0-test.sh`) are `bin/*-test.sh` files; the
  implement agent's pre-commit gate catches any regression.

- **A-016 — `bin/agent-prompts-content-test.sh` already pins ENG-82
  per-stage positive markers in the same shape D-3 prescribes for
  ENG-101.** Verified by direct read of lines 1113–1138 (the ENG-82
  §6 back-fill clause block):

  ```bash
  s6="$(section_body "## 6. QA Agent")"
  if printf '%s\n' "$s6" | grep -qiF 'back-fill'; then
    ok "§6 ENG-82: carries 'back-fill' detection clause"
  else
    nope "§6 ENG-82: carries 'back-fill' detection clause" \
         "phrase missing — QA agent will re-derive the workaround per dispatch"
  fi
  # ... two more similar grep-qF assertions
  unset s6
  ```

  Task 4's new ENG-101 block uses the SAME shape: `section_body` into
  a stage-scoped variable, `grep -qF` for literal substring, paired
  `ok`/`nope` per assertion, `unset` at the end.

- **A-017 — Test-gate closure sweep: tokens REMOVED from any tracked
  file by this plan = zero.** This plan ONLY INSERTS content
  (`AGENT_PROMPTS.md` gains two clauses; `bin/agent-prompts-content-test.sh`
  gains one assertion block). No tokens are renamed, dropped,
  enum-variant-removed, default-changed, or otherwise deleted from
  production code. The test-gate closure sweep has no removals to
  verify. Defensive check on additions (confirming the new tokens
  aren't pinned-ABSENT by any sibling test):

  - `**Defensive-code restraint:**` — `Grep` on `bin/*-test.sh` for
    `Defensive-code restraint` returns zero matches. Safe.
  - `try/except: pass` — `Grep` on `bin/*-test.sh` returns zero
    matches. Safe.
  - `controllers/`, `internal/` (path-class tokens) — `Grep` on
    `bin/*-test.sh` for the literal `controllers/` returns zero
    matches; `Grep` for `internal/` returns matches in unrelated
    contexts (`HARNESS_STATE_DIR`, comment text about "internal
    state") but no assertion pins `internal/` as ABSENT from
    `AGENT_PROMPTS.md`. Safe.
  - `[major]` — already present in `AGENT_PROMPTS.md` (the §5
    Decision-path B language uses `[major]` as the severity token);
    no sibling test pins it as ABSENT. Safe.
  - Idiomatic-propagation carve-out tokens (Go `if err != nil`, Rust
    `?`, Ruby `raise`) — `Grep` on `bin/*-test.sh`: no matches that
    pin these as ABSENT from `AGENT_PROMPTS.md`. Safe.
  - Test-code carve-out tokens (`tests/`, `__tests__/`, `*-test.sh`,
    `*_test.go`, `*.spec.*`) — `Grep` on `bin/*-test.sh`: no matches
    that pin these as ABSENT from `AGENT_PROMPTS.md`. The literal
    `*-test.sh` glob appears in CLAUDE.md and shell scripts but not
    as a content-absence assertion. Safe.

  Tokens whose ABSENCE is asserted that this plan must not violate:

  - `bin/agent-prompts-content-test.sh:148` runs the ENG-97
    `forbidden_token` loop over `Tauri`, `tauri::`, `tauri.conf.json`,
    `src-tauri/`, `cargo test -- --list`, `invoke(`. Task 2 and Task 3
    inserts contain NONE of these tokens (the body uses
    stack-agnostic prose; the boundary heuristic names path classes
    like `controllers/`, `lib/`, etc., NOT Tauri-shaped tokens).
    Safe.
  - `bin/agent-prompts-content-test.sh:161` case-insensitive
    `tauri` whole-file scan. Neither insert contains any `tauri`
    substring (case-insensitive). Safe.
  - `bin/agent-prompts-content-test.sh:298-302` pins absence of
    `<!-- pipeline: verdict result=wait reason=awaiting-approval -->`
    in §5. Neither §5 insert contains this marker. Safe.
  - `bin/agent-prompts-content-test.sh:277-280` pins absence of
    `gh pr review --approve` in §5. Neither §5 insert contains this
    string. Safe.
  - `bin/agent-prompts-content-test.sh:283-286` pins absence of
    `gh pr review --request-changes` in §5. Neither §5 insert
    contains this string. Safe.
  - `bin/agent-prompts-content-test.sh:1065`-area forbids
    `env VAR=val bash bin/...` shape anywhere in `AGENT_PROMPTS.md`.
    Neither insert contains an env-var-prefixed bash invocation.
    Safe.
  - `bin/agent-prompts-content-test.sh:1176-1185` (ENG-87 iter-7 M4)
    caps occurrences of the `MANDATORY — overwrite on every dispatch`
    phrase at ≤2 across the file. Neither §3 nor §5 insert contains
    this phrase. Safe.

  **Conclusion:** zero test-gate closure defects. No sibling test
  file needs editing.

- **A-018 — `bin/render-prompt.sh::STAGE_TO_SECTION` does not need
  to change.** Verified per the brainstorm A-29. The dispatch-time
  stages map to the same H2 sections (`implementing` → `## 3.`,
  `reviewing` → `## 5.`); the insertions go INSIDE the existing
  section bodies; no section identifier changes.

- **A-019 — `bin/pipeline-events.json` (verdict registry) does not
  need to change.** No new verdict variant. The §5 review-loopback
  for `[major]` defensive-code findings uses the existing
  `verdict fail --target implementing` event (see §5 Decision-path
  B at `AGENT_PROMPTS.md:1018-1034` — verified by direct read).

- **A-020 — `failure_outcome_for_exit` in `bin/common.sh` does not
  need a new exit code.** No new exit code added by this plan; both
  agents continue to exit 0 on clean (and existing taxonomy codes
  on failure paths).

- **A-021 — `bin/render-prompt-slug-test.sh` does not pin any §3 or
  §5 content.** Verified by `Grep -E 'defensive|try/except|Defensive-code|
  controllers/' bin/render-prompt-slug-test.sh`: zero matches. Task
  2 and Task 3 do not break this test.

- **A-022 — Plan doc basename satisfies
  `partition_dirty_paths::D-004`.** The plan filename
  `2026-05-15-eng-101-prompt-side-defensive-code-restraint-clause-for-implement-review-agents.md`
  contains the `eng-101` token (lowercase) in the basename at the
  correct position for in-scope bucketing. ✓

- **A-023 — `learned-rules/harness/plan.md` does not exist.**
  Verified by `ls learned-rules/harness/`: returns only `build.md`
  and `project-profile.md`. Per the plan prompt preamble, no
  learned-rules to apply (skip-if-not-present).

- **A-024 — `learned-rules/harness/implementation.md` and
  `learned-rules/harness/review.md` do not exist.** Verified per
  brainstorm A-15. The Linear issue's "Out of scope" clause for
  learned-rules carries cleanly — there is no existing file to
  drift against.

- **A-025 — The implementing-stage Bash tool allowlist (per the
  harness profile) includes `Bash(bash bin/agent-prompts-content-test.sh:*)`
  AND `Bash(bash bin/render-prompt-test.sh:*)` AND
  `Bash(bash .githooks/pre-commit:*)`.** Verified per this
  dispatch's Project profile addendum, `## Tool allowlist`,
  `implementing` section. The implement agent CAN run all three
  test files at exit-time without an allowlist change. (Note:
  `bin/render-prompt-rc0-test.sh` is in the profile's allowlist via
  the enumerated `Bash(bash bin/render-prompt-test.sh:*)` pattern's
  sibling — but actually distinct; verified independently in the
  profile's enumerated list at lines for `implementing`. Both
  `render-prompt-test.sh` and `render-prompt-rc0-test.sh` are listed
  separately and explicitly.)

- **A-026 — Upstream commits on `origin/main` since branch creation
  do NOT touch any file in this plan's File Structure.** Verified
  by `git log --oneline --name-only HEAD..origin/main`:

  ```
  06aa03b Merge pull request #101 from StupiDeity/fix/dispatch-trailing-gtime-cleanup-set-e-safe
  9905326 fix(dispatch): trailing gtime cleanup must be set -e safe
  CLAUDE.md
  README.md
  bin/dispatch-test.sh
  bin/dispatch.sh
  ```

  Files touched: `CLAUDE.md`, `README.md`, `bin/dispatch-test.sh`,
  `bin/dispatch.sh`. None overlap `AGENT_PROMPTS.md` or
  `bin/agent-prompts-content-test.sh`. Task 0 (rebase) is the clean-
  drift path; subsequent Tasks 2-5 survive the rebase because Edit
  calls use content anchors (literal substrings) rather than bare
  line numbers.

- **A-027 — Branch prefix matches Improvement label.** Branch name
  (from git status): `feat/eng-101-prompt-side-defensive-code-restraint-clause-for-implement-review-agents`.
  CLAUDE.md confirms `feat/` = Feature/Improvement. ✓

## File Structure

Modified files only — no new files, no new test scripts, no new
dependencies, no new Linear labels, no new exit codes.

- `AGENT_PROMPTS.md` — two edit sites, both INSIDE existing fenced
  blocks. §3 column-0 fence count stays at exactly 2 (existing fences
  at lines 608 and 747 unchanged). §5 column-0 fence count stays at
  exactly 2 (existing fences at lines 892 and 1106 unchanged):
  - Task 2: insert ~22 lines of indented bullet body inside §3's
    "Self-review before exit" block, between the existing
    `**Gate commands:**` bullet (~line 693) and the closing
    `- Iterate until zero P0` bullet (~line 694). Content anchors
    in A-003.
  - Task 3: insert ~17 lines of paragraph body inside §5's "Anti-bias
    pass" block, between the existing `**Simplicity check:**`
    paragraph close (~line 968) and the `**Scope enforcement (HARD
    REJECT, with safety valve):**` paragraph header (~line 970).
    Content anchors in A-006.
- `bin/agent-prompts-content-test.sh` — one new ENG-101 assertion
  block inserted BEFORE the final results printf at line 1267
  (anchor: AFTER the ENG-87 token-coverage block's closing `fi` at
  line 1265, BEFORE the `printf '\nRESULTS: ...'` line at 1267).
  Four assertions:
  - (a) `s3="$(section_body "## 3. Implementation Agent (Backend)")"`
    → §3 carries the literal `**Defensive-code restraint:**` header
    (via `grep -qF`).
  - (b) §3 carries the AVOID example token `try/except: pass` (via
    `grep -qF`).
  - (c) §3 carries BOTH `controllers/` AND `internal/` boundary
    heuristic tokens (via two `grep -qF` chained with `&&`).
  - (d) `s5_eng101="$(section_body "## 5. Review Agent")"` → §5
    carries `**Defensive-code restraint:**` AND `[major]`
    co-occurring (via two `grep -qF` chained with `&&`).

  Each assertion uses the existing `section_body`/`ok`/`nope`
  helpers; no helper functions added. The block ends with
  `unset s3 s5_eng101` to keep the test file's variable hygiene
  consistent with the ENG-82 §6 block at line 1138.

Explicitly out of scope (per brainstorm §10 + Linear issue's "Out of
scope" clause):

- `bin/dispatch.sh`, `bin/run-stage.sh`, `bin/run-local.sh`,
  `bin/poll.sh`, `bin/verdict-handler.sh`, `bin/scope-check.sh`,
  `bin/render-prompt.sh`, `bin/run-local-helpers.sh`,
  `bin/linear.sh`, `bin/common.sh` — unchanged.
- `bin/pipeline-events.json` — unchanged (no new verdict variant).
- `bin/common.sh::failure_outcome_for_exit` — unchanged (no new
  exit code).
- `learned-rules/harness/*.md` — unchanged (per Linear issue's
  "Out of scope" clause: edits to `learned-rules/implementation.md`
  and `learned-rules/review.md` are retrospective-owned). These
  files do not exist today for the harness slug.
- `CLAUDE.md` — unchanged (the prompt-stage clauses are
  §3/§5-specific; documenting them in CLAUDE.md duplicates the
  drift surface).
- `AGENT_PROMPTS.md` §4 (UI Agent), §6 (QA Agent), §0 (Common rules)
  — unchanged (brainstorm D-4 documents the decline-to-hoist to §0;
  §4 / §6 deferred per brainstorm §9 OQ-1).
- `bin/render-prompt-test.sh`, `bin/render-prompt-rc0-test.sh` —
  unchanged (content-pinning lives in `bin/agent-prompts-content-test.sh`
  per brainstorm §9 OQ-7; the rc0 test is unchanged but provides the
  end-to-end fence-count backstop for §3/§5).
- New detective scripts (regex / Haiku judge) — not added. Brainstorm
  §10 documents Option A as rejected outright and Option B as the
  escalation path conditioned on observed misses.

## API Contract

no new API surface

(The harness has no FE↔BE API surface of its own — it is a Bash
orchestration toolkit. The `api-contract` block being referenced
elsewhere in `AGENT_PROMPTS.md` is prompt content delivered to the
Plan agent's output schema, not the harness's own API. This plan
adds neither endpoints, payload types, nor schema fields.)

## Backend Tasks

Tasks 1, 2, 3 can run in any order after Task 0 completes (the
rebase). Task 4 depends on Tasks 2 and 3 because its assertions
verify the §3 and §5 inserts landed. Task 5 (gate run) depends on
Tasks 2, 3, 4. The implement agent SHOULD complete Task 0 first,
then any order of {Task 2, Task 3}, then Task 4, then Task 5. Task 1
is a no-code feasibility re-check immediately post-rebase.

### Task 0: Rebase onto origin/main

- `depends_on: []`
- `touches: <git working tree only — no file edits>`

Steps:

- [ ] **0.1** Run `git fetch origin main`. Expect zero failures; if
  the fetch errors (network / auth), halt with
  `bash bin/pipeline.sh event ENG-101 verdict halt --reason agent-blocked`
  and a Linear comment naming the failure.
- [ ] **0.2** Run `git rebase origin/main`. Expected outcome: clean
  rebase, no conflicts (the upstream commits touch
  `CLAUDE.md`, `README.md`, `bin/dispatch-test.sh`, `bin/dispatch.sh`
  — none overlap this plan's File Structure per A-026). If a
  conflict occurs unexpectedly, halt with
  `verdict halt --reason agent-blocked` and a comment naming the
  conflicting paths.
- [ ] **0.3** Force-push the rebased branch:
  `git push --force-with-lease origin feat/eng-101-prompt-side-defensive-code-restraint-clause-for-implement-review-agents`.
  Use `--force-with-lease` to avoid clobbering any concurrent push
  to the same branch.

### Task 1: Re-verify Assumption Inventory anchors survived the rebase

- `depends_on: [0]`
- `touches: <read-only — no file edits>`

Steps:

- [ ] **1.1** Re-grep `AGENT_PROMPTS.md` for the two §3 anchor
  substrings (per A-003):
  - `**Gate commands:** every gate listed in the profile's "Build & test gates" section passes.`
  - `Iterate until zero P0. If you cannot, STOP, comment`
  Both MUST match exactly once. If either is absent OR appears more
  than once, halt with
  `verdict halt --reason agent-blocked` and a comment naming the
  drift.
- [ ] **1.2** Re-grep `AGENT_PROMPTS.md` for the two §5 anchor
  substrings (per A-006):
  - `**Simplicity check:** Could this PR be 30 % smaller and still achieve the goal? Any`
  - `**Scope enforcement (HARD REJECT, with safety valve):**`
  Both MUST match exactly once. Same halt-on-drift behavior as 1.1.
- [ ] **1.3** Re-grep `bin/agent-prompts-content-test.sh` for the
  Task 4 anchor (per A-010): the literal 3-line excerpt of `fi` +
  blank + `printf '\nRESULTS:` MUST match exactly once. Same
  halt-on-drift behavior.

If all three sub-steps pass, proceed to Tasks 2 / 3 / 4 in any
order.

### Task 2: Insert §3 Self-review defensive-code restraint bullet in AGENT_PROMPTS.md (brainstorm D-1)

- `depends_on: [1]`
- `touches: AGENT_PROMPTS.md` — §3 Self-review block, between the
  `**Gate commands:**` bullet and the `- Iterate until zero P0`
  closing bullet (per A-003)

Steps:

- [ ] **2.1** Use a single `Edit` call with multi-line `old_string`
  anchored on the unique closing line of the `Gate commands` bullet
  AND the trailing `Iterate until zero P0` opening line. Both anchor
  substrings appear EXACTLY ONCE in `AGENT_PROMPTS.md` (Task 1
  verified).

  Exact `old_string` (3 lines as they appear in the file):

  ```
    - **Gate commands:** every gate listed in the profile's "Build & test gates" section passes.
    - Iterate until zero P0. If you cannot, STOP, comment `<!-- meta: metric name=impl_escalate -->`
      with what is failing, and exit without advancing.
  ```

  Exact `new_string` (replacement — inserts the new Defensive-code
  restraint bullet between the two anchors, preserving both bounding
  bullets and their indentation):

  ```
    - **Gate commands:** every gate listed in the profile's "Build & test gates" section passes.
    - **Defensive-code restraint:** scan your own diff for added code
      that validates internal invariants or guards against scenarios
      that cannot occur given the rest of the change. The system prompt's
      rule applies: "Don't add error handling, fallbacks, or validation
      for scenarios that can't happen. Trust internal code and framework
      guarantees. Only validate at system boundaries."
        AVOID — internal-invariant defensiveness:
          - `try/except: pass` (or `catch (...) {}`) around code you
            control end-to-end on the call path.
          - `if x is None: return None` / `unless x.nil?` /
            `if (!x) return` on values your own code just produced.
          - `assert x is not None` followed by a fallback when the
            producer already guarantees non-nil.
        LEGITIMATE — boundary validation:
          - Parsing CLI args / env vars (user input crossing the
            process boundary).
          - Validating the shape of an HTTP request body or external
            API response.
          - Decoding bytes from a file or socket the caller does not
            own.
        Boundary heuristic — path-based:
          - Boundary: `controllers/`, `handlers/`, `routes/`, `api/`,
            `cli/`, `main.*` and the entrypoint binaries the profile's
            File layout names. Defensive validation here is correct.
          - Internal: `lib/`, `internal/`, `services/`, `domain/`, and
            the implementation-detail directories the profile names.
            Defensive validation here is a self-review failure.
        Test code (paths under `tests/`, `__tests__/`, `*-test.sh`,
          `*_test.go`, `*.spec.*`) is exempt — test assertions ARE the
          validation, not defensive guards.
        Idiomatic language error handling (Go `if err != nil { return err }`,
          Rust `?`, Ruby `raise`) is NOT in scope — those propagate, they
          do not swallow.
        If you add defensive code at an internal site, cite the
        boundary justification in the commit message body (one line:
        `Defensive: <why this is a real-world reachable failure mode>`)
        OR remove the code before exit. A bullet in the self-review
        that says "added try/except for safety" without a concrete
        reachable-failure citation is a P0.
    - Iterate until zero P0. If you cannot, STOP, comment `<!-- meta: metric name=impl_escalate -->`
      with what is failing, and exit without advancing.
  ```

  Notes:
  - The bullet is column-2 indented (`  -`) to match the surrounding
    `Premise-match`, `Contract match`, `Test-map match`, and
    `Gate commands` bullets.
  - The body uses 4-space sub-indentation (matching the surrounding
    sub-bullets like `if you cannot, STOP, comment` in the closing
    bullet). The example AVOID / LEGITIMATE / Boundary heuristic
    sub-sections use 6/8-space indentation for their bullets.
  - NO column-0 ` ``` ` fence is introduced. The fence count for §3
    stays at exactly 2 (existing fences at lines 608 and 747 are
    unaffected per A-007).
  - The body uses ONLY plain-prose tokens — no `{token}` substring
    is introduced (per A-008). `<why this is a real-world reachable
    failure mode>` uses literal `<>` (plain-prose placeholder), not
    `{` / `}`.
  - The test-code carve-out + idiomatic-propagation carve-out are
    BOTH included (resolves brainstorm §9 OQ-3; mirrors §5's
    idiomatic-propagation carve-out).

- [ ] **2.2** Verify by reading back `AGENT_PROMPTS.md` ~25 lines
  AFTER the original `Gate commands` bullet. Confirm: (a) `Gate
  commands` bullet is preserved verbatim; (b) the new
  `**Defensive-code restraint:**` bullet appears immediately below;
  (c) the closing `Iterate until zero P0` bullet is preserved
  verbatim; (d) no column-0 ` ``` ` appears in the inserted block.

- [ ] **2.3** Sanity-check §3 column-0 fence count is still exactly
  2 by running `bash bin/render-prompt-test.sh` (this test's
  fence-count assertions cover §2; the §3 fence count is covered
  end-to-end by `bin/render-prompt-rc0-test.sh::implementing`). If
  either fails, the Edit introduced a stray column-0 fence — revert
  with `git checkout -- AGENT_PROMPTS.md` and re-apply with the
  fence removed.

### Task 3: Insert §5 Anti-bias defensive-code restraint paragraph in AGENT_PROMPTS.md (brainstorm D-2)

- `depends_on: [1]`
- `touches: AGENT_PROMPTS.md` — §5 Anti-bias pass block, between the
  `**Simplicity check:**` paragraph close and the `**Scope
  enforcement:**` paragraph header (per A-006)

Steps:

- [ ] **3.1** Use a single `Edit` call with multi-line `old_string`
  anchored on the unique closing line of `Simplicity check` AND the
  trailing `Scope enforcement` header. Both anchor substrings appear
  EXACTLY ONCE in `AGENT_PROMPTS.md` (Task 1 verified).

  Exact `old_string` (5 lines as they appear in the file — Simplicity
  check is 3 lines + blank line + Scope enforcement header):

  ```
  **Simplicity check:** Could this PR be 30 % smaller and still achieve the goal? Any
    abstraction used only once? Any increase in crate / module / indirection count
    unjustified by the plan?

  **Scope enforcement (HARD REJECT, with safety valve):**
  ```

  Exact `new_string` (replacement — inserts the new Defensive-code
  restraint paragraph between the two anchors, preserving both
  bounding paragraphs and their spacing):

  ```
  **Simplicity check:** Could this PR be 30 % smaller and still achieve the goal? Any
    abstraction used only once? Any increase in crate / module / indirection count
    unjustified by the plan?

  **Defensive-code restraint:** scan added / changed code for try-blocks,
    nil-guards, and internal-invariant validation. For each occurrence,
    require ONE of:
      (a) the file path is a boundary (`controllers/`, `handlers/`,
          `routes/`, `api/`, `cli/`, `main.*`, or an entrypoint binary the
          profile's File layout names), OR
      (b) the commit message body OR the diff's surrounding context cites
          the concrete reachable-failure mode the defensive code addresses.
    Otherwise flag the occurrence as `[major] <path>:<line> — defensive
    code at internal site; either move the check to the boundary, justify
    the failure mode in commit, or remove`. The system prompt rule the
    implementer should have followed is: "Don't add error handling,
    fallbacks, or validation for scenarios that can't happen. Trust internal
    code and framework guarantees. Only validate at system boundaries."
    Apply the same boundary heuristic the implement agent uses (path-based;
    defer to the profile's File layout for non-web stacks). Idiomatic
    language error handling (Go `if err != nil { return err }`, Rust `?`,
    Ruby `raise`) is NOT in scope — those propagate, they do not swallow.
    Test code (paths under `tests/`, `__tests__/`, `*-test.sh`, `*_test.go`,
    `*.spec.*`) is exempt — test assertions ARE the validation, not
    defensive guards.

  **Scope enforcement (HARD REJECT, with safety valve):**
  ```

  Notes:
  - The paragraph starts at column 0 (`**Defensive-code restraint:**`)
    matching the surrounding `**Premise challenge:**`, `**Workaround
    detection:**`, `**Simplicity check:**`, `**Scope enforcement:**`,
    and `**Review-comment quality rubric:**` paragraph headers in §5.
  - The body uses 2-space sub-indentation matching the surrounding
    `Simplicity check` body and the other paragraphs.
  - NO column-0 ` ``` ` fence is introduced. The fence count for §5
    stays at exactly 2 (existing fences at lines 892 and 1106 are
    unaffected per A-007).
  - The body uses ONLY plain-prose tokens — no `{token}` substring
    is introduced (per A-008). `<path>:<line>` uses literal `<>`
    (plain-prose placeholder), not `{` / `}`.
  - The carve-outs (idiomatic propagation + test code) match Task
    2's wording for cross-stage coherence — the implementer and the
    reviewer agree on what is in scope.

- [ ] **3.2** Verify by reading back `AGENT_PROMPTS.md` ~25 lines
  AFTER the original `Simplicity check` paragraph. Confirm: (a)
  `Simplicity check` paragraph is preserved verbatim; (b) the new
  `**Defensive-code restraint:**` paragraph appears immediately
  below; (c) the `Scope enforcement` header is preserved verbatim;
  (d) no column-0 ` ``` ` appears in the inserted block.

- [ ] **3.3** Sanity-check §5 column-0 fence count is still exactly
  2 by running `bash bin/render-prompt-rc0-test.sh` (which exec()s
  `bash bin/render-prompt.sh reviewing ENG-X` and would die on a
  fence-count regression per A-007 + A-014). If it fails, revert
  with `git checkout -- AGENT_PROMPTS.md` and re-apply with the
  fence removed.

### Task 4: Add ENG-101 §3/§5 positive-marker pin block in bin/agent-prompts-content-test.sh (brainstorm D-3)

- `depends_on: [2, 3]`
- `touches: bin/agent-prompts-content-test.sh` — insert one new
  assertion block BEFORE the final results printf at line 1267
  (anchor: between the closing `fi` of the ENG-87 token-coverage
  block at line 1265 and the `printf '\nRESULTS:` line at 1267,
  per A-010)

Steps:

- [ ] **4.1** Use a single `Edit` call with multi-line `old_string`
  anchored on the closing `fi` of the ENG-87 token-coverage block
  AND the `printf '\nRESULTS:` line. Both anchor substrings appear
  EXACTLY ONCE in `bin/agent-prompts-content-test.sh` (Task 1
  verified).

  Exact `old_string` (3 lines as they appear in the file —
  fi + blank + printf):

  ```
  fi

  printf '\nRESULTS: %d passed, %d failed\n' "$PASS" "$FAIL"
  ```

  Exact `new_string` (replacement — inserts the ENG-101 block
  between the bounding `fi` and `printf`):

  ```
  fi

  # ─── ENG-101: §3 Self-review + §5 Anti-bias defensive-code restraint ──
  # Without these pins, a future "cleanup" pass that strips the §3
  # bullet or §5 paragraph would pass every existing assertion (no
  # current assertion keys on defensive-code content). The four
  # positive-marker pins mirror the ENG-82 §6 / ENG-77 stage-summary
  # pin shapes — one assertion per token gives a per-token
  # diagnostic on failure.
  s3_eng101="$(section_body "## 3. Implementation Agent (Backend)")"
  if printf '%s\n' "$s3_eng101" | grep -qF '**Defensive-code restraint:**'; then
    ok "§3 ENG-101: carries '**Defensive-code restraint:**' Self-review bullet header"
  else
    nope "§3 ENG-101: carries '**Defensive-code restraint:**' Self-review bullet header" \
         "header missing — implement agent will not self-review for defensive code (ENG-101 D-1)"
  fi
  if printf '%s\n' "$s3_eng101" | grep -qF 'try/except: pass'; then
    ok "§3 ENG-101: carries 'try/except: pass' AVOID example token"
  else
    nope "§3 ENG-101: carries 'try/except: pass' AVOID example token" \
         "example missing — bullet body was gutted while header preserved (ENG-101 D-3 #2)"
  fi
  if printf '%s\n' "$s3_eng101" | grep -qF 'controllers/' \
     && printf '%s\n' "$s3_eng101" | grep -qF 'internal/'; then
    ok "§3 ENG-101: carries boundary heuristic tokens 'controllers/' AND 'internal/'"
  else
    nope "§3 ENG-101: carries boundary heuristic tokens 'controllers/' AND 'internal/'" \
         "either 'controllers/' OR 'internal/' missing — boundary heuristic incomplete (ENG-101 D-3 #3)"
  fi
  unset s3_eng101

  s5_eng101="$(section_body "## 5. Review Agent")"
  if printf '%s\n' "$s5_eng101" | grep -qF '**Defensive-code restraint:**' \
     && printf '%s\n' "$s5_eng101" | grep -qF '[major]'; then
    ok "§5 ENG-101: carries '**Defensive-code restraint:**' AND '[major]' severity (Anti-bias check)"
  else
    nope "§5 ENG-101: carries '**Defensive-code restraint:**' AND '[major]' severity (Anti-bias check)" \
         "either header OR '[major]' severity token missing — review agent will not flag defensive code at the prescribed severity (ENG-101 D-2 / D-3 #4)"
  fi
  unset s5_eng101

  printf '\nRESULTS: %d passed, %d failed\n' "$PASS" "$FAIL"
  ```

  Notes:
  - Uses `grep -qF` (literal-substring, no regex) per the ENG-97 D-8
    convention. The four assertions mirror the ENG-82 §6 block at
    lines 1113–1138 (per A-016) for cross-test stylistic
    consistency.
  - Each assertion has its own `ok`/`nope` pair → per-token
    diagnostic on failure (per brainstorm §13 simpler-alternative
    rejection of single AND-gated grep).
  - The `[major]` literal in `grep -qF '[major]'` is treated as a
    fixed-string substring by `-F`, NOT as a regex character class.
    Safe.
  - Variable names `s3_eng101` and `s5_eng101` are scoped (not
    `s3`/`s5` to avoid colliding with existing globals used elsewhere
    in the file — the existing `s3=$(section_body …)` at line 68 is
    referenced by multiple subsequent ENG-43 / ENG-50 / ENG-54 /
    ENG-87 assertions; reusing it would shadow that scope). `unset`
    at the end of each block keeps variable hygiene consistent with
    ENG-82's `unset s6` at line 1138.

- [ ] **4.2** Verify by running `bash bin/agent-prompts-content-test.sh`.
  Expect: four new OK lines printed (`§3 ENG-101: carries ...`,
  `§3 ENG-101: carries 'try/except: pass' ...`, `§3 ENG-101: carries
  boundary heuristic ...`, `§5 ENG-101: carries '...' AND '[major]'
  ...`). The total `RESULTS: N passed, 0 failed` line ends with
  `0 failed`. If any of the four assertions FAILS, debug whether
  Task 2 or Task 3 introduced a typo in the expected token; do NOT
  weaken the test.

### Task 5: Run all gates listed in the Project profile's "Build & test gates" section

- `depends_on: [2, 3, 4]`
- `touches: <read-only — gate runs only>`

Steps:

- [ ] **5.1** Run the profile's full Build & test gates command
  (per `learned-rules/harness/project-profile.md::## Build & test gates`):

  ```
  bash bin/dispatch-test.sh && bash bin/run-stage-test.sh && bash bin/poll-slot-test.sh && bash bin/scope-check-test.sh && bash bin/verdict-handler-test.sh && bash bin/classify-failure-test.sh && bash bin/halt-sprawl-test.sh && bash bin/halt-sprawl-adversarial-test.sh && bash bin/linear-test.sh && bash bin/metrics-test.sh && bash bin/mutex-test.sh && bash bin/setup-helpers-test.sh && bash bin/render-prompt-test.sh && bash bin/phase-project-profile-test.sh && bash bin/common-test.sh
  ```

  Expect rc=0.

- [ ] **5.2** Run the content-pinning tests explicitly:

  ```
  bash bin/agent-prompts-content-test.sh && bash bin/render-prompt-rc0-test.sh
  ```

  Expect rc=0 from both. (The first verifies the four new ENG-101
  assertions pass; the second verifies §3 and §5 still render rc=0
  end-to-end for `implementing` and `reviewing` stages.)

- [ ] **5.3** Run the pre-commit hook (which runs the full
  `bin/*-test.sh` suite per CLAUDE.md):

  ```
  bash .githooks/pre-commit
  ```

  Expect rc=0. This is the load-bearing pre-commit gate the implement
  agent's exit-time commit invokes.

- [ ] **5.4** If any gate fails, debug the failure and re-run. Do
  NOT weaken any assertion. Common failure modes:
  - Fence count regression in §3 or §5 → introduced a stray
    column-0 ` ``` ` in Task 2 or Task 3; revert the offending Edit
    and re-apply with column-0 fences removed.
  - ENG-101 §3 / §5 assertion failure → Task 2 or Task 3 introduced
    a typo in the expected token; verify against this plan's
    `new_string` literal.
  - ENG-87 token-coverage failure → an inadvertent `{token}` was
    introduced in §3 or §5 body; replace with plain-prose `<>`
    placeholder per A-008.
  - ENG-97 forbidden-token failure → an inadvertent `Tauri` /
    `tauri::` / similar token was introduced in §3 or §5 body; the
    body should use only stack-agnostic prose.

## Frontend Tasks

N/A — the harness has no frontend. The harness profile's `## Stack`
declares "Bash 3.2+ orchestration scripts". This plan touches only
markdown prose (`AGENT_PROMPTS.md`) and a bash test file
(`bin/agent-prompts-content-test.sh`). The UI stage is a pass-through
for this issue (per §4's no-frontend pass-through clause).

## Failure Mode → Test Map

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
|---|---|---|---|---|
| §3 fence-count regression | A future Edit introduces a stray column-0 ` ``` ` inside §3 (e.g., copying a code-fenced example) | `bin/render-prompt.sh::extract_block` dies at dispatch time with the schema-error message; `bin/render-prompt-rc0-test.sh::implementing` fails with rc != 0; pre-commit hook blocks the offending commit | unit (render-prompt-rc0) | Case-87-R6: `bash bin/render-prompt.sh implementing ENG-X` exits 0 (in `bin/render-prompt-rc0-test.sh:113`) |
| §5 fence-count regression | A future Edit introduces a stray column-0 ` ``` ` inside §5 | `bin/render-prompt.sh::extract_block` dies; `bin/render-prompt-rc0-test.sh::reviewing` fails; pre-commit blocks | unit (render-prompt-rc0) | Case-87-R6: `bash bin/render-prompt.sh reviewing ENG-X` exits 0 (in `bin/render-prompt-rc0-test.sh:113`) |
| §3 Defensive-code restraint bullet silently removed | Future "cleanup" pass strips the bullet body but preserves surrounding bullets | New `bin/agent-prompts-content-test.sh` assertion (a) fails: "§3 ENG-101: carries '**Defensive-code restraint:**' Self-review bullet header"; pre-commit hook blocks the commit | unit (agent-prompts-content) | §3 ENG-101: carries '**Defensive-code restraint:**' Self-review bullet header (Task 4 #4.1 first assertion) |
| §3 bullet header preserved but body gutted (header-only stub) | Future edit keeps `**Defensive-code restraint:**` but replaces body with a one-line stub | Assertion (b) fails (`try/except: pass` token missing) OR assertion (c) fails (`controllers/`/`internal/` tokens missing); pre-commit blocks | unit (agent-prompts-content) | §3 ENG-101: carries 'try/except: pass' AVOID example token (Task 4 #4.1 second assertion); §3 ENG-101: carries boundary heuristic tokens 'controllers/' AND 'internal/' (Task 4 #4.1 third assertion) |
| §5 Defensive-code restraint paragraph silently removed | Future "cleanup" pass strips the §5 paragraph | New assertion (d) fails: "§5 ENG-101: carries '**Defensive-code restraint:**' AND '[major]' severity"; pre-commit blocks | unit (agent-prompts-content) | §5 ENG-101: carries '**Defensive-code restraint:**' AND '[major]' severity (Task 4 #4.1 fourth assertion) |
| §5 severity silently downgraded from `[major]` to `[minor]` or `[nit]` | Future edit keeps the paragraph header but rewrites the severity token | Assertion (d) fails (`[major]` substring missing); pre-commit blocks | unit (agent-prompts-content) | §5 ENG-101: carries '**Defensive-code restraint:**' AND '[major]' severity (Task 4 #4.1 fourth assertion) |
| New `{token}` substring accidentally introduced in §3 or §5 body | An author writes `{path}` instead of `<path>` for a placeholder | ENG-87 token-coverage assertion (`bin/agent-prompts-content-test.sh:1257-1260`) fails: "missing entry for: path"; `bin/render-prompt.sh::resolve_block_tokens` would die at dispatch time too | unit (agent-prompts-content) | ENG-87: every {token} in AGENT_PROMPTS.md is declared in PROMPT_RESOLVERS or AGENT_RUNTIME_TOKENS (existing assertion at line 1257) |
| Tauri-shaped token accidentally introduced | An author writes a Tauri-specific example | ENG-97 forbidden-token loop at `bin/agent-prompts-content-test.sh:148-154` flags the regression with per-token diagnostic | unit (agent-prompts-content) | AGENT_PROMPTS.md ENG-97: forbidden token '<token>' absent (existing assertion at lines 148-154) |
| End-to-end render regression for implementing or reviewing | Any change to §3 / §5 that breaks `bin/render-prompt.sh::main` (e.g. unresolved `{token}` or fence-count drift) | `bash bin/render-prompt.sh implementing ENG-X` and `… reviewing ENG-X` exit non-zero; `bin/render-prompt-rc0-test.sh` flags the offending stage | unit (render-prompt-rc0) | Case-87-R6: `bash bin/render-prompt.sh <stage> ENG-X` exits 0 (in `bin/render-prompt-rc0-test.sh:113` — once per stage) |
| Pre-commit hook bypasses regression | An author uses `git commit --no-verify` to skip the hook | The next normal commit re-runs the suite and catches it; CI (if/when added) would also catch | manual / process | n/a — operator hygiene per CLAUDE.md `## Pre-commit hook` |

## Test Strategy

**Unit coverage.** Four new positive-marker assertions in
`bin/agent-prompts-content-test.sh` (per Task 4) provide direct
content-presence checks for §3's defensive-code restraint bullet
(header + AVOID example token + boundary heuristic tokens) and §5's
paragraph (header + severity token). Each assertion uses `grep -qF`
(literal substring, no regex) for stability against cosmetic
rephrasing — the marker substrings (the bold header, the
`try/except: pass` literal, the `controllers/` / `internal/`
path-class tokens, the `[major]` severity token) are distinctive
enough that a future edit cannot cosmetically drift past them
without breaking the rule's load-bearing semantics.

**Integration coverage.** Two existing tests provide end-to-end
backstops:

- `bin/render-prompt-test.sh` exercises `bin/render-prompt.sh`'s
  resolver behavior (PROMPT_RESOLVERS + AGENT_RUNTIME_TOKENS) — no
  new content pins added per brainstorm §9 OQ-7; this plan's §3 / §5
  inserts do not introduce new `{token}` substrings (per A-008) so
  resolver behavior is unchanged.
- `bin/render-prompt-rc0-test.sh` exec()s the full `bash
  bin/render-prompt.sh <stage> ENG-X` for every dispatch-time stage
  including `implementing` and `reviewing`. Any §3 or §5 column-0
  fence regression (or any unresolved `{token}`) introduced by Task
  2 / Task 3 would die at `extract_block` / `resolve_block_tokens`
  and trip the corresponding `Case-87-R6: bash bin/render-prompt.sh
  <stage> ENG-X exits 0` assertion.

**Smoke / adversarial coverage.** No new smoke or adversarial tests
added. The existing pre-commit hook (`.githooks/pre-commit`) runs
the full `bin/*-test.sh` suite at commit time — every prompt-content
invariant in `bin/agent-prompts-content-test.sh` (ENG-46, ENG-50,
ENG-52, ENG-53, ENG-54, ENG-77, ENG-82, ENG-87, ENG-97 — and now
ENG-101) gets per-commit verification. The harness's adversarial
test files (`bin/halt-sprawl-adversarial-test.sh`,
`bin/run-local-content-adversarial-test.sh`,
`bin/verdict-adversarial-test.sh`) cover orthogonal failure modes
(slot accounting, runtime config drift, verdict-marker robustness)
and are not impacted by this plan's prompt-content edits.

**Behavioral verification (not testable in CI).** The §3 bullet's
effectiveness is a *behavioral* claim — that future implementing
dispatches will write less defensive code. This is not directly
testable via `bin/*-test.sh`; the brainstorm §11 A-28 verified the
underlying system prompt rule IS reachable to the dispatched agent,
so the §3 citation acts as reinforcement (not duplication). Post-ship
monitoring per brainstorm §10 and the Linear issue's "Escalation
path" — observed defensive-code-violation incidents that the §5
reviewer missed → file the Haiku LLM-judge detective ticket. The
prompt-only rule is the cheapest defensible shape; CI gates verify
that the prompt content STAYS in place, not that the agent's
behavior CHANGES (the latter is observed empirically over dispatches).

**Test-gate closure sweep result.** Zero tokens removed by this plan
(per A-017). No sibling test file needs editing. The two-file change
is closed end-to-end at the content-presence layer (Task 4
assertions) and the rendering-correctness layer
(`bin/render-prompt-rc0-test.sh`).
