---
linear: ENG-205
title: Apply orchestrator-merge to verdict-review.json (review_schema_version, issue_id, dispatch_id)
date: 2026-06-17
status: draft
---

# Apply orchestrator-merge to verdict-review.json

## 1. Problem

ENG-203 shipped a content-only / envelope-merge contract for the qa stage's
two artifacts (`verdict-qa.json`, `qa-predicate-<ident>.json`) and proved
it through `merge_artifact_envelope` (`bin/common.sh:713`). The structural
gap it closed: **the agent reliably slips on invariant envelope keys** —
boilerplate that names a schema version, the issue id, the dispatch id —
because those keys carry no decision content the agent reasons about; they
are exactly the surface where ENG-118 halted and a steady stream of qa
re-dispatches halted before that.

The review stage's `verdict-review.json` (ENG-119) is the next instance of
the same class. Today's §5 review prompt (`AGENT_PROMPTS.md:1804-1822`)
hands the agent five required top-level keys: three envelope
(`review_schema_version: 1`, `issue_id`, `dispatch_id`) and two content
(`sha`, `verdict`), plus the dimensions object. The validator at
`bin/review-payload-schema.sh:108-163` rejects any missing or
ill-typed envelope key with rc=37 (review-payload-incomplete). The agent
has not yet observably slipped on the review envelope in the operator's
memory log, but:

* the slip surface is structurally identical to qa's,
* the agent class that emits these payloads (review) has already
  contributed to halt-class incidents on adjacent artifacts (ENG-190
  review-ledger row diagnostics; ENG-71 stage-summary staleness),
* ENG-202 names review as one of three sibling cuts that consume
  the foundation helper unchanged, with ENG-205 being the explicit
  next-after-qa child.

ENG-205 ships the smallest cut against the next-most-likely slip surface,
using the helper ENG-203 already exposed. The cost is small (~3 functions,
~3 prompt edits, 4 tests) and the structural gap it closes is permanent.

## 2. Decisions

### D-001. Mechanism: sidecar-merge mirrors ENG-203 D-001 verbatim. Agent writes content-only `verdict-review.body.json`; orchestrator merges envelope `{review_schema_version: 1, issue_id, dispatch_id}` onto a fresh canonical `verdict-review.json` via `common.sh::merge_artifact_envelope`; validator runs on the merged canonical.

**Rationale.** ENG-203 D-001 enumerated four mechanism candidates
(sidecar-merge / pre-seed / validator-synthesises / strengthen-prompt)
and chose sidecar-merge after rejecting the other three with reasons
that are structurally identical for review. The alternatives reconsidered
here:

* **A. Sidecar-merge (chosen, same as ENG-203).** Agent writes
  `verdict-review.body.json` containing only `sha`, `verdict`, and
  `dimensions{}`. Orchestrator post-dispatch invokes
  `_merge_review_payload_envelope` which constructs envelope JSON from
  `$ident` + `$PIPELINE_DISPATCH_ID`, calls `merge_artifact_envelope`
  (`bin/common.sh:713-742`), writes canonical `verdict-review.json`
  atomically. The existing `_validate_review_payload` at
  `bin/run-stage.sh:1400-1419` runs on the canonical, unchanged. Schema
  validator at `bin/review-payload-schema.sh:108-163` is unchanged.
* **B. Pre-seed.** Same rejection as ENG-203 D-001 B — `Edit` anchors on
  an orchestrator-seeded sentinel are fragile and silent on miss. Review
  has the additional drawback that the dimensions block is a deeply
  nested object whose Edit-anchor shape would have to commit a specific
  key ordering, breaking the agent's natural write order.
* **C. Validator accepts body-only.** Same rejection — blurs the
  validator's contract; doesn't generalise across siblings.
* **D. Strengthen the prompt.** Same rejection. The agent has not yet
  observably slipped on review-envelope, but waiting for the first live
  incident before applying a foundation-proven fix is anti-economical
  — the slip class is structural, not contingent.

