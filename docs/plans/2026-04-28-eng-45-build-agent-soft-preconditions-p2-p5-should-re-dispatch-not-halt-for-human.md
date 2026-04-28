---
linear: ENG-45
date: 2026-04-28
topic: Build agent soft preconditions (P2/P5) re-dispatch via pipeline-wait marker + orchestrator-owned budget
---

# Plan — ENG-45 build agent soft preconditions (P2/P5) re-dispatch, not halt-for-human

Implements the design in
`docs/brainstorms/2026-04-28-build-agent-soft-preconditions-p2-p5-should-re-dispatch-not-halt-for-human-design.md`.

## Goal

Land a single PR off `main` that makes the build agent re-dispatch on the next
launchd tick (instead of halting for a human) when the only failed precondition
is P2 (non-bot Code Owner approval missing) or P5 (CI not yet green), bounded by
an orchestrator-owned attempts/wall-clock budget that escalates to
`pipeline-halt: external-signal-budget-exhausted` when exhausted — observable as
a sequence of one or more `outcome=soft-pending` metric events on `stage=build`
followed by an `outcome=success` event with no intervening `outcome=halt-for-human`.

## Assumption Inventory

Every modified file's current state is quoted by `path:line` so the
implementation agent can find the insertion / replacement target verbatim.

### A-001 — `bin/run-stage.sh` agent-contract validator location

Current code at `bin/run-stage.sh:477-490`:

```bash
  if (( ! skip_dispatch )); then
    case "$stage" in
      brainstorm|plan|implement|ui|review|qa|build)
        local _summary_path _fresh_marker
        _summary_path="$(issue_dir "$ident")/stage-summary-${stage}.md"
        _fresh_marker="$(find_fresh_verdict "$ident" 2>/dev/null || printf '')"
        if [[ ! -s "$_summary_path" ]] && [[ -z "$_fresh_marker" ]]; then
          classify_failure "$ident" "$stage" "retry-immediately" \
            "agent dispatch returned 0 but emitted no stage-summary file and no verdict marker" 25
          exit 25
        fi
        ;;
    esac
  fi
```

The new wait gate inserts at line 477, **immediately before** this block. The
existing block is not modified — for non-wait exits it continues to fire as
today. `skip_dispatch`, `stage`, `ident`, and `t0` are all in scope at line 477
(verified at `bin/run-stage.sh:295-475`).

### A-002 — `bin/run-stage.sh` defensive halt-add

Current code at `bin/run-stage.sh:539-545`:

```bash
  # Post-dispatch halt check: every stage agent must apply pipeline:halted.
  # If it did not, apply it on the agent's behalf and let the Verdict Handler
  # surface a protocol violation on the next tick.
  if ! bash "$SCRIPT_DIR/linear.sh" has-label "$ident" "pipeline:halted"; then
    log "post-dispatch: agent did not apply pipeline:halted; applying on its behalf"
    bash "$SCRIPT_DIR/linear.sh" add-label "$ident" "pipeline:halted" || true
  fi
```

Not modified by this plan. The wait gate at line 477 short-circuits with
`exit 0` on a within-budget wait, so this block never runs for wait exits. On a
budget-exhausted wait, `_handle_wait` already applied `pipeline:halted`, so this
block is a no-op.

### A-003 — `bin/run-stage.sh` success-path cleanup

Current code at `bin/run-stage.sh:574-577`:

```bash
      log "stage $stage complete for $ident (verdict-handler transitioned)"
      # Success path: clear any prior failure state + skip labels.
      rm -f "$(issue_dir "$ident")/issue-state.json" 2>/dev/null || true
      bash "$SCRIPT_DIR/linear.sh" remove-label "$ident" "pipeline:skip-until-code-changes" 2>/dev/null || true
```

This plan adds `rm -f "$(issue_dir "$ident")/wait-${stage}.json" 2>/dev/null || true`
immediately after the existing `issue-state.json` removal (line 575) — so a
successful build that had been waiting earlier clears its counter file.

### A-004 — `bin/poll.sh::_poll_classify_labels` else-branch (the soft-redispatch path the design exploits)

Current code at `bin/poll.sh:227-229`:

```bash
  else
    class='{"slot":"hold","advanceable":true}'
  fi
```

Not modified by this plan. This `else` fires whenever an issue with `stage:building`
has no `pipeline:halted`, no `pipeline:abandoned`, no `pipeline:paused`,
no `pipeline:scope-approval-needed`. The wait flow leaves the issue in exactly
that state; the existing `else` correctly classifies it as
`hold, advanceable=true` and re-dispatches build on the next tick.

### A-005 — `bin/verdict-handler.sh::find_fresh_verdict` regex set (does NOT match `pipeline-wait`)

Current code at `bin/verdict-handler.sh:82-118`:

```bash
  fresh="$(jq -c --arg t "$last_transition_ts" '
    [.[]
     | select(.createdAt > $t)
     | select(
         (.body | contains("<!-- pipeline-stage-summary:")) or
         (.body | contains("<!-- pipeline-rejection:")) or
         (.body | contains("<!-- pipeline-halt:"))
       )]
    | sort_by(.createdAt) | last // empty' <<<"$comments")"
```

Not modified. The jq filter literally enumerates the three verdict shapes;
`pipeline-wait` is **not** among them, so a wait-marker comment is invisible to
`find_fresh_verdict`. This is the load-bearing reason the existing four-state
poller already handles the wait flow.

### A-006 — `bin/verdict-handler.sh::find_fresh_verdict` halt regex accepts hyphenated reasons

Current code at `bin/verdict-handler.sh:110-113`:

```bash
  elif grep -qE '<!-- pipeline-halt: [a-z-]+ -->' <<<"$body"; then
    marker="pipeline-halt"
    reason="$(grep -oE '<!-- pipeline-halt: [a-z-]+ -->' <<<"$body" \
      | head -1 | sed -E 's/<!-- pipeline-halt: ([a-z-]+) -->/\1/')"
```

Not modified. `[a-z-]+` accepts `external-signal-budget-exhausted`, so the new
escalation halt reason is a one-string change with zero control-flow impact on
`find_fresh_verdict`.

### A-007 — `bin/linear.sh::_lane_decision` already permits the agent's writes

Current code at `bin/linear.sh:75, 82`:

```bash
    "add pipeline_halted")        printf 'allow' ;;  # all lanes allowed
    "add other_comment")          printf 'allow' ;;  # all lanes allowed
```

Not modified. The agent posts the wait comment via
`bash .pipeline/bin/linear.sh add-comment`, which classifies as `other_comment`
(the body's first non-blank line is `<!-- pipeline-wait: -->`, not
`<!-- pipeline-transition: -->`, so `transition_comment` does not match — see
`_classify_comment_body` at `bin/linear.sh:49-63`); the agent lane is `allow`
for the `add other_comment` row. The orchestrator's budget-exhaustion halt-add
inside `_handle_wait` exports `PIPELINE_WRITER=orchestrator` so it goes through
the `orchestrator` lane.

### A-008 — `bin/dispatch.sh` build profile already permits `linear.sh` calls

Current code at `bin/dispatch.sh:136`:

```bash
    build)          printf 'Read,Write,Grep,Glob,Bash(git fetch:*),Bash(git clone:*),Bash(git rebase:*),Bash(gh run:*),Bash(gh pr list:*),Bash(gh pr view:*),Bash(gh pr checks:*),Bash(gh pr edit:*),Bash(gh pr merge:*),Bash(jq:*),Bash(mktemp:*),Bash(bash .pipeline/bin/linear.sh:*),Bash(bash .pipeline/bin/slack.sh:*)' ;;
```

