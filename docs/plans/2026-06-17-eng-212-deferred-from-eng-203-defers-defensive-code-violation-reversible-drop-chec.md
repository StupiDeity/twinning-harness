---
linear: ENG-212
date: 2026-06-17
topic: Drop the env_json object-type recheck inside merge_artifact_envelope (and its U-8 pin) — internal-invariant defensiveness flagged by ENG-203 review
---

# Plan — Drop defensive env_json type recheck in merge_artifact_envelope (ENG-212)

## Anti-anchoring check

- **Problem (operator-perspective):** ENG-203's review caught defensive code at `bin/common.sh:723-724` — `merge_artifact_envelope` re-validates that `env_json` is a JSON object after the caller already constructed it via `jq -nc '{...}'`. The check is an internal-invariant guard that violates the §3 Self-review "Defensive-code restraint" rule (path: `bin/common.sh` is internal — not a `cli/` / `controllers/` boundary). ENG-203 deferred the fix as reversible + no-regression + no user-visible surface; this ticket lands it.
- **Brainstorm framing:** No standalone brainstorm exists for ENG-212 — the ticket body IS the brainstorm (deferred-major auto-filing pattern from ENG-193). Decision factors recorded: `in_changed_code: yes`, `is_regression: no`, `user_visible: no`, `reversible_post_ship: yes`, `has_workaround: yes`. The fix is the inverse of the original violation: delete the recheck (2 lines) + delete the U-8 test (6 lines) + update the rc=42 docstring + one wording fix in a downstream caller's comment.
- **Solution proportionality:** Tiny — 4 file edits, ~10 net-removed lines, zero new abstractions. No new tests, no callers refactored, no taxonomy change (rc=42 still exists for the body-symlink case). Production behavior identical: a hostile caller passing non-object `env_json` (e.g. `'"hi"'`) now routes through `jq --argjson env`'s own type mismatch on `$b[0] + $env` → helper rc=50; both rc=42 and rc=50 already map to `qa-payload-malformed` (run-stage.sh:2102-2106) and to `42` in verify-qa.sh:677. No behavior-observable downstream surface changes.
- **Verdict:** proceed.

## Goal

Remove the internal-invariant `jq -e 'type == "object"' <<<"$env_json"` recheck from `merge_artifact_envelope` and retire its U-8 pinning test, with no change to production behavior of the qa-payload or qa-predicate merge paths; verified by `bash .githooks/pre-commit` passing with U-8 absent and U-1..U-7, U-9..U-11 + OS-6/OS-6b/OS-7 all green.

## Assumption Inventory

- **`bin/common.sh:707` (existing — to be edited).** The rc=42 docstring currently reads:
  ```
  #   42 body is symlink OR envelope arg is not a JSON object
  ```
  After the fix it reads `#   42 body is symlink`. This is a contract claim — leaving it stale is a plan-completeness defect.

- **`bin/common.sh:713-744` (existing — function body).** Current shape of `merge_artifact_envelope`:
  ```bash
  merge_artifact_envelope() {
    local body="$1" env_json="$2" canonical="$3"
    [[ -f "$body" ]] || { printf 'merge: body missing: %s\n' "$body" >&2; return 41; }
    [[ -L "$body" ]] && { printf 'merge: body is symlink: %s\n' "$body" >&2; return 42; }
    local sz; sz="$(wc -c <"$body" 2>/dev/null | tr -d ' ')"
    if [[ -z "$sz" ]] || (( sz <= 0 || sz > 65536 )); then
      printf 'merge: body size out of range: %s bytes\n' "${sz:-0}" >&2; return 39
    fi
    jq -e 'type == "object"' "$body" >/dev/null 2>&1 \
      || { printf 'merge: body is not a JSON object: %s\n' "$body" >&2; return 39; }
    jq -e 'type == "object"' <<<"$env_json" >/dev/null 2>&1 \
      || { printf 'merge: envelope is not a JSON object\n' >&2; return 42; }
    # ... mktemp + `jq -n --slurpfile b "$body" --argjson env "$env_json" '$b[0] + $env'` ...
  }
  ```
  Target removal: the two lines `jq -e 'type == "object"' <<<"$env_json" ...` (currently lines 723-724). The body-type check at 721-722 stays (the body is operator-authored content; that is a system-boundary at the qa stage entry).

