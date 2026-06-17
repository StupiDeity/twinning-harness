---
linear: ENG-213
date: 2026-06-17
topic: Drop unreachable `*)` arm from `_merge_qa_payload_envelope`'s rc-defect case (ENG-203 deferred finding)
---

# Plan — Drop unreachable `*)` arm in `_merge_qa_payload_envelope` (ENG-213)

## Anti-anchoring check

- **Problem (operator-perspective):** None observable to operators. ENG-203's
  review iteration 2 flagged `bin/run-stage.sh:2102-2106` —
  `_merge_qa_payload_envelope`'s rc → defect case carries a `*)` arm that maps
  to `qa-payload-malformed`, identical to the `39|42|50` arm above it. The arm
  is dead code: `merge_artifact_envelope` (the only caller's helper) has a
  closed-contract rc ∈ {0, 39, 41, 42, 50}; rc=0 is filtered upstream by
  `if (( rc != 0 ))`. Reviewer adjudicated `blocks_ship=false` with decision
  factors `in_changed_code=yes`, `is_regression=no`, `user_visible=no`,
  `reversible_post_ship=yes`, `has_workaround=yes (arm is no-op)` — and
  deferred to this ticket.
- **Brainstorm framing:** No brainstorm. The deferred-finding ticket body
  IS the spec; `finding_class_key=maintainability:run-stage.sh:case-rc-fallthrough-defensive`
  + decision_factor `reversible_post_ship=yes (drop *)` is the directive.
  Linear issue rendered the actionable change verbatim. No reframing needed
  or possible.
- **Proportionality:** One-line deletion in `bin/run-stage.sh`; one structural
  pin (~12 lines) appended to the existing `ENG-203 OS-*` block in
  `bin/run-stage-test.sh`. Touches one subsystem (orchestrator/dispatch) and
  one decision (drop the arm vs. re-pin the closed-contract). Subordinate
  decision: pin absence of `*)` via existing structural-anchor pattern
  (OS-6b/OS-7b/OS-8 precedent). Proportional. Proceed.

## Goal

Delete the dead `*)` arm at `bin/run-stage.sh:2102-2106`'s rc → defect case in
`_merge_qa_payload_envelope`, and pin its absence via a new structural test
(`ENG-203 OS-9`) so a future refactor can't silently re-add the defensive
dead code.

## Assumption Inventory

**branch-base freshness:** `HEAD..origin/main` empty at plan time
(`origin/main = ede2380` = HEAD). No rebase task needed.

### Verified — code paths quoted from current tree

- `[verified]` `bin/run-stage.sh:2089-2112` — `_merge_qa_payload_envelope`'s
  body, with the offending case at lines 2102-2106:

      case "$rc" in
        41) defect="qa-payload-missing" ;;
        39|42|50) defect="qa-payload-malformed" ;;
        *)  defect="qa-payload-malformed" ;;
      esac

  Content anchor: the literal `_merge_qa_payload_envelope() {` (line 2089)
  and the unique `41) defect="qa-payload-missing"` line (line 2103). The
  `41)` arm of `_validate_qa_payload` (line 2133) is distinct — it calls
  `_post_qa_payload_halt` directly with a return, not a bare defect
  assignment — so the anchor is unambiguous within the file.
- `[verified]` `bin/common.sh:699-744` — `merge_artifact_envelope`'s header
  comment documents the closed-contract:

      #   0  success
      #   39 body malformed (not an object / parse error / oversize)
      #   41 body missing
      #   42 body is symlink OR envelope arg is not a JSON object
      #   50 mktemp / jq / mv write failure

  Content anchor: the literal `merge_artifact_envelope() {`. The closed set
  is `{0, 39, 41, 42, 50}` — no other rc values can be returned.
- `[verified]` `bin/common-test.sh:1378-1434` — U-3 through U-9 pin every
  non-zero rc in the helper's closed-contract:

      U-3: rc=41 (body missing)
      U-4: rc=39 (body is array)
      U-5: rc=39 (body parse error)
      U-6: rc=42 (body is symlink)
      U-7: rc=39 (body > 64 KiB)
      U-8: rc=42 (envelope not object)
      U-9: rc=50 (unwritable canonical parent)

  Content anchor: `# U-3: body missing → rc=41.` block marker. These tests
  jointly cover every non-zero exit path; if a future regression widens the
  contract, a new U-N would be required to land alongside it, AND that new
  U-N would need a matching arm in `_merge_qa_payload_envelope`.
- `[verified]` `bin/run-stage-test.sh:9769-9806` — OS-2 (rc=41) and OS-3
  (rc=39) directly call `_merge_qa_payload_envelope` and assert defect
  mapping for the two arms that survive the deletion. Neither test exercises
  the `*)` arm. Content anchor: `# OS-2: body file absent → merge rc=41`
  and `# OS-3: body file is parse error → merge rc=39`.
