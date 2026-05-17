---
linear: ENG-133
date: 2026-05-17
topic: Review Agent — mechanical path-B / path-C verdict from (critical, major) counts
---

# Plan — Review Agent verdict mechanical (ENG-133)

## Anti-anchoring check

- **Problem (operator-perspective):** "The Review Agent (AGENT_PROMPTS.md §5) summarised `0 critical, 0 major, 5 minor, 7 nit` (a path-C summary), then 27s later emitted `verdict result=fail target=implementing` (path-B). The mismatch tripped `guards.sh review_rejection`, looped back to implement, and burned six dispatch cycles on ENG-122 before halting on an unrelated scope violation."
- **Brainstorm framing:** the brainstorm (`docs/brainstorms/2026-05-17-eng-133-review-agent-emits-path-b-fail-verdict-on-path-c-clean-summary-design.md`) makes the path-B / path-C verdict a mechanical predicate on `(critical, major)` and forces the agent to emit a structured count-tuple line before the Decision-path block. Two small wording shifts in the Decision-path block headers (B: "mechanical: critical > 0 OR major > 0"; C: "mechanical: critical == 0 AND major == 0"), one new paragraph at the top of the Decision-path block, one new pre-block instruction with the literal output format, and three grep-anchored test assertions. Matches the problem one-for-one.
- **Proportionality:** four edits in `AGENT_PROMPTS.md` (one inserted pre-Decision-path paragraph, two header rewords, one new count-tuple emission instruction inserted between merge-findings and anti-bias-pass), three new grep assertions in `bin/agent-prompts-content-test.sh`. No new state, no new marker, no schema change, no Linear contract change. Total production-text diff ≈ 8 added lines + 2 reworded lines + ~12 added test lines. Proportional. Proceed.

## Goal

`AGENT_PROMPTS.md` §5 (Review Agent) emits a literal structured pre-verdict line `Findings: (critical=N, major=N, minor=N, nit=N)` immediately after the merge-findings step and before the anti-bias pass. The Decision-path block opens with a paragraph stating the path-B / path-C choice is a mechanical predicate on `(critical, major)`. Path-B and path-C headers reword to state the mechanical predicate verbatim. `bin/agent-prompts-content-test.sh` gains three new assertions: (a) literal `Findings: (critical=` line present in §5; (b) literal `mechanical: critical == 0 AND major == 0` present; (c) literal `mechanical: critical > 0 OR major > 0` present. Path A (premise failure) wording is untouched.

## Assumption Inventory

Format: `[verified|assumed]` ITEM — `path:line` reference.

### Verified — code paths quoted from current tree

- `[verified]` `AGENT_PROMPTS.md:1140-1146` — merge-findings block ending with `- 'nit'      — style; never request changes for nits alone.` Content anchor: the literal `nit\`      — style; never request changes for nits alone.` line is the unique boundary token before the new count-tuple injection point.

- `[verified]` `AGENT_PROMPTS.md:1148` — `Anti-bias pass (MANDATORY — do this YOURSELF; do not delegate to ensemble):` — the next block immediately following merge-findings. Content anchor: literal `Anti-bias pass (MANDATORY` is unique in the file (Grep verified, 2026-05-17). New count-tuple instruction is inserted immediately above this line.

- `[verified]` `AGENT_PROMPTS.md:1233` — `Decision path (apply exactly one):` line. Content anchor: literal `Decision path (apply exactly one):` occurs four times in the file (§5, §6, §7, §8); the §5 occurrence is uniquely identified by its preceding context (gotchas/conventions paragraph at lines 1227-1230). Edit uses the larger surrounding block as the `old_string` to disambiguate.

- `[verified]` `AGENT_PROMPTS.md:1242` — `  B. Changes requested (any \`critical\` or \`major\` findings).` — literal §5 path-B header. Content anchor: the exact phrase `B. Changes requested (any \`critical\` or \`major\` findings).` is unique in the file (the §6 QA agent has different decision-path wording).

- `[verified]` `AGENT_PROMPTS.md:1260` — `  C. Clean review (no \`critical\` / \`major\` findings) — ENG-54 contract.` — literal §5 path-C header. Content anchor: the exact phrase including `ENG-54 contract` is unique in the file.

