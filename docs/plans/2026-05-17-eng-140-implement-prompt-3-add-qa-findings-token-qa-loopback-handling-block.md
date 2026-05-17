---
linear: ENG-140
date: 2026-05-17
topic: implement prompt §3 — {qa_findings} token + qa→implementing loopback block
---

# ENG-140 — Plan: §3 {qa_findings} token + qa-loopback handling block

## 1. Goal

Wire a `{qa_findings}` render-time token gated on `PIPELINE_LOOPBACK_SOURCE=qa` and add a §3 "QA → implement loopback handling" block that names QA's P0 severity, mandates a failing-test-name commit trailer, and carries a scope-drift restraint with a bug-fix carve-out — so that on a `qa → implementing` loopback the implementer sees the QA findings inline in its prompt instead of having to discover them via Linear.

## 2. Assumption Inventory

**Branch-base freshness:** `git log --oneline HEAD..origin/main` is **NON-EMPTY** at plan time — 15 commits ahead on origin/main (most recent: `1533f00` Merge PR #117 ENG-110 lane-stamp). Task 0 (Rebase onto origin/main) is added at the top of Backend Tasks; all subsequent tasks use content anchors, never bare line numbers, to survive the rebase. The line numbers cited below are informational hints valid at the pre-rebase HEAD (`0a51c68`) — the implement agent re-verifies anchors post-rebase.

Every named symbol, path, and contract referenced by tasks below is grep-verified against the current working tree.

| # | Assumption | Status | Evidence |
|---|---|---|---|
| A1 | `bin/render-prompt.sh::PROMPT_RESOLVERS` is the resolver registry; entries land between the opening `PROMPT_RESOLVERS='` line and the closing `'` line | **verified** | `bin/render-prompt.sh:41-57` (read directly); current entries: `issue_id`, `review_findings`, `progress_md_path`, `plan_json`, etc. Trailing entry today is `plan_json=_resolve_plan_json`. Content anchor: the line `review_findings=_resolve_review_findings` inside the registry. |
| A2 | `bin/render-prompt.sh::_resolve_review_findings` exists with the gating shape ENG-140 will copy | **verified** | `bin/render-prompt.sh:264-276`. Signature: `_resolve_review_findings()`; gates on `${PIPELINE_LOOPBACK_SOURCE-}`; uses `${_RENDER_REVIEW_FINDINGS_PATH-}`; emits `'(no prior review for this issue — this dispatch is not a review-loopback)'` sentinel on negative-gate and empty-file paths. Content anchor for inserting the new resolver: the closing `}` of `_resolve_review_findings`, followed by the existing blank line and `# Without a structured plan.json sibling, ...` comment that opens `_resolve_plan_json`. |
| A3 | `bin/render-prompt.sh::main()` binds `_RENDER_REVIEW_FINDINGS_PATH` near other `_RENDER_*` globals | **verified** | `bin/render-prompt.sh:467-468` declares `local review_findings_path; review_findings_path="$(issue_dir "$issue_id")/stage-summary-reviewing.md"`; `:487` binds `_RENDER_REVIEW_FINDINGS_PATH="$review_findings_path"`. Content anchor: the bash line `_RENDER_REVIEW_FINDINGS_PATH="$review_findings_path"` is unique in `render-prompt.sh`. |
| A4 | `bin/run-stage.sh` exports `PIPELINE_LOOPBACK_SOURCE` per implementing dispatch | **verified — UNTOUCHED by plan** | `bin/run-stage.sh:1416-1422` (read directly): `_resolve_loopback_source` returns `qa` on qa→implementing transitions; value exported to `render-prompt.sh` invocation on `:1421`. The brainstorm D-007 + Linear ticket "Proposed scope" point 3 explicitly mandate no edits here. |
| A5 | `bin/verdict-handler.sh` allows the `qa → implementing` transition | **verified — UNTOUCHED by plan** | `bin/verdict-handler.sh:36` row `qa\|implementing\|` present. |
| A6 | `AGENT_PROMPTS.md` §3 has the existing review-loopback block followed by the build-loopback block, separated by a `Build → implement loopback handling (MANDATORY when present):` header line | **verified** | `AGENT_PROMPTS.md:729-763`. The review-loopback fall-through clause ends with the literal `Reviewing summary (verbatim):` header on its own line, immediately followed by `{review_findings}` token on its own line, then a blank line, then the build-loopback header. **Content anchors:** (a) the literal `{review_findings}` token line marks the end of the review-loopback block; (b) the literal header line `Build → implement loopback handling (MANDATORY when present):` marks the start of the build-loopback block. The new QA-loopback block inserts BETWEEN these two anchors. |
| A7 | §3 review-loopback fall-through already names `qa → implementing fail loopback` as a non-review case (so cross-reference from the new block is coherent) | **verified** | `AGENT_PROMPTS.md:735` literally contains `"- a qa → implementing fail loopback (treat as a bug-fix dispatch; QA's summary in completion/qa/{issue_id} is your input — do NOT treat the prior reviewer's findings as in scope here),"`. The new QA-loopback block will REPLACE the operational instruction "QA's summary in completion/qa/{issue_id} is your input" by inlining the findings — but the fall-through reference itself stays UNCHANGED (the brainstorm's D-005 placement preserves it as a forward reference). |
| A8 | §3 has exactly two column-0 ` ``` ` fences and `extract_block` will die loudly if a third lands | **verified** | `bin/render-prompt.sh:94-115` `extract_block` enforces fence_count == 2 per stage. The new block must NOT introduce a column-0 fence. The brainstorm's prose is plain markdown — no code blocks needed in the new block body. |
| A9 | `bin/render-prompt-rc0-test.sh` cases G/H/I/J/K demonstrate the loopback-gating fixture pattern | **verified** | `bin/render-prompt-rc0-test.sh:301-400`. Each case: (a) creates `ISSUE_DIR_<X>`; (b) writes `stage-summary-reviewing.md` with a per-case literal sentinel string; (c) invokes `render-prompt.sh implementing <issue>` with `PIPELINE_LOOPBACK_SOURCE=<value>`; (d) asserts via `grep -qF "$LB_SENTINEL"` whether the sentinel appears in the rendered prompt. **Content anchor for inserting cases L/M/N:** the existing `# Case K:` block ends with `fi\n\nprintf '\n━━━ Summary ━━━\n...` at line ~402; cases L/M/N insert BEFORE the `printf '\n━━━ Summary ━━━` summary footer. The agent re-locates the footer by literal string match. |
| A10 | `bin/render-prompt-rc0-test.sh` cases G/H/I caveat (line 339-342) names the prose-quotes-sentinel gotcha that case-L/M/N tests must respect | **verified** | `bin/render-prompt-rc0-test.sh:339-342`: "we deliberately do NOT also assert the literal sentinel string is present in $out_h — AGENT_PROMPTS.md's prose quotes the literal sentinel … which would make any such grep always-true". This is why L/M/N use DISTINCT per-case sentinel strings injected into the fixture file, then grep for those sentinels. |
| A11 | `bin/agent-prompts-content-test.sh:91-101` is the canonical §3 content-pin shape (`grep -qF '1. {progress_md_path}'`) | **verified** | `bin/agent-prompts-content-test.sh:91-101` (read directly). New pin uses identical `printf '%s\n' "$s3" \| grep -qF '<phrase>'` shape. Content anchor for insertion: the `# ─── ENG-108: §3 read-first list …` comment block ends with its `fi` at line 101, immediately followed by the `# ─── ENG-109: …` block. The ENG-140 pin inserts as a sibling block, anchored BEFORE the `# ─── ENG-109:` comment. |
| A12 | `bin/common.sh::issue_dir` composes `$PROJECT_STATE_DIR/$issue` (stable contract, used by both the review-findings binding and the new qa-findings binding) | **verified** | `bin/common.sh:68-72`. |
| A13 | The QA agent writes `$(issue_dir)/stage-summary-qa.md` on every QA dispatch (overwrite-on-every-dispatch contract per CLAUDE.md §"Stage summary file") | **verified** | `AGENT_PROMPTS.md:1453` (read directly) — §6's final step writes the stage summary at `{stage_summary_path}` which resolves to `stage-summary-qa.md` for the qa stage via `_resolve_stage_summary_path` (`bin/render-prompt.sh:228-229`). |
| A14 | `_clear_current_stage_slots` preserves `stage-summary-qa.md` across qa→implementing transitions | **verified** | `bin/run-stage.sh:929-939` (read directly); comment at 926-930 explicitly names `stage-summary-OTHER.md` as preserved for forward+loopback reads. ENG-140 reads `stage-summary-qa.md` on an implementing dispatch — qa is "OTHER" relative to implementing. |
| A15 | `_resolve_review_findings` resolver pattern is byte-for-byte the template the new resolver copies (three text substitutions: `REVIEW`→`QA`, `reviewing`→`qa`, `review`→`qa run`) | **verified** | brainstorm §10.6 "Feasibility persona" enumerates the three substitutions. Exact diff target captured in Task 2's checkbox step. |
| A16 | The `eng-140` slug-token is present in this plan doc's basename, satisfying `partition_dirty_paths::D-004` in-scope bucketing for `docs/plans/` writes | **verified** | basename: `2026-05-17-eng-140-implement-prompt-3-add-qa-findings-token-qa-loopback-handling-block.md` contains literal `eng-140`. |

**Branch-base freshness pin:** `HEAD..origin/main` non-empty at plan time; origin/main = `1533f00`. Plan compensates via Task 0 (rebase) + content-anchored Edit boundaries. If post-rebase the content anchors named above no longer exist (e.g. a sibling commit renamed `_resolve_review_findings` or removed the §3 review-loopback block), implement halts with `verdict halt --reason agent-blocked` and names the missing anchor.

## 3. File Structure

| File | Change | Status |
|---|---|---|
| `bin/render-prompt.sh` | Modify — add `qa_findings=_resolve_qa_findings` to PROMPT_RESOLVERS; add `_resolve_qa_findings` function body; bind `_RENDER_QA_FINDINGS_PATH` in `main()`. | modified |
| `AGENT_PROMPTS.md` | Modify — insert new "QA → implement loopback handling" block in §3 between the existing review-loopback `{review_findings}` token line and the `Build → implement loopback handling` header line. | modified |
| `bin/render-prompt-rc0-test.sh` | Modify — add cases L (qa source + qa-file present → findings inlined), M (building source + qa-file present → sentinel/no leak), N (reviewing source + qa-file present → sentinel/no leak), plus regression-intent assertion that `{review_findings}` continues to resolve to its sentinel under `PIPELINE_LOOPBACK_SOURCE=qa`. | modified |
| `bin/agent-prompts-content-test.sh` | Modify — pin §3 contains the distinctive phrase `QA → implement loopback handling`. | modified |
| `docs/plans/2026-05-17-eng-140-implement-prompt-3-add-qa-findings-token-qa-loopback-handling-block.md` | New (this file). | new |
| `docs/plans/2026-05-17-eng-140-implement-prompt-3-add-qa-findings-token-qa-loopback-handling-block.json` | New — schema-v1 plan contract sibling. | new |

**Out of scope (NOT modified):** `bin/run-stage.sh`, `bin/verdict-handler.sh`, `bin/dispatch.sh`, `bin/common.sh`, `bin/linear.sh`, `AGENT_PROMPTS.md §6` (QA prompt), any `learned-rules/` file. Per brainstorm D-007 + Linear ticket "Proposed scope" point 3 + "Not in scope" list. The implement agent MUST NOT touch these files; scope-check halts on the slightest deviation.

## 4. API Contract

No new API surface. The harness has no FE↔BE API surface; render-prompt.sh is a bash script + token registry, not an API.

## 5. Backend Tasks

### Task 0: Rebase onto origin/main

- `depends_on: []`
- `touches: (git history only — no file edits)`
- [ ] Run `git fetch origin main` then `git rebase origin/main` in the worktree. Resolve any conflicts in files listed in §3 File Structure using the post-rebase `bin/scope-check.sh::is_benign` rules (lockfile-class benign by construction). If a conflict touches one of the content anchors named in Assumption Inventory (A2, A3, A6, A9, A11), STOP and halt with `verdict halt --reason agent-blocked` naming the conflicting upstream commit — the brainstorm should be re-validated against the new main, not patched.
- [ ] `git push --force-with-lease origin {branch_name}` — required because the rebase rewrites the published history.
- [ ] After rebase, re-verify each content anchor named in Assumption Inventory survived: `grep -n '_resolve_review_findings' bin/render-prompt.sh` (A2/A3), `grep -n 'Build → implement loopback handling' AGENT_PROMPTS.md` (A6), `grep -n '# Case K:' bin/render-prompt-rc0-test.sh` (A9), `grep -n '# ─── ENG-108:' bin/agent-prompts-content-test.sh` (A11). Each must return at least one hit; zero hits = halt with `agent-blocked`.

### Task 1: Add `_resolve_qa_findings` resolver to `bin/render-prompt.sh`

- `depends_on: [0]`
- `touches: bin/render-prompt.sh::PROMPT_RESOLVERS, bin/render-prompt.sh::_resolve_qa_findings (new), bin/render-prompt.sh::main`
- [ ] **Registry entry.** Locate the literal line `review_findings=_resolve_review_findings` inside the `PROMPT_RESOLVERS='...'` heredoc (~line 54). Insert `qa_findings=_resolve_qa_findings` on the line immediately AFTER `review_findings=_resolve_review_findings`. Content anchor — the `review_findings=` line is unique in the file; the new line preserves alphabetical-ish grouping with the other findings token.
- [ ] **Resolver body.** Locate the closing `}` of `_resolve_review_findings` (~line 276). Locate the next non-blank comment block starting `# Without a structured plan.json sibling, ...` (the comment that opens `_resolve_plan_json`). Insert the new resolver BETWEEN these two anchors — AFTER the closing `}` of `_resolve_review_findings` and BEFORE the `# Without a structured plan.json sibling` comment, separated by one blank line above and one below. Resolver body (byte-for-byte from brainstorm D-001 / §10.6):

```bash
# ENG-140: per-issue prior-qa summary, mirror of _resolve_review_findings.
# Preserved across qa → implementing transitions by _clear_current_stage_slots
# (only the CURRENT stage's summary is cleared). Resolver reads this path into
# the {qa_findings} token for the implementing prompt; other stages emit the
# same token but typically don't reference it. Negative gate on
# PIPELINE_LOOPBACK_SOURCE != "qa" prevents stale qa findings leaking into
# review-loopback / build-loopback / fresh-from-planning dispatches.
_resolve_qa_findings() {
  local p="${_RENDER_QA_FINDINGS_PATH-}"
  local source="${PIPELINE_LOOPBACK_SOURCE-}"
  if [[ -n "$source" && "$source" != "qa" ]]; then
    printf '(no prior qa run for this issue — this dispatch is not a qa-loopback)'
    return 0
  fi
  if [[ -n "$p" && -s "$p" ]]; then
    cat "$p"
  else
    printf '(no prior qa run for this issue — this dispatch is not a qa-loopback)'
  fi
}
```

- [ ] **main() binding.** Locate the literal line `_RENDER_REVIEW_FINDINGS_PATH="$review_findings_path"` (~line 487) inside `main()`. Insert two lines IMMEDIATELY AFTER this anchor: a local declaration `local qa_findings_path` and its assignment `qa_findings_path="$(issue_dir "$issue_id")/stage-summary-qa.md"`, plus the bind `_RENDER_QA_FINDINGS_PATH="$qa_findings_path"`. Place the local declaration sibling to the existing `local review_findings_path` declaration (~lines 467-468) for readability; the bind line goes immediately after `_RENDER_REVIEW_FINDINGS_PATH=...` for resolver-ordering symmetry. Secret-handling pin: use `${VAR-}` single-dash empty fallback in the resolver — NEVER `${VAR:-FALLBACK}` — per ENG-46 (none of these vars match `*KEY|*TOKEN|*SECRET|...`, but secret-probe-lint enforces the rule uniformly).
- [ ] Re-run `bash bin/render-prompt-test.sh` (the test the implement agent has allowlisted) to confirm the registry parses, the resolver compiles, and the new token validates against the residual-scan guard.

### Task 2: Insert "QA → implement loopback handling" block into `AGENT_PROMPTS.md` §3

- `depends_on: [0]`
- `touches: AGENT_PROMPTS.md §3`
- [ ] **Block placement.** Locate the literal token line `{review_findings}` inside §3 (~line 750, immediately after the literal header `Reviewing summary (verbatim):`). Locate the literal header line `Build → implement loopback handling (MANDATORY when present):` (~line 752). Insert the new block BETWEEN these two anchors — AFTER the `{review_findings}` token line + its trailing blank line, BEFORE the `Build → implement loopback handling` header. The new block sits as a peer to the review-loopback block and the build-loopback block. Must NOT introduce a column-0 ` ``` ` fence (A8).
- [ ] **Block body** (Markdown prose, no fenced code, derived directly from brainstorm D-002 / D-003 / D-004):

```
QA → implement loopback handling (MANDATORY when present — ENG-140):

The orchestrator inlines the prior QA stage's summary below as `{qa_findings}` ONLY when the most-recent transition into this dispatch was `from=qa to=implementing`. When the value reads `(no prior qa run for this issue — this dispatch is not a qa-loopback)`, this is one of:

  - a fresh dispatch forward from planning, OR
  - a review-loopback (handled by the review block above), OR
  - a build-loopback (handled by the build block below),

and the rest of THIS block does not apply. Otherwise:

  1. Treat every P0 finding in the QA summary as a contract you MUST close by code commits on `{branch_name}` before exit. §6's P0 set (missing tests on a new code path, regression-intent violations, weak assertions on Failure Mode → Test Map rows, missing boundary/failure-mode/concurrency tests) is the exhaustive list — every entry in `{qa_findings}` tagged P0 must be addressed. Non-P0 findings are best-effort: close them when cheap, defer with a one-line rationale in the stage-summary Notes otherwise.
  2. For each closed P0 finding, the commit message MUST cite the failing test name (e.g. `fix(ENG-N): close P0 — <failing-test-name> now passes`). If the finding cited a `qa-patterns.md` entry as the explanation for a flake, also cite the qa-pattern locator in a trailer (e.g. `Fixes: docs/knowledge/qa-patterns.md:qa-P-0042`). The next QA dispatch grep-cross-checks the test name against the commit log; an unbacked `verdict pass` results in a loopback.
  3. Do NOT post `verdict pass` if any P0 finding remains uncommitted. The branch's git log is the only authoritative record of work done — re-emitting the prior `completion/implementing/{issue_id}` body via the overwrite-on-every-dispatch contract without making fresh commits is the same NOOP-loopback failure mode the review-loopback block guards against.
  4. **Scope-drift restraint — a QA finding is NOT authorization to expand scope.** The brainstorm and plan are the only authorization surfaces for behavior in this PR. If addressing a finding would require behavior the brainstorm/plan did not authorize — a new defensive layer, a new contract field, a new validation outcome, a new metric — STOP and file it as a follow-up via `<!-- meta: metric name=plan_gap -->` with the finding text and the brainstorm/plan section that should have covered it.
     - Carve-out: fixing a real bug that the QA test exposed IS in scope by construction. The plan's Failure Mode → Test Map enumerates the bugs each test guards against; if a test is failing because the code is wrong AND the test correctly encodes the plan's expected behavior, the fix is authorized even if the brainstorm did not enumerate the specific code path. Distinguish "the test reveals a bug in code the plan told you to write" (FIX IT) from "the QA agent wrote an adversarial test exposing a contract the plan did not specify" (FILE `plan_gap`, do NOT silently expand contract).
     - Concrete failure (mirror of the ENG-123 review-loopback example): an adversarial QA test asserting a 404 response shape the plan never specified is NOT authorization to add 404-shape code paths. QA's adversarial-testing budget (§6 step 5) is exploratory; its tests become specification only via a `plan_gap` follow-up.

QA summary (verbatim):

{qa_findings}
```

- [ ] After insertion, run `grep -c '^```' AGENT_PROMPTS.md` to confirm the column-0 fence count is unchanged from pre-edit (no new fences introduced). Run `bash bin/render-prompt-test.sh` to confirm the fence-count check in `extract_block` still passes for §3.

### Task 3: Add cases L/M/N + regression-intent assertion to `bin/render-prompt-rc0-test.sh`

- `depends_on: [1, 2]`
- `touches: bin/render-prompt-rc0-test.sh (cases L, M, N, plus regression-intent assertion)`
- [ ] **Locate insertion point.** Content anchor: the `# Case K:` block ends with its closing `fi` and a blank line, immediately followed by the literal line `printf '\n━━━ Summary ━━━\nPASS: %d / FAIL: %d\n' "$PASS" "$FAIL"`. The new cases insert BETWEEN the `fi` ending case K and the `printf '\n━━━ Summary ━━━` summary footer (~line 402 pre-rebase; locate by literal string match post-rebase).
- [ ] **Case L (positive control — qa source + qa-file present → findings inlined).** Mirror case G shape (`bin/render-prompt-rc0-test.sh:301-319`) with these substitutions: `ISSUE_DIR_G` → `ISSUE_DIR_L`; sentinel `SENTINEL-REVIEW-FINDINGS-LOOPBACK-GATE-CASE-G-9281` → `SENTINEL-QA-FINDINGS-LOOPBACK-GATE-CASE-L-9281`; fixture file `stage-summary-reviewing.md` → `stage-summary-qa.md`; `PIPELINE_LOOPBACK_SOURCE=reviewing` → `PIPELINE_LOOPBACK_SOURCE=qa`; `ENG-87R6X-G` → `ENG-87R6X-L`. Assert: `grep -qF "$LB_SENTINEL"` succeeds on rendered output. Pass message names ENG-140.
- [ ] **Case M (no-leak — building source + qa-file present → sentinel).** Mirror case H shape (`:321-342`) with: dir `ENG-87R6X-M`, sentinel `SENTINEL-QA-FINDINGS-LOOPBACK-GATE-CASE-M-9281`, fixture `stage-summary-qa.md`, `PIPELINE_LOOPBACK_SOURCE=building`. Assert: `grep -qF "$LB_SENTINEL"` FAILS on rendered output. Mirror the existing `# Note:` caveat block at lines 339-342 verbatim — the AGENT_PROMPTS.md §3 QA-loopback block prose includes the sentinel literal as documentation, which would make any presence-of-literal-sentinel assertion always-true.
- [ ] **Case N (no-leak — reviewing source + qa-file present → sentinel).** Mirror case I shape (`:344-361`) with: dir `ENG-87R6X-N`, sentinel `SENTINEL-QA-FINDINGS-LOOPBACK-GATE-CASE-N-9281`, fixture `stage-summary-qa.md`, `PIPELINE_LOOPBACK_SOURCE=reviewing`. Assert: `grep -qF "$LB_SENTINEL"` FAILS on rendered output.
- [ ] **Regression-intent assertion (AC-2 from Linear ticket).** Inside case L's fixture (after writing `stage-summary-qa.md`), ALSO write `stage-summary-reviewing.md` with a distinct sentinel `SENTINEL-REVIEW-FINDINGS-CASE-L-REGRESSION-9281`. After capturing `$out_l`, add a SECOND assertion: `grep -qF "$REGRESSION_SENTINEL" <<<"$out_l"` must FAIL. Pass message: `"ENG-140 case L regression: PIPELINE_LOOPBACK_SOURCE=qa does NOT leak stale review-findings (5ebae80 still gates correctly)"`. This is the AC-2 verifier — confirms the existing `_resolve_review_findings` gate still emits the sentinel when source=qa.
- [ ] Run `bash bin/render-prompt-rc0-test.sh` standalone (the agent has it allowlisted via `Bash(bash bin/render-prompt-test.sh:*)` per the profile — verify via `bash -n` first). All cases A–N must pass.

### Task 4: Add §3 content pin to `bin/agent-prompts-content-test.sh`

- `depends_on: [2]`
- `touches: bin/agent-prompts-content-test.sh`
- [ ] **Locate insertion point.** Content anchor: the `# ─── ENG-108: §3 read-first list has {progress_md_path} at position 1 ───` comment block (~lines 91-101) ends with its closing `fi` line. The next block opens with `# ─── ENG-109: ...`. Insert the new ENG-140 pin block BETWEEN these — AFTER the ENG-108 block's closing `fi` + blank line, BEFORE the `# ─── ENG-109:` comment header.
- [ ] **Pin body** (byte-for-byte from brainstorm D-006C):

```bash
# ─── ENG-140: §3 contains the new QA → implement loopback block ───
# The implementing prompt MUST carry a QA-loopback handling block so that
# qa → implementing fail dispatches see the QA findings inline (via
# {qa_findings}) rather than discovering them via Linear/Read. Pin the
# distinctive header so a future edit that removes the block trips here.
if printf '%s\n' "$s3" | grep -qF 'QA → implement loopback handling'; then
  ok "§3 ENG-140: QA → implement loopback handling block present"
else
  nope "§3 ENG-140: QA → implement loopback handling block present" \
    "literal 'QA → implement loopback handling' header missing from §3 — has the QA-loopback block been removed or its header renamed?"
fi
```

- [ ] Run `bash bin/agent-prompts-content-test.sh` standalone; all prior pins plus the new one must pass.

### Task 5: Run the full gate suite + final TDD discipline check

- `depends_on: [1, 2, 3, 4]`
- `touches: (no file edits — gate suite invocation)`
- [ ] Run the profile's "Build & test gates" suite verbatim. The agent has 38 `bin/*-test.sh` patterns allowlisted; the relevant subset for ENG-140 is `render-prompt-test.sh`, `agent-prompts-content-test.sh`, `verdict-handler-test.sh`, `dispatch-test.sh`, `run-stage-test.sh`. Plus `bash bin/secret-probe-lint.sh bin/render-prompt.sh` to confirm the new `${VAR-}` usage stays compliant. Plus `bash .githooks/pre-commit` before the final commit.
- [ ] **TDD discipline.** Per the §3 TDD checklist: each task with a Failure-Mode-Map row must have a `test(ENG-140): <task summary>` commit BEFORE the corresponding `feat(ENG-140): <task summary>` commit. Specifically: Task 3 (cases L/M/N) is the test commit for Task 1 (resolver) AND Task 2 (prompt block); Task 4 (content pin) is a test-only commit. Commit order: (a) Task 3 + Task 4 test commits first (RED — tests fail because production code not yet written); (b) Task 1 + Task 2 implementation commits (GREEN — tests pass). Minimum 2 commits across the production-code changes; the review stage counts test-first order.
- [ ] **Commit-message convention.** Every commit must cite `ENG-140` in the subject. The failing-test-name trailer added by the new §3 block applies prospectively (the next implement dispatch on a qa-loopback uses it); it does NOT retroactively apply to ENG-140's own commits since ENG-140 itself is not a qa-loopback target.

## 6. Frontend Tasks

No frontend tasks. The harness has no UI component and no UI agent dispatches on harness-self targets. Per the project profile, the `ui` stage's allowlist is `(none)` and the harness self-hosts no frontend.

## 7. Failure Mode → Test Map

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
|---|---|---|---|---|
| Stale QA findings leak into a build-loopback dispatch | qa→implementing fail loopback fires; later, build-loopback fires for the same issue. `stage-summary-qa.md` still on disk from the prior qa-loopback. | `_resolve_qa_findings` sees `PIPELINE_LOOPBACK_SOURCE=building` and emits the sentinel; the rendered prompt does NOT contain the stale qa findings. | unit | `render-prompt-rc0-test.sh` Case M (ENG-140) |
| Stale QA findings leak into a review-loopback dispatch | qa→implementing fail loopback fires; later, reviewing→implementing fires. `stage-summary-qa.md` still on disk. | Resolver sees `PIPELINE_LOOPBACK_SOURCE=reviewing` and emits the sentinel; rendered prompt does NOT contain stale qa findings. | unit | `render-prompt-rc0-test.sh` Case N (ENG-140) |
| QA findings missing from prompt on a genuine qa-loopback (the bug ENG-140 fixes) | qa→implementing fail loopback fires; `stage-summary-qa.md` present; `PIPELINE_LOOPBACK_SOURCE=qa`. | Resolver inlines file content into `{qa_findings}`; the rendered prompt contains the file's literal sentinel. | unit | `render-prompt-rc0-test.sh` Case L (ENG-140) |
| Stale review findings leak into a qa-loopback (regression of `5ebae80`) | qa→implementing loopback fires; `stage-summary-reviewing.md` and `stage-summary-qa.md` both present. | `_resolve_review_findings` (UNCHANGED — already gated) emits its sentinel under `PIPELINE_LOOPBACK_SOURCE=qa`; rendered prompt does NOT contain stale review findings. | unit | `render-prompt-rc0-test.sh` Case L regression-intent assertion (ENG-140, second grep against the same `$out_l`) |
| §3 QA-loopback block silently removed by a future refactor | A future commit removes/renames the `QA → implement loopback handling` header. | `agent-prompts-content-test.sh` ENG-140 pin trips with `nope` and a descriptive message naming the missing header. | unit | `agent-prompts-content-test.sh` ENG-140 pin |
| Render-time fence-count regression in §3 from the prose insertion | New block accidentally introduces a column-0 ` ``` ` fence. | `extract_block` dies with the fence-count mismatch message; `render-prompt-test.sh` fails. | unit | `render-prompt-test.sh` (existing — exercises the fence check) |
| Sentinel string `_resolve_qa_findings` emits is grep-true against §3 prose itself (false-positive) | A future test author adds a presence-of-sentinel assertion in cases M/N. | The `# Note:` caveat block in cases M/N (mirrored from cases H/I) documents the gotcha so the test stays a presence-of-FIXTURE-sentinel check, not a presence-of-PROSE-sentinel check. | doc-pin | inline `# Note:` comment in Case M/N (no separate test — same docs+convention discipline as cases H/I) |
| Adversarial-payload prompt-injection via `stage-summary-qa.md` content | A buggy QA agent writes attacker-controlled text into `stage-summary-qa.md`. | Same risk surface as `{review_findings}` today — resolver inlines as-is. No new threat ceiling. Out of scope for ENG-140 per brainstorm §10.2. | (no new test) | covered by sub-agent-debris discipline (CLAUDE.md ENG-100) |

## 8. Test Strategy

**Unit (the primary surface):**

- `bin/render-prompt-rc0-test.sh` cases L, M, N cover the three legal `PIPELINE_LOOPBACK_SOURCE` values × the qa-file-present axis. Mirrors the cases G/H/I/J/K precedent for the review-loopback resolver — fixture pattern + per-case literal sentinels + the prose-quotes-sentinel caveat applies symmetrically.
- Case L's regression-intent assertion (second grep on `$out_l`) is the AC-2 verifier — confirms `_resolve_review_findings` (unchanged) continues to emit its sentinel when `PIPELINE_LOOPBACK_SOURCE=qa`. Failing this assertion indicates `5ebae80` regressed.
- `bin/agent-prompts-content-test.sh` adds one content pin for `QA → implement loopback handling`. Mirrors the ENG-108 pin shape; pins the new block's distinctive prose so a silent future removal trips here.

**Integration:** None new. The PIPELINE_DRY_RUN=1 integration path through `run-stage.sh` does not exercise a render of the implementing prompt against a fixture-realistic `stage-summary-qa.md` — the unit-level coverage at `render-prompt-rc0-test.sh` is the canonical contract for the resolver, and `run-stage.sh` is UNCHANGED per D-007.

**Smoke:** None new. `dry-run.sh` already exercises the full render pipeline end-to-end; adding a smoke-level fixture for the new resolver would duplicate the unit-level coverage without adding signal.

**Adversarial:** No new adversarial test file. The brainstorm §10.2 (Security persona) confirms the risk surface is identical to `_resolve_review_findings` today; adding a fresh adversarial test for prompt-injection via `stage-summary-qa.md` would be a generalization-of-existing-risk test that belongs in a Security-hardening ticket, not ENG-140.

**Test-gate closure sweep.** Per the self-review feasibility persona's mandate: every token, symbol, or substring this plan REMOVES from production code must be checked against sibling test files. **ENG-140 removes nothing** — every change is additive (new resolver entry, new resolver body, new global binding, new prompt block, new tests, new content pin). No sibling test files contain a soon-to-be-removed token. Closure sweep: clean (no sibling test edits required beyond Tasks 3-4).

**Failure-mode coverage:** Every row of §7's Failure Mode → Test Map binds to either an L/M/N test, the regression assertion, the ENG-140 content pin, or an existing convention-doc (the `# Note:` caveat in case M/N). No row is unbound.

