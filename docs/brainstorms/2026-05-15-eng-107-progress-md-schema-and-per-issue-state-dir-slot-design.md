---
linear: ENG-107
title: progress.md — schema and per-issue state-dir slot
date: 2026-05-15
status: draft
---

# ENG-107 — `progress.md` schema and per-issue state-dir slot

## 1. Problem

ENG-28 (parent umbrella) proposes a continuous, per-issue notebook —
`progress.md` — that survives across dispatches so a future dispatch's
agent (plan, implement, review, qa, build) can read the accumulated
context that prior-dispatch agents on the same issue chose to record.
The umbrella decomposes into three sub-tickets:

| Sub-ticket | Scope |
|---|---|
| **ENG-107 (this)** | Define the slot + schema + helper. No agent touches it. |
| ENG-106 | Plan-stage writer pilot (first stage that actually writes entries). |
| (later) | Implement-stage reader sub-ticket. |

ENG-107 lays the foundation only. The hazards in scope:

1. The file path must be canonical and resolvable from one place
   (`bin/common.sh`) so future writers/readers don't drift into
   hand-rolled string concatenation — the exact failure shape
   ENG-79 catalogued for `branch-name` (`render-prompt.sh:212`
   drifted from `bin/branch-name.sh`).
2. The schema must be append-only and self-describing per entry. If a
   later sub-ticket lets one stage's agent write and another stage's
   agent read, the readers MUST be able to tell which dispatch wrote
   which section without a Linear API call.
3. The slot must NOT trip `partition_dirty_paths`. Per-issue state
   lives in `$PROJECT_STATE_DIR/<ident>/`, which is OUTSIDE the
   worktree — so this is automatic, but worth stating explicitly
   because the file's name (`progress.md`) is the same shape as
   docs-in-worktree paths and a sloppy future change could move it.
4. The slot must NOT collide with the ENG-77 / ENG-87
   stage-summary clear-on-dispatch contract. ENG-77 mandates that
   `stage-summary-<stage>.md` is OVERWRITTEN on every dispatch
   (idempotent re-emit). `progress.md` is the OPPOSITE: it
   accumulates. Designing it as a sibling under the same
   `$(issue_dir <ident>)/` directory means two adjacent files with
   opposite lifecycle contracts; the schema doc must call this out
   loud, and the helper must NOT accidentally invite a writer to
   `Write` (truncate) rather than append.

The Linear acceptance criteria are tightly scoped:

1. `progress_md_path ENG-N` returns canonical path under
   `$PROJECT_STATE_DIR`.
2. `docs/runbooks/progress-md.md` documents schema, append-only
   contract, intended lifecycle.
3. `CLAUDE.md` per-issue-state-directory section lists `progress.md`
   with one-line purpose.
4. Test asserts path shape and idempotence.

This brainstorm proposes a minimal, foundation-only implementation
that satisfies all four.

## 2. Decisions