Not modified. The build profile already grants
`Bash(bash .pipeline/bin/linear.sh:*)`, so the new wait-marker post needs
no dispatch-allowlist change.

### A-009 — `bin/common.sh::config_get` is the canonical jq wrapper

Current code at `bin/common.sh:191-194`:

```bash
config_get() {
  local path="$1"
  jq -r "$path" "$CONFIG"
}
```

Not modified. The new `_handle_wait` reads
`config_get '.orchestrator.external_signal_budget.max_attempts // empty'` and
the matching `max_minutes` key.

### A-010 — `~/code/twinning-harness/.pipeline-config/config.json::orchestrator` block

Verified by `jq '.orchestrator' .pipeline-config/config.json` (in the harness's
own `.pipeline-config/`): currently holds keys `paused`,
`max_concurrent_features`, `alert_on_halted_over`. Adding
`external_signal_budget: {max_attempts: 12, max_minutes: 60}` is additive — no
existing key is touched. Default `null`/missing/`{}` means "no limit, retry
forever" (operator opt-out for long-running CI farms).

### A-011 — `AGENT_PROMPTS.md` §7 P2 prose (current location of the operator-facing lie)

Current text at `AGENT_PROMPTS.md:1067-1072`:

```text
  P2. **Review was approved by a non-bot Code Owner** (bot self-approval does NOT count):
        gh pr view <N> --json reviews --jq \
          '[.reviews[] | select(.state == "APPROVED" and (.author.login | test("\\[bot\\]$") | not))] | length >= 1'
      If this returns false, the PR is not ready; do NOT merge. Post a Linear
      comment noting "awaiting human Code Owner approval" and exit. The
      orchestrator will retry on the next tick.
```

Replaced verbatim by Task 6 — see §3.4 in the brainstorm for the exact
replacement string.

### A-012 — `AGENT_PROMPTS.md` §7 P5 prose

Current text at `AGENT_PROMPTS.md:1082-1088`:

```text
  P5. **CI is green** (all required checks passed on latest commit):
        gh pr checks <N> --watch --required
      If the command exits 0 with no output, no required checks are configured —
      treat P5 as PASSING and proceed. Fail only if a required check is red or
      cancelled. Flaky checks count as red — re-run via
      `gh run rerun --failed <run-id>` up to 2 times; after that, file a Linear
      bug and loop back.
```

Replaced by Task 6 with the wait variant (reason `awaiting-ci`). The two-rerun
cap is in-tick retry behavior and stays as-is — independent of the new
between-tick wait counter.

### A-013 — `AGENT_PROMPTS.md` §7 verdict-marker exit table

Current text at `AGENT_PROMPTS.md:1185-1191`:

```text
- Post exactly ONE additional append-only comment with your verdict marker:
    - merged and CI green → `<!-- pipeline-stage-summary: building -->`
    - blocked-by-conflict or CI red → `<!-- pipeline-rejection: building --><!-- pipeline-rejection-target: implementing -->`
    - halt-for-human (missing approval, WIP label, etc.) → `<!-- pipeline-halt: agent-blocked -->`
```

Task 6 inserts a fourth bullet for the wait shape and updates the
"halt-for-human" bullet's parenthetical to drop "missing approval" (now a wait
case) and add only hard-fail examples (e.g., budget-exhausted is
orchestrator-applied, not agent-applied).

### A-014 — `AGENT_PROMPTS.md` Verdict-marker protocol preamble

Current location at `AGENT_PROMPTS.md:38-54`. Task 6 adds a new
"**Non-verdict markers**" subsection *after* the existing verdict table (i.e.,
after line 54) documenting `pipeline-wait` separately. Kept structurally
distinct from the verdict table to prevent future agent authors from confusing
"wait" with a verdict shape.

### A-015 — Test sentinel pattern

Current code at `bin/run-stage.sh:600-602`:

```bash
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
```

Not modified. The new `_fresh_wait_reason` and `_handle_wait` helpers will be
defined inside `run-stage.sh` (above `main`) and exported by sourcing — the
existing test pattern in `bin/run-stage-test.sh:67-74` (source common.sh +
classify-failure.sh + run-stage.sh, then call the function) reaches them
identically.

### A-016 — `bin/poll-slot-test.sh` stub conventions

Verified at `bin/poll-slot-test.sh:62-80`: linear.sh stub reads fixture JSONs
keyed by subcommand from `$FIXTURE_DIR`. `get-comments` reads
`$FIXTURE_DIR/comments-<issue>.json`, which is the test-injection point for
fresh-marker fixtures. Test additions follow the existing case-N convention
inline in the same file.

### A-017 — `bin/metrics.sh stage-end` accepts arbitrary outcome strings

Current code at `bin/metrics.sh:20-67`: outcome is a free-form string field
serialised straight into the events.jsonl record; no allow-list. New outcome
literal `soft-pending` is a one-string change, no schema migration needed.
Retrospective filter compatibility is tracked as Open Question Q2 in the
brainstorm — the implementation agent verifies it during Task 8 (see Test
Strategy).

### A-018 — `bin/run-stage.sh::main` `t0` and `skip_dispatch` are in scope at the new gate

Verified by reading `bin/run-stage.sh:295-477`: `main()` declares
`local t0; t0="$(date +%s)"` near the top of dispatch, and
`local skip_dispatch=0` at line 334 before any path that could reach line 477.
Both variables are available where the new wait gate is inserted.

## File Structure

```
bin/
  run-stage.sh                 modified  — add _fresh_wait_reason + _handle_wait helpers; insert wait gate at line 477; add wait-file cleanup at line 575
  run-stage-test.sh            modified  — append cases for wait exit, budget exhaustion, success clears counter, build-only gate, reason allow-list, get-comments read-failure fail-closed, P6 regression
  poll-slot-test.sh            modified  — append case: stage:building + no halt + only pipeline-wait fresh comment → hold,advanceable=true
  verdict-handler-test.sh      modified  — append case: find_fresh_verdict returns empty when only pipeline-wait marker is present

AGENT_PROMPTS.md               modified  — §7 P2 + P5 wait paths; §7 exit-table fourth row; preamble "Non-verdict markers" subsection; §7 precondition-ordering clause

docs/
  plans/2026-04-28-eng-45-build-agent-soft-preconditions-p2-p5-should-re-dispatch-not-halt-for-human.md   NEW (this file)
```

No changes to `bin/poll.sh`, `bin/verdict-handler.sh`, `bin/classify-failure.sh`,
`bin/linear.sh`, `bin/dispatch.sh`, `bin/metrics.sh`, `bin/common.sh`. Per
brainstorm §3.1, the fix is additive in `run-stage.sh` + `AGENT_PROMPTS.md` only.

The `config.json::orchestrator.external_signal_budget` key is per-installation
state (not in this repo). The implementation agent does NOT add it to any
checked-in config; behavior with the key absent (no limit, retry forever) is
explicitly tested. Operator can add `{"max_attempts": 12, "max_minutes": 60}`
to `~/code/twinning-harness/.pipeline-config/config.json::orchestrator` after
merge to opt into the default budget.

## Command API Contract

No new Tauri command API. This change is bash-only (the harness is shell
orchestration, not a Tauri app — see `CLAUDE.md` "What this repo is").

Operator-facing surface changes:
- One new comment shape posted by the build agent: `<!-- pipeline-wait: <reason> -->`
  with reason ∈ `{awaiting-approval, awaiting-ci}`. Posted via
  `bash .pipeline/bin/linear.sh add-comment …` (append-only, see brainstorm D-002).
