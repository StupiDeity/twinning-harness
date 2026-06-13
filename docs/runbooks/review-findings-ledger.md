---
title: ENG-190 review-findings-ledger.jsonl — per-issue adjudicator memory slot
date: 2026-06-13
---

# Runbook — review-findings-ledger.jsonl (per-issue adjudicator memory)

## 1. Slot & path

Each issue's review-findings ledger lives at:

```
$(issue_dir <ident>)/review-findings-ledger.jsonl
```

which expands to `$PROJECT_STATE_DIR/<ident>/review-findings-ledger.jsonl`.

The canonical render-time resolver is
`bin/render-prompt.sh::_resolve_review_ledger_path` (binds
`_RENDER_REVIEW_LEDGER_PATH` from `issue_dir <ident>` in `main()`); the
agent sees the resolved absolute path via the `{review_ledger_path}` token.
The orchestrator seeds the file once per issue on the first reviewing-stage
dispatch via `bin/run-stage.sh::_ensure_review_ledger`.

Design rationale: `docs/brainstorms/2026-06-13-eng-190-*.md` and
`docs/plans/2026-06-13-eng-190-*.md`.

## 2. Schema

Each row is one JSON object per line (JSONL). Lines beginning with `#`
are file-header comments; the orchestrator seeds two such lines on
file creation and they are byte-checked by the validator. Whitespace-
only lines are tolerated and skipped.

Canonical row:

```json
{
  "ledger_schema_version": 1,
  "issue_id": "ENG-N",
  "dispatch_id": "ENG-N-dNNNN",
  "iteration": 1,
  "created_at": "2026-06-13T12:34:56Z",
  "finding_class_key": "<dimension>:<scope-anchor>:<concept-slug>",
  "cold_severity": "critical|major|minor|nit",
  "adjudicated_severity": "critical|major|minor|nit",
  "decision": "carry|stabilise|defer-candidate|block",
  "rationale": "<non-empty string; ≤280 char soft cap>"
}
```

Source of truth for the schema is the header comment block in
`bin/review-ledger-schema.sh`; downstream validators and the agent's
adjudication decision table both reference that file.

Two invariants are mechanically enforced by the validator:

- **Severity-ladder:** `adjudicated_severity` is never strictly greater
  than `cold_severity` on the ladder critical=4>major=3>minor=2>nit=1.
- **Critical-floor:** if `cold_severity == critical` then
  `decision == block` AND `adjudicated_severity == critical`. No
  exceptions. The adjudicator may never downgrade a critical.

## 3. Append-only contract

Writers MUST append. Never edit a prior row. Never rewrite the file from
scratch (`Write`-with-truncation is forbidden; use `Edit` with the seed-
header line as the anchor to append).

The reviewing-stage `--allowed-tools` surface intentionally omits
`Bash(rm:*)` — the agent cannot delete the ledger.

The contract is a CONVENTION enforced post-dispatch by
`bin/review-ledger-schema.sh` (validates rows; halts on schema
violations) and by the seed-header byte-equal check (catches
header tampering).

Reads are unrestricted — any future stage agent may read the file at
any time (though no current stage other than reviewing does so).

## 4. Ownership boundary

The reviewing-stage agent writes rows; the orchestrator only seeds the
header and validates post-dispatch.

- `bin/run-stage.sh::_clear_current_stage_slots` is intentionally NOT
  extended to clear this file. The function-header comment block lists
  `review-findings-ledger.jsonl` under "NOT cleared". The append-only,
  never-cleared contract is the design — opposite lifecycle from
  `verdict-review.json` (which IS overwrite-per-dispatch).
- `bin/run-local-helpers.sh::partition_dirty_paths` operates on
  worktree-internal paths only (sourced from `git status` against the
  per-issue worktree). The ledger lives under
  `$PROJECT_STATE_DIR/<ident>/`, which is OUTSIDE the worktree, so the
  sweep never sees it. No allowlist change is needed.
- `bin/scope-check.sh::is_benign` operates on worktree-relative paths
  for the same reason — the file is invisible to the scope gate.

## 5. Intended lifecycle

- File is seeded by `_ensure_review_ledger` on the first reviewing-stage
  dispatch on the issue. Stage-gated to `reviewing` so issues that never
  reach reviewing don't accumulate empty ledger files.
- Accumulates for the entire life of the issue across every reviewing
  iteration. The whole point of the ledger is cumulative memory —
  every prior decision is a row.
- Survives `--action continue` resume. Resume re-allocates a fresh
  `dispatch_id` but does not reset accumulated rows. Operator note:
  if the resume cause was a `review-ledger-invalid` halt, the operator
  must fix or remove the offending row BEFORE resuming — the detective
  will re-halt on the same row otherwise. See
  `docs/runbooks/recovery.md` §12.
- Never auto-pruned. Operator-only cleanup (`rm`) is the terminal
  mechanism. At observed iteration counts (most issues converge inside
  3 reviewing dispatches), the file stays well under 100 KB.

## 6. Cross-references

- **ENG-87 staleness contract.** The `dispatch_id` field on each row is
  `PIPELINE_DISPATCH_ID` exported by `bin/common.sh::allocate_dispatch_id`.
  Readers filter "rows from the current dispatch" vs "rows from prior
  dispatches" by comparing `dispatch_id` to the current
  `$PIPELINE_DISPATCH_ID`. The validator's per-row format check on
  `dispatch_id` (`^ENG-[0-9]+-d[0-9]+$`) plus the `--ident` cross-check
  cover the bulk of staleness defense. In-window cross-check against
  `dispatch_history.jsonl::started_at` is deferred from v1
  (brainstorm D-009) to preserve the sibling-validator pattern.
- **`progress.md` similarity.** Both files have the SAME lifecycle:
  per-issue, append-only, never cleared on dispatch start, seeded by
  the orchestrator via an `_ensure_*` helper. The difference:
  `progress.md` is human-and-agent-readable markdown for cross-stage
  context; `review-findings-ledger.jsonl` is machine-validated JSONL
  for adjudicator memory across reviewing iterations on the SAME stage.
- **`verdict-review.json` contrast.** The verdict payload has the
  OPPOSITE lifecycle: overwritten on every reviewing-stage dispatch
  start by `_clear_current_stage_slots`. The two reviewing-stage
  agent-owned files therefore have deliberately opposite contracts;
  do not conflate them.
- **`dispatch_history.jsonl` similarity.** Both files are append-only
  and never cleared. The difference: `dispatch_history.jsonl` is
  orchestrator-only forensic JSONL (never agent-readable by design;
  see CLAUDE.md "Cross-dispatch staleness contract"
  §"`dispatch_history.jsonl`"). `review-findings-ledger.jsonl` is
  agent-written and agent-read for adjudicator memory.