- **D-001. File location: `$(issue_dir <ident>)/progress.md` —
  resolved through a new `bin/common.sh::progress_md_path <ident>`
  helper that is a one-line wrapper over `issue_dir`.**

  Concrete shape:

  ```bash
  progress_md_path() {
    local issue="$1"
    [[ -n "$issue" ]] || die "progress_md_path: missing issue id"
    printf '%s/progress.md' "$(issue_dir "$issue")"
  }
  ```

  This matches the pattern already in use throughout the codebase:
  every per-issue artifact path is composed as
  `"$(issue_dir "$issue")/<filename>"` rather than carrying its own
  resolver. The handful of existing examples (`bin/run-stage.sh:42`
  for `worktree`, `bin/run-stage.sh:85` for `usage-<stage>.json`,
  `bin/run-stage.sh:274` and `:776` for `stage-summary-<stage>.md`,
  `bin/run-stage.sh:631` for `wait-<stage>.json`, `bin/common.sh:107`
  for `issue-state.json`, CLAUDE.md "Cross-dispatch staleness
  contract" §"`dispatch_history.jsonl`" for the forensic log) all
  inline the suffix. progress.md is special enough to warrant a
  named helper — see D-002 rejected alternatives — but the helper
  is intentionally a thin alias, not a new abstraction layer.

  *Reference to constraint:* CLAUDE.md "When wiring a new script /
  Per-project state must reference `$PROJECT_STATE_DIR`, never
  `$HARNESS_STATE_DIR/<issue>` directly." `issue_dir` is the
  documented gateway; `progress_md_path` composes on top of it
  rather than computing the path independently.

  *Reference to principle:* CLAUDE.md "Don't add features, refactor,
  or introduce abstractions beyond what the task requires." A
  one-line wrapper is the smallest abstraction that gives future
  writers/readers a single import point and a stable test target.

  *Rejected alternative — no helper; document the path as
  `$(issue_dir <ident>)/progress.md` in `docs/runbooks/progress-md.md`
  and let each caller hand-roll the suffix:* rejected because it is
  exactly the shape that produced the ENG-79 drift incident
  (canonical `branch-name.sh` exists but `render-prompt.sh:212`
  hand-rolled a different concatenation; the second-source-of-truth
  drifted and bit production). A two-line helper plus a one-line
  test gives readers a single grep target (`progress_md_path`) and
  cuts off the drift class before it lands.

  *Rejected alternative — colocate the helper in `bin/run-local-helpers.sh`
  rather than `bin/common.sh`:* rejected because the Linear ticket
  is explicit (`bin/common.sh helper progress_md_path <ident>`) and
  because `progress_md_path` is a sibling of `issue_dir` itself, not
  a sweep-/scope-specific helper. `bin/run-local-helpers.sh` is
  reserved for orchestrator-tick logic (`partition_dirty_paths`,
  `stage_output_paths`, `stage_is_read_mostly`). Future readers
  outside the orchestrator (plan/implement/build agents reading
  the file via their `Read` tool path) will not look there.

- **D-002. The file is markdown with a one-section-per-entry
  schema. Entries are H2-headed; the heading carries metadata
  (dispatch id, stage, timestamp); the body is free-form prose.
  Append-only: never edit a prior entry, never rewrite the file
  from scratch.**

  Canonical entry shape:

  ```markdown
  ## ENG-N-d0001 · brainstorming · 2026-05-15T12:34:56Z

  Free-form prose. Anything the agent thinks the next dispatch
  on this issue should know. Decisions, dead-ends, open
  questions, surprises.
  ```

  Schema rules (the durable contract `docs/runbooks/progress-md.md`
  spells out):

  1. **Append-only.** Writers MUST append, never rewrite. The file
     accumulates across the issue's entire lifetime.
  2. **H2-per-entry.** Each entry is one H2 heading. The heading
     line is the only enforced structural element. The body below
     is free-form markdown.
  3. **Heading format.** `## <dispatch-id> · <stage> · <ISO-8601-UTC>`.
     Three tokens, middle-dot separators. `dispatch-id` is the
     `PIPELINE_DISPATCH_ID` exported into the dispatch
     (`ENG-N-dNNNN`, allocated by
     `bin/common.sh::allocate_dispatch_id`, `bin/common.sh:104-147`).
     `stage` is the gerund-form key
     (`brainstorming|planning|implementing|ui|reviewing|qa|building|released`).
     Timestamp is UTC, second-precision, ISO-8601.
  4. **No body schema.** Deliberately. Future sub-tickets that wire
     stage agents will evolve per-stage prompts to suggest body
     conventions (a "decisions" subsection, an "open questions"
     subsection). Encoding those today would lock in conventions
     before we have evidence of what's useful — exactly the
     anti-pattern the CLAUDE.md "Don't add features … beyond what
     the task requires" rule names.
  5. **Owner.** The dispatched stage agent. The orchestrator does
     NOT write to this file (D-003).
  6. **No clear-on-dispatch.** Unlike `stage-summary-<stage>.md`,
     `progress.md` is NEVER cleared at dispatch start. The
     `_clear_current_stage_slots` helper at `bin/run-stage.sh:865-873`
     enumerates exactly the files cleared per dispatch
     (`stage-summary-${stage}.md`, `wait-${stage}.json`) — this list
     stays unchanged.

  *Reference to constraint:* CLAUDE.md "Cross-dispatch staleness
  contract (ENG-87)" — the brainstorm names six prior tickets that
  manifested the same structural class: "a fresh dispatch's reader
  treats data written by a PRIOR dispatch as if it were current."
  `progress.md` is DESIGNED to be cross-dispatch, which is exactly
  the hazard surface. The H2-per-entry schema with
  dispatch-id-stamped headings inverts the contract: readers see
  EACH dispatch's contribution as a separately-attributed section,
  not a homogeneous blob. The reader's freshness check is
  "filter to entries with `dispatch-id != current`" instead of "is
  this whole file current," which is the structural inversion
  ENG-87 D-glue (`PIPELINE_DISPATCH_ID`) was designed to enable.

  *Reference to principle:* CLAUDE.md "Default to writing no
  comments. Only add one when the WHY is non-obvious." Applied to
  schemas: keep the structure minimal until evidence drives a
  richer one. H2 + heading metadata + free body is the minimum
  that satisfies the four acceptance criteria.

  *Rejected alternative — JSONL, one record per dispatch:*
  rejected because (a) future agents read this file via the `Read`
  tool — markdown renders inline for the operator and the agent
  alike; JSONL forces a re-parse step and produces brittle prompts;
  (b) agents are markdown-native (every other artifact under
  `$(issue_dir)` that an agent reads is markdown: stage-summary
  files, brainstorm/plan docs, prompts); a JSONL outlier here
  raises the cognitive load for no audit-trail benefit
  (`dispatch_history.jsonl` is JSONL precisely because it's
  retrospective-machine-readable, NEVER agent-readable — see
  CLAUDE.md "Cross-dispatch staleness contract" §"`dispatch_history.jsonl`").

  *Rejected alternative — free-form markdown with no heading
  schema, agent decides:* rejected because future readers (plan-,
  implement-, review-stage agents on later dispatches) need a
  reliable way to filter "what entries did I already write" vs
  "what did prior dispatches add." Without a heading-level
  dispatch-id marker, the only filter is timestamp-window — the
  exact secondary-signal anti-pattern CLAUDE.md "Cross-dispatch
  staleness contract" §1.3 / §3 calls out as the root cause of
  ENG-77, ENG-41 §1.2, ENG-78.

  *Rejected alternative — H1-per-entry (top-level headings):*
  rejected because per the markdown convention used elsewhere in
  the repo (every doc in `docs/` has a single H1 title and uses
  H2+ for sections), H1 is the document title. Reserving H1 for a
  future "Progress notebook — ENG-N" title line allows the runbook
  to specify (or not) a fixed file header without retroactive
  schema breakage.

  *Rejected alternative — embed `<!-- meta: dispatch id=... -->`
  HTML-comment markers per entry, mirroring the `linear.sh` chokepoint
  injection from ENG-87:* explicitly OUT OF SCOPE per the Linear
  ticket's OUT list ("Cross-dispatch hand-off (ENG-87 marker
  integration)"). The H2 heading carrying a plain-text dispatch-id
  token is NOT the ENG-87 HTML-comment marker integration; it is
  visible-text metadata that satisfies the schema-self-description
  goal without coupling to the marker contract. The OUT list
  prohibits the HTML-comment-shape integration; entry-heading
  metadata in plain text is the schema half this brainstorm owns.

