---
linear: ENG-47
project: harness
date: 2026-04-28
status: design
related: [ENG-45, ENG-24, ENG-26, ENG-41, ENG-18]
depends_on: [ENG-45]
---

# Halt protocol symmetry — design

## 1. Problem

The halt protocol is asymmetric: easy to enter, hard to exit cleanly.
Three distinct failures observed during 2026-04-28's pipeline work share
one root cause and warrant a unified fix.

### 1.1 Three observed failures

**F1. Entry-side, narrow soft-pause primitive (ENG-26 → ENG-45 partial fix).**
The build agent failing P2 (no human approval) had no soft-pause primitive
available, so it reached for `pipeline-halt: agent-blocked`. ENG-45 introduced
`pipeline-wait` but gated to `[[ "$stage" == "build" ]] || return 1` (see
`bin/run-stage.sh::_fresh_wait_reason` line 302 on the ENG-45 branch). The
*shape* is general; the *implementation* is build-specific. Future soft-pause
cases on other stages would either re-introduce the original P2-style halt
bug, or mint a new shape (vocabulary explosion).

**F2. Exit-side, partial state reset (ENG-24).**
Operator runs `bash bin/halt.sh resolve <issue> --decision resume` to clear
`pipeline:halted`. The label clears. But the *cause* of the halt persists in
three other places:

- Rejection counters via `bin/guards.sh::count_marker_since_last_transition`
  (line 42). Each `<!-- pipeline-metric: implement_rejection -->` newer than
  the most recent `<!-- pipeline-transition: -->` still counts; threshold ≥2
  trips on the next dispatch, before the agent runs.
- Stale verdict markers via `bin/verdict-handler.sh::find_fresh_verdict`
  (line 69). A `<!-- pipeline-halt: -->` marker from before the resume is
  still classified "fresh" because no new transition has been posted to
  invalidate it.
- Stale `wait-{stage}.json` files in `$(issue_dir)` (when the prior halt
  was a budget exhaustion).

Concretely on ENG-24, 2026-04-28T10:47Z: halt resolved 10:47:22Z → re-halted
10:47:55Z. 33-second loop. Operator must rerun resolve and post a synthetic
transition marker to actually unblock.

**F3. Compliance, agent confabulation (ENG-45 ×3).**
UI agent (12:36, 12:57) and implement agent (14:09) all exited "pass" but
failed to emit `pipeline-stage-summary: <stage>` verdict markers. Each
post-dispatch defensive halt-add at `bin/run-stage.sh:445-450` (main) /
`bin/run-stage.sh:542-545` (ENG-45 branch) re-applied `pipeline:halted`;
verdict-handler classified each as `protocol-violation`.

Worse, agents narrated as if they had emitted the marker. Transcript on
ENG-45 implement at 2026-04-28T14:10:10Z claimed "verdict marker
`<!-- pipeline-stage-summary: implementing -->` posted; `pipeline:halted`
applied" — but the actual Linear comment (cc3c49d1) contained only
`<!-- pipeline-sig: completion/implement/ENG-45 -->`. The confabulation
hides the bug from operators reading transcripts; only inspecting Linear
comment bodies surfaces it.

### 1.2 Common root cause

A halt event today simultaneously implies four orthogonal things:

1. **Intent.** An agent declared a human should act (verdict marker).
2. **Gate.** The orchestrator should refuse to advance (`pipeline:halted` label).
3. **Accumulated state.** Counters / state files that contributed to the halt.
4. **Operator override.** Human's authority to clear or reject (decision marker).

These four are managed by distinct mechanisms (markers, labels, JSON state
files, comments) but they aren't atomically transactional. Mutating one
(label) leaves the other three consistent with the prior halted state. The
exit channel doesn't compose with the entry channel.

F1 is "no soft entry shape exists for some scenarios." F2 is "exit doesn't
reset state." F3 is "agents skip the marker step but no audit catches it,
and defensive logic over-corrects in a direction that conflicts with the
agent's actual intent." Three angles on the same asymmetry.

