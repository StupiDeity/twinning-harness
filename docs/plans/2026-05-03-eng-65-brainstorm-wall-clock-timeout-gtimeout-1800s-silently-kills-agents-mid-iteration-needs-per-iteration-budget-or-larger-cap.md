---
linear: ENG-65
date: 2026-05-03
topic: brainstorm wall-clock timeout — bound iterations, capture partial spend, raise cap
---

# Plan — ENG-65 brainstorm wall-clock timeout

Implementation plan for the design in
`docs/brainstorms/2026-05-03-eng-65-brainstorm-wall-clock-timeout-gtimeout-1800s-silently-kills-agents-mid-iteration-needs-per-iteration-budget-or-larger-cap-design.md`.

## Anti-anchoring

- **Problem (operator's words):** the 30-min `gtimeout` watchdog SIGTERMs
  brainstorm agents mid-iteration; cost telemetry is zeroed (`cost_usd: 0`
  in metrics) despite real Anthropic spend, the issue lands in
  `skip-until-human-acts`, and operators have to manually unblock —
  wasting both spend and operator time. Concrete incident: ENG-58 brainstorm
  killed at iter-2 5/6 PASS; manual resume completed in 2m38s using the
  preserved worktree.
- **Does the brainstorm address it?** Yes, on all three Linear ACs.
  D-001 binds iteration count at the source (prompt edit; cheapest
  fix). D-002 backstops by raising the wall-clock cap for the two
  legitimately-slow stages. D-003 captures spend even on SIGTERM. D-004
  preserves the operator-recovery flow with one new hint line. D-005
  scopes to brainstorm only per the Linear AC text.
- **Proportional?** Yes. Three additive changes plus one CLAUDE.md
  paragraph and test fixtures. No new files, no schema migration, no
  new lanes, no new pipeline-event tokens (`iteration-exhausted` and
  `dispatch-timeout` are already in `bin/pipeline-events.json:14,17`).
- **No escalation needed.**

## Goal

Ship D-001 (brainstorm prompt: voluntary halt at iteration 2),
D-002 (per-stage `dispatch_timeout_minutes_per_stage` config + 60-min
built-in defaults for `brainstorming` / `planning`), D-003 (partial
`usage-<stage>.json` from summed `assistant.message.usage` on SIGTERM),
and D-004 (worktree-resume hint on `dispatch-timeout` halt comment) —
verifiable by `bash bin/dispatch-test.sh && bash bin/run-stage-test.sh && bash -n bin/dispatch.sh bin/run-stage.sh && bash bin/render-prompt-test.sh`
exiting 0 with the new fixtures (per-stage override, fallthrough,
built-in default, zero-rejection guard, partial-usage extraction) in
PASS state and existing fixtures unchanged.

## Assumption Inventory

Format: `[verified|assumed]` — `path:line` reference (or "assumed/new"
with the file where it will be created).

### Verified — current code being modified

- **A-001 — `bin/dispatch.sh:273-279` reads `_cfg_minutes` with a single
  precedence: `.orchestrator.dispatch_timeout_minutes // empty` →
  `[[ =~ ^[0-9]+$ ]]` guard → default 30.** Verified at:
  ```bash
  local timeout_minutes=30
  if [[ -f "$CONFIG" ]]; then
    local _cfg_minutes
    _cfg_minutes="$(jq -r '.orchestrator.dispatch_timeout_minutes // empty' "$CONFIG" 2>/dev/null || true)"
    [[ -n "$_cfg_minutes" && "$_cfg_minutes" =~ ^[0-9]+$ ]] && timeout_minutes="$_cfg_minutes"
  fi
  local timeout_seconds=$(( timeout_minutes * 60 ))
  ```
  Task 1 extends this block in place (adds per-stage override
  precedence + per-stage built-in defaults + `(( minutes >= 1 ))` guard).
  `$stage` is in scope at this point — declared at `bin/dispatch.sh:237`.
- **A-002 — `bin/dispatch.sh:312-320` is the gtimeout invocation
  literal.** Verified:
  ```bash
  local cmd=(env PIPELINE_WRITER=agent
    gtimeout --signal=TERM --kill-after=10 "$timeout_seconds"
    claude -p
    --output-format stream-json --verbose
    --setting-sources project,local
    --disable-slash-commands
    --disallowed-tools "$denies"
    --allowed-tools "$tools"
  )
  ```
  Unchanged by this plan; only `$timeout_seconds` resolution upstream
  changes.
- **A-003 — `bin/dispatch.sh:94-148` is the `_render_and_capture_stream`
  function; the post-stream extractor block lives at lines 126-148** and
  branches on whether `last_result` (grep `'"type":"result"'` | tail -1)
  is non-empty. Today the empty branch only logs "no result event found
  in stream (soft fail; usage-<stage>.json not written)" at line 147.
  Task 2 inserts the partial-usage fallback inside that empty branch
  before the soft-fail log, preserving the unconditional return-0
  invariant. The implementing-stage `assert_no_tool_invocation` block
  at lines 150-163 (the only `return 22` exit in the function) remains
  AFTER the post-stream block; ordering is preserved.
- **A-004 — `${issue_dir}/.raw-stream.ndjson.tmp` is written by `tee`
  synchronously to disk and removed by RETURN trap.** Verified at
  `bin/dispatch.sh:96-99,109`:
  ```bash
  local raw_capture="${issue_dir}/.raw-stream.ndjson.tmp"
  ...
  trap 'rm -f "$raw_capture"' RETURN
  ...
  tee "$raw_capture" \
  ```
  Task 2 reads back from `$raw_capture` after the pipe drains; the
  file persists until RETURN, so the read happens before cleanup.
- **A-005 — `system`/`init` event carries `.model`** consumed at
  `bin/dispatch.sh:114-115` for the prose-on-stdout `[claude] session=…
  model=…` line. Task 2 reuses the same field for the partial-usage
  `model` slot.
- **A-006 — `bin/run-stage.sh:567-576` is the `dispatch_rc == 124`
  branch.** Verified:
  ```bash
  if (( dispatch_rc == 124 )); then
    classify_failure "$ident" "$stage" "skip-until-human-acts" \
      "dispatch wall-clock timeout — agent exceeded budget without exiting" 124
    rm -f "$prompt_file"
    exit 124
  ```
  Task 4 extends only the reason-string argument (third positional
  after stage); policy `skip-until-human-acts` and exit code 124 are
  preserved per D-004.
- **A-007 — `bin/common.sh:126` maps exit 124 → `dispatch-timeout`.**
  Unchanged; not modified by this plan but referenced by Task 4's halt
  comment text.
- **A-008 — `AGENT_PROMPTS.md:288-291` is the existing brainstorm
  iteration-cap wording:**
  > 3. **Iterate until the gate passes**: at least 5/6 personas return
  >    PASS AND feasibility returns zero P0 findings. Iterate at most 3
  >    times. If any P0 remains after iteration 3, set status = `escalate`
  >    and proceed to step 5 with an escalation comment rather than a
  >    success comment. Do NOT silently exit.

  Task 3 replaces this paragraph with a 2-iteration cap + voluntary
  halt instruction. The §1 Brainstorm Agent fenced block runs
  219..331 — exactly two ``` fences (verified by reading the block);
  Task 3 does NOT add or remove fences.
- **A-009 — `AGENT_PROMPTS.md:303-304` is the now-dead
  `brainstorm_escalate` bullet inside step 5:**
  > - Escalate tag: `<!-- meta: metric name=brainstorm_escalate -->` if
  >   any P0 remained after iteration 3.

  Task 3 deletes this bullet. Verified that no harness reader consumes
  the marker — `grep -rn brainstorm_escalate bin/` returns no matches
  (the only `brainstorm_escalate` reference in the tree is this prompt
  bullet itself); the retrospective ingests `events.jsonl` not per-issue
  meta markers, so dropping the bullet is observable to operators
  reading the comment thread but to no automated consumer.
- **A-010 — `bin/pipeline-events.json:14,17` already contains
  `iteration-exhausted` and `dispatch-timeout` in `halt_reasons`.**
  No registry change required by this plan; `bash bin/pipeline.sh
  event ENG-N verdict halt --reason iteration-exhausted` validates.
- **A-011 — `bin/dispatch-test.sh:262-322` is Group 5 ("ENG-48: gtimeout
  watchdog wraps claude -p"); the existing per-target custom-config
  fixture at lines 296-322 demonstrates the dry-run-log-grep pattern
  Task 6 reuses for the new per-stage override fixtures.** Verified:
  ```bash
  TARGET_REPO_CUSTOM="$_TEST_STUB_DIR/target-custom"
  mkdir -p "$TARGET_REPO_CUSTOM/.pipeline-config/schemas"
  jq -n '{ ... orchestrator: { ... dispatch_timeout_minutes: 5 } }' > "$TARGET_REPO_CUSTOM/.pipeline-config/config.json"
  ...
  PIPELINE_DRY_RUN=1 TARGET_REPO="$TARGET_REPO_CUSTOM" ... bash "$SCRIPT_DIR/dispatch.sh" brainstorming "$_PROMPT_FILE" 2>"$DRYRUN_OUT_C" >/dev/null || true
  if grep -qE 'gtimeout.*\b300\b' "$DRYRUN_OUT_C"; then
    pass_at "..."
  ```
  New fixtures slot in alongside.
- **A-012 — Fixtures in Group 3 of `bin/dispatch-test.sh:350-643`
  exercise `_render_and_capture_stream` directly with NDJSON heredocs
  on stdin.** Existing fixtures occupy letters A through K
  (`bin/dispatch-test.sh:350,427,443,461,482,514,536,562,574,602,624`).
  The next free letter is **L**. Task 6 adds Fixture L (partial-usage
  success) using the same heredoc + `_render_and_capture_stream
  "$USAGE" "$ISSUE_DIR" <<'NDJSON' ... NDJSON` pattern. Note
  particularly that **existing Fixture H at `bin/dispatch-test.sh:562-572`
  already covers the "empty stdin → no events → no usage file →
  soft-fail log" path** that the plan's empty-NDJSON edge case
  describes; under D-003's new contract that path remains a soft-fail
  (zero `tokens_in+out` triggers the `_partial_sum > 0` guard, so no
  file is written), so existing Fixture H continues to PASS and
  doubles as the negative-case test for Task 2 — no separate
  zero-tokens fixture needed.
- **A-013 — `_cost_flags_for` at `bin/run-stage.sh:73-85` reads
  `usage-<stage>.json` with `// 0` defaults on every field; missing
  file silently returns 0 (line 76: `[[ -s "$f" ]] || return 0`).**
  Specifically `bin/run-stage.sh:82` reads `(.cost_usd // 0 | tostring)`.
  jq's `//` operator treats `null` as the trigger value, so a partial
  usage file with `cost_usd: null` causes `_cost_flags_for` to emit
  `--cost-usd 0` (string literal `"0"`), NOT `--cost-usd null`. This
  is the existing zero-coalesce behavior and is downstream-safe — no
  metrics.sh tolerance work needed. The partial path therefore
  observably looks like a clean zero-cost dispatch from
  `_cost_flags_for`'s perspective; the `partial: true` marker on the
  file itself is the discriminator the retrospective reads, not the
  flag stream. Verified `_cost_footer` at `bin/run-stage.sh:104` uses
  the same `// 0` pattern and behaves identically. Implementation
  note for Task 2: write `cost_usd` as the JSON literal `null`
  (not `0`, not `"null"`), so the file shape is unambiguously
  partial when inspected directly; the flag stream's `0` coercion
  is acceptable downstream.
- **A-014 — `bin/dispatch.sh:130-145` `last_result` extraction uses
  `jq` with `// 0` defaults**, providing the field-naming source of
  truth for D-003's parallel jq filter:
  ```jq
  tokens_in:    (.usage.input_tokens // 0),
  tokens_out:   (.usage.output_tokens // 0),
  cache_read:   (.usage.cache_read_input_tokens // 0),
  cache_create: (.usage.cache_creation_input_tokens // 0),
  ```
  D-003 targets the same field names but inside
  `assistant.message.usage.*` per-message rather than aggregated
  `result.usage.*`.
- **A-015 — CLAUDE.md "Per-target dispatch.tools extras (ENG-51, ENG-53
  #8)" subsection lives at CLAUDE.md:233-262.** Task 5 inserts a
  parallel "Per-stage dispatch timeouts (ENG-65)" subsection
  immediately after this block (around line 263 of the live file at
  insertion time), mirroring its prose style and fenced-json example.

### Assumed — needs validation during implementation or new code

- **B-001 — `claude -p`'s stream-json `assistant` events carry
  `.message.usage.{input_tokens,output_tokens,cache_read_input_tokens,cache_creation_input_tokens}`
  per turn.** No current test fixture exercises the per-message usage
  path (`bin/dispatch-test.sh:357-359, 433, 449, 469, 525, 591` use
  content-only assistant events). Brainstorm §9 flags this as an
  implementation TODO. **Mitigation:** Task 2 captures one real
  stream-json transcript before/during implementation
  (`PROJECT_STATE_DIR/<slug>/<issue>/logs/<stage>-*.log` from any
  recent dispatch, or run a one-shot dispatch with renderer output to a
  scratch file). If field names differ at the per-message layer,
  adjust the jq filter; if usage is only emitted on the FIRST or LAST
  assistant event of a turn (cumulative-for-turn), use the LAST
  assistant.message.usage value directly rather than summing. Either
  variant is contained inside the new fallback block; downstream
  schema is identical.
- **B-002 — `gtimeout --signal=TERM --kill-after=10 0 <cmd>` runs
  `<cmd>` unbounded** (no timeout fires). This is GNU coreutils
  documented behavior for `--duration=0`. **Mitigation:** Task 1 adds a
  `(( minutes >= 1 ))` guard regardless. Verifying the underlying
  gtimeout behavior is not blocking — the guard is a safety net
  whether or not 0 is the no-timeout sentinel.
- **B-003 — `partial: true` and `cost_usd: null` in
  `usage-<stage>.json` do not break existing consumers
  (`_cost_flags_for`, `_cost_footer`, `metrics.sh stage-end`,
  retrospective input parsing).** Verified that `_cost_flags_for`
  uses `// 0` defaults (A-013), so `cost_usd: null` flows through as
  `--cost-usd 0` — no `metrics.sh` tolerance work required.
  `_cost_footer` at `bin/run-stage.sh:98-121` likewise uses
  `// 0` defaults via `jq @tsv` and behaves identically (the cost
  footer prose says `cost: $0.00`). Operator-visible behavior on
  partial files: the per-stage Linear comment shows `cost: $0.00`
  rather than zero-cost-with-partial-marker; the discriminator
  lives in `usage-<stage>.json`'s `partial` field on disk for the
  retrospective to read. **Mitigation:** Task 6 fixture asserts the
  observable contract — `_cost_flags_for` emits `--cost-usd 0` for
  a partial file (NOT `--cost-usd null`).

## File Structure

Modified files only — no new files, no deletes.

- `bin/dispatch.sh` — D-002 (per-stage timeout resolution + zero-guard)
  and D-003 (partial-usage fallback in `_render_and_capture_stream`).
- `AGENT_PROMPTS.md` — D-001 + D-005 (replace iteration-cap wording in
  §1 step 3; delete `brainstorm_escalate` bullet in §1 step 5).
- `bin/run-stage.sh` — D-004 (extend halt reason string in
  `dispatch_rc == 124` branch with worktree-inspection hint).
- `CLAUDE.md` — D-002 docs (new "Per-stage dispatch timeouts (ENG-65)"
  subsection after "Per-target dispatch.tools extras").
- `bin/dispatch-test.sh` — fixtures for the per-stage override path,
  fallthrough, built-in defaults, zero-minutes rejection, and the
  partial-usage extraction NDJSON fixture.

Files NOT touched (verified intentional per brainstorm §3):

- `bin/classify-failure.sh` — exit-124 classification path unchanged
  (D-004 only mutates the upstream halt-comment string).
- `bin/common.sh::failure_outcome_for_exit` — `124 → dispatch-timeout`
  mapping at `bin/common.sh:126` correct as-is.
- `bin/pipeline-events.json` — `iteration-exhausted` and
  `dispatch-timeout` already present at lines 14, 17.
- `bin/run-local-helpers.sh::partition_dirty_paths` — no allowlist
  change; this issue's plan doc lands under `docs/plans/` (already
  in `stage_output_paths` at line 56).
