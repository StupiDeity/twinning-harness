---
linear: ENG-XX
title: cross-dispatch staleness — hard hand-off contract via per-dispatch identifier and per-medium primitives
date: 2026-05-09
status: draft
---

# Hard hand-off contract — eliminate cross-dispatch staleness via `dispatch_id` glue + per-medium primitives

> **Linear ID is a placeholder.** Filename uses today's date; bind to the
> next available ENG-N before this doc enters reconcile.sh's canonical-doc
> path (per CLAUDE.md "Linear conventions" §, doc-to-issue ownership is
> the YAML `linear: ENG-N` line). Cross-references to this doc from
> follow-on plans should pin the assigned ENG-N once allocated.

## 1. Problem

The harness has been bitten — repeatedly, in shapes that initially looked
unrelated — by one structural failure class: **a dispatch reads data
that was written by a PRIOR dispatch as if it's current.** Each instance
manifested differently because the harness moves data between dispatches
across four media with different persistence semantics, and the prior
fixes addressed each medium in isolation. This design names the class
and lands a unified contract.

### 1.1 Observed instances of the class

| Ticket | Medium that went stale | Symptom | Prior fix layer |
|---|---|---|---|
| ENG-77 (May 2026) | Per-issue local file (`stage-summary-reviewing.md`) | Review iters 6–9 emitted fresh `verdict fail` markers but did not rewrite the stage-summary file; orchestrator's `post_completion_comment` posted iter-5 body to Linear; implement on loopback read iter-5 body; 9-iteration cycle, ~$50, 2 manual interventions | D-001 §5-only prompt rule + D-002 content test (shipped as `bd8ca2d`) |
| ENG-41 §1.1 (Apr 2026) | Linear comment freshness window | UI agent forged a `<!-- pipeline-transition: ui → reviewing -->` comment mid-run; orchestrator's `find_fresh_verdict` computed freshness from the latest `pipeline-transition` comment (now agent-authored); legitimate ui done-marker filtered out as "older"; protocol-violation halt | ENG-41 §4.1 lane fence + §4.2 cross-check (designed; not yet shipped) |
| ENG-41 §1.2 (Apr 2026) | Linear comment freshness window | After manual reset of ENG-24, a 2-day-old `pipeline-transition: planning → implementing` comment was selected as "in-progress"; `resume_in_progress_transition` had no upper bound on transition-comment age; brainstorm/implement label tug-of-war loop | ENG-41 §4.2 cross-check (designed; not yet shipped) |
| ENG-78 (May 2026) | Linear label state | `classify_failure` unconditionally adds `pipeline:halted` even on `policy=retry-immediately` exits; `poll.sh` then skips the issue; the retry never happens; `retry-immediately`'s "next tick re-dispatches" contract silently broken | (in flight; brainstorm written) |
| ENG-79 (May 2026) | Prompt token interpolation | `render-prompt.sh:212` hand-rolled `branch_name="feature/${issue_id_lower}-${slug}"` — drifted from canonical `bin/branch-name.sh`'s `feat/...` shape; ENG-67 cleanup of legacy `feature/*` coexistence path exposed the drift; build-stage agents emitted `agent-blocked` halts because `gh pr list --head feature/eng-N-…` returned empty against a canonical `feat/...` PR | ENG-79 single-resolver fix (shipped — `render-prompt.sh:222` calls `bin/branch-name.sh`) |
| ENG-67 (May 2026) | Per-issue worktree path | `run-local.sh:213-226` carried a "legacy `feature/*` coexistence" branch that silently dispatched into the operator's `$TARGET_REPO` checkout when the canonical worktree was missing; agents ran on the operator's HEAD instead of a per-issue worktree; cross-issue write contamination | ENG-67 D-003 invariant (`die`-on-empty-worktree-path) — shipped |

Six instances; one class. The pattern in every case:

1. The orchestrator OR the agent persisted data during dispatch N.
2. Dispatch N+1 read that data.
3. Either (a) the data was supposed to have been overwritten in N+1 but wasn't (stage-summary file, branch-name interpolation), or (b) the data was supposed to be filtered out as "from N, not N+1" but wasn't (Linear comment freshness window, halt label, transition marker).

### 1.2 Why prior fixes didn't generalize

Each prior fix targeted one medium with that medium's natural primitive:

- ENG-77 D-001: prompt-rule mandate at agent layer → fixes ONE stage's stage-summary file behavior.
- ENG-41 §4.1: lane-fence at `linear.sh` chokepoint → fixes label-write authorship.
- ENG-79: canonical resolver call in `render-prompt.sh` → fixes ONE prompt token's source-of-truth.
- ENG-67: invariant `die` on missing worktree → fixes worktree-path freshness.

The fixes are correct in isolation. None of them gives a future operator
a way to ANSWER the question "which dispatch wrote this artifact?" at
read time — and that question is precisely the one every instance of
the class collapses to. Without a per-dispatch identifier, freshness has
to be reconstructed from secondary signals (timestamps, mtime, label
state, comment ordering); secondary signals are exactly what each
incident exploited.

The system documents on `bin/run-stage.sh:497-499` the rationale that
should generalize but doesn't:

```bash
# Clear any stale stage-summary file so a later post_completion_comment
# cannot post stale content from a prior dispatch.
rm -f "$(issue_dir "$ident")/stage-summary-${stage}.md" 2>/dev/null || true
```

That comment is in `_handle_wait` (verified at `bin/run-stage.sh:495-499`),
applied only to the wait-exit path. Build (§7) is the only stage that
exercises wait-exit, which is why ENG-77 §6 named build as "structurally
immune." The reasoning ("don't post stale content from a prior dispatch")
is the design we want; the scope is wrong.

### 1.3 Common root cause

**The harness has no per-dispatch identifier.** Every cross-dispatch
read therefore depends on secondary inference: file mtime, append-only
comment ordering, label state, prompt-token textual equality. Each
secondary signal has a known failure mode, and one or more of those
failure modes has fired in production for each medium.

## 2. Goal

The orchestrator and agent can rely on five invariants:

1. **G-1 (allocation).** Every dispatch (one `claude -p` invocation
   against one (issue, stage) pair) has a unique, orchestrator-allocated
   `dispatch_id` of the form `ENG-N-d<NNNN>`, monotonic per issue,
   persisted in `issue-state.json` before dispatch starts.
