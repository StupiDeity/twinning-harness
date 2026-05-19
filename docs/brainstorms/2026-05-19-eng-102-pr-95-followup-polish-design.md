---
linear: ENG-102
title: PR #95 follow-up polish — `.scratch/` + auto-clean low/info review findings
date: 2026-05-19
status: draft
---

# PR #95 follow-up polish — `.scratch/` + auto-clean low/info review findings

## 1. Problem

PR #95 (`fix/sanctioned-scratch-dir-for-agents`) shipped the sanctioned
`.scratch/` namespace, `stage_is_read_mostly` predicate,
`clean_self_leak_residue` per-path cleanup, and `clean_scratch_dir`
tick-end persistence guard. Three rounds of cold-pass ensemble review
left ~18 LOW/INFO/nit findings that do not block merge but compound if
new work lands on this surface. The harness has a pattern (ENG-100,
ENG-104, ENG-87) where ignored low-severity findings accrete into
mental-model friction; the cheap polish items should be cashed in now.

## 2. Scope

Acceptance criteria pin this to **items 1, 3, 4, 13, 14, 15** as
must-implement, with the remaining 16 either dismissed in-PR with
reasoning or deferred. The six mandatory items collectively touch:

- One subsystem: `scope/sweep` (`bin/run-local-helpers.sh`, sibling test).
- One docs artifact: `CLAUDE.md`.

Per the file-time sizing rubric: 1 subsystem + 1 design decision = autonomy-safe.

## 3. The six must-do items

1. **Rename** `clean_scratch_dir` → `clean_scratch_residue` for symmetry
   with sibling `clean_self_leak_residue`. Mechanical rename across
   `bin/run-local-helpers.sh` definition, `bin/run-local.sh` callsite,
   `bin/run-local-helpers-adversarial-test.sh` test names + wire-up
   greps, and `CLAUDE.md` references.

3. **Dry-run tests assert FS-not-mutated but not log-emitted.** Capture
   stderr from the helpers and grep for the `[DRY_RUN]` log line in
   `test_self_leak_dry_run_skips_mutation` and
   `test_clean_scratch_dir_dry_run_skips_mutation`. A regression that
   silently drops the log line currently passes the suite.

4. **`.claude/` not in sibling-preservation test.**
   `test_clean_scratch_dir_preserves_siblings` seeds `.pipeline-config/`
   and `src/` but not `.claude/` — the other gitignored operator-local
   dir. Add `.claude/should-survive.json` to the seed.

13. **`test_read_mostly_predicate` stderr noise.** For `implementing|ui|qa`
    the inner `stage_output_paths` call emits a `log` warning when
    `PROJECT_SLUG` is unset (test env). The predicate's rc is captured
    correctly, but stderr pollutes the suite output. Append `2>/dev/null`
    to the per-stage call inside the test loop.

14. **Review-label shorthand leaking into permanent code comments.**
    Sweep `bin/run-local-helpers-adversarial-test.sh`,
    `bin/run-local-helpers.sh`, and `CLAUDE.md` for "C1", "M-T1",
    "review finding M5", etc — paraphrase intent in plain prose. The
    review thread is off-PR; the shorthand is a dangling reference.

15. **`CLAUDE.md` per-stage matrix duplicated.** The impl/ui/qa vs
    brainstorm/plan vs reviewing/building/released matrix appears in
    both the "Sanctioned agent scratch dir" and "Tick-end stage-agnostic
    `.scratch/` cleanup" sections. Trim the second to the orthogonal
    cross-dispatch reasoning.

## 4. Items dismissed in-PR

Items 2, 5, 6, 7, 8, 9, 12, 17, 19, 20, 21 — note brief dismissal
reasoning in PR body. Items 10, 11, 16, 18, 22 noted as deferred to
follow-up.

## 5. Risk

- Rename in item 1 is a wide sweep; a missed callsite would break the
  pre-commit test suite (defense by `bin/run-local-helpers-adversarial-test.sh`
  wire-up greps).
- Item 3 stderr capture must not break existing assertions — assert the
  log line AND the FS-not-mutated invariant.
- Items 4, 13, 14, 15 are local edits with no behavioral impact.

## 6. Verification

Single gate: full `.githooks/pre-commit` suite green (~30s).
