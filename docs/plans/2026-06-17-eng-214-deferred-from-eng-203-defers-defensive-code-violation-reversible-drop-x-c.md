---
linear: ENG-214
date: 2026-06-17
topic: Drop paranoid `[[ -x metrics.sh ]]` guard from `merge_artifact_envelope`'s forensic emission + ENG-214 OS-1 shape pin
---

# Plan — Drop the paranoid `[[ -x metrics.sh ]]` guard from `merge_artifact_envelope`

## Goal

Delete the `&& [[ -x "$(dirname "${BASH_SOURCE[0]}")/metrics.sh" ]]` clause at `bin/common.sh:736` (the third conjunct guarding the forensic `envelope-overwrite` metric emission inside `merge_artifact_envelope`), and append one regression-pin test block (ENG-214 OS-1) to `bin/common-test.sh` that asserts the post-fix guard shape, so that every documented call path is unchanged AND a future re-introduction of the executable-bit check fails the pre-commit gate.

## Anti-anchoring check

* **Problem restatement (user view).** "`merge_artifact_envelope`'s forensic-emission branch guards a `bash <path>` invocation with `[[ -x <path> ]]` — a check on a property that `bash <path>` does not consult (verified at `bin/render-prompt-test.sh:671`, the project's own comment documenting that `bash "$SCRIPT_DIR/metrics.sh"` ignores the exec bit). The check is defensive code for a scenario that can't happen (`metrics.sh` is co-located in `bin/`, ships executable, and the only thing the check protects against is a non-executable but readable metrics.sh, which `bash` would run anyway)."
* **Solution proportionality.** The Linear issue body explicitly bounds the change as `reversible_post_ship: yes, has_workaround: yes (guard is no-op), user_visible: no`. A one-clause deletion (preserving the `(( overlap_n > 0 )) && [[ -n "${PIPELINE_ISSUE_ID:-}" ]]` conjuncts that ARE load-bearing) plus a ~15-line grep-anchored sibling test mirrors the ENG-213 PR shape one ticket prior. No new crate, no taxonomy edit, no docs change, no companion edits in `bin/run-stage.sh` / `bin/verify-qa.sh` / `bin/metrics.sh` / `AGENT_PROMPTS.md`. Proportional.
* **Escalation.** Not needed — both checks pass.

## Assumption Inventory

Every code-level claim below has been verified against the current worktree at `feat/eng-214-deferred-from-eng-203-defers-defensive-code-violation-reversible-drop-x-c` at plan-time `HEAD = bf59b25`.

**Branch-base freshness:** `HEAD..origin/main` empty at plan time (origin/main = bf59b25). No Task 0 rebase needed; this branch was cut from `origin/main` post-ENG-213 merge with zero divergence to absorb.

### Files this plan modifies (verified `path:line`)

* `bin/common.sh:699-712` — header comment for `merge_artifact_envelope`. Documents the closed rc set {0, 39, 41, 42, 50} and explicitly states *"Forensic `envelope-overwrite` metric is best-effort; failure to emit is non-fatal."* The "best-effort" framing is the design intent the `-x` guard violates by gating-out a legitimate emission whenever the exec-bit is missing.
* `bin/common.sh:713-742` — `merge_artifact_envelope()` function body. Returns one of {0,39,41,42,50} per the enumerated return statements at L715, L716, L719, L722, L724, L727, L729, L735, L741.
* `bin/common.sh:736` — the three-conjunct `if` guarding the forensic metric emission:
  ```bash
    if (( overlap_n > 0 )) && [[ -n "${PIPELINE_ISSUE_ID:-}" ]] && [[ -x "$(dirname "${BASH_SOURCE[0]}")/metrics.sh" ]]; then
  ```
  Confirmed L736 is exactly this single-line `if` header (no continuation), and the third conjunct `&& [[ -x "$(dirname "${BASH_SOURCE[0]}")/metrics.sh" ]]` is the deletion target. The first two conjuncts (`(( overlap_n > 0 ))` for "is there actually an overlap to report" and `[[ -n "${PIPELINE_ISSUE_ID:-}" ]]` for "we have a valid issue identifier to label the metric with") are load-bearing and **MUST be preserved**.
