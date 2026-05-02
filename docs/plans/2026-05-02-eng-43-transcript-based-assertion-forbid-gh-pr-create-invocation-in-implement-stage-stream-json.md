---
linear: ENG-43
date: 2026-05-02
topic: Transcript-based assertion — forbid `gh pr create` in implement-stage stream-json
status: draft
---

# Plan — ENG-43 transcript-based assertion forbidding `gh pr create` in implement-stage stream-json

Implementation plan for the design in
`docs/brainstorms/2026-05-02-eng-43-transcript-based-assertion-forbid-gh-pr-create-invocation-in-implement-stage-stream-json-design.md`.

## Goal

Add an `assert_no_tool_invocation <transcript> <pattern>` helper in
`bin/dispatch.sh`, call it from `_render_and_capture_stream` gated on
`stage == "implement"` with pattern `gh pr create`, and route the
match-failure return (rc=22) through `bin/run-stage.sh` so the operator
sees the same `skip-until-human-acts` / `pr-opened-too-early` halt the
deleted state-check guard produced — verified by six new transcript
fixtures (AS1–AS6) in `bin/dispatch-test.sh` and unchanged passing of
all other test files.

## Anti-anchoring check

- **Problem restated.** The implement stage's tool-lane already denies
  `Bash(gh:*)` (`bin/dispatch.sh:175`), so the lane *is* the contract;
  but ENG-42 deleted the (false-positive) state-check guard, leaving no
  second line of defense if the lane is ever misconfigured.
- **Brainstorm's solution.** Adds a transcript scan that answers the
  contract question directly ("did this dispatch invoke `gh pr create`?")
  rather than via PR-existence proxy. Proportional: ~15 lines of bash, one
  jq fork (matches ENG-26 D-002 budget), six unit fixtures, one rc-routing
  branch in run-stage.sh, one CLAUDE.md bullet. No new crate, no new
  marker, no new label, no new exit-code mapping.
- **Verdict.** Both checks pass. Proceed.

## Assumption inventory

Every code-level claim is verified against the current branch
(`feat/eng-43-transcript-based-assertion-…`, post-ENG-26 merge). Each
row cites a `path:line` source-of-truth.

- **A-001 — `_render_and_capture_stream` exists, owns
  `.raw-stream.ndjson.tmp`, and removes it via RETURN trap.**
  - `bin/dispatch.sh:69` — `_render_and_capture_stream() {`
  - `bin/dispatch.sh:70` — `local usage_file="$1" issue_dir="$2"`
  - `bin/dispatch.sh:71` — `local raw_capture="${issue_dir}/.raw-stream.ndjson.tmp"`
  - `bin/dispatch.sh:72` — `trap 'rm -f "$raw_capture"' RETURN`
  - Status: **verified.** Helper will receive a third arg `stage` (D-006
    in the brainstorm); existing two-arg call sites are at
    `bin/dispatch.sh:288` and `bin/dispatch.sh:297`.

- **A-002 — Implement stage's allowed-tools list excludes
  `Bash(gh:*)` and `Agent`.**
  - `bin/dispatch.sh:175` —
    `implement)      base='Read,Write,Edit,Grep,Glob,TaskCreate,Bash(git:*),Bash(cargo:*),Bash(bun:*),Bash(rustc:*),Bash(jq:*),Bash(awk:*),Bash(bash .pipeline/bin/linear.sh:*),Bash(bash bin/linear.sh:*)' ;;`
  - Status: **verified.** The lane is the primary defense; the assertion
    is a tripwire if the lane is ever misconfigured.

- **A-003 — Renderer is invoked from `main()` inside two pipelines, both
  passing `(usage_file, issue_state_dir)`.**
  - `bin/dispatch.sh:286-289` — log_file branch:
    ```bash
    "${cmd[@]}" < "$prompt_file" \
      | _render_and_capture_stream "$usage_file" "$issue_state_dir" \
      > "$log_file"
    ```
  - `bin/dispatch.sh:295-297` — no-log_file branch:
    ```bash
    "${cmd[@]}" < "$prompt_file" \
      | _render_and_capture_stream "$usage_file" "$issue_state_dir"
    ```
  - Status: **verified.** Both call sites need a third arg `"$stage"`
    threaded through. `$stage` is local to `main()` at
    `bin/dispatch.sh:194`.

- **A-004 — `dispatch.sh::main` is under `set -euo pipefail`, and the
  pipeline propagates a non-zero rc from the renderer (right side of pipe)
  to `main()`.**
  - `bin/dispatch.sh:15` — `set -euo pipefail`
  - Status: **verified.** Returning 22 from `_render_and_capture_stream`
    makes the pipeline exit 22, which under `set -e` exits `main()` with
    22 as well.