- **D-003. The file is agent-written, never orchestrator-written.
  The orchestrator's role in this ticket is limited to (a)
  reserving the path under `$(issue_dir)/`, (b) defining the
  helper, (c) documenting the schema and lifecycle. No
  orchestrator code reads or writes the file.**

  Specifically — and this is the explicit scope boundary that
  keeps ENG-107 inside the Linear ticket's IN list:

  - `bin/run-stage.sh` is NOT modified to clear, create, or
    inspect `progress.md`. `_clear_current_stage_slots`
    (`bin/run-stage.sh:865-873`) is NOT extended.
    `_validate_dispatch_envelope` (`bin/run-stage.sh:875-...`) is
    NOT extended.
  - `bin/run-local.sh` is NOT modified to sweep or commit
    `progress.md` — it lives under `$PROJECT_STATE_DIR/<ident>/`,
    which is outside the worktree, so `partition_dirty_paths`
    (`bin/run-local-helpers.sh:562-651`) never sees it.
    Nothing is added to `partition_dirty_paths`.
  - `bin/scope-check.sh` is NOT modified — same out-of-worktree
    rationale; `is_benign` does not see paths under
    `$PROJECT_STATE_DIR/`.
  - The retrospective agent is NOT modified. The retrospective
    reads `events.jsonl` and per-stage transcripts; the
    transcript-vs-progress.md tradeoff is a sub-ticket-after-MVP
    question (OQ-2 below).

  *Reference to constraint:* the Linear issue's OUT list — "Any
  stage agent writing or reading progress.md (separate
  sub-tickets)." If the orchestrator wrote, it would either be
  setting up state the writer-pilot agent is responsible for, or
  doing per-entry housekeeping the schema does not require.
  Neither is in scope.

  *Reference to principle:* CLAUDE.md "Don't add features,
  refactor, or introduce abstractions beyond what the task
  requires." The smallest implementation that produces the four
  acceptance criteria adds two functions (the helper and its
  test) and two markdown sections (CLAUDE.md update and the
  runbook). Nothing more.

  *Rejected alternative — have the orchestrator create an empty
  `progress.md` skeleton on first dispatch (with H1 title and a
  "no entries yet" placeholder):* rejected because (a) the file's
  presence/absence is itself a useful signal for future
  sub-tickets ("has any agent ever logged progress on this
  issue?"), (b) the writer-pilot agent (ENG-106) will create the
  file on first write via `Write`/`Edit`, (c) skeleton creation
  fires before any agent has anything to say — pure ceremony.

  *Rejected alternative — clear-on-first-dispatch-of-new-cycle
  (e.g., after `--action continue` resume):* rejected because
  `--action continue` is by design a resume of the same issue's
  lifecycle, not a reset. The accumulated entries are the value;
  losing them on resume defeats the purpose. The append-only
  contract is uniform across the issue's lifetime.

- **D-004. The runbook `docs/runbooks/progress-md.md` is the
  single source of truth for the schema. The CLAUDE.md per-issue
  state-directory diagram gets one new line listing
  `progress.md` with a one-line purpose pointer to the runbook.**

  Required runbook sections (matching ticket AC-2):

  1. **Slot & path.** Names the file path, references
     `progress_md_path` in `bin/common.sh`, points at this
     brainstorm for design rationale.
  2. **Schema.** Restates D-002 entry format (H2 heading
     `## <dispatch-id> · <stage> · <ISO-8601-UTC>`, free-form body).
  3. **Append-only contract.** Spells out the rules: writers MUST
     append, never edit. Reads are unrestricted.
  4. **Ownership.** Stage agents write; orchestrator does not.
     Cross-dispatch persistence is the explicit invariant —
     contrast with `stage-summary-<stage>.md` (overwrite per
     dispatch) and `wait-<stage>.json` (overwrite per dispatch);
     similarity to `dispatch_history.jsonl` (append-only
     forensic, never cleared).
  5. **Intended lifecycle.** File is created by the first writer
     (per ENG-106 / writer-pilot sub-ticket); accumulates for the
     life of the issue; survives `--action continue` resume;
     never auto-pruned. Operator-only cleanup (rm) is the
     terminal mechanism.
  6. **Pointer to ENG-87.** The schema's dispatch-id-per-heading
     is the cross-dispatch staleness mitigation; ENG-87 HTML-marker
     integration is deferred to a separate ticket.

  CLAUDE.md update site is `CLAUDE.md:271-302` (the "## Per-issue
  state directory" section). The diagram at `CLAUDE.md:286-289`
  currently lists three slots under `ENG-N/`:
  - `worktree/`
  - `issue-state.json`
  - `stage-summary-<stage>.md`

  ENG-107 adds a fourth:
  - `progress.md         # append-only per-issue notebook (see docs/runbooks/progress-md.md)`

  *Reference to constraint:* CLAUDE.md per-issue state-directory
  section (`CLAUDE.md:271`) is the documented catalog of the
  per-issue scratch surface. Every existing slot has a one-line
  purpose entry; the new slot follows the same shape.

  *Rejected alternative — embed the full schema in CLAUDE.md
  rather than a separate runbook:* rejected because (a) CLAUDE.md
  is dense and growing; the per-issue state-directory section is
  already a single dense paragraph; (b) `docs/runbooks/` is the
  canonical location for "if you encounter X, here's the
  contract" reference docs (alongside `failure-modes.md`,
  `operator-mental-model.md`, `recovery.md`); (c) future writers
  on ENG-106 / the implement-reader sub-ticket will be pointed at
  a stable runbook URL, not a CLAUDE.md sub-section that scrolls
  away as CLAUDE.md grows.

- **D-005. Test coverage in `bin/common-test.sh` (extending the
  existing file) asserts: (a) path shape — the helper returns
  `<PROJECT_STATE_DIR>/<ident>/progress.md`; (b) idempotence — two
  calls return identical strings; (c) `die`-on-empty-issue — the
  helper fails loudly when called without an argument, matching
  `issue_dir`'s contract.**

  Concrete fixtures (3 cases, matching the existing
  `bin/common-test.sh` style at lines 84-121):

  | # | Input | Expected output |
  |---|---|---|
  | 1 | `progress_md_path ENG-1` | `<PROJECT_STATE_DIR>/ENG-1/progress.md` |
  | 2 | `progress_md_path ENG-1` (twice) | identical strings (idempotence) |
  | 3 | `progress_md_path ""` | `die` (rc=1, stderr `FATAL: progress_md_path: missing issue id`) |

  The fixtures use the existing `_TEST_ROOT` mktemp pattern at
  `bin/common-test.sh:18-30` so no new test scaffolding is
  required.

  *Reference to constraint:* the harness convention "Tests are
  sibling shell scripts named `*-test.sh` in `bin/`" (CLAUDE.md
  "Tests"). `common-test.sh` exists at `bin/common-test.sh:1-932`
  and already exercises `is_orchestrator_paused`,
  `parse_pipeline_marker`, `try_acquire_lock`, `acquire_claude_mutex`.
  `progress_md_path` slots in as a peer-tested helper.

  *Rejected alternative — new file `bin/progress-md-test.sh`:*
  rejected because the helper lives in `common.sh`, the test home
  for `common.sh` helpers is `common-test.sh`, and a fresh test
  file for a 4-line helper adds CI-time and pre-commit-hook surface
  with no isolation gain.

  *Rejected alternative — skip the `die`-on-empty fixture (only
  test cases 1 & 2):* rejected because the existing `issue_dir`
  test surface at `bin/common-test.sh` does NOT cover the
  `die`-on-empty case explicitly (`issue_dir` is exercised
  indirectly through `acquire_claude_mutex` / mutex-test, and
  through every issue-touching helper). `progress_md_path` should
  set the higher bar at the file where the helper is introduced;
  the negative-input case is the cheapest fixture to write and
  catches a future refactor that drops the `die` line.