- `[verified]` `bin/agent-prompts-content-test.sh:74` — `s5="$(section_body "## 5. Review Agent")"` already extracts §5's body for assertions. The new assertions use the same `s5` variable.

- `[verified]` `bin/agent-prompts-content-test.sh:90-95` — existing §3 ENG-108 grep-anchored assertion pattern (`grep -qF '1. {progress_md_path}'`). New §5 ENG-133 assertions follow the same pattern (`grep -qF '<literal>'`).

### Assumed — pinned by content anchor + verify-at-implement

- `[assumed]` Nothing on origin/main between plan time (`origin/main = c23d0ff`) and implement time changes the merge-findings block (§5 lines 1140-1146), the Anti-bias-pass header line (§5 line 1148), the §5 Decision-path header line (1233), or the §5 path-B/path-C header lines (1242, 1260). Verify by re-grepping the content anchors at the start of implement; if any anchor is gone, rebase first.

## Edit-boundary keys (content anchors, not line numbers)

When the implementer runs `Edit`, the `old_string` MUST quote enough surrounding context that the substitution is unambiguous on a future-rebased tree. The four anchors:

1. **Count-tuple injection (between merge-findings and anti-bias-pass).** `old_string` = the literal `  - \`nit\`      — style; never request changes for nits alone.\n\nAnti-bias pass (MANDATORY` block; `new_string` inserts a paragraph in between.

2. **Decision-path opening paragraph.** `old_string` = `Decision path (apply exactly one):\n\n  A. Premise failure (brainstorm was wrong).`; `new_string` injects the mechanical-predicate paragraph between the header and path-A.

3. **Path-B header reword.** `old_string` = the literal `  B. Changes requested (any \`critical\` or \`major\` findings).`; `new_string` = `  B. Changes requested (mechanical: critical > 0 OR major > 0).`.

4. **Path-C header reword.** `old_string` = the literal `  C. Clean review (no \`critical\` / \`major\` findings) — ENG-54 contract.`; `new_string` = `  C. Clean review (mechanical: critical == 0 AND major == 0) — ENG-54 contract.`.

## Failure Mode → Test Map

| # | Failure mode | Test |
|---|---|---|
| 1 | Count-tuple instruction deleted or demoted | `bin/agent-prompts-content-test.sh` §5 ENG-133 assertion (a) — `grep -qF 'Findings: (critical='` |
| 2 | Decision-path path-C header reverts to prose ("no critical / major findings") | `bin/agent-prompts-content-test.sh` §5 ENG-133 assertion (b) — `grep -qF 'mechanical: critical == 0 AND major == 0'` |
| 3 | Decision-path path-B header reverts to prose ("any critical or major findings") | `bin/agent-prompts-content-test.sh` §5 ENG-133 assertion (c) — `grep -qF 'mechanical: critical > 0 OR major > 0'` |
| 4 | Existing §5 pin (path-C contract sentence, COMMENTED-state requirement, etc.) regresses | Existing `bin/agent-prompts-content-test.sh` assertions stay green |

## File structure (scope)

IN:
- `AGENT_PROMPTS.md` (single section, §5)
- `bin/agent-prompts-content-test.sh` (assertions only; no new file)
- `docs/brainstorms/2026-05-17-eng-133-*.md` (already committed at brainstorm stage)
- `docs/plans/2026-05-17-eng-133-*.md` + `docs/plans/2026-05-17-eng-133-*.json` (this commit)

OUT:
- Any other file in the repo.

## Sequence

1. **F-1 (single commit):** Apply the four `AGENT_PROMPTS.md` edits (one insertion, one paragraph injection, two header rewords). Apply the three new `bin/agent-prompts-content-test.sh` assertions in the §5 block.
2. **Gate:** run `bash bin/agent-prompts-content-test.sh` — expect rc=0 with the three new OK lines visible.
3. **Gate:** run `bash .githooks/pre-commit` (full sibling test suite) — expect exit 0.
4. Commit with `feat(ENG-133): mechanical path-B/path-C verdict for review agent`.

## Pass criteria

See `2026-05-17-eng-133-review-agent-emits-path-b-fail-verdict-on-path-c-clean-summary.json` (one feature, four grep + one smoke).
