---
linear: ENG-78
date: 2026-05-08
topic: Gate classify-failure's halt-label apply on effective_policy; switch retry-immediately to a meta-shape comment; preserve issue-state.json across orphan cleanup when policy=retry-immediately
---

# Plan — ENG-78 classify-failure halt vs retry-immediately contradiction

Implementation plan for the design at
`docs/brainstorms/2026-05-08-eng-78-classify-failure-writes-policy-retry-immediately-but-the-same-call-applies-pipeline-halted-poll-sh-then-skips-the-issue-dead-ending-the-retry-design.md`.

## Goal

Stop dead-ending issues on transient failures: a 529 Overloaded (or other
retry-immediately classify exit) no longer halts the pipeline on the first
hit — `poll.sh` re-dispatches the same (issue, stage) on the next tick, and
the operator-facing Linear comment says "retry-pending (attempt N of 2)"
truthfully instead of today's "will retry automatically" lie. The pipeline
auto-halts only after 3 consecutive same-evidence failures (~15 min at the
5-min tick), at which point the operator sees a halt comment with policy
`skip-until-code-changes`.

Concretely: inside `bin/classify-failure.sh::classify_failure`, replace the
unconditional `add-label "pipeline:halted"` at lines 117-119 with a
`case "$effective_policy"` that fires only on the two halt-policy arms
(`skip-until-code-changes`, `skip-until-human-acts`); split the halt-comment
block at lines 121-146 into the today-shape halt-verdict comment for those
two arms and a new
`<!-- meta: metric name=transient-retry stage=<stage> attempt=<n> -->`-shape
comment under sig `retry-pending/$stage/$issue` for the `retry-immediately`
arm; in `bin/poll.sh::_poll_evaluate_skip` (lines 57-64), preserve the
`issue-state.json` orphan when `.policy == "retry-immediately"` so
classify-failure's auto-escalation guard at `bin/classify-failure.sh:67-77`
sees `retry_count` survive across ticks; pin all four with new test cases in
`bin/classify-failure-test.sh` and `bin/poll-slot-test.sh`.

**Trade-off (per brainstorm §9 Product persona).** Operators lose the
first-failure halt notification: today's behavior fires a halt comment +
Slack on the very first transient; ENG-78 holds off until the third
consecutive same-evidence failure. Slack signal lag for sustained outages
grows by up to ~10 minutes (two extra tick intervals). The trade buys
self-recovery on isolated transients, which is the issue's stated intent.

## Anti-anchoring check

- **Problem restated.** A `retry-immediately` policy from `classify_failure`
  applies `pipeline:halted` and posts a `<!-- pipeline: verdict result=halt -->`
  marker; on the next tick `bin/poll.sh::_poll_classify_labels` (lines
  217-233) treats the issue as halted, calls `verdict_handler`, sees the halt
  marker, returns 1, and the issue idles forever. The Linear comment text
  ("pipeline will retry automatically on the next tick") is verifiably false.
  ENG-68 demonstrated 5 hours of dormancy on a 529-Overloaded transient.
- **Brainstorm's solution.** Path A (gate the halt apply at the producer
  site, not the reader) plus the marker-shape split (D-002) so a future
  marker-first reader cannot re-introduce the bug, plus a one-branch
  poll.sh state-file preservation (D-003) so the existing 2-retry
  auto-escalation cap actually fires, plus regression tests (D-004).
- **Solution proportionality.** Three production files modified
  (`bin/classify-failure.sh`, `bin/poll.sh`, plus a one-line CLAUDE.md doc
  string update); two test files extended; no new files; no new helpers; no
  new exports; no new config keys; no changes to `bin/pipeline-events.json`
  (the new comment shape uses the existing `meta:metric` kind that
  `bin/pipeline-events.json:42-48` already lists and that
  `bin/common.sh::parse_pipeline_marker` already returns as
  `event:"meta", kind:"metric"` at lines 219-220, which `find_fresh_verdict`
  then filters out at `bin/verdict-handler.sh:111`).
- **Verdict.** Both checks pass. Proceed without `pipeline:supersede` /
  `pipeline:extend`.

## Assumption inventory

Every code-level claim is verified against the worktree at composition
time (branch
`feat/eng-78-classify-failure-writes-policy-retry-immediately-but-the-same-call-applies-pipeline-halted-poll-sh-then-skips-the-issue-dead-ending-the-retry`).

- **A-001 — `bin/classify-failure.sh:117-119` is the unconditional halt-label
  apply this plan replaces.**
  - `bin/classify-failure.sh:117` — `# ENG-18: every policy outcome is a halt surface from the Verdict`
  - `bin/classify-failure.sh:118` — `# Handler's perspective; apply the sentinel label unconditionally.`
  - `bin/classify-failure.sh:119` — `bash "$_CFS_SCRIPT_DIR/linear.sh" add-label "$issue" "pipeline:halted" || true`
  - **Status:** verified. Task 1 replaces these three lines with a
    `case "$effective_policy"` switch keyed on the same enum the
    skip-label dance at `bin/classify-failure.sh:106-115` already uses.

- **A-002 — `bin/classify-failure.sh:121-146` is the halt-comment block this
  plan splits.**
  - `bin/classify-failure.sh:121-123` — preamble comment + `local sig="halt/$stage/$issue"`
  - `bin/classify-failure.sh:124-129` — `marker_reason` resolution (`skip-until-human-acts → agent-blocked`, default → `agent-failure`)
  - `bin/classify-failure.sh:130-132` — `comment_body` header `printf` with verdict marker, halt header, retry_count
  - `bin/classify-failure.sh:133-143` — three-arm `case "$effective_policy"` that appends the resume-text body
  - `bin/classify-failure.sh:140-142` — the offending arm: `retry-immediately) comment_body+="pipeline will retry automatically on the next tick." ;;`
  - `bin/classify-failure.sh:144` — evidence footer
  - `bin/classify-failure.sh:146` — `add-or-update-comment "$sig" "$issue" "$comment_body"`
  - **Status:** verified. Task 2 wraps lines 121-146 in an outer
    `case "$effective_policy"` and emits a distinct meta-shape comment
    under sig `retry-pending/$stage/$issue` on the `retry-immediately` arm.