* `bin/common.sh:737-740` — the four-argument `bash bin/metrics.sh "envelope-overwrite" …` call the `if` guards. Invocation form is `bash "$(dirname "${BASH_SOURCE[0]}")/metrics.sh"` — the script is read by `bash` as input; the executable bit on the script file is NOT consulted by this invocation form. Unchanged by this plan.
* `bin/common-test.sh:1341-1463` — `eng203_merge_envelope_tests()` block (U-1..U-7, U-9, U-10, U-11; U-8 retired by ENG-212 per commit `4edaeb2 test(ENG-212): retire U-8 pinning test for env_json object-type recheck`). Closing `}` at L1463, immediate invocation at L1464.
* `bin/common-test.sh:1466-1477` — `eng203_body_path_helpers()` block (path-helper shape pins added by ENG-203).
* `bin/common-test.sh:1484-1493` — `eng212_adversarial_no_env_type_recheck()` block (the **structural-guard precedent** for the new ENG-214 OS-1: same file, same shape — defined function + immediate top-level invocation, function-body slice via `awk '/^<name>\(\) \{/,/^\}/'` on `"$(dirname "${BASH_SOURCE[0]}")/common.sh"`, regression-fail-on-substring). **Content anchor for the new ENG-214 OS-1 block's `AFTER` boundary: the literal invocation line `eng212_adversarial_no_env_type_recheck` at L1493; `BEFORE` boundary: the `printf '\ncommon-test summary: %d passed, %d failed\n'` summary line at L1495.** Approximate insertion line `~1494` (informational only).

### Files this plan does NOT modify (verified)

* `bin/metrics.sh` — the script being invoked. Unchanged; it ships executable (verified `ls -la bin/metrics.sh` → `-rwxr-xr-x`) and the invocation form `bash bin/metrics.sh` never consults the exec bit anyway.
* `bin/render-prompt-test.sh:671` — comment explicitly documenting that `bash "$SCRIPT_DIR/metrics.sh"` does not consult the exec bit (the canonical project precedent the deletion is justified against). Unchanged.
* `bin/run-stage.sh` — the only caller-path that flows through `merge_artifact_envelope` for qa-stage is `_merge_qa_payload_envelope` at L2089-2112 (just edited in ENG-213). The forensic-emission branch is fully internal to `merge_artifact_envelope` — no caller observes it; no test asserts its emission. Unchanged.
* `bin/verify-qa.sh` — calls `merge_artifact_envelope` for the qa predicate via `--body` (ENG-203 brainstorm §3.1). Unchanged.
* `bin/run-local-helpers.sh:875` — separate `-x` check on `linear.sh`, NOT in scope for ENG-214 (the deferred finding's `finding_class_key` is `maintainability:common.sh:metrics-sh-x-guard-paranoid` — scoped to common.sh, scoped to metrics.sh). If that one is genuinely paranoid too, it ships as a sibling deferred-majors ticket; this plan does not preempt it.
* `bin/run-stage-test.sh:3606` — stub setup conditional (`if [[ ! -x "$STUB_DIR/metrics.sh" ]]; then chmod +x …`). This is test-stub fixture wiring (creates a stub metrics.sh in a tempdir), NOT a production-guard pin. Verified by reading the surrounding block: the `STUB_DIR` is a per-test fixture, not the real `bin/metrics.sh`. Unchanged.
* `AGENT_PROMPTS.md` — no agent ever sees `merge_artifact_envelope`'s implementation; the orchestrator owns the envelope-merge surface. The agent owns the `verdict-qa.body.json` body sidecar. Unchanged.
* `docs/runbooks/recovery.md` — references `envelope-overwrite` metric generically at L1237-1242. No documentation prose ties the metric's emission to an exec-bit check. Unchanged.
* `CLAUDE.md` — references the `envelope-overwrite` metric in the failure-mode quick reference for the qa-payload-invalid halt class (the "forensic signal" row). No row references the `-x` guard specifically. Unchanged.
* `learned-rules/harness/project-profile.md` — no new test file is created; the new ENG-214 OS-1 pin lands inside the existing `bin/common-test.sh`, which is already in `.githooks/pre-commit`'s `bin/*-test.sh` glob (per the project-profile addendum's "Build & test gates" Test command). Add-side test-gate closure sweep confirms no `## Build & test gates` edit needed.

### Codebase precedent verified

