---
linear: ENG-61
title: Verdict-handler — harden parse_pipeline_marker against prose-quoted markers + fix _fresh_wait_reason wait-shadows-newer-verdict trap
date: 2026-05-03
status: draft
---

# ENG-61 — parse_pipeline_marker prose-quote hardening + _fresh_wait_reason wait-shadow fix

## 1. Problem

Two independent regressions in the orchestrator's verdict-discovery path,
both surfaced by the 2026-05-02 SDLC observation run on ENG-43, ENG-52,
and ENG-58.

### 1.1 Bug A — `parse_pipeline_marker` false-matches markers quoted in prose

`bin/common.sh::parse_pipeline_marker` (`bin/common.sh:141-171`) discovers
markers via a single ERE grep:

    grep -oE '<!-- pipeline: [^>]+ -->'

The pattern matches the literal byte sequence anywhere in the body. It
does not know that markdown renders code spans (single backticks) and
fenced code blocks (triple backticks) as inert text. Linear's web UI
shows the marker as code, but the orchestrator sees raw bytes and treats
it as a real state-driving event.

Concretely: a stage-summary body that documents the marker protocol —
e.g. ENG-58's plan, which contains the literal string
``<!-- pipeline-transition: <stage> → <stage> (operator-resume) -->``
inside a code span — becomes a phantom transition. That phantom is then
the freshness floor used by both `find_fresh_verdict`
(`bin/verdict-handler.sh:91-102`) and `_fresh_wait_reason`
(`bin/run-stage.sh:309-318`). Every legitimate marker posted *before*
the prose comment is now older than the floor and silently invisible;
every legitimate marker posted *after* must clear the (also-fake)
floor.

The acute symptom is `pipeline-halt: protocol-violation` raised against
issues whose stage-summaries are perfectly valid — the orchestrator just
cannot see them because the freshness window has been pushed past them.

### 1.2 Bug B — `_fresh_wait_reason` doesn't notice newer non-wait verdicts

`bin/run-stage.sh::_fresh_wait_reason` (`bin/run-stage.sh:298-341`) is
the build-stage soft-pause gate. Today it runs two passes over the
comment stream:

1. Find the latest `pipeline-transition` timestamp (`last_t`).
2. Find the latest `verdict result=wait` newer than `last_t`. Return
   its reason.

Step 2 looks only at wait-shaped verdicts. A later
`verdict result=pass|fail|halt` posted after the wait is invisible —
the function still returns the old wait's reason, so the run-stage
caller (`bin/run-stage.sh:698-737`) routes the tick through `_handle_wait`
and exits 0 before reaching the agent-contract validator at line 749 or
`verdict_handler` at the parent dispatch site.

Observed in the field on ENG-58: a build P2 wait at 16:32:08Z shadowed
five subsequent `verdict pass stage=building` markers posted between
16:39:35Z (PR merge) and the operator's manual rescue. Each tick
re-dispatched the build agent, accumulated a wait-budget increment, and
emitted the same pass marker — none of which was ever read.

### 1.3 Why these compound

The two bugs land on the same code path. Bug A pushes the freshness
floor past real verdicts; Bug B refuses to consider non-wait verdicts
even when they ARE inside the freshness window. Together they account
for ~$50 of wasted Anthropic spend in a single observation session and
generalise to any future issue whose summary discusses the marker
protocol — including ENG-60, ENG-58, ENG-43, ENG-41, and this issue.

## 2. Decisions

- **D-001. Fix Bug A inside `parse_pipeline_marker` via a private
  pre-grep stripper.**

  Add a static helper `_strip_code_blocks_and_spans body` in
  `bin/common.sh` and call it from `parse_pipeline_marker` before the
  `grep -oE`. The helper's three-pass body is detailed under D-002
  (which scopes which shapes are stripped); D-001 is solely about
  *where* the stripping happens (centrally, in
  `parse_pipeline_marker`).

  *Why central:* every consumer of pipeline markers
  (`bin/run-stage.sh::_fresh_wait_reason`,
  `bin/verdict-handler.sh::find_fresh_verdict`,
  `bin/scope-check.sh::has_scope_approval`,
  `bin/pipeline.sh:55`) routes through `parse_pipeline_marker` and is
  already paying for the gsub-collapsed body. A single central fix
  immunises all of them in one place. This matches the project's "use
  the helper from `common.sh` rather than rolling your own"
  convention (CLAUDE.md "When wiring a new script", final bullet).

  *Rejected alternative — strip in each caller's jq projection.* Each
  call site does
  `jq -r '.[] | "\(.createdAt)\t\(.body | gsub("\n"; " "))"'`; we could
  extend the gsub to also strip backticks (`gsub("\`[^\`]*\`"; " ")`).
  Rejected because (a) jq's PCRE is optional and tests run on macOS
  jq-1.6 without it, (b) we would have to duplicate the same logic in
  five jq expressions, and (c) the helper is invisible to anyone
  writing a new caller — they would have to read the verdict-handler
  flow to learn the convention.

  *Rejected alternative — switch to a markdown parser (e.g.
  `marked`/`pandoc`).* Rejected because the harness has zero
  non-bash runtime deps today (CLAUDE.md "Stack" section in the
  project profile addendum lists `jq awk sed gtimeout git gh claude
  curl` only). Pulling in a markdown parser for a 30-line stripper
  is wildly disproportionate.