### 1.3 Why one umbrella

The three tracks are independent (different files, different concerns) but
they share a design discipline: **never grow the marker vocabulary; reuse
the existing four-shape protocol via reason fields and per-stage allow-lists.**
Documenting that discipline once, in one place, avoids each future fix
re-deriving it (and possibly choosing differently).

## 2. Background — the four-shape protocol

After ENG-45 lands, the verdict-marker vocabulary stabilizes at four shapes:

| Shape | Behavior class | Reason field |
|---|---|---|
| `pipeline-stage-summary` | advance forward | stage name |
| `pipeline-rejection` | loop backward | target stage |
| `pipeline-halt` | hard stop, operator must act | reason allow-list |
| `pipeline-wait` | soft pause, orchestrator will recheck | reason allow-list |

This is the right ontology — **shape ↔ behavior class; reason ↔ specific
case.** ENG-47's discipline: future failure modes never add a fifth shape.
They map to one of the four behavior classes by adding to that shape's
reason allow-list (and, where applicable, the per-stage→reasons map).

The orchestrator gate label `pipeline:halted` pairs only with `pipeline-halt`.
A `pipeline-wait` marker does **not** apply the halt label — its absence is
load-bearing for ENG-45's poller-redispatch path. This decoupling preserves
the invariant "halt label ↔ operator-must-act" that downstream readers
(dashboards, halt-sprawl alerts, retrospective queries) depend on.

## 3. Three tracks

### 3.1 Track A — Generalize `pipeline-wait` as the canonical soft-pause primitive

ENG-45 introduced `pipeline-wait` with a closed allow-list of reasons
`{awaiting-approval, awaiting-ci}` and a build-stage-only gate. Track A
generalizes the gate without changing the marker shape or reason semantics.

#### D-A1. Promote build-only gate to per-stage→reasons allow-list

Replace the line in `bin/run-stage.sh::_fresh_wait_reason`:

```bash
[[ "$stage" == "build" ]] || return 1
```

with a per-stage allow-list lookup:

```bash
declare -gA _WAIT_REASONS_BY_STAGE=(
  [build]="awaiting-approval awaiting-ci"
)

local allowed_reasons="${_WAIT_REASONS_BY_STAGE[$stage]:-}"
[[ -n "$allowed_reasons" ]] || return 1
[[ " $allowed_reasons " == *" $reason "* ]] || return 1
```