**Reuse of the shared helper.** No new helper code in `common.sh`. The
existing `merge_artifact_envelope` was authored taxonomy-agnostic
(`bin/common.sh:698-712` header comment: "callers own envelope-keyset
discipline … rc=39/41/42/50 are values returned to the qa caller, not
intrinsically 'qa codes.'"). The review caller constructs envelope
JSON from already-trusted inputs and remaps the helper's rc to the
review-payload taxonomy entries 36/37/38 already in
`failure_outcome_for_exit` (`bin/common.sh:789-791`).

**Reference to constraint.** CLAUDE.md "When wiring a new script": "For
exit codes, use the `failure_outcome_for_exit` taxonomy (common.sh) —
unmapped codes route to `unknown-exit-N`." The review-payload codes
36/37/38 already exist; no taxonomy edit needed.

**Reference to constraint.** CLAUDE.md "Cross-dispatch staleness contract
(ENG-87)": "Per-medium primitives: clear-on-dispatch-start for per-issue
files." The canonical `verdict-review.json` is already cleared on the
reviewing stage at `bin/run-stage.sh:962-964`; the body sidecar joins it
in D-005.

### D-002. Helper `verdict_review_body_path <ident>` lives in `bin/common.sh` alongside `qa_payload_body_path` (line 99) and `qa_predicate_body_path` (line 104). Resolver `verdict_review_body_path=_resolve_verdict_review_body_path` registers in `bin/render-prompt.sh::PROMPT_RESOLVERS` (line 40-66). `_merge_review_payload_envelope` lives in `bin/run-stage.sh` next to `_merge_qa_payload_envelope` (line 2089).

**Rationale.** Three placement decisions mirror ENG-203 D-002 verbatim:

* `bin/common.sh` for the body-path helper — same family as the existing
  `qa_payload_body_path` / `qa_predicate_body_path` (lines 99-108). Both
  are pure-string composers over `issue_dir`. The helper body:

  ```bash
  verdict_review_body_path() {
    local issue="$1"
    [[ -n "$issue" ]] || die "verdict_review_body_path: missing issue id"
    printf '%s/verdict-review.body.json' "$(issue_dir "$issue")"
  }
  ```

  Exported via the existing `export -f` list. No new file; no new
  taxonomy code; sub-page-of-disk change.

* `bin/render-prompt.sh` registry — token `verdict_review_body_path`
  joins `qa_payload_body_path` and `qa_predicate_body_path` in the
  registry block at lines 61-62 and the resolver functions at
  lines 289-290. The new resolver mirrors the qa siblings:

  ```bash
  _resolve_verdict_review_body_path() { printf '%s' "$_RENDER_VERDICT_REVIEW_BODY_PATH"; }
  ```

  `main()` binds `_RENDER_VERDICT_REVIEW_BODY_PATH` next to
  `_RENDER_VERDICT_REVIEW_PATH` (existing, line 285) and
  `_RENDER_QA_PAYLOAD_BODY_PATH` (existing, line 687):

  ```bash
  _RENDER_VERDICT_REVIEW_BODY_PATH="$(verdict_review_body_path "$issue_id")"
  ```

* `bin/run-stage.sh` for `_merge_review_payload_envelope` — sibling of
  `_merge_qa_payload_envelope` (line 2089-2111). The merge helper itself
  is library-agnostic; the wiring (envelope construction + caller-side
  rc remap + halt-post) is review-specific and belongs next to the
  review validator.

**Rejected — name the helper `review_payload_body_path` for symmetry with
`qa_payload_body_path`.** The on-disk canonical is `verdict-review.json`
(not `review-payload.json`), so the body sibling is `verdict-review.body.json`.
Naming the helper `verdict_review_body_path` keeps the file-basename
correspondence the existing siblings preserve (`qa_payload_body_path` →
`verdict-qa.body.json` is the only inverted case, and ENG-203 chose that
name only because the qa canonical IS `verdict-qa.json` — same naming
asymmetry survives here). The resolver token mirrors the helper name for
grep symmetry.

**Reference to constraint.** Language idioms (Project profile addendum):
"Use `log` / `die` / `require_env` / `require_bin` from common.sh; don't
roll your own." `common.sh` is the canonical place for cross-script
helpers.

### D-003. AGENT_PROMPTS.md §5 (review) — strip envelope keys from the documented required-fields list at lines 1808-1809 and change the Write target from `{verdict_review_path}` to `{verdict_review_body_path}` at lines 1563, 1749, 1804.

**Rationale.** Three specific edits to AGENT_PROMPTS.md §5 review block:

1. **Line 1563 (token reference in the in-mind narrative).** Change
   "You will Write this as JSON to `{verdict_review_path}` at the end of
   the Output sequence" → "You will Write the content-only body as JSON
   to `{verdict_review_body_path}` at the end of the Output sequence."

2. **Line 1749 (Decision-path C clean-pass step list).** Change
   "Write the dimension-scoring payload at `{verdict_review_path}`" →
   "Write the dimension-scoring body at `{verdict_review_body_path}`."

3. **Lines 1804-1822 (Output bullet — the canonical instruction).**
   Today's text:

   > **Write the dimension-scoring payload** at `{verdict_review_path}`
   > as the LAST step BEFORE the verdict marker. … **Required top-level
   > fields:** `review_schema_version: 1`, `issue_id` (must equal
   > `{issue_id}`), `dispatch_id` (must equal `{dispatch_id}`), `sha`
   > (the PR HEAD SHA you reviewed against), `verdict` (`approve` …)

   New text:

   > **Write the dimension-scoring body** at `{verdict_review_body_path}`
   > as the LAST step BEFORE the verdict marker. … **Required top-level
   > fields:** `sha` (the PR HEAD SHA you reviewed against), `verdict`
   > (`approve` …). **The orchestrator merges the schema envelope
   > (`review_schema_version`, `issue_id`, `dispatch_id`) onto your body
   > before validation; do NOT emit those keys yourself.**

   The required-dimensions block at lines 1812-1817 (`correctness`,
   `testing`, `maintainability`, `scope`, plus optional `security` /
   `performance` / `api_contract` / `premise`) is unchanged — those are
   content, not envelope.

   The §5 prompt may still MENTION the envelope keys in the
   "the orchestrator merges {…} before validation" sentence — that's
   allowed. The prompt-content tests in D-008 narrow their assertion to
   the "required fields the agent must emit" doc area (via a section
   locator that mirrors ENG-203 D-009 AP-1 at `bin/agent-prompts-content-test.sh`'s
   §6-step-9 locator).

**Reference to constraint.** CLAUDE.md "Stage summary file —
overwrite-on-every-dispatch contract (ENG-77/ENG-71)": "any stage-summary
file going unwritten on a re-dispatch is a structural staleness hazard."
The body sidecar inherits that contract. The agent writes via `Write`
(not `Edit`) → overwrite-on-every-dispatch is automatic.

**Reference to constraint.** CLAUDE.md "Don't add features beyond what
the task requires." The §5 prompt has FOUR call sites that name
`{verdict_review_path}` (lines 1563, 1749, 1804, plus 1865 which says
"opposite lifecycle from … verdict-review.json"). Edit the first three —
they are agent-write instructions. The fourth at 1865 is *narrative
prose* describing the ledger's append-only-vs-overwrite contrast vs the
canonical; the canonical filename does not change, so the reference is
still accurate and does NOT need editing.

### D-004. Caller-side rc remap. Helper rc=39 (body malformed/oversize) → 36 (review-payload-malformed). rc=41 (body missing) → 38 (review-payload-missing). rc=42 (body is symlink) → 36. rc=50 (write failure) → 36. Halt via the existing `_post_review_payload_halt` at `bin/run-stage.sh:1428-1436`.

**Rationale.** The merge helper returns codes in the qa-payload range
(39/41/42/50 — see `bin/common.sh:702-708`). ENG-203 D-006 documents
the same situation for the qa caller and notes that 42/50 are
cosmetically mis-mapped in `failure_outcome_for_exit` (qa-predicate-malformed
and review-ledger-missing respectively). The review caller has the same
cosmetic mis-map for rc=50 (review-ledger-missing) and a fresh one for
rc=42 — which is the qa-predicate-malformed text in the taxonomy.

Same trade-off, same resolution: the halt-comment body names the actual
problem (the helper's diagnostic line `merge: body is symlink: <path>` or
`merge: atomic mv failed` is embedded verbatim in the comment via
`_post_review_payload_halt`'s `raw` parameter — see line 1429-1434). The
taxonomy entry is just the categorisation token visible to the
retrospective; the halt comment is the operator-visible signal.

Implementation snippet (sibling of `_merge_qa_payload_envelope` at line
2089-2111):

```bash
# ENG-205: review-payload envelope merge. Reads agent-authored content-only
# verdict-review.body.json; splices {review_schema_version, issue_id,
# dispatch_id} envelope onto a fresh canonical verdict-review.json.
_merge_review_payload_envelope() {
  local ident="$1"
  local d; d="$(issue_dir "$ident")"
  local body="$d/verdict-review.body.json"
  local canonical="$d/verdict-review.json"
  local env_json
  env_json="$(jq -nc --arg ii "$ident" --arg di "${PIPELINE_DISPATCH_ID:-}" \
    '{review_schema_version: 1, issue_id: $ii, dispatch_id: $di}')"
  local rc=0 raw=""
  raw="$(PIPELINE_ISSUE_ID="$ident" PIPELINE_STAGE=reviewing \
    merge_artifact_envelope "$body" "$env_json" "$canonical" 2>&1)" || rc=$?
  if (( rc != 0 )); then
    local defect="" remap=0
    case "$rc" in
      41) defect="review-payload-missing"; remap=38 ;;
      39|42|50) defect="review-payload-malformed"; remap=36 ;;
    esac
    _post_review_payload_halt "$ident" "$defect" \
      "merge_artifact_envelope failed (rc=$rc) for body=$body${raw:+ — $raw}"
    return "$remap"
  fi
  return 0
}
```

The remap explicitly converts helper rc → review-payload-taxonomy rc
before returning, so the caller block at line 2960-2972 sees a value the
existing `case "$rc" in 36|37|38)` shape already handles. This is a
mild divergence from `_merge_qa_payload_envelope` (which returns the
helper's rc verbatim because the qa range overlaps the helper range);
the review range does NOT overlap (36/37/38 vs 39/41/42/50), so a
remap is required. The asymmetry is documented in the function header
comment.

**Rejected — return the helper's rc verbatim and patch
`failure_outcome_for_exit` to multiplex 39/41/42/50 by stage.** Stage
context is not available to `failure_outcome_for_exit` (it takes
`exit_code` + `subcode` only — `bin/common.sh:759-806`); adding a stage
arg ripples through every caller across the codebase. The localised
remap inside `_merge_review_payload_envelope` is smaller and
self-contained.

**Reference to constraint.** CLAUDE.md "When wiring a new script": "For
exit codes, use the `failure_outcome_for_exit` taxonomy (common.sh) —
unmapped codes route to `unknown-exit-N`." Codes 36/37/38 are mapped
(`bin/common.sh:789-791`).

### D-005. `_clear_current_stage_slots` reviewing branch (`bin/run-stage.sh:962-964`) gains one `rm -f` for `verdict-review.body.json`. The canonical `verdict-review.json` clear is already present (ENG-119, line 963).

**Rationale.** Per the ENG-87 cross-dispatch staleness contract: per-issue
files cleared on dispatch start. The body sidecar is a new per-issue
file in the same family as the canonical. Today's block:

```bash
if [[ "$stage" == "reviewing" ]]; then
  rm -f "$d/verdict-review.json" 2>/dev/null || true
fi
```

Becomes:

```bash
if [[ "$stage" == "reviewing" ]]; then
  rm -f "$d/verdict-review.json"      2>/dev/null || true
  rm -f "$d/verdict-review.body.json" 2>/dev/null || true
fi
```

Without the new clear line, a stale body from a prior dispatch would
leak into the next dispatch's merge (yielding a "merge succeeded"
canonical built on yesterday's grading). The review-payload validator
rejects on `dispatch_id` mismatch (`bin/review-payload-schema.sh:160-163`)
so the halt would still fire — but the halt diagnostic would name
"dispatch_id mismatch" (misleading) rather than the actual cause
(stale body). Clean clear; clean diagnostic.

**Edge case — loopback `reviewing → implementing`.** When path B
(request-changes) loops review back to implementing, the next
implementing-stage dispatch runs `_clear_current_stage_slots "$ident"
"implementing"` which does NOT touch reviewing files (per the existing
stage-gating at line 962). The review body and canonical survive the
loopback. When reviewing re-dispatches after implement completes, the
reviewing-stage clear fires fresh. No staleness regression. (This
mirrors ENG-203 D-005's loopback analysis verbatim.)

**Reference to constraint.** CLAUDE.md "Cross-dispatch staleness
contract": "Per-medium primitives: clear-on-dispatch-start for per-issue
files (current-stage only; OTHER stages preserved for loopback)." The
review-stage gating is preserved.

### D-006. Sequencing in `run-stage.sh::main` post-dispatch block: insert `_merge_review_payload_envelope` as a NEW step BEFORE `_validate_review_payload` at line 2960. Order: clear-on-start → dispatch → `_merge_review_payload_envelope` → `_validate_review_payload` → `_validate_review_ledger` → `_post_deferred_majors_comment_if_eligible` → `_validate_review_thresholds` + `_create_follow_up_tickets_for_deferred_majors`.

**Rationale.** The merge must run before the validator (else validator
sees a body-only document missing `review_schema_version` and halts with
the ENG-118-shaped "missing required field: review_schema_version" — the
exact failure ENG-203 avoided for qa). Caller wiring at line 2960:

```bash
# ENG-205: review-payload envelope merge. Reviewing stage only.
if (( ! skip_dispatch )); then
  case "$stage" in
    reviewing)
      local _rev_merge_rc=0
      _merge_review_payload_envelope "$ident" || _rev_merge_rc=$?
      if (( _rev_merge_rc != 0 )); then
        classify_failure "$ident" "$stage" "skip-until-human-acts" \
          "review-payload-invalid: $(failure_outcome_for_exit "$_rev_merge_rc")" \
          "$_rev_merge_rc"
        exit "$_rev_merge_rc"
      fi
      ;;
  esac
fi

# ENG-119 existing block at 2960-2972 — _validate_review_payload —
# runs unchanged below.
```

Downstream consumers all see the merged canonical: `_validate_review_payload`
at line 2964 (no change), `_validate_review_ledger` at line 2982 (no
change), `_post_deferred_majors_comment_if_eligible` at line 3002
(reads `verdict-review.json` indirectly via the ledger — unaffected),
`_validate_review_thresholds` at line 1722 (reads canonical at
`$(issue_dir "$ident")/verdict-review.json` — verified, unaffected),
`_create_follow_up_tickets_for_deferred_majors` at line 3020 (ledger-
driven, unaffected).

**Reference to constraint.** AC#3 of ENG-205: "ENG-118's threshold-coercion
read of the merged file (once that ships) is unaffected." Verified: the
threshold gate reads `$payload` at line 1722 (`$(issue_dir
"$ident")/verdict-review.json`) and then `.verdict` (line 1728) and
`.dimensions[$n].score` (line 1759+). All three values are in the body;
the merge does not touch them.

**Reference to constraint.** CLAUDE.md "Pipeline vocabulary": no new
event-registry entries required — merge failure halts via the existing
`review-payload-invalid` halt reason already wired through
`_post_review_payload_halt`. The closed-vocabulary guarantee holds.

### D-007. No backward-compat shim for "old-style canonical without body sidecar." Body file is required.

**Rationale.** Mirrors ENG-203 D-008 verbatim:

1. Prompts are re-rendered every dispatch by `bin/render-prompt.sh`.
   The moment ENG-205 ships, every new reviewing dispatch's rendered
   prompt instructs the agent to write the body — there is no in-flight
   scenario where an agent renders the old prompt and produces the old
   shape. The cutover is atomic per-dispatch.

2. Accepting "canonical without body" as a fallback would silently
   re-introduce the slip surface. The agent could land a malformed
   canonical and the merge would no-op, the validator would halt on the
   agent's bad envelope. Reject.

**Implementation.** When the body is missing post-dispatch, halt with
`review-payload-invalid: review-payload-missing` (rc=38 after remap).
Halt body says "verdict-review.body.json missing — agent did not write
the body file. The orchestrator-merge contract requires body-only
output; see `docs/runbooks/recovery.md` §16."

**In-progress dispatch at deploy time** (cutover edge). A reviewing
dispatch already in flight when the operator deploys ENG-205 (agent
started under the old prompt, orchestrator code rolled to the new
binary) will land an old-shape canonical with no body sidecar, and the
new orchestrator's `_merge_review_payload_envelope` halts with
`review-payload-missing`. Recovery is `bash bin/pipeline.sh decide
<ENG-N> --action continue` — clears halt label, re-dispatches under
the new prompt, agent writes body. Bounded to one issue per project
(the one currently in reviewing at deploy time). The ENG-203 brainstorm
named this case "the ONLY legitimate operator-visible cutover artifact";
the same naming applies. `docs/runbooks/recovery.md` §16 is added by
this ticket (paralleling §15 added by ENG-203).

**Reference to constraint.** CLAUDE.md "Don't add backwards-compatibility
shims when you can just change the code." Prompts are re-rendered every
dispatch; no in-flight agents survive a prompt change.

### D-008. Asymmetry from ENG-203: NO `--body` flag on any in-dispatch tool. The merge is post-dispatch only.

**Rationale.** ENG-203 D-004 added `verify-qa.sh validate --body` because
the qa agent invokes `verify-qa.sh` IN-DISPATCH (per AGENT_PROMPTS.md §6
step 1) to consume per-criterion JSONL output before deciding its verdict
path. The qa-predicate body merge happens in-band inside the agent's
own tool call.

The review stage has NO in-dispatch validator the agent calls. The
review agent writes `verdict-review.json` (post-ENG-205: the body) as
the LAST step before the verdict marker (`AGENT_PROMPTS.md:1804-1805`),
then exits. `_validate_review_payload` runs post-dispatch from the
orchestrator (`bin/run-stage.sh:2956-2972`). No agent-side flag is
needed; the merge sits entirely on the orchestrator side.

**Consequence.** ENG-205's footprint is strictly smaller than ENG-203's:
no `bin/verify-qa.sh`-style edit, no in-dispatch realpath fence (the
agent never names the body path to a Bash tool that opens it — the
agent only `Write`s the body, and `Write` respects the dispatch's CWD
sandbox).

**Rejected — generalise the qa-predicate `--body` pattern preemptively
into a future `bin/review-validate.sh validate --body`.** No in-dispatch
caller exists; building one to consume a flag nothing calls is YAGNI.
ENG-202's later children that DO need an in-dispatch surface (plan.json
might if the implement agent reads it via a validator — currently it
does not) can add the flag at that point.

**Reference to constraint.** CLAUDE.md ticket sizing rubric: "Don't
design for hypothetical future requirements. Three similar lines is
better than a premature abstraction."

### D-009. Test surface mirrors ENG-203 D-009 at three call sites. Helper-level unit tests are NOT re-added (the helper is unchanged from ENG-203 and its U-1..U-10 cases already cover the contract).

**Rationale.** AC#2 of ENG-205 pins "validation passes on the merged
file with a boilerplate-free body" — the orchestration tests cover this.
AC#1 pins "boilerplate keys gone from §5" — the prompt-content tests
cover this. AC#3 pins "clear-on-dispatch-start preserved" — the clear
test covers this. Cases:

Orchestration tests in `bin/run-stage-test.sh`:

* **OS-R1.** Body has only `{sha, verdict, dimensions}`; merge runs;
  `_validate_review_payload` accepts the merged canonical. Pins AC#2.
* **OS-R2.** Body missing post-dispatch → halt rc=38 (remapped from
  helper rc=41), `classify_failure` reason
  `review-payload-invalid: review-payload-missing`. Pins D-004 + D-007.
* **OS-R3.** Body parse error → halt rc=36 (remapped from helper rc=39).
* **OS-R4.** Stale body from prior dispatch is cleared at reviewing-stage
  dispatch start; assert BOTH `verdict-review.json` AND
  `verdict-review.body.json` are absent post-`_clear_current_stage_slots
  <ident> reviewing`. Pins AC#3 + D-005.
* **OS-R5.** Body present, envelope merge succeeds, ENG-118 threshold
  gate (`_validate_review_thresholds`) reads merged canonical and
  coerces correctly when a payload-emitted dimension falls below floor.
  Pins the "consumer reads the merged file" contract from ENG-205's
  Dependencies section.

Prompt-content tests in `bin/agent-prompts-content-test.sh`:

* **AP-R1.** §5 documented required-fields block does NOT contain the
  literal `review_schema_version` in the agent content-shape area
  (allowed in the "orchestrator merges" prose sentence, by section
  locator). Pins AC#1.
* **AP-R2.** §5 documented required-fields block does NOT contain
  `dispatch_id` or `issue_id` as required-for-agent.
* **AP-R3.** §5 contains the literal `{verdict_review_body_path}` token
  at the agent Write instruction line.
* **AP-R4.** §5 does NOT contain the literal `{verdict_review_path}`
  token at the agent Write instruction line (it MAY appear elsewhere
  in narrative prose — same section-locator approach as AP-R1).

Render-prompt smoke test (`bin/render-prompt-rc0-test.sh` or similar):

* **RP-R1.** The new token `{verdict_review_body_path}` resolves to a
  non-empty path under `$(issue_dir <ident>)/verdict-review.body.json`
  when rendered against the reviewing stage. Pins D-002's resolver
  wiring.

Helper-level cases (U-1 .. U-10 in `bin/common-test.sh`, added by
ENG-203) are NOT re-added. The helper is unchanged; covering it twice
is YAGNI.

**Reference to constraint.** AC#2: "validation passes on the merged
file with a boilerplate-free body." OS-R1 pins this end-to-end. AC#3
"clear-on-dispatch-start … preserved, pinned by test." OS-R4 pins this.

## 3. Architecture

### 3.1 Files touched

| Path | Change | Lines |
|---|---|---|
| `bin/common.sh` | Add `verdict_review_body_path <ident>` helper next to `qa_payload_body_path` (line 99). Add to existing `export -f` list. | ~10 added |
| `bin/run-stage.sh` | Add `_merge_review_payload_envelope <ident>` function next to `_merge_qa_payload_envelope` (line 2089). Insert the merge call in the post-dispatch reviewing block BEFORE `_validate_review_payload` (line 2960). Extend `_clear_current_stage_slots` reviewing branch (line 962-964) with one `rm -f` for `verdict-review.body.json`. | ~35 added |
| `bin/render-prompt.sh` | Add `verdict_review_body_path=_resolve_verdict_review_body_path` to `PROMPT_RESOLVERS` (line 40-66). Add `_resolve_verdict_review_body_path` body (mirror lines 289-290). Bind `_RENDER_VERDICT_REVIEW_BODY_PATH` in `main()` next to the existing `_RENDER_QA_PAYLOAD_BODY_PATH` binding (line 687). | ~6 added |
| `AGENT_PROMPTS.md` (§5 review) | Edit line 1563, 1749, 1804: change `{verdict_review_path}` → `{verdict_review_body_path}` at the three agent-Write instruction sites. Edit lines 1808-1812: strip `review_schema_version`, `issue_id`, `dispatch_id` from the required-fields list; add the explanatory sentence "the orchestrator merges schema envelope before validation." Leave line 1865 ("opposite lifecycle from … verdict-review.json") untouched — refers to the canonical, unchanged. | ~8 changed |
| `bin/run-stage-test.sh` | Add OS-R1 through OS-R5 (D-009). | ~120 added |
| `bin/agent-prompts-content-test.sh` | Add AP-R1 through AP-R4 (D-009). | ~40 added |
| `bin/render-prompt-rc0-test.sh` | Add RP-R1 (D-009) — token resolution check. | ~15 added |
| `bin/review-payload-schema.sh` | NO change. Schema validator runs on the merged canonical, unchanged. | 0 |
| `bin/qa-payload-schema.sh` | NO change (qa is ENG-203's scope). | 0 |
| `bin/common-test.sh` | NO change. Helper unit tests U-1..U-10 added by ENG-203 already cover the contract. | 0 |
| `bin/pipeline-events.json` | NO change. `envelope-overwrite` metric added by ENG-203 covers the review caller too (emitted from `merge_artifact_envelope`, line 736-740). | 0 |
| `docs/runbooks/recovery.md` | Add §16 "review-payload merge failure" with recovery recipe (the halt body's "see §16" pointer). Mirrors ENG-203 §15. | ~25 added |
| `CLAUDE.md` "Failure-mode quick reference" table | Add row for `review-payload-invalid: review-payload-missing` with merge-failure root cause and §16 recovery pointer. | ~3 added |

### 3.2 Subsystems touched (rubric check)

Per CLAUDE.md "Ticket sizing rubric":

* **orchestrator** — `bin/run-stage.sh` (merge function + caller + clear
  extension).
* **agent prompts** — `AGENT_PROMPTS.md` §5 (the documented required-fields
  + token swap edits).
* **tests/fixtures** — `bin/run-stage-test.sh`,
  `bin/agent-prompts-content-test.sh`, `bin/render-prompt-rc0-test.sh`.
* **dispatch** — `bin/common.sh` (one new helper), `bin/render-prompt.sh`
  (one new resolver). Clearly subordinate to orchestrator: each is
  ≤10 lines added.

**Ticket sizing matches: 2 subsystems (orchestrator + agent-prompts),
dispatch subordinate.** Autonomy-safe per the ticket's own sizing.

### 3.3 Per-dispatch data flow

```
reviewing agent dispatches.
  ↓
agent does cold + warm pass + ensemble work; computes adjudicated counts.
  ↓
agent writes content-only body via Write tool at
   {verdict_review_body_path} = $(issue_dir ident)/verdict-review.body.json
   body = { "sha": "<head-sha>",
            "verdict": "approve|request-changes|premise-failure|halt",
            "dimensions": { "correctness": {...}, "testing": {...},
                            "maintainability": {...}, "scope": {...},
                            "security": {...},  # optional
                            ... } }
  ↓
agent emits verdict marker via bash bin/pipeline.sh event.
  ↓
agent dispatch exits.
  ↓
run-stage.sh post-dispatch sequence (reviewing stage):
  ↓
_merge_review_payload_envelope ident       (NEW, ENG-205)
  ↓
  Step 1: env_json = jq -nc { review_schema_version: 1,
                              issue_id: $ident,
                              dispatch_id: $PIPELINE_DISPATCH_ID }
  ↓
  Step 2: merge_artifact_envelope $body $env_json $canonical
            body=$(issue_dir ident)/verdict-review.body.json
            canonical=$(issue_dir ident)/verdict-review.json
  ↓
  Step 3: rc=0 → return 0.
          rc=41 (body missing) → remap to 38 → _post_review_payload_halt
                                   + classify_failure + exit 38.
          rc=39|42|50 → remap to 36 → halt + exit 36.
  ↓
_validate_review_payload ident             (existing, ENG-119, unchanged)
  → runs review-payload-schema.sh validate on canonical
  → canonical now has the orchestrator-injected envelope keys,
    schema-v1 validation passes.
  ↓
_validate_review_ledger ident              (existing, ENG-190, unchanged)
  → runs review-ledger-schema.sh validate on ledger; unaffected.
  ↓
_post_deferred_majors_comment_if_eligible  (existing, ENG-191, unchanged)
  → reads fresh verdict marker; soft-fail; unaffected.
  ↓
_validate_review_thresholds ident          (existing, ENG-118, unchanged)
  → reads .review.thresholds + canonical's .verdict + .dimensions[].score;
    coerces if any below floor. Unaffected because all three keys are
    content (in body, surviving the merge unchanged).
  ↓
_create_follow_up_tickets_for_deferred_majors (existing, ENG-193).
  ↓
push_branch_if_ahead + post_completion_comment + verdict_handler.
```

## 4. Data Flow

### 4.1 Envelope construction (review payload)

```bash
local env_json
env_json="$(jq -nc \
  --arg ii "$ident" \
  --arg di "${PIPELINE_DISPATCH_ID:-}" \
  '{review_schema_version: 1, issue_id: $ii, dispatch_id: $di}')"
```

* `review_schema_version`: hardcoded `1` — schema-v1 is the only
  supported version (`bin/review-payload-schema.sh:119-126` rejects
  anything else). When schema-v2 lands, this constant moves to a
  helper-level argument (same upgrade path ENG-203 documented for qa).
* `issue_id`: `$ident` — already validated by `run-stage.sh::main`
  against `^ENG-[0-9]+$` before dispatch begins (ENG-87 invariant).
* `dispatch_id`: `$PIPELINE_DISPATCH_ID` — allocated by
  `allocate_dispatch_id` at `bin/run-stage.sh::main`; format
  `^ENG-[0-9]+-d[0-9]+$` is guaranteed by the allocator.

If `$PIPELINE_DISPATCH_ID` is empty (sub-case: scope-approval replay
path that doesn't re-allocate), the envelope's `dispatch_id` field is
the empty string, and `bin/review-payload-schema.sh:150-157` rejects
it with `dispatch_id must be a non-empty string`. **This is correct
behavior**: the merge-and-halt path makes the missing dispatch-id
surface explicit. (Same analysis as ENG-203 §4.1.)

### 4.2 Body content shape

```json
{
  "sha": "<HEAD-SHA the review ran against>",
  "verdict": "approve|request-changes|premise-failure|halt",
  "dimensions": {
    "correctness":     { "score": "...", "rationale": "...",
                         "thresholds_met": [...], "thresholds_missed": [...] },
    "testing":         { ... },
    "maintainability": { ... },
    "scope":           { ... },
    "security":        { ... },        // optional
    "performance":     { ... },        // optional
    "api_contract":    { ... },        // optional
    "premise":         { ... }         // optional
  }
}
```

`sha` and `verdict` are content the agent reasons about — they are NOT
envelope. `sha` is the HEAD SHA the agent reviewed against; `verdict` is
the agent's mechanical decision-path output. Both are agent-typed and
fall outside this ticket's scope (the orchestrator could derive `sha`
via `git rev-parse HEAD` post-dispatch — see Open Question OQ-1 — but
ENG-205 ships only the three keys the ticket names).

## 5. Error Handling

### 5.1 Helper failure modes

| Helper rc | Cause | Caller remap | Halt reason |
|---|---|---|---|
| 39 | body parse error / not object / oversize (> 64 KiB) | 36 | review-payload-malformed |
| 41 | body file missing | 38 | review-payload-missing |
| 42 | body file is symlink | 36 | review-payload-malformed |
| 50 | mktemp / jq / atomic mv failure | 36 | review-payload-malformed |

All four halt via `_post_review_payload_halt` (`bin/run-stage.sh:1428-1436`)
with the helper's stderr diagnostic embedded verbatim in the comment
body's tilde-fenced section (so the operator sees the actual cause —
e.g. "merge: body is symlink: …" rather than the cosmetic taxonomy
text "qa-predicate-malformed").

### 5.2 Downstream validator behaviour

After a successful merge, the canonical `verdict-review.json` is the
schema-v1 shape the existing validator expects, end-to-end:

* `_validate_review_payload` (`bin/run-stage.sh:1400-1419`) runs
  `bin/review-payload-schema.sh validate` against the canonical with
  `--ident $ident --dispatch-id $PIPELINE_DISPATCH_ID`. The
  orchestrator-injected envelope keys match exactly (they were
  constructed from those same inputs); validation passes.
* The mismatch arm at `bin/review-payload-schema.sh:160-163`
  ("dispatch_id mismatch: JSON has '…' but --dispatch-id '…' was passed
  (prior-dispatch payload survived pre-clean?)") cannot fire on a
  fresh merge — both values trace to the same envelope `--arg di
  "${PIPELINE_DISPATCH_ID:-}"`. The arm remains as a guard against
  agent hand-edits that bypass the merge path; that surface is
  unchanged.

### 5.3 Forensic signal

The merge helper's existing `envelope-overwrite` metric
(`bin/common.sh:736-740`) fires when body keys collide with envelope
keys (i.e. an agent attempted to emit an envelope key in the body, and
the envelope's right-biased merge overwrote it). Per ENG-203 D-001,
this is the diagnostic signal that says "the prompt+body contract is
being violated by the agent" — retrospective-visible. ENG-205 inherits
this for free.

## 6. Edge Cases

### 6.1 Empty `dispatch_id` (scope-approval replay path)

Same as ENG-203 §4.1: when `$PIPELINE_DISPATCH_ID` is unset (the
scope-approval replay path that doesn't re-allocate), the envelope's
`dispatch_id` field is the empty string, schema validation rejects it
with `dispatch_id must be a non-empty string`. Correct behaviour:
explicit halt > silent acceptance.

### 6.2 Loopback `reviewing → implementing` (Path B / Path B′)

When the agent emits `verdict request-changes` (Path B) or
`verdict wait` (Path B′), the orchestrator loops the issue back to
implementing. The reviewing-stage clear DOES NOT fire on the implement
dispatch (per the existing stage-gating at `bin/run-stage.sh:962`).
The review body and canonical survive the loopback. When reviewing
re-dispatches after implement completes, the reviewing-stage clear
fires fresh, the new merge runs against the new body, no staleness
leaks. Verified path against `_clear_current_stage_slots` (line
949-982) — stage gating preserved.

### 6.3 In-progress dispatch at deploy time

The one operator-visible cutover artifact (D-007). Bounded to one issue
per project (the one currently in reviewing when the new harness binary
boots). Recovery: `bash bin/pipeline.sh decide <ENG-N> --action continue`.

### 6.4 Agent writes content-key into envelope-key territory

If a buggy agent writes `review_schema_version: 99` into the body, the
envelope-wins merge silently overwrites it with `1`, and the
`envelope-overwrite` metric fires (`bin/common.sh:736-740`) carrying
`keys=review_schema_version`. Retrospective surfaces the prompt-drift
or agent-bug; canonical remains valid. No halt, no operator action
needed. Same trade-off as ENG-203 D-001 documented in U-10.

### 6.5 Threshold gate read-path

Verified: `_validate_review_thresholds` (`bin/run-stage.sh:1722-1764`)
reads `$payload = $(issue_dir "$ident")/verdict-review.json` (the
canonical, post-merge) and consumes `.verdict` + `.dimensions[$n].score`
— all body content. AC#3 of ENG-205 explicitly pins this: "ENG-118's
threshold-coercion read of the merged file is unaffected." Verified by
direct file inspection.

## 7. Open Questions

* **OQ-1** Should `sha` move into the envelope? It's orchestrator-derivable
  post-dispatch via `git rev-parse HEAD` against the per-issue worktree.
  Argument for: closes one more slip surface. Argument against: scope
  explicitly excludes it ("Boilerplate the review agent currently emits
  and could slip on: `review_schema_version` (1) and `issue_id`. ENG-205
  also covers `dispatch_id`. `sha` is content — agent-typed."). **Defer
  to ENG-202 follow-up if `sha` becomes a live slip class.**

* **OQ-2** Should the review-ledger get an envelope/body split? Ticket
  scope explicitly excludes ledger ("the review-findings-ledger (sibling
  children)"). Ledger has opposite lifecycle (append-only across
  dispatches, never cleared) and per-row envelope, so the helper as
  written doesn't fit. **Out of scope; defer to a separate ENG-202
  child.**

* **OQ-3** Should we promote `envelope-overwrite` to a per-stage signal
  by including `stage=reviewing` in the metric payload? Already
  done — `PIPELINE_STAGE=reviewing` is exported by the caller
  (`_merge_review_payload_envelope`) and read by the helper at
  `bin/common.sh:738`. Pinned by metric-shape test in ENG-203;
  ENG-205's caller respects the convention. **No new action.**

* **OQ-4** Should the §5 prompt-content tests use the same section-locator
  shape as ENG-203's §6 step-9 locator (AP-1/AP-2 at
  `bin/agent-prompts-content-test.sh`)? Yes — same shape. Concrete locator
  TBD at plan time; the principle ("narrow the assertion to the
  required-fields documented area, not the whole §5 block") is the
  contract. Documentary note for the plan agent.

## 8. Persona review

| Persona | Verdict | Notes |
|---|---|---|
| design | PASS | Mechanism mirrors ENG-203 D-001 exactly; no new architectural decision; ADR-stress-test §9.1 below. |
| security | PASS | No new tool authority surface (no `--body` flag; no in-dispatch fence required). The body path is composed by `verdict_review_body_path()` from `issue_dir`, which already resolves under `$PROJECT_STATE_DIR`. Helper's existing symlink + size-cap defenses cover. |
| scope | PASS | Three subsystems touched (orchestrator + agent-prompts primary; dispatch subordinate at ≤10 lines per file). Matches the ticket's "2 subsystems, autonomy-safe" sizing. No out-of-scope expansion. |
| coherence | PASS | All consumers of `verdict-review.json` read the canonical; merge produces the same canonical shape as the pre-ENG-205 agent-emitted file. Threshold gate, ledger validator, deferred-majors comment, follow-up ticket creator all verified path-compatible. |
| product | PASS | Operator-visible cutover bounded to one issue (D-007). Halt message + recovery pointer mirror the ENG-203 §15 shape the operator has already internalised. No new label, no new wait reason, no new event-registry token. |
| feasibility | PASS · 0 P0 | Every code reference verified at quoted `path:line`; no fabricated function names; no claims about behaviour that disagrees with the current source. ENG-203 helper exists on disk (`bin/common.sh:713`) as memory and verification both confirmed. |

### Persona review notes

* **Design (ADR-stress-test, §9.1).** The decision to *reuse* ENG-203's
  helper without modification puts pressure on D-001 of that brainstorm
  ("caller owns envelope-keyset discipline"). Each new caller adds a
  keyset definition (closed to 3 keys here, vs ENG-203's 3-or-2 by
  artifact) and a U-10-style adversarial test would ideally exist
  per-caller. D-009 above defers the helper-level retest as YAGNI
  (helper unchanged); the *caller-side* OS-R1 test asserts the
  3-key envelope contract on the merged result, which is the
  meaningful boundary. Trade-off acknowledged.

* **Security.** The body-path helper composes only via
  `printf '%s/verdict-review.body.json' "$(issue_dir "$issue")"`. The
  agent's `Write` tool sandboxes against the dispatch CWD plus
  per-issue state-dir grants the agent has at dispatch time
  (handled at the prompt + dispatch surface, unchanged by ENG-205).
  No new file-authority surface is opened.

* **Scope.** Per the ticket's "Sizing" block: "2 subsystems —
  orchestrator (`run-stage.sh`, review validator) + agent-prompts
  (§5 review). 1 decision: the verdict-review.json envelope/body
  split. Autonomy-safe." Verified — `bin/common.sh` (1 helper, ~10
  lines), `bin/render-prompt.sh` (1 resolver, ~6 lines) are clearly
  subordinate.

* **Coherence.** Verified read-paths of consumers post-merge:

  - `_validate_review_payload` reads canonical at line 1402; full
    schema-v1 validation against the merged file passes.
  - `_validate_review_ledger` reads `review-findings-ledger.jsonl` at
    line 1444 — independent of `verdict-review.json`; unaffected.
  - `_post_deferred_majors_comment_if_eligible` reads fresh verdict
    marker via `find_fresh_verdict` (not the JSON file); unaffected.
  - `_validate_review_thresholds` reads canonical at line 1722,
    consumes `.verdict` (line 1728) and `.dimensions[$n].score` (line
    1759+). Both body content; merge preserves verbatim.
  - `_create_follow_up_tickets_for_deferred_majors` is ledger-driven;
    unaffected.

* **Product.** The §5 prompt is the operator's contact surface
  whenever a reviewing dispatch halts. D-007's halt message
  ("verdict-review.body.json missing — agent did not write the body
  file. The orchestrator-merge contract requires body-only output;
  see `docs/runbooks/recovery.md` §16.") mirrors ENG-203 §15's shape,
  so the operator's mental model carries over.

  **Plan-time note (product persona, P2).** D-004's snippet hardcodes
  the diagnostic string `"merge_artifact_envelope failed (rc=$rc) for
  body=$body${raw:+ — $raw}"` for ALL rc values. For rc=41 (body
  missing) specifically, the plan agent should consider branching the
  diagnostic so the operator sees the friendlier "verdict-review.body.json
  missing — agent did not write the body file" text D-007 promises,
  not the helper-internal "merge_artifact_envelope failed" text. The
  helper's `raw` stderr ("merge: body missing: …") IS embedded after
  the em-dash, so the cause is recoverable from the comment in any
  case; the friendlier framing is polish, not a structural defect.

  **Plan-time note (product persona, P2).** If the agent both writes a
  full canonical AND a body sidecar (defensive double-write), the merge
  helper's atomic `mv` of its tmp file overwrites the agent's canonical
  silently. Behaviour is correct; document it in §16 so the operator
  understands "I see a canonical too" is not a contract violation.

* **Feasibility.** Every named codebase fact in the brainstorm has a
  verified `path:line` citation in §9.2 below. No fabricated
  functions; no assumed-but-unchecked behaviours; ENG-203 helper
  on-disk confirmation passed.

## 9. Assumption Inventory

### 9.1 ADR-stress-test on ENG-203

The decision to reuse `merge_artifact_envelope` unchanged puts
two-line pressure on ENG-203 D-001's "callers own envelope-keyset
discipline" contract:

* Each new caller needs its own OS-N adversarial test pinning the
  3-key envelope contract. D-009 OS-R1 covers ENG-205 but does NOT
  add a sibling of U-10 (the documentary test in `common-test.sh`).
  Trade-off acknowledged; bounded YAGNI.

* Each new caller's rc-remap logic is hand-written. If a fourth
  caller lands (ENG-202 plan or review-ledger child), the remap
  pattern would warrant a shared helper. ENG-205 is not yet the
  third caller (qa is one, ENG-205 is two) so the abstraction
  remains premature.

No ADR overturn proposed.

### 9.2 Codebase-fact verification

All references below were opened and confirmed in the current branch
HEAD tree:

| Claim | Source | Status |
|---|---|---|
| `merge_artifact_envelope` exists at `bin/common.sh:713` | Read tool, file inspected | verified |
| `qa_payload_body_path` exists at `bin/common.sh:99` | Read tool | verified |
| `qa_predicate_body_path` exists at `bin/common.sh:104` | Read tool | verified |
| `failure_outcome_for_exit` codes 36/37/38 = review-payload-(malformed/incomplete/missing) at `bin/common.sh:789-791` | Read tool | verified |
| `_merge_qa_payload_envelope` exists at `bin/run-stage.sh:2089-2111` (template for the new function) | Grep+Read | verified |
| `_validate_review_payload` exists at `bin/run-stage.sh:1400-1419` and runs `bin/review-payload-schema.sh validate <file> --ident <ident> --dispatch-id <id>` | Read tool | verified |
| `_post_review_payload_halt` exists at `bin/run-stage.sh:1428-1436`; embeds `raw` diagnostic via tilde-fenced section | Read tool | verified |
| `_clear_current_stage_slots` exists at `bin/run-stage.sh:949-982`; reviewing branch at lines 962-964 already clears canonical `verdict-review.json` | Read tool | verified |
| Post-dispatch review-payload validator caller at `bin/run-stage.sh:2956-2972` | Read tool | verified |
| Post-dispatch qa-payload merge caller at `bin/run-stage.sh:3025-3046` (template for the new caller) | Read tool | verified |
| `_validate_review_thresholds` at `bin/run-stage.sh:1704-1764` reads `$(issue_dir "$ident")/verdict-review.json` (line 1722) and consumes `.verdict` (line 1728) + `.dimensions[$n].score` (line 1759+) | Read tool | verified |
| `review-payload-schema.sh::cmd_validate` requires `review_schema_version: 1` (lines 119-126), `issue_id: ^ENG-[0-9]+$` (lines 128-138), `dispatch_id: ^ENG-[0-9]+-d[0-9]+$` (lines 146-157), `sha` (lines 165-172), `verdict` enum (lines 174-185), `dimensions` (lines 187-246) | Read tool | verified |
| `PROMPT_RESOLVERS` registry block at `bin/render-prompt.sh:40-66`; `verdict_review_path=_resolve_verdict_review_path` at line 57; `qa_payload_body_path=_resolve_qa_payload_body_path` at line 61 | Read tool | verified |
| `_resolve_qa_payload_body_path` at `bin/render-prompt.sh:289` (template for the new resolver) | Read tool | verified |
| `_RENDER_QA_PAYLOAD_BODY_PATH` binding at `bin/render-prompt.sh:687` (template) | Read tool | verified |
| `AGENT_PROMPTS.md` §5 references `{verdict_review_path}` at lines 1563, 1749, 1804 | Grep | verified |
| `AGENT_PROMPTS.md` §5 documented required fields `review_schema_version: 1`, `issue_id`, `dispatch_id`, `sha`, `verdict` at lines 1808-1812 | Read tool | verified |
| `AGENT_PROMPTS.md` line 1865 ("opposite lifecycle from … verdict-review.json") refers to canonical, not body — no edit needed | Read tool | verified |
| `bin/agent-prompts-content-test.sh` exists and has §6-step-9 locator pattern (referenced by ENG-203 D-009) | Grep+presence-check | verified (presence; exact locator shape deferred to plan time) |
| `bin/render-prompt-rc0-test.sh` exists | Grep (file in `grep` results for merge-helper symbols) | verified (presence) |
| `docs/runbooks/recovery.md` exists and §15 was added by ENG-203 | inferred from ENG-203 brainstorm §3.1; not directly opened | assumed |

The single "assumed" line (`docs/runbooks/recovery.md` §15) is a
documentation reference, not a code-shape claim. The plan agent will
verify §15's actual heading/anchor when authoring §16.

### 9.3 Other assumptions

* **assumed** — the agent's existing `--allowed-tools` for the
  reviewing stage grants `Write` against per-issue state-dir paths.
  Verified indirectly: agent already writes `verdict-review.json` to
  the same dir today (`AGENT_PROMPTS.md:1804-1822`); the body sibling
  sits in the same directory. The dispatch surface needs no change.
  Plan agent should re-verify against the rendered prompt's stage
  tools.

* **verified** — `$PIPELINE_DISPATCH_ID` is exported into the agent's
  subshell and available to orchestrator-side post-dispatch code
  (ENG-87 contract). Used in envelope construction.

* **verified** — the helper emits the `envelope-overwrite` metric only
  when `PIPELINE_ISSUE_ID` is set (`bin/common.sh:736`). The new
  caller exports `PIPELINE_ISSUE_ID="$ident"` (mirrors
  `_merge_qa_payload_envelope` at line 2098).

* **verified** — `failure_outcome_for_exit` for codes 39/41/42/50
  returns text in the qa range; the remap inside
  `_merge_review_payload_envelope` converts them to review codes
  36/38 BEFORE `classify_failure` is called, so the
  `failure_outcome_for_exit` text printed in the halt comment is
  review-flavoured.
