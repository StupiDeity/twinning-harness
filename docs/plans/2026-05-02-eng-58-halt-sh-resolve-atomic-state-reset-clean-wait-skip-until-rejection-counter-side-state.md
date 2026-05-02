---
linear: ENG-58
date: 2026-05-02
topic: halt.sh resolve — atomic state reset (wait/skip-until/issue-state/rejection-counter side state)
---

# Plan — ENG-58 halt.sh resolve atomic state reset

> **For agentic workers:** REQUIRED SUB-SKILL — use
> `superpowers:subagent-driven-development` (recommended) or
> `superpowers:executing-plans` to walk this task-by-task. Steps use
> `- [ ]` for tracking.

Implementation plan for the design in
`docs/brainstorms/2026-05-02-eng-58-halt-sh-resolve-atomic-state-reset-clean-wait-skip-until-rejection-counter-side-state-design.md`.

## Anti-anchoring

- **Problem (operator's words):** running `bash bin/halt.sh resolve ENG-N
  --decision resume` clears the visible `pipeline:halted` label but leaves
  the side state that drove the halt (`wait-${stage}.json`, `pipeline:skip-until-*`
  labels, `issue-state.json`, stale rejection-counter markers). The next
  dispatch sees the leftover state and re-halts the issue.
- **Does the brainstorm address it?** Yes. D-001 puts the cleanup inside
  `bin/halt.sh::resolve` (atomic with the operator command). D-002/D-008
  post the `pipeline-transition: <stage> → <stage> (operator-resume)`
  waypoint that resets `count_marker_since_last_transition` and
  `find_fresh_verdict` boundaries. D-005/D-006/D-007 enumerate the side
  state cleared. D-011 closes the chained `scope-approved` → `resume`
  flow which would otherwise re-halt via `_vh_protocol_violation`.
  D-009/D-012 keep `scope-approved`/`scope-rejected` as the documented
  narrower path with a stderr advisory when stale state coexists.
- **Proportional?** Yes. The change is one new helper plus an extended
  `case` arm in `bin/halt.sh::resolve`, six new test cases in
  `bin/halt-test.sh`, and one CLAUDE.md row update. No new marker shapes
  (D-002), no new state files, no new lanes, no API surface change. The
  brainstorm explicitly rejected wider alternatives (push cleanup into
  `poll.sh`; chain `reset-pipeline.sh`).
- **No escalation needed.**

## Goal

Extend `bin/halt.sh::resolve` so that `--decision resume` is an atomic
state reset — removing `pipeline:halted` AND `pipeline:skip-until-*` labels,
removing `$issue_dir/wait-*.json`, conditionally removing
`$issue_dir/issue-state.json` (iff `policy=skip-until-human-acts`), and
posting a `<!-- pipeline-transition: <stage> → <stage> (operator-resume) -->`
waypoint that resets rejection-counter / `find_fresh_verdict` freshness —
verifiable via `bash bin/halt-test.sh && bash bin/halt-sprawl-test.sh && bash bin/verdict-handler-test.sh && bash -n bin/halt.sh && bash bin/secret-probe-lint.sh`
exiting 0 with the new test cases (E–P) in PASS state and existing
halt-sprawl assertions unchanged.

## Architecture

This work is additive to one operator CLI (`bin/halt.sh`) and its sibling
test (`bin/halt-test.sh`); CLAUDE.md gets a one-row + one-subsection
docs update. No changes to `bin/poll.sh`, `bin/verdict-handler.sh`,
`bin/classify-failure.sh`, `bin/linear.sh`, `bin/guards.sh`,
`bin/run-stage.sh`, or `AGENT_PROMPTS.md` — the brainstorm explicitly
delimits the change as one helper + an extended `case` arm in the
existing `resolve()` function.

The architectural pivot is treating `--decision resume` as a *complete*
operator exit ramp from a halted issue: today it clears the surface label
but leaves the side state that originally drove the halt, breaking
compositionality of the halt-resume contract. ENG-58 closes that gap by
making the resume operation atomic at the operator-command boundary.

There is no `docs/VISION.md`, no `docs/knowledge/decisions.md`, no
`SYSTEM_ARCHITECTURE.md` in this repo (verified: `ls docs/` returns
`brainstorms/  plans/  runbooks/`). Governing constraints come from
`CLAUDE.md` and `learned-rules/harness/project-profile.md`. The relevant
learned-rules file `learned-rules/harness/plan.md` does not exist
(verified: `ls learned-rules/harness/` returns `project-profile.md`
only).

## Tech stack

- Bash 3.2+ (Darwin default, harness target).
- `jq` for `.policy` field reads from `issue-state.json`.
- `compgen -G` for safe glob expansion in `wait-*.json` deletion.
- `shasum -a 256` is unused here; the existing `add-comment` dedup runs
  after our writes (idempotency analysis at §test J in the brainstorm).
- No new dependencies. No `dispatch.sh::allowed_tools_for` cases added
  (halt.sh is operator-driven, not agent-dispatched).

## Assumption Inventory

Every modified-file fact below is `path:line`-cited against the current
worktree per ENG-5 P-002 / B-001. Assumptions marked `assumed/new`
identify the file where the artifact will be created.

### Modified files — current signatures and call sites

- **A-001 — `bin/halt.sh::resolve()` exists at `bin/halt.sh:16-65` with the
  decision dispatcher.** Verified at `bin/halt.sh:16-23` (entry +
  arg-validation), `bin/halt.sh:25-27` (decision-marker post),
  `bin/halt.sh:29-37` (resume branch sources `verdict-handler.sh`, calls
  `verdict_handler`), `bin/halt.sh:38-60` (`case "$rc"` dispatch on
  vh_rc=0/1/2/*), `bin/halt.sh:46` (case-1 `remove-label` for
  `pipeline:halted`), `bin/halt.sh:63` (non-resume final
  `remove-label`). The plan extends this function in place.

- **A-002 — `bin/halt.sh:14` exports `PIPELINE_WRITER=human`.** Verified.
  All Linear writes from halt.sh ride the human lane fence in
  `bin/linear.sh::_lane_decision` at `bin/linear.sh:73-91`. `add
  transition_comment` allows orchestrator,human at `bin/linear.sh:85`;
  `remove pipeline_skip_until` allows orchestrator,classify,human at
  `bin/linear.sh:84`; `remove pipeline_halted` allows orchestrator,human
  at `bin/linear.sh:80`. All three new writes pass the existing fences.

- **A-003 — `bin/halt.sh::main` arg-parse loop currently accepts any
  `ENG-*` token via the case glob at `bin/halt.sh:74-78`** (specifically
  `bin/halt.sh:76`: `ENG-*) issue="$1"; shift ;;`). The token is then
  fed unchanged into `issue_dir` (`bin/common.sh:61-65`) and used in
  filesystem `rm -f` calls. The plan adds a `^ENG-[0-9]+$` regex
  validator at the top of `resolve()` (D-014) before any FS or Linear
  write, and a fallback for `current_stage` against `^[a-z]+$`.

- **A-004 — `bin/halt-test.sh` exists at 90 lines; uses the
  source-and-stub pattern.** Verified at `bin/halt-test.sh:5-49`:
  `SCRIPT_DIR_REAL` resolution, `PIPELINE_DRY_RUN=1`, `STUB_DIR` setup
  with mock `linear.sh` (logs every call into `LINEAR_CALLS`) and mock
  `verdict-handler.sh` (`VH_RC` env var controls return). `source
  "$SCRIPT_DIR_REAL/halt.sh"` then post-source override of `SCRIPT_DIR`
  to point at the stub dir. Existing cases A–D at `bin/halt-test.sh:52-86`
  cover vh_rc=0/1/2 and scope-approved at the verdict-handler-call layer.
  The plan APPENDS new cases E–P; existing cases A–D stay unchanged.

- **A-005 — `bin/halt-test.sh:11-21` configures `_TEST_TARGET` (with
  `$_TEST_TARGET/.pipeline-config/config.json` fixture) and exports
  `TARGET_REPO`.** Verified. `PROJECT_STATE_DIR` is implicitly resolved
  from `PROJECT_SLUG=test-slug` + `HARNESS_STATE_DIR` default. New test
  cases need to materialise per-issue `wait-build.json` /
  `issue-state.json` files under `$(issue_dir <ENG-N>)`; the existing
  fixture's `PROJECT_STATE_DIR` is the right anchor.

- **A-006 — `CLAUDE.md:294` is the current `Kill switch` row** in the
  Failure-mode quick reference. Verified at `CLAUDE.md:286-294`. The
  plan replaces this single row with a row + bullet-list subsection
  documenting the atomic resume contract (per brainstorm §3.5; closes
  iter-1 Product P1 — "dense and operator-hostile").

### Read-only callees / state shapes — verified, not modified

- **A-007 — `bin/verdict-handler.sh::verdict_handler` returns 0
  (transitioned), 1 (halt preserved), 2 (protocol violation).** Verified
  at `bin/verdict-handler.sh:312-369`. Specifically: rc=0 via
  `apply_transition` at `bin/verdict-handler.sh:340-348`; rc=1 via the
  `pipeline-halt` arm at `bin/verdict-handler.sh:360-363`; rc=2 via
  `_vh_protocol_violation` at `bin/verdict-handler.sh:323-326,365` and
  the no-marker arm at `bin/verdict-handler.sh:323`.

- **A-008 — `bin/verdict-handler.sh::_vh_protocol_violation` re-applies
  `pipeline:halted` UNCONDITIONALLY** at `bin/verdict-handler.sh:58`.
  This is the trap D-011's `has-label pipeline:halted` guard avoids in
  the chained `scope-approved → resume` flow.

- **A-009 — `bin/verdict-handler.sh::apply_transition` posts
  `<!-- pipeline-transition: from → to -->` at lines 142-145** and
  removes `pipeline:halted` at `bin/verdict-handler.sh:256`. The vh_rc=0
  path therefore already has its own freshness boundary; D-003 skips
  the operator-resume waypoint in vh_rc=0.

- **A-010 — `find_fresh_verdict` boundary detection uses
  `contains("<!-- pipeline-transition:")` at
  `bin/verdict-handler.sh:75-78`.** Substring match — the
  `(operator-resume)` body suffix and the `from == to` shape are
  invisible to it. The boundary still fires; no parser change needed.

- **A-011 — `count_marker_since_last_transition` boundary detection uses
  the same `contains` check at `bin/guards.sh:46-48`.** Verified —
  same substring shape; the operator-resume waypoint is recognised as
  a transition.

- **A-012 — `resume_in_progress_transition` strict regex at
  `bin/verdict-handler.sh:276-279` requires `-->` immediately after
  `<to>`.** The `(operator-resume)` suffix breaks this regex, so the
  function falls through to `[[ -z "$from" || -z "$to" ]] && return 1`
  at `bin/verdict-handler.sh:280` — no spurious "completion" attempt
  on the operator-resume marker. ✓

- **A-013 — `bin/run-stage.sh::_handle_wait` writes
  `$(issue_dir "$ident")/wait-${stage}.json` at lines 378 and 424;
  `bin/run-stage.sh:455` deletes it on budget exhaust;
  `bin/run-stage.sh:836` deletes it on stage success.** Verified. The
  wholesale `wait-*.json` glob in D-005 is the canonical cleanup path
  outside those two existing call sites.

- **A-014 — `bin/run-stage.sh::_fresh_wait_reason` allow-lists `build`
  only** at `bin/run-stage.sh:308-311`. Today `wait-*.json` glob
  resolves only to `wait-build.json`; D-005's wholesale glob is
  build-only equivalent under current semantics and forward-compat if
  a future ticket re-broadens.

- **A-015 — `bin/classify-failure.sh::classify_failure` writes
  `issue-state.json` at lines 83-103 carrying `.policy` ∈
  `{retry-immediately, skip-until-code-changes, skip-until-human-acts}`.**
  Verified. D-006's `.policy == "skip-until-human-acts"` conditional
  reads this exact field via `jq -r '.policy // ""'`.

- **A-016 — `bin/classify-failure.sh:106-115` applies skip-until-*
  labels.** Verified — only `skip-until-code-changes` (line 109) and
  `skip-until-human-acts` (line 113) shapes exist today; D-007's
  wholesale removal of both is exhaustive.

- **A-017 — `bin/poll.sh::_poll_evaluate_skip` orphan-state-file cleanup
  at lines 55-63.** Verified — deletes `issue-state.json` when no
  skip label is present. D-006 documents that halt.sh's eager
  `issue-state.json` removal closes a one-tick race window where a
  dispatch could still observe stale state between halt.sh exit and
  the next poll.sh tick.

- **A-018 — `bin/poll.sh::_poll_classify_labels` halted branch at
  lines 217-233** calls `find_fresh_verdict` to decide
  `slot/advanceable`. Verified. The operator-resume waypoint is the
  freshness boundary that makes find_fresh_verdict return empty post-
  resume → `class='{"slot":"hold","advanceable":false}'` for any
  remaining halt label (impossible after the atomic reset, since halt
  label is removed in case 1).

- **A-019 — `bin/linear.sh::remove_label` is idempotent** at
  `bin/linear.sh:271-274` (no-ops with log line "label not present on
  $ident: $label_name (noop)" when the label is absent). D-007's
  wholesale removal of both skip-until-* shapes is therefore safe even
  if neither was applied.

- **A-020 — `bin/linear.sh::add_comment` dedup-by-hash** at
  `bin/linear.sh:455-487` strips ISO timestamps + git SHAs and hashes
  the normalized body, comparing against the last 10 comments. The
  operator-resume waypoint body is fixed for a given (issue, stage)
  pair (no timestamp inside the body), so back-to-back resume
  invocations against the same issue produce one waypoint comment;
  the second is correctly suppressed. The brainstorm §3.4 case J
  documents that the test STUB does NOT replicate dedup, so the test
  asserts `LINEAR_CALLS` count, not API-surface count.

- **A-021 — `bin/linear.sh::stage_of` returns the first `stage:*`
  label or empty** at `bin/linear.sh:287-290`. D-014's stage shape
  fallback (`current_stage="unknown"` when not `^[a-z]+$`) handles
  the empty-stage edge case (issue carries `pipeline:halted` but no
  `stage:*` label).

- **A-022 — `bin/linear.sh::has_label`** at `bin/linear.sh:292-297`
  is the existence query D-011 wraps around the `verdict_handler`
  call to short-circuit the chained `scope-approved → resume` re-halt
  trap.

- **A-023 — `bin/common.sh::issue_dir`** at `bin/common.sh:61-65`
  returns `$PROJECT_STATE_DIR/<issue>`. Per CLAUDE.md "Don'ts": never
  reference `$HARNESS_STATE_DIR/<issue>` directly; the helper is the
  canonical path resolver for per-issue scratch state.

- **A-024 — `bin/halt-sprawl-test.sh` exclusively tests
  `_poll_emit_halt_sprawl_alert`** (in `poll.sh`), NOT `halt.sh`.
  Verified — `grep _poll_emit_halt_sprawl_alert bin/halt-sprawl-test.sh`
  shows 11 matches at lines 191, 213, 243, 265, 266, 292, 303, 325,
  348, 364, 385; every assertion calls that single function. The
  Linear issue's hint "halt-sprawl-test.sh (or a sibling test)" is
  misleading; per D-010 the new tests go to `bin/halt-test.sh` (the
  actual halt.sh-testing sibling).

- **A-025 — `bin/reset-pipeline.sh:42-43` is the existing precedent**
  for wholesale `pipeline:skip-until-*` removal in the human lane.
  Verified. D-007 mirrors this two-call shape for symmetry.

- **A-026 — `bin/metrics.sh` accepts the call shape**
  `metrics.sh <event> <issue> <stage> <outcome> <duration_ms> [notes…]`
  at `bin/metrics.sh:19-41`. D-013's `halt-resume` event is a new
  event name but does NOT require any metrics.sh code change — the
  helper writes any event name verbatim into `events.jsonl`. Notes
  ride as an unstructured space-separated string at line 39, which is
  where `wait_files=N skip_labels=M state_file=B waypoint_posted=B`
  goes.

- **A-027 — secret-handling lint at `bin/secret-probe-lint.sh`** is
  the project's enforcement point for the ENG-46 `${VAR:-FALLBACK}`
  guard. The new helper introduces no env-var fallback patterns
  against `*KEY|*TOKEN|*SECRET|ANTHROPIC*|GITHUB*|LINEAR*` names; the
  only env-var read is `${VH_RC:-0}` in the test stub (already
  present). Plan's verify-after step runs this lint.

- **A-028 — `bin/halt.sh:13-14` `PIPELINE_WRITER=human` export is
  file-scope** (not function-scope). Verified — applies to every Linear
  write inside `resolve()` including the new helper's writes. No need
  to re-export inside `_resolve_reset_side_state`.

### Assumed/new artifacts

- **A-N1 — `_resolve_reset_side_state` private helper is NEW** in
  `bin/halt.sh`. Will live above `resolve()` (alongside the file-scope
  `PIPELINE_WRITER=human` export at line 14, before line 16). Returns
  cleanup stats on stdout (`wait_files=N skip_labels=M state_file=true|false`)
  and logs to stderr via the existing `log` helper from common.sh.

- **A-N2 — `_emit_halt_resume_metric` private helper is NEW** in
  `bin/halt.sh`. Wraps a single `bash "$SCRIPT_DIR/metrics.sh"
  halt-resume …` call with `|| true` so emission failure does not
  fail the resume (D-013).

- **A-N3 — `_format_reset_audit` private helper is NEW** in
  `bin/halt.sh`. Single-line formatter that produces the body
  fragment "Cleared: <stats>" appended to the operator-resume
  waypoint comment body (D-013, supports closure of iter-1 Product P1
  "diagnostic body").

- **A-N4 — `_observe_stale_side_state` private helper is NEW** in
  `bin/halt.sh`. Stderr-only advisory; called from the
  `scope-approved`/`scope-rejected` non-resume branch when stale
  side state coexists (D-012).

- **A-N5 — Test cases E, F, G, H, I, J, K, L, M, N, O, P, Q, R** are
  NEW in `bin/halt-test.sh`, appended after the existing `Case D` at
  `bin/halt-test.sh:80-86` and before the `RESULTS` summary at
  `bin/halt-test.sh:88-90`. The cases cover the brainstorm §3.4
  matrix plus two operator-facing safety contracts: side-state cleanup
  on vh_rc=0/1/2 (E/F/G), `scope-approved` preservation + advisory
  (H/M), conditional `issue-state.json` for
  `policy=skip-until-code-changes` (I), idempotency (J), ENG-24
  rejection-counter regression (K), chained scope-approved → resume
  D-011 trap (L), `metrics.sh halt-resume` capture (N), path-traversal
  D-014 (O), stage-shape sanitization (P), corrupt-JSON guard (Q —
  brainstorm §5), and `PIPELINE_DRY_RUN=1` FS-vs-Linear contract
  (R — brainstorm §6). Existing cases A–D get a one-line
  `LABELS_ON="pipeline:halted"` injection so they continue to exercise
  the verdict-handler-call layer they were originally written to test
  (without it, D-011's has-label guard short-circuits and Cases A/B's
  assertions about the `remove-label pipeline:halted` count become
  meaningless).

- **A-N6 — `events.jsonl` `halt-resume` event is NEW.** No schema
  change is needed — `bin/metrics.sh` writes any event name verbatim
  (A-026). Downstream consumers (status.sh, retrospective §1) do not
  filter on this event name today; they will start to once it exists,
  per the standard "additive event name" convention used in prior
  brainstorms.

## File Structure

```
bin/
  halt.sh           modified  — add 4 private helpers (_resolve_reset_side_state,
                                _emit_halt_resume_metric, _format_reset_audit,
                                _observe_stale_side_state); extend resolve() with
                                D-014 input validation, D-011 has-label guard,
                                D-008 atomic ordering in case 1, D-002 operator-
                                resume waypoint, D-003/D-004 vh_rc-branched
                                cleanup, D-009 narrower non-resume path with
                                D-012 advisory.  (Tasks 1, 2)
  halt-test.sh      modified  — append cases E–R after existing case D;
                                inject LABELS_ON="pipeline:halted" into
                                existing cases A–D for D-011 compatibility.  (Task 3)

