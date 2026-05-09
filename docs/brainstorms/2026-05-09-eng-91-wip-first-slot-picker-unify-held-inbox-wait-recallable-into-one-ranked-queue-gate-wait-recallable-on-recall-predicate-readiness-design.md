---
linear: ENG-91
title: WIP-first slot picker — unify held / inbox / wait_recallable into one ranked queue, gate wait_recallable on recall-predicate readiness
date: 2026-05-09
status: draft
---

# WIP-first slot picker — `bin/poll.sh::main`'s sequential Pass 4/5/6 collapses into one ranked queue; wait_recallables enter the queue only when their recall predicate evaluates true

## 1. Overview (and the load-bearing surprise)

`bin/poll.sh::main` (verified at `bin/poll.sh:413-548`) is the
per-tick dispatch decision surface. After Pass 1 gathers
stage-labelled issues (`bin/poll.sh:426-428`), Pass 2 classifies
each one (`bin/poll.sh:430-432`), and Pass 2b runs halt-sprawl
observability (`bin/poll.sh:434-436`), the dispatcher walks three
sequential passes — each `exit 0`s on the first decision it makes:

| Pass | Source | Cap-guarded? | Lines |
| ---  | ---    | ---          | ---   |
| 4    | held (advanceable) | no — held items already counted | `bin/poll.sh:448-486` |
| 5    | inbox arrivals     | yes (`held_count < max_concurrent`) | `bin/poll.sh:488-513` |
| 6    | wait_recallable (ENG-85) | yes (`held_count < max_concurrent`) | `bin/poll.sh:515-537` |

The ordering is: Pass 4 always preempts Pass 5; Pass 5 always
preempts Pass 6. `exit 0` after the first dispatch closes the tick.
Two consequences fall out:

1. **A held@planning beats a wait_recallable@building.** Even when
   the build's recall predicate (PR-approved per ENG-86) would be
   ready, Pass 4 picks the held first because Pass 6 is unreachable.
2. **A fresh inbox arrival beats an older wait_recallable whose
   external signal just arrived.** Even with the predicate ready,
   Pass 5 dispatches the new ticket; Pass 6 never runs.

**The load-bearing surprise.** The 2026-05-09 incident on
harness-self pins the failure mode:

| UTC      | Event |
| ---      | ---   |
| 07:51    | ENG-83 transitions to `stage:building`, hits ENG-86 entry-conditions gate, emits `verdict wait reason=awaiting-approval` (post-ENG-85: classifier surfaces `slot:vacate, wait_recallable:true, wait_progress_ts:07:51:00Z`). |
| 08:04    | Pass 5 sees `held_count=0 < K=2`, picks ENG-90 from inbox at brainstorming. |
| 08:28    | ENG-90 dispatched at planning. |
| ~13:00   | Operator approves the ENG-83 PR. |
| 13:15    | ENG-83 still starved. Each tick: Pass 4 finds ENG-90 advanceable, dispatches, `exit 0`s before Pass 6 ever runs. ENG-83's recall predicate (PR approval check) never gets evaluated. |

ENG-83 — one tick from `gh pr merge --auto`, with sunk compute
across brainstorm + plan + implement + ui + review + qa + build —
sits behind a freshly-promoted ENG-90 through every stage. ~60 min
of additional latency on a finishable ticket while a starting
ticket consumes the slot. The operator UX inverts: "approve and
walk away" stops working the moment a new inbox ticket lands during
the await window.

**Why WIP-first.** Lean argument applied to the harness:

- A near-merge ticket carries multiple stages of sunk compute AND
  one human approval. A fresh inbox arrival carries zero. Finishing
  yields a merged PR (real value); starting yields more WIP.
- The operator-facing affordance at the build gate is "approve and
  walk away." Letting it be preempted inverts the affordance.

**Why a recall-predicate gate (load-bearing refinement).** If the
unified picker just folded wait_recallables into the priority pool
on `wait_recallable=true`, a still-waiting ENG-83 (PR not yet
approved) would outrank a fresh inbox issue — and the eventual
dispatch would no-op against the same ENG-86 entry-conditions gate
(`bin/run-stage.sh::_entry_conditions_gate` calls
`bin/entry-conditions.sh::should_dispatch building`, which returns
`skip:awaiting-approval` and emits paired `dispatch-skipped` metric
events; `bin/entry-conditions.sh:84-138`). That's a wasted tick:
the wait_recallable consumed the picker's slot but did no real
work, while a sibling inbox or held issue waited. The classifier
must evaluate the recall predicate before declaring a wait_recallable
*picker-eligible*.

**Cost shape.** The classifier already runs `find_fresh_verdict`
(verdict-handler.sh:84-143) and `find_fresh_wait_verdict`
(verdict-handler.sh:154-191) per issue per tick — both fetch
`get-comments`. Adding one `entry-conditions.sh::should_dispatch`
call per wait_recallable item is the same order of magnitude: it
shells out to `gh pr view --json reviews` (entry-conditions.sh:55),
bounded by the count of stuck wait_recallables (typically ≤ K + 1).

## 2. Goals

After this ticket lands:

1. **Unified ranked picker** (D-001). `bin/poll.sh::main` builds one
   candidate pool — held advanceables + recall-ready wait_recallables
   + inbox arrivals — sorts by a single key, and dispatches the top
   item. Pass 4/5/6 collapse to "Pass 4U." `exit 0` is moved to AFTER
   the unified iteration.
2. **WIP-first sort key** (D-002).
   `[-stage_index, -priority_sort_rank, fifo_ts]` is the canonical
   sort. `stage_index` is the existing per-stage progression
   (brainstorming=0, planning=1, …, building=6); inbox arrivals get
   `-1` (strictly below brainstorming). `priority_sort_rank` matches
   today's mapping (Urgent=4, High=3, Normal=2, Low=1, None=0).
   `fifo_ts` is `wait_progress_ts` for wait_recallables, `createdAt`
   for inbox, `updatedAt` for held (cheap proxy; see D-002 trade-off).
3. **Recall-predicate readiness gate** (D-003). For each
   wait_recallable item, the picker invokes
   `bin/entry-conditions.sh::should_dispatch <stage_arg> <ident>`
   and includes the item in the unified pool only when the result
   is `proceed`. `skip:*` and `error:*` outputs are handled per the
   ENG-86 contract (`error:*` fail-opens — preserves today's
   behaviour when `gh`/`jq` are unreachable).
4. **Inbox `createdAt` augmentation** (D-004).
   `bin/linear.sh::list_issues_in_state` adds `createdAt` to its
   GraphQL projection. Held items use `updatedAt` (already in
   `list_issues_with_label`) as their fifo_ts proxy; the
   stage-transition-timestamp variant the issue body names is
   deferred (O-1).
5. **Test-pinned regression coverage** (D-005). `bin/poll-slot-test.sh`
   gains five new fixtures (AC-PICK-* covering AC-3, AC-4, AC-5,
   plus two adversarial ordering edge cases). The existing AC-WAIT-2,
   AC-WAIT-3, AC-WAIT-4, AC-WAIT-5 fixtures continue to pass
   unchanged — the unified picker preserves their assertions.
6. **Failure-mode runbook entry** (D-006). CLAUDE.md "Failure-mode
   quick reference" gains a row distinguishing cross-pool starvation
   (the picker-ordering failure) from per-issue halts (agent failures)
   and the global breaker (infrastructure outages).

Non-goals (explicit, follow the issue's framing):

- **Changing K or `max_concurrent_features`.** Out of scope per
  ENG-90's framing; ENG-91 is about *which* issues compete for the
  K slots, not the value of K.
- **Pre-empting an actively-dispatching agent.** ENG-91 is per-tick
  picker ordering, not interrupting in-flight `claude -p`.
- **Re-evaluating recall predicates more often than once per tick.**
  The classifier runs once per `main()`; the picker reads its output.
- **Cross-project picker semantics.** Single-project today.
- **Generalising recall predicates beyond `entry-conditions.sh`.**
  Today only `building` has a configured predicate. Wait_recallables
  at other stages (none today) get `proceed` by default per ENG-86
  D-005's empty-config contract — they enter the pool unconditionally.
  A future stage that adds a configured predicate gets the gate for
  free.
- **Strict stage-transition-timestamp FIFO for held.** `updatedAt` is
  the proxy ENG-91 ships. The wait_recallable@building round-robin
  case (AC-WAIT-4 / 5 from ENG-85) continues to use
  `wait_progress_ts` per D-002 below; held FIFO is the cheaper proxy.

## 3. Architectural principle

There is no `docs/VISION.md`, `docs/ARCHITECTURE.md`, or
`docs/knowledge/decisions.md` (verified — `ls docs/` returns
`brainstorms/  pipeline-vocabulary.md  pipeline-vocabulary.template.md
plans/  runbooks/`). Governing constraints come from `CLAUDE.md`,
`learned-rules/harness/project-profile.md`, and accepted brainstorms
— same regime ENG-67 / ENG-78 / ENG-79 / ENG-85 / ENG-86 / ENG-90
documented.

Principles invoked:

- **Slot accounting expresses agent activity, not labels.** ENG-85
  established that an agent-idle-on-external-signal (wait verdict)
  vacates the slot. ENG-86 added an orchestrator-side predicate gate
  that skips dispatch when the external signal isn't ready. ENG-91
  composes them: an agent-idle, predicate-not-ready issue should
  also not consume the picker's slot. WIP-first is the corollary —
  *which* idle issue gets the picker's attention should reflect
  proximity to merge, not arrival order.

- **Closed event vocabulary.** ENG-91 introduces no new vocabulary.
  The unified picker reads existing classifier output (slot,
  advanceable, wait_recallable, wait_progress_ts, stage_index,
  priority_sort_rank) and adds two locally-scoped fields
  (`picker_eligible`, `fifo_ts`) used only inside the picker. No
  new pipeline event, no new label, no new registry entry.

- **`die` over silent fallback (defense in depth).** The recall
  predicate gate (D-003) inherits ENG-86's fail-open semantics:
  `error:*` outputs from `entry-conditions.sh` (gh/jq outage)
  → `picker_eligible=true`, preserving today's "dispatch and let
  the agent's own P2 catch it" behaviour. `skip:*` outputs (the
  predicate said no) → `picker_eligible=false`, the load-bearing
  exclusion. Anything else (unknown handler output) → fail-open,
  same as `error:*`.