- **A-003 — `bin/classify-failure.sh:67-77` is the auto-escalation guard
  whose `retry_count` survives must be preserved across ticks.**
  - `bin/classify-failure.sh:69` — `if [[ "$base_policy" == "retry-immediately" ]] && [[ "$prior_policy" == "retry-immediately" ]]; then`
  - `bin/classify-failure.sh:70` — `if [[ "$prior_hash" == "$current_hash" ]] && [[ "$prior_sha" == "$current_sha" ]]; then`
  - `bin/classify-failure.sh:71` — `retry_count=$((prior_count + 1))`
  - `bin/classify-failure.sh:72-74` — `if (( retry_count >= 2 )); then effective_policy="skip-until-code-changes"; effective_reason="escalated after $retry_count same-evidence retries of: $reason"; fi`
  - **Status:** verified. The guard is the natural escape valve for this
    fix: when same-evidence failures recur ≥2 times, `effective_policy`
    flips to `skip-until-code-changes` and Task 1's case-match enters the
    halt-applier arm. No new escalation logic needed.

- **A-004 — `bin/classify-failure.sh:60-65` reads `prior_policy`,
  `prior_hash`, `prior_sha`, `prior_count` from `issue-state.json` on every
  call.**
  - `bin/classify-failure.sh:61-64` — four `jq -r` reads of the `.policy`,
    `.evidence.pipeline_content_hash`, `.evidence.branch_head_sha`,
    `.retry_count` fields with `// ""` / `// 0` defaults.
  - **Status:** verified. If the state file is deleted between ticks (the
    pre-D-003 behavior in poll.sh), all four prior_* values are empty/zero
    and the auto-escalation guard at 69 short-circuits. D-003 closes that.

- **A-005 — `bin/poll.sh:57-64` is the orphan-cleanup site this plan
  modifies.**
  - `bin/poll.sh:57` — `# No skip label AND no state file → normal eligible candidate.`
  - `bin/poll.sh:58` — `if [[ "$has_code_label" != "true" && "$has_human_label" != "true" ]]; then`
  - `bin/poll.sh:59-62` — `if [[ -f "$state_file" ]]; then log "poll: orphan state file for $ident (no skip label); removing"; rm -f "$state_file"; fi`
  - `bin/poll.sh:63` — `return 0`
  - **Status:** verified. Task 3 inserts a `jq -r '.policy // ""'` read
    BEFORE the `rm -f`, branches on `retry-immediately`, and logs the
    keep/delete decision either way.

- **A-006 — `bin/poll.sh:217-233` is the halt-label-gated reader that
  ENG-78 will no longer trip for transient retries.**
  - `bin/poll.sh:217` — `elif [[ "$(_has_label pipeline:halted)" == "true" ]]; then`
  - `bin/poll.sh:218-219` — `local fresh; fresh="$(find_fresh_verdict "$ident" 2>/dev/null || printf '')"`
  - `bin/poll.sh:220-222` — empty-fresh → `slot:"hold",advanceable:false`
  - `bin/poll.sh:223-232` — `pipeline-stage-summary|pipeline-rejection → hold,advanceable:true`; `pipeline-halt → vacate`; default → hold,not-advanceable
  - **Status:** verified. With Task 1 not applying the halt label on
    retry-immediately, this branch never fires; classification falls
    through to the bare `else class='{"slot":"hold","advanceable":true}'`
    at line 266, which is the dispatch-eligible state.

- **A-007 — Held-slot loop calls `verdict_handler` for halted advanceable
  issues at `bin/poll.sh:439-448`.**
  - `bin/poll.sh:439-441` — `local has_halt; has_halt="$(jq -r --arg n "pipeline:halted" '[.[] | select(. == $n)] | length > 0' <<<"$labels_json")"`
  - `bin/poll.sh:442-448` — when halt label is present, calls `verdict_handler "$ident" "$cur_stage_suffix"`, then `i=$((i+1)); continue`
  - **Status:** verified. With ENG-78 keeping the halt label off for
    retry-immediately, this branch is bypassed; the loop falls through to
    the default `jq -nc … '{issue_id, stage, entry_action:"run"}'`
    dispatch shape at lines 450-457.

- **A-008 — `verdict_handler` returns 1 ("preserve halt") for `pipeline-halt`
  markers at `bin/verdict-handler.sh:396-398`.**
  - `bin/verdict-handler.sh:396` — `pipeline-halt)`
  - `bin/verdict-handler.sh:397` — `log "verdict-handler: halt marker on $issue (reason=$(jq -r '.reason' <<<"$fresh")) — leaving halt intact"`
  - `bin/verdict-handler.sh:398` — `return 1`
  - **Status:** verified. The bug's terminal: today's halt marker on a
    retry-immediately failure routes here and stays parked. Task 2 emits
    a meta-shape comment instead, which `find_fresh_verdict` skips at
    `bin/verdict-handler.sh:111` (`event != "verdict"` filter), so this
    branch is unreachable for transient retries.

- **A-009 — `find_fresh_verdict` filters to `event == "verdict"` at
  `bin/verdict-handler.sh:111` and selects latest by createdAt at line 114.**
  - `bin/verdict-handler.sh:107-117` — full freshness loop (read TSV from comments, parse marker, filter `event == "verdict"`, exclude `result == "wait"`, keep latest by `[[ "$ts" > "$fresh_ts" ]]`)
  - **Status:** verified. The new meta-shape comment with
    `<!-- meta: metric name=transient-retry … -->` parses as
    `{event:"meta", kind:"metric", name:"transient-retry", …}` (per A-010)
    and is dropped at line 111. Existing pass markers (createdAt > halt
    comment timestamp) win on the auto-recovered tick — their createdAt
    is later because Linear writes do not back-date.

