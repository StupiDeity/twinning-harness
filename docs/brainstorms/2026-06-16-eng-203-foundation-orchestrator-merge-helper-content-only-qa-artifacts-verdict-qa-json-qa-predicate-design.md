---
linear: ENG-203
title: Foundation — orchestrator-merge helper + content-only qa artifacts (verdict-qa.json, qa-predicate)
date: 2026-06-16
status: draft
---

# Foundation — orchestrator-merge helper + content-only qa artifacts

## 1. Problem

ENG-118 halted at `stage:qa` with `qa-payload-incomplete: missing required field
qa_payload_schema_version`. The qa agent had written a *content-complete,
clean-pass* dimensional-grading body — verdict + dimensions + scores — and
then dropped one boilerplate envelope key (`qa_payload_schema_version`),
omitted another (`issue_id`), and added a non-required one (`dispatch_id`)
that did not match the expected shape. The schema-v1 validator at
`bin/qa-payload-schema.sh:108-153` rejected it correctly; the orchestrator
halted the dispatch correctly; the operator had to repair the JSON by hand
and force the transition.

This is a structural class, not an isolated incident. Live evidence from
the operator's auto-memory (memory entry `qa-agent-schema-version-field-slip`):
the qa agent **reliably** emits format-invalid payloads when it has to write
boilerplate (wrong field name, hyphenated dim names, 0-10 scores, etc.). The
agent's strength is grading; the agent's weakness is invariant JSON
boilerplate. Today the prompt makes the agent responsible for both —
content AND envelope — and the envelope is the surface that slips.

ENG-202 generalised this as: **stage agents emit content; the orchestrator
owns the structured-artifact envelope.** ENG-203 is its foundation child —
the smallest concrete cut: define the merge mechanism, ship a reusable
helper, and prove it on the two qa-stage artifacts (`verdict-qa.json` and
`qa-predicate-<ident>.json`). The plan.json / verdict-review.json / review-
ledger children consume this helper unchanged.

The structural gap this ticket closes: **the agent never types the three
envelope keys (`*_schema_version`, `issue_id`, `dispatch_id`).** The keys
are constructed by orchestrator code from already-trusted inputs:
`$PIPELINE_DISPATCH_ID` (orchestrator-allocated, monotonic, ENG-87) and
`$ident` (the issue identifier, ENG-87 regex `^ENG-[0-9]+$`). The agent
emits only what it can reason about — the grading content. The envelope
slip surface disappears.

## 2. Decisions

### D-001. Mechanism: sidecar-merge. Agent writes content-only `<artifact>.body.json`; orchestrator merges envelope keys onto a fresh canonical `<artifact>.json` via a shared `common.sh::merge_artifact_envelope` helper; validator runs on the merged canonical.

**Rationale.** Four candidate mechanisms were considered:

* **A. Sidecar-merge (chosen).** Agent writes `verdict-qa.body.json`
  containing ONLY `verdict` + `dimensions[]`. Orchestrator post-dispatch
  invokes `merge_artifact_envelope` (new helper in `common.sh`) which
  reads the body, splices the envelope JSON `{qa_payload_schema_version:
  1, issue_id, dispatch_id}` onto it (envelope keys win on collision),
  writes the canonical `verdict-qa.json` atomically. The existing
  `_validate_qa_payload` at `bin/run-stage.sh:2073-2092` then runs on
  the canonical — unchanged. Schema validator at
  `bin/qa-payload-schema.sh:108-153` is unchanged.
* **B. Pre-seed.** Orchestrator writes a `verdict-qa.json` containing
  envelope-only at dispatch start; agent edits content via the `Edit`
  tool. Rejected — `Edit` requires a stable anchor on a file the agent
  did not author; the orchestrator-seeded envelope would have to embed
  an anchor like `"dimensions": [REPLACE_ME]` that the agent then
  searches for, and the failure mode is silent (anchor-not-found → no
  edit → seeded sentinel passes through to validator). Also: the agent
  could still corrupt envelope by editing past the anchor. Sidecar
  decouples envelope from content cleanly.
* **C. Validator accepts body-only, synthesises envelope at validation
  time.** Rejected — blurs the validator's contract (it stops being a
  pure structural check). Doesn't generalise: the validator can't know
  the canonical layout that plan/review children will impose.
* **D. Strengthen the prompt instead.** Rejected — memory entry
  `qa-agent-schema-version-field-slip` is live evidence that prompts
  don't suffice. The structural fix is to remove the slip surface
  entirely. Re-typing instructions an agent has already misread
  hardly counts as a fix.

**The shared helper.** A single function in `bin/common.sh`:

```bash
# merge_artifact_envelope <body-path> <envelope-json-string> <canonical-path>
#
# Read body JSON object at <body-path>; merge envelope keys onto it
# (envelope wins on collision); write the merged object atomically to
# <canonical-path>. Caller halts on non-zero rc per its own contract.
#
# rc=0  — merge succeeded; canonical written.
# rc=39 — body parse error (top-level not object, or JSON parse fail).
# rc=41 — body file missing or not a regular file.
# rc=42 — envelope-json-string is not a JSON object (caller bug).
# rc=50 — write failed (atomic mv error, disk space, etc.).
merge_artifact_envelope() { ... }
```

Returns codes from the qa-payload taxonomy (rc=39/41 — `bin/common.sh:732-734`,
`failure_outcome_for_exit`) so the qa caller can `exit "$rc"` directly without
remapping. The plan.json / verdict-review.json children would map their own
caller-side codes (33/34/35 for plan; 36/37/38 for review). The helper itself
is taxonomy-agnostic — it uses the qa range only because qa is its first
caller; rc=39/41 here are values returned to the qa caller, not
intrinsically "qa codes."

**Helper body** (jq one-liner inside a bash function — no shell expansion of
agent-controlled values; envelope-string is orchestrator-constructed):

```bash
merge_artifact_envelope() {
  local body="$1" env_json="$2" canonical="$3"
  [[ -f "$body" ]]            || { printf 'merge: body missing: %s\n' "$body" >&2; return 41; }
  [[ -L "$body" ]]            && { printf 'merge: body is symlink: %s\n' "$body" >&2; return 42; }
  local sz; sz="$(wc -c <"$body" 2>/dev/null | tr -d ' ')"
  (( sz > 0 && sz <= 65536 )) || { printf 'merge: body size out of range: %s bytes\n' "${sz:-0}" >&2; return 39; }
  jq -e 'type == "object"' "$body" >/dev/null 2>&1 \
    || { printf 'merge: body is not a JSON object: %s\n' "$body" >&2; return 39; }
  jq -e 'type == "object"' <<<"$env_json" >/dev/null 2>&1 \
    || { printf 'merge: envelope is not a JSON object\n' >&2; return 42; }
  local tmp
  tmp="$(mktemp "${canonical}.tmp.XXXXXX")" \
    || { printf 'merge: mktemp failed for %s\n' "$canonical" >&2; return 50; }
  jq -n --slurpfile b "$body" --argjson env "$env_json" \
    '$b[0] + $env' > "$tmp" \
    || { rm -f "$tmp"; printf 'merge: jq failed\n' >&2; return 50; }
  mv "$tmp" "$canonical" \
    || { rm -f "$tmp"; printf 'merge: atomic mv failed\n' >&2; return 50; }
  return 0
}
```

**Temp file via `mktemp`** (security persona Iter-1 P1). The `mktemp
"${canonical}.tmp.XXXXXX"` pattern is collision-proof against concurrent
in-shell siblings (`$$` would alias across two function calls in one
shell process — a credible scenario when plan/review children share a
per-tick run loop). The per-issue lock already serialises calls TODAY,
but the helper is reusable and we cannot assume future callers retain
the lock invariant — defense-in-depth.

**Envelope keyset is closed to exactly three keys** (feasibility persona
Iter-1 P1): the envelope JSON the helper receives MUST carry only the
identity keys `qa_payload_schema_version` (or its sibling for plan /
review), `issue_id`, and `dispatch_id` (qa-payload) or only the two-key
form `{qa_predicate_schema_version, issue_id}` (qa-predicate). **The
envelope MUST NOT carry `verdict`, `dimensions`, `pass_criteria`, or
any other content key** — the right-bias merge would silently overwrite
agent-authored content otherwise. The helper is taxonomy-agnostic and
does NOT enforce the keyset; the invariant is owned by the CALLER. Both
call sites in this brainstorm construct envelopes with the safe keyset
inline (see D-006's `_merge_qa_payload_envelope` and D-004's verify-qa.sh
`--body` integration). D-009 pins **caller-side** tests:

- **OS-6.** `_merge_qa_payload_envelope`'s constructed envelope contains
  exactly the keys `{qa_payload_schema_version, issue_id, dispatch_id}`
  (assert via `jq -r 'keys | sort | join(",")'` against the env_json
  built by the function — fixture-driven by stubbing
  `$PIPELINE_DISPATCH_ID` and asserting the literal key set).
- **OS-7.** verify-qa.sh `--body` envelope contains exactly the keys
  `{qa_predicate_schema_version, issue_id}` (same assertion shape).
- **U-10 (helper-level, documentary).** Adversarial caller passes an
  envelope containing a content key like `verdict: "fail"`; the helper
  merges right-biased (envelope wins) per its documented semantic, and
  the test asserts the canonical's `verdict` is `"fail"` (NOT the
  body's). This pins the contract that callers, not the helper, own
  envelope hygiene. The test header comment explicitly states "the
  helper is not the safety net; callers must construct envelopes from
  identity keys only."