- One new orchestrator-applied halt reason: `external-signal-budget-exhausted`
  (replaces `agent-blocked` only on budget timeout — first-attempt halts on
  hard preconditions still use `agent-blocked`).
- One new optional config key: `.orchestrator.external_signal_budget`
  (object with `max_attempts: int`, `max_minutes: int`; either or both may be
  absent / `null` / missing-object → "retry forever").

The CLI surface for operators (`bin/halt.sh resolve`, `bin/run-stage.sh`,
`bin/run-local.sh`) is unchanged. Per brainstorm D-008.

## Backend Tasks

(Bash harness — no Tauri/Rust backend.)

### Task 1: Add `_fresh_wait_reason` helper to `bin/run-stage.sh`

- `depends_on: []`
- `touches: bin/run-stage.sh::_fresh_wait_reason (new helper)`

- [ ] Add the helper above `main()` in `bin/run-stage.sh` (a good site is
  immediately after `_cost_flags_for` and before `main()`; locate by
  grepping for `^main()` and insert above the matching line).

```bash
# ENG-45: Returns the wait reason on stdout (exit 0) iff a fresh, well-formed,
# build-only `<!-- pipeline-wait: <reason> -->` marker exists newer than the
# most recent pipeline-transition. Else prints empty + nonzero. Build-only
# gate (security F-1); closed reason allow-list (security F-2). Fail-closed on
# Linear read failure: nonzero exit OR empty output from get-comments → return 1.
_fresh_wait_reason() {
  local issue="$1" stage="$2"
  [[ "$stage" == "build" ]] || return 1

  local comments
  comments="$(bash "$SCRIPT_DIR/linear.sh" get-comments "$issue" 2>/dev/null)" || return 1
  [[ -z "$comments" || "$comments" == "null" ]] && return 1

  local last_t
  last_t="$(jq -r '
    [.[] | select(.body | contains("<!-- pipeline-transition:"))]
    | sort_by(.createdAt) | last | .createdAt // ""' <<<"$comments")"
  local fresh
  fresh="$(jq -r --arg t "$last_t" '
    [.[] | select(.createdAt > $t)
         | select(.body | test("<!-- pipeline-wait: "))]
    | sort_by(.createdAt) | last // empty | .body // ""' <<<"$comments")"
  [[ -z "$fresh" ]] && return 1

  local reason
  reason="$(grep -oE '<!-- pipeline-wait: [a-z-]+ -->' <<<"$fresh" \
    | head -1 | sed -E 's/<!-- pipeline-wait: ([a-z-]+) -->/\1/')"

  case "$reason" in
    awaiting-approval|awaiting-ci) printf '%s' "$reason"; return 0 ;;
    *) return 1 ;;
  esac
}
```

- [ ] Run the existing test suite to confirm sourcing still succeeds:
  `bash bin/run-stage-test.sh`. Expected: tests pass exactly as today (no new
  cases yet — Task 7 adds them).

### Task 2: Add `_handle_wait` helper to `bin/run-stage.sh`

- `depends_on: [1]` (lives next to `_fresh_wait_reason`)
- `touches: bin/run-stage.sh::_handle_wait (new helper)`

- [ ] Add the helper immediately below `_fresh_wait_reason`. Returns 0 = within
  budget, no halt (caller exits 0). Returns 1 = budget exhausted, halt was
  applied (caller falls through to defensive halt-add (no-op) and verdict_handler
  which preserves the halt). Per brainstorm D-005, the escalation halt reason is
  `external-signal-budget-exhausted` (distinct from `agent-blocked`).

```bash
# ENG-45: idempotent counter mutation + budget check for wait exits. All Linear
# writes inside this function go through the orchestrator lane (security F-4).
# State file at $(issue_dir)/wait-${stage}.json is owned by the orchestrator
# (per ENG-18 separation between agent signals and orchestrator-owned state).
_handle_wait() {
  local PIPELINE_WRITER=orchestrator
  export PIPELINE_WRITER

  local ident="$1" stage="$2" reason="$3"
  local f; f="$(issue_dir "$ident")/wait-${stage}.json"
  local now; now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # Clear any stale stage-summary file so a later post_completion_comment
  # cannot post stale content from a prior dispatch.
  rm -f "$(issue_dir "$ident")/stage-summary-${stage}.md" 2>/dev/null || true

  local first attempts
  if [[ -s "$f" ]] && jq -e . "$f" >/dev/null 2>&1; then
    first="$(jq -r '.first_attempt_at // ""' "$f")"
    attempts="$(jq -r '.attempts // 0' "$f")"
    # Field-validity guard (security F-3): regex-validate first_attempt_at
    # before feeding it to date -j -f. An attacker-controlled file (crafted
    # via the agent's Write tool) cannot reach the arithmetic substitution.
    if [[ ! "$first" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
      first="$now"; attempts=0
    fi
    [[ "$attempts" =~ ^[0-9]+$ ]] || attempts=0
    attempts=$((attempts + 1))
  else
    first="$now"; attempts=1
  fi

  local body tmp
  body="$(jq -cn --arg i "$ident" --arg s "$stage" --arg r "$reason" \
                --arg fa "$first" --arg la "$now" --argjson n "$attempts" '
    {issue:$i, stage:$s, reason:$r, attempts:$n,
     first_attempt_at:$fa, last_attempt_at:$la}')"
  tmp="${f}.tmp.$$"; printf '%s' "$body" > "$tmp"; mv -f "$tmp" "$f"

  local max_a max_m
  max_a="$(config_get '.orchestrator.external_signal_budget.max_attempts // empty')"
  max_m="$(config_get '.orchestrator.external_signal_budget.max_minutes  // empty')"
  [[ "$max_a" == "null" ]] && max_a=""
  [[ "$max_m" == "null" ]] && max_m=""

  local exhausted=0
  [[ -n "$max_a" && "$max_a" =~ ^[0-9]+$ ]] && (( attempts >= max_a )) && exhausted=1
  if [[ -n "$max_m" && "$max_m" =~ ^[0-9]+$ ]]; then
    local first_epoch elapsed_m
    first_epoch="$(date -j -f %Y-%m-%dT%H:%M:%SZ "$first" +%s 2>/dev/null || printf '')"
    if [[ -n "$first_epoch" ]]; then
      elapsed_m=$(( ($(date -u +%s) - first_epoch) / 60 ))
      (( elapsed_m < 0 )) && elapsed_m=0   # clock-skew guard
      (( elapsed_m >= max_m )) && exhausted=1
    fi
  fi

  if (( exhausted )); then
    local halt_body
    halt_body="$(printf '<!-- pipeline-halt: external-signal-budget-exhausted -->\n\nBuild stage halted: %s budget exhausted (%d attempts since %s).\n\n**Resume:** approve the PR as a non-bot Code Owner, then run `bash bin/halt.sh resolve %s --decision resume`. Or raise `orchestrator.external_signal_budget.max_attempts` / `max_minutes` in `.pipeline-config/config.json` to extend the window.' \
                "$reason" "$attempts" "$first" "$ident")"
    bash "$SCRIPT_DIR/linear.sh" add-comment "$ident" "$halt_body" || true
    # Only delete the wait file if the halt label actually applied. A network
    # blip on add-label could otherwise leave the issue with no halt label AND
    # no counter file — the next dispatch would start a brand-new wait window
    # at attempts=1, silently bypassing the budget safety net. Preserving the
    # file means the next dispatch retries the escalation atomically.
    if bash "$SCRIPT_DIR/linear.sh" add-label "$ident" "pipeline:halted"; then
      rm -f "$f"
    else
      log "WARN: pipeline:halted apply failed for $ident at budget exhaust; preserving $f for retry"
    fi
    return 1
  fi
  return 0
}
```