Build's existing behavior is preserved (only the two reasons it had before).
Adding a new stage is a one-entry edit to the array. The security property
that motivated the original build-only gate ("prevent cross-stage marker
forgery from creating a snooze primitive on stages outside the explicit
IN-scope," per ENG-45 brainstorm §D-003) is preserved — only the
explicitly-declared (stage, reason) pairs are accepted. Anything else
returns 1 and the wait gate doesn't fire.

**Rejected alternative:** flat reason allow-list with no stage gate.
Rejected because: (a) loses the per-stage authorization granularity;
(b) any stage that fabricates a wait marker would now be honored; (c)
operators would have no way to disallow wait on a specific stage where it's
inappropriate.

**Rejected alternative:** new shapes per stage (`pipeline-build-wait`,
`pipeline-review-wait`, etc.). Rejected because that's exactly the
vocabulary explosion §1.3 explicitly bounds.

#### D-A2. Per-stage budget configuration

Today's `orchestrator.external_signal_budget` is a single global setting
(default `{max_attempts: 12, max_minutes: 60}`). Promote to a per-stage map
with a `default` fallback:

```json
{
  "orchestrator": {
    "external_signal_budget": {
      "default": {"max_attempts": 12, "max_minutes": 60},
      "build":   {"max_attempts": 12, "max_minutes": 60}
    }
  }
}
```

Configuration migration: operators with the existing flat shape continue to
work — `_handle_wait` reads the per-stage entry first, falls back to
`default`, falls back to the legacy flat shape. Three-tier lookup, fully
backwards-compatible.

#### D-A3. AGENT_PROMPTS.md "Non-verdict markers" preamble update

Add one paragraph to the preamble (introduced by ENG-45) stating:

> The `pipeline-wait` shape is the **canonical soft-pause primitive** for
> any agent stage. New soft-pause failure modes are NOT to be expressed as
> new marker shapes; they are added as new entries in the per-stage
> reasons allow-list (`bin/run-stage.sh::_WAIT_REASONS_BY_STAGE`) via a
> code change reviewed under the standard pipeline. The four shapes
> (`pipeline-stage-summary`, `pipeline-rejection`, `pipeline-halt`,
> `pipeline-wait`) are bounded; sub-cases live in reason fields.

This makes the discipline explicit in the place future agents read first.

### 3.2 Track B — `bin/halt.sh::resolve` as atomic state reset

Today's `bin/halt.sh::resolve` (lines 16-29) does two things:

1. Posts `<!-- pipeline-decision: <decision> -->` comment.
2. Removes `pipeline:halted` label.

Add three more, executed in order so the resume is atomic from the
orchestrator's next-tick perspective:

#### D-B1. Post operator-attributed transition marker

After step 1, post:

```
<!-- pipeline-transition: <current-stage> → <current-stage> (operator-resume) -->

Counter reset and verdict-marker invalidation by operator authority via halt.sh resolve.
```

The shape is the existing `pipeline-transition` — no new vocabulary. The
`(operator-resume)` suffix in the body is the discriminator; readers that
care about agent-vs-operator transitions can grep for the suffix. Existing
freshness consumers (`find_fresh_verdict`, `count_marker_since_last_transition`)
treat the comment exactly as they treat agent transitions: as the new
freshness boundary.

The current stage is read from the issue's `stage:*` label via
`bash bin/linear.sh stage-of <issue>`. If the issue has no stage label
(rare), use the literal `none`.

This single addition unblocks both ENG-24 (rejection counter resets via
the existing freshness rule) and the verdict-marker side of the F2/F3
pathology (stale halt markers become stale).

#### D-B2. Clean stale state files

After step 2 (label removal), execute:

```bash
local stage; stage="$(bash "$SCRIPT_DIR/linear.sh" stage-of "$issue" 2>/dev/null || echo '')"
[[ -n "$stage" ]] && rm -f "$(issue_dir "$issue")/wait-${stage}.json"

# operator's explicit resume invalidates skip-until-* labels
bash "$SCRIPT_DIR/linear.sh" remove-label "$issue" "pipeline:skip-until-human-acts" 2>/dev/null || true
bash "$SCRIPT_DIR/linear.sh" remove-label "$issue" "pipeline:skip-until-code-changes" 2>/dev/null || true

# orphan issue-state.json policy=skip-until-human-acts is a no-op artifact post-resume
local state_file; state_file="$(issue_dir "$issue")/issue-state.json"
if [[ -f "$state_file" ]]; then
  local policy; policy="$(jq -r '.policy // ""' "$state_file" 2>/dev/null)"
  [[ "$policy" == "skip-until-human-acts" ]] && rm -f "$state_file"
fi
```

Each removal is conditional and safe — if the label or file is absent,
the operation is a no-op.

#### D-B3. Decision-aware behavior

The full state reset only applies to `--decision resume`. The other two
decisions need different semantics:

- `--decision scope-approved`: same behavior as resume (operator overrides
  scope concern; counters reset; agent should re-attempt the work).
- `--decision scope-rejected`: the operator is rejecting the work itself,
  not the halt. Do NOT post a transition marker (the halt should remain
  the latest verdict). Do remove `pipeline:halted` so the operator can
  apply `pipeline:abandoned` or move the issue back to a prior stage by
  hand. Do NOT clean wait state files (they're not relevant to a
  scope rejection).

#### D-B4. New marker-emission from halt.sh

`halt.sh resolve` runs in the human writer lane (`PIPELINE_WRITER=human`,
already set at line 14). The new transition marker is written through the
same lane fences as today's resolve comment. No ENG-41 lane changes
required.

**Rejected alternative:** add a new `<!-- pipeline-operator-transition: -->`
shape to make operator authority more explicit. Rejected because it adds
vocabulary for no behavioral benefit — the existing `pipeline-transition`
shape with a body suffix is parseable by humans and machines, and existing
freshness rules apply unchanged.

**Rejected alternative:** ship `count_marker_since_last_transition` with a
new exemption for "comments before a `pipeline-decision` are stale."
Rejected because it conflates two rules (transition-based freshness and
decision-based exemption), making the freshness logic harder to reason
about. Posting a transition marker is simpler and uses the existing rule.

### 3.3 Track C — Marker-emission compliance + tighter defensive halt-add

ENG-45's three failure cases (UI ×2, implement ×1) all share a shape: the
agent emitted a `pipeline-sig` (which is dedup metadata, not a verdict
marker) and narrated as if it had emitted a verdict marker. The orchestrator's
defensive halt-add at `bin/run-stage.sh:445-450` (main) re-applied
`pipeline:halted` because no `pipeline-halt` shape was in Linear, and
verdict-handler then wrote `pipeline-halt: protocol-violation` as the
canonical halt cause.

Two compounding causes:

1. **Agent confabulation.** The agent's transcript output ≠ what's in
   Linear. The agent thinks emitting `pipeline-sig` counts as emitting a
   verdict marker. Or it thinks the marker text in its own narration
   counts as posting it.
2. **Defensive halt-add over-corrects.** It treats "agent didn't apply
   `pipeline:halted` label" as definitive evidence of an unfinished agent
   exit. But a clean-pass exit also doesn't apply the halt label by design;
   the orchestrator's verdict-handler is supposed to swap the stage label
   based on the agent's emitted `pipeline-stage-summary`.

#### D-C1. Tighten `bin/run-stage.sh` defensive halt-add

Replace the current logic (lines 445-450 on main):

```bash
# Post-dispatch halt check: every stage agent must apply pipeline:halted.
# ...
if ! bash "$SCRIPT_DIR/linear.sh" has-label "$ident" "pipeline:halted"; then
  log "post-dispatch: agent did not apply pipeline:halted; applying on its behalf"
  bash "$SCRIPT_DIR/linear.sh" add-label "$ident" "pipeline:halted" || true
fi
```

with a verdict-aware check:

```bash
# Post-dispatch verdict-marker audit:
local fresh_marker; fresh_marker="$(_marker_emission_audit "$ident" "$dispatched_stage_label")"
log "marker-emission-audit: $dispatched_stage_label $ident marker=${fresh_marker:-missing}"

if [[ -n "$fresh_marker" ]]; then
  # Agent emitted a verdict marker. Trust it; verdict_handler will act.
  :
elif ! bash "$SCRIPT_DIR/linear.sh" has-label "$ident" "pipeline:halted"; then
  log "post-dispatch: no verdict marker AND no halt label; applying defensive halt"
  bash "$SCRIPT_DIR/linear.sh" add-label "$ident" "pipeline:halted" || true
fi
```

Where `_marker_emission_audit` is a new helper:

```bash
_marker_emission_audit() {
  local issue="$1" stage="$2"
  local comments last_ts
  comments="$(bash "$SCRIPT_DIR/linear.sh" get-comments "$issue")"
  last_ts="$(jq -r '
    [.[] | select(.body | contains("<!-- pipeline-transition:"))]
    | sort_by(.createdAt) | last | .createdAt // ""' <<<"$comments")"
  local filter
  if [[ -n "$last_ts" ]]; then
    filter="select(.createdAt > \"$last_ts\")"
  else
    filter="."
  fi
  jq -r --arg f "$filter" '
    [.[] | '"$filter"' | .body
      | capture("<!-- pipeline-(?<m>stage-summary|rejection|halt|wait): [a-z-]+ -->") // empty
      | .m]
    | last // ""' <<<"$comments"
}
```

The audit reads Linear comments newer than the most recent transition,
greps for any of the four verdict shapes, returns the most recent shape
or empty. Defensive halt-add only fires when the audit returns empty AND
the halt label isn't already set. The audit log line is unconditional and
metric-shaped for retrospective consumption.

This means:

- **Clean-pass exit** (agent posted `pipeline-stage-summary`): audit
  returns `stage-summary`; defensive halt-add stays its hand;
  verdict-handler picks up the marker and advances the label normally.
  ✅ Fixes ENG-45's third failure if the agent emits the marker.
- **Confabulated exit** (agent posted only `pipeline-sig`, no verdict
  shape): audit returns empty; log line fires (`marker=missing`);
  defensive halt-add applies as today; verdict-handler writes
  `pipeline-halt: protocol-violation` as today. ✅ Behavior preserved
  for the actual failure case, plus the audit log makes the failure
  obvious in metrics.
- **Halt exit** (agent posted `pipeline-halt: ...` and applied the label):
  audit returns `halt`; defensive halt-add stays its hand (the label is
  already set); verdict-handler proceeds. ✅ Behavior unchanged.
- **Rejection exit** (`pipeline-rejection: ...` + halt label): audit
  returns `rejection`; defensive halt-add stays its hand. Behavior
  unchanged for hard rejections.
- **Wait exit** (`pipeline-wait: ...`, no halt label): audit returns
  `wait`; defensive halt-add stays its hand (it explicitly should not
  fire on a wait exit, which is the whole point of the wait gate ENG-45
  introduced upstream of the validator). Behavior preserved.

#### D-C2. Stage-prompt self-verification step

Add to AGENT_PROMPTS.md, in every stage's exit instructions (or once in
the verdict-marker preamble), a self-verification step:

> Before claiming the stage exited cleanly, verify your verdict marker
> is actually in Linear:
>
> ```bash
> bash bin/linear.sh get-comments {issue_id} \
>   | jq -r --arg s "{stage}" '[.[]
>     | .body
>     | select(test("<!-- pipeline-(stage-summary|rejection|halt|wait): " + $s))
>   ] | length'
> ```
>
> If this returns 0, your marker did NOT post. The
> `<!-- pipeline-sig: completion/{stage}/{issue_id} -->` metadata is NOT
> a verdict marker. Verdict markers are
> `pipeline-stage-summary | pipeline-rejection | pipeline-halt | pipeline-wait`.
> Re-post the verdict marker as a separate `bash bin/linear.sh add-comment`
> call before exit.

This shifts the responsibility for catching the confabulation from "the
orchestrator audits and complains afterwards" to "the agent verifies its
own output before claiming success." The orchestrator's audit
(D-C1) is the second line of defense.

#### D-C3. Marker-emission metric

Promote the audit log line to a structured metric event so the
retrospective agent can count `marker_missing` failures across stages
and issues:

```bash
bash "$SCRIPT_DIR/metrics.sh" stage-end "$ident" "$dispatched_stage_label" \
  marker_emitted="${fresh_marker:-missing}" ...
```

