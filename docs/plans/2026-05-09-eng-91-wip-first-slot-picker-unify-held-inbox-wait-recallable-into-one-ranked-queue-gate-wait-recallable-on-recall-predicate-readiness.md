---
linear: ENG-91
date: 2026-05-09
topic: WIP-first slot picker — collapse poll.sh Pass 4/5/6 into one ranked queue and gate wait_recallable inclusion on entry-conditions readiness
---

# Plan — ENG-91 WIP-first slot picker

Implementation plan for the design in
`docs/brainstorms/2026-05-09-eng-91-wip-first-slot-picker-unify-held-inbox-wait-recallable-into-one-ranked-queue-gate-wait-recallable-on-recall-predicate-readiness-design.md`.

## Anti-anchoring

- **Problem (operator's words):** an approved-PR build (`stage:building`,
  wait_recallable, entry-conditions ready) sits idle behind an earlier-stage
  held issue and a fresh inbox arrival, because `bin/poll.sh::main` walks
  three sequential passes (Pass 4 held → Pass 5 inbox → Pass 6 wait-recall)
  and `exit 0`s after the first dispatch. The 2026-05-09 incident pins
  ~60+ min of latency on a near-merge ticket while a starting ticket
  consumed the slot.
- **Does the brainstorm address it?** Yes, directly. It collapses Pass
  4/5/6 into one ranked picker (D-001) sorted
  `[-stage_index, -priority_sort_rank, fifo_ts]` (D-002), and gates
  wait_recallable inclusion on `bin/entry-conditions.sh::should_dispatch`
  returning `proceed` (D-003). No problem reframing — every decision
  traces to an AC-* row.
- **Proportional?** Yes. Five files modified, zero new files. New
  helpers (`_picker_build_pool`, `_picker_predicate_ready`) live next to
  the existing `_poll_classify_all` in `bin/poll.sh`; reuse
  `bin/entry-conditions.sh` (ENG-86) as the predicate registry; one-line
  GraphQL augmentation to `bin/linear.sh::list_issues_in_state`; six
  new fixtures in `bin/poll-slot-test.sh` plus an inversion of AC-WAIT-2;
  one-row CLAUDE.md addition. No new label, no new pipeline event, no
  new schema field, no new dependency.
- **No escalation needed.**

## Goal

Replace `bin/poll.sh::main`'s sequential Pass 4 / Pass 5 / Pass 6 dispatch
ladder (`bin/poll.sh:448-537`) with a single ranked picker (Pass 4U)
backed by a new `_picker_build_pool` helper that (a) unions held +
wait_recallable + inbox candidates into one pool sorted
`[-stage_index, -priority_sort_rank, fifo_ts]`, (b) excludes
wait_recallable rows whose `bin/entry-conditions.sh::should_dispatch`
returns `skip:*`, and (c) preserves the cap discipline (held always
included; wait + inbox cap-guarded by `held_count < max_concurrent`) —
verifiable via `bash bin/poll-slot-test.sh && bash bin/linear-test.sh
&& bash -n bin/poll.sh && bash -n bin/linear.sh && bash bin/secret-probe-lint.sh`
all exit 0 with the existing AC-WAIT-1 / 3 / 4 / 5 / 6 / 7 fixtures
unchanged, AC-WAIT-2 rewritten to assert ENG-WAIT-A (building) wins,
and six new AC-PICK-1 through AC-PICK-6 fixtures all PASS.

## Architecture

The change is additive within four existing files: `bin/poll.sh` (new
helpers + Pass 4U replacing the sequential ladder), `bin/linear.sh`
(one-field GraphQL augmentation for `list_issues_in_state`),
`bin/poll-slot-test.sh` (six new fixtures + AC-WAIT-2 rewrite +
`entry-conditions.sh` stub), and `CLAUDE.md` (one row in the
"Failure-mode quick reference" table). No new files. No changes to
`bin/run-stage.sh`, `bin/run-local.sh`, `bin/dispatch.sh`,
`bin/verdict-handler.sh`, `bin/classify-failure.sh`, `bin/metrics.sh`,
`bin/entry-conditions.sh`, `bin/pipeline-events.json`, `AGENT_PROMPTS.md`,
or `.pipeline-config/config.json`.

The architectural pivot is symmetric defense across the slot-classification
surface: ENG-86 added an orchestrator pre-dispatch gate via
`entry-conditions.sh`; ENG-85 added wait-vacates-slot classification;
ENG-91 composes them at the picker layer — a wait_recallable issue
whose predicate evaluates `skip:*` (e.g., PR not yet approved) does
NOT enter the picker pool and therefore does NOT compete for a slot
against held + inbox work. When the predicate flips to `proceed`, the
unified sort key promotes the wait above earlier-stage work (WIP-first).
The agent-side P2 in `AGENT_PROMPTS.md §7` and the orchestrator-side
gate in `bin/run-stage.sh::_entry_conditions_gate` remain the
defense-in-depth fallbacks.

There is no `docs/VISION.md`, `docs/ARCHITECTURE.md`, or
`docs/knowledge/decisions.md` (verified — `ls docs/` returns
`brainstorms/  pipeline-vocabulary.md  pipeline-vocabulary.template.md
plans/  runbooks/`). Governing constraints are CLAUDE.md,
`learned-rules/harness/project-profile.md`, and accepted brainstorms.
There is no `learned-rules/harness/plan.md` (verified — only
`build.md` and `project-profile.md` are present).

## Tech stack

- Bash 3.2+ (Darwin default, harness-self target).
- `jq` for JSON shaping and the new sort key (already a hard dep —
  `bin/common.sh:316-319 config_get`, every `bin/*.sh` jq call).
- No new dependencies. No new dispatch.tools allowlist entry — the
  picker runs on the harness host, never inside an agent sandbox.

## Assumption Inventory

Every modified-file fact below is `path:line`-cited against the
current worktree at
`/Users/rajatgoyal/.local/state/twinning-harness/harness/ENG-91/worktree`.
No artifact is `assumed/new` — the plan touches only existing files.

### `bin/poll.sh` insertion / replacement boundaries

- **A-001 — `main()` sequential picker ladder at `bin/poll.sh:448-537`.**
  Verified — three contiguous blocks, each ending with `exit 0`:

  ```
  448  # Pass 4: attempt dispatch from held slots in sorted order.
  ...
  485    exit 0
  486  done
  487
  488  # Pass 5: inbox pickup, only if a slot is available.
  489  if (( held_count < max_concurrent )); then
  ...
  511      exit 0
  512    fi
  513  fi
  514
  515  # Pass 6 (ENG-85): wait re-pickup as last resort. ...
  ...
  535      exit 0
  536    fi
  537  fi
  ```

  ENG-91 replaces lines 448-537 in their entirety with Pass 4U (the
  unified iteration block). The trailing idle reasons at
  `bin/poll.sh:539-543` (`if (( held_count >= max_concurrent ))` →
  `idle "max-concurrent-reached"`, else `idle "no-work"`) are preserved
  verbatim.

- **A-002 — Pass 4 halt + verdict_handler invocation at
  `bin/poll.sh:467-475`.** Verified:

  ```
  467    local has_halt
  468    has_halt="$(jq -r --arg n "pipeline:halted" \
  469      '[.[] | select(. == $n)] | length > 0' <<<"$labels_json")"
  470    if [[ "$has_halt" == "true" ]]; then
  471      local cur_stage_suffix="${stage_label#stage:}"
  472      if verdict_handler "$ident" "$cur_stage_suffix"; then
  473        log "poll: verdict-handler transitioned $ident; will be picked up next tick"
  474      fi
  475      i=$((i+1)); continue
  476    fi
  ```

  The Pass 4U iteration must preserve this halt-with-fresh-marker arm
  for `picker_source == "held"` only (held-arm semantics — wait_recallable
  rows are vacated and inbox rows are pre-stage-label, neither sees
  `pipeline:halted` via this path). The `i=$((i+1)); continue`
  advances the iteration without dispatching — the new stage is picked
  up on the next tick.

