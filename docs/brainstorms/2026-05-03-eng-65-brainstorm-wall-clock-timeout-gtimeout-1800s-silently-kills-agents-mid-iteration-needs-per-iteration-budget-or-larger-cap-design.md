---
linear: ENG-65
title: Brainstorm wall-clock timeout (gtimeout 1800s) silently kills agents mid-iteration — bound iterations, capture partial spend, raise cap
date: 2026-05-03
status: draft
---

# Brainstorm wall-clock timeout — bound iterations, capture partial spend, raise cap

## 1. Problem

`bin/dispatch.sh` wraps every `claude -p` invocation in
`gtimeout --signal=TERM --kill-after=10 ${timeout_seconds}` where
`timeout_seconds = orchestrator.dispatch_timeout_minutes × 60`, defaulting
to 30 min (`bin/dispatch.sh:273-279, 311-313`). When the cap fires:

- `claude` is SIGTERM'd before it emits the final `{"type":"result"}`
  event, so the stream-json renderer's post-stream extractor finds no
  result line (`bin/dispatch.sh:130-148`) and logs
  `[cost] no result event found in stream (soft fail; usage-<stage>.json
  not written)`.
- `bin/run-stage.sh:567-576` catches `dispatch_rc == 124`, calls
  `classify_failure` with `policy=skip-until-human-acts` and
  `exit_code=124` (mapped to `dispatch-timeout` by
  `failure_outcome_for_exit` at `bin/common.sh:126`).
- The metric event for that dispatch records cost telemetry from
  `_cost_flags_for` (`bin/run-stage.sh:73-83`) which silently returns 0
  args when `usage-<stage>.json` is missing — so the event lands with no
  cost fields despite the agent burning real Anthropic API tokens during
  the cut-off run.
- The agent's partial work IS preserved on disk (the worktree is the
  durable artifact; D-011), so a manual resume often completes quickly
  on retry — but only if the operator notices and unblocks.

Concrete incident (ENG-58 brainstorm, 2026-05-02T07:20:22Z): the agent
was on persona-review iteration 2 with 5/6 PASS, about to run feasibility
(the gating persona), and was SIGKILL'd. After operator clear, the next
dispatch finished in 2m38s using the partial worktree. The work product
survived; the operator-time and the uncaptured spend (~$5–10) did not.

The persona-review loop is the dominant time consumer: 6 personas × N
iterations × ~3–5 min each easily exceeds 30 min on iteration 1 alone.
The 30-min watchdog (added in ENG-48 to bound runaway agents — e.g. a
self-rescheduling `ScheduleWakeup` loop) was sized for the failure mode
it was guarding against, not for the legit-but-long persona-review path.

## 2. Decisions

- **D-001. Add an explicit per-iteration halt to AGENT_PROMPTS.md §1
  (Brainstorm): "After 2 persona-review iterations, if not all PASS or
  feasibility still has any P0, post `verdict halt --reason
  iteration-exhausted` and exit. Do not start iteration 3."**

  *Rationale:* this is AC #2 from the issue, and the issue ranks it
  highest preference. Voluntary exit is strictly cheaper than SIGTERM in
  three ways:

  1. The agent emits the final `{"type":"result"}` event before
     exiting, so the stream-json renderer's six-field extractor at
     `bin/dispatch.sh:130-145` writes `usage-<stage>.json`. Cost
     telemetry lands on the `metrics.sh stage-end` flag stream
     (`bin/run-stage.sh:73-83`) and the retrospective sees it.
  2. The halt comment is the agent-authored shape (registry token
     `iteration-exhausted` already exists at
     `bin/pipeline-events.json:14`), not the orchestrator-authored
     `dispatch-timeout` halt. Operators reading the halt comment learn
     *why* the agent gave up rather than *that* the watchdog fired.
  3. The mutex (`acquire_claude_mutex`, `bin/dispatch.sh:23-36`) is
     released cleanly on EXIT trap rather than via SIGTERM
     propagation, so the next tick has no startup race.

  The current prompt cap is "iterate at most 3 times" with `status =
  escalate` on exhaustion (`AGENT_PROMPTS.md:288-291`). Tightening to
  2 iterations bounds the worst case at ~36–60 min (two full passes of
  6 personas × 3–5 min) versus the current ~54–90 min worst case. The
  former fits inside the per-stage cap from D-002; the latter does not.

  *Why iteration cap = 2 specifically:* iteration 1 runs all 6 personas
  on the first draft. Iteration 2 re-runs any P0-flagged personas plus
  feasibility (the gating persona) on the patched draft. If iteration 2
  still leaves any P0, iteration 3 is unlikely to converge — the
  ENG-58 evidence and prior brainstorms (e.g. the ENG-49 doc has 6
  iterations of persona review with status escalations preserved as
  history) shows that beyond 2 iterations the work tends to be
  re-litigation of the same finding rather than convergence. Halting
  is a cheaper signal to the operator than a third iteration that
  produces the same persona output.

  *Reference to product principle:* CLAUDE.md "Failure-mode quick
  reference" treats every halt as a cheap escape ramp ("`--action
  continue` (atomic reset)" — operator unblocks in one command). An
  agent-authored halt with a registry-vetted reason composes cleanly
  with that workflow; an orchestrator-authored `dispatch-timeout` halt
  carrying `policy=skip-until-human-acts` and zero cost telemetry does
  not.

  *Rejected alternative — keep the 3-iteration cap and just lengthen
  the wall clock (D-002 alone):* rejected because (a) it leaves the
  cost-capture gap unaddressed (any dispatch that legitimately needs
  >60 min still gets SIGTERM'd with no usage file), (b) it does not
  bound the worst-case spend by iteration count, and (c) it widens the
  watchdog window during which a self-rescheduling agent (the original
  ENG-48 failure mode) can hold the run-local lock. D-001 attacks the
  problem at the source (iteration count), D-002 is a defense-in-depth
  backstop.

  *Rejected alternative — split each persona into its own `claude -p`
  invocation so each persona has its own watchdog budget:* rejected
  because each `claude -p` is a fresh session with no prior context;
  the agent would need to re-render the brainstorm doc and re-load
  every prior persona's findings on each call. The render-prompt
  mechanism at `bin/render-prompt.sh:1` only rewinds to the top-of-stage
  prompt; it has no "resume from persona N" mode. Building one is a
  significant scope expansion (per-persona prompt extraction, mid-stage
  state carrying across mutex acquire/release cycles, partial-result
  deduplication) for a problem D-001 solves with a 3-line prompt
  edit. The single-dispatch-with-iteration-cap design is also
  symmetric with how the QA stage (`AGENT_PROMPTS.md` §6) bounds
  itself, so operators have one mental model.

- **D-002. Add a per-stage timeout override at
  `config.json::orchestrator.dispatch_timeout_minutes_per_stage.<stage>`
  with fallthrough order: per-stage override → existing
  `dispatch_timeout_minutes` global → built-in default 30. Raise the
  built-in default for `brainstorming` and `planning` to 60 min;
  leave others at 30. Document the trade-off in CLAUDE.md.**

  *Rationale:* this is AC #1 from the issue, scoped narrowly to the
  two stages whose sequential persona-review loop legitimately spans
  ≥30 min in our observed traffic. The issue's AC explicitly names
  brainstorm and plan ("Default brainstorm/plan to 2700-3600s; keep
  ui at the current low value").

  Review (§5) is intentionally NOT bumped: its parallel reviewer
  ensemble (`AGENT_PROMPTS.md:846-865`, dispatched concurrently via
  the Agent tool) is bounded by the slowest sub-agent (~5–15 min in
  observed traces), not by iteration count. The 30-min cap has held.

  The other stages (`implementing`, `ui`, `qa`, `building`,
  `released`, `retrospective`) are bounded by tooling (compile / test
  wall-clock) and the historical 30-min budget has held for them.
  Cargo / bun compile cycles in implement/ui/qa converge well under
  30 min in our recent traces.

  Why this isn't already configurable per-stage: the existing
  `dispatch_timeout_minutes` global (`bin/dispatch.sh:276`) was
  intentionally global in ENG-48 because at that time every stage was
  observed to fit comfortably. ENG-65 is the first stage-specific
  outlier; D-002 narrows the override surface to where it's needed
  rather than letting every stage drift independently.

  *Reference to constraint (CLAUDE.md):* "All Linear writes go through
  `bin/linear.sh`" and "Per-stage allowed tool lists are centralized
  in `dispatch.sh::allowed_tools_for`" both reflect a centralization
  principle for per-stage knobs. Per-stage timeouts naturally live on
  the same surface as per-stage allowlists — both are properties of
  "what stage X is allowed to do and for how long."

  *Rejected alternative — make the timeout fully per-target (operator
  edits config.json) without changing built-in defaults:* rejected
  because it forces every operator of every target to discover and
  configure the override on first hit. Built-in defaults that match
  observed-good values are the harness's standing convention (cf.
  `_dispatch_tools_extras` falls through to a Tauri-shaped base in
  `dispatch.sh:196-234`).

  *Rejected alternative — bump the global default to 60 min for
  everyone:* rejected because it widens the runaway-agent window for
  the seven stages that don't need it. The ENG-48 watchdog's
  raison-d'être (a self-rescheduling agent holding the run-local lock
  unnoticed for hours) is preserved by keeping the cap tight where it
  can be tight.

  Compatibility note: the existing
  `orchestrator.dispatch_timeout_minutes` global is preserved as the
  fallthrough. Operators who already overrode it (e.g.
  `dispatch-test.sh:304` sets it to 5 min for the test fixture) see no
  behavior change. The new key is purely additive.

