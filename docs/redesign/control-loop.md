# Durable Control-Loop Semantics

> **Artifact for §9.4 checklist #2** of [`brainstorm.md`](brainstorm.md). The execution semantics of
> the single TypeScript daemon (decision **B1**) that drives [`schema.sql`](schema.sql). Substrate
> only — NOT the autonomy layer (no LLM supervisor / memory; those are post-cutover increments).
>
> **Acceptance (§9.4 #2), discharged in §6–§7:** (1) a step that already ran returns its recorded
> result on replay; (2) external side-effects carry idempotency keys; (3) crash mid-step resumes
> at that step.
>
> Status: step catalog frozen 2026-06-19 after a full operator walkthrough (S1–S10). Decisions
> tagged **CL-#**.

---

## 0. Vocabulary

- **Daemon** — the long-running TS process (launchd `KeepAlive`, **B4**). The only writer of the
  SQLite SoT (**B2**).
- **Workflow** — the lifecycle of one `ticket`, `design → released`. Long-running; many dispatches
  and human waits.
- **Step** — one durable unit of progress, a `workflow_step` row. Deterministic `step_key`; carries
  a recorded result; re-entrant via replay. `UNIQUE(ticket_id, step_key)` → one row per logical
  step; retries increment `attempt`.
- **Worker / dispatch** — a `claude -p` agent run (the kept `dispatch.sh` leaf). Workers return
  results; they never write SQLite (B2).
- **Effect** — a change outside SQLite. **Local** = on this host (spawn a worker, run a build, local
  git). **External** = on a remote service (Linear, GitHub, git push) → always via the outbox (§5).

---

## 1. Design goals

1. **Recover, don't halt.** Any anomaly is absorbed, looped with feedback, or parked as a resumable
   wait — never a dead halt that strands a ticket.
2. **Durable + replayable.** Crash anywhere resumes from the journal; effects are exactly-once.
3. **Single-writer simplicity (B2).** One daemon writes one SQLite file.
4. **Trivial to install (`GOAL-INSTALL`).** A new operator brings up the whole system with one
   command, no servers, no runtime dance (§10). A hard constraint that shapes real choices below
   (e.g. polling over webhooks in S8).

---

## 2. Execution model (B1 / B2 / B4)

### 2.1 One daemon, one SoT, all projects `[CL-1 — DECIDED 2026-06-19]`
A single daemon serves all projects against one SQLite file (a shift from today's per-project
launchd jobs). The single-writer invariant only means something with exactly one writer; one DB +
one daemon makes two-authoritative-writers (ENG-217) impossible globally. K=2–3 concurrency makes
contention a non-issue, and it serves GOAL-INSTALL (one service, not N). Projects stay isolated by
the `project_id` FK and the per-project `project.paused` breaker.

### 2.2 The event loop
```
on_start():
  open_db(); PRAGMA foreign_keys=ON; busy_timeout=5000
  migrate()                       # §10 self-bootstrap / apply pending schema migrations
  recover()                       # §6.1 reconcile crash-interrupted steps + drain outbox
  loop()

loop():
  while running:
    drain_outbox()                # §5 execute pending external effects idempotently
    poll_external_signals()       # §7.3 checks-system status, PR-merged -> deliver signals
    ready = SELECT * FROM v_ready_tickets ORDER BY <stage_index DESC, priority DESC, created_at ASC>
    for ticket in ready:
      if inflight_count() >= K: break       # K = orchestrator.max_concurrent_features (2–3)
      spawn_async(advance_one_step, ticket)
    await_any_completion_or(timeout=POLL_INTERVAL)
```
`v_ready_tickets` already excludes paused projects and tickets parked on a pending signal. Workers
run concurrently; the daemon journals each result as it returns. **No worker touches SQLite.**

### 2.3 `advance_one_step(ticket)` — the resolver
A pure resolver maps current state + journal to the next `step_key`; the workflow definition is code.
```
key  = next_step_key(ticket)              # deterministic (CL-INV-1); the state machine
step = upsert_step(ticket, key)
if step.status == 'succeeded': recurse    # already applied; move on (§6.2)
if step.status == 'running':   return     # in-flight; recover() owns it
if step.status == 'failed':    return apply_failure_policy(step)   # §8
if not guard_holds(step):      return park_or_block(step)
execute(step)                              # §3
```
The lifecycle is the new C1 vocab (DS-2): `design → implement → verify → review → merge → released`,
expanded by the step catalog (§4).

---

## 3. The step contract

**Pure step** (result is a deterministic function of SQLite data) — single transaction: compute →
`UPDATE … status='succeeded', result_json=…` + downstream changes + outbox enqueues, all atomic.
Replay returns `result_json`; never re-runs.

**Effectful step** — the effect can't join the DB transaction, so **intent is journaled before the
effect** and the effect is **idempotent** (universal write-ahead discipline):
```
(1) BEGIN; UPDATE step SET status='running', attempt+=1, idempotency_key=K, started_at=now; COMMIT
(2) result = do_effect(step, K)          # idempotent; EXTERNAL effects via the outbox (§5)
(3) BEGIN; UPDATE step SET status='succeeded', result_json=result;
           <state transition + outbox enqueues>; COMMIT
```
A crash between (1) and (3) leaves `status='running'` with a known `idempotency_key` — the sole
signal `recover()` needs (§6.1).

---

## 3a. Structured output: act through a validated interface, never parse a free-form blob `[CL-FROZEN]`

The single most load-bearing reliability rule, and the reason the review stage was redesigned:

> **An agent never emits a serialized decision for the daemon to parse. It takes actions through a
> schema-validated tool interface, and the daemon computes the decision from the resulting state.**

Why: a serialized JSON verdict conflates two failure modes the daemon must distinguish — *malformed
output* vs *a real "no" decision*. If they share one channel, a formatting slip masquerades as a
deny, the daemon conservatively re-runs an expensive agent, and the format-error rate is
unmeasurable (so unhardenable). The validated-interface pattern dissolves this:

- structured values are submitted via **forced-schema tool calls** (Anthropic SDK constrained
  decoding): the model **cannot** emit a shape that violates the schema; a malformed call returns a
  tool-error and the model **self-corrects in-context** (cheap, same dispatch — no re-run).
- the daemon then only ever observes two unambiguous states: **completed** (a clean dispatch end /
  an explicit `complete()` call → state present → deterministic decision) or **transport failure**
  (dispatch died / never completed → retry the dispatch). These are separately counted and
  separately hardenable.
- the daemon **computes** the decision from the accumulated state, never from a parsed blob.

**Reason/extract, refined.** The expensive reasoner emits rich content (its strength). Turning that
into schema rows happens via the validated interface, by one of two means:
- **mechanical formalization** (e.g. a plan → `work_unit` rows) → a *cheap* model does it, as a cost
  optimization (the cheap-extractor split). It is not judging, only formalizing.
- **judgment-bearing fields** (e.g. a review finding's severity) → the *reasoner itself* files them
  via forced-schema tool calls, because the fields *are* its judgment; a cheap model must not
  re-derive judgment from prose.

The cheap extractor is an optimization; the validated interface + state-derived decision is the
correctness mechanism.

---

## 4. Step catalog — guards, inputs, outputs, tools

Each step declares **Guard** (precondition to fire), **Input**, **Output** (postcondition + rows),
**Tools** (agent steps) or **Commands/Capability** (daemon steps), **Model** (agent steps), and
**Failure → route** (see the Loopback Atlas, §8). An unmet guard *parks or blocks*, it does not fail.

Capability frame (move 4) applies to every agent step: the **worktree is the only writable surface**;
agents have **no outward tools** — no `gh`, no `git push`, no Linear, no ambient key, no `curl`.
Every external effect is the daemon's (§5). **The daemon commits, not the agent** (`[CL-COMMIT]`):
agents only edit files; the daemon commits each dispatch's worktree changes with a deterministic
message (incl. `dispatch_id`) and records the SHA — so agents need no git tool at all.

> **Orchestration is the daemon's, not a master agent's (`[CL-ORCH]`).** The implement phase is a
> *sequence of focused steps the daemon orchestrates* (rebase → implement → verify …), not one
> LLM "master agent" driving sub-agents. An LLM orchestrator would be non-deterministic, unjournaled,
> and un-resumable mid-sequence, and would need broad spawn authority. The daemon owns the
> *between-step* orchestration; an agent owns only its *within-step* loop (e.g. implement's
> code↔test iteration).

### Design

**S1a · `design:dispatch`** — fused brainstorm + plan (Opus 4.8)
- **Guard:** `stage='design'`; worktree exists (else `worktree-ensure` runs first); no succeeded
  `design:dispatch` unless a re-design loopback was requested.
- **Input:** ticket identity/title/`type_label` + description **injected by the daemon** (the agent
  does not read Linear); the design prompt (`render-prompt.sh`) + project-profile.
- **Output:** a committed **plan artifact** (`docs/plans/<date>-<eng-n>-*.md`, `linear: ENG-N`
  frontmatter). The plan must *contain*, per work-unit, the facts S1b needs (kind, files, behavioral?
  + how tested, verify check-types, dependencies) — as prose, never as JSON. Sets `needs_docs`
  (whether the change is doc-impacting).
- **Tools:** `Read`, `Grep`, `Glob`; `Write`/`Edit` **restricted to `docs/**`**; `WebSearch`,
  `WebFetch`, Context7 (read-only). ❌ no `Bash`, no outward tools.
- **Failure → route:** D2/D3 in §8.

**S1b · `design:extract`** — decomposition into `work_unit` rows (Haiku 4.5, forced structured output)
- **Guard:** S1a succeeded (plan committed).
- **Input:** the committed plan doc + the `work_unit` schema.
- **Output:** validated **`work_unit` rows** (kind / files_to_touch / behavioral / test_plan /
  verify_check_types / depends_on). Daemon zod-validates. **Postcondition: ≥1 work_unit;
  `stage='implement'`.**
- **Mechanism:** mechanical formalization → cheap model, forced-schema tool calls (§3a).
- **Failure → route:** shape failure → cheap retry (D1); genuine content gap (plan lacks required
  info) → loop back to S1a (D2); no plan / no units (D3).

### Implement (per work-unit; daemon-orchestrated sequence)

**S2a · `implement:wuN:rebase`** — keep the branch current (hybrid: daemon-first, agent-on-conflict)
- **Guard:** branch is behind `origin/<base>`.
- **Daemon path (common, no LLM):** `git rebase origin/<base>`; clean → done, journal new HEAD.
- **Conflict → conflict-resolution agent (Sonnet 4.6; Opus on repeat):**
  - **Input:** conflicted files (markers), the plan doc (intent), both sides, profile.
  - **Output:** resolved files. The **daemon** then `git add` + `rebase --continue` and re-runs verify.
  - **Tools:** `Read`, `Grep`, `Glob`, `Write`, `Edit` (worktree); scoped `Bash` = read-only git +
    profile test/build self-check. ❌ no git-write (daemon drives `--continue`), no push/`gh`.
- **Note:** during implement the branch is local-only (push is at merge), so rebase needs no
  force-push. A rebase *after* push uses **force-push-with-lease to the feature branch only — never
  `main`/protected** (`hard_deny`).
- **Failure → route:** R1/R2 in §8.

**S2b · `implement:wuN:dispatch`** — write the code + its tests (Sonnet 4.6; Opus on loopback)
- **Guard:** `stage='implement'`; `wuN.status='pending'`; every `wuN.depends_on` unit `verified`;
  plan committed; rebase current.
- **Input:** the `work_unit` spec; the plan doc; implement prompt + profile; worktree at branch HEAD.
- **Output:** code **+ the unit's tests** edited in the worktree → **daemon commits** → SHA recorded,
  `dispatch` row, `wuN.status='verifying'`. **Postcondition: branch HEAD advanced; diff non-empty.**
  No schema-extraction step — implement's output is code, judged by ground-truth verify, not a payload.
- **Tools:** `Read`, `Grep`, `Glob`; `Write`/`Edit` **full worktree** (`files_to_touch` is advisory,
  A3 — reviewer-judged, not tool-enforced); `Bash` = **profile's kind-appropriate build/test/lint
  runners only** (the within-step code↔test self-check loop). ❌ no git tools, no outward tools,
  no arbitrary Bash.
- **Failure → route:** I1/I2 in §8.

### Verify (ground truth; daemon-executed, no LLM)

**S3 · `verify:wuN:<check>`** — per-work-unit ground truth (one step per check-type)
- **Guard:** `wuN.status='verifying'`; `<check> ∈ wuN.verify_check_types`; profile declares a command
  for it.
- **Input:** the profile command for this check-type (F4); worktree at wuN's SHA.
- **Output:** a **`ground_truth_signal`** row (`result ∈ pass|fail|error`, `detail_json` = counts /
  failing tests / changed paths). All of wuN's checks pass → `wuN.status='verified'`.
- **Commands/Capability:** **only** the profile's declared command for this check-type, run under a
  timeout — never arbitrary shell.
- **Behavioral gate (A1), deterministic:** when `wuN.behavioral=1`, the test check requires *the
  dispatch diff touched a test file* (path-classified via the profile) **and** tests green — both
  deterministic. Whether the test is *good* is the reviewer's job (S5), never the daemon's.
- **`scope_diff` is advisory (A3):** produces a signal that becomes an input to review; it never
  fails S3.
- **Value (vs the agent's inner loop):** the agent's loop is self-report on its working tree with a
  command it chose; S3 is the **independent** re-run on the **committed SHA** with the **canonical**
  profile command, producing a **structured durable signal** the control loop trusts. It catches
  hallucinated/partial runs, weakened/deleted tests, dirty-env passes, and premature "done."
- **Failure → route:** I3/I4/I5/I6 in §8.

**S4 · `verify:integration`** — ticket-level ground truth (C3); always run
- **Guard:** every `work_unit` is `verified`.
- **Input:** the profile's full build + full test suite (+ any integration/e2e); worktree at branch HEAD.
- **Output:** `ground_truth_signal('integration')`; on pass → ready for `docs:revise` then review.
- **Commands/Capability:** profile-declared full-suite commands only.
- **Failure → route:** N1 in §8 — integration failure is cross-unit, so the loopback is a
  **ticket-scoped reconcile** implement dispatch (may edit any unit's files), then re-run S4.

### Docs

**`docs:revise`** — ticket-level documentation sync (conditional; Haiku 4.5)
- **Guard:** S4 passed **and** S1 set `needs_docs=true`. (Otherwise skipped.)
- **Input:** the full ticket diff + plan + existing docs + profile (doc locations).
- **Output:** updated `docs/**` → daemon commits; a `dispatch` row. Output is content, not a payload.
- **Tools:** `Read`, `Grep`, `Glob`; `Write`/`Edit` **`docs/**` only** (cannot touch source/tests, so
  it can't invalidate S4's pass — no re-verify needed). ❌ no `Bash`, no outward tools.
- **Doc quality:** judged by the reviewer at cutover (no separate `docs:verify`).
- **Failure → route:** C1 in §8.

### Review (cold, independent; redesigned)

**S5 · `review`** — independent cold-context reviewer (A2/A4; Opus 4.8)
- **Guard:** S4 passed; `docs:revise` done if it ran.
- **Input — artifacts only (anti-anchoring, A2):** the full diff + plan + ground-truth signals +
  `scope_diff`. **Explicitly NOT the implementer's transcript.**
- **Mechanism (§3a):** the reviewer **files each finding via a forced-schema tool call**
  (`file_finding`), then `complete_review()` (or a clean end). The judgment fields *are* the
  reviewer's, so it files them directly — no cheap extractor. A malformed call self-corrects
  in-context; a dead dispatch is a transport failure (retry), never a deny.
- **Finding fields:** `severity` (critical|major|minor|nit), `category` (correctness | security |
  perf | maintainability | test-quality | scope | **plan-defect** | …), `location`, `rationale`,
  `factors{in_changed_code, is_regression, user_visible, reversible_post_ship, has_workaround}`,
  optional `deferral_candidate`. → written as **`review_finding`** rows.
- **Verdict — daemon-derived from the ledger, never a reviewer self-pass:**
  - any open finding `severity ∈ {critical,major}` → **loopback**, routed by `category`:
    `plan-defect` → **design (pivot, V3)**, else → **implement (V1)**. **Critical-floor: critical
    always blocks** (non-deferrable).
  - a `major` tagged `deferral_candidate` → **escalate that finding to the human** (V-defer).
  - else → **ship-ready**, transition `review → merge`.
- **No deferral dictionary (`[CL-NODEFER]`).** At cutover the threshold is fixed (major+ blocks);
  deferral ("this major is OK to ship *here*") is a *judgment that varies by project* — a
  post-cutover memory-backed decision, not a deterministic rule list. The human decides the rare
  `deferral_candidate`; **those decisions are recorded now** to seed the future learning layer.
  Nothing learns automatically at cutover.
- **Tools:** `Read`, `Grep`, `Glob` (+ read-only git); `file_finding`, `complete_review`. ❌ no
  `Write`/`Edit`, no execution, no outward tools.
- **Failure → route:** V1–V6 in §8.

### Merge (daemon; external effects via the outbox)

**S6 · `merge:push`** — put the reviewed branch on GitHub
- **Guard:** review ship-ready; branch local-only with commits ahead of base (push-once-after-review:
  the branch lives only on the host until here).
- **Output:** branch on GitHub at the reviewed SHA; outbox row sent.
- **Capability:** push **this feature branch only**. Force-change allowed **only** on the feature
  branch and **only** with-lease (no one else moved it); **never** `main`/protected.
- **Idempotency:** **probe** — remote ref already at the SHA → skip.
- **Failure → route:** transient → retry; lease/unexpected-remote-move → escalate (H-class).

**S7 · `merge:pr-ensure`** — ensure a pull request exists (result-bearing)
- **Guard:** branch pushed.
- **Input:** branch, base, and a PR title/description. The **description is written by a cheap AI**
  (smoother write-up) from facts the daemon already has — the changed work-units, test results,
  review outcome. (Facts are assembled deterministically; only the prose is the cheap model's.)
- **Output:** a PR exists; `response_ref` = PR number/url; **delivers the parked signal** so the
  workflow resumes with the PR ref (§5.3). Opening the PR is what makes the checks-system start.
- **Capability:** create **one** PR for this branch.
- **Idempotency:** **probe** — `gh pr view <branch>` → use the existing PR if present.
- **Failure → route:** transient → retry.

**S8 · `merge:await-checks`** — wait for the project's checks system (generic) `[CL-CHECKS]`
- **Guard:** PR exists.
- **Generic by design:** each project has a **checks system** (GitHub's built-in checks, a *separate*
  CI system, or none), discovered or asked at setup and saved in the project's settings. The step
  asks one **standard question** — *"for this change, are the checks passing, failing, or still
  running?"* — answered by a small **per-system translator**. Build the GitHub translator + the
  "none" case now; other systems are added later as new translators, **this step unchanged.**
- **Delivery = polling, not webhooks (`[CL-POLL]`):** the daemon *reaches out* to the checks system
  periodically. This serves GOAL-INSTALL — works behind any firewall, no public endpoint. The
  checks/merge facts enter as **delivered signals** (§7.3), never a control-flow read.
- **Output:** green → proceed to S9; failing → loop back through the normal coding-and-review steps
  (P1); flaky/infra → re-run the checks (P2); **none configured → skip** (human merge stays the gate).
- **Timeout:** bounded wait; stuck/unreachable → escalate to the human.

**S9 · `merge:await-human`** — the single human gate (D2)
- **Guard:** checks green (or none).
- **Behavior:** parks the work in the operator's **needs-you inbox** with full context (what changed,
  test/check results, review outcome). **No deadline** — waits indefinitely (optional gentle
  reminder). Detected by polling GitHub for the merge.
- **Auto-merge fully off at cutover** — earned later, per ticket-class, via the learning layer.
- **Stale-branch handling while waiting (`[CL-STALE]`)** — main may advance during a slow approval:
  the daemon keeps the branch current and re-validates, tiered to risk:
  - **clean catch-up** → re-run tests (S4) + re-run checks (S8); if green, mergeable and the prior
    review stands (the change's own diff is unchanged);
  - **catch-up needs conflict resolution** → re-run tests + checks **and re-review (S5)**, and **flag
    the needs-you item** "updated to keep up with main; code was reconciled — re-check";
  - **catch-up breaks tests** → send back to fix through the normal steps (a real behavior clash);
  - **invariants:** the human always merges a branch **current with main and green**; if the change
    was altered while catching up, the human is told; if main moves faster than the branch can be
    kept current (repeated thrash), **stop and hand the merge to the human**.
- **Output:** operator merges → transition `merge → released`. Operator requests changes → loop back
  (H1).

### Released

**S10 · `released:project`** — wrap up (daemon; external via outbox)
- **Guard:** PR merged (signal delivered).
- **Output:** ticket recorded done; tracker (Linear) projected to **Done**; the per-ticket worktree
  cleaned up. `ticket.stage='released'`, `status='done'`. ("Done" = merged + tracked at cutover;
  watch-for-deployment is an optional later addition per project.)
- **Capability:** project this one ticket's terminal state; remove its worktree.
- **Idempotency:** declarative (set-to-Done is idempotent).
- **Failure → route:** transient → retry.

---

## 5. External effects — the outbox (B3) `[CL-2: all external effects via the outbox]`

Every external effect (Linear, GitHub API, git push) is a `projection_outbox` row, enqueued in the
**same transaction** as the state change that motivates it, and drained idempotently by the daemon.
Local effects (dispatch, verify, local git) use the §3 write-ahead discipline but execute inline.

```
drain_outbox():
  for row in SELECT * FROM projection_outbox WHERE status='pending' ORDER BY created_at:
    try: ref = apply(row); UPDATE … status='sent', response_ref=ref; if delivers_result: deliver_signal(row)
    catch transient: UPDATE … attempts+=1, error=…           # retried next loop
```
`idempotency_key` is `UNIQUE` (enqueue-twice is a no-op insert). **Reconciliation = re-attempt +
probe (CL-3):** re-run the effect and probe the external system for the change (comment already
posted? PR already open? remote ref already at SHA? already merged?), using a key where one exists;
probe-first guards no-native-key and irreversible effects (`pr_create`, `pr_merge`). Result-bearing
effects (`pr_create`) park on a signal the drainer delivers with `response_ref` (§7).

---

## 6. Crash & resume — discharging §9.4 #2

### 6.1 Recovery on start
```
recover():
  for step in SELECT * FROM workflow_step WHERE status='running':
    kill_orphan(step)                 # journaled PID still alive (dispatch) -> kill (ENG-131 lesson)
    if reattemptable(step): reset to 'pending'
    else (irreversible w/ probe): if probe_says_done: mark 'succeeded'(reconstructed) else 'pending'
  drain_outbox()
```
Intent-before-effect (§3) makes a `running` row the complete record of "an effect may be half-done."

### 6.2 Replay returns the recorded result
The resolver never re-executes a `succeeded` step — it reads `result_json`. The journal is the memo
table; with §5 idempotency every operation is at-least-once-attempted, exactly-once-effective.

### 6.3 Dispatch crash
A `claude -p` dies mid-run: step `{running, pid}`, no `result_json` → restart → `kill_orphan` →
re-dispatch as a fresh `dispatch_id`. Partial work committed to the branch is the next worker's
start point — git is the durable substrate for code, the journal for control. *Dispatch retry =
fresh attempt, not cached replay; only external effects get exactly-once keys.*

---

## 7. Durable waits — signals (B1)

A step of `step_type='await_signal'` inserts a `signal` (pending), sets `await_signal_id`, and sets
`ticket.status='waiting'` — the ticket leaves `v_ready_tickets`, so **no busy-wait** for human/CI
waits. A deliverer flips the signal to `delivered` (+ payload) and the ticket back to `active`; the
await step then succeeds.

| Signal | Delivered by |
|---|---|
| `human_merge_approval` (D2) | operator, via the needs-you inbox (D3) |
| `human_resume` (escalation, §8) | operator |
| `external_checks` | §7.3 poll of the project's checks system (CL-CHECKS/CL-POLL) |
| `external_pr_result` | the outbox drainer completing `pr_create` (delivers `response_ref`) |

**7.3 External delivery = polling.** Checks-system status and PR-merged are obtained by the daemon
*reaching out* on an interval (no inbound endpoint → GOAL-INSTALL). Budget fields (`attempts`,
`max_attempts`, `first_attempt_at`) bound the wait; exhaustion → `human_resume` escalation.

---

## 8. The Loopback Atlas

**Two invariants bound every entry — the anti-anxiety guarantees:**
- **Every loop is bounded by `K_DISTINCT` *distinct* attempts.** "Distinct" = the failure signature
  changed. Two counters: total distinct corrective attempts (cap ~3) **and** consecutive-identical
  (cap ~2). An agent re-emitting the same failing diff escalates *faster*, not slower. No loop runs
  forever.
- **Exhaustion ⇒ escalate = a durable, resumable human wait** (`human_resume` in the inbox) — never
  an infinite loop, never a dead halt. The worst case for any ticket is "parked in your inbox with
  the full trace," not "stuck." Routing is deterministic at cutover (the detecting step fixes the
  target); the supervisor makes it smarter later.

| # | Detected at | Scenario | Routes to | Bound → exhaustion |
|---|---|---|---|---|
| D1 | design:extract | shape invalid (rare; forced output) | re-run extract (cheap) | K_shape → escalate |
| D2 | design:extract | content gap — plan lacks required info | → S1a re-design (Opus) | K_distinct → escalate |
| D3 | post-design | no plan / zero work-units | → S1a re-design | K_distinct → escalate |
| R1 | S2a | rebase merge conflict | → conflict-resolution agent | — |
| R2 | S2a | resolution fails / re-conflict / post-rebase verify red | → escalate | K → escalate |
| I1 | S2b | claude death / timeout | retry fresh dispatch (backoff) | K_retry → escalate |
| I2 | S2b | noop — empty diff | re-dispatch with feedback | K_distinct → escalate |
| I3 | S3 | build red | → S2b with build error | K_distinct → escalate |
| I4 | S3 | tests red | → S2b with failing tests | K_distinct → escalate |
| I5 | S3 | behavioral unit, no test added | → S2b to add the test | K_distinct → escalate |
| I6 | S3 | toolchain/infra error | retry (transient) | K_retry → escalate(infra) |
| N1 | S4 | cross-unit integration red | → **ticket-scoped reconcile** implement | K_distinct → escalate |
| C1 | docs:revise | claude death | retry | K_retry → escalate |
| V1 | S5 | blocking finding (code) | → S2b, targeted at the findings | K_distinct → escalate |
| V2 | S5 | unjustified scope expansion (A3) | blocking finding → S2b | K_distinct → escalate |
| V3 | S5 | plan-defect (impl correct, plan wrong) | → **S1 design (pivot)** | K_distinct → escalate |
| V-def | S5 | major tagged `deferral_candidate` | → escalate that finding to human | — |
| V4 | S5 | reviewer death / transport failure | retry dispatch (distinct from a deny) | K_retry → escalate |
| V5 | post-review | no clean verdict after retries | fail-safe NO-SHIP → escalate | K → escalate |
| V6 | across reviews | same finding persists N cold rounds | → escalate (agent can't fix it) | fast |
| P1 | S8 | checks red — real failure | → S2b with check logs (then verify+review+re-push) | K_distinct → escalate |
| P2 | S8 | checks flaky / infra | re-run the checks | K_retry → escalate |
| ST1 | S9 | stale: clean catch-up | re-run tests + checks; review stands | — |
| ST2 | S9 | stale: catch-up reconciled code | re-run tests + checks + **re-review**, flag the human | K_distinct → escalate |
| ST3 | S9 | stale: catch-up breaks tests | → S2b (real behavior clash) | K_distinct → escalate |
| ST4 | S9 | main moves faster than we can keep current | stop; hand merge to the human | — |
| H1 | S9 | operator requests changes | → S2b or S1 per feedback | human-driven |
| B1 | any loop | K_DISTINCT distinct attempts reached | escalate (resumable wait) | — |
| B2 | any | escalation budget (3 consecutive / 20 total) | escalate | — |
| B3 | any | per-ticket token / wall-clock cap | escalate | — |

**Three loopback targets, by meaning:** **→ implement** (the code is wrong — most failures);
**→ design (pivot)** (the *plan* is wrong — only the reviewer distinguishes this, V3); **→ escalate**
(bounded attempts exhausted, or an inherently human case — R2, V-def, V6, ST4, H1).

---

## 9. Invariants a step author MUST hold

- **CL-INV-1 — stable keys.** `step_key` is a pure function of (ticket, work_unit, logical position);
  never embed a timestamp/random/`dispatch_seq`/attempt.
- **CL-INV-2 — allocate-once.** Ids/timestamps an effect needs are allocated at step creation and
  journaled; replay reuses, never re-allocates.
- **CL-INV-3 — one transaction.** Every state transition + its outbox enqueues commit in one tx;
  effects sit outside it behind write-ahead intent.
- **CL-INV-4 — validated interface, not parsed blobs.** Structured agent output is submitted via
  forced-schema tool calls; the daemon computes decisions from state (§3a). Never parse a free-form
  verdict.
- **CL-INV-5 — keyed/probed effects.** External effects are idempotent via probe + key (§5).
- **CL-INV-6 — DB is the only control input.** Control flow reads SQLite only; external facts (checks,
  human, merge) arrive as delivered signals, never a live read.
- **CL-INV-7 — single writer.** Only the daemon writes SQLite (B2); the daemon commits, not agents.
- **CL-INV-8 — display-local.** Timestamps stored UTC; every operator-facing surface renders host
  local time (DS-1).

---

## 10. Installation & operability `[GOAL-INSTALL]`

One command, no server setup. Implications the daemon owns:
- **Single self-contained binary** (TS compiled, node bundled) — no global installs; escapes the
  bash-3.2 curse entirely.
- **Embedded SQLite, zero-ops** — no DB server; WAL on by default.
- **Self-bootstrapping schema** — `migrate()` creates/upgrades the DB on start; no manual SQL.
- **One idempotent `setup <target-repo>`** — creates+migrates the DB, seeds the `project` row,
  refreshes the `linear_id_cache`, **discovers/asks the checks system**, renders + bootstraps the
  single `KeepAlive` plist.
- **Minimal host contract** — the binary + `claude` + `git` + `gh`; one config file + one secrets
  file; no ambient `LINEAR_API_KEY`.
- **Reach-out-only networking** — polling (not webhooks) for checks/merge → works behind any
  firewall, no public endpoint.
- **Built-in `status` (local-tz, DS-1) + needs-you inbox** — no extra dashboards.

---

## 11. Worked example — ENG-9, full-track backend+frontend feature

| # | `step_key` | executor | result |
|---|---|---|---|
| 1 | `design:dispatch` | Opus | plan doc committed; `needs_docs=true` |
| 2 | `design:extract` | Haiku | `work_unit` wu1(backend), wu2(frontend); `stage=implement` |
| 3 | `implement:wu1:rebase` | daemon | clean (no-op if current) |
| 4 | `implement:wu1:dispatch` | Sonnet | backend code + tests; daemon commits (d-row) |
| 5 | `verify:wu1:build` / `:test` | daemon | ground-truth pass; wu1 verified |
| 6 | `implement:wu2:dispatch` | Sonnet | frontend code + tests; daemon commits |
| 7 | `verify:wu2:visual` | daemon | Playwright pass; wu2 verified |
| 8 | `verify:integration` | daemon | full suite pass |
| 9 | `docs:revise` | Haiku | docs updated (needs_docs was set); daemon commits |
| 10 | `review` | Opus | files findings via tools; 0 blocking → ship-ready; `stage=merge` |
| 11 | `merge:push` | daemon/outbox | branch pushed (probe on SHA) |
| 12 | `merge:pr-ensure` | daemon/outbox + Haiku | PR opened (probe), cheap-AI description |
| 13 | `merge:await-checks` | daemon (poll) | checks green |
| 14 | `merge:await-human` | operator | merges (branch kept current meanwhile); `stage=released` |
| 15 | `released:project` | daemon/outbox | tracker → Done; worktree cleaned; `status=done` |

A backend-only ticket drops 6–7 and (if no doc impact) 9; **1 work-unit = 1 implement dispatch.**

---

## 12. Mapping to §9.4 #2 + open questions

**Discharged:** ✅ replay returns recorded result (§6.2) · ✅ external effects keyed (§5) · ✅ crash
mid-step resumes (§6.1).

**Decided in the walkthrough:** CL-1 (one daemon) · CL-COMMIT (daemon-commits) · CL-ORCH
(daemon-orchestrates, no master agent) · validated-interface for structured output (§3a) · review
redesign (findings via tool calls; verdict from state) · CL-NODEFER (no deferral dictionary;
record-now-learn-later) · CL-CHECKS/CL-POLL (generic checks system, polling) · CL-STALE
(stale-branch handling).

**Still open (don't block #2):** the per-ticket budget numbers (K_DISTINCT, token/wall-clock caps);
the needs-you inbox surface (D3) — specify with the projector artifact.

**Next artifact:** §9.4 #3 — the one-time state-import mapping (`issue-state.json` + labels + marker
history → rows), then #4 the Linear/GitHub one-way projector (the outbox drainer's adapters).