2. **G-2 (no-stale-file).** When a stage's dispatch begins, the
   stage's own per-issue local files (`stage-summary-<stage>.md`,
   `wait-<stage>.json`) do not exist. Their existence at envelope
   validation time is proof of THIS-dispatch authorship.
3. **G-3 (linear-comment-stamp).** Every Linear comment written
   during a dispatch carries the current `dispatch_id` in a structured
   marker, auto-injected at the `bin/linear.sh` chokepoint. Readers
   filter by id rather than by timestamp.
4. **G-4 (prompt-token-canonical).** Every `{token}` in
   `AGENT_PROMPTS.md` is resolved at render time by a registered
   canonical resolver. An unknown token (typo, drift, fork) fails
   render-time loudly. ENG-79's branch-name fix becomes the general
   case.
5. **G-5 (envelope-validation).** The orchestrator's post-dispatch
   detective check confirms (a) stage-summary file exists post-dispatch
   (covered by existing rc=25), (b) every Linear comment posted under
   sigs scoped to (issue, current_stage) during this dispatch carries
   the current `dispatch_id` marker (cross-check via
   `linear.sh list-comments`), (c) no Linear write happened outside
   `bin/linear.sh` (transcript scan, per CLAUDE.md "Defense-in-depth
   on top of tool-lane denials" §). Halt with structured reason on
   any violation.

## 3. Non-goals

- **Schema'd typed envelopes.** ENG-77 D-005's typed-findings channel
  stays deferred under its existing un-deferral conditions. This
  contract is freshness-only; content-shape stays prose. (D-008.)
- **Backporting `dispatch_id` to in-flight issues.** Reader fallback
  to timestamp-window applies when no dispatch_id markers exist on
  the issue (legacy state). Fallback expires the first time the
  orchestrator dispatches the issue post-cutover. No data migration.
- **A whole-issue lock spanning poll → dispatch → verdict_handler.**
  Existing `.claude-mutex.lock/` is sufficient; the contract relies on
  serialized dispatch (already true). Whole-issue lock stays deferred
  per ENG-41 §12.
- **Cycle-id stamping on log files / forensic-only artifacts.** Logs
  get `[dispatch=ENG-N-d014]` prefixed for searchability; no validator
  runs on log content.
- **Replacing ENG-41's lane fence.** This design DEPENDS ON the lane
  fence being shipped (orchestrator-only label/comment authorship is
  what makes the dispatch_id contract trustworthy). Ship lane fence
  first or together; this design assumes it's in place.
- **Replacing ENG-77 D-001's already-shipped §5 prompt rule.**
  The rule remains; this design GENERALIZES it via clear-on-start
  (un-defers ENG-77 D-003's §3/§4 conditions structurally, removing
  the rationale for the per-stage prompt edits the un-deferral would
  have proposed).

## 4. Architecture

The contract has one glue and four per-medium mechanisms.

### 4.1 The glue: `dispatch_id`

`dispatch_id` is the freshness primitive across every cross-dispatch
read. Its lifecycle:

```
T0  run-stage.sh::main entry (poll has selected (issue, stage))
     │
     ├─ allocate_dispatch_id "$issue":
     │    seq = $(jq -r '.current_dispatch_seq // 0' issue-state.json) + 1
     │    write seq back atomically (via tmpfile + mv)
     │    PIPELINE_DISPATCH_ID="$issue-d$(printf '%04d' "$seq")"
     │    export PIPELINE_DISPATCH_ID
     │    append to dispatch_history.jsonl: {id, stage, started_at}
     │
     ├─ _clear_current_stage_slots "$issue" "$stage":
     │    rm -f stage-summary-${stage}.md
     │    rm -f wait-${stage}.json
     │    (other stages' files left untouched — needed for forward+loopback reads)
     │
     ├─ render-prompt.sh:
     │    every {token} resolved via PROMPT_RESOLVERS registry
     │    {dispatch_id} interpolates from $PIPELINE_DISPATCH_ID
     │    render-time validator: every interpolated token came from a registered resolver
     │
     ├─ dispatch.sh:
     │    env block to claude -p includes PIPELINE_DISPATCH_ID, PIPELINE_WRITER=agent, PIPELINE_STAGE=$stage
     │    subshell agents that call bin/linear.sh inherit the env naturally
     │
     ├─ [agent runs claude -p]
     │    every bash bin/linear.sh add-comment auto-injects
     │      <!-- meta: dispatch id=$PIPELINE_DISPATCH_ID stage=$PIPELINE_STAGE -->
     │    every bash bin/linear.sh add-or-update-comment same
     │
     ├─ [post-dispatch in run-stage.sh]
     │    _validate_dispatch_envelope "$issue" "$stage":
     │      check stage-summary file exists (existing rc=25 path on missing)
     │      list comments posted this dispatch (filter: dispatch_id=$current AND stage=$current)
     │      assert each has the auto-injected marker (sanity — bypass detection)
     │      transcript scan: no Linear write outside bin/linear.sh
     │    on violation: pipeline.sh event verdict halt --reason dispatch-envelope-violation
     │
     ├─ append to dispatch_history.jsonl: {id, exit_code, exit_at}
     │
     └─ verdict_handler picks up; routes via dispatch_id-filtered marker reads
```

### 4.2 The four per-medium mechanisms

Each medium gets the cheapest primitive that achieves G-2 through G-5
for that medium's persistence semantics. The primitives are NOT
forced into a single mechanism — that would over-engineer some media
and under-fit others.

| Medium | Persistence | Preventive | Detective | LOC |
|---|---|---|---|---|
| Per-issue local files | mutable, local FS | **G-2: clear-at-dispatch-start** for current-stage files (extend `run-stage.sh:495-499`'s wait-exit pattern). After clear, file existence at envelope time = THIS-dispatch authorship. | Existing rc=25 (`summary_missing`) at `run-stage.sh:977-989`; covers "agent didn't write at all" loud-fail. | +20 |
| Linear comments | append-only, remote | **G-3: auto-injection** in `bin/linear.sh::add_comment` and `add_or_update_comment` (lines 470, 541). Every comment body carries `<!-- meta: dispatch id=… stage=… -->`. | Cross-check via `linear.sh list-comments` filtered to current dispatch's writes; assert each has the marker. Transcript scan asserts no Linear write outside `linear.sh`. | +25 |
| Linear labels | mutable, remote | **lane fence** (ENG-41 §4.1, dependency). Already designed; orchestrator-only authority. dispatch_id contributes nothing here — labels are mutable, not append-only, and the lane fence already prevents agent forgery. | Cross-check in `resume_in_progress_transition` (ENG-41 §4.2) — strengthened by dispatch_id (see §4.3 below). | (cross-ref ENG-41) |
| Prompt tokens | re-rendered each dispatch | **G-4: canonical resolver registry** in `render-prompt.sh`. `{token}` → resolver function map; resolver is the source of truth. ENG-79's `branch_name`-via-`bin/branch-name.sh` becomes the general case. | Render-time validator: any `{token}` in the source not in `PROMPT_RESOLVERS` → `die`. Content test in `bin/agent-prompts-content-test.sh`: assert every `{…}` token in `AGENT_PROMPTS.md` appears in the registry. | +50 |

### 4.3 How the dispatch_id strengthens ENG-41's planned §4.2 cross-check

ENG-41's `resume_in_progress_transition` cross-check was designed
around `current_stage != from` and "multiple `stage:*` labels →
abort." Both are correct backstops, but they reason about secondary
signals (label state, comment text). With dispatch_id, the cross-check
becomes a single equality:

```bash
# ENG-41 §4.2 (planned):
#   if current_stage != to: return 1   # already at destination
#   if current_stage != from: return 1 # comment is stale or forged (NEW guard)
#   if len(stage:* labels) > 1: return 1 # malformed (NEW guard)
#   if has_label pipeline:halted: apply_transition; return 0

# This design (replaces / augments):
#   parse last_transition: extract dispatch_id_in_marker
#   if dispatch_id_in_marker != current_dispatch_id: return 1  # stale by id
#   (otherwise existing checks still apply)
```

dispatch_id is monotonic per issue; a transition marker from a prior
cycle cannot have an id ≥ current. The dispatch_id check is strictly
stronger than the timestamp window AND strictly stronger than the
labels-cross-check, because (a) it doesn't rely on clock skew or
timestamp-comment ordering, and (b) it doesn't rely on the labels
having been kept consistent.

The design SHIPS BOTH: dispatch_id check is primary; ENG-41's
labels-cross-check stays as backstop for in-flight legacy issues
where dispatch_id markers aren't yet present (during the cutover
window).

### 4.4 The extensibility shape

A new artifact type added in a future ticket joins the contract by
choosing one of three mechanisms based on the artifact's persistence:

- Local FS, mutable, single-writer-per-dispatch → register in
  `_clear_current_stage_slots`'s clear-list. (e.g., a future
  `transcript-summary-<stage>.json`.)
