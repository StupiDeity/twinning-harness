---
linear: ENG-74
title: build agent wait-exit fails — `PIPELINE_WRITER=agent bash bin/pipeline.sh ...` rejected by sandbox allowlist
date: 2026-05-07
status: draft
---

# ENG-74 — Build agent wait-exit fails when the agent prepends `PIPELINE_WRITER=agent` to its `bash bin/pipeline.sh ...` invocation

## 1. Problem

ENG-64's build-stage dispatch on 2026-05-05 22:47Z ran preflight cleanly:
P1, P3, P4, P5, P6, P7 all PASS; P2 FAIL (no human Code Owner approval —
only bot `twinning-pipeline` reviews exist on PR #54). Per the ENG-45
contract this is the documented `wait-exit (awaiting-approval)` path:
emit `verdict wait --reason awaiting-approval` and exit so the
orchestrator re-dispatches on the next tick.

The dispatched agent attempted:

```
PIPELINE_WRITER=agent bash bin/pipeline.sh event ENG-64 verdict wait --reason awaiting-approval
```

The Claude sandbox returned a permission denial. Per the universal
agent-policy clause at `AGENT_PROMPTS.md:1232` ("If a Bash invocation
fails with a permission denial, the pattern is NOT allowed — do NOT
post throwaway Linear comments [...] to verify other patterns"), the
agent did not retry. It summarised findings, asked for human guidance,
and exited rc=0 with no `stage-summary-building.md` written. The
no-output detector at `bin/run-stage.sh:846-857` then classified it
as `agent-failure` ("agent dispatch returned 0 but emitted no
stage-summary file and no verdict marker"), exit 25, and the
post-dispatch hook at `bin/run-stage.sh:376-388` applied
`pipeline:halted`.

### 1.1 Root cause — sandbox allowlist matcher anchors on the first token

The build-stage allowlist at `bin/dispatch.sh:252` contains
`Bash(bash bin/pipeline.sh:*)` (and the `.pipeline/` symlink twin).
The agent's invocation prepends an env-var assignment
(`PIPELINE_WRITER=agent`) before `bash`. Claude Code's allowlist
matcher anchors on the FIRST token of the command line — here the
first token is `PIPELINE_WRITER=agent`, not `bash`. The pattern
`Bash(bash bin/pipeline.sh:*)` does not match `PIPELINE_WRITER=agent
bash bin/pipeline.sh ...`. (Same general failure mode as ENG-65's
`Bash(bash bin/*-test.sh:*)` glob disconnect, but here the pattern
itself is fine — only the env-var prefix breaks the anchor.)

The agent has no way to suppress, retest, or work around the prefix
mismatch from inside the sandbox. The cleanest exit ramp would have
been the documented `verdict halt --reason agent-blocked`, but the
agent reasoned (correctly per the prompt) that the wait-exit path
was the right path and stopped at the denied invocation.

### 1.2 Why the agent thought it needed the prefix

`bin/linear.sh::_check_lane` (at `bin/linear.sh:120-145`) reads
`${PIPELINE_WRITER:-orchestrator}` and gates writes by lane. The
agent reasoned: "I'm the agent; I need to set the agent lane;
therefore prefix the command." Defensive over-provisioning, not
strictly wrong, but the env-var prefix runs into the sandbox
matcher.

In practice this prefix is **redundant**: `bin/dispatch.sh:361`
already wraps the `claude -p` subprocess with
`env PIPELINE_WRITER=agent ...`, so `PIPELINE_WRITER=agent` is
inherited into every shell the agent spawns. The agent cannot
observe this directly without running a Bash test (which itself
needs an allowlisted pattern), so it falls back to the over-cautious
prefix.

### 1.3 Why this hits §7 specifically (build, not implement / ui / etc.)

Build is the only stage where `verdict wait` is allowed (per
`AGENT_PROMPTS.md:58-60` and registered in `bin/pipeline-events.json`
as `awaiting-approval | awaiting-ci`). The wait path is also the
only path where the prompt steers the agent into the lane-aware
mental model — the wait-exit instructions at
`AGENT_PROMPTS.md:1281-1302` and `:1322-1339` mention the lane
indirectly (the post-wait informational comment must include
`tick_at: $(date ...)` to defeat dedup, etc.), so the agent reads
those, reasons about lanes, and adds the `PIPELINE_WRITER=agent`
prefix when it would never have done so for `verdict pass --stage X`
or `verdict halt --reason Y`.

That said, the failure mode is **stage-agnostic in principle**: any
agent in any stage that reasons "I should set the lane" would hit
the same matcher. Build is just the empirically observed instance.

### 1.4 Why this is reproducible on every issue that reaches build

Every build dispatch on every issue that hasn't been human-approved
yet hits the P2 wait-exit path. So this halt is reproducible on
every issue that reaches build pre-approval. The recovery cost is
small (one operator click to approve + one
`pipeline.sh decide --action continue`), but the breaker risk is
real: 3 consecutive build halts on three different issues, each
with no human approval at the time of the build dispatch, will
trip `.consecutive-failures ≥ 3` and pause the orchestrator.

### 1.5 Why this is P3, not P2

Workaround is straightforward: human approves the PR (the actual
gate the agent is waiting on), then `decide --action continue` to
clear the halt. Net cost: one operator action + one CLI command per
halted issue. ENG-64 is in this state right now. Not blocking
architecturally — just adds a halt cycle per issue per build approval
window and risks tripping the breaker on bursts.

## 2. Decisions

### D-001. Prompt-content rule: forbid env-var prefixes on harness invocations

Add an explicit instruction to the universal "Tool allowlist & probing"
paragraph that is replicated in every stage's fenced block (§§1–9 of
`AGENT_PROMPTS.md`). The new sentence:

> **Do NOT prepend env-var assignments** (e.g. `PIPELINE_WRITER=agent`,
> `LINEAR_API_KEY=...`) **to your `bash bin/...` invocations.** The
> sandbox allowlist matcher anchors on the FIRST token of the command
> line; an env-var assignment is not `bash`, so the
> `Bash(bash bin/pipeline.sh:*)` / `Bash(bash bin/linear.sh:*)`
> patterns fail to match. The orchestrator already exports
> `PIPELINE_WRITER=agent` into your dispatch environment (see
> `bin/dispatch.sh::main`), so the prefix is redundant AND
> unmatchable. Run `bash bin/pipeline.sh event ...` and
> `bash bin/linear.sh ...` directly.

The sentence lands in the "Common allowlist-parser pitfalls" half of
the existing paragraph (right after the `$(cmd)` / backticks /
heredoc guidance), so it composes with the family of allowlist
matcher gotchas already documented there.

**Why this lives in the universal paragraph (not §7-only).** The
defect is matcher-shape, not stage-shape. Build is the empirical
hit because of the wait-exit lane reasoning (§1.3), but any future
stage prompt that nudges the agent to think about lanes — or any
agent that defensively over-provisions — would trip the same
matcher. The "Tool allowlist & probing" paragraph is already
replicated across §§1–9 (test-pinned at
`bin/agent-prompts-content-test.sh:216-249`), so adding one
sentence is uniform and enforceable.

**Why this is enough on its own.** The agent already reads the
"Tool allowlist & probing" paragraph at the top of every stage
prompt; it lives in the same prose neighbourhood as the other
allowlist-matcher gotchas. The defensive PIPELINE_WRITER reasoning
is a one-shot mental error — once the prompt names the gotcha
explicitly, the agent has the correct answer in working memory
when it reaches the wait-exit instruction. No code path is left
uncovered.

**Linkage to product principle.** The harness's load-bearing rule
("If you cannot accomplish your task with the documented tools,
run `verdict halt --reason agent-blocked` and exit; do not probe.")
already forbids workarounds when the documented tools fail. The
defect is upstream — the agent's invocation **was** documented but
ran into a sandbox-syntax oversight. D-001 closes the gap so the
documented invocation actually matches the allowlist, restoring
the load-bearing property.

**Rejected alternative A — scope to §7 only.** As the Linear issue
itself proposed. Rejected: same fix cost, narrower coverage. The
universal-paragraph approach test-pins the rule in 9 stages with
the same loop the existing tests already use; per-section custom
text is more lines than needed.

**Rejected alternative B — render-time banner injecting
`PIPELINE_WRITER is already set in your environment to '$PIPELINE_WRITER'`
(the issue's "defense-in-depth" suggestion).** Rejected: requires
modifying `bin/render-prompt.sh` or `bin/dispatch.sh` to inject
runtime values into the prompt; introduces a new dynamic-prompt
surface that needs its own test fixture. The prompt-text rule
covers the same ground at zero new infrastructure cost. Reconsider
if the prompt-text rule alone proves insufficient (e.g., a future
incident shows agents still reasoning their way to the prefix).

**Rejected alternative C — extend `dispatch.sh::allowed_tools_for`
to also match `Bash(env PIPELINE_WRITER=agent bash bin/pipeline.sh:*)`.**
Rejected: (i) it is not established that the Claude allowlist
syntax even supports a leading `env VAR=val` token in the pattern;
(ii) even if it did, blessing the redundant prefix institutionalises
the agent's wrong mental model. Better to teach the agent not to
do it.

### D-002. Test pin: `bin/agent-prompts-content-test.sh`

Extend `bin/agent-prompts-content-test.sh` with a per-stage assertion,
matching the existing ENG-53 #11 / ENG-57 multi-stage iteration loop
at lines 216-249. New assertion (positive): every stage section
(§§1–9) contains the substring `Do NOT prepend env-var assignments`
(or a stable distinguishing fragment), and the substring
`PIPELINE_WRITER=agent` is present in the same paragraph (negative
example). Mirrors the existing pattern of "rule + canonical example
of the forbidden form" used by the branch-name-convention pin at
lines 419-451.

**Why a test pin.** The retrospective agent edits prompts via
`learned-rules/<stage>.md`, but it CAN edit the AGENT_PROMPTS.md
fenced blocks directly during retrospective passes (per
`AGENT_PROMPTS.md` §9). A future cleanup pass could remove the
new sentence in pursuit of brevity; the pin makes the regression
loud (test fail) instead of silent (failure-mode reintroduced).
This is the same rationale the existing assertions cite (e.g.,
ENG-53 #11 multi-stage probe-rule pin, ENG-57 sig-mutation pin).

**Why per-stage assertion (not a single-grep at file scope).** The
iteration loop is the established pattern in this test file for
"every stage must carry rule X" — losing the rule from one stage
section is the failure mode the test is supposed to catch.

### D-003. Operator-recovery for the in-flight ENG-64 instance

ENG-64 is currently halted in build with the symptom described.
Recovery follows the standard ENG-58 atomic-resume protocol:

1. Operator approves PR #54 in GitHub (the actual gate the agent
   was waiting on).
2. Operator runs:
   ```
   bash bin/pipeline.sh decide ENG-64 --action continue
   ```
3. Next tick: P2 now sees a non-bot APPROVED review, the agent
   merges, and the pipeline advances to released.

No code change required for the recovery itself — D-003 just notes
that the standard `--action continue` primitive is the correct
operator response.

### D-004. Explicit non-changes (scope discipline)

- `bin/dispatch.sh::allowed_tools_for`: unchanged. The build-stage
  allowlist already covers `Bash(bash bin/pipeline.sh:*)` via both
  the `.pipeline/` and the bare `bin/` paths
  (`bin/dispatch.sh:252`); the matcher's first-token anchor is the
  matter, not the pattern itself.
- `bin/run-stage.sh::_handle_wait` and `_fresh_wait_reason`:
  unchanged. The wait-exit pipeline contract (ENG-45) is correct;
  the bug lives in the agent's invocation shape, not in the
  orchestrator's interpretation of the marker it never received.
- `bin/render-prompt.sh`: unchanged. No new render-time prompt
  injection (rejected D-001 alt B).
- `bin/pipeline.sh` and `bin/linear.sh`: unchanged. The lane fence
  is correct as-is; agents inherit the right lane via
  `dispatch.sh::main`'s `env PIPELINE_WRITER=agent` wrapper.
- `learned-rules/harness/build.md`: not modified. The new prompt
  rule applies to every stage, not just build; learned-rules are
  stage-specific addenda. Putting an "all stages" rule in a single
  stage's learned-rules file would be misplaced. (See ADR stress
  test in §8.1 for how this fits prior art.)
- `docs/runbooks/recovery.md`: unchanged. The PIPELINE_WRITER=human
  prefix that recovery.md instructs operators to use is OUT OF
  SCOPE — operators run from their own shell, outside the agent
  sandbox, where the matcher does not apply.
- No changes to `bin/agent-prompts-content-test.sh` beyond adding
  the new assertion stanza.

### D-005. Fail mode of the rule is "agent reads prompt and complies"

There is no enforcement mechanism beyond prompt-text + test pin.
A future agent that reasons its way back to the prefix despite the
rule will fail the same way as today. Two mitigations:

1. **Training-data drift safety net.** D-002's test pin makes the
   rule survive future prompt edits, so the rule itself doesn't
   rot.
2. **Same failure mode is recoverable.** If a regression slips
   through, the symptom is identical to today (sandbox denial,
   agent-failure halt, operator runs `--action continue` after
   approving). The harness's documented `agent-blocked` exit ramp
   would let the agent halt cleanly instead of silently exiting
   rc=0; the agent's failure to use that ramp here is a separate
   prompt-conformance question (the agent stopped at the denial
   per the existing rule, but didn't escalate to halt). That
   higher-order observation is **flagged for follow-up** in §7
   open questions; not in scope for ENG-74's narrow framing.

## 3. Architecture

### 3.1 Files modified

| File | Change |
| --- | --- |
| `AGENT_PROMPTS.md` | One new sentence appended to the "Common allowlist-parser pitfalls" half of the universal "Tool allowlist & probing" paragraph, replicated in every stage section (9 spots: lines 246, 361, 567, 714, 855, 1068, 1232, 1483, 1595). Each spot gets the same text. |
| `bin/agent-prompts-content-test.sh` | Add an iteration loop modelled on the ENG-53 #11 multi-stage probe-rule loop at lines 216-249. Asserts `Do NOT prepend env-var assignments` substring is present in each of the 9 stage sections. |

### 3.2 Prompt-text edit shape

Each of the 9 occurrences gets the same insertion. The current
sentence neighbourhood (e.g., `AGENT_PROMPTS.md:1232`):

> Common allowlist-parser pitfalls: `$(cmd)` and backticks inside
> Bash arguments are rejected — pass argument values as literal
> text, and pipe multi-line bodies via stdin (ENG-55): [...]

The patched neighbourhood:

> Common allowlist-parser pitfalls: `$(cmd)` and backticks inside
> Bash arguments are rejected — pass argument values as literal
> text, and pipe multi-line bodies via stdin (ENG-55): [...].
> **Do NOT prepend env-var assignments** (e.g. `PIPELINE_WRITER=agent`,
> `LINEAR_API_KEY=...`) **to your `bash bin/...` invocations** —
> the matcher anchors on the FIRST token of the command line, and
> an env-var assignment is not `bash`, so the
> `Bash(bash bin/pipeline.sh:*)` / `Bash(bash bin/linear.sh:*)`
> patterns fail to match. The orchestrator already exports
> `PIPELINE_WRITER=agent` for your dispatch via `bin/dispatch.sh::main`;
> the prefix is redundant AND unmatchable.

The sentence is wedged between the existing heredoc guidance and
the existing scratch-files-leak guidance, preserving the rest of
the paragraph verbatim. Total addition: ~5 lines × 9 sections =
~45 lines.

### 3.3 Test edit shape

Append to `bin/agent-prompts-content-test.sh` (after the existing
ENG-57 `retry with the same sig` loop at lines 294-325, before the
ENG-55 `--body -` heredoc loop at line 337):

```bash
# ─── ENG-74: env-var-prefix rule (PIPELINE_WRITER=agent must NOT be
# prepended to bash bin/... invocations from inside the agent sandbox).
# The Claude allowlist matcher anchors on the first token; an env-var
# assignment is not `bash`, so the Bash(bash bin/pipeline.sh:*) pattern
# fails to match a `PIPELINE_WRITER=agent bash bin/pipeline.sh ...`
# invocation. ENG-64's build dispatch on 2026-05-05 hit this exact case;
# pin the rule per-stage so a future prompt edit can't drop it from one
# stage and silently regress.
for stage_section in \
  "## 1. Brainstorm Agent" \
  "## 2. Plan Agent" \
  "## 3. Implementation Agent (Backend)" \
  "## 4. UI Agent (Frontend)" \
  "## 5. Review Agent" \
  "## 6. QA Agent" \
  "## 7. Build Agent" \
  "## 8. Release Agent" \
  "## 9. Retrospective Agent (Scheduled)"; do
  body="$(section_body "$stage_section")"
  short="${stage_section## }"

  if printf '%s\n' "$body" | grep -qF 'Do NOT prepend env-var assignments'; then
    ok "$short contains env-var-prefix rule (ENG-74)"
  else
    nope "$short contains env-var-prefix rule (ENG-74)" "phrase missing"
  fi

  if printf '%s\n' "$body" | grep -qF 'PIPELINE_WRITER=agent'; then
    ok "$short names the canonical forbidden prefix PIPELINE_WRITER=agent (ENG-74)"
  else
    nope "$short names the canonical forbidden prefix PIPELINE_WRITER=agent (ENG-74)" \
         "agent must see the exact forbidden form, not just a prose hint"
  fi
done
```

This shape matches the existing per-stage iteration loops (positive
phrase + canonical-name pin), so it composes cleanly with the rest
of the file. No new fixture or stub infrastructure.

## 4. Data flow

### 4.1 Happy path (post-fix, build dispatched on a not-yet-approved PR)

```
launchd tick N
  poll.sh: ENG-X has stage:building, no halt label, no fresh verdict
    → _poll_classify_labels else branch (poll.sh:265-267) → advanceable=true
    → emit decision (ENG-X, building, run)

run-stage.sh ENG-X building
  → verify_preconditions → 0
  → render-prompt.sh extracts §7 fenced block (now containing D-001's rule)
  → dispatch.sh wraps with `env PIPELINE_WRITER=agent ...`, invokes claude -p

agent reads §7 fenced prompt:
  - sees "Tool allowlist & probing" paragraph (with D-001's new sentence)
  - reaches P0 (merge precheck) → state != MERGED → proceed
  - P1 pass, P3-P7 pass, P2 fail (no non-bot APPROVED review)
  - reaches P2 wait-exit instructions
  - executes: bash bin/pipeline.sh event ENG-X verdict wait --reason awaiting-approval
    (NO PIPELINE_WRITER=agent prefix, per D-001)
  - sandbox matches Bash(bash bin/pipeline.sh:*) — invocation succeeds
  - pipeline.sh validates registry, posts <!-- pipeline: verdict result=wait reason=awaiting-approval --> via linear.sh add-comment
  - agent emits informational comment via linear.sh add-comment heredoc (ENG-55), exits

run-stage.sh post-dispatch:
  - _fresh_wait_reason returns "awaiting-approval"
  - _post_dispatch_apply_halt detects wait shape, skips pipeline:halted apply
  - _handle_wait increments per-issue counter, returns within budget
  - exit 0; orchestrator re-dispatches on next tick

next tick (same state) → re-dispatch → same loop, until either:
  (a) Code Owner approval lands → P2 passes → agent merges → released
  (b) external_signal_budget exhausted → escalate to halt-for-human
```

The path is unchanged from the ENG-45 contract — D-001 just removes
the prefix that breaks step "executes: bash bin/pipeline.sh ...".

### 4.2 Pre-fix path (today, the failure case from §1)

```
agent reaches P2 wait-exit instructions:
  - executes: PIPELINE_WRITER=agent bash bin/pipeline.sh event ENG-64 verdict wait --reason awaiting-approval
  - sandbox does NOT match (first token is PIPELINE_WRITER=agent, not bash)
  - permission denied
  - agent (per universal probe-rule) does NOT retry, does NOT mutate the command
  - agent summarises and exits rc=0 with no stage-summary, no marker

run-stage.sh post-dispatch:
  - agent-contract validator (run-stage.sh:846-857) detects no summary + no marker
  - classify_failure as retry-immediately, exit 25
  - .consecutive-failures incremented
  - _post_dispatch_apply_halt applies pipeline:halted (no fresh wait verdict to detect)
  - operator must approve PR + run `--action continue` to recover
```

### 4.3 In-flight migration (ENG-64 specifically)

ENG-64 is currently in state §4.2's "operator must recover". When
this fix lands:

1. The fix itself does not auto-recover ENG-64 — `pipeline:halted`
   is already on the issue, `poll.sh` vacates it (no dispatch).
2. Operator follows D-003's two-step (approve PR + `--action
   continue`). On the next tick, ENG-64 re-dispatches against the
   patched prompt; P2 now sees a non-bot APPROVED review (the
   approval the operator just landed) and merges directly — wait
   path is not exercised on ENG-64's recovery cycle.
3. The next issue that enters build pre-approval (some future
   ENG-Y) exercises §4.1's happy path against the patched prompt.

No data migration; no schema change; no learned-rules change.

## 5. Error handling

- **Agent emits the prefix despite the rule (regression, training-data
  drift).** Same observable failure as today (§4.2). Operator-recovery
  cost unchanged. Retrospective should catch the regression in the
  next cycle — D-002's test pin would have already failed in CI before
  the regression shipped, so this case implies the test was bypassed
  or removed.
- **Agent reads the rule, omits the prefix, but the invocation still
  fails for a different reason (e.g., `bin/pipeline.sh` itself errors,
  Linear outage).** Falls into the existing
  `bin/pipeline.sh::cmd_event_verdict` error path: nonzero rc bubbles
  up to the agent, who can retry (Linear outage) or halt-for-human
  (`bin/pipeline.sh` self-error). Unchanged from today.
- **Agent reasons that some OTHER env-var prefix is needed (e.g.,
  `LINEAR_API_KEY=...`).** The new sentence covers this case
  generically by listing both `PIPELINE_WRITER=agent` and
  `LINEAR_API_KEY=...` as canonical examples. The matcher anchor
  applies to any leading `VAR=value` token.
- **Operator runs the recovery from their own shell (not from the
  agent sandbox).** D-001 explicitly scopes the rule to the agent's
  dispatch environment. Operator commands like
  `PIPELINE_WRITER=human bash bin/linear.sh remove-label ...`
  (per `docs/runbooks/recovery.md:53`) remain untouched and
  required. The rule's wording ("your dispatch environment...
  via `bin/dispatch.sh::main`") names the agent context explicitly.
- **Test bypass during emergency edit.** `pre-commit` hook runs the
  test suite; if the new assertion fires on an unrelated edit
  (e.g., a stage prompt rewrite that drops the sentence), the
  hook blocks the commit. Bypass via `--no-verify` would let it
  through — same concern as every other pre-commit check; not
  unique to ENG-74.

## 6. Edge cases

- **A stage prompt is added in the future (a 10th agent).** D-002's
  iteration loop names §1–§9 explicitly. A 10th stage would not be
  covered until the loop is updated. This is the same maintenance
  pattern as the existing ENG-53 #11 / ENG-57 / ENG-55 loops —
  acceptable; if the harness ever grows a 10th stage, all those
  loops need updating in lockstep.
- **A stage prompt's "Tool allowlist & probing" paragraph is
  rewritten and the new sentence lands AFTER (or BEFORE) the
  paragraph rather than inside it.** D-002's grep is body-scoped
  to the section, not paragraph-scoped, so substring presence
  anywhere in the section body counts. Acceptable: the rule
  reaching the agent is what matters, not its exact paragraph
  position.
- **Agent reads the prompt and asks "but `bin/dispatch.sh::main`
  exports PIPELINE_WRITER=agent — can I verify by `echo
  $PIPELINE_WRITER`?"** `Bash(echo:*)` is not in any stage's
  allowlist (per `bin/dispatch.sh:226-263`), so a probe attempt
  would itself fail. The fix is the unconditional rule "do not
  prepend; the orchestrator already set it" — the agent does not
  need to verify.
- **Operator manually dispatches `dispatch.sh` outside
  `run-stage.sh::main` (a recovery one-shot or a debug session).**
  The `env PIPELINE_WRITER=agent` wrapper at
  `bin/dispatch.sh:361` still fires — same export, regardless of
  caller. Rule still holds.
- **`PIPELINE_DRY_RUN=1` runs.** `bin/dispatch.sh:330-336` short-
  circuits before the actual `claude -p` invocation; the agent
  never runs in dry-run, so the rule is never exercised. No
  edge-case interaction.

## 7. Open questions

- **Q1 — Should the agent's fallback to `agent-blocked` be louder
  when a sandbox denial is observed?** Today the agent's universal
  probe-rule says "if a Bash invocation fails with a permission
  denial, the pattern is NOT allowed — do NOT post throwaway Linear
  comments to verify other patterns" (`AGENT_PROMPTS.md:1232`).
  The agent on ENG-64 followed this rule but did NOT escalate to
  `verdict halt --reason agent-blocked` — it exited rc=0 with a
  prose summary. The probe-rule could be tightened to add: "If a
  documented invocation (one called out in this prompt) fails
  with a permission denial, that's an `agent-blocked` halt — do
  not silently exit." This is a separate prompt-conformance
  question, not strictly needed for ENG-74's fix, but worth
  filing as a follow-up Linear issue. **Action:** file under
  separate ticket title "Agents should escalate to
  `verdict halt --reason agent-blocked` when a documented
  invocation hits a sandbox denial."
- **Q2 — Should `bin/dispatch.sh` log the export of
  `PIPELINE_WRITER=agent` in the per-stage transcript so future
  retrospective archaeology can confirm the agent was actually
  in the right lane at dispatch time?** Today this is implicit
  (read `bin/dispatch.sh:361`, infer the export). A one-line
  `log "dispatch: PIPELINE_WRITER=agent for stage=$stage"` at
  the top of `main()` would surface it. Out of scope for ENG-74;
  flag if the prompt-fix proves insufficient and we need
  evidence of the agent's environment.
- **Q3 — Does the test pin assert against ALL nine stage sections
  including §8 Release and §9 Retrospective?** Yes, per D-002's
  loop. Release and retrospective don't typically post wait
  verdicts, but the rule is matcher-shape (universal), and the
  paragraph is already replicated in those sections per the
  existing ENG-53 #11 loop. Consistency with existing pattern
  wins over scoped-to-relevant-stages.

## 8. Anti-bias checks

### 8.1 ADR / prior-art stress test

The harness has no `docs/knowledge/decisions.md`; the closest
analogues are prior brainstorms.

- **`2026-04-30-eng-49-harness-productionization-design.md`**
  (ENG-49) — established the universal "Tool allowlist & probing"
  paragraph that D-001 extends. The paragraph was written
  specifically to handle agent-side allowlist confusion; this
  brainstorm appends one more known gotcha to a designed-for-this
  surface, not introducing a new one.
- **`2026-05-03-eng-65-brainstorm-wall-clock-timeout-...-design.md`**
  (ENG-65) — surfaced a similar matcher disconnect for
  `Bash(bash bin/*-test.sh:*)` glob patterns. ENG-65 fixed the
  pattern (config-side); ENG-74 fixes the invocation shape
  (prompt-side). The two sit on opposite sides of the same matcher
  and don't conflict.
- **`2026-04-28-build-agent-soft-preconditions-p2-p5-should-re-dispatch-not-halt-for-human-design.md`**
  (ENG-45) — defined the wait-marker contract this brainstorm
  preserves. D-001 lets the wait verdict actually post; the
  contract behind it is unchanged.
- **`2026-05-06-eng-62-build-p2-still-emits-awaiting-approval-...-design.md`**
  (ENG-62) — added P0 merge-state precheck to §7 and the
  symmetric `_pre_dispatch_merge_gate` orchestrator gate. ENG-74
  is downstream of ENG-62 in the §7 prompt flow: merge precheck
  runs first, then if state != MERGED the agent reaches the
  P1-P7 evaluation that may produce the wait-exit. ENG-74's fix
  doesn't touch ENG-62's P0; both can ship independently.
- **ENG-53 #11 / ENG-57 / ENG-55** — established the per-stage
  iteration-loop test pattern that D-002 reuses. Test will look
  identical in shape to what's already there.
- **`docs/runbooks/recovery.md`** — operator-side
  `PIPELINE_WRITER=human` prefix usage. Out of scope for ENG-74;
  D-001 is explicitly scoped to the agent's dispatch context.

**Tradeoff surfaced.** The universal "Tool allowlist & probing"
paragraph keeps growing — it's now ~150 words including ENG-53,
ENG-55, ENG-57, and ENG-74 guidance. Risk: the paragraph becomes
dense enough that agents skim instead of read. Mitigation: D-001's
sentence is bolded and uses the same `**Do NOT ...**` shape as
the existing ENG-57 `**If add-or-update-comment appears to have
failed, retry with the same sig — never mutate it (ENG-57).**`
sentence — visually consistent with the rest of the paragraph's
high-priority callouts. If the paragraph length becomes its own
problem in a future incident, factor into a dedicated "Sandbox
allowlist gotchas" subsection — out of scope here.

### 8.2 Simpler alternatives considered

- **A. Scope the rule to §7 only (the issue's proposal).** Rejected
  per D-001: same edit cost, narrower coverage; the matcher gotcha
  is stage-agnostic.
- **B. Render-time banner injecting the runtime
  `PIPELINE_WRITER` value into the prompt.** Rejected per D-001:
  introduces a new dynamic-prompt surface; prompt-text rule
  covers the same ground at zero new infrastructure cost.
- **C. Extend the build-stage allowlist to also match
  `Bash(env PIPELINE_WRITER=agent bash bin/pipeline.sh:*)`.**
  Rejected per D-001: blesses the agent's wrong mental model;
  uncertain whether the matcher even supports leading
  `env VAR=val` tokens in patterns.
- **D. Write a learned-rules entry under
  `learned-rules/harness/build.md` instead of editing the prompt.**
  Rejected: learned-rules are stage-specific addenda; the rule
  applies universally. Putting "all stages" guidance in a single
  stage's learned-rules file is misplaced. (Also, the rule is
  test-pinned via D-002; learned-rules are softer and not
  test-pinned.)
- **E. Do nothing — let operators recover via `--action continue`
  on every issue that hits build pre-approval.** Rejected: 3+
  consecutive build halts on different issues during a
  pre-approval burst trips the breaker. Recovery cost compounds.

### 8.3 Assumption inventory

| Assumption | Status | Evidence / Action |
| --- | --- | --- |
| `bin/dispatch.sh::main` wraps the `claude -p` subprocess with `env PIPELINE_WRITER=agent ...` | **verified** | `bin/dispatch.sh:361` (`local cmd=(env PIPELINE_WRITER=agent ...)`). |
| `bin/common.sh` defaults `PIPELINE_WRITER` to `orchestrator` and exports it | **verified** | `bin/common.sh:293-294`. |
| `bin/pipeline.sh::cmd_event_verdict` warns (does not refuse) on `PIPELINE_WRITER != agent` | **verified** | `bin/pipeline.sh:124-131` (`if [[ "$PIPELINE_WRITER" != "agent" ]]; then log "warning: ..."`); the function still calls `linear.sh add-comment`. |
| `bin/linear.sh::_check_lane` reads `${PIPELINE_WRITER:-orchestrator}` and gates writes by lane | **verified** | `bin/linear.sh:120-145`. |
| `add other_comment` (the class verdict markers fall under) allows lanes `orchestrator,agent,classify,scope-check,human` | **verified** | `bin/linear.sh:109` (`"add other_comment") printf 'orchestrator,agent,classify,scope-check,human' ;;`). Means: even if the agent's PIPELINE_WRITER were stuck at `orchestrator`, the verdict comment would still post — the lane fence is not the actual blocker; the matcher is. |
| Build-stage allowlist contains `Bash(bash bin/pipeline.sh:*)` and the `.pipeline/` symlink twin | **verified** | `bin/dispatch.sh:252` (`building) base='Read,Write,Grep,Glob,...,Bash(bash .pipeline/bin/pipeline.sh:*),Bash(bash bin/pipeline.sh:*),...'`). |
| The "Tool allowlist & probing" paragraph appears in every stage section (§§1–9) of `AGENT_PROMPTS.md` | **verified** | grep confirms 9 occurrences at lines 246, 361, 567, 714, 855, 1068, 1232, 1483, 1595. |
| `bin/agent-prompts-content-test.sh` already iterates `## 1. Brainstorm Agent` through `## 9. Retrospective Agent (Scheduled)` for per-stage pinning loops | **verified** | `bin/agent-prompts-content-test.sh:216-249` (ENG-53 #11 probe-rule loop), `:259-281` (ENG-56 `add-label pipeline:halted` absence loop), `:294-325` (ENG-57 same-sig loop). |
| The pre-commit hook runs `bin/agent-prompts-content-test.sh` on every commit | **verified** | `.githooks/pre-commit` runs the entire `bin/*-test.sh` suite per CLAUDE.md "Pre-commit hook" §. |
| `bin/run-stage.sh:846-857` is the no-output detector that classified ENG-64's silent rc=0 exit as `agent-failure` | **verified** | `bin/run-stage.sh:846-857` (the `case "$stage" in brainstorming|planning|implementing|ui|reviewing|qa|building) ...` block; emits exit 25 with `"agent dispatch returned 0 but emitted no stage-summary file and no verdict marker"`). |
| `bin/run-stage.sh:376-388` (`_post_dispatch_apply_halt`) applies `pipeline:halted` after the no-output exit | **verified** | `bin/run-stage.sh:376-388`; the wait-shape carve-out only fires if `_fresh_wait_reason` returns non-empty, which it doesn't here because the wait verdict was never posted. |
| The Linear issue summary's diagnosis of the failure (env-var prefix breaks the matcher) | **verified by inspection** | The matcher's first-token-anchored behaviour is consistent with the issue's described observation; pattern `Bash(bash bin/pipeline.sh:*)` literally starts with `bash`, so a command line whose first token is `PIPELINE_WRITER=agent` cannot match it. |
| `bin/pipeline.sh event` validates verdict tokens against `bin/pipeline-events.json` | **verified** | `bin/pipeline.sh:80-115` (`_validate_registry` is called for verdict_results, stages, halt_reasons, wait_reasons, fail_targets, pivot_targets). Means: the dispatched invocation, once it reaches `bin/pipeline.sh`, is fully validated; the matcher is the only remaining gate. |
| ENG-45 wait-exit contract is the load-bearing protocol the patched prompt should preserve | **verified** | `docs/brainstorms/2026-04-28-build-agent-soft-preconditions-p2-p5-should-re-dispatch-not-halt-for-human-design.md` and §7 P2/P5 wait-exit text at `AGENT_PROMPTS.md:1281-1302` and `:1322-1339`. |
| Adding ~5 lines to each of 9 stage sections does not push any stage's fenced block past `bin/render-prompt.sh`'s extraction limits or break fence counting | **verified** | `bin/render-prompt.sh::extract_block` requires exactly 2 column-0 fences per section; the new sentence is plain prose (no triple-backtick), so fence count is unchanged. No length limit exists on the extractor. |
| `partition_dirty_paths::D-004` requires the basename to contain `eng-N` (case-insensitive) for in-scope bucketing of brainstorm/plan stages | **verified** | `bin/run-local-helpers.sh:140-194`, especially `:182` (`if [[ "$base_lower" =~ (^|[^a-z0-9])${issue_lower_re}([^a-z0-9]|$) ]]`). Brainstorm doc filename `2026-05-07-eng-74-build-agent-...-design.md` contains `eng-74` and is therefore in-scope. |
| The Claude allowlist matcher anchors on the first whitespace-separated token of the command line | **assumed** | Based on the Linear issue's diagnosis and the ENG-65 precedent (matcher-glob disconnect on `Bash(bash bin/*-test.sh:*)`). Not directly inspectable from the harness code (matcher lives inside Claude Code itself). **Action:** confirm during implementation by running a deliberate-prefix dispatch in dry-run mode (the symptom from ENG-64 is itself sufficient evidence in production, but a contained reproduction would lock the assumption). |
| `verdict halt --reason agent-blocked` would have been the documented escape hatch for the ENG-64 agent (§5 Q1 follow-up) | **verified** | `AGENT_PROMPTS.md:1232` (the universal probe-rule paragraph names this exact exit ramp). The agent on ENG-64 did not use it; that is a separate prompt-conformance question and out of scope. |

### 8.4 Codebase-fact verification

Every named code artifact is grounded in the current worktree
(`/Users/rajatgoyal/.local/state/twinning-harness/harness/ENG-74/worktree/`):

| Name | Quoted location |
| --- | --- |
| `bin/dispatch.sh::main` env-var wrapper for `claude -p` | `bin/dispatch.sh:361` (`local cmd=(env PIPELINE_WRITER=agent ...)`) |
| `bin/dispatch.sh::allowed_tools_for` build-stage entry | `bin/dispatch.sh:252` |
| `bin/common.sh` `PIPELINE_WRITER` default + export | `bin/common.sh:293-294` |
| `bin/pipeline.sh::cmd_event_verdict` lane warning | `bin/pipeline.sh:124-131` |
| `bin/pipeline.sh::cmd_event_verdict` registry validation | `bin/pipeline.sh:104-115` |
| `bin/pipeline.sh::cmd_event_verdict` linear.sh add-comment call | `bin/pipeline.sh:138` |
| `bin/linear.sh::_check_lane` | `bin/linear.sh:120-145` |
| `bin/linear.sh::_lane_decision` `add other_comment` row | `bin/linear.sh:109` |
| `bin/run-stage.sh::_post_dispatch_apply_halt` | `bin/run-stage.sh:376-388` |
| `bin/run-stage.sh::_handle_wait` (orchestrator-lane assignment) | `bin/run-stage.sh:397-399` |
| `bin/run-stage.sh::_fresh_wait_reason` (build-only allow-list) | `bin/run-stage.sh:306-360` |
| `bin/run-stage.sh::main` no-output detector (agent-contract validator) | `bin/run-stage.sh:846-857` |
| `AGENT_PROMPTS.md` §7 Build Agent header | `AGENT_PROMPTS.md:1225` |
| §7 P0 merge precheck (post-ENG-62) | `AGENT_PROMPTS.md:1249-1267` |
| §7 P1 (one open PR) | `AGENT_PROMPTS.md:1269-1273` |
| §7 P2 (non-bot APPROVED review) + wait-exit instructions | `AGENT_PROMPTS.md:1274-1302` |
| §7 P5 (CI green) + wait-exit instructions | `AGENT_PROMPTS.md:1312-1343` |
| §7 precondition-ordering clause (ENG-45 / ENG-62) | `AGENT_PROMPTS.md:1242-1247` |
| Universal "Tool allowlist & probing" paragraph (top of every stage's fenced block) | `AGENT_PROMPTS.md:246, 361, 567, 714, 855, 1068, 1232, 1483, 1595` (9 occurrences) |
| Universal probe-rule prose ("If a Bash invocation fails with a permission denial...") | `AGENT_PROMPTS.md:1232` (representative; same prose at all 9 sites) |
| `bin/agent-prompts-content-test.sh` ENG-53 #11 multi-stage iteration loop (probe-rule pin) | `bin/agent-prompts-content-test.sh:216-249` |
| `bin/agent-prompts-content-test.sh` ENG-56 multi-stage iteration loop (`add-label pipeline:halted` absence) | `bin/agent-prompts-content-test.sh:259-281` |
| `bin/agent-prompts-content-test.sh` ENG-57 multi-stage iteration loop (same-sig pin) | `bin/agent-prompts-content-test.sh:294-325` |
| `bin/agent-prompts-content-test.sh` ENG-55 stdin-heredoc pin (stages 1–7) | `bin/agent-prompts-content-test.sh:337-353` |
| `bin/agent-prompts-content-test.sh::section_body` helper | `bin/agent-prompts-content-test.sh:20-28` |
| `bin/render-prompt.sh::extract_block` (fence-count contract) | `bin/render-prompt.sh` (per CLAUDE.md "AGENT_PROMPTS.md is load-bearing" §) |
| `bin/run-local-helpers.sh::partition_dirty_paths` D-004 basename-token rule | `bin/run-local-helpers.sh:140-194` (especially `:182`) |
| `bin/pipeline-events.json::wait_reasons` registry (`awaiting-approval`, `awaiting-ci`) | `bin/pipeline-events.json` (referenced in §1.3) |
| `docs/runbooks/recovery.md` operator `PIPELINE_WRITER=human` usage | `docs/runbooks/recovery.md:50, 53, 108, 119, 191, 197, 288, 292, 293, 307` |

Predecessor brainstorms used as prior art:

| Name | Path |
| --- | --- |
| ENG-45 (build-agent soft preconditions; wait-marker contract) | `docs/brainstorms/2026-04-28-build-agent-soft-preconditions-p2-p5-should-re-dispatch-not-halt-for-human-design.md` |
| ENG-49 (harness productionization; established the universal "Tool allowlist & probing" paragraph) | `docs/brainstorms/2026-04-30-eng-49-harness-productionization-design.md` |
| ENG-58 (atomic-resume primitive used by D-003) | `docs/brainstorms/2026-05-02-eng-58-halt-sh-resolve-atomic-state-reset-clean-wait-skip-until-rejection-counter-side-state-design.md` |
| ENG-62 (P0 merge-state precheck added to §7; this brainstorm sits downstream of it) | `docs/brainstorms/2026-05-06-eng-62-build-p2-still-emits-awaiting-approval-on-post-merge-dispatches-despite-non-bot-approved-review-existing-design.md` |
| ENG-65 (sister allowlist-disconnect bug for the `Bash(bash bin/*-test.sh:*)` glob) | `docs/brainstorms/2026-05-03-eng-65-brainstorm-wall-clock-timeout-gtimeout-1800s-silently-kills-agents-mid-iteration-needs-per-iteration-budget-or-larger-cap-design.md` |

No referenced item is non-existent or speculative.

## 9. Scope check vs Linear issue

The Linear issue's "Proposed scope" maps to:

- ✅ **Scope item 1 — Prompt fix in §7.** D-001 covers this with a
  scope-widening to all 9 stages. The widening is explicitly
  justified (§1.3, §8.2) — the matcher gotcha is stage-agnostic;
  build is the empirical hit. **Flagged as scope expansion**: the
  Linear issue proposed §7-only; this brainstorm proposes
  universal-paragraph. Implementation cost is 9× the same one-line
  edit; review cost is identical (one diff). Reverting to §7-only
  is trivial if the planning step disagrees.
- ✅ **Scope item 2 — Test pin (cheap).** D-002 covers, mirroring
  the existing ENG-53 #11 multi-stage loop pattern. Per §8.3 / §8.4,
  the test infrastructure already exists; the new stanza is
  ~15 lines of test code.
- ❌ **Scope item 3 — Defense-in-depth banner.** Rejected per D-001
  alt B and §8.2 alt B: introduces a new dynamic-prompt surface;
  the prompt-text rule covers the same ground at zero new
  infrastructure cost. The Linear issue itself flagged this as
  "not required."

OUT-of-scope items (no sprawl):

- ✅ No changes to `bin/dispatch.sh::allowed_tools_for` (per D-004).
- ✅ No changes to `bin/run-stage.sh` (per D-004; wait-exit handler
  is correct as-is, ENG-45 contract preserved).
- ✅ No changes to `bin/pipeline.sh` or `bin/linear.sh` (per D-004;
  lane fence is correct as-is).
- ✅ No changes to `learned-rules/harness/build.md` (per D-004;
  learned-rules are stage-specific addenda, this rule is
  universal).
- ✅ No changes to `docs/runbooks/recovery.md` (operator-side
  prefix usage is out of scope; the rule is scoped to the agent
  sandbox).
- ✅ No new ADR in a (non-existent) `docs/knowledge/decisions.md`
  — this is a small prompt-content rule, not an architectural
  decision. The brainstorm itself is the durable record.

**Pre-existing observation logged for follow-up (NOT in scope):**
The agent's failure path on ENG-64 (silent rc=0 exit instead of
`verdict halt --reason agent-blocked` after a documented invocation
failed) is a separate prompt-conformance question. The universal
probe-rule at `AGENT_PROMPTS.md:1232` says "If you cannot
accomplish your task with the documented tools, run [...] verdict
halt --reason agent-blocked [...] and exit." The agent stopped at
the denial without escalating. **File a separate Linear issue**
rather than bundling here. Recommended title: "Agents should
escalate to `verdict halt --reason agent-blocked` when a documented
invocation hits a sandbox denial." See §7 Q1.

**Verification recipe (post-fix, the next issue that reaches build
pre-approval; call it ENG-Y):**

1. Wait for ENG-Y to reach `stage:building` without a non-bot
   APPROVED review on its PR. Confirm the build agent runs and
   exits the wait path:
   ```
   bash bin/pipeline.sh status ENG-Y
   ```
   Expected event sequence ends with:
   ```
   <ts>  {"event":"verdict","result":"wait","reason":"awaiting-approval"}
   ```
2. Confirm `pipeline:halted` was NOT applied (the wait-shape
   carve-out at `bin/run-stage.sh:376-388` skips it):
   ```
   bash bin/linear.sh has-label ENG-Y pipeline:halted && echo halted || echo OK
   ```
   Expected: `OK`.
3. Confirm the orchestrator re-dispatches on the next tick (the
   wait counter increments in `wait-building.json`):
   ```
   ls $PROJECT_STATE_DIR/ENG-Y/wait-building.json
   jq '.count' $PROJECT_STATE_DIR/ENG-Y/wait-building.json
   ```
   Expected: file exists, count > 0 and increases by 1 per tick.

If step 1 instead shows `agent dispatch returned 0 but emitted no
stage-summary file and no verdict marker`, the rule did not reach
the agent (test-pin regression or training-data drift) — fall
back to D-001's iteration-2 review.

## 10. Persona review

Personas run in canonical order: design → security → scope →
coherence → product → feasibility (gating). All findings recorded;
no P0 remained at the end of iteration 1.

### Iteration 1

#### Persona 1 — Design (PASS, 0 P0)

The fix is the smallest static-prompt change that closes the
behaviour gap. The choice between §7-only and the universal "Tool
allowlist & probing" paragraph is justified explicitly in D-001's
rejected-alternative block (alt A) plus §1.3 (the matcher gotcha is
stage-agnostic; build is the empirical hit). Test pin (D-002) uses
the existing per-stage iteration loop pattern — minimum new
infrastructure.

P2 (suggestion only, not gating): the patched paragraph is now ~150
words and growing on each ENG-N gotcha addition; risk of agents
skimming. Mitigation: D-001's sentence uses the same `**Do NOT ...**`
visual shape as the existing ENG-57 sentence in the same paragraph,
preserving the high-priority-callout rhythm. If paragraph length
becomes its own problem, factor into a dedicated "Sandbox allowlist
gotchas" subsection — flagged in §8.1 as out-of-scope here.

#### Persona 2 — Security (PASS, 0 P0)

D-001 leaves the `bin/linear.sh::_check_lane` enforcement at lines
120–145 unchanged; the `lane=agent` attribution flows through the
inherited env from `bin/dispatch.sh:361`. No new privilege escalation
surface. The rejected alternative C ("extend the allowlist to bless
the prefix") is correctly rejected on multiple grounds, including
that institutionalising leading `env VAR=val` tokens in patterns
opens a class of evasion vectors (an agent could probe for which
prefixes are allowed; the prompt-text rule forecloses the question).

The new sentence is restrictive (forbids an extra shell construct),
not expansive. No new env vars introduced. The rule explicitly
scopes itself to the agent's dispatch context, so the operator-side
`PIPELINE_WRITER=human bash bin/linear.sh ...` usage in
`docs/runbooks/recovery.md` is unaffected.

#### Persona 3 — Scope (PASS, 0 P0)

Issue scope items 1, 2, 3 are addressed: 1 is kept and broadened
(rationale documented at §1.3 / §8.2 alt A / §9); 2 is kept; 3 is
deferred (D-003 / §9). No new helpers, no schema migration, no
orchestrator change, no learned-rules edit, no ADR file change
(harness has none). Two-file diff: `AGENT_PROMPTS.md` plus
`bin/agent-prompts-content-test.sh`.

P2 (already flagged by author): broadening from §7-only to the
universal-paragraph form is technically *outside* the issue's
literal proposal. Rationale documented in §9. The broadening is no
more code than the §7-only version and is strictly more durable.
Reverting to §7-only during planning is trivial if the operator
disagrees.

#### Persona 4 — Coherence (PASS, 0 P0)

The fix composes with ENG-45 (wait-exit contract preserved verbatim),
ENG-56 (orchestrator-managed `pipeline:halted` carve-out at
`bin/run-stage.sh:380-383` still fires correctly when the wait
verdict lands), ENG-41 (lane fence intact), ENG-62 (P0 merge-state
precheck unchanged), ENG-65 (sister allowlist-disconnect bug
addressed analogously). No conflicting rules introduced.

The test-pin shape mirrors `bin/agent-prompts-content-test.sh:216-249`
(ENG-53 #11 probe-rule loop), `:259-281` (ENG-56 absence loop), and
`:294-325` (ENG-57 same-sig loop) exactly — same `for stage_section
in ... do` iteration, same `section_body` helper, same positive-phrase
+ canonical-name pattern. Naming and location choices are consistent
with the precedent set across the existing universal-rule families.

#### Persona 5 — Product (PASS, 0 P0)

User-facing impact: every issue that reaches build without a
pre-existing non-bot Code Owner approval no longer halts spuriously
on the agent's invocation shape. Removes one halt cycle + one
`--action continue` per issue per build pre-approval window.
Aligned with the harness's CLAUDE.md "Failure-mode quick reference"
principle that every halt should be a cheap escape ramp; this fix
preempts a halt class that didn't need to fire in the first place.

The breaker-trip risk on bursts (3+ consecutive build halts on
different issues during a pre-approval window) is real and
disproportionate to the underlying defect. Shipping this fix is
strictly better than letting the breaker tripping become an
operator workflow.

#### Persona 6 — Feasibility (gating, PASS, 0 P0)

Codebase-fact verification (every named code artifact in the doc):

- `bin/dispatch.sh:361` `local cmd=(env PIPELINE_WRITER=agent ...)`
  — **verified by Read**.
- `bin/dispatch.sh:252` `building` allowlist line containing
  `Bash(bash bin/pipeline.sh:*)` plus the `.pipeline/` symlink twin
  — **verified**.
- `bin/common.sh:293-294` PIPELINE_WRITER default + export
  — **verified**.
- `bin/pipeline.sh:124-131` lane-mismatch warning in
  `cmd_event_verdict`; line 138 calls `linear.sh add-comment`
  unconditionally — **verified**.
- `bin/pipeline.sh::_validate_registry` calls at lines 91 / 105 /
  107 / 109 / 111 / 112 — **verified**.
- `bin/linear.sh:120-145` `_check_lane` reads
  `${PIPELINE_WRITER:-orchestrator}` — **verified**.
- `bin/linear.sh:109` `add other_comment` row allows
  `orchestrator,agent,classify,scope-check,human` — **verified**.
- `bin/run-stage.sh:376-388` `_post_dispatch_apply_halt` with
  wait-shape carve-out — **verified**.
- `bin/run-stage.sh:397-399` `_handle_wait` orchestrator-lane
  assignment — **verified**.
- `bin/run-stage.sh:306-360` `_fresh_wait_reason` build-only
  allow-list — **verified**.
- `bin/run-stage.sh:846-857` no-output detector (the agent-contract
  validator that classified ENG-64's silent rc=0 as `agent-failure`,
  exit 25, with the literal message `"agent dispatch returned 0 but
  emitted no stage-summary file and no verdict marker"`) —
  **verified**.
- `AGENT_PROMPTS.md:47-93` shared "Verdict-marker protocol" section
  — **verified**.
- `AGENT_PROMPTS.md:101-114` lane-aware write matrix — **verified**.
- `AGENT_PROMPTS.md:1225` §7 Build Agent header — **verified**.
- `AGENT_PROMPTS.md:1281-1302` §7 P2 wait-exit instructions
  — **verified**.
- `AGENT_PROMPTS.md` 9 occurrences of "Tool allowlist & probing"
  paragraph at lines 246, 361, 567, 714, 855, 1068, 1232, 1483, 1595
  — **verified by grep** (all 9 confirmed).
- `bin/agent-prompts-content-test.sh:216-249` ENG-53 #11
  multi-stage probe-rule loop; `:259-281` ENG-56 absence loop;
  `:294-325` ENG-57 same-sig loop; `:337-353` ENG-55 stdin-heredoc
  pin (stages 1-7); `:417-451` branch-name-convention block
  — **verified**.
- `bin/agent-prompts-content-test.sh:20-28` `section_body` helper
  — **verified**.
- `bin/run-local-helpers.sh:133-198` `partition_dirty_paths`;
  specifically `:140-141` (`apply_d004=0` then `case "$stage" in
  brainstorming|planning) apply_d004=1`) and `:182` (the
  case-insensitive issue-id basename check
  `if [[ "$base_lower" =~ (^|[^a-z0-9])${issue_lower_re}([^a-z0-9]|$) ]]`)
  — **verified**.
- `bin/pipeline-events.json` registry: `verdict_results` (5 values),
  `halt_reasons` (8), `wait_reasons` (`awaiting-approval`,
  `awaiting-ci`), `stages` (8) — **verified by Read**.
- Doc basename `2026-05-07-eng-74-...-design.md` contains `eng-74`
  (case-insensitive); satisfies `partition_dirty_paths` D-004 — see
  `:182` regex match — **verified**.

Implementation cost: ~5 lines × 9 sections ≈ 45 lines in
`AGENT_PROMPTS.md` plus ~15 lines of test (one iteration loop with
two assertions per stage). No new helpers, no schema change, no
orchestrator change. The change is reversible by deleting the
inserted sentence at all 9 sites. CI gate (`.githooks/pre-commit`
running the full `bin/*-test.sh` suite) catches regressions in
≤30 s.

The one assumption listed as "assumed" in §8.3 — Claude Code's
allowlist matcher anchors on the first whitespace-separated token
of the command line — is consistent with the ENG-64 incident
evidence and the analogous ENG-65 disconnect. Even under a relaxed
matcher rule (which would be silently more permissive), D-001 is
also a valid no-op cleanup. Either way the fix is correct.

No P0; no P1; no P2.

### Persona-review summary

Personas: 6/6 PASS · gate P0: 0 · proceeding to planning.
