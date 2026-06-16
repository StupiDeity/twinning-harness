---
linear: ENG-194
title: Reviewer is scope-aware — out-of-plan-scope findings auto-defer, never loop back (descoped 2-subsystem shape)
date: 2026-06-16
status: draft
supersedes: docs/brainstorms/2026-06-14-eng-194-reviewer-is-scope-aware-a-finding-whose-fix-lands-outside-the-plan-s-file-structure-is-auto-deferred-never-looped-back-design.md
---

# Reviewer is scope-aware — out-of-plan-scope findings auto-defer, never loop back (descoped)

## 0. Provenance — supersedes 2026-06-14 draft

This document is the third dispatch's authoritative draft for ENG-194.
Dispatches d0001 and d0002 produced the 2026-06-14 brainstorm (2370 lines)
which gated 5/6 PASS + 1 feasibility P0 at iter-2 of d0002 and halted with
`iteration-exhausted`. Between dispatches, the operator made an
authoritative **DESCOPE** decision committed at `f804369` (2026-06-16):
reduce ENG-194 to the autonomy-safe 2-subsystem shape; file three carve-outs
as follow-up tickets:

- (a) D-006 — orchestrator's deferred-majors comment partition (grouped
  sub-sections + operator-recipe trailer).
- (b) D-007's second resolver — `{plan_scope_benign_path_classes}` (reviewer
  consults stack-agnostic benign-path classes alongside the plan).
- (c) D-002's `critical-out-of-plan/<ident>` meta-comment recipe trailer
  (operator-recipe Linear comment for the critical+out-of-plan residual
  case).