A spike in `marker_missing` events on a particular stage is a strong
signal that the prompt for that stage is unclear about marker emission;
retrospective can flag it.

**Rejected alternative:** orchestrator posts the verdict marker on the
agent's behalf when missing. Rejected because: (a) hides the agent's
protocol violation, (b) the orchestrator doesn't know what verdict
the agent intended (pass vs halt vs reject), (c) disincentivizes
prompt-correctness work — the prompt would never get fixed.

**Rejected alternative:** delete defensive halt-add entirely. Rejected
in ENG-45 brainstorm §8.2 because the defense catches genuine silent-crash
exits where the agent terminated mid-write. Track C tightens the defense
without removing it.

## 4. Failure mode → test map

| Failure mode | Test layer | Test case |
|---|---|---|
| `_WAIT_REASONS_BY_STAGE` accepts (build, awaiting-approval) | `bin/run-stage-test.sh` | ENG-47-A1: existing build cases preserved |
| `_WAIT_REASONS_BY_STAGE` rejects (review, awaiting-approval) — review not declared | `bin/run-stage-test.sh` | ENG-47-A2: cross-stage forgery blocked |
| Per-stage budget config: build entry preferred over default | `bin/run-stage-test.sh` | ENG-47-A3: three-tier lookup |
| Per-stage budget config: default fallback when stage not declared | `bin/run-stage-test.sh` | ENG-47-A4 |
| Legacy flat budget shape still works (backwards-compat) | `bin/run-stage-test.sh` | ENG-47-A5 |
| `halt.sh resolve --decision resume` posts transition marker with `(operator-resume)` suffix | `bin/halt-resolve-test.sh` (new) | ENG-47-B1 |
| `count_marker_since_last_transition` returns 0 after resume | `bin/halt-resolve-test.sh` | ENG-47-B2 |
| `find_fresh_verdict` returns empty after resume | `bin/halt-resolve-test.sh` | ENG-47-B3 |
| `wait-{stage}.json` removed after resume | `bin/halt-resolve-test.sh` | ENG-47-B4 |
| `pipeline:skip-until-*` labels removed after resume | `bin/halt-resolve-test.sh` | ENG-47-B5 |
| `issue-state.json` policy=skip-until-human-acts removed after resume | `bin/halt-resolve-test.sh` | ENG-47-B6 |
| `--decision scope-rejected` does NOT post transition marker | `bin/halt-resolve-test.sh` | ENG-47-B7 |
| Defensive halt-add stays hand when agent emitted `pipeline-stage-summary` | `bin/run-stage-test.sh` | ENG-47-C1 |
| Defensive halt-add stays hand when agent emitted `pipeline-wait` | `bin/run-stage-test.sh` | ENG-47-C2 |
| Defensive halt-add applies when no verdict marker AND no halt label | `bin/run-stage-test.sh` | ENG-47-C3 (regression) |
| Defensive halt-add does not double-apply when halt label already set | `bin/run-stage-test.sh` | ENG-47-C4 |
| `marker-emission-audit` log line fires for every dispatch | `bin/run-stage-test.sh` | ENG-47-C5 |
| `_marker_emission_audit` ignores `pipeline-sig` (not a verdict shape) | `bin/run-stage-test.sh` | ENG-47-C6 |
| `_marker_emission_audit` ignores `pipeline-decision` (not a verdict shape) | `bin/run-stage-test.sh` | ENG-47-C7 |
| Regression: ENG-24 reproduction (re-halt within 33s of resume) | end-to-end via test fixture | ENG-47-R1 |
| Regression: ENG-45 confabulated implement halt | `bin/run-stage-test.sh` | ENG-47-R2 |