- **A-005 — `run-stage.sh` already maps `dispatch_rc` to
  `skip-until-human-acts` (rc 124) and `retry-immediately` (any other
  non-zero) via `classify_failure`.**
  - `bin/run-stage.sh:554-557` — `dispatch_rc=0; … bash dispatch.sh … || dispatch_rc=$?`
  - `bin/run-stage.sh:559-568` — rc 124 branch:
    ```bash
    if (( dispatch_rc == 124 )); then
      classify_failure "$ident" "$stage" "skip-until-human-acts" \
        "dispatch wall-clock timeout — agent exceeded budget without exiting" 124
      rm -f "$prompt_file"
      exit 124
    elif (( dispatch_rc != 0 )); then
      classify_failure "$ident" "$stage" "retry-immediately" \
        "dispatch failed (see $log_file)" 20
      rm -f "$prompt_file"
      exit 20
    fi
    ```
  - Status: **verified.** New branch `elif (( dispatch_rc == 22 ))` slots
    BETWEEN the 124 case and the catch-all `dispatch_rc != 0` case (so
    the specific 22 is matched before the generic non-zero).

- **A-006 — `failure_outcome_for_exit 22` returns `pr-opened-too-early`.**
  - `bin/common.sh:115` — `22) printf 'pr-opened-too-early' ;;`
  - Status: **verified.** Operator-facing surface preserved; no taxonomy
    change.

- **A-007 — `issue_dir()` helper resolves
  `$PROJECT_STATE_DIR/<ident>` and is exported by common.sh.**
  - `bin/common.sh:153` — `export -f issue_dir compute_pipeline_content_hash failure_outcome_for_exit …`
  - `bin/run-stage.sh:592` — `local approval_state_file="$(issue_dir "$ident")/scope-approval"`
  - Status: **verified.** Sidecar lands at
    `$PROJECT_STATE_DIR/<ident>/.transcript-violation-<stage>` —
    per-issue, per-stage, hidden (leading-dot, partition_dirty_paths
    invisible per existing `.raw-stream.ndjson.tmp` precedent).

- **A-008 — `bin/dispatch-test.sh` already defines fixtures A–K for the
  renderer and sources dispatch.sh under `set -euo pipefail` with
  PIPELINE_DRY_RUN seeded; the renderer fixtures explicitly flip
  `PIPELINE_DRY_RUN=0` to exercise the code path.**
  - `bin/dispatch-test.sh:336` — `printf '\n--- _render_and_capture_stream renderer fixtures (A-E) ---\n'`
  - `bin/dispatch-test.sh:347-348` — `PIPELINE_DRY_RUN=0; export PIPELINE_DRY_RUN`
  - `bin/dispatch-test.sh:574-643` — fixtures F-K
  - Status: **verified.** New fixtures AS1–AS6 (D-009 in brainstorm —
    renamed from issue's E-J to avoid letter collision with existing
    fixtures A-K) appended after fixture K, before the Gap-7 contract
    block at `bin/dispatch-test.sh:645`. Fixtures source the helper
    directly (no claude invocation; they only need
    `assert_no_tool_invocation` to be defined).

- **A-009 — `bin/dispatch-test.sh` uses the source-and-stub pattern from
  CLAUDE.md "How tests work" — sourcing dispatch.sh after env setup and
  using `_TEST_STUB_DIR`/`ISSUE_DIR` mktemps.**
  - `bin/dispatch-test.sh:21-22` — `_TEST_TARGET_DIR`, `_TEST_STUB_DIR`
  - `bin/dispatch-test.sh:65-66` — `ISSUE_DIR="${PROJECT_STATE_DIR}/ENG-T-COST"`
  - `bin/dispatch-test.sh:70` — `source "$SCRIPT_DIR/dispatch.sh"`
  - Status: **verified.** AS1–AS6 fixtures will write transcript files
    under `$_TEST_STUB_DIR/`, call `assert_no_tool_invocation` directly,
    and assert `(rc, stdout)` tuples — no real claude, no real renderer.

- **A-010 — `bin/run-stage-test.sh` cases 11 and 12 cover the
  scope-check `rc=3` (SEVERE) and `rc=*` (unknown) paths and bump
  `implement_rejection`; they do not cover `dispatch_rc == 22`.**
  - Cited in ENG-42's plan §"Assumption inventory" A-006 and §"Failure
    mode → test map" — re-validated for ENG-43: cases 11 and 12 sit at
    `bin/run-stage-test.sh:~338+` (post-ENG-42 case-13 deletion).
  - Status: **verified by inheritance.** Cases 11, 12 exercise the
    post-dispatch scope-check ladder (rcs 3 and `*`), independent of the
    new rc=22 branch. They continue to pass without modification.

