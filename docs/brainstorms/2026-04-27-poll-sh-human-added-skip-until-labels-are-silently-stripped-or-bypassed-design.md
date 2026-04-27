---
linear: ENG-24
title: poll.sh respects human-added skip-until-* labels
date: 2026-04-27
status: draft
---

# poll.sh respects human-added `pipeline:skip-until-*` labels

## 1. Overview

`bin/poll.sh` has two independent bugs that cause human-added
`pipeline:skip-until-human-acts` and `pipeline:skip-until-code-changes`
labels to be silently bypassed. Both stem from the same flawed assumption
encoded in the script — that these labels are *only ever* applied by the
pipeline (`classify-failure.sh`), paired with a per-issue state file at
`$PROJECT_STATE_DIR/<issue>/issue-state.json`. Humans apply these labels
manually (per the contract documented in `bin/setup-labels.sh:38`), and the
poller does not respect them.

Bug A is in **Pass 5 (inbox pickup)** at `bin/poll.sh:432-439`: the jq
filter excludes `pipeline:paused` and `pipeline:abandoned` but not the two
skip-until labels. A `Todo` issue carrying only `pipeline:skip-until-human-acts`
passes the filter and is dispatched into `stage:brainstorming`.

Bug B is in `_poll_evaluate_skip` at `bin/poll.sh:64-69`: when an issue
carries a skip label but has no state file, the function logs `orphan skip
label … clearing`, removes the label via `linear.sh remove-label`, and
returns 0 (include). This silently undoes a human pause on any
stage-labeled issue.

The fix is two narrow patches plus two new test cases. There is no new
architecture and no new ADR — this is a straightforward contract bug.

### Goal

A human-applied `pipeline:skip-until-*` label reliably blocks the
pipeline from acting on the issue until the human removes the label.
True regardless of:
- whether the issue is in `Todo` (Pass 5 inbox pickup) or in a `stage:*`
  label (Pass 1–4 stage dispatch);
- whether `$PROJECT_STATE_DIR/<issue>/issue-state.json` exists.

### Non-goals

- Changing when the pipeline itself applies these labels
  (`classify-failure.sh:101-107` flow).
- The orphan-STATE-file cleanup path at `bin/poll.sh:55-60`
  (state file without label) — that branch is correct.
- `skip-until-code-changes` evidence-recompute semantics at
  `bin/poll.sh:76-114` — that branch is correct when a state file
  exists.
- Refactoring unrelated parts of `poll.sh`.

## 2. Decisions

### D-1: Add both `skip-until-*` labels to the Pass 5 inbox-pickup exclusion filter

**Decision.** Extend the jq filter at `bin/poll.sh:432-439` to drop any
candidate that carries `pipeline:skip-until-human-acts` or
`pipeline:skip-until-code-changes`, modelled exactly on the existing
`pipeline:paused` exclusion.

```diff
-       | select([.labels.nodes[].name] | index("pipeline:paused") | not)
-       | select([.labels.nodes[].name] | index("pipeline:abandoned") | not)
+       | select([.labels.nodes[].name] | index("pipeline:paused") | not)
+       | select([.labels.nodes[].name] | index("pipeline:abandoned") | not)
+       | select([.labels.nodes[].name] | index("pipeline:skip-until-human-acts") | not)
+       | select([.labels.nodes[].name] | index("pipeline:skip-until-code-changes") | not)
```

**Rationale.** Each of the four labels in this filter expresses
"orchestrator must not pick this up". Three of them already do; the
remaining two leak through. The fix is the simplest possible local
change — add two filter clauses parallel to the existing two — and
matches the working-by-design behavior of `pipeline:paused`
(Technical Hint in the Linear issue).

**Rejected alternative — gate inbox pickup through a richer
`_poll_evaluate_skip` call.** Could refactor Pass 5 to evaluate every
inbox candidate through `_poll_evaluate_skip` (so the same logic applies
to inbox and stage dispatch). Rejected because (a) inbox candidates have
no state file by definition (they have not yet been picked up), so the
"orphan-label" branch in `_poll_evaluate_skip` would fire on every inbox
candidate and the function would mostly degrade into the same simple
"drop if labeled" check we are adding; (b) it expands the scope beyond
what the bug requires; (c) `pipeline:paused` is already handled by the
narrow filter and is the precedent.