CLAUDE.md           modified  — replace "Kill switch" row at line 294 with row
                                + atomic-resume contract subsection.  (Task 4)
```

No changes to: `bin/poll.sh`, `bin/verdict-handler.sh`,
`bin/classify-failure.sh`, `bin/linear.sh`, `bin/guards.sh`,
`bin/run-stage.sh`, `bin/run-local.sh`, `bin/dispatch.sh`,
`bin/common.sh`, `bin/metrics.sh`, `bin/reset-pipeline.sh`,
`bin/halt-sprawl-test.sh`, `bin/halt-sprawl-adversarial-test.sh`,
`AGENT_PROMPTS.md`, `learned-rules/**`, `launchd/**`,
`.github/workflows/**`.

## API Contract

**No new API surface.** The harness has no FE↔BE API surface; halt.sh is
an operator CLI. The change adds:

- One new metrics event name (`halt-resume`) — written verbatim by the
  pre-existing `bin/metrics.sh` helper (no schema migration; A-026, A-N6).
- One body suffix (`(operator-resume)`) on an existing comment shape
  (`<!-- pipeline-transition: <stage> → <stage> -->`). The four-shape
  verdict vocabulary stays at four (D-002 — body-text only; not a new
  marker shape).
- Three CLI-level idempotent post-conditions on the existing `--decision
  resume` invocation (skip-until-* labels removed; `wait-*.json` removed;
  `issue-state.json` conditionally removed).

No CLI argv change, no env-var addition, no on-disk state-file format
change, no new exit code (the existing `0` / non-zero / `2` rc
semantics on resolve() are preserved per the brainstorm §3.3 sketch).

---

## Backend Tasks

(The harness has only "backend" code in the bash-script sense — see
*Frontend Tasks* below for the no-op statement.)

### Task 1: Add four private helpers to `bin/halt.sh`

- `depends_on: []`
- `touches: bin/halt.sh (new functions: _resolve_reset_side_state, _emit_halt_resume_metric, _format_reset_audit, _observe_stale_side_state)`

- [ ] In `bin/halt.sh`, INSERT four private helpers between the
      file-scope `export PIPELINE_WRITER=human` at line 14 and the
      `resolve()` function at line 16. Place them in this order so
      forward references in `resolve()` resolve cleanly when sourced by
      `bin/halt-test.sh`.

- [ ] Helper 1 — `_resolve_reset_side_state` (D-001 / D-005 / D-006 /
      D-007). Idempotent: every operation no-ops when the target is
      absent. Reads `$issue_dir/issue-state.json` `.policy` via
      `jq -e .` guarded for invalid JSON. Writes: removes labels,
      removes files. Stdout: single line
      `wait_files=N skip_labels=M state_file=true|false`. Stderr: `log`
      lines via the common.sh helper.

      ```bash
      _resolve_reset_side_state() {
        local issue="$1"
        local d; d="$(issue_dir "$issue")"
        # Defense in depth (D-014/Security): reject empty issue_dir before any rm.
        [[ -n "$d" ]] || die "halt-resolve: empty issue_dir for $issue"

        # D-007: skip-until-* removal (idempotent — has-label gate so the
        # count reflects actual removals, not no-op calls).
        local skip_count=0
        for lbl in "pipeline:skip-until-code-changes" "pipeline:skip-until-human-acts"; do
          if bash "$SCRIPT_DIR/linear.sh" has-label "$issue" "$lbl" 2>/dev/null; then
            bash "$SCRIPT_DIR/linear.sh" remove-label "$issue" "$lbl" 2>/dev/null || true
            skip_count=$((skip_count + 1))
          fi
        done

        # D-005: wholesale wait-*.json glob removal. compgen handles
        # no-match cleanly without nullglob.
        local wait_count=0
        if compgen -G "$d/wait-*.json" >/dev/null 2>&1; then
          wait_count="$(compgen -G "$d/wait-*.json" | wc -l | tr -d ' ')"
          rm -f "$d"/wait-*.json 2>/dev/null || true
        fi

        # D-006: conditional issue-state.json removal.
        local state_file="$d/issue-state.json"
        local state_removed=false
        if [[ -s "$state_file" ]] && jq -e . "$state_file" >/dev/null 2>&1; then
          local policy
          policy="$(jq -r '.policy // ""' "$state_file" 2>/dev/null || printf '')"
          if [[ "$policy" == "skip-until-human-acts" ]]; then
            rm -f "$state_file"
            state_removed=true
            log "halt-resolve: removed $state_file (policy=skip-until-human-acts)"
          fi
        fi

        printf 'wait_files=%d skip_labels=%d state_file=%s' \
          "$wait_count" "$skip_count" "$state_removed"
      }
      ```

- [ ] Helper 2 — `_format_reset_audit` (D-013). Renders the
      machine-shorthand stats string into a human-readable plain-English
      sentence for the operator-resume waypoint body. The stats string
      shape is `wait_files=N skip_labels=M state_file=true|false`
      produced by `_resolve_reset_side_state`.

      ```bash
      _format_reset_audit() {
        local stats="$1"
        local wf sl sf
        wf="$(printf '%s' "$stats" | sed -nE 's/.*wait_files=([0-9]+).*/\1/p')"
        sl="$(printf '%s' "$stats" | sed -nE 's/.*skip_labels=([0-9]+).*/\1/p')"
        sf="$(printf '%s' "$stats" | sed -nE 's/.*state_file=(true|false).*/\1/p')"
        local state_phrase
        if [[ "$sf" == "true" ]]; then
          state_phrase=", issue-state.json removed"
        else
          state_phrase=""
        fi
        printf '_Cleared:_ %s wait file(s), %s skip-until-* label(s)%s.\n' \
          "${wf:-0}" "${sl:-0}" "$state_phrase"
      }
      ```

      Example output: `_Cleared:_ 1 wait file(s), 1 skip-until-* label(s),
      issue-state.json removed.` — readable in Linear's UI without the
      operator translating `state_file=true` mentally.

- [ ] Helper 3 — `_emit_halt_resume_metric` (D-013). Wrapped in `|| true`
      so emission failure does not fail the resume.

      ```bash
      _emit_halt_resume_metric() {
        local issue="$1" stage="$2" stats="$3" waypoint_posted="$4"
        bash "$SCRIPT_DIR/metrics.sh" halt-resume "$issue" "$stage" \
          "atomic-reset" 0 "$stats waypoint_posted=$waypoint_posted" || true
      }
      ```

- [ ] Helper 4 — `_observe_stale_side_state` (D-012). Stderr-only
      advisory. Called from the non-resume `scope-*` branch.

      ```bash
      _observe_stale_side_state() {
        local issue="$1"
        local d; d="$(issue_dir "$issue")"
        local hits=()
        bash "$SCRIPT_DIR/linear.sh" has-label "$issue" "pipeline:skip-until-code-changes" 2>/dev/null \
          && hits+=("pipeline:skip-until-code-changes")
        bash "$SCRIPT_DIR/linear.sh" has-label "$issue" "pipeline:skip-until-human-acts" 2>/dev/null \
          && hits+=("pipeline:skip-until-human-acts")
        compgen -G "$d/wait-*.json" >/dev/null 2>&1 && hits+=("$d/wait-*.json")
        [[ -s "$d/issue-state.json" ]] && hits+=("$d/issue-state.json")
        if (( ${#hits[@]} > 0 )); then
          # Quote $HARNESS_ROOT in the recommended command so an operator
          # cargo-cult-copy-pasting at 2am gets a tokenization-safe form
          # even if the path contains spaces.
          printf 'halt.sh: NOTE — stale side state detected on %s (%s); run `bash "%s/bin/halt.sh" resolve %s --decision resume` to clear.\n' \
            "$issue" "$(IFS=', '; printf '%s' "${hits[*]}")" "$HARNESS_ROOT" "$issue" >&2
        fi
      }
      ```

- [ ] Verify the helpers parse cleanly: `bash -n bin/halt.sh` exits 0.
- [ ] Verify no secret-leak patterns introduced:
      `bash bin/secret-probe-lint.sh` exits 0 (the new helpers use no
      `${VAR:-X}` patterns against secret-named vars; A-027).

### Task 2: Extend `resolve()` with D-002, D-003, D-004, D-008, D-009, D-011, D-012, D-013, D-014

- `depends_on: [1]`  *(uses helpers from Task 1)*
- `touches: bin/halt.sh::resolve (replaces lines 16-65 in place)`

- [ ] At the TOP of `resolve()` (currently `bin/halt.sh:16-19`), insert
      D-014 input validation BEFORE the existing decision arg validation:

      ```bash
        # D-014: strict issue-id validation before ANY filesystem or Linear write.
        # Closes Security P1 (path-traversal via ENG-* glob in main()).
        [[ "$issue" =~ ^ENG-[0-9]+$ ]] \
          || die "halt.sh: invalid issue id '$issue' (expected ENG-<digits>)"
      ```

      Keep the existing `[[ -n "$issue" && -n "$decision" ]] || die …` and
      `case "$decision"` block at lines 18-23 unchanged after this
      insertion.

- [ ] Keep the existing `add-comment` of the `<!-- pipeline-decision:
      <decision> -->` marker at lines 25-27 unchanged. (D-009: this
      marker is preserved on every code path; only the resume branch
      gets the additional waypoint.)

- [ ] REPLACE the existing `if [[ "$decision" == "resume" ]]; then …
      fi` block at lines 29-61 with the extended flow below. The change
      composes D-011 (has-label guard around verdict_handler), D-014
      (stage-shape sanitization), D-004 (cleanup runs in vh_rc=0 AND
      vh_rc=1, NEVER vh_rc=2), D-003 (operator-resume waypoint posted
      in vh_rc=1 only), D-008 (atomic ordering: cleanup → halt-remove →
      waypoint LAST), D-013 (metric emission).

      ```bash
        if [[ "$decision" == "resume" ]]; then
          # ENG-49 Gap #2: invoke verdict-handler BEFORE clearing
          # pipeline:halted so any fresh forward verdict actually advances
          # the stage.
          # shellcheck source=verdict-handler.sh
          source "$SCRIPT_DIR/verdict-handler.sh"
          local current_stage rc=0 had_halt=0 cleared_waypoint=0
          current_stage="$(bash "$SCRIPT_DIR/linear.sh" stage-of "$issue")"
          current_stage="${current_stage#stage:}"
          # D-014 bonus: validate stage-name shape before printf %s
          # interpolation into the operator-resume waypoint body.
          [[ "$current_stage" =~ ^[a-z]+$ ]] || current_stage="unknown"

          # D-011: skip verdict_handler when pipeline:halted is absent.
          # The chained scope-approved → resume flow lands here; calling
          # verdict_handler with no halt + no fresh marker would fire
          # _vh_protocol_violation, which unconditionally re-applies
          # pipeline:halted (bin/verdict-handler.sh:58) — strictly worse
          # than the bug ENG-58 set out to fix. Synthesize vh_rc=1 in
          # that case so the cleanup-and-waypoint path runs.
          if bash "$SCRIPT_DIR/linear.sh" has-label "$issue" "pipeline:halted"; then
            had_halt=1
            verdict_handler "$issue" "$current_stage" || rc=$?
          else
            log "halt-resolve: pipeline:halted absent; skipping verdict_handler (D-011)"
            rc=1
          fi

          case "$rc" in
            0)
              # D-004: cleanup runs on the transitioned arm too.
              # D-003: NO operator-resume waypoint — apply_transition's
              # own <!-- pipeline-transition: from → to --> at
              # bin/verdict-handler.sh:142-145 is the freshness boundary.
              local stats; stats="$(_resolve_reset_side_state "$issue")"
              _emit_halt_resume_metric "$issue" "$current_stage" "$stats" "$cleared_waypoint"
              log "halt resolved: $issue decision=resume (verdict-handler transitioned; side state reset: $stats)"
              return 0
              ;;
            1)
              # D-008 atomic ordering: cleanup → halt-remove (only if
              # had_halt) → operator-resume waypoint LAST. Posting last
              # means a partial-failure earlier in the sequence is
              # idempotently recoverable by re-running halt.sh resolve.
              local stats; stats="$(_resolve_reset_side_state "$issue")"
              if (( had_halt )); then
                bash "$SCRIPT_DIR/linear.sh" remove-label "$issue" "pipeline:halted"
              fi
              local waypoint_body
              waypoint_body="$(printf '<!-- pipeline-transition: %s → %s (operator-resume) -->\n\nOperator-attributed transition waypoint (halt.sh resolve --decision resume).\n\n%s' \
                                "$current_stage" "$current_stage" \
                                "$(_format_reset_audit "$stats")")"
              bash "$SCRIPT_DIR/linear.sh" add-comment "$issue" "$waypoint_body"
              cleared_waypoint=1
              _emit_halt_resume_metric "$issue" "$current_stage" "$stats" "$cleared_waypoint"
              if (( had_halt )); then
                log "halt resolved: $issue decision=resume (halt label cleared; side state reset: $stats; operator-resume waypoint posted)"
              else
                log "halt resolved: $issue decision=resume (halt label absent; side state reset: $stats; operator-resume waypoint posted)"
              fi
              return 0
              ;;
            2)
              # D-004: NO cleanup, NO waypoint, NO halt removal. Operator
              # must investigate the protocol violation before resuming.
              printf 'halt.sh: verdict-handler reported protocol violation on %s; halt label preserved.\n' "$issue" >&2
              printf 'halt.sh: see Linear comment with sig protocol-violation/<case_id>/%s for details.\n' "$issue" >&2
              return 2
              ;;
            *)
              die "verdict_handler returned unknown rc=$rc"
              ;;
          esac
        fi
      ```

- [ ] REPLACE the existing non-resume tail (currently `bin/halt.sh:63-64`:
      `bash "$SCRIPT_DIR/linear.sh" remove-label "$issue" "pipeline:halted"` +
      `log "halt resolved: $issue decision=$decision"`) with the D-009
      narrower path + D-012 advisory:

      ```bash
        # D-009: scope-approved / scope-rejected — narrower path. Posts
        # decision marker (already done above), removes pipeline:halted,
        # leaves all side state intact (scope-deviation halts don't
        # accrue skip labels / wait files / issue-state.json — see
        # brainstorm D-009 for the rationale). D-012: emit a stderr
        # advisory if stale halt-related side state coexists with this
        # issue, pointing the operator to the resume path.
        _observe_stale_side_state "$issue"
        bash "$SCRIPT_DIR/linear.sh" remove-label "$issue" "pipeline:halted"
        log "halt resolved: $issue decision=$decision"
      ```

- [ ] Verify the file parses: `bash -n bin/halt.sh` exits 0.
- [ ] Verify no `${VAR:-FALLBACK}` against secret-named env vars
      (ENG-46): `bash bin/secret-probe-lint.sh` exits 0.

### Task 3: Append test cases E–P to `bin/halt-test.sh`

- `depends_on: [1, 2]`  *(asserts behavior introduced by Tasks 1+2)*
- `touches: bin/halt-test.sh (insertions after line 86, before the RESULTS summary at line 88)`

The existing test harness already provides:
- `LINEAR_CALLS` log of every stub linear.sh call
- `VH_RC` env var to control `verdict_handler`'s return
- `$_TEST_TARGET` / `PROJECT_STATE_DIR`-rooted scratch space

The new cases need a small fixture-helper to materialise per-issue
`wait-build.json` / `issue-state.json` files and (for the `has-label`
stub in D-011/D-007) a `LABEL_PRESENT` env-var-driven mock. Place all
new code AFTER line 86 (`Case D` end) and BEFORE line 88 (`printf
'\nRESULTS: %d passed, %d failed\n'`).

- [ ] Append a test fixture helper above the new cases:

      ```bash
      # ─── ENG-58 fixture helpers ─────────────────────────────────────
      _eng58_seed_side_state() {
        # Args: <issue> [policy=skip-until-human-acts|skip-until-code-changes]
        local issue="$1" policy="${2:-skip-until-human-acts}"
        local d="$PROJECT_STATE_DIR/$issue"
        mkdir -p "$d"
        printf '{"reason":"awaiting-approval","attempts":12}\n' > "$d/wait-build.json"
        jq -cn --arg p "$policy" '{policy:$p, evidence:{pipeline_content_hash:"abc",branch_head_sha:"def"}}' \
          > "$d/issue-state.json"
      }

      _eng58_clear_side_state() {
        rm -rf "$PROJECT_STATE_DIR/$1"
      }
      ```

- [ ] Replace the existing `linear.sh` stub at lines 25-34 with a more
      capable mock that returns has-label results from a `LABELS_ON`
      env-var allow-list, so cases E/F/G/H/I/J/L/M can drive the new
      `has-label pipeline:halted` and `has-label pipeline:skip-until-*`
      branches:

      ```bash
      cat > "$_TEST_STUB/linear.sh" <<SH
      #!/usr/bin/env bash
      printf '%s\n' "\$*" >> "$LINEAR_CALLS"
      case "\$1" in
        add-comment|remove-label|add-label) exit 0 ;;
        stage-of) printf '%s' "\${STAGE_OF:-stage:ui}" ;;
        has-label)
          # \$2 = issue, \$3 = label. Match against LABELS_ON CSV.
          case ",\${LABELS_ON:-}," in *,"\$3",*) exit 0 ;; *) exit 1 ;; esac
          ;;
        *) exit 0 ;;
      esac
      SH
      ```

      A `metrics.sh` stub is also needed to capture the D-013 emission:

      ```bash
      METRICS_CALLS="$_TEST_STUB/metrics-calls.log"
      : > "$METRICS_CALLS"
      cat > "$_TEST_STUB/metrics.sh" <<SH
      #!/usr/bin/env bash
      printf '%s\n' "\$*" >> "$METRICS_CALLS"
      exit 0
      SH
      chmod +x "$_TEST_STUB/metrics.sh"
      ```

      Existing case A–D semantics: the `stage-of`
      `${STAGE_OF:-stage:ui}` default matches the prior
      `printf 'stage:ui'`. **However**, the new D-011 `has-label
      pipeline:halted` guard inside `resolve()` means cases A–D need
      `LABELS_ON="pipeline:halted"` injected so the post-source
      `verdict_handler` invocation actually runs (otherwise D-011
      synthesizes rc=1 and Cases A/B's assertions about whether
      `remove-label pipeline:halted` is called become meaningless).
      Update existing cases A–D to set `LABELS_ON` accordingly:

      ```bash
      # Case A (line 53-54 in current file): add LABELS_ON to drive D-011 guard.
      LABELS_ON="pipeline:halted" VH_RC=0 resolve "ENG-980" "resume" >/dev/null 2>&1 || true
      # Case B (line 61-62): same.
      LABELS_ON="pipeline:halted" VH_RC=1 resolve "ENG-981" "resume" >/dev/null 2>&1 || true
      # Case C (line 70-71): same.
      ( LABELS_ON="pipeline:halted" VH_RC=2 resolve "ENG-982" "resume" >/dev/null 2>&1 ) || exit_code=$?
      # Case D (line 81-82): scope-approved doesn't reach the resume branch's
      #                      D-011 guard, but LABELS_ON is read by
      #                      _observe_stale_side_state — pass it as empty so the
      #                      advisory does NOT fire (no stale skip labels seeded).
      LABELS_ON="pipeline:halted" VH_RC=99 resolve "ENG-983" "scope-approved" >/dev/null 2>&1 || true
      ```

      Without these `LABELS_ON` injections, Case B's assertion
      (`remove-label pipeline:halted` called once) fails because the
      D-011 short-circuit sets `had_halt=0` and the `(( had_halt ))`
      guard skips the `remove-label` call.

- [ ] Append cases E–P. Each case sets `LABELS_ON` to drive the
      `has-label` stub, calls `_eng58_seed_side_state` where needed,
      runs `resolve`, and asserts on `LINEAR_CALLS` / `METRICS_CALLS` /
      filesystem state. Pattern matches the existing case A–D shape
      (`ok`/`nope` bookkeeping; `: > "$LINEAR_CALLS"` between cases).

      ```bash
      # ─── ENG-58 Case E: vh_rc=1 + halted + full side state → atomic reset ───
      : > "$LINEAR_CALLS"; : > "$METRICS_CALLS"
      _eng58_seed_side_state "ENG-984" skip-until-human-acts
      LABELS_ON="pipeline:halted,pipeline:skip-until-human-acts" \
        VH_RC=1 STAGE_OF="stage:building" \
        resolve "ENG-984" "resume" >/dev/null 2>&1 || true
      wait_present=0; [[ -e "$PROJECT_STATE_DIR/ENG-984/wait-build.json" ]] && wait_present=1
      state_present=0; [[ -e "$PROJECT_STATE_DIR/ENG-984/issue-state.json" ]] && state_present=1
      skip_remove="$(grep -c "^remove-label ENG-984 pipeline:skip-until-human-acts$" "$LINEAR_CALLS" || true)"
      halt_remove="$(grep -c "^remove-label ENG-984 pipeline:halted$" "$LINEAR_CALLS" || true)"
      waypoint="$(grep -c "operator-resume" "$LINEAR_CALLS" || true)"
      if [[ "$wait_present" == "0" && "$state_present" == "0" \
            && "$skip_remove" == "1" && "$halt_remove" == "1" \
            && "$waypoint" -ge "1" ]]; then
        ok "ENG-58 E: vh_rc=1 atomic reset (wait+state cleared, labels removed, waypoint posted)"
      else
        nope "ENG-58 E: vh_rc=1 atomic reset" \
          "wait=$wait_present state=$state_present skip_remove=$skip_remove halt_remove=$halt_remove waypoint=$waypoint"
      fi
      _eng58_clear_side_state "ENG-984"

      # ─── ENG-58 Case F: vh_rc=0 + halted → cleanup runs, NO waypoint ───────
      : > "$LINEAR_CALLS"; : > "$METRICS_CALLS"
      _eng58_seed_side_state "ENG-985" skip-until-human-acts
      LABELS_ON="pipeline:halted,pipeline:skip-until-human-acts" \
        VH_RC=0 STAGE_OF="stage:building" \
        resolve "ENG-985" "resume" >/dev/null 2>&1 || true
      wait_present=0; [[ -e "$PROJECT_STATE_DIR/ENG-985/wait-build.json" ]] && wait_present=1
      waypoint="$(grep -c "operator-resume" "$LINEAR_CALLS" || true)"
      if [[ "$wait_present" == "0" && "$waypoint" == "0" ]]; then
        ok "ENG-58 F: vh_rc=0 cleanup runs without operator-resume waypoint"
      else
        nope "ENG-58 F: vh_rc=0 cleanup-only path" \
          "wait=$wait_present waypoint=$waypoint"
      fi
      _eng58_clear_side_state "ENG-985"

      # ─── ENG-58 Case G: vh_rc=2 → NO cleanup, halt preserved, exit 2 ───────
      : > "$LINEAR_CALLS"
      _eng58_seed_side_state "ENG-986" skip-until-human-acts
      exit_code=0
      ( LABELS_ON="pipeline:halted,pipeline:skip-until-human-acts" \
          VH_RC=2 STAGE_OF="stage:building" \
          resolve "ENG-986" "resume" >/dev/null 2>&1 ) || exit_code=$?
      wait_present=0; [[ -e "$PROJECT_STATE_DIR/ENG-986/wait-build.json" ]] && wait_present=1
      halt_remove="$(grep -c "^remove-label ENG-986 pipeline:halted$" "$LINEAR_CALLS" || true)"
      if [[ "$exit_code" -ne 0 && "$wait_present" == "1" && "$halt_remove" == "0" ]]; then
        ok "ENG-58 G: vh_rc=2 protocol violation preserves all state, exits non-zero"
      else
        nope "ENG-58 G: vh_rc=2 protocol violation" \
          "exit=$exit_code wait=$wait_present halt_remove=$halt_remove"
      fi
      _eng58_clear_side_state "ENG-986"

      # ─── ENG-58 Case H: scope-approved with stale side state → narrower
      #                   path + advisory; no cleanup ──────────────────────────
      : > "$LINEAR_CALLS"
      _eng58_seed_side_state "ENG-987" skip-until-human-acts
      stderr_capture="$(LABELS_ON="pipeline:halted,pipeline:skip-until-human-acts" \
        VH_RC=99 STAGE_OF="stage:implementing" \
        resolve "ENG-987" "scope-approved" 2>&1 >/dev/null || true)"
      wait_present=0; [[ -e "$PROJECT_STATE_DIR/ENG-987/wait-build.json" ]] && wait_present=1
      skip_remove="$(grep -c "^remove-label ENG-987 pipeline:skip-until-" "$LINEAR_CALLS" || true)"
      halt_remove="$(grep -c "^remove-label ENG-987 pipeline:halted$" "$LINEAR_CALLS" || true)"
      if [[ "$wait_present" == "1" && "$skip_remove" == "0" && "$halt_remove" == "1" \
            && "$stderr_capture" == *"NOTE — stale side state detected"* ]]; then
        ok "ENG-58 H: scope-approved preserves side state + emits advisory"
      else
        nope "ENG-58 H: scope-approved narrower path" \
          "wait=$wait_present skip_remove=$skip_remove halt_remove=$halt_remove advisory_seen=$([[ "$stderr_capture" == *"NOTE"* ]] && printf 1 || printf 0)"
      fi
      _eng58_clear_side_state "ENG-987"

      # ─── ENG-58 Case I: vh_rc=1 + policy=skip-until-code-changes →
      #                   issue-state.json PRESERVED ─────────────────────────
      : > "$LINEAR_CALLS"
      _eng58_seed_side_state "ENG-988" skip-until-code-changes
      LABELS_ON="pipeline:halted" VH_RC=1 STAGE_OF="stage:building" \
        resolve "ENG-988" "resume" >/dev/null 2>&1 || true
      state_present=0; [[ -e "$PROJECT_STATE_DIR/ENG-988/issue-state.json" ]] && state_present=1
      if [[ "$state_present" == "1" ]]; then
        ok "ENG-58 I: vh_rc=1 preserves issue-state.json when policy=skip-until-code-changes"
      else
        nope "ENG-58 I: D-006 policy conditional" \
          "state file removed (should have been preserved for evidence trail)"
      fi
      _eng58_clear_side_state "ENG-988"

      # ─── ENG-58 Case J: idempotency — back-to-back resume calls succeed ──
      # NOTE: the `|| true` pattern used in Cases A-D would clobber $? here.
      # Use a subshell + explicit capture so the rc actually reflects the
      # resolve() exit code.
      : > "$LINEAR_CALLS"; : > "$METRICS_CALLS"
      first_rc=0; second_rc=0
      ( LABELS_ON="pipeline:halted" VH_RC=1 STAGE_OF="stage:building" \
          resolve "ENG-989" "resume" >/dev/null 2>&1 ) || first_rc=$?
      ( LABELS_ON="pipeline:halted" VH_RC=1 STAGE_OF="stage:building" \
          resolve "ENG-989" "resume" >/dev/null 2>&1 ) || second_rc=$?
      metric_count="$(grep -c "^halt-resume ENG-989 building atomic-reset" "$METRICS_CALLS" || true)"
      if [[ "$first_rc" == 0 && "$second_rc" == 0 && "$metric_count" -ge "2" ]]; then
        ok "ENG-58 J: back-to-back resume calls are idempotent"
      else
        nope "ENG-58 J: idempotency" "rc1=$first_rc rc2=$second_rc metrics=$metric_count"
      fi
      _eng58_clear_side_state "ENG-989"

      # ─── ENG-58 Case K (regression): operator-resume waypoint resets the
      #     count_marker_since_last_transition boundary ────────────────────
      # The contains("<!-- pipeline-transition:") check at
      # bin/guards.sh:46-48 treats the operator-resume body as a fresh
      # transition. Verify the waypoint body contains that exact prefix.
      : > "$LINEAR_CALLS"
      LABELS_ON="pipeline:halted" VH_RC=1 STAGE_OF="stage:building" \
        resolve "ENG-990" "resume" >/dev/null 2>&1 || true
      contains_transition="$(grep -c "<!-- pipeline-transition: building → building (operator-resume) -->" "$LINEAR_CALLS" || true)"
      if [[ "$contains_transition" -ge "1" ]]; then
        ok "ENG-58 K: operator-resume waypoint matches contains() boundary used by guards/find_fresh_verdict"
      else
        nope "ENG-58 K: ENG-24 regression — waypoint shape" \
          "no comment with pipeline-transition: building → building (operator-resume) found in LINEAR_CALLS"
      fi
      _eng58_clear_side_state "ENG-990"

      # ─── ENG-58 Case L (D-011): chained scope-approved → resume on an
      #     issue with NO halt label does NOT call verdict_handler ──────────
      # If verdict_handler ran, the stub would obey VH_RC=2 and exit code
      # would be 2; with D-011 short-circuiting, rc=1 path runs and rc=0.
      : > "$LINEAR_CALLS"
      _eng58_seed_side_state "ENG-991" skip-until-human-acts
      exit_code=0
      ( LABELS_ON="pipeline:skip-until-human-acts" \
          VH_RC=2 STAGE_OF="stage:building" \
          resolve "ENG-991" "resume" >/dev/null 2>&1 ) || exit_code=$?
      wait_present=0; [[ -e "$PROJECT_STATE_DIR/ENG-991/wait-build.json" ]] && wait_present=1
      skip_remove="$(grep -c "^remove-label ENG-991 pipeline:skip-until-human-acts$" "$LINEAR_CALLS" || true)"
      halt_remove="$(grep -c "^remove-label ENG-991 pipeline:halted$" "$LINEAR_CALLS" || true)"
      if [[ "$exit_code" == 0 && "$wait_present" == "0" \
            && "$skip_remove" == "1" && "$halt_remove" == "0" ]]; then
        ok "ENG-58 L (D-011): bypass verdict_handler when pipeline:halted absent"
      else
        nope "ENG-58 L (D-011): chained scope-approved → resume bypass" \
          "exit=$exit_code wait=$wait_present skip_remove=$skip_remove halt_remove=$halt_remove"
      fi
      _eng58_clear_side_state "ENG-991"

      # ─── ENG-58 Case M (D-012): scope-approved + wait-build.json →
      #     stderr advisory mentions wait-*.json ──────────────────────────
      : > "$LINEAR_CALLS"
      mkdir -p "$PROJECT_STATE_DIR/ENG-992"
      printf '{}' > "$PROJECT_STATE_DIR/ENG-992/wait-build.json"
      stderr_capture="$(LABELS_ON="pipeline:halted" VH_RC=99 STAGE_OF="stage:building" \
        resolve "ENG-992" "scope-approved" 2>&1 >/dev/null || true)"
      wait_present=0; [[ -e "$PROJECT_STATE_DIR/ENG-992/wait-build.json" ]] && wait_present=1
      if [[ "$wait_present" == "1" && "$stderr_capture" == *"wait-*.json"* ]]; then
        ok "ENG-58 M (D-012): scope-approved advisory mentions wait-*.json without clearing"
      else
        nope "ENG-58 M (D-012): scope-approved advisory" \
          "wait=$wait_present advisory='$stderr_capture'"
      fi
      _eng58_clear_side_state "ENG-992"

      # ─── ENG-58 Case N (D-013): metrics.sh halt-resume captures stats ──
      : > "$LINEAR_CALLS"; : > "$METRICS_CALLS"
      _eng58_seed_side_state "ENG-993" skip-until-human-acts
      LABELS_ON="pipeline:halted,pipeline:skip-until-human-acts" \
        VH_RC=1 STAGE_OF="stage:building" \
        resolve "ENG-993" "resume" >/dev/null 2>&1 || true
      metric_line="$(grep "^halt-resume ENG-993 building atomic-reset 0 " "$METRICS_CALLS" | head -1)"
      if [[ "$metric_line" == *"wait_files=1"* \
            && "$metric_line" == *"skip_labels=1"* \
            && "$metric_line" == *"state_file=true"* \
            && "$metric_line" == *"waypoint_posted=1"* ]]; then
        ok "ENG-58 N (D-013): metrics.sh halt-resume captures full stats"
      else
        nope "ENG-58 N (D-013): metrics emission" "line='$metric_line'"
      fi
      _eng58_clear_side_state "ENG-993"

      # ─── ENG-58 Case O (D-014): invalid issue id → die before any FS or
      #     Linear write ────────────────────────────────────────────────
      : > "$LINEAR_CALLS"
      exit_code=0
      ( resolve "ENG-../../etc" "resume" >/dev/null 2>&1 ) || exit_code=$?
      remove_count="$(grep -c "^remove-label" "$LINEAR_CALLS" || true)"
      if [[ "$exit_code" -ne 0 && "$remove_count" == "0" ]]; then
        ok "ENG-58 O (D-014): path-traversal issue id rejected before any write"
      else
        nope "ENG-58 O (D-014): issue-id validation" \
          "exit=$exit_code remove_count=$remove_count"
      fi

      # ─── ENG-58 Case P (D-014): malformed stage label → sanitized to
      #     'unknown' in operator-resume body ────────────────────────────
      : > "$LINEAR_CALLS"
      LABELS_ON="pipeline:halted" VH_RC=1 STAGE_OF="stage:foo%s" \
        resolve "ENG-994" "resume" >/dev/null 2>&1 || true
      sanitized="$(grep -c "<!-- pipeline-transition: unknown → unknown (operator-resume) -->" "$LINEAR_CALLS" || true)"
      if [[ "$sanitized" -ge "1" ]]; then
        ok "ENG-58 P (D-014): stage-shape sanitized to 'unknown' on malformed label"
      else
        nope "ENG-58 P (D-014): stage sanitization" \
          "no operator-resume waypoint with 'unknown → unknown' found"
      fi
      _eng58_clear_side_state "ENG-994"

      # ─── ENG-58 Case Q (corrupt JSON guard): issue-state.json with
      #     invalid JSON is PRESERVED (jq -e . guard short-circuits).
      #     Brainstorm §5: "issue-state.json corrupt → file preserved
      #     (operator can investigate)."
      : > "$LINEAR_CALLS"
      mkdir -p "$PROJECT_STATE_DIR/ENG-995"
      printf 'this is not valid json\n' > "$PROJECT_STATE_DIR/ENG-995/issue-state.json"
      LABELS_ON="pipeline:halted" VH_RC=1 STAGE_OF="stage:building" \
        resolve "ENG-995" "resume" >/dev/null 2>&1 || true
      state_present=0; [[ -e "$PROJECT_STATE_DIR/ENG-995/issue-state.json" ]] && state_present=1
      if [[ "$state_present" == "1" ]]; then
        ok "ENG-58 Q (corrupt JSON): issue-state.json preserved when jq -e . fails"
      else
        nope "ENG-58 Q: corrupt-JSON guard" \
          "state file removed despite invalid JSON (operator loses investigation evidence)"
      fi
      _eng58_clear_side_state "ENG-995"

      # ─── ENG-58 Case R (PIPELINE_DRY_RUN): dry-run still removes local
      #     filesystem state but suppresses Linear writes. This is the
      #     existing halt.sh contract (brainstorm §6) — locking it as a
      #     test prevents an accidental future change to make dry-run
      #     fully read-only on FS too (which would silently change the
      #     operator's preview-vs-real semantics).
      : > "$LINEAR_CALLS"; : > "$METRICS_CALLS"
      _eng58_seed_side_state "ENG-996" skip-until-human-acts
      LABELS_ON="pipeline:halted,pipeline:skip-until-human-acts" \
        VH_RC=1 STAGE_OF="stage:building" PIPELINE_DRY_RUN=1 \
        resolve "ENG-996" "resume" >/dev/null 2>&1 || true
      wait_present=0; [[ -e "$PROJECT_STATE_DIR/ENG-996/wait-build.json" ]] && wait_present=1
      state_present=0; [[ -e "$PROJECT_STATE_DIR/ENG-996/issue-state.json" ]] && state_present=1
      if [[ "$wait_present" == "0" && "$state_present" == "0" ]]; then
        ok "ENG-58 R (dry-run): local FS cleanup runs under PIPELINE_DRY_RUN=1"
      else
        nope "ENG-58 R: dry-run FS contract" \
          "wait=$wait_present state=$state_present (expected both 0; brainstorm §6 says FS ops execute even in dry-run)"
      fi
      _eng58_clear_side_state "ENG-996"
      ```

- [ ] Run `bash bin/halt-test.sh` — must exit 0 with PASS lines for the
      existing four cases (A–D, updated to set `LABELS_ON`) PLUS
      fourteen new cases (E–R). The RESULTS line should read
      `RESULTS: 18 passed, 0 failed`.
- [ ] Run `bash bin/halt-sprawl-test.sh` — must remain green (this test
      exercises `_poll_emit_halt_sprawl_alert` in `poll.sh`, not
      `halt.sh`; A-024). No assertion changes here.
- [ ] Run `bash bin/verdict-handler-test.sh` — must remain green (no
      verdict-handler modifications in this plan).

### Task 4: Update `CLAUDE.md` Failure-mode quick reference

- `depends_on: []`
- `touches: CLAUDE.md (line 294 row + new subsection below the table)`

- [ ] In `CLAUDE.md`, REPLACE the existing `Kill switch` row at line 294:

      ```
      | Kill switch | `bash bin/halt.sh resolve …` or set `orchestrator.paused=true` (takes effect next tick) |
      ```

      with a slightly tightened row:

      ```
      | Kill switch | `bash bin/halt.sh resolve <ENG-N> --decision resume` (atomic reset, see below) or set `orchestrator.paused=true` (takes effect next tick) |
      ```

- [ ] APPEND a new subsection below the Failure-mode quick reference
      table (after the table closes, before the next `## …` heading or
      EOF). Use this exact wording from brainstorm §3.5:

      ```markdown

      **What `--decision resume` clears (atomic, ENG-58):**

      1. `pipeline:halted` label
      2. `pipeline:skip-until-code-changes` and `pipeline:skip-until-human-acts` labels
      3. `$PROJECT_STATE_DIR/<ident>/wait-*.json` files
      4. `$PROJECT_STATE_DIR/<ident>/issue-state.json` IFF its `.policy == "skip-until-human-acts"`
      5. Posts a `<!-- pipeline-transition: <stage> → <stage> (operator-resume) -->` waypoint to reset `count_marker_since_last_transition` (rejection counter) and `find_fresh_verdict` freshness.

      `--decision scope-approved` / `--decision scope-rejected` are the
      NARROWER paths (they post the decision marker AND remove
      `pipeline:halted` — i.e., they DO clear item 1 — but they do NOT
      clear items (2)-(5) because scope-deviation halts don't accrue
      that side state). If stale state from an unrelated earlier
      failure coexists, halt.sh emits a one-line stderr advisory
      pointing the operator to the resume path.

      **Chained flow:** if an issue is halted for both a scope deviation
      AND a separate failure (e.g., budget exhaustion left a `wait-build.json`
      behind), run `--decision scope-approved` first, then run
      `--decision resume` to clear the residual side state. The second
      command is the documented chained step — D-011's `has-label
      pipeline:halted` guard makes this safe even though the halt label
      was already removed by the first command.

      **Idempotent — safe to re-run.** If `halt.sh resolve` errors mid-flow
      (network blip on a Linear write), re-running the same command picks
      up from where it left off. Every operation (remove-label, rm -f,
      add-comment) is idempotent; the operator-resume waypoint is posted
      LAST so a partial-failure leaves the issue in a re-runnable state
      (the halt label remains observable in Linear, prompting the operator
      to retry).
      ```