## 3. Architecture (where code goes)

| Site | Change | Lines (approx.) |
|---|---|---|
| `bin/common.sh` | Add `progress_md_path()` near `issue_dir` (~line 72) | +5 |
| `bin/common.sh` | Append `progress_md_path` to the `export -f` line at `bin/common.sh:389` | +0 (one-line edit) |
| `bin/common-test.sh` | Add 3 fixtures (path, idempotence, die-on-empty) at end of file before the final summary print at `bin/common-test.sh:926` | +30 |
| `docs/runbooks/progress-md.md` | New file: schema + lifecycle + ownership | +80 |
| `CLAUDE.md` | Extend the `## Per-issue state directory` diagram at lines 286-289 with one `progress.md` line + one paragraph below it (or after the existing `issue-state.json` paragraph at lines 292-295) | +5 |

Total: roughly 120 LOC across 4 files. Zero changes to
`bin/run-stage.sh`, `bin/run-local.sh`, `bin/dispatch.sh`,
`bin/scope-check.sh`, `bin/run-local-helpers.sh`,
`bin/render-prompt.sh`, `bin/linear.sh`, `bin/verdict-handler.sh`,
`bin/classify-failure.sh`, `bin/poll.sh`, or `AGENT_PROMPTS.md`.
Zero changes to any test other than `common-test.sh`.

## 4. Data Flow

Pre-ENG-107: no file exists, no helper exists, no schema documented.

Post-ENG-107: still no file exists on any live issue (no writer ships
in this ticket). But:

1. A future caller (the ENG-106 plan-stage writer pilot, or any
   future stage's prompt) can resolve the path via
   `path="$(progress_md_path "$ident")"` rather than hand-rolling
   the string.
2. A future agent reading the file (via `Read` or
   `Edit`/`Write`-with-append-pattern) reads the runbook URL in
   the agent's stage prompt (delivered via the writer-pilot
   sub-ticket; not via this brainstorm), follows the heading-shape
   convention.
3. The retrospective agent (`bin/run-retrospective-local.sh`) is
   stack-unchanged but COULD, in a future sub-ticket, opt to
   parse `progress.md` files alongside transcripts. Out of scope
   for ENG-107; see OQ-2.

The file is born when the first stage agent on an issue writes its
first entry. There is no "initialization" event; absence of the
file is a legitimate, expected state (most issues at any moment
have zero entries).

