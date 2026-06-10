---
linear: ENG-178
title: Picker unified candidate pool — let predicate-ready higher-stage waits compete
date: 2026-06-10
status: draft
---

# ENG-178 — Picker unified candidate pool

**Type:** `Bug` (High) · **Subsystem:** orchestrator (`bin/poll.sh`) + tests (subordinate) · **Status:** design approved

## Problem

When `K` issues are already classified `slot:"hold"`, the picker in
`bin/poll.sh::_picker_build_pool` excludes **all** `wait_recallable` and
`inbox` candidates from the pool — regardless of stage. An approved,
build-ready issue (`stage:building`, fresh `wait` verdict, recall predicate
ready) loses its slot to a *less-advanced* held issue (e.g. `stage:planning`).
This contradicts the documented sort intent (`[-stage_index, …]` =
most-advanced-first) and is the exact cross-pool starvation ENG-91's Pass 4U
comment claims to have fixed.

Observed 2026-06-10: ENG-154 and ENG-119 reached `stage:building`, emitted
`verdict wait reason=awaiting-approval`, and were approved by a non-bot OWNER,
yet sat idle across multiple ticks while ENG-156 (planning→ui) and ENG-150
(brainstorming→implementing) — both *less* advanced — consumed both `K=2`
slots every tick. `wait-building.json::attempts` froze at `1` (never
re-evaluated); no `"wait_recallable skipped (predicate not ready)"` log lines,
because the cap guard short-circuits *before* the predicate check is reached.

## Root cause

`bin/poll.sh::_picker_build_pool` (~L470):

```bash
local wait_pool='[]' inbox_pool='[]'
if (( held_count < max_concurrent )); then
    # wait_recallable + inbox candidates are assembled ONLY inside here
```

Held items are assembled unconditionally; the `wait`/`inbox` candidate block
is gated on `held_count < max_concurrent`. The Pass 4U sort key
(`[-stage_index, -priority_sort_rank, fifo_ts, identifier]`) only orders items
*within* the already-assembled pool — it cannot promote a candidate that was
excluded before sorting. Net effect: any `held` issue at any stage outranks an
approved `building` wait.

## Conceptual model

The orchestrator should: **gather all candidates → filter out the
un-workable (halted, abandoned, paused, build-wait whose approval predicate is
not yet ready) → sort the survivors by the prioritisation rubric → take the
top K.** The classify + sort + top-K machinery already implements this model;
the only defect is one gate that filters out a whole class (`wait`/`inbox`)
for the wrong reason ("K issues are held") rather than because the ticket is
un-workable.

| Model step | Where it lives today |
|---|---|
| Gather all candidates | `_poll_classify_labels` over every issue |
| Filter out un-workable | slot states: `halted`/`abandoned` → `vacate(oar)`; build-wait not approved → wait excluded by `_picker_predicate_ready`; `paused`/`abandoned` inbox filtered in the inbox query |
| Sort survivors by rubric | `_picker_build_pool` final `sort_by([-stage_index, -priority_sort_rank, fifo_ts, identifier])` |
| Take top K | `main()` decision loop, capped at `_max_decisions` (= K) |

"Stuck → out of contention" is already honored: a build-wait awaiting approval
has `_picker_predicate_ready == false` → excluded from `wait_pool`; a halted
issue is `slot:"vacate"`, never in `held_pool`. Only *workable* tickets reach
the sort. No anti-starvation guard is added — a low-stage held issue yielding
to higher-stage *workable* work is the intended "advance the most-complete
work first" behavior, and stuck higher-stage tickets remove themselves from
contention.

## Design — the change

In `_picker_build_pool`, split the single `held_count < max_concurrent` gate
so that the two candidate classes are treated according to whether they can
ever outrank a held issue:

- **`wait_pool` → always assembled** (existing `_picker_predicate_ready`
  filter unchanged). A predicate-ready wait carries its true `stage_index`, so
  the unified sort lets a ready `building` wait outrank a `planning` held.
  This is the fix.

