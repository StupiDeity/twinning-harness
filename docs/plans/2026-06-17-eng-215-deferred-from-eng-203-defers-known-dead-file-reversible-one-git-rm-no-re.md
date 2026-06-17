---
linear: ENG-215
date: 2026-06-17
topic: Delete the known-dead scratch file `bin/probe-test.sh` (reversible single git rm)
---

# Plan — Delete the known-dead `bin/probe-test.sh` scratch file

## Goal

Delete `bin/probe-test.sh` from the repository (one `git rm`), so the worktree no longer carries the ENG-203 review-loopback scratch file the dispatch sandbox left behind, the `bin/*-test.sh` glob the pre-commit hook iterates loses one always-passing no-op entry, and the per-stage autotest allowlist `_dispatch_tools_autotests` derives shrinks by exactly one matching grant — with zero behaviour change for any documented dispatch.

## Anti-anchoring check

* **Problem restatement (user view).** "The harness carries an inert four-line scratch file `bin/probe-test.sh` that an ENG-203 review-loopback dispatch wrote during its run and could not delete (no `Bash(rm:*)` grant in the implementing stage's allowlist); the file's own header says `Should be deleted by next clean run; sandbox prevented rm during dispatch`. Nothing references it; it just sits in `bin/` and gets pointlessly executed (exit 0) by the pre-commit hook on every commit." The brainstorm-equivalent solution (one `git rm`) maps onto this exactly — no reframing.
* **Solution proportionality.** A one-file deletion is the right tier for a finding the ENG-203 deferred-majors rubric explicitly tagged `reversible_post_ship: yes`, `has_workaround: yes (file is silently inert)`, `user_visible: no`. No new test, no taxonomy work, no profile edit, no docs change, no companion edits in `bin/dispatch.sh` / `.githooks/pre-commit` / `learned-rules/harness/project-profile.md`. Proportional. (Same shape pattern as sibling ENG-213 / ENG-212 deferred-majors closes — one-file polish PRs.)
* **Escalation.** Not needed — both checks pass.

## Assumption Inventory

Every code-level claim below was verified by `Read`/`Grep` against the current worktree at plan-time `HEAD = bf59b25` on branch `feat/eng-215-deferred-from-eng-203-defers-known-dead-file-reversible-one-git-rm-no-re`.

**Branch-base freshness:** `HEAD..origin/main` empty at plan time (origin/main = `bf59b25`). The freshly-merged sibling deferred-from-ENG-203 tickets (ENG-212 at `2725796`, ENG-213 at `bf59b25`) landed first; this branch is current. No Task 0 rebase needed.

### Files this plan modifies (verified `path:line`)

* `bin/probe-test.sh:1-4` — the file slated for deletion. Verified by `Read`:
  ```bash
  #!/usr/bin/env bash
  # probe-test.sh — accidental scratch file from ENG-203 review-loopback dispatch.
  # Should be deleted by next clean run; sandbox prevented rm during dispatch.
  exit 0
  ```
  Four lines total. The file is a no-op: shebang + two comment lines + `exit 0`. The header comment is the authoritative provenance pointer (ENG-203 review-loopback dispatch, sandbox-rm-blocked).

### Files this plan does NOT modify (verified)

