# Pipeline vocabulary

The harness's state machine is driven by HTML comments embedded in Linear
issues. There are two families:

- **`<!-- pipeline: <event> ... -->`** — drives state. Read by the orchestrator.
- **`<!-- meta: <kind> ... -->`** — bookkeeping (dedup keys, metric counters,
  evidence bundles). Read by individual scripts; never affects pipeline state.

## Anatomy of a marker

Every pipeline-driving comment carries one HTML marker on its own line.
The shape:

```
<!-- pipeline: verdict result=halt stage=implementing reason=scope-violation -->
       │           │       │             │                   │
       │           │       │             │                   └─ reason — closed token from halt_reasons
       │           │       │             └───────────────────── stage — closed token from stages
       │           │       └─────────────────────────────────── result — closed token from verdict_results
       │           └─────────────────────────────────────────── event name (verdict | transition | decision | …)
       └─────────────────────────────────────────────────────── family ("pipeline:" drives state, "meta:" is bookkeeping)
```

Every key=value pair is validated against the closed registry below.
Unknown tokens cause `bin/pipeline.sh` to die loudly. Unknown fields
attached by hand are ignored by the orchestrator.

## Writing markers

Use `bin/pipeline.sh` — never hand-craft marker bodies.

- `bin/pipeline event <issue> verdict <result> [--stage X] [--target Y] [--reason Z]`
- `bin/pipeline event <issue> transition "<from> → <to>"`
- `bin/pipeline decide <issue> --action <action> [--gate <gate>]`

## Who writes what

Different actors write different markers. Knowing who emits which is
load-bearing when reading a thread:

| Actor | Markers emitted |
|---|---|
| **Orchestrator** (`bin/run-stage.sh`, `bin/verdict-handler.sh`, `bin/classify-failure.sh`) | `transition`, `verdict result=halt`, `verdict result=fail` (when scope-check rejects), `decision action=continue` (operator-resume waypoint), `meta: dedup`, `meta: metric`, `meta: forensic` |
| **Agent** (`claude -p` running with the per-stage prompt) | `verdict result=pass\|fail\|halt\|wait\|pivot` (declares its own outcome), `meta: evidence` (TDD evidence comments), `meta: dedup` (when it edits in place via `bin/pipeline.sh`) |
| **Operator** (you, via CLI) | `decision action=continue\|approve\|abandon` (via `bin/pipeline.sh decide`); occasionally raw `verdict` markers for forensic recovery |
| **Retrospective** (`bin/run-retrospective-local.sh`) | None. The retrospective writes PRs to `learned-rules/`, not Linear comments. |

The verdict family is the most stage-shaped: agents declare a verdict
on completing their stage, the orchestrator may override it (e.g., turn
a `pass` into a `halt` if scope-check rejects), and the operator very
rarely writes one by hand.

## Reading the registry

The registry below lists every closed token. A few sections need
context that the generated list can't carry:

- **`verdict_results`** — what an agent or the orchestrator can declare
  about a stage's outcome. `pass` (advance), `fail` (loop back to
  `target`), `halt` (operator action required), `wait` (depends on an
  external signal — only valid for `building`), `pivot` (rare — change
  trajectory, currently only `pivot_targets=planning`).
