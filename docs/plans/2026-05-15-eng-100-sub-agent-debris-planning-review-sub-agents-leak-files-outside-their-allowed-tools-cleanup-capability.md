---
linear: ENG-100
date: 2026-05-15
topic: route brainstorm/plan self-leak through clean_self_leak_residue so sub-agent debris stops halting clean stage outputs
---

# Plan — ENG-100: Sub-agent debris cleanup for brainstorming/planning stages

## 1. Goal

Brainstorming and planning dispatches that emit a clean stage output but leave a sub-agent's
scratch file at the worktree root complete WITHOUT `halt_issue_for_self_leak` firing — the
legitimate doc auto-commits and pushes, and the debris is wiped with a metric event for
forensic audit. No new agent-callable delete pattern; no change to `implementing | ui | qa`
halt semantics.

The Linear issue names "planning/review sub-agents." `reviewing` was already routed through
`clean_self_leak_residue` pre-ENG-100 (it is read-mostly). This plan extends the auto-clean
lane to `brainstorming` alongside `planning` because both stages share the same shape under
operator decision 2026-05-10 (no `Bash(rm:*)` for docs-only stages — brainstorm D-002).

## 2. Assumption Inventory

`branch-base freshness: HEAD..origin/main NON-EMPTY at plan time (origin/main = 06aa03b5d8cfa1b1a6ea160743a4078a9c72db66; two upstream commits — #101 fix dispatch.sh trailing gtime cleanup set -e safe + merge commit). Touches bin/dispatch.sh + bin/dispatch-test.sh + CLAUDE.md + README.md. Plan adds a Task 0 rebase below; the upstream changes are in adjacent files but DO touch dispatch.sh (where this plan's stretch detective lands). Rebase rather than supersede — the upstream change adds a 5-line if-block at dispatch.sh:617-622 (per upstream diff) and a new G8.B test assertion; neither conflicts with this plan's D-005 detective which lands after _render_and_capture_stream returns (current dispatch.sh:147+ region). Rebase risk is low; content anchors below survive the rebase by construction.`

### Verified path:line citations (current worktree, pre-rebase)