- **A-010 — `bin/common.sh::parse_pipeline_marker` returns
  `{event:"meta", kind:"metric"}` for `<!-- meta: metric ... -->` bodies.**
  - `bin/common.sh:185-235` — full function definition
  - `bin/common.sh:197` — `marker="$(grep -oE '<!-- (pipeline|meta): [^>]+ -->' <<<"$body" 2>/dev/null | tail -1 || true)"`
  - `bin/common.sh:201-207` — family resolution (pipeline vs meta)
  - `bin/common.sh:217-221` — for `family == "meta"`, sets
    `json="$(jq -nc --arg k "$first" '{event:"meta", kind:$k}')"` where
    `$first` is the first whitespace-token of the payload (here, `metric`)
  - `bin/common.sh:224-232` — k=v pair parser merges remaining tokens
    (here, `name=transient-retry stage=<stage> attempt=<n>`) into the
    JSON object via `jq -c --arg k "$k" --arg v "$v" '. + {($k): $v}'`
  - **Status:** verified. The meta-shape body parses cleanly; the
    `event:"meta"` field is what `find_fresh_verdict` excludes.

- **A-011 — `bin/pipeline-events.json::meta_kinds` already includes
  `"metric"`; no registry change needed.**
  - `bin/pipeline-events.json:42-48` — `"meta_kinds": ["dedup", "metric", "evidence", "reapplied", "forensic"]`
  - **Status:** verified. The `metric` kind is the existing closed-vocab
    entry; reusing it is consistent with CLAUDE.md "Pipeline vocabulary"
    §. No need to add `transient-retry` as a new kind — `metric` is the
    bookkeeping bucket and `name=transient-retry` rides as a k=v pair.

- **A-012 — `bin/linear.sh::add_or_update_comment` matches existing
  comments by sig embedded in the body, and distinct sigs produce
  distinct comments with distinct createdAt.**
  - `bin/linear.sh:541-548` — entrypoint (`sig`, `ident`, `body`)
  - `bin/linear.sh:559-560` — `local marker="<!-- meta: dedup key=$sig -->"; local marker_legacy="<!-- pipeline-sig: $sig -->"`
  - `bin/linear.sh:561-563` — appends new-shape marker if not present
  - `bin/linear.sh:577-579` — GraphQL search via `select(.body | contains($m) or contains($l))`
  - `bin/linear.sh:607-611` — `commentUpdate` mutation (only `body` in
    input — `createdAt` is preserved on update)
  - `bin/linear.sh:613-617` — fall-through `commentCreate` mutation
  - **Status:** verified. New sig `retry-pending/$stage/$issue` is
    disjoint from `halt/$stage/$issue` (Task 2 keeps the latter for the
    halt arms), so an auto-escalation tick creates a brand-new comment
    with a fresh createdAt rather than overwriting the retry-pending
    thread in place. Forensic property: the operator can read the
    transition (transient → final halt) from the createdAt timeline.

- **A-013 — `bin/run-stage.sh:813-817, 982-986, 1004-1009` are the three
  retry-immediately call sites; each exits 20/25/24 BEFORE reaching the
  post-dispatch hook at `bin/run-stage.sh:1036`.**
  - `bin/run-stage.sh:813-817` — `elif (( dispatch_rc != 0 )); then classify_failure "$ident" "$stage" "retry-immediately" "dispatch failed (see $log_file)" 20; rm -f "$prompt_file"; exit 20`
  - `bin/run-stage.sh:982-986` — agent-contract validator: `if [[ ! -s "$_summary_path" ]] && [[ -z "$_fresh_marker" ]]; then classify_failure "$ident" "$stage" "retry-immediately" "agent dispatch returned 0 but emitted no stage-summary file and no verdict marker" 25; exit 25; fi`
  - `bin/run-stage.sh:1005-1008` — `if ! post_completion_comment "$ident" "$stage"; then classify_failure "$ident" "$stage" "retry-immediately" "linear post failed for completion/$stage/$ident after one retry" 24; exit 24; fi`
  - `bin/run-stage.sh:1036` — `_post_dispatch_apply_halt "$ident" "$stage"` (success-path halt-add, ENG-56)
  - **Status:** verified. Each retry-immediately arm exits before reaching
    line 1036, so Task 1's gating at the classify-failure layer is the
    SOLE halt-apply site on the failure path. `_post_dispatch_apply_halt`
    is unaffected by ENG-78.

- **A-014 — `bin/run-stage.sh:1080-1084` clears `issue-state.json` and
  skip labels on the success path.**
  - `bin/run-stage.sh:1081` — `rm -f "$(issue_dir "$ident")/issue-state.json" 2>/dev/null || true`
  - `bin/run-stage.sh:1082` — `rm -f "$(issue_dir "$ident")/wait-${stage}.json" 2>/dev/null || true`
  - `bin/run-stage.sh:1083-1084` — remove `pipeline:skip-until-code-changes` / `pipeline:skip-until-human-acts`
  - **Status:** verified. The retry-immediately state file is cleaned up
    on a successful retry tick (Tick 2 Case A in the brainstorm's data
    flow §6). D-003 only changes the orphan-cleanup branch; the
    success-path cleanup is unmodified.

- **A-015 — `bin/pipeline.sh::_pipeline_drain_issue_state` (lines 207-226)
  removes `issue-state.json` only when `.policy == "skip-until-human-acts"`.**
  - `bin/pipeline.sh:211-213` — function entry, state file path
  - `bin/pipeline.sh:216-224` — `if [[ -s "$state_file" ]] && jq -e . "$state_file" >/dev/null 2>&1; then policy="$(jq -r '.policy // ""' "$state_file" …)"; if [[ "$policy" == "skip-until-human-acts" ]]; then rm -f "$state_file"; …`
  - **Status:** verified. `decide --action continue` on a
    retry-immediately issue does NOT drain the state file — the
    retry counter survives operator-resume. Brainstorm A-3 confirms
    this is intentional. D-003 inherits this without modification.