* `bin/render-prompt-test.sh:671` — *the canonical project precedent* for the deletion. Literal comment text: `# chmod +x omitted: resolver invokes via 'bash "$SCRIPT_DIR/metrics.sh"' so exec-bit is not consulted`. The project's own test code documents that the exec-bit check at `bin/common.sh:736` is testing a property the invocation form does not consult.
* `bin/run-stage-test.sh:9905-9913` — OS-6b's AST-style grep precedent on a function body using `awk '/^<name>\(\) \{/,/^\}/'`. ENG-213 OS-1 (just committed at `8c215fb test(ENG-213): pin _merge_qa_payload_envelope case shape (OS-1)`) reused this exact `awk` shape. ENG-214 OS-1 will mirror it once more, targeting `^merge_artifact_envelope\(\) \{` instead of `^_merge_qa_payload_envelope\(\) \{`.
* Test-gate closure (remove-side sweep): `Grep` for `-x.*metrics\.sh|metrics\.sh.*-x` across `bin/` returns:
  - `bin/common.sh:736` — the line whose third conjunct is being deleted (the only production occurrence; the surrounding `if` line stays).
  - `bin/run-stage-test.sh:3606` — stub-setup conditional (`if [[ ! -x "$STUB_DIR/metrics.sh" ]]`). NOT a production-guard pin; the conditional asks "is the fixture stub already executable" so the stub-setup doesn't redundantly `chmod`. Unchanged by this plan.
  - 11 `chmod +x "$STUB_DIR/metrics.sh"` test-stub setups across `bin/*-test.sh` files (also fixture wiring, not production-guard pins). Unchanged.
  No sibling test asserts that the `[[ -x … ]]` clause fires or gates emission. The deletion does not require an inverting assertion in any other test file.
