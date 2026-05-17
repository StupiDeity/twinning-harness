---
linear: ENG-140
title: implement prompt §3 — {qa_findings} token + qa→implementing loopback block
date: 2026-05-17
status: draft
---

# ENG-140 — implement prompt §3: {qa_findings} token + qa-loopback handling block

## 1. Overview

§3 (Implementation Agent) of AGENT_PROMPTS.md currently has **two**
loopback-handling blocks:

| Loopback | Source stage | Block | Inputs to implementer |
|---|---|---|---|
| Review-loopback | `reviewing` | §3 "Review → implement loopback handling" at `AGENT_PROMPTS.md:729-750` | `{review_findings}` token (file content from `$(issue_dir)/stage-summary-reviewing.md`, loopback-source-gated) |
| Build-loopback | `building` | §3 "Build → implement loopback handling" at `AGENT_PROMPTS.md:752-763` | Linear `<!-- meta: metric name=merge_conflict -->` marker (agent reads via `bash bin/linear.sh get-comments`) |

The third legal loopback into implementing — **qa → implementing** —
has no block. `bin/verdict-handler.sh:36` carries the loopback row
`qa|implementing|`, and §6's Decision-path B (`AGENT_PROMPTS.md:1446`)
explicitly emits `bash bin/pipeline.sh event {issue_id} verdict fail
--target implementing` on genuine QA failures. When that fires today
the implementer sees:

- `{review_findings}` → sentinel string `(no prior review for this issue — this dispatch is not a review-loopback)` (correct after `5ebae80`; the resolver at `bin/render-prompt.sh:264-276` gates on `PIPELINE_LOOPBACK_SOURCE=qa` → emits sentinel).
- No explicit "you're in a qa-loopback" prose. The agent has to discover the QA findings via Linear (`completion/qa/{issue_id}` comment) or via `Read` on `$(issue_dir)/stage-summary-qa.md`. The stage-summary file survives across the qa→implementing transition because `_clear_current_stage_slots` (`bin/run-stage.sh:931-939`) only clears the CURRENT stage's summary.
- No QA-loopback-specific severity hierarchy, commit-message-trailer expectation, or scope-drift restraint.

ENG-140 closes the gap by mirroring the review-loopback shape:

1. **Token surface.** `bin/render-prompt.sh` gains a `{qa_findings}` token wired through a new `_resolve_qa_findings` resolver, gated on `PIPELINE_LOOPBACK_SOURCE=qa` (the inverse gate of `_resolve_review_findings`). Resolves to the content of `$(issue_dir)/stage-summary-qa.md` when the gate fires; resolves to a sentinel string otherwise.
2. **Prompt surface.** §3 gains a "QA → implement loopback handling" block parallel to the review-loopback block: severity hierarchy (P0 vs lower), commit-trailer expectation (cite test name or qa-pattern entry), scope-drift restraint (the `24a0631` clause), and the `{qa_findings}` token splice point.
3. **Test surface.** `bin/render-prompt-rc0-test.sh` cases L–N mirror the G/H/I shape — file present + each `PIPELINE_LOOPBACK_SOURCE` value (`qa`, `building`, `reviewing`) for the `{qa_findings}` token. `bin/agent-prompts-content-test.sh` pins distinctive substrings from the new §3 block.

Three non-obvious design problems the brainstorm has to resolve:

- **A. Severity hierarchy.** QA's failure-mode taxonomy is different from review's. Reviewer findings come tagged `[critical]`/`[major]`/`[minor]`/`[nit]` (§3 review-loopback block, line 739). QA findings come from §6's "P0 findings" set: missing tests, regression-intent violations, weak assertions on Failure Mode → Test Map rows, missing boundary/failure-mode/concurrency tests per new code path. The brainstorm must decide whether to map QA findings onto the same `[critical]`/`[major]` rubric or to use the existing P0 vocabulary directly.
- **B. Scope-drift restraint.** The `24a0631` clause added to the review-loopback block is load-bearing (it prevented the ENG-123 iter-4-6 $50 burn). The QA-loopback block needs an analogous clause. But QA findings often DO legitimately require new code (the regression test is failing because the regression bug is real and there's no fix yet). The brainstorm must distinguish "QA found a real bug — the fix is by definition new code, and that's authorized" from "QA wrote an adversarial test that exposed a contract the brainstorm did not specify; expanding the contract on QA's say-so is drift."
- **C. Commit-message convention.** The review-loopback block (line 740) mandates the commit cite the finding's `file:line` locator. The QA-loopback equivalent must adapt — QA findings cite **test names** (`failing-test-name@first-line-of-panic-or-assert-message` per §6 step 6, line 1413) and/or **qa-patterns.md entries**. The brainstorm must pin the convention so the next QA dispatch can cross-check the commit log.

## 2. Decisions

- **D-001. Inline-content delivery (not path-token), gated on `PIPELINE_LOOPBACK_SOURCE=qa`.** Add `qa_findings=_resolve_qa_findings` to `PROMPT_RESOLVERS` (`bin/render-prompt.sh:41-57`); add `_resolve_qa_findings` body mirroring `_resolve_review_findings` (`bin/render-prompt.sh:264-276`); bind `_RENDER_QA_FINDINGS_PATH="$(issue_dir "$issue_id")/stage-summary-qa.md"` in `main()` (sibling to `_RENDER_REVIEW_FINDINGS_PATH` at `:487`).

  Concrete resolver shape (byte-for-byte structural copy of `_resolve_review_findings`):

  ```bash
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

  *Reference to constraint:* CLAUDE.md "Don't add features, refactor, or introduce abstractions beyond what the task requires." The review-findings resolver is the exact existing precedent; copying its shape adds zero new abstraction.

  *Reference to constraint:* the Linear ticket's "Proposed scope" point 1 names this approach verbatim: "Reads `$(issue_dir)/stage-summary-qa.md` analogous to today's review_findings resolver."

  *Rejected alternative — path-token + `Read` (the ENG-108 progress.md shape):* rejected because (a) the agent already has the path via `Read` on `$(issue_dir)/stage-summary-qa.md` if it goes hunting; the question is whether the prompt should TELL it to look. Inlining the content makes the prompt self-contained — same justification as the review-loopback block; (b) `stage-summary-qa.md` is bounded in size: it's one dispatch's findings, cleared and rewritten on every QA re-dispatch (per the §0 overwrite-on-every-dispatch contract). The progress.md token-budget concern that pushed ENG-108 to path-token doesn't apply here (progress.md accumulates across the issue's entire lifetime; stage-summary-qa.md is one dispatch's snapshot); (c) symmetry with `{review_findings}` — both loopback inputs are inline content, both gated on `PIPELINE_LOOPBACK_SOURCE`. Diverging only for `{qa_findings}` raises cognitive load with no offsetting gain.

  *Rejected alternative — no new resolver; instruct the agent to `Read` `$(issue_dir)/stage-summary-qa.md` by absolute path:* rejected because (a) the agent does NOT know `$PROJECT_STATE_DIR` (it's a harness env var, not surfaced in the prompt), exactly the same drift-class ENG-79 fixed; (b) the prompt would need a path-shaped token anyway — so we'd add `{qa_findings_path}` to the registry, which is more work than `{qa_findings}` (path-shape needs a `_RENDER_*` global + resolver + main() binding, content-shape needs the same plus the inline `cat`). Path-shape is strictly more code, not less.

  *Rejected alternative — read the QA findings from the Linear `completion/qa/{issue_id}` comment instead of disk:* rejected because (a) the Linear comment goes through the dispatch-id auto-inject and lane-fence chokepoints; reading it back is a multi-hop indirection vs. a `Read` on the local file; (b) the `completion/<stage>/<issue>` comment uses `add-or-update-comment` and shows the latest body verbatim — but the on-disk file IS that body (orchestrator copies disk → Linear). Reading disk is the canonical first read; Linear is the publication channel.

- **D-002. Severity hierarchy: use QA's own P0 vocabulary directly; do NOT map onto `[critical]`/`[major]`.** The §3 qa-loopback block carries:

  ```
    1. Treat every P0 finding in the QA summary as a contract you MUST
       close by code commits on {branch_name} before exit. The §6 P0
       set (missing tests, regression-intent violations, weak
       assertions on Failure Mode → Test Map rows, missing
       boundary/failure-mode/concurrency tests per new code path)
       is exhaustive — every line in {qa_findings} flagged P0 must be
       addressed.
  ```

  *Reference to constraint:* §6 (QA Agent) at `AGENT_PROMPTS.md:1429` defines "Zero P0 findings from §1–5" as the QA pass gate. P0 is the existing QA vocabulary; introducing a translation layer (`[critical] = P0`, `[major] = ??`) would create a mismatch and force the implementer to interpret a mapping the QA agent never emits.

  *Reference to constraint:* CLAUDE.md "Don't add features, refactor, or introduce abstractions beyond what the task requires." A new severity rubric for QA-loopback is unnecessary abstraction when QA's existing P0/non-P0 binary is sufficient.

  *Rejected alternative — adopt the review-loopback `[critical]`/`[major]`/`[minor]`/`[nit]` rubric for symmetry:* rejected because (a) QA does not currently emit those tags in the §6 prompt — adding them would require a §6 edit (out of scope per the Linear ticket's "Proposed scope" which scopes to §3 + render-prompt.sh); (b) QA's finding types don't map cleanly onto reviewer severity (a missing concurrency test is not "minor" — it's a coverage gap that §6 already calls P0); (c) the implementing agent's behavior on a QA-loopback is qualitatively different from a review-loopback. A reviewer says "you wrote code X; consider Y instead." A QA agent says "you wrote code X; the test for X is missing or weak." The fix shape is more constrained — write the test, then fix the bug if the test reveals one. A four-tier severity rubric is over-specified for that.

  *Rejected alternative — invent a QA-specific severity rubric (`[bug]`/`[coverage]`/`[regression]`):* rejected on two counts: (a) it requires a §6 edit (out of scope); (b) it forces the implementer to apply different rules for QA-loopback vs review-loopback, when the underlying behavior (close every must-close finding before exit) is the same.

- **D-003. Scope-drift restraint: the `24a0631` clause applies verbatim with the addition of a QA-specific "fixing a real bug is in-scope by construction" carve-out.** The §3 qa-loopback block carries:

  ```
    5. Scope-drift restraint — a QA finding is NOT authorization to
       expand scope. The brainstorm and plan are the only authorization
       surfaces for behavior in this PR. If addressing a finding would
       require behavior the brainstorm/plan did not authorize — a new
       defensive layer, a new contract field, a new validation outcome,
       a new metric — STOP and file it as a follow-up via
       `<!-- meta: metric name=plan_gap -->` with the finding text and
       the brainstorm/plan section that should have covered it.
       - Carve-out: fixing a real bug that the QA test exposed IS in
         scope by construction. The plan's Failure Mode → Test Map
         enumerates the bugs the test must guard against; if the test
         is failing because the code is wrong (and the test correctly
         encodes the plan's expected behavior), the fix is authorized
         even if the brainstorm did not enumerate the specific code
         path. Distinguish: "the test reveals a bug in code the plan
         told you to write" (FIX IT) from "the QA agent wrote an
         adversarial test exposing a contract the plan did not
         specify" (FILE plan_gap, do NOT silently expand contract).
       - Concrete failure (mirror of the ENG-123 example in the
         review-loopback §3.5): an adversarial QA test asserting a
         404 response shape that the plan never specified is NOT
         authorization to add 404-shape code paths. The QA agent's
         adversarial-testing budget (§6 step 5) is exploratory; its
         tests can become specification only via a plan_gap follow-up.
  ```

  *Reference to constraint:* the ENG-123 iter-4-6 incident cited in the existing review-loopback §3.5 (line 746). The same drift class applies to QA-loopback: an adversarial test that exposes an unauthorised behavior is the QA-stage analog of a `[minor]` "you could also harden X" review finding.

  *Reference to constraint:* §6 step 5 (adversarial-testing budget at `AGENT_PROMPTS.md:1397-1410`) explicitly authorises QA to write tests "NOT in the plan's Failure Mode → Test Map." These tests are by construction NOT authorised by the plan; their failures are signals to expand the plan via `plan_gap`, not implicit license to expand contract via implementation.

  *Reference to principle:* CLAUDE.md "Don't add features, refactor, or introduce abstractions beyond what the task requires." Mirrors the same anti-pattern the `24a0631` clause guards against in the review-loopback path.

  *Rejected alternative — no scope-drift clause (let the implementer fix whatever QA flags):* rejected because (a) the ENG-123 incident is the load-bearing evidence that scope-drift on a "fix the finding" mandate burns operator time and cost; (b) the same failure mode is exactly as plausible on a qa-loopback as on a review-loopback — possibly more so, because QA's adversarial-test mandate (§6 step 5) generates novel breakage scenarios the plan did not anticipate.

  *Rejected alternative — port the review-loopback §3.5 clause verbatim, no carve-out:* rejected because (a) review findings rarely require new code (they're commentary on existing code); QA findings often DO require new code (a failing regression test means the regression code path is broken). A strict no-new-code-paths interpretation would dead-end the qa-loopback every time the bug requires a fix the brainstorm didn't name. The carve-out preserves the load-bearing scope restraint (no contract expansion) while permitting bug fixes within the plan's expected-behavior surface; (b) the carve-out is observably bounded — "the test correctly encodes the plan's expected behavior" — not a free pass.

- **D-004. Commit-message convention: cite the failing test name (and qa-pattern entry if applicable), not a file:line locator.** The §3 qa-loopback block carries:

  ```
    2. For each closed P0 finding, the commit message MUST cite the
       failing test name (e.g.
       `fix(ENG-N): close P0 - {failing-test-name} now passes`).
       If the finding cited a qa-patterns.md entry as the explanation
       for a flake, the commit must also cite the qa-pattern locator
       (e.g.
       `Fixes: docs/knowledge/qa-patterns.md:qa-P-0042`).
       The next QA dispatch grep-cross-checks the test name against
       the commit log; an unbacked verdict pass results in a loopback.
  ```

  *Reference to constraint:* §6 step 6 (`AGENT_PROMPTS.md:1413`) defines the bug signature as `<failing-test-name>@<first-line-of-panic-or-assert-message>`. The test name is the load-bearing identifier QA already uses for dedup; mirroring it in the commit log keeps the linkage cheap to re-verify.

  *Reference to constraint:* §6 step 1 (`AGENT_PROMPTS.md:1378-1380`) mandates "When you later dismiss a failure as 'known flaky,' quote the `path:line` of the matching qa-patterns.md entry. A dismissal without citation is itself P0 (flakes aren't escape hatches)." Citing the qa-pattern locator in the commit message preserves the linkage if the implementer chose to address a finding by patching qa-patterns logic vs. patching the code under test.

  *Rejected alternative — file:line locator (the review-loopback convention):* rejected because QA findings don't have a single "file:line" — the failing test, the panic stack frame, and the code under test are three different file:line locators. Picking one is arbitrary and adds churn. The test name is unambiguous (each failing test has exactly one name) and matches QA's existing dedup signature.

  *Rejected alternative — no convention; let the implementer choose:* rejected because the review-loopback block establishes the precedent that loopback responses carry locator-trailers for cross-verification on the next dispatch. Skipping it for qa-loopback breaks symmetry and removes the cheap audit trail QA needs on the re-dispatch.

- **D-005. Block placement: between the existing review-loopback block (`AGENT_PROMPTS.md:729-750`) and the build-loopback block (`AGENT_PROMPTS.md:752-763`).** The QA-loopback block lives at lines 751–774-ish post-insertion. Both flanking blocks open with their `PIPELINE_LOOPBACK_SOURCE` sentinel check; placing QA between them preserves the read order (review → qa → build), which matches the pipeline's actual stage order.

  *Reference to constraint:* CLAUDE.md "Coherence with existing structure." The review-loopback block is the canonical loopback-shape; placing the qa-loopback block as its immediate neighbor invites direct comparison and makes drift between the two blocks visible to the next reader.

  *Rejected alternative — append after the build-loopback block:* rejected because (a) reads less naturally — review → build → qa is not the pipeline stage order; (b) the review-loopback block's last paragraph (line 745, the "If this dispatch is NOT a review-loopback" fall-through) explicitly names "qa → implementing fail loopback" as one of the non-review-loopback cases. Locating the qa-loopback block immediately after that fall-through clause is a coherent forward reference.

  *Rejected alternative — single combined "loopback handling" block covering all three sources:* rejected because (a) the build-loopback block has different shape (no findings file; it reads a Linear marker), and merging the three would muddy the prose; (b) two blocks already work; one big block is harder to surgically edit when a single loopback's contract changes (the `5ebae80` review-only gating change and the `24a0631` review-only scope-drift clause would have been more painful as merges into a combined block).

- **D-006. Test surface: cases L–N in `render-prompt-rc0-test.sh` + one §3 content pin in `agent-prompts-content-test.sh`. No new test files.** Cases:

  | # | Setup | Assert |
  |---|---|---|
  | L | `stage-summary-qa.md` present + `PIPELINE_LOOPBACK_SOURCE=qa` | rendered prompt contains the file's literal sentinel string (findings inlined) |
  | M | `stage-summary-qa.md` present + `PIPELINE_LOOPBACK_SOURCE=building` | rendered prompt does NOT contain the literal sentinel (resolver emits the sentinel string, stale qa findings filtered) |
  | N | `stage-summary-qa.md` present + `PIPELINE_LOOPBACK_SOURCE=reviewing` | rendered prompt does NOT contain the literal sentinel (qa findings filtered out of review-loopback) |

  Plus a regression-intent assertion (D-006R): with `PIPELINE_LOOPBACK_SOURCE=qa` AND `stage-summary-reviewing.md` present, the rendered prompt does NOT contain the review sentinel — confirms `5ebae80` still gates correctly under the new qa case.

  Content pin (D-006C): `agent-prompts-content-test.sh` asserts §3 contains the literal phrase `QA → implement loopback handling` (mirroring the ENG-108 pin shape at line 96).

  *Reference to constraint:* the harness convention "Tests are sibling shell scripts named `*-test.sh` in `bin/`" (CLAUDE.md). `render-prompt-rc0-test.sh` already exercises the loopback-source gating logic via cases G/H/I (`bin/render-prompt-rc0-test.sh:307-400`); cases L–N extend the same pattern.

  *Rejected alternative — new test file `render-prompt-qa-findings-test.sh`:* rejected on CLAUDE.md "Don't add features … beyond what the task requires." The ENG-105/ENG-139 cases land inline in `render-prompt-rc0-test.sh`; the parallel ENG-140 cases land in the same file.

  *Rejected alternative — integration test in `run-stage-test.sh`:* rejected because (a) `PIPELINE_DRY_RUN=1` short-circuits the actual `claude -p` call, so an integration test cannot observe agent behavior on the rendered prompt; (b) the contract under test is the resolver + token interpolation, which `render-prompt-rc0-test.sh` exercises directly.

- **D-007. Scope boundary: no changes to §6 (QA prompt), no changes to verdict-handler, no changes to run-stage's PIPELINE_LOOPBACK_SOURCE export.** Specifically:

  - `AGENT_PROMPTS.md §6` — UNTOUCHED. QA already emits `verdict fail --target implementing` correctly (line 1446); QA already writes the stage-summary file at `{stage_summary_path}` correctly (line 1453).
  - `bin/verdict-handler.sh` — UNTOUCHED. The `qa|implementing|` row at line 36 already accepts the transition.
  - `bin/run-stage.sh::_resolve_loopback_source` — UNTOUCHED. Returns `qa` correctly today on a qa-loopback (the existing tests confirm this via case I of `render-prompt-rc0-test.sh`, which exercises the same env-var export path).
  - `bin/run-stage.sh::_clear_current_stage_slots` (`:931-939`) — UNTOUCHED. `stage-summary-qa.md` is NOT the current-stage summary on an implementing dispatch, so it correctly survives.

  *Reference to constraint:* the Linear ticket's "Proposed scope" point 3 says verbatim: "`bin/run-stage.sh`: nothing — `PIPELINE_LOOPBACK_SOURCE` already exports per-dispatch."

  *Reference to principle:* CLAUDE.md "Ticket sizing rubric" §"Axis 1 — Subsystems touched." Touched: agent prompts (AGENT_PROMPTS.md §3), dispatch (render-prompt.sh resolver), tests (render-prompt-rc0-test.sh + agent-prompts-content-test.sh). Two subsystems by the rubric (tests subordinate to dispatch); one independent design decision (D-001 delivery mechanism); the rubric's "2 subsystems with one clearly subordinate → autonomy-safe IF the scope boundary is explicit in the ticket body" clause covers this.

## 3. Architecture (where code goes)

| Site | Change | Lines (approx.) |
|---|---|---|
| `bin/render-prompt.sh` | Add `qa_findings=_resolve_qa_findings` to `PROMPT_RESOLVERS` (line 41-57) | +1 |
| `bin/render-prompt.sh` | Add `_resolve_qa_findings()` body near `_resolve_review_findings` (after line 276) | +12 |
| `bin/render-prompt.sh` | Bind `_RENDER_QA_FINDINGS_PATH="$(issue_dir "$issue_id")/stage-summary-qa.md"` in `main()` (sibling to line 487) | +2 |
| `AGENT_PROMPTS.md` §3 | Insert "QA → implement loopback handling" block between the review-loopback fall-through (line 750) and the build-loopback header (line 752) | +30 |
| `bin/render-prompt-rc0-test.sh` | Cases L (qa source → findings inlined), M (building → sentinel), N (reviewing → sentinel), plus regression-intent assertion (line 400 onward) | +60 |
| `bin/agent-prompts-content-test.sh` | One pin: `§3 contains 'QA → implement loopback handling'` (mirroring line 96) | +6 |

Total: ~110 LOC across 3 production files (one .sh, one .md, plus 2 test files). Zero changes to `bin/common.sh`, `bin/run-stage.sh`, `bin/dispatch.sh`, `bin/verdict-handler.sh`, `bin/linear.sh`, `bin/scope-check.sh`, `bin/run-local-helpers.sh`, `bin/run-local.sh`, `bin/poll.sh`, `bin/classify-failure.sh`, `bin/metrics.sh`, `AGENT_PROMPTS.md §6`.

## 4. Data Flow

Pre-ENG-140, on a qa→implementing fail loopback:

1. QA agent dispatches; runs gates; finds genuine failures.
2. QA writes `$(issue_dir)/stage-summary-qa.md` (overwrite-on-every-dispatch contract).
3. QA emits `bash bin/pipeline.sh event {issue_id} verdict fail --target implementing` (line 1446).
4. Orchestrator transitions issue to `stage:implementing`, dispatches §3 implementing agent.
5. `bin/run-stage.sh:1416-1422` calls `_resolve_loopback_source` → returns `qa`; exports `PIPELINE_LOOPBACK_SOURCE=qa`.
6. `render-prompt.sh` renders §3:
   - `{review_findings}` → sentinel (correct after `5ebae80`).
   - **No `{qa_findings}` token in §3 — QA findings are not surfaced in the prompt.**
7. Implementing agent reads §3, sees no QA-specific instructions, falls through to the review-loopback block (which the sentinel correctly tells it doesn't apply), falls through to the build-loopback block (which the merge_conflict marker absence tells it doesn't apply), and proceeds as if a fresh forward dispatch — which is wrong.

Post-ENG-140, same flow:

1. QA agent dispatches; runs gates; finds genuine failures. (UNCHANGED)
2. QA writes `$(issue_dir)/stage-summary-qa.md` (UNCHANGED).
3. QA emits `verdict fail --target implementing` (UNCHANGED).
4. Orchestrator transitions and dispatches §3 (UNCHANGED).
5. `bin/run-stage.sh:1416-1422` exports `PIPELINE_LOOPBACK_SOURCE=qa` (UNCHANGED).
6. `render-prompt.sh` renders §3:
   - `_RENDER_QA_FINDINGS_PATH = $(issue_dir)/stage-summary-qa.md` (NEW).
   - `_resolve_qa_findings()` sees `PIPELINE_LOOPBACK_SOURCE=qa` AND file present → emits file content (NEW).
   - `{qa_findings}` in §3's new QA-loopback block resolves to the file content (NEW).
   - `{review_findings}` → sentinel (UNCHANGED — `5ebae80` still gates correctly).
7. Implementing agent reads §3, the new QA-loopback block routes its attention to the QA findings, applies the severity-hierarchy rule (close every P0), the commit-message convention (cite test name), and the scope-drift restraint (do not expand contract on adversarial-test mandate).

Resolver execution flow inside `bin/render-prompt.sh::main()`:

```
main(stage=implementing, issue=ENG-140)
  ↓
  _RENDER_REVIEW_FINDINGS_PATH = "$(issue_dir)/stage-summary-reviewing.md"
  _RENDER_QA_FINDINGS_PATH = "$(issue_dir)/stage-summary-qa.md"  ← NEW
  ↓
  resolve_block_tokens($block)
    ↓ extracts tokens via regex \{[a-z_]+\}
    ↓ for each token, _lookup_resolver returns the resolver function name
    ↓ calls the resolver
    ↓ "{qa_findings}" → _resolve_qa_findings()
        ↓ reads PIPELINE_LOOPBACK_SOURCE
        ↓ if != "qa" → sentinel (block content "this dispatch is not a qa-loopback")
        ↓ if == "qa" + file present → cat $_RENDER_QA_FINDINGS_PATH
        ↓ if == "qa" + file absent → sentinel
    ↓ "{review_findings}" → _resolve_review_findings() (UNCHANGED)
```

Both resolvers' sentinel strings are quoted verbatim in their corresponding §3 blocks (the blocks include a "When the value reads `(no prior … for this issue — this dispatch is not a …-loopback)`" fall-through), which means the cases-L/M/N tests must NOT assert the sentinel literal is present-or-absent (the AGENT_PROMPTS.md prose itself contains the sentinel as documentation). Tests use a distinct fixture-side sentinel string (`SENTINEL-QA-FINDINGS-LOOPBACK-GATE-CASE-L-9281` shape) for the present-case assertion — mirrors the case-G/H/I trick at `bin/render-prompt-rc0-test.sh:303,339-342`.

## 5. Error Handling

The new resolver follows the existing `_resolve_review_findings` failure shape:

- **`PIPELINE_LOOPBACK_SOURCE` unset.** Back-compat: emits file content if non-empty. Preserves debug renders, dry-run.sh, and any caller outside `bin/run-stage.sh` that doesn't set the env var. The implementing render in production always sets it, so this branch is only exercised by tests + manual debugging.
- **`PIPELINE_LOOPBACK_SOURCE != qa`.** Emits the sentinel — the §3 qa-loopback block's "this dispatch is not a qa-loopback" fall-through fires.
- **File missing on a qa-loopback dispatch.** Emits the sentinel — agent reads "this dispatch is not a qa-loopback," which is technically wrong (it IS a qa-loopback, just with no findings file). This is the same failure mode as `_resolve_review_findings` today: file missing → sentinel → block treated as non-applicable. The QA agent has the overwrite-on-every-dispatch contract (§0); the file is missing only in the pathological case where the QA dispatch crashed before writing the summary. Acceptable — the orchestrator's halt-classifier catches the broken QA dispatch upstream.
- **File contains an adversarial payload (prompt-injection in QA findings).** Same risk surface as `_resolve_review_findings` today. QA findings are written by an agent (`PIPELINE_WRITER=agent` writer-lane); the implementer reads them as untrusted content. No new ceiling.
- **File contains a literal `{token}` substring.** `resolve_block_tokens` does NOT recursively resolve resolver-output for tokens (per `bin/render-prompt.sh:367-380` comment about the residual-scan removal). Safe.

Render-time error modes:

- **Empty `issue_id`.** `main()` already dies at `:438`. Resolver never runs.
- **`$(issue_dir "$issue_id")` returns a path that doesn't exist.** `_RENDER_QA_FINDINGS_PATH` becomes a stale string; the `-s` test in the resolver returns false; sentinel emitted. Same behavior as `_resolve_review_findings` today.

## 6. Edge Cases

- **QA passes on the first dispatch (no qa-loopback ever fires).** `PIPELINE_LOOPBACK_SOURCE != qa` → sentinel → §3 qa-loopback block's fall-through fires → block is treated as non-applicable. No regression.
- **QA loops back twice in a row (`qa → implementing → ui → reviewing → qa → implementing` repeatedly).** Each implementing dispatch is treated as a qa-loopback iff the MOST RECENT transition was `from=qa to=implementing` (per `_resolve_loopback_source` logic at `bin/run-stage.sh:144-170`). On the second qa-loopback, `stage-summary-qa.md` has been overwritten by the second QA dispatch (per the §0 overwrite-on-every-dispatch contract). The implementer reads the second iteration's findings, not the first's. Correct.
- **QA and review both flagged issues — qa-loopback then immediate review-loopback.** Not possible in the current state machine: the pipeline is linear (implement → ui → review → qa), and a qa-loopback returns to implement, not to a position where the prior review's findings remain authoritative. The review-loopback resolver's gate (`PIPELINE_LOOPBACK_SOURCE=reviewing`) ensures stale review findings don't leak; the qa-loopback resolver's gate (`PIPELINE_LOOPBACK_SOURCE=qa`) ensures stale qa findings don't leak across non-qa-loopback dispatches.
- **Build-loopback followed by qa-loopback (same issue).** After build-loopback fires, implement rebases + force-pushes; later QA fails; qa-loopback fires. `stage-summary-qa.md` from any earlier QA dispatch has been overwritten or never existed yet. New qa-loopback dispatch reads the most recent qa findings. Correct.
- **`--action continue` resume during a qa-loopback dispatch.** Per `_resolve_loopback_source`'s `operator-resume` filter (line 162), the resume waypoint is skipped when computing the loopback source. The most recent NON-RESUME `transition to=implementing` row wins; if that was `from=qa`, the qa-loopback block fires again on resume. Correct.
- **Agent reads `{qa_findings}` block but the §3 prose still references `{review_findings}` as the primary loopback input.** Mitigated by D-005 (block placement immediately after review-loopback) + D-006C (content pin asserts the new block's presence) — both make the qa-loopback block discoverable in the same scan that hits review-loopback.
- **`PIPELINE_LOOPBACK_SOURCE=qa` on a non-implementing stage render.** Resolver registered globally (works for any stage), but `{qa_findings}` token is only referenced by §3 today. Other stages' renders don't include the token → resolver never invoked. No-op. (Same pattern as `_resolve_review_findings` today.)
- **QA findings file is >1 MB (highly unlikely; bounded by QA dispatch's prompt budget).** `cat` streams the file into the rendered prompt. The implementing agent's context window absorbs the inline content. The progress.md token-budget concern that ENG-108 documented does NOT apply: `stage-summary-qa.md` is one dispatch's findings (bounded ~5-50 KB observed), not multi-dispatch accumulation.

## 7. Open Questions

- **OQ-1. Should `_resolve_qa_findings` (and `_resolve_review_findings`) gain a `_validate_dispatch_envelope` detective check for "implementer must have Read'd or processed the findings"?** Plausible — a transcript-scan predicate that fires when `{qa_findings}` resolved to non-sentinel content but the implementer's diff has no commits citing test names. Out of scope for ENG-140 (the brainstorm doesn't ask for it; ENG-87's detective-backstop pattern is the right home for a follow-up).

- **OQ-2. Should `--action continue` clear `stage-summary-qa.md` to prevent stale-qa-findings-on-resume?** Today's `--action continue` clears `pipeline:halted`, the wait-files, the issue-state policy, and global breaker state (per CLAUDE.md "What `--action continue` clears (atomic)" §). It does NOT clear stage-summary files because the loopback contract relies on them. If an operator resumes from a halted qa-loopback, the implementer reads the existing qa findings on resume — which is what the operator probably wants. Recommend no change; flag for the operator-workflow docs.

- **OQ-3. Should the §3 qa-loopback block instruct the agent to also `Read $(issue_dir)/stage-summary-qa.md` directly via the `Read` tool?** Today the file content is inlined via `{qa_findings}`. If the QA findings include long stderr snippets or stack traces, the inlined content may be truncated by the model's context window before the agent processes it. The `Read` tool can be invoked on-demand by the agent and would let it pull only the sections it needs. Tradeoff: explicitness (`Read` makes the access transcript-visible) vs. simplicity (inline content avoids an extra round trip). Recommend defer — same tradeoff applies to `{review_findings}` and is unresolved there too. File a coordinator ticket for both if it becomes a problem in production.

- **OQ-4. Should `_count_loopback_rejections_for_stage` (`bin/run-stage.sh:172`) gate model escalation for qa-loopbacks the same way it does for review-loopbacks?** The model-escalation predicate at `bin/run-stage.sh:212-219` fires on ≥1 prior rejection. A qa-loopback IS a rejection per the predicate's general shape. Today's CLAUDE.md model-escalation docs say "Fires on both rebase loopback (`building → implementing`) and review loopback" — qa-loopback is not explicitly named but should fall under the same `verdict fail --target implementing` counting logic. Verify on iter-1: the count function reads all `verdict fail target=implementing` rows since the most recent `transition to=implementing`, which would include qa-loopback rejections. Likely already correct; no action needed unless the test fixture reveals otherwise.

- **OQ-5. Cross-stage qa-findings reading.** The Linear ticket is scoped to §3 (implementing). Should §4 (UI Agent) also surface `{qa_findings}` if/when a qa→ui loopback ever lands? Currently no such loopback row exists in `_VH_LOOPBACK_TRANSITIONS` (`bin/verdict-handler.sh:32-38`), and the pipeline order is implement → ui → reviewing → qa, so a qa-loopback to ui is not part of today's design. Deferred; not relevant to ENG-140.

## 8. ADR stress test

There is no `docs/knowledge/decisions.md` in the harness repo (verified — `ls docs/knowledge/` returns no files). Durable architectural rules live in CLAUDE.md. ENG-140 puts pressure on the following:

- **CLAUDE.md "Cross-dispatch staleness contract (ENG-87)" §"Per-medium primitives" — per-issue files clear-on-dispatch-start.** `stage-summary-qa.md` is preserved across qa→implementing transitions because `_clear_current_stage_slots` only clears the CURRENT stage's summary (`bin/run-stage.sh:929-930` comment explicitly names this — "stage-summary-OTHER.md (forward+loopback reads need them intact)"). ENG-140 is the first ticket exercising the QA side of this exception. No rule overturn; the exception is by design.

- **CLAUDE.md "Don't add features … beyond what the task requires."** Borderline — the brainstorm chooses inline-content delivery (D-001) over path-token, which adds a resolver body of 12 LOC vs. ENG-108's 1-line path resolver. The brainstorm-side rationale (symmetry with `{review_findings}`, bounded file size, no token-budget concern) is documented; the alternative is documented and rejected on coherence grounds. Acceptable cost.

- **CLAUDE.md "Stage summary file — overwrite-on-every-dispatch contract (ENG-77/ENG-71)."** `stage-summary-qa.md` is governed by this contract — QA writes it every dispatch. ENG-140 reads it; does not write it. The contract is preserved; the read pattern is new.

- **CLAUDE.md "Tool allowlist & probing (ENG-53 #11 / ENG-57)."** The implementing stage's allowlist does NOT enumerate `Read` as a per-stage Bash pattern; `Read` is a stage-agnostic core tool (per the project profile preamble: "Stage-agnostic core tools (Read, Write, Edit, Grep, Glob, TaskCreate, git family, `bash bin/linear.sh`, …) are implicit and not declared here"). The agent could `Read` `$(issue_dir)/stage-summary-qa.md` by absolute path with no allowlist change — but D-001 picks inline-content over path+Read, so this is moot. The resolver itself runs at render-time (in the harness, not in the agent), so the agent's allowlist is not affected.

- **CLAUDE.md "Per-stage dispatch model (ENG-103)" §"escalation predicate."** OQ-4 flags this; not a rule overturn. The escalation predicate at `_count_loopback_rejections_for_stage` counts `verdict fail target=implementing` rows; qa-loopbacks naturally qualify. ENG-140 does not need to touch this.

## 9. Assumption inventory

Every named symbol, path, file, or contract referenced above is grep-verified against the current working tree (ENG-5 anti-bias check).

| # | Assumption | Status | Evidence |
|---|---|---|---|
| A1 | `bin/verdict-handler.sh:36` row `qa\|implementing\|` accepts the qa→implementing loopback | **verified** | `bin/verdict-handler.sh:32-38` (read directly): `qa\|implementing\|` row present at line 36 |
| A2 | `bin/render-prompt.sh::PROMPT_RESOLVERS` is the resolver registry; new entries land between existing lines 41-57 | **verified** | `bin/render-prompt.sh:41-57` (read directly); registry comment at 33-40 spells out the three-step contract |
| A3 | `bin/render-prompt.sh::_resolve_review_findings` body is 12 lines (264-276) and gates on `PIPELINE_LOOPBACK_SOURCE` | **verified** | `bin/render-prompt.sh:264-276` (read directly); contains `[[ -n "$source" && "$source" != "reviewing" ]] && printf '(no prior review…)'` |
| A4 | `bin/render-prompt.sh::main` binds `_RENDER_REVIEW_FINDINGS_PATH="$(issue_dir "$issue_id")/stage-summary-reviewing.md"` at line 487 (read source: 467-468, 487) | **verified** | `bin/render-prompt.sh:467,468,487` (read directly) |
| A5 | `bin/render-prompt.sh::resolve_block_tokens` short-circuits the residual scan (does NOT recursively scan resolver-output for tokens) | **verified** | `bin/render-prompt.sh:367-380` (read directly); explicit comment "Resolver values are content, not template directives, and the renderer must not parse them for template tokens" |
| A6 | `bin/run-stage.sh:1416-1422` exports `PIPELINE_LOOPBACK_SOURCE` per implementing dispatch | **verified** | `bin/run-stage.sh:1416-1422` (read directly); calls `_resolve_loopback_source` and exports the value to `render-prompt.sh` |
| A7 | `bin/run-stage.sh::_resolve_loopback_source` (lines 144-170) returns `qa` when the most recent transition to=implementing has `from=qa` | **verified** | `bin/run-stage.sh:144-170` (read directly); the `latest_from` accumulator returns whichever `from=<X>` accompanied the latest `to=implementing` transition |
| A8 | `bin/run-stage.sh::_clear_current_stage_slots` (lines 931-939) clears only `stage-summary-${stage}.md` for the CURRENT stage; `stage-summary-qa.md` survives across qa→implementing transitions | **verified** | `bin/run-stage.sh:929-939` (read directly); comments at 926-930 explicitly name `stage-summary-OTHER.md` as preserved |
| A9 | `AGENT_PROMPTS.md §3` review-loopback block is at lines 729-750; build-loopback block is at lines 752-763 | **verified** | `AGENT_PROMPTS.md:729-763` (read directly) |
| A10 | `AGENT_PROMPTS.md §6` Decision-path B emits `verdict fail --target implementing` at line 1446 | **verified** | `AGENT_PROMPTS.md:1446` (read directly) |
| A11 | `AGENT_PROMPTS.md §6` writes the stage summary at `{stage_summary_path}` (which resolves to `$(issue_dir)/stage-summary-qa.md`) at line 1453 | **verified** | `AGENT_PROMPTS.md:1453` (read directly); `{stage_summary_path}` resolver at `bin/render-prompt.sh:228` |
| A12 | `bin/render-prompt-rc0-test.sh` cases G/H/I/J/K (lines 307-400) demonstrate the loopback-source-gating fixture pattern | **verified** | `bin/render-prompt-rc0-test.sh:301-400` (read directly); each case sets `PIPELINE_LOOPBACK_SOURCE` and asserts findings inlined / sentinel emitted |
| A13 | Cases G/H/I use a per-case `ISSUE_DIR_<X>` + a literal sentinel `LB_SENTINEL` injected into the file and grepped for in the rendered prompt | **verified** | `bin/render-prompt-rc0-test.sh:301-339` (read directly); fixture pattern is `ISSUE_DIR_G="$sandbox/state/test-slug-rc0/ENG-87R6X-G"` etc., file written with literal sentinel, `grep -qF "$LB_SENTINEL"` in output |
| A14 | `bin/render-prompt-rc0-test.sh` cases G H I test discipline includes the "AGENT_PROMPTS.md prose quotes the literal sentinel" caveat at lines 339-342 (so cases avoid asserting the sentinel string is present-or-absent in the rendered prompt for the missing-file case) | **verified** | `bin/render-prompt-rc0-test.sh:339-342` (read directly); explicit comment explains the caveat |
| A15 | `bin/agent-prompts-content-test.sh` line 96 is the canonical pin shape (`grep -qF '1. {progress_md_path}'`) for §3 content invariants | **verified** | `bin/agent-prompts-content-test.sh:91-101` (read directly); ENG-108 pin for the position-1 read-first list |
| A16 | `bin/common.sh::issue_dir` (lines 68-72) composes `$PROJECT_STATE_DIR/$issue` | **verified** | `bin/common.sh:68-72` (read directly) |
| A17 | `5ebae80` commit is on the current branch and is the one that landed the `PIPELINE_LOOPBACK_SOURCE`-gating fix for `_resolve_review_findings` | **verified** | `git log --oneline -15 -- AGENT_PROMPTS.md bin/render-prompt.sh` (ran directly) shows `5ebae80 fix(implement-prompt): gate review_findings on loopback source` |
| A18 | `24a0631` is the commit that added the scope-drift restraint clause to the review-loopback block | **verified** | same git log output: `24a0631 feat(implement-prompt): scope-drift restraint in review-loopback block` |
| A19 | The §3 review-loopback block at lines 729-750 contains a fall-through that names "qa → implementing fail loopback" as a non-review-loopback case at line 735 | **verified** | `AGENT_PROMPTS.md:735` (read directly): "- a qa → implementing fail loopback (treat as a bug-fix dispatch; QA's summary in `completion/qa/{issue_id}` is your input — do NOT treat the prior reviewer's findings as in scope here)," |
| A20 | The basename of THIS brainstorm file contains `eng-140` (case-insensitive), satisfying `partition_dirty_paths::D-004` | **verified** | basename: `2026-05-17-eng-140-implement-prompt-3-add-qa-findings-token-qa-loopback-handling-block-design.md` — contains `eng-140` ✓ |
| A21 | `bin/render-prompt.sh::_resolve_progress_md_path` and `_resolve_stage_summary_path` are byte-for-byte single-line `printf` resolvers reading `_RENDER_*` globals (the resolver-shape precedent) | **verified** | `bin/render-prompt.sh:228-229` (read directly); both are one-line `printf` resolvers |
| A22 | §3 review-loopback block line 743 already carries the scope-drift restraint clause (from `24a0631`); ENG-140's analogous clause for QA need not back-fill review's | **verified** | `AGENT_PROMPTS.md:743-746` (read directly); contains the "Scope-drift restraint — a review finding is NOT an authorization to expand scope" header + ENG-123 example |
| A23 | The agent's stage-agnostic `Read` tool can open arbitrary absolute paths (outside the worktree) without an allowlist entry — same property as ENG-108 confirmed | **verified** | Project profile addendum's "Stage-agnostic core tools" preamble in this very prompt: "Stage-agnostic core tools (Read, Write, Edit, Grep, Glob, TaskCreate, git family, `bash bin/linear.sh`, `bash bin/pipeline.sh`, `bash bin/guards.sh`, `bash bin/slack.sh`, `bash bin/metrics.sh`) are implicit and not declared here" |

## 10. Persona review

Six personas were run in order **design → security → scope → coherence → product → feasibility**. Feasibility runs last because codebase-fact errors are always P0.

### 10.1 Design persona

**Concerns evaluated:** is the delivery mechanism right-shaped? Are the severity/commit-message conventions internally consistent? Does the scope-drift carve-out preserve the load-bearing restraint?

- D-001 picks inline-content delivery, copying `_resolve_review_findings` byte-for-byte structurally. Rejection of path-token delivery (ENG-108 shape) is grounded in three concrete distinctions: bounded file size (one dispatch vs. lifetime accumulation), explicit inline-content precedent in `{review_findings}`, and content-vs-path symmetry across loopback sources. Each is independently load-bearing.
- D-002 (severity hierarchy) uses QA's existing P0 vocabulary directly. Rejected alternatives (importing `[critical]`/`[major]` rubric, inventing a QA-specific rubric) each require §6 edits that are explicitly out of scope. The decision falls out of the constraint.
- D-003 (scope-drift carve-out) preserves the `24a0631` no-contract-expansion rule while permitting bug-fix code by construction. The "test correctly encodes the plan's expected behavior" qualifier is observably bounded — the implementer can grep the plan's Failure Mode → Test Map for the failing test name; if present, the bug fix is in scope; if absent, file `plan_gap`. Clean distinction.
- D-004 (commit-message convention) uses the failing test name as the locator, mirroring QA's own dedup signature in §6 step 6. The convention is unambiguous and cheap to cross-verify.
- D-005 (placement between review-loopback and build-loopback) is justified on coherence — placement matches pipeline stage order and exploits the existing review-loopback fall-through that names "qa → implementing" as a non-review case.
- D-006 (test surface) extends `render-prompt-rc0-test.sh` cases G/H/I shape exactly. No new abstraction.
- D-007 (scope boundary) is explicit: no §6 edit, no verdict-handler edit, no run-stage edit. Linear ticket's "Proposed scope" point 3 says verbatim "`bin/run-stage.sh`: nothing."

**Verdict: PASS** — no design changes required.

### 10.2 Security persona

**Concerns evaluated:** can a malicious or buggy QA agent inject content via `{qa_findings}`? Are secret-handling rules respected? Are cross-issue reads possible?

- **Prompt-injection via `stage-summary-qa.md` content.** The QA agent writes the file with `PIPELINE_WRITER=agent`; the implementer reads it as untrusted content. Same risk surface as `{review_findings}` today (`bin/render-prompt.sh:264-276`). No new ceiling. If the threat model changes, a sanitization pass on inlined resolver output is a separate ticket affecting both resolvers symmetrically.
- **Cross-issue read.** `_RENDER_QA_FINDINGS_PATH` is composed by `progress_md_path`-shaped path concatenation: `$PROJECT_STATE_DIR/$issue_id/stage-summary-qa.md`. If `$issue_id` carried `../../../etc/passwd`, the resolved path could escape. Mitigated upstream by Linear's identifier-shape validation (`ENG-\d+`); `bin/run-stage.sh::main` reads `issue_id` from Linear's authoritative identifier field, never from user-provided strings. Same property as the existing `_RENDER_REVIEW_FINDINGS_PATH` binding. No regression.
- **Secret-handling (ENG-46).** The new resolver uses `${_RENDER_QA_FINDINGS_PATH-}` and `${PIPELINE_LOOPBACK_SOURCE-}` — single-dash empty fallback for presence-only checks. Neither matches the `*KEY|*TOKEN|*SECRET|ANTHROPIC*|GITHUB*|LINEAR*` regex. `bin/secret-probe-lint.sh` will not flag. Compliant.
- **Allowlist surface.** No changes to `dispatch.sh::allowed_tools_for` or the project profile's `## Tool allowlist` section. Render-time resolver runs in the harness, not the agent. No allowlist regression.
- **Lane-fence (ENG-41).** `bin/render-prompt.sh` does not post Linear comments. The resolver's output is consumed inline into the rendered prompt only. No `bash bin/linear.sh` call site, no lane-fence violation possible.

**Verdict: PASS** — risk surface identical to `_resolve_review_findings`; no new threat introduced.

### 10.3 Scope persona

**Concerns evaluated:** does the brainstorm stay within the Linear IN list? Does any decision drift into §6, verdict-handler, run-stage, or build-loopback territory?

- **IN list coverage (per the Linear ticket's "Proposed scope"):**
  - Point 1: `bin/render-prompt.sh` — `_resolve_qa_findings` resolver, gated on `PIPELINE_LOOPBACK_SOURCE=qa`, reads `$(issue_dir)/stage-summary-qa.md`. **Covered by D-001.**
  - Point 2: `AGENT_PROMPTS.md §3` — new "QA → implementing loopback handling" block with severity hierarchy, commit-trailer convention, scope-drift restraint. **Covered by D-002, D-003, D-004, D-005.**
  - Point 3: `bin/run-stage.sh`: nothing. **Covered by D-007.**
  - Point 4: tests — `render-prompt-rc0-test.sh` cases L–N + `agent-prompts-content-test.sh` content pin. **Covered by D-006.**
- **OUT list coverage (per the Linear ticket's "Not in scope"):**
  - `{build_failure_context}` token: not introduced. **Confirmed by D-007.**
  - Back-fill review-loopback prose with the scope-drift clause: not introduced (D-003 acknowledges `24a0631` already shipped the analogous clause to review; ENG-140's clause is for QA only).
- **Subsystems touched (per CLAUDE.md "Ticket sizing rubric" §"Axis 1"):**
  - Agent prompts (AGENT_PROMPTS.md §3).
  - Dispatch (render-prompt.sh resolver).
  - Tests (render-prompt-rc0-test.sh + agent-prompts-content-test.sh).

  Three nominal subsystems; tests are clearly subordinate (~6 LOC for the content pin, ~60 LOC for cases L-N parallel to existing G/H/I). Two production subsystems. Rubric clause "2 subsystems with one clearly subordinate → autonomy-safe IF the scope boundary is explicit in the ticket body" — the boundary is explicit in the Linear ticket's "Not in scope" + D-007.
- **Independent design decisions:** D-001 (delivery mechanism) is load-bearing. D-002, D-003, D-004 are all derivative given D-001 + ticket constraints (severity from §6's existing P0 vocabulary; commit-message convention from §6's existing dedup signature; scope-drift from the `24a0631` precedent + a single carve-out). D-005 is placement (mechanical). D-006 is test surface (mechanical). One independent design decision; well under the 2-independent threshold.

**Verdict: PASS** — squarely within scope; subsystem count + decision count both fall under their respective rubric thresholds with explicit boundary.

### 10.4 Coherence persona

**Concerns evaluated:** does this fit existing harness conventions? Does it conflict with any cross-cutting rule?

- **Token naming.** `{qa_findings}` mirrors `{review_findings}` (both: `<source-stage>_findings` snake-case). Coherent.
- **Resolver function naming.** `_resolve_qa_findings` mirrors `_resolve_review_findings`. Coherent.
- **`_RENDER_*` global naming.** `_RENDER_QA_FINDINGS_PATH` mirrors `_RENDER_REVIEW_FINDINGS_PATH`. Coherent.
- **Sentinel string shape.** `(no prior qa run for this issue — this dispatch is not a qa-loopback)` mirrors `(no prior review for this issue — this dispatch is not a review-loopback)`. Coherent.
- **Loopback-source gating logic.** The resolver gates on `PIPELINE_LOOPBACK_SOURCE != "qa"` (negative form), mirroring `_resolve_review_findings`'s `PIPELINE_LOOPBACK_SOURCE != "reviewing"` (negative form). Both use the same `[[ -n "$source" && "$source" != "<stage>" ]]` shape. Coherent.
- **Test-case naming.** Cases L–N continue the alphabetical sequence past J/K (which exists at lines 363-400). Coherent.
- **Block placement.** Between review-loopback and build-loopback (D-005). Matches pipeline stage order (review → qa → build in the implementer's view of "where might I have come from"). Coherent.
- **Severity vocabulary.** D-002 uses QA's existing P0 (not the reviewer's `[critical]`/`[major]`). This DEVIATES from the review-loopback block at first glance, but the deviation is intentional and well-grounded — QA's P0 is a different schema, and the review-loopback block's rubric came from review's `[critical]`/`[major]`/`[minor]`/`[nit]` tag set, which QA doesn't emit. Coherent-with-flag.
- **Commit-message convention.** D-004's "cite failing test name" mirrors the review-loopback's "cite file:line." Same shape (locator-trailer in commit message), different locator content. Coherent.

**Verdict: PASS** — severity-vocabulary divergence from review-loopback is flagged but justified.

### 10.5 Product persona

**Concerns evaluated:** does this fix the actual problem described in the Linear ticket? Is the foundation right-sized?

- **Problem closure.** The ticket's "Context" §3 names the gap: "No explicit 'you're in a qa-loopback' prose. The QA findings live in the `completion/qa/ENG-140` Linear comment and in `$(issue_dir)/stage-summary-qa.md` on disk. The agent has to discover them via Read/Linear-MCP. Not great — opaque to the agent." ENG-140 closes the gap: the §3 qa-loopback block tells the agent it's in a qa-loopback AND inlines the findings into the prompt body. The implementer no longer has to discover the findings.
- **Acceptance criteria coverage (verbatim from Linear ticket):**
  - AC-1: "On `qa → implementing` loopback, `{qa_findings}` resolves to the QA summary content." → **D-001 + D-006 case L.**
  - AC-2: "On any other dispatch, the sentinel." → **D-001 + D-006 case M (building) + case N (reviewing).**
  - AC-3 (regression-intent): "On `qa → implementing` loopback, `{review_findings}` continues to resolve to the sentinel." → **D-006 regression-intent assertion (D-006R).**
  - AC-4: "AGENT_PROMPTS.md §3 contains a qa-loopback block whose distinctive phrase is pinned by `agent-prompts-content-test.sh`." → **D-006C.**
  - AC-5: "Brainstorm captures the severity-hierarchy + scope-drift decisions made for QA-loopback work." → **D-002 (severity) + D-003 (scope-drift carve-out).**
- **Right-sizing.** ~110 LOC total, three production files, four design decisions. Per CLAUDE.md "Ticket sizing rubric" — well within the autonomy boundary. No follow-up coordinator ticket; no umbrella structure; no cascading dependencies.
- **Failure mode at iter-1 in production.** If the qa-loopback block's wording is unclear (e.g., the scope-drift carve-out gets misinterpreted), the failure mode is the same as the review-loopback block: noisy follow-up qa-loopbacks until the wording is refined. Acceptable iteration cost; mitigated by the prompt's literal example mirroring the ENG-123 case for review-loopback.
- **Cost.** One extra paragraph in the rendered prompt per implementing dispatch (~30 lines of prose, ~few KB). Trivial token cost.

**Verdict: PASS** — closes the gap the Linear ticket describes; correctly sized for autonomy; no cascading effects.

### 10.6 Feasibility persona

**Concerns evaluated:** are all referenced symbols/paths real? Does the proposed code compile? Are the test fixtures runnable?

Per the codebase-fact verification mandate, every named symbol/path/line reference in §§1-9 was checked against the working tree (see §9 Assumption inventory for the full table). Summary:

- `bin/verdict-handler.sh:36` qa→implementing row ✓ (verified directly)
- `bin/render-prompt.sh:41-57` PROMPT_RESOLVERS registry ✓
- `bin/render-prompt.sh:264-276` `_resolve_review_findings` body ✓
- `bin/render-prompt.sh:467-468, 487` `_RENDER_REVIEW_FINDINGS_PATH` bindings ✓
- `bin/render-prompt.sh:367-380` residual-scan removal comment ✓ (confirms safe content inlining)
- `bin/run-stage.sh:144-170` `_resolve_loopback_source` ✓
- `bin/run-stage.sh:1416-1422` PIPELINE_LOOPBACK_SOURCE export ✓
- `bin/run-stage.sh:929-939` `_clear_current_stage_slots` preserves non-current-stage summaries ✓
- `AGENT_PROMPTS.md:729-763` §3 review-loopback + build-loopback blocks ✓
- `AGENT_PROMPTS.md:735` "qa → implementing fail loopback" fall-through reference ✓
- `AGENT_PROMPTS.md:743-746` review-loopback §3.5 scope-drift clause (`24a0631`) ✓
- `AGENT_PROMPTS.md:1446` QA Decision-path B verdict emit ✓
- `AGENT_PROMPTS.md:1453` QA stage-summary write ✓
- `bin/render-prompt-rc0-test.sh:307-400` cases G/H/I/J/K fixture pattern ✓
- `bin/render-prompt-rc0-test.sh:339-342` sentinel-string-in-prose caveat ✓
- `bin/agent-prompts-content-test.sh:91-101` ENG-108 pin shape ✓
- `bin/common.sh:68-72` `issue_dir` ✓
- commits `5ebae80` + `24a0631` present on branch ✓

**Resolver-pattern proof.** The proposed resolver:

```bash
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

is structurally identical to `_resolve_review_findings` at `bin/render-prompt.sh:264-276`, with three text substitutions:
1. `_RENDER_REVIEW_FINDINGS_PATH` → `_RENDER_QA_FINDINGS_PATH`.
2. `"reviewing"` → `"qa"`.
3. `(no prior review …)` → `(no prior qa run …)`.

Bash 3.2 (macOS system bash) syntax. The secret-handling `${VAR-}` single-dash form is preserved (the original used `${VAR-}`, not `${VAR:-…}`, so no secret-probe regression). No surprises.

**Test fixture proof.** Case-L (qa source + file present) is structurally identical to case-G (reviewing source + file present), with:
1. `ISSUE_DIR_G` → `ISSUE_DIR_L`.
2. `stage-summary-reviewing.md` → `stage-summary-qa.md`.
3. `PIPELINE_LOOPBACK_SOURCE=reviewing` → `PIPELINE_LOOPBACK_SOURCE=qa`.
4. Sentinel string differentiated per case (e.g., `SENTINEL-QA-FINDINGS-LOOPBACK-GATE-CASE-L-9281`).

Cases M (building + file present) and N (reviewing + file present) mirror case H (building + reviewing-file-present) and the not-present-side of case G respectively. All four scenarios reuse the existing `$sandbox` + `test-slug-rc0` scaffolding at the top of `bin/render-prompt-rc0-test.sh`.

**§3 prose insertion proof.** The new block goes between line 750 (`{review_findings}` token) and line 752 (`Build → implement loopback handling`). The block does NOT introduce a column-0 ``` fence (mandatory per CLAUDE.md "AGENT_PROMPTS.md is load-bearing" — exactly two fences per stage section). Verified by reading the existing two fences in §3 (the opening fence at line 680 and the closing fence wherever §3 ends — exact line not pinned, but the fence-count invariant is enforced by `bin/render-prompt.sh::extract_block` at lines 113-115).

**Content pin proof.** The §3 pin `grep -qF 'QA → implement loopback handling'` mirrors line 96's `grep -qF '1. {progress_md_path}'` — same `grep -qF` invocation; same `printf '%s\n' "$s3" |` upstream. The fixture is one block (~6 LOC).

**No P0 findings.** Every referenced symbol/path is grep-verified against the current tree; every test fixture has a structural precedent in `render-prompt-rc0-test.sh`; every prose change has a structural precedent in §3.

**Verdict: PASS · P0 findings: 0** — codebase facts all check out; resolver implementation is a structural copy of an existing resolver; test fixtures are structural copies of existing fixtures.

## 11. Gate summary

| Persona | Verdict | Notes |
|---|---|---|
| Design | PASS | No design changes required; one independent decision (D-001 delivery mechanism); derivative decisions internally consistent. |
| Security | PASS | Risk surface identical to `_resolve_review_findings`; no new threat. Cross-issue read property unchanged. Secret-handling compliant (single-dash empty fallback). |
| Scope | PASS | All four IN-list bullets covered; OUT-list bullets respected; two production subsystems with tests clearly subordinate; one independent design decision. |
| Coherence | PASS | Token / resolver / global naming all mirror `_resolve_review_findings`. Severity-vocabulary divergence (QA P0 vs reviewer `[critical]`/`[major]`) is intentional and grounded in §6's existing vocabulary. |
| Product | PASS | Closes the gap the Linear ticket describes; AC-1 through AC-5 all mapped to specific decisions; ~110 LOC total. |
| Feasibility | PASS · P0=0 | Every referenced symbol/path grep-verified; resolver is a structural copy of `_resolve_review_findings`; test fixtures are structural copies of cases G/H/I; prose insertion respects fence invariant. |

**Personas: 6/6 PASS · gate P0: 0 · proceeding to planning.**