**Constraint.** Per CLAUDE.md "Linear conventions": *Mutate labels
additively. Use `bash bin/linear.sh add-label`/`remove-label`. Never
overwrite the entire label set.* The fix only adds two `select(...)`
clauses to a read-side filter; no Linear writes.

### D-2: In `_poll_evaluate_skip`, "skip label without state file" returns skip and does NOT strip the label

**Decision.** Replace the orphan-label branch at `bin/poll.sh:64-69`
with a branch that returns 1 (skip) and performs no Linear writes,
applied uniformly to both `skip-until-human-acts` and
`skip-until-code-changes`.

Conceptual diff:

```bash
# Label without file → human-applied. Respect the label.
if [[ ! -f "$state_file" ]]; then
  log "poll: $ident has skip label without state file (human-applied); skipping"
  return 1
fi
```

**Rationale (human-acts).** The contract published in
`bin/setup-labels.sh:38` reads:
> Pipeline: issue skipped until a human resolves the underlying issue
> (scope violation, guards, etc.) and removes this label.

The current code violates that contract: the orchestrator strips the
label on the very next tick after a human applies it. The minimal,
faithful fix is to honor the label exactly the way the contract reads —
the only thing that clears it is a human `remove-label` call.

**Rationale (code-changes).** Without a state file there is no prior
evidence (`pipeline_content_hash` and `branch_head_sha`) to diff against.
The conservative default is to continue skipping until either (a) a
human removes the label, or (b) `classify-failure.sh:101-107` next runs
and writes a fresh state file from which a future evidence diff can
fire. The Linear issue's "Desired Outcome" §3 explicitly endorses this
treatment.

**Why uniformity is correct, not a regression.** The pre-fix asymmetry
(code-changes had a "real" cleanup path; human-acts also got stripped
under the same branch) was not load-bearing. In every case where the
state file is absent:
- pipeline-applied path: the state file write in `classify-failure.sh`
  has either not happened yet (race window of one tick) or has been
  manually deleted. In both cases conservative-skip is the right
  default — the next `classify-failure.sh` run, or a human, will
  resolve.
- human-applied path: the absence of a state file is the *expected*
  steady state.

**Rejected alternative — keep the orphan-cleanup behavior but exempt
`skip-until-human-acts`.** Could special-case only Bug B's exact
symptom: leave `skip-until-code-changes` orphan-cleanup as-is, only
change `skip-until-human-acts`. Rejected because (a) it preserves
asymmetry that is not justified by the contract — `setup-labels.sh:37`
says skip-until-code-changes auto-resumes on hash/SHA change, and
without a state file there is no hash to compare to, so "auto-resume"
is undefined; (b) leaves a smaller version of the same bug standing for
the code-changes label; (c) the Linear issue's "IN" scope §2 explicitly
prefers uniform treatment.

**Rejected alternative — write an "auto-seeded" state file when a human
applies the label.** Could detect "label present, no state file" and
synthesize an `issue-state.json` from current `(content_hash,
branch_head_sha)` so the standard auto-resume can later fire. Rejected
because (a) this is feature work, not a bug fix — out of scope per the
Linear issue's "OUT" boundaries; (b) it gives "auto-resume" a behavior
that the contract in `setup-labels.sh:37,38` does not promise for
human-applied labels; (c) the simpler "human removes the label" exit
already covers the use case.

**Constraint — Linear write reduction.** Today the orphan branch
issues 1–2 `linear.sh remove-label` calls per labeled issue per tick on
the way to dispatching it. After the fix, those calls disappear.
Slightly less Linear API churn; no behavior dependent on those calls.

### D-3: Tests live in `bin/poll-slot-test.sh`, not a new test file

**Decision.** Append two new test cases to `bin/poll-slot-test.sh`
(numbered AC-8 and AC-9), reusing the existing `write_label_fixture`,
`write_inbox_fixture`, and `LINEAR_STUB_LOG` machinery.

**Rationale.** The CLAUDE.md "How tests work" section is the source of
truth for this repo's test pattern: `*-test.sh` siblings to the script
under test, sourced with `PIPELINE_DRY_RUN=1`, fixtures via `STUB_DIR`.
`poll-slot-test.sh` already covers all of `poll.sh`'s slot/dispatch
behavior including AC-6 / AC-7 (skip-until-code-changes auto-resume),
which exercise the same `_poll_evaluate_skip` function we are
modifying. Adding cases there keeps the regression surface in one
place.