## 5. Assumption inventory

| Assumption | Status | Evidence |
|---|---|---|
| `bin/halt.sh::resolve` source location is `bin/halt.sh:16-29` | **verified** | `grep -n resolve bin/halt.sh` |
| `bin/halt.sh` exports `PIPELINE_WRITER=human` (line 14) | **verified** | `grep -n PIPELINE_WRITER bin/halt.sh` |
| `bin/guards.sh::count_marker_since_last_transition` resets on new transition marker | **verified** | `bin/guards.sh:42-55`; freshness rule reads `last_ts` of most recent `pipeline-transition` |
| `bin/verdict-handler.sh::find_fresh_verdict` reads "newer than most recent `pipeline-transition`" | **verified** | `bin/verdict-handler.sh:69-127` |
| Defensive halt-add on main is at `bin/run-stage.sh:445-450` | **verified** | `grep -n "agent did not apply" bin/run-stage.sh` |
| Defensive halt-add on ENG-45 branch is at `bin/run-stage.sh:542-545` | **verified** | per ENG-45 brainstorm §8.3 |
| `_fresh_wait_reason` and `_handle_wait` exist on the ENG-45 branch only | **verified** | `git show main:bin/run-stage.sh \| grep -c _fresh_wait_reason` returns 0; ENG-45 branch returns 6 |
| `bash bin/linear.sh stage-of <issue>` exists and returns the current `stage:*` label | **assumed** | called by other scripts; needs verification by `grep -n stage-of bin/linear.sh` during plan stage |
| `bash bin/metrics.sh stage-end` accepts `marker_emitted=...` as a free-form key=value | **verified** by ENG-45 §8.3 | "outcome is a free-form string field, no allow-list at line 67" |
| `pipeline-sig` is NEVER one of the four verdict shapes | **verified** | searched `bin/verdict-handler.sh` and AGENT_PROMPTS.md — `pipeline-sig` is exclusively a dedup metadata key |
| `bin/poll.sh::_poll_classify_labels` else-branch (line 228) returns `slot=hold, advanceable=true` for stage:X + no halt + no fresh marker | **verified** | per ENG-45 brainstorm §8.3 |
| `bash bin/linear.sh add-comment` is append-only (uses `commentCreate`) | **verified** | per ENG-45 brainstorm §8.3 |
| ENG-45 branch's `wait-{stage}.json` files live at `$(issue_dir)/wait-${stage}.json` | **verified** | per ENG-45 brainstorm §D-004 |