* `.githooks/pre-commit:159-185` — the pre-commit hook's gate loop. Iterates `bin/*-test.sh` via `for t in bin/*-test.sh; do`; tests are RUN unconditionally and then either gated (FAIL) or skipped (KNOWN_BROKEN). `bin/probe-test.sh` is NOT on the `KNOWN_BROKEN` array (verified at `.githooks/pre-commit:88-107` — array contains `mutex-test.sh, render-pr-body-test.sh, render-prompt-slug-test.sh, eng-81-reproducer-test.sh` only). So today `bin/probe-test.sh` runs as a green gate entry (`exit 0` from L4) and contributes 1 to `total_pass`. Post-delete, `total_pass` decreases by 1; `total_fail`/`total_skip` are unaffected; the gate's pass/fail decision (which keys off `total_fail`) is unchanged. **No edit required.**
* `bin/dispatch.sh::_dispatch_tools_autotests` — derives the per-stage allowlist by globbing `bin/*-test.sh` from the worktree at dispatch time (no hand-enumerated list). Verified by reading the ENG-196 block at `bin/dispatch-test.sh:2220-2295` — `auto_impl="$(_dispatch_tools_autotests implementing)"` is asserted to equal the disk enumeration `for f in bin/*-test.sh; do ... done`. Post-delete, both sides shrink by 1; the equality assertion holds; the test continues to pass. **No edit required.**
* `learned-rules/harness/project-profile.md::"## Build & test gates"` — the gate command line is `bash .githooks/pre-commit` (already a glob-iterating script). No hand-enumerated list of test files lives here; the gate auto-discovers via glob. No add-side test-gate-closure edit required (no new file is created). **No edit required.**
* `learned-rules/harness/project-profile.md::"## Tool allowlist"` — implementing/qa list `Bash(bash .githooks/pre-commit:*)` and `Bash(bash bin/secret-probe-lint.sh:*)` only; per-test entries are no longer enumerated here (ENG-196 retired them). **No edit required.**
* `CLAUDE.md` — references the `KNOWN_BROKEN` list contents at one bullet (`eng-81-reproducer, mutex, render-pr-body, render-prompt-slug`). `probe-test.sh` is not in that list and is not referenced anywhere else in `CLAUDE.md`. **No edit required.**
* `docs/runbooks/**` — `Grep probe-test docs/` returns zero hits. **No edit required.**
* `AGENT_PROMPTS.md` — `Grep probe-test AGENT_PROMPTS.md` returns zero hits. **No edit required.**

### Codebase reference check

* Full-tree grep: `Grep "probe-test"` across the worktree returns exactly one file — `bin/probe-test.sh` itself (line 2 of the file is the only match: the header comment string `probe-test.sh — accidental scratch file from ENG-203 review-loopback dispatch.`). Verified by `Grep` for files_with_matches: `Found 1 file: bin/probe-test.sh`. Conclusion: no other file in the worktree imports, sources, references, or names `bin/probe-test.sh`. Deletion is safe.
* Git history: `git log --all --oneline -- bin/probe-test.sh` returns one commit — `df32051 chore(pipeline): implementing for ENG-203`. The file was created during ENG-203's implementing dispatch and has been untouched since. (Verified by `git show df32051 --stat -- bin/probe-test.sh`.) This matches the file's own header-comment provenance claim exactly.
* `bin/*-test.sh` count at plan-time: 80 (verified by `ls bin/*-test.sh | wc -l`). Post-delete: 79.

### Assumed (validated at implementation time, not pre-flight)