**Rejected alternative — new file `bin/poll-skip-label-test.sh`.**
Rejected because the test setup (fixture writers, stub harness, config
JSON) is non-trivial and already correct in `poll-slot-test.sh`;
duplicating it is gratuitous.

**Constraint — sentinel pattern.** Per CLAUDE.md "Tests": each
`bin/foo.sh` ends with `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
main "$@"; fi` so the test can `source` it. `poll.sh:452-454` already
matches this; no change required.

## 3. Architecture (where code goes)

| Change | File | Lines (current) | Action |
|---|---|---|---|
| Pass 5 inbox-pickup filter | `bin/poll.sh` | 432–439 | Add 2 jq `select(...)` clauses |
| `_poll_evaluate_skip` orphan-label branch | `bin/poll.sh` | 64–69 | Replace 6 lines with 4 (return 1, no Linear writes) |
| New test AC-8 (Bug A) | `bin/poll-slot-test.sh` | append at EOF before `# Summary` | ~25 lines |
| New test AC-9 (Bug B) | `bin/poll-slot-test.sh` | append at EOF before `# Summary` | ~30 lines |

No new files. No changes outside these two. No `AGENT_PROMPTS.md`
edits, no `learned-rules/**` writes, no `config.json` schema changes,
no `setup-labels.sh` changes (the documented contract is already
correct — the code is the thing that contradicts it).

## 4. Data flow

### Pass 5 (inbox pickup, fixed)

```
Linear: list-issues-in-state(Todo)
   ↓
[.data.issues.nodes[]
 | drop if any startswith("stage:")
 | drop if "pipeline:paused"
 | drop if "pipeline:abandoned"
 | drop if "pipeline:skip-until-human-acts"     ← NEW
 | drop if "pipeline:skip-until-code-changes"   ← NEW
 | shape into {identifier, priority_sort_rank}]
   ↓
sort by priority desc; take .[0].identifier
   ↓
nonempty → emit dispatch JSON; empty → idle "no-work"
```

### Stage dispatch (Passes 1–4) with the new `_poll_evaluate_skip` orphan branch (fixed)

For an issue gathered by `_poll_gather_stage_labeled_issues`:

```
labels = [...]
state_file = $PROJECT_STATE_DIR/<issue>/issue-state.json

if no skip labels:
    if state_file exists: log "orphan state file"; rm -f state_file
    return 0  # include

if skip label present AND state_file missing:           ← FIXED BRANCH
    log "human-applied skip; skipping"
    return 1                                            # vacate, no Linear writes

if skip-until-human-acts:
    return 1                                            # vacate

# skip-until-code-changes with state_file: existing evidence-diff logic unchanged
prev_hash = state_file.evidence.pipeline_content_hash
prev_sha  = state_file.evidence.branch_head_sha
current_hash = compute_pipeline_content_hash
current_sha  = git ls-remote origin <branch>
if (prev_hash != current_hash) or (prev_sha != current_sha):
    rm -f state_file
    remove-label skip-until-code-changes
    if pipeline:halted: post pipeline-decision: resume; remove-label pipeline:halted
    emit refreshed labels_json
    return 0
return 1
```

Then in `_poll_classify_labels` (`bin/poll.sh:186-232`), a return-1
maps to `slot:"vacate", advanceable:false`, which Pass 4 skips and
Pass 5 (now also filtering) will not pick up either.

## 5. Error handling

The fix removes two `linear.sh remove-label` calls (the orphan-branch
removals) — i.e., it removes a Linear API write rather than adding one.
There are no new failure modes.

| Failure mode | Pre-fix behavior | Post-fix behavior |
|---|---|---|
| Human applies `pipeline:skip-until-human-acts` to a `Todo` issue | Inbox pickup; issue dispatched into `stage:brainstorming` (Bug A) | Inbox skips it; issue stays Todo |
| Human applies `pipeline:skip-until-human-acts` to a `stage:planning` issue | Orphan-cleanup strips the label; issue dispatched into planning (Bug B) | Slot vacated; label preserved; issue not dispatched |
| Human applies `pipeline:skip-until-code-changes` to a stage-labeled issue with no state file | Orphan-cleanup strips the label; issue dispatched | Slot vacated; label preserved; issue not dispatched until human removes the label OR `classify-failure.sh` next writes a state file (then the existing evidence-diff path takes over) |
| Pipeline applies `pipeline:skip-until-*` via `classify-failure.sh:101-107` | Writes state file + label in the same call | Unchanged. Fix only affects the read path in `poll.sh`. |
| `linear.sh remove-label` was previously failing on these calls | Silent `|| true`; counter-effective | Calls eliminated; no degradation possible |