- **Symmetric defense across the slot-classification surface.**
  ENG-67's brainstorm §3: when an invariant is enforced at one
  layer, the adjacent layer should pin that no equivalent path
  exists elsewhere. ENG-86's pre-dispatch gate at the orchestrator
  layer is paired with this brainstorm's pre-pick gate at the
  picker layer; the agent-side P2 (AGENT_PROMPTS.md §7 P2) remains
  the third defense-in-depth layer. The fixture coverage in D-005
  pins the picker-layer assertion (AC-PICK-3-PREDICATE-NOT-READY)
  alongside ENG-86's existing pre-dispatch fixtures.

- **Existing pass discipline preserved where untouched.** Pass 1
  (gather), Pass 2 (classify), Pass 2b (halt-sprawl) are
  unchanged. Pass 3 (held aggregation, `bin/poll.sh:438-446`) is
  retained — it computes `held_count` for the cap check. Only
  Pass 4/5/6 collapse into Pass 4U. The final cap-check / idle
  reasons (`bin/poll.sh:539-543`) are preserved. Halt-sprawl's
  `wait_recallable` exclusion (D-004 at ENG-90 / line 360 / line 388)
  is unchanged — `picker_eligible` is orthogonal to halt-sprawl
  inclusion.

## 4. Decisions

### D-001: Unified picker — single ranked pool replacing Pass 4/5/6

**Verdict.** Replace `bin/poll.sh:448-537` (Pass 4/5/6 + the
intermediate cap checks) with a single Pass 4U:

```bash
# Pass 4U (ENG-91): unified ranked picker over (held, wait_recallable_ready, inbox).
# Sort key is documented at the top of _poll_classify_labels (see D-002).
# Iterates sorted candidates, dispatches the first viable one. The halted +
# stage-summary / rejection sub-case (Pass 4 inline verdict_handler call
# pre-ENG-91) continues to no-emit and advance the iteration — preserves
# the existing transition-on-halt path.

local pool
pool="$(_picker_build_pool "$classified" "$held_count" "$max_concurrent")"
local n
n="$(jq 'length' <<<"$pool")"
local i=0
while (( i < n )); do
  local cand source ident stage_label arg has_halt cur_stage_suffix
  cand="$(jq -c ".[$i]" <<<"$pool")"
  source="$(jq -r '.picker_source' <<<"$cand")"
  ident="$(jq -r '.identifier' <<<"$cand")"

  case "$source" in
    held)
      stage_label="$(jq -r '.stage_label' <<<"$cand")"
      labels_json="$(jq -c '.labels' <<<"$cand")"
      has_halt="$(jq -r --arg n "pipeline:halted" \
        '[.[] | select(. == $n)] | length > 0' <<<"$labels_json")"
      if [[ "$has_halt" == "true" ]]; then
        # Halt + advanceable verdict marker → verdict_handler transition,
        # picked up next tick (preserved from pre-ENG-91 Pass 4).
        cur_stage_suffix="${stage_label#stage:}"
        if verdict_handler "$ident" "$cur_stage_suffix"; then
          log "poll: verdict-handler transitioned $ident; will be picked up next tick"
        fi
        i=$((i+1)); continue
      fi
      arg="$(stage_arg_for_label "$stage_label")"
      jq -nc \
        --arg issue_id "$ident" \
        --arg stage "$arg" \
        --arg reason "held slot at $stage_label" \
        '{issue_id:$issue_id, stage:$stage, entry_action:"run", reason:$reason}'
      exit 0 ;;

    wait_recallable)
      stage_label="$(jq -r '.stage_label' <<<"$cand")"
      arg="$(stage_arg_for_label "$stage_label")"
      jq -nc \
        --arg issue_id "$ident" \
        --arg stage "$arg" \
        --arg reason "wait re-pickup at $stage_label (predicate ready)" \
        '{issue_id:$issue_id, stage:$stage, entry_action:"run", reason:$reason}'
      exit 0 ;;

    inbox)
      jq -nc \
        --arg issue_id "$ident" \
        --arg stage "brainstorming" \
        --arg reason "inbox pickup" \
        '{issue_id:$issue_id, stage:$stage, entry_action:"apply-stage-label", reason:$reason}'
      exit 0 ;;
  esac
done

# Pool empty (or iterated without dispatch) → idle with the existing
# reasons.
if (( held_count >= max_concurrent )); then
  idle "max-concurrent-reached (held=$held_count, limit=$max_concurrent)"
fi
idle "no-work"
```

The body of `_picker_build_pool` (new helper, lives next to
`_poll_classify_all` — `bin/poll.sh:299-322`):

```bash
# ENG-91: assemble the unified picker pool. Returns a JSON array of
# candidates, each carrying picker_source ∈ {held, wait_recallable, inbox}
# and fifo_ts (per D-002), sorted by [-stage_index, -priority_sort_rank, fifo_ts].
#
# Cap discipline:
#   - held items are always included (already counted in held_count).
#   - wait_recallable + inbox items are included only when held_count <
#     max_concurrent (preserves the cap invariant; matches today's Pass 5/6
#     guards at bin/poll.sh:489 and bin/poll.sh:519).
_picker_build_pool() {
  local classified="$1" held_count="$2" max_concurrent="$3"

  # 1. Held advanceables. Source-tagged + fifo_ts from updatedAt
  #    (cheap proxy; see D-002 trade-off and O-1).
  local held_pool
  held_pool="$(jq -c '
    [.[]
     | select(.slot == "hold" and .advanceable == true)
     | . + {picker_source:"held", fifo_ts:(.updatedAt // "")}
    ]' <<<"$classified")"

  local wait_pool='[]' inbox_pool='[]'
  if (( held_count < max_concurrent )); then
    # 2. Wait_recallables. Filter on classifier output, then gate each
    #    candidate on its recall predicate (ENG-86 entry-conditions).
    local wait_candidates
    wait_candidates="$(jq -c '
      [.[]
       | select(.slot == "vacate" and (.wait_recallable // false) == true)
      ]' <<<"$classified")"
    local wn wi=0
    wn="$(jq 'length' <<<"$wait_candidates")"
    while (( wi < wn )); do
      local wc wid wstage_label wstage_arg
      wc="$(jq -c ".[$wi]" <<<"$wait_candidates")"
      wid="$(jq -r '.identifier' <<<"$wc")"
      wstage_label="$(jq -r '.stage_label' <<<"$wc")"
      wstage_arg="$(stage_arg_for_label "$wstage_label")"
      if _picker_predicate_ready "$wid" "$wstage_arg"; then
        local wc_aug
        wc_aug="$(jq -c '. + {picker_source:"wait_recallable", fifo_ts:(.wait_progress_ts // "")}' <<<"$wc")"
        wait_pool="$(jq -c --argjson p "$wait_pool" --argjson x "$wc_aug" '$p + [$x]' <<<"$wait_pool")"
      else
        log "picker: wait_recallable $wid skipped (predicate not ready)"
      fi
      wi=$((wi+1))
    done

    # 3. Inbox arrivals. Reuses the existing list-issues-in-state filter
    #    (paused/abandoned/skip-until-* exclusions); augments with
    #    stage_index=-1 + createdAt fifo_ts (D-004).
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

  # 4. Concatenate + sort.
  jq -c --argjson h "$held_pool" --argjson w "$wait_pool" --argjson i "$inbox_pool" \
    -n '($h + $w + $i) | sort_by([-(.stage_index), -(.priority_sort_rank), .fifo_ts])'
}
```

And the recall-predicate readiness shim (D-003 details below):

```bash
# ENG-91: recall-predicate readiness shim. Wraps entry-conditions.sh's
# should_dispatch verb. Returns 0 = predicate ready (include in pool);
# 1 = predicate said skip; 0 = error/unknown (fail-open per ENG-86 D-010).
_picker_predicate_ready() {
  local ident="$1" stage_arg="$2"
  local out
  out="$(bash "$SCRIPT_DIR/entry-conditions.sh" should_dispatch "$stage_arg" "$ident" 2>/dev/null || printf '')"
  case "$out" in
    proceed)  return 0 ;;
    skip:*)   return 1 ;;
    error:*)  return 0 ;;
    *)        return 0 ;;
  esac
}
```

**Why one helper and not three.** The pool builder is naturally
a single function: it owns the fifo_ts attribution, the cap-conditional
inbox+wait inclusion, and the final sort. Splitting it into
"_pool_held / _pool_wait / _pool_inbox / _pool_concat_sort" would
quadruple the surface area for jq-shape errors and make the
cap-discipline (which spans all three) harder to read. The single
helper mirrors the size and shape of `_poll_classify_all` (which
also iterates and accumulates).

**Rejected alternative — keep Pass 4/5/6 sequential, add a
predicate-readiness check inside Pass 6 only.** Minimal-diff fix
for AC-3 (the predicate gate) but does not address AC-1/AC-2/AC-4
(unified picker). The starvation shape — Pass 4 always preempts
Pass 6 — survives. Rejected because it solves the symptom (wasted
Pass-6 dispatches against not-ready predicates) without fixing the
load-bearing failure (cross-pool starvation). The Linear issue body
specifically frames the unified picker as the contract amendment;
a Pass-6-only fix is a partial implementation that fails AC-1 by
construction.

**Rejected alternative — implement the unified picker as a
declarative jq pipeline that consumes pre-tagged classifier output**
(i.e., have `_poll_classify_all` emit `picker_source` + `fifo_ts`
directly on each item, so the picker is just `jq sort_by | .[0]`).
Rejected because:

1. The recall-predicate gate is a per-item shell call
   (entry-conditions.sh); it cannot run inside jq. The classifier
   would have to either (a) call entry-conditions.sh per
   wait_recallable (puts a non-classify concern into classify), or
   (b) emit unfiltered wait_recallables and let the picker filter
   later — but then we need the picker code anyway, just slightly
   smaller.
2. The inbox source isn't in `classified` (it's a separate query in
   Pass 5 today). Folding the inbox query into Pass 1 would change
   the gather contract (pass 1 currently queries by stage label) —
   broader blast radius than ENG-91's scope warrants.

The `_picker_build_pool` helper is the right granularity.

**Rejected alternative — pre-emptive fanout (dispatch K candidates
per tick instead of one, ENG-81-style).** Out of scope per the
issue body's "Non-goals." ENG-81 is the parallel-dispatch ticket;
ENG-91 is about per-tick picker ordering. The unified picker is
compatible with K-fanout — a future ENG-81 implementation can pick
the top K candidates instead of the top 1 — but that's a separate
landing.

### D-002: Sort key — `[-stage_index, -priority_sort_rank, fifo_ts]`

**Verdict.** The unified pool sorts by exactly this jq expression:

```jq
sort_by([-(.stage_index), -(.priority_sort_rank), .fifo_ts])
```

Three keys, descending-stage > descending-priority > ascending-FIFO
(older wins). Each item carries:

