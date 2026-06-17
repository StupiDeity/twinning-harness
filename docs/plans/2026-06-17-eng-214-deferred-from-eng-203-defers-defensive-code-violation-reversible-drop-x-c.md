---
linear: ENG-214
date: 2026-06-17
topic: Drop the paranoid `-x metrics.sh` guard from merge_artifact_envelope's emission predicate
---

# Plan — Drop the paranoid `-x metrics.sh` guard from `merge_artifact_envelope`

## Goal

Delete the trailing `&& [[ -x "$(dirname "${BASH_SOURCE[0]}")/metrics.sh" ]]` conjunct from the `envelope-overwrite` metric-emission predicate inside `merge_artifact_envelope` (`bin/common.sh`, currently the third conjunct on the `if` line), keeping the two load-bearing guards (`(( overlap_n > 0 ))` and `[[ -n "${PIPELINE_ISSUE_ID:-}" ]]`) and the trailing `|| true` on the `bash bin/metrics.sh …` invocation untouched, so that every documented merge contract (rc=0/39/41/42/50) and every existing test in `bin/common-test.sh::eng203_merge_envelope_tests` continues to pass unchanged.

## Anti-anchoring check

* **Problem restatement (user view).** "There's a paranoid `[[ -x "$(dirname "${BASH_SOURCE[0]}")/metrics.sh" ]]` check on a tracked, checked-in sibling file that's always present, gating the best-effort forensic `envelope-overwrite` metric. The check guards a state that can't occur in production and is belt-and-braces redundant with the trailing `|| true` on the same invocation — a textbook defensive-code-restraint violation the ENG-191 reviewer flagged and deferred." The brainstorm's solution (drop the conjunct) addresses this directly — no reframing.
* **Solution proportionality.** A one-line conjunct deletion is the smallest possible intervention for a deferred maintainability finding marked `reversible_post_ship: yes, user_visible: no, is_regression: no, has_workaround: yes (guard is a no-op), in_changed_code: yes`. No new file, no new test (D-002), no taxonomy edit, no companion edit, no rule update, no docs change. Proportional.
* **Escalation.** Not needed — both checks pass.

## Assumption Inventory

Every code-level claim below has been verified against the worktree at `feat/eng-214-…` at plan-time `HEAD = bcc6485`.

**Branch-base freshness:** `HEAD..origin/main` NON-EMPTY at plan time. Sibling tickets ENG-212 and ENG-213 landed on `origin/main` after this branch was cut. ENG-212 (commit `45e3eee`) modified the same function (`merge_artifact_envelope` in `bin/common.sh`), dropping two lines (the `env_json` object-type recheck at the pre-rebase L723-724) and shifting the target conjunct from pre-rebase `:738` to post-rebase `:736`. The change is **orthogonal** to ENG-214's drop — different conjunct, different predicate, no merge conflict on the literal text — but the line numbers shift, so the implement agent MUST rebase before editing. ENG-213 (commit `bf59b25`) touched `bin/run-stage.sh` and `bin/run-stage-test.sh`, not `bin/common.sh` — no interaction. Both changes share the same defensive-code-restraint family; cumulatively they shrink (not expand) the guard surface of `merge_artifact_envelope`. A `Task 0: Rebase onto origin/main` entry is added at the top of Backend Tasks; all subsequent task content anchors are designed to survive the rebase (see "Content anchors" below).

### Files this plan modifies (verified `path:line`)

Line numbers below are reported against the LOCAL worktree (`HEAD = bcc6485`, pre-rebase). The post-rebase shifts (after Task 0) are noted in parentheses where they differ.