## 6. Edge cases

1. **Both skip labels present at once.** `classify-failure.sh:102,106`
   already enforces mutual exclusion (each `add-label` is preceded by
   the opposite `remove-label`), but a human could in theory apply
   both. The fixed orphan branch returns 1 on the first detected
   skip-label. The inbox filter drops on either match. Either label
   alone is sufficient; both is not a meaningful state. No special-
   casing required.

2. **Skip label applied between Linear `list-issues-in-state` and
   classification.** Today the Pass 1 gathered issues snapshot is read
   once per tick. If a human applies a skip label *after* the snapshot
   is taken, the next tick (~5 min) honors the label. This is the
   already-accepted single-tick race window (same property as
   `pipeline:paused`). Not changed by this fix.

3. **Skip label removed by human between two calls in
   `_poll_classify_labels`.** All `_has_label` checks read the in-memory
   `labels_json` snapshot (`bin/poll.sh:200-202`); a Linear-side
   mutation mid-tick has no effect until next tick. No race introduced.

4. **State file present AND skip label absent.** Existing branch at
   `bin/poll.sh:55-60` (`orphan state file` cleanup) is unchanged. The
   Linear issue's "OUT" boundaries call this out explicitly.

5. **`skip-until-code-changes` with state file but humans want to
   force-resume.** Already covered: human removes the label; the next
   tick sees `has_code_label=false`, falls into the `no skip labels`
   branch, cleans up the orphan state file, returns 0. Behavior
   unchanged.

6. **Race: pipeline writes state file mid-tick after a human applied
   the label.** Possible only when the pipeline is mid-flight on the
   same issue the human is pausing. The state-file write happens during
   `classify-failure.sh` (post-stage), so the issue is mid-`stage:*`
   dispatch when the label is applied. After the fix, the next poll
   tick: state file exists → `has_human_label=true` → skip-until-human
   branch (`bin/poll.sh:71-74`) returns 1. Human pause respected. No
   regression.

7. **Pipeline-applied skip-until-human-acts after the human had
   already applied it.** `classify-failure.sh:107` calls `add-label`
   which is idempotent on Linear's side; the label stays. The state
   file gets written. Subsequent ticks take the existing
   `has_human_label=true → return 1` branch. Behavior unchanged.

## 7. Open questions

- **Should the orphan branch log differ between human-acts and
  code-changes?** Decision: one shared log line keyed on `$ident`. The
  branch is identical for both labels and the differentiation does not
  aid debugging — the labels are visible in Linear.
- **Should we add a `pipeline-decision` marker comment when honoring a
  human-applied skip label?** Decision: no. Human-applied labels are
  themselves the audit trail. Per ENG-18 verdict-marker protocol, only
  the orchestrator's own state transitions need markers.
- **Should `setup-labels.sh:37,38` description for
  `skip-until-code-changes` be updated to clarify the no-state-file
  case?** Decision: defer. The label description already says
  "auto-resumes when ... content hash OR HEAD changes, OR when the
  label is removed" — the "label removed" branch covers the no-
  state-file case adequately. Out of scope for this bug fix.

## 8. Anti-bias checks

### 8.1 ADR stress test

This repo has no `docs/knowledge/decisions.md` (verified at §9.1
below). The closest equivalents are CLAUDE.md and AGENT_PROMPTS.md. The
fix puts no pressure on either:
- CLAUDE.md "Linear conventions" — *Mutate labels additively* — the
  fix removes two `linear.sh remove-label` calls (more conservative,
  not less).
- CLAUDE.md "When wiring a new script" — only relevant to new files;
  this is two-line edits in two existing files.
- ENG-18 verdict-marker protocol — orthogonal. Skip labels are a
  separate axis from verdict markers; this fix does not write or read
  verdict markers.
- ENG-20 held-slots orchestrator — Pass 5 was untouched by ENG-20 (per
  the Linear issue "Related Context"). The Pass 1–4 stage path's
  classification was reworked but the `_poll_evaluate_skip` orphan
  branch was preserved unchanged from pre-ENG-20; it is original to the
  policy-routed skip-state ENG (see `_poll_evaluate_skip`
  introduction in the file). The fix does not pressure ENG-20.

No accepted decision is challenged. No new ADR is proposed.