This closes the silent-corruption surface at the only place defense is
meaningful — the call sites. A future ENG-202 child adding a fourth
caller (review-ledger, etc.) must add its own OS-N test mirroring the
shape above.

**Envelope-wins precedence.** The jq expression is `$b[0] + $env` — jq's
`+` on objects is right-biased (right operand keys overwrite left). This is
deliberate: the agent's purpose for emitting boilerplate is to satisfy the
schema; if the agent emits a wrong boilerplate value (e.g.
`qa_payload_schema_version: "v1"` instead of `1`), the orchestrator's
authoritative envelope overwrites it silently. The agent cannot poison
envelope keys.

**Reference to constraint.** CLAUDE.md "When wiring a new script": "Per-issue
state must reference `$PROJECT_STATE_DIR`, never `$HARNESS_STATE_DIR/<issue>`
directly." Body and canonical both resolve through `issue_dir`
(`bin/common.sh:68-72`) → `$PROJECT_STATE_DIR/<ident>/`.

**Reference to constraint.** CLAUDE.md "Cross-dispatch staleness contract
(ENG-87)": "Per-medium primitives: clear-on-dispatch-start for per-issue
files." Body sidecar gets the same treatment as `verdict-qa.json` — cleared
at qa-stage dispatch start by `_clear_current_stage_slots`
(`bin/run-stage.sh:949-974`). See D-005.

### D-002. Helper lives in `bin/common.sh`, not in a new top-level script.

**Rationale.** Three placement candidates:

* `bin/common.sh` (chosen). Mirrors the existing per-artifact helpers
  `issue_dir` (line 68), `progress_md_path` (line 78), `qa_predicate_path`
  (line 89), `_validate_pass_criterion` (line 111). All four are
  sourced-from-everywhere library functions. The merge helper sits in
  the same family. Exported via the line 901 `export -f` list so any
  sourcing script (run-stage.sh, verify-qa.sh) sees it.
* New `bin/merge-envelope.sh` script. Rejected — adds a new top-level
  executable for a function that has exactly two callers (post-dispatch
  qa-payload merge; in-dispatch qa-predicate merge via verify-qa.sh).
  CLAUDE.md ticket sizing rubric: "Don't add features beyond what the
  task requires." A new script also forces tests via a separate
  `bin/merge-envelope-test.sh`; with common.sh placement, the helper's
  test sits naturally inside `bin/common-test.sh` next to the other
  common-helper tests.
* Inline in `bin/run-stage.sh`. Rejected — the plan/review children will
  reuse the helper; embedding it in run-stage.sh forces them to source
  run-stage.sh (which is an executable with main(), not a library).
  Also: verify-qa.sh consumes it for the in-dispatch predicate merge
  (D-004) and cannot reasonably source run-stage.sh.

**Reference to constraint.** Language idioms (Project profile addendum):
"Use `log` / `die` / `require_env` / `require_bin` from common.sh; don't
roll your own." common.sh is the canonical place for cross-script library
functions.

### D-003. AGENT_PROMPTS.md §6 (qa) — strip envelope keys from both `verdict-qa.json` step (current §6 step 9) and the qa-predicate step (current §6 step 1). Add new prompt resolver tokens for the body paths.

**Rationale.** Two specific edits to `AGENT_PROMPTS.md`'s §6 qa block:

1. **§6 step 9 (verdict-qa.json — `AGENT_PROMPTS.md:2038-2073`).** Current
   prompt instructs the agent to write `qa_payload_schema_version` (1),
   `issue_id` ("{issue_id}"), and `dispatch_id` ("{dispatch_id}") into
   `verdict-qa.json`. New prompt instructs the agent to write a body-only
   document at the new `{qa_payload_body_path}` token, containing ONLY
   `verdict` and `dimensions[]`. The current required-fields table loses
   three rows; the file path token changes from `$(issue_dir
   {issue_id})/verdict-qa.json` to `{qa_payload_body_path}`. The text
   "The orchestrator merges the schema envelope (`qa_payload_schema_version`,
   `issue_id`, `dispatch_id`) onto your body before validation; do not
   emit those keys yourself" replaces the current envelope-self-author
   instruction.

2. **§6 step 1 (qa-predicate — `AGENT_PROMPTS.md:1932-1954`).** Current
   prompt instructs the agent to write a JSON document at
   `{qa_predicate_path}` with `qa_predicate_schema_version` (1),
   `issue_id`, and `pass_criteria[]`. New prompt instructs the agent to
   write a body-only document at the new `{qa_predicate_body_path}`
   token, containing ONLY `pass_criteria[]`. The agent's subsequent
   validation call changes from `bash bin/verify-qa.sh validate
   {qa_predicate_path} --ident {issue_id}` to `bash bin/verify-qa.sh
   validate --body {qa_predicate_body_path} --ident {issue_id}` — the
   new `--body` flag is documented in D-004.

**New tokens.** Two new resolvers added to `bin/render-prompt.sh::PROMPT_RESOLVERS`
(line 40-63):

* `qa_payload_body_path=_resolve_qa_payload_body_path`
* `qa_predicate_body_path=_resolve_qa_predicate_body_path`

Each resolver returns a string from common.sh helpers (mirroring
`qa_predicate_path` at line 60 ↔ `qa_predicate_path` helper at common.sh:89):

* New helper `qa_payload_body_path <ident>` → `$(issue_dir
  "$ident")/verdict-qa.body.json`.
* New helper `qa_predicate_body_path <ident>` → `$(issue_dir
  "$ident")/qa-predicate-<ident>.body.json`.

Both helpers exported via common.sh's line 901 `export -f` list.

**Reference to constraint.** CLAUDE.md "Stage summary file —
overwrite-on-every-dispatch contract (ENG-77/ENG-71)": "any stage-summary
file going unwritten on a re-dispatch is a structural staleness hazard."
Same shape applies to the body sidecars. The agent writes via `Write`
(not `Edit`) → overwrite-on-every-dispatch is automatic.

**Reference to constraint.** Anti-prompt-drift: a test in
`bin/agent-prompts-content-test.sh` (already exists; pattern at line
1040 for unrelated ENG-191 literal) asserts §6 step 9 does NOT contain
the strings `qa_payload_schema_version` or `dispatch_id` in the agent
content-shape doc. AC#1 of the ticket pins this test.

### D-004. `verify-qa.sh validate` gains an optional `--body <body-path>` flag. When passed, the validator merges envelope from `<body-path>` to the canonical predicate path (via the shared helper) before running its existing schema + execution validation.

**Rationale.** The qa-predicate is unlike the qa payload in one critical
respect: **the agent invokes `verify-qa.sh validate` in-dispatch** (current
prompt step §6 step 1, line 1954). The agent reads the JSONL summary to
decide between Decision-path B (genuine failure) and Decision-path C/A (no
genuine failure). If the predicate's envelope merge moves post-dispatch
only, the agent's in-dispatch validation call sees a body-only document
with no `qa_predicate_schema_version` and rejects it. Either the agent
hand-loops on the error (wastes a dispatch) or we move predicate validation
post-dispatch (loses the in-dispatch decision signal).

The cleanest fix: extend `verify-qa.sh validate` to accept `--body
<body-path>`. When present, the validator:

1. Resolves the canonical predicate path via `qa_predicate_path "$ident"`
   (common.sh:89) — it already needs `--ident` so this is no new param.
2. Constructs envelope JSON: `{"qa_predicate_schema_version": 1,
   "issue_id": "$ident"}`. Note: predicate envelope has only TWO keys,
   not three (predicate schema at `bin/verify-qa.sh:42-51` defines no
   `dispatch_id` field — verified directly).
3. Calls `merge_artifact_envelope "$body" "$env_json" "$canonical"`.
4. Continues with the existing validation against `$canonical` (no other
   code-path change).

When `--body` is OMITTED, verify-qa.sh behaviour is unchanged (back-compat
for any out-of-band invocation; not used by the qa prompt post-ENG-203 but
guards against ENG-202's review children inadvertently regressing the
flag).

**Reference to constraint.** `bin/verify-qa.sh:14-22` "--worktree fence":
"Bypassing the fence would let a malicious predicate pivot `file_exists`
/ `grep` authority into arbitrary filesystem regions." The body sidecar
must respect the same authority rule.

**Mandatory `--body` realpath fence** (security persona Iter-1 P1).
Before calling `merge_artifact_envelope`, `cmd_validate` MUST apply the
existing `$PROJECT_STATE_DIR` realpath fence (mirroring
`bin/verify-qa.sh:140-159`) to `$ARG_BODY`. Step 0 of the integration
sketch in §3.4:

```bash
# Step 0 — body authority fence (mirrors lines 140-159 fence on $ARG_FILE).
local body_real
body_real="$(cd "$(dirname "$ARG_BODY")" 2>/dev/null && pwd -P)/$(basename "$ARG_BODY")"
case "$body_real" in
  "$PROJECT_STATE_DIR"/*) ;;  # OK — inside per-project state
  *)
    printf 'verify-qa: --body must resolve under $PROJECT_STATE_DIR; got %s\n' "$body_real" >&2
    return 42  # qa-predicate-malformed
    ;;
esac
[[ -L "$ARG_BODY" ]] && {
  printf 'verify-qa: --body must not be a symlink: %s\n' "$ARG_BODY" >&2
  return 42
}
```

Without the fence the agent could pass `--body /etc/passwd` (or `--body
/tmp/poisoned.body.json`) and have the contents merged authoritatively
into the canonical under `$PROJECT_STATE_DIR/<ident>/qa-predicate-
<ident>.json`. The body's *content* is then merged through `jq` (no
shell expansion); the fence applies to the file-path argv only.

