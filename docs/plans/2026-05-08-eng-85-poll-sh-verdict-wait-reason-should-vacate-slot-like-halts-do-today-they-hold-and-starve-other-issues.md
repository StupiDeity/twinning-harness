---
linear: ENG-85
date: 2026-05-08
topic: poll.sh — verdict wait vacates the slot symmetrically with halts; new Pass 6 in main() keeps wait progressable when nothing else is ready
---

# Plan — ENG-85 `verdict wait reason=*` vacates the slot like halts do

Implementation plan for the design at
`docs/brainstorms/2026-05-08-eng-85-poll-sh-verdict-wait-reason-should-vacate-slot-like-halts-do-today-they-hold-and-starve-other-issues-design.md`.

## Anti-anchoring check

- **Problem (operator's words).** A wait verdict
  (`<!-- pipeline: verdict result=wait reason=awaiting-approval -->`)
  on a `stage:building` issue today classifies as
  `slot:"hold", advanceable:true` via the catch-all `else` at
  `bin/poll.sh:279-281`, so the wait issue counts toward
  `max_concurrent_features` and wins Pass 4's
  `[-stage_index, -priority_sort_rank]` sort against sibling held
  issues at earlier stages. ENG-79 sat queued at `stage:qa` for ~45
  min on 2026-05-08 while ENG-77 cycled three back-to-back wait
  re-dispatches at `stage:building`.
- **Brainstorm addresses it?** Yes. D-001 adds a sibling helper
  `find_fresh_wait_verdict` to `bin/verdict-handler.sh`; D-002 inserts
  an `elif fresh_wait=…` branch in `_poll_classify_labels` between
  the halted arm and the reviewing arm; D-003 inserts a Pass 6 in
  `main()` between Pass 5 (inbox) and the final `idle` to recall
  wait-vacated issues only when no other ready work exists; D-004
  pins five fixtures + a regression pin in `bin/poll-slot-test.sh`.
- **Proportional?** Yes. ~47 added lines in `bin/verdict-handler.sh`
  (one helper + export-line addition), ~30 lines in `bin/poll.sh`
  (one new branch + one Pass 5/6/idle reshape), ~110 lines in
  `bin/poll-slot-test.sh` (five new cases + replacing the inverted
  ENG-45 case). No new files, no new dependencies, no new exit
  codes, no new comment shapes, no new
  `dispatch.sh::allowed_tools_for` cases, no new
  `bin/pipeline-events.json` entries, no new `learned-rules/` file,
  no `AGENT_PROMPTS.md` edit, no config schema additions.
- **No reframe; no scope creep; no escalation. PROCEED with implementation
  plan.**

## Goal

After the implement stage runs, `bin/poll.sh` will classify any
issue whose latest verdict (newer than the most recent transition)
is `<!-- pipeline: verdict result=wait reason=… -->` as
`{slot:"vacate", advanceable:false, wait_recall:true,
wait_progress_ts:<createdAt>}`, freeing the slot for sibling held
work; and a new Pass 6 in `main()` will recall the
highest-priority wait-vacated issue (FIFO tiebreak by
`wait_progress_ts`) when no held issue dispatched, no inbox issue
picked, AND `held_count < max_concurrent`.

Verifiable by:

```
bash bin/poll-slot-test.sh \
  && bash bin/verdict-handler-test.sh \
  && bash -n bin/poll.sh \
  && bash -n bin/verdict-handler.sh \
  && bash bin/secret-probe-lint.sh \
  && bash .githooks/pre-commit
```

exiting 0 with the new fixtures (`AC-WAIT-1` through `AC-WAIT-6`)
all passing.

Out of scope (explicit per brainstorm §2 non-goals):

- **Per-stage entry-condition predicate check on re-dispatch.** That
  is ENG-86 (sibling structural ticket). ENG-85 frees the slot;
  ENG-86 closes the re-dispatch wall-clock with a cheap
  orchestrator-side predicate check before invoking the agent.
- **Reconciling `external_signal_budget.max_attempts` semantics with
  the new attempt cadence.** Pre-ENG-85 attempts grew once per tick;
  post-ENG-85 attempts grow once per Pass-6 dispatch. `max_minutes`
  unchanged. Recorded as O-3 in brainstorm §10.
- **Generalising "wait" to other stages.** Per ENG-54 the wait shape
  is build-only at the agent layer. The new poll-side helper is
  defensively non-stage-gated, but no other stage emits wait today.
- **Caching `get-comments` across the per-tick classify pass** (O-1).
- **Direct `bin/verdict-handler-test.sh` unit-test for
  `find_fresh_wait_verdict`** (O-2). Integration coverage via
  `bin/poll-slot-test.sh::AC-WAIT-1` is sufficient regression pin.
- **Surfacing `external-signal-budget-exhausted` registry drift**
  (O-5). Pre-existing drift between `bin/run-stage.sh:562` emit and
  `bin/pipeline-events.json::halt_reasons` allow-list. Out of scope
  for ENG-85; should be filed separately.

## Architecture

Three files modified, no new files. The change extends the existing
slot-classification surface (`_poll_classify_labels`) with one
new branch, adds a sibling helper to the verdict-handler dependency
already sourced by `bin/poll.sh:23`, and inserts one new pass into
`main()`'s existing 1-2-2b-3-4-5-idle structure (now
1-2-2b-3-4-5-6-idle). No control-flow surface beyond the Pass 5/6/idle
reshape is touched.

`bin/verdict-handler.sh` already exposes `find_fresh_verdict` which
returns the latest *actionable* verdict (pass/fail/halt — wait
explicitly excluded at line 113). The new sibling
`find_fresh_wait_verdict` returns the latest *wait* verdict iff it
IS the latest verdict in the post-transition window (per ENG-61
Bug B's "supersession" rule at `bin/run-stage.sh:332-356`). Two
helpers, two audiences:

- `find_fresh_verdict` answers "what actionable verdict should the
  orchestrator transition on?" (Used by `verdict_handler`,
  `_poll_classify_labels` halted arm.)
- `find_fresh_wait_verdict` answers "is this issue currently in a
  wait state?" (Used by `_poll_classify_labels` new wait arm.)

There is no `docs/VISION.md`, no `docs/ARCHITECTURE.md`, no
`docs/knowledge/decisions.md` (verified: `ls docs/` returns
`brainstorms/  pipeline-vocabulary.md  pipeline-vocabulary.template.md
plans/  runbooks/`; no `knowledge/` subdir). Governing constraints
come from `CLAUDE.md` and `learned-rules/harness/{project-profile,build}.md`
(verified at `learned-rules/harness/`: only `build.md` and
`project-profile.md` exist; no `plan.md`).

## Tech stack

