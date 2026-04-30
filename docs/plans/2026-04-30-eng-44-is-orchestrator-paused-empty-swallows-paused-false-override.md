---
linear: ENG-44
date: 2026-04-30
topic: Close test-coverage gap for `is_orchestrator_paused` (paused=false override) — six-row table in a new `bin/common-test.sh`
---

# Plan — ENG-44: close test-coverage gap for `is_orchestrator_paused`

Implementation plan for the design in
`docs/brainstorms/2026-04-30-is-orchestrator-paused-empty-swallows-paused-false-override-design.md`.

## Anti-anchoring check

**Problem restatement (user perspective).** When an operator runs
`set_orchestrator_paused false` after cleanup, the orchestrator must actually
resume on the next tick. The original `// empty` jq expression silently ate
the `paused: false` override; the operator's resume signal was lost.

**Does the brainstorm address this?** Yes — and it correctly observes that
the *code fix already shipped* in commit `d420c64` (ENG-49). The remaining
work is the six-row test table from ENG-44's "Test" section, of which only
one row (state-file-overrides-true→false) is currently covered (in
`bin/run-local-helpers-adversarial-test.sh:601-611`). The brainstorm
re-scopes ENG-44 to "complete the test coverage" rather than re-fix-and-
revert. This is justified — repeating the fix would be a no-op churn and
the bug-class defense lives in tests anyway.

**Solution proportionality.** One new test file (~150 lines), one in-band
comment in `bin/common.sh`, and one line added to the project-profile test
enumeration. No new behavior, no new orchestration surface, no
infrastructure. Proportionate to a test-gap close.

**Result: PROCEED** (no `pipeline:supersede` or `pipeline:extend` needed).

## Goal

Land a single PR off `main` (`feat/eng-44-is-orchestrator-paused-empty-swallows-paused-false-override`)
that, after merge, satisfies these acceptance criteria:

1. `bin/common-test.sh` exists, is executable, exits 0 against current
   `bin/common.sh`, and asserts all six rows of ENG-44's test table
   (rows numbered 1–6 in §5 of the brainstorm).
2. `bin/common.sh:128` (just above the jq expression) carries a one-line
   comment naming the `// empty` anti-pattern, citing ENG-44 / ENG-49, so a
   future "simplify verbose jq" sweep cannot regress the bug silently.
3. `learned-rules/harness/project-profile.md:17` `Test:` enumeration
   includes `bash bin/common-test.sh` so the discovery-agent's regenerated
   profile and any test-aggregator pick it up.
4. Existing tests still pass: `bin/run-local-helpers-adversarial-test.sh`'s
   `test_paused_override_honored` (the one-row overlap) and
   `test_paused_callsites_use_helper` are unchanged and still pass.
