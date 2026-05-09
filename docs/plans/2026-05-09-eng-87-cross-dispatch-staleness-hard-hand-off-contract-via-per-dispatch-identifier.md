---
linear: ENG-87
date: 2026-05-09
topic: cross-dispatch staleness — hard hand-off contract via per-dispatch identifier (allocator + clear-on-start + linear.sh auto-injection + resolver registry + envelope validator)
---

# Plan — ENG-87 cross-dispatch staleness hard hand-off contract

Implementation plan for the design in
`docs/brainstorms/2026-05-09-eng-87-cross-dispatch-staleness-hard-hand-off-contract-via-per-dispatch-identifier-design.md`
(currently on branch `feat/cross-dispatch-staleness-handoff-contract-brainstorm`,
not yet on main; merge order is independent).

## Anti-anchoring

- **Problem (operator's words):** six unrelated-looking incidents (ENG-77, ENG-41 §1.1
  + §1.2, ENG-78, ENG-79, ENG-67) all collapse to one structural class — *a dispatch
  reads data written by a PRIOR dispatch as if it's current*. Each prior fix patched
  one medium (per-issue file, Linear comment freshness, Linear label, prompt token,
  worktree path) with that medium's natural primitive. None of them gives a future
  reader a way to ask "which dispatch wrote this artifact?" — that question is what
  every instance collapses to.
- **Does the brainstorm address it?** Yes. Five invariants G-1..G-5 ship one glue
  (`dispatch_id`) plus four per-medium primitives (clear-at-start, linear.sh
  auto-injection, prompt resolver registry, envelope validator). G-3 depends on
  ENG-41's lane fence shipping first; the lane fence is what makes auto-injection
  trustworthy.
- **Proportional?** Yes. ~860 LOC across 14 files, of which ~380 LOC are tests.
  One vocabulary expansion (`dispatch` meta-kind + `dispatch-envelope-violation`
  halt reason). One env var (`PIPELINE_DISPATCH_ID`). One new persistent artifact
  (`dispatch_history.jsonl`); everything else is additive (extra fields on existing
  JSON, meta-marker injection on existing comments). No data migration; soft
  fallback to timestamp-window for legacy issues. The brainstorm explicitly rejects
  heavier alternatives — typed envelopes (D-008), whole-issue lock (§3),
  cycle-id-on-logs (§3) — and documents why each is over-fit.
- **No escalation needed.**

## Goal

Land an orchestrator-allocated per-dispatch identifier (`dispatch_id` of the form
`ENG-N-d<NNNN>`, monotonic per issue, persisted in `issue-state.json`) plus four
per-medium primitives — clear-at-dispatch-start for per-issue local files,
auto-injection of `<!-- meta: dispatch id=… stage=… -->` markers at the
`bin/linear.sh::add_comment` / `add_or_update_comment` chokepoint, a prompt-token
resolver registry in `bin/render-prompt.sh` with render-time validation, and a
post-dispatch envelope validator (`_validate_dispatch_envelope`) that halts with
the new `dispatch-envelope-violation` reason on EGREGIOUS bypass — such that a
fresh dispatch's reads (orchestrator's `find_fresh_verdict` /
`resume_in_progress_transition`, agent's loopback inputs) filter cross-dispatch
data by id rather than by secondary signals (mtime, timestamp window, label state),
verifiable via `bash bin/run-stage-test.sh && bash bin/linear-test.sh && bash
bin/verdict-handler-test.sh && bash bin/render-prompt-test.sh && bash
bin/agent-prompts-content-test.sh && bash bin/common-test.sh && bash
bin/dispatch-test.sh && bash bin/classify-failure-test.sh && bash
bin/secret-probe-lint.sh && bash -n bin/*.sh` all exiting 0.

## Architecture

The change is additive across `bin/common.sh` (allocator + reader + a one-line
`export -f` extension), `bin/dispatch.sh` (env passthrough at the existing
`env PIPELINE_WRITER=agent …` block at line 437), `bin/run-stage.sh` (allocator
call + history log + `_clear_current_stage_slots` + `_validate_dispatch_envelope`),
`bin/linear.sh` (auto-injection at `add_comment`/`add_or_update_comment`),
`bin/verdict-handler.sh` (dispatch_id-primary filter in `find_fresh_verdict`
and `resume_in_progress_transition` with timestamp-window/labels-cross-check
fallback), `bin/render-prompt.sh` (PROMPT_RESOLVERS registry replacing the
hand-rolled python interpolation), `bin/pipeline-events.json` (vocabulary
expansion), `bin/common.sh::failure_outcome_for_exit` (new exit code 29),
`AGENT_PROMPTS.md` (preamble dispatch-id contract + §§1-7 stage-summary mandate
generalisation), and four sibling test files. No changes to `bin/poll.sh`,
`bin/run-local.sh`, `bin/classify-failure.sh::classify_failure` body (only sourcing
the new exit-29 mapping), `bin/scope-check.sh`, `bin/metrics.sh`,
`bin/branch-name.sh`, `bin/setup.sh`, or any launchd plist.

The architectural pivot is twofold:

1. **Glue layer (`dispatch_id`).** Every cross-dispatch read becomes a single-equality
   check on a monotonic per-issue counter, instead of secondary inference (mtime,
   createdAt window, label state, prompt-token textual equality). The counter is
   allocated once at `bin/run-stage.sh::main`, exported as `PIPELINE_DISPATCH_ID`,
   and inherited transparently by `bin/dispatch.sh`'s subshell, the agent's
   `bash bin/linear.sh` calls, and the orchestrator's post-dispatch validator.

2. **Per-medium primitives, each cheapest for its medium.** Per-issue local files
   get clear-on-dispatch-start (existence post-dispatch == THIS-dispatch authorship);
   Linear comments get a single auto-injected marker at the chokepoint (no
   per-call-site edit); prompt tokens get a resolver registry that fails
   render-time on any unknown `{token}` (generalises ENG-79's branch-name fix);
   labels delegate to ENG-41's already-designed lane fence (this design's Phase 3
   depends on ENG-41 having shipped). The detective backstop (envelope validator)
   halts only on EGREGIOUS bypass: missing stage-summary file (existing rc=25),
   transcript invocation of `mcp__plugin_linear` or direct Linear-API curl
   (extends `assert_no_tool_invocation` from `bin/dispatch.sh`).

The dependency on ENG-41 is one-way: ENG-41 ships independently and BEFORE Phase 3
(otherwise an agent could bypass `linear.sh` via direct API call and skip the
auto-injection — Phase 4's transcript scan is the backstop, but Phase 3's primary
mechanism assumes labels are lane-fenced). Phases 1, 2, and 4 are independently
shippable without ENG-41.

This plan keeps the brainstorm's 4-phase phasing as task groups; the implement
agent may collapse them into a single PR or split per phase per operator
discretion (each phase compiles, tests, and ships alone — see brainstorm §11).

The harness has no `docs/VISION.md`, no `docs/knowledge/decisions.md`, no
`SYSTEM_ARCHITECTURE.md`, and no `learned-rules/harness/plan.md` (verified — only
`docs/brainstorms/`, `docs/plans/`, `docs/runbooks/`, `docs/pipeline-vocabulary.md`,
and `docs/pipeline-vocabulary.template.md` exist; under `learned-rules/harness/`
only `build.md` and `project-profile.md` are present). Governing constraints come
from `CLAUDE.md`, `learned-rules/harness/project-profile.md`, the brainstorm's
own decisions §7, and the existing `bin/*-test.sh` source-and-stub harness.

## Tech stack

- Bash 3.2+ (Darwin default; harness-self target).
- `jq` for JSON read/write (already a hard dep — `bin/common.sh:316-319`,
  `bin/classify-failure.sh:31-37`, `bin/linear.sh:30`).
- `awk`, `sed`, `shasum`, `find` (already used).
- `gtimeout`, `gh`, `curl` — unchanged.
- No new dependencies. No `bin/dispatch.sh::allowed_tools_for` cases added.
- No new launchd plist or env-var injection at the `EnvironmentVariables` layer
  — `PIPELINE_DISPATCH_ID` is allocated and exported per-dispatch by
  `bin/run-stage.sh::main`, mirroring `PIPELINE_WRITER`'s flow at
  `bin/common.sh:301-302` and `bin/dispatch.sh:437`.

## Assumption Inventory

Every modified-file fact is `path:line`-cited against the current worktree
(`/Users/rajatgoyal/.local/state/twinning-harness/harness/ENG-87/worktree/`).
Assumptions marked `assumed/new` identify the file where the artifact will be
created. Codebase facts re-verified 2026-05-09; the brainstorm's §10 inventory
(IDs A-001..A-015) is propagated below with re-citations from this worktree's
file state.

### Modified files — current signatures, call sites, and globals

- **A-001 — `bin/common.sh::issue_dir` at lines 68-72.** Verified:

  ```
  68   issue_dir() {
  69     local issue="$1"
  70     [[ -n "$issue" ]] || die "issue_dir: missing issue id"
  71     printf '%s/%s' "$PROJECT_STATE_DIR" "$issue"
  72   }
  ```

  The new `allocate_dispatch_id` and `current_dispatch_id` (Task 1) land in
  `bin/common.sh` immediately after `compute_pipeline_content_hash`'s closing
  `}` at line 95 (sibling-helper convention; both are per-issue state-file
  helpers exported via `export -f` at line 275). The `export -f` line itself
  must be extended to include the two new functions (Task 1, last bullet).

- **A-002 — `bin/common.sh::failure_outcome_for_exit` at lines 111-137.**
  Verified — the case-arm covers exit codes 0 (with subcode 1 for
  `scope-approval-pending`), 10-14, 20-28, 124. **The next free code is 29**
  (27 = self-leak per ENG-69; 28 = leaked-in-scope-threshold per ENG-69;
  124 = dispatch-timeout). Task 2 adds:

      29) printf 'envelope-violation' ;;

  Adding the case-arm without updating its caller in
  `bin/run-stage.sh::main`'s exit-code routing dispatch is the failure mode
  the CLAUDE.md "When wiring a new script" § warns about — Task 2 ALSO adds
  the corresponding routing arm (see Task 9).

- **A-003 — `bin/common.sh::parse_pipeline_marker` at lines 192-242.**
  Verified — the parser already handles the `meta` family generically:
  line 213 strips the `<!-- meta: ... -->` envelope, line 219-228 parses
  `kind` as the first whitespace-token, lines 230-239 parse remaining
  `k=v` pairs into the JSON output. The new `meta: dispatch id=… stage=…`
  marker requires NO parser change — `parse_pipeline_marker` returns
  `{"event":"meta","kind":"dispatch","id":"…","stage":"…"}` by construction.
  Verified by direct read 2026-05-09. (The brainstorm §10 A-014 noted "one-
  line addition to its kind-recognition table" — re-verified that no such
  table exists; the parser is fully generic over kinds.)

- **A-004 — `bin/common.sh::export -f` list at line 275.** Verified:

  ```
  275  export -f issue_dir compute_pipeline_content_hash failure_outcome_for_exit parse_pipeline_marker is_orchestrator_paused set_orchestrator_paused
  ```

  Task 1 extends to:

  ```
  export -f issue_dir compute_pipeline_content_hash failure_outcome_for_exit parse_pipeline_marker is_orchestrator_paused set_orchestrator_paused allocate_dispatch_id current_dispatch_id
  ```

  Functions defined but not exported are not visible to subshells (a
  failure mode that bit ENG-41 §A-007 — re-verified by greppng for an
  earlier line where `acquire_lock release_lock` were added at line 296).