### 8.2 Simpler alternatives

Documented inline at each decision (D-1 alt: refactor inbox through
`_poll_evaluate_skip`; D-2 alt 1: special-case only `human-acts`; D-2
alt 2: auto-seed state file; D-3 alt: separate test file). Each
rejected alternative has an explicit reason.

### 8.3 Assumption inventory

All marked **verified** are quoted with `path:line` references against
the code on this worktree, per Rule B-001 in `learned-rules/twinning/brainstorm.md`.

| # | Assumption | Status | Evidence |
|---|---|---|---|
| 1 | `_poll_evaluate_skip` is the single decision point for skip-label handling. | verified | `bin/poll.sh:45-116`. Called once per gathered issue from `_poll_classify_labels` at `bin/poll.sh:190`. |
| 2 | The orphan-label branch is at `bin/poll.sh:64-69` and calls `linear.sh remove-label` for each present skip label. | verified | `bin/poll.sh:64-69` matches the issue's quoted snippet exactly. |
| 3 | The Pass 5 inbox-pickup filter is the jq filter that excludes `pipeline:paused` and `pipeline:abandoned` and is the only inbox-side filter. | verified | `bin/poll.sh:432-439`. Lines do not match the issue's reference (issue says 316-325) but the structural shape — `select([.labels.nodes[].name] | startswith("stage:") not)` followed by `index("pipeline:paused") not` and `index("pipeline:abandoned") not` — matches verbatim. The issue was filed against an earlier line layout; the bug is in the same filter. |
| 4 | `pipeline:skip-until-human-acts` is documented as "skipped until a human resolves… and removes this label." | verified | `bin/setup-labels.sh:38`. |
| 5 | `pipeline:skip-until-code-changes` is documented as auto-resuming on hash/SHA change OR label removal. | verified | `bin/setup-labels.sh:37` says "skipped until .pipeline/{bin,config.json,AGENT_PROMPTS.md} content hash or branch HEAD SHA changes." `classify-failure.sh:128-129` shows the comment body that says "auto-resumes when …" and includes the "OR when `pipeline:skip-until-code-changes` label is removed" wording. |
| 6 | `classify-failure.sh:101-107` is the pipeline-side application of these labels. | verified | `bin/classify-failure.sh:101` `skip-until-code-changes)` then `bin/classify-failure.sh:102-103` add/remove pair; `bin/classify-failure.sh:105-107` mirror for `skip-until-human-acts`. |
| 7 | `issue_dir` resolves `$PROJECT_STATE_DIR/<issue>` and is the canonical state-file location. | verified | `bin/common.sh:61-65`. Used in `bin/poll.sh:47` (`state_file="$(issue_dir "$ident")/issue-state.json"`). |
| 8 | `bin/poll-slot-test.sh` has the test scaffolding for `_poll_evaluate_skip`-style cases (AC-6, AC-7) and the `LINEAR_STUB_LOG` capture pattern. | verified | `bin/poll-slot-test.sh:62-87` (linear.sh stub with optional `LINEAR_STUB_LOG`); `bin/poll-slot-test.sh:367-446` (AC-6 and AC-7). |
| 9 | The `linear.sh` stub appends `<subcommand> <args...>` to `LINEAR_STUB_LOG` for write subcommands. | verified | `bin/poll-slot-test.sh:77-82` (`remove-label\|add-label\|swap-stage\|... [[ -n "${LINEAR_STUB_LOG:-}" ]] && printf '%s\n' "$*" >> "$LINEAR_STUB_LOG"`). |
| 10 | `write_inbox_fixture` writes to `state-Todo.json` keyed by `config.linear.native_states.inbox`. | verified | `bin/poll-slot-test.sh:185-206`. |
| 11 | Test fixtures use a tempdir for `PROJECT_STATE_DIR`; new tests can omit the state-file seed by simply not creating `$PROJECT_STATE_DIR/<issue>/issue-state.json`. | verified | `bin/poll-slot-test.sh:50-54` sets up tempdir; AC-6 and AC-7 explicitly `mkdir -p "$PROJECT_STATE_DIR/ENG-7001"` and write the state file. Omitting that step is sufficient to reproduce the no-state-file case. |
| 12 | The sentinel `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi` is at the bottom of `poll.sh`. | verified | `bin/poll.sh:452-454`. |
| 13 | `_poll_classify_labels` interprets a non-zero return from `_poll_evaluate_skip` as `slot:"vacate", advanceable:false` (the human-acts current branch). | verified | `bin/poll.sh:190-193`. The `if ! refreshed_labels="$(_poll_evaluate_skip ...)"` branch emits `{slot:"vacate",advanceable:false,labels:$l}`. |
| 14 | Pass 4 (`bin/poll.sh:387-420`) skips advanceable=false items and Pass 5 (`bin/poll.sh:427-447`) is gated by `held_count >= max_concurrent`. So a stage-labeled issue with `slot:vacate` is not dispatched, and is not picked from the inbox path either (because the inbox path looks for `Todo` issues, not stage-labeled ones). | verified | `bin/poll.sh:397-399` (advanceable check); `bin/poll.sh:423-425` (cap check); `bin/poll.sh:430-431` (inbox query is `list-issues-in-state Todo`). |
| 15 | This repo has no `docs/knowledge/decisions.md` or `docs/architecture/` or `docs/VISION.md`. The brainstorm prompt was a generic template; the harness's design source-of-truth is `CLAUDE.md` + `AGENT_PROMPTS.md`. | verified | `ls docs/` returns only `brainstorms` and `plans`. Existing `docs/brainstorms/2026-04-26-multi-project-harness.md` does not reference VISION.md or ADRs either. |

