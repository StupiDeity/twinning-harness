---
linear: ENG-135
title: Plan §2 test-gate closure sweep — extend to add-side (newly created gate-runnable files imply project-profile gate-line update)
date: 2026-05-17
status: draft
---

# ENG-135 — Plan test-gate closure sweep: add-side rule

## 1. Overview

`AGENT_PROMPTS.md` §2 (Plan Agent) carries a feasibility-persona
"test-gate closure" sweep that runs in self-review. The current rule
(`AGENT_PROMPTS.md:560-572`) is one-directional — it covers the
**remove-side**:

> for every token, symbol, or substring this plan REMOVES from
> production code (e.g., a dropped allowlist entry, a renamed function,
> a deleted enum variant, a changed default), grep the project's
> sibling test files … ANY sibling test file that contains the
> soon-to-be-removed token AND is not listed in File Structure is a P0
> plan-completeness defect — either add the file to File Structure with
> a task inverting the assertion, or document explicitly … why the test
> should keep passing unchanged. This catches the ENG-94 class of
> error: the plan removed `Bash(cargo:*)` from `dispatch.sh` but missed
> that `bin/profile-allowlist-test.sh` had five assertions pinning that
> exact token, and the implement agent halted on the pre-commit gate
> failure mid-stage.

There is NO symmetric **add-side** rule. When a plan ADDS new
gate-runnable files (e.g., `bin/plan-schema-test.sh`,
`bin/plan-schema-adversarial-test.sh`), the project profile's gate-list
line (`learned-rules/<slug>/project-profile.md::## Build & test gates`)
is implicitly stale — it doesn't enumerate the new files, so future
agent dispatches don't run them as part of the gate command they read
from the prompt addendum. The pre-commit hook (`.githooks/pre-commit`,
which globs `bin/*-test.sh`) is a host-side safety net that runs at
commit time only — it doesn't repair the prompt-side gate list the
implement and qa agents will see on the next dispatch.

ENG-122 (2026-05-15) is the observed instance: the plan listed three
new test scripts in File Structure but never named
`learned-rules/harness/project-profile.md` as a file requiring an
update. The post-merge review's minor finding #4 caught it, triggering
an implement-loopback edit that tripped scope-check because the profile
file wasn't in the plan's File Structure. A symmetric closure sweep at
plan time would have caught this in the feasibility persona's
self-review and added the profile file to File Structure with a task
explicitly updating the gate command.

The defect is structural, not stylistic: the existing sweep only models
"removed test exists with no plan disposition," not "added test exists
with no profile-gate update." Both are forms of plan-test-gate drift —
the rule should be bidirectional.

## 2. Goal

After ENG-135 lands:

- **AC#1.** §2's feasibility-persona sweep contains both the existing
  remove-side rule AND a new symmetric add-side rule covering newly
  added gate-runnable files implying a `project-profile.md::## Build &
  test gates` update.
- **AC#2.** The new add-side rule names
  `learned-rules/<slug>/project-profile.md::## Build & test gates`
  explicitly so the agent can locate the file and section without
  ambiguity. It states that a missing profile entry in File Structure
  is a P0 plan-completeness defect (same severity as the remove-side).
- **AC#3.** The feasibility persona's self-review is documented as the
  enforcement site (same site as the remove-side; the rule is one more
  bullet in the existing self-review sweep — not a new persona, not a
  new orchestrator-side check, not a detective post-dispatch validator).
- **AC#4.** `bin/agent-prompts-content-test.sh` gains a grep-anchored
  assertion that §2's body contains the add-side closure language. The
  existing fence-count and structure-pin assertions stay green.
- **AC#5.** Pre-commit (`.githooks/pre-commit`, full `bin/*-test.sh`
  suite) stays green.

A hand-traced replay of ENG-122's plan, after this change, would have
flagged: "you are adding `bin/plan-schema-test.sh` and
`bin/plan-schema-adversarial-test.sh` but
`learned-rules/harness/project-profile.md` is not in File Structure —
P0 defect, add it."

## 3. Design

### 3.1 Where to inject the add-side rule

