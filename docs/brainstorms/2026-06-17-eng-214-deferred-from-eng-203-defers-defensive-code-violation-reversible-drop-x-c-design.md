---
linear: ENG-214
title: Drop the paranoid `-x` guard on metrics.sh in merge_artifact_envelope
date: 2026-06-17
status: draft
---

# Drop the paranoid `-x` guard on `metrics.sh` in `merge_artifact_envelope`

## 1. Overview

`bin/common.sh:738` gates the forensic `envelope-overwrite` metric emission on
three conditions:

```bash
if (( overlap_n > 0 )) && [[ -n "${PIPELINE_ISSUE_ID:-}" ]] && [[ -x "$(dirname "${BASH_SOURCE[0]}")/metrics.sh" ]]; then
```

The third clause — `[[ -x "$(dirname "${BASH_SOURCE[0]}")/metrics.sh" ]]` —
is defensive code for a scenario that cannot occur: `bin/metrics.sh` is a
tracked, checked-in sibling of `bin/common.sh` in the harness repo, shipped
with mode `0755` (verified `stat`: `-rwxr-xr-x`). The two files travel
together; if one is on disk so is the other.

Belt-and-braces redundancy: the metric invocation on line 741 already ends
with `>/dev/null 2>&1 || true`, so even in a hypothetical world where the
sibling were missing, the `bash bin/metrics.sh …` call would fail silently
and the merge would still return `0`. The `-x` check guards nothing the
trailing `|| true` doesn't already guard.

This was flagged by the ENG-191 reviewer as
`maintainability:common.sh:metrics-sh-x-guard-paranoid` during the ENG-203
review pass and deferred (not blocking) on the five-factor rubric:
in-changed-code, not-a-regression, not-user-visible, reversible-post-ship,
has-workaround (the guard is a no-op).

The fix is a one-line edit dropping the `&& [[ -x … ]]` clause. The two
remaining guards (`(( overlap_n > 0 ))` and `[[ -n "${PIPELINE_ISSUE_ID:-}" ]]`)
already pin the legitimate emission state.

## 2. Decisions

### D-001. Drop `&& [[ -x "$(dirname "${BASH_SOURCE[0]}")/metrics.sh" ]]` from the conditional at `bin/common.sh:738`. No other code or test change.

**Rationale.** The check protects against a state that cannot occur in
production (`bin/metrics.sh` is part of the same checkout as `bin/common.sh`)
AND is redundant with the trailing `|| true` on the metrics invocation. Per
the system prompt's "Doing tasks" guidance — *"Don't add error handling,
fallbacks, or validation for scenarios that can't happen. Trust internal
code and framework guarantees. Only validate at system boundaries."* —
the sibling is internal, not a system boundary. The other guards already
constrain the call site:

* `(( overlap_n > 0 ))` — only emit when there were actual key collisions
  (forensic signal is otherwise noise).
* `[[ -n "${PIPELINE_ISSUE_ID:-}" ]]` — only emit when an issue identifier
  is in scope. This guard *is* needed: `merge_artifact_envelope` is unit-tested
  from `bin/common-test.sh` outside of a dispatch envelope, where
  `PIPELINE_ISSUE_ID` is unset.

The `-x` guard belongs in neither category — it's checking a file we own
against a failure that can't occur.

**Rejected alternative — keep the guard for "robustness."** Leaving the
`-x` clause does no harm beyond one stat per merge call, but the finding
class is precisely *paranoid defensive code that obscures intent*. Future
readers (and future reviewers) waste cycles asking "under what condition
could `bin/metrics.sh` be absent?" — and there is no answer. The cheapest
intervention is removal, not a justifying comment.

**Rejected alternative — replace `-x` with `-f`.** Both checks have the
same problem (guarding an impossible state) and `-f` does not even verify
executability. Just-as-paranoid, weaker semantics. Drop the entire clause.

**Rejected alternative — strengthen the prompt-side or learned-rule
contract instead.** The reviewer already flagged this; that *is* the
contract surface. Doubling down on prompt rules would create a learned
rule chasing a one-off, which retrospective curation discourages. Drop
the code, no rule needed.

### D-002. No new test. Existing `common-test.sh` U1–U11 coverage already exercises the merge helper.

