# Durable Control-Loop Semantics

> **Artifact for §9.4 checklist #2** of [`brainstorm.md`](brainstorm.md). Specifies the
> execution semantics of the single TypeScript daemon (decision **B1**) that drives
> [`schema.sql`](schema.sql). This is the **substrate** control loop — NOT the autonomy
> layer (no LLM supervisor / UGL / memory; those are post-cutover increments I-C/I-D).
>
> **Acceptance (§9.4 #2), discharged in §6–§7:**
> 1. a step that already ran **returns its recorded result on replay**;
> 2. external side-effects carry **idempotency keys**;
> 3. **crash mid-step resumes at that step.**
>
> Status: draft 2026-06-19. Decisions tagged **CL-#** (defaults; revisable). Forks resolved by
> operator 2026-06-19: CL-2 = all external effects via the outbox; CL-3 = re-attempt + probe.

---

## 0. Vocabulary

- **Daemon** — the long-running TS process (launchd `KeepAlive`, decision **B4**). The *only*
  writer of the SQLite SoT (decision **B2**).
- **Workflow** — the lifecycle of one `ticket`, `design → released`. Long-running (days), many
  dispatches + human waits.
- **Step** — one durable unit of progress, a `workflow_step` row. Deterministic `step_key`; carries
  a recorded result; re-entrant via replay.
- **Worker** — a `claude -p` subprocess (the kept `dispatch.sh` leaf). Workers **return results**;
  they never write SQLite (B2).
- **Effect** — a change outside SQLite. **Local effect** = on this host (spawn a worker, run a
  build, local git). **External effect** = on a remote service (Linear, GitHub API, git push).

---

## 1. Design goals (what the loop optimizes for)

1. **Recover, don't halt.** The default response to an anomaly is absorb-and-continue or a durable,
   resumable wait — never a dead halt that strands a ticket (the disease named in §0/§2 of the spec).
2. **Durable + replayable.** Crash at any point resumes from the journal; effects are exactly-once.
3. **Single-writer simplicity.** One daemon writes one SQLite file (B2) — no two-writer class.
4. **Trivial to install `[GOAL-INSTALL]`.** A new operator brings up the whole system with **one
   command, no servers, no runtime install dance.** This is a hard constraint, not a nicety — it
   shapes concrete choices below (§10): a single self-contained binary, embedded SQLite (zero-ops,
   per §9.2), a self-bootstrapping schema, an auto-rendered `launchd` plist. Measured as a
   north-star: *time-to-first-ticket for a fresh operator* (target: minutes, one command).

---

## 2. Execution model (B1 / B2 / B4)

### 2.1 One daemon, one SoT, all projects `[CL-1 — confirm]`

A **single** daemon serves **all** projects against **one** SQLite file — a shift from today's
per-`PROJECT_SLUG` launchd jobs.
- *Why:* the single-writer invariant (B2) only means something with exactly one writer. One DB +
  one daemon makes "two authoritative writers (ENG-217) impossible" hold *globally*. K=2–3
  concurrency makes cross-project writer contention a non-issue. (Also serves GOAL-INSTALL: one
  service to install, not N.)
- Projects stay isolated by the `project_id` FK and the per-project `project.paused` breaker.

### 2.2 The event loop

`launchd KeepAlive` restarts the daemon if it dies; the daemon runs a continuous loop (not a
5-min `StartInterval` tick — that scheduling artifact and its lock/stuck-tick class are gone):

```
on_start():
  open_db(); PRAGMA foreign_keys=ON; busy_timeout=5000     # WAL persists in the file
  migrate()                       # §10 — self-bootstrap / apply pending schema migrations
  recover()                       # §6.1 — reconcile crash-interrupted steps + drain outbox
  loop()

loop():
  while running:
    drain_outbox()                # §5 — execute pending EXTERNAL effects idempotently
    poll_external_signals()       # §7.3 — CI status etc. -> deliver signals
    ready = SELECT * FROM v_ready_tickets
            ORDER BY <stage_index DESC, priority DESC, created_at ASC>   # ports poll.sh picker
    for ticket in ready:
      if inflight_count() >= K: break       # K = orchestrator.max_concurrent_features (2–3)
      spawn_async(advance_one_step, ticket)  # non-blocking; result journaled on completion
    await_any_completion_or(timeout=POLL_INTERVAL)   # wake on worker finish / signal / short sleep
```

`v_ready_tickets` already encodes "active, project not paused, **not parked on a pending signal**".
K resolves as today (`CLAUDE_MAX_CONCURRENT` → `orchestrator.max_concurrent_features` → 2). Workers
run concurrently; the daemon journals each result as it returns and never lets a worker touch SQLite.

### 2.3 `advance_one_step(ticket)` — the resolver

The workflow definition is **code**: a pure resolver maps current state + journal to the next step.

```
advance_one_step(ticket):
  key  = next_step_key(ticket)            # deterministic (CL-INV-1); the state machine
  step = upsert_step(ticket, key)
  if step.status == 'succeeded': return advance_one_step(ticket)  # already applied; move on (§6.2)
  if step.status == 'running':   return   # in-flight; recover() owns it
  if step.status == 'failed':    return apply_failure_policy(step)  # §8
  if not guard_holds(step): return park_or_block(step)   # §4 guard — precondition not yet met
  execute(step)                           # §3
```

`next_step_key` walks the **new C1 lifecycle** (DS-2): `design → implement[per work_unit] →
verify → review → merge → released`. The per-step Guard/Input/Output contract is §4.

---

## 3. The step contract (pure vs effectful)

`UNIQUE(ticket_id, step_key)` ⇒ **one row per logical step**. Retries increment `attempt` on the
same row (the journal stays a clean memo table keyed by logical identity).

**Pure step** (result is a deterministic function of data already in SQLite) — single transaction:
```
BEGIN; result = compute(input); UPDATE step SET status='succeeded', result_json=result;
       <downstream state changes + outbox enqueues>; COMMIT
```
Replay: resolver sees `succeeded`, returns `result_json`, never re-runs `compute`.

**Effectful step** — the effect can't join the DB tx, so **intent is journaled before the effect**,
and the effect is **idempotent** (universal write-ahead-intent discipline — for BOTH local and
external effects):
```
(1) BEGIN; UPDATE step SET status='running', attempt+=1, idempotency_key=K, started_at=now; COMMIT
(2) result = do_effect(step, K)          # idempotent (§5.2); EXTERNAL effects via the outbox
(3) BEGIN; UPDATE step SET status='succeeded', result_json=result;
           <state transition + outbox enqueues>; COMMIT
```
A crash between (1) and (3) leaves `status='running'` with a known `idempotency_key` — the sole
signal `recover()` needs (§6.1).

---

## 4. Step catalog — guards, inputs, outputs

The mechanics the resolver enforces. Each step declares: **Guard** (precondition to fire),
**Input** (what it consumes), **Output** (postcondition + rows written), **Effect/mode**,
**Idempotency**, **Failure→policy**. A step fires only when its Guard holds; an unmet guard parks
the ticket (on a signal) or blocks (waits for a sibling step), it does not fail.

### S1 · `design:dispatch`  (brainstorm+plan fused)
- **Guard:** `ticket.stage='design'`; worktree exists (else `S0:worktree-ensure` runs first); no
  succeeded `design:dispatch` unless a loopback re-design was requested.
- **Input:** ticket (ident, title, `type_label`); rendered design prompt (`render-prompt.sh` leaf)
  + project-profile; model = Opus 4.8 (F1); design tool allowlist.
- **Output:** committed plan artifact on branch; **`work_unit` rows inserted** by the daemon from
  the agent's validated structured plan (move 3 — orchestrator owns the envelope, agent emits
  content-only; zod-validated, inserted in step (3)'s tx) each with `kind` / `files_to_touch` /
  `behavioral` / `test_plan` / `verify_check_types`; a `dispatch` row; `pipeline_event` transition
  `design→implement`; outbox `set_labels`. **Postcondition: ≥1 `work_unit`; `ticket.stage='implement'`.**
- **Effect/mode:** spawn worker + local git commit (local).
- **Idempotency:** retry = fresh `dispatch_id`; branch re-entrant.
- **Failure→policy:** claude-death/timeout → retry; **no work_units / no plan committed** → re-prompt
  with the validation defect (the old plan-contract gate, now a structured re-prompt) → after
  `K_DISTINCT` → escalate.

### S2 · `implement:wuN:dispatch`
- **Guard:** `ticket.stage='implement'`; `wuN.status='pending'`; **every `wuN.depends_on` unit is
  `verified`**; plan committed; branch exists.
- **Input:** the `work_unit` spec (kind, description, `files_to_touch` advisory, `test_plan`);
  implement prompt; **kind-appropriate tool allowlist** (from the profile, per `wuN.kind`); model =
  Sonnet 4.6 (F1; escalates to Opus on loopback); **worktree rebased on `origin/<branch>` first**
  (the implement-rebase lesson — avoid duplicate work).
- **Output:** code committed for wuN; a `dispatch` row; `wuN.status='verifying'`.
  **Postcondition: branch HEAD advanced; diff non-empty.**
- **Effect/mode:** spawn worker + local git (local).
- **Idempotency:** fresh dispatch; branch re-entrant.
- **Failure→policy:** claude-death/timeout → retry; **noop (empty diff)** → re-dispatch; persistent
  → escalate.

### S3 · `verify:wuN:<check>`  (one per check-type in `wuN.verify_check_types`)
- **Guard:** `wuN.status='verifying'`; `<check> ∈ wuN.verify_check_types`; toolchain present
  (profile). **For `test` when `wuN.behavioral=1`:** a test realizing `test_plan` MUST exist (A1) —
  absent ⇒ fail back to S2.
- **Input:** the project-profile build/test/scope command (F4); worktree at wuN's commit; the
  check-type.
- **Output:** a **`ground_truth_signal`** row (`signal_type ∈ {build,test,scope_diff}`, `result`,
  `detail_json` = counts / changed-paths). When **all** of wuN's checks pass → `wuN.status='verified'`.
  (`scope_diff` is advisory — it is an *input to review* (A3), not a gate.)
- **Effect/mode:** run command in worktree (local).
- **Idempotency:** re-runnable (deterministic) — just re-run.
- **Failure→policy:** red build/test → loop back to S2 with the failure as feedback (bounded
  `K_DISTINCT`) → escalate; toolchain/infra error → retry.

### S4 · `verify:integration`  (ticket-level, C3)
- **Guard:** **all** `work_unit`s `verified`.
- **Input:** ticket-level integration build/test command; worktree at branch HEAD.
- **Output:** `ground_truth_signal`(integration); on pass → `pipeline_event` transition
  `implement→review`. **Postcondition: ticket ready for cold review.**
- **Effect/mode:** local.
- **Failure→policy:** red → loop back to the implicated unit (cutover: re-dispatch most-recently
  changed unit; the supervisor refines this later) bounded → escalate.

### S5 · `review:dispatch`  (independent cold-context reviewer, A2/A4)
- **Guard:** `verify:integration` passed.
- **Input:** the **diff + plan + verify/CI results + scope_diff signal** — **NOT** the implementer's
  transcript (A2 cold context); reviewer prompt; Opus 4.8 (F1); read-mostly tools.
- **Output:** **`review_finding`** rows (`adjudicated_severity`, `blocks_ship`, `decision_factors`);
  a verdict. 0 blocking → transition `review→merge`. ≥1 blocking → loop back to S2 for the targeted
  units (bounded → escalate). Reviewer also **judges scope expansion** (A3).
- **Effect/mode:** spawn worker (local; emits findings only).
- **Idempotency:** fresh dispatch.
- **Failure→policy:** blocking findings → loopback (NOT a halt); reviewer-death → retry.

### S6 · `merge:push`  (EXTERNAL → outbox/github)
- **Guard:** review approved; local branch ahead of base.
- **Input:** branch name, head SHA, remote.
- **Output:** branch on origin; outbox row `sent` (`response_ref`).
- **Effect/mode:** `git push` (external; outbox).
- **Idempotency:** **probe** — remote ref already at local SHA ⇒ no-op (re-push same SHA is safe).

### S7 · `merge:pr-ensure`  (EXTERNAL → outbox/github; result-bearing)
- **Guard:** branch pushed.
- **Input:** branch, base, PR title/body (from plan + stage summaries).
- **Output:** a PR exists; `response_ref` = PR number/url; **delivers the parked signal** so the
  workflow resumes with the PR ref (§5.3).
- **Effect/mode:** `gh pr create` (external; outbox).
- **Idempotency:** **probe** — `gh pr view <branch>`; create only if absent (no natural key).

### S8 · `merge:await-ci`  (durable wait → `external_ci`)
- **Guard:** PR exists.
- **Input:** PR ref; the **required check name** (F3 self-hosting meta-gate; A1: CI green = the
  merge arbiter; PR #184 hermeticity is the prereq).
- **Output:** signal delivered on green → proceed. Red ⇒ loop back to S2 (CI found a real failure)
  bounded → escalate. Budget exhausted ⇒ escalate.
- **Effect/mode:** none — CI enters as a delivered signal (§7.3), never a control-flow read.

### S9 · `merge:await-human`  (durable wait → `human_merge_approval`; the SINGLE human gate, D2)
- **Guard:** CI green.
- **Input:** a needs-you-inbox entry (PR link, plan, ground-truth evidence summary).
- **Output:** operator performs the merge (D2 — fully human-gated initially) ⇒ signal delivered ⇒
  transition `merge→released`.
- **Effect/mode:** none (operator merges in GitHub; daemon observes via poll/webhook or an inbox
  "done"). Auto-merge earned later per ticket-class via the learning loop.

### S10 · `released:project`  (EXTERNAL → outbox/linear; terminal)
- **Guard:** PR merged (signal delivered).
- **Input:** ticket, `linear_issue_uuid`, terminal state.
- **Output:** Linear projected to Done; `ticket.stage='released'`, `status='done'`.
- **Effect/mode:** outbox `set_state` (external).
- **Idempotency:** declarative (set-to-desired is idempotent).

**Generic mechanics:**
- **Transitions are not standalone steps** — a `pipeline_event` transition + its `set_labels` outbox
  enqueue commit *inside the producing step's* tx (§3), so state and projection never diverge.
- **`project:*`** = the outbox rows themselves, drained by §5.
- **`await_signal`** = the parking primitive (§7.1); S8/S9 are instances.

---

## 5. External effects — the outbox (B3) `[CL-2: all external effects via the outbox]`

Every **external** effect (Linear, GitHub API, git push) is a `projection_outbox` row, enqueued in
the **same transaction** as the state change that motivates it, and drained idempotently by the
daemon. (Local effects — dispatch, verify, local git — use the same write-ahead-intent discipline
of §3 but execute inline; only *external* effects need the async durable queue.) This is the
cleanest expression of move 2 ("Linear/GitHub are one-way projections") + B3: state-change and
its projection commit atomically, so they can never disagree — the ~30-ticket reconciliation class
is gone by construction.

### 5.1 The drainer
```
drain_outbox():
  for row in SELECT * FROM projection_outbox WHERE status='pending' ORDER BY created_at:
    try:
      ref = apply_idempotent(row)                  # §5.2
      UPDATE projection_outbox SET status='sent', response_ref=ref, sent_at=now WHERE id=row.id
      if row delivers a result: deliver_signal(row)   # §5.3
    catch transient: UPDATE ... SET attempts=attempts+1, error=... WHERE id=row.id   # retried next loop
```
`projection_outbox.idempotency_key` is `UNIQUE` — enqueuing the same effect twice is a no-op insert.

### 5.2 Reconciliation: re-attempt + probe `[CL-3]`
**Re-attempt the effect; make the duplicate harmless by probing the external system for the change,
and use a key where one exists.** (Operator 2026-06-19: probe external state — "comment already
posted? PR already opened?" — and handle cases where a key can't dedup.)

| Effect | How a duplicate is absorbed |
|---|---|
| Linear `add_comment` | **probe** — grep recent comments for the `idempotency_key` tag (`<!-- meta: key=… -->`); post only if absent (the API has no native key) |
| Linear `set_labels` / `set_state` | **declarative** — setting to the desired set is idempotent |
| git `push` | **probe** — remote ref already at SHA ⇒ skip |
| `gh pr create` | **probe** — `gh pr view <branch>` ⇒ skip if present |
| `gh pr merge` | **probe** — already merged ⇒ skip (irreversible; never blind re-attempt) |

Probe-first specifically guards the **no-native-key** and **irreversible** effects; declarative
effects need no probe.

### 5.3 Result-bearing effects → signals
`gh pr create` returns a PR number the workflow needs. The step **enqueues the outbox row and parks
on a signal**; the drainer writes `response_ref` and **delivers that signal**; the workflow resumes
reading it. One mechanism (signals) covers both human waits and result-bearing external effects.

---

## 6. Crash & resume — discharging §9.4 #2

### 6.1 Recovery on daemon start
```
recover():
  for step in SELECT * FROM workflow_step WHERE status='running':
    kill_orphan(step)                  # journaled PID still alive (dispatch) -> kill (ENG-131 lesson)
    if reattemptable(step): reset to 'pending'        # idempotent/probe-guarded -> normal re-exec
    else (irreversible w/ probe): if probe_says_done: mark 'succeeded'(reconstructed) else 'pending'
  drain_outbox()                        # pending external effects are idempotent -> safe replay
```
Because §3 commits **intent before effect**, a `running` row is the complete record of "an effect
may be half-done here." Nothing else needs scanning.

### 6.2 Replay returns the recorded result
The resolver **never re-executes a `succeeded` step** — it reads `result_json`; the journal *is* the
memo table. With §5.2 idempotency, every operation is at-least-once-attempted, exactly-once-effective.
The §9 determinism rules keep `step_key`s stable so replay always finds the prior row.

### 6.3 Dispatch crash (worked)
`claude -p` in flight when the daemon dies: step `{dispatch, running, pid:12345}`, no `result_json`.
Restart → `recover()` → kill 12345 if alive → `reattemptable` (dispatch is always safe to redo:
agent work is re-entrant against the branch) → reset to `pending` → `advance` re-dispatches as a
**fresh** `dispatch_id`. Partial work already committed is the next worker's starting point — git is
the durable substrate for code, the journal for control. *Dispatch retry = fresh attempt, not cached
replay; only external effects get exactly-once keys.*

---

## 7. Durable waits — signals (B1 "durable human-waits")

Replaces `wait-<stage>.json`, soft-pending parking, and the single build-approval gate.

### 7.1 Parking
```
BEGIN
  INSERT INTO signal(ticket_id, signal_type, reason, max_attempts, first_attempt_at, requested_at) …
  UPDATE workflow_step SET status='running', await_signal_id=<new>
  UPDATE ticket SET status='waiting'
COMMIT
```
The ticket now fails `v_ready_tickets`' `NOT EXISTS (pending signal)` clause — no busy-wait, no
polling cost for human waits.

### 7.2 Delivery → resume
A deliverer sets `signal.status='delivered'` (+ `payload_json`) and `ticket.status='active'`. Next
loop, the await step sees its signal delivered → `succeeded` (result = payload) → proceeds.

| Signal type | Delivered by |
|---|---|
| `human_merge_approval` (D2 single gate) | operator via the needs-you inbox CLI/endpoint (D3) |
| `human_plan_approval` (optional, large tickets) | operator |
| `human_resume` (escalation, §8) | operator (`decide --action continue` equivalent) |
| `external_ci` | §7.3 poll (webhook later) |
| `external_review` | the `review:dispatch` step completing (internal) |

### 7.3 External signal delivery
CI status is **not** a control-flow read of GitHub (move 2 forbids it) — it **enters as a delivered
signal.** For cutover the daemon **polls** open `external_ci` signals' PR checks on an interval and
delivers on green (webhook is a later optimization). The budget fields (`attempts`, `max_attempts`,
`first_attempt_at`) port `external_signal_budget`: exhausting it converts the wait into a
`human_resume` escalation rather than waiting forever.

---

## 8. Step-level failure handling (deterministic; NO supervisor yet)

The cutover loop has only the **deterministic fast-path** — the slimmed `failure_outcome` table
(the ~31 codes that no longer exist are gone, per Deliverable 1). No LLM classifier.
```
apply_failure_policy(step):
  o = step.error_json.outcome
  if o in {dispatch-failed(20), dispatch-timeout(124)}:        # liveness/infra
     if within_budget(step): backoff_retry(step) else escalate(step)     # NEVER a pipeline halt
  elif o in {build-red, tests-red, reviewer-blocking, ci-red}: # ground-truth KEEP↻
     if distinct_attempts(step) < K_DISTINCT: redispatch_with_feedback(step) else escalate(step)
  else: escalate(step)                                          # unknown / irreducible
```
- **Escalate = a durable wait, not a dead halt** — opens a `human_resume` signal, sets
  `ticket.status='waiting'`, surfaces in the inbox (D3). The core behavior change vs today.
- **Bounded by budget (F2):** `K_DISTINCT` *distinct* corrective attempts (not identical retries);
  per-ticket retry/token/wall-clock caps; escalation budget **3 consecutive / 20 total** — all
  **derived** from `dispatch` + `v_rejection_counts` + `pipeline_event` (no budget table for cutover).
- **scope-violation** is absent here — reviewer-judged now (A3), an advisory input to S5.

---

## 9. Invariants a step author MUST hold

- **CL-INV-1 — stable keys.** `step_key` is a pure function of (ticket, work_unit, logical
  position). Never embed a timestamp / random / `dispatch_seq` / attempt — else replay can't find
  the row.
- **CL-INV-2 — allocate-once.** Ids/timestamps an effect needs (`dispatch_id`, idempotency keys) are
  allocated when the step row is created and journaled; replay reuses, never re-allocates.
- **CL-INV-3 — one transaction.** Every state transition + its outbox enqueues commit in one tx;
  effects live outside it, fronted by write-ahead intent (§3).
- **CL-INV-4 — keyed/probed effects.** External effects are idempotent via probe + key (§5.2); local
  effects are re-entrant or probe-guarded.
- **CL-INV-5 — DB is the only control input.** Control flow reads SQLite only; external systems are
  write-only projections; CI/human facts arrive as **delivered signals**, never a live read.
- **CL-INV-6 — single writer.** Only the daemon writes SQLite (B2); workers return results.
- **CL-INV-7 — display-local.** Timestamps stored UTC; every operator-facing surface renders host
  local time (DS-1).

---

## 10. Installation & operability `[GOAL-INSTALL]`

A fresh operator must reach first-ticket with **one command and no server setup.** Concrete design
implications the daemon owns:

- **Single self-contained binary.** TS compiled to one executable (`bun build --compile` / pkg) —
  node bundled, no global `npm i`, no version dance. Escapes the bash-3.2 curse (UTF-8 hang,
  `local -A`, gtimeout PATH) entirely.
- **Embedded SQLite, zero-ops** (`bun:sqlite` / better-sqlite3). No DB server to install, run, or
  back up beyond copying one file (§9.2). WAL is on by default.
- **Self-bootstrapping schema.** On start, `migrate()` reads `schema_meta.version` and applies
  pending migrations (creating the DB + full schema on first run). No manual `sqlite3 < schema.sql`.
- **One-command setup.** `harness setup <target-repo>`: creates the SQLite file + migrates, seeds the
  `project` row, refreshes the `linear_id_cache`, renders **and** `launchctl bootstrap`s the single
  `KeepAlive` plist. **Idempotent** — re-runnable safely.
- **Minimal host contract.** Just the binary + `claude` CLI + `git` + `gh`; `sqlite3` optional for
  debugging. One config file (the existing `config.json` shape) + one secrets file; **no ambient
  `LINEAR_API_KEY`** in the agent env (move 4 — the orchestrator holds creds).
- **Observability built in.** `harness status` (reads SQLite, renders **local-tz** per DS-1) and the
  needs-you inbox (D3) ship with the binary — no extra dashboards to stand up.

*North-star:* time-to-first-ticket for a brand-new operator, single command. (Added to the spec's
§6 metrics.)

---

## 11. Worked example — ENG-9, full-track backend+frontend feature

Journal the daemon writes, `design → released` (one row per durable point):

| # | `step_key` | type | result | other rows |
|---|---|---|---|---|
| 1 | `design:dispatch` | dispatch | plan + decomposition | `dispatch` d0001; `work_unit` wu1(backend), wu2(frontend); transition design→implement; outbox set_labels |
| 2 | `implement:wu1:dispatch` | dispatch | backend code | `dispatch` d0002 |
| 3 | `verify:wu1:build` | verify | pass | `ground_truth_signal`(build) |
| 4 | `verify:wu1:test` | verify | pass | `ground_truth_signal`(test); wu1=verified |
| 5 | `implement:wu2:dispatch` | dispatch | frontend code | `dispatch` d0003 |
| 6 | `verify:wu2:visual` | verify | pass (Playwright) | `ground_truth_signal`; wu2=verified |
| 7 | `verify:integration` | verify | pass | `ground_truth_signal`; transition implement→review |
| 8 | `review:dispatch` | dispatch | 0 blocking → approve | `dispatch` d0004; `review_finding`s; transition review→merge |
| 9 | `merge:push` | outbox/github | branch pushed | outbox push (probe on SHA) |
| 10 | `merge:pr-ensure` | outbox/github | PR# | outbox pr_create (probe); delivers signal |
| 11 | `merge:await-ci` | await_signal | CI green | `signal`(external_ci) delivered by poll |
| 12 | `merge:await-human` | await_signal | operator merges | `signal`(human_merge_approval); waiting→active |
| 13 | `released:project` | outbox/linear | Done; status=done | transition merge→released |

A backend-only ticket drops 5–6; **1 work-unit = 1 implement dispatch**, no waste.

---

## 12. Mapping to §9.4 #2 + open questions

**Acceptance discharged:** ✅ replay returns recorded result (§6.2) · ✅ external effects carry
idempotency keys (§5) · ✅ crash mid-step resumes (§6.1).

**Open (don't block #2):**
- **CL-1** one daemon / one DB / all projects — confirm the shift from per-project launchd.
- CI delivery: poll (cutover) vs webhook (later) — §7.3.
- Budgets derived vs a dedicated table — §8.
- Escalation/inbox surface (D3) — specify the `human_*` deliverer endpoint with the projector artifact.

**Resolved 2026-06-19:** CL-2 (all external effects via outbox) · CL-3 (re-attempt + probe) · step
granularity = one step per durable decision point · GOAL-INSTALL added (§1/§10).

**Next artifact:** §9.4 #3 — the one-time state-import mapping (`issue-state.json` + labels + marker
history → rows), then #4 the Linear one-way projector (the outbox drainer's Linear adapter).
