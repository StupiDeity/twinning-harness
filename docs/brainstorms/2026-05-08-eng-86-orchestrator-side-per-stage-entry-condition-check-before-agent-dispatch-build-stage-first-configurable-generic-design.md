---
linear: ENG-86
title: Orchestrator-side per-stage entry-condition check before agent dispatch
date: 2026-05-08
status: draft
---

# ENG-86 — Orchestrator-side per-stage entry-condition check before agent dispatch (build first; configurable, generic)

## 1. Problem

When a `stage:building` issue has emitted `<!-- pipeline: verdict
result=wait reason=awaiting-approval -->` on a prior tick, every
subsequent 5-min tick re-dispatches the build agent end-to-end so it can
re-run preflight P0–P7 (`AGENT_PROMPTS.md:1262-1369`) and re-emit the
SAME wait verdict. The agent dispatch costs ≈ \$0.5–0.7 per cycle and
~2 min wall-clock on the host. After ENG-81 lands K=2 parallel
dispatch, two awaiting-approval issues can occupy both slots and starve
all other ready issues of the host's claude-mutex. The wall-clock burn
is the primary cost.

The orchestrator already has a precedent for short-circuiting build:
ENG-62's `_pre_dispatch_merge_gate` (`bin/run-stage.sh:613-654`) — when
the PR is `MERGED`, it transitions `building → released` directly
without invoking the agent. That gate covers the *post-merge* case.
ENG-86 adds the symmetric *pre-merge* gate: if the PR isn't approved
yet, skip the dispatch and bump the existing ENG-45 wait counter.

Today's flow for a wait-looping building issue:

```
poll.sh: stage:building, no halt, fresh wait verdict (invisible to
       find_fresh_verdict per verdict-handler.sh:113)
     → _poll_classify_labels else branch (poll.sh:280) → hold, advanceable=true
run-stage.sh::main
     → verify_preconditions (ok)
     → _pre_dispatch_merge_gate (PR is OPEN, not MERGED) → return 1, fall through
     → render-prompt.sh + dispatch.sh (~2 min, ~$0.5–0.7)
     → agent re-emits verdict wait reason=awaiting-approval
     → _fresh_wait_reason matches → _handle_wait bumps wait-building.json counter
     → exit 0
next tick: same triple → repeat ad infinitum, until:
     - external_signal_budget exhausts → halt (run-stage.sh:560-575)
     - operator approves PR → next tick's agent run hits P2 pass → merge
     - on-new-release.sh sweep flips stage:building → stage:released
```

We can replace the dispatch in this loop with a single `gh pr view
... --json reviews` call (~100 ms) for the same effective accounting.

### 1.1 Why the issue's "in `run-local.sh`" placement is structurally wrong

The Linear issue suggests inserting the gate "in
`bin/run-local.sh::main` after `poll.sh` returns a decision and before
`dispatch.sh`." But `bin/run-local.sh` does not call `dispatch.sh` —
it calls `bin/run-stage.sh::main` (`bin/run-local.sh:257`), which in
turn calls `dispatch.sh` (`bin/run-stage.sh:744`). The architectural
pattern for pre-dispatch gates is established by ENG-62: helpers
declared in `run-stage.sh`, invoked from `run-stage.sh::main` after
`verify_preconditions` and before `render-prompt.sh`/`dispatch.sh`.
This brainstorm preserves that pattern (D-001) and treats the Linear
issue's pseudocode as intent-correct, file-location-incorrect.

## 2. Decisions