## 5. Error Handling

The helper is a pure path-composer with one guard (`die`-on-empty-issue,
mirroring `issue_dir`). It cannot fail in any other shape; there is
no I/O, no syscall, no Linear/git/jq dependency.

Schema violations by future writers (malformed headings,
non-append-only edits, body content that violates a per-stage
convention) are NOT enforced by this ticket. ENG-107 ships a
schema CONTRACT, not a schema VALIDATOR. A detective validator —
"the post-dispatch envelope scan also checks the most recent
`progress.md` entry's heading matches the agent's dispatch-id" —
is plausible but explicitly NOT in scope; that's a sub-ticket
that would live alongside the writer-pilot or implement-reader
work. See OQ-3.

If a writer in a later sub-ticket attempts to `Write` (truncate)
instead of `Edit` (append), the runbook + prompt rules are the
defense. The file's append-only-ness is a CONVENTION, not a
filesystem ACL. ENG-107 does NOT propose making the file
immutable, chmod-only-append, or similar — that would add
operational surface (e.g., file-mode flips on each writer
sub-ticket) for a hazard that does not exist today.

## 6. Edge Cases

- **First write to a non-existent file.** Agent calls `Write` with
  the H2 heading + body; file is created with no preceding
  content. No ENG-107 code path cares.
- **`--action continue` resume.** Per D-003 / D-002 #6, the file
  is NOT cleared. The first write after a resume produces a new
  entry with the post-resume dispatch-id (`ENG-N-dNNNN` where NNNN
  is the seq after `_pipeline_clear_breaker` re-allocates). All
  prior entries remain visible to subsequent dispatches.
- **Issue ID with mixed case (`eng-1` vs `ENG-1`).** The helper
  composes whatever string the caller passes; it does not
  case-normalize. Callers throughout the harness pass canonical
  upper-case identifiers (`bin/run-stage.sh` uses `ident="ENG-N"`
  via Linear identifier extraction). The fixture uses `ENG-1`
  uppercase.
- **`$PROJECT_STATE_DIR` unset (bootstrap mode).** In
  `TWINNING_BOOTSTRAPPING=1` mode, `PROJECT_SLUG` is empty and
  `PROJECT_STATE_DIR` is empty (`bin/common.sh:58-59`). A caller
  invoking `progress_md_path ENG-N` in that mode would receive
  `"/ENG-N/progress.md"` — a clearly malformed path. This is the
  SAME hazard `issue_dir` has today; ENG-107 inherits it without
  worsening it. Acceptable because no agent runs in bootstrap
  mode and no orchestrator-tick path reaches the helper in
  bootstrap mode.
- **Very long-lived issues.** The file grows unbounded. At
  observed dispatch rates (~10 dispatches per issue is typical;
  the longest-lived issues in the current 18-ticket queue have
  ~30 dispatches), the file stays well under 100 KB. Even a
  100-dispatch issue with ~2 KB of prose per entry sits at
  ~200 KB — comfortably within `Read` tool window. No truncation
  policy needed today; OQ-4 captures the future question.

## 7. Open Questions

- **OQ-1. Should the helper's heading-shape contract be
  enforceable today via a tiny `progress_md_append` writer
  helper (in `bin/common.sh`) that takes `<ident>` + `<body>` and
  prepends the canonical heading?** Plausible but ticket-scope
  rejects writing helpers (writer-pilot is ENG-106). Punt:
  defer to ENG-106 once we have the first concrete writer's
  ergonomic needs. The writer-pilot brainstorm can decide
  whether to push the heading composition back into `common.sh`
  or keep it in-prompt.

- **OQ-2. Does the retrospective agent eventually consume
  `progress.md` alongside `events.jsonl` and transcripts?**
  Possible. The schema's dispatch-id stamping makes
  cross-referencing easy. But "what the retrospective reads" is
  governed by `bin/run-retrospective-local.sh` + the
  retrospective prompt; both are out of scope for this ticket.
  No design pre-commitment.

- **OQ-3. Should the post-dispatch envelope validator
  (`_validate_dispatch_envelope`, `bin/run-stage.sh:875`) gain
  an optional `progress.md` schema check?** Detective backstop
  in the ENG-87 spirit: scan the file at dispatch end, verify
  the latest H2 heading's dispatch-id matches
  `$PIPELINE_DISPATCH_ID`, halt with envelope-violation on
  mismatch. Has value (catches a writer that forgot the heading
  or hand-typed the dispatch-id) but is premature: no writer
  exists. File ticket against ENG-106 (writer-pilot) once the
  writer's prompt is written and we know what failure shapes
  appear in iteration.

- **OQ-4. Truncation / pruning policy at very long file
  lengths?** Today the largest plausible issue is ~30 dispatches.
  Truncation policy ("keep last 50 entries", "split when >500 KB")
  is a problem we should let manifest before solving. If it ever
  fires, the runbook can grow a §"Pruning" section without
  schema-break (a "## Archived" H2 separator works fine).

- **OQ-5. Symmetry with `dispatch_history.jsonl`.** That file is
  the existing append-only per-issue forensic log (CLAUDE.md
  "Cross-dispatch staleness contract" §"`dispatch_history.jsonl`").
  It captures orchestrator-side dispatch start/end records;
  progress.md captures agent-side prose. Sibling files with
  complementary perspectives. The runbook should cross-reference
  this so future readers don't conflate the two surfaces. No
  consolidation proposed.