- [ ] Re-run `bash bin/run-stage-test.sh`. Expected: still passes.

### Task 3: Insert wait-detection gate at `bin/run-stage.sh:477`

- `depends_on: [1, 2]`
- `touches: bin/run-stage.sh::main (line 477 insertion only)`

- [ ] Insert the wait gate **immediately before** the existing
  `if (( ! skip_dispatch )); then` block at line 477 (the agent-contract
  validator). Per brainstorm §3.3, the gate must run BEFORE the validator,
  defensive halt-add, and verdict_handler, all three of which would otherwise
  trip on a legitimate wait exit (no summary file, no verdict marker).

```bash
  # ENG-45: wait exit. Build agent posts <!-- pipeline-wait: <reason> --> on
  # P2/P5 failures so the orchestrator re-dispatches next tick instead of
  # halting. Detect BEFORE the agent-contract validator at the next block.
  if (( ! skip_dispatch )); then
    local _sp_reason
    _sp_reason="$(_fresh_wait_reason "$ident" "$stage" 2>/dev/null || printf '')"
    if [[ -n "$_sp_reason" ]]; then
      if _handle_wait "$ident" "$stage" "$_sp_reason"; then
        bash "$SCRIPT_DIR/metrics.sh" stage-end "$ident" "$stage" "soft-pending" \
          "$(( ($(date +%s) - t0) * 1000 ))" "reason=$_sp_reason" || true
        log "stage $stage wait on $ident (reason=$_sp_reason)"
        exit 0
      fi
      # Budget exhausted: pipeline:halted was applied by _handle_wait.
      # Fall through to defensive halt-add (now a no-op, label already set)
      # and verdict_handler, which preserves the halt and emits
      # halt-for-human metrics naturally.
    fi
  fi
```

- [ ] Confirm placement: the very next block in the file should be the
  existing `if (( ! skip_dispatch )); then ... agent-contract validator`
  block (`bin/run-stage.sh:477-490` pre-edit, now shifted down by the
  insertion). Do NOT modify the validator block.

- [ ] Note (intentional cascade-skip): the `exit 0` in this gate also
  bypasses `push_branch_if_ahead` (~line 498), `post_completion_comment`
  (~line 506), the stage-drift guard (~lines 514-537), and `verdict_handler`
  (~line 555). This is correct: the agent posted no commits (no branch to
  push), no stage-summary file (no completion comment to post), no verdict
  marker (verdict_handler would posthumously synthesize a protocol
  violation), and stage-drift is re-checked on the next tick when
  re-dispatched. Do NOT add code to wire any of these calls into the wait
  exit path.

- [ ] Re-run `bash bin/run-stage-test.sh`. Expected: still passes (no test
  case yet exercises the wait path; that lands in Task 7).

### Task 4: Add wait-file cleanup on success path

- `depends_on: [3]`
- `touches: bin/run-stage.sh::main (success branch around line 575)`

- [ ] In the `case "$vh_rc" in 0)` arm at `bin/run-stage.sh:574-585`, add a
  single line immediately after the existing `rm -f
  "$(issue_dir "$ident")/issue-state.json"` cleanup at line 575:

```bash
      rm -f "$(issue_dir "$ident")/wait-${stage}.json" 2>/dev/null || true
```

- [ ] Re-run `bash bin/run-stage-test.sh`. Expected: still passes.

### Task 5: Commit Tasks 1–4 as a single bash-only commit

- `depends_on: [1, 2, 3, 4]`
- `touches: bin/run-stage.sh`

- [ ] Stage and commit: `bin/run-stage.sh` only.

```bash
git add bin/run-stage.sh
git commit -m "feat(ENG-45): add wait-marker gate + budget escalation to run-stage.sh"
```

The prompt and test changes ship as separate commits (Tasks 6, 7-10) so a
bisect can isolate behavior changes from prompt copy.

### Task 6: Update `AGENT_PROMPTS.md` §7 (build) + Verdict-marker preamble

- `depends_on: [5]`
- `touches: AGENT_PROMPTS.md`

- [ ] Insert the precondition-ordering clause as a NEW MANDATORY sentence
  (security F-1 in the brainstorm) prepended to the §7 P2 spec (above
  current line 1067). Without this clause, the agent could enter the wait
  branch on a mixed soft+hard precondition failure (e.g., P2 missing AND
  P3 CHANGES_REQUESTED), causing the orchestrator to re-dispatch forever
  on a hard failure. Per brainstorm §3.4:

```text
If P1, P3, P4, P6, or P7 fail, post the existing hard-halt marker
(`pipeline-halt: agent-blocked`) and exit. The wait path below applies
ONLY when every other precondition has passed and the only failure is
P2 or P5.
```

- [ ] Replace the §7 P2 final sentence at `AGENT_PROMPTS.md:1070-1072`
  ("If this returns false … retry on the next tick.") with the wait variant
  per brainstorm §3.4:

```text
If this returns false, the PR is not ready; do NOT merge. Confirm P1, P3,
P4, P6, P7 all passed (otherwise halt-for-human, see precondition-ordering
clause above). **Wait exit:** post (via `bash .pipeline/bin/linear.sh
add-comment`, append-only) a comment whose first line is exactly
`<!-- pipeline-wait: awaiting-approval -->` and whose body includes the
human-readable signature `awaiting-external/build/{issue_id}` and says:
"Awaiting human Code Owner approval. Will re-check on next tick. If
`orchestrator.external_signal_budget` is configured, will escalate to
halt-for-human after the budget exhausts; if not configured, will retry
indefinitely until approval lands." Do NOT apply `pipeline:halted`. Do NOT
post a verdict marker. Do NOT write a stage-summary file. Exit. The
orchestrator increments a per-issue counter and re-dispatches build on the
next tick; once the budget is exhausted (if configured) it escalates to
`pipeline-halt: external-signal-budget-exhausted` automatically.
```

- [ ] Apply the analogous wait variant to P5 at `AGENT_PROMPTS.md:1082-1088`.
  Use reason `awaiting-ci`. The existing `gh run rerun --failed` cap of 2
  remains as in-tick retry behavior — independent of the wait counter.

- [ ] Update the §7 verdict-marker exit table at
  `AGENT_PROMPTS.md:1185-1191`. Add a fourth bullet immediately after the
  three existing verdict bullets:

```text
    - awaiting external signal (P2 OR P5 only, all hard preconditions
      passed) → `<!-- pipeline-wait: awaiting-approval -->` or
      `<!-- pipeline-wait: awaiting-ci -->` (NOT a verdict shape — see
      "Non-verdict markers" in the protocol preamble)
```

  In the same table, narrow the existing "halt-for-human" bullet's
  parenthetical so missing approval is no longer named there:

```text
    - halt-for-human (WIP / blocked label, malformed PR title, etc.) →
      `<!-- pipeline-halt: agent-blocked -->`
```

- [ ] Append a new "**Non-verdict markers**" subsection to the
  Verdict-marker protocol preamble, immediately after the existing
  freshness-rule paragraph at `AGENT_PROMPTS.md:54`:

```text
### Non-verdict markers

Non-verdict markers communicate state OTHER than a stage outcome and are
NOT consumed by `verdict-handler.sh`. They are read by the orchestrator's
per-stage gates in `run-stage.sh`.

| Marker | Who posts | When | Meaning |
|---|---|---|---|
| `<!-- pipeline-wait: <reason> -->` | build agent only | external-signal precondition unmet (P2 / P5) | exit clean; orchestrator re-dispatches next tick until budget exhausts |
```

