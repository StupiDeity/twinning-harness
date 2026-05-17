---
linear: ENG-119
title: Dimensional grading — review-stage verdict payload
date: 2026-05-17
status: draft
---

# Dimensional grading — review-stage verdict payload

## 1. Problem

Today the review agent (`AGENT_PROMPTS.md` §5, lines 1064–1320) reaches
its verdict through a multi-persona ensemble (six sub-agents:
correctness / testing / maintainability / scope-via-anti-bias / and
conditionally security / performance / api-contract) plus an anti-bias
pass that the agent runs itself. The verdict it emits is a single bit:
`verdict pass --stage reviewing` (clean), `verdict fail --target
implementing` (changes requested), or `verdict fail --target
brainstorming` (premise failure). Everything the ensemble surfaced
about *why* — which dimensions passed, which were concerning, which
explicit thresholds were met or missed — collapses into that bit, plus
prose in the Linear stage-summary comment and per-finding PR review
comments.

The umbrella ticket ENG-31 wants dimensional grading on review and QA
verdicts: a structured per-dimension payload alongside the verdict so
that (a) the threshold-logic ticket ENG-118 can gate the verdict on a
deterministic rule (e.g. "any dimension scoring `fail` ⇒ request
changes"), (b) the retrospective agent can read which dimensions
correlate with downstream failures, and (c) operators get a stable
machine-readable snapshot of the review's structured findings beyond
prose.

ENG-119 is the foundation sub-ticket for the review side: emit
`$issue_dir/verdict-review.json` with per-dimension scores + rationale
+ thresholds met/missed, and add the detective scan that halts a
review dispatch if the payload is missing or malformed. Threshold
logic (ENG-118) and the parallel QA payload (ENG-117) are explicitly
out of scope.

## 2. Decisions

### D-001. The payload lives at `$issue_dir/verdict-review.json` (outside the worktree, in per-issue state), overwritten on every review dispatch.

**Rationale.** The Linear scope explicitly names
`$issue_dir/verdict-review.json`. That places the file in the same
storage tier as the existing per-issue, per-dispatch artifacts the
orchestrator already manages: `usage-<stage>.json` (cost telemetry,
written by `dispatch.sh` per dispatch — `bin/dispatch.sh:88-102`),
`wait-<stage>.json` (soft-pause budget — `bin/run-stage.sh:697`),
`stage-summary-<stage>.md` (per-stage exit verdict, overwrite-on-every-dispatch
per the ENG-77/ENG-71 contract — `AGENT_PROMPTS.md:164-211`).

It is NOT inside the worktree (`$(issue_dir)/worktree/`) because:
(a) the file is ephemeral state, not a committed artifact — every
review dispatch overwrites it and the previous content has no
archival value beyond the retrospective's metrics stream;
(b) writing inside the worktree would put it in scope for
`partition_dirty_paths` (`bin/run-local-helpers.sh`) and force either
a `.gitignore` entry or special-case scope handling, neither of which
matches the established per-issue-state pattern.

Lifecycle: overwritten on every review dispatch (same shape as
`stage-summary-reviewing.md`). Cleared on `--action continue` resume
only when the orchestrator-side `_clear_current_stage_slots` removes
the current stage's slots; otherwise it persists across the
review→implement loopback for the implement agent to inspect (the
brainstorm does NOT add a reader of the file in this ticket, but
future readers — ENG-118, retrospective — benefit from durability).

**Reference to constraint.** CLAUDE.md "Per-issue state directory" —
the directory holds `issue-state.json`, the `worktree/` subdir,
`usage-<stage>.json`, `wait-<stage>.json`, `stage-summary-<stage>.md`,
and the proposed `verdict-<stage>.json` family
(`docs/brainstorms/2026-05-02-pipeline-vocabulary-simplification-design.md:104-105`
proposed this shape). `verdict-review.json` fits the existing tier
without inventing a new one.

**Reference to constraint.** CLAUDE.md "Per-project state must
reference `$PROJECT_STATE_DIR`, never `$HARNESS_STATE_DIR/<issue>`
directly" — resolution goes through
`bin/common.sh::issue_dir "$ident"` (`bin/common.sh:68-72`), which is
the canonical helper.

**Rejected alternative — put the file inside the worktree at
`docs/reviews/<date>-<issue>.json`** (mirroring the ENG-122
`docs/plans/<basename>.json` shape). Rejected because:
(a) ENG-122 plan.json is a *committed plan contract* — readers
include reviewers on GitHub PRs and future plan-stage runs that
re-read prior plans for context. The review verdict has no
cross-PR / cross-issue readership; archiving it in git is gratuitous;
(b) inside-worktree would require either `.gitignore` plumbing or
agent-side cleanup before commit, both of which conflict with the
clean orchestrator-owns-cleanup boundary at
`bin/run-local-helpers.sh::clean_scratch_dir`;
(c) the Linear scope text is explicit about `$issue_dir/`.

**Rejected alternative — append a JSON record to a rolling
`$issue_dir/verdict-review.jsonl` instead of overwriting.** Rejected
because:
(a) the threshold-logic ticket (ENG-118) needs the *latest* iteration's
verdict, not history. Overwriting gives that for free;
(b) the existing `usage-<stage>.json` / `stage-summary-<stage>.md`
pair already follows overwrite-per-dispatch with the audit trail
captured separately in `dispatch_history.jsonl` (orchestrator-owned,
forensic-only) — same shape, no new pattern to invent;
(c) JSONL would invite readers to make per-iteration decisions
(comparing iter N vs N+1) which is reader scope, not producer scope.

### D-002. Schema — `review_schema_version: 1`, top-level `issue_id` + `dispatch_id` + `sha` + `verdict` + a `dimensions` object keyed by dimension name. Four required dimensions (correctness, testing, maintainability, scope); the four conditional ones (security, performance, api_contract, premise) are accepted but optional.

**Rationale.** The Linear scope says "per-dimension scores + rationale
+ thresholds met/missed." That decomposes to four fields per
dimension: `score`, `rationale`, `thresholds_met[]`, `thresholds_missed[]`.

Schema sketch (canonical version lives in the validator's file-header
comment per D-003; CLAUDE.md "Don't add features … beyond what the task
requires" — no separate `docs/review-payload-schema.md`):

```json
{
  "review_schema_version": 1,
  "issue_id": "ENG-119",
  "dispatch_id": "ENG-119-d0003",
  "sha": "0a51c68f...",
  "verdict": "request-changes",
  "dimensions": {
    "correctness": {
      "score": "concern",
      "rationale": "1 major: unsigned-shift suspicion in handler.ts:42; 0 critical",
      "thresholds_met":   ["no contract drift", "no failure-mode-test-map gaps"],
      "thresholds_missed": ["zero major findings"]
    },
    "testing":         { "score": "pass",    "rationale": "...", "thresholds_met": [...], "thresholds_missed": [] },
    "maintainability": { "score": "pass",    "rationale": "...", "thresholds_met": [...], "thresholds_missed": [] },
    "scope":           { "score": "pass",    "rationale": "...", "thresholds_met": [...], "thresholds_missed": [] }
  }
}
```

**Required top-level fields (validator P0):**

* `review_schema_version` — integer, must equal `1`.
* `issue_id` — string matching `^ENG-[0-9]+$`; cross-checked against
  the validator's `--ident` argument (defense-in-depth — D-006).
* `dispatch_id` — string matching `^ENG-[0-9]+-d[0-9]{4}$`;
  cross-checked against the validator's `--dispatch-id` argument
  (ENG-87 staleness contract; D-006).
* `sha` — non-empty string (no hex regex — short SHAs and full SHAs
  both valid; the agent uses whatever `gh pr view` returned).
* `verdict` — one of `approve` / `request-changes` / `premise-failure` /
  `halt`, mirroring the existing Decision-path A/B/C in
  `AGENT_PROMPTS.md:1216-1255` plus the agent-blocked exit ramp at
  `AGENT_PROMPTS.md:1311-1313`. The `halt` value covers the case where
  the agent reaches the payload-write step but cannot reach a clean
  Decision-path verdict (e.g. tool blocked, validator failure). On
  `halt`, the agent populates dimensions with whatever findings the
  ensemble surfaced before the block (the ensemble runs BEFORE the
  Decision-path selection per `AGENT_PROMPTS.md:1100-1128`, so the
  required dimensions ARE inspected by then) and the operator gets
  both the payload AND the halt comment as triage signal.
* `dimensions` — object, MUST contain the four required keys:
  `correctness`, `testing`, `maintainability`, `scope`. Conditional
  keys (`security`, `performance`, `api_contract`, `premise`) are
  accepted; unknown keys log a warning and pass (see "Permissive on
  unknown fields" clause below).

**Per-dimension required fields:**

* `score` — one of `pass` / `concern` / `fail`. Three-state, not Likert.
  `pass` = no findings worse than `minor`. `concern` = ≥1 `major`
  finding. `fail` = ≥1 `critical` finding. The mapping is established
  in the prompt text, not encoded in the schema (the validator does
  not enforce it; it would invent semantic policy that belongs in the
  agent prompt — schema is structural).
* `rationale` — non-empty string, soft-limit ≤200 chars
  (informational only — the validator does NOT length-check; over-long
  rationales are acceptable, they just clutter the payload).
* `thresholds_met` — array of strings (may be empty). **Free-text
  narrative, NOT a closed vocabulary.** Intended audience: the
  retrospective agent and operator post-halt triage.
* `thresholds_missed` — array of strings (may be empty). Same
  contract as `thresholds_met`.

**Reader contract for the threshold arrays.** ENG-118's threshold
gating reads only the `score` field — three-state policy is the
exhaustive v1 input. The `thresholds_met` / `thresholds_missed`
arrays are descriptive narrative captured for retrospective trend
analysis, NOT machine-readable gate input. Future shippers wanting
to gate on specific thresholds should add a typed
`gated_thresholds` field under a `review_schema_version: 2` bump
rather than scraping the v1 free-text arrays. Documenting this here
prevents the consumer-side ambiguity raised in product-persona P1.

**Rationale — three-state score (not Likert 0-5):**
The existing review-prompt severity vocabulary is four-level
(`critical` / `major` / `minor` / `nit` — `AGENT_PROMPTS.md:1122-1127`).
Three-state collapses cleanly onto that ladder. Numeric scores would
invite (a) false precision (what does "3 vs 4" actually mean?),
(b) noisier retrospective signal (now every dimension has 6×8 = 48
possible permutations), (c) pressure to redesign the prompt's severity
ladder. Three-state matches CLAUDE.md "Don't introduce abstractions
beyond what the task requires."

**Rationale — four required dimensions:**
The four are the ones the prompt mandates unconditionally on every
review: correctness, testing, maintainability all come from the
always-on sub-agents; `scope` is required because every review's
anti-bias pass runs the scope enforcement clause
(`AGENT_PROMPTS.md:1175-1184`). The four conditional dimensions
(`security`, `performance`, `api_contract`, `premise`) are emitted
when their conditions fire — security/performance per
`AGENT_PROMPTS.md:1112-1115`, `api_contract` per the FE↔BE trigger
at `AGENT_PROMPTS.md:1116-1119`, `premise` only when Decision-path A
fires. Making them required would force the agent to fabricate a
`pass` score in their absence, which loses the "this dimension was
not exercised" signal.

**Rationale — `verdict` field is denormalized.**
The verdict marker (`bin/pipeline.sh event ... verdict pass|fail
--stage|--target ...` — written via `bash bin/linear.sh add-comment`)
is the single source of truth for the orchestrator's state machine.
The payload's `verdict` field is a denormalization the retrospective
can read without joining against Linear comments. Future
threshold-gating (ENG-118) MAY use it to detect agent-self-inconsistency
(e.g. dimensions all `fail` but `verdict: approve`). The agent is
required to keep both in sync; that's a prompt rule, not a validator
rule — the validator checks structural well-formedness, not
cross-source agreement (which is CLAUDE.md "Don't add error handling …
for scenarios that can't happen"; if the agent lies, that's the
prompt's failure mode, not this validator's).

**Reference to product principle.** CLAUDE.md "Don't add features
… beyond what the task requires" — four required + four optional
dimensions reflect *exactly* the prompt's existing structure; the
schema introduces no novel dimensions and does not pre-decide
ENG-118's threshold-mapping policy.

**Reference to constraint.** CLAUDE.md "Per-stage allowed tool
lists are centralized in `dispatch.sh::allowed_tools_for`" — the
same centralization principle says one canonical place per concern.
`bin/review-payload-schema.sh` (D-003) is that place for this
schema; the schema doc lives in the validator's header comment.

**Rejected alternative — JSON Schema (jsonschema-org spec) validation.**
Rejected for the same reasons as ENG-122 D-002: the harness uses
only bash + jq, and jsonschema's expressivity is overkill for an
8-field schema.

**Rejected alternative — embed dimensions as a `dimensions: []` array
rather than an object.** Rejected because (a) the array form forces
readers to scan-then-key-match (`dimensions | map(select(.name=="testing"))`),
which is awkward in jq; (b) duplicate-key prevention is free with
the object form; (c) future readers (ENG-118 threshold gating) want
keyed access by dimension name.

**Rejected alternative — model dimensions as a 6-field flat object
at the top level (`correctness_score`, `correctness_rationale`, ...).**
Rejected because (a) it forces a schema bump for every new dimension
instead of nesting under the existing `dimensions` key; (b) jq
projection is harder (no `to_entries | .[] | .key`).

### D-003. Validator implementation lives at `bin/review-payload-schema.sh` as a standalone CLI with a `validate <file> [--ident <ENG-N>] [--dispatch-id <id>]` subcommand. Exit codes: 0 valid, 36 malformed, 37 incomplete, 38 missing-file.

**Rationale.** Identical to ENG-122 D-003's argument for a dedicated
file (`docs/brainstorms/2026-05-15-eng-122-...md:184-260`): single
concern, ~100 lines of jq, unit-testable in isolation via the
source-and-stub pattern, operator can use it as a one-liner repro
post-halt (`bash bin/review-payload-schema.sh validate
$issue_dir/verdict-review.json --ident ENG-119 --dispatch-id
ENG-119-d0003`).

**Exit-code split (36/37/38):**

* **38 (missing-file):** the review agent exited but produced no
  payload file — operator inspects whether the agent forgot the
  `Write` step or whether `Write` failed.
* **37 (incomplete):** the JSON exists and parses but is missing a
  required field (`review_schema_version`, an `issue_id` mismatch
  against `--ident`, a `dispatch_id` mismatch against `--dispatch-id`,
  a missing required dimension, a malformed enum value).
* **36 (malformed):** `jq` failed to parse the JSON at all — operator
  inspects for a heredoc-quoting bug or stray prose in the file body.

**Three new exit codes.** Following the ENG-122 D-003 precedent at
`bin/common.sh:247-279`: 32 is currently unused; 33/34/35 are
plan-contract; 36/37/38 slot cleanly after.
`bin/common.sh::failure_outcome_for_exit` gets three new entries:

| Exit code | Outcome token              | Halt reason            |
|-----------|----------------------------|------------------------|
| 36        | `review-payload-malformed` | `review-payload-invalid` |
| 37        | `review-payload-incomplete`| `review-payload-invalid` |
| 38        | `review-payload-missing`   | `review-payload-invalid` |

All three map to a single new halt reason
`review-payload-invalid` in `bin/pipeline-events.json::halt_reasons`
(joining the ten existing entries — `agent-blocked`, `agent-failure`,
`smoke-failed`, `iteration-exhausted`, `scope-violation`,
`protocol-violation`, `dispatch-timeout`, `pr-opened-too-early`,
`dispatch-envelope-violation`, `plan-contract-invalid`). The
fine-grained outcome tokens give the retrospective enough signal to
distinguish root causes; the coarse halt reason gives the operator a
single mental model.

**Reference to constraint.** CLAUDE.md "Never use exit codes outside
the taxonomy in `failure_outcome_for_exit`" — three new codes are
added to the taxonomy in step 1 of the implementation, before any
caller emits them. Mirrors ENG-122's identical sequencing.

**Rejected alternative — fold the validator into `bin/common.sh`.**
Same rejection as ENG-122 D-003: widens common.sh, loses CLI
testability + operator repro one-liner.

**Rejected alternative — share a single
`bin/dimension-payload-schema.sh` between review and qa
(anticipating ENG-117).** Rejected because (a) the dimensions
themselves differ semantically between review (reviewer-personas)
and qa (verification-vs-evaluation per ENG-38), so the "shared"
validator would still need a stage-discriminator and per-stage
required-keys table; (b) ENG-117 is explicitly parallel-safe in the
Linear scope, meaning it should ship without coordinating on a
shared module; (c) premature generalization for a single consumer
violates CLAUDE.md "Don't add features … beyond what the task
requires." A future cleanup ticket can merge if both validators
prove substantially similar.

### D-004. Detective scan — `bin/run-stage.sh::_validate_review_payload` runs after `_validate_dispatch_envelope` and `_validate_plan_contract` in the post-dispatch hook block, stage-gated to `reviewing` only. Halts the dispatch with the appropriate exit code + halt comment body when the validator returns non-zero.

**Rationale.** The established post-dispatch scan pattern is
`_validate_dispatch_envelope` (ENG-87,
`bin/run-stage.sh:966-1030`) and `_validate_plan_contract`
(ENG-122, `bin/run-stage.sh:1036-1072`). Both run after the agent
exits, look at a per-issue artifact, post a halt comment on
violation, exit with a specific code. The review-payload validator
is the same shape and slots co-located.

**Concrete placement** (immediately after the ENG-122
`_validate_plan_contract` block at `bin/run-stage.sh:1823-1835`):

```bash
if (( ! skip_dispatch )); then
  case "$stage" in
    reviewing)
      local _rev_rc=0
      _validate_review_payload "$ident" || _rev_rc=$?
      if (( _rev_rc != 0 )); then
        classify_failure "$ident" "$stage" "skip-until-human-acts" \
          "review-payload-invalid: $(failure_outcome_for_exit "$_rev_rc")" "$_rev_rc"
        exit "$_rev_rc"
      fi
      ;;
  esac
fi
```

**Validator helper signature:**

```bash
_validate_review_payload() {
  local ident="$1"
  local payload; payload="$(issue_dir "$ident")/verdict-review.json"
  if [[ ! -f "$payload" ]]; then
    _post_review_payload_halt "$ident" "missing-file" \
      "no verdict-review.json at $payload"
    return 38
  fi
  local out rc=0
  out="$(bash "$SCRIPT_DIR/review-payload-schema.sh" validate "$payload" \
         --ident "$ident" --dispatch-id "${PIPELINE_DISPATCH_ID-}")" || rc=$?
  case "$rc" in
    0)  return 0 ;;
    36) _post_review_payload_halt "$ident" "malformed"  "$out" ; return 36 ;;
    37) _post_review_payload_halt "$ident" "incomplete" "$out" ; return 37 ;;
    *)  _post_review_payload_halt "$ident" "unexpected-rc" \
          "validator returned unexpected rc=$rc; stdout: $out" ; return 36 ;;
  esac
}
```

**Sanitisation requirement.** Validator stdout is partially
agent-controlled (it interpolates the agent's `verdict-review.json`
content into diagnostic messages). When interpolated into the halt
comment body, an embedded `<!-- pipeline: verdict result=pass -->`
substring would be picked up by `parse_pipeline_marker`'s
family-precedence selector and promote the halt INTO a forward pass
on the next `find_fresh_verdict` read.

`_post_review_payload_halt` MUST mirror the ENG-87 / ENG-122
sanitisation at `bin/run-stage.sh:1014-1016` and
`bin/run-stage.sh:1079`: `safe="${raw//<!--/<\!--}"` plus wrap in a
triple-backtick fenced block (the marker parser's
`_strip_code_blocks_and_spans` removes fenced runs before grep'ing
for markers).

**Halt comment body** (posted by `_post_review_payload_halt` via
`bash bin/linear.sh add-comment`, NOT `add-or-update-comment` —
verdict markers are append-only per CLAUDE.md "Verdict-marker
protocol"):

```
<!-- pipeline: verdict result=halt reason=review-payload-invalid -->

Review-payload validation failed on dispatch_id=<id> stage=reviewing:

- Defect: <missing-file|malformed|incomplete|unexpected-rc>

```
<validator stdout>
```

Expected: <absolute path resolved from issue_dir at emission, e.g.
          /Users/.../twinning-harness/harness/ENG-119/verdict-review.json>
Schema: see bin/review-payload-schema.sh (header comment)

**Resume:** fix the agent prompt (or re-render the payload by hand),
then run `bash bin/pipeline.sh decide <ENG-N> --action continue`.
```

**Reference to constraint.** CLAUDE.md "Defense-in-depth: when a
stage's contract says 'agent must not invoke tool X,' prefer a
transcript-based assertion … over a post-dispatch state check." This
rule applies to *tool denials* — the review-payload contract is a
state requirement (a specific file must exist with a specific shape),
not a tool denial. Post-dispatch state check is the correct shape for
this failure mode and matches the agent-contract-validator + ENG-106
filesystem detective precedents at `bin/dispatch.sh:265-269` and
`bin/run-stage.sh:1819-1835`.

**Reference to constraint.** CLAUDE.md "Linear writes go through
`bin/linear.sh` so dry-run + `meta: dedup` work uniformly" — the halt
comment is emitted via `add-comment` (NOT `add-or-update-comment`)
because verdict markers are append-only by protocol; the auto-
injected `<!-- meta: dispatch id=… -->` marker is owned by
`bin/linear.sh::_inject_dispatch_marker` (`bin/linear.sh:60-71`).

**Rejected alternative — make the validator a transcript scan
(check that the agent's `Write` tool was invoked with file_path
ending in `/verdict-review.json`).** Rejected because (a) it only
catches the absence-of-Write case, not the malformed-JSON case;
(b) a successful `Write` does not guarantee the content is the JSON
we want (could be a placeholder, a Python script, anything). A
filesystem + jq parse check is strictly stronger; transcript scan is
not a substitute, just defense-in-depth on top — and we don't add
defense-in-depth speculatively (YAGNI). The CLAUDE.md preference for
transcript-based assertions is specifically about *tool denials* (don't
let a forbidden tool fire), which is the inverse problem.

**Rejected alternative — run the validator inside `dispatch.sh`'s
`_render_and_capture_stream` post-stream block.** Same rejection as
ENG-122 D-004: dispatch.sh is the thin claude-wrapper layer; expanding
its responsibilities pulls Linear-API calls into its failure path.

### D-005. Agent prompt updates — `AGENT_PROMPTS.md` §5 acquires (a) a new `{verdict_review_path}` token in the Output section, (b) a `Write` step at the same lifecycle position as the stage-summary file, (c) an example dimension payload in the prompt body.

**Rationale.** The agent's exit sequence today is documented in
`AGENT_PROMPTS.md:1265-1294`:

```
Output:
- Per-finding PR review comments via gh pr review --comment
- Consolidated Linear review summary as a completion/reviewing/{issue_id}
  add-or-update-comment
- Stage-summary file at {stage_summary_path}
- Verdict per Decision path
- Append a progress.md entry BEFORE posting the verdict marker (Path C only)
Verdict marker (MANDATORY at exit)
```

The new payload write slots immediately after the stage-summary
file write (same lifecycle bullet shape). The prompt body explains
the schema with an example block and references
`bin/review-payload-schema.sh`'s header comment as the
source-of-truth schema doc. The agent is instructed to emit the
file on **all three** Decision paths (A premise-failure / B
changes-requested / C clean) so the detective scan is unconditional
within `reviewing`. On Decision-path A, dimensions reflect why the
brainstorm was wrong; `verdict: "premise-failure"`. On Decision-path
B, dimensions reflect the unresolved concerns; `verdict:
"request-changes"`. On Decision-path C, all dimensions
`score: "pass"`; `verdict: "approve"`.

**Token interpolation.** Add `verdict_review_path` to
`bin/render-prompt.sh::PROMPT_RESOLVERS` (`bin/render-prompt.sh:41-57`)
with a sibling resolver `_resolve_verdict_review_path() { printf
'%s' "$_RENDER_VERDICT_REVIEW_PATH"; }` mirroring the existing
`_resolve_stage_summary_path` shape (`bin/render-prompt.sh:228`).
Bind `_RENDER_VERDICT_REVIEW_PATH="$(issue_dir
"$issue_id")/verdict-review.json"` in `main()` at the same site as
`_RENDER_STAGE_SUMMARY_PATH` (`bin/render-prompt.sh:484`).

**Reference to constraint.** CLAUDE.md "AGENT_PROMPTS.md is
load-bearing" — the prompt file's fence-count + section-table
invariants are preserved (no new H2 sections, no nested fences
inside the body).

**Reference to constraint.** CLAUDE.md "Cross-dispatch staleness
contract (ENG-87)" — the prompt explicitly instructs the agent
to populate `dispatch_id` from the rendered `{dispatch_id}` token,
and the schema validator cross-checks it against
`PIPELINE_DISPATCH_ID` (D-006). The payload is overwrite-on-every-dispatch
(matching the stage-summary contract), so loopback-iteration
freshness is enforced both by mtime semantics and the dispatch_id
field.

**Rejected alternative — make the agent emit raw JSON via `printf`
through `bash bin/linear.sh add-comment` (i.e. attach the payload
to a Linear comment instead of writing a file).** Rejected because
(a) Linear comments are append-only (CLAUDE.md "Verdict-marker
protocol"), making per-dispatch overwriting impossible; (b) the
threshold-gating consumer (ENG-118) wants a fast filesystem lookup,
not a Linear API call; (c) it conflates the human-facing prose
narrative (completion comment) with the machine-readable payload.

### D-006. Validator cross-checks `issue_id` and `dispatch_id` against orchestrator-supplied flags. Mismatch returns rc=37 (incomplete) with a specific defect message.

**Rationale.** ENG-87's cross-dispatch staleness contract treats
strict ID-equality as the canonical freshness check (CLAUDE.md "Glue:
`PIPELINE_DISPATCH_ID`"). Two failure modes the cross-check catches:

1. **Stale file from prior dispatch.** Pre-clean of the payload
   could fail; an old `verdict-review.json` from dispatch N-1
   sits on disk; the agent in dispatch N exits without writing
   (e.g., crashes after stage-summary write but before payload
   write). Without the cross-check, the detective sees a present
   file and passes; the threshold-gating consumer reads stale data.
   With the cross-check, `dispatch_id mismatch → incomplete → halt`.
2. **Copy-pasted template.** Agent copy-pastes a sibling issue's
   payload (e.g. test fixture leaks into a real dispatch). Mismatch
   on `issue_id` halts.

This mirrors ENG-122 D-001's "JSON ALSO carries an `issue_id` field
at the top level for defense-in-depth: the validator (D-004)
cross-checks `json.issue_id == ident`" rationale.

**Reference to constraint.** CLAUDE.md "Cross-dispatch staleness
contract (ENG-87)" — strict id-equality is the primary freshness
mechanism; file mtime is secondary. Encoding `dispatch_id` in the
payload is the same pattern as `<!-- meta: dispatch id=… -->`
markers in Linear comments.

**Rejected alternative — rely on file mtime alone.** Rejected
because mtime is fragile across `--action continue` resume,
filesystem clock skew, and the orchestrator's pre-clean races.
Strict ID-equality is the established harness contract.

### D-007. The validator is invoked by the orchestrator (run-stage.sh), NOT by the agent. `bin/dispatch.sh::allowed_tools_for "reviewing"` is NOT widened.

**Rationale.** The post-dispatch detective runs inside `run-stage.sh`,
which executes under orchestrator-process privileges (the same
privilege boundary as `_validate_dispatch_envelope` and
`_validate_plan_contract`). The agent's `claude -p --allowed-tools`
lane is a SEPARATE permission surface; granting
`Bash(bash bin/review-payload-schema.sh:*)` to the agent would let
the agent self-validate before exit but adds no integrity benefit
(an agent that emits bad payload AND lies about validating is
strictly worse than an agent that emits bad payload, since the
detective catches both). Speculative grant-widening violates the
conservative-allowlist precedent in CLAUDE.md "Per-target
dispatch.tools extras" + the no-scoped-rm-allowlist memory.

**Reference to constraint.** CLAUDE.md "Per-stage allowed tool
lists are centralized in `dispatch.sh::allowed_tools_for`. New
stages must add a case there" — the centralization principle
applies symmetrically to the inverse: don't widen an existing
case without a load-bearing reason.

**Rejected alternative — widen the lane to enable agent self-
validation.** Rejected as above. If a future ticket has a concrete
need (e.g., the agent wants to re-emit a corrected payload after
self-validation), widen the lane THEN, not now.

### D-008. Pre-clean the payload file on dispatch start (current-stage slot only), mirroring `stage-summary-<stage>.md` lifecycle.

**Rationale.** ENG-87's "clear-on-dispatch-start" primitive lives in
`bin/run-stage.sh::_clear_current_stage_slots` (named in CLAUDE.md
"Per-medium primitives"). Per-issue files for the CURRENT stage are
cleared at dispatch start so a stale file from a prior dispatch
cannot survive into a fresh agent's read window. Stage-summary
files for the current stage are already pre-cleaned this way.
`verdict-review.json` joins the same set: on `reviewing` dispatch
start, the orchestrator `rm -f "$(issue_dir
"$ident")/verdict-review.json"` before invoking the agent.

This bounds the failure mode in D-006 to "agent wrote nothing,
detective halts on missing-file"; without pre-clean, the failure
mode is "agent wrote nothing, detective passes a stale file with
wrong dispatch_id" — same outcome but via a slower / less specific
path.

**Reference to constraint.** CLAUDE.md "Per-medium primitives" —
clear-on-dispatch-start is the named primitive for per-issue files
in the cross-dispatch staleness contract. Adding a new per-issue
file MUST add it to that primitive.

**Rejected alternative — skip pre-clean; rely on D-006's id-check
to catch stale files.** Rejected because D-006 catches the failure
but produces a less actionable diagnostic (`incomplete:
dispatch_id mismatch`) vs the cleaner `missing-file`. Pre-clean is
cheap (one `rm -f`); skipping it would be premature optimisation.

## 3. Architecture (where code goes)

```
bin/review-payload-schema.sh         NEW. ~120 lines. Mirrors
                                     bin/plan-schema.sh shape (ENG-122).
                                     CLI: `validate <file> --ident <ENG-N>
                                     [--dispatch-id <id>]`. Exit codes
                                     0/36/37/38.

bin/review-payload-schema-test.sh    NEW. Sibling self-contained test.
                                     Mirrors bin/plan-schema-test.sh.
                                     Cases: well-formed pass, malformed
                                     JSON, missing required field,
                                     missing file, dispatch_id mismatch,
                                     issue_id mismatch, unknown field
                                     warns + passes.

bin/run-stage.sh                     EDIT (~30 lines added). New
                                     _validate_review_payload() helper
                                     and _post_review_payload_halt()
                                     mirroring the ENG-122
                                     _validate_plan_contract /
                                     _post_plan_contract_halt pair at
                                     lines 1036-1084. New case arm in
                                     the post-dispatch hook block at
                                     lines ~1823-1835 (immediately after
                                     the planning arm) stage-gated to
                                     reviewing. New rm -f call in
                                     _clear_current_stage_slots for the
                                     `reviewing` stage entry.

bin/run-stage-test.sh                EDIT. Sibling tests for the new
                                     helpers (mirrors the existing
                                     plan-contract test cases).

bin/dispatch.sh                      NO CHANGE. Per D-007, the validator
                                     runs in run-stage.sh under
                                     orchestrator privileges, NOT under
                                     the agent's --allowed-tools lane.
                                     Speculative grant-widening would
                                     violate the conservative-allowlist
                                     precedent.

bin/common.sh                        EDIT (~3 lines). Three new entries
                                     in failure_outcome_for_exit at
                                     lines 247-279: 36, 37, 38.

bin/pipeline-events.json             EDIT (~1 line). New halt_reasons
                                     entry: `review-payload-invalid`.
                                     Run bin/generate-vocabulary-doc.sh
                                     to regenerate docs/pipeline-vocabulary.md.

bin/render-prompt.sh                 EDIT (~5 lines). New
                                     verdict_review_path entry in
                                     PROMPT_RESOLVERS at lines 41-57;
                                     new _resolve_verdict_review_path
                                     function at lines ~228; new
                                     _RENDER_VERDICT_REVIEW_PATH binding
                                     in main() at line ~484.

bin/render-prompt-test.sh            EDIT. Sibling tests for the new
                                     resolver (mirrors the existing
                                     stage_summary_path tests).

AGENT_PROMPTS.md                     EDIT. Section 5 Review Agent: new
                                     Output bullet for the payload
                                     file write; new "Dimension scoring"
                                     subsection in the prompt body with
                                     the example schema and the three-
                                     state score rubric. Insert
                                     immediately before the Stage-summary
                                     file Output bullet at line ~1271.

docs/runbooks/recovery.md            EDIT. New section "Resume from
                                     review-payload-invalid halt"
                                     mirroring the plan-contract-invalid
                                     resume section.

docs/pipeline-vocabulary.md          REGENERATED by
                                     bin/generate-vocabulary-doc.sh
                                     when pipeline-events.json is
                                     edited.
```

**Lifecycle dataflow:**

```
[Orchestrator]                              [Agent (claude -p)]
  run-stage.sh main()
    _clear_current_stage_slots
      └─ rm -f $issue_dir/verdict-review.json  ◀── pre-clean (D-008)
    allocate_dispatch_id
      └─ export PIPELINE_DISPATCH_ID
    render-prompt.sh
      └─ {verdict_review_path} → $issue_dir/verdict-review.json
      └─ {dispatch_id}          → ENG-N-dNNNN
    dispatch.sh
      └─ claude -p ──────────────────────▶  (review ensemble runs)
                                            (anti-bias pass)
                                            (Decision path A/B/C selected)
                                            Write $issue_dir/verdict-review.json
                                            Write stage-summary-reviewing.md
                                            Append progress.md (path C only)
                                            bash bin/pipeline.sh event ...
                                              verdict pass/fail
      ◀───────────────────────────────────  exit
    _validate_dispatch_envelope (ENG-87)
    _validate_review_payload (NEW)             ◀── detective (D-004)
      └─ bash bin/review-payload-schema.sh validate \
           $issue_dir/verdict-review.json \
           --ident ENG-N --dispatch-id ENG-N-dNNNN
      └─ rc=0  → continue to post_completion_comment
      └─ rc=36/37/38 → classify_failure + halt
    push_branch_if_ahead
    post_completion_comment
    verdict-handler picks up the agent's verdict marker
```

## 4. Data flow

**Producer:** review agent, on every review dispatch, on all three
Decision paths.

**Storage:** `$(issue_dir "$ident")/verdict-review.json` — per-issue
state dir, outside the worktree, mode 0644 (no secrets in the
payload). Overwritten on every dispatch; pre-cleaned on dispatch
start.

**Reader (this ticket):** `bin/run-stage.sh::_validate_review_payload`
detective scan only. No business-logic reader in v1 — those land in
ENG-118 (threshold gating) and the retrospective agent (which
already reads `$issue_dir/*.json` and `events.jsonl` shapes; this
file slots in naturally).

**Lifecycle:**

```
dispatch start (orchestrator):
  rm -f $issue_dir/verdict-review.json     ← pre-clean (D-008)

dispatch (agent):
  Write $issue_dir/verdict-review.json     ← producer (D-005)

dispatch end (orchestrator):
  bash bin/review-payload-schema.sh validate ...   ← detective (D-004)
  if rc != 0 → classify_failure + exit ${rc}

next dispatch (loopback iteration):
  rm -f $issue_dir/verdict-review.json     ← pre-clean again
  Write …                                  ← new payload
```

## 5. Error handling

**Halt cases (this ticket's contract):**

| Failure mode                          | rc | Outcome token             | Halt reason             | Operator recovery |
|---------------------------------------|----|---------------------------|-------------------------|-------------------|
| File missing entirely                 | 38 | review-payload-missing    | review-payload-invalid  | Inspect transcript; either re-render the file by hand and `--action continue`, or fix the prompt regression and let the next dispatch produce it. |
| JSON parse error                      | 36 | review-payload-malformed  | review-payload-invalid  | Inspect file (operator-visible at `$issue_dir/verdict-review.json`); fix bytes or delete and `--action continue` to regenerate. |
| Required field missing / wrong type   | 37 | review-payload-incomplete | review-payload-invalid  | Diagnostic prints which field; operator can either edit the JSON in place or delete and resume. |
| `issue_id` mismatch with `--ident`    | 37 | review-payload-incomplete | review-payload-invalid  | Indicates stale/copy-pasted template; delete file + `--action continue`. |
| `dispatch_id` mismatch with current   | 37 | review-payload-incomplete | review-payload-invalid  | Indicates the agent's write didn't happen this dispatch; delete + resume. |
| Unknown field (e.g. future schema)    | 0  | (warning only)            | (none — passes)         | None — D-002 permissive on unknowns. |
| Validator itself crashes (jq absent)  | 36 | review-payload-malformed  | review-payload-invalid  | This is an infra failure, not an agent failure. Operator inspects the per-stage transcript. |

**Soft-fail cases (NOT this ticket):**

* If the threshold-logic ticket (ENG-118) ever reads the payload and
  finds a missing optional dimension, it fails open — that's ENG-118's
  contract, not this one.
* If the retrospective agent reads the payload and finds a malformed
  one (shouldn't happen post-detective), it skips the data point.

**Logging:** Validator stdout is operator-readable (see ENG-122
`bin/plan-schema.sh:44-57` for the `plan-contract-malformed: …`
prefix convention; mirror as `review-payload-malformed: …` etc.).
Per-stage transcript captures both the validator stdout and the
halt-comment posting.

**No retry path (intentional).** The agent already runs the
ensemble; payload emission is a deterministic transformation of
in-memory findings. If it failed, the agent has a bug that retry
won't fix. Halt + operator triage is the correct response. Mirrors
the ENG-122 plan-contract-invalid policy.

## 6. Edge cases

1. **Agent emits a payload but exits with `verdict halt --reason
   agent-blocked`.** Detective still runs (stage-gated, not
   verdict-gated). The payload's `verdict` field carries `halt` per
   D-002's enum extension. Two outcomes possible: (a) payload is
   well-formed with `verdict: "halt"` → detective passes, the
   agent-blocked halt comment posted by the agent surfaces the real
   reason in Linear; (b) payload is malformed/missing → detective
   halts a SECOND time with `review-payload-invalid`. The second
   case is observationally indistinguishable from "agent crashed
   mid-stream after writing stage-summary but before payload"; both
   halt comments land in Linear and operator triage reads the
   transcript. **Decision:** detective runs unconditionally on
   `reviewing`; double-halt is acceptable signal cost.

2. **`--action continue` resume after a `review-payload-invalid`
   halt.** `bin/pipeline.sh decide --action continue` clears
   `pipeline:halted` and re-allocates `dispatch_id`. Next tick: poll
   selects the issue (still `stage:reviewing`); run-stage
   pre-cleans `verdict-review.json` (D-008); agent re-runs the
   review; if the payload is now valid, dispatch completes. If
   operator instead inspected and manually edited the file to make
   it valid, `--action continue` will *erase* it on next dispatch
   (pre-clean). Manual recovery shape: operator should re-emit the
   verdict-pass marker via `bash bin/pipeline.sh event ENG-N verdict
   pass --stage reviewing` themselves AFTER editing the file, NOT
   use `--action continue` for that path. **Documented in the
   runbook update (Section 3 architecture).**

3. **`PIPELINE_DISPATCH_ID` is unset when the validator runs.** The
   `${VAR-}` fallback (CLAUDE.md "Secret-handling (ENG-46)" — single-
   dash for presence checks) returns empty. Validator either: (a) if
   `--dispatch-id` flag is empty, skips the cross-check (fail-open);
   (b) if `--dispatch-id` is non-empty but doesn't match payload's
   `dispatch_id`, rc=37. **Choice:** option (a) — fail-open on
   missing flag, strict-equality on present flag, mirrors ENG-87's
   D-005 "Soft-fallback for legacy issues with no markers."

4. **Concurrent dispatches on the same issue (K=2 per project from
   ENG-81).** The semaphore caps *cross-issue* concurrency but
   per-issue locking is enforced by `try_acquire_lock` on
   `$(issue_dir)/.in-flight.lock` (`bin/common.sh::acquire_lock`).
   Two dispatches on the same issue MUST not run concurrently;
   pre-clean + write + validate are atomic relative to other
   dispatches on the same issue.

5. **Agent uses heredoc with shell expansion in payload body.**
   CLAUDE.md "Build wait `tick_at` line needs literal-baked timestamp"
   memory — quoted heredoc (`<<'EOF'`) prevents `$VAR` expansion.
   Prompt guidance: emit the payload via `Write` tool (which writes
   literal content, no shell expansion), NOT via `bash -c "cat > $VAR
   <<EOF …"`. Write is the only tool the agent needs.

6. **Agent writes a path under the worktree instead of $issue_dir.**
   Detective at `$(issue_dir "$ident")/verdict-review.json` will see
   missing-file and halt with rc=38. The wrong-path file inside the
   worktree gets caught by `partition_dirty_paths` as self-leak
   (it's NOT in `stage_output_paths` for reviewing — empty per
   `learned-rules/harness/project-profile.md::File layout` for
   reviewing) and triggers a *separate* halt. Order of halts depends
   on which check fires first; both are valid operator signals.
   Operator recovery: same shape — fix the prompt, resume.

7. **Massive payload (e.g., agent emits 10 MB of "rationale").** The
   validator runs `jq -r 'type' "$file"` first which streams; no OOM
   risk. The Linear halt-comment body excerpts the validator's stdout
   (which itself is bounded). **No size limit enforced** in v1
   (CLAUDE.md "Don't add error handling … for scenarios that can't
   happen"); if pathological size becomes a real failure mode, add
   a check then.

8. **Dry-run (`PIPELINE_DRY_RUN=1`).** The agent isn't invoked, so
   the payload isn't written. The validator has **no internal
   fail-open branch**; the caller's `(( ! skip_dispatch ))` case-arm
   gate in `bin/run-stage.sh` prevents the validator from ever
   running in dry-run / scope-approval-replay paths. Mirrors the
   ENG-122 plan-contract gating exactly — see `bin/run-stage.sh:1823`.

9. **Stage-summary file write fails after payload write succeeds.**
   Both are agent-side writes. If stage-summary write fails, the
   agent's existing `agent-contract-missing` (rc=25) check at
   `bin/run-stage.sh:~1539` catches it. The orphan payload file
   survives until next dispatch's pre-clean, which is harmless.

10. **Operator-pinned `_RENDER_VERDICT_REVIEW_PATH`.** Not exposed
    to operators. The path is derived from `issue_dir` + a literal
    basename; no config knob.

## 7. Open questions

* **OQ-1.** Do we add `validator passes empty payload` as a
  diagnostic mode (e.g. `verdict-review.json` with `dimensions: {}`)
  to support a future "smoke-only review" scenario? **Working
  decision:** no — the four required dimensions are mandatory in
  v1; loosening is ENG-118's scope when threshold-gating is wired.

* **OQ-2.** ~~Does `bin/dispatch.sh::allowed_tools_for "reviewing"`
  need a new grant?~~ **Resolved as D-007 above** (closed
  decision, not open). The agent allowlist is NOT widened.

* **OQ-3.** The proposed schema does not include a top-level
  `created_at` timestamp. ENG-87's `dispatch_history.jsonl` already
  carries dispatch start/end timestamps. Does the payload need a
  redundant timestamp? **Working decision:** no — file mtime is
  sufficient secondary signal, primary is `dispatch_id`.

* **OQ-4.** Should the validator enforce that `verdict ==
  "approve"` implies all required dimensions `score == "pass"`?
  This is a *semantic* check that overlaps with ENG-118. **Working
  decision:** no — schema is structural, ENG-118 is semantic.
  Defer.

* **OQ-5.** What about a payload entry for the conditional
  `premise` dimension? When Decision-path A fires (premise failure),
  `verdict: "premise-failure"` AND the `premise` dimension key
  appears in `dimensions{}` with `score: "fail"`. When path A does
  NOT fire, `premise` is absent. **Working decision:** treat
  `premise` as optional but conventionally-emitted-on-path-A. The
  prompt instructs the agent on this; the validator does not
  enforce.

* **OQ-6.** Cross-coordination with ENG-117 (qa payload).
  Parallel-safe per Linear scope. If both ship and the validators
  end up nearly identical, a follow-up cleanup ticket can extract
  a shared helper. This ticket does NOT pre-design that shape.

* **OQ-7.** Defense-in-depth for triple-backtick fence-escape in
  the halt-comment body. D-004's sanitisation handles `<!--`
  prefixes (the load-bearing marker-hijack vector) and wraps the
  agent-controlled `out` in a triple-backtick fence so the
  marker parser's `_strip_code_blocks_and_spans` neutralises any
  remaining `<!-- … -->` substrings inside. The residual edge is
  a payload that itself contains ` ``` ` (triple-backtick) runs
  that could break out of the fence. The marker parser collapses
  fenced runs greedily (per ENG-87 review iter-7 C3 + ENG-122
  Minor 1), so a balanced inner-fence interpolation is benign;
  an unbalanced one falls back to defense-in-depth on `<\!--`
  prefix escape. **Working decision:** flag as residual edge for
  implementation; if a real exploit shape surfaces, mirror the
  ENG-122 review's resolution (additional `code_block_strip` over
  the validator output before fence-wrap).

## 8. Out-of-scope reminders

* **Threshold logic gating verdicts (ENG-118).** This ticket emits;
  does NOT gate. The agent's verdict (the bash `bin/pipeline.sh
  event` marker) is still the source of truth for orchestrator
  state machine in v1. ENG-118 will add the gate.

* **QA payload (ENG-117).** Parallel sub-ticket. No shared code
  delivered in this ticket.

* **Retrospective agent reading the payload.** The retrospective
  reads `$issue_dir/*.json` (and `events.jsonl`) generically today;
  this ticket adds a new file that will be picked up by the existing
  retrospective surface naturally. No retrospective changes in
  scope for this ticket.

* **Schema versioning beyond v1.** D-002's permissive-on-unknown
  contract lets schema v2 ship later without breaking v1 readers.
  v2 design is not pre-empted here.

## 9. ADR stress test

This ticket puts pressure on the following accepted decisions:

* **ENG-122 plan-contract validator pattern.** This brainstorm
  *deliberately* mirrors ENG-122's shape (dedicated validator
  script, three exit codes, single halt reason, post-dispatch state
  check). The mirror is intentional — it minimises learning cost
  for future maintainers, but it does propagate any latent flaws
  in ENG-122's pattern (e.g. if the dedicated-validator-per-stage
  pattern proves to be the wrong shape at three callers, all three
  share that flaw). **Cost flagged**, not load-bearing enough to
  refactor today.

* **ENG-87 cross-dispatch staleness contract.** D-006's cross-check
  of `dispatch_id` extends the staleness contract to a new file
  shape. The contract's "Per-medium primitives" table will need
  one new row (`Per-issue files | clear-on-dispatch-start | bin/
  run-stage.sh::_clear_current_stage_slots — extended for
  verdict-review.json`). This is additive, not a stress.

* **CLAUDE.md "Defense-in-depth: when a stage's contract says
  'agent must not invoke tool X,' prefer a transcript-based
  assertion … over a post-dispatch state check."** D-004's
  detective is a state check, which on a literal read of this
  guidance might seem to conflict. The clause is specifically
  about *tool denials* (transcript scan catches an agent invoking
  a forbidden command); state requirements (a specific file must
  exist with a specific shape) are not in its scope. The ENG-122
  precedent already established this delineation; ENG-119 follows
  it.

## 10. Simpler-alternative pass

Already documented inline at each Decision (D-001–D-008).
Consolidated summary:

| Decision | Rejected alternative | Why rejected |
|----------|----------------------|--------------|
| D-001 | Inside-worktree file | conflates ephemeral state with committed artifacts; scope-sweep plumbing burden |
| D-001 | Rolling JSONL | history not needed by v1 readers; complexity for nothing |
| D-002 | JSON Schema (jsonschema.org spec) | new dep; jq is sufficient for 8 fields |
| D-002 | Array-of-dimensions instead of object | awkward jq projection; no dup-key prevention |
| D-002 | Flat schema (no `dimensions` nesting) | forces schema-bump per new dimension |
| D-002 | Numeric Likert score | false precision; doesn't map onto existing severity ladder |
| D-003 | Fold into common.sh | widens common.sh; loses CLI testability |
| D-003 | Shared `dimension-payload-schema.sh` w/ ENG-117 | premature generalisation across parallel tickets |
| D-004 | Transcript scan instead of filesystem check | catches only absence-of-Write, not malformed content |
| D-004 | Inside dispatch.sh post-stream | conflates the thin claude-wrapper with Linear-API failure paths |
| D-005 | Payload via Linear comment | append-only; can't overwrite per dispatch |
| D-006 | Rely on mtime alone | fragile across resume / clock skew |
| D-007 | Widen agent allowlist for self-validation | speculative; conservative-allowlist precedent |
| D-008 | Skip pre-clean; rely on D-006 id-check | premature optimisation; pre-clean is free |

## 11. Assumption inventory

| # | Assumption | Status | Evidence |
|---|------------|--------|----------|
| 1 | `bin/common.sh::issue_dir "$ident"` returns `$PROJECT_STATE_DIR/$ident` | **verified** | `bin/common.sh:68-72` (function body); CLAUDE.md "Per-issue state directory" |
| 2 | `bin/common.sh::failure_outcome_for_exit` is the canonical exit-code → outcome map; codes 30/31/33/34/35 exist; 32/36+ are free | **verified** | `bin/common.sh:247-279` (case arms listed) |
| 3 | `bin/pipeline-events.json::halt_reasons` is the registry; 10 existing reasons, none named `review-payload-invalid` | **verified** | `jq .halt_reasons` returns the listed array; no clash |
| 4 | `bin/run-stage.sh::_validate_dispatch_envelope` is at `bin/run-stage.sh:966-1030`; the post-dispatch hook block invokes it at lines 1797-1817 | **verified** | grep'd `_validate_dispatch_envelope`; file inspected lines 960-1030 + 1790-1820 |
| 5 | `bin/run-stage.sh::_validate_plan_contract` is at `bin/run-stage.sh:1036-1072`; sibling `_post_plan_contract_halt` at 1077-1084; invocation arm at 1823-1835 | **verified** | grep'd `_validate_plan_contract`; file inspected lines 1036-1084 + 1819-1835 |
| 6 | `bin/dispatch.sh::allowed_tools_for "reviewing"` exists and lists `Bash(gh pr review:*)` etc. | **verified** | `bin/dispatch.sh:456` (reviewing arm content) |
| 7 | `bin/render-prompt.sh::PROMPT_RESOLVERS` exists and registers `stage_summary_path`, `progress_md_path`, `dispatch_id` resolvers; `main()` binds `_RENDER_STAGE_SUMMARY_PATH` | **verified** | `bin/render-prompt.sh:41-57`, 228-237, 459+484 |
| 8 | `bin/linear.sh::_inject_dispatch_marker` is the chokepoint at `bin/linear.sh:55-71` and auto-injects `<!-- meta: dispatch id=… stage=… -->` when `PIPELINE_DISPATCH_ID` is set | **verified** | `bin/linear.sh:55-71` |
| 9 | `bin/common.sh::assert_no_tool_invocation` and `assert_no_write_to_path` exist at `bin/common.sh:188-204` and `bin/common.sh:213-230` respectively | **verified** | grep'd; file lines 185-230 |
| 10 | Review-stage exit sequence is documented in `AGENT_PROMPTS.md` §5 Output bullets at lines 1265-1294; `{stage_summary_path}` token is used at line 1271 | **verified** | `AGENT_PROMPTS.md:1064-1320` read in full |
| 11 | `bin/plan-schema.sh` exists as the ENG-122 validator template at `bin/plan-schema.sh` (full file ~100-200 lines) | **verified** | file read; lines 1-100 inspected; pattern is reusable |
| 12 | `bin/run-stage.sh::_clear_current_stage_slots` is the named primitive for clear-on-dispatch-start (CLAUDE.md "Per-medium primitives") and currently clears `stage-summary-<stage>.md` + `wait-<stage>.json` for the current stage | **verified** (feasibility persona iter 2) | `bin/run-stage.sh:931-939` shows the helper removing exactly those two files for the current stage. |
| 13 | The retrospective agent reads `$issue_dir/*.json` shapes generically (no per-file plumbing for usage/wait files) | **assumed** — referenced in CLAUDE.md but the retrospective's read surface was not opened in this dispatch. Implementation phase can defer this; the file lands at the canonical location either way. |
| 14 | `bin/generate-vocabulary-doc.sh` regenerates `docs/pipeline-vocabulary.md` from `bin/pipeline-events.json` | **verified** | named in CLAUDE.md "Pipeline vocabulary"; file present in `bin/` listing |
| 15 | The per-issue concurrency lock at `$(issue_dir)/.in-flight.lock` enforces single-active-dispatch on an issue | **verified** | CLAUDE.md failure-mode table row "Issue stuck at one stage; `$(issue_dir <issue>)/.in-flight.lock` present" + ENG-81 description |
| 16 | `partition_dirty_paths` classifies paths against `stage_output_paths` per-stage; `reviewing` returns empty in `stage_output_paths` (read-mostly) | **verified** (feasibility persona iter 2) | `bin/run-local-helpers.sh:508-509` shows `reviewing|building|released)` falls through with no allowlist entries — pure read-mostly. Edge case 6 self-leak claim holds. |
| 17 | `bin/run-stage-test.sh` and `bin/render-prompt-test.sh` exist as siblings | **verified** | both listed in `bin/` directory listing |

## 12. Out-of-scope flags

The brainstorm stays inside the Linear scope as written. One soft
near-miss: D-008 (pre-clean) is implementation plumbing the Linear
scope did not list explicitly, but pre-cleaning is required by the
ENG-87 cross-dispatch staleness contract for any new per-issue file
that gets overwritten per dispatch. **Not flagging as scope creep**
— it's a structural consequence of D-001 + the existing contract.

The remaining inside-scope items the Linear issue lists are all
covered:

* "Schema for `$issue_dir/verdict-review.json`" → D-001 + D-002.
* "AGENT_PROMPTS.md review section instructs agent to emit the
  payload" → D-005.
* "`bin/dispatch.sh` detective scan asserts the payload exists and
  is well-formed" → D-004 (placement is in `bin/run-stage.sh`, not
  `bin/dispatch.sh`, because that's where peer detectives live —
  ENG-122 / ENG-87 — and that's the higher-trust orchestrator
  context; called out as a Linear-scope-prose-vs-code-precedent
  delta in the implementation plan, NOT a scope deviation: the
  semantic ask is "post-dispatch detective halts on bad payload"
  and the established harness placement is in run-stage.sh).
* "Tests cover payload parsing + missing-payload halt" → covered
  by new `bin/review-payload-schema-test.sh` + edits to
  `bin/run-stage-test.sh` and `bin/render-prompt-test.sh`.

## 13. Persona review

The brainstorm was reviewed against six personas in the canonical
order (design → security → scope → coherence → product →
feasibility). Real cold-pass results from this dispatch follow;
iteration history is in §14.

### 13.1 Design — PASS

* P0: 0.
* P1: 3 findings (OQ-2 self-contradiction with §3 Architecture;
  cross-reference rot for "permissive on unknown"; Edge case 8
  dry-run wording inconsistent with D-004 helper signature).
* P2: 3 findings (schema docs only in header-comment YAGNI flag;
  exit-code 32 skip not justified inline; Decision-path A premise-
  failure dimension-fabrication question; verdict enum missing
  `halt` for Edge case 1).
* All P1s addressed in this dispatch's edits:
  * §3 Architecture's `bin/dispatch.sh` row is now "NO CHANGE"
    cross-linked to the new D-007 (the open question is closed).
  * The "(D-005)" cross-ref at line ~165 now points at the
    correct clause inside D-002.
  * Edge case 8 wording rewritten — the validator has no internal
    fail-open; the caller's `(( ! skip_dispatch ))` gate handles
    dry-run.
* All P2s addressed where load-bearing:
  * `verdict` enum extended to include `halt` (Edge case 1).
  * D-005 clarified that the ensemble runs BEFORE Decision-path
    selection, so required-dimension scores ARE inspected even
    on premise-failure (no fabrication).
  * Exit-code 32 skip is a flat-namespace allocation; one-line
    note added in §11 / §13.6.
  * Schema doc location stays YAGNI per CLAUDE.md "Don't add
    features beyond what the task requires"; flagged in §7 OQ.

### 13.2 Security — PASS

* P0: 0.
* P1: 0.
* P2: 3 findings (triple-backtick fence-escape inside halt body —
  defense-in-depth question; validator stdout length cap for the
  Linear comment body — YAGNI-accepted; OQ-2 should be locked in
  as a decision — closed in this dispatch).
* All clean. Marker-hijack sanitisation (D-004) is correct;
  no secret-handling regex matches; no new agent tool grants
  (D-007 closes the question); cross-dispatch isolation upheld
  via D-006 + D-008.
* P2 fence-escape: documented as a defense-in-depth open in
  OQ-7 below — implementation should consider escaping or
  stripping triple-backtick runs in the agent-controlled
  payload before fenced-block interpolation. The marker parser's
  `_strip_code_blocks_and_spans` is the primary defense; this
  P2 just notes that nested-fence breakout is the residual edge.

### 13.3 Scope — PASS

* P0: 0.
* P1: 0.
* P2: 4 findings (§3 vs OQ-2 inconsistency — fixed; Linear scope
  prose says `bin/dispatch.sh` but brainstorm uses `bin/run-stage.sh`
  — §12 already discloses; AC-1 wording absolute vs dry-run carveout
  — minor; Assumptions #12/#13/#16 remain assumed — accepted).
* Subsystem count: spans dispatch + agent-prompts + orchestrator +
  tests/fixtures = 3-4 by strict rubric count, but all edits except
  the dispatch line (NO CHANGE per D-007) are mechanically
  subordinate to ONE design decision (schema shape + detective
  placement) and mirror ENG-122 verbatim. Within autonomy-safe.
* All IN bullets delivered; all OUT bullets cleanly deferred
  (ENG-117 in §8 + OQ-6, ENG-118 in §8 + OQ-1/OQ-4); AC-1/2/3 all
  map to concrete decisions.

### 13.4 Coherence — PASS

* P0: 0.
* P1: 1 finding (OQ-2 self-contradiction — same one all 4 prior
  personas raised; fixed via D-007 + dispatch.sh row → "NO CHANGE").
* P2: 4 findings (Edge case 8 dry-run wording — fixed; §13.4 was
  self-attestation — replaced this entire section with real
  cold-pass results; lifecycle diagram suggests sequential chain —
  clarified below as stage-gated case-arms; halt-comment body uses
  literal `$issue_dir` placeholder — fixed to absolute-path note).
* The mirror-of-ENG-122 shape is held: validator script, exit
  codes 36/37/38 in the next contiguous block, halt reason
  `review-payload-invalid` shaped exactly like
  `plan-contract-invalid`, prompt resolver naming
  (`verdict_review_path`) symmetric with `stage_summary_path` and
  `progress_md_path`. Single canonical pattern.
* **Diagram clarification:** §3 Architecture's data-flow diagram
  shows `_validate_dispatch_envelope` → `_validate_plan_contract`
  → `_validate_review_payload` as if linear, but each is a
  stage-gated case-arm; plan-contract runs only on `planning`,
  review-payload only on `reviewing`, and they never co-fire.
  The diagram's ordering is just "post-dispatch hook block
  position in source code," not a runtime sequence.

### 13.5 Product — PASS

* P0: 0.
* P1: 2 findings (ENG-118 consumer fit for `thresholds_*[]`
  arrays — addressed by adding "Reader contract for the threshold
  arrays" clause in D-002 explicitly stating thresholds are
  narrative-only and ENG-118 reads `score`; retrospective surface
  assumption — flagged for implementation verification, see §11
  Assumption #13).
* P2: 4 findings (operator UX on Edge case 2 `--action continue`
  erases manual edits — runbook needs prominence, noted in §3;
  `scope` dimension granularity may degenerate to constant `pass`
  — empirical check post-ship, OK; 3-state collapses minor/nit —
  acceptable v1 ceiling; value-vs-effort ratio defensible).
* All operator-facing artefacts named: halt reason, three outcome
  tokens, runbook resume section (`docs/runbooks/recovery.md`),
  validator one-liner for manual repro.

### 13.6 Feasibility — PASS (iter 2)

* P0: 0.
* P1: 0.
* P2: 6 findings — all citation-precision drift or unverified-but-
  not-load-bearing items, not blocking. Notable:
  * Assumption #12 (`_clear_current_stage_slots` clears
    `stage-summary-*.md` + `wait-*.json`) now **verified** via
    `bin/run-stage.sh:931-939`. §11 row updated.
  * Assumption #16 (`reviewing` is read-mostly with empty
    `stage_output_paths`) now **verified** via
    `bin/run-local-helpers.sh:508-509`. §11 row updated.
  * Assumption #13 (retrospective reads `$issue_dir/*.json`
    generically) remains "assumed" — not blocking, not on this
    ticket's critical path; implementation can verify when the
    retrospective surface is touched.
  * Trivial off-by-one citation `bin/common.sh:188-204` should be
    `188-205` for `assert_no_tool_invocation`. Drive-by fix
    during implementation; no behaviour change.
  * Pre-existing ENG-122 comment-rot at `bin/run-stage.sh:1821`
    ("Exit codes 30/31/32 map to" vs actual 33/34/35) — flagged
    for drive-by fix; not caused by ENG-119.
  * `AGENT_RUNTIME_TOKENS` does NOT need a new entry —
    `verdict_review_path` resolves at orchestrator render-time
    (sibling of `stage_summary_path` and `progress_md_path`). The
    brainstorm correctly omits it; a one-line note in D-005 will
    make this explicit for future maintainers.

**Gate status: 6/6 personas PASS, feasibility P0 count = 0.**
Brainstorm cleared for commit and stage progression.

## 14. Persona-review iteration history

* **Iteration 1.**
  * Design / Security / Scope / Coherence / Product — all PASS,
    0 P0. 4 of the 5 personas independently flagged the same P1
    (OQ-2 contradicting §3 Architecture's `bin/dispatch.sh` edit).
    Product flagged the additional ENG-118-consumer P1 on
    `thresholds_*[]` arrays. Together: 5 P1 findings across the
    pass, plus a handful of P2s.
  * Brainstorm-doc edits applied in this dispatch to address all
    P1s and load-bearing P2s; see §13.1-§13.5 lists for the
    one-to-one fix mapping. Notable structural edits:
    - Added D-007 (tool-grant decision) and renumbered the prior
      D-007 (pre-clean) to D-008.
    - Extended D-002 `verdict` enum with `halt`.
    - Added "Reader contract for the threshold arrays" clause in
      D-002.
    - Cleaned up cross-refs (line ~165 "(D-005)" → correct clause).
    - Rewrote Edge case 8 (dry-run) wording.
    - Rewrote Edge case 1 (halt-path) wording.
    - Fixed halt-comment body literal `$issue_dir` → absolute-path
      note.
    - Replaced the pre-baked §13 placeholder text with real
      cold-pass findings from this iteration.
  * Feasibility persona not yet run. Iter 2 dispatches it as the
    gating persona on the updated doc.

* **Iteration 2.** Feasibility cold-pass — **PASS, 0 P0, 0 P1, 6 P2**.
  All P2s are citation-precision drift (off-by-one line refs, one
  pre-existing ENG-122 comment-rot) or unverified-but-not-load-bearing
  items. Assumptions #12 and #16 graduated from "assumed" to
  "verified" with concrete `file:line` evidence. Assumption #13
  remains "assumed" but is not on this ticket's critical path.
  **Gate met: 6/6 PASS, feasibility P0 = 0. Brainstorm cleared.**

## 15. Proposed ADRs

This ticket does not propose new ADRs. The decisions all fit
within established architectural patterns (ENG-87 staleness
contract, ENG-122 dedicated-validator-per-stage pattern, ENG-46
secret handling). If `docs/knowledge/decisions.md` is later
created, the ENG-122 ADR (proposed in that ticket's brainstorm)
will serve as the parent that this ticket's mirror implementation
follows.