**Caller-side rc remap** (coherence persona Iter-1 P1). The remap from
the helper's qa-payload range (39/41/42/50) to verify-qa.sh's qa-
predicate range (42/43/44) lives in `verify-qa.sh::cmd_validate`
immediately after the merge call, before the existing validation block.
Mapping: helper rc=39 → 42 (qa-predicate-malformed), helper rc=41 → 44
(qa-predicate-missing), helper rc=42 → 42 (envelope-not-object, caller
bug — cannot fire by D-006), helper rc=50 → 42 (write failure). This
mirrors D-006's caller-side remap discipline on the qa-payload side and
keeps both consumers within their documented taxonomy ranges.

**OQ-6 (design persona Iter-1 P1).** `--body` overloads
`cmd_validate` with a merge responsibility — `verify-qa.sh` stops being
"validate a canonical" and becomes "build-then-validate." Sibling
alternatives considered: (a) a `verify-qa.sh prepare --body ...; verify-
qa.sh validate ...` two-call shape — rejected because it forces the
agent prompt to chain two commands and recover from a half-failed prepare;
(b) `verify-qa.sh merge-and-validate --body ...` as a separate sub-
command — rejected because it duplicates the existing validate flow's
schema checks. The chosen in-place flag (`--body`) keeps the agent
invocation atomic from the agent's POV (one Bash call → one JSONL
output) and the contract overload is bounded to a single thin code-path
inside `cmd_validate`. Pinned here so future maintainers see the
trade-off; ENG-202's review children may opt for the two-call shape if
their stage's prompt-economy is different.

**Rejected alternative — orchestrator pre-merges before the agent runs.**
Rejected because the merge would have to happen synchronously during the
agent's dispatch but outside the agent's tool-invocation surface — there's
no orchestrator hook between "agent writes body" and "agent runs
verify-qa.sh". The agent runs verify-qa.sh directly via the `Bash(bash
bin/verify-qa.sh:*)` allowlist (Project profile addendum, qa tools);
inserting an orchestrator pre-pass requires a daemon or a per-tool
interceptor. `--body` flag is the trivial in-band fix.

**Rejected alternative — drop the agent's in-dispatch predicate-validation
step entirely; validate post-dispatch only.** Rejected because the agent
uses the JSONL execution output (`pass: false` per criterion at
verify-qa.sh:53-55) to make a verdict decision (path B vs C — line 1954
of AGENT_PROMPTS.md). Moving validation post-dispatch decouples execution
from decision; the agent would emit `verdict pass` and the orchestrator
would then discover a failed criterion AND have no way to feed that signal
back to the agent's decision logic. Foundation-ticket scope precludes
restructuring the agent decision graph.

### D-005. `_clear_current_stage_slots` (`bin/run-stage.sh:949-974`) gains two `rm -f` lines for the qa stage: `verdict-qa.body.json` and `qa-predicate-<ident>.body.json`. The canonical `verdict-qa.json` clear stays; the canonical `qa-predicate-<ident>.json` is NEWLY cleared (today the function leaves it alone).

**Rationale.** Per the ENG-87 cross-dispatch staleness contract (CLAUDE.md):
"clear-on-dispatch-start for per-issue files." The body sidecars are new
per-issue files in the same family as `verdict-qa.json`,
`stage-summary-qa.md`, `wait-qa.json`. They need the same primitive — or
a prior dispatch's stale body would leak into the next dispatch's merge
(yielding a "merge succeeded" canonical built on yesterday's grading).

Current `_clear_current_stage_slots` lines 970-972:

```bash
if [[ "$stage" == "qa" ]]; then
  rm -f "$d/verdict-qa.json" 2>/dev/null || true
fi
```

Becomes:

```bash
if [[ "$stage" == "qa" ]]; then
  rm -f "$d/verdict-qa.json"                       2>/dev/null || true
  rm -f "$d/verdict-qa.body.json"                  2>/dev/null || true
  rm -f "$d/qa-predicate-${ident}.json"            2>/dev/null || true
  rm -f "$d/qa-predicate-${ident}.body.json"       2>/dev/null || true
fi
```

**Why also clear `qa-predicate-<ident>.json`** (the canonical) on qa-stage
dispatch start? Today the agent writes the canonical predicate directly
and the file is overwritten in-dispatch — no clear needed because the
write is unconditional. **This is a NEW behavior** (pre-ENG-203 the
file was never cleared; scope persona Iter-1 P1) and it is a
load-bearing consequence of the merge mechanism, not an opportunistic
cleanup: post-ENG-203 the canonical predicate is written by
`merge_artifact_envelope` via verify-qa.sh `--body`. If the agent
forgets to invoke verify-qa.sh on a re-dispatch (D-004's `--body` path
is agent-driven), a stale canonical from a prior dispatch could survive.
The clear is the per-medium primitive that closes the window.

**Reference to constraint.** CLAUDE.md "Cross-dispatch staleness contract":
"Per-medium primitives: clear-on-dispatch-start for per-issue files
(current-stage only; OTHER stages preserved for loopback)." This decision
strictly honors the stage gating — only the qa-stage branch grows.

**Edge case — loopback `qa → implementing`.** When the threshold gate
(ENG-118) loops qa back to implementing, the next implementing-stage
dispatch runs `_clear_current_stage_slots "$ident" "implementing"` which
does NOT touch qa files (per the existing stage-gating). The qa body and
canonical survive the loopback. When qa re-dispatches after implement
completes, the qa-stage clear fires fresh. No staleness regression.

### D-006. Sequencing in `run-stage.sh::main` post-dispatch block: insert `_merge_qa_payload_envelope` as a NEW step BEFORE `_validate_qa_payload`. Order: clear-on-start → dispatch → `_merge_qa_payload_envelope` → `_validate_qa_payload` → `_validate_qa_thresholds` → completion + verdict_handler.

**Rationale.** The merge must run before the validator (else validator
sees the body-only document and halts with `qa-payload-incomplete:
missing required field qa_payload_schema_version` — the original
ENG-118 symptom). The new helper:

```bash
_merge_qa_payload_envelope() {
  local ident="$1"
  local d; d="$(issue_dir "$ident")"
  local body="$d/verdict-qa.body.json"
  local canonical="$d/verdict-qa.json"
  local env_json
  env_json="$(jq -nc --arg ii "$ident" --arg di "${PIPELINE_DISPATCH_ID:-}" \
    '{qa_payload_schema_version: 1, issue_id: $ii, dispatch_id: $di}')"
  local rc=0
  merge_artifact_envelope "$body" "$env_json" "$canonical" || rc=$?
  if (( rc != 0 )); then
    _post_qa_payload_halt "$ident" \
      "$(failure_outcome_for_exit "$rc")" \
      "merge_artifact_envelope failed (rc=$rc) for body=$body"
    return "$rc"
  fi
  return 0
}
```

Caller wires it into the post-dispatch sequence at
`bin/run-stage.sh:2985-2997`:

```bash
if (( ! skip_dispatch )); then
  case "$stage" in
    qa)
      local _qa_merge_rc=0
      _merge_qa_payload_envelope "$ident" || _qa_merge_rc=$?
      if (( _qa_merge_rc != 0 )); then
        classify_failure "$ident" "$stage" "skip-until-human-acts" \
          "qa-payload-invalid: $(failure_outcome_for_exit "$_qa_merge_rc")" "$_qa_merge_rc"
        exit "$_qa_merge_rc"
      fi
      local _qa_payload_rc=0
      _validate_qa_payload "$ident" || _qa_payload_rc=$?
      ...  # existing block unchanged
      ;;
  esac
