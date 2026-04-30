---
linear: ENG-44
title: is_orchestrator_paused — close test-coverage gap for paused=false override
date: 2026-04-30
status: draft
---

# `is_orchestrator_paused` — close test-coverage gap for `paused=false` override

## 1. Context (and a load-bearing surprise)

The Linear issue describes a real bug: `bin/common.sh::is_orchestrator_paused`
used `jq -r '.orchestrator.paused // empty'`, and `//` treats `false` as
falsy, so a `STATE_FILE` carrying `{"orchestrator":{"paused":false}}` would
emit empty output and fall through to `config.json`. The "I've cleaned up,
resume" direction silently failed.

**The bug is already fixed.** Commit `d420c64` (ENG-49, "fix(ENG-49): respect
state.local.json paused override in poll and tick", 2026-04-30 09:44 IST)
replaced the `// empty` form with the explicit-null form:

```bash
override="$(jq -r 'if .orchestrator.paused != null then .orchestrator.paused else empty end' "$STATE_FILE" 2>/dev/null || true)"
if [[ -n "$override" ]]; then
  printf '%s' "$override"
  return
fi
```

(`bin/common.sh:127-134`, current `HEAD`.) ENG-49's commit message names the
exact same anti-pattern and applies the same fix sketched in ENG-44's "Fix"
section. ENG-44 was filed before its fix landed in a sibling issue, then
poll.sh picked it up.

This brainstorm therefore re-scopes ENG-44: **the code fix is done; the work
remaining is the comprehensive test table from the issue's "Test" section.**
ENG-49 added a single test row (state.local=`false` overrides config=`true`,
the exact regression direction) at
`bin/run-local-helpers-adversarial-test.sh:601-611`. The other five rows in
ENG-44's table — including both inverse direction and the
absent-key-at-various-levels cases — are uncovered.

Re-scoping also satisfies CLAUDE.md's "fix existing things; don't restructure"
implicit principle: doing the code change again would be a no-op churn-revert
loop, so we don't.

## 2. Goals

The user-facing outcome: an operator who runs `set_orchestrator_paused
false` after cleanup gets the orchestrator to actually resume on the next
tick, and that contract cannot silently re-break when a future contributor
"simplifies the verbose jq." The five new test rows are the load-bearing
defense — together they cover both override directions plus all
key-absent fall-through branches that the existing one-row test does not.

1. **Test the entire ENG-44 table.** All six rows pass against the current
   `is_orchestrator_paused` implementation.
2. **Self-contained location.** Tests for `bin/common.sh` helpers live in
   their natural home, not bolted onto a sibling test file.
3. **No code-fix churn.** The implementation is correct; do not revert,
   re-fix, or rewrite it.
4. **Discoverable provenance.** A future reader hitting this file can trace
   each row back to ENG-44's table and to the original bug it guards against.

Non-goals (explicit per ENG-44's "Out of scope"):

- Restructuring the override mechanism (multi-key, layered hierarchy, etc.).
- Auditing every other `jq // empty` site in the harness — `grep '// empty'`
  shows ~20 hits; most are for strings where empty-vs-absent equivalence is
  fine, but the audit is its own ticket.

## 3. Decisions

### D-001 — New test file `bin/common-test.sh`

**Decision.** Add a new self-contained test file `bin/common-test.sh` that
covers all six rows of ENG-44's table. It follows the standard
source-and-stub pattern (`set -uo pipefail` at the top, source `common.sh`,
PASS/FAIL counters, `assert_eq`, sentinel test main).

**Why this matches the project's intent.** ENG-44's "Files likely to change"
section lists this exact path as the primary option. CLAUDE.md's testing
section names "sibling shell scripts named `*-test.sh` in `bin/`" as the
canonical pattern, with the explicit example "When a new bash file is meant
to be both executable and unit-testable, replicate the sentinel pattern" —
applied here to `common.sh` itself, which currently has no dedicated test
file (its helpers are tested transitively through mutex-test, classify-test,
etc., but `is_orchestrator_paused` is one of the few not tested transitively
anywhere).

**Why not extend `bin/run-local-helpers-adversarial-test.sh`** (the file
ENG-49's row 2 lives in). The function under test is in `common.sh`, not
`run-local-helpers.sh`; conceptually the test belongs with its function.
ENG-49's existing row stays where it is — moving it would invent churn and
sever the commit-message-to-test traceability. A small overlap (row 2 tested
in two files) is the cost; the benefit is a self-contained module-level
test.

**Why not extend `bin/run-stage-test.sh`** (ENG-44's secondary suggestion).
`is_orchestrator_paused` has five call sites — `bin/poll.sh:376`,
`bin/run-local.sh:91`, `bin/run-stage.sh:251`, `bin/reset-pipeline.sh:31`,
and `bin/dry-run.sh:73` (verified by `grep -n "is_orchestrator_paused"
bin/*.sh`). The function-under-test is owned by `common.sh`, not by any
single caller. Putting tests in `run-stage-test.sh` would arbitrarily
favour one of five callers and bury the test for a future reader looking
at the function definition. `common-test.sh` co-locates with the
function's home and tests the contract once, regardless of caller count.

### D-002 — Cover all six rows, accepting a one-row overlap with ENG-49

**Decision.** `common-test.sh` covers all six rows of the ENG-44 table.
Yes, this duplicates ENG-49's `test_paused_override_honored`. Accept the
duplication.

**Why.** A reader of `common-test.sh` should be able to verify behavior of
`is_orchestrator_paused` without cross-referencing a different test file.
The marginal cost of one duplicate `assert_eq` is trivial; the marginal
benefit is self-contained module coverage that doesn't require a reader to
mentally union two test files to know what's verified.

**Why not "test only the five missing rows".** That requires every future
reader to know that one row is "elsewhere" and find it, which defeats the
self-containment goal. Comprehensive-and-redundant beats incomplete-and-
distributed for module unit tests.

### D-003 — Add a one-line "why" comment to `is_orchestrator_paused`

**Decision.** Add a single comment above the jq expression at
`bin/common.sh:129` explaining why the longer `if … != null then … else
empty end` form is required (i.e., `// empty` is wrong because `false` is
jq-falsy).

**Why.** The current code carries no in-file explanation of why the verbose
form was chosen over the natural `// empty`. A future contributor doing a
"clean up this verbose jq" sweep could regress the bug. One short line —
"don't simplify to `// empty`: `false` is jq-falsy, eats the override" —
prevents that.

**Why not a regression-prevention lint.** ENG-44's "Out of scope" explicitly
defers the broader audit; a one-off lint just for this site is over-built.
The comment is the lightest-weight defense and is in-band with the code it
protects.

### D-004 — No change to any call site

**Decision.** Leave all five call sites alone (`bin/poll.sh:376`,
`bin/run-local.sh:91`, `bin/run-stage.sh:251`, `bin/reset-pipeline.sh:31`,
`bin/dry-run.sh:73`). ENG-49 already routed `poll.sh` and `run-local.sh`
through `is_orchestrator_paused` (rather than `config_get
'.orchestrator.paused'` directly), and added a static-check test
(`test_paused_callsites_use_helper` at
`bin/run-local-helpers-adversarial-test.sh:616-622`) that fails if a future
edit reintroduces the bypass on those two scripts.

The other three callers (`run-stage.sh`, `reset-pipeline.sh`, `dry-run.sh`)
already use the helper directly (verified by `grep -n
"is_orchestrator_paused" bin/*.sh`), so the bypass-class regression is
already prevented at all five sites.

**Why no work here.** ENG-49's work is complete; touching call sites from
ENG-44 would expand scope and risk regressing an unrelated guard.

## 4. Architecture (where the code lives)

```
bin/common.sh                  ← implementation (already correct, +1 comment)
bin/common-test.sh             ← NEW: 6-row table from ENG-44
bin/run-local-helpers-          ← UNCHANGED: keeps ENG-49's test_paused_override_honored
  adversarial-test.sh             and test_paused_callsites_use_helper
```

Per CLAUDE.md's "How tests work" section, `common-test.sh` MUST:

1. Set `set -uo pipefail` at the top — drop the `-e` deliberately so a
   failed row does not abort the suite before later rows run. **This is
   not the dominant project convention** (~30 sibling tests use
   `set -euo pipefail`; only `bin/run-local-helpers-adversarial-test.sh:18`
   and `bin/profile-allowlist-test.sh:22` use `-uo`). Pick `-uo` here for
   the same table-driven reason those two files do: the test is a fixed
   six-row matrix, and the value of seeing all failing rows in one run
   outweighs fail-fast. Plan stage may switch to `-euo pipefail` if it
   prefers fail-fast — both are workable.
2. Resolve `SCRIPT_DIR` from `${BASH_SOURCE[0]}`.
3. Set `PROJECT_SLUG` before sourcing common.sh, because common.sh's
   slug-resolution path (`bin/common.sh:40-48`) calls `die` if it can't find
   one. Pattern is in use at `bin/run-local-helpers-adversarial-test.sh:21`.
4. Set `TARGET_REPO` to a temp dir that exists, since common.sh hard-checks
   `[[ -d "$TARGET_REPO" ]]` at line 12.
5. Source `common.sh` to get the function under test.
6. End each test by re-pointing `CONFIG` and `STATE_FILE` at per-test
   fixtures (this is exactly the per-call override pattern ENG-49's existing
   test uses at line 607: `CONFIG="$cfg" STATE_FILE="$sf" got="$(…)"`).
7. Print a summary line `common-test summary: N passed, M failed` and exit
   non-zero if `FAIL > 0`.

Add `bash bin/common-test.sh` to the project profile's `Test:` enumeration
in `learned-rules/harness/project-profile.md` so the next discovery-agent
refresh and the test-aggregator both pick it up. (Optional: out of scope of
ENG-44 strictly, but trivially in-line with the test addition. Decision
deferred to plan stage — ask there whether the project-profile pin should
update in the same PR.)

## 5. Data flow (the function, scenario by scenario)

The function `is_orchestrator_paused()` (`bin/common.sh:126-136`) operates
purely on file content; no network, no concurrency. The data flow per
ENG-44's table:

| # | STATE_FILE       | config.json `.orchestrator.paused` | jq STATE_FILE result | Branch taken      | Result   |
| - | ---------------- | ----------------------------------- | -------------------- | ----------------- | -------- |
| 1 | absent           | `true`                              | n/a (`-f` false)     | fall to CONFIG    | `true`   |
| 2 | `{paused:false}` | `true`                              | `false` (non-empty)  | print override    | `false`  |
| 3 | `{paused:true}`  | `false`                             | `true` (non-empty)   | print override    | `true`   |
| 4 | `{}`             | `true`                              | empty (path null)    | fall to CONFIG    | `true`   |
| 5 | `{orch: {}}`     | `true`                              | empty (path null)    | fall to CONFIG    | `true`   |
| 6 | `{}`             | absent                              | empty (path null)    | CONFIG `// "false"` | `false` |

Each test in `common-test.sh` is one row of this table.

## 6. Error handling

`is_orchestrator_paused` already handles the three failure modes that exist:

- **Malformed `STATE_FILE` JSON.** `jq -r … 2>/dev/null || true` swallows
  the error; override stays empty; falls through to CONFIG. (Tested
  implicitly by row 4/5 — if jq couldn't read the file, the same fall-
  through fires.)
- **Malformed `config.json` JSON.** Falls through `jq` without a guard; the
  unhandled error propagates. This pre-dates ENG-44 and ENG-49 and is out
  of scope; CLAUDE.md treats config.json as the contract surface that is
  validated by setup.sh.
- **STATE_FILE path unwritable.** Only matters for `set_orchestrator_paused`
  (ENG-44 writes are unaffected), and `set_orchestrator_paused` already
  `mkdir -p`s its parent at `bin/common.sh:141`.

No new error-handling work in this brainstorm.

## 7. Edge cases

- **Non-bool value** in either file (`{paused: "true"}` instead of `paused:
  true`). The function would emit the string `"true"`; the call sites
  compare `[[ "$paused" == "true" ]]` which still matches for that string.
  Not in ENG-44's table; not tested; left as-is.
- **`paused: 1` or `paused: 0`** (numeric instead of bool). Same as above —
  numeric `0` is non-empty in jq output, and the bash `==` comparison would
  fail-closed (treat as not-paused for `1`, fine). Not tested.
- **Race between two ticks** writing `STATE_FILE`. The `tmp + mv` rename in
  `set_orchestrator_paused` (`bin/common.sh:142-148`) is atomic on POSIX.
  No tearing. Not tested at the unit level (tested transitively by
  `mutex-test.sh`).
- **`STATE_FILE` symlink** to a missing path. `[[ -f X ]]` follows symlinks;
  the test in row 1 covers this implicitly by making the path absent.
- **Per-test `TARGET_REPO` setup.** `common.sh` requires `TARGET_REPO` to be
  a valid directory at source time (`bin/common.sh:12`). The test must
  `mktemp -d` and `export TARGET_REPO` BEFORE sourcing. Pattern verified at
  `bin/run-local-helpers-adversarial-test.sh:21-23` (sets `PROJECT_SLUG`
  before source; `TARGET_REPO` flows in from the harness invocation in CI,
  but for a self-contained test we set both).

## 8. Persona review

Six personas were run in order: design → security → scope → coherence →
product → feasibility. Iteration 1 results:

| Persona | Verdict (it. 1) | Findings |
| --- | --- | --- |
| design | PASS | P1: drop `set -uo pipefail`-as-convention framing; ~30 sibling tests use `-euo pipefail`. *Fixed* in §4 by acknowledging the dominant convention and justifying the `-uo` choice on its own merits (table-driven test wants all rows to run). P2: `bin/common-test.sh` filename matches the `<module>-test.sh` convention. P2: sentinel-pattern note correct (tests are leaves; sentinel is for sourceable helpers). P3: pre-source `PROJECT_SLUG`/`TARGET_REPO` ordering matches sibling tests. |
| security | PASS | No findings. No secrets, no `${VAR:-}` against secret-shaped envs, no command-injection vectors. Test fixtures are throwaway JSON in `mktemp -d`. |
| scope | PASS | D-003 (in-band comment): in-scope — issue lists `bin/common.sh` as a likely change, comment is the lightest defense. §10 Q1 (project-profile pin): correctly deferred to plan. §10 Q3/Q4 (cleanup, write tests): correctly deferred. No scope creep, no contraction. |
| coherence | **FAIL → fixed** | **P0**: §3 D-001 and §9.3 row 6 claimed `is_orchestrator_paused` has only two callers; `grep` shows five. *Fixed* in §3 D-001 (revised "Why not extend `run-stage-test.sh`" to use the correct five-caller fact), §3 D-004 (lists all five), and §9.3 row 6 (corrected claim with persona-source attribution). §5 jq behaviour for rows 4/5/6 verified correct. All other path:line citations spot-checked correct. |
| product | PASS | P3: §2 Goals could state the user-facing benefit upfront. *Fixed* in §2 with a one-paragraph user-outcome lead-in before the bulleted goals. Reframe (code fix already in HEAD via d420c64) verified correct against `git show`. |
| feasibility (gating) | **FAIL → fixed** | **P0** (same root as coherence's P0): caller list incomplete. *Fixed* alongside coherence in §3 D-001, §3 D-004, §9.3 row 6, §9.4 caller-row block. All other 14+ codebase-fact claims verified correct (function lines, jq expression text, commit `d420c64` existence and content, sibling test patterns, non-existence of `bin/common-test.sh`, project-profile test enumeration). Final P0 count after iteration 1: **0**. |

**Gate result after iteration 1: 4/6 PASS at iteration start; 6/6 PASS
after the single P0 (caller-list error) was fixed in this same iteration.
Feasibility P0 count = 0. Proceed to planning.**

The corrected facts are now load-bearing for any plan-stage refinement
(e.g., a future "write-side test" decision for `set_orchestrator_paused`
should consider that five scripts read the helper, so the contract has
five touch surfaces, not two).

## 9. Anti-bias checks

### 9.1 ADR stress test

There is no `docs/knowledge/decisions.md` in this repo (verified by
`find docs -name decisions*` returning nothing). The closest equivalent —
CLAUDE.md and `learned-rules/harness/project-profile.md` — is informational,
not load-bearing-formal. So there is no ADR for this work to stress.

The implicit "ADR" most relevant is ENG-23's "STATE_FILE > CONFIG > 'false'"
priority chain, documented in `bin/common.sh:122-125`. This brainstorm
**defends** that ADR rather than stressing it: ENG-44's bug is exactly that
the override priority was being silently broken. Closing the test-coverage
gap is in service of that ADR.

ENG-49's recent productionization brainstorm (`docs/brainstorms/2026-04-30-
eng-49-harness-productionization-design.md`, Gap #6) folded this fix into a
larger umbrella but left one row of the ENG-44 table covered. ENG-44 closes
the loop without re-litigating the umbrella decisions.

### 9.2 Simpler alternative

**Alternative A — Do nothing.** The code is fixed; ENG-49 added one test;
arguably that's enough for a one-direction regression.

**Why rejected.** The ENG-44 issue describes a six-row test table as the
deliverable. Skipping five rows ignores the customer's spec. Specifically,
row 6 (both layers absent → `false`) and rows 4-5 (state file present but
key absent → fall-through correctness) verify branch-coverage of the
function that no row ENG-49 added does. A single regression direction tested
is meaningfully weaker than full-table coverage.

**Alternative B — Skip the new file; add the missing five rows to
`bin/run-local-helpers-adversarial-test.sh`.**

**Why rejected.** That file is named for a different module
(`run-local-helpers.sh`); accreting unrelated tests there is the path that
ENG-49 already started, and it makes the next test reader hunt across
modules to find function-level coverage. (See D-001 rationale.)

**Alternative C — Add a static lint that bans `// empty` from
`is_orchestrator_paused` specifically.**

**Why rejected.** Out of scope per ENG-44 ("Auditing other `// empty`
usages in the harness for the same anti-pattern (worth a separate pass)").
A one-line in-band comment (D-003) is the lightest defense without
expanding scope.

### 9.3 Assumption inventory

| # | Assumption | Status | Evidence |
| - | --- | --- | --- |
| 1 | Bug is already fixed in `bin/common.sh` | verified | `bin/common.sh:129` quotes `if .orchestrator.paused != null then .orchestrator.paused else empty end`, not `// empty` |
| 2 | The fix is from ENG-49 | verified | `git show d420c64 -- bin/common.sh` shows the exact `// empty → if/else` diff with commit message "fix a pre-existing bug in is_orchestrator_paused where the jq expression '.orchestrator.paused // empty' treats false as falsy" |
| 3 | Only one row of ENG-44's table is covered today | verified | `bin/run-local-helpers-adversarial-test.sh:601-611` (`test_paused_override_honored`) covers row 2 only; `grep -n is_orchestrator_paused bin/*-test.sh` returns no other coverage |
| 4 | `is_orchestrator_paused` is at `bin/common.sh:126-136` | verified | direct file read |
| 5 | `set_orchestrator_paused` is at `bin/common.sh:138-149` | verified | direct file read |
| 6 | Call sites are `bin/poll.sh:376`, `bin/run-local.sh:91`, `bin/run-stage.sh:251`, `bin/reset-pipeline.sh:31`, `bin/dry-run.sh:73` | verified | `grep -n "is_orchestrator_paused" bin/*.sh` returns these five plus the definition at `bin/common.sh:126` and the export at `bin/common.sh:151`. **Earlier draft of this brainstorm claimed only two callers; that was a P0 codebase-fact error caught by the coherence and feasibility persona reviews and corrected here.** |
| 7 | Per-call `CONFIG=… STATE_FILE=… is_orchestrator_paused` works because the function reads them at call time | verified | `bin/common.sh:127,129,135` reference `$STATE_FILE` and `$CONFIG` at every call; no caching. Pattern in active use at `bin/run-local-helpers-adversarial-test.sh:607` |
| 8 | `common.sh` enforces `TARGET_REPO` exists before any helpers can be used | verified | `bin/common.sh:12` `[[ -d "$TARGET_REPO" ]] || …exit 1` |
| 9 | `PROJECT_SLUG` must be set before sourcing common.sh in tests | verified | `bin/common.sh:40-48` will `die` if config.json is absent and `PROJECT_SLUG` isn't pre-set; `bin/run-local-helpers-adversarial-test.sh:21` does this |
| 10 | Sibling tests use `set -uo pipefail` (no `-e`) | verified | `bin/run-local-helpers-adversarial-test.sh:18` |
| 11 | Test sentinel pattern is `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi` | verified | called out in CLAUDE.md "How tests work"; pattern present across `bin/*.sh`; for a test file (not a sourced helper), the sentinel is unnecessary because tests are always invoked directly |
| 12 | `failure_outcome_for_exit` and other common.sh helpers have no dedicated test file today | verified | `grep -l 'failure_outcome_for_exit' bin/*-test.sh` returns `classify-failure-test.sh` only — transitive coverage, no dedicated file. So `common-test.sh` is a green-field name |
| 13 | The project-profile's `Test:` line lists every required test file | verified | `learned-rules/harness/project-profile.md:17` enumerates them; `bin/common-test.sh` would need to be added there if we want it auto-pinned |
| 14 | ENG-49's static-check test for non-bypass is at `bin/run-local-helpers-adversarial-test.sh:616-622` | verified | direct file read |
| 15 | Adding `bash bin/common-test.sh` to the test enumeration is "in scope by adjacency, deferred to plan" | assumed | ENG-44's "Files likely to change" doesn't list `learned-rules/harness/project-profile.md`. The plan stage should make the call. Brainstorm flags this rather than deciding it |

### 9.4 Codebase-fact verification (every named symbol)

All file paths and line numbers are quoted from `HEAD` of branch
`feat/eng-44-is-orchestrator-paused-empty-swallows-paused-false-override`
at brainstorm time (commit `a871211` head):

| Reference | Verified? | Evidence |
| --- | --- | --- |
| `bin/common.sh` (file) | yes | direct read |
| `bin/common.sh:126-136` `is_orchestrator_paused()` | yes | direct read; signature and body match this brainstorm's quotes |
| `bin/common.sh:138-149` `set_orchestrator_paused()` | yes | direct read |
| `bin/common.sh:129` jq expression `if .orchestrator.paused != null then .orchestrator.paused else empty end` | yes | direct read |
| `bin/common.sh:135` fallback `jq -r '.orchestrator.paused // "false"' "$CONFIG"` | yes | direct read |
| `bin/common.sh:12` `[[ -d "$TARGET_REPO" ]]` guard | yes | direct read |
| `bin/common.sh:40-48` PROJECT_SLUG resolution | yes | direct read |
| `bin/common.sh:122-125` "Read priority: STATE_FILE > CONFIG > 'false'" comment | yes | direct read |
| `bin/poll.sh:376` `paused="$(is_orchestrator_paused)"` | yes | `grep -n` |
| `bin/run-local.sh:91` `paused="$(is_orchestrator_paused)"` | yes | `grep -n` |
| `bin/run-stage.sh:251` `paused="$(is_orchestrator_paused)"` | yes | `grep -n` (third caller, not in original draft) |
| `bin/reset-pipeline.sh:31` `if [[ "$(is_orchestrator_paused)" == "true" ]]` | yes | `grep -n` (fourth caller, not in original draft) |
| `bin/dry-run.sh:73` `bash -c '[[ "$(is_orchestrator_paused)" == "false" ]]'` | yes | `grep -n` (fifth caller, smoke test) |
| `bin/run-local-helpers-adversarial-test.sh:601-611` `test_paused_override_honored` | yes | direct read |
| `bin/run-local-helpers-adversarial-test.sh:616-622` `test_paused_callsites_use_helper` | yes | direct read |
| `bin/run-local-helpers-adversarial-test.sh:18` `set -uo pipefail` | yes | direct read |
| `bin/run-local-helpers-adversarial-test.sh:21` `PROJECT_SLUG=… export` before `source common.sh` | yes | direct read |
| `bin/run-local-helpers-adversarial-test.sh:607` per-call CONFIG/STATE_FILE override pattern | yes | direct read |
| commit `d420c64` ENG-49 fix | yes | `git show d420c64 --stat` |
| `bin/common-test.sh` (proposed new file) | does not exist yet | `ls bin/common-test.sh` returns no such file; this brainstorm proposes its creation |
| `learned-rules/harness/project-profile.md:17` test enumeration | yes | direct read |
| no `docs/knowledge/decisions.md` | yes | `find docs -name 'decisions*'` returns empty |
| no `docs/VISION.md` / `docs/ARCHITECTURE.md` | yes | `find docs -name 'VISION*' -o -name 'ARCHITECTURE*'` returns empty |

## 10. Open questions

1. **Pin in project-profile?** Should `bash bin/common-test.sh` be added to
   `learned-rules/harness/project-profile.md:17`'s `Test:` enumeration in
   the same PR, or deferred to a separate "test-aggregator update" pass?
   The brainstorm leans "same PR" because the test exists nowhere else; the
   plan stage should confirm.
2. **Comment wording.** The exact wording of the in-band comment at
   `bin/common.sh:129` is a plan-stage detail. Suggested form: `# Use
   explicit null check, not '// empty': false is jq-falsy and would silently
   eat a paused=false override. See ENG-44 / ENG-49.`
3. **Should we delete the existing one-row test in
   `run-local-helpers-adversarial-test.sh` once `common-test.sh` covers it?**
   No (per D-002), but a future "consolidate paused tests" cleanup pass
   could revisit. Not for ENG-44.
4. **Do `set_orchestrator_paused` correctness tests belong here too?** It's
   the write side of the same flag. ENG-44 doesn't ask for them, but the
   test file is going to exist. The plan stage should decide whether to
   include 1-2 paired write tests now or defer them. Brainstorm's
   recommendation: defer — keep ENG-44 narrow.

## 11. Conflicts and scope

- **No conflict with existing architecture.** This brainstorm is purely
  additive: one new test file, one new in-line comment, no behavior change.
- **No scope expansion.** Specifically excluded: the broader `// empty` audit;
  multi-key/layered override mechanism; `set_orchestrator_paused` write-side
  testing; lint infrastructure; touching `bin/poll.sh` or `bin/run-local.sh`.
- **Acknowledged scope-overlap with ENG-49.** ENG-49 fixed the code and added
  one test row. ENG-44 closes the remaining five rows, and accepts a
  one-row overlap (D-002). This is documented so the next reviewer doesn't
  flag the duplication as accidental.