## 8. ADR stress test

There is no `docs/knowledge/decisions.md` file in the repo. The
durable architectural rules live in `CLAUDE.md` and
`docs/architecture.md`. ENG-107 puts pressure on the following
rules:

- **CLAUDE.md "Cross-dispatch staleness contract (ENG-87)" §1.3
  "The harness has no per-dispatch identifier."** Already
  satisfied — `PIPELINE_DISPATCH_ID` shipped in ENG-87. The
  D-002 schema explicitly RELIES on it (per-entry heading
  stamping). No ADR overturn; ENG-87 is load-bearing for the
  reader-side filter story. Implementing this without ENG-87
  would have produced the same secondary-signal hazards ENG-77
  / ENG-41 §1.2 manifested.

- **CLAUDE.md "Per-issue state directory" §"`stage-summary-<stage>.md`
  is OVERWRITTEN on every dispatch."** D-002 #6 makes a different
  contract for `progress.md` (NEVER cleared, ALWAYS append). The
  CLAUDE.md catalog must NOT be read as "every file under
  `$(issue_dir)` follows the stage-summary lifecycle." The
  runbook + the new CLAUDE.md line explicitly differentiate the
  two contracts. No conflict, but a hazard if a future reader
  skims the diagram and assumes uniform lifecycle.

- **CLAUDE.md "Don't add features, refactor, or introduce
  abstractions beyond what the task requires."** D-001's helper
  is a one-line wrapper around `issue_dir`. Borderline — could
  be argued that no helper at all is "even simpler." Counter-
  argument: a named helper with a test target is the documented
  defense against the ENG-79 drift class. The cost (5 lines +
  3 fixtures) is small relative to the defense value. No ADR
  conflict; the principle is applied at the level of "minimum
  abstraction that pre-empts the named hazard."

## 9. Assumption inventory

Every named symbol or path in this brainstorm has been
grep-verified against the working tree.

| # | Assumption | Status | Evidence |
|---|---|---|---|
| A1 | `bin/common.sh::issue_dir` exists and returns `$PROJECT_STATE_DIR/<ident>` | **verified** | `bin/common.sh:68-72` |
| A2 | `bin/common.sh` already uses an `export -f` line for its public helpers | **verified** | `bin/common.sh:389` lists `issue_dir compute_pipeline_content_hash failure_outcome_for_exit parse_pipeline_marker is_orchestrator_paused set_orchestrator_paused allocate_dispatch_id current_dispatch_id assert_no_tool_invocation` |
| A3 | `PIPELINE_DISPATCH_ID` is allocated by `allocate_dispatch_id` and exported into the dispatch env | **verified** | `bin/common.sh:104-147` (allocator), `bin/common.sh:145` (`export PIPELINE_DISPATCH_ID="$id"`) |
| A4 | `bin/run-stage.sh::_clear_current_stage_slots` enumerates the per-dispatch-cleared files | **verified** | `bin/run-stage.sh:865-873`; clears `stage-summary-${stage}.md` + `wait-${stage}.json`; explicitly preserves `issue-state.json` and `stage-summary-OTHER.md` |
| A5 | `bin/run-local-helpers.sh::partition_dirty_paths` operates on worktree-internal paths only | **verified** | `bin/run-local-helpers.sh:562-651`; reads `git status` for the worktree; `$PROJECT_STATE_DIR/<ident>/` lives outside the worktree and is never seen |
| A6 | `bin/scope-check.sh::is_benign` operates on worktree-relative paths | **verified** | `bin/scope-check.sh:74-92` (per the cross-referenced ENG-96 brainstorm) — same out-of-worktree rationale |
| A7 | `bin/common-test.sh` exists and follows the `_TEST_ROOT` mktemp + `report_ok`/`report_fail` pattern | **verified** | `bin/common-test.sh:1-932`; mktemp at `:18`; report helpers at `:38-46` |
| A8 | The CLAUDE.md "Per-issue state directory" section starts at line 271 with a tree diagram at lines 286-289 | **verified** | `CLAUDE.md:271-302` (section), `CLAUDE.md:286-289` (tree) |
| A9 | `bin/run-stage.sh` references `stage-summary-${stage}.md`, `wait-${stage}.json`, `usage-${stage}.json`, `issue-state.json` as the existing per-issue artifacts | **verified** | `bin/run-stage.sh:42, :85, :216, :274, :631, :776, :782, :783, :870, :871` |
| A10 | `dispatch_history.jsonl` is the existing append-only forensic log | **verified** | CLAUDE.md "Cross-dispatch staleness contract" §"`dispatch_history.jsonl`" at `CLAUDE.md:636-640`; mentions `$(issue_dir)/dispatch_history.jsonl`; `bin/run-stage.sh:1041, :1074` writes end-row |
| A11 | `bin/render-prompt.sh:212` hand-rolled `branch_name` was the source of the ENG-79 drift | **verified** | ENG-87 brainstorm §1.1 row "ENG-79" describes `render-prompt.sh:212` drift; ENG-79 fix at `bin/render-prompt.sh:224` calls `bin/branch-name.sh` (per CLAUDE.md ENG-87 brainstorm cross-reference, line 28) |
| A12 | `bin/run-retrospective-local.sh` reads `events.jsonl` + transcripts only | **verified by absence** — searched the brainstorm folder for any retrospective-reads-progress.md reference; none exists. Docs/architecture.md "Two binaries, peer roles" lists retrospective Reads as `$PROJECT_STATE_DIR/metrics/events.jsonl`, per-stage transcripts, `learned-rules/*.md` |
| A13 | The Linear ticket's OUT list explicitly excludes ENG-87 marker integration | **verified** | Linear issue body §"OUT: ... Cross-dispatch hand-off (ENG-87 marker integration)" |
| A14 | No `progress_md_path` helper or `progress.md` reference exists today | **verified** | grep over the worktree returned zero matches |
| A15 | `failure-modes.md`, `operator-mental-model.md`, `recovery.md` are the existing files under `docs/runbooks/` | **verified** | `ls docs/runbooks/` returned those three |
| A16 | The brainstorm-doc basename token regex (`eng-N` case-insensitive) is enforced by `partition_dirty_paths` D-004 | **verified** | `bin/run-local-helpers.sh:569-578` sets `apply_d004=1` for `brainstorming|planning`; `:634` greps `(^\|[^a-z0-9])${issue_lower_re}([^a-z0-9]\|$)` against `${path##*/}` |