- Linear comment → no work needed; auto-injection is universal.
- Prompt token → register in `PROMPT_RESOLVERS`.

A new stage joins the contract automatically: `_clear_current_stage_slots`
takes the current stage as a parameter and clears its files; the
auto-injection at `linear.sh` is stage-agnostic; the resolver registry
is stage-agnostic.

A new medium (a future cache file shared across issues, an external
dashboard) requires (a) deciding its primitive (clear / stamp /
re-render), (b) wiring it into the appropriate layer. The contract's
shape gives the designer a forced choice from a small menu rather
than a blank slate.

## 5. Components

### 5.1 The dispatch_id glue

| File | Change | LOC |
|---|---|---|
| `bin/common.sh` | New `allocate_dispatch_id <issue>` (atomic increment, exports `PIPELINE_DISPATCH_ID`); `current_dispatch_id <issue>` (read-only). Exported alongside existing `issue_dir`/`compute_pipeline_content_hash` family. | +40 |
| `bin/dispatch.sh` | Inherit `PIPELINE_DISPATCH_ID` and `PIPELINE_STAGE` into the env block passed to `claude -p`. | +2 |
| `bin/run-stage.sh` | Allocate dispatch_id at start of `main`; persist to `dispatch_history.jsonl` with `started_at`; append `exit_code, exit_at` after dispatch returns. Skip allocation on scope-approval replay (`skip_dispatch=1`). | +30 |
| `bin/pipeline-events.json` | Add `dispatch` to `meta_kinds`; add `dispatch-envelope-violation` to `halt_reasons`. | +2 |
| `docs/pipeline-vocabulary.md` | Auto-regenerated via `bin/generate-vocabulary-doc.sh`. | (gen) |
| `bin/common.sh::failure_outcome_for_exit` | Add new exit code for `envelope-violation` (next free, e.g. 13) so retrospective §1 filter recognizes it. | +2 |

### 5.2 Per-medium mechanisms

| File | Change | LOC |
|---|---|---|
| `bin/run-stage.sh` (clear-on-start) | New `_clear_current_stage_slots <issue> <stage>`; called at dispatch start. Generalizes the wait-exit pattern from line 497-499 to all stages. | +20 |
| `bin/linear.sh` (auto-injection) | In `add_comment` (line 470) and `add_or_update_comment` (line 541): if `$PIPELINE_DISPATCH_ID` is set and the body doesn't already contain a `<!-- meta: dispatch ... -->` marker, append `<!-- meta: dispatch id=$PIPELINE_DISPATCH_ID stage=$PIPELINE_STAGE -->` before the existing dedup footer. | +25 |
| `bin/verdict-handler.sh` (reader filter) | `find_fresh_verdict`: filter to comments whose dispatch_id marker matches current. Fallback to timestamp window when no dispatch_id present anywhere on the issue (legacy). `resume_in_progress_transition`: dispatch_id mismatch → return 1 (primary); ENG-41's labels-cross-check stays as secondary. | +50 / -25 |
| `bin/render-prompt.sh` (resolver registry) | Top-of-file `PROMPT_RESOLVERS` table: `{token} → resolver function`. Resolver functions are thin wrappers (`_resolve_branch_name` → `bash bin/branch-name.sh`; `_resolve_dispatch_id` → `echo "$PIPELINE_DISPATCH_ID"`; etc.). Render loop iterates over tokens encountered in the source, dies on unknown. | +60 / -30 |

### 5.3 The detective backstop

