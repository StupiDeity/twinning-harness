---
linear: ENG-78
title: classify-failure writes policy=retry-immediately but the same call applies pipeline:halted — poll.sh then skips the issue, dead-ending the retry
date: 2026-05-08
status: draft
---

# `classify_failure` paints `pipeline:halted` over every retry-immediately exit — fix the apply-site, not the readers

## 1. Overview (and the load-bearing surprise)

`bin/classify-failure.sh::classify_failure` (verified at
`bin/classify-failure.sh:39-159` in this worktree at the time of
writing) is the shared entry point every dispatch-failure exit in
`run-stage.sh` calls (verified at `bin/run-stage.sh:678, 755, 768,
794, 809, 814, 900, 906, 983, 1006`). Three sites pass policy
`retry-immediately` — the dispatch-failure arm at
`bin/run-stage.sh:813-818` (any non-zero exit not already classified
as one of the typed error arms 124/22/26/13), the agent-contract
validator at `bin/run-stage.sh:982-986` (no stage-summary file AND no
fresh verdict marker), and the post-completion-comment-failure arm
at `bin/run-stage.sh:1004-1009`. All three are *transient* by
design: a 529 Overloaded from Anthropic, a Linear post that fails on
the first try, an agent that exited 0 without an artifact (often a
JSON-parse race in stream capture). `retry-immediately`'s explicit
contract — visible in `failure_outcome_for_exit`'s policy taxonomy
(`bin/common.sh:107-130`) and in the auto-escalation logic at
`bin/classify-failure.sh:67-77` — is "next tick re-dispatches; if
the same evidence (pipeline_content_hash + branch_head_sha)
reproduces the failure twice more, escalate to
`skip-until-code-changes`."

```bash
# bin/classify-failure.sh:117-119  (verified)
# ENG-18: every policy outcome is a halt surface from the Verdict
# Handler's perspective; apply the sentinel label unconditionally.
bash "$_CFS_SCRIPT_DIR/linear.sh" add-label "$issue" "pipeline:halted" || true
```

```bash
# bin/classify-failure.sh:140-142  (verified)
retry-immediately)
  comment_body+="pipeline will retry automatically on the next tick."
  ;;
```

The unconditional `add-label "pipeline:halted"` and the
"will retry automatically" comment-body branch coexist in the same
function call. The next reader downstream is
`bin/poll.sh::_poll_classify_labels` (verified at
`bin/poll.sh:217-233`):

```bash
# bin/poll.sh:217-233  (verified)
elif [[ "$(_has_label pipeline:halted)" == "true" ]]; then
  local fresh
  fresh="$(find_fresh_verdict "$ident" 2>/dev/null || printf '')"
  if [[ -z "$fresh" ]]; then
    class='{"slot":"hold","advanceable":false}'
  else
    local marker
    marker="$(jq -r '.marker // ""' <<<"$fresh")"
    case "$marker" in
      pipeline-stage-summary|pipeline-rejection)
        class='{"slot":"hold","advanceable":true}' ;;
      pipeline-halt)
        class='{"slot":"vacate","advanceable":false}' ;;
      *)
        class='{"slot":"hold","advanceable":false}' ;;
    esac
  fi
```

`classify_failure` posts a `<!-- pipeline: verdict result=halt
reason=agent-failure -->` marker at `bin/classify-failure.sh:124-132`
(verified — `marker_reason="agent-failure"` for non-skip-human
policies, including retry-immediately). `find_fresh_verdict` returns
that marker shape as `pipeline-halt` (verified at
`bin/verdict-handler.sh:138`). `_poll_classify_labels`'s `pipeline-halt`
arm sets `slot:"vacate"`. The held-slot loop in `bin/poll.sh:442-448`
then calls `verdict_handler`, which for a `pipeline-halt` marker
returns 1 ("leave halt intact") at `bin/verdict-handler.sh:396-398`.
Slot is vacated; no dispatch fires; the issue idles forever.

**The load-bearing surprise.** This is not just dead code in a
narrow path. Every dispatched stage routes its transient-failure
exits through `classify_failure`, and EVERY one of those exits paints
on `pipeline:halted` — including the three sites whose explicit
contract is "transient, retry next tick." The `policy` field in
`issue-state.json` is the orchestrator's only durable retry-tracking
mechanism (the `retry_count` auto-escalation at
`bin/classify-failure.sh:67-77` reads it on every classify call), but
no downstream reader honors it for `retry-immediately` while the halt
label is on. ENG-68 demonstrated the failure mode: a 529 Overloaded
on a build dispatch at 2026-05-07T12:11:20Z applied
`policy=retry-immediately` + `pipeline:halted` in a single call and
the issue idled until 2026-05-07T17:30Z (~5 hours), zero retries,
zero progress. The exact transient API outage `retry-immediately`
exists to handle is the case the harness silently fails on.

The Linear comment posted at `bin/classify-failure.sh:140-142`
("**Resume:** pipeline will retry automatically on the next tick.")
is verifiably false under current behavior — the operator reads
"will retry automatically" and waits, but `poll.sh` skips the issue
on every subsequent tick. The contradiction was visible in the
operator-facing UI itself.

This brainstorm picks Path A from the issue's "Proposed fixes" list
and refines it to encompass three coupled changes (D-001, D-002,
D-003) plus a regression pin (D-004). Path B (poll.sh reads
`issue-state.json` and dispatches halted retry-immediately issues)
is simpler in line count but muddies halt-label semantics for every
other reader (status.sh, retrospective, the operator's mental
model). Path C (classify-failure auto-clears the halt label after
applying it) is race-prone and rejected by the issue itself.

**Why three coupled decisions, not one.** Reverting only the
halt-label apply (D-001) without changing the marker shape (D-002)
leaves a `<!-- pipeline: verdict result=halt -->` comment on every
retry-immediately tick — semantically a halt verdict with no halt
label. Other readers (status.sh's halt count, retrospective's
halt-sprawl analysis, future verdict-handler refactors) would treat
the marker as a real halt event. Reverting D-001 + D-002 without
preserving the state file in poll.sh (D-003) loses the
`retry_count` auto-escalation evidence between ticks: poll.sh's
`_poll_evaluate_skip` (verified at `bin/poll.sh:57-64`) deletes any
`issue-state.json` that exists without an accompanying skip label,
so the next failure starts fresh from `retry_count=0` and never
escalates. The three together encode "retry-immediately is a
non-halt, retry-tracked state" coherently across the failure-apply
site, the marker shape, and the reader.

## 2. Goals

**G-1 (primary).** When `classify_failure` is called with
`base_policy=retry-immediately` AND the auto-escalation guard at
`bin/classify-failure.sh:67-77` does NOT escalate (i.e.,
`effective_policy` stays `retry-immediately`), `pipeline:halted` is
NOT applied. The next `poll.sh` tick must dispatch the same
(issue, stage) again, exactly as the policy name promises.

**G-2.** When `effective_policy` escalates to `skip-until-code-changes`
(after `retry_count >= 2` with same-evidence retries), the existing
behavior is preserved verbatim: `pipeline:halted` IS applied, the
`pipeline:skip-until-code-changes` label IS applied, the halt-shape
verdict marker IS posted with `reason=agent-failure`. This is the
escape valve for non-transient retries and must continue to halt for
operator visibility.

**G-3.** When `base_policy=skip-until-human-acts` (the SEVERE-scope,
dispatch-timeout, transcript-violation paths at
`bin/run-stage.sh:678, 755, 768, 794, 809, 900`),
`pipeline:halted` IS applied verbatim. The human-in-loop contract
must not regress.

**G-4.** Operator visibility for retry-immediately attempts is
preserved: a single dedup-keyed Linear comment shows "transient
failure: attempt N of 2 before escalation; last error: ...". The
comment is `<!-- meta: ... -->` shape so it does NOT register as a
halt verdict in `find_fresh_verdict` and does NOT count toward the
halt-sprawl threshold (`_poll_emit_halt_sprawl_alert` at
`bin/poll.sh:317-376`).

**G-5.** The `retry_count` auto-escalation at
`bin/classify-failure.sh:67-77` must continue to fire correctly across
ticks. This requires `bin/poll.sh::_poll_evaluate_skip` to NOT
delete `issue-state.json` when its `policy=retry-immediately` and no
skip label is present.

**G-6.** No regression in the halt-sprawl alert (`bin/poll.sh:317-376`):
issues that are *actually* halted continue to count; transient-retry
issues do not pollute the count.

**Non-goals (deferred).** Retry-loop budget cap beyond the existing
`retry_count >= 2` auto-escalation. Generalizing "transient-with-
self-resume" to other policies. Refactoring the marker registry
(`bin/pipeline-events.json`) to add a non-halt failure verdict.
Tightening the breaker's `consecutive-failures` interaction with
retry-immediately exits (separate ticket if the
`auto-escalate-then-trip-breaker` interaction proves problematic
in practice — see §10 O-3).

## 3. Architectural principle