No item below is "assumed" — every code-level fact is grounded in the
current worktree.

### 8.4 Codebase-fact verification (Rule B-001)

Per `learned-rules/twinning/brainstorm.md` Rule B-001, every named code
artifact is grounded:

- `_poll_evaluate_skip` — `bin/poll.sh:45`.
- `_poll_classify_labels` — `bin/poll.sh:186`.
- `_poll_gather_stage_labeled_issues` — `bin/poll.sh:125`.
- `issue_dir` — `bin/common.sh:61`.
- `compute_pipeline_content_hash` — referenced from `bin/poll.sh:81`,
  defined in `bin/common.sh` (export at `bin/common.sh:148`:
  `export -f issue_dir compute_pipeline_content_hash …`).
- `find_fresh_verdict` — `bin/verdict-handler.sh` (sourced at
  `bin/poll.sh:23`); called at `bin/poll.sh:212`.
- `linear.sh remove-label`, `linear.sh add-label`, `linear.sh
  add-comment`, `linear.sh list-issues-with-label`, `linear.sh
  list-issues-in-state` — used in `bin/poll.sh:66-67, 91, 105-106,
  134, 430`.
- Labels — `pipeline:halted`, `pipeline:abandoned`, `pipeline:paused`,
  `pipeline:scope-approval-needed`, `pipeline:skip-until-code-changes`,
  `pipeline:skip-until-human-acts` — `bin/setup-labels.sh:28-38`.
- `classify-failure.sh` skip-label application — `bin/classify-failure.sh:101-107`.
- Test scaffolding — `write_label_fixture`, `write_inbox_fixture`,
  `write_comments_fixture`, `LINEAR_STUB_LOG`, `STUB_DIR`,
  `PROJECT_STATE_DIR`, `CONFIG`, `git()` override —
  `bin/poll-slot-test.sh:62-141, 159-222`.

No method, label, or path in this brainstorm is unverified.

## 9. Implementation plan (sketch — to be expanded by the plan stage)

This section sketches what the plan stage will turn into ordered
sub-tasks. The plan agent will own ordering and granularity.

1. Edit `bin/poll.sh` Pass 5 inbox jq filter (D-1).
2. Edit `bin/poll.sh` `_poll_evaluate_skip` orphan-label branch (D-2).
3. Append AC-8 (Bug A regression) to `bin/poll-slot-test.sh`:
   single Todo issue with only `pipeline:skip-until-human-acts`,
   no state file. Asserts `main` returns `issue_id: null` (idle).
4. Append AC-9 (Bug B regression) to `bin/poll-slot-test.sh`:
   single `stage:planning` issue with `pipeline:skip-until-human-acts`
   and no state file. Asserts (a) `main` does not dispatch this issue;
   (b) `LINEAR_STUB_LOG` contains no `remove-label ENG-XXXX
   pipeline:skip-until-human-acts` line.
5. AC-10 (required, not optional): same shape as AC-9 but with
   `pipeline:skip-until-code-changes` instead. D-2's rationale rests on
   "uniform treatment is correct, not a regression"; the test that
   proves uniformity must therefore be a requirement, not optional.