- **`bin/run-stage.sh:2089-2112` (existing — qa-stage caller).** Constructs `env_json` via `jq -nc --arg ii "$ident" --arg di "${PIPELINE_DISPATCH_ID:-}" '{qa_payload_schema_version: 1, issue_id: $ii, dispatch_id: $di}'` (line 2095). `jq -nc '{...}'` ALWAYS emits a JSON object on success; on failure the `"$(…)"` substitution yields the empty string, which `--argjson` would then reject in the downstream merge (rc=50 path). The recheck guards a scenario the caller's discipline already prevents.

- **`bin/run-stage.sh:3032` (existing — comment).** Current text inside the qa-stage post-dispatch sequence reads `(body missing → rc=41, body malformed → rc=39, write failure → rc=50, envelope-not-object → rc=42)`. After the fix it reads `(body missing → rc=41, body malformed → rc=39, body symlink → rc=42, write failure → rc=50)`. Plain prose update — no behavior change.

- **`bin/verify-qa.sh:666-680` (existing — qa-predicate caller, unchanged).** Constructs `env_json` via `jq -nc --arg ii "$ARG_IDENT" '{qa_predicate_schema_version: 1, issue_id: $ii}'` (line 668). Same invariant as the run-stage caller. Case statement at 673-680 still handles `42) return 42` for the body-symlink case — no edit required.

- **`bin/common-test.sh:1418-1423` (existing — to be removed).** The U-8 test body:
  ```bash
  # U-8: envelope arg is non-object JSON string → rc=42.
  body="$tdir/u8-body.json"
  canonical="$tdir/u8-canonical.json"
  printf '%s' '{"verdict":"pass"}' > "$body"
  rc=0; merge_artifact_envelope "$body" '"hi"' "$canonical" 2>/dev/null || rc=$?
  assert_eq "U-8: envelope not object → rc=42" "42" "$rc"
  ```
  This is the ONLY assertion pinning the soon-to-be-deleted check. After the check removal, the same input would route through `--argjson env '"hi"'` → `$b[0] + $env` fails (object + string) → helper rc=50. Leaving U-8 in place would flip it red (expected 42, got 50). Adversarial-test sweep confirms no other test references the rc=42 path for an envelope argument.