* `bin/common.sh:713-744` (post-rebase `:713-742`) — `merge_artifact_envelope()` function definition. Header comment at L699-712 documents the helper's contract: closed rc set `{0, 39, 41, 42, 50}`, right-biased merge semantic, "Forensic `envelope-overwrite` metric is best-effort; failure to emit is non-fatal" (L711-712). Unchanged by this plan.
* `bin/common.sh:738` (post-rebase `:736`) — the predicate line being edited:
  ```bash
    if (( overlap_n > 0 )) && [[ -n "${PIPELINE_ISSUE_ID:-}" ]] && [[ -x "$(dirname "${BASH_SOURCE[0]}")/metrics.sh" ]]; then
  ```
  Confirmed verbatim via `Read bin/common.sh L738` and `git show origin/main:bin/common.sh | sed -n '736p'` (post-rebase form identical except for line number). **Content anchor for the edit: the `if` line that opens the `envelope-overwrite` metric emission block AFTER the `mv "$tmp" "$canonical"` atomic-rename block AND BEFORE the `bash "$(dirname …)/metrics.sh" "envelope-overwrite"` invocation.** The full content fragment to remove is the substring ` && [[ -x "$(dirname "${BASH_SOURCE[0]}")/metrics.sh" ]]` (leading space, ampersand-ampersand, space, opening `[[`, the `-x` test, closing `]]`).
* `bin/common.sh:739-741` (post-rebase `:737-739`) — the `bash "$(dirname "${BASH_SOURCE[0]}")/metrics.sh" "envelope-overwrite" …` invocation. The trailing ` >/dev/null 2>&1 || true` on L741 (post-rebase L739) is the load-bearing best-effort guarantee. Unchanged by this plan.

### Files this plan does NOT modify (verified)

* `bin/metrics.sh` — the sibling script being stat'd by the removed conjunct. Tracked, checked in, mode `0755` (verified `stat -f "%Sp"` → `-rwxr-xr-x`). The helper invocation already points at this file and is unchanged.
* `bin/common-test.sh:1341-1471` — `eng203_merge_envelope_tests()` (U-1, U-2, U-3, U-4, U-5, U-6, U-7, U-9, U-10, U-11; U-8 was retired by ENG-212). Verified via `Grep "U-[0-9]+"`: none of the tests export `PIPELINE_ISSUE_ID` (verified `Grep PIPELINE_ISSUE_ID bin/common-test.sh` → no matches), so the metric-emission predicate short-circuits on the second conjunct (`[[ -n "${PIPELINE_ISSUE_ID:-}" ]]`) before reaching the dropped `-x` clause. The dropped clause is unreachable from the existing test suite; the suite's pass/fail outcome is unchanged.
* `bin/run-stage-test.sh:3606` — the only other `-x .*metrics\.sh` occurrence in `bin/` is `if [[ ! -x "$STUB_DIR/metrics.sh" ]]; then` (and sibling `chmod +x "$STUB_DIR/metrics.sh"` calls at L428, L747, L822, L1075, L1906). All operate on a per-test stub at `$STUB_DIR/metrics.sh`, NOT on the real `bin/metrics.sh` path. Unrelated to this plan's edit; no test pins the dropped conjunct.
* `bin/poll-slot-test.sh:366`, `bin/poll-slot-test.sh:383`, `bin/stuck-tick-alarm-test.sh:76` — additional `chmod +x "$STUB_DIR/metrics.sh"` stub-creation lines. Same category as above — stub helpers, not the real bin/metrics.sh. Unrelated.
* `bin/run-stage.sh` — orchestrator-side caller of `merge_artifact_envelope` (via `_merge_qa_payload_envelope`). The helper's observable contract (rc set, atomic write, right-biased merge) is unchanged; caller stays the same.
* `bin/qa-payload-schema.sh`, `bin/verify-qa.sh` — qa-payload validator + predicate validator. Unrelated.
* `AGENT_PROMPTS.md` — no agent-facing surface changes.
* `learned-rules/harness/project-profile.md` — no new test file is added (D-002 in brainstorm), so the add-side test-gate closure sweep is moot. No `## Build & test gates` edit needed.
* `learned-rules/harness/plan.md`, `learned-rules/harness/build.md`, learned rules generally — retrospective-owned; not edited by one-shot tickets (see CLAUDE.md "AGENT_PROMPTS.md is load-bearing" §).
* `docs/runbooks/recovery.md`, `CLAUDE.md` — the helper's halt classes (`qa-payload-invalid`) and the rc taxonomy are unchanged, so no doc row needs updating.
* `bin/metrics.sh` — the script being invoked. Its argv interface is unchanged (`bash bin/metrics.sh envelope-overwrite … || true`).

### Codebase precedent verified

