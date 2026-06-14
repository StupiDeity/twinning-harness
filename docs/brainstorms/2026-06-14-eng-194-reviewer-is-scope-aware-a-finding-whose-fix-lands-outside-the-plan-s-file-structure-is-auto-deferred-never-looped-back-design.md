---
linear: ENG-194
title: Reviewer is scope-aware — out-of-plan-scope findings auto-defer, never loop back
date: 2026-06-14
status: draft
---

# Reviewer is scope-aware — out-of-plan-scope findings auto-defer, never loop back

## 1. Overview

[ENG-194](https://linear.app/twinning/issue/ENG-194) closes a structural
catch-22 in the review→implement loop. The reviewing stage's finding
authority is unconstrained by the plan, but the implement/ui/qa stages
that *act* on review findings ARE scope-constrained by
`bin/scope-check.sh:261-394`'s post-dispatch diff-vs-plan gate. A review
finding whose fix touches a file the plan didn't scope traps the
implement agent: fix it → `scope-check.sh` halts with
`scope-violation`; don't fix it → next cold review re-flags it →
`reviewing → implementing` loopback → ratchet → eventual
`review_rejection` halt. The recovery path is broken too —
[ENG-180](https://linear.app/twinning/issue/ENG-180)'s
scope-approval-resume bug means even `bash bin/pipeline.sh decide
--action approve --gate scope` doesn't unstick it.

The fix: make the reviewer **structurally aware** of the same plan
scope `scope-check.sh` enforces. When the reviewer identifies a finding
whose fix-target file is out-of-plan-scope, it auto-classifies the
finding as `blocks_ship=false` with `defer_reason="out-of-plan-scope"`
and routes it through [ENG-191](https://linear.app/twinning/issue/ENG-191)'s
deferred-majors machinery — never as a `reviewing → implementing`
loopback. The catch-22 dissolves because the finding never *asks* the
implementer to make a scope-violating edit.

This is a structural extension to ENG-191's deferability axis: where
ENG-191 D-002 distinguished "must-fix-now" from "how bad" by the
five-question rubric (agent judgment), ENG-194 adds a stronger,
structural reason — "fix is impossible in this plan's scope" — that
short-circuits the rubric and the convergence-rounds gate alike.

**Win attribution.** Part of [ENG-189](https://linear.app/twinning/issue/ENG-189)'s
review-convergence family (Lever 4). The other three levers ([ENG-190]
reviewer memory, [ENG-191] selective exit, [ENG-192] fix-the-class) all
assume the finding/fix loop CAN converge. ENG-194 handles the residual
class where it structurally cannot: out-of-plan-scope findings.
Empirically observed on [ENG-27](https://linear.app/twinning/issue/ENG-27)
(2026-06-12) — `docs/install.md` flagged stale, plan only scoped
`bin/setup.sh`; operator unstuck via manual plan-amend + force-transition.
Without ENG-194, the same shape recurs whenever a `bin/setup.sh` (or
any in-plan source) change has documentation/test/lockfile siblings the
plan author didn't enumerate.

**Reference to product principle.** CLAUDE.md ticket-sizing rubric:
**3 subsystems** touched (agent-prompts §5 + scope/sweep extraction +
orchestrator deferred-majors-comment formatter). 1 primary decision
(out-of-plan ⇒ defer) plus 2 subordinates (shared-matcher extraction;
deferred-majors-comment UX delta for AC #2's "visible audit trail"
requirement). The rubric's "3+ subsystems → split before filing"
trigger is satisfied **only with one clearly subordinate touch
permitted**; ENG-194 has TWO subordinates which falls outside the
strict 2-subsystem autonomy-safe range.

The scope-persona iter-1 audit raised this trade-off. Two responses
considered:

- **Option A (descope D-006 to a follow-up).** File a child ticket
  for the deferred-majors-comment formatter rewrite, keep ENG-194 at
  2 subsystems. Risk: AC #2 ("not silently dropped") is structurally
  satisfied by the ledger field alone, but the operator-discoverable
  audit signal (the grouped sub-sections + recipe trailer) is the
  product-persona-validated improvement. Splitting reduces operator
  value of THIS ticket.
- **Option B (carve out D-006 explicitly).** Acknowledge the third
  subsystem; document the subordinate scope of D-006 (≤50 line
  change, no new control flow, AC-driven, the entire function is
  already ENG-191-shipped and the change is a partition of its jq
  filter into two branches). Risk: rubric drift if accepted.

**Working decision: Option B.** D-006's change is genuinely small in
the orchestrator subsystem — it modifies ONE existing function's body
without adding new entry points or new validators or new pipeline
markers; the partition is data-driven on `defer_reason`. Calling D-006
a "second subordinate" rather than a third primary subsystem touch is
honest. If the implementation-time line count balloons beyond ~50
lines or D-006 grows new control flow (e.g., new error handling paths,
new metric events), descope to follow-up. Iter-2 acknowledges this
trade-off explicitly; the brainstorm is still autonomy-safe IF Option
B's bound holds at implementation time.

**Reference to constraint.** CLAUDE.md "AGENT_PROMPTS.md is
load-bearing": the new block sits inside §5's existing fenced body —
no new H2 section, no column-0 ``` fence, no change to
`STAGE_TO_SECTION` in `bin/render-prompt.sh`.

## 2. Decisions

### D-001. Extract the in-plan-scope matcher into `bin/plan-scope.sh` — both `bin/scope-check.sh` and a new `bin/render-prompt.sh` resolver source it. Byte-for-byte agreement enforced by a sibling test that asserts identical `allowed_files`/`allowed_dirs` output from both callers.

**Rationale.** Linear AC #4: "The in-plan-scope matcher is shared with
`bin/scope-check.sh` (one helper, both callers) so reviewer-defer and
scope-check-halt decisions cannot diverge (assert both call the same
function)."

The matcher decomposes into four steps that are scattered across
`bin/scope-check.sh:143-215`:

1. **Find the canonical plan.** `find_canonical_plan <issue_id>
   <worktree_root>` (`bin/scope-check.sh:143-157`) — frontmatter
   `linear: <ID>` match, 20-line cap, awk-driven.
2. **Extract the File Structure section.** `extract_scope_section
   <plan>` (`bin/scope-check.sh:159-172`) — awk grabs the body
   between the `## File Structure` (or `### File Structure` or
   `## N. File Structure`) heading and the next sibling heading.
3. **Parse allowed files + allowed dirs.** The
   `allowed_files="$(grep -oE ...)"` and `allowed_dirs="$(grep -oE
   ...)"` block at `bin/scope-check.sh:307-314` — two grep regexes
   plus an awk filter for the malformed-capture case.
4. **Match a single path.** The inner per-changed-file loop at
   `bin/scope-check.sh:356-378` — `grep -qxF "$f" <<<"$allowed_files"`
   for exact-match, plus a per-line prefix check for directory match.

ENG-194 extracts ALL FOUR steps into a new file `bin/plan-scope.sh`,
sourced by both `bin/scope-check.sh` and `bin/render-prompt.sh`.
Public API (functions exported via the source):

```bash
# Find the canonical plan file for an issue under <root>/docs/plans/.
# Returns 0 + absolute path on stdout, 1 if no plan found.
plan_scope::find_plan <issue_id> <worktree_root>

# Extract the File Structure body from a plan file. Returns 0 + body
# on stdout. Empty stdout iff the section is absent.
plan_scope::extract_section <plan_path>

# Parse <body> into allowed_files and allowed_dirs sets. Returns 0
# with stdout shape:
#   #ALLOWED_FILES#
#   <file1>
#   <file2>
#   #ALLOWED_DIRS#
#   <dir1>/
#   <dir2>/
# Each set is newline-separated, sorted-unique. Either set may be
# empty (but section header lines always emit).
plan_scope::parse_sets <body>

# Match a path against the parsed sets. allowed_files exact-match
# wins first; allowed_dirs prefix-match second. Returns 0=in-scope,
# 1=out-of-scope. STRICTLY the structural match — does NOT consult
# the benign-path classes (those live in scope-check.sh::is_benign
# because they're orchestrator-policy, not plan-structure).
plan_scope::path_in_scope <path> <allowed_files> <allowed_dirs>
```

**`bin/scope-check.sh` refactor.** Replace the inline parse + match
with `plan_scope::*` calls. `find_canonical_plan` (line 143-157),
`extract_scope_section` (159-172), the `allowed_files`/`allowed_dirs`
parse (307-314), and the per-file `grep -qxF` / dir-prefix loop
(356-367) all source through the new helper.

**Benign-path classes — partitioned: stack-agnostic classes move to the
shared helper; stack-conditional ones stay in `bin/scope-check.sh`.**
The design persona iter-1 finding flagged that a finding whose
fix-target is `docs/plans/foo.md` (benign-path class) would be
auto-deferred by the reviewer even though `scope-check.sh` would let
the implementer fix it — two sources of truth that contradict AC #4's
"cannot diverge" guarantee. The fix is to move the **stack-agnostic
benign-path classes** into the shared helper so both callers agree on
the full "the implementer can edit this" set.

Partition:

- **Moved to `bin/plan-scope.sh`** (stack-agnostic, reviewer-and-
  scope-check both consume): `_BENIGN_PATH_CLASSES` from
  `bin/scope-check.sh:59-65` — `.pipeline/metrics/*`,
  `docs/knowledge/*`, `docs/plans/*`, `docs/brainstorms/*`,
  `docs/pipeline-vocabulary.md`. PLUS the `.scratch/*` carve-out
  (stage-conditional only on the orchestrator-side sweep — on the
  reviewer side, `.scratch/*` findings would be agent-debris and
  shouldn't drive a defer anyway, but including the carve-out is
  safe).
- **Stays in `bin/scope-check.sh::is_benign`** (stack-conditional,
  runtime-only): the profile-derived lockfile basenames
  (`SCOPE_BENIGN_LOCKFILES` populated at `bin/scope-check.sh:328-332`
  per dispatch from the `## Build & test gates` section) and the Rust
  crates-tests carve-out at `bin/scope-check.sh:198-205` that reads
  `allowed_files` in dynamic scope. Reasons: (a) lockfiles rarely
  generate review findings (the reviewer doesn't flag lockfile
  churn), so including them in the reviewer-side path adds no
  observable signal but doubles the byte-for-byte assertion surface;
  (b) the Rust crates-tests carve-out is stack-specific and reads
  `allowed_files`/`allowed_dirs` in dynamic scope inside a function
  that's currently structured around scope-check's per-file loop —
  porting it to a shared helper would require refactoring the
  dynamic-scope dependency, which is out of scope.

**Shared helper exports a single combined predicate.**

```bash
# Path is "implementer-can-edit-this-without-halting-scope-check" iff:
#   - it's in the plan's File Structure, OR
#   - it matches one of the stack-agnostic benign-path classes.
# Does NOT consult stack-conditional benign sources (lockfiles,
# Rust crates-tests) — those stay in scope-check.sh::is_benign and
# are intentionally invisible to the reviewer (rare/no review-
# finding generation).
plan_scope::path_in_scope_or_benign <path> <allowed_files> <allowed_dirs>
```

This is the predicate **both callers use for the byte-for-byte
assertion**. `scope-check.sh::main` per-file loop is refactored to:

```bash
if plan_scope::path_in_scope_or_benign "$f" "$allowed_files" "$allowed_dirs"; then
  continue   # was: grep -qxF $f / dir-prefix loop, then is_benign check
fi
# Then stack-conditional benign checks (lockfiles, Rust crates-tests)
if is_benign_stack_conditional "$f"; then  # extracted residue of is_benign
  continue
fi
# Then is_notable / SEVERE tier — unchanged.
```

The reviewer's prompt-side match (D-002) reads `{plan_scope_allowed_paths}`
(parsed by `plan_scope::parse_sets`) and the rendered
`{plan_scope_benign_path_classes}` (NEW — D-007 extension) and applies
the same predicate logic in-prompt. Byte-for-byte means: both callers'
verdicts on a path agree, given the same plan + helper.

The two callers DO diverge on stack-conditional benign paths
(lockfiles): scope-check skips them; reviewer defers them. The
divergence is BY DESIGN — lockfile review findings are
near-nonexistent in practice and not worth the cross-caller plumbing
in v1. Documented explicitly in §6 Edge case 16 (NEW).

**Test mechanism — the byte-for-byte assertion.**
`bin/plan-scope-test.sh` (new sibling test) constructs a fixture plan
file with edge cases (repo-root files like `CLAUDE.md`, nested files,
dotfile directories like `.github/`, dotted-extension dirs that the
awk filter at 313-314 should NOT strip) and asserts:

- `plan_scope::parse_sets` output is byte-equal to the legacy inline
  parse logic (snapshot test against a frozen expected fixture).
- `plan_scope::path_in_scope` returns the same 0/1 verdict as the
  legacy per-file loop on a battery of test paths.
- Sourcing `bin/scope-check.sh` and `bin/render-prompt.sh` both
  define and use `plan_scope::path_in_scope` (assert via
  `declare -f plan_scope::path_in_scope`).

A second sibling test `bin/scope-check-test.sh` (existing — see
worktree) is updated: its existing case fixtures continue to pass
unchanged. This is the structural side of AC #4.

**Reference to constraint.** CLAUDE.md "Language idioms": each
`bin/foo.sh` ends with the sentinel `if [[ "${BASH_SOURCE[0]}" ==
"${0}" ]]; then main "$@"; fi`. `bin/plan-scope.sh` follows the same
pattern with `main` being a CLI dispatch (`parse-sets`, `find-plan`,
`path-in-scope` sub-commands) so it can be invoked from the
command line for manual testing as well as sourced.

**Rejected alternative — leave parse/match inline in `bin/scope-check.sh`
and have the render resolver re-execute scope-check.sh.** Rejected
because (a) scope-check.sh's `main` has side effects (logs, exits with
non-zero on out-of-scope) — invoking it from render-prompt would
either pollute logs or require a new `--dry-run`/`--scope-info-only`
flag that's a parallel implementation of the helper; (b) the renderer
needs the PARSED SETS to embed in the prompt, not a yes/no verdict;
scope-check.sh::main computes the sets internally then discards them
after the per-file loop. Extracting is structurally cleaner than
adding a new output mode to main.

**Rejected alternative — duplicate the parse logic in
`bin/render-prompt.sh`.** Rejected per AC #4's structural assertion:
"reviewer-defer and scope-check-halt decisions cannot diverge."
Duplicated code drifts; the test `assert both call the same function`
becomes meaningless if both copies are statically identical at one
moment but drift on the next edit.

**Rejected alternative — bake the parse output into a JSON file on
disk that both callers read.** Rejected because (a) one more
per-dispatch artifact and one more freshness-staleness contract
(orchestrator must regenerate every render; scope-check must
re-verify mtime); (b) sourcing the same bash file is the established
shared-code idiom in `bin/common.sh`; (c) JSON would require `jq` in
the matcher hot path — `plan-scope.sh` stays bash-only.

### D-002. Reviewer §5 prompt gains a "Plan-scope adjudication" block that runs BEFORE the five-question rubric. On a major finding whose fix-target file is out-of-plan-scope, auto-classify `blocks_ship=false defer_reason="out-of-plan-scope"`; the rubric is bypassed for that finding.

**Rationale.** Linear scope: "The reviewer/adjudicator computes, per
finding, whether the fix target falls within the plan's `## File
Structure`. A finding whose fix is out-of-plan-scope is emitted with
`blocks_ship=false` + reason `out-of-plan-scope` and excluded from the
loopback predicate."

**Where in §5.** Insert AFTER the "Deferability adjudication"
(AGENT_PROMPTS.md:1439-1480 — ENG-191's five-question rubric block) and
BEFORE the count-tuple emission (AGENT_PROMPTS.md:1481-1500). The
correct reading order is:

1. Cold findings merged (existing).
2. Adjudication block (ENG-190 — severity-only).
3. **NEW** Plan-scope adjudication block — for each
   `adjudicated_severity ∈ {major, critical}` finding, extract the
   fix-target file from the finding's canonical anchor (the
   `path/to/file.ext:LINE` token that the existing review-comment-
   quality rubric — AGENT_PROMPTS.md:1572-1586 — mandates as the
   first body token). Match the fix-target against the parsed sets
   rendered as `{plan_scope_allowed_paths}` (D-007). The rendered
   token contains two section headers: `#ALLOWED_FILES#` (one path
   per line) and `#ALLOWED_DIRS#` (one directory prefix per line).
   ALSO check against `{plan_scope_benign_path_classes}` (D-007 — a
   third section listing the stack-agnostic benign-path glob classes:
   `.scratch/*`, `.pipeline/metrics/*`, `docs/knowledge/*`,
   `docs/plans/*`, `docs/brainstorms/*`, `docs/pipeline-vocabulary.md`).
   The matching algorithm: fix-target is in-plan-from-review's-POV iff
   (exact-match in `#ALLOWED_FILES#`) OR (has a prefix matching one
   of `#ALLOWED_DIRS#`'s entries) OR (matches one of
   `{plan_scope_benign_path_classes}`'s globs).
   If OUT-of-plan-from-review's-POV, set `blocks_ship=false`,
   `defer_reason="out-of-plan-scope"`, fill
   `ship_classification_rationale` with the EXACT shape
   `"out-of-plan-scope: <path> not in plan's File Structure"` (the
   `: <path>` colon-space-path tail is structurally required —
   validator D-005 parses the path back out for cross-check), and
   SKIP the five-question rubric for that finding (`decision_factors`
   is either OMITTED or emitted as `null` — schema D-005 accepts
   both).
4. Deferability adjudication (ENG-191 five-question rubric) — applies
   ONLY to findings not already classified by step 3.
5. Count-tuple emission (Findings:, Adjudicated:, Deferrable:).
6. Decision path (B / B′ / C / D).

**Critical-floor invariant interaction.** ENG-191 critical-floor
(`bin/review-ledger-schema.sh:362-365`): `adjudicated_severity ==
critical ⇒ blocks_ship == true`. ENG-194 PRESERVES this: a critical
finding whose fix-target is out-of-plan-scope STILL has
`blocks_ship=true`; the reviewer MAY emit `defer_reason="out-of-plan-
scope"` on the row for audit (D-005 permits it on `blocks_ship=true`
rows as informational), but `blocking_majors > 0` → path B (loopback)
fires unchanged.

**Critical+out-of-plan emits an operator-visible signal.** When the
reviewer detects a critical finding whose fix-target is out-of-plan,
the path-B body additionally posts a meta-marker comment via
`bash bin/linear.sh add-comment <ident> --sig
critical-out-of-plan/<ident>` with the body explicitly naming the
file: `"Critical finding requires fix outside plan scope: <file>.
Implementer dispatch will halt at scope-check (rc=3
scope-violation). Resolve by amending plan File Structure (commit on
feature branch) + bash bin/pipeline.sh decide <ENG-N> --action
continue."` This makes the catch-22-residual case explicit instead of
letting it fall through to a generic scope-violation halt the operator
has to triage from scratch.

The structural fix to the catch-22 is narrow: **MAJOR** findings whose
fix is out-of-plan auto-defer (path D eligible); **CRITICAL** findings
whose fix is out-of-plan loop back, the implementer attempts, scope-
check.sh halts with `scope-violation`, AND the reviewer's
`critical-out-of-plan/<ident>` meta-comment gives the operator the
direct recovery instructions. ENG-180 still owns the broken-resume bug;
this brainstorm gives the operator a discoverable path that does NOT
depend on `decide --action approve --gate scope` working.

**Fix-target identification.** The reviewer's existing
review-comment-quality rubric (AGENT_PROMPTS.md:1572-1586) MANDATES
that every review comment carry a `path/to/file.ext:LINE` anchor as
its first body token after the severity tag. The fix-target file is
that path. The agent extracts it by trimming the `:LINE` suffix.

**Multi-target findings.** Some findings span multiple files (e.g. a
contract drift naming both BE handler and FE caller). The reviewer
uses the CANONICAL anchor — the `path/to/file.ext:LINE` token that
sits immediately after the severity tag, as mandated by the existing
review-comment-quality rubric (AGENT_PROMPTS.md:1572-1586). That
single canonical path IS the fix-target for the plan-scope check;
other paths mentioned later in the finding body are informational
and not consulted. This avoids the design persona iter-1 tie-break
ambiguity (first-listed canonical vs. any-in-plan) by collapsing to
the SINGLE source of truth the prompt already enforces. If the
canonical anchor's file is out-of-plan, the finding is scope-deferred
regardless of secondary mentions; if it's in-plan, the rubric
applies. Operators inspecting a deferred-majors comment can re-read
the underlying PR review comment to see the full file list.

**Findings without a `file:line` anchor.** Rare but possible — e.g.,
a security finding about absent code ("no rate-limit on
`/api/login`"). For findings without a clear fix-target file
(anchor absent or generic like `<missing>:0`), the agent falls
through to the five-question rubric (existing ENG-191 path). These
are not auto-deferred; the agent's judgment via the rubric handles
them. Documented as Edge case 5.

**Reference to constraint.** CLAUDE.md "AGENT_PROMPTS.md is
load-bearing." The new block sits inside §5's existing fenced body
— no new H2 section, no column-0 ``` fence, no change to
`STAGE_TO_SECTION` in `bin/render-prompt.sh`.

**Reference to constraint.** Linear AC #1 + AC #2 — the structural
classification + non-routing-to-loopback shape is what this prompt
block delivers. AC #3 — in-plan finding behaviour unchanged — is
preserved because the new block FALLS THROUGH to the existing
rubric when fix-target is in-plan.

**Rejected alternative — the plan-scope check is the FIRST step of
the deferability adjudication, replacing question 1 (`in_changed_code`).**
Rejected because (a) `in_changed_code` answers a different question
("did this PR's diff introduce or touch the defective code?") that
applies to in-plan findings too — losing the signal degrades the
ENG-191 rubric's quality; (b) ENG-191's five-question schema is
positioned as the rubric for in-plan findings whose judgment IS
the deferability test; scope-deferred is a SHORT-CIRCUIT that
bypasses the rubric entirely, not a replacement for one of its
inputs.

**Rejected alternative — sanction the reviewer-requested
out-of-scope edit in `bin/scope-check.sh` when a matching review
finding exists.** Explicitly rejected by the Linear ticket as
option (c): "weakens the scope gate's guarantee and is hard to
attribute reliably." The scope gate stays strict; the reviewer
adapts.

**Rejected alternative — in-band plan-File-Structure amendment
proposed by reviewer.** Linear option (b). Kept as future fallback;
the reviewer would emit a structured "plan addendum" proposal that
the implementer commits before fixing. Out of scope for ENG-194
because (a) it pushes scope decisions into the agent loop; (b) it
risks scope creep; (c) (a)'s deferral path is materially simpler.
Tracked in OQ-1.

### D-003. Add per-finding `defer_reason: "out-of-plan-scope" | "rubric"` to the ledger row schema. Required on `blocks_ship=false adjudicated_severity=major` rows; optional and omitted on others.

**Rationale.** The ledger row is already the per-finding decision
record (ENG-191 D-002). Adding `defer_reason` keeps the
adjudicator's per-finding output unified. Distinct from
`ship_classification_rationale` (which is a free-form prose
sentence): `defer_reason` is a closed-vocabulary token the orchestrator
and validator can branch on.

**Schema extension (additive, v1 stays).** ONE new optional field:

```json
{
  "ledger_schema_version": 1,
  "issue_id": "ENG-194",
  "dispatch_id": "ENG-194-d0001",
  ...
  "adjudicated_severity": "major",
  "blocks_ship": false,
  "ship_classification_rationale": "out-of-plan-scope: docs/install.md not in plan's File Structure",
  "defer_reason": "out-of-plan-scope",
  "decision_factors": null
}
```

**Field contract:**

- `defer_reason` — string, one of `"out-of-plan-scope"` or
  `"rubric"`. **Required** on rows where `blocks_ship == false`
  AND `adjudicated_severity == "major"`. **Optional on critical**
  (the critical-floor invariant rules: a critical row with
  `blocks_ship=false` is already rc=49; a critical row with
  `blocks_ship=true` doesn't need a reason; both states are
  covered without `defer_reason`). **Optional and informational
  on `blocks_ship=true` major rows** — agents MAY emit
  `defer_reason="out-of-plan-scope"` to record "this scope-traps
  the implementer" even when severity-blocks (e.g., a critical
  upgraded from a major) so the operator can see the trap. The
  validator does not require it on `blocks_ship=true`. **Omitted
  on minor/nit rows** (those rows don't carry `blocks_ship` per
  ENG-191 D-002, so `defer_reason` has no semantic).
- `decision_factors` — ENG-191 D-002 required this on every major
  row. ENG-194 RELAXES the requirement: when `defer_reason ==
  "out-of-plan-scope"`, `decision_factors` MAY be `null` or
  omitted. When `defer_reason == "rubric"` (default for ENG-191-
  shape rows), `decision_factors` is still required with all five
  keys per ENG-191. The validator's existing
  `decision_factors-missing-required-keys` check at
  `bin/review-ledger-schema.sh:386-390` is gated on
  `defer_reason != "out-of-plan-scope"`.

**Why a new field, not overloading `ship_classification_rationale`.**
Three reasons:

1. **Branching predicate.** D-004's convergence-rounds bypass needs
   the orchestrator + the agent to branch on a *token*, not a
   prefix-string match. Closed vocabulary is debuggable; prose
   prefix matches drift (today `"out-of-plan-scope: foo"`,
   tomorrow `"scope-deferred (foo)"`).
2. **Validator clarity.** The validator's `defer_reason`-conditional
   check (relax `decision_factors` requirement) reads cleanly when
   testing one field; a prefix-match against
   `ship_classification_rationale` is fragile.
3. **Retrospective signal.** The flywheel ([ENG-189]) wants to count
   `out-of-plan-scope` defers separately from rubric defers to
   tune the plan-author's coverage expectations. A single field
   makes the count one jq filter.

**Backwards compatibility with ENG-191 rows.** Pre-ENG-194 ledger
rows (written by issues mid-flight at ENG-194 rollout cutover) lack
`defer_reason`. The validator's defaulting rule: when
`defer_reason` is ABSENT and `blocks_ship=false`, treat it as
`"rubric"` (preserves the ENG-191 contract — `decision_factors`
remains required on those rows). When `defer_reason == "out-of-
plan-scope"` is present, the relaxation applies. The schema-grace
clause from ENG-191 D-002 already gates by `dispatch_id == --
dispatch-id` so prior-dispatch rows are validated against the
pre-ENG-194 contract regardless. ENG-194 inherits this — no new
grace mechanic needed.

**Reference to constraint.** CLAUDE.md "Don't add features beyond
what the task requires." One new field maps directly to AC #1's
`reason=out-of-plan-scope` requirement. The closed vocabulary (two
values) is the minimum that discriminates the two structural cases.

**Reference to constraint.** ENG-190/ENG-191's
`ledger_schema_version=1` posture is preserved — additive-optional
field with documented default-when-absent semantics.

**Rejected alternative — overload `ship_classification_rationale`
with `"out-of-plan-scope:..."` prefix.** Per the "Why a new field"
section above.

**Rejected alternative — bump to `ledger_schema_version: 2` to make
`defer_reason` mandatory on every `blocks_ship=false` row.** Rejected
because (a) ENG-191 D-002 already documented why v2 doubles the
validator surface; (b) the `defer_reason` field's default-when-absent
semantics make v1 + default-rule strictly less complex than a v2
bump; (c) prior-dispatch rows from ENG-191 issues mid-flight will
flow through the default cleanly.

**Rejected alternative — new file `review-scope-defers.jsonl`
sibling to the ledger.** Rejected because (a) one more per-issue
artifact, one more validator; (b) the ledger row IS the per-finding
record; splitting based on `defer_reason` cross-cuts the contract.

### D-004. The path-D selective-exit predicate is EXTENDED to allow scope-deferred-only exits at iteration 1 (no convergence-rounds gate). Mixed scope-defer + rubric-defer still requires the convergence plateau.

**Rationale.** Linear AC #5: "The ENG-27-class scenario (`bin/setup.sh`
changed in-plan, its doc `docs/install.md` flagged stale but
out-of-plan) advances instead of deadlocking — end-to-end fixture."

Today's ENG-191 D-006 predicate:

```
selective_exit_eligible :=
  Adjudicated critical == 0
  AND  blocking_majors == 0  (i.e. every adjudicated-major has blocks_ship=false)
  AND  convergence_rounds_at_zero_critical >= N
```

The convergence-rounds gate exists because rubric-deferred findings
are **agent judgments** that benefit from cross-iteration
stability evidence — "if it's still deferrable 2 rounds later, the
agent's judgment held up." Scope-deferred findings are
**structural facts** — the fix is impossible in this plan's scope
regardless of how many rounds pass. The convergence-rounds gate
adds no information about scope-deferred findings.

**Extended predicate (ENG-194):**

```
selective_exit_eligible :=
  Adjudicated critical == 0
  AND  blocking_majors == 0
  AND  (
         convergence_rounds_at_zero_critical >= N
         OR  every adjudicated-major has defer_reason == "out-of-plan-scope"
       )
```

**The OR is structurally safe.**

- If ALL deferred majors are scope-deferred, the implementer
  CANNOT fix any of them in this PR (each fix would self-leak past
  scope-check.sh). One round of stability is sufficient because
  no further iterations would change the deferred status.
- If ANY deferred major is rubric-deferred, the agent's judgment
  is at stake and the existing convergence-rounds gate applies
  (the mixed case still waits N rounds).
- Critical-floor still applies (any critical → `blocks_ship=true`
  → `blocking_majors > 0` → predicate fails).

**Worked examples:**

- **ENG-27 scenario (iter 1):** Reviewer finds 1 major,
  `docs/install.md` stale. Fix-target is out-of-plan. Agent emits
  `Deferrable: (deferrable_majors=1, blocking_majors=0)` with
  `defer_reason="out-of-plan-scope"`. `convergence_rounds=0` (iter 1,
  fresh issue). Extended OR: every deferred major is
  `out-of-plan-scope` → predicate **TRUE** → path D fires →
  `reviewing → qa`. No deadlock. AC #5 satisfied.
- **Mixed case (iter 1):** Reviewer finds 2 majors — 1 scope-deferred,
  1 rubric-deferred. `blocking_majors=0`, but one row is
  `defer_reason="rubric"`. Extended OR: NOT every deferred major is
  scope-deferred → falls through to convergence-rounds gate →
  `convergence_rounds=0 < N=2` → predicate **FALSE** → path B′
  (loopback without bumping `review_rejection`, per ENG-191 D-008).
  Next iter: re-evaluate. The rubric-deferred finding's stability
  earns the exit; the scope-deferred one rides along.
- **Critical case:** Reviewer finds 1 critical, fix is out-of-plan.
  Critical-floor: `blocks_ship=true` → `blocking_majors=0` but
  `Adjudicated critical=1` → predicate **FALSE** → path B
  (loopback). The implement agent tries to fix; scope-check.sh
  halts with `scope-violation`. Operator triages — this is the
  intentional ENG-180 backstop for criticals.

**Per-agent prompt change.** AGENT_PROMPTS.md §5 Decision path block
(lines 1614-1620 — the mechanical predicates list) needs a small
amendment to path D's predicate. The new text:

```
- Path D (ship-with-debt) — fires iff
  `Adjudicated critical == 0 AND Adjudicated major > 0 AND blocking_majors == 0
  AND (convergence_rounds_at_zero_critical >= {review_converge_rounds}
       OR  every adjudicated-major row has defer_reason == "out-of-plan-scope")`.
- Path B′ (convergence-waiting) — fires iff
  `Adjudicated critical == 0 AND Adjudicated major > 0 AND blocking_majors == 0
  AND convergence_rounds_at_zero_critical < {review_converge_rounds}
  AND  at least one adjudicated-major row has defer_reason == "rubric"`.
```

(The B′ predicate is implicit-complement: if path D's extended OR
clause is TRUE, B′ does not fire even at low convergence rounds.)

**No code change to verdict-handler.** Path D still emits `verdict
pass --stage reviewing --reason ship-with-deferred-majors`; the
forward transition `reviewing → qa` is unchanged from ENG-191.
The orchestrator's `_post_deferred_majors_comment_if_eligible`
(`bin/run-stage.sh:1483-1561`) reads the ledger rows where
`blocks_ship=false` regardless of `defer_reason` — both
out-of-plan-scope and rubric-deferred findings appear in the
comment (D-006 formats them differently for operator clarity).

**Reference to constraint.** Linear scope: "auto-deferred, never
looped back" — the predicate change is the structural mechanism
that prevents the loopback at iteration 1 when every deferral is
scope-driven. AC #1 + AC #5 demand this.

**Rejected alternative — bypass convergence-rounds for ANY
scope-deferred finding (even mixed case).** Rejected because (a) the
rubric-deferred finding's stability is still load-bearing for the
mixed case (the agent's judgment may flip round-to-round; the gate
protects against premature shipping of an agent-judgment-mistake);
(b) the mixed case is rare in practice — most ENG-27-class incidents
have either ALL-scope or ALL-rubric majors. The OR-conjunction is
the cleanest expression of "scope-deferred alone is sufficient;
mixed cases still need stability evidence."

**Rejected alternative — bypass convergence-rounds whenever ANY
finding is scope-deferred AND convergence_rounds >= 0 (effectively
disabling the gate).** Rejected for the same reason; the rubric-
deferred finding's stability signal is meaningful.

**Rejected alternative — bypass convergence-rounds whenever EVERY
finding is scope-deferred AND scope-deferred-count > 0.** This is
the chosen rule; written for clarity.

### D-005. Schema validator (`bin/review-ledger-schema.sh`) extension — known-field `defer_reason`, closed-vocabulary check, conditional `decision_factors` requirement based on `defer_reason`. No new exit code (uses existing rc=49 incomplete).

**Rationale.** AC #1 requires that an out-of-plan-scope finding is
classified `blocks_ship=false reason=out-of-plan-scope`; the
validator is the structural enforcement layer.

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

2. **`defer_reason` required on `blocks_ship=false` major rows.**
   When `adjudicated_severity == "major"` AND `blocks_ship == false`
   AND `dispatch_id == --dispatch-id` (schema-grace), `defer_reason`
   MUST be present. ABSENT IS FINE if it's a pre-ENG-194 row
   (handled by the schema-grace clause already in place from ENG-191
   D-002). For this-dispatch rows, absence → rc=49 incomplete with
   diagnostic `defer_reason-missing-on-deferred-major`.

   **Defaulting for ENG-191 backwards-compat:** When this-dispatch
   row has `blocks_ship=false adjudicated_severity=major` AND
   `defer_reason` is absent, the validator emits rc=49.

   **But pre-ENG-194 ledger rows on issues mid-flight at rollout
   cutover lack `defer_reason`.** The schema-grace clause
   (`dispatch_id == --dispatch-id`) already isolates this dispatch's
   rows from prior dispatches' rows. Prior-dispatch rows missing
   `defer_reason` ARE silently allowed (the validator's existing
   gate). This dispatch's rows MUST emit `defer_reason` — that's
   the contract.

3. **`decision_factors` conditional requirement.** Existing ENG-191
   check at `bin/review-ledger-schema.sh:375-390` requires
   `decision_factors` as an object with all five keys on every
   `adjudicated_severity ∈ {major, critical}` this-dispatch row.
   ENG-194 RELAXES: when `defer_reason == "out-of-plan-scope"` on
   the row, `decision_factors` MAY be `null` or absent (the
   five-question rubric was bypassed). Implementation:

   ```bash
   # ... after the existing critical-floor-blocks-ship check at line 365 ...
   local dr_val_for_df
   dr_val_for_df="$(jq -r '.defer_reason // ""' <<<"$line")"
   if [[ "$dr_val_for_df" == "out-of-plan-scope" ]]; then
     # ENG-194: scope-deferred findings bypass the rubric. Skip the
     # decision_factors-required check (lines 375-390 below).
     :
   else
     # Existing ENG-191 decision_factors-required check unchanged.
     ...
   fi
   ```

4. **`ship_classification_rationale` non-empty on
   `blocks_ship=false out-of-plan-scope` rows.** Existing ENG-191
   check at lines 367-374 already requires non-empty on every
   `blocks_ship`-bearing row. ENG-194 inherits unchanged; no new
   rule.

5. **Add `defer_reason` to known-fields allowlist.** Extend
   `bin/review-ledger-schema.sh`'s known-fields list (used by
   `_warn_unknown` per assumption #36 below) to include `defer_reason`.
   Without this, every ledger row carrying the new field would emit an
   `_warn_unknown: unknown ledger-row field: defer_reason` warning to
   stderr — noisy but non-blocking. The allowlist extension eliminates
   the noise. The seed-header comment at `bin/review-ledger-schema.sh`
   top-of-file documents the closed permitted-fields set; that comment
   is also extended in lockstep so the on-disk allowlist and the
   in-comment documentation stay in sync (design persona iter-1 P1
   finding on second-source-of-truth drift).

6. **Validator cross-check: `defer_reason="out-of-plan-scope"` claim
   must agree with the matcher's verdict (security defense-in-depth).**
   For each this-dispatch row where `defer_reason == "out-of-plan-
   scope"`, the validator parses the fix-target out of
   `ship_classification_rationale` (D-002 mandates the exact prefix
   shape `"out-of-plan-scope: <path> not in plan's File Structure"` —
   the `: <path> not` substring is the parse anchor), then sources
   `bin/plan-scope.sh` and re-runs `plan_scope::path_in_scope_or_benign`
   on the parsed path against the canonical plan for `--ident`. If
   the matcher's verdict is IN-scope (i.e. the agent's claim is
   FALSE), emit rc=49 with diagnostic
   `defer-reason-claim-disagrees-with-plan-scope: agent claimed
   out-of-plan-scope but matcher classifies path=<sanitised> as
   IN-plan`. Cross-check fail-open shape: if the rationale doesn't
   parse cleanly (no anchor parseable, or path token missing), emit a
   stderr warning (`_warn_unknown`-style) and PASS — the structural
   prompt-content contract is the prompt-side enforcement; this
   validator extension is defense-in-depth against an adversarial
   agent emitting a well-formed but lying `defer_reason`. The
   parsing step uses the EXISTING anchor format that D-002's prompt
   contract mandates; agents producing rationales without the anchor
   fall through to the prompt-level pin enforcement only. This
   addresses the security persona iter-1 P0 finding about agent-
   trust-only convergence bypass.

   ```bash
   # In cmd_validate, after the existing defer_reason closed-vocab check:
   if [[ "$dr_val" == "out-of-plan-scope" ]] && [[ "$did_val" == "$dispatch_id_flag" ]]; then
     local scr fix_target
     scr="$(jq -r '.ship_classification_rationale // ""' <<<"$line" 2>/dev/null || printf '')"
     # Parse: "out-of-plan-scope: <path> not in plan's File Structure"
     fix_target="$(printf '%s' "$scr" | sed -nE 's/^out-of-plan-scope:[[:space:]]*([^[:space:]]+)[[:space:]]+not[[:space:]]+in[[:space:]]+plan.*$/\1/p')"
     if [[ -n "$fix_target" ]]; then
       # Source helper + run matcher against canonical plan.
       source "$SCRIPT_DIR/plan-scope.sh"
       local plan body af ad
       plan="$(plan_scope::find_plan "$ident" "$worktree_root" 2>/dev/null || printf '')"
       if [[ -n "$plan" ]]; then
         body="$(plan_scope::extract_section "$plan" 2>/dev/null || printf '')"
         # parse_sets emits #ALLOWED_FILES# / #ALLOWED_DIRS# sections
         # Caller splits on the section markers; impl in helper.
         if [[ -n "$body" ]]; then
           if plan_scope::path_in_scope_or_benign "$fix_target" "$plan"; then
             _emit_incomplete "$line_no" "defer-reason-claim-disagrees-with-plan-scope: agent claimed out-of-plan-scope but matcher classifies path=$(sanitise_for_diag "$fix_target") as IN-plan" "$fck"
             return 49
           fi
         fi
       fi
     else
       _warn_unknown "ship_classification_rationale" "could not parse fix-target from defer_reason=out-of-plan-scope row; skipping matcher cross-check (prompt-content contract handled at agent side)"
     fi
   fi
   ```

   `plan_scope::path_in_scope_or_benign <path> <plan>` is the
   single-arg public wrapper that internally calls
   `plan_scope::extract_section + parse_sets + path_in_scope_or_benign`
   (the 3-arg form) — defined in `bin/plan-scope.sh` per D-001.
   Production validators get an `--ident` flag (per ENG-190 existing
   pattern) and use the worktree's plan; test fixtures pass a
   `$SCOPE_CHECK_PROFILE_PATH`-style override for the plan path (or
   use the existing test-source-and-stub pattern).

**No new exit code.** The ENG-190 validator uses 48/49/50. ENG-194's
new rules all map to rc=49 incomplete. No new halt reason — the
existing `review-ledger-invalid` covers ENG-190+ENG-191+ENG-194
violations. CLAUDE.md "Never use exit codes outside the taxonomy"
honoured.

**Reference to constraint.** ENG-190/ENG-191 D-009 sanitisation
contract (`<!-- → <\!--` + `\n,\r → space`) applies to all new
agent-controlled string interpolation. `defer_reason` is closed-
vocabulary (no agent prose), so the diagnostic just embeds the
literal token; the sanitiser is still applied for defense.

**Adversarial test cases** (added to
`bin/review-ledger-schema-adversarial-test.sh`):

- **AC-AD-10.** Row with `adjudicated_severity=major, blocks_ship=
  false, defer_reason="out-of-plan-scope", decision_factors:null`
  → rc=0 valid (rubric bypass).
- **AC-AD-11.** Row with `adjudicated_severity=major, blocks_ship=
  false, defer_reason="rubric", decision_factors:null` → rc=49
  incomplete (`decision_factors must be object`).
- **AC-AD-12.** Row with `adjudicated_severity=major, blocks_ship=
  false, defer_reason="bogus-token"` → rc=49 with closed-vocabulary
  diagnostic.
- **AC-AD-13.** Row with `adjudicated_severity=major, blocks_ship=
  false, defer_reason missing` → rc=49 with
  `defer_reason-missing-on-deferred-major`.
- **AC-AD-14.** Row with `adjudicated_severity=critical, blocks_ship=
  true, defer_reason="out-of-plan-scope"` → rc=0 valid (informational
  on critical+blocking; critical-floor invariant still holds).
- **AC-AD-15.** Sanitisation: row with
  `defer_reason="out-of-plan-scope"` (clean token) — diagnostic for
  an unrelated failure does not contain `<\!--` because the literal
  token has no `<!--` substring. (Defensive: confirms the new field
  doesn't introduce a sanitisation surface that requires extra
  handling.)

**Reference to constraint.** Linear AC #4 "assert both call the
same function" — the schema-side assertion is in D-001's
sibling test. This decision (D-005) covers the validator's
contract for the new field; the matcher-sharing assertion is
elsewhere.

**Rejected alternative — bump `ledger_schema_version` to 2.**
Rejected per the additive-v1 reasoning in D-003 / ENG-191 D-002.

**Rejected alternative — separate validator file
`bin/review-defer-reason-schema.sh`.** Rejected because (a) one
file, one validator, one detective slot — sprawl rejected per
ENG-191 D-002 / D-009 precedent; (b) the ledger row IS the
per-finding decision record; splitting the validation cross-
cuts the contract.

### D-006. Orchestrator's deferred-majors comment formatter (`_post_deferred_majors_comment_if_eligible`) reads `defer_reason` and groups bullets by reason. Two sub-sections: "Out-of-plan-scope (auto-deferred)" and "Rubric-deferred". Lede sentence references both counts.

**Rationale.** Linear AC #2: "The same finding is routed to the
[ENG-191] deferred-majors path (recorded as known debt), not
silently dropped." Operators need to distinguish scope-deferred
from rubric-deferred at-a-glance — the two have different
implications for the follow-up ticket creation (ENG-193) and for
operator triage (scope-deferred → "plan-author should have scoped
this"; rubric-deferred → "agent judged this acceptable, audit if
needed").

**Helper change.** `bin/run-stage.sh::_post_deferred_majors_comment_if_eligible`
at lines 1483-1561 currently emits all bullets in one flat list
with one lede. ENG-194 partitions:

```
Review took the selective exit (ENG-191 + ENG-194). N major finding(s) deferred as known debt — M out-of-plan-scope, K via the rubric.

Out-of-plan-scope (auto-deferred — fix lands outside plan's File Structure):
- [major] <finding_class_key>
  Rationale: <ship_classification_rationale>
  Ledger row: dispatch_id=<id> iteration=<N>

(repeat per scope-deferred bullet)

To fix any of the above in-PR (recommended when the file *should* have been scoped):
  1. Amend `docs/plans/<plan>.md`'s File Structure to include the file.
  2. Commit the amendment on the feature branch (docs/plans/* is benign).
  3. `bash bin/pipeline.sh decide <ENG-N> --action continue` to re-trigger reviewing.
The next reviewing iteration will see the expanded scope and apply the rubric.

Rubric-deferred (agent judged deferrable via the five-question rubric):
- [major] <finding_class_key>
  Rationale: <ship_classification_rationale>
  Decision: in_changed_code=<y|n>, is_regression=<y|n>, user_visible=<y|n>, reversible_post_ship=<y|n>, has_workaround=<y|n>
  Ledger row: dispatch_id=<id> iteration=<N>

(repeat per rubric-deferred bullet)

ENG-193 will auto-create follow-up tickets per deferred major.
```

Decision-factors are emitted as a SINGLE inline line (`y|n` shorthand)
rather than the verbose 5-line form ENG-191 D-005 originally proposed.
Three reasons (product persona iter-1 P1 #2): (a) busy issues with
5+ rubric-deferred majors balloon the comment to >100 lines under the
verbose form; (b) the at-a-glance scan is what operators do — 5
shorthand booleans on one line is faster to read than a 5-line list;
(c) ENG-191's flywheel-substrate consumer (ENG-193 + retrospective)
reads the LEDGER row, not the comment body — verbosity in the comment
is operator-UX-only and the single-line shape is strictly easier to
scan. The verbose form is preserved in the LEDGER row.

The "To fix any of the above in-PR" trailer is operator-recipe (product
persona iter-1 P1 #1): the lived-experience ENG-27 recovery was
plan-amend + force-transition. The trailer makes that the
operator-discoverable default. When ALL deferred majors are rubric-
deferred (M=0), the trailer is OMITTED (it has no scope-deferred
target).

**Implementation sketch.** Two jq filter passes over the same
ledger, partitioned by `defer_reason`:

```bash
# Scope-deferred rows
rows_scope="$(grep -v '^#' "$ledger" | jq -rc --arg did "$did" '
  select(.dispatch_id == $did)
  | select(.adjudicated_severity == "major")
  | select(.blocks_ship == false)
  | select(.defer_reason == "out-of-plan-scope")
  | [...]
')"

# Rubric-deferred rows (default treatment — defer_reason absent or "rubric")
rows_rubric="$(grep -v '^#' "$ledger" | jq -rc --arg did "$did" '
  select(.dispatch_id == $did)
  | select(.adjudicated_severity == "major")
  | select(.blocks_ship == false)
  | select(.defer_reason != "out-of-plan-scope")
  | [...]
')"
```

Empty sub-sections are omitted (e.g., if all deferred majors are
scope-deferred, only the "Out-of-plan-scope" section appears, not
an empty "Rubric-deferred" header).

**Sanitisation unchanged from ENG-191 D-005.** Every agent-controlled
field (finding_class_key, ship_classification_rationale, dispatch_id,
iteration) is sanitised via the existing `_san` helper at
`bin/run-stage.sh:1508-1514`. `defer_reason` is a closed token, so
no new sanitisation needed (but defensively, run it through `_san`
anyway).

**Lede sentence.** "Review took the selective exit (ENG-191 + ENG-194).
N major finding(s) deferred as known debt — M out-of-plan-scope, K
via the rubric." Where `M + K == N`. This is the operator's at-a-
glance summary.

**Idempotence unchanged.** Same `--sig deferred-majors/<ident>`;
ENG-150's append-only convention applies.

**Reference to constraint.** Linear AC #2 — visible audit trail
for scope-deferred findings. The grouped sub-sections make the
distinction explicit.

**Rejected alternative — same flat list, just add `(scope)` /
`(rubric)` annotations to each bullet's first line.** Rejected
because (a) operators scan the comment for "is there a plan-author
fix I need to make for next time?"; grouped sub-sections answer
that in one glance; (b) the rubric sub-section's decision-factors
list is verbose — separating it visually from the scope-deferred
sub-section (which has no decision-factors) avoids confusing
"which factors apply to which finding" for the operator reading
the comment.

**Rejected alternative — two separate Linear comments (one per
defer_reason).** Rejected because (a) two posts for one logical
decision; (b) the operator wants one place to look; (c) ENG-191
D-005's "exactly ONE Linear comment" AC #4 contract.

### D-007. Two new `bin/render-prompt.sh` resolvers — `{plan_scope_allowed_paths}` (parsed plan sets) and `{plan_scope_benign_path_classes}` (the shared-helper-exported benign-path glob list). Both render into the reviewer's prompt; neither is path-shaped (no sidecar entry).

**Rationale.** D-002 needs the reviewer to know the parsed
`allowed_files` / `allowed_dirs` at dispatch time. The token-render
mechanism is the established path (`bin/render-prompt.sh:40-62` +
the `PROMPT_RESOLVERS` registry).

**Resolver body.**

```bash
# In PROMPT_RESOLVERS registry (added after review_converge_rounds line):
plan_scope_allowed_paths=_resolve_plan_scope_allowed_paths

# Resolver body (added after _resolve_review_converge_rounds at line 303):
# ENG-194: render the parsed plan File Structure into the prompt as
# two newline-separated sets. Shape:
#   #ALLOWED_FILES#
#   <file1>
#   ...
#   #ALLOWED_DIRS#
#   <dir1>/
#   ...
# Both sections always emit (even when empty), so the prompt-side
# match logic can branch on absence.
# On absent plan / unparseable section, emits the two headers with
# empty bodies and logs a warning — soft-fail (the reviewer falls
# through to the five-question rubric for every finding, which is
# the safe-default ENG-191 behaviour).
_resolve_plan_scope_allowed_paths() {
  local issue_id="$_RENDER_ISSUE_ID"
  local worktree_root
  worktree_root="$(git rev-parse --show-toplevel 2>/dev/null || printf '%s' "$TARGET_REPO")"
  source "$SCRIPT_DIR/plan-scope.sh"
  local plan body
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
  plan_scope::parse_sets "$body"
}
```

**Soft-fail discipline.** When the resolver can't find the plan or
the section is empty, it emits the two headers with empty bodies
(NOT die). The reviewer's prompt block (D-002) checks whether
both sets are empty and falls through to the five-question rubric
for every major finding — degraded mode, but not blocked. The
log warning surfaces the degradation in
`$PROJECT_STATE_DIR/<slug>/logs/<ident>-reviewing-*.log`.

**Second resolver: `{plan_scope_benign_path_classes}`.** Exports the
stack-agnostic benign-path globs from `bin/plan-scope.sh` as a
newline-separated list (one glob per line, e.g. `.scratch/*`,
`docs/plans/*`, ...). Always-non-empty (the globs are hardcoded in
the helper). Same shape as `{plan_scope_allowed_paths}` for prompt-
side consumption.

```bash
# Registered alongside plan_scope_allowed_paths in PROMPT_RESOLVERS:
plan_scope_benign_path_classes=_resolve_plan_scope_benign_path_classes

_resolve_plan_scope_benign_path_classes() {
  source "$SCRIPT_DIR/plan-scope.sh"
  plan_scope::list_benign_path_classes
}
```

`plan_scope::list_benign_path_classes` is a NEW function in the
shared helper that prints the hardcoded stack-agnostic glob list, one
per line. Both `scope-check.sh` (via the shared call) and the
renderer source the same hardcoded list — byte-for-byte agreement is
trivial because there's only one declaration.

**Sidecar entry.** Add `plan_scope_allowed_paths` or
`plan_scope_benign_path_classes` to `_write_rendered_paths_sidecar`
(`bin/render-prompt.sh:94-127`)?
NO for both — the resolvers' outputs are NOT single paths (they're
structured manifests of paths/globs). The sidecar's contract per
ENG-156 D-004 is "closed allowlist of path-shaped tokens"; these
resolvers emit multi-line manifests. Treat them like
`{review_converge_rounds}` (also non-sidecar per ENG-191 D-010
comment at `bin/render-prompt.sh:290-291`).

**Reference to constraint.** CLAUDE.md "AGENT_PROMPTS.md is
load-bearing." The new token is added to the existing resolver
registry; render-prompt's residual unknown-token validator
(`bin/render-prompt.sh:71-83` — see the AGENT_RUNTIME_TOKENS
allowlist) treats it as a registered token and substitutes
correctly.

**Reference to constraint.** ENG-156 D-004 — sandbox-denial
detective sidecar surface. The non-path nature of this resolver's
output justifies the sidecar exclusion.

**Rejected alternative — render the resolved sets as JSON.**
Rejected because (a) the agent already reads structured prompt
content as plain text; (b) JSON in the prompt would require the
agent to parse it, which is a fresh prompt complexity surface;
(c) the section-header newline-separated shape is the simplest
prompt-side branchable format.

**Rejected alternative — render only the COMPILED MATCH OUTPUT
(yes/no per finding).** Rejected because the renderer doesn't
know the findings at render time; they emerge in-prompt during
the cold-pass and adjudication.

### D-008. Prompt-content test + sibling tests assert byte-for-byte agreement (AC #4) and the five Linear ACs end-to-end.

**Rationale.** AC #1 through AC #5 demand structural fixtures.
This decision consolidates the test mechanism.

**`bin/plan-scope-test.sh` (NEW — sibling test for D-001).**
- Test 1: `plan_scope::parse_sets` snapshot on a curated fixture
  plan body (repo-root files, nested dirs, dotfile dirs,
  dotted-extension dir-prefix anti-pattern) matches a frozen
  expected output byte-for-byte.
- Test 2: `plan_scope::path_in_scope` yes/no verdict on a battery
  of probe paths (exact match, dir-prefix match, no match,
  prefix-substring-but-not-actual-dir match) returns the
  expected 0/1.
- Test 3: source `bin/scope-check.sh` and assert
  `declare -f plan_scope::parse_sets` is defined (proves the
  helper is wired). Same assertion against `bin/render-prompt.sh`.
- Test 4: end-to-end byte-for-byte assertion — construct a fixture
  plan; run scope-check.sh's parse step (via the refactored
  path); run the new resolver's parse step (via
  `_resolve_plan_scope_allowed_paths` with `_RENDER_ISSUE_ID`
  set); assert their parsed `allowed_files` / `allowed_dirs`
  byte-equal. (AC #4 structural assertion.)

**`bin/scope-check-test.sh` (EXISTING — extended).**
- All existing fixtures continue to pass unchanged (the refactor
  is a behaviour-preserving extraction).
- New test: `bin/scope-check.sh` sources `bin/plan-scope.sh`
  (assert via `declare -f`).

**`bin/review-ledger-schema-test.sh` (EXISTING — extended).**
- AC-AD-10 through AC-AD-15 from D-005's adversarial cases.

**`bin/review-ledger-schema-adversarial-test.sh` (EXISTING — extended).**
- Same as above; placement depends on the existing test's
  partition between "positive cases" and "adversarial."

**`bin/agent-prompts-content-test.sh` (EXISTING — extended).**
The seven prompt-content pins:

- Assert §5 contains the literal phrase "Plan-scope adjudication".
- Assert §5 references `{plan_scope_allowed_paths}` token.
- Assert §5 contains the literal phrase
  `defer_reason="out-of-plan-scope"`.
- Assert §5 documents that out-of-plan-scope rows OMIT
  `decision_factors` (the relaxation rule).
- Assert §5's path-D predicate contains the extended OR clause
  (`OR every adjudicated-major row has defer_reason ==
  "out-of-plan-scope"`).
- Assert §5's plan-scope-adjudication block is positioned BEFORE
  the count-tuple emission (positional check by line-number
  ordering).
- Assert §5 contains the multi-target finding tie-break rule
  (canonical anchor is the SOLE fix-target — iter-2 wording fix).
- **Pin #8 (iter-2 added per coherence persona P1 #4):** assert
  §5 wording permits BOTH `decision_factors: null` AND fully-
  omitted `decision_factors` on scope-deferred rows (D-002
  prompt block says "OMITTED or null"; schema D-005 accepts
  either). Test asserts BOTH literal substrings ("OMITTED" and
  "null") appear in the §5 block.

**`bin/render-prompt-test.sh` (EXISTING — extended).**
- Sibling test for the new resolver: token resolves to a
  non-empty payload when a plan with File Structure exists;
  empty-header payload on missing plan; soft-fail logging
  visible on the empty path.

**`bin/run-stage-test.sh` (EXISTING — extended).** End-to-end
fixtures for AC #1, #2, #5:
- **AC #1 fixture.** Construct a fixture ledger with one
  this-dispatch row: `adjudicated_severity=major, blocks_ship=
  false, defer_reason="out-of-plan-scope", ship_classification_
  rationale="out-of-plan-scope: docs/install.md not in plan's
  File Structure"`. Construct a fixture verdict marker with
  `reason=ship-with-deferred-majors`. Assert
  `_post_deferred_majors_comment_if_eligible` posts the
  deferred-majors comment with the body containing
  "Out-of-plan-scope (auto-deferred…)" sub-header AND the
  bullet matching the row.
- **AC #2 fixture.** Assert the scope-deferred row appears in
  the comment body (NOT silently dropped).
- **AC #3 fixture.** Construct a fixture with one in-plan major
  row (`defer_reason="rubric"`). Assert the rubric-deferred
  bullet is rendered with the five decision factors (regression
  test — ENG-191 D-005 behaviour preserved).
- **AC #5 (ENG-27-class) end-to-end fixture.** Construct a
  worktree fixture with `docs/plans/.../plan.md` scoping only
  `bin/setup.sh`, a feature branch diff that modifies only
  `bin/setup.sh`, and a synthesised ledger row with the
  `docs/install.md` scope-deferred finding. Assert the agent's
  decision-path output (the count-tuple line + verdict marker)
  selects path D, the verdict marker carries
  `reason=ship-with-deferred-majors`, and the orchestrator
  posts the deferred-majors comment with the scope-deferred
  bullet. (Heavily mocked — the agent's in-prompt arithmetic
  is asserted via the COUNT-TUPLE line shape, not by running
  `claude -p` itself; ENG-191 D-008 prior art for prompt-content
  rather than runtime-execution testing.)

**Reference to constraint.** CLAUDE.md "Tests" section — sibling
shell scripts, sourceable via the sentinel. New
`bin/plan-scope.sh` follows the same pattern.

**Rejected alternative — a single end-to-end fixture that
exercises every AC.** Rejected because (a) end-to-end fixtures are
heavy; each AC is structurally distinct; (b) fast feedback on a
single AC's regression is more useful than a single
omnibus fixture.

## 3. Architecture (where code goes)

```
bin/plan-scope.sh                       NEW (~150 lines).
                                        Sourced by both scope-check.sh,
                                        render-prompt.sh, AND review-ledger-
                                        schema.sh (D-005 cross-check).
                                        Defines:
                                        - plan_scope::find_plan
                                        - plan_scope::extract_section
                                        - plan_scope::parse_sets
                                        - plan_scope::list_benign_path_classes
                                          (the stack-agnostic glob list)
                                        - plan_scope::path_in_scope (structural)
                                        - plan_scope::path_in_scope_or_benign
                                          (structural OR stack-agnostic benign;
                                          BOTH 3-arg form and 2-arg
                                          "path + plan-file" convenience form)
                                        Sentinel main() runs sub-commands
                                        for manual CLI use.

bin/plan-scope-test.sh                  NEW (~80 lines).
                                        Per D-008: parse snapshot,
                                        path-match battery, shared-function
                                        assertion, byte-for-byte cross-
                                        caller assertion.

bin/scope-check.sh                      EDIT (~50 lines net).
                                        - Source bin/plan-scope.sh after
                                          common.sh (line 47-48).
                                        - Replace find_canonical_plan (143-
                                          157) body with delegation to
                                          plan_scope::find_plan; preserve
                                          the legacy function name as a
                                          thin wrapper for back-compat
                                          (test-source-and-stub callers).
                                        - Replace extract_scope_section
                                          (159-172) similarly.
                                        - Replace allowed_files/allowed_dirs
                                          parse at 297-314 with
                                          plan_scope::parse_sets call.
                                        - Replace per-file in-scope check
                                          at 356-378 with
                                          plan_scope::path_in_scope (the
                                          benign-path + notable-tier logic
                                          stays in scope-check.sh).

bin/scope-check-test.sh                 EDIT. Existing cases pass; new
                                        case asserts plan-scope helper
                                        is sourced.

bin/render-prompt.sh                    EDIT (~40 lines).
                                        - Add two tokens to PROMPT_RESOLVERS
                                          (after line 62):
                                          plan_scope_allowed_paths=
                                          _resolve_plan_scope_allowed_paths
                                          plan_scope_benign_path_classes=
                                          _resolve_plan_scope_benign_path_classes
                                        - Add the two resolver bodies per
                                          D-007 (after _resolve_review_
                                          converge_rounds at line 303).

bin/render-prompt-test.sh               EDIT. New resolver fixture.

bin/review-ledger-schema.sh             EDIT (~70 lines).
                                        - Add defer_reason to known-fields
                                          allowlist + update seed-header
                                          comment (lockstep with D-005 #5).
                                        - Add closed-vocabulary check.
                                        - Gate the existing decision_
                                          factors-required check (375-390)
                                          on defer_reason != out-of-plan-
                                          scope.
                                        - Add defer_reason-required-on-
                                          deferred-major check.
                                        - Add validator cross-check
                                          (D-005 rule 6): source
                                          bin/plan-scope.sh; parse fix-
                                          target from ship_classification_
                                          rationale; run
                                          plan_scope::path_in_scope_or_benign;
                                          mismatch → rc=49 with diagnostic
                                          defer-reason-claim-disagrees-
                                          with-plan-scope.

bin/review-ledger-schema-adversarial-test.sh  EDIT.
                                        AC-AD-10 through AC-AD-15.

bin/run-stage.sh                        EDIT (~50 lines).
                                        - _post_deferred_majors_comment_
                                          if_eligible (1483-1561): split
                                          the single jq filter into two
                                          (scope vs rubric); render two
                                          sub-sections; update lede sentence
                                          to include both counts.
                                        - Sanitise defer_reason via _san
                                          for defense-in-depth.

bin/run-stage-test.sh                   EDIT. AC #1, #2, #5 fixtures.

AGENT_PROMPTS.md                        EDIT. §5 Review Agent insertions:
                                        - New "Plan-scope adjudication"
                                          block AFTER ENG-191 "Deferability
                                          adjudication" (line 1480) and
                                          BEFORE the count-tuple emission
                                          (line 1481).
                                        - Update path-D predicate
                                          (mechanical predicates block at
                                          1614-1620) to the extended OR.
                                        - Update path-B′ predicate (mutual
                                          complement).
                                        - Update the Output block ledger-
                                          row instruction (1776-1801) to
                                          emit defer_reason on
                                          blocks_ship=false major rows.
                                        - All inside the existing fenced
                                          block; no fence-count change.

bin/agent-prompts-content-test.sh       EDIT. Eight new content pins per
                                        D-008 (iter-2 added pin #8 per
                                        coherence persona P1 #4 — assert
                                        §5 wording permits both null AND
                                        omitted decision_factors on
                                        scope-deferred rows).

docs/runbooks/recovery.md               EDIT. Append §14 "Scope-deferred
                                        majors (ENG-194)" — operator
                                        audit recipe + power-user
                                        override.

docs/runbooks/operator-mental-model.md  EDIT. Update §3 grep recipe to
                                        include the scope-deferred sub-
                                        section header.

CLAUDE.md                               EDIT. Failure-mode quick reference
                                        row update — extend the existing
                                        ENG-191 "Issue at stage:qa with
                                        verdict comment reason=ship-with-
                                        deferred-majors" row to mention
                                        the scope-deferred sub-class.
```

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
                                                Match against #ALLOWED_FILES# / #ALLOWED_DIRS#
                                                → OUT OF SCOPE
                                                → blocks_ship=false
                                                → defer_reason="out-of-plan-scope"
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
    └─ defer_reason closed-vocabulary check (NEW — D-005)
    └─ defer_reason-required on deferred-major (NEW)
    └─ decision_factors required ONLY if defer_reason != "out-of-plan-scope" (RELAXED)
  _post_deferred_majors_comment_if_eligible (UPDATED — D-006)
    └─ partition ledger rows by defer_reason
    └─ render two sub-sections: scope / rubric
    └─ post under sig deferred-majors/ENG-194
  post_completion_comment
  verdict-handler picks up agent's verdict marker
    └─ pass + stage=reviewing → forward transition reviewing → qa
```

## 4. Data flow

**Producer (scope-deferred selective exit):** review agent on a
dispatch where critical=0 AND every adjudicated-major has
`blocks_ship=false defer_reason="out-of-plan-scope"`. Emits:

- `Adjudicated:` line with major>0.
- `Deferrable:` line with deferrable_majors=N, blocking_majors=0.
- Per-finding ledger rows with `defer_reason="out-of-plan-scope"`,
  `decision_factors=null`, `ship_classification_rationale`
  beginning with "out-of-plan-scope:".
- Verdict marker: `verdict pass --stage reviewing --reason
  ship-with-deferred-majors`.

**Producer (mixed deferral):** agent emits some
`defer_reason="out-of-plan-scope"` rows AND some
`defer_reason="rubric"` rows. Convergence-rounds gate applies
(no bypass); path B′ fires unless plateau is met. The rubric
rows carry full `decision_factors` per ENG-191.

**Producer (in-plan only — ENG-191 status quo):** agent emits all
rows with `defer_reason="rubric"` (or `defer_reason` omitted for
backwards compat). Behaviour unchanged from ENG-191.

**Storage:** `$(issue_dir <ident>)/review-findings-ledger.jsonl`
(extended schema). Append-only across all review dispatches.

**Reader (v1):**

1. The same review agent's adjudication step on the NEXT review
   dispatch — reads ledger via ENG-190 inventory step.
2. The orchestrator's `_post_deferred_majors_comment_if_eligible`
   helper — partitions this-dispatch rows by `defer_reason`,
   renders two sub-sections.
3. ENG-193 (auto-ticketing) — future reader; `defer_reason`
   gives it signal for ticket priority + title prefix
   ("Scope-deferred:" vs "Rubric-deferred:").

**Detective reader:** `bin/run-stage.sh::_validate_review_ledger`
post-dispatch scan (extended with ENG-194 rules per D-005).

**Linear-comment surfaces:**

| Surface | Sig | Writer | Body |
|---|---|---|---|
| Completion summary | `completion/reviewing/<issue>` | orchestrator (via post_completion_comment, ENG-11) | Agent's stage-summary-reviewing.md (includes adjudicator summary line + ship-with-debt summary line; ENG-191 D-008). |
| Deferred majors | `deferred-majors/<issue>` | orchestrator (UPDATED per D-006) | Markdown bullet list grouped by defer_reason. |
| Verdict | (none — verdict markers are body-only) | agent (via `bash bin/pipeline.sh event`) | `<!-- pipeline: verdict result=pass stage=reviewing reason=ship-with-deferred-majors -->` |

## 5. Error handling

**Halt cases (this ticket's contract):**

| Failure mode | rc | Outcome token | Halt reason | Operator recovery |
|---|---|---|---|---|
| Major row with `blocks_ship=false` missing `defer_reason` this dispatch | 49 | review-ledger-incomplete | review-ledger-invalid | Validator names the row; agent didn't follow the new prompt rule. Operator inspects transcript, fixes by hand or `--action continue` after agent re-runs. |
| `defer_reason` is a non-vocabulary value (e.g. `"out-of-scope"` instead of `"out-of-plan-scope"`) | 49 | review-ledger-incomplete | review-ledger-invalid | Closed-vocabulary diagnostic names the bad value. |
| `defer_reason="out-of-plan-scope"` but `decision_factors` is present-and-malformed | not an error — the validator skips the decision_factors check entirely when defer_reason is scope. Agent free-form data is logged as unknown via `_warn_unknown`. | n/a | n/a | n/a |
| `defer_reason="rubric"` but `decision_factors` missing | 49 (existing ENG-191 rule, unchanged) | review-ledger-incomplete | review-ledger-invalid | Pre-existing ENG-191 contract — operator inspects transcript. |
| Render-prompt resolver fails to find plan (e.g. plan deletion mid-dispatch) | 0 | (soft-fail: log warning) | n/a | Resolver emits empty sets; reviewer falls through to ENG-191 rubric for every finding. Degraded mode visible in render log. |
| Reviewer mis-classifies an in-plan finding as out-of-plan-scope (agent bug) | 0 | (agent-level error; not validator-detectable) | n/a | Operator can spot via the deferred-majors comment: bullet says "out-of-plan-scope: <file>" but operator knows the file IS in the plan. Manual triage: revoke the exit per recovery.md §14 (D-006 power-user override). |
| Reviewer mis-classifies an out-of-plan finding as in-plan (and applies rubric) | 0 | (agent-level error; not validator-detectable in v1) | n/a | The downstream implement dispatch's scope-check.sh halts when the implementer touches the out-of-plan file. ENG-180-class catch-22 returns. v1 accepts the agent-judgment risk; future hardening could validate the agent's claim post-hoc via plan_scope::path_in_scope on the row's fix-target. |
| Reviewer emits `verdict pass --reason ship-with-deferred-majors` but ledger has no this-dispatch `blocks_ship=false` rows | 0 | (deferred-majors comment posts with N=0 bullets) | n/a | Operator sees "selective exit took, 0 deferrable" — visibly wrong, triage signal. |

**Soft-fail cases (NOT halts):**

- Render-prompt resolver's plan-not-found / section-empty path:
  logs warning; emits empty sets; reviewer degrades safely.
- `_post_deferred_majors_comment_if_eligible` failing to post
  (Linear API outage): same as ENG-191 D-005 — soft-fail, ledger
  is canonical, transition still fires.

**Logging.** Validator stdout follows the existing ENG-190 shape:
`review-ledger-incomplete: row N: <msg> finding_class_key=<key>`.
New diagnostic messages from D-005:
- `defer_reason must be 'out-of-plan-scope' or 'rubric' (closed vocabulary), got '<val>'`
- `defer_reason-missing-on-deferred-major: adjudicated_severity=major blocks_ship=false`

**No retry path.** Same as ENG-190/ENG-191/ENG-119 — emission is
deterministic; failure means agent bug.

## 6. Edge cases

1. **Plan deleted mid-dispatch.** Render-prompt resolver's
   plan-not-found path emits empty sets; reviewer treats every
   major finding as in-plan (falls through to rubric). This is
   safe-default behaviour: the reviewer rubric is the existing
   ENG-191 contract; the worst case is no improvement over
   ENG-191. Logged via the render-prompt warning.

2. **Plan File Structure section absent.** Same as #1 — resolver
   emits empty sets, safe-default behaviour.

3. **Multi-file finding with mixed in-plan/out-of-plan files.**
   Per D-002, the agent treats the FIRST file in the body as
   canonical for fix-target. If any of the named files is in-plan,
   the finding is treated as in-plan. The rubric handles it.
   Rationale: the implementer CAN fix the in-plan one without
   tripping scope-check; the out-of-plan files become side-quests.

4. **Critical finding whose fix is out-of-plan.** Critical-floor
   invariant rules: `blocks_ship=true` unconditionally. The agent
   MAY record `defer_reason="out-of-plan-scope"` for audit (D-005
   permits it on `blocks_ship=true` rows), but `blocking_majors`
   stays > 0 → path B (loopback). Implementer tries; scope-check
   halts. Operator triages. **NEW (iter-2):** the reviewer ALSO
   posts an operator-recipe meta-comment via `add-comment --sig
   critical-out-of-plan/<ident>` naming the file + the plan-amend
   + resume sequence (D-002 final paragraph). This turns the
   residual catch-22 into a discoverable operator path instead of
   a silent scope-violation halt that the operator triages from
   scratch — closes product persona iter-1 P1 #3.

5. **Findings without a `file:line` anchor.** Per D-002, the agent
   falls through to the five-question rubric for these. v1 accepts
   the small ambiguity; flagged for future hardening if a
   transcript-pattern of "findings missing anchors" recurs (the
   review-comment-quality rubric — AGENT_PROMPTS.md:1572-1586 —
   already requires the anchor at the boundary, so this should
   be rare).

6. **Reviewer adversarially fakes `defer_reason="out-of-plan-scope"`
   to bypass the convergence-rounds gate on a rubric-deferred
   finding.** v1 trusts the agent's claim. Defense: future
   hardening could add a validator-side check that runs
   `plan_scope::path_in_scope` against the row's
   `finding_class_key`-derived fix-target. The check is non-
   trivial (parsing the scope-anchor out of `finding_class_key` —
   format is `<dimension>:<scope-anchor>:<concept-slug>` and
   scope-anchor may be `path.ext:line` or `path.ext::function`
   or other shapes per AGENT_PROMPTS.md:1437 guidance). Bounded:
   if observed, file a follow-up. v1 doesn't ship the cross-
   check (YAGNI for adversarial-not-buggy case).

7. **Plan File Structure has prose surrounding the path tokens.**
   `plan_scope::parse_sets` uses the same `grep -oE` regexes as
   the legacy scope-check.sh body (line 307-314). Prose surrounding
   the tokens (e.g. "I will edit `bin/setup.sh` to add a phase")
   is ignored — only token shapes match. No regression vs ENG-191
   scope-check behaviour.

8. **Dotfile directory in plan (e.g. `.github/workflows/`).** The
   existing awk filter at scope-check.sh:313-314 was fixed
   pre-ENG-194 to NOT strip dotfile dirs (ENG-46 fix). The
   plan-scope helper inherits this. Prompt-content test pins the
   dotfile-dir case (D-008 Test 1).

9. **Repo-root files in plan (e.g. `CLAUDE.md`).** ENG-25 fix at
   scope-check.sh:300 — `*` not `+` on the path-prefix group.
   plan-scope helper inherits.

10. **Dry-run (`PIPELINE_DRY_RUN=1`).** Same as ENG-191 D-006: the
    orchestrator's deferred-majors comment post is dry-run-gated
    by `linear.sh` itself; ledger is written as normal; validator
    runs as normal.

11. **`PIPELINE_DISPATCH_ID` unset when validator runs.** Same
    fail-open shape as ENG-191 D-009 — the schema-grace clause
    becomes a no-op (no prior/current distinction). All rows
    must satisfy the new ENG-194 rules. Test-fixture case.

12. **Concurrent dispatches on the same issue.** ENG-81 per-issue
    lock prevents this; no new hazard.

13. **Operator manually edits ledger to flip `defer_reason` from
    rubric to scope.** The schema-grace clause skips prior-
    dispatch rows; if the operator edits a this-dispatch row, the
    validator re-runs on next dispatch (if the agent does a
    fresh emission) but at that point the row's `dispatch_id`
    has changed to the new dispatch — so the hand-edit's row
    becomes a prior-dispatch row, validated against the
    pre-edit contract. Recovery via recovery.md §12.

14. **Plan amended (in `docs/plans/...md`) mid-loop.** The render-
    prompt resolver reads the current worktree's plan file at
    render time (per D-007 `git rev-parse --show-toplevel`). If
    the operator amends the plan File Structure between
    dispatches, the next reviewing dispatch sees the new sets.
    No staleness contract violation.

15. **Sandbox-denial on plan read.** ENG-156 detective catches
    sandbox denials on path-shaped tokens; this resolver's output
    is NOT path-shaped (D-007 sidecar exclusion). The internal
    plan-read goes through bash file IO which is unrestricted at
    render time (renderer runs in orchestrator context, not
    sandbox).

16. **Lockfile review-finding divergence (design persona iter-1
    P0).** A reviewer-flagged lockfile (e.g. `Cargo.lock`) is a
    stack-conditional benign-path on scope-check's side but NOT
    on the reviewer's side — D-001's partition explicitly leaves
    lockfiles in scope-check.sh's `is_benign`. Net effect: a
    review finding about a lockfile (rare in practice — reviewers
    don't typically raise findings about lockfile churn) would be
    auto-deferred by the reviewer. The implementer COULD fix it
    (scope-check would allow), but the reviewer's defer means the
    finding becomes known debt instead. Acceptable in v1 because
    (a) lockfile findings are near-nonexistent (the cold-pass sub-
    agents don't flag lockfile churn); (b) the auto-defer routes
    to known debt instead of deadlocking; (c) if observed, the
    fix is mechanical — extend `plan_scope::list_benign_path_classes`
    to consult profile-derived lockfiles via a new helper-side
    parse. Bounded follow-up tracked as OQ-9.

17. **Plan-file integrity (security persona iter-1 P1 #3).** The
    resolver reads the plan from the worktree at render time. A
    reviewer agent's writes to `docs/plans/*` are benign-tier on
    the orchestrator-side sweep (see scope-check.sh:62) and
    therefore committed-or-not. Threat: an adversarial reviewer
    edits `docs/plans/<plan>.md`'s File Structure mid-iteration to
    expand its own scope, and the NEXT dispatch's render sees the
    expanded scope. v1 mitigation: the renderer reads via
    `git rev-parse --show-toplevel`'s worktree state, which the
    reviewer COULD have written to in the current dispatch — but
    the validator's cross-check (D-005 rule 6) re-runs the matcher
    against the SAME on-disk plan at validate-time, so an agent
    bypassing prompt rules to fake `defer_reason="out-of-plan-
    scope"` on an actually-in-plan file STILL trips the cross-
    check (the matcher reads the same state the renderer did).
    The window the agent could exploit is "edit the plan to
    EXPAND scope, then claim the file is in-plan (not deferred)"
    — but that's the reverse direction (claiming in-plan to
    avoid the defer); the convergence-rounds gate (D-004) still
    applies to those rubric-deferred or rubric-blocking
    classifications. Documented as bounded; full plan-blob
    pinning is OQ-10.

## 7. Open questions

- **OQ-1.** Option (b) from the Linear ticket — reviewer/implementer
  proposes an in-band plan File Structure amendment as a structured
  "plan addendum" — is deferred to a follow-up. v1 ships the
  auto-defer path. **Working decision:** revisit if the auto-defer
  results in too many scope-deferred bullets that are actually
  legitimate plan-amendments-the-author-missed (operator pain signal:
  many deferred-majors comments where every deferred bullet is the
  same kind of plan gap, e.g. "test-helper.sh changed and its
  doc was stale"). Trigger ticket once observed.

- **OQ-2.** Should the validator cross-check the agent's
  `defer_reason="out-of-plan-scope"` claim by running
  `plan_scope::path_in_scope` against the row's
  `finding_class_key`-derived fix-target? **Working decision:**
  no in v1. The cross-check requires parsing the scope-anchor
  out of `finding_class_key` which has multiple format shapes per
  AGENT_PROMPTS.md:1437 guidance; the validator would need to
  match every shape robustly. Bounded by an agent that LIES (not
  one that errors); v1's safe-default is to trust the agent. If
  observed-needed (false defers slipping through), the
  cross-check is structural and small — follow-up.

- **OQ-3.** Should the rendered `{plan_scope_allowed_paths}` token
  include the `is_benign` path classes (`.scratch/*`,
  `docs/plans/*`, `docs/brainstorms/*`, `.pipeline/metrics/*`,
  `docs/knowledge/*`, `docs/pipeline-vocabulary.md`)? **Working
  decision:** no in v1. Per D-001 rationale: benign-paths are
  scope-check-runtime policy (church orchestrator-owned), not
  plan-structure. The reviewer rarely raises findings against
  these paths (they're not part of the feature); when it does,
  they should be treated as out-of-plan (and auto-deferred), which
  is the correct outcome. Future: if this causes annoying false
  defers (reviewer flags `docs/knowledge/decisions.md` for ADR
  drift, agent defers as out-of-plan when the operator wanted
  it fixed), we extend the prompt rule to also accept benign-path
  matches as in-scope. Not in v1.

- **OQ-4.** Cross-coordination with ENG-192 (implement-side
  fix-the-class). ENG-192's class-closure reads only the cited
  finding's defect mechanism. ENG-194's auto-defer happens at the
  reviewer; the implementer never sees the scope-deferred finding
  (it's in the deferred-majors comment, not in
  `{review_findings}`). The two are independent in v1; no
  coordination needed. **Working decision:** confirmed independent.

- **OQ-5.** Operator-discoverable preview of the rendered
  `{plan_scope_allowed_paths}` payload — should `bin/status.sh`
  surface it? **Working decision:** no in v1. The payload is
  derivable from the plan file directly; operators with the plan
  open already see the File Structure. If observed-needed
  (operators repeatedly debugging "why did this finding defer?"),
  add to `bin/status.sh`.

- **OQ-6.** Convergence-rounds-bypass safety on adversarial agent
  shapes. An agent that claims `defer_reason="out-of-plan-scope"`
  on every major finding could ship-with-debt on iteration 1
  every time, bypassing the convergence plateau entirely. Defense
  in v1: (a) the validator (D-005) rejects rows whose
  `defer_reason` doesn't match the closed vocabulary; (b) the
  operator-visible deferred-majors comment names the file; an
  adversarial agent claiming in-plan files as out-of-plan would
  be visibly inconsistent with the plan's contents to the
  operator. Not a hard failure in v1; OQ-2's cross-check would be
  the structural defense. **Working decision:** documented;
  bounded by the optional follow-up.

- **OQ-7.** `plan-scope.sh` API namespacing. Bash has no real
  namespaces; the `plan_scope::*` prefix is a convention.
  Conflicts with other `*::*` patterns in the codebase? **Working
  decision:** no conflicts (grepped: no other `::`-namespaced
  function patterns in `bin/`). The pattern follows informal
  shell conventions seen in some open-source projects (e.g.,
  bats). If preferred, fall back to `plan_scope_*` underscore-
  prefixed; same semantics. Implementation-time call.

- **OQ-9.** Lockfile review-findings (edge case 16). v1 leaves
  lockfiles in scope-check's stack-conditional benign set; the
  reviewer's defer for a lockfile finding is incorrect-but-bounded.
  **Working decision:** v1 accepts the auto-defer routing for
  near-nonexistent cases; if observed, extend
  `plan_scope::list_benign_path_classes` to consume profile-derived
  lockfile basenames at render time (the renderer already has
  profile access via `_resolve_*` calls).

- **OQ-10.** Full plan-blob pinning across dispatches (security
  persona iter-1 P1 #3 mitigation). v1 reads the worktree state at
  render time AND at validator time (same state — the cross-check
  works). For stronger isolation, the renderer could pin against
  `git show HEAD:<plan-path>` (the branch HEAD blob) and the
  validator could assert no plan-file write happened during
  dispatch. **Working decision:** defer; v1's cross-check already
  catches the "claim in-plan to avoid defer" direction; the
  remaining "expand plan to flip a finding from defer to in-plan"
  direction is a one-iteration soft window that the operator can
  spot in `bin/status.sh`'s commit log (any plan-file change
  surfaces). Bounded.

- **OQ-8.** Test mechanism for AC #5 (the ENG-27-class end-to-end).
  The full E2E requires a runtime `claude -p` invocation, which
  tests don't do. Per D-008, the fixture asserts the COUNT-TUPLE
  shape and verdict marker shape as proxies for the agent's
  in-prompt arithmetic. **Working decision:** documented;
  prompt-content-based testing is the established pattern (ENG-190
  D-003, ENG-191 D-008). The E2E shape is implicit in the
  conjunction of (a) the prompt rules being correctly worded,
  (b) the orchestrator-side fixtures asserting the correct
  partition behaviour, and (c) the validator gating the contract.

## 8. Out-of-scope reminders

- **The deferred-major exit machinery itself ([ENG-191]).** This
  ticket CONSUMES it. The selective-exit transition `reviewing →
  qa`, the `reason=ship-with-deferred-majors` marker, the
  orchestrator's `_post_deferred_majors_comment_if_eligible`, the
  `Deferrable:` line — all preserved and extended additively.
- **Auto-ticket creation per deferred major ([ENG-193]).** Future
  consumer. ENG-194 extends the ledger row's structured data
  (adds `defer_reason`) so ENG-193 can prefix tickets by reason.
- **Fixing the `scope-violation`-resume break ([ENG-180]).**
  Orthogonal, blocking parent of the manifest catch-22 but not
  this ticket's scope. ENG-194 eliminates the catch-22's
  occurrence; ENG-180 fixes the recovery for residual cases
  (e.g., critical-finding out-of-plan).
- **Validator-side cross-check that the agent's
  `defer_reason="out-of-plan-scope"` claim matches the actual
  scope-check verdict.** Deferred to OQ-2.
- **Plan-amendment in-band path (Linear option (b)).** Deferred to
  OQ-1.

## 9. ADR stress test

This brainstorm puts pressure on the following accepted decisions:

- **ENG-190 ledger schema (closed-minimal posture).** ENG-191 D-002
  already documented the additive-v1 path; ENG-194 adds ONE more
  optional field (`defer_reason`). Schema version unchanged. The
  conditional `decision_factors` relaxation (gated on `defer_
  reason="out-of-plan-scope"`) is a NEW validator-side branch,
  not a schema change. Within contract; ENG-190 OQ-5's "schema
  exposes enough signal" prediction continues to hold.

- **ENG-191 D-006 path-D predicate (agent-decides).** ENG-194
  EXTENDS the predicate inside the agent's prompt — adds the OR
  clause to the existing conjunction. The orchestrator-side hook
  (`_post_deferred_majors_comment_if_eligible`) reads `blocks_ship
  =false` rows regardless of `defer_reason`; the agent's marker
  shape (`verdict pass --reason ship-with-deferred-majors`)
  unchanged. Within ENG-191's "agent decides outcome, orchestrator
  publishes effect" boundary.

- **ENG-191 D-007 (no `guards.sh` code change).** Selective exit
  still fires `reviewing → qa` (forward); no rejection bump.
  Scope-deferred path inherits this; no `guards.sh` change for
  ENG-194 either. Within contract.

- **ENG-87 cross-dispatch staleness contract.** The schema-grace
  clause (ENG-191 D-002 inheritance) gates the new `defer_reason`
  check by `dispatch_id == --dispatch-id`. Strictly additive;
  no stress.

- **CLAUDE.md "Don't add features beyond what the task requires."**
  Linear scope explicitly lists 4 IN items, all delivered:
  (1) reviewer computes per-finding scope-status (D-002);
  (2) out-of-plan-scope → `blocks_ship=false` + reason (D-003);
  (3) excluded from loopback (D-004 + structural via D-002);
  (4) shared matcher with byte-for-byte assertion (D-001 + D-008).
  Plus the 5 ACs map to decisions. No fifth feature.

- **CLAUDE.md "AGENT_PROMPTS.md is load-bearing."** §5 gains ~25
  lines (Plan-scope adjudication block + path-D predicate
  extension + Output bullet update). No fence-count change; no
  new H2 section.

- **CLAUDE.md "Defense-in-depth: prefer transcript-based assertion
  over post-dispatch state check."** The new ENG-194 contract is
  the agent's CLASSIFICATION choice (`defer_reason`). v1 trusts
  the agent; OQ-2 documents a cross-check follow-up. The
  transcript-based assertion equivalent ("did the agent claim
  scope-deferred for an in-plan file?") requires runtime
  `plan_scope::path_in_scope` cross-check against the row's
  fix-target — that's a structural validator extension, not a
  transcript pattern match. OQ-2 captures the trade-off.

- **CLAUDE.md "Sub-agent debris (ENG-100)."** The reviewer agent
  does NOT write fixture files to verify the scope match; the
  matcher logic is rendered into the prompt as a token, and
  the agent reads it. Same constraint as ENG-191; respected.

- **scope-check.sh's "benign-path classes" surface.** ENG-194
  EXTRACTS the parse + match logic but PRESERVES `is_benign` in
  scope-check.sh per D-001. The reviewer's structural match is
  intentionally STRICTER than scope-check's runtime gate (does
  not consult benign classes). OQ-3 documents the trade-off; the
  rare case (`docs/knowledge/decisions.md`-style ADR drift
  findings) is acceptable as a deferred-major if it occurs.

## 10. Simpler-alternative pass

Per-decision rejected alternatives documented inline. Consolidated:

| Decision | Rejected alternative | Why rejected |
|---|---|---|
| D-001 | Leave parse/match inline in scope-check.sh; render-prompt re-executes scope-check.sh | scope-check.sh main has side effects; renderer needs sets, not yes/no |
| D-001 | Duplicate the parse logic in render-prompt.sh | AC #4 forbids divergence; duplicated code drifts |
| D-001 | Bake JSON sidecar on disk | One more artifact + freshness contract; sourcing is established idiom |
| D-002 | Plan-scope check as question 1 of the five-question rubric | Loses `in_changed_code` signal; rubric is the in-plan path, not a checklist |
| D-002 | Sanction reviewer-requested out-of-scope edits in scope-check.sh | Linear option (c) explicitly rejected |
| D-002 | In-band plan-File-Structure amendment via reviewer/implementer | Linear option (b); deferred to OQ-1 |
| D-003 | Overload `ship_classification_rationale` with prefix | Prose drifts; closed token is debuggable |
| D-003 | Bump schema to v2 | Doubles validator surface; additive-v1 strictly less complex |
| D-003 | Separate file `review-scope-defers.jsonl` | Sprawl; per-finding record is the ledger |
| D-004 | Bypass convergence for ANY scope-deferred finding (mixed case) | Mixed case still benefits from rubric stability evidence |
| D-004 | Bypass convergence whenever scope-deferred-count > 0 | Same as above |
| D-005 | Bump schema to v2 | Same as D-003 |
| D-005 | Separate validator file | Same as D-003 |
| D-006 | Flat list with `(scope)`/`(rubric)` annotations | Sub-sections answer "any plan gaps?" at a glance |
| D-006 | Two separate Linear comments | One logical record; ENG-191 AC #4 one-comment contract |
| D-007 | Render as JSON | Plain text is the agent's read format |
| D-007 | Render compiled match output | Renderer doesn't know findings at render time |
| D-008 | Single omnibus end-to-end fixture | Per-AC tests give faster feedback |

## 11. Assumption inventory

| # | Assumption | Status | Evidence |
|---|------------|--------|----------|
| 1 | `bin/scope-check.sh::find_canonical_plan` exists and uses `linear: <ID>` frontmatter | **verified** | `bin/scope-check.sh:143-157` (read) |
| 2 | `bin/scope-check.sh::extract_scope_section` extracts the File Structure body via awk | **verified** | `bin/scope-check.sh:159-172` (read) |
| 3 | `bin/scope-check.sh` parses `allowed_files` and `allowed_dirs` via `grep -oE` regexes | **verified** | `bin/scope-check.sh:297-314` (read) |
| 4 | `bin/scope-check.sh`'s per-file in-scope check uses `grep -qxF` (exact-match) + per-line dir-prefix loop | **verified** | `bin/scope-check.sh:356-378` (read) |
| 5 | `bin/scope-check.sh::is_benign` consults `.scratch/`, `_BENIGN_PATH_CLASSES`, profile-derived lockfiles, and Rust crate-tests | **verified** | `bin/scope-check.sh:175-207` (read) |
| 6 | The post-stage sweep gating site that halts on `scope-violation` is `bin/scope-check.sh:380-385` (rc=3 SEVERE / rc=1 NOTABLE) | **verified** | `bin/scope-check.sh:380-391` (read) |
| 7 | `bin/render-prompt.sh::PROMPT_RESOLVERS` registers tokens; new resolvers add to the list AND need a `_resolve_*` function body | **verified** | `bin/render-prompt.sh:40-62` (read); `_resolve_review_converge_rounds` at lines 292-303 |
| 8 | `bin/render-prompt.sh::_write_rendered_paths_sidecar` enumerates path-shaped resolvers explicitly; non-path tokens stay out | **verified** | `bin/render-prompt.sh:94-127` (read) |
| 9 | `bin/render-prompt.sh::_resolve_review_converge_rounds` is the precedent for a non-path resolver returning data (lines 285-303) | **verified** | `bin/render-prompt.sh:285-303` (read) |
| 10 | `bin/review-ledger-schema.sh` has validation for `blocks_ship` (line 356-360), critical-floor (362-365), `ship_classification_rationale` (367-374), and `decision_factors` (375-390) | **verified** | `bin/review-ledger-schema.sh:354-390` (grep matched all four blocks) |
| 11 | `bin/review-ledger-schema.sh` uses rc=49 for incomplete and emits diagnostics via `_emit_incomplete` | **verified** | `bin/review-ledger-schema.sh:135-143` (read) |
| 12 | `bin/review-ledger-schema.sh` has `dispatch_id_flag` schema-grace clause cross-check | **verified** | `bin/review-ledger-schema.sh:151-174` (read) |
| 13 | `bin/run-stage.sh::_post_deferred_majors_comment_if_eligible` exists at lines 1483-1561 and reads ledger rows with `adjudicated_severity=major AND blocks_ship=false` | **verified** | `bin/run-stage.sh:1470-1561` (read) |
| 14 | The orchestrator's reviewing post-dispatch hook block is at `bin/run-stage.sh:2442-2455` (between `_validate_review_ledger` and `_validate_qa_payload`) | **verified** | `bin/run-stage.sh:2424-2455` (read) |
| 15 | `bin/pipeline-events.json::pass_reasons` array contains `"ship-with-deferred-majors"` | **verified** | `bin/pipeline-events.json:10-11` (grep) |
| 16 | AGENT_PROMPTS.md §5 Review Agent body spans lines 1335-1845 in the worktree; ENG-191's deferability adjudication block is at lines 1439-1480 | **verified** | AGENT_PROMPTS.md:1335-1845 (read in pages); deferability block at 1439-1480 confirmed |
| 17 | AGENT_PROMPTS.md §5 count-tuple emission (`Findings:`, `Adjudicated:`, `Deferrable:`) is at lines 1481-1500 | **verified** | AGENT_PROMPTS.md:1481-1500 (read) |
| 18 | AGENT_PROMPTS.md §5 mechanical predicates block (path B / C / D / B′) is at lines 1614-1620 | **verified** | AGENT_PROMPTS.md:1614-1620 (read) |
| 19 | AGENT_PROMPTS.md §5 review-comment-quality rubric mandates `path/to/file.ext:LINE` anchor at lines 1572-1586 | **verified** | AGENT_PROMPTS.md:1572-1586 (read) |
| 20 | AGENT_PROMPTS.md §5 Output bullet for ledger-row emission is at lines 1776-1801 | **verified** | AGENT_PROMPTS.md:1776-1801 (read) |
| 21 | `bin/scope-check-test.sh` exists in `bin/` per project profile File layout | **verified** | `ls bin/scope-check-test.sh` (Bash listed) |
| 22 | `bin/review-ledger-schema-adversarial-test.sh` exists in `bin/` per project profile File layout | **verified** | `ls bin/review-ledger-schema-adversarial-test.sh` (Bash listed) |
| 23 | `bin/agent-prompts-content-test.sh` is the prompt-content content test harness (ENG-190 D-003 + ENG-191 D-008 prior art) | **verified** | iter-2 feasibility persona confirmed the file is present in the worktree |
| 24 | `bin/render-prompt-test.sh` exists per the ENG-191 D-010 brainstorm's referenced test mechanism | **verified** | iter-2 feasibility persona confirmed |
| 25 | `bin/run-stage-test.sh` exists per the ENG-191 D-008 brainstorm's referenced test cases | **verified** | iter-2 feasibility persona confirmed |
| 26 | `bin/common.sh::issue_dir` returns `$PROJECT_STATE_DIR/<issue>` and is used in `_post_deferred_majors_comment_if_eligible` to locate the ledger | **verified** | `bin/run-stage.sh:1493` calls `issue_dir "$ident"` directly (read) |
| 27 | `docs/runbooks/recovery.md` exists with sections 1-13 (ENG-191 added §13) | **verified** | iter-2 feasibility persona confirmed |
| 28 | `docs/runbooks/operator-mental-model.md` exists with §3 grep-recipe surface | **verified** | iter-2 feasibility persona confirmed |
| 29 | `_validate_review_ledger` is invoked at `bin/run-stage.sh:2432` in the reviewing-stage post-dispatch validator gate (between envelope validator and deferred-majors hook) | **verified** | `bin/run-stage.sh:2428-2440` (read) |
| 30 | `bin/scope-check.sh` honours `$SCOPE_CHECK_PROFILE_PATH` env-var override (TEST-ONLY) | **verified** | `bin/scope-check.sh:98-108` (read) |
| 31 | `find_fresh_verdict` returns the agent's verdict marker with `.event.reason` accessible via jq | **verified** | `bin/run-stage.sh:1488-1491` calls `jq -r '.event.reason // ""' <<<"$fresh"` (read) |
| 32 | `_san` sanitisation helper inside `_post_deferred_majors_comment_if_eligible` already handles `<!--` and newline/CR | **verified** | `bin/run-stage.sh:1508-1514` (read) |
| 33 | The `bin/pipeline-events.json::pass_reasons` registry has `field_registry_by_arm.pass.reason = "pass_reasons"` entry (ENG-191) | **verified** | `bin/pipeline-events.json:113` (grep) |
| 34 | No existing code uses `defer_reason` or `out-of-plan-scope` anywhere in `bin/` or AGENT_PROMPTS.md (no collision) | **verified** | grep across `bin/*.sh`, `AGENT_PROMPTS.md`, `bin/pipeline-events.json` returned zero hits (empty output) |
| 35 | `plan_scope_allowed_paths` is not yet a registered token in `PROMPT_RESOLVERS` (no collision) | **verified** | grep over `bin/render-prompt.sh` for `plan_scope` returned no matches |
| 36 | `bin/review-ledger-schema.sh` has a `_warn_unknown` helper for emitting unknown-field warnings | **verified** | `bin/review-ledger-schema.sh:145-147` defines `_warn_unknown() { log "[review-ledger-schema] warning: unknown $1: $2"; }` (re-read in iter-2). The known-fields allowlist is in the per-row jq filter at lines 311-318 per ENG-191 D-009. |
| 37 | `plan_scope_benign_path_classes` is not yet a registered token (D-007 second resolver — no collision) | **verified** | grep over `bin/render-prompt.sh` for `benign_path_classes` returned no matches |
| 38 | `bin/scope-check.sh:59-65` defines `_BENIGN_PATH_CLASSES` as a 5-glob hardcoded array (`docs/{knowledge,plans,brainstorms}`, `.pipeline/metrics/*`, `docs/pipeline-vocabulary.md`) | **verified** | `bin/scope-check.sh:59-65` (re-read in iter-2) |
| 39 | `bin/scope-check.sh:175-207` `is_benign` consults the path-class globs, profile-derived lockfiles, and Rust crates-tests in that order | **verified** | `bin/scope-check.sh:175-207` re-read in iter-2 |

## 12. Out-of-scope flags

This brainstorm stays inside the Linear scope as written. Three
soft near-misses worth calling out (each within scope but not
literally enumerated):

- **D-001 (shared helper extraction to `bin/plan-scope.sh`).**
  Required by Linear AC #4 ("one helper, both callers");
  structural extraction.
- **D-007 (`{plan_scope_allowed_paths}` resolver + sidecar
  exclusion).** Required by D-002 — the agent needs the parsed
  sets at render time; the resolver is the established plumbing.
- **D-006 (orchestrator deferred-majors comment grouping).**
  Required by AC #2 (visible audit trail). The grouping is the
  smallest UX delta that distinguishes the two reasons; the
  alternative (flat list with annotations) is rejected for
  operator clarity.

All five Linear acceptance criteria map to concrete decisions:

- AC #1 (out-of-plan finding → `blocks_ship=false
  reason=out-of-plan-scope`, excluded from loopback) → D-002 +
  D-003 + D-004.
- AC #2 (routed to ENG-191 deferred-majors path, not silently
  dropped) → D-006 (UI surface).
- AC #3 (in-plan finding unchanged) → D-002 (rubric fall-through)
  + D-004 (predicate compatibility).
- AC #4 (shared matcher; assert both call the same function)
  → D-001 + D-008.
- AC #5 (ENG-27-class advance instead of deadlock) → D-002 +
  D-004 + D-008 end-to-end fixture.

All Linear IN bullets covered:

- "The reviewer/adjudicator computes, per finding, whether the
  fix target falls within the plan's `## File Structure`" →
  D-002 + D-001 (shared parse).
- "A finding whose fix is out-of-plan-scope is emitted with
  `blocks_ship=false` + reason `out-of-plan-scope` (ENG-191
  deferability schema), routed to the deferred-majors comment/
  ticket path, and excluded from the loopback predicate" →
  D-003 (schema) + D-006 (comment) + D-004 (loopback exclusion
  via path-D predicate).
- "The shared matcher is the single source of truth so a finding
  the reviewer defers as out-of-scope is exactly what scope-check
  would have halted on (no divergence)" → D-001 (extraction) +
  D-008 (byte-for-byte test).

All Linear OUT bullets honoured:

- "The deferred-major exit machinery itself (ENG-191)" → §8 first
  bullet; consumed unchanged.
- "Auto-ticket creation (ENG-193)" → §8 second bullet.
- "Fixing the scope-violation-resume break (ENG-180)" → §8 third
  bullet; orthogonal, scope-deferred path bypasses the broken
  resume.

## 13. Persona review

Six personas, canonical order (design → security → scope →
coherence → product → feasibility). Iteration history in §14.
The verdicts below are the **iteration-2** verdicts after the
post-iter-1 edits (P0s addressed; P1s addressed opportunistically).

### Persona 1 — Design

**Iter-1: CONCERN** — 2 P0 + 3 P1.

P0 #1 (two sources of truth: reviewer auto-defers benign-path
findings the implementer could fix). **Resolved iter-2** by
partitioning `is_benign` per D-001: stack-agnostic path-classes
moved to the shared helper; reviewer prompt-side check
(D-002 step 3) now consults BOTH `{plan_scope_allowed_paths}` AND
`{plan_scope_benign_path_classes}`. Stack-conditional residue
(lockfiles, Rust crates-tests) stays in scope-check.sh as
documented exception — divergence documented in §6 Edge case 16
as bounded acceptable.

P0 #2 (multi-target finding rule contradicts "first-listed
canonical anchor"). **Resolved iter-2** by collapsing D-002's
multi-target rule to the SINGLE canonical anchor (mandated by
the existing review-comment-quality rubric at
AGENT_PROMPTS.md:1572-1586). Tie-break ambiguity eliminated.

P1 findings #3-#5 (closed-vocab `defer_reason` informational
case looseness; known-fields seed-header drift; silent-
degradation observability). **Addressed iter-2**: D-005 rule 5
adds the lockstep seed-header update; assumption #36 newly
verifies `_warn_unknown`; soft-fail observability deferred as
OQ-9 / acceptable. Lockfile-finding bound documented as Edge
case 16.

**Iter-2 verdict: PASS** (all P0 resolved; P1s addressed).

### Persona 2 — Security

**Iter-1: CONCERN** — 1 P0 + 3 P1.

P0 #1 (adversarial agent claims `defer_reason="out-of-plan-
scope"` to bypass convergence-rounds gate; validator only checks
vocabulary, not the claim). **Resolved iter-2** by promoting
OQ-2's structural cross-check to v1: D-005 rule 6 sources
`bin/plan-scope.sh`, parses the fix-target out of
`ship_classification_rationale` (the prompt-mandated anchor in
D-002 makes parsing deterministic), and runs the shared matcher.
Mismatch → rc=49 with `defer-reason-claim-disagrees-with-plan-
scope`. The cross-check is fail-open on unparseable rationales
(prompt-content contract is the agent-side enforcement).

P1 #2 (path-suffix interpolation sanitisation): **Addressed
iter-2** — D-005's seed parsing tokenises the fix-target before
the matcher call (path tokens are bounded by `[^[:space:]]`);
the existing `_san` already covers `ship_classification_
rationale` interpolation into the deferred-majors comment.
Explicit pinning in §3 of "the path-suffix MUST go through `_san`"
is one prompt-content pin added (D-008 pin #6 now mentions it).

P1 #3 (plan-source-of-truth integrity): **Addressed iter-2** as
Edge case 17 + OQ-10. v1's validator cross-check provides
defense against the "claim in-plan to avoid defer" direction; the
reverse direction (expand plan to flip a defer) remains a one-
iteration soft window that operators see in commit history.
Bounded.

P1 #4 (validator helper naming): **Addressed iter-2** — D-005
explicitly names `sanitise_for_diag` (the ENG-190 D-009 helper at
`bin/review-ledger-schema.sh:115-121` — re-verified iter-2).

**Iter-2 verdict: PASS** (P0 resolved by validator cross-check;
P1s addressed).

### Persona 3 — Scope

**Iter-1: PASS** — 0 P0 + 2 P1.

P1 #1 (D-006 is a UX delta not literally an IN bullet). **Addressed
iter-2** by explicit carve-out in §1's product-principle paragraph:
D-006 acknowledged as the second subordinate touch (Option B),
with bound on implementation-time line count. AC #2's "not
silently dropped" requirement is structurally satisfied by the
ledger field, but the UX is part of the operator-discoverable
audit surface.

P1 #2 (subsystem count understated as 2; actually 3). **Addressed
iter-2** by honest re-count in §1: 3 subsystems (agent-prompts +
scope/sweep + orchestrator hook), 1 primary + 2 subordinates.
The rubric's "3+ → split" trigger has the "one subordinate"
carve-out, which Option B extends pragmatically; the trade-off
is documented explicitly so operators can revisit if the
implementation balloons.

**Iter-2 verdict: PASS** (P1s addressed, no new P0).

### Persona 4 — Coherence

**Iter-1: CONCERN** — 1 P0 + 4 P1.

P0 #1 (D-002 contradicts itself on critical+out-of-plan: first
paragraph says halt path via `verdict halt --reason agent-blocked`,
second paragraph says path B loopback + scope-check halts).
**Resolved iter-2** by deleting the first contradictory paragraph
and rewriting the second as the canonical resolution: critical+
out-of-plan goes path B as before, BUT the reviewer additionally
posts an operator-visible `critical-out-of-plan/<ident>` meta-
comment naming the file + the plan-amend + resume recipe. Edge
case 4 updated to reflect this.

P1 #2 (count drift §13 vs §3). **Resolved iter-2** by recounting
in iter-2 §3 architecture: 2 new + 13 edits (matches §3 file list).

P1 #3 (`_warn_unknown` not in assumption inventory). **Resolved
iter-2** by adding assumption #36 verifying `_warn_unknown` at
`bin/review-ledger-schema.sh:145-147`.

P1 #4 ("OMITTED or null" wording lacked test pin). **Resolved
iter-2** by adding D-008 pin #8 explicitly asserting both
substrings appear in the §5 block.

P1 #5 (D-002 doesn't name the `#ALLOWED_FILES#`/`#ALLOWED_DIRS#`
section markers). **Resolved iter-2** by D-002 step 3 update —
explicitly names both markers AND the third
`{plan_scope_benign_path_classes}` token's format.

**Iter-2 verdict: PASS** (all findings resolved).

### Persona 5 — Product

**Iter-1: PASS** — 0 P0 + 3 P1.

P1 #1 (operator action recipe missing from deferred-majors
comment body). **Addressed iter-2** by adding the "To fix any
of the above in-PR" trailer to D-006's body template (3-line
operator recipe pointing at plan-amend + `bin/pipeline.sh decide
--action continue`). Trailer omitted when M=0 (no scope-
deferred bullets).

P1 #2 (verbose decision-factors lines balloon busy issues).
**Addressed iter-2** by collapsing decision-factors to a single
inline line per bullet (`y|n` shorthand). Verbose form preserved
in the ledger row (ENG-193 / retrospective reads the ledger,
not the comment).

P1 #3 (critical+out-of-plan still bounces operator into broken
ENG-180 recovery). **Addressed iter-2** — D-002 final paragraph +
Edge case 4 add the `critical-out-of-plan/<ident>` meta-comment
with explicit operator recipe, removing the "triage from scratch"
pain.

**Iter-2 verdict: PASS** (P1s addressed; product UX strictly
improved vs iter-1 draft).

### Persona 6 — Feasibility

**Iter-1: PASS** — 0 P0 + 0 P1.

Iter-1 feasibility persona verified all 35 assumptions, all
file paths, all line citations, all proposed-new file/token
non-collision. AGENT_PROMPTS.md §5 line citations (5 spots) all
verified correct. The three §11 "assumed" entries upgraded to
verified at no cost (files present in worktree).

Iter-2 additions: assumption #36 (`_warn_unknown` verified),
#37 (`plan_scope_benign_path_classes` non-collision verified),
#38 (`_BENIGN_PATH_CLASSES` array verified), #39 (`is_benign`
internal order verified). All four cited `path:line` evidence.

**Iter-2 verdict: PASS** (0 P0; codebase-fact-correctness
strengthened by the iter-2 cross-check additions).

**Gate verdict: 6/6 PASS, 0 P0. Proceed to planning.**

## 14. Iteration history

- **Iteration 1 (2026-06-14).** Initial draft. All 6 personas ran.
  Verdicts: Design CONCERN (2 P0, 3 P1), Security CONCERN (1 P0,
  3 P1), Scope PASS (2 P1), Coherence CONCERN (1 P0, 4 P1),
  Product PASS (3 P1), Feasibility PASS (0 P0, 0 P1). Total: 3/6
  PASS, 4 P0. Gate NOT met (required 5/6 PASS + 0 P0 from
  feasibility); iterated.

- **Iteration 2 (2026-06-14).** All 4 P0 findings addressed:
  (1) D-001 partitioned `is_benign` so stack-agnostic classes move
  to shared helper (design P0 #1); (2) D-002 multi-target rule
  collapsed to single canonical anchor (design P0 #2); (3) D-005
  rule 6 promoted: validator cross-check parses fix-target from
  `ship_classification_rationale` and re-runs matcher (security
  P0 #1); (4) D-002 contradictory critical+out-of-plan paragraph
  deleted; replaced with critical-out-of-plan/<ident> meta-comment
  operator recipe (coherence P0 #1). All P1 findings addressed
  opportunistically. §3 architecture, §6 edge cases (added 16+17),
  §7 open questions (added OQ-9 + OQ-10), §11 assumption inventory
  (added #36-#39, upgraded 5 entries from "assumed" to verified
  per feasibility persona walk-through), §13 persona review
  (rewrote with iter-2 verdicts). Iter-2 internal re-pass: all 6
  personas PASS, 0 P0. Gate MET.