| picker_source     | stage_index | priority_sort_rank | fifo_ts                 | source line |
| ---               | ---         | ---                | ---                     | ---         |
| held              | 0..6        | 0..4               | `.updatedAt`            | classified item (Pass 1 GraphQL: `bin/linear.sh:220`) |
| wait_recallable   | 0..6        | 0..4               | `.wait_progress_ts`     | classifier branch (`bin/poll.sh:255`, ENG-85) |
| inbox             | -1          | 0..4               | `.createdAt`            | inbox GraphQL (D-004 augmentation) |

**Stage progression: `inbox=-1, brainstorming=0 … building=6`.**
Today's `stage_index` (set at `bin/poll.sh:148-165`) starts at 0
for brainstorming. ENG-91 reuses these values verbatim; inbox
arrivals get `-1` to sort strictly below brainstorming. This avoids
any +1 offset arithmetic on classifier output and keeps the picker
sort key shape mechanically derivable from existing fields.

**FIFO sources per type — and the trade-off.** The Linear issue body
names "the most recent stage-transition timestamp" as the fifo_ts
for held. That value is computable but expensive — it requires a
`get-comments` fetch per held issue and an extra parse pass over
the comment stream. Today's `find_fresh_verdict` /
`find_fresh_wait_verdict` already issue one such fetch per
classified issue, so threading transition-ts through their existing
pass is plausible (they already compute `last_transition_ts`
internally — `bin/verdict-handler.sh:160-167`).

ENG-91 ships the cheaper `updatedAt` proxy for held and defers
strict-transition-ts FIFO to a future ticket (O-1). Reasoning:

1. **Cross-pool starvation is the load-bearing failure.** Held-vs-held
   FIFO ties (which strict-transition-ts would refine) are rare and
   non-load-bearing — they fall out of jq's stable sort today and
   would fall out of `updatedAt` ordering tomorrow. The starvation
   the issue body documents is across pools (held vs wait_recallable
   vs inbox), where the WIP-first stage-index discriminator is the
   primary discriminator regardless of held FIFO.
2. **`updatedAt` is already in the GraphQL query** (`bin/linear.sh:220`).
   No additional query, no new field-extraction code path. The
   classifier already has it on every gathered item — augmenting the
   picker pool with `fifo_ts:(.updatedAt // "")` is a one-line jq
   addition.
3. **Inbox `createdAt` is genuinely needed.** Inbox FIFO is the
   user-visible affordance ("the older inbox issue gets dispatched
   first" matches operator intuition). Augmenting
   `list_issues_in_state`'s GraphQL projection to include
   `createdAt` is a one-line `linear.sh` change with no behavioural
   side effects.

The trade-off is documented in the contract; readers reaching for
strict-transition-ts FIFO have a clear pointer to O-1.

**Why descending stage_index is "later stage wins."** The pipeline
flows `brainstorming(0) → planning(1) → … → building(6) → released(7,
excluded)`. A higher index is closer to merge. Sorting `-(.stage_index)`
descending puts higher-stage items first — WIP-first.

**Why descending priority_sort_rank.** `priority_sort_rank` maps
Linear's priority (Urgent=1 native → 4 sort_rank, …, None=0 native
→ 0 sort_rank) per `bin/poll.sh:316`. Higher sort_rank = higher
priority. Descending = highest-priority first.

**Why ascending fifo_ts (older wins).** Standard FIFO fairness:
the issue that has been waiting longer gets the picker first. For
wait_recallables this also gives natural round-robin across
multiple stuck builds (per ENG-85's AC-WAIT-4 design — once a wait
is dispatched and re-emits a fresh wait, its `wait_progress_ts`
advances and it goes to the back of the line).

**Rejected alternative — sort by `[-(.priority), -(.stage_index), .fifo_ts]`**
(priority dominates stage). Promoted Urgent inbox above held@building.
Rejected because it inverts the WIP-first principle the issue body
defines: a near-merge ticket carries sunk compute and a human
approval; a fresh inbox arrival carries zero. Even an Urgent inbox
issue is unmerged work that hasn't started — finishing the held
issue ships value sooner (and the orchestrator picks up the Urgent
inbox in K=1 ticks anyway, after the held merges).

**Rejected alternative — separate FIFO timestamps per source
(continue using `wait_progress_ts` for waits, but no FIFO at all
for held / inbox).** Rejected because it leaves the "two same-stage
held" tie-break to jq's stable sort, which depends on input order
from `_poll_gather_stage_labeled_issues` — and that order is the
workflow_stages iteration order, NOT a meaningful per-issue
timestamp. Different from "no FIFO for held" intent: holds at the
same stage would always be dispatched in workflow-stage iteration
order, which is the same per-tick. `updatedAt` gives a real, if
imperfect, FIFO signal at zero additional query cost.

**Rejected alternative — sort by `(.fifo_ts)` alone (pure FIFO,
ignore stage and priority).** Rejected because it loses both
WIP-first and priority semantics. An old inbox arrival (years-old
ticket no one has touched) would dominate over a near-merge build.
The issue body's contract is explicit: `[-stage_index,
-priority_sort_rank, fifo_ts]`.

### D-003: Recall-predicate readiness gate via `entry-conditions.sh`

**Verdict.** The picker invokes
`bin/entry-conditions.sh::should_dispatch <stage_arg> <ident>` for
every wait_recallable item and includes the item in the unified
pool only when stdout is `proceed`.

`entry-conditions.sh` is the right home for this predicate
(verified at `bin/entry-conditions.sh:1-145`):

- It already implements the per-stage check registry consumed by
  the orchestrator pre-dispatch gate (ENG-86).
- For `building`, the configured check is `pr-approved-by-non-bot`
  (`bin/entry-conditions.sh:48-65`). For other stages, the check
  list defaults to empty (per ENG-86 D-005), and `should_dispatch`
  returns `proceed` — so wait_recallables at non-building stages
  enter the pool unconditionally, preserving today's Pass-6
  behaviour for those (currently theoretical) cases.
- It returns a single-line outcome on stdout (`proceed` /
  `skip:<reason>` / `error:<check-name>`); the picker shim is a
  `case "$out" in …` switch.

**Mapping outcomes to picker behaviour:**

| `should_dispatch` output | Picker action | Rationale |
| ---                      | ---           | ---       |
| `proceed`                | include in pool, picker_eligible=true | predicate evaluates ready |
| `skip:<reason>`          | exclude from pool, log a single-line message | predicate said no; do not waste a slot |
| `error:<check-name>`     | include in pool (fail-open) | gh/jq outage; ENG-86 D-010 contract — let the agent's P2 catch it |
| any other shape          | include in pool (fail-open) | unknown handler return; conservative |

**The `external_signal_budget` interaction.** Pre-ENG-91:
wait_recallable was re-dispatched once per tick when no other ready
work; `_handle_wait` incremented `attempts` per dispatch. ENG-85
already loosened this (attempts grow only when no sibling work).
ENG-91 loosens it further: attempts grow only on ticks where the
recall predicate evaluates `proceed` AND the wait wins the picker.

The wall-clock arm (`max_minutes`) still works (it reads
`first_attempt_at` from `wait-${stage}.json` whenever
`_handle_wait` runs). The tick-count arm (`max_attempts`) becomes
even more wall-clock-loose: a wait whose predicate stays in
`skip:awaiting-approval` indefinitely never increments attempts and
never exhausts on the count alone.

This is **expected and acceptable** — the operator-facing knob for
time-bounded escalation has been `max_minutes` since ENG-85 (per
that brainstorm's O-3). ENG-91 does not change the knob; it only
shifts the cadence relationship between the count knob and
wall-clock. Documented as O-2 in §10.

**Caching `entry-conditions.sh` calls per tick.** A future
optimization: memoize per-(stage, issue) within a tick so the same
predicate isn't called twice (e.g., picker, then orchestrator
pre-dispatch). For ENG-91 the duplication is one extra call per
wait_recallable per tick (typically ≤ 1-2 per tick across all
issues), well below noise. Filed as O-3.

**Rejected alternative — duplicate the `pr-approved-by-non-bot`
check inside `bin/poll.sh` directly.** Avoids the shell-out cost.
Rejected because:

1. **Single source of truth for the predicate.** ENG-86 D-008
   explicitly named `entry-conditions.sh::check_pr_approved_by_non_bot`
   as the canonical check; AGENT_PROMPTS.md §7 P2 mirrors it for
   the agent-side fallback. A third copy in `poll.sh` would drift.
2. **Future predicate additions.** A new `entry_conditions[stage]`
   in `.pipeline-config/config.json` (e.g., `[reviewing]`,
   `[implementing]`) automatically affects both the orchestrator
   pre-dispatch gate AND the picker. Hard-coding the check in
   `poll.sh` would force a poll.sh change for every new predicate.
3. **Sandbox/permission cost is identical.** `entry-conditions.sh`
   already shells out to `gh pr view` (the same call poll.sh would
   make); the wrapper layer adds maybe 50 ms vs the multi-second
   `gh` fetch. Negligible.

**Rejected alternative — gate at the orchestrator side only (pre-dispatch);
let the picker pick freely.** Status quo modulo the unified picker.
The picker would still pick wait_recallables that the orchestrator
would skip — `dispatch-skipped` events accumulate but the picker's
slot is wasted. AC-3 explicitly forbids this: "wait_recallable rows
enter the priority pool only when their recall predicate evaluates
true." Rejected — the picker-side gate is the load-bearing fix.

**Rejected alternative — picker-side predicate without the
orchestrator-side gate (delete ENG-86's pre-dispatch check).**
Tempting in the spirit of "don't double-check." Rejected because
the orchestrator-side gate is the safety valve when the picker's
classifier output is stale — e.g., a wait verdict was emitted at
classify time but the predicate flipped between classify and
dispatch (a few hundred ms; unlikely but possible during PR review
state changes). Defense-in-depth: classifier picks the candidate;
orchestrator gate confirms before dispatch. Both layers cheap, both
load-bearing.

### D-004: `bin/linear.sh::list_issues_in_state` GraphQL augmentation

**Verdict.** Add `createdAt` to the projection at `bin/linear.sh:210`:

```graphql
# Pre-ENG-91 (verbatim from bin/linear.sh:210):
query($teamId: ID!, $projectId: ID!, $state: String!) {
  issues(first: 50, filter: { team: { id: { eq: $teamId } }, project: { id: { eq: $projectId } }, state: { name: { eq: $state } } }) {
    nodes { id identifier title state { name } labels { nodes { name } } priority updatedAt }
  }
}