- [ ] Verify the AGENT_PROMPTS.md fence-count contract (each H2 stage section
  has exactly one fenced ``` block — see `CLAUDE.md` "AGENT_PROMPTS.md is
  load-bearing"): run `bash bin/dry-run.sh` and confirm it succeeds. The
  dry-run validator extracts every stage's fenced block via
  `bin/render-prompt.sh` and dies on a fence-count mismatch.

- [ ] Stage and commit:

```bash
git add AGENT_PROMPTS.md
git commit -m "feat(ENG-45): rewrite build §7 P2/P5 wait paths + add Non-verdict markers preamble"
```

### Task 7: Add `_fresh_wait_reason` unit cases to `bin/run-stage-test.sh`

- `depends_on: [5]`
- `touches: bin/run-stage-test.sh`

- [ ] Append a new section at the end of `bin/run-stage-test.sh` (above the
  existing `printf 'PASS=%d ...'` summary footer if present, else at the end
  of the test cases). Each case follows the existing `reset_capture` /
  `pass_at` / `fail_at` idiom. Use the existing `linear.sh` stub by injecting
  a fixture-style comments JSON via an env override of the `get-comments`
  subcommand path — easiest is to write a wrapper that sets a `COMMENTS_JSON`
  env var the stub reads. Concretely, replace the inline linear.sh stub at
  `bin/run-stage-test.sh:20-27` with one that handles `get-comments` by
  echoing `${MOCK_COMMENTS_JSON:-[]}`:

```bash
cat > "$STUB_DIR/linear.sh" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  get-comments) printf '%s' "\${MOCK_COMMENTS_JSON:-[]}" ;;
  *)
    printf 'SUBCMD=%s\nSIG=%s\nIDENT=%s\nBODY_BEGIN\n%s\nBODY_END\n---\n' \
      "\${1:-}" "\${2:-}" "\${3:-}" "\${4:-}" >> "$CAPTURE_FILE"
    ;;
esac
exit 0
SH
```

- [ ] Add the unit cases:

```bash
# ─── ENG-45 case A: fresh wait marker on build → returns reason ─────────
export MOCK_COMMENTS_JSON='[{"createdAt":"2026-04-28T08:17:00Z","body":"<!-- pipeline-wait: awaiting-approval -->\n\nAwaiting human Code Owner approval."}]'
out="$(_fresh_wait_reason ENG-45T1 build || printf '')"
if [[ "$out" == "awaiting-approval" ]]; then
  pass_at "ENG-45 case A: fresh wait marker → returns awaiting-approval"
else
  fail_at "ENG-45 case A" "got: $out"
fi

# ─── ENG-45 case B: stage != build → empty (build-only gate) ────────────
out="$(_fresh_wait_reason ENG-45T2 review || printf '')"
[[ -z "$out" ]] && pass_at "ENG-45 case B: review stage rejected by build-only gate" \
                || fail_at "ENG-45 case B" "got: $out"

# ─── ENG-45 case C: invented reason rejected by allow-list ──────────────
export MOCK_COMMENTS_JSON='[{"createdAt":"2026-04-28T08:17:00Z","body":"<!-- pipeline-wait: never-escalate -->"}]'
out="$(_fresh_wait_reason ENG-45T3 build || printf '')"
[[ -z "$out" ]] && pass_at "ENG-45 case C: invented reason rejected" \
                || fail_at "ENG-45 case C" "got: $out"

# ─── ENG-45 case D: wait marker older than last pipeline-transition → empty ─
export MOCK_COMMENTS_JSON='[
  {"createdAt":"2026-04-28T08:00:00Z","body":"<!-- pipeline-wait: awaiting-approval -->"},
  {"createdAt":"2026-04-28T08:05:00Z","body":"<!-- pipeline-transition: implementing → building -->"}
]'
out="$(_fresh_wait_reason ENG-45T4 build || printf '')"
[[ -z "$out" ]] && pass_at "ENG-45 case D: stale wait pre-transition is ignored" \
                || fail_at "ENG-45 case D" "got: $out"

# ─── ENG-45 case E: get-comments empty stdout → fail-closed (return 1) ─
export MOCK_COMMENTS_JSON=''
out="$(_fresh_wait_reason ENG-45T5 build || printf '')"
[[ -z "$out" ]] && pass_at "ENG-45 case E: empty get-comments fails closed" \
                || fail_at "ENG-45 case E" "got: $out"

# ─── ENG-45 case F: get-comments returns "null" → fail-closed (return 1) ─
export MOCK_COMMENTS_JSON='null'
out="$(_fresh_wait_reason ENG-45T6 build || printf '')"
[[ -z "$out" ]] && pass_at "ENG-45 case F: null get-comments fails closed" \
                || fail_at "ENG-45 case F" "got: $out"

unset MOCK_COMMENTS_JSON
```

- [ ] Run `bash bin/run-stage-test.sh`. Expected: 6 new PASS lines for cases
  A–F; previous cases unchanged.

### Task 8: Add `_handle_wait` unit cases to `bin/run-stage-test.sh`

- `depends_on: [7]`
- `touches: bin/run-stage-test.sh`

- [ ] Add cases that exercise the counter increment, atomic write, budget
  exhaustion at attempts cap, budget exhaustion at wall-clock cap,
  field-validity guard, and the success-path file deletion. Use a temporary
  `CONFIG` jq-target set to a fixture file with the desired budget shape.

```bash
# ─── ENG-45 case G: first wait → attempts=1, file written, returns 0 ────
ENG_45_TMP_CFG="$(mktemp)"
printf '{"orchestrator":{}}' > "$ENG_45_TMP_CFG"
CONFIG="$ENG_45_TMP_CFG"
mkdir -p "$(issue_dir ENG-45T7)"
rm -f "$(issue_dir ENG-45T7)/wait-build.json"
if _handle_wait ENG-45T7 build awaiting-approval; then
  jq -e '.attempts == 1 and .reason == "awaiting-approval"' \
    "$(issue_dir ENG-45T7)/wait-build.json" >/dev/null \
    && pass_at "ENG-45 case G: first wait writes attempts=1, returns 0" \
    || fail_at "ENG-45 case G" "json: $(cat "$(issue_dir ENG-45T7)/wait-build.json")"
else
  fail_at "ENG-45 case G" "_handle_wait returned nonzero on first attempt"
fi

# ─── ENG-45 case H: 2nd wait increments attempts to 2 ───────────────────
if _handle_wait ENG-45T7 build awaiting-approval; then
  jq -e '.attempts == 2' "$(issue_dir ENG-45T7)/wait-build.json" >/dev/null \
    && pass_at "ENG-45 case H: 2nd wait increments to 2" \
    || fail_at "ENG-45 case H" "json: $(cat "$(issue_dir ENG-45T7)/wait-build.json")"
fi

# ─── ENG-45 case I: budget=2 attempts → 2nd call exhausts (returns 1) ───
printf '{"orchestrator":{"external_signal_budget":{"max_attempts":2}}}' > "$ENG_45_TMP_CFG"
mkdir -p "$(issue_dir ENG-45T8)"
rm -f "$(issue_dir ENG-45T8)/wait-build.json"
_handle_wait ENG-45T8 build awaiting-approval  # first call returns 0
if _handle_wait ENG-45T8 build awaiting-approval; then
  fail_at "ENG-45 case I" "expected nonzero on 2nd call (budget exhausted)"