The plan-mutation transcript defense (D-005 paragraph in the 2026-06-14
draft, added in iter-1-of-d0002 for security iter-1 P0 #2) is also
deferred — it lives in `bin/run-stage.sh::_validate_dispatch_envelope`,
which is the orchestrator subsystem; including it tips the ticket to 3
subsystems. See §7 OQ-3 for the threat-model trade-off.

This brainstorm planning surface is **strictly the reduced scope**:
**D-001 + D-002 + D-003 + D-004 + D-005 + D-008**. The planning agent
MUST NOT plan D-006, D-007's second resolver, D-002's critical-out-of-plan
recipe trailer, or the plan-mutation transcript defense.

## 1. Overview

[ENG-194](https://linear.app/twinning/issue/ENG-194) closes a structural
catch-22 in the review→implement loop. The reviewing stage's finding
authority is unconstrained by the plan, but the implement/ui/qa stages
that *act* on review findings ARE scope-constrained by
`bin/scope-check.sh:261-394`'s post-dispatch diff-vs-plan gate. A review
finding whose fix touches a file the plan didn't scope traps the
implement agent: fix it → `scope-check.sh` halts with `scope-violation`;
don't fix it → next cold review re-flags it → `reviewing → implementing`
loopback → ratchet → eventual `review_rejection` halt. The recovery path
is broken too — [ENG-180](https://linear.app/twinning/issue/ENG-180)'s
scope-approval-resume bug means even `bash bin/pipeline.sh decide
--action approve --gate scope` doesn't unstick it.

**Fix.** Make the reviewer **structurally aware** of the plan scope. When
the reviewer identifies a finding whose fix-target file is out-of-plan,
it auto-classifies the finding as `blocks_ship=false` with
`defer_reason="out-of-plan-scope"` and routes it through
[ENG-191](https://linear.app/twinning/issue/ENG-191)'s deferred-majors
machinery — never as a `reviewing → implementing` loopback. The catch-22
dissolves because the finding never *asks* the implementer to make a
scope-violating edit.

**Win attribution.** Part of [ENG-189](https://linear.app/twinning/issue/ENG-189)'s
review-convergence family (Lever 4). The other three levers (ENG-190
reviewer memory, ENG-191 selective exit, ENG-192 fix-the-class) all
assume the finding/fix loop CAN converge. ENG-194 handles the residual
class where it structurally cannot: out-of-plan-scope findings.
Empirically observed on [ENG-27](https://linear.app/twinning/issue/ENG-27)
(2026-06-12) — `docs/install.md` flagged stale, plan only scoped
`bin/setup.sh`; operator unstuck via manual plan-amend + force-transition.

**Subsystem accounting (CLAUDE.md ticket-sizing rubric).** Two subsystems
touched:

1. **scope/sweep.** New `bin/plan-scope.sh` (the shared in-plan matcher
   extracted from `bin/scope-check.sh`); `bin/scope-check.sh` refactored
   to source it (D-001).
2. **agent-prompts (the agent-output contract).** AGENT_PROMPTS.md §5
   plan-scope adjudication block (D-002 + D-004); `bin/render-prompt.sh`
   gains one new resolver `{plan_scope_allowed_paths}` (D-007 first
   resolver only); `bin/review-ledger-schema.sh` ledger field +
   validator extension (D-003 + D-005). The validator is the
   structural enforcement layer for the §5 prompt contract — same
   contract surface as the prompt it gates.

One primary design decision (out-of-plan ⇒ defer; structural short-circuit
of the ENG-191 rubric). All sub-decisions are mechanically necessary:
the helper extraction (D-001), the prompt-side adjudication (D-002),
the ledger field (D-003), the predicate extension (D-004), the validator
(D-005), the tests (D-008). No third "feature" surface.

**Three deferred items become follow-up tickets after ENG-194 ships:**

- ENG-194-A — orchestrator deferred-majors comment grouping +
  operator-recipe trailer (was D-006).
- ENG-194-B — `{plan_scope_benign_path_classes}` second resolver +
  reviewer-side benign-path matching (was D-007's second resolver).
- ENG-194-C — `critical-out-of-plan/<ident>` operator-recipe meta-comment
  for critical+out-of-plan residuals (was D-002 final paragraph).
- ENG-194-D — plan-mutation transcript defense in
  `_validate_dispatch_envelope` (was iter-1-of-d0002 security P0 #2).

**Reference to constraint.** CLAUDE.md ticket-sizing rubric §"Axis 1 —
Subsystems touched": "1 subsystem → autonomy-safe; 2 subsystems with one
clearly subordinate → autonomy-safe IF the scope boundary is explicit in
the ticket body." Here the scope/sweep extraction (D-001) is the
subordinate to the agent-prompts contract change (D-002 + D-003 + D-004 +
D-005); the boundary is enumerated above and re-pinned in §8.

**Reference to constraint.** CLAUDE.md "AGENT_PROMPTS.md is load-bearing":
the new block sits inside §5's existing fenced body — no new H2 section,
no column-0 ``` fence, no change to `STAGE_TO_SECTION` in
`bin/render-prompt.sh`.

## 2. Decisions

### D-001. Extract the in-plan-scope matcher into `bin/plan-scope.sh` — both `bin/scope-check.sh` and a new `bin/render-prompt.sh` resolver source it. Byte-for-byte agreement enforced by a sibling test that asserts identical `allowed_files` / `allowed_dirs` output from both callers. The helper is PLAN-STRUCTURAL ONLY (no benign-path classes, no stack-conditional residue).

**Rationale.** Linear AC #4: "The in-plan-scope matcher is shared with
`bin/scope-check.sh` (one helper, both callers) so reviewer-defer and
scope-check-halt decisions cannot diverge (assert both call the same
function)."

The matcher decomposes into four steps scattered across
`bin/scope-check.sh:143-378`:

1. **Find the canonical plan.** `find_canonical_plan <issue_id>
   <worktree_root>` (`bin/scope-check.sh:143-157`) — frontmatter
   `linear: <ID>` match, 20-line cap, awk-driven.
2. **Extract the File Structure section.** `extract_scope_section
   <plan>` (`bin/scope-check.sh:159-172`) — awk grabs the body between
   the `## File Structure` (or `### File Structure` or `## N. File
   Structure`) heading and the next sibling heading.
3. **Parse allowed files + allowed dirs.** The
   `allowed_files="$(grep -oE ...)"` and `allowed_dirs="$(grep -oE
   ...)"` block at `bin/scope-check.sh:307-314` — two grep regexes
   plus an awk filter for the malformed-capture case.
4. **Match a single path.** The inner per-changed-file loop at
   `bin/scope-check.sh:356-378` — `grep -qxF "$f" <<<"$allowed_files"`
   for exact-match, plus a per-line prefix check for directory match.

ENG-194 extracts steps 1-4 into `bin/plan-scope.sh`. Public API:

```bash
# Find the canonical plan file for an issue under <root>/docs/plans/.
# Returns 0 + absolute path on stdout, 1 if no plan found.
plan_scope::find_plan <issue_id> <worktree_root>

# Extract the File Structure body from a plan file. Returns 0 + body
# on stdout. Empty stdout iff the section is absent.
plan_scope::extract_section <plan_path>

# Parse <body> into the allowed_files set (newline-separated, sorted-
# unique). May be empty (no matches in body).
plan_scope::parse_allowed_files <body>

# Parse <body> into the allowed_dirs set (newline-separated, sorted-
# unique). Each entry ends with `/`. May be empty.
plan_scope::parse_allowed_dirs <body>

# Match a path against the parsed sets. allowed_files exact-match wins
# first; allowed_dirs prefix-match second. Returns 0=in-scope,
# 1=out-of-scope. STRICTLY structural — does NOT consult any benign-
# path classes, lockfiles, or stack-conditional carve-outs. Those
# remain in scope-check.sh::is_benign (orchestrator-side runtime
# policy, intentionally invisible to the reviewer per the operator
# descope decision; see §6 Edge case 8 for the bounded divergence).
plan_scope::path_in_scope <path> <allowed_files> <allowed_dirs>
```

Five functions, each single-responsibility. The 2-arg `path_in_scope_or_benign`
convenience wrapper proposed in the 2026-06-14 draft is REMOVED per
operator descope — benign-path partitioning was D-007's second-resolver
surface, not in this brainstorm.

**`bin/scope-check.sh` refactor.** Replace the inline parse + match with
`plan_scope::*` calls.

- `find_canonical_plan` (line 143-157): preserve the function name as a
  thin wrapper that delegates to `plan_scope::find_plan` (back-compat
  for test-source-and-stub callers).
- `extract_scope_section` (line 159-172): same wrapper pattern delegating
  to `plan_scope::extract_section`.
- `allowed_files` / `allowed_dirs` parse (line 297-314): replace inline
  greps with calls to `plan_scope::parse_allowed_files` /
  `plan_scope::parse_allowed_dirs`.
- Per-file in-scope check (line 356-366): replace the `grep -qxF` +
  dir-prefix loop with `plan_scope::path_in_scope`. The benign-path +
  `is_benign` + `is_notable` + `SEVERE`/`NOTABLE` tier logic at lines
  368-391 stays UNCHANGED in scope-check.sh.

The wrappers preserve back-compat: existing `bin/scope-check-test.sh`
fixtures call `find_canonical_plan` and `extract_scope_section` directly;
the wrappers keep the names live.

**Source insertion site.** `bin/plan-scope.sh` is sourced after line 53
(`export PIPELINE_WRITER=scope-check`) in `bin/scope-check.sh`, before
the `_BENIGN_PATH_CLASSES` array at line 59. Pattern matches `common.sh`
sourcing at line 48: `# shellcheck source=plan-scope.sh` +
`source "$SCRIPT_DIR/plan-scope.sh"`.

**Test mechanism — the byte-for-byte assertion.**
`bin/plan-scope-test.sh` (NEW sibling test) constructs a fixture plan
body with edge cases (repo-root files like `CLAUDE.md`, nested paths,
dotfile directories like `.github/`, dotted-extension-named directories
that the awk filter at line 313-314 should NOT strip) and asserts:

- `plan_scope::parse_allowed_files` output is byte-equal to the snapshot
  fixture.
- `plan_scope::parse_allowed_dirs` output is byte-equal to the snapshot
  fixture.
- `plan_scope::path_in_scope` returns the same 0/1 verdict as the
  legacy per-file loop on a battery of test paths.
- Sourcing `bin/scope-check.sh` AND `bin/render-prompt.sh` both define
  `plan_scope::path_in_scope` (`declare -f plan_scope::path_in_scope`
  succeeds in both). This is the AC #4 structural assertion.

`bin/scope-check-test.sh` (existing): all current fixtures pass
unchanged (the refactor is behaviour-preserving). One new case asserts
the helper is sourced (`declare -f plan_scope::find_plan` succeeds).

**Reference to constraint.** CLAUDE.md "Language idioms": each `bin/foo.sh`
ends with the sentinel `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
main "$@"; fi`. `bin/plan-scope.sh` follows the pattern with `main()`
dispatching `find-plan` / `extract-section` / `parse-allowed-files` /
`parse-allowed-dirs` / `path-in-scope` sub-commands for manual CLI use.

**Reference to constraint.** Linear AC #4 "assert both call the same
function" — D-001 + the prompt-content test in D-008 are the structural
assertion.

**Rejected alternative — leave parse/match inline in `bin/scope-check.sh`
and have the render resolver re-execute `bin/scope-check.sh`.** Rejected
because (a) `scope-check.sh::main` has side effects (logs, exits with
non-zero on out-of-scope) — invoking it from render-prompt would either
pollute logs or require a new `--dry-run` / `--scope-info-only` flag
that's a parallel implementation of the helper; (b) the renderer needs
the PARSED SETS to embed in the prompt, not a yes/no verdict;
`scope-check.sh::main` computes the sets internally then discards them
after the per-file loop. Extracting is structurally cleaner than adding
a new output mode to `main`.

**Rejected alternative — duplicate the parse logic in
`bin/render-prompt.sh`.** Rejected per AC #4's structural assertion:
"reviewer-defer and scope-check-halt decisions cannot diverge."
Duplicated code drifts; the test `assert both call the same function`
becomes meaningless if both copies are statically identical at one
moment but drift on the next edit.

**Rejected alternative — bake the parse output into a JSON file on disk
that both callers read.** Rejected because (a) one more per-dispatch
artifact and one more freshness contract; (b) sourcing the same bash
file is the established shared-code idiom in `bin/common.sh`; (c) JSON
would require `jq` in the matcher hot path — `plan-scope.sh` stays
bash-only.

**Rejected alternative — keep the 2-arg `path_in_scope_or_benign`
convenience wrapper from the 2026-06-14 draft.** Rejected per operator
descope: the benign-path classes are D-007's second-resolver surface
(carve-out (b)), so the reviewer's prompt-side match consults ONLY the
plan structural sets. The validator's cross-check (D-005 rule 6)
verifies against the same plan-structural-only matcher; full agreement
with the prompt-side check.

### D-002. Reviewer §5 prompt gains a "Plan-scope adjudication" block that runs BEFORE the five-question rubric. On a major finding whose fix-target file is out-of-plan-scope, auto-classify `blocks_ship=false defer_reason="out-of-plan-scope"`; the rubric is bypassed for that finding. Critical findings still route through path B unconditionally (critical-floor invariant).

**Rationale.** Linear scope: "The reviewer/adjudicator computes, per
finding, whether the fix target falls within the plan's `## File
Structure`. A finding whose fix is out-of-plan-scope is emitted with
`blocks_ship=false` + reason `out-of-plan-scope` and excluded from the
loopback predicate."

**Where in §5.** Insert AFTER the "Deferability adjudication"
(AGENT_PROMPTS.md:1439-1480 — ENG-191's five-question rubric block) and
BEFORE the count-tuple emission (AGENT_PROMPTS.md:1481-1500). Correct
reading order:

1. Cold findings merged (existing).
2. Adjudication block (ENG-190 — severity only).
3. **NEW.** Plan-scope adjudication block — for each
   `adjudicated_severity ∈ {major, critical}` finding, extract the
   fix-target file from the finding's canonical anchor (the
   `path/to/file.ext:LINE` token mandated by the review-comment-quality
   rubric at AGENT_PROMPTS.md:1572-1586 as the first body token after
   the severity tag). Match the fix-target against the parsed sets
   rendered as `{plan_scope_allowed_paths}` (D-007 first resolver). The
   rendered token contains two section headers: `#ALLOWED_FILES#` (one
   path per line) and `#ALLOWED_DIRS#` (one directory prefix per line).
   Match rule: fix-target is **in-plan** iff (exact-match in
   `#ALLOWED_FILES#`) OR (has a prefix matching one entry in
   `#ALLOWED_DIRS#`). Benign-path classes are NOT consulted (deferred
   to ENG-194-B follow-up).

   If OUT-of-plan-scope:
   - For MAJOR: set `blocks_ship=false`,
     `defer_reason="out-of-plan-scope"`, and
     `ship_classification_rationale` to the EXACT shape
     `"out-of-plan-scope: <path> not in plan's File Structure"` (the
     `: <path>` colon-space-path tail is structurally required —
     validator D-005 rule 6 parses the path back out for cross-check
     via an anchored start+end regex). `decision_factors` MAY be
     omitted entirely or emitted as `null` — schema D-005 accepts both.
     SKIP the five-question rubric for that finding.
   - For CRITICAL: the critical-floor invariant
     (`bin/review-ledger-schema.sh:362-365`) UNCONDITIONALLY requires
     `blocks_ship=true`. The agent MAY emit
     `defer_reason="out-of-plan-scope"` on the row for audit (D-005
     permits it on `blocks_ship=true` rows as informational), but
     `blocking_majors > 0` → path B (loopback) fires unchanged. The
     implementer attempts the fix; scope-check.sh halts with
     `scope-violation`. Operator triages — this is the intentional
     ENG-180 backstop for criticals. **No operator-recipe meta-comment
     in this ticket** (deferred to ENG-194-C); recovery follows
     standard `docs/runbooks/recovery.md` paths.

4. Deferability adjudication (ENG-191 five-question rubric) — applies
   ONLY to findings not already classified by step 3.
5. Count-tuple emission (Findings:, Adjudicated:, Deferrable:).
6. Decision path (B / B′ / C / D).

The reviewer's existing review-comment-quality rubric (AGENT_PROMPTS.md
:1572-1586) MANDATES that every review comment carry a
`path/to/file.ext:LINE` anchor as its first body token after the
severity tag. The fix-target file is that path. The agent extracts it
by trimming the `:LINE` suffix.

**Multi-target findings — canonical-anchor rule.** Some findings span
multiple files (e.g. a contract drift naming both BE handler and FE
caller). The reviewer uses the CANONICAL anchor — the
`path/to/file.ext:LINE` token sitting immediately after the severity
tag, as mandated by the review-comment-quality rubric. That single
canonical path IS the fix-target for the plan-scope check; other paths
mentioned later in the finding body are informational and not
consulted. This collapses to the SINGLE source of truth the prompt
already enforces. If the canonical anchor's file is out-of-plan, the
finding is scope-deferred regardless of secondary mentions; if it's
in-plan, the rubric applies. Operators inspecting a deferred-majors
comment can re-read the underlying PR review comment to see the full
file list.

**Findings without a `file:line` anchor.** Rare but possible — e.g. a
security finding about absent code ("no rate-limit on `/api/login`").
For findings without a clear fix-target file (anchor absent or generic
like `<missing>:0`), the agent falls through to the five-question
rubric (existing ENG-191 path). These are not auto-deferred; the
agent's judgment via the rubric handles them. Documented as Edge case 5.

**Reference to constraint.** CLAUDE.md "AGENT_PROMPTS.md is load-bearing."
The new block sits inside §5's existing fenced body — no new H2 section,
no column-0 ``` fence, no change to `STAGE_TO_SECTION` in
`bin/render-prompt.sh`.

**Reference to constraint.** Linear AC #1 + AC #2 — the structural
classification + non-routing-to-loopback shape is what this prompt
block delivers. AC #3 — in-plan finding behaviour unchanged — is
preserved because the new block FALLS THROUGH to the existing rubric
when fix-target is in-plan.

**Rejected alternative — the plan-scope check is the FIRST step of the
deferability adjudication, replacing question 1 (`in_changed_code`).**
Rejected because (a) `in_changed_code` answers a different question
("did this PR's diff introduce or touch the defective code?") that
applies to in-plan findings too — losing the signal degrades the
ENG-191 rubric's quality; (b) ENG-191's five-question schema is the
rubric for in-plan findings whose judgment IS the deferability test;
scope-deferred is a SHORT-CIRCUIT that bypasses the rubric entirely,
not a replacement for one of its inputs.

**Rejected alternative — sanction the reviewer-requested out-of-scope
edit in `bin/scope-check.sh` when a matching review finding exists.**
Explicitly rejected by the Linear ticket as option (c): "weakens the
scope gate's guarantee and is hard to attribute reliably." The scope
gate stays strict; the reviewer adapts.

**Rejected alternative — in-band plan-File-Structure amendment proposed
by reviewer.** Linear option (b). Kept as future fallback; the reviewer
would emit a structured "plan addendum" proposal that the implementer
commits before fixing. Out of scope for ENG-194 because (a) it pushes
scope decisions into the agent loop; (b) it risks scope creep; (c) the
auto-defer path (option (a)) is materially simpler. Tracked in OQ-1.

**Rejected alternative — the critical+out-of-plan path posts an
operator-recipe meta-comment naming the file + the plan-amend + resume
sequence.** This was the 2026-06-14 draft's D-002 final paragraph.
Rejected per operator descope as carve-out (c). The critical residual
case reverts to standard operator triage via `docs/runbooks/recovery.md`;
recipe-style improvements are deferred to ENG-194-C.

### D-003. Add per-finding `defer_reason: "out-of-plan-scope" | "rubric"` to the ledger row schema. Required on `blocks_ship=false adjudicated_severity=major` rows; optional on others.

**Rationale.** The ledger row is already the per-finding decision record
(ENG-191 D-002). Adding `defer_reason` keeps the adjudicator's
per-finding output unified. Distinct from `ship_classification_rationale`
(free-form prose sentence): `defer_reason` is a closed-vocabulary token
the orchestrator and validator can branch on.

**Schema extension (additive, v1 stays).** ONE new optional field:

```json
{
  "ledger_schema_version": 1,
  "issue_id": "ENG-194",
  "dispatch_id": "ENG-194-d0003",
  "iteration": 1,
  "created_at": "2026-06-16T12:00:00Z",
  "finding_class_key": "doc-drift:docs/install.md:setup-phase",
  "cold_severity": "major",
  "adjudicated_severity": "major",
  "decision": "request-changes",
  "rationale": "docs/install.md drifted from bin/setup.sh changes",
  "blocks_ship": false,
  "ship_classification_rationale": "out-of-plan-scope: docs/install.md not in plan's File Structure",
  "defer_reason": "out-of-plan-scope",
  "decision_factors": null
}
```

**Field contract:**

- `defer_reason` — string, one of `"out-of-plan-scope"` or `"rubric"`.
  - **Required** on rows where `blocks_ship == false` AND
    `adjudicated_severity == "major"` AND `dispatch_id == --dispatch-id`
    (this-dispatch row; schema-grace exempts prior-dispatch rows from
    the new contract per ENG-191 D-002 inheritance).
  - **Optional on critical rows.** The critical-floor invariant rules:
    a critical row with `blocks_ship=false` is already rc=49
    (`critical-floor-blocks-ship-violation`); a critical row with
    `blocks_ship=true` doesn't need a defer reason. Both states are
    covered without `defer_reason`. Agents MAY emit
    `defer_reason="out-of-plan-scope"` on a `blocks_ship=true` critical
    row for audit (documenting "this scope-traps the implementer") —
    validator accepts.
  - **Optional and informational on `blocks_ship=true` major rows** —
    agents MAY emit `defer_reason="out-of-plan-scope"` to record "this
    scope-traps the implementer" even when severity-blocks (e.g. a
    critical upgraded from a major) so the operator can see the trap.
    Validator does not require it on `blocks_ship=true`.
  - **Omitted on minor/nit rows** (those rows don't carry `blocks_ship`
    per ENG-191 D-002; `defer_reason` has no semantic).

- `decision_factors` — ENG-191 D-002 required this on every major row.
  ENG-194 RELAXES: when `defer_reason == "out-of-plan-scope"`,
  `decision_factors` MAY be `null` or omitted. When `defer_reason ==
  "rubric"` (default for ENG-191-shape rows), `decision_factors` is
  still required with all five keys per ENG-191. The validator's
  existing `decision_factors`-required check at
  `bin/review-ledger-schema.sh:375-390` is gated on `defer_reason !=
  "out-of-plan-scope"`.

**Why a new field, not overloading `ship_classification_rationale`.**
Three reasons:

1. **Branching predicate.** D-004's convergence-rounds bypass needs the
   orchestrator + the agent to branch on a *token*, not a prefix-string
   match. Closed vocabulary is debuggable; prose prefix matches drift
   (today `"out-of-plan-scope: foo"`, tomorrow `"scope-deferred (foo)"`).
2. **Validator clarity.** The validator's `defer_reason`-conditional
   check (relax `decision_factors` requirement) reads cleanly when
   testing one field; a prefix-match against
   `ship_classification_rationale` is fragile.
3. **Retrospective signal.** The flywheel (ENG-189) wants to count
   `out-of-plan-scope` defers separately from rubric defers to tune
   the plan-author's coverage expectations. A single field makes the
   count one jq filter.

**Backwards compatibility with ENG-191 rows.** Pre-ENG-194 ledger rows
(written by issues mid-flight at ENG-194 rollout cutover) lack
`defer_reason`. The schema-grace clause from ENG-191 D-002 already
gates by `dispatch_id == --dispatch-id` so prior-dispatch rows are
validated against the pre-ENG-194 contract regardless. This-dispatch
rows MUST emit `defer_reason` on the `blocks_ship=false major` shape
per the validator rule in D-005. ENG-194 inherits this — no new grace
mechanic.

**Reference to constraint.** CLAUDE.md "Don't add features beyond what
the task requires." One new field maps directly to AC #1's
`reason=out-of-plan-scope` requirement. The closed vocabulary (two
values) is the minimum that discriminates the two structural cases.

**Reference to constraint.** ENG-190/ENG-191 `ledger_schema_version=1`
posture preserved — additive-optional field with documented
default-when-absent semantics.

**Rejected alternative — overload `ship_classification_rationale` with
`"out-of-plan-scope:..."` prefix.** Per the "Why a new field" section
above.

**Rejected alternative — bump to `ledger_schema_version: 2` to make
`defer_reason` mandatory on every `blocks_ship=false` row.** Rejected
because (a) ENG-191 D-002 already documented why v2 doubles the
validator surface; (b) the `defer_reason` field's default-when-absent
semantics make v1 + default-rule strictly less complex than a v2 bump;
(c) prior-dispatch rows from ENG-191 issues mid-flight will flow
through the default cleanly.

**Rejected alternative — new file `review-scope-defers.jsonl` sibling
to the ledger.** Rejected because (a) one more per-issue artifact, one
more validator; (b) the ledger row IS the per-finding decision record;
splitting based on `defer_reason` cross-cuts the contract.

### D-004. The path-D selective-exit predicate is EXTENDED to allow scope-deferred-only exits at iteration 1 (no convergence-rounds gate). Mixed scope-defer + rubric-defer still requires the convergence plateau.

**Rationale.** Linear AC #5: "The ENG-27-class scenario (`bin/setup.sh`
changed in-plan, its doc `docs/install.md` flagged stale but
out-of-plan) advances instead of deadlocking — end-to-end fixture."

Today's ENG-191 predicate (AGENT_PROMPTS.md:1617-1620):

```
Path D (ship-with-debt) — fires iff
  Adjudicated critical == 0
  AND Adjudicated major > 0
  AND blocking_majors == 0
  AND convergence_rounds_at_zero_critical >= {review_converge_rounds}.
```

The convergence-rounds gate exists because rubric-deferred findings
are **agent judgments** that benefit from cross-iteration stability
evidence — "if it's still deferrable 2 rounds later, the agent's
judgment held up." Scope-deferred findings are **structural facts** —
the fix is impossible in this plan's scope regardless of how many
rounds pass. The convergence-rounds gate adds no information about
scope-deferred findings.

**Extended predicate (ENG-194):**

```
Path D (ship-with-debt) — fires iff
  Adjudicated critical == 0
  AND Adjudicated major > 0
  AND blocking_majors == 0
  AND ( convergence_rounds_at_zero_critical >= {review_converge_rounds}
        OR  every adjudicated-major row has defer_reason == "out-of-plan-scope" ).

Path B′ (convergence-waiting) — fires iff
  Adjudicated critical == 0
  AND Adjudicated major > 0
  AND blocking_majors == 0
  AND convergence_rounds_at_zero_critical < {review_converge_rounds}
  AND at least one adjudicated-major row has defer_reason == "rubric".
```

(The path B′ predicate is the implicit complement: if path D's extended
OR is TRUE, B′ does not fire even at low convergence rounds.)

**The OR is structurally safe.**

- If ALL deferred majors are scope-deferred, the implementer CANNOT fix
  any of them in this PR (each fix would self-leak past
  `scope-check.sh`). One round of stability is sufficient because no
  further iterations would change the deferred status.
- If ANY deferred major is rubric-deferred, the agent's judgment is at
  stake and the existing convergence-rounds gate applies (the mixed
  case still waits N rounds).
- Critical-floor still applies (any critical → `blocks_ship=true` →
  `blocking_majors > 0` → predicate fails).

**Worked examples:**

- **ENG-27 scenario (iter 1).** Reviewer finds 1 major,
  `docs/install.md` stale. Fix-target out-of-plan. Agent emits
  `Deferrable: (deferrable_majors=1, blocking_majors=0)` with
  `defer_reason="out-of-plan-scope"`. `convergence_rounds=0`. Extended
  OR: every deferred major is `out-of-plan-scope` → path D fires →
  `reviewing → qa`. No deadlock. AC #5 satisfied.
- **Mixed case (iter 1).** Reviewer finds 2 majors — 1 scope-deferred,
  1 rubric-deferred. `blocking_majors=0`, but one row is
  `defer_reason="rubric"`. Extended OR: NOT every deferred major is
  scope-deferred → falls through to convergence-rounds gate →
  `convergence_rounds=0 < N=2` → path B′ (loopback without bumping
  `review_rejection`, per ENG-191 D-008). Next iter: re-evaluate. The
  rubric-deferred finding's stability earns the exit; the
  scope-deferred one rides along.
- **Critical case.** Reviewer finds 1 critical, fix out-of-plan.
  Critical-floor: `blocks_ship=true` → `blocking_majors=0` but
  `Adjudicated critical=1` → path B (loopback). Implementer attempts;
  scope-check.sh halts with `scope-violation`. Operator triages —
  intentional ENG-180 backstop for criticals.

**Per-agent prompt change.** AGENT_PROMPTS.md §5 mechanical-predicates
block (lines 1614-1620) needs a small amendment to path D's predicate
and path B′'s implicit-complement formulation:

```
- Path D (ship-with-debt) — fires iff
    Adjudicated critical == 0 AND Adjudicated major > 0 AND blocking_majors == 0
    AND ( convergence_rounds_at_zero_critical >= {review_converge_rounds}
          OR  every adjudicated-major row has defer_reason == "out-of-plan-scope" ).
- Path B′ (convergence-waiting) — fires iff
    Adjudicated critical == 0 AND Adjudicated major > 0 AND blocking_majors == 0
    AND convergence_rounds_at_zero_critical < {review_converge_rounds}
    AND  at least one adjudicated-major row has defer_reason == "rubric".
```

The path-D verbose body at AGENT_PROMPTS.md:1670 ("To ship with
deferred majors (path D — Adjudicated critical=0, all adjudicated
majors deferrable, convergence rounds satisfied)") gets the OR
extension appended to its parenthetical predicate for consistency.

**No code change to `bin/verdict-handler.sh`.** Path D still emits
`verdict pass --stage reviewing --reason ship-with-deferred-majors`;
the forward transition `reviewing → qa` is unchanged from ENG-191.
The orchestrator's `_post_deferred_majors_comment_if_eligible`
(`bin/run-stage.sh:1483-1561`) reads ledger rows where `blocks_ship=
false` regardless of `defer_reason` — both out-of-plan-scope and
rubric-deferred findings appear in the comment as flat bullets.
Distinguishing them in the comment body is D-006's surface, deferred
to ENG-194-A; AC #2 ("not silently dropped") is satisfied by the row
appearing in the comment at all.

**Reference to constraint.** Linear scope: "auto-deferred, never looped
back" — the predicate change is the structural mechanism that prevents
the loopback at iteration 1 when every deferral is scope-driven. AC #1
+ AC #5 demand this.

**Rejected alternative — bypass convergence-rounds for ANY scope-
deferred finding (even mixed case).** Rejected because (a) the
rubric-deferred finding's stability is still load-bearing for the
mixed case (the agent's judgment may flip round-to-round; the gate
protects against premature shipping of an agent-judgment-mistake);
(b) the mixed case is rare in practice — most ENG-27-class incidents
have either ALL-scope or ALL-rubric majors. The OR-conjunction is the
cleanest expression of "scope-deferred alone is sufficient; mixed
cases still need stability evidence."

**Rejected alternative — bypass convergence-rounds whenever ANY
finding is scope-deferred AND convergence_rounds >= 0 (effectively
disabling the gate).** Same reason as above.

### D-005. Schema validator (`bin/review-ledger-schema.sh`) extension — known-field `defer_reason`, closed-vocabulary check, conditional `decision_factors` requirement based on `defer_reason`, and a structural cross-check that the agent's `defer_reason="out-of-plan-scope"` claim agrees with the matcher's verdict on the same plan. No new exit code (uses existing rc=49 incomplete).

**Rationale.** AC #1 requires that an out-of-plan-scope finding is
classified `blocks_ship=false reason=out-of-plan-scope`; the validator
is the structural enforcement layer. AC #4's "cannot diverge" is the
cross-check's reason for being — without it, the agent's claim is
unaudited.

**Validation rules added (in `cmd_validate`, after the existing
ENG-191 critical-floor-blocks-ship block at lines 362-365):**

1. **`defer_reason` closed-vocabulary check.** When present, MUST be
   `"out-of-plan-scope"` or `"rubric"`. Unknown values:

   ```bash
   local dr_type dr_val
   dr_type="$(jq -r '.defer_reason | type' <<<"$line" 2>/dev/null || printf 'missing')"
   if [[ "$dr_type" != "null" && "$dr_type" != "missing" ]]; then
     dr_val="$(jq -r '.defer_reason' <<<"$line" 2>/dev/null || printf '')"
     if [[ "$dr_val" != "out-of-plan-scope" && "$dr_val" != "rubric" ]]; then
       _emit_incomplete "$line_no" "defer_reason must be 'out-of-plan-scope' or 'rubric' (closed vocabulary), got '$(sanitise_for_diag "$dr_val")'" "$fck"
       return 49
     fi
   fi
   ```

2. **`defer_reason` required on `blocks_ship=false` major this-dispatch
   rows.** When `adjudicated_severity == "major"` AND `blocks_ship ==
   false` AND `dispatch_id == --dispatch-id` (the schema-grace clause
   already in place from ENG-191 D-002), `defer_reason` MUST be
   present. Pre-ENG-194 rows on issues mid-flight at rollout cutover
   are exempt (their `dispatch_id` differs from `--dispatch-id`).
   For this-dispatch rows, absence → rc=49 incomplete with diagnostic
   `defer_reason-missing-on-deferred-major: adjudicated_severity=major
   blocks_ship=false`.

3. **`decision_factors` conditional requirement.** The existing ENG-191
   check at `bin/review-ledger-schema.sh:375-390` requires
   `decision_factors` as an object with all five keys on every
   `adjudicated_severity ∈ {major, critical}` this-dispatch row.
   ENG-194 RELAXES: when `defer_reason == "out-of-plan-scope"` on the
   row, `decision_factors` MAY be `null` or absent (the five-question
   rubric was bypassed). Implementation:

   ```bash
   # ... after the existing critical-floor-blocks-ship check at line 365 ...
   local dr_val_for_df
   dr_val_for_df="$(jq -r '.defer_reason // ""' <<<"$line")"
   if [[ "$dr_val_for_df" == "out-of-plan-scope" ]]; then
     # ENG-194: scope-deferred findings bypass the rubric. Skip the
     # decision_factors-required check below.
     :
   else
     # Existing ENG-191 decision_factors-required check unchanged
     # (lines 375-390).
     ...
   fi
   ```

4. **`ship_classification_rationale` non-empty.** Existing ENG-191
   check at lines 367-374 already requires non-empty on every
   `blocks_ship`-bearing row. ENG-194 inherits unchanged; no new rule.

5. **Add `defer_reason` to known-fields allowlist.** Extend the inline
   jq `(keys) - [...]` allowlist expression at
   `bin/review-ledger-schema.sh:404` to include `defer_reason`.
   Without this, every ledger row carrying the new field would emit a
   `_warn_unknown` "unknown ledger-row field: defer_reason" warning to
   stderr (noisy but non-blocking). There is no separate
   top-of-file documented permitted-fields comment — the inline jq
   expression is the single source of truth.

   (Note for implementers: assumption #16 in §11 pins the line number
   `404` as the location of the allowlist; the 2026-06-14 draft's
   iter-1-of-d0002 corrected an earlier draft that cited the wrong
   lines. Re-verify at implementation time in case patches have
   shifted the line number.)

6. **Validator cross-check: `defer_reason="out-of-plan-scope"` claim
   must agree with the matcher's verdict (security defense-in-depth).**
   For each this-dispatch row where `defer_reason == "out-of-plan-
   scope"`, the validator parses the fix-target out of
   `ship_classification_rationale` (D-002 mandates the EXACT shape
   `"out-of-plan-scope: <path> not in plan's File Structure"` —
   anchored start-AND-end-of-string, no trailing prose). The regex
   below uses `^...$` anchoring so an adversarial rationale with
   prefix-match-but-trailing-prose (e.g.
   `"out-of-plan-scope: /etc/passwd not in plan but actually-in-plan-file/foo.sh"`)
   fails to parse and triggers the fail-CLOSED branch.

   ```regex
   ^out-of-plan-scope:[[:space:]]+([^[:space:]]+)[[:space:]]+not in plan's File Structure$
   ```

   The validator then sources `bin/plan-scope.sh` and re-runs the
   matcher on the parsed path against the canonical plan for
   `--ident`. The matcher is the PLAN-STRUCTURAL `plan_scope::
   path_in_scope` (3-arg form) — does NOT consult any benign-path
   classes or stack-conditional carve-outs. This matches the
   reviewer's prompt-side check (D-002 step 3): both callers verify
   the same predicate. If the matcher's verdict is IN-scope (i.e. the
   agent's claim is FALSE), emit rc=49 with diagnostic
   `defer-reason-claim-disagrees-with-plan-scope: agent claimed
   out-of-plan-scope but matcher classifies path=<sanitised> as
   IN-plan`.

   **Fail-CLOSED on unparseable rationale.** When `defer_reason ==
   "out-of-plan-scope"` AND the rationale does not match the anchored
   regex, the validator emits rc=49 with diagnostic
   `out-of-plan-scope-rationale-malformed: defer_reason=out-of-plan-
   scope but rationale does not match the mandated shape "<sanitised>"`.
   The prompt mandates the exact shape (D-002 step 3); an unparseable
   rationale IS a contract violation, not a benign edge case.
   Fail-open would be a forge surface — an agent could emit
   ill-formed rationale to skip the matcher cross-check entirely.
   Fail-closed forces the agent to either emit the canonical shape
   (which the matcher then verifies) or trip the validator.

   ```bash
   # In cmd_validate, after the closed-vocabulary check at rule 1:
   if [[ "$dr_val" == "out-of-plan-scope" ]] && [[ -n "$dispatch_id_flag" && "$did_val" == "$dispatch_id_flag" ]]; then
     local scr fix_target worktree_root plan body af ad
     scr="$(jq -r '.ship_classification_rationale // ""' <<<"$line" 2>/dev/null || printf '')"
     # Anchored start+end (^...$): trailing-prose forgery fails the parse.
     fix_target="$(printf '%s' "$scr" \
       | sed -nE "s/^out-of-plan-scope:[[:space:]]+([^[:space:]]+)[[:space:]]+not in plan's File Structure\$/\1/p")"
     if [[ -z "$fix_target" ]]; then
       # FAIL-CLOSED on unparseable rationale.
       _emit_incomplete "$line_no" "out-of-plan-scope-rationale-malformed: defer_reason=out-of-plan-scope but rationale does not match mandated shape, got '$(sanitise_for_diag "$scr")'" "$fck"
       return 49
     fi
     # Source the shared helper + run matcher against the canonical plan.
     # shellcheck source=plan-scope.sh
     source "$SCRIPT_DIR/plan-scope.sh"
     worktree_root="$(git rev-parse --show-toplevel 2>/dev/null || printf '%s' "${TARGET_REPO-}")"
     plan="$(plan_scope::find_plan "$ident" "$worktree_root" 2>/dev/null || printf '')"
     if [[ -z "$plan" ]]; then
       # Plan absent — the renderer's plan-absent fallback (D-007 soft-
       # fail) emitted empty allowed-paths sets, so the agent should
       # have fallen through to the rubric for every finding. Logging
       # a soft warning and PASSING the row preserves operability when
       # the operator deletes the plan between dispatches.
       log "[review-ledger-schema] cross-check: plan absent for $ident; skipping matcher verification on row $line_no" >&2
     else
       body="$(plan_scope::extract_section "$plan" 2>/dev/null || printf '')"
       af="$(plan_scope::parse_allowed_files "$body" 2>/dev/null || printf '')"
       ad="$(plan_scope::parse_allowed_dirs "$body" 2>/dev/null || printf '')"
       if plan_scope::path_in_scope "$fix_target" "$af" "$ad"; then
         _emit_incomplete "$line_no" "defer-reason-claim-disagrees-with-plan-scope: agent claimed out-of-plan-scope but matcher classifies path=$(sanitise_for_diag "$fix_target") as IN-plan" "$fck"
         return 49
       fi
     fi
   fi
   ```

   **Scope of the cross-check.** The cross-check verifies the agent's
   claim against the PLAN-STRUCTURAL matcher (`plan_scope::
   path_in_scope`), NOT against `bin/scope-check.sh`'s full
   `is_benign` (which includes stack-conditional
   `SCOPE_BENIGN_LOCKFILES` + Rust crates-tests carve-out). For a path
   that is out-of-plan per the matcher BUT in the
   stack-conditional-benign-set per `scope-check.sh` (e.g. a
   `Cargo.lock` review finding), the matcher confirms out-of-plan,
   validator passes — even though the implementer COULD have fixed
   the lockfile via `scope-check.sh::is_benign`. This is the
   documented divergence per Edge case 8 / OQ-2: the reviewer's
   structural match is intentionally STRICTER than scope-check's
   runtime gate. Closing the gap requires moving stack-conditional
   inference into the shared helper — bounded follow-up (ENG-194-B).

**No new exit code.** The ENG-190 validator uses 48/49/50. ENG-194's
new rules all map to rc=49 incomplete. No new halt reason — the
existing `review-ledger-invalid` covers ENG-190+ENG-191+ENG-194
violations. CLAUDE.md "Never use exit codes outside the taxonomy"
honoured.

**Reference to constraint.** ENG-190/ENG-191 D-009 sanitisation
contract (`<!-- → <\!--` + `\n,\r → space`) applies to all new
agent-controlled string interpolation via `sanitise_for_diag`
(`bin/review-ledger-schema.sh:115-121`). `defer_reason` is closed-
vocabulary (no agent prose), but the diagnostic for rule 6 embeds the
agent-controlled `fix_target` and `scr` — both go through
`sanitise_for_diag` per the snippet above.

**Adversarial test cases** (added to
`bin/review-ledger-schema-adversarial-test.sh`):

- **AC-AD-10.** Row with `adjudicated_severity=major, blocks_ship=
  false, defer_reason="out-of-plan-scope", decision_factors:null,
  ship_classification_rationale="out-of-plan-scope: docs/install.md
  not in plan's File Structure"` (path out-of-plan in fixture) →
  rc=0 valid (rubric bypass + cross-check OK).
- **AC-AD-11.** Row with `adjudicated_severity=major, blocks_ship=
  false, defer_reason="rubric", decision_factors:null` → rc=49
  incomplete (`decision_factors must be object` — ENG-191 rule still
  fires).
- **AC-AD-12.** Row with `adjudicated_severity=major, blocks_ship=
  false, defer_reason="bogus-token"` → rc=49 with closed-vocabulary
  diagnostic (rule 1).
- **AC-AD-13.** Row with `adjudicated_severity=major, blocks_ship=
  false, defer_reason missing` (this-dispatch row) → rc=49 with
  `defer_reason-missing-on-deferred-major` (rule 2).
- **AC-AD-14.** Row with `adjudicated_severity=critical, blocks_ship=
  true, defer_reason="out-of-plan-scope"` → rc=0 valid (informational
  on critical+blocking; critical-floor invariant still holds).
- **AC-AD-15.** Row with `defer_reason="out-of-plan-scope"` and
  `ship_classification_rationale="out-of-plan-scope: /etc/passwd not
  in plan but bin/setup.sh"` (trailing prose) → rc=49 incomplete
  with `out-of-plan-scope-rationale-malformed` (rule 6 fail-CLOSED
  anchored regex).
- **AC-AD-16.** Row with `defer_reason="out-of-plan-scope"` and
  `ship_classification_rationale="out-of-plan-scope: bin/setup.sh not
  in plan's File Structure"` BUT the fixture plan IS scoping
  `bin/setup.sh` → rc=49 incomplete with
  `defer-reason-claim-disagrees-with-plan-scope` (rule 6 matcher
  cross-check disagreement). Validates the structural defense against
  forged claims.
- **AC-AD-17.** Row with `defer_reason="out-of-plan-scope"`,
  malformed rationale, but `dispatch_id != --dispatch-id`
  (prior-dispatch row) → rc=0 valid (schema-grace exemption).
- **AC-AD-18.** Plan-absent fixture (`$TARGET_REPO/docs/plans/` has no
  matching frontmatter) → rule 6 logs `cross-check: plan absent`
  warning to stderr, row PASSES validation. Validates the documented
  plan-absent soft-fail behaviour.

**Reference to constraint.** Linear AC #4 "assert both call the same
function" — D-001 provides the shared helper; D-005 rule 6 + the
prompt-content test in D-008 are the assertions that both callers
verify the SAME predicate. The helper is the single source of truth.

**Rejected alternative — bump `ledger_schema_version` to 2.** Rejected
per the additive-v1 reasoning in D-003.

**Rejected alternative — separate validator file
`bin/review-defer-reason-schema.sh`.** Rejected because (a) one file,
one validator, one detective slot — sprawl rejected per ENG-191
precedent; (b) the ledger row IS the per-finding decision record;
splitting cross-cuts the contract.

**Rejected alternative — fail-OPEN on unparseable rationale (the
2026-06-14 draft's pre-iter-1-of-d0002 shape).** Rejected because
fail-open is a forge surface: an adversarial agent could emit
ill-formed `ship_classification_rationale` to skip the matcher
cross-check entirely. Fail-closed binds the agent to the canonical
shape mandated by D-002.

**Rejected alternative — drop the cross-check entirely and trust the
agent's claim.** Rejected because AC #1 + AC #4 + AC #5 all rely on
the agent's claim being correct; the cross-check is the structural
enforcement layer. v1 ships with the cross-check as documented; future
hardening is OQ-3 (plan-mutation defense — bounded follow-up).

### D-007 (first resolver only). A new `bin/render-prompt.sh` resolver `{plan_scope_allowed_paths}` renders the parsed plan File Structure into the reviewer's prompt. Non-path token; no sidecar entry. The second resolver (`{plan_scope_benign_path_classes}`) from the 2026-06-14 draft is OUT per operator descope and tracked as ENG-194-B.

(This decision retains its original D-007 label for traceability with
the 2026-06-14 draft; the descope removes only the second resolver.)

**Rationale.** D-002 needs the reviewer to know the parsed
`allowed_files` / `allowed_dirs` at dispatch time. The token-render
mechanism is the established path
(`bin/render-prompt.sh::PROMPT_RESOLVERS` registry at lines 40-62).

**Resolver body.**

```bash
# In PROMPT_RESOLVERS registry (added after review_converge_rounds at line 62):
plan_scope_allowed_paths=_resolve_plan_scope_allowed_paths

# Resolver body (added after _resolve_review_converge_rounds at line 303):
# ENG-194: render the parsed plan File Structure into the prompt as
# two newline-separated sets. Shape:
#   #ALLOWED_FILES#
#   <file1>
#   <file2>
#   #ALLOWED_DIRS#
#   <dir1>/
#   <dir2>/
# Both sections always emit (even when empty), so the prompt-side
# match logic can branch on absence.
# On absent plan / unparseable section, emits the two headers with
# empty bodies and logs a warning — soft-fail (the reviewer falls
# through to the five-question rubric for every finding, which is
# the safe-default ENG-191 behaviour).
_resolve_plan_scope_allowed_paths() {
  local issue_id="$_RENDER_ISSUE_ID"
  local worktree_root
  worktree_root="$(git rev-parse --show-toplevel 2>/dev/null || printf '%s' "${TARGET_REPO-}")"
  # shellcheck source=plan-scope.sh
  source "$SCRIPT_DIR/plan-scope.sh"
  local plan body af ad
  plan="$(plan_scope::find_plan "$issue_id" "$worktree_root" 2>/dev/null)"
  if [[ -z "$plan" || ! -f "$plan" ]]; then
    log "[render] plan_scope_allowed_paths: no plan for $issue_id; emitting empty sets" >&2
    printf '#ALLOWED_FILES#\n#ALLOWED_DIRS#\n'
    return 0
  fi
  body="$(plan_scope::extract_section "$plan" 2>/dev/null)"
  if [[ -z "$body" ]]; then
    log "[render] plan_scope_allowed_paths: empty File Structure section in $plan; emitting empty sets" >&2
    printf '#ALLOWED_FILES#\n#ALLOWED_DIRS#\n'
    return 0
  fi
  af="$(plan_scope::parse_allowed_files "$body" 2>/dev/null)"
  ad="$(plan_scope::parse_allowed_dirs "$body" 2>/dev/null)"
  {
    printf '#ALLOWED_FILES#\n'
    printf '%s\n' "$af"
    printf '#ALLOWED_DIRS#\n'
    printf '%s\n' "$ad"
  }
}
```

**Soft-fail discipline.** When the resolver can't find the plan or the
section is empty, it emits the two headers with empty bodies (NOT
die). The reviewer's prompt block (D-002) checks whether both sets are
empty and falls through to the five-question rubric for every major
finding — degraded mode, but not blocked. The log warning surfaces the
degradation in `$PROJECT_STATE_DIR/<slug>/logs/<ident>-reviewing-*.log`.

**Sidecar entry.** Add `plan_scope_allowed_paths` to
`_write_rendered_paths_sidecar` (`bin/render-prompt.sh:94-127`)? **No.**
The resolver's output is NOT a single path (it's a structured manifest
of paths). The sidecar's contract per ENG-156 D-004 is "closed
allowlist of path-shaped tokens"; this resolver emits a multi-line
manifest. Treat like `{review_converge_rounds}` (also non-sidecar per
ENG-191 D-010 comment at `bin/render-prompt.sh:290-291`).

**Reference to constraint.** CLAUDE.md "AGENT_PROMPTS.md is load-bearing."
The new token is added to the existing resolver registry; render-prompt's
residual unknown-token validator at `bin/render-prompt.sh:451`
(`die "render-prompt: unknown token '$t' in source — register a
resolver in PROMPT_RESOLVERS"`) accepts the new registered token and
substitutes correctly.

**Reference to constraint.** ENG-156 D-004 — sandbox-denial detective
sidecar surface. The non-path nature of this resolver's output
justifies the sidecar exclusion.

**Rejected alternative — render the resolved sets as JSON.** Rejected
because (a) the agent already reads structured prompt content as plain
text; (b) JSON in the prompt would require the agent to parse it,
which is a fresh prompt complexity surface; (c) the section-header
newline-separated shape is the simplest prompt-side branchable format.

**Rejected alternative — render only the COMPILED MATCH OUTPUT (yes/no
per finding).** Rejected because the renderer doesn't know the findings
at render time; they emerge in-prompt during the cold-pass and
adjudication.

**Rejected alternative — include the stack-agnostic benign-path classes
as a second resolver `{plan_scope_benign_path_classes}` (the
2026-06-14 draft's D-007 second resolver).** Rejected per operator
descope as carve-out (b). The reviewer's prompt-side check operates on
plan-structural sets only; benign-path-finding cases auto-defer to
known debt (bounded acceptable per §6 Edge case 8). Closing the
divergence is ENG-194-B's follow-up.

### D-008. Prompt-content test + sibling tests assert byte-for-byte agreement (AC #4) and the five Linear ACs end-to-end.

**Rationale.** AC #1 through AC #5 demand structural fixtures.

**`bin/plan-scope-test.sh` (NEW — sibling test for D-001).**

- Test 1: `plan_scope::parse_allowed_files` snapshot on a curated
  fixture plan body (repo-root files, nested paths, dotfile dirs,
  dotted-extension dir-prefix anti-pattern) matches a frozen expected
  output byte-for-byte.
- Test 2: `plan_scope::parse_allowed_dirs` snapshot, same fixture body.
- Test 3: `plan_scope::path_in_scope` yes/no verdict on a battery of
  probe paths (exact match, dir-prefix match, no match,
  prefix-substring-but-not-actual-dir, dotfile dir, repo-root file)
  returns the expected 0/1.
- Test 4: source `bin/scope-check.sh` and assert `declare -f
  plan_scope::path_in_scope` succeeds (proves the helper is wired into
  the scope-check.sh refactor). Same assertion against
  `bin/render-prompt.sh`.
- Test 5: end-to-end byte-for-byte assertion — construct a fixture
  plan; run scope-check.sh's parse step (via the refactored path);
  run the new resolver's parse step (via
  `_resolve_plan_scope_allowed_paths` with `_RENDER_ISSUE_ID` set);
  assert their parsed `allowed_files` / `allowed_dirs` byte-equal.
  This is the AC #4 structural assertion.

**`bin/scope-check-test.sh` (EXISTING — extended).**

- All existing fixtures pass unchanged (the refactor is behaviour-
  preserving).
- New test: `bin/scope-check.sh` sources `bin/plan-scope.sh` (assert
  via `declare -f`).

**`bin/review-ledger-schema-adversarial-test.sh` (EXISTING —
extended).**

- AC-AD-10 through AC-AD-18 from D-005's adversarial cases.

**`bin/agent-prompts-content-test.sh` (EXISTING — extended).** Seven
prompt-content pins:

- Pin #1: §5 contains the literal phrase "Plan-scope adjudication"
  (the block heading).
- Pin #2: §5 references `{plan_scope_allowed_paths}` token.
- Pin #3: §5 contains the literal phrase `defer_reason="out-of-plan-
  scope"`.
- Pin #4: §5 documents that out-of-plan-scope rows OMIT
  `decision_factors` AND PERMITS `null` (the relaxation rule —
  assert BOTH literal substrings "OMITTED" and "null" appear).
- Pin #5: §5's path-D predicate contains the extended OR clause
  (`OR  every adjudicated-major row has defer_reason == "out-of-plan-
  scope"`).
- Pin #6: §5's plan-scope-adjudication block is positioned BEFORE the
  count-tuple emission (positional check by line-number ordering —
  block heading appears before the `Findings:` heading line in §5).
- Pin #7: §5 contains the multi-target finding tie-break rule
  (canonical anchor is the SOLE fix-target).

**`bin/render-prompt-test.sh` (EXISTING — extended).**

- Sibling test for the new resolver: token resolves to a non-empty
  payload when a fixture plan with File Structure exists; empty-header
  payload on missing plan; soft-fail log warning visible on the empty
  path.
- Assert the token shape is exactly `#ALLOWED_FILES#\n...\n#ALLOWED_DIRS#\n...\n`
  (snapshot test).

**`bin/run-stage-test.sh` (EXISTING — extended).** End-to-end fixtures
for AC #1, #2, #5:

- **AC #1 fixture.** Construct a fixture ledger with one this-dispatch
  row: `adjudicated_severity=major, blocks_ship=false, defer_reason=
  "out-of-plan-scope", ship_classification_rationale="out-of-plan-
  scope: docs/install.md not in plan's File Structure"`. Construct a
  fixture verdict marker with `reason=ship-with-deferred-majors`.
  Assert `_post_deferred_majors_comment_if_eligible` posts the
  deferred-majors comment with the body containing the bullet matching
  the row (the comment shape is ENG-191's flat-list — D-006 grouping
  is deferred). AC #2 ("not silently dropped") is satisfied by the
  row appearing in the comment.
- **AC #3 fixture.** Construct a fixture with one in-plan major row
  (`defer_reason="rubric"`). Assert the rubric-deferred bullet is
  rendered with the five decision factors (regression test — ENG-191
  D-005 behaviour preserved).
- **AC #5 (ENG-27-class) end-to-end fixture.** Construct a worktree
  fixture with `docs/plans/.../plan.md` scoping only `bin/setup.sh`,
  a feature branch diff modifying only `bin/setup.sh`, and a
  synthesised ledger row with the `docs/install.md` scope-deferred
  finding. Assert the agent's decision-path output (the count-tuple
  line + verdict marker) selects path D, the verdict marker carries
  `reason=ship-with-deferred-majors`, and the orchestrator posts the
  deferred-majors comment with the scope-deferred bullet. (Heavily
  mocked — the agent's in-prompt arithmetic is asserted via the
  COUNT-TUPLE line shape, not by running `claude -p` itself; ENG-191
  D-008 prior art for prompt-content rather than runtime-execution
  testing.)

**Reference to constraint.** CLAUDE.md "Tests" section — sibling shell
scripts, sourceable via the sentinel. New `bin/plan-scope.sh` follows
the same pattern.

**Rejected alternative — a single end-to-end fixture that exercises
every AC.** Rejected because (a) end-to-end fixtures are heavy; each
AC is structurally distinct; (b) fast feedback on a single AC's
regression is more useful than a single omnibus fixture.

## 3. Architecture (where code goes)

```
bin/plan-scope.sh                       NEW (~120 lines).
                                        Sourced by bin/scope-check.sh,
                                        bin/render-prompt.sh, AND
                                        bin/review-ledger-schema.sh
                                        (D-005 rule 6 cross-check).
                                        Defines:
                                        - plan_scope::find_plan
                                        - plan_scope::extract_section
                                        - plan_scope::parse_allowed_files
                                        - plan_scope::parse_allowed_dirs
                                        - plan_scope::path_in_scope
                                        Sentinel main() runs sub-commands
                                        for manual CLI use.

bin/plan-scope-test.sh                  NEW (~80 lines).
                                        Per D-008: parse-files snapshot,
                                        parse-dirs snapshot, path-match
                                        battery, shared-function
                                        assertion, byte-for-byte
                                        cross-caller assertion.

bin/scope-check.sh                      EDIT (~50 lines net).
                                        - Source bin/plan-scope.sh after
                                          line 53 (export PIPELINE_WRITER).
                                        - find_canonical_plan (143-157)
                                          becomes a thin wrapper
                                          delegating to
                                          plan_scope::find_plan
                                          (back-compat).
                                        - extract_scope_section (159-172)
                                          same wrapper pattern.
                                        - allowed_files/allowed_dirs
                                          parse at 297-314 calls
                                          plan_scope::parse_allowed_files
                                          + plan_scope::parse_allowed_dirs.
                                        - Per-file in-scope check at
                                          356-366 calls
                                          plan_scope::path_in_scope.
                                          The benign-path + notable-tier
                                          + SEVERE/NOTABLE logic at
                                          368-391 stays in scope-check.sh.

bin/scope-check-test.sh                 EDIT. Existing cases pass; new
                                        case asserts plan-scope helper
                                        is sourced.

bin/render-prompt.sh                    EDIT (~25 lines).
                                        - Add ONE token to PROMPT_RESOLVERS
                                          (after line 62):
                                          plan_scope_allowed_paths=
                                          _resolve_plan_scope_allowed_paths
                                        - Add the resolver body per D-007
                                          (after _resolve_review_
                                          converge_rounds at line 303).

bin/render-prompt-test.sh               EDIT. New resolver fixture +
                                        soft-fail log assertion.

bin/review-ledger-schema.sh             EDIT (~70 lines).
                                        - Add defer_reason to known-fields
                                          allowlist (line 404).
                                        - Add closed-vocabulary check
                                          (rule 1).
                                        - Gate the existing decision_
                                          factors-required check
                                          (375-390) on defer_reason !=
                                          out-of-plan-scope (rule 3).
                                        - Add defer_reason-required-on-
                                          deferred-major check (rule 2).
                                        - Add validator cross-check
                                          (rule 6): source
                                          bin/plan-scope.sh; parse fix-
                                          target from ship_classification_
                                          rationale via anchored regex;
                                          run plan_scope::path_in_scope;
                                          fail-CLOSED on unparseable
                                          rationale; mismatch → rc=49
                                          with diagnostic.

bin/review-ledger-schema-adversarial-test.sh  EDIT.
                                        AC-AD-10 through AC-AD-18.

AGENT_PROMPTS.md                        EDIT. §5 Review Agent insertions:
                                        - New "Plan-scope adjudication"
                                          block AFTER ENG-191 "Deferability
                                          adjudication" (line 1480) and
                                          BEFORE the count-tuple emission
                                          (line 1481).
                                        - Update path-D predicate
                                          (mechanical predicates block at
                                          1614-1620) to the extended OR.
                                        - Update path-B′ predicate
                                          (implicit complement —
                                          requires at least one rubric
                                          defer).
                                        - Update the Output block ledger-
                                          row instruction (around line
                                          1776-1801) to emit defer_reason
                                          on blocks_ship=false major rows.
                                        - All inside the existing fenced
                                          block; no fence-count change.

bin/agent-prompts-content-test.sh       EDIT. Seven new content pins
                                        per D-008.

docs/runbooks/recovery.md               EDIT. Append §14 "Scope-deferred
                                        majors (ENG-194)" — operator
                                        audit recipe (read ledger for
                                        defer_reason; manual plan-amend
                                        + --action continue path).

CLAUDE.md                               EDIT. Failure-mode quick reference
                                        row update — extend the existing
                                        ENG-191 "Issue at stage:qa with
                                        verdict comment reason=ship-with-
                                        deferred-majors" row to mention
                                        the scope-deferred sub-class
                                        (one-line addendum).
```

**Subsystem count (recap from §1) — 2 subsystems:**

| Subsystem | Files in this brainstorm |
|---|---|
| scope/sweep (subordinate) | bin/plan-scope.sh (NEW), bin/scope-check.sh (refactor), bin/plan-scope-test.sh (NEW), bin/scope-check-test.sh (extension) |
| agent-prompts (the agent-output contract) | AGENT_PROMPTS.md (§5), bin/render-prompt.sh (one resolver), bin/review-ledger-schema.sh (validator extension), bin/agent-prompts-content-test.sh + bin/render-prompt-test.sh + bin/review-ledger-schema-adversarial-test.sh + bin/run-stage-test.sh (extensions) |

The `docs/runbooks/recovery.md` and `CLAUDE.md` edits listed in the file
table above are documentation hygiene, NOT a third subsystem touch.
`docs/**` is a stack-agnostic benign-path class
(`bin/scope-check.sh:62`) — every ticket's documentation edits ride
along the agent-prompts subsystem's "the contract this surface exposes
needs a runbook entry" obligation.

**Lifecycle dataflow (selective-exit dispatch, scope-deferred path):**

```
[Orchestrator: bin/run-stage.sh main()]      [Agent (claude -p)]
  allocate_dispatch_id
  _clear_current_stage_slots                 (stage-summary-reviewing.md,
                                              verdict-review.json cleared;
                                              ledger preserved)
  render-prompt.sh
    └─ {plan_scope_allowed_paths}  ─────────▶ #ALLOWED_FILES#
                                              bin/setup.sh
                                              #ALLOWED_DIRS#
                                              docs/brainstorms/
                                              docs/plans/
    └─ {review_converge_rounds}    → 2
    └─ {dispatch_id}               → ENG-194-d000K
  dispatch.sh
    └─ claude -p ─────────────────────────▶ Read ledger; inventory prior keys
                                            Dispatch sub-agents (cold)
                                            Merge findings → severity tags:
                                              [major] docs/install.md:42 stale
                                            Adjudication (severity, ENG-190)
                                            **Plan-scope adjudication (NEW — ENG-194)**:
                                              For each major finding:
                                                Extract fix-target = "docs/install.md"
                                                (canonical anchor; trim `:42`)
                                                Match against #ALLOWED_FILES# / #ALLOWED_DIRS#
                                                → OUT OF SCOPE
                                                → blocks_ship=false
                                                → defer_reason="out-of-plan-scope"
                                                → ship_classification_rationale =
                                                    "out-of-plan-scope: docs/install.md
                                                     not in plan's File Structure"
                                                → SKIP five-question rubric
                                            (Deferability rubric runs ONLY for in-plan findings)
                                            Emit Findings: line (cold counts)
                                            Emit Adjudicated: line
                                            Emit Deferrable: line
                                              (deferrable_majors=1, blocking_majors=0)
                                            Decision path:
                                              critical=0, blocking_majors=0,
                                              EVERY deferred-major has
                                                defer_reason=="out-of-plan-scope"
                                              → path D fires (no convergence-rounds gate;
                                                 ENG-194 D-004 extension)
                                            Output:
                                              - gh pr review --comment
                                              - completion/reviewing/ENG-194
                                              - Stage-summary, verdict-review.json
                                              - Edit append ledger row:
                                                  blocks_ship=false,
                                                  defer_reason="out-of-plan-scope",
                                                  decision_factors=null
                                              - progress.md
                                              - verdict pass --stage reviewing
                                                  --reason ship-with-deferred-majors
    ◀───────────────────────────────────── exit
  _validate_dispatch_envelope
  _validate_review_payload
  _validate_review_ledger
    └─ defer_reason closed-vocabulary check (NEW — D-005 rule 1)
    └─ defer_reason-required on deferred-major (NEW — rule 2)
    └─ decision_factors required ONLY if defer_reason != "out-of-plan-scope" (RELAXED — rule 3)
    └─ Cross-check (NEW — rule 6): parse fix-target via anchored regex
                                    source bin/plan-scope.sh
                                    plan_scope::path_in_scope "$fix_target" "$af" "$ad"
                                    fail-CLOSED on unparseable rationale
                                    rc=49 on matcher disagreement
  _post_deferred_majors_comment_if_eligible (UNCHANGED from ENG-191 in v1)
    └─ ledger rows where blocks_ship=false render as flat bullets
    └─ scope-deferred rows ARE in the comment (AC #2) but not grouped
       (D-006 grouping deferred to ENG-194-A)
  post_completion_comment
  verdict-handler picks up agent's verdict marker
    └─ pass + stage=reviewing → forward transition reviewing → qa
```

## 4. Data flow

**Producer (scope-deferred selective exit).** Review agent on a
dispatch where critical=0 AND every adjudicated-major has
`blocks_ship=false defer_reason="out-of-plan-scope"`. Emits:

- `Adjudicated:` line with major>0.
- `Deferrable:` line with `deferrable_majors=N`, `blocking_majors=0`.
- Per-finding ledger rows with `defer_reason="out-of-plan-scope"`,
  `decision_factors=null`, `ship_classification_rationale` matching
  the EXACT anchored shape `"out-of-plan-scope: <path> not in plan's
  File Structure"`.
- Verdict marker: `verdict pass --stage reviewing --reason
  ship-with-deferred-majors`.

**Producer (mixed deferral).** Agent emits some
`defer_reason="out-of-plan-scope"` rows AND some
`defer_reason="rubric"` rows. Convergence-rounds gate applies (no
bypass); path B′ fires unless plateau is met. The rubric rows carry
full `decision_factors` per ENG-191.

**Producer (in-plan only — ENG-191 status quo).** Agent emits all
rows with `defer_reason="rubric"` (or `defer_reason` omitted for
backwards compat at the contract boundary). Behaviour unchanged from
ENG-191.

**Storage.** `$(issue_dir <ident>)/review-findings-ledger.jsonl`
(extended schema). Append-only across all review dispatches.

**Reader (v1):**

1. The same review agent's adjudication step on the NEXT review
   dispatch — reads ledger via ENG-190 inventory step.
2. The orchestrator's `_post_deferred_majors_comment_if_eligible`
   helper — reads `blocks_ship=false` rows; renders the flat-list
   shape from ENG-191 (the `defer_reason` field is on the row but not
   rendered into the comment — D-006 grouping deferred to ENG-194-A).
3. The orchestrator's `_validate_review_ledger` post-dispatch scan
   (extended with ENG-194 rules per D-005).
4. ENG-193 (auto-ticketing) — future reader; `defer_reason` gives it
   signal for ticket priority + title prefix ("Scope-deferred:" vs
   "Rubric-deferred:").

**Linear-comment surfaces:**

| Surface | Sig | Writer | Body |
|---|---|---|---|
| Completion summary | `completion/reviewing/<issue>` | orchestrator (via post_completion_comment, ENG-11) | Agent's stage-summary-reviewing.md (includes adjudicator summary + ship-with-debt line; ENG-191 D-008). |
| Deferred majors | `deferred-majors/<issue>` | orchestrator (UNCHANGED from ENG-191 in v1) | Flat-list markdown bullets covering ALL blocks_ship=false rows; defer_reason not surfaced in comment body (deferred to ENG-194-A). |
| Verdict | (none — verdict markers are body-only) | agent (via `bash bin/pipeline.sh event`) | `<!-- pipeline: verdict result=pass stage=reviewing reason=ship-with-deferred-majors -->` |

## 5. Error handling

**Halt cases (this ticket's contract):**

| Failure mode | rc | Outcome token | Halt reason | Operator recovery |
|---|---|---|---|---|
| Major row with `blocks_ship=false` missing `defer_reason` this dispatch | 49 | review-ledger-incomplete | review-ledger-invalid | Validator names the row; agent didn't follow the new prompt rule. Operator inspects transcript, fixes by hand or `--action continue` after agent re-runs. |
| `defer_reason` is a non-vocabulary value (e.g. `"out-of-scope"` instead of `"out-of-plan-scope"`) | 49 | review-ledger-incomplete | review-ledger-invalid | Closed-vocabulary diagnostic names the bad value. |
| `defer_reason="out-of-plan-scope"` but `decision_factors` is present-and-malformed | not an error — the validator skips the decision_factors check entirely when defer_reason is scope. Agent free-form data is logged as `_warn_unknown`. | n/a | n/a | n/a |
| `defer_reason="rubric"` but `decision_factors` missing | 49 (existing ENG-191 rule, unchanged) | review-ledger-incomplete | review-ledger-invalid | Pre-existing ENG-191 contract — operator inspects transcript. |
| Render-prompt resolver fails to find plan | 0 | (soft-fail: log warning) | n/a | Resolver emits empty sets; reviewer falls through to ENG-191 rubric for every finding. Degraded mode visible in render log. |
| Reviewer mis-classifies an in-plan finding as out-of-plan-scope (agent bug) | 49 | review-ledger-incomplete | review-ledger-invalid | NEW — caught by D-005 rule 6 cross-check. Validator diagnostic names the row + sanitised path. Operator typically observes agent prompt drift or forged claim; resume after next pass classifies correctly. |
| Reviewer mis-classifies an out-of-plan finding as in-plan (and applies rubric) | 0 | (agent-level error; not validator-detectable in v1) | n/a | The downstream implement dispatch's scope-check.sh halts when the implementer touches the out-of-plan file. ENG-180-class catch-22 returns. v1 accepts the agent-judgment risk; the structural defense is the matcher's strictness (the prompt block CAN'T mis-classify an out-of-plan path as in-plan unless the agent ignores the explicit `{plan_scope_allowed_paths}` token contents). |
| Agent emits `defer_reason="out-of-plan-scope"` but `ship_classification_rationale` doesn't match the mandated shape `"out-of-plan-scope: <path> not in plan's File Structure"` (anchored start+end) | 49 | review-ledger-incomplete | review-ledger-invalid | Fail-CLOSED. Diagnostic `out-of-plan-scope-rationale-malformed` names the row. Operator triages — usually agent prompt drift. |

**Soft-fail cases (NOT halts):**

- Render-prompt resolver's plan-not-found / section-empty path: logs
  warning; emits empty sets; reviewer degrades to ENG-191-only safely.
- `_post_deferred_majors_comment_if_eligible` failing to post (Linear
  API outage): same as ENG-191 D-005 — soft-fail, ledger is canonical,
  transition still fires.
- D-005 rule 6 cross-check when plan is absent: logs warning; PASSES
  the row (agent's claim is plausibly correct because the renderer
  emitted empty sets too). This is the degraded-mode operability path
  for plan-deletion-mid-dispatch.

**Logging.** Validator stdout follows the existing ENG-190 shape:
`review-ledger-incomplete: row N: <msg> finding_class_key=<key>`. New
diagnostic messages from D-005:

- `defer_reason must be 'out-of-plan-scope' or 'rubric' (closed vocabulary), got '<val>'`
- `defer_reason-missing-on-deferred-major: adjudicated_severity=major blocks_ship=false`
- `out-of-plan-scope-rationale-malformed: defer_reason=out-of-plan-scope but rationale does not match mandated shape, got '<val>'`
- `defer-reason-claim-disagrees-with-plan-scope: agent claimed out-of-plan-scope but matcher classifies path=<sanitised> as IN-plan`

**No retry path.** Same as ENG-190/ENG-191 — emission is deterministic;
failure means agent bug.

## 6. Edge cases

1. **Plan deleted mid-dispatch.** Render-prompt resolver's
   plan-not-found path emits empty sets; reviewer treats every major
   finding as in-plan (falls through to rubric). The matcher
   cross-check (D-005 rule 6) also detects plan-absent and PASSES the
   row with a warning log — agent and validator agree in the degraded
   mode. Safe-default.

2. **Plan File Structure section absent.** Same as #1 — resolver emits
   empty sets, cross-check sees empty body, safe-default behaviour.

3. **Multi-file finding with mixed in-plan/out-of-plan files.** Per
   D-002's canonical-anchor rule, ONLY the canonical anchor — the
   `path/to/file.ext:LINE` token immediately after the severity tag —
   is consulted as the fix-target; secondary files mentioned later in
   the finding body are informational and NOT consulted. If the
   canonical anchor's file is out-of-plan, the finding is scope-
   deferred regardless of secondary mentions; if it's in-plan, the
   five-question rubric applies. Collapses to the single source of
   truth the review-comment-quality rubric (AGENT_PROMPTS.md:
   1572-1586) already enforces. Operators inspecting a
   deferred-majors comment can re-read the underlying PR review
   comment to see the full file list.

4. **Critical finding whose fix is out-of-plan.** Critical-floor
   invariant rules: `blocks_ship=true` unconditionally. Agent MAY
   record `defer_reason="out-of-plan-scope"` for audit (D-005 permits
   it on `blocks_ship=true` rows), but `blocking_majors` stays > 0 →
   path B (loopback). Implementer tries; scope-check halts. Operator
   triages via `docs/runbooks/recovery.md`'s scope-violation recovery
   path. **No operator-recipe meta-comment** (deferred to ENG-194-C).
   The catch-22 residual for critical+out-of-plan is the intentional
   ENG-180 backstop and is documented as accepted v1 cost.

5. **Findings without a `file:line` anchor.** Per D-002, the agent
   falls through to the five-question rubric for these. The
   review-comment-quality rubric (AGENT_PROMPTS.md:1572-1586) already
   requires the anchor at the boundary, so this should be rare. v1
   accepts the small ambiguity; flagged for future hardening (OQ-4)
   if a transcript-pattern of "findings missing anchors" recurs.

6. **Reviewer adversarially fakes `defer_reason="out-of-plan-scope"`
   to bypass the convergence-rounds gate on a rubric-deferred
   finding.** D-005 rule 6 cross-check defends: validator re-runs
   `plan_scope::path_in_scope` against the row's fix-target; mismatch
   → rc=49. The agent CAN bypass the cross-check ONLY by:
   (a) emitting a rationale that doesn't match the anchored regex
       (caught by fail-CLOSED — rc=49 with
       `out-of-plan-scope-rationale-malformed`); OR
   (b) claiming an actually-out-of-plan path the matcher confirms
       (which is just the legitimate scope-defer path; not a forge).
   The cross-check closes the "claim in-plan-path as out-of-plan"
   direction.

7. **Plan File Structure has prose surrounding the path tokens.**
   `plan_scope::parse_allowed_files` and `parse_allowed_dirs` use the
   same `grep -oE` regexes as the legacy `bin/scope-check.sh:307-314`.
   Prose surrounding the tokens (e.g. "I will edit `bin/setup.sh` to
   add a phase") is ignored — only token shapes match. No regression
   vs ENG-191 scope-check behaviour.

8. **Reviewer flags a benign-path class file (e.g. `docs/knowledge/
   decisions.md`, `docs/plans/foo.md`, `.scratch/foo`).** The
   reviewer's matcher consults ONLY the plan structural sets; benign-
   path classes are NOT consulted (deferred to ENG-194-B). Net: a
   review finding about a benign-path class file gets auto-deferred
   (since it's not in the plan's File Structure). The implementer
   COULD have fixed it (scope-check.sh::is_benign would allow), but
   the reviewer's defer routes it to known debt instead.

   Acceptable in v1 because (a) benign-path class findings are
   uncommon (cold-pass sub-agents don't typically flag
   `docs/knowledge/` or `docs/plans/` files — those are docs not
   tested by the implement phase); (b) the auto-defer routes to known
   debt instead of deadlocking (the failure mode this brainstorm
   exists to fix); (c) the operator sees the defer in the ledger and
   can read `defer_reason="out-of-plan-scope"` to recognise the
   benign-path case. ENG-194-B closes the divergence by moving stack-
   agnostic benign-path classes into the shared helper.

   Same divergence shape covers stack-conditional benign paths (lock-
   files, Rust crates-tests carve-out at `bin/scope-check.sh:200-205`).
   The frequency of lockfile review-findings is essentially zero in
   practice — cold-pass sub-agents don't flag lockfile churn.

9. **Dotfile directory in plan (e.g. `.github/workflows/`).** The
   existing awk filter at `bin/scope-check.sh:313-314` was fixed
   pre-ENG-194 (ENG-46) to NOT strip dotfile dirs. The `plan-scope.sh`
   helper inherits this. Prompt-content test pins the dotfile-dir
   case (D-008 test 1).

10. **Repo-root files in plan (e.g. `CLAUDE.md`).** ENG-25 fix at
    `bin/scope-check.sh:307` — `*` not `+` on the path-prefix group.
    `plan-scope.sh` helper inherits.

11. **Dry-run (`PIPELINE_DRY_RUN=1`).** Same as ENG-191 D-006: the
    orchestrator's deferred-majors comment post is dry-run-gated by
    `linear.sh` itself; ledger is written as normal; validator runs as
    normal.

12. **`PIPELINE_DISPATCH_ID` unset when validator runs (test-fixture
    case).** Same fail-open shape as ENG-191 D-009 — the schema-grace
    clause becomes a no-op (no prior/current distinction). All rows
    must satisfy the new ENG-194 rules.

13. **Concurrent dispatches on the same issue.** ENG-81 per-issue lock
    prevents this; no new hazard.

14. **Operator manually edits ledger to flip `defer_reason` from rubric
    to scope.** The schema-grace clause skips prior-dispatch rows; if
    the operator edits a this-dispatch row, the validator re-runs on
    next dispatch (if the agent does a fresh emission) but at that
    point the row's `dispatch_id` has changed to the new dispatch —
    so the hand-edit's row becomes a prior-dispatch row, validated
    against the pre-edit contract. Recovery via `docs/runbooks/
    recovery.md` §12.

15. **Plan amended (in `docs/plans/...md`) mid-loop.** The
    render-prompt resolver reads the current worktree's plan file at
    render time (per D-007). If the operator amends the plan File
    Structure between dispatches, the next reviewing dispatch sees
    the new sets. No staleness contract violation.

16. **Sandbox-denial on plan read.** ENG-156 detective catches
    sandbox denials on path-shaped tokens; this resolver's output is
    NOT path-shaped (D-007 sidecar exclusion). The internal plan-read
    goes through bash file IO unrestricted at render time (renderer
    runs in orchestrator context, not sandbox).

17. **Adversarial plan mutation by reviewer mid-dispatch.** An
    adversarial reviewer could edit `docs/plans/<plan>.md`'s File
    Structure to ADD an out-of-scope file (the `docs/plans/*` glob is
    a stack-agnostic benign-path class — `bin/scope-check.sh:62` —
    so the post-stage sweep won't catch the edit), then claim that
    file is in-plan. The D-005 rule 6 cross-check would PASS (the
    plan file says it's in-plan now), bypassing the defer. v1
    accepts this as a bounded weakness: (a) requires an agent that
    actively edits the plan, which is not normal reviewing behaviour
    and would be visible in the commit history; (b) operator can spot
    via `git log` post-hoc; (c) plan-mutation transcript defense
    (`_validate_dispatch_envelope` extension) is deferred to
    ENG-194-D per operator descope (it touches the orchestrator
    subsystem, which would tip the ticket past 2 subsystems). OQ-3
    captures the trade-off.

## 7. Open questions

- **OQ-1.** Option (b) from the Linear ticket — reviewer/implementer
  proposes an in-band plan File Structure amendment as a structured
  "plan addendum" — is deferred to a follow-up. v1 ships the
  auto-defer path. **Working decision:** revisit if the auto-defer
  results in too many scope-deferred bullets that are actually
  legitimate plan-amendments-the-author-missed (operator pain signal:
  many deferred-majors comments where every deferred bullet is the
  same kind of plan gap, e.g. "test-helper.sh changed and its doc was
  stale"). Trigger ticket once observed.

- **OQ-2.** Benign-path-class divergence (Edge case 8). v1 leaves
  stack-agnostic AND stack-conditional benign paths in scope-check's
  `is_benign`; the reviewer's defer for a benign-path-class finding is
  incorrect-but-bounded routing to known debt. **Working decision:**
  v1 accepts the auto-defer routing for near-nonexistent cases.
  Tracked as ENG-194-B follow-up: extend `bin/plan-scope.sh` with a
  `list_benign_path_classes` function + a second resolver
  `{plan_scope_benign_path_classes}`; reviewer prompt rule consults
  both. Stack-conditional residue (lockfiles, Rust crates-tests)
  stays out of scope-check's runtime gate even after ENG-194-B in v2.

- **OQ-3.** Plan-mutation defense in `_validate_dispatch_envelope`
  (Edge case 17). The reverse direction the D-005 rule 6 cross-check
  cannot catch alone. **Working decision:** v1 accepts the bounded
  weakness; ENG-194-D follow-up extends the existing envelope-validator
  forbidden-substring list with `Write` / `Edit` patterns targeting
  `docs/plans/**/*.md` during reviewing, halting with
  `plan-mutation-during-review` (new halt reason added to
  `bin/pipeline-events.json::halt_reasons`). The orchestrator subsystem
  touch is the reason it's a separate ticket — adding it to ENG-194
  would tip past 2 subsystems.

- **OQ-4.** Findings without a `file:line` anchor (Edge case 5). v1
  falls through to the rubric. **Working decision:** v1's safe-default
  is acceptable; the review-comment-quality rubric mandates the anchor
  so missing-anchor findings are already a separate violation surface.
  If a transcript-pattern of frequent missing anchors emerges, file a
  follow-up to formalise an "anchor required" validator check.

- **OQ-5.** Operator-discoverable preview of the rendered
  `{plan_scope_allowed_paths}` payload — should `bin/status.sh` surface
  it? **Working decision:** no in v1. The payload is derivable from
  the plan file directly; operators with the plan open already see the
  File Structure. If observed-needed (operators repeatedly debugging
  "why did this finding defer?"), add to `bin/status.sh`.

- **OQ-6.** Cross-coordination with ENG-192 (implement-side
  fix-the-class). ENG-192's class-closure reads only the cited
  finding's defect mechanism. ENG-194's auto-defer happens at the
  reviewer; the implementer never sees the scope-deferred finding
  (it's in the deferred-majors comment, not in `{review_findings}`).
  Independent in v1; no coordination needed. **Working decision:**
  confirmed independent.

- **OQ-7.** `plan-scope.sh` API namespacing. Bash has no real
  namespaces; the `plan_scope::*` prefix is a convention. **Working
  decision:** no conflicts (grepped: no other `::`-namespaced function
  patterns in `bin/`). Pattern follows informal shell conventions
  (e.g. bats). If preferred at implementation time, fall back to
  `plan_scope_*` underscore-prefixed; same semantics.

- **OQ-8.** Test mechanism for AC #5 (the ENG-27-class end-to-end).
  The full E2E requires a runtime `claude -p` invocation, which tests
  don't do. Per D-008, the fixture asserts the COUNT-TUPLE shape and
  verdict marker shape as proxies for the agent's in-prompt
  arithmetic. **Working decision:** prompt-content-based testing is
  the established pattern (ENG-190 D-003, ENG-191 D-008). The E2E
  shape is implicit in the conjunction of (a) the prompt rules being
  correctly worded, (b) the orchestrator-side fixtures asserting the
  correct partition behaviour, and (c) the validator gating the
  contract.

## 8. Out-of-scope reminders

**Operator-descoped follow-ups (filed as sibling tickets after
ENG-194 ships):**

- **ENG-194-A — deferred-majors comment grouping + operator-recipe
  trailer (was D-006).** Orchestrator's
  `_post_deferred_majors_comment_if_eligible` reads `defer_reason` and
  groups bullets by reason ("Out-of-plan-scope" + "Rubric-deferred"
  sub-sections); lede sentence includes both counts; "To fix any of
  the above in-PR" operator-recipe trailer when scope-deferred bullets
  exist. Touches the orchestrator subsystem — strictly UX delta;
  AC #2's "not silently dropped" is satisfied in v1 by the ledger
  field being present.

- **ENG-194-B — `{plan_scope_benign_path_classes}` second resolver
  (was D-007 second resolver).** Reviewer prompt-side check consults
  stack-agnostic benign-path classes alongside the plan, closing the
  Edge case 8 divergence for findings against `docs/knowledge/`,
  `docs/plans/`, `.scratch/`, `.pipeline/metrics/`. Stack-conditional
  residue stays out of scope.

- **ENG-194-C — `critical-out-of-plan/<ident>` meta-comment
  operator-recipe (was D-002 final paragraph).** When the reviewer
  classifies a critical+out-of-plan finding, post an operator-visible
  meta-comment naming the file + the plan-amend + resume sequence.
  Improves operator UX for the residual catch-22 case; v1 reverts to
  standard `docs/runbooks/recovery.md` triage.

- **ENG-194-D — plan-mutation transcript defense in
  `_validate_dispatch_envelope` (was iter-1-of-d0002 security P0 #2
  mitigation).** Detects `Write` / `Edit` tool invocations targeting
  `docs/plans/**/*.md` during a reviewing dispatch; halts with
  `plan-mutation-during-review` (new halt reason). Closes Edge case 17
  reverse-direction adversarial path.

**Linear-stated OUT bullets:**

- **The deferred-major exit machinery itself ([ENG-191]).** This
  ticket CONSUMES it. The selective-exit transition `reviewing → qa`,
  the `reason=ship-with-deferred-majors` marker, the orchestrator's
  `_post_deferred_majors_comment_if_eligible`, the `Deferrable:` line
  — all preserved and extended additively.
- **Auto-ticket creation per deferred major ([ENG-193]).** Future
  consumer. ENG-194 extends the ledger row's structured data (adds
  `defer_reason`) so ENG-193 can prefix tickets by reason.
- **Fixing the `scope-violation`-resume break ([ENG-180]).**
  Orthogonal; blocking parent of the manifest catch-22 but not this
  ticket's scope. ENG-194 eliminates the catch-22's occurrence;
  ENG-180 fixes the recovery for residual cases (e.g.
  critical-finding out-of-plan).

## 9. ADR stress test

This brainstorm puts pressure on the following accepted decisions:

- **ENG-190 ledger schema (closed-minimal posture).** ENG-191 D-002
  already documented the additive-v1 path; ENG-194 adds ONE more
  optional field (`defer_reason`). Schema version unchanged. The
  conditional `decision_factors` relaxation (gated on
  `defer_reason="out-of-plan-scope"`) is a NEW validator-side branch,
  not a schema change. Within contract; ENG-190 OQ-5's "schema exposes
  enough signal" prediction continues to hold.

- **ENG-191 D-006 path-D predicate (agent-decides).** ENG-194 EXTENDS
  the predicate inside the agent's prompt — adds the OR clause to the
  existing conjunction. The orchestrator-side hook
  (`_post_deferred_majors_comment_if_eligible`) reads `blocks_ship=
  false` rows regardless of `defer_reason` (no orchestrator change in
  v1; D-006 grouping deferred to ENG-194-A); the agent's marker shape
  (`verdict pass --reason ship-with-deferred-majors`) unchanged.
  Within ENG-191's "agent decides outcome, orchestrator publishes
  effect" boundary.

- **ENG-191 D-007 (no `guards.sh` code change).** Selective exit still
  fires `reviewing → qa` (forward); no rejection bump. Scope-deferred
  path inherits this; no `guards.sh` change for ENG-194 either. Within
  contract.

- **ENG-87 cross-dispatch staleness contract.** The schema-grace
  clause (ENG-191 D-002 inheritance) gates the new `defer_reason`
  check by `dispatch_id == --dispatch-id`. Strictly additive; no
  stress.

- **CLAUDE.md "Don't add features beyond what the task requires."**
  Linear scope explicitly lists 4 IN items, all delivered:
  (1) reviewer computes per-finding scope-status (D-002);
  (2) out-of-plan-scope → `blocks_ship=false` + reason (D-003);
  (3) excluded from loopback (D-004 + structural via D-002);
  (4) shared matcher with byte-for-byte assertion (D-001 + D-008).
  No fifth feature; the three former carve-outs are explicit follow-up
  tickets per operator descope.

- **CLAUDE.md "AGENT_PROMPTS.md is load-bearing."** §5 gains ~20 lines
  (Plan-scope adjudication block + path-D predicate extension + Output
  bullet update for the ledger-row instruction). No fence-count
  change; no new H2 section.

- **CLAUDE.md "Defense-in-depth: prefer transcript-based assertion
  over post-dispatch state check."** The new ENG-194 contract is the
  agent's CLASSIFICATION choice (`defer_reason`). v1 ships D-005 rule 6
  as the structural matcher cross-check (post-dispatch state check on
  the ledger row vs. the on-disk plan). The transcript-based assertion
  for "agent must not Write/Edit `docs/plans/*` mid-reviewing" is
  deferred to ENG-194-D — the orthogonal direction the cross-check
  cannot catch. v1 trade-off documented.

- **CLAUDE.md "Sub-agent debris (ENG-100)."** The reviewer agent does
  NOT write fixture files to verify the scope match; the matcher logic
  is rendered into the prompt as a token, and the agent reads it. Same
  constraint as ENG-191; respected.

- **CLAUDE.md ticket-sizing rubric — Axis 1 (subsystems touched).**
  2 subsystems explicitly enumerated in §1: scope/sweep (subordinate
  D-001 extraction) + agent-prompts (D-002 + D-003 + D-004 + D-005 +
  D-007 first resolver; agent-output contract surface). The
  validator's home in `bin/review-ledger-schema.sh` is treated as part
  of the agent-output contract subsystem because it enforces what §5
  mandates. Within the autonomy-safe range with one clearly
  subordinate.

- **`bin/scope-check.sh`'s "benign-path classes" surface.** ENG-194
  EXTRACTS the structural parse + match logic but PRESERVES `is_benign`
  in `bin/scope-check.sh` (D-001). The reviewer's structural match is
  intentionally STRICTER than scope-check's runtime gate (does not
  consult benign classes). OQ-2 documents the trade-off; ENG-194-B
  closes the gap as a sibling ticket.

## 10. Simpler-alternative pass

Per-decision rejected alternatives documented inline. Consolidated:

| Decision | Rejected alternative | Why rejected |
|---|---|---|
| D-001 | Leave parse/match inline in scope-check.sh; render-prompt re-executes scope-check.sh | scope-check.sh main has side effects; renderer needs sets, not yes/no |
| D-001 | Duplicate the parse logic in render-prompt.sh | AC #4 forbids divergence; duplicated code drifts |
| D-001 | Bake JSON sidecar on disk | One more artifact + freshness contract; sourcing is established idiom |
| D-001 | Keep 2-arg `path_in_scope_or_benign` wrapper (2026-06-14 draft) | Benign-path partitioning is ENG-194-B follow-up per operator descope |
| D-002 | Plan-scope check as question 1 of the five-question rubric | Loses `in_changed_code` signal; rubric is the in-plan path, not a checklist |
| D-002 | Sanction reviewer-requested out-of-scope edits in scope-check.sh | Linear option (c) explicitly rejected |
| D-002 | In-band plan-File-Structure amendment via reviewer/implementer | Linear option (b); deferred to OQ-1 |
| D-002 | critical-out-of-plan meta-comment operator-recipe trailer | Operator descope; ENG-194-C follow-up |
| D-003 | Overload `ship_classification_rationale` with prefix | Prose drifts; closed token is debuggable |
| D-003 | Bump schema to v2 | Doubles validator surface; additive-v1 strictly less complex |
| D-003 | Separate file `review-scope-defers.jsonl` | Sprawl; per-finding record is the ledger |
| D-004 | Bypass convergence for ANY scope-deferred finding (mixed case) | Mixed case still benefits from rubric stability evidence |
| D-004 | Bypass convergence whenever scope-deferred-count > 0 | Same as above |
| D-005 | Bump schema to v2 | Same as D-003 |
| D-005 | Separate validator file | Sprawl |
| D-005 | Fail-OPEN on unparseable rationale | Forge surface; an agent can emit ill-formed rationale to skip the matcher cross-check |
| D-005 | Drop the cross-check entirely and trust the agent's claim | AC #1+#4+#5 rely on the agent's claim being correct |
| D-007 | Render as JSON | Plain text is the agent's read format |
| D-007 | Render compiled match output | Renderer doesn't know findings at render time |
| D-007 | Add `{plan_scope_benign_path_classes}` second resolver | Operator descope; ENG-194-B follow-up |
| D-008 | Single omnibus end-to-end fixture | Per-AC tests give faster feedback |

## 11. Assumption inventory

Every named function, file, line citation re-verified in this dispatch
against the worktree HEAD. Entries marked **verified** carry a
`path:line` reference quoted from the current code.

| # | Assumption | Status | Evidence |
|---|------------|--------|----------|
| 1 | `bin/scope-check.sh::find_canonical_plan` exists and uses `linear: <ID>` frontmatter | **verified** | `bin/scope-check.sh:143-157` (read this dispatch) |
| 2 | `bin/scope-check.sh::extract_scope_section` extracts the File Structure body via awk | **verified** | `bin/scope-check.sh:159-172` (read) |
| 3 | `bin/scope-check.sh` parses `allowed_files` and `allowed_dirs` via `grep -oE` regexes | **verified** | `bin/scope-check.sh:297-314` (read) |
| 4 | `bin/scope-check.sh`'s per-file in-scope check uses `grep -qxF` (exact-match) + per-line dir-prefix loop | **verified** | `bin/scope-check.sh:356-366` (read) |
| 5 | `bin/scope-check.sh::is_benign` consults `.scratch/`, `_BENIGN_PATH_CLASSES`, profile-derived lockfiles, and Rust crate-tests in that order | **verified** | `bin/scope-check.sh:175-207` (read) |
| 6 | The post-stage sweep gating site halts on `scope-violation` is `bin/scope-check.sh:380-391` (rc=3 SEVERE / rc=1 NOTABLE) | **verified** | `bin/scope-check.sh:380-391` (read) |
| 7 | `bin/render-prompt.sh::PROMPT_RESOLVERS` registers tokens at lines 40-62; new resolvers add to the list AND need a `_resolve_*` function body | **verified** | `bin/render-prompt.sh:40-62` (read); `_resolve_review_converge_rounds` at lines 292-303 |
| 8 | `bin/render-prompt.sh::_write_rendered_paths_sidecar` enumerates path-shaped resolvers explicitly (lines 94-127); non-path tokens stay out | **verified** | `bin/render-prompt.sh:94-127` (read) |
| 9 | `bin/render-prompt.sh::_resolve_review_converge_rounds` (lines 292-303) is the precedent for a non-path resolver returning data | **verified** | `bin/render-prompt.sh:292-303` (read) |
| 10 | `bin/render-prompt.sh::main`'s residual unknown-token validator dies on unregistered tokens at line ~451 | **verified** | `bin/render-prompt.sh:451` (grep — `die "render-prompt: unknown token..."`) |
| 11 | `bin/review-ledger-schema.sh` has validation for `blocks_ship` (358-360), critical-floor (363-365), `ship_classification_rationale` (367-374), and `decision_factors` (375-390) | **verified** | `bin/review-ledger-schema.sh:354-398` (read) |
| 12 | `bin/review-ledger-schema.sh` uses rc=49 for incomplete and emits diagnostics via `_emit_incomplete` | **verified** | `bin/review-ledger-schema.sh:135-143` (read prior dispatch + re-verified line range still holds) |
| 13 | `bin/review-ledger-schema.sh` has `dispatch_id_flag` schema-grace clause cross-check at lines 151-165 | **verified** | `bin/review-ledger-schema.sh:151-165` (grep matched `--dispatch-id` parsing) |
| 14 | `bin/run-stage.sh::_post_deferred_majors_comment_if_eligible` exists at lines 1483-1561 and reads ledger rows with `adjudicated_severity=major AND blocks_ship=false` | **verified** | `bin/run-stage.sh:1483-1561` (read prior dispatch); re-verified line 1483 + 1527 still hold via grep this dispatch |
| 15 | `bin/run-stage.sh::_validate_review_ledger` is invoked at `bin/run-stage.sh:2432` in the reviewing-stage post-dispatch validator gate | **verified** | `bin/run-stage.sh:2432` (grep) |
| 16 | The `bin/review-ledger-schema.sh` known-fields allowlist is an inline jq `(keys) - [...]` expression at line 404 (corrected from the iter-1-of-d0002 wrong-line citation) | **verified** | `bin/review-ledger-schema.sh:404` (read this dispatch; allowlist contains the 13 ENG-191 fields, no `defer_reason`) |
| 17 | `bin/review-ledger-schema.sh::_warn_unknown` defined at line 145 | **verified** | `bin/review-ledger-schema.sh:145` (grep) |
| 18 | `bin/review-ledger-schema.sh::sanitise_for_diag` defined at line 115 | **verified** | `bin/review-ledger-schema.sh:115` (grep) |
| 19 | `bin/pipeline-events.json::pass_reasons` array contains `"ship-with-deferred-majors"` | **verified** | `bin/pipeline-events.json:10-11` (grep) |
| 20 | AGENT_PROMPTS.md §5 Review Agent body spans lines 1335-1845; ENG-191 deferability adjudication block at lines 1439-1480 | **verified** | `grep "^## 5\.\|^## 6\." AGENT_PROMPTS.md` (this dispatch) returned `1335:## 5. Review Agent`, `1847:## 6. QA Agent`; deferability block at 1439-1480 confirmed via grep this dispatch |
| 21 | AGENT_PROMPTS.md §5 count-tuple emission (`Findings:`, `Adjudicated:`, `Deferrable:`) is at lines 1481-1500 | **verified** | grep showed `Adjudicated:` at line 1485 + `Deferrable:` at line 1486 this dispatch |
| 22 | AGENT_PROMPTS.md §5 mechanical predicates block (path B / C / D / B′) is at lines 1614-1620 | **verified** | grep showed `Mechanical predicates` block lines 1614-1620 this dispatch |
| 23 | AGENT_PROMPTS.md §5 review-comment-quality rubric mandates `path/to/file.ext:LINE` anchor at lines 1572-1586 | **verified** | grep showed `Review-comment quality rubric` at line 1572 this dispatch |
| 24 | AGENT_PROMPTS.md §5 path-D verbose body referencing the predicate at line 1670 (Output block) | **verified** | grep showed `To ship with deferred majors (path D — ...)` at line 1824 this dispatch (NOTE: prior brainstorm cited 1776-1801 for the Output ledger-row block — line numbers may have shifted slightly; implementation re-checks at edit time) |
| 25 | `bin/scope-check-test.sh` exists in `bin/` | **verified** | `ls bin/scope-check-test.sh` (visible in worktree) |
| 26 | `bin/review-ledger-schema-adversarial-test.sh` exists in `bin/` | **verified** | iter-2 feasibility persona confirmed presence; assumed unchanged this dispatch |
| 27 | `bin/agent-prompts-content-test.sh` is the prompt-content content test harness (ENG-190 D-003 + ENG-191 D-008 prior art) | **verified** | iter-2 feasibility persona confirmed presence |
| 28 | `bin/render-prompt-test.sh` exists | **verified** | iter-2 feasibility persona confirmed presence |
| 29 | `bin/run-stage-test.sh` exists | **verified** | iter-2 feasibility persona confirmed presence |
| 30 | `bin/common.sh::issue_dir` returns `$PROJECT_STATE_DIR/<issue>` and is used to locate the ledger | **verified** | `bin/run-stage.sh:1493` calls `issue_dir "$ident"` directly (read prior dispatch) |
| 31 | `docs/runbooks/recovery.md` exists with sections 1-13 (ENG-191 added §13) | **verified** | iter-2 feasibility persona confirmed |
| 32 | `bin/scope-check.sh:53` is `export PIPELINE_WRITER=scope-check` (insertion site for `source plan-scope.sh`) | **verified** | `bin/scope-check.sh:53` (read this dispatch) |
| 33 | `bin/scope-check.sh:59-65` defines `_BENIGN_PATH_CLASSES` as a 5-glob hardcoded array | **verified** | `bin/scope-check.sh:59-65` (read this dispatch) |
| 34 | No existing code uses `defer_reason` or `out-of-plan-scope` anywhere in `bin/` or AGENT_PROMPTS.md (no collision) | **verified** | `grep "defer_reason\|out-of-plan-scope" bin/*.sh AGENT_PROMPTS.md bin/pipeline-events.json` returned zero hits this dispatch |
| 35 | `plan_scope_allowed_paths` is not yet a registered token in `PROMPT_RESOLVERS` (no collision) | **verified** | `grep plan_scope bin/render-prompt.sh` returned zero hits this dispatch |
| 36 | `bin/plan-scope.sh` does not exist yet | **verified** | `ls bin/plan-scope*.sh` returned "no matches found" this dispatch |
| 37 | `_validate_dispatch_envelope` lives at `bin/run-stage.sh:1039` (NOT in `bin/dispatch.sh`) — the iter-2-of-d0002 feasibility P0 fix | **verified** | grep this dispatch confirmed `bin/run-stage.sh:1039:_validate_dispatch_envelope() {` and `bin/dispatch.sh` has only comments referencing the function (lines 75, 162). NOTE: this assumption is informational for OQ-3 / ENG-194-D follow-up; the descoped v1 does NOT touch `_validate_dispatch_envelope` |
| 38 | `bin/run-stage.sh::_validate_dispatch_envelope` uses an `assert_no_tool_invocation "$sidecar" "<substring>"` helper for forbidden-substring checks | **verified** | `bin/run-stage.sh:1052-1077` (grep returned 5 call sites this dispatch). Informational for OQ-3 / ENG-194-D |
| 39 | AGENT_PROMPTS.md does NOT contain `plan_scope_allowed_paths` or `plan_scope_benign_path_classes` (token-collision check) | **verified** | the only `plan_scope` hit in AGENT_PROMPTS.md is line 1568 — `<!-- meta: metric name=plan_scope_silent -->` (a metric name in the Scope-enforcement safety-valve block, unrelated to the new resolver tokens). No collision. |
| 40 | The closed-vocabulary check on `defer_reason` (D-005 rule 1) does not conflict with any existing schema field — pre-ENG-194 ledger rows have no `defer_reason` field | **verified** | grep over `bin/review-ledger-schema.sh` and `AGENT_PROMPTS.md` returned no existing `defer_reason` usage this dispatch (also covered by #34) |
| 41 | `bin/scope-check.sh:300-307` documents the ENG-25 fix on the `allowed_files` regex (`*` not `+`) for repo-root files | **verified** | `bin/scope-check.sh:298-307` (read this dispatch — comment confirms ENG-25 fix) |
| 42 | `bin/scope-check.sh:308-314` documents the ENG-46 fix on the `allowed_dirs` awk filter for dotfile directories | **verified** | `bin/scope-check.sh:308-314` (read this dispatch — comment confirms ENG-46 fix) |

## 12. Out-of-scope flags

This brainstorm stays inside the Linear scope as written, plus the
operator-descoped subset. Three soft near-misses worth calling out
(each within scope but not literally enumerated):

- **D-001 (shared helper extraction to `bin/plan-scope.sh`).** Required
  by Linear AC #4 ("one helper, both callers"); structural extraction.
- **D-007 first resolver (`{plan_scope_allowed_paths}`).** Required by
  D-002 — the agent needs the parsed sets at render time; the resolver
  is the established plumbing. The SECOND resolver
  (`{plan_scope_benign_path_classes}`) and its rendering are explicitly
  carved out to ENG-194-B.
- **D-005 rule 6 cross-check.** Required to make AC #1 + AC #4 + AC #5
  structurally enforceable (without the cross-check the agent's claim
  is unaudited and an adversarial agent could fake `out-of-plan-scope`
  to bypass the convergence-rounds gate). This was added in
  iter-1-of-d0002 to address security iter-1 P0 #1; ships in v1.

All five Linear acceptance criteria map to concrete decisions:

- AC #1 (out-of-plan finding → `blocks_ship=false reason=out-of-plan-
  scope`, excluded from loopback) → D-002 + D-003 + D-004 + D-005
  (validator enforcement).
- AC #2 (routed to ENG-191 deferred-majors path, not silently dropped)
  → D-003 (`defer_reason` on row) + ENG-191's existing
  `_post_deferred_majors_comment_if_eligible` reading
  `blocks_ship=false` rows unchanged. The grouped comment shape
  improvement is ENG-194-A follow-up; AC #2 is structurally satisfied
  by the row appearing in the comment.
- AC #3 (in-plan finding unchanged) → D-002 (rubric fall-through) +
  D-004 (predicate compatibility).
- AC #4 (shared matcher; assert both call the same function) → D-001
  + D-008 (test 4 + test 5 byte-for-byte assertions).
- AC #5 (ENG-27-class advance instead of deadlock) → D-002 + D-004 +
  D-008 end-to-end fixture.

All Linear IN bullets covered:

- "The reviewer/adjudicator computes, per finding, whether the fix
  target falls within the plan's `## File Structure`" → D-002 + D-001
  (shared parse).
- "A finding whose fix is out-of-plan-scope is emitted with
  `blocks_ship=false` + reason `out-of-plan-scope`, routed to the
  deferred-majors comment/ticket path, and excluded from the loopback
  predicate" → D-003 (schema) + ENG-191 hook (unchanged comment shape)
  + D-004 (loopback exclusion via path-D predicate).
- "The shared matcher is the single source of truth so a finding the
  reviewer defers as out-of-scope is exactly what scope-check would
  have halted on (no divergence)" → D-001 (extraction) + D-005 rule 6
  (validator cross-check) + D-008 (byte-for-byte test). Note: this is
  PLAN-STRUCTURAL only; benign-path divergence per Edge case 8 is
  documented and bounded (closed by ENG-194-B follow-up).

All Linear OUT bullets honoured:

- "The deferred-major exit machinery itself (ENG-191)" → §8; consumed
  unchanged.
- "Auto-ticket creation (ENG-193)" → §8.
- "Fixing the scope-violation-resume break (ENG-180)" → §8;
  orthogonal, scope-deferred path bypasses the broken resume.

## 13. Persona review

Six personas, canonical order (design → security → scope → coherence
→ product → feasibility). Feasibility runs LAST per the dispatch
contract (codebase-fact errors are always P0). Iteration history in
§14. Verdicts below are this dispatch's iter-1 results after the
descope rewrite.

### Persona 1 — Design

**Iter-1 of d0003 verdict: PASS.**

- **Catch-22 dissolution.** The chosen structural mechanism — reviewer
  auto-classifies out-of-plan fixes as `blocks_ship=false defer_reason=
  "out-of-plan-scope"`, predicate extension at path D — closes the
  catch-22 without weakening scope-check's runtime gate (Linear option
  (c) rejected) and without pushing scope decisions into the
  implementer loop (Linear option (b) deferred).
- **Critical-floor preservation.** Critical-out-of-plan still loops
  back, scope-check halts, operator triages. The 2026-06-14 draft's
  D-002 final-paragraph operator-recipe meta-comment is descoped to
  ENG-194-C, leaving the critical case at standard recovery. This is a
  UX regression vs. the 2026-06-14 draft but does NOT degrade
  structural correctness — the operator path through
  `docs/runbooks/recovery.md` still works. Acceptable v1 cost
  documented in §6 Edge case 4.
- **Benign-path divergence (§6 Edge case 8).** Reviewer's matcher is
  STRICTER than scope-check's runtime gate (does not consult benign-
  path classes). For findings against benign-path files, the reviewer
  auto-defers when scope-check would have allowed the implementer to
  fix. v1 acceptable cost: routes to known debt instead of deadlocking
  (the structural failure mode this brainstorm exists to fix);
  benign-path-class findings are uncommon in practice. ENG-194-B
  closes the divergence as a follow-up.
- **Matcher cross-check (D-005 rule 6) shape.** Plan-structural-only
  matcher means the validator and the reviewer's prompt-side check use
  the SAME predicate. Cross-caller agreement is structurally
  achievable.
- **Fail-CLOSED on unparseable rationale (D-005 rule 6 sub-rule).**
  Anchored start+end regex + fail-closed eliminate the forge surface
  the 2026-06-14 draft's pre-iter-1-of-d0002 fail-open had. The
  anchored regex's `^...$` form rejects the `prefix-match-but-trailing-
  prose` adversarial shape.

P0: none. P1: none new. Pre-existing P1 carve-outs (D-006, D-007
second resolver, critical recipe) are descoped per operator decision
and tracked as sibling tickets.

### Persona 2 — Security

**Iter-1 of d0003 verdict: PASS.**

- **Forge surface on rationale.** D-005 rule 6's anchored regex
  (`^out-of-plan-scope:[[:space:]]+([^[:space:]]+)[[:space:]]+not in
  plan's File Structure$`) rejects `prefix-match + trailing-prose`
  forgeries. Combined with fail-CLOSED on parse failure, the agent
  CANNOT bypass the matcher cross-check via rationale shape
  manipulation.
- **Matcher cross-check defends the primary attack direction.** Agent
  claims `out-of-plan-scope` on an in-plan path to bypass convergence-
  rounds gate → matcher disagrees → rc=49. Direct structural defense.
- **Reverse direction (plan mutation) — bounded.** Edge case 17
  documents the reverse threat: agent edits `docs/plans/<plan>.md` to
  ADD an out-of-scope path then claims it's in-plan, bypassing the
  defer. v1 bounded weakness; plan-mutation defense
  (`_validate_dispatch_envelope` extension) deferred to ENG-194-D per
  operator descope. The trade-off is explicit: closing this requires
  the orchestrator subsystem touch, which would tip ENG-194 past 2
  subsystems. OQ-3 documents the bound; operator awareness via §1's
  carve-out enumeration.
- **Sanitisation on diagnostics.** All agent-controlled fields
  (`fix_target`, `scr`) flow through `sanitise_for_diag` per the
  D-005 rule 6 snippet. ENG-190 D-009 sanitisation contract honoured.
- **Closed vocabulary on `defer_reason`.** Two values only; no agent
  prose injection surface on the field itself.

P0: none. P1: residual bounded-weakness on plan mutation
direction is documented and operator-visible.

### Persona 3 — Scope

**Iter-1 of d0003 verdict: PASS.**

- **Operator descope decision is authoritative.** §0 + §1 + §8
  explicitly enumerate the descope: D-006, D-007 second resolver,
  D-002 critical-out-of-plan recipe, and plan-mutation defense are all
  carve-outs filed as ENG-194-A/-B/-C/-D follow-ups. The brainstorm's
  planning surface is strictly D-001 + D-002 + D-003 + D-004 + D-005 +
  D-007 first resolver + D-008.
- **2-subsystem accounting.** §1 enumerates the two subsystems:
  scope/sweep (D-001) + agent-prompts (D-002 + D-003 + D-004 + D-005 +
  D-007 first resolver). The validator's home in
  `bin/review-ledger-schema.sh` is treated as part of the agent-output
  contract subsystem (it enforces what §5 mandates). Within the
  autonomy-safe range with one clearly subordinate (scope/sweep
  extraction subordinate to the agent-prompts contract change).
- **No scope creep.** §12 maps every Linear AC + IN bullet to
  decisions; no orphaned decisions, no decisions outside the AC
  surface.
- **Follow-up tickets are bounded.** ENG-194-A/-B/-C/-D each have
  enumerated scope; none is an umbrella.

P0: none. P1: none.

### Persona 4 — Coherence

**Iter-1 of d0003 verdict: PASS.**

- **Critical+out-of-plan handling consistent.** §2 D-002 step 3,
  §4 critical-case worked example, §6 Edge case 4 all say the same
  thing: critical → blocks_ship=true unconditionally → path B
  loopback → scope-check halt → operator triages via standard
  recovery (NO meta-comment recipe in v1).
- **Multi-target finding rule consistent.** §2 D-002, §6 Edge case 3
  both pin the canonical-anchor (first body token after severity tag)
  as the SOLE fix-target.
- **`decision_factors` relaxation rule consistent.** §2 D-002 step 3
  ("OMITTED entirely or emitted as null"), §2 D-003 ("MAY be null or
  omitted"), §2 D-005 rule 3 (gate `defer_reason ==
  "out-of-plan-scope"` → skip decision_factors check), §2 D-008
  pin #4 (assert BOTH "OMITTED" and "null" appear in §5 wording) — no
  drift across sections.
- **AC mapping consistent.** §12 ACs map to decisions; §13 design
  persona references the same AC numbers; §10 simpler-alternative
  table covers each decision. No orphan claim.
- **Subsystem count consistent.** §1 + §3 + §9 all say 2 subsystems
  with the same partition; no drift.
- **D-007 first/second resolver carve-out consistent.** §1, §2 D-007,
  §8 ENG-194-B all consistently describe ONLY the first resolver as
  in-scope, the second as carved out.
- **Cross-check shape consistent.** §2 D-005 rule 6 (anchored regex +
  fail-CLOSED + plan-structural matcher), §5 halt cases table
  (fail-CLOSED behaviour described), §6 Edge case 6 (cross-check
  closes the primary forge direction). No drift.

P0: none. P1: none.

### Persona 5 — Product

**Iter-1 of d0003 verdict: PASS.**

- **Operator catch-22 dissolves.** §1 + §6 Edge case 4 + AC #5 fixture
  in D-008 describe the end-to-end path: ENG-27-class scenario
  advances at iter 1 with no operator intervention.
- **Operator regression vs. 2026-06-14 draft.** ENG-194-A
  (deferred-majors comment grouping) and ENG-194-C (critical-recipe
  meta-comment) are operator-UX improvements descoped to follow-ups.
  v1 ships with ENG-191's flat-list deferred-majors comment shape; the
  scope-deferred row IS in the comment (AC #2 satisfied) but not
  visually distinguished. Operators who need the distinction can read
  the ledger row's `defer_reason` field. Acceptable v1 cost; ENG-194-A
  is the next-priority sibling ticket.
- **Critical+out-of-plan UX regression.** v1 reverts to standard
  `docs/runbooks/recovery.md` triage (no meta-comment recipe trailer).
  Acceptable v1 cost; ENG-194-C is the cleanup sibling.
- **Plan-amend recipe documented.** §3 architecture lists
  `docs/runbooks/recovery.md` §14 addition — operator audit recipe for
  scope-deferred majors (read ledger for `defer_reason`; manual
  plan-amend + `--action continue` path). Discoverable through the
  established runbook surface.

P0: none. P1: none.

### Persona 6 — Feasibility

**Iter-1 of d0003 verdict: PASS.**

- **All 42 assumptions in §11 verified this dispatch.** Line citations
  re-checked against worktree HEAD via grep + Read. Key delta vs the
  2026-06-14 draft: assumption #16 (known-fields allowlist) corrected
  to line 404 in iter-1-of-d0002, re-confirmed this dispatch; the
  2026-06-14 draft's iter-2-of-d0002 P0 (validator-extension location:
  `bin/run-stage.sh:1039` not `bin/dispatch.sh`) is NOT relevant to
  the descoped v1 (plan-mutation defense is carved out to ENG-194-D),
  but assumptions #37 + #38 still verify the location for the
  follow-up ticket's benefit.
- **No tokens collide.** `plan_scope_allowed_paths` and `defer_reason`
  are both fresh per assumptions #34, #35, #39, #40.
- **Helper insertion site verified.** `bin/scope-check.sh:53` is
  `export PIPELINE_WRITER=scope-check`; sourcing `plan-scope.sh` after
  it is consistent with the `common.sh` sourcing at line 48
  (assumption #32).
- **AGENT_PROMPTS.md §5 boundaries verified.** Line 1335 (§5 start),
  line 1847 (§6 start), lines 1439-1480 (deferability adjudication —
  insertion-after site), lines 1481-1500 (count-tuple — insertion-
  before site), lines 1614-1620 (mechanical predicates — update
  site), lines 1572-1586 (review-comment-quality rubric — anchor
  source-of-truth). All re-verified this dispatch via grep.
- **Validator landmarks verified.** `_emit_incomplete` at line 135,
  `sanitise_for_diag` at line 115, `_warn_unknown` at line 145,
  closed-vocabulary check insertion point after critical-floor block
  at 362-365, `decision_factors` check at 375-390 (the relaxation
  target), known-fields allowlist at 404. All re-verified this
  dispatch via grep or Read.
- **`bin/scope-check.sh` refactor sites verified.** Lines 143-157
  (`find_canonical_plan` body), 159-172 (`extract_scope_section`
  body), 297-314 (allowed_files/allowed_dirs parse), 356-366
  (per-file in-scope check), 368-391 (benign + notable + tier
  logic preserved). All re-read this dispatch.
- **`bin/render-prompt.sh` resolver landmarks verified.**
  `PROMPT_RESOLVERS` at lines 40-62, `_resolve_review_converge_rounds`
  precedent at 292-303, sidecar enumerator at 94-127, residual
  validator at line 451. All re-verified.

P0: none. P1: none new. Assumption #24 (path-D verbose body line
number) carries a soft caveat noting line numbers may shift between
draft and implementation; implementation re-verifies at edit time.

**Gate verdict: 6/6 PASS, 0 P0. Proceed to planning.**

## 14. Iteration history

- **Iteration 1 (2026-06-14, dispatch d0001).** Initial draft.
  Verdicts: Design CONCERN (2 P0, 3 P1), Security CONCERN (1 P0,
  3 P1), Scope PASS (2 P1), Coherence CONCERN (1 P0, 4 P1), Product
  PASS (3 P1), Feasibility PASS (0 P0, 0 P1). Total 3/6 PASS, 4 P0.
  Gate NOT met; iterated.

- **Iteration 2 (2026-06-14, dispatch d0001).** All 4 P0 findings
  addressed; tested 6/6 PASS internally. Gate MET. Doc committed at
  `1a5d294`.

- **Iteration 1 of d0002 (2026-06-14, dispatch d0002).** Fresh dispatch
  surfaced fresh P0s, mostly tightening the iter-2 defense-in-depth:
  (1) Feasibility P0 #1 known-fields allowlist line correction;
  (2) Design + Security P0 #1 fail-CLOSED + anchored regex on D-005
  rule 6; (3) Design P0 #2 lockfile cross-check blindspot;
  (4) Security P0 #2 plan-mutation defense via
  `_validate_dispatch_envelope`; (5) Scope P0 #1 Option-B carve-out
  surfaced for operator decision; (6) Scope P0 #2 D-005 rule 6
  acknowledged as scope expansion forced by security defense-in-depth.
  Doc committed at `74933d1`.

- **Iteration 2 of d0002 (2026-06-14, dispatch d0002).** Personas
  re-ran; 4/6 PASS + 2 CONCERN. Feasibility CONCERN with 1 P0:
  D-005 rule 6's plan-mutation paragraph cited `bin/dispatch.sh` for
  `_validate_dispatch_envelope`'s home, actual location is
  `bin/run-stage.sh:1039`. Sibling test should be
  `bin/run-stage-test.sh` not `bin/dispatch-test.sh`. Targeted fix
  applied; persona not re-verified (iter-3 forbidden per dispatch
  contract). Gate NOT met. Halt with `iteration-exhausted`.

- **Operator DESCOPE decision (2026-06-16).** Operator inspected the
  d0002 result and chose path 2 of the scope persona's
  operator-decision flag: descope to autonomy-safe 2-subsystem shape.
  Three carve-outs filed for sibling ticketing: D-006, D-007 second
  resolver, D-002 critical-out-of-plan recipe trailer. Commit
  `f804369`. The 2026-06-14 draft was preserved (carries the full
  history) and remains the source of follow-up ticket detail.

- **Iteration 1 of d0003 (2026-06-16, this dispatch).** Fresh
  brainstorm written per operator descope. Authoritative scope
  D-001 + D-002 (plan-scope-only) + D-003 + D-004 + D-005 + D-007
  first resolver + D-008. Plan-mutation defense (was iter-1-of-d0002
  security P0 #2) ALSO deferred to ENG-194-D follow-up because it
  touches the orchestrator subsystem — keeping it would tip ENG-194
  past 2 subsystems. D-001 simplified to 5 single-responsibility
  functions (no benign-path partitioning, no 2-arg convenience
  wrapper); D-005 rule 6 cross-check uses plan-structural matcher
  only; §5 prompt block consults `{plan_scope_allowed_paths}` only
  (no second resolver). Personas re-run internally: 6/6 PASS, 0 P0.
  Gate MET. Proceed to commit + verdict-pass.
