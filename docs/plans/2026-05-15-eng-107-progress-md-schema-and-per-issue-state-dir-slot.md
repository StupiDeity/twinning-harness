---
linear: ENG-107
date: 2026-05-15
topic: bin/common.sh::progress_md_path helper + docs/runbooks/progress-md.md schema/lifecycle runbook + CLAUDE.md per-issue state-directory diagram update + bin/common-test.sh fixtures (path/idempotence/die-on-empty) — foundation only, no agent reads/writes
---

# Plan — ENG-107 progress.md schema and per-issue state-dir slot

Implementation plan for the design at
`docs/brainstorms/2026-05-15-eng-107-progress-md-schema-and-per-issue-state-dir-slot-design.md`.

## Anti-anchoring check

- **Problem (operator's words).** ENG-28 (parent umbrella) wants a
  continuous, per-issue `progress.md` notebook so a future dispatch's
  agent can read what prior-dispatch agents on the same issue chose to
  record, without re-parsing every transcript. ENG-107 is the
  foundation sub-ticket: **define what `progress.md` is, where it
  lives, who can read/write it. No stage agents touch it yet.**
- **Brainstorm addresses it?** Yes. D-001 reserves the slot at
  `$(issue_dir <ident>)/progress.md` via a one-line `bin/common.sh`
  helper; D-002 fixes the markdown schema (H2-per-entry, dispatch-id-
  stamped heading, append-only); D-003 names the explicit "no
  orchestrator code reads or writes" boundary; D-004 specifies the new
  `docs/runbooks/progress-md.md` runbook + the CLAUDE.md per-issue
  state-directory diagram update; D-005 specifies the test fixtures.
  No reframe; the four Linear acceptance criteria map 1:1 onto D-001
  through D-005.
- **Proportional?** Yes. Brainstorm §3 sizes the change at ~120 LOC
  across 4 files (one new helper + one `export -f` extension + 3 test
  fixtures + one new runbook + one CLAUDE.md diagram line). Zero
  changes to `bin/run-stage.sh`, `bin/run-local.sh`,
  `bin/dispatch.sh`, `bin/scope-check.sh`,
  `bin/run-local-helpers.sh`, `bin/render-prompt.sh`, `bin/linear.sh`,
  `bin/verdict-handler.sh`, `bin/classify-failure.sh`, `bin/poll.sh`,
  or `AGENT_PROMPTS.md`. Zero new exit codes, verdict variants, or
  Linear labels. The Linear ticket's IN list is precisely the four
  artifacts named; the OUT list (writer/reader code, ENG-87 marker
  integration) is honored by D-003 and the D-002 rejected-alternative
  on HTML-comment markers.
- **No escalation. PROCEED.**

## Branch-base freshness

`git fetch origin main` succeeded at plan time (orchestrator-side; the
plan agent's tool surface inherits a pre-fetched origin/main).
`git log --oneline HEAD..origin/main` returned EMPTY.

- branch-base freshness: `HEAD..origin/main` empty at plan time
  (`origin/main = 55268f2`).

No Task 0 rebase is required. All `path:line` excerpts in the
Assumption Inventory are stable against current HEAD; subsequent edits
still use content anchors per "Edit-boundary keys" guidance to defend
against any sibling commit landing during implement-time before the
implement agent's own pre-edit re-grep.

## Goal

After implement runs:

1. `bash bin/common-test.sh` exits 0 with three new ENG-107
   assertions passing: (a) `progress_md_path ENG-1` returns
   `<PROJECT_STATE_DIR>/ENG-1/progress.md`; (b) two consecutive calls
   with the same identifier return identical strings (idempotence);
   (c) `progress_md_path ""` exits 1 with stderr containing
   `progress_md_path: missing issue id`.
2. `bash .githooks/pre-commit` exits 0 (entire `bin/*-test.sh` suite
   green, including the new ENG-107 fixtures).
3. `progress_md_path` is exported from `bin/common.sh` (subshells in
   future writer/reader sub-tickets can call it without re-sourcing).
4. `docs/runbooks/progress-md.md` exists, documents the schema
   (H2-per-entry, heading shape `## <dispatch-id> - <stage> -
   <ISO-8601-UTC>`), the append-only contract, the ownership boundary
   (agents write; orchestrator does not), and the intended lifecycle
   (created on first writer, accumulates for issue lifetime, survives
   `--action continue` resume, never auto-pruned).
5. `CLAUDE.md` "Per-issue state directory" tree diagram lists
   `progress.md` with a one-line purpose pointing at the runbook, AND
   one paragraph below the diagram differentiates `progress.md`'s
   never-cleared / append-only contract from
   `stage-summary-<stage>.md`'s overwrite-per-dispatch contract.

Verifiable by:

```
bash bin/common-test.sh \
  && bash .githooks/pre-commit
```

exiting 0.

## Assumption Inventory

Every modified-file fact below is `path:line`-cited against the
current worktree HEAD. Quoted excerpts are exact substrings to
preserve in `Edit::old_string` calls. Bare line numbers appear ONLY
as informational hints alongside a content anchor; the literal
content-anchor strings are what the Edit calls match.

### Files modified in this plan: 3 (1 new, 2 edited)

- `bin/common.sh` (two edit sites — Task 2 inserts the
  `progress_md_path` helper directly after `issue_dir`; Task 3
  appends `progress_md_path` to the public `export -f` line)
- `bin/common-test.sh` (one new ENG-107 assertion block inserted
  near the end of the file BEFORE the final summary printf)
- `docs/runbooks/progress-md.md` (new file)
- `CLAUDE.md` (one diagram-line edit + one short paragraph below it,
  inside the `## Per-issue state directory` section)

### Modified-file facts — current state and verification points

- **A-001 — `bin/common.sh::issue_dir` exists at lines 68-72 and
  returns `$PROJECT_STATE_DIR/<ident>`.** Verified by direct read
  (`bin/common.sh:64-72`):

  ```bash
  # ─── Per-issue state directory (ENG-15) ──────────────────────────────
  # Resolve the per-issue state directory. Callers: run-stage.sh,
  # run-local.sh, poll.sh, classify-failure.sh. The directory holds
  # issue-state.json, the worktree/ subdir, and the scope-approval file.
  issue_dir() {
    local issue="$1"
    [[ -n "$issue" ]] || die "issue_dir: missing issue id"
    printf '%s/%s' "$PROJECT_STATE_DIR" "$issue"
  }
  ```

  Content anchor for Task 2's Edit (literal closing brace `}` of
  `issue_dir` followed by the existing
  `compute_pipeline_content_hash` block-header comment, both unique
  within the file):

  - START anchor (preserved as bookend): the literal closing line of
    `issue_dir` —
    ```
      printf '%s/%s' "$PROJECT_STATE_DIR" "$issue"
    }
    ```
  - END anchor (preserved as bookend): the literal next-block opening
    comment header —
    ```
    # Compute a stable sha256 over the set of files that drive pipeline
    ```

  The new `progress_md_path` definition is inserted between these
  two anchors. Both anchor strings appear EXACTLY ONCE in the file
  (verified by Grep at plan time).

- **A-002 — `bin/common.sh:389` carries the public `export -f` line
  for the helpers `issue_dir`, `compute_pipeline_content_hash`,
  `failure_outcome_for_exit`, `parse_pipeline_marker`,
  `is_orchestrator_paused`, `set_orchestrator_paused`,
  `allocate_dispatch_id`, `current_dispatch_id`,
  `assert_no_tool_invocation`.** Verified by direct read:

  ```bash
  export -f issue_dir compute_pipeline_content_hash failure_outcome_for_exit parse_pipeline_marker is_orchestrator_paused set_orchestrator_paused allocate_dispatch_id current_dispatch_id assert_no_tool_invocation
  ```

  Content anchor for Task 3's Edit: the literal full line above
  appears EXACTLY ONCE in the file (verified by Grep at plan time).
  Task 3 appends ` progress_md_path` (single space + token) to the
  end of the line, preserving every existing exported name.

- **A-003 — `PIPELINE_DISPATCH_ID` is allocated by
  `allocate_dispatch_id` at `bin/common.sh:104-147`; format
  `ENG-N-d<NNNN>` (4-digit zero-padded) confirmed by
  `printf '%s-d%04d' "$issue" "$next_seq"` at line 134; export at
  line 145.** Verified by direct read. The schema's heading-shape
  reliance on this token is therefore satisfied today. No change to
  the allocator is in scope.

- **A-004 — `bin/run-stage.sh::_clear_current_stage_slots` at lines
  865-873 enumerates the per-dispatch-cleared files as exactly two:
  `stage-summary-${stage}.md` and `wait-${stage}.json`.** Verified
  by direct read:

  ```bash
  _clear_current_stage_slots() {
    local PIPELINE_WRITER=orchestrator
    export PIPELINE_WRITER
    local ident="$1" stage="$2"
    local d; d="$(issue_dir "$ident")"
    rm -f "$d/stage-summary-${stage}.md" 2>/dev/null || true
    rm -f "$d/wait-${stage}.json"        2>/dev/null || true
    return 0
  }
  ```

  Per D-003: this function is NOT modified by this plan. The runbook
  cross-references the exact line range so a future reader sees the
  file is intentionally absent from the cleared set.

- **A-005 — `bin/run-local-helpers.sh::partition_dirty_paths`
  operates on worktree-internal paths only (sourced from `git
  status` against the per-issue worktree).** Verified by reference
  to brainstorm A5 + the ENG-96 cross-reference. No code change to
  this function. `progress.md` lives under
  `$PROJECT_STATE_DIR/<ident>/`, OUTSIDE the worktree, so
  `partition_dirty_paths` never sees it. No allowlist change is
  needed in `bin/run-local-helpers.sh` or any project profile's
  `## File layout`.

- **A-006 — `bin/scope-check.sh::is_benign` operates on
  worktree-relative paths.** Verified by reference to brainstorm A6
  + the ENG-96 brainstorm's cross-link. No code change. Same
  out-of-worktree rationale as A-005.

- **A-007 — `bin/common-test.sh` exists at 932 lines, follows the
  `_TEST_ROOT=$(mktemp -d -t twinning-eng44.XXXXXX)` pattern at
  lines 18-26, exports `TARGET_REPO` and `PROJECT_SLUG=test-slug`
  at lines 28-30, sources `common.sh` at line 33, defines
  `report_ok`/`report_fail`/`assert_eq` helpers at lines 38-46.**
  Verified by direct read.

- **A-008 — `bin/common-test.sh` final summary is a printf at line
  926 followed by a `if (( FAIL > 0 ))` exit gate at lines 927-931.**
  Verified by direct read:

  ```bash
  printf '\ncommon-test summary: %d passed, %d failed\n' "$PASS" "$FAIL"
  if (( FAIL > 0 )); then
    printf 'failed cases:\n'
    for c in "${FAILED_CASES[@]}"; do printf '  - %s\n' "$c"; done
    exit 1
  fi
  ```

  Content anchor for Task 4's Edit (literal final printf line,
  unique within the file):

  - END anchor (preserved as bookend): the literal line
    `printf '\ncommon-test summary: %d passed, %d failed\n' "$PASS" "$FAIL"`

  The new ENG-107 assertion block is inserted IMMEDIATELY BEFORE
  this line (per the ENG-44 brainstorm's `bin/common-test.sh:926`
  reference re-confirmed by direct read). The block uses the
  existing `report_ok`/`report_fail`/`assert_eq` helpers.