- **D-002. Strip both backtick shapes (full coverage) and 4-space-
  indented blocks (best-effort, newline-dependent).**

  The Linear issue's AC #1 names "backtick-bounded" code spans plus
  "fenced code blocks (triple-backtick or four-space-indent)". The
  suggested-implementation paragraph and all four named fixtures
  (P13–P16) cover backticks only — there is a tension between the
  AC's literal text and the implementer guidance. Both observed-cost
  incidents (ENG-58, ENG-52) used backtick fences; no production
  incident has been traced to a 4-space-indented marker.

  Resolution: the strip helper handles all three shapes. Backtick
  shapes work in any body (collapsed or raw); 4-space-indent stripping
  activates only when the body still contains newlines. Sketch with
  the indented-block step included:

  ```bash
  _strip_code_blocks_and_spans() {
    local body="$1"
    # Step 1: 4-space-indented blocks. Only meaningful on a multi-line
    # body. The harness's three current call sites (run-stage.sh:318,
    # verdict-handler.sh:102, scope-check.sh:127, :140) pre-collapse via
    # jq gsub("\n"; " "), so this step is a no-op for them today.
    # Direct callers (e.g. tests, future call sites that preserve
    # newlines) get full coverage. CommonMark "indented code block"
    # rules (preceding blank line + 4-space indent) are approximated
    # by line-level filtering: any line starting with >=4 spaces or a
    # tab is stripped. The strip is monotone (it can only remove
    # potential matches, never surface new ones), so the relaxed
    # heuristic is safe — false positives strip a real marker, but
    # markers are written at column 0 by contract (AGENT_PROMPTS.md).
    if [[ "$body" == *$'\n'* ]]; then
      body="$(awk '!/^( {4,}|\t)/' <<<"$body")"
    fi
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
  ```

  *Why:* honours the AC's literal text without forcing a refactor of
  the three call sites' jq pipelines (which would require switching
  the tab-delimited line-protocol to a NUL-delimited or base64-encoded
  one to preserve newlines through `read`). Backtick coverage —
  which is what every observed cost case used — is fully effective
  immediately; indented-block coverage activates the moment any caller
  starts passing raw bodies, and a unit-test fixture pins the
  behaviour today.

  Codify as a Gotcha note in the helper's leading comment so a future
  maintainer who migrates a call site knows that doing so unlocks
  indented-block coverage automatically.

  *Rejected alternative — refactor all three call sites to preserve
  newlines through the read loop.* Rejected because (a) the cost
  incidents are 100% backtick-shaped, (b) it touches three modules
  for a hypothetical class of bug, and (c) it forces a Linear-comment
  body-encoding decision (NUL-delimit vs base64) that has nothing
  to do with the parser hardening this ticket scopes.

  *Rejected alternative — drop 4-space-indent entirely as the prior
  draft did.* Rejected on Scope-persona review (iteration 1, P0):
  AC #1 is the contract; suggested-implementation is a hint, not an
  amendment. The compromise above (best-effort, no call-site
  refactor) honours the AC literally with no extra blast radius.

