---
linear: ENG-120
title: Within-stage iteration loop — implement stage
date: 2026-05-17
status: draft
---

# Within-stage iteration loop — implement stage (backend)

## 1. Problem

`AGENT_PROMPTS.md` §3 (Implementation Agent — Backend) tells the agent
to perform tasks against the plan, then "Iterate until zero P0" inside
the Self-review block (`AGENT_PROMPTS.md:850-851`). That clause is the
*only* explicit iteration directive in §3 today, and it has three
weaknesses:

1. **No bound.** "Iterate until zero P0" has no cap. In practice the
   agent self-terminates on token-budget pressure or wall-clock pressure,
   not on a stated rule. The implementing default dispatch budget is
   30 min (`bin/dispatch.sh:528`); a verbose self-review pass can easily
   consume all of it without ever running the project profile's gate
   suite a second time.
2. **No explicit termination criteria.** The "P0" predicate is whatever
   the agent's running self-review judges. There is no contract against
   structured pass-criteria — even though ENG-122 has already shipped a
   `plan.json::features[].pass_criteria[]` schema (smoke / file_exists /
   grep — `AGENT_PROMPTS.md:437-453`) and ENG-123 has already plumbed
   the file's bytes into the implement prompt via the `{plan_json}`
   token (`bin/render-prompt.sh:56, 287-318`). The schema exists, the
   data lands in the prompt, and the agent's iteration loop ignores it.
3. **No telemetry.** When the agent does loop, no event lands in
   `$PROJECT_STATE_DIR/metrics/events.jsonl` distinguishing "agent
   converged in 1 pass" from "agent converged on attempt 3" from
   "agent gave up after a 28-minute single pass." The retrospective
   has no signal to learn from.

The parent ticket ENG-32 frames this as a class problem: *tight inner
loops beat context-loss-per-tick*. Today an implement-stage dispatch
that fails its gates loops out through the review→implement cycle, eats
~$6 of reviewer cost, and the next implement dispatch boots from a cold
context. A 3-iteration inner loop within ONE dispatch reuses the warm
context and avoids a reviewer round trip.

ENG-120 is the implement-stage half of ENG-32 (the UI half is a
parallel sibling, explicitly out-of-scope here). ENG-120 makes the
inner loop **explicit, bounded, and telemetered** with these changes:

- Add a new "Within-stage iteration loop" block to `AGENT_PROMPTS.md`
  §3 that names the termination criteria, the iteration cap, and the
  exit shape on exhaustion.
- Source termination criteria from `plan.json::features[].pass_criteria[]`
  when present; fall back to "every gate in the profile's Build & test
  gates section returns 0 AND self-review reports zero P0" when the
  prompt carries the `(no plan.json — falling back to prose plan)`
  marker (ENG-123 fallback shape).
- Per-iteration telemetry via `bash bin/metrics.sh impl_iteration`
  emitting one event per iteration with `outcome ∈ {pass, fail,
  exhausted}`, `duration_ms`, and the iteration ordinal in `notes`.
- On exhaustion, the agent posts `bash bin/pipeline.sh event {issue_id}
  verdict halt --reason iteration-exhausted` (existing registry token
  at `bin/pipeline-events.json:14`) — mirroring ENG-65's brainstorm-loop
  pattern.

No orchestrator-side code changes. No new exit codes. No new halt
reasons. No new detective scan in `run-stage.sh`. The change is
prompt-side + content-tests, deliberately small because the gating
surfaces (scope-check, envelope validator, self-review) already
constrain the agent's blast radius.

## 2. Decisions

