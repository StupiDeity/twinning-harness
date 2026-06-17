---
linear: ENG-213
date: 2026-06-17
topic: Drop defensive *) arm from _merge_qa_payload_envelope's rc→defect case + ENG-213 OS-1 shape pin
---

# Plan — Drop the defensive `*)` arm from `_merge_qa_payload_envelope`

## Goal

Delete the single defensive `*)` arm at `bin/run-stage.sh:2105` (the rc→defect case inside `_merge_qa_payload_envelope`), and append one regression-pin test block (ENG-213 OS-1) to `bin/run-stage-test.sh` that asserts the resulting two-arm shape, so that every documented merge rc (0, 39, 41, 42, 50) routes unchanged AND a future re-introduction of the duplicate `*)` arm fails the pre-commit gate.

## Anti-anchoring check

* **Problem restatement (user view).** "The orchestrator's qa-payload envelope-merge helper contains a defensive `*)` arm that silently relabels any undocumented rc as `qa-payload-malformed` — a literal no-op for the closed rc set {0,39,41,42,50} the callee promises, and a contradiction of the ENG-101 defensive-code-restraint directive the implement agent is told to follow." The brainstorm's solution (drop the arm, add a shape pin) addresses this directly — no reframing.
* **Solution proportionality.** A one-line deletion plus a ~15-line grep-anchored sibling test is the right tier for a deferred maintainability finding marked `reversible_post_ship: yes, has_workaround: yes (arm is no-op), user_visible: no`. No new crate, no taxonomy edit, no docs change, no companion edits in `bin/common.sh` / `bin/qa-payload-schema.sh` / `AGENT_PROMPTS.md`. Proportional.
* **Escalation.** Not needed — both checks pass.

## Assumption Inventory

Every code-level claim below has been verified against the current worktree at `feat/eng-213-deferred-from-eng-203-defers-defensive-code-violation-reversible-drop-a` at plan-time `HEAD = c94bb70`.

**Branch-base freshness:** `HEAD..origin/main` empty at plan time (origin/main = ede2380). No Task 0 rebase needed; the brainstorm commit on this branch is one ahead of `origin/main` with no upstream drift to absorb.

### Files this plan modifies (verified `path:line`)

* `bin/run-stage.sh:2089-2112` — `_merge_qa_payload_envelope()` function definition. Header comment at L2080-2088 documents the closed rc set {0,39,41,42,50} from `merge_artifact_envelope`'s `failure_outcome_for_exit` qa-payload range.
* `bin/run-stage.sh:2100` — `if (( rc != 0 )); then` guard that ensures the case statement only sees non-zero rc.
* `bin/run-stage.sh:2102-2106` — the three-arm `case "$rc" in` block:
  ```bash
        case "$rc" in
          41) defect="qa-payload-missing" ;;
          39|42|50) defect="qa-payload-malformed" ;;
          *)  defect="qa-payload-malformed" ;;
        esac
  ```
  Confirmed L2105 is exactly `      *)  defect="qa-payload-malformed" ;;` (six leading spaces, then `*)` with two spaces between `)` and `defect=`).
* `bin/run-stage.sh:2107-2109` — the `_post_qa_payload_halt` call that consumes `$defect`. Unchanged by this plan; the empty-defect string ("") in a future hypothetical undocumented-rc path renders as `- Defect: ` (trailing space) per `_post_qa_payload_halt`'s printf format at L2147.
* `bin/run-stage-test.sh:9719-9997` — the ENG-203 OS-1..OS-8 block. Final OS-8 closes at L9997 (`unset _os8_hook _os8_fail`). L9999 prints the run-stage-test summary footer. **Content anchor for new ENG-213 OS-1 block's `AFTER` boundary is OS-8's closing `unset _os8_hook _os8_fail` line; `BEFORE` boundary is the blank line and `echo` at L9999.**
* `bin/run-stage-test.sh:9905-9913` — OS-6b's AST-style grep precedent on the same function body (`awk '/^_merge_qa_payload_envelope\(\) \{/,/^\}/' "$HARNESS_DIR/run-stage.sh"`). New ENG-213 OS-1 mirrors this `awk` extraction verbatim.