- `bin/render-prompt.sh::STAGE_TO_SECTION` — no new sections, no
  renumbering. Task 3 only edits prose inside §1's existing fenced block.
- `bin/metrics.sh` — see B-003; if a per-arg `null` tolerance is
  needed, that's a follow-up issue, not in scope here.

## API Contract

No new API surface. The harness has no FE↔BE split — bash
orchestration scripts only. Internal contract changes (the new
`partial: true` field on `usage-<stage>.json` and the new
`dispatch_timeout_minutes_per_stage` config key) are described in the
Backend Tasks below and validated by Task 6's fixtures.

## Backend Tasks

### Task 1: Add per-stage timeout resolution + zero-minutes guard to `dispatch.sh::main`

- `depends_on: []`
- `touches: bin/dispatch.sh::main` (lines 273-279)

Implements D-002. The resolver gains a per-stage override layer above
the existing global, plus per-stage built-in defaults, plus a hard
floor at 1 minute.

- [ ] In `bin/dispatch.sh:265-279`, replace the `local
  timeout_minutes=30` initialization + single-key resolver with a
  three-layer precedence chain. The `$stage` variable is already in
  scope (declared at line 237). Pseudocode for the new block:
  ```bash
  # Per-stage built-in default (D-002). Brainstorm/plan iterations
  # legitimately span >30 min on the persona-review path; other
  # stages stay at 30 to keep the runaway-agent window tight.
  local timeout_minutes
  case "$stage" in
    brainstorming|planning) timeout_minutes=60 ;;
    *)                      timeout_minutes=30 ;;
  esac
  if [[ -f "$CONFIG" ]]; then
    local _cfg_minutes
    # 1. Per-stage override wins.
    _cfg_minutes="$(jq -r --arg s "$stage" \
      '.orchestrator.dispatch_timeout_minutes_per_stage[$s] // empty' \
      "$CONFIG" 2>/dev/null || true)"
    # 2. Existing global.
    if [[ -z "$_cfg_minutes" ]]; then
      _cfg_minutes="$(jq -r '.orchestrator.dispatch_timeout_minutes // empty' "$CONFIG" 2>/dev/null || true)"
    fi
    [[ -n "$_cfg_minutes" && "$_cfg_minutes" =~ ^[0-9]+$ ]] && timeout_minutes="$_cfg_minutes"
  fi
  # Reject 0 (gtimeout sentinel for no-timeout) — restore built-in default.
  if (( timeout_minutes < 1 )); then
    case "$stage" in
      brainstorming|planning) timeout_minutes=60 ;;
      *)                      timeout_minutes=30 ;;
    esac
  fi
  local timeout_seconds=$(( timeout_minutes * 60 ))
  ```