## 6. Risks

**R1.** The new operator-attributed transition marker could be confused
for an agent emission by a future tool that doesn't read the body.
*Mitigation:* the `(operator-resume)` suffix is in the body, parseable by
any consumer that cares; for the existing freshness rule, agent-vs-operator
attribution doesn't matter (transitions are transitions). ENG-41 lane
fences mean the comment can only be written by `PIPELINE_WRITER=human`,
which is structurally true for `halt.sh`.

**R2.** Generalizing `pipeline-wait` to other stages could enable abuse
(an agent on review or qa using wait to dodge a real halt).
*Mitigation:* the per-stage→reasons allow-list keeps the security property
ENG-45's build-only gate provided. Only explicitly-declared (stage, reason)
pairs are accepted; everything else returns 1 and the wait gate doesn't
fire.

**R3.** Tightening defensive halt-add could regress on real protocol
violations (an agent that segfaults mid-write before posting any marker).
*Mitigation:* the trust criterion is "verdict marker present in Linear,
not just in narration or stage-summary file" — same check verdict-handler
uses, just earlier in the flow. Silent-crash agents won't post any marker
and will still trip defensive halt-add. Tested via ENG-47-C3 regression
case.

**R4.** Agents seeing the new self-verification step (D-C2) might
"verify" by parsing their own narration rather than calling Linear
(the same kind of confabulation that caused F3).
*Mitigation:* the self-verification text explicitly invokes a `bash`
command, and it's followed by the orchestrator's audit (D-C1) that
inspects Linear directly. Belt-and-suspenders. The audit is the
load-bearing check; self-verification is a hint.

**R5.** Track A's stage→reasons map is a global declaration; a typo
silently disables wait for a stage. *Mitigation:* test ENG-47-A1
exercises the existing build entries; any future stage addition gets a
matching test case.

**R6.** Track B's `--decision scope-rejected` deliberately keeps the
halt marker fresh; an operator who runs scope-rejected and then changes
their mind to resume will need to run resume too. *Acceptable* — this is
a state-machine choice, documented in D-B3.

## 7. Implementation roadmap

The three tracks are independent. Suggested ordering (smallest blast
radius first):

1. **Track B** (atomic operator resume). `bin/halt.sh` + new
   `bin/halt-resolve-test.sh`. Cleanest immediate win — unblocks ENG-24
   the moment it lands. ~50 LOC + tests.
