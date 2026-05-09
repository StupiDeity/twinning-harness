---
linear: ENG-90
date: 2026-05-09
topic: poll.sh — slot-occupancy contract; every vacate branch declares operator_action_required; halt-sprawl filter and review-PR-pending arm follow from it
---

# Plan — ENG-90 Slot-occupancy contract: holds reserved for active-dispatch work; vacate when next tick is state-check only

Implementation plan for the design at
`docs/brainstorms/2026-05-09-eng-90-slot-occupancy-contract-holds-reserved-for-active-dispatch-work-vacate-when-next-tick-is-state-check-only-design.md`.

## Anti-anchoring check

- **Problem (operator's words).** `bin/poll.sh::_poll_classify_labels`
  was assembled case-by-case as new states were added (ENG-20
  halt-vacates, ENG-50 review gating, ENG-78 retry-immediately,
  ENG-85 wait-vacates), and no single articulated contract describes
  what a held slot represents. Three current branches hold a slot
  when the next tick will not dispatch any agent: review-stage
  hold-during-PR-wait (`bin/poll.sh:285`), halt-no-marker
  (`bin/poll.sh:235`), halt-unknown-marker (`bin/poll.sh:245`). One
  vacate path is miscounted by halt-sprawl
  (`pipeline:skip-until-code-changes` evidence-unchanged at
  `bin/poll.sh:211-213`).
- **Brainstorm addresses it?** Yes. D-001 adds an
  `operator_action_required` flag to every vacate-classifier branch.
  D-002 flips the reviewing-idle arm from `hold` to `vacate`. D-003
  collapses halt-no-marker and halt-unknown-marker into a single
  `vacate, operator_action_required:true` path. D-004 swaps the
  halt-sprawl filter polarity from
  `(.wait_recallable // false) != true` (exclude) to
  `(.operator_action_required // false) == true` (include). D-005
  differentiates the two skip variants in the early-return path.
  D-006 pins every audit-table row with a unit fixture. D-007
  documents the contract in `CLAUDE.md` and at the top of
  `_poll_classify_labels`.
- **Proportional?** Yes. ~+28 net lines in `bin/poll.sh`, ~+250 in
  `bin/poll-slot-test.sh` (15 fixtures), ~+120 in
  `bin/halt-sprawl-test.sh` (5 new fixtures + field migration on
  existing rows), ~+25 in `bin/halt-sprawl-adversarial-test.sh`
  (1 new fixture + literal migration on `$DEFAULT_CLASSIFIED` /
  `big_classified`),
  ~+30 in `CLAUDE.md`. No new files, no new helpers, no new pass,
  no new dependencies, no new exit codes, no new `pipeline-events.json`
  entries, no `dispatch.sh::allowed_tools_for` cases, no
  `learned-rules/` file, no `AGENT_PROMPTS.md` edit.
- **No reframe; no scope creep; no escalation. PROCEED with implementation
  plan.**

## Goal

After the implement stage runs, `bin/poll.sh::_poll_classify_labels`
emits `operator_action_required: bool` on every `slot:"vacate"`
output; `_poll_emit_halt_sprawl_alert` includes vacates by
`operator_action_required == true` rather than excluding by
`wait_recallable != true`; the reviewing arm at line 285 returns
`vacate` (was `hold`); the halted arm at lines 234-235 and 244-245
collapses to a single `vacate, operator_action_required:true`
path; and 15 new fixtures in `bin/poll-slot-test.sh` plus 5 in
`bin/halt-sprawl-test.sh` plus 1 in
`bin/halt-sprawl-adversarial-test.sh` pin every classifier branch
of the audit table. CLAUDE.md gains a `## Slot-occupancy contract
(ENG-90)` subsection adjacent to "Failure-mode quick reference."

Verifiable by:

```
bash bin/poll-slot-test.sh \
  && bash bin/halt-sprawl-test.sh \
  && bash bin/halt-sprawl-adversarial-test.sh \
  && bash bin/verdict-handler-test.sh \
  && bash -n bin/poll.sh \
  && bash bin/secret-probe-lint.sh \
  && bash .githooks/pre-commit
```

exiting 0 with the new fixtures all passing.

Out of scope (explicit per brainstorm §2 non-goals):

- **`pipeline:abandoned` (terminal) handling is unchanged.** Terminal
  items don't carry `operator_action_required` — the field is
  meaningless for never-runs-again issues.
- **`pipeline:scope-approval-needed` and `pipeline:paused` semantics
  are unchanged.** Both fall into
  `vacate, operator_action_required:true` — same observable
  behaviour as today.
- **Marker-shape recognition logic inside `find_fresh_verdict` is
  unchanged.** Only the disposition of its output in
  `_poll_classify_labels` shifts.
- **No new Pass 6 variants.** ENG-85's Pass 6 for `wait_recallable`
  stays as-is. Review-PR-pending uses implicit recall via next-tick
  classify.
- **Slot count `K` and per-stage limits (ENG-81) are out of scope.**
- **`external_signal_budget` / `_handle_wait` semantics are
  unchanged.**
- **Pass 5 `pipeline:halted` exclusion** (open question O-1 in
  brainstorm). Speculative inbox-issue-with-halt-label
  edge-case; not load-bearing for the contract.

## Assumption Inventory

Every modified-file fact below is `path:line`-cited against the
current worktree per the codebase-fact verification mandate.

### Files touched in this plan

- `bin/poll.sh` — net +28 lines
  (`_poll_classify_labels`: skip-evaluate vacate at 211-214 gains
  D-005 distinguisher [+7]; paused/scope-approval at 228-230 gains
  oar=true [+0 char-level]; halted arm at 231-247 collapses
  3-arm case to 2-arm [-3]; wait at 248-256 gains
  oar=false [+1]; reviewing-idle at 285 flips to vacate [+1];
  D-007 contract citation above 207 [+2].
  `_poll_emit_halt_sprawl_alert`: filter at 360 and 388 polarity
  flip [+0 net], comment update reflecting new semantics [+5]).
- `bin/poll-slot-test.sh` — net +250 lines (14 new
  `AC-OAR-*` fixtures + 3 regression fixtures `AC-OAR-REVIEW-STARVATION`,
  `AC-OAR-HALT-NO-MARKER-STARVATION`,
  `AC-OAR-DECIDE-CONTINUE-RECOVERS-HALT-NO-MARKER`; minor field
  additions to existing AC-2 [253-256], AC-3 [277-280], AC-WAIT-1
  [466-470], ENG-50-A/B [832-852]).
- `bin/halt-sprawl-test.sh` — net +120 lines (5 new fixtures:
  `AC-THR-EXCLUDE-WAIT`, `AC-THR-EXCLUDE-SKIP-CODE`,
  `AC-THR-EXCLUDE-REVIEW-VACATE`, `AC-THR-MIXED`,
  `AC-THR-MIXED-OVER`; field migration on existing
  `AC-THR-EQ` [184-189], `AC-THR-GT` [204-211], `AC-THR-ZERO`
  [242], `AC-DEBOUNCE-WITHIN` [257-264], `AC-DEBOUNCE-AFTER`
  [284-291], `AC-MIXED-SLOTS` [315-323]).
- `bin/halt-sprawl-adversarial-test.sh` — net +25 lines
  (field migration on `$DEFAULT_CLASSIFIED` at lines 125-132 and
  on `big_classified` jq generator at line 212; new
  `AC-ADV-MISSING-FLAG` fixture pinning `// false` default
  behaviour).
- `CLAUDE.md` — net +30 lines (new
  `## Slot-occupancy contract (ENG-90)` subsection adjacent to
  `## Failure-mode quick reference` at line 502).
- `docs/plans/2026-05-09-eng-90-…md` — this file. NEW.

### Modified-file facts — current state, signatures, and verification points

#### A-001 — `bin/poll.sh:207-293` `_poll_classify_labels` definition

Verified by direct read at `bin/poll.sh:207-293`. Concrete current
shape:

```bash
# bin/poll.sh:207-293 (verified, current)
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

  local class fresh_wait
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
  elif fresh_wait="$(find_fresh_wait_verdict "$ident" 2>/dev/null)"; [[ -n "$fresh_wait" ]]; then
    local _wait_ts
    _wait_ts="$(jq -r '.created_at' <<<"$fresh_wait")"
    class="$(jq -nc --arg ts "$_wait_ts" \
      '{slot:"vacate", advanceable:false, wait_recallable:true, wait_progress_ts:$ts}')"
  elif [[ "$(_has_label stage:reviewing)" == "true" ]]; then
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

Branches that emit `slot:"vacate"` — the surface the new field
covers:

| File:line | Today's payload | Post-ENG-90 payload |
|---|---|---|
| `bin/poll.sh:212` (skip-evaluate rc=1) | `{slot:"vacate",advanceable:false,labels}` | `{slot:"vacate",advanceable:false,operator_action_required:<derived>,labels}` (D-005) |
| `bin/poll.sh:230` (paused / scope-approval) | `{slot:"vacate",advanceable:false}` | `{slot:"vacate",advanceable:false,operator_action_required:true}` |
| `bin/poll.sh:235` (halt + no marker) | `{slot:"hold",advanceable:false}` ← VIOLATION | `{slot:"vacate",advanceable:false,operator_action_required:true}` (D-003) |
| `bin/poll.sh:243` (halt + pipeline-halt marker) | `{slot:"vacate",advanceable:false}` | `{slot:"vacate",advanceable:false,operator_action_required:true}` (folded into default arm via D-003) |
| `bin/poll.sh:245` (halt + unknown marker) | `{slot:"hold",advanceable:false}` ← VIOLATION | `{slot:"vacate",advanceable:false,operator_action_required:true}` (folded into default arm via D-003) |
| `bin/poll.sh:255-256` (wait verdict) | `{slot:"vacate",advanceable:false,wait_recallable:true,wait_progress_ts:$ts}` | adds `operator_action_required:false` |
| `bin/poll.sh:285` (reviewing-idle) | `{slot:"hold",advanceable:false}` ← VIOLATION | `{slot:"vacate",advanceable:false,operator_action_required:false}` (D-002) |

The catch-all `else` at `bin/poll.sh:289` and the
hold/advanceable=true arms at lines 241, 278, 283, 289 are unchanged
(they emit `slot:"hold"`, where the field is meaningless).

#### A-002 — `bin/poll.sh:340-404` `_poll_emit_halt_sprawl_alert` definition

Verified. Two filter sites at lines 360 and 388:

```bash
# bin/poll.sh:360 (verified, current)
count="$(jq '[.[] | select(.slot == "vacate" and (.wait_recallable // false) != true)] | length' <<<"$classified_json")"

# bin/poll.sh:388
top3="$(jq -rc '[.[] | select(.slot == "vacate" and (.wait_recallable // false) != true) | .identifier] | .[:3] | join(", ")' \
         <<<"$classified_json")"
```

D-004 inverts both: `(.wait_recallable // false) != true` →
`(.operator_action_required // false) == true`. Same default-safe
hatch (`// false`) — items missing the field default to excluded
(strictly safer than over-counting).

#### A-003 — `bin/poll.sh:48-137` `_poll_evaluate_skip` definition

Verified. Two rc=1 paths:

- `bin/poll.sh:88-89` — skip label without state file (label
  present, no evidence to recompute).
- `bin/poll.sh:92-95` — `skip-until-human-acts` label present
  (regardless of state file).
- `bin/poll.sh:136` — `skip-until-code-changes` label, evidence
  unchanged.

The function is unchanged by ENG-90. D-005 is implemented in the
caller (`_poll_classify_labels` at line 211-214) by re-reading the
`labels_json` to distinguish the two skip variants. The label-check
idiom is the same as `bin/poll.sh:52-55, 121-122` (`jq -r --arg n
"<label>" '[.[] | select(. == $n)] | length > 0'`).

#### A-004 — `bin/poll.sh:413-544` `main()` definition (Pass 1-2-2b-3-4-5-6-idle)

Verified. ENG-90 does NOT change pass ordering, sort keys, or
guards. Pass 3 (`bin/poll.sh:441-444`) filters
`select(.slot == "hold")` — review-vacate (D-002) and
halt-no-marker-vacate (D-003) drop out of `held`, freeing slots for
Pass 4 advanceables, Pass 5 inbox, and Pass 6 wait-recall. Pass 6
guard at line 519 (`held_count < max_concurrent`) is unchanged; the
`wait_recallable:true` filter at line 522 is unchanged
(`wait_recallable` and `operator_action_required` are independent
fields per brainstorm §4 D-001).

#### A-005 — `bin/verdict-handler.sh:84-143` `find_fresh_verdict`

Verified. Returns `{marker, source_stage, target_stage, reason,
comment_id}` where `marker ∈
{pipeline-stage-summary, pipeline-rejection, pipeline-halt,
unknown}` (see `bin/verdict-handler.sh:128-141`). Wait verdicts are
intentionally excluded at `bin/verdict-handler.sh:113`. ENG-90 does
NOT modify this helper — only the dispositioning of its output in
the halted arm of `_poll_classify_labels`.

#### A-006 — `bin/verdict-handler.sh:154-191` `find_fresh_wait_verdict`

Verified (post-ENG-85). Returns
`{reason, comment_id, created_at}` for the latest wait verdict in
the post-transition window, or empty string. Unchanged by ENG-90.

#### A-007 — `bin/review-poll.sh:29-53` `review_should_dispatch`

Verified. Returns 0 (dispatch) on:
1. No last-review-state file (bootstrap).
2. PR query failure (`bin/review-poll.sh:42` — fail-open).
3. New commits since last review (`bin/review-poll.sh:49`).

Returns 1 (idle) only on a successful query where the PR HEAD SHA
matches `last-review-state.sha`. D-002 vacates only when this
returns 1 — the predicate is well-defined, no fall-through. The
upstream branch-derivation failure path at `bin/poll.sh:275-278`
remains `hold, advanceable=true` (not changed by ENG-90 — surfaces
the underlying Linear-API outage to the dispatch pipeline rather
than swallowing it).

#### A-008 — `bin/poll-slot-test.sh:155-223` fixture helpers

Verified. Three helpers in scope: `write_label_fixture`
(stage-issue fixtures by label), `write_inbox_fixture` (Todo-state
fixtures), `write_comments_fixture` (per-issue Linear comments
keyed by `body|createdAt`). All D-006 fixtures reuse these without
modification. The post-source override pattern (`STUB_DIR`,
`SCRIPT_DIR`, `_CFS_SCRIPT_DIR`) is unchanged.

#### A-009 — `bin/poll-slot-test.sh:246-289` AC-2 / AC-3 existing halt fixtures

Verified. AC-2 at lines 246-266 uses
`<!-- pipeline: verdict result=halt reason=agent-blocked -->`
which `find_fresh_verdict` projects to `marker=pipeline-halt`;
today asserts `slot=vacate`; D-001 needs `operator_action_required:true`
added to the assertion. AC-3 at lines 268-289 uses
`<!-- pipeline: verdict result=pass stage=planning -->`
which projects to `marker=pipeline-stage-summary`; today asserts
`slot=hold,advanceable=true` (transitively, via "issue_id MUST NOT
be the inbox Todo"); unchanged post-ENG-90.

#### A-010 — `bin/poll-slot-test.sh:449-474` AC-WAIT-1

Verified. Today asserts `slot=vacate, advanceable=false,
wait_recallable=true, wait_progress_ts=<ts>`. D-001 needs
`operator_action_required:false` added (wait is auto-recallable
via Pass 6).

#### A-011 — `bin/poll-slot-test.sh:783-862` ENG-50 review-stage cases

Verified. Three sub-cases:
- ENG-50-A (line 832-842): `REVIEW_SHOULD_DISPATCH=0` →
  `slot=hold, advanceable=true`. Unchanged.
- ENG-50-B (line 844-852): `REVIEW_SHOULD_DISPATCH=1` →
  TODAY asserts `slot=hold, advanceable=false`. D-002 changes the
  assertion to `slot=vacate, advanceable=false,
  operator_action_required=false`.
- ENG-50-C (line 854-862): non-reviewing stage → unchanged.

The `review-poll.sh` and `branch-name.sh` stubs at lines 786-799
work post-ENG-90 without modification.

#### A-012 — `bin/halt-sprawl-test.sh:184-191, 204-211, 242, 257-264, 284-291, 315-323` raw fixtures

Verified. All fixtures construct `[{"identifier":"…","slot":"vacate"}]`
arrays directly without `operator_action_required`. D-006 adds
`,"operator_action_required":true` to the existing rows so the
new D-004 inclusion-by-flag filter still counts them.

#### A-013 — `bin/halt-sprawl-adversarial-test.sh` test harness + existing fixtures

Verified. The file is 232 lines total. Test harness setup spans
lines 1-67 (`_test_assert_temp_path` guard, `install_default_metrics_stub`
helper at lines 52-67). The `$DEFAULT_CLASSIFIED` JSON literal at
lines 125-132 supplies six `[{"identifier":"ENG-N","slot":"vacate"}]`
items (no `operator_action_required` field) and is reused by every
fixture below. The five existing fixtures are:

- `ADV-DEBOUNCE-FUTURE` (line 134) — future debounce stamp;
  expects `metric=1, slack=0`.
- `ADV-DEBOUNCE-EMPTY` (line 151) — empty debounce file;
  expects `metric=1, slack=1`.
- `ADV-DEBOUNCE-CORRUPT` (line 166) — unparseable stamp;
  expects `metric=1, slack=1`.
- `ADV-METRICS-FAIL` (line 185) — failing metrics stub;
  expects `slack=1, helper rc=0`.
- `ADV-LARGE-COUNT` (line 206) — 100-item synthetic array via
  `big_classified="$(jq -nc '[range(0; 100) | {identifier: ("ENG-\(. + 1000)"), slot: "vacate"}]')"`
  at line 212; expects `metric=1, count=100 threshold=5,
  slack=1`.

**Critical post-D-004 migration.** Every existing adversarial
fixture relies on the raw `[{slot:"vacate"}]` shape passing the
halt-sprawl filter. Under D-004's inclusion-by-flag polarity
(`(.operator_action_required // false) == true`), items missing
the field default to excluded → count=0 → no metric → existing
asserts fail. Task 6c MUST migrate both `$DEFAULT_CLASSIFIED` and
the `big_classified` generator to set
`operator_action_required:true` on every item BEFORE adding the
new `AC-ADV-MISSING-FLAG` (which deliberately omits the flag to
pin the default-false hatch).

#### A-014 — `bin/pipeline.sh::decide --action continue`

Verified at `bin/pipeline.sh::decide` and CLAUDE.md
"Failure-mode quick reference" §. Atomic operator-resume contract:
clears `pipeline:halted` label, skip-until-* labels, wait files,
resets per-issue counter, posts a transition waypoint marker. The
recovery-path test (`AC-OAR-DECIDE-CONTINUE-RECOVERS-HALT-NO-MARKER`)
simulates this contract via fixture setup (remove halt label +
write a transition waypoint comment) — does NOT shell out to
`bin/pipeline.sh decide` (which would require a live Linear API).

#### A-015 — `CLAUDE.md` "Failure-mode quick reference" § at line 502

Verified at `CLAUDE.md:502`. The new
`## Slot-occupancy contract (ENG-90)` subsection lands directly
above this section (between line 501 and line 502). The subsection
is self-contained — names the three slot dispositions
(`terminal`, `hold`, `vacate`) and the two-valued
`operator_action_required` field, with the requirement that any
new branch in `_poll_classify_labels` set the flag and add a
fixture. Mirrors the precedent in the existing
"Per-stage dispatch timeouts (ENG-65)" and
"Orchestrator entry-conditions (ENG-86)" sections (single-section
documentation of a contract + the test that pins it).

## File Structure

Modified files (all exist in tree):

- `bin/poll.sh` — modified: `_poll_classify_labels` body (lines 207-293) and `_poll_emit_halt_sprawl_alert` filters (lines 360, 388).
- `bin/poll-slot-test.sh` — modified: append 14 `AC-OAR-*` unit fixtures + 3 regression fixtures; field-update existing AC-2 (line 253-256), AC-3 (277-280), AC-WAIT-1 (466-470), ENG-50-A (832-842), ENG-50-B (844-852).
- `bin/halt-sprawl-test.sh` — modified: append 5 `AC-THR-*` fixtures; field-update existing AC-THR-EQ (184-189), AC-THR-GT (204-211), AC-THR-ZERO (242), AC-DEBOUNCE-WITHIN (257-264), AC-DEBOUNCE-AFTER (284-291), AC-MIXED-SLOTS (315-323).
- `bin/halt-sprawl-adversarial-test.sh` — modified: field-migrate `$DEFAULT_CLASSIFIED` (lines 125-132) and `big_classified` jq generator (line 212) to set `operator_action_required:true` on every item; append `AC-ADV-MISSING-FLAG` fixture.
- `CLAUDE.md` — modified: insert `## Slot-occupancy contract (ENG-90)` subsection above line 502.

New files:

- `docs/plans/2026-05-09-eng-90-slot-occupancy-contract-holds-reserved-for-active-dispatch-work-vacate-when-next-tick-is-state-check-only.md` — this plan; assumed/new.

Files explicitly NOT touched:

- `bin/verdict-handler.sh` — `find_fresh_verdict` and
  `find_fresh_wait_verdict` are unchanged; only the disposition of
  their outputs in `_poll_classify_labels` shifts.
- `bin/review-poll.sh` — `review_should_dispatch`'s contract is
  unchanged; only its caller's classification of the false-return
  case shifts.
- `bin/pipeline.sh` — `decide --action continue` is the documented
  recovery contract for D-003's halt-vacate path; not modified.
- `bin/run-stage.sh::_handle_wait` — build-wait re-dispatch path
  preserved; ENG-90 does not change `external_signal_budget`
  semantics.
- `AGENT_PROMPTS.md` — no agent prompt changes.
- `.pipeline-config/config.json` — no schema additions; the
  existing `orchestrator.alert_on_halted_over` threshold key is
  unchanged.
- `bin/pipeline-events.json` — no new event tokens.
- `bin/dispatch.sh` — no new `allowed_tools_for` cases.
- `learned-rules/harness/*.md` — no new rule files (those are
  retrospective-curated; not for plan output).

## API Contract

no new API surface (this is a Bash orchestration repo with no FE↔BE
API; the change is internal to `bin/poll.sh`).

## Backend Tasks

### Task 1: Add `operator_action_required` to existing vacate paths in `_poll_classify_labels`

- `depends_on: []`
- `touches: bin/poll.sh::_poll_classify_labels (lines 211-214, 228-230, 248-256)`

This task implements D-001 + D-005 for the three vacate paths that
already exist and aren't restructured by D-002 / D-003. Three
distinct edits in one function:

- [ ] **`bin/poll.sh:211-214` (skip-evaluate rc=1).** Replace the
  one-line `jq -nc … '{slot:"vacate",advanceable:false,labels:$l}'`
  with a label-aware variant that sets oar=true when
  `pipeline:skip-until-human-acts` is present and oar=false
  otherwise (skip-until-code-changes evidence-unchanged).

  ```bash
  if ! refreshed_labels="$(_poll_evaluate_skip "$ident" "$labels_json")"; then
    # ENG-90 D-005: differentiate the two skip kinds.
    # skip-until-human-acts is operator-action-required (operator
    # removes label). skip-until-code-changes with evidence
    # unchanged is auto-recallable (next-tick _poll_evaluate_skip
    # re-checks pipeline_content_hash + branch SHA; clears label
    # mid-tick on change, line 109-134).
    local oar="false"
    if [[ "$(jq -r --arg n "pipeline:skip-until-human-acts" \
            '[.[] | select(. == $n)] | length > 0' <<<"$labels_json")" == "true" ]]; then
      oar="true"
    fi
    jq -nc --argjson l "$labels_json" --argjson oar "$oar" \
      '{slot:"vacate",advanceable:false,operator_action_required:$oar,labels:$l}'
    return 0
  fi
  ```

- [ ] **`bin/poll.sh:228-230` (paused / scope-approval).** Add
  `,operator_action_required:true` to the existing payload.

  ```bash
  elif [[ "$(_has_label pipeline:paused)" == "true" ]] \
    || [[ "$(_has_label pipeline:scope-approval-needed)" == "true" ]]; then
    class='{"slot":"vacate","advanceable":false,"operator_action_required":true}'
  ```

- [ ] **`bin/poll.sh:248-256` (wait verdict).** Add
  `,operator_action_required:false` to the existing jq-built
  payload. Wait is Pass-6-recallable; orchestrator-side
  `_handle_wait` re-runs the predicate.

  ```bash
  elif fresh_wait="$(find_fresh_wait_verdict "$ident" 2>/dev/null)"; [[ -n "$fresh_wait" ]]; then
    local _wait_ts
    _wait_ts="$(jq -r '.created_at' <<<"$fresh_wait")"
    class="$(jq -nc --arg ts "$_wait_ts" \
      '{slot:"vacate", advanceable:false, wait_recallable:true, wait_progress_ts:$ts, operator_action_required:false}')"
  ```

The task does NOT touch the halted arm (D-003 owns that), the
reviewing arm (D-002 owns that), or the halt-sprawl filter (Task 4
owns that). Verify with `bash -n bin/poll.sh` after each edit.

### Task 2: Reviewing arm — `review_should_dispatch=false` → vacate (D-002)

- `depends_on: []`
- `touches: bin/poll.sh::_poll_classify_labels (line 285)`

- [ ] **`bin/poll.sh:284-286` (reviewing-idle bifurcation).** Change
  the `else` arm of `review_should_dispatch` from
  `'{"slot":"hold","advanceable":false}'` to
  `'{"slot":"vacate","advanceable":false,"operator_action_required":false}'`.
  Add a brief comment citing ENG-90 D-002 and the recall mechanism
  (next-tick implicit classify):

  ```bash
  if review_should_dispatch "$ident" "$_rp_branch"; then
    class='{"slot":"hold","advanceable":true}'
  else
    # ENG-90 D-002: PR not mergeable / checks pending. Agent dispatch
    # will not run; the next tick re-evaluates review_should_dispatch
    # (cheap orchestrator-side state check). Vacate the slot so
    # sibling work can dispatch.
    class='{"slot":"vacate","advanceable":false,"operator_action_required":false}'
  fi
  ```

The dispatch=true arm at line 283 (`hold, advanceable=true`) and
the branch-derivation-failed arm at line 278
(`hold, advanceable=true`) are unchanged. Verify with
`bash -n bin/poll.sh`.

### Task 3: Halted arm — collapse no-marker / unknown / pipeline-halt to one vacate path (D-003)

- `depends_on: []`
- `touches: bin/poll.sh::_poll_classify_labels (lines 231-247)`

- [ ] **`bin/poll.sh:231-247` (halted arm).** Restructure from the
  current 3-arm `case` (`pipeline-stage-summary|pipeline-rejection`
  → hold-advanceable; `pipeline-halt` → vacate; `*` → hold-NOT-advanceable)
  with an `if -z` pre-check (no-marker → hold-NOT-advanceable) to
  a 2-arm `case` plus a no-marker fall-through to vacate:

  ```bash
  elif [[ "$(_has_label pipeline:halted)" == "true" ]]; then
    local fresh
    fresh="$(find_fresh_verdict "$ident" 2>/dev/null || printf '')"
    if [[ -n "$fresh" ]]; then
      local marker
      marker="$(jq -r '.marker // ""' <<<"$fresh")"
      case "$marker" in
        pipeline-stage-summary|pipeline-rejection)
          # Verdict-handler-led transition is upcoming in Pass 4;
          # halt label is consumed by apply_transition. Slot remains
          # held (active dispatch work).
          class='{"slot":"hold","advanceable":true}' ;;
        *)
          # ENG-90 D-003: pipeline-halt OR unknown marker. Halt
          # label gates dispatch — no agent compute will run
          # regardless of marker shape. Operator must run
          # `bin/pipeline.sh decide --action continue`.
          class='{"slot":"vacate","advanceable":false,"operator_action_required":true}' ;;
      esac
    else
      # ENG-90 D-003: no fresh marker (silent agent crash,
      # externally-applied label, or marker race with this tick).
      # Halt label still gates dispatch — no agent compute will
      # run. Operator must run `bin/pipeline.sh decide --action
      # continue`.
      class='{"slot":"vacate","advanceable":false,"operator_action_required":true}' ;;
    fi
  ```

The reordering — `if -n` (marker present) followed by `else`
(no marker) — preserves the same shape as the wait branch at
lines 248-256 and is a strictly more readable inversion of the
current `if -z` (no marker) … `else` (marker present). Verify
with `bash -n bin/poll.sh`.

### Task 4: Halt-sprawl filter polarity flip (D-004)

- `depends_on: [1, 2, 3]`
- `touches: bin/poll.sh::_poll_emit_halt_sprawl_alert (lines 354-360, 388)`

This task depends on Tasks 1-3 because the new include-by-flag
filter only counts items where every classifier branch sets
`operator_action_required` correctly. If a branch is missed, items
default to excluded silently — Task 6's
`AC-ADV-MISSING-FLAG` adversarial fixture pins this default and
catches drift, but the production effect is "alert miscount" rather
than "alert wrong direction." Tasks 1-3 ensure no current branch
defaults silently.

- [ ] **`bin/poll.sh:354-360`.** Replace the comment block plus
  count-filter line. New comment cites ENG-90 D-004 (with the
  ENG-85 wait-exclusion rationale preserved as the precedent):

  ```bash
  # ENG-90 D-004: count vacates where operator action is required
  # to advance. Excludes orchestrator-recallable vacates
  # (build-wait — ENG-85; review-PR-pending — D-002;
  # skip-until-code-changes evidence-unchanged — D-005), which are
  # not halts. Default-false hatch: items missing the flag default
  # to excluded (strictly safer than over-counting). The
  # `AC-ADV-MISSING-FLAG` adversarial test pins this default.
  local count
  count="$(jq '[.[] | select(.slot == "vacate" and (.operator_action_required // false) == true)] | length' <<<"$classified_json")"
  ```

- [ ] **`bin/poll.sh:388`.** Mirror the filter on the top-3 selector
  (same polarity flip):

  ```bash
  top3="$(jq -rc '[.[] | select(.slot == "vacate" and (.operator_action_required // false) == true) | .identifier] | .[:3] | join(", ")' \
           <<<"$classified_json")"
  ```

The relationship between count and Slack body is preserved — same
filter, same exclusions, same items. Verify with
`bash -n bin/poll.sh`.

### Task 5: Document the contract — CLAUDE.md subsection + top-of-function citation (D-007)

- `depends_on: []`
- `touches: CLAUDE.md (insert above line 502), bin/poll.sh (insert above line 207)`

- [ ] **`CLAUDE.md` (insert above line 502 — directly above
  `## Failure-mode quick reference`).** Add a new section:

  ```markdown
  ## Slot-occupancy contract (ENG-90)

  `bin/poll.sh::_poll_classify_labels` is the slot-classification
  surface. Every output declares one of:

  - **`slot:"terminal"`** — `pipeline:abandoned`. Never recalled.
  - **`slot:"hold", advanceable:true`** — Active development. Pass 4
    will dispatch a `claude -p` agent on this tick.
  - **`slot:"hold", advanceable:false`** — Reserved (today: never
    emitted; left in place for transitional/legacy paths). If a
    branch needs to express "do not dispatch but keep the slot,"
    reach for `vacate` instead.
  - **`slot:"vacate", operator_action_required:true`** — Agent-idle,
    recall path requires operator action (label removal,
    `bin/pipeline.sh decide --action continue`, PR review).
    Counted by `_poll_emit_halt_sprawl_alert`'s threshold.
  - **`slot:"vacate", operator_action_required:false`** — Agent-idle,
    recall is automatic (next-tick orchestrator-side state check:
    `review_should_dispatch`, `pipeline_content_hash`,
    `_handle_wait`'s budget). Excluded from halt-sprawl.

  Adding a new branch to `_poll_classify_labels` MUST set
  `operator_action_required` for every `slot:"vacate"` output AND
  add a fixture under `bin/poll-slot-test.sh::AC-OAR-*`. The
  adversarial halt-sprawl test
  (`bin/halt-sprawl-adversarial-test.sh::AC-ADV-MISSING-FLAG`)
  catches silent omissions for the alert path; the poll-slot
  per-row fixtures catch silent omissions for the classifier path.
  ```

- [ ] **`bin/poll.sh` (insert above line 207 — directly above
  `_poll_classify_labels() {`).** Add a one-line citation. The
  existing comment block at lines 169-205 documents the
  classification rules; the new citation lands between line 206 and
  line 207 (after the closing line of the existing block):

  ```bash
  # ENG-90: every `slot:"vacate"` output declares
  # operator_action_required. See CLAUDE.md "Slot-occupancy
  # contract (ENG-90)" before adding new branches.
  _poll_classify_labels() {
  ```

Verify with `bash -n bin/poll.sh`.

### Task 6: Test fixture coverage — `AC-OAR-*`, `AC-THR-*`, `AC-ADV-MISSING-FLAG` (D-006)

- `depends_on: [1, 2, 3, 4, 5]`
- `touches: bin/poll-slot-test.sh, bin/halt-sprawl-test.sh, bin/halt-sprawl-adversarial-test.sh`

This task depends on Tasks 1-5 because the new fixtures assert
post-change classifier outputs and post-change halt-sprawl
inclusion logic. The implementing agent should write source +
tests in the same commit (the harness's pre-commit hook at
`.githooks/pre-commit` runs every `bin/*-test.sh`).

#### 6a — `bin/poll-slot-test.sh` per-branch unit fixtures (`AC-OAR-*`)

- [ ] **Append 14 unit fixtures** at the end of the existing
  test block (after the last existing `pass_at`/`fail_at`).
  Each fixture follows the established
  `reset_fixtures` → `write_label_fixture` /
  `write_inbox_fixture` / `write_comments_fixture` →
  `_poll_classify_labels` → `jq -r '…'` extract → if/else
  pass_at/fail_at pattern (mirrors `AC-WAIT-1` at lines 449-474).
  Field assertions use `jq -r '… | tostring'` for booleans (per
  `AC-WAIT-1`'s line 465-466 idiom — `// ""` would silently coerce
  `false` to `""`).

  | Fixture name | Setup | Expected output |
  |---|---|---|
  | `AC-OAR-ABANDONED` | labels=`["pipeline:abandoned"]` | `slot=terminal, advanceable=false`; `operator_action_required` field absent (jq-extract returns `null`) |
  | `AC-OAR-PAUSED` | labels=`["pipeline:paused"]` | `slot=vacate, advanceable=false, operator_action_required=true` |
  | `AC-OAR-SCOPE` | labels=`["pipeline:scope-approval-needed"]` | same as PAUSED |
  | `AC-OAR-HALT-PASS` | labels=`["stage:planning","pipeline:halted"]`, comments contain `<!-- pipeline: verdict result=pass stage=planning -->\|2026-05-09T08:00:00Z` | `slot=hold, advanceable=true`; `operator_action_required` absent |
  | `AC-OAR-HALT-FAIL` | labels=`["stage:implementing","pipeline:halted"]`, comments contain `<!-- pipeline: verdict result=fail target=implementing -->\|2026-05-09T08:00:00Z` | same as HALT-PASS |
  | `AC-OAR-HALT-HALT` | labels=`["stage:implementing","pipeline:halted"]`, comments contain `<!-- pipeline: verdict result=halt reason=agent-blocked -->\|2026-05-09T08:00:00Z` | `slot=vacate, advanceable=false, operator_action_required=true` |
  | `AC-OAR-HALT-NO-MARKER` | labels=`["stage:planning","pipeline:halted"]`, comments empty (write empty `comments-ENG-…json` or omit fixture) | `slot=vacate, advanceable=false, operator_action_required=true` (D-003 — was hold today) |
  | `AC-OAR-HALT-UNKNOWN-MARKER` | labels=`["stage:planning","pipeline:halted"]`, comments contain `<!-- pipeline: transition from=planning to=implementing -->\|2026-05-09T08:00:00Z` (transition is parsed but `find_fresh_verdict` does not emit it as a verdict; sub-case is "fresh empty" via no-actionable-verdict → falls into D-003's no-marker arm) | `slot=vacate, advanceable=false, operator_action_required=true` (D-003) |
  | `AC-OAR-WAIT` | labels=`["stage:building"]`, comments per existing AC-WAIT-1 | `slot=vacate, advanceable=false, wait_recallable=true, wait_progress_ts=2026-04-28T08:17:00Z, operator_action_required=false` |
  | `AC-OAR-REVIEW-DISPATCH` | labels=`["stage:reviewing"]`, env `REVIEW_SHOULD_DISPATCH=0` | `slot=hold, advanceable=true`; `operator_action_required` absent |
  | `AC-OAR-REVIEW-IDLE` | labels=`["stage:reviewing"]`, env `REVIEW_SHOULD_DISPATCH=1` | `slot=vacate, advanceable=false, operator_action_required=false` (D-002 — was hold today) |
  | `AC-OAR-SKIP-HUMAN` | labels=`["stage:planning","pipeline:skip-until-human-acts"]`, write a state file at `$(issue_dir <ident>)/issue-state.json` so `_poll_evaluate_skip` reaches the rc=1 path at line 92-95 | `slot=vacate, advanceable=false, operator_action_required=true` (D-005) |
  | `AC-OAR-SKIP-CODE-UNCHANGED` | labels=`["stage:planning","pipeline:skip-until-code-changes"]`, write state file with `evidence.pipeline_content_hash` matching `compute_pipeline_content_hash` and `evidence.branch_head_sha` matching the `git ls-remote` output (or stub `git ls-remote` to return the file's stored sha) | `slot=vacate, advanceable=false, operator_action_required=false` (D-005) |
  | `AC-OAR-DEFAULT` | labels=`["stage:implementing"]` (no other labels, no fresh markers) | `slot=hold, advanceable=true`; `operator_action_required` absent |

  The `AC-OAR-HALT-NO-MARKER` fixture writes an empty
  `comments-ENG-OAR-HALT-NO-MARKER.json` (linear.sh stub returns
  `[]` per `bin/poll-slot-test.sh:817`) so `find_fresh_verdict`
  returns empty and the new D-003 no-marker fall-through fires.

  The `AC-OAR-HALT-UNKNOWN-MARKER` fixture intentionally posts
  ONLY a `<!-- pipeline: transition … -->` marker (an event of
  kind `transition`, not `verdict`). `find_fresh_verdict`'s loop
  at `bin/verdict-handler.sh:107-117` skips
  non-verdict events and returns empty — the same fall-through
  the no-marker case takes. The fixture name is preserved for
  traceability against the issue body's audit table; the
  observable behaviour (vacate, oar=true) is identical to
  `AC-OAR-HALT-NO-MARKER`. (This is a structural reality:
  `find_fresh_verdict` never returns `marker:"unknown"` in
  production — `parse_pipeline_marker` only emits known event
  kinds; the `marker:"unknown"` jq-projection arm at
  `bin/verdict-handler.sh:139-141` is reached only for verdicts
  with unrecognised result tokens, which the registry rejects.
  The pre-ENG-90 `case *)` arm at `bin/poll.sh:244-245` was a
  belt-and-braces guard against future drift.)

  The `AC-OAR-SKIP-CODE-UNCHANGED` fixture requires stubbing
  `git ls-remote` so `_poll_evaluate_skip` at line 104 returns a
  deterministic SHA matching the state file's stored sha. Two
  options: (a) reuse the existing `AC-7` test pattern at
  `bin/poll-slot-test.sh` ~line 410-447 (which exercises the
  evidence-changed path via `compute_pipeline_content_hash` +
  state-file matching); (b) stub `git` directly via
  `STUB_DIR/git`. Implementing agent picks the cleaner option
  for this codebase; option (a) reuses existing infrastructure.

- [ ] **Append 3 regression fixtures** (mirror existing `AC-WAIT-2`
  / `AC-WAIT-3` style — invoke `main()` end-to-end against a
  multi-issue fixture and assert which issue dispatched):

  | Fixture name | Setup | Expected behaviour |
  |---|---|---|
  | `AC-OAR-REVIEW-STARVATION` | ENG-A at stage:reviewing + `REVIEW_SHOULD_DISPATCH=1`; ENG-B at stage:implementing; cap=2 | `main()` dispatches ENG-B (review-vacate frees the slot per D-002). Asserts `issue_id=ENG-B, stage=implementing` |
  | `AC-OAR-HALT-NO-MARKER-STARVATION` | ENG-A at stage:planning + `pipeline:halted` + empty comments; ENG-B Todo in inbox; cap=2 | `main()` dispatches ENG-B with `entry_action=apply-stage-label` (halt-no-marker frees the slot per D-003 — was held pre-fix). Asserts `issue_id=ENG-B, entry_action=apply-stage-label` |
  | `AC-OAR-DECIDE-CONTINUE-RECOVERS-HALT-NO-MARKER` | First tick: ENG-A at stage:planning + `pipeline:halted` + empty comments → vacate. Then simulate `bin/pipeline.sh decide --action continue` by clearing the halt label from the fixture and writing a `<!-- pipeline: transition from=planning to=planning reason=operator-resume -->` waypoint. Second tick: classify sees no halt label + a transition waypoint → catch-all `else` arm → hold/advanceable=true. | `main()` dispatches ENG-A on the second tick. Asserts `issue_id=ENG-A, stage=planning, entry_action=run` |

- [ ] **Field-update existing fixtures** so they assert the new
  field where applicable:

  - `AC-2` (lines 246-266): no assertion change required (asserts
    inbox pickup; the post-classify slot is implicit).
  - `AC-3` (lines 268-289): no assertion change required (asserts
    inbox NOT picked).
  - `AC-WAIT-1` (lines 449-474): add
    `oar="$(jq -r '.operator_action_required | tostring' <<<"$out")"`
    extract and `&& "$oar" == "false"` to the if-condition.
    Update the failure message to include `oar=$oar`.
  - `ENG-50-A` (lines 832-842): no assertion change (asserts
    `slot=hold, adv=true`).
  - `ENG-50-B` (lines 844-852): change asserted shape from
    `slot=hold, adv=false` to `slot=vacate, adv=false, oar=false`
    (D-002). Failure message updated to reflect new expected
    shape.

#### 6b — `bin/halt-sprawl-test.sh` inclusion-by-flag fixtures

- [ ] **Field-migrate existing fixtures** at lines 184-191,
  204-211, 242, 257-264, 284-291, 315-323. For each
  `{"identifier":"…","slot":"vacate"}` row in the `classified`
  JSON literal, add `,"operator_action_required":true`.
  Mechanical change; no assertion changes.

- [ ] **Append 5 new fixtures** to the end of the test block.
  Each follows the existing `reset_fixtures; reset_state` →
  classified literal → `_poll_emit_halt_sprawl_alert` →
  `count_metric_events` / `slack_call_count` assertion pattern:

  | Fixture name | Setup | Expected |
  |---|---|---|
  | `AC-THR-EXCLUDE-WAIT` | 6 vacate items, all with `wait_recallable:true, operator_action_required:false`; threshold=5 | `count_metric_events alert == 0`, `slack_call_count == 0` (existing ENG-85 invariant; pinned post-rename) |
  | `AC-THR-EXCLUDE-SKIP-CODE` | 6 vacate items, all with `operator_action_required:false` (modeling skip-until-code-changes evidence-unchanged); threshold=5 | same: no metric, no Slack (D-004 — was a miscount pre-fix) |
  | `AC-THR-EXCLUDE-REVIEW-VACATE` | 6 vacate items, all with `operator_action_required:false` (modeling review-PR-pending); threshold=5 | same: no metric, no Slack (D-004 — would be a new miscount post-D-002 without D-004) |
  | `AC-THR-MIXED` | 3 items `operator_action_required:true` + 3 items `operator_action_required:false`; threshold=5 | no metric (count=3 ≤ 5), no Slack |
  | `AC-THR-MIXED-OVER` | 6 items `operator_action_required:true` (identifiers ENG-M-1…ENG-M-6) + 3 items `operator_action_required:false` (identifiers ENG-X-1…ENG-X-3); threshold=5 | metric notes `count=6 threshold=5`; Slack body contains `ENG-M-1`, `ENG-M-2`, `ENG-M-3`; Slack body does NOT contain any `ENG-X-*`; suffix `, …` present (count=6>3) |

#### 6c — `bin/halt-sprawl-adversarial-test.sh` field migration + default-flag pin

- [ ] **Migrate `$DEFAULT_CLASSIFIED`** at `bin/halt-sprawl-adversarial-test.sh:125-132`
  to add `,"operator_action_required":true` to every entry. Without
  this migration, every existing `ADV-*` fixture (which reuses
  `$DEFAULT_CLASSIFIED`) fails post-D-004 because items default to
  excluded by the inclusion-by-flag filter:

  ```bash
  DEFAULT_CLASSIFIED='[
    {"identifier":"ENG-901","slot":"vacate","operator_action_required":true},
    {"identifier":"ENG-902","slot":"vacate","operator_action_required":true},
    {"identifier":"ENG-903","slot":"vacate","operator_action_required":true},
    {"identifier":"ENG-904","slot":"vacate","operator_action_required":true},
    {"identifier":"ENG-905","slot":"vacate","operator_action_required":true},
    {"identifier":"ENG-906","slot":"vacate","operator_action_required":true}
  ]'
  ```

- [ ] **Migrate `big_classified`** at line 212 to add
  `operator_action_required: true` to the synthesized objects:

  ```bash
  big_classified="$(jq -nc '[range(0; 100) | {identifier: ("ENG-\(. + 1000)"), slot: "vacate", operator_action_required: true}]')"
  ```

- [ ] **Append `AC-ADV-MISSING-FLAG`** to the end of the
  adversarial test block. Pins the `// false` default behaviour:
  a future classifier branch that forgets to set
  `operator_action_required` is silently excluded — strictly
  safer than silently included.

  ```bash
  # ─── AC-ADV-MISSING-FLAG (ENG-90 D-004): vacate items WITHOUT
  #     operator_action_required default to excluded.
  reset_fixtures; reset_state
  classified='[
    {"identifier":"ENG-MISS-1","slot":"vacate"},
    {"identifier":"ENG-MISS-2","slot":"vacate"},
    {"identifier":"ENG-MISS-3","slot":"vacate"},
    {"identifier":"ENG-MISS-4","slot":"vacate"},
    {"identifier":"ENG-MISS-5","slot":"vacate"},
    {"identifier":"ENG-MISS-6","slot":"vacate"}
  ]'
  _poll_emit_halt_sprawl_alert "$classified" 2>/dev/null || true
  if [[ "$(count_metric_events alert)" == "0" ]] \
     && [[ "$(slack_call_count)" == "0" ]]; then
    pass_at "AC-ADV-MISSING-FLAG missing oar field → excluded (default-false)"
  else
    fail_at "AC-ADV-MISSING-FLAG missing oar field → excluded (default-false)" \
      "metric=$(count_metric_events alert) slack=$(slack_call_count)"
  fi
  ```

After all fixtures are appended:

- [ ] Run `bash bin/poll-slot-test.sh` — every existing case PASS
  + 17 new `AC-OAR-*` cases PASS.
- [ ] Run `bash bin/halt-sprawl-test.sh` — every existing case
  PASS (after field migration) + 5 new `AC-THR-*` cases PASS.
- [ ] Run `bash bin/halt-sprawl-adversarial-test.sh` — every
  existing case PASS + `AC-ADV-MISSING-FLAG` PASS.
- [ ] Run `bash .githooks/pre-commit` — all `bin/*-test.sh` PASS.

## Frontend Tasks

No frontend work — this is a Bash orchestration repo with no UI
surface. Skip.

## Failure Mode → Test Map

Every Edge Case from the brainstorm §8 is bound to a concrete test:

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
|---|---|---|---|---|
| Halt + stage-summary marker (race against transition) | label=`pipeline:halted`, fresh `<!-- pipeline: verdict result=pass stage=planning -->` | `slot=hold, advanceable=true` (Pass 4 → verdict_handler transition) | unit | `bin/poll-slot-test.sh::AC-OAR-HALT-PASS` |
| Halt + rejection marker | label=`pipeline:halted`, fresh `<!-- pipeline: verdict result=fail target=implementing -->` | `slot=hold, advanceable=true` (Pass 4 → verdict_handler) | unit | `bin/poll-slot-test.sh::AC-OAR-HALT-FAIL` |
| Halt + pipeline-halt marker | label=`pipeline:halted`, fresh `<!-- pipeline: verdict result=halt reason=agent-blocked -->` | `slot=vacate, oar=true` (D-003 — case folds into default arm) | unit | `bin/poll-slot-test.sh::AC-OAR-HALT-HALT` |
| Halt + no fresh marker (silent crash, externally-applied label, race) | label=`pipeline:halted`, comments empty | `slot=vacate, oar=true` (D-003 — was hold pre-fix) | unit | `bin/poll-slot-test.sh::AC-OAR-HALT-NO-MARKER` |
| Halt + only a transition marker (no actionable verdict) | label=`pipeline:halted`, comments contain only a `<!-- pipeline: transition … -->` marker | `slot=vacate, oar=true` (D-003 — fall-through) | unit | `bin/poll-slot-test.sh::AC-OAR-HALT-UNKNOWN-MARKER` |
| Reviewing + PR not yet reviewable (D-002 path) | label=`stage:reviewing`, `REVIEW_SHOULD_DISPATCH=1` | `slot=vacate, oar=false` (D-002 — was hold pre-fix) | unit | `bin/poll-slot-test.sh::AC-OAR-REVIEW-IDLE` |
| Reviewing + PR mergeable | label=`stage:reviewing`, `REVIEW_SHOULD_DISPATCH=0` | `slot=hold, advanceable=true` (unchanged — Pass 4 dispatches review agent) | unit | `bin/poll-slot-test.sh::AC-OAR-REVIEW-DISPATCH` |
| Reviewing-stage with halt label (precedence) | labels=`stage:reviewing` + `pipeline:halted`; covered transitively by halted-arm cases firing first | halted arm fires; reviewing branch unreachable | (covered by halted-arm cases) | `AC-OAR-HALT-*` |
| Reviewing-stage with paused label (precedence) | labels=`stage:reviewing` + `pipeline:paused`; covered transitively by paused-arm firing first | paused arm fires; reviewing branch unreachable | (covered by paused fixture) | `AC-OAR-PAUSED` |
| Skip-until-code-changes evidence unchanged | label=`pipeline:skip-until-code-changes`, state file's hash matches `compute_pipeline_content_hash`, branch sha matches | `slot=vacate, oar=false` (D-005) | unit | `bin/poll-slot-test.sh::AC-OAR-SKIP-CODE-UNCHANGED` |
| Skip-until-human-acts | label=`pipeline:skip-until-human-acts` + state file present | `slot=vacate, oar=true` (D-005) | unit | `bin/poll-slot-test.sh::AC-OAR-SKIP-HUMAN` |
| Wait verdict (build-stage awaiting approval) | label=`stage:building`, fresh `<!-- pipeline: verdict result=wait reason=awaiting-approval -->` | `slot=vacate, oar=false, wait_recallable=true` | unit | `bin/poll-slot-test.sh::AC-OAR-WAIT` |
| Default catch-all (mid-stage, no blockers) | label=`stage:implementing`, no other labels, no fresh markers | `slot=hold, advanceable=true` | unit | `bin/poll-slot-test.sh::AC-OAR-DEFAULT` |
| Abandoned (terminal) | label=`pipeline:abandoned` | `slot=terminal`, oar absent | unit | `bin/poll-slot-test.sh::AC-OAR-ABANDONED` |
| Paused | label=`pipeline:paused` | `slot=vacate, oar=true` | unit | `bin/poll-slot-test.sh::AC-OAR-PAUSED` |
| Scope-approval-needed | label=`pipeline:scope-approval-needed` | `slot=vacate, oar=true` | unit | `bin/poll-slot-test.sh::AC-OAR-SCOPE` |
| Review-stage starvation regression (Linear issue body's example) | ENG-A at stage:reviewing+idle; ENG-B at stage:implementing; cap=2 | `main()` dispatches ENG-B (slot freed by D-002) | integration | `bin/poll-slot-test.sh::AC-OAR-REVIEW-STARVATION` |
| Halt-no-marker starvation regression | ENG-A at stage:planning+halt+no-marker; ENG-B Todo in inbox; cap=2 | `main()` dispatches ENG-B (slot freed by D-003) | integration | `bin/poll-slot-test.sh::AC-OAR-HALT-NO-MARKER-STARVATION` |
| Operator recovery via `decide --action continue` after halt-no-marker vacate | ENG-A at stage:planning+halt+no-marker → vacate; operator removes halt + posts transition waypoint; classify retries | next tick: `main()` dispatches ENG-A | integration | `bin/poll-slot-test.sh::AC-OAR-DECIDE-CONTINUE-RECOVERS-HALT-NO-MARKER` |
| Halt-sprawl excludes wait-recallable items (existing ENG-85 invariant; preserved post-rename) | 6 vacate items with `wait_recallable=true, oar=false`; threshold=5 | no metric, no Slack | unit | `bin/halt-sprawl-test.sh::AC-THR-EXCLUDE-WAIT` |
| Halt-sprawl excludes skip-until-code-changes (D-004 — was miscount pre-fix) | 6 vacate items with `oar=false`; threshold=5 | no metric, no Slack | unit | `bin/halt-sprawl-test.sh::AC-THR-EXCLUDE-SKIP-CODE` |
| Halt-sprawl excludes review-PR-pending (D-004 — would be miscount without filter flip) | 6 vacate items with `oar=false`; threshold=5 | no metric, no Slack | unit | `bin/halt-sprawl-test.sh::AC-THR-EXCLUDE-REVIEW-VACATE` |
| Halt-sprawl mixed below threshold | 3 oar=true + 3 oar=false; threshold=5 | no metric (count=3) | unit | `bin/halt-sprawl-test.sh::AC-THR-MIXED` |
| Halt-sprawl mixed over threshold; top-3 selector mirrors filter | 6 oar=true (`ENG-M-*`) + 3 oar=false (`ENG-X-*`); threshold=5 | metric notes `count=6 threshold=5`; Slack body contains `ENG-M-1`, `ENG-M-2`, `ENG-M-3`; does NOT contain any `ENG-X-*` | unit | `bin/halt-sprawl-test.sh::AC-THR-MIXED-OVER` |
| Halt-sprawl default-false hatch (defense-in-depth: future branch forgets to set oar) | 6 vacate items WITHOUT oar field; threshold=5 | no metric, no Slack (silent excluded — strictly safer than over-counting) | adversarial | `bin/halt-sprawl-adversarial-test.sh::AC-ADV-MISSING-FLAG` |
| Linear-API outage in `find_fresh_verdict` during halted classification | label=`pipeline:halted`, `find_fresh_verdict` returns empty | `slot=vacate, oar=true` (D-003 — strictly better than pre-fix hold) | (covered transitively) | `AC-OAR-HALT-NO-MARKER` |
| Linear-API outage in `_poll_evaluate_skip` (`git ls-remote` fails) | covered by ENG-78's existing `AC-7` fixture; ENG-90 doesn't change `_poll_evaluate_skip` semantics | unchanged | (no new test) | (existing `AC-7`) |
| Branch-name derivation failure in reviewing arm | covered by ENG-50's existing `bin/poll.sh:275-278` fail-open path; ENG-90 doesn't change this arm | `slot=hold, advanceable=true` (unchanged — fail-open preserves dispatch) | (no new test) | (existing ENG-50 path; no fixture today; out of scope per brainstorm §7) |

The brainstorm §8 also enumerates two `max_concurrent_features`
edge cases (`=0`, `=1`); these are state-of-the-system invariants
preserved unchanged by ENG-90 (the cap guards on Pass 5 and Pass 6
remain `held_count < max_concurrent`). No new fixtures — covered by
existing `AC-1`, `AC-WAIT-2`, `AC-WAIT-3`, `AC-WAIT-4` fixtures.

## Test Strategy

### Unit (poll-slot-test.sh)

Per-classifier-branch unit fixtures pin every row of the audit
table from the issue body. Each fixture instantiates a single
issue's labels + comments, calls `_poll_classify_labels` directly
(no `main()` invocation, no Pass 4 dispatch), and asserts the
output JSON's `slot`, `advanceable`, and
`operator_action_required` (or its absence). 14 fixtures cover the
13 audit-table rows plus the catch-all `AC-OAR-DEFAULT`. The
existing AC-WAIT-1 / ENG-50-A/B fixtures gain field assertions to
match the new contract.

### Integration (poll-slot-test.sh — main()-level)

Three regression fixtures exercise the end-to-end `main()` path
across multi-issue fleets:

- `AC-OAR-REVIEW-STARVATION` — pinning the literal review-starvation
  scenario from the Linear issue body (ENG-85-shape; the new
  D-002 fix).
- `AC-OAR-HALT-NO-MARKER-STARVATION` — pinning the halt-no-marker
  starvation scenario (the new D-003 fix).
- `AC-OAR-DECIDE-CONTINUE-RECOVERS-HALT-NO-MARKER` — pinning the
  operator-recovery contract (the documented exit ramp via
  `bin/pipeline.sh decide --action continue` recovers a
  halt-no-marker-vacated issue on the next tick).

These three exercise the actual control flow (Pass 1 → Pass 2 →
Pass 3 → Pass 4 / 5 / 6) under fixture-stubbed `linear.sh`,
`branch-name.sh`, `review-poll.sh`. They DO NOT shell out to a
live Linear API (`PIPELINE_DRY_RUN=1` per the test harness env
setup at `bin/poll-slot-test.sh:1-50`).

### Unit (halt-sprawl-test.sh)

Five new fixtures pin the inclusion-by-flag filter:

- `AC-THR-EXCLUDE-WAIT`, `AC-THR-EXCLUDE-SKIP-CODE`,
  `AC-THR-EXCLUDE-REVIEW-VACATE` — three exclusion modes,
  matching the brainstorm §1's audit table's
  "Counts toward halt-sprawl?" column (no for all three).
- `AC-THR-MIXED`, `AC-THR-MIXED-OVER` — pin that the count and
  the top-3 Slack body use the SAME inclusion filter (no
  `oar=false` items leak into the Slack body even when alert
  fires).

Existing fixtures gain field migration but no assertion changes —
they continue to pin "pure operator-required halts trigger the
alert" with the new field present.

### Adversarial (halt-sprawl-adversarial-test.sh)

Two changes here. (1) The five existing `ADV-*` fixtures all use
`$DEFAULT_CLASSIFIED` (or the synthesized `big_classified`),
which today are raw `[{slot:"vacate"}]` arrays without the new
field. Task 6c migrates these literals to set
`operator_action_required:true`, so the existing assertions
(metric=1, slack=1, etc.) continue to hold under D-004's
inclusion-by-flag filter. (2) New `AC-ADV-MISSING-FLAG` pins the
`// false` default-safe behaviour: a vacate item without
`operator_action_required` is excluded by the filter. This
catches a future classifier branch that forgets to set the
flag — the silent-default surface the brainstorm explicitly
named in D-001's "Defaulting is the bug we're fixing" argument.

### Smoke (bash -n + secret-probe-lint + pre-commit)

The `.githooks/pre-commit` hook runs every `bin/*-test.sh` plus
`bash bin/secret-probe-lint.sh`. ENG-90 introduces no new secret
references (the new code is JSON metadata + filter polarity
flips), so the secret-probe lint should be a no-op delta. The
`bash -n bin/poll.sh` syntax check at every commit catches
malformed jq quoting / heredoc errors mid-edit.

### Coverage statement

Adversarial coverage in `AC-ADV-MISSING-FLAG` + per-row coverage
in `bin/poll-slot-test.sh::AC-OAR-*` jointly satisfy AC-1 of the
issue body (every classifier branch has a fixture; adding a new
branch without a fixture trips at CI).
`AC-OAR-REVIEW-STARVATION` satisfies AC-2.
`AC-OAR-HALT-NO-MARKER` + `AC-OAR-HALT-UNKNOWN-MARKER` +
`AC-OAR-HALT-NO-MARKER-STARVATION` +
`AC-OAR-DECIDE-CONTINUE-RECOVERS-HALT-NO-MARKER` jointly satisfy
AC-3.
`AC-THR-EXCLUDE-WAIT` + `AC-THR-EXCLUDE-SKIP-CODE` +
`AC-THR-EXCLUDE-REVIEW-VACATE` jointly satisfy AC-4.
AC-5 (multi-variant recall priority) is satisfied by the
existing `AC-WAIT-*` fixtures (Pass 6 priority desc → ts asc) +
the new `AC-OAR-REVIEW-IDLE` (review-vacate has no Pass 6 entry,
recalled implicitly by next-tick classify) + the brainstorm §4
D-001 table's explicit documentation of the cross-variant
ordering. AC-6 is satisfied by the CLAUDE.md subsection +
top-of-function comment in Task 5.

## Persona review

Five personas reviewed the plan in parallel via the
`compound-engineering:document-review` skill (feasibility, scope,
coherence, design, product). Summary:

### feasibility — PASS

Every code-level fact verified against the current worktree:

- `bin/poll.sh:207-293` `_poll_classify_labels` — verified.
- `bin/poll.sh:211-214` skip-evaluate rc=1 early return — verified.
- `bin/poll.sh:228-230` paused/scope-approval arm — verified.
- `bin/poll.sh:231-247` halted arm (3-arm case + no-marker if-arm) — verified.
- `bin/poll.sh:248-256` wait branch — verified.
- `bin/poll.sh:257-287` reviewing arm — verified.
- `bin/poll.sh:285` reviewing-idle bifurcation — verified.
- `bin/poll.sh:288-290` catch-all else — verified.
- `bin/poll.sh:340-404` `_poll_emit_halt_sprawl_alert` — verified.
- `bin/poll.sh:360, 388` filter sites — verified.
- `bin/poll.sh:413-544` `main()` — verified, ENG-90 doesn't modify.
- `bin/verdict-handler.sh:84-143` `find_fresh_verdict` — verified.
- `bin/verdict-handler.sh:113` wait exclusion — verified.
- `bin/verdict-handler.sh:154-191` `find_fresh_wait_verdict` — verified.
- `bin/review-poll.sh:29-53` `review_should_dispatch` — verified.
- `bin/review-poll.sh:42` defensive dispatch on PR query failure — verified.
- `bin/poll-slot-test.sh:155-223` fixture helpers — verified.
- `bin/poll-slot-test.sh:246-289` AC-2 / AC-3 — verified.
- `bin/poll-slot-test.sh:449-474` AC-WAIT-1 — verified.
- `bin/poll-slot-test.sh:783-862` ENG-50 cases — verified.
- `bin/halt-sprawl-test.sh:184-191, 204-211, 242, 257-264, 284-291, 315-323` raw-array fixtures — verified.
- `bin/halt-sprawl-adversarial-test.sh:1-67` test harness setup; `$DEFAULT_CLASSIFIED` at lines 125-132; existing fixtures at lines 134, 151, 166, 185, 206; `big_classified` at line 212 — all verified.
- `CLAUDE.md:502` "Failure-mode quick reference" — verified.

Every task's `depends_on` list is correct: Tasks 1, 2, 3, 5 are
parallelisable (touch disjoint regions of `bin/poll.sh`); Task 4
depends on Tasks 1-3 (filter expects flag set on every vacate
branch); Task 6 depends on Tasks 1-5 (asserts post-change
behaviour). Every Failure Mode → Test Map row names a plausible
test layer (unit / integration / adversarial) and an exact test
name.

One feasibility nuance pinned in Task 6a: the
`AC-OAR-HALT-UNKNOWN-MARKER` fixture's name is preserved for
audit-table traceability, but in production
`find_fresh_verdict` does NOT return `marker:"unknown"` (the jq
projection arm at `bin/verdict-handler.sh:139-141` is reached
only for verdicts with unrecognised result tokens, which the
registry rejects). The fixture exercises the structurally
equivalent fall-through (no actionable verdict via a transition-
only marker thread), which is the same observable behaviour as
no-marker. Task 6a calls this out explicitly.

**Verdict: PASS.**

### scope — PASS

Every task and File Structure entry traces to a brainstorm
decision:

- Task 1 → D-001 + D-005 (annotate existing vacate paths).
- Task 2 → D-002 (reviewing arm vacate).
- Task 3 → D-003 (halt arm collapse).
- Task 4 → D-004 (halt-sprawl filter polarity flip).
- Task 5 → D-007 (CLAUDE.md + top-of-function citation).
- Task 6 → D-006 (test fixture coverage).

No task `touches` list strays outside the declared File Structure.
No gold-plating (the brainstorm's rejected alternatives are not
implemented; e.g., no Pass 7 for review-PR-pending, no `recall_kind`
three-valued enum, no separate skip-evaluate rc=2 path). Out-of-
scope items from the brainstorm are explicitly preserved (terminal
handling, `find_fresh_verdict` internals, `pipeline:scope-approval-
needed` semantics, slot count K). The plan does not redefine the
slot enum, does not touch `_handle_wait`'s `external_signal_budget`,
does not touch the inbox-Pass-5 query (O-1 deferred).

**Verdict: PASS.**

### coherence — PASS

Plan's Goal matches brainstorm §1 and the Linear issue's contract.
Backend Tasks jointly realise every brainstorm decision (D-001
through D-007). No frontend tasks (no FE surface). API Contract
section explicitly notes "no new API surface" per the project
profile (Bash orchestration repo).

Failure Mode → Test Map covers every brainstorm §8 edge case:

- Halt + each marker variant (5 edge cases) → 4 unit fixtures
  (HALT-PASS, HALT-FAIL, HALT-HALT, HALT-NO-MARKER) +
  HALT-UNKNOWN-MARKER fixture for transition-only fall-through.
- Reviewing + dispatch true/false → REVIEW-DISPATCH /
  REVIEW-IDLE.
- Skip variants → SKIP-HUMAN / SKIP-CODE-UNCHANGED.
- Wait verdict → WAIT.
- Three precedence edge cases (reviewing+halt, reviewing+paused,
  inbox+halt) covered transitively.
- max_concurrent edge cases covered by existing AC-1, AC-WAIT-*.
- Three regression scenarios pinned by the integration-layer
  fixtures.
- Halt-sprawl exclusions and default-flag pin covered by AC-THR-*
  and AC-ADV-MISSING-FLAG.

Every Failure Mode row names a test name that maps to a concrete
fixture in Backend Task 6. Test Strategy describes the layer
intent (unit / integration / adversarial / smoke) and notes that
the AC-1 through AC-6 acceptance criteria from the issue body are
jointly satisfied by the fixture set.

**Verdict: PASS.**

### design — PASS

Plan respects existing module responsibilities:

- `_poll_classify_labels` is the slot-classification surface;
  ENG-90 strengthens its output contract without changing its
  call signature, callers, or pass-positioning.
- `_poll_emit_halt_sprawl_alert` is the alert surface; ENG-90
  changes its filter polarity without changing inputs / outputs /
  pass-positioning.
- `find_fresh_verdict` and `find_fresh_wait_verdict` are
  unchanged.
- `review_should_dispatch` is unchanged.
- `bin/pipeline.sh decide --action continue` is unchanged
  (existing operator-resume contract).

No layering violations; no circular deps. The plan does not source
new files, does not introduce new helpers, does not register new
metric event names. The new field on every classifier output is
metadata (mirrors ENG-85's `wait_recallable` precedent) — pure
addition, no mutation of existing semantics.

The "Defaulting is the bug we're fixing" argument from the
brainstorm is preserved: every vacate-emitting branch sets the
flag explicitly (Tasks 1-3), and the halt-sprawl filter's `// false`
hatch is the strictly-safer default (silent under-count rather
than silent over-count). The adversarial test pins this.

**Verdict: PASS.**

### product — PASS

Three operator-facing improvements:

1. **Review-stage starvation eliminated.** With K=2, a
   review-waiting issue no longer blocks the queue.
2. **Halt-no-marker / halt-unknown-marker stalls eliminated.**
   Operator recovery via `decide --action continue` is the single
   documented exit ramp; today's "stuck slot" failure mode goes
   away.
3. **Halt-sprawl alert is correct.** Operators relying on
   halt-sprawl as a "halts pending operator" indicator get the
   correct count (no false positives from
   skip-until-code-changes; no false positives from review-PR-
   pending).

No regression to existing flows. The plan delivers exactly what
the Linear issue asked for, in the issue's own framing
("HOLD/VACATE/TERMINAL contract", "operator action required" as
the discriminating axis, "halt-sprawl excludes by operator-action
flag"). Every acceptance criterion (AC-1 through AC-6) maps to
a Backend task or test fixture.

**Verdict: PASS.**

## Open questions / deferred work

Inherited from brainstorm §10:

- **O-1.** Pass 5 inbox query does NOT exclude `pipeline:halted`
  labels. An operator-applied halt on a Todo issue gets picked up
  + given a `stage:brainstorming` label, then on the next tick the
  new halted arm fires (vacate, oar=true). One tick of
  brainstorm-stage-label noise + halt-sprawl alert. Not a
  regression introduced by ENG-90. Filing recommendation: low
  priority; either add `pipeline:halted` to Pass 5's exclusion
  filter or document as expected behaviour.

- **O-2.** `bin/halt-sprawl-test.sh`'s fixtures construct
  `classified_json` arrays directly rather than routing through
  `_poll_classify_all`. A future direct unit test asserting
  end-to-end "classifier output → halt-sprawl filter" would live
  in a new test file. Filing recommendation: nice-to-have;
  per-fixture coverage in D-006 sufficient for CI.

- **O-3.** Operator-visible halt-sprawl count drops post-D-004
  (skip-until-code-changes was being miscounted). Recommend a
  one-line note in the release / changelog naming the miscount fix.
  Documentation only.

- **O-4.** D-002's review-vacate logic could in principle be
  implemented as an `entry_conditions[reviewing]` predicate
  (ENG-86 surface). Today the predicate runs inside
  `_poll_classify_labels`. Filing recommendation: defer
  unification until a third stage gains entry conditions;
  premature abstraction otherwise.

- **O-5.** The contract's binary `operator_action_required`
  (true/false) cuts off three-state nuance ("operator action
  required" + "orchestrator can take a stab first"). No such
  case exists today. If/when one arises, extend to a three-valued
  enum (`operator | auto | hybrid`). Deferred.

None of these block the implement stage.