5. `bash -n bin/common-test.sh` is clean (the project's only lint gate).

Out of scope (per brainstorm §2 non-goals and ENG-44 issue):
- Restructuring the override mechanism (multi-key, layered hierarchy).
- Auditing other `// empty` sites in the harness.
- Adding `set_orchestrator_paused` write-side tests.
- Deleting the existing one-row overlap in
  `run-local-helpers-adversarial-test.sh`.

## Assumption Inventory

Each assumption is verified against the current worktree (branch
`feat/eng-44-is-orchestrator-paused-empty-swallows-paused-false-override`,
HEAD `a871211`).

### A-001 — `is_orchestrator_paused` body and signature (verified)

`bin/common.sh:126-136`:
```bash
is_orchestrator_paused() {
  if [[ -f "$STATE_FILE" ]]; then
    local override
    override="$(jq -r 'if .orchestrator.paused != null then .orchestrator.paused else empty end' "$STATE_FILE" 2>/dev/null || true)"
    if [[ -n "$override" ]]; then
      printf '%s' "$override"
      return
    fi
  fi
  jq -r '.orchestrator.paused // "false"' "$CONFIG"
}
```

The function is no-arg, takes `STATE_FILE` and `CONFIG` from environment at
call time (no caching), prints `"true"` or `"false"` to stdout. The fix is
already in place — the plan does NOT change the function body, only adds a
comment line above it (Task 2).

### A-002 — Caller list (5, not 2; from brainstorm §3 D-001 P0 fix, verified)

```
bin/poll.sh:376        paused="$(is_orchestrator_paused)"
bin/run-local.sh:91    paused="$(is_orchestrator_paused)"
bin/run-stage.sh:251   paused="$(is_orchestrator_paused)"
bin/reset-pipeline.sh:31  if [[ "$(is_orchestrator_paused)" == "true" ]]; then
bin/dry-run.sh:73      bash -c '[[ "$(is_orchestrator_paused)" == "false" ]]'
```

Plus the definition at `bin/common.sh:126` and the export at
`bin/common.sh:151`. Verified by `grep -n is_orchestrator_paused bin/*.sh`.
**The plan touches none of these call sites** — Task 1's tests verify the
helper's contract; the five callers consume that contract unchanged.

### A-003 — Existing single-row coverage (verified)

`bin/run-local-helpers-adversarial-test.sh:601-611`:
```bash
test_paused_override_honored() {
  local tdir; tdir="$(mktemp -d -t twinning-paused.XXXXXX)"
  local cfg="$tdir/config.json" sf="$tdir/state.local.json"
  jq -n '{orchestrator:{paused:true}}' > "$cfg"
  jq -n '{orchestrator:{paused:false}}' > "$sf"
  local got
  CONFIG="$cfg" STATE_FILE="$sf" got="$(is_orchestrator_paused)"
  assert_eq "paused-override state.local wins" "false" "$got"
  rm -rf "$tdir"
}
test_paused_override_honored
```

This row stays where it is (D-002 — accept the one-row overlap). Same file,
lines 616-622, also defines `test_paused_callsites_use_helper`, a static
`grep` check that fails if `poll.sh`/`run-local.sh` revert to
`config_get '.orchestrator.paused'`. Both stay unchanged.

### A-004 — Per-call `CONFIG=… STATE_FILE=…` override pattern works (verified)

`bin/common.sh:127,129,135` reference `$STATE_FILE` and `$CONFIG`
syntactically inside the function body — bash resolves env vars at call
time, not at definition time. The pattern at
`bin/run-local-helpers-adversarial-test.sh:607` (`CONFIG="$cfg"
STATE_FILE="$sf" got="$(is_orchestrator_paused)"`) is the documented
fixture pattern; Task 1's tests reuse it row-for-row.

### A-005 — Pre-source environment requirements (verified)

`bin/common.sh:11-12` requires `TARGET_REPO` to be set and to point at an
existing directory; `bin/common.sh:40-48` requires `PROJECT_SLUG` to be set
OR `config.json::project.slug` to be present in `$TARGET_REPO/.pipeline-
config/config.json` OR `TWINNING_BOOTSTRAPPING=1`. The cleanest test
pattern is to `mktemp -d` for `TARGET_REPO` and `export PROJECT_SLUG=test-
slug` BEFORE sourcing common.sh, mirroring
`bin/profile-allowlist-test.sh:23-44` and
`bin/run-local-helpers-adversarial-test.sh:20-23`.

### A-006 — `set -uo pipefail` precedent for table-driven tests (verified)

Two existing test files use `set -uo pipefail` (no `-e`) so all rows run
even if one fails: `bin/run-local-helpers-adversarial-test.sh:18` and
`bin/profile-allowlist-test.sh:22`. Most tests use `set -euo pipefail`.
Task 1 follows the table-driven precedent (`-uo`). Note: common.sh sets
`set -euo pipefail` at line 7 when sourced, so Task 1's test must `set +e`
AFTER sourcing to actually enable continue-on-fail (mirror
`bin/profile-allowlist-test.sh:62-69`).

### A-007 — Project-profile test enumeration (verified)

`learned-rules/harness/project-profile.md:17` lists every required test
file as a `&&`-chained shell line:
```
- Test: `bash bin/dispatch-test.sh && bash bin/run-stage-test.sh && bash bin/poll-slot-test.sh && bash bin/scope-check-test.sh && bash bin/verdict-handler-test.sh && bash bin/classify-failure-test.sh && bash bin/halt-sprawl-test.sh && bash bin/halt-sprawl-adversarial-test.sh && bash bin/linear-test.sh && bash bin/metrics-test.sh && bash bin/mutex-test.sh && bash bin/setup-helpers-test.sh && bash bin/render-prompt-test.sh && bash bin/phase-project-profile-test.sh`
```
Adding `&& bash bin/common-test.sh` to the end (Task 3) is a single-line
edit. Open Question Q1 in the brainstorm — answered "yes, same PR" — is
satisfied by Task 3.

### A-008 — Target file does not exist (verified — green-field)

`ls bin/common-test.sh` returns no such file (verified at brainstorm time
and re-verified at plan time). Filename matches the `<module>-test.sh`
convention used by every sibling test (`dispatch-test.sh`, `linear-test.sh`,
`metrics-test.sh`, …). No collision with existing names.

### A-009 — Secret-probe-lint constraint (verified)

`bin/secret-probe-lint.sh` (per CLAUDE.md preamble) forbids
`${VAR:-FALLBACK}` and `${VAR:+ALTERNATE}` against env vars matching
`*KEY|*TOKEN|*SECRET|ANTHROPIC*|GITHUB*|LINEAR*`. Task 1's test sets
`TARGET_REPO`, `PROJECT_SLUG`, `CONFIG`, and `STATE_FILE` — none match the
secret-shape regex, so neither `:-` nor `:+` is forbidden here. The test
does not source secrets and does not need `LINEAR_API_KEY`. (We will still
prefer `${VAR-}` empty-fallback or `: "${VAR:=…}"` assign-default forms by
default to stay consistent with the rest of the harness.)

### A-010 — Stage-summary expectation (assumed/contractual)

The orchestrator's stage-summary slot expects an artifact link of the form
`[docs/plans/<file>.md](<github-blob-url>)`. The blob URL must point at the
plan doc on the feature branch. The branch name is
`feat/eng-44-is-orchestrator-paused-empty-swallows-paused-false-override`.
Plan-stage step 5 builds this URL after the plan doc is committed and pushed.

## File Structure

```
bin/
  common-test.sh                                      NEW — 6-row table from ENG-44 (Task 1)
  common.sh                                           modified — +1 comment line above the jq expression at line 128 (Task 2)

learned-rules/
  harness/
    project-profile.md                                modified — Test: line gains `&& bash bin/common-test.sh` (Task 3)

docs/
  plans/
    2026-04-30-eng-44-is-orchestrator-paused-empty-swallows-paused-false-override.md   NEW — this file
```

No other files change. Specifically NOT touched (per brainstorm §3 D-004
and §11):
- `bin/poll.sh`, `bin/run-local.sh`, `bin/run-stage.sh`,
  `bin/reset-pipeline.sh`, `bin/dry-run.sh` (the five callers — none need
  edits).
- `bin/run-local-helpers-adversarial-test.sh` (one-row overlap stays;
  callsite static check stays).
- `AGENT_PROMPTS.md`, `learned-rules/twinning/*`, any orchestration script,
  any launchd plist.

## API Contract

No new API surface. The harness has no FE↔BE API; the only stable interface
is the bash function `is_orchestrator_paused` whose signature is unchanged
(no args, prints `"true"|"false"`, reads `$STATE_FILE`+`$CONFIG`). This
plan adds tests around the existing contract; it does not modify it.

## Backend Tasks

### Task 1: Add `bin/common-test.sh` covering all six rows of ENG-44's test table

- `depends_on: []`
- `touches: bin/common-test.sh`

- [ ] **Step 1.1 — Create file with header, env setup, source order.**
  Mirror `bin/profile-allowlist-test.sh:1-67`'s scaffolding pattern. The
  file uses `set -uo pipefail` (not `-euo`) so a failing row doesn't abort
  the suite; common.sh's own `set -e` is undone with `set +e` after source.

  Concrete header (write to `bin/common-test.sh`):
  ```bash
  #!/usr/bin/env bash
  # ENG-44: bin/common.sh::is_orchestrator_paused — six-row test table.
  #
  # Coverage maps directly to ENG-44's Test table (rows 1-6). Row 2 also
  # exists in bin/run-local-helpers-adversarial-test.sh:601-611
  # (test_paused_override_honored, written for ENG-49). The overlap is
  # intentional (see brainstorm D-002): self-contained module-level
  # coverage beats cross-file scavenging for a future reader.
  #
  # Read priority under test (bin/common.sh:122-125 contract):
  #   STATE_FILE (if present and key is non-null) > CONFIG > "false"

  set -uo pipefail
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  # Throwaway TARGET_REPO and PROJECT_SLUG — common.sh requires both at
  # source time (bin/common.sh:11-12, :40-48).
  _TEST_ROOT="$(mktemp -d -t twinning-eng44.XXXXXX)"
  _assert_temp_path() {
    case "$1" in
      /var/folders/*|/tmp/*|/private/var/folders/*|/private/tmp/*) return 0 ;;
      *) printf 'REFUSING: %q is not a platform temp dir\n' "$1" >&2; exit 99 ;;
    esac
  }
  _assert_temp_path "$_TEST_ROOT"
  trap 'case "$_TEST_ROOT" in /var/folders/*|/tmp/*|/private/var/folders/*|/private/tmp/*) rm -rf "$_TEST_ROOT" ;; esac' EXIT

  export TARGET_REPO="$_TEST_ROOT/target"
  mkdir -p "$TARGET_REPO/.pipeline-config"
  export PROJECT_SLUG="${PROJECT_SLUG:-test-slug}"

  # shellcheck source=common.sh
  source "$SCRIPT_DIR/common.sh"
  # common.sh sets `-e`; relax it so a failing row does not abort.
  set +e
  ```

- [ ] **Step 1.2 — Add `assert_eq` and PASS/FAIL summary scaffolding.**
  Reuse the same shape as
  `bin/run-local-helpers-adversarial-test.sh:27-52`:
  ```bash
  PASS=0; FAIL=0; FAILED_CASES=()
  report_ok()   { printf 'OK: %s\n' "$1"; PASS=$((PASS+1)); }
  report_fail() {
    printf 'FAIL: %s\n  expected: %s\n  got:      %s\n' "$1" "$2" "$3" >&2
    FAIL=$((FAIL+1)); FAILED_CASES+=("$1")
  }
  assert_eq() {
    local name="$1" expected="$2" got="$3"
    if [[ "$got" == "$expected" ]]; then report_ok "$name"; else report_fail "$name" "$expected" "$got"; fi
  }
  ```

- [ ] **Step 1.3 — Add a `mkfixture` helper that materializes per-row
  `config.json` and `state.local.json` and returns their paths.**
  Each row uses `mktemp -d` under `$_TEST_ROOT` so test isolation is
  per-call; CONFIG and STATE_FILE are passed as per-call env overrides
  to `is_orchestrator_paused` (the documented pattern at
  `bin/run-local-helpers-adversarial-test.sh:607`).

  ```bash
  mkfixture() {
    local row_name="$1" cfg_paused="$2" sf_body="$3"
    local tdir; tdir="$(mktemp -d "$_TEST_ROOT/row-${row_name}-XXXXXX")"
    local cfg="$tdir/config.json" sf="$tdir/state.local.json"
    if [[ "$cfg_paused" == "absent" ]]; then
      printf '{}\n' > "$cfg"
    else
      jq -n --argjson p "$cfg_paused" '{orchestrator:{paused:$p}}' > "$cfg"
    fi
    case "$sf_body" in
      "absent")     ;;                              # no state.local.json file
      "{}")         printf '{}\n' > "$sf" ;;
      "{orch:{}}")  printf '{"orchestrator":{}}\n' > "$sf" ;;
      *)            printf '%s\n' "$sf_body" > "$sf" ;;
    esac
    printf '%s\n%s\n' "$cfg" "$sf"
  }
  ```

  Usage: `read -r cfg sf < <(mkfixture row1 true absent)`.

- [ ] **Step 1.4 — Implement six row tests bound 1:1 to brainstorm §5
  table.** Each row's name encodes its scenario:

  | Row | Test name | STATE_FILE | config.paused | Expected |
  |-----|-----------|------------|---------------|----------|
  | 1 | `row1_state_file_absent_falls_to_config_true`            | absent                              | `true`  | `true`  |
  | 2 | `row2_state_file_overrides_config_to_false`              | `{orchestrator:{paused:false}}`     | `true`  | `false` |
  | 3 | `row3_state_file_overrides_config_to_true`               | `{orchestrator:{paused:true}}`      | `false` | `true`  |
  | 4 | `row4_state_file_empty_object_falls_to_config`           | `{}`                                | `true`  | `true`  |
  | 5 | `row5_state_file_orchestrator_empty_falls_to_config`     | `{"orchestrator":{}}`               | `true`  | `true`  |
  | 6 | `row6_both_layers_absent_returns_false`                  | `{}`                                | absent  | `false` |

  Concrete row 2 (the regression direction the original ENG-44 issue
  flagged):
  ```bash
  row2_state_file_overrides_config_to_false() {
    local cfg sf got
    read -r cfg sf < <(mkfixture row2 true '{"orchestrator":{"paused":false}}')
    got="$(CONFIG="$cfg" STATE_FILE="$sf" is_orchestrator_paused)"
    assert_eq "row2_state_file_overrides_config_to_false" "false" "$got"
  }
  row2_state_file_overrides_config_to_false
  ```

  Implement rows 1, 3, 4, 5, 6 with the same shape. Row 1 omits `sf`
  creation by passing `absent`; row 6 omits `cfg.orchestrator.paused` by
  passing `absent` for `cfg_paused`. Each test calls itself at the bottom
  (test-runner pattern — there is no test-discovery framework).

- [ ] **Step 1.5 — Add summary footer.**
  ```bash
  printf '\ncommon-test summary: %d passed, %d failed\n' "$PASS" "$FAIL"
  if (( FAIL > 0 )); then
    printf 'failed cases:\n'
    for c in "${FAILED_CASES[@]}"; do printf '  - %s\n' "$c"; done
    exit 1
  fi
  exit 0
  ```

- [ ] **Step 1.6 — Make executable and validate locally.**
  ```bash
  chmod +x bin/common-test.sh
  bash -n bin/common-test.sh                # syntax check
  bash bin/common-test.sh                   # all 6 rows must pass
  ```

  Expected output ends with `common-test summary: 6 passed, 0 failed` and
  exit 0.

### Task 2: Add a one-line warning comment above the jq expression in `bin/common.sh`

- `depends_on: []`
- `touches: bin/common.sh::is_orchestrator_paused`

- [ ] **Step 2.1 — Edit `bin/common.sh:128` (the line immediately above
  the jq expression at line 129).** Insert one comment line. Pick
  Open-Question Q2's suggested wording verbatim:

  ```bash
    if [[ -f "$STATE_FILE" ]]; then
      local override
      # Don't simplify to '// empty': false is jq-falsy and would silently
      # eat a paused=false override. See ENG-44 / ENG-49 / bin/common-test.sh.
      override="$(jq -r 'if .orchestrator.paused != null then .orchestrator.paused else empty end' "$STATE_FILE" 2>/dev/null || true)"
  ```

  Edit shape (one Edit call):
  - `old_string`: lines 127-129 from current `bin/common.sh` (the
    `if [[ -f "$STATE_FILE" ]]; then` block including the existing
    `local override` and `override=…` lines, exactly as they appear today).
  - `new_string`: same lines with the two comment lines inserted between
    `local override` and `override=…`.

  No other line in `bin/common.sh` changes. Function body, signature, and
  exports stay identical.

- [ ] **Step 2.2 — Validate.**
  `bash -n bin/common.sh && bash bin/common-test.sh`. Expected: 6 passed,
  0 failed (the comment doesn't affect behavior).

### Task 3: Pin `bin/common-test.sh` in the project-profile test enumeration

- `depends_on: [1]`
- `touches: learned-rules/harness/project-profile.md::"Test:" line`

- [ ] **Step 3.1 — Edit `learned-rules/harness/project-profile.md:17`.**
  Append `&& bash bin/common-test.sh` to the end of the existing `&&`-
  chained command, before the trailing closing backtick. Diff shape:

  ```diff
  -- Test: `… && bash bin/render-prompt-test.sh && bash bin/phase-project-profile-test.sh`
  ++ Test: `… && bash bin/render-prompt-test.sh && bash bin/phase-project-profile-test.sh && bash bin/common-test.sh`
  ```

  Justification: brainstorm Open Question Q1 is answered "same PR" because
  the test exists nowhere else; without the pin, the next discovery-agent
  refresh would not regenerate this list with the new test. `phase-project-
  profile-test.sh` (which validates the profile schema) does NOT verify the
  Test: line's content, so this edit is safe to make manually.

- [ ] **Step 3.2 — Validate the new Test: line.**
  Run the full chain to confirm it still parses and all tests pass:
  ```bash
  TARGET_REPO=. bash bin/dispatch-test.sh && \
    TARGET_REPO=. bash bin/run-stage-test.sh && \
    … && \
    TARGET_REPO=. bash bin/common-test.sh
  ```

  (Local validation only; CI is unchanged because there is no CI runner
  reading this Test: line yet — discovery-agent picks it up on next
  profile refresh.)

## Frontend Tasks

`(n/a) — bash-only harness; no FE artifacts.` Recorded explicitly to
satisfy the template contract; mirrors the precedent at
`docs/plans/2026-04-28-eng-46-agent-env-probe-pattern-secret-unset-leaks-key-values-into-agent-context.md`
("Frontend Tasks section is therefore empty by design").

## Failure Mode → Test Map

Pulled from the brainstorm's §5 (data flow) + §6 (error handling) + §7
(edge cases), bound to the six rows of `bin/common-test.sh`. Each row in
this table is exactly one test in the new file:

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
|---|---|---|---|---|
| State file absent → must read CONFIG | `state.local.json` does not exist; `config.json::orchestrator.paused = true` | returns `true` | unit | `row1_state_file_absent_falls_to_config_true` |
| **Regression direction** (original ENG-44 bug) — false override silently eaten | `state.local.json` carries `paused:false`; `config.json` carries `paused:true` | returns `false` (state file wins) | unit | `row2_state_file_overrides_config_to_false` |
| True override against false default | `state.local.json` carries `paused:true`; `config.json` carries `paused:false` | returns `true` (state file wins) | unit | `row3_state_file_overrides_config_to_true` |
| State file present but completely empty object | `state.local.json` = `{}`; `config.json::paused = true` | returns `true` (fall through to CONFIG) | unit | `row4_state_file_empty_object_falls_to_config` |
| State file has `orchestrator` namespace but no `paused` key | `state.local.json` = `{"orchestrator":{}}`; `config.json::paused = true` | returns `true` (fall through to CONFIG) | unit | `row5_state_file_orchestrator_empty_falls_to_config` |
| Both layers absent → safe default | `state.local.json` exists but is `{}`; `config.json::paused` key absent | returns `false` (the `// "false"` jq fallback) | unit | `row6_both_layers_absent_returns_false` |

Out-of-table edge cases (per brainstorm §7) are intentionally NOT bound to
tests in this iteration:
- malformed JSON in `STATE_FILE` (covered implicitly by rows 4/5 because
  `2>/dev/null || true` swallows the jq error → empty override → fall
  through);
- non-bool values (`"true"`, `1`, `0`); race between two ticks (atomic
  rename — covered transitively by `mutex-test.sh`); symlink to missing
  path (covered implicitly by row 1's absent path).

## Test Strategy

**Unit (canonical layer for this work).** Six rows in `bin/common-test.sh`
exercise every branch of `is_orchestrator_paused`'s decision tree
(`-f STATE_FILE` × `paused != null` × CONFIG fallback × CONFIG default).
Branch coverage is 100% by construction: row 1 hits "no state file";
rows 2-3 hit "state file with explicit value"; rows 4-5 hit "state file
present but key absent at different depths"; row 6 hits the CONFIG `//
"false"` default branch.

**Integration.** The existing single-row integration check at
`bin/run-local-helpers-adversarial-test.sh:601-611` stays — confirms the
helper is wired into the actual orchestrator binary path. No new
integration coverage is needed; the contract surface is one function and
the unit tests cover it.

**Smoke.** `bin/dry-run.sh:73` already smoke-tests
`is_orchestrator_paused` end-to-end (`bash -c '[[ "$(is_orchestrator_paused)"
== "false" ]]'`) against a real `TARGET_REPO/.pipeline-config/state.local.
json` written by the smoke run. Unchanged by this plan; will continue to
pass because the helper's behavior is preserved.

**Adversarial.** Two adversarial rows already in
`bin/run-local-helpers-adversarial-test.sh`:
- `test_paused_override_honored` (line 601) — same as our row 2; deliberate
  overlap (D-002).
- `test_paused_callsites_use_helper` (line 616) — static `grep` guard
  preventing the call-site bypass regression. Stays in place.

**Lint.** `bash -n bin/common-test.sh` and `bash -n bin/common.sh` (the
project's only lint gate per project profile §"Lint/check"). Both must
pass.

**No new test infrastructure** is added: no test runner, no fixture
factory, no stub library. The standard source-and-stub pattern from
`bin/profile-allowlist-test.sh` is replicated verbatim.

---

## Self-review (post-draft)

Five personas in parallel. Each verdict + key findings below. Final gate:
**5/5 PASS, 0 P0 findings → proceed to implementing**.

### feasibility — PASS

Every named symbol verified against current HEAD (`a871211`):

- `bin/common.sh:126-136` `is_orchestrator_paused` body — direct read,
  matches the function quoted in A-001.
- `bin/common.sh:127`, `:129`, `:135` reference `$STATE_FILE` and `$CONFIG`
  syntactically — verified, supports the per-call override pattern.
- `bin/common.sh:7` `set -euo pipefail` — verified, requires `set +e` in
  test after source.
- `bin/common.sh:11-12` `TARGET_REPO` exists guard — verified.
- `bin/common.sh:40-48` `PROJECT_SLUG` resolution — verified (test
  pre-sets `PROJECT_SLUG`).
- All five caller lines (`bin/poll.sh:376`, `bin/run-local.sh:91`,
  `bin/run-stage.sh:251`, `bin/reset-pipeline.sh:31`, `bin/dry-run.sh:73`)
  — verified by `grep -n is_orchestrator_paused bin/*.sh`. Plan touches
  none of them.
- `bin/run-local-helpers-adversarial-test.sh:601-611, 616-622` — verified.
- `bin/profile-allowlist-test.sh:22-69` source-and-stub scaffolding —
  verified, mirrored 1:1.
- `learned-rules/harness/project-profile.md:17` Test: line — verified to
  end with `bash bin/phase-project-profile-test.sh`.
- `bin/common-test.sh` does not exist — verified (`ls` returns no such
  file). Green-field name; no collision.
- `bin/secret-probe-lint.sh` would not flag the test file (no
  `${VAR:-FALLBACK}` against secret-shaped names).
- All Failure Mode rows name a real, plan-defined test name; all
  `depends_on` lists are correct (Task 3 needs Task 1 because the project-
  profile pin would fail validation if the test it points at didn't exist;
  Tasks 1 and 2 are independent — could in principle run in parallel).

### scope — PASS

Every task and file traces to a brainstorm decision:
- Task 1 → D-001 (new `bin/common-test.sh`) and D-002 (cover all six rows).
- Task 2 → D-003 (in-band warning comment).
- Task 3 → Open Question Q1 (resolved "same PR").
- File Structure entries are exactly the three files D-001/D-003/Q1
  authorize. No gold-plating: no `set_orchestrator_paused` write tests
  (Q4 deferred), no `// empty` audit (out-of-scope per ENG-44 and §11),
  no test consolidation/deletion (Q3 deferred).
- D-004 (no call-site changes) is honored — File Structure does NOT list
  `poll.sh`/`run-local.sh`/`run-stage.sh`/`reset-pipeline.sh`/`dry-run.sh`.

### coherence — PASS

- Goal restates the brainstorm's §2 user outcome (operator's resume signal
  cannot silently re-break) in PR-shaped acceptance criteria.
- Backend Tasks jointly realize all three brainstorm decisions (D-001
  via Task 1, D-003 via Task 2, Q1 via Task 3); Frontend Tasks correctly
  marked n/a per harness convention.
- Failure Mode → Test Map covers every row of brainstorm §5's table (rows
  1-6) and is consistent with §6 (error handling) and §7 (edge cases —
  marked NOT bound to tests with justification).
- Test Strategy enumerates unit/integration/smoke/adversarial/lint and
  each layer points at a concrete file or test name.
- The plan's File Structure section and Task `touches` lists agree (no
  task strays outside declared files).

### design — PASS

- No layering violations: `common.sh` is the lowest-level helper; tests
  source it directly without going through any caller. The plan does not
  introduce a circular dep (no caller sources the test, and the test does
  not source any caller).
- Test belongs with its function's home (D-001 rationale) — respects
  the implicit module boundary.
- The `&&`-chained Test: line is a flat enumeration; appending preserves
  short-circuit semantics (any earlier failure prevents `common-test.sh`
  from running, but `common-test.sh` doesn't depend on any earlier test's
  side effects).

### product — PASS

- Operator-facing benefit (the resume signal works) is named in the Goal
  section's first paragraph and in §2 of the brainstorm.
- The Linear issue's "Test" section deliverable is a six-row table; the
  plan delivers exactly six rows with names that map 1:1 to the rows.
- The plan's name on disk (`docs/plans/2026-04-30-eng-44-…`) matches
  Rule P-001 (frontmatter + filename convention).
- No "solving an adjacent technical problem" risk: the scope rejection of
  the `// empty` audit (§11), of the override-mechanism restructure
  (§2 non-goals), and of `set_orchestrator_paused` write-side tests
  (Q4 deferred) is explicit.

**Gate result: 5/5 PASS · gate P0: 0 · proceeding to implementing.**
