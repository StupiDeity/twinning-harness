---
linear: ENG-61
date: 2026-05-03
topic: parse_pipeline_marker prose-quote hardening + _fresh_wait_reason wait-shadow fix
---

# Plan — ENG-61 verdict-handler parser hardening + wait-shadow fix

> **For agentic workers:** REQUIRED SUB-SKILL — use
> `superpowers:subagent-driven-development` (recommended) or
> `superpowers:executing-plans` to walk this task-by-task. Steps use
> `- [ ]` for tracking.

Implementation plan for the design in
`docs/brainstorms/2026-05-03-eng-61-verdict-handler-harden-parse-pipeline-marker-against-prose-quoted-markers-fix-fresh-wait-reason-wait-shadows-newer-verdict-trap-design.md`.

## Anti-anchoring

- **Problem (operator's words):** when an issue's stage-summary or plan
  body discusses the marker protocol — quoting `<!-- pipeline: ... -->`
  inside backticks or fenced blocks — the orchestrator's marker parser
  treats those quoted strings as real state-driving events. This pushes
  the freshness floor past every legitimate marker and emits
  `pipeline-halt: protocol-violation` against perfectly valid issues
  (Bug A). Independently, when the build-stage soft-pause gate sees a
  newer non-wait verdict (e.g. a post-merge `verdict pass building`),
  it ignores it and keeps returning the old wait reason — so build
  spins on the wait until an operator manually flips labels (Bug B).
  The brainstorm cites \~$50 of wasted spend in the 2026-05-02
  observation session and lists ENG-58, ENG-52 as concrete victims.
- **Does the brainstorm address it?** Yes. D-001/D-002 fix Bug A
  centrally inside `parse_pipeline_marker` via a private
  `_strip_code_blocks_and_spans` helper that removes triple-backtick
  fences, single-backtick spans, and (best-effort, multi-line bodies
  only) 4-space-indented blocks before the grep. D-003 fixes Bug B
  by changing `_fresh_wait_reason`'s second loop to track the latest
  verdict of *any* result and return the wait reason iff the latest
  verdict is itself a wait. D-005 keeps tests in the per-module
  sibling files. D-004 makes pivot-result symmetry implicit (no enum
  enumeration). The fixes match the brainstorm's "is the latest
  verdict still a wait?" framing of the function's intended
  semantics.
- **Proportional?** Yes. Two surgical edits to two existing functions
  + 8 new test fixtures across two existing test files (P13, P14,
  P14b, P15, P16 in `bin/common-test.sh`; WS1, WS2, WS3 in
  `bin/run-stage-test.sh`). No new files, no new env vars, no new
  state, no new Linear writes, no new agent-prompt requirements, no
  exit-code taxonomy changes, no trust-lane changes. The brainstorm
  explicitly rejected wider alternatives (jq-side strip, markdown
  parser, refactoring three call sites to preserve newlines, parallel
  cursors in `_fresh_wait_reason`, auto-emit transitions on
  wait-supersede, separate test file).
- **No escalation needed.**

## Goal

Make the orchestrator's marker discovery path immune to (1) prose-
quoted marker syntax in Linear comment bodies and (2) wait verdicts
that have been superseded by a newer non-wait verdict — verifiable
via `bash bin/common-test.sh && bash bin/run-stage-test.sh && bash
bin/verdict-handler-test.sh && bash bin/scope-check-test.sh && bash
-n bin/common.sh && bash -n bin/run-stage.sh` exiting 0 with the new
fixtures (P13, P14, P14b, P15, P16, WS1, WS2, WS3) in PASS state and
existing fixtures (P1–P12, WR1–WR3, MEA1, ENG-56-A through ENG-56-I,
all `find_fresh_verdict` and `has_scope_approval` cases) unchanged.

## Architecture

This work is additive to two existing functions in two existing
modules and their sibling test files. Per the brainstorm §3:

```
bin/common.sh
  ├─ _strip_code_blocks_and_spans (NEW, private; called by parse_pipeline_marker)
  └─ parse_pipeline_marker         (MODIFIED — pre-strips body before grep)

bin/run-stage.sh
  └─ _fresh_wait_reason            (MODIFIED — second loop tracks latest verdict
                                    of any result, returns wait reason iff latest
                                    is wait)

bin/common-test.sh                 (APPEND fixtures P13, P14, P14b, P15, P16)
bin/run-stage-test.sh              (APPEND fixtures WS1, WS2, WS3)
```

No changes to `bin/verdict-handler.sh::find_fresh_verdict`,
`bin/scope-check.sh::has_scope_approval`, or `bin/pipeline.sh::cmd_status`
— all three call `parse_pipeline_marker` and inherit Bug A's fix
transparently. No changes to `bin/pipeline-events.json`,
`docs/pipeline-vocabulary.md`, `AGENT_PROMPTS.md`, or
`learned-rules/`.

There is no `docs/VISION.md`, no `docs/knowledge/decisions.md`, no
`SYSTEM_ARCHITECTURE.md` in this repo (verified: `ls docs/` returns
`brainstorms/  pipeline-vocabulary.md  pipeline-vocabulary.template.md
plans/  runbooks/`). Governing constraints come from `CLAUDE.md` and
`learned-rules/harness/project-profile.md`. The relevant learned-rules
file `learned-rules/harness/plan.md` does not exist (verified: `ls
learned-rules/harness/` returns `project-profile.md` only).

## Tech stack

- Bash 3.2+ (Darwin default, harness target). The strip helper uses
  `[[ "$body" =~ ... ]]` + `BASH_REMATCH[0]` + `${var//pat/repl}`,
  all of which are supported in Bash 3.2 per A14 in the brainstorm.
- BSD `awk` (macOS default) for the indented-block strip; verified to
  support `!/regex/` action and herestring input per A18.
- `jq` for the existing reason-field projections in
  `_fresh_wait_reason`'s second loop.
- No new dependencies. No `dispatch.sh::allowed_tools_for` cases
  added (parser is read-side helper, not agent-dispatched).

## Assumption Inventory

Every modified-file fact below is `path:line`-cited against the
current worktree per ENG-5 P-002 / B-001. Assumptions marked
`assumed/new` identify the file where the artifact will be created.
Every entry below was verified against the live tree on 2026-05-03
and re-cross-checked against the brainstorm's §8.4 codebase-fact
table.

### Modified files — current signatures and call sites

- **A-001 — `bin/common.sh::parse_pipeline_marker` exists at
  `bin/common.sh:141-171`.** Verified. Current body (lines 141-146):

      parse_pipeline_marker() {
        local body="$1"
        local marker
      
        # New shape: `<!-- pipeline: <event> [k=v ...] -->`
        marker="$(grep -oE '<!-- pipeline: [^>]+ -->' <<<"$body" 2>/dev/null | tail -1 || true)"

  Lines 147-167 then parse `event` + `k=v` pairs and emit JSON.
  Plan inserts a single new line — `body="$(_strip_code_blocks_and_spans "$body")"` —
  immediately after `local marker` (between current line 143 and line 145).
  No signature change; no return-shape change.

- **A-002 — `parse_pipeline_marker` is exported via `export -f`** at
  `bin/common.sh:204`. Verified. The new private helper is NOT added
  to that line — staying unexported per F-3 lane discipline (ENG-41)
  and brainstorm Q-4.

- **A-003 — `bin/run-stage.sh::_fresh_wait_reason` exists at
  `bin/run-stage.sh:298-341`** with a building-only stage gate at
  lines 300-303 and the second wait-only loop at lines 320-333.
  Verified. The second loop's current body (lines 322-333):

      while IFS=$'\t' read -r ts body; do
        [[ -n "$last_t" && ! "$ts" > "$last_t" ]] && continue
        ev="$(parse_pipeline_marker "$body" 2>/dev/null || true)"
        [[ -z "$ev" ]] && continue
        [[ "$(jq -r '.event' <<<"$ev")" != "verdict" ]] && continue
        [[ "$(jq -r '.result' <<<"$ev")" != "wait" ]] && continue
        if [[ "$ts" > "$fresh_ts" ]]; then
          fresh_ts="$ts"
          fresh_reason="$(jq -r '.reason' <<<"$ev")"
        fi
      done < <(jq -r '.[] | "\(.createdAt)\t\(.body | gsub("\n"; " "))"' <<<"$comments")

  Plan replaces the `[[ ... .result == "wait" ]] && continue` line
  and the body of the `if [[ "$ts" > ... ]]` block per D-003: track
  latest verdict of *any* result; record `.result` and `.reason`
  unconditionally; after the loop, return wait reason iff
  `fresh_result == "wait"`. The post-loop reason allow-list at
  lines 337-340 is preserved verbatim.

- **A-004 — `_fresh_wait_reason` callers** are
  `bin/run-stage.sh::_post_dispatch_apply_halt` at lines 357-369 and
  the build-stage main path at the early-exit referenced from
  brainstorm §1.2 (`bin/run-stage.sh:698-737`, `:749`). Verified.
  Both treat rc=0 as "wait detected, soft-pause" and rc=1 as
  "fall through to verdict_handler" — the contract D-003 preserves.
  Plan does NOT touch either caller.

- **A-005 — `bin/common-test.sh` parse_pipeline_marker group lives
  at `bin/common-test.sh:248-276`.** Verified — the existing
  `pass_at` / `fail_at` helper definitions are at lines 237-246; the
  `--- parse_pipeline_marker ---` heading is at line 250; fixtures
  P1, P2, P3, P11, P12 occupy lines 252-276; the summary footer is
  at lines 278-284. Plan APPENDS new fixtures P13, P14, P14b, P15,
  P16 between the existing P12 (line 276) and the summary footer
  (line 278). Existing P1–P12 stay unchanged.

- **A-006 — `bin/run-stage-test.sh` _fresh_wait_reason new-shape
  group lives at `bin/run-stage-test.sh:2175-2210`.** Verified —
  group heading at line 2175; fixtures WR1, WR2, WR3 at lines
  2179-2210; final summary echo at lines 2212-2214. Plan APPENDS new
  fixtures WS1, WS2, WS3 between the existing WR3 (line 2210) and
  the summary echo (line 2212). Existing WR1–WR3 stay unchanged.

- **A-007 — `bin/run-stage-test.sh` overrides `SCRIPT_DIR` to
  `STUB_DIR` for `_fresh_wait_reason` tests.** Verified at
  `bin/run-stage-test.sh:2189`: `SCRIPT_DIR="$STUB_DIR"`. The new
  WS fixtures reuse this same override pattern by re-rendering
  `$STUB_DIR/linear.sh` with the new `COMMENTS_JSON` payload (same
  shape as WR1's stub at lines 2185-2188).

### Read-only callees / state shapes — verified, not modified

- **A-008 — `bin/verdict-handler.sh::find_fresh_verdict` at
  `bin/verdict-handler.sh:85-144`** calls `parse_pipeline_marker`
  inline at lines 97 and 110 after a `gsub("\n"; " ")` collapse at
  lines 102 and 118. Verified. Inherits the parser fix transparently;
  the wait-exclusion at line 114 is unchanged.

- **A-009 — `bin/scope-check.sh::has_scope_approval` at
  `bin/scope-check.sh:105-143`** calls `parse_pipeline_marker` after
  the same `gsub("\n"; " ")` collapse at lines 127 and 140. Verified.
  Inherits the parser fix transparently.

- **A-010 — `bin/pipeline.sh::cmd_status` at `bin/pipeline.sh:43-59`**
  calls `parse_pipeline_marker` at line 55 after the same gsub
  collapse at line 58. Verified. Inherits the parser fix
  transparently.

- **A-011 — `bin/common.sh::parse_pipeline_marker`'s call sites all
  pre-collapse newlines via `jq gsub("\n"; " ")`** before passing
  the body. Verified (all call sites listed above). Direct callers
  bypassing the collapse — e.g. fixture P14b — exercise the helper's
  multi-line code path.

- **A-012 — Pipeline-event registry admits results
  `pass|fail|halt|wait|pivot`** per `docs/pipeline-vocabulary.md:38-44`
  and `bin/pipeline-events.json`. Verified. D-004 reasoning: the
  D-003 sketch returns empty whenever `fresh_result != "wait"`, so
  pivot is treated identically to pass/fail/halt without any explicit
  enum check — exactly the right thing per the brainstorm.

- **A-013 — Wait reason allow-list is `awaiting-approval|awaiting-ci`**
  at `bin/run-stage.sh:337-340` and `docs/pipeline-vocabulary.md:56-59`.
  Verified. The post-loop `case "$fresh_reason"` filter is preserved
  verbatim by D-003; no allow-list change.

- **A-014 — Bash 3.2+ supports `[[ "$body" =~ ... ]]`,
  `BASH_REMATCH[0]`, and `${var//pat/repl}` global-replace.**
  Verified per brainstorm A14; macOS Bash 3.2 ships with all three.

- **A-015 — BSD `awk` (macOS default) supports `!/regex/` action
  and herestring (`<<<`) input.** Verified per brainstorm A18 by
  inspection of existing usages in `bin/run-stage-test.sh:67, :107`.

- **A-016 — `${var//pat/repl}` treats `pat` as a glob.** Per
  brainstorm A15 this is correctness-only (not a trust-lane
  regression). Mitigation: the strip loop replaces the literal
  matched span (`${BASH_REMATCH[0]}`) which, for our backtick-fenced
  inputs, contains backticks, alphanumerics, whitespace, punctuation —
  no glob metacharacters in any observed Linear body or the four
  named fixtures. The brainstorm's §12 sed fallback is the
  documented contingency if a pathological body surfaces post-deploy:

      body="$(printf '%s' "$body" | sed -E 's/`{3}[^`]*`{3}//g; s/`[^`]*`//g')"

  Plan implements the BASH_REMATCH form by default per the
  brainstorm sketch; the sed fallback is documented inline in a
  comment for future maintainers.

- **A-017 — The `awk '!/^( {4,}|\t)/' <<<"$body"` filter is a
  sufficient approximation of CommonMark indented-code-block rules
  for harness purposes.** Verified per brainstorm A17: AGENT_PROMPTS.md
  emits markers via `bin/pipeline.sh` which writes raw HTML comments
  unindented; agent contract is column-0. Over-strip is benign.

- **A-018 — The strip helper is invisible at the public-export
  surface.** `parse_pipeline_marker` is exported at
  `bin/common.sh:204`; `_strip_code_blocks_and_spans` is NOT exported.
  Same-file private helper accessed via lexical scope. Per brainstorm
  Q-4: no need to export.

- **A-019 — Pre-existing tests cover P1–P12, WR1–WR3, ENG-56-A
  through ENG-56-I, MEA1, every `find_fresh_verdict` case, every
  `has_scope_approval` case.** Verified by reading
  `bin/common-test.sh:248-276`, `bin/run-stage-test.sh:2105-2173`,
  `bin/run-stage-test.sh:2175-2210`, plus existing
  `bin/verdict-handler-test.sh` and `bin/scope-check-test.sh`. The
  plan's regression contract is "all existing fixtures continue to
  pass after the helper insertion in `parse_pipeline_marker`."

### Assumed/new artifacts

- **A-N1 — `_strip_code_blocks_and_spans` private helper is NEW** in
  `bin/common.sh`. Will live immediately above the existing
  `parse_pipeline_marker` definition (between current line 121 and
  line 122 — i.e. inside the existing `# ─── Pipeline-marker parser
  (ENG-60) ───` section header so the section comment introduces both
  the public parser and its private pre-stripper). Three-step body
  per brainstorm D-002 sketch. Returns the stripped body on stdout.
  Logs nothing. Same-file lexical access; no `export -f`.

- **A-N2 — Test fixtures P13, P14, P14b, P15, P16 are NEW** in
  `bin/common-test.sh`. Appended after the existing P12 at line 276,
  before the summary footer at line 278. Each fixture follows the
  existing `result="$(parse_pipeline_marker "...")" / [[ "$(jq -r
  '.field' <<<"$result")" == "expected" ]] && pass_at "..." ||
  fail_at "..."` pattern (see P11 at lines 269-271 for the
  multi-line-body precedent).

- **A-N3 — Test fixtures WS1, WS2, WS3 are NEW** in
  `bin/run-stage-test.sh`. Appended after the existing WR3 at line
  2210, before the summary echo at line 2212. Each fixture follows
  the existing WR* pattern: re-write `$STUB_DIR/linear.sh` with a
  new `COMMENTS_JSON` payload, call `_fresh_wait_reason ENG-WSN
  building`, assert stdout / rc.

## File Structure

- `bin/common.sh` — MODIFIED. Insert `_strip_code_blocks_and_spans`
  helper (NEW; ~20 lines) immediately above current line 141; add
  one line inside `parse_pipeline_marker` to call it before the
  grep.
- `bin/run-stage.sh` — MODIFIED. Replace the second loop body in
  `_fresh_wait_reason` (current lines 320-333) so it tracks latest
  verdict of any result; add post-loop guard `[[ "$fresh_result" !=
  "wait" ]] && return 1` before the existing reason allow-list at
  lines 337-340.
- `bin/common-test.sh` — MODIFIED. Append fixtures P13, P14, P14b,
  P15, P16 between current line 276 (end of P12) and line 278
  (summary footer).
- `bin/run-stage-test.sh` — MODIFIED. Append fixtures WS1, WS2, WS3
  between current line 2210 (end of WR3) and line 2212 (summary
  echo).

No new files. No deleted files.

## API Contract

no new API surface — this ticket modifies a private helper
(`parse_pipeline_marker`) and a private function (`_fresh_wait_reason`);
neither is part of an FE↔BE contract. The harness has no FE↔BE
surface; all I/O is shell + Linear GraphQL.

## Backend Tasks

### Task 1: Add `_strip_code_blocks_and_spans` private helper to `bin/common.sh`

- `depends_on: []`
- `touches: bin/common.sh::_strip_code_blocks_and_spans (NEW)`
- [ ] Insert a new function definition in `bin/common.sh` between
  current line 121 (closing `}` of `failure_outcome_for_exit`) and
  current line 122 (`# ─── Pipeline-marker parser (ENG-60) ─` header).
  Place inside the same section so the comment introduces both the
  public parser and the private stripper. Body per brainstorm D-002:

      _strip_code_blocks_and_spans() {
        local body="$1"
        # Step 1 (multi-line bodies only): strip 4-space-indented blocks.
        # No-op for the three current production callers (run-stage.sh,
        # verdict-handler.sh, scope-check.sh, pipeline.sh) which pre-collapse
        # newlines via jq gsub("\n"; " ") before passing the body. Activates
        # for direct callers (tests, future call sites that preserve newlines).
        # Markers are written at column 0 by contract (AGENT_PROMPTS.md), so
        # over-stripping indented lines is benign.
        if [[ "$body" == *$'\n'* ]]; then
          body="$(awk '!/^( {4,}|\t)/' <<<"$body")"
        fi
        # Collapse newlines to spaces so the regex steps below can scan
        # in a single pass.
        body="${body//$'\n'/ }"
        # Step 2: triple-backtick fenced regions (works in collapsed form).
        while [[ "$body" =~ \`\`\`[^\`]*\`\`\` ]]; do
          body="${body//${BASH_REMATCH[0]}/ }"
        done
        # Step 3: single-backtick code spans.
        while [[ "$body" =~ \`[^\`]*\` ]]; do
          body="${body//${BASH_REMATCH[0]}/ }"
        done
        printf '%s' "$body"
      }

- [ ] Do NOT add `_strip_code_blocks_and_spans` to the `export -f`
  line at `bin/common.sh:204`. Per brainstorm Q-4 the helper is a
  same-file private; staying unexported is the F-3 lane-discipline
  default.
- [ ] Verify no existing function in `bin/common.sh` is renamed,
  reordered, or deleted by the insertion (`bash -n bin/common.sh`
  must pass; `git diff bin/common.sh` must show only the new
  function block plus the one-line call site change in Task 2).

### Task 2: Wire the strip helper into `parse_pipeline_marker`

- `depends_on: [1]`
- `touches: bin/common.sh::parse_pipeline_marker`
- [ ] In `bin/common.sh::parse_pipeline_marker` (lines 141-171),
  insert one new line immediately after `local marker` (line 143)
  and before the existing comment at line 145:

      body="$(_strip_code_blocks_and_spans "$body")"

  This is the only edit to the function body; the grep at line 146,
  the sed-extraction at line 149, the event/k=v parser at lines
  150-164, and the return shape at lines 165-170 are all unchanged.
- [ ] Confirm rc=1 path is preserved: an all-stripped body (every
  marker was inside a code span) results in empty grep output →
  `marker` empty → `if [[ -n "$marker" ]]` skipped → existing
  `return 1` at line 170 fires.

### Task 3: Replace `_fresh_wait_reason`'s second loop in `bin/run-stage.sh`

- `depends_on: []`
- `touches: bin/run-stage.sh::_fresh_wait_reason`
- [ ] In `bin/run-stage.sh::_fresh_wait_reason` (lines 298-341),
  replace the second loop body (current lines 320-333) per brainstorm
  D-003:

      # Find the latest verdict (of any result) newer than the transition.
      # Bug B fix (ENG-61): tracking only wait verdicts here meant any
      # later pass/fail/halt/pivot was invisible — _fresh_wait_reason kept
      # returning a stale wait reason and the orchestrator looped on
      # _handle_wait. Track the latest verdict regardless of result;
      # decide post-loop whether it's a fresh wait.
      local fresh_reason="" fresh_result=""
      local fresh_ts=""
      while IFS=$'\t' read -r ts body; do
        [[ -n "$last_t" && ! "$ts" > "$last_t" ]] && continue
        ev="$(parse_pipeline_marker "$body" 2>/dev/null || true)"
        [[ -z "$ev" ]] && continue
        [[ "$(jq -r '.event' <<<"$ev")" != "verdict" ]] && continue
        if [[ "$ts" > "$fresh_ts" ]]; then
          fresh_ts="$ts"
          fresh_result="$(jq -r '.result' <<<"$ev")"
          fresh_reason="$(jq -r '.reason // ""' <<<"$ev")"
        fi
      done < <(jq -r '.[] | "\(.createdAt)\t\(.body | gsub("\n"; " "))"' <<<"$comments")

      # If the latest verdict in the freshness window is not a wait,
      # the wait has been superseded — return rc=1 and let the caller
      # fall through to verdict_handler.
      [[ "$fresh_result" != "wait" ]] && return 1

      [[ -z "$fresh_reason" ]] && return 1

  Note the `.reason // ""` projection — pass/fail/halt verdicts have
  no `.reason` field and would otherwise emit `"null"`; the `// ""`
  default keeps the `[[ -z "$fresh_reason" ]]` guard semantically
  correct for the wait branch.
- [ ] Preserve the existing reason allow-list at lines 337-340
  verbatim (no edit):

      case "$fresh_reason" in
        awaiting-approval|awaiting-ci) printf '%s' "$fresh_reason"; return 0 ;;
        *) return 1 ;;
      esac

- [ ] Preserve the building-only stage gate at lines 300-303
  verbatim (no edit). Per brainstorm A-014 / ENG-54 contract.
- [ ] Confirm the first loop (transition-discovery, lines 309-318)
  is unchanged. Bug B is in the second loop only.

## Frontend Tasks

n/a — this ticket has no UI / no FE surface. The harness is a
collection of bash scripts; there is no frontend.

## Test Tasks

### Task 4: Append fixtures P13, P14, P14b, P15, P16 to `bin/common-test.sh`

- `depends_on: [1, 2]`
- `touches: bin/common-test.sh`
- [ ] Insert the five new fixtures between current line 276 (end of
  P12) and line 278 (summary footer `printf '\ncommon-test summary
  ...'`). Use the same `pass_at` / `fail_at` pattern P11 uses for
  multi-line bodies.

  **P13 — marker enclosed in single backticks must NOT parse as a
  real marker.** AC #1 fixture 1.

      body='Discussion: the legacy stripper was triggered by `<!-- pipeline: verdict result=pass stage=implementing -->` in body text.'
      result="$(parse_pipeline_marker "$body" 2>/dev/null)" && rc=0 || rc=$?
      [[ "$rc" -eq 1 ]] && pass_at "P13: backticked marker NOT parsed (rc=1)" || fail_at "P13: rc mismatch" "expected 1, got $rc"
      [[ -z "$result" ]] && pass_at "P13: backticked marker → empty stdout" || fail_at "P13: stdout not empty" "got: $result"

  **P14 — marker inside triple-backtick fenced block must NOT parse.**
  AC #1 fixture 2. Body uses the gsub-collapsed form (single line)
  to mirror the production call sites' input shape.

      body='Example: ```<!-- pipeline: verdict result=pass stage=implementing -->``` is what the agent emits.'
      result="$(parse_pipeline_marker "$body" 2>/dev/null)" && rc=0 || rc=$?
      [[ "$rc" -eq 1 ]] && pass_at "P14: triple-backtick fenced marker NOT parsed (rc=1)" || fail_at "P14: rc mismatch" "expected 1, got $rc"
      [[ -z "$result" ]] && pass_at "P14: triple-backtick fenced marker → empty stdout" || fail_at "P14: stdout not empty" "got: $result"

  **P14b — multi-line raw body with 4-space-indented marker must NOT
  parse.** Brainstorm D-002 / A-N2: pins the indented-block code
  path (step 1 of the strip helper). Bypasses the typical caller's
  gsub-collapse by passing newlines preserved.

      body=$'Some prose.\n    <!-- pipeline: verdict result=pass stage=implementing -->\nMore prose.'
      result="$(parse_pipeline_marker "$body" 2>/dev/null)" && rc=0 || rc=$?
      [[ "$rc" -eq 1 ]] && pass_at "P14b: 4-space-indented marker (raw multi-line body) NOT parsed (rc=1)" || fail_at "P14b: rc mismatch" "expected 1, got $rc"
      [[ -z "$result" ]] && pass_at "P14b: 4-space-indented marker → empty stdout" || fail_at "P14b: stdout not empty" "got: $result"

  **P15 — real marker on a line with no backticks must still parse.**
  AC #1 fixture 3. Confirms the strip helper does not over-strip.

      body='Plain prose. <!-- pipeline: verdict result=pass stage=implementing -->'
      result="$(parse_pipeline_marker "$body")"
      [[ "$(jq -r '.event' <<<"$result")" == "verdict" ]] && pass_at "P15: bare real marker still parses" || fail_at "P15: event mismatch" "got: $result"
      [[ "$(jq -r '.result' <<<"$result")" == "pass" ]] && pass_at "P15: bare real marker → result=pass" || fail_at "P15: result mismatch" "got: $result"

  **P16 — real marker followed by a backticked example marker; real
  one must win.** AC #1 fixture 4. Confirms `tail -1` semantics
  survive the pre-strip (the example is removed → only the real one
  remains for grep → tail -1 picks it).

      body='Real: <!-- pipeline: verdict result=pass stage=implementing --> See also: `<!-- pipeline: verdict result=fail target=planning -->` for the failure case.'
      result="$(parse_pipeline_marker "$body")"
      [[ "$(jq -r '.event' <<<"$result")" == "verdict" ]] && pass_at "P16: real marker wins over backticked example" || fail_at "P16: event mismatch" "got: $result"
      [[ "$(jq -r '.result' <<<"$result")" == "pass" ]] && pass_at "P16: real marker → result=pass (NOT fail)" || fail_at "P16: result mismatch (example marker was wrongly parsed)" "got: $result"

- [ ] Verify the summary footer (`printf '\ncommon-test summary:
  %d passed, %d failed\n' "$PASS" "$FAIL"`) and the failure dump
  remain at the end of the file unchanged.

### Task 5: Append fixtures WS1, WS2, WS3 to `bin/run-stage-test.sh`

- `depends_on: [3]`
- `touches: bin/run-stage-test.sh`
- [ ] Insert the three new fixtures between current line 2210 (end
  of WR3 assertion) and line 2212 (`echo`/summary line). Use the
  same `COMMENTS_JSON='[...]'` + re-write `$STUB_DIR/linear.sh` +
  `_fresh_wait_reason ENG-WSN building` pattern WR1 uses (lines
  2179-2191).

  **WS1 — wait at T1, stage-summary (verdict pass) at T2 > T1 →
  return empty + rc=1.** AC #2 fixture 1: Bug B fix's primary
  scenario.

      printf '\n--- _fresh_wait_reason: Bug B (wait shadows newer non-wait) ---\n'

      COMMENTS_JSON='[
        {"id":"c1","createdAt":"2026-05-03T10:00:00Z","body":"<!-- pipeline-transition: qa → building -->"},
        {"id":"c2","createdAt":"2026-05-03T11:00:00Z","body":"<!-- pipeline: verdict result=wait reason=awaiting-approval -->"},
        {"id":"c3","createdAt":"2026-05-03T12:00:00Z","body":"<!-- pipeline: verdict result=pass stage=building -->"}
      ]'
      cat > "$STUB_DIR/linear.sh" <<EOF
      #!/bin/bash
      [[ "\$1" == "get-comments" ]] && printf '%s' '$COMMENTS_JSON'
      EOF
      rc=0; result="$(_fresh_wait_reason ENG-WS1 building 2>/dev/null)" || rc=$?
      [[ "$rc" -eq 1 ]] && pass_at "WS1: wait shadowed by newer pass → rc=1" "rc=$rc" || fail_at "WS1: rc mismatch" "expected 1, got $rc"
      [[ -z "$result" ]] && pass_at "WS1: wait shadowed by newer pass → empty stdout" || fail_at "WS1: stdout not empty" "got: $result"

  **WS2 — wait at T1, no later verdict → return wait reason + rc=0.**
  AC #2 fixture 2: regression check that the wait carve-out still
  works when no later verdict exists.

      COMMENTS_JSON='[
        {"id":"c1","createdAt":"2026-05-03T10:00:00Z","body":"<!-- pipeline-transition: qa → building -->"},
        {"id":"c2","createdAt":"2026-05-03T11:00:00Z","body":"<!-- pipeline: verdict result=wait reason=awaiting-approval -->"}
      ]'
      cat > "$STUB_DIR/linear.sh" <<EOF
      #!/bin/bash
      [[ "\$1" == "get-comments" ]] && printf '%s' '$COMMENTS_JSON'
      EOF
      result="$(_fresh_wait_reason ENG-WS2 building 2>/dev/null || printf '')"
      [[ "$result" == "awaiting-approval" ]] && pass_at "WS2: wait alone → reason returned" "got: '$result'" || fail_at "WS2: wait reason mismatch" "got: '$result'"

  **WS3 — wait at T1, halt at T2 > T1 → return empty + rc=1.**
  AC #2 fixture 3: Bug B + Bug A integration check (the latest
  verdict can be any non-wait result, including halt).

      COMMENTS_JSON='[
        {"id":"c1","createdAt":"2026-05-03T10:00:00Z","body":"<!-- pipeline-transition: qa → building -->"},
        {"id":"c2","createdAt":"2026-05-03T11:00:00Z","body":"<!-- pipeline: verdict result=wait reason=awaiting-approval -->"},
        {"id":"c3","createdAt":"2026-05-03T12:00:00Z","body":"<!-- pipeline: verdict result=halt reason=agent-blocked -->"}
      ]'
      cat > "$STUB_DIR/linear.sh" <<EOF
      #!/bin/bash
      [[ "\$1" == "get-comments" ]] && printf '%s' '$COMMENTS_JSON'
      EOF
      rc=0; result="$(_fresh_wait_reason ENG-WS3 building 2>/dev/null)" || rc=$?
      [[ "$rc" -eq 1 ]] && pass_at "WS3: wait shadowed by newer halt → rc=1" "rc=$rc" || fail_at "WS3: rc mismatch" "expected 1, got $rc"
      [[ -z "$result" ]] && pass_at "WS3: wait shadowed by newer halt → empty stdout" || fail_at "WS3: stdout not empty" "got: $result"

