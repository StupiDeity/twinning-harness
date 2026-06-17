---
linear: ENG-216
date: 2026-06-17
topic: Add Case-P to bin/render-prompt-rc0-test.sh pinning {qa_payload_body_path} end-to-end resolution on qa-stage render
---

# Plan — Add Case-P pinning `{qa_payload_body_path}` end-to-end resolution

## Goal

Append a single `Case-P` block (~20 lines) to `bin/render-prompt-rc0-test.sh` immediately after Case-O and before the `━━━ Summary ━━━` printf, mirroring Case-O's `_timeout` + `grep -qF` shape verbatim with three string substitutions (`{qa_predicate_body_path}` → `{qa_payload_body_path}`, `qa-predicate-ENG-87R6X-O.body.json` → `verdict-qa.body.json`, `ENG-87R6X-O` → `ENG-87R6X-P`), so the full `main()` render-time resolver chain for the sibling Step-9 sidecar token is pinned against silent regression.

## Anti-anchoring check

- **Problem restatement (user view).** "ENG-203 added Case-O to pin the end-to-end render-time resolution of `{qa_predicate_body_path}` but never added the symmetric Case-P for `{qa_payload_body_path}` — a regression that drops the `_RENDER_QA_PAYLOAD_BODY_PATH` bind at `bin/render-prompt.sh:687` would resolve the token to an empty string at render time, AP-3 would still pass (greps `AGENT_PROMPTS.md` source, not rendered output), the qa-stage exit-0 sweep at L127 would still pass, and the qa agent would `Write` the dimensional payload to an empty path (cwd)." The brainstorm's solution (add Case-P mirroring Case-O) addresses this directly — no reframing.
- **Solution proportionality.** A ~20-line addition to one existing test file is the right tier for a deferred testing-coverage finding marked `reversible_post_ship: yes, has_workaround: yes (AP-3 grep-pin as backup), user_visible: no`. No new test file, no edits to production code, no docs change, no companion edits in `bin/render-prompt.sh` / `bin/common.sh` / `AGENT_PROMPTS.md`. Proportional.
- **Escalation.** Not needed — both checks pass.

## Assumption Inventory

Every code-level claim below has been verified against the current worktree at `feat/eng-216-deferred-from-eng-203-defers-fmtm-coverage-gap-reversible-add-20-line-case` at plan-time `HEAD = e2a602f`.

**Branch-base freshness:** `HEAD..origin/main` empty at plan time (origin/main = bf59b25). No Task 0 rebase needed; the brainstorm commit on this branch is one ahead of `origin/main` with no upstream drift to absorb.

### Files this plan modifies (verified `path:line`)

