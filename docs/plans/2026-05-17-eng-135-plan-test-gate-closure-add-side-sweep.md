---
linear: ENG-135
date: 2026-05-17
topic: Plan Agent §2 test-gate closure sweep — add-side rule
---

# Plan — ENG-135 add-side test-gate closure sweep for §2

## Anti-anchoring check

- **Problem (operator-perspective):** "AGENT_PROMPTS.md §2 (Plan Agent) tells the feasibility persona to flag tests that reference REMOVED tokens, but says nothing about ADDED gate-runnable tests that imply a `learned-rules/<slug>/project-profile.md::## Build & test gates` update. ENG-122 (2026-05-15) hit this — three new `bin/*-test.sh` files landed in File Structure without `project-profile.md`, the post-merge minor #4 caught it, and the implement-loopback edit halted on scope-check because the profile file wasn't in scope."
- **Brainstorm framing:** the brainstorm (`docs/brainstorms/2026-05-17-eng-135-plan-test-gate-closure-add-side-sweep-design.md`) extends the existing §2 feasibility-persona "test-gate closure" sweep with one symmetric add-side paragraph. Same persona, same severity (P0 plan-completeness), same gate-glob resolution mechanism. One inserted paragraph in `AGENT_PROMPTS.md`, one grep-anchored assertion in `bin/agent-prompts-content-test.sh`. ENG-122 is the worked-example replay.
- **Proportionality:** one inserted paragraph in `AGENT_PROMPTS.md` (~10 lines, immediately after the existing remove-side paragraph at lines 561-572), one new §2-scoped assertion in `bin/agent-prompts-content-test.sh` (~5 lines). No new state, no new marker, no new schema, no new orchestrator-side check. Total production-text diff ≈ 10 added lines + 5 added test lines. Proportional. Proceed.

## Goal

`AGENT_PROMPTS.md` §2's feasibility-persona self-review sweep gains a symmetric **add-side** paragraph immediately after the existing remove-side paragraph (currently `AGENT_PROMPTS.md:561-572`). The new paragraph instructs the planner: for every file in File Structure being NEWLY CREATED under a gate-runnable glob (per the profile's `## Build & test gates` Test command), the project's `learned-rules/<slug>/project-profile.md` file MUST also appear in File Structure with a task updating the gate command. A missing profile entry is a P0 plan-completeness defect. Worked example mirrors the ENG-94 example already present, anchored on ENG-122. `bin/agent-prompts-content-test.sh` gains one new §2-scoped assertion pinning the literal phrase `NEWLY CREATED` paired with the literal path `learned-rules/<slug>/project-profile.md` as a single grep target (`grep -qF` on each).

## Assumption Inventory

Format: `[verified|assumed]` ITEM — `path:line` reference.

### Verified — code paths quoted from current tree

- `[verified]` `AGENT_PROMPTS.md:561-572` — remove-side `**test-gate closure** sweep` paragraph. The new add-side paragraph is inserted immediately after line 572 (the literal `pre-commit gate failure mid-stage.` line ending the remove-side block) and before line 573 (the `- **scope** —` next-persona bullet). Content anchor: literal string `had five assertions pinning that exact token, and the implement agent halted on the\n    pre-commit gate failure mid-stage.\n  - **scope** —` is unique in the file (the phrase `had five assertions pinning that exact token` is verified-unique via Grep, 2026-05-17).

- `[verified]` `bin/agent-prompts-content-test.sh:67` — `s2="$(section_body "## 2. Plan Agent")"` already extracts §2's body for assertions. The new assertion uses the same `s2` variable.

- `[verified]` `bin/agent-prompts-content-test.sh:250-308` — existing §2-scoped ENG-97 assertion cluster pattern (`grep -qF '<literal>'` against `$s2`). New §2 ENG-135 assertion follows the same pattern and inserts at the tail of the §2 cluster (immediately after the ENG-52 column-0 fence-count assertion at line ~398-401 OR within the ENG-97 cluster at line ~250-340 — implementer picks based on grouping cleanliness; both are syntactically equivalent).

- `[verified]` `bin/agent-prompts-content-test.sh` `ok` / `nope` helpers (lines 13-14) — the new assertion uses the same OK / FAIL emit pattern.

### Assumed — pinned by content anchor + verify-at-implement