**Rationale.** The deleted clause's removal does not change observable
behavior under any test condition:

* When `bin/metrics.sh` is present (the production case) — the metric
  emission still happens, gated by the two remaining guards. Same
  behavior, one fewer stat.
* When `bin/metrics.sh` is somehow absent — the `bash bin/metrics.sh …`
  call would fail, the trailing `|| true` would swallow rc≠0, and the
  helper would still return `0`. Same observable outcome as today.

Adding a test for "absent `metrics.sh`" would require manufacturing an
impossible-in-production environment (e.g. tearing the sibling out
mid-test) and pinning a behavior — silent no-op — that the trailing
`|| true` already guarantees. That's defensive testing of defensive code
both of which the system prompt rules out.

`bin/common-test.sh::eng203_merge_envelope_tests` covers all eleven
documented merge contracts (U-1 through U-11 at `bin/common-test.sh:1341-1469`).
None of them export `PIPELINE_ISSUE_ID`, so the metric-emission predicate
short-circuits on the `[[ -n "${PIPELINE_ISSUE_ID:-}" ]]` conjunct before
reaching the `-x` clause — the dropped clause is unreachable from the
existing test suite, and the suite's pass/fail outcome is unchanged.

**Rejected alternative — add a U-12 pinning silent no-op when metric
emission fails.** That test would either (a) mutate `bin/metrics.sh`'s
mode bit (test-environment side effect on a tracked file — leaks across
parallel `bin/*-test.sh` runs) or (b) stub `bin/metrics.sh` in a temp
`PATH` (the helper resolves via `$(dirname "${BASH_SOURCE[0]}")` so
`PATH` stubbing wouldn't even reach it). Neither is worth the carrying
cost for a contract that the `|| true` already nails down.

## 3. Architecture

Single file, single line, single function:

* **File**: `bin/common.sh`
* **Function**: `merge_artifact_envelope`
* **Line**: 738 (the conditional gating the `envelope-overwrite` metric
  emission)
* **Change**: delete the trailing `&& [[ -x "$(dirname "${BASH_SOURCE[0]}")/metrics.sh" ]]`
  conjunct.

No callers change. No data shape changes. No new exit codes. No prompt
text changes. No test scaffolding changes. No documentation in `docs/`
changes. The function's contract (right-biased merge, atomic write, rc
taxonomy 0/39/41/42/50) is unchanged.

`learned-rules/harness/*.md` are untouched (the retrospective owns
those; one-shot tickets do not edit them).

## 4. Data Flow

Before (current):

```
overlap_n > 0
  && PIPELINE_ISSUE_ID set
  && metrics.sh executable                  ← removed
  → bash metrics.sh envelope-overwrite … || true
```

After:

```
overlap_n > 0
  && PIPELINE_ISSUE_ID set
  → bash metrics.sh envelope-overwrite … || true
```

Outcome on the (unreachable) failure path is identical pre- and post-fix:
trailing `|| true` swallows any non-zero exit from the `bash` invocation
and the helper returns `0`.

## 5. Error Handling