* **Defensive-code-restraint precedent.** ENG-212 (commit `45e3eee` on `origin/main`) dropped a sibling internal-invariant guard (`jq -e 'type == "object"' <<<"$env_json"` at the pre-rebase L723-724) from the same function. ENG-213 (commit `bf59b25`) dropped a sibling defensive `*)` arm from `_merge_qa_payload_envelope`'s rc→defect case. Both rest on the same five-factor rubric and the same engineering directive ("Don't add error handling, fallbacks, or validation for scenarios that can't happen"). ENG-214 is the third in this family and uses identical mechanics (one-line conjunct deletion, no test edit, no taxonomy change).
* **Test-gate closure (remove-side).** The dropped fragment is ` && [[ -x "$(dirname "${BASH_SOURCE[0]}")/metrics.sh" ]]`. Greppable tokens specific to the dropped clause: literal `-x.*metrics\.sh` matches `bin/common.sh:738` (the line being edited) and `bin/run-stage-test.sh:3606` (a `$STUB_DIR/metrics.sh` stub check — unrelated). NO sibling test file asserts the `-x metrics.sh` token on the real path. The deletion does not require an inverting assertion in any other test file. Verified via `grep -rn -E '\-x.*metrics\.sh' bin/`.
* **Test-gate closure (add-side).** This plan adds no new test file (D-002). No `learned-rules/harness/project-profile.md::"## Build & test gates"` edit is required. Verified by inspecting the plan's File Structure — no new files.
* **Closed-rc-set invariant.** `bin/common-test.sh::eng203_merge_envelope_tests` (U-1, U-2, U-3, U-4, U-5, U-6, U-7, U-9, U-10, U-11) exercises `merge_artifact_envelope` across the closed rc set `{0, 39, 41, 42, 50}`. The dropped conjunct does not change which rc the helper returns (it gates only the side-effect metric emission, and the helper returns 0 regardless of whether the emission fires). The U-N suite remains green without edits.

### Assumed (validated at implementation time, not pre-flight)

* The implementing-stage scope-allowlist permits writes to `bin/common.sh`. From `learned-rules/harness/project-profile.md::"## File layout"`: `bin/` is the canonical script directory. Verify during implementation that `partition_dirty_paths` classifies the single-file diff as in-scope.
* `bash .githooks/pre-commit` runs cleanly on the post-edit branch — the modified `bin/common.sh` parses (`bash -n`) and every `bin/*-test.sh` outside the KNOWN_BROKEN allowlist passes (no test pins the dropped conjunct).
* `bash bin/common-test.sh` passes standalone — `eng203_merge_envelope_tests` runs and all U-N assertions hold.
* No KNOWN_BROKEN allowlist edit is needed in `.githooks/pre-commit` — `common-test` is not in the current allowlist (verified from CLAUDE.md "Pre-commit hook" + project-profile addendum: current entries are `eng-81-reproducer, mutex, render-pr-body, render-prompt-slug`).

## System invariants

- After the edit, the predicate line in `merge_artifact_envelope` contains `(( overlap_n > 0 ))` AND `[[ -n "${PIPELINE_ISSUE_ID:-}" ]]`, and does NOT contain `[[ -x` anywhere in its body. verified_by: task:T2
- `merge_artifact_envelope` returns rc in the closed set `{0, 39, 41, 42, 50}` and `merge_artifact_envelope` ALWAYS returns 0 on the success path regardless of whether the `envelope-overwrite` metric emission fires (the emission is best-effort; the trailing `|| true` swallows non-zero exits). verified_by: bin/common-test.sh:eng203_merge_envelope_tests
- The `bash "$(dirname "${BASH_SOURCE[0]}")/metrics.sh" "envelope-overwrite" …` invocation is followed by ` >/dev/null 2>&1 || true` on the same logical line, providing the best-effort guarantee independently of any pre-call guard. verified_by: task:T2
- `bin/metrics.sh` is a tracked, checked-in sibling of `bin/common.sh` with mode `0755`. Its presence and executability are repo-level invariants enforced by git, not runtime invariants enforced by helper code. verified_by: task:T2

## File Structure

Modified (existing files, no new files):

* `bin/common.sh` — delete one fragment (` && [[ -x "$(dirname "${BASH_SOURCE[0]}")/metrics.sh" ]]`) from the predicate line that opens the `envelope-overwrite` metric emission block inside `merge_artifact_envelope` (currently L738 pre-rebase; L736 post-rebase). No other line in the file changes.