| # | Claim | Evidence |
|---|---|---|
| A-1 | `halt_issue_for_self_leak` defined and emits a 27-coded `classify_failure` skip-until-human-acts halt; reason string carries sha12 hashes only (adversarial-filename discipline). | `bin/run-local-helpers.sh:128-154` (function body); signature `halt_issue_for_self_leak() { local issue="$1" stage="$2"; shift 2; ...; classify_failure ... 27 }` |
| A-2 | `stage_is_read_mostly` defined; derives the predicate from `stage_output_paths` returning empty. Returns 0 for `reviewing | building | released`; returns 1 for every other stage including `brainstorming | planning`. UNKNOWN stages → 1 (conservative). | `bin/run-local-helpers.sh:176-180`: `stage_is_read_mostly() { local out; out="$(stage_output_paths "$1" 2>/dev/null)" || return 1; [[ -z "$out" ]]; }` |
| A-3 | `clean_self_leak_residue` defined; per-path strategy: tracked-modified → `git checkout -- "$p"`; untracked → `rm -rf -- "$worktree/$p"`. Defensive guards (empty/missing-worktree/main-or-master/dry-run). Emits `sweep-readonly-residue-cleaned` metric with `count branch hashes rm_fail checkout_fail`. | `bin/run-local-helpers.sh:215-272` (function body); metric emit at `bin/run-local-helpers.sh:269-271`; main/master refuse at `bin/run-local-helpers.sh:233-238` |
| A-4 | `partition_dirty_paths` emits FD3 (in-scope) / FD4 (leaked-in-scope) / FD5 (out-of-scope); D-004 issue-id token check applied only to `brainstorming | planning`; `.scratch/*` carve-out applied only to `implementing | ui | qa`. | `bin/run-local-helpers.sh:535-624` (function body); D-004 token check `bin/run-local-helpers.sh:543, 600-619`; `.scratch/*` carve-out at `bin/run-local-helpers.sh:583-587` |
| A-5 | Observed-vs-self-leak split in `_run_worker`: paths in `out_scope_file` that exist verbatim in tick-start `snapshot_file` go to `observed_buckets[]` via `bucket_for_path`; others go to `self_leak_paths[]` + `self_leak_hashes[]`. | `bin/run-local.sh:239-258`; snapshot creation at `bin/run-local.sh:184-189`; `grep -qxF -- "$p" "$snapshot_file"` at `bin/run-local.sh:245` |
| A-6 | The self-leak cleanup vs halt gate lives at `bin/run-local.sh:263`, exact form `if stage_is_read_mostly "$stage"; then`. The else-branch calls `halt_issue_for_self_leak` and `return 1` on non-dry-run. The auto-clean branch calls `clean_self_leak_residue "$issue_id" "$stage" "$dispatch_cwd" "${self_leak_paths[@]}"` (positional). | `bin/run-local.sh:262-273` |
| A-7 | `clean_scratch_dir "$dispatch_cwd"` is called at `bin/run-local.sh:202`, BEFORE `route_run_stage_exit` at `bin/run-local.sh:207` and BEFORE the rc-gate at `bin/run-local.sh:211`. Wire-up anchor #6 (`bin/run-local-helpers-adversarial-test.sh:2794-2830`) pins this ordering. The new D-001 cleanup path runs much later (after partition, line 263 region), so anchor #6 is unaffected. | `bin/run-local.sh:202`, `bin/run-local.sh:207`, `bin/run-local.sh:211` |
| A-8 | Wire-up anchor #3 (`bin/run-local-helpers-adversarial-test.sh:2775-2782`) pins the EXACT regex `if[[:space:]]+stage_is_read_mostly[[:space:]]+"\$stage";` in `run-local.sh`. **TEST-GATE CLOSURE: this assertion REGRESSES when run-local.sh switches to `stage_auto_cleans_self_leak` — the assertion MUST be updated in lock-step or the pre-commit hook fails.** | `bin/run-local-helpers-adversarial-test.sh:2775-2782` |
| A-9 | Wire-up anchor #4 (`bin/run-local-helpers-adversarial-test.sh:2783-2793`) pins the EXACT regex `clean_self_leak_residue[[:space:]]+"\$issue_id"[[:space:]]+"\$stage"[[:space:]]+"\$dispatch_cwd"[[:space:]]+"\$\{self_leak_paths\[@\]\}"` in `run-local.sh`. Unaffected by this change (the invocation shape stays identical; only the predicate name changes). | `bin/run-local-helpers-adversarial-test.sh:2783-2793` |
| A-10 | `test_read_mostly_predicate` (`bin/run-local-helpers-adversarial-test.sh:2285-2308`) asserts `stage_is_read_mostly` returns true for `reviewing|building|released` and false for `brainstorming|planning|implementing|ui|qa|retrospective`. This test STAYS GREEN — `stage_is_read_mostly` is preserved as the canonical predicate over `stage_output_paths`. | `bin/run-local-helpers-adversarial-test.sh:2285-2308` |
| A-11 | `test_self_leak_handler_pipeline_e2e` (`bin/run-local-helpers-adversarial-test.sh:2651-2741`) exercises the observed-vs-self-leak split → `stage_is_read_mostly reviewing` gate → `clean_self_leak_residue` invocation. The test STAYS GREEN for `reviewing` because the new predicate `stage_auto_cleans_self_leak` is a superset of `stage_is_read_mostly`; the integration test calls `stage_is_read_mostly` directly (not the new predicate) and that function does not change. New sibling tests for planning/brainstorming join this fixture (see Task 5). | `bin/run-local-helpers-adversarial-test.sh:2651-2741` |
| A-12 | `assert_no_tool_invocation` is the existing primitive in `bin/common.sh:178-195`. It scans the transcript for `tool_use.name == "Bash"` events whose `input.command` startswith a pattern. Shape-incompatible with `Write` tool checks (which need `tool_use.name == "Write"` and `input.file_path` matching). A sibling helper is needed for the D-005 detective. ASSUMED/NEW — symbol `assert_no_write_outside_allowlist` does not exist; verified empty via `grep -n "assert_no_write_outside_allowlist" bin/`. | `bin/common.sh:178-195`; new symbol confirmed absent |
| A-13 | `bin/dispatch.sh::_render_and_capture_stream` persists a transcript sidecar to `${issue_dir}/.envelope-transcript-${stage}` (`bin/dispatch.sh:54, 142-144`) AFTER its stream is consumed. The same function carries ENG-43 (implement-stage `gh pr create`), ENG-66 (branch-creation), ENG-68 (`core.bare`), ENG-71 (build-stage forbidden git ops) detective scans at `bin/dispatch.sh:146-235`. The D-005 detective stage-gate fits inline alongside these patterns. | `bin/dispatch.sh:47-236` |
| A-14 | `brainstorming` base allowlist (`bin/dispatch.sh:395`) and `planning` base allowlist (`bin/dispatch.sh:396`) carry no `Bash(rm:*)` / `Bash(git rm:*)` / any delete pattern. Verified verbatim. | `bin/dispatch.sh:395-396` |
| A-15 | `AGENT_PROMPTS.md §0` is the canonical single-source for cross-stage rules at `AGENT_PROMPTS.md:212-228`. Body opens with column-0 ``` fence at line 220 and closes at line 228. Existing rules: Secret-handling (ENG-46) line 221; Tool allowlist & probing (ENG-53 #11 / ENG-57) line 223 (carries the existing scratch-file rule for Linear helpers); Dispatch identifier and freshness contract (ENG-87) line 225; Stage summary file overwrite contract (ENG-77/ENG-71) line 227. | `AGENT_PROMPTS.md:212-228` |
| A-16 | `bin/agent-prompts-content-test.sh` uses `rendered_stage_body` (`bin/agent-prompts-content-test.sh:36-40`) to assert that §0-prepended content reaches every per-stage rendered body. Existing pin shapes use `grep -qF` (`bin/agent-prompts-content-test.sh:58-65`) for §0 phrases and `grep -qE` for regex matches. Iter-7 token-coverage check (`bin/agent-prompts-content-test.sh:1215+`) requires every `{token}` to be declared in `PROMPT_RESOLVERS`. The new rule contains no new `{token}` (it cites stages by literal name and uses `agent-blocked` as a literal verdict reason), so no resolver registration is required. | `bin/agent-prompts-content-test.sh:36-40, 58-65, 1215+` |
| A-17 | `bin/run-local-sweep-test.sh::assert_partition` (lines 13-44) is the canonical helper for partition assertions: NUL-delimited stdin → expected (in, leaked, observed) counts. Existing fixtures cover D-004 hit/miss, case-insensitive, path-boundary, embedded space, rename records, word-boundary. | `bin/run-local-sweep-test.sh:13-44` |
| A-18 | `_path_has_linear_frontmatter` honored at `bin/run-local-helpers.sh:609` admits a basename-mismatch path into FD3 when the doc's YAML frontmatter declares the issue. Unchanged by this plan; flagged here because the new fixture's debris path `awk-test-input.txt` does not carry frontmatter and so falls to FD5 (out-of-scope) as expected. | `bin/run-local-helpers.sh:609` |
| A-19 | `clean_self_leak_residue`'s log line at `bin/run-local-helpers.sh:253` reads `auto-clean: stage=$stage is read-mostly; cleaning ${count} self-leak path(s) on $branch; hashes=${hash_csv}`. After this change the "is read-mostly" substring becomes inaccurate for brainstorm/plan dispatches (design persona's P2 in iter-1 of the brainstorm). Updated in Task 2. | `bin/run-local-helpers.sh:253` |
| A-20 | `sweep-readonly-residue-cleaned` metric name has no downstream consumer outside `bin/run-local-helpers.sh:269-271` (emit), `bin/run-local-helpers-adversarial-test.sh:2508, 2540, 2729, 2734` (test pins), and CLAUDE.md description (`(check sweep-readonly-residue-cleaned metric)`) — no retrospective §1 filter branch, no `bin/status.sh` red/yellow predicate. Confirmed by `grep -rn` over `bin/ learned-rules/ docs/` outside the brainstorm doc itself. Metric name preserved per brainstorm D-003 / OQ-2. | grep evidence: see `bin/run-local-helpers-adversarial-test.sh:2508, 2540, 2729, 2734` |
| A-21 | `docs/architecture.md::## Sweep + scope partition (ENG-14)` at line 241 documents the three-stream partition + self-leak halt. No mention of `stage_is_read_mostly` or the read-mostly auto-clean lane today — this plan extends the section with a paragraph for the broadened auto-clean lane (Task 7). | `docs/architecture.md:241-257` |
| A-22 | `docs/knowledge/decisions.md` does NOT exist in the worktree today (`ls docs/knowledge/` returns ENOENT — confirmed). The brainstorm's proposed ADR (§14) is documented but not landed in this plan — Tasks 0-9 do not add `docs/knowledge/decisions.md`. The brainstorm's §14 ADR text stays in the brainstorm doc as the design rationale; if a later ticket creates `docs/knowledge/decisions.md`, the ADR can be lifted then. Deferred per brainstorm §11.1 ("if it exists at implement time"). | filesystem absence confirmed |
| A-23 | Sub-agents dispatched via the `Agent` tool — uncertain whether their `Write` invocations appear in the parent's transcript NDJSON, or whether the sub-agent has an independent transcript. The structural fix (D-001 cleanup) is unaffected: `partition_dirty_paths` reads `git status -z --porcelain` AFTER the parent agent exits, so sub-agent writes that persist in the worktree are visible regardless of transcript-visibility. The D-005 detective (stretch) MAY false-negative on sub-agent writes; flagged in Task 8 as a known limitation, deferred to operator observation. | brainstorm A-14, OQ-6 |

### Assumed/new (not yet in codebase)

| # | Symbol or artifact | Where it lands |
|---|---|---|
| N-1 | `stage_auto_cleans_self_leak` predicate | NEW function in `bin/run-local-helpers.sh` (Task 2) |
| N-2 | `assert_no_write_outside_allowlist` helper (stretch) | NEW function in `bin/common.sh` (Task 8) |
| N-3 | `dispatch-debris-write` metric (stretch) | NEW emit site in `bin/dispatch.sh::_render_and_capture_stream` (Task 8) |
| N-4 | `dispatch.debris_detective` config flag | NEW key in `.pipeline-config/config.json` (Task 8) |
| N-5 | `Sub-agent debris (ENG-100)` §0 rule | NEW paragraph in `AGENT_PROMPTS.md` §0 fenced block (Task 4) |
| N-6 | Fixture `AC-ENG-100-PLAN-DEBRIS` and `AC-ENG-100-CLEAN-RESPECTS-*` | NEW assertions in `bin/run-local-sweep-test.sh` and `bin/run-local-helpers-adversarial-test.sh` (Tasks 5-6) |