- **D-003. Fix Bug B by tracking the latest verdict of *any* result
  in `_fresh_wait_reason`, returning the wait reason iff the latest
  verdict is a wait.**

  Replace the second loop (`bin/run-stage.sh:320-333`) so it tracks
  the most recent verdict comment newer than `last_t`, regardless of
  result. After the loop:

  - if no verdict was found → return 1 (current behaviour preserved);
  - if the latest verdict's result is `wait` → emit reason, return 0;
  - if the latest verdict's result is anything else (pass, fail,
    halt, pivot) → return 1, letting the caller fall through to the
    agent-contract validator and `verdict_handler`.

  Sketch:

  ```bash
  local fresh_ts="" fresh_result="" fresh_reason=""
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

  [[ "$fresh_result" != "wait" ]] && return 1
  [[ -z "$fresh_reason" ]] && return 1
  case "$fresh_reason" in
    awaiting-approval|awaiting-ci) printf '%s' "$fresh_reason"; return 0 ;;
    *) return 1 ;;
  esac
  ```

  *Why:* this matches the function's intended contract — "is the
  current state a *fresh* wait?" — and the failure mode it advertises
  in its own header comment ("most recent pipeline-transition" sets
  the freshness floor). The current implementation conflates "latest
  wait newer than transition" with "latest verdict in the freshness
  window is a wait", and the two diverge precisely when the agent
  posts a real outcome after a wait.

  *Rejected alternative — track the latest wait AND the latest
  non-wait separately, return wait reason iff `latest_wait_ts >
  latest_non_wait_ts`.* Mathematically equivalent but harder to read
  and easier to bug-out (the bookkeeping has to keep two parallel
  cursors). The single-cursor "track latest verdict, conditionally
  return" form maps to the existing loop one-for-one and is what the
  three new fixtures (WS1/WS2/WS3) test directly.

  *Rejected alternative — emit a `<!-- pipeline-transition: -->`
  comment automatically when a non-wait verdict supersedes a wait.*
  Rejected because (a) it adds an orchestrator-side write to a
  read-only discovery function, (b) it conflates "freshness floor" with
  "real state transition" and would pollute the transition stream
  read by `find_fresh_verdict` and `count_marker_since_last_transition`,
  and (c) the trust model (ENG-41) restricts who can post which marker
  shape. Read-side filtering is the right layer.

- **D-004. Apply pivot-result symmetry without enumerating it.**

  The verdict registry today admits five results
  (`bin/pipeline-events.json`: pass, fail, halt, wait, pivot). The
  D-003 sketch returns empty whenever `fresh_result != "wait"`, so
  pivot is treated identically to pass/fail/halt — exactly the right
  thing (a pivot is also a real, non-wait outcome that should
  un-shadow the wait). No explicit pivot test fixture is needed; the
  general predicate covers it.

  *Why:* the function should not encode the verdict registry's enum
  in its predicate. Future verdict results (if any) should fall
  through to "non-wait → return empty" by default.

