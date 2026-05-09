---
linear: ENG-90
title: Slot-occupancy contract — holds reserved for active-dispatch work; vacate when next tick is state-check only
date: 2026-05-09
status: draft
---

# Slot-occupancy contract — every classifier branch tagged with `operator_action_required`; halt-sprawl filter and review-PR-pending arm follow from it

## 1. Overview (and the load-bearing surprise)

`bin/poll.sh::_poll_classify_labels` (verified at `bin/poll.sh:207-293`)
is the slot-classification surface. It maps an issue's
`(label set, fresh verdict marker)` pair to one of three slot
outcomes and an `advanceable` flag — but the rules were assembled
case-by-case as new states were added (ENG-20 halt-vacates, ENG-50
review gating, ENG-78 retry-immediately, ENG-85 wait-vacates), and
no single articulated contract describes what a held slot represents.

The Linear issue body provides the contract:

| Outcome     | Meaning                                                               |
| ---         | ---                                                                   |
| `terminal`  | `pipeline:abandoned`; never run again.                                |
| `hold`      | Active development; next tick will (or might) dispatch a `claude -p`. |
| `vacate`    | Agent-idle pending an external signal (operator action, upstream code change, PR check, human approval, CI). The next tick's work is bounded to **cheap orchestrator-side state checks** — no slot needed. |

Three current branches violate this contract by holding a slot when
the next tick will not dispatch any agent:

1. **Review-stage hold-during-PR-wait** (`bin/poll.sh:283-285`).
   `review_should_dispatch` returns false (PR not mergeable, checks
   pending) — the review agent will not be dispatched. Today: `hold,
   advanceable=false`. Same shape as ENG-85's pre-fix build wait. PR
   checks can run for hours; on `K=2` one stuck review starves the
   queue.
2. **Halt + no fresh marker** (`bin/poll.sh:234-235`). `pipeline:halted`
   blocks dispatch by definition, so no agent compute will run
   regardless. Today: `hold, advanceable=false`. If the marker never
   appears (silent agent crash, externally-applied label), the slot
   holds indefinitely.
3. **Halt + unrecognised marker** (`bin/poll.sh:244-245`). Same
   reasoning as #2 — the halt label gates dispatch and the marker
   shape is irrelevant for that gate. Today: `hold, advanceable=false`.

**Halt-sprawl miscount.** The halt-sprawl alert
(`bin/poll.sh:340-404`) counts `slot == "vacate"` rows excluding
`(.wait_recallable // false) != true` (line 360, 388). The exclusion
captures ENG-85's build-wait but no other "operator-not-required"
vacate. Two specific bugs land in production:

- `pipeline:skip-until-code-changes` with evidence unchanged is a
  vacate driven by upstream code change (`bin/poll.sh:48-137` —
  `_poll_evaluate_skip` returns rc=1 → caller emits
  `slot:vacate, advanceable:false` at line 211-213). Operator action
  is **not** required — but it counts toward halt-sprawl today.
- After D-002 below, review-PR-pending becomes a vacate. Without a
  parallel exclusion it would count as a halt and trip halt-sprawl
  on long-running PR-check waits.

The exclusion criterion in `_poll_emit_halt_sprawl_alert` should be
**"operator action required to advance"** rather than per-flag
whitelisting — anything else asks the same drift to be re-introduced
the next time a vacate kind is added.

**Why now.** ENG-85 fixed exactly this for build wait by surfacing a
single piece of metadata (`wait_recallable`) and threading it
through the halt-sprawl exclusion + a Pass 6 recall picker. Each
new vacate kind today repeats that work. ENG-90 extracts the
contract: every classifier branch declares `operator_action_required`,
and the halt-sprawl filter consumes that flag uniformly. Future
additions to the classifier — stress-load throttling, per-stage
gating beyond review — get the alert exclusion for free by setting
the flag.

## 2. Goals

After this ticket lands:

1. **Single contract** (D-001). Every classifier branch produces
   `slot ∈ {terminal, hold, vacate}` AND, for vacate items, an
   explicit `operator_action_required: bool` flag. The flag's
   semantics: `true` iff the only path back to a slot runs through a
   human acting on the issue (label removal, `bin/pipeline.sh decide
   --action continue`, `gh pr review`). `false` iff the recall
   predicate is something the orchestrator can re-evaluate on its
   own each tick (PR mergeability, pipeline-content-hash, branch
   HEAD SHA).
2. **Review-PR-pending vacates** (D-002). When `stage:reviewing` is
   present and `review_should_dispatch` returns false, the slot
   classifies as `vacate, advanceable=false, operator_action_required=false`.
   Recall is implicit via next-tick classify (the orchestrator
   re-runs `review_should_dispatch` on every tick — same surface
   that classify already touches today). No Pass 6 changes for this
   variant.
3. **Halt-without-actionable-marker vacates** (D-003). Cases
   `bin/poll.sh:234-235` and `bin/poll.sh:244-245` collapse to
   `vacate, operator_action_required=true`. Only the
   `pipeline-stage-summary` / `pipeline-rejection` sub-case
   (line 240-241) keeps `slot:hold, advanceable:true` — that path
   leads to `verdict_handler` running the transition in Pass 4
   (`bin/poll.sh:467-475`), which IS active dispatch work.
4. **Halt-sprawl excludes by `operator_action_required`** (D-004).
   The filter at `bin/poll.sh:360` and the top-3 selector at
   `bin/poll.sh:388` swap from `(.wait_recallable // false) != true`
   to `(.operator_action_required // false) == true`. Functionally
   equivalent for build-wait (already excluded), and additionally
   excludes skip-until-code-changes (today's miscount) and
   review-PR-pending (would be a new miscount post-D-002).
5. **Test-pinned regression coverage** (D-006). One test fixture
   per row of the audit table from §1.6 of the issue body, plus a
   halt-sprawl adversarial fixture covering both new exclusions and
   a review-vacate fleet not tripping halt-sprawl. Adding a new
   classifier branch without adding a fixture fails CI by virtue of
   adversarial coverage detecting the unannotated outcome.
6. **Contract documented in code and CLAUDE.md** (D-007). A one-line
   citation at the top of `_poll_classify_labels` plus a CLAUDE.md
   subsection in "Failure-mode quick reference" naming the
   contract. Future additions are bound to revisit it.

Non-goals (explicit, follow the issue's framing):

- **`pipeline:abandoned` (terminal) handling is unchanged.** Terminal
  items don't have `operator_action_required` (the field is
  meaningless for never-runs-again issues); halt-sprawl filter on
  `slot == "vacate"` excludes them naturally.
- **`pipeline:scope-approval-needed` and `pipeline:paused` semantics
  are unchanged.** Both are operator-applied labels with operator-driven
  recall. They fall into `vacate, operator_action_required=true` —
  same observable behaviour as today (slot vacated, halt-sprawl counts
  them).
- **Marker-shape recognition logic inside `find_fresh_verdict` is
  unchanged.** This ticket only changes how the classifier
  *dispositions* halts after the marker is parsed. The set of
  recognised markers
  (`pipeline-stage-summary | pipeline-rejection | pipeline-halt | unknown`)
  and the fall-back logic to `unknown` are out of scope.
- **No new Pass 6 variants.** ENG-85's Pass 6 for `wait_recallable`
  stays as-is. Review-PR-pending uses implicit recall via next-tick
  classify — there's no orchestrator-internal predicate that
  benefits from a Pass 6 round (the predicate
  `review_should_dispatch` IS a per-tick classify input). See §5
  rejected alternatives for the explicit comparison.
- **Slot count `K` and per-stage limits (ENG-81) are out of scope.**
  This ticket is about *which* issues count toward `K`, not the
  value of `K`.
- **`external_signal_budget` / `_handle_wait` semantics are
  unchanged.** Build-wait still uses Pass 6 to re-dispatch (ENG-85);
  the per-issue attempts/wall-clock budgets in
  `bin/run-stage.sh::_handle_wait` are untouched.

## 3. Architectural principle

There is no `docs/VISION.md`, `docs/ARCHITECTURE.md`, or
`docs/knowledge/decisions.md` (verified — `ls docs/` returns
`brainstorms/  pipeline-vocabulary.md  pipeline-vocabulary.template.md
plans/  runbooks/`). Governing constraints come from `CLAUDE.md`,
`learned-rules/harness/project-profile.md`, and accepted brainstorms
— same regime ENG-67 / ENG-78 / ENG-79 / ENG-85 documented.

Principles invoked:

- **Slot accounting expresses agent activity, not labels.** ENG-85
  established the rule for build wait. ENG-90 generalises: every
  classifier branch declares whether agent compute is upcoming. The
  three current violations (review-PR-pending, halt-no-marker,
  halt-unknown-marker) all have the same shape — an issue holding
  a slot for a state check the orchestrator can do itself.
  CLAUDE.md "Failure-mode quick reference" already states the
  halt-vacate contract: *"Per-issue halt […] Other issues continue
  to be polled — do NOT touch `orchestrator.paused`."* This
  brainstorm extends that contract to every halt sub-state and
  to review-PR-pending.

- **Symmetric defense across the slot-classification surface.**
  ENG-67's brainstorm §3 establishes that when an invariant is
  enforced at one layer, the adjacent layer should also have a test
  pinning that no equivalent path exists in *that* layer.
  ENG-85 pinned the wait-vacates path. ENG-90 pins every row of the
  audit table — both the "matches contract" rows and the
  "violation" rows that this ticket fixes. AC-1 in the Linear issue
  body codifies this: *"Adding a new branch to `_poll_classify_labels`
  without adding a test fails CI."*

- **Closed event vocabulary.** `operator_action_required` is a
  binary flag with two values; every classifier branch sets it
  explicitly. No `null`, no missing key, no defaulting (jq's
  `// false` fallback is reserved for catch-all `slot == "hold"`
  items where the field is meaningless). This mirrors the closed
  event vocabulary in `bin/pipeline-events.json` — the registry
  pattern that CLAUDE.md "Pipeline vocabulary" § names as canonical.

- **`die` over silent fallback (defense in depth).** Where the
  classifier can't determine the disposition (e.g.,
  `find_fresh_verdict` returns empty under Linear-API outage in
  the halted arm), the rule prefers the *safer* of the two
  outcomes. For ENG-90 specifically: an outage that prevents
  marker parsing in the halted arm previously held the slot
  (one tick of waste); after D-003 it vacates the slot
  (no waste). Both are recoverable on next tick when the API
  recovers; vacate is strictly better because it frees a slot for
  any sibling work the API outage doesn't touch (e.g., classify
  ran successfully for a different issue that doesn't need
  `find_fresh_verdict`). This matches the same fail-closed rule
  ENG-85 D-002 codified for `find_fresh_wait_verdict`.