- `[verified]` `bin/run-stage-test.sh:9896-9913` — OS-6b's structural pin
  awk-extracts `_merge_qa_payload_envelope`'s body and asserts:
    1. body contains `merge_artifact_envelope` (the call must persist), AND
    2. body does NOT contain `command merge_artifact_envelope` (no `command`
       prefix bypass).
  Both assertions remain true after dropping the `*)` arm; OS-6b is robust
  to this change. Content anchor: `# OS-6b (ENG-203 review M4): structural
  pin against stub-bypass refactors.`
- `[verified]` `bin/run-stage-test.sh:9971-9996` — OS-8's structural pin
  awk-extracts the qa-stage hook in `main()` (a different region — the
  caller, not the helper). Anchors on `# ENG-203: qa-payload envelope
  merge.` and the closing `fi`. The OS-8 region is unmodified by this
  ticket. Content anchor: `# OS-8 (ENG-203 review M5)`.
- `[verified]` `bin/run-stage-test.sh:9999-10001` — End of file:

      echo "run-stage-test: passed=$PASS failed=$FAIL"
      (( FAIL == 0 )) || exit 1

  Content anchor for inserting OS-9: the literal `--- ENG-203:
  orchestrator-merge + clear-on-start (OS-1..OS-7) ---` header (the OS
  block) and the closing `echo "run-stage-test: passed=..."` line. OS-9
  is appended INSIDE the OS block, BEFORE the final summary echo.
- `[verified]` `learned-rules/harness/project-profile.md:14-19` — Build &
  test gates section: gate-runnable glob is `bin/*-test.sh`, executed by
  `.githooks/pre-commit`. `bin/run-stage-test.sh` already matches the
  glob; no profile update required (sibling test extended, no NEW file
  added).

## System invariants

- `merge_artifact_envelope`'s non-zero return-code set is closed at
  `{39, 41, 42, 50}`. `verified_by: bin/common-test.sh:U-3` (and the
  contiguous U-4 through U-9 block in the same file pinning every member
  of the closed set; U-3 is the lead marker).
- After this plan ships, `_merge_qa_payload_envelope`'s rc → defect case
  contains exactly two arms (`41)` and `39|42|50)`); no `*)` fallthrough.
  `verified_by: task:T2` (Task 2 below adds OS-9 in
  `bin/run-stage-test.sh`, asserting the function body has no `*)` arm).
- OS-2's rc=41 → `qa-payload-missing` defect mapping is unchanged.
  `verified_by: bin/run-stage-test.sh:OS-2`.
- OS-3's rc=39 → `qa-payload-malformed` defect mapping is unchanged.
  `verified_by: bin/run-stage-test.sh:OS-3`.
- OS-6b's structural pin (function calls `merge_artifact_envelope`, no
  `command` prefix bypass) remains satisfied.
  `verified_by: bin/run-stage-test.sh:OS-6b`.

## File Structure

Modified:
- `bin/run-stage.sh` — drop one arm (`*)  defect="qa-payload-malformed" ;;`)
  inside `_merge_qa_payload_envelope`'s rc → defect case.
- `bin/run-stage-test.sh` — append `OS-9` structural pin inside the ENG-203
  OS block, before the final summary echo.

No new files. No `learned-rules/harness/project-profile.md` edit (sibling
test extended in an already-gate-runnable location; add-side closure not
triggered).

## API Contract

No new API surface — internal helper change.

## Backend Tasks

### Task 1: Drop the `*)` arm from `_merge_qa_payload_envelope`'s rc → defect case
- `depends_on: []`
- `touches: bin/run-stage.sh::_merge_qa_payload_envelope`
- [ ] Edit `bin/run-stage.sh`. Content-anchor the change to the literal
      sequence `41) defect="qa-payload-missing" ;;` immediately followed
      by the `39|42|50)` arm AND the `*)` arm (this triple is unique to
      `_merge_qa_payload_envelope` — `_validate_qa_payload`'s `41)` arm
      calls `_post_qa_payload_halt` with a return, not a bare defect
      assignment). Replace:

          case "$rc" in
            41) defect="qa-payload-missing" ;;
            39|42|50) defect="qa-payload-malformed" ;;
            *)  defect="qa-payload-malformed" ;;
          esac

      with:

          case "$rc" in
            41) defect="qa-payload-missing" ;;
            39|42|50) defect="qa-payload-malformed" ;;
          esac

- [ ] No other change to the function body. Do NOT add comments
      explaining the deletion — the closed-contract assertion lives in
      `bin/common.sh`'s `merge_artifact_envelope` header comment and is
      pinned by U-3..U-9 in `bin/common-test.sh`; the deletion's
      rationale lives in this plan and the OS-9 test name.

### Task 2: Add OS-9 — structural pin asserting `*)` arm is absent
- `depends_on: [1]`
- `touches: bin/run-stage-test.sh::ENG-203 OS-block`
- [ ] Edit `bin/run-stage-test.sh`. Content-anchor on the OS-8 closing
      block: AFTER the line `unset _os8_hook _os8_fail` (~line 9997)
      and BEFORE the trailing `echo` summary at lines 9999-10001.