- [ ] Update the comment block at `bin/dispatch.sh:265-272` to
  reference `dispatch_timeout_minutes_per_stage` and the per-stage
  built-in defaults; remove "per-stage overrides can be added later"
  language since they're now present.
- [ ] Verify with `bash -n bin/dispatch.sh` (syntax) before moving on.

### Task 2: Add partial-usage fallback to `_render_and_capture_stream`

- `depends_on: []`
- `touches: bin/dispatch.sh::_render_and_capture_stream` (lines 126-148)

Implements D-003. When `last_result` is empty (SIGTERM or any
pre-result termination), sum per-message
`assistant.message.usage.{input_tokens,output_tokens,cache_read_input_tokens,cache_creation_input_tokens}`
and write a partial-flagged usage file.

- [ ] In `bin/dispatch.sh:146-148` (the `else` branch of the
  `last_result`-empty test), insert a partial-extraction block BEFORE
  the existing soft-fail log line. The partial-extraction filter must
  parse line-delimited NDJSON (`fromjson? // empty` to drop malformed
  lines, matching the renderer's existing F2/D-002 tolerance), select
  the first `system`/`init` event for the model name, and sum
  `assistant.message.usage.*` across all assistant events. Use
  `jq -nR` (not `-s`) so the filter operates per-line via `inputs`,
  matching the renderer's main filter pattern at `bin/dispatch.sh:110`:
  ```bash
  else
    # ENG-65 D-003: SIGTERM (or any path leaving no result event) lost
    # cost telemetry pre-fix. Sum per-message assistant.message.usage
    # so the metrics stream isn't biased toward zero on watchdog kills.
    # cost_usd: null because total_cost_usd is only on the result event;
    # downstream `_cost_flags_for` coerces null → 0 via // 0 (acceptable).
    local _partial_json
    _partial_json="$(jq -nR '
      [inputs | (fromjson? // empty)] as $events
      | ($events | map(select(.type=="system" and .subtype=="init"))[0].model // "") as $model
      | ($events | map(select(.type=="assistant") | (.message.usage // {}))) as $usages
      | { tokens_in:    ($usages | map(.input_tokens // 0)             | add // 0),
          tokens_out:   ($usages | map(.output_tokens // 0)            | add // 0),
          cache_read:   ($usages | map(.cache_read_input_tokens // 0)  | add // 0),
          cache_create: ($usages | map(.cache_creation_input_tokens // 0) | add // 0),
          cost_usd:     null,
          model:        $model,
          partial:      true }
    ' < "$raw_capture" 2>/dev/null || printf '')"
    local _partial_sum=0
    if [[ -n "$_partial_json" ]]; then
      _partial_sum="$(printf '%s' "$_partial_json" | jq -r '(.tokens_in + .tokens_out)' 2>/dev/null || printf 0)"
    fi
    if [[ -n "$_partial_json" && "$_partial_sum" =~ ^[0-9]+$ && "$_partial_sum" -gt 0 ]]; then
      ( umask 077; printf '%s' "$_partial_json" > "$usage_file" )
      log "[cost] partial usage captured (no result event; SIGTERM-style termination): tokens_in+out=${_partial_sum}"
    else
      log "[cost] no result event found in stream (soft fail; usage-<stage>.json not written)"
    fi
  fi
  ```
  The `jq -nR` form (read raw lines, `inputs` yields each line) plus
  `[inputs | (fromjson? // empty)] as $events` slurps and decodes in
  one pass while silently dropping malformed lines. The `(.message.usage // {})`
  guard handles assistant events that lack a usage block (a degraded
  shape covered by the malformed-event test row in the Failure Map).
  The exact field naming inside `assistant.message.usage` may need a
  one-line tweak after observing real per-message NDJSON (see B-001);
  the slurp+sum+guard contract is what this plan owns.
- [ ] Preserve the function's existing `return 0` (implicit) on the
  partial path — the implementing-stage `assert_no_tool_invocation`
  block at lines 150-163 must still run after on the
  `stage == "implementing"` path; don't insert a `return` inside the
  `else` arm.
- [ ] Note the umask 077 inside the subshell wrapper so the file mode
  matches the existing `last_result`-non-empty branch
  (`bin/dispatch.sh:132`).
- [ ] Verify with `bash -n bin/dispatch.sh` (syntax) before moving on.

### Task 3: Brainstorm prompt — bound iterations to 2, voluntary halt

- `depends_on: []`
- `touches: AGENT_PROMPTS.md` (§1 step 3 at lines 288-291; §1 step 5
  bullet at lines 303-304)

Implements D-001 + D-005. Prompt edit only — no other stage section
changes, no fence count change.

- [ ] In `AGENT_PROMPTS.md`, locate §1 step 3 (`Iterate until the gate
  passes` ... `Iterate at most 3 times`) at lines 288-291 and replace
  it with a 2-iteration cap that mandates a voluntary
  `verdict halt --reason iteration-exhausted`:
  ```
  3. **Iterate until the gate passes**: at least 5/6 personas return
     PASS AND feasibility returns zero P0 findings. **After 2
     persona-review iterations, if not all PASS or feasibility still
     has any P0, run `bash bin/pipeline.sh event {issue_id} verdict
     halt --reason iteration-exhausted` and exit. Do NOT start
     iteration 3.** This bounds the worst-case dispatch at ~36–60 min
     and lets the operator inspect the partial doc + persona findings
     in the worktree before deciding `--action continue` (resume) or
     fixing the underlying P0.
  ```
- [ ] In §1 step 5, delete the now-dead `Escalate tag` bullet at
  lines 303-304:
  ```
  - Escalate tag: `<!-- meta: metric name=brainstorm_escalate -->` if any P0 remained
    after iteration 3.
  ```
  Removed — under the new contract any unresolved-P0 path posts the
  `iteration-exhausted` halt verdict (step 3) which the retrospective
  reads from `events.jsonl` directly.
- [ ] Do NOT touch §2 (Plan), §5 (Review), or any other stage
  section. Do NOT change the §1 fenced block boundaries (verify that
  `grep -c '^```$' AGENT_PROMPTS.md` is unchanged before and after the
  edit).
- [ ] Verify with `bash bin/render-prompt-test.sh` — the renderer
  contract that requires exactly two fences per stage block must hold.

### Task 4: Halt-comment hint on `dispatch_rc == 124` (worktree resume)

- `depends_on: []`
- `touches: bin/run-stage.sh` (lines 567-576)

Implements D-004. Reason-string change only; policy and exit code
unchanged.

- [ ] In `bin/run-stage.sh:567-576`, extend the third positional
  argument to `classify_failure` so the halt-comment body surfaces the
  worktree-resume hint:
  ```bash
  if (( dispatch_rc == 124 )); then
    classify_failure "$ident" "$stage" "skip-until-human-acts" \
      "dispatch wall-clock timeout — agent exceeded budget without exiting. Partial worktree artifacts may resume cleanly. Inspect: $(issue_dir "$ident")/worktree/. If the artifact looks complete, run: bash bin/pipeline.sh decide $ident --action continue" 124
    rm -f "$prompt_file"
    exit 124
  fi
  ```
  Use `$(issue_dir "$ident")` (already sourced via common.sh) so the
  hint resolves to the live `$PROJECT_STATE_DIR/<ident>/worktree/`
  path rather than a templated literal.
- [ ] Verify with `bash bin/run-stage-test.sh` — the existing fixture
  set should pass; the reason-string assertion (if any) is a substring
  match per existing convention (`grep -q 'wall-clock timeout'`).

### Task 5: CLAUDE.md — document `dispatch_timeout_minutes_per_stage`

- `depends_on: [1]`
- `touches: CLAUDE.md` (insertion after line 262 — the
  "Per-target dispatch.tools extras" subsection ends at the closing
  ```` ``` ```` of its example, currently around line 259)

Implements D-002 docs. Mirrors the existing per-target subsection's
prose-then-fenced-json shape.

- [ ] Insert a new H2 subsection immediately after "Per-target
  dispatch.tools extras (ENG-51, ENG-53 #8)" with the heading:
  ```
  ## Per-stage dispatch timeouts (ENG-65)
  ```
  Body covers (a) the wall-clock watchdog motivation (ENG-48), (b)
  the new `dispatch_timeout_minutes_per_stage` config schema, (c) the
  three-layer precedence (per-stage override → global → built-in
  default), (d) the per-stage built-in defaults table (60 for
  `brainstorming` and `planning`; 30 for everything else), and (e)
  the trade-off ("longer cap = more wasted spend on stalled agents;
  tighter cap = legitimate persona-review may SIGTERM mid-iteration").
- [ ] Include a fenced JSON example matching the per-target
  `.pipeline-config/config.json` apply pattern:
  ```json
  {
    "orchestrator": {
      "dispatch_timeout_minutes": 30,
      "dispatch_timeout_minutes_per_stage": {
        "brainstorming": 60,
        "planning":      60
      }
    }
  }
  ```
- [ ] Note the `0` rejection rule (Task 1 guard) and the integer-only
  validation regex (no `"60m"` / `"1h"` strings) in the prose.
- [ ] List the canonical stage keys explicitly so operators don't get
  silent fallthrough on typo'd keys: `brainstorming`, `planning`,
  `implementing`, `ui`, `reviewing`, `qa`, `building`, `released`
  (gerund form per `bin/dispatch.sh:214-225`). Note that an unknown
  key (e.g. `brainstorm` missing `-ing`) silently falls through to
  the global, then to the built-in default, with no warning — operators
  should grep `gtimeout ... <seconds>` in the per-stage transcript to
  confirm their override took effect. Cross-link the partial-usage
  field shape (`partial: true`, `cost_usd: null`) introduced by D-003
  so an operator inspecting `usage-<stage>.json` understands the
  discriminator.
- [ ] Add a one-liner to CLAUDE.md "Failure-mode quick reference" table
  noting the brainstorm 2-iteration cap behavior change: a brainstorm
  that historically resolved on iteration 3 now halts at iteration 2
  with `iteration-exhausted`; operator inspects the worktree and
  decides `--action continue` (resume) or fixes the underlying P0.
  The trade is bounded worst-case spend vs. one extra operator
  touch on slow-converging brainstorms.

### Task 6: Test fixtures in `bin/dispatch-test.sh`

- `depends_on: [1, 2]`
- `touches: bin/dispatch-test.sh::Group 5 (lines 262-322), one new
  Group-3 fixture after the existing F+G adversarial fixtures`

Implements coverage for D-002 and D-003. Reuses the existing
dry-run-grep pattern for cap fixtures and the NDJSON-heredoc pattern
for the renderer fixture.

- [ ] Add a per-stage override fixture to Group 5: build a
  `TARGET_REPO_PERSTAGE` config with
  `orchestrator.dispatch_timeout_minutes_per_stage.brainstorming = 45`
  and assert the dry-run log emits
  `gtimeout ... 2700` for `bash dispatch.sh brainstorming` and
  `gtimeout ... 1800` for `bash dispatch.sh ui` (override does NOT
  affect other stages).
- [ ] Add a fallthrough fixture: `dispatch_timeout_minutes_per_stage`
  is absent but `dispatch_timeout_minutes: 5` is set; assert
  brainstorm dry-run log emits `gtimeout ... 300`.
- [ ] Add a built-in-default-by-stage fixture: no overrides at all;
  assert brainstorm/planning dry-run logs emit `gtimeout ... 3600`
  and ui/implementing/qa dry-run logs emit `gtimeout ... 1800`.
- [ ] Add a zero-rejection fixture:
  `dispatch_timeout_minutes_per_stage.brainstorming = 0`; assert
  brainstorm dry-run log emits `gtimeout ... 3600` (built-in default
  restored, NOT `gtimeout ... 0`).
- [ ] Add a typo'd-key fixture:
  `dispatch_timeout_minutes_per_stage.brainstorm = 45` (missing
  "-ing"); assert brainstorm dry-run log emits the built-in-default
  `gtimeout ... 3600`, demonstrating that mis-keyed overrides fall
  through silently rather than dying.
- [ ] Add a partial-usage fixture (**Fixture L**, appended after the
  existing Fixture K at `bin/dispatch-test.sh:644`): feed
  `_render_and_capture_stream` an NDJSON heredoc with one
  `system`/`init` event (model = `claude-opus-4-7`) and three
  `assistant` events each carrying
  `message.usage.{input_tokens, output_tokens, cache_read_input_tokens,
  cache_creation_input_tokens}` with non-zero values, and NO `result`
  line. Assert: `usage-<stage>.json` exists, `partial` field is
  `true` (JSON boolean), `cost_usd` is `null` (JSON null —
  verify with `jq -r '.cost_usd == null'` returning `true`),
  `tokens_in` equals the sum across the three events, `model`
  equals `claude-opus-4-7`. The per-event NDJSON shape is:
  ```json
  {"type":"assistant","message":{"id":"msg_01","content":[{"type":"text","text":"work"}],
   "usage":{"input_tokens":100,"output_tokens":50,
            "cache_read_input_tokens":20,"cache_creation_input_tokens":10}}}
  ```
  This shape may need adjustment after the B-001 live-transcript
  validation; the assertions are the load-bearing contract.
- [ ] Add a malformed-`usage`-block extension to Fixture L: include
  one `assistant` event WITHOUT `message.usage` alongside two valid
  ones. Assert the sum equals only the valid events' total
  (`(.message.usage // {})` guard absorbs the missing-usage event as 0).
- [ ] Add a `_cost_flags_for` partial-file fixture to
  `bin/run-stage-test.sh`: write a partial usage file (`cost_usd: null,
  partial: true`, non-zero tokens), invoke `_cost_flags_for "$ident"
  "<stage>"`, assert the emitted flag stream contains `--cost-usd 0`
  (NOT `null`) due to jq's `// 0` coercion at `bin/run-stage.sh:82`.
  This pins B-003's downstream contract.
- [ ] **Note:** the existing Fixture H at `bin/dispatch-test.sh:562-572`
  already covers the empty-stdin / no-`assistant`-events path — it
  passes pre-D-003 because no result event is found, and it continues
  to pass post-D-003 because the new fallback's
  `_partial_sum > 0` guard rejects the zero-token sum. Do NOT add a
  duplicate fixture for that case; verify the original still passes
  after Task 2 lands as part of the regression check.
- [ ] Verify with `bash bin/dispatch-test.sh && bash bin/run-stage-test.sh`
  — all new fixtures pass, no existing fixture regresses (especially
  Fixture H must remain green).

## Frontend Tasks

No frontend tasks. The harness has no UI; this work is bash-only.

## Failure Mode → Test Map

Pulled from brainstorm §5 (Error handling) and §6 (Edge cases). Each
row binds to a concrete fixture (or explicitly states why a behavior
is uncovered by harness tests).

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
|---|---|---|---|---|
| Empty NDJSON capture (gtimeout fires before any agent output) | empty stdin → no events at all | NO `usage-<stage>.json` written; existing soft-fail log line emitted; new partial path's `_partial_sum > 0` guard rejects | unit | existing `bin/dispatch-test.sh:562-572` Fixture H (regression-pin only — must stay green after Task 2) |
| SIGTERM mid-stream — partial agent output captured | feed 3× `assistant` events with `message.usage.*`, no `result` | `usage-<stage>.json` written with summed tokens, `partial: true`, `cost_usd: null`, model from init event | unit | `bin/dispatch-test.sh` Fixture L-partial (Task 6) |
| Malformed `usage` block on an `assistant` event | inject one `assistant` event missing `.message.usage`; others valid | malformed event contributes 0 (jq `// 0` default); valid events still summed | unit | extension of Fixture L — assert sum equals only the valid events' total |
| Per-stage timeout config malformed (non-numeric) | `dispatch_timeout_minutes_per_stage.brainstorming = "60m"` (string) | regex guard rejects; falls through to existing global, then to built-in default | unit | extension of Task 6's typo'd-key fixture |
| Per-stage timeout config = 0 (gtimeout no-timeout sentinel) | `dispatch_timeout_minutes_per_stage.brainstorming = 0` | `(( minutes >= 1 ))` guard rejects; built-in default 60 restored; gtimeout wraps with `3600` | unit | Task 6 zero-rejection fixture |
| Per-stage timeout config typo (unknown stage key) | `dispatch_timeout_minutes_per_stage.brainstorm = 45` (missing -ing) | lookup misses; falls through to built-in default per stage; no abort | unit | Task 6 typo'd-key fixture |
| Per-stage override present, used | `dispatch_timeout_minutes_per_stage.brainstorming = 45` | brainstorm dispatch wraps with `2700`; non-brainstorm stages unaffected | unit | Task 6 per-stage override fixture |
| Global override present (no per-stage), used | `dispatch_timeout_minutes = 5`, no per-stage | brainstorm wraps with `300` (existing fallthrough preserved) | unit | Task 6 fallthrough fixture |
| No config at all | no `.pipeline-config/config.json` overrides | brainstorm/plan use 60-min default (3600s); other stages use 30-min default (1800s) | unit | Task 6 built-in-default-by-stage fixture |
| Stream contains both `result` AND `assistant` events with usage | NDJSON with `assistant`+usage events followed by valid `result` | clean-capture path runs; partial fallback never fires; no double-counting | unit | existing Fixture A at `bin/dispatch-test.sh:350` already covers (assistant events present, result event present, six-field clean output) |
| `dispatch_rc == 124` halt comment includes worktree-resume hint | run-stage.sh receives 124 | classify_failure called with reason string containing "Inspect: ...worktree/" and "--action continue" | unit | extension of `bin/run-stage-test.sh` — substring assertion on the classify_failure call's third arg |
| Brainstorm agent posts iteration-exhausted halt | agent behavior under new prompt — out of harness-test scope | registry validates `iteration-exhausted` token; halt comment emitted via `bin/pipeline.sh event` | smoke | manual validation on the next live brainstorm dispatch (or harness-self brainstorm of any open ENG-* issue) — covered in QA stage's smoke test against a one-shot dispatch |
| Two halt comments race (agent posts iteration-exhausted, then SIGTERM fires before exit) | gtimeout fires after the agent's halt-marker post but before exit | both halt markers visible in Linear; verdict-handler picks the freshest (per `find_fresh_verdict`); operator `--action continue` clears | manual | not test-covered — verified by reading `verdict-handler.sh::find_fresh_verdict` (existing freshness contract) |
| `_cost_flags_for` consumes a partial usage file | partial `usage-<stage>.json` with `cost_usd: null` | emits `--cost-usd 0` (jq `// 0` coerces null → 0); other flags carry summed token values; `partial: true` field is NOT in the flag stream | unit | extension to `bin/run-stage-test.sh` covering `_cost_flags_for` against a partial fixture file |

## Test Strategy

**Unit (the load-bearing layer for this plan):**

1. `bin/dispatch-test.sh` Group 5 extensions — five new
   wall-clock-cap fixtures (per-stage override, fallthrough,
   built-in default, zero-rejection, typo'd key) using the existing
   dry-run-log-grep pattern at lines 296-322.
2. `bin/dispatch-test.sh` new Fixture L (partial-usage success) plus
   a malformed-`usage`-block extension to Fixture L — direct
   `_render_and_capture_stream` coverage using NDJSON heredocs on
   stdin (matches Fixtures A–K pattern at lines 350-643). Existing
   Fixture H at lines 562-572 doubles as the empty-stdin
   regression pin; no new zero-tokens fixture needed.
3. `bin/run-stage-test.sh` extension — substring assertion on the
   `dispatch_rc == 124` branch's `classify_failure` reason argument
   covering D-004's worktree-resume hint. Add a new
   `_cost_flags_for` partial-file fixture covering B-003.

**Integration:** none required. The
`PIPELINE_DRY_RUN=1 TARGET_REPO=... bash bin/run-stage.sh ENG-X
brainstorming` path covers Task 1 + Task 5 end-to-end on a real
target; no new orchestration plumbing.

**Smoke:** the next live brainstorm dispatch (any open ENG-* issue
hitting iteration 2 with unresolved P0) exercises Task 3 in
production. The QA stage's smoke checklist should include a one-shot
dispatch to confirm the new `iteration-exhausted` voluntary halt
emits cleanly via `bin/pipeline.sh event`.

**Adversarial / negative-path coverage:**

- The zero-minutes guard fixture is the primary adversarial case for
  Task 1 (operator typo'd config could otherwise disable the
  watchdog).
- The malformed `usage` block extension to Fixture L is the
  adversarial case for Task 2 (degraded API response shouldn't crash
  the partial-extraction filter).
- The typo'd-key fixture is the adversarial case for Task 1's
  fallthrough chain (operator misspells the stage gerund).

**Out of scope (deliberately not tested by this plan):**

- B-001 (per-message `assistant.message.usage` field naming) — the
  jq filter is exercised by Fixture L using documented field names;
  if the live shape differs, Task 2's small jq tweak is contained
  inside the partial-extraction block. Capturing one real
  stream-json transcript before merging is recommended (see Task 2
  step 1 mitigation), but is not codified as a test.
- The two-halt-comments race in §5 of the brainstorm — verified by
  reading `verdict-handler.sh::find_fresh_verdict`'s freshness
  contract; not test-covered because it requires multi-process
  timing.
- `bin/metrics.sh stage-end --cost-usd null` end-to-end behavior —
  see B-003. The new contract is that `_cost_flags_for` emits
  `--cost-usd 0` (jq `// 0` coercion), so metrics.sh sees a clean
  `0` and behaves as if the dispatch had genuinely zero cost; the
  `partial: true` discriminator on disk is what the retrospective
  reads to separate "captured under SIGTERM" from "clean zero-cost."

## Persona review

Personas were applied design → scope → coherence → product →
feasibility (gating). Iteration 1: feasibility FAIL (1 P0) and
product FAIL (2 P1) — others PASS. Iteration 2: product re-review
PASS; feasibility re-review found a residual P0 (a `replace_all`
operation accidentally renamed correct "existing Fixture H"
references to "Fixture L"). Iteration 3: feasibility re-check
PASS after explicit per-occurrence fix.

### Iteration 1

| Persona | Verdict | P0 | P1 | P2 |
|---|---|---|---|---|
| design | PASS | 0 | 0 | 3 |
| scope | PASS | 0 | 0 | 3 |
| coherence | PASS | 0 | 0 | 1 |
| product | FAIL | 0 | 2 | 3 |
| feasibility (gating) | FAIL | 1 | 2 | 1 |

Findings addressed:
- **feasibility P0** — Fixture H name collision: existing
  `bin/dispatch-test.sh` has fixtures A through K; new
  partial-usage fixture renamed to L; existing Fixture H at lines
  562-572 noted as the empty-stdin regression-pin (continues to
  PASS under D-003 because the new fallback's `_partial_sum > 0`
  guard rejects zero-token inputs).
- **feasibility P1** — Task 2 jq filter pseudocode (`-s` + `inputs`
  mismatch): rewritten as `jq -nR '[inputs | (fromjson? // empty)]
  as $events | ...'`.
- **feasibility P1** — A-013 `null`→"null" coercion claim wrong:
  corrected — `_cost_flags_for` uses `(.cost_usd // 0 | tostring)`
  at `bin/run-stage.sh:82`, so `cost_usd: null` flows through as
  `--cost-usd 0`. Task 6 fixture assertion updated accordingly.
- **product P1** — typo'd-stage-name silent fallthrough: Task 5
  now lists canonical gerund-form keys explicitly and documents
  the silent fallthrough + `grep gtimeout ...` operator workaround.
- **product P1** — iter-3 → iter-2 worst-case behavior change:
  Task 5 now adds a one-liner to CLAUDE.md "Failure-mode quick
  reference" calling out the trade.

### Iteration 2

| Persona | Verdict | P0 | P1 | P2 |
|---|---|---|---|---|
| feasibility (re-check) | FAIL | 1 | 0 | 0 |
| product (re-check) | PASS | 0 | 0 | 0 |

- **feasibility P0** — `replace_all "Fixture H" → "Fixture L"`
  accidentally turned correct "existing Fixture H" references into
  "Fixture L" in three places (A-012, Task 6 step 7, Test
  Strategy). Fixed by per-occurrence Edit; new fixture remains
  Fixture L; references to existing fixture restored to H.

### Iteration 3

| Persona | Verdict | P0 | P1 | P2 |
|---|---|---|---|---|
| feasibility (final) | PASS | 0 | 0 | 0 |

### Final verdict

`status = clean` — 5/5 personas PASS, gate P0 = 0, proceeding to
implementing.