- **A-011 — CLAUDE.md "When wiring a new script" section is at
  lines 242-259 and uses bullet-list format.**
  - `CLAUDE.md:242` — `## When wiring a new script`
  - `CLAUDE.md:244-259` — six existing bullets
  - Status: **verified.** A new bullet (defense-in-depth pattern) is
    appended after the existing bullet at lines 256-259.

- **A-012 — jq's `startswith($p)` is literal-string matching (not
  regex); `// ""` defaults a missing field to empty string; `fromjson?`
  silently drops malformed lines.**
  - jq manual; pattern already used in
    `bin/dispatch.sh:86` (`fromjson? // empty`) for the renderer's
    own malformed-line tolerance.
  - Status: **verified.** Pattern containing regex metacharacters
    (e.g. `gh pr create.*`) would be matched as literal characters, not
    regex — safe by design; covered by §4 brainstorm note.

- **A-013 — The slightly stale `(b) no-pr-check` comment at
  `bin/run-stage.sh:586` ("UI stage opens the PR") is OUT OF SCOPE for
  ENG-43; cleanup deferred to a separate ENG-52-style residue PR.**
  - `bin/run-stage.sh:584-586` — comment block:
    ```
    # Post-implement / post-ui guards:
    #   (a) scope-check: no files outside plan File Structure were touched.
    #   (b) no-pr-check: implement stage must NOT have opened a PR (UI stage opens the PR).
    ```
  - Status: **verified, intentionally not touched** (brainstorm §8.2).
    Bundling it would widen the change set unnecessarily.

## File Structure

```
bin/
  dispatch.sh                modified  — add assert_no_tool_invocation helper;
                                          extend _render_and_capture_stream signature
                                          to accept stage; gated assertion call;
                                          thread stage through both call sites in main()
  run-stage.sh               modified  — insert `elif (( dispatch_rc == 22 ))` branch
                                          between the 124 and the catch-all non-zero cases;
                                          read sidecar, classify, rm sidecar, exit 22
  dispatch-test.sh           modified  — append AS1-AS6 transcript fixtures after fixture K,
                                          before the Gap-7 contract block (line ~645)

CLAUDE.md                    modified  — add a single bullet to "When wiring a new script"
                                          documenting the transcript-assertion pattern as
                                          defense-in-depth on top of tool-lane denials

docs/
  brainstorms/2026-05-02-eng-43-transcript-based-assertion-forbid-gh-pr-create-invocation-in-implement-stage-stream-json-design.md   PRE-EXISTING (this issue's brainstorm)
  plans/2026-05-02-eng-43-transcript-based-assertion-forbid-gh-pr-create-invocation-in-implement-stage-stream-json.md                NEW (this file)
```

No changes to `bin/common.sh` (exit-code mapping `22 →
pr-opened-too-early` is already there). No changes to `bin/run-stage-test.sh`
(brainstorm §9.2: stubbing dispatch.sh to return 22 is doable but adds
material complexity for marginal coverage; helper-fixture coverage plus
the small mechanical addition to run-stage.sh is sufficient). No changes
to `bin/classify-failure.sh` or `bin/metrics.sh` (existing taxonomies
suffice). No changes to `bin/dry-run.sh` (dispatch dry-run path
short-circuits before the renderer; assertion is not exercised).

## API Contract

No new API surface. `dispatch.sh` continues to take
`<stage> <prompt_file> [<log_file>]`, and `run-stage.sh` continues to take
`<ident> <stage>`. The only "contract" that changes is internal:
`_render_and_capture_stream` accepts a third positional arg
(`stage`) used to gate the assertion and to suffix the sidecar filename.
The sidecar file name `${issue_dir}/.transcript-violation-${stage}` is
private to dispatch↔run-stage; no other reader exists.

## Backend Tasks

(Bash harness — no Tauri/Rust backend, no frontend.)

### Task 1: add `assert_no_tool_invocation` helper to `bin/dispatch.sh`

- `depends_on: []`
- `touches: bin/dispatch.sh::assert_no_tool_invocation` (new function)