- **`halt_reasons`** — why a halt was emitted. Reasons map roughly to
  failure-outcome exit codes; see [`architecture.md#failure-taxonomy`](architecture.md#failure-taxonomy).
- **`wait_reasons`** — `awaiting-approval` is the post-QA human gate at
  build P2. `awaiting-ci` covers explicit CI poll waits. Both are
  building-only; review/QA never wait.
- **`fail_targets`** — the asymmetric list `[brainstorming, planning,
  implementing, ui]` is intentional. These are the stages where a fail
  loops *back* to a productive earlier stage. `reviewing`, `qa`,
  `building`, `released` aren't valid loopback targets — they fail to
  `halt` instead.
- **`pivot_targets`** — currently only `planning`. Used when an agent
  decides the plan itself was wrong; rare.
- **`decision_actions`** — operator actions. `continue` is the
  catch-all resume; `approve` requires `--gate`; `abandon` is terminal.
- **`decision_gates`** — `scope` (approve a scope-check rejection),
  `build-cap` (bypass the human-approval gate at build P2). New gates
  land here as the harness adds them.
- **`meta_kinds`** — `dedup` (sig-based edit-in-place), `metric` (typed
  counter event), `evidence` (TDD evidence bundle), `reapplied` (timestamp
  footer for re-emitted comments), `forensic` (post-mortem artefact).
- **`stages`** — gerund form. Always. `brainstorm` (missing `-ing`)
  silently falls through unknown-key paths in several configs.

## Worked example 1 — happy path (no halt)

A typical six-stage clean run:

1. Issue filed at `Todo` with label `Feature`. Poll picks it up.
2. **Brainstorm**:
   ```
   bin/pipeline.sh event ENG-N verdict pass --stage brainstorming
   bin/pipeline.sh event ENG-N transition "brainstorming → planning"
   ```
3. **Plan**:
   ```
   bin/pipeline.sh event ENG-N verdict pass --stage planning
   bin/pipeline.sh event ENG-N transition "planning → implementing"
   ```
4. **Implement** + **Review** + **QA** repeat the same shape.
5. **Build P2** (the only stage that can wait):
   ```
   bin/pipeline.sh event ENG-N verdict wait --reason awaiting-approval
   ```
   Operator approves the PR in GitHub. Next tick:
   ```
   bin/pipeline.sh event ENG-N verdict pass --stage building
   bin/pipeline.sh event ENG-N transition "building → released"
   ```
6. **Released**:
   ```
   bin/pipeline.sh event ENG-N verdict pass --stage released
   ```

Every transition + verdict is a separate Linear comment. Sigs
(`<!-- meta: dedup key=halt/<stage>/<issue> -->`) keep repeats from
accumulating.

## Worked example 2 — scope-violation halt → approval → resume

1. Implement agent finishes 6 commits cleanly:
   ```
   bin/pipeline.sh event ENG-N verdict pass --stage implementing
   ```
2. Orchestrator runs scope-check → SEVERE violation. Posts:
   ```
   <!-- pipeline: verdict result=halt reason=scope-violation -->
   ```
   Applies `pipeline:halted`. The dedup sig is `halt/implementing/ENG-N`.
3. Operator inspects the halt comment, judges the touches intentional:
   ```
   bin/pipeline.sh decide ENG-N --action approve --gate scope
   ```
   Posts a `decision action=approve gate=scope` marker.
4. Next tick, scope-check sees the approval and bypasses the gate.
   The orchestrator transitions:
   ```
   <!-- pipeline: transition from=implementing to=reviewing -->
   ```

For "I just want it to resume, no scope debate," the universal command
is `bin/pipeline.sh decide ENG-N --action continue` — see
[`operations.md#resolving-a-halt`](operations.md#resolving-a-halt).

<!-- GENERATED:registry -->
## Closed event registry

Source: `bin/pipeline-events.json` — edit there, not here.

### `verdict_results`

- `pass`
- `fail`
- `halt`
- `wait`
- `pivot`

### `halt_reasons`

- `agent-blocked`
- `agent-failure`
- `smoke-failed`
- `iteration-exhausted`
- `scope-violation`
- `protocol-violation`
- `dispatch-timeout`
- `pr-opened-too-early`

### `wait_reasons`

- `awaiting-approval`
- `awaiting-ci`

### `fail_targets`

- `brainstorming`
- `planning`
- `implementing`
- `ui`

### `pivot_targets`

- `planning`

### `decision_actions`

- `continue`
- `approve`
- `abandon`

### `decision_gates`

- `scope`
- `build-cap`

### `meta_kinds`

- `dedup`
- `metric`
- `evidence`
- `reapplied`
- `forensic`

### `stages`

- `brainstorming`
- `planning`
- `implementing`
- `ui`
- `reviewing`
- `qa`
- `building`
- `released`

<!-- /GENERATED:registry -->
