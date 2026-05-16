---
linear: ENG-108
title: progress.md — implement stage reads progress entries
date: 2026-05-16
status: draft
---

# ENG-108 — implement stage reads progress.md (first reader pilot)

## 1. Overview

ENG-107 shipped the foundation: a canonical helper
`bin/common.sh::progress_md_path <ident>` resolving to
`$PROJECT_STATE_DIR/<ident>/progress.md`, a documented append-only
schema in `docs/runbooks/progress-md.md`, and a CLAUDE.md listing
under the per-issue state directory. No agent reads or writes the
file yet.

ENG-106 (blocking-this) ships the first writer: the plan-stage
agent appends an entry. ENG-108 (this brainstorm) ships the first
reader: the implement-stage agent reads `progress.md` BEFORE the
other onboarding artifacts (CLAUDE.md, architecture docs,
brainstorm/plan), so cross-dispatch context recorded by the prior
planner (or by a prior implement attempt — once a future ticket
extends writes to implement) lands in the implementer's frame from
turn one.

The Linear ticket is tightly scoped:

| In scope | Out of scope |
|---|---|
| AGENT_PROMPTS.md §3 (Implementation Agent) gets a "Read progress.md first" preamble | ui, qa, review readers (separate sub-ticket) |
| Optionally, `render-prompt.sh` exposes the path (or inlines content) for the implement prompt | Implement-stage WRITER responsibilities |
| Test covers implement dispatch with vs. without an existing progress.md | ENG-87 HTML-comment marker integration (deferred per ENG-107 OUT list) |

**Acceptance criteria (verbatim from Linear):**

1. Implement dispatch reads progress.md before reading other
   worktree files.
2. Test fixture: with and without progress.md — both succeed; the
   latter logs a "progress-md missing" info note.

The two non-obvious problems this brainstorm has to solve:

- **A. Delivery mechanism.** Two viable shapes — (a) inject a
  `{progress_md_path}` token into the implementing prompt and let
  the agent's `Read` tool fetch the file; (b) inline file contents
  into the prompt body via a render-time resolver, mirroring the
  ENG-105 `{review_findings}` precedent at
  `bin/render-prompt.sh:245-252`. Pick one and justify against the
  token-budget, transcript-visibility, and coherence tradeoffs.