- **Existing pass discipline preserved.** `main()`'s
  Pass 1-2-2b-3-4-5-6-idle structure
  (`bin/poll.sh:413-544`, post-ENG-85) is load-bearing; ENG-78,
  ENG-26, ENG-85 brainstorms all rely on its ordering. ENG-90
  modifies only the classifier output shape and the halt-sprawl
  filter — does not reorder, rename, or merge any existing pass.

## 4. Decisions

### D-001: Add `operator_action_required` to every vacate-classifier branch

**Verdict.** Every code path in `_poll_classify_labels` that emits
`slot:"vacate"` also emits `operator_action_required: bool`. The
flag's semantics are exhaustive — `true` iff a human must act on
the issue (label removal, `bin/pipeline.sh decide --action continue`,
PR review/approval) before classify can return the issue to a slot.
For the three slot values:

| Slot | `operator_action_required` |
|---|---|
| `terminal` (abandoned) | absent — irrelevant (never recalled) |
| `hold` | absent — agent dispatch is upcoming |
| `vacate` | mandatory — `true` or `false` |

The full table for current and new branches:

| Branch | `slot` | `advanceable` | `operator_action_required` | Recall mechanism |
|---|---|---|---|---|
| `pipeline:abandoned` (line 226-227) | terminal | false | n/a | none |
| `pipeline:paused` (line 228-230) | vacate | false | **true** | operator removes label |
| `pipeline:scope-approval-needed` (line 228-230) | vacate | false | **true** | operator removes label |
| `pipeline:halted` + `pipeline-stage-summary` / `pipeline-rejection` (line 240-241) | hold | true | n/a | Pass 4 → `verdict_handler` transition |
| `pipeline:halted` + `pipeline-halt` marker (line 242-243) | vacate | false | **true** | `bin/pipeline.sh decide --action continue` |
| `pipeline:halted` + no marker (line 234-235) | vacate (D-003) | false | **true** | `bin/pipeline.sh decide --action continue` |
| `pipeline:halted` + unknown marker (line 244-245) | vacate (D-003) | false | **true** | `bin/pipeline.sh decide --action continue` |
| fresh `verdict result=wait` (line 248-256) | vacate | false | **false** | Pass 6 wait recall |
| `stage:reviewing` + `review_should_dispatch=true` (line 282-283) | hold | true | n/a | Pass 4 dispatch |
| `stage:reviewing` + `review_should_dispatch=false` (line 284-285) | vacate (D-002) | false | **false** | next-tick implicit (PR state changes) |
| `pipeline:skip-until-human-acts` (`_poll_evaluate_skip` rc=1, line 92-95) | vacate | false | **true** | operator removes label |
| `pipeline:skip-until-code-changes` evidence-unchanged (`_poll_evaluate_skip` rc=1, line 109-136) | vacate | false | **false** | next-tick implicit (`pipeline_content_hash` / branch SHA changes via `_poll_evaluate_skip` mid-tick re-entry, line 109-134) |
| catch-all else (line 288-290) | hold | true | n/a | Pass 4 dispatch |