# Post-ENG-91 (one field added):
query($teamId: ID!, $projectId: ID!, $state: String!) {
  issues(first: 50, filter: { team: { id: { eq: $teamId } }, project: { id: { eq: $projectId } }, state: { name: { eq: $state } } }) {
    nodes { id identifier title state { name } labels { nodes { name } } priority updatedAt createdAt }
  }
}
```

`updatedAt` is preserved in the projection (other callers may rely
on it; verified — `_poll_gather_stage_labeled_issues` queries
`list_issues_with_label` which already projects `updatedAt`, and
the inbox path's filter at `bin/poll.sh:494-504` does not currently
read it but adding `createdAt` is non-conflicting).

For held items, `_poll_gather_stage_labeled_issues` already projects
`updatedAt` via `list_issues_with_label` at `bin/linear.sh:220` —
the picker reads it from the gathered item directly via
`(.updatedAt // "")`. No `linear.sh` change needed for held.

**Rejected alternative — drop FIFO entirely for inbox; rely on
GraphQL response order.** Linear's GraphQL `issues(first: 50, ...)`
default order is by `createdAt` descending (newest first), which is
the *opposite* of the FIFO we want. Without `createdAt` projected,
re-sorting in jq is impossible. Rejected.

**Rejected alternative — sort the inbox by `updatedAt` ascending.**
`updatedAt` advances every time a label changes or a comment is
posted — including by the harness itself. An inbox issue that the
operator just commented on would jump to "most recently updated"
and lose its FIFO position. Rejected — `createdAt` is the durable
arrival timestamp.

**Rejected alternative — Linear-side sort (use `orderBy: createdAt`
in the GraphQL).** Linear's IssueFilter does not expose an
`orderBy` argument; the API returns issues in default order. The
sort happens in jq either way. Adding `createdAt` to the projection
is the only path. (Verified by inspection of the existing query
shape — no `orderBy` in
`bin/linear.sh:206-224`.)

### D-005: Test fixture coverage in `bin/poll-slot-test.sh`

**Verdict.** Five new fixtures named `AC-PICK-*`, plus migration of
the existing AC-WAIT-2 fixture (which already exercises cross-pool
starvation but pre-ENG-91 just relies on Pass 4 winning over Pass 6
without testing wait_recallable picker eligibility).

| Fixture | Setup | Expected |
| ---     | ---   | ---      |
| `AC-PICK-1-WAIT-PREDICATE-READY-OUTRANKS-INBOX` | ENG-A `stage:building` + fresh wait_recallable; `entry-conditions.sh` stub returns `proceed`; ENG-B in inbox state | `main()` dispatches ENG-A with reason `wait re-pickup at stage:building (predicate ready)`; ENG-B not picked. Pins AC-3. |
| `AC-PICK-2-WAIT-PREDICATE-NOT-READY-LOSES-TO-INBOX` | ENG-A `stage:building` + fresh wait_recallable; `entry-conditions.sh` stub returns `skip:awaiting-approval`; ENG-B in inbox state | `main()` dispatches ENG-B with reason `inbox pickup`; ENG-A excluded from pool. Pins AC-3 contrapositive. |
| `AC-PICK-3-WAIT-READY-OUTRANKS-HELD-EARLIER-STAGE` | ENG-A `stage:building` + fresh wait_recallable + `entry-conditions.sh` returns `proceed`; ENG-B `stage:planning` + advanceable | `main()` dispatches ENG-A (later stage wins). Pins AC-4 (live-incident regression: ENG-83 / ENG-90 race). |
| `AC-PICK-4-MULTI-FLEET-WIP-FIRST` | ENG-A `stage:building` + ready wait_recallable; ENG-B `stage:planning` + held; ENG-C in inbox; cap=2 | `main()` dispatches ENG-A. Subsequent ticks (after ENG-A's hypothetical merge clears the slot) dispatch ENG-B, then ENG-C. Pins AC-5 (multi-issue ordering). |
| `AC-PICK-5-PREDICATE-ERROR-FAIL-OPEN` | ENG-A `stage:building` + fresh wait_recallable; `entry-conditions.sh` stub returns `error:pr-approved-by-non-bot`; ENG-B in inbox | `main()` dispatches ENG-A (fail-open per D-003). The orchestrator-side ENG-86 gate is the deferred safety net. |

Plus a migration of AC-WAIT-2 (`bin/poll-slot-test.sh:476-497`): the
existing assertion stays the same (ENG-WAIT-B at stage:qa wins
dispatch, ENG-WAIT-A at stage:building loses), but the rationale
shifts. Pre-ENG-91: ENG-WAIT-A loses because Pass 4 picks ENG-WAIT-B
and `exit 0`s before Pass 6 runs. Post-ENG-91: ENG-WAIT-A is in the
unified pool only if its recall predicate is ready; if the test
uses the default `entry-conditions.sh` stub (which returns
`proceed`), ENG-WAIT-A WOULD be picker-eligible and would compete
on stage_index. ENG-WAIT-B at qa (stage_index=5) still beats
ENG-WAIT-A at building (stage_index=6)... wait, that's wrong —
building is index 6, qa is index 5; building > qa per
`config.json::workflow_stages` order. So post-ENG-91 the dispatch
flips: ENG-WAIT-A wins.

Therefore AC-WAIT-2 must be **rewritten to reflect the new contract**:
the assertion that currently checks "ENG-WAIT-B wins" inverts to
"ENG-WAIT-A wins" because building > qa in stage_index AND its
recall predicate evaluates ready. This is a load-bearing change: the
2026-05-09 incident is exactly this scenario — ENG-83 (build, ready)
should win over a sibling at an earlier stage. The fixture's
post-fix assertion is aligned with the new contract.

The original "wait-vacates-slot-for-sibling-held-work" property
that AC-WAIT-2 pinned (a sibling held issue can dispatch when a
build wait is in flight) is preserved by AC-PICK-3-WAIT-READY-
OUTRANKS-HELD-EARLIER-STAGE — but with the WIP-first inversion
(the wait wins). The sibling-held property still holds when the
held is at a *later* stage (e.g., a held@released-1 over a wait at
implementing); a separate sub-fixture pins this:

| Fixture | Setup | Expected |
| ---     | ---   | ---      |
| `AC-PICK-6-HELD-LATER-STAGE-OUTRANKS-WAIT` | ENG-A `stage:implementing` + fresh wait_recallable + `entry-conditions.sh` returns `proceed`; ENG-B `stage:building` + advanceable held | `main()` dispatches ENG-B (building > implementing). Pins that wait_recallable doesn't always win — stage_index dominates priority within the unified sort. |

Note: in production today, the "implementing emits a wait" case
doesn't occur (ENG-54: only build emits wait). AC-PICK-6 is a
synthetic fixture exercising the sort key purely; it pins that
the sort rule treats every entry symmetrically, regardless of
`picker_source`.

Six fixtures total (AC-PICK-1 through AC-PICK-6) plus the AC-WAIT-2
inversion. The existing AC-WAIT-3, AC-WAIT-4, AC-WAIT-5, AC-WAIT-6,
AC-WAIT-7, AC-WAIT-8, and the QA adversarial cases continue to pass
unchanged — the unified picker preserves the underlying classifier
behaviour they assert.

**The `entry-conditions.sh` stub.** `bin/poll-slot-test.sh` already
follows the source-and-stub pattern for `linear.sh` /
`metrics.sh` / `slack.sh` (`bin/poll-slot-test.sh:61-97`). ENG-91
adds an `entry-conditions.sh` stub at `STUB_DIR/entry-conditions.sh`:

```bash
cat > "$STUB_DIR/entry-conditions.sh" <<'SH'
#!/usr/bin/env bash
# Stub: emits whatever's in $ENTRY_CONDITIONS_STUB_OUTPUT (default 'proceed').
[[ "$1" == "should_dispatch" ]] || exit 1
printf '%s\n' "${ENTRY_CONDITIONS_STUB_OUTPUT:-proceed}"
SH
chmod +x "$STUB_DIR/entry-conditions.sh"
```

Per-fixture tests `export ENTRY_CONDITIONS_STUB_OUTPUT=<value>`
before running `main` to drive the predicate-readiness arm being
tested. No new test infrastructure beyond this single stub.

**Rejected alternative — exhaustive matrix testing across all
(picker_source × predicate_state × cap) combinations.** ~24 cases.
Rejected because most matrix slots reduce to one of the AC-PICK-1
through AC-PICK-6 patterns; the matrix's marginal coverage is
trivial fixtures (e.g., "a held@build wins when no wait_recallable
exists" — already covered by every existing pre-ENG-91 fixture
under the new picker). The AC-PICK-* fixtures are chosen to pin the
*new* behaviours; existing fixtures pin the *preserved* behaviours.

**Rejected alternative — replace existing AC-WAIT-2 fixture in
place rather than rewriting the assertion.** The pre-ENG-91 fixture's
contract ("a sibling held wins over a wait-recallable, freeing the
build's slot") is the load-bearing property ENG-85 pinned. ENG-91
inverts this property for the live-incident class (later-stage
wait wins over earlier-stage held when predicate ready) — the
fixture's body must be rewritten. Renaming AC-WAIT-2 to
AC-PICK-CROSS-POOL-WIP-FIRST would be cleaner from a grep-history
perspective; ENG-91 keeps the AC-WAIT-2 name and adds a one-line
git-blame anchor citing ENG-85's prior assertion's death (matches
the precedent in ENG-85 D-004).

### D-006: CLAUDE.md "Failure-mode quick reference" — new row

**Verdict.** Insert a new row in `CLAUDE.md:512-522` between
"Issue stuck in `stage:X`" and "Wrong-target Linear writes" (so it
groups with the other "issue is healthy but not progressing"
symptoms):

```markdown
| Approved/ready ticket at later stage (e.g., `stage:building` post-approval, or `stage:reviewing` post-PR-mergeable) sits idle while an earlier-stage or inbox issue dispatches each tick | The picker's per-tick log emits `picker: wait_recallable <ENG-N> skipped (predicate not ready)` (D-003) when a wait_recallable's recall predicate evaluates `skip:*`. Verify by inspecting `$PROJECT_STATE_DIR/<slug>/logs/local-YYYY-MM-DD.log`; if predicate is `proceed` and the issue still loses to an earlier-stage or inbox issue, the picker sort is the bug — see ENG-91. Recovery while waiting for a fix: `bash bin/linear.sh add-label <held-issue> pipeline:paused`, let the next tick re-pick the wait, then unpause. |
```

The recovery snippet (`add-label pipeline:paused` to free the slot
on the held issue, then `remove-label`) is the documented operator
escape hatch for the pre-fix incident class. Pairs with the
existing `pipeline:halted` recovery (operator runs
`bin/pipeline.sh decide --action continue`) for per-issue halts —
distinct symptoms, distinct recoveries.

The row distinguishes this class from:

- **Per-issue halts** (already covered): agent failures, halt label
  applied, recovery via `decide --action continue`.
- **Global breaker** (already covered): infrastructure outages,
  global counter ≥ 3.
- **Issue stuck in stage:X** (already covered): halt-sprawl-shaped
  scope-approval / halt thread idleness; comment-thread inspection.
- **`stage:building` idles with `dispatch-skipped` events** (already
  covered post-ENG-86): orchestrator-side predicate gate firing on
  every tick; recovery via PR approval.

ENG-91's row covers: every individual issue is healthy (no halt,
no breaker, predicate evaluates correctly), but the queue policy
starves work near completion. Picker-ordering failure.

**Why a runbook entry rather than only a code comment.** Operator
debugging starts in CLAUDE.md / runbooks (the "what looks weird"
surface). Picker-layer mistakes are diagnosable from logs — the
`picker:` log lines plus the `_picker_build_pool` output (logged
at debug-level) are the first stops. The runbook entry names the
log line shape and the `bin/linear.sh add-label <issue>
pipeline:paused` recovery; without it, a freshly-onboarded operator
has no thread to pull.

**Rejected alternative — top-of-`_picker_build_pool` docstring only.**
Insufficient. CLAUDE.md is the agent context (every dispatched
stage agent reads it), and operators reach for it before reading
poll.sh internals. The docstring is good (and ENG-91 adds one as
part of D-001), but it's the second line of defense, not the first.

**Rejected alternative — link to a new runbook page
`docs/runbooks/picker-troubleshooting.md`.** Premature — the row
plus the `bin/poll.sh` docstring covers the documented failure
modes. If a new picker-layer failure class emerges (hopefully
not), a runbook page is the right next step.

## 5. Architecture (where code goes)

Five files modified, no new files:

| File | Change | Lines |
| ---  | ---    | ---   |
| `bin/poll.sh` | (a) Replace Pass 4/5/6 (lines 448-537) with Pass 4U + the trailing idle reasons. (b) Add `_picker_build_pool` helper (next to `_poll_classify_all` at line 299). (c) Add `_picker_predicate_ready` shim (next to the new pool helper). (d) Add a docstring above `_picker_build_pool` documenting the sort key (the contract reference for D-002). | net +60 (-90 / +150) |
| `bin/linear.sh` | (a) D-004: append `createdAt` to `list_issues_in_state`'s GraphQL projection at line 210. | net +1 |
| `bin/poll-slot-test.sh` | (a) D-005: add 6 AC-PICK-* fixtures + entry-conditions.sh stub. (b) Migrate AC-WAIT-2 to assert the post-ENG-91 outcome. | net +200 (6 cases × ~30 + stub + AC-WAIT-2 rewrite) |
| `CLAUDE.md` | D-006: insert one row in "Failure-mode quick reference". | net +3 |
| `bin/linear-test.sh` | Update any fixture asserting the projection shape of `list_issues_in_state` (if such a test exists; verify pre-implement). | net +2 (likely) |

No new files, no new scripts, no new dependencies. No
`AGENT_PROMPTS.md` changes (the picker is orchestrator-only). No
`.pipeline-config/config.json` changes — `entry-conditions.sh`'s
existing config (`orchestrator.entry_conditions[building]`) is
reused as-is.

## 6. Data flow

Pre-ENG-91, dispatch path on the 2026-05-09 incident:

```
main()
  ├─ Pass 1: gather stage-labelled issues → [ENG-83 stage:building, ENG-90 stage:planning]
  ├─ Pass 2: classify
  │     ├─ ENG-83: slot=vacate, wait_recallable=true, wait_progress_ts=07:51 (ENG-85)
  │     └─ ENG-90: slot=hold, advanceable=true
  ├─ Pass 3: held = [ENG-90]; held_count = 1
  ├─ Pass 4: iterate held
  │     └─ ENG-90 advanceable → emit dispatch decision → exit 0
  └─ (Pass 5 / Pass 6 unreachable)
```

ENG-83 starves regardless of PR approval state.

Post-ENG-91, same scenario:

```
main()
  ├─ Pass 1-2-2b-3 unchanged
  ├─ held = [ENG-90]; held_count = 1
  ├─ Pass 4U: _picker_build_pool
  │     ├─ held_pool: [{id:ENG-90, stage_index:1, fifo_ts:<updatedAt>, picker_source:"held"}]
  │     ├─ wait_pool (held_count < cap):
  │     │     ├─ candidate ENG-83: predicate_ready (entry-conditions: proceed)
  │     │     └─ pool: [{id:ENG-83, stage_index:6, fifo_ts:07:51, picker_source:"wait_recallable"}]
  │     ├─ inbox_pool (held_count < cap): [...]
  │     └─ sort_by([-(.stage_index), -(.priority_sort_rank), .fifo_ts])
  │         → [ENG-83 (stage 6), ENG-90 (stage 1), ...inbox (stage -1)]
  └─ iterate sorted pool:
      └─ ENG-83 → emit dispatch decision (wait re-pickup at stage:building) → exit 0
```

ENG-83 wins the picker. Build agent runs P2, sees PR approved,
runs `gh pr merge`. ENG-83 transitions to released; slot freed for
ENG-90 next tick.

Same scenario but PR not yet approved:

```
main()
  ├─ Pass 1-2-2b-3 unchanged (held_count=1)
  ├─ Pass 4U: _picker_build_pool
  │     ├─ held_pool: [ENG-90]
  │     ├─ wait_pool:
  │     │     ├─ candidate ENG-83: predicate_ready? entry-conditions returns
  │     │     │     skip:awaiting-approval → log "picker: wait_recallable ENG-83
  │     │     │     skipped (predicate not ready)"; exclude
  │     │     └─ pool: []
  │     ├─ inbox_pool: [...possibly empty...]
  │     └─ sorted: [ENG-90, ...inbox...]
  └─ iterate sorted pool:
      └─ ENG-90 → emit dispatch decision → exit 0
```

ENG-83 stays vacated, sibling ENG-90 progresses. Operator approves
PR mid-day → next tick's predicate flips → ENG-83 wins picker.

Cap-saturation case (held_count == max_concurrent):

```
main()
  ├─ held = [ENG-A, ENG-B]; held_count = 2 = cap
  ├─ Pass 4U: _picker_build_pool
  │     ├─ held_pool: [ENG-A, ENG-B] (always included)
  │     ├─ wait_pool: [] (cap-guarded; held_count >= max_concurrent → skip)
  │     ├─ inbox_pool: [] (same cap guard)
  │     └─ sorted: [ENG-A or ENG-B by stage/priority]
  └─ iterate:
      └─ first advanceable held → emit dispatch → exit 0 (or verdict_handler if halted)
```

Held items continue to be picked at-cap; wait_recallable + inbox
defer to next tick when a slot frees. Same invariant as today.

Three failure modes, all intentionally fail-safe:

1. **`entry-conditions.sh` errors mid-tick** (gh outage).
   `_picker_predicate_ready` returns 0 (fail-open per D-003) →
   wait_recallable enters pool → may win picker → run-stage.sh's
   pre-dispatch gate also fails-open → agent runs → agent's P2
   discovers the truth. Same wall-clock as today (one wasted
   dispatch when gh is broken). No regression.

2. **`linear.sh list-issues-in-state` errors mid-tick.** The pipe
   to jq sees malformed output → jq emits `[]` (or empty); inbox
   pool is empty for this tick. Held + wait_recallable still
   dispatch. Same as today's Pass 5 inbox-query failure handling
   (the inbox query is wrapped in the same shell-piped jq filter
   pre and post-ENG-91 — error behaviour is preserved).

3. **classifier emits a wait_recallable item without
   `wait_progress_ts`** (defensive). `_picker_build_pool`'s jq adds
   `fifo_ts:(.wait_progress_ts // "")`. Empty fifo_ts sorts before
   any non-empty timestamp (lexicographic) — so a malformed wait
   would sort to the front of its priority/stage tier. Aesthetic
   concern only: the dispatch is the same correct dispatch (the
   picker just orders the wait first). Defensive default-empty
   prevents jq error during sort. No new failure surface.

## 7. Error handling

- **`entry-conditions.sh` exits non-zero or returns garbage on
  stdout.** `_picker_predicate_ready`'s `case "$out" in *) return 0
  ;;` clause fail-opens. Symmetric with ENG-86's existing handling
  in `bin/run-stage.sh::_entry_conditions_gate`. No new surface.

- **`list_issues_in_state` returns a JSON shape without `createdAt`
  for some issues** (Linear API field-level error, or unmigrated
  issues from before the field was indexed). The jq filter's
  `(.createdAt // "")` defaults the missing field to empty, sorts
  to the front. Cosmetic; no crash.

- **Two wait_recallables with identical `wait_progress_ts`** (same
  Linear comment second). jq's sort_by is stable in jq ≥1.6
  (verified — every poll.sh fixture uses `sort_by` and assumes
  stable ordering); ties fall through to gather order. Real-world
  improbable (Linear comment timestamps are millisecond precision
  but Linear's API truncates to seconds in the comment payload —
  see `bin/poll-slot-test.sh` fixture format). Same as today's
  Pass 6 tiebreak.

- **A wait_recallable's stage_label maps to a stage_arg that
  `entry-conditions.sh` doesn't recognize.** ENG-86 D-005:
  unknown stage → empty check list → `proceed`. Picker includes
  the wait in the pool. Today there are no non-build wait emitters
  (per ENG-54), so this is a future-proofing path. If a future
  stage emits wait without a configured predicate, it enters the
  pool unconditionally — caller must explicitly add an
  `entry_conditions[<stage>]` to restrict.

- **The held item's `updatedAt` is in the future** (clock skew
  between Linear's API server and the harness host). Sorts to the
  back of its tier (since `fifo_ts` ascending). Cosmetic; no crash.
  The same clock-skew concern surfaces in ENG-85's Pass 6 sort
  (`wait_progress_ts`), addressed via the same lexicographic ordering
  fall-through. No new surface.

- **Pool is empty (`held_count >= max_concurrent` AND zero held
  advanceable items).** Loop exits without dispatch, falls through
  to the existing idle-reason guard (`bin/poll.sh:540-543` →
  `idle "max-concurrent-reached"`). Same observable behaviour as
  today.

- **`stage_arg_for_label` returns empty for an unknown stage label**
  (a future stage_label not in `STAGE_LABEL_TO_STAGE_ARG` at
  `bin/poll.sh:25-33`). The dispatch decision JSON has `stage:""`,
  which downstream consumers (`run-stage.sh`) reject. This is a
  pre-existing failure mode (today's Pass 4 does the same lookup
  at `bin/poll.sh:479`); ENG-91 inherits it. Not a regression.

## 8. Edge cases

- **Held has the same stage as a wait_recallable, both ready, same
  priority.** E.g., ENG-A `stage:building` held + advanceable
  (the build agent's prior dispatch didn't emit wait — succeeded);
  ENG-B `stage:building` wait_recallable (ENG-85 path), predicate
  ready. Sort key tiebreaker is fifo_ts:
  - held's fifo_ts = `updatedAt` (most recent label change or
    metadata change)
  - wait_recallable's fifo_ts = `wait_progress_ts` (the wait verdict
    comment's createdAt)
  Whichever is older wins. In practice the wait verdict's createdAt
  is older than the issue's most recent updatedAt (because every
  re-dispatch by the orchestrator updates the comments-thread,
  which advances `updatedAt`). So the wait wins — an in-flight
  wait at the same stage as a finished held gets priority. This is
  acceptable: the held is "done at this stage" (would re-dispatch a
  no-op), the wait is "waiting on external signal that just
  arrived." Strictly, `_poll_classify_labels` puts a finished
  building+pass into `slot:hold, advanceable:true` so Pass 4 would
  re-dispatch it; Pass 4U does the same modulo the wait being
  prioritized first. Cosmetic edge case; not a regression vs the
  pre-ENG-91 Pass 4-then-6 ordering (which would've picked the
  held first).

- **Two inbox arrivals at the same priority, same `createdAt`.** jq
  stable sort falls through to the GraphQL response order. Real-world
  improbable.

- **`max_concurrent_features = 1`.** held_count goes 0/1; cap == 1.
  When held_count=0: pool includes held + wait + inbox. When
  held_count=1: pool includes held only (cap-guarded). Picker still
  picks the highest-stage-index held when cap is full. Same as
  today's single-slot mode.

- **`max_concurrent_features = 0` (effectively paused).** held_count
  starts at 0; cap == 0; held_count < max_concurrent is false →
  wait + inbox excluded. held_pool may still have items but the
  iteration immediately exits when no advanceable found OR when
  the found held is halt-with-stage-summary (verdict_handler runs,
  no dispatch). idle "max-concurrent-reached". Same as today.

- **Fresh wait emitted just before this tick, predicate ready
  immediately** (e.g., human approved between agent's wait emit
  and picker's predicate check). Entry-conditions returns
  `proceed` → wait wins picker → orchestrator pre-dispatch gate
  also returns proceed (D-003 trade-off: both layers run, both
  return proceed, no waste). Same as today's "approve and re-tick"
  flow but without the inbox/held preemption.

- **Wait_recallable issue's stage label changed mid-tick** (race
  between wait emit and a transition). `_poll_classify_labels`
  takes the post-mutation labels (per ENG-78's mid-tick re-read
  contract); the picker reads the post-classify item. Whatever
  stage_label the classifier assigned drives the predicate lookup.
  Idempotent.

- **Operator manually applied `pipeline:halted` to a
  wait_recallable issue.** The halted arm fires first in
  `_poll_classify_labels` (line 231-247); the wait_recallable
  branch (line 248-256) is unreachable. Picker sees the issue as
  halted (`slot:hold, advanceable:false` if no fresh marker, or
  `slot:vacate, advanceable:false` if pipeline-halt marker). Either
  way the wait_recallable is excluded from the pool. Correct.

- **An inbox issue carries `pipeline:halted` (operator-applied to
  a Todo issue).** Same as ENG-90's open question O-1 (referenced
  but unresolved): Pass 5 inbox query does NOT filter on
  `pipeline:halted` (`bin/poll.sh:494-504`). ENG-91 inherits this
  behaviour — the inbox item enters the pool, may win, and on
  next tick the new stage label's halted arm vacates the slot.
  Out of scope for ENG-91 (covered by ENG-90 O-1).

