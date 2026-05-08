---
linear: ENG-86
date: 2026-05-08
topic: orchestrator-side per-stage entry-condition gate (build first; configurable, generic) — short-circuit awaiting-approval re-dispatches at ~100ms cost
---

# Plan — ENG-86 orchestrator-side per-stage entry-condition gate

Implementation plan for the design in
`docs/brainstorms/2026-05-08-eng-86-orchestrator-side-per-stage-entry-condition-check-before-agent-dispatch-build-stage-first-configurable-generic-design.md`.

## Anti-anchoring

- **Problem (operator's words):** every 5-min tick that picks up a
  `stage:building` issue waiting on a non-bot APPROVED review re-dispatches
  the build agent end-to-end (~2 min wall-clock, ~$0.5–0.7) just to re-run
  preflight P0–P7 and re-emit `verdict wait reason=awaiting-approval`. The
  wall-clock is the load-bearing cost: after ENG-81 K=2, two awaiting-approval
  issues can occupy both parallel slots and starve other ready work.
- **Does the brainstorm address it?** Yes. It pre-empts the dispatch with a
  ~100ms `gh pr view --json reviews` query before `dispatch.sh` is invoked.
  The brainstorm reframes the Linear issue's pseudocode placement
  (insert in `bin/run-local.sh::main`) to `bin/run-stage.sh::main` — D-001
  documents this as a *structural* correction, not a scope change: (a)
  `dispatch.sh` is invoked from `run-stage.sh:744`, not `run-local.sh`;
  (b) `_handle_wait` (the ENG-45 budget primitive the issue's Risks
  section requires us to integrate with) is in scope only inside
  `run-stage.sh`; (c) the pre-dispatch-gate pattern is already
  established by ENG-62's `_pre_dispatch_merge_gate` at
  `bin/run-stage.sh:613-654`. The intent ("orchestrator runs cheap gate
  before agent dispatch") is fully preserved; only the file location
  differs. **Flagged for review attention** because the AC text names
  `run-local.sh` explicitly.
- **Proportional?** Yes. One new ~80 LOC file (`bin/entry-conditions.sh`),
  one new helper (`_entry_conditions_gate`) + one ~10-line block in
  `bin/run-stage.sh::main`, one new ~150 LOC test file, one operator-applied
  config-key (gitignored), one CLAUDE.md docblock, one new metric outcome
  string. No new label, no new marker shape, no new pipeline-events.json
  registry entry, no new dispatch tool-allowlist entry, no
  `bin/run-local.sh` change. Brainstorm explicitly rejected wider
  alternatives (mini-DSL §8.2-A; cache layer §8.2-B; `poll.sh`-side gate
  §8.2-C; inlining into `_pre_dispatch_merge_gate` §8.2-E; new
  `verify_preconditions` exit code §8.2-F).
- **No escalation needed.**

## Goal

Land an orchestrator-side, config-driven per-stage entry-condition gate at
`bin/run-stage.sh::_entry_conditions_gate` (called from `main()` between
`_pre_dispatch_merge_gate` and the per-issue `mkdir`), backed by a new
`bin/entry-conditions.sh` registry whose only initial check is
`pr-approved-by-non-bot` for stage `building` — such that a `stage:building`
issue whose PR has zero non-bot APPROVED reviews skips the build-agent
dispatch entirely on each tick (~100ms instead of ~2 min), bumps the
existing ENG-45 wait counter via `_handle_wait`, and emits a
`dispatch-skipped` metric event — verifiable via
`bash bin/entry-conditions-test.sh && bash bin/run-stage-test.sh && bash bin/dispatch-test.sh && bash -n bin/entry-conditions.sh && bash -n bin/run-stage.sh && bash bin/secret-probe-lint.sh`
all exiting 0 with the new ENG-86 cases A–F all PASS and the existing
ENG-45 budget cases (run-stage-test.sh G/H/I) extended for case G
("orchestrator-skip increments the same counter") all PASS.

## Architecture

The change is additive across two existing scripts (`bin/run-stage.sh`,
`CLAUDE.md`), one new orchestrator script (`bin/entry-conditions.sh`),
and one new sibling test (`bin/entry-conditions-test.sh`). No changes to
`bin/run-local.sh`, `bin/poll.sh`, `bin/dispatch.sh`,
`bin/verdict-handler.sh`, `bin/classify-failure.sh`, `bin/linear.sh`,
`bin/metrics.sh`, `bin/pipeline-events.json`, `AGENT_PROMPTS.md`,
`bin/branch-name.sh`, `bin/halt-sprawl-test.sh`,
`bin/run-local-sweep-test.sh`, or `bin/run-local-helpers.sh`.

The architectural pivot is: the orchestrator gains a *generic*,
config-driven pre-dispatch check stack that mirrors the ENG-62
`_pre_dispatch_merge_gate` shape but is parameterized over an array of
named checks per stage. Phase 1 ships exactly one check
(`pr-approved-by-non-bot` on `building`); Phase 2 (deferred) can opt
other stages in (review SHA gate, retrospective cadence) without schema
migration.

The new helper `_entry_conditions_gate` is the integration boundary: it
calls out to `bin/entry-conditions.sh` (a separate script that returns
`proceed` / `skip:<reason>` / `error:<check-name>` on stdout), and
on `skip` it routes through the existing `_handle_wait` budget primitive
so ENG-45's `external_signal_budget` escalation still applies — a buggy
predicate that permanently skips dispatch will still halt the issue
within `max_attempts` ticks.

The Linear issue's "Result coupling" risk (orchestrator-side check vs
agent-side P2) is addressed by D-008: a comment in
`check_pr_approved_by_non_bot` cites `AGENT_PROMPTS.md:1287-1289` as
the source of truth; the agent-side P2 is unchanged (defense-in-depth
when an operator opts out of the config or when `gh` errors fail-open).

There is no `docs/VISION.md`, no `docs/knowledge/decisions.md`, no
`SYSTEM_ARCHITECTURE.md` (verified: only `brainstorms/`,
`pipeline-vocabulary.md`, `plans/`, `runbooks/`, and the
`pipeline-vocabulary.template.md` exist under `docs/`). Governing
constraints come from `CLAUDE.md`, the
`learned-rules/harness/project-profile.md` profile, and
`learned-rules/harness/build.md`. The plan-level learned-rules file
`learned-rules/harness/plan.md` does not exist (verified — only
`build.md` and `project-profile.md` are present).

## Tech stack

- Bash 3.2+ (Darwin default, harness-self target).
- `jq` for config parse + `gh` JSON shaping (already a hard dep —
  `bin/common.sh:316-319 config_get`, `bin/metrics.sh:53` jq invocation).
- `gh` CLI (already used by `bin/run-stage.sh:632`,
  `bin/review-poll.sh:41`).
- No new dependencies. No `bin/dispatch.sh::allowed_tools_for` cases
  added (the gate runs on the harness host, not in any agent sandbox).

## Assumption Inventory

Every modified-file fact is `path:line`-cited against the current
worktree (`/Users/rajatgoyal/.local/state/twinning-harness/harness/ENG-86/worktree/`).
Assumptions marked `assumed/new` identify the file where the artifact
will be created.

### Modified files — current signatures, call sites, and globals

- **A-001 — `bin/run-stage.sh::main()` insertion-point boundaries.**
  - AFTER: `_pre_dispatch_merge_gate` invocation block at
    `bin/run-stage.sh:710-722`. Quoted (lines 710-722):

    ```
    710  if _pre_dispatch_merge_gate "$ident" "$stage"; then
    711    t1="$(date +%s)"; duration=$(( (t1 - t0) * 1000 ))
    ...
    717    bash "$SCRIPT_DIR/metrics.sh" stage-start "$ident" "$stage" \
    718      "merged-pre-dispatch" 0 || true
    719    bash "$SCRIPT_DIR/metrics.sh" stage-end "$ident" "$stage" \
    720      "merged-pre-dispatch" "$duration" || true
    721    exit 0
    722  fi
    ```

  - BEFORE: `mkdir -p "$(issue_dir "$ident")"` at `bin/run-stage.sh:726`.

  The new gate-firing block lands between line 722 and line 726 (i.e.,
  before the prompt-rendering block beginning at line 728). No other
  line in `main()` is modified.

- **A-002 — `bin/run-stage.sh::_handle_wait` complete signature and
  budget logic at lines 489–578.** Verified — key lines:

  ```
  489  _handle_wait() {
  490    local PIPELINE_WRITER=orchestrator
  491    export PIPELINE_WRITER
  492
  493    local ident="$1" stage="$2" reason="$3"
  494    local f; f="$(issue_dir "$ident")/wait-${stage}.json"
  ...
  543    max_a="$(config_get '.orchestrator.external_signal_budget.max_attempts // empty')"
  544    max_m="$(config_get '.orchestrator.external_signal_budget.max_minutes  // empty')"
  ...
  575      return 1
  ...
  577    return 0
  ...
  578  }
  ```

  The new `_entry_conditions_gate` will call `_handle_wait "$ident"
  "$stage" "$reason"` with the unmet check's reason string. Returns 0 →
  within budget; returns 1 → budget exhausted (halt already applied).

- **A-003 — `bin/run-stage.sh::_pre_dispatch_merge_gate` is the
  pre-dispatch-gate pattern at lines 613–654.** Verified — key lines
  (lane attribution, gh-outage fail-open, return-1=fall-through):

  ```
  613  _pre_dispatch_merge_gate() {
  ...
  618    local PIPELINE_WRITER=orchestrator
  619    export PIPELINE_WRITER
  620
  621    local ident="$1" stage="$2"
  622    case "$stage" in building) ;; *) return 1 ;; esac
  623    command -v gh >/dev/null 2>&1 || return 1
  624
  625    local _branch
  626    _branch="$(bash "$SCRIPT_DIR/branch-name.sh" "$ident" 2>/dev/null || printf '')"
  627    [[ -n "$_branch" ]] || return 1
  ```

  The new helper `_entry_conditions_gate` reuses these idioms: `local
  PIPELINE_WRITER=orchestrator; export PIPELINE_WRITER` at the top;
  fail-open on subprocess failure (D-010).

- **A-004 — `bin/run-stage.sh::main()` agent-side `_handle_wait` call
  site at line 947.** Verified:

  ```
  947      if _handle_wait "$ident" "$stage" "$_wait_reason"; then
  ```

  The new orchestrator-side call site in `_entry_conditions_gate`
  is its sibling — same signature, same return semantics, but
  invoked synchronously in the orchestrator path before any agent
  dispatch.

- **A-005 — `bin/run-stage.sh:947`'s wait-success branch emits a
  `soft-pending` metric at lines 957–959.** Verified — that outcome
  literal is paired to "agent ran and emitted wait verdict". The
  orchestrator-skip path uses a NEW outcome literal `dispatch-skipped`
  to distinguish "agent did not run" from "agent ran-and-waited"
  (D-006). No change to the existing `soft-pending` callers.

- **A-006 — `bin/run-stage.sh::main()` already imports `verdict-handler.sh`
  at line ~21 and `classify-failure.sh` at line ~22.** Verified by
  proxy through ENG-62's plan §A-002. The new helper does NOT call
  `apply_transition` or `classify_failure` — `_handle_wait` is the
  only state-mutation primitive the gate touches.

- **A-007 — `bin/run-stage.sh:489-578::_handle_wait` writes
  `wait-${stage}.json` and reads `orchestrator.external_signal_budget.{max_attempts,max_minutes}`.**
  Verified at `bin/run-stage.sh:494` (`f="$(issue_dir "$ident")/wait-${stage}.json"`),
  lines 543-544 (config reads), and lines 546-558 (exhaust check).
  The orchestrator-skip path will share the `wait-${stage}.json`
  file with the (today only agent-driven) wait path — same `attempts`
  field, same `first_attempt_at` field. No schema change.

- **A-008 — `bin/run-stage.sh:1126-1128` sentinel pattern.** Verified
  — the file ends with the `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"; fi` sentinel that `bin/run-stage-test.sh:101` relies on
  to source the file without firing `main`. The new helper
  `_entry_conditions_gate` lands above `main()` in source order (in
  the same neighbourhood as `_pre_dispatch_merge_gate` at lines
  613–654, immediately after `_pre_dispatch_merge_gate`'s closing
  `}` at line 654 for grep-ability).

- **A-009 — `bin/dispatch.sh::main()` ENG-65 per-stage timeout config
  read at lines 388-403.** Verified — this is the validation pattern
  template the brainstorm cites (D-005). Key lines:

  ```
  388  if [[ -f "$CONFIG" ]]; then
  389    local _cfg_minutes
  390    _cfg_minutes="$(jq -r --arg s "$stage" \
  391      '.orchestrator.dispatch_timeout_minutes_per_stage[$s] // empty' \
  392      "$CONFIG" 2>/dev/null || true)"
  ...
  396    [[ -n "$_cfg_minutes" && "$_cfg_minutes" =~ ^[0-9]+$ ]] && timeout_minutes="$_cfg_minutes"
  397  fi
  ```

  The new `should_dispatch` in `bin/entry-conditions.sh` will use the
  identical jq read shape (with `$CONFIG`, `--arg s "$stage"`, `// []`
  fallback) for `orchestrator.entry_conditions[$s]`.

- **A-010 — `bin/dispatch.sh::allowed_tools_for` building case at
  line 328.** Verified — the building stage's allowed-tools list
  already includes `Bash(gh pr view:*)` and `Bash(gh pr list:*)`.
  The orchestrator-side check runs on the harness host (NOT in the
  agent sandbox), so no allowlist change is required, but the
  parallel agent-side P2 query continues to work.

- **A-011 — `bin/branch-name.sh:31` derivation.** Verified:

  ```
  31    printf '%s/%s-%s\n' "$prefix" "$ident_lower" "$slug"
  ```

  Where `$prefix` is `feat` or `fix` per `bin/branch-name.sh:26-29`
  (Bug label → `fix`, else → `feat`). The new check function
  invokes `bash "$SCRIPT_DIR/branch-name.sh" "$ident"` and uses the
  returned branch as the `gh pr view <branch>` argument.

- **A-012 — `bin/common.sh:316-319 config_get`.** Verified:

  ```
  316  config_get() {
  317    local path="$1"
  318    jq -r "$path" "$CONFIG"
  319  }
  ```

  The new `should_dispatch` reads `$CONFIG` via the local jq invocation
  (it needs `--arg s "$stage"` parameterization which `config_get`
  doesn't expose — same shape as `bin/dispatch.sh:390-392` already
  uses).

- **A-013 — `bin/common.sh:68 issue_dir`.** Verified:

  ```
  68   issue_dir() {
  69     local issue="$1"
  70     [[ -n "$issue" ]] || die "issue_dir: missing issue id"
  71     printf '%s/%s' "$PROJECT_STATE_DIR" "$issue"
  72   }
  ```

  Used transitively via `_handle_wait` at `bin/run-stage.sh:494`. The
  new helper does not call `issue_dir` directly.

- **A-014 — `bin/metrics.sh::main` accepts arbitrary outcome strings
  at lines 19-75.** Verified — `outcome` is `--arg outcome "$outcome"`
  at line 58 (no enum gate). New literal `dispatch-skipped` is sound
  by inspection. Cost-flag args (`--cost-usd`, `--tokens-in`, etc.)
  are optional per the parser at lines 27-37.

- **A-015 — `bin/run-stage-test.sh` source-and-stub fixtures at lines
  1–115.** Verified — `STUB_DIR` setup (line 17), stub `linear.sh`
  with capture (lines 21–38), stub `branch-name.sh` (lines 40–44),
  toggleable stub `gh` keyed off `MOCK_GH_PR_STATE`/`MOCK_GH_PR_URL`
  (lines 53–68), `MOCK_COMMENTS_JSON` injection point (line 28-29),
  source-after-stub at line 101 (`source "$HARNESS_DIR/run-stage.sh"`),
  post-source `SCRIPT_DIR` override at line 114. Existing ENG-45
  budget integration tests: case G at line 1039, case H at 1051,
  case I at 1062-1083, case I-LF at 1085-1134, then the linear-stub
  restoration block at lines 1136-1139 (the `mv` + `chmod +x`
  immediately before case J starts at line 1141). The file ends at
  line 3448 with the `passed=$PASS failed=$FAIL` summary at line 3447.
  The ENG-86 cases (G/G2/G3) append at the END of the file
  (immediately before the `echo` + summary block at line 3446) so
  they don't perturb the existing case-ordering or stub-restoration
  state. The new cases use a fresh `bin/entry-conditions.sh` stub
  under `$STUB_DIR` that emits `skip:awaiting-approval` to drive
  `_entry_conditions_gate` and assert on the resulting
  `wait-building.json` `attempts` field.

- **A-016 — `bin/dispatch-test.sh` enumerated-tests count assertion at
  lines 2140-2168.** Verified — the test scans
  `$HARNESS_ROOT/.pipeline-config/config.json` for the
  `dispatch.tools.{implementing,qa}` arrays and asserts (a) no broken
  `Bash(bash bin/*-test.sh:*)` wildcard, (b) the literal-prefix entry
  count is `>=` the count of `bin/*-test.sh` files on disk. Adding
  `bin/entry-conditions-test.sh` increases the on-disk count by one;
  the harness operator (Rajat) must regenerate the local
  `.pipeline-config/config.json` per the CLAUDE.md `## Per-target
  dispatch.tools extras` regen one-liner. **Note for the implementer:**
  `.pipeline-config/` is gitignored — the implement agent MUST NOT
  commit the regenerated config; that is an operator-side step. The
  `dispatch-test.sh` check skips when `$HARNESS_CONFIG` is absent
  (line 2167) so CI / non-harness operators do not see a regression.

### New (assumed) files

- **A-017 — `bin/entry-conditions.sh`** (assumed/new). New file at
  `bin/entry-conditions.sh`. Shape per brainstorm D-004 (~80 LOC):
  `set -euo pipefail`, `source "$SCRIPT_DIR/common.sh"`,
  `check_pr_approved_by_non_bot()` (input: issue id; outputs:
  rc=0 met / rc=1 unmet+stdout reason / rc=2 error),
  `_entry_check_handler_for()` (case-arm name → handler-fn-name),
  `should_dispatch()` (CLI verb: stdout `proceed` | `skip:<reason>`
  | `error:<check-name>`; exit always 0), and the standard sentinel
  pattern. The new file MUST end with the
  `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then ... fi` sentinel so
  `bin/entry-conditions-test.sh` can `source` it for unit-test access
  to the check functions without firing `main`.

- **A-018 — `bin/entry-conditions-test.sh`** (assumed/new). New file
  at `bin/entry-conditions-test.sh`. Source-and-stub pattern per
  CLAUDE.md "Tests" §, mirroring `bin/run-stage-test.sh:1–115`.
  Stubs: `gh`, `bin/branch-name.sh`. Post-source overrides:
  `SCRIPT_DIR=$STUB_DIR; PATH="$STUB_DIR:$PATH"; CONFIG=$TMP_CFG`.
  Test cases A–F per Failure Mode → Test Map below.

- **A-019 — Q1 (retrospective filter accepts `dispatch-skipped`).**
  `assumed`. The brainstorm §7 Q1 is the only `assumed` item — the
  retrospective's §1 outcome filter (`bin/run-retrospective-local.sh`)
  may silently drop unknown outcome strings. **Mitigation:** Task 6
  adds a one-shot dry-run verification step. If silent-drop is
  observed, file a follow-up ticket; the gate's primary function
  (cost recovery) is unaffected even in the silent-drop case.

## File Structure

```
bin/entry-conditions.sh                   NEW   ~80 LOC. should_dispatch CLI verb + check_pr_approved_by_non_bot + _entry_check_handler_for registry. Sentinel at end.
bin/entry-conditions-test.sh              NEW   ~150 LOC. Source-and-stub fixtures; cases A-F covering met/unmet/malformed/empty/gh-outage/gerund-mismatch.
bin/run-stage.sh                          MOD   Add _entry_conditions_gate helper (above main, immediately after _pre_dispatch_merge_gate at line 654). Insert gate-firing block in main() between line 722 and line 726.
bin/run-stage-test.sh                     MOD   Append ENG-86 case G ("orchestrator-skip increments wait-building.json attempts") to the ENG-45 test block at lines 1039+.
CLAUDE.md                                 MOD   Add ## Orchestrator entry-conditions docblock (parallel to ## Per-stage dispatch timeouts at lines ~299-350); document config schema, fail-open semantics, dispatch-skipped metric, gerund-key trade-off.
```

No other file is modified or created. Per brainstorm D-009:
`bin/run-local.sh`, `bin/poll.sh`, `bin/dispatch.sh`,
`bin/verdict-handler.sh`, `bin/classify-failure.sh`, `bin/linear.sh`,
`bin/metrics.sh`, `bin/pipeline-events.json`, `AGENT_PROMPTS.md`,
`bin/branch-name.sh` are unchanged.

The operator-applied (not committed) `$TARGET_REPO/.pipeline-config/config.json`
key `orchestrator.entry_conditions.building` is part of the rollout
runbook (Task 7), NOT this PR's diff — `.pipeline-config/` is
gitignored per CLAUDE.md "## Per-target dispatch.tools extras".

## API Contract

no new API surface (this is a bash orchestration repo with no FE↔BE
HTTP/IPC interface; the only inter-script "contract" is the stdout
shape of `bash bin/entry-conditions.sh should_dispatch <stage> <issue>`
and the existing `_handle_wait` signature, both documented in §A-002,
§A-017, and the per-task code snippets below).

## Backend Tasks

(All tasks are "backend" — this repo has no UI surface. The "Frontend
Tasks" section below is a deliberate "no UI surface" note, per
project profile.)

### Task 1: Create `bin/entry-conditions.sh` with the `pr-approved-by-non-bot` check and the `should_dispatch` CLI verb

- `depends_on: []`
- `touches: bin/entry-conditions.sh (new)`
- [ ] Create new file `bin/entry-conditions.sh`. Shebang
      `#!/usr/bin/env bash`, `set -euo pipefail`, then
      `SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"`,
      `source "$SCRIPT_DIR/common.sh"`. Match the prologue shape used
      by `bin/branch-name.sh:1-13`.
- [ ] Add the check function `check_pr_approved_by_non_bot` per
      brainstorm D-004. Contract: input = `$1` issue id; rc=0 met,
      rc=1 unmet (stdout = reason string `awaiting-approval`),
      rc=2 error (tooling outage / branch-derivation failure / `gh`
      empty-or-failed / `jq` parse failure). The `gh pr view --json
      reviews` query and the embedded jq filter MUST mirror the
      agent-side P2 at `AGENT_PROMPTS.md:1287-1289`. Add a comment
      citing that location as the source of truth (per D-008).
      Snippet:

      ```bash
      check_pr_approved_by_non_bot() {
        local issue="$1"
        command -v gh >/dev/null 2>&1 || return 2
        local branch
        branch="$(bash "$SCRIPT_DIR/branch-name.sh" "$issue" 2>/dev/null || printf '')"
        [[ -n "$branch" ]] || return 2
        # Mirrors AGENT_PROMPTS.md §7 P2 (lines 1287-1289). If P2 evolves,
        # update this filter in lockstep — see ENG-86 D-008.
        local reviews_json
        reviews_json="$(gh pr view "$branch" --json reviews 2>/dev/null || printf '')"
        [[ -n "$reviews_json" ]] || return 2
        local approved_count
        approved_count="$(jq -r '
          [.reviews[] | select(.state == "APPROVED" and (.author.login | test("\\[bot\\]$") | not))]
          | length' <<<"$reviews_json" 2>/dev/null || printf '0')"
        [[ "$approved_count" =~ ^[0-9]+$ ]] || return 2
        (( approved_count >= 1 )) && return 0
        printf 'awaiting-approval\n'
        return 1
      }
      ```

- [ ] Add `_entry_check_handler_for` (private helper):
      case-arm `pr-approved-by-non-bot) printf 'check_pr_approved_by_non_bot' ;;`
      with default `*) return 1 ;;` (signals "unknown check name" to
      the caller). New checks land here in Phase 2.
- [ ] Add `should_dispatch` (public CLI verb): args `<stage> <issue>`,
      reads `$CONFIG` (from common.sh) via
      `jq -c --arg s "$stage" '.orchestrator.entry_conditions[$s] // []' "$CONFIG"`,
      iterates over the array, dispatches each entry through
      `_entry_check_handler_for`, AND-gates results, and prints
      `proceed` / `skip:<reason>` / `error:<check-name>` on stdout.
      Always exits 0 — caller parses stdout. Empty/null/absent config
      → empty array → `proceed` (back-compat per D-005).
      Snippet (logic skeleton):

      ```bash
      should_dispatch() {
        local stage="$1" issue="$2"
        local checks_json
        checks_json="$(jq -c --arg s "$stage" \
          '.orchestrator.entry_conditions[$s] // []' "$CONFIG" 2>/dev/null || printf '[]')"
        local n; n="$(jq 'length' <<<"$checks_json")"
        (( n == 0 )) && { printf 'proceed\n'; return 0; }
        local i=0
        while (( i < n )); do
          local name handler reason rc=0
          name="$(jq -r ".[$i].name // \"\"" <<<"$checks_json")"
          [[ -z "$name" ]] && { i=$((i+1)); continue; }
          handler="$(_entry_check_handler_for "$name" 2>/dev/null || printf '')"
          if [[ -z "$handler" ]]; then
            log "entry-conditions: unknown check '$name' for stage '$stage'; skipping (fall through)"
            i=$((i+1)); continue
          fi
          reason="$("$handler" "$issue" 2>/dev/null)" || rc=$?
          case "$rc" in
            0) ;;
            1) printf 'skip:%s\n' "$reason"; return 0 ;;
            2) printf 'error:%s\n' "$name"; return 0 ;;
            *) log "entry-conditions: handler '$handler' returned unexpected rc=$rc; treating as error"
               printf 'error:%s\n' "$name"; return 0 ;;
          esac
          i=$((i+1))
        done
        printf 'proceed\n'
      }
      ```

- [ ] Append the standard sentinel block:

      ```bash
      if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
        case "${1:-}" in
          should_dispatch) shift; should_dispatch "$@" ;;
          *) die "usage: entry-conditions.sh should_dispatch <stage> <issue>" ;;
        esac
      fi
      ```

      The sentinel matches the CLAUDE.md "Tests" § contract so
      `bin/entry-conditions-test.sh` can `source` the file for
      function-level access without firing `main`.
- [ ] Verify syntax: `bash -n bin/entry-conditions.sh` exits 0.

### Task 2: Add `_entry_conditions_gate` helper and call site in `bin/run-stage.sh`

- `depends_on: [1]`
- `touches: bin/run-stage.sh (modify — add helper + insert call block in main)`
- [ ] Add helper `_entry_conditions_gate` immediately AFTER
      `_pre_dispatch_merge_gate`'s closing `}` at `bin/run-stage.sh:654`.
      Source-order placement is grep-ability (search "pre_dispatch_"
      finds both gates as siblings). Helper signature: `_entry_conditions_gate
      <ident> <stage>`. Returns 0 = gate did NOT fire (caller proceeds
      to dispatch — note inversion vs `_pre_dispatch_merge_gate`,
      where 0 means "gate fired"). Returns 1 = gate fired skip and
      counter bumped (caller MUST exit 0). Lane attribution
      `local PIPELINE_WRITER=orchestrator; export PIPELINE_WRITER`
      at the top, mirroring `bin/run-stage.sh:618-619` and
      `bin/run-stage.sh:490-491`. Snippet:

      ```bash
      # ENG-86: orchestrator-side entry-condition gate. Runs after
      # _pre_dispatch_merge_gate (handles MERGED) and before
      # render-prompt + dispatch. When the gate fires "skip", bumps the
      # existing ENG-45 wait counter via _handle_wait so external_signal_budget
      # escalation still applies.
      #
      # Returns 0 = gate did NOT fire (caller proceeds to dispatch).
      # Returns 1 = gate fired skip; caller MUST exit 0 (caller handles metric).
      # Fail-open on subprocess failure / unexpected outcome (D-010).
      _entry_conditions_gate() {
        local PIPELINE_WRITER=orchestrator
        export PIPELINE_WRITER

        local ident="$1" stage="$2"
        local outcome
        outcome="$(bash "$SCRIPT_DIR/entry-conditions.sh" should_dispatch \
                    "$stage" "$ident" 2>/dev/null || printf 'error:invocation')"

        case "$outcome" in
          proceed)
            return 0
            ;;
          skip:*)
            local reason="${outcome#skip:}"
            log "entry-conditions: skip ($ident, $stage) — reason=$reason"
            # Reuse _handle_wait so external_signal_budget escalation still
            # applies. Within budget → returns 0; budget exhausted → returns
            # 1 (halt already applied). We exit clean either way; the halt
            # is the durable signal.
            _handle_wait "$ident" "$stage" "$reason" || true
            return 1
            ;;
          error:*)
            local check="${outcome#error:}"
            log "entry-conditions: WARNING — check '$check' errored for $ident/$stage; falling through to dispatch"
            return 0
            ;;
          *)
            log "entry-conditions: unexpected outcome '$outcome'; falling through to dispatch"
            return 0
            ;;
        esac
      }
      ```

- [ ] Insert the gate-firing block in `main()` between
      `bin/run-stage.sh:722` (close of the `_pre_dispatch_merge_gate`
      `if` block, after `exit 0; fi`) and
      `bin/run-stage.sh:726` (`mkdir -p "$(issue_dir "$ident")"`).
      The block emits paired `stage-start` / `stage-end` metric events
      with the new outcome literal `dispatch-skipped` (mirrors the
      `merged-pre-dispatch` pairing at lines 717-720, required so the
      retrospective §1 filter can pair the events). Snippet:

      ```bash
      # ENG-86: pre-dispatch entry-condition gate. If the configured
      # check(s) for this stage are unmet, skip the agent dispatch. The
      # gate bumps the ENG-45 wait counter so external_signal_budget
      # still escalates a stale predicate.
      if ! _entry_conditions_gate "$ident" "$stage"; then
        t1="$(date +%s)"; duration=$(( (t1 - t0) * 1000 ))
        bash "$SCRIPT_DIR/metrics.sh" stage-start "$ident" "$stage" \
          "dispatch-skipped" 0 || true
        bash "$SCRIPT_DIR/metrics.sh" stage-end "$ident" "$stage" \
          "dispatch-skipped" "$duration" || true
        exit 0
      fi
      ```

      Note the `if !` inversion: the helper returns 0 (proceed) on the
      pass-through path, so we negate to enter the exit-block only on
      `return 1` (gate fired skip).
- [ ] Verify syntax: `bash -n bin/run-stage.sh` exits 0.
- [ ] Run `bash bin/secret-probe-lint.sh` to confirm no `${VAR:-…}`
      bash-default introduced (the helper uses `${outcome#skip:}` /
      `${outcome#error:}` which are parameter-substring expansions,
      NOT default-fallback — lint-clean by construction).

### Task 3: Author `bin/entry-conditions-test.sh` with cases A–F

- `depends_on: [1]`
- `touches: bin/entry-conditions-test.sh (new)`
- [ ] Create new test file. Source-and-stub pattern per CLAUDE.md
      "Tests" §, mirroring `bin/run-stage-test.sh:1-115`. Set
      `PIPELINE_DRY_RUN=1`, `LINEAR_API_KEY=test-mock-key`,
      `PROJECT_SLUG=test-slug`, mktemp `STUB_DIR`, `TMP_CFG`,
      `HARNESS_STATE_DIR`. Stub `gh` (toggleable on `MOCK_GH_REVIEWS_JSON`
      and `MOCK_GH_RC`), stub `bin/branch-name.sh` (returns
      `feat/<lower-id>-mock-slug`). Source `bin/common.sh` first so
      `log` / `die` / `$CONFIG` are in scope, then source
      `bin/entry-conditions.sh`. Override `SCRIPT_DIR=$STUB_DIR;
      PATH="$STUB_DIR:$PATH"; CONFIG=$TMP_CFG` post-source.
- [ ] **Case A — condition met → `proceed`.** Set `MOCK_GH_REVIEWS_JSON`
      to one APPROVED non-bot review fixture (`{"reviews":[{"state":"APPROVED","author":{"login":"alice"}}]}`).
      Set `$TMP_CFG` with
      `{"orchestrator":{"entry_conditions":{"building":[{"name":"pr-approved-by-non-bot","type":"github-pr-review"}]}}}`.
      Assert `should_dispatch building ENG-86A` prints `proceed` and
      exit code 0.
- [ ] **Case B — condition unmet → `skip:awaiting-approval`.** Set
      `MOCK_GH_REVIEWS_JSON` to zero APPROVED reviews
      (`{"reviews":[]}` or `{"reviews":[{"state":"COMMENTED","author":{"login":"alice"}}]}`).
      Same config as A. Assert `should_dispatch building ENG-86B`
      prints exactly `skip:awaiting-approval` and exit code 0.
- [ ] **Case C — malformed config (unknown check name) →
      fall-through to `proceed`.** Config:
      `{"orchestrator":{"entry_conditions":{"building":[{"name":"made-up-check","type":"unknown"}]}}}`.
      Assert `should_dispatch building ENG-86C` prints `proceed` (the
      unknown entry is logged via `log` and skipped per D-005).
- [ ] **Case D — empty/absent config → `proceed`.** Config: `{}`.
      Assert `should_dispatch building ENG-86D` prints `proceed`
      (back-compat).
- [ ] **Case E — gh outage (gh nonzero) → `error:pr-approved-by-non-bot`.**
      `MOCK_GH_RC=1` (stub exits nonzero). Same config as A.
      Assert `should_dispatch building ENG-86E` prints
      `error:pr-approved-by-non-bot` (fail-open per D-010).
- [ ] **Case F — unknown stage key (gerund mismatch) → `proceed`.**
      Config has `building` (gerund), test calls
      `should_dispatch build ENG-86F` (non-canonical short form).
      Assert output is `proceed` — documents the silent gerund-drift
      trade-off per D-005.
- [ ] Append `RESULTS: <pass> passed, <fail> failed` summary and
      exit nonzero on failure (matches `bin/run-stage-test.sh`
      end-of-file shape at lines ~1300+).
- [ ] Verify: `bash bin/entry-conditions-test.sh` exits 0 with all 6
      cases PASS.

### Task 4: Extend `bin/run-stage-test.sh` with ENG-86 case G (orchestrator-skip increments wait-building.json)

- `depends_on: [2]`
- `touches: bin/run-stage-test.sh (modify — append ENG-86 cases at end of file)`

**Note for reviewers:** The Linear AC bullet (e) reads as if the
ENG-45-budget-interaction test should land in
`bin/entry-conditions-test.sh`, but the brainstorm §3.5 case G
explicitly reroutes it to `bin/run-stage-test.sh`: the assertion is
on `_handle_wait`'s side effect inside `_entry_conditions_gate`, not
on `bin/entry-conditions.sh` in isolation. The runtime composition
lives in `run-stage.sh`, so the integration test lives in its
sibling. Documenting here so a cold reviewer doesn't grep for case
(e) in `bin/entry-conditions-test.sh` and conclude it's missing.
- [ ] Append at the END of `bin/run-stage-test.sh` immediately BEFORE
      the final `echo` + summary block at line 3446–3448 (i.e.,
      after the last existing case's closing `fi`). Inserting at the
      end avoids perturbing the existing case-ordering and the
      stub-restoration state at lines 1136–1139 (which other cases
      J/J2/J3/K/K2/M depend on). Add a stub
      `bin/entry-conditions.sh` under `STUB_DIR` that emits
      `skip:awaiting-approval` on stdout and exits 0 — this lets
      `_entry_conditions_gate` reach `_handle_wait` deterministically
      without invoking the real `gh` query. Snippet:

      ```bash
      cat > "$STUB_DIR/entry-conditions.sh" <<'SH'
      #!/usr/bin/env bash
      printf 'skip:awaiting-approval\n'
      exit 0
      SH
      chmod +x "$STUB_DIR/entry-conditions.sh"
      ```

- [ ] **Case G — orchestrator-skip increments wait counter via
      `_handle_wait`.** Config (`$ENG_45_TMP_CFG` in the test) holds
      no budget (so `_handle_wait` always returns 0). Pre-clean
      `wait-building.json`. Call `_entry_conditions_gate ENG-86G
      building` three times in a row. Assert `wait-building.json`
      `attempts == 3` after the third call (the same shape as the
      existing ENG-45 case G/H assertion at lines 1041-1059).
- [ ] **Case G2 — orchestrator-skip respects budget exhaust.** Set
      `$ENG_45_TMP_CFG` to
      `{"orchestrator":{"external_signal_budget":{"max_attempts":2}}}`.
      Pre-clean state. Call `_entry_conditions_gate` twice. Assert
      after the 2nd call: (a) `wait-building.json` was deleted, (b)
      capture file shows `add-comment` with
      `external-signal-budget-exhausted` body, (c) capture shows
      `add-label pipeline:halted`. Mirrors ENG-45 case I (lines
      1062-1083) but driven through the orchestrator-skip path.
- [ ] **Case G3 — `proceed` outcome from stub does NOT touch
      `wait-building.json`.** Override the stub to `printf 'proceed\n'`
      and re-run `_entry_conditions_gate`. Assert
      `wait-building.json` does NOT exist after the call (gate did
      not fire skip; `_handle_wait` not invoked).
- [ ] Verify: `bash bin/run-stage-test.sh` exits 0 with all existing
      cases PASS plus the three new ENG-86 cases PASS.

### Task 5: Update `CLAUDE.md` with a `## Orchestrator entry-conditions` docblock

- `depends_on: [2]`
- `touches: CLAUDE.md (modify — add new section after ## Per-stage dispatch timeouts)`
- [ ] Add a new H2 section `## Orchestrator entry-conditions (ENG-86)`
      immediately after `## Per-stage dispatch timeouts (ENG-65)`
      (lines ~299-350). Mirror the prose shape of that section: opening
      paragraph describing what the gate does, JSON config example,
      Validation bullet list (silent fall-through on unknown stage keys,
      `dispatch-skipped` metric outcome literal, fail-open on `gh`
      outage), and a short trade-off paragraph (cost-recovery vs
      Linear-thread silence — operator visibility is via logs +
      events.jsonl, not Linear comments per D-003).
- [ ] Add the recommended config snippet:

      ```json
      {
        "orchestrator": {
          "entry_conditions": {
            "building": [
              {
                "name": "pr-approved-by-non-bot",
                "type": "github-pr-review"
              }
            ]
          }
        }
      }
      ```

- [ ] Add a sentence noting that `.pipeline-config/` is gitignored —
      each operator opts in independently — and the harness-self
      target's adopt-step is "edit the local config and add the
      stanza above". Cross-reference the `## Per-target
      dispatch.tools extras` section (which already documents the
      gitignore + per-operator adopt pattern).
- [ ] Add a one-line note under "Failure-mode quick reference" table
      (after the existing scope-check row): "| Issue at
      stage:building idles forever with `dispatch-skipped` events
      and no halt label | inspect `$PROJECT_STATE_DIR/<ident>/wait-building.json`
      `attempts` field; the gate is firing skip per `gh pr view`. If
      the PR has been approved, check whether `gh` is on PATH for
      launchd's environment (the stale-predicate fail-mode); if not,
      operator approves the PR. |".
- [ ] Verify: rendered file has no broken links, fenced blocks
      balanced (no column-0 ``` inside the new section's body —
      CLAUDE.md is consumed by humans, not `render-prompt.sh`, so
      the AGENT_PROMPTS.md fence rule does NOT bind here, but the
      brainstorm § documentation prefers a single fenced block per
      section regardless).

### Task 6: Verify Q1 (retrospective accepts `dispatch-skipped` outcome) via dry-run

- `depends_on: [2,3,4]`
- `touches: (no file edits — verification step)`
- [ ] After Tasks 1-4 land, write a synthetic `events.jsonl` row with
      `outcome=dispatch-skipped` to a scratch
      `$PROJECT_STATE_DIR/metrics/events.jsonl` and run
      `PIPELINE_DRY_RUN=1 TARGET_REPO=… bash
      bin/run-retrospective-local.sh` (or its dry-run variant if one
      exists). Expected: the synthetic row is present in the
      retrospective's input view (no silent-drop). If the row is
      dropped, the brainstorm Q1 mitigation kicks in: file a
      follow-up ticket — do NOT block this PR. The cost-recovery
      function is unaffected by retrospective-side filtering.
- [ ] Record the verification result in the PR description (or in
      the implement-stage summary) as either "Q1 verified — no drop"
      or "Q1 not verified — follow-up ticket filed: ENG-XXX".

### Task 7: Add the operator runbook step (rollout, not committed code)

- `depends_on: [2,5]`
- `touches: (operator action only — no file edit on the feature branch)`
- [ ] In the implement-stage summary, document the post-merge
      operator action: regenerate `.pipeline-config/config.json`
      locally on the harness operator's host with the
      `entry_conditions.building` stanza per Task 5's snippet AND
      with `bin/entry-conditions-test.sh` enumerated in
      `dispatch.tools.{implementing,qa}` (so the implement and qa
      agents can run the new test under their `bash bin/<name>-test.sh:*`
      allowlist patterns — driven by the assertion at
      `bin/dispatch-test.sh:2140-2168`). The CLAUDE.md regen
      one-liner at lines ~285-292 already covers the test-list
      enumeration; the entry_conditions stanza is a one-time manual
      add. Per CLAUDE.md "## Per-target dispatch.tools extras",
      `.pipeline-config/` is gitignored, so this step does NOT
      become a commit.

## Frontend Tasks

no UI surface (this repo is bash orchestration scripts; the
`project-profile.md` Stack section confirms "Bash 3.2+ orchestration
scripts… The repo contains no application code"; per `dispatch.sh::allowed_tools_for`
case arms, no `ui` stage runs against this target).

## Failure Mode → Test Map

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
| --- | --- | --- | --- | --- |
| Gate proceeds when PR has at least one APPROVED non-bot review | `MOCK_GH_REVIEWS_JSON` returns one `state=APPROVED` non-bot reviewer; config has `pr-approved-by-non-bot` for `building` | `should_dispatch` prints `proceed`; caller dispatches the agent | unit | `bin/entry-conditions-test.sh` Case A |
| Gate skips when PR has zero APPROVED non-bot reviews | `MOCK_GH_REVIEWS_JSON` returns `{"reviews":[]}` or `state=COMMENTED` only | `should_dispatch` prints `skip:awaiting-approval` exactly | unit | `bin/entry-conditions-test.sh` Case B |
| Malformed config (unknown check name) falls through to dispatch (does NOT lock out) | Config has `{name:"made-up-check"}` | Logs unknown-check warning; prints `proceed`; the entry's check is skipped per D-005 | unit | `bin/entry-conditions-test.sh` Case C |
| Empty/absent config → no behavior change (back-compat) | Config: `{}` (no `entry_conditions` key) | Prints `proceed`; identical to today's pre-ENG-86 dispatch path | unit | `bin/entry-conditions-test.sh` Case D |
| `gh` outage / nonzero exit → fail-open (does NOT lock out, per D-010) | Stub `gh` exits nonzero | Prints `error:pr-approved-by-non-bot`; caller proceeds to dispatch | unit | `bin/entry-conditions-test.sh` Case E |
| Unknown stage key (gerund mismatch — `build` vs `building`) silently falls through | Config keyed by `building`; caller asks `should_dispatch build …` | Prints `proceed` (jq `// []` returns empty array; D-005 documented trade-off) | unit | `bin/entry-conditions-test.sh` Case F |
| Orchestrator-skip path increments the same `wait-${stage}.json` counter the agent-side wait path uses (ENG-45 budget integration) | Stub `entry-conditions.sh` returns `skip:awaiting-approval`; `_entry_conditions_gate` invoked 3 times with no budget | `wait-building.json` has `attempts == 3`; no halt label applied | integration | `bin/run-stage-test.sh` ENG-86 Case G |
| Orchestrator-skip respects ENG-45 `external_signal_budget.max_attempts` exhaust | Same stub; budget config `max_attempts=2`; invoked 2 times | After 2nd call: `wait-building.json` deleted, `add-comment` with `external-signal-budget-exhausted` body, `add-label pipeline:halted` posted | integration | `bin/run-stage-test.sh` ENG-86 Case G2 |
| `proceed` outcome from the registry does NOT touch the wait counter | Stub returns `proceed` | `wait-building.json` does NOT exist after the call; `_handle_wait` never invoked | integration | `bin/run-stage-test.sh` ENG-86 Case G3 |
| New script ends with the `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]` sentinel so tests can `source` it | `bin/entry-conditions-test.sh` sources `bin/entry-conditions.sh` and calls `should_dispatch` directly without the file's main running | All 6 cases A-F PASS — implicitly verifies the sentinel works (test would `die` on usage error if `main` fired) | unit | covered by Cases A-F |
| `dispatch-skipped` metric event has paired `stage-start`/`stage-end` (so retrospective §1 pairing pass does not see an orphaned terminal event) | Run `bin/run-stage.sh` against a stub that triggers gate-skip; inspect `events.jsonl` | Two events with same `issue_id`/`stage` and `outcome=dispatch-skipped`; identical to the `merged-pre-dispatch` pairing at `bin/run-stage.sh:717-720` | smoke | `bin/run-stage-test.sh` ENG-86 Case G2 (asserts capture for halt comment + label; the metric pairing is implicit in the gate-firing block at Task 2) |

## Test Strategy

- **Unit (case A–F in `bin/entry-conditions-test.sh`).** Lock the
  registry contract in isolation — no `_handle_wait` involvement, no
  `run-stage.sh` integration. Each case manipulates fixture state
  (`MOCK_GH_REVIEWS_JSON`, `$TMP_CFG`) and asserts on
  `should_dispatch` stdout. Verifies the brainstorm's three
  fail-open paths (D-010): unknown check name (C), empty config (D),
  gh outage (E), and the silent-stage-drift trade-off (F).
- **Integration (case G/G2/G3 in `bin/run-stage-test.sh`).** Lock the
  budget integration: orchestrator-skip increments the same wait
  counter the agent-side wait path uses. Reuses the existing ENG-45
  stub fixtures (config file, capture file, linear stub, gh stub) so
  no new fixture infrastructure is needed. Drives
  `_entry_conditions_gate` directly via post-source function call,
  with a stub `bin/entry-conditions.sh` under `STUB_DIR` so the
  gate's outcome is deterministic without standing up a real `gh`
  session.
- **Smoke (paired metric events).** The metric pairing is asserted
  implicitly: case G2 of `run-stage-test.sh` exercises the
  gate-firing path through `_handle_wait`'s exhaust escalation; the
  retrospective Q1 dry-run (Task 6) verifies the new outcome literal
  `dispatch-skipped` is not silently filtered. No dedicated smoke
  test added — the brainstorm's Q1 marks this as a verification
  step, not a new permanent test.
- **Adversarial (silent-stage-drift, malformed JSON, race).** Case F
  pins the gerund-mismatch silent-drift trade-off (it is a
  brainstorm-documented decision, not a bug). Malformed reviews JSON
  is covered indirectly by case E (any `gh`/`jq` failure becomes
  `error:` → fall-through). The PR-approval-revoked-mid-tick race
  is documented in §5 of the brainstorm and covered by the agent's
  P2 (unchanged) — no orchestrator-side test needed because the
  agent IS the post-gate fallback.
- **Regression — existing test suite passes.**
  `bash bin/dispatch-test.sh` (validates the harness-self
  `dispatch.tools.{implementing,qa}` enumeration covers the new
  `bin/entry-conditions-test.sh` — operator-side step, but the
  test SKIPs cleanly when `.pipeline-config/config.json` is absent),
  `bash bin/run-stage-test.sh`, `bash bin/poll-slot-test.sh`,
  `bash bin/scope-check-test.sh`, `bash bin/verdict-handler-test.sh`,
  `bash bin/classify-failure-test.sh`, `bash bin/halt-sprawl-test.sh`,
  `bash bin/halt-sprawl-adversarial-test.sh`, `bash bin/linear-test.sh`,
  `bash bin/metrics-test.sh`, `bash bin/mutex-test.sh`,
  `bash bin/setup-helpers-test.sh`, `bash bin/render-prompt-test.sh`,
  `bash bin/phase-project-profile-test.sh`, `bash bin/common-test.sh`,
  `bash -n bin/*.sh`, `bash bin/secret-probe-lint.sh` all exit 0
  unchanged from main.

## Persona review verdicts

The five required personas were dispatched in parallel after the draft
was written; each verified its lens against the current worktree and
the brainstorm.

- **Feasibility (PASS).** Every cited path:line was re-verified
  against the current worktree. Insertion-point boundaries
  (`bin/run-stage.sh:710-722` AFTER, `bin/run-stage.sh:726` BEFORE)
  are correct. `_handle_wait` signature at `bin/run-stage.sh:489-578`
  is exactly as quoted; return semantics (0 within budget, 1
  exhausted) match. `_pre_dispatch_merge_gate` precedent at
  `bin/run-stage.sh:613-654` (including the `local
  PIPELINE_WRITER=orchestrator` lane attribution at lines 618-619)
  is the template the new helper follows. ENG-65 validation pattern
  template (`bin/dispatch.sh:388-403`) is the jq-shape template for
  the new config read. Building stage's allowed-tools at
  `bin/dispatch.sh:328` already carries `gh pr view`/`gh pr list`
  (no allowlist change). `bin/branch-name.sh:31` derivation pattern
  re-verified. `bin/metrics.sh:19-75` accepts arbitrary outcome
  strings. `bin/run-stage-test.sh:1-115` source-and-stub fixtures
  are extendable. Q1 (retrospective filter) is the only assumed
  item; Task 6 verifies it during implementation. `depends_on`
  chains: Task 2 needs Task 1 (the new script must exist before
  `_entry_conditions_gate` calls it); Task 3 needs Task 1 (test
  needs the script); Task 4 needs Task 2 (extends run-stage tests
  using the new helper); Tasks 5–7 land after the code does. Each
  Failure Mode row names a specific test layer and a specific test
  name (or explicitly states "covered by Cases A-F"). No hidden
  coupling.
- **Scope (PASS).** Every File Structure entry traces to a brainstorm
  decision: `bin/entry-conditions.sh` (D-004),
  `bin/entry-conditions-test.sh` (§3.5),
  `bin/run-stage.sh` modifications (D-001, §3.2, §3.3),
  `bin/run-stage-test.sh` extension (§3.5 Case G),
  `CLAUDE.md` documentation (D-005, §3.1). Tasks `touches`
  lists stay within these files. The brainstorm's D-009
  non-changes are honored: no edit to `bin/run-local.sh`,
  `bin/poll.sh`, `bin/dispatch.sh`, `bin/verdict-handler.sh`,
  `bin/classify-failure.sh`, `bin/linear.sh`, `bin/metrics.sh`,
  `bin/pipeline-events.json`, or `AGENT_PROMPTS.md`. The Linear
  issue's "in run-local.sh" pseudocode-deviation is flagged in
  the Anti-anchoring section (matches §9 of the brainstorm). The
  pre-existing `external-signal-budget-exhausted` registry-gap
  carried over from ENG-62 §9 is logged out-of-scope. No
  gold-plating: mini-DSL rejected per D-004 / Out-of-scope;
  shared jq-fragment refactor rejected per D-008.
- **Coherence (PASS).** Goal matches brainstorm §0 / §1 (cost
  recovery via cheap pre-dispatch gate). Backend Tasks 1-2
  jointly realise §3.2 + §3.4 (the helper + the registry).
  Tasks 3-4 cover the Failure Mode → Test Map exhaustively
  (every row binds to a named test). Test Strategy enumerates
  unit/integration/smoke/adversarial coverage matching the
  brainstorm's §3.5 cases A-G + Q1 verification. The "no API
  surface" / "no UI" disclaimers match the project profile's
  Stack section. The deviation from the AC's "in run-local.sh"
  text is structurally justified and explicitly flagged
  (matches §9 of the brainstorm). The §6 multiple-checks-AND'd
  semantics is realized by the `should_dispatch` skeleton's
  short-circuit-on-rc=1 logic.
- **Design (PASS).** No layering violations: `_entry_conditions_gate`
  lives in `run-stage.sh` (orchestrator stage executor) and calls
  out to `bin/entry-conditions.sh` (pure registry), which is
  consistent with the existing pattern of `bin/scope-check.sh`,
  `bin/review-poll.sh`, and `bin/branch-name.sh` (single-purpose
  scripts the orchestrator scripts shell out to). No circular deps:
  `entry-conditions.sh` sources only `common.sh`; it does not
  source `run-stage.sh`. Lane attribution (`PIPELINE_WRITER=orchestrator`)
  is enforced explicitly in the helper, mirroring
  `_pre_dispatch_merge_gate:618-619` and `_handle_wait:490-491`.
  The fail-open default (D-010) is consistent with ENG-62 D-006.
  No new label, no new marker shape, no new pipeline-events.json
  entry — closed-vocabulary discipline preserved.
- **Product (PASS).** The plan delivers the Linear issue's stated
  goal: orchestrator-side cheap predicate replaces full agent
  dispatch on awaiting-approval issues, reclaiming ~2 min wall-clock
  + ~$0.5–0.7 per skipped tick. The K=2 (ENG-81) interaction is
  preserved: skipped issues no longer occupy the host's
  claude-mutex during the dispatch window. The Linear issue's
  Risks-1 mitigation (ENG-45 budget integration) is implemented in
  Task 2 / Task 4 (Cases G, G2). Operator-facing surface is
  unchanged in the happy case (no new label, no new marker, no
  new sig); visible only as a new metric outcome
  (`dispatch-skipped`) when it fires. Q1 verification (Task 6)
  guards against silent retrospective-filter drop. The plan's
  language tracks the issue's vocabulary ("entry condition", "skip
  vs vacate", "ENG-45 budget"). The structural deviation from
  "in run-local.sh" to "in run-stage.sh" is flagged explicitly
  for human review attention with the brainstorm's three-line
  justification.

**Final tally: 5/5 PASS, gate P0 = 0. Proceeding to implementing.**
