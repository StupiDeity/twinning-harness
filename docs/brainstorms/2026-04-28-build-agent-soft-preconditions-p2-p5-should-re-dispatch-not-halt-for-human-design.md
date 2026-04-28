---
linear: ENG-45
title: Build agent soft preconditions (P2/P5) re-dispatch instead of halt-for-human
date: 2026-04-28
status: draft
---

# Build agent: soft preconditions (P2/P5) re-dispatch, not halt-for-human

## 1. Problem

The build agent's `AGENT_PROMPTS.md` §7 P2 precondition tells the operator
that on missing Code Owner approval the agent will exit and "the orchestrator
will retry on the next tick" (`AGENT_PROMPTS.md:1070-1072`). That contract is
unimplementable under the current ENG-18 verdict-marker protocol: the
mandatory exit table at `AGENT_PROMPTS.md:1180-1192` only offers three exit
shapes — `pipeline-stage-summary` (forward), `pipeline-rejection` (loopback),
and `pipeline-halt: agent-blocked` (halt-for-human). The agent has nowhere to
say "no transition needed; ask me again next tick", so it picks
`agent-blocked` and applies `pipeline:halted`.

`bin/poll.sh::_poll_classify_labels` (line 221) then classifies any fresh
`pipeline-halt` marker as `slot=vacate, advanceable=false`, which is a hard
stop until an operator runs `bash bin/halt.sh resolve … --decision resume`.
The same pathology applies to P5 (CI green) — flaky CI runs that the agent
just `gh run rerun`-ed get halted instead of soft-retried.

### 1.1 Empirical reproduction (ENG-26, 2026-04-28)

```
08:17  build agent halts ENG-26 with <!-- pipeline-halt: agent-blocked -->
       message: "Resume by approving the PR as a non-bot reviewer; the next
                 tick will re-evaluate."
08:47  operator approves the PR on GitHub
08:47–09:14   five launchd ticks fire; orchestrator stays silent because
              pipeline:halted is still on the issue
09:14  operator runs `bash bin/halt.sh resolve ENG-26 --decision resume`
       → next tick re-dispatches build, P2 passes, merge proceeds
```

The 27-minute idle period is a direct consequence of the missing
"soft-pending" exit shape, not of any operator latency — the operator did
exactly what the halt-comment told them to do, and the orchestrator
ignored them.

### 1.2 Why the existing four-state poller already handles this

`_poll_classify_labels` (`bin/poll.sh:186-232`) already encodes four
distinct *poller-classification* outcomes from the
`(stage_label, fresh_marker, halt_label)` triple:

| Triple                                                                  | poll classification                  | Where in poll.sh             |
| ---                                                                     | ---                                  | ---                          |
| fresh `pipeline-stage-summary` + `pipeline:halted`                      | hold, advanceable (forward)          | line 220                     |
| fresh `pipeline-rejection`     + `pipeline:halted`                      | hold, advanceable (loopback)         | line 220                     |
| fresh `pipeline-halt`          + `pipeline:halted`                      | vacate (halt-for-human)              | line 222                     |
| **no fresh marker**            + **no halt label**                      | **hold, advanceable (re-dispatch)**  | **line 228 (else branch)**   |

The fourth row is the one we want for P2/P5 soft failures, but no stage
agent reaches it today because the post-dispatch defensive halt-add at
`bin/run-stage.sh:542-545` re-applies `pipeline:halted` whenever the
agent exits without it, which then forces `verdict_handler`
(`bin/run-stage.sh:555`) to either find a verdict marker or post a
`protocol-violation: no-marker` halt (`bin/verdict-handler.sh:233-237`).

### 1.3 Root cause

The poller is correctly dispatched-by-default. The blocker is the **two
orchestrator safety nets** that assume an agent exiting clean is a
contract violation:

1. `bin/run-stage.sh:477-490` — agent-contract validator that exits 25
   (retry-immediately) when the agent emits neither a stage-summary file
   nor a fresh verdict marker; `classify_failure` then unconditionally
   applies `pipeline:halted` (`bin/classify-failure.sh:117-119`).
2. `bin/run-stage.sh:542-545` — defensive `pipeline:halted` add when the
   agent forgot to apply it.

These nets exist because, before this work, "no marker" meant "agent
crashed silently". We need a deterministic way for the build agent to
say "exited intentionally; retry next tick" that bypasses both nets and
still satisfies §1.2's fourth-row triple.

## 2. Decisions