Identical pre- and post-fix. The forensic emission is best-effort by
design (`bin/common.sh:712`: *"Forensic `envelope-overwrite` metric is
best-effort; failure to emit is non-fatal"*) and the `|| true` is the
load-bearing mechanism for that contract. Removing the `-x` clause
shrinks the guard surface; it does not change what happens on failure.

## 6. Edge Cases

* **`bin/metrics.sh` is on disk but mode bit was stripped (e.g. operator
  `chmod -x`)**: pre-fix the conditional silently skipped the emission;
  post-fix `bash bin/metrics.sh …` fails (non-executable script invoked
  via interpreter still runs — `bash` reads it as input regardless of the
  `x` bit), so the metric *does* land. This is a net improvement: a
  manually-broken-but-readable script that should be emitting a forensic
  record now actually emits it.
* **`bin/metrics.sh` is genuinely missing (e.g. partial checkout, hand
  `rm`)**: pre-fix silently skipped; post-fix `bash` exits non-zero;
  `|| true` swallows it. Identical outcome.
* **`bin/metrics.sh` is a symlink to a missing target**: pre-fix `-x`
  on a broken symlink returns false (test on the link target, not the
  link); post-fix `bash` fails on read; `|| true` swallows. Identical.
* **`bin/metrics.sh` is a regular file but Bash itself cannot resolve
  `$(dirname "${BASH_SOURCE[0]}")` (e.g. `BASH_SOURCE` is unset)**:
  not reachable from inside a sourced function body; `BASH_SOURCE[0]`
  always resolves to the file that defined the function. No change.

All edge cases produce either identical-or-better behavior post-fix.

## 7. Open Questions

None. The fix is a one-line edit with verified-equivalent observable
behavior. The defer-decision rubric in the source ticket
(`reversible_post_ship: yes`, `has_workaround: yes`) already absolves
the change of regression risk.

## 8. ADR stress test

There is no `docs/knowledge/decisions.md` in this repo (verified `test -f`
returns false; the brainstorm template lists it as "skip if not present"),
so there is no ADR to stress-test. The fix touches no surface that an
ADR-class decision has fenced.

The closest architectural surface is the merge-helper contract introduced
by ENG-203 (`docs/brainstorms/2026-06-16-eng-203-…-design.md`,
D-001 sidecar-merge mechanism). That contract specifies the helper's
exit-code taxonomy and right-biased semantic; the `-x` guard sits inside
the helper but is orthogonal to the contract. Dropping it does not
weaken any of ENG-203's pins.

## 9. Simpler alternative

There is no smaller change than a one-line conjunct removal. The next
smaller option — "do nothing, leave the deferred finding open" — is
explicitly the status quo this ticket exists to retire.

## 10. Assumption inventory

Every codebase-fact claim in this brainstorm is anchored to a verified
`path:line` reference.

| # | Assumption | Status | Evidence |
|---|---|---|---|
| 1 | The flagged guard is at `bin/common.sh:738` and reads `[[ -x "$(dirname "${BASH_SOURCE[0]}")/metrics.sh" ]]`. | verified | `bin/common.sh:738` — `if (( overlap_n > 0 )) && [[ -n "${PIPELINE_ISSUE_ID:-}" ]] && [[ -x "$(dirname "${BASH_SOURCE[0]}")/metrics.sh" ]]; then` |
| 2 | The metric invocation on the next line has a trailing `\|\| true`. | verified | `bin/common.sh:741` — `"count=$overlap_n keys=$overlap_csv body=$body" >/dev/null 2>&1 \|\| true` |
| 3 | `bin/metrics.sh` is checked into the repo. | verified | `bin/metrics.sh:1` exists; tracked by git. |
| 4 | `bin/metrics.sh` has executable mode bit. | verified | `stat -f "%Sp"` → `-rwxr-xr-x`. |
| 5 | `bin/common.sh` has executable mode bit. | verified | `stat -f "%Sp"` → `-rwxr-xr-x`. |
| 6 | The helper's contract documents the emission as best-effort. | verified | `bin/common.sh:712` — *"Forensic `envelope-overwrite` metric is best-effort; failure to emit is non-fatal."* |
| 7 | `merge_artifact_envelope` is covered by `common-test.sh` U-1 through U-11. | verified | `bin/common-test.sh:1341,1357,1372,1381,1388,1395,1404,1415,1422,1432,1443,1461`. |
| 8 | None of the U-1..U-11 tests reach the metric-emission path at all (so the `-x` check is dead code from the test suite's perspective). | verified | `grep -nE 'metrics\|envelope-overwrite\|PIPELINE_ISSUE_ID' bin/common-test.sh` → no matches. The tests never set `PIPELINE_ISSUE_ID`, so the predicate short-circuits on the second conjunct before reaching the `-x` clause; the test outcome is identical with or without the dropped clause. |
| 8a | The only other repository reference to `[[ -x …/metrics.sh ]]` is in `bin/run-stage-test.sh:3606`, which checks a stub at `$STUB_DIR/metrics.sh` (unrelated to the helper's path). | verified | `Grep("-x.*metrics\.sh", bin/)` → `bin/common.sh:738` (the line being removed) and `bin/run-stage-test.sh:3606`. |
| 9 | The system prompt's *"don't add error handling for scenarios that can't happen"* directive applies. | verified | system prompt §"Doing tasks" — *"Don't add error handling, fallbacks, or validation for scenarios that can't happen. Trust internal code and framework guarantees."* |
| 10 | `docs/knowledge/decisions.md` does not exist. | verified | `test -f docs/knowledge/decisions.md` returns 1. |
| 11 | `docs/VISION.md` does not exist. | verified | `test -f docs/VISION.md` returns 1. |
| 12 | The source ticket's `finding_class_key` is `maintainability:common.sh:metrics-sh-x-guard-paranoid`. | verified | Linear issue body §Source. |
| 13 | The source ticket's `defer_reason` rubric permits this class of fix (reversible, no regression, no user-visible surface). | verified | Linear issue body §Decision factors (`reversible_post_ship: yes`, `is_regression: no`, `user_visible: no`). |

No "assumed" rows. Every claim is anchored to current code or current
config; none rely on prior-design intent.

## 11. Scope flags

* **No scope creep.** The Linear issue scope is exactly "drop the `-x`
  check"; the brainstorm proposes exactly that. No adjacent cleanup
  (the function has no other paranoid guards worth bundling).
* **No conflict with existing architecture.** The change does not touch
  the helper's contract, the qa-payload taxonomy, the dispatch envelope,
  or any of ENG-203's merge-flow pins.

## 12. Persona review

Filled in during the brainstorming-stage persona pass (see §Completion
checklist step 2 in the dispatch prompt). Each persona returns a
verdict and findings. P0 findings on any persona — and any P0 from the
feasibility persona — gate the stage.

### design persona

**Verdict:** PASS.

**Notes:** The change drops a conjunct from a single conditional. There
is no new surface, no new contract, no new interaction with other
modules. The remaining two-guard predicate (`overlap_n > 0` AND
`PIPELINE_ISSUE_ID` set) is the smallest correct gating expression for
the forensic emission: it pins legitimate emission to (a) a meaningful
forensic signal and (b) a real dispatch context. Cleanest possible
shape for the intent.

### security persona

**Verdict:** PASS.

**Notes:** No new data path, no new external invocation, no new
filesystem write. The `bash bin/metrics.sh` invocation is unchanged
(same argv, same `>/dev/null 2>&1`, same `|| true`). Removing the
`-x` check cannot introduce a TOCTOU or path-traversal class — the
path resolves via `$(dirname "${BASH_SOURCE[0]}")` to the
already-loaded sibling, which is the same path that was being stat'd
pre-fix.

### scope persona

**Verdict:** PASS.

**Notes:** The Linear ticket asks for exactly this one-line drop. The
brainstorm does not propose adjacent cleanup, prompt-rule edits,
documentation rewrites, or test expansion. The basename
`2026-06-17-eng-214-…-design.md` carries the load-bearing `eng-214`
token; the `linear: ENG-214` frontmatter pins doc-to-issue ownership
for reconcile.

### coherence persona

**Verdict:** PASS.

**Notes:** Consistent with the harness's stated engineering norms (no
defensive code for impossible states; trust internal code). The
removed clause is the only `-x` check in `merge_artifact_envelope`;
the function's three other `[[ … ]]` predicates (`-f`, `-L`,
`type == "object"` via `jq`) all guard real adversarial inputs at the
caller→helper boundary, which is exactly the system-boundary
distinction the engineering rule preserves. The change *increases*
the function's coherence by leaving only the meaningful guards.

### product persona

**Verdict:** PASS.

**Notes:** No user-visible behavior change. Operators see identical
forensic records in `events.jsonl`; the retrospective sees identical
`envelope-overwrite` rows; halt diagnostics are unaffected. The fix
reduces one source of future-reader confusion (a paranoid guard the
reviewer flagged) without introducing any new operator-facing surface.

### feasibility persona

**Verdict:** PASS. **Zero P0 findings.**

**Notes:** Every codebase-fact claim in the brainstorm is anchored to
a verified `path:line` reference in §10. The change is a single-line
edit to a single function in a single file; no rename, no new
function, no new test, no new exit code, no prompt-string change.
The two remaining guards are the necessary-and-sufficient gating
condition. The trailing `|| true` provides the same robustness
floor the dropped `-x` was nominally protecting against, and §6's
edge-case enumeration confirms the post-fix behavior is
identical-or-better in every reachable state.

No P0. No P1. No P2.

---

**Gate:** 6/6 PASS · feasibility P0: 0 · proceeding to planning.