fi
```

**Why exit immediately on merge failure** instead of letting
`_validate_qa_payload` halt? The validator's diagnostic ("missing required
field") is wrong if the cause is "body file missing" or "body file
malformed." A clean halt at the merge step gives the operator the
accurate cause ("verdict-qa.body.json missing"). This is also why the
helper returns codes from the qa-payload taxonomy (39/41/42/50) — the
caller can map them through the EXISTING `_post_qa_payload_halt`
(`bin/run-stage.sh:2097-2105`) without inventing new halt-comment shapes.

**Reference to constraint.** CLAUDE.md "Pipeline vocabulary": no new
event-registry entries required — merge failure halts via the existing
`qa-payload-invalid` halt reason (already in `bin/pipeline-events.json`'s
`halt_reasons` per the post-ENG-117 surface). The closed-vocabulary
guarantee holds.

**Reference to constraint.** CLAUDE.md "When wiring a new script": "For
exit codes, use the `failure_outcome_for_exit` taxonomy (common.sh) —
unmapped codes route to `unknown-exit-N`." Codes 39/41 are already
mapped to `qa-payload-malformed` / `qa-payload-missing`
(`bin/common.sh:732,734`). Code 42 is `qa-predicate-malformed`
(`bin/common.sh:735`) — slightly weird for the qa-payload caller (it'd
classify "envelope JSON is not an object" as `qa-predicate-malformed`).
**Refinement:** the helper's rc=42 "envelope-not-object" is a CALLER
BUG, not a content failure — orchestrator constructs the envelope from
trusted inputs and a static jq expression. It cannot fire in practice.
The helper still returns rc=42 for defensive correctness, but the qa
caller can collapse `(39|42)` → "qa-payload-malformed" in
classify-failure's reason string (one-line tweak). Code 50 is
`review-ledger-missing` (`bin/common.sh:743`) which is also a mis-map;
the caller similarly collapses → "qa-payload-malformed" with a "write
failed" detail. **Trade-off:** rc=50 collision is cosmetic — the halt
comment names the actual problem. Adding a new "merge-internal-write"
code is more invasive than the cosmetic mis-map; defer to ENG-202 if it
recurs across plan/review children.

### D-007. Body file size cap = 64 KiB. Symlink rejected. Top-level must be a JSON object.

**Rationale.** Mirrors verify-qa.sh's existing predicate-file hardening
(line 30: "file size > 64 KiB"; line 142: "predicate file must not be a
symlink") — the same threat surface applies to the body sidecar
(agent-authored file with structural input role; could be a TOCTOU pivot
or a DoS vector if unbounded). The cap is generous: a real qa-payload body
with six dimensions runs ~1 KiB; six pass_criteria entries with rich
diagnostics run ~3 KiB. 64 KiB is two orders of magnitude of safety
margin.

Top-level-must-be-object: jq's `.foo` indexing on an array returns null,
which the validator would treat as missing — silent corruption. Explicit
object check at the helper boundary gives a clean error.

**Reference to constraint.** CLAUDE.md "Be careful not to introduce
security vulnerabilities such as command injection, XSS, SQL injection,
and other OWASP top 10 vulnerabilities." The body is *content* (JSON
data), but the path-class check (symlink rejection) defends against the
agent pivoting a write into a sensitive file via symlink.

### D-008. No backward-compat shim for "old-style canonical without body sidecar." Body file is required.

**Rationale.** Two questions: (a) what happens if an in-flight agent
authored under the pre-ENG-203 prompt writes the canonical directly and
no body sidecar exists? (b) Do we accept legacy direct-write to avoid a
cutover gap?

(a) Today's agent prompt is RENDERED FRESH every dispatch by
`bin/render-prompt.sh`. The moment ENG-203 ships, every new dispatch's
rendered prompt instructs the agent to write the body — there is no
in-flight scenario where an agent renders the old prompt and produces
the old shape. The cutover is atomic per-dispatch.

(b) Accepting "canonical without body" as a fallback would silently
re-introduce the slip surface. The agent could land a malformed
canonical and the merge would no-op, the validator would halt on the
agent's bad envelope. We'd be back to the ENG-118 failure. Reject.

**Implementation.** When the body file is missing post-dispatch, halt
with `qa-payload-invalid: qa-payload-missing` (rc=41). Halt body says
"verdict-qa.body.json missing — agent did not write the body file. The
orchestrator-merge contract requires body-only output; see
`docs/runbooks/recovery.md` §15."

**Reference to constraint.** CLAUDE.md "Don't add backwards-compatibility
shims when you can just change the code." Prompts are re-rendered every
dispatch; no in-flight agents survive a prompt change.

**In-progress dispatch at deploy time** (product persona Iter-1 P2). A
dispatch already in flight when the operator deploys ENG-203 (agent
started under the old prompt, orchestrator code rolled to the new
binary) will land an old-shape canonical with no body sidecar, and the
new orchestrator's `_merge_qa_payload_envelope` halts with
`qa-payload-invalid: qa-payload-missing` ("verdict-qa.body.json
missing"). Recovery is the standard `bash bin/pipeline.sh decide
<ENG-N> --action continue` — clears halt label, re-dispatches under the
new prompt, agent writes body. This is the ONLY legitimate operator-
visible cutover artifact, bounded to one issue (the one currently in
qa). The post-ENG-203 `docs/runbooks/recovery.md` §15 entry names
this case explicitly.

### D-009. Test surface: one unit test for the helper in `bin/common-test.sh`; orchestration tests in `bin/run-stage-test.sh`; prompt-content assertion in `bin/agent-prompts-content-test.sh`.

**Rationale.** AC#3 of the ticket pins "a reusable envelope-merge helper
exists and is unit-tested independently of the qa stage." The right place
for that test is the existing `bin/common-test.sh` (which already covers
`issue_dir`, `progress_md_path`, `qa_predicate_path`,
`_validate_pass_criterion`) — same family. Cases:

* **U-1 body present + envelope simple → merged canonical valid.** Body is
  `{"verdict":"pass","dimensions":[]}`, envelope is
  `{"qa_payload_schema_version":1,"issue_id":"ENG-1","dispatch_id":"ENG-1-d0001"}`.
  Assert canonical contains all five keys with envelope's values.
* **U-2 collision: body has `issue_id: "ENG-99"`, envelope says "ENG-1".**
  Assert canonical has `issue_id: "ENG-1"` (envelope wins).
* **U-3 body missing.** Assert rc=41.
* **U-4 body not JSON object (array).** Assert rc=39.
* **U-5 body parse error.** Assert rc=39.
* **U-6 body is symlink.** Assert rc=42.
* **U-7 body > 64 KiB.** Assert rc=39.
* **U-8 envelope not an object (caller-bug).** Assert rc=42.
* **U-9 canonical write target unwritable** (chmod 0500 the parent dir).
  Assert rc=50.

Orchestration tests in `bin/run-stage-test.sh`:

* **OS-1 ENG-118 regression: body has only verdict+dimensions, no
  envelope keys; merge succeeds; `_validate_qa_payload` passes.** Pins
  AC#4.
* **OS-2 body missing post-dispatch → halt rc=41, classify_failure
  fires with reason `qa-payload-invalid: qa-payload-missing`.**
* **OS-3 body parse error → halt rc=39.**
* **OS-4 stale body from prior dispatch is cleared by
  `_clear_current_stage_slots` at qa-stage dispatch start; assert BOTH
  `verdict-qa.body.json` AND canonical `verdict-qa.json` are absent
  post-clear (and same for `qa-predicate-*.body.json` + canonical
  `qa-predicate-<ident>.json`).** Pins D-005.
* **OS-5 in-dispatch verify-qa.sh `--body` flag merges and validates
  predicate.** Pins D-004.

Prompt-content tests in `bin/agent-prompts-content-test.sh`:

* **AP-1 §6 step 9 does NOT contain the literal string
  `qa_payload_schema_version` in the agent content-shape doc.** Pins AC#1.
* **AP-2 §6 step 9 does NOT contain `dispatch_id` as a content-shape
  required field.**
* **AP-3 §6 step 9 contains the literal `{qa_payload_body_path}` token.**
* **AP-4 §6 step 1 does NOT contain `qa_predicate_schema_version` in the
  agent content-shape doc.**
* **AP-5 §6 step 1 contains the literal `{qa_predicate_body_path}` token.**
* **AP-6 §6 step 1's verify-qa.sh call uses `--body`.**
* **AP-7 (product persona Iter-1 P1) §6 step 1's invocation example
  contains the EXACT literal `bash bin/verify-qa.sh validate --body
  {qa_predicate_body_path} --ident {issue_id}` (or its `.pipeline/`
  prefix sibling) — pinning the flag-positional shape so an agent that
  copy-pastes the example cannot drift into a no-`--body` form.**

The §6 prompt may still MENTION the envelope keys in the "the orchestrator
merges {schema_version, issue_id, dispatch_id} before validation" sentence
— that's allowed. AP-1/AP-2/AP-4 narrow their assertion to the "required
fields the agent must emit" doc (not the prose), via a section locator.
The exact locator shape mirrors existing tests in
`bin/agent-prompts-content-test.sh` (pattern at line 1040+).

**Reference to constraint.** AC#3: "unit-tested independently of the qa
stage." common-test.sh is the right place because it's the cross-script
library test surface; the helper has no qa-specific dependency.

## 3. Architecture

### 3.1 Files touched

| Path | Change | Lines |
|---|---|---|
| `bin/common.sh` | Add `qa_payload_body_path <ident>` helper, `qa_predicate_body_path <ident>` helper, and `merge_artifact_envelope <body> <env-json> <canonical>` helper. Export all three via the existing `export -f` list (line 901). | ~70 added |
| `bin/run-stage.sh` | Add `_merge_qa_payload_envelope <ident>` function (sibling of `_validate_qa_payload`). Insert the merge call in the post-dispatch sequence (line 2985 region) BEFORE `_validate_qa_payload`. Extend `_clear_current_stage_slots` qa branch with two new `rm -f` lines (D-005). | ~50 added |
| `bin/verify-qa.sh` | Add `--body <body-path>` flag to `_parse_validate_argv` (line 82 region). When present, compute envelope JSON `{qa_predicate_schema_version: 1, issue_id: $ident}` and call `merge_artifact_envelope $body $env "$canonical"` BEFORE the existing validation block. Reuse `qa_predicate_path "$ident"` from common.sh for the canonical path. | ~40 added |
| `bin/render-prompt.sh` | Add two entries to `PROMPT_RESOLVERS` (line 40-63): `qa_payload_body_path=_resolve_qa_payload_body_path` and `qa_predicate_body_path=_resolve_qa_predicate_body_path`. Add the two `_resolve_*` body functions (mirror the `_resolve_qa_predicate_path` shape at line 283). Bind `_RENDER_QA_PAYLOAD_BODY_PATH` and `_RENDER_QA_PREDICATE_BODY_PATH` in main() the same way the existing `_RENDER_QA_PREDICATE_PATH` is bound. | ~20 added |
| `AGENT_PROMPTS.md` (§6 qa) | Edit step 1 — replace the document-shape required fields list (`qa_predicate_schema_version`, `issue_id`, `pass_criteria`) with `pass_criteria` only; change the write path token from `{qa_predicate_path}` to `{qa_predicate_body_path}`; change the verify-qa.sh call from `validate {qa_predicate_path} --ident {issue_id}` to `validate --body {qa_predicate_body_path} --ident {issue_id}`; add the explanatory sentence "the orchestrator merges schema envelope keys before validation." Edit step 9 — replace the required fields list (`qa_payload_schema_version`, `issue_id`, `dispatch_id`, `verdict`, `dimensions[]`) with `verdict`, `dimensions[]`; change the write path from `$(issue_dir {issue_id})/verdict-qa.json` to `{qa_payload_body_path}`; add the same merge-explanatory sentence. | ~15 changed |
| `bin/common-test.sh` | Add unit cases U-1 through U-9 (D-009) for `merge_artifact_envelope`. | ~120 added |
| `bin/run-stage-test.sh` | Add orchestration cases OS-1 through OS-5 (D-009). | ~150 added |
| `bin/agent-prompts-content-test.sh` | Add AP-1 through AP-6 (D-009). | ~50 added |
| `bin/qa-payload-schema.sh` | NO change. Schema validator runs on the merged canonical, unchanged. | 0 |
| `bin/pipeline-events.json` | Add `envelope-overwrite` to the `metric_names` array (OQ-4 promotion). Closed-vocabulary token; passes the existing validator at `bin/pipeline.sh::_validate_event_payload`. | ~2 added |
| `bin/vocabulary-cleanliness-test.sh` | Add pin: `envelope-overwrite in metric_names registry`. | ~10 added |
| `bin/verify-qa-test.sh` | Add cases for the new `--body` flag: body-present-and-valid → merge + validate succeeds; body-missing + `--body` passed → rc=44 (qa-predicate-missing — body file IS the predicate now). | ~60 added |
| `docs/runbooks/recovery.md` | Add §15 "qa-payload merge failure" with recovery recipe (the halt body's "see §15" pointer). | ~25 added |
| `CLAUDE.md` "Failure-mode quick reference" table | Add row for `qa-payload-invalid: qa-payload-missing` with merge-failure root cause and §15 recovery pointer. | ~3 added |
| `bin/common.sh::failure_outcome_for_exit` | NO change. Codes 39/41 already mapped; codes 42/50 are existing but cosmetically mis-mapped for this caller (D-006). | 0 |
| `bin/verdict-handler.sh` | NO change. | 0 |

### 3.2 Subsystems touched (rubric check)

Per CLAUDE.md "Ticket sizing rubric":

* **dispatch** — `bin/common.sh` (helpers), `bin/render-prompt.sh` (tokens).
* **orchestrator** — `bin/run-stage.sh` (merge call, clear extension),
  `bin/verify-qa.sh` (`--body` flag).
* **agent prompts** — `AGENT_PROMPTS.md` §6 step 1 + step 9 (the two
  required-field edits) — clearly subordinate to the orchestrator change
  per the ticket: "agent-prompts (§6 qa) subordinate."
* **tests/fixtures** — `bin/common-test.sh`, `bin/run-stage-test.sh`,
  `bin/agent-prompts-content-test.sh`, `bin/verify-qa-test.sh`.

**Ticket sizing says: 2 subsystems** (dispatch/orchestrator primary,
agent-prompts subordinate). This brainstorm sees 3 (the verify-qa.sh
`--body` extension sits within orchestrator/dispatch but spans the
in-dispatch surface). **Still within rubric — autonomy-safe** because the
verify-qa.sh edit is mechanically tiny and the agent-prompts edit is the
subordinate boundary the ticket already named.

### 3.3 Per-dispatch data flow (qa payload — verdict-qa.json)

```
qa agent dispatches.
  ↓