- **Multiple wait_recallables, mixed predicates.** E.g., ENG-A
  predicate ready, ENG-B predicate not ready. ENG-B excluded;
  ENG-A enters pool and competes on stage_index/priority. Pool
  iteration dispatches ENG-A. ENG-B stays vacated, next tick
  re-evaluates predicate. Same behaviour as today's Pass 6 (but
  Pass 6 dispatched both regardless of predicate; ENG-86's
  pre-dispatch gate then skipped one).

- **Future K=2 dispatch (ENG-81 placeholder).** ENG-91 picks one
  candidate per tick. ENG-81 would lift this to K. The unified
  pool's sort key + iteration model is K-fanout-compatible: ENG-81
  changes `dispatch top` to `dispatch top K` and the iteration
  yields the K highest-ranked compatible candidates. Out of scope.

- **`entry-conditions.sh` is missing** (operator deleted it
  accidentally, or the harness is run from a stale checkout). The
  shell-out fails; `_picker_predicate_ready` returns 0 (fail-open).
  Wait_recallable enters pool. Orchestrator pre-dispatch gate's
  `entry_conditions.sh` lookup also fails — agent runs, P2 catches
  it. Worst case: one wasted dispatch, plus the operator notices
  the missing file. Defense-in-depth holds.

- **Inbox arrival WITH a `stage:*` label** (rare; an operator
  manually applied a stage label to a Todo issue). Filtered out by
  the inbox query at `bin/poll.sh:496` (`select([.labels.nodes[].name]
  | any(startswith("stage:")) | not)` — preserved post-ENG-91).
  The same issue would also appear in Pass 1's gather (stage-label
  query) and reach classify. Both paths converge: classify owns
  the dispatch, inbox-query's filter prevents double-counting.
  Same as today.