No new files. No deletes. No companion test edit. No path or filename collisions. No directory changes. No `learned-rules/harness/project-profile.md` edit (no new test file added).

## API Contract

No new API surface. The harness has no FE↔BE wire format, no HTTP routes, no protobuf — this is a single-conjunct deletion inside an orchestrator-internal helper's emission predicate. The helper's contract (rc taxonomy 0/39/41/42/50, right-biased merge, atomic write, best-effort emission) is unchanged. The agent-facing `verdict-qa.body.json` content schema and the orchestrator-facing `verdict-qa.json` envelope schema are both unchanged.

## Backend Tasks

### Task 0: Rebase onto `origin/main`

- `depends_on: []`
- `touches: (git operations only — no file edits)`

- [ ] From the worktree root, run `git fetch origin main` to refresh `origin/main`.
- [ ] Run `git log --oneline HEAD..origin/main` to confirm the drift (expected: ENG-212 and ENG-213 sibling commits, plus their planning/brainstorm chore commits — totalling 13 commits at plan time).
- [ ] Run `git rebase origin/main`. Expected: clean rebase. ENG-212's diff (`45e3eee`) modifies `bin/common.sh` lines pre-rebase L707, L723-724 (the env_json recheck deletion + docstring narrowing); ENG-214's local-branch change up to plan-time `HEAD` is only the brainstorm doc + this plan doc, neither of which touches `bin/common.sh`, so no textual conflict is possible.
- [ ] After rebase, re-verify the target conjunct is present and at its new line number by running `grep -n 'metrics.sh \]\]' bin/common.sh`. Expected: one hit at post-rebase ~L736 (down from pre-rebase L738), matching `if (( overlap_n > 0 )) && [[ -n "${PIPELINE_ISSUE_ID:-}" ]] && [[ -x "$(dirname "${BASH_SOURCE[0]}")/metrics.sh" ]]; then`.
- [ ] Re-verify the helper's contract docstring at L707 reads `#   42 body is symlink` (ENG-212's narrowed form) and NOT the pre-ENG-212 `#   42 body is symlink OR envelope arg is not a JSON object`. If the pre-ENG-212 form survives, the rebase silently failed — STOP and inspect.
- [ ] If `git log --oneline HEAD..origin/main` returns NON-EMPTY after rebase (or if the conjunct text is missing from `bin/common.sh`), halt with `bash bin/pipeline.sh event ENG-214 verdict halt --reason agent-blocked` and post a one-line description.
- [ ] Do NOT `git push --force` from the implement stage — the post-rebase branch is consumed in-place by the implement agent; the orchestrator owns the eventual push.

### Task 1: Delete the `-x metrics.sh` conjunct from `merge_artifact_envelope`