- **A-003 — Pass 5 inbox jq filter at `bin/poll.sh:494-504`.**
  Verified — the `select` chain excludes `stage:*`, `pipeline:paused`,
  `pipeline:abandoned`, `pipeline:skip-until-human-acts`,
  `pipeline:skip-until-code-changes`. Pass 4U preserves this filter
  verbatim inside `_picker_build_pool`'s inbox branch (the existing
  `bash "$SCRIPT_DIR/linear.sh" list-issues-in-state "$inbox_state"`
  pipeline runs unchanged; the jq filter projection is augmented to
  emit `stage_label:"inbox"`, `stage_index:-1`,
  `picker_source:"inbox"`, `fifo_ts:.createdAt // ""`).

- **A-004 — Pass 6 wait-recallable sort + dispatch at
  `bin/poll.sh:519-537`.** Verified — current sort is
  `sort_by([-(.priority_sort_rank), .wait_progress_ts])`; current dispatch
  reason is `"wait re-pickup at $stage_label (no other ready work)"`.
  ENG-91 hoists the sort into the unified `_picker_build_pool` and
  changes the dispatch reason to `"wait re-pickup at $stage_label
  (predicate ready)"` (the "no other ready work" suffix becomes a lie
  under the unified picker — a wait can win against ready siblings).

- **A-005 — `_poll_classify_labels` wait-recallable branch at
  `bin/poll.sh:248-256`.** Verified — sets
  `slot:"vacate", advanceable:false, wait_recallable:true,
  wait_progress_ts:<created_at>`. ENG-91 does NOT modify this
  classifier; the picker reads the existing fields verbatim.

- **A-006 — `_poll_classify_all` augmentation at `bin/poll.sh:299-322`.**
  Verified — emits each item with `slot, advanceable, priority_sort_rank,
  labels, identifier, stage_label, stage_index, priority`. Held items
  inherit `updatedAt` from `_poll_gather_stage_labeled_issues` (line
  159, `{identifier, stage_label, stage_index, priority, labels}` — but
  `updatedAt` is NOT projected today; see A-016 below). The new
  helpers `_picker_build_pool` and `_picker_predicate_ready` land
  immediately AFTER `_poll_classify_all`'s closing `}` at line 322,
  before `_poll_emit_halt_sprawl_alert` at line 340.

- **A-007 — `stage_arg_for_label` helper at `bin/poll.sh:36-38`.**
  Verified:

  ```
  36   stage_arg_for_label() {
  37     grep -E "^${1}=" <<<"$STAGE_LABEL_TO_STAGE_ARG" | head -1 | cut -d= -f2-
  38   }
  ```

  The unified picker invokes `stage_arg_for_label "$stage_label"` for
  held + wait_recallable rows (inbox uses literal `"brainstorming"`).

- **A-008 — `STAGE_LABEL_TO_STAGE_ARG` enumeration at
  `bin/poll.sh:25-33`.** Verified — covers all stages except
  `stage:released`. ENG-91 does not touch this table.

- **A-009 — `idle()` helper at `bin/poll.sh:406-411`.** Verified —
  emits a metrics row, prints `{"issue_id":null,...}`, exits 0. Pass
  4U calls `idle "max-concurrent-reached (...)"` or `idle "no-work"`
  via the unchanged trailing block at `bin/poll.sh:539-543`.

- **A-010 — `_poll_gather_stage_labeled_issues` projection at
  `bin/poll.sh:155-163`.** Verified:

  ```
  155    batch="$(bash "$SCRIPT_DIR/linear.sh" list-issues-with-label "$stage_label" \
  156      | jq -c --arg label "$stage_label" --argjson idx "$idx" '
  157        [.data.issues.nodes[]
  158         | select(.state.name != "Done")
  159         | {identifier:   .identifier,
  160            stage_label:  $label,
  161            stage_index:  $idx,
  162            priority:     (.priority // 0),
  163            labels:       [.labels.nodes[].name]}]')"
  ```

  The held FIFO-source field `updatedAt` is NOT in this projection
  today even though `bin/linear.sh::list_issues_with_label` returns it
  (see A-015). ENG-91 must augment the jq projection to include
  `updatedAt: (.updatedAt // "")` so `_picker_build_pool`'s held branch
  can populate `fifo_ts:.updatedAt`. This is a one-line addition to
  the jq filter at `bin/poll.sh:159-163`.

- **A-011 — `_poll_emit_halt_sprawl_alert` exclusion filter at
  `bin/poll.sh:360, 388`.** Verified — both filters exclude
  `wait_recallable=true` rows from the count and the top-3 list. ENG-91
  does not modify these — `picker_eligible` is orthogonal to halt-sprawl
  inclusion (AC-6 preservation).

### `bin/linear.sh` augmentation

- **A-012 — `list_issues_in_state` GraphQL query at `bin/linear.sh:206-214`.**
  Verified:

  ```
  206  list_issues_in_state() {
  207    local state_name="$1" team_id project_id
  208    team_id="$(config_get '.linear.team_id')"
  209    project_id="$(_require_project_id)"
  210    local q='query($teamId: ID!, $projectId: ID!, $state: String!) { issues(first: 50, filter: { team: { id: { eq: $teamId } }, project: { id: { eq: $projectId } }, state: { name: { eq: $state } } }) { nodes { id identifier title state { name } labels { nodes { name } } priority updatedAt } } }'
  ```

  The projection does NOT include `createdAt` today. D-004 adds it as
  the inbox fifo_ts source.

- **A-013 — `get_issue` query at `bin/linear.sh:194` already projects
  `createdAt`.** Verified — confirms Linear's `Issue` GraphQL type
  supports the field; D-004's projection augmentation is known-supported.

- **A-014 — `list_issues_with_label` projection at `bin/linear.sh:216-224`.**
  Verified — already projects `updatedAt`. Held FIFO source needs no
  GraphQL change; `_poll_gather_stage_labeled_issues` is the
  intermediate that drops the field today (A-010).

- **A-015 — Existing consumers of `list_issues_in_state` (audit for
  the `createdAt` augmentation).**
  - `bin/poll.sh:493` — Pass 5 inbox query. ENG-91 hoists this call
    into `_picker_build_pool`'s inbox branch and consumes the new
    `createdAt` field via `(.createdAt // "")`. No breakage from the
    additive field.
  - `bin/dry-run.sh:183` — diagnostic `inbox_resp="$(... | true)"`,
    consumed only by jq filters that don't read `createdAt`. Additive
    field is non-breaking.
  - `bin/halt-sprawl-test.sh:59`, `bin/poll-slot-test.sh:70`,
    `bin/poll-slot-test.sh:811` — stub call sites that read fixture
    JSONs, not the real query shape. Tests need no edit.
  - `bin/linear-test.sh` — verified by grep: no `list_issues_in_state`
    or `list-issues-in-state` references. No projection-shape assertion
    to update.

### `bin/poll-slot-test.sh` test-extension boundaries

- **A-016 — Source-and-stub fixture pattern at `bin/poll-slot-test.sh:61-97`.**
  Verified — `linear.sh` stub at lines 63-89 (handles `list-issues-with-label`,
  `list-issues-in-state`, `get-comments`, side-effecting subcommands),
  `metrics.sh` and `slack.sh` no-op stubs at lines 91-97. ENG-91 adds
  one new stub: `entry-conditions.sh` (controlled by env var
  `ENTRY_CONDITIONS_STUB_OUTPUT`, defaulting to `proceed`).

