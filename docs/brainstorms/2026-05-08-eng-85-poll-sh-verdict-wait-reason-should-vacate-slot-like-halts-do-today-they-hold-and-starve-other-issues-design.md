---
linear: ENG-85
title: poll.sh — `verdict wait reason=*` should vacate slot like halts do; today they hold and starve other issues
date: 2026-05-08
status: draft
---

# `verdict wait` vacates the slot — and a low-priority Pass 6 in `poll.sh::main` keeps the wait issue progressable when the queue is empty

## 1. Overview (and the load-bearing surprise)

`bin/poll.sh::_poll_classify_labels` (verified at
`bin/poll.sh:207-284`) is the slot-classification surface. It maps an
issue's `(label set, fresh verdict marker)` pair to one of three slot
outcomes:

| Outcome     | Meaning                                                               |
| ---         | ---                                                                   |
| `terminal`  | Issue is `pipeline:abandoned`; ignore entirely                        |
| `vacate`    | Slot is empty; issue does NOT count toward `max_concurrent_features`  |
| `hold`      | Slot is occupied; counts toward the cap; may also be `advanceable`   |

Today, only **labels** can drive an issue to `vacate`:

- `pipeline:abandoned`        → `terminal` (`bin/poll.sh:226-227`)
- `pipeline:paused` / `pipeline:scope-approval-needed` → `vacate`
  (`bin/poll.sh:228-230`)
- `pipeline:halted` + fresh `<!-- pipeline: verdict result=halt -->` marker →
  `vacate` (`bin/poll.sh:231-247`, `pipeline-halt` arm at line 242-243)
- `pipeline:halted` without fresh marker, OR with fresh stage-summary /
  rejection → `hold` (advanceable when stage-summary/rejection)

Crucially, a `<!-- pipeline: verdict result=wait reason=… -->` marker
**without** `pipeline:halted` falls through every branch and lands on
the catch-all `else` at line 280:

```bash
# bin/poll.sh:279-281  (verified)
else
  class='{"slot":"hold","advanceable":true}'
fi
```

That is the path ENG-45's plan §A-004 explicitly relies on
(`bin/poll-slot-test.sh:449-468`):

```bash
# bin/poll-slot-test.sh:457-468  (verified)
write_comments_fixture "ENG-45-WAIT" \
  '<!-- pipeline: transition from=implementing to=building -->|2026-04-28T08:00:00Z' \
  '<!-- pipeline: verdict result=wait reason=awaiting-approval -->|2026-04-28T08:17:00Z'

out="$(_poll_classify_labels "ENG-45-WAIT" '["stage:building"]')"
slot="$(jq -r '.slot // ""' <<<"$out")"
adv="$(jq -r '.advanceable // ""'  <<<"$out")"
if [[ "$slot" == "hold" && "$adv" == "true" ]]; then
  pass_at "ENG-45 poll-slot: pipeline-wait re-dispatches via else branch (hold,advanceable=true)"
```

So a wait-shaped issue is `slot:"hold"` and counts toward
`max_concurrent_features`. This is what causes the starvation the issue
documents.

**The load-bearing surprise.** Two waiting issues already saturate
today's `max_concurrent_features=2` cap. The poller's Pass 4 dispatch
loop (`bin/poll.sh:439-472`) iterates the held set in
`(stage_index desc, priority desc)` order and dispatches the first
advanceable candidate. ENG-77 at `stage:building` (stage_index=6) wins
that sort against ENG-79 at `stage:qa` (stage_index=5), so ENG-77 gets
re-dispatched into a wait it just emitted, and ENG-79 starves out of
Pass 4 entirely. Pass 5's inbox-pickup gate at line 475 then sees
`held_count >= max_concurrent` and `idle`s with reason
`max-concurrent-reached`. Net effect for the operator: ~45 min of
wall-clock spent re-dispatching the wait issue to verify a pending
external signal that has not changed, while ready work on a sibling
issue silently waits.

ENG-81 (K=2 parallel dispatch — separate ticket) does NOT close this:
two slots saturated by two waiting issues still starve a third ready
issue. The fix has to be at the slot-classification layer, not the
dispatch-fanout layer. That is what this ticket is.

**Asymmetry with halts.** `pipeline:halted` (since ENG-20) vacates a
slot precisely to free other ready work to run. The wait shape's
operational character — *agent-not-running, idling on an external
signal* — is the same. Only the labeling differs (halts apply a label;
waits use a marker shape). The slot accounting should match.

## 2. Goals

After this ticket lands:

1. **Wait vacates the slot** (D-002). An issue whose latest verdict
   newer than the most recent transition is `result=wait reason=*` is
   classified as `slot:"vacate"`, advanceable=false, and is annotated
   with `wait_recall=true` so Pass 6 can find it. It does not count
   toward `max_concurrent_features`.

2. **Wait is still progressable when nothing else is ready** (D-003).
   A new Pass 6 in `main()` runs after Pass 5's inbox-pickup gate. If
   no held issue dispatched, no inbox issue picked, AND
   `held_count < max_concurrent`, Pass 6 selects the highest-priority
   wait-recallable issue (ties broken by `wait_progress_ts` ascending
   — FIFO fairness) and emits a dispatch decision for it. The
   `external_signal_budget` re-dispatch path (ENG-45) keeps working
   through this Pass 6 path, just at a slower attempt cadence (see §8
   Edge cases — interaction with `external_signal_budget`).

3. **Test-pinned regression coverage** (D-004). `bin/poll-slot-test.sh`
   gains four new fixtures covering: the wait→vacate classification
   (replaces the existing ENG-45 `[stage:building]` assertion at
   line 449-468), the slot-cap-vacated property (a sibling ready issue
   wins Pass 4 when one slot is wait-shaped), the Pass 6 fallback
   (wait issue eventually advances when no other ready work), and the
   priority/FIFO sort key (two waits, higher-priority + older one
   wins).