- [ ] Add the helper definition immediately ABOVE
  `_render_and_capture_stream` in `bin/dispatch.sh` (so the renderer can
  call it without forward-declaration). Decoupled signature per
  brainstorm D-010: takes only `transcript_path` + `pattern`; consumes no
  ambient harness state (`$PIPELINE_ISSUE_ID`, `$issue_dir`, etc.).

  ```bash
  # ENG-43: transcript-based assertion. Single jq fork; reads NDJSON
  # from $transcript line by line, finds tool_use blocks invoking Bash
  # whose .input.command starts with $pattern, and prints the FIRST
  # match on stdout (returning 1). Soft-fail (return 0) on empty/missing
  # transcript so dry-run / planning-only paths never synthesize false
  # positives. Pure: no harness ambient context.
  assert_no_tool_invocation() {
    local transcript="$1" pattern="$2"
    [[ -s "$transcript" ]] || return 0
    local matched
    matched="$(jq -Rr --arg p "$pattern" '
      fromjson? // empty
      | select(.type == "assistant")
      | .message.content[]?
      | select(.type == "tool_use" and .name == "Bash")
      | (.input.command // "")
      | select(startswith($p))
    ' "$transcript" 2>/dev/null | head -1)" || true
    if [[ -n "$matched" ]]; then
      printf '%s\n' "$matched"
      return 1
    fi
    return 0
  }
  ```

  Notes for the implementation agent:
  - `-Rr` reads the file line-by-line as raw strings (matches the
    NDJSON shape `tee` writes into `$raw_capture` per `bin/dispatch.sh:82`).
  - `fromjson? // empty` tolerates malformed lines (Fixture AS5).
  - `head -1` caps output to first match; SIGPIPE on jq is harmless
    inside command substitution.
  - The `2>/dev/null || true` swallows jq stderr and rc, so a corrupted
    jq runtime degrades to "no match" rather than tripping the script's
    `set -e`. The renderer already requires jq one line later, so a
    real jq-absent host fails earlier, not here.

### Task 2: extend `_render_and_capture_stream` to accept `stage` and run the assertion

- `depends_on: [1]`
- `touches: bin/dispatch.sh::_render_and_capture_stream`