- `[assumed]` Nothing on `origin/main` between plan time (`origin/main = b1eefa1`) and implement time changes the §2 remove-side paragraph (`AGENT_PROMPTS.md:561-572`) or the `s2` section-body extraction line (`bin/agent-prompts-content-test.sh:67`). Verify by re-grepping the content anchors at the start of implement; if any anchor is gone, rebase first.

## Edit-boundary keys (content anchors, not line numbers)

When the implementer runs `Edit`, the `old_string` MUST quote enough surrounding context that the substitution is unambiguous on a future-rebased tree. Two anchors:

1. **Add-side paragraph injection in §2.** `old_string` = the literal `    had five assertions pinning that exact token, and the implement agent halted on the\n    pre-commit gate failure mid-stage.\n  - **scope** —` substring (multi-line; spans the remove-side paragraph's last sentence + the next-persona bullet header). `new_string` = the same block with the new add-side paragraph inserted between `mid-stage.` and the `- **scope** —` line. The new paragraph follows the same 4-space indent as the remove-side body and uses the same bullet-less continuation shape (it's a continuation of the **feasibility** bullet's body, not a new bullet).

2. **New §2-scoped assertion in `bin/agent-prompts-content-test.sh`.** `old_string` = the literal `nope "§2 column-0 fence count is exactly 2 (api-contract example stays indented)" \\\n       "got $fence_count_s2 column-0 fences in §2 body — render-prompt.sh::extract_block requires exactly 2"\nfi` block (the trailing assertion in the §2 cluster — anchor verified via Grep). `new_string` appends one new `if printf … grep -qF … then ok … else nope … fi` assertion block immediately after the existing closing `fi`, before the next non-§2 assertion cluster.

## Failure Mode → Test Map

| # | Failure mode | Test |
|---|---|---|
| 1 | Add-side rule deleted from §2 | `bin/agent-prompts-content-test.sh` §2 ENG-135 assertion — `printf '%s\n' "$s2" \| grep -qF 'NEWLY CREATED'` |
| 2 | Add-side rule loses `project-profile.md` canonical pointer | Same assertion — `printf '%s\n' "$s2" \| grep -qF 'project-profile.md'` (paired AND check) |
| 3 | Add-side rule relocates out of §2 | Assertion runs on `$s2` only; relocation trips it |
| 4 | Remove-side rule regresses | Existing §2 ENG-97 / ENG-52 structure pins stay green |
| 5 | Pre-commit hook regression on any other test | `bash .githooks/pre-commit` stays green |

## File Structure (scope)

IN:
- `AGENT_PROMPTS.md` (single section, §2)
- `bin/agent-prompts-content-test.sh` (one new assertion; no new file)
- `docs/brainstorms/2026-05-17-eng-135-plan-test-gate-closure-add-side-sweep-design.md` (already committed at brainstorm stage)
- `docs/plans/2026-05-17-eng-135-plan-test-gate-closure-add-side-sweep.md` (this commit)
- `docs/plans/2026-05-17-eng-135-plan-test-gate-closure-add-side-sweep.json` (this commit)

OUT:
- Any other file in the repo.

Profile-update self-check: this plan does NOT add any new file matching `bin/*-test.sh` — only a new assertion inside an existing file. The profile's `## Build & test gates` Test command already covers `bin/agent-prompts-content-test.sh`. No profile edit required.

## Sequence

### Task 0: Verify content anchors against current tree
- `depends_on: []`
- `touches: AGENT_PROMPTS.md, bin/agent-prompts-content-test.sh`
- [ ] `grep -nF 'had five assertions pinning that exact token, and the implement agent halted on the' AGENT_PROMPTS.md` returns exactly 1 hit in §2 (lines ~570-571).
- [ ] `grep -nF 'fence_count_s2 column-0 fences in §2 body' bin/agent-prompts-content-test.sh` returns exactly 1 hit in the §2 cluster.
- [ ] If either anchor is gone, rebase the worktree on `origin/main` and re-verify before proceeding.

### Task 1: Insert add-side paragraph in §2
- `depends_on: [0]`
- `touches: AGENT_PROMPTS.md`
- [ ] Use `Edit` with `old_string` quoting the remove-side paragraph's last sentence + the `- **scope** —` next-bullet header (per Edit-boundary key #1).
- [ ] `new_string` inserts the add-side paragraph between `pre-commit gate failure mid-stage.` and the `- **scope** —` line. Indent matches the remove-side body (4 spaces), no new bullet (continuation of the **feasibility** bullet's body).
- [ ] Add-side paragraph contains both load-bearing literals: `NEWLY CREATED` (caps-emphasised, parallel to `REMOVES` in the remove-side rule) and `learned-rules/<slug>/project-profile.md` (canonical reference). Worked example references ENG-122.

### Task 2: Add §2-scoped assertion in `bin/agent-prompts-content-test.sh`
- `depends_on: [1]`
- `touches: bin/agent-prompts-content-test.sh`
- [ ] Use `Edit` with `old_string` quoting the existing trailing §2 assertion block per Edit-boundary key #2.
- [ ] `new_string` appends one new assertion block:
  ```bash
  # ─── ENG-135: §2 carries add-side test-gate closure sweep ───────────
  # Plan agent's feasibility persona must flag NEWLY CREATED gate-runnable
  # files (per the profile's "Build & test gates" glob) that imply a
  # learned-rules/<slug>/project-profile.md update. Pin both load-bearing
  # literals to catch deletion or canonical-pointer drift.
  if printf '%s\n' "$s2" | grep -qF 'NEWLY CREATED' && \
     printf '%s\n' "$s2" | grep -qF 'learned-rules/<slug>/project-profile.md'; then
    ok "§2 ENG-135: add-side test-gate closure sweep present (NEWLY CREATED + project-profile.md pointer)"
  else
    nope "§2 ENG-135: add-side test-gate closure sweep present (NEWLY CREATED + project-profile.md pointer)" \
      "literal phrase 'NEWLY CREATED' or path 'learned-rules/<slug>/project-profile.md' missing from §2 — has the add-side rule been deleted or relocated?"
  fi
  ```

### Task 3: Run gates
- `depends_on: [2]`
- `touches: (none — gates only)`
- [ ] `bash bin/agent-prompts-content-test.sh` — expect rc=0 with the new `OK: §2 ENG-135` line visible.
- [ ] `bash .githooks/pre-commit` (full sibling test suite) — expect exit 0.

### Task 4: Commit + push
- `depends_on: [3]`
- `touches: (worktree git state)`
- [ ] `git -c user.name=implement-bot -c user.email=implement-bot@harness.local commit` with message `feat(ENG-135): symmetric add-side test-gate closure sweep in §2`.
- [ ] `git push origin HEAD`.

## API Contract

no new API surface

## Test Strategy

Single-stage sibling test (`bin/agent-prompts-content-test.sh`). Two literal-substring assertions (`NEWLY CREATED` + `learned-rules/<slug>/project-profile.md`), both grep-anchored, both scoped to `$s2` (the §2 body extracted by `section_body`). The assertion AND-joins the two greps so deleting either literal trips the test. No new test file; profile gate-list stays unchanged.

QA's adversarial check (test-the-test): demote `NEWLY CREATED` to lowercase in §2, re-run the assertion, observe FAIL line, restore. Repeat with the path literal. Both should trip the same assertion with the same `nope` reason; if either passes after demotion, the AND-join is broken.

## Self-review (MANDATORY — to be done by the planner self-review block)

Per §2 self-review block — five personas (feasibility, scope, coherence, design, product). For this plan specifically:
- **feasibility** — content anchors verified (Task 0); test-gate closure (remove-side) check: this plan REMOVES no tokens. test-gate closure (add-side) check: this plan ADDS no `bin/*-test.sh` files (only an assertion in an existing file); profile-gate-list update not required.
- **scope** — both tasks trace to brainstorm AC#1 (add-side rule in §2) and AC#4 (new assertion). No gold-plating.
- **coherence** — Goal matches brainstorm Overview; one paragraph + one assertion realises the symmetric-extension goal end-to-end.
- **design** — no architectural surface touched; AGENT_PROMPTS.md is the canonical site for stage-prompt content; test-content invariants live in `bin/agent-prompts-content-test.sh`.
- **product** — issue body asks for add-side rule with explicit profile-file pointer and a sibling test; this plan delivers exactly that.

## Completion checklist (manual shepherd — for transparency)

1. [done] Brainstorm doc committed at 9ce1174.
2. [pending] Plan doc + plan.json committed (this commit).
3. [pending] Implement Task 1 + Task 2 + run gates.
4. [pending] Review verdict (post-commit on local HEAD SHA).
5. [pending] QA verdict (test-the-test adversarial).
6. [pending] Build (gh pr create + operator approval gate + merge).
7. [pending] Released (state→Done, label cleanup, worktree cleanup).