* Test-gate closure (add-side sweep): the new ENG-214 OS-1 pin sits inside `bin/common-test.sh`, already in the `bin/*-test.sh` glob the pre-commit hook iterates (per project-profile addendum's "Build & test gates" Test command). No new test file is created, so `learned-rules/harness/project-profile.md::"## Build & test gates"` does NOT need a companion edit.
* Sibling-ticket precedent: ENG-213's plan (`docs/plans/2026-06-17-eng-213-…-drop-a.md`) and PR (`bf59b25 feat(eng-213): … drop *)`) shipped this same shape one ticket prior — one-line edit + ~15-line shape-pin test in the same suite. ENG-212 (`2725796 feat(eng-212): … drop check`) shipped a similar shape three days prior, retiring U-8 from the same `eng203_merge_envelope_tests` block this plan extends. ENG-214 OS-1 sits alongside U-N in the same function.

### Closed-call-set invariant (existing tests)

* `bin/common-test.sh:1341-1463` — `eng203_merge_envelope_tests()` (U-1..U-7, U-9, U-10, U-11) exercises `merge_artifact_envelope` across:
  - U-1 (clean body + envelope → rc=0, no overlap → forensic branch NOT entered),
  - U-2 (collision → envelope wins; `PIPELINE_ISSUE_ID` unset in the test → forensic branch short-circuited by the second conjunct),
  - U-3 (rc=41), U-4/U-5/U-7 (rc=39), U-6 (rc=42), U-9 (rc=50),
  - U-10 (collision content-key → envelope wins; same second-conjunct short-circuit),
  - U-11 (empty-string dispatch_id; same short-circuit).
  None of U-1..U-11 export `PIPELINE_ISSUE_ID`, so none of them exercise the third `[[ -x … ]]` conjunct — the deletion is **strictly additive to test coverage**: the existing tests stay green unchanged (no rc behaviour changes; the forensic branch's reachability under existing test fixtures is identical, gated by the second conjunct).

### Assumed (validated at implementation time, not pre-flight)

* The implementing-stage scope-allowlist permits writes to both `bin/common.sh` and `bin/common-test.sh`. From project-profile's `## File layout`: `bin/` is listed as the canonical script directory. Verify during implementation that `partition_dirty_paths` classifies the two-file diff as in-scope (not leaked-in-scope).
* `bash .githooks/pre-commit` runs cleanly on the post-edit branch — the new ENG-214 OS-1 block's `awk`-extracted body matches the expected substrings (first conjunct `(( overlap_n > 0 ))`, second conjunct `[[ -n "${PIPELINE_ISSUE_ID:-}" ]]`, the `bash "$(dirname "${BASH_SOURCE[0]}")/metrics.sh" "envelope-overwrite"` invocation), and does NOT match the deleted `[[ -x` substring inside the `merge_artifact_envelope` function body.
* No KNOWN_BROKEN allowlist edit is needed in `.githooks/pre-commit` — `common` is not in the current allowlist (verified from CLAUDE.md "Pre-commit hook" section + project-profile addendum listing the allowlist as `eng-81-reproducer, mutex, render-pr-body, render-prompt-slug`).
* The `_validate_qa_payload` halt-flow callsite for `_merge_qa_payload_envelope` is unchanged from ENG-213's post-merge state. (ENG-213 ran first in the deferred-majors sequence; its OS-1 pin in `bin/run-stage-test.sh` remains green throughout this plan.)

## System invariants

- After the edit, `merge_artifact_envelope`'s forensic-emit `if` line contains exactly two conjuncts — `(( overlap_n > 0 ))` and `[[ -n "${PIPELINE_ISSUE_ID:-}" ]]` — and contains NEITHER `[[ -x` NOR a reference to `metrics.sh` in the guard itself (the guarded body keeps its `bash …/metrics.sh "envelope-overwrite" …` invocation). verified_by: task:T2
- `merge_artifact_envelope` (`bin/common.sh:713-742`) continues to return rc in the closed set {0, 39, 41, 42, 50} — every `return` statement in its body resolves to one of these five values. The deletion is inside the rc=0 success path, AFTER the `mv "$tmp" "$canonical"` atomic write succeeded; it does not alter any return path. verified_by: bin/common-test.sh:eng203_merge_envelope_tests
- `bash "$(dirname "${BASH_SOURCE[0]}")/metrics.sh"` is the canonical invocation form across the project; `bash <script>` does not consult the script's exec bit — the deletion does not change the production-runtime behaviour of the forensic emission for the common case (`metrics.sh` ships executable) and unlocks emission in the pathological case (`metrics.sh` somehow becomes non-executable but stays readable). verified_by: bin/render-prompt-test.sh:671 (canonical project comment)
- The `|| true` at the end of the `bash …/metrics.sh …` invocation (`bin/common.sh:739` — the `>/dev/null 2>&1 || true` tail) preserves the "best-effort, non-fatal" contract documented in the function's header comment. The `-x` guard's deletion does NOT change this contract: a `bash` invocation against a missing or unreadable script returns non-zero, which the `|| true` already swallows. verified_by: bin/common.sh:699-712 (header comment) + bin/common.sh:739 (the `|| true` tail)

## File Structure

Modified (existing files, no new files):

* `bin/common.sh` — delete one expression (the third conjunct `&& [[ -x "$(dirname "${BASH_SOURCE[0]}")/metrics.sh" ]]` plus the leading ` && ` separator at the end of `bin/common.sh:736`) inside `merge_artifact_envelope`'s forensic-emission guard. The line goes from a three-conjunct `if` to a two-conjunct `if`.
* `bin/common-test.sh` — append one new regression-pin block (`ENG-214 OS-1: merge_artifact_envelope forensic-emit guard has no -x check`) between the closing `eng203_merge_envelope_tests` invocation (~L1472) and the next test function (or the test file's final summary line). Mirrors OS-6b's `awk` extraction shape.

No new files. No deletes. No path or filename collisions. No directory changes.

## API Contract

No new API surface. The harness has no FE↔BE wire format, no HTTP routes, no protobuf — this is an orchestrator-internal conditional-expression edit plus its sibling test pin. The agent-facing `verdict-qa.body.json` content schema and the orchestrator-facing `verdict-qa.json` envelope schema are both unchanged. The `envelope-overwrite` metric event schema (`bin/pipeline-events.json`) is unchanged.

## Backend Tasks

### Task 1: Delete the `[[ -x metrics.sh ]]` conjunct at `bin/common.sh:736`

- `depends_on: []`
- `touches: bin/common.sh` (specifically `merge_artifact_envelope()` at L713-742)

- [ ] In `bin/common.sh`, locate the forensic-emission `if` inside `merge_artifact_envelope()`. **Content anchor for the edit: the `if` line immediately AFTER the `mv "$tmp" "$canonical"` atomic-mv block (L734-735) AND immediately BEFORE the `bash "$(dirname "${BASH_SOURCE[0]}")/metrics.sh" "envelope-overwrite" \` invocation line.** Approximate line number `~736` (informational only; the content anchor is load-bearing).
- [ ] Replace the entire `if` line:
  ```bash
    if (( overlap_n > 0 )) && [[ -n "${PIPELINE_ISSUE_ID:-}" ]] && [[ -x "$(dirname "${BASH_SOURCE[0]}")/metrics.sh" ]]; then
  ```
  with the two-conjunct form:
  ```bash
    if (( overlap_n > 0 )) && [[ -n "${PIPELINE_ISSUE_ID:-}" ]]; then
  ```
  The change drops the trailing ` && [[ -x "$(dirname "${BASH_SOURCE[0]}")/metrics.sh" ]]` clause and its preceding ` && ` separator. Whitespace and the leading two-space indent before `if` are preserved.
- [ ] Do NOT alter the body of the guarded block (`bin/common.sh:737-740`). The `bash "$(dirname "${BASH_SOURCE[0]}")/metrics.sh" "envelope-overwrite" …` invocation, its arguments, the `>/dev/null 2>&1 || true` tail, and the closing `fi` are all unchanged.
- [ ] Do NOT alter the function's header comment (`bin/common.sh:699-712`). The "Forensic `envelope-overwrite` metric is best-effort; failure to emit is non-fatal." sentence already documents the post-fix contract correctly — the `|| true` tail in the invocation is the load-bearing best-effort mechanism, not the deleted `-x` guard.
- [ ] Run `bash -n bin/common.sh` to confirm the file still parses.
- [ ] Do NOT touch `bin/run-local-helpers.sh:875` (the separate `-x` check on `linear.sh` — out of scope; different finding class).
- [ ] Do NOT touch any test-stub `chmod +x` or `[[ ! -x "$STUB_DIR/metrics.sh" ]]` callsite — those are fixture wiring for stub directories, not production guards. Verified: only `bin/common.sh:736` is the production guard.

### Task 2: Append ENG-214 OS-1 regression-pin test to `bin/common-test.sh`

- `depends_on: [1]`
- `touches: bin/common-test.sh` (append ~25 lines after the `eng203_merge_envelope_tests` invocation)

- [ ] Locate the end of the ENG-212 adversarial block in `bin/common-test.sh`. **Content anchor for the insertion: AFTER the literal invocation line `eng212_adversarial_no_env_type_recheck` (immediately following its closing `}` ~L1493) AND BEFORE the `printf '\ncommon-test summary…'` summary line at L1495.** Approximate line number `~1494` (informational only). Sitting after ENG-212's adversarial block keeps the deferred-from-ENG-203 polish tests in source order alongside their sibling.
- [ ] Append a new function `eng214_adversarial_no_metrics_x_guard` plus its immediate invocation, mirroring the ENG-212 adversarial-block shape verbatim (function definition + immediate call at top-level, file path resolved via `"$(dirname "${BASH_SOURCE[0]}")/common.sh"` — the same idiom ENG-212 uses at `bin/common-test.sh:1485`). Use a Bash `=~` regex AND a substring check on the function-body slice; both must agree:

  ```bash
  # ─── ENG-214: drop paranoid -x metrics.sh guard shape pin ───
  # Regression-pin against re-introduction of the `[[ -x .../metrics.sh ]]`
  # conjunct in `merge_artifact_envelope`'s forensic-emission guard. The
  # invocation form `bash "$(dirname "${BASH_SOURCE[0]}")/metrics.sh"` does
  # not consult the script's exec bit (see bin/render-prompt-test.sh:671 —
  # the canonical project precedent: "chmod +x omitted: resolver invokes
  # via `bash \"\$SCRIPT_DIR/metrics.sh\"` so exec-bit is not consulted").
  # The `|| true` tail at bin/common.sh:739 already preserves the best-
  # effort contract documented in the function header. ENG-101's
  # defensive-code restraint directive forbids the implement agent from
  # adding such guards; ENG-214 removes a pre-existing instance and pins
  # the guard shape against re-introduction. Mirrors ENG-212's adversarial
  # structural-guard shape (bin/common-test.sh:1484-1492).
  eng214_adversarial_no_metrics_x_guard() {
    local src body
    src="$(dirname "${BASH_SOURCE[0]}")/common.sh"
    body="$(awk '/^merge_artifact_envelope\(\) \{/,/^\}/' "$src" 2>/dev/null || true)"
    if [[ "$body" == *'(( overlap_n > 0 ))'* ]] \
      && [[ "$body" == *'[[ -n "${PIPELINE_ISSUE_ID:-}" ]]'* ]] \
      && [[ "$body" == *'metrics.sh" "envelope-overwrite"'* ]] \
      && [[ "$body" != *'[[ -x'* ]]; then
      pass_at "ENG-214 OS-1: merge_artifact_envelope forensic-emit guard has no -x check"
    else
      fail_at "ENG-214 OS-1: guard shape" \
        "expected (( overlap_n > 0 )) && [[ -n PIPELINE_ISSUE_ID ]] only; got: ${body}"
    fi
  }
  eng214_adversarial_no_metrics_x_guard
  ```

- [ ] Confirm the path is resolved via `"$(dirname "${BASH_SOURCE[0]}")/common.sh"` — the exact idiom ENG-212's adversarial block uses at `bin/common-test.sh:1485`. Do NOT use `$SCRIPT_DIR` even though it is in scope; the local `src=` variable mirrors ENG-212's `local src` exactly and keeps the two adversarial blocks textually parallel for future readers.
- [ ] Confirm the block's pass-name string starts with the literal prefix `ENG-214 OS-1:` so the operator's grep recipe (per CLAUDE.md operator-mental-model.md §3) distinguishes it from ENG-213 OS-1 and ENG-203 OS-1 in the same suite.
- [ ] Confirm there is NO column-0 ` ``` ` fence inside the test block.
- [ ] Run `bash -n bin/common-test.sh` to confirm the file still parses.

### Task 3: Run the full test suite and confirm clean

- `depends_on: [1, 2]`
- `touches: (none — verification only)`

- [ ] Run `bash bin/common-test.sh` standalone. Confirm:
  - All U-1..U-7, U-9, U-10, U-11 in `eng203_merge_envelope_tests` still pass (no behaviour change for any documented rc; the forensic-emit branch is unreachable under those fixtures because none export `PIPELINE_ISSUE_ID`, identical pre- and post-fix).
  - The new ENG-214 OS-1 test passes (forensic-emit guard has no `-x` conjunct).
- [ ] Run `bash bin/run-stage-test.sh` to confirm ENG-213 OS-1 (sibling shape pin on `_merge_qa_payload_envelope`, just shipped one ticket prior) still passes — unchanged by this edit.
- [ ] Run `bash .githooks/pre-commit` from the worktree root. Confirm green gate (or the only failures are pre-existing KNOWN_BROKEN entries: `eng-81-reproducer, mutex, render-pr-body, render-prompt-slug`).
- [ ] Run `bash bin/secret-probe-lint.sh`. Confirm clean (no secret-handling concerns — the edit is a pure no-op deletion of an executable-bit test conjunct).

## Frontend Tasks

No frontend exists for this project (harness is bash orchestration only — no UI). All work is in Backend Tasks above.

## Failure Mode → Test Map

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
|---|---|---|---|---|
| Paranoid `[[ -x ]]` guard re-introduced post-fix | Future PR (human or agent) re-adds the `&& [[ -x "$(dirname "${BASH_SOURCE[0]}")/metrics.sh" ]]` conjunct to `merge_artifact_envelope`'s forensic-emit `if` | Pre-commit gate fails on the new ENG-214 OS-1 pin; diff cannot land | unit | `bin/common-test.sh::ENG-214 OS-1: merge_artifact_envelope forensic-emit guard has no -x check` |
| rc=0 success path regresses (clean body + envelope) | Clean body + envelope → `merge_artifact_envelope` returns 0; canonical merged file has all five keys | Pre- and post-fix identical: rc=0, all keys present | unit | `bin/common-test.sh::eng203_merge_envelope_tests::U-1` |
| rc=41 documented path regresses | `verdict-qa.body.json` missing → `merge_artifact_envelope` returns 41 (before reaching the forensic-emit branch) | Pre- and post-fix identical: rc=41 | unit | `bin/common-test.sh::eng203_merge_envelope_tests::U-3` |
| Right-bias on collision regresses (U-2/U-10/U-11) | Envelope key shadows body key | Envelope wins (jq `+` right-bias); rc=0; forensic-emit branch short-circuits via the second conjunct (`PIPELINE_ISSUE_ID` unset in these fixtures) | unit | `bin/common-test.sh::eng203_merge_envelope_tests::U-2, U-10, U-11` |
| `metrics.sh` non-executable but readable at runtime (the only behavioural change) | Operator chmod -x bin/metrics.sh (pathological — not a real production scenario) | Pre-fix: forensic emission silently skipped (loss of forensic surface). Post-fix: forensic emission still attempted via `bash metrics.sh`; succeeds (bash doesn't consult exec bit). Best-effort `|| true` tail keeps the call non-fatal regardless. | (not pinned — pathological case; behavioural change is purely additive in coverage) | N/A — change is justified by `bin/render-prompt-test.sh:671` precedent; no new test asserts this pathological case |
| `metrics.sh` missing at runtime (out-of-tree deployment) | metrics.sh deleted from `bin/` | Pre-fix: `[[ -x ]]` returns false → forensic emission silently skipped (loss of forensic surface; also no error visible). Post-fix: `bash metrics.sh` fails to find the script → exits non-zero → `\|\| true` swallows it; forensic emission silently skipped. Net behaviour: identical loss of forensic surface; identical lack of error. | (not pinned — pathological case; behavioural change is null in this case) | N/A |
| Pre-commit gate fails because new test syntax-errors | Bash parser fails on the new test block | `bash -n bin/common-test.sh` (Task 2's checklist) catches it before commit; if not, pre-commit gate (Task 3) catches at commit time | smoke | `bash -n bin/common-test.sh` (manual; not a pinned test) |

## Test Strategy

* **Unit (new).** One regression-pin test (`ENG-214 OS-1`) in `bin/common-test.sh`, asserting the post-fix guard-conjunct shape via `awk` extraction of `merge_artifact_envelope`'s function body + glob match on the three required substrings (`(( overlap_n > 0 ))`, `[[ -n "${PIPELINE_ISSUE_ID:-}" ]]`, `metrics.sh" "envelope-overwrite"`) AND a negative-match for `[[ -x`. Catches re-introduction of the `-x` conjunct by any future writer (human or agent). Mirrors OS-6b's / ENG-213 OS-1's `awk` extraction shape verbatim.
* **Unit (existing — confirmed unchanged).** `bin/common-test.sh::eng203_merge_envelope_tests::U-1..U-11` (minus U-8, retired by ENG-212) continue to pass without edits. None of them export `PIPELINE_ISSUE_ID`, so none of them exercise the third conjunct under either pre- or post-fix code. The deletion is strictly additive to coverage (no regression risk on the existing suite).
* **Sibling-ticket coverage (confirmed unchanged).** `bin/run-stage-test.sh::ENG-213 OS-1` (shape-pin on `_merge_qa_payload_envelope`, shipped one ticket prior at commit `bf59b25`) continues to pass — different function, different file, no overlap with this edit.
* **Integration.** No integration test needed — the conjunct is a function-internal control-flow primitive with no external surface. The end-to-end qa-stage envelope-merge flow is exercised by `bin/run-stage-test.sh::ENG-203 OS-1..OS-8` (rc=0 / rc=41 / rc=39 / hook wire-up) on every test run.
* **Smoke.** `bash bin/common-test.sh` standalone (Task 3) is the per-stage smoke. `bash .githooks/pre-commit` (Task 3) is the suite-wide smoke.
* **Adversarial coverage.** The shape-pin's adversarial intent is the regression class itself: a future defensive-coding re-introduction of the `[[ -x … ]]` conjunct. The pin asserts on the absence of any `[[ -x` substring inside the `merge_artifact_envelope` function body — both `[[ -x "$(dirname "${BASH_SOURCE[0]}")/metrics.sh" ]]` (the original) and any whitespace-edited variant (e.g. `[[ -x "${BASH_SOURCE[0]%/*}/metrics.sh" ]]`) trip it. A refactor to a positive-form check on a different property (e.g. `[[ -r `, `[[ -f `, or a `command -v`) would not trip the pin — acknowledged tradeoff. The pin's intent is regression-against-this-specific-pattern, not regression-against-all-defensive-checks; a generic detective is OQ-2 in ENG-213's brainstorm and remains deferred.
* **No new test file.** The new pin sits inside `bin/common-test.sh`, which is already covered by `.githooks/pre-commit`'s `bin/*-test.sh` glob. No edit to `learned-rules/harness/project-profile.md::"## Build & test gates"` is required (add-side test-gate closure sweep clear).
* **Test-gate closure (remove-side, completed).** `Grep` for `-x.*metrics\.sh|metrics\.sh.*-x` across `bin/` returns one production occurrence (`bin/common.sh:736`, the line being edited) and 13 test-stub fixture occurrences (`chmod +x "$STUB_DIR/metrics.sh"` and one `if [[ ! -x "$STUB_DIR/metrics.sh" ]]`). No test-stub occurrence pins the production guard's behaviour — they all wire up tempdir stubs unrelated to `bin/metrics.sh`. The deletion does not require an inverting assertion in any other test file.

## Self-review

The brainstorming stage was not run for ENG-214 (no `docs/brainstorms/2026-06-17-eng-214-*.md` exists; the dispatch_history.jsonl shows planning as the first stage). The operator transitioned the issue directly from Backlog → planning because the Linear issue body — emitted by ENG-203's deferred-majors auto-creation flow under sig `deferred-majors/ENG-203` — IS the brainstorm in miniature: it carries the `finding_class_key`, the originating PR, the decision factors (`reversible_post_ship: yes, has_workaround: yes, user_visible: no`), and the disposition rationale (the five-question deferred-majors rubric per ENG-191). The ENG-213 brainstorm (sibling ticket, shipped one ticket prior, same shape — drop one conjunct from a co-located helper) provided the structural template for this plan's persona reasoning. The persona-level review below is plan-stage-only:

* **Feasibility (codebase-fact verification + invariants resolution + test-gate closure).** PASS. Every `path:line` in Assumption Inventory was verified via `Read` against current code: `bin/common.sh:699-712, 713-742, 736, 737-740`; `bin/common-test.sh:1341-1463, 1466-1477, 1484-1493` (the three sibling blocks bracketing the insertion point); `bin/render-prompt-test.sh:671` (the canonical project precedent comment); `bin/run-local-helpers.sh:875` (the out-of-scope sibling `-x` on linear.sh, explicitly NOT touched). The closed-rc-set claim was verified by re-enumerating every `return` statement in `merge_artifact_envelope` and confirming each lands in {0, 39, 41, 42, 50}. The test-gate closure remove-side sweep (`Grep -x.*metrics\.sh|metrics\.sh.*-x`) confirmed one production hit (the line being edited) and zero sibling-test pins. The add-side sweep confirmed no new test file is created → no `project-profile.md` Build & test gates edit needed. **System invariants resolution sweep:** the plan's `## System invariants` section has four bullets; their `verified_by:` tokens resolve as follows — (1) `task:T2` resolves to the in-plan `### Task 2: Append ENG-214 OS-1 regression-pin test to bin/common-test.sh` whose `touches:` field names `bin/common-test.sh`, a file matching the gate-runnable glob `bin/*-test.sh`; (2) `bin/common-test.sh:eng203_merge_envelope_tests` resolves to the function defined at `bin/common-test.sh:1348` (literal `eng203_merge_envelope_tests() {` opener verified); (3) `bin/render-prompt-test.sh:671` resolves to the literal comment at that line (verified by Grep); (4) `bin/common.sh:699-712 + bin/common.sh:739` both verified by Read. All four bullets resolve cleanly. PASS.
* **Scope.** PASS. Both tasks trace to the Linear issue's bounded change: drop the `-x` conjunct (Task 1) + add a shape pin (Task 2). Task 3 is verification, not a new artifact. The "Files this plan does NOT modify" list explicitly enumerates every file the implement agent might be tempted to also touch (the sibling `-x` on `linear.sh` at `bin/run-local-helpers.sh:875`, the test-stub setups, the runbook, AGENT_PROMPTS.md, the project profile). No task strays outside the declared File Structure (2 modified files, 0 new files). The deletion's surface is one conjunct on one line.
* **Coherence.** PASS. Plan Goal matches the Linear issue's `Why this was deferred` rationale ("defensive-code violation — reversible (drop -x check), no regression, no user-visible surface, has workaround (guard is no-op)"). Task 1 + Task 2 jointly realise the bounded change. The Failure Mode → Test Map binds every realistic failure mode to a named existing or new test; the two pathological-case rows (non-executable / missing `metrics.sh`) are explicitly marked unpinned with rationale (additive coverage, not a regression). The plan's structure mirrors the just-shipped ENG-213 plan one-for-one (same sections, same density, same Failure Mode table layout).
* **Design.** PASS. Plan respects module boundaries: orchestrator-side helper edited in `bin/common.sh`; orchestrator-side test pinned in `bin/common-test.sh`. No cross-module refactor; no layering violation; no circular dep introduced. The test reads the source via `awk` on a path string — no live import, no runtime coupling. Path is resolved via `"$(dirname "${BASH_SOURCE[0]}")/common.sh"` — the exact idiom ENG-212's sibling adversarial block uses at `bin/common-test.sh:1485`, keeping the two adversarial structural-guards textually parallel for future readers. The deletion preserves the documented "best-effort, non-fatal" forensic-emit contract (header comment at L711-712) via the existing `|| true` tail at L739.
* **Product.** PASS. Plan delivers exactly what the Linear issue asked for in the issue's own language: "drop -x check". The issue's "How to triage" guidance ("Move to Todo to enter the harness queue. The finding text above is the canonical description") is honoured — the finding text drives the plan; no synthesised re-scoping. The plan matches the ENG-191/ENG-193 ship-with-known-debt loop: a small follow-up ticket that closes a deferred-majors bucket cleanly, validating the workflow as ENG-213 just did.

Personas: 5/5 PASS · gate P0: 0 · proceeding to implementing.
