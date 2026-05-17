---
linear: ENG-138
date: 2026-05-16
topic: Scope guards.sh review_rejection halt to the dispatched implementing stage (post-ENG-116 regression)
---

# Plan — guards: scope review_rejection halt to the implementing stage (ENG-138)

## Anti-anchoring check

- **Problem (operator-perspective):** "A clean reviewing PASS that ended a multi-cycle implement↔reviewing loop should advance the issue to QA, but the orchestrator halts the very next dispatch on the cumulative `review_rejection` counter — penalising convergence and stranding the loop's $25–30 of agent output behind an operator-resume." Brainstorm names this and chooses the surgical fix.
- **Brainstorm framing:** the brainstorm's D-1 implements the Linear issue's Option (a): scope the `review_rejection` halt check to `stage == implementing`. ENG-116's reset-side contract (only `operator-resume` waypoints clear the counter) is preserved verbatim; only the check-side firing edge narrows. The reframing matches the problem one-for-one.
- **Proportionality:** three small edits in `bin/guards.sh` (one signature widening, one wrapping conditional, one comment), two-line edit at the `run-stage.sh` call site, one new `bin/guards-test.sh` file (three cases mirroring AC#1–AC#3), and an optional one-row CLAUDE.md quick-reference addition. Total production-code diff is ~6 lines + a small new test file. No new state, no new marker, no schema change, no Linear contract change. Proportional. Proceed.

## Goal

`bin/guards.sh::check` accepts an optional second positional `stage` argument and trips the `review_rejection` threshold ONLY when `stage == implementing` (the `reviewing → implementing` loopback-continuation edge) or when no stage is passed (preserves the direct-CLI back-compat path used by `bin/run-stage-test.sh::case-15`). The `bin/run-stage.sh::main` guards call site at line 1177-1179 passes `"$stage"` to both invocations. Reset semantics from ENG-116 (`count_marker_since_last_operator_resume`, only `reason=operator-resume` waypoints clear the counter) are unchanged.

## Assumption Inventory

Format: `[verified|assumed]` ITEM — `path:line` reference.

**branch-base freshness:** `HEAD..origin/main` empty at plan time (`origin/main = 7f4ab77`). No Task 0 rebase needed; content anchors are still load-bearing per "Edit-boundary keys" below in case a sibling commit lands during implement.

### Verified — code paths quoted from current tree

- `[verified]` `bin/guards.sh:85-131` — `check()` function. Current signature:
  ```
  check() {
    local ident="$1"
    ...
  }
  ```
  The function reads five counters, sets `tripped=""`, and conditionally appends per-counter strings; the `review_rejection` trip is the unconditional block:
  ```
  if (( rev >= review_threshold )); then
    tripped+="review_rejection($rev>=$review_threshold) "
  fi
  ```
  (`bin/guards.sh:109-111`). Content anchor: the literal token `review_rejection($rev>=$review_threshold)` is unique in the file (Grep verified, 2026-05-16).

- `[verified]` `bin/guards.sh:31` — usage comment line: `#   guards.sh check <issue_id>`. Content anchor: literal `guards.sh check <issue_id>` is unique in the file.

- `[verified]` `bin/guards.sh:33` — usage comment line: `#   guards.sh bump <issue_id> <counter_name>`. Not changed by this plan; used as a positional landmark when editing the surrounding comment block.

- `[verified]` `bin/guards.sh:9-21` — header-comment block describing the ENG-116/ENG-123 contract: "The rejection counters … accumulate across loopback cycles and are cleared ONLY by an operator-resume waypoint". ENG-138 extends this block with one new sentence documenting the per-stage scoping. Content anchor: the literal closing line `# threshold` of the gotcha/rule paragraph at `bin/guards.sh:23` is the unique boundary token.

- `[verified]` `bin/guards.sh:64-83` — `count_marker_since_last_operator_resume()` body. Not modified by this plan; cited so the implementer knows the counter-accumulation semantic this fix builds on (post-ENG-116 lifetime counter, reset only by `reason=operator-resume`).

- `[verified]` `bin/guards.sh:133-140` — `bump()` function (the writer-side complement to `check`). Not modified by this plan.

- `[verified]` `bin/guards.sh:142-150` — `main()` dispatcher: `case "$cmd" in check) check "$@" ;; bump) bump "$@" ;; …`. The dispatcher forwards all positional args via `"$@"` so adding an optional `[stage]` to `check`'s signature requires no `main` change; the second arg already propagates if present.

- `[verified]` `bin/run-stage.sh:1176-1183` — guards.sh check call site:
  ```
  # Guards (threshold-based human gates).
  if ! bash "$SCRIPT_DIR/guards.sh" check "$ident" 2>/dev/null; then
    local tripped
    tripped="$(bash "$SCRIPT_DIR/guards.sh" check "$ident" 2>&1 || true)"
    classify_failure "$ident" "$stage" "skip-until-human-acts" \
      "guards tripped: $tripped" 10
    exit 10
  fi
  ```
  Both invocations need `"$stage"` as the second positional. `$stage` is set in `main` from the first CLI arg and normalized to long-form gerund earlier in the function (`bin/run-stage.sh:1748-1752`). Content anchor: the comment `# Guards (threshold-based human gates).` is unique in the file (Grep verified, 2026-05-16).

- `[verified]` `bin/run-stage.sh:1748-1752` — `stage_label_long` normalisation block that runs AFTER the dispatch but BEFORE the verdict_handler call. The `$stage` value passed into the line-1177 call site is the ORIGINAL first-arg `$stage` (in long-form already — `run-stage.sh ENG-N implementing` passes `implementing`, never `implement`). Confirms that `"$stage"` at line 1177 is the long-form gerund the guards check expects.

- `[verified]` `bin/run-stage-test.sh:1523-1635` — Case 15 regression. Three subcases:
  - Trip subcase (`bin/run-stage-test.sh:1565`): `bash "$FAKE_REPO/.pipeline/bin/guards.sh" check ENG-T15` (no stage arg) with two `implement_rejection` markers; expects rc=10, `implement_rejection(2>=2)` in output.
  - Clear subcase (`bin/run-stage-test.sh:1594`): same plus an `operator-resume` waypoint; expects rc=0.
  - Auto-trans subcase (`bin/run-stage-test.sh:1623`): same plus a non-resume auto-transition; expects rc=10.
  All three pass NO stage arg. The `[[ -z "$stage" || "$stage" == "implementing" ]]` guard in D-1 of the brainstorm is the empty-stage back-compat branch that keeps Case 15 green. Since Case 15's fixtures use `implement_rejection` (not `review_rejection`), the narrowing does not change its semantics regardless — the trip-as-today path runs.

- `[verified]` `bin/verdict-adversarial-test.sh:165-172` (A10) — sources `bin/guards.sh` directly to test `count_marker_since_last_operator_resume`. The new optional `stage` arg in `check()` does NOT affect the helper's signature, so this test is unaffected. `bin/verdict-adversarial-test.sh:177-194` (A10B / A11) likewise.

- `[verified]` `bin/run-stage-test.sh:1666-1699` (Case 17 QA) — asserts `impl=0` appears in the clear-log line at `bin/guards.sh:130`. The plan does NOT touch the clear-log line; assertion remains green.

- `[verified]` `bin/run-stage-test.sh:1637-1664` (Case 16 QA) — asserts `bump`'s marker text matches `count_marker`'s grep target. Not affected by this plan.

- `[verified]` `bin/dispatch.sh:399-400` — reviewing/qa allowlists already include `Bash(bash bin/guards.sh:*)` and `Bash(bash .pipeline/bin/guards.sh:*)`. The new second arg is just another positional; no allowlist change required.

- `[verified]` `bin/profile-allowlist-test.sh:324,335,338-347` — asserts `Bash(bash bin/guards.sh:*)` is present in reviewing/qa tools. The new arg passes those assertions unchanged.

- `[verified]` `bin/verdict-handler.sh:23-24` — forward transition `reviewing=qa`. `bin/verdict-handler.sh:35` — loopback `reviewing|implementing|`. Not modified; cited so the implementer can read why the dispatched stage is the right gate boundary.

- `[verified]` `bin/guards-test.sh` — does NOT exist on disk at HEAD. `Glob bin/guards*` returns only `bin/guards.sh` (verified 2026-05-16). New file per D-3 of the brainstorm. `.githooks/pre-commit` runs every `bin/*-test.sh` automatically (per `CLAUDE.md::"Pre-commit hook"`), so the new file is picked up by the hook without manual wiring.

- `[verified]` `bin/run-stage-test.sh:73-80` — stub `guards.sh` used by case-1–case-14 fixtures swallows ALL args (`for arg in "$@" …`) and records them. Adding a second arg to `check` does NOT break the stub or those cases.

- `[verified]` `AGENT_PROMPTS.md:1168` — reviewer-agent B-path bump: `bash .pipeline/bin/guards.sh bump {issue_id} review_rejection`. Not modified by this plan; cited so the implementer knows where the counter source lives.

- `[verified]` `CLAUDE.md::"Failure-mode quick reference"` — does NOT currently contain a `review_rejection`-keyed row (Grep `review_rejection CLAUDE.md` returns zero matches, 2026-05-16). The D-4 optional one-row addition is genuinely new.

### Verified — file/dir existence and absence

- `[verified]` `bin/guards.sh` — exists at HEAD; modified by Tasks 1, 2, 3.
- `[verified]` `bin/run-stage.sh` — exists at HEAD; modified by Task 4.
- `[verified]` `bin/guards-test.sh` — does NOT exist at HEAD; created by Task 5.
- `[verified]` `CLAUDE.md` — exists at HEAD; Task 6 is an optional one-row addition gated on "row does not already exist" (it doesn't, per the grep above).

### Verified — runtime / dependency

- `[verified]` `jq` is a required runtime tool per the project profile Stack section; already used by `bin/guards.sh::check`. No new tooling.
- `[verified]` `.githooks/pre-commit` ships in repo and runs every `bin/*-test.sh` (per `CLAUDE.md::"Pre-commit hook"`). New `bin/guards-test.sh` is auto-picked up; no KNOWN_BROKEN allowlist edit needed.

### Assumed — to be verified during implement

- `[assumed]` Direct CLI invocation `bash bin/guards.sh check ENG-N` (no stage) is a flow used by operators during manual triage (called out in §7 of the brainstorm). The empty-stage trip-as-today branch defends this; the implementer should manually re-confirm by running `bash bin/run-stage-test.sh` post-change.

- `[assumed]` `bin/pipeline.sh decide --action continue` posts the `<!-- pipeline: transition ... reason=operator-resume -->` waypoint that resets the counter (cited indirectly via `CLAUDE.md::"What --action continue clears (atomic)"` step 7 and `bin/guards.sh:11-13`). Counter-reset is unchanged by this ticket; not re-verified.

## File Structure

### Modified

- `bin/guards.sh` — extend `check()`'s signature with optional `${2:-}` as `stage`; wrap the `review_rejection` trip in `[[ -z "$stage" || "$stage" == "implementing" ]]`; update usage comment (line 31) to show the optional `[stage]` arg; extend the header-comment block (lines 9-21) with one sentence documenting the per-stage scoping.
- `bin/run-stage.sh` — pass `"$stage"` as second positional to both `guards.sh check` invocations in the line 1177-1179 block.
- `CLAUDE.md` — *(optional, gated on row-absence; verified absent in Assumption Inventory)* — append a one-row entry under "Failure-mode quick reference" mapping the symptom `reviewing → qa transition halts on review_rejection(N>=2)` to "fixed in ENG-138; before that fix, recover via `bash bin/pipeline.sh decide --action continue`."

### New

- `bin/guards-test.sh` — new test file. Source-and-stub pattern per `CLAUDE.md::"How tests work"`. Three cases covering AC#1, AC#2, AC#3 from the brainstorm §2 (preserves ENG-116 intent at `stage=implementing`; fixes the regression at `stage=qa`; operator-resume still resets). Plus a fourth case asserting the empty-stage back-compat branch trips as today on `review_rejection`. Ends with the source-and-test sentinel.

No other files are modified. No new schema, no new marker, no new Linear contract, no new prompt-template token.

## API Contract

No new FE↔BE API surface. The harness has no FE/BE split (Bash-only orchestration per the project profile's Stack section). The only CLI surface this plan touches is:

- `bash bin/guards.sh check <issue_id> [stage]` — exit 0 (clear) / exit 10 (a threshold tripped). Adding `[stage]` as an optional second positional preserves the existing one-arg invocation shape (back-compat).

No other CLI shapes change.

## Backend Tasks

### Task 1: Extend `bin/guards.sh::check()` signature with optional `stage` arg

- `depends_on: []`
- `touches: bin/guards.sh::check`
- [ ] In `bin/guards.sh`, locate the `check()` function (anchor: `check() {` on the line preceded by the blank line that closes `count_marker_since_last_operator_resume`'s body, ~line 85).
- [ ] AFTER the line `local ident="$1"` and BEFORE the line `local review_threshold gotcha_threshold rule_threshold qa_threshold impl_threshold`, insert:

  ```bash
  local stage="${2:-}"
  ```
- [ ] Locate the unconditional `review_rejection` trip block (content anchor: the literal `review_rejection($rev>=$review_threshold)` token is unique in the file, ~line 110). Wrap the existing two-line `if (( rev >= review_threshold )); then … fi` block with an outer `[[ -z "$stage" || "$stage" == "implementing" ]]` guard. Resulting shape:

  ```bash
  # ENG-138: trip review_rejection only when the next dispatched stage is
  # 'implementing' (the loopback-continuation edge). Empty-stage CLI
  # invocations preserve the trip-as-today path used by bin/run-stage-
  # test.sh::case-15 and operator triage flows. The counter still
  # accumulates across loopback cycles; reset semantics from ENG-116
  # (operator-resume only) are unchanged.
  if (( rev >= review_threshold )) && [[ -z "$stage" || "$stage" == "implementing" ]]; then
    tripped+="review_rejection($rev>=$review_threshold) "
  fi
  ```
- [ ] DO NOT change the `gotcha_triggered`, `learned_rule_renewal`, `qa_rejection`, or `implement_rejection` trip blocks (out of scope per Linear issue §Scope).
- [ ] DO NOT change the `guards: clear on $ident (rev=$rev …)` log line at the bottom of `check` — `rev` is still computed so operators can read the cumulative count from the per-stage transcript.

### Task 2: Update `bin/guards.sh` usage comment and header-comment block

- `depends_on: [1]`
- `touches: bin/guards.sh (comments)`
- [ ] Update the usage block (content anchor: the literal line `#   guards.sh check <issue_id>` is unique in the file, ~line 31). Change it to:

  ```bash
  #   guards.sh check <issue_id> [stage]
  #     exit 0 if clear, exit 10 if a threshold is tripped (prints which).
  #     When [stage] is omitted, the review_rejection trip fires as today
  #     (operator-triage / case-15 back-compat). When [stage] is provided
  #     (e.g. by bin/run-stage.sh), the review_rejection trip is scoped to
  #     stage == implementing — see header comment below for the ENG-138
  #     contract.
  ```
- [ ] In the header-comment block (content anchor: the line `# `building → implementing` merge-conflict loopback handed each rebase` is unique in the file, ~line 19; the next paragraph starts with `# gotcha_triggered and learned_rule_renewal` at ~line 20), append one new sentence at the end of the ENG-123 paragraph, BEFORE the `gotcha_triggered` paragraph. Suggested text:

  ```bash
  # ENG-138 narrows the firing-side: the review_rejection threshold trips
  # only when the dispatched stage is 'implementing' (the loopback
  # continuation edge). Reaching qa after a clean reviewing PASS no
  # longer halts even when the cumulative count is at or over the
  # threshold. The counter still accumulates across loopback cycles for
  # operator audit (visible in the `guards: clear` log line), and reset
  # semantics (operator-resume waypoint clears) are unchanged.
  ```

### Task 3: Pass `"$stage"` from `bin/run-stage.sh` to both `guards.sh check` invocations

- `depends_on: [1]`
- `touches: bin/run-stage.sh::main`
- [ ] Locate the guards call-site block (content anchor: the comment `# Guards (threshold-based human gates).` is unique in the file, ~line 1176). The next two non-comment lines invoke `guards.sh check "$ident"` twice — once with stderr suppressed for the rc check, once capturing combined output for the halt message.
- [ ] Add `"$stage"` as a second positional argument to BOTH invocations. Resulting block:

  ```bash
  # Guards (threshold-based human gates). ENG-138: pass the dispatched
  # stage so guards.sh::check can scope the review_rejection threshold
  # trip to stage == implementing (the loopback continuation edge).
  if ! bash "$SCRIPT_DIR/guards.sh" check "$ident" "$stage" 2>/dev/null; then
    local tripped
    tripped="$(bash "$SCRIPT_DIR/guards.sh" check "$ident" "$stage" 2>&1 || true)"
    classify_failure "$ident" "$stage" "skip-until-human-acts" \
      "guards tripped: $tripped" 10
    exit 10
  fi
  ```
- [ ] DO NOT change `classify_failure`'s args, the `exit 10` policy, or the surrounding `# Reconcile is now performed …` block.
- [ ] `$stage` is in long-form gerund at this point (`bin/run-stage.sh:main` accepts the first CLI arg verbatim and `bin/run-local.sh` / `bin/poll.sh` pass long-form per the gerund convention documented in `CLAUDE.md::"Per-stage dispatch timeouts (ENG-65)"`). No normalisation needed.

### Task 4: Create `bin/guards-test.sh` with four regression cases

- `depends_on: [1, 3]`
- `touches: bin/guards-test.sh (new)`
- [ ] Create `bin/guards-test.sh` with the project-standard preamble: `#!/usr/bin/env bash`, `set -euo pipefail`, `SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"`, `PIPELINE_DRY_RUN=1`, `LINEAR_API_KEY=test-mock-key`. Mktemp-based `STUB_DIR` with a stub `linear.sh` returning a parameterised comment fixture (mirrors `bin/run-stage-test.sh::case-15` fixture shape at `bin/run-stage-test.sh:1543-1561`).
- [ ] Use the fake-repo overlay shape from `bin/run-stage-test.sh:1535-1541`: symlink the real `bin/guards.sh` and `bin/common.sh` into `$FAKE_REPO/.pipeline/bin/`, symlink real config under `$FAKE_REPO/.pipeline/config.json`, write a per-case `linear.sh` stub at `$FAKE_REPO/.pipeline/bin/linear.sh`.
- [ ] **case-1: AC#2 (preserves ENG-116 intent at stage=implementing).** Stub `linear.sh get-comments` returns two `<!-- meta: metric name=review_rejection -->` markers, no operator-resume. Invoke `bash "$FAKE_REPO/.pipeline/bin/guards.sh" check ENG-T138A implementing`. Assert rc=10, output matches `review_rejection(2>=2)`.
- [ ] **case-2: AC#1 (fixes the regression at stage=qa).** Same stub as case-1 but invoke `bash … guards.sh check ENG-T138B qa`. Assert rc=0; assert `review_rejection` does NOT appear in the output (clear-log line should appear instead — `grep -q 'guards: clear' <<<"$out"` is the positive assertion).
- [ ] **case-3: AC#3 (operator-resume still resets).** Stub returns two `review_rejection` markers plus a newer `<!-- pipeline: transition from=implementing to=implementing reason=operator-resume -->` body. Invoke `bash … guards.sh check ENG-T138C implementing`. Assert rc=0.
- [ ] **case-4: empty-stage back-compat (preserves case-15 CLI shape).** Stub returns two `review_rejection` markers, no operator-resume. Invoke `bash … guards.sh check ENG-T138D` (NO stage arg). Assert rc=10, output matches `review_rejection(2>=2)`. This is the regression test for the `[[ -z "$stage" || … ]]` empty-stage branch in Task 1.
- [ ] Use `pass_at` / `fail_at` shape (precedent: `bin/run-stage-test.sh:24-50` defines these helpers; the new file should inline minimal equivalents — `pass_at "msg"` echoes `PASS: msg`, `fail_at "ctx" "details"` echoes `FAIL: ctx ($details)` and exits 1).
- [ ] End the file with the sentinel `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi` (mirrors every other `bin/*-test.sh`).
- [ ] `chmod +x bin/guards-test.sh` — `.githooks/pre-commit` discovers the file via `bin/*-test.sh` glob and invokes it with `bash`, so the executable bit is convenience for operators running it directly.

### Task 5: Add CLAUDE.md "Failure-mode quick reference" row (optional, gated on row-absence)

- `depends_on: [1, 3, 4]`
- `touches: CLAUDE.md`
- [ ] Verify the row does not already exist via `grep 'review_rejection' CLAUDE.md` — should return 0 matches at implement time (verified at plan time, 2026-05-16; the implement agent re-verifies post-rebase).
- [ ] If still absent, locate the "Failure-mode quick reference" table (content anchor: the table header `| Symptom | Where to look |` is unique in the file). Insert a new row after the existing `gtimeout watchdog can silently fail` row (or any other reasonable insertion point — exact position is not load-bearing; the row's presence is). Suggested row text:
  ```
  | `reviewing → qa` transition halts on `review_rejection(N>=2)` after a clean reviewing PASS | Pre-ENG-138 bug; post-ENG-138 (`bin/guards.sh::check`, gated on `stage == implementing`) the trip only fires at the next `implementing` dispatch. If symptom persists, check transcript for `guards: tripped on ENG-N: review_rejection`; recovery is the standard `bash bin/pipeline.sh decide <issue> --action continue` reset, but the bug itself should not recur. |
  ```
- [ ] If the row already exists (defensive check), skip this task; record `[ ] skipped: row exists` in the dispatch log.

### Task 6: Run gate suite and confirm green

- `depends_on: [1, 2, 3, 4, 5]`
- `touches: (no source edits — gate execution only)`
- [ ] Run the new test directly: `bash bin/guards-test.sh`. Expect all 4 cases PASS, exit 0.
- [ ] Run the case-15 regression: `bash bin/run-stage-test.sh` — Case 15's three subcases must remain green (back-compat assertion).
- [ ] Run the helper-source assertions: `bash bin/verdict-adversarial-test.sh` — A10/A10B/A11 must remain green (they source `bin/guards.sh` directly).
- [ ] Run the allowlist test: `bash bin/profile-allowlist-test.sh` — reviewing/qa allowlist assertions for `Bash(bash bin/guards.sh:*)` must remain green.
- [ ] Run the full pre-commit hook: `bash .githooks/pre-commit`. Expect zero failures (excluding the `KNOWN_BROKEN` allowlist which is unchanged by this plan).
- [ ] DO NOT run `bash bin/dry-run.sh` here — it requires `TARGET_REPO` exported and is not gated by the pre-commit hook; QA stage executes it.

## Frontend Tasks

**None.** This is a harness-self bash plan with no SvelteKit / Tauri / Rust surface (see the project profile's Stack section). Recorded explicitly to satisfy the template contract.

## Failure Mode → Test Map

Each row binds an edge case from the brainstorm §7 to a concrete test.

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
|---|---|---|---|---|
| Cumulative review_rejection halts forward `reviewing → qa` after a clean PASS (the regression) | Invoke `guards.sh check ENG-T138B qa` with two prior `review_rejection` markers and no operator-resume | rc=0; `guards: clear` log line appears; `review_rejection` token absent from output | unit | `bin/guards-test.sh::case-2` |
| Cumulative review_rejection still halts forward at next `implementing` dispatch (ENG-116 intent) | Invoke `guards.sh check ENG-T138A implementing` with two prior `review_rejection` markers and no operator-resume | rc=10; output matches `review_rejection(2>=2)` | unit | `bin/guards-test.sh::case-1` |
| Operator-resume waypoint still clears the counter (ENG-116 contract preserved) | Invoke `guards.sh check ENG-T138C implementing` with two `review_rejection` markers + a newer `reason=operator-resume` transition | rc=0 | unit | `bin/guards-test.sh::case-3` |
| Direct-CLI invocation with no stage arg still trips (back-compat for case-15 and operator triage) | Invoke `guards.sh check ENG-T138D` (no stage) with two `review_rejection` markers and no operator-resume | rc=10; output matches `review_rejection(2>=2)` | unit | `bin/guards-test.sh::case-4` |
| Existing implement_rejection-based case-15 trip still fires after the signature change (no-stage back-compat) | Run `bin/run-stage-test.sh` Case 15 (unchanged fixtures) | All three subcases PASS as today | integration | `bin/run-stage-test.sh::case-15` |
| `count_marker_since_last_operator_resume` helper still accumulates correctly across auto-transitions | Run `bin/verdict-adversarial-test.sh` A10/A10B/A11 | A10 returns 3, A10B returns 1, A11 returns 2 | integration | `bin/verdict-adversarial-test.sh::A10`, `::A10B`, `::A11` |
| Reviewer agent's `Bash(bash bin/guards.sh:*)` allowlist still grants the `bump` invocation post-fix | Run `bin/profile-allowlist-test.sh` | reviewing/qa assertions for `Bash(bash bin/guards.sh:*)` pass | integration | `bin/profile-allowlist-test.sh::review`, `::qa` (anchors at lines 335-347) |
| Unknown stage value (defensive) does NOT trip review_rejection | Invoke `guards.sh check ENG-T138 brainstorming` with two `review_rejection` markers | rc=0; `review_rejection` token absent from output | unit | covered by `bin/guards-test.sh::case-2`'s assertion shape (case-2 passes `qa`; same code path for any non-implementing label) — explicit fifth case unnecessary; cited here for traceability per §7 of the brainstorm |
| Stage-drift race (`run-stage.sh:1756` dispatches `qa` but Linear flips back to `reviewing`) | Pre-dispatch guards sees `stage=qa` (dispatched value); no review_rejection trip | rc=0 from guards; subsequent stage-drift exit at line 1757 fires correctly | (no new test) | covered by existing `bin/run-stage-test.sh::case-19` (drift exit) plus the case-2 assertion |

## Test Strategy

**Unit (`bin/guards-test.sh`, new).** Four fixture cases (case-1 through case-4) enumerated in the Failure Mode → Test Map. Each builds a temp fake-repo overlay with symlinks to the real `bin/guards.sh` and `bin/common.sh`, plus a per-case stub `linear.sh` that returns a parameterised `get-comments` payload. Cases assert exit code and (for trip cases) substring presence in the combined output. Mirrors `bin/run-stage-test.sh::case-15` shape exactly so future readers see a familiar idiom. Runnable standalone via `bash bin/guards-test.sh`; the pre-commit hook auto-discovers it.

**Integration backstop.** Three existing test files cover the second-order assertions the plan depends on:

- `bin/run-stage-test.sh::case-15` (lines 1523-1635) — verifies the empty-stage back-compat branch by passing NO stage arg to `guards.sh check ENG-T15` with `implement_rejection` markers. Stays green because (a) the new signature is back-compat (optional `${2:-}`), and (b) `implement_rejection` is not affected by the `review_rejection`-only narrowing.
- `bin/verdict-adversarial-test.sh::A10/A10B/A11` (lines 158-194) — sources `bin/guards.sh` and tests `count_marker_since_last_operator_resume` directly. The new `stage` arg is local to `check()`; the helper signature is unchanged.
- `bin/profile-allowlist-test.sh::review/qa` (lines 335-347) — asserts `Bash(bash bin/guards.sh:*)` is present in reviewing/qa stage allowlists. Unaffected by adding a positional arg.

**Smoke (`.githooks/pre-commit`).** Runs the full `bin/*-test.sh` suite (~30 s) and blocks commits on any failure. The new `bin/guards-test.sh` is auto-picked up; no `KNOWN_BROKEN` allowlist edit needed. AC#5 from the brainstorm §2 is verified at commit time.

**Adversarial coverage.** Two adversarial shapes worth calling out:

- *Empty-stage CLI invocation* — case-4 explicitly asserts that the `[[ -z "$stage" || "$stage" == "implementing" ]]` empty-stage branch trips as today. This guards against a future refactor that drops the `-z` half (which would silently disable the trip for every operator-triage and case-15 invocation).
- *Stage-drift race* — `bin/run-stage.sh:1748-1762` already exits with `stage-drift` metric when the label flips during dispatch; the new guards call site is upstream of the drift check and uses the DISPATCHED stage value (not the post-dispatch label state), so the race window is closed by inheritance from the existing exit path. No new test needed; cited in §7 of the brainstorm.

**Test-gate closure check (mandatory, per the template).** This plan does NOT remove any token from production code. The `review_rejection($rev>=$review_threshold)` string, the clear-log line, the `bump`'s marker text, and the `count_marker_since_last_operator_resume` helper signature are all preserved verbatim. Therefore no sibling test file contains a token whose meaning is being inverted. The four files Grep showed reference `review_rejection` (`bin/guards.sh` itself, `bin/profile-allowlist-test.sh`'s comments) carry no assertions that the trip MUST fire on a non-implementing dispatch.

## Out of scope (reproduced from issue)

- `qa_rejection` and `implement_rejection` counters — same edge-confusion bug shape may apply (see brainstorm OQ-1 and OQ-2) but explicitly OUT per Linear issue. File follow-ups if observed post-ship.
- Threshold-value change (default 2) — explicitly OUT per Linear issue. See brainstorm OQ-4.
- Pass-clears-counter semantic (Option (b)) — rejected in brainstorm D-1.
- Split-counter design (Option (c)) — rejected in brainstorm D-1.

## Persona review (audit trail)

Five-persona document-review run inline during this dispatch. Headline goes in the Linear stage-summary; full record below.

### Iteration 1

| Persona      | Verdict | Load-bearing findings |
|---|---|---|
| feasibility  | PASS · 0 P0 | Every `path:line` cited has been opened during this dispatch (Assumption Inventory). Task `depends_on` graph is acyclic (1 → 2/3; 3 → 4; all → 5/6). The test-gate closure sweep returned zero tokens-being-removed; no sibling-test halt risk. Edit boundaries use content anchors (`# Guards (threshold-based …)` comment; `check() {` function header; `review_rejection($rev>=…)` token) — no bare-line-only boundaries. Branch-base freshness pinned (`HEAD..origin/main` empty at plan time; pinned to `origin/main = 7f4ab77`). |
| scope        | PASS · 0 P0 | All five file edits (`bin/guards.sh`, `bin/run-stage.sh`, `bin/guards-test.sh`, optional `CLAUDE.md`) trace to Linear issue §Scope IN: list (guards.sh, run-stage.sh, new test) or are documentation adjacent to in-scope files. `OUT:` clause (other counters) is honoured — `qa_rejection`, `implement_rejection`, `gotcha_triggered`, `learned_rule_renewal` trip blocks are not modified. No gold-plating: every task has a verifiable AC#1-AC#5 hook. |
| coherence    | PASS · 0 P0 | Goal sentence matches brainstorm §2. AC#1–AC#5 are 1:1 traceable to Failure Mode → Test Map rows. Backend Tasks 1+3 jointly realise D-1 of the brainstorm; Task 4 realises D-3; Task 5 realises D-4. No row in the table is un-tested; no test is un-mapped to an AC. |
| design       | PASS · 0 P0 | Optional-arg-with-empty-default pattern matches existing harness shape (`bin/render-prompt.sh`'s `${3:-}`, `bin/dispatch.sh`'s `${PIPELINE_DISPATCH_MODEL:-}`, `bin/guards.sh::bump`'s positional handling). No new module boundary, no new dependency, no new state. Single-file change with one-line caller adjustment; the change is reversible via a single revert. The plan respects the project profile's File layout (only `bin/` and `CLAUDE.md` are touched). |
| product      | PASS · 0 P0 | AC#1–AC#5 (brainstorm §2) are observable from `bin/guards-test.sh` output and the existing Linear flow. The cost-asymmetry argument (~$25–30 of agent spend held behind operator-resume) is directly addressed by D-1's narrowed firing edge. The trade-off in brainstorm §7 / OQ-3 (re-entry after qa rejection still inherits the lifetime counter) is honestly named in "Out of scope" and is the same trade-off the brainstorm acknowledged. |

**Gate decision: 5/5 PASS · feasibility P0 = 0 · proceeding to implementing.**