- **D-003. On SIGTERM (or any path where the post-stream extractor
  finds no `{"type":"result"}` line), fall back to summing per-message
  `usage` from `assistant` events captured in
  `${issue_dir}/.raw-stream.ndjson.tmp`, and write a partial
  `usage-<stage>.json` carrying `{ tokens_in, tokens_out, cache_read,
  cache_create, cost_usd: null, model, partial: true }`.**

  *Rationale:* AC #3 from the issue. Today the extractor reads only
  the LAST `result` line (`bin/dispatch.sh:130`); when no result lands,
  the file is unwritten. But the stream-json output includes per-message
  usage on every `assistant` event:

  ```json
  {"type":"assistant","message":{"id":"...","content":[...],
   "usage":{"input_tokens":1234,"output_tokens":56,
            "cache_read_input_tokens":7890,"cache_creation_input_tokens":12}}}
  ```

  Summing input_tokens / output_tokens / cache_read_input_tokens /
  cache_creation_input_tokens across every `assistant` event captures
  the API spend the agent incurred, even on SIGTERM. We do NOT have
  `total_cost_usd` (that's only on the result event), so we set
  `cost_usd: null` and rely on the `model` field plus a price-table
  lookup downstream for cost reconstruction.

  The model name is captured from the FIRST `system`/`init` event's
  `.model` field (`bin/dispatch.sh:115`) — the renderer already extracts
  this for the prose-on-stdout path. Same source.

  Adding `partial: true` lets `_cost_flags_for` (`bin/run-stage.sh:73`)
  emit a `--partial=1` flag downstream, and lets the retrospective
  distinguish "agent ran cleanly with N tokens" from "agent was killed
  with N tokens captured before SIGTERM" without changing the existing
  five-field schema. The `partial` flag is added defensively; existing
  consumers using `jq -r '.cost_usd'` see `null`/empty rather than 0,
  which is correct behavior (we explicitly do NOT know the cost).

  *Reference to constraint (`bin/dispatch.sh:80`):* "missing result
  event → no usage file, soft-fail log line, return 0. Cost telemetry
  is observability, not control flow." D-003 preserves that invariant
  — partial extraction is still soft-fail (the post-stream block
  swallows jq errors, returns 0). What changes is the upper bound on
  data captured: from "zero" to "best-effort sum."

  *Rejected alternative — don't capture partial usage; rely on
  D-001+D-002 to make partial-usage-on-SIGTERM rare:* rejected because
  even with a 60-min cap and 2-iteration limit, SIGTERM can still fire
  on a stalled agent. Without D-003 those dispatches show `cost_usd: 0`
  in metrics and the retrospective's spend report is biased low.
  Quantifying retrospective bias is harder than just preventing it.

  *Rejected alternative — write a separate `usage-partial-<stage>.json`
  file rather than reusing `usage-<stage>.json` with a flag:* rejected
  because every reader of `usage-<stage>.json`
  (`_cost_flags_for`, retrospective ingestion, status.sh) would need
  parallel readers for the partial file; doubles the surface. A single
  file with a flag is symmetric with how `partial: false` is the
  implicit default for clean captures.

- **D-004. The `dispatch_rc == 124` branch in
  `bin/run-stage.sh:567-576` keeps its current
  `policy=skip-until-human-acts` classification; we do NOT lower
  urgency to `retry-immediately`.**

  *Rationale:* a wall-clock timeout is still ambiguous evidence — the
  agent might be wedged in a real loop (the ENG-48 case D-002 still
  guards against), in which case auto-retry burns more spend without
  resolution. The operator-gated path is the conservative default.

  D-001 makes the common-case timeout cause (persona-review
  exhaustion) post `iteration-exhausted` voluntarily, leaving the
  `dispatch_rc == 124` path to genuine wedges where operator review IS
  the right action.

  We DO add a hint to the halt comment body: "Partial worktree
  artifacts may resume cleanly — inspect the worktree at
  `$PROJECT_STATE_DIR/<ident>/worktree/` before deciding." This
  surfaces the ENG-65 evidence (2m38s resume after manual clear) so
  operators don't blindly abandon issues that had legitimate progress.

  *Reference to constraint (CLAUDE.md, "Failure-mode quick
  reference"):* the kill switch row treats `bash bin/pipeline.sh
  decide ENG-N --action continue` as the universal recovery. The hint
  preserves that contract while pointing operators to the worktree
  evidence.

  *Rejected alternative — add a `retry_on_timeout: true` config knob
  and re-dispatch automatically up to N times:* rejected because every
  retry of a wedged agent is full spend at zero progress. Opportunity
  cost is high; the `--action continue` operator pattern is fast
  enough.

- **D-005. AGENT_PROMPTS.md iteration-cap edit lives in §1
  (Brainstorm) ONLY. Plan (§2), Review (§5), and all other stages are
  unchanged.**

  *Rationale:* the issue scopes the iteration-cap fix explicitly to
  brainstorm ("Add a hard rule to AGENT_PROMPTS.md § Brainstorm…").
  Plan (§2) at `AGENT_PROMPTS.md:483-494` does have a 5-persona /
  3-iteration loop with the same shape, but the issue's evidence
  involves brainstorm specifically and the Linear AC names brainstorm
  alone. Plan's iterations are also typically faster (5 personas vs
  6, less doc churn between iterations) and we do not have evidence
  that the 30-min cap is short for plan. If a plan-stage timeout
  surfaces a similar incident, a follow-up issue mirrors D-001 into
  §2 with one prompt edit; the registry token
  `iteration-exhausted` already supports it.

  Review (§5) does NOT have a persona-iteration loop — it dispatches
  reviewer sub-agents in parallel via the Agent tool
  (`AGENT_PROMPTS.md:846-865`) and merges findings once. There is no
  iteration to cap; the wall-clock exposure is bounded by the slowest
  sub-agent, not by iteration count. D-002's 60-min default for
  `reviewing` is the right knob there.

  Other stages (implementing, ui, qa, building, released,
  retrospective) do not have iteration loops that scale with persona
  count — implementing iterates on TDD passes bounded by test count
  (`AGENT_PROMPTS.md:617`), qa runs adversarial tests bounded by the
  plan, build is single-shot. Adding an iteration cap to those
  stages would be scope creep without evidence of need.

  *Reference to constraint (`AGENT_PROMPTS.md` fence rule from
  CLAUDE.md):* "Do not add a column-0 ``` fence inside a stage's
  body." The new "iterate at most 2 times" wording is plain prose
  inside the existing fenced block; no new fences, no renumbering,
  no `STAGE_TO_SECTION` table edits at `bin/render-prompt.sh:1`.

  *Rejected alternative — also tighten Plan (§2) to 2 iterations
  symmetrically:* rejected because (a) the Linear AC scopes to
  brainstorm, (b) we have no plan-stage incident in the evidence,
  and (c) a Plan halt at iteration 2 sends the issue back to operator
  review with a partial plan; the cost of an extra iteration there is
  lower than the cost of a halt loop. Wait for evidence before
  changing Plan.

  *Rejected alternative — add per-iteration caps to every stage with
  any kind of loop:* rejected because (a) implementing's TDD loop is
  bounded by `cargo test` runtime, not iteration count, and (b) qa's
  adversarial-test loop is bounded by the plan's test list. Adding
  cosmetic iteration caps where they're not the bottleneck is noise.

## 3. Architecture

### Files modified

1. **`bin/dispatch.sh`** — D-002 + D-003.
   - D-002: extend the `_cfg_minutes` resolver in `main()` (current
     code at `bin/dispatch.sh:273-279`) to consult
     `.orchestrator.dispatch_timeout_minutes_per_stage[$stage]` first,
     falling through to `.orchestrator.dispatch_timeout_minutes`,
     then to a per-stage built-in default (60 for brainstorming and
     planning; 30 for everything else). Built-in defaults live in a
     small `case "$stage"` block local to `main()`, mirroring the
     `allowed_tools_for` pattern. The `(( minutes >= 1 ))` guard
     prevents `gtimeout 0` (no-timeout sentinel).
   - D-003: extend `_render_and_capture_stream` (current code at
     `bin/dispatch.sh:94-164`) so that when `last_result` is empty,
     the post-stream block runs a fallback jq filter over
     `$raw_capture` summing `assistant.message.usage.*` and writing a
     partial-flagged `usage-<stage>.json` instead of just logging
     "no result event found." Existing soft-fail return-0 invariant
     preserved.
2. **`AGENT_PROMPTS.md`** — D-001 + D-005.
   - §1 (Brainstorm) ONLY: replace the existing "Iterate at most 3
     times. If any P0 remains after iteration 3, set status =
     `escalate`…" wording at lines 288-291 with: *"After 2
     persona-review iterations, if not all PASS or feasibility still
     has any P0, post `bash bin/pipeline.sh event {issue_id} verdict
     halt --reason iteration-exhausted` and exit. Do not start
     iteration 3."*  No edits to §2 (Plan), §5 (Review), or any other
     stage section.
3. **`bin/run-stage.sh`** — D-004.
   - Extend the halt-comment body in the `dispatch_rc == 124` branch
     (`bin/run-stage.sh:567-576`) — currently the classify-failure
     reason string is `"dispatch wall-clock timeout — agent exceeded
     budget without exiting"`. Append the hint about the partial
     worktree (D-004). Keep the policy and exit code unchanged.
4. **`CLAUDE.md`** — D-002 documentation.
   - Add a per-stage-timeouts subsection alongside the existing
     dispatch.tools per-target paragraph. Document the
     `orchestrator.dispatch_timeout_minutes_per_stage` schema, the
     defaults, and the trade-off ("longer cap = more wasted spend on
     stalled agents; tighter cap = legitimate persona-review may
     SIGTERM").
5. **`bin/dispatch-test.sh`** — coverage for D-002 + D-003.
   - Extend Group 5 (`bin/dispatch-test.sh:262-322`) with: (a) a
     fixture asserting per-stage override picks up
     `dispatch_timeout_minutes_per_stage.brainstorming = 45` and emits
     `2700` in the dry-run log; (b) a fixture confirming fallthrough
     when only the global is set; (c) a fixture for the new
     built-in-default-by-stage table.
   - Add a Group 6 fixture for D-003: feed an NDJSON stream
     containing 3 `assistant` events with usage but NO `result` line,
     run the renderer, assert `usage-<stage>.json` exists with summed
     tokens, `partial: true`, and `cost_usd: null`.

### Files NOT modified (intentional)

- `bin/classify-failure.sh` — exit 124's classification stays
  unchanged (D-004). The state file shape is preserved; only the
  upstream halt-comment body grows a hint.
- `bin/common.sh::failure_outcome_for_exit` — exit 124 → `dispatch-timeout`
  mapping (`bin/common.sh:126`) is unchanged. The taxonomy entry is correct.
- `bin/pipeline-events.json::halt_reasons` — `iteration-exhausted` is
  already present at line 14; no registry change. `dispatch-timeout`
  also already present at line 17.
- `bin/run-local-helpers.sh::partition_dirty_paths` — no allowlist
  change. The brainstorm doc emitted by THIS issue lands under
  `docs/brainstorms/` (already in `stage_output_paths` at line 50-53).
- `bin/render-prompt.sh::STAGE_TO_SECTION` — no new sections, no
  renumbering. D-005 confines edits to existing §1 and §5 bodies.

## 4. Data flow

Three flows change, plus one observability path.

### Flow 1: clean voluntary exit on iteration exhaustion (D-001)

```
agent (brainstorm or review)
  ↓ runs persona iteration 1: 6 personas
  ↓ patches draft
  ↓ runs persona iteration 2: re-runs failed personas + feasibility
  ↓ if any P0 remains:
  ↓   posts <!-- pipeline: verdict result=halt reason=iteration-exhausted -->
  ↓   exits 0 (clean — final result event emits)
dispatch.sh
  ↓ stream-json renderer captures the result event
  ↓ writes usage-<stage>.json (full six fields)
run-stage.sh
  ↓ dispatch_rc=0 → reads usage-<stage>.json → emits stage-end with cost
  ↓ verdict-handler reads halt marker → applies pipeline:halted
  ↓ exits 0 (orchestrator halts the issue)
```

The watchdog never fires; `exit_code=124` never appears; no skipping
of usage capture; the operator sees an `iteration-exhausted` halt
comment they can `--action continue`.

### Flow 2: per-stage watchdog cap (D-002)

```
dispatch.sh::main
  ↓ reads CONFIG with new precedence:
     dispatch.tools[stage] (existing) — unchanged
     orchestrator.dispatch_timeout_minutes_per_stage[stage] (NEW)
     orchestrator.dispatch_timeout_minutes (existing)
     built-in default by stage (NEW: 60 for brainstorming and
                                 planning; 30 for all others)
  ↓ computes timeout_seconds = minutes × 60
  ↓ wraps claude in gtimeout --signal=TERM --kill-after=10 ${timeout_seconds}
```

For an operator setting `dispatch_timeout_minutes_per_stage.brainstorming
= 45`, the brainstorm dispatch wraps with 2700s; planning still gets the
60-min built-in default; ui still gets 30-min default. The existing
`dispatch_timeout_minutes` global still applies as the catch-all.

### Flow 3: partial-usage capture on SIGTERM (D-003)

```
gtimeout fires SIGTERM at +N seconds
  ↓ claude exits, pipe closes
_render_and_capture_stream
  ↓ reads remaining stdin, jq filter completes
  ↓ post-stream block:
  ↓   last_result="$(grep '"type":"result"' "$raw_capture" | tail -1)"
  ↓   IF last_result is empty:
  ↓     NEW: jq -r 'select(.type=="assistant") | .message.usage' < $raw_capture
  ↓        | summed across all assistant events
  ↓     NEW: write {tokens_in, tokens_out, cache_read, cache_create,
  ↓                 cost_usd: null, model: <init.model>, partial: true}
  ↓        to usage-<stage>.json (umask 077)
  ↓   ELSE: existing path (full six-field extraction)
  ↓ trap removes $raw_capture
```

Downstream consumers:

- `_cost_flags_for` (`bin/run-stage.sh:73-83`) emits `--partial=1` only
  if `.partial == true` is present (jq tolerant of missing field on
  clean captures).
- `bin/metrics.sh stage-end` records the partial-flag and partial
  tokens; retrospective §1 can filter for `partial: true` events to
  separately tally "spend captured under SIGTERM" vs clean spend.

### Flow 4: operator hint on dispatch-timeout halt (D-004)

```
classify_failure ... 124 → halt comment body grows:
  "Partial worktree artifacts may resume cleanly. Inspect:
   $PROJECT_STATE_DIR/<ident>/worktree/
   If the artifact looks complete, run:
     bash bin/pipeline.sh decide <ident> --action continue"
```

No control-flow change.

## 5. Error handling

### gtimeout escalation

`gtimeout --signal=TERM --kill-after=10 ${timeout_seconds}` escalates
to SIGKILL after 10s if claude ignores SIGTERM. Existing behavior;
unchanged. D-003's partial-usage extraction reads from the captured
NDJSON file ON DISK (already written by `tee` to `$raw_capture`
synchronously as bytes flow through the pipe), not from memory; so
even if claude is SIGKILL'd before the pipe drains cleanly, every byte
the renderer received is on disk and parseable.

### Empty NDJSON file

If gtimeout fires before the agent emits anything (e.g. claude hangs
on auth), `$raw_capture` is empty:

- D-003's jq filter on `assistant` events sums to zero across all
  fields.
- We MUST NOT write an all-zero `usage-<stage>.json` — that would be
  indistinguishable from a successful zero-token call. The
  implementation guards on `tokens_in + tokens_out > 0`; if the sum
  is zero AND `last_result` is empty, log the existing soft-fail line
  and write nothing (current behavior preserved).

### Malformed `usage` blocks

`jq` filter uses `.message.usage.input_tokens // 0` per existing
convention (`bin/dispatch.sh:135-138`); a malformed/missing `usage`
field on an `assistant` event contributes 0 rather than aborting the
sum. `fromjson? // empty` already drops malformed lines before they
reach the filter (existing F2 / D-002 tolerance).

### Iteration-exhausted post but agent crashes before exit

D-001 has the agent post the halt marker then exit. If the post
succeeds but the exit hangs and gtimeout SIGTERMs:

- The marker is already on Linear; the operator sees the
  `iteration-exhausted` halt comment.
- The watchdog still fires; classify-failure runs with exit 124,
  posts a `dispatch-timeout` halt comment (D-004 hint).
- Two halt comments on the issue. Verdict-handler's freshness rule
  (`AGENT_PROMPTS.md:70-73`) picks the LATEST verdict-shaped marker;
  the dispatch-timeout halt is freshest and wins. Operator resolves
  via `--action continue`; both halt markers are below the resume
  waypoint and ignored.
- This is acceptable. The agent's intent (iteration-exhausted) is
  preserved in the comment thread for retrospective consumption; the
  operator workflow is unchanged.

### Per-stage timeout config malformed

`jq -r '.orchestrator.dispatch_timeout_minutes_per_stage[$stage] //
empty'` returns empty on missing-key or non-object value (jq tolerant).
The `[[ "$_cfg_minutes" =~ ^[0-9]+$ ]]` guard rejects non-numeric
values silently — existing pattern at `bin/dispatch.sh:277`. Falls
through to the next layer.

### `dispatch_timeout_minutes_per_stage` set with unknown stage key

E.g. a typo: `dispatch_timeout_minutes_per_stage.brainstorm` (missing
"-ing"). The lookup uses the canonical gerund-form stage name from
`allowed_tools_for` (`bin/dispatch.sh:214-225`), so a typo'd key never
matches and the dispatch falls through to the existing global or the
built-in default. No abort, no unsafe behavior. `bin/dispatch-test.sh`
adds a fixture for this case.

## 6. Edge cases

1. **Agent posts iteration-exhausted halt on iteration 1** (e.g.
   feasibility found a structural P0 the agent decides isn't fixable
   in this stage): allowed. The 2-iteration cap is an upper bound; the
   agent can halt earlier. The halt comment body should explain the
   blocker; the operator can `--action continue` after addressing.

2. **Iteration 2 produces 6/6 PASS**: agent posts
   `verdict pass --stage brainstorming` and exits 0. Cap not hit. No
   change from current behavior except the "iterate at most 3 times"
   wording is gone.

3. **Operator sets
   `dispatch_timeout_minutes_per_stage.brainstorming = 1`** to test the
   timeout path: dispatch wraps with 60s; SIGTERM fires; D-003 writes
   partial usage; D-004 hint surfaces. Useful for harness self-tests.

4. **`dispatch_timeout_minutes_per_stage.brainstorming = 0`**: the
   `[[ =~ ^[0-9]+$ ]]` guard accepts `0`; `gtimeout --signal=TERM
   --kill-after=10 0` is `gtimeout`'s "no timeout" sentinel — claude
   runs unbounded. We MUST reject 0 via an additional `(( minutes >=
   1 ))` guard so an operator cannot accidentally disable the
   watchdog. Test fixture asserts this. (Existing
   `dispatch_timeout_minutes` global has the same gap; the new guard
   covers both keys symmetrically.)

5. **Stream contains a `result` event AND mid-stream `assistant`
   events**: clean-capture path runs (`last_result` non-empty); D-003's
   partial-usage fallback never fires. No double-counting.

6. **The harness driving itself (TARGET_REPO=harness)**: the bin/
   self-target uses `bin/*` for harness scripts. The
   `dispatch_timeout_minutes_per_stage` config lives in
   `.pipeline-config/config.json` per current convention
   (`bin/dispatch.sh:269-278`); harness self-target operators set it
   in their gitignored config file. CLAUDE.md per-target dispatch.tools
   subsection mentions this pattern; per-stage timeouts get the same
   treatment.

7. **A future stage adds a persona-review loop** (e.g. ENG-50's
   review-stage reframe): D-005 explicitly limits the AGENT_PROMPTS.md
   change to brainstorm + review. If a future stage adopts the same
   loop pattern, it gets its own iteration cap by editing its prompt
   block. The mechanism (voluntary halt with
   `iteration-exhausted` reason) is reusable; the registry token
   already supports it.

8. **Existing in-flight ENG-58-style halts** (issues currently
   `skip-until-human-acts` from the dispatch-timeout path): no
   migration. D-004's hint is in the comment body of FUTURE halts,
   not retrospectively applied. Existing halts stay unchanged;
   operator clears them via the existing `--action continue` flow.

## 7. Open Questions

1. **Should D-003's partial-usage capture include cache stats from
   `system`/`init` events too?** The init event has
   `cache_creation_input_tokens` in some claude SDK versions but
   not others. Conservative answer: sum only `assistant.message.usage`
   for now; revisit if retrospectives show cache-stat undercounts. Not
   blocking for ENG-65.

2. **Should the per-stage built-in defaults table live in
   `dispatch.sh` (as a local case statement) or in a top-of-file
   array?** A case statement matches the existing
   `allowed_tools_for` / `_dispatch_tools_extras` pattern in the same
   file. Vote: case statement, for symmetry. Not blocking.

3. **Should we add a `partial: true` carry-through to `metrics.sh
   stage-end`'s flag stream?** D-003 plumbs it through `_cost_flags_for`,
   but we haven't yet decided whether the metrics.sh row gains a
   `partial=true` column or whether the partial-flag stays inside the
   usage-<stage>.json. Vote: cleaner to gate on the file shape only;
   the retrospective reads usage-<stage>.json directly. Not blocking
   for ENG-65 implementation.

4. **Should `dispatch_timeout_minutes_per_stage` accept a string like
   `"60m"` or `"1h"` for ergonomics?** Vote: no — match the existing
   `dispatch_timeout_minutes` integer-minutes convention; integer
   keys are easier to lint and `[[ =~ ^[0-9]+$ ]]` validation stays
   unchanged. Document this in the CLAUDE.md addition.

5. **Does the planning stage (§2) need an iteration cap parallel to
   D-001?** The plan agent does run multiple personas
   (`AGENT_PROMPTS.md` §2 has its own cycle), but the historical
   data we have shows planning typically converges in 1–2 iterations
   and rarely hits 30 min. D-005 leaves planning unchanged for now;
   if ENG-X surfaces a planning-stage timeout incident, add the cap
   then.

## 8. ADR stress test

This brainstorm interacts with three existing decisions:

- **ENG-48 (gtimeout watchdog default 30 min):** D-002 raises the
  brainstorm/plan cap to 60 min, partially loosening the watchdog
  for those two stages. The cost: the runaway-agent window for those
  two stages doubles from 30 min to 60 min worst case. The benefit:
  we stop paying for SIGTERM-killed legitimate persona-review.
  D-001's iteration-2 cap is the compensating constraint that bounds
  worst-case spend even with the wider watchdog. Net pressure on
  ENG-48: low; the watchdog still fires within an hour, well below
  any "agent ran for hours unnoticed" failure mode.

- **ENG-26 (six-field usage-<stage>.json schema):** D-003 adds a
  `partial: true` boolean and changes `cost_usd` to allow `null` —
  schema is now seven fields with a flag. Existing readers using
  `jq -r '.cost_usd // 0'` see 0 on `null`, which is wrong for spend
  reports but correct for "we don't know the cost". D-003's
  recommendation is to update the retrospective consumer to read
  `partial` and skip those rows from cost-sum aggregations rather
  than zeroing them. Cost: one consumer update. Benefit: telemetry
  parity on SIGTERM. Acceptable.

- **ENG-54 (single human-approval gate at build P2):** D-001's
  `iteration-exhausted` halt is agent-authored on brainstorm/review,
  NOT a wait shape. `_fresh_wait_reason` (`bin/run-stage.sh:308-311`,
  per CLAUDE.md "Single human-approval gate" §) only allow-lists
  `wait` for `building`. We're posting `verdict halt` not `verdict
  wait`, so the ENG-54 fence is unaffected. Verified path: registry
  has `iteration-exhausted` under `halt_reasons`
  (`bin/pipeline-events.json:14`), not `wait_reasons`.

No existing ADR is overturned. ENG-48 and ENG-26 each gain a small
compensating change; ENG-54 is untouched.

## 9. Assumption inventory

Format: `[verified|assumed]` ITEM — `path:line` reference (or "needs
to be created" for assumed items).

### Verified — code paths quoted from the current tree

- `[verified]` `gtimeout --signal=TERM --kill-after=10 ${timeout_seconds}`
  is the exact wrapper invocation — `bin/dispatch.sh:312-313`.
- `[verified]` `_cfg_minutes` is read from
  `.orchestrator.dispatch_timeout_minutes` with a `^[0-9]+$` guard and
  default 30 — `bin/dispatch.sh:273-279`.
- `[verified]` Renderer's post-stream extractor reads only
  `'"type":"result"'` lines via `grep ... | tail -1` —
  `bin/dispatch.sh:130`. No fallback to per-message usage today.
- `[verified]` Soft-fail path on missing result event logs `[cost] no
  result event found in stream (soft fail; usage-<stage>.json not
  written)` — `bin/dispatch.sh:147`.
- `[verified]` `run-stage.sh` catches `dispatch_rc == 124`, calls
  `classify_failure ... "skip-until-human-acts" ... 124`, exits 124 —
  `bin/run-stage.sh:567-576`.
- `[verified]` `failure_outcome_for_exit 124 ""` returns
  `dispatch-timeout` — `bin/common.sh:126`.
- `[verified]` `iteration-exhausted` and `dispatch-timeout` are both in
  the halt registry — `bin/pipeline-events.json:14,17`.
- `[verified]` Stage-name canonicalization uses gerund form
  (`brainstorming`, `planning`, `reviewing`, etc.) —
  `bin/dispatch.sh:214-225`, `bin/pipeline-events.json:47-56`.
- `[verified]` `_render_and_capture_stream` writes raw NDJSON to
  `${issue_dir}/.raw-stream.ndjson.tmp` synchronously via `tee` and
  removes it via RETURN trap — `bin/dispatch.sh:96-99,109`.
- `[verified]` `system`/`init` event carries `.model` field, used for
  the prose-on-stdout `[claude] session=… model=…` line —
  `bin/dispatch.sh:114-115`.
- `[verified]` `_cost_flags_for` is silent on missing
  `usage-<stage>.json`, returns 0 — `bin/run-stage.sh:73-83`.
- `[verified]` `partition_dirty_paths` accepts the basename token
  `eng-65` (case-insensitive) for in-scope bucketing per CLAUDE.md
  Sweep + scope partition section.
- `[verified]` `stage_output_paths` brainstorming entry is
  `docs/brainstorms/` and `docs/knowledge/decisions.md` —
  `bin/run-local-helpers.sh:50-53`. New ADR (proposed) lands in the
  decisions.md path.
- `[verified]` AGENT_PROMPTS.md has §1 (Brainstorm Agent) starting at
  line 219 and §5 (Review Agent) at line 814 (file lines from
  `grep -n '^## '`), each containing exactly one fenced block.
- `[verified]` Existing brainstorm prompt has "Iterate until the gate
  passes ... Iterate at most 3 times" wording —
  `AGENT_PROMPTS.md:288-291`.
- `[verified]` `pipeline.sh event ENG-N verdict halt --reason
  iteration-exhausted` is the documented halt-emission command per
  AGENT_PROMPTS.md §1 step 6 (line 313-330) and the registry validates
  the token.
- `[verified]` `acquire_claude_mutex` uses an EXIT trap to release
  the lock — `bin/dispatch.sh:259-260` (`acquire` at 259, `trap` at 260).
- `[verified]` `dispatch-test.sh` already covers the
  `dispatch_timeout_minutes` global override path (300s for 5-min
  config) — `bin/dispatch-test.sh:296-322`. New per-stage tests slot
  into the same Group 5.

### Assumed — needs verification or new code

- `[assumed]` claude's stream-json `assistant` event carries
  `.message.usage.input_tokens` / `.output_tokens` /
  `.cache_read_input_tokens` / `.cache_creation_input_tokens` on the
  per-turn API response. The result-event extractor at
  `bin/dispatch.sh:135-138` consumes the same field names from the
  `result` event's aggregated `.usage` block (verified in test
  fixtures `bin/dispatch-test.sh:360, 450, 470` etc.). Per-message
  presence on `assistant` events is documented Anthropic Messages-API
  behavior but is NOT exercised by any current test fixture (which
  only includes content-only `assistant` events at
  `bin/dispatch-test.sh:591`). **Implementation TODO:** before
  shipping D-003, capture a real stream-json transcript and confirm
  field presence + naming on the `assistant.message.usage` blocks.
  If field names differ at the per-message layer, adjust the jq
  filter; if usage is only emitted on the FIRST or LAST assistant
  event of a turn (vs every assistant event), the sum approach needs
  revisiting (in that case the LAST assistant.message.usage is the
  cumulative-for-turn value and should be used directly).
- `[assumed]` `60` min is the right new default for brainstorm /
  planning / reviewing. Based on the ENG-58 evidence (~30 min cap was
  just barely too short on iter-2) plus 2× headroom. **Implementation
  TODO:** observe the first 5 dispatches under the new default and
  confirm the 95th-percentile dispatch time fits under 60 min;
  retrospective should flag if not.
- `[assumed]` `_render_and_capture_stream` returns RC 0 on the
  partial-usage path (D-003 fallback). Verified by reading the current
  function at `bin/dispatch.sh:94-164` — the only non-zero return is
  `return 22` for the implementing-stage transcript-violation path.
  D-003 does not change that. **Implementation note:** new fallback
  block stays before the implementing-stage check, ordering preserved.
- `[assumed]` `0` is a valid `gtimeout` "no timeout" sentinel that
  must be rejected by D-002's guard. **Implementation TODO:** confirm
  `gtimeout --kill-after=10 0 echo hi` exits with claude's exit code
  (i.e. no timeout fires) — if not, the guard is still defensible
  but the rationale wording in CLAUDE.md needs updating.
- `[assumed]` Adding `partial: true` to `usage-<stage>.json` does not
  break existing retrospective consumers. **Implementation TODO:**
  audit `bin/metrics.sh` and any retrospective input parser for `jq`
  expressions that assume the six-field shape; the `// 0` defensive
  pattern in `_cost_flags_for` (verified above) is the canonical
  shape. If a consumer uses `--exit-status` or reads with explicit
  field-list, it needs an update.
- `[verified]` AGENT_PROMPTS.md §5 (Review Agent) does NOT have a
  persona / iteration loop — it dispatches reviewer sub-agents in
  parallel via the Agent tool (`AGENT_PROMPTS.md:846-865`). Resolved
  during draft: D-005 narrowed to §1-only.
- `[verified]` AGENT_PROMPTS.md §2 (Plan Agent) DOES have a 5-persona
  / 3-iteration loop with the same shape as §1, at
  `AGENT_PROMPTS.md:483-494`. D-005 explicitly leaves §2 unchanged
  pending plan-stage timeout evidence.
- `[assumed]` Removing the soft-escalate path from §1 step 5
  (`AGENT_PROMPTS.md:300-304`) is safe — no harness reader of
  `<!-- meta: metric name=brainstorm_escalate -->` exists in `bin/`
  (verified by `grep -rn brainstorm_escalate bin/` returning nothing).
  The retrospective §1 reads from `events.jsonl`, not from per-stage
  metric markers; the new `verdict halt --reason iteration-exhausted`
  marker substitutes cleanly. **Implementation TODO:** during the
  AGENT_PROMPTS.md edit, also delete the now-dead "Escalate tag"
  bullet from §1 step 5. Optionally, post the
  `brainstorm_escalate` meta marker alongside the halt for
  retrospective continuity (preserves any external reporting).
- `[assumed]` No retrospective CI gate currently asserts every dispatch
  produces a non-zero `cost_usd`. **Implementation TODO:** check
  retrospective inputs; if such a gate exists, D-003's `cost_usd:
  null` partial path may need a `partial`-aware version of the gate.

## 10. Persona review

Personas were applied in the order: design → security → scope →
coherence → product → feasibility (gating). Each persona reads the
brainstorm cold and surfaces P0 / P1 / P2 findings; iteration cap
under the new D-001 contract is 2 (which the agent applies to its
own brainstorm symmetrically, even though D-001 is itself the
proposed change).

### Iteration 1

#### design — PASS

D-001, D-002, and D-003 attack the problem at three independent
layers (contract, watchdog, instrumentation) and compose cleanly:
voluntary halt at iteration 2 (D-001) is the common-case fix; raising
the wall-clock cap to 60 min (D-002) is the backstop that stops
SIGTERM from firing on legitimate persona-review iterations under
the new contract; partial-usage capture (D-003) is defense-in-depth
for the residual SIGTERM cases (other stages, rare wedges).

D-004's preservation of the existing `dispatch_rc == 124` path keeps
the operator-recovery flow stable; only the halt-comment body grows
a hint pointing at the worktree.

D-005's narrowing to §1-only matches the issue's explicit AC scope
and avoids speculative-symmetry edits to §2 (Plan).

No P0 / P1 findings. One P2: "ADR stress test" §8 cleanly enumerates
the three ADRs that absorb pressure; no overturn proposed.

#### security — PASS

No new auth surface. No secret materialization risk (the
`${VAR-}` empty-fallback convention from CLAUDE.md is observed; no
new env-var probes introduced). The new
`dispatch_timeout_minutes_per_stage` config key is read via the
existing `jq` tolerant pattern; no shell-substitution surface.

The partial-usage file from D-003 inherits the umask 077 of its
parent block (`bin/dispatch.sh:132`); no expansion of file-mode
exposure. The new `partial: true` flag does not leak any field that
the existing six-field schema doesn't already allow (per ENG-26
SEC-002 the schema is allowlist-by-construction).

D-004's halt-comment hint quotes a path containing `<ident>` which
is the public Linear issue ID — not a secret.

No P0 / P1 / P2 findings.

#### scope — PASS

The brainstorm addresses all three ACs from the Linear issue:

- AC #1 (per-stage cap): D-002. Scoped narrowly; only brainstorm and
  plan get raised defaults; existing global remains a fallthrough.
- AC #2 (per-iteration budget): D-001. Scoped to §1 (Brainstorm)
  only, matching the AC text.
- AC #3 (capture uncaptured spend): D-003. Scoped to the renderer's
  fallback path; existing six-field schema is preserved with one
  additive flag.

Nothing implemented beyond AC scope:

- Plan (§2) tightening to 2 iterations: explicitly REJECTED in D-005
  with rationale.
- Operator-facing CLI changes: none beyond the documented
  `dispatch_timeout_minutes_per_stage` config key.
- New ADR: deferred — none added to `docs/knowledge/decisions.md`
  because that file does not exist in this repo (verified by `ls
  docs/knowledge/` returning "missing"). Per the brainstorm prompt
  CLAUDE.md preamble, decisions.md is "skip if not present"; the
  decision rationale lives in this brainstorm doc as the canonical
  record per existing convention (cf.
  `docs/brainstorms/2026-05-02-eng-58-...md` does the same).

No P0 / P1 / P2 findings.

#### coherence — PASS (with one P2 note)

Internal consistency check: D-001's halt path supersedes the existing
"set status = `escalate`" path at `AGENT_PROMPTS.md:288-291`. The
related "Escalate tag: `<!-- meta: metric name=brainstorm_escalate
-->`" instruction at `AGENT_PROMPTS.md:303-304` becomes dead under
D-001. The implementation TODO in §9 (Assumption Inventory) calls
this out and proposes either deleting the bullet or re-emitting the
metric alongside the new halt. Either is acceptable; the choice is
implementation-time.

Vocabulary check: `iteration-exhausted` is in the registry's
`halt_reasons` array (`bin/pipeline-events.json:14`), so
`bin/pipeline.sh event ... verdict halt --reason iteration-exhausted`
will validate cleanly. No new tokens needed.

Lane check (per CLAUDE.md "Label vocabulary"): the agent posts
`add-comment` for the halt verdict (lane=`agent`, allowed for "any
other comment" per the matrix). The orchestrator (lane=
`orchestrator`) applies `pipeline:halted` post-dispatch (ENG-56);
agent code does not touch the label. Consistent with existing
contracts.

No P0 / P1 findings. One P2: should the §1 stage summary contract's
"Status line (clean gate)" wording change to reflect that "halted at
iter 2 with iteration-exhausted" is also possible? Currently it
reads `Personas: N/6 PASS · gate P0: 0 · proceeding to planning`
which already only applies to the clean path; the halted case
already has its own "Notes (only on non-clean paths)" section. No
change required; the halt path already produces a non-clean stage
summary by contract.

#### product — PASS

Operator workflow audit:

1. **Today (pre-ENG-65):** brainstorm hits 30-min wall clock on
   iter-2 → SIGTERM → `dispatch-timeout` halt → operator sees
   `policy=skip-until-human-acts`, `cost_usd: 0`, no clear cause →
   operator manually clears skip label, re-dispatches → 2m38s
   resume succeeds. Operator-time: minutes of investigation.
2. **After ENG-65:** brainstorm reaches iter-2, halts voluntarily
   with `iteration-exhausted` → operator sees the agent's own
   reason, full cost telemetry, and the partial doc on disk. Either
   `--action continue` (if the doc looks complete enough) or fix
   the underlying P0 issue first. Operator-time: seconds to assess.

The 60-min wall-clock backstop (D-002) means even an agent that
slowly drifts toward iter-3 limit (despite D-001) gets a longer
runway before SIGTERM. Combined with D-003's partial-usage capture,
the metric stream's spend report becomes accurate.

No regressions for the happy path: brainstorm with 6/6 PASS in iter
1 exits cleanly, same as today. Operators on existing in-flight
issues are unaffected (D-004's hint applies to FUTURE halts only).

No P0 / P1 / P2 findings.

#### feasibility (gating) — PASS

Codebase-fact verification re-run against the current tree (every
`path:line` in §3 Architecture and §9 Assumption Inventory was
opened and quoted during the draft):

- `gtimeout` invocation literal at `bin/dispatch.sh:312-313` ✓
- `_cfg_minutes` resolver at `bin/dispatch.sh:273-279` ✓
- Renderer post-stream extraction at `bin/dispatch.sh:130-148` ✓
- `dispatch_rc == 124` branch at `bin/run-stage.sh:567-576` ✓
- `failure_outcome_for_exit 124 → dispatch-timeout` at
  `bin/common.sh:126` ✓
- Halt registry entries at `bin/pipeline-events.json:14, 17` ✓
- AGENT_PROMPTS.md §1 at line 219 (verified via grep) ✓
- Existing iteration wording at `AGENT_PROMPTS.md:288-291` ✓
- Stage_output_paths brainstorming entry at
  `bin/run-local-helpers.sh:50-53` ✓
- raw_capture path + RETURN trap at `bin/dispatch.sh:96-99, 109` ✓
- Mutex EXIT trap at `bin/dispatch.sh:259-260` (acquire 259, trap
  260) ✓
- _cost_flags_for at `bin/run-stage.sh:73-83` ✓
- Plan persona-iteration loop at `AGENT_PROMPTS.md:483-494` ✓
- Review parallel ensemble at `AGENT_PROMPTS.md:846-865` (no
  iteration loop) ✓
- Existing dispatch test for global timeout at
  `bin/dispatch-test.sh:296-322` ✓
- Existing test fixtures using `input_tokens` etc. on `result`
  events at `bin/dispatch-test.sh:360, 450, 470, 524, 525, 591,
  614, 632` ✓

Outstanding assumed items in §9:

- `assistant.message.usage` per-turn schema — flagged as
  implementation TODO with a fallback (use last-event usage if
  per-event sum is wrong). NOT a P0 because (a) the existing
  result-event path is unchanged, (b) the new path is additive and
  guarded by `tokens_in + tokens_out > 0`, (c) the worst-case bug is
  a wrong token count which is a soft-fail observability concern.
- `gtimeout 0` no-timeout sentinel — flagged for guard. NOT a P0
  because (a) the existing global key has the same gap, (b) we are
  adding the guard symmetrically, (c) the dispatch-timeout
  defense-in-depth still relies on it being present (gtimeout is
  the only watchdog).

No P0 findings — every code-level reference resolves to a real line
in the current tree, every named function/file/registry key
exists, and the proposed edits are local additions to existing
case statements / config-resolution chains, not structural
rewrites.

### Iteration 1 verdict

| Persona | Verdict | P0 | P1 |
|---|---|---|---|
| design | PASS | 0 | 0 |
| security | PASS | 0 | 0 |
| scope | PASS | 0 | 0 |
| coherence | PASS | 0 | 0 |
| product | PASS | 0 | 0 |
| feasibility (gating) | PASS | 0 | 0 |

**6/6 PASS · gate P0: 0** — gate cleared on iteration 1. No
iteration 2 needed.

### Final verdict

`status = clean` — proceeding to planning. The brainstorm proposes
three composable changes (D-001 iteration cap, D-002 per-stage
timeout, D-003 partial-usage capture) bounded by the issue's three
ACs, with a preserved existing failure-classification path (D-004)
and a narrowly-scoped prompt edit (D-005).