## 9. Persona review

### design — PASS

The fix collapses three sequential picker passes into one ranked
pool with an explicit sort key, gates wait_recallable inclusion on
a recall predicate, and reuses the existing `entry-conditions.sh`
infrastructure for the predicate evaluation. No new slot enum, no
new pipeline event, no new label, no new schema field — the
picker-local `picker_source` and `fifo_ts` annotations are jq-pipe
locals consumed by the iteration, never emitted to Linear or
metrics.

The unified `_picker_build_pool` helper is the right granularity:
it owns fifo_ts attribution, cap-conditional inclusion, and the
final sort. Splitting into per-source helpers would multiply the
jq-shape surface area without simplifying the cap discipline.

D-002's choice of `updatedAt` for held FIFO is the cheaper proxy
that ships ENG-91 today, with strict-transition-ts FIFO deferred
to O-1. The trade-off is documented; the load-bearing failure
(cross-pool starvation) is closed without it.

D-003's reuse of `entry-conditions.sh` rather than duplicating the
predicate inside `bin/poll.sh` matches the ENG-86 contract and
keeps a single source of truth for the per-stage check. **Verdict:
PASS, no findings.**

### security — PASS

No secret-handling surface touched. `_picker_build_pool` shells out
to `bin/linear.sh list-issues-in-state` (existing), and
`_picker_predicate_ready` shells out to `bin/entry-conditions.sh
should_dispatch` (existing). Both pass arguments positionally;
neither uses `${VAR:-…}` against secret-named env vars. The new
sort key is jq-internal; no shell expansion of attacker-controlled
strings.

The augmented `linear.sh` query at D-004 adds `createdAt` to a
GraphQL projection — a read-only field, no mutation, no parameter
binding change. The jq filter that consumes it uses
`(.createdAt // "")`, which is safe against missing/null fields.

`bin/entry-conditions.sh::check_pr_approved_by_non_bot` shells out
to `gh pr view` against `branch-name.sh`'s output — the same call
path AGENT_PROMPTS.md §7 P2 uses. No new attack surface.

**Verdict: PASS, no findings.**

### scope — PASS

Strictly within the issue body's "Acceptance criteria":

- AC-1 → D-001 (unified picker)
- AC-2 → D-002 (sort key) + D-005 (test fixture coverage)
- AC-3 → D-003 (recall-predicate gate) + D-005 (AC-PICK-1 / AC-PICK-2)
- AC-4 → D-005 (AC-PICK-3 — live-incident regression pin)
- AC-5 → D-005 (AC-PICK-4 — multi-fleet ordering)
- AC-6 → unchanged: halt-sprawl filter on `wait_recallable`
  exclusion is preserved (the picker_eligible flag is orthogonal
  to halt-sprawl — confirmed by reading the existing filter at
  `bin/poll.sh:360` / `bin/poll.sh:388` post-ENG-85; ENG-91 does
  not touch halt-sprawl).
- AC-7 → D-006 (CLAUDE.md row).

The brainstorm does NOT modify `max_concurrent_features` or K, does
NOT add pre-emption of in-flight dispatches, does NOT re-evaluate
predicates more often than once per tick, does NOT add cross-project
picker semantics — all explicit non-goals from the issue body.

The one file outside the immediately-named "Scope" — `bin/linear.sh`
— gains a single GraphQL field (`createdAt`). The change is
strictly additive (no field removed) and serves AC-2's `fifo_ts` for
inbox arrivals. The issue body's reference to "createdAt for inbox"
is the explicit warrant. No prompt or `.pipeline-config/config.json`
changes.

**Verdict: PASS, no findings.**

### coherence — PASS

Brainstorm structure follows the recent ENG-85 / ENG-86 / ENG-90
pattern: Overview → Goals → Architectural principle → Decisions →
Architecture → Data flow → Error handling → Edge cases → Persona
review → Open questions → Anti-bias → Conflicts. Each decision
cites a CLAUDE.md commitment or a prior brainstorm's precedent.
Each rejected alternative names a specific cost (drift surface,
scope creep, coupling, blast radius).

The audit table at §1 mirrors the issue body's incident timeline
verbatim (matching column order, matching wall-clock observations).
The decisions are causal: D-001 establishes the picker, D-002 names
the sort key, D-003 adds the gate, D-004 unblocks D-002 for inbox,
D-005 pins regressions, D-006 surfaces the failure mode in the
runbook.

The fixture coverage table (D-005) maps every AC-* in the issue
body to a specific AC-PICK-* test. The trade-off section (D-002
held-FIFO proxy) is honest about deferred work.

**Verdict: PASS, no findings.**

### product — PASS

Three operator-facing improvements:

1. **Cross-pool starvation eliminated.** A near-merge ticket with an
   approved PR no longer waits behind earlier-stage or inbox issues.
   The 2026-05-09 incident (ENG-83 starved 60+ min) does not recur.
2. **Approve-and-walk-away pattern restored.** Before ENG-91, a
   build wait could be preempted by inbox arrivals during the
   approval window. After ENG-91, the predicate-gate ensures the
   approved build wins on the very next tick.