agent does grading work.
  ↓
agent writes content-only body via Write tool at
   {qa_payload_body_path} = $(issue_dir ident)/verdict-qa.body.json
   body = { "verdict": "pass", "dimensions": [ {name, score, ...}, ... ] }
  ↓
agent emits `verdict pass --stage qa` via bash bin/pipeline.sh event.
  ↓
agent dispatch exits.
  ↓
run-stage.sh post-dispatch sequence (qa stage):
  ↓
_merge_qa_payload_envelope ident       (NEW, ENG-203)
  ↓
  Step 1: env_json = jq -nc { qa_payload_schema_version: 1,
                              issue_id: $ident,
                              dispatch_id: $PIPELINE_DISPATCH_ID }
  ↓
  Step 2: merge_artifact_envelope $body $env_json $canonical
            body=$(issue_dir ident)/verdict-qa.body.json
            canonical=$(issue_dir ident)/verdict-qa.json
  ↓
  Step 3: rc=0 → return 0.
          rc=39 → _post_qa_payload_halt + classify_failure + exit 39.
          rc=41 → _post_qa_payload_halt + classify_failure + exit 41.
          rc=42/50 → _post_qa_payload_halt + classify_failure + exit (code).
  ↓
_validate_qa_payload ident             (existing, ENG-117, unchanged)
  → runs qa-payload-schema.sh validate on canonical
  → canonical now has the orchestrator-injected envelope keys,
    schema-v1 validation passes.
  ↓
_validate_qa_thresholds ident           (existing, ENG-118, unchanged)
  → reads .qa.thresholds + dimensions[]; coerces if any below floor.
  ↓
push_branch_if_ahead + post_completion_comment + verdict_handler.
```

### 3.4 In-dispatch data flow (qa predicate — qa-predicate-<ident>.json)

```
qa agent dispatches.
  ↓
agent reads embedded plan.json (between PLAN_JSON_BEGIN / _END markers).
  ↓
agent writes content-only body via Write tool at
   {qa_predicate_body_path} = $(issue_dir ident)/qa-predicate-<ident>.body.json
   body = { "pass_criteria": [ {kind: "smoke", command, expect_exit, ...}, ... ] }
  ↓
agent runs: bash bin/verify-qa.sh validate
              --body {qa_predicate_body_path}
              --ident {issue_id}
  ↓