else
  [[ ! -e "$(issue_dir ENG-45T8)/wait-build.json" ]] \
    && pass_at "ENG-45 case I: budget exhausted → wait file deleted, returned 1" \
    || fail_at "ENG-45 case I" "wait file should have been deleted"
fi

# ─── ENG-45 case J: corrupt first_attempt_at resets the window ──────────
printf '{"orchestrator":{}}' > "$ENG_45_TMP_CFG"
mkdir -p "$(issue_dir ENG-45T9)"
printf '{"first_attempt_at":"NOT-A-DATE","attempts":99}' > "$(issue_dir ENG-45T9)/wait-build.json"
_handle_wait ENG-45T9 build awaiting-approval >/dev/null
jq -e '.attempts == 0 or .attempts == 1' \
  "$(issue_dir ENG-45T9)/wait-build.json" >/dev/null \
  && pass_at "ENG-45 case J: corrupt timestamp resets counter" \
  || fail_at "ENG-45 case J" "json: $(cat "$(issue_dir ENG-45T9)/wait-build.json")"

# ─── ENG-45 case K: wall-clock cap exhausts even when attempts < cap ────
# Pre-write a wait file dated 2 minutes in the past; max_minutes=1 should
# trip exhaustion on the next call regardless of the attempts cap.
printf '{"orchestrator":{"external_signal_budget":{"max_minutes":1}}}' > "$ENG_45_TMP_CFG"
mkdir -p "$(issue_dir ENG-45T10)"
two_min_ago="$(date -u -j -v-2M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
              || date -u -d '2 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"
printf '{"first_attempt_at":"%s","attempts":1}' "$two_min_ago" \
  > "$(issue_dir ENG-45T10)/wait-build.json"
if _handle_wait ENG-45T10 build awaiting-approval; then
  fail_at "ENG-45 case K" "wall-clock cap should have exhausted; got within-budget"
else
  pass_at "ENG-45 case K: wall-clock cap exhausts (attempts < cap, elapsed >= max_minutes)"
fi

# ─── ENG-45 case M: stale stage-summary file is deleted on wait entry ───
# Load-bearing: prevents post_completion_comment from posting stale content
# from a prior dispatch into the next tick's wait window.
printf '{"orchestrator":{}}' > "$ENG_45_TMP_CFG"
mkdir -p "$(issue_dir ENG-45T11)"
rm -f "$(issue_dir ENG-45T11)/wait-build.json"
printf 'STALE CONTENT FROM PRIOR DISPATCH\n' > "$(issue_dir ENG-45T11)/stage-summary-build.md"
_handle_wait ENG-45T11 build awaiting-approval >/dev/null
[[ ! -e "$(issue_dir ENG-45T11)/stage-summary-build.md" ]] \
  && pass_at "ENG-45 case M: stale stage-summary-build.md deleted on wait entry" \
  || fail_at "ENG-45 case M" "stale summary file still present"

rm -f "$ENG_45_TMP_CFG"
```

- [ ] Run `bash bin/run-stage-test.sh`. Expected: cases G, H, I, J, K, M pass.

### Task 8a: Add P6 (merge conflict) regression case to `bin/run-stage-test.sh`

- `depends_on: [1, 3, 7]` (Task 1 defines `_fresh_wait_reason`; Task 3 inserts the gate; Task 7 adds the `MOCK_COMMENTS_JSON` stub)
- `touches: bin/run-stage-test.sh`

This case is required by the Linear issue's IN list ("Regression: P6 (merge
conflict) still loops back to `stage:implementing` via
`pipeline-rejection: building`") and the brainstorm §3.1 test row. The
plan's wait gate must NOT fire on a rejection-marker-only fixture — the
existing rejection loopback flow must remain reachable.

- [ ] Append the following case (uses the same `MOCK_COMMENTS_JSON`
  injection point added in Task 7):

```bash
# ─── ENG-45 case P6: rejection marker present, wait gate must NOT fire ──
export MOCK_COMMENTS_JSON='[
  {"createdAt":"2026-04-28T08:00:00Z","body":"<!-- pipeline-transition: implementing → building -->"},
  {"createdAt":"2026-04-28T08:17:00Z","body":"<!-- pipeline-rejection: building -->\n<!-- pipeline-rejection-target: implementing -->\nMerge conflict on rebase."}
]'
out="$(_fresh_wait_reason ENG-45T-P6 build || printf '')"
[[ -z "$out" ]] \
  && pass_at "ENG-45 case P6: rejection marker is invisible to wait gate" \
  || fail_at "ENG-45 case P6" "wait gate spuriously matched: $out"
unset MOCK_COMMENTS_JSON
```

- [ ] Run `bash bin/run-stage-test.sh`. Expected: case P6 passes; the
  rejection loopback path remains reachable through the existing
  agent-contract validator and verdict_handler.

### Task 9: Add `bin/poll-slot-test.sh` regression case for the wait path

- `depends_on: []` (parallelisable with Tasks 1-8)
- `touches: bin/poll-slot-test.sh`

- [ ] Append a case that asserts the load-bearing claim from A-004:
  `_poll_classify_labels` returns `slot=hold, advanceable=true` for an
  issue with `stage:building`, no `pipeline:halted`, and a fresh
  `pipeline-wait` comment as the only freshest non-transition comment.
  Use the existing `write_comments_fixture` helper (defined at
  `bin/poll-slot-test.sh:210`); its signature is
  `write_comments_fixture <issue_id> <body|createdAt>...` (verified at the
  helper's docstring on line 208 and existing call sites at lines 252-254,
  276-278, 376). The label-fixture helper `write_label_fixture` (line 159)
  takes pipe-delimited specs of the form `<ident>|<state>|<priority>|<labels>`
  (verified at line 374-375). Test the classifier directly by calling
  `_poll_classify_labels` with a synthesized labels JSON — this is the
  cleanest unit test of the load-bearing else-branch behavior.

```bash
# ─── ENG-45: stage:building + only pipeline-wait fresh → hold,advanceable=true
write_comments_fixture "ENG-45" \
  '<!-- pipeline-transition: implementing → building -->|2026-04-28T08:00:00Z' \
  '<!-- pipeline-wait: awaiting-approval -->|2026-04-28T08:17:00Z'

out="$(_poll_classify_labels "ENG-45" '["stage:building"]')"
slot="$(jq -r '.slot' <<<"$out")"
adv="$(jq -r '.advanceable' <<<"$out")"
if [[ "$slot" == "hold" && "$adv" == "true" ]]; then
  pass_at "ENG-45 poll-slot: pipeline-wait re-dispatches via else branch (hold,advanceable=true)"
else
  fail_at "ENG-45 poll-slot" "got slot=$slot adv=$adv (want hold/true)"
fi
```

- [ ] Run `bash bin/poll-slot-test.sh`. Expected: new case passes alongside
  the existing case set.

### Task 10: Add `bin/verdict-handler-test.sh` regression case

- `depends_on: []` (parallelisable with Tasks 1-9)
- `touches: bin/verdict-handler-test.sh`

- [ ] Append a case that constructs a fixture with **only** a fresh
  `pipeline-wait` marker (no stage-summary, rejection, or halt markers) and
  asserts `find_fresh_verdict` returns the empty string. This is the
  load-bearing regression — the entire design depends on
  `find_fresh_verdict` NOT matching `pipeline-wait`. Use the existing
  `mk_fixture` helper (line 89) and `VH_FIXTURE_COMMENTS` env var (consumed
  by the inline linear.sh stub at line 38).

```bash
# ─── ENG-45: pipeline-wait alone is not a verdict shape ─────────────────
VH_FIXTURE_COMMENTS="$(mk_fixture \
  '<!-- pipeline-transition: implementing → building -->|2026-04-28T08:00:00Z' \
  '<!-- pipeline-wait: awaiting-approval -->|2026-04-28T08:17:00Z')"