- **D-001. Add a fourth marker shape: `<!-- pipeline-wait: <reason> -->`.**
  `<reason>` ∈ a closed allow-list `{awaiting-approval, awaiting-ci}`
  (extensible only by code change in `_fresh_wait_reason`'s validator).
  The marker is **not** a verdict shape — it signals "exited
  intentionally, no transition wanted". `find_fresh_verdict`
  (`bin/verdict-handler.sh:69-127`) does NOT match it, so the verdict
  handler treats it as if no fresh verdict exists.
  *Why "wait", not "soft-pending":* per design-review P0-2, the verb
  "wait" is structurally distinct from the outcome verbs `stage-summary`,
  `rejection`, `halt` — eliminates the visual confusability that risks
  protocol drift in future stage prompts. The load-bearing reason for
  using a Linear comment (rather than a sentinel file) is **operator
  visibility in the Linear UI**: the human reading the issue page sees
  exactly what the system is waiting on, in the same comment thread as
  every other state-machine event.

  Rejected alternative: encode wait as a sentinel file under `issue_dir`
  (e.g., `wait-build.touch`). Rejected because the operator-facing
  status would not be visible without `cd $PROJECT_STATE_DIR/$ident`,
  defeating the audit trail.

  Rejected alternative: re-use `pipeline-rejection: building` with target
  `building` (self-loopback). Rejected because the loopback table
  (`bin/verdict-handler.sh:32-38`) does not include `building|building|`,
  the table is part of the ENG-18 contract, and adding self-loopbacks
  would require teaching `apply_transition` (`bin/verdict-handler.sh:138-169`)
  to skip the label-swap and the `pipeline-transition: from → to`
  waypoint — significantly more intrusive than a new non-verdict marker.

- **D-002. Sig the wait comment via `add-comment` (append-only),
  NOT `add-or-update-comment`.**
  Sig: `awaiting-external/{stage}/{issue_id}` (still in the body for
  human readability), but the comment is APPENDED on each tick, not
  edited in place.
  *Why:* per design-review and product-review P0-1, `add-or-update-comment`
  uses `commentUpdate` (`bin/linear.sh:453`), which preserves the
  original `createdAt`. Both the existing `find_fresh_verdict` freshness
  query and any new wait-marker freshness query rely on `createdAt`
  ordering newer-than-most-recent-`pipeline-transition` to identify the
  fresh marker. After any future loopback into `building` (legitimate
  or otherwise) posts a `pipeline-transition: → building` waypoint, the
  edited-in-place wait comment's `createdAt` would become older than
  the transition waypoint, and the gate would silently stop firing.

  Append-only avoids that entire class of bug at the cost of one
  comment per tick (~12/hour worst case = 144/day in the longest
  budget). The Linear UI groups consecutive comments cleanly, and the
  body is short ("Awaiting … will re-check on next tick"). The
  operator-visibility win actually *improves* with append-only: each
  tick produces a visible event with a fresh timestamp, so the
  operator can see "system is alive, here's tick 6 of 12".

  Note: this is a deviation from the Linear-issue technical hint, which
  said "deduplicated 'awaiting external signal' comment". The
  deviation is justified by a verified API-semantics bug; if comment
  spam becomes a real problem in practice, a follow-up can switch to
  `add-or-update-comment` AND change the freshness rule to use
  `updatedAt`. We pick the safer primitive for v1.

- **D-003. Two new orchestrator gates in `run-stage.sh`, both keyed on
  the wait marker, both inserted at a single new insertion point
  positioned BEFORE the agent-contract validator.**
  Insertion point: line 477, immediately before the existing
  agent-contract validator block (`bin/run-stage.sh:477-490`).
  - **Gate A:** if `_fresh_wait_reason` returns a valid reason AND
    `$stage == build`, hand off to `_handle_wait` and exit 0 (within
    budget) or fall through (budget exhausted, `_handle_wait` already
    posted halt and applied label).
  - **Gate B:** if Gate A did not fire, the existing agent-contract
    validator and defensive halt-add behave exactly as today.
  *Why:* per coherence-review P0, the previous draft placed the gate
  AFTER the agent-contract validator, which would have exited 25 on
  any wait exit (no summary file, no verdict marker). Moving the gate
  to line 477 puts it strictly upstream of every safety net it needs
  to short-circuit. Per security-review F-1, gating on `$stage == build`
  prevents cross-stage marker forgery from creating a "snooze" primitive
  on stages outside the explicit IN-scope.

- **D-004. Per-stage wait state file at
  `$(issue_dir)/wait-{stage}.json`.** Schema:
  ```json
  {
    "issue": "ENG-26",
    "stage": "build",
    "reason": "awaiting-approval",
    "attempts": 6,
    "first_attempt_at": "2026-04-28T08:17:00Z",
    "last_attempt_at": "2026-04-28T08:47:00Z"
  }
  ```
  Owned and incremented by the **orchestrator** (`run-stage.sh`), not
  the agent. The agent only posts the marker.
  *Why:* state-machine ownership — per ENG-18 the orchestrator owns
  transitions and budgets; agents emit signals. Stage-keyed filename
  prevents cross-stage interference if a different stage later adopts
  the same primitive.

  Rejected alternative: store the counter under a new
  `external_signal_attempts` field in `issue-state.json` (suggested by
  the Linear issue's Technical Hints). Rejected because
  `bin/poll.sh::_poll_evaluate_skip` deletes `issue-state.json` as an
  "orphan state file" whenever neither `pipeline:skip-until-*` label is
  present (`bin/poll.sh:55-60`). On a wait tick we have no skip label
  by design, so the counter would be wiped on every poll cycle.

  Rejected alternative: modify `_poll_evaluate_skip` to whitelist a
  new `external_signal_attempts` field and skip the orphan delete when
  only that field is present. Rejected because the brainstorm's whole
  premise is "fix is additive in `run-stage.sh`, no `poll.sh` changes"
  (§3.1); pulling `poll.sh` into the change-set widens the blast
  radius and the test surface.

- **D-005. Budget-based escalation, owned by the orchestrator, with a
  distinct halt reason.**
  When `attempts >= max_attempts` OR
  `(now - first_attempt_at) >= max_minutes`, the orchestrator:
  1. Posts an append-only
     `<!-- pipeline-halt: external-signal-budget-exhausted -->` comment
     (NEW reason, not the existing `agent-blocked`) with a body that
     includes operator-recovery instructions: "Approve the PR as a
     non-bot Code Owner, then run `bash bin/halt.sh resolve {issue}
     --decision resume`. Or raise
     `orchestrator.external_signal_budget.max_attempts` (or
     `max_minutes`) in `.pipeline-config/config.json` to extend the
     window."
     Posted via `bash bin/linear.sh add-comment` (append-only per
     `AGENT_PROMPTS.md:54`).
  2. Applies `pipeline:halted`.
  3. Deletes `wait-{stage}.json`.
  4. Continues to `verdict_handler`, which now sees the fresh halt
     marker and preserves the halt (`bin/verdict-handler.sh:271-274`).
  *Why distinct reason:* per product-review F-5, an operator skim of
  Linear comments cannot tell `agent-blocked` (first-attempt halt;
  investigate agent reasoning) from budget-exhausted (system waited
  and timed out; investigate external signal). Same marker shape
  meant identical-looking halts with different operator actions.
  `find_fresh_verdict`'s grep `pipeline-halt: [a-z-]+` already accepts
  hyphenated reasons (`bin/verdict-handler.sh:110`), so the new reason
  is a one-string change with no control-flow impact.

  *Why orchestrator-owned:* AC-4 (budget escalation), and consistent
  with ENG-18's separation between agent-emitted signals and
  orchestrator-owned state transitions.

- **D-006. New configuration key:
  `config.json::orchestrator.external_signal_budget`.**
  Default `{"max_attempts": 12, "max_minutes": 60}` (per Linear issue
  AC-4 and Technical Hints). `null`/missing/`{}` means "no limit, retry
  forever" (operator opt-out for long-running CI farms).
  Read via `config_get '.orchestrator.external_signal_budget.max_attempts'`
  (`bin/common.sh:191-194`).
  *Why:* AC-4 explicitly mandates "configurable via
  `config.json::orchestrator.external_signal_budget`"; this is in
  the IN list. Keeping the issue's stated default for v1; see Open
  Question Q3 (default may need to grow to 8h based on operator habits).

- **D-007. P5 (CI green) shares the wait path with P2.**
  Same marker, same sig, same counter. Reason field distinguishes:
  `awaiting-ci` vs `awaiting-approval`. The agent's separate `gh run rerun`
  retries (capped at 2 per the existing P5 prose, `AGENT_PROMPTS.md:1086-1088`)
  are independent of `attempts` — once the agent has burned both
  reruns and CI is still red, that is the existing hard-fail path
  (`gh run rerun --failed` exhausted) and continues to halt-for-human;
  it is not a wait case.
  *Why:* AC-5; collapses two near-identical flows.

- **D-008. Explicit non-changes (scope discipline).**
  - Operator workflow: `bin/halt.sh resolve` is unchanged.
  - Poller classification (`_poll_classify_labels`): unchanged. The
    `else` branch at `bin/poll.sh:228` already returns
    `slot=hold, advanceable=true`; that's exactly what we exploit.
  - Verdict handler tables (`_VH_FORWARD_TRANSITIONS`,
    `_VH_LOOPBACK_TRANSITIONS`): unchanged.
  - Lane fence (`bin/linear.sh::_lane_decision`): unchanged. The
    agent lane is already permitted to `add other_comment` and
    `add pipeline_halted`. *Lane-fence-impact note (per security
    F-6):* Gate B's skip of the defensive halt-add is functionally
    equivalent to an agent-driven `remove pipeline_halted` (since the
    operator just cleared the halt and the orchestrator now refrains
    from re-applying it). This is acceptable because the operator
    cleared the halt deliberately and a fresh wait counter starts;
    the agent itself never calls `remove-label`.
  - Other stages' soft preconditions (review CODEOWNERS, qa flake
    re-runs): out of scope per Linear issue. Pattern is reusable but
    not generalized in this ticket.

## 3. Architecture

### 3.1 Files modified

| File                         | Change                                                                                       |
| ---                          | ---                                                                                          |
| `AGENT_PROMPTS.md`           | §7 (build): rewrite P2/P5 failure paths to post the `pipeline-wait` marker, with explicit "only after P1, P3, P4, P6, P7 all pass" precondition-ordering clause. |
| `AGENT_PROMPTS.md`           | "Verdict-marker protocol" preamble: add a "non-verdict markers" subsection after the verdict table that documents `pipeline-wait` separately so it cannot be confused with a verdict shape. |
| `bin/run-stage.sh`           | Add `_fresh_wait_reason` helper (closed allow-list of reasons, build-only stage gate).        |
| `bin/run-stage.sh`           | Add `_handle_wait` helper that increments the counter, escalates on budget exhaust, with explicit `PIPELINE_WRITER=orchestrator` for all Linear writes inside it. |
| `bin/run-stage.sh`           | Insert wait-detection block at line 477 (BEFORE the agent-contract validator), short-circuiting on success.  |
| `bin/run-stage.sh`           | Success-path cleanup (line ~574): also `rm -f wait-{stage}.json` on stage success.           |
| `bin/run-stage-test.sh`      | New cases: P2-only wait exit; budget exhaustion; success clears counter; cross-stage forgery rejected; build-only gate; reason allow-list. |
| `bin/run-stage-test.sh`      | Unit tests for `_fresh_wait_reason` (allow-list pass/reject, build-only gate, get-comments failure read-side fail-closed). |
| `bin/poll-slot-test.sh`      | New case: `stage:building`, no halt, no fresh verdict (only a `pipeline-wait` marker present) → `hold, advanceable=true`. |
| `bin/verdict-handler-test.sh`| Regression case: `find_fresh_verdict` returns empty when only a `pipeline-wait` marker is present (must NOT match). |

No changes required to `bin/poll.sh`, `bin/verdict-handler.sh`,
`bin/classify-failure.sh`, `bin/linear.sh`. The fix is additive in
`run-stage.sh` and `AGENT_PROMPTS.md`.

### 3.2 New helpers (sketches, both in `bin/run-stage.sh`)

**`_fresh_wait_reason`** — returns the reason string on stdout (and
exit 0) if a fresh, well-formed, build-only `pipeline-wait` marker
exists; else returns empty + nonzero. Bullet contracts (matching
security F-1, F-2 and design P0-1):

```bash
_fresh_wait_reason() {
  local issue="$1" stage="$2"
  # Build-only gate (security F-1). Out-of-scope stages cannot use this.
  [[ "$stage" == "build" ]] || return 1

  local comments
  comments="$(bash "$SCRIPT_DIR/linear.sh" get-comments "$issue" 2>/dev/null)" || return 1
  [[ -z "$comments" || "$comments" == "null" ]] && return 1

  # Use createdAt (consistent with find_fresh_verdict). Safe here only
  # because D-002 mandates append-only posting — each tick gets a fresh
  # createdAt timestamp, so the latest comment IS the one this tick
  # posted. Edit-in-place would have broken this; we picked add-comment
  # specifically to keep the freshness query simple.
  local last_t; last_t="$(jq -r '
    [.[] | select(.body | contains("<!-- pipeline-transition:"))]
    | sort_by(.createdAt) | last | .createdAt // ""' <<<"$comments")"
  local fresh; fresh="$(jq -r --arg t "$last_t" '
    [.[] | select(.createdAt > $t)
         | select(.body | test("<!-- pipeline-wait: "))]
    | sort_by(.createdAt) | last // empty | .body // ""' <<<"$comments")"
  [[ -z "$fresh" ]] && return 1

  local reason
  reason="$(grep -oE '<!-- pipeline-wait: [a-z-]+ -->' <<<"$fresh" \
    | head -1 | sed -E 's/<!-- pipeline-wait: ([a-z-]+) -->/\1/')"

  # Closed reason allow-list (security F-2). Anything else is treated
  # as protocol violation by the absence of a fresh wait marker:
  # caller falls through to the existing agent-contract validator,
  # which fires exit 25 + halt as today.
  case "$reason" in
    awaiting-approval|awaiting-ci) printf '%s' "$reason"; return 0 ;;
    *) return 1 ;;
  esac
}
```

**`_handle_wait`** — idempotent counter mutation + budget check.
Returns 0 = within budget, no halt (caller exits 0). Returns 1 =
budget exhausted, halt was applied (caller falls through to metrics
and verdict_handler, which preserves the halt). All Linear writes
inside the function use an explicit `PIPELINE_WRITER=orchestrator`
(security F-4).

```bash
_handle_wait() {
  local PIPELINE_WRITER=orchestrator
  export PIPELINE_WRITER

  local ident="$1" stage="$2" reason="$3"
  local f="$(issue_dir "$ident")/wait-${stage}.json"
  local now; now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # Soft-pending detected — clear any stale stage-summary file for this
  # stage so a later post_completion_comment cannot post stale content.
  rm -f "$(issue_dir "$ident")/stage-summary-${stage}.md" 2>/dev/null || true

  # Read prior state defensively (coherence P2 — JSON validation guard).
  local first attempts
  if [[ -s "$f" ]] && jq -e . "$f" >/dev/null 2>&1; then
    first="$(jq -r '.first_attempt_at // ""' "$f")"
    attempts="$(jq -r '.attempts // 0' "$f")"
    # Field-validity guard (security F-3): regex-validate first_attempt_at
    # before feeding it to date -j -f. An attacker-controlled value (e.g.,
    # crafted file written via the agent's Write tool) cannot reach the
    # arithmetic substitution.
    if [[ ! "$first" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
      first="$now"; attempts=0
    fi
    [[ "$attempts" =~ ^[0-9]+$ ]] || attempts=0
    attempts=$((attempts + 1))
  else
    first="$now"; attempts=1
  fi

  # Atomic write.
  local body
  body="$(jq -cn --arg i "$ident" --arg s "$stage" --arg r "$reason" \
                --arg fa "$first" --arg la "$now" --argjson n "$attempts" '
    {issue:$i, stage:$s, reason:$r, attempts:$n,
     first_attempt_at:$fa, last_attempt_at:$la}')"
  local tmp="${f}.tmp.$$"; printf '%s' "$body" > "$tmp"; mv -f "$tmp" "$f"

  # Read budget. config_get returns the literal "null" on explicit-null
  # values; jq's // empty already collapses missing keys, but explicit
  # null still passes through, so we strip it explicitly.
  local max_a max_m
  max_a="$(config_get '.orchestrator.external_signal_budget.max_attempts // empty')"
  max_m="$(config_get '.orchestrator.external_signal_budget.max_minutes  // empty')"
  [[ "$max_a" == "null" ]] && max_a=""
  [[ "$max_m" == "null" ]] && max_m=""

  local exhausted=0
  [[ -n "$max_a" && "$max_a" =~ ^[0-9]+$ ]] && (( attempts >= max_a )) && exhausted=1
  if [[ -n "$max_m" && "$max_m" =~ ^[0-9]+$ ]]; then
    local first_epoch elapsed_m
    first_epoch="$(date -j -f %Y-%m-%dT%H:%M:%SZ "$first" +%s 2>/dev/null || printf '')"
    if [[ -n "$first_epoch" ]]; then
      elapsed_m=$(( ($(date -u +%s) - first_epoch) / 60 ))
      (( elapsed_m < 0 )) && elapsed_m=0   # clock-skew guard (§5)
      (( elapsed_m >= max_m )) && exhausted=1
    fi
  fi

  if (( exhausted )); then
    local halt_body
    halt_body="$(printf '<!-- pipeline-halt: external-signal-budget-exhausted -->\n\nBuild stage halted: %s budget exhausted (%d attempts since %s).\n\n**Resume:** approve the PR as a non-bot Code Owner, then run `bash bin/halt.sh resolve %s --decision resume`. Or raise `orchestrator.external_signal_budget.max_attempts` / `max_minutes` in `.pipeline-config/config.json` to extend the window.' \
                "$reason" "$attempts" "$first" "$ident")"
    bash "$SCRIPT_DIR/linear.sh" add-comment "$ident" "$halt_body" || true
    bash "$SCRIPT_DIR/linear.sh" add-label   "$ident" "pipeline:halted" || true
    rm -f "$f"
    return 1
  fi
  return 0
}
```

### 3.3 Insertion point in `run-stage.sh::main`

**Insert at line 477**, immediately BEFORE the agent-contract
validator block (which spans lines 477-490). The new block:

```bash
# ENG-45: wait exit. Build agent posts pipeline-wait on P2/P5 failures
# so the orchestrator re-dispatches next tick instead of halting.
# Detect BEFORE the agent-contract validator, defensive halt-add, and
# verdict_handler — all three of which would otherwise trip on a
# legitimate wait exit (no summary file, no verdict marker).
if (( ! skip_dispatch )); then
  local _sp_reason
  _sp_reason="$(_fresh_wait_reason "$ident" "$stage" 2>/dev/null || printf '')"
  if [[ -n "$_sp_reason" ]]; then
    if _handle_wait "$ident" "$stage" "$_sp_reason"; then
      bash "$SCRIPT_DIR/metrics.sh" stage-end "$ident" "$stage" "soft-pending" \
        "$(( ($(date +%s) - t0) * 1000 ))" "reason=$_sp_reason"
      log "stage $stage wait on $ident (reason=$_sp_reason)"
      exit 0
    fi
    # Budget exhausted: pipeline:halted was applied by _handle_wait.
    # Fall through to defensive halt-add (now a no-op, label already set)
    # and verdict_handler, which preserves the halt and emits
    # halt-for-human metrics naturally.
  fi
fi
# Existing agent-contract validator block follows at original line 477.
```

The agent-contract validator (`bin/run-stage.sh:477-490`) is **not
modified**. With the wait detection running upstream, a wait exit
short-circuits before the validator can fire; if the wait gate did
not fire (no marker, malformed reason, or wrong stage), the validator
runs unchanged.

The defensive halt-add (`bin/run-stage.sh:542-545`) is also **not
modified**. On a within-budget wait exit, the orchestrator already
exited 0 above. On a budget-exhausted exit, `_handle_wait` already
applied `pipeline:halted`, so the defensive add is a no-op.

### 3.4 Build agent prompt (AGENT_PROMPTS.md §7) — exact replacement

**Precondition-ordering clause (NEW; per design P1-1 and security F-1):**
prepend to the §7 P2 spec:

> If P1, P3, P4, P6, or P7 fail, post the existing hard-halt marker
> (`pipeline-halt: agent-blocked`) and exit. The wait path below applies
> ONLY when every other precondition has passed and the only failure is
> P2 or P5.

Current (`AGENT_PROMPTS.md:1067-1072`):

> P2. **Review was approved by a non-bot Code Owner** ... If this returns
> false, the PR is not ready; do NOT merge. Post a Linear comment noting
> "awaiting human Code Owner approval" and exit. The orchestrator will
> retry on the next tick.

Replacement:

> P2. **Review was approved by a non-bot Code Owner** ... If this returns
> false, the PR is not ready; do NOT merge. Confirm P1, P3, P4, P6, P7
> all passed (otherwise halt-for-human, see precondition-ordering clause
> above).
> **Wait exit:** post (via `add-comment`, append-only) a comment whose
> first line is exactly `<!-- pipeline-wait: awaiting-approval -->` and
> whose body says: "Awaiting human Code Owner approval. Will re-check on
> next tick. After roughly 60 minutes (~12 ticks at default budget)
> without approval, will escalate to halt-for-human." Do NOT apply
> `pipeline:halted`. Do NOT post a verdict marker. Do NOT write a
> stage-summary file. Exit. The orchestrator increments a per-issue
> counter and re-dispatches build on the next tick; once the budget is
> exhausted it escalates to
> `pipeline-halt: external-signal-budget-exhausted` automatically.

Same change for P5 (`AGENT_PROMPTS.md:1082-1088`), with reason
`awaiting-ci`. The existing `gh run rerun --failed` rerun cap (2)
remains as-is — it is an in-tick retry, not a between-tick wait.

The exit-shape table at `AGENT_PROMPTS.md:1180-1192` gets a fourth row:

| outcome | marker shape | comment posting |
| ---     | ---          | ---             |
| merged + green CI | `<!-- pipeline-stage-summary: building -->` | `add-comment` |
| conflict / CI red (hard) | `<!-- pipeline-rejection: building --><!-- pipeline-rejection-target: implementing -->` | `add-comment` |
| missing approval / WIP / etc. (hard halt) | `<!-- pipeline-halt: agent-blocked -->` | `add-comment` |
| **awaiting external signal (P2 OR P5 only, all hard preconditions passed)** | **`<!-- pipeline-wait: awaiting-approval -->`** or **`awaiting-ci`** (NOT a verdict shape — see "Non-verdict markers" below) | `add-comment` (append-only — see D-002) |

The Verdict-marker protocol preamble (`AGENT_PROMPTS.md:38-54`) gets a
new "**Non-verdict markers**" subsection added immediately after the
verdict table:

> Non-verdict markers communicate state OTHER than a stage outcome and
> are NOT consumed by `verdict-handler.sh`. They are read by the
> orchestrator's per-stage gates in `run-stage.sh`.
>
> | Marker | Who posts | When | Meaning |
> |---|---|---|---|
> | `<!-- pipeline-wait: <reason> -->` | build agent only | external-signal precondition unmet (P2/P5) | exit clean; orchestrator re-dispatches next tick until budget exhausts |

## 4. Data flow

### 4.1 Happy path (within budget, approval lands)

```
launchd tick N
  poll.sh
    → ENG-26 has stage:building, no halt, no fresh marker
    → _poll_classify_labels else branch (poll.sh:228) → hold, advanceable=true
    → emit decision: (ENG-26, build, run)

run-stage.sh ENG-26 build
  → render-prompt.sh + dispatch.sh → build agent runs P1..P7
  → P1, P3, P4, P6, P7 pass; P5 OK; P2 fails (no non-bot approval)
  → agent posts add-comment with body starting:
    <!-- pipeline-wait: awaiting-approval -->
    Awaiting human Code Owner approval. Will re-check on next tick...
  → agent exits 0; no halt label, no verdict marker, no stage-summary file

run-stage.sh post-dispatch (NEW logic at line 477):
  → _fresh_wait_reason "ENG-26" "build" → "awaiting-approval"
  → _handle_wait writes wait-build.json {attempts:1, ...}
  → returns 0 (within 12-attempt / 60-minute budget)
  → metrics outcome=soft-pending; exit 0

launchd tick N+1 (5 min later)
  poll.sh
    → ENG-26 still stage:building, no halt, fresh comment is the
      pipeline-wait one, but find_fresh_verdict's grep matches only
      the three verdict shapes (verdict-handler.sh:100-114). pipeline-wait
      is not in that set, so find_fresh_verdict returns empty.
    → _poll_classify_labels else branch (poll.sh:228) → hold, advanceable=true
  → re-dispatch build, agent runs again, posts NEW append-only wait
    comment with fresh createdAt, _handle_wait increments attempts to 2

(operator approves PR at tick N+5)

launchd tick N+6
  build agent runs; P2 passes; merge proceeds; success path
  → run-stage.sh:574 cleanup deletes wait-build.json AND issue-state.json
```

### 4.2 What the operator sees in Linear during the wait window

During the wait window, the issue page shows one append-only `pipeline-wait`
comment per tick, each with a fresh `createdAt` so the operator sees a
visible "system is alive, here's tick 6/12" trail. The body explicitly
names the 60-minute budget; the operator can compute their own deadline.

A worked example (12 ticks at 5-minute spacing = ~60 min):
- 08:17 — first wait comment posted by build agent
- 08:22, 08:27, 08:32, 08:37, 08:42 — five more wait comments (operator
  sees "tick 2/12 ... tick 6/12", each comment a fresh entry)
- 08:47 — operator approves PR; tick at 08:47 dispatches build,
  P2 passes, merge proceeds; wait comments stop appearing

If the operator approves at 08:30 (mid-window), the next tick at 08:32
sees P2 pass and merges; no escalation comment is posted.

The append-only design (D-002) is what makes "system is alive" visible.
An edit-in-place would silently update one comment 12 times with no
notification; an operator skim would see one stale comment that looks
abandoned.

### 4.3 Budget-exhaustion path (approval never lands)

```
tick N+12 (~60 min after first wait)
  build agent runs; P2 still fails; agent posts wait marker
  run-stage.sh _handle_wait:
    → reads wait-build.json {attempts: 11}, increments to 12
    → max_attempts=12 reached → exhausted=1
    → posts append-only halt:
      <!-- pipeline-halt: external-signal-budget-exhausted -->
      Build stage halted: awaiting-approval budget exhausted (12 attempts
      since 2026-04-28T08:17:00Z).

      Resume: approve the PR as a non-bot Code Owner, then run
      `bash bin/halt.sh resolve ENG-26 --decision resume`. Or raise
      orchestrator.external_signal_budget.max_attempts / max_minutes...
    → applies pipeline:halted
    → rm -f wait-build.json
    → returns 1
  run-stage.sh falls through:
    → defensive halt-add: pipeline:halted already present, no-op
    → verdict_handler: finds fresh halt marker → preserves halt (line 271-274)
  → metrics outcome=halt-for-human

launchd tick N+13
  poll.sh _poll_classify_labels: pipeline:halted + fresh halt marker
  → line 222 vacate, advanceable=false (today's halt-for-human path)
  → operator unblocks via halt.sh resolve as today
```

### 4.4 Operator manually clears `pipeline:halted` after escalation

```
operator approves PR + clears pipeline:halted
launchd tick N+14
  poll.sh: stage:building, no halt, last fresh comment is the
    external-signal-budget-exhausted halt, but find_fresh_verdict's
    freshness rule treats only markers newer-than-last-pipeline-transition
    as fresh, AND _poll_classify_labels' fresh-verdict branch is only
    entered when pipeline:halted is set (which the operator just cleared)
  → else branch (poll.sh:228) → hold, advanceable=true
  → re-dispatch build, runs P1..P7
  P2 passes (operator approved), merge proceeds; clean
  OR P2 still fails → fresh wait cycle starts (counter at 1, since
    wait-build.json was deleted at escalation time per §4.3)
```

This is the desired behavior — operator clearing the halt label is an
implicit "give it another window".

## 5. Error handling

- **Linear API failure when posting the wait comment.** The agent uses
  `add-comment` which returns nonzero on failure. If the marker isn't
  posted, the orchestrator's `_fresh_wait_reason` returns empty, and
  the existing agent-contract validator path fires — exit 25,
  retry-immediately, classify_failure halts. The operator gets the
  standard halt comment. Graceful degradation: a network blip on
  Linear cannot create a forever-loop.

- **Linear API failure when *reading* comments (`linear.sh get-comments`).**
  Per design P2-2, the read path needs explicit treatment. `_fresh_wait_reason`
  handles this by treating any nonzero exit OR empty output from
  `get-comments` as "no fresh wait marker" → return 1 → fall through
  to the agent-contract validator → exit 25 → halt. Net effect: a
  Linear read blip costs one extra cycle of halt-and-resume but cannot
  silently mask a real wait state. (This is a fail-closed semantic;
  fail-open would risk infinite loops on persistent network issues.)

- **Concurrent dispatch on the same issue.** The harness already enforces
  global single-flight via the `.claude-mutex.lock/` directory
  (`CLAUDE.md:172`). Two ticks cannot race the same issue's dispatch.
  The state file's atomic write (`mv -f tmp dst`) is redundant but cheap.

- **Clock-skew on `first_attempt_at`.** `_handle_wait` parses the
  ISO-8601 timestamp via BSD `date -j -f %Y-%m-%dT%H:%M:%SZ`. If the
  host clock jumps backwards, `elapsed_m` could underflow. Guard
  inline at `(( elapsed_m < 0 )) && elapsed_m=0` (already in §3.2 sketch).

- **Corrupt or attacker-controlled `wait-build.json`.** `_handle_wait`
  validates `first_attempt_at` against
  `^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$` before
  feeding it to `date -j -f`. `attempts` is validated against
  `^[0-9]+$`. The whole-file `jq -e . "$f"` syntax check catches
  invalid JSON. Any guard failure resets `first` to `now` and
  `attempts` to 0 — i.e., treat as a brand-new wait window. Per
  security F-3, an agent that crafts the file with `first=1970…` cannot
  trick the budget into immediate exhaustion.

- **Operator manually clears `pipeline:halted` after escalation.** See §4.4.

- **Stage-drift during a wait dispatch.** The existing stage-drift guard
  (`bin/run-stage.sh:514-537`) fires AFTER the new wait gate (which is
  at line 477), so a wait exit short-circuits before drift detection.
  If something transitioned the issue out of `stage:building` mid-dispatch,
  the wait branch is never entered. The counter file persists on disk
  and would be re-read on the next dispatch back into building, which
  may be wrong (counter from a prior cycle). Mitigation: success-path
  cleanup at line ~574 `rm -f wait-{stage}.json`, AND any forward/loopback
  transition through `verdict_handler` followed by a successful next
  dispatch will eventually clear it.

## 6. Edge cases

- **A wait marker posted on a stage other than build.** `_fresh_wait_reason`
  rejects this via the `[[ "$stage" == "build" ]] || return 1` gate
  (security F-1). Out-of-stage markers fall through to the existing
  agent-contract validator and halt as today. The other-stages opt-in
  is OUT of scope per the Linear issue; this gate enforces it.

- **An invented or empty reason (e.g., `pipeline-wait: never-escalate`
  or `pipeline-wait: ` or empty body).** `_fresh_wait_reason`'s closed
  allow-list (`{awaiting-approval, awaiting-ci}`) rejects anything else
  (security F-2). Falls through to halt as today.

- **Mixed soft + hard precondition failures (e.g., P2 missing AND P3
  CHANGES_REQUESTED).** P3 is a hard fail. The §3.4 prompt rewrite makes
  the ordering explicit: "Wait path applies ONLY when every other
  precondition has passed and the only failure is P2 or P5." If both
  P2 and P3 fail, the agent posts the existing hard-halt marker, not
  a wait marker.

- **Two consecutive wait ticks where the reason changes** (tick N
  reason = `awaiting-ci`; tick N+1 the CI passed but a separate
  approval-staleness invalidated the prior approval, reason =
  `awaiting-approval`). `_handle_wait` keys the JSON file by stage,
  not by reason; the `attempts` counter survives the reason change.
  Correct: budget is per (issue, stage), not per (issue, stage, reason).
  A separate counter per reason would let the agent flip-flop forever
  between two "fresh" buckets.

- **`config.json::orchestrator.external_signal_budget` set to `null`
  or `{}` (operator opt-out).** §3.2 sketches the explicit
  `[[ "$max_a" == "null" ]] && max_a=""` guard plus the `^[0-9]+$`
  numeric check. An explicit-null config means "no limit, retry forever".

- **Agent posts wait marker AND a halt marker in the same dispatch
  (security F-5: marker masking).** `_fresh_wait_reason` returns the
  latest fresh wait marker; if the agent posted halt AFTER wait, the
  halt is the freshest verdict marker and `verdict_handler` would
  preserve it next tick. If the agent posted wait AFTER halt, the
  wait gate fires and the halt marker is effectively ignored for
  this tick — equivalent to the agent overriding its own halt
  request. Documented behavior: the latest marker wins per the ENG-18
  freshness rule; benign for well-behaved agents and bounded-impact
  for buggy ones (next halt, or budget exhaustion, both close the
  loop).

- **Stale stage-summary file from a prior dispatch left in `issue_dir`.**
  `_handle_wait` does `rm -f $(issue_dir)/stage-summary-${stage}.md` at
  the start of wait handling (§3.2 sketch) so subsequent ticks start
  with a clean slate. (Per scope review P1, the parallel cleanup at
  the success path was originally proposed but is a separate latent
  bug independent of ENG-45 — out of scope for this ticket; the
  inside-`_handle_wait` cleanup is sufficient for the wait flow.)

## 7. Open questions

- **Q1.** Operator-facing text: §3.4 captures the new prose. No further
  question.

- **Q2.** Metrics outcome name `soft-pending`. Decision: new outcome name,
  passed as a literal string to `metrics.sh stage-end` (matches the
  existing `success`/`halt-for-human` convention at
  `run-stage.sh:571,588,593`). Need to verify the retrospective §1
  filter handles a new outcome name without silently dropping events;
  this is on the implementation TODO list (run-retrospective-local.sh
  inspection during the implementation stage).

- **Q3 (raised by product review F-3).** Default `max_minutes=60` is
  shorter than a typical commute. Operator approving from their phone
  while at lunch may return to a halted issue. Considered raising the
  default to `max_minutes=480` (8h, "next morning") with `max_attempts`
  unchanged at 12 — but K=12 would still exhaust at ~60 min (12 × 5min
  ticks). Either AC-4's K=12 must yield to the wall-clock cap, OR the
  attempts cap stays the load-bearing budget and 60 min is the de
  facto deadline. **Decision for v1:** keep `{max_attempts: 12,
  max_minutes: 60}` per the Linear issue's Technical Hints; if operator
  pain recurs in practice, raise both proportionally (e.g.,
  `{max_attempts: 96, max_minutes: 480}` for an 8h window). Operator
  can override per-installation via `config.json` today.

- **Q4 (success metric, raised by product review F-4).** The bug fix is
  observable in `events.jsonl` as: a sequence of one or more
  `outcome=soft-pending` events on `stage=build` for an issue,
  followed by an `outcome=success` event on the same stage, with NO
  intervening `outcome=halt-for-human` event. The retrospective should
  count "issues whose build merge happened on a tick following at
  least one soft-pending event, with no operator halt-resolve in
  between" — explicit win condition. This wiring is a follow-up but
  the primitive (`outcome=soft-pending` literal) lands here.

- **Q5 (scope drift, raised by product review F-6).** The "pipeline-wait
  fourth-marker" framing is more general than the bug fix. Decision:
  ship narrow (build-only gate per security F-1; closed reason
  allow-list per F-2). If review/qa later want the same primitive,
  the next ticket loosens the gate and adds reasons.

## 8. Anti-bias checks

### 8.1 ADR stress test

There is no existing ADR file at `docs/knowledge/decisions.md` in this
repository (the harness has no `docs/knowledge/` directory; this
brainstorm prompt was templated for the Twinning target). The closest
analogues are the prior brainstorms under `docs/brainstorms/`:

- `2026-04-22-pipeline-state-machine-formalization-design.md` (ENG-18,
  the verdict-marker protocol). This change adds a fourth marker shape
  and explicitly carves it out of the verdict vocabulary — it widens
  the protocol surface but does not violate any ENG-18 invariant. The
  freshness rule, the append-only verdict rule, and the
  orchestrator-owned-transitions rule are all preserved.
- `2026-04-27-pipeline-trust-model-enforce-write-lanes-design.md`
  (ENG-41, the lane fence). This change requires no fence change: the
  agent lane already permits `add other_comment` and `add pipeline_halted`,
  and the new orchestrator helpers explicitly export
  `PIPELINE_WRITER=orchestrator`. The Gate-B-as-functional-halt-removal
  case is documented in D-008.
- `2026-04-28-eng-42-reframe-implement-pr-guard-design.md` (ENG-42).
  Same family of "halt was the wrong primitive for this signal" finding;
  this is consistent.

Tradeoff surfaced: the new marker shape adds one more thing for an
agent author to know about, and one more pattern for a reader to
internalize. We accept this because (a) the marker uses a
structurally-distinct verb ("wait" vs the verdict verbs
"stage-summary"/"rejection"/"halt"), and (b) the Linear-comment
visibility is the load-bearing design requirement (the operator
needs to see what the system is waiting on without reading code).

### 8.2 Simpler alternatives considered

Documented inline at D-001 (sentinel file, self-loopback) and D-004
(reuse `issue-state.json`, modify poll.sh's orphan rule). The
strictly-simpler alternative — "delete the post-dispatch defensive
halt-add at run-stage.sh:542-545 entirely and let agents always emit
a fresh marker" — was rejected because the defensive halt-add catches
real silent-crash exits (an agent that segfaults after partial writes)
and downgrading to "no halt" on those would orphan issues silently.
The teach-and-skip gate in D-003 is the smallest change that preserves
the safety net.

### 8.3 Assumption inventory

| Assumption | Status | Evidence / Action |
| ---        | ---    | ---               |
| `bin/poll.sh::_poll_classify_labels` else branch (line 228) returns `slot=hold, advanceable=true` for an issue with `stage:building`, no halt label, no fresh marker | **verified** | `bin/poll.sh:204-229`. |
| `find_fresh_verdict` recognizes only three marker shapes and would NOT match a `pipeline-wait` body | **verified** | `bin/verdict-handler.sh:83-91` (jq `contains` on `pipeline-stage-summary`, `pipeline-rejection`, `pipeline-halt`); 100-118 (cascading `grep -qE` only matches those three). |
| `bin/run-stage.sh:542-545` defensively re-applies `pipeline:halted` whenever the agent forgot to | **verified** | `bin/run-stage.sh:542-545`. |
| `bin/run-stage.sh:477-490` agent-contract validator exits 25 when both stage-summary file and verdict marker are absent — and is reached only after the new wait gate has not fired | **verified post-fix** | The new gate is positioned at line 477 BEFORE the existing validator. With the wait gate firing first, the validator's reachability is unchanged for non-wait exits; for wait exits the validator never runs. (Coherence P1 / 8.3 update.) |
| `bin/classify-failure.sh` always applies `pipeline:halted` regardless of policy | **verified** | `bin/classify-failure.sh:117-119`. |
| `bin/poll.sh::_poll_evaluate_skip` deletes `issue-state.json` when neither `pipeline:skip-until-*` label is present | **verified** | `bin/poll.sh:55-60`. This is why D-004 uses a separate file. |
| `bin/linear.sh::_lane_decision` row `add other_comment` returns `allow` for the `agent` lane | **verified** | `bin/linear.sh:82` ("add other_comment") printf 'allow' (all lanes). |
| `bin/linear.sh::_lane_decision` row `add pipeline_halted` returns `allow` for the `agent` lane | **verified** | `bin/linear.sh:75`. |
| `bin/linear.sh::add_or_update_comment` uses `commentUpdate` and preserves `createdAt` (motivates D-002 append-only choice) | **verified** | `bin/linear.sh:423-465`; line 453 invokes `commentUpdate(id: $id, input: { body: $body })` — `createdAt` is not in the input, Linear preserves it on update. |
| `config_get` is a thin `jq -r` wrapper | **verified** | `bin/common.sh:191-194`. |
| `~/.pipeline-config/config.json::orchestrator` exists and currently holds `{paused, max_concurrent_features, alert_on_halted_over}` | **verified** | `~/code/twinning-harness/.pipeline-config/config.json` (`jq '.orchestrator'`). |
| `AGENT_PROMPTS.md` §7 P2 prose at lines 1067-1072 currently advertises orchestrator auto-retry | **verified** | `AGENT_PROMPTS.md:1070-1072`. |
| `AGENT_PROMPTS.md` §7 P5 prose at lines 1082-1088 includes a `gh run rerun --failed` cap of 2 | **verified** | `AGENT_PROMPTS.md:1086-1088`. |
| `AGENT_PROMPTS.md` §7 verdict-marker exit table at lines 1180-1191 | **verified** | `AGENT_PROMPTS.md:1180-1192`. |
| `bin/verdict-handler.sh::find_fresh_verdict` uses freshness rule "newer than the most recent `<!-- pipeline-transition: -->` comment" | **verified** | `bin/verdict-handler.sh:75-91`. The new `_fresh_wait_reason` reuses this rule, which is safe specifically because D-002 mandates append-only posting. |
| `bin/verdict-handler.sh::find_fresh_verdict`'s `pipeline-halt` regex is `pipeline-halt: [a-z-]+` (accepts hyphenated reasons like `external-signal-budget-exhausted`) | **verified** | `bin/verdict-handler.sh:110-113`. |
| `bin/run-stage.sh:574-585` success path `rm -f issue-state.json` and removes skip labels | **verified** | `bin/run-stage.sh:574-577`. The proposed `rm -f wait-{stage}.json` gets added at the same site. |
| `bin/dispatch.sh::allowed_tools_for` for `build` permits the bash subset needed to call `linear.sh add-comment` | **verified** | `bin/dispatch.sh:136` already lists `Bash(bash .pipeline/bin/linear.sh:*)` in the build profile. No dispatch-lane change needed during implementation. |
| Tests source `bin/run-stage.sh` via the sentinel pattern (`if [[ "${BASH_SOURCE[0]}" == "${0}" ]]`) | **verified** | `bin/run-stage.sh:600-602`. |
| BSD `date -j -f %Y-%m-%dT%H:%M:%SZ` parses ISO-8601 on macOS (the launchd host) | **verified** | Standard BSD date flag set; `date -u +%Y-%m-%dT%H:%M:%SZ` is already used at `bin/classify-failure.sh:79` for the same format. |
| `bin/poll.sh::_poll_evaluate_skip` does NOT need to know about `wait-{stage}.json` | **verified** | `_poll_evaluate_skip` only reads `issue-state.json`; the new file is invisible to it. |
| Retrospective §1 filter accepts a new metric outcome string (`soft-pending`) without silent-drop | **assumed** | Verify in `bin/run-retrospective-local.sh` or whichever script consumes `events.jsonl`. Listed as Open Question Q2 / implementation TODO. |

### 8.4 Codebase-fact verification (mandatory)

Every named code artifact in this brainstorm is grounded in the
current repo:

| Name | Quoted location |
| ---  | ---             |
| `bin/poll.sh::_poll_classify_labels` | `bin/poll.sh:186-232` |
| `bin/poll.sh::_poll_evaluate_skip` | `bin/poll.sh:45-116` |
| `_poll_classify_labels` else branch (soft-redispatch) | `bin/poll.sh:227-229` |
| `bin/poll.sh:228` (the `slot=hold, advanceable=true` literal) | `bin/poll.sh:228` |
| `bin/verdict-handler.sh::find_fresh_verdict` | `bin/verdict-handler.sh:69-127` |
| `bin/verdict-handler.sh::apply_transition` | `bin/verdict-handler.sh:138-169` |
| `_VH_FORWARD_TRANSITIONS` | `bin/verdict-handler.sh:19-27` |
| `_VH_LOOPBACK_TRANSITIONS` | `bin/verdict-handler.sh:32-38` |
| `pipeline-halt` branch in `verdict_handler` | `bin/verdict-handler.sh:271-274` |
| `pipeline-halt` reason regex `[a-z-]+` (accepts new reason names) | `bin/verdict-handler.sh:110-113` |
| `_vh_protocol_violation "no-marker"` | `bin/verdict-handler.sh:233-237` |
| `bin/run-stage.sh:477-490` agent-contract validator | `bin/run-stage.sh:477-490` |
| `bin/run-stage.sh:496-500` push_branch_if_ahead call | `bin/run-stage.sh:496-500` |
| `bin/run-stage.sh:504-512` post_completion_comment call | `bin/run-stage.sh:504-512` |
| `bin/run-stage.sh:514-537` stage-drift guard | `bin/run-stage.sh:514-537` |
| `bin/run-stage.sh:542-545` defensive halt-add | `bin/run-stage.sh:542-545` |
| `bin/run-stage.sh:555` verdict_handler call | `bin/run-stage.sh:555` |
| `bin/run-stage.sh:574-585` success cleanup | `bin/run-stage.sh:574-585` |
| `bin/classify-failure.sh::classify_failure` | `bin/classify-failure.sh:39-159` |
| `bin/classify-failure.sh:117-119` (unconditional `pipeline:halted` apply) | `bin/classify-failure.sh:117-119` |
| `bin/linear.sh::_lane_decision` | `bin/linear.sh:69-87` |
| `bin/linear.sh::add_or_update_comment` (uses `commentUpdate`) | `bin/linear.sh:423-465` (line 453 = `mutation … commentUpdate`) |
| `bin/linear.sh::add-comment` (uses `commentCreate`) | `bin/linear.sh:459-462` (in `add_or_update_comment`) and the standalone `add_comment` function in the same file. |
| `bin/common.sh::config_get` | `bin/common.sh:191-194` |
| `bin/common.sh` ISO-8601 timestamp format usage | `bin/classify-failure.sh:79` (`date -u +%Y-%m-%dT%H:%M:%SZ`). |
| `AGENT_PROMPTS.md` §7 P2 prose | `AGENT_PROMPTS.md:1067-1072` |
| `AGENT_PROMPTS.md` §7 P5 prose | `AGENT_PROMPTS.md:1082-1088` |
| `AGENT_PROMPTS.md` §7 verdict-marker exit table | `AGENT_PROMPTS.md:1180-1192` |
| `AGENT_PROMPTS.md` Verdict-marker protocol preamble | `AGENT_PROMPTS.md:38-54` |
| `~/.pipeline-config/config.json::orchestrator` block | verified via `jq '.orchestrator' ~/code/twinning-harness/.pipeline-config/config.json` |

No referenced item is non-existent or speculative; each is anchored to
a path:line pair in the worktree at
`/Users/rajatgoyal/.local/state/twinning-harness/harness/ENG-45/worktree/`.

## 9. Scope check vs Linear issue

The Linear issue's IN list:

- ✅ Build agent prompt: split P2/P5 from halt-for-human (D-007, §3.4).
- ✅ Deduplicated `awaiting-external/build/{issue}` comment — **deviation
  documented in D-002**: the brainstorm uses append-only (`add-comment`)
  rather than `add-or-update-comment` because the latter's
  `commentUpdate`-preserves-`createdAt` semantics breaks the freshness
  query. The sig is still in the body for human readability.
- ✅ Re-dispatch budget with attempts + wall-clock cap (D-005, D-006).
- ✅ Tests for wait exit, poller hold-advanceable classification,
  budget exhaustion escalation, and P6 regression (§3.1 test rows).

Note on the Linear issue's hint that the counter live "in
`issue-state.json` under a new `external_signal_attempts` field": the
brainstorm chose a separate file (D-004) because `_poll_evaluate_skip`
deletes `issue-state.json` on every wait tick (no skip label present).
This is a correctness deviation from the hint, justified by the verified
poll.sh:55-60 cleanup behavior.

The Linear issue's OUT list:

- ✅ No generalization to review CODEOWNERS or qa flake re-runs (D-008,
  enforced in code by the build-only gate in `_fresh_wait_reason`).
- ✅ `bin/halt.sh resolve` workflow unchanged (D-008).
- ✅ No orchestrator polling of GitHub PR state (D-008 — agent's own
  re-run is the polling mechanism).
- ✅ No generalization of the sig pattern beyond `awaiting-external`.

No scope sprawl detected. The change is isolated to: one prompt
section (§7 build agent), the verdict-marker preamble (one new
"Non-verdict markers" subsection), two helper functions in
`run-stage.sh`, three test files, and one config-key default. No
changes to `bin/poll.sh`, `bin/verdict-handler.sh`,
`bin/classify-failure.sh`, `bin/linear.sh`.

## 10. Persona review

Iteration 1 results (5 of 6 personas; feasibility runs after this
iteration):

- **Coherence (round 1):** FAIL. 1 P0 — insertion order contradiction
  between §3.1 (validator extension) and §3.3 (insertion after
  validator). Fixed in iteration 2: gate inserted at line 477 BEFORE
  the agent-contract validator (D-003); §3.3 explicit. Variable name
  drift (`_sp_reason` vs `_fresh_soft_pending`) cleaned up — single
  helper name `_fresh_wait_reason`, single var name `_sp_reason`.
  Stage-summary cleanup row added to §3.1. Assumption 8.3 row
  rewritten to reflect post-fix reachability.

- **Design lens (round 1):** CONCERN. 2 P0s and 5 P1s.
  - P0-1 `add-or-update-comment` createdAt freshness bug → fixed in
    iteration 2 via D-002 (append-only `add-comment`).
  - P0-2 marker structurally similar to verdict shapes → fixed via
    rename `pipeline-soft-pending` → `pipeline-wait` (verb category
    distinct from outcome verbs) and a dedicated "Non-verdict markers"
    subsection in the preamble.
  - P1 prompt precondition-ordering ambiguity → fixed in §3.4 with
    explicit "applies ONLY when every other precondition has passed".
  - P1 budget-exhaustion comment lacked operator-recovery instructions
    → fixed in D-005 with explicit recovery body.
  - P1 "what does Linear show" → added §4.2.
  - P1 retrospective filter assumption → tracked as Assumption 8.3
    "assumed" + Open Question Q2.
  - P1 read-side `linear.sh get-comments` failure → §5 explicit
    fail-closed semantic.

- **Security lens (round 1):** CONCERN. 0 P0s, 7 findings.
  - F-1 cross-stage forgery → build-only gate in `_fresh_wait_reason`
    (D-001, §3.2 sketch).
  - F-2 closed reason allow-list → §3.2 sketch case statement.
  - F-3 timestamp regex validation before `date -j -f` → §3.2 sketch.
  - F-4 explicit `PIPELINE_WRITER=orchestrator` → §3.2 sketch.
  - F-5 marker masking → documented in §6.
  - F-6 functional halt-removal-by-omission → documented in D-008.
  - F-7 explicit insertion order → §3.3 explicit (gate at line 477).

- **Scope guardian (round 1):** CONCERN. 2 P1s, 3 P2s.
  - P1 stale stage-summary success-path cleanup is a different bug
    → dropped; only the inside-`_handle_wait` cleanup retained.
  - P1 §10 ADR ceremony → dropped (the ADR section is removed; the
    decision rationale lives in D-001..D-008).
  - P2 D-004 third alternative ("modify poll.sh's orphan rule") →
    added to D-004's rejected list.
  - P2 D-001 rationale tightened — operator visibility is the
    load-bearing reason.
  - P2 D-006 hardcoded constants — kept config key per AC-4 mandate;
    documented as Q3 deferred concern.

- **Product lens (round 1):** CONCERN. 1 P0, 4 P1s, 2 P2s.
  - P0 (same as Design P0-1) → fixed via D-002 append-only.
  - P1 D-006 gold-plating → kept per AC-4; flagged as Q5 scope-narrow
    follow-up.
  - P1 60min default too short → kept per Linear hint; flagged as Q3
    "raise both proportionally if operator pain recurs".
  - P1 success metric implicit → made explicit in Q4 (a sequence of
    `outcome=soft-pending` events followed by `outcome=success` with
    no intervening `outcome=halt-for-human`).
  - P1 budget-exhaustion halt indistinguishable from agent-blocked →
    distinct reason `external-signal-budget-exhausted` (D-005).
  - P2 fourth-marker scope drift → kept (build-only gate scopes it).
  - P2 inversion scenarios → §6 covers the documented edge cases.

- **Feasibility lens (round 1, post-iteration):** PASS, 0 P0
  findings. Verified every path:line citation in §8.4 against the
  current worktree; verified `add-or-update-comment` uses
  `commentUpdate` at `bin/linear.sh:453`; verified
  `find_fresh_verdict`'s `pipeline-halt: [a-z-]+` regex accepts
  `external-signal-budget-exhausted`; verified `bin/dispatch.sh:136`
  for build already permits `Bash(bash .pipeline/bin/linear.sh:*)`;
  verified BSD `date -j -f` parses the chosen ISO-8601 format on
  the harness host; verified `bin/metrics.sh stage-end` accepts
  arbitrary outcome strings (no allow-list); verified `skip_dispatch`,
  `t0`, `stage`, `ident` are all in scope at line 477. Two minor P2
  citation drifts and one assumption-row downgrade fixed inline.

- **Coherence (round 2):** PASS. All eight round-1 findings resolved.
- **Design lens (round 2):** PASS. All seven round-1 findings resolved.
- **Security lens (round 2):** PASS. All seven round-1 findings
  resolved; one sub-MODERATE F-8 (operator-disclosure / Linear comment
  spam) tracked as a non-gating observation.
- **Scope guardian (round 2):** PASS. All five round-1 findings
  resolved.
- **Product lens (round 2):** PASS. All seven round-1 findings either
  resolved or consciously accepted with documented tripwires (Q3, Q5).

**Final tally: 6/6 PASS, gate P0 = 0.** Proceeding to planning.