6. Run `bash bin/poll-slot-test.sh` locally and verify all of
   AC-1..AC-7 still pass plus AC-8..AC-10. The Linear issue's "AC-5
   Regression" requirement (existing orphan-state-file cleanup path —
   state file without label — still works) is satisfied by the
   unchanged §4 branch at `bin/poll.sh:55-60`; adding a dedicated
   `poll-slot-test.sh` case for it is OUT of scope and is intentionally
   deferred.
7. Hand off to plan stage / implementation.

## 10. Persona review

Document-review run 2026-04-27. Six personas, executed in the prescribed
order (design → security → scope → coherence → product → feasibility).
Feasibility runs last because it is the gating persona.

| # | Persona | Verdict | Findings |
|---|---|---|---|
| 1 | Design (operator/decision-point + edge cases + observability + AI-slop) | PASS · P0 = 0 | UI-only axes N/A (backend bash). Decision-point coverage 9/10 (§4 traces every branch pre/post). Edge-case enumeration 9/10 (§6 covers seven cases including races). AI-slop 10/10. P1: §5 should explicitly state that no operator-visible signal is lost when the two `remove-label` calls disappear (none — confirmed; AC-9 asserts their absence in `LINEAR_STUB_LOG`). P2: §9 step 6 ambiguity (resolved by edit removing the "small smoke test" instruction); §8.3 assumption #3 stale-line caveat could be surfaced earlier. |
| 2 | Security | PASS · P0/P1/P2 = 0 | Fix repairs the kill-switch contract correctly. Net Linear-write surface shrinks (1–2 fewer `remove-label` calls per orphan-labeled issue per tick). No new attack surface. Single-tick race window is the same property `pipeline:paused` already has — accepted, not introduced. AuthN/AuthZ/XSS/CSRF/SQLi/PII/secrets all explicitly N/A for harness bash. Highest-impact subtle case (AC-9 author seeds a state file by mistake, defeating the regression) is mitigated by §9's explicit "omit `mkdir -p`" instruction. |
| 3 | Scope | PASS · P0/P1 = 0 | Two file edits, ~10 lines net diff, two/three test cases. 1:1 map to Linear IN scope. All four OUT items called out as non-goals. Four rejected alternatives in §2 (D-1 alt; two D-2 alts; D-3 alt) turn down the over-engineered options. P2 (resolved by edit): §9 step 6 had an "add a small smoke test for the orphan-state-file path" instruction that risked OUT-scope creep; now dropped/deferred. P2 (resolved): AC-10 was "optional"; now required. |
| 4 | Coherence | PASS · P0 = 0 | No contradictions. Terminology used uniformly ("orphan label" / "label without state file" used interchangeably with the term defined inline). Uniformity-of-treatment claim consistent across §1, §2 D-2, §4 data flow, §5 error handling, §6 edge cases, §8.3 assumptions, §9 ACs. Forward references all grounded in §8.4. |
| 5 | Product | PASS · P0/P1 = 0 | Right problem (operator kill-switch contract is contradicted by code; ENG-23 prep surfaced it). Direct, single-hop fix at the two contradicting sites — no proxy work, no rollout machinery. Goal-requirement alignment 1:1 (Bug A → D-1, Bug B → D-2, regression → D-3). P2: do-nothing pain qualitatively asserted, not quantified — acceptable for a two-line fix; flagged only for completeness. P2 (resolved): AC-10 promoted to required. |
| 6 | Feasibility (gating) | PASS · P0 = 0 | Every named code artifact verified against the current worktree on this branch: `bin/poll.sh:45-116` (`_poll_evaluate_skip`), `bin/poll.sh:64-69` (orphan-label branch — matches issue snippet exactly), `bin/poll.sh:186-232` (`_poll_classify_labels`), `bin/poll.sh:432-439` (Pass 5 inbox jq filter — issue cited 316-325 but the structure is identical; documented in §8.3 #3), `bin/poll.sh:452-454` (sentinel), `bin/common.sh:61-65` (`issue_dir`), `bin/setup-labels.sh:38` (label contract), `bin/classify-failure.sh:101-107` (pipeline-side label apply), `bin/poll-slot-test.sh:62-87, 185-206` (test scaffolding for `LINEAR_STUB_LOG` and `write_inbox_fixture`). No P0/P1/P2 findings. |

Result: **6/6 PASS · gate P0 = 0**. Proceeding to planning.