- [ ] Change the signature at `bin/dispatch.sh:69`:

  ```bash
  _render_and_capture_stream() {
    local usage_file="$1" issue_dir="$2" stage="${3:-}"
    local raw_capture="${issue_dir}/.raw-stream.ndjson.tmp"
    local violation_file="${issue_dir}/.transcript-violation-${stage}"
    rm -f "$violation_file"            # idempotent pre-clean (D-008)
    trap 'rm -f "$raw_capture"' RETURN
    mkdir -p "$issue_dir"
    …
  ```

  The pre-existing `trap 'rm -f "$raw_capture"' RETURN` at
  `bin/dispatch.sh:72` stays as-is. The assertion's sidecar is
  intentionally NOT swept by this trap — its lifecycle belongs to the
  consumer (`run-stage.sh`'s rc=22 branch), per brainstorm Q2.

- [ ] After the existing result-event extraction (`bin/dispatch.sh:99-121`)
  and BEFORE the function returns, insert the gated assertion call:

  ```bash
  # ENG-43: defense-in-depth assertion. Tool lane should already deny
  # Bash(gh:*) for implement (bin/dispatch.sh:175); this is the
  # second line of defense if the lane is ever misconfigured.
  if [[ "$stage" == "implement" ]]; then
    local _matched_cmd
    if _matched_cmd="$(assert_no_tool_invocation "$raw_capture" "gh pr create")"; then
      :   # rc 0: no match, fall through
    else
      printf '%s\n' "$_matched_cmd" > "$violation_file"
      log "[assert] implement-stage transcript invoked forbidden tool: ${_matched_cmd}"
      return 22
    fi
  fi
  ```

  Notes:
  - `assert_no_tool_invocation` returns 0 on no match (pass-through),
    1 on match (writes sidecar, returns 22 from the renderer).
  - Under the script's `set -o pipefail`, returning 22 from the right
    side of the pipe at `bin/dispatch.sh:288` or `bin/dispatch.sh:297`
    propagates 22 to `main()`, which exits 22 under `set -e`.
  - The RETURN trap fires AFTER the `return 22` and removes
    `.raw-stream.ndjson.tmp` (consistent with brainstorm D-006: existing
    trap stays unchanged; assertion slots in before it).
  - Sidecar `.transcript-violation-${stage}` survives the RETURN trap so
    `run-stage.sh` can read it next.

### Task 3: thread `$stage` through both renderer call sites in `dispatch.sh::main`

- `depends_on: [2]`
- `touches: bin/dispatch.sh::main`

- [ ] At `bin/dispatch.sh:288`, change:

  ```bash
  | _render_and_capture_stream "$usage_file" "$issue_state_dir" \
  ```

  to:

  ```bash
  | _render_and_capture_stream "$usage_file" "$issue_state_dir" "$stage" \
  ```

- [ ] At `bin/dispatch.sh:297`, change:

  ```bash
  | _render_and_capture_stream "$usage_file" "$issue_state_dir"
  ```

  to:

  ```bash
  | _render_and_capture_stream "$usage_file" "$issue_state_dir" "$stage"
  ```

  Both edits are mechanical. `$stage` is already in scope (local at
  `bin/dispatch.sh:194`).

### Task 4: insert the rc=22 branch in `bin/run-stage.sh`

- `depends_on: [3]`
- `touches: bin/run-stage.sh::main` (between rc-124 and catch-all non-zero)

- [ ] Insert the new branch BETWEEN the existing rc-124 case
  (`bin/run-stage.sh:559-568`) and the catch-all non-zero case
  (`bin/run-stage.sh:569-573`), so the specific code is matched first
  (per brainstorm D-007):

  ```bash
  elif (( dispatch_rc == 22 )); then
    # ENG-43: implement-stage transcript invoked the forbidden
    # `gh pr create` tool. Read the matched command from the sidecar
    # written by _render_and_capture_stream and surface the same
    # operator-facing halt as the deleted state-check guard:
    # exit 22, skip-until-human-acts, pr-opened-too-early.
    local _viol_file _viol_cmd
    _viol_file="$(issue_dir "$ident")/.transcript-violation-${stage}"
    _viol_cmd="$(cat "$_viol_file" 2>/dev/null || printf '<command-unavailable>')"
    classify_failure "$ident" "$stage" "skip-until-human-acts" \
      "implement-stage transcript invoked forbidden tool: $_viol_cmd" 22
    rm -f "$_viol_file" "$prompt_file"
    exit 22
  ```

  Notes:
  - The reason text follows the brainstorm D-007 / issue Decisions §4
    contract verbatim: `implement-stage transcript invoked forbidden tool: <command>`.
  - `<command-unavailable>` is the explicit fallback if the sidecar is
    missing (e.g. dispatch crashed between writing it and the rc=22
    branch reading it). Keeps the halt comment readable rather than
    truncated.
  - The sidecar is removed AFTER read, before `exit 22`, so a re-tick
    finds a clean state.
  - `classify_failure` already emits the metric and posts the halt
    comment / `pipeline:halted` label per existing taxonomy; no new
    plumbing.

### Task 5: add fixtures AS1–AS6 to `bin/dispatch-test.sh`

- `depends_on: [1]`  (only needs the helper to exist; assertion's
  call-site change can land in the same PR but tests do not require it)
- `touches: bin/dispatch-test.sh` (new section, ~80 lines)

- [ ] Insert a new section AFTER fixture K (which ends at
  `bin/dispatch-test.sh:643`) and BEFORE the Gap-7 contract block
  (`bin/dispatch-test.sh:645`). Section header:

  ```bash
  # ─── Group 7: assert_no_tool_invocation fixtures (ENG-43, AS1-AS6) ────
  # AS1-AS6 deliver the issue's fixtures E-J (renamed per brainstorm
  # D-009 to avoid colliding with existing fixtures A-K above).
  printf '\n--- assert_no_tool_invocation fixtures (AS1-AS6, ENG-43; issue fixtures E-J) ---\n'

  if ! declare -f assert_no_tool_invocation >/dev/null 2>&1; then
    fail_at "precondition: assert_no_tool_invocation defined in dispatch.sh" \
            "function not found after sourcing — Task 1 implementation missing"
    printf '\nRESULTS: %d passed, %d failed\n' "$PASS" "$FAIL"
    exit 1
  fi
  ```

- [ ] Six fixtures (transcript writes go to `$_TEST_STUB_DIR/` so they
  do not pollute `$ISSUE_DIR`):

  - **AS1** (issue fixture E) — tool_use invoking `gh pr create --title …`
    matches; helper returns 1; matched command on stdout.
  - **AS2** (F) — tool_use invocations of `git status`, `git log`,
    `gh pr list` only; helper returns 0; stdout empty.
  - **AS3** (G) — `assistant.message.content[].text` block with literal
    `gh pr create` prose; helper returns 0 (text blocks never matched).
  - **AS4** (H) — JSON-escaped quoted `"gh pr create"` inside a `text`
    field; helper returns 0 (text blocks never matched).
  - **AS5** (I) — one malformed JSON line followed by a valid matching
    tool_use; `fromjson?` skips malformed; helper returns 1.
  - **AS6** (J) — missing transcript file (`$_TEST_STUB_DIR/tx-as6-missing`,
    never created); helper returns 0 (D-005 soft-fail).

  Skeleton for AS1 (full block in brainstorm §9.1; the agent generates
  the rest by analogy):

  ```bash
  # AS1 — issue fixture E: tool_use invoking gh pr create matches
  TX_AS1="$_TEST_STUB_DIR/tx-as1.ndjson"
  cat > "$TX_AS1" <<'NDJSON'
  {"type":"system","subtype":"init","session_id":"as1","model":"claude-opus-4-7"}
  {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"gh pr create --title foo --body bar"}}]}}
  NDJSON
  out_as1="$(assert_no_tool_invocation "$TX_AS1" "gh pr create")" && rc_as1=0 || rc_as1=$?
  if [[ "$rc_as1" == "1" && "$out_as1" == "gh pr create --title foo --body bar" ]]; then
    pass_at "AS1: tool_use match returns 1 + matched command on stdout"
  else
    fail_at "AS1" "rc=$rc_as1 out=$out_as1"
  fi
  ```

  AS2-AS6 follow the same shape. AS6 specifically does NOT
  `cat > "$TX_AS6"` — it just references a path that does not exist:

  ```bash
  # AS6 — issue fixture J: missing transcript file → rc=0 (soft-fail)
  TX_AS6="$_TEST_STUB_DIR/tx-as6-missing-do-not-create.ndjson"
  rm -f "$TX_AS6"
  out_as6="$(assert_no_tool_invocation "$TX_AS6" "gh pr create")" && rc_as6=0 || rc_as6=$?
  if [[ "$rc_as6" == "0" && -z "$out_as6" ]]; then
    pass_at "AS6: missing transcript → rc=0 (soft-fail)"
  else
    fail_at "AS6" "rc=$rc_as6 out=$out_as6"
  fi
  ```

  All six fixtures use the existing `pass_at` / `fail_at` helpers
  defined at `bin/dispatch-test.sh:74-75`. Implementation agent verifies
  the section sits BEFORE the Gap-7 prompt↔allowlist block at
  `bin/dispatch-test.sh:645` and uses standalone variable names (e.g.
  `TX_AS1`, `out_as1`) so subsequent fixtures can re-use the slot
  pattern without bash-local-variable leakage.

### Task 6: update `CLAUDE.md` "When wiring a new script" section

- `depends_on: []`
- `touches: CLAUDE.md` (one new bullet)

- [ ] Append a single bullet after the existing last bullet at
  `CLAUDE.md:259`:

  ```
  - Defense-in-depth on top of tool-lane denials: when a stage's contract says
    "agent must not invoke tool X," prefer a transcript-based assertion
    (`assert_no_tool_invocation` in `bin/dispatch.sh`) over a state-of-the-world
    check after dispatch. State checks false-positive on actions taken by other
    actors (humans, prior stages, future agents); transcript checks answer the
    contract question directly. Today only the implement stage uses this
    pattern (forbidding `gh pr create`); generalising to other stages is a
    separate refactor.
  ```

  Constraint: keep the bullet style consistent with the existing six
  bullets (no fenced blocks, no nested headings). The CLAUDE.md section
  already has bullets that span ~3 lines, so the prose length is
  in-pattern.

## Frontend Tasks

No frontend tasks. This is a bash orchestration repo with no UI surface.

## Failure Mode → Test Map

Every row from brainstorm §4 (Edge cases & failure modes) is bound to a
concrete test. Test layer ∈ { unit, integration, smoke }.

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
|---|---|---|---|---|
| Lane-misconfigured implement agent invokes `gh pr create` | tool_use Bash event with `.input.command` starting `gh pr create` in the stream-json transcript | Helper returns 1 with matched command on stdout; renderer writes sidecar and returns 22; run-stage classifies as `skip-until-human-acts` exit 22 | unit | `bin/dispatch-test.sh` AS1 (helper); manual confirm of run-stage routing once the rc=22 branch lands (no new run-stage-test case per §9.2) |
| Implement agent uses only allowed tools (`git`, `gh pr list`, etc.) | tool_use Bash events with `git status`, `git log`, `gh pr list` only | Helper returns 0; renderer falls through; run-stage continues to scope-check | unit | `bin/dispatch-test.sh` AS2 |
| Agent narrates "I considered `gh pr create` but used git instead" in a `text` block | assistant.message.content[].text block contains the literal pattern | Helper ignores `text`; returns 0 | unit | `bin/dispatch-test.sh` AS3 |
| Agent quotes a JSON-escaped `"gh pr create"` from a doc inside a `text` block | text block contains escaped quoted pattern | Helper ignores `text`; returns 0 | unit | `bin/dispatch-test.sh` AS4 |
| Stream-json contains one malformed line then a real matching tool_use | `{not json{` followed by valid tool_use | `fromjson?` skips malformed; match found; helper returns 1 | unit | `bin/dispatch-test.sh` AS5 |
| Implement runs but transcript is zero-byte / missing (claude died early; dry-run; planning-only path) | `[[ -s "$transcript" ]]` false | Helper returns 0; renderer falls through; no false halt | unit | `bin/dispatch-test.sh` AS6 |
| Multiple matching tool_use blocks (agent escalation) | two or more matching events in the transcript | jq stream order + `head -1` returns the first match; renderer surfaces only one command in halt comment | implicit (jq stream semantics; AS1 already exercises a single match — the multi-match shape is documented and fixed by `head -1`) | covered implicitly by AS1 stream order |
| tool_use with `.input.command` absent | Bash tool_use missing the command field | `// ""` defaults to empty; `startswith` is false; ignored | implicit (jq filter shape) | covered implicitly by AS2 (no command-field event among the allowed ones — verifies the // "" default does not match) |
| Non-Bash tool_use whose name accidentally starts with the pattern | `name == "Read"` etc. with spurious match | Filtered by `.name == "Bash"` predicate | implicit (jq filter shape) | covered implicitly by AS2 (Read/Edit/Grep tool_use events present and ignored) |
| Sidecar `.transcript-violation-implement` present from a prior crashed dispatch | renderer entry sees stale sidecar | Renderer's idempotent `rm -f "$violation_file"` at function entry pre-cleans | implicit (single-line `rm -f` in Task 2) | covered by code review of Task 2's pre-clean line |
| run-stage.sh crashes between dispatch and the rc=22 branch | sidecar persists beyond the dispatch boundary | Next dispatch's renderer pre-cleans on entry; no false replay | implicit (same code path as the bullet above) | covered by code review of Task 2 |
| Pattern contains regex metacharacters (operator passes `gh pr create.*`) | `startswith` with metachar pattern | jq's `startswith` is literal; `.*` matched as literal characters; safe by design | implicit (jq semantics) | covered by jq's documented behavior |
| jq absent / corrupted at runtime | the `2>/dev/null || true` clause fires; `matched` is empty | Helper returns 0 (soft-fail equivalent) | implicit (renderer requires jq for cost extraction one line earlier and would fail there first) | covered by existing renderer fixtures (jq-absent already trips fixture A) |
| Smoke: `bash bin/dry-run.sh` continues to exercise dispatch.sh's dry-run path without invoking the renderer | PIPELINE_DRY_RUN=1 short-circuits at `bin/dispatch.sh:238` | Renderer never called; assertion never fires; dry-run rc 0 | smoke | `bash bin/dry-run.sh` (offline; existing) |
| Integration: `bin/run-stage-test.sh` cases 11/12 (scope-violation rcs 3 and `*`) bump `implement_rejection` and continue to pass | unchanged (no edits to scope-check rcs) | rcs 21 with `implement_rejection` bump | integration | `bin/run-stage-test.sh` cases 11, 12 |

## Test Strategy

### Unit (six new fixtures via `bin/dispatch-test.sh`)

Six fixtures AS1–AS6 cover the helper's contract end-to-end:

- AS1: positive (match → rc=1 + stdout).
- AS2: negative (allowed tools only → rc=0).
- AS3: text-block prose ignored.
- AS4: JSON-escaped text-block content ignored.
- AS5: malformed-line tolerance + match.
- AS6: missing-transcript soft-fail.

Each fixture is self-contained: it writes (or does not write) an NDJSON
file under `$_TEST_STUB_DIR/`, calls `assert_no_tool_invocation`,
captures `(rc, stdout)`, and asserts the expected tuple. No claude
invocation, no real renderer, no harness ambient state.

### Integration (`bin/run-stage-test.sh`)

No new case is added (brainstorm §9.2). Stubbing dispatch.sh to return
22 with a sidecar pre-seeded is doable but adds material harness
complexity for marginal coverage; the fixture coverage of the helper
plus the small mechanical addition to run-stage.sh's exit ladder is
sufficient. Cases 11 and 12 (scope-violation rcs 3 and `*`) continue to
pass — they exercise the post-dispatch scope-check ladder, not the
dispatch_rc=22 branch.

### Smoke (`bash bin/dry-run.sh`)

`bin/dry-run.sh` continues to pass: dispatch.sh's PIPELINE_DRY_RUN=1
guard at `bin/dispatch.sh:238` short-circuits before the renderer is
invoked, so the assertion is never exercised in dry-run.

### Adversarial / regression

- AS3 + AS4 ensure that any future refactor that mistakenly broadens the
  match to `text` blocks fails immediately.
- AS5 ensures that a future refactor removing `fromjson?` or
  introducing a streaming-json shape breaks loudly rather than silently
  bypassing the assertion.
- AS6 ensures that any future refactor that drops the `[[ -s ]]`
  short-circuit synthesizes false positives in dry-run / planning-only
  paths.
- Fixture A's `RAW_A` cleanup assertion (`bin/dispatch-test.sh:421-424`)
  continues to verify that the RETURN trap fires unchanged after
  Task 2's edits (the trap is not moved or extended).

### Test command (full suite)

```bash
TARGET_REPO=/path/to/harness bash bin/dispatch-test.sh
TARGET_REPO=/path/to/harness bash bin/run-stage-test.sh
TARGET_REPO=/path/to/harness bash bin/poll-slot-test.sh
TARGET_REPO=/path/to/harness bash bin/scope-check-test.sh
TARGET_REPO=/path/to/harness bash bin/verdict-handler-test.sh
TARGET_REPO=/path/to/harness bash bin/classify-failure-test.sh
TARGET_REPO=/path/to/harness bash bin/halt-sprawl-test.sh
TARGET_REPO=/path/to/harness bash bin/halt-sprawl-adversarial-test.sh
TARGET_REPO=/path/to/harness bash bin/linear-test.sh
TARGET_REPO=/path/to/harness bash bin/metrics-test.sh
TARGET_REPO=/path/to/harness bash bin/mutex-test.sh
TARGET_REPO=/path/to/harness bash bin/setup-helpers-test.sh
TARGET_REPO=/path/to/harness bash bin/render-prompt-test.sh
TARGET_REPO=/path/to/harness bash bin/phase-project-profile-test.sh
TARGET_REPO=/path/to/harness bash bin/common-test.sh
PIPELINE_DRY_RUN=1 TARGET_REPO=/path/to/harness bash bin/dry-run.sh
```

Acceptance per the issue: `bin/dispatch-test.sh` passes including the
six new fixtures; `bin/run-stage-test.sh` continues to pass with cases
11 and 12 unaffected; `CLAUDE.md` mentions the pattern under "When
wiring a new script."

## Rollout

- Single PR off this feature branch into `main`.
- No flags, no phased rollout. The assertion is gated on
  `stage == "implement"` only; other stages observe no behavior change.
- After merge:
  - Operators with the harness driving itself (slug `harness`) and any
    other slug observe identical behavior unless an implement-stage
    dispatch invokes `gh pr create`. Today, the lane denies the tool, so
    the assertion is a silent no-op in steady state.
  - If a future PR misconfigures the lane (adds `Bash(gh:*)` to
    implement), the assertion catches it on the very next implement
    dispatch and halts with the same operator-facing surface as the
    deleted state-check guard. Operator resolves with
    `bash bin/halt.sh resolve <ENG-N> --decision resume` after fixing
    the lane.

## Open questions

None unresolved. Brainstorm §10 lists four open questions; all four
were answered in the brainstorm itself with explicit recommendations
(Q1 wait on second call site, Q2 sidecar lifecycle owned by
run-stage.sh, Q3 stale comment cleanup deferred, Q4 sub-agent dispatch
not in scope for v1). No decisions have been re-litigated here.

## Persona review

| Persona | Verdict | Notes |
|---|---|---|
| feasibility | PASS | All `path:line` references verified against the current branch (A-001 through A-013). No invented method names. The six fixtures use only existing test helpers. The new branch in run-stage.sh slots cleanly between two existing branches without renumbering or refactoring. The `_render_and_capture_stream` signature change (third positional arg with default `${3:-}`) is backwards-compatible for any non-`main()` caller. Every Failure Mode → Test Map row names a plausible test layer + test name. |
| scope | PASS | Every task and File Structure entry traces to brainstorm decisions D-001 through D-010. No gold-plating: the helper signature matches D-010 (decoupled), the call-site is gated to implement only (D-003), and the sidecar lifecycle stays minimal (D-008 + Q2). The deferred cleanup of the stale `(b) no-pr-check` comment at `bin/run-stage.sh:586` is explicitly declared out-of-scope (A-013). |
| coherence | PASS | Plan's Goal matches brainstorm Overview verbatim; the six fixtures jointly realize the issue's six required test cases (E-J ↔ AS1-AS6); Failure Mode → Test Map covers every row in brainstorm §4; Test Strategy commits to the same per-test-layer split. |
| design | PASS | Honors the harness's documented module boundaries: dispatch.sh dispatches and renders, run-stage.sh classifies (per `bin/run-stage.sh:565,570` precedent — explicit at brainstorm §5.2 rejected alternative). No layering violations. No circular deps. The sidecar lives under `$PROJECT_STATE_DIR/<issue>/` per the ENG-23 paths invariant (project-profile.md Don'ts). |
| product | PASS | Operator-facing surface is preserved verbatim: same exit code (22), same outcome name (`pr-opened-too-early`), same policy (`skip-until-human-acts`). No new label, no new marker, no new metric event. The reason text shape (`implement-stage transcript invoked forbidden tool: <command>`) is the only operator-visible change and it carries the matched command for diagnosis. |