The flag carries one bit of information that wasn't observable
before. `wait_recallable` (ENG-85's flag) and the new
`operator_action_required` are independent: `wait_recallable`
identifies "Pass 6 picks this up"; `operator_action_required`
identifies "halt-sprawl counts this." A future `Pass 7` for some
other recall variant would set `operator_action_required: false`
(orchestrator-can-recall) AND its own `Pass 7`-specific flag.

**Why annotate every branch rather than infer from labels.** Three
arguments:

1. **Defaulting is the bug we're fixing.** Today the halt-sprawl
   exclusion uses `(.wait_recallable // false) != true`, where
   `// false` defaults the missing field. Items that should have
   been excluded (skip-until-code-changes) silently default to
   false → counted. An explicit field on every classifier output
   eliminates the silent-default surface.
2. **Single source of truth.** With the flag, halt-sprawl never
   needs to inspect labels — only `operator_action_required`. This
   isolates the alert from churn in the classification rules. If
   ENG-100 adds a new vacate kind and forgets the flag, the
   alert's behaviour is undefined; tests fail (D-006 covers this);
   reviewer is forced to set the flag.
3. **Mirrors `wait_recallable` precedent.** ENG-85 chose to add a
   metadata flag (`wait_recallable`) rather than expand the slot
   enum (`slot:"wait"`). Same reasoning: pure metadata addition has
   smaller blast radius than a fourth slot value, and consumers
   that don't care about the new flag ignore it via jq filter.

**Rejected alternative — derive `operator_action_required` post-hoc
in `_poll_emit_halt_sprawl_alert`.** The alert function would peek at
each item's labels, marker, etc. to recompute the flag. Two costs:
(a) duplicates the classification logic in two places — drift
guaranteed; (b) re-runs classifier checks (e.g., `find_fresh_verdict`
calls back into Linear) at alert time. Rejected — the classifier is
the single place that knows the disposition; emit it once.

**Rejected alternative — invert the flag (`auto_recallable: bool`).**
Symmetric in expressiveness. Rejected because the human-facing
intent is "should the operator be alerted that X needs them?" — the
direct framing is "operator action required." `auto_recallable=true`
reads as a property of the orchestrator; `operator_action_required=true`
reads as a property of the issue. The latter aligns with the
audience (operator).

**Rejected alternative — three-valued
`recall_kind: "operator" | "auto" | "none"`.** More expressive: the
"none" case (terminal) is distinguishable. Rejected because the
binary suffices for the current callers (halt-sprawl, Pass 6,
documentation), and a three-valued field invites confusion at the
call sites that only care about the binary distinction. Terminal
items have `slot:"terminal"` already — that's the
"never recall" signal.

### D-002: Reviewing branch — `review_should_dispatch=false` → vacate

**Verdict.** In `_poll_classify_labels`, change the
`stage:reviewing` arm at `bin/poll.sh:282-285` from:

```bash
# bin/poll.sh:282-286 (TODAY — verbatim)
if review_should_dispatch "$ident" "$_rp_branch"; then
  class='{"slot":"hold","advanceable":true}'
else
  class='{"slot":"hold","advanceable":false}'
fi
```

to:

```bash
# bin/poll.sh:282-287 (POST-ENG-90)
if review_should_dispatch "$ident" "$_rp_branch"; then
  class='{"slot":"hold","advanceable":true}'
else
  # ENG-90: PR not mergeable / checks pending. Agent dispatch will not
  # run; the next tick re-evaluates review_should_dispatch (cheap
  # orchestrator-side state check). Vacate the slot so sibling work
  # can dispatch.
  class='{"slot":"vacate","advanceable":false,"operator_action_required":false}'
fi
```

Note the `operator_action_required:false` — the recall predicate is
`review_should_dispatch`, which `_poll_classify_labels` itself runs
on every tick. There is no operator action involved.

**Why implicit recall (no Pass 6 entry).** Pass 6 (`bin/poll.sh:519-537`)
exists for `wait_recallable` items because the predicate that decides
"can we make progress on this wait?" is run by the *agent* during
dispatch — `bin/run-stage.sh::_handle_wait` reads `gh pr view
--json reviews` for `awaiting-approval` and emits a fresh wait verdict
or a pass. The orchestrator can't decide that from outside the
agent today.

For review-PR-pending the predicate IS in the orchestrator
(`bin/review-poll.sh::review_should_dispatch`, lines 29-53), and
classify already calls it on every tick (line 282). When the PR
becomes mergeable mid-day, the next tick's classify flips the issue
from `vacate` to `hold, advanceable=true`, and Pass 4 dispatches it
in the same tick. No Pass 6 round needed; the recall is implicit
in the per-tick classify pass.

This is the SAME pattern `_poll_evaluate_skip` already uses for
`skip-until-code-changes` evidence: when the hash or branch SHA
changes, `_poll_evaluate_skip` clears the label mid-tick (line
109-134) and the issue re-enters classify as
`stage:* + no skip label → hold, advanceable=true` in the same
tick. Implicit-recall pattern; no parallel pass.

**Edge case: review_should_dispatch returns false because the PR
query failed.** `bin/review-poll.sh:42` returns 0 (dispatch
defensively) when `gh pr view` fails. So
`review_should_dispatch=false` only fires on a *successful* query
where the PR has no new commits since `last-review-state.sha`.
Vacating in that case is correct — the agent has nothing new to
do.

**Edge case: `branch-name.sh` derivation fails.** Line 273-278 keeps
the existing fail-open: classify emits `hold, advanceable=true`.
Branch derivation failure is a Linear-API outage, not a state
change — and the fail-open path lets the agent dispatch detect the
real cause via its own contracts. ENG-90 does NOT change this.

**Rejected alternative — Pass 7 for review-PR-pending.** Add a Pass
6.5/7 that re-runs `review_should_dispatch` for vacate-recallable
review issues and dispatches them when it returns true. Rejected
because (a) the predicate is already evaluated in classify (Pass 2);
running it again post-classify is duplicate work; (b) within a
single tick the predicate is invariant — there's no point at which
Pass 6.5 sees a different answer than Pass 2. The only meaningful
re-evaluation is on the *next* tick, which is exactly what implicit
recall is.

**Rejected alternative — keep `hold, advanceable=false` for review.**
Status quo. Rejected because it's literally the violation the
issue body documents (§1.5 row 284-285). The starvation shape is
real (PR checks can run for hours; one stuck review on `K=2`
saturates the queue indefinitely).

### D-003: Halted arm — collapse "no marker" / "unknown marker" / "pipeline-halt" to one vacate path

**Verdict.** In `_poll_classify_labels`, simplify the halted arm at
`bin/poll.sh:231-247`:

```bash
# bin/poll.sh:231-247 (TODAY — verbatim)
elif [[ "$(_has_label pipeline:halted)" == "true" ]]; then
  local fresh
  fresh="$(find_fresh_verdict "$ident" 2>/dev/null || printf '')"
  if [[ -z "$fresh" ]]; then
    class='{"slot":"hold","advanceable":false}'      # ← violation
  else
    local marker
    marker="$(jq -r '.marker // ""' <<<"$fresh")"
    case "$marker" in
      pipeline-stage-summary|pipeline-rejection)
        class='{"slot":"hold","advanceable":true}' ;;
      pipeline-halt)
        class='{"slot":"vacate","advanceable":false}' ;;
      *)
        class='{"slot":"hold","advanceable":false}' ;;  # ← violation
    esac
  fi
```

becomes:

```bash
# bin/poll.sh:231-247 (POST-ENG-90)
elif [[ "$(_has_label pipeline:halted)" == "true" ]]; then
  local fresh
  fresh="$(find_fresh_verdict "$ident" 2>/dev/null || printf '')"
  if [[ -n "$fresh" ]]; then
    local marker
    marker="$(jq -r '.marker // ""' <<<"$fresh")"
    case "$marker" in
      pipeline-stage-summary|pipeline-rejection)
        # Verdict-handler-led transition is upcoming in Pass 4; the
        # halt label is consumed by apply_transition. Slot remains
        # held (active dispatch work).
        class='{"slot":"hold","advanceable":true}' ;;
      *)
        # pipeline-halt OR unknown marker. Halt label gates dispatch
        # — no agent compute will run regardless of marker shape.
        # Operator must run `bin/pipeline.sh decide --action continue`.
        class='{"slot":"vacate","advanceable":false,"operator_action_required":true}' ;;
    esac
  else
    # No fresh marker (silent agent crash, externally-applied label,
    # or marker race with this tick). Halt label still gates dispatch
    # — no agent compute will run. Operator must run
    # `bin/pipeline.sh decide --action continue`.
    class='{"slot":"vacate","advanceable":false,"operator_action_required":true}' ;;
  fi
```

Two structural changes:

1. **Cases 234-235 and 244-245 collapse to `vacate,
   operator_action_required=true`.** Both expressed
   "halt label present + no actionable transition pending" → no
   agent compute is upcoming → slot wasted by holding.
2. **The `pipeline-halt` arm (line 242-243) folds into the same
   default case.** It already vacated; nothing changes in
   observable behaviour for that sub-case beyond gaining the
   `operator_action_required:true` annotation. Branch flattens
   from a 3-arm `case` to a 2-arm one (stage-summary/rejection vs
   default).

**The "race" sub-case.** When the agent has just emitted a halt
verdict marker and is about to apply the `pipeline:halted` label
(or vice versa), there's a one-tick window where label and marker
disagree. Today's behaviour (hold, advanceable=false) holds the
slot for one tick (≈5 min), then next tick the marker lands and
the issue is correctly classified. After D-003: vacate for one tick,
then next tick the marker lands and classify lands on the
stage-summary/rejection arm (`hold, advanceable=true`) — Pass 4
dispatches the verdict_handler transition. Net wall-clock: ≤5 min,
identical to today. Strict improvement: in the race window, the
slot is freed for sibling work.

**The "silent crash" sub-case.** Agent crashes after emitting halt
marker but before label, OR before either. Both surfaces visible
to operator only after manual inspection. Today: slot held forever
until operator intervenes. After D-003: slot vacated on first tick
where halt-without-marker is detected; halt-sprawl counts the
issue (because `operator_action_required:true`); operator notices
via the threshold-cross alert and runs
`bin/pipeline.sh decide --action continue`. Strict improvement:
operator-visible alert + slot freed.

**The "externally-applied halt label" sub-case.** Most likely: a
human applied `pipeline:halted` manually without posting a marker.
Today: slot held forever. After D-003: same recovery as silent
crash — vacate, halt-sprawl counts, operator resolves via decide.
Strict improvement.

**Rejected alternative — preserve hold for `pipeline-halt` marker
specifically.** The argument: the explicit `pipeline-halt` marker
indicates a *deliberate* halt by the agent, possibly with intent
to retry; vacating gives up. Rejected because (a) every halt path
in production today calls `bin/pipeline.sh decide --action continue`
to recover — the recovery flow doesn't distinguish marker shapes;
(b) the `pipeline-halt` arm at line 242-243 ALREADY vacates today —
this rejected alternative would *re-add* a hold path that
currently doesn't exist.

**Rejected alternative — preserve hold for "no marker" sub-case
only (race-window protection).** The argument: a one-tick hold for
the race window is cheap insurance. Rejected because (a) the race
window's worst-case wall-clock is the same under hold or vacate
(see "race sub-case" above) — vacate strictly dominates; (b)
keeping one violation in a contract-formalising ticket leaves a
seam for the next failure mode to slip through. Symmetric closure.

### D-004: Halt-sprawl filter — switch from `wait_recallable` exclusion to `operator_action_required` inclusion

**Verdict.** In `_poll_emit_halt_sprawl_alert`, change the count and
top-3 filters at `bin/poll.sh:360` and `bin/poll.sh:388` from:

```bash
# bin/poll.sh:360 (TODAY — verbatim)
count="$(jq '[.[] | select(.slot == "vacate" and (.wait_recallable // false) != true)] | length' <<<"$classified_json")"

# bin/poll.sh:388
top3="$(jq -rc '[.[] | select(.slot == "vacate" and (.wait_recallable // false) != true) | .identifier] | .[:3] | join(", ")' \
         <<<"$classified_json")"
```

to:

```bash
# bin/poll.sh:360 (POST-ENG-90)
# ENG-90: count vacates where operator action is required to advance.
# Excludes orchestrator-recallable vacates (build-wait, review-PR-pending,
# skip-until-code-changes evidence-unchanged) which are not halts.
count="$(jq '[.[] | select(.slot == "vacate" and (.operator_action_required // false) == true)] | length' <<<"$classified_json")"

# bin/poll.sh:388
top3="$(jq -rc '[.[] | select(.slot == "vacate" and (.operator_action_required // false) == true) | .identifier] | .[:3] | join(", ")' \
         <<<"$classified_json")"
```

The polarity flips: the previous filter EXCLUDED items where a
specific flag was set; the new filter INCLUDES items where a
specific flag is set. Default-false (the `// false`) is the
back-compat hatch: any classifier output that forgets to set
`operator_action_required` is silently excluded from the alert
(strictly safer than over-counting). The unit-test fixtures pin
that every active classifier branch sets the flag explicitly
(D-006), so the default-false cannot mask a real miscount.

**Why polarity flip.** Two arguments for inclusion-by-flag rather
than exclusion-by-flag:

1. **A new vacate kind defaults to "not a halt" rather than "is a
   halt."** With exclusion-by-flag, every new flag (e.g.,
   `review_recallable`, `skip_recallable`) must be added to the
   filter. With inclusion-by-flag, every new vacate kind only
   needs to declare `operator_action_required` once at its
   classifier branch — no filter touch. Reduces the surface
   where additions can drift.