- **`inbox_pool` → stays under `held_count < max_concurrent`**, re-documented
  as a *lossless cost optimization*, not a correctness gate. Inbox candidates
  have `stage_index = -1`, so they can never outrank K held issues; skipping
  the `linear.sh list-issues-in-state` network call when held is full changes
  no outcome. The WIP cap on inbox admission is still enforced by the unified
  sort + top-K (inbox wins a slot only when fewer than K higher-stage workable
  candidates exist).

`held_count` stays a parameter (still feeds the inbox guard and the
`max-concurrent-reached` idle message). No Pass 3 / held-selection refactor —
smallest diff, lowest blast radius.

### Cost

`wait_pool` assembly now runs `_picker_predicate_ready` (→
`entry-conditions.sh::should_dispatch` → `gh pr view`) every tick for each
predicate-ready build-wait, even when slots are full. Bounded (few concurrent
build-waits; one `gh pr view` each) and necessary for correctness. The common
all-held busy case is otherwise unchanged, and the inbox Linear call is still
skipped when held is full.

### WIP-cap reasoning

The per-tick dispatch cap (`_max_decisions` = K) is unchanged. Inbox admission
(the only candidate class that *raises* WIP by promoting a fresh issue into
`stage:*`) is still bounded: inbox `stage_index = -1` means it only enters the
top-K when held + ready-wait candidates number fewer than K — i.e. when
in-flight `stage:*` work is below K. Dispatching a `wait` does not raise WIP
(the issue already carries a `stage:*` label). So the change does not relax
the existing WIP behavior.

## Testing (TDD)

New/extended fixtures in `bin/poll-slot-test.sh` (the picker classifier +
pool test surface):

1. **Regression (drives the fix):** classified input = 2 held `planning`
   (distinct priorities) + 1 predicate-ready `building` wait, `K=2` → assert
   the emitted decisions include the `building` wait and the higher-priority
   `planning` held; the lower-priority planning held is deferred. Fails on
   current code (wait excluded), passes after the fix.
2. **Predicate gate preserved:** a `building` wait whose predicate is **not**
   ready is still excluded and still logs
   `wait_recallable skipped (predicate not ready)`.
3. **Common-case regression guard:** 2 held, no ready waits, `K=2` → still
   dispatches exactly the 2 helds, unchanged.
4. **Inbox admission unchanged:** inbox candidate admitted only when
   `held_count < K`; with K helds present, inbox is not promoted.

Stub `_picker_predicate_ready` / `entry-conditions.sh` in the test harness so
no real `gh`/Linear calls fire (consistent with existing `poll-slot-test.sh`
stubbing).

Run the full `bin/*-test.sh` sweep (the pre-commit gate) green before commit.

## Out of scope

- Anti-starvation / fairness guard (explicitly declined).
- Broader `_picker_build_pool` / Pass 3 held-selection refactor.
- Any change to `_poll_classify_labels` slot contract (ENG-90) or
  `_picker_predicate_ready` semantics.

## Acceptance criteria

1. Unified picker dispatches the more-advanced *workable* candidate first
   across the held/wait/inbox boundary, sorted by the documented key, capped
   at K.
2. Regression fixture (test 1 above) committed and green.
3. Common-case guard (test 3) green — no change when no ready waits exist.
4. Predicate-not-ready wait still excluded + logged (test 2).
5. Inbox still admitted only when `held_count < K` (test 4).
6. CLAUDE.md "Failure-mode quick reference" row updated to reflect the
   corrected behavior (remove the implication that ENG-91 fully resolved it).
7. Full `bin/*-test.sh` suite passes.

## References

- `bin/poll.sh::_picker_build_pool` (~L459–525, gate at ~L470); Pass 4U
  (~L668); `main()` decision loop + `_max_decisions` (~L626, ~L740).
- ENG-91 (unified Pass 4U picker — incomplete fix).
- ENG-90 slot-occupancy contract (`_poll_classify_labels`, `wait_recallable`).
- ENG-81 (`max_concurrent_features`, per-tick K, WIP cap).
- Incident: 2026-06-10 ENG-154 / ENG-119 build-stage starvation behind
  ENG-156 / ENG-150.
