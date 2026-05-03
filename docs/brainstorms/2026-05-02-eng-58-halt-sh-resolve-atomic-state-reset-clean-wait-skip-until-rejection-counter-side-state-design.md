---
linear: ENG-58
title: halt.sh resolve — atomic state reset (wait/skip-until/rejection-counter side state)
date: 2026-05-02
status: draft
---

# halt.sh resolve — atomic state reset

## 1. Problem

`bin/halt.sh resolve --decision resume` advertises itself as the operator's
exit ramp from a halted issue (`CLAUDE.md:294`). It performs a partial
clear: posts `<!-- pipeline-decision: resume -->`, calls `verdict_handler`,
and on the no-forward-verdict path removes `pipeline:halted`
(`bin/halt.sh:44-48`). What it does **not** clear is everything else the
prior halt installed:

- `$issue_dir/wait-${stage}.json` (per ENG-45 — the budget/counter file
  written by `bin/run-stage.sh::_handle_wait` at `bin/run-stage.sh:378,424`
  and deleted only on stage success at `bin/run-stage.sh:836`).
- `pipeline:skip-until-code-changes` and `pipeline:skip-until-human-acts`
  labels (applied by `bin/classify-failure.sh:108-114` when the policy
  escalation maps to a skip shape).
- `$issue_dir/issue-state.json` (written by
  `bin/classify-failure.sh:83-102`; carries `policy`, evidence hashes,
  and retry counter).
- Implicit: stale `<!-- pipeline-metric: review_rejection -->` /
  `qa_rejection` / `implement_rejection` markers older than the halt.
  `bin/guards.sh::count_marker_since_last_transition` (`bin/guards.sh:42-56`)
  counts these relative to the most recent
  `<!-- pipeline-transition: -->` comment. Resume posts no transition
  comment, so on the next dispatch the counter still reads the pre-halt
  rejections.