- **D-005. Tests live in the same module sibling that hosts the
  function under test.**

  - Bug A fixtures P13–P16 → `bin/common-test.sh`, appended to the
    existing "parse_pipeline_marker" group at `bin/common-test.sh:248-276`
    (after fixture P12). One additional indented-block fixture P14b
    (multi-line raw body, 4-space-indented marker) calls
    `parse_pipeline_marker` with newlines preserved (bypassing the
    typical caller's gsub-collapse) and asserts the marker is
    correctly stripped — pinning the indented-block code path's
    behaviour under D-002 even though the standard call sites do not
    exercise it today.
  - Bug B fixtures WS1–WS3 → `bin/run-stage-test.sh`, appended to the
    existing "_fresh_wait_reason new-shape detection" group at
    `bin/run-stage-test.sh:2175-2210` (after fixture WR3).

  *Why:* matches the project's "tests are sibling shell scripts"
  convention (CLAUDE.md "Tests" section) and keeps each module's tests
  reachable from the gate command in the project profile. No new
  test-runner machinery, no cross-cutting fixture file.

  *Rejected alternative — add a separate `bin/parse-marker-fixtures-test.sh`
  for the prose-quoting fixtures.* Rejected because we already have a
  parse_pipeline_marker group in common-test.sh; splitting it would
  create two places to update on a future parser change.

## 3. Architecture

```
bin/common.sh
  ├─ _strip_code_blocks_and_spans (NEW, private; called by parse_pipeline_marker)
  └─ parse_pipeline_marker         (MODIFIED — pre-strips body before grep)

bin/run-stage.sh
  └─ _fresh_wait_reason            (MODIFIED — second loop tracks latest verdict
                                    of any result, returns wait reason iff latest
                                    is wait)

bin/common-test.sh                 (APPEND fixtures P13–P16)
bin/run-stage-test.sh              (APPEND fixtures WS1–WS3)
```

No new files. No changes to:

- `bin/verdict-handler.sh` — `find_fresh_verdict` already excludes wait
  from its "actionable verdict" loop (`bin/verdict-handler.sh:113-114`)
  and inherits the parser fix transparently.
- `bin/scope-check.sh` — `has_scope_approval` inherits the parser fix.
- `bin/pipeline.sh` — `event` writers do not read prose; only the
  status-rendering path at line 55 uses parse_pipeline_marker, and it
  inherits the fix.
- `bin/pipeline-events.json`, `docs/pipeline-vocabulary.md` — registry
  and rendered docs are unaffected.
- `AGENT_PROMPTS.md`, `learned-rules/` — prompts unaffected; this is
  read-side hardening, not a contract change for the agents.

## 4. Data flow

### 4.1 Bug A — parser pre-strip

```
caller body
   │
   │ standard call sites: jq gsub("\n"; " ") collapses to one line
   │ direct test callers (P14b): pass raw body with newlines preserved
   ▼
parse_pipeline_marker body
   │
   │ NEW: _strip_code_blocks_and_spans body
   │   step 1 (multi-line only): awk '!/^( {4,}|\t)/'  ← strip indented blocks
   │   step 2 (always):           collapse newlines to spaces
   │   step 3 (always):           strip ```…``` triple-fenced regions
   │   step 4 (always):           strip `…` single-backtick spans
   │
   │ grep -oE '<!-- pipeline: [^>]+ -->' | tail -1
   ▼
JSON event (or rc=1 + empty stdout)
```

`tail -1` semantics are preserved: when both a real marker and a
prose-quoted example are present, the example is stripped and the real
one wins regardless of position. (Fixture P16.)

Step 1 is a no-op for the three current production callers because
they pre-collapse via jq before passing the body to
`parse_pipeline_marker`. It activates for direct callers (e.g.
fixture P14b, future call sites that preserve newlines).

### 4.2 Bug B — _fresh_wait_reason

```
get-comments stream (json array, descending or unordered)
   │
   │ pass 1: max(createdAt) where event=transition  → last_t (freshness floor)
   ▼
   │ pass 2 (NEW): max(createdAt) where event=verdict AND createdAt > last_t
   │             record .result and .reason of that single latest verdict
   ▼
   if fresh_result == "wait" AND fresh_reason ∈ {awaiting-approval, awaiting-ci}
     → printf reason; return 0
   else
     → return 1   (caller falls through to verdict_handler)
```

### 4.3 End-to-end consequence (ENG-58 build replay)

Pre-fix sequence:

1. T0: agent posts `verdict wait reason=awaiting-approval`.
2. T1 (15s later): agent posts a stage-summary body containing
   `` `<!-- pipeline-transition: ... -->` ``.
   Bug A: parser sees a transition; freshness floor jumps to T1.
   The wait at T0 is now older than the floor and invisible — but so is
   every legitimate marker between T0 and T1.
3. T2..T6 (post-merge): agent posts `verdict pass stage=building`.
   Bug B: `_fresh_wait_reason` looks for waits newer than (corrupted)
   floor; finds none; returns rc=1 → caller falls through; but an
   *upstream* tick had also been routing through `_handle_wait` while
   T0 was still considered fresh. (Two failure paths converge.)

Post-fix sequence:

1. T0: agent posts wait. Floor unchanged (no transition involved).
2. T1: stage-summary with prose-quoted markers. Parser strips them;
   no phantom transition; floor unchanged.
3. T2..T6: agent posts pass markers. `_fresh_wait_reason` second loop
   finds T6 (latest verdict) > T0 (wait); fresh_result="pass" ≠ "wait";
   returns rc=1; caller falls through to `verdict_handler`, which reads
   the pass via `find_fresh_verdict` and transitions building→released.

Operator label-flips: zero.

## 5. Error handling

- **Strip helper called on empty body.** Loops never enter; returns
  empty string. `parse_pipeline_marker` then runs grep on empty input
  and returns rc=1 (current behaviour preserved).
- **Strip helper called on body with unbalanced backticks.** A lone
  `` ` `` not followed by another `` ` `` does not match
  `` `[^`]*` `` and is left in place. Markers in unbalanced-backtick
  bodies are still parsed (per fixture P15: marker on a line with
  no balanced backticks must still parse).
- **Strip helper called on a body where the *marker itself* contains a
  backtick.** Markers are HTML comments; the registry tokens
  (`bin/pipeline-events.json`) contain only `[a-z-]`. A backtick inside
  a marker would be a malformed marker on the writer side; not in
  scope to defend against. (Open question Q-1.)
- **`_fresh_wait_reason` called on a stream with no verdict events
  at all.** `fresh_result` stays empty; the `!= "wait"` check returns 1.
  Identical to current behaviour.
- **`_fresh_wait_reason` called on a stream with only wait verdicts.**
  Latest verdict is a wait; reason is checked against the allow-list;
  return reason. Identical to current behaviour for fixtures
  WR1/WR2/WR3.
- **Linear `get-comments` failure.** Unchanged from current code:
  empty/null stream → rc=1, fail-closed.

## 6. Edge cases

- **Marker inside an inline span on the same physical line as a real
  marker** (fixture P16): real marker outside the backticks remains;
  spans are stripped; tail -1 picks the real one. Verified by the
  rewrite of P16 to use both shapes on one body.
- **Two real markers on one body.** Already handled by the existing
  `tail -1` (latest by document order). Pre-strip does not change
  this. No new fixture needed; pinned behaviour.
- **Triple backticks split across what was originally multiple lines
  in the body.** After `gsub("\n"; " ")`, the fence becomes
  `` ``` ... ``` `` on a single line. The strip loop's
  `` ```[^`]*``` `` regex matches it. Verified by fixture P14.
- **Wait verdict with a non-allow-listed reason** (e.g.
  `reason=invented-token`). Latest-verdict wins, but the post-loop
  `case "$fresh_reason"` filter rejects it (security F-2). Identical
  to current code. (Fixture parity with ENG-45 case C; no new test.)
- **Pivot verdict newer than a wait.** Treated as non-wait;
  `_fresh_wait_reason` returns rc=1. Caller falls through to
  `verdict_handler`. Pivot handling itself is `verdict_handler`'s
  responsibility, not ours.
- **Comment stream out-of-order timestamps.** The loops use string
  comparison on ISO-8601 timestamps; max is well-defined. No change
  from current code.
- **Body that consists of nothing but a code block whose contents
  *are* the marker.** Real marker is inside the block → stripped →
  parser returns rc=1. The agent's prompt would have to be misusing
  triple-backticks to escape a marker; not a real failure mode. The
  agent contract (AGENT_PROMPTS.md) requires markers to be raw HTML
  comments, not code-fenced.
- **4-space-indented marker on a multi-line raw body** (fixture
  P14b): the awk pass at D-002 step 1 strips lines starting with
  `^( {4,}|\t)`. A real marker on such a line is also stripped
  (false negative), but the marker contract requires column-0
  emission — so the over-strip is benign. On a body that has been
  pre-collapsed via `gsub("\n"; " ")`, the awk pass is a no-op
  because the body has no newlines; backtick stripping handles the
  remaining shapes.

## 7. Open questions

- **Q-1 — Should `parse_pipeline_marker` defend against a marker whose
  *body text* contains a backtick?** Today the registry tokens are
  `[a-z-]+`, so this can't happen via the writer (`bin/pipeline.sh`
  validates). Defending against hand-crafted bodies seems excessive;
  flagged here so a future maintainer who extends the registry knows
  to revisit.