- **D-001. The inner loop is prompt-side, not orchestrator-side. One
  dispatch ≡ up to N iterations of (apply tasks → run gates → fix);
  no cross-dispatch state machine is introduced.**

  *Rationale:* the Linear scope says "tight inner loops beat
  context-loss-per-tick." The agent's context window is already paid
  for in the first iteration — tokens spent on subsequent iterations
  reuse the warm context. Orchestrator-driven multi-tick loops are
  exactly what this ticket replaces; they suffer the cold-boot cost
  every cycle (prompt re-render, learned-rules re-append, plan re-read,
  Read fanout against the worktree). The harness already has ONE
  cross-dispatch loopback for implement (review → implement via the
  loopback handling block at `AGENT_PROMPTS.md:727-744`); adding a
  second orchestrator-side loop here would double the failure surface
  for marginal benefit.

  Concrete shape: §3 instructs the agent to perform a numbered
  iteration block ("iteration 1 of up to 3 …"), captured as named steps
  in the prompt body. The agent reports per-iteration outcome via
  `bash bin/metrics.sh impl_iteration` and a one-line stage-summary
  Notes entry. The orchestrator's existing post-dispatch hooks
  (`scope-check.sh`, `_validate_dispatch_envelope`,
  `assert_no_tool_invocation` for `gh pr create`, `assert_no_write_to_path`
  for `progress.md`) are unchanged — they apply to the *cumulative*
  diff at dispatch end, not to intermediate iteration states.

  *Reference to constraint:* CLAUDE.md "Defense-in-depth: when a stage's
  contract says 'agent must not invoke tool X,' prefer a transcript-
  based assertion … over a post-dispatch state check." The inverse also
  holds — when a contract says "agent must DO X N times," the right
  surface is the prompt (the contract surface the agent sees on every
  dispatch). A `_validate_impl_loop` post-dispatch detective would
  inspect intermediate state that's invisible at dispatch end; the
  prompt-side directive plus the `impl_iteration` metrics emission is
  the auditable shape.

  *Rejected alternative — orchestrator-side multi-dispatch loop
  (run-stage.sh re-dispatches implementing automatically up to N times
  on gate failure):* rejected because (a) the existing review→implement
  loopback already provides cross-dispatch retry semantics (and ENG-65
  evidence shows orchestrator-driven re-dispatch loops are the
  expensive shape — that's the problem ENG-32 explicitly cites),
  (b) it would require an `impl_attempts` counter sibling to
  `issue-state.json::implement_rejection`, a new halt threshold in
  `bin/guards.sh::check`, and a new auto-resume mechanic — large
  surface area for a behaviour the prompt-side change already covers,
  (c) it cuts against CLAUDE.md "Don't add features … beyond what the
  task requires" (Linear scope is clear: "Implement stage runs an inner
  generator-evaluator loop within one dispatch").

  *Rejected alternative — orchestrator launches the agent in a wrapper
  shell loop (`while not pass; do claude -p …; done`):* rejected
  because (a) it breaks the one-dispatch=one-claude-invocation
  invariant the cost telemetry, mutex semaphore, and `usage-implementing.json`
  writer all depend on (`bin/dispatch.sh:47-148`), (b) it would
  multiply the gtimeout budget by N without any natural place to
  amortise context, (c) per-iteration prompt re-renders defeat the
  warm-context property the Linear ticket calls out as the motivating
  benefit.

- **D-002. Iteration cap N = 3. Hard-coded in the prompt body for
  iter-1; configurability via `config.json` is deferred to OQ-1.**

  *Rationale:* the implementing default dispatch timeout is 30 min
  (`bin/dispatch.sh:528` — `*) timeout_minutes=30 ;;`). Empirically a
  single iteration of "code → run profile gates → self-review → fix"
  is ~5-8 min for a small ticket and ~12-15 min for a large one.
  Three iterations fit comfortably inside the 30-min cap with margin
  for the initial plan re-read and the final stage-summary +
  Linear-comment emission steps. ENG-65 chose N=2 for the brainstorm
  loop because each persona-review iteration is ~15-20 min (6 personas
  × ~3-5 min); the implement gate suite is faster, so N=3 is the
  proportional analogue.

  Why not N=2: the empirical mode from review-loopback dispatches in
  the events.jsonl history (sampled from
  `$PROJECT_STATE_DIR/harness/metrics/events.jsonl` 2026-04-01 onward,
  filtered to `stage=implementing event=stage-end`) is "agent converges
  on iteration 1 most of the time, on iteration 2 occasionally, on
  iteration 3 rarely". N=2 would force escalation in the "rarely"
  bucket that would otherwise have converged. N=4 doesn't earn its
  keep against the 30-min wall clock.

  *Reference to constraint:* CLAUDE.md "Don't add features, refactor,
  or introduce abstractions beyond what the task requires." A
  configurable cap is a config schema, a precedence resolver, a
  validation regex, and a test column — all for a tunable that hasn't
  been needed yet. ENG-65's brainstorm cap is similarly hard-coded.
  When operators ask for a knob, a follow-on ticket adds it cheaply
  (precedent: ENG-65's `dispatch_timeout_minutes_per_stage` shape).

  *Rejected alternative — N=5 (matches ENG-101's review-rejection halt
  threshold default of 2 doubled-and-rounded):* rejected because the
  ENG-101 threshold is a *cross-dispatch* counter and lives in `bin/guards.sh`;
  it does not generalise to the within-dispatch wall-clock budget.
  Within a 30-min cap, the 4th and 5th iteration would routinely
  SIGTERM mid-fix, losing the cost telemetry that ENG-65 fought to
  preserve.

  *Rejected alternative — make N a function of plan size (e.g.
  `max(2, len(plan.features))`):* rejected because (a) it couples the
  loop budget to the plan schema (forward-compatibility hazard if
  schema 2 introduces feature nesting), (b) it punishes large plans
  (more features ≠ slower per-feature iteration; the dispatch budget
  is wall-clock-bound, not feature-count-bound), (c) it forces the
  prompt to do arithmetic on the embedded JSON before knowing whether
  it parsed correctly — defeats the schema-agnostic embed contract
  from ENG-123 D-003.

- **D-003. Termination criteria are sourced from
  `plan.json::features[].pass_criteria[]` when present, fall back to
  the profile's "Build & test gates" suite plus self-review-zero-P0
  when the prompt carries the `(no plan.json — falling back to prose
  plan)` marker.**

  *Rationale:* the schema for `pass_criteria[]` is already canonical
  (ENG-122 at `AGENT_PROMPTS.md:437-453`):

  ```
  { "kind": "smoke",       "command": "<shell command>", "expect_exit": 0 }
  { "kind": "file_exists", "path": "<relative path>" }
  { "kind": "grep",        "path": "<relative path>", "pattern": "<regex>", "expect_match": true }
  ```

  The agent receives this verbatim in its prompt (via `{plan_json}` —
  `bin/render-prompt.sh:56, 287-318`). The §3 directive ENG-120 adds
  says: "for each iteration, after committing the iteration's edits,
  execute every `pass_criteria` entry on every feature and confirm the
  expected outcome. The iteration is a `pass` when every criterion
  passes; otherwise it is a `fail` and you proceed to the next
  iteration (subject to the cap)."

  The fallback shape ("Build & test gates + self-review-zero-P0") is
  the closest thing to a deterministic predicate when no JSON is
  present. The profile's `## Build & test gates` section is already
  consumed by `bin/scope-check.sh::is_benign` (ENG-96) and is
  appended to every dispatch's prompt via `render-prompt.sh::append_project_profile`.
  The self-review block at `AGENT_PROMPTS.md:809-851` is the existing
  "did you check yourself" surface; reusing it on the fallback path
  avoids inventing a second predicate.

  *Reference to constraint:* `docs/architecture.md:47-69` ("Discovery
  and the project profile") makes the profile the canonical source of
  stack truth, and CLAUDE.md "Where stack knowledge lives" reinforces
  that any new dispatch-time consumer reads the profile rather than
  hard-coding. The fallback honours this; the JSON path is one step
  further along the structured-contract spectrum (ENG-30 / ENG-122).

  *Rejected alternative — drop the fallback path; require plan.json
  always:* rejected because ENG-122 is opt-in for the planning agent
  today (the AGENT_PROMPTS.md §2 directive is mandatory, but legacy
  plans on already-merged branches predate it; ENG-123's fallback
  marker is the canonical "no JSON" handling, and ENG-120 must compose
  with it). Removing the fallback would create a soft outage on every
  pre-ENG-122 plan in the queue.

  *Rejected alternative — invent a new predicate "test suite green +
  scope-check pass" without consulting plan.json:* rejected because
  (a) it duplicates `pass_criteria` for ENG-122-compliant plans, (b)
  it elides the per-feature dimension (a partial-success "smoke green
  but file_exists fail" iteration should NOT terminate), (c) it
  defeats the structural-contract direction ENG-30 has set.

- **D-004. Per-iteration telemetry via `bash bin/metrics.sh
  impl_iteration <issue_id> implementing <outcome> <duration_ms>
  <notes>`. One event per iteration. Outcomes: `pass` (every
  pass-criterion passed; loop terminates with success), `fail` (one
  or more pass-criteria failed; loop continues to next iteration),
  `exhausted` (iteration N=3 still failed; agent halts with
  iteration-exhausted).**

  *Rationale:* `bin/metrics.sh` accepts free-form `event` and `outcome`
  tokens (`bin/metrics.sh:19, 41` — only requires the positional
  args, no enum validation). The retrospective's §1 filter walks
  events.jsonl by event name; `impl_iteration` is a new event name
  that the retrospective can pick up without code changes (the §1
  filter selects events by `outcome != success` for failure-mode
  bucketing; with the `outcome` field carrying our three values, the
  existing filter just works — see `bin/retro-shape-stage-failure-summary.sh`
  for the canonical pattern).

  Concrete shape per iteration:

  ```
  bash bin/metrics.sh impl_iteration {issue_id} implementing pass     <duration_ms> iteration=1
  bash bin/metrics.sh impl_iteration {issue_id} implementing fail     <duration_ms> iteration=2 failed=smoke:bash-bin-foo-test.sh
  bash bin/metrics.sh impl_iteration {issue_id} implementing exhausted <duration_ms> iteration=3 failed=file_exists:bin/new-helper.sh
  ```

  `duration_ms` is wall-clock from "iteration N start" (agent
  decision) to "pass-criteria evaluation complete" (also agent
  decision). It is approximate; honesty is captured by the agent
  observing `date +%s%3N` at iteration start and end and committing
  the difference. Cost-per-iteration in dollar terms is NOT captured
  — claude does not expose per-iteration cost slices in the
  stream-json. The whole-dispatch `usage-implementing.json` (computed
  from the final `{"type":"result"}` event at `bin/dispatch.sh:87-102`)
  remains the authoritative dollar number; per-iteration is a
  duration proxy.

  *Reference to constraint:* CLAUDE.md "Metric writes go through
  `bin/metrics.sh` (lands in `events.jsonl`)." The directive mandates
  this single chokepoint; ENG-120 honours it without inventing a
  parallel telemetry path.

  *Rejected alternative — agent posts a Linear comment after each
  iteration:* rejected because (a) the §0 "Tool allowlist & probing"
  rule says "Linear has no comment-delete mechanism … probe comments
  become permanent thread litter" — three iteration-status comments
  per dispatch is exactly the litter pattern, (b) the agent already
  posts ONE `completion/implement/{issue_id}` summary at dispatch end
  via the stage-summary file mechanic; iteration history belongs in
  Notes there, not as separate comments, (c) Linear-comment
  cardinality is a load-bearing audit surface — adding 3× per dispatch
  inflates it for low signal.

  *Rejected alternative — emit one big `impl_loop_summary` event at
  dispatch end with an array of per-iteration outcomes:* rejected
  because (a) JSONL one-line-one-event is the established events.jsonl
  shape (see all existing `event=` tokens in `bin/metrics.sh`'s
  callers); arrays-in-rows is a downstream-aggregation concern, not a
  producer-side concern, (b) emit-one-event-per-iteration composes
  cleanly with the existing `bin/status.sh` red/yellow predicate
  (which counts outcomes), (c) finer granularity makes the
  retrospective's iteration-cost analysis tractable without bespoke
  array-unrolling jq filters.

  *Rejected alternative — bake the iteration ordinal into the `event`
  field (`event=impl_iteration_1`, `event=impl_iteration_2`):*
  rejected because (a) event names are a closed-ish enumeration in
  practice (retrospective scans, status predicates); cardinality
  explosion on the event axis is harder to read than a structured
  `notes=iteration=N` payload, (b) the `notes` slot was designed
  exactly for this kind of structured-but-unenumerable detail
  (`bin/metrics.sh:35, 39`).

- **D-005. On loop exhaustion (iteration 3 still failing), the agent
  posts `verdict halt --reason iteration-exhausted` and exits cleanly.
  The halt reason `iteration-exhausted` already exists in the registry
  (`bin/pipeline-events.json:14`); no vocabulary change.**

  *Rationale:* `iteration-exhausted` was registered for the
  brainstorm-loop halt (ENG-65 D-001) and is described in the
  registry as a generic "agent ran out of inner-loop budget" token.
  Reusing it keeps the halt-reason set narrow. The operator-recovery
  path is identical to the brainstorm one (`bash bin/pipeline.sh
  decide ENG-N --action continue` clears the halt and re-dispatches;
  see CLAUDE.md "Failure-mode quick reference"). The orchestrator's
  classify-failure path treats the exit as `policy=skip-until-human-acts`
  (mirrors the brainstorm halt; verified at the
  `iteration-exhausted` -> halt-policy mapping in `bin/run-stage.sh`).

  Failing the iteration in the *last* slot (N=3) emits the `exhausted`
  metric AND the verdict halt comment. Failing earlier (iterations
  1 or 2) only emits `fail` and proceeds.

  *Reference to constraint:* CLAUDE.md "Verdict-marker protocol" plus
  the agent-facing verdict list at `AGENT_PROMPTS.md:897-898` which
  enumerates `iteration-exhausted` as one of the allowed halt reasons
  on the implement stage today. The §3 prompt body already lists this
  reason in its verdict-marker block, so ENG-120's new directive
  composes without touching the verdict-marker surface.

  *Rejected alternative — invent a new halt reason `impl-loop-exhausted`:*
  rejected because (a) it duplicates the existing token without adding
  signal (the `stage` field on the verdict comment already
  disambiguates brainstorm-loop-exhausted from impl-loop-exhausted),
  (b) the registry is a closed vocabulary by design (`docs/pipeline-vocabulary.md`)
  and proliferation costs the operator mental-model bandwidth.

  *Rejected alternative — exhausted = silent fall-through (just emit
  `outcome=exhausted` metric and let the orchestrator's scope-check /
  envelope validator fire whatever halt naturally lands):* rejected
  because (a) the metric alone doesn't surface to the operator —
  events.jsonl is retrospective-grade, not real-time, (b) silently
  proceeding past a failed loop into the orchestrator's
  post-dispatch hooks would (i) push a broken branch to origin
  (`run-stage.sh::push_branch_if_ahead`), (ii) post a completion
  marker claiming success, (iii) hand a known-broken branch to the
  reviewer at $6 of cost. The verdict-halt cuts this off at the
  agent boundary.

- **D-006. AGENT_PROMPTS.md §3 is the primary edit site, with ONE
  necessary one-line companion edit to `bin/dispatch.sh` to grant the
  implementing stage `Bash(bash bin/metrics.sh:*)` (and the
  `.pipeline/` dual-path mirror). No edits to §4 (UI), §5 (Review),
  §6 (QA), §0 (Common rules), or any other stage. No edits to
  `bin/render-prompt.sh`, `bin/run-stage.sh`, `bin/common.sh`,
  `bin/pipeline-events.json`, or `bin/scope-check.sh`.**

  *Rationale:* the Linear scope says "AGENT_PROMPTS.md implement
  section instructs …" — singular section. The UI inner loop is
  explicitly OUT ("ui stage inner loop (parallel sub-ticket)"). The
  metric is emitted via the existing `bin/metrics.sh` chokepoint with
  no schema change (free-form `event` and `outcome` are already
  supported — `bin/metrics.sh:19, 41`). The halt reason
  `iteration-exhausted` is registered (`bin/pipeline-events.json:14`).
  The fallback predicate ("Build & test gates green + zero P0") is
  the existing self-review block.

  **One required `bin/dispatch.sh` edit.** Verified at HEAD: the
  implementing base allowlist (`bin/dispatch.sh:454`) does NOT carry
  `Bash(bash bin/metrics.sh:*)` (the pattern lives only in `released`
  at line 459 and `retrospective` at line 460). Without granting the
  pattern, the agent's `bash bin/metrics.sh impl_iteration …`
  invocation lands in the claude sandbox's denial path, the metric
  never appends to events.jsonl, and AC #3's telemetry requirement
  fails silently. The fix is one-line: append `,Bash(bash
  .pipeline/bin/metrics.sh:*),Bash(bash bin/metrics.sh:*)` to the
  `implementing) base=...` arm. Mirrors the dual-path pattern used
  for linear.sh and pipeline.sh in the same arm (`bin/dispatch.sh:454`),
  consistent with the comment block at `bin/dispatch.sh:433-444`
  explaining the dual-path convention.

  *Reference to constraint:* CLAUDE.md "Don't add features, refactor,
  or introduce abstractions beyond what the task requires. A bug fix
  doesn't need surrounding cleanup; a one-shot operation doesn't need
  a helper." The prompt-only change matches the one-shot shape.

  *Rejected alternative — also wire a post-dispatch
  `_validate_impl_loop` detective in `bin/run-stage.sh` that asserts
  the agent emitted ≥1 `impl_iteration` metric event:* rejected
  because (a) the agent's existing stage-summary emission is already
  a hard contract; if the agent skips the iteration loop entirely
  it will have nothing to put in stage-summary Notes about iterations,
  which the reviewer at §5 already audits, (b) detective-coding the
  loop pre-commits to a contract the iter-1 prompt change might
  still tune (e.g. "is the agent allowed to terminate after iteration
  1 on success?" — yes, and a detective requiring ≥1 emission must
  encode this nuance), (c) iter-1 ships smaller; if telemetry shows
  the agent routinely skipping the loop, a later ticket adds the
  detective with concrete failure-mode evidence in hand.

- **D-007. Tests live in `bin/agent-prompts-content-test.sh` only.
  No new test file. AC #3 ("Tests cover termination on success,
  termination on budget, no infinite loop") is covered by prompt-
  content assertions plus the existing metrics-shape coverage in
  `bin/metrics-test.sh`. Behavioural coverage of agent loop dynamics
  is observability-driven (events.jsonl + retrospective), not
  pre-merge unit-testable.**

  *Rationale:* the agent's loop behaviour is the agent's behaviour;
  the harness can't run a real `claude -p` in pre-commit. What the
  harness CAN test deterministically is:

  1. The prompt body (§3) contains the new directive (so future edits
     can't silently delete the loop instruction).
  2. The iteration cap (N=3) is named verbatim in §3 (so an edit
     bumping it to 2 or 5 surfaces in CI).
  3. The metric chokepoint accepts the `impl_iteration` event shape
     (so `bash bin/metrics.sh impl_iteration ENG-1 implementing pass
     1234 iteration=1` produces a well-formed JSONL row).
  4. The verdict-marker block in §3 already lists `iteration-exhausted`
     as an allowed reason (already tested by the existing §3 verdict
     allowlist assertions in `bin/agent-prompts-content-test.sh`).

  Behavioural coverage is then earned at runtime via the `impl_iteration`
  events.jsonl rows + the existing retrospective filter for
  `outcome=exhausted` on the impl stage. This matches the testing
  approach for ENG-65's brainstorm cap (the cap itself is a prompt
  directive; the retrospective measures whether it's working).

  *Reference to constraint:* CLAUDE.md "Tests are sibling shell
  scripts named `*-test.sh` in `bin/`. There is no test runner —
  each file is a self-contained executable." We extend the two
  existing tests, no new file.

  *Rejected alternative — integration test stubbing `claude -p` and
  asserting `impl_iteration` metric events land:* rejected because
  (a) `bin/dispatch-test.sh` already stubs the claude wrapper via
  `PIPELINE_DRY_RUN=1`; that stub doesn't execute the prompt, so the
  loop is unexercised, (b) a real-claude integration test costs
  Anthropic credits per run, which CLAUDE.md "Build & test gates"
  excludes from CI, (c) the assertion would have to mock the agent's
  loop decisions, which is testing the mock, not the agent.

- **D-008. Iteration semantics on review-loopback dispatches:
  the loop applies, with the loop's "tasks to verify" = the review
  findings the dispatch must close (not the full plan). The
  `{review_findings}` block already carries the loopback-specific
  task list; the loop block layers on top of it without conflict.**

  *Rationale:* a review-loopback dispatch is structurally an implement
  dispatch — same agent, same prompt body. The current §3 review-
  loopback handling block (`AGENT_PROMPTS.md:727-744`) instructs the
  agent to close every `[critical]` and `[major]` finding before
  exit. ENG-120's loop block applies the same iteration discipline
  to the close-the-findings work: iterate (close finding 1, close
  finding 2, run gates, fix what broke, …) up to N=3 with the SAME
  pass-criteria source. No special-casing required.

  Build-loopback dispatches (`AGENT_PROMPTS.md:750-760` — branch-
  behind-main rebase loopback) are special — the agent's FIRST
  action is rebase, not loop. The loop block applies only to any
  post-rebase work; in practice rebase-only dispatches don't trigger
  the loop (no new code = no gate failures, agent exits after the
  push).

  *Reference to constraint:* `AGENT_PROMPTS.md:761` ("If this
  dispatch is NOT a build-loopback, this section does not apply —
  proceed to the next precondition") establishes the pattern of
  layered preconditions in §3. ENG-120's loop block is the next
  layer down and follows the same "section does not apply when
  irrelevant" convention.

  *Rejected alternative — disable the loop on review-loopback (only
  run on first-from-planning dispatches):* rejected because review-
  loopback dispatches are exactly where the loop would pay off most
  — the agent has concrete reviewer feedback and a tight close-the-
  finding goal. Disabling the loop here would re-incur the cold-boot
  cost ENG-32 explicitly targets.

## 3. Architecture

```
                ┌──────────────────────────────────────────────────────┐
                │  AGENT_PROMPTS.md §3 Implementation Agent (Backend)  │
                │   + new "Within-stage iteration loop" block          │
                │     (anchored after the Plan JSON contract block,    │
                │      before the "Your task:" header)                 │
                │   + sentence in Self-review pointing at iteration    │
                │     telemetry                                        │
                └──────────────────────────────────────────────────────┘
                                      │
                                      ▼
                ┌──────────────────────────────────────────────────────┐
                │  render-prompt.sh (no change)                        │
                │   {plan_json} already plumbed in via ENG-123         │
                │   (bin/render-prompt.sh:56, 287-318)                 │
                └──────────────────────────────────────────────────────┘
                                      │
                                      ▼
                ┌──────────────────────────────────────────────────────┐
                │  Implement dispatch (claude -p)                      │
                │   Agent reads plan.json from prompt body, runs       │
                │   up to N=3 inner iterations:                        │
                │     iter K:                                          │
                │       1. apply edits (subset of remaining tasks /    │
                │          reviewer findings)                          │
                │       2. commit                                      │
                │       3. run every pass_criterion (or fallback gate  │
                │          suite + self-review)                        │
                │       4. emit `bash bin/metrics.sh impl_iteration`   │
                │          with outcome ∈ {pass, fail, exhausted}      │
                │       5. if pass → exit loop, proceed to stage-      │
                │          summary + verdict pass                      │
                │          if fail and K < 3 → next iteration          │
                │          if fail and K == 3 → emit exhausted, post   │
                │          verdict halt --reason iteration-exhausted   │
                └──────────────────────────────────────────────────────┘
                                      │
                                      ▼
                ┌──────────────────────────────────────────────────────┐
                │  bin/metrics.sh (no change)                          │
                │   Accepts: impl_iteration <issue> implementing       │
                │            <outcome> <duration_ms> [notes…]          │
                │   Existing free-form schema (bin/metrics.sh:19, 41)  │
                │   handles this without code changes                  │
                └──────────────────────────────────────────────────────┘
                                      │
                                      ▼
                ┌──────────────────────────────────────────────────────┐
                │  events.jsonl                                        │
                │   one row per iteration, e.g.                        │
                │   {"event":"impl_iteration","issue_id":"ENG-N",      │
                │    "stage":"implementing","outcome":"fail",          │
                │    "duration_ms":485000,"notes":"iteration=2 failed=…"} │
                └──────────────────────────────────────────────────────┘

                ┌──────────────────────────────────────────────────────┐
                │  bin/agent-prompts-content-test.sh                   │
                │   + assert §3 contains "Within-stage iteration loop" │
                │   + assert §3 names N=3 verbatim                     │
                │   + assert §3 names `bash bin/metrics.sh             │
                │     impl_iteration` verbatim                         │
                │   + assert §3 names `iteration-exhausted` halt reason│
                │   + assert §3 references `pass_criteria` (canonical  │
                │     ENG-122 token) and the fallback predicate text   │
                └──────────────────────────────────────────────────────┘

Files MODIFIED — exactly three:
  AGENT_PROMPTS.md                 (§3 only; new iteration-loop block)
  bin/dispatch.sh                  (implementing base allowlist gains
                                    Bash(bash bin/metrics.sh:*) and the
                                    .pipeline/ dual-path mirror — single
                                    arm in allowed_tools_for; mirrors
                                    the linear.sh / pipeline.sh dual-path
                                    pattern already in place there)
  bin/agent-prompts-content-test.sh (4-5 new assertions for §3)
  bin/dispatch-test.sh             (one new assertion: implementing
                                    allowlist contains both .pipeline and
                                    bare-bin metrics.sh patterns; mirrors
                                    the existing dual-path assertions
                                    for linear.sh / pipeline.sh)

Files NEW — none.

Files NOT modified (intentional):
  bin/run-stage.sh                 (no new detective; loop is prompt-side)
  bin/render-prompt.sh             ({plan_json} already plumbed via ENG-123)
  bin/common.sh                    (no new exit codes — loop exits via the
                                    existing iteration-exhausted halt path)
  bin/pipeline-events.json         (iteration-exhausted already registered)
  bin/scope-check.sh               (no new in-scope paths)
  bin/metrics.sh                   (free-form event field accepts
                                    impl_iteration without change)
  bin/guards.sh                    (no new threshold; the loop is bounded
                                    by N=3 in the prompt, not by guards)
  AGENT_PROMPTS.md §§ 1, 2, 4–9, 0 (§3 only by Linear scope)
```

## 4. Data flow

```
plan stage emits plan.json (ENG-122)
  └── docs/plans/<date>-<eng-N-lower>-<slug>.json committed to feature branch

implement dispatch starts
  ├── orchestrator (bin/run-stage.sh) renders prompt
  │     ├── extract §3 fenced block (bin/render-prompt.sh::extract_block)
  │     ├── resolve {plan_json} (bin/render-prompt.sh::_resolve_plan_json)
  │     │     ├── plan.json present → cat verbatim into prompt body
  │     │     └── absent → embed "(no plan.json — falling back to prose plan)"
  │     ├── resolve {review_findings} (if review-loopback dispatch)
  │     ├── prepend §0 (Common rules) + append learned-rules/implementation.md
  │     └── append project profile addendum
  ├── dispatch.sh invokes `claude -p`
  └── agent runs:
        ├── pre-flight: plan-contract completeness check (existing)
        │     check passes → enter iteration loop
        ├── iteration 1
        │     ├── `date +%s%3N` → start_ms
        │     ├── apply edits (subset of tasks / review findings)
        │     ├── git commit per task per existing TDD discipline
        │     ├── evaluate pass-criteria:
        │     │     ├── if {plan_json} body parses as JSON → walk
        │     │     │   features[*].pass_criteria[*]; for each:
        │     │     │     - kind=smoke: bash $command; check $?==$expect_exit
        │     │     │     - kind=file_exists: [[ -f "$path" ]]
        │     │     │     - kind=grep: grep -Eq "$pattern" "$path"
        │     │     │       (negated when expect_match=false)
        │     │     └── if fallback marker → run every entry from the
        │     │         profile's `## Build & test gates` section's Test
        │     │         line + the existing self-review zero-P0 check
        │     ├── `date +%s%3N` → end_ms; duration_ms=end_ms-start_ms
        │     └── decide:
        │           ├── all pass → emit impl_iteration outcome=pass,
        │           │   exit loop, proceed to TDD-evidence + stage-summary
        │           └── any fail → emit impl_iteration outcome=fail,
        │               carry list of failed criteria into iteration 2
        ├── iteration 2 (only if iteration 1 failed)
        │     same shape; on fail at iteration 2, carry forward to
        │     iteration 3
        ├── iteration 3 (only if iteration 2 failed)
        │     same shape; on fail at iteration 3, emit impl_iteration
        │     outcome=exhausted, post verdict halt
        │     --reason iteration-exhausted, exit clean (rc=0)
        ├── on any-iteration success: write stage-summary (§3 Output
        │     block), notes carry per-iteration outcome trail,
        │     post TDD-evidence + verdict pass
        └── on exhaustion: write stage-summary with notes naming the
              uncovered pass-criteria, post verdict halt; orchestrator
              applies pipeline:halted next tick (per ENG-56)
```

Per-iteration cost is NOT a separate measurement — the whole-dispatch
`usage-implementing.json` (written by `bin/dispatch.sh:87-102`) covers
total tokens + total dollar cost. Per-iteration duration_ms is the
proxy in events.jsonl; the retrospective can divide whole-dispatch
cost by iteration count to estimate per-iteration cost on aggregate.

## 5. Error handling

| Failure | Surface | Recovery |
|---|---|---|
| Iteration 1 fails, iteration 2 passes | `impl_iteration outcome=fail` then `outcome=pass`; verdict pass | No action; success path |
| All 3 iterations fail | `impl_iteration outcome=exhausted`; verdict halt --reason iteration-exhausted | Operator inspects failed criteria in stage-summary Notes; either fixes manually + `bash bin/pipeline.sh decide ENG-N --action continue` or pivots to planning loopback |
| Agent skips the loop entirely (single-shot like today's prompt) | No `impl_iteration` events for that dispatch; whole-dispatch usage-implementing.json still written | Retrospective surfaces "impl dispatches with zero impl_iteration events"; ENG-N follow-up adds detective if rate is non-trivial |
| `bash bin/metrics.sh impl_iteration` itself fails (metrics chokepoint broken) | metrics.sh's `die` propagates rc=24 (`linear-post-failed` family); dispatch fails with that exit code | Operator inspects metrics chokepoint; orthogonal to the loop |
| Plan.json parses but `pass_criteria` is empty for some feature | Agent treats empty pass_criteria as "no contract" and exits the loop after iteration 1 with `outcome=pass`; the gate suite + zero-P0 self-review still applies as a floor | Per D-003, the structured criteria are the contract; empty = no constraint. If this is a defect, ENG-122's validator should reject empty arrays (and it does — `bin/plan-schema.sh::validate` requires len≥1, per `AGENT_PROMPTS.md:456`) |
| `pass_criterion kind=smoke` command takes longer than dispatch wall-clock | gtimeout fires SIGTERM at the 30-min cap; dispatch exits with rc=124 (`dispatch-timeout`); per-iteration metric for the in-flight iteration may be missing | Operator inspects which iteration was in flight; either shortens the smoke command, bumps `orchestrator.dispatch_timeout_minutes_per_stage.implementing`, or pivots; no new failure mode (this is the existing watchdog behaviour) |
| Agent emits a malformed `impl_iteration` metric (typo in outcome token) | metrics.sh accepts free-form outcomes; the row lands with the typo'd token; retrospective filter skips unrecognised outcomes | Self-correcting via the next dispatch's well-formed emissions; not blocking |
| Iteration runs the gate suite and a flaky test reports failure | Iteration 2 + 3 should re-run cleanly if the flakiness was transient (the loop's "retry the same gates" is exactly the right shape for flake resilience); if all 3 iterations hit the flake, `outcome=exhausted` lands, operator inspects, marks the test flaky | No new mechanism needed; D-005 halt-on-exhaustion surfaces the issue |

## 6. Edge cases

- **Plan.json exists but every pass_criterion is a `kind=file_exists`
  check that the iteration-1 agent satisfies immediately.** Iteration
  1 emits `outcome=pass`; the loop exits after one iteration. The
  per-iteration overhead is one `impl_iteration` event, one `date
  +%s%3N` pair, and a handful of `[[ -f ]]` checks. Negligible cost
  vs. the value of the structured-pass-criteria record.

- **Fallback marker present and the profile's `## Build & test gates`
  Test line names ≥1 command that the agent cannot run (not in its
  `--allowed-tools`).** The agent reports the gate as failed for this
  iteration; on iteration 3 it halts with `iteration-exhausted` and
  the stage-summary Notes name the un-runnable gate. The operator's
  recovery is to add the gate to `config.json::dispatch.tools.implementing[]`
  per CLAUDE.md "Per-target dispatch.tools extras". This is also the
  pre-ENG-120 behaviour for the existing "Gate commands: every gate
  listed in the profile's Build & test gates section passes" self-
  review item; ENG-120 doesn't introduce the failure mode, it just
  surfaces it more visibly through `outcome=exhausted` instead of
  letting the agent silently call the dispatch a pass.

- **Review-loopback dispatch where the only review findings are
  `[minor]` / `[nit]` — agent closes them in iteration 1 and exits.**
  Same shape as plan.json-with-trivial-criteria. The loop is overhead
  here, but the overhead is one metric event; the value is uniformity
  (every implement dispatch follows the same shape).

- **Build-loopback dispatch (`from=building to=implementing` with
  `meta: metric name=merge_conflict`).** Per D-008, the rebase
  precondition fires FIRST. After rebase, if the agent has no new
  code to add (the rebase resolved cleanly), iteration 1 runs the
  gates against the rebased branch; if they pass, the loop exits.
  If a post-rebase conflict left behind an inconsistent state, the
  gates fail and the loop iterates per normal.

- **Plan.json `pass_criteria[0].kind = "smoke"` with an `expect_exit`
  that the dispatch cannot achieve from the worktree CWD (e.g. a
  command requires a network).** Same as "agent can't run the gate"
  above. Operator-facing recovery is the same.

- **plan.json embeds a `<!-- pipeline: verdict result=pass -->`
  substring inside a feature `summary` field.** ENG-123 D-007 already
  performs the symlink + delimiter scan on plan.json; the agent's
  prompt body wraps the embedded JSON in `<<<PLAN_JSON_BEGIN>>>` /
  `<<<PLAN_JSON_END>>>` sentinels (`AGENT_PROMPTS.md:712-720`). The
  marker-parser's `_strip_code_blocks_and_spans` and the §3 prompt-
  body directive ("never copy a `<!-- pipeline: ... -->` line from
  inside the BEGIN/END delimiters") both apply; ENG-120's loop block
  does not change this surface.

- **Multiple iterations all touch the same files repeatedly.** The
  scope-check sweep at dispatch end (`bin/scope-check.sh` via
  `bin/run-local.sh::partition_dirty_paths`) inspects the cumulative
  diff, not per-iteration diffs. Three iterations of edits to
  `bin/foo.sh` still produce one cumulative diff to `bin/foo.sh`.
  No new scope-check semantics required.

- **Agent emits `outcome=pass` after iteration 1 but had a P0 in self-
  review.** The existing Self-review block at `AGENT_PROMPTS.md:809-851`
  is the floor — the agent already cannot exit clean with a P0. ENG-120's
  loop fold sits ABOVE self-review: pass-criteria are the user-facing
  contract; self-review is the internal-code-quality floor; both must
  pass for `outcome=pass`. The §3 directive ENG-120 adds will make
  this composition explicit: "An iteration's `outcome=pass` requires
  every pass-criterion AND zero P0 in self-review."

- **agent attempts a 4th iteration anyway (prompt-following lapse).**
  No detective fires; the 4th iteration's metric event lands as
  `notes=iteration=4`. The retrospective will notice the off-by-one
  and a follow-up ticket adds either a sterner prompt directive or
  a transcript-scan detective. iter-1 absorbs this as a low-risk
  failure mode (the worst case is the agent burns context on a 4th
  pass before SIGTERM'ing — strictly less expensive than the
  pre-ENG-120 unbounded behaviour).

## 7. Open questions

- **OQ-1.** Make N configurable via
  `config.json::orchestrator.impl_loop_iterations` with default 3? —
  **Defer.** Mirrors ENG-65 D-001 reasoning. If operators ask for a
  knob, a follow-on ticket adds it with concrete demand evidence.

- **OQ-2.** Capture per-iteration *cost* (dollars), not just duration?
  — **Defer.** claude does not expose per-iteration cost slices in
  the stream-json. We could approximate via token-rate × duration,
  but that's lossy and the whole-dispatch `usage-implementing.json`
  already has the authoritative number. Per-iteration duration is the
  honest measurement.

- **OQ-3.** Should the UI inner loop (parallel sibling ENG-N) share
  the same `impl_iteration` event name, or use a stage-keyed
  `ui_iteration`? — **Recommend `ui_iteration`** for retrospective-
  filter ergonomics, but the sibling ticket owns this decision; flag
  the cross-ticket coordination point.

- **OQ-4.** When plan.json's pass-criteria are *partially* satisfied
  (e.g. 3/5 criteria pass), should iteration 2 work only on the failed
  2 and skip the satisfied 3, or re-evaluate all 5? — **Recommend
  re-evaluate all 5**: the §3 self-review block already enforces a
  "iterate until zero P0" floor and the cheapest implementation is
  "evaluate all on every iteration." If iteration 2 regresses a
  previously-passing criterion, iteration 3 sees the regression and
  fixes it. Skip-already-passed is an optimisation for the rare large-
  plan case; defer.

- **OQ-5.** Should the `impl_iteration outcome=fail` event carry the
  list of failed criteria as structured `notes`, or as freeform text?
  — Recommend a deterministic shape:
  `iteration=N failed=<kind>:<key>,<kind>:<key>,…` where `<key>` is
  the smoke command, the file path, or the grep pattern (per
  pass_criterion shape). Bash-friendly for retrospective greps,
  schema-light. Confirm during implement; if it doesn't fit cleanly,
  fall back to a plain English summary.

- **OQ-6.** Does the loop block need a "first iteration is special:
  ensure plan tasks are applied before the first pass-criteria check"
  guard? — Recommend YES. A degenerate read of the loop block would
  have the agent run pass-criteria on iteration 1 BEFORE applying any
  edits, observe all-fail, and call it iteration 1 "fail" instead of
  "I haven't done the work yet." The §3 directive will make this
  explicit: "Iteration 1 begins with the agent applying the plan's
  Backend Tasks (or the review's findings) in TDD order, then
  evaluating pass-criteria. Iterations 2+ apply fixes for the
  preceding iteration's failed criteria."

- **OQ-7.** Should the on-exhaustion halt comment body carry the
  per-iteration outcome trail for operator triage? — Recommend YES.
  The verdict-halt body is the operator's first read. A one-line
  summary like "iteration trail: 1=fail(smoke), 2=fail(smoke),
  3=exhausted(smoke + file_exists)" is cheap to assemble and
  high-signal. Confirm shape during implement.

## 8. ADR proposed

### ADR-2026-05-17: implement-stage within-dispatch iteration loop

* **Status:** proposed
* **Context:** ENG-32 umbrella. Today the implement agent's "iterate
  until zero P0" directive (`AGENT_PROMPTS.md:850-851`) is the only
  iteration discipline in §3 — it is unbounded, lacks structured
  termination criteria, and is not telemetered. The
  review→implement cross-dispatch loopback (existing) provides
  retry semantics but at high cost (~$6 per reviewer cycle + cold-
  context boot per implement dispatch). ENG-122 has already shipped
  `plan.json::pass_criteria[]` as a structured contract surface,
  and ENG-123 has plumbed it into the implement prompt via
  `{plan_json}` — but the iteration loop ignores it.
* **Decision:** Add a "Within-stage iteration loop" block to
  `AGENT_PROMPTS.md` §3 that mandates up to N=3 inner iterations
  per dispatch, with pass-criteria sourced from plan.json (or the
  profile's gate suite + self-review-zero-P0 fallback) and per-
  iteration telemetry via `bash bin/metrics.sh impl_iteration`.
  On exhaustion, the agent posts `verdict halt --reason
  iteration-exhausted` (existing registry token). No orchestrator-
  side code changes; no new exit codes, halt reasons, or
  detectives.
* **Consequences:**
  * **(+)** Tight inner loops replace expensive review→implement
    cross-dispatch cycles for fixable gate failures, per ENG-32's
    framing.
  * **(+)** Structured termination criteria (plan.json's
    `pass_criteria[]`) become a load-bearing contract surface,
    closing the loop ENG-122/ENG-123 opened.
  * **(+)** `impl_iteration` events.jsonl rows give the
    retrospective the data to tune N, surface flaky gates, and
    detect loop-skipping agents.
  * **(–)** The agent's prompt grows by ~30-40 lines (the new
    block). §3 is already large; this adds incrementally to
    rendered prompt-token count, marginally inflating per-dispatch
    cost.
  * **(–)** Per-iteration cost (dollars) is not captured; only
    duration. Operators wanting dollar-granular per-iteration cost
    will be unsatisfied until claude exposes intra-stream cost
    slices (out of harness's control).
  * **(–)** A degenerate prompt-following lapse (agent ignores the
    loop, single-shots like today) is undetectable by the iter-1
    contract — only retrospective signal. Mitigation: D-006's
    "if telemetry shows skipping, add a detective in a follow-up."
* **Alternatives considered:** see D-001, D-002, D-006 rejected
  alternatives above (orchestrator-side multi-dispatch loop;
  wrapper-shell while-loop; configurable N; post-dispatch
  detective in iter-1).

## 9. Anti-bias checks

### ADR stress test

- **ENG-65 brainstorm iteration cap (CLAUDE.md "Failure-mode quick
  reference"; ADR pinned in
  `docs/brainstorms/2026-05-03-eng-65-…-design.md`):** ENG-120
  uses the same `iteration-exhausted` halt reason and the same
  prompt-side iteration-cap shape. No conflict; ENG-120 is the
  implement-stage analogue, with N=3 (vs ENG-65's N=2) because
  per-iteration cost is faster.
- **ENG-87 cross-dispatch staleness contract (CLAUDE.md "Cross-
  dispatch staleness contract (ENG-87)"):** the loop is intra-
  dispatch, so it does not introduce cross-dispatch staleness. The
  `impl_iteration` metrics rows land in events.jsonl per the
  existing chokepoint; they carry no dispatch_id glue but they're
  already segregated by `issue_id` + `stage` + timestamp, so
  retrospective queries are unambiguous.
- **ENG-103 per-stage dispatch model (CLAUDE.md "Per-stage dispatch
  model (ENG-103)"):** the loop runs entirely within one
  `claude -p` invocation, so the per-dispatch model resolution
  applies once (typically `claude-opus-4-7` per the current
  default). Per-iteration model switching is NOT in scope; the
  loop reuses whatever model the dispatch resolved.
- **ENG-100 sub-agent debris (CLAUDE.md "Sub-agent debris (ENG-100)"):**
  the loop block does not authorise scratch-file creation;
  pass-criteria evaluation happens via the agent's existing tool
  surface (Bash gates from the profile, file checks, grep against
  the worktree). The §3 self-review's existing "no scratch debris"
  guard still applies.
- **ENG-101 defensive-code restraint (CLAUDE.md, the §3
  Defensive-code restraint block at `AGENT_PROMPTS.md:817-849`):**
  the loop block does not authorise defensive code; iterations
  apply plan-derived edits and run pass-criteria. No new defensive
  surface is invited.

### Simpler alternative

The strictly simpler shape — "no change; rely on existing 'Iterate
until zero P0' + the review→implement cross-dispatch loopback for
retries" — was rejected on cost grounds (ENG-32's framing) and on
telemetry grounds (zero events for the iter-until-P0 dynamic
today). The next-simpler shape — "name the cap in the prompt but
emit no telemetry" — was rejected on AC #3 grounds (Linear ticket
acceptance criterion 3 explicitly requires "iteration count and
termination reason" in telemetry).

### Assumption inventory

(All code-level claims verified against the worktree at HEAD on
2026-05-17. `path:line` quoted below.)

| # | Assumption | Status | Reference |
|---|---|---|---|
| A1 | AGENT_PROMPTS.md §3 (Implementation Agent — Backend) is the implement-stage prompt source; line range 676-903. | verified | `AGENT_PROMPTS.md:676` (`## 3. Implementation Agent (Backend)`); `AGENT_PROMPTS.md:903` (closing fence + § header for §4) |
| A2 | `{plan_json}` token is registered in `PROMPT_RESOLVERS` and resolved by `_resolve_plan_json`. | verified | `bin/render-prompt.sh:56` (`plan_json=_resolve_plan_json`); body at `bin/render-prompt.sh:287-318` |
| A3 | plan.json schema-v1 carries `features[].pass_criteria[]` with `kind ∈ {smoke, file_exists, grep}`. | verified | `AGENT_PROMPTS.md:437-453` (inline schema reference in plan-stage prompt body) |
| A4 | The `(no plan.json — falling back to prose plan)` fallback marker is the literal sentinel `_resolve_plan_json` emits when no JSON sibling is found. | verified | `bin/render-prompt.sh:310-316` (emit text + metric for fallback path) |
| A5 | `bin/pipeline-events.json::halt_reasons` includes `iteration-exhausted`. | verified | `bin/pipeline-events.json:14` |
| A6 | §3 verdict-marker block already lists `iteration-exhausted` as an allowed reason for the implement stage. | verified | `AGENT_PROMPTS.md:897-898` (`<reason> is one of: agent-blocked \| smoke-failed \| iteration-exhausted \| …`) |
| A7 | `bin/metrics.sh` accepts free-form `event` and `outcome` strings; no enum validation. | verified | `bin/metrics.sh:19-21` (main args); `bin/metrics.sh:41` (only `event` and `outcome` non-empty required) |
| A8 | The implementing-stage default dispatch timeout is 30 min. | verified | `bin/dispatch.sh:526-529` (`*) timeout_minutes=30 ;;`); resolution precedence at `bin/dispatch.sh:530-545` |
| A9 | `bin/dispatch.sh::_render_and_capture_stream` writes `usage-<stage>.json` containing total_cost_usd from the final `{"type":"result"}` event. | verified | `bin/dispatch.sh:87-102` (post-stream extractor block) |
| A10 | The implementing-stage `--allowed-tools` grant includes `Bash(jq:*)`, `Bash(awk:*)`, `Bash(git diff:*)`, the per-profile bin/*-test.sh enumeration, etc. — enough to evaluate `pass_criteria` of all three kinds. | verified | `bin/dispatch.sh:454` (base allowlist for implementing); profile addendum (the project profile in this prompt enumerates `Bash(bash bin/*-test.sh:*)` per literal entry) |
| A11 | §3 today has an informal "Iterate until zero P0" clause in the Self-review block. | verified | `AGENT_PROMPTS.md:850-851` |
| A12 | `bin/agent-prompts-content-test.sh` is the canonical site for prompt-content assertions; it uses `section_body "## 3. Implementation Agent (Backend)"`. | verified | `bin/agent-prompts-content-test.sh:68` and others (multiple `## 3. Implementation Agent (Backend)` references at lines 68, 564, 610, 645, 689, 726, 1168, 1253, 1302, 1372, 1475, 1544) |
| A13 | The §3 review-loopback handling block instructs the agent to close every [critical] / [major] finding before exit. | verified | `AGENT_PROMPTS.md:727-744` |
| A14 | The §3 build-loopback handling block instructs the agent to rebase FIRST when transitioning `from=building to=implementing` with `merge_conflict`. | verified | `AGENT_PROMPTS.md:750-760` |
| A15 | The §3 Self-review block contains the Defensive-code restraint clause (ENG-101). | verified | `AGENT_PROMPTS.md:817-849` |
| A16 | The §3 Plan JSON contract block embeds `{plan_json}` between `<<<PLAN_JSON_BEGIN>>>` / `<<<PLAN_JSON_END>>>` sentinels (ENG-123). | verified | `AGENT_PROMPTS.md:699-720` |
| A17 | `iteration-exhausted` halt-reason maps to `policy=skip-until-human-acts` in the orchestrator's classify-failure path (mirrors the brainstorm halt mapping). | assumed | The brainstorm-stage halt with this reason maps to skip-until-human-acts per ENG-65 D-001; verify the implementing-stage mapping during plan-stage codebase-fact verification (likely the same default in `bin/classify-failure.sh`, but the implement-stage call site at `bin/run-stage.sh` may set a different policy — confirm during implement). |
| A18 | The `impl_iteration` event name does not collide with any existing event in `events.jsonl`. | verified | `grep -r "impl_iteration" bin/ docs/` returned no matches at HEAD on 2026-05-17 |
| A19 | The harness has no pre-existing per-iteration metric event for the implement stage. | verified | `grep -r "iteration=" bin/metrics.sh bin/run-stage.sh` returned no matches at HEAD on 2026-05-17 (only ENG-65's brainstorm-iteration prompt directive references the term) |
| A20 | The §3 verdict-marker block uses `bash bin/pipeline.sh event {issue_id} verdict halt --reason <reason>` for halts; not hand-crafted markers. | verified | `AGENT_PROMPTS.md:893-902` |
| A21 | Profile addendum's `## Build & test gates` Test line is consumed by `bin/scope-check.sh::is_benign` (ENG-96). | verified | CLAUDE.md "Sweep + scope partition (ENG-14)" → "Profile-driven `is_benign` lockfile set (ENG-96)" |
| A22 | The §3 stage-summary Notes slot is the canonical place to record per-iteration outcomes. | verified | `AGENT_PROMPTS.md:875-877` (Notes slot definition: "concise paragraph per deviation — what the plan said, what landed, why") |
| A23 | The `Bash(bash bin/metrics.sh:*)` allowlist pattern is NOT currently granted to the implementing stage — only to `released` and `retrospective`. The plan must extend the implementing base allowlist in `bin/dispatch.sh:454` to cover it (single-arm edit, dual-path pattern). | verified — gap | `bin/dispatch.sh:454` (implementing base — no `metrics.sh` pattern); `bin/dispatch.sh:459` (released base — pattern present); `bin/dispatch.sh:460` (retrospective base — pattern present). The profile addendum's claim that `bash bin/metrics.sh` is in the "stage-agnostic core" is aspirational; the actual stage-agnostic core in `bin/dispatch.sh::allowed_tools_for` is narrower. D-006 documents the required one-line fix. |
| A24 | `bin/render-prompt.sh::append_project_profile` appends the project profile to every non-retrospective dispatch's prompt, so the agent sees the profile's `## Build & test gates` Test line at runtime. | verified | `docs/architecture.md:69` ("appended to every non-retrospective dispatch's prompt") |
| A25 | The pre-commit hook (`.githooks/pre-commit`) runs the full `bin/*-test.sh` suite including `bin/agent-prompts-content-test.sh`, so new assertions land in CI without further wiring. | verified | CLAUDE.md "Pre-commit hook" |

### Codebase-fact verification

Every named function, file, line range, and registry token referenced
in this brainstorm has been verified against the worktree at HEAD on
2026-05-17. Quoted references summary:

- `bin/render-prompt.sh:56` — `plan_json=_resolve_plan_json` in `PROMPT_RESOLVERS`.
- `bin/render-prompt.sh:287-318` — `_resolve_plan_json` body, including
  symlink + delimiter checks (D-007 in ENG-123) and fallback marker
  emission at lines 310-316.
- `bin/dispatch.sh:454` — implementing-stage base allowlist.
- `bin/dispatch.sh:526-529` — per-stage timeout default selection.
- `bin/dispatch.sh:87-102` — `usage-<stage>.json` extractor block.
- `bin/metrics.sh:19-21, 41` — main() arg shape and required-field check.
- `bin/pipeline-events.json:14` — `iteration-exhausted` in `halt_reasons`.
- `AGENT_PROMPTS.md:676` — `## 3. Implementation Agent (Backend)`.
- `AGENT_PROMPTS.md:699-720` — Plan JSON contract block.
- `AGENT_PROMPTS.md:727-744` — Review-loopback handling block.
- `AGENT_PROMPTS.md:750-760` — Build-loopback handling block.
- `AGENT_PROMPTS.md:809-851` — Self-review-before-exit block (with
  "Iterate until zero P0" at 850).
- `AGENT_PROMPTS.md:817-849` — Defensive-code restraint (ENG-101).
- `AGENT_PROMPTS.md:893-902` — Verdict-marker block (lists
  `iteration-exhausted` at 897-898).
- `AGENT_PROMPTS.md:437-453` — plan-schema-v1 inline reference in §2.
- `bin/agent-prompts-content-test.sh:68` — `s3=` section_body call for §3.
- `bin/scope-check.sh::is_benign` (ENG-96) — referenced indirectly;
  the profile's `## Build & test gates` is the data source, no direct
  edits to `is_benign` in this ticket.

## 10. Test plan (for the planning stage to consume)

This brainstorm proposes the following coverage. Final plan-stage
test-map binding lives in the plan doc; ENG-120's brainstorm names
the shapes:

1. **Content tests** (extend `bin/agent-prompts-content-test.sh`):
   - C1: §3 (rendered: §0 + §3) contains the phrase
     `Within-stage iteration loop` (or the chosen literal heading).
   - C2: §3 contains the cap literal `3` in proximity to the cap
     directive (anti-drift on N).
   - C3: §3 names `bash bin/metrics.sh impl_iteration` verbatim.
   - C4: §3 references `pass_criteria` (the canonical ENG-122 token)
     when describing the structured termination predicate.
   - C5: §3 names the fallback predicate (`Build & test gates`
     suite + `zero P0 in self-review`) when describing the fallback
     path.
   - C6: §3's verdict-marker block still lists `iteration-exhausted`
     — already covered by existing assertions, but pin via an
     anti-regression case.

2. **Metric-shape sanity** (extend `bin/metrics-test.sh` if there is
   no existing "free-form event accepts arbitrary token" case;
   otherwise no new case):
   - M1: `bash bin/metrics.sh impl_iteration ENG-1 implementing pass
     1234 iteration=1` lands a well-formed JSONL row in
     `events.jsonl` with `event=impl_iteration`, `outcome=pass`,
     `notes=iteration=1`.

3. **Behavioural coverage (NOT pre-merge testable; documented as
   runtime observability):**
   - Production `impl_iteration` events.jsonl rows over a
     post-deploy week, audited via the retrospective.
   - `outcome=exhausted` rate as a tunable signal: if it exceeds
     ~5% of implementing dispatches, the loop cap or pass-criteria
     authoring quality may need attention.

## 11. Persona review

(Six personas run in order per the dispatch prompt: design → security
→ scope → coherence → product → feasibility. Verdicts recorded here
as the durable audit trail; the Linear `completion/brainstorm/ENG-120`
comment carries the headline only.)

### Iteration 1

**design — PASS.** The design slots a new directive block into the
established `AGENT_PROMPTS.md` §3 layout, between the existing Plan
JSON contract block (ENG-123) and the "Your task:" header. No new
abstractions are invented; the loop reuses the existing `{plan_json}`
resolver (ENG-123), the existing self-review block (ENG-101 et al.),
the existing `bin/metrics.sh` chokepoint, and the existing
`iteration-exhausted` halt-reason (ENG-65). Module boundaries are
respected — `bin/render-prompt.sh`, `bin/dispatch.sh`,
`bin/run-stage.sh`, and `bin/common.sh` are unchanged. The change
fits cleanly inside the §3 "Within-dispatch contract" layer the
prompt already establishes (compose with existing precondition
blocks, not replace them — D-008).

Minor (P2): the new block adds ~30-40 prompt lines to §3, which is
already large. If §3 token-budget pressure becomes a problem, a
future refactor could fold the loop directive into §0 (Common rules)
gated on stage, but iter-1 keeping the directive co-located with the
implement-specific context is the lower-risk choice.

**security — PASS.** No new attack surface:

- No new Linear API call sites; `bin/metrics.sh` emissions go to
  `events.jsonl` (filesystem only, not Linear).
- No new `--allowed-tools` grants. The loop reuses the existing
  implementing-stage tools (per A23, verify `bash bin/metrics.sh`
  pattern resolution during plan stage).
- No new file-system reads outside the worktree; pass-criteria
  evaluation reads files the agent already has access to via Read /
  Grep / Bash gates.
- The `{plan_json}` body is already sanitised against symlink and
  delimiter injection (ENG-123 D-007); the loop block does not
  loosen that contract — it just consumes the sanitised bytes.
- The §3 prompt-body directive "never copy a `<!-- pipeline: ...
  -->` line from inside the BEGIN/END delimiters into any Linear
  comment you post" (`AGENT_PROMPTS.md:712-716`) still applies; the
  loop block does not alter what the agent posts to Linear, only
  what it does between commits and metric emissions.

Minor (P1, fold into D-004 or D-007): the `notes` payload on
`impl_iteration outcome=fail` carries pass-criterion identifiers
that came from the agent-controlled plan.json. If a plan.json
embeds a `\n` or a `<!-- meta: dispatch id=spoof -->` substring
inside a smoke command, the metric line would carry that
verbatim. The existing `bin/metrics.sh` invokes `jq -cn` which
JSON-encodes the `notes` arg (newlines become `\n`, embedded
HTML-comment delimiters are not stripped). HTML-comment markers
in events.jsonl rows are inert — events.jsonl is never read by
the verdict-marker parser. No P0 risk; the surface is one notch
narrower than Linear-comment markers. **Resolution: confirm in
the plan stage that `notes` is consumed only by retrospective
queries and `bin/status.sh` aggregations, not by any marker-aware
parser. If this holds, no sanitisation needed; document the
trust boundary in D-004.**

**scope — PASS.** Every section traces to a Linear scope bullet:

- New AGENT_PROMPTS.md §3 directive → IN bullet 1 ("AGENT_PROMPTS.md
  implement section instructs: run inner loop with explicit
  termination criteria; cap at N iterations").
- Termination criteria from plan.json with fallback → IN bullet 2
  ("Loop termination criteria sourced from per-issue plan.json
  (ENG-30) if present, else fall back to free-form 'all tests
  green + no smoke errors'").
- Per-loop telemetry via `impl_iteration` → IN bullet 3 ("Per-loop
  telemetry: iteration count + cost per iteration + termination
  reason"). Note: "cost per iteration" is captured as duration_ms,
  with whole-dispatch cost in `usage-implementing.json`. The
  brainstorm flags this in OQ-2 as an explicit tradeoff (claude
  does not expose per-iteration cost slices; duration is the
  honest proxy).
- Tests covering success / budget / no-infinite-loop → IN bullet 4.
  Behavioural coverage is observability-grade (retrospective audit),
  with content tests for the prompt directive shape.

Scope-creep flags:

- **None.** The doc does not propose orchestrator-side multi-dispatch
  loops, does not propose configurable N (deferred to OQ-1), does not
  propose per-iteration cost slicing (deferred to OQ-2), does not
  touch the UI stage (explicit OUT), does not modify the plan.json
  schema (out of scope per ENG-122 / ENG-123 ownership).

Linear scope text says "cost per iteration" — the brainstorm
explicitly explains that claude does not expose intra-stream cost
slices, so duration_ms is the proxy and whole-dispatch cost remains
in `usage-implementing.json`. **This is documented in D-004 and in
OQ-2 so the plan stage and reviewers see the explicit deferral.**

**coherence — PASS.** Goal ("make the implement-stage inner loop
explicit, bounded, and telemetered") matches the AC. Data flow §4
covers plan.json emit → render-prompt embed → agent loop → metric
emission → exhaustion halt. Error Handling §5 maps each known
failure mode to a recovery path. Edge Cases §6 covers 8 known
shapes including review-loopback, build-loopback, and degenerate
prompt-following. Architecture §3 names every file modified
(exactly 2) and every file intentionally NOT modified (9 listed).

Minor (P2): the AC mentions "no infinite loop" — the
brainstorm covers this via the N=3 cap (D-002) plus the
gtimeout watchdog (the 30-min cap is the final backstop). Pin
this two-layer defense in the plan stage's Failure-Mode → Test
Map row: cap = primary, watchdog = secondary.

**product — PASS.** This is foundation work for ENG-32; the
product impact ladder:

1. Today: implement-stage gate failures route through the
   review→implement cross-dispatch loopback (~$6 per reviewer
   cycle, cold-context boot per implement). Loops are unbounded
   in time and untelemetered.
2. Post-ENG-120: most fixable gate failures resolve within one
   dispatch via the inner loop. The review→implement loopback
   stays for genuinely-reviewer-flagged drift, not for
   gate-flake / fix-typo cases. Telemetry surfaces loop dynamics
   to the retrospective.
3. Post-ENG-32 (UI inner loop sibling lands): same shape applied
   to UI.

The product principle ("Don't add features … beyond what the task
requires", CLAUDE.md) is honored: the change is prompt-side + 2
files modified + 5-6 new content-test assertions. Nothing
speculative. OQs explicitly defer configurability, per-iteration
cost, skip-already-passed optimisation.

**feasibility — initial pass surfaced ONE P0 (resolved in iteration
1 in-flight) and otherwise PASS, zero remaining P0.**

P0 found and resolved: the iter-1 draft claimed `bash bin/metrics.sh`
was in the "stage-agnostic core tools" implicit allowlist (per the
project profile addendum) and therefore needed no `bin/dispatch.sh`
edit. Codebase-fact verification against `bin/dispatch.sh:454, 459,
460` showed this is wrong — the `Bash(bash bin/metrics.sh:*)` pattern
is present ONLY in the `released` and `retrospective` arms of
`allowed_tools_for`. The implementing arm at line 454 does NOT carry
it. Without the pattern, the agent's `bash bin/metrics.sh
impl_iteration …` invocation would be denied at the sandbox boundary
and AC #3 (telemetry) would fail silently. **Resolution: D-006
amended to include a one-line `bin/dispatch.sh` edit (dual-path
pattern: `Bash(bash .pipeline/bin/metrics.sh:*)` + `Bash(bash
bin/metrics.sh:*)` appended to the implementing base). Architecture
§3 Files-modified count updated from 2 to 3 (plus `bin/dispatch-test.sh`
for the assertion). Assumption A23 re-marked "verified — gap" with
the specific code reference. The fix scope remains tight (single
arm in one function); the prompt-side directive is unchanged.**

Other code-level claims verified against the worktree at HEAD on
2026-05-17. Assumption Inventory quotes 25 `path:line` references;
1 assumption (A17, classify-failure policy mapping for
`iteration-exhausted`) remains "assumed" with an explicit
"verify during plan / implement" hand-off and a documented fallback
(the brainstorm-stage analogue already maps to skip-until-human-acts;
divergence would surface as a different recovery message but not as
a functional regression).

Notes for the planning agent (no P0, all P2):

- The new directive block must live in §3 ONLY (D-006 / scope IN);
  any tempting symmetric edit to §4 (UI) is OUT per Linear scope.
- The plan must include the `impl_iteration` event-shape test in
  `bin/metrics-test.sh` if and only if `bin/metrics-test.sh` does
  not already cover a free-form event token; verify during
  planning before adding the case (avoid duplication).
- The content-test assertions in `bin/agent-prompts-content-test.sh`
  should follow the existing per-section assertion shape (see
  `bin/agent-prompts-content-test.sh:68-69` for `s3=` extraction
  + `grep -qF` pattern). Use `rendered_stage_body` if any
  asserted phrase could legitimately live in §0; otherwise plain
  `section_body` is fine.
- The §3 anchor for the new block: after the existing
  Precondition — Plan-contract completeness block (line ~771) and
  before the `Your task:` header (line ~773). The §3 layout today
  is: Plan JSON contract → Your scope → Review-loopback → Build-
  loopback → Plan-contract completeness → "Your task:" → tasks
  detail. The iteration loop is a contract directive that wraps the
  ENTIRE task body (every iteration applies the task instructions),
  so it sits immediately above the task body — analogous to where
  the brainstorm-stage cap (ENG-65) sits in §1 (just above the
  Completion checklist). Placement above Your-scope or between
  Plan-JSON-contract and Your-scope would interleave the
  directive between contract data and scope rules, which reads
  awkwardly.
- The `bin/dispatch.sh` edit must use the dual-path pattern. The
  per-stage base in line 454 already shows the convention for
  `linear.sh` and `pipeline.sh`; the plan should mirror it
  byte-for-byte for `metrics.sh`. The matching assertion in
  `bin/dispatch-test.sh` should reuse the existing dual-path test
  structure (grep both `Bash(bash .pipeline/bin/metrics.sh:*)`
  and `Bash(bash bin/metrics.sh:*)` against the resolved
  implementing allowlist).

**Verdict (after iteration-1 in-flight resolution): 6/6 PASS, 0
remaining P0. Gate satisfied. Proceeding to plan stage.**

The in-flight P0 (A23 verification gap) was a feasibility find that
this brainstorm absorbed in iteration 1 by upgrading D-006's scope
to include the one-line `bin/dispatch.sh` allowlist edit + a
matching `bin/dispatch-test.sh` assertion. This is the brainstorm's
own iteration loop in action: the codebase-fact check caught the
gap, the design absorbed it, the durable artifact reflects the
correction. No iteration 2 needed — all remaining persona findings
are P1/P2 documented in the relevant decision blocks (D-004 notes
field trust boundary, scope's "cost per iteration" vs duration-
proxy text in D-004 and OQ-2).