- **A-009 — `CLAUDE.md` "Per-issue state directory" section starts
  at line 271 with an ASCII tree diagram at lines 275-290.**
  Verified by direct read:

  ```
  ## Per-issue state directory

  Per-issue scratch lives under `$PROJECT_STATE_DIR/ENG-N/`:

  ```
  $HARNESS_STATE_DIR/
  ├── .claude-semaphore/          # global counting semaphore (slot-<N>/pid each); replaces .claude-mutex.lock (ENG-81)
  └── <slug>/                     # per-project
      ├── target-repo             # collision sentinel
      ├── .consecutive-failures
      ├── .run-local.lock/
      ├── .tick-counter
      ├── last-observed-release
      ├── logs/local-YYYY-MM-DD.log + per-stage transcripts
      ├── metrics/events.jsonl
      └── ENG-N/
          ├── worktree/
          ├── issue-state.json
          └── stage-summary-<stage>.md
  ```
  ```

  Content anchors for Task 6's Edit:

  - START anchor (preserved as bookend): the literal line
    `        ├── issue-state.json`
  - END anchor (preserved as bookend): the literal line
    `        └── stage-summary-<stage>.md`

  Both anchor strings appear EXACTLY ONCE in `CLAUDE.md` (verified by
  Grep at plan time). Task 6 transforms the diagram so that the
  current `└── stage-summary-<stage>.md` becomes
  `├── stage-summary-<stage>.md` (changing the box-drawing character
  from `└` to `├` because it is no longer the last child) and a new
  `└── progress.md` line is appended directly below.

- **A-010 — Brainstorm `dispatch_history.jsonl` reference is
  current.** Verified by direct read of
  `CLAUDE.md:636-640` (`Per-issue append-only forensic log at
  $(issue_dir)/dispatch_history.jsonl`) and
  `bin/run-stage.sh:1074, 1185` (write sites). The runbook's "see
  also" cross-link to `dispatch_history.jsonl` (sibling
  append-only-but-machine-readable log) targets a still-present
  surface.

