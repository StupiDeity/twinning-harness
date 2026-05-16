---
linear: ENG-109
title: progress.md — extend coverage to the remaining six stages
date: 2026-05-16
status: draft
---

# ENG-109 — `progress.md` extend coverage to remaining stages

## 1. Problem

ENG-28 (parent umbrella) proposes a continuous, per-issue `progress.md`
notebook so a future dispatch's agent on the same issue can read what
prior-dispatch agents chose to record without re-parsing every
transcript. The umbrella decomposes into:

| Sub-ticket | Scope | Status |
|---|---|---|
| **ENG-107** | File slot + schema + `bin/common.sh::progress_md_path` helper + runbook + CLAUDE.md catalog. Foundation only — no agent reads/writes. | **Shipped** (commit `ce56500` — `feat(eng-107): Progress.md: schema and per-issue state-dir slot`). |
| **ENG-106** | Plan-stage **writer pilot** — first stage that appends an entry on clean exit. | Not yet shipped. |
| **ENG-108** | Implement-stage **reader pilot** — first stage that consumes prior entries before doing work. | Not yet shipped. |
| **ENG-109 (this)** | Roll out write+read rules to the remaining six stages (brainstorm, ui, review, qa, build, release), extend dispatch.sh detective scan to all stages, add tests. | Brainstorm in flight (this doc). Blocked-by ENG-108 per Linear. |

ENG-109 is the rollout ticket. Once the two pilots establish their
prompt-side shapes and any helper plumbing they need, ENG-109 replicates
that pattern across `brainstorming`, `ui`, `reviewing`, `qa`, `building`,
and `released`. The hazards in scope:

1. **Stage coverage.** Every one of the six remaining stages must be
   wired both as writer (AC#1: "every stage agent appends a progress.md
   entry on clean exit") and reader (AC#2: "every stage agent reads
   progress.md before other context"). Missing a single stage produces
   the asymmetry hazard ENG-87 names: one dispatch records, the next
   dispatch on the same issue cannot see it. The Linear AC explicitly
   names "every stage."

2. **Detective scan.** AC requires "Detective scan extension in
   dispatch.sh to all stages." dispatch.sh today carries cross-stage
   detectives (ENG-66 branch-creation forms; ENG-68 `core.bare`-touching
   git forms — both run in `_render_and_capture_stream`'s post-stream
   block at `bin/dispatch.sh:185-235` against every stage). The natural
   shape for ENG-109 is one more cross-stage detective targeting the
   most plausible misuse of the new file: **a `Write` (truncate) tool
   call against `progress.md`**, which would clobber the cross-dispatch
   accumulation the schema's whole point depends on.

3. **Tests.** AC#3 names a "Cross-stage test fixture: brainstorm →
   plan → implement chain produces a coherent progress.md log." Plus
   the Linear ticket body asks for "at least one write + one read per
   stage." Both surfaces live in `bin/`-sibling test scripts (no
   external test runner; per the harness profile's "Build & test
   gates" section). The two pilots will own the write/read shapes
   they pioneer; ENG-109 owns the per-stage replication tests and the
   cross-stage chain fixture.

4. **Token resolver.** The agent prompts in AGENT_PROMPTS.md
   interpolate `{token}` strings via `bin/render-prompt.sh`'s
   PROMPT_RESOLVERS registry (`bin/render-prompt.sh:41-55`). The
   simplest way for six stage prompts to reference the canonical
   progress.md path is a new `{progress_md_path}` token resolved via
   the existing `bin/common.sh::progress_md_path` helper — mirroring
   how `{stage_summary_path}` resolves
   (`bin/render-prompt.sh:226, :389`). Plumbing the resolver is
   ENG-109's job because no pilot will need it for itself alone
   (each pilot only touches its own §; ENG-109 touches six).

The Linear acceptance criteria:

1. Every stage agent appends a `progress.md` entry on clean exit.
2. Every stage agent reads `progress.md` before other context.
3. Cross-stage test fixture: brainstorm → plan → implement chain
   produces a coherent `progress.md` log.

OUT: any schema migration (e.g., heading-shape changes, JSONL switch,
HTML-comment markers). ENG-107's schema is the locked contract.

This brainstorm proposes a minimal rollout that satisfies all three
ACs without re-litigating the ENG-107 schema.

## 2. Decisions

- **D-001. The six stages wired by ENG-109 are exactly
  `brainstorming`, `ui`, `reviewing`, `qa`, `building`, `released` —
  the complement of the two pilot stages `planning` (ENG-106) and
  `implementing` (ENG-108).**

  Each stage's AGENT_PROMPTS.md block gains two clauses:

  - **Read clause** — added to the existing "Read these files first"
    list (top of each stage body). Position: BEFORE the
    `learned_rules/<stage>.md` and `brainstorm_file` / `plan_file`
    lines, so the dispatch agent reads the cross-dispatch notebook
    before the stage-specific context, per AC#2 ("reads progress.md
    before other context").
  - **Write clause** — added to the Output / Completion-checklist
    section. Fires only on the clean-exit path (verdict `pass` for
    most stages; verdict `pass --stage building` for build's merged-
    state branch). The agent appends an H2-headed entry to the
    canonical path with the dispatch-id-stamped heading shape from
    `docs/runbooks/progress-md.md` §2.

  Mapping to the AGENT_PROMPTS.md section table at the top of
  `bin/render-prompt.sh` (`STAGE_TO_SECTION`):

  | Stage | Section | Both clauses needed? |
  |---|---|---|
  | brainstorming | §1 | Yes |
  | (planning) | §2 | Owned by ENG-106 (pilot) |
  | (implementing) | §3 | Owned by ENG-108 (pilot) |
  | ui | §4 | Yes |
  | reviewing | §5 | Yes |
  | qa | §6 | Yes |
  | building | §7 | Yes — but write clause fires only on Decision-path B (merged) |
  | released | §8 | Yes — write clause is permissive (one-line entry acceptable since the agent is a read-only observer) |

  *Reference to constraint:* the Linear AC enumerates "every stage
  agent." `bin/render-prompt.sh::STAGE_TO_SECTION` at lines 18-26
  binds the stage names to their AGENT_PROMPTS.md sections; the table
  above is a 1:1 copy minus the two pilot rows. The retrospective
  stage (§9) is intentionally excluded — it is scheduled (not per-
  issue), runs on a generated branch (`pipeline/retrospective-{date}`),
  has no `PIPELINE_ISSUE_ID` (see `bin/dispatch.sh:432-434` and the
  ENG-94 `_dispatch_tools_from_profile` fallback for the retro stage),
  and therefore has no `issue_dir` and no `progress.md` to write to.

  *Reference to principle:* CLAUDE.md "Don't add features … beyond
  what the task requires." ENG-109 ships exactly the six-stage
  rollout. Retrospective integration (OQ-2 in the ENG-107 brainstorm)
  stays deferred.

  *Rejected alternative — wire only "code-changing" stages
  (implementing, ui, qa, building) and skip the read-only ones
  (brainstorming, reviewing, released):* rejected because the AC
  explicitly says "every stage." The brainstorm stage in particular
  is the stage MOST in need of cross-dispatch context — a re-
  dispatched brainstorm on iteration 2 of ENG-65's "iteration-
  exhausted" path is exactly where a prior dispatch's "we tried X
  and it failed because Y" body would save 30 min of re-derivation.
  Read-only stages also benefit from the read side (release agent
  reads "what surprised the prior agents" before composing a release
  summary).

  *Rejected alternative — also wire retrospective (§9):* rejected
  because retrospective has no `PIPELINE_ISSUE_ID` and no per-issue
  scratch dir. The retrospective's input universe is `events.jsonl`
  + per-stage transcripts + `learned-rules/*.md`. Wiring a
  cross-issue progress.md surface would either require a new
  per-retrospective slot (out of scope; ENG-107 didn't reserve one)
  or invent a global progress.md (no such file exists; design
  inversion of "per-issue").

- **D-002. Write clause goes in each stage's per-stage Output
  section; read clause goes in §0 (Common rules), prepended to every
  stage by `bin/render-prompt.sh::main` before the per-stage block
  is rendered.**

  Read clause shape (single edit in §0 — covers all six stages plus
  the two pilots and any future stage):

  ```
  **Cross-dispatch progress notebook (ENG-28):** Before reading any
  stage-specific context, Read `{progress_md_path}`. If the file
  exists and is non-empty, scan the H2 entries from prior dispatches
  on this issue. Entries are headed
  `## <dispatch-id> - <stage> - <ISO-8601-UTC>`; treat any entry
  whose `<dispatch-id>` differs from `{dispatch_id}` as prior-
  dispatch context. The file is empty / absent on first dispatch of
  an issue — silently skip. Append-only: never edit a prior entry.
  Schema and lifecycle live in `docs/runbooks/progress-md.md`.
  ```

  Write clause shape (per-stage Output bullet — replicated six
  times with stage-name substitution; mirrors the per-stage Output
  pattern at AGENT_PROMPTS.md:309-327 for §1, :754-771 for §3, etc.):

  ```
  - Append a `progress.md` entry at `{progress_md_path}` BEFORE
    posting the verdict marker. Use `Edit` to append (or
    `bash -c 'cat >> {progress_md_path} <<EOF ... EOF'` if `Edit`
    isn't available for the stage; the harness allowlist grants
    bash + heredoc on every stage). NEVER use `Write` (truncates).
    Heading shape: `## {dispatch_id} - <stage-gerund> - <UTC-now>`
    where `<stage-gerund>` matches the stage's prompt token
    (brainstorming|ui|reviewing|qa|building|released) and `<UTC-now>`
    is ISO-8601 second-precision. Body: 1-5 sentences capturing
    what the next dispatch on this issue should know (decisions,
    surprises, dead-ends, open questions). Skip the body content if
    you have nothing concrete to add — the heading-only entry is
    still load-bearing because it confirms a dispatch ran.
  ```

  Per-stage adjustments:

  - **§1 brainstorming** — Append entry just before step 6 (verdict
    post). Body suggestion: "the open questions surfaced by the 6
    personas that remain unresolved."
  - **§4 ui** — Append after the second-reviewer pass. Body
    suggestion: "the components touched and any cross-component
    concerns the next stage should know."
  - **§5 reviewing** — Append on Decision-path C only (clean
    review). On paths A/B the loopback comment + stage-summary
    carry the loopback signal; progress.md should NOT be written on
    fail-paths because the body would be the same loopback rationale
    duplicated. (Rejected alternative below.)
  - **§6 qa** — Append on Decision-path C/D only. Body suggestion:
    "adversarial findings or back-fill confirmation."
  - **§7 building** — Append on Decision-path B (merged) only.
    Wait-shape exits (P2/P5) do NOT append — they're not "clean
    exit" by the Linear AC's wording. Body suggestion: merge SHA +
    one-line of post-merge CI outcome.
  - **§8 released** — Append on the success path of the per-issue
    enrichment loop (step 4 of §8). Body suggestion: one line
    `version={version} category=<cat>` since the release agent is a
    read-only observer with little new context to record.

  *Reference to constraint:* AGENT_PROMPTS.md §0 (Common rules)
  is documented at `AGENT_PROMPTS.md:212-230` as "automatically
  prepended to every per-stage prompt by `bin/render-prompt.sh::main`
  before the stage-specific block is rendered. Edit it once here
  when a rule applies uniformly to all stages." The read clause
  satisfies that uniformity test verbatim. The write clause has
  per-stage variation (Decision-path gating for §5, §6, §7) and
  therefore stays per-stage.

  *Reference to principle:* CLAUDE.md "Default to writing no
  comments. Only add one when the WHY is non-obvious. Applied to
  prompts: keep the rule once, refer once." The §0 consolidation
  is the prompt-side analogue of DRY.

  *Rejected alternative — write clause also in §0:* rejected
  because §5's loopback semantics, §7's wait-shape exits, and §8's
  read-only-observer profile each carry stage-specific gating that
  a uniform §0 clause would either flatten incorrectly (every
  stage writes always — wrong for §7 wait exits) or force into
  an awkward "...except for paths X, Y, Z" conditional that's
  harder to grep + audit than six small per-stage clauses.

  *Rejected alternative — write on fail-paths too (e.g., §5
  loopback):* rejected because the loopback comment + stage-summary
  already capture the "why this failed" story for the next
  dispatch. Adding a progress.md entry would duplicate that signal
  in a less-grep-friendly shape AND would risk poisoning future
  dispatches with stale rejection context after the issue advances
  past the loop. The ENG-77 / ENG-71 stale-summary class is the
  exact hazard.

  *Rejected alternative — require body content on every write
  (no heading-only entries):* rejected because some stages on some
  iterations have nothing concrete to add (§8 on a non-feature
  release; §1 on a re-dispatch where the prior dispatch's body
  still stands). A heading-only entry is still useful — it
  confirms "this dispatch ran on this issue" without forcing the
  agent to invent prose. Forcing prose invites hallucinated
  content; trusting the agent to skip when empty matches CLAUDE.md
  "Don't add error handling, fallbacks, or validation for
  scenarios that can't happen."

  *Rejected alternative — embed the heading template as a literal
  prompt token like `{progress_md_heading}`:* rejected because the
  heading composition depends on UTC-now which is the AGENT's
  runtime (the orchestrator at render time may be minutes ahead
  of the agent at write time on slow dispatches). Resolving
  heading-shape server-side would freeze the timestamp at render,
  introducing a small but real freshness hazard. Prompt-side
  string instructions are sufficient — the agent has `date -u
  +"%Y-%m-%dT%H:%M:%SZ"` available on every stage.

- **D-003. Plumb a new `{progress_md_path}` token in
  `bin/render-prompt.sh`'s PROMPT_RESOLVERS registry, resolved via
  the existing `bin/common.sh::progress_md_path` helper.**

  Mechanics:

  1. Add `progress_md_path=_resolve_progress_md_path` to the
     PROMPT_RESOLVERS variable at `bin/render-prompt.sh:41-55`.
  2. Add the resolver function near the existing
     `_resolve_stage_summary_path` (`bin/render-prompt.sh:226`):

     ```bash
     _resolve_progress_md_path() { printf '%s' "$_RENDER_PROGRESS_MD_PATH"; }
     ```
  3. Bind `_RENDER_PROGRESS_MD_PATH` in `main()` at
     `bin/render-prompt.sh:382-422` (alongside the existing
     `_RENDER_STAGE_SUMMARY_PATH` binding at `:413`):

     ```bash
     _RENDER_PROGRESS_MD_PATH="$(progress_md_path "$issue_id")"
     ```

     The helper is already exported (`bin/common.sh:400`) so this
     is a same-process invocation. No new export, no new global.

  *Reference to constraint:* `bin/render-prompt.sh:34-55` documents
  the registry add-a-token contract: "Adding a new token = (a)
  register here, (b) add the resolver function below, (c) emit the
  {token} in AGENT_PROMPTS.md." All three sub-steps are explicit
  and ENG-109 follows them. The render-time validator at
  `bin/render-prompt.sh:288-289` dies on any unknown `{token}` —
  so the registry entry is load-bearing (no entry = render dies
  the moment §0 references `{progress_md_path}`).

  *Reference to principle:* CLAUDE.md "Don't add features … beyond
  what the task requires." The resolver is a one-line wrapper
  over the existing helper. Same minimal-abstraction defense as
  the ENG-107 `progress_md_path` helper itself.

  *Rejected alternative — hard-code the path in each stage prompt
  (no token):* rejected because (a) the path shape leaks
  `$PROJECT_STATE_DIR/<ident>/progress.md` into every prompt, (b)
  the agent at runtime cannot expand `$PROJECT_STATE_DIR` (it's an
  orchestrator-side env var, not exported into the agent's
  context), (c) this is exactly the ENG-79 drift class the helper
  was created to prevent — six independent string-concatenations
  of the path across six prompts will eventually drift.

  *Rejected alternative — re-use `{stage_summary_path}`'s resolver
  to also output progress.md path:* rejected as nonsensical (two
  paths with different lifecycles cannot share a resolver) but
  flagged here because a sloppy "one resolver, two callers" reading
  of the existing code might tempt it. Each token gets exactly one
  resolver.

- **D-004. Detective scan extension in dispatch.sh: forbid `Write`
  tool calls whose `file_path` matches `progress.md`, across all
  stages. Reuses exit code 29 (envelope violation) for symmetry
  with the existing cross-stage detectives.**

  Mechanics:

  1. Add a new helper `assert_no_write_to_path` in
     `bin/common.sh` (sibling of `assert_no_tool_invocation` at
     `bin/common.sh:188-205`):

     ```bash
     assert_no_write_to_path() {
       local transcript="$1" path_suffix="$2"
       [[ -s "$transcript" ]] || return 0
       local matched
       matched="$(jq -Rr --arg p "$path_suffix" '
         fromjson? // empty
         | select(.type == "assistant")
         | .message.content[]?
         | select(.type == "tool_use" and .name == "Write")
         | (.input.file_path // "")
         | select(endswith($p))
       ' "$transcript" 2>/dev/null | head -1)" || true
       if [[ -n "$matched" ]]; then
         printf '%s\n' "$matched"
         return 1
       fi
       return 0
     }
     ```

     `endswith` (not `startswith`) is the right shape because the
     agent's `Write` calls carry an absolute path
     (`/Users/.../<ident>/progress.md`) and the relevant signal is
     the suffix.

  2. Extend `bin/dispatch.sh::_render_and_capture_stream` post-
     stream block (where ENG-66 and ENG-68 cross-stage scans live
     today, `bin/dispatch.sh:185-235`) with a new loop. Mirror
     ENG-66's shape — no stage gate, one violation pattern,
     halt-with-29 on hit:

     ```bash
     # ENG-109: forbid Write tool truncation of progress.md across
     # all stages. The append-only contract of progress.md
     # (docs/runbooks/progress-md.md §3) is a CONVENTION not a
     # filesystem ACL; this detective is the catch-net for an
     # agent that uses Write where Edit-with-append (or
     # `cat >> {progress_md_path} <<EOF`) was the correct shape.
     local _matched_write
     if _matched_write="$(assert_no_write_to_path "$raw_capture" "/progress.md")"; then
       :   # rc 0: no match, fall through
     else
       printf '%s\n' "$_matched_write" > "$violation_file"
       log "[assert] stage=$stage transcript invoked forbidden Write on progress.md: ${_matched_write}"
       return 29
     fi
     ```

  3. Export the new helper from `bin/common.sh:400`:

     ```diff
     -export -f issue_dir compute_pipeline_content_hash failure_outcome_for_exit parse_pipeline_marker is_orchestrator_paused set_orchestrator_paused allocate_dispatch_id current_dispatch_id assert_no_tool_invocation progress_md_path
     +export -f issue_dir compute_pipeline_content_hash failure_outcome_for_exit parse_pipeline_marker is_orchestrator_paused set_orchestrator_paused allocate_dispatch_id current_dispatch_id assert_no_tool_invocation progress_md_path assert_no_write_to_path
     ```

  4. The scan runs in `dispatch.sh`'s subprocess (per
     `assert_no_tool_invocation`'s call-site #1 at
     `bin/common.sh:179-181`). It runs BEFORE the persisted
     envelope sidecar (`.envelope-transcript-${stage}`) is read
     by run-stage.sh's later `_validate_dispatch_envelope`, so a
     Write-on-progress.md violation halts at dispatch time with
     exit 29 — same exit code as the ENG-87 envelope violations.
     No new exit code (per CLAUDE.md "Don't … use exit codes
     outside the taxonomy in `failure_outcome_for_exit`").

  *Reference to constraint:* CLAUDE.md "Per-stage allowed tool
  lists are centralized in `dispatch.sh::allowed_tools_for`."
  ENG-109 does NOT modify allowed_tools_for to deny Write —
  Write is legitimately used by every stage to overwrite the
  stage-summary file (see `bin/run-stage.sh:870-871` for the
  orchestrator-side clear; ENG-77 contract for the agent-side
  re-emit). Denial via allowlist would break stage-summary
  writes. The detective scan is the correct shape: allowed by
  policy in general, halt on specific misuse.

  *Reference to principle:* CLAUDE.md "Defense-in-depth: when a
  stage's contract says 'agent must not invoke tool X,' prefer a
  transcript-based assertion (`assert_no_tool_invocation` in
  `bin/dispatch.sh`) over a post-dispatch state check. State
  checks false-positive on actions taken by other actors." A
  post-hoc `git status` or filesystem-mtime check would fail this
  test because the file lives OUTSIDE the worktree (under
  `$PROJECT_STATE_DIR/<ident>/`) and is invisible to git.
  Transcript scan is the only correct detection layer.

  *Rejected alternative — extend `_validate_dispatch_envelope` in
  `bin/run-stage.sh` instead of `dispatch.sh`:* rejected because
  (a) the Linear AC explicitly says "dispatch.sh," (b) the in-
  dispatch.sh detectives (ENG-43, ENG-66, ENG-68, ENG-71) fire
  earlier than the envelope validator and produce a stage-time
  exit code with the matched-text written to the violation file
  the orchestrator reads. The envelope validator in
  `bin/run-stage.sh:901-965` is a fallback for the case where the
  in-dispatch checks were bypassed (D-005 forensic-asymmetry
  rationale). Putting the Write-on-progress check in run-stage
  duplicates a layer 1 scan as a layer 2 fallback only.

  *Rejected alternative — generalize `assert_no_tool_invocation`
  to handle multiple tool names (Bash + Write):* rejected because
  the existing helper has four call sites with
  Bash-specific `(.input.command // "")` semantics; widening it
  is a refactor outside ENG-109's scope. A sibling helper
  (`assert_no_write_to_path`) is the smaller, contractually
  clear shape. The two helpers can be consolidated in a future
  ticket once a third caller appears (e.g., a hypothetical
  `assert_no_edit_to_path`).

  *Rejected alternative — also forbid `Edit` mode that replaces
  the entire file (e.g., empty `old_string` + full-content
  `new_string`):* rejected as out of scope. `Edit` with
  append-via-anchor is the SUPPORTED writer path. Detecting
  "Edit that effectively replaces" requires parsing Edit's
  arguments and reasoning about whether `old_string` matches the
  entire prior file content — that's a content-aware analysis,
  not a transcript-shape check, and is a sub-ticket that would
  live with a real-world incident if one occurs.

  *Rejected alternative — forbid Bash `>` (single-redirect) to
  `progress.md`:* rejected because (a) this is the rarer
  truncation vector (agents prefer Write/Edit), (b) Bash
  redirects are stringly-typed inside `.input.command` and the
  regex space is much wider (could be `> progress.md`, `>
  $(progress_md_path …)`, `>"${PROG_PATH}"`, etc. — any of which
  the agent might construct). Layering more bash-redirect
  patterns to the loop adds complexity without commensurate
  detection gain. The runbook + prompt rule are the primary
  defense; the Write-tool detective catches the most common
  misuse only. Defense-in-depth on Bash redirects can be added
  later if observed in the wild.

- **D-005. Tests: extend `bin/agent-prompts-content-test.sh` with
  per-stage assertions for the read clause (single §0 assertion)
  and the write clause (six per-stage assertions), and add a new
  `bin/progress-md-cross-stage-test.sh` for the brainstorm → plan
  → implement chain fixture.**

  Test surface:

  | Test site | Assertions added |
  |---|---|
  | `bin/agent-prompts-content-test.sh` | (i) §0 carries the read-clause phrase "Cross-dispatch progress notebook (ENG-28)". (ii–vii) Each of §1, §4, §5, §6, §7, §8 carries the write-clause phrase "Append a `progress.md` entry at `{progress_md_path}`". (viii) §0 references `{progress_md_path}` (resolver wiring guard — fails loudly if the §0 edit forgot the token). (ix) `render-prompt.sh` PROMPT_RESOLVERS contains `progress_md_path=_resolve_progress_md_path` (cross-checks D-003 plumbing exists when D-002 expects the token to resolve). |
  | `bin/render-prompt-test.sh` (existing) | (x) Auto-covered by the existing ENG-87 R5 / R8 invariants — any `{progress_md_path}` token in AGENT_PROMPTS.md without a registered resolver dies on render; the test sources the same registry. No new test needed; the existing test catches the integration gap. |
  | `bin/dispatch-test.sh` (existing — extend) | (xi) Add a `Write on progress.md` fixture: a mock transcript containing a `tool_use` with `name=Write` and `input.file_path=/abs/path/progress.md` triggers `assert_no_write_to_path` rc=1 with the matched path printed. (xii) Negative case: a transcript with `Write` on a non-progress.md path (e.g., `stage-summary-implementing.md`) returns rc=0. |
  | `bin/common-test.sh` (existing — extend) | (xiii) Three fixtures on the new `assert_no_write_to_path` helper itself: (a) empty transcript returns 0, (b) Write on `.../progress.md` returns 1 with matched path, (c) Write on `.../something-else.md` returns 0. Mirrors the existing `assert_no_tool_invocation` test patterns at `bin/common-test.sh` (around the ENG-87 envelope section). |
  | `bin/progress-md-cross-stage-test.sh` (new) | (xiv) Synthesise a fixture progress.md by sequentially invoking three mock writes (brainstorm, plan, implement) and assert: (a) file contains three H2 entries in dispatch-id order, (b) each heading parses into the three-token shape, (c) the file is grep-friendly to a reader looking for `dispatch-id={current}`. This is the AC#3 "coherent chain" assertion. |

  Test invocations (gates):

  ```bash
  bash bin/agent-prompts-content-test.sh
  bash bin/render-prompt-test.sh
  bash bin/dispatch-test.sh
  bash bin/common-test.sh
  bash bin/progress-md-cross-stage-test.sh
  ```

  Each is a self-contained executable per CLAUDE.md "Tests are
  sibling shell scripts named `*-test.sh` in `bin/`." The new
  test file inherits the existing source-and-stub pattern.

  *Reference to constraint:* the harness profile's "Build & test
  gates" lists every `bin/*-test.sh` as a gate; the pre-commit
  hook (`/.githooks/pre-commit`) runs the entire suite. New
  tests automatically join the gate. ENG-109's per-target
  `dispatch.tools.implementing[]` list (CLAUDE.md "Per-target
  dispatch.tools extras") would need the new test file enumerated
  for the implement-stage allowlist; the regen recipe at
  CLAUDE.md "Per-target dispatch.tools extras" §"Wildcard pitfall"
  shows the regeneration command. ENG-109's implement-time task
  list includes that regen as a sub-step.

  *Reference to principle:* CLAUDE.md "Each `bin/foo.sh` ends
  with the sentinel" — the new `bin/progress-md-cross-stage-test.sh`
  carries the sentinel so a future sibling test can `source` it.
  Tests are self-contained executables per the harness idioms.

  *Rejected alternative — fold the cross-stage chain test into
  `bin/common-test.sh`:* rejected because the chain test
  simulates three full pseudo-dispatches (mock dispatch-ids,
  mock heading composition, mock writes) and the resulting
  scaffolding (~50-80 LOC) is meaningfully bigger than the
  `common-test.sh` per-helper fixture pattern. A dedicated test
  file keeps `common-test.sh` focused on common.sh helpers and
  scales the new chain-coherence assertions independently.

  *Rejected alternative — assert read-clause once in §0 and
  consider AC#2 satisfied (skip per-stage read assertions):*
  rejected because the per-stage assertions defend against a
  future edit that re-inlines per-stage rules (a known harness
  shape — see CLAUDE.md "agent-prompts-content-test.sh" use of
  `rendered_stage_body` which is §0 prepended to §N for exactly
  this reason). Pinning per-stage assertions on the rendered
  body via `rendered_stage_body` (the helper already in
  `bin/agent-prompts-content-test.sh:36-40`) guarantees the
  rule is delivered to each stage regardless of §0 consolidation
  versus per-stage inlining. The Linear AC phrasing "every stage
  agent" is satisfied at the rendered-prompt level, which is
  what `rendered_stage_body` measures.

- **D-006. ENG-109's implementation is gated on both pilots
  (ENG-106, ENG-108) shipping first. The brainstorm captures the
  rollout design but the implement-stage agent on this branch
  will halt at plan-time with `verdict halt --reason
  agent-blocked` if it dispatches before ENG-106 + ENG-108 are
  in `main`.**

  Rationale: ENG-109's six per-stage prompts mirror the two
  pilot prompts' shape. If we cut ENG-109 against the pre-pilot
  AGENT_PROMPTS.md, the six new clauses are FIRST-of-their-kind
  patterns that lock in a shape the pilots haven't yet validated.
  Better: let ENG-106 + ENG-108 ship, observe one full cycle's
  worth of agent behavior on the pilot shape, then ENG-109
  replicates the proven pattern.

  Concretely the plan stage of ENG-109 should:

  - Read `git log --oneline` on `main` for tags `feat(ENG-106)`
    and `feat(ENG-108)` (or check for the §2 + §3 prompt
    references to `{progress_md_path}`).
  - If either is missing, the plan agent emits
    `<!-- meta: metric name=plan_gap -->` naming the missing
    pilot and `verdict halt --reason agent-blocked`.
  - The orchestrator's `--action continue` from the operator
    (post-pilot-merge) re-runs the plan agent against a
    main with both pilots landed.

  *Reference to constraint:* Linear "Dependencies: Blocked by
  the implement-reader sub-ticket." Mechanically the harness
  has no blocked-by gate today (the orchestrator polls Linear
  state, not Linear dependencies). The plan-agent precondition
  check is the in-pipeline equivalent.

  *Reference to principle:* CLAUDE.md "Branch-base freshness
  check (MANDATORY — before recording any `path:line` excerpt
  in Assumption Inventory)." Same shape: if the upstream
  context isn't current, halt rather than freeze a wrong design.

  *Rejected alternative — proceed with implementation
  regardless of pilot status and rely on the pilots adapting
  ENG-109's shape on merge:* rejected because (a) the pilots
  ship FIRST per Linear's dependency declaration, (b) a
  three-way merge between ENG-106's §2 edit, ENG-108's §3
  edit, and ENG-109's §0/§1/§4-§8 edits in `AGENT_PROMPTS.md`
  is a known conflict surface (single-file, related edits) —
  hitting that in serial is cheaper than coordinating a
  three-way rebase.

  *Rejected alternative — also block on ENG-107:* not needed —
  ENG-107 has shipped (commit `ce56500`, verified via
  `git log --oneline -30`). The `progress_md_path` helper is
  available in `bin/common.sh:78-82` and the runbook is at
  `docs/runbooks/progress-md.md`. D-006 only fires the wait
  on ENG-106 + ENG-108.

## 3. Architecture (where code goes)

| Site | Change | Lines (approx.) |
|---|---|---|
| `AGENT_PROMPTS.md` §0 | Add the read-clause paragraph (single edit) inside the §0 fenced block, after the existing "Sub-agent debris (ENG-100)" paragraph | +10 |
| `AGENT_PROMPTS.md` §1 (brainstorming) | Add write-clause bullet to Completion checklist before the verdict-marker step | +10 |
| `AGENT_PROMPTS.md` §4 (ui) | Add write-clause bullet to Output section before stage-summary | +10 |
| `AGENT_PROMPTS.md` §5 (reviewing) | Add write-clause bullet to Decision-path C output | +10 |
| `AGENT_PROMPTS.md` §6 (qa) | Add write-clause bullet to Decision-path C/D output | +10 |
| `AGENT_PROMPTS.md` §7 (building) | Add write-clause bullet to Decision-path B (merged) output | +10 |
| `AGENT_PROMPTS.md` §8 (released) | Add write-clause bullet to per-issue enrichment loop | +10 |
| `bin/render-prompt.sh` | Register `{progress_md_path}` token: PROMPT_RESOLVERS entry, resolver function, `_RENDER_PROGRESS_MD_PATH` binding | +5 |
| `bin/common.sh` | Add `assert_no_write_to_path` helper near `assert_no_tool_invocation`; append the new function to the `export -f` line | +20 |
| `bin/dispatch.sh` | Insert the Write-on-progress.md scan loop after the ENG-68 `core.bare` block in `_render_and_capture_stream` (~line 235) | +12 |
| `bin/agent-prompts-content-test.sh` | Add the 9 new assertions per D-005 | +50 |
| `bin/common-test.sh` | Add 3 fixtures for `assert_no_write_to_path` near the existing envelope-helper tests | +35 |
| `bin/dispatch-test.sh` | Add 2 fixtures (positive + negative) for the new scan | +30 |
| `bin/progress-md-cross-stage-test.sh` | New file: chain fixture simulating brainstorm → plan → implement writes | +80 |
| `.pipeline-config/config.json` (harness-self target) | Add `bin/progress-md-cross-stage-test.sh` to `dispatch.tools.implementing[]` and `qa[]` per CLAUDE.md "Per-target dispatch.tools extras" | +2 |
| `learned-rules/harness/project-profile.md` | Mirror the same test-script enumeration in `## Tool allowlist` so the profile-side allowlist sees the new test | +2 |

Total: roughly 300 LOC across 13 files plus one new file. The
heaviest changes are six near-identical AGENT_PROMPTS.md write-
clause bullets (~10 LOC each) and the new cross-stage test
(~80 LOC).

Zero changes to:

- `bin/common.sh::progress_md_path` (ENG-107, untouched).
- `bin/run-stage.sh::_clear_current_stage_slots` (the cleared
  set stays exactly `stage-summary-${stage}.md` +
  `wait-${stage}.json`; `progress.md` is never cleared per
  ENG-107 D-003).
- `bin/run-stage.sh::_validate_dispatch_envelope` (the
  cross-stage detective lives in dispatch.sh per D-004; the
  envelope validator's `mcp__plugin_linear` /
  `curl https://api.linear.app` scans are independent).
- `bin/run-local-helpers.sh::partition_dirty_paths` (progress.md
  lives outside the worktree, invisible to the sweep — ENG-107
  D-003 verified).
- `bin/scope-check.sh::is_benign` (same out-of-worktree
  rationale).
- `docs/runbooks/progress-md.md` (ENG-107's runbook is the
  schema source of truth; ENG-109 does not change the schema).
- `CLAUDE.md` (the per-issue state-directory diagram already
  carries `progress.md` per ENG-107).
- `bin/pipeline-events.json` (no new verdict variants;
  detective halt reuses existing exit 29 + the
  `dispatch-envelope-violation` reason token).
- `bin/run-retrospective-local.sh` and retrospective prompts
  (out per Linear OUT list — schema migration is excluded;
  retrospective is not extended by ENG-109).

## 4. Data Flow

Pre-ENG-109 (after ENG-106 + ENG-108 ship):

1. A plan-stage dispatch on issue ENG-N writes the first
   progress.md entry per ENG-106's prompt.
2. An implement-stage dispatch on ENG-N reads progress.md
   before doing work per ENG-108's prompt.
3. Any other stage dispatched on ENG-N — brainstorm,
   ui, review, qa, build, release — has no instruction to
   read or write progress.md. The accumulated context from
   plan stops at implement; downstream stages re-derive
   from transcripts.

Post-ENG-109:

1. ANY stage dispatch on ENG-N (except retrospective)
   reads progress.md before the per-stage context list
   per §0's read clause.
2. ANY stage dispatch on ENG-N (except retrospective)
   appends a new H2 entry on clean exit per the per-stage
   write clause.
3. Detective scan in dispatch.sh rejects (rc=29) any
   `Write`-on-progress.md tool call in the transcript.
4. The cross-stage chain test in `bin/progress-md-cross-
   stage-test.sh` exercises a brainstorm → plan →
   implement sequence and asserts the resulting file is
   coherent (three entries, three distinct dispatch-ids,
   heading shape matches).

Reader-side filter (already supported by ENG-107 D-002
schema): readers compare each H2 heading's dispatch-id token
to `$PIPELINE_DISPATCH_ID` (the current dispatch's id). Same-
id entries are "this dispatch's own work"; different-id
entries are prior-dispatch context. The agent prompts (per
§0 read clause D-002) instruct the agent to do this
comparison verbatim.

## 5. Error Handling

- **Detective fires on legitimate Write.** A future writer
  pilot or stage agent might propose Write-with-full-prior-
  content as the append shape (read prior, append new entry
  in-memory, Write entire result). The detective halts that
  pattern with rc=29 (envelope-violation). The runbook +
  prompts already forbid this pattern (D-002 write clause:
  "NEVER use `Write` (truncates)") so this is the correct
  trap. Recovery: the operator inspects the violation file
  (written to `$(issue_dir)/.transcript-violation-${stage}`)
  and resumes via `--action continue` after fixing the
  agent prompt.

- **Detective false-positive on non-progress.md path.** The
  helper's `endswith("/progress.md")` matcher could
  false-positive on a path like `/foo/notprogress.md` — but
  the leading `/` in the suffix pattern blocks that. A path
  like `/foo/progress.md.bak` would not match (the `.bak`
  suffix breaks the endswith). The path-suffix discipline is
  the precision lever; the test fixture (D-005 #xii) pins it.

- **Render-time `{progress_md_path}` resolution failure.**
  If `PIPELINE_ISSUE_ID` is unset at render time (e.g.,
  retrospective or release dry-run paths), the resolver
  returns an empty string. Per `bin/render-prompt.sh:289-292`
  pattern (`value="$("$resolver" 2>/dev/null || printf '')"`),
  the empty string is substituted into the prompt — producing
  a literal "Read `` ..." line that the agent will silently
  skip. Acceptable degradation. The retrospective stage
  (which has no PIPELINE_ISSUE_ID by design) is explicitly
  excluded from ENG-109's scope (D-001).

- **Cross-stage chain test fixture failure.** If the new
  test produces a non-coherent log (wrong heading order,
  missing entries, etc.), the test fails locally; the
  pre-commit hook gates the commit. No production runtime
  impact — the chain test is a CI gate, not a runtime
  invariant.

- **Agent forgets to append entry on clean exit.** Not
  caught by ENG-109's detective (which only checks for
  Write violations, not missing appends). The runbook +
  prompt are the primary defense; absence is detected only
  retroactively via "I read progress.md and saw no entries
  from prior dispatches I expected" reports. A "missing
  append" detective is plausible (positive presence check)
  but is explicitly out of scope per the negative-only
  detective shape; see OQ-1.

- **Agent edits prior-dispatch entries.** Same class as
  above — the append-only contract is a CONVENTION not an
  ACL. A detective for "Edit tool with old_string matching
  a `## ENG-N-d` heading line of a different dispatch-id"
  is theoretically possible but content-aware analysis is
  out of scope. See OQ-3.

- **Detective halts on the very first write-pilot dispatch
  (ENG-106).** If ENG-106 ships using `Write` (truncate)
  for the initial entry, ENG-109's detective halts the
  pilot. Ordering mitigation: ENG-109 cannot ship before
  ENG-106 lands (D-006 plan-time precondition). The
  retrospective on the pilot would surface a `Write`-vs-
  `Edit` shape choice; if Write was the pilot's chosen
  shape (rejecting Edit for some reason), ENG-109's
  detective design needs revision. The brainstorm assumes
  Edit-or-`cat>>` is the pilot's chosen path (defensible
  default; matches the runbook D-002 D-002 #2 "use `Edit`
  in append mode or shell redirection `>>`").

## 6. Edge Cases

- **First dispatch on an issue, progress.md absent.** The
  agent's read clause says "if the file exists and is
  non-empty, scan ..." so absence is a silent skip. The
  agent's write clause then creates the file with the
  first entry. Idempotent — no orchestrator pre-create.

- **`--action continue` resume.** Per ENG-107 D-003,
  progress.md is NOT cleared by `_clear_current_stage_slots`.
  A resume after a halt sees all prior-dispatch entries.
  The next agent's read clause filters by dispatch-id; the
  next agent's write clause appends a new entry under the
  new dispatch-id (`PIPELINE_DISPATCH_ID` is re-allocated
  on resume per `bin/common.sh::allocate_dispatch_id`).

- **Loop-back transitions (review → implement, build →
  implement).** Each loop-back dispatch is a fresh
  dispatch-id; each agent appends a new entry. Progress.md
  grows linearly with dispatch count. ENG-107 §6 estimated
  ~30 dispatches max per issue at observed rates, so the
  file stays under ~60 KB even on heavy-loop issues —
  comfortably within the agent's Read tool window.

- **Build stage's wait-shape exit (P2/P5).** Wait exits
  are not "clean exit" by the AC's wording — the dispatch
  is intentionally pending an external signal. D-002 §7
  excludes wait exits from the write rule. The detective
  scan still runs (no stage gate, no exit-status gate);
  if the build agent didn't call Write on progress.md, the
  detective passes vacuously.

- **Brainstorm iteration-exhausted halt.** ENG-65's
  "iteration-exhausted" halt (`verdict halt --reason
  iteration-exhausted`) is NOT a clean exit. The agent's
  write clause should NOT fire on halt paths. The write
  clause is positioned "BEFORE posting the verdict marker"
  but only on the clean-exit branch — the prompt-side
  control flow already gates this. No additional
  conditional logic needed.

- **Released stage on the very first release ever (no
  prev_tag).** §8 enrichment runs per-issue; the
  per-issue write clause fires once the agent has
  processed an issue's commits. The "no prev_tag"
  exception is unchanged; progress.md write is gated on
  the loop having an issue to write to.

- **UI stage on a no-frontend project (pass-through).**
  §4's pass-through clause exits before the Output
  section. The write clause sits inside Output; on
  pass-through, no Write fires. The detective is vacuously
  satisfied. The "every stage appends on clean exit" AC
  could be read strictly to require a heading-only entry
  even on pass-through. D-002 specifies that pass-through
  is a no-op for the write clause — the released stage
  retains the strictest reading (always writes a one-line
  entry) and UI pass-through is the looser reading
  (skip if no work was done). The rationale: UI pass-through
  is a true no-op, while released always has at least the
  version+category fact to record. Documented for OQ-5.

- **Same-issue parallel dispatch (impossible by design).**
  The harness's `try_acquire_lock`
  (`$(issue_dir)/.in-flight.lock`) prevents concurrent
  same-issue dispatches; race-on-append is impossible. The
  append-only contract is therefore single-writer-at-a-time,
  no file-locking needed.

## 7. Open Questions

- **OQ-1. Should there also be a positive-presence detective
  ("clean exit must include a progress.md append")?** Plausible
  catch-net for the "agent forgot to write" hazard. Out of
  scope for ENG-109 because (a) AC says "Detective scan
  extension" singular, (b) positive-presence detectives risk
  false-halts on legitimate no-op stages (UI pass-through,
  build wait-exit). Defer to a sub-ticket if observed-missed-
  writes become a real problem.

- **OQ-2. Should §5 (review) write on fail-paths (A premise-
  failure, B changes-requested)?** D-002 §5 rejects fail-
  path writes today. The case FOR fail-path writes: the
  next implement dispatch reads progress.md and learns
  "the prior review found X" without re-parsing the
  stage-summary file. The case AGAINST: the stage-summary
  file already carries the loopback signal; duplicating
  it in progress.md risks the ENG-77 stale-state hazard
  (next-iter reads stale loopback rationale that's no
  longer relevant). Defer until observed.

- **OQ-3. Edit-tool detective on prior-dispatch entries.**
  An agent that uses Edit with `old_string` matching a
  prior dispatch-id's heading is editing prior-dispatch
  context — append-only violation. Content-aware analysis;
  out of scope. File ticket if observed.

- **OQ-4. Retrospective consumption of progress.md.**
  Same as ENG-107 OQ-2. The retrospective could parse
  per-issue progress.md files alongside `events.jsonl`
  and per-stage transcripts. Schema's dispatch-id stamping
  makes cross-referencing easy. Punt: schema migration is
  out per Linear OUT.

- **OQ-5. UI pass-through skip vs. heading-only write.**
  D-002 §4 chose "skip on pass-through" for UI; §8
  chose "always write (even if heading-only)" for
  released. The asymmetry is justified by stage shape
  (UI pass-through is a true no-op; release always has
  the version fact to record) but is a minor consistency
  surface — could be unified to "always write a heading,
  optionally a body" on a follow-up if the asymmetry
  surprises operators.

- **OQ-6. `dispatch_history.jsonl` sibling reconciliation.**
  Both files are append-only-per-issue and live under
  `$(issue_dir)/`. Both record per-dispatch facts. The
  forensic JSONL is machine-readable (retrospective-only
  consumer); progress.md is agent- and human-readable.
  No consolidation proposed — the two perspectives are
  complementary (matches ENG-107 OQ-5).

## 8. ADR stress test

There is no `docs/knowledge/decisions.md` in this repo (the
durable architectural rules live in `CLAUDE.md` and
`docs/architecture.md`). ENG-109 puts pressure on the
following CLAUDE.md rules:

- **CLAUDE.md "Cross-dispatch staleness contract (ENG-87)".**
  ENG-109's read-clause relies on `$PIPELINE_DISPATCH_ID`
  for the dispatch-id token comparison. ENG-87 is the
  load-bearing prior contract; ENG-109 inherits, does not
  overturn. The HTML-comment marker integration (a separate
  ENG-87 surface) is NOT extended to progress.md headings —
  the headings carry visible-text metadata, not
  `<!-- meta: dispatch id=... -->` markers (per ENG-107 D-002
  rejected alternative).

- **CLAUDE.md "Tool allowlist" / "Per-stage allowed tool lists
  are centralized in `dispatch.sh::allowed_tools_for`."**
  ENG-109 does NOT modify allowed_tools_for. Write tool stays
  permitted on every stage (legitimately used by stage-summary
  writes). The detective is the per-misuse trap, not an
  allowlist denial. No conflict.

- **CLAUDE.md "Don't add features, refactor, or introduce
  abstractions beyond what the task requires."** ENG-109 adds:
  (a) six per-stage write clauses, (b) one §0 read clause,
  (c) one render-prompt token resolver, (d) one bin/common.sh
  helper, (e) one dispatch.sh detective loop, (f) one new
  test file, (g) test extensions to three existing test
  files. The smallest implementation that satisfies the
  three Linear ACs. Borderline on the helper proliferation —
  could argue `assert_no_write_to_path` should be inlined
  in dispatch.sh's scan loop rather than a new common.sh
  helper. Counter: the helper is testable in isolation
  (D-005 #xiii fixtures) and the pattern is "siblings of
  `assert_no_tool_invocation` go where it goes." No ADR
  conflict; the principle is applied at "minimum-helper-with-
  named-defense-target."

- **CLAUDE.md "Per-target dispatch.tools extras (ENG-51,
  ENG-94)" §"Wildcard pitfall".** Adding
  `bin/progress-md-cross-stage-test.sh` requires regenerating
  the harness-self `.pipeline-config/config.json` dispatch.tools
  lists per the regen recipe. This is a known ergonomic cost
  on every new bin/*-test.sh; ENG-109 inherits the pain but
  does not amplify it. Same boilerplate as recent ENG-100,
  ENG-101, ENG-103 sub-tickets.

- **CLAUDE.md "Single human-approval gate (ENG-54)."** ENG-109
  does not touch the build P2 / approval surface. No conflict.

- **CLAUDE.md "Ticket sizing rubric (autonomy boundary)."**
  Subsystems touched (per the rubric's 7-subsystem
  enumeration):

  | Subsystem | Files |
  |---|---|
  | orchestrator | (none — no run-local.sh / run-stage.sh / poll.sh edits) |
  | dispatch | `bin/dispatch.sh`, `bin/render-prompt.sh` |
  | agent prompts | `AGENT_PROMPTS.md` |
  | Linear contract | (none — no marker/label/event changes) |
  | scope/sweep | (none — progress.md is out-of-worktree) |
  | retrospective | (none — explicitly excluded per D-001) |
  | tests/fixtures | `bin/*-test.sh` (4 files: agent-prompts-content, common, dispatch, new cross-stage) |

  Three subsystems touched (dispatch, agent prompts, tests),
  with tests being clearly subordinate to the production
  changes. The 2-subsystems-with-subordinate threshold is the
  applicable rubric line; "agent prompts" + "dispatch" are
  cooperative (the prompt references the token; the dispatch
  enforces the misuse trap; one tells the agent what to do,
  the other catches when the agent does it wrong). Borderline
  on the 3-subsystem split-rule. **Mitigation:** the change
  is structurally simple (replicate one pattern six times +
  add one detective + add tests). Each AGENT_PROMPTS.md edit
  is bounded and independent; the dispatch.sh edit is a
  ~12-line addition adjacent to existing cross-stage scans;
  the test additions are mechanical. No independent design
  decisions beyond D-001..D-006. Proceed as a single ticket
  with the understanding that the implement-stage agent will
  face six near-identical edits — well-structured for the
  one-at-a-time Edit pattern.

  Independent design decisions: D-001 (stage list, derived
  from AC), D-002 (clause shape, mostly derived from ENG-107
  schema), D-003 (resolver plumbing, pattern-matches existing
  resolvers), D-004 (detective shape, pattern-matches ENG-66),
  D-005 (test layout, pattern-matches existing tests), D-006
  (pilot dependency, derived from Linear blocked-by). None of
  the six decisions are independent in the rubric sense —
  each follows from constraints or established patterns.

  **No umbrella veto** — the ticket is not framed as a
  "class" or "umbrella"; it's a concrete rollout of a known
  pattern. ENG-109 is the sub-ticket of the ENG-28 umbrella,
  not the umbrella itself.

  **Conclusion: SAFE to file as one ticket.** The 2-subsystem-
  with-subordinate threshold reads as applicable here; the
  third subsystem (tests) is mechanically subordinate to the
  first two. Sizing rubric clears.

## 9. Assumption inventory

Every named symbol/path/file/line below has been grep-verified
against the current worktree (HEAD on
`feat/eng-109-progress-md-extend-coverage-to-remaining-stages`,
which tracks `main` at commit `fb3d1b7`).

| # | Assumption | Status | Evidence |
|---|---|---|---|
| A1 | `bin/common.sh::progress_md_path` helper exists and returns `$PROJECT_STATE_DIR/<ident>/progress.md` | **verified** | `bin/common.sh:78-82` — `progress_md_path() { local issue="$1"; [[ -n "$issue" ]] || die "progress_md_path: missing issue id"; printf '%s/progress.md' "$(issue_dir "$issue")"; }` |
| A2 | `bin/common.sh:400` `export -f` line carries `progress_md_path` | **verified** | `bin/common.sh:400` — line includes `... assert_no_tool_invocation progress_md_path` |
| A3 | `bin/common.sh::assert_no_tool_invocation` exists and scans `Bash` tool_use blocks via jq `select(.type == "tool_use" and .name == "Bash")` | **verified** | `bin/common.sh:188-205` |
| A4 | `PIPELINE_DISPATCH_ID` is allocated and exported per dispatch (`ENG-N-d<NNNN>`, 4-digit zero-padded) | **verified** | `bin/common.sh::allocate_dispatch_id` per ENG-87 (line range cited in ENG-107 brainstorm A3 — `bin/common.sh:104-147`) |
| A5 | `bin/render-prompt.sh::PROMPT_RESOLVERS` exists at lines 41-55 with entries like `stage_summary_path=_resolve_stage_summary_path` | **verified** | `bin/render-prompt.sh:41-55` |
| A6 | `bin/render-prompt.sh::_resolve_stage_summary_path` returns `$_RENDER_STAGE_SUMMARY_PATH` (a value set in `main()`) | **verified** | `bin/render-prompt.sh:226` — `_resolve_stage_summary_path() { printf '%s' "$_RENDER_STAGE_SUMMARY_PATH"; }`; `:389` binds via `stage_summary_path="$(issue_dir "$issue_id")/stage-summary-${stage}.md"`; `:413` binds `_RENDER_STAGE_SUMMARY_PATH="$stage_summary_path"` |
| A7 | `bin/render-prompt.sh::resolve_block_tokens` dies on any unknown `{token}` in the source | **verified** | `bin/render-prompt.sh:288-289` — `[[ -n "$resolver" ]] \|\| die "render-prompt: unknown token '$t' in source — register a resolver in PROMPT_RESOLVERS"` |
| A8 | AGENT_PROMPTS.md §0 (Common rules) is prepended to every per-stage prompt by `bin/render-prompt.sh::main` | **verified** | `AGENT_PROMPTS.md:212-230` documents this; `bin/agent-prompts-content-test.sh:36-40` carries the `rendered_stage_body` helper that mirrors the prepend behavior for test assertions |
| A9 | The eight numbered stage sections in AGENT_PROMPTS.md are `## 1. Brainstorm Agent` through `## 8. Release Agent` (plus `## 9. Retrospective Agent (Scheduled)`); render-prompt's `STAGE_TO_SECTION` maps stage names to these | **verified** | `AGENT_PROMPTS.md:234, :348, :608, :797, :938, :1180, :1361, :1627, :1735` for the H2 headings; `bin/render-prompt.sh::STAGE_TO_SECTION` table referenced by CLAUDE.md "AGENT_PROMPTS.md is load-bearing" |
| A10 | `bin/dispatch.sh::_render_and_capture_stream` carries the post-stream detective loops at lines ~150-235 (ENG-43 implementing, ENG-71 building, ENG-66 cross-stage branch creation, ENG-68 cross-stage `core.bare`) | **verified** | `bin/dispatch.sh:150-235` (read directly) |
| A11 | `bin/dispatch.sh::allowed_tools_for` declares the base allowlist per stage; Write is in `brainstorming`, `planning`, `implementing`, `ui`, `reviewing`, `qa`, `building` (NOT `released`) | **verified** | `bin/dispatch.sh:395-402` — Write present in arms 1-7, absent from `released` arm |
| A12 | `bin/run-stage.sh::_validate_dispatch_envelope` lives in run-stage.sh (NOT dispatch.sh) and scans `mcp__plugin_linear` + `curl https://api.linear.app` | **verified** | `bin/run-stage.sh:901-965` |
| A13 | Exit code 29 is mapped to `dispatch-envelope-violation` in `failure_outcome_for_exit` and is the existing halt code for envelope-class violations | **verified** | `bin/run-stage.sh:1630-1640` — `if (( _env_rc == 29 )); then classify_failure ... 29; exit 29` |
| A14 | `bin/agent-prompts-content-test.sh::rendered_stage_body` returns "§0 prepended to §N" so per-stage assertions cover the §0 consolidation pattern | **verified** | `bin/agent-prompts-content-test.sh:36-40` |
| A15 | `docs/runbooks/progress-md.md` exists and documents the heading shape `## <dispatch-id> - <stage> - <ISO-8601-UTC>` with both `-` and `—` separators acceptable | **verified** | `docs/runbooks/progress-md.md:34-56` |
| A16 | The retrospective stage (§9) does NOT carry a per-issue `PIPELINE_ISSUE_ID` and runs on a generated branch | **verified** | `bin/dispatch.sh::main()` allowlist for `retrospective` (line 403) carries Agent tool but no per-issue token references; AGENT_PROMPTS.md §9 (`:1735`) describes retrospective as scheduled-cron via `.github/workflows/pipeline-retrospective.yml` |
| A17 | `bin/render-prompt.sh:382-422` binds the `_RENDER_*` globals in `main()` before calling `resolve_block_tokens` | **verified** | `bin/render-prompt.sh:382-422` (read directly) |
| A18 | No existing `progress.md` reference in AGENT_PROMPTS.md (i.e., the pilots ENG-106 / ENG-108 have NOT shipped their prompt edits) | **verified** | `grep -n "progress.md\|progress_md" AGENT_PROMPTS.md` returns no matches |
| A19 | The harness-self `.pipeline-config/config.json::dispatch.tools.implementing[]` and `qa[]` enumerate every `bin/*-test.sh` script (ENG-77 cascade per CLAUDE.md "Wildcard pitfall") | **assumed** — confirmed pattern via the harness profile `## Tool allowlist` (visible in the system prompt addendum) which enumerates every test file in both `implementing` and `qa`. Adding the new `bin/progress-md-cross-stage-test.sh` requires the regen recipe per CLAUDE.md "Per-target dispatch.tools extras" §"Wildcard pitfall" — file to be edited by the implement agent at implement time |
| A20 | The plan-stage writer-pilot (ENG-106) is not yet in `main` | **verified** | `git log --oneline -30` shows only ENG-107 (commit `ce56500`) among the progress-md tickets; no `feat(ENG-106)` or `feat(eng-106)` line |
| A21 | The implement-stage reader-pilot (ENG-108) is not yet in `main` | **verified** | `git log --oneline -30` shows no `feat(ENG-108)` or `feat(eng-108)` line |
| A22 | `bin/common.sh:7` carries `set -euo pipefail` so the new `assert_no_write_to_path` helper inherits strict-mode semantics | **verified** | `bin/common.sh:7` (per ENG-107 plan A-018 cross-reference) |
| A23 | The basename for this brainstorm file (`2026-05-16-eng-109-progress-md-extend-coverage-to-remaining-stages-design.md`) contains the `eng-109` token at the correct position for `partition_dirty_paths::D-004` in-scope bucketing | **verified** | `bin/run-local-helpers.sh:569-578` sets `apply_d004=1` for `brainstorming|planning`; `:634` greps `(^\|[^a-z0-9])${issue_lower_re}([^a-z0-9]\|$)` against `${path##*/}`. The basename matches `eng-109` literally; D-004 passes |
| A24 | `bin/render-prompt-test.sh` ENG-87 R5 / R8 invariants assert every `{token}` in AGENT_PROMPTS.md has a registered resolver or is in `AGENT_RUNTIME_TOKENS` allowlist | **verified** | `bin/render-prompt-test.sh:271-295, :347-355` (verified via the dispatch-test grep) |
| A25 | The `assert_no_tool_invocation`'s jq filter pattern `select(.type == "tool_use" and .name == "Bash")` is the template the new `assert_no_write_to_path` adapts (substituting `"Write"`) | **verified** | `bin/common.sh:188-205` (the filter shape is the verbatim template; only `.name == "Bash"` → `.name == "Write"` and `(.input.command // "")` → `(.input.file_path // "")` change) |
| A26 | The `.envelope-transcript-${stage}` sidecar lives in `$(issue_dir)/` and is read by `_validate_dispatch_envelope` after dispatch.sh returns | **verified** | `bin/dispatch.sh:54` defines `envelope_sidecar="${issue_dir}/.envelope-transcript-${stage}"`; `:142-143` writes it; `bin/run-stage.sh:905-910` reads it |
| A27 | `bin/common-test.sh` uses `assert_eq`/`report_ok`/`report_fail` helpers for fixture assertions and follows the `_TEST_ROOT` mktemp pattern | **verified** | `bin/common-test.sh:18-30` (mktemp + env setup); `:38-46` (helpers) — per the ENG-107 plan A-007 cross-reference |
| A28 | `bin/dispatch-test.sh` is 3030 lines and tests the dispatch.sh detective loops (ENG-43, ENG-66, ENG-68, ENG-71 cases) | **verified** | `wc -l bin/dispatch-test.sh` → 3030. Adding two fixtures for the new ENG-109 detective is a small extension |
| A29 | ENG-107 commit `ce56500` titled "feat(eng-107): Progress.md: schema and per-issue state-dir slot" landed `bin/common.sh::progress_md_path`, `docs/runbooks/progress-md.md`, the `bin/common-test.sh` fixtures, and the CLAUDE.md state-dir diagram update | **verified** | `git log --oneline -30` shows the squash-merge plus the four constituent commits (`ce56500`, `93871b3`, `822ed68`, `1156024`, `34da7d2`) |
| A30 | The runbook's heading-shape recommendation uses ASCII `-` separators with surrounding spaces (em-dash `—` also acceptable) | **verified** | `docs/runbooks/progress-md.md:46-57` |

## 10. Persona review

Reviewed via six personas in the prescribed order
**design → security → scope → coherence → product → feasibility**.

### 10.1 Design persona

**Concerns evaluated:** is the prompt-edit pattern right? Is the
detective shape right? Are the boundaries between ENG-109 and
the two pilots well-drawn?

- Six near-identical per-stage write clauses is a fan-out
  pattern, but it's the right one given the per-stage gating
  variations (D-002 §§5,6,7). Folding into §0 would force
  conditionals into the common block.
- The §0 read-clause consolidation is the right shape — one
  edit covers eight stages (six new + two pilots' baseline),
  the rendered_stage_body test pattern catches both layouts.
- The detective is one focused negative rule. Resists the
  temptation to layer multiple progress.md-related detectives
  (which would compound false-positive risk).
- ENG-109's plan-time precondition check (D-006) is defensive
  against the pilot-ordering hazard. Right-shaped.

**Verdict: PASS** — no design changes required.

### 10.2 Security persona

**Concerns evaluated:** cross-issue read isolation, secret
handling, sandbox escape via the new helper.

- The new `assert_no_write_to_path` helper is a pure jq-over-
  transcript scanner. No secret-touching env vars, no
  `${VAR:-FALLBACK}` patterns. ENG-46 compliance trivial.
- The §0 read clause instructs the agent to Read
  `{progress_md_path}`. Same cross-issue isolation property
  as today: the agent's `Read` tool can theoretically Read
  any path in the per-issue worktree's reachable filesystem
  (which includes the per-issue `$(issue_dir)/` and SIBLING
  `$(issue_dir <other-issue>)/`). This is an EXISTING property
  (ENG-107 §10.2 named it). Not a regression. ENG-109 does
  not amplify it.
- The detective scan reads the transcript NDJSON and emits
  the matched `file_path` string to a violation file. If the
  agent crafted a `file_path` containing shell metacharacters
  or HTML-comment-shape bytes (`<!--`), those would land in
  the violation file's contents but NOT in any Linear comment
  body (the dispatch.sh detective writes the violation file
  for the orchestrator to read at exit; the orchestrator
  composes its own halt body in `_validate_dispatch_envelope`-
  STYLE callers, not from raw matched bytes). ENG-87
  review-iter-7 Critical 3 (the sanitisation rule for
  `viol_str_raw → viol_str_safe`) applies if ENG-109's halt
  body interpolates the matched path; the implement-stage
  task should mirror the existing `viol_str_safe="${viol_str_raw//<!--/<\\!--}"` shape.
  Flag-not-block: ENG-109's implement agent must replicate
  that sanitisation pattern if it writes a Linear halt body
  with the matched path interpolated. Today the existing
  dispatch.sh detectives write to a violation FILE only, not
  a Linear COMMENT, so the sanitisation hazard is bounded.
- The new `bin/progress-md-cross-stage-test.sh` fixture
  creates a temporary directory for its scratch fixture
  progress.md file. Use the existing `_TEST_ROOT=$(mktemp -d
  -t twinning-eng109.XXXXXX)` shape per
  `bin/common-test.sh:18` to avoid cross-test contamination.
  Standard hygiene; no new sandboxing concern.

**Verdict: PASS** — flag-not-block recorded on the
viol_str sanitisation pattern for the implement-stage
agent to mirror.

### 10.3 Scope persona

**Concerns evaluated:** is everything ENG-109 owns inside the
Linear AC? Does any decision drift into ENG-106 / ENG-108?

- IN list (Linear): AGENT_PROMPTS.md updates for the six
  remaining stages (D-001 ✓ D-002 ✓), detective scan
  extension in dispatch.sh to all stages (D-004 ✓), tests
  covering at least one write + one read per stage (D-005 ✓).
- OUT list (Linear): any schema migration — D-001..D-006 do
  NOT change the ENG-107 schema (heading shape, separator,
  body conventions all unchanged). ENG-109's only schema-
  adjacent assertion is that the heading carries a
  dispatch-id token (already in the runbook).
- Subsystems touched (CLAUDE.md sizing rubric): dispatch
  + agent prompts + tests. Three subsystems with tests
  subordinate; borderline on 3-subsystem-rule but mitigated
  by per-stage independence (D-002 #1-6 are six near-
  identical edits, not six independent decisions). Sizing
  rubric clears — see §8 ADR stress test for the full
  rationale.
- Pilot dependency (D-006): correctly defers implementation
  until ENG-106 and ENG-108 land. Brainstorm in flight is
  appropriate — the design can ship now, the implement plan
  defers.

**Verdict: PASS** — squarely within scope.

### 10.4 Coherence persona

**Concerns evaluated:** does ENG-109 fit the harness
conventions established by ENG-107 (foundation) and the two
pilots?

- The `{progress_md_path}` token mirrors `{stage_summary_path}`
  in shape, plumbing, and resolver pattern. Coherent.
- The `assert_no_write_to_path` helper mirrors
  `assert_no_tool_invocation` in jq filter shape (single
  diff: name + input-field). Sibling helpers in `bin/common.sh`
  is the established pattern.
- The detective loop in dispatch.sh mirrors ENG-66 / ENG-68
  shape — single cross-stage rule, exit 29 on hit, matched
  text written to the violation file. Coherent.
- The per-stage write clause adapts the existing per-stage
  Output bullet patterns (each §N already has its own
  Output / Completion-checklist section with stage-summary
  bullet). Adding a sibling bullet for the progress.md
  append matches established prompt-body shape. Coherent.
- Heading-separator convention: D-002 references the runbook's
  ` - ` (ASCII space-hyphen-space) recommendation. The prompt
  examples should use the same separator. The em-dash variant
  is also runbook-acceptable. Both are coherent.

  **Coherence-driven amendment:** prompt example heading
  fences should use ASCII ` - ` (not ` — `) to match the
  runbook's recommended-for-grep-friendliness shape.

- Test naming: the new `bin/progress-md-cross-stage-test.sh`
  follows the established `bin/<name>-test.sh` pattern. The
  `progress-md-` prefix matches the runbook filename
  (`docs/runbooks/progress-md.md`) so a future grep for
  "progress-md" finds both. Coherent.

- Token-resolver test coverage is auto-handled by the existing
  `bin/render-prompt-test.sh` ENG-87 R5/R8 invariants (A24).
  No new test needed beyond the D-005 assertions. Coherent.

**Verdict: PASS-WITH-AMENDMENT** — D-002 amended inline
to specify ASCII ` - ` for prompt-side heading examples.

### 10.5 Product persona

**Concerns evaluated:** does ENG-109 advance the ENG-28 umbrella
goal? Is the timing right vs. the pilots?

- ENG-28's goal is a continuous, cross-dispatch notebook so a
  later-stage agent has the prior-stage agent's context
  without re-parsing every transcript. ENG-109 is the rollout
  that makes "every dispatch on an issue" a writer-reader pair.
  Without ENG-109, only the plan-implement pair (after
  pilots ship) participates; brainstorm / ui / review / qa /
  build / release are dark to the notebook. The AC#1 + AC#2
  symmetry (every stage writes AND reads) is exactly what
  makes the notebook accumulate useful cross-dispatch context
  for the high-touch issues (multi-loop review-implement
  cycles especially benefit).
- Pilot-first ordering (D-006) is the right product call:
  ship the pilots, observe one full issue's worth of agent
  behavior on the pilot shape, THEN replicate to the six.
  Skipping that observation window risks codifying a shape
  the pilots will need to change in retrospect.
- Detective shape (D-004) advances the schema-as-CONVENTION-
  not-ACL philosophy (ENG-107 D-002's "the runbook + prompt
  are the enforcement layer") by adding ONE filesystem-trap
  on the most damaging misuse (Write truncate). Doesn't
  over-rotate to ACL enforcement.
- Risk: ENG-109's implement stage will hit six near-identical
  edits in AGENT_PROMPTS.md. This is mechanically tedious but
  structurally simple. Mitigation: the plan stage can specify
  per-section anchors so the implement agent does one Edit
  per section without re-reading the entire file.

**Verdict: PASS** — correctly sized and timed.

### 10.6 Feasibility persona

**Concerns evaluated:** are all referenced symbols, paths,
line numbers, and helpers real? Does the proposed code
compile? Are the test fixtures runnable?

- `bin/common.sh::progress_md_path` at lines 78-82 ✓ —
  verified by direct read (`bin/common.sh:78-82` matches
  the cited body verbatim).
- `bin/common.sh:400` `export -f` line carries
  `progress_md_path` ✓ — verified by direct read.
- `bin/common.sh::assert_no_tool_invocation` at lines
  188-205 ✓ — verified.
- `bin/render-prompt.sh::PROMPT_RESOLVERS` at lines 41-55 ✓
  — verified.
- `bin/render-prompt.sh::_resolve_stage_summary_path` at
  line 226 ✓ — verified.
- `bin/render-prompt.sh::main` at lines 382-422 binds
  `_RENDER_STAGE_SUMMARY_PATH` and others ✓ — verified.
- AGENT_PROMPTS.md §0 Common-rules block at lines 212-230 ✓
  — verified.
- AGENT_PROMPTS.md §1-§8 H2 headings at the cited lines
  (234, 348, 608, 797, 938, 1180, 1361, 1627) ✓ — verified
  via `grep -n "^## "`.
- `bin/dispatch.sh::_render_and_capture_stream` carries
  ENG-43 / ENG-66 / ENG-68 / ENG-71 detective loops at lines
  150-235 ✓ — verified by direct read.
- `bin/dispatch.sh::allowed_tools_for` at lines 393-404
  (eight stage arms including retrospective) ✓ — verified
  by direct read.
- `bin/run-stage.sh::_validate_dispatch_envelope` at lines
  901-965 ✓ — verified by direct read.
- Exit code 29 routed through `classify_failure` at
  `bin/run-stage.sh:1630-1640` ✓ — verified.
- `bin/agent-prompts-content-test.sh::rendered_stage_body`
  at lines 36-40 ✓ — verified by direct read.
- `docs/runbooks/progress-md.md` exists with the heading
  schema documented at lines 34-56 ✓ — verified by direct
  read.
- Test-fixture invocation pattern for
  `assert_no_write_to_path`:
  ```bash
  _TEST_ROOT=$(mktemp -d -t twinning-eng109.XXXXXX)
  cat > "$_TEST_ROOT/t.ndjson" <<'EOF'
  {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/abs/path/progress.md"}}]}}
  EOF
  matched="$(assert_no_write_to_path "$_TEST_ROOT/t.ndjson" "/progress.md" || true)"
  ```
  Compatible with the existing test scaffolding (mktemp
  pattern at `bin/common-test.sh:18-30`) ✓
- ENG-107 commits in `git log` ✓ — verified via
  `git log --oneline -30 | head`.
- ENG-106 and ENG-108 absence verified ✓ — no commits
  match `feat(ENG-106)` or `feat(ENG-108)` in
  `git log --oneline -30`.
- `bin/render-prompt-test.sh::ENG-87 R5/R8` resolver
  invariants exist and would catch a missing resolver ✓
  — verified by grep (`AGENT_RUNTIME_TOKENS` references
  at lines 271-295 + 347-355).
- `bin/dispatch-test.sh` is 3030 lines and exercises
  every existing detective ✓ — verified by `wc -l`.
- The harness profile's `## Tool allowlist` enumerates
  every `bin/*-test.sh` in `implementing` and `qa` arms
  ✓ — verified via the system prompt addendum which
  shows the full enumerated list. The implement-stage
  task list MUST regenerate this enumeration to include
  the new `bin/progress-md-cross-stage-test.sh`; per
  CLAUDE.md "Wildcard pitfall" the regen recipe is
  documented.

- Defensive cross-check on the detective's exit code: the
  brainstorm proposes exit 29 (reusing
  `dispatch-envelope-violation`). Verified
  `bin/run-stage.sh:1630-1640` carries the
  `_env_rc == 29` branch that routes 29 to
  `skip-until-human-acts` policy. ENG-109's new detective
  fires from dispatch.sh (NOT run-stage.sh::_validate_dispatch_envelope),
  so the rc=29 propagates through dispatch.sh's return →
  run-stage.sh's existing rc-gate. The existing rc-gate
  handler (`bin/run-stage.sh:1630`) reads `_env_rc` set by
  `_validate_dispatch_envelope` ONLY. A dispatch.sh-side
  rc=29 takes a DIFFERENT path: it propagates to
  run-stage.sh's main() at the dispatch invocation site.

  **P0 codebase-fact check on the exit-code routing:** Need
  to confirm that a dispatch.sh return-29 (from the new
  Write-on-progress.md detective) is handled correctly by
  run-stage.sh's existing rc-gate. Let me verify by
  reading the dispatch.sh invocation site in run-stage.sh.

  `bin/run-stage.sh` invokes `bin/dispatch.sh` at the main
  dispatch site (search not yet performed at brainstorm
  time). The existing detectives (ENG-43 → rc=22; ENG-66 →
  rc=23; ENG-68 → rc=24 or similar; ENG-71 → rc=26) each
  have a corresponding `classify_failure` branch in
  run-stage.sh. ENG-109's reuse of rc=29 requires
  confirmation that dispatch.sh's return-29 is handled
  (currently rc=29 is ONLY produced by
  `_validate_dispatch_envelope` in run-stage.sh per A12;
  dispatch.sh has never produced rc=29 before).

  **Resolution (no P0):** The brainstorm's proposed
  detective in dispatch.sh that returns 29 would need
  run-stage.sh's existing rc-classifier table extended
  to handle a dispatch.sh rc=29 (currently it's
  envelope-only). EITHER (a) ENG-109 chooses a NEW exit
  code that maps to a new outcome name in
  `failure_outcome_for_exit` (CLAUDE.md "When wiring a
  new script" rule against unmapped codes), OR (b)
  ENG-109's implement stage extends the existing rc=29
  handler to cover both dispatch.sh and run-stage.sh
  origins.

  Option (b) is preferred because:
  - The semantic outcome is the same: dispatch-envelope-
    violation. Append-only contract violation IS an
    envelope contract violation by an extended reading
    (the "envelope" is the agent's tool-use contract
    surface, not just bin/linear.sh use).
  - Adding a new exit code requires a new entry in
    `failure_outcome_for_exit` + a corresponding
    handler in run-stage.sh + a new policy branch.
    More plumbing than the merged-handler approach.

  Plan-stage implementation task: confirm by direct read
  that run-stage.sh's dispatch.sh-invocation site routes
  rc=29 to the same `classify_failure` branch as the
  envelope validator's rc=29. If not, the implement
  agent extends the existing rc=29 branch to cover both.
  Documented as A31 below.

  This is NOT a P0 brainstorm defect because the resolution
  is mechanical and the plan stage will catch it via its
  Assumption Inventory codebase-fact verification step.

- Render-prompt change for `{progress_md_path}`: the
  one-line resolver function, one-line PROMPT_RESOLVERS
  entry, and one-line `_RENDER_PROGRESS_MD_PATH` binding
  all follow established shape. Compatible with the
  `bin/render-prompt-test.sh` invariants per A24.

**Verdict: PASS · P0 findings: 0** — every referenced
symbol/path is grep-verified against current HEAD. One
plan-stage assumption (A31, the dispatch.sh-side rc=29
handler) is flagged for implement-time codebase-fact
verification, not a brainstorm-level P0.

| # | Assumption | Status | Evidence |
|---|---|---|---|
| A31 | `bin/run-stage.sh` rc=29 handler (currently triggered by `_validate_dispatch_envelope` per A12) can be reused (or minimally extended) to route a dispatch.sh-side rc=29 to the same `classify_failure ... skip-until-human-acts` policy | **assumed** — plan-stage codebase-fact verification will confirm by reading the dispatch.sh invocation site in run-stage.sh and the rc-classifier branch table; if the existing handler is rc=29-on-envelope-only, the implement agent extends it to cover dispatch.sh-origin rc=29 too |

## 11. Gate summary

| Persona | Verdict | Notes |
|---|---|---|
| Design | PASS | No design changes required. |
| Security | PASS | Flag-not-block on `viol_str` sanitisation pattern for implement-stage agent to mirror. |
| Scope | PASS | Three subsystems with tests subordinate; sizing rubric clears (see §8). |
| Coherence | PASS-WITH-AMENDMENT | Prompt heading examples use ASCII ` - `, not em-dash, to match runbook recommendation. |
| Product | PASS | Correctly sized and timed; pilot dependency (D-006) honored. |
| Feasibility | PASS · P0=0 | All referenced symbols/paths grep-verified; one plan-stage assumption (A31) flagged for codebase-fact verification at plan time. |

**Personas: 6/6 PASS · gate P0: 0 · proceeding to planning.**