| File | Change | LOC |
|---|---|---|
| `bin/run-stage.sh` (envelope validator) | New `_validate_dispatch_envelope <issue> <stage>`: (a) stage-summary file exists post-dispatch (existing rc=25 path); (b) Linear comments posted under sigs `(completion|halt|scope-approval|wait|verdict)/<stage>/<issue>` during this dispatch all carry the current dispatch_id marker; (c) transcript scan via `assert_no_tool_invocation` (existing helper at `bin/dispatch.sh`) — extended to assert no `mcp__plugin_linear` invocation, no `curl ... linear.app`, no direct Linear API calls outside `bin/linear.sh`. Halt with `verdict halt --reason dispatch-envelope-violation` on any failure. Skip on wait-exit and scope-approval-replay. | +60 |

### 5.4 Prompt-side surface

| File | Change | LOC |
|---|---|---|
| `AGENT_PROMPTS.md` (preamble, after line 91) | New section: "Dispatch identifier and freshness contract." Documents `{dispatch_id}` interpolation, the auto-injection rule (agents MUST NOT manually emit `dispatch id=` markers), and the no-manual-Linear-API rule. ~30 lines. | +30 |
| `AGENT_PROMPTS.md` Stage summary contract (line 164–209) | Generalize ENG-77 D-001's "MANDATORY — overwrite on every dispatch" rule from §5 only to apply uniformly to all §§1–7. Per ENG-77 D-003, the structural change here un-defers the §3/§4 generalization (clear-at-start removes the substrate that made narrowing prudent). | +15 / -5 |
| `bin/agent-prompts-content-test.sh` | Generalize ENG-77 D-002's three asserts from §5 to §§1–7 (each stage's stage-summary bullet must mandate overwrite-every-dispatch). Add new asserts: §preamble cites the dispatch_id contract; §preamble names the auto-injection rule; every `{…}` token in the file appears in `PROMPT_RESOLVERS`. | +60 |

### 5.5 Test surface

| File | Change | LOC |
|---|---|---|
| `bin/run-stage-test.sh` | Cases: (a) dispatch_id increments monotonically across consecutive `main` calls; (b) clear-on-start removes current-stage files but leaves OTHER stages' summaries (forward+loopback reads); (c) envelope validator halts on missing dispatch_id stamp on a Linear comment; (d) envelope validator halts on Linear-write-via-MCP transcript signature. | +80 |
| `bin/linear-test.sh` (new) | Marker injection: `add-comment` body unconditionally carries `<!-- meta: dispatch id=… stage=… -->` when env vars set. With env unset (operator manual call), no injection (preserves operator-side behavior). `find_fresh_verdict` filters by id; legacy-comment fallback returns timestamp-window result. | +140 |
| `bin/render-prompt-test.sh` | Resolver registry: every `{token}` resolves via a registered resolver; an unknown-token fixture → `die`. ENG-79's `branch_name` test stays; new tests for `dispatch_id`, `issue_id`, `stage_summary_path`. | +50 |
| `bin/verdict-handler-test.sh` | New cases for dispatch_id-based filter (replacing ENG-41 §4.2's planned timestamp/cross-check cases — ENG-41's labels-cross-check stays as the legacy-fallback case). Stale-id fixture: `last_transition` has dispatch_id from a prior cycle → `resume_in_progress_transition` returns 1. | +50 |

### 5.6 Documentation

| File | Change | LOC |
|---|---|---|
| `CLAUDE.md` | New "Cross-dispatch staleness contract" § referencing this brainstorm; brief mention of `PIPELINE_DISPATCH_ID` env var alongside the existing `PIPELINE_WRITER` (ENG-41). | +30 |
| `docs/runbooks/recovery.md` | New section: "Dispatch envelope violation" — symptoms (halt with `reason=dispatch-envelope-violation`), interpretation (one of: agent skipped Write, agent bypassed `linear.sh`, dispatch_id allocator failed), recovery (`bash bin/pipeline.sh decide ENG-N --action continue` to clear; investigate transcript at `$PROJECT_STATE_DIR/<ident>/logs/<stage>-*.log`). | +40 |
| `docs/pipeline-vocabulary.md` | Auto-regenerated; documents the new `dispatch` meta-kind and `dispatch-envelope-violation` halt reason. | (gen) |