verify-qa.sh::cmd_validate (with --body):
  ↓
  Step 1: parse argv — capture ARG_BODY in addition to existing args.
  ↓
  Step 2: env_json = { qa_predicate_schema_version: 1, issue_id: $ARG_IDENT }
          canonical = qa_predicate_path $ARG_IDENT
                    = $(issue_dir ARG_IDENT)/qa-predicate-<ARG_IDENT>.json
  ↓
  Step 3: merge_artifact_envelope $ARG_BODY $env_json $canonical
          (exits with same diagnostics + rc as helper on failure;
           caller-side mapping turns rc=39→42, rc=41→44 to fit
           verify-qa's qa-predicate-* taxonomy — D-006-style remap.)
  ↓
  Step 4: continue with existing validation: parse-validate-argv body
          set to $canonical; rest of cmd_validate executes against
          merged canonical.
  ↓
verify-qa.sh emits JSONL per-criterion outcomes + summary on stdout.
  ↓
agent reads summary line; decides verdict path B / C / D per §6.
  ↓
agent emits verdict and exits.
  ↓
(NO orchestrator post-dispatch predicate-merge step — the merge already
 happened in-dispatch via verify-qa.sh's --body code path.)
```

## 4. Data Flow

### 4.1 Envelope construction (qa payload)

```bash
local env_json
env_json="$(jq -nc \
  --arg ii "$ident" \
  --arg di "${PIPELINE_DISPATCH_ID:-}" \
  '{qa_payload_schema_version: 1, issue_id: $ii, dispatch_id: $di}')"
```

* `qa_payload_schema_version`: hardcoded `1` — schema-v1 is the only
  supported version (`bin/qa-payload-schema.sh:119-122` rejects anything
  else). When schema-v2 lands (future), this constant moves to a
  helper-level argument.
* `issue_id`: `$ident` — already validated by `run-stage.sh::main` against
  `^ENG-[0-9]+$` before dispatch begins (this is the ENG-87 invariant —
  any caller upstream guarantees the format).
* `dispatch_id`: `$PIPELINE_DISPATCH_ID` — allocated by
  `allocate_dispatch_id` at `bin/run-stage.sh:2353`; format
  `^ENG-[0-9]+-d[0-9]+$` is guaranteed by the allocator.

If `$PIPELINE_DISPATCH_ID` is empty (sub-case: scope-approval replay
path that doesn't re-allocate — `bin/run-stage.sh:2350` gates the
allocation on `! skip_dispatch`), the envelope's `dispatch_id` field is
the empty string, and `qa-payload-schema.sh:147-148` will reject it with
`dispatch_id must be a non-empty string`. **This is correct behavior**:
the merge-and-halt path makes the missing dispatch-id surface explicit.
A scope-approval replay should not be hitting the qa-payload merge path
in the first place; if it is, the failure is a real invariant break,
not silent.

### 4.2 Envelope construction (qa predicate, verify-qa.sh side)

```bash
local env_json
env_json="$(jq -nc --arg ii "$ARG_IDENT" \
  '{qa_predicate_schema_version: 1, issue_id: $ii}')"
```

Note: TWO keys, not three. The qa-predicate schema (verify-qa.sh:42-51,
verified directly) has no `dispatch_id` field. The predicate's lifetime
is bounded to the in-dispatch validation; it doesn't need a cross-dispatch
freshness check because verify-qa.sh's authority-fence
(`bin/verify-qa.sh:140-159`) already confines the file to the issue's
state dir, and `_clear_current_stage_slots` (post-ENG-203 D-005) clears
both body and canonical predicate at qa-stage dispatch start.

### 4.3 Atomic write

```bash
local tmp="${canonical}.tmp.$$"
jq -n --slurpfile b "$body" --argjson env "$env_json" '$b[0] + $env' > "$tmp" \
  || { rm -f "$tmp"; return 50; }
mv "$tmp" "$canonical" || { rm -f "$tmp"; return 50; }
```

The `.tmp.$$` suffix uses the current shell PID to disambiguate
concurrent calls. Concurrent merges on the same issue ARE possible if
two ticks somehow both reach the post-dispatch block (shouldn't happen
under the per-issue in-flight lock `bin/common.sh::try_acquire_lock`,
but defense-in-depth). `mv` on same-FS is atomic (POSIX rename); body
and canonical share `issue_dir` so the rename is always intra-FS.

### 4.4 Idempotency on resume

`bash bin/pipeline.sh decide ENG-N --action continue` clears
`pipeline:halted` and re-allocates a fresh `PIPELINE_DISPATCH_ID`. Next
tick:

* `_clear_current_stage_slots` clears body AND canonical
  (per-D-005).
* Agent re-runs from scratch, writes a fresh body.
* Orchestrator merges with the NEW `dispatch_id`. Canonical has the
  new id.
* `_validate_qa_payload`'s `--dispatch-id "${PIPELINE_DISPATCH_ID-}"`
  flag (`bin/run-stage.sh:2083`) cross-checks that the merged
  `dispatch_id` matches the live env var — pass.

No staleness regression; the ENG-87 freshness contract holds end-to-end.

## 5. Error Handling

### 5.1 Exit codes (merge helper)

| rc | Meaning | Caller maps to | Halt reason |
|---|---|---|---|
| 0  | Merge succeeded; canonical written. | (continue) | — |
| 39 | Body parse error / not object / size out of range. | qa-payload-malformed | `qa-payload-invalid` |
| 41 | Body file missing. | qa-payload-missing | `qa-payload-invalid` |
| 42 | Envelope JSON is not an object (caller bug; cannot fire in practice). | qa-payload-malformed (cosmetic mis-map per D-006) | `qa-payload-invalid` |
| 50 | Write failed (jq or mv). | qa-payload-malformed (cosmetic mis-map) | `qa-payload-invalid` |

All non-zero rc routes the qa caller to `_post_qa_payload_halt` (existing,
`bin/run-stage.sh:2097-2105`). The halt body carries the helper's stderr
output verbatim (sanitised `<!--` → `<\!--`) so the operator sees the
true root cause ("body missing", "parse error at byte N", etc.).

### 5.2 Linear post failures

`_post_qa_payload_halt` posts via `bin/linear.sh add-comment ... || true`
(line 2104). Pre-ENG-203 behavior unchanged — a Linear outage during the
merge-failure halt produces a "true" return and the dispatch exits with
the merge code anyway. classify_failure then routes to global breaker
via `bin/run-stage.sh:2991-2993` (the existing pattern).

### 5.3 Concurrent body writes (agent self-retry within one dispatch)

The agent's prompt instructs `Write` (overwrite-on-every-dispatch
contract — D-003). Multiple Write calls in one dispatch overwrite the
body file. The orchestrator's merge runs after the dispatch exits — it
reads whatever body the agent's LAST write produced. Idempotent.

### 5.4 Helper exposure

The helper is exported via `export -f merge_artifact_envelope` (added to
`bin/common.sh:901`). All sourcing scripts (run-stage.sh, verify-qa.sh,
common-test.sh) see it. Per `bin/common.sh:901` convention, the export
list is the canonical lane discipline — functions not on the list are
not part of the cross-script contract.

## 6. Edge Cases

* **Body is empty file (0 bytes).** D-007's size-cap check (`sz > 0`)
  catches it → rc=39 (treated as parse error). Halt with "body size out
  of range." Avoids ambiguity with "body present but missing keys."
* **Body has the same envelope keys but with WRONG values** (agent
  wrote `qa_payload_schema_version: "v1"` and `dispatch_id:
  "ENG-1-d0099"` when current dispatch is d0001). Orchestrator's
  envelope WINS (jq `$b[0] + $env` is right-biased). Canonical has the
  correct envelope. The agent's mis-emitted fields are silently
  overwritten. **No operator-visible signal** — the slip is repaired
  invisibly. Acceptable per D-008's "envelope is authoritative"
  posture. ENG-39's calibration substrate could surface "agent
  emitted vs orchestrator emitted" disagreement as a future signal;
  out-of-scope here.
* **Body has unknown content keys** (agent emits
  `dimensions[].extra_note`). `qa-payload-schema.sh:236-241` already
  handles unknown per-dimension fields: warning to stderr + rc=0
  (D-005 permissive). Helper passes through; canonical validation
  warns; no halt. Existing forensic ergonomics preserved.
* **Body has top-level array** `[{"verdict":"pass"}]`. Helper rc=39
  ("body is not a JSON object"). Halt body says so. Clearer than
  validator's "verdict missing."
* **Body is a symlink to /etc/passwd.** Helper rc=42. Halt before
  merging. Mirrors verify-qa.sh's defense.
* **Body and canonical have IDENTICAL inode** (e.g. agent wrote body to
  the canonical path by mistake then symlinked — pathological). Symlink
  rejection catches it.
* **Body contains a key named `qa_payload_schema_version` with value
  `1` (the agent followed the OLD prompt by accident).** Merge succeeds;
  canonical has `qa_payload_schema_version: 1` (envelope value, identical
  to body's value); validator passes. No-op on the operator side.
  Slip-resistant.
* **Two tools fight over `qa-predicate-<ident>.json` on the same
  dispatch.** verify-qa.sh's `--body` flag writes canonical. If the
  agent ALSO writes canonical directly (with no --body, old shape),
  whichever writes last wins. Since post-ENG-203 the prompt instructs
  only the body-write path, the agent has no reason to write canonical
  — and if it does (out-of-band), the next verify-qa.sh `--body` call
  overwrites. No corruption window beyond standard last-writer-wins.
* **`$PIPELINE_DISPATCH_ID` unset during qa post-dispatch.** Envelope's
  `dispatch_id: ""`; validator's `bin/qa-payload-schema.sh:147` rejects
  with rc=40 (`dispatch_id must be a non-empty string`); halt fires
  cleanly. D-005's expected behavior (see §4.1 above).
* **Body is valid but envelope merge produces an object with extra,
  unexpected envelope keys** (e.g. orchestrator code regression adds
  `"foo": "bar"` to env_json). `qa-payload-schema.sh:244-251`'s unknown-
  top-level-key handler warns + rc=0. No halt. Forensic surface only.
* **Disk full during atomic mv.** Helper rc=50. Halt body says "write
  failed." classify_failure routes to retry-immediately-style failure
  outcome; next tick re-dispatches the merge step from a fresh body
  write. (Note: the body sidecar was already cleared, so the agent re-
  dispatch re-writes it. Idempotent.)

## 7. Open Questions

* **OQ-1.** ENG-202 named plan.json / verdict-review.json / review-ledger
  as the next consumers of this helper. Should the helper signature
  pre-emptively accept a "kind" parameter so the plan/review children
  can simply call `merge_artifact_envelope --kind plan ...`? **Tentative
  answer: NO** — the helper is purely structural (read body, merge env,
  write canonical). The "kind" is owned by each caller (run-stage.sh
  knows it's qa-payload; the plan-stage caller will know it's plan).
  Forcing a kind parameter today over-fits to a single design that
  ENG-202 has not finalised. Resolve at ENG-202 design time.
* **OQ-2.** The qa-predicate flow happens IN-DISPATCH via verify-qa.sh
  `--body`; the qa-payload flow happens POST-DISPATCH via orchestrator
  call. This asymmetry is forced by the predicate's in-dispatch
  execution role (D-004). Should plan/review children replicate the
  asymmetry — i.e. is there a future case where a plan/review body
  must be merged in-dispatch? **Tentative answer: NO** — plan.json and
  verdict-review.json are both consumed post-dispatch by validators.
  Their merge sits cleanly post-dispatch. The qa-predicate's
  asymmetry is the exception, not the rule.
* **OQ-3.** Should the body sidecar's `.body.json` suffix be a constant
  in common.sh (`BODY_SUFFIX=.body.json`), so the helper or the path
  resolvers compose `${canonical/.json/.body.json}` programmatically?
  **Tentative answer: defer to ENG-202** — premature DRY for a single
  caller now. Concrete paths in `qa_payload_body_path` and
  `qa_predicate_body_path` are easier to read and lint.
* **OQ-4.** Audit: should the orchestrator log when the agent's body
  contains a key the envelope overwrites (e.g. agent emitted
  `qa_payload_schema_version: "v1"` and orchestrator overwrote it)?
  This would surface "agent regressed on the prompt's content-only
  contract" as a retrospective signal. **Promoted from "defer" to
  in-scope** (design persona + product persona Iter-1 P1): in
  `merge_artifact_envelope`, after the jq merge succeeds, compute the
  overlap of body-keys vs envelope-keys via
  `jq -r '(($b[0] | keys) - ($env | keys) | length), ($b[0] | keys) - ($env | keys) | join(",")'`
  (one-liner). When the overlap count is non-zero, emit a forensic
  metric via `bash bin/metrics.sh event envelope-overwrite "$ident"
  "$stage" count=N keys=<csv>` — no Linear-comment surface, no halt;
  just JSONL data. The retrospective shape (ENG-129) can grep
  `event=envelope-overwrite` rows to flag systematic agent drift. Cost:
  ~3 lines in the helper plus a new entry in
  `bin/pipeline-events.json::metric_names` (one closed-vocabulary
  token). Trade-off accepted: small forensic write per merge in
  exchange for visibility into the silent-repair surface the helper
  introduces. **Pinned in §3.1 as a row in `bin/pipeline-events.json`
  (was: NO change → now: add `envelope-overwrite` token).**
* **OQ-5.** `verify-qa.sh`'s `--body` flag is one more agent-facing
  argv shape. Should we sunset the no-flag form once ENG-203 ships?
  **Tentative answer: NO** — the no-flag form is still useful for
  operator manual triage (e.g. validating a hand-edited canonical
  during recovery per `docs/runbooks/recovery.md` §11). Keep both
  shapes; document `--body` as the dispatch-time shape.

## 8. Anti-bias checks

### 8.1 ADR stress test

* **ENG-87 cross-dispatch staleness contract.** The body sidecar is a
  new per-issue file; D-005 ensures it gets clear-on-dispatch-start —
  the established per-medium primitive. NO pressure on the contract.
* **ENG-77 stage-summary overwrite-on-every-dispatch.** The body file
  is written via `Write` (not `Edit`), so overwrite-on-every-dispatch
  is automatic. NO pressure on the contract.
* **ENG-117 qa-payload schema (D-005 permissive on unknown keys).**
  The merge potentially injects new top-level keys; ENG-117's permissive
  handling absorbs them with a warning. NO pressure.
* **ENG-118 dimensional threshold gate (gate runs on `score` only).**
  The merge does not touch dimensions content. Threshold gate consumes
  the merged canonical's dimensions unchanged. NO pressure.
* **ENG-119 verdict-review.json pre-clean** (`bin/run-stage.sh:957-964`):
  the reviewing-stage clear is stage-gated to reviewing. ENG-203's
  qa-stage body clears do not pollute reviewing. NO pressure.
* **CLAUDE.md "Don't add features beyond what the task requires."**
  The helper's "kind" parameterisation deferred to ENG-202 (OQ-1) is the
  right discipline. Helper accepts only what the qa caller needs today.
  This brainstorm explicitly resists generalising past ENG-202's known
  shape.
* **AGENT_PROMPTS.md fence-count contract** (Project profile addendum
  "Don'ts"): "Never use a column-0 ``` fence inside a stage's body
  in AGENT_PROMPTS.md." D-003's §6 edits do NOT introduce new fences;
  they edit existing text inside the existing fenced block. NO pressure.

### 8.2 Simpler alternatives (recap)

Each major decision documents at least one rejected alternative; recap
table:

| Decision | Rejected alternative | Why rejected |
|---|---|---|
| D-001 | Pre-seed (orchestrator writes envelope; agent Edits) | Edit-anchor fragility; silent failure mode; envelope still mutable by agent |
| D-001 | Validator synthesises envelope at validation time | Blurs validator contract; doesn't generalise |
| D-001 | Strengthen the prompt instead | Live evidence (memory `qa-agent-schema-version-field-slip`) proves prompts don't suffice |
| D-002 | New `bin/merge-envelope.sh` script | Adds a top-level executable for one library function with two callers |
| D-002 | Inline in `bin/run-stage.sh` | Forces plan/review children to source an executable; verify-qa.sh can't source run-stage.sh sensibly |
| D-004 | Orchestrator pre-merges before agent runs verify-qa.sh | No synchronous orchestrator hook between agent Write and agent Bash invocations |
| D-004 | Drop agent's in-dispatch predicate validation | Decouples execution from decision; agent can't signal Decision-path B from post-dispatch context |
| D-008 | Backward-compat shim accepting old direct-canonical writes | Re-introduces the slip surface ENG-203 is closing |

### 8.3 Assumption inventory

Each row marked **verified** (checked directly against the current code)
or **assumed** (will validate during implementation).

| # | Assumption | Status |
|---|---|---|
| A1 | `bin/qa-payload-schema.sh:108-122` enforces `qa_payload_schema_version == 1` and returns rc=40 on absence. | **verified** (read directly: lines 110-122) |
| A2 | `bin/qa-payload-schema.sh:124-140` enforces `issue_id` regex `^ENG-[0-9]+$` and rc=40 on absence/type. | **verified** (lines 124-140) |
| A3 | `bin/qa-payload-schema.sh:142-153` enforces `dispatch_id` regex `^ENG-[0-9]+-d[0-9]+$` and rc=40 on absence/type. | **verified** (lines 142-153) |
| A4 | `bin/qa-payload-schema.sh` returns 39/40/41 (malformed/incomplete/missing); these are mapped to `qa-payload-malformed/incomplete/missing` in `failure_outcome_for_exit`. | **verified** (`bin/common.sh:732-734`) |
| A5 | `bin/verify-qa.sh:42-51` schema header documents the qa-predicate as `{qa_predicate_schema_version, issue_id, pass_criteria[]}` — no `dispatch_id` field. | **verified** (read directly: lines 38-51) |
| A6 | `bin/verify-qa.sh:248-258` enforces `qa_predicate_schema_version == 1`. | **verified** (lines 248-258) |
| A7 | `bin/verify-qa.sh:140-159` requires the predicate file to live under `$PROJECT_STATE_DIR` (authority surface). | **verified** (lines 140-159) |
| A8 | `bin/run-stage.sh::_clear_current_stage_slots` (line 949-974) clears qa-stage files including `verdict-qa.json` but NOT `qa-predicate-<ident>.json`. | **verified** (lines 949-974) |
| A9 | `bin/run-stage.sh::_validate_qa_payload` (line 2073-2092) runs after dispatch and halts on rc 39/40/41 via `_post_qa_payload_halt`. | **verified** (lines 2073-2092) |
| A10 | `bin/run-stage.sh::_validate_qa_thresholds` (line 1783+) runs AFTER `_validate_qa_payload` in the post-dispatch sequence. | **verified** (call site lines 2985-3008) |
| A11 | `bin/common.sh::qa_predicate_path <ident>` returns `$(issue_dir)/qa-predicate-<ident>.json`. | **verified** (lines 89-93) |
| A12 | `bin/common.sh::issue_dir <ident>` returns `$PROJECT_STATE_DIR/<ident>`. | **verified** (lines 68-72) |
| A13 | `bin/common.sh` exports public helpers via line 901 `export -f` list (issue_dir, progress_md_path, qa_predicate_path, _validate_pass_criterion, etc.). | **verified** (line 901) |
| A14 | `bin/render-prompt.sh::PROMPT_RESOLVERS` (line 40-63) is the token registry; resolvers follow the `_RENDER_*` static-bound pattern; main() binds `_RENDER_QA_PREDICATE_PATH` from `qa_predicate_path`. | **verified** (line 40-63 + sample resolver at line 283) |
| A15 | `AGENT_PROMPTS.md:1932-1954` is §6 step 1 (qa-predicate write + verify); `AGENT_PROMPTS.md:2038-2073` is §6 step 9 (verdict-qa.json write). | **verified** (read directly) |
| A16 | `AGENT_PROMPTS.md:1936` instructs the agent to write predicate at `{qa_predicate_path}`; `:1954` instructs validation via `bash bin/verify-qa.sh validate {qa_predicate_path} --ident {issue_id}`. | **verified** (lines 1936, 1954) |
| A17 | `AGENT_PROMPTS.md:2040-2052` documents the verdict-qa.json required-fields list including `qa_payload_schema_version`, `issue_id`, `dispatch_id`. | **verified** (lines 2040-2052) |
| A18 | `bin/common.sh::failure_outcome_for_exit` (697-747) is the taxonomy; codes 39/41 are qa-payload-*; codes 42-44 are qa-predicate-*; rc=50 is review-ledger-missing. | **verified** (lines 697-747) |
| A19 | `bin/agent-prompts-content-test.sh` is the test surface for prompt-content assertions (existing literal-grep tests against §-section variables `$s5`, `$s4`, etc.). | **verified** (sample at line 1040) |
| A20 | `bin/common-test.sh` is the test surface for cross-script helper unit tests (existing pattern). | **assumed** (will follow the existing per-helper test shape; verify on implementation) |
| A21 | `bin/dispatch.sh:640` qa stage `Bash(bash bin/verify-qa.sh:*)` allowlist entry will continue to allow `verify-qa.sh validate --body ...` (the `*` glob covers any post-validate argv). | **verified** (read directly: line 640 — `bash bin/verify-qa.sh:*` is a literal sandbox-prefix pattern and matches the `--body` argv form) |
| A22 | jq `+` operator on objects is right-biased (right operand keys overwrite left). | **verified** (jq stdlib semantics; brainstorm helper uses `$b[0] + $env` with `$env` on the right) |
| A23 | `bin/run-stage.sh:2353` allocates `PIPELINE_DISPATCH_ID` BEFORE `_clear_current_stage_slots` and BEFORE the agent dispatch; the post-dispatch merge call therefore has the id in env. | **verified** (lines 2350-2359, ordering: allocate → re-export → log → clear) |
| A24 | The orchestrator's `_post_qa_payload_halt` sanitisation (`<!--` → `<\!--`) applies to the verbatim helper-stderr included in the halt body — so an agent body with a hostile dim name cannot hijack the halt marker. | **verified** (`bin/run-stage.sh:2099` `local safe="${raw//<!--/<\\!--}"`) |
| A25 | qa-predicate body file (post-ENG-203) lives under `$PROJECT_STATE_DIR/<ident>/qa-predicate-<ident>.body.json` and respects the existing `partition_dirty_paths` invariant ("`$PROJECT_STATE_DIR` is outside the worktree; the path is not in `git status`"). | **verified** (`bin/common.sh::issue_dir` returns a path under `$PROJECT_STATE_DIR`, not in `$TARGET_REPO`; `partition_dirty_paths` scopes to worktree-relative dirty paths) |
| A26 | `AGENT_PROMPTS.md` qa-stage prompt-content tests live in `bin/agent-prompts-content-test.sh` (the test name `agent-prompts-content-test` is the source-of-truth file). | **verified** (file exists, scanned content) |
| A27 | The verify-qa.sh `--body` flag will route to `qa-predicate-malformed` (rc=42) on body-malformed input, `qa-predicate-missing` (rc=44) on body-missing, `qa-predicate-incomplete` (rc=43) on envelope-shape errors — matching the qa-predicate-* taxonomy at common.sh:735-737. | **assumed** (caller-side remap; implement at the verify-qa.sh `--body` integration point per D-004 "Caller-side rc remap" paragraph) |
| A28 | `_validate_qa_thresholds` (`bin/run-stage.sh:1783` / call site `:3006`) reads `.verdict` and `.dimensions[]` from the merged canonical AFTER `_validate_qa_payload` passes. The right-bias merge with envelope = `{qa_payload_schema_version, issue_id, dispatch_id}` (closed keyset per D-001) preserves agent-emitted `verdict` + `dimensions[]` verbatim, so the threshold gate's semantics are unchanged by ENG-203. | **verified** (feasibility persona Iter-1; read `bin/run-stage.sh:1799-1804` and `1783+` directly) |
| A29 | `bin/pipeline-events.json:28` contains `"qa-payload-invalid"` in the `halt_reasons` array — the halt reason `_post_qa_payload_halt` writes is already registry-valid. | **verified** (feasibility persona IC5) |
| A30 | `_post_qa_payload_halt` (`bin/run-stage.sh:2097-2105`) accepts a free-form `defect` string and interpolates it as `- Defect: %s` — accepts new merge-failure shapes (`envelope-merge-failed-body-missing`, etc.) without code change. | **verified** (feasibility persona IC4) |

### 8.4 Codebase-fact verification — what could still slip

The Assumption Inventory above pins every named code-level fact this
brainstorm relies on with a `path:line` reference confirmed by direct
read. The two **assumed** rows (A20, A27) name implementation surfaces
that don't exist yet; they're the spots the plan stage will need to
create. No "I think the validator does X" beliefs — every behavioral
claim cites a line range.

## 9. Conflict with existing architecture

* **`partition_dirty_paths` scope (CLAUDE.md "Sweep + scope partition"):**
  body sidecars live under `$PROJECT_STATE_DIR/<ident>/`, OUTSIDE the
  worktree. The post-stage sweep never sees them — no leaked-in-scope
  risk. (Verified against the pattern existing predicates use, A25.)
* **`bin/dispatch.sh::allowed_tools_for` qa stage:** the `Bash(bash
  bin/verify-qa.sh:*)` allowlist entry covers the new `--body` form
  (A21). No allowlist edit needed.
* **`bin/render-prompt.sh::PROMPT_RESOLVERS` (line 40-63):** two new
  tokens added. No structural shape change; same pattern as the existing
  twenty entries.
* **`bin/common.sh::failure_outcome_for_exit`** (697-747): no new codes
  needed (D-006). The cosmetic mis-map for rc=42/50 in the qa caller is
  documented but does NOT break the taxonomy invariants.
* **`AGENT_PROMPTS.md` fence-count contract:** edits stay inside the
  existing single fenced block of §6; no new fences introduced.
* **`bin/agent-prompts-content-test.sh`:** the new AP-1..AP-6 tests are
  additive; existing tests untouched.

NO conflicts.

## 10. Scope guard

The Linear ticket's IN list, line-by-line:

* "Decide the mechanism" → **D-001** (sidecar-merge, with rationale).
* "Shared envelope-merge helper" → **D-001 + D-002** (helper signature
  pinned; placement chosen).
* "Update AGENT_PROMPTS.md §6 (qa)" → **D-003** (precise edits enumerated).
* "Sequencing in run-stage.sh" → **D-005 + D-006** (merge before
  validator; body file pre-clean).
* "Preserve clear-on-dispatch-start + overwrite-on-every-dispatch
  (ENG-77/ENG-87)" → **D-005** (clear primitive); D-003 (agent uses
  `Write`).
* "Tests" → **D-009** (helper unit tests, orchestration tests,
  prompt-content assertion).

The Linear ticket's OUT list:

* "plan.json / verdict-review.json / review-ledger (separate children)" →
  helper is designed to be reused unchanged by these children (D-001
  contract). They are NOT shipped here. **OQ-1** explicitly defers the
  "kind"-parameter generalisation.
* "Changing the qa grading semantics or thresholds (ENG-118/ENG-31
  territory)" → no dimension semantics touched; threshold gate runs on
  merged canonical exactly as today (D-006 sequencing).

