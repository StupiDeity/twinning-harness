---
linear: ENG-102
date: 2026-05-19
topic: PR #95 follow-up polish — `.scratch/` + auto-clean low/info review findings
spec: docs/brainstorms/2026-05-19-eng-102-pr-95-followup-polish-design.md
status: draft
---

# PR #95 follow-up polish — Implementation Plan

## 1. Goal

After this plan lands, items 1, 3, 4, 13, 14, 15 from the brainstorm are
implemented; the remaining LOW/INFO items are dismissed-with-reasoning or
deferred in the PR body; the full `.githooks/pre-commit` suite remains
green.

## 2. Files touched

| File | Reason |
|---|---|
| `bin/run-local-helpers.sh` | Item 1 rename (function definition + docstring); item 14 review-shorthand sweep |
| `bin/run-local.sh` | Item 1 callsite rename |
| `bin/run-local-helpers-adversarial-test.sh` | Items 1 (test+grep rename), 3 (capture stderr + assert log), 4 (`.claude/` sibling seed), 13 (`2>/dev/null` on per-stage call), 14 (shorthand sweep) |
| `CLAUDE.md` | Items 1 (rename), 14 (shorthand sweep), 15 (matrix trim) |

## 3. Step-by-step (TDD ordering where applicable)

### T1 — Item 3: dry-run log assertion (pin first)

- [ ] Modify `test_self_leak_dry_run_skips_mutation` to capture stderr
      of the dispatching call and assert it contains `[DRY_RUN]`.
- [ ] Modify `test_clean_scratch_dir_dry_run_skips_mutation` similarly.
- [ ] Run the file. Both tests must still PASS (dry-run log lines exist
      today via `log` in helpers).

### T2 — Item 4: `.claude/` sibling seed

- [ ] In `test_clean_scratch_dir_preserves_siblings`, add
      `mkdir -p "$wt/.claude" && echo '{}' > "$wt/.claude/should-survive.json"`.
- [ ] Add an assertion that `$wt/.claude/should-survive.json` still
      exists after cleanup.
- [ ] Run the file — passes (helper only `rm -rf`s `.scratch/`).

### T3 — Item 13: stderr quiet on `stage_is_read_mostly` per-stage loop

- [ ] Locate the per-stage loop in `test_read_mostly_predicate` that
      calls `stage_is_read_mostly "$stage"`. Append `2>/dev/null` to
      that inner call.
- [ ] Run the file — passes; suite output is quieter.

### T4 — Item 1: function rename (`clean_scratch_dir` → `clean_scratch_residue`)

- [ ] Rename function in `bin/run-local-helpers.sh`.
- [ ] Update callsite in `bin/run-local.sh`.
- [ ] Update test names + wire-up greps in
      `bin/run-local-helpers-adversarial-test.sh`.
- [ ] Update CLAUDE.md references.
- [ ] Run the test file + `.githooks/pre-commit`.

### T5 — Item 14: review-shorthand prose sweep

- [ ] Grep both `bin/run-local-helpers*.sh` and `CLAUDE.md` for
      patterns like `C1`, `C2`, `M-T1`, `review finding`.
- [ ] Paraphrase each in plain prose describing intent.

### T6 — Item 15: CLAUDE.md matrix-duplication trim

- [ ] Identify the two CLAUDE.md sections with the per-stage matrix.
- [ ] Replace the second copy with the orthogonal cross-dispatch
      reasoning only; cross-reference the first.

### T7 — Final gate

- [ ] `bash .githooks/pre-commit` end-to-end (full bin/*-test.sh suite).
      Must report all tests pass / SKIP only on KNOWN_BROKEN.

## 4. Out of scope (deferred / dismissed)

Items 2, 5, 6, 7, 8, 9, 12, 17, 19, 20, 21 — dismissed in PR body with
reasoning. Items 10, 11, 16, 18, 22 — flagged in PR body as deferred.

## 5. Risk

Item 1 rename is the only wide-touch change. Wire-up greps in the
adversarial test file are the safety net; if a callsite is missed the
sibling test catches it.