export VH_FIXTURE_COMMENTS
result="$(find_fresh_verdict ENG-45-WAIT 2>/dev/null || printf '')"
[[ -z "$result" ]] \
  && pass_at "ENG-45: find_fresh_verdict ignores pipeline-wait marker" \
  || fail_at "ENG-45 verdict-handler" "got: $result"
unset VH_FIXTURE_COMMENTS
```

- [ ] Run `bash bin/verdict-handler-test.sh`. Expected: new case passes
  (and confirms the load-bearing claim in A-005 that `pipeline-wait` is
  invisible to `find_fresh_verdict`).

### Task 11: Verify retrospective filter accepts new outcome name (or note follow-up)

- `depends_on: [5]`
- `touches: (verification only — no code changes if filter already accepts arbitrary outcomes)`

- [ ] Read `bin/run-retrospective-local.sh` and `bin/metrics.sh` to confirm
  that the retrospective §1 outcome filter does NOT silently drop unknown
  outcome names. If it does, file a follow-up issue (do NOT widen the filter
  in this PR — that is OUT of scope per brainstorm §9). If it accepts
  arbitrary strings (likely, since `metrics.sh` writes outcome as a free-form
  string per `bin/metrics.sh:67`), no action — note in the implement-stage
  summary.

- [ ] If a follow-up is needed, post a Linear comment on ENG-45 referencing
  it before exiting the implement stage. Do NOT block merge on it.

### Task 12: Commit tests + final stage

- `depends_on: [7, 8, 8a, 9, 10]`
- `touches: bin/run-stage-test.sh, bin/poll-slot-test.sh, bin/verdict-handler-test.sh`

- [ ] Stage and commit:

```bash
git add bin/run-stage-test.sh bin/poll-slot-test.sh bin/verdict-handler-test.sh
git commit -m "test(ENG-45): wait-marker, budget exhaustion, P6 rejection regression, poll-slot and verdict-handler regressions"
```

- [ ] Run all three test files to confirm green:

```bash
bash bin/run-stage-test.sh
bash bin/poll-slot-test.sh
bash bin/verdict-handler-test.sh
```

Expected: every test file ends with `PASS=N FAIL=0`.

## Frontend Tasks

N/A. The harness has no SvelteKit / Tauri / web UI. Operator-facing surface
changes (one new comment shape, one new halt reason, one new optional config
key) ship via `AGENT_PROMPTS.md` updates in Task 6 and the design's prose
in `docs/brainstorms/`.

## Failure Mode → Test Map

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
| --- | --- | --- | --- | --- |
| Missing non-bot Code Owner approval (P2) | Build agent runs P2; gh returns 0 approvals | Agent posts `<!-- pipeline-wait: awaiting-approval -->`; orchestrator increments counter; exits 0 with `outcome=soft-pending`; pipeline:halted NOT applied | unit | `bin/run-stage-test.sh` cases A, G |
| CI not yet green (P5) | gh pr checks returns red on latest commit | Agent posts `<!-- pipeline-wait: awaiting-ci -->`; same orchestrator path as P2 | unit | `bin/run-stage-test.sh` case A (reason=awaiting-ci variant — added in Task 7) |
| Cross-stage marker forgery (review stage tries to use wait) | Wait marker present but stage != build | `_fresh_wait_reason` returns empty; falls through to existing agent-contract validator and halts as today | unit | `bin/run-stage-test.sh` case B |
| Invented or empty reason (e.g., `awaiting-doom` or empty) | Marker body has reason outside allow-list | `_fresh_wait_reason` returns empty; falls through to existing halt path | unit | `bin/run-stage-test.sh` case C |
| Stale wait marker (older than last pipeline-transition) | Wait comment posted before a fresh transition waypoint | `_fresh_wait_reason` returns empty (createdAt freshness rule) | unit | `bin/run-stage-test.sh` case D |
| Linear `get-comments` API failure (read-side fail-closed) | linear.sh exits nonzero or returns "null"/empty | `_fresh_wait_reason` returns empty → halt path fires (fail-closed) | unit | `bin/run-stage-test.sh` cases E, F |
| Budget exhausted by attempts cap | K-th wait dispatch with `max_attempts=K` | Orchestrator posts `<!-- pipeline-halt: external-signal-budget-exhausted -->`, applies `pipeline:halted`, deletes wait file, returns 1 from `_handle_wait` | unit | `bin/run-stage-test.sh` case I |
| Budget exhausted by wall-clock cap | wait-build.json `first_attempt_at` is older than `max_minutes` | Same escalation as attempts cap | unit | `bin/run-stage-test.sh` case K (pre-writes wait file dated 2 minutes ago with max_minutes=1; asserts `_handle_wait` returns 1) |
| Corrupt or attacker-controlled wait-build.json | first_attempt_at = "NOT-A-DATE" or attempts = "evil" | Field-validity regex resets to fresh window (attempts=0 or 1, first=now); never feeds bad input to `date -j -f` | unit | `bin/run-stage-test.sh` case J |
| Concurrent dispatch of the same issue | Two ticks race the same issue | Single-flight via `.claude-mutex.lock/` (existing harness invariant) prevents the race; atomic `mv -f tmp f` write makes the file write benign even if ever reached | (relies on existing harness invariant — no new test required; documented in error-handling §5) | n/a |
| Clock-skew on first_attempt_at | Host clock jumps backwards | `(( elapsed_m < 0 )) && elapsed_m=0` guard caps the negative; never escalates spuriously | unit | (covered by case J's regex guard; backward-clock branch is read-only fall-through) |
| Operator clears pipeline:halted after escalation | Operator removes pipeline:halted label manually | Next tick poll.sh:228 else branch fires; build re-dispatches; new wait window starts (counter is at 1, since wait file was deleted at escalation time) | integration | `bin/poll-slot-test.sh` ENG-45 case (verifies the else branch fires); the counter-deletion behavior is covered indirectly by case I's wait-file delete assertion |
| poll.sh classifies wait-only state as advanceable | stage:building + no halt + only pipeline-wait fresh | `_poll_classify_labels` returns `slot=hold,advanceable=true` (the soft-redispatch contract) | integration | `bin/poll-slot-test.sh` ENG-45 case |
| `find_fresh_verdict` accidentally matches pipeline-wait | Wait marker is the freshest comment | Returns empty string (jq filter only matches the three verdict shapes) | integration | `bin/verdict-handler-test.sh` ENG-45 case |
| P6 (merge conflict) regression | Hard-fail precondition on rebase | Agent posts `<!-- pipeline-rejection: building --><!-- pipeline-rejection-target: implementing -->`; the wait gate does NOT fire (no fresh `pipeline-wait` marker); the existing rejection flow continues unchanged | unit | `bin/run-stage-test.sh` ENG-45 case P6 (added by Task 8a) — asserts `_fresh_wait_reason` returns empty when only a `pipeline-rejection: building` marker is fresh, so the gate cleanly hands off to the existing post-dispatch path |
| Operator-resume regression: halt.sh resolve unchanged | Operator runs halt.sh resolve --decision resume | Existing halt-resolve flow proceeds as today | (regression — plan does not touch `bin/halt.sh`; the existing `bin/halt-sprawl-test.sh` exercises adjacent halt-resolve paths but no automated test covers `--decision resume` directly. Documentation-only assurance.) | (existing halt-sprawl-test cases) |
| Mixed soft + hard precondition failures (P2 missing AND P3 CHANGES_REQUESTED) | Both P2 (soft) and P3 (hard) fail | Agent posts hard halt (`agent-blocked`), NOT wait marker (per AGENT_PROMPTS.md precondition-ordering clause added in Task 6) | (prompt-level — verified by reading the rendered prompt; no test layer in bash since the agent is the LLM, not code under our test harness) | manual-review (verified during Task 6 commit) |
| Reason changes between two consecutive wait ticks (awaiting-ci → awaiting-approval) | CI passed, approval invalidated | wait-build.json key is per-stage, not per-reason; counter survives reason change (correct: budget is per (issue,stage)) | (covered implicitly by case G+H; reason-change variant is a pure data-flow consequence and would not produce new code paths) | (no new test required) |
| Config key absent / null / `{}` (operator opt-out) | `.orchestrator.external_signal_budget` is null or missing | `_handle_wait` returns 0 forever; orchestrator never escalates; operator can run the pipeline without bound | unit | `bin/run-stage-test.sh` case G (uses `{"orchestrator":{}}` config — verifies "no budget = retry forever" works) |
| Stale stage-summary file from prior dispatch | Earlier failed dispatch left stage-summary-build.md in issue_dir | `_handle_wait` `rm -f` clears it before exit | unit | `bin/run-stage-test.sh` case M (pre-writes a stage-summary-build.md fixture, calls `_handle_wait`, asserts the file is gone) |

Total mapped failure modes: 18 (16 with concrete test rows; one
covered-by-invariant — concurrent dispatch via the existing
`.claude-mutex.lock/`; one prompt-level — mixed soft+hard precondition
ordering — verified at Task 6 commit-time prompt review).

## Acceptance criteria traceability

The Linear issue's seven acceptance criteria each trace to a specific task or test:

| AC | Statement (paraphrase) | Realised by |
| --- | --- | --- |
| AC-1 | Build P2-only failure: NO `pipeline:halted`; NO `pipeline-halt: agent-blocked`; sig'd `awaiting-external/build/{issue}` comment posted | Task 6 (prompt rewrite); Task 1 (`_fresh_wait_reason`); Task 3 (wait gate); verified by `run-stage-test.sh` case A |
| AC-2 | With approval pending, the next launchd tick re-dispatches build | Task 3 (wait gate exits 0 without applying halt); verified by `poll-slot-test.sh` ENG-45 case (Task 9) |
| AC-3 | Once approval lands, the next build tick passes P2 and proceeds to merge | Task 6 (prompt unchanged for happy path); existing build-merge path (no plan changes); Task 4 cleanup deletes counter on success |
| AC-4 | After K consecutive wait attempts (default K=12, configurable via `.orchestrator.external_signal_budget.max_attempts` and/or `.max_minutes`), build escalates to `pipeline-halt: agent-blocked` (issue's wording) — implemented as the distinct reason `external-signal-budget-exhausted` per brainstorm D-005 | Task 2 (`_handle_wait` budget check + escalation comment); verified by `run-stage-test.sh` case I (attempts cap) and case K (wall-clock cap) |
| AC-5 | P5 (CI green) shares the soft re-dispatch path with P2; gh run rerun retries are independent of the wait counter (`.orchestrator.external_signal_budget.max_attempts`) | Task 6 (P5 prompt mirrors P2 with reason `awaiting-ci`); `_fresh_wait_reason` allow-list (Task 1) accepts both reasons; the existing `gh run rerun --failed` cap of 2 in the prompt is unchanged (in-tick retry only) |
| AC-6 | P6 (merge conflict) regression: still posts `<!-- pipeline-rejection: building --><!-- pipeline-rejection-target: implementing -->` | No plan changes to that path; verified by `run-stage-test.sh` case P6 (Task 8a) |
| AC-7 | Operator-resume regression: any pre-existing `pipeline:halted` clearing path is unchanged | File Structure declares no changes to `bin/halt.sh`, `bin/poll.sh`, `bin/verdict-handler.sh`; covered by the regression row in the Failure Mode table |

## Test Strategy

**Unit:** `bin/run-stage-test.sh` is the primary surface. Six cases for
`_fresh_wait_reason` (build-only gate, allow-list, freshness, fail-closed)
and four cases for `_handle_wait` (counter, atomic write, budget exhaustion,
corrupt-input guard). All cases use the existing source-and-stub pattern at
`bin/run-stage-test.sh:67-74`; `MOCK_COMMENTS_JSON` env var is the new
injection point added by Task 7's stub rewrite.

**Integration:** `bin/poll-slot-test.sh` exercises the
`_poll_classify_labels` else-branch with a wait-only comment fixture,
proving the load-bearing claim that the soft-redispatch flow already works
end-to-end through the poller. `bin/verdict-handler-test.sh` exercises
`find_fresh_verdict` against the same wait-only fixture, proving
`pipeline-wait` is invisible to the verdict pipeline. Each file uses its
own existing fixture helper: `write_comments_fixture` (poll-slot-test.sh
line 210) writes JSON fixtures keyed by issue id; `mk_fixture` plus the
`VH_FIXTURE_COMMENTS` env var (verdict-handler-test.sh lines 89, 38) is
the verdict-handler stub injection idiom.

**Smoke:** `bash bin/dry-run.sh` validates the AGENT_PROMPTS.md fence-count
contract after Task 6 (each H2 stage section has exactly one fenced ``` block
— see CLAUDE.md "AGENT_PROMPTS.md is load-bearing"). Runs at the end of Task
6 before the commit.

