---
linear: ENG-117
title: Dimensional grading — qa-stage payload (verdict-qa.json)
date: 2026-05-17
status: draft
---

# Dimensional grading — qa-stage payload (verdict-qa.json)

## 1. Problem

Today the qa stage exits with one bit of structured signal: a verdict
marker (`<!-- pipeline: verdict result=pass|fail|halt … -->`) plus a
free-form prose summary in `stage-summary-qa.md`. The verdict is a
yes/no on the whole stage; the per-dimension reasoning ("coverage was
strong, but adversarial testing was thin") lives in prose and is
lost on the way to (a) the retrospective, (b) the threshold-logic
sub-ticket that wants to gate `pass` on dimensional minimums, and (c)
operators triaging "why did this fail."

Parent ticket **ENG-31** ("dimensional grading on review and qa
verdicts") is the umbrella. It splits into three:

| Sub-ticket | Concern | Status |
|---|---|---|
| review-payload (sibling) | review-stage `verdict-review.json` | parallel-safe |
| **ENG-117 (this brainstorm)** | qa-stage `verdict-qa.json` | this work |
| threshold-logic | pass/fail gating on dimensional scores | blocked-by ENG-117 |

This brainstorm is the foundation slice: emit a sibling JSON file
whose shape is the single source of truth for "what did qa grade,
and how." The downstream threshold reader comes later; this ticket
just lands the producer + the detective scan that enforces "the file
exists and is well-formed on every qa dispatch."

## 2. Decisions

### D-001. File location — `$issue_dir/verdict-qa.json`

The verdict payload lands at `$(issue_dir <ident>)/verdict-qa.json`
— inside the per-issue scratch dir under `$PROJECT_STATE_DIR/<ident>/`,
the same directory that holds `stage-summary-qa.md`,
`issue-state.json`, `.envelope-transcript-qa`, and (post-ENG-107)
`progress.md`.

This **diverges** from the ENG-122 plan-contract precedent, which
places `plan.json` in the worktree (`docs/plans/`) and commits it as
a long-term repo artifact.

*Rationale:* the qa verdict is per-dispatch ephemeral state, not a
long-term repo artifact:

- **Lifecycle parallels stage-summary-qa.md**, not the plan doc.
  stage-summary-qa.md lives in `$issue_dir` because it is overwritten
  on every dispatch and consumed once by `post_completion_comment`
  (run-stage.sh:340). verdict-qa.json has the same producer/consumer
  shape: produced by the qa agent on each dispatch, consumed by the
  threshold reader at the same dispatch's tail. Co-locating it with
  stage-summary-qa.md keeps "everything qa-dispatch-local" in one
  directory.
- **Linear scope says so explicitly.** The IN bullet reads "Schema for
  `$issue_dir/verdict-qa.json`" — `$issue_dir` is the canonical
  reference shape (`bin/common.sh::issue_dir`, lines 68-72) for the
  per-issue state dir, not the worktree.
- **No need to git-commit.** The Linear comment thread + the
  retrospective's `events.jsonl` are the durable record of qa grades;
  the JSON is the structured-payload tail of one dispatch. Committing
  it would (a) bloat the repo with per-dispatch detritus, (b) force a
  push step on every qa pass, (c) trip the scope sweep on stages that
  don't normally write to `docs/`.

*Reference to constraint:* CLAUDE.md "Per-issue state directory" —
the canonical pattern for "per-dispatch produced, per-dispatch
consumed" state. Schema docs for that table list
`stage-summary-<stage>.md` and `wait-<stage>.json` at the same tier;
`verdict-<stage>.json` slots there cleanly.

*Reference to constraint:* `docs/brainstorms/2026-05-02-pipeline-vocabulary-simplification-design.md:105`
already anticipates this exact filename under §4.4 ("State files
(per-issue, `$issue_dir/`)") — `verdict-<stage>.json (proposed
ENG-31) — dimensional grading`. This brainstorm honors that prior
declaration.

*Rejected alternative — put it in `docs/qa-verdicts/` and commit:*
rejected because (a) the file is per-dispatch ephemeral; committing
generates one PR commit per qa pass and pollutes git history, (b) the
threshold-logic ticket reads the LATEST verdict, not the historical
series — git history is the wrong index for that read pattern, (c)
it would compete with the existing stage-summary-qa.md for "the
canonical qa-dispatch output." Two parallel out-of-tree state files
were rejected by ENG-77 for exactly this reason (stale stage-summary
across loopback).

*Rejected alternative — embed the JSON inside `stage-summary-qa.md`
as a fenced ` ```qa-verdict` block:* rejected because (a) the
human-prose summary and the machine payload have different consumers
(operators read the summary in Linear; the threshold reader parses
the JSON) — mixing them forces every reader to walk both
representations, (b) fence-count fragility is a known foot-gun (cf.
`render-prompt.sh::extract_block`'s "exactly 2 fences" invariant), (c)
ENG-122 D-001 already chose against the same shape for plan.json with
the same reasoning.

### D-002. Schema — `qa_payload_schema_version: 1`, dimensions[] of typed records

Top-level shape:

```json
{
  "qa_payload_schema_version": 1,
  "issue_id": "ENG-117",
  "dispatch_id": "ENG-117-d0042",
  "verdict": "pass",
  "dimensions": [
    {
      "name": "gate_compliance",
      "score": 1.0,
      "rationale": "All declared gates passed; one flake cited qa-patterns.md:42.",
      "threshold_met": true
    },
    {
      "name": "coverage",
      "score": 0.85,
      "rationale": "Every new code path has at least one direct-name test (3/3); two of three also have boundary tests.",
      "threshold_met": true
    },
    {
      "name": "regression_intent",
      "score": 1.0,
      "rationale": "No previously-passing tests failed.",
      "threshold_met": true
    },
    {
      "name": "adversarial_coverage",
      "score": 0.6,
      "rationale": "Added 2 QA-authored adversarial tests across 3 new paths.",
      "threshold_met": false
    }
  ]
}
```

Required fields (validator P0):

- Top-level:
  - `qa_payload_schema_version` (integer, must equal `1`)
  - `issue_id` (string matching `^ENG-[0-9]+$`)
  - `dispatch_id` (string matching `^ENG-[0-9]+-d[0-9]+$`)
  - `verdict` (string, one of: `pass`, `fail`, `halt`)
  - `dimensions` (array, len ≥ 1)
- Each `dimensions[i]`:
  - `name` (string, non-empty, `^[a-z][a-z0-9_]*$`)
  - `score` (number, `0.0 ≤ score ≤ 1.0`)
  - `rationale` (string, non-empty)
  - `threshold_met` (boolean)

Unknown fields at any level: permissive (exit 0 + stderr warning),
mirroring `bin/plan-schema.sh:55-57` (ENG-122 D-005).

*Rationale — why these required fields and not others:*

- **`dispatch_id` at the top level is load-bearing.** Without it, a
  stale `verdict-qa.json` from a prior dispatch could be read as
  current by the next dispatch's threshold reader, recreating exactly
  the ENG-87 staleness class. Cross-checking
  `json.dispatch_id == $PIPELINE_DISPATCH_ID` is the freshness
  invariant. (Belt-and-braces: D-004 ALSO clears the file at
  dispatch-start.)
- **`verdict` mirrors the pipeline-vocabulary registry**
  (`bin/pipeline-events.json:3-9`). The qa agent already emits a
  verdict marker via `bash bin/pipeline.sh event ... verdict <result>`;
  duplicating it in the JSON gives the threshold reader a
  self-consistent payload without cross-comment reads.
- **`name` is restricted to `^[a-z][a-z0-9_]*$`.** Names are stable
  identifiers that downstream readers key off; allowing arbitrary
  Unicode invites case-sensitivity bugs and rendering surprises.
  Snake_case matches the existing convention for harness identifiers
  (CLAUDE.md "Language idioms": `snake_case for function names`).
- **`score` is a normalised 0..1 float**, not a 0..10 integer or
  per-dimension grade letters. The Linear scope says "per-dimension
  scores" without specifying a scale; normalising to 0..1 lets the
  threshold reader compose dimensions via simple weighted sums later
  without scale-conversion bugs.
- **`threshold_met` is a boolean PER DIMENSION,** not a top-level
  "all green" flag. The QA agent is the one judging per-dimension
  acceptance; the threshold reader (separate ticket) aggregates the
  per-dimension booleans into the dispatch verdict. Including it here
  makes the agent's judgment explicit and inspectable.
- **No `dimensions[].weight` field.** Weighting is the threshold
  ticket's concern (D-005 forward-compat permits adding it later
  without bumping schema_version, since unknown fields warn-only).

*Schema is intentionally minimal.* This ticket lands the producer +
the validator. The threshold reader (next sub-ticket) may extend the
schema later by bumping `qa_payload_schema_version` and adding
optional fields; the permissive-on-unknown contract (D-005) keeps
schema-1 documents valid for schema-2 readers.

*Reference to product principle:* CLAUDE.md "Don't add features,
refactor, or introduce abstractions beyond what the task requires" —
the schema covers exactly the three named items in the Linear scope
("per-dimension scores + rationale + thresholds met/missed"). No
speculative `dimensions[].weight`, no `dimensions[].subscores`, no
top-level `summary` (the prose summary lives in
`stage-summary-qa.md`).

*Reference to constraint:* CLAUDE.md "Cross-dispatch staleness
contract (ENG-87)" — `dispatch_id` at the top level is the same
mitigation pattern the ENG-87 contract requires for any per-issue
file that crosses dispatch boundaries.

*Rejected alternative — `dimensions` as an object keyed by name
(`dimensions: { coverage: {score: …}, gate_compliance: {…} }`) instead
of an array:* rejected because (a) JSON objects don't preserve key
order; the qa agent's narrative ordering (gates → coverage →
regression → adversarial) is communicative signal we'd lose, (b) jq
filtering of an object's values needs `to_entries`/`from_entries`
gymnastics whereas an array of records is one filter away from
operator-readable form, (c) the array shape mirrors `plan.json`'s
`features[]` (ENG-122 D-002) and minimises cross-schema mental load.

*Rejected alternative — JSON Schema (jsonschema-org spec) validation:*
rejected for the same reasons ENG-122 D-002 rejected it: no Python /
Node available in the harness (project profile Stack section),
jq filters cover the 6-field schema in < 80 lines of bash, and
jsonschema's expressivity is overkill for what we have.

*Rejected alternative — letter grades (`A`/`B`/`C`):* rejected because
(a) the threshold ticket wants numeric aggregation, not categorical;
mapping letters back to numbers introduces an extra translation step
with no information gain, (b) the QA agent has been emitting numeric
score-ish prose ("3/3 paths covered") already — 0..1 normalises that
without inventing new vocabulary.

### D-003. Validator implementation — `bin/qa-payload-schema.sh`

A standalone CLI with one subcommand, `validate <file>
[--ident <ENG-N>] [--dispatch-id <id>]`:

- `0`  — valid schema-v1 document.
- `36` — malformed: JSON parse error or top-level not an object.
- `37` — incomplete: required field missing, wrong type, unknown
  `verdict` value, or `dispatch_id` mismatch when `--dispatch-id` is
  supplied.
- `38` — missing-file: no JSON at the given path.

*Rationale:* one-helper-per-concern matches the harness convention
(`bin/plan-schema.sh`, `bin/secret-probe-lint.sh`, `bin/metrics.sh`,
`bin/scope-check.sh`). Hoisting the validator into `bin/common.sh`
would add ~150 lines of jq to a file that every other script sources
on every invocation — see ENG-122 D-003 for the same reasoning.

Three new exit codes 36/37/38 (paired with three new outcome tokens
in `bin/common.sh::failure_outcome_for_exit`):

| Exit code | Outcome token             | Operator-observable failure                                                |
|-----------|---------------------------|----------------------------------------------------------------------------|
| 36        | `qa-payload-malformed`    | The JSON file exists but jq cannot parse it (stray comma, prose contamination). |
| 37        | `qa-payload-incomplete`   | The JSON parses but a required field is missing, wrong type, or `dispatch_id`/`issue_id` mismatches the dispatch context. |
| 38        | `qa-payload-missing`      | No JSON file at the expected `$issue_dir/verdict-qa.json` path.            |

These slot cleanly after the ENG-122 plan-contract block (33/34/35)
in `bin/common.sh::failure_outcome_for_exit:272-275`.

The outcome tokens are stage-specific by design — they end up in
`events.jsonl::outcome` per the ENG-26 telemetry contract, which the
retrospective's §1 outcome-grouping reads to bucket failures. Reusing
33/34/35 (named `plan-contract-*`) for qa-payload failures would
silently group qa-payload-malformed events with plan-contract-malformed
events in the weekly retro, masking the root cause. Three new codes is
the smallest taxonomy extension that keeps the retro-side grouping
accurate.

Schema source-of-truth lives in `bin/qa-payload-schema.sh`'s header
comment (mirrors ENG-122 D-002 final paragraph).

*Reference to constraint:* CLAUDE.md "When a new bash file is meant
to be both executable and unit-testable, replicate the sentinel
pattern" — `bin/qa-payload-schema.sh` ends with the
`if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi` sentinel.

*Reference to constraint:* CLAUDE.md "Never use exit codes outside
the taxonomy in `failure_outcome_for_exit`" — codes 36/37/38 are
added to the taxonomy in step 1 of the implementation plan, BEFORE
any caller emits them. Without the taxonomy entry, the retrospective's
§1 filter routes unknown codes to `unknown-exit-N` and misclassifies
the failure.

*Rejected alternative — reuse the ENG-122 exit codes 33/34/35:*
rejected because the outcome tokens (`plan-contract-malformed`, etc.)
are stage-specific by name. `events.jsonl::outcome` is the
retrospective's primary discriminator for failure grouping; reusing
the codes would cause qa-payload failures to be filed under
plan-contract in the weekly retro. The triage shape is similar but
the outcome stream needs distinct tokens. (This was the original
draft; revised in persona-review iteration 1 per the feasibility
persona's P1 finding.)

*Rejected alternative — share a single `bin/verdict-schema.sh`
parameterised by stage (`validate qa <file>` / `validate review <file>`):*
rejected because (a) the review-payload sub-ticket runs in parallel
with this one; landing a shared file in one ticket forces the other
to modify it, breaking parallel-safety (merge conflict surface), (b)
the dimensions for review and qa may diverge over time (review cares
about correctness/security/clarity; qa cares about coverage/regression/
adversarial); per-stage validators keep them decoupled, (c) the
shared bits (top-level required fields) are < 30 lines of jq; the
copy-paste cost is bounded. **If both stages converge on identical
schemas later, fold into a shared helper as a follow-up — the
threshold-logic ticket is the natural consolidation moment.**

### D-004. Detective scan — `bin/run-stage.sh::_validate_qa_payload`

Runs in the post-dispatch hook block of `bin/run-stage.sh::main`,
**after** `_validate_dispatch_envelope` (run-stage.sh:1801) and
**after** `_validate_plan_contract` (run-stage.sh:1827), stage-gated
to `qa` only. Halts the dispatch with rc=36/37/38 + a halt comment
when the validator returns non-zero.

Concrete placement (immediately after the plan-contract block at
run-stage.sh:1819-1835):

```bash
if (( ! skip_dispatch )); then
  case "$stage" in
    qa)
      local _qa_rc=0
      _validate_qa_payload "$ident" || _qa_rc=$?
      if (( _qa_rc != 0 )); then
        classify_failure "$ident" "$stage" "skip-until-human-acts" \
          "qa-payload-invalid: $(failure_outcome_for_exit "$_qa_rc")" "$_qa_rc"
        exit "$_qa_rc"   # rc=36 malformed | 37 incomplete | 38 missing
      fi
      ;;
  esac
fi
```

The helper:

```bash
_validate_qa_payload() {
  local ident="$1"
  local d; d="$(issue_dir "$ident")"
  local payload="$d/verdict-qa.json"

  if [[ ! -f "$payload" ]]; then
    _post_qa_payload_halt "$ident" "qa-payload-missing" \
      "verdict-qa.json not found at $payload"
    return 35
  fi

  local schema_out schema_rc=0
  schema_out="$(bash "$SCRIPT_DIR/qa-payload-schema.sh" validate "$payload" \
    --ident "$ident" --dispatch-id "${PIPELINE_DISPATCH_ID:-}")" \
    || schema_rc=$?
  case "$schema_rc" in
    0)  return 0 ;;
    36) _post_qa_payload_halt "$ident" "qa-payload-malformed"  "$schema_out" ; return 36 ;;
    37) _post_qa_payload_halt "$ident" "qa-payload-incomplete" "$schema_out" ; return 37 ;;
    38) _post_qa_payload_halt "$ident" "qa-payload-missing"    "$schema_out" ; return 38 ;;
    *)  _post_qa_payload_halt "$ident" "qa-payload-unexpected-rc" \
          "validator returned unexpected rc=$schema_rc; stdout: $schema_out" ; return 36 ;;
  esac
}

_post_qa_payload_halt() {
  local ident="$1" defect="$2" raw="$3"
  local safe="${raw//<!--/<\\!--}"
  local body
  body="$(printf '<!-- pipeline: verdict result=halt reason=qa-payload-invalid -->\n\nqa-payload validation failed on dispatch_id=%s stage=qa:\n\n- Defect: %s\n\n~~~\n%s\n~~~\n\nSchema source-of-truth: see header comment in `bin/qa-payload-schema.sh`.\n\n**Resume:** fix verdict-qa.json (or the qa prompt'\''s emission step), commit on the feature branch if needed, then run `bash bin/pipeline.sh decide %s --action continue`.' \
    "${PIPELINE_DISPATCH_ID:-unknown}" "$defect" "$safe" "$ident")"
  bash "$SCRIPT_DIR/linear.sh" add-comment "$ident" "$body" || true
}
```

**Sanitisation requirement (mirrors run-stage.sh:1016, ENG-87 review
C3 + ENG-122 D-004).** Validator stdout is agent-controlled bytes (the
agent wrote verdict-qa.json the validator parsed). When interpolated
into the halt-comment body, an embedded
`<!-- pipeline: verdict result=pass -->` substring would otherwise be
picked up by `parse_pipeline_marker`'s family-precedence selector and
promote the halt INTO a forward pass. `_post_qa_payload_halt` does
both defenses:

1. Replace embedded `<!--` opens with `<\!--`
   (`safe="${raw//<!--/<\\!--}"`).
2. Wrap the validator output in a fenced (`~~~`) block — the
   marker parser's `_strip_code_blocks_and_spans` removes fenced
   runs before grep'ing.

*Detective philosophy — state check, not transcript scan.* The
qa-payload contract is a state requirement (the file must exist with
the right shape) — not a tool-denial. Post-dispatch state checks are
the correct shape for this failure mode (CLAUDE.md "Defense-in-depth:
when a stage's contract says 'agent must not invoke tool X,' prefer a
transcript-based assertion ... over a post-dispatch state check" —
this rule applies to *tool denials*; state requirements are the
opposite side of the dial). Precedents:
`_validate_plan_contract` (run-stage.sh:1036) for plan.json,
`_assert_progress_md_entry` (dispatch.sh:275) for progress.md.

*Reference to constraint:* CLAUDE.md "Per-stage allowed tool lists
are centralized in `dispatch.sh::allowed_tools_for`" — the same
centralization principle applies to per-stage post-dispatch
validators: they live in `bin/run-stage.sh`'s `case "$stage" in`
block, after the envelope and plan-contract validators. New stages
add a case; ordering is "envelope (all stages) → per-stage validators
in stage order (planning, qa, …)."

*Reference to constraint:* CLAUDE.md "Linear writes go through
`bin/linear.sh` so dry-run + `meta: dedup` work uniformly" — the halt
comment uses `add-comment` (append-only, per the verdict-marker
protocol), not `add-or-update-comment`. The auto-injected
`<!-- meta: dispatch id=… -->` marker is owned by `bin/linear.sh`
(ENG-87 chokepoint).

*Rejected alternative — fire the validator from `dispatch.sh` (in-band
transcript-scan path):* rejected because (a) dispatch.sh is the thin
claude-wrapper layer; expanding its responsibilities pulls
Linear-API calls into its failure path (ENG-103 D-003 / ENG-122 D-004
chose the same separation), (b) the file-existence check is a
post-dispatch FILESYSTEM check, not a transcript-scan check —
co-locating it with `_validate_dispatch_envelope`'s sidecar reads is
the cleaner layer.

*Rejected alternative — have the qa agent self-validate before
exit:* rejected for the same reason ENG-122 D-004 did: agents can
lie / forget / be killed mid-stream before reaching their self-check.
ENG-87's "Detective backstop" design explicitly says state checks
complement, not replace, prompt-side instructions.

### D-005. Halt-reason vocabulary — register `qa-payload-invalid`

Add a single new entry to `bin/pipeline-events.json::halt_reasons`:

```diff
   "halt_reasons": [
     "agent-blocked",
     "agent-failure",
     "smoke-failed",
     "iteration-exhausted",
     "scope-violation",
     "protocol-violation",
     "dispatch-timeout",
     "pr-opened-too-early",
     "dispatch-envelope-violation",
-    "plan-contract-invalid"
+    "plan-contract-invalid",
+    "qa-payload-invalid"
   ],
```

Mapping table (paired with the new exit codes from D-003):

| Exit code | Outcome token (NEW)         | Halt reason         |
|-----------|-----------------------------|---------------------|
| 36        | `qa-payload-malformed`      | `qa-payload-invalid`|
| 37        | `qa-payload-incomplete`     | `qa-payload-invalid`|
| 38        | `qa-payload-missing`        | `qa-payload-invalid`|

All three exit codes map to the SAME halt reason
(`qa-payload-invalid`) for operator-visible triage. The fine-grained
outcome tokens give the retrospective enough signal to separate
root causes in `events.jsonl::outcome` aggregation, mirroring the
plan-contract precedent (ENG-122 D-003 used three outcome tokens +
one halt reason — same shape here).

*Reference to constraint:* CLAUDE.md "Pipeline vocabulary" — single
source of truth is `bin/pipeline-events.json`; `bin/pipeline.sh
event` validates against it. Adding the new entry there is sufficient
to make `bash bin/pipeline.sh event ENG-117 verdict halt --reason
qa-payload-invalid` succeed (registry-validated).

*Reference to constraint:* CLAUDE.md "Failure-mode quick reference" —
the operator runbook reads halt reasons via Linear comments; a
human-readable token (`qa-payload-invalid`) is more discoverable than
"exit code 34" for the operator's mental model.

*Rejected alternative — three new halt reasons
(`qa-payload-missing`, `qa-payload-malformed`,
`qa-payload-incomplete`):* rejected because (a) the operator action
is identical in all three cases ("inspect verdict-qa.json, fix
agent emission, `--action continue`"); fine-grained halt reasons add
operator cognitive load without changing the recovery path, (b) the
defect detail is already in the halt-comment body, (c) the
plan-contract precedent collapses three defects to one halt reason
for the same reason.

### D-006. Pre-dispatch clear — extend `_clear_current_stage_slots`

`bin/run-stage.sh::_clear_current_stage_slots:931-938` clears
`stage-summary-${stage}.md` and `wait-${stage}.json` on every
dispatch-start. Extend it to ALSO clear `verdict-${stage}.json`:

```diff
 _clear_current_stage_slots() {
   local PIPELINE_WRITER=orchestrator
   export PIPELINE_WRITER
   local ident="$1" stage="$2"
   local d; d="$(issue_dir "$ident")"
   rm -f "$d/stage-summary-${stage}.md" 2>/dev/null || true
   rm -f "$d/wait-${stage}.json"        2>/dev/null || true
+  rm -f "$d/verdict-${stage}.json"     2>/dev/null || true
   return 0
 }
```

*Rationale:* ENG-87 names "Per-issue files: clear-on-dispatch-start"
as one of the four per-medium primitives in the staleness contract.
verdict-qa.json is a per-issue file that crosses dispatch boundaries
the same way stage-summary-qa.md does; the same primitive applies.

Defense in depth — the validator ALSO cross-checks
`json.dispatch_id == $PIPELINE_DISPATCH_ID` per D-002. The two
defenses cover orthogonal failure modes:

| Failure mode | Caught by |
|---|---|
| Agent fails to write verdict-qa.json this dispatch; file from a prior dispatch survives | Clear-on-dispatch-start (rm at run-stage.sh:1321) |
| Agent writes verdict-qa.json but emits stale `dispatch_id` (copy-paste from prior run) | Validator `--dispatch-id` cross-check (D-002 / D-003) |
| Agent omits `dispatch_id` field entirely | Validator required-field check (D-002 / D-003) |

Extending the clear is a one-line change, generalises to the
parallel `review-payload` sub-ticket (which adds
`verdict-reviewing.json` under the same `${stage}` parameter), and
gives the threshold reader a clean invariant: "if a
verdict-${stage}.json exists at the start of qa, it was written by
THIS dispatch."

*Reference to constraint:* CLAUDE.md "Cross-dispatch staleness
contract (ENG-87)" — `verdict-<stage>.json` slots into the same
per-medium primitive as `stage-summary-<stage>.md`. The extension is
load-bearing for the parallel review-payload sub-ticket too; we own
the generalisation here.

*Rejected alternative — validator-only freshness via mtime check
(`stat -f %m verdict-qa.json` ≥ dispatch start):* rejected because
(a) mtime is not preserved across git/rsync paths and depends on
filesystem behavior, (b) ENG-87 explicitly chose dispatch_id over
mtime for staleness invariants, (c) doing it twice (clear-on-start
+ id-cross-check) is cheap and aligns with the staleness contract.

### D-007. Agent prompt — extend AGENT_PROMPTS.md §6 "Output" section

Update the qa agent's prompt to instruct it to emit verdict-qa.json
as a sibling of the stage-summary file:

**Add to §6's "Your task" section, after step 7 ("qa-patterns
updates"):**

> **8. Emit dimensional grading payload (verdict-qa.json):**
>    Before exiting (on any decision path — A, B, C, or D), write a
>    dimensional grading payload to
>    `$(issue_dir <ENG-N>)/verdict-qa.json` describing your per-
>    dimension scores. Schema source-of-truth: see header comment in
>    `bin/qa-payload-schema.sh`. Required fields: `qa_payload_schema_version`
>    (must be `1`), `issue_id`, `dispatch_id`, `verdict`, `dimensions[]`.
>    Each dimension must have `name` (snake_case), `score` (0.0–1.0),
>    `rationale` (1-2 sentences citing concrete evidence), and
>    `threshold_met` (boolean — your judgment on whether this
>    dimension is acceptable for this PR).
>
>    The detective scan in `run-stage.sh::_validate_qa_payload` will
>    halt the dispatch with `qa-payload-invalid` if the file is
>    missing, malformed, or fails schema validation. The threshold
>    ticket (sub-ticket of ENG-31) will later gate the dispatch
>    verdict on dimensional minimums; today the JSON is recorded
>    forensically without gating.
>
>    Suggested starter dimensions for the qa stage (not mandated —
>    the threshold ticket will decide the canonical set): `gate_compliance`,
>    `coverage`, `regression_intent`, `adversarial_coverage`,
>    `plan_alignment`, `flake_dismissal_integrity`. Include a dimension
>    only if you can cite concrete evidence; omit rather than fabricate.

**Add to §6's "Output" bullet list:**

> - `verdict-qa.json` written to `$(issue_dir <ENG-N>)/verdict-qa.json`
>   on every decision path. Overwrite-on-every-dispatch contract per
>   §0; orchestrator's detective scan validates it before advancing.

The Decision Path blocks (A/B/C/D) at AGENT_PROMPTS.md:1436-1477
already enumerate the per-path side effects; no change to their
ordering is needed — the new step 8 fires before the verdict marker
in all four paths (the marker is the LAST emission, by the verdict-
marker contract at AGENT_PROMPTS.md:1494-1514).

*Reference to constraint:* CLAUDE.md "AGENT_PROMPTS.md is
load-bearing" — column-0 ``` fences are forbidden inside a stage's
body; the new step 8 is plain prose without fenced blocks, so the
"exactly 2 fences" invariant for §6 is preserved.

*Reference to constraint:* CLAUDE.md "Stage summary file —
overwrite-on-every-dispatch contract (ENG-77/ENG-71)" — verdict-qa.json
follows the same overwrite contract. The agent prompt instructs Write
(not Edit), and the validator runs on the post-dispatch file content.

*Rejected alternative — make verdict-qa.json mandatory only on
Decision-path C (all-green)*: rejected because (a) failure paths B
(loop-back-to-implementing) and D (back-fill PR) also produce
dimensional signal — "coverage was low" is exactly the data the
threshold ticket needs to gate fails fairly, (b) symmetric emission
makes the detective scan stage-gated without per-path branching,
keeping the contract simple.

### D-008. Tests — `bin/qa-payload-schema-test.sh` (unit) +
`bin/run-stage-test.sh` (integration)

**Unit (bin/qa-payload-schema-test.sh):**

| ID | Case | Expected rc |
|---|---|---|
| T1  | Well-formed schema-1 doc | 0 |
| T2  | Missing file | 38 |
| T3  | Malformed JSON (stray comma) | 36 |
| T4  | Top-level is an array, not object | 36 |
| T5  | `qa_payload_schema_version` missing | 37 |
| T6  | `qa_payload_schema_version: 2` | 37 |
| T7  | `issue_id` wrong type (int) | 37 |
| T8  | `dispatch_id` missing | 37 |
| T9  | `dispatch_id` fails regex (`^ENG-N-d[0-9]+$`) | 37 |
| T10 | `verdict` is `bogus` (not in pass/fail/halt) | 37 |
| T11 | `dimensions: []` (len 0) | 37 |
| T12 | `dimensions[0].name` fails regex | 37 |
| T13 | `dimensions[0].score` is a string | 37 |
| T14 | `dimensions[0].score: 1.5` (out of range) | 37 |
| T15 | `dimensions[0].rationale: ""` (empty) | 37 |
| T16 | `dimensions[0].threshold_met` missing | 37 |
| T17 | Unknown top-level field (`debug: "..."`) | 0 + warning |
| T18 | Unknown per-dimension field (`weight: 0.5`) | 0 + warning |
| T19 | `--ident ENG-999` mismatches JSON `issue_id: ENG-117` | 37 |
| T20 | `--dispatch-id` mismatches JSON `dispatch_id` | 37 |

**Integration (extend bin/run-stage-test.sh):**

| ID | Case | Expected |
|---|---|---|
| INT1 | Clean qa dispatch with valid verdict-qa.json | rc=0, no halt comment |
| INT2 | qa dispatch with missing verdict-qa.json | rc=38, halt comment body contains `qa-payload-invalid` + `defect: qa-payload-missing` |
| INT3 | qa dispatch with malformed verdict-qa.json | rc=36, halt body contains `qa-payload-malformed` |
| INT4 | qa dispatch with incomplete verdict-qa.json (missing `dispatch_id`) | rc=37, halt body contains `qa-payload-incomplete` |
| INT5 | Non-qa stage (e.g. implementing) with no verdict-qa.json | validator does NOT run (stage-gate); no halt comment |
| INT6 | qa dispatch with stale `dispatch_id` (from prior run) | rc=37 (cross-check failed) |

Both test files follow the source-and-stub pattern (CLAUDE.md "How
tests work — important when adding new ones"). The unit test sources
`bin/qa-payload-schema.sh` directly; the integration test extends
the existing `_validate_dispatch_envelope` test group in
`bin/run-stage-test.sh` using mktemp'd HARNESS_STATE_DIR + STUB_DIR
fixtures.

*Reference to constraint:* CLAUDE.md "Tests are sibling shell scripts
named `*-test.sh` in `bin/`. There is no test runner — each file is a
self-contained executable." — both new test files match the pattern;
both are added to the project profile's `Build & test gates` test
list AND to the harness-self `.pipeline-config/config.json::dispatch.tools`
test allowlist (the literal enumeration warning at CLAUDE.md "Wildcard
pitfall").

*Rejected alternative — check in a "happy-path" verdict-qa.json
fixture under `docs/` for tests to reference:* rejected for the same
reasons as ENG-122 D-006 (mktemp'd fixtures are isolated per-run;
docs/ is operationally a documentation root, not a fixture root).

## 3. Architecture

```
                ┌──────────────────────────────────────────────────────┐
                │  AGENT_PROMPTS.md §6 QA Agent                        │
                │  + new step 8: emit verdict-qa.json                  │
                │  + Output bullet names verdict-qa.json + schema      │
                └──────────────────────────────────────────────────────┘
                                      │
                                      ▼
                ┌──────────────────────────────────────────────────────┐
                │  bin/render-prompt.sh                                │
                │    (no change — emits whole §6 block via {tokens})   │
                └──────────────────────────────────────────────────────┘
                                      │
                                      ▼
                ┌──────────────────────────────────────────────────────┐
                │  bin/run-stage.sh::_clear_current_stage_slots        │
                │   + rm -f "$d/verdict-${stage}.json"   ◀── D-006     │
                └──────────────────────────────────────────────────────┘
                                      │
                                      ▼
                ┌──────────────────────────────────────────────────────┐
                │  qa dispatch (claude -p)                             │
                │  Agent writes:                                       │
                │    $issue_dir/stage-summary-qa.md (existing)         │
                │    $issue_dir/verdict-qa.json     ◀── NEW            │
                └──────────────────────────────────────────────────────┘
                                      │
                                      ▼
                ┌──────────────────────────────────────────────────────┐
                │  bin/run-stage.sh::main (post-dispatch hook block)   │
                │   1. agent-contract-validator (exit 25)              │
                │   2. _validate_dispatch_envelope (exit 29)           │
                │   3. _validate_plan_contract (exit 33/34/35,         │
                │      stage=planning only)                            │
                │   4. _validate_qa_payload  ◀── NEW                   │
                │      (exit 33/34/35, stage=qa only)                  │
                │   5. push_branch_if_ahead                            │
                │   6. post_completion_comment                         │
                └──────────────────────────────────────────────────────┘
                                      │
                                      ▼
                ┌──────────────────────────────────────────────────────┐
                │  bin/qa-payload-schema.sh   ◀── NEW                  │
                │   subcommands:                                       │
                │     validate <file> [--ident ENG-N]                  │
                │                     [--dispatch-id ENG-N-dNNNN]      │
                │   schema reference in file-header comment            │
                └──────────────────────────────────────────────────────┘
                                      │
                                      ▼
                ┌──────────────────────────────────────────────────────┐
                │  bin/pipeline-events.json                            │
                │   halt_reasons[] += "qa-payload-invalid"   ◀── D-005 │
                └──────────────────────────────────────────────────────┘

                                  Files MODIFIED ─────────────────────
                                  AGENT_PROMPTS.md   (QA §6: new step 8 + Output bullet)
                                  bin/run-stage.sh   (post-dispatch hook + _validate_qa_payload + _post_qa_payload_halt + _clear_current_stage_slots extension)
                                  bin/pipeline-events.json (halt_reasons += qa-payload-invalid)
                                  CLAUDE.md          (one paragraph documenting the new contract under "Per-issue state directory")
                                  .pipeline-config/config.json (test allowlist for the new sibling test)

                                  Files NEW ──────────────────────────
                                  bin/qa-payload-schema.sh
                                  bin/qa-payload-schema-test.sh

                                  Files MODIFIED (additional) ───────
                                  bin/common.sh      (failure_outcome_for_exit: 36/37/38 added per D-003)

                                  Files NOT MODIFIED ────────────────
                                  bin/dispatch.sh    (validator lives in run-stage.sh, not dispatch.sh — D-004)
                                  learned-rules/harness/qa.md  (retrospective-managed; new rules emerge from prod evidence, not file-time speculation)
```

## 4. Data Flow

1. **Dispatch start.** `bin/run-stage.sh::main` allocates a fresh
   `PIPELINE_DISPATCH_ID` via `allocate_dispatch_id` (common.sh:
   exported per ENG-87), then calls `_clear_current_stage_slots
   "$ident" qa` which removes any pre-existing
   `stage-summary-qa.md`, `wait-qa.json`, AND (post-D-006)
   `verdict-qa.json` from `$issue_dir`.
2. **render-prompt extracts §6.** `bin/render-prompt.sh` resolves
   the prompt tokens (`{issue_id}`, `{stage_summary_path}`,
   `{progress_md_path}`, `{dispatch_id}`, …) and emits the rendered
   §6 body to a tempfile. The new step 8 instruction is part of the
   fenced block.
3. **claude -p runs.** The qa agent reads the plan + the
   brainstorm + the PR, runs gates per its existing §6 task list,
   then writes verdict-qa.json to `$issue_dir/` via the `Write` tool.
4. **Agent emits verdict marker.** Per the existing protocol
   (AGENT_PROMPTS.md:1494-1514), the agent runs
   `bash bin/pipeline.sh event $ident verdict <result>` as its
   LAST action.
5. **Post-dispatch hook fires.** `run-stage.sh::main` runs the
   ordered post-dispatch validators:
   - agent-contract-validator (exit 25 if neither stage-summary
     nor verdict marker landed)
   - `_validate_dispatch_envelope` (exit 29 on transcript bypass)
   - `_validate_plan_contract` (stage-gated planning; no-op on qa)
   - `_validate_qa_payload "$ident"` (NEW; stage-gated qa)
6. **Validator path.** `_validate_qa_payload` checks
   `$issue_dir/verdict-qa.json` exists. If missing → posts halt
   comment, returns 38. Otherwise shells out to
   `bash bin/qa-payload-schema.sh validate <file> --ident <ENG-N>
   --dispatch-id <id>`, captures stdout + rc. Halt cases (36/37/38)
   post a sanitised halt comment via `bin/linear.sh add-comment`
   and exit the dispatch with the matching rc.
7. **Halt path.** `classify_failure` writes
   `policy=skip-until-human-acts` to `issue-state.json`; next
   tick's poller sees `pipeline:halted` label (applied by the
   orchestrator post-dispatch per ENG-56) and skips the issue.
   Operator resolves via `bash bin/pipeline.sh decide ENG-117
   --action continue` (clears the halt label, the wait file, the
   per-issue counter, re-allocates dispatch_id).
8. **Resume.** Next dispatch starts at step 1; the prior dispatch's
   verdict-qa.json was cleared in step 1's
   `_clear_current_stage_slots`, so the agent writes a fresh one
   stamped with the fresh `dispatch_id`.
9. **Clean path.** Validator returns 0; control falls through to
   `push_branch_if_ahead` + `post_completion_comment` + orchestrator
   advance to `stage:building` per the existing flow.

## 5. Error Handling

| Failure                                       | Surface              | Recovery                              |
|---                                            |---                   |---                                    |
| verdict-qa.json missing                       | Halt, rc=38          | Agent re-write; `--action continue`   |
| Malformed JSON syntax                         | Halt, rc=36          | Agent re-emit; `--action continue`    |
| Missing required field                        | Halt, rc=37          | Agent re-emit; `--action continue`    |
| `issue_id` mismatch (stale template)          | Halt, rc=37          | Agent re-emit with correct ID         |
| `dispatch_id` mismatch (stale dispatch)       | Halt, rc=37          | Inspect agent's emission step; usually a copy-paste of a prior run |
| `dimensions: []` (no dimensions)              | Halt, rc=37          | Agent re-emit with ≥1 dimension       |
| `score: 1.5` (out of range)                   | Halt, rc=37          | Agent re-emit with score in [0.0, 1.0]|
| Unknown field at any level                    | exit 0 + stderr warn | None — permissive forward-compat (D-005) |
| Validator (qa-payload-schema.sh) itself crashes | Halt, rc=36 (catch-all) | Operator inspects validator; manual fix |
| Validator's `jq` missing                      | Hard die (require_bin) | Operator installs jq (preflight)     |
| Worktree missing post-dispatch                | n/a — payload lives in `$issue_dir`, not worktree (D-001); validator only checks `$issue_dir` | n/a |
| `$issue_dir` missing                          | Halt, rc=38 (file not found) | Highly anomalous — investigate dispatch pipeline manually |

The validator does NOT short-circuit fail-open on missing
infrastructure (unlike `_validate_plan_contract` which fails open on
absent worktree). Reason: verdict-qa.json's location is
`$issue_dir/verdict-qa.json`, and `$issue_dir` is created by
`run-stage.sh::main` BEFORE dispatch (the dispatch couldn't have
happened otherwise). If `$issue_dir` is somehow missing
post-dispatch, that's a higher-order failure than a payload defect
— halting with rc=38 surfaces it correctly.

## 6. Edge Cases

- **qa runs twice on the same issue (re-dispatch after a
  rejection).** D-006's clear-on-dispatch-start removes the prior
  verdict-qa.json before the new agent starts; no cross-dispatch
  read of stale content. Belt-and-braces: the validator's
  `--dispatch-id` cross-check would catch it even if the clear were
  somehow skipped.

- **qa dispatched in dry-run mode** (`PIPELINE_DRY_RUN=1`). The
  detective scan still runs. In dry-run, the agent emission step is
  stubbed (no real `claude -p`); the agent stub would need to write
  a valid verdict-qa.json for the dispatch to advance. Unit tests in
  `bin/qa-payload-schema-test.sh` run under `PIPELINE_DRY_RUN=1`
  per CLAUDE.md "How tests work."

- **Agent writes verdict-qa.json with extra unknown fields
  (e.g. `dimensions[0].weight: 0.4`).** Validator returns 0 +
  stderr warning per D-005 (mirrors `bin/plan-schema.sh:55-57`).
  Forward-compatible for the threshold ticket's potential weight
  field.

- **Agent writes verdict-qa.json to wrong path** (e.g.
  `$issue_dir/verdict-qa-final.json`). Validator's
  "missing at expected path" branch fires → exit 35. Halt body
  names the expected path, agent re-runs with corrected prompt
  understanding.

- **Unicode in `rationale` text.** `jq` handles UTF-8 by default; no
  special handling required. The halt-comment body inlines validator
  stdout via the `<!--` sanitisation, so Linear renders UTF-8
  correctly.

- **Adversarial — agent emits a `rationale` containing a literal
  `<!-- pipeline: verdict result=pass -->` substring.** The
  validator's exit-0 path does NOT interpolate the payload content
  into Linear; only the halt path does. On the halt path,
  `_post_qa_payload_halt` mirrors `_validate_dispatch_envelope`'s
  sanitisation (`safe="${raw//<!--/<\\!--}"`) AND wraps in `~~~`
  fences. Same threat model + same defense as ENG-87 review-iter-7
  C3 / ENG-122 D-004.

- **qa stage on a back-fill PR (Decision-path D).** The verdict-qa.json
  payload is still required; dimensions will be sparse
  (`adversarial_coverage: not applicable, threshold_met: true,
  rationale: "Back-fill PR — no new code paths"`). The agent
  prompt's step 8 explicitly says "emit on any decision path"; the
  permissive-on-rationale-content schema means a sparse-but-honest
  payload validates clean. The threshold ticket will define how
  "not applicable" rationale should aggregate.

- **qa stage halts with `iteration-exhausted` (or any agent-side
  halt reason) WITHOUT emitting verdict-qa.json.** The detective
  scan fires regardless; missing file → rc=35. This may double-halt
  (agent emits halt verdict marker, THEN validator emits halt
  comment for missing JSON). **Mitigation:** the verdict marker
  protocol orders verdict-marker emission AFTER all output emissions
  (AGENT_PROMPTS.md:1494-1514); a well-behaved agent that halts
  mid-stage should NOT have emitted a verdict marker yet, so the
  validator's halt comment is the only one in flight. If the agent
  has already emitted a halt marker AND failed to write the JSON
  payload, two halt comments land; operators triage via the latest
  `<!-- meta: dispatch id=… -->` marker. Acceptable noise.

- **qa stage on a fail-back-to-implementing path (Decision-path B).**
  The agent runs `bash bin/pipeline.sh event ENG-N verdict fail
  --target implementing` as its last action. step 8 (emit
  verdict-qa.json) runs BEFORE that, per the ordering implied by the
  prompt's step numbering. The detective scan sees a well-formed
  payload + a `verdict: fail` field; both validators pass. The
  classify_failure path for fail-back-to-implementing remains
  unchanged (no payload-related halt).

- **qa stage on the harness-self target.** Same flow; the per-target
  `.pipeline-config/config.json::dispatch.tools.qa` test allowlist
  must include the new `bin/qa-payload-schema-test.sh` entry
  (CLAUDE.md "Wildcard pitfall" — literal enumeration required).
  The implementation plan will regenerate the enumerated list per
  the CLAUDE.md TESTS snippet.

## 7. Open Questions

- **OQ-1.** Should the schema enumerate a canonical set of dimension
  names (e.g. closed vocab: `gate_compliance`, `coverage`,
  `regression_intent`, `adversarial_coverage`, `plan_alignment`,
  `flake_dismissal_integrity`) and reject unknowns, OR accept any
  snake_case name and let the threshold ticket converge? — **DEFER
  to threshold ticket.** Today's schema accepts any well-formed
  snake_case name (D-002); the threshold ticket can either close the
  vocab (bump schema_version) or stay open. Closing it prematurely
  would force the qa agent to pick dimensions before the threshold
  ticket has decided what to gate on; staying permissive lets the
  agent emit honest signal and we curate via retrospective.

- **OQ-2.** Should `dimensions[].score` use a 0..1 float or a 0..10
  integer? — Recommend **0..1 float** per D-002 (composability,
  weighted sums). Open for revisit if operator feedback says floats
  are confusing in Linear comments; the schema_version bump path
  handles it.

- **OQ-3.** Should the verdict-qa.json land in `events.jsonl` as a
  metric? — Recommend **yes, follow up**, but NOT in this ticket.
  ENG-26 already streams per-dispatch cost + outcome; one row per qa
  dispatch with `qa_dimensions_scores: {...}` flattened would let
  the retrospective consume the historical series cheaply. Out of
  scope for ENG-117; suitable for a tiny follow-up after ENG-117
  ships.

- **OQ-4.** Should `_validate_qa_payload` run BEFORE or AFTER the
  agent-contract-validator (exit 25)? — Recommend **after**, matching
  the plan-contract precedent (run-stage.sh:1823-1834 is downstream
  of run-stage.sh:1538-1551). Rationale: the agent-contract-validator
  catches the catastrophic case (no stage-summary AND no verdict
  marker = agent did nothing). The payload validator runs in the
  "agent ran something" branch. Double-halting on a catastrophic
  failure is noisy; the agent-contract-validator should win there.

- **OQ-5.** Should the agent's step 8 be implemented as a tool-use
  enforced via the `disallowed_platform_tools` mechanism (e.g. force
  `Write` only)? — **No.** ENG-100 sub-agent debris is the relevant
  prior art: forcing tool patterns introduces new failure modes. The
  prompt instruction + the post-dispatch detective is the canonical
  shape (CLAUDE.md "Defense-in-depth").

- **OQ-6.** Schema-1 vs schema-1.0 — should the integer be `1` or
  the string `"1.0"`? — Recommend **integer `1`** per D-002,
  matching ENG-122's `plan_schema_version: 1`. Schema versioning is
  ordinal, not semantic-versioned; the threshold ticket bumps to `2`
  if/when needed.

- **OQ-7.** Should the parallel review-payload sub-ticket converge
  on a shared validator (`bin/verdict-schema.sh`)? — **DEFER to the
  threshold ticket**, which will read both files and is the natural
  consolidation moment. Today (parallel-safe), two per-stage
  validators is the simpler shape. D-003's "rejected alternative"
  branch captures the rationale.

## 8. ADR proposed

### ADR-2026-05-17: verdict-qa.json sibling payload + halt-on-malformed contract

* **Status:** proposed
* **Context:** ENG-31 umbrella. The qa stage today exits with one
  bit of signal (the verdict marker); the per-dimension reasoning is
  prose. The threshold-logic sub-ticket needs a structured payload
  to gate verdicts on dimensional minimums. The parallel
  review-payload sub-ticket runs the same mechanism for the review
  stage. The retrospective wants the structured payload for
  longitudinal analysis.
* **Decision:** The qa agent emits a per-dispatch payload at
  `$issue_dir/verdict-qa.json` describing per-dimension scores +
  rationale + threshold-met booleans. A new helper
  `bin/qa-payload-schema.sh` validates the JSON; a new detective
  scan (`run-stage.sh::_validate_qa_payload`) halts the dispatch on
  missing / malformed / incomplete payload with halt reason
  `qa-payload-invalid` and three new exit codes 36/37/38 (added to
  `bin/common.sh::failure_outcome_for_exit` per D-003, paired with
  outcome tokens `qa-payload-malformed`, `qa-payload-incomplete`,
  `qa-payload-missing`). The `_clear_current_stage_slots` helper is
  extended to also clear `verdict-${stage}.json` on dispatch-start,
  generalising the ENG-87 staleness primitive.
* **Consequences:**
  * **(+)** Downstream readers (threshold-logic ticket, retrospective)
    get a typed, enumerable payload.
  * **(+)** Halt-on-malformed surfaces qa defects at qa time, not at
    downstream-reader time (cheaper recovery).
  * **(+)** Generalising `_clear_current_stage_slots` to clear
    `verdict-${stage}.json` makes the parallel review-payload
    sub-ticket a near-no-op on this surface (it reuses the same
    primitive).
  * **(–)** Adds one new halt reason to the closed vocabulary
    (`qa-payload-invalid`) plus three new outcome tokens
    (`qa-payload-malformed`, `qa-payload-incomplete`,
    `qa-payload-missing`) paired with exit codes 36/37/38. The
    retrospective's §1 outcome filter must learn the new tokens —
    a one-line case-statement extension matching the ENG-122 plan-
    contract precedent.
  * **(–)** qa agent's failure modes widen: the agent can now fail
    on payload-emission defects (typo'd `dispatch_id`, omitted
    `rationale`). Empirically the API-contract block today is
    well-formed in plan dispatches (ENG-122 evidence), so the new
    failure mode is expected to be rare.
  * **(–)** One more file per qa dispatch in `$issue_dir/` —
    bounded; cleaned by `cleanup-worktrees.sh` when the issue
    finishes per the existing per-issue retention policy.
* **Alternatives considered:** see D-001, D-003, D-004, D-005, D-006
  rejected alternatives above.

## 9. Anti-bias checks

### ADR stress test

- **ENG-87 cross-dispatch staleness contract** (CLAUDE.md
  "Cross-dispatch staleness contract"): does verdict-qa.json create
  new staleness surface? Yes — it's a per-dispatch file in
  `$issue_dir` that crosses dispatch boundaries. D-006 mitigates by
  extending `_clear_current_stage_slots` (the per-medium "clear on
  dispatch start" primitive named in ENG-87). D-002 belt-and-braces
  with `dispatch_id` cross-check. ENG-87 compatible; in fact this
  ticket strengthens the contract by generalising the clear.

- **ENG-100 sub-agent debris** (CLAUDE.md "Sub-agent debris"): does
  this incentivise scratch files? No — the schema is small enough to
  reason about inline; the agent writes ONE file at one canonical
  path inside `$issue_dir` (not in the worktree, so it cannot be
  caught by `partition_dirty_paths` as a leaked-in-scope file).

- **ENG-122 plan-contract precedent** (CLAUDE.md "Per-issue state
  directory"): the architecture mirrors ENG-122 closely (separate
  validator script, post-dispatch detective in run-stage.sh, halt-on-
  malformed). Two deltas: (a) file lives in `$issue_dir`, not
  `docs/plans/` (per-dispatch ephemeral, not long-term repo
  artifact); (b) `dispatch_id` is a top-level required field (the
  staleness invariant; plan.json doesn't need it because the file
  lives in git and the basename-pairing pinned to today's date
  provides freshness already). Both deltas are justified above.

- **ENG-90 slot-occupancy contract** (CLAUDE.md "Slot-occupancy
  contract"): halt classification = `skip-until-human-acts`, which
  is `slot:"vacate", operator_action_required:true` per the
  contract. The new halt fits the existing classifier branch in
  `_poll_classify_labels`; no new branch needed.

- **ENG-77 stage-summary stale-across-loopback** (CLAUDE.md "Stage
  summary file — overwrite-on-every-dispatch contract"):
  verdict-qa.json inherits the same overwrite contract because it
  lives in the same `$issue_dir` as `stage-summary-qa.md` and is
  cleared by the same `_clear_current_stage_slots` helper.

- **ENG-46 secret-handling**: the validator and halt helper never
  use `${VAR:-X}` against secret-class env vars. The
  `${PIPELINE_DISPATCH_ID:-unknown}` pattern used in the halt body
  (mirrors run-stage.sh:1025) is lint-clean (variable name doesn't
  match the secret regex).

### Simpler alternative

For each major decision, the simpler alternative was named and
rejected:

- D-001 fenced-block-in-stage-summary — rejected (mixed-consumer
  shape, fence-count fragility).
- D-002 letter grades / object-keyed dimensions / JSON Schema —
  rejected (composability, key-order, dependency surface).
- D-003 fold-into-common.sh / shared `verdict-schema.sh` — rejected
  (parse-time surface, parallel-safety with review sub-ticket).
- D-004 agent self-validate / run-from-dispatch.sh — rejected
  (detective-backstop precedent, layering).
- D-005 three new halt reasons — rejected (operator action is
  identical; collapse to one).
- D-006 mtime-based freshness — rejected (filesystem behavior,
  ENG-87 chose dispatch_id).
- D-007 emit only on Decision-path C — rejected (fail paths produce
  signal too).
- D-008 checked-in fixture under `docs/` — rejected (mktemp pattern
  precedent).

The simplest possible shape — "agent writes JSON, no validator,
trust the agent" — was rejected because Linear AC #2 explicitly says
"Missing or malformed payload halts the qa stage with a clear
reason."

### Assumption inventory

Every code-level claim verified against the worktree at HEAD on
2026-05-17 (commit `fe66b5c`). `path:line` references quoted below.

| # | Assumption | Status | Reference |
|---|---|---|---|
| A1 | `bin/common.sh::issue_dir <ENG-N>` returns `$PROJECT_STATE_DIR/<ENG-N>` | verified | `bin/common.sh:68-72` |
| A2 | `bin/common.sh::failure_outcome_for_exit` maps 33→`plan-contract-malformed`, 34→`plan-contract-incomplete`, 35→`plan-contract-missing`; codes 36/37/38 are free and slot cleanly after them per the taxonomy convention (CLAUDE.md "Never use exit codes outside the taxonomy") | verified | `bin/common.sh:247-279` (table); codes 33-35 at lines 272-275; gap 36-123 confirmed (next entry is 124) |
| A3 | `bin/run-stage.sh::_clear_current_stage_slots` removes `stage-summary-${stage}.md` and `wait-${stage}.json` from `$issue_dir` on dispatch-start | verified | `bin/run-stage.sh:931-938` |
| A4 | `_clear_current_stage_slots` is called from `bin/run-stage.sh::main` at the dispatch start point | verified | `bin/run-stage.sh:1321` |
| A5 | The post-dispatch hook block in `bin/run-stage.sh::main` runs `_validate_dispatch_envelope` for `qa` (case match at line 1799) | verified | `bin/run-stage.sh:1797-1817` |
| A6 | `_validate_plan_contract` is the architectural precedent for a per-stage post-dispatch payload validator that halts on a missing / malformed JSON | verified | `bin/run-stage.sh:1036-1072` (function), `bin/run-stage.sh:1823-1835` (caller) |
| A7 | `_post_plan_contract_halt` sanitises agent-controlled bytes via `safe="${raw//<!--/<\\!--}"` plus `~~~` fenced block | verified | `bin/run-stage.sh:1077-1084` |
| A8 | `bin/pipeline-events.json::halt_reasons` is the closed-vocab registry; adding a new entry is sufficient for `bash bin/pipeline.sh event ... verdict halt --reason ...` to accept it | verified | `bin/pipeline-events.json:10-21` |
| A9 | `bin/linear.sh::add-comment` auto-injects `<!-- meta: dispatch id=… stage=… -->` when `PIPELINE_DISPATCH_ID` is set | verified (documented) | CLAUDE.md "Cross-dispatch staleness contract (ENG-87)"; behavior referenced in `bin/dispatch.sh` (PIPELINE_DISPATCH_ID exported per ENG-87) |
| A10 | AGENT_PROMPTS.md §6 (QA Agent) starts at line 1322 with fenced block bounded by §5 above and §7 below | verified | `AGENT_PROMPTS.md:1322` (§6 header), `AGENT_PROMPTS.md:1517` (§7 header) |
| A11 | AGENT_PROMPTS.md §6 has the verdict marker emission as the LAST step (lines 1494-1514) | verified | `AGENT_PROMPTS.md:1494-1514` |
| A12 | AGENT_PROMPTS.md §6 "Output" section enumerates per-path side effects but does NOT today reference verdict-qa.json | verified | `AGENT_PROMPTS.md:1481-1493` (Output bullet list) |
| A13 | `bin/qa-payload-schema.sh` does NOT currently exist | verified | `ls bin/qa-payload-schema*` returns no matches |
| A14 | `bin/qa-payload-schema-test.sh` does NOT currently exist | verified | same |
| A15 | `bin/plan-schema.sh` exists and serves as the architectural template | verified | `bin/plan-schema.sh:1-330` |
| A16 | The verdict marker protocol family (`pass|fail|halt|wait|pivot`) is enumerated in `bin/pipeline-events.json::verdict_results` | verified | `bin/pipeline-events.json:3-9` |
| A17 | `parse_pipeline_marker` family-precedence + `_strip_code_blocks_and_spans` is the sanitisation context (fenced runs are invisible to the marker grep) | verified | `bin/common.sh:291-317` |
| A18 | `bin/run-stage-test.sh` uses mktemp'd `STUB_DIR` with stubbed `linear.sh` / `gh` / `branch-name.sh`; new integration tests slot into the existing `_validate_dispatch_envelope` group around line 4093+ | verified | `bin/run-stage-test.sh:17-65` (stub setup); existing dispatch-envelope tests in this file follow the same pattern |
| A19 | The sentinel `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi` is required at end of new bin/*.sh for tests to source | verified | CLAUDE.md "How tests work — important when adding new ones" |
| A20 | The harness-self project's `.pipeline-config/config.json::dispatch.tools.qa[]` is a literal enumeration of test scripts (no wildcards) | verified (constraint) | CLAUDE.md "Wildcard pitfall" |
| A21 | `bin/dispatch-test.sh` asserts the literal-enumeration list covers every `bin/*-test.sh` on disk | verified (constraint) | CLAUDE.md "Wildcard pitfall" final paragraph |
| A22 | `bin/render-prompt.sh::PROMPT_RESOLVERS` resolves `{progress_md_path}` and `{stage_summary_path}` for §6 | verified | `bin/render-prompt.sh:49-53` (resolver map), `bin/render-prompt.sh:228-229` (resolvers) |
| A23 | `classify_failure "$ident" "$stage" "skip-until-human-acts" "<msg>" "$exit_code"` applies `pipeline:halted` via the orchestrator AFTER the dispatch exits (ENG-56) | verified (documented) | CLAUDE.md "Per-issue state directory"; mirror of the plan-contract caller at `bin/run-stage.sh:1827-1834` |
| A24 | `bin/qa-payload-schema.sh` should be added to the harness-self `dispatch.tools.qa[]` AND `dispatch.tools.implementing[]` allowlists so the qa and implement stages can BOTH run the sibling tests during their gate run | assumed | Project profile's tool allowlist for `qa` and `implementing` lists every `bin/*-test.sh`; adding the new test to both is the established pattern. Implementation step verifies by running `bash bin/dispatch-test.sh` post-edit. |
| A25 | The qa agent's existing flow already calls `bash bin/pipeline.sh event ... verdict <result>` as its terminal action, which posts the verdict marker via `linear.sh add-comment` (auto-injects `dispatch_id`) | verified | `AGENT_PROMPTS.md:1494-1514` (protocol), `bin/pipeline.sh` (writer) |
| A26 | `docs/brainstorms/2026-05-02-pipeline-vocabulary-simplification-design.md:105` already anticipates `verdict-<stage>.json` at `$issue_dir/` for ENG-31 | verified | quoted file:line above; matches D-001 location decision |
| A27 | The `_validate_qa_payload` caller does not depend on agent-contract-validator (exit 25) having succeeded — but should be sequenced after it for the same reason ENG-122 sequences `_validate_plan_contract` after the agent-contract-validator | verified | `bin/run-stage.sh:1813-1817` (envelope is between, agent-contract is upstream); OQ-4 above |
| A28 | Adding `qa-payload-invalid` to `bin/pipeline-events.json::halt_reasons` does NOT require any other registry edit (no AGENT_PROMPTS.md §0 enumeration of halt-reasons for agent-facing emission; only the orchestrator emits this reason) | assumed | The agent's verdict-marker protocol enumerates AGENT-emittable reasons (`agent-blocked | smoke-failed | iteration-exhausted | scope-violation | protocol-violation | dispatch-timeout | pr-opened-too-early`) — `dispatch-envelope-violation` and `plan-contract-invalid` are NOT in that list because the orchestrator (not the agent) emits them. `qa-payload-invalid` follows the same pattern. Verify during implement by grepping AGENT_PROMPTS.md for halt-reason allow-lists. |
| A29 | The `qa` stage's allowed-tools include `Write` (so the agent can emit verdict-qa.json) | verified | `bin/dispatch.sh::allowed_tools_for "qa"` — Write is in the stage-agnostic core implicit tool set (CLAUDE.md project-profile preamble "Stage-agnostic core tools (Read, Write, Edit, Grep, Glob, TaskCreate, …) are implicit") |
| A30 | The `qa` stage does NOT today allow `Bash(rm:*)`, so a stale verdict-qa.json that the agent wanted to remove cannot be cleaned by the agent. The orchestrator-side clear (D-006) is the correct cleanup boundary | verified | Project profile `## Tool allowlist`'s qa block does not list `Bash(rm:*)`; the memory "No scoped rm allowlist for agent stages" confirms operator policy |
| A31 | `bin/pipeline.sh event` does NOT have its own writer-side validation today (registry is Phase-1 documentation per pipeline-events.json:2) — so adding a new halt_reasons entry is sufficient for the orchestrator side, but the agent's `bin/pipeline.sh event ... verdict halt --reason ...` may not enforce the closed vocab yet | assumed | `bin/pipeline-events.json:2` self-describes as "Phase 1 parsers use this for documentation only"; D-005 here is forward-looking. Verify during implement whether the registry is wired into the writer; if not, the orchestrator's `classify_failure` path still works (it emits the marker bytes directly, not via `pipeline.sh event`). |

### Codebase-fact verification (per the prompt's MANDATORY check)

Every named function, file, exit-code, and line reference in this
brainstorm verified against the worktree at HEAD on 2026-05-17:

- `bin/common.sh::issue_dir` — `bin/common.sh:68-72` (function
  definition).
- `bin/common.sh::progress_md_path` — `bin/common.sh:78-82`.
- `bin/common.sh::failure_outcome_for_exit` table — `bin/common.sh:247-279`;
  33/34/35 mapped at lines 272-275 (plan-contract); codes 36/37/38
  unallocated in HEAD (next allocation gap before 124 →
  `dispatch-timeout`).
- `bin/run-stage.sh::_clear_current_stage_slots` — `bin/run-stage.sh:931-939`
  (function), `bin/run-stage.sh:1321` (caller).
- `bin/run-stage.sh::_validate_dispatch_envelope` — `bin/run-stage.sh:966-1030`.
- `bin/run-stage.sh::_validate_plan_contract` — `bin/run-stage.sh:1036-1072`.
- `bin/run-stage.sh::_post_plan_contract_halt` — `bin/run-stage.sh:1077-1084`.
- post-dispatch hook block running `_validate_plan_contract` —
  `bin/run-stage.sh:1819-1835`.
- post-dispatch hook block running `_validate_dispatch_envelope` —
  `bin/run-stage.sh:1797-1817`.
- `bin/dispatch.sh::_render_and_capture_stream` (envelope sidecar) —
  `bin/dispatch.sh:47-235`; sidecar at lines 54, 142-144.
- `bin/dispatch.sh::_assert_progress_md_entry` — `bin/dispatch.sh:275-293`.
- `bin/pipeline-events.json::halt_reasons` — `bin/pipeline-events.json:10-21`.
- AGENT_PROMPTS.md §6 QA Agent — header at `AGENT_PROMPTS.md:1322`,
  Output section at `AGENT_PROMPTS.md:1481-1493`, verdict-marker
  protocol at `AGENT_PROMPTS.md:1494-1514`, fence-terminator at
  `AGENT_PROMPTS.md:1515` (`§7. Build Agent` header at 1517).
- `bin/plan-schema.sh` — exists at 330 lines; header schema at
  lines 1-37 is the template `bin/qa-payload-schema.sh` will mirror.
- `bin/render-prompt.sh::PROMPT_RESOLVERS` — `bin/render-prompt.sh:41-54`;
  `stage_summary_path` resolver at line 51, `progress_md_path` at 52,
  `dispatch_id` at 53.
- `bin/qa-payload-schema.sh` — DOES NOT EXIST in HEAD (new file per
  D-003).
- `bin/qa-payload-schema-test.sh` — DOES NOT EXIST in HEAD (new file
  per D-008).
- ENG-122 brainstorm (architectural precedent) —
  `docs/brainstorms/2026-05-15-eng-122-plan-json-plan-stage-emits-structured-contract-tests-design.md:1-1036`.

## 10. Persona review

(Six personas run in order per the dispatch prompt: design → security →
scope → coherence → product → feasibility. Verdicts recorded as the
durable audit trail; the Linear `completion/brainstorm/ENG-117` comment
carries the headline only.)

### Iteration 1

**design — PASS (after iteration-1 revision).** The design slots
into the established post-dispatch detective pattern (ENG-87
precedent at `bin/run-stage.sh:1801`, ENG-122 precedent at
`bin/run-stage.sh:1827`). `bin/qa-payload-schema.sh` follows the
one-helper-per-concern convention. Module boundaries respected:
dispatch.sh stays thin, run-stage.sh owns the post-dispatch hook,
common.sh extends narrowly (three new outcome-token cases). The
schema is intentionally minimal (one dimension array, four required
per-record fields) and forward-extensible via the permissive-on-
unknown-fields contract (D-005).

The extension to `_clear_current_stage_slots` (D-006) is a single
load-bearing line that generalises cleanly to the parallel review-
payload sub-ticket via the `${stage}` parameter — a clean win for
architectural symmetry across the parent ENG-31 umbrella.

**P1 raised + resolved during iteration 1:** the original draft
reused exit codes 33/34/35 from the ENG-122 plan-contract case,
keeping outcome tokens `plan-contract-*`. Feasibility persona
flagged this as a real `events.jsonl::outcome` contamination
hazard: qa-payload events would be filed under plan-contract in the
retrospective's §1 outcome-grouping, masking the root cause.
**Resolution:** D-003 + D-005 revised in iteration 1 to introduce
NEW exit codes 36/37/38 with stage-specific outcome tokens
(`qa-payload-malformed`, `qa-payload-incomplete`,
`qa-payload-missing`). Three new codes is the smallest taxonomy
extension that preserves accurate retro-side grouping.

Minor (P2): if a third per-stage payload validator lands later
(e.g. review-payload — sibling sub-ticket — or building-payload),
the `case "$stage" in` block in the post-dispatch hook will grow
linearly. Folding into a helper `_dispatch_post_validators "$stage"`
is plausible follow-up; not in scope today. **The parallel review-
payload sub-ticket will need its own exit codes (proposed 39/40/41
or similar) — flagged here so the parallel author can avoid a
collision when both tickets land.**

**security — PASS.** No new attack surface:

- No new Linear API calls beyond the halt-comment emission, which
  flows through `bin/linear.sh add-comment` (ENG-87 chokepoint per
  `bin/linear.sh::_inject_dispatch_marker`).
- Validator stdout is inlined into the halt comment body; D-004 +
  `_post_qa_payload_halt` mirror the envelope validator's
  sanitisation pattern (`safe="${raw//<!--/<\\!--}"` plus `~~~`
  fenced wrap) at `bin/run-stage.sh:1016`. An agent-controlled JSON
  file with an embedded `<!-- pipeline: verdict result=pass -->`
  substring cannot hijack the verdict family.
- No new file-system reads outside `$issue_dir/verdict-qa.json`.
- `bin/qa-payload-schema.sh validate` reads a JSON file with `jq`
  — no shell expansion of file content; jq is the only consumer.
- `dispatch_id` cross-check (D-002 + D-003) defends against stale-
  template injection where an agent copy-pastes a sibling issue's
  JSON.
- The clear-on-dispatch-start primitive (D-006) defends against
  cross-dispatch read of stale verdict-qa.json.
- Secret-handling per ENG-46: only `${PIPELINE_DISPATCH_ID:-unknown}`
  is used as a fallback default for an env var, and `PIPELINE_DISPATCH_ID`
  does not match the secret regex (`*KEY|*TOKEN|*SECRET|ANTHROPIC*|GITHUB*|LINEAR*`).

Minor (P2): the `--dispatch-id` flag to `bin/qa-payload-schema.sh
validate` accepts agent-controlled bytes if a future caller passes
the value from an untrusted source. Today the caller is
`run-stage.sh::_validate_qa_payload` which passes
`$PIPELINE_DISPATCH_ID` (orchestrator-controlled). Implementation
should ensure the flag parser doesn't shell-interpret the value
(quoted, no `eval`). `bin/plan-schema.sh:62-78` provides the
template for safe flag-arg parsing.

**scope — PASS.** Every section traces to a Linear scope bullet:

- Schema definition (D-002) → IN bullet 1 ("Schema for
  `$issue_dir/verdict-qa.json` (per-dimension scores + rationale +
  thresholds met/missed)").
- AGENT_PROMPTS.md §6 update (D-007) → IN bullet 2 ("AGENT_PROMPTS.md
  qa section instructs agent to emit the payload").
- Detective scan (D-004) → IN bullet 3 — *Note: Linear scope says
  "bin/dispatch.sh detective scan asserts the payload exists and is
  well-formed". This is the same mis-statement ENG-122 flagged. The
  correct architectural layer is `bin/run-stage.sh`, mirroring
  ENG-87's `_validate_dispatch_envelope` and ENG-122's
  `_validate_plan_contract`. D-004 honors the design intent ("post-
  dispatch state check"); the layer choice is justified in D-004's
  "Rejected alternative — fire from dispatch.sh" paragraph.*
- Tests cover payload parsing + missing-payload halt (D-008) → IN
  bullet 4 + AC #3.

Scope-creep flags: **None.** The doc explicitly defers:

- The threshold-logic ticket (OUT bullet — D-002 declines to gate
  on `threshold_met`, only records).
- The review-payload ticket (parallel-safe; D-003 chose per-stage
  validators to avoid merge conflict).
- A canonical dimension vocab (OQ-1 defers to threshold ticket).
- A `events.jsonl` stream of qa scores (OQ-3 defers to a follow-up).
- A `bin/verdict-schema.sh` shared helper (OQ-7 defers to threshold
  ticket consolidation moment).

Linear scope mis-statement to flag in stage summary: "bin/dispatch.sh
detective scan" — in fact the detective lives in `bin/run-stage.sh`,
matching ENG-87 + ENG-122 (post-dispatch state checks live there).
Documented in D-004's Rejected alternative paragraph; the
implementation will honor design intent (post-dispatch state check)
in the correct architectural layer.

**coherence — PASS.** Goal ("emit a sibling verdict-qa.json …")
matches the AC. Data Flow §4 covers dispatch-start clear → agent
emission → detective → halt-on-fail → resume. Error Handling §5
maps each failure mode to a recovery path. Edge Cases §6 covers 8
known shapes including the back-fill PR and dry-run cases.
Architecture diagram in §3 names every file modified + created.

The cross-dispatch staleness story is internally coherent: D-006
(clear-on-dispatch-start) AND D-002 (`dispatch_id` field +
cross-check) are described as belt-and-braces in two different
sections (D-002 rationale + Error Handling §5 + Edge Cases §6
re-dispatch case).

Minor (P2): the relationship between `verdict` field (top-level in
verdict-qa.json) and the verdict marker comment (`<!-- pipeline:
verdict result=<x> -->`) could be a source of confusion. Both must
agree; the schema doesn't enforce coupling. **Resolution:** the
agent prompt's step 8 emits `verdict` matching what step 7's
verdict-marker emits; the threshold ticket will read both and assert
agreement if needed. Today's brainstorm acknowledges the soft
coupling in OQ-3 (events.jsonl follow-up); a strict cross-check is
out of scope for the foundation slice.

**product — PASS.** Foundation work for the threshold-logic ticket
+ the retrospective. User impact ladder:

1. Today: qa-stage verdicts are one bit (pass/fail) + free-form
   prose. Per-dimension reasoning is lost between the agent's mind
   and the operator's Linear scroll.
2. Post-ENG-117: qa emits a structured per-dimension payload on
   every dispatch. Operators can inspect dimensional scores at
   `$issue_dir/verdict-qa.json` (or via a `bin/status.sh` follow-up).
3. Post-threshold-ticket: the threshold reader gates `pass` on
   dimensional minimums; the qa stage's verdict is now a
   transparent function of the dimensional payload.
4. Post-retrospective integration: longitudinal series of
   per-dimension scores feeds the weekly retro's outcome filter.

The product principle ("Don't add features ... beyond what the task
requires", CLAUDE.md) is honored: ONE new file (`bin/qa-payload-schema.sh`),
ONE new test (`bin/qa-payload-schema-test.sh`), ONE validator helper
in run-stage.sh, ONE halt reason in the registry, ZERO new exit
codes. The OQs explicitly defer dimension-vocab closure, weighting,
events.jsonl streaming.

Minor (P2): the agent prompt's "Suggested starter dimensions" list
(D-007) could be too directive — the threshold ticket might
converge on a different set. **Resolution:** the prose explicitly
says "not mandated — the threshold ticket will decide the canonical
set"; the suggestion is hint-only and discardable.

**feasibility — PASS (after iteration-1 revision), zero P0.** Every
code-level claim verified against the worktree at HEAD on 2026-05-17
(commit `fe66b5c`). Assumption Inventory §9 quotes 31 `path:line`
references; 3 are marked "assumed" with explicit verify-during-
implement hand-offs (A24, A28, A31 — three items concerning the
harness-self test allowlist, the agent-facing halt-reason allow-list
in AGENT_PROMPTS.md, and the writer-side validation of
pipeline-events.json). All other 28 assumptions are verified against
actual code or CLAUDE.md canonical surfaces.

**P1 raised + resolved during iteration 1 (carried from design):**
The original draft reused exit codes 33/34/35 (named `plan-contract-*`)
for qa-payload failures. `failure_outcome_for_exit 33` returns
`plan-contract-malformed` — this token would land in
`events.jsonl::outcome` for every qa-payload-malformed event,
silently grouping qa-payload incidents with plan-contract incidents
in the weekly retrospective's §1 outcome-grouping. The token names
in `common.sh:272-275` are stage-specific by name, not by the
underlying defect class. Resolution: D-003 + D-005 revised to add
NEW codes 36/37/38 with NEW outcome tokens
(`qa-payload-malformed`, `qa-payload-incomplete`,
`qa-payload-missing`).

Notes for the planning agent (no P0, all P2):

- `bin/qa-payload-schema.sh` must end with the source-and-test
  sentinel per CLAUDE.md "How tests work."
- The schema in `bin/qa-payload-schema.sh`'s header comment is the
  single source of truth; the inline schema example in
  AGENT_PROMPTS.md §6 must be kept in sync with a small fixture-
  sanity test in `bin/qa-payload-schema-test.sh` (mirror ENG-122
  D-006 + design persona's drift-mitigation suggestion).
- The new halt reason `qa-payload-invalid` must be added to
  `bin/pipeline-events.json::halt_reasons`. AGENT_PROMPTS.md does
  NOT enumerate orchestrator-emitted halt reasons in the
  agent-facing allow-list at the verdict-marker protocol (cf.
  `dispatch-envelope-violation`, `plan-contract-invalid` — neither
  appears in agent-facing reason lists); A28 marks this assumed,
  verify during implement.
- The harness-self target's `dispatch.tools.qa[]` AND
  `dispatch.tools.implementing[]` must include the new
  `bin/qa-payload-schema-test.sh` entry; regenerate per the
  CLAUDE.md "Wildcard pitfall" TESTS snippet.
- `_validate_qa_payload` is sequenced AFTER both
  `_validate_dispatch_envelope` and `_validate_plan_contract` (OQ-4).
  The case-statement should be appended to the existing post-
  dispatch hook block, NOT folded into the prior cases (the
  plan-contract block at run-stage.sh:1823-1835 already has its own
  `if (( ! skip_dispatch )); then case … esac fi` shape; mirror it).
- The `Write` tool is in qa's stage-agnostic core implicit tool set
  (A29); no allowed-tools change is needed.
- `bin/common.sh:247-279` extension: codes 36/37/38 slot AFTER 35
  (`plan-contract-missing`) and BEFORE 124 (`dispatch-timeout`).
  A pre-existing entry at 30 (`noop-implementation`) and at
  31 (`progress-md-entry-missing`) confirms the numeric gap between
  ENG-122's 33-35 and 124 is intentional/conventional for future
  detective extensions.

**Verdict: 6/6 PASS, 0 P0. Gate satisfied. Proceeding to plan stage.**

(Three items absorbed into the design during iteration 1:
(1) the `--dispatch-id` flag's argument-quoting safety note (security
P2 → noted in feasibility hand-off);
(2) the soft-coupling note between the JSON `verdict` field and the
verdict-marker (coherence P2 → resolved in OQ-3);
(3) the exit-code reuse → `events.jsonl::outcome` contamination (design
P1 / feasibility P1 — same root cause flagged by both personas →
resolved by adding codes 36/37/38 with stage-specific outcome
tokens).
No iteration 2 needed.)