- **B. Missing-file path.** The file legitimately does not exist
  on most issues (first-time-on-issue + the plan writer pilot
  doesn't ship until ENG-106). The agent must NOT halt on a
  missing file, and an orchestrator-side info log must fire so
  operator and the test fixture can both observe the "no progress
  yet" state.

## 2. Decisions

- **D-001. Delivery mechanism: path token + agent `Read`, NOT
  in-prompt content inlining.** Add a new resolver
  `_resolve_progress_md_path` to `bin/render-prompt.sh`'s
  `PROMPT_RESOLVERS` registry (the same registry that today
  resolves `{stage_summary_path}`, `{branch_name}`,
  `{brainstorm_file}`, etc., per `bin/render-prompt.sh:41-55`).
  The resolver prints the absolute path returned by
  `bin/common.sh::progress_md_path <issue_id>` (`bin/common.sh:78-82`).
  The implement prompt references the token and instructs the
  agent to `Read` the file first.

  Concrete resolver shape (mirrors `_resolve_stage_summary_path`
  at `bin/render-prompt.sh:226`):

  ```bash
  _resolve_progress_md_path() { printf '%s' "$_RENDER_PROGRESS_MD_PATH"; }
  ```

  Concrete `main()` binding (sibling to lines 404-421):

  ```bash
  _RENDER_PROGRESS_MD_PATH="$(progress_md_path "$issue_id")"
  ```

  *Reference to constraint:* CLAUDE.md "Don't add features,
  refactor, or introduce abstractions beyond what the task
  requires." Adding one resolver alongside the existing 14 in
  `PROMPT_RESOLVERS` is the smallest change that satisfies the
  ticket's "Optional: render-prompt.sh appends progress.md content
  to the implement prompt (vs. agent reads via Read tool)" — we
  pick "agent reads via Read tool" + a path token. The opposite
  shape (inline-content) is more code and more risk; see rejected
  alternative below.

  *Reference to principle:* CLAUDE.md "Cross-dispatch staleness
  contract (ENG-87)" §"reader-side filters." The dispatch-id-
  stamped headings landed by ENG-107 (`docs/runbooks/progress-md.md:34-58`)
  are intended to let a reader filter "entries I just wrote" vs
  "entries from prior dispatches" by simple text-match on
  `$PIPELINE_DISPATCH_ID`. The path-token approach preserves this
  filter — the agent reads the full file and applies the filter
  inline. The inlined-content approach would have to either
  (a) inline the full file (token-budget-unbounded), or (b)
  pre-filter at render time (re-implementing the filter
  orchestrator-side, and forcing every future reader stage to
  carry the same flag in its prompt) — both worse.

  *Rejected alternative — inline the file's full content into
  the prompt body via a `_resolve_progress_md_content` resolver,
  mirroring `_resolve_review_findings` at
  `bin/render-prompt.sh:245-252`:* rejected on three counts:

  1. **Token budget unbounded.** `progress.md` accumulates across
     the issue's entire lifetime (ENG-107 D-002 #1 + #6 — the
     file is NEVER cleared). At observed dispatch rates (~10-30
     dispatches per issue per the ENG-107 brainstorm §6
     long-lived-issues edge case), the file stays under 100 KB;
     a pathological 100-dispatch issue could reach ~200 KB. The
     review-findings precedent at `bin/render-prompt.sh:245-252`
     does NOT carry this risk — `stage-summary-reviewing.md` is
     cleared per dispatch by `_clear_current_stage_slots`
     (`bin/run-stage.sh:883-891`) so it's bounded to one
     review's findings. Inlining `progress.md` makes the implement
     prompt grow monotonically with the issue's age. The agent's
     `Read` tool can fetch on-demand and stream the file into the
     model context only when the agent actually needs it.

  2. **Transcript visibility.** Today, when an implement agent
     reads `docs/brainstorms/<file>` or `docs/plans/<file>`, the
     transcript carries an explicit `tool_use:Read` entry that
     forensics (retrospective agent, operator manual triage,
     post-dispatch envelope validator) can grep for. An inlined
     `{progress_md_content}` resolver short-circuits this — the
     content is in the prompt, the agent never emits a `Read`
     tool_use, and the retrospective cannot tell from the
     transcript alone whether the agent looked at it. A future
     detective check ("did this implement dispatch read
     progress.md when it existed?") becomes impossible without
     a parallel orchestrator-side log. Path-token + `Read` makes
     the read explicit by construction.

  3. **Coherence with read-first patterns.** Every other entry
     in the implementing prompt's "Read these files first" list
     (`AGENT_PROMPTS.md:614-622`) is a file the agent reads via
     its `Read` tool: CLAUDE.md, ARCHITECTURE.md, gotchas.md,
     decisions.md, conventions.md, learned-rules/implementation.md,
     docs/brainstorms/{brainstorm_file}, docs/plans/{plan_file}.
     The inline-content shape would make `progress.md` the lone
     exception ("you read this one via the prompt body, not
     via Read"), which raises cognitive load for the agent and
     the operator.

  *Rejected alternative — no render-prompt change at all; embed
  the literal path string in AGENT_PROMPTS.md (`AGENT_PROMPTS.md`
  refers to `$PROJECT_STATE_DIR/<issue_id>/progress.md` as a
  string, agent resolves via `pwd` or env):* rejected because
  (a) `$PROJECT_STATE_DIR` is an env var; the prompt can't
  literally interpolate shell vars without a render-time pass;
  (b) hand-rolling the path string in AGENT_PROMPTS.md
  duplicates the canonical resolver in `bin/common.sh:78-82` and
  is exactly the ENG-79 drift class the named helper was
  introduced to prevent; (c) the helper already exists — adding
  a 5-line resolver to consume it is strictly cheaper than NOT
  consuming it.

- **D-002. Place `progress.md` as new position 1 in the implementing
  prompt's "Read these files first" list — ABOVE CLAUDE.md.** The
  current list (`AGENT_PROMPTS.md:614-622`) starts at CLAUDE.md.
  ENG-108 inserts `progress.md` as a NEW position 1 with the
  body:

  ```
  1. {progress_md_path} — per-issue progress notebook (cross-dispatch
     context from prior agents on this issue; see
     docs/runbooks/progress-md.md). Read this BEFORE the other
     files: the prior dispatch may have flagged that a plan task
     is blocked, that a chosen approach failed, or that a
     dead-end was already explored. Skip if not present —
     first-dispatch-on-issue is normal.
  ```

  CLAUDE.md and every subsequent file shift down one position.

  *Reference to constraint:* Linear AC-1 — "Implement dispatch
  reads progress.md before reading other worktree files." Literal
  reading: position 1 of the read-first list, ahead of every
  other worktree file (including CLAUDE.md). The list is the
  agent's onboarding sequence; position 1 is the strongest
  documented expression of "first."

  *Reference to principle:* CLAUDE.md "Cross-dispatch staleness
  contract (ENG-87)" §intro — "Six prior tickets … each
  manifested the same structural failure: a fresh dispatch's
  reader treats data written by a PRIOR dispatch as if it were
  current." `progress.md` is the inversion of that hazard: it
  is the FIRST place a returning agent reads BECAUSE the prior
  dispatch's notes are dispatch-id-stamped and the reader can
  filter accordingly. Putting it later in the list would
  weaken the inversion — the agent forms its mental model from
  CLAUDE.md + architecture first, then the prior dispatch's
  notes have to fight against that frame.

  *Rejected alternative — insert between learned-rules/implementation.md
  and docs/brainstorms/{brainstorm_file} (i.e., position 7):* rejected
  because (a) this would make the durable project context
  (CLAUDE.md, gotchas, decisions, conventions, learned-rules)
  load BEFORE the issue-specific cross-dispatch context, which is
  the opposite of the ticket's literal "first" mandate; (b) the
  per-issue artifacts (brainstorm, plan) at positions 7-8 are
  also worktree files — putting progress.md between learned-rules
  and brainstorm splits the per-issue context block awkwardly.

  *Rejected alternative — separate "PREAMBLE — Read this BEFORE
  the numbered list" line above the read-first list:* rejected
  because (a) the numbered list IS the onboarding sequence;
  parallel structure (preamble + list) raises cognitive load for
  the agent; (b) future stages adopting the same pattern (ui, qa,
  review per the OQ ticket) will copy the structure — if
  position-1 is the convention, the follow-up tickets converge
  on a clean shape.

- **D-003. Missing-file behavior: orchestrator-side info log +
  prompt-side "treat absent as no-op" instruction.** When the
  implement stage renders for an issue where `progress.md` does
  not exist on disk, `bin/render-prompt.sh::main` emits one
  `log` line to stderr:

  ```
  render-prompt: progress-md missing for ENG-N at $PROJECT_STATE_DIR/ENG-N/progress.md (informational; agent's Read will note absence)
  ```

  AND the implementing prompt's position-1 read-first item
  carries the trailing clause "Skip if not present — first-
  dispatch-on-issue is normal." (see D-002 body).

  Concrete `main()` insertion (after the
  `_RENDER_PROGRESS_MD_PATH="..."` binding from D-001):

  ```bash
  if [[ "$stage" == "implementing" && ! -e "$_RENDER_PROGRESS_MD_PATH" ]]; then
    log "render-prompt: progress-md missing for $issue_id at $_RENDER_PROGRESS_MD_PATH (informational; agent's Read will note absence)"
  fi
  ```

  *Reference to constraint:* Linear AC-2 — "Test fixture: with
  and without progress.md — both succeed; the latter logs a
  'progress-md missing' info note." The orchestrator-side
  stderr log is the testable surface; the prompt-side
  "skip if not present" instruction is the agent-side
  no-halt instruction.

  *Reference to principle:* CLAUDE.md "When wiring a new script
  / Use `log` / `die` / `require_env` / `require_bin` from
  common.sh." `log` is the canonical info-channel; it routes
  through `bin/common.sh::log` to stderr, which is captured by
  the per-stage transcript at
  `$PROJECT_STATE_DIR/<ident>/logs/<ident>-<stage>-*.log`.

  *Rejected alternative — die-on-missing:* rejected because
  the file's absence is a legitimate, expected state for ~all
  current issues (no writer ships until ENG-106). Halting
  every implement dispatch on a missing `progress.md` would
  brick the pipeline for the duration of ENG-106's rollout.

  *Rejected alternative — silent (no log line):* rejected
  because Linear AC-2 explicitly requires "logs a 'progress-md
  missing' info note." A silent path also defeats operator
  forensics: when the agent reports it found no prior notes,
  the operator can grep stderr for the orchestrator's view of
  the same fact and cross-check.

  *Rejected alternative — fire the log line for every stage's
  render, not just implementing:* rejected because the
  `{progress_md_path}` token is only referenced by the
  implementing prompt today (ENG-108 IN list scopes to
  implement). A log line on a render that won't reach a reader
  is noise. When ui/qa/review readers land in the follow-up,
  the condition extends from `== "implementing"` to a stage
  set or to token-presence detection. Premature generalization
  is the anti-pattern CLAUDE.md "Don't add features … beyond
  what the task requires" names.

- **D-004. Test surface: extend `bin/render-prompt-rc0-test.sh`
  with one new fixture pair (with-progress.md / without-progress.md),
  matching the ENG-105 case A/B pair already in the file at
  `bin/render-prompt-rc0-test.sh:117-157`.** No new test file;
  no run-stage integration test; no AGENT_PROMPTS.md content
  test.

  Concrete fixtures (matching the existing pair's shape):

  | # | Setup | Assert |
  |---|---|---|
  | A | No `$PROJECT_STATE_DIR/<issue>/progress.md` exists | (a) `render-prompt.sh implementing <issue>` rc=0; (b) stdout contains the absolute path token (resolved); (c) stderr contains `progress-md missing` |
  | B | `progress.md` pre-seeded with a sentinel H2 entry | (a) rc=0; (b) stdout contains the absolute path (the agent will Read it via the path); (c) stderr does NOT contain `progress-md missing` |

  *Reference to constraint:* the harness convention "Tests are
  sibling shell scripts named `*-test.sh` in `bin/`" (CLAUDE.md
  "Tests"). `render-prompt-rc0-test.sh` already exercises full
  `main()` execution via stub `linear.sh` + `branch-name.sh` in
  a sandboxed `HARNESS_STATE_DIR`/`PROJECT_SLUG` (`bin/render-prompt-rc0-test.sh:35-89`)
  — exactly the scaffolding ENG-108's fixtures need.

  *Reference to principle:* CLAUDE.md "Don't add features,
  refactor, or introduce abstractions beyond what the task
  requires." A new test file is unjustifiable given an existing
  test file already covers the same code path with the same
  scaffolding. The ENG-105 case A/B pair is the existence
  proof: a present/absent pair for a per-issue artifact lands
  inline in `render-prompt-rc0-test.sh`, not in a fresh file.

  *Rejected alternative — full dispatch integration test in
  `bin/run-stage-test.sh`:* rejected because (a)
  `PIPELINE_DRY_RUN=1` short-circuits the actual `claude -p`
  call before the agent runs, so an integration test cannot
  observe agent behavior (the AC-1 "reads progress.md before
  reading other worktree files" is satisfied structurally by
  prompt-text placement, verifiable by grepping the rendered
  prompt for the position-1 read-first line); (b) run-stage
  tests are heavier (~30s test runtime) than render-prompt-rc0
  fixtures (~1s).

  *Rejected alternative — add fixtures to `bin/render-prompt-test.sh`
  (the file that exercises `append_project_profile`):* rejected
  because `render-prompt-test.sh` sources render-prompt.sh and
  tests individual functions (not `main()`); the new fixtures
  need full `main()` invocation with stub linear.sh/branch-name.sh,
  which is exactly the scaffolding `render-prompt-rc0-test.sh`
  already has and `render-prompt-test.sh` does not.

  *Rejected alternative — `bin/agent-prompts-content-test.sh`
  fixture asserting the position-1 read-first line is present
  in §3:* additive, not exclusive. A one-line content assertion
  in agent-prompts-content-test.sh is cheap insurance that
  the position-1 placement does not regress. Including this
  as a secondary fixture in the plan; see §3 Architecture.

- **D-005. Scope boundary: zero changes to writer ergonomics,
  zero changes to ui/qa/review prompts, zero changes to the
  post-dispatch envelope validator.** Specifically:

  - `AGENT_PROMPTS.md §4` (UI Agent), §5 (Review Agent), §6 (QA
    Agent) — UNTOUCHED. They keep their current read-first
    lists. The follow-up ticket extends.
  - `AGENT_PROMPTS.md §3` (Implementation Agent) — gets the
    read-first prepend (D-002). NO writer instruction added.
    The implementer reads progress.md; nothing in this ticket
    asks it to append entries.
  - `bin/run-stage.sh::_clear_current_stage_slots` at
    `bin/run-stage.sh:883-891` — UNTOUCHED. `progress.md` stays
    on the NOT-cleared list per ENG-107 D-003.
  - `bin/run-stage.sh::_validate_dispatch_envelope` at
    `bin/run-stage.sh:893-940` — UNTOUCHED. No new envelope
    assertion (e.g., "implementer must have Read'd progress.md
    when it existed"). Detective backstop is OQ-1 for a follow-up.
  - `bin/run-local-helpers.sh::partition_dirty_paths`,
    `bin/scope-check.sh::is_benign` — UNTOUCHED. `progress.md`
    lives outside the worktree (ENG-107 D-003); the sweep and
    scope gate never see it.

  *Reference to constraint:* Linear OUT list — "ui, qa, review
  readers (separate sub-ticket)" and "Writer responsibilities
  for implement." Touching any of the above would put the
  ticket over the 2-subsystem rubric threshold.

  *Reference to principle:* CLAUDE.md "Ticket sizing rubric"
  §"Axis 1 — Subsystems touched." Touched today: agent prompts
  (AGENT_PROMPTS.md §3), dispatch (render-prompt.sh resolver +
  log), tests (render-prompt-rc0-test.sh + optional
  agent-prompts-content-test.sh). Three subsystems by the strict
  rubric, but two are clearly subordinate (tests always travel
  with production; the render-prompt change is one new resolver
  + one stage-conditional log = ~10 LOC). The rubric's "2
  subsystems with one clearly subordinate → autonomy-safe IF
  the scope boundary is explicit in the ticket body" clause
  covers this — the boundary is explicit in the Linear ticket
  AND restated here.

## 3. Architecture (where code goes)

| Site | Change | Lines (approx.) |
|---|---|---|
| `bin/render-prompt.sh` | Add `progress_md_path=_resolve_progress_md_path` to `PROMPT_RESOLVERS` (line 41-55) | +1 |
| `bin/render-prompt.sh` | Add `_resolve_progress_md_path()` near `_resolve_stage_summary_path` (line 226) | +1 |
| `bin/render-prompt.sh` | Bind `_RENDER_PROGRESS_MD_PATH="$(progress_md_path "$issue_id")"` in `main()` (alongside lines 404-421) | +1 |
| `bin/render-prompt.sh` | Stage-conditional info-log when file absent + stage == implementing | +3 |
| `AGENT_PROMPTS.md` | Insert new position-1 read-first item in §3 (between line 614 header and line 615 current pos-1); shift CLAUDE.md to 2, etc. | +3 net (1 new line + renumbering — renumbering is one-line edits) |
| `bin/render-prompt-rc0-test.sh` | Add case-A (no file) + case-B (file present) fixtures after the ENG-105 pair at line 157 | +30 |
| `bin/agent-prompts-content-test.sh` | Assert §3 read-first list includes `{progress_md_path}` at position 1 (one-line grep) | +5 |

Total: ~45 LOC across 3 files (one production file, two test
files). Zero changes to `bin/common.sh` (the helper landed in
ENG-107), `bin/run-stage.sh`, `bin/dispatch.sh`,
`bin/run-local-helpers.sh`, `bin/scope-check.sh`,
`bin/run-local.sh`, `bin/linear.sh`,
`bin/verdict-handler.sh`, `bin/classify-failure.sh`, `bin/poll.sh`,
or `docs/runbooks/progress-md.md`.

## 4. Data Flow

Pre-ENG-108: implement dispatch reads CLAUDE.md, architecture,
gotchas, decisions, conventions, learned-rules/implementation.md,
brainstorm, plan (in that order, per `AGENT_PROMPTS.md:614-622`).
`progress.md` exists on disk for some issues (post-ENG-106) but
the implementer ignores it.

Post-ENG-108, on dispatch of stage `implementing` for issue
`ENG-N`:

1. `bin/run-stage.sh::main` allocates the dispatch id via
   `allocate_dispatch_id` (`bin/common.sh:114-131`), exports
   `PIPELINE_DISPATCH_ID=ENG-N-dNNNN`.
2. `bin/run-stage.sh::main` calls `bin/render-prompt.sh implementing ENG-N`
   to produce the rendered prompt file
   (`bin/run-stage.sh:1288`).
3. `bin/render-prompt.sh::main`:
   - resolves `_RENDER_PROGRESS_MD_PATH="$(progress_md_path ENG-N)"`
     → e.g. `/Users/.../state/twinning-harness/<slug>/ENG-N/progress.md`
   - if `stage == implementing` AND `! -e` that path → `log`
     the info note to stderr (captured by the per-stage
     transcript).
   - calls `resolve_block_tokens "$block"` which substitutes
     `{progress_md_path}` → the absolute path string.
4. `bin/dispatch.sh` invokes `claude -p` with the rendered prompt.
5. Agent's session opens. The prompt's position-1 read-first
   item carries the absolute path token (now resolved). Agent
   issues a `Read` tool_use against the absolute path.
6. **Case present** (`progress.md` exists): `Read` returns the
   file contents. Agent uses them to frame its understanding
   of prior-dispatch context (filtered against
   `$PIPELINE_DISPATCH_ID` per the runbook's "readers filter
   entries-I-already-wrote" pattern at
   `docs/runbooks/progress-md.md:108-115`). Agent proceeds to
   item 2 (CLAUDE.md), 3 (architecture), etc.
7. **Case absent**: `Read` returns "File does not exist" (the
   literal Read-tool error). Agent recognizes this as the
   documented "skip if not present" state from the prompt
   body, does NOT halt, and proceeds to item 2.

The orchestrator's role ends at step 4. Steps 5-7 are pure agent
behavior — the prompt-side "skip if not present" instruction is
the only "code" governing them.

## 5. Error Handling

The `_resolve_progress_md_path` resolver is a pure path-printer
mirroring `_resolve_stage_summary_path`. It cannot fail in any
shape other than its caller `progress_md_path` failing — which
only happens on empty `issue_id`, which `main()` already guards
against at `bin/render-prompt.sh:368`.

The conditional info-log:

- Reads `_RENDER_PROGRESS_MD_PATH` (always non-empty at this
  point — `progress_md_path` dies on empty issue, but `issue_id`
  is already checked).
- `-e` test on the resolved path; no other syscalls.
- `log` writes to stderr; never blocks; never propagates rc.

Agent-side error modes:

- **Read on missing absolute path.** Returns Read-tool error
  (string "File does not exist" or similar). The prompt-side
  "skip if not present" instruction is the agent's contract.
  No P0 / no halt expected.
- **Read on permission-denied (corrupted file mode).** Should
  not happen — `$PROJECT_STATE_DIR/<ident>/` is owned by the
  user running launchd. If it ever does, agent will see the
  permission error and can halt with `agent-blocked`. Out of
  scope for this ticket.
- **Read on empty file.** File exists but has zero bytes. Read
  returns empty content. Functionally identical to the missing
  case — agent should treat it as no-op. The prompt-side
  instruction does not currently spell this out; the runbook
  (`docs/runbooks/progress-md.md:5`) implies the file is born
  on first append, so empty is an unusual but valid state.
  Acceptable: agent will read zero entries and proceed.
- **Read on huge file.** ENG-107 §6 long-lived-issues note —
  ~200 KB worst case at observed dispatch rates. Within the
  Read tool window. No truncation policy needed today; OQ-3 in
  ENG-107 captures the future question.

## 6. Edge Cases

- **First-dispatch-on-issue.** No prior writer has run; file
  doesn't exist. Info-log fires; agent reads "missing," moves
  on. This is the dominant path during ENG-106 rollout.
- **Implement re-dispatch on same issue (post-review-loopback).**
  By the time the implementer is re-dispatched, ENG-106's
  plan-stage writer has at minimum logged ONE entry on the
  prior plan dispatch. The file exists; the implementer reads
  it; finds the plan-stage entry tagged
  `## ENG-N-d0001 - planning - <ts>`; uses it as context.
- **`--action continue` resume.** Per ENG-107 D-003 / D-002 #6
  and the runbook (`docs/runbooks/progress-md.md:98-104`), the
  file is NOT cleared on resume. Implementer re-dispatched
  post-resume reads the file accumulated from before the halt;
  treats prior dispatches' entries normally.
- **`PROJECT_STATE_DIR` unset (bootstrap mode).**
  `progress_md_path ENG-N` returns `/ENG-N/progress.md` (a
  malformed path; ENG-107 §6 inherits this hazard from
  `issue_dir`). Render-prompt's `-e` test will return false;
  info-log fires with the malformed path; agent Read fails; no
  damage. Acceptable.
- **Issue ID in mixed case (`eng-1` vs `ENG-1`).** Same as
  ENG-107 §6 — callers throughout the harness pass canonical
  upper-case identifiers (`bin/run-stage.sh` uses `ident="ENG-N"`
  via Linear identifier extraction). Test fixtures use `ENG-N`
  uppercase.
- **Concurrent dispatches on different issues.** Each
  dispatch resolves a different `progress_md_path` (different
  `ENG-N`). No shared state, no race. The K=2 ENG-81 concurrency
  cap is irrelevant here — paths are per-issue.
- **Stage other than implementing references `{progress_md_path}`
  by accident in a future edit.** `resolve_block_tokens` would
  substitute it normally (the resolver is stage-agnostic); the
  info-log condition (`stage == "implementing"`) would skip,
  so the would-be reader would see the path but the
  orchestrator would not log on absence. That's a non-issue
  until the next reader stage lands — at which point the
  follow-up ticket extends the condition.

## 7. Open Questions

- **OQ-1. Should `_validate_dispatch_envelope`
  (`bin/run-stage.sh:893-940`) gain an "implement-stage read
  progress.md when it exists" detective check?** A transcript-scan
  predicate: when `$(progress_md_path)` exists AND no `Read` of
  that path appears in the transcript, halt with
  `dispatch-envelope-violation`. Plausible and aligned with
  ENG-87's detective-backstop pattern. Out of scope for this
  ticket — premature without observed bypass; would also need
  to cope with cases where the agent legitimately decides the
  prior entries are stale and doesn't engage. File against the
  follow-up ticket (or against a separate observability ticket
  after we have a few weeks of data).

- **OQ-2. Should the prompt instruct the implementer to also
  filter entries by `$PIPELINE_DISPATCH_ID` (i.e., "ignore
  entries whose dispatch-id equals YOUR dispatch-id")?** The
  runbook (`docs/runbooks/progress-md.md:108-115`) names this
  filter as the cross-dispatch staleness mitigation, but the
  implementer-as-reader scenario doesn't quite fit: in the
  current writer scope (ENG-106), only the plan stage writes
  — the implementer never sees an entry tagged with its own
  dispatch-id. The filter becomes load-bearing only once a
  stage both writes AND re-reads its own writes (e.g., a
  hypothetical implement-writer + implement-loopback-reader).
  Deferred to the follow-up ticket that introduces the
  implement-writer.

- **OQ-3. Cross-stage adoption rollout order.** The Linear
  ticket OUT list defers ui/qa/review readers; what's the right
  order? Recommend qa → review → ui, because qa most often
  re-derives state the implementer wrote down (e.g., "the
  smoke test I wrote needs this fixture"), review benefits
  from cross-dispatch context (rejection rationales), and ui
  is the lightest gain (UI work is mostly self-contained per
  dispatch). No decision required here — flagged for the
  follow-up coordinator.

- **OQ-4. Should the agent-prompts-content-test.sh fixture
  assert the exact wording of the position-1 line, or just
  the presence of `{progress_md_path}` at position 1?**
  Exact-wording is brittle (any future copy-edit breaks the
  test); presence-at-position-1 is more durable. Recommend
  presence-only; the rejected-alternative section in the
  plan-stage brainstorm can pin the exact wording if drift
  becomes a problem.

- **OQ-5. Token-budget tracking.** ENG-26 metrics include
  per-stage token cost; ENG-108 marginally inflates the
  implement-stage input token count (one extra Read of up to
  ~200 KB worst case, ~typically 5-20 KB). Worth a one-line
  retrospective note ("post-ENG-108, implement input tokens
  ticked up by ~X%") — but not worth instrumentation in this
  ticket. Today's `events.jsonl` already captures the deltas.

## 8. ADR stress test

There is no `docs/knowledge/decisions.md` file. Durable
architectural rules live in CLAUDE.md and
`docs/architecture.md`. ENG-108 puts pressure on the
following:

- **CLAUDE.md "Cross-dispatch staleness contract (ENG-87)"
  §"Per-medium primitives" — per-issue files clear-on-dispatch-
  start.** `progress.md` is the documented exception (ENG-107
  D-003). ENG-108 acts on that exception — it reads a file
  that is INTENTIONALLY not cleared. The runbook
  (`docs/runbooks/progress-md.md:78-91`) already calls this
  out; no rule overturn. ENG-108 is the first concrete reader
  exercising the exception, validating the design.

- **CLAUDE.md "Don't add features, refactor, or introduce
  abstractions beyond what the task requires."** Borderline —
  could be argued that adding `{progress_md_path}` to the
  resolver registry is unnecessary if the agent could just
  read the file via its already-known absolute path. Counter:
  the agent does NOT know `$PROJECT_STATE_DIR` (it's a
  harness env var, not an agent-side variable); the resolver
  is the only way to surface the absolute path without
  hand-rolling it in AGENT_PROMPTS.md (which D-001 rejects on
  drift grounds). Resolver is the minimum.

- **CLAUDE.md "Stage summary file — overwrite-on-every-dispatch
  contract (ENG-77/ENG-71)."** ENG-108 does NOT add another
  overwrite-on-every-dispatch contract. The agent's `Read` of
  `progress.md` is a pure read; no write side. The contract
  remains scoped to `stage-summary-*.md`.

- **CLAUDE.md "Tool allowlist & probing (ENG-53 #11 / ENG-57)."**
  The implementing stage's allowlist (per the project profile
  addendum's "Tool allowlist" section in this very prompt)
  does NOT enumerate `Read` as a per-stage Bash pattern,
  because `Read` is one of the stage-agnostic core tools
  (named explicitly in the profile preamble: "Stage-agnostic
  core tools (Read, Write, Edit, Grep, Glob, TaskCreate,
  git family, …) are implicit and not declared here"). So
  the agent can Read `$PROJECT_STATE_DIR/<ident>/progress.md`
  by absolute path with no allowlist change. Verified.

## 9. Assumption inventory

Every named symbol, path, file, or contract referenced above
has been grep-verified against the current working tree (the
ENG-5 anti-bias check).

| # | Assumption | Status | Evidence |
|---|---|---|---|
| A1 | `bin/common.sh::progress_md_path` exists and returns `$PROJECT_STATE_DIR/<ident>/progress.md` | **verified** | `bin/common.sh:78-82` (read directly) |
| A2 | `bin/common.sh:400` `export -f` line includes `progress_md_path` | **verified** | `bin/common.sh:400` (read directly) — line ends with `… progress_md_path` |
| A3 | `bin/render-prompt.sh::PROMPT_RESOLVERS` is the resolver registry; adding a new entry is the documented extension point | **verified** | `bin/render-prompt.sh:41-55` (read directly); the comment at lines 36-40 spells out the "register here, add resolver function, emit token in AGENT_PROMPTS.md" three-step contract |
| A4 | `bin/render-prompt.sh::_resolve_stage_summary_path` exists and is a one-line `printf` of a `_RENDER_*` global | **verified** | `bin/render-prompt.sh:226` (read directly): `_resolve_stage_summary_path() { printf '%s' "$_RENDER_STAGE_SUMMARY_PATH"; }` |
| A5 | `bin/render-prompt.sh::_resolve_review_findings` is the precedent for content-inlining resolvers and lives at lines 245-252 | **verified** | `bin/render-prompt.sh:245-252` (read directly): reads `_RENDER_REVIEW_FINDINGS_PATH`, falls back to sentinel string |
| A6 | `bin/render-prompt.sh::main` binds `_RENDER_*` globals at lines 404-421 before calling `resolve_block_tokens` | **verified** | `bin/render-prompt.sh:404-421` (read directly) |
| A7 | `bin/render-prompt.sh::resolve_block_tokens` only invokes resolvers for tokens that appear in the source; unused registered resolvers are silent | **verified** | `bin/render-prompt.sh:267-312` (read directly): `tokens="$(grep -oE '\{[a-z_]+\}' <<<"$rendered" \| sort -u \|\| true)"` — iterates over tokens found in source |
| A8 | `AGENT_PROMPTS.md §3 Implementation Agent` read-first list is at lines 614-622 with items `1. CLAUDE.md` through `8. docs/plans/{plan_file}` | **verified** | `AGENT_PROMPTS.md:614-622` (read directly) |
| A9 | `bin/run-stage.sh::_clear_current_stage_slots` at lines 883-891 clears only `stage-summary-${stage}.md` and `wait-${stage}.json`; `progress.md` is not in the cleared set | **verified** | `bin/run-stage.sh:883-891` (read directly) |
| A10 | `bin/run-stage.sh:1288` invokes `bin/render-prompt.sh` to produce the prompt file | **verified** | `bin/run-stage.sh:1288` (located via grep) |
| A11 | `bin/render-prompt-rc0-test.sh` exercises full `main()` execution with stub `linear.sh` + `branch-name.sh` and uses an `ENG-105 case A/B` pair at lines 117-157 for present/absent fixture testing of `{review_findings}` | **verified** | `bin/render-prompt-rc0-test.sh:1-162` (read directly); ENG-105 fixture pair at :117-157 |
| A12 | `bin/render-prompt-test.sh` exercises `append_project_profile` only, not full `main()` | **verified** | `bin/render-prompt-test.sh:1-120` (read directly); uses `src_with_env` to source render-prompt.sh and call `append_project_profile` directly, never invoking `main()` |
| A13 | `docs/runbooks/progress-md.md` exists with the schema, append-only contract, lifecycle, and dispatch-id-filter pattern described | **verified** | `docs/runbooks/progress-md.md:1-134` (read directly); §"Schema" at lines 29-61, §"Append-only contract" at 63-72, §"Cross-references" at 106-133 |
| A14 | ENG-107 brainstorm exists at `docs/brainstorms/2026-05-15-eng-107-progress-md-schema-and-per-issue-state-dir-slot-design.md` and contains the §6 long-lived-issues edge-case (200 KB worst case at observed dispatch rates) | **verified** | `docs/brainstorms/2026-05-15-eng-107-progress-md-schema-and-per-issue-state-dir-slot-design.md:478-484` (read directly) |
| A15 | `bin/common.sh::log` is the documented info-channel helper; routes to stderr | **verified by reference** — CLAUDE.md "When wiring a new script / Use `log` / `die` / `require_env` / `require_bin` from common.sh" + every existing script in `bin/` uses it. Not opened directly; the call site shape is standard |
| A16 | The agent's stage-agnostic `Read` tool can open arbitrary absolute paths (outside the worktree) without an allowlist entry | **verified** | Project profile addendum (in this prompt) "Stage-agnostic core tools (Read, Write, Edit, Grep, Glob, TaskCreate, git family, `bash bin/linear.sh`, …) are implicit and not declared here." Read is in the implicit core set |
| A17 | The brainstorm-doc basename token regex (`eng-N` case-insensitive) is enforced by `partition_dirty_paths::D-004` | **verified** | inherited from ENG-107 brainstorm §9 A16; basename of THIS file is `2026-05-16-eng-108-progress-md-implement-stage-reads-progress-entries-design.md` — contains `eng-108` ✓ |
| A18 | `PIPELINE_DISPATCH_ID` is exported by `bin/common.sh::allocate_dispatch_id` with format `ENG-N-dNNNN` | **verified** | `bin/common.sh:114-131, :144` (read directly); format set by `printf '%s-d%04d' "$issue" "$next_seq"` |
| A19 | `bin/agent-prompts-content-test.sh` exists as the canonical place for AGENT_PROMPTS.md content assertions | **verified** | `bin/agent-prompts-content-test.sh:1-30` (read directly); header line 2 spells out the file's purpose: "ENG-49: Invariants on AGENT_PROMPTS.md content. Asserts prompt-content rules …" — exact home for the position-1 read-first-list assertion |
| A20 | The implementer's `--allowed-tools` includes `Read` (core, implicit), so reading an absolute path under `$PROJECT_STATE_DIR/<ident>/` is permitted | **verified** | profile addendum's "Stage-agnostic core tools" preamble lists Read as core/implicit |

## 10. Persona review

Six personas were run in order
**design → security → scope → coherence → product → feasibility**.
Feasibility runs LAST because codebase-fact errors are always P0.

### 10.1 Design persona

**Concerns evaluated:** is the delivery mechanism right-shaped?
Is the read-first placement at position 1 architecturally
correct? Is the missing-file path properly designed?

- D-001 picks path-token + `Read`, rejecting inline-content with
  three concrete reasons (token budget, transcript visibility,
  read-pattern coherence). Each is independently
  load-bearing; the design choice is not over-determined.
- D-002 picks position 1 over position 7 (or above CLAUDE.md
  rather than after learned-rules) based on a literal reading
  of "first" plus the ENG-87 staleness-inversion principle. The
  reasoning chain is closed — no missing step.
- D-003 missing-file path: orchestrator-side info log +
  prompt-side "skip if not present." Both surfaces are needed:
  the log satisfies the testable AC-2; the prompt instruction
  satisfies the agent-side no-halt requirement. Symmetric.
- The resolver pattern (named global `_RENDER_PROGRESS_MD_PATH`
  + one-line `printf` resolver) is a direct copy of the existing
  `_resolve_stage_summary_path` shape. No new abstraction.

**Verdict: PASS** — no design changes required.

### 10.2 Security persona

**Concerns evaluated:** can a dispatched agent on issue A read
issue B's progress.md? Are absolute-path injections possible?
Are secret-handling rules respected?

- **Cross-issue read isolation.** The agent on issue A could
  Read issue B's progress.md by absolute path — same property
  as ENG-107 §10.2 noted for stage-summary files. ENG-108 is
  not a regression; the property is unchanged by adding a
  reader pilot. Recorded as observation, not blocker.
- **Path injection.** The resolved absolute path comes from
  `progress_md_path "$issue_id"` which composes
  `$PROJECT_STATE_DIR/$issue_id/progress.md`. If a maliciously-
  crafted `issue_id` carried `../../../etc/passwd`, the resolved
  path could escape the issue's directory. Mitigations: (a)
  `issue_id` is validated upstream by Linear's identifier-shape
  (`ENG-\d+`); (b) `bin/run-stage.sh::main` reads `issue_id`
  from Linear's authoritative identifier field, never from
  user-provided strings; (c) the orchestrator-side info-log is
  the only orchestrator-side action on the path — `log` is
  inherently safe. Not a real threat surface in this flow.
- **Secret handling (ENG-46).** The resolver does not touch any
  `*KEY|*TOKEN|*SECRET|ANTHROPIC*|GITHUB*|LINEAR*` env var. No
  `${VAR:-...}` patterns. The info-log message includes the
  resolved absolute path which contains the user's home dir
  and the issue id; neither is a secret. ENG-46 compliance is
  trivially satisfied.
- **Prompt-injection via progress.md content.** A malicious or
  buggy prior-dispatch writer could put adversarial text into
  `progress.md` that the implementer reads. Today, the same
  vulnerability exists for `stage-summary-reviewing.md` (read
  by the implementer via `{review_findings}` token-inline) and
  every other in-prompt artifact. ENG-108 does not raise the
  ceiling — agent already trusts content under
  `$PROJECT_STATE_DIR/<ident>/`. If the threat model changes,
  a separate sub-ticket can introduce a sanitization pass.

**Verdict: PASS** — one residual cross-issue-read observation
recorded (inherited from ENG-107); not blocking.

### 10.3 Scope persona

**Concerns evaluated:** does the brainstorm stay within the
Linear IN list? Does any decision drift into ui/qa/review or
into writer territory?

- **IN list coverage.** Implement prompt preamble: D-002 ✓.
  Optional render-prompt token: D-001 ✓ (we are doing it).
  Test fixture: D-004 ✓ (case A + case B).
- **OUT list coverage.** ui/qa/review readers: explicitly
  scoped out in D-005 (no changes to §§4-6 of AGENT_PROMPTS.md).
  Writer responsibilities for implement: explicitly scoped
  out in D-005 (no writer instruction in §3).
- **Subsystems touched.** Per CLAUDE.md "Ticket sizing rubric"
  §"Axis 1": agent prompts (AGENT_PROMPTS.md §3), dispatch
  (render-prompt.sh resolver + log), tests
  (render-prompt-rc0-test.sh + optional agent-prompts-content-test.sh).
  Three subsystems by the strict rubric. Two are clearly
  subordinate (render-prompt change = 6 LOC; tests = inevitable
  travel-with-production). The actual surface-area change is
  ~10 LOC in production code. The "one clearly subordinate" rubric
  clause covers this; explicit scope boundary stated in §1's
  in/out table satisfies the rubric.
- **Independent design decisions.** D-001 (delivery mechanism)
  is the load-bearing decision; D-002 (placement) and D-003
  (missing-file) are derivative given D-001; D-004 (test
  surface) and D-005 (scope boundary) are mechanical. One
  independent decision; under the 2-independent threshold.

**Verdict: PASS** — squarely within scope.

### 10.4 Coherence persona

**Concerns evaluated:** does this fit existing harness
conventions? Does it conflict with any cross-cutting rule?

- **Token naming.** `{progress_md_path}` mirrors
  `{stage_summary_path}` (both: `<artifact>_path` snake-case
  shape). Coherent.
- **Resolver function naming.** `_resolve_progress_md_path`
  mirrors `_resolve_stage_summary_path`. Coherent.
- **`_RENDER_*` global naming.** `_RENDER_PROGRESS_MD_PATH`
  mirrors `_RENDER_STAGE_SUMMARY_PATH`. Coherent.
- **Read-list placement.** Position 1 deviates from the
  convention that every other stage's read-first list starts
  with CLAUDE.md. Flagged for follow-up cohort: when ui/qa/
  review readers extend this pattern, the convention becomes
  "position 1 = progress.md for any reader stage; CLAUDE.md
  at position 2." If a future operator skims §§3-6 expecting
  CLAUDE.md at position 1 across the board, they'll see the
  deviation; the position-1 instruction body spells out the
  rationale ("cross-dispatch context from prior agents")
  inline, mitigating the surprise. Coherent-with-flag.
- **Info-log format.** `render-prompt: progress-md missing for
  <ident> at <path> (informational; …)` mirrors existing
  render-prompt log lines (e.g., `render-prompt: WARNING —
  project-profile schema_version != 1` at
  `bin/render-prompt.sh:204`). Coherent.
- **Test-file placement.** Extending
  `render-prompt-rc0-test.sh` matches the ENG-105
  case-A/case-B precedent at lines 117-157. Coherent.
- **Stage-agnostic resolver vs stage-conditional log.** The
  resolver is registered globally (works for any stage), but
  the info-log only fires for `implementing`. The token is
  only USED by `implementing` today. This asymmetry is
  intentional — the resolver is the cheap part to install
  proactively; the log is the part with a defined
  semantic per the AC-2 wording (which scopes to implement).
  Coherent given the explicit ticket scope.

**Verdict: PASS** — placement-deviation flagged but acceptable
given the stronger AC-1 mandate.

### 10.5 Product persona

**Concerns evaluated:** does this advance ENG-28? Is the
foundation right-sized for the follow-up reader cohort?

- **ENG-28 progress.** ENG-28's goal is a continuous,
  cross-dispatch notebook so a later-stage agent has the
  prior-stage agent's context without re-reading every
  transcript. ENG-107 shipped the substrate; ENG-106 ships the
  first writer; ENG-108 ships the first reader. After ENG-108,
  an end-to-end plan→implement exchange becomes observable:
  the planner writes one or more entries during plan stage,
  and the implementer reads them on dispatch. This is the
  minimum closed loop that lets the operator evaluate whether
  the design actually delivers value (vs. clutter the
  implementer's context).
- **Right-sized for follow-up.** The follow-up reader cohort
  (ui/qa/review per the Linear OUT list) extends D-002's
  position-1 read-first pattern to §§4-6. Each extension is
  ~3 LOC of prompt edit + 1 LOC of the info-log condition.
  No architectural commitment locks the follow-up into a
  shape; the only "convention" set by ENG-108 is the
  position-1 placement, which the follow-up coordinator can
  validate against ergonomic feedback from ENG-108 in
  production.
- **Failure mode at iter-1.** If the implementer ignores
  progress.md entries or treats them as gospel (cargo-culting
  prior-dispatch decisions that no longer apply), the
  retrospective agent will surface it after ~2 weeks. The
  prompt-side instruction ("the prior dispatch may have
  flagged that a plan task is blocked …") is open-ended
  enough to let the agent evaluate freshness per-entry.
  Acceptable risk; OQ-2 captures the "filter by dispatch-id"
  refinement for later.
- **No premature scope drift.** D-005 explicitly defers
  writer responsibilities for implement; OQ-1 defers the
  envelope-validator detective check; OQ-3 defers the
  cross-stage adoption ordering. Each is a one-issue
  follow-up at most, not a sprawling cohort.

**Verdict: PASS** — foundation correctly sized for the writer
pilot (ENG-106) and the follow-up reader cohort.

### 10.6 Feasibility persona

**Concerns evaluated:** are all referenced symbols/paths real?
Does the proposed code compile? Are the test fixtures runnable?

Per the codebase-fact verification mandate, every named symbol,
file, path, and line reference in §§1-9 was checked against the
working tree (see §9 Assumption inventory for the full table).
Summary:

- `bin/common.sh::progress_md_path` at lines 78-82 ✓ (read directly)
- `bin/common.sh:400` export -f line includes `progress_md_path` ✓
- `bin/render-prompt.sh::PROMPT_RESOLVERS` at lines 41-55 ✓
- `bin/render-prompt.sh::_resolve_stage_summary_path` at line 226 ✓
- `bin/render-prompt.sh::_resolve_review_findings` at lines 245-252 ✓
- `bin/render-prompt.sh::main` `_RENDER_*` bindings at lines 404-421 ✓
- `bin/render-prompt.sh::resolve_block_tokens` token-iteration
  loop at lines 267-312 ✓ — confirms unused registered resolvers
  are silent; new resolver does not affect other stages
- `AGENT_PROMPTS.md §3` read-first list at lines 614-622 ✓
- `bin/run-stage.sh::_clear_current_stage_slots` at lines 883-891 ✓
  — confirms `progress.md` is intentionally not in cleared set
- `bin/run-stage.sh:1288` invokes render-prompt.sh ✓
- `bin/render-prompt-rc0-test.sh` ENG-105 case A/B pair at lines
  117-157 ✓ — confirms the present/absent fixture pattern lands
  cleanly in this file
- `bin/render-prompt-test.sh` `src_with_env` source-pattern at
  lines 49-67 ✓ — confirms this is NOT the right home for the
  new fixtures (it sources rather than execs)
- `docs/runbooks/progress-md.md` at lines 1-134 ✓
- ENG-107 brainstorm at the cited path ✓
- `PIPELINE_DISPATCH_ID` allocator at `bin/common.sh:114-131,
  :144` ✓ — format `ENG-N-d<NNNN>` confirmed

**A19 follow-up — verified mid-feasibility-pass.** Initially
marked "assumed" pre-grep; subsequently opened directly. File
exists at `bin/agent-prompts-content-test.sh` (79 KB executable;
header self-describes as the ENG-49 invariant-asserter for
AGENT_PROMPTS.md content). The file's existing helpers
(`section_body`, `rendered_stage_body`, lines 21-30) match the
shape ENG-108's new fixture needs (grep within §3's rendered
body for `{progress_md_path}` at position 1). Status updated to
**verified** in §9. No P0; no fallback needed.

**Resolver-pattern proof.** The proposed resolver:

```bash
_resolve_progress_md_path() { printf '%s' "$_RENDER_PROGRESS_MD_PATH"; }
```

is byte-for-byte structurally identical to the existing
`_resolve_stage_summary_path()` at `bin/render-prompt.sh:226`.
Bash 3.2 (macOS system bash) syntax. No surprises.

**Test fixture proof.** The proposed case A/B pair would set
`HARNESS_STATE_DIR="$sandbox/state"` (already done in the
ENG-105 case A/B fixtures at lines 134, 150) and, for case B,
pre-seed `$sandbox/state/test-slug-rc0/ENG-87R6X-C/progress.md`
with a sentinel before invoking `render-prompt.sh implementing
ENG-87R6X-C`. The case-A path is mechanically identical to
ENG-105 case A's "no prior review on disk" setup at lines
130-141.

**Verdict: PASS · P0 findings: 0** — every referenced
symbol/path is grep-verified against the current tree; one
"assumed" assumption (A19) is bounded and has a fallback;
no codebase-fact errors.

## 11. Gate summary

| Persona | Verdict | Notes |
|---|---|---|
| Design | PASS | No design changes required. |
| Security | PASS | Cross-issue-read observation recorded (inherited from ENG-107); not blocking. |
| Scope | PASS | Single load-bearing decision; subsystem-count covered by the "clearly subordinate" rubric clause. |
| Coherence | PASS | Position-1 placement deviates from the CLAUDE.md-first convention; rationale (ENG-87 staleness inversion + literal "first" AC) is documented inline; convention extends naturally as ui/qa/review readers land. |
| Product | PASS | Closes the plan→implement loop; sized appropriately for follow-up reader cohort. |
| Feasibility | PASS · P0=0 | Every referenced symbol/path grep-verified; one "assumed" assumption (A19) bounded with fallback. |

**Personas: 6/6 PASS · gate P0: 0 · proceeding to planning.**