- **D-001. Add `_entry_conditions_gate` helper in `bin/run-stage.sh`,
  invoked from `main()` immediately after `_pre_dispatch_merge_gate`.**
  The gate consults a small, single-purpose script
  (`bin/entry-conditions.sh`) that returns one of three outcomes:

  | Outcome | Caller behavior |
  | --- | --- |
  | `proceed` | Fall through to `render-prompt.sh` + `dispatch.sh` (today's path) |
  | `skip:<reason>` | Bump wait counter via `_handle_wait`, emit metric, exit 0 |
  | `error` | Log warning; fall through to dispatch (fail-open per ENG-62 D-006) |

  *Why `run-stage.sh`, not `run-local.sh`.* The architectural precedent
  (`_pre_dispatch_merge_gate` at `bin/run-stage.sh:613-654`, invoked
  from `run-stage.sh:710`) places pre-dispatch gates inside
  `run-stage.sh::main`. `_handle_wait` lives in the same file
  (`bin/run-stage.sh:489-578`) and is in scope without re-sourcing.
  Putting the new gate elsewhere would (a) double-source `_handle_wait`
  or duplicate its budget logic, and (b) split the pre-dispatch
  short-circuit family across files. Run-local.sh's pre-`run-stage.sh`
  setup (worktree resolution at `bin/run-local.sh:229-233`, snapshot
  at `bin/run-local.sh:249-254`) is cheap in steady state — the
  worktree exists, snapshot is one `git status` — so the marginal
  cost of running it before the gate is ~100ms vs the ~2 min agent
  dispatch we're avoiding. Acceptable.

  Rejected alternative (insert in `run-local.sh::main` per Linear issue
  pseudocode). Rejected because (a) `dispatch.sh` is not called from
  `run-local.sh`, (b) `_handle_wait` is not in scope without
  re-sourcing or duplicating, (c) ENG-62's analogous gate establishes
  the run-stage.sh placement.

  Rejected alternative (gate inside `bin/poll.sh`, similar to
  `review_should_dispatch` at `bin/review-poll.sh:29-53`). Rejected:
  poll.sh is a hot loop evaluated for every issue every tick; adding
  a `gh pr view` call per `stage:building` issue per tick widens
  per-tick latency and blast radius. The run-stage.sh gate runs only
  when an issue is actually about to be dispatched. (Same trade-off
  ENG-62 §8.2-C documents.)

- **D-002. Skip path reuses `_handle_wait` for budget accounting; no
  new counter file.** When the gate skips, it calls
  `_handle_wait "$ident" "$stage" "$reason"` (`bin/run-stage.sh:489`).
  The reason string is mapped from the unmet check: e.g.,
  `pr-approved-by-non-bot` unmet → `awaiting-approval`. `_handle_wait`:
  - reads `wait-${stage}.json` and increments `attempts`;
  - on budget exhaust (`max_attempts` or `max_minutes` from
    `orchestrator.external_signal_budget`,
    `bin/run-stage.sh:543-544`), posts a halt comment and applies
    `pipeline:halted`, returning 1;
  - otherwise returns 0 (within budget).

  *Why integrate, not introduce a new counter.* The Linear issue's
  Risks section explicitly calls for it: "**Stale predicate:** a
  buggy check could permanently skip dispatch. Mitigation: ENG-45
  `external_signal_budget` still applies — after N skipped attempts,
  force a dispatch (or halt) to surface the stale predicate. Need to
  integrate with the existing budget counter." A separate counter
  would silently double the effective budget when both
  agent-emitted-wait and orchestrator-skip increments fire on
  alternating ticks (e.g., during the migration window where some
  issues already have a fresh wait verdict).

  Rejected alternative (separate `entry-skip-${stage}.json` counter).
  Rejected: violates the integration requirement; introduces a
  second budget primitive operators must understand and reset; the
  ENG-58 atomic-resume contract (`bash bin/pipeline.sh decide
  --action continue`) would need to learn about the new file.

  Rejected alternative (no counter integration; orchestrator skips
  forever until predicate flips). Rejected: a buggy check (e.g., a
  GitHub schema change that silently empties `.reviews[]`) would
  permanently park the issue with no escalation. Loses the Risks-1
  safety net.

- **D-003. Skip path does NOT post a Linear comment; does NOT post a
  verdict marker.** Today's agent emits both
  `<!-- pipeline: verdict result=wait reason=awaiting-approval -->`
  AND a per-tick informational `awaiting-external/build/<id>` comment
  (`AGENT_PROMPTS.md:1296-1315`). The skip path emits neither.
  Operator visibility is via:
  - the orchestrator log line (`bin/run-local.sh:42`'s `LOG_FILE`);
  - the `dispatch_skipped` metric event in `events.jsonl`;
  - the Linear issue stays at `stage:building` with no halt label
    (visible in any standard issue listing).

  *Why no verdict marker.* Lane discipline: verdict markers are
  agent-emitted (the lane fence at `bin/linear.sh::_lane_decision`
  permits the orchestrator to add other_comment but the verdict
  vocabulary is owned by agents — see ENG-41 / ENG-60). The
  orchestrator-skip event is structurally different from an agent
  wait verdict ("we ran the check pre-dispatch, didn't run the
  agent at all"); reusing the verdict shape would conflate two
  events. `find_fresh_verdict` walks the comment history and would
  start to see orchestrator-emitted "fake" verdicts on top of
  legitimate agent-emitted ones.

  *Why no informational comment.* Linear has no comment-delete
  mechanism; an append-only informational comment per skipped tick
  would generate one comment per 5-min tick during long approval
  waits — the exact spam pattern ENG-45's append-only-vs-edit
  decision (D-002 in `2026-04-28-build-agent-soft-preconditions-…`)
  was already a tradeoff for. Saving wall-clock cost only to spend
  it on Linear-thread litter is a net loss.

  Rejected alternative (post `<!-- meta: metric name=dispatch_skipped
  reason=awaiting-approval -->` once per skipped tick). Rejected:
  same Linear-thread-litter issue; the metrics events.jsonl row is
  the durable record.

  Rejected alternative (post a single dedup-keyed
  `dispatch-skip/<issue>` comment via `add-or-update-comment` and
  edit it on each skip). Rejected: `add-or-update-comment` preserves
  `createdAt` (`bin/linear.sh::add_or_update_comment` uses the
  `commentUpdate` mutation), which interacts badly with future
  freshness queries — the same trap ENG-45 D-002 already documents
  (the wait-marker uses `add-comment` specifically to avoid this).

- **D-004. New file `bin/entry-conditions.sh` with a small
  pluggable check registry.** Single CLI verb (`should_dispatch`)
  + per-check functions. Initial registry holds one check:
  `pr-approved-by-non-bot` (mirrors P2). Schema:

  ```bash
  # bin/entry-conditions.sh
  set -euo pipefail
  source "$SCRIPT_DIR/common.sh"

  # Check function contract: input = issue id; output = nothing on
  # success, "<reason>" on stdout when the check is unmet, error
  # message on stderr on tooling outage. Exit codes: 0 = met,
  # 1 = unmet, 2 = error (caller falls through to dispatch).
  check_pr_approved_by_non_bot() {
    local issue="$1"
    command -v gh >/dev/null 2>&1 || return 2
    local branch
    branch="$(bash "$SCRIPT_DIR/branch-name.sh" "$issue" 2>/dev/null || printf '')"
    [[ -n "$branch" ]] || return 2
    # gh pr view <branch> --json reviews — same query shape as
    # AGENT_PROMPTS.md §7 P2 (lines 1287-1289). Symmetry is
    # load-bearing per the issue's "Result coupling" risk.
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

  # Map check name → handler function name.
  _entry_check_handler_for() {
    case "$1" in
      pr-approved-by-non-bot) printf 'check_pr_approved_by_non_bot' ;;
      *) return 1 ;;  # unknown check name
    esac
  }

  # Public CLI: should_dispatch <stage> <issue>
  # stdout: 'proceed' | 'skip:<reason>' | 'error:<message>'
  # exit 0 always (caller parses stdout)
  should_dispatch() {
    local stage="$1" issue="$2"
    local checks_json
    checks_json="$(jq -c --arg s "$stage" \
      '.orchestrator.entry_conditions[$s] // []' "$CONFIG" 2>/dev/null || printf '[]')"
    # Empty / null / absent → no checks → proceed (back-compat).
    local n
    n="$(jq 'length' <<<"$checks_json")"
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
        0) ;;  # met; continue to next check
        1) printf 'skip:%s\n' "$reason"; return 0 ;;
        2) printf 'error:%s\n' "$name"; return 0 ;;
        *) log "entry-conditions: handler '$handler' returned unexpected rc=$rc; treating as error"
           printf 'error:%s\n' "$name"; return 0 ;;
      esac
      i=$((i+1))
    done
    printf 'proceed\n'
  }

  if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
      should_dispatch) shift; should_dispatch "$@" ;;
      *) die "usage: entry-conditions.sh should_dispatch <stage> <issue>" ;;
    esac
  fi
  ```

  *Why a separate file, not inline in `run-stage.sh`.* `run-stage.sh`
  is already the largest file in `bin/` (~1100 LOC); inlining adds
  ~80 LOC of check registry plus per-check handlers (we'd need one
  per future check). A separate file matches the precedent of
  `bin/review-poll.sh` (`review_should_dispatch`, ~70 LOC, sourced
  from `poll.sh:272`) and `bin/scope-check.sh`. The CLI verb form
  also lets operators sanity-check the gate manually:
  `bash bin/entry-conditions.sh should_dispatch building ENG-N`.

  *Why bash function dispatch, not a "check object" abstraction.*
  Phase 1 ships ONE check; an abstraction is not yet justified.
  Future checks add a `check_*` function and a case arm in
  `_entry_check_handler_for`. If/when the registry grows past ~5
  checks, refactor to a table-driven shape — same pace as
  `STAGE_TO_SECTION` in `bin/render-prompt.sh:13-23` and
  `STAGE_LABEL_TO_STAGE_ARG` in `bin/poll.sh:25-33`.

  Rejected alternative (mini-DSL for check predicates). Out of
  scope per the Linear issue's "Out of scope" list.

  Rejected alternative (each check is a separate executable, e.g.,
  `bin/entry-conditions/pr-approved-by-non-bot.sh`). Rejected for
  Phase 1: per-file overhead (one mktemp per fork, one bash startup
  per check) for one check is unjustified. If the registry grows
  beyond a handful, revisit.

- **D-005. Configuration schema:
  `orchestrator.entry_conditions.<stage>[]`. Stage keys must match
  canonical gerunds; unknown stage keys silently fall through to
  "always dispatch".** Mirrors `orchestrator.dispatch_timeout_minutes_per_stage`
  (`bin/dispatch.sh:391`) — the ENG-65 precedent the Linear issue
  explicitly cites. Each entry is `{name: <check-name>, type:
  <type>}`. The `type` field is documented but not yet consulted by
  the registry (single built-in `name` is sufficient for Phase 1);
  it's there so a future implementation can dispatch by type
  ("github-pr-review" → call check_pr_approved_by_non_bot) without
  a config schema break.

  Initial recommended config:

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

  *Why opt-in (config-driven), not on-by-default.* Per the Linear
  issue's "Acceptance" section: "absent / empty / unknown-stage
  config falls through to 'always dispatch' (back-compat)." A
  shipping operator without the config sees no behavior change.
  This matches ENG-65 dispatch_timeout_minutes_per_stage's opt-in
  shape.

  *Why stage-keyed (gerund), not check-keyed.* Allows multiple
  checks per stage (AND-gating per the Linear issue) and trivial
  Phase 2 expansion to other stages without schema migration.
  Gerund canonicalization matches the existing
  `dispatch.sh::allowed_tools_for` case arms (gerund-named per
  `bin/dispatch.sh:320-330`) and the
  `dispatch_timeout_minutes_per_stage` precedent. Drift is caught
  silently — ENG-65's documented trade-off, repeated here for
  consistency.

  Rejected alternative (boolean per stage, e.g.,
  `orchestrator.entry_conditions.building.pr_approval = true`).
  Rejected because it doesn't admit multiple checks per stage and
  doesn't carry a check-name for the metric / log line.

- **D-006. Skip-path metric: `dispatch_skipped` event emitted via
  `bin/metrics.sh`.** Notes field: `check=<name> reason=<reason>
  attempts=<N>`. Mirrors the existing
  `metrics.sh stage-end <issue> <stage> <outcome> <duration_ms>
  <notes...>` shape (`bin/metrics.sh:19-75`). Use a new outcome
  literal `dispatch-skipped` to distinguish from existing outcomes
  (`success`, `halt-for-human`, `merged-pre-dispatch`,
  `soft-pending`, etc.).

  *Why a new event/outcome literal.* Per ENG-62 §7-Q1, the
  retrospective's §1 filter operates on outcome strings; a new
  literal is the standard way to surface a new event type.

  *Why not reuse `soft-pending` (the wait-success outcome at
  `bin/run-stage.sh:957`).* Different semantics: `soft-pending`
  means "agent ran and emitted a wait verdict"; `dispatch-skipped`
  means "agent did not run". Conflating would corrupt the
  retrospective's per-stage cost-aggregation (the wait path
  carries cost-flag attributions; the skip path carries zero
  cost). Same precedent as `merged-pre-dispatch` getting its own
  literal in ENG-62 D-001.

- **D-007. Order of pre-dispatch gates: `_pre_dispatch_merge_gate`
  first, then `_entry_conditions_gate`.** Both query `gh pr ...`;
  if the PR is MERGED the merge gate fires and we never call the
  entry-condition check (saves one query). If MERGED, P2 is
  trivially satisfied anyway (a merged PR is approved); checking
  the reviews array would just produce a redundant `proceed`.

- **D-008. Coupling between agent-side P2 and orchestrator-side
  check is documented, not refactored into a shared snippet.**
  The Linear issue's Risks section names this and proposes
  factoring the jq filter into a shared snippet referenced from
  both. For Phase 1 (single check), factoring is over-engineering.
  Mitigation: a comment in `check_pr_approved_by_non_bot` cites
  `AGENT_PROMPTS.md` §7 P2 (lines 1287-1289) as the source of
  truth; if either side evolves, the comment + a regression test
  surface drift.

  Rejected alternative (extract jq filter to `bin/jq-fragments/`).
  Rejected: introduces a new directory and a new sourcing
  primitive for a single shared string. Defer until at least two
  checks share a non-trivial filter.

- **D-009. Explicit non-changes (scope discipline).**
  - `bin/run-local.sh`: unchanged. The Linear issue's pseudocode
    proposed it; D-001 corrects this.
  - `bin/dispatch.sh::allowed_tools_for`: unchanged. The
    orchestrator runs `gh pr view` directly; the agent's tool
    allowlist is unrelated.
  - `bin/poll.sh::_poll_classify_labels`: unchanged. The else
    branch (`bin/poll.sh:280`) still returns `advanceable=true` —
    the trigger that causes `run-stage.sh` to fire and the gate
    to run.
  - `_fresh_wait_reason` / `_handle_wait`: signatures and
    semantics unchanged. New caller adds, no rewriting.
  - `bin/verdict-handler.sh::find_fresh_verdict`: unchanged.
    Wait-shape exclusion (`bin/verdict-handler.sh:113`) still
    holds.
  - `AGENT_PROMPTS.md` §7 P2: agent-side check unchanged. The
    agent still runs P2 if it gets dispatched (e.g., an
    operator who hasn't applied the config opts out, or an
    error-fallthrough during a `gh` outage).
  - `bin/pipeline-events.json` registry: unchanged. The skip
    event is a metric, not a verdict / halt / transition; no
    new vocabulary entry.
  - `bin/entry-conditions.sh` does NOT post Linear comments,
    apply labels, or transition stages. Read-only on Linear /
    GitHub state. (The skip path's `_handle_wait` invocation
    does post + label only on budget exhaust, which is the
    existing ENG-45 behaviour.)
  - Other stages (review, qa, planning, etc.): no entry-conditions
    config in the initial population. Phase 2 follow-ups can
    opt in. Unconfigured = "always dispatch" (back-compat).

- **D-010. Failure mode is fail-open, mirroring ENG-62 D-006.**
  Any error path (gh outage, branch derivation failure, malformed
  config, unknown check name, handler returning unexpected rc)
  falls through to dispatch. Cost regression returns until the
  fault clears, but the issue cannot be silently parked.

  *Why fail-open.* A fail-closed gate would silently halt every
  building issue during a GitHub-API outage; the cost regression
  is observable and recoverable, a halted issue is not.
  Dispatch-on-error is the safer default for an availability-vs-
  silent-halt tradeoff.

## 3. Architecture

### 3.1 Files modified

| File | Change |
| --- | --- |
| `bin/entry-conditions.sh` | NEW. ~80 LOC. `should_dispatch` CLI verb + `check_pr_approved_by_non_bot` + `_entry_check_handler_for` registry. |
| `bin/run-stage.sh` | New helper `_entry_conditions_gate` (§3.2). |
| `bin/run-stage.sh` | Insert gate-firing block in `main()` between `_pre_dispatch_merge_gate` (`bin/run-stage.sh:710-722`) and the prompt-rendering block at `bin/run-stage.sh:728-737`. |
| `bin/entry-conditions-test.sh` | NEW. Cases A–E from §3.5. |
| `.pipeline-config/config.json` (operator-applied, not committed) | Add `orchestrator.entry_conditions.building` per D-005 example. Documented in CLAUDE.md. |
| `CLAUDE.md` | Add a short subsection under "Per-target dispatch.tools extras" documenting the new `orchestrator.entry_conditions` config key (parallel to the existing `dispatch_timeout_minutes_per_stage` doc block). |

No changes required to `bin/run-local.sh`, `bin/poll.sh`,
`bin/dispatch.sh`, `bin/verdict-handler.sh`, `bin/classify-failure.sh`,
`bin/linear.sh`, `bin/pipeline-events.json`, `AGENT_PROMPTS.md`. The
fix is additive: one new script, one new helper in `run-stage.sh`,
one config-key surface, and one regression test.

### 3.2 Helper sketch — `_entry_conditions_gate` (in `bin/run-stage.sh`)

```bash
# ENG-86: orchestrator-side entry-condition gate. Runs after
# _pre_dispatch_merge_gate (which handles MERGED) and before
# render-prompt + dispatch.sh. When the gate fires "skip", bumps the
# existing ENG-45 wait counter via _handle_wait so external_signal_budget
# escalation still applies.
#
# Returns 0 = gate did not fire (caller proceeds to dispatch).
# Returns 1 = gate fired skip and counter bumped (caller MUST exit 0).
# Fail-open on error (D-010): logs warning, returns 0.
#
# Note: confusingly, "return 0" here means PROCEED (mirrors
# _pre_dispatch_merge_gate's return semantics: 0 = gate consumed control).
# The actual outcome is encoded by the caller's exit-after-return-1.
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
      bash "$SCRIPT_DIR/metrics.sh" stage-end "$ident" "$stage" \
        "dispatch-skipped" 0 "reason=$reason check_outcome=skip" \
        || log "metrics.sh emission failed (non-blocking)"
      # Reuse _handle_wait so external_signal_budget escalation still
      # applies. Within budget → returns 0 → we exit clean. Budget
      # exhausted → _handle_wait posts halt + applies label, returns 1
      # → we still exit clean (the halt is the durable record).
      _handle_wait "$ident" "$stage" "$reason" || true
      return 1
      ;;
    error:*)
      local check="${outcome#error:}"
      log "entry-conditions: WARNING — check '$check' errored for $ident/$stage; falling through to dispatch"
      bash "$SCRIPT_DIR/metrics.sh" stage-end "$ident" "$stage" \
        "dispatch-skipped" 0 "outcome=error check=$check fallthrough=true" \
        || log "metrics.sh emission failed (non-blocking)"
      return 0
      ;;
    *)
      log "entry-conditions: unexpected outcome '$outcome'; falling through to dispatch"
      return 0
      ;;
  esac
}
```

### 3.3 Insertion point in `run-stage.sh::main`

Structural anchors:

- AFTER: the `_pre_dispatch_merge_gate` block at
  `bin/run-stage.sh:705-722`.
- BEFORE: `mkdir -p "$(issue_dir "$ident")"` at
  `bin/run-stage.sh:726` and the prompt-rendering block beginning at
  `bin/run-stage.sh:728`.

The block:

```bash
# ENG-86: pre-dispatch entry-condition gate. If the configured check(s)
# for this stage are unmet, skip the agent dispatch. Bumps the ENG-45
# wait counter so external_signal_budget still escalates.
if _entry_conditions_gate "$ident" "$stage"; then
  : # gate did not fire (or errored fail-open); proceed to dispatch.
else
  t1="$(date +%s)"; duration=$(( (t1 - t0) * 1000 ))
  bash "$SCRIPT_DIR/metrics.sh" stage-start "$ident" "$stage" \
    "dispatch-skipped" 0 || true
  bash "$SCRIPT_DIR/metrics.sh" stage-end "$ident" "$stage" \
    "dispatch-skipped" "$duration" "duration_total_ms=$duration" || true
  exit 0
fi
```

(The metrics.sh stage-start/stage-end pairing matches the ENG-62
gate's pairing at `bin/run-stage.sh:717-721` — required so the
retrospective §1 filter can pair the events.)

### 3.4 New file — `bin/entry-conditions.sh`

See full sketch under D-004 above. Sentinel pattern at end:

```bash
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    should_dispatch) shift; should_dispatch "$@" ;;
    *) die "usage: entry-conditions.sh should_dispatch <stage> <issue>" ;;
  esac
fi
```

The sentinel matches CLAUDE.md's "Tests" section requirement so
`bin/entry-conditions-test.sh` can `source` the file to access
`check_pr_approved_by_non_bot` and `should_dispatch` without
firing `main`.

### 3.5 Test cases (`bin/entry-conditions-test.sh`)

Source-and-stub pattern (CLAUDE.md "Tests" §). Stubs: `gh`,
`bin/branch-name.sh`, `bin/linear.sh`, `bin/metrics.sh`. Post-source
override of `SCRIPT_DIR`, `CONFIG`. `PIPELINE_DRY_RUN=1`,
`LINEAR_API_KEY=test-mock-key`.

| Case | Setup | Assertion |
| --- | --- | --- |
| **A. Condition met → proceed.** | `gh pr view --json reviews` stub returns one APPROVED non-bot review. Config has `pr-approved-by-non-bot` for `building`. | `should_dispatch building ENG-86A` prints `proceed` and exits 0. |
| **B. Condition unmet → skip.** | Stub returns zero APPROVED reviews. | `should_dispatch building ENG-86B` prints `skip:awaiting-approval`. |
| **C. Malformed config (unknown check name) → fall through.** | Config has `{name: "made-up-check"}`. | `should_dispatch` logs the unknown check, continues, prints `proceed`. |
| **D. Empty/absent config → fall through.** | Config has `entry_conditions: {}`. | `should_dispatch` prints `proceed` (back-compat). |
| **E. GitHub API failure (gh outage) → error fall-through.** | Stub returns nonzero / empty. | `should_dispatch` prints `error:pr-approved-by-non-bot`. |
| **F. Unknown stage key (gerund mismatch) → fall through.** | Config has `building` (gerund) but caller asks for `build` (non-canonical). | `should_dispatch build ENG-86F` prints `proceed` (no checks for the unknown stage). Documents the silent-drift trade-off. |
| **G. ENG-45 budget integration — N skips count toward budget.** | Stub returns "unmet" three times in a row. After case B's first skip, `_handle_wait` is invoked; the test stubs `bin/run-stage.sh::_handle_wait` but calls `should_dispatch` repeatedly. Assert: `wait-building.json` has `attempts=3` after three calls (matches the existing ENG-45 case-G assertion at `bin/run-stage-test.sh:1053`). This case lives in `bin/run-stage-test.sh` rather than `entry-conditions-test.sh` because it asserts on `_handle_wait`'s side effect within `_entry_conditions_gate`, not on the registry script in isolation. |

Cases A–E are minimum-viable per the Linear issue's Acceptance.
Case F is a defensive pin for the gerund-mismatch trade-off
documented in D-005. Case G is the ENG-45 integration test the
Linear issue's Acceptance §(e) explicitly calls out.

## 4. Data flow

### 4.1 Happy path — PR approved, gate proceeds, agent dispatches

```
launchd tick N (PR is OPEN with one APPROVED non-bot review)
  poll.sh
    → ENG-N has stage:building, no halt label, no fresh halt verdict
      (a stale wait verdict from a prior tick is invisible to
       find_fresh_verdict per verdict-handler.sh:113).
    → _poll_classify_labels else branch (poll.sh:280) → hold,
      advanceable=true
    → emit decision: (ENG-N, building, run)

run-stage.sh ENG-N building
  → verify_preconditions → 0
  → _pre_dispatch_merge_gate ENG-N building:
      gh pr list --head … --state all --json state → "OPEN" → return 1
  → _entry_conditions_gate ENG-N building:
      bin/entry-conditions.sh should_dispatch building ENG-N
        → check_pr_approved_by_non_bot ENG-N
          → branch = feat/eng-n-…
          → gh pr view … --json reviews → reviews[].state=APPROVED non-bot count == 1
          → return 0
        → all checks met → printf 'proceed'
      → outcome="proceed" → return 0 (gate did not fire)
  → render-prompt.sh + dispatch.sh (today's path)
  → agent runs P0..P7, P2 passes, fires gh pr merge --auto
  → next tick(s): _pre_dispatch_merge_gate detects MERGED → released
```

Gate adds one extra GH API call per tick when this issue is being
considered. Agent runs as before.

### 4.2 Cost-saving path — PR not yet approved, gate skips

```
launchd tick N (PR is OPEN, no approving reviews yet)
  poll.sh: same as 4.1 → emit decision (ENG-N, building, run)

run-stage.sh ENG-N building
  → _pre_dispatch_merge_gate: not MERGED → fall through
  → _entry_conditions_gate ENG-N building:
      should_dispatch:
        check_pr_approved_by_non_bot:
          gh pr view … --json reviews → APPROVED non-bot count == 0
          → return 1, stdout="awaiting-approval"
        → printf 'skip:awaiting-approval'
      → outcome=skip:awaiting-approval
      → log "entry-conditions: skip (ENG-N, building) — reason=awaiting-approval"
      → metrics.sh stage-end ENG-N building dispatch-skipped 0 …
      → _handle_wait ENG-N building awaiting-approval:
          read $(issue_dir ENG-N)/wait-building.json (or seed if absent)
          attempts++
          within budget (max_attempts/max_minutes from
            orchestrator.external_signal_budget) → return 0
      → return 1 (gate fired, caller exits)
  → run-stage.sh::main: exits 0 with stage-skip metric pair
  → run-local.sh continues (next snapshot/sweep — but no in-scope
    artifacts because no agent ran; partition_dirty_paths sees an
    empty diff)
```

No agent dispatch. Wall-clock from poll → exit: ~250 ms (one `gh pr
view` + jq + a couple metric writes). Cost regression: zero.

### 4.3 Budget exhaust escalation — operator never approves

```
tick N+budget (e.g., max_attempts reached)
  _entry_conditions_gate → skip → _handle_wait:
    attempts >= max_attempts → exhausted=1
    posts <!-- pipeline: verdict result=halt
      reason=external-signal-budget-exhausted -->
    applies pipeline:halted
    rm wait-building.json
    return 1 (budget exhausted)
  _entry_conditions_gate ignores _handle_wait's return value (we exit
    clean either way; the halt is the durable signal).

next tick:
  poll.sh: ENG-N has pipeline:halted → _poll_classify_labels' halted
    branch (poll.sh:241-264): fresh halt marker → vacate. Issue is no
    longer dispatched until operator runs:
      bash bin/pipeline.sh decide ENG-N --action continue
```

This is the existing ENG-45 escalation path, unchanged. The only
delta is that the budget is now bumped per orchestrator-skip, not per
agent-dispatch — which IS the safety net the Linear issue's Risks
section calls out.

### 4.4 GitHub API outage — gate fails open

```
tick M
  _entry_conditions_gate:
    should_dispatch returns "error:pr-approved-by-non-bot"
    → log warning
    → metrics.sh stage-end … dispatch-skipped 0 outcome=error … fallthrough=true
    → return 0 (proceed to dispatch)
  → render-prompt.sh + dispatch.sh — agent runs as today
```

A persistent `gh` outage means the agent runs every tick (cost
regression returns) — but no false transitions, no false halts.
Operator visibility: the `error` metric line in events.jsonl
(distinguished by `outcome=error fallthrough=true` in notes).

### 4.5 Migration — issues already at stage:building when fix lands

1. **Issues currently mid-wait-loop** (no `pipeline:halted`, fresh
   wait verdict from agent emission). Hit the gate on the very next
   tick. If PR is unapproved, gate skips (cheap); if PR was approved
   while the operator wasn't watching, gate proceeds, agent runs,
   merge fires. No migration step needed.

2. **Issues already halted via budget exhaustion** (existing
   `pipeline:halted` from `_handle_wait`'s prior escalation).
   `poll.sh::_poll_classify_labels` vacates them (today's behavior,
   unchanged). Operator runs `bash bin/pipeline.sh decide ENG-N
   --action continue` (the standard atomic-resume primitive); on
   the next tick the gate fires cleanly. No new operator workflow.

3. **Operators who don't add the config key.** `entry_conditions`
   absent → empty checks array → `proceed`. Zero behavior change for
   them. Adopt at their pace.

## 5. Error handling

- **Empty / absent config.** `jq -r '.orchestrator.entry_conditions[$s]
  // []'` returns `[]` → `length == 0` → `proceed`. Back-compat.
- **Unknown check name in config.** `_entry_check_handler_for` returns
  nonzero → log + skip the entry → continue with remaining checks (if
  any). If all entries are unknown, gate emits `proceed`. Documented
  trade-off per D-005 (silent fall-through, mirrors ENG-65).
- **Unknown stage key in config.** Stage key doesn't match the gerund
  the orchestrator queries → `entry_conditions[$s]` returns `null` →
  `// []` → empty array → `proceed`. Operator gets no behavior change
  and no warning (intentional; mirrors ENG-65's gerund-drift trade-off).
- **`gh` not in PATH.** `command -v gh >/dev/null 2>&1 || return 2` in
  `check_pr_approved_by_non_bot` → `error` outcome → fall through.
- **`branch-name.sh` returns empty (Linear API outage).** Check returns
  rc=2 → `error` outcome → fall through. Same defensive shape as ENG-62
  D-006.
- **`gh pr view` returns empty / errors.** `2>/dev/null || printf ''`
  → empty → rc=2 → `error` outcome → fall through.
- **`jq` parse failure on malformed reviews JSON.** `jq` errors are
  swallowed by `2>/dev/null || printf '0'` → `approved_count="0"` →
  treated as unmet → `skip:awaiting-approval`. Trade-off: a malformed
  GH response that our regex coerces to `0` looks identical to "really
  zero approvals". Acceptable: ENG-45 budget catches a persistently
  malformed response within `max_attempts` ticks.
- **Handler returns unexpected rc (≥3).** Log + treat as `error` →
  fall through. Defensive default.
- **`_handle_wait` partial failure (Linear add-label or add-comment
  outage at budget exhaust).** Existing ENG-45 behavior: preserve
  `wait-building.json` for retry on next tick (`bin/run-stage.sh:565-574`).
  Unchanged.
- **Race: PR approval lands between gate query and dispatch start.**
  Window: gate queried at tick N, didn't see approval; operator
  approves between gate and next tick. Tick N+1: gate sees approval,
  proceeds, agent dispatches, merge happens. Worst case: one extra
  tick of latency (~5 min). No false negatives.
- **Race: PR approval revoked between dispatch and agent's P2 check.**
  Gate proceeds at tick N (saw approval), agent dispatches, agent's
  P2 sees no approval (revoked) → emits wait verdict → today's
  behavior unchanged. No silent merge.

## 6. Edge cases

- **First-time pickup of a building issue.** No `wait-building.json`
  yet; `_handle_wait` seeds it (`bin/run-stage.sh:531-533`). Mirrors
  the agent-driven first-wait path.
- **Multiple checks for the same stage.** AND-gating: any `unmet` →
  skip with that check's reason. The reason posted to `_handle_wait`
  is the FIRST unmet check's reason; subsequent checks are not
  evaluated (short-circuit). This mirrors the Linear issue's design
  ("Multiple checks per stage are AND'd: all must return 0 to
  dispatch"). If two checks for the same stage map to different wait
  reasons, the first-evaluated wins; document this in
  `bin/entry-conditions.sh`'s header comment.
- **Concurrent ticks on the same issue.** Cross-issue serialization
  via `.claude-mutex.lock/` (CLAUDE.md). Within an issue, the
  per-tick single-flight in `bin/run-local.sh:49-52` plus the per-
  issue dir's mutations (which are themselves atomic via
  `.tmp.$$ + mv` in `_handle_wait`) handle serialization.
- **`PIPELINE_DRY_RUN=1`.** `bin/entry-conditions.sh` is a read-only
  invocation of `gh` and `jq`; no Linear writes. Safe in dry-run.
  `_handle_wait`'s side effects (writing `wait-${stage}.json`,
  posting halt comments at budget exhaust) need to respect dry-run
  guards already in place at `bin/linear.sh`. The wait-file write
  is not gated by dry-run today (`bin/run-stage.sh:540`), but that
  is consistent with the ENG-45 dry-run behavior pre-ENG-86 and the
  test cases in `bin/run-stage-test.sh:1066+` rely on it.
- **`.pipeline-config/config.json` is gitignored** (CLAUDE.md
  "Per-target dispatch.tools extras"). Each operator opts in
  independently. The harness-self target's config does carry the
  enumerated test-suite allowlist; adding `entry_conditions.building`
  there is the operator-side migration step.
- **Stage gating.** `_entry_conditions_gate` is invoked for every
  stage (no case-arm filter). The config-driven dispatch makes it
  effectively a no-op for unconfigured stages (empty checks → fall
  through). Per D-009, only `building` has an initial check. Other
  stages: zero overhead beyond one `jq` read.
- **Building issue with no PR yet (UI stage failed to open one).**
  `branch-name.sh` returns the canonical branch; `gh pr view <branch>`
  returns nonzero (no PR) → check rc=2 → `error` → fall through →
  agent dispatches → P1 (`AGENT_PROMPTS.md:1282-1285`) catches the
  missing PR → halt-for-human via the precondition-ordering clause.
  Same outcome as today.
- **Bot self-approval** (e.g., a future bot reviewer using the same
  GitHub App). The check's regex `(.author.login | test("\\[bot\\]$")
  | not)` correctly excludes `*[bot]` logins. If a non-bot identity
  is a bot in disguise (an operator running the bot under their own
  identity), the check accepts it — same trade-off as P2 today.
- **`gh pr view` returns reviews from a deleted user.** `author.login`
  may be `"ghost"` or null. `jq`'s `.author.login | test("\\[bot\\]$")`
  on null returns null → `not` → `true` → counted as non-bot. Worst
  case: a `"ghost"` user's APPROVED review counts. Same trade-off
  as P2.

## 7. Open questions

- **Q1 (retrospective outcome filter for `dispatch-skipped`).** The
  retrospective §1 filter classifies events by outcome string;
  `dispatch-skipped` is a new literal. Confirm
  `bin/run-retrospective-local.sh` does not silently drop unknown
  outcomes (same Q1 as ENG-62). **Action:** verify during
  implementation by running the retrospective in dry-run after the
  fix lands. If silent-drop is observed, register `dispatch-skipped`
  in the retrospective's outcome allow-list.

- **Q2 (telemetry — track dispatches avoided AND health).** Each
  skip saves ~2 min wall-clock + ~$0.5–0.7 of dispatch cost. Two
  operator queries (no infra change required):

  (a) **Avoided-cost counter:**
  ```
  jq -c 'select(.outcome=="dispatch-skipped")' \
    $PROJECT_STATE_DIR/metrics/events.jsonl | wc -l
  ```
  Multiplying by ~$0.6 gives the dispatches-avoided estimate.

  (b) **Health check: did the gate skip at all this week, given
      we know there were awaiting-approval issues?**
  Same query, time-windowed via `select(.ts >= "<week-ago>")`.
  If this drops to zero in a week where humans observed
  awaiting-approval issues, the gate has stopped firing
  (likely a persistent `gh` outage or config-key drift).

  Plan phase should fold these into `docs/runbooks/recovery.md`'s
  observability checklist; promote to automated tripwire only if
  the gate is observed to silently fail in the field.

- **Q3 (`status.sh` rendering for `dispatch-skipped`).** `bin/status.sh`
  color-codes by outcome name; `dispatch-skipped` falls into the
  default uncolored bucket. **Decision for v1:** leave default; the
  metrics row is the durable record. Add a row-styling case in a
  follow-up if operators report that skipped dispatches blur into
  the rest of the table. (Same as ENG-62 §7-Q3.)

- **Q4 (single-check vs multi-check reason precedence).** §6's
  multiple-checks-AND'd path uses first-unmet-wins. If two checks
  for the same stage map to different `_handle_wait` reasons (e.g.,
  Phase 2 adds `awaiting-ci`), the first-evaluated check's reason
  is what `_handle_wait` sees. Today there's only one check per
  stage so this doesn't bite, but the order in the config array
  becomes load-bearing. **Action for Phase 1:** document in
  `bin/entry-conditions.sh`'s header comment; revisit if Phase 2
  needs a more sophisticated reason policy.

- **Q5 (interaction with ENG-85 vacate-on-wait).** ENG-85 (separate
  ticket) proposes that wait-shape verdicts vacate the slot like
  halts do today. ENG-86 alone leaves the issue holding its slot
  (skip is not vacate). Together: ENG-86 saves wall-clock; ENG-85
  vacates the slot so other issues can run in it. **No coordination
  needed for Phase 1**: ENG-85 will inspect the same wait-counter
  state ENG-86 maintains, and the per-tick metric event lets
  ENG-85 distinguish skip-vacate from agent-emitted-vacate via the
  `outcome` field.

## 8. Anti-bias checks

### 8.1 ADR / prior-art stress test

The harness has no `docs/knowledge/decisions.md`. Closest analogues
are prior brainstorms; key tensions:

- **`2026-04-28-build-agent-soft-preconditions-…-design.md` (ENG-45,
  merged).** Defines the wait-marker contract this brainstorm
  extends. D-002 reuses `_handle_wait` directly; that primitive is
  designed for agent-emitted waits. Adding orchestrator-emitted
  invocations is a coverage extension, not a contract change — same
  budget primitive, same wait file, same escalation path.
  **Tension surfaced:** `_handle_wait`'s lane attribution
  (`bin/run-stage.sh:490-491`) sets `PIPELINE_WRITER=orchestrator`
  inside the helper, so an orchestrator-side caller is correct
  (whereas an agent caller would be ill-typed). The new gate's
  invocation is consistent with this lane.

- **`2026-05-06-eng-62-…-design.md` (ENG-62, merged).** Establishes
  the pre-dispatch-gate pattern this brainstorm clones. D-001's
  insertion ordering (`_pre_dispatch_merge_gate` first, then
  `_entry_conditions_gate`) is an explicit composition. **No
  tension:** ENG-62 already creates the precedent; ENG-86 simply
  populates the next slot in the same shape.

- **`2026-05-02-pipeline-vocabulary-simplification-design.md` (ENG-60,
  merged).** Establishes the closed verdict / halt / transition
  vocabulary. **Tension surfaced:** D-003 explicitly does NOT
  introduce a new orchestrator-emitted verdict marker; the skip is
  a metric-only event. This preserves the closed registry; if a
  future iteration wants to surface orchestrator skips on Linear,
  it would use a `<!-- meta: ... -->` shape, NOT a new verdict.

- **`2026-04-30-eng-50-review-stage-reframe-design.md` (ENG-50)** and
  ENG-54. `bin/review-poll.sh::review_should_dispatch` is the
  closest-analogue precedent in the codebase: an orchestrator-side
  predicate (HEAD-SHA equality) that gates dispatch. **No tension:**
  `_entry_conditions_gate` follows the same shape but is per-stage
  configurable, where `review_should_dispatch` is hardcoded for
  reviewing only. The Linear issue's Phase 2 explicitly suggests
  migrating review's gate into this generic shape later.

- **`2026-05-02-eng-58-…-design.md` (ENG-58, merged).** Defines
  `bash bin/pipeline.sh decide --action continue` as the
  atomic-resume primitive. §4.5 leans on this primitive unchanged
  for the migration of issues already halted via budget exhaustion.

- **ENG-65 dispatch_timeout_minutes_per_stage** (`bin/dispatch.sh:391`).
  The Linear issue cites this as the validation pattern template.
  D-005 follows it exactly: per-stage gerund-keyed config object,
  silent fall-through on unknown keys, opt-in default-empty.

**Key tradeoff surfaced:** `bin/run-stage.sh::main` keeps growing
its pre-dispatch gate stack. Today: `verify_preconditions` → guards
→ scope-approval-replay → `_pre_dispatch_merge_gate` →
`_entry_conditions_gate` → `render-prompt.sh` → `dispatch.sh`. Each
gate is structurally similar (helper + insertion point + idempotent
exit). If we cross five gates in this stack, refactoring to a
table-driven dispatch ("gate registry") becomes attractive. For
now, the linear-list shape is concrete and debuggable; defer.

### 8.2 Simpler alternatives considered

- **A. Prompt-side fix only — make the agent's P2 cheaper to
  re-run.** Rejected: the agent's P2 is already a single
  `gh pr view --json reviews` call (~100 ms inside the agent run);
  the dispatch overhead (~2 min wall-clock, claude session startup
  + prompt rendering + tool denial enumeration + transcript
  capture) is what we're saving, not the P2 query itself.

- **B. Cache last-known-approved state in `wait-building.json`** to
  short-circuit the agent without a fresh `gh` query. Rejected: the
  cache invalidation problem is exactly what the gate is solving;
  re-querying GH per tick is unavoidable.

- **C. Move the gate to `bin/poll.sh`** (next to `review-poll`'s
  HEAD-SHA gate). Rejected per ENG-62 §8.2-C: poll.sh is hot-loop
  per-issue per-tick; the gate runs only when an issue is about to
  be dispatched. Same trade-off.

- **D. Run the gate in `bin/run-local.sh` per the Linear issue's
  pseudocode.** Rejected per D-001: `dispatch.sh` is invoked from
  `run-stage.sh`, not `run-local.sh`; `_handle_wait` is in scope
  in `run-stage.sh` only.

- **E. Inline the check in `_pre_dispatch_merge_gate`** (one
  helper, two predicates). Rejected: violates single-purpose
  helpers; the merge gate is a transition path (it advances the
  issue), the entry-condition gate is a wait path (it stalls the
  issue). Coupling them complicates testing and obscures the
  Phase 2 generalization (other stages get entry-conditions but
  not merge-gates).

- **F. Make the entry-condition check a class-of `verify_preconditions`
  step** (`bin/run-stage.sh:664-674`). Rejected:
  `verify_preconditions` is currently a thin wrapper that exits 11
  on pause / 10 on guards. Adding a third exit code (12 for
  "wait-skip") would conflate hard preconditions (paused / guards)
  with soft skips (entry-conditions). The hard / soft distinction
  is load-bearing for the operator's mental model.

- **G. Use `<!-- meta: ... -->` markers on Linear for skip
  visibility.** Rejected per D-003: linear-thread-litter pattern.

### 8.3 Assumption inventory

| Assumption | Status | Evidence / Action |
| --- | --- | --- |
| `bin/run-stage.sh::_pre_dispatch_merge_gate` exists at `bin/run-stage.sh:613-654`; pattern of `if _gate "$ident" "$stage"; then exit 0; fi` is the precedent for ENG-86's gate. | **verified** | `bin/run-stage.sh:613` (function signature), `bin/run-stage.sh:710` (call site). |
| Insertion-point boundary: AFTER `_pre_dispatch_merge_gate`'s `exit 0` block at `bin/run-stage.sh:705-722`, BEFORE `mkdir -p "$(issue_dir "$ident")"` at `bin/run-stage.sh:726`. | **verified** | `bin/run-stage.sh:710-722` (gate block), `bin/run-stage.sh:726` (mkdir). |
| `_handle_wait` at `bin/run-stage.sh:489-578` is the budget-counter primitive; it reads `wait-${stage}.json`, increments `attempts`, escalates on `external_signal_budget` exhaust. | **verified** | `bin/run-stage.sh:489-578`. Specifically: read at line 502-503, increment at line 530, budget-exhaust check at line 546-558, halt application at line 560-575. |
| `_handle_wait` returns 0 when within budget (caller exits 0), returns 1 when budget exhausted (halt already applied). | **verified** | `bin/run-stage.sh:575` (`return 1` on exhaust), `bin/run-stage.sh:577` (`return 0` otherwise). |
| `_handle_wait`'s reason argument is opaque — accepts any string, written verbatim into `wait-${stage}.json::reason`. | **verified** | `bin/run-stage.sh:493` (signature), `bin/run-stage.sh:536` (`--arg r "$reason"`), `bin/run-stage.sh:538` (`reason:$r`). |
| `bin/run-stage.sh::main` already invokes `_handle_wait` from agent-side wait detection at `bin/run-stage.sh:947`; new orchestrator-side call adds a sibling call site. | **verified** | `bin/run-stage.sh:947` (`if _handle_wait "$ident" "$stage" "$_wait_reason"; then`). |
| `orchestrator.external_signal_budget.{max_attempts,max_minutes}` config keys are read by `_handle_wait`. | **verified** | `bin/run-stage.sh:543-544` (`config_get '.orchestrator.external_signal_budget.max_attempts // empty'` etc.). |
| `_post_dispatch_apply_halt` (`bin/run-stage.sh:380-392`) carve-out for wait shapes is build-only. The orchestrator-skip path doesn't reach this helper because it `exit 0`s before; no interaction. | **verified** | `bin/run-stage.sh:380-392` (helper), `bin/run-stage.sh:705-722` (gate `exit 0` precedes the agent-contract validator and `_post_dispatch_apply_halt` at `bin/run-stage.sh:1019` and beyond). |
| `bin/run-local.sh:257` invokes `bin/run-stage.sh`. The Linear issue's "in run-local.sh" placement is structurally wrong because `dispatch.sh` is invoked from `run-stage.sh`, not `run-local.sh`. | **verified** | `bin/run-local.sh:257` (`bash "$SCRIPT_DIR/run-stage.sh" "$issue_id" "$stage"`); `bin/run-stage.sh:744` (`bash "$SCRIPT_DIR/dispatch.sh"`). |
| `bin/poll.sh::_poll_classify_labels` else branch returns `slot=hold, advanceable=true` for `stage:building` + no halt label + no fresh halt verdict — the trigger that causes run-stage.sh to fire and the gate to run. | **verified** | `bin/poll.sh:280` (`else class='{"slot":"hold","advanceable":true}'`). |
| `bin/poll.sh:34` excludes `stage:released` from the polled set. | **verified** | `bin/poll.sh:34` (`stage:released is terminal — not polled`). |
| `bin/verdict-handler.sh::find_fresh_verdict` does NOT match `result=wait` markers (so a stale wait verdict from a prior agent dispatch is invisible to the verdict handler). | **verified** | `bin/verdict-handler.sh:113` (`[[ "$(jq -r '.result' <<<"$ev")" == "wait" ]] && continue`). Re-quoted line-by-line in this iteration (not just inherited from ENG-62 §8.4). |
| `bin/dispatch.sh::allowed_tools_for` for `building` includes `gh pr view:*` and `gh pr list:*` (the queries the agent's P2 uses). | **verified** | `bin/dispatch.sh:328` (`Bash(gh pr view:*),Bash(gh pr list:*)`). |
| The orchestrator-side gate runs `gh pr view` from the harness host (not the agent sandbox), so the dispatch tool allowlist does not constrain it. | **verified** | `bin/run-stage.sh::main` runs in the harness's bash process; `gh` is on PATH per `bin/run-local.sh:22`. |
| `bin/branch-name.sh` derivation pattern is `feat/<id-lower>-<slug>` or `fix/<id-lower>-<slug>`. | **verified** | `bin/branch-name.sh:31` (`printf '%s/%s-%s\n' "$prefix" "$ident_lower" "$slug"`). Re-quoted line-by-line. |
| `bin/metrics.sh stage-end <issue> <stage> <outcome> <duration_ms> [notes...]` accepts arbitrary outcome strings; new literal `dispatch-skipped` is sound; flag-style cost args are OPTIONAL. | **verified** | `bin/metrics.sh:19-75` (parser accepts any non-flag arg as a notes token; outcome is just `--arg outcome`). |
| `dispatch_timeout_minutes_per_stage` config validation pattern (silent fall-through on unknown keys, gerund stage names) is the right template for `entry_conditions`. | **verified** | `bin/dispatch.sh:391-396` (jq read via `--arg s "$stage"`, integer-only validation, silent fall-through). |
| `bin/poll.sh::stage_arg_for_label` and `bin/dispatch.sh::allowed_tools_for` use canonical gerunds (`brainstorming, planning, implementing, ui, reviewing, qa, building, released, retrospective`). | **verified** | `bin/poll.sh:25-33` (STAGE_LABEL_TO_STAGE_ARG); `bin/dispatch.sh:320-330` (case arms). |
| The `gh pr view --json reviews` query shape matches `AGENT_PROMPTS.md` §7 P2 for non-bot APPROVED detection. | **verified** | `AGENT_PROMPTS.md:1287-1289` (P2 query); D-008 keeps these in sync via comment. |
| `bin/common.sh::config_get` reads `$CONFIG` (which resolves to `$TARGET_CONFIG_DIR/config.json` via `bin/common.sh`). | **verified** | `bin/common.sh:316-319`. |
| Source-and-stub test pattern (per CLAUDE.md "Tests" §) supports new test files via the `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi` sentinel. | **verified** | `bin/run-stage.sh` sentinel at end of file (per CLAUDE.md); ENG-45 test cases in `bin/run-stage-test.sh` source-and-stub the same way. |
| `bin/run-stage-test.sh:1066+` already covers `_handle_wait`'s budget integration with stubs; case G ("ENG-45 budget integration") can extend the existing fixture to assert orchestrator-skip increments. | **verified** | `bin/run-stage-test.sh:1066-1119` (case G + I in the existing ENG-45 cases). |
| `bin/run-retrospective-local.sh`'s §1 outcome filter accepts the new `dispatch-skipped` literal without silent-drop. | **assumed** | Q1 — verify during implementation by running retrospective dry-run after the fix lands. |
| `gh pr view <branch> --json reviews` returns the historical reviews array even if the branch ref is later deleted (matches the post-merge case). | **verified externally** | Standard `gh` JSON behaviour; matches the pattern P2 already relies on per `AGENT_PROMPTS.md:1287`. The orchestrator-side check runs PRE-merge so this is a defensive note, not a load-bearing assumption. |
| `partition_dirty_paths` will not classify the new `bin/entry-conditions.sh` and `bin/entry-conditions-test.sh` files as out-of-scope when they're committed during the implement stage of ENG-86. | **assumed (low risk)** | The basename `eng-86-…-design.md` carries the load-bearing token; new files under `bin/` are in-scope per the harness-self target's plan File Structure conventions. Verify during implementation by inspecting the implement-stage tick's partition output. |

### 8.4 Codebase-fact verification

Every named code artifact is grounded in the current worktree
(`/Users/rajatgoyal/.local/state/twinning-harness/harness/ENG-86/worktree/`):

| Name | Quoted location |
| --- | --- |
| Build agent prompt §7 header | `AGENT_PROMPTS.md:1236` |
| §7 P0 merge-state precheck (ENG-62) | `AGENT_PROMPTS.md:1262-1280` |
| §7 P2 (review approved by non-bot Code Owner) | `AGENT_PROMPTS.md:1287-1316` |
| §7 P2 wait-exit (`reason=awaiting-approval`) | `AGENT_PROMPTS.md:1294-1316` |
| §7 P5 wait-exit (`reason=awaiting-ci`) | `AGENT_PROMPTS.md:1325-1352` |
| §7 precondition-ordering clause | `AGENT_PROMPTS.md:1255-1260` |
| `bin/run-stage.sh::_fresh_wait_reason` (build-only allow-list, awaiting-approval / awaiting-ci) | `bin/run-stage.sh:310-364` |
| `bin/run-stage.sh::_post_dispatch_apply_halt` (wait-shape carve-out) | `bin/run-stage.sh:380-392` |
| `bin/run-stage.sh::_handle_wait` (counter + budget) | `bin/run-stage.sh:489-578` |
| `bin/run-stage.sh::_handle_wait` reason-arg signature | `bin/run-stage.sh:493` |
| `bin/run-stage.sh::_handle_wait` `external_signal_budget` config read | `bin/run-stage.sh:543-544` |
| `bin/run-stage.sh::_handle_wait` budget-exhaust escalation | `bin/run-stage.sh:560-575` |
| `bin/run-stage.sh::_pre_dispatch_merge_gate` (ENG-62 precedent) | `bin/run-stage.sh:613-654` |
| `bin/run-stage.sh::main` `_pre_dispatch_merge_gate` invocation (insertion-point boundary, AFTER) | `bin/run-stage.sh:710-722` |
| `bin/run-stage.sh::main` `mkdir -p "$(issue_dir "$ident")"` (insertion-point boundary, BEFORE) | `bin/run-stage.sh:726` |
| `bin/run-stage.sh::main` `render-prompt.sh` invocation | `bin/run-stage.sh:734` |
| `bin/run-stage.sh::main` `dispatch.sh` invocation | `bin/run-stage.sh:744` |
| `bin/run-stage.sh::main` agent-side wait detection block (ENG-45) | `bin/run-stage.sh:937-983` |
| `bin/run-stage.sh::main` `_handle_wait` agent-side call site | `bin/run-stage.sh:947` |
| `bin/run-stage.sh` lane-attribution pattern (`local PIPELINE_WRITER=orchestrator`) | `bin/run-stage.sh:490-491` (in `_handle_wait`); `bin/run-stage.sh:618-619` (in `_pre_dispatch_merge_gate`) |
| `bin/run-local.sh` `run-stage.sh` invocation | `bin/run-local.sh:257` |
| `bin/run-local.sh` worktree resolution | `bin/run-local.sh:229-233` |
| `bin/run-local.sh` snapshot creation | `bin/run-local.sh:249-254` |
| `bin/poll.sh::_poll_classify_labels` else branch | `bin/poll.sh:280` |
| `bin/poll.sh:34` stage:released terminal note | `bin/poll.sh:34` |
| `bin/poll.sh::stage_arg_for_label` STAGE_LABEL_TO_STAGE_ARG table (canonical gerunds) | `bin/poll.sh:25-33` |
| `bin/dispatch.sh::allowed_tools_for` case arms (canonical gerunds) | `bin/dispatch.sh:320-330` |
| `bin/dispatch.sh::allowed_tools_for` building tools (includes `gh pr view`, `gh pr list`) | `bin/dispatch.sh:328` |
| `bin/dispatch.sh::main` per-stage timeout config read (ENG-65 validation pattern template) | `bin/dispatch.sh:388-403` |
| `bin/review-poll.sh::review_should_dispatch` (precedent: orchestrator-side dispatch predicate) | `bin/review-poll.sh:29-53` |
| `bin/metrics.sh::main` event-emission shape | `bin/metrics.sh:19-75` |
| `bin/common.sh::config_get` | `bin/common.sh:316-319` |
| `bin/common.sh::issue_dir` (used to resolve `wait-${stage}.json` location) | `bin/common.sh:68` (`issue_dir() {`); used in `bin/run-stage.sh:494`, `bin/run-stage.sh:639`. |
| `bin/run-stage-test.sh` ENG-45 case G/H/I (existing fixtures we extend for ENG-86 case G) | `bin/run-stage-test.sh:1039-1126` |

Predecessor brainstorms used as prior art:

| Name | Path |
| --- | --- |
| ENG-45 (build-agent soft preconditions, wait-marker contract) | `docs/brainstorms/2026-04-28-build-agent-soft-preconditions-p2-p5-should-re-dispatch-not-halt-for-human-design.md` |
| ENG-50 (review-stage reframe; orchestrator-side review-poll) | `docs/brainstorms/2026-04-30-eng-50-review-stage-reframe-design.md` |
| ENG-58 (atomic-resume) | `docs/brainstorms/2026-05-02-eng-58-halt-sh-resolve-atomic-state-reset-clean-wait-skip-until-rejection-counter-side-state-design.md` |
| ENG-60 (vocabulary simplification) | `docs/brainstorms/2026-05-02-pipeline-vocabulary-simplification-design.md` |
| ENG-62 (pre-dispatch merge gate; pattern this brainstorm extends) | `docs/brainstorms/2026-05-06-eng-62-build-p2-still-emits-awaiting-approval-on-post-merge-dispatches-despite-non-bot-approved-review-existing-design.md` |
| ENG-65 (per-stage timeout config; validation pattern template) | `docs/brainstorms/2026-05-03-eng-65-brainstorm-wall-clock-timeout-gtimeout-1800s-silently-kills-agents-mid-iteration-needs-per-iteration-budget-or-larger-cap-design.md` |

No referenced item is non-existent or speculative. The two items
that the prior draft of this brainstorm had carried over from
ENG-62 (`find_fresh_verdict` wait-shape exclusion;
`branch-name.sh:31`) were re-verified line-by-line during this
iteration and the citations updated accordingly.

## 9. Scope check vs Linear issue

The Linear issue's IN list maps to:

- ✅ **AC: New `bin/entry-conditions.sh` with `pr-approved-by-non-bot`.**
  D-004 specifies the file and the check.
- ⚠️ **AC: `bin/run-local.sh` calls into it before `dispatch.sh`.**
  **Deviation, structurally justified.** D-001 places the gate in
  `bin/run-stage.sh::main` instead, because (a) `dispatch.sh` is
  invoked from `run-stage.sh`, not `run-local.sh` — the issue's
  pseudocode is structurally incorrect; (b) `_handle_wait` is in
  scope only inside `run-stage.sh`; (c) the architectural pattern
  for pre-dispatch gates is established by ENG-62. The intent
  ("orchestrator runs cheap gate before agent dispatch") is
  fully preserved; only the file location differs. **Flagged for
  reviewer attention** because the AC text explicitly names
  `run-local.sh`.
- ✅ **AC: Config schema validated; absent / empty / unknown-stage
  config falls through to "always dispatch" (back-compat).** D-005
  follows the ENG-65 validation pattern explicitly.
- ✅ **AC: ENG-79-style scenario — agent NOT dispatched while PR is
  unapproved; orchestrator log shows `skip: entry condition unmet`;
  operator approves PR → next tick dispatches normally.** §4.1 + §4.2
  show both paths; the scenario test goes in `bin/entry-conditions-test.sh`
  case A + B (D-004 / §3.5). Note: ENG-79 is a separate ticket
  (render-prompt branch-name hardcoding); the Linear issue's
  reference is to the OBSERVED SYMPTOM that ENG-79 surfaced, not a
  dependency on ENG-79's fix.
- ✅ **AC: `bin/entry-conditions-test.sh` covering five scenarios.**
  §3.5 cases A-E directly map to the issue's (a)-(e). Case F
  (gerund-mismatch) and case G (ENG-45 budget integration, lives in
  run-stage-test.sh) are additional defensive pins.

OUT list (no scope sprawl):

- ✅ **No predicate language for arbitrary checks.** D-004 ships
  one named check; mini-DSL is out of scope per the issue.
- ✅ **No cross-stage entry conditions.** Per-stage / per-issue only.
  D-005's config schema does not admit cross-stage references.
- ✅ **No retrofit of analogous gates to other stages** beyond
  the documented Phase 2 list (review SHA gate, retrospective
  cadence). Phase 1 ships only `building`.

**Phase 2 follow-ups (deferred per issue's "Stage-by-stage rollout"):**

- Review stage: `branch-head-since-last-review-sha`. Migrate
  `bin/review-poll.sh::review_should_dispatch` into the
  `entry-conditions` registry. Reduces special-casing in `poll.sh`.
- Retrospective: `weekly-cadence-since-last-run`. Could collapse
  the separate launchd plist into the main pipeline plist.
- Runtime-mtime checks (the deferred D-004 from ENG-77 brainstorm).

**Pre-existing observations logged for separate follow-up
(NOT in scope):**

- `bin/run-stage.sh:560-562`'s `external-signal-budget-exhausted`
  reason string is NOT in `bin/pipeline-events.json::halt_reasons`
  (carried over from ENG-62 §9 follow-up). ENG-86 inherits this
  gap by reusing `_handle_wait` unchanged. **Action:** file as
  separate ticket, do not bundle.

- The Linear issue's "Result coupling" risk (orchestrator and
  agent both maintain a P2-shape jq filter that could drift):
  D-008 documents the trade-off and adds a reference comment, but
  does NOT factor into a shared snippet. If the agent's P2 evolves
  in a meaningful way, both sites need to be updated together —
  surface for retrospective inclusion in `learned-rules/harness/`.

## 10. Persona review

This section records each persona's verdict (PASS / CONCERN / FAIL)
and a one-paragraph summary of resolved findings.

### Iteration 1

- **Design lens — PASS.** The gate placement (D-001) reuses the
  ENG-62 `_pre_dispatch_merge_gate` pattern verbatim — same
  insertion shape, same `if _gate; then exit 0; fi` idiom, same
  `local PIPELINE_WRITER=orchestrator` lane attribution. The
  composition with `_pre_dispatch_merge_gate` (D-007: merge-gate
  first, entry-conditions second) avoids redundant `gh` queries on
  merged PRs. Reusing `_handle_wait` for budget accounting (D-002)
  preserves the existing safety net without duplicating state. The
  configurable design (D-005) admits Phase 2 expansion without
  schema migration. Single-purpose files (`bin/entry-conditions.sh`)
  match the codebase's `bin/review-poll.sh`/`bin/scope-check.sh`
  precedent. The Linear issue's "in run-local.sh" structural
  inversion is correctly identified and corrected (§1.1, D-001).

- **Security lens — PASS.** Stage-key drift (gerund vs non-gerund)
  silently falls through to "always dispatch" — the SAFER
  fail-mode (over-dispatch is observable as cost; silent-skip
  would be the dangerous mode). Lane attribution
  (`local PIPELINE_WRITER=orchestrator` in the new helper)
  mirrors the existing pattern at `bin/run-stage.sh:490-491` /
  `bin/run-stage.sh:618-619` — prevents lane-violation if a
  future caller invokes the gate from an agent sub-shell.
  `bin/entry-conditions.sh` is read-only on Linear and GitHub
  state — no label writes, no comments, no transitions; the only
  side effect is via `_handle_wait` (which is the existing
  primitive, owned by the orchestrator lane). No new env-var
  surface; no new tool-allowlist entry (the gate runs from the
  harness host, not the agent sandbox). Fail-open on `gh` outage
  (D-010) matches ENG-62 D-006's tradeoff. Bot-self-approval
  trade-off (`*[bot]` regex) is the same as P2's; no expansion
  of attack surface.

- **Scope guardian — PASS.** D-009 enumerates non-changes
  exhaustively (run-local.sh, poll.sh, dispatch.sh,
  verdict-handler.sh, classify-failure.sh, linear.sh,
  pipeline-events.json, AGENT_PROMPTS.md). §9's deviation from
  the Linear issue's "in run-local.sh" placement is structurally
  justified and explicitly flagged as deviation rather than
  silently reinterpreted. Phase 2 follow-ups (review SHA gate,
  retrospective cadence, runtime-mtime checks) are explicitly
  parked as separate tickets. The pre-existing
  `external-signal-budget-exhausted` registry-gap is logged as
  out-of-scope follow-up (carrying over from ENG-62 §9) rather
  than bundled. The mini-DSL temptation is rejected per the
  issue's OUT list.

- **Coherence — PASS.** D-001 + D-002 + D-003 + D-007 form a
  coherent chain: gate placement → budget integration → no
  Linear-comment side-effect → ordering with merge-gate. The
  §4 data flow's three branches (proceed / skip / error) are
  consistent with the §3.2 helper sketch's three return paths.
  The §5 error-handling table walks the same outcome shape as
  D-010's fail-open principle. The §6 multiple-checks-AND'd
  semantics (first-unmet-wins) is consistent with the Linear
  issue's design ("all must return 0 to dispatch") and surfaces
  the reason-precedence trade-off honestly (Q4) rather than
  burying it. The §4.5 migration uses ENG-58's atomic-resume
  primitive unchanged.

- **Product lens — PASS.** Cost recovery is concrete (~$0.5–0.7
  + ~2 min wall-clock per skipped tick). Operator-facing surface
  is unchanged in the happy case (no new label, no new sig);
  visible only as a new metrics outcome (`dispatch-skipped`)
  when it fires. Q2's two operator queries give ops a documented
  post-deploy verification path and a manual health-check
  tripwire, with promotion to automated only if the gate is
  observed to silently fail (mirrors ENG-62's Q2 cadence). The
  ENG-81 K=2 parallelism interaction (the load-bearing reason in
  the Linear issue) is explicitly preserved: skipped issues no
  longer occupy the host's claude-mutex during the dispatch
  window. ENG-85 vacate-on-wait composes cleanly without
  coordination (Q5).

- **Feasibility lens — PASS.** Every cited path:line in §8.4
  was re-verified against the current worktree before this
  iteration. Key items confirmed:
  `bin/run-stage.sh:489-578` (`_handle_wait` complete signature
  and budget logic), `bin/run-stage.sh:613-654`
  (`_pre_dispatch_merge_gate` precedent including `local
  PIPELINE_WRITER=orchestrator` at lines 618-619),
  `bin/run-stage.sh:710-722` (insertion-point AFTER boundary,
  including the metric stage-start/stage-end pairing the new
  block must mirror), `bin/run-stage.sh:726` (insertion-point
  BEFORE boundary), `bin/run-stage.sh:937-983` (existing
  agent-side wait detection — confirmed `_handle_wait` is
  callable from `main()` and returns the documented codes),
  `bin/run-stage.sh:947` (existing `_handle_wait` agent-call
  site — the new orchestrator-call site is its sibling),
  `bin/dispatch.sh:320-330` (canonical gerund stage names for
  D-005's stage-key validation), `bin/dispatch.sh:391-396`
  (ENG-65 validation pattern template),
  `bin/dispatch.sh:328` (building tools allowlist already
  carries `gh pr view`/`gh pr list` — no allowlist change
  needed), `bin/poll.sh:280` (else branch returns
  advanceable=true — the trigger),
  `bin/review-poll.sh:29-53` (closest-analogue precedent for
  orchestrator-side dispatch predicate),
  `bin/metrics.sh:19-75` (metric-emission shape accepts
  arbitrary outcome string — `dispatch-skipped` works),
  `AGENT_PROMPTS.md:1287-1289` (P2 query the new check
  mirrors). Two items the initial draft had carried over from
  ENG-62 (`bin/verdict-handler.sh::find_fresh_verdict`
  wait-shape exclusion at line 113;
  `bin/branch-name.sh:31` derivation) were re-verified
  line-by-line during this iteration and §8.4 now quotes
  them directly. Q1 (retrospective §1 outcome filter
  acceptance of `dispatch-skipped`) is the only "assumed"
  item; it is a straightforward dry-run verification during
  implementation, not a blocker. The plan stage will absorb
  this as a verification step in its acceptance test plan.

**Final tally for iteration 1: 6/6 PASS, gate P0 = 0.** Proceeding
to planning.