## 3. File Structure

| File | New / Modified | Purpose |
|---|---|---|
| `bin/run-local-helpers.sh` | Modified | Add `stage_auto_cleans_self_leak` predicate; update `clean_self_leak_residue` log message + docstring; do NOT touch `stage_is_read_mostly`. |
| `bin/run-local.sh` | Modified | One-line predicate swap at line 263 (`stage_is_read_mostly` → `stage_auto_cleans_self_leak`). Positional argv to `clean_self_leak_residue` unchanged (preserves wire-up anchor #4). |
| `AGENT_PROMPTS.md` | Modified | Append `Sub-agent debris (ENG-100)` paragraph to §0 fenced block (between the existing Stage-summary rule at line 227 and the closing ``` fence at line 228). |
| `bin/agent-prompts-content-test.sh` | Modified | Add §0 phrase pins for the new rule, mirroring ENG-87 iter-7 C2 pin shape (`rendered_stage_body` grep for `Sub-agent debris (ENG-100)` and the literal `agent-blocked` reason). |
| `bin/run-local-helpers-adversarial-test.sh` | Modified | Update wire-up anchor #3 to pin the new predicate name (`stage_auto_cleans_self_leak`); add positive-case tests for the new predicate (brainstorm/plan return 0; implementing/ui/qa return 1); add integration test cloning `test_self_leak_handler_pipeline_e2e` for `planning` stage and asserting plan-doc + debris co-existence. |
| `bin/run-local-sweep-test.sh` | Modified | Add `AC-ENG-100-PLAN-DEBRIS` assertion: planning dispatch with `docs/plans/2026-05-15-eng-100-foo.md` (in-scope) AND `awk-test-input.txt` (out-of-scope) — expect partition `1 0 1`; cross-check that `stage_auto_cleans_self_leak planning` returns 0 and `stage_auto_cleans_self_leak implementing` returns 1. |
| `bin/common.sh` | Modified (stretch — Task 8 optional) | Add `assert_no_write_outside_allowlist` helper. |
| `bin/dispatch.sh` | Modified (stretch — Task 8 optional) | Wire detective behind `dispatch.debris_detective` config flag; emit `dispatch-debris-write` metric on violations; do NOT halt. |
| `docs/architecture.md` | Modified | Append a paragraph to `## Sweep + scope partition (ENG-14)` (line 241+ region) documenting the broadened auto-clean lane. |
| `CLAUDE.md` | Modified | Update the "Read-mostly stages auto-clean" paragraph (line ~299) and the Failure-mode quick-reference row (line ~611) to enumerate the broadened auto-clean stage list (`brainstorming | planning | reviewing | building | released`). Surfaces the change in the canonical operator-facing reference. |
| `bin/dispatch-test.sh` | Read-only (post-rebase smoke) | Confirms upstream G8.B remains passing after Task 8's detective lands. No new assertions added here; the detective's tests live in dispatch-test.sh under a new G-block IF Task 8 ships. If Task 8 is deferred, no edit. |

## 4. API Contract

no new API surface

This is a bash-orchestration change with no FE↔BE API surface. The closest analogue is the new
predicate `stage_auto_cleans_self_leak`'s signature, documented inline as a code anchor:

```text
# stage_auto_cleans_self_leak <stage>
#
# Returns 0 iff a self-leak on this stage should be auto-cleaned by
# clean_self_leak_residue rather than halted via halt_issue_for_self_leak.
# Stage list: brainstorming, planning, reviewing, building, released.
# (Predicate is a superset of stage_is_read_mostly — it adds the two
# doc-writing stages to the auto-clean lane.)
#
# Returns 1 for implementing, ui, qa (production-path writes — halt is
# the correct operator signal). UNKNOWN stages → 1 (conservative; same
# default as stage_is_read_mostly).
```

## 5. Backend Tasks

### Task 0: Rebase onto origin/main

- `depends_on: []`
- `touches: feature branch HEAD`
- [ ] In the worktree, run `git fetch origin main` then `git rebase origin/main`.
- [ ] After the rebase, re-verify every `path:line` claim in §2 Assumption Inventory survives. Specifically: `bin/dispatch.sh:54, 142-144, 146-235` (where Task 8's detective lands) MAY have shifted by ±5 lines due to the upstream `_render_and_capture_stream` trailing cleanup change. Use the content anchors below (not line numbers) when applying Tasks 2-8.
- [ ] If the rebase introduces a merge conflict in `bin/dispatch.sh` or `bin/dispatch-test.sh`, STOP and post a Linear comment on ENG-100 requesting `pipeline:supersede` — the upstream change touched the same surface and the brainstorm should be re-evaluated against the new base. Otherwise proceed.
- [ ] Re-run the test gate (`bash bin/run-local-sweep-test.sh && bash bin/run-local-helpers-adversarial-test.sh && bash bin/dispatch-test.sh && bash bin/agent-prompts-content-test.sh`) before Task 1; this confirms a clean rebase.

### Task 1: Add `stage_auto_cleans_self_leak` predicate

- `depends_on: [0]`
- `touches: bin/run-local-helpers.sh::stage_auto_cleans_self_leak`
- [ ] In `bin/run-local-helpers.sh`, locate the `stage_is_read_mostly` function (CONTENT ANCHOR: the line `stage_is_read_mostly() {` and its closing `}` containing the body `out="$(stage_output_paths "$1" 2>/dev/null)" || return 1; [[ -z "$out" ]]`). Add a new sibling function IMMEDIATELY AFTER `stage_is_read_mostly`'s closing `}` brace (~line 180 pre-rebase, may shift post-rebase). Naming hygiene per brainstorm D-004: new predicate names the contract directly (`stage_auto_cleans_self_leak`); the existing `stage_is_read_mostly` is preserved verbatim because it remains the canonical predicate over `stage_output_paths`.
- [ ] Body:

  ```bash
  # stage_auto_cleans_self_leak <stage>
  #
  # Returns 0 iff a self-leak on this stage should be auto-cleaned by
  # clean_self_leak_residue rather than halted via halt_issue_for_self_leak.
  # Stage list: brainstorming, planning, reviewing, building, released.
  # Returns 1 for implementing, ui, qa, retrospective, and UNKNOWN.
  #
  # Superset of stage_is_read_mostly (which returns 0 only for
  # reviewing|building|released). The two doc-writing stages
  # (brainstorming, planning) are added because their --allowed-tools
  # surface does not include Bash(rm:*) (operator decision 2026-05-10),
  # so they cannot clean up sub-agent debris themselves; the orchestrator
  # absorbs the cleanup at the FD5 self-leak gate in run-local.sh.
  #
  # Distinct from stage_is_read_mostly: the latter is the SoT for "stage
  # has no legitimate worktree writes" (consumed by partition's empty-
  # allowlist case). Conflating the two would lie about brainstorm being
  # read-mostly (it isn't — it writes docs/brainstorms/*).
  stage_auto_cleans_self_leak() {
    case "$1" in
      brainstorming|planning|reviewing|building|released) return 0 ;;
      *) return 1 ;;
    esac
  }
  ```

- [ ] Verify with `bash -n bin/run-local-helpers.sh` (syntax check).

### Task 2: Update `clean_self_leak_residue` log message and docstring

- `depends_on: [1]`
- `touches: bin/run-local-helpers.sh::clean_self_leak_residue`
- [ ] CONTENT ANCHOR: `clean_self_leak_residue`'s opening docstring at line ~182 (the `# clean_self_leak_residue <issue> <stage> <worktree> <path>...` header). Replace the line `# Called from run-local.sh's self-leak handler when the affected stage is read-mostly (per stage_is_read_mostly).` with: `# Called from run-local.sh's self-leak handler when the affected stage routes self-leak through auto-clean (per stage_auto_cleans_self_leak — brainstorming, planning, reviewing, building, released).` Preserve the rest of the docstring verbatim.
- [ ] CONTENT ANCHOR: the log line at `bin/run-local-helpers.sh:253` immediately after the dry-run early-return. Old text (post-rebase line may shift): `log "auto-clean: stage=$stage is read-mostly; cleaning ${count} self-leak path(s) on $branch; hashes=${hash_csv}"`. Replace with: `log "auto-clean: stage=$stage residue; cleaning ${count} self-leak path(s) on $branch; hashes=${hash_csv}"`. Drops the stale "is read-mostly" phrasing flagged by the design persona's P2 in iter-1 of the brainstorm.
- [ ] Also update the defensive-refuse log line at line ~235: `log "auto-clean: defensive refuse on branch='${branch:-<empty-or-detached>}' for stage=$stage (read-mostly cleanup must never run on main)"`. Replace `read-mostly cleanup` with `auto-clean must never run on main` for consistency. Cosmetic; preserves the substring `defensive refuse` that downstream operators grep for.
- [ ] Verify with `bash -n bin/run-local-helpers.sh`.

### Task 3: Swap the gate in `run-local.sh::_run_worker`

- `depends_on: [1]`
- `touches: bin/run-local.sh:263 (gate site)`
- [ ] CONTENT ANCHOR: the comment block `# Precedence: self-leak (hard-fail) > leaked-in-scope > in-scope commit > observed bucketed.` at line ~260 followed by `if (( ${#self_leak_hashes[@]} > 0 )); then`. The exact line to change is `if stage_is_read_mostly "$stage"; then` — replace with `if stage_auto_cleans_self_leak "$stage"; then`. NO OTHER CHANGE: the auto-clean branch's `clean_self_leak_residue "$issue_id" "$stage" "$dispatch_cwd" "${self_leak_paths[@]}"` invocation stays byte-identical (preserves `bin/run-local-helpers-adversarial-test.sh` wire-up anchor #4); the else-branch's `halt_issue_for_self_leak "$issue_id" "$stage" "${self_leak_hashes[@]}"` invocation stays byte-identical.
- [ ] Verify with `bash -n bin/run-local.sh`.

### Task 4: Append the §0 sub-agent debris rule

- `depends_on: [0]`
- `touches: AGENT_PROMPTS.md::§0`
- [ ] CONTENT ANCHOR: in `AGENT_PROMPTS.md` §0, AFTER the existing line that starts with `**Stage summary file — overwrite-on-every-dispatch contract (ENG-77/ENG-71):**` (~line 227) AND BEFORE the closing ```` ``` ```` fence (~line 228), insert ONE blank line then the new rule:

  ```
  **Sub-agent debris (ENG-100):** Do NOT write fixture files, scratch text, test inputs, or any other file outside the per-stage output allowlist — not even to verify a regex or parse a payload before recommending it. Reason about the pattern inline (mental simulation, or pipe via stdin to `awk`/`sed` heredocs where the stage allows Bash). Sub-agents dispatched via the `Agent` tool inherit the same constraint. If you absolutely cannot reason about the pattern without a file, run `bash bin/pipeline.sh event {issue_id} verdict halt --reason agent-blocked` and describe what you needed — the operator will fix the ergonomic gap. The orchestrator's tick-end cleanup will remove debris regardless, but a transcript-scan detective may flag the violation for retrospective review.
  ```

  The whole rule is one paragraph on one logical line (matches the §0 wrapping convention).
- [ ] Confirm `bin/render-prompt.sh::extract_block` still extracts §0 cleanly: `bash bin/render-prompt.sh planning ENG-100 | grep -F 'Sub-agent debris (ENG-100)'` should emit one line.
- [ ] Run `bash bin/agent-prompts-content-test.sh` — existing pins (§0 phrases ENG-46 / ENG-53 #11 / ENG-57 / ENG-74) MUST still pass. Token-coverage check at `bin/agent-prompts-content-test.sh:1215+` will reject any `{token}` not declared in `PROMPT_RESOLVERS`; the new rule uses only `{issue_id}` which is already declared. Confirmed by `grep -c "{issue_id}" bin/render-prompt.sh` returning ≥1.

### Task 5: Pin the new §0 rule in `agent-prompts-content-test.sh`

- `depends_on: [4]`
- `touches: bin/agent-prompts-content-test.sh::§0 invariants`
- [ ] CONTENT ANCHOR: locate the existing for-loop at lines ~58-65 that pins §0 phrases via `for phrase in 'Secret-handling (ENG-46)' ... ; do`. Inside that loop's phrase list, add `'Sub-agent debris (ENG-100)'` AFTER `'Do NOT prepend env-var assignments'`. The for-body uses `grep -qF "$phrase"` against `$s0` so the new phrase will be checked identically.
- [ ] CONTENT ANCHOR: locate the `rendered_stage_body_implementing` block at lines ~1156-1187 (ENG-87 review-iter-7 C2 contract pin). After the last `unset rendered_stage_body_implementing` at line ~1187 and before the next `# ─── ENG-87 review-iter-7 M4` block, insert a new test block:

  ```bash
  # ─── ENG-100: sub-agent debris rule delivered via §0 ─────────────
  # The new §0 rule must reach every rendered stage body, including
  # brainstorm/plan which use it as the structural complement to the
  # orchestrator-side auto-clean. Pin the rule's headline phrase + the
  # operator-recognition word agent-blocked so a §0 deletion surfaces
  # directly. Mirrors the ENG-87 C2 pin shape (rendered_stage_body =
  # §0 + §N).
  for stage_key in '## 1. Brainstorm Agent' '## 2. Plan Agent'; do
    short="${stage_key%% Agent*}"
    rsb="$(rendered_stage_body "$stage_key")"
    if printf '%s' "$rsb" | grep -qF 'Sub-agent debris (ENG-100)'; then
      ok "rendered stage body ($short): cites 'Sub-agent debris (ENG-100)' (delivered via §0)"
    else
      nope "rendered stage body ($short): cites 'Sub-agent debris (ENG-100)'" \
        "phrase missing from rendered §0 + §N — sub-agents not warned about debris generation"
    fi
    if printf '%s' "$rsb" | grep -qF 'verdict halt --reason agent-blocked'; then
      ok "rendered stage body ($short): names the agent-blocked exit ramp"
    else
      nope "rendered stage body ($short): names the agent-blocked exit ramp" \
        "without the operator-recognition word, the rule reads like advice instead of a hard contract"
    fi
  done
  unset stage_key short rsb
  ```

- [ ] Run `bash bin/agent-prompts-content-test.sh`; new assertions plus all existing pins must pass.

### Task 6: Add partition + predicate fixtures to `run-local-sweep-test.sh`

- `depends_on: [1]`
- `touches: bin/run-local-sweep-test.sh`
- [ ] CONTENT ANCHOR: the file already carries numbered fixture comments (`# 1: brainstorming in-scope D-004 hit` at line 46, etc.) up through case 10. Append the new fixtures at the END of the file. `run-local-sweep-test.sh` is self-terminating via `assert_partition`'s exit-on-fail and has no trailing summary line — appending at EOF is the canonical pattern.
- [ ] Append:

  ```bash
  # AC-ENG-100-PLAN-DEBRIS: planning dispatch with sub-agent debris at
  # worktree root. Plan doc is in-scope (D-004 hit on basename);
  # awk-test-input.txt is out-of-scope (new since tick-start; no
  # allowlist match). Mirrors ENG-93 observed shape.
  printf '?? docs/plans/2026-05-15-eng-100-foo.md\0?? awk-test-input.txt\0' \
    | assert_partition plan_with_sub_agent_debris planning ENG-100 1 0 1

  # AC-ENG-100-BRAINSTORM-DEBRIS: parallel fixture on brainstorming
  # (the other docs-only stage routed through auto-clean).
  printf '?? docs/brainstorms/2026-05-15-eng-100-foo-design.md\0?? scratch-fixture.txt\0' \
    | assert_partition brainstorm_with_sub_agent_debris brainstorming ENG-100 1 0 1

  # AC-ENG-100-PREDICATE-PLANNING: new predicate routes planning to
  # auto-clean lane.
  if stage_auto_cleans_self_leak planning; then
    printf 'OK: stage_auto_cleans_self_leak: planning routes to auto-clean lane\n'
  else
    printf 'FAIL: stage_auto_cleans_self_leak: planning routes to auto-clean lane\n  reason: expected planning to auto-clean self-leak residue\n' >&2; exit 1
  fi

  # AC-ENG-100-PREDICATE-BRAINSTORM: same for brainstorming.
  if stage_auto_cleans_self_leak brainstorming; then
    printf 'OK: stage_auto_cleans_self_leak: brainstorming routes to auto-clean lane\n'
  else
    printf 'FAIL: stage_auto_cleans_self_leak: brainstorming routes to auto-clean lane\n  reason: expected brainstorming to auto-clean self-leak residue\n' >&2; exit 1
  fi

  # AC-ENG-100-PREDICATE-IMPLEMENTING: implementing STAYS on the halt
  # lane — operator decision asymmetry between docs-only and
  # production-path stages must be preserved.
  if stage_auto_cleans_self_leak implementing; then
    printf 'FAIL: stage_auto_cleans_self_leak: implementing must NOT auto-clean\n  reason: production-path stages still halt on self-leak (operator signal)\n' >&2; exit 1
  else
    printf 'OK: stage_auto_cleans_self_leak: implementing stays on halt lane\n'
  fi

  # AC-ENG-100-PREDICATE-UI: ui STAYS on the halt lane.
  if stage_auto_cleans_self_leak ui; then
    printf 'FAIL: stage_auto_cleans_self_leak: ui must NOT auto-clean\n' >&2; exit 1
  else
    printf 'OK: stage_auto_cleans_self_leak: ui stays on halt lane\n'
  fi

  # AC-ENG-100-PREDICATE-QA: qa STAYS on the halt lane.
  if stage_auto_cleans_self_leak qa; then
    printf 'FAIL: stage_auto_cleans_self_leak: qa must NOT auto-clean\n' >&2; exit 1
  else
    printf 'OK: stage_auto_cleans_self_leak: qa stays on halt lane\n'
  fi

  # AC-ENG-100-PREDICATE-UNKNOWN: UNKNOWN stage → halt lane (conservative).
  if stage_auto_cleans_self_leak some-unknown-stage 2>/dev/null; then
    printf 'FAIL: stage_auto_cleans_self_leak: unknown stage must NOT auto-clean\n' >&2; exit 1
  else
    printf 'OK: stage_auto_cleans_self_leak: unknown stage stays on halt lane (conservative)\n'
  fi
  ```

- [ ] Run `bash bin/run-local-sweep-test.sh`; all existing + new fixtures must pass.

### Task 7: Update wire-up anchor #3 and add integration tests in `run-local-helpers-adversarial-test.sh`

- `depends_on: [3]`
- `touches: bin/run-local-helpers-adversarial-test.sh::test_self_leak_callsite_wired, test_self_leak_handler_pipeline_e2e`
- [ ] **TEST-GATE CLOSURE** (per §2 A-8): wire-up anchor #3 currently pins the regex `if[[:space:]]+stage_is_read_mostly[[:space:]]+"\$stage";`. Task 3 changes `run-local.sh:263` to `if stage_auto_cleans_self_leak "$stage"; then` — anchor #3 WILL FAIL without this task.
- [ ] CONTENT ANCHOR: `test_self_leak_callsite_wired`'s "Anchor 3" comment block (lines ~2775-2782). Replace the `if grep -qE 'if[[:space:]]+stage_is_read_mostly[[:space:]]+"\$stage";' "$rl"; then` block with:

  ```bash
  # Anchor 3 (ENG-100): stage_auto_cleans_self_leak is the gate inside
  # the self-leak handler — must appear with $stage as the sole
  # positional argument. Pre-ENG-100 this anchor pinned
  # stage_is_read_mostly; the predicate was renamed to honor the
  # docs-only-stages auto-clean extension (brainstorm D-004).
  if grep -qE 'if[[:space:]]+stage_auto_cleans_self_leak[[:space:]]+"\$stage";' "$rl"; then
    report_ok 'wire-up #3: stage_auto_cleans_self_leak "$stage" gate present in run-local.sh'
  else
    report_fail 'wire-up #3: predicate gate' \
      'if stage_auto_cleans_self_leak "$stage"; then' 'not found'
  fi
  ```

- [ ] CONTENT ANCHOR: comment at line ~2645 inside `test_self_leak_handler_pipeline_e2e`'s leading docstring (`stage_is_read_mostly branch → clean_self_leak_residue invocation`). Replace `stage_is_read_mostly branch` with `stage_auto_cleans_self_leak branch`. Cosmetic; preserves the test's intent. The runtime call at line 2703 (`if stage_is_read_mostly reviewing; then`) STAYS — it exercises the (unchanged) `stage_is_read_mostly` function directly and stays green.
- [ ] CONTENT ANCHOR: `test_read_mostly_predicate` at lines ~2285-2308 stays IDENTICAL — it asserts `stage_is_read_mostly`'s SoT contract, which this plan preserves. Verify with `grep -n "stage_is_read_mostly reviewing" bin/run-local-helpers-adversarial-test.sh` showing the existing call still present.
- [ ] CONTENT ANCHOR: after the closing `}` of `test_self_leak_callsite_wired` and BEFORE the `# ─── Scheduler-side in-flight lock wire-up invariants ──` block (line ~2834 region), insert a NEW test:

  ```bash
  # ─── ENG-100: stage_auto_cleans_self_leak predicate ────────────────
  # New predicate ships the docs-only auto-clean extension. Verify the
  # stage routing matches the contract from the ENG-100 brainstorm:
  # auto-clean for {brainstorming, planning, reviewing, building, released};
  # halt for {implementing, ui, qa, retrospective, unknown}.
  test_auto_cleans_self_leak_predicate() {
    local s
    for s in brainstorming planning reviewing building released; do
      if stage_auto_cleans_self_leak "$s"; then
        report_ok "auto_cleans: $s routes to auto-clean lane"
      else
        report_fail "auto_cleans: $s" 'true' 'false'
      fi
    done
    for s in implementing ui qa retrospective unknown-stage ''; do
      if stage_auto_cleans_self_leak "$s" 2>/dev/null; then
        report_fail "auto_cleans: '$s' should NOT auto-clean" 'false' 'true'
      else
        report_ok "auto_cleans: '$s' correctly stays on halt lane"
      fi
    done
  }
  test_auto_cleans_self_leak_predicate

  # ─── ENG-100: integration — planning self-leak handler pipeline ────
  # Clone of test_self_leak_handler_pipeline_e2e (reviewing) for the
  # planning stage. Exercises observed-vs-self-leak split AND the new
  # stage_auto_cleans_self_leak branch end-to-end on a docs-only stage
  # that previously halted.
  test_planning_self_leak_handler_pipeline_e2e() {
    local td; td="$(mktemp -d -t twinning-plan-pipeline.XXXXXX)"
    local wt="$td/wt"
    _self_leak_make_repo "$wt" "feat/eng-100-plan"

    # Operator's pre-existing edit (would be in tick-start snapshot).
    echo "operator-edits-doc" > "$wt/docs-arch-wip.md"
    # Agent's sub-agent debris.
    echo "awk-test-input" > "$wt/awk-test-input.txt"

    local snapshot_file="$td/snapshot"
    echo "docs-arch-wip.md" > "$snapshot_file"

    local out_scope_file="$td/out_scope"
    printf 'docs-arch-wip.md\0awk-test-input.txt\0' > "$out_scope_file"

    local sink="$td/metrics.log"; : > "$sink"
    _self_leak_stub_metrics "$td/stubs" "$sink"

    local observed_buckets=() self_leak_hashes=() self_leak_paths=()
    while IFS= read -r -d '' p; do
      if grep -qxF -- "$p" "$snapshot_file"; then
        observed_buckets+=("$(bucket_for_path "$p")")
      else
        self_leak_hashes+=("$(sha12 "$p")")
        self_leak_paths+=("$p")
      fi
    done < "$out_scope_file"

    assert_eq 'planning-e2e: observed_buckets count' '1' "${#observed_buckets[@]}"
    assert_eq 'planning-e2e: self_leak_paths count'  '1' "${#self_leak_paths[@]}"

    # The NEW predicate must route planning to the auto-clean branch.
    if stage_auto_cleans_self_leak planning; then
      (
        SCRIPT_DIR="$td/stubs"
        clean_self_leak_residue ENG-100 planning "$wt" "${self_leak_paths[@]}"
      ) >/dev/null 2>&1
    else
      report_fail 'planning-e2e: stage_auto_cleans_self_leak planning' 'true' 'false'
    fi

    # C1 invariant: operator pre-existing edit survives.
    local op_content; op_content="$(cat "$wt/docs-arch-wip.md" 2>/dev/null)"
    if [[ "$op_content" == "operator-edits-doc" ]]; then
      report_ok 'planning-e2e: operator pre-existing edit survives (C1 invariant)'
    else
      report_fail 'planning-e2e: C1 invariant' 'operator-edits-doc' "${op_content:-MISSING}"
    fi

    # Debris removed.
    if [[ ! -f "$wt/awk-test-input.txt" ]]; then
      report_ok 'planning-e2e: sub-agent debris (awk-test-input.txt) removed'
    else
      report_fail 'planning-e2e: residue removal' 'awk-test-input.txt removed' 'still present'
    fi

    # Metric emitted with planning as the stage label.
    case "$(cat "$sink")" in
      *'sweep-readonly-residue-cleaned ENG-100 planning cleaned 0 count=1 branch=feat/eng-100-plan'*)
        report_ok 'planning-e2e: metric emitted with stage=planning, count=1'
        ;;
      *)
        report_fail 'planning-e2e: metric payload' \
          'sweep-readonly-residue-cleaned ENG-100 planning cleaned 0 count=1 branch=feat/eng-100-plan ...' \
          "$(cat "$sink")"
        ;;
    esac

    rm -rf "$td"
  }
  test_planning_self_leak_handler_pipeline_e2e
  ```

- [ ] Run `bash bin/run-local-helpers-adversarial-test.sh`; existing tests + the new ones must pass.

### Task 8 (STRETCH — defer if Task 0-7 exhaust time budget): D-005 transcript detective

- `depends_on: [0]`
- `touches: bin/common.sh::assert_no_write_outside_allowlist, bin/dispatch.sh::_render_and_capture_stream, .pipeline-config/config.json`
- [ ] In `bin/common.sh`, IMMEDIATELY AFTER the `assert_no_tool_invocation` function (CONTENT ANCHOR: the closing `}` at line ~195 — pre-rebase line; may shift after upstream rebase. Identify by the trailing comment `(2) bin/run-stage.sh::_validate_dispatch_envelope`), add a sibling helper:

  ```bash
  # assert_no_write_outside_allowlist <transcript> <allowlist_csv>
  #
  # Scans an NDJSON transcript for Write tool_use invocations whose
  # input.file_path is NOT covered by the comma-separated allowlist
  # (entries may be dir-prefix `docs/plans/` or exact files
  # `AGENT_PROMPTS.md`; matching mirrors partition_dirty_paths). Returns
  # 0 if no violation; returns 1 + prints the offending file_path to
  # stdout (one per line, deduplicated) if any Write fell outside.
  #
  # Detective only — caller decides whether to halt or just emit a
  # metric. Used by bin/dispatch.sh::_render_and_capture_stream behind
  # the dispatch.debris_detective config flag (default off).
  assert_no_write_outside_allowlist() {
    local transcript="$1" allowlist_csv="$2"
    [[ -s "$transcript" ]] || return 0
    local matched
    matched="$(jq -Rr --arg al "$allowlist_csv" '
      fromjson? // empty
      | select(.type == "assistant")
      | .message.content[]?
      | select(.type == "tool_use" and .name == "Write")
      | (.input.file_path // "")
      | select(. != "")
      | . as $fp
      | ($al | split(",")) as $entries
      | if any($entries[]; (. as $e | if endswith("/") then ($fp | startswith($e)) else $fp == $e end))
        then empty
        else $fp
        end
      ' "$transcript" 2>/dev/null | sort -u)" || true
    if [[ -n "$matched" ]]; then
      printf '%s\n' "$matched"
      return 1
    fi
    return 0
  }
  ```

- [ ] In `bin/dispatch.sh::_render_and_capture_stream`, CONTENT ANCHOR: the existing `# ENG-43: defense-in-depth assertion.` block at line ~146 (pre-rebase; may shift). AFTER the closing `fi` of the ENG-43 block (immediately before `# ENG-71: defense-in-depth assertion.` at line ~161), insert a new block:

  ```bash
    # ENG-100 D-005: debris-detective. Flag-gated via
    # dispatch.debris_detective (default false). Forensic-only —
    # emits a metric per offending Write path; never halts. The
    # structural fix is the orchestrator-side cleanup at
    # bin/run-local.sh:263 (stage_auto_cleans_self_leak gate);
    # this detective surfaces "agent prompt needs an update" trends
    # to the retrospective.
    if [[ "$(bash "$SCRIPT_DIR/common.sh" 2>/dev/null; jq -r '.dispatch.debris_detective // false' .pipeline-config/config.json 2>/dev/null || echo false)" == "true" ]]; then
      local _stage_allowlist_csv
      _stage_allowlist_csv="$(bash -c 'source "$SCRIPT_DIR/run-local-helpers.sh"; stage_output_paths "$1" 2>/dev/null' _ "$stage" | paste -sd, -)"
      if [[ -n "$_stage_allowlist_csv" ]]; then
        local _debris_paths
        _debris_paths="$(assert_no_write_outside_allowlist "$raw_capture" "$_stage_allowlist_csv" 2>/dev/null || true)"
        if [[ -n "$_debris_paths" ]]; then
          local _p _sha
          while IFS= read -r _p; do
            _sha="$(printf '%s' "$_p" | shasum -a 256 | awk '{print substr($1, 1, 12)}')"
            bash "$SCRIPT_DIR/metrics.sh" dispatch-debris-write "${ISSUE_ID:-unknown}" "$stage" \
              "detected" 0 "sha12=${_sha}" \
              || true   # forensic-only; never halts
          done <<< "$_debris_paths"
        fi
      fi
    fi
  ```

  Implementation notes for the implement agent:
  - The double-source pattern in the `if` condition is awkward. A cleaner shape is to source `run-local-helpers.sh` once at the top of `dispatch.sh::main` if it isn't already, then call `stage_output_paths` directly. The implementor should choose the cleanest shape; the contract is: detective is flag-gated, emits metric on violation, never halts, returns void.
  - Sub-agent visibility caveat (per §2 A-23 / brainstorm OQ-6): if sub-agents have independent transcripts, the detective may false-negative. This is acceptable — the cleanup pass is the structural fix; the detective is forensic-only.
- [ ] Add the config key default to `.pipeline-config/config.json` under `dispatch.debris_detective: false` IF the operator wants to ship with the flag explicitly declared. CONTENT ANCHOR: the existing `dispatch.tools` block (per CLAUDE.md "Per-target dispatch.tools extras"). Default off ships the structural change without risk.
- [ ] Add a smoke test under a new `# ─── G9 ENG-100 debris detective ─` block at the END of `bin/dispatch-test.sh`: stub a transcript with one in-allowlist Write and one out-of-allowlist Write; assert that the detective emits the metric only for the second and returns rc 0. Skip the test if the flag is off.

### Task 9: Update `docs/architecture.md` Sweep + scope partition section

- `depends_on: [3]`
- `touches: docs/architecture.md::## Sweep + scope partition (ENG-14)`
- [ ] CONTENT ANCHOR: the heading `## Sweep + scope partition (ENG-14)` at line 241 and its body through the line `Anything writing files outside the per-stage allowlist must update the partition rules in run-local-helpers.sh or it will trip the breaker.` at line ~257. Append a paragraph IMMEDIATELY AFTER that closing line and BEFORE the next H2 (`## Per-stage dispatch timeouts (ENG-65)` at line 259):

  ```markdown
  **Auto-clean lane for docs-only stages (ENG-100).** Pre-ENG-100,
  `bin/run-local.sh`'s self-leak gate routed `brainstorming | planning`
  to `halt_issue_for_self_leak` whenever a sub-agent left a scratch
  file at the worktree root — even on an otherwise clean stage output.
  Since operator decision 2026-05-10 forbids any form of `Bash(rm:*)`
  in agent `--allowed-tools`, the agent could not clean up after
  itself. The gate now routes through `stage_auto_cleans_self_leak`,
  a superset of `stage_is_read_mostly` that adds the two doc-writing
  stages to the auto-clean lane. `clean_self_leak_residue` (per-path:
  `git checkout --` for tracked, `rm -rf` for untracked) removes the
  debris under orchestrator privileges; the legitimate stage output
  auto-commits as if no debris ever existed. `implementing | ui | qa`
  remain on the halt lane — their allowlist admits production-path
  writes, and a self-leak there is the agent-off-piste signal the
  operator wants. Forensic audit is preserved via the existing
  `sweep-readonly-residue-cleaned` metric (its name predates ENG-100
  and is kept verbatim to avoid churning the retrospective filter
  and `bin/status.sh`'s red/yellow predicate).
  ```

- [ ] Confirm via `markdown-link-check` or manual read that no broken anchors are introduced.

### Task 9b: Update CLAUDE.md to reflect broadened auto-clean lane

- `depends_on: [3]`
- `touches: CLAUDE.md::Read-mostly stages auto-clean paragraph + Failure-mode quick reference row`
- [ ] CONTENT ANCHOR: in `CLAUDE.md`, the paragraph beginning `**Read-mostly stages auto-clean self-leak residue, never halt on it (\`reviewing | building | released\`).**` at line ~299. Replace the opening sentence with: `**Docs-only + read-mostly stages auto-clean self-leak residue, never halt on it (\`brainstorming | planning | reviewing | building | released\`).**` and update the next sentence to cite `stage_auto_cleans_self_leak` as the gate predicate (the existing `stage_is_read_mostly` reference stays as a parenthetical SoT note). Preserve the rest of the paragraph (per-path strategy, metric, defensive guards) verbatim.
- [ ] CONTENT ANCHOR: the Failure-mode quick-reference table row at line ~611 carrying the substring `Self-leak halts only fire on \`implementing | ui | qa\`; on \`reviewing | building | released\`, \`clean_self_leak_residue\` auto-cleans`. Replace the auto-clean stage list with `\`brainstorming | planning | reviewing | building | released\``. The `implementing | ui | qa` list stays unchanged.
- [ ] Run `bash bin/pipeline.sh status ENG-100` (no-op if CLAUDE.md changes don't affect pipeline state) as a smoke check.

## 6. Frontend Tasks

no UI surface — this is a bash orchestration change with no React, dashboard, or operator-facing UI deliverable. The dashboard at `bin/status.sh` reads the unchanged `sweep-readonly-residue-cleaned` metric and surfaces it as already-shipped behavior.

## 7. Failure Mode → Test Map

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
|---|---|---|---|---|
| Sub-agent writes scratch file at worktree root during planning; plan doc itself is clean | Planning dispatch with `docs/plans/2026-05-15-eng-100-foo.md` + `awk-test-input.txt` in worktree post-dispatch | Partition emits 1 in-scope, 0 leaked, 1 out-of-scope. `stage_auto_cleans_self_leak planning` returns 0. `clean_self_leak_residue` removes the debris, emits metric. Plan doc auto-commits. No halt. | integration | `bin/run-local-helpers-adversarial-test.sh::test_planning_self_leak_handler_pipeline_e2e` |
| Same shape on brainstorming | Brainstorming dispatch + sub-agent debris | Same as above with `brainstorming` as the stage label | unit | `bin/run-local-sweep-test.sh::brainstorm_with_sub_agent_debris` |
| Sub-agent writes scratch on `implementing` | Implementing dispatch + scratch path outside allowlist + new since tick-start | `stage_auto_cleans_self_leak implementing` returns 1 → `halt_issue_for_self_leak` fires → `pipeline:halted` applied (preserved contract) | unit | `bin/run-local-sweep-test.sh::stage_auto_cleans_self_leak: implementing` (AC-ENG-100-PREDICATE-IMPLEMENTING) |
| Operator's pre-existing edit happens to be out-of-scope | Tick-start snapshot contains the edit; tick-end shows same edit + new agent residue | Observed-vs-self-leak split filters the operator's edit into `observed_buckets[]`; only the agent's residue reaches `clean_self_leak_residue`. C1 invariant preserved. | integration | `bin/run-local-helpers-adversarial-test.sh::test_planning_self_leak_handler_pipeline_e2e` (operator-edits-doc survival assertion) |
| Operator override broadens planning's allowlist | `config.json::scope.allowlist.planning` contains `docs/custom/`; agent writes `docs/custom/foo.md` | `_scope_allowlist_override` wins; `stage_output_paths` returns the override; `partition_dirty_paths` routes the path to FD3 (in-scope); cleanup does not touch it. | unit | Coverage already in existing `bin/run-local-helpers-adversarial-test.sh::test_scope_allowlist_override` (no new test required; verified by reading the existing tests) |
| Worktree is on `main` / `master` / detached HEAD at cleanup time | `git branch --show-current` returns `main` / `master` / `""` | `clean_self_leak_residue` defensive-refuses, logs `auto-clean: defensive refuse on branch=...`, returns 0. No data loss. | unit | Existing `bin/run-local-helpers-adversarial-test.sh::test_self_leak_refuses_on_main` (pin unchanged) |
| Tick-start snapshot file missing/corrupt | The snapshot file is deleted between `git status` capture and observed-vs-self-leak split | The grep `grep -qxF -- "$p" "$snapshot_file"` returns rc 2 (file not found); under `set -e` this could blow up. Pre-existing behavior — out of scope for this plan. | n/a (existing behavior) | n/a |
| `clean_self_leak_residue` partial failure on rm or checkout | `rm -rf` returns nonzero for one of the paths (permission, locked) | Helper increments `rm_fail` / `checkout_fail` counters, logs partial failure, emits metric with the counters populated, returns 0. Next tick's partition catches survivors. | unit | Existing `bin/run-local-helpers-adversarial-test.sh::test_self_leak_metric_rm_fail` (pin unchanged) |
| `dispatch.debris_detective` flag is on; agent writes outside allowlist (stretch) | Flag-enabled dispatch with a `Write` to a non-allowlist path in transcript | `assert_no_write_outside_allowlist` returns 1 with the path; detective emits `dispatch-debris-write` metric; no halt. | smoke | `bin/dispatch-test.sh::G9 ENG-100 debris detective` (Task 8) |
| `dispatch.debris_detective` flag is off (default) | Same dispatch shape | Detective code is skipped; no metric emit; no behavior change vs pre-ENG-100. | smoke | `bin/dispatch-test.sh::G9 ENG-100 debris detective off-path` (Task 8) |
| Wire-up anchor #3 regression: someone reverts run-local.sh:263 back to `stage_is_read_mostly` | A future refactor accidentally restores the old predicate name | `test_self_leak_callsite_wired` anchor #3 fails — pre-commit hook blocks the change. | unit | `bin/run-local-helpers-adversarial-test.sh::test_self_leak_callsite_wired` anchor #3 (updated in Task 7) |
| §0 rule deletion / drift | Someone deletes the `Sub-agent debris (ENG-100)` paragraph from §0 | `bin/agent-prompts-content-test.sh`'s §0 for-loop phrase pin fails; rendered_stage_body pin for `## 1. Brainstorm Agent` and `## 2. Plan Agent` fails. Pre-commit hook blocks. | unit | `bin/agent-prompts-content-test.sh::§0 (Common rules) carries 'Sub-agent debris (ENG-100)'` + new rendered_stage_body checks (Task 5) |

## 8. Test Strategy

**Unit (existing test files extended):**
- `bin/run-local-sweep-test.sh` — partition shape for plan-debris and brainstorm-debris fixtures; positive + negative cases for `stage_auto_cleans_self_leak` across all stage names (Task 6).
- `bin/agent-prompts-content-test.sh` — §0 phrase pin + rendered_stage_body coverage for §§1-2 (Task 5).
- `bin/run-local-helpers-adversarial-test.sh::test_read_mostly_predicate` — STAYS UNCHANGED (existing pin on `stage_is_read_mostly`'s SoT). Confirms the legacy predicate's contract is preserved, which is load-bearing for `partition_dirty_paths`'s empty-allowlist branch.

**Integration:**
- `bin/run-local-helpers-adversarial-test.sh::test_planning_self_leak_handler_pipeline_e2e` — clones the existing reviewing-stage E2E to cover the planning lane (Task 7).
- `bin/run-local-helpers-adversarial-test.sh::test_auto_cleans_self_leak_predicate` — table-driven positive + negative across all stage names (Task 7).
- `bin/run-local-helpers-adversarial-test.sh::test_self_leak_callsite_wired` anchor #3 — pins the new predicate name at `run-local.sh:263` (Task 7). **Test-gate closure for the rename.**

**Smoke (stretch — Task 8):**
- `bin/dispatch-test.sh::G9 ENG-100 debris detective` — exercises the flag-on / flag-off paths of `assert_no_write_outside_allowlist` against a synthesized transcript.

**Adversarial coverage already in place (no new test, verified pre-PR):**
- Operator override broadens planning's allowlist — `_scope_allowlist_override` wins; cleanup respects FD3 classification (existing test in `bin/run-local-helpers-adversarial-test.sh`).
- Worktree on `main` / `master` / detached HEAD — `clean_self_leak_residue` defensive-refuses (existing test).
- Partial cleanup failure (rm or checkout returns nonzero) — metric emit with `rm_fail` / `checkout_fail` counters (existing test).
- Adversarial filenames (leading dash, embedded space, binary blob, symlink to /etc/passwd) — `rm -rf -- ...` form already covered by existing `clean_self_leak_residue` security tests (`bin/run-local-helpers-adversarial-test.sh`).

**Test-gate closure sweep (per §3 of the plan format mandate):**

Token removed from production code: `stage_is_read_mostly` at `bin/run-local.sh:263` (one site only — the rest of the codebase references `stage_is_read_mostly` as a function, not a string token; those references stay valid). Sibling test files referencing this exact site:

| File | Reference | Status |
|---|---|---|
| `bin/run-local-helpers-adversarial-test.sh:2777` | `grep -qE 'if[[:space:]]+stage_is_read_mostly[[:space:]]+"\$stage";' "$rl"` (wire-up anchor #3) | LISTED in File Structure (Task 7) — assertion inverted to pin the new predicate. |
| `bin/run-local-helpers-adversarial-test.sh:2645` | comment `stage_is_read_mostly branch → clean_self_leak_residue invocation` | LISTED in File Structure (Task 7) — comment updated. |
| `bin/run-local-helpers-adversarial-test.sh:2703` | `if stage_is_read_mostly reviewing; then ... clean_self_leak_residue ... fi` (runtime call inside integration test) | INTENTIONALLY UNCHANGED — exercises `stage_is_read_mostly`'s preserved SoT for `reviewing`; passing this test is part of the load-bearing assertion that the legacy predicate stays defined and correct. |
| `bin/run-local-helpers-adversarial-test.sh:2285-2308` | `test_read_mostly_predicate` body (multiple `stage_is_read_mostly` calls) | INTENTIONALLY UNCHANGED — see above. |
| `bin/run-local-helpers.sh:178-180, 185, 582` | Function definition + internal comment references | INTENTIONALLY UNCHANGED — predicate preserved. |

No other test file references the soon-to-change call site at `bin/run-local.sh:263`. No P0 test-gate-closure defect. The plan's File Structure entry for `bin/run-local-helpers-adversarial-test.sh` covers the two assertion sites that would otherwise regress.