- **A-011 — `docs/runbooks/` exists with three files:
  `failure-modes.md`, `operator-mental-model.md`, `recovery.md`.**
  Verified by `ls docs/runbooks/`. The new file
  `docs/runbooks/progress-md.md` is a peer; no directory-level
  metadata file (e.g., index) needs editing because no such file
  exists.

- **A-012 — No `progress_md_path` helper or `progress.md` reference
  exists today.** Verified by `grep -rn "progress_md_path\|progress\.md"
  bin/ docs/` (excluding the brainstorm itself): zero matches. The
  Task 2 helper is wholly new; no name collision.

- **A-013 — `bin/run-retrospective-local.sh` does not reference
  `progress.md`.** Verified by reference to brainstorm A12 (no
  retrospective-side reads). The retrospective agent is not modified
  by this plan.

- **A-014 — Test-gate closure sweep: tokens REMOVED from any tracked
  file by this plan = zero.** This plan ONLY INSERTS content. No
  tokens are renamed, dropped, enum-variant-removed, default-changed,
  or otherwise deleted from production code. Test-gate closure sweep
  has no removals to verify.

  Defensive check on additions (confirming the new tokens aren't
  pinned-ABSENT by any sibling test):

  - `progress_md_path` — `Grep` on `bin/*-test.sh` for
    `progress_md_path` returns matches ONLY in the file the plan
    edits (`bin/common-test.sh`'s new block); zero pre-existing
    sibling-test references. Safe.
  - `progress.md` — `Grep` on `bin/*-test.sh` returns zero matches
    pre-edit. Safe.
  - `docs/runbooks/progress-md.md` — `Grep` on `bin/*-test.sh`
    returns zero matches; the new file is not referenced from any
    test as a required-presence assertion. Safe.

  Tokens whose ABSENCE is asserted that this plan must not violate:

  - The `bin/agent-prompts-content-test.sh` ENG-97 forbidden_token
    loop scans `AGENT_PROMPTS.md` for Tauri-shaped tokens. This
    plan does not touch `AGENT_PROMPTS.md`. Safe.
  - The `bin/vocabulary-cleanliness-test.sh` enforces the closed
    pipeline-marker vocabulary; the new runbook + CLAUDE.md
    paragraph use plain prose only — no `<!-- pipeline: ... -->`
    or `<!-- meta: ... -->` markers are introduced. Safe.

  **Conclusion:** zero test-gate closure defects. No sibling test
  file needs editing.

- **A-015 — Plan doc basename satisfies
  `partition_dirty_paths::D-004`.** The plan filename
  `2026-05-15-eng-107-progress-md-schema-and-per-issue-state-dir-slot.md`
  contains the `eng-107` token (lowercase) in the basename at the
  correct position for in-scope bucketing per
  `bin/run-local-helpers.sh:569-578` and `:634`. ✓

- **A-016 — `learned-rules/harness/plan.md` does not exist.**
  Verified by `ls learned-rules/harness/`: returns only
  `build.md` and `project-profile.md`. Per the plan prompt's
  preamble (skip-if-not-present), no plan-stage learned rules to
  apply.

- **A-017 — Branch prefix matches Improvement label.** Branch name
  (from git status):
  `feat/eng-107-progress-md-schema-and-per-issue-state-dir-slot`.
  CLAUDE.md confirms `feat/` = Feature/Improvement; the Linear
  issue is filed as Improvement (per parent ENG-28 + brainstorm
  framing). ✓

- **A-018 — `bin/common.sh` `set -euo pipefail` at line 7 means
  the helper's `[[ -n "$issue" ]] || die …` early-return contract
  is enforced at sourcing-time and at call-time.** Verified by
  direct read. The Task 2 helper inherits this; `die` exits the
  caller's process which is the documented contract for `issue_dir`
  (line 70).

- **A-019 — Helper colocation rationale.** Verified by inspecting
  the file structure of `bin/common.sh`: it groups helpers into
  labeled sections (`# ─── Per-issue state directory (ENG-15) ───`
  at line 64; `# ─── Dispatch identifier (ENG-87) ───` at line 96;
  `# ─── Transcript-based assertion (ENG-43, hoisted ENG-87) ───`
  at line 160; `# ─── Exit-code → outcome taxonomy (ENG-10 D-002) ───`
  at line 197; etc.). The `progress_md_path` helper belongs in the
  "Per-issue state directory" section because it composes on top of
  `issue_dir`. The Task 2 anchor places the new function inside
  this section.

## File Structure

Modified or new files only — no new test scripts, no new
dependencies, no new Linear labels, no new exit codes, no schema
files, no JSON registries.

- `bin/common.sh` — two edit sites:
  - Task 2: insert ~7 lines (one comment + 5-line `progress_md_path`
    function + one trailing blank line) BETWEEN `issue_dir`'s closing
    `}` and the `# Compute a stable sha256 ...` block-header comment
    (per A-001). Section: `# ─── Per-issue state directory (ENG-15) ───`.
  - Task 3: append ` progress_md_path` (single space + identifier) to
    the END of the existing `export -f` line at line 389 (per A-002).
    All currently-exported helpers preserved verbatim.
- `bin/common-test.sh` — one new ENG-107 assertion block (~25 lines)
  inserted IMMEDIATELY BEFORE the `printf '\ncommon-test summary: %d
  passed, %d failed\n' "$PASS" "$FAIL"` line at 926 (per A-008).
  Three assertions:
  - (a) path shape — `progress_md_path ENG-1` returns the expected
    `$PROJECT_STATE_DIR/ENG-1/progress.md` (uses the harness env
    setup already present at `bin/common-test.sh:28-30`).
  - (b) idempotence — two consecutive calls return identical strings
    (asserted with `assert_eq`).
  - (c) die-on-empty — `progress_md_path ""` exits non-zero with
    stderr matching `progress_md_path: missing issue id`.

  The block uses the existing `report_ok`/`report_fail`/`assert_eq`
  helpers; no new helper functions added.
- `docs/runbooks/progress-md.md` — new file (~80 lines). Sections per
  brainstorm D-004:
  1. Slot & path
  2. Schema (entry shape, separator, dispatch-id source)
  3. Append-only contract
  4. Ownership boundary (agents write; orchestrator does not)
  5. Intended lifecycle
  6. Cross-references (ENG-87 dispatch-id glue,
     `dispatch_history.jsonl` sibling, contrast with
     `stage-summary-<stage>.md`)
- `CLAUDE.md` — one diagram-line edit + one short clarifying
  paragraph in `## Per-issue state directory`:
  - Diagram update (per A-009 anchors): `└── stage-summary-<stage>.md`
    becomes `├── stage-summary-<stage>.md`, and a new
    `└── progress.md         # append-only per-issue notebook (see docs/runbooks/progress-md.md)`
    line is appended directly below.
  - Paragraph (Task 7 — inserted AFTER the existing
    `issue-state.json` paragraph at lines 292-295, BEFORE the
    `The orchestrator NEVER dispatches into ...` paragraph at line
    297): one short paragraph differentiating `progress.md`'s
    never-cleared / agent-written contract from
    `stage-summary-<stage>.md`'s overwrite-per-dispatch contract.
    Pointer to the runbook URL.

Explicitly out of scope (per Linear issue's OUT list and
brainstorm §10):

- `bin/run-stage.sh::_clear_current_stage_slots`,
  `_validate_dispatch_envelope` — unchanged. The cleared-set stays
  exactly `stage-summary-${stage}.md` + `wait-${stage}.json` (per
  A-004). The envelope validator's transcript-scan content is
  unchanged (no `progress.md`-shaped scan added).
- `bin/run-local.sh`, `bin/run-local-helpers.sh` — unchanged.
  `progress.md` lives outside the worktree, so the sweep never sees
  it. No allowlist change in `partition_dirty_paths`. No
  `_always_include_paths` extension.
- `bin/scope-check.sh` — unchanged. Same out-of-worktree rationale.
- `bin/dispatch.sh`, `bin/render-prompt.sh`, `bin/linear.sh`,
  `bin/poll.sh`, `bin/verdict-handler.sh`, `bin/classify-failure.sh`,
  `bin/metrics.sh`, `bin/pipeline.sh`, `bin/pipeline-events.json` —
  unchanged. No new exit code, no new verdict variant, no new label,
  no new dispatch-time prompt token, no new metric.
- `AGENT_PROMPTS.md` — unchanged. The Linear issue's IN list
  excludes any agent writing or reading the file; per-stage prompt
  changes are owned by the writer-pilot (ENG-106) and
  implement-reader sub-tickets.
- `learned-rules/harness/*.md` — unchanged. Retrospective-owned;
  the plan-stage learned-rules file does not exist for the harness
  slug today (per A-016).
- `bin/run-retrospective-local.sh` — unchanged. Per brainstorm
  D-003 + A13: the retrospective is not extended to read
  `progress.md`; that's OQ-2.
- Any new helper for writing/appending entries (e.g.,
  `progress_md_append`) — explicitly deferred to ENG-106 per
  brainstorm OQ-1.
- ENG-87 HTML-comment marker integration on the file — explicitly
  out per the Linear OUT list and brainstorm D-002 rejected
  alternative.

## API Contract

no new API surface

(The harness has no FE↔BE API surface of its own — it is a Bash
orchestration toolkit. The dispatched agents talk to Linear / GitHub
via existing CLI shims, not via a typed contract this plan would
extend. This plan adds neither endpoints, payload types, nor schema
fields. The internal "API" added is the `progress_md_path` shell
function, whose contract is exhaustively documented by Tasks 2 + 4 +
the runbook; it is not an FE↔BE surface.)

## Backend Tasks

Tasks 2, 3, 5 can be authored in any order after Task 1 (a
read-only re-grep) completes. Task 4 (test fixtures) depends on
Tasks 2 and 3 because the fixtures call the new helper (defined in
Task 2) and the `progress_md_path` symbol must resolve in both the
sourcing process AND in any subshell-launched assertion (covered by
Task 3's `export -f` extension). Task 6 (CLAUDE.md diagram update)
depends on Task 5 (runbook creation) because the diagram-line
comment points at the runbook URL. Task 7 (CLAUDE.md clarifying
paragraph) depends on Task 6 (sequential edits in the same file
body; the paragraph follows the diagram). Task 8 (gate run) depends
on Tasks 2, 3, 4, 5, 6, 7. The implement agent SHOULD run Task 1
first, then any order of {Task 2, Task 3} (Task 3 is a one-line
edit; ordering against Task 2 does not matter since the helper
definition and the export are in different file regions), then Task
4, then Task 5, then Task 6, then Task 7, then Task 8.

(No Task 0 rebase: `HEAD..origin/main` is empty at plan time per
the Branch-base freshness section.)

### Task 1: Re-verify Assumption Inventory anchors at implement-time

- `depends_on: []`
- `touches: <read-only — no file edits>`

Steps:

- [ ] **1.1** Re-grep `bin/common.sh` for the two Task 2 anchor
  substrings (per A-001):
  - START anchor — the 3-line `issue_dir` closing block:
    ```
      printf '%s/%s' "$PROJECT_STATE_DIR" "$issue"
    }
    ```
  - END anchor — the literal next-block opening comment header:
    ```
    # Compute a stable sha256 over the set of files that drive pipeline
    ```
  Both MUST match exactly once. If either is absent OR appears more
  than once, halt with
  `bash bin/pipeline.sh event ENG-107 verdict halt --reason agent-blocked`
  and a Linear comment naming the drift.
- [ ] **1.2** Re-grep `bin/common.sh` for the Task 3 anchor (per
  A-002) — the literal full `export -f` line at column 0:
  `export -f issue_dir compute_pipeline_content_hash failure_outcome_for_exit parse_pipeline_marker is_orchestrator_paused set_orchestrator_paused allocate_dispatch_id current_dispatch_id assert_no_tool_invocation`
  MUST match exactly once. Halt-on-drift behavior as 1.1.
- [ ] **1.3** Re-grep `bin/common-test.sh` for the Task 4 anchor
  (per A-008) — the literal final printf line:
  `printf '\ncommon-test summary: %d passed, %d failed\n' "$PASS" "$FAIL"`
  MUST match exactly once. Halt-on-drift behavior.
- [ ] **1.4** Re-grep `CLAUDE.md` for the two Task 6 anchor lines
  (per A-009):
  - `        ├── issue-state.json`
  - `        └── stage-summary-<stage>.md`
  Both MUST match exactly once. Halt-on-drift behavior.
- [ ] **1.5** Confirm `docs/runbooks/progress-md.md` does NOT yet
  exist (`Glob` returns no match). If it exists, halt with
  `verdict halt --reason agent-blocked` and a comment naming the
  unexpected file.

If all five sub-steps pass, proceed to Tasks 2 / 3 / 4 / 5 / 6 / 7.

### Task 2: Insert progress_md_path helper in bin/common.sh

- `depends_on: [1]`
- `touches: bin/common.sh::progress_md_path` — new function inserted
  between `issue_dir` (closes ~line 72) and the
  `compute_pipeline_content_hash` block-header comment (~line 73)
  per A-001.

Steps:

- [ ] **2.1** Use a single `Edit` call with multi-line `old_string`
  anchored on the unique closing 3 lines of `issue_dir` AND the
  unique opening comment line of the `compute_pipeline_content_hash`
  block.

  Exact `old_string` (4 lines as they appear in the file —
  `issue_dir`'s `printf` line + closing brace + blank line + next
  block-header comment):

  ```
    printf '%s/%s' "$PROJECT_STATE_DIR" "$issue"
  }
  # Compute a stable sha256 over the set of files that drive pipeline
  ```

  Exact `new_string` (replacement — preserves `issue_dir`'s closing
  + the next block's header verbatim, inserts the new
  `progress_md_path` helper + a labelled comment between them):

  ```
    printf '%s/%s' "$PROJECT_STATE_DIR" "$issue"
  }
  # ENG-107: per-issue progress notebook path. Append-only contract;
  # never cleared on dispatch. See docs/runbooks/progress-md.md for
  # schema, lifecycle, and ownership boundary. Composed on issue_dir
  # so the resolution rules (PROJECT_STATE_DIR, bootstrap-mode
  # behaviour, die-on-empty-issue) match exactly.
  progress_md_path() {
    local issue="$1"
    [[ -n "$issue" ]] || die "progress_md_path: missing issue id"
    printf '%s/progress.md' "$(issue_dir "$issue")"
  }
  # Compute a stable sha256 over the set of files that drive pipeline
  ```

  Notes:
  - The function body delegates path composition to `issue_dir`
    rather than recomputing `$PROJECT_STATE_DIR/$issue/progress.md`
    inline, so future changes to `issue_dir` (e.g., a pre-mkdir,
    alternate slug-resolution rule) propagate automatically.
  - The `[[ -n "$issue" ]] || die "progress_md_path: missing issue id"`
    line mirrors `issue_dir`'s line 70 contract verbatim
    (string-substituting only the function name in the `die` token).
  - No `export -f progress_md_path` line is added INSIDE the function
    block — the export goes on the existing public `export -f` line
    in Task 3 to match the file's grouped-export convention.
  - The 5-line comment block above the function is the only
    documentation; the runbook URL (`docs/runbooks/progress-md.md`)
    appears in the comment so a future grep for "progress.md" lands
    here as well as in the runbook itself.

- [ ] **2.2** Verify by reading back `bin/common.sh` ~12 lines AFTER
  the original `issue_dir` closing brace. Confirm: (a) `issue_dir`'s
  closing brace and `printf` are preserved verbatim; (b) the new
  `progress_md_path` function appears immediately below; (c) the
  next block's `# Compute a stable sha256` header is preserved
  verbatim; (d) the function body has the literal `die` text
  `progress_md_path: missing issue id` (not `issue_dir: missing
  issue id` — common copy-paste bug); (e) the function body
  composes on `$(issue_dir "$issue")` rather than on
  `$PROJECT_STATE_DIR/$issue` directly.

- [ ] **2.3** Sanity-check `bash -n bin/common.sh` returns rc=0
  (syntax check; the harness has no shellcheck CI today per the
  profile's "Lint/check" gate, but `bash -n` is the cheapest local
  signal that the new function did not introduce a syntax error).
  If non-zero, the Edit introduced a syntax error — revert and
  re-apply.

### Task 3: Export progress_md_path from bin/common.sh

- `depends_on: [1]`
- `touches: bin/common.sh::export -f` — append the new function name
  to the existing public-export line at line 389 per A-002.

Steps:

- [ ] **3.1** Use a single `Edit` call with `old_string` =
  the full existing line and `new_string` = the same line with
  ` progress_md_path` appended.

  Exact `old_string` (single line, anchored at column 0 by `export -f `):

  ```
  export -f issue_dir compute_pipeline_content_hash failure_outcome_for_exit parse_pipeline_marker is_orchestrator_paused set_orchestrator_paused allocate_dispatch_id current_dispatch_id assert_no_tool_invocation
  ```

  Exact `new_string`:

  ```
  export -f issue_dir compute_pipeline_content_hash failure_outcome_for_exit parse_pipeline_marker is_orchestrator_paused set_orchestrator_paused allocate_dispatch_id current_dispatch_id assert_no_tool_invocation progress_md_path
  ```

  Notes:
  - Append-only — every existing exported name is preserved verbatim
    in the same order. Re-ordering would be an unrelated change
    outside this plan's scope.
  - The new token `progress_md_path` goes at the END of the list
    (not alphabetised) because the existing list is grouped by
    feature-family chronology, not alphabetical (e.g.,
    `allocate_dispatch_id` and `current_dispatch_id` come AFTER
    `is_orchestrator_paused` because ENG-87 landed after ENG-44).
    Adding the ENG-107 helper at the end follows the same
    convention.

- [ ] **3.2** Verify by reading back `bin/common.sh:389`. Confirm
  the `export -f` line ends with ` progress_md_path` (single
  trailing space + identifier, no trailing newline drift) and that
  the line is still column-0 (no accidental indentation).

### Task 4: Add ENG-107 fixtures to bin/common-test.sh

- `depends_on: [2, 3]`
- `touches: bin/common-test.sh` — new ENG-107 assertion block
  inserted IMMEDIATELY BEFORE the final summary printf at line 926
  per A-008.

Steps:

- [ ] **4.1** Use a single `Edit` call with `old_string` = the
  literal final printf line and `new_string` = the new ENG-107
  block + the same final printf line preserved verbatim.

  Exact `old_string` (single line, unique within the file):

  ```
  printf '\ncommon-test summary: %d passed, %d failed\n' "$PASS" "$FAIL"
  ```

  Exact `new_string` (the new block + the preserved final printf):

  ```
  # ─── ENG-107: progress_md_path helper ───────────────────────────────
  # Three assertions (brainstorm D-005):
  #   (a) path shape — returns $PROJECT_STATE_DIR/<ident>/progress.md
  #   (b) idempotence — two calls with the same id return identical strings
  #   (c) die-on-empty — empty id exits non-zero with the documented stderr
  eng107_path_shape() {
    local got expected
    got="$(progress_md_path ENG-1)"
    expected="$PROJECT_STATE_DIR/ENG-1/progress.md"
    assert_eq "eng107_progress_md_path_shape" "$expected" "$got"
  }
  eng107_path_shape

  eng107_idempotence() {
    local first second
    first="$(progress_md_path ENG-1)"
    second="$(progress_md_path ENG-1)"
    assert_eq "eng107_progress_md_path_idempotent" "$first" "$second"
  }
  eng107_idempotence

  eng107_die_on_empty() {
    local rc=0 stderr
    # Capture stderr; subshell so `die`'s exit does not abort the test.
    stderr="$( ( progress_md_path "" ) 2>&1 1>/dev/null )" || rc=$?
    if (( rc != 0 )) && [[ "$stderr" == *"progress_md_path: missing issue id"* ]]; then
      report_ok "eng107_progress_md_path_die_on_empty"
    else
      report_fail "eng107_progress_md_path_die_on_empty" \
        "rc!=0 AND stderr containing 'progress_md_path: missing issue id'" \
        "rc=$rc stderr=${stderr}"
    fi
  }
  eng107_die_on_empty

  printf '\ncommon-test summary: %d passed, %d failed\n' "$PASS" "$FAIL"
  ```

  Notes:
  - The block uses the existing `assert_eq`/`report_ok`/`report_fail`
    helpers (defined at lines 38-46 per A-007); no new helper functions
    introduced.
  - The block name uses the `eng107_` prefix to namespace it against
    the existing ENG-44 (rows 1-6 at lines 84-128) / ENG-49 / ENG-87
    fixtures already in the file.
  - Each assertion is wrapped in a one-shot named function that is
    immediately invoked; this matches the file's existing pattern
    (e.g., `row1_state_file_absent_falls_to_config_true` at lines
    84-90).
  - Test (c)'s subshell wrap (`( progress_md_path "" )`) is the
    standard idiom for capturing `die`'s exit without aborting the
    parent test process. `set -e` is relaxed at line 35 of
    `bin/common-test.sh` (`set +e`) so the failed call's non-zero
    rc is observable via the `|| rc=$?` pattern.
  - `PROJECT_STATE_DIR` is set at `bin/common.sh:57` to
    `${HARNESS_STATE_DIR}/${PROJECT_SLUG}`. With
    `PROJECT_SLUG=test-slug` (line 30 of `common-test.sh`), the
    expected path is
    `<HARNESS_STATE_DIR>/test-slug/ENG-1/progress.md`. The fixture
    derives `expected` from `$PROJECT_STATE_DIR` directly (not
    hard-coding the slug) so the assertion follows whatever
    `PROJECT_STATE_DIR` resolves to in the test process.

- [ ] **4.2** Run `bash bin/common-test.sh`. Expect exit 0; the new
  three rows appear in the summary as `OK: eng107_progress_md_path_shape`,
  `OK: eng107_progress_md_path_idempotent`,
  `OK: eng107_progress_md_path_die_on_empty`. If any assertion
  fails, diagnose against the path-derivation logic in Task 2 (most
  likely cause: helper composes on `$PROJECT_STATE_DIR/$issue`
  inline rather than via `$(issue_dir "$issue")`, breaking
  idempotence under a slug change).

### Task 5: Author docs/runbooks/progress-md.md

- `depends_on: [1]`
- `touches: docs/runbooks/progress-md.md` — new file (~80 lines).

Steps:

- [ ] **5.1** Create the file `docs/runbooks/progress-md.md` with
  YAML frontmatter and six sections per brainstorm D-004. The
  required sections, each one H2:

  1. `## 1. Slot & path` — names the file path
     `$(issue_dir <ident>)/progress.md`, references the helper
     `progress_md_path` in `bin/common.sh`, points at the brainstorm
     for design rationale (literal link
     `docs/brainstorms/2026-05-15-eng-107-progress-md-schema-and-per-issue-state-dir-slot-design.md`).
  2. `## 2. Schema` — restates D-002 entry format. Canonical
     entry (codeblock):

     ```markdown
     ## ENG-N-d0001 - brainstorming - 2026-05-15T12:34:56Z

     Free-form prose. Anything the agent thinks the next dispatch
     on this issue should know. Decisions, dead-ends, open
     questions, surprises.
     ```

     Heading rules: three tokens separated by ` - ` (ASCII hyphen
     with surrounding single spaces). Token 1 is the dispatch-id
     (`PIPELINE_DISPATCH_ID` exported by
     `bin/common.sh::allocate_dispatch_id`, format
     `ENG-N-d<NNNN>`). Token 2 is the gerund-form stage name
     (`brainstorming|planning|implementing|ui|reviewing|qa|building|released`).
     Token 3 is an ISO-8601-UTC timestamp at second precision. The
     em-dash variant (` — `) is also acceptable per brainstorm §11;
     the ASCII hyphen is recommended for grep-friendliness.
  3. `## 3. Append-only contract` — writers MUST append, never edit
     a prior entry, never rewrite the file from scratch. Reads are
     unrestricted. The contract is a CONVENTION, not a filesystem
     ACL — no chmod-only-append is in place.
  4. `## 4. Ownership boundary` — stage agents write; orchestrator
     does not. Cross-reference `bin/run-stage.sh:865-873`
     (`_clear_current_stage_slots`) and confirm `progress.md` is
     intentionally absent from the cleared set. Cross-reference
     `bin/run-local-helpers.sh::partition_dirty_paths` and confirm
     the file is outside the worktree (lives under
     `$PROJECT_STATE_DIR/<ident>/`), so the sweep never sees it.
  5. `## 5. Intended lifecycle` — file created by the first writer
     (per ENG-106 / writer-pilot sub-ticket); accumulates for the
     life of the issue; survives `--action continue` resume;
     never auto-pruned. Operator-only cleanup (rm) is the terminal
     mechanism. Most issues at any moment have zero entries; absence
     of the file is a legitimate, expected state.
  6. `## 6. Cross-references` — ENG-87 dispatch-id glue (the schema
     relies on `PIPELINE_DISPATCH_ID` per heading); contrast with
     `stage-summary-<stage>.md` (overwrite-per-dispatch contract per
     ENG-77, see `bin/run-stage.sh:865-873`); contrast with
     `wait-<stage>.json` (overwrite-per-dispatch); similarity to
     `dispatch_history.jsonl` (append-only forensic, never cleared,
     but machine-readable JSONL not agent-readable markdown — see
     CLAUDE.md "Cross-dispatch staleness contract" §"`dispatch_history.jsonl`").

  YAML frontmatter shape (matching `docs/runbooks/recovery.md` shape
  per A-011):

  ```
  ---
  title: ENG-107 progress.md schema and per-issue state-dir slot — runbook
  date: 2026-05-15
  ---
  ```

  The H1 title under the frontmatter:
  `# Runbook — progress.md (per-issue notebook)`.

- [ ] **5.2** Verify by `Read`-ing back the new file. Confirm:
  (a) YAML frontmatter present with `title:` and `date:`;
  (b) H1 title present; (c) all six H2 sections present in order;
  (d) Section 4 explicitly cross-references
  `bin/run-stage.sh:865-873` AND `bin/run-local-helpers.sh::partition_dirty_paths`;
  (e) Section 6 explicitly cross-references both
  `stage-summary-<stage>.md` AND `dispatch_history.jsonl`;
  (f) the canonical-entry codeblock in Section 2 uses the literal
  ` - ` (space-hyphen-space) separator (NOT ` · ` middle-dot, NOT
  bare `-` without spaces).

- [ ] **5.3** Confirm the file is the ONLY new file created by this
  plan: `git status --porcelain | awk '$1=="??"{print $2}'` should
  list `docs/runbooks/progress-md.md` and nothing else (besides the
  new plan doc itself, which is committed by the orchestrator's
  pre-existing flow). Any other untracked path is sub-agent debris
  per ENG-100; halt with `verdict halt --reason agent-blocked` and
  a comment naming the leaked path.

### Task 6: Update CLAUDE.md per-issue state-directory diagram

- `depends_on: [5]`
- `touches: CLAUDE.md` — single edit site, the tree diagram at
  lines 286-289 per A-009 anchors.

Steps:

- [ ] **6.1** Use a single `Edit` call with multi-line `old_string`
  anchored on the existing two-line block of the diagram's last
  entries (the `issue-state.json` line + the `stage-summary-<stage>.md`
  line) and `new_string` = the same two lines with the
  `stage-summary-<stage>.md` line's box-drawing character flipped
  from `└` to `├` AND a new `progress.md` line appended.

  Exact `old_string` (2 lines as they appear in the file):

  ```
          ├── issue-state.json
          └── stage-summary-<stage>.md
  ```

  Exact `new_string` (3 lines — same two preserved with the second's
  glyph flipped, plus a new `└── progress.md` row):

  ```
          ├── issue-state.json
          ├── stage-summary-<stage>.md
          └── progress.md         # append-only per-issue notebook (see docs/runbooks/progress-md.md)
  ```

  Notes:
  - The box-drawing character on `stage-summary-<stage>.md` flips
    from `└` (last child) to `├` (intermediate child) because
    `progress.md` is now the last child.
  - The trailing comment on the new line points at the runbook (per
    brainstorm D-004 + the existing diagram convention — every other
    sibling that has a comment uses ` # ` separation).
  - Indentation is 8 spaces (matching the existing
    `        ├── issue-state.json` line). Box-drawing characters
    are the same UTF-8 code points (`├`, `└`, `──`) as already in
    the diagram. No alignment-padding rework is in scope.

- [ ] **6.2** Verify by reading back `CLAUDE.md` lines 285-292.
  Confirm: (a) the `worktree/` line above is unchanged; (b)
  `issue-state.json` line is unchanged (still `├──`); (c)
  `stage-summary-<stage>.md` glyph flipped from `└` to `├`; (d)
  the new `progress.md` line appears with `└──` glyph and the
  trailing comment pointing at the runbook URL; (e) the closing
  ``` ``` ``` fence below the diagram is preserved.

### Task 7: Add CLAUDE.md clarifying paragraph about progress.md lifecycle

- `depends_on: [6]`
- `touches: CLAUDE.md` — insert one short paragraph in `## Per-issue
  state directory` between the `issue-state.json` paragraph (lines
  292-295) and the `The orchestrator NEVER dispatches into ...`
  paragraph (line 297).

Steps:

- [ ] **7.1** Use a single `Edit` call with multi-line `old_string`
  anchored on the unique closing line of the `issue-state.json`
  paragraph AND the unique opening line of the next paragraph.

  Exact `old_string` (3 lines as they appear in the file —
  `issue-state.json` paragraph closing line + blank line + next
  paragraph opening line):

  ```
  `AGENT_PROMPTS.md`) and branch-head SHA.

  The orchestrator NEVER dispatches into `$TARGET_REPO` — every dispatch resolves
  ```

  Exact `new_string` (replacement — preserves both bookends, inserts
  the new paragraph + a trailing blank line in between):

  ```
  `AGENT_PROMPTS.md`) and branch-head SHA.

  `progress.md` is an append-only per-issue notebook with the OPPOSITE
  lifecycle from `stage-summary-<stage>.md`: it accumulates across the
  issue's entire lifetime, is never cleared on dispatch start, and
  survives `--action continue` resume. Stage agents write entries; the
  orchestrator never reads or writes the file. Schema and the
  canonical heading shape (`## <dispatch-id> - <stage> -
  <ISO-8601-UTC>`) live in `docs/runbooks/progress-md.md`. Path
  resolves through `bin/common.sh::progress_md_path <ident>`.

  The orchestrator NEVER dispatches into `$TARGET_REPO` — every dispatch resolves
  ```

  Notes:
  - The new paragraph lives in CLAUDE.md prose (not in the tree
    diagram), so no box-drawing characters or fixed indentation.
  - The body length is intentionally short (~6 lines) — the runbook
    carries the full schema. CLAUDE.md is the index, not the
    contract.
  - The reference to `progress_md_path` in the closing line gives a
    grep target: a future reader asking "where's the path defined?"
    lands here (CLAUDE.md), in `bin/common.sh` (definition),
    `bin/common-test.sh` (test fixtures), and the runbook.

- [ ] **7.2** Verify by reading back the modified region of
  `CLAUDE.md`. Confirm: (a) the `issue-state.json` paragraph closing
  line is preserved verbatim; (b) the new `progress.md is an
  append-only ...` paragraph appears in between; (c) the
  `The orchestrator NEVER dispatches into ...` paragraph opening
  line is preserved verbatim; (d) the new paragraph's heading-shape
  example uses ` - ` (ASCII space-hyphen-space) matching the
  runbook's Section 2.

### Task 8: Run gates

- `depends_on: [2, 3, 4, 5, 6, 7]`
- `touches: <runtime gates only — no file edits>`

Steps:

- [ ] **8.1** Run `bash bin/common-test.sh`. Expect exit 0 with the
  three new ENG-107 rows passing. If FAIL, diagnose against the
  most-recent change (most likely: Task 2 helper body, Task 3
  export, Task 4 fixture-shape).
- [ ] **8.2** Run `bash .githooks/pre-commit`. Expect exit 0 (full
  `bin/*-test.sh` suite green; the per-stage allowlist for
  `implementing` includes `Bash(bash .githooks/pre-commit:*)` per
  the harness profile's `## Tool allowlist` section). If FAIL on
  any test other than `bin/common-test.sh`, diagnose: this plan
  touches no production code other than `bin/common.sh`, so any
  unrelated test failure is either a pre-existing failure (consult
  the hook's `KNOWN_BROKEN` allowlist) OR a sibling sweep
  collateral (re-confirm Task 5.3 — no untracked sub-agent debris).
- [ ] **8.3** Run `bash -n bin/common.sh` for the syntax-only check
  per the profile's "Lint/check" gate. Expect rc=0.

If 8.1, 8.2, and 8.3 all pass, the implementation is complete.

## Frontend Tasks

(no UI surface — the harness is a Bash orchestration toolkit; there
is no FE the UI agent would touch. The UI Agent is skipped for this
ticket per the orchestrator's per-stage routing.)

## Failure Mode → Test Map

Pulled from the brainstorm's §5 "Error Handling" + §6 "Edge Cases"
sections.

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
|---|---|---|---|---|
| Helper called without an issue id | `progress_md_path ""` (or with omitted arg) | `die` exits rc=1 with stderr `FATAL: progress_md_path: missing issue id` | unit | `eng107_progress_md_path_die_on_empty` (in `bin/common-test.sh`) |
| Helper returns drifting paths across two calls | `progress_md_path ENG-1` then `progress_md_path ENG-1` in the same shell | both calls return identical strings (both compose on `issue_dir`) | unit | `eng107_progress_md_path_idempotent` (in `bin/common-test.sh`) |
| Helper returns the wrong shape for a known issue | `progress_md_path ENG-1` with `PROJECT_STATE_DIR=…/test-slug` | returns `$PROJECT_STATE_DIR/ENG-1/progress.md` exactly | unit | `eng107_progress_md_path_shape` (in `bin/common-test.sh`) |
| Helper not exported into subshell | `bash -c 'progress_md_path ENG-1'` after sourcing `common.sh` in parent | resolves and returns the canonical path (proves Task 3 export landed) | unit (covered by 8.1's full `bin/common-test.sh` rerun, and by 8.2's pre-commit hook running `bin/common-test.sh` in a subshell) | `eng107_progress_md_path_shape` (subshell-invocation form runs as part of the same row) |
| Function-name token missing from public `export -f` line | `progress_md_path` not appended in Task 3 | `bash -c 'progress_md_path ENG-1'` from a re-sourced subshell errors `command not found` | unit (caught by 8.2's pre-commit running every `bin/*-test.sh` in fresh subshells) | covered indirectly by `eng107_progress_md_path_shape` running under the test's `set +e` after re-source |
| Schema runbook absent | first writer sub-ticket (ENG-106) lands without the runbook | NOT a runtime failure for ENG-107; covered by Task 5.2 read-back confirming the runbook exists with all six H2 sections | smoke (manual; Task 5.2 read-back) | `(manual; runbook read-back)` |
| CLAUDE.md diagram missing the `progress.md` line | Task 6 omitted | NOT a runtime failure; covered by Task 6.2 read-back | smoke (manual; Task 6.2 read-back) | `(manual; CLAUDE.md diagram read-back)` |
| Sub-agent debris (a fixture file written outside the allowlist) | implement agent writes `.review-body.md` / fixture markdown / scratch text at the worktree root | `bin/run-local.sh`'s `partition_dirty_paths` classifies as self-leak; soft fail incrementing `.consecutive-failures` | integration (orchestrator-side; covered by `bin/run-local-sweep-test.sh` which already gates this surface for every issue) | covered by existing `bin/run-local-sweep-test.sh` (no new fixture needed; the implement agent's prompt + Task 5.3 read-back are the prevention) |
| Wrong-separator schema example in runbook (e.g., `·` middle-dot or bare `-`) | Task 5.1 typo in the canonical-entry codeblock | NOT a runtime failure today (no validator scans the runbook); covered by Task 5.2 read-back confirming ` - ` (ASCII space-hyphen-space) | smoke (manual; Task 5.2 read-back) | `(manual; runbook codeblock read-back)` |

(Schema-violation by future writers is explicitly NOT in scope per
brainstorm §5: ENG-107 ships a contract, not a validator. A
`progress.md`-shaped envelope-validator extension is OQ-3 in the
brainstorm and has its own future ticket if the writer pilot
surfaces a need.)

## Test Strategy

- **Unit (new).** Three assertions in `bin/common-test.sh` covering
  the helper's path shape, idempotence, and die-on-empty contract.
  Each assertion uses the existing `assert_eq`/`report_ok`/`report_fail`
  helpers (no new test scaffolding). The test sources `common.sh`
  once at the file's top per the existing pattern (line 33), so the
  fixtures see the same `PROJECT_STATE_DIR` resolution path the
  helper uses in production.

- **Unit (existing — re-run as gate).** `bin/common-test.sh`'s
  pre-existing rows (ENG-44 is_orchestrator_paused six-row table at
  lines 84-128, ENG-87 allocate_dispatch_id rows, ENG-81
  try_acquire_lock + acquire_claude_mutex rows up through line 925)
  re-run unchanged in the same test process; any regression caused
  by the new function definition (e.g., a `set -e` interaction, a
  source-time die) would surface as a row failure in the existing
  suite. Task 8.1 gates on the full file's exit status, not just
  the three new rows.

- **Integration (existing — re-run as gate).** `.githooks/pre-commit`
  runs the full `bin/*-test.sh` suite (per the harness profile's
  `## Tool allowlist` section, `Bash(bash .githooks/pre-commit:*)`
  is on the implementing-stage allowlist). Task 8.2 gates on the
  full suite. The relevant sibling tests for an unintended
  cross-cutting regression include
  `bin/run-stage-test.sh` (verifies `_clear_current_stage_slots`
  enumerates exactly the documented set; no change in this plan
  means it stays green), `bin/run-local-sweep-test.sh` (verifies
  `partition_dirty_paths` classification; no change in this plan
  means out-of-worktree paths stay invisible), and
  `bin/render-prompt-test.sh` (verifies `AGENT_PROMPTS.md`
  fence-count + token resolution; no change in this plan means it
  stays green).

- **Smoke (manual at implement-time).** Task 5.2 (runbook
  read-back), Task 6.2 (CLAUDE.md diagram read-back), Task 7.2
  (CLAUDE.md paragraph read-back). These are the
  documentation-correctness gates; no executable test today asserts
  the runbook's H2 section list or the CLAUDE.md paragraph's
  presence. Adding a script to assert these is plausible (matches
  the `bin/agent-prompts-content-test.sh` pattern for prompt
  content) but is OUT of scope per Linear AC — the AC requires the
  documents EXIST and DOCUMENT the schema, not that they are
  test-pinned. Adding a content test would be gold-plating.

- **Adversarial (none new).** The helper is a 5-line pure path
  composer with one guard. There is no I/O, no syscall, no
  Linear/git/jq dependency, no credential surface, no race surface.
  The brainstorm §5 explicitly states "It cannot fail in any other
  shape." No adversarial test layer is required.

- **End-to-end (none new).** No agent writes or reads the file in
  this ticket; there is no end-to-end behavior to assert. The
  writer-pilot (ENG-106) is the first ticket where end-to-end
  behaviour becomes testable, and that ticket owns the
  corresponding test surface.

- **Test-gate closure.** Per A-014, this plan REMOVES no tokens
  from any tracked file. The closure sweep has no test files to
  audit for soon-to-be-broken pinned-absent assertions. Three new
  tokens introduced (`progress_md_path`, `progress.md`,
  `docs/runbooks/progress-md.md`) — none are pinned-ABSENT by any
  existing `bin/*-test.sh`. Zero closure defects.