- [ ] Verify the existing summary echo (`echo; echo "run-stage-test:
  passed=$PASS failed=$FAIL"; (( FAIL == 0 )) || exit 1`) remains
  unchanged at the end of the file.

### Task 6: Run the full test gate and report

- `depends_on: [4, 5]`
- `touches: (none — verification step)`
- [ ] From the worktree root run, in this order:

      bash -n bin/common.sh
      bash -n bin/run-stage.sh
      bash bin/common-test.sh
      bash bin/run-stage-test.sh
      bash bin/verdict-handler-test.sh
      bash bin/scope-check-test.sh

  All six must exit 0. The first two are syntax-only checks; the
  remaining four exercise the real implementations of
  `parse_pipeline_marker` (via common-test.sh and the two transitive
  callers' tests) and `_fresh_wait_reason` (via run-stage-test.sh).
- [ ] Spot-check that the broader gate also passes (not just the
  four directly affected suites). Per project profile §"Build & test
  gates", run:

      bash bin/dispatch-test.sh && bash bin/poll-slot-test.sh \
        && bash bin/scope-check-test.sh && bash bin/halt-sprawl-test.sh \
        && bash bin/halt-sprawl-adversarial-test.sh && bash bin/linear-test.sh \
        && bash bin/metrics-test.sh && bash bin/mutex-test.sh \
        && bash bin/setup-helpers-test.sh && bash bin/render-prompt-test.sh \
        && bash bin/phase-project-profile-test.sh && bash bin/classify-failure-test.sh

- [ ] If any test fails, return to the relevant Task (1, 2, 3, 4,
  or 5) and fix the regression before proceeding. Do NOT skip,
  comment-out, or weaken any existing assertion.

## Failure Mode → Test Map

Drawn from brainstorm §5 (Error handling) and §6 (Edge cases). Every
row binds to a concrete fixture in `bin/common-test.sh` or
`bin/run-stage-test.sh`.

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
| ------------ | ------- | ----------------- | ---------- | --------- |
| Marker quoted in single backticks | Comment body: `` `<!-- pipeline: ... -->` `` (single-line) | Parser returns rc=1, empty stdout | unit | `bin/common-test.sh::P13` |
| Marker inside triple-backtick fence | Comment body: ` ```<!-- pipeline: ... -->``` ` (single-line, post-gsub-collapse shape) | Parser returns rc=1, empty stdout | unit | `bin/common-test.sh::P14` |
| Marker on 4-space-indented line in raw multi-line body | Body with `\n    <!-- pipeline: ... -->\n` (newlines preserved) | Parser returns rc=1, empty stdout | unit | `bin/common-test.sh::P14b` |
| Bare real marker on a line with no backticks | Comment body: `Plain prose. <!-- pipeline: ... -->` | Parser returns rc=0, JSON event on stdout | unit | `bin/common-test.sh::P15` |
| Real marker + backticked example on same line | Body has both shapes; real marker outside backticks | Parser returns rc=0 with the REAL marker (example stripped) | unit | `bin/common-test.sh::P16` |
| Empty body | `parse_pipeline_marker ""` | Strip helper returns empty; parser returns rc=1 | unit | (covered by P12 — pre-existing) |
| Unbalanced single backtick (lone `` ` ``) | Body has one `` ` `` not paired | Strip loop exits (no match); marker on same body still parses | unit | (covered by P15 — bare real marker independent of stray punctuation) |
| Marker body itself contains a backtick | Hypothetical malformed marker with `` ` `` inside HTML-comment payload | Out of scope (writer-side validation per brainstorm Q-1, registry tokens are `[a-z-]` only) | n/a | n/a |
| Wait at T1, no later verdict | Comment stream: transition + wait only | `_fresh_wait_reason` returns wait reason, rc=0 | unit | `bin/run-stage-test.sh::WS2` |
| Wait at T1, verdict pass at T2 > T1 | Comment stream: transition + wait + pass | `_fresh_wait_reason` returns rc=1, empty stdout | unit | `bin/run-stage-test.sh::WS1` |
| Wait at T1, verdict halt at T2 > T1 | Comment stream: transition + wait + halt | `_fresh_wait_reason` returns rc=1, empty stdout | unit | `bin/run-stage-test.sh::WS3` |
| Wait at T1, verdict pivot at T2 > T1 | Pivot is non-wait; same predicate as pass/halt | `_fresh_wait_reason` returns rc=1 (covered by general predicate per D-004) | unit | (covered by WS1/WS3 — predicate is `!= "wait"` not enum) |
| Wait at T1, verdict fail at T2 > T1 | Same shape as pass/halt | `_fresh_wait_reason` returns rc=1 (covered by general predicate per D-004) | unit | (covered by WS1/WS3 — predicate is `!= "wait"` not enum) |
| `_fresh_wait_reason` called on stage other than building | `_fresh_wait_reason ENG-X implementing` | Returns rc=1 immediately (stage gate at lines 300-303) | unit | (covered by WR2 — pre-existing) |
| `_fresh_wait_reason` called with comment stream having no verdicts at all | Empty or transition-only stream | `fresh_result` stays empty; post-loop `!= "wait"` triggers rc=1 | unit | (implicit in WS1/WS2/WS3 setup; no separate fixture per brainstorm §5) |
| `_fresh_wait_reason` called when Linear get-comments fails | `comments=""` or `"null"` | Returns rc=1 (line 307) | unit | (covered by existing handling — unchanged from current) |
| Wait verdict with non-allow-listed reason (e.g. `reason=invented-token`) | Latest is wait but reason not in allow-list | Post-loop `case` allow-list rejects → rc=1 | unit | (covered by existing reason allow-list — unchanged) |
| Body that consists entirely of a triple-backtick fence whose contents are the marker | `` ```<!-- pipeline: ... -->``` `` is the entire body | Strip removes the fence; grep finds no marker; rc=1 | unit | (covered by P14 — same shape) |
| End-to-end: ENG-58-class build replay (Bug A + Bug B together) | PR merged → 5 post-merge `verdict pass building` markers; old wait shadowed; old prose-quoted transition phantom | Build completes on first post-merge dispatch, no operator label-flips | smoke (manual, post-deploy) | brainstorm §4.3 + Q-3 — implementer enumerates `$PROJECT_STATE_DIR/*/wait-building.json` after deploy and runs `bin/pipeline.sh decide --action continue` for any victim |

The end-to-end smoke check is documented in brainstorm §9 as an
operator action (existing tooling), not a code change. AC #3 of the
Linear issue is forward-looking — the fix is structural; subsequent
ENG-58-class issues complete the build stage on the first post-merge
dispatch automatically.

## Test Strategy

**Unit coverage (primary).** Eight new fixtures exercise the two
modified functions directly:

- `parse_pipeline_marker`: P13 (single-backtick), P14 (triple-fence),
  P14b (4-space-indent on raw multi-line body), P15 (bare real
  marker still parses), P16 (real marker wins over backticked
  example on same line).
- `_fresh_wait_reason`: WS1 (wait + pass → rc=1), WS2 (wait alone →
  reason), WS3 (wait + halt → rc=1).

The fixtures cover both bugs, the regression contract (existing
behaviour preserved when no shadow exists), and the pivot-symmetry
case (D-004) implicitly via the "any non-wait" predicate exercised
by WS1 and WS3.

**Integration coverage (transitive).** No new integration tests are
added. The pre-existing `bin/verdict-handler-test.sh` and
`bin/scope-check-test.sh` exercise `parse_pipeline_marker` via their
real call sites (`find_fresh_verdict`, `has_scope_approval`) and
must continue to pass — verifying that the Bug A fix does not
regress those callers. The pre-existing
`bin/run-stage-test.sh` cases ENG-56-A through ENG-56-I (lines
~2050-2143), MEA1 (line ~2150), and WR1/WR2/WR3 (lines 2179-2210)
must also continue to pass — verifying that the Bug B fix does not
regress the building-only stage gate, the wait-shape carve-out for
post-dispatch halt apply, the marker-emission audit path, or the
new-shape wait detection.

**Smoke coverage (manual, post-deploy).** Per brainstorm Q-3 and
this plan's Failure Mode table: enumerate `$PROJECT_STATE_DIR/*/wait-building.json`
for non-zero counters whose corresponding Linear issue carries a
non-wait verdict newer than its latest transition. Each is a Bug B
victim; flush via `bash bin/pipeline.sh decide ENG-N --action
continue`. No code change required for the cleanup; existing
operator tooling handles it.

**Adversarial coverage (deferred).** Per brainstorm §9, no
adversarial fixtures are added in this iteration. The brainstorm's
A15 residual concern — `${BASH_REMATCH[0]}` containing glob
metachars in `${var//pat/repl}` — is documented as a sed fallback
in Task 1's helper comment; if a pathological body surfaces post-
deploy, swap to the sed form per the brainstorm's §12 hint. Q-2's
"meta:metric counter for stripped prose markers" is explicitly out
of scope.

**Regression contract.** All existing fixtures in
`bin/common-test.sh`, `bin/run-stage-test.sh`,
`bin/verdict-handler-test.sh`, and `bin/scope-check-test.sh` continue
to pass. Task 6 enumerates the gate command.

## Self-review verdicts (2026-05-03)

Five personas reviewed the plan after Task 1–6 were drafted. Findings
recorded inline; iteration log at the bottom.

### Feasibility — PASS

Every named entity, file path, line range, and call site in this
plan was re-verified against the live worktree on 2026-05-03 with
Read/Grep before the personas were dispatched:

- `parse_pipeline_marker` at `bin/common.sh:141-171` ✓
- `_strip_code_blocks_and_spans` insertion point at
  `bin/common.sh:121-122` (between `failure_outcome_for_exit` close
  and the section header) ✓
- `_fresh_wait_reason` at `bin/run-stage.sh:298-341` with
  building-only gate at lines 300-303, second loop at lines 320-333,
  reason allow-list at lines 337-340 ✓
- `bin/common-test.sh` parse_pipeline_marker group at lines 248-276
  with summary footer at lines 278-284 ✓
- `bin/run-stage-test.sh` WR group at lines 2175-2210 with summary
  echo at lines 2212-2214 ✓
- `find_fresh_verdict` at `bin/verdict-handler.sh:85-144` with
  parse_pipeline_marker calls at lines 97 and 110, wait-exclusion
  at line 114 ✓
- `has_scope_approval` at `bin/scope-check.sh:105-143` with
  parse_pipeline_marker calls at lines 120, 134 (after gsub at 127,
  140) ✓
- `cmd_status` at `bin/pipeline.sh:43-59` with parse_pipeline_marker
  call at line 55 ✓
- `export -f parse_pipeline_marker` at `bin/common.sh:204` ✓
- Pipeline-event registry results `pass|fail|halt|wait|pivot` at
  `docs/pipeline-vocabulary.md:38-44` ✓
- Wait reason allow-list `awaiting-approval|awaiting-ci` at
  `bin/run-stage.sh:337-340` ✓

`depends_on` lists: Task 1 ([]) and Task 3 ([]) are independent —
they touch different files. Task 2 depends on Task 1 (the call site
needs the helper definition). Task 4 depends on Task 1 + Task 2
(fixtures need both pieces of the parser fix in place to assert the
correct behaviour). Task 5 depends on Task 3. Task 6 depends on
Task 4 + Task 5. No hidden coupling. Failure Mode table rows all
name plausible test layers and concrete fixture IDs.

No P0 findings.

### Scope — PASS

Every task and every File Structure entry traces to a brainstorm
decision: Task 1/Task 2 → D-001 + D-002, Task 3 → D-003, Task 4 →
D-005 (P13/P14/P15/P16 from AC #1, P14b from D-002 indented-block
pin), Task 5 → D-005 (WS1/WS2/WS3 from AC #2). No gold-plating; no
task strays outside the declared File Structure (Task 1/2 touch
`bin/common.sh`, Task 3 touches `bin/run-stage.sh`, Task 4 touches
`bin/common-test.sh`, Task 5 touches `bin/run-stage-test.sh`, Task
6 is verification-only with no file mutations).

The brainstorm's §9 "out-of-scope" list (call-site newline-preserve
refactor, auto-emit transition on wait-supersede, meta-metric
counter, in-flight cleanup, reverse wait-pass case) is honoured
verbatim — no plan task encroaches on any of these.

No P0 findings.

### Coherence — PASS

- Goal matches brainstorm §1 and §2 — both bugs, both fixes named.
- Task 1 + Task 2 jointly realise D-001 + D-002 (helper +
  call-site).
- Task 3 realises D-003 (single-cursor latest-verdict-tracking
  formulation).
- Task 4 + Task 5 jointly realise D-005 (per-module sibling tests).
- Test Strategy enumerates every Failure Mode row.
- API Contract block correctly states "no new API surface" — the
  harness has no FE↔BE surface, and even if it did, this ticket
  modifies internal helpers only.

No P0 findings.

### Design — PASS

- Module boundaries respected: `bin/common.sh` adds a private same-
  file helper (no `export -f`); `bin/run-stage.sh` does not gain any
  new dependency on `bin/common.sh` beyond what it already has via
  the existing `parse_pipeline_marker` call.
- Lane discipline (ENG-41) preserved: parser is read-side, no Linear
  writes; `_fresh_wait_reason` is read-side, no Linear writes.
- No new env vars, no new state files, no new exit codes.
- Bash 3.2+ compatibility checked (A14, A15, A16, A18 in brainstorm
  + A-014, A-015, A-016 in this plan's Assumption Inventory).
- The strip helper is monotone (it can only remove potential matches,
  not surface new ones), so it cannot be used to inject false-positive
  markers — security gate F-1/F-2 in `_fresh_wait_reason` is
  unaffected.

No P0 findings.

### Product — PASS

The user is the operator. Both bugs cost real spend and required
manual label-flip recovery. The plan removes both classes
structurally — agent-side prompts unchanged, marker contract
unchanged, registry unchanged. Operator-visible behaviour after the
fix: zero label-flips needed on issues whose summaries discuss the
marker protocol; zero "build wait-loops after PR merge" incidents.

The plan does not solve an adjacent technical problem; it solves
exactly the two bugs the Linear issue names, with the eight fixtures
the Linear issue's AC enumerates (P13–P16 from AC #1 plus P14b from
D-002 to honour AC #1's literal text on indented blocks; WS1–WS3
from AC #2).

No P0 findings.

### Iteration log

- Iteration 0 (initial draft, 2026-05-03): all five personas
  PASS; gate P0 = 0. No iteration needed; brainstorm was already at
  its iteration-2 accepted state (six personas PASS in §11) and the
  plan inherits the resolved scope from there.