- `bin/render-prompt-rc0-test.sh:497-522` — the ENG-113/ENG-203 Case-O block. Header comment at L497-508 names the failure mode the pin is designed to detect; the literal block runs from `ISSUE_DIR_O="$sandbox/state/test-slug-rc0/ENG-87R6X-O"` (L509) through the `fi` closing the `if grep -qF "$EXPECTED_O" <<<"$out_o"; then` conditional at L522.
- `bin/render-prompt-rc0-test.sh:524` — the `printf '\n━━━ Summary ━━━\nPASS: %d / FAIL: %d\n' "$PASS" "$FAIL"` line. **Content anchor for the new Case-P insertion: AFTER Case-O's closing `fi` (L522) AND BEFORE the `printf '\n━━━ Summary ━━━...` line (L524).** Approximate line number `~523` (informational only; the content anchor is load-bearing).
- `bin/render-prompt-rc0-test.sh:27-28` — the `ok` and `fail` helper definitions (`ok() { printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); }` / `fail() { printf '  ❌ %s — %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }`). Case-P reuses both helpers verbatim.
- `bin/render-prompt-rc0-test.sh:37-42` — the `_timeout` helper wraps each render with `gtimeout $RENDER_TIMEOUT` (default 60s). Case-P reuses this helper verbatim, so a perf regression (e.g. the bash-3.2 multibyte `${//}` catastrophe documented at L29-36) fails Case-P within `RENDER_TIMEOUT` seconds rather than stalling the pre-commit suite.
- `bin/render-prompt-rc0-test.sh:49-103` — the per-test mktemp sandbox setup. The sandbox is created with `mktemp -d` at L49 and torn down by `trap cleanup EXIT` at L50-51. The sandbox layout (`$sandbox/bin/render-prompt.sh`, `$sandbox/bin/common.sh`, `$sandbox/AGENT_PROMPTS.md` symlink, `$sandbox/learned-rules/test-slug-rc0/project-profile.md`, `$sandbox/target/.pipeline-config/config.json`, `$sandbox/bin/linear.sh` + `$sandbox/bin/branch-name.sh` stubs) is constructed once and reused by every case A–O. Case-P inherits the sandbox unchanged.
- `bin/render-prompt-rc0-test.sh:525-526` — the gate footer (`[[ "$FAIL" == 0 ]] || exit 1` then `exit 0`). Case-P's `fail` call (on regression) increments `$FAIL` so the gate trips.

### Files this plan does NOT modify (verified)

- `bin/render-prompt.sh:61` — `PROMPT_RESOLVERS` registry entry `qa_payload_body_path=_resolve_qa_payload_body_path`. Verified by Read; sibling pattern with `qa_predicate_body_path` at L62.
- `bin/render-prompt.sh:289` — `_resolve_qa_payload_body_path() { printf '%s' "$_RENDER_QA_PAYLOAD_BODY_PATH"; }`. Verified by Read.
- `bin/render-prompt.sh:687` — `_RENDER_QA_PAYLOAD_BODY_PATH="$(qa_payload_body_path "$issue_id")"` inside `main()`. Verified by Read; binds alongside `_RENDER_QA_PREDICATE_BODY_PATH` at L688.
- `bin/render-prompt.sh:113` — `_write_rendered_paths_sidecar` participation (the closed-allowlist sidecar that ENG-156 D-004 covers); already includes the `qa_payload_body_path` line. Unchanged by this plan.
- `bin/render-prompt.sh:86` — `AGENT_RUNTIME_TOKENS=' file pr_number '`. `qa_payload_body_path` is NOT in the runtime-passthrough allowlist; the resolver IS called at render time. Verified by Read.
- `bin/common.sh:99-103` — `qa_payload_body_path()` helper. Returns `<issue-dir>/verdict-qa.body.json` — basename has NO ident embedded (asymmetric vs `qa_predicate_body_path` at L104-108, which returns `qa-predicate-<ident>.body.json`). Case-P's `EXPECTED_P` literal reflects this asymmetry. Verified by Read.
- `bin/common.sh:68-72` — `issue_dir()` returns `"$PROJECT_STATE_DIR/$issue"`. Verified by Read; composes with `qa_payload_body_path` to produce `$PROJECT_STATE_DIR/$ident/verdict-qa.body.json` when called from the sandboxed render.
- `bin/common.sh:961` — `export -f qa_payload_body_path qa_predicate_body_path` line. Verified the helper is exported so sandboxed renders see it.
- `AGENT_PROMPTS.md:2107` — the literal `{qa_payload_body_path}` token in §6 step 9 (`dimensional grading payload to \`{qa_payload_body_path}\``). Verified by grep.
- `bin/agent-prompts-content-test.sh:547-553` — AP-3 grep-pin asserting the literal `{qa_payload_body_path}` token is present in §6 source text. Orthogonal to Case-P (source-template vs rendered-output). Unchanged.
- `bin/agent-prompts-content-test.sh:571-579` — AP-5 sibling pin for `{qa_predicate_body_path}`. Unchanged.
- `bin/run-stage.sh` — qa-stage merge path consumes the body file at runtime independently of the render-time pin. Unchanged.
- `learned-rules/harness/project-profile.md` — no new test file is added (the new Case-P sits inside the existing `bin/render-prompt-rc0-test.sh`, which is already covered by `.githooks/pre-commit`'s `bin/*-test.sh` glob). The add-side test-gate closure sweep finds no `## Build & test gates` edit needed.
- `docs/runbooks/recovery.md` — §15 references the runtime `qa-payload-invalid` halt class generically; no doc change needed (OQ-6 in brainstorm defers).
- `CLAUDE.md` — failure-mode quick reference rows for `qa-payload-missing` / `qa-payload-malformed` describe the runtime halt class generically; no row references the render-time resolver chain that Case-P pins. No edit needed.

### Codebase precedent verified

- `bin/render-prompt-rc0-test.sh:497-522` (Case-O) — the literal precedent. Case-P mirrors the env-var setup (`PIPELINE_DRY_RUN=1`, `LINEAR_API_KEY=test-mock-key`, `TARGET_REPO`, `PROJECT_SLUG=test-slug-rc0`, `PROJECT_STATE_DIR`, `HARNESS_ROOT`, `HARNESS_STATE_DIR`), the `_timeout bash "$sandbox/bin/render-prompt.sh" qa <ident>` wrapper, the `rm -rf $ISSUE_DIR; mkdir -p $ISSUE_DIR` fixture pattern, and the `grep -qF "$EXPECTED" <<<"$out"` assertion shape verbatim.
- `bin/render-prompt-rc0-test.sh:144, 159, 192, 214, 249, 265, 315, 335, 358, 377, 400, 425, 456, 479, 509` — every Case-letter A–O uses the `ENG-87R6X-<letter>` fixture-ident convention. Case-P at the next slot uses `ENG-87R6X-P` per brainstorm D-003.
- Test-gate closure (remove-side sweep): this plan REMOVES no tokens from production code — Case-P is a pure additive pin on the unchanged resolver chain. `grep -nF '{qa_payload_body_path}'` in `bin/` returns hits at `bin/render-prompt.sh:61`, `bin/agent-prompts-content-test.sh:548, 551`, and `AGENT_PROMPTS.md:2107` — all of which Case-P pins or leaves unchanged. No sibling test contains a token that Case-P would break.
- Test-gate closure (add-side sweep): Case-P sits inside `bin/render-prompt-rc0-test.sh`, already in the `bin/*-test.sh` glob the pre-commit hook iterates (verified from project-profile addendum's "Build & test gates" Test command). No new test file is created, so `learned-rules/harness/project-profile.md::"## Build & test gates"` does NOT need a companion edit.
- `bin/agent-prompts-content-test.sh:547-553` (AP-3) — verified the assertion is `grep -qF '{qa_payload_body_path}' "$s6"` where `$s6` is the literal §6 source text from `AGENT_PROMPTS.md`. AP-3 catches "token deleted from prompt body"; Case-P catches "token present in prompt body but resolver chain broken at render time." Orthogonal contracts, both retained.

### Assumed (validated at implementation time, not pre-flight)

- The implementing-stage scope-allowlist permits writes to `bin/render-prompt-rc0-test.sh`. From project-profile's `## File layout`: `bin/` is listed as the canonical script directory. Verify during implementation that `partition_dirty_paths` classifies the one-file diff as in-scope (not leaked-in-scope). Brainstorm A-14 made the same assumption explicitly.
- `bash .githooks/pre-commit` runs cleanly on the post-edit branch — the new Case-P's `grep -qF "$EXPECTED_P" <<<"$out_p"` returns 0 against the current production tree (the resolver chain is intact at `bin/render-prompt.sh:61, 113, 289, 687` per A-1, A-2, A-3, A-4 in the brainstorm).
- No KNOWN_BROKEN allowlist edit is needed in `.githooks/pre-commit` — `render-prompt-rc0` is not in the current allowlist (verified from CLAUDE.md "Pre-commit hook" section + project-profile addendum listing the allowlist as `eng-81-reproducer, mutex, render-pr-body, render-prompt-slug`).

## System invariants

- After the edit, `bin/render-prompt-rc0-test.sh` contains the literal pass string `ENG-203/ENG-216 case P: {qa_payload_body_path} resolves to` and the assignment `ISSUE_DIR_P=` exactly once each; both sit between Case-O's closing `fi` and the `━━━ Summary ━━━` printf. verified_by: task:T1
- `qa_payload_body_path <ident>` (the helper at `bin/common.sh:99-103`) returns `<issue-dir>/verdict-qa.body.json` — basename has NO ident embedded — and `issue_dir <ident>` returns `"$PROJECT_STATE_DIR/$ident"`. Composition produces `$PROJECT_STATE_DIR/$ident/verdict-qa.body.json`, which Case-P's `EXPECTED_P` literal mirrors with `PROJECT_STATE_DIR=$sandbox/state/test-slug-rc0` and `$ident=ENG-87R6X-P`. verified_by: bin/common-test.sh:eng203_body_path_helpers
- The render-time resolver chain for `{qa_payload_body_path}` is intact end-to-end: `PROMPT_RESOLVERS` registers `qa_payload_body_path=_resolve_qa_payload_body_path` (`bin/render-prompt.sh:61`); `_resolve_qa_payload_body_path` prints `$_RENDER_QA_PAYLOAD_BODY_PATH` (`bin/render-prompt.sh:289`); `main()` binds `_RENDER_QA_PAYLOAD_BODY_PATH="$(qa_payload_body_path "$issue_id")"` (`bin/render-prompt.sh:687`). Case-P's `grep -qF` against the rendered stdout succeeds IFF all three links survive. verified_by: task:T1
- `qa_payload_body_path` is NOT in `AGENT_RUNTIME_TOKENS=' file pr_number '` at `bin/render-prompt.sh:86`. The resolver IS invoked at render time; if a future edit added the token to the runtime-allowlist, the rendered prompt would carry the literal `{qa_payload_body_path}` text (resolver pass skipped) and Case-P's `grep -qF` for the absolute-path string would fail. verified_by: task:T1

## File Structure

Modified (existing files, no new files):

- `bin/render-prompt-rc0-test.sh` — insert one new `Case-P` block (~20 lines) between Case-O's closing `fi` (L522) and the `printf '\n━━━ Summary ━━━...` line (L524). No edits to lines 1-522 or 524-527.

No new files. No deletes. No path or filename collisions. No directory changes.

## API Contract

No new API surface. The harness has no FE↔BE wire format, no HTTP routes, no protobuf — this is a test-fixture addition that pins an unchanged render-time resolver chain. The agent-facing `{qa_payload_body_path}` token and its resolved absolute-path shape are both unchanged.

## Backend Tasks

### Task 1: Append Case-P block to `bin/render-prompt-rc0-test.sh`

- `depends_on: []`
- `touches: bin/render-prompt-rc0-test.sh` (insert ~20 lines between L522 and L524)

- [ ] In `bin/render-prompt-rc0-test.sh`, locate the end of the ENG-113/ENG-203 Case-O block. **Content anchor for the insertion: AFTER the `fi` that closes the `if grep -qF "$EXPECTED_O" <<<"$out_o"; then` conditional AND BEFORE the `printf '\n━━━ Summary ━━━\nPASS: %d / FAIL: %d\n' "$PASS" "$FAIL"` line.** Approximate line numbers `~522` (Case-O `fi`) and `~524` (Summary printf) — informational only; the content anchors are load-bearing.

- [ ] Insert the following block (~20 lines) verbatim, with one blank line of separation BEFORE Case-P (mirroring the spacing between Case-N's closing `fi` at L495 and Case-O's leading comment at L497):

  ```bash
  # ─── ENG-216 case P: {qa_payload_body_path} resolves on qa-stage render
  # Mirror of case O above for the sibling Step-9 sidecar token. §6 step 9
  # instructs the agent to Write the dimensional grading payload to
  # {qa_payload_body_path}; render-prompt.sh::PROMPT_RESOLVERS registers
  # `qa_payload_body_path` → `_resolve_qa_payload_body_path`; main() binds
  # _RENDER_QA_PAYLOAD_BODY_PATH via common.sh::qa_payload_body_path(issue_id).
  # The rendered prompt MUST contain the full absolute-path shape
  # `<issue-dir>/verdict-qa.body.json` — basename-only would pass even if a
  # regression dropped the directory prefix and emitted just `verdict-qa.body.json`
  # (broken authority surface; agent would Write into cwd). Note the basename
  # has NO ident embedded (asymmetric vs qa-predicate-<ident>.body.json — see
  # common.sh:99-103 vs 104-108).
  ISSUE_DIR_P="$sandbox/state/test-slug-rc0/ENG-87R6X-P"
  rm -rf "$ISSUE_DIR_P"; mkdir -p "$ISSUE_DIR_P"
  out_p="$(PIPELINE_DRY_RUN=1 LINEAR_API_KEY=test-mock-key \
    TARGET_REPO="$sandbox/target" PROJECT_SLUG=test-slug-rc0 \
    PROJECT_STATE_DIR="$sandbox/state/test-slug-rc0" \
    HARNESS_ROOT="$sandbox" HARNESS_STATE_DIR="$sandbox/state" \
    _timeout bash "$sandbox/bin/render-prompt.sh" qa ENG-87R6X-P 2>/dev/null || true)"
  EXPECTED_P="$sandbox/state/test-slug-rc0/ENG-87R6X-P/verdict-qa.body.json"
  if grep -qF "$EXPECTED_P" <<<"$out_p"; then
    ok "ENG-203/ENG-216 case P: {qa_payload_body_path} resolves to $EXPECTED_P on qa-stage render"
  else
    fail "ENG-203/ENG-216 case P: {qa_payload_body_path} resolves on qa-stage render" \
         "expected absolute-path substring '$EXPECTED_P' missing from rendered prompt — out tail: $(tail -10 <<<"$out_p" | tr '\n' ' ')"
  fi
  ```

- [ ] Confirm the block uses the same env-var setup as Case-O (every variable name and value matches Case-O byte-for-byte except where the substitution requires a difference: `ISSUE_DIR_O` → `ISSUE_DIR_P`, `out_o` → `out_p`, `EXPECTED_O` → `EXPECTED_P`, `ENG-87R6X-O` → `ENG-87R6X-P`, the comment header naming, the `ok` / `fail` strings, and the expected basename `qa-predicate-ENG-87R6X-O.body.json` → `verdict-qa.body.json`).
- [ ] Confirm the basename in `EXPECTED_P` is `verdict-qa.body.json` with NO ident embedded (per A-3 in the brainstorm: `qa_payload_body_path` and `qa_predicate_body_path` differ on this axis intentionally; copy-paste from Case-O would put the wrong basename).
- [ ] Confirm there is NO column-0 ``` ``` ``` fence inside the inserted block (the block is bash code; no embedded fenced subblock). The surrounding test file has no ``` fences elsewhere — verified by Read at L1-103 and L497-526.
- [ ] Confirm the fixture-ident `ENG-87R6X-P` continues the case-letter series at L509 (Case-O uses `ENG-87R6X-O`). Do NOT use `ENG-216-A` or any other prefix — the file's internal convention is one Case-87-R6 corpus; a fresh prefix would fragment the operator-grep recipe (per brainstorm D-003).
- [ ] Run `bash -n bin/render-prompt-rc0-test.sh` to confirm the file still parses.

### Task 2: Run the full test suite and confirm clean

- `depends_on: [1]`
- `touches: (none — verification only)`

- [ ] Run `bash bin/render-prompt-rc0-test.sh` standalone. Confirm:
  - Every existing Case A–O still passes (no behaviour change for any other case).
  - The new Case-P passes (`ok "ENG-203/ENG-216 case P: ..."` line in stdout).
  - The `━━━ Summary ━━━` footer reports `PASS: N+1 / FAIL: 0` where `N` is the previous PASS count.
  - Exit code is 0.
- [ ] Run `bash .githooks/pre-commit` from the worktree root. Confirm green gate (or the only failures are pre-existing KNOWN_BROKEN entries: `eng-81-reproducer, mutex, render-pr-body, render-prompt-slug`).
- [ ] Run `bash bin/secret-probe-lint.sh`. Confirm clean (no secret-handling concerns — the addition is test-fixture code with no env-var fallback patterns).

## Frontend Tasks

No frontend exists for this project (harness is bash orchestration only — no UI). All work is in Backend Tasks above.

## Failure Mode → Test Map

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
|---|---|---|---|---|
| `_RENDER_QA_PAYLOAD_BODY_PATH` bind at `bin/render-prompt.sh:687` deleted (silent-resolution regression) | Future edit drops the `main()` bind line | `_resolve_qa_payload_body_path` returns empty; token substitutes to empty; rendered prompt does NOT contain the expected absolute-path substring | unit | `bin/render-prompt-rc0-test.sh::ENG-203/ENG-216 case P: {qa_payload_body_path} resolves on qa-stage render` |
| `PROMPT_RESOLVERS` registry entry `qa_payload_body_path=_resolve_qa_payload_body_path` at L61 deleted | Future edit drops the registry line | `render-prompt.sh` dies with "unresolved token after registry pass: {qa_payload_body_path}" on every qa render | unit | Existing for-loop qa render (the per-stage rc=0 sweep already in `bin/render-prompt-rc0-test.sh` upstream of Case-O); Case-P fails redundantly |
| `_resolve_qa_payload_body_path` function body at L289 deleted | Future edit drops the resolver fn | `render-prompt.sh` dies with "unknown resolver" | unit | Same as above — caught by existing for-loop |
| `qa_payload_body_path` helper at `bin/common.sh:99-103` deleted | Future edit drops the helper | `main()` bind at L687 dies with `qa_payload_body_path: command not found` → render exits non-zero | unit | Existing for-loop qa render |
| `{qa_payload_body_path}` literal token removed from `AGENT_PROMPTS.md` §6 step 9 | Future edit drops the token from the prompt body | `bin/agent-prompts-content-test.sh::AP-3` fails first; Case-P's grep also fails because the expected absolute-path string is no longer in the rendered prompt | unit | `bin/agent-prompts-content-test.sh::§6 ENG-203 AP-3: '{qa_payload_body_path}' token present` (primary); Case-P (secondary) |
| `verdict-qa.body.json` basename renamed in `bin/common.sh::qa_payload_body_path` | Future edit changes the helper's return path | Case-P fails with `EXPECTED_P` carrying the OLD basename; operator updates Case-P alongside the rename | unit | `bin/render-prompt-rc0-test.sh::ENG-203/ENG-216 case P` |
| Perf regression (bash-3.2 multibyte `${//}` catastrophe) in `render-prompt.sh` | Future edit re-introduces the locale-dependent substitution hang | `_timeout` wrapper fires `gtimeout $RENDER_TIMEOUT`; Case-P exits non-zero within ~60s | smoke | `bin/render-prompt-rc0-test.sh::ENG-203/ENG-216 case P` (via `_timeout` wrapper) |
| Sandbox state collision between Case-O and Case-P | Theoretical (the test runs serially) | Each case `rm -rf`'s its own `ISSUE_DIR_<letter>` before `mkdir -p`; no collision possible | unit | (implicit — no dedicated test; the `rm -rf; mkdir -p` lines are the safety mechanism) |

## Test Strategy

- **Unit (new).** One additive regression-pin (`Case-P`) in `bin/render-prompt-rc0-test.sh`. Sandboxed end-to-end render via `_timeout bash "$sandbox/bin/render-prompt.sh" qa ENG-87R6X-P`; assertion via `grep -qF "$EXPECTED_P"` on the rendered stdout. Catches silent-resolution regression in the `main()` bind site (the failure mode no other test covers).
- **Unit (existing — confirmed unchanged).** Cases A–O continue to pass without edits. `bin/agent-prompts-content-test.sh::AP-3` and `::AP-5` continue to pin the literal tokens in §6 source text. The render-prompt.sh per-stage exit-0 sweep at L127 (the upstream for-loop already in `bin/render-prompt-rc0-test.sh` that exercises every stage) continues to pass.
- **Integration.** No integration test needed — Case-P IS the end-to-end render-path integration pin for the `{qa_payload_body_path}` token. The runtime authority-surface contract (the orchestrator's qa-stage merge helper expecting the body at this exact path) is covered by `bin/run-stage-test.sh::ENG-203 OS-1..OS-8` and `bin/common-test.sh::eng203_merge_envelope_tests U-1..U-11`, both unchanged.
- **Smoke.** `bash bin/render-prompt-rc0-test.sh` standalone (Task 2) is the per-file smoke. `bash .githooks/pre-commit` (Task 2) is the suite-wide smoke.
- **Adversarial coverage.** The pin's adversarial intent is the silent-regression class: a future edit that drops the `main()` bind line at L687 leaves AP-3 passing (source-template intact), leaves the existing for-loop qa render passing (the per-stage rc=0 sweep dies only on "unresolved token after registry pass", not on "resolver returned empty"), leaves `bin/run-stage-test.sh::OS-1..OS-8` passing (those tests pin orchestrator-side merge behaviour, not render-side resolution), and ships a qa agent receiving a `Write` step pointing at an empty path. Case-P is the only test that detects this class — verified via Failure Mode → Test Map row 1.
- **No new test file.** The new Case-P sits inside `bin/render-prompt-rc0-test.sh`, which is already covered by `.githooks/pre-commit`'s `bin/*-test.sh` glob. No edit to `learned-rules/harness/project-profile.md::"## Build & test gates"` is required (add-side test-gate closure sweep clear).
- **Test-gate closure (remove-side, completed).** This plan REMOVES no tokens from production code; Case-P is a pure additive pin on the unchanged resolver chain. No sibling test contains a token that Case-P would break.
- **No regression risk to Case-O.** The brainstorm explicitly rejects DRY-ing Case-O + Case-P into a loop (§9 Rejected alternatives). Case-P is appended after Case-O with the same env-var setup, the same `_timeout` wrapper, the same `mktemp` sandbox (inherited), and a fresh `ISSUE_DIR_P` fixture. The two cases share no mutable state.

## Self-review

Per CLAUDE.md "Pipeline vocabulary" + plan-stage prompt §3, the self-review section is folded into the brainstorm's §10 persona review (already completed — 6/6 PASS, zero P0). This plan inherits that review: the persona-level findings on D-001/D-002/D-003 hold against this plan unchanged, because the plan implements exactly the three decisions without expansion.

The plan-stage self-review below covers plan-specific concerns NOT addressed by the brainstorm review:

- **Feasibility (codebase-fact verification).** Every `path:line` in Assumption Inventory was verified via `Read` against current code: `bin/render-prompt-rc0-test.sh:1-103, 480-526`; `bin/render-prompt.sh:55-66, 86, 97-132, 285-298, 680-700`; `bin/common.sh:66-108, 961`; `bin/agent-prompts-content-test.sh:540-588`; `AGENT_PROMPTS.md:2107`. The test-gate closure remove-side sweep returned empty (no tokens removed). The add-side sweep confirmed no new test file is created → no `project-profile.md` Build & test gates edit needed. PASS.
- **Scope.** Task 1 traces to brainstorm D-001 (mirror Case-O verbatim with three substitutions); Task 2 satisfies the brainstorm's AC#2 (full suite green) and AC#3 (pre-commit green). D-002 (no companion edits) is honoured by the explicit "Files this plan does NOT modify" list (11 entries). D-003 (fixture-ident convention) is honoured by Task 1's explicit `ENG-87R6X-P` constraint. No task strays outside the declared File Structure. PASS.
- **Coherence.** Plan Goal matches brainstorm §2 Goal. Tasks 1 + 2 jointly realise the brainstorm's AC#1 (Case-P block exists), AC#2 (suite green), AC#3 (pre-commit green), AC#4 (one-file, ~20-line). Failure Mode → Test Map binds every brainstorm Edge Cases row (§7) to a named test or marks it as covered by an existing test. PASS.
- **Design.** Plan respects module boundaries: render-time resolver chain edited (nothing) in `bin/render-prompt.sh`; render-time pin added in `bin/render-prompt-rc0-test.sh`. No cross-module refactor; no layering violation; no circular dep introduced. The orthogonality with AP-3 (source-template grep) is preserved — both pins stay, each owns a distinct surface. PASS.
- **Product.** Plan delivers what the Linear issue asked for in the user's language: "reversible (add 20-line case)". The brainstorm rationale's user view (deferred-from-ENG-203 testing polish, no production-code change, single-file addition mirroring Case-O) maps cleanly onto the plan's one-task implementation. PASS.

Personas: 5/5 PASS · gate P0: 0 · proceeding to implementing.