Three CLAUDE.md / ENG-history constraints govern this design.

**A-1. CLAUDE.md "Doing tasks" §: don't add features beyond what the
task requires; bug fix doesn't need surrounding cleanup.** D-001+D-002
are the two-line semantic fix the issue describes; D-003 is the
hidden coupling that makes D-001 actually function across ticks
(without it, `retry_count` resets to 0 every tick and auto-escalation
is dead). D-004 is the regression pin. No new abstractions, no new
config keys, no new verdict shapes, no orphan-cleanup overhaul.

**A-2. CLAUDE.md "Linear conventions" §: mutate labels additively;
never reach for save_issue.** Both decisions modify behavior at the
call sites that already use `bin/linear.sh add-label /
remove-label`. No new code paths into Linear's GraphQL surface; no
shape changes to existing labels.

**A-3. ENG-18 (orchestrator-owned transitions; halt-label as a
sentinel for "operator decision needed")** + **ENG-56
(orchestrator-canonical halt applier; ENG-56 made `_post_dispatch_apply_halt`
idempotent and wait-shape-aware).** ENG-18 established that
`pipeline:halted` is a *halt* signal, not a *failure* signal. The
existing `bin/classify-failure.sh:117-119` comment ("every policy
outcome is a halt surface from the Verdict Handler's perspective")
overstates ENG-18's intent: ENG-18 said *halt-shape verdict markers*
are halt surfaces, not that every classify-failure exit is one. The
`retry-immediately` policy is the explicit non-halt failure path.
D-001+D-002 walk the apply site back into ENG-18's stated semantics;
ENG-56 is unaffected (the orchestrator is still the canonical
applier of `pipeline:halted` — it just stops applying it where the
policy taxonomy says not to).

**A-4. CLAUDE.md "Per-issue state directory" §: `issue-state.json` is
the durable state for the skip-label dance.** D-003 stretches that
contract slightly: `issue-state.json` is also the durable state for
`retry-immediately` retry tracking. The stretch is coherent — both
cases are "orchestrator-owned per-issue state read on every tick to
decide poll behavior," and `_poll_evaluate_skip`'s orphan cleanup
is what reads it today. The CLAUDE.md doc string at line 214 needs
a one-line edit to say "skip-label dance OR retry tracking."

## 4. Decisions

### D-001: Gate `pipeline:halted` apply on effective_policy in classify-failure

**Verdict.** In `bin/classify-failure.sh`, replace the unconditional
add-label at lines 117-119 with a `case` branch keyed on
`effective_policy`:

```bash
# bin/classify-failure.sh — replace 117-119 with:
# ENG-78: only the halt-policy branches apply pipeline:halted.
# retry-immediately is the explicit non-halt failure path — poll.sh
# re-dispatches automatically on the next tick. The auto-escalation
# guard at lines 67-77 will flip effective_policy to
# skip-until-code-changes after `retry_count >= 2` same-evidence
# retries; that branch DOES apply the halt label below.
case "$effective_policy" in
  skip-until-code-changes|skip-until-human-acts)
    bash "$_CFS_SCRIPT_DIR/linear.sh" add-label "$issue" "pipeline:halted" || true
    ;;
  retry-immediately)
    : # no halt; orchestrator re-dispatches next tick (ENG-78)
    ;;
esac
```

The existing skip-label dance at lines 105-115 already branches on
`effective_policy` — D-001 just extends the same dispatch pattern to
the halt label. Net diff: ~7 lines (3 deletions, ~10 additions
including comment). No new functions, no new config.

**Why.** This is the literal interpretation of the issue's
recommended Path A: "encodes the policy semantically at the apply
site, no race, no extra readers." The auto-escalation logic at
`bin/classify-failure.sh:67-77` is verified to flip
`effective_policy` to `skip-until-code-changes` on the third
same-evidence retry; D-001 inherits that escape valve for free —
when the policy escalates, the halt label fires via the
`skip-until-code-changes` arm. No new retry-budget logic; no new
config knob; the existing 2-retry escalation cap is reused as the
boundary.

The "every policy outcome is a halt surface" comment at line 117 is
historically incorrect — see A-3 above. D-001's replacement comment
cites ENG-78 as the corrigendum.

**Verified facts the decision relies on:**

- `bin/classify-failure.sh:67-77` flips `effective_policy` from
  `retry-immediately` to `skip-until-code-changes` when
  `prior_policy == "retry-immediately"`, evidence matches,
  `retry_count >= 2`. Verified by reading the function and the
  matching unit test cases at `bin/classify-failure-test.sh:107-114`
  (case-4: "retry-immediately same-SHA at 3rd hit escalates to
  skip-until-code-changes").
- `bin/run-stage.sh:813-818` is the dispatch-failure arm that calls
  `classify_failure ... retry-immediately ... 20`. Verified.
- `bin/run-stage.sh:982-986` is the agent-contract-missing arm that
  calls `classify_failure ... retry-immediately ... 25`. Verified.
- `bin/run-stage.sh:1004-1009` is the
  `post_completion_comment`-failure arm that calls
  `classify_failure ... retry-immediately ... 24`. Verified.
- run-stage.sh exits with rc=20/24/25 BEFORE reaching the
  post-dispatch hook `_post_dispatch_apply_halt` at
  `bin/run-stage.sh:1036`, so D-001 is the only halt-apply site
  on the failure path. Verified by reading the control flow:
  the failure arms at lines 813-818, 983-986, 1006-1009 each end
  in `exit 20|25|24`.

**Rejected alternative — Path B: read `issue-state.json` in
`poll.sh`'s held-slot halted branch and dispatch on
`policy=retry-immediately`.** The Linear issue offers this as a
fallback ("5-line poll.sh change"). It is. But it leaves the halt
label applied while the issue is *not* halting, which other readers
treat as a real halt: `_poll_emit_halt_sprawl_alert` at
`bin/poll.sh:317-376` would count every transient-retry issue
toward the configured threshold (G-6 regression);
`bin/status.sh`'s halt-count display would mislead the operator
the same way the misleading comment does today. Path B fixes the
symptom (issue stays dispatchable) while preserving the cause (the
label is wrong). D-001 fixes the cause. Rejected on coherence
grounds.

**Rejected alternative — Path C: classify-failure removes the halt
label after applying it for retry-immediately.** Race-prone
(another caller could observe the label between apply and remove);
introduces a transient state machine with no benefit; the issue
itself flags the smell ("Smell: race-prone if run-stage.sh applies
the label AFTER classify-failure runs"). Rejected.

**Rejected alternative — leave the apply unconditional but add a
new poll.sh code path that detects retry-immediately + halt and
issues a dispatch.** This is Path B with extra steps — same
coherence problem (halt label still on the issue while it's
dispatching) plus more code. Rejected.

### D-002: Replace the halt-shape verdict marker with a `<!-- meta: ... -->` comment for retry-immediately

**Verdict.** In `bin/classify-failure.sh`, the halt-comment block at
lines 121-146 currently posts a single `add-or-update-comment`
under sig `halt/$stage/$issue` with body containing
`<!-- pipeline: verdict result=halt reason=<reason> -->` and a
"**Resume:**" footer that branches on policy. Split this into two
shapes:

```bash
# bin/classify-failure.sh — replace 121-146 with:
case "$effective_policy" in
  skip-until-code-changes|skip-until-human-acts)
    # Halt-shape verdict marker, identical to today.
    local sig="halt/$stage/$issue"
    local marker_reason
    case "$effective_policy" in
      skip-until-human-acts) marker_reason="agent-blocked" ;;
      *)                     marker_reason="agent-failure" ;;
    esac
    local comment_body
    comment_body="$(printf '<!-- pipeline: verdict result=halt reason=%s -->\n\nPipeline: `%s` stage halted — %s\n\n**Policy:** %s\n**Recorded at:** %s\n**Branch:** %s\n**Retry count:** %d\n\n**Resume:** ' \
      "$marker_reason" "$stage" "$effective_reason" "$effective_policy" "$recorded_at" "${branch:-none}" "$retry_count")"
    case "$effective_policy" in
      skip-until-code-changes)
        comment_body+="$(printf 'auto-resumes when `.pipeline/{bin,config.json,AGENT_PROMPTS.md}` content hash OR `origin/%s` HEAD changes, OR when `pipeline:skip-until-code-changes` label is removed.' "${branch:-<branch>}")"
        ;;
      skip-until-human-acts)
        comment_body+="remove the \`pipeline:skip-until-human-acts\` label when the underlying issue is resolved."
        ;;
    esac
    comment_body+="$(printf '\n\n**Evidence:**\n- pipeline_content_hash: `%s`\n- branch_head_sha: `%s`\n' "$current_hash" "${current_sha:-<none>}")"
    bash "$_CFS_SCRIPT_DIR/linear.sh" add-or-update-comment "$sig" "$issue" "$comment_body" || true
    ;;
  retry-immediately)
    # Meta-shape "retry-pending" comment under a distinct sig so an
    # auto-escalation tick later (effective_policy → skip-until-code-changes)
    # creates a NEW halt comment with its OWN createdAt, rather than
    # overwriting this one in place. (ENG-63 fix made update-in-place
    # advance updatedAt via the reapplied footer, but createdAt is
    # what find_fresh_verdict reads — a fresh halt should have its own
    # createdAt for forensics.)
    local sig="retry-pending/$stage/$issue"
    local comment_body
    comment_body="$(printf '<!-- meta: metric name=transient-retry stage=%s attempt=%d -->\n\nPipeline: transient `%s`-stage failure — %s\n\n**Status:** retry-pending (attempt %d of 2 before auto-escalation to `skip-until-code-changes`).\n**Recorded at:** %s\n**Branch:** %s\n\nThe pipeline will re-dispatch this stage on the next tick. If the same evidence reproduces this failure %d more time(s), the orchestrator will halt the issue with `pipeline:skip-until-code-changes` for operator visibility.\n\n**Evidence:**\n- pipeline_content_hash: `%s`\n- branch_head_sha: `%s`\n' \
      "$stage" "$retry_count" "$stage" "$effective_reason" "$retry_count" "$recorded_at" "${branch:-none}" "$((2 - retry_count))" "$current_hash" "${current_sha:-<none>}")"
    bash "$_CFS_SCRIPT_DIR/linear.sh" add-or-update-comment "$sig" "$issue" "$comment_body" || true
    ;;
esac
```

**Why.** Three reasons.

(1) **Coherence with verdict-handler readers.** A
`<!-- pipeline: verdict result=halt -->` marker is a halt verdict.
The closed verdict vocabulary in `bin/pipeline-events.json` lists
`halt` among `verdict_results` (verified at the file's
`verdict_results` array). Posting the marker without applying the
halt label produces a state where `find_fresh_verdict` returns a
`pipeline-halt` shape (verified at `bin/verdict-handler.sh:138`)
on a non-halted issue. The current poll.sh halted branch
(`bin/poll.sh:217-233`) is gated on the *label*, so this is
harmless in practice today — but a future refactor that reads the
marker without checking the label first would re-introduce the
ENG-78 bug. Posting a `<!-- meta: metric ... -->` shape is what
`bin/common.sh::parse_pipeline_marker` (verified at
`bin/common.sh:185-260`) treats as bookkeeping (event:"meta", kind:"metric")
and `find_fresh_verdict` skips at line 110 (`event != "verdict"`).

(2) **Operator-facing comment text matches reality.** The current
text "pipeline will retry automatically on the next tick" is true
under D-001 — but the surrounding "**halted** — agent-failure"
header contradicts itself. The retry-pending body is unambiguous
and includes the attempt counter, so the operator can see "this
has retried 1 of 2 times" without grepping the state file.

(3) **Distinct sigs for distinct events.** Path B (the rejected
alternative for D-001) would have kept the same `halt/$stage/$issue`
sig across retry-pending and final-halt. With separate sigs
(`retry-pending/$stage/$issue` vs `halt/$stage/$issue`), the
auto-escalation tick that flips to `skip-until-code-changes`
creates a brand-new halt comment with its own `createdAt`, instead
of an in-place update on a comment whose `createdAt` reflects the
*first* retry-immediately attempt. This is the ENG-63 lesson
(verified at `docs/brainstorms/2026-05-04-eng-63-...`): identical-
body re-applies are invisible to operators; even with the
reapplied-footer fix at `bin/linear.sh:582-606`, `createdAt` is
still preserved on update, so a fresh halt event deserves a fresh
comment for forensics.

**Verified facts:**

- `bin/common.sh::parse_pipeline_marker` (lines 185-260) returns
  `{event:"meta", kind:"metric", ...}` for
  `<!-- meta: metric ... -->` and `find_fresh_verdict` filters
  to `event == "verdict"` only at `bin/verdict-handler.sh:111`.
  Verified.
- `bin/linear.sh::add_or_update_comment` matches by sig embedded in
  the body (verified at `bin/linear.sh:574-579`: searches comment
  bodies for the sig marker via `contains($m) or contains($l)`).
  Different sigs → different comments → distinct createdAt.
  Verified.
- The closed registry at `bin/pipeline-events.json` lists `metric`
  in `meta_kinds`. Verified by reading the file.

**Rejected alternative — keep the halt-shape marker, just gate the
label.** Argued in §1 ("Why three coupled decisions, not one"): a
halt marker without a halt label survives today (label-gated
readers don't fire) but breaks any future reader that looks at
markers first. Rejected on defense-in-depth grounds.

**Rejected alternative — post no comment at all for retry-immediately
(metric event only).** The `bin/metrics.sh stage-end` call at
`bin/classify-failure.sh:155-157` already lands an
`outcome=dispatch-failed` row in `events.jsonl`. But the operator
read of the retrospective is daily-or-weekly; for live triage they
look at the Linear thread. A meta-shape comment costs one Linear
write per retry (idempotent overwrite via dedup) and is worth the
visibility. Rejected on operator-experience grounds.

**Rejected alternative — emit a new verdict result `transient` and
register it in `bin/pipeline-events.json`.** Adds a state to the
closed vocabulary every reader has to learn. The two-shape
discipline (verdict OR meta) is the simpler boundary; meta is
exactly the right shape for an informational counter. Rejected on
A-1 grounds (don't add a feature beyond what the task requires).

### D-003: Preserve `issue-state.json` in `_poll_evaluate_skip` when policy=retry-immediately

**Verdict.** In `bin/poll.sh`, replace the orphan-state cleanup at
lines 57-64 with a policy-aware variant:

```bash
# bin/poll.sh — replace 57-64 with:
# No skip label AND no state file → normal eligible candidate.
if [[ "$has_code_label" != "true" && "$has_human_label" != "true" ]]; then
  if [[ -f "$state_file" ]]; then
    # ENG-78: a state file with policy=retry-immediately is NOT
    # orphan — it's the durable retry-tracking record that
    # classify_failure's auto-escalation guard reads on every tick
    # to compute retry_count. Removing it would reset the counter
    # to 0 each tick and break the 2-retry escalation cap. Only
    # delete state files whose policy is genuinely orphaned (the
    # original use case: human removed a skip label without
    # removing the file).
    local cur_policy
    cur_policy="$(jq -r '.policy // ""' "$state_file" 2>/dev/null || true)"
    if [[ "$cur_policy" == "retry-immediately" ]]; then
      log "poll: keeping retry-immediately state for $ident (active retry tracking, ENG-78)"
    else
      log "poll: orphan state file for $ident (no skip label, policy=$cur_policy); removing"
      rm -f "$state_file"
    fi
  fi
  return 0
fi
```

**Why.** Without D-003, D-001+D-002 are functionally broken across
ticks. The flow:

- Tick 1: dispatch fails. `classify_failure` writes
  `issue-state.json` with policy=retry-immediately,
  retry_count=0. D-001: no halt label.
- Tick 2: `_poll_evaluate_skip` runs. has_code_label=false,
  has_human_label=false. Without D-003, the state file is deleted
  as orphan. `classify_failure` on Tick 2's failure reads
  `prior_policy=""` (file gone), so the auto-escalation guard at
  `bin/classify-failure.sh:69-77` doesn't fire. retry_count
  written as 0 again.
- Tick N: still retry_count=0. Never escalates. The 2-retry cap
  is dead code.

D-003 closes that gap minimally — one `jq -r '.policy'` read and a
branch. The state file remains "orphan" from the perspective of
*skip-label* state, but is preserved as *retry-tracking* state.

**Verified facts:**

- `bin/poll.sh:48-63` is the orphan-cleanup site that deletes
  `issue-state.json` when no skip label is present. Verified.
- `bin/classify-failure.sh:60-65` reads prior_policy / prior_hash /
  prior_sha / prior_count from the state file on every call.
  Verified.
- `bin/classify-failure.sh:67-77` auto-escalation requires
  `prior_policy == "retry-immediately"` to fire. Verified.
- `bin/run-stage.sh:1081-1084` clears `issue-state.json` and
  `wait-${stage}.json` and the skip labels on a successful
  transition. So a successful run still cleans up the
  retry-immediately state file — D-003 only changes the *poll-
  loop-orphan* path, not the *successful-run* cleanup.
  Verified.
- `bin/pipeline.sh::_pipeline_drain_issue_state` (lines 207-226)
  removes `issue-state.json` only when policy=skip-until-human-acts
  on `decide --action continue`. retry-immediately state is
  preserved across operator continues; this is intentional because
  the retry tracking should survive a manual resume (the
  escalation cap is per-failure-stretch, not per-operator-action).
  D-003 inherits this semantic. Verified.

**Rejected alternative — preserve the state file unconditionally
when no skip label is present.** Loses the orphan-cleanup property
that the original code put there for a reason: a human who
manually removed a skip label without `pipeline.sh decide
--action continue` would leak `issue-state.json` files forever.
Path B's "minimal change" is one if-branch, not a wholesale
loosening. Rejected.

**Rejected alternative — require `retry-immediately` state to live
in a separate file (e.g., `retry-${stage}.json`).** Mirrors the
`wait-${stage}.json` pattern at `bin/run-stage.sh:492`. Cleaner
separation, but adds a fourth state file in the per-issue dir, a
new path in `pipeline.sh decide`, and a new field in the
retrospective. The current `issue-state.json` *is* the durable
state for failure-classification (per CLAUDE.md line 214); the
file is already correctly scoped. Rejected on A-1 grounds.

### D-004: Regression-pin tests at three levels

**Verdict.** Three new test cases, all in existing test files.

**D-004a: classify-failure-test.sh** — extend the linear.sh stub at
lines 22-28 to capture invocations (mirroring the metrics.sh
capture-stub pattern at lines 31-37), and add three cases asserting
`add-label pipeline:halted` is called only when `effective_policy`
is in {skip-until-code-changes, skip-until-human-acts}. Sketch:

```bash
# Replace the linear.sh stub at lines 22-28 with a capture-stub.
LINEAR_CAPTURE="$STUB_DIR/linear.capture"
: > "$LINEAR_CAPTURE"
cat > "$STUB_DIR/linear.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$LINEAR_CAPTURE"
exit 0
SH
chmod +x "$STUB_DIR/linear.sh"

# Helpers.
reset_linear() { : > "$LINEAR_CAPTURE"; }
linear_calls()  { cat "$LINEAR_CAPTURE"; }

# ─── Test N: retry-immediately fresh hit does NOT apply pipeline:halted ─
reset_state; reset_linear
MOCK_PIPELINE_HASH="hashG" MOCK_BRANCH_SHA="shaG" \
  classify_failure "ENG-920" "implement" "retry-immediately" "API-529" 20 ""
if linear_calls | grep -q '^add-label ENG-920 pipeline:halted$'; then
  fail_at "case-N retry-immediately should NOT apply pipeline:halted" "got: $(linear_calls | grep pipeline:halted)"
else
  pass_at "case-N retry-immediately does not apply pipeline:halted (ENG-78 D-001)"
fi

# ─── Test N+1: retry-immediately auto-escalation DOES apply pipeline:halted ─
reset_state
MOCK_PIPELINE_HASH="hashH" MOCK_BRANCH_SHA="shaH" \
  classify_failure "ENG-921" "implement" "retry-immediately" "r1" 20 ""
MOCK_PIPELINE_HASH="hashH" MOCK_BRANCH_SHA="shaH" \
  classify_failure "ENG-921" "implement" "retry-immediately" "r2" 20 ""
reset_linear
MOCK_PIPELINE_HASH="hashH" MOCK_BRANCH_SHA="shaH" \
  classify_failure "ENG-921" "implement" "retry-immediately" "r3" 20 ""
if linear_calls | grep -q '^add-label ENG-921 pipeline:halted$'; then
  pass_at "case-N+1 auto-escalated retry-immediately applies pipeline:halted (ENG-78 D-001)"
else
  fail_at "case-N+1 auto-escalated retry-immediately should apply pipeline:halted" "got: $(linear_calls)"
fi

# ─── Test N+2: skip-until-human-acts DOES apply pipeline:halted ─
reset_state; reset_linear
MOCK_PIPELINE_HASH="hashI" MOCK_BRANCH_SHA="shaI" \
  classify_failure "ENG-922" "implement" "skip-until-human-acts" "severe" 21 3
if linear_calls | grep -q '^add-label ENG-922 pipeline:halted$'; then
  pass_at "case-N+2 skip-until-human-acts applies pipeline:halted (ENG-78 G-3)"
else
  fail_at "case-N+2 skip-until-human-acts should apply pipeline:halted" "got: $(linear_calls)"
fi

# ─── Test N+3: retry-immediately uses meta-shape marker, not halt-shape ─
reset_state; reset_linear
MOCK_PIPELINE_HASH="hashJ" MOCK_BRANCH_SHA="shaJ" \
  classify_failure "ENG-923" "implement" "retry-immediately" "API-529" 20 ""
# add-or-update-comment is called with sig and body; assert sig contains "retry-pending"
# and the body does NOT contain "<!-- pipeline: verdict result=halt".
last_aoc="$(linear_calls | grep '^add-or-update-comment' | tail -1)"
if [[ "$last_aoc" == *"retry-pending/implement/ENG-923"* ]] \
   && [[ "$last_aoc" != *"<!-- pipeline: verdict result=halt"* ]]; then
  pass_at "case-N+3 retry-immediately uses retry-pending meta-shape (ENG-78 D-002)"
else
  fail_at "case-N+3 retry-immediately marker shape" "got: $last_aoc"
fi
```

**D-004b: poll-slot-test.sh (or new poll-evaluate-skip-test.sh)** —
add a case asserting `_poll_evaluate_skip` does NOT delete an
`issue-state.json` whose `policy` is `retry-immediately` when no
skip label is present. Sketch:

```bash
# Setup: a state file with policy=retry-immediately, label set without skip-until-*.
mkdir -p "$(issue_dir ENG-925)"
printf '{"policy":"retry-immediately","retry_count":1,"evidence":{"pipeline_content_hash":"h","branch_head_sha":"s"}}' \
  > "$(issue_dir ENG-925)/issue-state.json"
labels='["stage:implementing"]'

# Invoke _poll_evaluate_skip.
out="$(_poll_evaluate_skip "ENG-925" "$labels"; echo "rc=$?")"

# Assert: state file still exists.
if [[ -f "$(issue_dir ENG-925)/issue-state.json" ]]; then
  pass "ENG-78 D-003: retry-immediately state preserved when no skip label"
else
  fail "ENG-78 D-003: retry-immediately state was deleted (orphan-cleanup overreach)"
fi

# Adversarial: a state file with policy=skip-until-code-changes BUT no skip
# label is still treated as orphan (pre-D-003 behavior preserved).
mkdir -p "$(issue_dir ENG-926)"
printf '{"policy":"skip-until-code-changes","retry_count":2}' \
  > "$(issue_dir ENG-926)/issue-state.json"
out2="$(_poll_evaluate_skip "ENG-926" "$labels"; echo "rc=$?")"
if [[ ! -f "$(issue_dir ENG-926)/issue-state.json" ]]; then
  pass "ENG-78 D-003 adversarial: orphan skip-until-* state still cleaned up"
else
  fail "ENG-78 D-003 adversarial: skip-until-code-changes orphan was preserved (overreach)"
fi
```

**D-004c: bin/run-stage-test.sh end-to-end fixture (optional, recommended).**
The existing run-stage-test.sh structure stubs dispatch.sh. Add a
case where dispatch.sh exits non-zero with stderr matching the
529-style API-error pattern. Assert that after run-stage.sh exits
20, `pipeline:halted` is NOT in the linear-stub capture. This is
the issue's "Test plan" first item ("Reproduce the 529-on-build
scenario via a stub claude that exits non-zero with stderr
matching the API-error pattern. Assert that next tick re-dispatches
rather than skipping with `max-concurrent-reached` or 'no work'.")
The "next tick re-dispatches" half is hard to assert in a
single-process unit test (would need to drive the orchestrator
loop end-to-end), but the necessary precondition — no halt label
applied — is asserted directly by D-004a case-N. D-004c is
therefore RECOMMENDED but lower priority than D-004a/b. If the
existing run-stage-test.sh structure makes adding this
prohibitively invasive, mark it as a follow-up; D-004a's
function-level coverage of the same code path is the load-bearing
test.

**Why.** Each test pin protects against a different regression
class:

- D-004a guards the apply-site decision in classify-failure
  (D-001 + D-002).
- D-004b guards poll.sh's orphan-cleanup branch (D-003).
- D-004c guards the contract end-to-end (D-001 reaching the linear
  stub via the run-stage fail path).

The capture-stub pattern is verified to work in
`bin/classify-failure-test.sh:31-37` (existing metrics.sh capture)
and `bin/run-stage-test.sh` (similar pattern for verdict-handler
inputs); converting the linear.sh stub to a capture-stub is a
mechanical change.

**Rejected alternative — only test at the function level (D-004a
alone), skip the poll-side test (D-004b).** The poll.sh orphan-
cleanup path is in a different file from classify-failure; a
future refactor that touches poll.sh's `_poll_evaluate_skip`
without touching classify-failure could regress D-003 silently.
The function-level coverage doesn't catch that. Rejected.

**Rejected alternative — defer all testing to a follow-up PR.**
The CLAUDE.md test-pinning convention (and the precedent set by
ENG-67's `bin/run-local-content-test.sh` regression pin) is to
ship the test and the fix together. Rejected on A-1 / project
convention grounds.

## 5. Architecture (where code goes)

| Component | Path:Line (today) | Touched by | Net delta |
|---|---|---|---|
| `classify_failure` halt-label apply | `bin/classify-failure.sh:117-119` | D-001 | -3 lines, +10 lines (case + comment) |
| `classify_failure` halt-comment block | `bin/classify-failure.sh:121-146` | D-002 | -26 lines, +35 lines (split into halt vs retry-pending branches) |
| `_poll_evaluate_skip` orphan cleanup | `bin/poll.sh:57-64` | D-003 | +8 lines (policy-read + branch + log) |
| classify-failure tests (linear stub + 4 cases) | `bin/classify-failure-test.sh:22-28, append at end` | D-004a | +60 lines |
| poll-evaluate-skip tests (2 cases) | `bin/poll-slot-test.sh` (append) | D-004b | +30 lines |
| run-stage end-to-end fixture | `bin/run-stage-test.sh` (append, optional) | D-004c | +20 lines (deferrable) |
| CLAUDE.md doc string for issue-state.json | `CLAUDE.md:214-217` | D-003 follow-on | 1 line edit (`skip-label dance OR retry tracking`) |
| `bin/classify-failure.sh:117` historical comment | `bin/classify-failure.sh:117-118` | D-001 | replace ENG-18 misattribution with ENG-78 corrigendum |

No new files. No new exports. No new env vars. No new config
keys. No changes to `bin/pipeline-events.json` (D-002 uses the
existing `meta:metric` shape). No changes to `bin/run-stage.sh` —
the failure-arm sites at lines 813-818, 982-986, 1004-1009 keep
their current `classify_failure ... retry-immediately ...`
calls; D-001+D-002 implement the new behavior inside
`classify_failure` itself, so the call sites are unmodified.

The single touched function in poll.sh
(`_poll_evaluate_skip`) is sourced into `_poll_classify_labels`
via the existing call at `bin/poll.sh:197`; no signature change,
no new caller.

## 6. Data flow

**Today (the bug).** Transient failure path on ENG-68 build dispatch:

```
Tick 1 @ T0
  ├─ poll.sh         → dispatch ENG-68 building (held slot, advanceable)
  ├─ run-stage.sh    → dispatch.sh exits non-zero (claude API 529)
  │   └─ classify_failure ENG-68 building retry-immediately ...
  │       ├─ writes issue-state.json {policy:retry-immediately, retry_count:0}
  │       ├─ add-label pipeline:halted              ← BUG SITE
  │       ├─ add-or-update-comment halt/building/ENG-68 with halt-shape marker
  │       └─ metrics.sh stage-end ... outcome=dispatch-failed
  └─ exit 20

Tick 2 @ T0+5min … Tick N @ T0+5h
  └─ poll.sh
      ├─ _poll_classify_labels: pipeline:halted present, fresh marker is pipeline-halt
      │  → slot:vacate, advanceable:false
      ├─ verdict_handler: pipeline-halt → return 1 (preserve halt)
      └─ "max-concurrent-reached" or "no work"     ← NEVER RE-DISPATCHED
```

Five hours of dormancy.

**With ENG-78 D-001..D-004.** Same scenario:

```
Tick 1 @ T0
  ├─ poll.sh         → dispatch ENG-68 building
  ├─ run-stage.sh    → dispatch.sh exits non-zero (claude API 529)
  │   └─ classify_failure ENG-68 building retry-immediately ...
  │       ├─ writes issue-state.json {policy:retry-immediately, retry_count:0}
  │       ├─ NO halt label (D-001)
  │       ├─ add-or-update-comment retry-pending/building/ENG-68 with meta-shape  ← D-002
  │       └─ metrics.sh stage-end ... outcome=dispatch-failed
  └─ exit 20  (run-local.sh increments .consecutive-failures to 1)

Tick 2 @ T0+5min
  ├─ poll.sh
  │   ├─ _poll_evaluate_skip: no skip labels, state file present with
  │   │  policy=retry-immediately → keep file, return 0 (eligible)  ← D-003
  │   ├─ _poll_classify_labels: no halted label, no skip label, falls through
  │   │  → slot:hold, advanceable:true
  │   └─ held-slot loop: dispatch ENG-68 building
  ├─ run-stage.sh
  │   ├─ Case A (API recovered, dispatch succeeds):
  │   │   ├─ agent posts pass marker T2 (T2 > T0 → freshest)
  │   │   ├─ post-dispatch: _post_dispatch_apply_halt adds pipeline:halted (ENG-56)
  │   │   ├─ verdict_handler reads find_fresh_verdict → pipeline-stage-summary
  │   │   ├─ apply_transition: stage:building → stage:released
  │   │   │  removes pipeline:halted (verified at bin/verdict-handler.sh:273)
  │   │   ├─ run-stage.sh:1081 removes issue-state.json
  │   │   └─ exit 0  (run-local.sh clears .consecutive-failures)
  │   └─ Case B (API still 529, dispatch fails again):
  │       └─ classify_failure ... retry-immediately ...
  │           ├─ reads prior_policy=retry-immediately, prior_hash=h, prior_sha=s
  │           ├─ same evidence → retry_count=1, effective_policy=retry-immediately
  │           ├─ NO halt label (D-001), retry-pending comment updated (D-002)
  │           └─ exit 20  (run-local.sh: .consecutive-failures=2)

Tick 3 @ T0+10min (Case B continues, API still down)
  └─ … same as Tick 2 Case B …
      ├─ retry_count=2, effective_policy escalates to skip-until-code-changes
      ├─ apply pipeline:halted + pipeline:skip-until-code-changes  (D-001 escalated arm)
      ├─ NEW halt comment under sig halt/building/ENG-68 (D-002 distinct sig)
      └─ exit 20  (run-local.sh: .consecutive-failures=3 → trip_breaker)

Tick 4 @ T0+15min (post-escalation)
  └─ poll.sh
      ├─ orchestrator.paused=true (breaker tripped) → idle
      └─ Operator inspects, decides:
          ├─ pipeline.sh decide --action continue   (resumes; clears halt + skip + breaker)
          └─ pipeline.sh decide --action abandon    (halts permanently)
```

Behavioral notes on the new flow:

- **Successful retry on Tick 2 (Case A) requires no operator action.**
  The state file is cleaned up on success (existing
  `bin/run-stage.sh:1081` behavior). The retry-pending Linear comment
  remains in the thread as a forensic record but does not affect
  freshness (meta-shape is invisible to `find_fresh_verdict`).
- **Auto-escalation lands on Tick 3 — the breaker also trips
  simultaneously.** This is the same trip-on-3-consecutive-failures
  behavior the breaker has today; the difference is that today the
  breaker trip happens on Tick 1 (single failure → halted → 2
  more unrelated failures elsewhere) whereas with ENG-78 the trip
  reflects 3 same-issue consecutive failures. Operator action via
  `pipeline.sh decide --action continue` clears both the halt and
  the breaker (verified at
  `bin/pipeline.sh::_pipeline_clear_breaker:268-...`). See §10
  O-3 for the open question on whether to soften this interaction.
- **Operator-resume preserves retry-immediately state.**
  `_pipeline_drain_issue_state` at `bin/pipeline.sh:207-226` only
  removes `issue-state.json` when policy=skip-until-human-acts,
  which is unchanged.

## 7. Error handling

**E-1. The `linear.sh add-label` call fails (network blip).**
Today's behavior: `|| true` swallows the error
(`bin/classify-failure.sh:119`). The state file IS still written
(line 102, before the linear.sh call). With D-001, the same
guarantee holds: the state file is written before any linear.sh
call, and all linear.sh calls retain their `|| true` suffix. A
network-failed add-label on the auto-escalation path would leave
the issue with state file=skip-until-code-changes but no halt
label applied — `_poll_evaluate_skip`'s evidence-comparison logic
at `bin/poll.sh:83-93` reads the state file and may still resume,
but without the halt label, the issue isn't classified as
"halted" by `_poll_classify_labels`. This is identical to today's
network-blip failure mode and is bounded by the same retry — next
tick's classify-failure call would re-attempt the add-label.

**E-2. The state-file `jq -r '.policy'` read in D-003 fails (file
corruption).** D-003's branch defaults to the false case via `||
true` and `[[ "$cur_policy" == "retry-immediately" ]]` returns
false, so a corrupted state file falls through to the existing
orphan-deletion path. Strictly safer than today: today an
unparseable state file is silently deleted; D-003 logs which arm
it took.

**E-3. The state file's policy field has been hand-edited to
something invalid (e.g., `policy=foo`).** D-003 treats it as
non-retry-immediately, deletes as orphan. Same behavior as today.
classify-failure on the next failure writes a fresh state file
with the correct policy.

**E-4. The retry-pending sig collides with an operator-emitted
comment.** The sig namespace `retry-pending/$stage/$issue`
follows the existing convention (verified by
`completion/$stage/$issue` at `bin/run-stage.sh::post_completion_comment`
and `halt/$stage/$issue` at `bin/classify-failure.sh:124`). No
operator-emitted comment uses this prefix today (verified via
grep across `bin/`). New convention; future operators must avoid
the prefix. Documented in CLAUDE.md follow-on edit.

**E-5. `_poll_evaluate_skip` reads `issue-state.json` while
`classify_failure._cf_write_state` is mid-write.** The write is
atomic (tmp + rename, verified at `bin/classify-failure.sh:30-37`).
`jq -r` on either the old file or the new file produces a valid
policy string; either branches D-003 correctly. The atomic rename
guarantees no torn read.

**E-6. The agent on Tick 2 succeeds and posts a pass marker, but
the classify-failure halt marker from Tick 1 is "newer than the
last transition" because no transition happened.** Verified
non-issue: `find_fresh_verdict` (line 114 in
`bin/verdict-handler.sh`) picks the LATEST verdict marker by
createdAt across all comments past the freshness floor. The pass
marker (createdAt=T2) is later than the halt marker
(createdAt=T1). The pass marker wins. apply_transition fires.
Halt label removed.

**E-7. The agent on Tick 2 succeeds but does NOT post a pass
marker (agent-contract failure).** run-stage.sh's agent-contract
validator at lines 977-989 fires, calls
`classify_failure ... retry-immediately ... 25`. retry_count
increments. Same code path as a dispatch-rc-non-zero failure;
auto-escalation behaves identically. No regression.

**E-8. ENG-63 reapplied-footer interaction.** D-002 creates a NEW
comment under sig `retry-pending/$stage/$issue` on Tick 1; on
Tick 2 with same body content, ENG-63's reapplied-footer logic at
`bin/linear.sh:582-606` appends `<!-- meta: reapplied at=T2 -->`
to advance updatedAt. find_fresh_verdict still ignores the
comment (meta-shape, not verdict-shape). No regression.

## 8. Edge cases

**EC-1. retry-immediately state file with `prior_policy="" `
(brand new failure on a previously-clean issue).** classify-failure
treats `prior_policy=""` as not-matching at line 69 (the `&&`
clause), so retry_count stays 0 and effective_policy stays
retry-immediately. D-001 doesn't apply halt. D-003 preserves the
state. Subsequent ticks behave correctly.

**EC-2. retry-immediately followed by a different failure shape
on the next tick (e.g., dispatch_rc=20 then scope-violation
exit=21).** classify-failure on the second failure is called with
`base_policy=skip-until-code-changes` (verified at
`bin/run-stage.sh:906-908`). The auto-escalation guard at lines
67-77 doesn't fire (base_policy != retry-immediately). The state
file is rewritten with policy=skip-until-code-changes,
retry_count=0. D-001 applies halt. D-003 sees policy=skip-until-
code-changes (NOT retry-immediately) on the NEXT tick's poll, so
the file falls into the existing orphan-or-skip path correctly.

**EC-3. Operator manually applies `pipeline:halted` to a
retry-immediately-state issue (e.g., via the Linear UI).** The
agent-prompts lane matrix at `AGENT_PROMPTS.md:105` allows
human-applied `pipeline:halted`. With D-003 preserving the state
file, the next tick poll sees: pipeline:halted=true,
state file with policy=retry-immediately. `_poll_classify_labels`
halt branch fires (line 217), calls `verdict_handler`. If the
classify-failure marker shape was already changed to meta-shape
(D-002) and is the freshest comment, find_fresh_verdict skips
meta and may return empty → `class='{"slot":"hold","advanceable":false}'`.
The slot is held but not advanceable. Operator must follow
through with `pipeline.sh decide --action continue` (or remove
halt manually). Documented as a deliberate human-pause path —
identical to today's behavior for human-applied halt without an
agent-emitted halt verdict.

**EC-4. Two consecutive retry-immediately failures on different
stages (e.g., implementing fails on Tick 1, then a transition
happens, then reviewing fails on Tick 5).** The state file's
`.stage` field carries the stage name (verified at
`bin/classify-failure.sh:96`). classify-failure does NOT key the
auto-escalation comparison on stage match; only on
`prior_policy == "retry-immediately"` and evidence match. Cross-
stage retry-counter contamination is theoretically possible but
practically blocked by the evidence comparison: a new stage
typically has a different `branch_head_sha` (because the prior
stage's transition pushed commits) AND/OR a different
`pipeline_content_hash` (rare), so retry_count resets to 0 anyway.
This is an existing pre-ENG-78 quirk — not introduced or fixed by
this change. Flagged in §10 O-1.

**EC-5. `decide --action continue` on a retry-immediately
issue.** `_pipeline_drain_issue_state` at `bin/pipeline.sh:207-226`
only removes `issue-state.json` when policy=skip-until-human-acts.
For retry-immediately, the state file is preserved across
operator continues. This is intentional: an operator-resume during
a retry-pending sequence preserves the retry counter so that the
next failure (if any) escalates correctly. The retry-immediately
state file becomes orphan-on-success when run-stage.sh:1081 fires.

**EC-6. The `retrospective` runs while a retry-immediately is in
flight.** The retrospective at `bin/run-retrospective-local.sh`
reads metrics from `events.jsonl`. `bin/classify-failure.sh:155-157`
emits `outcome=dispatch-failed policy=retry-immediately
retry_count=N branch=B`. The retrospective sees the
`dispatch-failed` outcome the same as today. With D-002, the
Linear-thread visualization shifts from "halt sprawl"
(retry-pending comment is meta-shape, not counted by
`_poll_emit_halt_sprawl_alert`) to a normal failure metric.
Retrospective behavior is unchanged.

**EC-7. The breaker trips on retry-immediately escalation
(Tick 3).** `bin/run-local.sh:256-263` increments
`.consecutive-failures` on every non-zero rc=20 from
`run-stage.sh`. With D-001+D-003 enabling 3 same-evidence retries
in 3 ticks (~15 minutes at 5-min ticks), the third trip flips
`orchestrator.paused=true`. Operator action via `pipeline.sh
decide --action continue` clears both the halt label and the
breaker (verified at `bin/pipeline.sh::_pipeline_clear_breaker`).
This is the same operator-experience as today's halt-sprawl trip;
the difference is that today's halt fires on Tick 1 already, so
operator awareness of an outage is faster (5min vs 15min). Trade-
off: ENG-78 trades faster operator awareness for lower
operator-touch frequency on transients. The bargain matches the
issue's intent ("transient failures are exactly the case
retry-immediately is meant to handle"). See §10 O-3 for the
open question.

**EC-8. dispatch-timeout (rc=124) interaction.** `dispatch-timeout`
exits use `base_policy=skip-until-human-acts` (verified at
`bin/run-stage.sh:755-757`), not retry-immediately. D-001 applies
halt verbatim. No regression.

**EC-9. PR-opened-too-early (rc=22) and worktree-mutation (rc=26)
interactions.** Both use `base_policy=skip-until-human-acts`
(verified at `bin/run-stage.sh:768, 794`). D-001 applies halt
verbatim. No regression.

**EC-10. lane-violation (rc=13) interaction.** Uses
`base_policy=skip-until-human-acts` (verified at
`bin/run-stage.sh:809`). D-001 applies halt verbatim. No
regression.

## 9. Persona review

Six personas reviewed in the order: design → security → scope →
coherence → product → feasibility (feasibility last per the
brainstorm-stage prompt).

### Design — PASS

Encoding policy semantics at the apply site (D-001) rather than
the reader (Path B) is strictly more cohesive. Splitting the
marker shape (D-002) along the policy boundary makes
`find_fresh_verdict`'s halt-vs-meta partition exhaustive across
classify-failure outputs. The state-file preservation (D-003) is
a one-branch addition that turns a pre-existing assumption
("state file = skip label") into an explicit policy-aware check
without expanding the function's responsibility. Two minor
notes:

- *D-002's escalation-tick comment-sig change* — auto-escalation
  flips from `retry-pending/$stage/$issue` to `halt/$stage/$issue`,
  creating a NEW comment instead of updating in place. This
  matches ENG-63's lesson but means the operator sees TWO
  comments for one failure stretch (retry-pending + halt). Net
  benefit: distinct createdAt for each event class. Net cost: one
  extra comment per escalated stretch, capped at 2 per stretch.
  Acceptable.
- *D-001's "no halt label" arm has no positive logging* — the
  current line 117 has no log line either, so this is symmetric
  with existing behavior. The metrics.sh emission at line
  155-157 already carries `policy=retry-immediately` in notes.

PASS.

### Security — PASS

No new secret handling, no new shell command interpolation, no
new file paths. The `jq -r '.policy // ""'` read in D-003 is
already the pattern used elsewhere in poll.sh
(`bin/poll.sh:85-87`). The state-file path is constructed via
`issue_dir "$ident"` which validates the ident format (verified
at `bin/common.sh:68-72`).

The retry-pending comment body in D-002 includes `$effective_reason`
which can contain agent-controlled text from the dispatch-failure
arm (`see $log_file` etc.). Same pre-existing risk as today's
halt-comment body — no new attack surface. The `printf %s`
formatting safely handles arbitrary content; no `eval` or shell
interpolation.

PASS.

### Scope — PASS (with one flag)

The Linear issue requests fixing the contradiction. D-001+D-002
fix it semantically; D-003 is the enabling coupling that makes
D-001 actually work across ticks; D-004 is the regression pin.
All four sit cleanly within "fix the bug + pin against
regression."

**FLAG.** The Linear issue's "Out of scope" section explicitly
defers "retry-loop budget cap (separate ticket if A doesn't bake
one in)." This brainstorm leans on the existing 2-retry
auto-escalation in classify-failure as the cap. Net effect: 3
attempts before halt (initial + retry_count=1 + retry_count=2
escalation), spread over ~15 minutes. If the operator wants a
larger budget, that's a follow-up — not included in this PR.

**FLAG.** The Linear issue's "Out of scope" also defers "ENG-56's
broader 'orchestrator-managed halt label' design — only revisit
if A's branching breaks any other consumer." D-001 narrows
classify-failure's halt-apply behavior; ENG-56's
`_post_dispatch_apply_halt` (the success-path halt-add) is
unchanged. The two halt-applier sites (classify-failure on
failure path, _post_dispatch_apply_halt on success path) remain
consistent with ENG-56's stated principle ("orchestrator is the
canonical applier"). No ENG-56 violation. Flagged for explicit
acknowledgement.

PASS with two scope flags.

### Coherence — PASS

D-001 brings `bin/classify-failure.sh:117-119`'s comment ("every
policy outcome is a halt surface") in line with the actual
policy taxonomy. D-002 makes the marker shape match the label
state ("halt label ↔ halt marker"; "no halt label ↔ no halt
marker"). D-003 extends `issue-state.json`'s documented contract
("durable state for the skip-label dance") to also cover
"durable retry tracking" — consistent with the ENG-15 design
intent for per-issue state.

The lane matrix at `AGENT_PROMPTS.md:105` allows classify lane to
add `pipeline:halted`; D-001 just gates the apply on policy. No
lane-fence change needed.

PASS.

### Product — PASS

The Linear issue's "Why this matters" section is the product
case: transient API failures should self-recover; misleading
operator UI text creates wasted operator hours. D-001+D-002
remove the silent dormancy AND the misleading text. The
operator-facing comment under D-002 includes an explicit attempt
counter ("attempt N of 2 before escalation"), giving the operator
a clear progress signal during transient outages.

Trade-off the brainstorm makes explicit: operators no longer get
a halt notification on the FIRST transient failure; they get one
after 3 consecutive failures (~15 minutes). Slack signal lag
increases by 10 minutes worst case. The bargain matches the
issue's stated intent.

PASS.

### Feasibility — PASS (with two precondition checks)

All facts in §1, §4, and §6 cite path:line references in the
current worktree (verified at composition time, see Anti-bias
checks §12). The change set is:

- 1 function-internal branch in classify-failure (D-001, ~10 lines)
- 1 marker-shape conditional in classify-failure (D-002, ~15 net lines)
- 1 policy-aware orphan-cleanup branch in poll.sh (D-003, ~8 lines)
- 1 capture-stub conversion + 4 test cases in classify-failure-test.sh (D-004a)
- 2 test cases in poll-slot-test.sh (D-004b)
- (optional) 1 fixture in run-stage-test.sh (D-004c)

No new files. No new exports. No new config keys.

**Precondition P-1 (D-001 control flow):** the failure arms in
run-stage.sh exit with rc != 0 BEFORE reaching
`_post_dispatch_apply_halt` at line 1036. Verified by reading
lines 813-818, 982-986, 1004-1009 — each ends in
`exit 20|24|25` directly after `classify_failure`. The post-
dispatch hook is unreachable from the failure arms. Therefore
D-001's branching at the classify-failure layer is the SOLE
halt-apply site on the failure path. Confirmed.

**Precondition P-2 (find_fresh_verdict freshness on a successful
retry):** the agent-emitted pass marker on Tick 2 has a later
createdAt than the classify-failure halt marker on Tick 1, so
`find_fresh_verdict`'s `[[ "$ts" > "$fresh_ts" ]]` comparison at
`bin/verdict-handler.sh:114` selects the pass marker. add-or-
update-comment preserves createdAt across body updates (verified
at `bin/linear.sh:607-611` — `commentUpdate` mutation doesn't
touch createdAt), so even an in-place update on Tick 1's halt
comment doesn't bump it past Tick 2's pass marker. Confirmed.

PASS (gate P0: 0).

## 10. Open questions / out of scope

**O-1.** Should the auto-escalation guard at
`bin/classify-failure.sh:67-77` also key on stage match (so a
retry-immediately on stage:implementing followed by a separate
retry-immediately on stage:reviewing doesn't compound counters)?
This is an existing pre-ENG-78 quirk — flagged in EC-4 — not
introduced or worsened by this change. Defer to a follow-up if
operationally observed; the current evidence-comparison usually
masks it.

**O-2.** Should `_post_dispatch_apply_halt` (the success-path
halt-add at `bin/run-stage.sh:378-390`) ALSO branch on the
state file's policy (so a successful Tick 2 of a retry-immediately
issue doesn't briefly add+remove the halt label)? The brief flash
is invisible to `_poll_classify_labels` because it's fully bracketed
inside `verdict_handler`'s apply_transition. No operator visibility
of the flash. The defense-in-depth value of the unconditional add
(per ENG-56) is preserved. Defer.

**O-3.** Should run-local.sh's `.consecutive-failures` counter
treat retry-immediately exits specially (i.e., not increment the
counter for the first 2 retries to avoid the breaker tripping on
Tick 3 just as the auto-escalation lands)? The current behavior
trades per-issue resilience for project-wide safety; ENG-78
keeps the trade. If the breaker-on-tick-3 interaction proves
operationally noisy (e.g., over-tripping during legitimate
sustained Anthropic outages), the open question becomes "exit
non-zero on success-of-classify but tag the rc as 'retried,
self-managing'." Out of scope; deferred to operational data.

**O-4.** D-002's retry-pending comment text could include a
direct link to the dispatch log file (`$log_file` from
run-stage.sh:730). This requires plumbing `log_file` into
classify_failure as a parameter, which expands the function
signature. The current dispatch-failure arm at line 814-815
already mentions "(see $log_file)" inline in the reason string,
so the retry-pending comment shows it via `effective_reason`.
Adequate for now; defer to a follow-up if operators ask.

**O-5.** The CLAUDE.md doc string at line 214 ("`issue-state.json`
is the durable state for the skip-label dance") is mildly stale
even pre-ENG-78 — it was always also durable for retry tracking.
A one-line edit to "for the skip-label dance OR retry tracking"
clarifies. In scope as a small follow-on edit alongside the
implement PR; not load-bearing for the fix itself.

**Out of scope, per the issue:**
- Retry-loop budget cap beyond the existing 2-retry auto-escalation.
- ENG-56's broader orchestrator-managed halt-label design.
- Verdict-marker registry expansion (no new `result` shapes).
- Refactor of `_poll_evaluate_skip` orphan-cleanup beyond the
  one-branch policy-aware addition.

## 11. Acceptance criteria

The Linear issue's "Test plan" section maps to the following
tests, all in this brainstorm's D-004 scope:

| Linear issue test plan item | Test in this brainstorm |
|---|---|
| Reproduce 529-on-build via stub claude; assert next tick re-dispatches | D-004a case-N (no halt label applied) + D-004b (state preserved across ticks) + D-004c (e2e fixture, optional) |
| Adversarial: skip-until-human-acts still halts | D-004a case-N+2 |
| Pin halt comment text — match actual behavior | D-004a case-N+3 (asserts retry-pending sig + meta-shape + absence of halt verdict marker) |

Plus implicit AC from the Goals section:

- **G-1:** D-004a case-N pins.
- **G-2:** D-004a case-N+1 pins.
- **G-3:** D-004a case-N+2 pins.
- **G-4:** D-004a case-N+3 pins (meta-shape, distinct sig).
- **G-5:** D-004b cases pin.
- **G-6:** Implicit — D-001 ensures `pipeline:halted` is not
  applied on retry-immediately, so `_poll_emit_halt_sprawl_alert`
  (which counts `slot=="vacate"` entries, themselves gated on the
  halt label at `bin/poll.sh:217-233`) cannot count
  retry-immediately issues. No new test needed; existing
  halt-sprawl-test.sh remains green.

All 14 existing classify-failure-test.sh cases must continue to
pass (verified by running the test today; D-001 changes the
add-label call shape but the existing cases assert state-file
contents and metric notes only — none assert add-label
invocations directly, so the new capture-stub doesn't break them).

The full bin/*-test.sh suite (per CLAUDE.md "Pre-commit hook" §)
must remain green.

## 12. Anti-bias checks

### ADR / existing-decision pressure

ENG-18 (verdict-marker protocol; halt-label as "operator decision
needed" sentinel) — D-001 brings classify-failure's apply behavior
INTO line with ENG-18's stated principle. Not pressure, alignment.

ENG-56 (orchestrator-canonical halt applier) — D-001 narrows
classify-failure's halt-apply set, but the orchestrator is still
the canonical applier; the set is just smaller. ENG-56's
`_post_dispatch_apply_halt` (success path) is untouched. ENG-56's
"orchestrator is the canonical applier" principle is preserved.

ENG-15 (per-issue state directory; `issue-state.json` as durable
state for skip-label dance) — D-003 stretches the
`issue-state.json` contract to include retry tracking. Coherent
extension of the existing durable-state pattern.

ENG-63 (add-or-update-comment identical-body re-applies) —
D-002's distinct sigs (`retry-pending` vs `halt`) leverage the
ENG-63 lesson without re-arguing it: a fresh halt event deserves a
fresh comment with its own createdAt for forensics.

ENG-58 (atomic state reset on operator-continue) — `_pipeline_drain_issue_state`
preserves retry-immediately state across operator-continues; this
is intentional and consistent with ENG-58's "halt artifacts
distinct from active retry tracking" boundary.

No ADR overturned. No accepted decision pressure noted.

### Simpler-alternative inventory

For each major decision, a rejected alternative was documented in
§4 with a stated reason:

- D-001: Path B (poll.sh reads state file) rejected on coherence;
  Path C (classify-failure auto-clears) rejected by issue itself
  (race-prone).
- D-002: keep halt-shape marker rejected on defense-in-depth; no
  comment at all rejected on operator-experience; new verdict
  result (`transient`) rejected on A-1 (don't add features).
- D-003: preserve unconditionally rejected on orphan-leak risk;
  separate file (`retry-${stage}.json`) rejected on A-1 (no new
  files needed).
- D-004: function-level only rejected on regression-coverage;
  defer all testing rejected on project-test-pinning convention.

### Assumption inventory

| Claim in brainstorm | Status | Verification |
|---|---|---|
| `classify_failure` is called from run-stage.sh's three retry-immediately arms (lines 813-818, 982-986, 1004-1009) | verified | `bin/run-stage.sh:813-818, 982-986, 1004-1009` |
| `classify_failure` writes `issue-state.json` and unconditionally applies `pipeline:halted` at line 119 | verified | `bin/classify-failure.sh:117-119` |
| `classify_failure` posts a halt-shape verdict marker at line 124-146 with policy-branched body | verified | `bin/classify-failure.sh:121-146` |
| auto-escalation flips effective_policy to skip-until-code-changes when prior_policy=retry-immediately AND retry_count >= 2 | verified | `bin/classify-failure.sh:67-77` + `bin/classify-failure-test.sh:107-114` (case-4) |
| `bin/poll.sh::_poll_evaluate_skip` deletes `issue-state.json` orphan when no skip label is present | verified | `bin/poll.sh:57-64` |
| `bin/poll.sh::_poll_classify_labels` halt branch returns slot:vacate for `pipeline-halt` markers | verified | `bin/poll.sh:217-233` |
| `bin/poll.sh` held-slot loop calls `verdict_handler` for halted advanceable issues | verified | `bin/poll.sh:442-448` |
| `verdict_handler` returns 1 ("preserve halt") for `pipeline-halt` markers | verified | `bin/verdict-handler.sh:396-398` |
| `find_fresh_verdict` ignores meta-shape comments (`event != "verdict"` filter) | verified | `bin/verdict-handler.sh:111` |
| `find_fresh_verdict` selects latest verdict marker by createdAt past the freshness floor | verified | `bin/verdict-handler.sh:106-117` |
| `commentUpdate` mutation in linear.sh preserves createdAt across body updates | verified | `bin/linear.sh:607-611` (commentUpdate input has body only, no createdAt field) |
| `bin/run-stage.sh::_post_dispatch_apply_halt` runs on success path, never reached on failure arms | verified | `bin/run-stage.sh:813-818 exits 20`, `:982-986 exits 25`, `:1004-1009 exits 24`, `:1036` is past those exits |
| `bin/run-stage.sh:1081-1084` clears `issue-state.json`/`wait-${stage}.json` and skip labels on success | verified | `bin/run-stage.sh:1081-1084` |
| `bin/pipeline.sh::_pipeline_drain_issue_state` removes `issue-state.json` only when policy=skip-until-human-acts | verified | `bin/pipeline.sh:207-226` |
| `bin/pipeline-events.json` registers `metric` in `meta_kinds` | verified | reading the file's `meta_kinds` array |
| `bin/common.sh::parse_pipeline_marker` returns `{event:"meta", kind:"metric", ...}` for `<!-- meta: metric ... -->` | verified | `bin/common.sh:185-260` (specifically `family="meta"` branch at 219-220) |
| `failure_outcome_for_exit` taxonomy at `bin/common.sh:107-130` distinguishes typed exit codes (10/11/12/13/20/21/22/24/25/26/124) | verified | reading the file |
| `bin/classify-failure-test.sh:22-28` uses a no-op linear.sh stub today; conversion to capture-stub mirrors the metrics.sh capture at lines 31-37 | verified | reading both blocks |
| `bin/run-local.sh:256-263` increments `.consecutive-failures` on rc != 0 from run-stage.sh; trip_breaker fires at FAIL_THRESHOLD (3) | verified | `bin/run-local.sh:256-263` + `FAIL_COUNTER` definition at `bin/run-local.sh:32` |
| `bin/run-stage.sh::_fresh_wait_reason` allow-list is `building` only post-ENG-54 | verified | `bin/run-stage.sh:308-313` |
| `bin/verdict-handler.sh::apply_transition` removes `pipeline:halted` at line 273 | verified | `bin/verdict-handler.sh:273` |
| ENG-68 incident (529 Overloaded; 5 hours dormant; the linked issue's evidence) | assumed | issue body claim; not separately verified in this brainstorm. The mechanism by which a halted issue idles indefinitely IS verified per the rest of the table; only the wall-clock duration is taken on the issue's word. |
| operator-emitted comments do not use the `retry-pending/` sig prefix today | verified | grep for "retry-pending" across `bin/`, `AGENT_PROMPTS.md`, `docs/` returns no current-author hits |
| CLAUDE.md "Per-issue state directory" §214 documents `issue-state.json` as "durable state for the skip-label dance" | verified | `CLAUDE.md:214-217` |
| `AGENT_PROMPTS.md:105` allows classify lane to add `pipeline:halted` (so D-001's gating is policy-driven, not lane-driven) | verified | `AGENT_PROMPTS.md:105` |
| `bin/halt-sprawl-test.sh` exists; `_poll_emit_halt_sprawl_alert` counts only slot=="vacate" entries | verified | `bin/poll.sh:317-376` (halt-sprawl helper); `bin/poll.sh:332` (count = `[.[] | select(.slot == "vacate")] | length`) |

All twenty-six load-bearing facts cited in the brainstorm are
"verified" against the worktree at composition time. The only
"assumed" item is the wall-clock duration of ENG-68's dormancy
(taken on the linked issue's word; the mechanism is verified).

### Codebase-fact verification

Every named symbol referenced in the brainstorm has been opened
and quoted by `path:line` in the Assumption Inventory above. Two
classes of named symbols specifically:

- **Functions and helpers:** `classify_failure`,
  `_cf_write_state`, `_cf_branch_for`, `_cf_branch_head_sha`,
  `compute_pipeline_content_hash`, `failure_outcome_for_exit`,
  `parse_pipeline_marker`, `_poll_evaluate_skip`,
  `_poll_classify_labels`, `_poll_emit_halt_sprawl_alert`,
  `find_fresh_verdict`, `verdict_handler`,
  `_post_dispatch_apply_halt`, `_handle_wait`,
  `_pipeline_drain_issue_state`, `_pipeline_clear_breaker`,
  `_fresh_wait_reason`, `apply_transition`,
  `add_or_update_comment`, `add_label`, `remove_label`,
  `post_completion_comment`, `assert_no_tool_invocation`. All
  exist at the line numbers cited.
- **Files and directories:** `bin/classify-failure.sh`,
  `bin/poll.sh`, `bin/run-stage.sh`, `bin/run-local.sh`,
  `bin/common.sh`, `bin/verdict-handler.sh`, `bin/pipeline.sh`,
  `bin/linear.sh`, `bin/dispatch.sh`, `bin/branch-name.sh`,
  `bin/pipeline-events.json`, `bin/metrics.sh`,
  `AGENT_PROMPTS.md`, `CLAUDE.md`, `bin/classify-failure-test.sh`,
  `bin/poll-slot-test.sh`, `bin/run-stage-test.sh`,
  `bin/halt-sprawl-test.sh`, `bin/run-local-helpers.sh`,
  `docs/runbooks/recovery.md`. All paths exist in the
  worktree as of composition.

No symbol cited "assumed" without verification.