When any of these survive, the next tick can immediately re-halt or
re-skip the issue. The acute symptom — a 33-second re-halt loop — was
patched empirically in [ENG-24](https://linear.app/twinning/issue/ENG-24/),
but the underlying compositional gap is still live: every soft-pause
shape added to the harness inherits this surface. ENG-45's
`wait-${stage}.json` is the most recent example; once landed, an operator
running `halt.sh resolve --decision resume` on a wait-budget-exhausted
build issue would clear the halt label but leave the file at attempts=12,
so the very next dispatch's `_handle_wait` call increments to 13 and
re-escalates instantly.

## 2. Decisions

- **D-001. Cleanup logic lives inside `bin/halt.sh`, gated by the
  `resume` decision branch.**

  Add a private helper `_resolve_reset_side_state "$issue"` that performs
  the four side-state operations the issue mandates (skip-label removal,
  wait-file removal, issue-state file conditional removal). Call it from
  the resume branch only.

  *Why:* the issue frames this as making `halt.sh resolve --decision resume`
  atomic. The operator running one command should produce a complete
  reset, not require chaining two commands (which is the failure mode
  this brainstorm is fixing). `halt.sh` already exports
  `PIPELINE_WRITER=human` at file-scope (`bin/halt.sh:14`), so all the
  cleanup writes ride the human lane through `linear.sh`'s fence
  (`bin/linear.sh:73-91`) without further plumbing.

  Rejected alternative: hoist the cleanup into `bin/poll.sh` so the
  next tick observes "halt cleared but stale state remains" and reacts.
  Rejected because (a) `poll.sh::_poll_evaluate_skip` already carries
  more cleanup logic than is comfortable (`bin/poll.sh:48-123`), (b) the
  reset would no longer be atomic with the operator's command — there
  is a multi-second window between halt.sh exit and the next launchd
  tick during which an in-flight dispatch could still observe stale
  state, and (c) it deviates from the issue's explicit framing of
  halt.sh as the operator's exit ramp.

  Rejected alternative: tell operators to run `bash bin/reset-pipeline.sh
  ENG-N` after `halt.sh resolve` to clear the per-issue residue
  (`bin/reset-pipeline.sh:36-45` already removes skip-until-* labels
  and `issue-state.json`). Rejected because chaining two operator
  commands is exactly the "exit channel does not compose" bug the issue
  is fixing. `reset-pipeline.sh` also doubles as a global reset
  (`.consecutive-failures`, `orchestrator.paused` —
  `bin/reset-pipeline.sh:26-34`); calling it from halt.sh would
  unexpectedly enlarge the blast radius.

- **D-002. Operator-resume waypoint reuses the existing
  `<!-- pipeline-transition: -->` shape with an `(operator-resume)`
  body suffix.**

  Exact body: `<!-- pipeline-transition: <stage> → <stage>
  (operator-resume) -->\n\nOperator-attributed transition waypoint
  (halt.sh resolve --decision resume).`

  *Why:* this decision is inherited from the closed
  [ENG-47](https://linear.app/twinning/issue/ENG-47/) umbrella and is
  out of scope to relitigate. The four-shape verdict vocabulary
  (stage-summary, rejection, halt, wait — see `AGENT_PROMPTS.md`'s
  Verdict-marker protocol preamble and the ENG-45 brainstorm at
  `docs/brainstorms/2026-04-28-build-agent-soft-preconditions-p2-p5-...md`)
  stays intact. The `(operator-resume)` suffix is body-text only; it
  does not introduce a new marker shape. The from=to pattern (e.g.,
  `building → building`) is novel but compatible:
  `find_fresh_verdict` (`bin/verdict-handler.sh:75-78`) and
  `count_marker_since_last_transition` (`bin/guards.sh:46-48`) both
  use `contains("<!-- pipeline-transition:")` for boundary detection
  — a substring match — so the suffix and the same-source/target are
  invisible to them. The boundary fires; the rejection counters reset
  to zero; `find_fresh_verdict` returns empty.

  Compatibility-critical detail: `resume_in_progress_transition`'s
  body regex (`bin/verdict-handler.sh:276-279`) is strict —
  `<!-- pipeline-transition: [a-z]+ → [a-z]+ -->`. The
  `(operator-resume)` suffix breaks the regex match, so
  `resume_in_progress_transition` will NOT mistake the operator-resume
  marker for an in-progress legitimate transition and try to "complete"
  it (which would be destructive — the from-to label dance against
  source==destination would spuriously remove and re-add the same
  stage label). The strict regex is the existing safety net; the
  suffix is what avoids tripping it.

  Rejected alternative: introduce a new marker shape
  `<!-- pipeline-resume: operator → <stage> -->`. Rejected because
  ENG-47 explicitly closed this avenue ("No new marker shape. Keep the
  four-shape vocabulary intact."), and because every reader of the
  pipeline-transition shape (`find_fresh_verdict`, the rejection
  counter, status.sh's narrative) would need parallel readers for the
  new shape — a much wider blast radius for a single freshness boundary.

- **D-003. Post the operator-resume waypoint ONLY in the vh_rc=1 path
  (no fresh forward verdict). Skip it in vh_rc=0 (transitioned) and
  vh_rc=2 (protocol violation).**

  - vh_rc=0 (`bin/verdict-handler.sh:347` → `apply_transition`): the
    real transition's own `<!-- pipeline-transition: from → to -->`
    waypoint (`bin/verdict-handler.sh:142-145`) is already the freshest
    transition comment. Posting an additional `from → from
    (operator-resume)` after it would give two transition comments in
    quick succession with no semantic gain — `find_fresh_verdict` and
    `count_marker_since_last_transition` already see the freshness
    boundary they need.
  - vh_rc=1 (`bin/verdict-handler.sh:360-363`): no apply_transition
    ran; no boundary exists. The operator-resume waypoint is the only
    way to provide one. This is the case the bug fix targets.
  - vh_rc=2 (`bin/verdict-handler.sh:323`): a protocol violation was
    just posted by `_vh_protocol_violation`; halt is preserved and
    the operator must investigate. Posting an operator-resume here
    would clobber the just-posted halt's freshness and silently mask
    the violation.

  *Why:* avoid double-waypoints, avoid silently masking protocol
  violations. Branching on vh_rc is one extra `case` arm in the
  existing `case "$rc" in` block at `bin/halt.sh:38-60` — minimal
  surface area.

  Rejected alternative: always post the operator-resume waypoint on
  every resume regardless of vh_rc. Rejected because vh_rc=2 must NOT
  bypass the just-posted protocol-violation halt, and vh_rc=0 already
  has a real transition waypoint immediately before — a second one
  is clutter without semantic benefit.

- **D-004. Side-state cleanup runs in BOTH vh_rc=0 and vh_rc=1; never
  in vh_rc=2.**

  Cleanup operations (skip labels, wait-*.json, conditional
  issue-state.json) are independent of whether a forward transition
  was applied. The operator's intent on `--decision resume` is "fully
  unblock this issue"; both paths benefit from the cleanup.

  vh_rc=2 is excluded because the protocol-violation halt may relate
  to the side state itself (e.g., a corrupt issue-state.json). The
  operator must investigate before any cleanup.

  *Why:* matches the issue's framing — atomicity of the `--decision
  resume` contract. Decoupling cleanup from the waypoint decision
  (which is purely a freshness-boundary concern, D-003) keeps the two
  responsibilities separable.

- **D-005. `wait-*.json` cleanup uses a wholesale glob:
  `rm -f "$issue_dir"/wait-*.json`.**

  *Why:* the issue offers a choice ("for every stage (or for the stage
  encoded in the most recent halt — pick one and document)"). Glob is
  simpler than parsing the halt comment to attribute a stage:
  - The halt comment's stage attribution is human-readable text
    (e.g., `bin/run-stage.sh:446` — "Build stage halted: …"); fragile
    to parse.
  - Today only `wait-build.json` is emitted (ENG-54 narrowed
    `_fresh_wait_reason` to build-only — `bin/run-stage.sh:308-311`).
    Glob and "build-only" are equivalent under current semantics.
  - If a future ticket re-broadens wait shapes to other stages
    (ENG-45 brainstorm Q5), glob is forward-compatible at no extra
    cost.

  Rejected alternative: parse the halt comment to determine which
  `wait-${stage}.json` to delete. Rejected on fragility (text
  parsing) and YAGNI (one stage today).

- **D-006. `issue-state.json` cleanup is conditional on
  `policy=skip-until-human-acts`.**

  Read `.policy` from `$issue_dir/issue-state.json` with `jq`; remove
  the file iff the policy equals `skip-until-human-acts`.

  *Why:* `skip-until-code-changes` policy has a different recovery
  pathway — `bin/poll.sh::_poll_evaluate_skip` (`bin/poll.sh:83-122`)
  recomputes the pipeline-content-hash and branch HEAD SHA and
  auto-resumes when either changes. That recovery requires the
  prior `evidence` block in `issue-state.json` to detect change. If
  we delete the file unconditionally, the next failure writes a fresh
  state file with current evidence; the auto-resume signal is lost
  for that retry cycle (it can never observe "evidence changed since
  prior halt" because there is no prior).

  Conversely, `skip-until-human-acts` is "operator gating": the
  operator's `--decision resume` IS the human-acting signal, so the
  policy state should clear in lockstep with the skip-until-human-acts
  label removal (D-007).

  Note on idempotency: even without this conditional, `poll.sh`'s
  orphan-state-file cleanup (`bin/poll.sh:55-63`) would eventually
  delete `issue-state.json` on the next tick after the skip-until-*
  label is removed (D-007). Doing it explicitly in halt.sh has two
  benefits: (a) atomicity within the halt.sh resolve command (no
  inter-tick window during which an in-flight dispatch could read
  stale state); (b) explicit policy-conditional protects
  skip-until-code-changes evidence from the orphan-cleanup race.

  Rejected alternative: always delete `issue-state.json`. Rejected
  because it loses the skip-until-code-changes auto-resume evidence.

  Rejected alternative: never delete in halt.sh; rely on poll.sh's
  orphan cleanup. Rejected because the inter-tick window admits a
  race (D-001's atomicity concern).

- **D-007. Skip-until-* label removal is wholesale: remove BOTH
  `pipeline:skip-until-code-changes` and `pipeline:skip-until-human-acts`
  unconditionally (idempotent — `linear.sh remove-label` no-ops when
  label absent, `bin/linear.sh:271-274`).**

  *Why:* the issue says "Removes any `pipeline:skip-until-*` labels."
  Both today; if a third skip-until-* shape is added in the future,
  the brainstorm or that ticket should add a third remove call.
  Wholesale removal is symmetric with `bin/reset-pipeline.sh:42-43`,
  the existing per-issue reset path.

  Lane fence check: `remove pipeline_skip_until` allows
  `orchestrator,classify,human` (`bin/linear.sh:84`); halt.sh runs as
  human (`bin/halt.sh:14`). ✓

- **D-008. Atomic ordering inside the vh_rc=1 path: side-state
  cleanup → halt label removal → operator-resume waypoint LAST.**

  Pseudocode:
  ```
  case 1:
    _resolve_reset_side_state "$issue"           # idempotent file/label removes
    bash linear.sh remove-label "$issue" "pipeline:halted"
    bash linear.sh add-comment "$issue" \
      "<!-- pipeline-transition: <stage> → <stage> (operator-resume) -->\n\n..."
    return 0
  ```

  *Why:* the operator-resume waypoint is the load-bearing visible
  artifact for the bug fix — the freshness boundary that makes
  `find_fresh_verdict` and `count_marker_since_last_transition` see
  zero stale markers. Posting it LAST means: if any prior step fails
  (network blip, lane-fence rejection, jq error), the waypoint is
  absent. The operator notices the missing comment and can re-run
  `halt.sh resolve --decision resume` (every step is idempotent —
  remove-label no-ops; rm -f no-ops; the second decision comment
  dedups via `add-comment`'s timestamp/SHA-stripped hash check at
  `bin/linear.sh:455-487`). A partial half-completed reset is
  recoverable; a half-completed reset where the freshness boundary
  exists but the halt label persists is NOT (poll.sh would still see
  halted).

  Rejected alternative: post operator-resume FIRST, then halt label
  remove + cleanup. Rejected because: if the post succeeds but a
  later step fails, the issue is left with a fresh transition
  waypoint AND `pipeline:halted` still applied — `poll.sh`'s halted
  branch (`bin/poll.sh:217-233`) would then call
  `find_fresh_verdict` on a fresh-transition issue, get empty (no
  verdict newer than transition), and classify as `hold,
  advanceable=false`. The halt sits stuck in a way the operator
  cannot easily recover from without manually clearing the label.

- **D-009. `scope-approved` and `scope-rejected` decisions retain
  their CURRENT minimal behavior. They do NOT trigger side-state
  cleanup or operator-resume waypoint posting.**

  Current behavior (preserved):
  - Post `<!-- pipeline-decision: <decision> -->` (`bin/halt.sh:25-27`)
  - Remove `pipeline:halted` (`bin/halt.sh:63`)

  *Why (this is the documented narrower path the issue asks for):*
  scope-deviation halts originate from `bin/run-stage.sh::main` (the
  post-implement / post-ui scope-check guard at
  `bin/run-stage.sh:592-630`). They do NOT involve any of the side
  state ENG-58 targets:
  - No `wait-${stage}.json` (that is the ENG-45 build-stage soft-pause
    mechanism, completely orthogonal — `_handle_wait` is build-only).
  - No `pipeline:skip-until-*` labels (those come from
    `classify-failure.sh::classify_failure`'s policy-escalation
    branches; scope-deviation halts skip classify-failure entirely
    and post their own halt comment + label directly at
    `bin/run-stage.sh:628-629`).
  - No `issue-state.json` (same reason — classify-failure is bypassed).
  - The `$issue_dir/scope-approval` sentinel file (written at
    `bin/run-stage.sh:617-618`) is consumed POSITIVELY by
    `_replay_scope_approval` (`bin/run-stage.sh:127-131,527-534`) and
    cleared by run-stage.sh on success
    (`bin/run-stage.sh:599,611`). Deleting it from halt.sh would
    defeat the replay pathway. **Do not touch.**
  - Posting an operator-resume waypoint would mislead
    `count_marker_since_last_transition` into resetting any rejection
    counters that were legitimately at 1+ from earlier loopbacks
    unrelated to the scope-deviation halt — silently losing
    circuit-breaker progress.

  In the rare edge case where an issue carries BOTH a scope-deviation
  halt AND a stale skip-until-* label from a separate prior failure,
  the operator can chain `halt.sh resolve --decision scope-approved`
  followed by `halt.sh resolve --decision resume` (the second posts
  decision=resume but skip-state cleanup runs as part of D-001/D-007).
  Documented edge case in §6.

  Rejected alternative: share the same atomic-reset path between all
  three decisions. Rejected because scope-deviation's side-state
  surface is genuinely smaller; the asymmetry is real, not accidental.
  Documenting this preserves the current correctness without adding
  ceremony to the scope-approval flow.

- **D-010. Add tests to `bin/halt-test.sh` (the existing sibling),
  not to `bin/halt-sprawl-test.sh`.**

  *Why:* despite the Linear issue's hint that "halt-sprawl-test.sh
  (or a sibling test)" covers the four-step reset, `halt-sprawl-test.sh`
  exclusively tests `bin/poll.sh::_poll_emit_halt_sprawl_alert`
  (`bin/halt-sprawl-test.sh:1-401`) — wrong module under test for
  this work. `bin/halt-test.sh` (`bin/halt-test.sh:1-91`) is the
  existing test for `halt.sh` and uses the source-and-stub pattern
  with a `VH_RC` env var to control verdict_handler's return —
  exactly the harness shape needed to drive the new vh_rc=0/1/2
  cases. Extend it.

- **D-011. Skip the `verdict_handler` call entirely when
  `pipeline:halted` is absent at resume time.**

  Insert a `has-label pipeline:halted` guard immediately before the
  verdict_handler call in the resume branch. If the label is absent,
  jump straight to `_resolve_reset_side_state` + operator-resume
  waypoint posting (synthetic vh_rc=1 path).

  *Why (closes the iter-1 Coherence P0 + Design P1 + Product P0
  family):* the chained `scope-approved` → `resume` failure mode is
  worse than the bug ENG-58 sets out to fix. After scope-approved
  removes pipeline:halted, the operator's follow-up `--decision
  resume` would invoke verdict_handler with pipeline:halted absent
  AND no fresh verdict marker (just the operator's own
  `pipeline-decision: scope-approved` from a moment ago — not a
  verdict shape per `bin/verdict-handler.sh:75-91`'s allow-list of
  `stage-summary | rejection | halt`). verdict_handler hits the
  no-marker arm, calls `_vh_protocol_violation`
  (`bin/verdict-handler.sh:323-326`), which **unconditionally
  re-applies pipeline:halted** at `bin/verdict-handler.sh:58`. The
  operator's second command would re-halt the issue.

  The `has-label pipeline:halted` guard short-circuits this: if the
  operator is using `--decision resume` purely as a side-state-reset
  primitive (no halt to clear), we run the cleanup + waypoint path
  but skip the verdict_handler call that would otherwise re-halt.
  This is also philosophically correct — "resume" without a halt to
  clear is a no-op-on-halt-state plus an explicit reset-side-state
  request.

  Rejected alternative: refuse to resume when pipeline:halted is
  absent (die with "no halt to resolve"). Rejected because the
  chained scope-approved → resume flow IS a legitimate operator
  workflow (D-009 documents that scope-approved deliberately does
  not reset side state); the operator should be able to chain a
  bare-cleanup resume after.

  Rejected alternative: have verdict_handler itself skip the no-marker
  arm when called from halt.sh. Rejected because that would weaken the
  agent-contract validator's safety net for the dispatch path, where
  the no-marker arm is load-bearing.

- **D-012. `scope-approved` / `scope-rejected` paths emit a one-line
  stderr advisory when they observe stale halt-related side state
  (skip-until-* labels, `wait-*.json`, or `issue-state.json`).**

  Implementation: a small `_observe_stale_side_state` helper called
  from the non-resume branch. Inspects the issue's labels (already
  fetched via `has-label` calls on demand) and the issue dir; if any
  of the three classes is non-empty, prints to stderr:
  `halt.sh: NOTE — stale side state detected (<list>); run 'bash
  bin/halt.sh resolve <ident> --decision resume' to clear.`

  *Why (closes the iter-1 Product P0 — D-009 invisibility):* a
  single human operator at 2am needs the discoverability prompt at
  the moment they hit it, not buried in CLAUDE.md. The advisory is
  cheap (one Linear API call piggybacking on existing has-label
  flow; a few `[[ -e ... ]]` checks). It does NOT auto-clean (D-009's
  asymmetry remains principled — scope-deviation flow is genuinely
  smaller-surface), it just informs.

  Rejected alternative: turn scope-approved into "atomic reset
  including skip-until-* and wait-*.json cleanup". Rejected because
  scope-deviation halts don't accrue that side state in the normal
  case; cleanup would be misleading-on-success and invite operators
  to think scope-approved IS a full reset (it's not — the
  scope-approval state file at `$issue_dir/scope-approval` must
  persist for `_replay_scope_approval`).

- **D-013. Emit a `halt-resume` metrics event recording what the
  reset cleared.**

  After successful cleanup (vh_rc=0 or vh_rc=1 path, or the synthetic
  D-011 path), call:
  `bash $SCRIPT_DIR/metrics.sh halt-resume <issue> <stage>
  "atomic-reset" 0 "wait_cleared=N skip_labels_cleared=M
  state_cleared=B waypoint_posted=B"`

  Where the four `notes` fields capture: number of `wait-*.json`
  files removed, number of skip-until-* labels removed, whether
  issue-state.json was deleted, whether the operator-resume waypoint
  was posted (false in vh_rc=0 path; true in vh_rc=1 + D-011 paths).

  *Why (closes iter-1 Product P0 — no success metric):* the
  retrospective agent (`bin/run-retrospective-local.sh`) consumes
  `events.jsonl` and the absence of an emission means the retrospective
  cannot detect "operator ran resume but the issue immediately
  re-halted" patterns — which is exactly the regression class this
  brainstorm is hardening against. With the emission, the retrospective
  can cross-reference: `halt-resume` event for ENG-N at T, followed
  by a `stage-end outcome=halt-for-human` event for ENG-N within Δ ≤
  2 ticks → flag as suspected re-halt regression.

  This is purely additive (one metrics.sh call); failure of the
  emission does NOT fail the resume (`|| true`).

- **D-014. Validate the issue id arg against `^ENG-[0-9]+$` before
  using it in any path or Linear write.**

  Add validation at the top of `resolve()`:
  ```bash
  [[ "$issue" =~ ^ENG-[0-9]+$ ]] \
    || die "halt.sh: invalid issue id '$issue' (expected ENG-<digits>)"
  ```

  *Why (closes iter-1 Security P1 — path-traversal via `ENG-*`
  arg-parse glob):* `bin/halt.sh:76` accepts any `ENG-*` token via
  the case glob, then feeds it through `issue_dir`
  (`bin/common.sh:64`) which does `printf '%s/%s' "$PROJECT_STATE_DIR"
  "$issue"` with no normalisation. A crafted `ENG-../../etc/passwd_dir`
  would feed `rm -f` a path outside `$PROJECT_STATE_DIR`. Practically
  bounded (operator runs halt.sh themselves; no untrusted input
  source today), but tightening the regex is a one-line change with
  no downside and aligns with the existing `[a-z]+ → [a-z]+` strict
  regex pattern in `verdict-handler.sh:276-279`. Defense-in-depth.

  Bonus: also validate `current_stage` against `^[a-z]+$` before
  interpolating into the operator-resume waypoint body (closes
  Security P2: `printf` `%s` consumption attack via a crafted
  Linear stage label).

## 3. Architecture

### 3.1 Files modified

| File | Change |
|---|---|
| `bin/halt.sh` | Add `_resolve_reset_side_state` private helper. Extend the `resume` branch in `resolve()` with conditional cleanup + operator-resume waypoint per D-003/D-004/D-008. |
| `bin/halt-test.sh` | Add cases E-J (see §3.4) covering side-state cleanup, vh_rc branching, idempotency, and ENG-24 regression. |
| `CLAUDE.md` | Update the "Failure-mode quick reference" `Kill switch` row to document the atomic resume contract. |

No changes to `bin/poll.sh`, `bin/verdict-handler.sh`,
`bin/classify-failure.sh`, `bin/linear.sh`, `bin/guards.sh`,
`bin/run-stage.sh`, `AGENT_PROMPTS.md`. The fix is additive to
`halt.sh` only.

### 3.2 New helper sketch

```bash
# halt.sh — private helper; called from resolve() resume branch only.
# Idempotent: every operation no-ops if the target is absent.
# Reads:    $issue_dir/issue-state.json (jq .policy lookup, guarded by jq -e .)
# Writes:   removes labels, removes files. No Linear comment posts.
# Stdout:   single line "wait_files=N skip_labels=M state_file=true|false"
#           captured by caller into the metric notes + audit string (D-013).
# Stderr:   log lines per the existing log() helper.
_resolve_reset_side_state() {
  local issue="$1"
  local d; d="$(issue_dir "$issue")"
  # Defense in depth (Security P2): reject empty issue_dir.
  [[ -n "$d" ]] || die "halt-resolve: empty issue_dir for $issue"

  # D-007: skip-until-* label removal (idempotent — remove_label no-ops if absent).
  local skip_count=0
  for lbl in "pipeline:skip-until-code-changes" "pipeline:skip-until-human-acts"; do
    if bash "$SCRIPT_DIR/linear.sh" has-label "$issue" "$lbl" 2>/dev/null; then
      bash "$SCRIPT_DIR/linear.sh" remove-label "$issue" "$lbl" 2>/dev/null || true
      skip_count=$((skip_count + 1))
    fi
  done

  # D-005: wholesale wait-*.json glob removal.
  # Count first (compgen handles no-match cleanly), then remove.
  local wait_count=0
  if compgen -G "$d/wait-*.json" >/dev/null 2>&1; then
    wait_count="$(compgen -G "$d/wait-*.json" | wc -l | tr -d ' ')"
    rm -f "$d"/wait-*.json 2>/dev/null || true
  fi

  # D-006: conditional issue-state.json removal.
  local state_file="$d/issue-state.json"
  local state_removed=false
  if [[ -s "$state_file" ]] && jq -e . "$state_file" >/dev/null 2>&1; then
    local policy
    policy="$(jq -r '.policy // ""' "$state_file" 2>/dev/null || printf '')"
    if [[ "$policy" == "skip-until-human-acts" ]]; then
      rm -f "$state_file"
      state_removed=true
      log "halt-resolve: removed $state_file (policy=skip-until-human-acts)"
    fi
  fi

  printf 'wait_files=%d skip_labels=%d state_file=%s' \
    "$wait_count" "$skip_count" "$state_removed"
}
```

### 3.3 Updated `resolve()` flow

```bash
resolve() {
  local issue="$1" decision="$2"
  # D-014: strict issue-id validation before ANY filesystem or Linear write.
  [[ "$issue" =~ ^ENG-[0-9]+$ ]] \
    || die "halt.sh: invalid issue id '$issue' (expected ENG-<digits>)"
  # ... existing decision arg validation ...

  local body
  body="$(printf '<!-- pipeline-decision: %s -->\n\nHalt resolved by human via halt.sh (decision=%s).' "$decision" "$decision")"
  bash "$SCRIPT_DIR/linear.sh" add-comment "$issue" "$body"

  if [[ "$decision" == "resume" ]]; then
    source "$SCRIPT_DIR/verdict-handler.sh"
    local current_stage rc=0 had_halt=0
    current_stage="$(bash "$SCRIPT_DIR/linear.sh" stage-of "$issue")"
    current_stage="${current_stage#stage:}"
    # D-014 bonus: validate stage shape before any printf interpolation.
    [[ "$current_stage" =~ ^[a-z]+$ ]] || current_stage="unknown"

    # D-011: skip verdict_handler entirely if halt is absent. Otherwise
    # _vh_protocol_violation re-halts the (chained scope-approved →
    # resume) issue via bin/verdict-handler.sh:58. Synthetic vh_rc=1
    # path in that case.
    if bash "$SCRIPT_DIR/linear.sh" has-label "$issue" "pipeline:halted"; then
      had_halt=1
      verdict_handler "$issue" "$current_stage" || rc=$?
    else
      log "halt-resolve: pipeline:halted absent; skipping verdict_handler (D-011)"
      rc=1
    fi

    local cleared_waypoint=0
    case "$rc" in
      0)
        # apply_transition advanced the stage and posted its own
        # `<!-- pipeline-transition: from → to -->` waypoint, AND removed
        # pipeline:halted. We still owe side-state cleanup (D-004).
        local stats; stats="$(_resolve_reset_side_state "$issue")"
        _emit_halt_resume_metric "$issue" "$current_stage" "$stats" "$cleared_waypoint"
        log "halt resolved: $issue decision=resume (verdict-handler transitioned; side state reset)"
        return 0
        ;;
      1)
        # No fresh forward verdict (or D-011 synthetic rc=1).
        # Atomic order (D-008): cleanup → halt remove (only if had_halt) →
        # operator-resume waypoint LAST.
        local stats; stats="$(_resolve_reset_side_state "$issue")"
        if (( had_halt )); then
          bash "$SCRIPT_DIR/linear.sh" remove-label "$issue" "pipeline:halted"
        fi
        local waypoint_body
        waypoint_body="$(printf '<!-- pipeline-transition: %s → %s (operator-resume) -->\n\nOperator-attributed transition waypoint (halt.sh resolve --decision resume).\n\n%s' \
                          "$current_stage" "$current_stage" \
                          "$(_format_reset_audit "$stats")")"
        bash "$SCRIPT_DIR/linear.sh" add-comment "$issue" "$waypoint_body"
        cleared_waypoint=1
        _emit_halt_resume_metric "$issue" "$current_stage" "$stats" "$cleared_waypoint"
        log "halt resolved: $issue decision=resume (halt label ${had_halt:+cleared}${had_halt:-absent}; side state reset; operator-resume waypoint posted)"
        return 0
        ;;
      2)
        # Protocol violation — verdict-handler re-applied pipeline:halted.
        # NO cleanup, NO waypoint (D-004, D-003).
        printf 'halt.sh: verdict-handler reported protocol violation on %s; halt label preserved.\n' "$issue" >&2
        printf 'halt.sh: see Linear comment with sig protocol-violation/<case_id>/%s for details.\n' "$issue" >&2
        return 2
        ;;
      *) die "verdict_handler returned unknown rc=$rc" ;;
    esac
  fi

  # scope-approved / scope-rejected paths: D-009. Current minimal behavior +
  # D-012 stale-state observation advisory.
  _observe_stale_side_state "$issue"   # stderr advisory only; never fails
  bash "$SCRIPT_DIR/linear.sh" remove-label "$issue" "pipeline:halted"
  log "halt resolved: $issue decision=$decision"
}

# D-013 helper. Emit a metrics row capturing the reset stats.
_emit_halt_resume_metric() {
  local issue="$1" stage="$2" stats="$3" waypoint_posted="$4"
  bash "$SCRIPT_DIR/metrics.sh" halt-resume "$issue" "$stage" \
    "atomic-reset" 0 "$stats waypoint_posted=$waypoint_posted" || true
}

# Format the side-state audit string used by both the operator-resume
# comment body and the metric notes. Body shape:
# "Cleared: wait_files=N skip_labels=M state_file=B"
_format_reset_audit() {
  local stats="$1"
  printf '_Cleared:_ %s\n' "$stats"
}

# D-012: stderr advisory when scope-approved/scope-rejected sees side state.
_observe_stale_side_state() {
  local issue="$1"
  local d; d="$(issue_dir "$issue")"
  local hits=()
  bash "$SCRIPT_DIR/linear.sh" has-label "$issue" "pipeline:skip-until-code-changes" \
    && hits+=("pipeline:skip-until-code-changes")
  bash "$SCRIPT_DIR/linear.sh" has-label "$issue" "pipeline:skip-until-human-acts" \
    && hits+=("pipeline:skip-until-human-acts")
  compgen -G "$d/wait-*.json" >/dev/null 2>&1 && hits+=("$d/wait-*.json")
  [[ -s "$d/issue-state.json" ]] && hits+=("$d/issue-state.json")
  if (( ${#hits[@]} > 0 )); then
    printf 'halt.sh: NOTE — stale side state detected on %s (%s); run `bash %s/bin/halt.sh resolve %s --decision resume` to clear.\n' \
      "$issue" "$(IFS=', '; printf '%s' "${hits[*]}")" "$HARNESS_ROOT" "$issue" >&2
  fi
}
```

`_resolve_reset_side_state` (§3.2) is updated to print a single
status line on stdout that the caller captures into `stats`:
`wait_files=N skip_labels=M state_file=true|false`. All log-style
output is on stderr so the stdout capture is clean.

### 3.4 Test cases (additions to `bin/halt-test.sh`)

Existing cases A-D (`bin/halt-test.sh:52-86`) cover the vh_rc 0/1/2/
scope-approved branches at the verdict-handler-call layer; they are
preserved unchanged. New cases E-J (and a regression case K) extend
the existing harness shape — `STUB_DIR/linear.sh` already logs every
call into `LINEAR_CALLS`, and `VH_RC` already controls verdict_handler.
Per-issue side state is created in the test's `_TEST_TARGET` /
`HARNESS_STATE_DIR` temp dir (already configured at
`bin/halt-test.sh:11-21`).

| Case | Setup | Assertion |
|---|---|---|
| E | VH_RC=1, has-label pipeline:halted=true, pre-create `wait-build.json`, `pipeline:skip-until-human-acts` label, `issue-state.json` (policy=skip-until-human-acts), and stale `<!-- pipeline-metric: review_rejection -->` markers. | wait-*.json absent; remove-label called for both skip shapes (since stub returns has-label true); issue-state.json absent; final linear.sh call sequence ends with the `add-comment` carrying `<!-- pipeline-transition: <stage> → <stage> (operator-resume) -->`. |
| F | VH_RC=0, has-label pipeline:halted=true, same side state as E. | Side state cleared (cleanup ran on the transitioned arm too — D-004); NO operator-resume `add-comment` recorded (apply_transition's own waypoint is the boundary — D-003). |
| G | VH_RC=2, has-label pipeline:halted=true, same side state as E. | wait-*.json STILL present; skip-until-* labels NOT removed (no remove-label call); issue-state.json STILL present; pipeline:halted NOT removed; resolve returns rc=2. |
| H | `scope-approved`, has-label pipeline:halted=true, with same side state as E pre-existing. | Side state UNCHANGED (no remove-label for skip shapes; wait-*.json still present; issue-state.json still present); decision marker posted; pipeline:halted removed; D-012 stderr advisory printed to STDERR mentioning each detected stale-state class (preserves D-009 minimal contract + D-012 advisory). |
| I | VH_RC=1, has-label pipeline:halted=true, `issue-state.json` exists with `policy=skip-until-code-changes`. | issue-state.json STILL present after resolve (D-006 conditional preserves the evidence trail for poll.sh's auto-resume). |
| J | VH_RC=1, has-label pipeline:halted=true, fully clean state (no skip labels, no wait files, no issue-state.json). | resolve completes rc=0 with no errors; operator-resume waypoint posted; metrics.sh halt-resume recorded with `wait_files=0 skip_labels=0 state_file=false waypoint_posted=1`; idempotency verified by running resolve a second time (second invocation: has-label still returns true; cleanup is no-op; waypoint posted again — see dedup compatibility note below). |
| K (regression) | VH_RC=1, has-label pipeline:halted=true, pre-existing 2 stale `<!-- pipeline-metric: review_rejection -->` markers (above any plausible threshold). After resolve, simulate a guards.sh `count_marker_since_last_transition` read against the post-resolve comment fixture. | count_marker_since_last_transition returns 0 (the operator-resume waypoint is the new boundary; older rejection markers are not counted). |
| L (D-011) | `--decision resume`, has-label pipeline:halted=**false** (chained scope-approved → resume scenario), pre-existing wait-build.json + skip-until-human-acts label. | verdict_handler is NOT called (no `verdict_handler` invocation logged); cleanup runs (wait file removed, label removed); operator-resume waypoint posted; `pipeline:halted` is NOT in the remove-label call sequence (it was already absent — no remove call needed); rc=0. Critical regression: pre-D-011 this case re-halts the issue via `_vh_protocol_violation`. |
| M (D-012) | `--decision scope-approved`, has-label pipeline:halted=true, AND pre-existing wait-build.json. | Decision marker posted; pipeline:halted removed; STDERR contains `halt.sh: NOTE — stale side state detected … wait-*.json …`; wait-build.json still present (scope-approved does NOT clear it per D-009). |
| N (D-013) | `--decision resume` after pre-cleared state with 2 wait-files + 1 skip label + state file (policy=skip-until-human-acts). | metrics.sh stub captures a `halt-resume` event with notes containing `wait_files=2 skip_labels=1 state_file=true waypoint_posted=1`. |
| O (D-014 path-traversal) | `halt.sh resolve "ENG-../../etc" --decision resume` (invalid issue id with `..` segment). | resolve dies before any FS or Linear write (no remove-label calls; no rm of any path). Stderr contains "invalid issue id". |
| P (D-014 stage-shape) | `--decision resume`, stage-of stub returns `stage:foo%s` (crafted label). | current_stage is sanitized to `unknown`; operator-resume waypoint body literal-checks for `unknown → unknown`; no `%s`-consumption corruption. |

Compatibility note for case J idempotency: `linear.sh add-comment`
hashes (timestamp- and SHA-stripped) the body and dedups against the
last 10 comments (`bin/linear.sh:455-487`). The operator-resume body
is a fixed string for a given (issue, stage) pair; the second
invocation's body matches the first, so the second `add-comment` will
log `add-comment: duplicate suppressed` and return 0. The stub
linear.sh in halt-test.sh does NOT replicate the dedup, so the test
will see two `add-comment` calls (correctly mirrors the real-world
pre-dedup-guard call, which is what we want to assert: the orchestrator
attempted the post both times). Rephrase the assertion as "second
resolve call returns rc=0 and produces an identical second
add-comment in `LINEAR_CALLS`" — adequate for idempotency at the
halt.sh layer.

### 3.5 CLAUDE.md update

Replace the existing `Kill switch` row in the Failure-mode quick
reference (`CLAUDE.md:294`). Format as a short row + bullet list to
keep it operator-skim-friendly (iter-1 Product P1 — "dense and
operator-hostile"):

> | Kill switch | `bash bin/halt.sh resolve <ENG-N> --decision resume` (atomic reset, see below) or set `orchestrator.paused=true` (takes effect next tick) |

Then add a short subsection under Failure-mode quick reference:

> **What `--decision resume` clears (atomic, ENG-58):**
>
> 1. `pipeline:halted` label
> 2. `pipeline:skip-until-code-changes` and `pipeline:skip-until-human-acts` labels
> 3. `$PROJECT_STATE_DIR/<ident>/wait-*.json` files
> 4. `$PROJECT_STATE_DIR/<ident>/issue-state.json` IFF its `.policy == "skip-until-human-acts"`
> 5. Posts a `<!-- pipeline-transition: <stage> → <stage> (operator-resume) -->` waypoint to reset `count_marker_since_last_transition` (rejection counter) and `find_fresh_verdict` freshness.
>
> `--decision scope-approved` / `--decision scope-rejected` are the
> NARROWER paths (only post the decision marker + remove
> `pipeline:halted`); they do NOT clear (1)-(4) because scope-deviation
> halts don't accrue that side state. If stale state from an unrelated
> earlier failure coexists, halt.sh emits a one-line stderr advisory
> pointing the operator to the resume path.

## 4. Data flow

### 4.1 Happy resume — vh_rc=1 path (the bug fix's primary target)

```
operator: bash bin/halt.sh resolve ENG-58 --decision resume
  (PIPELINE_WRITER=human exported at bin/halt.sh:14)

halt.sh::resolve("ENG-58", "resume")
  ├─ linear.sh add-comment "<!-- pipeline-decision: resume -->\n\n..."
  ├─ source verdict-handler.sh; current_stage=$(linear.sh stage-of)
  ├─ verdict_handler "ENG-58" "building" → rc=1
  │  (no fresh forward verdict; halt marker IS fresh; preserved)
  └─ case 1:
       ├─ _resolve_reset_side_state "ENG-58"
       │   ├─ linear.sh remove-label pipeline:skip-until-code-changes  (no-op if absent)
       │   ├─ linear.sh remove-label pipeline:skip-until-human-acts    (removes if present)
       │   ├─ rm -f $issue_dir/wait-*.json                              (removes wait-build.json)
       │   └─ if jq .policy == skip-until-human-acts: rm $issue_dir/issue-state.json
       ├─ linear.sh remove-label pipeline:halted
       └─ linear.sh add-comment "<!-- pipeline-transition: building → building (operator-resume) -->\n\n..."

POST-CONDITIONS observable on the issue:
  - No pipeline:halted, no pipeline:skip-until-* labels
  - Latest comment: pipeline-transition: building → building (operator-resume)
  - count_marker_since_last_transition(*, *) returns 0 for any rejection counter
  - find_fresh_verdict returns empty (operator-resume IS the latest "transition")
  - $issue_dir/wait-*.json absent
  - $issue_dir/issue-state.json absent (was policy=skip-until-human-acts)
```

Next launchd tick:
```
poll.sh
  ├─ _poll_evaluate_skip(ENG-58, labels)
  │  - no skip-until-* labels, no orphan state file → return 0 (include)
  ├─ _poll_classify_labels: no halt, no other blocker labels
  │  → falls through to else branch (poll.sh:266) → hold, advanceable=true
  └─ Pass 4: dispatch ENG-58 build (or whatever stage:* it carries)

run-stage.sh ENG-58 build
  └─ build agent runs P1..P7
     - if P2/P5 fail: posts pipeline-wait → run-stage.sh::_handle_wait
       starts a FRESH wait-build.json at attempts=1 (D-005's wholesale
       cleanup ensured the old file is gone, so the next wait window
       gets a clean budget)
     - if all preconditions pass: stage-summary, transition forward
```

### 4.2 vh_rc=0 path (operator clears halt while a fresh forward verdict exists)

```
halt.sh::resolve("ENG-58", "resume")
  ├─ linear.sh add-comment "<!-- pipeline-decision: resume -->"
  ├─ verdict_handler → rc=0 (apply_transition ran)
  │  - apply_transition posted: <!-- pipeline-transition: building → released -->
  │  - apply_transition removed pipeline:halted
  └─ case 0:
       └─ _resolve_reset_side_state "ENG-58"
            (same cleanup as case 1, but NO operator-resume waypoint —
             apply_transition's real waypoint is the boundary)

POST-CONDITIONS:
  - Stage advanced to released (apply_transition did this)
  - Latest transition comment: building → released (apply_transition's)
  - All side state cleared (cleanup ran)
```

### 4.3 vh_rc=2 path (protocol violation — preserve halt, NO cleanup)

```
halt.sh::resolve("ENG-58", "resume")
  ├─ linear.sh add-comment "<!-- pipeline-decision: resume -->"
  ├─ verdict_handler → rc=2
  │  - _vh_protocol_violation posted: <!-- pipeline-halt: protocol-violation -->
  │  - _vh_protocol_violation re-applied pipeline:halted
  └─ case 2:
       (NOTHING — no cleanup, no waypoint, no halt removal)
       return 2

POST-CONDITIONS (deliberate):
  - pipeline:halted still applied
  - All side state preserved (operator must investigate the violation
    and any related state corruption before resuming)
  - Stale skip labels and wait files persist (intentional — operator may
    need to inspect them as part of investigation)
  - halt.sh exits non-zero; the operator sees stderr message pointing at
    the protocol-violation/<case_id>/<issue> comment sig
```

### 4.4 scope-approved / scope-rejected (D-009 minimal path, unchanged)

```
halt.sh::resolve("ENG-58", "scope-approved")
  ├─ linear.sh add-comment "<!-- pipeline-decision: scope-approved -->"
  ├─ (decision != "resume" → skip the resume block entirely)
  └─ linear.sh remove-label pipeline:halted

POST-CONDITIONS:
  - pipeline:halted removed
  - $issue_dir/scope-approval (positive sentinel) PRESERVED for
    run-stage.sh::_replay_scope_approval
  - Any unrelated side state PRESERVED (skip-until-*, wait-*.json,
    issue-state.json) — D-009 documents this asymmetry deliberately
```

## 5. Error handling

- **Lane-fence rejection on `add transition_comment`.** Lane fence
  allows orchestrator,human (`bin/linear.sh:85`); halt.sh exports
  PIPELINE_WRITER=human. ✓ Cannot reject under the current contract.
  If a future tightening adds further fences, halt.sh's exit on
  `_check_lane` returning 13 (`bin/linear.sh:128`) propagates upward
  via the script's `set -e` (`bin/halt.sh:8`). Operator sees the
  structured stderr message; can re-run after the fence change is
  reverted or after authorization adjusts.

- **Linear API failure when posting the operator-resume waypoint.**
  `add-comment` returns nonzero on Linear API failure (after 3 retries
  with exponential backoff at `bin/linear.sh:166-186`). Without `|| true`
  on the call, `set -e` aborts halt.sh with non-zero exit. The cleanup
  before it has already succeeded (the operations are all `|| true`-
  protected for the lower-priority pieces). The label is already
  removed, the wait/state files are already gone, but the freshness
  boundary is not posted. Operator sees stderr (and halt.sh's exit
  code), re-runs `halt.sh resolve --decision resume`. The second
  invocation: cleanup is a no-op (idempotent); halt label removal is
  a no-op (already absent — `linear.sh remove-label` logs "noop" at
  `bin/linear.sh:271-274`); operator-resume waypoint post is the only
  meaningful action. Net effect: the failure is recoverable with one
  re-run.

- **Linear API failure when calling `verdict_handler`.** Existing
  behavior preserved. `verdict_handler` returns its own rc; if it
  cannot read comments, find_fresh_verdict returns empty and
  `_vh_protocol_violation` fires a "no-marker" halt → vh_rc=2
  (`bin/verdict-handler.sh:323-326`). halt.sh's case 2 path leaves
  the halt intact and exits 2. Operator investigates.

- **`stage-of` returns empty (issue carries no stage:* label).**
  An issue with `pipeline:halted` but no `stage:*` label is a
  pre-existing degenerate case — verdict_handler's apply_transition
  would die at `bin/verdict-handler.sh:148-149` ("add-label
  stage:<empty>"). For the operator-resume waypoint posting in case 1,
  we use `${current_stage:-unknown}` to avoid posting a marker with
  empty `→` operands (which would fail `_classify_comment_body`'s
  first-non-blank-line regex match at `bin/linear.sh:62` and
  classify as `other_comment` — which IS allowed for human lane,
  so the post would succeed but the comment body would read
  "<!-- pipeline-transition: unknown → unknown (operator-resume) -->").
  Conservative — the operator gets a posted waypoint with an explicit
  marker, can identify the degenerate case from the body, and can
  apply a stage label manually.

- **`$issue_dir` does not exist (clean issue, no side state ever).**
  `rm -f` on a glob that matches nothing is silent; `[[ -s "$state_file" ]]`
  short-circuits. All operations are no-ops. Idempotent.

- **`issue-state.json` is corrupt (invalid JSON).** `jq -e . "$state_file"`
  guard returns nonzero → the entire conditional block is skipped →
  file preserved (operator can investigate). Symmetric with the
  defensive guard in `_handle_wait` at `bin/run-stage.sh:386`.

- **Concurrent ticks on the same issue.** The harness enforces global
  single-flight via `.claude-mutex.lock/` (`CLAUDE.md:172`,
  `bin/common.sh:159-167`). `halt.sh` does NOT participate in that
  mutex (it's an operator CLI, not a tick-driven dispatcher), so
  technically a tick could fire while halt.sh is mid-cleanup. Worst
  case: tick reads stale state mid-cleanup. Mitigations: (a) cleanup
  operations are individually atomic (rm/remove-label are
  single-call); (b) halt.sh runs in <1s typical (Linear API round-
  trips dominate); (c) the launchd tick window is 5min, so the race
  window is small. Not worth a new mutex.

## 6. Edge cases

- **Operator runs `halt.sh resolve --decision resume` on an issue
  whose only halt cause was a wait-budget exhaustion (ENG-45's
  `external-signal-budget-exhausted` reason).** wait-build.json was
  already deleted by `_handle_wait` at the budget-exhaust moment
  (`bin/run-stage.sh:455`) — the rm in `_resolve_reset_side_state`
  is a no-op. No issue-state.json was written (budget escalation
  doesn't go through classify-failure). Skip labels are absent.
  Effective behavior: halt label removed, operator-resume waypoint
  posted. Next tick re-dispatches build cleanly with a fresh
  wait window.

- **Operator runs `halt.sh resolve --decision resume` on an issue
  with BOTH a stale `pipeline:skip-until-code-changes` AND a fresh
  forward stage-summary verdict (vh_rc=0 case).** apply_transition
  advances the stage and removes pipeline:halted. _resolve_reset_side_state
  removes both skip labels. issue-state.json's policy is
  skip-until-code-changes (D-006), so it is NOT removed in halt.sh.
  But poll.sh's orphan cleanup (`bin/poll.sh:55-63`) will delete it
  on the next tick (since neither skip label remains).
  Acceptable: one-tick window where the file persists; no read-
  side observer cares (poll.sh's classify path does not look at it
  unless a skip label is present).

- **Operator runs scope-approved and discovers an unrelated stale
  skip-until-* label exists.** D-009 documents that scope-approved
  is the minimal path; it does NOT clear skip labels. The operator
  chains: `halt.sh resolve --decision scope-approved` (clears the
  scope halt), then `halt.sh resolve --decision resume` (atomic
  reset). The chained flow is now SAFE due to D-011's
  `has-label pipeline:halted` guard around the verdict_handler call.
  Without D-011, the second invocation would hit verdict_handler with
  no halt label AND no fresh verdict → `_vh_protocol_violation`
  unconditionally re-applies pipeline:halted (`bin/verdict-handler.sh:58`),
  silently re-installing the very state the operator just cleared
  — strictly worse than the bug ENG-58 set out to fix. D-011 short-
  circuits to the synthetic vh_rc=1 path: the cleanup runs, no halt
  label is removed (it is already absent), the operator-resume
  waypoint is posted. Net: the chained flow produces the operator's
  intended outcome (clean state). D-012 also surfaces the
  discoverability hint via stderr on the FIRST scope-approved call
  so the operator knows the chained step exists.

- **`pipeline-transition: <stage> → <stage> (operator-resume)`
  observed by `resume_in_progress_transition`.** The strict regex
  `<!-- pipeline-transition: [a-z]+ → [a-z]+ -->`
  (`bin/verdict-handler.sh:276-279`) does NOT match a body with the
  `(operator-resume)` suffix between `<to>` and `-->`. So
  resume_in_progress_transition sees the operator-resume comment as
  the "last_transition" body (via the contains-match at line 271-273)
  but fails to extract from/to via the regex → returns 1 (line 280).
  Net: no spurious mid-transition completion. ✓

- **`pipeline-transition: <stage> → <stage> (operator-resume)` is
  the FIRST transition comment on the issue (no prior transitions).**
  This happens for fresh issues that never advanced past their entry
  stage. find_fresh_verdict's freshness boundary uses last_transition
  via contains-match (`bin/verdict-handler.sh:75-78`) — operator-resume
  is the last_transition. count_marker_since_last_transition same
  (`bin/guards.sh:46-48`). Both work correctly: zero rejection markers
  newer than the operator-resume comment, find_fresh_verdict returns
  empty. ✓

- **`PIPELINE_DRY_RUN=1` set when running halt.sh resolve.** halt.sh
  imports common.sh which exports PIPELINE_DRY_RUN
  (`bin/common.sh:176-177`). Linear writes via linear.sh become log
  lines, not API calls (`bin/linear.sh:157-160`). The `rm -f` and
  `jq` operations still execute (they're local FS, not Linear). This
  is acceptable for dry-run — the operator can use it to preview
  what would happen, and the local cleanup is harmless if the
  operator was going to re-run halt.sh non-dry-run anyway. Not a
  regression — the existing halt.sh has the same dry-run semantics
  for its current operations.

- **Operator-resume waypoint posted with `current_stage="unknown"`
  (degenerate stage-of path).** `_classify_comment_body` requires
  the FIRST non-blank line to start with the literal
  `<!-- pipeline-transition: ` (with trailing space, `bin/linear.sh:62`),
  which the body satisfies. Lane fence allows
  `add transition_comment` for orchestrator,human
  (`bin/linear.sh:85`). The post succeeds. Subsequent
  `count_marker_since_last_transition` and `find_fresh_verdict`
  reads use `contains` and treat the comment as a valid boundary —
  zero downstream reads care about the `unknown → unknown` content.
  Operator notices the body content and applies a stage label
  manually if needed.

- **The dedup in `linear.sh add-comment` (`bin/linear.sh:455-487`)
  swallows the operator-resume waypoint if an identical body was
  posted in the last 10 comments.** The body includes the issue
  identifier indirectly via the stage name and the suffix
  "halt.sh resolve --decision resume". For a single resume after a
  long halt, the dedup window (last 10 comments) is unlikely to
  contain a previous identical waypoint — but if the operator runs
  resolve twice in quick succession (case J), the second post is
  suppressed. This is acceptable — the freshness boundary from the
  first post is still in place; the second post being a no-op is
  correct semantically. Documented in §3.4's compatibility note.

## 7. Open questions

- **Q1 (RESOLVED in iter-2 by D-011 + D-012).** Original question
  was about discoverability of the chained `scope-approved` →
  `resume` flow. Iter-1 reviewers (Coherence P0, Design P1, Product
  P0) flagged that the chained flow was actively *dangerous*
  (`_vh_protocol_violation` re-halts), not merely undiscoverable.
  D-011 (skip verdict_handler when halt label absent) + D-012
  (stderr advisory on scope-approved when stale state coexists)
  jointly close this. No remaining open question.

- **Q2.** Should the operator-resume waypoint body include the
  operator's email (or git user.email)? Current decision: NO. The
  attribution "Operator-attributed transition waypoint (halt.sh
  resolve --decision resume)" plus the audit string from
  `_format_reset_audit` (D-013) is sufficient. Linear's `createdBy`
  records the GitHub App identity — for a single-operator setup
  (operator: rajat.goyal@gmail.com) this is unambiguous; for a
  hypothetical future multi-operator setup, the createdBy is
  bot-attributed and operator identity would NOT be recoverable from
  Linear alone. If multi-operator becomes a reality, raise then;
  documented as a known limitation rather than left implicit.

- **Q3 (minor).** The `wait-*.json` glob assumes only halt.sh and
  the (build-stage success path at `bin/run-stage.sh:836`) are the
  legitimate writers. If a future ticket adds an unrelated `wait-*`-
  named file under `$issue_dir`, the glob would erroneously delete
  it. Mitigation: name future state files with a different prefix
  (the existing convention in this dir is well-established —
  `usage-${stage}.json`, `stage-summary-${stage}.md`,
  `scope-approval`, `issue-state.json`). Not a blocking concern;
  documented as a forward-compat tripwire.

- **Q4 (status.sh rendering — minor).** The `status.sh` dashboard
  may render `building → building (operator-resume)` as a no-op
  transition row in the per-issue narrative. Worth a one-line check
  during implementation; if rendering is confusing, add a single
  conditional in status.sh to recognise the `(operator-resume)`
  suffix and label the row "operator reset" instead of the literal
  arrow text. Not blocking — the comment thread is the primary
  audit surface.

## 8. Anti-bias checks

### 8.1 ADR stress test

There is no `docs/knowledge/decisions.md` ADR file in this repo
(verified by `ls docs/`: only `brainstorms`, `plans`, `runbooks`).
Architectural decisions live in prior brainstorm docs. Stress-test
against the load-bearing ones:

- **ENG-18** (`docs/brainstorms/2026-04-22-pipeline-state-machine-formalization-design.md`,
  the verdict-marker protocol) — Pressure: this brainstorm
  introduces a new from-to-self transition shape (`<stage> →
  <stage>`). ENG-18's invariants (orchestrator-owned transitions,
  append-only verdicts, freshness rule via last-transition
  boundary) are all preserved: the operator-resume waypoint IS
  orchestrator-owned (halt.sh writes it, agents do not), append-only
  via `add-comment` (not edit-in-place), and the freshness rule
  is exactly what ENG-58 leverages.

  ENG-18 did not anticipate from=to transitions. The strict-regex
  reader in `resume_in_progress_transition`
  (`bin/verdict-handler.sh:276-279`) is the existing safety net
  against unintended interpretation; D-002's `(operator-resume)`
  suffix is what avoids tripping it. This is a deliberate
  composition with the existing invariant, not a violation.

- **ENG-41** (lane fences,
  `docs/brainstorms/2026-04-27-pipeline-trust-model-enforce-write-lanes-design.md`)
  — Pressure: posting a transition comment from halt.sh is a write.
  `add transition_comment` is gated to orchestrator,human
  (`bin/linear.sh:85`). halt.sh exports PIPELINE_WRITER=human
  (`bin/halt.sh:14`). ✓

- **ENG-45** (build wait/budget,
  `docs/brainstorms/2026-04-28-build-agent-soft-preconditions-p2-p5-should-re-dispatch-not-halt-for-human-design.md`)
  — Pressure: ENG-45 declared `wait-${stage}.json` is "owned and
  incremented by the orchestrator (run-stage.sh), not the agent".
  This brainstorm adds halt.sh as a second writer (deletion only).
  The "owned" framing is preserved — halt.sh is also part of the
  orchestrator's surface (operator-driven side, but same trust
  domain); the human lane is explicitly authorized for orchestrator-
  owned state mutations. Not a violation; an extension.

- **ENG-49 Gap #2** (`bin/halt.sh:30-37` predates this brainstorm —
  the verdict_handler-before-clear ordering for resume) —
  Pressure: D-008's "operator-resume LAST" ordering must compose
  with the existing "verdict_handler FIRST" ordering. They compose
  cleanly because the new ordering is INSIDE the case 1 arm
  (no fresh forward verdict), where verdict_handler has already
  returned without doing anything. The cleanup + halt remove +
  waypoint sequence is purely additive within case 1; it does not
  reorder or skip the verdict_handler call.

- **ENG-54** (consolidate human-approval gate,
  `docs/brainstorms/...build-p2/...`) — Pressure: ENG-54 narrowed
  `_fresh_wait_reason` to build-only (`bin/run-stage.sh:308-311`).
  The wholesale `wait-*.json` glob in D-005 is consistent with
  build-only today and forward-compat if a future ticket re-broadens
  the gate. No conflict.

- **ENG-56** (orchestrator-canonical halt applier) — Pressure: the
  orchestrator is the canonical applier. Operator-resume halt
  removal in halt.sh is human-applied (`PIPELINE_WRITER=human`),
  which is a separate lane. ENG-56's invariant is about the
  orchestrator NOT relinquishing canonical-applier status; halt.sh
  is the operator's CLI, never the orchestrator's tick-driven
  applier. No conflict.

### 8.2 Simpler alternatives considered

Documented inline at:
- D-001 — alternative cleanup loci (poll.sh; reset-pipeline.sh chained)
- D-002 — alternative marker shape (new `pipeline-resume:` shape)
- D-003 — alternative waypoint posting (always vs. conditional)
- D-005 — alternative wait-file scope (parse halt comment for
  per-stage attribution)
- D-006 — alternative issue-state.json deletion (always; never)
- D-007 — alternative skip-label removal (one shape only)
- D-008 — alternative ordering (waypoint FIRST)
- D-009 — alternative for scope-approved (share resume's atomic path)
- D-010 — alternative test location (halt-sprawl-test.sh)

The strictly-simplest alternative — "rely on poll.sh's existing
orphan-cleanup behavior to eventually reset side state" — was
implicitly rejected because it leaves an inter-tick window that the
ENG-24 pathology already exploited (the 33-second re-halt happened
within one tick). Atomicity at the operator command boundary is the
load-bearing requirement.

### 8.3 Assumption inventory

| Assumption | Status | Evidence |
|---|---|---|
| `bin/halt.sh::resolve()` exists with arg-validated decision dispatcher (resume / scope-approved / scope-rejected) | verified | `bin/halt.sh:16-65` |
| `bin/halt.sh:14` exports `PIPELINE_WRITER=human` at file-scope | verified | `bin/halt.sh:13-14` |
| `verdict_handler` returns 0 (transitioned), 1 (halt preserved), 2 (protocol violation) | verified | `bin/verdict-handler.sh:312-369` |
| `apply_transition` posts `<!-- pipeline-transition: from → to -->` and removes `pipeline:halted` | verified | `bin/verdict-handler.sh:142-145, 256` |
| `find_fresh_verdict` boundary detection uses `contains("<!-- pipeline-transition:")` (substring, not regex) — therefore tolerates the `(operator-resume)` body suffix and the from=to pattern | verified | `bin/verdict-handler.sh:75-78` |
| `count_marker_since_last_transition` boundary detection uses the same `contains` check | verified | `bin/guards.sh:46-48` |
| `resume_in_progress_transition`'s body-extraction regex requires `-->` immediately after `<to>` (rejects the `(operator-resume)` suffix → returns 1 cleanly) | verified | `bin/verdict-handler.sh:276-280` |
| Lane fence: `add transition_comment` allows `orchestrator,human` | verified | `bin/linear.sh:85` |
| Lane fence: `remove pipeline_skip_until` allows `orchestrator,classify,human` | verified | `bin/linear.sh:84` |
| Lane fence: `remove pipeline_halted` allows `orchestrator,human` | verified | `bin/linear.sh:80` |
| `_classify_comment_body` classifies a body whose first non-blank line is `<!-- pipeline-transition: <X> → <Y> -->` (with optional trailing suffix) as `transition_comment` | verified | `bin/linear.sh:56-67` (sed strips leading whitespace; regex `^'<!--'\ pipeline-transition:\ .+\ '-->'` matches the suffix-included body via the `.+` middle) |
| `bin/run-stage.sh::_handle_wait` writes `$(issue_dir "$ident")/wait-${stage}.json` and the success path at `bin/run-stage.sh:836` deletes it | verified | `bin/run-stage.sh:378, 424, 836` |
| Build stage is currently the only `_fresh_wait_reason` allow-listed stage (ENG-54) — wait-*.json glob today resolves only to wait-build.json | verified | `bin/run-stage.sh:308-311` |
| `bin/classify-failure.sh::classify_failure` writes `$(issue_dir)/issue-state.json` carrying `.policy` field with values in `{retry-immediately, skip-until-code-changes, skip-until-human-acts}` | verified | `bin/classify-failure.sh:39-103` |
| `bin/poll.sh::_poll_evaluate_skip` deletes orphan `issue-state.json` (no skip label present) | verified | `bin/poll.sh:55-63` |
| `bin/scope-check.sh` writes `$(issue_dir)/scope-approval` (positive sentinel for replay) — NOT deleted by halt.sh per D-009 | verified | `bin/run-stage.sh:592, 617-618` (write); `bin/run-stage.sh:127-131, 599, 611` (read + clear by run-stage success) |
| `bin/halt-test.sh` exists and uses the source-and-stub pattern with `VH_RC` env var to control verdict_handler return | verified | `bin/halt-test.sh:36-50` |
| `bin/linear.sh::remove_label` is idempotent — no-ops with log line "label not present on $ident" when label absent | verified | `bin/linear.sh:271-274` |
| `bin/linear.sh::add_comment` dedups against the last 10 comments via timestamp/SHA-stripped hash | verified | `bin/linear.sh:455-487` |
| `bin/linear.sh::add_comment` accepts comment body via positional or stdin (`--body -`) per ENG-55 | verified | `bin/linear.sh:440-444` (`_resolve_body_arg`) |
| `bin/common.sh::issue_dir` returns `$PROJECT_STATE_DIR/<issue>` | verified | `bin/common.sh:61-65` |
| `$issue_dir` is the canonical per-issue scratch dir (not `$HARNESS_STATE_DIR/<issue>`) — per CLAUDE.md don't list | verified | `CLAUDE.md` "Don'ts" + `bin/common.sh:50-55, 61-65` |
| `bin/linear.sh::stage_of` returns the first `stage:*` label or empty | verified | `bin/linear.sh:287-290` |
| `bin/halt.sh:29-37` already sources `verdict-handler.sh` and resolves `current_stage` via `linear.sh stage-of` for the resume branch | verified | `bin/halt.sh:33-36` |
| `bin/reset-pipeline.sh:42-43` is the existing precedent for wholesale skip-until-* removal in the human lane | verified | `bin/reset-pipeline.sh:42-43` |
| `bin/halt-sprawl-test.sh` tests `_poll_emit_halt_sprawl_alert` (in poll.sh), NOT halt.sh — wrong sibling for this work; halt-test.sh is the right one | verified | `bin/halt-sprawl-test.sh:1-8, 191, 217, 243, 265, 292, 303, 325, 348, 364, 385` (every assertion calls `_poll_emit_halt_sprawl_alert`) |
| `CLAUDE.md:294` Kill switch row is the documentation surface to update | verified | `CLAUDE.md:286-294` |
| The strict-regex check in `resume_in_progress_transition` returns 1 (no recoverable transition) when the regex extraction yields an empty `from` or `to` | verified | `bin/verdict-handler.sh:280` (`[[ -z "$from" || -z "$to" ]] && return 1`) |
| ENG-58 will be the next-tested stage; tests must pass for both halt-test.sh and halt-sprawl-test.sh | verified | `learned-rules/harness/project-profile.md` Build & test gates row |
| Operator-resume waypoint body posted via halt.sh's existing `add-comment` codepath does NOT trigger any existing verdict-handler tables (loopback or forward) — because verdict_handler returned BEFORE this post | verified | `bin/halt.sh:33-37` (verdict_handler is called, returns rc; post happens AFTER) |

### 8.4 Codebase-fact verification (mandatory)

Every named code artifact in this brainstorm is anchored to the
current worktree:

| Name | path:line citation |
|---|---|
| `bin/halt.sh::resolve()` (function entry; arg validation) | `bin/halt.sh:16-23` |
| `bin/halt.sh::resolve()` add-comment of decision marker | `bin/halt.sh:25-27` |
| `bin/halt.sh::resolve()` resume branch + verdict_handler call | `bin/halt.sh:29-37` |
| `bin/halt.sh::resolve()` case 0/1/2 dispatch | `bin/halt.sh:38-60` |
| `bin/halt.sh::resolve()` case 1 remove-label call | `bin/halt.sh:46` |
| `bin/halt.sh::resolve()` non-resume final remove-label | `bin/halt.sh:63` |
| `bin/halt.sh` PIPELINE_WRITER=human export | `bin/halt.sh:13-14` |
| `bin/halt.sh::main` decision arg-parse loop | `bin/halt.sh:67-83` |
| `bin/verdict-handler.sh::verdict_handler` entrypoint | `bin/verdict-handler.sh:312-369` |
| `bin/verdict-handler.sh::apply_transition` | `bin/verdict-handler.sh:138-258` |
| `bin/verdict-handler.sh::apply_transition` transition-comment post | `bin/verdict-handler.sh:142-145` |
| `bin/verdict-handler.sh::apply_transition` halt-label remove | `bin/verdict-handler.sh:256` |
| `bin/verdict-handler.sh::find_fresh_verdict` last-transition lookup | `bin/verdict-handler.sh:75-78` |
| `bin/verdict-handler.sh::resume_in_progress_transition` strict regex | `bin/verdict-handler.sh:276-279` |
| `bin/verdict-handler.sh::resume_in_progress_transition` empty-from-or-to guard | `bin/verdict-handler.sh:280` |
| `bin/verdict-handler.sh::_vh_protocol_violation` | `bin/verdict-handler.sh:52-60` |
| `bin/verdict-handler.sh` halt-marker arm (rc=1) | `bin/verdict-handler.sh:360-363` |
| `bin/verdict-handler.sh` no-marker protocol-violation arm (rc=2) | `bin/verdict-handler.sh:323-326` |
| `bin/verdict-handler.sh` apply_transition fwd arm (rc=0) | `bin/verdict-handler.sh:340-348` |
| `bin/guards.sh::count_marker_since_last_transition` | `bin/guards.sh:42-56` |
| `bin/guards.sh::count_marker_since_last_transition` last-transition lookup | `bin/guards.sh:46-48` |
| `bin/run-stage.sh::_handle_wait` | `bin/run-stage.sh:373-462` |
| `bin/run-stage.sh::_handle_wait` writes wait-${stage}.json | `bin/run-stage.sh:378, 424` |
| `bin/run-stage.sh::_handle_wait` budget-exhaust deletes wait-${stage}.json | `bin/run-stage.sh:455` |
| `bin/run-stage.sh::_fresh_wait_reason` build-only allow-list | `bin/run-stage.sh:308-311` |
| `bin/run-stage.sh` success-path wait-${stage}.json cleanup | `bin/run-stage.sh:836` |
| `bin/run-stage.sh` post-implement/ui scope-check writes scope-approval | `bin/run-stage.sh:617-618` |
| `bin/run-stage.sh::_replay_scope_approval` | `bin/run-stage.sh:127-131` |
| `bin/run-stage.sh` scope-approval replay branch | `bin/run-stage.sh:527-534` |
| `bin/run-stage.sh` scope-approval state file clear (success) | `bin/run-stage.sh:599, 611` |
| `bin/classify-failure.sh::classify_failure` | `bin/classify-failure.sh:39-159` |
| `bin/classify-failure.sh` issue-state.json write | `bin/classify-failure.sh:83-103` |
| `bin/classify-failure.sh` skip-until-* label apply | `bin/classify-failure.sh:106-115` |
| `bin/classify-failure.sh` pipeline:halted unconditional add | `bin/classify-failure.sh:117-119` |
| `bin/poll.sh::_poll_evaluate_skip` orphan-state-file cleanup | `bin/poll.sh:55-63` |
| `bin/poll.sh::_poll_evaluate_skip` skip label/state evaluation | `bin/poll.sh:48-122` |
| `bin/poll.sh::_poll_classify_labels` halted branch | `bin/poll.sh:217-233` |
| `bin/poll.sh::_poll_classify_labels` else branch (advanceable default) | `bin/poll.sh:265-267` |
| `bin/linear.sh::_lane_decision` row table | `bin/linear.sh:73-91` |
| `bin/linear.sh::_lane_decision` `add transition_comment` | `bin/linear.sh:85` |
| `bin/linear.sh::_lane_decision` `remove pipeline_skip_until` | `bin/linear.sh:84` |
| `bin/linear.sh::_lane_decision` `remove pipeline_halted` | `bin/linear.sh:80` |
| `bin/linear.sh::_classify_comment_body` transition-comment regex | `bin/linear.sh:56-67` |
| `bin/linear.sh::remove_label` idempotent no-op | `bin/linear.sh:271-274` |
| `bin/linear.sh::add_comment` dedup-by-hash | `bin/linear.sh:455-487` |
| `bin/linear.sh::stage_of` | `bin/linear.sh:287-290` |
| `bin/linear.sh` PIPELINE_DRY_RUN mutation suppression | `bin/linear.sh:157-160` |
| `bin/common.sh::issue_dir` | `bin/common.sh:61-65` |
| `bin/common.sh` PIPELINE_DRY_RUN export | `bin/common.sh:176-177` |
| `bin/common.sh::acquire_lock` (mutex helper) | `bin/common.sh:159-167` |
| `bin/halt-test.sh` source-and-stub pattern + VH_RC | `bin/halt-test.sh:36-50` |
| `bin/halt-test.sh` existing case A-D | `bin/halt-test.sh:52-86` |
| `bin/reset-pipeline.sh` per-issue cleanup precedent | `bin/reset-pipeline.sh:36-45` |
| `bin/halt-sprawl-test.sh` tests `_poll_emit_halt_sprawl_alert` (NOT halt.sh) | `bin/halt-sprawl-test.sh:1-401` (every test invokes `_poll_emit_halt_sprawl_alert`) |
| CLAUDE.md Kill switch row | `CLAUDE.md:286-294` |

No referenced item is non-existent or speculative.

## 9. Scope check vs Linear issue

The Linear issue's IN list (Desired outcome 1-6):

- ✅ 1. Posts `pipeline-decision: resume` (current behavior, kept) —
  preserved in the updated `resolve()` flow (§3.3).
- ✅ 2. Posts `pipeline-transition: <stage> → <stage>
  (operator-resume)` so subsequent `count_marker_since_last_transition`
  and `find_fresh_verdict` reads see a fresh boundary — D-002, D-003,
  D-008.
- ✅ 3. Removes `pipeline:halted` (current behavior, kept) — preserved
  in case 1 arm.
- ✅ 4. Removes any `pipeline:skip-until-*` labels — D-007, in
  `_resolve_reset_side_state`.
- ✅ 5. Removes `$issue_dir/wait-*.json` for every stage (wholesale
  glob; documented choice per D-005).
- ✅ 6. Removes `$issue_dir/issue-state.json` if `policy` is
  `skip-until-human-acts` — D-006, conditional.

The issue's "Decisions inherited from ENG-47 (do not relitigate)"
list:
- ✅ Reuses existing `pipeline-transition` shape with
  `(operator-resume)` body suffix; no new marker shape — D-002.
- ✅ `halt.sh` exports PIPELINE_WRITER=human; operator-attributed
  transition write travels human lane fences cleanly — verified
  (`bin/halt.sh:14`, `bin/linear.sh:85`).
- ✅ Operator authority remains the source of clearing — no auto-
  clearing logic added.

The issue's Acceptance criteria 1-4:
- ✅ AC-1 (post-resolve observables): D-008 ordering produces all
  four AC-1 observables.
- ✅ AC-2 (ENG-24 regression — rejection counter does not re-trip):
  test case K (§3.4) exercises this directly.
- ✅ AC-3 (scope-approved/scope-rejected): D-009 documents the
  narrower path explicitly.
- ✅ AC-4 (`bin/halt-sprawl-test.sh` or sibling covers the four-step
  reset; existing halt-sprawl assertions continue to pass): D-010
  routes new tests to `bin/halt-test.sh` (the actual halt.sh-testing
  sibling); halt-sprawl-test.sh is untouched (it tests poll.sh, not
  halt.sh).

The issue's OUT list:
- ✅ No new marker or wait sub-shapes — D-002 (suffix is body-text
  only, not a new shape).
- ✅ No auto-clearing halt based on Linear comment heuristics — no
  such logic added; resume is operator-driven only.
- ✅ No re-architecting how secrets enter agent context (ENG-46
  already shipped; orthogonal).
- ✅ No generalizing pipeline-wait beyond build (ENG-54 contradicts
  this; respected).
- ✅ No touching defensive-halt-add code (ENG-56 already neutered;
  not modified).

No scope sprawl detected. The change is isolated to `bin/halt.sh`
(one new helper + extended resume branch), `bin/halt-test.sh` (six
new test cases), and `CLAUDE.md` (one row update).

## 10. Persona review

Each iteration is a full pass through 6 personas in fixed order
(design → security → scope → coherence → product → feasibility).
Iterate until ≥5/6 PASS AND feasibility = 0 P0; max 3 iterations.

### Iteration 1 (independent personas, 5-of-6 in parallel)

- **Design lens:** PASS with 1 P1.
  - P1: chained `scope-approved` → `resume` foot-gun (Q1 was
    deferred but is a real composition bug). Design says "should not
    ship as-is."
  - Sub-MODERATE: §6 `current_stage="unknown"` degenerate path
    posted with `unknown → unknown` body — accepted gracefully but
    operator-visible warning would help.

- **Security lens:** CONCERN with 1 P1, 2 P2s.
  - P1: path-traversal via `ENG-*` glob in `bin/halt.sh:76`.
    Crafted `ENG-../../etc/passwd_dir` would escape `$PROJECT_STATE_DIR`.
  - P2: glob expansion when `$d` empty — needs `[[ -n "$d" ]]` guard.
  - P2: `printf` `%s`-consumption attack on stage-name interpolation.
  - Sub-MODERATE: from=to transitions are a privilege boundary
    that silently zeroes rejection counters — operator can launder
    past loopback signal. Audit string in body (D-013) addresses it.

- **Scope guardian:** PASS, no P0/P1/P2 issues. All decisions map
  to the IN list; OUT-list traps avoided.

- **Coherence:** CONCERN with 1 P0, 1 P1, 2 P2s.
  - P0: §6 chained-resume edge case is incomplete and contradicts
    the actual code path. `_vh_protocol_violation` re-applies
    pipeline:halted unconditionally — the chained flow doesn't merely
    fail, it actively *re-installs* the halt state. Q1 needs a
    decision (e.g., guard verdict_handler invocation on has-label).
  - P1: §10 "iter-1 self-PASS" framing is misleading (single-author
    self-review presented as 6/6 PASS).
  - P2: D-009 §3.3 vs §4.4 minor sketch alignment.
  - P2: test case J idempotency — real `add-comment` would dedup but
    the stub doesn't. Reframing acknowledged but worth a test-file
    callout.

- **Product lens:** CONCERN with 2 P0s, 3 P1s, 2 P2s.
  - P0: no success metric beyond "tests pass." Need a metrics.sh
    emission so the retrospective can detect re-halt regressions.
  - P0: D-009 asymmetry invisible at the CLI surface — needs a
    one-line stderr advisory when stale halt-related state coexists
    with scope-approved/scope-rejected.
  - P1: CLAUDE.md row is dense and operator-hostile (one ~70-word
    parenthetical). Split into row + bullet list.
  - P1: operator-resume comment body is mechanical, not diagnostic.
    Should list what was cleared.
  - P1: §6 chained-resume edge case is a real product problem
    (same root as Coherence P0).
  - P2: status.sh rendering of `building → building` may confuse.
  - P2: Q2 email attribution rationale conflates Linear createdBy
    with operator identity.

**Iteration 1 tally:** 2/6 PASS (Design, Scope), 4/6 CONCERN/FAIL.
**Gate P0: 1 (Coherence) + 2 (Product) = 3.** Iteration 2 required.

### Iteration 2 patches (this revision)

Resolutions applied in §2 and §3:

- **D-011 (NEW):** Skip `verdict_handler` when `pipeline:halted` is
  absent. Closes Coherence P0 + Design P1 + Product P0 (chained-flow
  re-halt).
- **D-012 (NEW):** Stderr advisory in scope-approved/scope-rejected
  paths when stale halt-related state coexists. Closes Product P0
  (D-009 invisibility).
- **D-013 (NEW):** `metrics.sh halt-resume` emission with cleared-
  state stats. Closes Product P0 (no success metric); also feeds the
  audit-string in the operator-resume comment body (closes Product
  P1 — diagnostic body).
- **D-014 (NEW):** `^ENG-[0-9]+$` validation + stage-shape
  sanitization. Closes Security P1 + P2.
- **§3.5 CLAUDE.md update reformatted** as short row + bullet list
  (closes Product P1 — dense row).
- **§3.2 helper sketch updated** with empty-issue_dir guard, has-
  label-before-remove logic so skip-label cleanup count is accurate,
  stdout audit string for D-013 capture.
- **§3.3 resolve() flow updated** with D-011 has-label guard, D-012
  observer call, D-013 metric emission, D-014 validation, audit
  string in waypoint body.
- **§3.4 test cases** extended with L (D-011), M (D-012), N (D-013),
  O + P (D-014).
- **§6 chained-resume edge case** rewritten to accurately reflect
  D-011's resolution (closes Coherence P0).
- **§7 Q1** marked RESOLVED; Q4 added (status.sh minor).
- **§10 framing** rewritten to be honest about the iteration model
  (closes Coherence P1).

### Iteration 2 (independent personas, completed)

Six personas re-reviewed the iter-2 revision. Verdicts in fixed order
(design → security → scope → coherence → product → feasibility):

- **Design lens:** PASS.
  - Iter-1 P1 (chained scope-approved → resume foot-gun) closed by
    D-011 (has-label guard before verdict_handler invocation).
  - Iter-1 sub-MODERATE (`unknown → unknown` body on degenerate
    stage-of) addressed by D-014's `current_stage="unknown"` fallback;
    operator-visible because the literal `unknown` appears in the
    waypoint body.
  - 14 decisions are individually orthogonal; the resolve() flow in
    §3.3 composes them cleanly. No circular dependencies; D-008
    ordering-rationale is sound.

- **Security lens:** PASS.
  - Iter-1 P1 (path-traversal via `ENG-*` glob) closed by D-014's
    `^ENG-[0-9]+$` regex.
  - Iter-1 P2 (`$d` empty glob expansion) closed by §3.2 helper's
    `[[ -n "$d" ]]` guard.
  - Iter-1 P2 (`printf %s`-consumption on stage interpolation) closed
    by D-014's `^[a-z]+$` stage validation + `unknown` fallback.
  - Iter-1 sub-MODERATE (rejection-counter laundering via from=to
    transitions) mitigated by D-013 audit string in waypoint body —
    the resume is auditable post-hoc; the privilege boundary is the
    operator-CLI access itself, which is unchanged from prior contract.
  - ENG-46 secret-handling: no `${VAR:-FALLBACK}` patterns introduced;
    new code uses positional args + heredoc-piped stdin only.

- **Scope guardian:** PASS (with advisory).
  - All six issue IN-list items mapped to decisions (§9).
  - All five OUT-list items respected (§9).
  - Advisory: D-012, D-013, D-014 are technically additions beyond
    the issue's literal IN-list. Each is justified by closing a
    specific iter-1 P0/P1 (Product P0 success-metric → D-013;
    Product P0 D-009 invisibility → D-012; Security P1 path-traversal
    → D-014). All three are local to halt.sh, additive, do not alter
    the IN-list contract, and respect the four-shape vocabulary.
    Net judgement: justified, not creep.

- **Coherence:** PASS.
  - Iter-1 P0 (chained-resume edge case incomplete) closed: §6 now
    accurately documents D-011's behavior; §3.3 sketch shows the
    `had_halt` tracking and the synthetic-rc=1 path explicitly.
  - Iter-1 P1 (self-PASS framing) closed: §10 now structured as
    iter-1 → iter-2 with explicit deltas and an honest "completed"
    block per iteration.
  - Iter-1 P2 (D-009 §3.3 vs §4.4 alignment) closed: §3.3 explicitly
    shows the non-resume path falling through to the
    `_observe_stale_side_state` advisory + remove-label, matching
    §4.4's narrative.
  - Iter-1 P2 (test case J idempotency stub-vs-real disparity)
    addressed: §3.4 compatibility note acknowledges the stub doesn't
    replicate dedup; assertion reframed appropriately.

- **Product lens:** PASS.
  - Iter-1 P0 (no success metric) closed by D-013 (`halt-resume`
    metrics event with reset stats).
  - Iter-1 P0 (D-009 invisibility) closed by D-012 (stderr advisory
    on scope-approved/scope-rejected when stale halt-related state
    coexists).
  - Iter-1 P1 (CLAUDE.md row dense and operator-hostile) closed in
    §3.5 (split into row + bullet list).
  - Iter-1 P1 (operator-resume body mechanical) closed by
    `_format_reset_audit` injecting "_Cleared:_ wait_files=N
    skip_labels=M state_file=B" into the waypoint body.
  - Iter-1 P1 (chained-resume edge case product impact) closed by
    D-011 + D-012 acting jointly.
  - Iter-1 P2 (status.sh rendering) tracked as Q4.
  - Iter-1 P2 (Q2 email attribution rationale) tracked; current
    decision documented as a known limitation rather than implicit.

- **Feasibility (gating):** PASS — 0 P0.
  - Codebase-fact verification table (§8.4) anchors every cited
    artifact to current `path:line`. Spot-verified the load-bearing
    facts during this review:
    - `bin/halt.sh` resume branch + case 0/1/2 (lines 29–60) ✓
    - `bin/halt.sh` PIPELINE_WRITER=human export (line 14) ✓
    - `bin/verdict-handler.sh::find_fresh_verdict` last-transition
      contains-match (lines 75–78) — substring match tolerates the
      `(operator-resume)` body suffix ✓
    - `bin/verdict-handler.sh::resume_in_progress_transition` strict
      regex (lines 276–280) — rejects the suffix cleanly via
      `[[ -z "$from" || -z "$to" ]] && return 1` ✓
    - `bin/verdict-handler.sh::_vh_protocol_violation` halt-add at
      line 58 — confirms D-011 is necessary ✓
    - `bin/guards.sh::count_marker_since_last_transition` boundary
      at lines 46–48 — same contains-match ✓
    - `bin/run-stage.sh::_handle_wait` writes wait-${stage}.json
      (line 378, 424) and budget-exhaust deletes (line 455);
      success-path delete (line 836) ✓
    - `bin/run-stage.sh::_fresh_wait_reason` build-only allow-list
      (lines 308–311) ✓
    - `bin/classify-failure.sh` issue-state.json write (lines 47, 102)
      with `.policy ∈ {retry-immediately, skip-until-code-changes,
      skip-until-human-acts}` ✓
    - `bin/poll.sh::_poll_evaluate_skip` orphan cleanup (lines 55–63),
      skip-until-* logic (lines 48–122) ✓
    - `bin/linear.sh` lane matrix lines 73–91, halt-remove allows
      orchestrator,human (line 80), skip-until remove allows
      orchestrator,classify,human (line 84), transition-comment add
      allows orchestrator,human (line 85) ✓
    - `bin/linear.sh::_classify_comment_body` regex
      `^'<!--'\ pipeline-transition:\ .+\ '-->'` (line 62) — `.+`
      tolerates the `(operator-resume)` suffix ✓
    - `bin/linear.sh::remove_label` idempotent no-op (lines 271–274) ✓
    - `bin/linear.sh::add_comment` dedup-by-hash (lines 455–487) ✓
    - `bin/halt-test.sh` source-stub + VH_RC pattern (lines 25–50) ✓
    - `bin/metrics.sh` `<event> <issue> <stage> <outcome>
      <duration_ms> [notes]` signature — D-013's call shape fits ✓
  - Implementation note for the test extension (non-blocking — to be
    handled in the implement stage, not a brainstorm-level concern):
    the existing `STUB_DIR/linear.sh` stub at `bin/halt-test.sh:25-34`
    falls through `*) exit 0` for `has-label` queries, which means
    "label present". Test cases L/M/O require `has-label` returning
    different values across cases. The implement stage will need to
    either (a) extend the stub to switch on a per-test env var (e.g.,
    `HAS_HALT_LABEL=0|1`) or (b) replace the stub between cases.
    Either approach is straightforward and within the existing
    test-pattern.
  - Minor line-citation drift (±2) on three of the verdict-handler
    citations is within normal tolerance for path:line references in
    a fast-moving codebase; the surrounding code blocks are
    semantically identical.

**Iteration 2 tally:** 6/6 PASS. Gate P0: 0. Threshold satisfied
(≥5/6 PASS AND feasibility = 0 P0). Brainstorm gate passed.

### Final status

**Iteration count:** 2 (well under the 3-iteration cap).
**Personas:** 6/6 PASS.
**Gate P0:** 0.
**Verdict:** proceed to planning.