Non-goals (explicit, follow the issue's framing):

- **Per-stage entry-condition predicate check on re-dispatch.** That is
  ENG-86 (sibling structural ticket). ENG-85 frees the slot; ENG-86
  closes the re-dispatch wall-clock with a cheap orchestrator-side
  predicate check before invoking the agent. Either ticket ships
  independently. Issue body §"Interaction with ENG-86" is explicit:
  *"Either ticket is shippable independently; the wall-clock saving
  is mostly from ENG-86 (the cheap check vs the 2-min dispatch). This
  ticket alone unblocks parallel-issue progress."*

- **Reconciling `external_signal_budget.max_attempts` semantics with
  the new attempt cadence.** Today, `_handle_wait`
  (`bin/run-stage.sh:543-558`) increments `attempts` once per
  re-dispatch. Post-ENG-85 the re-dispatch cadence drops (only when
  Pass 6 picks the wait), so attempts grow more slowly in wall-clock
  time. `max_minutes` (the wall-clock arm of the same budget) still
  works unchanged. Documented as an edge case in §8; not a defect.

- **Generalising "wait" to other stages.** Per ENG-54 the wait shape is
  build-only at the agent layer (`_fresh_wait_reason`'s case at
  `bin/run-stage.sh:312-315` allow-lists `building`). The new poll-side
  detector (D-001 — `find_fresh_wait_verdict`) is not stage-gated for
  defense in depth (a future stage that emits wait would Just Work),
  but the issue body's scope is specifically build's awaiting-approval
  / awaiting-ci waits. No change to `_fresh_wait_reason`'s allow-list.

- **Caching `get-comments` across the per-tick classify pass.** Pass 2
  already calls `find_fresh_verdict` once per halted issue
  (`bin/poll.sh:233`). This brainstorm adds one more `get-comments`
  call per non-halted issue (D-001's invocation in
  `_poll_classify_labels`'s new branch). At today's per-tick volumes
  (~2-3 stage-labeled issues), that is +2-3 Linear API calls per tick,
  well below noise. A future optimization would push `get-comments`
  through a per-tick memoized fetch — recorded as O-1 in §11.

## 3. Architectural principle

There is no `docs/VISION.md`, `docs/ARCHITECTURE.md`, or
`docs/knowledge/decisions.md` (verified: `ls docs/` returns
`brainstorms/  pipeline-vocabulary.md  pipeline-vocabulary.template.md
plans/  runbooks/`). Governing constraints come from `CLAUDE.md`,
`learned-rules/harness/project-profile.md`, and accepted brainstorms
— same regime ENG-67/ENG-78/ENG-79 documented.

Principles invoked here are existing CLAUDE.md commitments, not new
ones:

- **Slot accounting expresses agent activity, not labels.** Today the
  slot accounting derives from labels (`pipeline:halted` etc.). ENG-85
  surfaces the implicit invariant: an *agent that is not actively
  doing work* should not occupy a slot. Halt and wait both express
  agent-idle-on-external-event, just at different layers (label vs
  marker). Symmetric treatment is the right answer. CLAUDE.md
  "Failure-mode quick reference" already states the halt-vacate
  contract: *"Per-issue halt […] Other issues continue to be polled —
  do NOT touch `orchestrator.paused`."* This brainstorm extends that
  contract to wait.

- **Closed event vocabulary is the source of truth.** The wait shape's
  reason is constrained by `bin/pipeline-events.json::wait_reasons` to
  `{"awaiting-approval", "awaiting-ci"}`. D-001's `find_fresh_wait_verdict`
  reads `event.reason` directly from `parse_pipeline_marker`'s output
  and trusts the registry's allow-list (write-time validation in
  `bin/pipeline.sh::event` already enforces this — out of scope to
  re-validate at read time).

- **Symmetric defense across the slot-classification surface.**
  ENG-67's brainstorm §3 establishes that when an invariant is
  enforced at one layer, the adjacent layer should also have a test
  pinning that no equivalent path exists in *that* layer. Today the
  invariant "agent-idle-on-external-signal vacates the slot" is
  pinned at one layer (halts via labels). ENG-85 extends it to the
  marker-driven wait shape. The poll-slot-test fixture coverage
  matches: AC-2 (halt-for-human vacates) is the paired test for the
  new AC-WAIT-1 (wait vacates).

- **`die` over silent fallback (defense in depth).** `find_fresh_wait_verdict`
  fails closed: when `get-comments` fails or returns empty, it returns
  empty string and the caller falls through to the existing
  classification (else branch, hold/advanceable=true). This is exactly
  the same pattern `find_fresh_verdict` uses at
  `bin/verdict-handler.sh:88` (`[[ -z "$comments" || "$comments" ==
  "null" ]] && { printf ''; return 0; }`). Failing closed in
  `_poll_classify_labels` means a transient Linear-API outage
  degrades to *the pre-ENG-85 behavior* — not to a worse failure mode
  — and the next tick re-attempts.

- **Keep the existing pass discipline.** `main()`'s
  Pass 1-2-2b-3-4-5-idle structure is load-bearing; ENG-78 and ENG-26
  brainstorms both rely on its ordering. D-003 inserts a single new
  Pass 6 BETWEEN Pass 5 and `idle "no-work"` — does not reorder,
  rename, or merge any existing pass.

## 4. Decisions

### D-001: New helper `find_fresh_wait_verdict` in `bin/verdict-handler.sh`

**Verdict.** Add a sibling helper to `find_fresh_verdict` that mirrors
its freshness logic but returns the latest wait verdict (when the
latest verdict in the post-transition window IS a wait) or empty
(when the latest is `pass`/`fail`/`halt`/`pivot`, or no verdict at all).
Output JSON shape: `{reason, comment_id, created_at}` or empty string.

```bash
# bin/verdict-handler.sh (new helper, sits next to find_fresh_verdict at line 84)
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

  # Stage 1: most recent transition timestamp (freshness floor) — same
  # algorithm as find_fresh_verdict at bin/verdict-handler.sh:91-101.
  local last_transition_ts="" ts body ev
  while IFS=$'\t' read -r ts body; do
    ev="$(parse_pipeline_marker "$body" 2>/dev/null || true)"
    [[ -z "$ev" ]] && continue
    if [[ "$(jq -r '.event' <<<"$ev")" == "transition" ]]; then
      [[ "$ts" > "$last_transition_ts" ]] && last_transition_ts="$ts"
    fi
  done < <(jq -r '.[] | "\(.createdAt)\t\(.body | gsub("\n"; " "))"' <<<"$comments")

  # Stage 2: latest verdict (any result) newer than the transition.
  # ENG-61 Bug B rule: only return wait if it IS the latest verdict; a
  # later pass/fail/halt/pivot supersedes the wait.
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

Append `find_fresh_wait_verdict` to the `export -f` line at
`bin/verdict-handler.sh:407` so direct callers (tests, future
helpers) can use it without re-sourcing.

**Why this rather than extending `find_fresh_verdict` with a
parameter.** Three reasons:

1. **Single-responsibility sibling.** `find_fresh_verdict` is
   *deliberately* wait-blind — its caller is `verdict_handler`, which
   transitions on actionable verdicts only (`bin/verdict-handler.sh:113`
   `[[ "$(jq -r '.result' <<<"$ev")" == "wait" ]] && continue`). Adding
   a parameter would put the wait-handling decision inside the
   helper; a sibling helper keeps each function's concern clean.
2. **No risk of accidental opt-in.** If `find_fresh_verdict` grew an
   `--include-wait` flag, a future caller copy-pasting from the wrong
   call-site could enable it inadvertently and treat a wait as an
   actionable transition target — exactly the failure mode ENG-61
   Bug B closed.
3. **Symmetry with `_fresh_wait_reason`.** The agent-side wait
   detector is also a separate function (`bin/run-stage.sh:310-364`),
   not a flag on a verdict-detection function. ENG-85 mirrors that
   shape on the orchestrator side.

**Rejected alternative — call `_fresh_wait_reason` from poll.sh.**
`_fresh_wait_reason` (`bin/run-stage.sh:310-364`) is build-only by
contract (case statement at line 312-315); calling it from poll.sh
would either (a) copy/paste-and-modify the body — guaranteed
drift — or (b) widen its scope and break the security F-1 gate
ENG-45 D-? established. The implementation overlap is large but the
*contract* is different: `_fresh_wait_reason` answers "should the
build agent honor a wait?" whereas `find_fresh_wait_verdict` answers
"is this issue currently in a wait?" Different audiences, different
gates. Rejected.

**Rejected alternative — store the wait state in
`$(issue_dir <ident>)/wait-<stage>.json`** (which `_handle_wait`
already writes at `bin/run-stage.sh:540`) and have poll.sh read it
to detect waits. Cheaper (one stat() call vs one Linear API call per
issue), but: (a) the file is removed by `_handle_wait` itself when
the budget exhausts (line 571), so during the halt path there's a
tick-window race where the file is gone but the halt label is not yet
applied; (b) a manual operator who flips state via `pipeline.sh
decide` does not touch the wait file, so the file becomes
out-of-sync with the canonical Linear state; (c) couples poll.sh to
run-stage.sh's private file format. Rejected — Linear comments are
the canonical source for state-driving events (CLAUDE.md "Linear
conventions the harness depends on" §). The file is run-stage.sh's
private bookkeeping for the budget counter.

### D-002: `_poll_classify_labels` adds a fresh-wait branch between halted and reviewing

**Verdict.** Insert a new branch after the halted check at
`bin/poll.sh:247` and before the reviewing check at line 248:

```bash
# bin/poll.sh:248- (new branch, pre-existing branches at 226-247 unchanged)
elif fresh_wait="$(find_fresh_wait_verdict "$ident" 2>/dev/null)"; [[ -n "$fresh_wait" ]]; then
  # ENG-85: a wait verdict newer than the most recent transition vacates
  # the slot. Symmetric with the pipeline-halt arm at line 242-243 — both
  # express agent-idle-on-external-signal. Pass 6 in main() picks
  # wait-recallable issues only when no held / inbox work is ready.
  local _wait_ts
  _wait_ts="$(jq -r '.created_at' <<<"$fresh_wait")"
  class="$(jq -nc --arg ts "$_wait_ts" \
    '{slot:"vacate", advanceable:false, wait_recall:true, wait_progress_ts:$ts}')"
elif [[ "$(_has_label stage:reviewing)" == "true" ]]; then
  # ... existing reviewing branch (unchanged) ...
```

**Why between halted and reviewing.** Order is load-bearing:

- BEFORE halted: a `pipeline:halted` label combined with a fresh wait
  is impossible by current contract — wait emission paths
  (`_handle_wait` at `bin/run-stage.sh:485-578`) never apply
  `pipeline:halted` (only the budget-exhausted halt path does, line
  570). Defensive: even if such a state slipped through, the halt
  arm's `vacate` outcome is the same as ours.
- BEFORE reviewing: per ENG-54, review is agent-only — never waits.
  The `_fresh_wait_reason` allow-list at `bin/run-stage.sh:312-315`
  rejects review-stage waits. Defensively, if a wait somehow appeared
  on a reviewing-stage issue, vacating is still safer than re-dispatching
  the review agent into a stale wait.
- Above the catch-all `else`: the previously-failing case
  (ENG-45-WAIT test). The wait now diverts BEFORE the
  `hold/advanceable=true` default, ending the starvation loop.

The new branch fires on ANY non-halted, non-paused, non-abandoned issue
when `find_fresh_wait_verdict` returns non-empty. Since the helper is
non-stage-gated, this is defense-in-depth coverage for any future stage
that emits wait. Today only `building` does (per ENG-54 / ENG-45).

**Why annotate with `wait_recall=true` and `wait_progress_ts`.** Pass 6
needs to: (a) find wait-recallable issues among all classified items,
(b) sort them by priority + age. Stuffing the metadata on the
classified item itself avoids a second pass over the data. The keys are
prefixed `wait_*` to avoid collision with any future per-issue
classification fields and to make the grep easy.

**Rejected alternative — overload `slot:"vacate"` and re-derive
recall-eligibility from comments later.** Pass 6 would have to call
`find_fresh_wait_verdict` again for every vacated issue (O(N) extra
Linear API calls per tick). Rejected — annotate-once is cheap and
clear.

**Rejected alternative — introduce a new slot value `slot:"wait"`** on
top of `terminal/vacate/hold`. The slot enum is consumed by
`_poll_emit_halt_sprawl_alert`'s `select(.slot == "vacate")` filter
(`bin/poll.sh:346`), Pass 3's `select(.slot == "hold")` filter
(`bin/poll.sh:428`), and the test fixtures. Adding a fourth value
forces every consumer to learn it. Pure metadata addition
(`wait_recall:true`) leaves the slot enum alone; consumers that don't
care about wait-recall ignore the new field by jq filter. Rejected
— slot expansion has higher blast radius than a side-channel field.

**Rejected alternative — fail-open on `find_fresh_wait_verdict` error**
(if get-comments fails, treat the issue as wait-vacated to avoid
re-dispatching into a stuck wait). Rejected because the symmetric
rule applied to halted issues (`bin/poll.sh:234` —
`if [[ -z "$fresh" ]]; then class='{"slot":"hold","advanceable":false}'`)
falls through to a non-vacating class on read failure. Both should
behave the same: read failure → preserve previous-tick semantics →
next tick re-attempts. Aligning with the existing convention is
strictly better than diverging.

### D-003: New Pass 6 in `main()` — wait re-pickup as last resort

**Verdict.** Restructure `main()`'s Pass 5/idle ordering to insert
Pass 6 between the inbox-pickup attempt and the final `idle "no-work"`:

```bash
# bin/poll.sh::main (post-ENG-85 — Pass 5/6/idle reshape)

# Pass 5: inbox pickup, only if a slot is available.
local inbox_pick=""
if (( held_count < max_concurrent )); then
  local inbox_state
  inbox_state="$(config_get '.linear.native_states.inbox')"
  inbox_pick="$(bash "$SCRIPT_DIR/linear.sh" list-issues-in-state "$inbox_state" \
    | jq -r '<existing filter — unchanged from current bin/poll.sh:483-493>')"
  if [[ -n "$inbox_pick" ]]; then
    jq -nc \
      --arg issue_id "$inbox_pick" \
      --arg stage "brainstorming" \
      --arg reason "inbox pickup" \
      '{issue_id:$issue_id, stage:$stage, entry_action:"apply-stage-label", reason:$reason}'
    exit 0
  fi
fi

# Pass 6 (ENG-85): wait re-pickup as last resort. Only fires when no held
# was dispatched (Pass 4), no inbox issue picked (Pass 5), AND there is
# slot capacity. Sort: priority desc, then wait_progress_ts asc (FIFO
# fairness — older waits go first).
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
```

Two structural changes to existing Pass 5/idle:

1. **Move the `held_count >= max_concurrent` cap check BELOW Pass 5
   and Pass 6** (current `bin/poll.sh:475-477`). Today's order is "if
   cap reached → idle; else → inbox check". Post-fix: "Pass 5 if cap
   not reached; Pass 6 if cap not reached; else terminate." The
   `max-concurrent-reached` idle reason is preserved by the
   final-else guard, so observability is unchanged.
2. **Inline the inbox query inside the cap-conditional block.** Pre-fix,
   `inbox_pick` was always computed; post-fix, it's only computed
   when `held_count < max_concurrent`. Saves one Linear API call per
   tick when the cap is full. Side effect of the structural reshape;
   not user-facing.

**Why this sort key (priority desc, then wait_progress_ts asc).**
Issue body §"Risks" specifies it explicitly: *"Re-pickup ordering: wait
issues should be deprioritized vs fresh ready work but not deprioritized
below other waits, otherwise FIFO fairness breaks. Sort key: priority,
then last-progress-timestamp ascending."* `wait_progress_ts` is the
createdAt of the wait verdict marker (set by D-001) — not the
last-transition-ts — because:

- The wait verdict's createdAt is the closest available proxy for
  "when did this issue start its current wait." It updates each time
  the agent re-emits a wait (e.g., after Pass 6 re-dispatches and the
  agent emits another wait — that issue's `wait_progress_ts` advances,
  so it goes to the back of the FIFO line on the next tick).
- The transition timestamp would also work but is invariant across
  re-dispatches at the same stage, so two issues that transitioned
  into stage:building near each other and stayed there would always
  have the same sort order regardless of which one was just
  re-dispatched. The wait timestamp gives natural round-robin
  rotation.

**Why guard Pass 6 with `held_count < max_concurrent`.** A wait issue
has slot:"vacate" — it is not in `held` and does not contribute to
`held_count`. But if `held_count` is already at the cap (i.e., 2
non-wait issues are actively running), dispatching a third agent for
the wait issue would over-cap. The guard preserves the
`max_concurrent_features` invariant.

**Rejected alternative — Pass 6 BEFORE Pass 5 (inbox).** Inverted
priority: wait re-pickup wins over fresh inbox work. Rejected because
the issue body's framing — *"wait issues should be deprioritized vs
fresh ready work"* — is explicit. Inbox pickup represents fresh ready
work that hasn't started yet; a wait is an in-flight idle. Fresh wins.

**Rejected alternative — Pass 6 BEFORE Pass 4 (held dispatch).**
Wait re-pickup wins over advanceable held issues. Rejected for the
same reason — *"deprioritized vs fresh ready work"*. A held
advanceable issue (e.g., ENG-79 at stage:qa) has the agent ready to
run; a waiting issue's agent has nothing new to do. Held wins.

**Rejected alternative — Pass 6 only fires every Nth tick (rate-limited
re-dispatch).** Reduces wall-clock and Linear-API cost when the wait
queue is the only work. Rejected because (a) Pass 6 is already gated
by "no other ready work," so it only fires on otherwise-idle ticks —
the cost is bounded; (b) `external_signal_budget.max_minutes` already
provides the wall-clock bound on a stuck wait; (c) adding a new
rate-limit knob means a new config schema field with its own
edge cases. The simpler design is correct.

### D-004: Test fixture coverage in `bin/poll-slot-test.sh`

**Verdict.** Four new test fixtures, plus an inversion of the existing
ENG-45 fixture.

1. **AC-WAIT-1 (replaces ENG-45 line 449-468).** A wait verdict on
   a `[stage:building]` issue → `slot:"vacate"`,
   `advanceable:false`, `wait_recall:true`. The pre-ENG-85 assertion
   (`hold/true`) is now the failure mode this test guards against.
2. **AC-WAIT-2 (slot vacated).** `_poll_gather_stage_labeled_issues`
   returns ENG-A (stage:building, fresh wait) and ENG-B (stage:qa,
   no markers). `max_concurrent_features=2`. After Pass 2, ENG-A is
   `vacate` and ENG-B is `hold`. After Pass 3, `held_count == 1`.
   After Pass 4, ENG-B's stage is dispatched (not ENG-A, which is
   the regression scenario from the issue body's "Observed" section).
3. **AC-WAIT-3 (Pass 6 fallback).** ENG-A (stage:building, fresh
   wait) is the ONLY classified issue, and the inbox is empty. Pass
   4: nothing to dispatch (held is empty after vacate). Pass 5:
   no inbox pickup. Pass 6: ENG-A is dispatched with reason
   `wait re-pickup at stage:building (no other ready work)`.
4. **AC-WAIT-4 (Pass 6 sort key — priority + FIFO).** Two wait issues:
   ENG-A (stage:building, priority=Urgent, wait at 10:00:00Z) and
   ENG-B (stage:building, priority=Urgent, wait at 10:05:00Z). Pass 6
   picks ENG-A (older wait wins on FIFO tiebreak).
5. **AC-WAIT-5 (Pass 6 priority dominates FIFO).** Two wait issues:
   ENG-A (priority=Normal, wait at 10:00:00Z), ENG-B (priority=Urgent,
   wait at 10:05:00Z). Pass 6 picks ENG-B (Urgent wins regardless of
   FIFO).

Plus a regression pin for ENG-45's `external_signal_budget` hand-off
(AC-WAIT-6): when the issue carries `pipeline:halted` AND a fresh
`<!-- pipeline: verdict result=halt reason=external-signal-budget-exhausted -->`
marker, the existing `pipeline-halt` arm at `bin/poll.sh:242-243` fires
(slot=vacate, advanceable=false), and the new wait branch does NOT —
because `find_fresh_wait_verdict` returns empty when the latest verdict
is halt (the supersession rule from ENG-61 Bug B). This pins the
hand-off boundary that the issue's "Acceptance" §4 names: *"ENG-45
external_signal_budget escalation path still works (wait →
halt-for-budget-exhausted → existing halt vacate)."*

**Why these fixtures and not behavioral tests of `main()`.** Three
of them (AC-WAIT-2/3/6) DO exercise `main()` via the existing
`out="$(main 2>/dev/null || true)"` pattern. AC-WAIT-1/4/5 are
pure classification asserts on `_poll_classify_labels`. The split
mirrors the existing test file's structure (e.g., AC-1 hits main(),
ENG-50 cases hit `_poll_classify_labels` directly). No new test
infrastructure required — the existing `write_label_fixture`,
`write_comments_fixture`, `write_inbox_fixture` helpers handle
every shape.

**Rejected alternative — only test `_poll_classify_labels`** (skip
`main()` integration tests for AC-WAIT-2/3). Rejected because the
*starvation* failure mode is at the main() level, not at the
classifier — AC-WAIT-2 is the literal regression test for the
issue body's "ENG-79 starved 45 min" scenario. Skipping it would
leave the integration regression unpinned.

**Rejected alternative — replace existing ENG-45 fixture in place
without renaming.** The ENG-45 fixture's purpose was to pin the
soft-redispatch contract for waits. ENG-85 changes the contract:
wait now vacates AND is recallable via Pass 6. The fixture's body
must be inverted (slot=vacate, not slot=hold) AND its comment
should be updated to reference ENG-85's new semantics rather than
ENG-45's. Renaming `ENG-45-WAIT` to a new label (e.g., `ENG-85-WAIT-CLASSIFY`)
is cleaner than overwriting in place — readers grepping for ENG-45
context still find the vestigial pin's history in `git blame`.
Net: replace the ENG-45 case with AC-WAIT-1, leave a one-line
comment citing the prior assertion's death.

## 5. Architecture (where code goes)

Three files modified, no new files:

| File | Change | Lines |
|---|---|---|
| `bin/verdict-handler.sh` | Add `find_fresh_wait_verdict` helper next to `find_fresh_verdict` (~line 84). Append to `export -f` list at line 407. | net +47 (function +44, export +3) |
| `bin/poll.sh` | (a) New `elif fresh_wait="$(find_fresh_wait_verdict ...)"; …` branch in `_poll_classify_labels` between the halted arm (line 247) and the reviewing arm (line 248). (b) Restructure `main()`'s Pass 5/idle: move cap-check to bottom, inline inbox query, add Pass 6. | net +30 (classify +6, main reshape +24) |
| `bin/poll-slot-test.sh` | Replace ENG-45 fixture (line 449-468) with AC-WAIT-1, add AC-WAIT-2 through AC-WAIT-6. Reuse existing fixture-builder helpers. | net +110 (replace -19, add 5 cases × ~26) |

Optional fourth file: a tiny update to `bin/verdict-handler-test.sh`
asserting `find_fresh_wait_verdict` returns empty for issues with no
wait (sanity); deferred as O-2 in §11 — the new helper is exercised
end-to-end through `bin/poll-slot-test.sh::AC-WAIT-1`, which is
sufficient for the regression pin.

No new files, no new scripts, no new dependencies. No prompt or config
changes (issue body's "Scope" §). The data flow through
`_poll_classify_labels` is unchanged for halted/paused/abandoned/reviewing
branches — only the pre-existing else fall-through is now diverted
when a fresh wait exists.

## 6. Data flow

Pre-ENG-85, classifier path for an issue at stage:building with fresh
wait:

```
_poll_classify_labels(ENG-N, ["stage:building"])
  └─ has pipeline:abandoned? → no
  └─ has pipeline:paused / scope-approval? → no
  └─ has pipeline:halted? → no
  └─ has stage:reviewing? → no
  └─ else → {slot:"hold", advanceable:true}     ← drift point
```

The issue then:
- counts toward held_count (Pass 3),
- wins Pass 4's sort against same-priority issues at earlier stages,
- consumes a dispatch slot to re-emit the same wait,
- starves any sibling held issue.

Post-ENG-85, classifier path for the same issue:

```
_poll_classify_labels(ENG-N, ["stage:building"])
  └─ has pipeline:abandoned? → no
  └─ has pipeline:paused / scope-approval? → no
  └─ has pipeline:halted? → no
  └─ find_fresh_wait_verdict(ENG-N) → {reason:"awaiting-approval",
                                        comment_id:"...",
                                        created_at:"2026-05-08T08:17:00Z"}
                                  → {slot:"vacate",
                                     advanceable:false,
                                     wait_recall:true,
                                     wait_progress_ts:"2026-05-08T08:17:00Z"}
  └─ (reviewing / else not reached)
```

The issue then:
- does NOT count toward held_count (Pass 3 filters slot=="hold"),
- is excluded from Pass 4's iteration,
- frees a slot for sibling held issues at earlier stages,
- becomes a Pass 6 candidate; picked iff no other ready work AND
  `held_count < max_concurrent`.

Pass 6 dispatch path:

```
main()
  └─ Pass 4: no held advanceable issue dispatched
  └─ Pass 5: no inbox pickup
  └─ Pass 6:
       held_count < max_concurrent?
         └─ jq filter: select(.slot == "vacate" and .wait_recall == true)
         └─ sort_by([-(.priority_sort_rank), .wait_progress_ts])
         └─ .[0]
         └─ emit dispatch decision { issue_id, stage, entry_action:"run",
                                     reason:"wait re-pickup at <label> (no other ready work)" }
         └─ exit 0
```

Two failure modes, both intentionally fall through to existing behavior:

1. **`find_fresh_wait_verdict` returns empty on Linear-API outage.**
   Get-comments error → printf '' → caller's `[[ -n "$fresh_wait" ]]`
   guard fails → reviewing/else branch fires → pre-ENG-85 behavior
   (hold/advanceable=true → re-dispatch). Symmetric with
   `find_fresh_verdict`'s read-failure handling at
   `bin/verdict-handler.sh:88`.

2. **No wait-recallable issues for Pass 6.** jq `.[0] // empty`
   yields empty → Pass 6 fall-through → `idle "no-work"` (or
   `max-concurrent-reached` if cap is full, via the final-else
   guard).

## 7. Error handling

- **Linear API outage during classification** → `find_fresh_wait_verdict`
  fails closed (returns empty); the classifier falls through to the
  existing else branch, producing the pre-ENG-85 hold/advanceable
  behavior. The issue is re-dispatched on the current tick — same as
  today. Next tick re-attempts the wait detection. No new failure
  surface.

- **Non-monotonic Linear timestamps.** `find_fresh_wait_verdict`'s
  freshness comparison uses string `>` on createdAt, which is
  lexicographically valid for ISO-8601 UTC strings (the format Linear
  emits — verified against `bin/poll-slot-test.sh::write_comments_fixture`
  fixtures that use `2026-04-28T08:17:00Z`-style timestamps). Any
  malformed timestamp would silently fail the `>` comparison and that
  marker would be ignored. Same robustness profile as
  `find_fresh_verdict` and `_fresh_wait_reason`. No new failure
  surface.

- **Multiple wait verdicts in the same window.** Possible (today's
  re-dispatch model creates one per tick). `find_fresh_wait_verdict`
  takes the LATEST (max ts) — its `wait_progress_ts` is the most
  recent wait timestamp. FIFO ordering on this is "most-recently-waited
  goes last," which is exactly the round-robin behavior we want.

- **Wait verdict superseded by halt before next tick.** Possible if
  `_handle_wait`'s budget exhausts mid-tick (`bin/run-stage.sh:546-557`).
  `find_fresh_wait_verdict`'s ENG-61 Bug B rule (line `[[ "$fresh_result"
  != "wait" ]] && return empty`) handles this correctly: the latest
  verdict is `halt`, not `wait`, so the wait branch is not taken; the
  issue's `pipeline:halted` label is now present, and the existing
  halted arm at `bin/poll.sh:231-247` takes over.

- **A wait issue's stage:* label changes between ticks.**
  `find_fresh_wait_verdict` answers per-issue based on the comment
  history; it does not look at labels. If the agent transitioned the
  issue (e.g., via a fresh pass verdict) before the next tick, the
  freshness floor (last_transition_ts) advances past the old wait, and
  the wait is no longer "fresh." Returns empty. Correct behavior.

- **Pass 6 dispatches a wait issue, agent immediately emits another
  wait.** Same wall-clock budget as today's tick-rate
  (one re-dispatch per tick when no other work). The
  `external_signal_budget.attempts` counter increments once per
  re-dispatch (`bin/run-stage.sh:530`); when no other work, attempts
  grow at the same rate as today. When other work is ready (the common
  case), attempts grow more slowly. `max_minutes` is unchanged —
  wall-clock-driven. See §8 Edge cases.

## 8. Edge cases

- **`external_signal_budget.max_attempts` exhausts more slowly.**
  Pre-ENG-85: build-stage wait re-dispatched on every tick. With
  `max_attempts=5`, halt fires after 5 ticks (≈25 min). Post-ENG-85:
  build-stage wait re-dispatched only on ticks where Pass 6 fires
  (i.e., no other ready work). If sibling work is available
  continuously, attempts may stay at 1 indefinitely; only `max_minutes`
  triggers escalation. This is **expected and acceptable** — the issue
  body's "Acceptance" §4 explicitly preserves the budget hand-off:
  *"ENG-45 external_signal_budget escalation path still works (wait →
  halt-for-budget-exhausted → existing halt vacate)."* Operators who
  previously relied on attempt-count escalation should set
  `max_minutes` (already supported per
  `bin/run-stage.sh:548-557`). Recorded as O-3 in §11.

- **The wait issue is the highest-priority work AND there is sibling
  ready work.** Pass 4 picks the sibling (held, advanceable) per the
  current sort `[-stage_index, -priority_sort_rank]`. Wait issue is
  not in held, so it loses Pass 4 categorically — which is the
  correct behavior. The wait priority is honored in Pass 6 only
  among other waits.

- **All slots are wait, nothing in inbox.** Two issues at
  `verdict wait`, no other work. Pass 4: nothing held. Pass 5:
  no inbox. Pass 6 fires: highest-priority wait (or earliest, on
  priority tie) gets re-dispatched. Next tick: same logic, but the
  *just-re-dispatched* issue's `wait_progress_ts` advanced — it goes
  to the back of the FIFO line. The other wait issue takes its turn.
  Round-robin emerges naturally.

- **Single wait issue, nothing else.** Pass 6 fires every tick.
  Same as today's behavior (re-dispatch every tick). The
  `external_signal_budget` budgets still bound it. No regression.

- **Wait issue at `stage:building` after `pipeline:halted` was applied
  manually by an operator.** The halted arm fires first
  (`bin/poll.sh:231-247`); the new wait branch is unreachable. Halted
  vacate-or-hold semantics apply. Correct.

- **The wait verdict's createdAt is in the future** (clock skew
  between the agent and the local host). `wait_progress_ts` is just
  passed to jq's sort — a future timestamp simply sorts last. No
  crash. Defense from the same class of issue addressed in
  `_handle_wait`'s value-validity guard at `bin/run-stage.sh:518-528`,
  but at much lower stakes here (sort order, not wall-clock arithmetic).

- **`max_concurrent_features = 1` (single-slot mode).** `held_count`
  goes 0/1; cap == 1. Pass 6's `held_count < max_concurrent` guard
  permits one Pass-6 dispatch per idle tick. Same logic as today's
  tick at single-slot mode.

- **Two wait issues, one of which has its `wait_progress_ts`
  identical to the other** (same exact second). FIFO tiebreak
  collapses; jq `sort_by` is stable in jq ≥1.6 (verified —
  every poll.sh fixture uses `sort_by` and assumes stable ordering),
  so original input order from the gather pass wins. Real-world:
  unlikely (Linear timestamps are millisecond-precision). Not worth
  guarding against. Noted as O-4.

- **A wait issue with `pipeline:halted` but no fresh halt marker
  yet** (race between `add-comment` and `add-label` at the budget
  boundary in `_handle_wait`'s line 564-570). The halted arm of
  `_poll_classify_labels` fires (line 231); `find_fresh_verdict`
  may return empty (no halt marker yet) or the still-fresh wait —
  but the new helper `find_fresh_wait_verdict` is NOT called in
  the halted branch (it's the elif AFTER halted). So the result is
  the pre-existing halted-no-marker behavior:
  `slot:"hold", advanceable:false`. Slot accounting is correct
  (issue counts toward cap), and on the next tick after the halt
  marker lands, Pass 4's halted-with-fresh-marker branch fires.
  Race window is one tick (≤5 min). No wait misclassification.

- **An issue with `verdict wait` AND `verdict pivot` (or
  `verdict fail`) in the same post-transition window.**
  `find_fresh_wait_verdict`'s ENG-61 Bug B rule: only returns wait
  when wait IS the latest verdict. Pivot/fail wins as the actionable
  transition target → `find_fresh_verdict` (the pre-existing helper)
  handles it via the halted branch's stage-summary/rejection arm. The
  new wait branch returns empty. Correct.

- **An operator manually posts a `verdict wait` marker via
  `bash bin/pipeline.sh event ENG-N verdict wait --reason ...`.**
  `bin/pipeline.sh::event` validates against the registry's
  `wait_reasons`, then `linear.sh add-comment` posts the marker. Next
  tick: `find_fresh_wait_verdict` sees the operator-posted wait, and
  the issue vacates the slot. This is the intended use case for
  manual wait emission (e.g., paused-on-CI not detected by the agent).
  Correct.

## 9. Persona review

### design — PASS

The fix delegates wait detection to a single new sibling helper
(`find_fresh_wait_verdict`) that mirrors the existing
`find_fresh_verdict` shape. Slot annotation
(`wait_recall`, `wait_progress_ts`) is additive metadata, not a new
slot enum value — keeps the consumer surface small. Pass 6 is
inserted between existing passes, preserving the 1-2-2b-3-4-5 ordering
that other brainstorms (ENG-78, ENG-26) build on. **Verdict: PASS,
no findings.**

### security — PASS

No secret-handling surface touched. `find_fresh_wait_verdict` shells
out to `bash "$_VH_SCRIPT_DIR/linear.sh" get-comments "$issue"` —
identical pattern to `find_fresh_verdict` at line 87. Both pass `$issue`
positionally; no `${VAR:-…}` against secret-named env vars. Pass 6's
sort key is jq-internal; no shell expansion of attacker-controlled
strings. The wait reason is parsed by `parse_pipeline_marker`'s
closed allow-list (verified — `bin/common.sh:192-242`) and stuffed
into a JSON string field; no injection surface into shell argv.
**Verdict: PASS, no findings.**

### scope — PASS

Strictly within the issue's "Scope" section: `bin/poll.sh` (slot
classification + Pass 6) and `bin/poll-slot-test.sh` (new fixtures).
The one file outside that scope — `bin/verdict-handler.sh` — gains a
new helper that `bin/poll.sh` sources via the existing
`source "$SCRIPT_DIR/verdict-handler.sh"` line at
`bin/poll.sh:23`. The issue body's framing of "slot-classification
layer" is interpreted as the path through which classification
happens; adding a sibling helper to the dependency that owns wait
detection elsewhere is consistent. Issue body §"Scope" says *"No
prompt or config changes"* — verified, no `AGENT_PROMPTS.md` or
`.pipeline-config/config.json` changes. **Verdict: PASS, no findings.**

### coherence — PASS

Brainstorm structure follows the pattern of recent ENG-78 / ENG-79
brainstorms — Overview → Goals → Architectural principle → Decisions
→ Architecture → Data flow → Error handling → Edge cases → Persona
review → Open questions → Anti-bias checks → Conflicts. Each decision
cites a CLAUDE.md commitment or a prior brainstorm's precedent. Each
rejected alternative names a specific cost (e.g., "couples poll.sh to
run-stage.sh's private file format"). Decision order is causal: D-001
adds the helper, D-002 uses it, D-003 builds the recall path on top,
D-004 pins the regressions. **Verdict: PASS, no findings.**

### product — PASS

The fix removes a 45-min observed starvation incident (ENG-79
queued behind ENG-77's wait-loop on 2026-05-08). After the fix, Pass 4
dispatches whatever ready work exists; waits get the leftover slot
when nothing else is ready. The operator-visible behavior change is
minimal: the wait issue still gets re-dispatched eventually (Pass 6),
just less often when sibling work is queued. Linear UI shows
exactly the same comment thread. The
`max-concurrent-reached`-vs-`no-work` idle reasons preserve
observability. **Verdict: PASS, no findings.**

### feasibility — PASS (gating)

Codebase-fact verification (every named file, line, function, exit
code, registry value cross-checked against the current worktree —
see §11 Anti-bias / Assumption Inventory):

- `bin/poll.sh:207-284` — `_poll_classify_labels` definition. ✅
- `bin/poll.sh:226-227` — abandoned arm. ✅
- `bin/poll.sh:228-230` — paused / scope-approval arm. ✅
- `bin/poll.sh:231-247` — halted arm (with `find_fresh_verdict`). ✅
- `bin/poll.sh:242-243` — `pipeline-halt` arm sets `slot:"vacate"`. ✅
- `bin/poll.sh:248-278` — reviewing arm (with branch-name + review_should_dispatch). ✅
- `bin/poll.sh:279-281` — catch-all else (current wait fall-through point). ✅
- `bin/poll.sh:399-504` — `main()`. ✅
- `bin/poll.sh:439-472` — Pass 4 dispatch loop. ✅
- `bin/poll.sh:469` — `held slot at $stage_label` reason emit (issue body's reference). ✅
- `bin/poll.sh:475-477` — current cap-check at top of Pass 5. ✅
- `bin/poll.sh:482-493` — current inbox query. ✅
- `bin/poll.sh:494-501` — current inbox dispatch emit. ✅
- `bin/poll.sh:503` — current `idle "no-work"`. ✅
- `bin/poll.sh:23` — `source "$SCRIPT_DIR/verdict-handler.sh"`. ✅
- `bin/verdict-handler.sh:84-143` — `find_fresh_verdict` definition. ✅
- `bin/verdict-handler.sh:88` — empty-comments fall-through. ✅
- `bin/verdict-handler.sh:91-101` — last_transition_ts loop. ✅
- `bin/verdict-handler.sh:113` — wait-exclusion line (existing). ✅
- `bin/verdict-handler.sh:407` — `export -f` line. ✅
- `bin/run-stage.sh:310-364` — `_fresh_wait_reason` definition. ✅
- `bin/run-stage.sh:312-315` — build-only allow-list. ✅
- `bin/run-stage.sh:332-356` — ENG-61 Bug B latest-verdict rule. ✅
- `bin/run-stage.sh:489-578` — `_handle_wait` definition. ✅
- `bin/run-stage.sh:494` — `wait-${stage}.json` file path. ✅
- `bin/run-stage.sh:540` — file-write line. ✅
- `bin/run-stage.sh:546-557` — exhausted check (max_attempts / max_minutes). ✅
- `bin/run-stage.sh:560-575` — exhausted halt-add path. ✅
- `bin/poll-slot-test.sh:449-468` — current ENG-45 fixture (the one to invert). ✅
- `bin/poll-slot-test.sh::write_label_fixture` — line 160-182. ✅
- `bin/poll-slot-test.sh::write_comments_fixture` — line 211-223. ✅
- `bin/poll-slot-test.sh::write_inbox_fixture` — line 186-207. ✅
- `bin/pipeline-events.json::wait_reasons` — `["awaiting-approval", "awaiting-ci"]`. ✅
- `bin/pipeline-events.json::halt_reasons` — `external-signal-budget-exhausted`
  *NOT* present (the registry's halt_reasons are
  `agent-blocked, agent-failure, smoke-failed, iteration-exhausted,
  scope-violation, protocol-violation, dispatch-timeout, pr-opened-too-early`).
  ✅ (relevant: AC-WAIT-6 fixture uses `agent-blocked` or another
  registry-valid reason as the halt reason, NOT
  `external-signal-budget-exhausted`. The actual marker emitted by
  `_handle_wait` at `bin/run-stage.sh:562` IS
  `external-signal-budget-exhausted` — that is a registered drift
  between code and registry, but is OUT OF SCOPE for ENG-85; flagged
  as O-5 in §11.)
- `bin/common.sh:192-242` — `parse_pipeline_marker` definition. ✅
- CLAUDE.md "Single human-approval gate (ENG-54)" § confirms review
  is agent-only, build is the only stage that waits. ✅

All facts referenced are verified. No P0 findings. **Verdict: PASS
(gating).**

## 10. Open questions

- **O-1 (deferred optimization).** Per-tick `get-comments` calls are
  O(N) where N = stage-labeled-non-paused-non-abandoned issues. With
  this brainstorm's change, every non-halted issue at a stage that
  could emit wait calls `find_fresh_wait_verdict`, which makes one
  `get-comments` request. At today's per-tick volumes (~2-3 issues),
  cost is negligible. A future optimization: thread a per-tick
  `comments_cache` map through `_poll_classify_all` so each issue's
  comments are fetched at most once per tick. Filing recommendation:
  low priority, no blast radius.

- **O-2 (test-coverage gap).** `bin/verdict-handler-test.sh` (verified
  to exist at the path) does not have a fixture exercising
  `find_fresh_wait_verdict` directly. The new helper is integration-
  tested via `bin/poll-slot-test.sh::AC-WAIT-1`, which is sufficient
  for the regression pin. A direct unit test would add isolation
  but no coverage. Filing recommendation: nice-to-have; defer until
  someone touches `find_fresh_wait_verdict`.

- **O-3 (operator-visible behavior change).** Today's
  `external_signal_budget.max_attempts` config knob exhausts in N
  ticks (≈5N min). Post-ENG-85 it exhausts in N ticks AT MINIMUM —
  potentially many more wall-clock minutes if other work is ready
  most ticks. Operators who tune `max_attempts` to bound wall-clock
  should switch to `max_minutes` for the wall-clock semantics they
  expect. Possible follow-up: add a runbook entry for
  `external_signal_budget.max_attempts`'s new "tick-of-eligibility"
  semantics. Filing recommendation: documentation-only;
  capture in `docs/runbooks/operator-mental-model.md` if/when it
  bites someone.

- **O-4 (FIFO tiebreak with identical timestamps).** Two wait
  verdicts emitted in the same Linear comment second sort by jq's
  stable-order semantics, which fall back to `_poll_gather_stage_labeled_issues`'s
  output order. Real-world unlikely (Linear timestamps are
  millisecond-precision); not worth guarding. Filing recommendation:
  no action.

- **O-5 (out-of-scope drift surfaced by feasibility review).** The
  halt reason `external-signal-budget-exhausted` is emitted at
  `bin/run-stage.sh:562` but is NOT present in
  `bin/pipeline-events.json::halt_reasons`. Write-time validation in
  `bin/pipeline.sh::event` would reject it if a hand-rolled writer
  tried — but `_handle_wait` writes it via `linear.sh add-comment`
  directly, bypassing the registry validator. This is a pre-existing
  drift, NOT introduced by ENG-85, and surfacing it is incidental to
  the feasibility audit. Out of scope; should be filed as a
  separate ticket. Filing recommendation: low priority follow-up.

## 11. Anti-bias checks

### ADR stress test

There are no formal ADRs in this repo (no `docs/knowledge/decisions.md`,
verified). The closest analogues are accepted brainstorms and
CLAUDE.md commitments. Specific stress points:

- **ENG-45's brainstorm** (`docs/brainstorms/2026-04-28-build-agent-soft-preconditions-p2-p5-should-re-dispatch-not-halt-for-human-design.md`)
  §1.2 frames the poller's *"no fresh marker + no halt label →
  hold, advanceable (re-dispatch)"* table row as the load-bearing
  fourth state that the new wait shape lands in. ENG-85 changes
  that fourth-row outcome for waits specifically: when a fresh wait
  IS present, vacate instead of hold/advanceable. **Tension:
  yes, but acknowledged and resolved.** ENG-45's contract was *"the
  agent's exit path must work without operator intervention"*; ENG-85
  preserves that contract via Pass 6 (the wait issue still progresses
  when no other work is ready). The "every-tick re-dispatch" cadence
  was an *emergent* property of the ENG-45 design, not a stated
  contract. ENG-85 changes the cadence under load (sibling work
  available) without breaking the no-operator-intervention contract.
  Cost: `external_signal_budget.max_attempts`-driven escalation
  exhausts more slowly under load (O-3 above); `max_minutes` is the
  load-bearing escalation knob post-ENG-85.

- **ENG-20's halt-vacates pattern** (the precedent the issue body
  cites). ENG-85 *strengthens* ENG-20: the same agent-idle-on-external-
  signal semantics that drove halt-vacates now also drive wait-vacates.
  No tension — it's structural symmetry.

- **ENG-54's "single human-approval gate"** (CLAUDE.md §). ENG-54
  established that the human approval wait happens at build's P2 only.
  ENG-85's wait branch fires for any non-halted issue whose latest
  verdict is wait, irrespective of stage. **Defensive symmetry, not
  tension** — review-stage waits are agent-protocol-violations (per
  ENG-54), and ENG-85's vacate-then-recall is strictly safer than the
  pre-fix re-dispatch loop for that misuse case. If review somehow
  emits wait, vacating is benign; pre-fix would have re-dispatched
  the broken review every tick.

- **CLAUDE.md "Sweep + scope partition (ENG-14)" §** —
  `bin/poll.sh`, `bin/verdict-handler.sh`, and `bin/poll-slot-test.sh`
  are all in `bin/`, which is in the
  `partition_dirty_paths::D-004` allowlist for the implement stage.
  Modifying them is in-scope by construction. No tension.

- **Pipeline-marker write-time validation contract.** The wait
  marker is written by `_handle_wait` at `bin/run-stage.sh:485-578`
  (and through `bin/pipeline.sh::event` for operators); the new
  helper only READS markers via `parse_pipeline_marker`. Read side
  has no validation contract — purely syntactic via the registry.
  No tension.

### Simpler alternative

Documented under each decision (D-001 has two rejected alternatives,
D-002 has three, D-003 has three, D-004 has two). Each rejection
cites a specific cost — file-format coupling, slot-enum blast
radius, ordering-priority misalignment, fixture-rename hygiene, etc.

The simplest possible alternative — *do nothing; let the agent
self-throttle wait emission* — was rejected upfront by the issue
body's framing (*"agent's effective state is 'idle, waiting for an
external signal that takes wall-clock minutes to verify each
time'"*) and the empirical 45-min starvation observation. Agent-side
self-throttling is also strictly more complex than orchestrator-side
slot accounting — the agent would need to know about other issues'
states, which violates the single-issue-per-dispatch isolation that
makes the harness reasoning tractable.

### Assumption inventory

Every codebase fact referenced is verified against the current
worktree (see §9 feasibility checklist).

| Assumption | Status |
|---|---|
| `bin/poll.sh::_poll_classify_labels` is at line 207-284, with the catch-all else at 279-281 | verified |
| The halted arm at `bin/poll.sh:231-247` calls `find_fresh_verdict` and routes `pipeline-halt` markers to vacate | verified |
| The reviewing arm at `bin/poll.sh:248-278` predates ENG-85 and shouldn't be reordered | verified |
| `bin/poll.sh::main` Pass 5/idle structure (lines 474-503) is a contiguous block I can restructure | verified (lines 474-501 are Pass 5; 503 is the final idle) |
| `find_fresh_verdict` deliberately excludes wait at `bin/verdict-handler.sh:113` | verified |
| `bin/verdict-handler.sh::export -f` at line 407 lists exported helpers I can extend | verified |
| `bin/run-stage.sh::_fresh_wait_reason` is the agent-side build-only wait detector with the same freshness-floor logic I want to replicate (minus the stage gate) | verified at lines 310-364 |
| `bin/run-stage.sh::_handle_wait` writes `wait-<stage>.json` with attempts and first_attempt_at | verified (lines 535-540) |
| `external_signal_budget.max_attempts` increments via `_handle_wait` once per re-dispatch | verified (line 530) |
| `bin/pipeline-events.json::wait_reasons` is `["awaiting-approval", "awaiting-ci"]` | verified |
| `bin/pipeline-events.json::halt_reasons` does NOT include `external-signal-budget-exhausted` (drift surfaced as O-5) | verified |
| `bin/poll-slot-test.sh::write_*_fixture` helpers handle the shapes I need for the new fixtures | verified (lines 160-223) |
| `bin/poll-slot-test.sh:449-468` is the existing ENG-45 fixture I will replace | verified |
| `bin/poll-slot-test.sh` post-source overrides `SCRIPT_DIR` to STUB_DIR (so my new helper's transitive `linear.sh` calls land on the stub) | verified (line 109) |
| The orchestrator post-ENG-67 uses canonical `feat/eng-N-…` branches (relevant if the wait-progress logic ever needs branch context) | verified (`bin/run-local.sh:227-243`, ENG-67 brainstorm) |
| Linear comment timestamps are ISO-8601 UTC strings, sortable lexicographically | verified by inspection of fixture format `2026-04-28T08:17:00Z` and `bin/linear.sh::get_comments` `sort_by(.createdAt)` line at `bin/linear.sh:372` |
| ENG-86 (sibling structural ticket) is not yet implemented | verified (`grep -rn 'ENG-86' docs/brainstorms/` returns no results) |
| The wait shape carries `reason=*` per the registry's allow-list — i.e., a wait without a reason is an agent protocol violation | verified (`bin/pipeline-events.json::wait_reasons` is non-empty; `parse_pipeline_marker` extracts `.reason`) |
| `bin/poll.sh::main` calls `idle "no-work"` only when all dispatch paths return empty | verified at line 503 |
| `held_count >= max_concurrent` → idle reason is `max-concurrent-reached` | verified at line 476 |

### Codebase-fact verification (gating)

All named files, methods, line numbers, registry values verified —
see §9 feasibility checklist. Zero unverified facts. Zero P0 findings.

## 12. Conflicts with existing architecture

**One real interaction, one cosmetic:**

1. **`external_signal_budget.max_attempts` semantics shift** under the
   new attempt cadence. Pre-ENG-85: `attempts` is incremented every
   tick. Post-ENG-85: `attempts` is incremented only on ticks where
   Pass 6 fires (no other ready work). This is documented in §8 and
   §11 O-3 above. Operators who relied on `max_attempts` to bound
   wall-clock should switch to `max_minutes`. Not a regression — both
   knobs continue to work — but the *implicit relationship* between
   attempts and wall-clock weakens. If ENG-85 ships standalone (without
   ENG-86), the operator's experience is: wait-driven halts may take
   longer to escalate when sibling work is busy. Acceptable
   trade-off given the starvation fix it buys.

2. **The existing ENG-45 test in `bin/poll-slot-test.sh:449-468`
   inverts.** Pre-ENG-85: `slot=hold, advanceable=true`. Post-ENG-85:
   `slot=vacate, advanceable=false, wait_recall=true`. D-004 replaces
   the case with AC-WAIT-1; the prior assertion's purpose
   (pin the soft-redispatch contract) is preserved at a higher level
   by AC-WAIT-3 (Pass 6 fallback covers the "wait still progresses"
   contract that ENG-45's pin originally guarded). Cosmetic; not a
   real architecture conflict.

No other conflicts identified. The brainstorm strengthens the
existing slot-classification contract by extending the halt-vacates
pattern to a marker-driven equivalent, without changing any other
control-flow surface.