### Files this plan does NOT modify (verified)

* `bin/common.sh:699-744` — `merge_artifact_envelope` (the callee). Every `return` statement enumerated at L715-743 and they all return one of {0, 39, 41, 42, 50}. Unchanged by this plan.
* `bin/run-stage.sh:2118-2137` — `_validate_qa_payload`. Its `*)` arm at L2134-2136 emits a distinct defect token (`unexpected-rc`) and delegates to an *external* script (`bin/qa-payload-schema.sh`) at a real trust boundary. OQ-1 in the brainstorm defers any cleanup here; this plan does not touch it.
* `bin/run-stage.sh:2142-2150` — `_post_qa_payload_halt`. Consumer of `$defect`; printf format string is unchanged. The hypothetical empty-defect path renders as `- Defect: ` (trailing space) and the raw stderr text (containing `(rc=N)`) is carried through `$3`.
* `bin/qa-payload-schema.sh` — schema validator script. Unchanged.
* `bin/verify-qa.sh` — predicate validator. Unchanged (its body-merge call site is pinned by OS-7b, not affected by the case-statement edit).
* `AGENT_PROMPTS.md` — qa stage prompt body. The agent owns the body sidecar (`verdict-qa.body.json`); the orchestrator owns the envelope. The case statement is orchestrator-side; agent never sees it.
* `learned-rules/harness/project-profile.md` — no new test file is added (the new ENG-213 OS-1 pin lands inside the existing `bin/run-stage-test.sh`, which is already covered by `.githooks/pre-commit`'s `bin/*-test.sh` glob). The add-side test-gate closure sweep finds no `## Build & test gates` edit needed.
* `docs/runbooks/recovery.md` §15 — references the `qa-payload-invalid` halt class generically; no doc change needed (OQ-4 in brainstorm defers).
* `CLAUDE.md` — failure-mode quick reference row for rc=41 / rc=39/42/50 / rc=50 with halt-reason `qa-payload-invalid` describes the qa-payload halt class generically; no row references the `*)` arm specifically.

### Codebase precedent verified

* `bin/run-stage-test.sh:9905-9910` (OS-6b) — uses `awk '/^_merge_qa_payload_envelope\(\) \{/,/^\}/' "$HARNESS_DIR/run-stage.sh"` to extract the function body for greppable assertions. ENG-213 OS-1 reuses this exact `awk` shape.
* `bin/run-stage-test.sh:9719-9997` — ENG-203 OS-N block lives at the end of the test file, immediately before the final `echo` summary line. ENG-213 OS-1 will sit at the same level (one block, sibling of OS-1..OS-8), under its own `# ─── ENG-213: defensive-arm shape pin ───` separator header.
* Test-gate closure (remove-side sweep): the only occurrence of `*)  defect=` anywhere in `bin/` is `bin/run-stage.sh:2105` (verified via `Grep` for `\*\)\s*defect=`). No sibling test asserts the `*)` arm fires (verified — `_merge_qa_payload_envelope` is invoked by OS-1, OS-2, OS-3, OS-6 with rcs 0, 41, 39, and 0 respectively; none exercise an undocumented rc).
* Test-gate closure (add-side sweep): the new ENG-213 OS-1 pin sits inside `bin/run-stage-test.sh`, already in the `bin/*-test.sh` glob the pre-commit hook iterates (verified from project-profile's "Build & test gates" Test command). No new test file is created, so `learned-rules/harness/project-profile.md::"## Build & test gates"` does NOT need a companion edit.

### Closed-rc-set invariant pin (existing tests)

* `bin/common-test.sh:1341-1471` — `eng203_merge_envelope_tests()` (U-1..U-11) exercises `merge_artifact_envelope` across the full closed rc set: U-1 (rc=0), U-3 (rc=41), U-4/U-5/U-7 (rc=39), U-6/U-8 (rc=42), U-9 (rc=50). Together these pin the invariant that the callee returns ONLY values in {0, 39, 41, 42, 50}. The plan's safety story rests on this set staying closed; this plan does NOT add a new pin for the closed-rc-set invariant — the existing U-1..U-9 coverage is sufficient.

### Assumed (validated at implementation time, not pre-flight)

* The implementing-stage scope-allowlist permits writes to both `bin/run-stage.sh` and `bin/run-stage-test.sh`. From project-profile's `## File layout`: `bin/` is listed as the canonical script directory. Verify during implementation that `partition_dirty_paths` classifies the two-file diff as in-scope (not leaked-in-scope).
* `bash .githooks/pre-commit` runs cleanly on the post-edit branch — the new ENG-213 OS-1 block's `awk`-extracted body matches all three required substrings (`41) defect="qa-payload-missing"`, `39|42|50) defect="qa-payload-malformed"`, neither `*)  defect=` nor `*) defect=`).
* No KNOWN_BROKEN allowlist edit is needed in `.githooks/pre-commit` — `run-stage` is not in the current allowlist (verified from CLAUDE.md "Pre-commit hook" section + project-profile addendum listing the allowlist as `eng-81-reproducer, mutex, render-pr-body, render-prompt-slug`).

## System invariants

- After the edit, `_merge_qa_payload_envelope`'s case statement contains the literal arms `41) defect="qa-payload-missing"` and `39|42|50) defect="qa-payload-malformed"`, and contains NEITHER `*)  defect=` nor `*) defect=`. verified_by: task:T2
- `merge_artifact_envelope` (the callee at `bin/common.sh:699-744`) returns rc in the closed set {0, 39, 41, 42, 50} — every `return` statement in its body resolves to one of these five values. verified_by: bin/common-test.sh:eng203_merge_envelope_tests
- The rc=0 guard at `bin/run-stage.sh:2100` (`if (( rc != 0 )); then`) ensures the case statement is only entered when the merge failed; rc=0 never reaches the case. verified_by: bin/run-stage-test.sh:OS-1
- `_validate_qa_payload`'s `*)` arm at `bin/run-stage.sh:2134-2136` (which emits the distinct `unexpected-rc` token) is OUT OF SCOPE for this plan and remains unchanged — a different defect class at a different trust boundary (external script). verified_by: bin/run-stage-test.sh:117-H

## File Structure

Modified (existing files, no new files):

* `bin/run-stage.sh` — delete one line (`bin/run-stage.sh:2105`, the `*)  defect="qa-payload-malformed" ;;` arm) inside `_merge_qa_payload_envelope`'s rc→defect case.
* `bin/run-stage-test.sh` — append one new regression-pin block (`ENG-213 OS-1: _merge_qa_payload_envelope case has no defensive *) arm`) between OS-8's closing `unset _os8_hook _os8_fail` line and the final `echo` summary line.

No new files. No deletes. No path or filename collisions. No directory changes.

## API Contract

No new API surface. The harness has no FE↔BE wire format, no HTTP routes, no protobuf — this is an orchestrator-internal case-statement edit plus its sibling test pin. The agent-facing `verdict-qa.body.json` content schema and the orchestrator-facing `verdict-qa.json` envelope schema are both unchanged.

## Backend Tasks

### Task 1: Delete the defensive `*)` arm at `bin/run-stage.sh:2105`

- `depends_on: []`
- `touches: bin/run-stage.sh` (specifically `_merge_qa_payload_envelope()` at L2089-2112)

- [ ] In `bin/run-stage.sh`, locate the case statement inside `_merge_qa_payload_envelope()`. **Content anchor for the deletion: the line immediately AFTER `39|42|50) defect="qa-payload-malformed" ;;` AND immediately BEFORE the `esac` closer.** Approximate line number `~2105` (informational only; the content anchor is load-bearing).
- [ ] Delete the entire line `      *)  defect="qa-payload-malformed" ;;` (six leading spaces, `*)`, two spaces, then `defect="qa-payload-malformed" ;;`).
- [ ] Confirm the resulting case has exactly two arms:
  ```bash
        case "$rc" in
          41) defect="qa-payload-missing" ;;
          39|42|50) defect="qa-payload-malformed" ;;
        esac
  ```
- [ ] Run `bash -n bin/run-stage.sh` to confirm the file still parses.
- [ ] Do NOT edit `bin/run-stage.sh:2134-2136` (`_validate_qa_payload`'s `*)` arm — different function, different trust boundary, out of scope).
- [ ] Do NOT edit any other case statement in `bin/run-stage.sh` (`bin/run-stage.sh:1411, 1453, 2129` use different exit-code taxonomies; OQ-2 defers any work on them).

### Task 2: Append ENG-213 OS-1 regression-pin test to `bin/run-stage-test.sh`

- `depends_on: [1]`
- `touches: bin/run-stage-test.sh` (append ~15 lines after OS-8)

- [ ] Locate the end of the ENG-203 OS-N block in `bin/run-stage-test.sh`. **Content anchor for the insertion: AFTER the line `unset _os8_hook _os8_fail` (OS-8's cleanup) AND BEFORE the blank line and `echo` that opens the run-stage-test summary footer.** Approximate line number `~9998` (informational only).
- [ ] Append a new test block under a `# ─── ENG-213: drop defensive *) arm shape pin ───` separator header. Mirror the OS-6b `awk` extraction shape verbatim:

  ```bash
  # ─── ENG-213: drop defensive *) arm shape pin ───
  # Regression-pin against re-introduction of the defensive `*)` arm in
  # `_merge_qa_payload_envelope`'s rc→defect case. The arm assigned the
  # same value as the `39|42|50)` arm — a literal no-op for the closed
  # rc set {0, 39, 41, 42, 50} promised by `merge_artifact_envelope`
  # (pinned in bin/common-test.sh U-1..U-9). Removing it tightens the
  # diagnostic surface for any future contract drift: an undocumented
  # rc now lands an empty Defect: line + the raw stderr `(rc=N)`,
  # which is louder than a silent relabel. ENG-101's defensive-code
  # restraint directive forbids the implement agent from adding such
  # arms; ENG-213 removes a pre-existing instance and pins the
  # case-statement shape against re-introduction.
  _eng213_body="$(awk '/^_merge_qa_payload_envelope\(\) \{/,/^\}/' \
    "$HARNESS_DIR/run-stage.sh" 2>/dev/null || true)"
  if [[ "$_eng213_body" == *'41) defect="qa-payload-missing"'* ]] \
    && [[ "$_eng213_body" == *'39|42|50) defect="qa-payload-malformed"'* ]] \
    && [[ "$_eng213_body" != *'*)  defect='* ]] \
    && [[ "$_eng213_body" != *'*) defect='* ]]; then
    pass_at "ENG-213 OS-1: _merge_qa_payload_envelope case has no defensive *) arm"
  else
    fail_at "ENG-213 OS-1: case shape" \
      "expected 41)+39|42|50) only; got: ${_eng213_body}"
  fi
  unset _eng213_body
  ```

- [ ] Confirm the block uses `$HARNESS_DIR` (the test file's existing convention for the harness root, used by OS-6b at L9905) — NOT a hand-rolled path.
- [ ] Confirm the block's pass-name string starts with the literal prefix `ENG-213 OS-1:` so the operator's grep recipe (per CLAUDE.md operator-mental-model.md §3) distinguishes it from `ENG-203 OS-1:`.
- [ ] Confirm there is NO column-0 ` ``` ` fence inside the test block (the block is bash code under the existing test file's structure; no embedded fenced subblock).
- [ ] Run `bash -n bin/run-stage-test.sh` to confirm the file still parses.

### Task 3: Run the full test suite and confirm clean

- `depends_on: [1, 2]`
- `touches: (none — verification only)`

- [ ] Run `bash bin/run-stage-test.sh` standalone. Confirm:
  - All ENG-203 OS-1..OS-8 tests still pass (no behaviour change for any documented rc).
  - The new ENG-213 OS-1 test passes (case statement has no `*)` arm).
  - ENG-117 117-B (rc=41 → `Defect: qa-payload-missing`) and 117-C (rc=39 → `Defect: qa-payload-malformed`) still pass (these pin `_validate_qa_payload`, which is unchanged — they should remain green without touching them).
- [ ] Run `bash .githooks/pre-commit` from the worktree root. Confirm green gate (or the only failures are pre-existing KNOWN_BROKEN entries: `eng-81-reproducer, mutex, render-pr-body, render-prompt-slug`).
- [ ] Run `bash bin/secret-probe-lint.sh`. Confirm clean (no secret-handling concerns — the edit is a pure no-op deletion of a defect-string assignment).

## Frontend Tasks

No frontend exists for this project (harness is bash orchestration only — no UI). All work is in Backend Tasks above.

## Failure Mode → Test Map

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
|---|---|---|---|---|
| Defensive `*)` arm re-introduced post-fix | Future PR (human or agent) re-adds the `*)  defect=...` arm to `_merge_qa_payload_envelope`'s case | Pre-commit gate fails on the new ENG-213 OS-1 pin; diff cannot land | unit | `bin/run-stage-test.sh::ENG-213 OS-1: _merge_qa_payload_envelope case has no defensive *) arm` |
| rc=41 documented path regresses | `verdict-qa.body.json` missing → `merge_artifact_envelope` returns 41 | `_merge_qa_payload_envelope` returns 41; halt comment posts with `Defect: qa-payload-missing` | unit | `bin/run-stage-test.sh::ENG-203 OS-2: body absent → rc=41 + qa-payload-missing halt comment` |
| rc=39 documented path regresses | `verdict-qa.body.json` malformed JSON → `merge_artifact_envelope` returns 39 | `_merge_qa_payload_envelope` returns 39; halt comment posts with `Defect: qa-payload-malformed` | unit | `bin/run-stage-test.sh::ENG-203 OS-3: body parse error → rc=39 + qa-payload-malformed halt comment` |
| rc=0 success path regresses | Clean body + envelope → `merge_artifact_envelope` returns 0 | Canonical merged file has all five keys; `_validate_qa_payload` returns 0 | unit | `bin/run-stage-test.sh::ENG-203 OS-1: clean body → merged canonical has all five keys + _validate_qa_payload rc=0` |
| Closed-rc-set invariant breaks (callee starts emitting an undocumented rc) | Future edit to `merge_artifact_envelope` adds a new return statement (e.g. `return 43`) | Existing `bin/common-test.sh` U-1..U-9 still cover the documented set; a new rc would not be covered by U-N. The plan does NOT add a new pin for this — the closed-rc-set invariant rests on the existing common-test.sh suite. A hypothetical contract drift would manifest at runtime as empty `Defect: ` + raw stderr `rc=43` (louder forensic signal than today's silent relabel) | unit | `bin/common-test.sh::U-1..U-9 (existing — no new pin in this plan)` |
| `_validate_qa_payload`'s `*)` arm accidentally dropped (out-of-scope sibling edit) | Implement agent over-zealously edits `bin/run-stage.sh:2134-2136` too | OS-1 test passes on the in-scope edit; out-of-scope edit caught by ENG-117 117-H (existing) which pins the `unexpected-rc` defect on the `_validate_qa_payload` `*)` arm | unit | `bin/run-stage-test.sh::ENG-117 117-H: unexpected-rc arm of _validate_qa_payload (existing)` |
| Pre-commit gate fails because new test syntax-errors | Bash parser fails on the new test block | `bash -n bin/run-stage-test.sh` (Task 2's checklist) catches it before commit; if not, pre-commit gate (Task 3) catches at commit time | smoke | `bash -n bin/run-stage-test.sh` (manual; not a pinned test) |

## Test Strategy

* **Unit (new).** One regression-pin test (`ENG-213 OS-1`) in `bin/run-stage-test.sh`, asserting the post-fix case-statement shape via `awk` extraction + glob match. Catches re-introduction of the `*)` arm by any future writer (human or agent). Mirrors OS-6b's shape verbatim.
* **Unit (existing — confirmed unchanged).** OS-1, OS-2, OS-3 (documented-rc behaviour), OS-6, OS-6b (envelope-keyset discipline), OS-8 (qa-stage hook wire-up) in `bin/run-stage-test.sh` continue to pass without edits. ENG-117 117-A..117-H, ENG-117 117-B (rc=41 defect), 117-C (rc=39 defect), 117-H (unexpected-rc defect for the sibling `_validate_qa_payload` arm) all continue to pass. `bin/common-test.sh::eng203_merge_envelope_tests` (U-1..U-11) continues to pin the closed rc set.
* **Integration.** No integration test needed — the case statement is a function-internal control-flow primitive with no external surface. The end-to-end qa-stage flow is exercised by OS-1's merge → validator roundtrip on every test run.
* **Smoke.** `bash bin/run-stage-test.sh` standalone (Task 3) is the per-stage smoke. `bash .githooks/pre-commit` (Task 3) is the suite-wide smoke.
* **Adversarial coverage.** The shape-pin's adversarial intent is the regression class itself: a future defensive-coding re-introduction. The pin asserts on the absence of the `*)` arm in both whitespace forms (`*)  defect=` two-space and `*) defect=` one-space) so a cosmetic whitespace edit doesn't bypass the gate. A refactor to `if/elif` would require a benign test edit (acknowledged tradeoff — the case statement is the project-idiomatic shape, refactor is unlikely without a broader cross-cutting change that would update tests anyway).
* **No new test file.** The new pin sits inside `bin/run-stage-test.sh`, which is already covered by `.githooks/pre-commit`'s `bin/*-test.sh` glob. No edit to `learned-rules/harness/project-profile.md::"## Build & test gates"` is required (add-side test-gate closure sweep clear).
* **Test-gate closure (remove-side, completed).** Grep across `bin/` for `\*\)\s*defect=` returns exactly one hit (`bin/run-stage.sh:2105`, the line being deleted). No sibling test pins this token — the deletion does not require an inverting assertion in any other test file.

## Self-review

Per CLAUDE.md "Pipeline vocabulary" + plan-stage prompt §3, the self-review section is folded into the brainstorm's §10 persona review (already completed — 6/6 PASS, zero P0). This plan inherits that review: the persona-level findings on D-001/D-002/D-003 hold against this plan unchanged, because the plan implements exactly the three decisions without expansion.

The plan-stage self-review below covers plan-specific concerns NOT addressed by the brainstorm review:

* **Feasibility (codebase-fact verification).** Every `path:line` in Assumption Inventory was verified via `Read` against current code: `bin/run-stage.sh:2089-2112, 2102-2106, 2107-2109, 2118-2137, 2142-2150`; `bin/common.sh:699-744`; `bin/run-stage-test.sh:9719-9997, 9905-9913`; `bin/common-test.sh:1341-1471`. The closed-rc-set claim was verified by enumerating every `return` statement in `merge_artifact_envelope`. The test-gate closure remove-side sweep (`Grep \*\)\s*defect=`) confirmed exactly one hit at the soon-deleted line. The add-side sweep confirmed no new test file is created → no `project-profile.md` Build & test gates edit needed. PASS.
* **Scope.** Both tasks trace to a single brainstorm decision: D-001 (Task 1 implements the deletion) + D-003 (Task 2 implements the shape pin). D-002 (no companion edits, no taxonomy work) is honoured by the explicit "Files this plan does NOT modify" list. No task strays outside the declared File Structure. PASS.
* **Coherence.** Plan Goal matches brainstorm §2 Goal. Task 1 + Task 2 jointly realise the brainstorm's AC#1 (no `*)` arm) and AC#3 (pre-commit green). Task 3's full-suite run satisfies AC#2 (existing tests still pass). Failure Mode → Test Map binds every brainstorm Edge Cases / Error Handling row to a named test. PASS.
* **Design.** Plan respects module boundaries: orchestrator-side helper edited in `bin/run-stage.sh`; orchestrator-side test pinned in `bin/run-stage-test.sh`. No cross-module refactor; no layering violation; no circular dep introduced (the test reads the source via `awk` on a path string — no live import). PASS.
* **Product.** Plan delivers what the Linear issue asked for in the user's language: "drop the defensive `*)` arm (reversible)". The brainstorm rationale's user view (deferred-from-ENG-203 polish, no behaviour change for documented rcs, louder forensic signal for hypothetical undocumented rcs) maps cleanly onto the plan's two-task implementation. PASS.

Personas: 5/5 PASS · gate P0: 0 · proceeding to implementing.