- **A-016 — `bin/classify-failure-test.sh:22-28` is the no-op `linear.sh`
  stub today; lines 31-37 are the existing capture-stub for `metrics.sh`
  (the pattern Task 4 mirrors).**
  - `bin/classify-failure-test.sh:22-28` — `for cmd in linear.sh slack.sh; do cat > "$STUB_DIR/$cmd" <<'SH' #!/usr/bin/env bash exit 0 SH chmod +x "$STUB_DIR/$cmd"; done`
  - `bin/classify-failure-test.sh:31-37` — capture-stub for metrics: `cat > "$STUB_DIR/metrics.sh" <<SH ... printf 'EVENT=%s\\n…' "\${1:-}" "\${2:-}" "\${3:-}" "\${4:-}" "\${5:-}" "\${6:-}" >> "$METRICS_CAPTURE" exit 0 SH`
  - **Status:** verified. Task 4's conversion of `linear.sh` to a
    capture-stub follows the same pattern; existing cases 1-15 do not
    assert on linear-stub output, so the conversion is non-breaking.

- **A-017 — `bin/poll-slot-test.sh:78-82` already routes
  `add-or-update-comment` and `add-label` calls to a no-op stub; the
  optional `LINEAR_STUB_LOG` capture file lets new tests assert on
  side effects without changing the default behavior.**
  - `bin/poll-slot-test.sh:78-83` — case arm for `remove-label|add-label|swap-stage|transition-state|add-comment|add-or-update-comment|refresh-cache|stage-of|has-label`: `[[ -n "${LINEAR_STUB_LOG-}" ]] && printf '%s\n' "$*" >> "$LINEAR_STUB_LOG"; exit 0`
  - **Status:** verified. New cases for D-003 don't need linear capture;
    they assert directly on filesystem state of `issue-state.json`.

- **A-018 — `issue_dir` from `bin/common.sh` resolves to
  `$PROJECT_STATE_DIR/<ident>` and is the canonical per-issue path
  helper used by both classify-failure and poll.sh.**
  - `bin/common.sh:67-72` — `issue_dir() { local id="$1"; [[ "$id" =~ ^[A-Z]+-[0-9]+$ ]] || die "issue_dir: invalid ident: $id"; printf '%s/%s' "$PROJECT_STATE_DIR" "$id"; }`
  - **Status:** verified. Both touchpoints (classify-failure and
    poll-evaluate-skip) resolve via this helper; nothing in this plan
    constructs paths by hand.

- **A-019 — `_poll_evaluate_skip`'s caller `_poll_classify_labels` reads
  the function's stdout for refreshed labels via
  `if ! refreshed_labels="$(_poll_evaluate_skip "$ident" "$labels_json")"; then`
  at `bin/poll.sh:197`.**
  - `bin/poll.sh:194-205` — the conditional + stdout-capture
  - **Status:** verified. The orphan-cleanup branch (lines 57-64) does
    NOT print to stdout — it falls through to `return 0` and the caller
    treats empty stdout as "no refresh needed" (line 205). D-003's
    `keep retry-immediately state` branch and `delete orphan` branch
    must both leave stdout empty to preserve this contract; both branches
    in Task 3 only emit `log` messages (which go to stderr via
    `bin/common.sh::log`'s `>&2` redirect — verified at
    `bin/common.sh::log`).

- **A-020 — `_poll_emit_halt_sprawl_alert` counts `slot == "vacate"`
  entries from `_poll_classify_all`'s output at `bin/poll.sh:332`, and
  vacates are gated on the halt label at line 217-233.**
  - `bin/poll.sh:332` — `count="$(jq '[.[] | select(.slot == "vacate")] | length' <<<"$classified_json")"`
  - **Status:** verified. With Task 1 not applying `pipeline:halted` on
    retry-immediately, the halt-sprawl threshold cannot be inflated by
    transient retries — G-6 holds without any new code in poll.sh.

- **A-021 — `bin/run-stage.sh::_post_dispatch_apply_halt` (lines 378-390)
  is the success-path halt-applier and is unchanged by ENG-78.**
  - `bin/run-stage.sh:378-390` — full function
  - `bin/run-stage.sh:386` — `if ! bash "$SCRIPT_DIR/linear.sh" has-label "$ident" "pipeline:halted"; then`
  - **Status:** verified. ENG-56's "orchestrator-canonical halt applier"
    invariant is preserved. The two halt-applier sites (classify-failure
    failure path; `_post_dispatch_apply_halt` success path) remain
    consistent with ENG-56 — the failure path's set just narrows.

- **A-022 — `apply_transition` removes `pipeline:halted` at
  `bin/verdict-handler.sh:273`.**
  - `bin/verdict-handler.sh:273` — `bash "$_VH_SCRIPT_DIR/linear.sh" remove-label "$issue" "pipeline:halted" || true`
  - **Status:** verified. On the auto-recovered tick (Tick 2 Case A in
    the brainstorm flow), the transition runs and removes the halt
    label that `_post_dispatch_apply_halt` briefly added on the success
    path. No halt-label leak.

- **A-023 — `CLAUDE.md:214-217` documents `issue-state.json` as
  "the durable state for the skip-label dance".**
  - `CLAUDE.md:214` — `'issue-state.json' is the durable state for the skip-label dance — 'poll.sh' reads it on`
  - **Status:** verified. Task 3 includes a one-line edit to the doc
    string to add "OR retry tracking" so the contract matches the new
    poll.sh behavior. (Brainstorm O-5 confirms this is small/clarifying.)

- **A-024 — `bin/halt-sprawl-test.sh` and
  `bin/halt-sprawl-adversarial-test.sh` exist and pin the halt-sprawl
  metric/Slack flow today; both are run by the pre-commit hook.**
  - `bin/halt-sprawl-test.sh:1` — `#!/usr/bin/env bash`
  - **Status:** verified. ENG-78 does not touch
    `_poll_emit_halt_sprawl_alert`; the existing tests must remain green
    after the fix.

## File Structure

- **MODIFIED** `bin/classify-failure.sh` — Task 1 replaces lines 117-119
  with a `case "$effective_policy"`-gated `add-label`; Task 2 replaces the
  halt-comment block at lines 121-146 with an outer
  `case "$effective_policy"` that emits the today-shape halt marker for
  `skip-until-code-changes`/`skip-until-human-acts` and a meta-shape
  comment under sig `retry-pending/$stage/$issue` for `retry-immediately`.