- [ ] Verify the Markdown renders cleanly: `cat CLAUDE.md | head -310 |
      tail -30` shows the row + subsection in expected order. (No
      automated lint for CLAUDE.md in this repo.)

---

## Frontend Tasks

**No frontend tasks.** The harness has no UI/frontend surface — it is
bash orchestration scripts (verified at
`learned-rules/harness/project-profile.md` Stack section: "Bash 3.2+
orchestration scripts (macOS-compatible). The repo contains no
application code …"). The "UI Agent" stage in the pipeline is a
pass-through for harness-self dispatches per `AGENT_PROMPTS.md §4`.

---

## Failure Mode → Test Map

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
|---|---|---|---|---|
| Resume against an issue with `policy=skip-until-human-acts` leaves `wait-*.json` and `issue-state.json` behind → next tick re-halts (the ENG-58 root cause) | Operator runs `halt.sh resolve --decision resume` after a budget-exhausted build halt | All side state cleared; `find_fresh_verdict` empty; rejection counters return 0 (operator-resume waypoint is the new transition boundary) | unit | `bin/halt-test.sh` Case E (ENG-58 E) |
| `vh_rc=0` (forward verdict exists) — cleanup must still run, but no operator-resume waypoint (apply_transition's own waypoint is the boundary) | Stub `VH_RC=0`, halt label present, side state seeded | Side state removed; `LINEAR_CALLS` contains NO `operator-resume` substring | unit | `bin/halt-test.sh` Case F |
| `vh_rc=2` (protocol violation) — must NOT cleanup, NOT remove halt label, must exit non-zero | Stub `VH_RC=2`, halt label present, side state seeded | All state preserved; `pipeline:halted` not removed; resolve exits non-zero | unit | `bin/halt-test.sh` Case G |
| `scope-approved` accidentally clears side state from an unrelated prior failure (would break `_replay_scope_approval`) | Operator runs `--decision scope-approved` with stale `wait-*.json` + `pipeline:skip-until-*` coexisting | Side state preserved; `pipeline:halted` removed; stderr advisory listing the stale state | unit | `bin/halt-test.sh` Case H + Case M (advisory phrasing) |
| `policy=skip-until-code-changes` evidence trail accidentally deleted by halt.sh, breaking `_poll_evaluate_skip` auto-resume | Resume on issue with `policy=skip-until-code-changes` | `issue-state.json` PRESERVED (D-006 conditional) | unit | `bin/halt-test.sh` Case I |
| Operator runs resume twice in quick succession → second invocation crashes or double-mutates | Two consecutive resume calls on the same issue | Both calls return rc=0; metrics.sh records two `halt-resume` events; idempotent at the halt.sh layer | unit | `bin/halt-test.sh` Case J |
| Stale `<!-- pipeline-metric: review_rejection -->` markers older than the halt re-trip the rejection counter on the next dispatch (the ENG-24 reproduction) | Multiple stale rejection markers exist before halt; resume runs | Operator-resume waypoint body matches the `contains("<!-- pipeline-transition:")` boundary used by `bin/guards.sh:46-48` and `bin/verdict-handler.sh:75-78`; both readers see zero markers newer than the boundary | unit | `bin/halt-test.sh` Case K (regression) |
| Chained `scope-approved → resume` fires `_vh_protocol_violation` which re-applies `pipeline:halted`, silently re-installing the very state the operator just cleared (D-011 trap) | Issue has no halt label (just cleared by scope-approved), `--decision resume` invoked | `verdict_handler` is NOT called; cleanup runs; halt label not toggled; rc=0 | unit | `bin/halt-test.sh` Case L |
| `metrics.sh halt-resume` event missing → retrospective cannot detect re-halt regression patterns (D-013) | Resume runs through cleanup path | `events.jsonl` line containing `event=halt-resume issue=ENG-N stage=… outcome=atomic-reset notes='wait_files=N skip_labels=M state_file=B waypoint_posted=B'` | unit | `bin/halt-test.sh` Case N |
| Path-traversal via `ENG-../../etc/passwd_dir` arg → `rm -f` writes outside `$PROJECT_STATE_DIR` (D-014 Security P1) | `halt.sh resolve "ENG-../../etc" --decision resume` | Resolve dies before any FS or Linear write; no `remove-label` calls | unit | `bin/halt-test.sh` Case O |
| `printf %s`-consumption on stage-name interpolation via crafted Linear stage label (D-014 Security P2) | `stage-of` returns `stage:foo%s` | `current_stage` sanitized to `unknown`; waypoint body literal contains `unknown → unknown`; no format-string corruption | unit | `bin/halt-test.sh` Case P |
| Corrupt `issue-state.json` (invalid JSON) silently deleted, losing the operator's investigation evidence (brainstorm §5 contract) | `issue-state.json` contains `not valid json`; resume runs | File PRESERVED (jq -e . guard short-circuits); operator can investigate the corruption | unit | `bin/halt-test.sh` Case Q |
| `PIPELINE_DRY_RUN=1` accidentally promoted to suppress filesystem cleanup → operator's preview-vs-real semantics silently change | Resume runs under `PIPELINE_DRY_RUN=1` with seeded side state | Local FS cleanup STILL executes (matching brainstorm §6 + existing halt.sh dry-run contract); only Linear writes are suppressed | unit | `bin/halt-test.sh` Case R |
| `_post_dispatch_apply_halt` re-applies `pipeline:halted` after halt.sh resume because the orchestrator runs concurrently | A tick fires while halt.sh mid-cleanup (race window <1s) | Mitigated by global `.claude-mutex.lock/` mutex around dispatch (`bin/common.sh:159-167`); halt.sh runs in <1s; tick window is 5min — race window negligible. Documented in brainstorm §5; not test-locked | n/a | (documented; not test-locked — operator-CLI vs orchestrator-tick race window) |
| `add-comment` dedup at `bin/linear.sh:455-487` suppresses the operator-resume waypoint when an identical body was posted within the last 10 comments | Operator runs resume twice in <10 comments span | Second post suppressed by dedup hash; freshness boundary from first post still in place; semantically correct | n/a | (documented in §3.4 case J compatibility note; the test stub does not replicate dedup so the LINEAR_CALLS log shows both attempts — the assertion is on call attempt count, not API call count) |
| `halt-sprawl-test.sh` regresses because `_poll_emit_halt_sprawl_alert` semantics depend on halt-comment surface | Test author misreads "halt-sprawl" as "halt"; modifies poll.sh logic | `bin/halt-sprawl-test.sh` exits non-zero on the existing 11 cases. Plan does NOT modify `bin/poll.sh` so the test stays green by construction | unit | `bin/halt-sprawl-test.sh` (existing — runs as part of Task 3's verify-after) |

The last three rows (race window, dedup compat, halt-sprawl regression
backstop) are intentionally documentation/regression-backstop only.
The first thirteen rows correspond 1:1 to the test cases E–R (E + F + G
+ H + I + J + K + L + M + N + O + P + Q + R = 14 cases covering 13
failure modes — Case H pairs with Case M for the scope-approved+advisory
pair).

## Test Strategy

- **Unit (locked invariants).** Fourteen new test cases (E–R) in
  `bin/halt-test.sh` (Task 3) cover every brainstorm decision that
  affects observable behavior:
  - D-002 / D-003 / D-004 / D-008 atomic ordering: cases E, F, G
  - D-005 wait-file glob: cases E, F (wait_present assertions)
  - D-006 conditional issue-state.json: cases E (delete), I (preserve)
  - D-007 wholesale skip-label removal: cases E, L (skip_remove count)
  - D-009 scope-approved narrower path: cases H, M
  - D-011 has-label guard around verdict_handler: case L
  - D-012 stderr advisory: cases H, M
  - D-013 metrics emission: cases J, N
  - D-014 issue-id + stage-shape validation: cases O, P
  - ENG-24 rejection-counter regression (AC-2): case K
  - Brainstorm §5 corrupt-JSON guard: case Q
  - Brainstorm §6 PIPELINE_DRY_RUN FS-vs-Linear contract: case R

  The existing four cases (A, B, C, D) at `bin/halt-test.sh:52-86` are
  updated in Task 3 to set `LABELS_ON="pipeline:halted"`; this is
  required by the new D-011 short-circuit so the cases continue to
  exercise the verdict-handler-call layer they were originally written
  to test. Without the `LABELS_ON` injection, Case B (`VH_RC=1` →
  `remove-label pipeline:halted` count == 1) would fail because the
  D-011 guard would skip the `verdict_handler` call entirely and
  `had_halt=0` would short-circuit the `remove-label` call.

- **Unit (sibling regression backstop).** `bin/halt-sprawl-test.sh`
  must continue to pass — it exercises `_poll_emit_halt_sprawl_alert`
  in `poll.sh`, which this plan does NOT touch. Listed as a verify-
  after step at Task 3.

  `bin/verdict-handler-test.sh` similarly must continue to pass — no
  verdict-handler modifications in this plan.

- **Syntax (interpreted-bash gate).** `bash -n bin/halt.sh` after
  Tasks 1 and 2 confirms the helper additions and `resolve()` flow
  rewrite parse cleanly. Listed as a project-profile lint gate at
  `learned-rules/harness/project-profile.md` "Lint/check" row.

- **Secret-handling lint (ENG-46).** `bash bin/secret-probe-lint.sh`
  after Task 2 confirms no new `${VAR:-FALLBACK}` or `${VAR:+ALTERNATE}`
  patterns against `*KEY|*TOKEN|*SECRET|ANTHROPIC*|GITHUB*|LINEAR*`-named
  env vars. The new helpers and resolve() rewrite use no such patterns
  (verified at design time in A-027).

- **Integration / smoke.** `PIPELINE_DRY_RUN=1 TARGET_REPO=… bash
  bin/halt.sh resolve ENG-XX --decision resume` against a synthetic
  test issue should:
  1. Print decision marker post (suppressed in dry-run; logged to stderr)
  2. Print would-remove-label messages for any labels present
  3. Print the local rm operations actually executing (dry-run does NOT
     suppress filesystem ops — A-018 bin/common.sh PIPELINE_DRY_RUN
     export only suppresses Linear mutations)
  4. Print would-comment for the operator-resume waypoint
  5. Exit 0
  This is a smoke verification (no new automated test); the unit tests
  cover the same code paths with stubbed Linear.

- **Adversarial.** Cases O (path-traversal) and P (`%s`-consumption)
  in Task 3 are adversarial-equivalent for the only two security
  surfaces this plan introduces (string interpolation into FS paths
  and printf bodies). No additional adversarial test file warranted —
  `bin/halt-sprawl-adversarial-test.sh` exists for `poll.sh`'s
  halt-sprawl predicate and is unrelated.

- **Coverage map.** Failure-Mode rows 1-11 are unit-test-locked in
  `bin/halt-test.sh` cases E-P. Rows 12 (race window), 13 (dedup
  compat), 14 (halt-sprawl regression backstop) are
  documentation/manual-review verified. Total automated coverage: 12
  new assertions in halt-test.sh + 2 existing tests reused as
  regression backstops (halt-sprawl-test.sh, verdict-handler-test.sh).