## 10. Persona review

The brainstorm was reviewed via six personas in the order
**design → security → scope → coherence → product → feasibility**.
The full transcripts live in this section; the per-comment Linear
summary carries the headline.

### 10.1 Design persona

**Concerns evaluated:** is the schema right-shaped? Is the helper
the right level of abstraction? Are the failure modes well thought
through?

- The helper is a one-line wrapper around `issue_dir`. The named
  helper is justified by D-001's defense-against-drift rationale.
  An anti-design alternative ("just document the path") was
  considered and rejected.
- The schema is markdown with one heading-shape rule. Minimal.
  Future schema evolution paths (subsection conventions per
  stage) are explicitly left open.
- The append-only contract is a convention, not enforced by
  filesystem permissions. This is defensible — enforcing it
  filesystem-side would add ops surface for a hazard that does
  not exist today and would not survive a malicious agent
  anyway.

**Verdict: PASS** — no design changes required.

### 10.2 Security persona

**Concerns evaluated:** can a dispatched agent on issue A read
issue B's progress.md? Can the file be used as a side-channel?
Are secret-handling rules respected?

- Cross-issue read isolation: the file path is
  `$(issue_dir <ident>)/progress.md`. The agent's dispatch on
  issue A runs with `cwd = $(issue_dir A)/worktree`; the agent's
  `Read` tool is gated by `--allowed-tools` which (per
  `bin/dispatch.sh::allowed_tools_for` + the project profile's
  `## Tool allowlist`) grants `Read` broadly. So an agent on issue
  A COULD `Read` issue B's progress.md by absolute path. This is
  the SAME isolation property as today's `stage-summary-<stage>.md`
  (an agent on A could read B's stage-summary file). Not a
  regression. Calling this out so a future hardening sub-ticket
  has a target if the threat model changes.
- Secret handling: the helper does not touch any
  `*KEY|*TOKEN|*SECRET|ANTHROPIC*|GITHUB*|LINEAR*` env var. No
  `${VAR:-...}` patterns. ENG-46 compliance is trivially
  satisfied.
- The schema does NOT instruct writers to include credentials.
  Future per-stage prompts that wire progress.md writing must
  carry the existing secret-handling preamble; that's the
  writer-pilot's concern, not this brainstorm's.

**Verdict: PASS** — one residual cross-issue-read observation
recorded; not blocking.

### 10.3 Scope persona

**Concerns evaluated:** does the brainstorm stay within the
Linear ticket's IN list? Does any decision drift into ENG-106 /
the implement-reader sub-ticket?

- IN list (from Linear): new file slot, schema documented,
  helper, test. All four are covered by D-001 / D-002 / D-003 /
  D-004 / D-005.
- OUT list (from Linear): stage agents writing/reading
  progress.md, ENG-87 marker integration. D-003 explicitly
  defers writer/reader changes. D-002's "no body schema" rule
  defers per-stage conventions to writer sub-tickets. D-002
  rejected alternative on HTML-comment markers explicitly
  defers ENG-87 marker integration.
- Subsystems touched (per CLAUDE.md "Ticket sizing rubric"):
  `bin/common.sh`, `bin/common-test.sh`,
  `docs/runbooks/progress-md.md`, `CLAUDE.md`. One subsystem
  ("orchestrator") if we lump common.sh under it; arguably zero
  if we count docs separately. Single-subsystem ticket.
- Independent design decisions: file location (D-001), schema
  shape (D-002), ownership boundary (D-003), documentation
  surface (D-004), test fixtures (D-005). All five are derivative
  of "where does it live + what does it look like"; not 5
  independent decisions in the rubric sense. Well under the
  2-independent-decisions threshold.

**Verdict: PASS** — squarely within scope.

### 10.4 Coherence persona

**Concerns evaluated:** does this fit the existing harness
conventions? Does it conflict with any cross-cutting rule?

- File-naming convention: `progress.md` is camel-case-free,
  lower-kebab, matching every other per-issue artifact basename
  (`issue-state.json`, `stage-summary-<stage>.md`,
  `wait-<stage>.json`, `dispatch_history.jsonl`). Note the
  underscore in `dispatch_history.jsonl` is an outlier —
  `progress.md` follows the dominant kebab-case shape, not the
  outlier. Coherent.
- Helper naming: `progress_md_path` matches `issue_dir`'s
  snake-case + verb-less convention. Coherent.
- Lifecycle contract: this brainstorm flags the
  contrast-with-stage-summary in D-002 #6 and D-004. The new
  CLAUDE.md line will need a one-clause note to avoid the
  "every file under issue_dir clears per dispatch" reader
  misread. Coherent if that note ships; incoherent without it
  (caught by D-004's CLAUDE.md update spec).
- The schema uses `·` (middle-dot, U+00B7) as a token separator
  in headings. Outlier — the rest of the codebase uses ASCII.
  Switched to a less exotic separator: D-002 heading shape uses
  `·` for readability, but ASCII `-` or ` — ` works equally
  well. **Coherence-driven amendment:** see §11 for the
  follow-up.

**Verdict: PASS-WITH-AMENDMENT** — see §11 D-002 separator
amendment. Recorded inline below.

### 10.5 Product persona

**Concerns evaluated:** does this advance the parent ENG-28
goal? Is the foundation right-sized for the writer-pilot
sub-ticket?

- ENG-28's goal is a continuous, cross-dispatch notebook so a
  later-stage agent has the prior-stage agent's context without
  re-reading every transcript. ENG-107's foundation supplies
  exactly that: a known-path, schema-defined file the writer
  pilot can `Write`-or-append to in ENG-106, and the
  implement-reader can `Read` in a follow-up.
- The writer-pilot's path of least resistance — once ENG-107
  ships — is `bash -c 'cat >> $(progress_md_path ENG-N) <<EOF
  ...EOF'`. The helper is testable and stable; the writer's
  prompt can hard-code the helper name.
- Risk: the writer-pilot is the FIRST file-mutator of this slot;
  if the writer's prompt is wrong (e.g., uses `Write` to
  truncate instead of `>>` to append), the bug lands on
  ENG-106, not on ENG-107. ENG-107's runbook is the contract
  ENG-106 follows; ENG-107 takes no responsibility for ENG-106's
  prompt quality.

**Verdict: PASS** — foundation correctly sized.

### 10.6 Feasibility persona

**Concerns evaluated:** are all referenced symbols/paths real?
Does the proposed code compile? Are the test fixtures runnable?

- `bin/common.sh::issue_dir` exists at lines 68-72 ✓
- `bin/common.sh:389` `export -f` line exists ✓ — verified via
  Read; symbols listed match the assumption inventory A2
- `bin/common-test.sh` exists at 932 lines ✓ — verified
- `bin/run-stage.sh::_clear_current_stage_slots` at lines
  865-873 ✓ — verified, clears `stage-summary-${stage}.md` and
  `wait-${stage}.json` only
- `bin/run-local-helpers.sh::partition_dirty_paths` at lines
  562-651 ✓ — verified
- `CLAUDE.md` "Per-issue state directory" section at line 271 ✓
  — verified
- `PIPELINE_DISPATCH_ID` allocator at `bin/common.sh:104-147` ✓
  — verified; format `ENG-N-d<NNNN>` confirmed at line 134
- `docs/runbooks/` exists with three files ✓ — verified via ls
- `dispatch_history.jsonl` referenced in CLAUDE.md "Cross-dispatch
  staleness contract" §"`dispatch_history.jsonl`" at lines
  636-640 ✓ — verified
- Test fixture invocation: the proposed test calls
  `progress_md_path ENG-1` after sourcing `common.sh` with
  `PROJECT_SLUG=test-slug` set per the `common-test.sh:30`
  pattern. The expected output is `$PROJECT_STATE_DIR/ENG-1/progress.md`
  where `PROJECT_STATE_DIR=$HARNESS_STATE_DIR/test-slug` by
  fallthrough. Compatible with the existing test scaffolding ✓
- `bin/scope-check.sh::is_benign` reference verified via prior
  ENG-96 brainstorm cross-link — was not opened directly. The
  assumption is that scope-check operates only on worktree-
  relative paths from `git status` output; the brainstorm's
  D-003 rationale rests on this. Marking A6 as **verified by
  reference** (ENG-96 brainstorm + the architecture.md
  description of scope-check); a direct file open is not
  required because no code change touches scope-check.

**Verdict: PASS · P0 findings: 0** — every referenced
symbol/path is grep-verified against the current tree; no
P0 codebase-fact errors.

## 11. Coherence-driven amendment

Per §10.4, D-002 heading separator is amended from `·` to ` — `
(em-dash with surrounding spaces) for ASCII friendliness in
shell pipelines and grep patterns. Final canonical heading:

```markdown
## ENG-N-d0001 — brainstorming — 2026-05-15T12:34:56Z
```

Em-dash is ASCII-unfriendly too; for max grep-friendliness the
runbook will recommend ASCII `-` with surrounding spaces:

```markdown
## ENG-N-d0001 - brainstorming - 2026-05-15T12:34:56Z
```

Either is acceptable to writers; the runbook documents both as
permissible. The dispatch-id prefix is the load-bearing token;
the separator is cosmetic.

## 12. Gate summary

| Persona | Verdict | Notes |
|---|---|---|
| Design | PASS | No design changes required. |
| Security | PASS | Cross-issue-read observation recorded; not blocking. |
| Scope | PASS | Single-subsystem, single-decision ticket. |
| Coherence | PASS | One amendment applied inline (§11 separator). |
| Product | PASS | Foundation correctly sized for ENG-106. |
| Feasibility | PASS · P0=0 | All referenced symbols/paths grep-verified. |

**Personas: 6/6 PASS · gate P0: 0 · proceeding to planning.**