NO scope creep. NO scope shortfall against the ticket's IN list.

## 11. Persona review

### Iteration 1 — Initial doc

Six personas ran in series (design → security → scope → coherence →
product → feasibility). **All six returned PASS; feasibility (the
gating persona) reported zero P0 findings.** Gate cleared at iter-1; no
iter-2 needed.

| Persona | Verdict | P0 | P1 | P2 |
|---|---|---|---|---|
| Design | PASS | 0 | 3 | 0 |
| Security | PASS | 0 | 2 | 1 |
| Scope | PASS | 0 | 2 | 0 |
| Coherence | PASS | 0 | 2 | 1 |
| Product | PASS | 0 | 2 | 1 |
| Feasibility | PASS | 0 | 2 | 0 |

**P1 findings folded into the doc** (changes named, by section):

| Persona | Finding | Resolution |
|---|---|---|
| Design P1#1 | `--body` overloads `cmd_validate` (build-then-validate). | Added **OQ-6** under D-004 acknowledging the contract overload, naming the two-call sibling alternative, and stating why the in-place flag wins. |
| Design P1#2 + Product P1#1 | OQ-4 envelope-overwrite signal deferred indefinitely; loses retrospective forensic surface. | Promoted **OQ-4 from defer to in-scope**: the helper emits a `bash bin/metrics.sh event envelope-overwrite` row on key-overlap. Added `bin/pipeline-events.json` token + `vocabulary-cleanliness-test.sh` pin to §3.1. |
| Design P1#3 | rc=42/50 cosmetic mis-map is a smell. | Acknowledged in D-006 as an explicit cosmetic trade-off; the halt-body's helper-stderr verbatim is the disambiguating signal (A24 confirms sanitisation). Deferring a new taxonomy slot to ENG-202 explicitly. |
| Security P1#1 | verify-qa.sh `--body` is missing an explicit realpath fence. | Added **mandatory `--body` realpath fence** code block under D-004 — mirrors lines 140-159 fence on `$ARG_FILE`. |
| Security P1#2 | `${canonical}.tmp.$$` not collision-proof under same-shell concurrency. | D-001 helper body now uses `mktemp "${canonical}.tmp.XXXXXX"`. Test U-10's adjacency is the documented future-proof. |
| Security P2 | AP-1/AP-2/AP-4 section-locator deferred. | Locator strategy left to plan stage; flagged as P2 (cosmetic), not P1 — acceptable for this stage. |
| Scope P1#1 | D-005's NEW behavior (clear canonical `qa-predicate-*.json`) tangential to merge mechanism. | D-005 now explicitly names this as a NEW behavior and a LOAD-BEARING consequence of the merge mechanism (not opportunistic cleanup). |
| Scope P1#2 | §3.2 "3 subsystems" vs ticket's "2." | Acknowledged in §3.2; verify-qa.sh sits inside the orchestrator subsystem per CLAUDE.md's 7-subsystem table — count remains 2. |
| Coherence P1#1 | §3.4 caller-side rc remap not pinned to a function. | D-004 "Caller-side rc remap" paragraph now pins the location: `verify-qa.sh::cmd_validate`, immediately after the merge call, before the existing validation block. |
| Coherence P1#2 | OS-4 test name reads as a question. | Test description in D-009 rewritten as a guarantee — assert both body AND canonical absent post-clear. |
| Coherence P2 | D-006's "cannot fire in practice" applies symmetrically to verify-qa.sh side. | Micro-clarification, low impact; not folded. Already implicit. |
| Product P1#2 | Agent might forget `--body` flag on verify-qa.sh — new slip surface. | Added **AP-7** test pinning the literal flag-positional shape in the prompt example so an agent that copy-pastes can't drift into the no-`--body` form. |
| Product P2 | D-008 cutover atomicity only holds for fresh dispatches. | D-008 now names the in-progress-dispatch-at-deploy edge case and points to recovery.md §15. |
| Feasibility P1#1 | `_validate_qa_thresholds` reader not in Assumption Inventory. | Added **A28**, plus A29 (`qa-payload-invalid` registry validity) and A30 (`_post_qa_payload_halt` free-form defect string). |
| Feasibility P1#2 | Envelope keyset not pinned; right-bias merge could corrupt content if caller drifts. | D-001 now **closes the envelope keyset** explicitly to 3 keys (qa-payload) / 2 keys (qa-predicate); D-009 adds OS-6, OS-7 (caller-side tests) and U-10 (helper-level documentary test). |

**Independent codebase-fact checks** (feasibility persona): all 26
verified A-rows (A1-A26) CONFIRMED against cited line ranges. Two
**assumed** rows (A20, A27) — both implementation-surface details, not
design pivots; verifiable at plan time.

Persona panel readout: the brainstorm is design-coherent, factually
grounded, in-scope, and structurally closes the ENG-118 root cause. All
P1 findings folded; P2 findings acknowledged. No iteration 2 needed.