**Total**: ~860 LOC across 14 files, of which ~380 LOC are tests. One vocabulary expansion (1 meta-kind + 1 halt reason). One env var (`PIPELINE_DISPATCH_ID` alongside ENG-41's `PIPELINE_WRITER`).

## 6. Data flow

### 6.1 Forward transition (e.g., implementing → ui)

```
T0  Tick: poll selects (ENG-71, ui).
    ├─ run-local.sh resolves worktree (ENG-67 invariant).
    ├─ run-stage.sh main starts:
    │    PIPELINE_DISPATCH_ID = ENG-71-d014  (allocated here)
    │    _clear_current_stage_slots ENG-71 ui:
    │      rm stage-summary-ui.md          ← G-2
    │      rm wait-ui.json
    │      (stage-summary-implementing.md left intact — ui will read it)
    │
    ├─ render-prompt.sh:
    │    {dispatch_id}     → ENG-71-d014  (from PROMPT_RESOLVERS[dispatch_id])
    │    {branch_name}     → feat/eng-71-…  (from PROMPT_RESOLVERS[branch_name] → bin/branch-name.sh)
    │    {stage_summary_path} → $(issue_dir)/stage-summary-ui.md
    │    render-time validator: no unknown tokens.        ← G-4
    │
    ├─ dispatch.sh: env=PIPELINE_DISPATCH_ID,PIPELINE_WRITER=agent,PIPELINE_STAGE=ui
    │
    ├─ [ui agent reads stage-summary-implementing.md — current iter's content,
    │   because implement's last dispatch (d013) wrote it; ui's d014 doesn't clear it.]
    │
    ├─ [ui agent writes stage-summary-ui.md — file existed only because ui created it
    │   this dispatch (cleared at d014 start).]
    │
    ├─ [ui agent calls bash bin/linear.sh add-or-update-comment …
    │   linear.sh auto-injects <!-- meta: dispatch id=ENG-71-d014 stage=ui --> ]   ← G-3
    │
    ├─ post-dispatch in run-stage.sh:
    │    _validate_dispatch_envelope ENG-71 ui:
    │      stage-summary-ui.md exists                              ✓ (G-2 satisfied)
    │      all comments under (completion|verdict)/ui/ENG-71 from this tick
    │        have dispatch id=ENG-71-d014 markers                 ✓ (G-3 satisfied)
    │      transcript: no MCP/curl Linear writes                  ✓
    │
    ├─ post_completion_comment reads stage-summary-ui.md, posts via linear.sh
    │   (auto-injects another dispatch_id marker; idempotent — body already contains one).
    │
    └─ verdict_handler: find_fresh_verdict filtered to id=ENG-71-d014 → ui done-marker.
       transitions ui → reviewing.
```

### 6.2 Loopback (e.g., review → implement re-entry)

```
[review d014 has just emitted verdict fail target=implementing]
[orchestrator's verdict_handler routes: stage:reviewing → stage:implementing]

T0  Next tick: poll selects (ENG-71, implementing).
    ├─ run-stage.sh main:
    │    PIPELINE_DISPATCH_ID = ENG-71-d015  (NEXT id; loopback gets a fresh one)
    │    _clear_current_stage_slots ENG-71 implementing:
    │      rm stage-summary-implementing.md   ← clears prior implement-d013's content
    │      (stage-summary-reviewing.md left intact — implement reads d014's findings)
    │
    ├─ render-prompt.sh:
    │    {dispatch_id} → ENG-71-d015
    │    (other tokens unchanged)
    │
    ├─ [implement agent reads stage-summary-reviewing.md — d014's content,
    │   the review findings that triggered THIS loopback.
    │   The Linear thread also surfaces completion/reviewing/ENG-71 via sig dedup;
    │   that comment's body carries dispatch id=ENG-71-d014 — the trigger for d015.]
    │
    ├─ [implement agent writes stage-summary-implementing.md — clean slate (cleared at d015 start)]
    │
    ├─ [implement agent posts tdd-evidence comment via linear.sh]
    │   auto-injects <!-- meta: dispatch id=ENG-71-d015 stage=implementing -->
    │
    ├─ post-dispatch envelope validator: all checks pass.
    │
    └─ verdict_handler: find_fresh_verdict filtered to id=ENG-71-d015 → implement pass-marker.
       transitions implementing → ui.

[The d013 → d015 jump is monotonic; d014 (review) sat between them.
 dispatch_history.jsonl carries all three dispatches with stage labels;
 retrospectives reconstruct the cycle structure from the log.]
```

### 6.3 ENG-41 §1.2 stale-resume scenario, post-fix

```
[Pre-fix: 2-day-old pipeline-transition: planning → implementing comment.
 Manual reset → Linear status=Todo, stage labels stripped, issue-state.json deleted.
 Tick: poll picks up via Pass 5 inbox.]

T0  run-stage.sh main:
     allocate_dispatch_id: issue-state.json was deleted; new file written with seq=1.
     PIPELINE_DISPATCH_ID = ENG-24-d0001
     _clear_current_stage_slots: removes stage-summary-brainstorming.md (no-op, already absent).

T1  brainstorm runs; emits done-marker. linear.sh auto-injects dispatch id=ENG-24-d0001.

T2  post-dispatch verdict_handler:
     resume_in_progress_transition:
       last_transition = the 2-day-old planning → implementing comment.
       parse: dispatch_id_in_marker = (NONE — legacy comment, pre-cutover)
       fallback: timestamp window check + ENG-41 labels-cross-check
                 → labels.from = brainstorming ≠ comment.from = planning
                 → return 1                                                ← ENG-41 §4.2 guard fires
     find_fresh_verdict:
       filter: dispatch_id == ENG-24-d0001
       brainstorm done-marker has dispatch id=ENG-24-d0001 (auto-injected)
       2-day-old transition lacks any dispatch_id marker → filtered out
       → returns brainstorm done-marker
     transitions brainstorming → planning correctly.
```

The post-fix behavior depends on EITHER the dispatch_id filter OR the
labels-cross-check; the design ships both because the labels-cross-check
covers the legacy-comment fallback window.

## 7. Decisions

### D-001: Per-issue monotonic id (vs per-(issue, stage))

Chosen: id format `ENG-N-d<NNNN>`, monotonic counter per issue,
incremented on every dispatch regardless of stage.

Rejected: per-(issue, stage) ids like `ENG-71-reviewing-d05`. Two-level
state, id collisions across stages, total ordering within an issue
lost. Per-issue ordering is the load-bearing forensic property
(retrospectives, incident reconstruction, dispatch_history.jsonl
linearization) and per-(issue, stage) gives that up. Per-stage iter
counts are easily reconstructed from `dispatch_history.jsonl` regardless
of id format.

Stage information is preserved as a *field* on every artifact stamp
(`<!-- meta: dispatch id=ENG-71-d014 stage=reviewing -->`), so forensic
readability is not lost — just not encoded in the id itself.

### D-002: dispatch_id allocator lives in `bin/common.sh`

Chosen: new `allocate_dispatch_id <issue>` in `common.sh` exported
alongside `issue_dir`, `compute_pipeline_content_hash`, etc.
`run-stage.sh` calls it; `dispatch.sh` calls `current_dispatch_id`
(read-only) when re-rendering on retry.

Rejected: allocator inline in `run-stage.sh`. Tests for `run-stage.sh`
would have to source-and-stub the allocator; placing it in `common.sh`
makes it independently testable.

Rejected: allocator in `dispatch.sh`. Dispatch is invoked AFTER
`run-stage.sh::main` has already done state setup; the allocator
needs to fire earlier (before `_clear_current_stage_slots` so the
clear can be logged with the dispatch_id).

### D-003: Auto-injection at `bin/linear.sh` chokepoint (vs orchestrator post-process)

Chosen: `bin/linear.sh::add_comment` and `add_or_update_comment` auto-
inject the `dispatch_id` marker when `$PIPELINE_DISPATCH_ID` is set.

Rejected: orchestrator post-processes every comment after the dispatch
returns. Bookkeeping-heavy (must track which sigs were touched during
the dispatch); race-prone (if the dispatch crashes, post-process never
runs and comments are unstamped). Chokepoint injection inherits via
env naturally and crashes the dispatch loud.

Rejected: agent emits the marker manually per prompt rule. Same trust
problem as ENG-41 §4.1 — agent could lie, skip, or use a stale id. The
chokepoint is the single trustworthy authoring site.

### D-004: Detective is "transcript scan + post-dispatch sanity," not "halt-on-mismatch"

Chosen: the detective layer halts only on EGREGIOUS violations
(agent bypassed `linear.sh` entirely, file missing, dispatch_id env
not set). Sanity checks (every comment posted under issue+stage sigs
this dispatch carries the auto-injection) are belt-and-suspenders for
the chokepoint — if the chokepoint is sound, every comment HAS the
marker; if it doesn't, that's a chokepoint bug.

Rejected: halt on every observable inconsistency. Over-broad — small
issues (e.g., a future operator-tool's manual comment without
PIPELINE_DISPATCH_ID set) would halt issues unnecessarily. The
preventive layer carries the load; the detective catches structural
bypass.

### D-005: Reader-side fallback to timestamp window for legacy comments

Chosen: `find_fresh_verdict` and `resume_in_progress_transition` fall
back to timestamp-window when no `dispatch_id` markers exist on the
issue. Fallback expires once any `dispatch_id` marker appears on the
issue (which happens the first time the orchestrator dispatches the
issue post-cutover).

Rejected: hard cutover (legacy issues halt at next tick). In-flight
issues at the cutover would all halt simultaneously, blocking the
deploy on a bulk recovery operation. Soft fallback amortizes the
migration: each issue migrates on its next dispatch.

The fallback shipped as part of this design is the SAME ENG-41 §4.2
labels-cross-check the trust-model brainstorm specified. ENG-41 ships
the cross-check as primary; this design demotes it to fallback once
the dispatch_id primary is in place. ENG-41's brainstorm and this
brainstorm are coherent: ship ENG-41 first, this design second; the
cross-check goes from "primary" to "fallback for legacy comments"
in the second phase.

### D-006: Generalize ENG-77 D-001 prompt rule to all §§1–7 (un-defer D-003)

Chosen: ENG-77 D-001's §5-only "MANDATORY — overwrite on every
dispatch" generalizes to every stage's stage-summary-file Output
bullet. ENG-77 D-002's three asserts generalize from §5 to all stages.

This *un-defers* ENG-77 D-003's narrowing. ENG-77 D-003's un-deferral
condition was "one observed instance of an implement-stage loopback
where the implement agent emits fresh tdd-evidence but doesn't rewrite
stage-summary-implementing.md." This design's clear-at-start removes
the substrate that made the narrowing prudent — there is no longer a
"residual file" the agent could read-then-skip-write, because the
file is cleared by the orchestrator before the agent sees it.

The §3/§4 prompt-edit cost ENG-77 D-003 deferred (~25 lines / ~15
asserts) is paid here because the structural prerequisite changed.

### D-007: Subsume ENG-77 D-004 (stale-file mtime check) entirely

Chosen: do NOT add a post-dispatch mtime check on the stage-summary
file. The clear-at-start mechanism makes existence-after-dispatch
proof-of-this-dispatch-authorship; mtime is irrelevant.

ENG-77 D-004 is superseded by clear-at-start (G-2) — file existence
after envelope validation IS the freshness proof, with no clock-
granularity edge cases (HFS+ vs APFS sub-second skew flagged in
ENG-77 §E-3). The deferred halt-reason addition (`stale-stage-summary`)
is replaced by `dispatch-envelope-violation` (more general; covers
the case ENG-77 D-004 was intended for).

The security precondition ENG-77 D-004 added (`$ident` must match
`^ENG-[0-9]+$` before passing to `stat`) does NOT apply here because
clear-at-start uses `rm -f "$(issue_dir "$ident")/stage-summary-${stage}.md"`
where `issue_dir` already requires non-empty input; `$ident` shape
validation belongs at `issue_dir` itself (separate hardening, out of
scope).

### D-008: ENG-77 D-005 (typed findings channel) stays deferred

Chosen: this design does NOT introduce typed/schema'd findings. ENG-77
D-005's un-deferral conditions still apply unchanged:

- Two distinct review-implement loop incidents *despite* this contract.
- Operator demand for structured findings.
- A typed JSON schema with byte-cap, validation, and explicit nested-
  marker rejection.

The contract this design ships is freshness-only; content shape stays
prose. If ENG-77 D-005's un-deferral fires, the typed channel layers
ON TOP of dispatch_id (each typed-findings comment still gets the
auto-injection), not in place of it.

### D-009: Phasing — ship in 4 phases, each independently shippable

Chosen sequence (each phase compiles, tests, and ships alone):

1. **Phase 1 (glue).** `bin/common.sh` allocator; `bin/dispatch.sh`
   env-passthrough; `bin/run-stage.sh` allocator-call + history log.
   `pipeline-events.json` vocabulary expansion. No behavior change yet
   (allocator allocates but nothing reads).
2. **Phase 2 (clear-at-start).** Generalize wait-exit pattern. Existing
   summary_missing rc=25 catches the loud-fail case (agent didn't
   write).
3. **Phase 3 (linear.sh injection + reader filter).** Auto-injection
   universal; readers filter by id with timestamp-window fallback for
   legacy.
4. **Phase 4 (resolver registry + envelope validator + content tests).**
   Generalize ENG-79's pattern; ship the detective backstop; un-defer
   ENG-77 D-003.

Phases 1–3 deliver the preventive contract; Phase 4 hardens.

The dependency on ENG-41 (lane fence) is one-way: ENG-41 ships
independently of this design and BEFORE Phase 3 (because Phase 3's
auto-injection assumes labels are lane-fenced — otherwise an agent
could still write to Linear via direct API and bypass the auto-
injection). ENG-41's brainstorm is at
`docs/brainstorms/2026-04-27-pipeline-trust-model-enforce-write-lanes-design.md`.

### D-010: New env var `PIPELINE_DISPATCH_ID` (not a flag, not a config field)

Chosen: env var, set by `run-stage.sh` and `dispatch.sh`, inherited by
subshells naturally. Mirrors ENG-41's `PIPELINE_WRITER` pattern —
same rationale (D-001 in ENG-41).

Rejected: `--dispatch-id` flag on every `bin/linear.sh` call. 30+
call sites need editing; env var inherits transparently.

Rejected: `config.json` field. dispatch_id is per-dispatch, not per-
project; config is the wrong granularity.

## 8. Failure modes

| Failure | What happens | Detection |
|---|---|---|
| Agent skips Write of stage-summary file | File doesn't exist post-dispatch (cleared at start, never recreated) → existing rc=25 `summary_missing` path fires → halt. | Existing rc=25 in `run-stage.sh:977-989`. |
| Agent writes file with stale (read-then-skip-write) content | Cannot happen post-clear: no prior content to read. The file simply doesn't exist when the agent looks. The agent's read attempts get ENOENT. The agent must Write fresh content from its current-dispatch reasoning. | n/a — preventive. |
| Agent posts a Linear comment via `mcp__plugin_linear` (bypassing `bin/linear.sh`) | Comment has no auto-injected `dispatch_id` marker. Envelope validator's transcript scan catches the MCP invocation → halt with `dispatch-envelope-violation`. | Transcript scan in `_validate_dispatch_envelope`. |
| Agent curl's Linear API directly | `--allowed-tools` excludes `Bash(curl:*)` for non-build stages by default (must verify per stage). Transcript scan as backup. | Allowed-tools denial; transcript scan. |
| `dispatch_id` allocator races (two ticks for same issue at once) | Cannot happen: `.claude-mutex.lock/` serializes per-host; `_acquire_run_lock` per-issue. Allocator atomic-writes via tmpfile + mv. | Existing locking; the allocator's atomic-write pattern. |
| `issue-state.json` corruption mid-allocate | Allocator dies (jq parse fails) → `run-stage.sh::main` dies → tick logs FATAL → next tick's allocator sees corrupt state too → human recovery. | FATAL log entry; halt-sprawl monitor (ENG-21). |
| Operator runs `bin/linear.sh add-comment …` manually (no `PIPELINE_DISPATCH_ID` set) | Auto-injection skipped (env var unset → conditional skip). Comment lands without marker. Reader fallback to timestamp-window picks it up correctly. | Designed for: operator-lane writes are unstamped by intent. |
| `render-prompt.sh` encounters a `{token}` not in `PROMPT_RESOLVERS` | Render-time validator dies loud with the unknown token name. Prompt is never sent to `claude -p`. Tick fails fast. | Render-time die. |
| New stage added but `_clear_current_stage_slots` not extended | Stage's local files persist across dispatches → ENG-77-class bug for the new stage. | Test pin in `bin/run-stage-test.sh` asserts every stage in `dispatch.sh::allowed_tools_for`'s case-arm-names is also in the clear-list. |
| Mid-dispatch crash between allocator and clear-at-start | `dispatch_history.jsonl` has a record without `exit_code, exit_at`. Next tick's allocator increments past it (counter is durable). The previous (orphaned) attempt's stage-summary file may or may not have been cleared — but next tick's clear-at-start fires uncondition­ally, so it gets cleared. | dispatch_history.jsonl gap; benign. |
| Linear API outage during auto-injection's `add_comment` call | Existing `linear.sh` failure path: returns non-zero; `run-stage.sh` logs and routes via classify-failure (rc=24, `linear-post-failed`, `retry-immediately`). | Existing failure routing. |
| Reader's dispatch_id fallback (legacy-comment window) extended indefinitely | If an issue never sees a post-cutover dispatch (e.g., abandoned), it stays in fallback mode forever. Benign — abandoned issues are skipped by poll. | n/a — abandonment is the resolution. |
| Two stages of the same issue race for dispatch_id (impossible today, but defense in depth) | Allocator's atomic mv sequence guarantees one write wins; the loser sees the higher seq next read. | Atomic-write pattern. |

## 9. Open questions

1. **Should `dispatch_id` be visible in the Linear status column or
   as a Linear custom field?** Operators triaging halts could see
   "ENG-71 currently on dispatch d014, halted" at a glance.
   **Working answer:** no for this design — Linear custom-field write
   is a new lane (orchestrator-only) and adds a sync surface. Defer;
   `bin/status.sh` displays it from `dispatch_history.jsonl` instead.

2. **Should the dispatch_id stamp on Linear comments include
   `pipeline_content_hash` for cache-key forensics?** Adding it
   makes "compare two dispatches' inputs" queryable from Linear alone.
   **Working answer:** no — the hash is large and noisy in comment
   bodies; `dispatch_history.jsonl` already stores it per-dispatch.

3. **What is the right behavior when the agent writes the stage-
   summary file AND emits a verdict-marker, but the verdict-marker's
   dispatch_id (auto-injected by linear.sh during the agent's
   linear.sh call) doesn't match the file's stamp (which doesn't
   exist — files aren't stamped, per D-007)?** Files don't carry
   stamps; the verdict-marker carries the stamp; the file is "fresh"
   by virtue of clear-at-start. Mismatch impossible. (This is a
   non-question; recorded for clarity.)

4. **Should `_clear_current_stage_slots` clear `transcript-*.log`
   files for the current stage?** Tempting (forensic noise), but
   transcripts are appended-to, not overwritten — they accumulate
   across dispatches by design. Solution: tag each transcript line
   with `[dispatch=ENG-N-d014]` prefix; clear-at-start does NOT
   touch transcripts. **Working answer:** prefix lines, don't clear.
   Out of scope for this brainstorm; track in a separate ticket.

5. **Is render-time validation (PROMPT_RESOLVERS unknown-token die)
   the right enforcement mechanism, or should `bin/agent-prompts-content-test.sh`
   carry the assertion?** Both. Test pins catch drift at commit-time;
   render-time die catches anything that escapes (e.g., a token
   added to AGENT_PROMPTS.md by a non-harness contributor without
   running tests). Cheap to ship both.

6. **Does ENG-78's halt-on-retry-immediately bug (classify_failure
   unconditionally adds `pipeline:halted`) need to ship before this
   design or after?** Independent; ENG-78's fix is a logic bug in
   `classify_failure`, not a hand-off contract issue. Either order
   works; ship whichever is in flight first.

## 10. Assumption inventory

| ID | Assumption | Verification |
|---|---|---|
| A-001 | `bin/run-stage.sh:495-499` clears stage-summary on wait-exit and the surrounding code articulates the rationale "don't post stale content from a prior dispatch." | Verified by direct read 2026-05-09 (`sed -n '490,500p'` showed the rm and comment). |
| A-002 | `bin/run-stage.sh:977-989` is the agent-contract validator carrying the existing `summary_missing` rc=25 path. | Verified by direct read. |
| A-003 | `bin/render-prompt.sh:222` already calls `bin/branch-name.sh` for `branch_name` (ENG-79). | Verified by direct read; the comment block at `render-prompt.sh:213-220` documents the ENG-79 fix. |
| A-004 | `bin/linear.sh::add_comment` lives at line 470; `add_or_update_comment` at line 541. | Verified by `grep -nE`. |
| A-005 | `issue_dir` lives at `bin/common.sh:68-72` and validates non-empty input. | Verified by direct read 2026-05-09 (matches ENG-77 D-004's citation). |
| A-006 | `.claude-mutex.lock/` serializes `claude -p` invocations per host; `_acquire_run_lock` (per-issue) serializes per-issue runs. | Verified per CLAUDE.md "Per-issue state directory" §; allocator atomicity layered on top. |
| A-007 | The agent's `--allowed-tools` list excludes `mcp__plugin_linear` (per ENG-41 A-004). | UNVERIFIED at brainstorm time; same un-verified-in-the-field caveat as ENG-41 §A-004. The transcript scan in `_validate_dispatch_envelope` is the backstop. |
| A-008 | `bin/agent-prompts-content-test.sh` runs in `.githooks/pre-commit` and is sourced by `bin/run-stage-test.sh` and the dispatch-test pattern. | Verified per ENG-77 §A-002 / §A-005 lineage; also CLAUDE.md "Pre-commit hook" §. |
| A-009 | `bin/pipeline-events.json` is the closed registry; new meta-kinds and halt-reasons require entry there. | Verified per CLAUDE.md "Pipeline vocabulary" §; ENG-77 D-004 §C cites the same constraint. |
| A-010 | Adding an env var (`PIPELINE_DISPATCH_ID`) to dispatch.sh's env block is sufficient for subshell inheritance into `bin/linear.sh` calls the agent makes. | Verified by ENG-41 A-003 (same pattern for `PIPELINE_WRITER`). |
| A-011 | `dispatch_history.jsonl` is a new file; no existing tooling depends on it. | New artifact. By construction, no callers; safe addition. |
| A-012 | `bin/run-stage.sh` re-executes `_clear_current_stage_slots` on every dispatch start regardless of prior dispatch's exit status (success, halt, retry-immediately). | UNVERIFIED at brainstorm time; the implementation must run the clear before any branching on prior state, immediately after dispatch_id allocation. Test pin asserts this. |

## 11. Migration / rollout

Single-PR-per-phase rollout. No data migration. Existing in-flight
issues continue under legacy timestamp-window semantics until their
next dispatch post-cutover; the reader-side fallback (D-005) carries
them.

```
Phase 1 (glue, no behavior change yet)
  ├─ bin/common.sh: allocate_dispatch_id, current_dispatch_id
  ├─ bin/dispatch.sh: env passthrough
  ├─ bin/run-stage.sh: allocator call + dispatch_history.jsonl
  ├─ bin/pipeline-events.json: dispatch meta-kind, dispatch-envelope-violation halt reason
  └─ Tests: bin/common-test.sh (or new) for allocator atomicity

Phase 2 (clear-at-start, agents start hitting rc=25 if they skip Write)
  ├─ bin/run-stage.sh: _clear_current_stage_slots
  ├─ Tests: bin/run-stage-test.sh fixtures for clear behavior
  └─ AGENT_PROMPTS.md (light): note clear-at-start in §preamble

Phase 3 (linear.sh auto-injection + reader filter — load-bearing change)
  ├─ Depends on: ENG-41 lane fence shipped (otherwise auto-injection can be bypassed)
  ├─ bin/linear.sh: auto-inject dispatch_id marker
  ├─ bin/verdict-handler.sh: dispatch_id-primary filter, timestamp fallback
  ├─ Tests: bin/linear-test.sh (new), bin/verdict-handler-test.sh (extended)
  └─ Soft cutover: in-flight issues use fallback path until next dispatch

Phase 4 (resolver registry + detective + content-test generalization)
  ├─ bin/render-prompt.sh: PROMPT_RESOLVERS registry
  ├─ bin/run-stage.sh: _validate_dispatch_envelope
  ├─ AGENT_PROMPTS.md: §preamble dispatch contract; §§1-7 stage-summary mandate
  ├─ bin/agent-prompts-content-test.sh: generalize ENG-77 D-002 asserts
  ├─ Tests: render-prompt-test.sh (extended)
  └─ Un-defers ENG-77 D-003 (the structural prerequisite is now present)
```

After Phase 3 ships and is stable for ~30 days, ENG-41's labels-cross-
check is demoted from primary to legacy-fallback (no code change —
the order of checks in `resume_in_progress_transition` is reversed,
dispatch_id-first, labels-second).

## 12. Out-of-scope future work

- **ENG-77 D-005 (typed findings channel).** Stays deferred under its
  existing un-deferral conditions. If un-deferred, layers on top of
  this design (typed-findings comments still get the auto-injection).
- **dispatch_id surfaced as a Linear custom field.** `bin/status.sh`
  reads from `dispatch_history.jsonl` for now; Linear custom-field
  sync is separable.
- **Per-dispatch budget gating.** `dispatch_history.jsonl` enables a
  future "halt issue if cumulative cost > $X" check, but that's
  product-policy, not hand-off contract.
- **Cross-issue staleness.** The contract scopes per-issue. A future
  "shared cache file" type artifact (none today) would need a
  different mechanism (likely cycle-id keyed by content hash, not
  per-dispatch monotonic). Out of scope.
- **Transcript line tagging.** Open question §4. Track separately;
  forensic improvement, not load-bearing.
- **`bin/dispatch-test.sh`-style coverage for the auto-injection
  path.** A test fixture verifying that an agent invoked through
  `dispatch.sh` (with stub claude) emits comments through `linear.sh`
  and the markers are present. Higher cost than the unit-level tests
  in §5.5; defer until empirical evidence the unit tests miss something.