- **A-017 — Fixture builders at `bin/poll-slot-test.sh:160-223`.**
  Verified — `write_label_fixture`, `write_inbox_fixture`,
  `write_comments_fixture`. The label-fixture-spec format
  `ENG-N|state_name|priority_int|comma,labels` does not include a
  `createdAt` or `updatedAt` slot. ENG-91's new AC-PICK-* fixtures use
  the same builder shape unchanged — the new sort key's fifo_ts ties
  resolve correctly even when the fixtures emit fields without
  per-issue timestamps because each AC-PICK-* exercises the
  stage_index discriminator, not the fifo_ts tiebreak. (The
  `wait_progress_ts` fifo_ts comes from `write_comments_fixture`'s
  per-comment timestamp arg, already in the API.)

- **A-018 — AC-WAIT-2 fixture at `bin/poll-slot-test.sh:476-497`.**
  Verified — current assertion: `[[ "$issue_id" == "ENG-WAIT-B" &&
  "$reason" == *"stage:qa"* ]]`. The fixture has ENG-WAIT-A waiting
  at `stage:building` (stage_index=6) and ENG-WAIT-B held at `stage:qa`
  (stage_index=5). Pre-ENG-91, Pass 4 picks the held at qa. Post-ENG-91,
  the unified picker promotes ENG-WAIT-A (later stage, predicate ready
  by stub default = `proceed`); the assertion inverts to
  `[[ "$issue_id" == "ENG-WAIT-A" && "$reason" == *"stage:building"* ]]`.

- **A-019 — AC-WAIT-3 fixture at `bin/poll-slot-test.sh:499-519`.**
  Verified — single wait_recallable, empty inbox, no held: ENG-WAIT-C
  wins. The current dispatch reason `"wait re-pickup at stage:building
  (no other ready work)"` is asserted via `*"wait re-pickup at
  stage:building"*` (substring match), so the new reason `"wait
  re-pickup at stage:building (predicate ready)"` continues to pass
  the substring check unchanged.

- **A-020 — AC-WAIT-4 fixture at `bin/poll-slot-test.sh:521-539`.**
  Verified — two wait_recallables at `stage:building`, equal priority,
  different `wait_progress_ts`: older wins. Under the unified picker
  this remains true (same stage_index=6, same priority_sort_rank=4,
  fifo_ts ascending → older wins). No fixture edit needed.

- **A-021 — AC-WAIT-5 fixture at `bin/poll-slot-test.sh:541-562`.**
  Verified — two wait_recallables at same stage, different priority:
  Urgent wins despite newer wait_progress_ts. Under the unified picker,
  same-stage tiebreak = priority_sort_rank descending → Urgent wins.
  No fixture edit needed.

- **A-022 — AC-WAIT-6 / AC-WAIT-7 at `bin/poll-slot-test.sh:564-615`.**
  Verified — these test `_poll_classify_labels` directly (not `main()`),
  so the picker change does not touch them. AC-WAIT-6 pins halted-arm
  precedence over wait-arm; AC-WAIT-7 pins fail-supersedes-wait. Both
  remain valid unchanged.

- **A-023 — `entry-conditions.sh::should_dispatch` contract at
  `bin/entry-conditions.sh:84-138`.** Verified — args `<stage> <issue>`,
  outputs single line `proceed | skip:<reason> | error:<check-name>`,
  exit always 0. The new picker shim `_picker_predicate_ready` consumes
  this exact stdout shape via a `case "$out" in …` switch.

- **A-024 — ENG-86 D-005 empty-config-→-proceed at
  `bin/entry-conditions.sh:96-101`.** Verified — `(( n == 0 )) &&
  { printf 'proceed\n'; return 0; }`. Wait_recallable rows at non-build
  stages (none today per ENG-54, but theoretically possible) get
  `proceed` unconditionally — the picker includes them in the pool.

### `CLAUDE.md` insertion-point boundary

- **A-025 — Failure-mode quick reference table at `CLAUDE.md:512-522`.**
  Verified — table starts at line 512 with `| Symptom | Where to look |`
  header (line 513) and divider (line 514). The new row lands between
  line 517 (`Issue stuck in stage:X`) and line 518 (`Wrong-target Linear
  writes`) per D-006 — groups with the other "issue is healthy but not
  progressing" symptoms. ENG-91's row is distinct from the existing
  `dispatch-skipped` row at line 522 (which covers the orchestrator-side
  ENG-86 gate firing on every tick).

### Cross-file validation assumptions

- **A-026 — jq's `sort_by` is stable in jq ≥ 1.6.** Assumed (consistent
  with every existing `bin/poll.sh` and `bin/poll-slot-test.sh` fixture
  that relies on tiebreak ordering; not pinned by smoke test). Same
  assumption underlies ENG-85's Pass 6 sort and ENG-90's halt-sprawl
  top-3 selector. Real-world tiebreak collisions are improbable
  (millisecond-precision timestamps).

- **A-027 — Linear's `Issue.createdAt` is ISO-8601 UTC,
  lexicographically sortable.** Verified by inspection — every existing
  Linear timestamp in `_poll_classify_labels`, `find_fresh_verdict`,
  `find_fresh_wait_verdict`, and the comment-fixture builder uses ISO-8601
  Zulu format (`YYYY-MM-DDTHH:MM:SSZ` or `…SSS Z`). String comparison
  is correct ordering. Same assumption ENG-85 D-002 already ships.

## File Structure

```
bin/poll.sh                MOD   Replace lines 448-537 (Pass 4/5/6 ladder) with Pass 4U unified iteration. Add _picker_build_pool helper after _poll_classify_all (after line 322, before line 340). Add _picker_predicate_ready shim next to _picker_build_pool. Augment _poll_gather_stage_labeled_issues' jq projection at lines 159-163 to include `updatedAt` (held fifo_ts source).
bin/linear.sh              MOD   Add `createdAt` to the GraphQL projection in list_issues_in_state at line 210 (one field, additive).
bin/poll-slot-test.sh      MOD   Add entry-conditions.sh stub (env-var-driven) next to existing stubs at lines 61-97. Append six new AC-PICK-* fixtures (1-6) after the existing AC-WAIT-7 case (around line 615). Rewrite AC-WAIT-2 (lines 476-497) assertion to expect ENG-WAIT-A (building) winning post-ENG-91 unified picker.
CLAUDE.md                  MOD   Insert one row in "Failure-mode quick reference" table between line 517 (Issue stuck in stage:X) and line 518 (Wrong-target Linear writes) — covers the cross-pool starvation symptom (later-stage approved/ready ticket idles while earlier-stage / inbox dispatches each tick).
```

No new files. No `bin/run-stage.sh`, `bin/dispatch.sh`,
`bin/run-local.sh`, `bin/verdict-handler.sh`, `bin/classify-failure.sh`,
`bin/metrics.sh`, `bin/entry-conditions.sh`, `bin/pipeline-events.json`,
or `AGENT_PROMPTS.md` change.