- `depends_on: [0]`
- `touches: bin/common.sh` (specifically `merge_artifact_envelope()`'s emission predicate inside the function body at L713-744 pre-edit / L713-742 post-edit)

- [ ] In `bin/common.sh`, locate the predicate line that opens the `envelope-overwrite` metric emission block. **Content anchor for the edit: the line begins `  if (( overlap_n > 0 )) && [[ -n "${PIPELINE_ISSUE_ID:-}" ]]` AND ends with the literal substring `[[ -x "$(dirname "${BASH_SOURCE[0]}")/metrics.sh" ]]; then`. It is the SOLE line in `bin/common.sh` containing the substring `[[ -x "$(dirname` (verified by Grep).** Approximate post-rebase line number `~736` (informational only; the content anchor is load-bearing).
- [ ] Delete exactly the substring ` && [[ -x "$(dirname "${BASH_SOURCE[0]}")/metrics.sh" ]]` (leading single space, ampersand-ampersand, space, the `[[ -x` test, closing `]]`). Leave the rest of the line — the leading whitespace, the `if`, the first two conjuncts, the trailing `; then` — untouched.
- [ ] Confirm the resulting line reads exactly:
  ```bash
    if (( overlap_n > 0 )) && [[ -n "${PIPELINE_ISSUE_ID:-}" ]]; then
  ```
  (Two leading spaces, `if`, the two surviving conjuncts joined by `&&`, semicolon, `then`.)
- [ ] Do NOT edit the helper's header comment (L699-712 in the post-rebase tree). The "Forensic `envelope-overwrite` metric is best-effort; failure to emit is non-fatal" line at L711-712 is the contract claim this edit is making good on; do not weaken or strengthen it.
- [ ] Do NOT edit the `bash "$(dirname "${BASH_SOURCE[0]}")/metrics.sh" "envelope-overwrite"` invocation on the next line (post-rebase L737-739) — the `bash …/metrics.sh` path stays as is; only the predicate guarding the invocation changes.
- [ ] Do NOT edit the trailing `>/dev/null 2>&1 || true` on the invocation's final line — that's the load-bearing best-effort mechanism and the entire safety story for this edit.
- [ ] Run `bash -n bin/common.sh` to confirm the file still parses.

### Task 2: Verify post-edit invariants via the existing test suite

- `depends_on: [1]`
- `touches: (none — verification only)`

- [ ] Run `bash bin/common-test.sh` standalone. Confirm:
  - `eng203_merge_envelope_tests` (U-1 through U-11 except U-8 which ENG-212 retired) all pass.
  - U-1 (rc=0 success path) still passes — the dropped clause was inside the rc=0 path, but the test does not export `PIPELINE_ISSUE_ID`, so the predicate short-circuits before reaching the dropped clause; outcome is unchanged.
  - U-3 (rc=41), U-4/U-5/U-7 (rc=39), U-6 (rc=42), U-9 (rc=50) all pass — these exercise paths that `return` before the metric-emission block; the dropped clause is unreachable from them.
- [ ] Run `bash -n bin/common.sh` again from the worktree root. Expected exit 0.
- [ ] Run `grep -c '\[\[ -x' bin/common.sh` from the worktree root. Expected: **zero** (the file should contain no `[[ -x` test anywhere — the dropped conjunct was the only one). If non-zero, the deletion targeted the wrong line; revert and re-do.
- [ ] Run `grep -n 'envelope-overwrite' bin/common.sh`. Expected: one hit on the `bash …/metrics.sh "envelope-overwrite"` invocation line (post-rebase L737). The invocation itself is unchanged.
- [ ] Run `bash .githooks/pre-commit` from the worktree root. Expected: green gate (or the only failures are pre-existing KNOWN_BROKEN entries: `eng-81-reproducer, mutex, render-pr-body, render-prompt-slug`).
- [ ] Run `bash bin/secret-probe-lint.sh`. Expected: clean. The edit removes a `-x` file-existence check; it does not introduce any env-var dereference, so secret-probe is structurally unaffected — confirm by inspection.

## Frontend Tasks

No frontend exists for this project (harness is bash orchestration only — no UI). All work is in Backend Tasks above.

## Failure Mode → Test Map

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
|---|---|---|---|---|
| `bin/metrics.sh` present + `PIPELINE_ISSUE_ID` set + overlap > 0 | qa-payload merge emits a collision-bearing envelope inside a real dispatch | `merge_artifact_envelope` returns 0; one `envelope-overwrite` row lands in `events.jsonl`. Pre- and post-fix identical. | unit | `bin/common-test.sh::eng203_merge_envelope_tests` (existing U-1 + U-10 cover the success path; U-10 specifically pins right-bias on a collision) |
| `bin/metrics.sh` present + `PIPELINE_ISSUE_ID` UNSET (e.g. unit test context) + overlap > 0 | U-N tests invoke the helper outside a dispatch envelope | Second conjunct `[[ -n "${PIPELINE_ISSUE_ID:-}" ]]` short-circuits the predicate; no emission. Pre- and post-fix identical. | unit | `bin/common-test.sh::eng203_merge_envelope_tests` (existing — every U-N runs in this state) |
| `bin/metrics.sh` present + `PIPELINE_ISSUE_ID` set + overlap == 0 | Clean disjoint-key merge inside a dispatch | First conjunct `(( overlap_n > 0 ))` short-circuits; no emission. Pre- and post-fix identical. | unit | `bin/common-test.sh::eng203_merge_envelope_tests::U-1` (clean body + envelope, no collision) |
| `bin/metrics.sh` mode bit stripped (hypothetical `chmod -x` by an operator) + overlap > 0 + `PIPELINE_ISSUE_ID` set | Operator hand-mutated checkout | **Pre-fix:** silent skip (the `-x` returned false). **Post-fix:** `bash …/metrics.sh` still runs (bash reads scripts regardless of the `x` bit); the metric lands. Net improvement (louder forensic signal in a manually-broken state). Same rc=0 from the helper. | unit | Not pinned by a new test (defensive testing of a hypothetical operator-manufactured state — D-002 in brainstorm). The behaviour is observable post-fix only if an operator manufactures the state; unreachable from the existing test suite. |
| `bin/metrics.sh` genuinely missing (partial checkout, hand `rm`) + overlap > 0 + `PIPELINE_ISSUE_ID` set | Filesystem-level corruption | **Pre-fix:** `-x` false, silent skip. **Post-fix:** `bash …/metrics.sh` exits non-zero on read failure; trailing `\|\| true` swallows. Helper still returns 0. Same observable outcome (no `events.jsonl` row, helper returns 0). | unit | Not pinned by a new test (defensive testing of an impossible-in-production state — D-002). The trailing `\|\| true` invariant is implicit in every U-N success-path assertion: if it weren't load-bearing, U-1 / U-10 would fail intermittently on a hypothetical broken sibling, which they don't. |
| Closed-rc-set invariant breaks (callee `merge_artifact_envelope` starts emitting an undocumented rc) | Future contract drift inside the helper | Existing U-N suite still covers the documented set; no new pin needed. The helper's `return` statements are enumerated in System invariants. | unit | `bin/common-test.sh::eng203_merge_envelope_tests` (existing — no new pin in this plan) |
| Future re-introduction of the `-x` conjunct (regression) | A future writer (human or agent) re-adds the dropped clause | **Not pinned by a new test.** Brainstorm D-002 explicitly rejected a regression pin (carrying cost outweighs the benefit for a no-op clause). Defence-in-depth: ENG-101's prompt-side defensive-code-restraint directive plus the next reviewer's adjudication catch the re-introduction. | (none — acknowledged tradeoff per brainstorm D-002) | (none) |

## Test Strategy

* **Unit (existing — confirmed unchanged).** `bin/common-test.sh::eng203_merge_envelope_tests` (U-1, U-2, U-3, U-4, U-5, U-6, U-7, U-9, U-10, U-11 — U-8 retired by ENG-212) continues to pin the closed rc set `{0, 39, 41, 42, 50}` and the right-bias merge semantic. None of the existing tests export `PIPELINE_ISSUE_ID`, so the metric-emission predicate short-circuits on the second conjunct in every test; the dropped third conjunct is unreachable from the suite. Outcome is unchanged.
* **Unit (new).** **None.** Per brainstorm D-002: adding a U-12 pinning "silent no-op when emission fails" would require either (a) mutating `bin/metrics.sh`'s mode bit (tracked-file side effect leaking across parallel `bin/*-test.sh` runs) or (b) `PATH`-stubbing `bin/metrics.sh` (the helper resolves via `$(dirname "${BASH_SOURCE[0]}")`, so `PATH` stubbing is structurally ineffective). The trailing `|| true` is the implicit invariant pinned by every U-N success-path assertion (if it weren't load-bearing, U-1 / U-10 would be flaky). Defensive testing of defensive code is the trap; declining is the right call.
* **Integration.** None needed — the helper is an orchestrator-internal control-flow primitive. The end-to-end qa-stage flow is exercised by `bin/run-stage-test.sh::ENG-203 OS-1 .. OS-8` on every run (these stub `metrics.sh` via `$STUB_DIR/metrics.sh` and never reach the real `bin/metrics.sh` path; unaffected by this edit).
* **Smoke.** `bash bin/common-test.sh` standalone (Task 2) is the per-file smoke. `bash .githooks/pre-commit` (Task 2) is the suite-wide smoke. `bash -n bin/common.sh` (Task 1 + Task 2) is the parse smoke.
* **Adversarial coverage.** The dropped conjunct's adversarial purpose was guarding a state that cannot occur (a sibling file present in the same tracked checkout going missing). The post-fix behaviour on every reachable adversarial input is **identical-or-better** than pre-fix (per §6 of the brainstorm: stripped mode bit, missing file, broken symlink, unset `BASH_SOURCE` all produce identical or louder forensic outcomes). No new adversarial pin is needed.
* **No new test file.** No edit to `learned-rules/harness/project-profile.md::"## Build & test gates"` is required (add-side test-gate closure sweep clear).
* **Test-gate closure (remove-side, completed).** `grep -rn -E '\-x.*metrics\.sh' bin/` returns two hits: `bin/common.sh:738` (the line being edited) and `bin/run-stage-test.sh:3606` (a `$STUB_DIR/metrics.sh` stub check, unrelated). No sibling test asserts the dropped conjunct token; the deletion does not require an inverting assertion.