- [ ] Insert OS-9: awk-extract `_merge_qa_payload_envelope`'s body
      (same shape as OS-6b at lines 9904-9905) and assert the body's
      `case "$rc" in ... esac` block contains exactly two arms
      (`41)` and `39|42|50)`) and no `*)` fallthrough. Suggested shape:

          # OS-9 (ENG-213): pin absence of the dropped `*)` defensive
          # fallthrough in _merge_qa_payload_envelope's rc → defect case.
          # ENG-203's review iter-2 found the *) arm mapped to the same
          # defect as the 39|42|50 arm and was unreachable given
          # merge_artifact_envelope's closed-contract rc ∈ {0,39,41,42,50}
          # (pinned by U-3..U-9 in bin/common-test.sh). Reversible: if a
          # future regression widens the contract, re-add the *) arm.
          _os9_body=""
          _os9_body="$(awk '/^_merge_qa_payload_envelope\(\) \{/,/^\}/' "$HARNESS_DIR/run-stage.sh" 2>/dev/null || true)"
          _os9_fail=""
          [[ "$_os9_body" == *'41) defect="qa-payload-missing"'* ]] || _os9_fail+="missing 41) arm; "
          [[ "$_os9_body" == *'39|42|50) defect="qa-payload-malformed"'* ]] || _os9_fail+="missing 39|42|50) arm; "
          [[ "$_os9_body" != *'*)  defect='* ]] || _os9_fail+="found *) defensive fallthrough (dropped by ENG-213); "
          if [[ -z "$_os9_fail" ]]; then
            pass_at "ENG-213 OS-9: _merge_qa_payload_envelope case has no *) fallthrough"
          else
            fail_at "ENG-213 OS-9: case-arm shape" "$_os9_fail"
          fi
          unset _os9_body _os9_fail

      Note the literal pattern `*)  defect=` (with TWO spaces — matches
      the original file's indentation) avoids false-matches on any other
      `*)` glob substring in the function body.

## Frontend Tasks

No frontend surface.

## Failure Mode → Test Map

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
|---|---|---|---|---|
| `*)` arm re-introduced into `_merge_qa_payload_envelope` | Refactor adds `*)  defect="..." ;;` back into the case | OS-9 fails with `found *) defensive fallthrough (dropped by ENG-213)` | unit | `bin/run-stage-test.sh::ENG-213 OS-9` |
| `41)` arm removed from `_merge_qa_payload_envelope` | Refactor drops the missing-body arm | OS-9 fails with `missing 41) arm`; OS-2 fails (rc=41 → empty defect → halt body lacks `qa-payload-missing`) | unit | `bin/run-stage-test.sh::ENG-203 OS-2` + `ENG-213 OS-9` |
| `39\|42\|50)` arm removed | Refactor drops the malformed-body arm | OS-9 fails with `missing 39\|42\|50) arm`; OS-3 fails (rc=39 → empty defect → halt body lacks `qa-payload-malformed`) | unit | `bin/run-stage-test.sh::ENG-203 OS-3` + `ENG-213 OS-9` |
| `merge_artifact_envelope` contract widened with new rc (e.g. 43) without caller update | Body of helper returns 43; `_merge_qa_payload_envelope`'s case has no matching arm | `defect=""` → halt comment with empty defect string (accepted regression per decision_factor `reversible_post_ship=yes`); operator re-adds `*)` arm as workaround | accepted regression (no test) | n/a — explicit reversibility tradeoff |

## Test Strategy

### Unit
- OS-9 (new) pins the case-arm shape via awk-anchored structural
  inspection (same pattern as OS-6b/OS-7b/OS-8). Catches re-introduction
  of the dead `*)` arm and accidental removal of either surviving arm.
- OS-2/OS-3 (existing, unchanged) pin the live arms' rc → defect
  mappings via end-to-end calls to `_merge_qa_payload_envelope`.

### Integration / Smoke
- Existing OS-1 (clean body → merged canonical → `_validate_qa_payload`
  rc=0 roundtrip) still passes. The clean-pass path is unaffected by
  this change.

### Adversarial
- U-3..U-9 in `bin/common-test.sh` (existing, unchanged) pin every
  non-zero rc in `merge_artifact_envelope`'s closed-contract. If a
  future regression introduces a new rc (e.g. 43), U-N would have to
  land alongside it AND `_merge_qa_payload_envelope`'s case would need
  a matching arm — OS-9's structural pin would NOT catch the contract
  widening itself, but the operator-facing halt comment with empty
  `defect` string would surface within one dispatch and re-adding the
  `*)` arm restores the prior behavior (explicit reversibility per
  ticket decision_factors).

### Gate coverage
- `bin/run-stage-test.sh` and `bin/common-test.sh` both run under the
  `bin/*-test.sh` glob in `.githooks/pre-commit` (per
  `learned-rules/harness/project-profile.md`'s Build & test gates
  section); no profile update required.