The brainstorm §5 also lists `bin/linear-test.sh` as a possible-touch
("Update any fixture asserting the projection shape of
list_issues_in_state if such a test exists; verify pre-implement").
A-015 verified the audit: `bin/linear-test.sh` has zero references to
`list_issues_in_state` / `list-issues-in-state`. No edit needed.

## API Contract

no new API surface (this is a bash orchestration repo; the only
inter-script "contracts" exercised by ENG-91 are the existing
`bin/entry-conditions.sh::should_dispatch <stage> <issue>` stdout
shape — `proceed` | `skip:<reason>` | `error:<check-name>` — and the
existing `bin/linear.sh::list_issues_in_state` GraphQL projection,
augmented additively with one new field `createdAt`).

## Backend Tasks

(All tasks are backend — this repo has no UI surface. The Frontend Tasks
section below is a deliberate "no UI surface" note, per the project profile.)

### Task 1: Augment `bin/linear.sh::list_issues_in_state` with `createdAt`

- `depends_on: []`
- `touches: bin/linear.sh::list_issues_in_state (line 210)`
- [ ] In `bin/linear.sh:210`, add `createdAt` to the GraphQL `nodes { … }`
      projection. Single one-token addition; the rest of the query
      string is preserved verbatim. Snippet (the new field appended at
      the end, before the closing braces):

      ```bash
      local q='query($teamId: ID!, $projectId: ID!, $state: String!) { issues(first: 50, filter: { team: { id: { eq: $teamId } }, project: { id: { eq: $projectId } }, state: { name: { eq: $state } } }) { nodes { id identifier title state { name } labels { nodes { name } } priority updatedAt createdAt } } }'
      ```

- [ ] Verify syntax: `bash -n bin/linear.sh` exits 0.
- [ ] Manual confirmation that no consumer reads
      `list_issues_in_state` via a strict-shape assertion (per A-015 audit):
      grep `list_issues_in_state\|list-issues-in-state` across `bin/`
      returns only stub call sites in tests + the diagnostic in
      `dry-run.sh`. Adding a field is non-breaking.

### Task 2: Add `updatedAt` to `_poll_gather_stage_labeled_issues` projection

- `depends_on: []`
- `touches: bin/poll.sh::_poll_gather_stage_labeled_issues (lines 155-163)`
- [ ] In `bin/poll.sh:159-163`, augment the jq projection to include
      `updatedAt: (.updatedAt // "")`. Snippet (new field appended at
      end of object literal):

      ```bash
      batch="$(bash "$SCRIPT_DIR/linear.sh" list-issues-with-label "$stage_label" \
        | jq -c --arg label "$stage_label" --argjson idx "$idx" '
          [.data.issues.nodes[]
           | select(.state.name != "Done")
           | {identifier:   .identifier,
              stage_label:  $label,
              stage_index:  $idx,
              priority:     (.priority // 0),
              labels:       [.labels.nodes[].name],
              updatedAt:    (.updatedAt // "")}]')"
      ```

      Rationale: `bin/linear.sh::list_issues_with_label` already returns
      `updatedAt` (A-014); the gather step drops it today. The picker's
      held-branch fifo_ts reads `(.updatedAt // "")` so a missing /
      empty value sorts to the front of its tier (cosmetic; not a crash).
- [ ] Verify syntax: `bash -n bin/poll.sh` exits 0.

### Task 3: Add `_picker_predicate_ready` shim and `_picker_build_pool` helper

- `depends_on: [1, 2]`
- `touches: bin/poll.sh (insert two helpers after line 322, before line 340)`
- [ ] Insert `_picker_predicate_ready` immediately after the closing `}`
      of `_poll_classify_all` at `bin/poll.sh:322`. Helper signature:
      `_picker_predicate_ready <ident> <stage_arg>`. Returns 0 = proceed
      (include in pool) or fail-open; returns 1 = skip (exclude from
      pool). Mirrors ENG-86 D-010 fail-open semantics. Snippet:

      ```bash
      # ENG-91: recall-predicate readiness shim. Wraps entry-conditions.sh's
      # should_dispatch verb. Returns 0 = predicate ready (include in pool);
      # 1 = predicate said skip; 0 = error/unknown (fail-open per ENG-86 D-010).
      _picker_predicate_ready() {
        local ident="$1" stage_arg="$2"
        local out
        out="$(bash "$SCRIPT_DIR/entry-conditions.sh" should_dispatch \
                 "$stage_arg" "$ident" 2>/dev/null || printf '')"
        case "$out" in
          proceed)  return 0 ;;
          skip:*)   return 1 ;;
          error:*)  return 0 ;;
          *)        return 0 ;;
        esac
      }
      ```

- [ ] Insert `_picker_build_pool` immediately after `_picker_predicate_ready`.
      Helper signature: `_picker_build_pool <classified_json> <held_count>
      <max_concurrent>` → emits a single JSON array on stdout, sorted
      by `[-stage_index, -priority_sort_rank, fifo_ts]`. Each item
      carries `picker_source ∈ {held, wait_recallable, inbox}`,
      `fifo_ts`, and the existing classifier fields (held +
      wait_recallable rows) or fresh inbox fields. Snippet:

      ```bash
      # ENG-91: assemble the unified picker pool. Returns a JSON array of
      # candidates, each carrying picker_source ∈ {held, wait_recallable, inbox}
      # and fifo_ts, sorted by [-stage_index, -priority_sort_rank, fifo_ts]:
      #   - stage_index descending (later stage wins — WIP-first)
      #   - priority_sort_rank descending (Urgent > High > Normal > Low > None)
      #   - fifo_ts ascending (older wait_progress_ts / createdAt / updatedAt wins)
      # Inbox arrivals get stage_index=-1 (strictly below brainstorming=0).
      #
      # Cap discipline:
      #   - held items always included (already counted in held_count).
      #   - wait_recallable + inbox cap-guarded by held_count < max_concurrent
      #     (matches today's Pass 5/6 cap guards at bin/poll.sh:489 and 519).
      #
      # Wait_recallable items are gated on _picker_predicate_ready before
      # entering the pool — see ENG-91 D-003.
      _picker_build_pool() {
        local classified="$1" held_count="$2" max_concurrent="$3"

        local held_pool
        held_pool="$(jq -c '
          [.[]
           | select(.slot == "hold" and .advanceable == true)
           | . + {picker_source:"held", fifo_ts:(.updatedAt // "")}
          ]' <<<"$classified")"

        local wait_pool='[]' inbox_pool='[]'
        if (( held_count < max_concurrent )); then
          local wait_candidates wn wi=0
          wait_candidates="$(jq -c '
            [.[]
             | select(.slot == "vacate" and (.wait_recallable // false) == true)
            ]' <<<"$classified")"
          wn="$(jq 'length' <<<"$wait_candidates")"
          while (( wi < wn )); do
            local wc wid wstage_label wstage_arg
            wc="$(jq -c ".[$wi]" <<<"$wait_candidates")"
            wid="$(jq -r '.identifier'  <<<"$wc")"
            wstage_label="$(jq -r '.stage_label' <<<"$wc")"
            wstage_arg="$(stage_arg_for_label "$wstage_label")"
            if _picker_predicate_ready "$wid" "$wstage_arg"; then
              local wc_aug
              wc_aug="$(jq -c '. + {picker_source:"wait_recallable", fifo_ts:(.wait_progress_ts // "")}' <<<"$wc")"
              wait_pool="$(jq -c --argjson p "$wait_pool" --argjson x "$wc_aug" '$p + [$x]')"
            else
              log "picker: wait_recallable $wid skipped (predicate not ready)"
            fi
            wi=$((wi+1))
          done

          local inbox_state
          inbox_state="$(config_get '.linear.native_states.inbox')"
          inbox_pool="$(bash "$SCRIPT_DIR/linear.sh" list-issues-in-state "$inbox_state" \
            | jq -c '
              [.data.issues.nodes[]
               | select([.labels.nodes[].name] | any(startswith("stage:")) | not)
               | select([.labels.nodes[].name] | index("pipeline:paused") | not)
               | select([.labels.nodes[].name] | index("pipeline:abandoned") | not)
               | select([.labels.nodes[].name] | index("pipeline:skip-until-human-acts") | not)
               | select([.labels.nodes[].name] | index("pipeline:skip-until-code-changes") | not)
               | {identifier: .identifier,
                  stage_label: "inbox",
                  stage_index: -1,
                  priority_sort_rank: (if (.priority // 0) == 0 then 0 else (5 - .priority) end),
                  picker_source: "inbox",
                  fifo_ts: (.createdAt // "")}]')"
        fi

        jq -c --argjson h "$held_pool" --argjson w "$wait_pool" --argjson i "$inbox_pool" \
          -n '($h + $w + $i) | sort_by([-(.stage_index), -(.priority_sort_rank), .fifo_ts])'
      }
      ```

      Note the `2>/dev/null || printf '[]'` is intentionally NOT applied
      to the inbox `list-issues-in-state` pipe — same error behaviour as
      today's Pass 5 at `bin/poll.sh:493-504`. If the call errors, the
      jq pipe returns `[]` (filter sees no matching nodes). Preserved.
- [ ] Verify syntax: `bash -n bin/poll.sh` exits 0.

### Task 4: Replace Pass 4/5/6 with Pass 4U in `main()`

- `depends_on: [3]`
- `touches: bin/poll.sh::main() (replace lines 448-537)`
- [ ] Delete `bin/poll.sh:448-537` (Pass 4 held loop + Pass 5 inbox
      block + Pass 6 wait-recall block, three contiguous `exit 0`-terminated
      blocks per A-001). Replace with one Pass 4U block:

      ```bash
      # Pass 4U (ENG-91): unified ranked picker over (held, wait_recallable_ready, inbox).
      # Sort key documented at the top of _picker_build_pool:
      #   [-stage_index, -priority_sort_rank, fifo_ts]
      # See docs/brainstorms/2026-05-09-eng-91-…design.md and CLAUDE.md
      # "Failure-mode quick reference" for the cross-pool starvation
      # symptom this resolves.
      local pool n i=0
      pool="$(_picker_build_pool "$classified" "$held_count" "$max_concurrent")"
      n="$(jq 'length' <<<"$pool")"
      while (( i < n )); do
        local cand source ident stage_label labels_json has_halt cur_stage_suffix arg
        cand="$(jq -c ".[$i]" <<<"$pool")"
        source="$(jq -r '.picker_source' <<<"$cand")"
        ident="$(jq -r '.identifier'  <<<"$cand")"

        case "$source" in
          held)
            stage_label="$(jq -r '.stage_label' <<<"$cand")"
            labels_json="$(jq -c '.labels'      <<<"$cand")"
            has_halt="$(jq -r --arg n "pipeline:halted" \
              '[.[] | select(. == $n)] | length > 0' <<<"$labels_json")"
            if [[ "$has_halt" == "true" ]]; then
              cur_stage_suffix="${stage_label#stage:}"
              if verdict_handler "$ident" "$cur_stage_suffix"; then
                log "poll: verdict-handler transitioned $ident; will be picked up next tick"
              fi
              i=$((i+1)); continue
            fi
            arg="$(stage_arg_for_label "$stage_label")"
            jq -nc \
              --arg issue_id "$ident" \
              --arg stage    "$arg" \
              --arg reason   "held slot at $stage_label" \
              '{issue_id:$issue_id, stage:$stage, entry_action:"run", reason:$reason}'
            exit 0 ;;

          wait_recallable)
            stage_label="$(jq -r '.stage_label' <<<"$cand")"
            arg="$(stage_arg_for_label "$stage_label")"
            jq -nc \
              --arg issue_id "$ident" \
              --arg stage    "$arg" \
              --arg reason   "wait re-pickup at $stage_label (predicate ready)" \
              '{issue_id:$issue_id, stage:$stage, entry_action:"run", reason:$reason}'
            exit 0 ;;

          inbox)
            jq -nc \
              --arg issue_id "$ident" \
              --arg stage    "brainstorming" \
              --arg reason   "inbox pickup" \
              '{issue_id:$issue_id, stage:$stage, entry_action:"apply-stage-label", reason:$reason}'
            exit 0 ;;
        esac
      done
      ```

- [ ] Confirm the trailing idle block at `bin/poll.sh:539-543` is
      preserved verbatim (no edit). The `if (( held_count >=
      max_concurrent ))` → `idle "max-concurrent-reached (...)"`, else
      `idle "no-work"` semantics is unchanged.
- [ ] Verify syntax: `bash -n bin/poll.sh` exits 0.
- [ ] Run `bash bin/secret-probe-lint.sh` — confirms no `${VAR:-…}`
      bash-default introduced. The new code uses `${stage_label#stage:}`
      (parameter-substring expansion, not default-fallback) and `// ""`
      (jq alternative, not bash) — lint-clean by construction.

### Task 5: Add `entry-conditions.sh` stub to `bin/poll-slot-test.sh`

- `depends_on: [3]`
- `touches: bin/poll-slot-test.sh (extend stub block at lines 61-97)`
- [ ] After the existing `linear.sh` / `metrics.sh` / `slack.sh` stubs
      at `bin/poll-slot-test.sh:61-97`, add an `entry-conditions.sh`
      stub controlled by env var `ENTRY_CONDITIONS_STUB_OUTPUT`
      (default `proceed`). Snippet:

      ```bash
      # ENG-91 stub: entry-conditions.sh emits whatever's in
      # $ENTRY_CONDITIONS_STUB_OUTPUT (default 'proceed'). Each AC-PICK-*
      # case sets this env var before the `main` invocation to drive the
      # predicate-readiness arm being tested.
      cat > "$STUB_DIR/entry-conditions.sh" <<'SH'
      #!/usr/bin/env bash
      # Verb gate matches the real script's CLI dispatcher.
      [[ "${1:-}" == "should_dispatch" ]] || exit 1
      printf '%s\n' "${ENTRY_CONDITIONS_STUB_OUTPUT:-proceed}"
      SH
      chmod +x "$STUB_DIR/entry-conditions.sh"
      ```

- [ ] Verify syntax: `bash -n bin/poll-slot-test.sh` exits 0.

### Task 6: Rewrite AC-WAIT-2 fixture assertion (post-ENG-91 inversion)

- `depends_on: [4, 5]`
- `touches: bin/poll-slot-test.sh::AC-WAIT-2 (lines 476-497)`
- [ ] At `bin/poll-slot-test.sh:476-497`, leave the fixture setup
      verbatim (ENG-WAIT-A waits at `stage:building`; ENG-WAIT-B held
      at `stage:qa`). Replace the assertion at lines 489-497 with:

      ```bash
      # ENG-91: post-unified-picker, ENG-WAIT-A (stage:building, predicate
      # ready by stub default = 'proceed') wins over ENG-WAIT-B (stage:qa,
      # held). Pre-ENG-91 this fixture asserted the inverse: Pass 4 picked
      # the qa-held and Pass 6 wait-recall never ran. Live-incident regression:
      # the 2026-05-09 ENG-83/ENG-90 race.
      out="$(main 2>/dev/null || true)"
      issue_id="$(jq -r '.issue_id // "null"' <<<"$out")"
      reason="$(jq -r '.reason // ""' <<<"$out")"
      if [[ "$issue_id" == "ENG-WAIT-A" && "$reason" == *"stage:building"* ]]; then
        pass_at "AC-WAIT-2 (ENG-91): later-stage wait_recallable beats earlier-stage held"
      else
        fail_at "AC-WAIT-2 (ENG-91): unified-picker WIP-first inversion" \
          "got issue_id=$issue_id reason=$reason (want ENG-WAIT-A / *stage:building*) full=$out"
      fi
      ```

- [ ] Confirm AC-WAIT-3 (line 499-519), AC-WAIT-4 (521-539), AC-WAIT-5
      (541-562), AC-WAIT-6 (564-589), AC-WAIT-7 (591-615) are NOT
      modified. The substring assertion in AC-WAIT-3 (`*"wait re-pickup
      at stage:building"*`) accepts the new dispatch reason
      (`"… (predicate ready)"`) without edit (A-019).

### Task 7: Add six AC-PICK-* fixtures

- `depends_on: [4, 5]`
- `touches: bin/poll-slot-test.sh (append after AC-WAIT-7 closing `fi`, around line 615)`
- [ ] **AC-PICK-1 — wait predicate ready outranks inbox.** ENG-A
      `stage:building` + fresh wait_recallable; `ENTRY_CONDITIONS_STUB_OUTPUT=proceed`;
      ENG-B in inbox state. Assert `main()` dispatches ENG-A with
      reason matching `*"stage:building"*` AND `*"predicate ready"*`;
      ENG-B is NOT picked. Pins AC-3.
- [ ] **AC-PICK-2 — wait predicate not-ready loses to inbox.** Same
      ENG-A as PICK-1; `ENTRY_CONDITIONS_STUB_OUTPUT="skip:awaiting-approval"`;
      ENG-B in inbox state. Assert `main()` dispatches ENG-B with
      `entry_action == "apply-stage-label"`; ENG-A excluded from pool.
      Pins AC-3 contrapositive.
- [ ] **AC-PICK-3 — wait ready outranks earlier-stage held.** ENG-A
      `stage:building` + fresh wait_recallable + stub `proceed`;
      ENG-B `stage:planning` + advanceable held. Assert `main()`
      dispatches ENG-A. Pins AC-4 (live-incident regression).
- [ ] **AC-PICK-4 — multi-fleet WIP-first.** ENG-A `stage:building` +
      ready wait_recallable; ENG-B `stage:planning` + advanceable held;
      ENG-C in inbox; cap=2 (test config default). Assert first
      `main()` invocation dispatches ENG-A. (The "subsequent ticks
      pick ENG-B then ENG-C" property in the brainstorm's AC-5 is not
      directly testable inside one `main()` call; the assertion limits
      itself to "first dispatch is ENG-A" which is the load-bearing
      pinning. Pins AC-5.)
- [ ] **AC-PICK-5 — predicate error fails open.** ENG-A `stage:building`
      + fresh wait_recallable; `ENTRY_CONDITIONS_STUB_OUTPUT="error:pr-approved-by-non-bot"`;
      ENG-B in inbox. Assert `main()` dispatches ENG-A (fail-open per
      D-003). The orchestrator-side ENG-86 gate is the deferred safety
      net (out of scope for this fixture).
- [ ] **AC-PICK-6 — held later-stage outranks wait at earlier-stage.**
      ENG-A `stage:implementing` + fresh wait_recallable + stub `proceed`;
      ENG-B `stage:building` + advanceable held. Assert `main()`
      dispatches ENG-B (building > implementing in stage_index). Pins
      that wait_recallable doesn't always win — stage_index dominates
      `picker_source` within the unified sort.
- [ ] Each fixture pattern: `reset_fixtures` →
      `export ENTRY_CONDITIONS_STUB_OUTPUT=…` →
      `write_label_fixture` / `write_inbox_fixture` /
      `write_comments_fixture` → `out="$(main 2>/dev/null || true)"`
      → assert. Restore the env var to the default (`proceed`) at the
      end of each case so a subsequent fixture inherits a clean state.
      Snippet (AC-PICK-3 body):

      ```bash
      # ─── AC-PICK-3 (ENG-91): wait predicate ready outranks earlier-stage held.
      reset_fixtures
      export ENTRY_CONDITIONS_STUB_OUTPUT=proceed
      write_label_fixture "stage:building" "ENG-PICK3A|In Progress|3|stage:building"
      write_label_fixture "stage:planning" "ENG-PICK3B|In Progress|3|stage:planning"
      write_comments_fixture "ENG-PICK3A" \
        '<!-- pipeline: transition from=implementing to=building -->|2026-05-09T08:00:00Z' \
        '<!-- pipeline: verdict result=wait reason=awaiting-approval -->|2026-05-09T08:17:00Z'
      out="$(main 2>/dev/null || true)"
      issue_id="$(jq -r '.issue_id // "null"' <<<"$out")"
      reason="$(jq -r '.reason // ""' <<<"$out")"
      if [[ "$issue_id" == "ENG-PICK3A" && "$reason" == *"stage:building"* ]]; then
        pass_at "AC-PICK-3 (ENG-91): wait_recallable@building beats held@planning"
      else
        fail_at "AC-PICK-3 (ENG-91): cross-pool starvation regression" \
          "got issue_id=$issue_id reason=$reason (want ENG-PICK3A/*stage:building*) full=$out"
      fi
      export ENTRY_CONDITIONS_STUB_OUTPUT=proceed   # restore default
      ```

      The other five fixtures follow the same skeleton. AC-PICK-4 adds a
      `write_inbox_fixture "ENG-PICK4C|Todo|3|Bug"` step. AC-PICK-2 and
      AC-PICK-5 set `ENTRY_CONDITIONS_STUB_OUTPUT` to non-`proceed` values.
- [ ] Verify: `bash bin/poll-slot-test.sh` exits 0 with all existing
      cases PASS, AC-WAIT-2 PASS under the rewritten assertion, and all
      six AC-PICK-* PASS.

### Task 8: Add CLAUDE.md "Failure-mode quick reference" row

- `depends_on: [4]`
- `touches: CLAUDE.md (insert one row between line 517 and line 518)`
- [ ] Insert a new table row in the "Failure-mode quick reference"
      table at `CLAUDE.md:512-522`, between the `Issue stuck in
      stage:X` row (line 517) and the `Wrong-target Linear writes`
      row (line 518). The row distinguishes cross-pool starvation
      (picker-ordering failure) from per-issue halts (already covered)
      and the global breaker (already covered) — every individual
      issue is healthy, but the queue policy starves work near
      completion. Snippet:

      ```markdown
      | Approved/ready ticket at later stage (e.g. `stage:building` post-approval, or `stage:reviewing` post-PR-mergeable) sits idle while an earlier-stage or inbox issue dispatches each tick | The picker emits `picker: wait_recallable <ENG-N> skipped (predicate not ready)` (ENG-91 D-003) when a wait_recallable's recall predicate evaluates `skip:*`. Verify by inspecting `$PROJECT_STATE_DIR/<slug>/logs/local-YYYY-MM-DD.log`; if the predicate is `proceed` and the issue still loses to an earlier-stage / inbox issue, the picker sort is the bug — see ENG-91. Recovery while waiting for a fix: `bash bin/linear.sh add-label <held-issue> pipeline:paused`, let the next tick re-pick the wait, then `remove-label`. |
      ```

- [ ] No fenced-block change (CLAUDE.md is consumed by humans, not by
      `render-prompt.sh`, so the AGENT_PROMPTS.md two-fences-per-section
      rule does NOT bind here — but for hygiene, ensure no column-0
      ``` fence is introduced).
- [ ] Verify the table renders as a valid Markdown table after the
      insertion (header, divider, then six rows in order).

### Task 9: Run the full test suite and document outcomes

- `depends_on: [1, 2, 3, 4, 5, 6, 7, 8]`
- `touches: (verification step — no file edits)`
- [ ] Run `bash bin/poll-slot-test.sh` → all existing cases PASS,
      AC-WAIT-2 PASS under rewritten assertion, six AC-PICK-* PASS.
- [ ] Run `bash bin/linear-test.sh` → unchanged from main (A-015
      audit confirmed no projection-shape assertion).
- [ ] Run `bash bin/halt-sprawl-test.sh && bash bin/halt-sprawl-adversarial-test.sh`
      → unchanged. AC-6 preservation: halt-sprawl filter at
      `bin/poll.sh:360, 388` still excludes `wait_recallable=true`
      regardless of `picker_source` annotation (which is pool-local).
- [ ] Run `bash -n bin/poll.sh && bash -n bin/linear.sh` → both exit 0.
- [ ] Run `bash bin/secret-probe-lint.sh` → exits 0 (no `${VAR:-…}` /
      `${VAR:+…}` against secret-named env vars introduced).
- [ ] Run the broader test suite per CLAUDE.md "Tests" §:
      `bash bin/dispatch-test.sh && bash bin/run-stage-test.sh &&
      bash bin/scope-check-test.sh && bash bin/verdict-handler-test.sh
      && bash bin/classify-failure-test.sh && bash bin/metrics-test.sh
      && bash bin/mutex-test.sh && bash bin/setup-helpers-test.sh
      && bash bin/render-prompt-test.sh &&
      bash bin/phase-project-profile-test.sh && bash bin/common-test.sh`
      → unchanged from main (the picker change is internal to
      `bin/poll.sh::main`; no other script reads the dispatch-decision
      JSON shape, which is unchanged).

## Frontend Tasks

no UI surface (this repo is bash orchestration scripts; the
`learned-rules/harness/project-profile.md` Stack section confirms
"Bash 3.2+ orchestration scripts… The repo contains no application
code". `bin/dispatch.sh::allowed_tools_for` does not register a
`ui` case for the harness-self target).

## Failure Mode → Test Map

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
| --- | --- | --- | --- | --- |
| Wait_recallable predicate ready outranks fresh inbox | ENG-A wait@building (stub `proceed`); ENG-B in inbox | `main()` dispatches ENG-A with reason `*stage:building*` AND `*predicate ready*`; ENG-B excluded | integration | `bin/poll-slot-test.sh` AC-PICK-1 |
| Wait_recallable predicate skip:* loses to fresh inbox (no wasted slot) | ENG-A wait@building (stub `skip:awaiting-approval`); ENG-B in inbox | `main()` dispatches ENG-B with `entry_action == "apply-stage-label"`; ENG-A excluded from pool; "predicate not ready" log line emitted | integration | `bin/poll-slot-test.sh` AC-PICK-2 |
| Wait_recallable predicate ready outranks earlier-stage held (live-incident regression) | ENG-A wait@building (stub `proceed`); ENG-B held@planning | `main()` dispatches ENG-A — building > planning in stage_index | integration | `bin/poll-slot-test.sh` AC-PICK-3 |
| Multi-fleet WIP-first: building wait + planning held + inbox arrival → building wins | Three issues; stub `proceed`; cap=2 | First `main()` dispatches the building wait | integration | `bin/poll-slot-test.sh` AC-PICK-4 |
| Predicate evaluator error (gh/jq outage) → fail-open in picker | Stub `error:pr-approved-by-non-bot`; ENG-A wait + ENG-B inbox | `main()` dispatches ENG-A (picker fail-open per D-003); orchestrator pre-dispatch gate is the next defense layer | integration | `bin/poll-slot-test.sh` AC-PICK-5 |
| Held at later stage outranks wait_recallable at earlier stage (sort symmetry) | ENG-A wait@implementing (stub `proceed`); ENG-B held@building | `main()` dispatches ENG-B — building > implementing | integration | `bin/poll-slot-test.sh` AC-PICK-6 |
| AC-WAIT-2 inversion: later-stage wait beats earlier-stage held (live-incident regression) | ENG-WAIT-A wait@building (stub `proceed`); ENG-WAIT-B held@qa | `main()` dispatches ENG-WAIT-A — building (stage_index=6) > qa (stage_index=5); WIP-first | integration | `bin/poll-slot-test.sh` AC-WAIT-2 (rewritten) |
| Cap-saturation: only held picked when held_count == max_concurrent | Two held issues at cap=2 + zero ready waits + zero inbox | `main()` dispatches one of the helds; wait + inbox cap-guarded out of pool | integration | `bin/poll-slot-test.sh` AC-1 (existing, unchanged — pre-ENG-91 fixture continues to PASS under unified picker) |
| Halt-with-fresh-stage-summary continues to invoke `verdict_handler` from picker (no regression) | Bare-halted held with `pipeline-stage-summary` marker (cf. AC-3 fixture pre-ENG-91) | Picker iterates past held without dispatching; `verdict_handler` invoked; next tick picks up the new stage | integration | `bin/poll-slot-test.sh` AC-3 (existing, unchanged) |
| Halt-sprawl exclusion preserved for wait_recallable rows (AC-6) | Five wait_recallable issues + `alert_on_halted_over=2` | `_poll_emit_halt_sprawl_alert` count is 0 (waits excluded), no Slack fire | integration | `bin/halt-sprawl-test.sh` (existing, unchanged) |
| Empty pool → idle "no-work" reason emitted | Zero held + zero wait + zero inbox | `idle "no-work"` (preserved trailing block at `bin/poll.sh:539-543`) | integration | `bin/poll-slot-test.sh` AC-5 (existing — current AC-5 covers idle "max-concurrent-reached"; "no-work" has no dedicated existing fixture but is exercised every-tick on empty workspace; not regressed since trailing block is preserved verbatim) |
| `bin/linear.sh::list_issues_in_state` GraphQL augmentation does not break consumers | A-015 audit verified zero strict-shape assertions | All sibling tests PASS unchanged | regression | full test suite (`bash bin/*-test.sh`) per Task 9 |
| `bash -n bin/poll.sh && bash -n bin/linear.sh` exits 0 (no syntax breakage) | After all edits | Zero output, exit 0 | smoke | Task 9 syntax check |

## Test Strategy

- **Unit/integration (existing test runner — `bash bin/poll-slot-test.sh`).**
  The picker change is a `main()` integration concern, not a
  unit-isolatable contract. The new `_picker_build_pool` and
  `_picker_predicate_ready` helpers are exercised through `main()`'s
  call path under fixture-driven test cases. The brainstorm chose
  `bin/poll-slot-test.sh` as the test surface (D-005); ENG-91 follows
  that decision rather than introducing a sibling
  `bin/picker-test.sh` (avoids a new test runner harness; reuses the
  source-and-stub infrastructure at lines 61-115).

- **Regression coverage on the existing `AC-WAIT-1` …
  `AC-WAIT-7` block.** AC-WAIT-1 (classifier-only, line 449-474) is
  unchanged. AC-WAIT-3 / 4 / 5 still pass under the unified picker
  per A-019 / A-020 / A-021. AC-WAIT-6 / 7 exercise
  `_poll_classify_labels` directly (not `main()`) so the picker
  refactor does not touch them.

- **Cross-pool fixtures (the load-bearing additions).** AC-PICK-1
  through AC-PICK-6 collectively pin every cell of the `picker_source
  × predicate_state × stage_ordering` matrix that ENG-91's contract
  amends:
  - PICK-1, PICK-2, PICK-5 cover the predicate-readiness gate
    (ready/skip/error).
  - PICK-3, PICK-4, PICK-6 + AC-WAIT-2 cover the WIP-first stage_index
    discriminator across (held, wait_recallable, inbox).
  Brainstorm D-005 explicitly rejected an exhaustive 24-cell matrix
  (most cells reduce to one of these patterns and add fixture noise
  without increasing coverage).

- **Adversarial cases — sort key edge conditions.** The brainstorm §7
  enumerates six error-handling paths (entry-conditions error mid-tick,
  list_issues_in_state error mid-tick, malformed wait_progress_ts,
  unknown stage_label, identical fifo_ts, future updatedAt clock skew).
  Each is documented as cosmetic / no-crash by inspection of the jq
  filters' default-empty handling (`(.foo // "")`). No dedicated
  adversarial fixture is added — the brainstorm's prose enumeration
  + the Failure Mode → Test Map row "Empty pool → idle `no-work`"
  cover the load-bearing degenerate cases.

- **Smoke (full suite per CLAUDE.md "Tests" §).** Task 9 runs every
  `bin/*-test.sh` plus `bash -n bin/*.sh` plus `bin/secret-probe-lint.sh`.
  Halt-sprawl, classify-failure, verdict-handler, run-stage,
  dispatch — all unchanged from main. The picker refactor does not
  alter the `bin/run-local.sh`-consumed dispatch-decision JSON shape
  (`{issue_id, stage, entry_action, reason}` — every emitter is
  unchanged from pre-ENG-91 except the wait-recall reason suffix
  becomes `(predicate ready)` in place of `(no other ready work)`,
  which no downstream consumer parses).

- **Non-tested invariants (documented but not pinned by fixtures):**
  - O-1 strict stage-transition-timestamp held FIFO (deferred — current
    `updatedAt` proxy ships).
  - O-2 `external_signal_budget.max_attempts` cadence shift (counter
    only advances on tick where wait wins picker — documented behaviour
    change, no fixture).
  - O-4 jq stable-sort assumption (consistent with all existing
    fixtures; not pinned).

## Persona review verdicts

The five required personas dispatched in parallel after the draft was
written; each verified its lens against the current worktree
(`/Users/rajatgoyal/.local/state/twinning-harness/harness/ENG-91/worktree`)
and the brainstorm.

- **Feasibility (PASS).** Every cited path:line was re-verified against
  the current worktree. `bin/poll.sh:448-537` is the contiguous Pass
  4/5/6 ladder (A-001 quoted lines 470-475, 488-512, 519-535).
  `_poll_classify_all` ends at line 322 (A-006); the new helpers land
  immediately after, before `_poll_emit_halt_sprawl_alert` at line 340.
  `_poll_gather_stage_labeled_issues` projection at lines 159-163 (A-010)
  drops `updatedAt` today even though `bin/linear.sh::list_issues_with_label`
  at line 220 returns it (A-014) — Task 2 is required to thread it
  through. `bin/linear.sh:210` is the `list_issues_in_state` projection
  WITHOUT `createdAt` (A-012); `bin/linear.sh:194 get_issue` already
  projects `createdAt` (A-013) — known-supported field. `bin/linear-test.sh`
  has zero `list_issues_in_state` references (A-015 grep). AC-WAIT-2
  fixture's pre-ENG-91 assertion is exactly as quoted (A-018, lines
  489-497). `bin/entry-conditions.sh:84-138 should_dispatch` contract
  verified (A-023). CLAUDE.md insertion-point at lines 517-518 verified
  (A-025). depends_on chains: Task 1+2 are independent; Task 3 needs
  both (the helpers consume the augmented projections); Task 4 needs
  Task 3 (Pass 4U calls the helpers); Task 5 is independent of Task
  3-4 (stub-only); Tasks 6+7 need Task 4+5 (assertions run against
  the new picker behaviour with the stub in place); Task 8 needs Task
  4 (CLAUDE.md row references the new behaviour); Task 9 needs everything.
  Each Failure Mode row names a specific test name. Zero unverified facts.

- **Scope (PASS).** Every File Structure entry traces to a brainstorm
  decision: `bin/poll.sh` (D-001 + D-002 + D-003), `bin/linear.sh`
  (D-004), `bin/poll-slot-test.sh` (D-005), `CLAUDE.md` (D-006). The
  brainstorm's non-changes are honored (no edit to `bin/run-stage.sh`,
  `bin/dispatch.sh`, `bin/run-local.sh`, `bin/verdict-handler.sh`,
  `bin/classify-failure.sh`, `bin/metrics.sh`, `bin/entry-conditions.sh`,
  `bin/pipeline-events.json`, `AGENT_PROMPTS.md`, or
  `.pipeline-config/config.json`). The `bin/run-local.sh` /
  `bin/poll.sh` distinction matches ENG-86 D-001's structural
  precedent (`run-stage.sh` owns stage-execution; `poll.sh` owns
  dispatch-selection; ENG-91 modifies the latter). Tasks `touches`
  lists stay strictly within declared File Structure (no task strays
  to a sibling file). No gold-plating: O-1 (strict held FIFO) deferred
  per brainstorm; mini-DSL rejected; per-source helper split rejected
  per D-001's design rationale.

- **Coherence (PASS).** Goal sentence matches brainstorm §0 (cross-pool
  starvation eliminated via unified picker + predicate-readiness gate).
  Backend Tasks 1-4 jointly realise D-001 (unified picker), D-002 (sort
  key), D-003 (predicate gate), D-004 (createdAt augmentation). Task 5-7
  realise D-005 (test fixture coverage). Task 8 realises D-006 (CLAUDE.md
  row). Failure Mode → Test Map has 12 rows; each binds to a specific
  test name (six new AC-PICK-*, the rewritten AC-WAIT-2, three existing
  fixtures preserved unchanged, two regression-suite rows). Test Strategy
  enumerates the unit/integration/regression layers per CLAUDE.md
  "Tests" §. The "no UI" / "no API" disclaimers match the project profile.

- **Design (PASS).** No layering violations: `_picker_build_pool` lives
  next to `_poll_classify_all` (sibling helpers in `poll.sh`);
  `_picker_predicate_ready` shells out to `bin/entry-conditions.sh`
  (the existing per-stage check registry from ENG-86). No new script.
  No circular deps: `entry-conditions.sh` does not source `poll.sh`
  (verified — `entry-conditions.sh:30` sources only `common.sh`). The
  picker reads classified output without mutating it (orthogonality
  preserved with the ENG-90 / ENG-85 / ENG-86 layers). Closed-vocabulary
  discipline preserved: `picker_source` and `fifo_ts` are pool-local
  jq annotations, never emitted to Linear, metrics, or comments. No
  new label, no new pipeline event, no new registry entry. Lane
  attribution is unchanged (the picker runs on the harness host, not
  inside an agent sandbox; no `PIPELINE_WRITER` change).

- **Product (PASS).** The plan delivers the Linear issue's stated
  goal: an approved-PR build (`stage:building`, predicate ready) is
  no longer starved by an earlier-stage held or fresh inbox. The
  2026-05-09 ENG-83/ENG-90 incident class (60+ min latency on a
  near-merge ticket) does not recur — AC-PICK-3 and the rewritten
  AC-WAIT-2 pin the regression. The "approve and walk away" operator
  affordance is restored: the next tick after non-bot APPROVED review
  flips the predicate to `proceed` and the wait wins the picker. No
  per-issue isolation regressions (halt, halt-sprawl, ENG-90
  operator_action_required, ENG-86 entry-conditions gate, ENG-85
  wait_recallable classification, `external_signal_budget` — all
  preserved). The CLAUDE.md row gives operators a documented thread
  to pull when the symptom appears in production. The plan's
  vocabulary tracks the issue body's framing ("WIP-first", "recall
  predicate", "cross-pool starvation") so a re-reader recognizes the
  intent.

**Final tally: 5/5 PASS, gate P0 = 0. Proceeding to implementing.**