**Adversarial coverage intent (per CLAUDE.md test-design expectations):**
- **Cross-stage marker forgery** (case B): a wait marker on `stage=review`
  must not create a "snooze" primitive on stages outside scope. Build-only
  gate enforces.
- **Invented reason** (case C): closed allow-list rejects anything outside
  `{awaiting-approval, awaiting-ci}`.
- **Stale marker** (case D): freshness rule must use the same
  newer-than-last-pipeline-transition semantics as
  `find_fresh_verdict`; otherwise a wait comment posted before an earlier
  loopback could spuriously fire.
- **Read-side fail-closed** (cases E, F): a Linear API blip must not silently
  mask a real wait state into a halt-then-resume cycle would be acceptable;
  silent-mask into a forever-loop would not.
- **Corrupt JSON** (case J): hostile or rotted state file must not feed
  arbitrary input to `date -j -f` (security F-3).
- **Budget exhaustion** (case I): the load-bearing safety net — without it
  the system would re-dispatch forever on never-arriving signals.

**E2E:** Not in this plan. The full
"agent posts wait → orchestrator re-dispatches → operator approves → next
tick merges" flow is observed in production by `events.jsonl` (sequence of
`outcome=soft-pending` followed by `outcome=success` with no intervening
`outcome=halt-for-human`); per brainstorm Q4, the retrospective will count
this sequence after merge as a success metric. Wiring the retrospective
filter is OUT of scope per Q4 — the primitive (`outcome=soft-pending`
literal) lands in this PR via Task 3.

**Out-of-scope tests (deliberately):**
- Test for the `add-or-update-comment` createdAt-edit-in-place bug
  (brainstorm D-002): we picked `add-comment` specifically to avoid that
  trap. No regression test is needed for a primitive we no longer use.
- Test for review-stage CODEOWNERS soft-precondition (brainstorm D-008):
  out of scope per the Linear issue.