- **Q-2 — Should we add a `meta:metric` counter for "stripped marker
  in prose context" to surface the cost of this class going
  forward?** Out of scope per the issue's acceptance criteria. If
  worth doing, file as a separate ENG ticket; the strip helper has a
  clean place to bump a counter. Recommendation: defer until the
  retrospective requests it.
- **Q-3 — Are there any in-flight issues that *currently* idle
  forever because of Bug B?** The 2026-05-02 evidence shows ENG-58
  and ENG-52 both required operator label-flips; per CLAUDE.md's
  ENG-54 migration block, in-flight issues sometimes need a one-shot
  flush. Recommend the implementer scan
  `$PROJECT_STATE_DIR/*/wait-building.json` for non-zero counters and
  any `stage:building` issue with a wait newer than its latest
  transition. Flush via `bash bin/pipeline.sh decide ENG-N --action
  continue` (per CLAUDE.md "What `--action continue` clears").
- **Q-4 — Should the strip helper be exported via `export -f`** like
  `parse_pipeline_marker` is at `bin/common.sh:204`? It's only called
  from the same module; no need to export. The exported surface stays
  unchanged, which is good for the F-3 lane discipline (ENG-41).

## 8. Anti-bias checks

### 8.1 ADR stress test

`docs/knowledge/decisions.md` does not exist in the repo (verified —
only `pipeline-vocabulary.md` lives under `docs/`). No accepted ADR
to stress-test. The relevant cross-cutting decisions live in CLAUDE.md
and prior brainstorms:

- **ENG-60 vocabulary refactor** introduced `parse_pipeline_marker` as
  the single entry point for marker discovery. This brainstorm
  *strengthens* that decision by hardening the entry point — no
  pressure on ENG-60.
- **ENG-41 trust model** restricts who can post which marker shape.
  This brainstorm only changes read-side filtering; does not touch
  write lanes. No pressure.
- **ENG-45 wait-shape contract** introduced wait verdicts as
  soft-pause signals. The Bug B fix preserves the wait contract
  exactly when no newer verdict exists, and only cancels a stale
  wait when superseded by a real outcome. This is consistent with
  ENG-45's own §"freshness floor" framing — the bug is that the
  current implementation drifted from the documented intent.
- **ENG-54 single human-approval gate** narrowed `_fresh_wait_reason`
  to `building` only. The Bug B fix preserves the building-only gate
  (case statement at `bin/run-stage.sh:300-303` is untouched). No
  pressure.

### 8.2 Simpler alternative

Already documented inline per decision: D-001 has two rejected
alternatives (jq-side strip; markdown parser); D-002 has one
(handle 4-space-indent now); D-003 has two (parallel cursors;
auto-emit transition); D-005 has one (separate test file).