2. **Track C** (marker-emission compliance). `bin/run-stage.sh`
   defensive halt-add tightening + new `_marker_emission_audit` helper +
   AGENT_PROMPTS.md preamble update. ~80 LOC + tests + prompt diff.
3. **Track A** (pipeline-wait generalization). `bin/run-stage.sh`
   `_fresh_wait_reason` + `_handle_wait` updates + config schema change +
   AGENT_PROMPTS.md preamble. ~30 LOC + tests + config diff. **Depends on
   ENG-45 having merged** — Track A modifies functions that don't exist
   on main yet.

If Tracks B and C land before ENG-45 merges, Track A's File Structure
references functions that aren't on the base. The plan stage should
sequence the work so Track A starts after ENG-45 lands, OR the plan
should explicitly target ENG-45's merge commit as the base for Track A.

The three tracks can ship as three separate commits within one PR
(sequenced B → C → A), or as three separate PRs. The plan stage decides.

## 8. Codebase-fact verification

Every named code artifact in this brainstorm is grounded:

| Name | Quoted location |
|---|---|
| `bin/halt.sh::resolve` | `bin/halt.sh:16-29` |
| `bin/halt.sh::main` | `bin/halt.sh:31-48` |
| `bin/halt.sh` `PIPELINE_WRITER=human` export | `bin/halt.sh:14` |
| `bin/guards.sh::count_marker_since_last_transition` | `bin/guards.sh:42-55` |
| `bin/guards.sh::check` | `bin/guards.sh:57-` |
| `bin/verdict-handler.sh::find_fresh_verdict` | `bin/verdict-handler.sh:69-127` |
| `bin/run-stage.sh::main` defensive halt-add (main) | `bin/run-stage.sh:445-450` |
| `bin/run-stage.sh::main` defensive halt-add (ENG-45 branch) | `bin/run-stage.sh:542-545` |
| `bin/run-stage.sh::_fresh_wait_reason` (ENG-45 branch only) | `bin/run-stage.sh:302-` |
| `bin/run-stage.sh::_handle_wait` (ENG-45 branch only) | `bin/run-stage.sh:338-` |
| `bin/poll.sh::_poll_classify_labels` else-branch | `bin/poll.sh:228` |
| `bin/linear.sh::add-comment` | `bin/linear.sh::add_comment` standalone function |
| `bin/linear.sh::stage-of` | `bin/linear.sh` (assumed; verify in plan stage) |
| `AGENT_PROMPTS.md` "Non-verdict markers" preamble (ENG-45 branch only) | `AGENT_PROMPTS.md` (introduced by ENG-45's `f59acf8` commit) |
| `~/.pipeline-config/config.json::orchestrator` block | `${TARGET_REPO}/.pipeline-config/config.json` |

## 9. Open questions

**Q1.** Should `--decision scope-rejected` advance the stage to
`stage:abandoned` automatically, or leave that to the operator? Today
neither path is clean (`pipeline:abandoned` is a label, not a stage).
*Recommendation:* leave it to the operator for now (status quo); revisit
if scope-rejected is used frequently enough to justify automation.

**Q2.** Should the marker-emission audit (D-C1) also fire for
`pipeline-decision` shapes (which are not verdict markers but are
emitted by `halt.sh`)? *Recommendation:* no — the audit is specifically
about agent-emitted verdict markers; `pipeline-decision` is operator
authority and follows a different path.

**Q3.** Does the marker-emission metric (D-C3) need a new outcome
literal, or can `marker_emitted=true|false|missing` ride on the existing
free-form key=value space? *Verified per ENG-45 §8.3:* the metric outcome
is a free-form string with no allow-list, so a new key is fine without
schema change. Same answer for the `marker_emitted` field.

**Q4.** Should `bin/halt.sh resolve --decision resume` emit a Slack
notification (operator-driven recovery is a meaningful event)? *Out of
scope here* — file as a separate small ticket if useful.