- **`bin/common-test.sh:1436-1448` (U-10, unchanged).** Pins right-bias caller-discipline contract on a valid OBJECT envelope (`{"verdict":"fail"}` overwrites a body's `verdict`). Independent of U-8 — U-10 continues to pass.

- **`bin/common-test.sh:1450-1469` (U-11, unchanged).** Pins empty-string `dispatch_id` envelope key passes through cleanly; envelope is `{"qa_payload_schema_version":1,"issue_id":"ENG-1","dispatch_id":""}` — a valid object, exercise unaffected by removal.

- **`bin/run-stage-test.sh:9861-9893` (OS-6, unchanged).** Stubs `merge_artifact_envelope` and captures the env_json argument; asserts the qa-payload caller emits `{qa_payload_schema_version, issue_id, dispatch_id}` exactly. The stub fires before any internal-check code in the helper would execute, so this test is unaffected.

- **`bin/run-stage-test.sh:9916-…` (OS-7, unchanged).** Same shape for the qa-predicate caller via verify-qa.sh. Unaffected.

- **`bin/run-stage-test.sh:9896-9913` (OS-6b, unchanged).** Structural pin against stub-bypass refactors on `_merge_qa_payload_envelope`. Unaffected.

- **`bin/common-test.sh:1341` (section header comment).** Currently reads `# ─── ENG-203: merge_artifact_envelope helper (U1-U10) ────`. The header was already stale pre-change (file actually contains U-1..U-11). Out of scope for this ticket — touching it is gold-plating per §6 step 5 scope-drift restraint; the section's full case list is visible in the function body.

- **`docs/brainstorms/2026-06-16-eng-203-…-design.md`, `docs/plans/2026-06-16-eng-203-…-md`, `docs/plans/2026-06-16-eng-203-…json` (historical artifacts, unchanged).** These reference U-8 and rc=42-envelope-not-object as historical decisions. Per harness convention, prior plans/brainstorms are not retro-edited; new ticket-specific reasoning (this doc) supersedes the prior choice without rewriting history.

- **Branch-base freshness:** `HEAD..origin/main` empty at plan time (origin/main = ede2380). HEAD matches origin/main exactly.

## System invariants

- Callers of `merge_artifact_envelope` construct `env_json` via `jq -nc '{...}'`, producing a syntactically valid JSON object whenever the call succeeds; the removed recheck only guarded a caller-discipline violation that cannot occur in the qa-payload or qa-predicate paths. verified_by: bin/run-stage-test.sh:OS-6
- The qa-predicate `--body` caller in verify-qa.sh follows the same `jq -nc` discipline as the qa-payload caller, so the recheck removal does not regress that path either. verified_by: bin/run-stage-test.sh:OS-7
- Body-symlink continues to return rc=42 from `merge_artifact_envelope`, preserving the docstring's narrowed contract and the downstream `42) return 42 ;;` arm in `verify-qa.sh::cmd_validate` and the `39|42|50) defect="qa-payload-malformed"` arm in `run-stage.sh::_merge_qa_payload_envelope`. verified_by: bin/common-test.sh:U-6
- The right-bias caller-discipline contract on valid-object envelopes (U-10) and the empty-string identity-key passthrough (U-11) continue to pass after the recheck is removed — these tests exercise the post-type-check path with valid objects. verified_by: bin/common-test.sh:U-10
- A hostile caller passing a non-object JSON value as `env_json` (the input shape U-8 pinned) now fails inside `jq --argjson env "$env_json" '$b[0] + $env'` → helper rc=50, which the downstream taxonomies (`run-stage.sh:2104` `39|42|50 → qa-payload-malformed`; `verify-qa.sh:678` `50) return 42`) already classify as malformed; the observable user-facing outcome (halt with `qa-payload-malformed` / `qa-predicate-malformed`) is preserved. verified_by: bin/common-test.sh:U-11

## File Structure

- `bin/common.sh` — modified: drop env_json object-type recheck (2 lines) inside `merge_artifact_envelope`; narrow rc=42 docstring line.
- `bin/common-test.sh` — modified: remove U-8 test case (6 lines).
- `bin/run-stage.sh` — modified: update the inline comment listing helper failure modes (one prose clause swap; no executable change).
- `docs/plans/2026-06-17-eng-212-deferred-from-eng-203-defers-defensive-code-violation-reversible-drop-chec.md` — new (this file).
- `docs/plans/2026-06-17-eng-212-deferred-from-eng-203-defers-defensive-code-violation-reversible-drop-chec.json` — new (sibling plan contract).

## API Contract

no new API surface — this ticket removes an internal invariant guard inside a bash helper. No FE↔BE API. No new endpoints, no new types, no schema change.

## Backend Tasks

### Task 1: Drop the env_json type recheck in merge_artifact_envelope

- `depends_on: []`
- `touches: bin/common.sh::merge_artifact_envelope`
- [ ] In `bin/common.sh`, INSIDE `merge_artifact_envelope`'s body, locate the block:
      ```bash
      jq -e 'type == "object"' <<<"$env_json" >/dev/null 2>&1 \
        || { printf 'merge: envelope is not a JSON object\n' >&2; return 42; }
      ```
      It sits AFTER the `jq -e 'type == "object"' "$body" >/dev/null 2>&1 \ || { ... 'merge: body is not a JSON object: %s\n' ... return 39; }` block and BEFORE the `local tmp` declaration. Delete the two lines (the `jq -e ... <<<"$env_json"` line and its `|| { ... return 42; }` continuation).
- [ ] In the SAME file, update the docstring header comment block (the `# ENG-203: orchestrator-side artifact-envelope merge helper.` section). Change the line that reads `#   42 body is symlink OR envelope arg is not a JSON object` to `#   42 body is symlink`. Anchor: it sits BETWEEN the `#   41 body missing` line and the `#   50 mktemp / jq / mv write failure` line, INSIDE the comment block that ends at the `merge_artifact_envelope() {` function definition.
- [ ] Sanity-pass: run `bash -n bin/common.sh`. No syntax error expected.

### Task 2: Retire the U-8 pinning test

- `depends_on: [1]`
- `touches: bin/common-test.sh::eng203_merge_envelope_tests`
- [ ] In `bin/common-test.sh`, INSIDE the `eng203_merge_envelope_tests` function body, locate the U-8 block. It sits AFTER the `assert_eq "U-7: body > 64 KiB → rc=39" "39" "$rc"` line and BEFORE the `# U-9: canonical write target unwritable → rc=50.` comment. Delete the entire 6-line block:
      ```bash
      # U-8: envelope arg is non-object JSON string → rc=42.
      body="$tdir/u8-body.json"
      canonical="$tdir/u8-canonical.json"
      printf '%s' '{"verdict":"pass"}' > "$body"
      rc=0; merge_artifact_envelope "$body" '"hi"' "$canonical" 2>/dev/null || rc=$?
      assert_eq "U-8: envelope not object → rc=42" "42" "$rc"
      ```
      Including the blank line that separates it from U-9, so U-7 → blank → U-9.
- [ ] Do NOT edit the section header at line 1341 (`# ─── ENG-203: merge_artifact_envelope helper (U1-U10) ────`). The (U1-U10) range syntax was already stale before this ticket (file contains U-1..U-11) — editing it is gold-plating outside this ticket's authorization boundary.

### Task 3: Update the helper-failure-mode comment in run-stage.sh

- `depends_on: [1]`
- `touches: bin/run-stage.sh` (comment inside the qa-stage post-dispatch sequence, near `_merge_qa_payload_envelope`)
- [ ] In `bin/run-stage.sh`, INSIDE the comment block that begins `# ENG-203: qa-payload envelope merge. Post-dispatch; qa stage only.` (anchor: it sits immediately ABOVE `if (( ! skip_dispatch )); then` and ABOVE `case "$stage" in`/`qa)` / `_merge_qa_payload_envelope "$ident"` — the helper-failure-mode summary line), change the parenthesised clause:
      `(body missing → rc=41, body malformed → rc=39, write failure → rc=50, envelope-not-object → rc=42)`
      to:
      `(body missing → rc=41, body malformed → rc=39, body symlink → rc=42, write failure → rc=50)`
- [ ] Sanity-pass: run `bash -n bin/run-stage.sh`. No syntax error expected.

### Task 4: Verify pre-commit gate passes cleanly

- `depends_on: [1, 2, 3]`
- `touches: (none — gate run only)`
- [ ] Run `bash .githooks/pre-commit`. Expected: PASS. The gate globs `bin/*-test.sh` (ENG-196), runs every sibling test; the only behaviour-affecting test cases here are U-1..U-7, U-9, U-10, U-11 (still valid) and OS-6, OS-6b, OS-7 (still valid). U-8 is gone from the suite.
- [ ] If the gate fails, do NOT proceed — file the failing test name, the rc, and the assertion text on the Linear issue and `pipeline.sh event ENG-212 verdict halt --reason agent-blocked`.

## Frontend Tasks

n/a — the harness has no frontend; the `ui` stage in this pipeline applies only when the target carries client code. This ticket touches only bash orchestration helpers.

## Failure Mode → Test Map

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
|---|---|---|---|---|
| Body file missing | Caller passes a path that does not exist | Helper returns rc=41; run-stage.sh halts with qa-payload-missing | unit | bin/common-test.sh::U-3 |
| Body is a symlink | Caller passes a symlinked body path | Helper returns rc=42; caller halts with qa-payload-malformed / qa-predicate-malformed | unit | bin/common-test.sh::U-6 |
| Body is not a JSON object (e.g. array) | Caller passes a body containing a top-level JSON array | Helper returns rc=39; caller halts with qa-payload-malformed | unit | bin/common-test.sh::U-4 |
| Body JSON parse error | Caller passes a body with malformed JSON | Helper returns rc=39; caller halts with qa-payload-malformed | unit | bin/common-test.sh::U-5 |
| Body exceeds 64 KiB size cap | Caller passes a body file larger than 65 536 bytes | Helper returns rc=39; caller halts with qa-payload-malformed | unit | bin/common-test.sh::U-7 |
| Canonical write target unwritable | Caller invokes the helper with a canonical path whose parent directory denies write | Helper returns rc=50; caller halts with qa-payload-malformed | unit | bin/common-test.sh::U-9 |
| Caller envelope keys collide with body keys (valid object envelope) | Caller passes a valid-object envelope with overlapping key | Right-bias preserved: envelope wins; right-bias contract pinned for caller discipline | unit | bin/common-test.sh::U-10 |
| Caller passes empty-string identity-key in valid-object envelope | `PIPELINE_DISPATCH_ID` unset → `${VAR:-}` is `""` | Helper passes through cleanly; rc=0 | unit | bin/common-test.sh::U-11 |
| qa-payload caller emits the expected envelope keyset | run-stage.sh's `_merge_qa_payload_envelope` runs against a stub | Captured env_json keys = `{qa_payload_schema_version, issue_id, dispatch_id}` | unit | bin/run-stage-test.sh::OS-6 |
| qa-predicate caller emits the expected envelope keyset | verify-qa.sh's `cmd_validate --body` runs against a stub | Captured env_json keys = `{qa_predicate_schema_version, issue_id}` | unit | bin/run-stage-test.sh::OS-7 |
| `_merge_qa_payload_envelope` cannot be bypassed by a `command merge_artifact_envelope` refactor | Source-file structural inspection of `_merge_qa_payload_envelope` | The function calls `merge_artifact_envelope` and does NOT prefix it with `command ` | unit (structural) | bin/run-stage-test.sh::OS-6b |

Removed failure mode (U-8): "Envelope arg is non-object JSON string". After this change the path becomes a caller-discipline violation that downstream callers in the harness do not produce; if a future caller did emit one, `jq --argjson env "$env_json" '$b[0] + $env'` would fail and the helper would return rc=50 (already mapped to `qa-payload-malformed` / `qa-predicate-malformed`). No new test is added — adding a test that asserts the helper still halts on this caller-bug shape would re-introduce internal-invariant defensiveness from the test side, the same anti-pattern this ticket retires.

## Test Strategy

- **Unit:** rely on the existing U-1..U-7, U-9, U-10, U-11 cases inside `eng203_merge_envelope_tests` (bin/common-test.sh:1348-…). Coverage is unchanged; U-8 is retired as load-bearing dead weight.
- **Integration:** OS-5, OS-6, OS-6b, OS-7, OS-8 in bin/run-stage-test.sh continue to pin caller-side envelope-keyset discipline. None of them exercise the deleted check.
- **Smoke:** `bash .githooks/pre-commit` runs every `bin/*-test.sh` on disk; the suite must pass with U-8 absent. This is the proxy smoke for "no behavior regression".
- **Adversarial sweep:** grep verified no other sibling test references the removed tokens (`envelope is not a JSON object`, `envelope not object`, `env_json` as a function-internal recheck pattern) outside the three files in File Structure. No silent test breakage path.
- **No new tests added.** Adding a "must NOT have this check" test would over-fit the codebase to this one removal; the defensive-code restraint clause in §3 Self-review of AGENT_PROMPTS.md is the future-regression guard. The retrospective will catch a reintroduction during weekly review.