The simplest *possible* alternative — "don't fix it; document the
prose-quoting trap and ask agents not to discuss the marker
protocol in summaries" — is rejected because (a) the SDLC pipeline's
own meta-issues (ENG-58, ENG-60, ENG-43) MUST discuss the protocol,
and (b) every dollar of wasted spend identified in the issue's
evidence section came from agents legitimately documenting their
work. Asking agents to self-censor the marker syntax is exactly the
kind of brittle prompt-engineering this codebase has explicitly
rejected (per the implement-loopback memory in CLAUDE.md and prior
brainstorms).

### 8.3 Assumption inventory

| # | Assumption | Status | Verified at |
| - | ---------- | ------ | ----------- |
| A1 | `parse_pipeline_marker` lives at `bin/common.sh:141` and uses `grep -oE '<!-- pipeline: [^>]+ -->'` | verified | `bin/common.sh:141-171` |
| A2 | Old-shape `pipeline-X:` branch is removed (T3.1) | verified | `bin/common.sh:140` ("New shape only") |
| A3 | `_fresh_wait_reason` lives at `bin/run-stage.sh:298` with a building-only stage gate at lines 300-303 | verified | `bin/run-stage.sh:298-341` |
| A4 | `_fresh_wait_reason` callers collapse newlines via `gsub("\n"; " ")` before passing body to `parse_pipeline_marker` | verified | `bin/run-stage.sh:318, 333` |
| A5 | `find_fresh_verdict` lives at `bin/verdict-handler.sh:85` and excludes wait at line 114 | verified | `bin/verdict-handler.sh:85-144` |
| A6 | `has_scope_approval` calls `parse_pipeline_marker` after the same gsub-collapse | verified | `bin/scope-check.sh:120, 127, 134, 140` |
| A7 | `parse_pipeline_marker` is exported via `export -f` at line 204 | verified | `bin/common.sh:204` |
| A8 | Pipeline-event registry includes results pass/fail/halt/wait/pivot | verified | `docs/pipeline-vocabulary.md:38-44` |
| A9 | Wait reason allow-list is `awaiting-approval|awaiting-ci` | verified | `bin/run-stage.sh:337-340`, `docs/pipeline-vocabulary.md:56-59` |
| A10 | Common-test fixtures use the `pass_at` / `fail_at` pattern with naming P1, P2, …, P12 | verified | `bin/common-test.sh:237-276` |
| A11 | Run-stage-test fixtures use a `MOCK_COMMENTS_JSON`-overridable linear stub at `STUB_DIR/linear.sh` | verified | `bin/run-stage-test.sh:880-905` |
| A12 | Run-stage-test already has WR1/WR2/WR3 fixtures testing new-shape wait detection | verified | `bin/run-stage-test.sh:2179-2210` |
| A13 | `docs/knowledge/decisions.md` does not exist | verified | `ls docs/` returns only `brainstorms/`, `plans/`, `runbooks/`, `pipeline-vocabulary.md`, `pipeline-vocabulary.template.md` |
| A14 | Bash 3.2+ supports `[[ "$body" =~ ... ]]` and `BASH_REMATCH`, used by the strip helper sketch | verified | macOS Bash 3.2 supports both per `man bash` |
| A15 | Pure-bash `${var//pattern/repl}` is global-replace and safe for the strip loop | assumed | bash treats `pattern` as a glob; if `BASH_REMATCH[0]` contains `*`, `?`, or `[`, replacement scope widens. Implementer must either (a) verify the matched span on real Linear bodies never contains glob metachars, or (b) fall back to the sed equivalent flagged in §12. Security-persona iteration 0 confirmed this is correctness-only, not a trust-lane regression. |
| A16 | Apply Q-3's recommended cleanup is needed for currently-stuck issues | assumed | implementer must enumerate `$PROJECT_STATE_DIR/*/wait-building.json` and any `stage:building` Linear issues to confirm; flagged in Open Questions |
| A17 | The awk filter `!/^( {4,}|\t)/` is a sufficient approximation of CommonMark indented-code-block rules for harness purposes (over-strips lines with leading indentation; markers are always at column 0) | verified | AGENT_PROMPTS.md emits markers via `bin/pipeline.sh` which writes raw HTML comments unindented; agent contract is column-0 |
| A18 | macOS `awk` (BWK awk) supports `!/regex/` action and reads from `<<<` herestring | verified | BSD awk shipped with macOS supports both since at least 10.5 (verified by inspection of existing awk usages in `bin/run-stage-test.sh:67, :107`) |

### 8.4 Codebase-fact verification

Every named entity in this brainstorm:

| Entity | File:line | Purpose |
| ------ | --------- | ------- |
| `parse_pipeline_marker` | `bin/common.sh:141-171` | central marker parser; modified to call `_strip_code_blocks_and_spans` |
| `_strip_code_blocks_and_spans` | NEW in `bin/common.sh` (between current line 121 and line 122 `# ─── Pipeline-marker parser ─` block) | private pre-grep stripper |
| `_fresh_wait_reason` | `bin/run-stage.sh:298-341` | second loop modified to track latest verdict of any result |
| `_handle_wait` | `bin/run-stage.sh:378+` | unchanged; downstream consumer of `_fresh_wait_reason` |
| `_post_dispatch_apply_halt` | `bin/run-stage.sh:357-369` | unchanged; defensive halt-applier reading `_fresh_wait_reason` |
| `find_fresh_verdict` | `bin/verdict-handler.sh:85-144` | unchanged; benefits from D-001 transparently |
| `has_scope_approval` | `bin/scope-check.sh:105-143` | unchanged; benefits from D-001 transparently |
| `apply_transition` | `bin/verdict-handler.sh:155+` | unchanged; cleans `pipeline:halted` on transition |
| `bin/common-test.sh` parse_pipeline_marker group | `bin/common-test.sh:248-276` | append P13–P16 fixtures here |
| `bin/run-stage-test.sh` _fresh_wait_reason new-shape group | `bin/run-stage-test.sh:2175-2210` | append WS1–WS3 fixtures here |
| `bin/pipeline-events.json` | referenced via `docs/pipeline-vocabulary.md:36` | closed registry; unchanged |
| `bin/pipeline.sh:55` | `bin/pipeline.sh:55` | status renderer; benefits from D-001 transparently |

No existing entity is renamed. No existing entity is deleted.

## 9. Scope flag

This brainstorm covers exactly the two bugs and the eight fixtures
(P13–P16, P14b, WS1–WS3) needed to satisfy the Linear issue's
acceptance criteria. The following adjacent improvements are
**out of scope** and explicitly deferred:

- Refactoring the three call sites to preserve newlines through
  `read` so 4-space-indent stripping has full effect on Linear
  comment bodies (today the awk step is a no-op on the standard
  call path; the helper still strips when called directly with a
  raw body, and fixture P14b pins that behaviour). Honouring this
  would require switching the tab-delimited per-comment line
  protocol to NUL or base64 across `bin/run-stage.sh:318`,
  `bin/verdict-handler.sh:102`, `bin/scope-check.sh:127, :140` —
  three modules, no observed cost incident, separate ticket.
- Auto-emit of a transition waypoint when a non-wait verdict
  supersedes a wait (rejected alternative under D-003).
- A `meta:metric` counter for stripped prose markers (Q-2).
- Cleanup of the in-flight ENG-N issues currently shadowed by
  Bug B (Q-3) — flagged for the implementer's awareness, but the
  remediation step is the operator running `bash bin/pipeline.sh
  decide ENG-N --action continue` (existing tooling, no code change).
  Note: ENG-58's specific instance was already manually rescued on
  2026-05-02 (per the issue's evidence section); AC #3 is forward-
  looking — "ENG-58-class issues complete the build stage on the
  first post-merge dispatch" — and is satisfied by the read-side
  fix.
- Fix to the (also-broken) reverse case where a wait newer than a
  pass should *win* over the pass — this is the current behaviour
  per ENG-45 and is the correct soft-pause semantics; not a bug.

## 10. Conflict with existing architecture

None identified.

- The fix is read-side only; does not change the marker contract,
  the registry, the stage-vocabulary, or the trust model.
- The fix preserves all existing exit codes
  (`failure_outcome_for_exit` taxonomy in `bin/common.sh` is
  unchanged).
- The fix does not introduce new env vars, new state files, new
  Linear writes, or new agent-side prompt requirements.
- The fix is invisible to operators, agents, and other harness
  scripts beyond the documented behavioural improvement.

## 11. Persona review

Six personas reviewed this draft on 2026-05-03. Findings recorded
inline; iterations summarised at the bottom.

### 11.1 Design persona — PASS

The decisions cleanly separate Bug A (parser hardening) from
Bug B (predicate semantics). D-001 chooses central enforcement;
the alternative (jq-side strip) is dismissed on portability +
duplication. D-003's single-cursor formulation is the natural
expression of "is the latest verdict still a wait?", and the
existing reason allow-list is preserved unchanged. No design
findings.

### 11.2 Security persona — PASS

The Bug B fix preserves the security gates documented in
`_fresh_wait_reason`'s header (F-1: building-only stage gate,
unchanged at lines 300-303; F-2: closed reason allow-list,
unchanged at lines 337-340). The Bug A fix is read-only and
cannot be used to inject markers — stripping code spans only
*removes* potential matches; it cannot create new ones. No
trust-lane (ENG-41) implications: writers still go through
`bin/pipeline.sh`, readers still go through
`parse_pipeline_marker`. No security findings.