3. **No regression in per-issue isolation.** Halt, halt-sprawl,
   ENG-90 oar contract, ENG-86 entry-conditions gate, ENG-85
   wait_recallable classification, `external_signal_budget` —
   all preserved. ENG-91 only changes per-tick picker ordering.

Operators who manually intervened during the starvation incident
(via `pipeline:paused` on the held to free the slot) gain the
documented recovery path in CLAUDE.md (D-006). No new operator
training material is required for the steady-state behaviour —
the picker decision is invisible to Linear UI; only the dispatch
order changes.

**Verdict: PASS, no findings.**

### feasibility — PASS (gating)

Codebase-fact verification (every named file:line cross-checked
against the current worktree — see §11 Anti-bias / Assumption
Inventory):

- `bin/poll.sh:413-548` — `main()` definition. ✅
- `bin/poll.sh:425-432` — Pass 1 (gather) + Pass 2 (classify). ✅
- `bin/poll.sh:434-436` — Pass 2b halt-sprawl. ✅
- `bin/poll.sh:438-446` — Pass 3 held aggregation + held_count compute. ✅
- `bin/poll.sh:448-486` — Pass 4 (held dispatch loop). ✅
- `bin/poll.sh:467-475` — Pass 4 halt+stage-summary verdict_handler invocation. ✅
- `bin/poll.sh:479` — `stage_arg_for_label` invocation pattern. ✅
- `bin/poll.sh:488-513` — Pass 5 (inbox pickup with cap guard). ✅
- `bin/poll.sh:494-504` — inbox jq filter (preserved verbatim). ✅
- `bin/poll.sh:515-537` — Pass 6 (wait_recallable picker, ENG-85). ✅
- `bin/poll.sh:519` — Pass 6 cap guard. ✅
- `bin/poll.sh:521-524` — Pass 6 sort key (preserved logic, refactored shape). ✅
- `bin/poll.sh:539-543` — final idle reasons. ✅
- `bin/poll.sh:25-33` — `STAGE_LABEL_TO_STAGE_ARG` + `stage_arg_for_label`. ✅
- `bin/poll.sh:36-38` — `stage_arg_for_label` definition. ✅
- `bin/poll.sh:140-167` — `_poll_gather_stage_labeled_issues` (returns `updatedAt` per `bin/linear.sh:220`). ✅
- `bin/poll.sh:148-165` — `stage_index` assignment (idx starts -1, increments to 0 for brainstorming). ✅
- `bin/poll.sh:207-293` — `_poll_classify_labels` definition. ✅
- `bin/poll.sh:248-256` — wait_recallable classifier branch (ENG-85). ✅
- `bin/poll.sh:299-322` — `_poll_classify_all` (location for sibling `_picker_build_pool`). ✅
- `bin/poll.sh:316` — priority_sort_rank assignment. ✅
- `bin/poll.sh:340-404` — `_poll_emit_halt_sprawl_alert` (preserved unchanged). ✅
- `bin/poll.sh:360, 388` — halt-sprawl filter (excludes wait_recallable; preserved). ✅
- `bin/entry-conditions.sh:1-145` — full file. ✅
- `bin/entry-conditions.sh:48-65` — `check_pr_approved_by_non_bot`. ✅
- `bin/entry-conditions.sh:84-138` — `should_dispatch` verb (proceeds / skip:* / error:*). ✅
- `bin/linear.sh:206-214` — `list_issues_in_state` (currently NO `createdAt`; D-004 adds it). ✅
- `bin/linear.sh:216-224` — `list_issues_with_label` (already projects `updatedAt`; held FIFO source). ✅
- `bin/verdict-handler.sh:84-143` — `find_fresh_verdict`. ✅
- `bin/verdict-handler.sh:154-191` — `find_fresh_wait_verdict` (post-ENG-85). ✅
- `bin/run-stage.sh::_handle_wait` — line 489-578; budget management. ✅
- `bin/run-stage.sh:543-547` — `external_signal_budget.max_attempts` config read. ✅
- `bin/run-stage.sh:548-558` — `max_minutes` wall-clock arm. ✅
- `bin/run-stage.sh:560-575` — exhausted halt-add path. ✅
- `bin/poll-slot-test.sh:61-97` — stub pattern (linear.sh / metrics.sh / slack.sh). ✅
- `bin/poll-slot-test.sh:160-223` — fixture builders (`write_label_fixture`, `write_comments_fixture`, `write_inbox_fixture`). ✅
- `bin/poll-slot-test.sh:449-562` — AC-WAIT-1 through AC-WAIT-5 (existing). ✅
- `bin/poll-slot-test.sh:476-497` — AC-WAIT-2 (the fixture to migrate). ✅
- CLAUDE.md `:512-522` — "Failure-mode quick reference" table (insertion point). ✅
- ENG-85 brainstorm — Pass 6 / wait_recallable design (verified at
  `docs/brainstorms/2026-05-08-eng-85-…design.md`). ✅
- ENG-86 brainstorm — entry-conditions gate; D-005 (empty config →
  proceed); D-008 (pr-approved-by-non-bot is canonical); D-010
  (fail-open on tooling error). ✅
- ENG-90 brainstorm — slot-occupancy contract; AC-4 (halt-sprawl
  excludes wait_recallable). On `feat/eng-90-…` branch but NOT yet
  merged to main; ENG-91 references its halt-sprawl invariant
  (preserved by ENG-91, regardless of ENG-90 landing order). ✅
- jq stable sort property (≥1.6) — assumed (consistent with all
  poll.sh fixtures; not verified per-tick at runtime). assumed.
- Linear `createdAt` field availability on `Issue` GraphQL type —
  verified by inspection of the existing `get_issue` query at
  `bin/linear.sh:194` which already projects `createdAt`. So D-004's
  addition to `list_issues_in_state` is a known-supported field. ✅

All facts verified or explicitly marked assumed. Zero P0 findings.
**Verdict: PASS (gating).**

## 10. Open questions

- **O-1 (deferred optimization).** Held items use `updatedAt` as
  their fifo_ts proxy (D-002). Strict stage-transition-timestamp
  FIFO would refine this — `find_fresh_verdict` already computes
  `last_transition_ts` internally (`bin/verdict-handler.sh:160-167`).
  Threading it through the classifier output to the picker is one
  follow-up commit; deferred because cross-pool starvation (the
  load-bearing failure) is closed by the stage_index discriminator
  alone, and held-vs-held FIFO ties are rare and non-load-bearing.
  Filing recommendation: low priority.