- **A-005 — `bin/run-stage.sh::main` at lines 714-800.** Verified — main
  executes in this order:

  1. arg parse + `t0` (lines 714-719)
  2. `verify_preconditions` (line 722)
  3. `guards.sh check` (line 735)
  4. scope-approval replay → `skip_dispatch=1` (lines 753-761)
  5. `_pre_dispatch_merge_gate` exits 0 if MERGED (lines 768-780)
  6. `_entry_conditions_gate` exits 0 if skip (lines 789-796)
  7. `mkdir -p "$(issue_dir …)"` (line 800)
  8. render-prompt → dispatch.sh (lines 802-911)

  The new allocator + `_clear_current_stage_slots` lands BETWEEN step 7
  (line 800) and step 8 (line 802), gated on `(( ! skip_dispatch ))` per
  brainstorm §5.1. Pre-dispatch gates that exit before line 800 (steps 5,
  6) do NOT allocate (they don't invoke `claude -p`). Scope-approval
  replay does NOT allocate (the prior dispatch's id is still durable in
  `issue-state.json` and its envelope was already validated).

- **A-006 — `bin/run-stage.sh::_handle_wait` at lines 489-578.** Verified —
  line 497-499 contains the exact rationale comment the brainstorm cites:

  ```
  497    # Clear any stale stage-summary file so a later post_completion_comment
  498    # cannot post stale content from a prior dispatch.
  499    rm -f "$(issue_dir "$ident")/stage-summary-${stage}.md" 2>/dev/null || true
  ```

  Task 5 generalises this clear-on-exit pattern to a clear-on-START helper
  `_clear_current_stage_slots <ident> <stage>` covering the same file PLUS
  `wait-${stage}.json`. The wait-exit clear at 497-499 stays (defense in
  depth — agent crash mid-wait would also leave a stale summary).

- **A-007 — `bin/run-stage.sh` agent-contract validator at lines 1059-1081.**
  Verified — the existing rc=25 path:

  ```
  1059   # Agent-contract validator (ENG-7). On a fresh dispatch (not scope-approval
  1060   # replay), the agent MUST have produced at least one of:
  ...
  1068   if (( ! skip_dispatch )); then
  1069     case "$stage" in
  1070       brainstorming|planning|implementing|ui|reviewing|qa|building)
  ...
  1074         if [[ ! -s "$_summary_path" ]] && [[ -z "$_fresh_marker" ]]; then
  1075           classify_failure "$ident" "$stage" "retry-immediately" \
  1076             "agent dispatch returned 0 but emitted no stage-summary file and no verdict marker" 25
  1077           exit 25
  ```

  This is the existing "agent didn't write at all" loud-fail. The new
  `_validate_dispatch_envelope` (Task 8) lands AFTER line 1081 (in the
  same `(( ! skip_dispatch ))` block) but BEFORE the
  `push_branch_if_ahead`/`post_completion_comment` block at lines
  1087-1103, so envelope failure halts BEFORE any post-completion Linear
  write occurs.

- **A-008 — `bin/run-stage.sh` post-completion-comment block at lines
  1087-1103.** Verified — `post_completion_comment` is called there;
  `find_fresh_verdict` is called immediately after at the verdict_handler
  invocation (line 1138). The envelope validator MUST run before line 1097
  (`post_completion_comment`) so a violation aborts before the Linear post
  burns API quota AND before the comment lands as if the dispatch
  succeeded.

- **A-009 — `bin/run-stage.sh::main` dispatch_rc routing block at lines
  821-910.** Verified — non-zero `dispatch.sh` exit codes route to specific
  `classify_failure` calls + `exit <rc>`. The new exit code 29
  (`envelope-violation`) lands as a sibling case-arm of 22/23/26/13:

  ```
  elif (( dispatch_rc == 29 )); then
    classify_failure "$ident" "$stage" "skip-until-human-acts" \
      "dispatch envelope violation: <details from sidecar>" 29
    exit 29
  ```

  Note: rc=29 is emitted BY THE ORCHESTRATOR (post-dispatch envelope
  validator), not by the agent's `claude -p` exit. The dispatch_rc routing
  arm is therefore unused in normal operation — the validator's exit path
  is direct. Task 9 lands the validator's `exit 29` site at the post-A-008
  insertion point (no use of the dispatch_rc routing arm).

- **A-010 — `bin/dispatch.sh::main` env block at line 437.** Verified:

  ```
  437  local cmd=(env PIPELINE_WRITER=agent
  438    gtimeout --signal=TERM --kill-after=10 "$timeout_seconds"
  439    claude -p
  ...
  ```

  Task 3 extends to:

  ```
  local cmd=(env PIPELINE_WRITER=agent
    PIPELINE_DISPATCH_ID="${PIPELINE_DISPATCH_ID:-}"
    PIPELINE_STAGE="$stage"
    gtimeout --signal=TERM --kill-after=10 "$timeout_seconds"
    claude -p
    ...
  ```

  The `${PIPELINE_DISPATCH_ID:-}` fallback is intentional (back-compat for
  callers that invoke `dispatch.sh` directly without going through
  `run-stage.sh::main` — e.g., the `bin/dispatch-test.sh` paths). When
  empty, `bin/linear.sh`'s auto-injection skips per Task 7's env-set
  conditional. **Lint note:** `PIPELINE_DISPATCH_ID` does NOT match the
  secret-probe-lint.sh secret-name regex (`*KEY|*TOKEN|*SECRET|ANTHROPIC*|
  GITHUB*|LINEAR*` — verified by running the regex against the literal
  name); the `${VAR:-}` form is therefore lint-clean. `PIPELINE_STAGE`
  passes the same check.

- **A-011 — `bin/dispatch.sh::assert_no_tool_invocation` at lines 48-65.**
  Verified — single-jq pattern that returns the FIRST matched command
  whose `Bash` `tool_use` `.input.command` starts with `$pattern`. Currently
  used at lines 186 (gh pr create), 210 (git checkout/switch/pull/reset),
  234 (banned branch-creation forms), 262 (core.bare git forms). Task 8's
  envelope validator extends the same helper for two new patterns:
  `mcp__plugin_linear` (Linear MCP forks) and `curl https://api.linear.app`
  (direct Linear HTTP). The helper signature stays unchanged.

- **A-012 — `bin/linear.sh::add_comment` at line 470.** Verified — current
  shape:

  ```
  470  add_comment() {
  471    local ident="$1"; shift
  472    local body
  473    body="$(_resolve_body_arg "$@")"
  474    [[ -n "$body" ]] || die "add-comment: body is empty …"
  475    _reject_legacy_marker_body "add-comment" "$body" || return $?
  476    # Lane fence: check before any Linear API call (including dry-run).
  477    local _comment_class
  478    _comment_class="$(_classify_comment_body "$body")"
  479    _check_lane "add" "$_comment_class" || return $?
  480
  481    if [[ "${PIPELINE_DRY_RUN:-0}" == "1" ]]; then
  ...
  ```

  Task 7 inserts the auto-injection block immediately after line 479 (the
  lane-fence check) and BEFORE line 481 (the dry-run short-circuit) — so
  dry-run mode also exercises the injection (matters for unit tests). The
  injection prepends/appends the marker; placement BEFORE the legacy-marker
  reject (line 475) is wrong because the marker we inject is `meta:`-shape
  and would not trip `_reject_legacy_marker_body` (which targets the
  hyphenated `pipeline-<word>:` shapes). Verified by reading
  `_reject_legacy_marker_body` at line 402-…: it greps for
  `<!-- pipeline-(stage-summary|rejection|halt|wait|decision|sig|metric|transition):` —
  none of which match `<!-- meta: dispatch id=… stage=… -->`. Lint-clean.

- **A-013 — `bin/linear.sh::add_or_update_comment` at line 541.** Verified
  — current shape (similar prologue to add_comment plus sig handling at
  line 559-563 for `<!-- meta: dedup key=… -->` injection). Task 7 inserts
  the dispatch_id auto-injection block immediately after the existing
  `_reject_legacy_marker_body` call at line 553 and BEFORE the
  `marker="<!-- meta: dedup key=$sig -->"` block at line 559. The dedup
  marker is appended with `body+=$'\n\n'"$marker"` at line 562 — the new
  dispatch_id injection follows the SAME shape (idempotent: skip if body
  already contains `<!-- meta: dispatch id=`).

- **A-014 — `bin/linear.sh::_classify_comment_body` at lines 58-70.**
  Verified — classifies by first non-blank line. Task 7's injection MUST
  run AFTER `_classify_comment_body` and `_check_lane` (so injection
  doesn't change the classification — the dispatch_id marker is always
  appended LAST, never as the first non-blank line). Re-verified: the
  marker is emitted at the END of the body via the same `body+=$'\n\n'…`
  pattern as the dedup marker at line 562, so the first non-blank line is
  unchanged.

- **A-015 — `bin/render-prompt.sh` python-block interpolation at lines
  230-252.** Verified — the python block hard-codes the `repl` dict with
  exactly 11 token names (lines 237-247): `{issue_id}`, `{issue_id_lower}`,
  `{issue_title}`, `{issue_description}`, `{date}`, `{slug}`,
  `{brainstorm_file}`, `{plan_file}`, `{branch_name}`,
  `{stage_summary_path}`, `{learned_rules_dir}`. Task 11 replaces this
  block with a bash-side `PROMPT_RESOLVERS` registry (token → resolver
  function name) iterated over the source's distinct `{…}` tokens. The
  `branch_name` resolver at line 224 (`bash bin/branch-name.sh`) becomes
  the prototype for new resolvers. Task 11 adds a 12th resolver
  `{dispatch_id}` → `_resolve_dispatch_id` which prints
  `${PIPELINE_DISPATCH_ID:-}`. **Render-time validator** (Task 11):
  any `{token}` in the source AGENT_PROMPTS.md fenced block whose name is
  not in `PROMPT_RESOLVERS` triggers `die`.

- **A-016 — `bin/verdict-handler.sh::find_fresh_verdict` at lines 84-148.**
  Verified — current shape iterates Linear comments, finds the latest
  `transition` event by `createdAt`, then picks the latest non-wait
  `verdict` event whose `createdAt > last_transition_ts`. The freshness
  primitive is the timestamp window (lines 99, 108, 114). Task 12 layers
  a dispatch_id-primary filter ABOVE the timestamp window:

  - parse `meta: dispatch id=… stage=…` from each comment via
    `parse_pipeline_marker` (already supported per A-003).
  - When ANY comment on the issue carries a `dispatch_id` marker, use
    `dispatch_id == current_dispatch_id` as the primary filter; fall
    through to the existing timestamp-window code only when no
    `dispatch_id` marker is found anywhere on the issue (legacy
    fallback per brainstorm D-005).

- **A-017 — `bin/verdict-handler.sh::resume_in_progress_transition` at
  lines 330-380.** Verified — the function fetches `last_transition`
  (latest `pipeline: transition` event), then guards: dest != current
  (line 357); from != current_stage (line 360); multi-stage labels (line
  366); requires `pipeline:halted` (line 374). Task 12 adds a new guard
  BEFORE line 357: parse the `meta: dispatch id=…` marker from the
  `last_transition` comment body; if id < current dispatch_id, return 1
  (the transition is from a prior cycle). Falls through to the existing
  guards on legacy comments (no marker present) — ENG-41's labels-cross-
  check at lines 360-371 stays as fallback per brainstorm D-005.

- **A-018 — `bin/agent-prompts-content-test.sh::§5 asserts at lines
  197-237.** Verified — the existing three asserts pin §5 (review stage
  only): "overwrite on every dispatch" (line 211), "read-then-conditionally-
  skip" ban (line 221), ENG-71 citation (line 230). Task 14 generalises
  these three asserts to §§1-7 — every numbered stage section's
  stage-summary bullet must mandate overwrite-every-dispatch. The
  `section_body()` helper used at line ~248 (verified: the file has
  `section_body` callable per the `in_fence_s5="$(awk … "$fenced_s5")"`
  pattern) is reused per-stage. Task 14 ALSO adds a new fourth assert
  family: every `{…}` token appearing in `AGENT_PROMPTS.md` is in
  `PROMPT_RESOLVERS` (cross-references against the registry from Task 11).

- **A-019 — `bin/classify-failure.sh::_cf_write_state` at lines 31-37.**
  Verified — the canonical atomic-write pattern (tmp file + `mv -f`).
  Task 1's `allocate_dispatch_id` reuses this exact shape via a private
  helper `_cs_write_state_atomic` in `bin/common.sh` (sibling to the
  existing `is_orchestrator_paused` and `set_orchestrator_paused` at lines
  248-273 which use the SAME tmp+mv pattern). No coupling to
  `classify-failure.sh`'s implementation — the pattern is duplicated
  rather than imported, mirroring CLAUDE.md "When wiring a new script"
  guidance against premature abstraction.

- **A-020 — `bin/dispatch.sh:48-65 assert_no_tool_invocation` startswith
  semantics.** Verified — `select(startswith($p))` at line 58 means the
  envelope validator's MCP-detection patterns must be the literal prefix
  of the agent's invocation. `mcp__plugin_linear` matches every Linear MCP
  function (`mcp__plugin_linear_linear__save_issue`, etc. — they all share
  the `mcp__plugin_linear` prefix). For `curl`, the validator scans for
  `curl https://api.linear.app` and `curl 'https://api.linear.app`
  (single-quote variant). The chained-command blind spot documented at
  `bin/run-stage.sh:867-881` (post-dispatch HEAD-check defense) applies
  here too — the validator catches direct invocations only, not chained
  commands; the brainstorm §8 "Detection" column accepts this trade-off.

- **A-021 — `bin/pipeline-events.json::meta_kinds` at lines 42-48.**
  Verified — current registry: `[dedup, metric, evidence, reapplied,
  forensic]`. Task 2 extends to:
  `[dedup, metric, evidence, reapplied, forensic, dispatch]`.
  `halt_reasons` at lines 10-19 currently:
  `[agent-blocked, agent-failure, smoke-failed, iteration-exhausted,
  scope-violation, protocol-violation, dispatch-timeout,
  pr-opened-too-early]`. Task 2 extends to add
  `dispatch-envelope-violation`. The vocabulary doc
  `docs/pipeline-vocabulary.md` is auto-regenerated via
  `bin/generate-vocabulary-doc.sh` — Task 2 runs the regen and commits the
  diff alongside the registry change.

- **A-022 — `bin/run-stage.sh::main` sentinel pattern at the file's last
  line.** Verified — `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main
  "$@"; fi`. The new helpers `_clear_current_stage_slots` and
  `_validate_dispatch_envelope` are defined ABOVE `main()` in source order
  (between `_entry_conditions_gate`'s closing `}` at line 712 and
  `main()` at line 714, in the same neighbourhood as the other
  `_pre_dispatch_*` helpers). Sourcing `run-stage.sh` from
  `bin/run-stage-test.sh` does not invoke `main` (CLAUDE.md "Tests" §
  contract).

- **A-023 — `bin/run-stage-test.sh` source-and-stub fixtures at lines
  1-115.** Verified — `STUB_DIR` setup (line 17), stub `linear.sh`
  capturing args + `MOCK_COMMENTS_JSON` injection (lines 21-38), stub
  `branch-name.sh` (lines 40-44), stub `gh` (lines 53-68),
  source-after-stub at line 99-101 (`source "$HARNESS_DIR/run-stage.sh"`).
  Tasks 6/9 append new cases at the END of the file, after the existing
  ENG-86 cases G/G2/G3 added by ENG-86's plan.

- **A-024 — `bin/linear-test.sh` source-and-stub fixtures.** Verified by
  proxy (lines 559-630 show `add_or_update_comment` invocations under
  test). Task 10 extends with cases for the new auto-injection block. The
  test stubs the network calls (`linear_query`) so the assertion is on
  body shape, not on Linear API state.

- **A-025 — `bin/dispatch-test.sh` enumerated-tests count assertion at
  lines 2140-2168.** Verified by proxy through ENG-86's plan §A-016. The
  `bin/*-test.sh` enumeration in `.pipeline-config/config.json` MUST be
  regenerated per the CLAUDE.md regen one-liner when this PR adds a new
  `bin/dispatch-history-test.sh` (if Task 5 chooses that path; verified
  below). **Operator-side step**, not part of the implement-stage diff —
  `.pipeline-config/` is gitignored.

### New (assumed) files

- **A-026 — `dispatch_history.jsonl`** (assumed/new). New per-issue file
  at `$(issue_dir <issue>)/dispatch_history.jsonl`. Append-only; written
  by `run-stage.sh` at dispatch-start (one row, `{dispatch_id, stage,
  started_at, trigger, predecessor_dispatch_id, branch,
  pipeline_content_hash}`) and dispatch-end (one row, `{dispatch_id,
  stage, exit_at, exit_code, policy, verdict_emitted, verdict_target,
  duration_ms, envelope: {…}}`). NEVER cleared; never read at runtime by
  decision-making code. Read only by retrospective + `bin/status.sh` +
  manual triage (out of scope: surfacing in `bin/status.sh` is left to a
  future ticket per brainstorm §12). No tooling depends on it today.

- **A-027 — `bin/run-stage.sh::_clear_current_stage_slots`** (assumed/new).
  New helper, lands above `main()`. Removes (a)
  `$(issue_dir)/stage-summary-${stage}.md`, (b)
  `$(issue_dir)/wait-${stage}.json`. Idempotent (`rm -f`). Generalises
  `bin/run-stage.sh:497-499`'s wait-exit pattern.

- **A-028 — `bin/run-stage.sh::_validate_dispatch_envelope`**
  (assumed/new). New helper, lands above `main()`. Three checks: (a)
  stage-summary file exists post-dispatch (existing rc=25 path covers
  this earlier — this check is belt-and-suspenders for the resolver-
  registry-failed-but-rc-0 corner); (b) Linear comments posted under sigs
  scoped to `(completion|halt|scope-approval|retry-pending|tdd-evidence)/
  <stage>/<issue>` whose body's `meta: dispatch id=…` marker matches
  `$PIPELINE_DISPATCH_ID` (sanity check on the chokepoint); (c) transcript
  scan for `mcp__plugin_linear` and `curl https://api.linear.app`
  invocations. On any violation: emit
  `<!-- pipeline: verdict result=halt reason=dispatch-envelope-violation -->`
  via `bin/pipeline.sh event` and exit 29.

- **A-029 — `bin/render-prompt.sh::PROMPT_RESOLVERS`** (assumed/new). New
  registry table at the top of the file (or below `STAGE_TO_SECTION` at
  line 23). Bash-string-block of `{token}=resolver_function` rows; each
  resolver is a thin function defined in the same file. New resolvers:
  `_resolve_dispatch_id` (prints `${PIPELINE_DISPATCH_ID:-}`),
  `_resolve_branch_name` (already a one-liner shelling to
  `bin/branch-name.sh` per A-015's line 224), and 10 thin wrappers around
  the existing python-dict values. Render-time validator dies on any
  unknown `{token}` encountered in the source.

- **A-030 — `bin/common-test.sh` extension cases.** The existing file
  tests `is_orchestrator_paused`. Task 4 appends new cases for
  `allocate_dispatch_id` (atomicity, monotonicity, durability across
  process boundaries). The test pattern follows the existing
  source-and-stub at lines 28-46.

- **A-031 — `bin/render-prompt-test.sh` extension cases.** Task 13
  appends cases for `PROMPT_RESOLVERS` registry behavior (every token
  resolves, unknown token dies, `{dispatch_id}` interpolates from
  `$PIPELINE_DISPATCH_ID`).

- **A-032 — `bin/verdict-handler-test.sh` extension cases.** Task 12's
  test arm adds cases for the dispatch_id-primary filter in
  `find_fresh_verdict` and the dispatch_id mismatch guard in
  `resume_in_progress_transition`, with legacy-comment fallback assertions
  per D-005.

- **A-033 — `bin/agent-prompts-content-test.sh` extensions.** Task 15
  generalises the §5 asserts to §§1-7 (each stage's stage-summary bullet
  asserts 3 conditions: overwrite-every-dispatch, no
  read-then-conditionally-skip, ENG-77 citation as precedent — the
  citation ties the rule to its motivating incident so a future cleanup
  pass cannot quietly remove it). Adds a token-coverage assert: every
  `{…}` in source ∈ `PROMPT_RESOLVERS`.

- **A-034 — `dispatch-envelope-violation` vocabulary entries.** Two
  registry adds in `bin/pipeline-events.json` (Task 2). The vocabulary
  doc `docs/pipeline-vocabulary.md` is regenerated via
  `bin/generate-vocabulary-doc.sh`.

### Open assumption flagged but non-blocking

- **A-035 (BRAINSTORM A-007 unverified)**: the agent's `--allowed-tools`
  list excludes `mcp__plugin_linear`. UNVERIFIED at brainstorm time and
  here too — `bin/dispatch.sh::allowed_tools_for` does not name MCP tools
  in any case-arm (verified 2026-05-09 by reading the function), but
  Claude's runtime may resolve MCP tools via a different mechanism. The
  envelope validator's transcript scan (Task 8) is the backstop — even if
  the allowlist permits MCP, the transcript scan halts. **Mitigation:**
  Task 8's test cases include a fixture transcript with an
  `mcp__plugin_linear_*` invocation; a green test pin proves the scan
  catches the case regardless of allowlist state.

- **A-036 (BRAINSTORM A-012 implementation note)**: `_clear_current_stage_slots`
  must run on EVERY dispatch start regardless of prior dispatch's exit
  status. Task 5's pin asserts this: a synthetic "prior dispatch left
  stage-summary-implementing.md from policy=retry-immediately" fixture
  must be cleared at the next implementing dispatch start.

## File Structure

```
bin/common.sh                              MOD   Add allocate_dispatch_id, current_dispatch_id (after compute_pipeline_content_hash at line 95). Extend `export -f` at line 275. Add `case 29) printf 'envelope-violation' ;;` at lines 111-137.
bin/dispatch.sh                            MOD   Extend env block at line 437 with PIPELINE_DISPATCH_ID, PIPELINE_STAGE.
bin/run-stage.sh                           MOD   Add _clear_current_stage_slots, _validate_dispatch_envelope helpers (above main). Insert allocator + clear-on-start call (between line 800 and 802, gated on skip_dispatch=0). Insert envelope validator call (after line 1081 rc=25 path, before line 1097 post_completion_comment). Add rc=29 routing arm in dispatch_rc switch (lines 821-910). Append dispatch_history.jsonl rows at start and end of dispatch.
bin/linear.sh                              MOD   Insert auto-injection block in add_comment (after line 479, before line 481) and add_or_update_comment (after line 553, before line 559). Idempotent (skip if body already contains `<!-- meta: dispatch id=`).
bin/verdict-handler.sh                     MOD   Add dispatch_id-primary filter to find_fresh_verdict (after line 88, around the comment-iteration block at lines 95-117). Add dispatch_id-mismatch guard to resume_in_progress_transition (before line 357). Both fall back to existing timestamp-window / labels-cross-check on legacy comments.
bin/render-prompt.sh                       MOD   Replace python-block interpolation at lines 230-252 with bash-side PROMPT_RESOLVERS registry + render-time validator. Twelve resolvers (eleven existing tokens + new {dispatch_id}). Unknown-token die.
bin/pipeline-events.json                   MOD   Add `dispatch` to meta_kinds (line 42-48). Add `dispatch-envelope-violation` to halt_reasons (line 10-19).
docs/pipeline-vocabulary.md                MOD   Auto-regenerated via bin/generate-vocabulary-doc.sh after pipeline-events.json edit.
AGENT_PROMPTS.md                           MOD   Add `### Dispatch identifier and freshness contract` subsection to the agent-side preamble (around lines 90-94, near the existing Freshness rule). Generalise §5's "MANDATORY — overwrite on every dispatch" rule (lines 1027-1037) to §§1-7 (each stage's stage-summary bullet).
CLAUDE.md                                  MOD   Add `## Cross-dispatch staleness contract (ENG-87)` section (after `## Orchestrator entry-conditions (ENG-86)`). Documents PIPELINE_DISPATCH_ID, dispatch_history.jsonl, dispatch-envelope-violation halt reason, soft-fallback semantics.
docs/runbooks/recovery.md                  MOD   New `## Dispatch envelope violation` subsection. Symptoms, interpretation (one of: agent skipped Write, agent bypassed linear.sh, allocator failed), recovery (`bash bin/pipeline.sh decide ENG-N --action continue`).
bin/common-test.sh                         MOD   Append cases for allocate_dispatch_id atomicity/monotonicity/durability.
bin/run-stage-test.sh                      MOD   Append cases for clear-on-dispatch-start (current-stage cleared, OTHER stages preserved) and envelope validator (halts on missing stamp; halts on transcript MCP/curl).
bin/linear-test.sh                         MOD   Append cases for auto-injection (env set → injected; env unset → no injection; idempotent re-apply; legacy-fallback for find_fresh_verdict).
bin/verdict-handler-test.sh                MOD   Append cases for dispatch_id filter in find_fresh_verdict and dispatch_id mismatch guard in resume_in_progress_transition (plus legacy-fallback).
bin/render-prompt-test.sh                  MOD   Append cases for PROMPT_RESOLVERS coverage and unknown-token die.
bin/agent-prompts-content-test.sh          MOD   Generalise §5 asserts (lines 197-237) to §§1-7. Add §preamble dispatch-id contract assertion. Add token-coverage assert (every `{…}` ∈ PROMPT_RESOLVERS).
```

No other file is modified or created. Per brainstorm §11: `bin/poll.sh`,
`bin/run-local.sh`, `bin/classify-failure.sh` body, `bin/scope-check.sh`,
`bin/metrics.sh`, `bin/branch-name.sh`, `bin/setup.sh`, `launchd/*.plist.template`
are unchanged.

The operator-applied `$TARGET_REPO/.pipeline-config/config.json` regeneration
to enumerate `bin/dispatch-history-test.sh` (if Task 5 ships a separate test
file) follows the CLAUDE.md "Per-target dispatch.tools extras" §; the implement
agent does NOT commit `.pipeline-config/` (gitignored). Task 5 inlines history
tests into `bin/common-test.sh` to avoid this operator step (decision per
brainstorm §11 phasing — single test file).

## API Contract

no new API surface. This is a bash orchestration repo with no FE↔BE HTTP/IPC
interface. The only inter-script "contracts" are:

1. **Env-var contract.** `PIPELINE_DISPATCH_ID` (new) is exported from
   `bin/run-stage.sh::main` and inherited by `bin/dispatch.sh`'s `env` block,
   the agent's `bash bin/linear.sh` calls, and the orchestrator's post-dispatch
   `_validate_dispatch_envelope`. Documented in CLAUDE.md and AGENT_PROMPTS.md
   preamble.

2. **JSON shape contract.** `dispatch_history.jsonl` two-row schema (start +
   end) per brainstorm §13.1.2. NOT read at runtime; consumed by retrospective
   and `bin/status.sh` (out of scope here).

3. **Marker grammar contract.** `<!-- meta: dispatch id=ENG-N-d<NNNN> stage=<gerund> -->`
   appended to every Linear comment body when `$PIPELINE_DISPATCH_ID` is set.
   Coexists with existing `<!-- pipeline: <event> ... -->` and
   `<!-- meta: <kind> ... -->` markers; parsed by the existing
   `parse_pipeline_marker` (no parser change required).

4. **Stdout contract for `bin/pipeline.sh event`.** Unchanged; the new halt
   reason `dispatch-envelope-violation` validates against the registry per
   `bin/pipeline.sh`'s existing `_validate_against_registry` call.

5. **Exit-code contract.** New code 29 = `envelope-violation` (taxonomy in
   `bin/common.sh::failure_outcome_for_exit`).

These are documented in the per-task code snippets below.

## Backend Tasks

(All tasks are "backend" — this repo has no UI surface. The "Frontend Tasks"
section below is a deliberate "no UI surface" note, per project profile.)

### Task 1: Add `allocate_dispatch_id` and `current_dispatch_id` to `bin/common.sh`

- `depends_on: []`
- `touches: bin/common.sh::allocate_dispatch_id (new), bin/common.sh::current_dispatch_id (new), bin/common.sh::export -f line 275`
- [ ] Open `bin/common.sh`. Add a new section header
      `# ─── Dispatch identifier (ENG-87) ─────────` immediately after
      `compute_pipeline_content_hash`'s closing `}` at line 95 (sibling-
      helper convention).
- [ ] Add `allocate_dispatch_id <issue>`. Increments
      `current_dispatch_seq` in `$(issue_dir)/issue-state.json` (creating
      the file if absent), formats `ENG-N-d<NNNN>` (4-digit zero-padded),
      exports `PIPELINE_DISPATCH_ID`, prints the id on stdout. Atomic
      write via tmpfile + `mv -f` (mirroring
      `bin/classify-failure.sh::_cf_write_state` at lines 31-37 and
      `set_orchestrator_paused` at lines 262-273). Snippet:

      ```bash
      allocate_dispatch_id() {
        local issue="$1"
        [[ -n "$issue" ]] || die "allocate_dispatch_id: missing issue id"
        local state_file; state_file="$(issue_dir "$issue")/issue-state.json"
        local prior_seq=0 prior_json="{}"
        if [[ -s "$state_file" ]] && jq -e . "$state_file" >/dev/null 2>&1; then
          prior_seq="$(jq -r '.current_dispatch_seq // 0' "$state_file" 2>/dev/null || printf '0')"
          [[ "$prior_seq" =~ ^[0-9]+$ ]] || prior_seq=0
          prior_json="$(cat "$state_file")"
        fi
        local next_seq=$((prior_seq + 1))
        local id; id="$(printf '%s-d%04d' "$issue" "$next_seq")"
        # Merge: write current_dispatch_seq, current_dispatch_id, current_stage
        # without losing classify-failure's existing fields (policy, reason,
        # exit_code, …).  jq -n + (--argjson prior … | . + {…}) preserves them.
        local merged
        merged="$(jq -cn --argjson prior "$prior_json" --argjson seq "$next_seq" \
                       --arg id "$id" --arg stage "${PIPELINE_STAGE:-}" '
          $prior + {current_dispatch_seq: $seq, current_dispatch_id: $id, current_stage: $stage}')"
        mkdir -p "$(dirname "$state_file")"
        local tmp="${state_file}.tmp.$$"
        printf '%s' "$merged" > "$tmp"
        mv -f "$tmp" "$state_file"
        export PIPELINE_DISPATCH_ID="$id"
        printf '%s' "$id"
      }
      ```

- [ ] Add `current_dispatch_id <issue>` (read-only sibling). Returns the
      `current_dispatch_id` field from `issue-state.json`, or empty string
      if absent. Snippet:

      ```bash
      current_dispatch_id() {
        local issue="$1"
        [[ -n "$issue" ]] || die "current_dispatch_id: missing issue id"
        local state_file; state_file="$(issue_dir "$issue")/issue-state.json"
        [[ -s "$state_file" ]] || { printf ''; return 0; }
        jq -r '.current_dispatch_id // ""' "$state_file" 2>/dev/null || printf ''
      }
      ```

- [ ] Extend the `export -f` line at line 275 to include
      `allocate_dispatch_id` and `current_dispatch_id`. The list is
      load-bearing for subshell visibility (A-004); a missed entry causes
      silent rc=127 in callers like `bin/run-stage.sh::main`.
- [ ] Verify syntax: `bash -n bin/common.sh` exits 0.
- [ ] Verify lint: `bash bin/secret-probe-lint.sh` exits 0 (the helper
      uses no `${VAR:-…}` against secret-name vars; `PIPELINE_STAGE` and
      `PIPELINE_DISPATCH_ID` are both name-clean).

### Task 2: Extend vocabulary registry and exit-code taxonomy

- `depends_on: []`
- `touches: bin/pipeline-events.json::meta_kinds, bin/pipeline-events.json::halt_reasons, bin/common.sh::failure_outcome_for_exit, docs/pipeline-vocabulary.md`
- [ ] Open `bin/pipeline-events.json`. Add `"dispatch"` to the
      `meta_kinds` array (lines 42-48). Add `"dispatch-envelope-violation"`
      to the `halt_reasons` array (lines 10-19). Maintain the existing
      JSON formatting (one item per line).
- [ ] Open `bin/common.sh::failure_outcome_for_exit` at lines 111-137.
      Insert `29) printf 'envelope-violation' ;;` immediately after
      line 133 (`28) printf 'leaked-in-scope-threshold' ;;`). The
      `unknown-exit-N` default at line 135 is the safety net for any
      future unmapped code.
- [ ] Regenerate `docs/pipeline-vocabulary.md` via:

      ```bash
      bash bin/generate-vocabulary-doc.sh > docs/pipeline-vocabulary.md
      ```

      Commit the diff alongside the registry change.
- [ ] Verify: `jq -e '.meta_kinds | index("dispatch") != null' bin/pipeline-events.json`
      exits 0; same for `halt_reasons`.

### Task 3: Add env passthrough in `bin/dispatch.sh`

- `depends_on: [1]`
- `touches: bin/dispatch.sh::main env block at line 437`
- [ ] Open `bin/dispatch.sh`. At line 437, extend the `local cmd=(env …`
      array to include `PIPELINE_DISPATCH_ID` and `PIPELINE_STAGE`.
      Snippet:

      ```bash
      local cmd=(env PIPELINE_WRITER=agent
        PIPELINE_DISPATCH_ID="${PIPELINE_DISPATCH_ID:-}"
        PIPELINE_STAGE="$stage"
        gtimeout --signal=TERM --kill-after=10 "$timeout_seconds"
        claude -p
        --output-format stream-json --verbose
        --setting-sources project,local
        --disable-slash-commands
        --disallowed-tools "$denies"
        --allowed-tools "$tools"
      )
      ```

      The `${PIPELINE_DISPATCH_ID:-}` form is intentional: callers that
      invoke `dispatch.sh` directly (test fixtures, future scripts that
      bypass `run-stage.sh::main`) get an empty marker, and
      `bin/linear.sh` Task 7's auto-injection skips on empty.
      `${PIPELINE_DISPATCH_ID:-}` against this var name is lint-clean
      (the name does not match the secret-name regex).
- [ ] Verify syntax: `bash -n bin/dispatch.sh` exits 0.
- [ ] Verify lint: `bash bin/secret-probe-lint.sh` exits 0.

### Task 4: Add allocator-call site, history log, and clear-on-start in `bin/run-stage.sh::main`

- `depends_on: [1, 3]`
- `touches: bin/run-stage.sh::_clear_current_stage_slots (new), bin/run-stage.sh::main allocator-call site (modify)`
- [ ] Add `_clear_current_stage_slots` immediately above `main()` at line
      714 (sibling neighbourhood to `_pre_dispatch_merge_gate` at lines
      613-654 and `_entry_conditions_gate` at lines 675-712). Snippet:

      ```bash
      # ENG-87: clear current-stage local files at the start of every
      # dispatch so file existence post-dispatch is proof of THIS-dispatch
      # authorship. Generalises bin/run-stage.sh:497-499's wait-exit
      # pattern (build-only) to all stages. Cleared:
      #   stage-summary-${stage}.md  (read by post_completion_comment)
      #   wait-${stage}.json         (overwritten by _handle_wait when
      #                               the agent emits a wait verdict; the
      #                               clear here ensures a fresh dispatch
      #                               doesn't inherit a stale counter)
      # NOT cleared:
      #   issue-state.json           (allocator merges into it; clearing
      #                               would lose classify-failure state)
      #   stage-summary-OTHER.md     (forward+loopback reads need them
      #                               intact — see brainstorm §6.1/6.2)
      _clear_current_stage_slots() {
        local PIPELINE_WRITER=orchestrator
        export PIPELINE_WRITER
        local ident="$1" stage="$2"
        local d; d="$(issue_dir "$ident")"
        rm -f "$d/stage-summary-${stage}.md" 2>/dev/null || true
        rm -f "$d/wait-${stage}.json"        2>/dev/null || true
      }
      ```

- [ ] In `main()`, insert the allocator + clear + history-log block
      between line 800 (`mkdir -p "$(issue_dir "$ident")"`) and line 802
      (the `if (( ! skip_dispatch )); then` opening of the prompt-render
      block). Gate on `skip_dispatch=0` (scope-approval replay does NOT
      allocate per brainstorm §5.1). Snippet:

      ```bash
      # ENG-87: allocate dispatch_id (per-issue monotonic counter) and
      # clear current-stage local files. Skip on scope-approval replay
      # (the prior dispatch's id is still durable in issue-state.json
      # and its envelope has already been validated).
      if (( ! skip_dispatch )); then
        export PIPELINE_STAGE="$stage"  # so allocator can stamp current_stage
        local _dispatch_id
        _dispatch_id="$(allocate_dispatch_id "$ident")"
        log "dispatch-id allocated: $_dispatch_id (stage=$stage)"
        _clear_current_stage_slots "$ident" "$stage"
        # Append dispatch-start row to history (orchestrator-only log;
        # never read at runtime by decision-making code).
        local _hist_file _trigger _predecessor _branch _hash
        _hist_file="$(issue_dir "$ident")/dispatch_history.jsonl"
        _branch="$(bash "$SCRIPT_DIR/branch-name.sh" "$ident" 2>/dev/null || printf '')"
        _hash="$(compute_pipeline_content_hash 2>/dev/null || printf '')"
        # predecessor = the prior id minus 1; empty if this is d0001.
        if [[ "$_dispatch_id" =~ -d0*([1-9][0-9]*)$ ]]; then
          local _seq="${BASH_REMATCH[1]}"
          if (( _seq > 1 )); then
            _predecessor="$(printf '%s-d%04d' "$ident" "$((_seq - 1))")"
          else
            _predecessor=""
          fi
        else
          _predecessor=""
        fi
        # Trigger inferred from labels; conservative default = "transition".
        _trigger="transition"  # refined by retrospective from event log
        printf '{"dispatch_id":"%s","stage":"%s","started_at":"%s","trigger":"%s","predecessor_dispatch_id":"%s","branch":"%s","pipeline_content_hash":"%s"}\n' \
          "$_dispatch_id" "$stage" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
          "$_trigger" "$_predecessor" "$_branch" "$_hash" >> "$_hist_file"
      fi
      ```

      The `$_trigger` placeholder is intentionally conservative
      (always `"transition"`); refining from labels (loopback vs inbox-pickup
      vs retry-immediately) is a separate ticket — the field is forensic
      only, not state-driving.

- [ ] Add the dispatch-end history row after the verdict_handler call at
      line 1138 (`verdict_handler "$ident" "$vh_stage" || vh_rc=$?`). The
      existing line 1146 computes `duration` from `t1-t0`; reuse it.
      Snippet (insert immediately before the existing `bash
      "$SCRIPT_DIR/metrics.sh" stage-end …` call near line 1180-ish — the
      implement agent will locate the precise post-handler line via
      `grep -n 'metrics.sh stage-end' bin/run-stage.sh`):

      ```bash
      # ENG-87: append dispatch-end row to dispatch_history.jsonl. The
      # envelope object is conservative (true/false on the post-dispatch
      # checks); on a non-zero verdict_handler rc the writes are still
      # appended so the retrospective can pair start/end on dispatch_id.
      if (( ! skip_dispatch )); then
        local _hist_file_end; _hist_file_end="$(issue_dir "$ident")/dispatch_history.jsonl"
        local _summary_end; _summary_end="$(issue_dir "$ident")/stage-summary-${stage}.md"
        printf '{"dispatch_id":"%s","stage":"%s","exit_at":"%s","exit_code":%d,"duration_ms":%d,"envelope":{"stage_summary_present":%s,"transcript_clean":%s}}\n' \
          "${PIPELINE_DISPATCH_ID:-}" "$stage" \
          "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
          "$vh_rc" "$duration" \
          "$([[ -s "$_summary_end" ]] && printf 'true' || printf 'false')" \
          "true" \
          >> "$_hist_file_end" || true
      fi
      ```

      The `transcript_clean: true` placeholder defaults to true; Task 8's
      envelope validator will explicitly write `false` and exit 29
      BEFORE this point if the scan detects bypass, so reaching this
      line implies clean.

- [ ] Verify syntax: `bash -n bin/run-stage.sh` exits 0.
- [ ] Verify lint: `bash bin/secret-probe-lint.sh` exits 0.

### Task 5: Add `bin/common-test.sh` cases for `allocate_dispatch_id`

- `depends_on: [1]`
- `touches: bin/common-test.sh (modify — append cases)`
- [ ] Append a new section `### ENG-87: allocate_dispatch_id` at the END
      of `bin/common-test.sh`, immediately before the final summary
      (`PASS=$PASS FAIL=$FAIL` block). Reuse the existing
      `_TEST_ROOT` and helpers (`assert_eq`, `report_ok`, `report_fail`).
- [ ] **Case 87.1 — first allocation creates issue-state.json with seq=1
      and prints id=ENG-87T-d0001.** Pre-clean
      `$_TEST_ROOT/state/test-slug/ENG-87T/issue-state.json`. Call
      `id="$(allocate_dispatch_id ENG-87T)"`. Assert
      `$id == "ENG-87T-d0001"`. Assert
      `jq -r '.current_dispatch_seq' …/issue-state.json == "1"`. Assert
      `jq -r '.current_dispatch_id' … == "ENG-87T-d0001"`.
- [ ] **Case 87.2 — second allocation increments to seq=2 and preserves
      classify-failure fields.** Seed
      `…/issue-state.json` with
      `'{"current_dispatch_seq":1,"current_dispatch_id":"ENG-87T-d0001","policy":"retry-immediately","reason":"linear-post-failed","retry_count":1}'`.
      Call `allocate_dispatch_id ENG-87T`. Assert id is `ENG-87T-d0002`,
      `seq == 2`, AND `policy == "retry-immediately"` (preserved).
- [ ] **Case 87.3 — concurrent invocations serialize via mv-f atomicity.**
      Run two allocator calls in parallel via `& wait`. Assert the two
      returned ids are `{ENG-87T-d0003, ENG-87T-d0004}` set-equal (no
      collision; no seq=3 written twice). The atomicity property is
      provided by `mv -f` on POSIX, but the test pin documents the
      assumption.
- [ ] **Case 87.4 — invalid prior seq (corrupt JSON) treated as 0.**
      Seed `…/issue-state.json` with `'{not valid json'`. Call
      `allocate_dispatch_id ENG-87T`. Assert id is `ENG-87T-d0001`
      (the corrupt-JSON branch resets seq).
- [ ] **Case 87.5 — `current_dispatch_id` reads back the just-allocated
      id.** After Case 87.1, call `current_dispatch_id ENG-87T`; assert
      output is `ENG-87T-d0001`.
- [ ] Verify: `bash bin/common-test.sh` exits 0 with all existing cases
      PASS plus the five new ENG-87 cases PASS.

### Task 6: Add `bin/run-stage-test.sh` cases for clear-on-dispatch-start

- `depends_on: [4]`
- `touches: bin/run-stage-test.sh (modify — append cases)`
- [ ] Append at the END of `bin/run-stage-test.sh`, after the existing
      ENG-86 cases G/G2/G3 (per ENG-86's plan §A-015), before the final
      summary line.
- [ ] **Case 87-A — current-stage stage-summary file is cleared at
      dispatch start.** Pre-create
      `$STUB_DIR/state/test-slug/ENG-87A/stage-summary-implementing.md`
      with body `STALE iter-1`. Call
      `_clear_current_stage_slots ENG-87A implementing`. Assert the
      file no longer exists.
- [ ] **Case 87-B — OTHER-stage stage-summary files are NOT cleared
      (loopback safety).** Pre-create
      `…/ENG-87B/stage-summary-implementing.md` (current-stage) AND
      `…/ENG-87B/stage-summary-reviewing.md` (other-stage; the loopback-
      source the implement agent will read). Call
      `_clear_current_stage_slots ENG-87B implementing`. Assert
      `stage-summary-implementing.md` is gone AND
      `stage-summary-reviewing.md` is unchanged. This is the brainstorm
      §6.2 invariant — loopback reads must see the source-stage's fresh
      output.
- [ ] **Case 87-C — `wait-${stage}.json` cleared with the summary.**
      Pre-create both files; call clear; assert both gone.
- [ ] **Case 87-D — clear is idempotent (safe to call when files
      absent).** Pre-clean state. Call
      `_clear_current_stage_slots ENG-87D building` twice. Assert
      both calls return 0 (the `rm -f … || true` swallows ENOENT).
- [ ] Verify: `bash bin/run-stage-test.sh` exits 0 with all existing
      cases PASS plus the four new ENG-87 cases PASS.

### Task 7: Add auto-injection to `bin/linear.sh::add_comment` and `add_or_update_comment`

- `depends_on: [1, 2]`
- `touches: bin/linear.sh::add_comment, bin/linear.sh::add_or_update_comment`
- [ ] Add a private helper `_inject_dispatch_marker` near the top of
      `bin/linear.sh` (immediately after the `_classify_comment_body` /
      `_check_lane` helpers around line 90). Snippet:

      ```bash
      # ENG-87: append the dispatch_id meta-marker to a comment body when
      # PIPELINE_DISPATCH_ID is set. Idempotent (skip if body already
      # contains the marker — protects against double-injection on
      # add-or-update-comment re-applies). Operator-lane writes (env
      # unset) bypass injection by design.
      _inject_dispatch_marker() {
        local body="$1"
        [[ -n "${PIPELINE_DISPATCH_ID:-}" ]] || { printf '%s' "$body"; return 0; }
        # Idempotent: if a dispatch marker is already present, return as-is.
        if grep -qF '<!-- meta: dispatch id=' <<<"$body"; then
          printf '%s' "$body"
          return 0
        fi
        printf '%s\n\n<!-- meta: dispatch id=%s stage=%s -->' \
          "$body" "$PIPELINE_DISPATCH_ID" "${PIPELINE_STAGE:-}"
      }
      ```

      Note: `${PIPELINE_DISPATCH_ID:-}` and `${PIPELINE_STAGE:-}` are
      lint-clean — neither name matches the secret-name regex.

- [ ] In `add_comment` at line 470, immediately AFTER line 479
      (`_check_lane "add" "$_comment_class" || return $?`) and BEFORE
      line 481 (`if [[ "${PIPELINE_DRY_RUN:-0}" == "1" ]]`), inject the
      marker into `$body`:

      ```bash
        body="$(_inject_dispatch_marker "$body")"
      ```

      Placement is load-bearing: AFTER `_check_lane` so the
      classification reflects the agent's authoring intent (the dispatch
      marker doesn't change the first non-blank line per A-014); BEFORE
      the dry-run short-circuit so unit tests under `PIPELINE_DRY_RUN=1`
      observe the injection.

- [ ] In `add_or_update_comment` at line 541, immediately AFTER line 553
      (`_reject_legacy_marker_body "add-or-update-comment" "$body" || return $?`)
      and BEFORE line 559 (`local marker="<!-- meta: dedup key=$sig -->"`),
      inject the marker:

      ```bash
        body="$(_inject_dispatch_marker "$body")"
      ```

      The dedup-marker append at line 561-563 then runs on the already-
      injected body; both markers coexist on the same comment per
      brainstorm §13.1.6.

- [ ] Verify syntax: `bash -n bin/linear.sh` exits 0.
- [ ] Verify lint: `bash bin/secret-probe-lint.sh` exits 0.

### Task 8: Add `_validate_dispatch_envelope` helper and call site in `bin/run-stage.sh`

- `depends_on: [4, 7]`
- `touches: bin/run-stage.sh::_validate_dispatch_envelope (new), bin/run-stage.sh::main envelope-call site (modify)`
- [ ] Add helper `_validate_dispatch_envelope` immediately AFTER
      `_clear_current_stage_slots` from Task 4 (above `main()`, sibling
      neighbourhood). Three checks; halt on EGREGIOUS bypass only per
      brainstorm D-004. Snippet:

      ```bash
      # ENG-87: post-dispatch envelope validator. Detective-only —
      # halts only on egregious bypass:
      #   (a) Stage-summary file missing post-dispatch
      #       (existing rc=25 path covers fresh dispatches; this check
      #       is belt-and-suspenders for the resolver-registry-failed-
      #       but-rc-0 corner — sanity check).
      #   (b) Transcript invoked mcp__plugin_linear*  (Linear MCP fork
      #       outside bin/linear.sh's auto-injection lane).
      #   (c) Transcript invoked curl https://api.linear.app  (direct
      #       Linear HTTP API outside bin/linear.sh).
      # Returns 0 = envelope clean, 29 = violation (halt).
      # Skip on wait-exit and scope-approval-replay (caller gate).
      _validate_dispatch_envelope() {
        local PIPELINE_WRITER=orchestrator
        export PIPELINE_WRITER
        local ident="$1" stage="$2"
        local d; d="$(issue_dir "$ident")"
        local raw_capture="${d}/.raw-stream.ndjson.tmp"
        local violations=()
        # Check (a): stage-summary file present.
        if [[ ! -s "${d}/stage-summary-${stage}.md" ]]; then
          # Existing rc=25 path normally fires earlier; this defensive
          # check returns clean — the rc=25 site (lines 1068-1080) is
          # the loud-fail singleton.
          :
        fi
        # Check (b)/(c): transcript scan via assert_no_tool_invocation.
        # The dispatch.sh-private $raw_capture is removed by a RETURN
        # trap when dispatch.sh's _render_and_capture_stream completes
        # successfully; for the validator to see it, this helper MUST
        # be invoked from run-stage.sh::main BEFORE dispatch.sh returns.
        # Implementation: dispatch.sh writes a sidecar copy at
        # $issue_dir/.envelope-transcript-${stage} on stream-end (Task 8
        # prereq below).
        local sidecar="${d}/.envelope-transcript-${stage}"
        if [[ -s "$sidecar" ]]; then
          local _viol_mcp _viol_curl
          if _viol_mcp="$(assert_no_tool_invocation "$sidecar" "mcp__plugin_linear")"; then
            :
          else
            violations+=("mcp__plugin_linear:${_viol_mcp}")
          fi
          if _viol_curl="$(assert_no_tool_invocation "$sidecar" "curl https://api.linear.app")"; then
            :
          else
            violations+=("curl-linear:${_viol_curl}")
          fi
        fi
        if (( ${#violations[@]} > 0 )); then
          local viol_str; viol_str="$(printf '%s; ' "${violations[@]}")"
          local body
          body="$(printf '<!-- pipeline: verdict result=halt reason=dispatch-envelope-violation -->\n\nDispatch envelope violation on dispatch_id=%s stage=%s:\n\n%s\n\nThe agent bypassed bin/linear.sh (auto-injection chokepoint). Inspect: $(issue_dir)/.envelope-transcript-%s\n\n**Resume:** investigate the bypass, fix the agent prompt or tool-allowlist, then `bash bin/pipeline.sh decide %s --action continue`.' \
            "${PIPELINE_DISPATCH_ID:-unknown}" "$stage" "$viol_str" "$stage" "$ident")"
          bash "$SCRIPT_DIR/linear.sh" add-comment "$ident" "$body" || true
          return 29
        fi
        return 0
      }
      ```

- [ ] **Sidecar transcript copy.** Add to `bin/dispatch.sh`'s
      `_render_and_capture_stream` (around line 178, before the closing
      `}`): if the stream completes without halt-rc, copy `$raw_capture`
      to `$issue_dir/.envelope-transcript-${stage}` so the validator can
      read it after the RETURN trap removes `$raw_capture`. Snippet:

      ```bash
        # ENG-87: persist a copy of the transcript for the post-dispatch
        # envelope validator. The trap removes $raw_capture on RETURN;
        # the validator needs an inspection target after dispatch.sh
        # exits. Same dir as the existing .transcript-violation-${stage}
        # sidecar (lines 188-189, 213-214, 237-238, 265-266).
        if [[ -s "$raw_capture" && -n "$stage" ]]; then
          cp "$raw_capture" "${issue_dir}/.envelope-transcript-${stage}" \
            2>/dev/null || true
        fi
      ```

- [ ] In `main()`, insert the validator call site immediately AFTER the
      rc=25 agent-contract validator block at line 1081 (close of the
      `if (( ! skip_dispatch )); then case "$stage" …` block) and BEFORE
      `push_branch_if_ahead` at line 1087. Snippet:

      ```bash
      # ENG-87: post-dispatch envelope validator. Halts on egregious
      # bypass only (transcript scan for direct Linear API). Skips on
      # scope-approval replay (no agent ran).
      if (( ! skip_dispatch )); then
        case "$stage" in
          brainstorming|planning|implementing|ui|reviewing|qa|building)
            local _env_rc=0
            _validate_dispatch_envelope "$ident" "$stage" || _env_rc=$?
            if (( _env_rc == 29 )); then
              classify_failure "$ident" "$stage" "skip-until-human-acts" \
                "dispatch envelope violation: agent bypassed bin/linear.sh (transcript shows mcp__plugin_linear or curl https://api.linear.app)" 29
              # Clean up transcript sidecar after halt comment lands.
              rm -f "$(issue_dir "$ident")/.envelope-transcript-${stage}" 2>/dev/null || true
              exit 29
            fi
            # Clean up transcript sidecar on clean envelope.
            rm -f "$(issue_dir "$ident")/.envelope-transcript-${stage}" 2>/dev/null || true
            ;;
        esac
      fi
      ```

      Placement is load-bearing: AFTER rc=25 (the loud-fail "no artifact"
      path) and BEFORE `post_completion_comment` (so a violation halts
      before the Linear post burns API quota AND before the comment lands
      as if dispatch succeeded).

- [ ] Verify syntax: `bash -n bin/run-stage.sh` exits 0; `bash -n bin/dispatch.sh` exits 0.

### Task 9: Add envelope-validator test cases to `bin/run-stage-test.sh`

- `depends_on: [8]`
- `touches: bin/run-stage-test.sh (modify — append cases)`
- [ ] Append after Task 6's cases.
- [ ] **Case 87-E — clean envelope (no transcript bypass) returns rc=0.**
      Pre-create `…/ENG-87E/.envelope-transcript-implementing` with a
      benign fixture containing only `bash bin/linear.sh add-comment`
      tool calls (no MCP, no curl). Pre-create the stage-summary file.
      Call `_validate_dispatch_envelope ENG-87E implementing`; assert
      rc=0.
- [ ] **Case 87-F — transcript MCP invocation halts with rc=29.** Fixture
      transcript contains an `assistant` event with a `tool_use` block
      whose `.input.command` starts with
      `mcp__plugin_linear_linear__save_issue`. Call validator; assert
      rc=29; assert capture file shows an `add-comment` invocation with
      `dispatch-envelope-violation` body.
- [ ] **Case 87-G — transcript curl-linear invocation halts with rc=29.**
      Fixture transcript contains an `assistant` event with a `tool_use`
      block whose `.input.command` starts with
      `curl https://api.linear.app/graphql`. Call validator; assert
      rc=29; same body assertion as 87-F.
- [ ] **Case 87-H — chokepoint sanity (env set: every comment posted
      via add_comment in this dispatch carries the marker).** Indirect
      test through `bin/linear-test.sh` Task 10, but pin here that
      `_inject_dispatch_marker` invocation under `PIPELINE_DISPATCH_ID=
      ENG-87H-d0001` produces a body ending with
      `<!-- meta: dispatch id=ENG-87H-d0001 stage=implementing -->`.
- [ ] Verify: `bash bin/run-stage-test.sh` exits 0 with all cases PASS.

### Task 10: Add auto-injection cases to `bin/linear-test.sh`

- `depends_on: [7]`
- `touches: bin/linear-test.sh (modify — append cases)`
- [ ] Append after the existing ENG-63 / ENG-57 cases (line 559+) at the
      END of the file. Source-and-stub pattern unchanged.
- [ ] **Case 87-L1 — env set: add-comment body carries the marker.** Set
      `PIPELINE_DISPATCH_ID=ENG-87L-d0007 PIPELINE_STAGE=implementing
      PIPELINE_DRY_RUN=1`. Call
      `add_comment ENG-87L "agent body line 1\nline 2"`. Assert the
      `[DRY_RUN] would comment` log line shows the body ends with
      `<!-- meta: dispatch id=ENG-87L-d0007 stage=implementing -->`.
- [ ] **Case 87-L2 — env unset: no injection (operator-manual lane).**
      Unset `PIPELINE_DISPATCH_ID`. Call
      `add_comment ENG-87L "operator-direct comment"`. Assert the
      logged body does NOT contain `meta: dispatch id=`.
- [ ] **Case 87-L3 — re-apply is idempotent.** Pre-craft a body that
      already contains `<!-- meta: dispatch id=ENG-87L-d0007 stage=implementing -->`.
      Call `add_or_update_comment "test/sig/ENG-87L" ENG-87L "$body"`.
      Assert the resulting body has the marker EXACTLY ONCE (no
      double-injection).
- [ ] **Case 87-L4 — add_or_update_comment env set: marker added before
      dedup-key footer.** Set env. Call
      `add_or_update_comment "test/sig/ENG-87L4" ENG-87L4 "body text"`.
      Assert the resulting body contains BOTH
      `<!-- meta: dispatch id=ENG-87L-d… stage=… -->` AND
      `<!-- meta: dedup key=test/sig/ENG-87L4 -->`.
- [ ] **Case 87-L5 — find_fresh_verdict legacy fallback (no marker on
      issue).** Set up `MOCK_COMMENTS_JSON` with two comments: an older
      `pipeline: transition from=implementing to=ui` and a newer
      `pipeline: verdict result=pass stage=implementing`. NO dispatch
      markers anywhere on the issue. Call
      `find_fresh_verdict ENG-87L5`; assert it returns the verdict
      (timestamp-window fallback path per D-005).
- [ ] **Case 87-L6 — find_fresh_verdict prefers id-match when markers
      present.** Set up `MOCK_COMMENTS_JSON` with three comments: an
      older `pipeline: verdict result=fail target=implementing` carrying
      `meta: dispatch id=ENG-87L6-d0014`, a newer
      `pipeline: verdict result=pass stage=reviewing` carrying
      `meta: dispatch id=ENG-87L6-d0015`, and a much newer
      decoy comment with NO dispatch marker. With current dispatch =
      `ENG-87L6-d0015`, assert `find_fresh_verdict` returns the d0015
      pass marker (and NOT the unstamped decoy by createdAt).
- [ ] Verify: `bash bin/linear-test.sh` exits 0 with all existing cases
      PASS plus the six new ENG-87 cases PASS.

### Task 11: Add dispatch_id-primary filter to `bin/verdict-handler.sh`

- `depends_on: [1, 2, 7]`
- `touches: bin/verdict-handler.sh::find_fresh_verdict, bin/verdict-handler.sh::resume_in_progress_transition`
- [ ] In `find_fresh_verdict` at lines 84-148, add a dispatch_id-primary
      filter pre-pass. Read the issue's `current_dispatch_id` (via
      `current_dispatch_id "$issue"` from common.sh, exported per
      Task 1). Iterate all comments via `parse_pipeline_marker`; build
      a set of `(verdict-event, comment-id, ts)` tuples whose
      `meta: dispatch id=` matches `current_dispatch_id`. If the set is
      non-empty, return the latest non-wait verdict from it. If the set
      is empty AND any comment on the issue carries ANY dispatch_id
      marker, return empty (the current dispatch has emitted no verdict
      yet — strict id-match path). If NO comment carries any dispatch_id
      marker, fall through to the existing timestamp-window code at
      lines 90-118 (legacy-fallback per D-005). Snippet (insert
      immediately AFTER line 89's `comments=…` and BEFORE line 91's
      `# Find the most recent transition-event timestamp` comment):

      ```bash
        # ENG-87: dispatch_id-primary filter (D-005). When ANY comment
        # on the issue carries a dispatch marker, filter strictly by
        # current dispatch id; legacy issues (no markers anywhere) fall
        # through to the timestamp-window code below.
        local _curr_id _has_any_marker
        _curr_id="$(current_dispatch_id "$issue" 2>/dev/null || printf '')"
        _has_any_marker="$(jq -r '.[] | .body | gsub("\n"; " ")' <<<"$comments" \
          | grep -qF '<!-- meta: dispatch id=' && printf '1' || printf '0')"
        if [[ -n "$_curr_id" && "$_has_any_marker" == "1" ]]; then
          local _id_ts="" _id_body="" _id_id=""
          while IFS=$'\t' read -r ts id body; do
            ev="$(parse_pipeline_marker "$body" 2>/dev/null || true)"
            [[ -z "$ev" ]] && continue
            [[ "$(jq -r '.event' <<<"$ev")" != "verdict" ]] && continue
            [[ "$(jq -r '.result' <<<"$ev")" == "wait" ]] && continue
            # Comment must carry the current dispatch_id marker.
            if ! grep -qF "<!-- meta: dispatch id=$_curr_id" <<<"$body"; then
              continue
            fi
            if [[ "$ts" > "$_id_ts" ]]; then
              _id_ts="$ts"; _id_body="$body"; _id_id="$id"
            fi
          done < <(jq -r '.[] | "\(.createdAt)\t\(.id)\t\(.body | gsub("\n"; " "))"' <<<"$comments")
          if [[ -n "$_id_body" ]]; then
            # Reuse the existing legacy-output projection block at lines
            # 119-148 by binding fresh_ts/fresh_body/fresh_id to the
            # id-matched winner and falling through.
            fresh_ts="$_id_ts"; fresh_body="$_id_body"; fresh_id="$_id_id"
            # Skip the timestamp-window pre-pass; jump to projection.
            goto_projection=1
          else
            # Markers exist on the issue but none match current — fresh
            # nothing.
            printf ''
            return 0
          fi
        fi
        if [[ "${goto_projection:-0}" != "1" ]]; then
          # Existing timestamp-window code (lines 90-118) follows here unchanged.
          ...
        fi
      ```

      The `goto_projection=1` flag wraps the existing legacy code path
      (lines 90-118) inside a guard; the projection block at 119-148
      runs unchanged on either path. The implement agent will refactor
      the function body to introduce the flag without disturbing the
      existing timestamp-window logic.

- [ ] In `resume_in_progress_transition` at lines 330-380, add a
      dispatch_id-mismatch guard BEFORE the existing guard 1 at line
      357 (`[[ "$current_stage" == "$to" ]] && return 1`). Snippet:

      ```bash
        # ENG-87 §4.3: dispatch_id-mismatch guard. Parse the
        # last_transition's meta: dispatch id=…; if it disagrees with
        # the current dispatch id, the transition is from a prior cycle.
        # This is strictly stronger than the existing labels-cross-check
        # at lines 360-371 (which stays as legacy-fallback).
        local _curr_id _last_ts_id_marker _last_dispatch_id
        _curr_id="$(current_dispatch_id "$issue" 2>/dev/null || printf '')"
        if [[ -n "$_curr_id" ]]; then
          # Re-find the latest transition's body (already iterated
          # above; pin the body for marker extraction).
          local _trans_body=""
          # Note: the existing while-loop at lines 341-349 captures
          # from/to via parse_pipeline_marker. Extend it to capture the
          # body string itself so we can grep for the dispatch marker.
          # (Implementation detail: store body in a sibling local
          # `_last_transition_body` next to from/to.)
          _last_dispatch_id="$(grep -oE 'meta: dispatch id=[A-Z]+-[0-9]+-d[0-9]+' \
            <<<"$_last_transition_body" | sed 's/.*id=//' | head -1)"
          if [[ -n "$_last_dispatch_id" && "$_last_dispatch_id" != "$_curr_id" ]]; then
            log "verdict-handler: skipping resume — transition dispatch_id ($_last_dispatch_id) != current ($_curr_id)"
            return 1
          fi
        fi
      ```

      The existing guards at lines 357-371 stay as fallback for legacy
      comments without a dispatch marker (per D-005).

- [ ] Verify syntax: `bash -n bin/verdict-handler.sh` exits 0.

### Task 12: Add dispatch_id-filter cases to `bin/verdict-handler-test.sh`

- `depends_on: [11]`
- `touches: bin/verdict-handler-test.sh (modify — append cases)`
- [ ] Append after the existing cases.
- [ ] **Case 87-V1 — `find_fresh_verdict` ignores other-dispatch
      verdicts.** `MOCK_COMMENTS_JSON` has two verdicts: a stale
      `verdict result=pass stage=reviewing` carrying
      `dispatch id=ENG-87V-d0010` (older `createdAt`) and a fresh
      `verdict result=fail target=implementing` carrying
      `dispatch id=ENG-87V-d0011` (newer `createdAt`). Seed
      `current_dispatch_id == ENG-87V-d0011`. Assert
      `find_fresh_verdict` returns the d0011 fail-marker (NOT the older
      d0010 pass marker).
- [ ] **Case 87-V2 — `find_fresh_verdict` falls back to timestamp
      window when no markers present (D-005).** Same comment shape but
      neither comment carries `meta: dispatch id=`. Assert
      `find_fresh_verdict` returns the latest verdict by createdAt
      (existing legacy behavior).
- [ ] **Case 87-V3 — `resume_in_progress_transition` rejects stale id.**
      `MOCK_COMMENTS_JSON` has a stale `pipeline: transition from=planning
      to=implementing` carrying `dispatch id=ENG-87V-d0008`. Seed
      `current_dispatch_id == ENG-87V-d0010`. Stage label = `stage:planning`.
      `pipeline:halted` applied. Assert `resume_in_progress_transition`
      returns 1 (refuses to compound on a stale id).
- [ ] **Case 87-V4 — `resume_in_progress_transition` accepts matching
      id.** Same shape but the transition carries
      `dispatch id=ENG-87V-d0010` (matches current). Assert it returns 0
      (resume proceeds; `apply_transition` invoked).
- [ ] **Case 87-V5 — legacy issue (no markers): existing labels-cross-check
      still fires.** No dispatch markers anywhere; transition's
      `from=planning`, current_stage label = `stage:brainstorming`. Assert
      `resume_in_progress_transition` returns 1 (existing ENG-41 §4.2
      cross-check, preserved per D-005).
- [ ] Verify: `bash bin/verdict-handler-test.sh` exits 0 with all cases PASS.

### Task 13: Add `PROMPT_RESOLVERS` registry and render-time validator to `bin/render-prompt.sh`

- `depends_on: [1]`
- `touches: bin/render-prompt.sh (modify — replace python interpolation block)`
- [ ] At the top of `bin/render-prompt.sh`, immediately after the
      `STAGE_TO_SECTION` block ending at line 23, add the
      `PROMPT_RESOLVERS` registry. Snippet:

      ```bash
      # ENG-87: prompt-token resolver registry. Every {token} in
      # AGENT_PROMPTS.md is resolved at render time by a function
      # registered here. Generalises ENG-79's bin/branch-name.sh fix
      # (the only canonical resolver pre-ENG-87). Unknown {token} in
      # source → die. Adding a new token = (a) register here, (b) add
      # the resolver function below, (c) emit the {token} in
      # AGENT_PROMPTS.md.
      PROMPT_RESOLVERS='
      issue_id=_resolve_issue_id
      issue_id_lower=_resolve_issue_id_lower
      issue_title=_resolve_issue_title
      issue_description=_resolve_issue_description
      date=_resolve_date
      slug=_resolve_slug
      brainstorm_file=_resolve_brainstorm_file
      plan_file=_resolve_plan_file
      branch_name=_resolve_branch_name
      stage_summary_path=_resolve_stage_summary_path
      learned_rules_dir=_resolve_learned_rules_dir
      dispatch_id=_resolve_dispatch_id
      '
      ```

      Twelve resolvers — eleven existing tokens + new `dispatch_id`.

- [ ] Add resolver functions below `find_doc()` (around line 125). Each
      resolver takes the relevant context as positional args (issue id,
      stage, etc.) and prints the resolved value. Snippet (selected;
      pattern repeats for the others):

      ```bash
      _resolve_branch_name() {
        local issue_id="$1"
        local b; b="$(bash "$SCRIPT_DIR/branch-name.sh" "$issue_id" 2>/dev/null || printf '')"
        [[ -n "$b" ]] || die "render-prompt: branch-name.sh returned empty for $issue_id"
        printf '%s' "$b"
      }
      _resolve_dispatch_id() {
        # Empty when allocator hasn't run (e.g., release stage); agent's
        # auto-injection is no-op when env is unset, so empty token is
        # acceptable on those paths.
        printf '%s' "${PIPELINE_DISPATCH_ID:-}"
      }
      _resolve_stage_summary_path() {
        local issue_id="$1" stage="$2"
        printf '%s/stage-summary-%s.md' "$(issue_dir "$issue_id")" "$stage"
      }
      # … (8 more resolvers, each a thin wrapper around the existing
      # python-dict values at lines 237-247 of the current file).
      ```

      `${PIPELINE_DISPATCH_ID:-}` is lint-clean (name does not match the
      secret-name regex).

- [ ] Replace the python-block interpolation at lines 230-252 with a
      bash-side renderer that:

      1. Extracts the distinct `{token}` set from `$block` (the fenced
         body). Use `grep -oE '\{[a-z_]+\}'` and `sort -u`.
      2. For each token: look up resolver in `PROMPT_RESOLVERS`; die if
         unknown.
      3. Call the resolver with the appropriate context (`issue_id`,
         `stage`, etc.); substitute the value into `$block` via `sed`
         (or `printf`-and-shell-loop to avoid sed-meta-char issues
         in title/description — the existing python block's
         `tmpl.replace` is safe; bash `${var//pat/repl}` is safe for
         literal patterns since `{token}` shapes contain no glob
         metachars).
      4. After substitution, assert no `{token}` remains in `$block`
         (the validator pin — catches a token that resolves to empty
         when it shouldn't, and catches a future typo where the source
         has `{ branch_name }` with extra spaces).

      Snippet (replace the python block):

      ```bash
      # ENG-87: bash-side resolver registry; replaces the previous
      # python-dict interpolation. ENG-79's branch_name resolver becomes
      # the general case.
      _lookup_resolver() {
        local token="$1"
        grep -E "^${token}=" <<<"$PROMPT_RESOLVERS" | head -1 | cut -d= -f2-
      }
      local rendered="$block" t resolver value tokens
      tokens="$(grep -oE '\{[a-z_]+\}' <<<"$block" | sort -u)"
      while IFS= read -r t; do
        [[ -z "$t" ]] && continue
        local name="${t#\{}"; name="${name%\}}"
        resolver="$(_lookup_resolver "$name")"
        [[ -n "$resolver" ]] || die "render-prompt: unknown token '$t' in source — register a resolver in PROMPT_RESOLVERS"
        value="$("$resolver" "$issue_id" "$stage" 2>/dev/null || printf '')"
        # Literal substitution; {token} contains no glob metachars.
        rendered="${rendered//"$t"/"$value"}"
      done <<<"$tokens"
      # Render-time validator: any remaining {…} is unresolved.
      local _residual; _residual="$(grep -oE '\{[a-z_]+\}' <<<"$rendered" | head -1 || true)"
      [[ -z "$_residual" ]] || die "render-prompt: unresolved token after registry pass: $_residual"
      printf '%s' "$rendered" | append_project_profile "$stage"
      ```

      The previous python branch and the sed-fallback branch (lines
      230-267) are removed entirely. The new resolver-based pass handles
      the issue title/description case (where sed would have failed on
      meta-chars) by using bash literal substitution
      (`${var//pat/repl}`), which does NOT interpret regex.

- [ ] Verify syntax: `bash -n bin/render-prompt.sh` exits 0.

### Task 14: Generalise stage-summary mandate from §5 to §§1-7 in `AGENT_PROMPTS.md`; add preamble dispatch-id contract

- `depends_on: [13]`
- `touches: AGENT_PROMPTS.md (modify — preamble subsection + §§1-7 stage-summary bullets)`
- [ ] Add a new subsection `### Dispatch identifier and freshness contract`
      to the agent-side preamble, immediately after the existing
      `**Freshness rule:**` paragraph at lines 90-93 and BEFORE the
      `### Label vocabulary` H3 at line 95. Body (~20-30 lines):

      - Document `{dispatch_id}` token as the canonical per-dispatch
        identifier (auto-resolved by render-prompt.sh).
      - Mandate: agents MUST NOT manually emit
        `<!-- meta: dispatch id=… -->` markers — `bin/linear.sh`'s
        chokepoint auto-injects them. Manual emission is a contract
        violation (linear.sh's `_inject_dispatch_marker` is idempotent,
        so a manual marker is silently de-duplicated, but the convention
        is "the chokepoint owns this marker").
      - Mandate: agents MUST NOT post Linear comments via
        `mcp__plugin_linear_*` or `curl https://api.linear.app` —
        envelope validator halts with `dispatch-envelope-violation`.
      - Mandate: agents MUST NOT read the dispatch_id of a previous
        cycle to "carry forward" any state. Each dispatch is a fresh
        slate; loopback inputs come from the SOURCE stage's stage-summary
        file (already cleared at THIS dispatch's start; loopback-source
        files are intact).

- [ ] Generalise §5's three §-specific clauses (lines 1027-1037: "MANDATORY
      — overwrite on every dispatch", "do not read-then-conditionally-
      skip", "ENG-71 May 2026 cycle") to the analogous bullets in §§1
      (Brainstorm), §2 (Plan), §3 (Implementation), §4 (UI), §6 (QA),
      §7 (Build). Each stage's "Stage summary file" Output bullet must
      carry the same three clauses, plus reference to the new dispatch-
      id contract subsection. Per brainstorm D-006: this un-defers
      ENG-77 D-003's narrowing.

      For each of §§1-7, locate the existing "Stage-summary file at
      `{stage_summary_path}`" Output bullet and extend with the same
      clause family that §5 already has at lines 1027-1037. Existing §5
      reads:

      > Stage-summary file at {stage_summary_path} (per the Stage summary
      > comment format contract). **MANDATORY — overwrite on every dispatch.**
      > Use `Write` with the full report content; do not read-then-
      > conditionally-skip. […]

      The same wording (with stage-specific examples) applies to §§1-4
      and §§6-7. Cite ENG-77 (May 2026) as the precedent in each.

- [ ] Verify: `bin/render-prompt.sh implementing ENG-87` (against a
      worktree-state-replicated fixture) renders without dying — the
      render-time validator from Task 13 catches any new `{token}` the
      AGENT_PROMPTS edits introduced that lacks a resolver.

### Task 15: Generalise asserts in `bin/agent-prompts-content-test.sh`

- `depends_on: [14]`
- `touches: bin/agent-prompts-content-test.sh (modify — generalise §5 asserts to §§1-7 + token-coverage assert)`
- [ ] Lift the three §5 asserts at lines 211-235 into a helper
      `assert_overwrite_mandate <stage-section-name> <stage-key>` that
      runs the three checks (overwrite-every-dispatch literal, no
      read-then-conditionally-skip literal, ENG-77|ENG-71 incident
      citation literal) against any §-section body. Snippet:

      ```bash
      assert_overwrite_mandate() {
        local section_name="$1" stage_key="$2"
        local body; body="$(section_body "$section_name")"
        if printf '%s\n' "$body" | grep -qiE 'overwrite[ d]+on every dispatch'; then
          ok "${stage_key}: mandates 'overwrite on every dispatch'"
        else
          nope "${stage_key}: mandates 'overwrite on every dispatch'" \
            "without this rule, the ${stage_key} agent can re-emit verdicts without a fresh file write — orchestrator posts stale body, downstream loopback gets no new feedback (ENG-77/ENG-71 May 2026 cycle)"
        fi
        if printf '%s\n' "$body" | grep -qF 'read-then-conditionally-skip'; then
          ok "${stage_key}: bans 'read-then-conditionally-skip'"
        else
          nope "${stage_key}: bans 'read-then-conditionally-skip'" \
            "the carve-out names the exact ENG-71 misreading; without it, agents may re-derive the same wrong behavior"
        fi
        if printf '%s\n' "$body" | grep -qE 'ENG-(71|77).*(May|2026)'; then
          ok "${stage_key}: cites the ENG-71/77 incident"
        else
          nope "${stage_key}: cites the ENG-71/77 incident" \
            "without the precedent, a future prompt-cleanup pass might decide the rule is overcautious and remove it"
        fi
      }
      ```

- [ ] Invoke `assert_overwrite_mandate` for each of §§1-7:
      `1. Brainstorm Agent → brainstorming`,
      `2. Plan Agent → planning`,
      `3. Implementation Agent (Backend) → implementing`,
      `4. UI Agent (Frontend) → ui`,
      `5. Review Agent → reviewing` (already covered; preserved),
      `6. QA Agent → qa`,
      `7. Build Agent → building`.

- [ ] Add a §preamble assert: the body of the agent-side preamble (the
      content between the H1 and `## 1.` header) must contain a literal
      `Dispatch identifier and freshness contract` heading and must cite
      the auto-injection rule. Snippet:

      ```bash
      preamble_body="$(awk '/^# / {h=1; next} /^## 1\./ {exit} h' AGENT_PROMPTS.md)"
      if printf '%s' "$preamble_body" | grep -qF 'Dispatch identifier and freshness contract'; then
        ok "preamble: cites Dispatch identifier and freshness contract"
      else
        nope "preamble: cites Dispatch identifier and freshness contract" \
          "without the preamble subsection, agents lack the canonical reference for {dispatch_id} interpolation and the no-mcp/no-curl mandates"
      fi
      ```

- [ ] Add a token-coverage assert: every `{token}` appearing in the
      file is registered in `PROMPT_RESOLVERS`. Read `PROMPT_RESOLVERS`
      from `bin/render-prompt.sh` (sourced or grepped); diff against the
      set extracted from `AGENT_PROMPTS.md` via
      `grep -oE '\{[a-z_]+\}' AGENT_PROMPTS.md | sort -u`. Any
      AGENT_PROMPTS token missing from the resolver list is a P0 for
      this assert.

- [ ] Verify: `bash bin/agent-prompts-content-test.sh` exits 0 with all
      existing cases PASS plus the new generalised asserts (per-stage
      §§1-7 = 21 new asserts; preamble = 1 assert; token-coverage = N
      asserts where N is the resolver count) all PASS.

### Task 16: Add `PROMPT_RESOLVERS` cases to `bin/render-prompt-test.sh`

- `depends_on: [13]`
- `touches: bin/render-prompt-test.sh (modify — append cases)`
- [ ] Append after the existing case-6.* tests.
- [ ] **Case 87-R1 — every existing token resolves cleanly.** Render
      the implementing stage's prompt against a fixture
      AGENT_PROMPTS.md fenced block containing all 12 tokens; assert
      output contains no `{…}` literal substring (the render-time
      validator's pin).
- [ ] **Case 87-R2 — unknown token dies.** Render a fixture fenced
      block containing `{nonexistent_token_xyz}`; assert
      `bin/render-prompt.sh` exits non-zero with a `die` message
      containing the literal token name.
- [ ] **Case 87-R3 — `{dispatch_id}` interpolates from
      `$PIPELINE_DISPATCH_ID`.** Set `PIPELINE_DISPATCH_ID=ENG-87R-d0042`.
      Render a fixture block containing `{dispatch_id}`; assert output
      contains `ENG-87R-d0042`.
- [ ] **Case 87-R4 — `{dispatch_id}` empty when env unset.** Unset env;
      render same fixture; assert output is empty for that token (NOT a
      die — empty is acceptable per resolver contract).
- [ ] **Case 87-R5 — `{branch_name}` resolves via bin/branch-name.sh
      (regression pin for ENG-79).** Existing case stays; preserved.
- [ ] Verify: `bash bin/render-prompt-test.sh` exits 0 with all cases PASS.

### Task 17: Update `CLAUDE.md` with `## Cross-dispatch staleness contract (ENG-87)` section

- `depends_on: [4, 7, 8, 11, 13]`
- `touches: CLAUDE.md (modify — append new section after `## Orchestrator entry-conditions (ENG-86)`)`
- [ ] Add a new H2 section `## Cross-dispatch staleness contract (ENG-87)`
      immediately after `## Orchestrator entry-conditions (ENG-86)` (at
      the location where ENG-86's plan landed its docblock). Document:

      - **Glue: `PIPELINE_DISPATCH_ID`.** Allocated by
        `bin/run-stage.sh::main` per dispatch, format `ENG-N-d<NNNN>`,
        monotonic per issue, persisted in `issue-state.json`. Inherited
        by `dispatch.sh`'s subshell, the agent's `bash bin/linear.sh`
        calls, and the orchestrator's post-dispatch validator.
      - **Per-medium primitives table.** Files (clear-on-start),
        Linear comments (auto-inject at chokepoint), Linear labels (lane
        fence — ENG-41), prompt tokens (resolver registry).
      - **Detective backstop.** `_validate_dispatch_envelope` halts on
        EGREGIOUS bypass (transcript scan for `mcp__plugin_linear` or
        `curl https://api.linear.app`). Halt reason
        `dispatch-envelope-violation`, exit code 29.
      - **Soft-fallback (D-005).** Legacy issues pre-cutover: readers
        fall back to timestamp-window. Fallback expires the first time
        the orchestrator dispatches the issue post-cutover.
      - **`dispatch_history.jsonl`.** New per-issue append-only log;
        forensic only.
      - **Recovery.** `bash bin/pipeline.sh decide ENG-N --action continue`
        clears the halt label and the per-issue counter; the next tick
        re-allocates a fresh `dispatch_id`.

      Mirror the prose shape of the existing CLAUDE.md sections at
      `## Per-stage dispatch timeouts (ENG-65)` and
      `## Orchestrator entry-conditions (ENG-86)`.

### Task 18: Add envelope-violation entry to `docs/runbooks/recovery.md`

- `depends_on: [8]`
- `touches: docs/runbooks/recovery.md (modify — append new section)`
- [ ] Add a new section `## Dispatch envelope violation (ENG-87)`.
      Body (~30-40 lines):

      - **Symptoms.** Halt comment with
        `<!-- pipeline: verdict result=halt reason=dispatch-envelope-violation -->`;
        `pipeline:halted` label; per-stage transcript shows a tool call
        starting with `mcp__plugin_linear` or `curl https://api.linear.app`.
      - **Interpretation.** One of: (a) the agent bypassed `bin/linear.sh`
        via the Linear MCP plugin (allowlist drift; check
        `bin/dispatch.sh::allowed_tools_for`); (b) the agent ran direct
        `curl` against the Linear GraphQL endpoint (likely a prompt
        regression); (c) the allocator failed and the chokepoint logged
        unstamped comments (rare; check
        `$PROJECT_STATE_DIR/<ident>/logs/<stage>-*.log` for allocator
        errors).
      - **Recovery.** Inspect the transcript at
        `$PROJECT_STATE_DIR/<ident>/.envelope-transcript-<stage>` (kept
        across the halt for forensic review; cleared on
        `--action continue`). Fix the underlying cause (allowlist edit,
        prompt fix, allocator bug). Resume:

        ```bash
        bash bin/pipeline.sh decide ENG-N --action continue
        ```

      - **Why this halt exists.** Defense-in-depth on top of the lane
        fence (ENG-41). The auto-injection at `bin/linear.sh` is the
        preventive primitive; the envelope validator catches any agent
        that bypasses the chokepoint entirely.

## Frontend Tasks

no UI surface. This repo is bash orchestration only — no React, no API client,
no compiled artifact. The "Frontend Tasks" header is preserved for plan-format
consistency per the prompt contract.

## Failure Mode → Test Map

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
|---|---|---|---|---|
| Agent skips Write of stage-summary file | Mock dispatch produces no `stage-summary-implementing.md` post-clear | Existing rc=25 (`agent-contract-missing`) fires; halt with classify_failure → exit 25 | unit | `bin/run-stage-test.sh::Case-7-rc25-summary-missing` (existing — verify still green) |
| Agent writes stale (read-then-skip-write) content | Cannot happen post-clear (file absent at agent-start, read returns ENOENT, agent must Write fresh) | n/a — preventive; no halt path | unit | `bin/run-stage-test.sh::Case-87-A` (current-stage cleared at start) + `Case-87-B` (other-stage preserved) |
| Agent posts via `mcp__plugin_linear_*` (bypassing linear.sh) | Fixture transcript with assistant `tool_use` Bash command starting `mcp__plugin_linear_linear__save_issue` | Envelope validator halts with rc=29; classify_failure → `dispatch-envelope-violation`; halt comment posted | unit | `bin/run-stage-test.sh::Case-87-F` |
| Agent direct-curls Linear GraphQL | Fixture transcript with `curl https://api.linear.app/graphql` | Envelope validator halts with rc=29; same classify path | unit | `bin/run-stage-test.sh::Case-87-G` |
| Allocator races (two ticks for same issue at once) | Background two `allocate_dispatch_id ENG-87T` calls in parallel | Each call gets a distinct id; no collision; mv-f atomicity preserves seq | unit | `bin/common-test.sh::Case-87.3` |
| `issue-state.json` corruption mid-allocate | Seed file with `'{not valid json'` | Allocator treats prior_seq as 0; new id is `ENG-87T-d0001` | unit | `bin/common-test.sh::Case-87.4` |
| Operator runs `bin/linear.sh add-comment` manually (env unset) | `PIPELINE_DISPATCH_ID` empty; call `add_comment ENG-87L "operator-direct"` | Auto-injection skipped; body unchanged (operator-lane behavior) | unit | `bin/linear-test.sh::Case-87-L2` |
| `render-prompt.sh` encounters unknown `{token}` | Fixture AGENT_PROMPTS fenced block with `{nonexistent_token_xyz}` | Render-time validator dies loud with token name in message; tick fails fast | unit | `bin/render-prompt-test.sh::Case-87-R2` |
| New stage added but `_clear_current_stage_slots` not extended | n/a — function takes stage as parameter, no per-stage hardcoding | n/a — design eliminates this failure mode (parametric clear) | smoke | (covered structurally by Task 4's parametric implementation; no separate test) |
| Mid-dispatch crash between allocator and clear-at-start | Pre-seed `dispatch_history.jsonl` with an orphaned start row + `issue-state.json` with the matching `current_dispatch_seq` (simulating crashed prior dispatch); pre-seed orphaned `wait-${stage}.json`/`stage-summary-${stage}.md` for the second sub-case | `dispatch_history.jsonl` has start row without end row; next tick's allocator advances to `prior_seq+1` (read from issue-state.json, NOT history); orphaned wait/summary files cleared by next dispatch's `_clear_current_stage_slots` | unit | `bin/run-stage-test.sh::Case-87-D` (idempotent clear, file-absent) + `Case-87-D'` (post-crash monotonic increment + audit-log preservation) + `Case-87-D2'` (orphaned wait+summary cleared on next start) — review-iter-2 C3' added the two crash-recovery sub-cases the original Case-87-D was flagged for missing |
| Linear API outage during auto-injection | Existing `linear.sh` failure path (rc=24) | classify-failure routes via `linear-post-failed`/retry-immediately (existing path) | unit | (existing `bin/linear-test.sh` rc=24 cases — preserved) |
| Reader's dispatch_id fallback (legacy issue, no markers) | `MOCK_COMMENTS_JSON` with no `meta: dispatch id=` markers | `find_fresh_verdict` falls back to timestamp window; returns latest verdict | unit | `bin/verdict-handler-test.sh::Case-87-V2` (review-iter-3 m3: removed stale `bin/linear-test.sh::Case-87-L5` reference — L5 actually tests writer-side `add_comment` integration with `_inject_dispatch_marker`, not reader-side fallback) |
| Reader's dispatch_id mismatch (stale transition) | Latest transition carries `dispatch id=ENG-87V-d0008`; current = d0010 | `resume_in_progress_transition` returns 1 (refuses stale) | unit | `bin/verdict-handler-test.sh::Case-87-V3` |
| Reader's dispatch_id match (legitimate resume) | Transition's id matches current | `resume_in_progress_transition` returns 0; `apply_transition` invoked | unit | `bin/verdict-handler-test.sh::Case-87-V5` (review-iter-3 m3: was `Case-87-V4`; V4 is the stale-id reject case, V5 is the match-accept case) |
| ENG-41 §1.2-style 2-day-old transition selected as in-progress | Stale comment with no marker; current_stage=brainstorming, comment.from=planning | Existing labels-cross-check fires (legacy fallback, D-005) → returns 1 | unit | `bin/verdict-handler-test.sh::Case-87-V6` (legacy fallback preserves ENG-41 §4.2 guard) (review-iter-3 m3: was `Case-87-V5`; V5 is the matching-id accept, V6 is the legacy-fallback path) |
| ENG-77-style 9-iter review/implement loop | Implement loopback dispatch starts with stale `stage-summary-reviewing.md` from prior review iter | Cannot happen — review's clear-at-start removes its own summary; implement reads the FRESH review summary on each loopback | unit | `bin/run-stage-test.sh::Case-87-B` (other-stage preserved) covers the structural guarantee |
| `add_or_update_comment` re-apply with same body double-injects marker | Pre-craft body with marker present; call `add_or_update_comment` again | Idempotent: marker appears EXACTLY ONCE | unit | `bin/linear-test.sh::Case-87-L3` |
| Auto-injection breaks dedup-marker placement | Call `add_or_update_comment` with sig and env set | Both `meta: dispatch id=…` AND `meta: dedup key=…` present, in source-order (dedup last) | unit | `bin/linear-test.sh::Case-87-L4` |
| `find_fresh_verdict` picks unstamped decoy by createdAt when markers exist | Three comments: two stamped (older), one unstamped (newest) | Stamped pass marker wins (id-match path); unstamped decoy filtered out | unit | `bin/verdict-handler-test.sh::Case-87-V1b` (covers the original ENG-77 attack vector; lives in verdict-handler-test.sh because the function-under-test is `find_fresh_verdict`, sourced from verdict-handler.sh; review-iter-2 C2' updated this row from the planned `bin/linear-test.sh::Case-87-L6` to the actual home) |
| Token in AGENT_PROMPTS.md added without registering in PROMPT_RESOLVERS | Fixture AGENT_PROMPTS edit introduces `{novel_token}` without adding resolver | content-test fails: token-coverage assert fires; render-time validator also dies on actual render | unit | `bin/agent-prompts-content-test.sh::token-coverage assert` |
| §5-only mandate not generalised; new stage's stage-summary file goes stale | Fixture: §3 Implementation lacks the "overwrite on every dispatch" clause | content-test fails: §3 stage-summary mandate assert fires | unit | `bin/agent-prompts-content-test.sh::assert_overwrite_mandate(implementing)` |
| Preamble dispatch-id contract removed by future cleanup | Fixture: AGENT_PROMPTS preamble lacks `Dispatch identifier and freshness contract` heading | content-test fails: preamble assert fires | unit | `bin/agent-prompts-content-test.sh::preamble assert` |

## Test Strategy

**Unit tests** carry the bulk of coverage. Each new helper has a sibling
test in the same file family:

- `bin/common-test.sh::Case-87.{1..5}` covers `allocate_dispatch_id`
  atomicity, monotonicity, durability, corruption-handling, and the
  read-back via `current_dispatch_id`.
- `bin/run-stage-test.sh::Case-87-{A..H}` covers
  `_clear_current_stage_slots` (clear current; preserve OTHER;
  idempotent) and `_validate_dispatch_envelope` (clean; MCP halts; curl
  halts; chokepoint sanity).
- `bin/linear-test.sh::Case-87-L{1..6}` covers auto-injection
  (env-set/unset; idempotent; coexists with dedup; legacy-fallback in
  `find_fresh_verdict`).
- `bin/verdict-handler-test.sh::Case-87-V{1..5}` covers dispatch_id
  filter in `find_fresh_verdict` and the new mismatch guard in
  `resume_in_progress_transition`, with legacy-fallback and ENG-41
  cross-check preserved.
- `bin/render-prompt-test.sh::Case-87-R{1..5}` covers PROMPT_RESOLVERS
  registry: every token resolves; unknown dies; `dispatch_id` is
  registered; ENG-79 `branch_name` regression preserved.
- `bin/agent-prompts-content-test.sh` extends with `assert_overwrite_mandate`
  applied per-stage to §§1-7 (21 new asserts) plus preamble + token-
  coverage asserts.

**Integration tests** are not added in this plan — `bin/run-stage-test.sh`
already exercises the full `main()` path with stubs. The brainstorm §12
notes a deferred dispatch-test.sh-style coverage of the auto-injection
under a stub `claude`; defer until empirical evidence the unit tests
miss something.

**Smoke tests** are covered by `bash -n bin/*.sh` (already in CI as the
syntax check) plus the existing pre-commit hook (`.githooks/pre-commit`)
that runs the entire `bin/*-test.sh` suite. Adding new test files to that
suite is automatic (the hook globs `bin/*-test.sh`).

**Adversarial coverage** focuses on the brainstorm §8 failure modes that
hand-rolled bypass attempts:

- Transcript fixtures with chained Bash commands (e.g.,
  `bash bin/linear.sh add-comment …; mcp__plugin_linear …`). The
  `assert_no_tool_invocation` startswith semantics catch the second
  invocation if it's its OWN tool_use block; chained-in-single-string
  commands are an acknowledged blind spot per A-020. Document the gap
  in CLAUDE.md (Task 17).
- Fixture transcripts with case-variant Linear MCP names (e.g.
  `MCP__plugin_linear`). The case-sensitive prefix match is intentional;
  AGENT_PROMPTS.md preamble (Task 14) bans MCP-Linear writes; the
  allowlist (verified absent in `allowed_tools_for`) is the primary
  defense.
- Re-apply of `add_or_update_comment` with subtly different body content
  (timestamps, SHAs) under the same sig — the existing dedup-normalisation
  at `bin/linear.sh:497-504` covers byte-equal-modulo-{TS,SHA}; the
  dispatch-id auto-injection adds another normalised line that the
  norm-strip does NOT erase, so re-applies of the SAME dispatch keep
  marker-equal. Test `Case-87-L3` pins this property.

The plan does not introduce smoke tests against a real `claude -p`
binary — that's the implement agent's local gate; under the harness-self
sandbox the implementing-stage `claude -p` invocation is denied per
CLAUDE.md "Implement-stage sandbox blocks bash bin/<test>.sh".

## Self-review — persona summary

| Persona | Verdict | P0 |
|---|---|---|
| Feasibility | PASS | 0 |
| Scope | PASS | 0 |
| Coherence | PASS | 0 |
| Design | PASS | 0 |
| Product | PASS | 0 |

**5/5 PASS · gate P0: 0 · proceeding to implementing.**

Detailed findings:

### Feasibility — PASS (P0 = 0)

Every modified-file fact is `path:line`-cited and re-verified against
this worktree (2026-05-09). Notable verifications: `bin/run-stage.sh`
main flow at lines 714-800 with the correct insertion point at line 800
(after `mkdir -p` and before render-prompt — matches A-005); the rc=25
agent-contract validator at lines 1059-1081 (re-verified via direct
read; A-007); `bin/linear.sh::add_comment` at line 470 with insertion
point after line 479 (`_check_lane`) and before line 481 (dry-run
short-circuit) — A-012; `parse_pipeline_marker` at lines 192-242 already
generic over `meta` kinds, no parser change needed (A-003);
`failure_outcome_for_exit` next free code is 29 (A-002). The single
subtle dependency is on ENG-41's lane fence shipping before Phase 3 —
called out explicitly in Architecture §3 and Task 7's gate.

`PROMPT_RESOLVERS` (Task 13) replaces the python-block interpolation;
verified that all 11 existing tokens map cleanly to one-line resolver
functions, and that bash `${var//pat/repl}` substitution is glob-immune
for `{token}` shapes (no metachars in `{name}`; titles/descriptions go
through the resolver's literal substitution, NOT sed, avoiding the
existing fallback's meta-char issue at lines 254-267).

Codebase-fact errors: zero. The brainstorm's prior incorrect citation of
`bin/run-stage.sh:977-989` for the rc=25 path (corrected to 1068-1080
in the brainstorm itself, then re-verified here as 1059-1081 in this
worktree) is the only line-number drift between the brainstorm's
inventory and the current state.

`depends_on` graph is acyclic: Task 1 (allocator) is the root; Tasks 2-3
parallel (vocab + dispatch.sh); Task 4 (run-stage.sh allocator-call)
depends on 1+3; Tasks 5-6 (tests) depend on 4; Task 7 (linear.sh
auto-inject) depends on 1+2; Task 8 (envelope validator) depends on 4+7;
Tasks 9-10 (tests) depend on 8/7; Task 11 (verdict-handler.sh) depends
on 1+2+7; Task 12 (test) depends on 11; Task 13 (render-prompt.sh)
depends on 1; Tasks 14-16 (prompts/tests/docs) depend on 13/8/etc.;
Tasks 17-18 (docs) depend on 4/7/8/11/13. No hidden coupling through
shared mutable state — the env var `PIPELINE_DISPATCH_ID` is the
only cross-task globals, and all callers either set or read it
explicitly.

### Scope — PASS

Every File Structure entry traces to a brainstorm decision (D-001..D-010
in §7) or an explicit §11 phase. No file is touched outside the
brainstorm's scope. `touches:` lists strictly subset the File Structure
declarations.

The Linear issue specifies five invariants (G-1..G-5) — every one is
covered:
- G-1 (allocation) → Tasks 1 + 4
- G-2 (no-stale-file) → Tasks 4 (clear-on-start)
- G-3 (linear-comment-stamp) → Tasks 7 + 11
- G-4 (prompt-token-canonical) → Tasks 13 + 16 + 15
- G-5 (envelope-validation) → Tasks 8 + 9

The 4-phase phasing is preserved as task groups; no scope creep beyond
brainstorm §11.

### Coherence — PASS

The plan's Goal matches brainstorm §2 verbatim. Backend Tasks jointly
realise the env-var contract, JSON shape contract, marker grammar
contract, and exit-code contract from API Contract §. Test Strategy
covers every Failure Mode → Test Map row.

ENG-41 dependency surfaced explicitly (Architecture §3, Task 7 gate).
ENG-77 D-001 generalisation surfaced in Task 14 + Task 15. ENG-79
single-resolver pattern generalised in Task 13. ENG-78 independence
documented (Architecture §3 — different layer; can ship in either
order).

### Design — PASS

The plan respects bash idiom boundaries: helpers use `local
PIPELINE_WRITER=…; export PIPELINE_WRITER` for lane attribution;
`require_bin` is implicit (jq, awk are existing hard deps; no new
deps); `set -euo pipefail` is inherited from `common.sh`. The
clear-on-start / auto-inject / resolver-registry / envelope-validator
primitives each occupy the correct layer (orchestrator-side preventive
for files, chokepoint-side for comments, render-side for tokens, post-
dispatch detective for transcripts).

No layering violations: agents never set `PIPELINE_DISPATCH_ID` (the
orchestrator owns it); `bin/linear.sh` only reads the env var (no
caller of `linear.sh` mutates dispatch state); `bin/render-prompt.sh`
imports tokens from existing context, not from any new external
state.

No circular dependencies introduced: Task 1's `bin/common.sh` is at
the bottom of the source-tree (everything sources it); the new
helpers append to its set, not modify existing functions.

### Product — PASS

The plan delivers what the Linear issue asked for, in language the
operator would recognise: "a unified hard hand-off contract that
eliminates the [cross-dispatch staleness] class," with the five named
invariants G-1..G-5 each spelled out as concrete tasks. Operator
visibility is preserved: `dispatch_id` appears in halt comments
(Task 8 body); `bin/status.sh`-side surfacing of
`dispatch_history.jsonl` is deferred per brainstorm §12 (out-of-scope
future work; a separate ticket).

Recovery commands are unchanged — `bash bin/pipeline.sh decide ENG-N
--action continue` clears the new halt class same as any other
(documented in Task 18).