- **MODIFIED** `bin/poll.sh` — Task 3 inserts a `jq -r '.policy // ""'`
  read + branch in `_poll_evaluate_skip` (lines 57-64) so a state file
  with `.policy == "retry-immediately"` is preserved across orphan
  cleanup (so classify-failure's `retry_count` survives ticks).
- **MODIFIED** `bin/classify-failure-test.sh` — Task 4 converts the
  no-op `linear.sh` stub at lines 22-28 to a capture-stub mirroring the
  `metrics.sh` capture at lines 31-37, then appends four cases: case-N
  (retry-immediately fresh hit no halt label), case-N+1 (auto-escalation
  applies halt label), case-N+2 (skip-until-human-acts applies halt
  label), case-N+3 (retry-immediately uses meta-shape sig + body).
- **MODIFIED** `bin/poll-slot-test.sh` — Task 5 appends two cases:
  D-003-1 (state file with `policy=retry-immediately` is preserved when
  no skip label is present) and D-003-2 adversarial (state file with
  `policy=skip-until-code-changes` AND no skip label is still treated as
  orphan).
- **MODIFIED** `CLAUDE.md` — Task 6 edits the one-line doc string at
  line 214 to add "OR retry tracking" so the documented `issue-state.json`
  contract matches the new poll.sh behavior.

No new files. No new exports. No new env vars. No changes to
`bin/pipeline-events.json`. No changes to `bin/run-stage.sh` (the
retry-immediately call sites at 813-817, 982-986, 1004-1009 are
unmodified — Task 1+2 changes behavior INSIDE `classify_failure`).

## API Contract

no new API surface (this is a bash-orchestration repo with no FE↔BE API;
the only "interface" change is the new comment sig `retry-pending/$stage/$issue`
and the new Linear comment shape, both of which are documented in Task 2's
implementation steps and the brainstorm §4 D-002).

## Backend Tasks

### Task 1: Gate `pipeline:halted` apply in `classify_failure` on `effective_policy`

- `depends_on: []`
- `touches: bin/classify-failure.sh::classify_failure (lines 117-119)`
- [ ] In `bin/classify-failure.sh`, replace lines 117-119 (the
      `# ENG-18: every policy outcome is a halt surface ...` comment + the
      unconditional `bash "$_CFS_SCRIPT_DIR/linear.sh" add-label "$issue" "pipeline:halted" || true`)
      with the following `case` block:

```bash
# ENG-78: only the halt-policy branches apply pipeline:halted.
# retry-immediately is the explicit non-halt failure path — poll.sh
# re-dispatches automatically on the next tick. The auto-escalation
# guard at lines 67-77 will flip effective_policy to
# skip-until-code-changes after retry_count >= 2 same-evidence
# retries; that branch DOES apply the halt label below.
case "$effective_policy" in
  skip-until-code-changes|skip-until-human-acts)
    bash "$_CFS_SCRIPT_DIR/linear.sh" add-label "$issue" "pipeline:halted" || true
    ;;
  retry-immediately)
    : # no halt; orchestrator re-dispatches next tick (ENG-78)
    ;;
esac
```

- [ ] Confirm the existing skip-label dance at lines 105-115 still runs
      BEFORE the new `case` block (it does — Task 1 only replaces 117-119,
      not the surrounding code).

### Task 2: Split halt-comment block on `effective_policy`; emit meta-shape comment for retry-immediately

- `depends_on: [1]`
- `touches: bin/classify-failure.sh::classify_failure (lines 121-146)`
- [ ] In `bin/classify-failure.sh`, replace the entire halt-comment block
      at lines 121-146 (from `# Halt comment (edit-in-place via sig). ...`
      through `bash "$_CFS_SCRIPT_DIR/linear.sh" add-or-update-comment "$sig" "$issue" "$comment_body" || true`)
      with:

```bash
# ENG-78: split comment shape on effective_policy.
# Halt-policy arms post the same halt-shape verdict marker as today
# (preserves verdict-handler / find_fresh_verdict / status.sh behavior).
# retry-immediately posts a meta-shape transient-retry comment under a
# distinct sig so an auto-escalation tick later (effective_policy →
# skip-until-code-changes) creates a NEW halt comment with its OWN
# createdAt rather than overwriting in place. find_fresh_verdict
# excludes meta-shape (event != "verdict" filter at
# verdict-handler.sh:111), so the retry-pending comment never registers
# as a halt verdict and never trips the halt-sprawl threshold.
case "$effective_policy" in
  skip-until-code-changes|skip-until-human-acts)
    local sig="halt/$stage/$issue"
    local marker_reason
    case "$effective_policy" in
      skip-until-human-acts) marker_reason="agent-blocked" ;;
      *)                     marker_reason="agent-failure" ;;
    esac
    local comment_body
    comment_body="$(printf '<!-- pipeline: verdict result=halt reason=%s -->\n\nPipeline: `%s` stage halted — %s\n\n**Policy:** %s\n**Recorded at:** %s\n**Branch:** %s\n**Retry count:** %d\n\n**Resume:** ' \
      "$marker_reason" "$stage" "$effective_reason" "$effective_policy" "$recorded_at" "${branch:-none}" "$retry_count")"
    case "$effective_policy" in
      skip-until-code-changes)
        comment_body+="$(printf 'auto-resumes when `.pipeline/{bin,config.json,AGENT_PROMPTS.md}` content hash OR `origin/%s` HEAD changes, OR when `pipeline:skip-until-code-changes` label is removed.' "${branch:-<branch>}")"
        ;;
      skip-until-human-acts)
        comment_body+="remove the \`pipeline:skip-until-human-acts\` label when the underlying issue is resolved."
        ;;
    esac
    comment_body+="$(printf '\n\n**Evidence:**\n- pipeline_content_hash: `%s`\n- branch_head_sha: `%s`\n' "$current_hash" "${current_sha:-<none>}")"
    bash "$_CFS_SCRIPT_DIR/linear.sh" add-or-update-comment "$sig" "$issue" "$comment_body" || true
    ;;
  retry-immediately)
    local sig="retry-pending/$stage/$issue"
    local remaining=$((2 - retry_count))
    local comment_body
    comment_body="$(printf '<!-- meta: metric name=transient-retry stage=%s attempt=%d -->\n\nPipeline: transient `%s`-stage failure — %s\n\n**Status:** retry-pending (attempt %d of 2 before auto-escalation to `skip-until-code-changes`).\n**Recorded at:** %s\n**Branch:** %s\n\nThe pipeline will re-dispatch this stage on the next tick. If the same evidence reproduces this failure %d more time(s), the orchestrator will halt the issue with `pipeline:skip-until-code-changes` for operator visibility.\n\n**Evidence:**\n- pipeline_content_hash: `%s`\n- branch_head_sha: `%s`\n' \
      "$stage" "$retry_count" "$stage" "$effective_reason" "$retry_count" "$recorded_at" "${branch:-none}" "$remaining" "$current_hash" "${current_sha:-<none>}")"
    bash "$_CFS_SCRIPT_DIR/linear.sh" add-or-update-comment "$sig" "$issue" "$comment_body" || true
    ;;
esac
```

- [ ] Verify by inspection that:
  - the `skip-until-code-changes`/`skip-until-human-acts` body is
    byte-identical to today's body (only the surrounding `case` is new),
  - the `retry-immediately` body uses `<!-- meta: metric name=transient-retry stage=<stage> attempt=<n> -->`
    as the first line (not `<!-- pipeline: verdict result=halt -->`),
  - the new sig namespace is `retry-pending/$stage/$issue` (not `halt/...`).

### Task 3: Preserve `issue-state.json` orphan when `policy=retry-immediately` in `_poll_evaluate_skip`

- `depends_on: []`
- `touches: bin/poll.sh::_poll_evaluate_skip (lines 57-64)`
- [ ] In `bin/poll.sh`, replace lines 57-64 (the `if [[ -f "$state_file" ]];
      then log "poll: orphan state file ..."; rm -f "$state_file"; fi`
      block inside the `if [[ "$has_code_label" != "true" && ... ]]` arm)
      with a policy-aware variant:

```bash
# No skip label AND no state file → normal eligible candidate.
if [[ "$has_code_label" != "true" && "$has_human_label" != "true" ]]; then
  if [[ -f "$state_file" ]]; then
    # ENG-78: a state file with policy=retry-immediately is NOT
    # orphan — it's the durable retry-tracking record that
    # classify_failure's auto-escalation guard reads on every tick
    # to compute retry_count. Removing it would reset the counter
    # to 0 each tick and break the 2-retry escalation cap. Only
    # delete state files whose policy is genuinely orphaned (the
    # original use case: human removed a skip label without
    # removing the file, or pre-ENG-78 leftover).
    local cur_policy
    cur_policy="$(jq -r '.policy // ""' "$state_file" 2>/dev/null || true)"
    if [[ "$cur_policy" == "retry-immediately" ]]; then
      log "poll: keeping retry-immediately state for $ident (active retry tracking, ENG-78)"
    else
      log "poll: orphan state file for $ident (no skip label, policy=$cur_policy); removing"
      rm -f "$state_file"
    fi
  fi
  return 0
fi
```

- [ ] Confirm by inspection that NEITHER branch prints to stdout (only
      `log` calls, which go to stderr per `bin/common.sh::log`); the
      caller `_poll_classify_labels` at line 197 reads stdout for
      refreshed labels, and an empty stdout signals "no refresh needed".

### Task 4: Extend `bin/classify-failure-test.sh` with linear-capture stub + 4 cases

See full sketch under "Test Strategy → Unit (Task 4)" below.

- `depends_on: [1, 2]`
- `touches: bin/classify-failure-test.sh (lines 22-28; append 4 cases before "─── Summary")`

### Task 5: Extend `bin/poll-slot-test.sh` with D-003 cases

See full sketch under "Test Strategy → Integration (Task 5)" below.

- `depends_on: [3]`
- `touches: bin/poll-slot-test.sh (append before final summary)`

### Task 6: Update CLAUDE.md doc string for `issue-state.json` contract

- `depends_on: []`
- `touches: CLAUDE.md (line 214)`
- [ ] In `CLAUDE.md`, find the line beginning
      `'issue-state.json' is the durable state for the skip-label dance`
      (line 214 today) and change `the skip-label dance` to
      `the skip-label dance OR retry tracking`.

## Frontend Tasks

(no UI surface in this repo)

## Failure Mode → Test Map

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
|---|---|---|---|---|
| Transient API outage on dispatch (529 Overloaded) | `dispatch.sh` exits non-zero with retry-immediately classification on first hit | `pipeline:halted` is NOT applied; meta-shape `retry-pending/<stage>/<issue>` comment posted | unit | `bin/classify-failure-test.sh` case-N "retry-immediately fresh hit does NOT apply pipeline:halted" |
| Same transient repeats with same evidence × 3 | Three consecutive retry-immediately calls with identical pipeline_content_hash + branch_head_sha | Third call escalates `effective_policy` to `skip-until-code-changes` and DOES apply `pipeline:halted` + halt-shape verdict marker | unit | `bin/classify-failure-test.sh` case-N+1 "auto-escalated retry-immediately applies pipeline:halted" |
| Severe scope violation / dispatch timeout / lane violation | `classify_failure` called with `base_policy=skip-until-human-acts` | `pipeline:halted` IS applied; halt-shape verdict marker posted under sig `halt/<stage>/<issue>` (no regression) | unit | `bin/classify-failure-test.sh` case-N+2 "skip-until-human-acts applies pipeline:halted" |
| retry-immediately first hit comment shape | retry-immediately classify call | Linear comment uses sig `retry-pending/<stage>/<issue>` and body contains `<!-- meta: metric name=transient-retry ... -->` (NOT `<!-- pipeline: verdict result=halt -->`) | unit | `bin/classify-failure-test.sh` case-N+3 "retry-immediately uses retry-pending meta-shape" |
| State-file persistence across ticks for retry-immediately | `_poll_evaluate_skip` runs on issue with state file `policy=retry-immediately` and no skip label | State file is preserved; function returns 0 (eligible) | integration | `bin/poll-slot-test.sh` case "D-003 retry-immediately state preserved when no skip label" |
| State-file orphan cleanup for non-retry policies | `_poll_evaluate_skip` runs on issue with state file `policy=skip-until-code-changes` and no skip label | State file is deleted (pre-ENG-78 orphan-cleanup behavior preserved) | integration | `bin/poll-slot-test.sh` case "D-003 adversarial: orphan skip-until-* state still cleaned up" |
| Halt-sprawl alert on transient retries | retry-immediately failures across N issues | retry-immediately issues do NOT trip the halt-sprawl threshold (G-6); existing `bin/halt-sprawl-test.sh` remains green | integration | `bin/halt-sprawl-test.sh` (existing — must remain green; verified by Task 4 case-N's no-halt-label assertion) |
| Operator-resume on retry-immediately state file | `bin/pipeline.sh decide --action continue` on issue with state file `policy=retry-immediately` | State file is preserved (existing behavior at `bin/pipeline.sh:211-226`); retry counter survives operator resume | integration | covered by existing `bin/pipeline-test.sh` `_pipeline_drain_issue_state` cases — no new test needed (A-015) |

## Test Strategy

### Unit (Task 4 detail)

`bin/classify-failure-test.sh` is the function-level harness. Convert the
no-op `linear.sh` stub at lines 22-28 to a capture-stub mirroring the
existing `metrics.sh` capture at lines 31-37; add four cases pinning the
new `case "$effective_policy"`-gated behavior in `classify_failure`.

Implementation steps for Task 4:

- [ ] Replace the `for cmd in linear.sh slack.sh; do … exit 0 SH …`
      block at lines 22-28 with a split: `slack.sh` keeps the no-op stub;
      `linear.sh` becomes a capture-stub. Insert the following BEFORE the
      `# metrics.sh as a capture stub …` comment at line 29:

```bash
# Capture-stub for linear.sh (ENG-78). Records every invocation as a
# single line in $LINEAR_CAPTURE for assertions. Mirrors the
# metrics.sh capture pattern below.
LINEAR_CAPTURE="$STUB_DIR/linear.capture"
: > "$LINEAR_CAPTURE"
cat > "$STUB_DIR/linear.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$LINEAR_CAPTURE"
exit 0
SH
chmod +x "$STUB_DIR/linear.sh"

# slack.sh stays a no-op stub (no test asserts on slack invocations).
cat > "$STUB_DIR/slack.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$STUB_DIR/slack.sh"
```

- [ ] Add `reset_linear() { : > "$LINEAR_CAPTURE"; }` and
      `linear_calls() { cat "$LINEAR_CAPTURE"; }` helpers next to the
      existing `latest_outcome` / `latest_notes` / `reset_metrics`
      helpers (around line 66-68).
- [ ] Append the four new test cases AFTER case-15 (line 215) and BEFORE
      the `# ─── Summary` block (line 217). Use the patterns established
      by cases 1-15 (`reset_state`, `MOCK_PIPELINE_HASH=… MOCK_BRANCH_SHA=…
      classify_failure …`, `pass_at`/`fail_at`).

```bash
# ─── Test 16 (ENG-78 D-001): retry-immediately fresh hit no halt label ────
reset_state; reset_linear
MOCK_PIPELINE_HASH="hashG" MOCK_BRANCH_SHA="shaG" \
  classify_failure "ENG-920" "implement" "retry-immediately" "API-529" 20 ""
if linear_calls | grep -q '^add-label ENG-920 pipeline:halted$'; then
  fail_at "case-16 retry-immediately fresh hit must NOT apply pipeline:halted (ENG-78 D-001)" \
    "got: $(linear_calls | grep pipeline:halted)"
else
  pass_at "case-16 retry-immediately fresh hit does NOT apply pipeline:halted (ENG-78 D-001)"
fi

# ─── Test 17 (ENG-78 D-001): retry-immediately auto-escalation applies halt ─
reset_state
MOCK_PIPELINE_HASH="hashH" MOCK_BRANCH_SHA="shaH" \
  classify_failure "ENG-921" "implement" "retry-immediately" "r1" 20 ""
MOCK_PIPELINE_HASH="hashH" MOCK_BRANCH_SHA="shaH" \
  classify_failure "ENG-921" "implement" "retry-immediately" "r2" 20 ""
reset_linear
MOCK_PIPELINE_HASH="hashH" MOCK_BRANCH_SHA="shaH" \
  classify_failure "ENG-921" "implement" "retry-immediately" "r3" 20 ""
if linear_calls | grep -q '^add-label ENG-921 pipeline:halted$'; then
  pass_at "case-17 auto-escalated retry-immediately applies pipeline:halted (ENG-78 G-2)"
else
  fail_at "case-17 auto-escalated retry-immediately should apply pipeline:halted" \
    "got: $(linear_calls)"
fi

# ─── Test 18 (ENG-78 G-3): skip-until-human-acts applies halt verbatim ────
reset_state; reset_linear
MOCK_PIPELINE_HASH="hashI" MOCK_BRANCH_SHA="shaI" \
  classify_failure "ENG-922" "implement" "skip-until-human-acts" "severe" 21 3
if linear_calls | grep -q '^add-label ENG-922 pipeline:halted$'; then
  pass_at "case-18 skip-until-human-acts applies pipeline:halted (ENG-78 G-3)"
else
  fail_at "case-18 skip-until-human-acts should apply pipeline:halted" \
    "got: $(linear_calls)"
fi

# ─── Test 19 (ENG-78 D-002): retry-immediately uses retry-pending meta-shape ─
reset_state; reset_linear
MOCK_PIPELINE_HASH="hashJ" MOCK_BRANCH_SHA="shaJ" \
  classify_failure "ENG-923" "implement" "retry-immediately" "API-529" 20 ""
last_aoc="$(linear_calls | grep '^add-or-update-comment' | tail -1)"
# Sig must contain retry-pending/, body must NOT contain halt verdict marker,
# body must contain meta:metric transient-retry header.
if [[ "$last_aoc" == *"retry-pending/implement/ENG-923"* ]] \
   && [[ "$last_aoc" != *"<!-- pipeline: verdict result=halt"* ]] \
   && [[ "$last_aoc" == *"<!-- meta: metric name=transient-retry"* ]]; then
  pass_at "case-19 retry-immediately uses retry-pending sig + meta-shape body (ENG-78 D-002)"
else
  fail_at "case-19 retry-immediately marker shape" "got: $last_aoc"
fi
```

- [ ] Run `bash bin/classify-failure-test.sh` and confirm 19 cases pass
      (15 existing + 4 new).

### Integration (Task 5 detail)

`bin/poll-slot-test.sh` already sources `poll.sh` and overrides
`SCRIPT_DIR` to redirect linear/metrics/slack subprocess calls through a
stub harness. Add two cases that exercise `_poll_evaluate_skip` directly.

Implementation steps for Task 5:

- [ ] Append the following AFTER the last existing test case and BEFORE
      the final `printf '\npoll-slot: passed=…' "$PASS" "$FAIL"` summary.
      The cases use the existing `pass_at`/`fail_at` helpers and the
      `issue_dir` resolver from `common.sh`.

```bash
# ─── ENG-78 D-003: retry-immediately state preserved across orphan cleanup ──
# Setup: a state file with policy=retry-immediately, labels set without
# either skip-until-* label.
reset_fixtures
mkdir -p "$(issue_dir ENG-925)"
printf '{"policy":"retry-immediately","retry_count":1,"evidence":{"pipeline_content_hash":"h1","branch_head_sha":"s1"},"branch":"feat/eng-925"}' \
  > "$(issue_dir ENG-925)/issue-state.json"

labels='["stage:implementing"]'
# _poll_evaluate_skip returns 0 (include); we don't read its stdout here —
# we only verify the side effect on the state file.
if _poll_evaluate_skip "ENG-925" "$labels" >/dev/null 2>&1; then
  if [[ -f "$(issue_dir ENG-925)/issue-state.json" ]]; then
    pass_at "ENG-78 D-003: retry-immediately state preserved when no skip label"
  else
    fail_at "ENG-78 D-003: retry-immediately state was deleted (orphan-cleanup overreach)" \
      "$(issue_dir ENG-925)/issue-state.json missing after _poll_evaluate_skip"
  fi
else
  fail_at "ENG-78 D-003: _poll_evaluate_skip should return 0 (include) for retry-immediately" \
    "non-zero exit"
fi

# ─── ENG-78 D-003 adversarial: orphan skip-until-* state still cleaned up ──
# A state file with policy=skip-until-code-changes BUT no skip label is
# still treated as orphan (pre-ENG-78 orphan-cleanup behavior preserved).
reset_fixtures
mkdir -p "$(issue_dir ENG-926)"
printf '{"policy":"skip-until-code-changes","retry_count":2,"evidence":{"pipeline_content_hash":"h2","branch_head_sha":"s2"},"branch":"feat/eng-926"}' \
  > "$(issue_dir ENG-926)/issue-state.json"
labels='["stage:implementing"]'
if _poll_evaluate_skip "ENG-926" "$labels" >/dev/null 2>&1; then
  if [[ ! -f "$(issue_dir ENG-926)/issue-state.json" ]]; then
    pass_at "ENG-78 D-003 adversarial: orphan skip-until-code-changes state cleaned up"
  else
    fail_at "ENG-78 D-003 adversarial: skip-until-code-changes orphan was preserved (overreach)" \
      "state file still exists after _poll_evaluate_skip"
  fi
else
  fail_at "ENG-78 D-003 adversarial: _poll_evaluate_skip should return 0 for orphan" \
    "non-zero exit"
fi
```

- [ ] Run `bash bin/poll-slot-test.sh` and confirm all existing cases
      still pass plus the two new D-003 cases.

### Smoke / pre-commit gate

The pre-commit hook runs the full `bin/*-test.sh` suite (~30 s per
CLAUDE.md "Pre-commit hook" §). After Tasks 1-5, run the suite locally:

```bash
bash bin/classify-failure-test.sh
bash bin/poll-slot-test.sh
bash bin/halt-sprawl-test.sh
bash bin/halt-sprawl-adversarial-test.sh
bash bin/run-stage-test.sh
bash bin/verdict-handler-test.sh
```

All must remain green. The halt-sprawl tests are the load-bearing
regression check for G-6 (transient retries do not trip the halt-sprawl
threshold) — they must pass without modification because Task 1 removes
the only path by which a transient retry was inflating the vacate count.

### Adversarial coverage already in Failure Mode → Test Map

- `case-N+1` (Task 4): proves the auto-escalation escape valve still
  fires (G-2). If a regression accidentally drops the
  `skip-until-code-changes` arm from Task 1's `case`, this case fails.
- `case-N+2` (Task 4): proves `skip-until-human-acts` halt path is
  unchanged (G-3). If a regression conflates retry-immediately and
  skip-until-human-acts under one bare-`retry-immediately`-only check,
  this case fails.
- `D-003-2` (Task 5): proves the orphan-cleanup property survives. If a
  regression preserves state files unconditionally (path B's
  loosening), this case fails.

### Out-of-scope tests (per brainstorm)

- D-004c (run-stage-test.sh end-to-end fixture stubbing dispatch.sh exit
  20): the brainstorm flags this as "RECOMMENDED but lower priority" —
  the function-level coverage in case-N already pins the load-bearing
  contract (no halt label on retry-immediately). Deferred to a follow-up
  if the operator wants end-to-end coverage.

## Self-review

Personas — feasibility, scope, coherence, design, product — will be run
via `compound-engineering:document-review` after the draft is committed.
Required gate: 4/5 PASS, zero P0 findings (codebase-fact errors,
malformed API contract block, missing `depends_on`/`touches` metadata,
unbound Failure Mode rows). Iterate at most 3 times.