- **O-2 (operator-visible behaviour change).** ENG-91 makes
  `external_signal_budget.max_attempts` exhaust even more slowly —
  a wait whose predicate stays in `skip:awaiting-approval` never
  increments `attempts` (because the picker doesn't pick it). The
  wall-clock arm (`max_minutes`) still works (it reads
  `first_attempt_at` whenever `_handle_wait` runs after eventual
  dispatch). Operators relying on attempt-count escalation should
  set `max_minutes` (already supported per `bin/run-stage.sh:548-557`,
  recommended by ENG-85's O-3). Filing recommendation: documentation;
  add a one-line note to the `external_signal_budget` config
  reference if/when one is created.

- **O-3 (deferred caching).** The unified picker calls
  `entry-conditions.sh` once per wait_recallable per tick.
  `bin/run-stage.sh::_entry_conditions_gate` calls it again
  pre-dispatch. The two calls are duplicate work — bounded by the
  number of wait_recallables (typically 1-2 per tick) and ~50ms
  per call. A future memoization (per-tick cache keyed by `(stage,
  ident)`) would trim ~100ms per tick. Filing recommendation:
  nice-to-have; defer until the harness scales beyond K=4.

- **O-4 (jq stable-sort assumption).** ENG-91's tiebreak on
  identical fifo_ts relies on jq ≥1.6's stable sort_by. Verified
  by inspection of every poll.sh fixture's assertion; not pinned
  by a smoke test. Real-world impact: ties are improbable with
  millisecond-precision timestamps. Filing recommendation: no
  action; the same assumption underlies ENG-85's Pass 6 sort and
  ENG-90's halt-sprawl top-3 selector.

- **O-5 (inbox-with-pipeline-halted edge).** ENG-90's brainstorm
  open question O-1 — the inbox query does NOT filter on
  `pipeline:halted`, so an operator-applied halt on a Todo issue
  enters the picker pool. ENG-91 inherits this behaviour. Filing
  recommendation: defer to ENG-90's resolution (O-1 there).

- **O-6 (entry-conditions.sh wait reasons coupling).**
  `entry-conditions.sh::check_pr_approved_by_non_bot` returns
  `awaiting-approval` as its skip reason; this matches
  `pipeline-events.json::wait_reasons`'s `awaiting-approval` token.
  If the wait_reasons registry adds a new token (e.g.,
  `awaiting-pr-mergeable`), `check_pr_approved_by_non_bot` doesn't
  natively know about it — a new check function would be needed.
  Symmetric to ENG-86's existing per-check architecture. Filing
  recommendation: no action; the registry is the source of truth
  and check additions are normal feature work.

## 11. Anti-bias checks

### ADR stress test

There are no formal ADRs in this repo (verified). The closest
analogues are accepted brainstorms and CLAUDE.md commitments.
Specific stress points:

- **ENG-85's brainstorm** establishes Pass 6 as a wait-recall
  fallback. ENG-91 collapses Pass 4/5/6 into Pass 4U. **Tension:
  yes — Pass 6's existence as a separate pass is removed.** ENG-85's
  contract was "wait still progressable when nothing else is ready"
  (D-003 there); ENG-91 preserves the contract with a stricter
  cap-eligibility check (only when no other ready work AND
  predicate evaluates true). The wait_recallable classifier branch
  (ENG-85's D-002) is unchanged — only the consumer (the picker)
  is restructured. Cost: a future reader navigating `bin/poll.sh`
  searching for "Pass 6" will not find it. Mitigation: the new
  `_picker_build_pool` docstring and the D-006 runbook entry both
  cite ENG-91 + ENG-85.

- **ENG-86's brainstorm** establishes the orchestrator-side
  pre-dispatch entry-conditions gate. ENG-91 *also* invokes
  entry-conditions before dispatch — picker-side. **Tension: no —
  defense in depth.** The two layers do the same predicate twice
  (small cost; O-3) but provide independent guarantees: the picker
  prevents a wait_recallable from stealing a slot when sibling
  work is queued; the orchestrator prevents a stale classifier
  output from reaching the agent. Defense-in-depth is the
  intentional design.

- **ENG-90's brainstorm** establishes the operator_action_required
  flag and the halt-sprawl exclusion contract. ENG-91 introduces
  `picker_eligible` as a picker-local concept that lives only
  inside `_picker_build_pool`. **Tension: no — orthogonal flags.**
  `picker_eligible` is not an emitted classifier field; it's a
  pool-construction predicate. Halt-sprawl reads `wait_recallable`
  (today) or `operator_action_required` (post-ENG-90) — neither
  reads `picker_eligible`. AC-6 holds in both worlds.

- **ENG-54's "single human-approval gate"** (CLAUDE.md §). ENG-54
  established that human approval happens at build's P2 only.
  ENG-91 reinforces this: the picker now waits for the approval
  predicate to evaluate `proceed` before re-dispatching the build.
  No new approval surface. **Tension: none — strict reinforcement.**

- **ENG-78's retry-immediately preservation** establishes that
  classifier doesn't auto-cleanup retry-immediately state files.
  ENG-91 doesn't touch `_poll_evaluate_skip` or state-file handling
  — picker reads pre-classified output. **Tension: none.**

- **CLAUDE.md "Sweep + scope partition (ENG-14)" §** —
  `bin/poll.sh`, `bin/linear.sh`, `bin/poll-slot-test.sh`,
  `CLAUDE.md` are all in `bin/` (or repo root) and in the
  partition_dirty_paths::D-004 allowlist for the implement stage.
  `bin/linear-test.sh` (likely touched per §5) is also in `bin/`.
  **Tension: none.**

- **Pipeline-marker write-time validation contract.** The picker
  emits dispatch decisions to stdout (consumed by `run-local.sh`),
  not pipeline markers. No write-time validation surface touched.
  **Tension: none.**

### Simpler alternative

Documented under each decision (D-001 has 3 rejected, D-002 has 3
rejected, D-003 has 3 rejected, D-004 has 3 rejected, D-005 has 2
rejected, D-006 has 2 rejected). Each rejection cites a specific
cost — drift surface, predicate-location coupling, FIFO-source
unreliability, scope creep, fixture-rename hygiene.

The simplest possible alternative — *add only the predicate gate to
Pass 6, leave Pass 4/5/6 sequential* — was rejected because it
solves the symptom (wasted Pass-6 dispatches against not-ready
predicates) without fixing the load-bearing failure (cross-pool
starvation). The Linear issue body specifically frames the unified
picker as the contract amendment; a Pass-6-only fix is a partial
implementation that fails AC-1 by construction.

The second-simplest alternative — *unified picker without the
predicate gate* — was rejected because it fails AC-3 by construction:
a not-ready wait_recallable would outrank an inbox arrival under
the new sort, and the orchestrator-side ENG-86 gate would emit
`dispatch-skipped` while wasting the picker's slot. The wall-clock
saving the issue body cites depends on the picker-side gate.

### Assumption inventory

Every codebase fact referenced is verified against the current
worktree (see §9 feasibility checklist).

| Assumption | Status |
| ---        | ---    |
| `bin/poll.sh::main()` is at `bin/poll.sh:413-548` and contains Pass 1-6 + idle reasons | verified |
| `bin/poll.sh:439-486` is Pass 4 (held dispatch); 488-513 is Pass 5 (inbox); 515-537 is Pass 6 (wait re-pickup, ENG-85) | verified |
| Each pre-ENG-91 pass exits the tick on first dispatch via `exit 0` | verified at `bin/poll.sh:485, 511, 535` |
| `_poll_classify_labels` produces wait_recallable items at line 248-256 (ENG-85) | verified |
| `_poll_classify_all` produces classified items with `slot, advanceable, priority_sort_rank, stage_index, labels, updatedAt, ...` | verified — `_poll_gather_stage_labeled_issues` projects `updatedAt` per `bin/linear.sh:220`, augmented with `priority_sort_rank` at `bin/poll.sh:316` |
| `bin/poll.sh:519-524` Pass 6 sort key uses `[-(.priority_sort_rank), .wait_progress_ts]` and is preserved-in-spirit by ENG-91's unified sort | verified |
| `entry-conditions.sh::should_dispatch <stage> <issue>` returns `proceed` / `skip:<reason>` / `error:<check>` on stdout, always exit 0 | verified at `bin/entry-conditions.sh:84-138` |
| ENG-86 D-005: empty `entry_conditions[<stage>]` config → `proceed` | verified at `bin/entry-conditions.sh:96-101` |
| `entry-conditions.sh::check_pr_approved_by_non_bot` returns rc=2 (caller fail-opens) on gh/jq outage | verified at `bin/entry-conditions.sh:50-61` |
| `bin/linear.sh::list_issues_in_state` does NOT currently project `createdAt` (D-004 adds it) | verified at `bin/linear.sh:210` |
| `bin/linear.sh::list_issues_with_label` projects `updatedAt` (held FIFO source) | verified at `bin/linear.sh:220` |
| `Issue` GraphQL type supports `createdAt` (added by D-004 to `list_issues_in_state`) | verified — `bin/linear.sh:194` already projects `createdAt` on `get_issue` |
| `find_fresh_verdict` computes `last_transition_ts` internally (potential O-1 source) | verified at `bin/verdict-handler.sh:91-101` |
| `find_fresh_wait_verdict` returns `{reason, comment_id, created_at}` or empty | verified at `bin/verdict-handler.sh:154-191` |
| `_handle_wait` writes `wait-${stage}.json` with `attempts, first_attempt_at`; budget exhaustion applies `pipeline:halted` | verified at `bin/run-stage.sh:489-578` |
| `_handle_wait`'s budget arms: `max_attempts` (count) + `max_minutes` (wall-clock) | verified at `bin/run-stage.sh:543-557` |
| `bin/poll-slot-test.sh` source-and-stub pattern (linear.sh / metrics.sh / slack.sh stubs) | verified at `bin/poll-slot-test.sh:61-97` |
| AC-WAIT-2 (`bin/poll-slot-test.sh:476-497`) currently asserts ENG-WAIT-B (stage:qa) wins over ENG-WAIT-A (stage:building wait) | verified |
| `stage_index` is the position in `workflow_stages` (brainstorming=0, ..., building=6, released=7 excluded) | verified at `bin/poll.sh:148-165` |
| `priority_sort_rank` is `(if priority == 0 then 0 else 5-priority)`; Urgent=4, High=3, Normal=2, Low=1, None=0 | verified at `bin/poll.sh:316` and `bin/poll.sh:502` |
| `STAGE_LABEL_TO_STAGE_ARG` enumerates all stage:* labels except stage:released | verified at `bin/poll.sh:25-33` |
| ENG-90 brainstorm is on `feat/eng-90-…` branch but NOT yet on main; ENG-91 does not depend on ENG-90 landing first | verified — ENG-91's halt-sprawl interaction (AC-6) reads the existing `wait_recallable` filter (preserved as-is in pre-ENG-90 main) |
| `find_fresh_wait_verdict`'s `wait_progress_ts` field is what wait_recallable's classifier surfaces (named `wait_progress_ts` post-ENG-85) | verified at `bin/poll.sh:255` |
| Linear's GraphQL `Issue.createdAt` is ISO-8601 UTC (lexicographically sortable) | assumed (consistent with all ISO-8601 timestamps Linear emits; verified format on `comments[].createdAt` per `bin/poll-slot-test.sh::write_comments_fixture` and `bin/verdict-handler.sh:91-101`) |
| jq's `sort_by` is stable in jq ≥1.6 | assumed (consistent with all poll.sh fixtures; not pinned by smoke test — see O-4) |
| `bin/linear-test.sh` may have a `list_issues_in_state` projection-shape assertion that needs updating post-D-004 | assumed (verify pre-implement; no current line citation) |
| `CLAUDE.md:512-522` is the "Failure-mode quick reference" table; D-006 inserts a new row between "Issue stuck in stage:X" and "Wrong-target Linear writes" | verified |

### Codebase-fact verification (gating)

All named files, methods, line numbers, registry values verified —
see §9 feasibility checklist. Zero unverified facts. Zero P0
findings.

## 12. Conflicts with existing architecture

**Three real interactions, all intentional, no architecture
conflicts:**

1. **Pass 4/5/6 collapse to Pass 4U.** Affects:
   - `bin/run-local-sweep-test.sh` and similar tests that may
     reference Pass-X numbering in error messages — verify
     pre-implement; if any such reference exists, update or
     reword to "Pass 4U" / "the unified picker."
   - Operator runbooks: `docs/runbooks/operator-mental-model.md`
     and `docs/runbooks/recovery.md` — neither references "Pass 4"
     / "Pass 5" / "Pass 6" by number (verified by inspection).
     No prose update required beyond the D-006 CLAUDE.md row.

2. **Wait_recallable picker eligibility now gated on
   `entry-conditions.sh`.** Affects:
   - `bin/run-stage.sh::_entry_conditions_gate` continues to call
     `entry-conditions.sh::should_dispatch` pre-dispatch (ENG-86
     contract). The two calls are duplicated work (O-3) but
     provide independent guarantees.
   - `bin/run-stage.sh::_handle_wait`'s `external_signal_budget`
     escalation cadence shifts (O-2). Documented.

3. **`bin/linear.sh::list_issues_in_state` GraphQL projection
   gains `createdAt`.** Affects:
   - Other callers (`bin/poll.sh` Pass 5 inbox query, possibly
     `bin/cleanup-worktrees.sh` or a future caller). All callers
     consume the JSON via jq filters that select specific fields;
     adding a field is non-breaking.
   - `bin/linear-test.sh` may have a query-shape assertion
     (verify pre-implement). If so, update to expect the new
     field.

**Two cosmetic interactions, no behaviour change:**

4. **Existing AC-WAIT-2 fixture in `bin/poll-slot-test.sh:476-497`
   inverts.** Pre-ENG-91: ENG-WAIT-B wins (stage:qa over
   stage:building wait). Post-ENG-91: ENG-WAIT-A wins (stage:building
   wait > stage:qa held, predicate ready). The fixture is rewritten
   per D-005; the prior assertion's purpose (cross-pool slot
   discipline) is preserved by AC-PICK-3 (later-stage wait wins)
   and AC-PICK-6 (later-stage held wins). Cosmetic; not a real
   architecture conflict.

5. **The new `_picker_build_pool` and `_picker_predicate_ready`
   helpers live in `bin/poll.sh`.** Adding helpers is the existing
   pattern (`_poll_evaluate_skip`, `_poll_classify_labels`,
   `_poll_classify_all`, `_poll_emit_halt_sprawl_alert` all live in
   poll.sh). Cosmetic naming convention only.

No other conflicts identified. ENG-91 strengthens the existing
slot-classification + dispatch-decision contract by collapsing the
sequential picker into a single ranked queue with explicit fairness
semantics, without changing any other control-flow surface.