2. **Halt-sprawl is a semantic alert** ("count of issues stuck
   pending operator"), not a "count of issues vacating with no
   recall." Inclusion-by-flag matches the semantic; exclusion-by-flag
   matches the implementation history.

**Rejected alternative — ADD `operator_action_required` filter on
top of the existing `wait_recallable` exclusion.**

```jq
[.[] | select(.slot == "vacate" 
              and (.wait_recallable // false) != true
              and (.operator_action_required // false) == true)] | length
```

Rejected because the second clause subsumes the first (anything
with `wait_recallable=true` has `operator_action_required=false`
per D-001's contract; the `wait_recallable!=true` clause is
redundant). Carrying both clauses just guarantees they drift apart
the next time someone touches the alert. Single source of truth.

**Rejected alternative — replace `wait_recallable` semantics with
`operator_action_required`** (delete `wait_recallable`). Tempting
because both fields are declared per-classifier-branch. Rejected
because Pass 6 (`bin/poll.sh:519-537`) uses `wait_recallable` to
identify items it should pick up, and the inversion
(`operator_action_required==false`) would also include
review-PR-pending items that must NOT be picked up by Pass 6
(D-002 mandates implicit recall for them). The two flags answer
different questions:

- `wait_recallable`: "Pass 6 should re-dispatch this with an agent."
- `operator_action_required`: "halt-sprawl should count this."

Independent. Both are needed.

### D-005: Skip-classification — differentiate `skip-until-human-acts` vs `skip-until-code-changes`

**Verdict.** In `_poll_classify_labels`'s early-return path at
`bin/poll.sh:211-214`, branch on the labels to set
`operator_action_required` correctly:

```bash
# bin/poll.sh:211-214 (TODAY — verbatim)
if ! refreshed_labels="$(_poll_evaluate_skip "$ident" "$labels_json")"; then
  jq -nc --argjson l "$labels_json" '{slot:"vacate",advanceable:false,labels:$l}'
  return 0
fi
```

becomes:

```bash
# bin/poll.sh:211-220 (POST-ENG-90)
if ! refreshed_labels="$(_poll_evaluate_skip "$ident" "$labels_json")"; then
  # ENG-90: differentiate the two skip kinds. skip-until-human-acts is
  # operator-action-required (operator removes label). skip-until-code-changes
  # with evidence unchanged is auto-recallable (next-tick _poll_evaluate_skip
  # re-checks pipeline_content_hash + branch SHA; clears label mid-tick on
  # change, line 109-134). _poll_evaluate_skip returns rc=1 in BOTH cases
  # (line 92-95 for human-acts, line 136 for code-changes-unchanged); the
  # caller distinguishes via labels.
  local oar="false"
  if [[ "$(jq -r --arg n "pipeline:skip-until-human-acts" '[.[] | select(. == $n)] | length > 0' <<<"$labels_json")" == "true" ]]; then
    oar="true"
  fi
  jq -nc --argjson l "$labels_json" --argjson oar "$oar" \
    '{slot:"vacate",advanceable:false,operator_action_required:$oar,labels:$l}'
  return 0
fi
```

When both labels are present (rare but possible), `_poll_evaluate_skip`
already short-circuits on `has_human_label==true` (line 92-95) without
recomputing evidence — so the human-acts label dominates. The
classify-side check uses the same dominance rule: if
human-acts is present, oar=true; otherwise (code-changes only),
oar=false.

**Why check labels in `_poll_classify_labels` rather than have
`_poll_evaluate_skip` return distinguishable rc.** Three options:

1. **Two rc values from `_poll_evaluate_skip`** (e.g., rc=1 for
   human-acts, rc=2 for code-changes). Rejected because Bash
   convention is rc=0 success / rc!=0 failure with semantic
   distinction reserved for documented failure codes (the
   `failure_outcome_for_exit` taxonomy in `bin/common.sh`).
   `_poll_evaluate_skip`'s contract is "include yes/no" — adding
   semantic rc values invites callers to misread.
2. **Stdout-channel disposition signal.** `_poll_evaluate_skip`
   could print `human-acts\n` or `code-changes\n` to stdout when
   it returns rc=1, alongside today's `refreshed_labels` print.
   Rejected because stdout already carries the post-resume label
   set (line 133 — when evidence changed, the line emits the
   stripped labels). Stuffing two semantically distinct payloads
   on the same channel is a parser nightmare.
3. **Caller re-reads labels** (chosen). Cheap, explicit, no
   coupling between callers. The label check is a single jq
   invocation; per-tick per-issue cost is negligible.

**Rejected alternative — set `operator_action_required:true` for
both skip variants.** Simpler classifier. Rejected because
`skip-until-code-changes` evidence-unchanged is provably
recallable without operator action — the
`pipeline_content_hash`/`branch_head_sha` tracking exists exactly
because this surface is auto-recoverable. Setting
`operator_action_required:true` would cause skip-until-code-changes
to count toward halt-sprawl — exactly the bug the issue body
documents. Direct violation of the contract.

### D-006: Test fixture coverage — every audit-table row pinned

**Verdict.** Extend `bin/poll-slot-test.sh` with a fixture per row of
the audit table from §1, reusing the existing
`write_label_fixture` / `write_comments_fixture` /
`write_inbox_fixture` helpers (`bin/poll-slot-test.sh:160-223`).
Extend `bin/halt-sprawl-test.sh` and
`bin/halt-sprawl-adversarial-test.sh` with the corresponding
inclusion/exclusion regression cases.

**`bin/poll-slot-test.sh` — classifier output cases.** One
fixture per classifier branch, named `AC-OAR-<row>`:

| Fixture | Setup | Expected output |
|---|---|---|
| `AC-OAR-ABANDONED` | `["pipeline:abandoned"]` | `slot:terminal, advanceable:false` (no oar field) |
| `AC-OAR-PAUSED` | `["pipeline:paused"]` | `slot:vacate, advanceable:false, operator_action_required:true` |
| `AC-OAR-SCOPE` | `["pipeline:scope-approval-needed"]` | same as above |
| `AC-OAR-HALT-PASS` | `["pipeline:halted"]` + fresh `verdict result=pass stage=planning` | `slot:hold, advanceable:true` (no oar — slot is hold) |
| `AC-OAR-HALT-FAIL` | `["pipeline:halted"]` + fresh `verdict result=fail target=implementing` | same as above |
| `AC-OAR-HALT-HALT` | `["pipeline:halted"]` + fresh `verdict result=halt reason=agent-blocked` | `slot:vacate, advanceable:false, operator_action_required:true` (current `pipeline-halt` arm + new oar) |
| `AC-OAR-HALT-NO-MARKER` | `["pipeline:halted"]`, comments empty | `slot:vacate, advanceable:false, operator_action_required:true` (D-003 — was hold today) |
| `AC-OAR-HALT-UNKNOWN-MARKER` | `["pipeline:halted"]` + an unrecognised marker (e.g., a `<!-- pipeline: transition from=… to=… -->` only) | `slot:vacate, advanceable:false, operator_action_required:true` (D-003 — was hold today) |
| `AC-OAR-WAIT` | `["stage:building"]` + fresh `verdict result=wait reason=awaiting-approval` | `slot:vacate, advanceable:false, wait_recallable:true, wait_progress_ts:..., operator_action_required:false` (extends existing AC-WAIT-1 with the new field) |
| `AC-OAR-REVIEW-DISPATCH` | `["stage:reviewing"]` + `REVIEW_SHOULD_DISPATCH=0` | `slot:hold, advanceable:true` (no oar) |
| `AC-OAR-REVIEW-IDLE` | `["stage:reviewing"]` + `REVIEW_SHOULD_DISPATCH=1` | `slot:vacate, advanceable:false, operator_action_required:false` (D-002 — was hold today) |
| `AC-OAR-SKIP-HUMAN` | `["stage:planning","pipeline:skip-until-human-acts"]` + state file present | `slot:vacate, advanceable:false, operator_action_required:true` (D-005) |
| `AC-OAR-SKIP-CODE-UNCHANGED` | `["stage:planning","pipeline:skip-until-code-changes"]` + state file with prev_hash matching `compute_pipeline_content_hash` | `slot:vacate, advanceable:false, operator_action_required:false` (D-005) |
| `AC-OAR-DEFAULT` | `["stage:implementing"]` (no other labels, no fresh markers) | `slot:hold, advanceable:true` (no oar) |

Plus the regression cases that pin observable behaviour:

| Fixture | Setup | Expected behaviour |
|---|---|---|
| `AC-OAR-REVIEW-STARVATION` | ENG-A at `stage:reviewing` + `REVIEW_SHOULD_DISPATCH=1`; ENG-B at `stage:implementing`; cap=2 | `main()` dispatches ENG-B (review-vacate frees the slot per D-002) |
| `AC-OAR-HALT-NO-MARKER-STARVATION` | ENG-A at `stage:planning` + `pipeline:halted` + no marker; ENG-B Todo in inbox; cap=2 | `main()` dispatches ENG-B with `entry_action:apply-stage-label` (halt-no-marker frees the slot per D-003 — was held pre-fix) |
| `AC-OAR-DECIDE-CONTINUE-RECOVERS-HALT-NO-MARKER` | ENG-A at `stage:planning` + `pipeline:halted` + no marker (vacated). Operator runs `bin/pipeline.sh decide --action continue` (simulated by removing the halt label and writing the resume waypoint marker). Next tick: classify sees no halt label + a transition waypoint → catch-all `else` (`hold, advanceable:true`). | `main()` dispatches ENG-A on the next tick |

The first regression case is the literal review-starvation
scenario from the Linear issue body's example. The second is the
halt-no-marker starvation that D-003 closes. The third pins the
operator-recovery contract for D-003's vacate path —
`bin/pipeline.sh decide --action continue` is the documented
exit ramp (CLAUDE.md "Failure-mode quick reference" §).

**`bin/halt-sprawl-test.sh` — inclusion/exclusion regression
cases.** The existing fixtures (`bin/halt-sprawl-test.sh:184-189`)
construct raw `[{"identifier":"...", "slot":"vacate"}]` arrays.
Per D-004, the new filter requires `operator_action_required:true`
to count an item — those existing fixtures must be updated to set
the flag explicitly:

```jsonc
// AC-THR-EQ, AC-THR-GT, AC-DEBOUNCE-* fixture rows post-D-004:
{"identifier":"ENG-101","slot":"vacate","operator_action_required":true}
```

Plus three NEW fixtures pinning the exclusions:

| Fixture | Setup | Expected |
|---|---|---|
| `AC-THR-EXCLUDE-WAIT` | 6 vacate items, all with `wait_recallable:true, operator_action_required:false`; threshold=5 | No metric, no Slack (existing ENG-85 invariant; pinned post-rename) |
| `AC-THR-EXCLUDE-SKIP-CODE` | 6 vacate items, all with `operator_action_required:false` (modeling skip-until-code-changes evidence-unchanged); threshold=5 | No metric, no Slack (D-004 — was a miscount today) |
| `AC-THR-EXCLUDE-REVIEW-VACATE` | 6 vacate items, all with `operator_action_required:false` (modeling review-PR-pending); threshold=5 | No metric, no Slack (D-004 — would be a new miscount post-D-002 without D-004) |
| `AC-THR-MIXED` | 3 items `operator_action_required:true` + 3 items `operator_action_required:false`; threshold=5 | No metric (count=3 ≤ 5) |
| `AC-THR-MIXED-OVER` | 6 items `operator_action_required:true` + 3 items `operator_action_required:false`; threshold=5 | Metric notes `count=6 threshold=5`; Slack top-3 lists only `operator_action_required:true` items |

The MIXED fixtures also pin that the top-3 Slack body uses the
SAME inclusion filter as the count — i.e., a vacate item with
`operator_action_required:false` is never named in the Slack body
even when the alert fires. This is the case-by-case derivation of
issue body's AC-4 ("Adversarial test: a fleet of long-running
review-waiting issues does NOT trip halt-sprawl").

**`bin/halt-sprawl-adversarial-test.sh` — defense-in-depth.** Add
one fixture asserting that an item with no `operator_action_required`
field is treated as excluded (the `// false` default-safe
behaviour):

| Fixture | Setup | Expected |
|---|---|---|
| `AC-ADV-MISSING-FLAG` | 6 vacate items WITHOUT `operator_action_required` field; threshold=5 | No metric, no Slack (default-false → excluded) |

This pins the D-004 default behaviour: a future classifier branch
that forgets the field is silently excluded — strictly safer than
silently included.

**Rejected alternative — extend `bin/halt-sprawl-test.sh` to
build `classified_json` via `_poll_classify_all` instead of raw
JSON.** End-to-end test through the classifier. Rejected because
it couples halt-sprawl tests to classifier internals — every
classifier change would force halt-sprawl test churn. The unit-level
"halt-sprawl reads `operator_action_required` correctly" is
better isolated. Classifier-level fixture coverage is
`bin/poll-slot-test.sh`'s job (D-006 covers it).

**Rejected alternative — leave existing AC-THR-EQ/GT fixtures
unchanged, rely on default-false to make them pass.** Rejected
because the items in those fixtures DO model halts in production
(operator_action_required=true), and writing the field explicitly
matches the contract. Implicit-default fixtures invite subsequent
authors to omit the flag for any new vacate item — exactly the
miscount surface D-004 closes.

### D-007: Document the contract — CLAUDE.md and a top-of-function citation

**Verdict.** Add a new subsection to CLAUDE.md adjacent to
"Failure-mode quick reference" (around CLAUDE.md's slot-accounting
discussion):

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
adversarial halt-sprawl tests
(`bin/halt-sprawl-adversarial-test.sh::AC-ADV-MISSING-FLAG`) catch
silent omissions for the alert path; the
poll-slot per-row fixtures catch silent omissions for the
classifier path.
```

And a one-line citation at the top of `_poll_classify_labels`
(directly above `bin/poll.sh:207`):

```bash
# Contract: every `slot:"vacate"` output declares operator_action_required.
# See CLAUDE.md "Slot-occupancy contract (ENG-90)" before adding new branches.
_poll_classify_labels() {
  ...
}
```

**Why two locations.** CLAUDE.md is the agent-prompt context (every
dispatched stage agent sees it). The function-level citation is the
in-code reminder for the human or agent editing `_poll_classify_labels`.
Both are necessary because the agent context (CLAUDE.md) and the
direct code-reading context (`bin/poll.sh`) are entered through
different paths during pipeline operation.

**Rejected alternative — CLAUDE.md only.** Future-author of a new
classifier branch may not have CLAUDE.md in their working set when
they edit `bin/poll.sh`. The function-level comment is the
last-mile surface that catches them.

**Rejected alternative — `bin/poll.sh` only (no CLAUDE.md
addition).** Agents dispatched into stages that touch poll.sh
(implement, qa, build) see CLAUDE.md in their base prompt. Without
the CLAUDE.md entry, the contract is invisible to those agents at
context-load time.

## 5. Architecture (where code goes)

Five files modified, no new files:

| File | Change | Lines |
|---|---|---|
| `bin/poll.sh` | (a) D-001 / D-005: add `operator_action_required` to vacate outputs at lines 211-214 (skip path), 228-230 (paused/scope), 248-256 (wait — augment existing). (b) D-002: change reviewing branch at lines 282-285. (c) D-003: simplify halted arm at lines 231-247. (d) D-004: swap halt-sprawl filter polarity at lines 360 and 388. (e) D-007: add 2-line citation comment above line 207. | net +28 (-12 / +40) |
| `bin/poll-slot-test.sh` | D-006: add 14 `AC-OAR-*` fixtures + 3 regression fixtures. Update existing `AC-WAIT-1` (line 449-474) to assert `operator_action_required:false`. Update existing AC-2 (line 246-266) and AC-3 (line 268-289) to assert `operator_action_required:true` on the halted arm. | net +250 (15 cases × ~16 lines + minor existing-fixture updates) |
| `bin/halt-sprawl-test.sh` | D-006: add `operator_action_required:true` to existing AC-THR-EQ/GT/ZERO/DEBOUNCE-* fixture rows (lines 184-189, 204-211, 242, 257-264). Add 5 new AC-THR-* fixtures (EXCLUDE-WAIT, EXCLUDE-SKIP-CODE, EXCLUDE-REVIEW-VACATE, MIXED, MIXED-OVER). | net +120 (5 cases × ~22 lines + minor field-add updates) |
| `bin/halt-sprawl-adversarial-test.sh` | D-006: add `AC-ADV-MISSING-FLAG` fixture pinning default-false behaviour. | net +20 |
| `CLAUDE.md` | D-007: add `## Slot-occupancy contract (ENG-90)` subsection adjacent to "Failure-mode quick reference". | net +30 |

No new files, no new scripts, no new dependencies. No
`AGENT_PROMPTS.md` or `.pipeline-config/config.json` changes.
`bin/verdict-handler.sh::find_fresh_verdict` is unchanged
(D-003 only changes how its output is dispositioned — the helper
itself doesn't move).

## 6. Data flow

Pre-ENG-90, classifier path for an issue at `stage:reviewing` with
`review_should_dispatch=false`:

```
_poll_classify_labels(ENG-N, ["stage:reviewing"])
  └─ has pipeline:abandoned? → no
  └─ has pipeline:paused / scope-approval? → no
  └─ has pipeline:halted? → no
  └─ fresh wait verdict? → no
  └─ has stage:reviewing? → yes
       └─ branch_name + review_should_dispatch
            └─ false → {slot:"hold", advanceable:false}     ← VIOLATION
```

The issue counts toward `held_count` (Pass 3 filters
`slot=="hold"`), wins or competes in Pass 4's sort, but Pass 4
skips it because `advanceable=false`. Pass 5 inbox-pickup gate at
line 489 sees `held_count` and may not add an inbox pick if cap
reached. Sibling work waits; review-waiting issue holds slot for
hours.

Post-ENG-90:

```
_poll_classify_labels(ENG-N, ["stage:reviewing"])
  └─ ... (same pre-checks)
  └─ has stage:reviewing? → yes
       └─ branch_name + review_should_dispatch
            └─ false → {slot:"vacate",
                        advanceable:false,
                        operator_action_required:false}  ← D-002
```

The issue does NOT count toward `held_count` (Pass 3 filters
`slot=="hold"`); freed slot is available to other holds AND inbox
(Pass 5) AND wait recallables (Pass 6). On the next tick when PR
becomes mergeable, classify re-runs `review_should_dispatch`,
returns `slot:"hold", advanceable:true`, and Pass 4 dispatches.

Pre-ENG-90, classifier path for a halt-no-marker issue:

```
_poll_classify_labels(ENG-N, ["stage:planning","pipeline:halted"])
  └─ has pipeline:abandoned? → no
  └─ has pipeline:paused / scope-approval? → no
  └─ has pipeline:halted? → yes
       └─ find_fresh_verdict → empty
       └─ → {slot:"hold", advanceable:false}              ← VIOLATION
```

Slot held forever (until operator removes label).

Post-ENG-90:

```
_poll_classify_labels(ENG-N, ["stage:planning","pipeline:halted"])
  └─ ...
  └─ has pipeline:halted? → yes
       └─ find_fresh_verdict → empty
       └─ → {slot:"vacate",
              advanceable:false,
              operator_action_required:true}              ← D-003
```

Slot vacated. Halt-sprawl filter (D-004) sees
`operator_action_required:true` → counted. Operator notices via
the threshold-cross alert (or the in-progress per-issue Linear UI
inspection) and runs `bin/pipeline.sh decide --action continue`.

Halt-sprawl flow change (D-004):

```
_poll_emit_halt_sprawl_alert(classified_json)
  ├─ count = jq filter (POST-D-004):
  │     [.[] | select(.slot == "vacate" 
  │                   and (.operator_action_required // false) == true)] | length
  ├─ if count > threshold:
  │     emit metric event {event:"halt-sprawl", outcome:"alert", count, threshold}
  │     if 24h debounce expired:
  │         top3 = jq filter (same as count, take first 3 .identifier)
  │         post Slack warning naming top3
```

The relationship between count and Slack body is preserved — same
filter, same exclusions, same items.

Three failure modes, all intentionally fail-safe:

1. **Linear-API outage in `find_fresh_verdict` during halted
   classification.** Returns empty → D-003's "no marker" path →
   `slot:vacate, operator_action_required:true`. Slot vacated for
   one tick (≤5 min); operator may briefly see the issue counted
   in halt-sprawl. On next tick, API recovers, marker is found,
   classification flips to the marker-appropriate disposition.
   Strictly better than today's "hold for one tick" outcome
   because the slot is freed.

2. **Linear-API outage in `_poll_evaluate_skip` during skip
   classification.** `git ls-remote` fails (line 104) → empty
   `current_sha` → if `prev_sha` was set, evidence-changed path
   fires (auto-resume). If neither was set, evidence-unchanged
   (skip retained). Either path returns rc=1 with the existing
   labels intact; classify emits
   `vacate, operator_action_required` based on the surviving
   skip-* label. Same as today.

3. **Classifier branch missed `operator_action_required`** (D-001
   contract violation). Default-false → halt-sprawl excludes the
   item silently. Adversarial test
   (`AC-ADV-MISSING-FLAG`) catches the omission at CI time. In
   production prior to test catching it: the silent exclusion is
   a *miss*, not an *over-count* — the alert under-counts halt
   sprawl until the test catches the omission. Acceptable
   trade-off: silently undercounting an alert is recoverable;
   silently overcounting confuses operators with phantom alerts.

## 7. Error handling

Already covered above. No new failure surfaces. Every change
preserves existing fail-safe behaviour:

- `find_fresh_verdict` failure during halted classification:
  D-003's no-marker arm fires → vacate (better than today's hold).
- `find_fresh_wait_verdict` failure during wait classification:
  unchanged (D-001 only adds the field; ENG-85's fail-closed
  pattern at `bin/verdict-handler.sh:157` is preserved).
- `_poll_evaluate_skip` returning rc=1 when neither
  skip-until-* label is present: impossible by code path —
  `_poll_evaluate_skip` returns rc=0 early when both labels are
  false (line 58-78). D-005's caller-side label re-check is
  defensive; if both checks fail, oar="false" — but this code
  path is dead by construction.
- `review_should_dispatch` propagating an unexpected exit code:
  the existing if/else binary check (line 282) interprets
  non-zero as false. D-002 preserves this — both true→hold and
  false→vacate are well-defined. There's no fall-through.

## 8. Edge cases

- **Halt label paired with `pipeline-stage-summary` or
  `pipeline-rejection` marker.** Pre-ENG-90: hold/advanceable=true,
  Pass 4 calls `verdict_handler` to transition (`bin/poll.sh:472`).
  Post-ENG-90: unchanged. The slot stays held because the
  verdict_handler invocation IS active dispatch work.

- **Halt + multiple verdict markers, the latest is `pipeline-halt`.**
  Pre-ENG-90: vacate. Post-ENG-90: vacate (case folded into
  default arm). Adds `operator_action_required:true`. Same
  observable behaviour, plus the new flag.

- **Reviewing-stage issue with `pipeline:halted` label** (race
  between an agent halt and the orchestrator's stage-reviewing
  detection). The halted arm at line 231 fires first (before line
  282's reviewing arm); the reviewing branch is unreachable. D-002
  doesn't change this. Halted arm dispositions per D-003.

- **Reviewing-stage issue with `pipeline:paused` label** (operator
  pause during review). Paused arm at line 228-230 fires first;
  reviewing branch is unreachable. D-002 doesn't change this.
  Same precedence as today, with `operator_action_required:true`
  newly attached.

- **Halt + no marker, then operator runs `decide --action
  continue`.** `bin/pipeline.sh::decide` (verified at
  `bin/pipeline.sh:174-260`) clears the halt label, removes
  skip-until-* labels, posts a transition waypoint marker. Next
  tick classify: no halt label → no halted arm → catch-all else
  → `hold, advanceable=true` → Pass 4 dispatches the
  current-stage agent. Recovery latency: one tick (≤5 min).
  Identical to today's halt-with-marker recovery.

- **Halt + unknown marker, then a fresh `pipeline-stage-summary`
  is posted by an agent that recovered from the halt.** Edge
  case: agent halted, was investigated, manually re-dispatched,
  emitted stage-summary. The latest verdict is the stage-summary;
  `find_fresh_verdict` returns it (its tie-breaker is
  `createdAt > prev`, line 114, so the latest wins). Classifier
  takes the stage-summary/rejection arm: `hold, advanceable=true`.
  Pass 4 → verdict_handler runs the transition. Halt label is
  consumed. Correct.

- **Skip-until-code-changes evidence-unchanged on a halt-paired
  issue.** `_poll_evaluate_skip` recomputes evidence; if unchanged,
  returns rc=1 → caller hits D-005's branch → emits
  `vacate, operator_action_required:false` (skip-until-code-changes
  dominates because `_poll_evaluate_skip` ran first; the halted
  arm is bypassed). On evidence change, `_poll_evaluate_skip`
  clears BOTH skip and halt labels (line 109-134) and re-emits
  refreshed labels; caller falls through to default arm
  (`hold, advanceable=true`). Both paths correct.

- **Inbox issue (no `stage:*` label) with a `pipeline:halted`
  label that an operator forgot to clear.** The inbox query at
  Pass 5 (`bin/poll.sh:489-504`) does NOT filter on
  `pipeline:halted` (it filters paused, abandoned, skip-until-*,
  and any `stage:*` label, but not halted). So an inbox issue
  with halted but no stage:* would be picked up by Pass 5 with
  `apply-stage-label` action — which would create a stage:*
  label on top of the lingering halt. Out-of-scope edge case;
  flagged as O-1 in §11. Not a regression introduced by ENG-90.

- **`max_concurrent_features = 1` (single-slot mode).** All the
  vacate/hold logic is unchanged in shape; the single-slot mode
  is not special-cased. Pass 6 wait recall + the implicit-recall
  paths (review, skip-code-unchanged) all work as today.

- **`max_concurrent_features = 0` (orchestrator effectively
  paused via cap).** Pass 4 iterates 0 holds; Pass 5 inbox
  guarded by `held_count < max_concurrent` (0 < 0 = false) →
  no pickup; Pass 6 same guard → no recall. Idle every tick.
  Same as today.

- **Operator manually applied `pipeline:halted` but the issue is
  in the inbox state with no `stage:*` label.** Falls into the
  inbox flow — see edge case above. Out-of-scope for ENG-90.

- **A vacate item with `wait_recallable:true` AND
  `operator_action_required:false`.** This is the build-wait
  contract. Post-D-001 it sets BOTH flags. Halt-sprawl excludes
  via `operator_action_required:false`; Pass 6 includes via
  `wait_recallable:true`. Independent. Correct.

- **Future stage that emits `verdict result=wait` outside of
  build.** ENG-85's `find_fresh_wait_verdict` is not
  stage-gated (`bin/verdict-handler.sh:154-191`); the wait branch
  fires for any non-halted issue with a fresh wait verdict. For
  ENG-90 the new branch sets `operator_action_required:false` for
  every wait. If a future stage adds wait + needs operator action
  (none today; speculative), it would either: (a) emit halt
  instead of wait (the existing operator-required mechanism), or
  (b) extend the contract to differentiate. Today's contract:
  wait = auto-recallable always. Documented in CLAUDE.md.

## 9. Persona review

### design — PASS

The fix introduces a single uniform metadata field
(`operator_action_required`) and threads it through three call
sites: classifier outputs, halt-sprawl filter, documentation. No
new slot enum value, no new pass, no new helper. The new field is
declared per-classifier-branch (every branch updates), which is
load-bearing — the test fixture coverage in D-006 pins every
branch and would catch a missed annotation. The polarity flip in
D-004 (exclude-by-flag → include-by-flag) is a deliberate move to
minimise the surface where a future addition can drift, with the
default-false hatch as the back-compat safety net (and an
adversarial test pinning the default's behaviour).

D-002's choice of implicit recall (no Pass 7) is justified by the
predicate location — `review_should_dispatch` runs in classify, not
in dispatch — making the per-tick re-evaluation an existing
property of the system rather than a new mechanism.

D-003's collapse of three halted sub-cases to two reduces a
case-statement arm count from 3 to 2 and removes the implicit
"unknown-marker hold" surface that the issue body specifically
flags as a violation. The race-window argument is made explicitly
and is provably equivalent or better than today's behaviour.

**Verdict: PASS, no findings.**

### security — PASS

No secret-handling surface touched. `_poll_classify_labels` and
`_poll_emit_halt_sprawl_alert` shell out to `linear.sh`,
`branch-name.sh`, and `slack.sh` — all pre-existing patterns that
ENG-85's brainstorm verified safe (passing positional args, no
`${VAR:-…}` against secret-named env vars, no shell expansion of
attacker-controlled strings). `operator_action_required` is a
boolean — JSON-encoded via `--argjson`, never embedded in argv
strings, never passed to `eval`. The new label-check in D-005
uses the exact same jq idiom already present at lines 52-55 and
121-122 (`jq -r --arg n ...` literal-arg interpolation).
**Verdict: PASS, no findings.**

### scope — PASS

Strictly within the issue's "Acceptance" surface. AC-1 maps to
D-006. AC-2 maps to D-002. AC-3 maps to D-003. AC-4 maps to D-004
+ D-006. AC-5 maps to D-002 + D-006 (the multi-variant recall
ordering reduces to "implicit recall via classify; explicit recall
via Pass 6"). AC-6 maps to D-007. The brainstorm does NOT modify
`pipeline:scope-approval-needed` semantics, does NOT change Pass
6's sort key, does NOT touch `_handle_wait` or
`external_signal_budget`, does NOT redefine the slot enum. The
issue body's explicit non-goals (`terminal` handling, marker
recognition, scope-approval/paused, K value) are all preserved.

The `bin/verdict-handler.sh` reference in §5's architecture column
shows zero net-line changes — the helper is unchanged. Only the
disposition of its output in `_poll_classify_labels` shifts.

**Verdict: PASS, no findings.**

### coherence — PASS

Brainstorm structure follows the recent ENG-85 / ENG-78 / ENG-79
pattern: Overview → Goals → Architectural principle → Decisions →
Architecture → Data flow → Error handling → Edge cases → Persona
review → Open questions → Anti-bias → Conflicts. Each decision
cites a CLAUDE.md commitment or a prior brainstorm's precedent.
Each rejected alternative names a specific cost. Decision order is
causal: D-001 establishes the contract, D-002 / D-003 / D-005
apply it to specific branches, D-004 consumes it in the alert,
D-006 pins the regressions, D-007 documents.

The audit table at §1 mirrors the issue body's table verbatim
(matching column order, matching contract verdict labels). The
classifier output table at §4 (D-001) extends it with the new
metadata column. The traceability is direct.

**Verdict: PASS, no findings.**

### product — PASS

Three operator-facing improvements:

1. Review-stage starvation eliminated. With `K=2`, a review-waiting
   issue no longer blocks the queue — sibling holds and inbox
   work dispatch.
2. Halt-no-marker / halt-unknown-marker stalls eliminated. Operator
   recovery via `decide --action continue` is the single
   documented exit ramp; today's "stuck slot" failure mode goes
   away.
3. Halt-sprawl alert is correct. Operators who relied on
   halt-sprawl as a "halts pending operator" indicator get the
   correct count post-D-004 (excluded miscounts:
   skip-until-code-changes; would-be miscounts: review-PR-pending).
   No phantom alerts, no missed real alerts.

No regression to existing flows. `pipeline:scope-approval-needed`,
`pipeline:paused`, `pipeline:abandoned`, build-wait — all keep
their current observable behaviour.

**Verdict: PASS, no findings.**

### feasibility — PASS (gating)

Codebase-fact verification: every named file:line reference cross
checked against the current worktree (see §11 Anti-bias / Assumption
Inventory). Notable verifications:

- `bin/poll.sh:207-293` — `_poll_classify_labels` definition. ✅
- `bin/poll.sh:211-214` — early-return on `_poll_evaluate_skip` rc=1. ✅
- `bin/poll.sh:48-137` — `_poll_evaluate_skip` definition. ✅
- `bin/poll.sh:92-95` — skip-until-human-acts rc=1 path. ✅
- `bin/poll.sh:109-134` — skip-until-code-changes evidence-changed (mid-tick auto-resume). ✅
- `bin/poll.sh:226-227` — abandoned arm. ✅
- `bin/poll.sh:228-230` — paused / scope-approval arm. ✅
- `bin/poll.sh:231-247` — halted arm. ✅
- `bin/poll.sh:234-235` — halted no-marker (violation). ✅
- `bin/poll.sh:240-241` — halted + stage-summary/rejection (matches contract). ✅
- `bin/poll.sh:242-243` — halted + pipeline-halt (matches contract; will gain oar field). ✅
- `bin/poll.sh:244-245` — halted + unknown marker (violation). ✅
- `bin/poll.sh:248-256` — fresh wait verdict (ENG-85). ✅
- `bin/poll.sh:257-287` — reviewing arm. ✅
- `bin/poll.sh:282-285` — reviewing-dispatch / reviewing-idle bifurcation. ✅
- `bin/poll.sh:283` — reviewing dispatch=true (hold/advanceable=true). ✅
- `bin/poll.sh:285` — reviewing dispatch=false (violation: hold/advanceable=false). ✅
- `bin/poll.sh:288-290` — catch-all else. ✅
- `bin/poll.sh:340-404` — `_poll_emit_halt_sprawl_alert`. ✅
- `bin/poll.sh:360` — count filter (line numbers exact). ✅
- `bin/poll.sh:388` — top-3 filter. ✅
- `bin/poll.sh:467-475` — Pass 4 verdict_handler invocation for halted-advanceable. ✅
- `bin/poll.sh:489-504` — inbox query (Pass 5). ✅
- `bin/poll.sh:519-537` — Pass 6 wait-recall picker. ✅
- `bin/verdict-handler.sh:84-143` — `find_fresh_verdict`. ✅
- `bin/verdict-handler.sh:154-191` — `find_fresh_wait_verdict` (post-ENG-85, in tree). ✅
- `bin/review-poll.sh:29-53` — `review_should_dispatch`. ✅
- `bin/review-poll.sh:42` — defensive dispatch on `gh pr view` failure. ✅
- `bin/poll-slot-test.sh:160-223` — `write_*_fixture` helpers. ✅
- `bin/poll-slot-test.sh:228-244` — AC-1 (advance-held-at-cap). ✅
- `bin/poll-slot-test.sh:246-266` — AC-2 (halt-for-human vacates slot — uses `verdict result=halt reason=agent-blocked` which `find_fresh_verdict` projects to `pipeline-halt`; today gives `slot=vacate`; needs `operator_action_required:true` post-D-001). ✅
- `bin/poll-slot-test.sh:268-289` — AC-3 (halt-for-verdict holds slot — uses `verdict result=pass`; today gives `slot=hold,advanceable=true`; unchanged post-ENG-90). ✅
- `bin/poll-slot-test.sh:449-474` — AC-WAIT-1 (today asserts `slot=vacate, advanceable=false, wait_recallable=true`; needs `operator_action_required:false` added post-D-001). ✅
- `bin/poll-slot-test.sh:783-862` — ENG-50 reviewing tests (today asserts `slot=hold, advanceable=true|false`; ENG-50-B at line 845-851 needs revision to `slot=vacate, operator_action_required:false` per D-002). ✅
- `bin/halt-sprawl-test.sh:184-191` — AC-THR-EQ baseline fixture (raw `[{slot:vacate}]` items; needs `operator_action_required:true` added per D-006). ✅
- `bin/halt-sprawl-test.sh:204-213` — AC-THR-GT baseline fixture (same migration). ✅
- `bin/halt-sprawl-adversarial-test.sh:128-180` — adversarial fixture style; new `AC-ADV-MISSING-FLAG` follows the same shape. ✅
- `bin/pipeline.sh:174-260` — `decide --action continue` (operator-resume contract). ✅
- `bin/run-stage.sh::_handle_wait` — unchanged; build-wait re-dispatch path is post-Pass 6. ✅
- CLAUDE.md "Failure-mode quick reference" §, "Single human-approval gate (ENG-54)" §, "Pipeline vocabulary" § — all referenced sections exist and are unchanged. ✅
- Linear issue body's audit table § — every row covered by a D-006 fixture. ✅

All facts verified. Zero P0 findings. **Verdict: PASS (gating).**

## 10. Open questions

- **O-1 (out of scope, surfaced).** Inbox issue with
  `pipeline:halted` but no `stage:*` label. The Pass 5 inbox query
  filters paused, abandoned, skip-until-*, and any `stage:*`
  label, but NOT `pipeline:halted` (`bin/poll.sh:489-504`). An
  operator-applied halt on a Todo issue would be picked up by
  Pass 5 and labelled with `stage:brainstorming`, then on the
  next tick the new halted arm fires (`vacate,
  operator_action_required:true`). Net behaviour: one tick of
  brainstorm-stage-label noise, no agent dispatch (halt label
  blocks dispatch via D-003's vacate), then halt-sprawl. Filing
  recommendation: low priority; either (a) add `pipeline:halted`
  to Pass 5's exclusion filter, or (b) document as expected
  behaviour. Out of scope for ENG-90.

- **O-2 (deferred test isolation).** `bin/halt-sprawl-test.sh`'s
  fixtures construct `classified_json` arrays directly rather than
  routing through `_poll_classify_all`. Tests for D-004 use the
  same shortcut. A future direct unit test asserting
  "`_poll_classify_labels` outputs include `operator_action_required`
  for every vacate path AND halt-sprawl picks up the right items"
  would live in a new test that gathers labels via fixtures, runs
  classify, then runs the alert. Filing recommendation:
  nice-to-have; the per-fixture coverage in D-006 is sufficient
  for CI. Aligns with O-2 in ENG-85's brainstorm.

- **O-3 (operator-visible behaviour).** The halt-sprawl alert
  count drops post-D-004 because skip-until-code-changes
  evidence-unchanged was being miscounted. An operator who sees
  the live count of "halts" decline by 1-2 after deploy may
  worry. Filing recommendation: include a one-line note in the
  release / changelog that names the miscount fix. Documentation
  only.

- **O-4 (D-002 + ENG-86 interaction).** ENG-86 (entry-conditions
  gate, in CLAUDE.md "Orchestrator entry-conditions (ENG-86)" §)
  added a pre-dispatch gate for `building` stage. ENG-90 doesn't
  touch entry-conditions, but D-002's review-vacate logic could
  in principle be implemented as a `entry_conditions[reviewing]`
  predicate. Today the predicate runs inside
  `_poll_classify_labels` directly. Filing recommendation: defer
  unification until a third stage gains entry conditions; premature
  abstraction otherwise. Consistent with ENG-86's incremental
  framing.

- **O-5 (the contract's binary cuts off three-state nuance).** The
  current contract is `operator_action_required: true | false`.
  In a future world with semi-autonomous PR check responses
  (e.g., the orchestrator can re-run a flaky check on its own),
  the field's semantics blur — "operator action required" but
  "orchestrator can take a stab first" → conflict. Filing
  recommendation: today there is no such case; if/when it
  arises, extend the field to a three-valued enum
  (`operator | auto | hybrid`). Deferred.

## 11. Anti-bias checks

### ADR stress test

There are no formal ADRs in this repo (no `docs/knowledge/decisions.md`,
verified). The closest analogues are accepted brainstorms and CLAUDE.md
commitments. Specific stress points:

- **ENG-85's brainstorm** establishes the wait-vacates pattern and
  the `wait_recallable` flag. ENG-90 generalises that flag's
  *halt-sprawl exclusion role* into `operator_action_required`,
  while preserving the *Pass 6 inclusion role* (which stays
  `wait_recallable`). **Tension: none — strict generalisation.**
  ENG-90 does NOT delete `wait_recallable`; it adds a sibling
  field. The two fields answer different questions: one for
  Pass 6 inclusion, one for halt-sprawl exclusion. ENG-85's
  framework is preserved and extended.

- **ENG-50's review-stage gating brainstorm** introduced
  `review_should_dispatch` and the `hold, advanceable=false`
  outcome at `bin/poll.sh:285`. **Tension: yes — D-002 changes
  that outcome to vacate.** ENG-50's intent was correct (don't
  dispatch when PR is not reviewable), but the slot-accounting
  consequence (held slot wastes parallelism) was not surfaced at
  the time. ENG-90 closes the consequence without changing
  ENG-50's predicate. The original `review_should_dispatch`
  function and its caller location are unchanged; only the
  classifier disposition flips. Cost: an operator who tracked
  "review-pending issues stay in held" as an informal indicator
  loses that signal — but Linear UI's `stage:reviewing` label
  is the durable indicator and is unchanged.

- **ENG-78's retry-immediately preservation** establishes that
  `_poll_evaluate_skip` must NOT delete state files where
  `policy=retry-immediately` (line 64-72). ENG-90 doesn't touch
  `_poll_evaluate_skip`'s state-file handling; D-005 only adds
  a label-check in the *caller* (`_poll_classify_labels`).
  **Tension: none.**

- **ENG-69's per-issue circuit breaker** establishes per-issue
  `.consecutive-failures` accounting separate from the global
  breaker. Halt-sprawl is the global-orchestrator-visibility surface
  for halts. **Tension: none — orthogonal accounting layers.**

- **ENG-85's `external_signal_budget` semantics shift** carries
  forward unchanged. ENG-90 doesn't touch `_handle_wait`'s
  attempts/wall-clock budgets.

- **CLAUDE.md "Sweep + scope partition (ENG-14)" §** —
  `bin/poll.sh`, `bin/poll-slot-test.sh`, `bin/halt-sprawl-test.sh`,
  `bin/halt-sprawl-adversarial-test.sh`, and `CLAUDE.md` are all
  in-scope for the implement stage by D-004 path-allowlisting. No
  tension.

### Simpler alternative

Documented under each decision (D-001 has 3 rejected, D-002 has
2 rejected, D-003 has 2 rejected, D-004 has 2 rejected, D-005
has 3 rejected, D-006 has 2 rejected, D-007 has 2 rejected).
Each rejection cites a specific cost — coupling, drift surface,
expressiveness mismatch, fixture-rename hygiene, etc.

The simplest possible alternative — *do nothing; let operators
manually break starvation by reapplying labels* — was rejected
upfront by the issue body's framing (the multi-hour starvation
observed in production) and the structural symmetry argument
(ENG-85 already established that the asymmetric handling drifted
case-by-case; refusing to extend the contract leaves the next
drift point in place).

The second-simplest alternative — *fix only review-stage
starvation (D-002), leave halt sub-cases and halt-sprawl alone*
— was considered and rejected. The Linear issue body explicitly
names all three violations (review, halt-no-marker,
halt-unknown-marker) AND the halt-sprawl miscount. Closing only
review leaves the same drift surface for the next addition.

### Assumption inventory

Every codebase fact referenced is verified against the current
worktree (see §9 feasibility checklist). Specific items with status:

| Assumption | Status |
|---|---|
| `bin/poll.sh::_poll_classify_labels` is at line 207-293 | verified at `bin/poll.sh:207-293` |
| `_poll_evaluate_skip`'s rc semantics (rc=0 include / rc=1 skip) match the docstring | verified at `bin/poll.sh:48-137` |
| `_poll_evaluate_skip` returns rc=1 from human-acts arm WITHOUT side effects on labels | verified at `bin/poll.sh:92-95` |
| `_poll_evaluate_skip` returns rc=1 from code-changes-evidence-unchanged arm | verified at `bin/poll.sh:97-136` |
| `find_fresh_verdict`'s output marker types are `pipeline-stage-summary | pipeline-rejection | pipeline-halt | unknown` | verified at `bin/verdict-handler.sh:128-141` |
| `find_fresh_verdict` deliberately excludes wait | verified at `bin/verdict-handler.sh:113` |
| `find_fresh_wait_verdict` is in tree post-ENG-85 | verified at `bin/verdict-handler.sh:154-191` |
| `review_should_dispatch` returns 0 on dispatch / 1 on idle | verified at `bin/review-poll.sh:29-53` |
| `review_should_dispatch` fails open (returns 0) on `gh pr view` query failure | verified at `bin/review-poll.sh:42` |
| The reviewing branch in `_poll_classify_labels` derives the branch via `bin/branch-name.sh` (not via Linear `gitBranchName`) | verified at `bin/poll.sh:273-275` |
| Pass 6's `wait_recallable` filter and `wait_progress_ts` sort key | verified at `bin/poll.sh:519-537` |
| Halt-sprawl filters at lines 360 and 388 use `(.wait_recallable // false) != true` | verified |
| `bin/poll-slot-test.sh::AC-WAIT-1` asserts `wait_recallable:true, wait_progress_ts:<ts>` and DOES NOT assert `operator_action_required` | verified at `bin/poll-slot-test.sh:466-470` |
| `bin/poll-slot-test.sh::AC-2` uses `verdict result=halt reason=agent-blocked` markers | verified at `bin/poll-slot-test.sh:253-256` |
| `bin/poll-slot-test.sh::ENG-50` cases at line 832-862 cover dispatch=true/false/non-reviewing | verified |
| `bin/halt-sprawl-test.sh` fixtures construct raw `[{slot:vacate}]` arrays without `operator_action_required` | verified at `bin/halt-sprawl-test.sh:184-191`, `204-211`, `242` |
| `bin/halt-sprawl-adversarial-test.sh::reset_state` and fixture-construction style match `bin/halt-sprawl-test.sh` | verified at `bin/halt-sprawl-adversarial-test.sh:1-122` |
| `bin/pipeline.sh decide --action continue` is the documented operator-resume contract | verified at `bin/pipeline.sh:174-260` and CLAUDE.md "Failure-mode quick reference" |
| The operator-resume contract clears halt label, skip-until-* labels, wait files, and posts a transition waypoint | verified at `bin/pipeline.sh:229-260` (also documented in CLAUDE.md) |
| ENG-86 entry-conditions gate is in tree but does NOT cover `reviewing` | verified at CLAUDE.md "Orchestrator entry-conditions (ENG-86)" §; only `building` is wired |
| `bin/poll.sh:248-256` (wait branch) is between halted arm (231-247) and reviewing arm (257-287) | verified |
| Pass 4 invokes `verdict_handler` for halted+advanceable issues | verified at `bin/poll.sh:467-475` |
| `bin/run-stage.sh::_handle_wait` writes `wait-${stage}.json` and emits the wait verdict marker | verified per ENG-85 brainstorm assumption inventory (no change in tree) |
| The current contract differentiates `wait_recallable=true` (Pass 6 inclusion) from `operator_action_required=true` (halt-sprawl inclusion) | NEW — established by D-001; pinned by D-006 fixtures |
| Both `_poll_classify_labels` and `_poll_emit_halt_sprawl_alert` receive `classified_json` from `_poll_classify_all` | verified at `bin/poll.sh:431-436` |
| `bin/poll.sh:431-436` shows Pass 2 → Pass 2b ordering (classify then halt-sprawl) | verified |

### Codebase-fact verification (gating)

All named files, methods, line numbers, registry values verified —
see §9 feasibility checklist. Zero unverified facts. Zero P0
findings.

## 12. Conflicts with existing architecture

**Two real interactions, both intentional, no architecture
conflicts:**

1. **D-002 changes the observable disposition of review-PR-pending
   issues from `slot:hold` to `slot:vacate`.** This affects:
   - `bin/poll.sh:441-444` (Pass 3 held aggregation): a
     review-pending issue no longer enters the held set. Pass 4's
     dispatch sort doesn't see it.
   - `bin/poll.sh:489` (Pass 5 inbox guard): held_count is
     smaller, so inbox-pickup may now dispatch in cases where
     it didn't before. This is the intended improvement.
   - `bin/poll.sh:519` (Pass 6 wait-recall guard): same — more
     slots available for wait recall.
   No regression; the cap invariant is preserved by the
   `held_count < max_concurrent` guards on Pass 5 and Pass 6.

2. **D-003 changes the observable disposition of
   halt-without-actionable-marker issues from `slot:hold` to
   `slot:vacate`.** Affects:
   - Pass 4 dispatch loop (`bin/poll.sh:467-475`): halt+no-marker
     issues are no longer in held; the `verdict_handler`
     invocation is bypassed (correct — no actionable verdict
     exists). The halted+stage-summary/rejection sub-case is
     untouched, so transition-on-halt continues to work.
   - Halt-sprawl: D-004 picks up the operator_action_required:true
     flag → these issues now contribute to the alert count
     (where pre-fix they were invisible to halt-sprawl in the
     held form). This is the intended improvement.

**Two cosmetic interactions, no behaviour change:**

3. **Existing test fixtures in `bin/halt-sprawl-test.sh` need an
   `operator_action_required:true` field added to existing
   vacate items.** D-006 covers this. No semantic shift; the
   tests pass with the new field in place AND the new D-004
   filter, vs. today's tests passing with neither.

4. **Existing test fixture `bin/poll-slot-test.sh::AC-WAIT-1` and
   `ENG-50-B` need `operator_action_required` added to the
   asserted output.** D-006 covers this. No semantic shift;
   the tests assert a strictly stronger contract post-fix.

No other conflicts identified. The brainstorm strengthens the
existing slot-classification contract by formalising it as a
single-flag annotation and threading the flag through the
halt-sprawl filter, without changing any other control-flow
surface.
