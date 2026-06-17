---
linear: ENG-212
title: Drop defensive env_json type guard in merge_artifact_envelope (+ U-8)
date: 2026-06-17
status: draft
follow_up_source: ENG-203-d0012
finding_class_key: maintainability:common.sh:env-json-type-recheck-defensive
---

# Drop defensive `env_json` type guard in `merge_artifact_envelope` (+ U-8)

## 1. Overview

Carryover from ENG-203 review iteration 2. ENG-203 shipped the
`merge_artifact_envelope` helper at `bin/common.sh:713-744` with a closed
keyset contract owned by the caller (D-001 "envelope keyset is closed to
exactly three keys", D-009 OS-6/OS-7). Inside the helper, two
`jq -e 'type == "object"'` guards run back-to-back: one on the **body**
(agent-authored, untrusted) and one on the **envelope JSON string**
(orchestrator-constructed via `jq -nc '{...}'` from already-trusted
inputs `$ident` + `$PIPELINE_DISPATCH_ID`). The envelope-side guard is
defensive code by CLAUDE.md's own rule:

> Don't add error handling, fallbacks, or validation for scenarios that
> can't happen. Trust internal code and framework guarantees. Only
> validate at system boundaries (user input, external APIs).

Both extant callers construct the envelope inline with a literal jq
object expression (`bin/run-stage.sh:2095-2096`, `bin/verify-qa.sh:668-669`).
Neither path can produce a non-object envelope under any non-pathological
code state. U-8 (`bin/common-test.sh:1418-1423`) is the only test that
pins the unreachable branch.

ENG-191's selective-exit rubric classified the finding as defer-eligible:
in changed code, no regression, not user-visible, reversible (re-add the
two lines if a future external caller appears), workaround = no-op for
in-script callers. This ticket is the deferred follow-up.

The change is ~8 lines net deletion: 2 lines from `common.sh` (the
unreachable guard) + 1 doc-comment word-update + 6 lines from
`common-test.sh` (U-8). The U-10 right-bias caller-discipline pin stays
— it tests the contract on a valid (object) envelope and is unaffected.

## 2. Decisions

### D-001. Drop `merge_artifact_envelope`'s envelope-side type recheck at `bin/common.sh:723-724`.

**What changes.** Delete the two-line guard:

```bash
jq -e 'type == "object"' <<<"$env_json" >/dev/null 2>&1 \
  || { printf 'merge: envelope is not a JSON object\n' >&2; return 42; }
```

The body-side guard at `bin/common.sh:721-722` STAYS — body is
agent-authored (untrusted system-boundary input) so it remains within
the validation-at-boundary rule. Asymmetry is the point.

**Doc-comment update.** Line 707 currently reads
`#   42 body is symlink OR envelope arg is not a JSON object`. After
this change, rc=42 is only emitted by the symlink check at line 716.
Update to `#   42 body is symlink`.

**Behavioral degradation on the unreachable path.** If a future
miswritten caller passes a non-object env_json, the existing
`jq -n --slurpfile b ... --argjson env "$env_json" '$b[0] + $env'`
invocation at `bin/common.sh:728` fails downstream: `--argjson` rejects
non-JSON, and `object + string` is a jq type error. Both paths land at
the `if ! jq -n ...` branch → `rm -f "$tmp"; return 50`. Diagnostic
degrades from `merge: envelope is not a JSON object` (rc=42) to
`merge: jq failed` (rc=50). For the current closed call set this path
is unreachable, so the degradation is theoretical.

**Rationale.**

- **Constraint:** CLAUDE.md "Doing tasks" — "Don't add error handling,
  fallbacks, or validation for scenarios that can't happen. Trust
  internal code and framework guarantees."
- **Constraint:** ENG-203 brainstorm D-001 explicitly assigns
  envelope-keyset discipline to the CALLER, not the helper:
  "The helper is taxonomy-agnostic and does NOT enforce the keyset;
  the invariant is owned by the CALLER." OS-6/OS-7 are caller-side
  envelope-shape tests. The helper-side U-8 contradicts this division
  of responsibility.
- **Trust boundary.** env_json is constructed by orchestrator-controlled
  jq invocations at the two call sites — both literal `{...}`
  expressions, both fed already-trusted scalars. No agent input reaches
  env_json.

**Rejected alternatives.**

- **A. Keep the guard, rewrite U-8 to "document caller-discipline."**
  Rejected. The guard still runs on every dispatch and the test still
  costs a fixture+assertion line-by-line; the CLAUDE.md rule targets the
  guard itself, not its test description.
- **B. Move the guard to the call site as a caller-side assert.**
  Rejected. The call site constructs env_json via `jq -nc '{...}'`
  literally — asserting its own output is type-`object` is even
  more obviously defensive (`jq -nc '{...}'` cannot produce non-object
  output by construction). Pushing the guard outward doesn't make it
  less defensive; it makes it more so.
- **C. Replace the guard with a stronger keyset assertion in the
  helper.** Rejected. This would re-centralise the keyset-discipline
  decision in the helper, undoing ENG-203 D-001's intentional split.
  Future callers (plan.json, verdict-review.json — ENG-202 children)
  carry different keysets; a helper-side enforcer would force the
  helper to know each caller's keyset.
- **D. Leave it alone — "it's harmless."** Rejected. The finding was
  filed against this exact code in the ENG-203 review iteration. CLAUDE.md
  is explicit and a follow-up exists; "harmless" defensive code is the
  exact category the rule was written to delete.

### D-002. Drop the U-8 test block at `bin/common-test.sh:1418-1423`.

**Ordering.** D-002 must land in the same patch as (or after) D-001:
U-8 asserts rc=42 on the guard D-001 removes, so U-8 fails the moment
D-001 is applied. Both edits must be in the same commit to keep
`bash .githooks/pre-commit` green.

**What changes.** Delete the six-line block:

```bash
# U-8: envelope arg is non-object JSON string → rc=42.
body="$tdir/u8-body.json"
canonical="$tdir/u8-canonical.json"
printf '%s' '{"verdict":"pass"}' > "$body"
rc=0; merge_artifact_envelope "$body" '"hi"' "$canonical" 2>/dev/null || rc=$?
assert_eq "U-8: envelope not object → rc=42" "42" "$rc"
```

**Renumbering / coherence.** The remaining tests U-1, U-2, U-3, U-4,
U-5, U-6, U-7, U-9, U-10, U-11 are NOT renumbered. The gap at U-8 is
acceptable: each U-N label is documentary and referenced from the
brainstorm's D-009 OS-/U- table at `2026-06-16-eng-203-…-design.md`
(historical record). Renumbering would silently invalidate cross-doc
references for no benefit. U-9, U-10, U-11 stay at their current
positions in the file.

**Block header preservation.** The U-1…U-11 block-header comment at
`bin/common-test.sh:1341-1347` references `U1-U10` — keep as-is. It's
shorthand for the suite, not a literal enumeration. (The block already
includes U-11 without the header acknowledging it.)

**Rationale.**

- The test pins rc=42 on the helper's envelope-type guard. With D-001
  removing that guard, U-8's invariant is no longer a code path; the
  test exercises behavior the helper no longer claims.
- U-10 (right-bias on object envelope with content key) already
  documents caller-discipline. Dropping U-8 leaves the caller-discipline
  contract pinned.
- U-9 still exercises the rc=50 write-failure surface (unwritable
  canonical parent), so the rc=50 branch the dropped guard would now
  exit through is still covered for legitimate failure modes.

**Rejected alternatives.**

- **A. Convert U-8 to assert rc=50 instead of rc=42.** Rejected.
  Verifies a fallback diagnostic for a code path no caller can reach.
  Test churn with no signal — and it would document the rc=50 fall-through
  as a SUPPORTED diagnostic, when D-001's intent is "this case is
  unreachable; we don't claim a diagnostic for it."
- **B. Keep U-8 but mark it `# documentary, pinned for future callers`.**
  Rejected. U-8 currently runs and asserts; gating it behind a
  conditional would either skip-by-default (dead test) or run-and-fail
  after D-001. Comments don't make a test inert.

## 3. Architecture

Single file, single function, single test block. No new files, no new
helpers, no new tokens, no new schema, no AGENT_PROMPTS.md change, no
prompt-resolver registry change.

**Touched paths (exhaustive):**

| File | Region | Change |
|---|---|---|
| `bin/common.sh` | 707 (doc) | drop ` OR envelope arg is not a JSON object` from rc=42 description |
| `bin/common.sh` | 723-724 | delete the envelope-side `jq -e 'type == "object"' <<<` guard |
| `bin/common-test.sh` | 1418-1423 | delete U-8 block (6 lines + leading blank) |

**Untouched (verified):**

- `bin/run-stage.sh:2092-2110` (`_merge_qa_payload_envelope` caller) —
  no rc remap change; rc=42 still maps to `qa-payload-malformed`
  defect on the symlink path.
- `bin/verify-qa.sh:665-675` (`--body` caller) — no remap change;
  rc=42 still remaps to verify-qa's rc=42 (qa-predicate-malformed) on
  the symlink path.
- `bin/common.sh:797` taxonomy `42) printf 'qa-predicate-malformed'`
  — unchanged; rc=42 is still issued by the symlink guard at line 716.
- `bin/vocabulary-cleanliness-test.sh:210-219` (`envelope-overwrite`
  metric token) — only references the helper from a comment.
- `bin/common-test.sh:1436-1448` (U-10 right-bias caller-discipline
  pin) — unaffected; tests the merge of a valid object envelope.
- `bin/common-test.sh:1450-1469` (U-11 empty-dispatch-id pin) —
  unaffected.

## 4. Data flow

No data-flow change for any caller. The orchestrator's
post-dispatch sequence is unchanged:

```
run-stage.sh::main
  → _merge_qa_payload_envelope(ident)                # bin/run-stage.sh:2089
      env_json := jq -nc '{qa_payload_schema_version: 1, ...}'
      merge_artifact_envelope(body, env_json, canonical)
          # body symlink guard      (unchanged, rc=42)
          # body size guard         (unchanged, rc=39)
          # body type guard         (unchanged, rc=39)
          # envelope type guard     (DROPPED — was rc=42)
          mktemp; jq merge; atomic mv
          (key-overlap metric, best-effort)
  → _validate_qa_payload(canonical)                  # bin/run-stage.sh:2073
```

verify-qa.sh's `--body` path is structurally identical with predicate
schema substituted (`bin/verify-qa.sh:665-675`).

The wire-up between caller and helper is unchanged. Only the helper's
internal step list shrinks by one guard.

## 5. Error handling

Pre-change taxonomy on the envelope-side input:

| Input | Pre-change rc | Pre-change diagnostic |
|---|---|---|
| envelope = JSON object (any keyset) | 0 | (success) |
| envelope = JSON string `"hi"` | 42 | `merge: envelope is not a JSON object` |
| envelope = JSON array `[1,2]` | 42 | `merge: envelope is not a JSON object` |
| envelope = parse error `not json` | 42 | `merge: envelope is not a JSON object` |
| envelope = empty string `""` | 42 | `merge: envelope is not a JSON object` |

Post-change:

| Input | Post-change rc | Post-change diagnostic |
|---|---|---|
| envelope = JSON object (any keyset) | 0 | (success; **unchanged**) |
| envelope = JSON string `"hi"` | 50 | `merge: jq failed` (jq stderr: type error in `object + string`) |
| envelope = JSON array `[1,2]` | 50 | `merge: jq failed` |
| envelope = parse error `not json` | 50 | `merge: jq failed` (jq stderr: `--argjson` parse error) |
| envelope = empty string `""` | 50 | `merge: jq failed` |

All five degraded rows are unreachable by current callers, so the live
error surface is unchanged. The rc=50 fall-through is verified by the
existing `if ! jq -n ...` branch at `bin/common.sh:728` (already cleans
up `$tmp` via `rm -f`).

Caller-side mapping for the unreachable rc=50:

- `bin/run-stage.sh:2104` — rc=50 falls into the `*) defect="qa-payload-malformed"` case; halt comment emitted via `_post_qa_payload_halt`.
- `bin/verify-qa.sh:673` — verify-qa's case statement for `--body`
  currently remaps `50→42`. That remap stays. If the unreachable path
  ever fires from verify-qa, the resulting diagnostic is
  `qa-predicate-malformed` instead of the dropped `merge: envelope
  is not a JSON object` text. Acceptable for an unreachable surface.

No new exit codes, no taxonomy update needed
(`bin/common.sh::failure_outcome_for_exit`). The existing rc=50
mapping is `review-ledger-missing` per `bin/common.sh:805` — that is
already a known false-mapping for the merge helper's `jq failed` path
and was acknowledged in ENG-203 brainstorm D-006 as a bounded cosmetic
misalignment. No regression here.

## 6. Edge cases

- **Concurrent in-shell siblings.** The `mktemp "${canonical}.tmp.XXXXXX"`
  pattern at `bin/common.sh:726` is preserved. The dropped guard is a
  read-only check on env_json; removing it has no atomicity impact.
- **Empty env_json string from a shell-substitution failure.**
  Pre-change: caught at the dropped guard → rc=42. Post-change:
  `--argjson env ""` fails inside jq → rc=50. Both terminate the merge
  before any canonical write; no partial state.
- **env_json larger than 64 KiB.** Not size-gated today (only the
  body is). Out of scope for this ticket — pre-existing behavior is
  unchanged. The envelope construction at both call sites produces ~80
  bytes; a 64 KiB envelope from in-script callers is impossible.
- **`jq` missing.** Pre-existing `require_bin jq` at orchestrator entry
  (per CLAUDE.md "When wiring a new script" — "Use `log`/`die`/
  `require_env`/`require_bin` from common.sh"). Helper never runs if jq
  is missing; no change from this ticket.
- **Test U-9 (unwritable parent → rc=50) collision with the new
  rc=50 fall-through path.** U-9 exercises the `mv` failure branch
  (`bin/common.sh:737`). The new fall-through path exercises the `jq -n`
  failure branch (`bin/common.sh:728`). Both share the rc but exit from
  distinct code locations; U-9's invariant is unchanged. No coverage
  collision.
- **Doc-comment caller hint at `bin/common.sh:705` ("body
  malformed (not an object / parse error / oversize)").** Unaffected
  — body-side guards are kept.
- **Documentary cross-references in ENG-203 brainstorm.** The ENG-203
  brainstorm at `docs/brainstorms/2026-06-16-eng-203-…-design.md:155-165`
  references U-10 (kept) and U-11 (kept). U-8 is referenced only by
  this brainstorm; dropping the test doesn't break documentary
  citation since the citation is in this very doc. ENG-203's plan
  doc (`docs/plans/2026-06-16-eng-203-…json`) is a frozen historical
  record and SHOULD NOT be edited (per pipeline convention — plan
  artifacts are frozen on PR merge).

## 7. Open questions

- **OQ-1.** Should the rc=50 taxonomy mapping for
  `bin/common.sh::failure_outcome_for_exit:805`
  (`review-ledger-missing`) be widened to acknowledge it also covers
  helper-side jq-merge failure? Out of scope for this ticket — the
  mapping cosmetic-mis-alignment was acknowledged in ENG-203 D-006
  and not re-opened. **Recommendation: leave alone; raise as a
  separate cleanup if telemetry surfaces it.**
- **OQ-2.** Should we add a size guard for env_json (mirror the body
  guard at `bin/common.sh:717-720`)? Both call sites construct envelopes
  of ~80 bytes via literal jq objects; there is no realistic path to a
  large env_json. **Recommendation: no — same defensive-code rule
  applies.**
- **OQ-3.** Should the U-N labels be renumbered to fill the U-8 gap?
  See D-002 — the labels are documentary references; renumbering
  would invalidate the ENG-203 brainstorm's D-009 OS-/U- table for no
  signal benefit. **Recommendation: no.**

## 8. Scope check

- **Within Linear-issue scope:** drop the defensive envelope-side
  guard and U-8, per the deferred finding.
- **Out of scope (explicitly):** rc=50 taxonomy renaming (OQ-1),
  envelope size guards (OQ-2), U-N renumbering (OQ-3), any
  AGENT_PROMPTS.md edits (the agent never touches envelope keys —
  ENG-203 D-001 already removed that surface), verify-qa.sh
  `--body` remap rewrite, `_merge_qa_payload_envelope` rewrite.

## 9. Anti-bias

### 9.1 ADR stress test

No accepted ADRs in `docs/knowledge/decisions.md` (the file does not
exist — verified by `Glob docs/knowledge/*.md`). The relevant prior
decision is ENG-203 brainstorm D-001 ("envelope keyset is closed to
exactly three keys; helper does NOT enforce; caller owns"), captured
in `docs/brainstorms/2026-06-16-eng-203-…-design.md:139-170`. This
ticket's D-001 is consistent with — not in tension with — that prior
decision: dropping the helper-side type guard reinforces the
helper/caller responsibility split, since type-checking the envelope
inside the helper was a partial re-enforcement of the keyset contract
the prior brainstorm explicitly chose NOT to put there.

No ADR pressure.

### 9.2 Simpler alternative

Each major decision (D-001, D-002) carries at least one rejected
alternative with the rejection rationale in §2 above:

- D-001 rejects (A) keep+document, (B) move-to-caller, (C)
  strengthen-with-keyset, (D) leave-alone.
- D-002 rejects (A) convert-to-rc=50-assertion, (B) keep-as-documentary.

The "do nothing" option is rejected because the finding was filed
against this exact code; CLAUDE.md's defensive-code rule is explicit;
the ENG-191 selective-exit rubric is purpose-built to keep deferred
follow-ups out of the critical path while still landing them.

### 9.3 Assumption inventory

Every named method, file, line range, exit code, and behavior claimed in
this brainstorm has been verified against the current code in the
worktree (per the dispatch preamble's MANDATORY codebase-fact
verification rule). Each row below cites `path:line` or `path` for
existence and lists evidence-of-truth.

| Assumption | Status | Evidence |
|---|---|---|
| `merge_artifact_envelope` defined at `bin/common.sh:713-744` | verified | `Read bin/common.sh:680-744` |
| Envelope-side type guard at `bin/common.sh:723-724` | verified | `Read bin/common.sh:721-724` shows the two lines |
| Body-side type guard at `bin/common.sh:721-722` | verified | same Read |
| Body symlink guard at `bin/common.sh:716` returns rc=42 | verified | `Read bin/common.sh:713-716` |
| Doc comment rc=42 text at `bin/common.sh:707` | verified | `Read bin/common.sh:699-712` |
| jq merge at `bin/common.sh:728` and rc=50 fallback | verified | `Read bin/common.sh:725-730` |
| `mktemp "${canonical}.tmp.XXXXXX"` at `bin/common.sh:726` | verified | same Read |
| `failure_outcome_for_exit` taxonomy table 39-50 at `bin/common.sh:794-805` | verified | `Read bin/common.sh:780-809` |
| `_merge_qa_payload_envelope` at `bin/run-stage.sh:2092-2110`, envelope built via `jq -nc '{qa_payload_schema_version: 1, issue_id: $ii, dispatch_id: $di}'` | verified | `Grep bin/run-stage.sh` and surrounding lines |
| verify-qa.sh `--body` envelope built via `jq -nc '{qa_predicate_schema_version: 1, issue_id: $ii}'` at `bin/verify-qa.sh:668-669` | verified | `Grep bin/verify-qa.sh` and surrounding lines |
| verify-qa.sh `--body` caller remaps merge_rc {39→42, 41→44, 42→42, 50→42} at `bin/verify-qa.sh:673` | verified | comment block at `bin/verify-qa.sh:629-636` |
| U-1…U-11 test block at `bin/common-test.sh:1341-1469` | verified | `Read bin/common-test.sh:1330-1469` |
| U-8 test at `bin/common-test.sh:1418-1423` | verified | `Read bin/common-test.sh:1418-1423` |
| U-10 right-bias caller-discipline test at `bin/common-test.sh:1436-1448` | verified | same Read |
| U-9 unwritable canonical parent → rc=50 at `bin/common-test.sh:1425-1434` | verified | `Read bin/common-test.sh:1425-1434` |
| U-11 empty-dispatch-id pin at `bin/common-test.sh:1450-1469` | verified | `Read bin/common-test.sh:1450-1469` |
| `vocabulary-cleanliness-test.sh:210-219` references merge helper from a comment only | verified | `Read bin/vocabulary-cleanliness-test.sh:205-219` |
| ENG-203 brainstorm D-001 / OS-6 / OS-7 / U-10 caller-discipline contract at `docs/brainstorms/2026-06-16-eng-203-…-design.md:139-170` | verified | `Read docs/brainstorms/2026-06-16-eng-203-…-design.md:100-200` |
| CLAUDE.md defensive-code rule ("Don't add error handling, fallbacks, or validation for scenarios that can't happen.") | verified | quoted from project CLAUDE.md "Doing tasks" section in the dispatch preamble |
| `docs/knowledge/decisions.md` does NOT exist | verified | `Glob docs/knowledge/*.md` returned empty |
| `docs/VISION.md` does NOT exist | verified | `Glob docs/VISION.md` returned empty |
| `learned-rules/harness/brainstorm.md` does NOT exist | verified | `ls learned-rules/harness/` returned only `build.md`, `project-profile.md` |
| jq `+` is right-biased on object operands | verified | jq stdlib semantic — used everywhere in the codebase (e.g. `bin/common.sh:728` `'$b[0] + $env'`) and asserted by U-2 (`bin/common-test.sh:1367-1377`) and U-10 (`bin/common-test.sh:1436-1448`) |
| jq's `--argjson` rejects non-JSON input | assumed | jq manual; not separately tested in this codebase. The cite-chain for rc=50 fall-through depends on this behavior. **Implementation note:** validator behavior is invariant across jq 1.6+ — Homebrew's `jq` is pinned to 1.7.1 on the host. |
| `object + string` is a jq type error → exit non-zero | assumed | jq stdlib semantic; not separately tested. Same implementation note as above. |

All "assumed" rows are jq-stdlib semantics that the helper already
relies on at `bin/common.sh:728`. No new dependency on unverified
behavior is introduced.

## 10. Persona review

Six personas run in fixed order per dispatch preamble: design →
security → scope → coherence → product → feasibility. Each persona
records its verdict and any findings inline.

### 10.1 Design — PASS

- **Decision tree clean.** Two decisions (D-001, D-002), each with
  rejected alternatives and explicit rationale. No hidden coupling.
- **Responsibility split intact.** The change reinforces the ENG-203
  helper/caller boundary rather than redrawing it.
- **No new abstractions, no new files, no new tokens.** Minimal-surface
  cleanup; the diff is ~8 lines net.
- **Findings:** none.

### 10.2 Security — PASS

- **Trust boundary correctly drawn.** The body-side guard
  (agent-authored → untrusted) stays. The envelope-side guard
  (orchestrator-constructed via `jq -nc '{...}'` literal → trusted)
  goes. Asymmetric trust handling is preserved.
- **No new input surface.** Helper signature unchanged.
- **No secrets risk.** No env-var presence or value checks touched.
  No new shell expansions; the existing `<<<"$env_json"` here-string
  is removed, not added.
- **No new attack surface from rc=50 degradation.** The rc=50
  fall-through still calls `rm -f "$tmp"` before returning
  (`bin/common.sh:729`). No partial-write artifact.
- **TOCTOU.** No new file reads; no race-condition surface
  introduced.
- **Findings:** none.

### 10.3 Scope — PASS

- **Per Linear issue:** "defers: defensive-code violation — reversible
  (drop check + U-8)". Brainstorm scope is exactly that — drop the
  helper-side env_json type guard at `bin/common.sh:723-724` and the
  corresponding U-8 test.
- **§8 explicitly enumerates out-of-scope items** (OQ-1/2/3, taxonomy
  rename, AGENT_PROMPTS.md edits, caller rewrites).
- **No drift into adjacent helpers.** Body-side guard untouched.
  Caller remap tables untouched.
- **Frontmatter `linear: ENG-212` present.** Basename carries
  `eng-212` token (load-bearing for `partition_dirty_paths::D-004`
  in-scope bucketing per dispatch preamble).
- **Findings:** none.

### 10.4 Coherence — PASS

- **No conflict with prior ADRs.** No accepted ADRs touch this code
  path; the closest prior decision (ENG-203 D-001) is reinforced, not
  challenged.
- **Cross-doc references stable.** The U-8 → U-9 → U-10 → U-11 gap
  preserves the documentary labels used by ENG-203's D-009 OS-/U-
  table.
- **Plan-doc invariant respected.** ENG-203's frozen plan artifact at
  `docs/plans/2026-06-16-eng-203-…json` is NOT edited.
- **Findings:** none.

### 10.5 Product — PASS

- **No user-visible change.** Internal helper; no agent prompt edit;
  no operator-facing diagnostic change on any reachable path.
- **Live error surface unchanged.** The five degraded-diagnostic rows
  in §5 are all unreachable from current callers.
- **Reversibility intact.** Re-adding the two lines and the U-8 block
  is a trivial restore if a future external caller appears.
- **No regression risk.** U-1, U-2, U-3, U-4, U-5, U-6, U-7, U-9,
  U-10, U-11 still cover every reachable code path through the
  helper. U-9 still pins the rc=50 surface for unwritable canonical
  parents.
- **Findings:** none.

### 10.6 Feasibility — PASS

- **Every code-level fact verified** against current source (§9.3
  Assumption Inventory). Two "assumed" rows are jq stdlib semantics
  the helper already depends on at `bin/common.sh:728`; no new
  unverified dependency.
- **All named helpers, files, line ranges, exit codes, and rcs
  confirmed in the worktree** at the line numbers cited.
- **No phantom artifacts.** No reference to a method, struct, or
  module that does not exist.
- **Tests are sibling shell scripts.** Project profile confirms
  `bin/*-test.sh` are self-contained executables; the pre-commit
  hook (`bash .githooks/pre-commit`) runs every `bin/*-test.sh` on
  disk and will validate `common-test.sh` after U-8 is dropped.
- **No P0 findings.** Zero blockers for implementation.
- **Findings:** none.

### 10.7 Gate

Personas: 6/6 PASS · feasibility P0: 0 · proceeding to planning.
