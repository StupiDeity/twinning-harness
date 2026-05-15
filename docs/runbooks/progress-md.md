---
title: ENG-107 progress.md schema and per-issue state-dir slot — runbook
date: 2026-05-15
---

# Runbook — progress.md (per-issue notebook)

## 1. Slot & path

Each issue's progress notebook lives at:

```
$(issue_dir <ident>)/progress.md
```

which expands to `$PROJECT_STATE_DIR/<ident>/progress.md`.

The canonical resolver is `bin/common.sh::progress_md_path <ident>`:

```bash
path="$(progress_md_path "$ident")"
```

Use this helper — never hand-roll the path string. The ENG-79 incident showed
that a second source of truth for a path formula drifts and breaks silently.

Design rationale: `docs/brainstorms/2026-05-15-eng-107-progress-md-schema-and-per-issue-state-dir-slot-design.md`.

## 2. Schema

Each entry is one H2 section. The heading carries structured metadata; the
body is free-form prose.

Canonical entry:

```markdown
## ENG-N-d0001 - brainstorming - 2026-05-15T12:34:56Z

Free-form prose. Anything the agent thinks the next dispatch
on this issue should know. Decisions, dead-ends, open
questions, surprises.
```

Heading rules:

- Three tokens separated by ` - ` (ASCII space-hyphen-space).
- Token 1: dispatch-id (`PIPELINE_DISPATCH_ID` exported by
  `bin/common.sh::allocate_dispatch_id`; format `ENG-N-dNNNN`, 4-digit
  zero-padded).
- Token 2: gerund-form stage name
  (`brainstorming|planning|implementing|ui|reviewing|qa|building|released`).
- Token 3: ISO-8601-UTC timestamp at second precision (e.g.,
  `2026-05-15T12:34:56Z`).

The em-dash variant (` — `) is also acceptable; ASCII ` - ` is recommended
for grep-friendliness.

The dispatch-id prefix is the load-bearing token; the separator is cosmetic.
Future writers may include subsection conventions (decisions, open questions)
in the body — these are per-stage conventions owned by the writer sub-tickets,
not enforced by this schema.

## 3. Append-only contract

Writers MUST append. Never edit a prior entry. Never rewrite the file from
scratch (`Write`-with-truncation is forbidden; use `Edit` in append mode or
shell redirection `>>`).

Reads are unrestricted — any stage agent may read the file at any time.

The contract is a CONVENTION, not a filesystem ACL. No chmod-only-append is
in place. The runbook + stage-agent prompts are the enforcement layer.

## 4. Ownership boundary

Stage agents write; the orchestrator does not.

- `bin/run-stage.sh::_clear_current_stage_slots` (lines 865-873) enumerates
  the per-dispatch-cleared files as exactly `stage-summary-${stage}.md` and
  `wait-${stage}.json`. `progress.md` is intentionally absent from this set.
  Do not add it — the append-only, never-cleared contract is the design.

- `bin/run-local-helpers.sh::partition_dirty_paths` operates on worktree-
  internal paths only (sourced from `git status` against the per-issue
  worktree). `progress.md` lives under `$PROJECT_STATE_DIR/<ident>/`, which
  is OUTSIDE the worktree, so the sweep never sees it. No allowlist change
  is needed.

- `bin/scope-check.sh::is_benign` operates on worktree-relative paths for
  the same reason — the file is invisible to the scope gate.

## 5. Intended lifecycle

- File is created by the first stage agent that writes an entry (per
  ENG-106 / writer-pilot sub-ticket). The orchestrator does not pre-create
  it. Absence of the file is a legitimate, expected state — most issues at
  any moment have zero entries.
- Accumulates for the entire life of the issue.
- Survives `--action continue` resume. `_clear_current_stage_slots` does not
  touch it; the resume path re-allocates a fresh dispatch-id but does not
  reset accumulated entries.
- Never auto-pruned. Operator-only cleanup (`rm`) is the terminal mechanism.
  At observed dispatch rates (~10-30 dispatches per issue), the file stays
  well under 100 KB — within the `Read` tool window.

## 6. Cross-references

- **ENG-87 dispatch-id glue.** The heading's dispatch-id token is
  `PIPELINE_DISPATCH_ID` allocated by `bin/common.sh::allocate_dispatch_id`.
  Readers filter "entries I already wrote" vs "entries from prior dispatches"
  by comparing heading dispatch-ids to the current `$PIPELINE_DISPATCH_ID`.
  This inverts the cross-dispatch staleness hazard ENG-87 names: each
  dispatch's contribution is separately attributed, not a homogeneous blob.
  HTML-comment marker integration (ENG-87 `<!-- meta: dispatch id=... -->`)
  is explicitly out of scope for ENG-107 per the Linear ticket's OUT list.

- **`stage-summary-<stage>.md` contrast.** Stage summary files have the
  OPPOSITE lifecycle: overwritten on every dispatch start by
  `_clear_current_stage_slots` (`bin/run-stage.sh:865-873`; ENG-77
  overwrite-per-dispatch contract). `progress.md` never gets cleared.
  These two sibling files have deliberately opposite contracts; do not
  conflate them.

- **`wait-<stage>.json` contrast.** Also overwritten per dispatch.
  Same contrast as stage-summary.

- **`dispatch_history.jsonl` similarity.** Both files are append-only and
  never auto-cleared. The difference: `dispatch_history.jsonl` is JSONL
  written by the orchestrator for machine-readable forensics (never agent-
  readable by design; see CLAUDE.md "Cross-dispatch staleness contract"
  §"`dispatch_history.jsonl`"). `progress.md` is markdown written by stage
  agents for human- and agent-readable context. Sibling files with
  complementary perspectives.