* The implementing-stage scope-allowlist permits `git rm` of files under `bin/`. From project-profile's `## File layout`: `bin/` is the canonical script directory. `partition_dirty_paths` should classify the `D bin/probe-test.sh` diff as in-scope. Verify during implementation by running `bin/scope-check.sh` mentally / observing the orchestrator's tick-end sweep. (Note: agents do NOT have `Bash(rm:*)` or `Bash(git:rm:*)` allowed — the implement agent must use `git rm` via a workflow the orchestrator's scope-check already accepts for legitimate file deletions. This is the documented kind of edit that produces a `D` row in `git diff --cached`, which `partition_dirty_paths` does parse.)
* `bash .githooks/pre-commit` runs cleanly on the post-edit branch — `total_pass` drops by 1 (79 instead of 80 gated passes), no new failures, KNOWN_BROKEN behaviour unchanged. The gate's exit-1 decision keys off `total_fail`, which is unaffected.

## System invariants

- `_dispatch_tools_autotests` (`bin/dispatch.sh`) derives its per-stage allowlist by globbing `bin/*-test.sh` from the worktree, NOT from a hand-enumerated list; removing `bin/probe-test.sh` shrinks both the on-disk `bin/*-test.sh` set and the function's grant output by exactly one matched entry, leaving the equality between disk enumeration and grant enumeration intact. verified_by: bin/dispatch-test.sh:ENG-196

## File Structure

Deleted (one file, no other edits):

* `bin/probe-test.sh` — DELETED via `git rm`. Four-line inert scratch file (`exit 0`); unreferenced anywhere else in the worktree.

No new files. No modified files. No directory changes. No path or filename collisions.

## API Contract

No new API surface. The harness has no FE↔BE wire format, no HTTP routes, no protobuf. This is a pure file deletion with zero behaviour change for any dispatch.

## Backend Tasks

### Task 1: Delete `bin/probe-test.sh` via `git rm`

- `depends_on: []`
- `touches: bin/probe-test.sh` (deletion)

- [ ] From the worktree root, run `git rm bin/probe-test.sh`. **Content anchor for the deletion: the entire file at `bin/probe-test.sh` whose contents start with the literal `#!/usr/bin/env bash` shebang AND whose line 2 is the literal string `# probe-test.sh — accidental scratch file from ENG-203 review-loopback dispatch.`.** No line-number-only boundaries are used; the file is identified by its path AND by the verified content excerpt above.
- [ ] Confirm the staged diff shows exactly one row: `D bin/probe-test.sh` (a single file deletion, no modifications, no renames). Run `git diff --cached --name-status` to confirm.
- [ ] Do NOT touch `.githooks/pre-commit` (the `bin/*-test.sh` glob auto-picks up the new on-disk set).
- [ ] Do NOT touch `bin/dispatch.sh` (the `_dispatch_tools_autotests` glob auto-picks up the new on-disk set).
- [ ] Do NOT touch `learned-rules/harness/project-profile.md` (the gate command is glob-based; no hand-list to update).
- [ ] Do NOT add a new file (no regression-pin test, no docs note — the file's own header comment is its tombstone, removed with it; the ENG-196 invariant test in `bin/dispatch-test.sh` continues to pin the glob-discovery behaviour).
- [ ] Do NOT touch any other `bin/*-test.sh` file (the deletion is one row).

### Task 2: Verify the pre-commit gate runs clean post-deletion

- `depends_on: [1]`
- `touches: (none — verification only)`

- [ ] Run `bash .githooks/pre-commit` from the worktree root. Confirm:
  - The header line prints `running bin/*-test.sh (79 tests)` (down from 80).
  - `total_pass` decreases by exactly 1 from the pre-delete baseline (the previously-passing `bin/probe-test.sh` is gone).
  - `total_fail = 0` (gate decision is green).
  - `total_skip` matches the KNOWN_BROKEN array size (4: `mutex, render-pr-body, render-prompt-slug, eng-81-reproducer`), unchanged from pre-delete.
  - Final exit code is 0.
- [ ] Run `bash bin/dispatch-test.sh` standalone. Confirm:
  - The ENG-196 block at L2233-2295 still passes. In particular, `ENG-196: _dispatch_tools_autotests grants all 79 bin/*-test.sh on disk` (count down from 80, equality with on-disk set intact).
  - No other test in the file regresses.
- [ ] Run `bash bin/secret-probe-lint.sh`. Confirm clean — this edit has no secret-handling concerns (pure file removal, no env-var changes).

## Frontend Tasks

No frontend exists for this project (harness is bash orchestration only — no UI). All work is in Backend Tasks above.

## Failure Mode → Test Map

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
|---|---|---|---|---|
| `_dispatch_tools_autotests` and on-disk glob diverge after deletion (one side drops, the other doesn't) | Future refactor of `_dispatch_tools_autotests` to a hand-enumerated source | The existing ENG-196 AC1 assertion `ENG-196: _dispatch_tools_autotests grants all N bin/*-test.sh on disk` fails the gate | unit | `bin/dispatch-test.sh::ENG-196: _dispatch_tools_autotests grants all ${disk_count} bin/*-test.sh on disk` |
| Pre-commit hook fails because remaining test file references the deleted scratch file | Some other `bin/*-test.sh` (or other gate-runnable script) named `probe-test.sh` as input | Pre-commit gate fails at commit time; root cause grep'able to the dangling reference | smoke | `bash .githooks/pre-commit` (Task 2) — no specific test name; the gate IS the smoke |
| `git rm` failure (file not tracked, worktree dirty, etc.) | `git rm` rc != 0 | Implement agent's pre-commit sweep refuses to commit; orchestrator scope-check halts cleanly with the agent's surfaced error | smoke | (Task 1's `git diff --cached --name-status` check; no specific test name) |
| Deleted file regenerated by another sandbox-rm-blocked dispatch in the future (CLASS-LEVEL hazard, not regression of THIS deletion) | A future agent dispatch writes a scratch file under `bin/` and is killed mid-run with no rm grant | Out of scope for this ticket. Sibling work in `bin/run-local-helpers.sh::clean_self_leak_residue` (ENG-100) and `clean_scratch_residue` (CLAUDE.md "Sweep + scope partition") already cover the class-level cleanup for `implementing | ui | qa` and `.scratch/` respectively; a leaked top-level `bin/*-test.sh` from a docs-only stage is the residual hazard, addressed (for non-`implementing|ui|qa` stages) by `stage_auto_cleans_self_leak` (`bin/run-local-helpers.sh`) per CLAUDE.md "Sweep + scope partition". | n/a | (out of scope) |

## Test Strategy

* **Unit (new).** None. The change is a single-file deletion with zero behaviour change for any documented dispatch; no new positive assertion is needed and no symmetric regression class exists for this specific scratch file. The existing ENG-196 invariant in `bin/dispatch-test.sh` (L2233-2295) keeps the on-disk-vs-grant equality intact across the deletion — that test passed at 80 tests today and will continue to pass at 79 tests post-delete.
* **Unit (existing — confirmed unchanged).** `bin/dispatch-test.sh::ENG-196 AC1` (disk-vs-grant equality, AC3 newly-added file auto-grant, stage-gating, empty-worktree soft behaviour) — all four sub-assertions continue to pass without edits. Every other `bin/*-test.sh` in the suite continues to pass without edits (no test names or imports `probe-test`).
* **Integration.** No integration test needed — the file is a static no-op with no callers, no sourcers, no `read`ers. End-to-end dispatch flow on `implementing`/`qa` exercises `_dispatch_tools_autotests` indirectly through `allowed_tools_for` on every dispatch.
* **Smoke.** `bash .githooks/pre-commit` (Task 2) is the suite-wide smoke. `bash bin/dispatch-test.sh` standalone (Task 2) re-runs the ENG-196 block as a focused smoke on the glob-discovery invariant.
* **Adversarial coverage.** The only adversarial vector is "scratch file silently regenerates because a future dispatch leaks one." This is a class-level hazard that ENG-215's narrow scope does NOT defend against (and the brainstorm's deferred-majors rubric `reversible_post_ship: yes` accepts the residual risk). Class-level defences live in `clean_self_leak_residue` and `clean_scratch_residue` (CLAUDE.md "Sweep + scope partition") and are out of scope. If a sibling scratch file ever appears under `bin/*-test.sh` again, it would surface as a +1 line in `git status` AND as a +1 entry in `_dispatch_tools_autotests`'s output AND in the ENG-196 `auto_impl` size, with PR review catching the new file via diff.
* **No new test file.** Skipping the regression-pin is the load-bearing proportionality call. The brainstorm-equivalent description framed the work as "one git rm, no regression" — adding a pin to assert "`bin/probe-test.sh` does not exist" would defend against an extremely narrow re-introduction class (the exact same scratch file's name and content from the same ENG-203 dispatch), without defending against the broader class (any other leaked scratch). YAGNI per CLAUDE.md "Don't add features beyond what the task requires."
* **Test-gate closure (remove-side, completed).** The only token being removed is the file `bin/probe-test.sh` itself. `Grep` across the worktree for `probe-test` returns exactly one hit (the file's own header comment at L2). No sibling test in the project pins this token; no inverting assertion is required in any other test file.
* **Test-gate closure (add-side, completed).** No new file is created. No new file under a gate-runnable glob means no edit to `learned-rules/harness/project-profile.md::"## Build & test gates"` is required (and the harness's gate is glob-based regardless, per ENG-196 — even a hypothetical new test file wouldn't require a profile edit).

## Self-review

Per the plan-stage prompt, the self-review section folds in the five-persona review (feasibility, scope, coherence, design, product). For ENG-215, no formal brainstorm exists (the ticket was auto-created by ENG-191's deferred-majors loop and filed directly to `Backlog`); this self-review carries the persona work in full.

* **Feasibility (codebase-fact verification).** Every `path:line` in Assumption Inventory was verified via `Read`/`Grep` against current code:
  - `bin/probe-test.sh:1-4` — file contents read in full.
  - `.githooks/pre-commit:88-107` — `KNOWN_BROKEN` array read; `probe-test.sh` confirmed absent.
  - `.githooks/pre-commit:159-185` — gate loop read; `for t in bin/*-test.sh; do` confirmed as the iteration shape.
  - `bin/dispatch-test.sh:2220-2295` — ENG-196 block read; disk-vs-grant equality assertion confirmed.
  - `Grep probe-test` worktree-wide returned exactly one file (the file itself). `git log --all --oneline -- bin/probe-test.sh` returned exactly one commit. PASS.
- **Test-gate closure remove-side sweep (feasibility):** the deleted file `bin/probe-test.sh` is the only thing being removed. The only sibling token is its own header comment, removed with it. No sibling test asserts this token. PASS — zero defects.
- **Test-gate closure add-side sweep (feasibility):** no new files created. PASS — vacuously clean.
- **System invariants resolution sweep (feasibility):** one bullet. Token `bin/dispatch-test.sh:ENG-196` resolves to the ENG-196 block at `bin/dispatch-test.sh:2233` (header line `printf '\n--- ENG-196: auto-derived test-runner allowlist ---\n'`) which contains the named `ENG-196: _dispatch_tools_autotests grants all ${disk_count} bin/*-test.sh on disk` pass label at L2246 of that file. PASS — token resolves.
* **Scope.** Both task entries trace to a single goal (the one-file deletion + the gate-verification follow-up). Task 1 deletes the file; Task 2 verifies the gate. No task strays outside the declared File Structure (one deletion, no modifications). The "Files this plan does NOT modify" list explicitly enumerates the four candidate files (`.githooks/pre-commit`, `bin/dispatch.sh`, `learned-rules/harness/project-profile.md`, `CLAUDE.md`) and justifies the no-touch per surface. PASS.
* **Coherence.** Plan Goal matches the ticket's "one git rm, no regression" framing. Backend Tasks 1+2 jointly realise the goal: delete the file, verify the suite still passes. The Failure Mode → Test Map binds the one realistic failure mode (autotest-grant divergence from disk) to the existing ENG-196 test, and the class-level "scratch file regenerated" hazard is explicitly marked out of scope with a forward pointer to the sibling sweep mechanisms. PASS.
* **Design.** No module boundaries are crossed (one file under `bin/`). No layering violation. No circular dep introduced. No new abstractions. The change respects the harness's "no application code; just orchestration scripts" architecture by removing an inert scratch file that doesn't belong in either category. PASS.
* **Product.** Plan delivers exactly what the Linear ticket asked for: a one-line `git rm`. No expansion to taxonomy work, regression pins, or class-level defences (all of which would be disproportionate per the deferred-majors rubric tags `reversible_post_ship: yes` and `has_workaround: yes (file is silently inert)`). The ticket framed the work as a polish PR; the plan is a polish PR. PASS.

5/5 PASS, zero P0 findings. Proceeding to implementing.