## Self-review

Per the plan-stage prompt §3, the brainstorm's §12 six-persona review (6/6 PASS, zero P0) covers the substantive shape of the change. The plan-stage self-review below covers plan-specific concerns the brainstorm review did not address:

* **Feasibility (codebase-fact verification).** Every `path:line` in Assumption Inventory was verified via `Read` and `Grep` against current worktree code AND against `git show origin/main:bin/common.sh` (the post-rebase tree). The closed-rc-set claim was verified by enumerating every `return` statement in `merge_artifact_envelope` (L715, L716, L719, L722, L726, L729, L737, L743 in the pre-rebase tree; L715, L716, L719, L722, L724, L727, L735, L741 in the post-rebase tree — all yield values in `{0, 39, 41, 42, 50}`). The test-gate closure remove-side sweep (`grep -rn -E '\-x.*metrics\.sh' bin/`) confirmed two hits, one of them the soon-deleted line and the other a `$STUB_DIR` stub check unrelated to the real path. The add-side sweep confirmed no new test file is created → no `project-profile.md` Build & test gates edit needed. **System invariants resolution sweep:** the four `verified_by:` tokens — `task:T2` (×3) and `bin/common-test.sh:eng203_merge_envelope_tests` (×1) — all resolve: T2 is `### Task 2: Verify post-edit invariants via the existing test suite` in Backend Tasks above and its `touches` field is "verification only" but its checklist runs `bash bin/common-test.sh` and `bash .githooks/pre-commit` (both gate-runnable per the profile's "Build & test gates" line); `bin/common-test.sh:eng203_merge_envelope_tests` exists at L1348 in the local tree and L1348 in origin/main (verified by `Grep "eng203_merge_envelope_tests"`). PASS.
* **Scope.** Every Backend Task traces to a single brainstorm decision: Task 0 (rebase) is operational hygiene mandated by the branch-base freshness check (not a brainstorm decision but a plan-template MUST); Task 1 implements D-001 (drop the conjunct); Task 2 honours D-002 (no new test) by limiting verification to existing suites. No task strays outside the declared File Structure (`bin/common.sh` only). No gold-plating: no adjacent paranoid-guard cleanup in `merge_artifact_envelope` even though one could plausibly look for more (the function's other `[[ … ]]` guards are real adversarial-input checks at the caller→helper boundary, per brainstorm coherence persona). PASS.
* **Coherence.** Plan Goal matches brainstorm §1 Overview ("Drop the paranoid `-x` guard on `metrics.sh` …"). Task 1 + Task 2 jointly realise the brainstorm's §2 D-001 (the one-line deletion) and §2 D-002 (no new test). Failure Mode → Test Map binds every brainstorm §6 Edge Cases row to a named existing test OR an explicit "not pinned (acknowledged tradeoff)" entry; no row is left dangling. PASS.
* **Design.** Plan respects module boundaries: a single conjunct deletion inside a single function in a single file. No cross-module refactor; no layering violation; no new dependency. The helper's contract (rc taxonomy, atomic-write, right-bias) is unchanged — the edit is on a side-effect predicate, not a control-flow primitive. PASS.
* **Product.** Plan delivers what the Linear issue asked for in the user's language: "drop the `-x` check (reversible, no regression, no user-visible surface)". The brainstorm rationale's user view (deferred-from-ENG-203 polish, identical observable behaviour, louder forensic signal in hypothetical manually-broken states) maps cleanly onto Task 1's single-line deletion. No reframing. PASS.

Personas: 5/5 PASS · gate P0: 0 · proceeding to implementing.