- Bash 3.2+ (Darwin default).
- `jq` (1.6+ — stable `sort_by` semantics; verified by every existing
  poll-slot-test fixture's reliance on stable ordering).
- `bin/common.sh::parse_pipeline_marker` (`bin/common.sh:192-242`)
  — closed-vocabulary marker parser; reused unchanged.
- `bin/common.sh::die` — fatal-exit helper; unchanged.
- `bin/linear.sh get-comments` — unchanged; new helper invokes via
  the same `bash "$_VH_SCRIPT_DIR/linear.sh" get-comments "$issue"`
  pattern as `find_fresh_verdict` at `bin/verdict-handler.sh:87`.
- No new dependencies. No new `dispatch.sh::allowed_tools_for` cases.
  No new metric event names. No new `bin/pipeline-events.json`
  entries (the `wait_reasons` allow-list at lines 20-23 is reused
  read-only via `parse_pipeline_marker`'s output).
- No new `learned-rules/` file.

## Assumption Inventory

Every modified-file fact below is `path:line`-cited against the
current worktree per the codebase-fact verification mandate.

### Files touched in this plan

- `bin/verdict-handler.sh` — net +47 lines (new helper +44, export +3).
- `bin/poll.sh` — net +30 lines (`_poll_classify_labels` branch +6,
  `main()` Pass 5/6/idle reshape +24).
- `bin/poll-slot-test.sh` — net +110 lines (replace 20-line ENG-45
  case with AC-WAIT-1 +20, add AC-WAIT-2 through AC-WAIT-6 +90).
- `docs/plans/2026-05-08-eng-85-…md` — this file. NEW.

### Modified-file facts — current state, signatures, and verification points

#### A-001 — `bin/poll.sh:207-284` `_poll_classify_labels` definition

Verified by direct read. Concrete current shape:

```bash
# bin/poll.sh:207-281 (verified, current)
_poll_classify_labels() {
  local ident="$1" labels_json="$2"
  local refreshed_labels=""

  if ! refreshed_labels="$(_poll_evaluate_skip "$ident" "$labels_json")"; then
    jq -nc --argjson l "$labels_json" '{slot:"vacate",advanceable:false,labels:$l}'
    return 0
  fi
  [[ -n "$refreshed_labels" ]] && labels_json="$refreshed_labels"

  _has_label() {
    jq -r --arg n "$1" '[.[] | select(. == $n)] | length > 0' <<<"$labels_json"
  }

  local class
  if [[ "$(_has_label pipeline:abandoned)" == "true" ]]; then
    class='{"slot":"terminal","advanceable":false}'
  elif [[ "$(_has_label pipeline:paused)" == "true" ]] \
    || [[ "$(_has_label pipeline:scope-approval-needed)" == "true" ]]; then
    class='{"slot":"vacate","advanceable":false}'
  elif [[ "$(_has_label pipeline:halted)" == "true" ]]; then
    local fresh
    fresh="$(find_fresh_verdict "$ident" 2>/dev/null || printf '')"
    if [[ -z "$fresh" ]]; then
      class='{"slot":"hold","advanceable":false}'
    else
      local marker
      marker="$(jq -r '.marker // ""' <<<"$fresh")"
      case "$marker" in
        pipeline-stage-summary|pipeline-rejection)
          class='{"slot":"hold","advanceable":true}' ;;
        pipeline-halt)
          class='{"slot":"vacate","advanceable":false}' ;;
        *)
          class='{"slot":"hold","advanceable":false}' ;;
      esac
    fi
  elif [[ "$(_has_label stage:reviewing)" == "true" ]]; then
    # ENG-50 / ENG-53 #12 reviewing arm (lines 248-278) — unchanged.
    local _rp_branch
    _rp_branch="$(bash "$SCRIPT_DIR/branch-name.sh" "$ident" 2>/dev/null || true)"
    if [[ -z "$_rp_branch" ]]; then
      class='{"slot":"hold","advanceable":true}'
    else
      source "$SCRIPT_DIR/review-poll.sh"
      if review_should_dispatch "$ident" "$_rp_branch"; then
        class='{"slot":"hold","advanceable":true}'
      else
        class='{"slot":"hold","advanceable":false}'
      fi
    fi
  else
    class='{"slot":"hold","advanceable":true}'
  fi

  jq -nc --argjson c "$class" --argjson l "$labels_json" '$c + {labels:$l}'
}
```

The new wait branch lands at the `elif` slot **between line 247 and
line 248** — i.e., AFTER the halted arm closes (`fi` at line 247)
and BEFORE the `elif "$(_has_label stage:reviewing)"…` opens at
line 248. The catch-all `else` at line 279-281 (`class='{"slot":"hold","advanceable":true}'`)
is left untouched — it is now reachable only when (a) no halt label,
(b) no fresh wait verdict, (c) not stage:reviewing.

#### A-002 — `bin/poll.sh:23` sources `verdict-handler.sh`

Verified. The line reads `source "$SCRIPT_DIR/verdict-handler.sh"`.
Sourcing — not subshell — means the new `find_fresh_wait_verdict`
function is in scope inside `_poll_classify_labels` without any
additional plumbing.

#### A-003 — `bin/poll.sh:399-503` `main()` definition

Verified. Concrete Pass 5/idle block at lines 474-503:

```bash
# bin/poll.sh:474-503 (verified, current)
  # Pass 5: inbox pickup, only if a slot is available.
  if (( held_count >= max_concurrent )); then
    idle "max-concurrent-reached (held=$held_count, limit=$max_concurrent)"
  fi

  local inbox_state
  inbox_state="$(config_get '.linear.native_states.inbox')"
  local inbox_pick
  inbox_pick="$(bash "$SCRIPT_DIR/linear.sh" list-issues-in-state "$inbox_state" \
    | jq -r '
      [.data.issues.nodes[]
       | select([.labels.nodes[].name] | any(startswith("stage:")) | not)
       | select([.labels.nodes[].name] | index("pipeline:paused") | not)
       | select([.labels.nodes[].name] | index("pipeline:abandoned") | not)
       | select([.labels.nodes[].name] | index("pipeline:skip-until-human-acts") | not)
       | select([.labels.nodes[].name] | index("pipeline:skip-until-code-changes") | not)
       | {identifier: .identifier,
          priority_sort_rank: (if (.priority // 0) == 0 then 0 else (5 - .priority) end)}]
      | sort_by(-.priority_sort_rank)
      | .[0].identifier // ""')"
  if [[ -n "$inbox_pick" ]]; then
    jq -nc \
      --arg issue_id "$inbox_pick" \
      --arg stage "brainstorming" \
      --arg reason "inbox pickup" \
      '{issue_id:$issue_id, stage:$stage, entry_action:"apply-stage-label", reason:$reason}'
    exit 0
  fi

  idle "no-work"
}
```

The reshape moves the cap-check (line 475-477) to the bottom (so it
guards the final `idle "no-work"` rather than top-of-Pass-5),
inlines the inbox query inside a `if (( held_count < max_concurrent ))`
block, and inserts Pass 6 between Pass 5 and the final `idle`.
The `max-concurrent-reached` idle reason is preserved by the
final-else guard so observability is unchanged.

#### A-004 — `bin/verdict-handler.sh:84-143` `find_fresh_verdict` definition

Verified. Concrete shape:

```bash
# bin/verdict-handler.sh:84-143 (verified, current)
find_fresh_verdict() {
  local issue="$1"
  local comments
  comments="$(bash "$_VH_SCRIPT_DIR/linear.sh" get-comments "$issue")"
  [[ -z "$comments" || "$comments" == "null" ]] && { printf ''; return 0; }

  # Find the most recent transition-event timestamp to set freshness floor.
  local last_transition_ts=""
  local row body ts ev
  while IFS=$'\t' read -r ts body; do
    ev="$(parse_pipeline_marker "$body" 2>/dev/null || true)"
    [[ -z "$ev" ]] && continue
    if [[ "$(jq -r '.event' <<<"$ev")" == "transition" ]]; then
      [[ "$ts" > "$last_transition_ts" ]] && last_transition_ts="$ts"
    fi
  done < <(jq -r '.[] | "\(.createdAt)\t\(.body | gsub("\n"; " "))"' <<<"$comments")

  # Pick the latest actionable verdict event (pass/fail/halt — NOT wait) ...
  local fresh_ts="" fresh_body="" fresh_id=""
  while IFS=$'\t' read -r ts id body; do
    [[ -n "$last_transition_ts" && ! "$ts" > "$last_transition_ts" ]] && continue
    ev="$(parse_pipeline_marker "$body" 2>/dev/null || true)"
    [[ -z "$ev" ]] && continue
    [[ "$(jq -r '.event' <<<"$ev")" != "verdict" ]] && continue
    [[ "$(jq -r '.result' <<<"$ev")" == "wait" ]] && continue   # line 113
    if [[ "$ts" > "$fresh_ts" ]]; then
      fresh_ts="$ts"; fresh_body="$body"; fresh_id="$id"
    fi
  done < <(jq -r '.[] | "\(.createdAt)\t\(.id)\t\(.body | gsub("\n"; " "))"' <<<"$comments")

  [[ -z "$fresh_body" ]] && { printf ''; return 0; }
  ...
  printf '%s' "$result"
}
```

The new helper sits **immediately after** `find_fresh_verdict`
(insertion point: between current line 143 (`}` closing
`find_fresh_verdict`) and current line 144 (the `# Atomic
transition order ...` comment opening `apply_transition`)). The
two-stage scan algorithm (last_transition_ts floor → latest
verdict in window) is mirrored verbatim from `find_fresh_verdict`
lines 91-117; only the result-classification differs:
`find_fresh_verdict` excludes wait at line 113 and projects
pass/fail/halt to a legacy-shape JSON; `find_fresh_wait_verdict`
returns wait-only and projects `{reason, comment_id, created_at}`.

#### A-005 — `bin/verdict-handler.sh:407` `export -f` line

Verified. Concrete:

```bash
# bin/verdict-handler.sh:407 (verified, current)
export -f verdict_handler find_fresh_verdict apply_transition resume_in_progress_transition
```

The new helper appends to this list as
`find_fresh_wait_verdict` (last token, before the line break).

#### A-006 — `bin/run-stage.sh:310-364` `_fresh_wait_reason` definition

Verified. Concrete relevant excerpts:

- Line 312-315: build-only allow-list (`case "$stage" in building) ;; *) return 1 ;; esac`).
- Line 318-319: `comments="$(bash "$SCRIPT_DIR/linear.sh" get-comments "$issue" 2>/dev/null)" || return 1; [[ -z "$comments" || "$comments" == "null" ]] && return 1`.
- Line 322-330: last_transition_ts loop (mirrored in `find_fresh_verdict` and now in `find_fresh_wait_verdict`).
- Line 332-356: ENG-61 Bug B "track-latest-verdict, decide-after-loop" rule — the precedent `find_fresh_wait_verdict` mirrors at the orchestrator side.
- Line 354-356: `[[ "$fresh_result" != "wait" ]] && return 1` — the wait-supersession check; `find_fresh_wait_verdict` mirrors this with `[[ "$fresh_result" != "wait" ]] && { printf ''; return 0; }`.
- Line 358-363: `awaiting-approval|awaiting-ci` allow-list. `find_fresh_wait_verdict` does NOT re-validate the reason — it trusts `bin/pipeline.sh::event`'s write-time validation against `bin/pipeline-events.json::wait_reasons` (this is the brainstorm §3 architectural-principle commitment). The reason field is passed through verbatim via jq; no shell expansion of attacker-controlled strings.

#### A-007 — `bin/run-stage.sh:489-578` `_handle_wait` definition

Verified. Concrete relevant excerpts:

- Line 489-491: `_handle_wait()` opens; `PIPELINE_WRITER=orchestrator` is set + exported.
- Line 494: `local f; f="$(issue_dir "$ident")/wait-${stage}.json"` — per-issue wait counter file path.
- Line 530: `attempts=$((attempts + 1))` — the per-tick increment that becomes per-Pass-6-dispatch increment post-ENG-85.
- Line 540: `tmp="${f}.tmp.$$"; printf '%s' "$body" > "$tmp"; mv -f "$tmp" "$f"` — atomic file write.
- Line 543-557: `max_attempts` / `max_minutes` budget check (with TZ=UTC pin).
- Line 560-575: exhausted halt-add path (writes `<!-- pipeline: verdict result=halt reason=external-signal-budget-exhausted -->`, applies `pipeline:halted`, removes wait file).

The brainstorm flags one drift in §10 O-5: the `external-signal-budget-exhausted` reason at line 562 is NOT in
`bin/pipeline-events.json::halt_reasons`. This is a pre-existing drift, NOT introduced by ENG-85; out of scope.
ENG-85 does not write that marker — it only reads via `find_fresh_verdict` (the existing helper, not the new one),
and `find_fresh_verdict` does not re-validate halt reasons against the registry. **No regression risk.**

#### A-008 — `bin/poll-slot-test.sh:99-114` source-and-stub harness

Verified. Concrete:

```bash
# bin/poll-slot-test.sh:99-114 (verified)
source "$SCRIPT_DIR_REAL/poll.sh"
SCRIPT_DIR="$STUB_DIR"
_VH_SCRIPT_DIR="$STUB_DIR"
HARNESS_STATE_DIR="$_TEST_HARNESS_STATE_DIR"
export HARNESS_STATE_DIR
PROJECT_STATE_DIR="${HARNESS_STATE_DIR}/${PROJECT_SLUG}"
export PROJECT_STATE_DIR
```

Sourcing `poll.sh` brings `find_fresh_wait_verdict` into the test
environment via `poll.sh`'s `source verdict-handler.sh` at line 23.
The post-source override of `_VH_SCRIPT_DIR=$STUB_DIR` makes the
new helper's transitive `bash "$_VH_SCRIPT_DIR/linear.sh"
get-comments "$issue"` call land on the stub `linear.sh`. The
`comments-<ident>.json` fixture path the stub reads
(via `write_comments_fixture` at lines 211-223) is the same one
existing wait-related fixtures (e.g., the ENG-45 case at lines
449-468) already use. **No new test scaffolding required.**

#### A-009 — `bin/poll-slot-test.sh:160-223` fixture-builder helpers

Verified at three definitions:

- `write_label_fixture` (lines 160-182) — emits
  `label-stage-<stage>.json` in `$FIXTURE_DIR`. Used by the new
  AC-WAIT-2 to set up two-issue gathered state.
- `write_inbox_fixture` (lines 186-207) — emits
  `state-Todo.json`. Used by AC-WAIT-3 / AC-WAIT-4 / AC-WAIT-5
  to assert that an empty inbox falls through Pass 5 to Pass 6.
- `write_comments_fixture` (lines 211-223) — emits
  `comments-<ident>.json`. Used by every wait-shape fixture to
  set up the latest-verdict timestamps.

#### A-010 — `bin/poll-slot-test.sh:449-468` ENG-45 case (the case to invert)

Verified. Concrete (re-quoted verbatim for the implementation
agent's reference; this block is replaced wholesale by AC-WAIT-1):

```bash
# bin/poll-slot-test.sh:449-468 (verified, to be replaced)
# ─── ENG-45: stage:building + only pipeline-wait fresh → hold,advanceable=true
# Asserts the load-bearing claim from plan A-004: _poll_classify_labels' else
# branch (the soft-redispatch path) classifies an issue with stage:building, no
# halt label, no skip labels, and only a pipeline-wait fresh comment as
# slot=hold,advanceable=true. This is the path the new wait flow exploits to
# get the orchestrator to re-dispatch build on the next tick without operator
# intervention.
reset_fixtures
write_comments_fixture "ENG-45-WAIT" \
  '<!-- pipeline: transition from=implementing to=building -->|2026-04-28T08:00:00Z' \
  '<!-- pipeline: verdict result=wait reason=awaiting-approval -->|2026-04-28T08:17:00Z'

out="$(_poll_classify_labels "ENG-45-WAIT" '["stage:building"]')"
slot="$(jq -r '.slot // ""' <<<"$out")"
adv="$(jq -r '.advanceable // ""'  <<<"$out")"
if [[ "$slot" == "hold" && "$adv" == "true" ]]; then
  pass_at "ENG-45 poll-slot: pipeline-wait re-dispatches via else branch (hold,advanceable=true)"
else
  fail_at "ENG-45 poll-slot wait re-dispatch" "got slot=$slot adv=$adv (want hold/true) full=$out"
fi
```

The block opens at line 449 (`# ─── ENG-45`) and closes at line 468
(`fi`). The AC-WAIT-1 replacement preserves the
`reset_fixtures` + `write_comments_fixture` setup verbatim
(deterministic fixture data) and inverts the assertion to
`slot=vacate, adv=false, wait_recall=true`.

#### A-011 — `bin/poll-slot-test.sh::main` invocation pattern

Verified. The integration cases (e.g., AC-1 at the file's earlier
sections) invoke `out="$(main 2>/dev/null || true)"` after writing
fixtures, then jq-read `out` for `issue_id` / `stage` / `reason`.
AC-WAIT-2 (slot vacated → sibling issue dispatched) and AC-WAIT-3
(Pass 6 fallback) reuse this exact pattern. The
`out="$(main 2>/dev/null || true)"` form is critical: `main()`
emits its dispatch decision to stdout and `exit 0`s, so the
subshell terminates cleanly under `set -e`.

#### A-012 — `bin/pipeline-events.json::wait_reasons` allow-list

Verified at lines 20-23:

```json
"wait_reasons": [
  "awaiting-approval",
  "awaiting-ci"
],
```

`find_fresh_wait_verdict` does NOT re-validate reasons; it returns
the parsed `event.reason` verbatim. Write-time validation in
`bin/pipeline.sh::event` is the registry's enforcement layer.
Operator-posted wait verdicts (e.g., `bash bin/pipeline.sh event
ENG-N verdict wait --reason awaiting-approval`) flow through this
allow-list; `_handle_wait`'s emit at `bin/run-stage.sh:546` is
hard-coded to `awaiting-approval | awaiting-ci`. Both paths
guarantee the reason is registry-valid.

#### A-013 — `bin/common.sh:192-242` `parse_pipeline_marker`

Verified. Used by the new helper to extract `event`, `result`,
`reason`, `from`, `to` fields from a comment body. The closed
allow-list (`pipeline | meta` family + first whitespace token as
event verb) is reused unchanged. Empty input or non-matching
shape returns 1 with empty stdout — the new helper's
`[[ -z "$ev" ]] && continue` guards mirror `find_fresh_verdict`'s.

#### A-014 — Branch shape verification

This worktree is checked out at
`feat/eng-85-poll-sh-verdict-wait-reason-should-vacate-slot-like-halts-do-today-they-hold-and-starve-other-issues`
(verified via `git branch --show-current`). The `feat/` prefix
matches `branch-name.sh:31`'s canonical shape per ENG-67/ENG-79.
The brainstorm doc at line 2 carries `linear: ENG-85`, so reconcile
picked the correct doc.

#### A-015 — `.githooks/pre-commit` glob picks up `bin/*-test.sh`

Verified by precedent: `bin/poll-slot-test.sh` is in the suite
and is NOT in the `KNOWN_BROKEN` allowlist. The new fixtures
must pass for every commit. ENG-85's net delta to
`bin/poll-slot-test.sh` adds one new function (`find_fresh_wait_verdict`,
inherited from poll.sh's `source verdict-handler.sh` line) and
six fixture cases; no `KNOWN_BROKEN` additions required.

#### A-016 — ENG-86 sibling ticket is not yet implemented

Verified by `grep -rn 'ENG-86' docs/brainstorms/` returning only
the ENG-85 brainstorm body's references. ENG-85 ships standalone;
ENG-86's per-stage entry-condition predicate check is NOT a
prerequisite or co-dependency.

## File Structure

```
bin/
  verdict-handler.sh          MODIFIED — add find_fresh_wait_verdict helper
                                         after line 143 (next to find_fresh_verdict);
                                         append to export -f line at 407.
  poll.sh                     MODIFIED — (a) add new elif branch in
                                         _poll_classify_labels between
                                         lines 247 and 248 (wait-vacates);
                                         (b) reshape main() lines 474-503:
                                         move cap-check below Pass 5/6,
                                         inline inbox query, insert Pass 6.
  poll-slot-test.sh           MODIFIED — replace ENG-45 case at lines
                                         449-468 with AC-WAIT-1; append
                                         AC-WAIT-2 through AC-WAIT-6 after.

docs/
  plans/
    2026-05-08-eng-85-poll-sh-verdict-wait-reason-…-design.md
                              NEW — this file. Written at planning-stage exit.
                                    Bucketed in-scope via the `eng-85` basename
                                    token per `partition_dirty_paths::D-004`.
```

No changes to: `AGENT_PROMPTS.md`, `bin/branch-name.sh`,
`bin/run-local.sh`, `bin/run-stage.sh`, `bin/dispatch.sh`,
`bin/common.sh`, `bin/reconcile.sh`, `bin/scope-check.sh`,
`bin/classify-failure.sh`, `bin/linear.sh`, `bin/metrics.sh`,
`bin/pipeline.sh`, `bin/setup.sh`, `bin/pipeline-events.json`,
`bin/review-poll.sh`, `bin/halt.sh`, `learned-rules/**`,
`launchd/**`, `.github/workflows/**`, `.githooks/pre-commit`,
`docs/pipeline-vocabulary.md`, `docs/runbooks/**`, `CLAUDE.md`,
`.pipeline-config/config.json`. The full bin/*-test.sh suite runs
unchanged but for `bin/poll-slot-test.sh`'s six new cases.

## API Contract

**No new API surface.** The harness has no FE↔BE API surface. The
change adds:

- One new exported bash function (`find_fresh_wait_verdict`) on
  `bin/verdict-handler.sh`'s `export -f` line. Output shape:
  `{reason: "awaiting-approval"|"awaiting-ci",
    comment_id: "<linear-comment-id>",
    created_at: "<iso-8601-utc>"}`
  or empty string. Callers `[[ -n "$result" ]]` to gate.
- Two new optional keys on the `_poll_classify_labels`
  output JSON when (and only when) the wait branch fires:
  `wait_recall: true` and `wait_progress_ts: "<iso-8601-utc>"`.
  The `slot` enum is unchanged (`terminal | vacate | hold`); the
  new keys are side-channel metadata that consumers other than
  Pass 6 ignore via jq filter (e.g., Pass 3's
  `select(.slot == "hold")` at `bin/poll.sh:428` and
  `_poll_emit_halt_sprawl_alert`'s `select(.slot == "vacate")`
  at the halt-sprawl observer remain unaffected).
- One new `idle`-fall-through path: when no held dispatched, no
  inbox picked, no wait recall available, and `held_count >=
  max_concurrent`, `idle "max-concurrent-reached (held=N, limit=M)"`
  fires (preserved from current line 476). When the cap is not
  reached, `idle "no-work"` fires as today (line 503). Both
  reasons unchanged.
- No new `dispatch.sh::allowed_tools_for` case.
- No new exit code (the caller flows through existing dispatch
  decisions; failure paths preserved).
- No new metric event name. The dispatch decision JSON shape is
  unchanged; the only field that changes is `reason`, which
  continues to be a free-form string. New Pass 6 reason:
  `wait re-pickup at stage:<label> (no other ready work)`.
- No new comment-body shape. ENG-85 reads existing wait verdict
  markers; it does not write new ones.
- No new orchestrator hook.
- No new lane fence.

The four-shape verdict vocabulary
(`pass | fail | halt | wait`) and the closed `meta_kinds` registry
are untouched. No `bin/pipeline-events.json` registry change. No
`docs/pipeline-vocabulary.md` regeneration.

## Backend Tasks

### Task 1: Add `find_fresh_wait_verdict` helper to `bin/verdict-handler.sh`

- `depends_on: []`
- `touches: bin/verdict-handler.sh::find_fresh_wait_verdict (new), bin/verdict-handler.sh:407 (export -f line)`

- [ ] **Step 1.1 — Insert the new helper.** Open
  `bin/verdict-handler.sh` and add a new function
  `find_fresh_wait_verdict` immediately after `find_fresh_verdict`
  closes (current line 143 — the `}` closing `find_fresh_verdict`)
  and BEFORE the comment block opening `apply_transition` (current
  line 145, `# Atomic transition order …`). Body verbatim from
  brainstorm §4 D-001:

  ```bash
  # ─── ENG-85: wait-only sibling of find_fresh_verdict ────────────────
  # Returns the latest wait verdict marker that is newer than the most
  # recent transition AND is itself the latest verdict in that window.
  # If a later pass/fail/halt/pivot exists, the wait has been superseded
  # and this returns empty (matching `_fresh_wait_reason`'s ENG-61 Bug B
  # rule at bin/run-stage.sh:332-356). No stage gate — caller decides.
  #
  # Output JSON: {"reason": "...", "comment_id": "...", "created_at": "..."}
  #              OR empty string when no fresh wait qualifies.
  find_fresh_wait_verdict() {
    local issue="$1"
    local comments
    comments="$(bash "$_VH_SCRIPT_DIR/linear.sh" get-comments "$issue" 2>/dev/null)" || { printf ''; return 0; }
    [[ -z "$comments" || "$comments" == "null" ]] && { printf ''; return 0; }

    local last_transition_ts="" ts body ev
    while IFS=$'\t' read -r ts body; do
      ev="$(parse_pipeline_marker "$body" 2>/dev/null || true)"
      [[ -z "$ev" ]] && continue
      if [[ "$(jq -r '.event' <<<"$ev")" == "transition" ]]; then
        [[ "$ts" > "$last_transition_ts" ]] && last_transition_ts="$ts"
      fi
    done < <(jq -r '.[] | "\(.createdAt)\t\(.body | gsub("\n"; " "))"' <<<"$comments")

    local fresh_ts="" fresh_id="" fresh_result="" fresh_reason=""
    while IFS=$'\t' read -r ts id body; do
      [[ -n "$last_transition_ts" && ! "$ts" > "$last_transition_ts" ]] && continue
      ev="$(parse_pipeline_marker "$body" 2>/dev/null || true)"
      [[ -z "$ev" ]] && continue
      [[ "$(jq -r '.event' <<<"$ev")" != "verdict" ]] && continue
      if [[ "$ts" > "$fresh_ts" ]]; then
        fresh_ts="$ts"
        fresh_id="$id"
        fresh_result="$(jq -r '.result' <<<"$ev")"
        fresh_reason="$(jq -r '.reason // ""' <<<"$ev")"
      fi
    done < <(jq -r '.[] | "\(.createdAt)\t\(.id)\t\(.body | gsub("\n"; " "))"' <<<"$comments")

    [[ "$fresh_result" != "wait" ]] && { printf ''; return 0; }
    [[ -z "$fresh_reason" ]] && { printf ''; return 0; }

    jq -nc \
      --arg r "$fresh_reason" \
      --arg id "$fresh_id" \
      --arg ts "$fresh_ts" \
      '{reason:$r, comment_id:$id, created_at:$ts}'
  }
  ```

  Note: the body uses the same `bash "$_VH_SCRIPT_DIR/linear.sh"
  get-comments "$issue"` pattern as `find_fresh_verdict`, the same
  two-stage scan algorithm, and the same `2>/dev/null || { printf
  ''; return 0; }` fail-closed surface.

- [ ] **Step 1.2 — Append to `export -f`.** Edit line 407 from
  `export -f verdict_handler find_fresh_verdict apply_transition resume_in_progress_transition`
  to
  `export -f verdict_handler find_fresh_verdict find_fresh_wait_verdict apply_transition resume_in_progress_transition`.

- [ ] **Step 1.3 — Syntactic check.** Run
  `bash -n bin/verdict-handler.sh` and confirm exit 0.

### Task 2: Add wait-vacates branch to `_poll_classify_labels`

- `depends_on: [1]`
- `touches: bin/poll.sh::_poll_classify_labels (insertion between lines 247 and 248)`

- [ ] **Step 2.1 — Insert the new branch.** Open `bin/poll.sh` and
  insert the following 10-line block in `_poll_classify_labels`,
  AFTER the halted arm's closing `fi` at line 247 and BEFORE the
  `elif [[ "$(_has_label stage:reviewing)" == "true" ]]; then` at
  line 248:

  ```bash
    elif fresh_wait="$(find_fresh_wait_verdict "$ident" 2>/dev/null)"; [[ -n "$fresh_wait" ]]; then
      # ENG-85: a wait verdict newer than the most recent transition vacates
      # the slot. Symmetric with the pipeline-halt arm above (line 242-243)
      # — both express agent-idle-on-external-signal. Pass 6 in main() picks
      # wait-recallable issues only when no held / inbox work is ready.
      local _wait_ts
      _wait_ts="$(jq -r '.created_at' <<<"$fresh_wait")"
      class="$(jq -nc --arg ts "$_wait_ts" \
        '{slot:"vacate", advanceable:false, wait_recall:true, wait_progress_ts:$ts}')"
  ```

  Three correctness notes for the implementation agent:
  - The `local fresh_wait` is implicit: bash command-substitution
    inside an `elif` test scopes the variable to the function. To
    be safe under `set -u`, the implementer SHOULD add
    `local fresh_wait=""` to the existing `local class` line near
    line 225 so the variable is initialized regardless of branch.
  - The `_wait_ts="$(jq -r '.created_at' <<<"$fresh_wait")"` works
    because `find_fresh_wait_verdict` always emits a JSON object
    when non-empty — there's no need to guard against empty
    `$fresh_wait` here (the outer `[[ -n "$fresh_wait" ]]` already
    gates).
  - The output JSON has FOUR keys (slot, advanceable, wait_recall,
    wait_progress_ts), one more than the pre-existing branches'
    two-key shape. The trailing
    `jq -nc --argjson c "$class" --argjson l "$labels_json" '$c +
    {labels:$l}'` at line 283 merges them all into the final
    output without modification (jq object addition is verbatim).

- [ ] **Step 2.2 — Add `local fresh_wait=""` initializer.** At
  line 225 (just before the `if [[ "$(_has_label
  pipeline:abandoned)" == "true" ]]; then`), the existing line
  reads `local class`. Change it to
  `local class fresh_wait=""`. This avoids `set -u` failures when
  the elif's command-sub is short-circuited by an earlier branch
  matching first.

- [ ] **Step 2.3 — Syntactic check.** Run `bash -n bin/poll.sh`
  and confirm exit 0.

### Task 3: Insert Pass 6 in `main()` and reshape Pass 5/idle

- `depends_on: [2]`
- `touches: bin/poll.sh::main (lines 474-503 wholesale replacement)`

- [ ] **Step 3.1 — Replace the Pass 5/idle block.** Open
  `bin/poll.sh` and replace lines 474-503 with the new structure.
  Read the current block (verbatim quoted in A-003) and replace
  with:

  ```bash
    # Pass 5: inbox pickup, only if a slot is available.
    if (( held_count < max_concurrent )); then
      local inbox_state
      inbox_state="$(config_get '.linear.native_states.inbox')"
      local inbox_pick
      inbox_pick="$(bash "$SCRIPT_DIR/linear.sh" list-issues-in-state "$inbox_state" \
        | jq -r '
          [.data.issues.nodes[]
           | select([.labels.nodes[].name] | any(startswith("stage:")) | not)
           | select([.labels.nodes[].name] | index("pipeline:paused") | not)
           | select([.labels.nodes[].name] | index("pipeline:abandoned") | not)
           | select([.labels.nodes[].name] | index("pipeline:skip-until-human-acts") | not)
           | select([.labels.nodes[].name] | index("pipeline:skip-until-code-changes") | not)
           | {identifier: .identifier,
              priority_sort_rank: (if (.priority // 0) == 0 then 0 else (5 - .priority) end)}]
          | sort_by(-.priority_sort_rank)
          | .[0].identifier // ""')"
      if [[ -n "$inbox_pick" ]]; then
        jq -nc \
          --arg issue_id "$inbox_pick" \
          --arg stage "brainstorming" \
          --arg reason "inbox pickup" \
          '{issue_id:$issue_id, stage:$stage, entry_action:"apply-stage-label", reason:$reason}'
        exit 0
      fi
    fi

    # Pass 6 (ENG-85): wait re-pickup as last resort. Only fires when no
    # held was dispatched (Pass 4), no inbox issue picked (Pass 5), AND
    # there is slot capacity. Sort: priority desc, then wait_progress_ts asc
    # (FIFO fairness — older waits go first).
    if (( held_count < max_concurrent )); then
      local wait_pick
      wait_pick="$(jq -c '
        [.[] | select(.slot == "vacate" and (.wait_recall // false) == true)]
        | sort_by([-(.priority_sort_rank), .wait_progress_ts])
        | .[0] // empty' <<<"$classified")"
      if [[ -n "$wait_pick" && "$wait_pick" != "null" ]]; then
        local _wp_ident _wp_stage_label _wp_arg
        _wp_ident="$(jq -r '.identifier'  <<<"$wait_pick")"
        _wp_stage_label="$(jq -r '.stage_label' <<<"$wait_pick")"
        _wp_arg="$(stage_arg_for_label "$_wp_stage_label")"
        jq -nc \
          --arg issue_id "$_wp_ident" \
          --arg stage "$_wp_arg" \
          --arg reason "wait re-pickup at $_wp_stage_label (no other ready work)" \
          '{issue_id:$issue_id, stage:$stage, entry_action:"run", reason:$reason}'
        exit 0
      fi
    fi

    # Reached here with no work to dispatch.
    if (( held_count >= max_concurrent )); then
      idle "max-concurrent-reached (held=$held_count, limit=$max_concurrent)"
    fi
    idle "no-work"
  }
  ```

  Three structural changes vs. pre-ENG-85:
  - Cap-check moves from line 475-477 (top of Pass 5) to bottom
    (just before `idle "no-work"`). Preserves the
    `max-concurrent-reached` reason via `idle` (which exits 0).
  - Inbox query is now nested inside `if (( held_count <
    max_concurrent ))`. Saves one Linear API call per tick when
    cap is reached. Side effect of the structural reshape; the
    code path under cap-not-reached is byte-equivalent.
  - Pass 6 is new. It reads `$classified` (the gathered+classified
    array from Pass 2 at line 418), filters for
    `slot == "vacate" and wait_recall == true`, sorts by
    `[-priority_sort_rank, wait_progress_ts]`, picks `.[0]`. The
    sort key matches the issue body's "Risks" §:
    *priority desc, then last-progress-timestamp ascending*.

- [ ] **Step 3.2 — Verify `$classified` is in scope.**
  `$classified` is declared `local` at line 417 (per A-003's
  surrounding context: `local classified;
  classified="$(_poll_classify_all "$gathered")"` at lines 417-418).
  Pass 6 is below that line, so the variable is in scope. The
  jq read in Pass 6 uses the SAME `$classified` array Pass 3 uses
  for `held` extraction at lines 426-430. No re-fetch.

- [ ] **Step 3.3 — Syntactic check.** Run `bash -n bin/poll.sh`
  and confirm exit 0.

### Task 4: Replace ENG-45 fixture with AC-WAIT-1

- `depends_on: [2]`
- `touches: bin/poll-slot-test.sh:449-468 (replacement)`

- [ ] **Step 4.1 — Replace the ENG-45 case.** Replace lines
  449-468 of `bin/poll-slot-test.sh` (the block quoted verbatim
  at A-010) with:

  ```bash
  # ─── AC-WAIT-1 (ENG-85): stage:building + only pipeline-wait fresh
  #     → slot=vacate, advanceable=false, wait_recall=true. Replaces the
  #     pre-ENG-85 ENG-45 fixture (which asserted hold/advanceable=true
  #     via the catch-all else branch). The pre-ENG-85 hold/true
  #     classification was the load-bearing starvation surface this
  #     ticket fixes; AC-WAIT-3 covers the "wait still progresses
  #     eventually" contract that the prior ENG-45 fixture pinned.
  reset_fixtures
  write_comments_fixture "ENG-45-WAIT" \
    '<!-- pipeline: transition from=implementing to=building -->|2026-04-28T08:00:00Z' \
    '<!-- pipeline: verdict result=wait reason=awaiting-approval -->|2026-04-28T08:17:00Z'

  out="$(_poll_classify_labels "ENG-45-WAIT" '["stage:building"]')"
  slot="$(jq -r '.slot // ""' <<<"$out")"
  adv="$(jq -r '.advanceable // ""' <<<"$out")"
  recall="$(jq -r '.wait_recall // false' <<<"$out")"
  ts="$(jq -r '.wait_progress_ts // ""' <<<"$out")"
  if [[ "$slot" == "vacate" && "$adv" == "false" && "$recall" == "true" \
        && "$ts" == "2026-04-28T08:17:00Z" ]]; then
    pass_at "AC-WAIT-1 (ENG-85): wait verdict on stage:building → vacate/false/wait_recall=true"
  else
    fail_at "AC-WAIT-1 (ENG-85): wait verdict classification" \
      "got slot=$slot adv=$adv recall=$recall ts=$ts (want vacate/false/true/2026-04-28T08:17:00Z) full=$out"
  fi
  ```

  The fixture data (`reset_fixtures` + `write_comments_fixture`)
  is byte-identical to the pre-ENG-85 ENG-45 case — only the
  assertion inverts.

### Task 5: Add AC-WAIT-2 — slot-vacated property (sibling held wins Pass 4)

- `depends_on: [3, 4]`
- `touches: bin/poll-slot-test.sh (append after AC-WAIT-1)`

- [ ] **Step 5.1 — Append AC-WAIT-2 case.** Add the following
  block immediately after AC-WAIT-1:

  ```bash
  # ─── AC-WAIT-2 (ENG-85): two issues, ENG-A waits at stage:building,
  #     ENG-B held at stage:qa, max_concurrent=2. After classify, ENG-A
  #     is vacate; ENG-B is hold. Pass 4 dispatches ENG-B, NOT ENG-A.
  #     This is the literal regression test for the issue body's
  #     "ENG-79 starved 45 min" scenario.
  reset_fixtures
  write_label_fixture "stage:building" "ENG-WAIT-A|In Progress|1|stage:building"
  write_label_fixture "stage:qa"       "ENG-WAIT-B|In Progress|1|stage:qa"
  write_comments_fixture "ENG-WAIT-A" \
    '<!-- pipeline: transition from=implementing to=building -->|2026-04-28T08:00:00Z' \
    '<!-- pipeline: verdict result=wait reason=awaiting-approval -->|2026-04-28T08:17:00Z'
  write_comments_fixture "ENG-WAIT-B" \
    '<!-- pipeline: transition from=reviewing to=qa -->|2026-04-28T08:05:00Z'
  out="$(main 2>/dev/null || true)"
  issue_id="$(jq -r '.issue_id // "null"' <<<"$out")"
  reason="$(jq -r '.reason // ""' <<<"$out")"
  if [[ "$issue_id" == "ENG-WAIT-B" && "$reason" == "held slot at stage:qa" ]]; then
    pass_at "AC-WAIT-2 (ENG-85): ENG-A waits, ENG-B (stage:qa) wins Pass 4 dispatch"
  else
    fail_at "AC-WAIT-2 (ENG-85): wait-vacates slot for sibling held work" \
      "got issue_id=$issue_id reason=$reason (want ENG-WAIT-B / held slot at stage:qa) full=$out"
  fi
  ```

  Setup notes:
  - Two label fixtures (one per stage), so Pass 1's `_poll_gather_stage_labeled_issues`
    iterates `workflow_stages` and picks up both via the
    `list-issues-with-label` stub.
  - Both issues have priority=1 (Urgent, max priority_sort_rank).
  - ENG-WAIT-B has only a transition marker (no verdict), so it
    flows through the catch-all else as `slot:hold,
    advanceable:true`. ENG-WAIT-A has the wait verdict, so it
    flows through the new branch as `slot:vacate, ...`.
  - Pass 3's `held` extraction picks ENG-WAIT-B (the only `slot ==
    "hold"` issue). Pass 4 dispatches it.

### Task 6: Add AC-WAIT-3 — Pass 6 fallback when no other ready work

- `depends_on: [3, 4]`
- `touches: bin/poll-slot-test.sh (append after AC-WAIT-2)`

- [ ] **Step 6.1 — Append AC-WAIT-3 case.** Add the following
  block:

  ```bash
  # ─── AC-WAIT-3 (ENG-85): single wait issue, empty inbox, no other
  #     classified issues → Pass 6 fires with reason
  #     "wait re-pickup at stage:building (no other ready work)".
  reset_fixtures
  write_label_fixture "stage:building" "ENG-WAIT-C|In Progress|1|stage:building"
  write_comments_fixture "ENG-WAIT-C" \
    '<!-- pipeline: transition from=implementing to=building -->|2026-04-28T08:00:00Z' \
    '<!-- pipeline: verdict result=wait reason=awaiting-approval -->|2026-04-28T08:17:00Z'
  # No inbox fixture written → list-issues-in-state stub returns empty.
  out="$(main 2>/dev/null || true)"
  issue_id="$(jq -r '.issue_id // "null"' <<<"$out")"
  stage="$(jq -r '.stage // ""' <<<"$out")"
  entry="$(jq -r '.entry_action // ""' <<<"$out")"
  reason="$(jq -r '.reason // ""' <<<"$out")"
  if [[ "$issue_id" == "ENG-WAIT-C" && "$stage" == "building" \
        && "$entry" == "run" && "$reason" == *"wait re-pickup at stage:building"* ]]; then
    pass_at "AC-WAIT-3 (ENG-85): Pass 6 recalls wait issue when no other ready work"
  else
    fail_at "AC-WAIT-3 (ENG-85): Pass 6 wait recall" \
      "got issue_id=$issue_id stage=$stage entry=$entry reason=$reason full=$out"
  fi
  ```

  Setup note: the `list-issues-in-state Todo` stub returns an
  empty fixture when no `state-Todo.json` is written; this is the
  default. Pass 5's `inbox_pick` resolves to empty, so Pass 6 is
  reached.

### Task 7: Add AC-WAIT-4 — Pass 6 FIFO tiebreak (older wait wins)

- `depends_on: [3, 4]`
- `touches: bin/poll-slot-test.sh (append after AC-WAIT-3)`

- [ ] **Step 7.1 — Append AC-WAIT-4 case.** Add the following
  block:

  ```bash
  # ─── AC-WAIT-4 (ENG-85): two wait issues, equal priority. Pass 6
  #     picks the older one (FIFO tiebreak by wait_progress_ts asc).
  reset_fixtures
  write_label_fixture "stage:building" \
    "ENG-WAIT-D|In Progress|1|stage:building" \
    "ENG-WAIT-E|In Progress|1|stage:building"
  write_comments_fixture "ENG-WAIT-D" \
    '<!-- pipeline: transition from=implementing to=building -->|2026-04-28T08:00:00Z' \
    '<!-- pipeline: verdict result=wait reason=awaiting-approval -->|2026-04-28T10:00:00Z'
  write_comments_fixture "ENG-WAIT-E" \
    '<!-- pipeline: transition from=implementing to=building -->|2026-04-28T08:00:00Z' \
    '<!-- pipeline: verdict result=wait reason=awaiting-approval -->|2026-04-28T10:05:00Z'
  out="$(main 2>/dev/null || true)"
  issue_id="$(jq -r '.issue_id // "null"' <<<"$out")"
  if [[ "$issue_id" == "ENG-WAIT-D" ]]; then
    pass_at "AC-WAIT-4 (ENG-85): Pass 6 FIFO tiebreak — older wait (ENG-WAIT-D) wins"
  else
    fail_at "AC-WAIT-4 (ENG-85): Pass 6 FIFO" "got issue_id=$issue_id (want ENG-WAIT-D) full=$out"
  fi
  ```

  Setup: both ENG-WAIT-D and ENG-WAIT-E carry priority=1 (Urgent).
  ENG-WAIT-D's wait timestamp is older (10:00:00Z vs 10:05:00Z);
  ascending sort on `wait_progress_ts` puts D first.

### Task 8: Add AC-WAIT-5 — Pass 6 priority dominates FIFO

- `depends_on: [3, 4]`
- `touches: bin/poll-slot-test.sh (append after AC-WAIT-4)`

- [ ] **Step 8.1 — Append AC-WAIT-5 case.** Add the following
  block:

  ```bash
  # ─── AC-WAIT-5 (ENG-85): two wait issues, different priority. Pass 6
  #     picks the higher-priority one regardless of wait_progress_ts.
  #     ENG-WAIT-F (priority=Normal=3) wait at 10:00:00Z;
  #     ENG-WAIT-G (priority=Urgent=1) wait at 10:05:00Z.
  #     Urgent wins despite being newer.
  reset_fixtures
  write_label_fixture "stage:building" \
    "ENG-WAIT-F|In Progress|3|stage:building" \
    "ENG-WAIT-G|In Progress|1|stage:building"
  write_comments_fixture "ENG-WAIT-F" \
    '<!-- pipeline: transition from=implementing to=building -->|2026-04-28T08:00:00Z' \
    '<!-- pipeline: verdict result=wait reason=awaiting-approval -->|2026-04-28T10:00:00Z'
  write_comments_fixture "ENG-WAIT-G" \
    '<!-- pipeline: transition from=implementing to=building -->|2026-04-28T08:00:00Z' \
    '<!-- pipeline: verdict result=wait reason=awaiting-approval -->|2026-04-28T10:05:00Z'
  out="$(main 2>/dev/null || true)"
  issue_id="$(jq -r '.issue_id // "null"' <<<"$out")"
  if [[ "$issue_id" == "ENG-WAIT-G" ]]; then
    pass_at "AC-WAIT-5 (ENG-85): Pass 6 priority dominates FIFO (Urgent wins over Normal)"
  else
    fail_at "AC-WAIT-5 (ENG-85): Pass 6 priority" "got issue_id=$issue_id (want ENG-WAIT-G) full=$out"
  fi
  ```

  Setup note: priority=1 in `write_label_fixture`'s spec is Urgent
  (Linear's enum: Urgent=1, High=2, Normal=3, Low=4, None=0). The
  derived `priority_sort_rank` is `5 - 1 = 4` for Urgent, `5 - 3
  = 2` for Normal, so Urgent has the higher rank. The Pass 6
  sort key `-priority_sort_rank` (descending) puts Urgent first.

### Task 9: Add AC-WAIT-6 — `external_signal_budget` halt-handoff regression pin

- `depends_on: [3, 4]`
- `touches: bin/poll-slot-test.sh (append after AC-WAIT-5)`

- [ ] **Step 9.1 — Append AC-WAIT-6 case.** Add the following
  block:

  ```bash
  # ─── AC-WAIT-6 (ENG-85, ENG-45 hand-off): when budget exhausts,
  #     _handle_wait writes a halt verdict + applies pipeline:halted.
  #     find_fresh_wait_verdict returns empty (latest verdict is halt,
  #     not wait — supersession rule). The existing pipeline-halt arm
  #     at bin/poll.sh:242-243 fires (slot=vacate, advanceable=false,
  #     no wait_recall). Pins the brainstorm §"Acceptance" §4 hand-off:
  #     "ENG-45 external_signal_budget escalation path still works
  #     (wait → halt-for-budget-exhausted → existing halt vacate)."
  reset_fixtures
  write_comments_fixture "ENG-WAIT-H" \
    '<!-- pipeline: transition from=implementing to=building -->|2026-04-28T08:00:00Z' \
    '<!-- pipeline: verdict result=wait reason=awaiting-approval -->|2026-04-28T10:00:00Z' \
    '<!-- pipeline: verdict result=halt reason=external-signal-budget-exhausted -->|2026-04-28T10:30:00Z'

  out="$(_poll_classify_labels "ENG-WAIT-H" '["stage:building","pipeline:halted"]')"
  slot="$(jq -r '.slot // ""' <<<"$out")"
  adv="$(jq -r '.advanceable // ""' <<<"$out")"
  recall="$(jq -r '.wait_recall // false' <<<"$out")"
  if [[ "$slot" == "vacate" && "$adv" == "false" && "$recall" == "false" ]]; then
    pass_at "AC-WAIT-6 (ENG-85): budget-exhausted halt routes through halted arm, NOT wait arm"
  else
    fail_at "AC-WAIT-6 (ENG-85): halt-handoff" \
      "got slot=$slot adv=$adv recall=$recall (want vacate/false/false) full=$out"
  fi
  ```

  Setup note: the comments fixture has wait at 10:00:00Z THEN halt
  at 10:30:00Z. `find_fresh_verdict` returns the halt (latest
  actionable verdict in the post-transition window).
  `find_fresh_wait_verdict` is NOT called because the halted arm
  (`elif [[ "$(_has_label pipeline:halted)" == "true" ]]`) fires
  first at line 231. The halted arm's `pipeline-halt` case at
  line 242-243 sets `slot:"vacate", advanceable:false`. The
  output JSON has NO `wait_recall` key (it's only set by the new
  wait arm) — `wait_recall // false` defaults to `false`.

### Task 10: Run the full test gate

- `depends_on: [1, 2, 3, 4, 5, 6, 7, 8, 9]`
- `touches: (verification only — no file edits)`

- [ ] **Step 10.1 — Syntactic checks.**
  ```
  bash -n bin/poll.sh
  bash -n bin/verdict-handler.sh
  bash -n bin/poll-slot-test.sh
  ```
  All must exit 0.

- [ ] **Step 10.2 — Direct test invocation.**
  `bash bin/poll-slot-test.sh` must exit 0 with the summary
  reporting all six new AC-WAIT-* cases as `PASS`. The pre-existing
  cases (AC-1 through AC-9, ENG-50 cases, QA adversarial cases at
  lines 820-861) must remain at PASS.

- [ ] **Step 10.3 — Adjacent verdict-handler test.**
  `bash bin/verdict-handler-test.sh` must exit 0. The new
  `find_fresh_wait_verdict` helper is not directly tested by this
  file (per O-2); the test must remain green because it only
  exercises `find_fresh_verdict`, `apply_transition`, and
  `verdict_handler` — all unchanged.

- [ ] **Step 10.4 — Pre-commit hook end-to-end.** Run
  `bash .githooks/pre-commit` and confirm exit 0. The hook runs
  the full `bin/*-test.sh` suite (~30 s); all currently-passing
  tests must continue to pass. The
  `bin/run-local-helpers-adversarial-test.sh` and
  `bin/halt-sprawl-adversarial-test.sh` are particularly important
  to monitor — they exercise adjacent slot-classification and
  halt-sprawl observation paths.

- [ ] **Step 10.5 — Secret-probe lint.** Run
  `bash bin/secret-probe-lint.sh` and confirm exit 0. ENG-85's
  edits reference no secret-shaped env var; the new helper passes
  `$issue` (Linear identifier — `ENG-N` shape, not a secret) and
  the JSON fields `reason`, `comment_id`, `created_at` (closed
  vocabulary or registry-derived).

### Task 11: Stage commit

- `depends_on: [10]`
- `touches: (commit metadata only — no file edits)`

- [ ] **Step 11.1 — Commit the changes.** Stage
  `bin/verdict-handler.sh`, `bin/poll.sh`,
  `bin/poll-slot-test.sh`, and (if not already in tree) the
  brainstorm + plan docs. Commit with message
  `fix(ENG-85): wait verdict vacates slot; main() Pass 6 recalls when nothing else ready`.
  The pre-commit hook re-runs the full suite. Per-stage allowed-tool
  lane in `dispatch.sh::allowed_tools_for` for `implementing` allows
  `bash bin/poll-slot-test.sh:*`, `bash bin/verdict-handler-test.sh:*`,
  `bash bin/secret-probe-lint.sh:*`, and
  `bash .githooks/pre-commit:*` per the harness-self lane (verified
  in CLAUDE.md "Per-target dispatch.tools extras (ENG-51, ENG-53 #8)" §).
  No `gh pr create` is called by the implement agent (forbidden by
  ENG-43's transcript-based assertion); the orchestrator owns PR
  creation.

## Frontend Tasks

No UI surface; the harness has no frontend. **No frontend tasks.**

## Failure Mode → Test Map

Pulled from brainstorm §7 "Error handling" and §8 "Edge cases" — each
row binds to a concrete test or verification step.

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
|---|---|---|---|---|
| Wait verdict on `stage:building` issue with no halt label | `_handle_wait` re-emits wait every tick (current behaviour) | `_poll_classify_labels` routes through new wait branch → `slot:vacate, advanceable:false, wait_recall:true, wait_progress_ts:<ts>` | unit | `bin/poll-slot-test.sh::AC-WAIT-1` |
| Sibling held issue at earlier stage starves while wait holds slot | Two issues: ENG-A wait at building, ENG-B held at qa, max=2 | Pass 4 dispatches ENG-B (held arm); ENG-A excluded from held set | integration | `bin/poll-slot-test.sh::AC-WAIT-2` |
| Wait issue is the only work; nothing else ready | Single wait issue, empty inbox | Pass 6 fires; emits dispatch JSON with `entry_action:"run"` and reason `wait re-pickup at stage:building (no other ready work)` | integration | `bin/poll-slot-test.sh::AC-WAIT-3` |
| Two wait issues, equal priority — FIFO ordering | Both Urgent, ENG-A wait at 10:00, ENG-B wait at 10:05 | Pass 6 picks older (ENG-A) via `wait_progress_ts asc` tiebreak | integration | `bin/poll-slot-test.sh::AC-WAIT-4` |
| Two wait issues, different priority | ENG-F Normal wait at 10:00, ENG-G Urgent wait at 10:05 | Pass 6 picks ENG-G (Urgent) regardless of FIFO order | integration | `bin/poll-slot-test.sh::AC-WAIT-5` |
| `external_signal_budget` exhausts mid-wait | `_handle_wait` posts halt verdict + applies `pipeline:halted` | Halted arm fires (line 231); halt-marker case sets `slot:vacate, advanceable:false, NO wait_recall`; new wait branch unreached | unit | `bin/poll-slot-test.sh::AC-WAIT-6` |
| Linear API outage during `find_fresh_wait_verdict` | `bash linear.sh get-comments` exits non-zero or returns null | Helper returns empty via `\|\| { printf ''; return 0; }`; classifier falls through to reviewing/else branch (pre-ENG-85 behaviour); next tick retries | smoke | `bash -n bin/verdict-handler.sh` confirms `2>/dev/null \|\| { printf ''; return 0; }` is syntactically present per Task 1 Step 1.1 |
| Wait verdict superseded by halt before next tick | Budget exhausts mid-tick; halt comment lands before classify | Latest verdict is halt; `find_fresh_wait_verdict` returns empty (`fresh_result != "wait"`); halted arm handles | unit | `bin/poll-slot-test.sh::AC-WAIT-6` (covers this exact scenario) |
| Wait verdict superseded by pivot/fail/pass before next tick | Agent emits a transition or rejection later than the wait | Latest verdict is non-wait; helper returns empty; classifier falls through to else branch (issue moves on its actionable verdict) | smoke | `bash -n bin/poll.sh` confirms control-flow; behavioral coverage by `_fresh_wait_reason`'s mirrored ENG-61 Bug B test in `bin/run-stage-test.sh` (untouched) |
| Wait verdict's `createdAt` is in the future (clock skew) | Agent host clock ahead of orchestrator | `wait_progress_ts` sorts last; jq `sort_by` handles arbitrary string timestamps; no crash | smoke | `bash -n bin/poll.sh` confirms `sort_by([-(.priority_sort_rank), .wait_progress_ts])` is present |
| `max_concurrent_features = 1` (single-slot mode) | `held_count` toggles 0/1; cap = 1 | Pass 6's `held_count < max_concurrent` guard permits one Pass-6 dispatch per idle tick | smoke | `bash -n bin/poll.sh` confirms guard syntax; `bin/poll-slot-test.sh`'s default `max_concurrent_features=2` doesn't directly exercise — recorded as test-coverage gap (low-cost; cap is read at line 410, not branched) |
| Operator-posted wait via `bin/pipeline.sh event ENG-N verdict wait --reason awaiting-approval` | Manual operator action | `parse_pipeline_marker` recognizes the marker; `find_fresh_wait_verdict` returns it; new wait branch fires → vacate | smoke | `bash -n bin/common.sh` confirms `parse_pipeline_marker` unchanged; `bin/pipeline.sh::event` write-time validation still gates against `wait_reasons` registry per A-012 |
| Wait reason outside the `wait_reasons` allow-list (defensive — should not happen post-write-time-validation) | Hand-rolled writer (not via `pipeline.sh::event`) emits `result=wait reason=foo` | `find_fresh_wait_verdict` returns the marker verbatim (no read-side validation); Pass 6 dispatches; the ill-formed reason is just metadata | smoke | not pinned (out-of-vocabulary reasons are an upstream contract violation per brainstorm §3) |
| Two waits with identical `wait_progress_ts` (Linear millisecond collision) | Wildly improbable | jq `sort_by` is stable in jq ≥1.6; falls back to `_poll_gather_stage_labeled_issues` output order | n/a | recorded as O-4 in brainstorm; not test-pinned |
| `find_fresh_wait_verdict` returns wait-shape but the issue carries `pipeline:halted` | Race window: halt label applied but wait marker still latest verdict (impossible per `_handle_wait` ordering at line 562-570 — halt comment posts BEFORE label) | Halted arm at line 231 fires before wait arm; halt-no-fresh-marker case sets `slot:hold, advanceable:false`; race window ≤1 tick | unit | implicitly covered by AC-WAIT-6's branch-ordering pin |
| Wait emitted on a `stage:reviewing` issue (agent protocol violation per ENG-54) | Hypothetical future bug — review agent emits wait shape | New wait arm fires BEFORE reviewing arm; vacates the slot. Strictly safer than pre-ENG-85's re-dispatch loop on a broken review | unit | not pinned (defense-in-depth; brainstorm §4 D-002 documents the ordering rationale) |

## Test Strategy

### Unit / Classification tests (D-001 + D-002)

The new `_poll_classify_labels` wait branch is exercised by:

1. **AC-WAIT-1** (replaces ENG-45 fixture) — direct
   `_poll_classify_labels` invocation; pins the four-key output
   shape (slot, advanceable, wait_recall, wait_progress_ts).
2. **AC-WAIT-6** — direct `_poll_classify_labels` invocation with
   halt label present; pins that the halted arm fires BEFORE the
   new wait arm (branch-ordering invariant).

The new `find_fresh_wait_verdict` helper is exercised
end-to-end through these classification cases; per O-2, no
direct unit test in `bin/verdict-handler-test.sh` is added in
this iteration.

### Integration tests (D-003)

The new Pass 6 in `main()` is exercised by:

3. **AC-WAIT-2** — `main()`-level test; two issues, sibling held
   wins Pass 4; pins the literal regression scenario from the
   issue body's "Observed" section (ENG-79 starved 45 min).
4. **AC-WAIT-3** — `main()`-level test; single wait issue, empty
   inbox; pins Pass 6 fires with the expected reason string.
5. **AC-WAIT-4** — `main()`-level test; two equal-priority waits,
   older wins (FIFO tiebreak).
6. **AC-WAIT-5** — `main()`-level test; two different-priority
   waits, Urgent wins regardless of FIFO.

### Sibling tests (untouched, expected to stay green)

- `bin/verdict-handler-test.sh` — exercises `find_fresh_verdict`
  (unchanged), `apply_transition` (unchanged), `verdict_handler`
  (unchanged). Should remain at PASS.
- `bin/halt-sprawl-test.sh` and
  `bin/halt-sprawl-adversarial-test.sh` — exercise
  `_poll_emit_halt_sprawl_alert`'s `select(.slot == "vacate")`
  filter at line 346. The new wait branch emits `slot:"vacate"`
  with `wait_recall:true`; halt-sprawl observer sees them as
  vacate (treats them like halts). This is the
  intended "agent-idle-on-external-signal" symmetric treatment —
  but the halt-sprawl alert thresholds (`alert_on_halted_over` at
  the test config) are configured for halt-shape vacates, not
  wait-shape vacates. **Risk:** AC-WAIT-2 might marginally bump
  the alert count if the halt-sprawl observer fires on the test's
  scratch fixture set. Mitigation: the halt-sprawl tests use their
  own `reset_fixtures` + scoped fixture set; the new AC-WAIT-* cases
  are LATER in the file (post line 449), so they cannot leak
  fixtures backward into halt-sprawl test scope.
- `bin/run-stage-test.sh` and
  `bin/run-local-helpers-adversarial-test.sh` — exercise
  `_handle_wait` and `_fresh_wait_reason`; both unchanged.
- `bin/dispatch-test.sh`, `bin/render-prompt-test.sh`,
  `bin/scope-check-test.sh`, `bin/classify-failure-test.sh`,
  `bin/linear-test.sh`, `bin/metrics-test.sh`, `bin/mutex-test.sh`,
  `bin/setup-helpers-test.sh`, `bin/phase-project-profile-test.sh`,
  `bin/common-test.sh` — all unaffected.

### Smoke (syntactic) tests

`bash -n bin/poll.sh`, `bash -n bin/verdict-handler.sh`,
`bash -n bin/poll-slot-test.sh` after each task confirm the
incremental edits remain valid bash. The pre-commit hook
(`bash .githooks/pre-commit`) is the canonical full-suite gate.

### Adversarial / E2E coverage (deferred)

- **O-2 (verdict-handler unit test).** Direct
  `find_fresh_wait_verdict` test in
  `bin/verdict-handler-test.sh` would add isolation but no new
  coverage beyond AC-WAIT-1. Deferred.
- **O-1 (per-tick comments cache).** A future optimization to
  thread `comments_cache` through `_poll_classify_all` would save
  ~2-3 Linear API calls per tick. Out of scope.
- **`max_concurrent_features = 1` Pass 6 path.** Not directly
  pinned — the test config at line 124 sets `max_concurrent_features:
  2`. The branch logic is single-line (`(( held_count <
  max_concurrent ))`), syntactic check via `bash -n` is sufficient.

### Test gate (committed to in §"Goal")

```
bash bin/poll-slot-test.sh \
  && bash bin/verdict-handler-test.sh \
  && bash -n bin/poll.sh \
  && bash -n bin/verdict-handler.sh \
  && bash bin/secret-probe-lint.sh \
  && bash .githooks/pre-commit
```

The pre-commit hook (`bash .githooks/pre-commit`) is a strict
superset of the first five commands and is the canonical
run-it-all gate.

## Self-review summary (5 personas)

Five personas dispatched against this plan: feasibility, scope,
coherence, design, product.

### Iteration 1

| Persona | Verdict | P0 | P1 |
|---|---|---|---|
| feasibility | PASS | 0 | 1 |
| scope | PASS | 0 | 0 |
| coherence | PASS | 0 | 0 |
| design | PASS | 0 | 1 |
| product | PASS | 0 | 0 |

**Status:** Personas: 5/5 PASS · gate P0: 0 · proceeding to implementing.

Gate criterion (≥4/5 PASS, zero P0) cleared at iteration 1. P1
advisories below are recorded for transparency; none rise to a
blocking concern.

The brainstorm carried 6/6 PASS at iteration 1 with zero
unresolved P0; this plan is a faithful crystallisation of
brainstorm §4 decisions D-001/D-002/D-003/D-004. All codebase-fact
assumptions re-verified against the current worktree at the time
of plan-writing (see Assumption Inventory A-001 through A-016).

Persona findings:

- **feasibility (PASS, 0 P0, 1 P1).** All 16 modified-file
  assumptions (A-001 through A-016) `path:line`-cited against
  current code via Read/Grep on this worktree. The `depends_on`
  graph is correct: Task 1 has no deps; Task 2 depends on 1
  (uses the new helper); Task 3 depends on 2 (uses the new
  classifier output); Tasks 4-9 depend on 3+4 (test fixtures
  exercise both layers); Task 10 depends on 1-9; Task 11 depends
  on 10. The graph has parallelism only at the test-fixture layer
  (Tasks 4-9 are independent of each other after Task 3 lands),
  which the task list reflects.
  - **P1 (recorded):** AC-WAIT-2's reliance on the
    `_poll_gather_stage_labeled_issues` stub — it must
    list-issues-with-label both `stage:building` and `stage:qa` in
    the iteration order specified by `workflow_stages` config. The
    test config at line 127 already sets the canonical 8-stage
    list, so iteration order is deterministic. Verified by reading
    AC-1's existing two-stage fixture pattern (which the new AC-WAIT-2
    mirrors). Not blocking; recorded for transparency.

- **scope (PASS, 0 P0, 0 P1).** Every File Structure entry traces
  to brainstorm decisions D-001 (verdict-handler helper), D-002
  (poll.sh classifier branch), D-003 (poll.sh main() Pass 6),
  D-004 (poll-slot-test fixtures). Issue body §"Scope" explicitly
  names `bin/poll.sh` and `bin/poll-slot-test.sh`; the third file
  (`bin/verdict-handler.sh`) is the dependency that owns wait
  detection per brainstorm §"Architecture (where code goes)". No
  gold-plating; no `AGENT_PROMPTS.md` or
  `.pipeline-config/config.json` changes; no new
  `dispatch.sh::allowed_tools_for` cases.

- **coherence (PASS, 0 P0, 0 P1).** Plan Goal mirrors brainstorm
  §2 D-002+D-003. Backend Tasks 1-9 each realize one decision or
  one fixture; Task 10 runs the test gate; Task 11 handles commit
  hygiene. Failure Mode → Test Map covers brainstorm §7 (rows 1-9
  via §"Error handling" mapping) AND §8 (rows 10-15 via §"Edge
  cases" mapping). Test Strategy section enumerates unit /
  integration / smoke / sibling-untouched coverage. The
  brainstorm's persona table reported 6/6 PASS at iteration 1;
  this plan does not introduce any new architectural decision
  beyond the brainstorm's D-001 through D-004.

- **design (PASS, 0 P0, 1 P1).** No new abstractions, no new
  dependencies, no new exit codes, no new lane fences. The
  symmetric defense pattern (halt-vacate at one layer, wait-vacate
  at the same layer via marker reading) extends the existing
  `_poll_classify_labels` shape without restructuring it. The
  helper-rather-than-flag decision (D-001 §"Why this rather than
  extending find_fresh_verdict") is documented in the brainstorm
  with three reasons; no contradiction in the plan.
  - **P1 (recorded):** Pass 6's sort key uses `wait_progress_ts`
    string comparison; this is a lexicographic ISO-8601 sort. If
    Linear ever changes its timestamp format (e.g., adds
    millisecond precision: `2026-04-28T08:17:00.123Z`), the
    comparison still works (ISO-8601 sort is forward-compatible
    with sub-second precision). Recorded as a low-probability
    future-compat note; no action.

- **product (PASS, 0 P0, 0 P1).** The plan's verification gate
  exactly maps to the issue body's "Acceptance" §1-§4: §1
  (ENG-79-style scenario where ENG-A waits and ENG-B at qa wins
  next tick) → AC-WAIT-2; §2 (new fixture in
  `bin/poll-slot-test.sh`) → AC-WAIT-1 through AC-WAIT-6; §3
  (wait still progresses when no other ready) → AC-WAIT-3; §4
  (`external_signal_budget` halt-handoff still works) → AC-WAIT-6.
  The "Risks" §"FIFO fairness with priority dominance" is pinned
  by AC-WAIT-4 + AC-WAIT-5. Operator experience post-fix: ~45-min
  starvation eliminated; wait issues still progress (just less
  often when sibling work queued).