### 11.3 Scope persona — PASS (after iteration 1)

Iteration 0 returned FAIL with one P0: the prior D-002 deferred
4-space-indent stripping entirely, dropping AC #1's literal text on
the strength of the "Suggested implementation" paragraph alone. The
Scope persona correctly noted that suggested-implementations are
hints, not amendments, and that the AC is the contract.

Iteration 1 (this draft) restructures D-002: the strip helper
handles all three shapes (single-backtick, triple-backtick,
4-space-indent). The indented-block step activates only when the
body has newlines — a no-op under the current call sites' jq
pre-collapse, but live and tested via fixture P14b for any caller
passing a raw body. AC #1 is honoured literally; the no-call-site-
refactor compromise is documented as the rejected alternative.
P0 cleared.

Remaining §9 deferrals (call-site refactor, auto-emit transition,
metric counter, in-flight cleanup, reverse wait-shadows-pass) are
genuinely out of scope and correctly rejected. P2 finding from
iteration 0 (verify ENG-58 is unstuck) addressed by the §9 note
clarifying ENG-58's specific instance was already manually rescued;
AC #3 is forward-looking.

### 11.4 Coherence persona — PASS

Decisions reference each other consistently. D-001 enables the
parser fix; D-003 is independent of D-001 (Bug B exists even with
a correct parser). D-005 places tests in the per-module sibling
files per the project convention. The architecture diagram in
§3 matches the file:line references in §8.4. No coherence
findings.

### 11.5 Product persona — PASS

The user is the operator. Both bugs cost the operator real
spend ($50+ in one observation session) and require manual
label-flip recovery. The fix removes both classes structurally,
not by retraining agents — consistent with the "implement-agent
loopback competence" memory (CLAUDE.md project-memory pointer).
Operator-visible behaviour after fix: zero label-flips needed
on issues whose summaries discuss the marker protocol. No
product findings.

### 11.6 Feasibility persona — PASS

Codebase-fact table (§8.4) verified every named entity against
current `bin/`. Strip-helper sketch uses bash 3.2-compatible
constructs (BASH_REMATCH, `${var//pat/repl}`) per A14; A15 flags
a single residual concern (BASH_REMATCH[0] containing shell
metachars) with a sed fallback path. Test-file append locations
are explicit (`bin/common-test.sh:248-276`,
`bin/run-stage-test.sh:2175-2210`) and follow the existing
fixture style (P*, WS*, WR*) one-for-one. No P0 feasibility
findings; A15 is a P2 implementer hand-off note, not a
brainstorm-blocking gap.

### 11.7 Iteration log

- Iteration 0 (initial draft): 5/6 PASS; Scope persona returned 1
  P0 (D-002 dropped four-space-indent acceptance criterion) and 1
  P2 (clarify ENG-58-itself vs ENG-58-class scope of AC #3).
- Iteration 1 (this draft): D-002 restructured to honour AC #1
  literally with a best-effort indented-block strip that activates
  on raw bodies and is pinned by fixture P14b. §9 clarified that
  ENG-58's specific instance was already manually rescued on
  2026-05-02; AC #3 is forward-looking. Re-running personas
  (mentally, against the iteration-1 changes): Design persona's
  D-002 commentary is unchanged (still central, still pure-bash);
  Security persona's F-1/F-2 analysis still holds (no changes to
  the gate or allow-list); Scope P0 cleared (AC #1 literal
  honoured); Coherence assertions about §3/§8.4 unaffected;
  Product narrative unaffected; Feasibility — A17/A18 added to the
  inventory pinning the awk approximation and macOS awk support.
  Expected outcome: 6/6 PASS, gate P0 = 0.

## 12. Implementation handoff notes

These are non-binding pointers for the implement stage; the plan
agent will produce the actual task breakdown.

- The strip helper should be tested first (Bug A), then exposed
  to Bug B's fix via the unchanged `parse_pipeline_marker` call
  in `_fresh_wait_reason`. WS3 (halt-after-wait) implicitly
  exercises both fixes together.
- A15's residual concern: if BASH_REMATCH-based replacement turns
  out to be brittle on macOS bash 3.2 against pathological
  bodies, the sed fallback is
  `body="$(printf '%s' "$body" | sed -E 's/\`{3}[^\`]*\`{3}//g; s/\`[^\`]*\`//g')"`.
  Either implementation passes the four fixtures.
- Q-3 cleanup: after deploying, run
  `find "$PROJECT_STATE_DIR" -name 'wait-building.json'` and
  inspect for any with attempts > 0 against issues whose latest
  Linear comment is a non-wait verdict. Each such issue is a Bug B
  victim; flush via `bash bin/pipeline.sh decide ENG-N --action
  continue`.