The remove-side rule sits inside the **feasibility** persona bullet of
the self-review block (`AGENT_PROMPTS.md:558-572`). The natural
insertion site is immediately after the remove-side paragraph, framed
as a symmetric continuation: same persona, same severity, same
"gate-runnable file" glob resolution (the profile's `## Build & test
gates` Test command). No new persona, no new orchestrator-side check.

### 3.2 Rule text shape

The add-side rule mirrors the remove-side rule's structure so the
agent reads them as one bidirectional sweep:

> Then run the **add-side** half of the same closure sweep: for every
> file in File Structure being NEWLY CREATED under a gate-runnable
> glob (per the profile's "Build & test gates" Test command — e.g.,
> `bin/*-test.sh` for the harness target, `tests/` for most stacks),
> the project's `learned-rules/<slug>/project-profile.md` file MUST
> also appear in File Structure with a task explicitly updating the
> relevant gate command line under the `## Build & test gates` section
> to include the new file. If the profile file is absent from File
> Structure, this is a P0 plan-completeness defect — add it. This
> catches the ENG-122 class of error: the plan added
> `bin/plan-schema-test.sh` + `bin/plan-schema-adversarial-test.sh` to
> File Structure but never named `learned-rules/harness/project-profile.md`,
> so the agent-side gate list silently drifted from the on-disk test set.

Three load-bearing pieces of literal text the new test will pin:

- The phrase `add-side` (paired with the existing `remove-side`/
  `REMOVES` framing — one bidirectional sweep).
- The path `learned-rules/<slug>/project-profile.md` (canonical
  reference, mirrors the existing AGENT_PROMPTS.md section-pointer
  shape).
- The phrase `NEWLY CREATED` (caps-emphasised, parallel to `REMOVES`
  in the remove-side rule).

### 3.3 What NOT to change

Per the issue body's Scope Boundaries:

- No detective-mode post-plan validator (a follow-up if needed).
- No changes to `bin/render-prompt.sh::append_project_profile` — the
  profile is already appended; we're only changing what §2 instructs
  the planner to flag.
- No changes to `bin/scope-check.sh` to make profile edits non-self-leak.
  That would defeat the scope guarantee — the goal is to add the
  profile to File Structure at plan time, so the implement-stage edit
  is in-scope by construction.
- No edits to §3 (Implementation Agent) or §5 (Review Agent). Those
  are tracked separately (ENG-133 already landed for §5;
  ENG-136 is the §3 minor-chasing ticket).

### 3.4 Worked example — ENG-122 replay

ENG-122's plan added these to File Structure:
- `bin/plan-schema-test.sh` (new)
- `bin/plan-schema-adversarial-test.sh` (new)
- `bin/plan-stage-emits-plan-json-test.sh` (new)

Each matches the harness profile's `bin/*-test.sh` Test-command glob.
The profile's `## Build & test gates` Test line lists each
`bin/*-test.sh` explicitly so dispatch.sh and the prompt-appended
addendum carry the up-to-date set. Under the add-side rule, the
feasibility persona would have observed:

> Three newly created files match the gate-runnable glob
> `bin/*-test.sh`. The profile file
> `learned-rules/harness/project-profile.md` is NOT in File Structure.
> P0 defect — add it with a task updating the `## Build & test gates`
> Test line to include the three new files.

The plan would then have added the profile to File Structure, and the
implement-stage edit to `learned-rules/harness/project-profile.md`
would have been in-scope by construction — no post-merge minor-finding
loopback, no scope-check halt.

## 4. Scope

IN:
- `AGENT_PROMPTS.md` §2 — one inserted paragraph (the add-side rule)
  immediately after the existing remove-side sweep paragraph.
- `bin/agent-prompts-content-test.sh` — one new grep-anchored
  assertion in the §2 block.
- `docs/brainstorms/2026-05-17-eng-135-...md` (this doc).
- `docs/plans/2026-05-17-eng-135-...md` + `.json` (next stage).

OUT:
- Detective-mode post-dispatch validator (follow-up if needed).
- `bin/render-prompt.sh::append_project_profile` — unchanged.
- `bin/scope-check.sh` — unchanged.
- §3 / §5 of AGENT_PROMPTS.md — separate tickets.
- Any other file in the repo.

## 5. Edge cases & risks

- **False positives.** A plan might add a file matching `bin/*-test.sh`
  that is intentionally NOT in the gate command (e.g., a manual repro
  script named with a `-test.sh` suffix). Mitigation: the rule
  delegates the gate-glob resolution to "per the profile's Build &
  test gates Test command" — operators authoring such files can
  document the exception in the plan's Test Strategy section, same
  escape hatch the remove-side rule provides ("document explicitly
  why the test should keep passing unchanged").
- **Stack neutrality.** The rule uses the same gate-glob resolution
  mechanism as the existing remove-side rule (profile's `## Build &
  test gates` Test command), so it works for non-harness stacks
  (Rust/Cargo, Python/pytest, Node/jest) without further changes.
- **Test brittleness.** The new grep assertion will fire if a future
  edit rewords the add-side rule. Mitigation: pin a short distinctive
  substring (`NEWLY CREATED` + `project-profile.md`) that's
  semantically load-bearing — wording around it can change without
  tripping the assertion.

## 6. Failure mode → test map

| # | Failure mode | Test |
|---|---|---|
| 1 | Add-side rule deleted entirely from §2 | New `bin/agent-prompts-content-test.sh` §2 ENG-135 assertion — `grep -qF 'NEWLY CREATED'` against §2 body |
| 2 | Add-side rule rewords away the `project-profile.md` pointer (loses canonical reference) | Same assertion pins `project-profile.md` as a second literal |
| 3 | Add-side rule moves out of §2 (e.g., gets promoted to §0 or §3) | Assertion runs on §2 body only — relocation trips it |
| 4 | Remove-side rule regresses (existing) | Existing §2 structure pins stay green (fence count, ENG-94 reference) |
| 5 | Pre-commit hook regression | `bash .githooks/pre-commit` stays green |

## 7. Open questions

None. The issue body specifies the rule text shape and severity; the
worked-example replay against ENG-122 is unambiguous.

## 8. Related issues / context

- ENG-94 — precedent for the remove-side rule.
- ENG-122 — observed add-side defect that triggered this ticket.
- ENG-133 — companion §5 (Review Agent) mechanical-verdict fix
  (already landed 2026-05-17).
- ENG-136 — companion §3 minor-chasing discipline (separate).
