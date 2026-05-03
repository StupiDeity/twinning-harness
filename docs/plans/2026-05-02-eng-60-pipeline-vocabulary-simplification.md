---
linear: ENG-60
topic: Pipeline vocabulary simplification — collapse markers, sigs, labels, and decision verbs into one closed event taxonomy
date: 2026-05-02
status: draft
---

# Plan — ENG-60 pipeline vocabulary simplification

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

Implementation plan for the design in
`docs/brainstorms/2026-05-02-pipeline-vocabulary-simplification-design.md`.

## Goal

Land the Level 2 vocabulary simplification across three sequential phases: **Phase 1** ships parsers that accept old AND new comment shapes (no behavior change); **Phase 2** ships the new `bin/pipeline` CLI, agent-prompt updates, and a canonical glossary (old binaries become deprecation-logging wrappers); **Phase 3** removes old-shape readers, deletes the wrappers, and runs a one-time legacy-label cleanup.

After all three phases land, every state-driving Linear comment uses `<!-- pipeline: <event> ... -->`, every bookkeeping comment uses `<!-- meta: <kind> ... -->`, the pipeline-namespace label set is `{halted, abandoned, rule-reviewed}`, stage names are gerund-tense everywhere, and `docs/pipeline-vocabulary.md` is the single source of truth.

## Architecture

The simplification is implemented in three migration phases, each its own PR, each independently reversible. Phase 1 is purely additive (parsers learn new shapes; nothing emits them yet). Phase 2 introduces the canonical writer (`bin/pipeline`) and turns the agent prompts and old binaries to use the new shapes; in-flight issues drain naturally because Phase 1's parsers still accept old shapes. Phase 3 removes the legacy paths after a soak period during which all in-flight issues complete on the new shapes.

The load-bearing decision is the introduction of `bin/common.sh::parse_pipeline_marker` — a single normalizer that translates either old-shape or new-shape markers into a uniform JSON event representation. Every consumer (verdict-handler, scope-check, run-stage's defensive paths) switches to this helper in Phase 1, which centralizes the parsing logic to one place and makes Phase 3's old-shape removal a one-line edit in the helper.

## Tech Stack

- Bash 3+ (Darwin default).
- `jq` for JSON parsing/construction.
- Harness scripts: `common.sh`, `verdict-handler.sh`, `scope-check.sh`, `run-stage.sh`, `linear.sh`, `dispatch.sh`, `halt.sh`, `post-verdict.sh`.
- Test pattern: sentinel-guarded `*-test.sh`, source target script, override `SCRIPT_DIR`/stubs post-source. See `bin/common-test.sh` and `bin/verdict-handler-test.sh` for established patterns.

## Plan horizon and structure

**Phase 1 is fully detailed below** with TDD-disciplined task decomposition.

**Phases 2 and 3 are outlined** with task lists and per-task intent, but full code sketches are intentionally deferred to follow-up plans written after Phase 1 ships. Reason: Phase 2 task shapes (especially the `bin/pipeline` CLI surface and AGENT_PROMPTS.md rewrites) are easier to specify after we observe Phase 1 in flight against real issues. Phase 3 task shapes depend on which legacy labels still exist in Linear at deploy time. This keeps the plan honest about its planning horizon.

When Phase 1 lands, append the Phase 2 detailed sub-plan to this document (or split into a sibling `docs/plans/2026-05-XX-eng-60-phase-2-write-new.md` — operator's call).

## Assumption inventory

- **A-001:** `bin/verdict-handler.sh::find_fresh_verdict` (lines 69-103 at HEAD) reads comments via `bash linear.sh get-comments`, finds the most recent `pipeline-transition` to set a freshness floor, and selects the latest comment containing `<!-- pipeline-stage-summary:`, `<!-- pipeline-rejection:`, or `<!-- pipeline-halt:`. After Phase 1 it will use `parse_pipeline_marker` instead and the per-shape contains-checks become one regex.
- **A-002:** `bin/scope-check.sh::has_scope_approval` (lines 95-119) looks for `<!-- pipeline-halt: scope-deviation -->` followed by `<!-- pipeline-decision: scope-approved -->`. NOTE: the existing code uses the reason token `scope-deviation` while `bin/common.sh::failure_outcome_for_exit:114` returns `scope-violation` for the corresponding exit code. Both tokens appear in the wild. The Phase 1 helper must accept both as synonyms; the registry in Phase 2 will canonicalize to one (`scope-violation`).
- **A-003:** `bin/run-stage.sh:736` calls `find_fresh_verdict` for the marker-emission audit (post-ENG-47 Track C). No behavior change in Phase 1 — it just gets the same answer through the new helper.
- **A-004:** The `pipeline-sig` marker is documented as **not a verdict**. `find_fresh_verdict` already excludes it. The Phase 1 helper preserves this — `parse_pipeline_marker` returns `meta` events for sig and metric markers, and consumers filter to `event=verdict` etc.
- **A-005:** The `pipeline-rejection-target` shape (used at verdict-handler.sh:107) is a separate marker from `pipeline-rejection`. The current code reads both. Phase 1's helper folds `pipeline-rejection: <stage>` + `pipeline-rejection-target: <stage>` into a single event `{event:"verdict",result:"fail",target:<stage>}`. If only `pipeline-rejection` is present without a target, the parser falls back to using the rejection's value as the target (today's behavior).
- **A-006:** `bin/common.sh` is sourced by every other script via `source "$SCRIPT_DIR/common.sh"` at the top. New helpers added there are immediately available everywhere. The sentinel pattern (`if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi`) lets `common-test.sh` source common.sh and call its functions.
- **A-007:** `bin/common-test.sh` exists (added in ENG-44) and uses the established test pattern: `PIPELINE_DRY_RUN=1`, `LINEAR_API_KEY=test-mock-key`, `STUB_DIR` for mock helpers. New tests for `parse_pipeline_marker` go here.
- **A-008:** No existing comment in Linear uses `<!-- pipeline: ` (with space) or `<!-- meta: ` as a literal prefix — verified by reading the inventory in §4 of the brainstorm doc. The new shapes are collision-free with existing shapes.

## File Structure (Phase 1)

**Create:**
- `bin/pipeline-events.json` — closed registry (no validation enforcement in Phase 1; placeholder for Phase 2's writers).

**Modify:**
- `bin/common.sh` — add `parse_pipeline_marker` helper (~50 lines).
- `bin/common-test.sh` — add 12 fixtures covering old shapes, new shapes, edge cases, mixed bodies.
- `bin/verdict-handler.sh` — replace inline marker matching in `find_fresh_verdict` with calls to `parse_pipeline_marker`.
- `bin/verdict-handler-test.sh` — add 4 fixtures asserting equivalent behavior between old and new shapes for find_fresh_verdict.
- `bin/scope-check.sh` — replace inline jq in `has_scope_approval` with `parse_pipeline_marker`-based logic; accept both `scope-deviation` and `scope-violation` halt reasons.
- `bin/scope-check-test.sh` — add 3 fixtures for new shape scope-approval, mixed-shape, reason-token aliasing.
- `bin/run-stage.sh` — `find_fresh_verdict` consumer at line ~736 gets the new helper transparently; no direct edits needed if find_fresh_verdict's contract is preserved.
- `CLAUDE.md` — one-line note in "When wiring a new script" section pointing future scripts at `parse_pipeline_marker`.

**No changes (Phase 1):**
- `AGENT_PROMPTS.md` — agents continue emitting old shapes.
- `bin/halt.sh`, `bin/post-verdict.sh` — continue writing old shapes.
- `bin/dispatch.sh` — no marker emission changes.
- All Linear labels — unchanged.

---

## Phase 1: Read both (parsers accept old + new shapes)

**Phase goal:** Every harness consumer of pipeline markers reads through `bin/common.sh::parse_pipeline_marker`, which accepts old AND new shapes and emits a uniform JSON event representation. No agent or operator-visible behavior change.

**Phase exit criteria:** All `bin/*-test.sh` tests pass. A synthetic comment using new-shape syntax produces the same `find_fresh_verdict` / `has_scope_approval` result as the equivalent old-shape comment. The Phase 1 PR can land on `main` without breaking any in-flight issue.

### Task 1.1: Create the registry stub

**Files:**
- Create: `bin/pipeline-events.json`

- [ ] **Step 1: Create the registry file**

```json
{
  "_comment": "Closed vocabulary registry for pipeline events. Phase 1 parsers use this for documentation only; Phase 2 writers will validate against it. See docs/brainstorms/2026-05-02-pipeline-vocabulary-simplification-design.md §7.4.",
  "verdict_results": ["pass", "fail", "halt", "wait", "pivot"],
  "halt_reasons": [
    "agent-blocked",
    "smoke-failed",
    "iteration-exhausted",
    "scope-violation",
    "protocol-violation",
    "dispatch-timeout",
    "pr-opened-too-early"
  ],
  "wait_reasons": ["awaiting-approval", "awaiting-ci"],
  "fail_targets": ["brainstorming", "planning", "implementing", "ui"],
  "pivot_targets": ["planning"],
  "decision_actions": ["continue", "approve", "abandon"],
  "decision_gates": ["scope", "build-cap"],
  "meta_kinds": ["dedup", "metric", "evidence"],
  "stages": [
    "brainstorming", "planning", "implementing", "ui",
    "reviewing", "qa", "building", "released"
  ],
  "legacy_halt_reason_aliases": {
    "scope-deviation": "scope-violation"
  }
}
```

- [ ] **Step 2: Validate it parses as JSON**

Run: `jq empty bin/pipeline-events.json`
Expected: exits 0 with no output.

- [ ] **Step 3: Commit**

```bash
git add bin/pipeline-events.json
git commit -m "feat(ENG-60): add pipeline-events.json closed vocabulary registry

Documentation-only in phase 1; phase 2 writers will validate against it.
Includes legacy_halt_reason_aliases to handle the existing
scope-deviation/scope-violation token inconsistency."
```

### Task 1.2: Add `parse_pipeline_marker` helper to common.sh

**Files:**
- Modify: `bin/common.sh` (append after the existing `failure_outcome_for_exit` function)
- Test: `bin/common-test.sh`

- [ ] **Step 1: Write the failing tests first**

Append to `bin/common-test.sh` before its summary block:

```bash
# ─── Group: parse_pipeline_marker (ENG-60 Phase 1) ───────────────────────

printf '\n--- parse_pipeline_marker ---\n'

# Fixture P1: new-shape verdict pass
result="$(parse_pipeline_marker '<!-- pipeline: verdict result=pass stage=implementing -->')"
[[ "$(jq -r '.event' <<<"$result")" == "verdict" ]]   && pass_at "P1: event=verdict"   || fail_at "P1: event mismatch ($result)"
[[ "$(jq -r '.result' <<<"$result")" == "pass" ]]     && pass_at "P1: result=pass"     || fail_at "P1: result mismatch"
[[ "$(jq -r '.stage' <<<"$result")" == "implementing" ]] && pass_at "P1: stage=implementing" || fail_at "P1: stage mismatch"

# Fixture P2: new-shape verdict fail
result="$(parse_pipeline_marker '<!-- pipeline: verdict result=fail target=planning -->')"
[[ "$(jq -r '.result' <<<"$result")" == "fail" ]]     && pass_at "P2: result=fail"     || fail_at "P2 ($result)"
[[ "$(jq -r '.target' <<<"$result")" == "planning" ]] && pass_at "P2: target=planning" || fail_at "P2 target"

# Fixture P3: new-shape verdict halt
result="$(parse_pipeline_marker '<!-- pipeline: verdict result=halt reason=agent-blocked -->')"
[[ "$(jq -r '.result' <<<"$result")" == "halt" ]]            && pass_at "P3: result=halt" || fail_at "P3"
[[ "$(jq -r '.reason' <<<"$result")" == "agent-blocked" ]]   && pass_at "P3: reason"     || fail_at "P3 reason"

# Fixture P4: old-shape stage-summary translates to verdict pass
result="$(parse_pipeline_marker '<!-- pipeline-stage-summary: implementing -->')"
[[ "$(jq -r '.event' <<<"$result")" == "verdict" ]]      && pass_at "P4: legacy stage-summary→verdict"  || fail_at "P4"
[[ "$(jq -r '.result' <<<"$result")" == "pass" ]]        && pass_at "P4: result=pass"                    || fail_at "P4 result"
[[ "$(jq -r '.stage' <<<"$result")" == "implementing" ]] && pass_at "P4: stage carried"                  || fail_at "P4 stage"

# Fixture P5: old-shape rejection translates to verdict fail
result="$(parse_pipeline_marker '<!-- pipeline-rejection: planning -->')"
[[ "$(jq -r '.result' <<<"$result")" == "fail" ]]        && pass_at "P5: legacy rejection→fail" || fail_at "P5"
[[ "$(jq -r '.target' <<<"$result")" == "planning" ]]    && pass_at "P5: target derived from rejection value" || fail_at "P5 target"

# Fixture P6: old-shape halt translates to verdict halt
result="$(parse_pipeline_marker '<!-- pipeline-halt: scope-deviation -->')"
[[ "$(jq -r '.result' <<<"$result")" == "halt" ]]            && pass_at "P6: legacy halt→halt" || fail_at "P6"
[[ "$(jq -r '.reason' <<<"$result")" == "scope-violation" ]] && pass_at "P6: scope-deviation aliased to scope-violation" || fail_at "P6 reason ($result)"

# Fixture P7: old-shape decision (scope-approved) translates
result="$(parse_pipeline_marker '<!-- pipeline-decision: scope-approved -->')"
[[ "$(jq -r '.event' <<<"$result")" == "decision" ]] && pass_at "P7: legacy decision→decision" || fail_at "P7"
[[ "$(jq -r '.action' <<<"$result")" == "approve" ]] && pass_at "P7: scope-approved→approve"   || fail_at "P7 action"
[[ "$(jq -r '.gate' <<<"$result")" == "scope" ]]     && pass_at "P7: gate=scope"               || fail_at "P7 gate"

# Fixture P8: old-shape decision (resume) translates
result="$(parse_pipeline_marker '<!-- pipeline-decision: resume -->')"
[[ "$(jq -r '.action' <<<"$result")" == "continue" ]] && pass_at "P8: resume→continue" || fail_at "P8"
[[ "$(jq -r '.gate // ""' <<<"$result")" == "" ]]     && pass_at "P8: no gate on continue" || fail_at "P8 gate-empty"

# Fixture P9: old-shape transition translates
result="$(parse_pipeline_marker '<!-- pipeline-transition: implementing → reviewing -->')"
[[ "$(jq -r '.event' <<<"$result")" == "transition" ]] && pass_at "P9: transition" || fail_at "P9"
[[ "$(jq -r '.from' <<<"$result")"  == "implementing" ]] && pass_at "P9: from"     || fail_at "P9 from"
[[ "$(jq -r '.to' <<<"$result")"    == "reviewing" ]]    && pass_at "P9: to"       || fail_at "P9 to"

# Fixture P10: meta-sig translates
result="$(parse_pipeline_marker '<!-- pipeline-sig: completion/implement/ENG-43 -->')"
[[ "$(jq -r '.event' <<<"$result")" == "meta" ]]   && pass_at "P10: sig→meta" || fail_at "P10"
[[ "$(jq -r '.kind' <<<"$result")" == "dedup" ]]   && pass_at "P10: kind=dedup" || fail_at "P10 kind"
[[ "$(jq -r '.key' <<<"$result")" == "completion/implement/ENG-43" ]] && pass_at "P10: key carried" || fail_at "P10 key"

# Fixture P11: comment body with surrounding prose + marker at the end
body=$'A multi-line\nbody.\n<!-- pipeline: verdict result=pass stage=implementing -->'
result="$(parse_pipeline_marker "$body")"
[[ "$(jq -r '.event' <<<"$result")" == "verdict" ]] && pass_at "P11: marker found in multi-line body" || fail_at "P11"

# Fixture P12: body with no recognizable marker returns empty + rc=1
result="$(parse_pipeline_marker 'just prose, no marker' 2>/dev/null)" && rc=0 || rc=$?
[[ "$rc" -eq 1 ]] && pass_at "P12: rc=1 on no marker" || fail_at "P12 rc=$rc"
[[ -z "$result" ]] && pass_at "P12: empty stdout" || fail_at "P12 stdout=$result"
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
TARGET_REPO=/Users/rajatgoyal/code/twinning-harness bash bin/common-test.sh
```

Expected: 12 P-prefixed FAILs ("parse_pipeline_marker: command not found").

- [ ] **Step 3: Implement `parse_pipeline_marker` in common.sh**

Append to `bin/common.sh` (after `failure_outcome_for_exit` ~line 130):

```bash
# parse_pipeline_marker <body> — translate a Linear comment body containing
# a pipeline marker (old or new shape) into a uniform JSON event.
#
# Output JSON shapes:
#   {"event":"verdict","result":"pass","stage":"implementing"}
#   {"event":"verdict","result":"fail","target":"planning"}
#   {"event":"verdict","result":"halt","reason":"agent-blocked"}
#   {"event":"verdict","result":"wait","reason":"awaiting-approval"}
#   {"event":"transition","from":"implementing","to":"reviewing"}
#   {"event":"decision","action":"approve","gate":"scope"}
#   {"event":"decision","action":"continue"}            (no gate)
#   {"event":"meta","kind":"dedup","key":"<ns/stage/issue>"}
#   {"event":"meta","kind":"metric","name":"<metric>"}
#
# Returns 0 with JSON on stdout when a marker is found.
# Returns 1 with empty stdout when no recognizable marker is in the body.
#
# Accepts BOTH old (`pipeline-X: value`) and new (`pipeline: event k=v ...`)
# shapes during phases 1-2; phase 3 simplifies to new-shape only.
parse_pipeline_marker() {
  local body="$1"
  local marker

  # New shape: `<!-- pipeline: <event> [k=v ...] -->`
  marker="$(grep -oE '<!-- pipeline: [^>]+ -->' <<<"$body" 2>/dev/null | tail -1 || true)"
  if [[ -n "$marker" ]]; then
    local payload
    payload="$(sed -E 's/<!-- pipeline: (.+) -->/\1/' <<<"$marker")"
    local event="${payload%% *}"
    local rest="${payload#$event}"
    rest="${rest# }"
    local json
    json="$(jq -nc --arg e "$event" '{event:$e}')"
    # Parse remaining `k=v` pairs (whitespace-separated).
    if [[ -n "$rest" ]]; then
      local pair k v
      for pair in $rest; do
        [[ "$pair" == *=* ]] || continue
        k="${pair%%=*}"
        v="${pair#*=}"
        json="$(jq -c --arg k "$k" --arg v "$v" '. + {($k): $v}' <<<"$json")"
      done
    fi
    printf '%s' "$json"
    return 0
  fi

  # Old shape: `<!-- pipeline-<kind>: <value> -->`
  marker="$(grep -oE '<!-- pipeline-(stage-summary|rejection|rejection-target|halt|wait|transition|decision|sig|metric): [^>]+ -->' <<<"$body" 2>/dev/null | tail -1 || true)"
  if [[ -n "$marker" ]]; then
    local kind value
    kind="$(sed -E 's/<!-- pipeline-([^:]+): .+ -->/\1/' <<<"$marker")"
    value="$(sed -E 's/<!-- pipeline-[^:]+: (.+) -->/\1/' <<<"$marker")"
    case "$kind" in
      stage-summary)
        jq -nc --arg s "$value" '{event:"verdict",result:"pass",stage:$s}' ;;
      rejection|rejection-target)
        jq -nc --arg t "$value" '{event:"verdict",result:"fail",target:$t}' ;;
      halt)
        # Apply legacy aliases (e.g. scope-deviation → scope-violation).
        local canon
        canon="$(jq -r --arg r "$value" '.legacy_halt_reason_aliases[$r] // $r' "$HARNESS_ROOT/bin/pipeline-events.json" 2>/dev/null || printf '%s' "$value")"
        jq -nc --arg r "$canon" '{event:"verdict",result:"halt",reason:$r}' ;;
      wait)
        jq -nc --arg r "$value" '{event:"verdict",result:"wait",reason:$r}' ;;
      transition)
        local from to
        from="$(sed -E 's/(.+) → .+/\1/' <<<"$value")"
        to="$(sed -E 's/.+ → (.+)/\1/' <<<"$value")"
        jq -nc --arg f "$from" --arg t "$to" '{event:"transition",from:$f,to:$t}' ;;
      decision)
        case "$value" in
          scope-approved) jq -nc '{event:"decision",action:"approve",gate:"scope"}' ;;
          scope-rejected) jq -nc '{event:"decision",action:"abandon",gate:"scope"}' ;;
          resume)         jq -nc '{event:"decision",action:"continue"}' ;;
          *)              jq -nc --arg v "$value" '{event:"decision",legacy:$v}' ;;
        esac ;;
      sig)
        jq -nc --arg k "$value" '{event:"meta",kind:"dedup",key:$k}' ;;
      metric)
        jq -nc --arg n "$value" '{event:"meta",kind:"metric",name:$n}' ;;
    esac
    return 0
  fi

  printf ''
  return 1
}
export -f parse_pipeline_marker
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
TARGET_REPO=/Users/rajatgoyal/code/twinning-harness bash bin/common-test.sh
```

Expected: all 12 P-prefixed tests PASS, plus existing tests still pass.

- [ ] **Step 5: Commit**

```bash
git add bin/common.sh bin/common-test.sh
git commit -m "feat(ENG-60): add parse_pipeline_marker helper to common.sh

Single normalizer that translates either old- or new-shape pipeline
markers into a uniform JSON event. Centralizes parsing so phase 3
can drop the legacy branch in one edit. 12 fixtures cover both
shapes plus the scope-deviation→scope-violation alias."
```

### Task 1.3: Switch `find_fresh_verdict` to use `parse_pipeline_marker`

**Files:**
- Modify: `bin/verdict-handler.sh:69-128`
- Test: `bin/verdict-handler-test.sh`

- [ ] **Step 1: Write equivalence tests first**

Append to `bin/verdict-handler-test.sh` before its summary block:

```bash
# ─── Group: find_fresh_verdict equivalence (ENG-60 Phase 1) ──────────────

printf '\n--- find_fresh_verdict accepts new-shape markers ---\n'

# Fixture FV1: new-shape stage-summary marker should be detected as fresh verdict.
COMMENTS_JSON='[
  {"id":"c1","createdAt":"2026-05-02T10:00:00Z","body":"<!-- pipeline-transition: planning → implementing -->"},
  {"id":"c2","createdAt":"2026-05-02T11:00:00Z","body":"<!-- pipeline: verdict result=pass stage=implementing -->"}
]'
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/linear.sh" <<EOF
#!/bin/bash
[[ "\$1" == "get-comments" ]] && printf '%s' '$COMMENTS_JSON'
EOF
chmod +x "$STUB_DIR/linear.sh"
_VH_SCRIPT_DIR="$STUB_DIR"
result="$(find_fresh_verdict ENG-FV1)"
[[ "$(jq -r '.marker' <<<"$result")" == "pipeline-stage-summary" || "$(jq -r '.event // ""' <<<"$result")" == "verdict" ]] \
  && pass_at "FV1: new-shape stage-summary detected" || fail_at "FV1 ($result)"

# Fixture FV2: new-shape rejection
COMMENTS_JSON='[
  {"id":"c1","createdAt":"2026-05-02T10:00:00Z","body":"<!-- pipeline-transition: implementing → reviewing -->"},
  {"id":"c2","createdAt":"2026-05-02T11:00:00Z","body":"<!-- pipeline: verdict result=fail target=planning -->"}
]'
cat > "$STUB_DIR/linear.sh" <<EOF
#!/bin/bash
[[ "\$1" == "get-comments" ]] && printf '%s' '$COMMENTS_JSON'
EOF
result="$(find_fresh_verdict ENG-FV2)"
target="$(jq -r '.target_stage // .target // ""' <<<"$result")"
[[ "$target" == "planning" ]] && pass_at "FV2: new-shape rejection target=planning" || fail_at "FV2 ($result)"

# Fixture FV3: mixed bodies — old transition, new halt — halt detected
COMMENTS_JSON='[
  {"id":"c1","createdAt":"2026-05-02T10:00:00Z","body":"<!-- pipeline-transition: planning → implementing -->"},
  {"id":"c2","createdAt":"2026-05-02T11:00:00Z","body":"<!-- pipeline: verdict result=halt reason=agent-blocked -->"}
]'
cat > "$STUB_DIR/linear.sh" <<EOF
#!/bin/bash
[[ "\$1" == "get-comments" ]] && printf '%s' '$COMMENTS_JSON'
EOF
result="$(find_fresh_verdict ENG-FV3)"
reason="$(jq -r '.reason // ""' <<<"$result")"
[[ "$reason" == "agent-blocked" ]] && pass_at "FV3: mixed-shape halt detected" || fail_at "FV3 ($result)"

# Fixture FV4: ALSO assert old-shape still works (equivalence with new)
COMMENTS_JSON='[
  {"id":"c1","createdAt":"2026-05-02T10:00:00Z","body":"<!-- pipeline-transition: planning → implementing -->"},
  {"id":"c2","createdAt":"2026-05-02T11:00:00Z","body":"<!-- pipeline-stage-summary: implementing -->"}
]'
cat > "$STUB_DIR/linear.sh" <<EOF
#!/bin/bash
[[ "\$1" == "get-comments" ]] && printf '%s' '$COMMENTS_JSON'
EOF
result="$(find_fresh_verdict ENG-FV4)"
src="$(jq -r '.source_stage // .stage // ""' <<<"$result")"
[[ "$src" == "implementing" ]] && pass_at "FV4: old-shape stage-summary still detected" || fail_at "FV4 ($result)"
```

- [ ] **Step 2: Run the test to verify FV1-FV3 fail (FV4 should pass)**

```bash
TARGET_REPO=/Users/rajatgoyal/code/twinning-harness bash bin/verdict-handler-test.sh
```

Expected: FV1, FV2, FV3 FAIL (new-shape markers not yet detected). FV4 passes.

- [ ] **Step 3: Update `find_fresh_verdict` to use `parse_pipeline_marker`**

Replace `bin/verdict-handler.sh::find_fresh_verdict` (lines 69-128) with:

```bash
find_fresh_verdict() {
  local issue="$1"
  local comments
  comments="$(bash "$_VH_SCRIPT_DIR/linear.sh" get-comments "$issue")"
  [[ -z "$comments" || "$comments" == "null" ]] && { printf ''; return 0; }

  # Find the most recent transition-event timestamp to set freshness floor.
  # Iterate comments through parse_pipeline_marker; pick max createdAt where
  # event=transition. Comments without a recognizable marker are skipped.
  local last_transition_ts=""
  local row body ts ev
  while IFS=$'\t' read -r ts body; do
    ev="$(parse_pipeline_marker "$body" 2>/dev/null || true)"
    [[ -z "$ev" ]] && continue
    if [[ "$(jq -r '.event' <<<"$ev")" == "transition" ]]; then
      [[ "$ts" > "$last_transition_ts" ]] && last_transition_ts="$ts"
    fi
  done < <(jq -r '.[] | "\(.createdAt)\t\(.body | gsub("\n"; " "))"' <<<"$comments")

  # Pick the latest verdict event with createdAt > last_transition_ts.
  local fresh_ts="" fresh_body="" fresh_id=""
  while IFS=$'\t' read -r ts id body; do
    [[ -n "$last_transition_ts" && ! "$ts" > "$last_transition_ts" ]] && continue
    ev="$(parse_pipeline_marker "$body" 2>/dev/null || true)"
    [[ -z "$ev" ]] && continue
    [[ "$(jq -r '.event' <<<"$ev")" != "verdict" ]] && continue
    if [[ "$ts" > "$fresh_ts" ]]; then
      fresh_ts="$ts"; fresh_body="$body"; fresh_id="$id"
    fi
  done < <(jq -r '.[] | "\(.createdAt)\t\(.id)\t\(.body | gsub("\n"; " "))"' <<<"$comments")

  [[ -z "$fresh_body" ]] && { printf ''; return 0; }

  # Re-parse the fresh body and project to the legacy output shape that
  # callers (apply_transition, run-stage.sh) expect:
  #   {marker, source_stage, target_stage, reason, comment_id}
  local ev_json
  ev_json="$(parse_pipeline_marker "$fresh_body")"
  local result
  result="$(jq -nc \
    --argjson e "$ev_json" \
    --arg id "$fresh_id" '
      ($e.result) as $r |
      if $r == "pass" then
        {marker:"pipeline-stage-summary", source_stage:$e.stage, target_stage:"", reason:"", comment_id:$id, event:$e}
      elif $r == "fail" then
        {marker:"pipeline-rejection", source_stage:"", target_stage:$e.target, reason:"", comment_id:$id, event:$e}
      elif $r == "halt" then
        {marker:"pipeline-halt", source_stage:"", target_stage:"", reason:$e.reason, comment_id:$id, event:$e}
      elif $r == "wait" then
        {marker:"pipeline-wait", source_stage:"", target_stage:"", reason:$e.reason, comment_id:$id, event:$e}
      else
        {marker:"unknown", source_stage:"", target_stage:"", reason:"", comment_id:$id, event:$e}
      end')"
  printf '%s' "$result"
}
```

- [ ] **Step 4: Run the test to verify all fixtures pass**

```bash
TARGET_REPO=/Users/rajatgoyal/code/twinning-harness bash bin/verdict-handler-test.sh
```

Expected: FV1-FV4 all PASS. All pre-existing verdict-handler tests still PASS.

- [ ] **Step 5: Commit**

```bash
git add bin/verdict-handler.sh bin/verdict-handler-test.sh
git commit -m "feat(ENG-60): find_fresh_verdict uses parse_pipeline_marker

Replaces inline contains-checks + per-shape regex extraction with a
single helper call. New-shape markers (\`<!-- pipeline: verdict ... -->\`)
are now detected. Legacy shape continues to work; output JSON keeps the
same {marker, source_stage, target_stage, reason, comment_id} contract
plus a new \`event\` field carrying the normalized JSON for forward use."
```

### Task 1.4: Switch `has_scope_approval` to use `parse_pipeline_marker`

**Files:**
- Modify: `bin/scope-check.sh:101-119`
- Test: `bin/scope-check-test.sh`

- [ ] **Step 1: Write the equivalence tests**

Append to `bin/scope-check-test.sh` before its summary block:

```bash
# ─── Group: has_scope_approval new-shape detection (ENG-60 Phase 1) ─────

printf '\n--- has_scope_approval accepts new-shape decision ---\n'

# Fixture HSA1: new-shape decision approve gate=scope after old halt
COMMENTS_JSON='[
  {"id":"c1","createdAt":"2026-05-02T10:00:00Z","body":"<!-- pipeline-halt: scope-deviation -->"},
  {"id":"c2","createdAt":"2026-05-02T11:00:00Z","body":"<!-- pipeline: decision action=approve gate=scope -->"}
]'
cat > "$STUB_DIR/linear.sh" <<EOF
#!/bin/bash
[[ "\$1" == "get-comments" ]] && printf '%s' '$COMMENTS_JSON'
EOF
SCRIPT_DIR="$STUB_DIR"  # has_scope_approval reads via $SCRIPT_DIR/linear.sh
has_scope_approval ENG-HSA1 && pass_at "HSA1: new-shape approve detected" || fail_at "HSA1"

# Fixture HSA2: new-shape halt + new-shape decision approve
COMMENTS_JSON='[
  {"id":"c1","createdAt":"2026-05-02T10:00:00Z","body":"<!-- pipeline: verdict result=halt reason=scope-violation -->"},
  {"id":"c2","createdAt":"2026-05-02T11:00:00Z","body":"<!-- pipeline: decision action=approve gate=scope -->"}
]'
cat > "$STUB_DIR/linear.sh" <<EOF
#!/bin/bash
[[ "\$1" == "get-comments" ]] && printf '%s' '$COMMENTS_JSON'
EOF
has_scope_approval ENG-HSA2 && pass_at "HSA2: new-shape halt+approve detected" || fail_at "HSA2"

# Fixture HSA3: pure-old-shape continues to work (regression)
COMMENTS_JSON='[
  {"id":"c1","createdAt":"2026-05-02T10:00:00Z","body":"<!-- pipeline-halt: scope-deviation -->"},
  {"id":"c2","createdAt":"2026-05-02T11:00:00Z","body":"<!-- pipeline-decision: scope-approved -->"}
]'
cat > "$STUB_DIR/linear.sh" <<EOF
#!/bin/bash
[[ "\$1" == "get-comments" ]] && printf '%s' '$COMMENTS_JSON'
EOF
has_scope_approval ENG-HSA3 && pass_at "HSA3: pure-old shape regression" || fail_at "HSA3"
```

- [ ] **Step 2: Run tests to verify HSA1, HSA2 fail (HSA3 passes)**

```bash
TARGET_REPO=/Users/rajatgoyal/code/twinning-harness bash bin/scope-check-test.sh
```

Expected: HSA1 and HSA2 FAIL; HSA3 PASS.

- [ ] **Step 3: Replace `has_scope_approval` to use `parse_pipeline_marker`**

Replace `bin/scope-check.sh::has_scope_approval` (lines 101-119) with:

```bash
has_scope_approval() {
  local issue="$1"
  [[ -n "$issue" ]] || die "has-scope-approval: issue id required"
  local comments
  comments="$(bash "$SCRIPT_DIR/linear.sh" get-comments "$issue")"
  [[ -z "$comments" || "$comments" == "null" ]] && return 1

  # Find latest scope-related halt (any token: scope-deviation, scope-violation).
  local last_halt_ts=""
  local ts body ev result reason
  while IFS=$'\t' read -r ts body; do
    ev="$(parse_pipeline_marker "$body" 2>/dev/null || true)"
    [[ -z "$ev" ]] && continue
    [[ "$(jq -r '.event' <<<"$ev")" != "verdict" ]] && continue
    [[ "$(jq -r '.result' <<<"$ev")" != "halt" ]] && continue
    reason="$(jq -r '.reason' <<<"$ev")"
    case "$reason" in scope-violation|scope-deviation) ;; *) continue ;; esac
    [[ "$ts" > "$last_halt_ts" ]] && last_halt_ts="$ts"
  done < <(jq -r '.[] | "\(.createdAt)\t\(.body | gsub("\n"; " "))"' <<<"$comments")
  [[ -z "$last_halt_ts" ]] && return 1

  # Find the latest decision approve gate=scope newer than that halt.
  local approved_ts=""
  while IFS=$'\t' read -r ts body; do
    [[ ! "$ts" > "$last_halt_ts" ]] && continue
    ev="$(parse_pipeline_marker "$body" 2>/dev/null || true)"
    [[ -z "$ev" ]] && continue
    [[ "$(jq -r '.event' <<<"$ev")" != "decision" ]] && continue
    [[ "$(jq -r '.action' <<<"$ev")" != "approve" ]] && continue
    [[ "$(jq -r '.gate // ""' <<<"$ev")" != "scope" ]] && continue
    [[ "$ts" > "$approved_ts" ]] && approved_ts="$ts"
  done < <(jq -r '.[] | "\(.createdAt)\t\(.body | gsub("\n"; " "))"' <<<"$comments")

  [[ -n "$approved_ts" ]]
}
```

- [ ] **Step 4: Run tests to verify HSA1-HSA3 all pass**

```bash
TARGET_REPO=/Users/rajatgoyal/code/twinning-harness bash bin/scope-check-test.sh
```

Expected: HSA1, HSA2, HSA3 all PASS. Existing scope-check tests still PASS.

- [ ] **Step 5: Commit**

```bash
git add bin/scope-check.sh bin/scope-check-test.sh
git commit -m "feat(ENG-60): has_scope_approval uses parse_pipeline_marker

Recognizes both old (\`pipeline-decision: scope-approved\` after
\`pipeline-halt: scope-deviation\`) and new (\`pipeline: decision
action=approve gate=scope\` after \`pipeline: verdict result=halt
reason=scope-violation\`) shapes. The reason-token alias from
pipeline-events.json (scope-deviation→scope-violation) is honored in
the helper, so this script doesn't need to know the alias."
```

### Task 1.5: Verify `run-stage.sh` defensive paths through equivalence

**Files:**
- Modify: none (run-stage.sh's `find_fresh_verdict` consumer at line ~736 already uses the helper transitively).
- Test: `bin/run-stage-test.sh` — add one fixture asserting the marker-emission audit detects new-shape markers.

- [ ] **Step 1: Write the test**

Append to `bin/run-stage-test.sh` before its summary block:

```bash
# ─── Group: marker-emission audit accepts new-shape (ENG-60 Phase 1) ─────

printf '\n--- marker-emission audit detects new-shape verdict ---\n'

# Fixture MEA1: a comment with new-shape verdict pass should NOT trigger
# the defensive halt-add path (because find_fresh_verdict returns non-empty).
COMMENTS_JSON='[
  {"id":"c1","createdAt":"2026-05-02T10:00:00Z","body":"<!-- pipeline-transition: planning → implementing -->"},
  {"id":"c2","createdAt":"2026-05-02T11:00:00Z","body":"<!-- pipeline: verdict result=pass stage=implementing -->"}
]'
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/linear.sh" <<EOF
#!/bin/bash
[[ "\$1" == "get-comments" ]] && printf '%s' '$COMMENTS_JSON'
EOF
_VH_SCRIPT_DIR="$STUB_DIR"
result="$(find_fresh_verdict ENG-MEA1)"
[[ -n "$result" ]] && pass_at "MEA1: new-shape pass detected for marker-emission audit" || fail_at "MEA1"
[[ "$(jq -r '.event.result' <<<"$result")" == "pass" ]] && pass_at "MEA1: result=pass via event field" || fail_at "MEA1 result"
```

- [ ] **Step 2: Run the test**

```bash
TARGET_REPO=/Users/rajatgoyal/code/twinning-harness bash bin/run-stage-test.sh
```

Expected: MEA1 PASS (because Task 1.3 already wired find_fresh_verdict to parse_pipeline_marker, run-stage.sh's defensive path inherits the new behavior).

- [ ] **Step 3: Commit**

```bash
git add bin/run-stage-test.sh
git commit -m "test(ENG-60): assert marker-emission audit detects new-shape verdict

run-stage.sh's defensive halt-add path consumes find_fresh_verdict
transitively. After Task 1.3 wired find_fresh_verdict to
parse_pipeline_marker, this test confirms the consumer inherits the
new shape support without any direct edit to run-stage.sh."
```

### Task 1.6: Document `parse_pipeline_marker` in CLAUDE.md

**Files:**
- Modify: `CLAUDE.md` (the "When wiring a new script" section)

- [ ] **Step 1: Add a single bullet under "When wiring a new script"**

Find the bulleted list under `## When wiring a new script` (around line 220) and append:

```markdown
- For any new script that reads pipeline markers from Linear comments, use
  `parse_pipeline_marker` from `bin/common.sh` rather than hand-rolling
  contains-checks or regex extraction. The helper accepts both legacy
  (`pipeline-X: value`) and current (`pipeline: event k=v`) shapes and
  returns a uniform JSON event. This is the single source of truth for
  marker parsing — see `docs/pipeline-vocabulary.md` (post-Phase 2) for
  the event schema.
```

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs(ENG-60): point future scripts at parse_pipeline_marker

One-line guidance in the \"When wiring a new script\" section so future
contributors don't hand-roll marker parsing."
```

### Task 1.7: Phase 1 integration smoke

- [ ] **Step 1: Run the full test suite**

```bash
TARGET_REPO=/Users/rajatgoyal/code/twinning-harness bash bin/common-test.sh
TARGET_REPO=/Users/rajatgoyal/code/twinning-harness bash bin/verdict-handler-test.sh
TARGET_REPO=/Users/rajatgoyal/code/twinning-harness bash bin/scope-check-test.sh
TARGET_REPO=/Users/rajatgoyal/code/twinning-harness bash bin/run-stage-test.sh
TARGET_REPO=/Users/rajatgoyal/code/twinning-harness bash bin/halt-sprawl-test.sh
TARGET_REPO=/Users/rajatgoyal/code/twinning-harness bash bin/verdict-adversarial-test.sh
TARGET_REPO=/Users/rajatgoyal/code/twinning-harness bash bin/halt-sprawl-adversarial-test.sh
```

Expected: every test file exits 0 with all PASS.

- [ ] **Step 2: Smoke-test against a synthetic worktree**

```bash
mkdir -p /tmp/eng-60-smoke && cd /tmp/eng-60-smoke
git init -q && git commit --allow-empty -qm bootstrap
# Source common.sh and exercise parse_pipeline_marker directly.
HARNESS_ROOT=/Users/rajatgoyal/code/twinning-harness \
TARGET_REPO=/tmp/eng-60-smoke \
bash -c 'source /Users/rajatgoyal/code/twinning-harness/bin/common.sh
parse_pipeline_marker "<!-- pipeline: verdict result=pass stage=implementing -->"
echo
parse_pipeline_marker "<!-- pipeline-stage-summary: implementing -->"
echo'
```

Expected: two JSON lines printed, each with `{"event":"verdict","result":"pass","stage":"implementing"}`.

- [ ] **Step 3: Phase 1 PR — push and open**

```bash
git push -u origin feat/eng-60-pipeline-vocabulary-simplification
gh pr create --base main --title "feat(ENG-60): phase 1 — parsers accept old + new pipeline marker shapes" --body "$(cat <<'EOF'
## Summary
- Adds `bin/pipeline-events.json` registry (documentation-only in this phase).
- Adds `bin/common.sh::parse_pipeline_marker` — single normalizer for old + new pipeline marker shapes.
- Switches `verdict-handler.sh::find_fresh_verdict` and `scope-check.sh::has_scope_approval` to use the helper.
- 12 new fixtures in `common-test.sh`; 4 in `verdict-handler-test.sh`; 3 in `scope-check-test.sh`; 1 in `run-stage-test.sh`.

No agent or operator-visible behavior change. Phase 2 (writers) follows in a subsequent PR.

Spec: `docs/brainstorms/2026-05-02-pipeline-vocabulary-simplification-design.md`.
Plan: `docs/plans/2026-05-02-eng-60-pipeline-vocabulary-simplification.md`.

## Test plan
- [ ] All `bin/*-test.sh` pass on the branch.
- [ ] Smoke a real implement-stage tick on a small issue; observe marker-emission audit log line still fires correctly.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Expected: PR opens; CI (if any) passes; reviewer can manually verify by running the test commands above.

---

## Phase 2: Write new (deferred detail)

**Phase goal:** New-shape markers become canonical. `bin/pipeline` CLI lands as the canonical writer; `bin/halt.sh` and `bin/post-verdict.sh` become deprecation-logging wrappers; agent prompts in `AGENT_PROMPTS.md` switch to new shapes; stage names align to gerund tense everywhere; `docs/pipeline-vocabulary.md` is generated and `CLAUDE.md` links to it. Pipeline-namespace label cleanup happens issue-by-issue as the orchestrator transitions each issue.

**Phase exit criteria:** Every new comment written by the harness uses the new shape. In-flight issues continue to drain because Phase 1's parsers still accept old shapes. After a 1-week soak with no issue stuck on legacy shapes, Phase 3 can begin.

### Phase 2 task outline

Each task gets a full TDD-disciplined sub-plan in a follow-up document
(`docs/plans/2026-05-XX-eng-60-phase-2-write-new.md`) written after Phase 1 PR
merges. Sketches:

> **Carryover from Phase 1 Task 1.3:** new-shape `verdict result=fail target=X`
> markers do not carry `source_stage`. Old-shape two-marker rejections still
> work via the `rejection_src` grep added in `find_fresh_verdict`. When Phase 2
> teaches agents to emit new-shape rejections, `verdict_handler`'s rejection
> branch must fall back to the issue's current `stage:*` label when
> `source_stage` is empty — otherwise `_vh_lookup_loopback` will fail and the
> dispatch will silently halt as a protocol violation. Capture this as an
> explicit acceptance criterion in T2.8 (AGENT_PROMPTS.md verdict-marker
> rewrite) and T2.10 (legacy-label cleanup, where the loopback table is touched).
>
> **Carryover from Phase 1 Task 1.4 (code-quality review):**
> 1. `parse_pipeline_marker` normalizes OLD-shape halt reasons through
>    `legacy_halt_reason_aliases` (e.g., `scope-deviation` → `scope-violation`)
>    but NOT new-shape halts. A new-shape `verdict result=halt
>    reason=scope-deviation` would carry the legacy token verbatim. Phase 2
>    must extend the alias normalization to the new-shape branch of
>    `parse_pipeline_marker`. Until then, `has_scope_approval` accepts both
>    tokens defensively (load-bearing, not redundant — see comment in code).
> 2. Add interleaved-marker edge case to `bin/scope-check-test.sh`: a body
>    sequence containing BOTH old-shape halt and new-shape halt followed by a
>    new-shape decision approve, to confirm the timestamp ordering still
>    selects the correct latest events.
> 3. Test-helper-signature divergence across `bin/*-test.sh` files
>    (`pass_at`/`fail_at` are 1-arg in `common-test.sh`, 2-arg in
>    `scope-check-test.sh` and `verdict-handler-test.sh`). Phase 2 should
>    unify on the 2-arg form (more diagnosable) and update the 1-arg sites
>    in a mechanical sweep.
>
> **Carryover from Phase 1 final review:**
> 4. `bin/run-stage.sh::_fresh_wait_reason` (lines 306–334) uses inline
>    `contains("<!-- pipeline-transition:")` and `test("<!-- pipeline-wait: ")`
>    to detect wait markers. It will silently miss new-shape `<!-- pipeline:
>    verdict result=wait ... -->` comments. T2.8 (AGENT_PROMPTS.md rewrite)
>    will cause the build agent to emit new-shape wait markers, which would
>    immediately break the build-stage wait flow — the most user-visible halt
>    path. **This is a hard prerequisite of T2.8** and must be ordered before
>    the prompt rewrite ships, OR `_fresh_wait_reason` must be migrated to
>    `parse_pipeline_marker` in the same PR. Phase 1 ships FV5 to pin the
>    invariant in `find_fresh_verdict`; an analogous fixture for
>    `_fresh_wait_reason` belongs in the Phase 2 task that touches it.

- **T2.1** — Create `bin/pipeline.sh` skeleton with `status <issue>` subcommand. Read-only; calls `parse_pipeline_marker` per comment to produce a human-readable event log.
- **T2.2** — Add `bin/pipeline event <issue> verdict <pass|fail|halt|wait|pivot> [args]` subcommand. Writes `<!-- pipeline: verdict result=... -->` markers via `linear.sh add-comment`. Validates against `bin/pipeline-events.json`.
- **T2.3** — Add `bin/pipeline event <issue> transition <from→to>` subcommand. Same pattern; lane-fenced (`PIPELINE_WRITER=orchestrator`).
- **T2.4** — Add `bin/pipeline decide <issue> --action <continue|approve|abandon> [--gate <gate>]` subcommand. Lane-fenced (`PIPELINE_WRITER=human`).
- **T2.5** — Add `bin/pipeline-test.sh` with end-to-end fixtures covering each subcommand against a stub `linear.sh`.
- **T2.6** — Convert `bin/halt.sh::resolve` into a deprecation wrapper that translates `--decision <X>` to the new `bin/pipeline decide` invocation and logs `[deprecated] use 'bin/pipeline decide ...' instead`.
- **T2.7** — Convert `bin/post-verdict.sh` into a deprecation wrapper.
- **T2.8** — Rewrite `AGENT_PROMPTS.md` "Verdict-marker protocol" preamble to describe new shapes; update each stage section to emit new shapes.
- **T2.9** — Align stage names to gerund tense everywhere — function names in `bin/*.sh` (where mismatched), CLI args in `bin/run-stage.sh` and `bin/post-verdict.sh` wrappers (with one-release alias accepting verb form). Decide during execution whether to do as one PR or split — see Q2 in the brainstorm §10.
- **T2.10** — Add legacy-label cleanup to the orchestrator's label-application path (`bin/verdict-handler.sh::apply_transition`): on every `add-label` call, also `remove-label` for the legacy pipeline-namespace labels (`paused`, `scope-approval-needed`, `supersede`, `skip-until-code-changes`, `skip-until-human-acts`).
- **T2.11** — Create `bin/generate-vocabulary-doc.sh` that reads `bin/pipeline-events.json` and produces `docs/pipeline-vocabulary.md` with one section per event family + worked examples (the worked examples are hand-written in a template; only the registry-derived sections are generated).
- **T2.12** — Generate and commit `docs/pipeline-vocabulary.md`. Update `CLAUDE.md` to remove inline vocabulary explanations and link to the glossary.
- **T2.13** — Phase 2 deploy gate: operator validates manually by running the harness against a small issue end-to-end; observes new-shape markers being emitted; observes legacy labels being cleaned up on transition.

### Phase 2 acceptance criteria

1. Every Linear comment posted by `bin/pipeline event` matches the new shape regex `<!-- pipeline: <event> [k=v ...] -->`.
2. Registry validation: writing an unknown halt reason / decision action / etc. exits non-zero with a precise error.
3. `bin/halt.sh` and `bin/post-verdict.sh` keep working but emit a single `[deprecated]` log line per invocation.
4. `AGENT_PROMPTS.md` no longer references `pipeline-stage-summary:`, `pipeline-rejection:`, `pipeline-halt:`, `pipeline-wait:` directly except in a "legacy shape" appendix that's removed in Phase 3.
5. `docs/pipeline-vocabulary.md` exists and is internally consistent with `bin/pipeline-events.json`.
6. `CLAUDE.md` links to the glossary instead of explaining vocabulary inline.

---

## Phase 3: Drop old

**Phase goal:** Remove old-shape readers, delete the wrapper binaries, run the one-time legacy-label cleanup script. After Phase 3 lands, the codebase has exactly one vocabulary.

**Phase exit criteria:** No code in `bin/*.sh` references any of the legacy marker shapes. `bin/halt.sh` and `bin/post-verdict.sh` no longer exist. No issue in Linear has any of the dropped legacy labels. `docs/pipeline-vocabulary.md` no longer mentions migration shims.

**Detailed sub-plan:** see `docs/plans/2026-05-03-eng-60-phase-3-drop-old.md`. The original outline below is preserved for context; the sub-plan supersedes it with TDD-disciplined task decomposition and the additional carryovers surfaced during Phase 2 implementation reviews.

### Phase 3 task outline (superseded by sub-plan — kept for context)

- **T3.1** — Edit `bin/common.sh::parse_pipeline_marker` to remove the legacy-shape branch (the entire second `marker=...|sed...|case` block). The function now only handles `<!-- pipeline: <event> ... -->`.
- **T3.2** — Update `bin/common-test.sh` — delete fixtures P4-P10 (legacy-shape tests). Verify P1-P3, P11, P12 still pass with the simplified helper.
- **T3.3** — Delete `bin/halt.sh` and `bin/post-verdict.sh` (the wrappers). Update `CLAUDE.md`'s "Common commands" section to remove their invocations.
- **T3.4** — Create `bin/migrate-labels.sh` admin script that: lists all issues in the harness Linear project; for each issue, calls `linear.sh remove-label <issue> <legacy-label>` for each of `pipeline:paused`, `pipeline:scope-approval-needed`, `pipeline:supersede`, `pipeline:skip-until-code-changes`, `pipeline:skip-until-human-acts`. Idempotent: removing an absent label is a no-op.
- **T3.5** — Operator runs `bin/migrate-labels.sh`. (Manual step — script is run once.)
- **T3.6** — Remove deprecation log lines from `bin/pipeline.sh` (the wrappers are gone, so the log lines were Phase 2 cushioning that no longer applies).
- **T3.7** — Update `docs/pipeline-vocabulary.md` to remove the "Migration notes" section.

### Phase 3 carryovers from Phase 2 reviews (also covered in the sub-plan)

These additional removals were surfaced during Phase 2 implementation and reviews:

- **C-T3.A** — Remove verb-form aliases from `bin/render-prompt.sh::_normalize_stage` and the equivalent `case` block at the top of `bin/run-stage.sh::main` (T2.12 added these as a one-release migration shim).
- **C-T3.B** — Remove the verb-form case arms from `bin/dispatch.sh::allowed_tools_for` (the `brainstorm)`, `plan)`, `implement)`, `review)`, `build)`, `release)` arms that recurse into the gerund form). Also remove the `_dispatch_tools_extras` verb-form key fallback (`legacy_halt_reason_aliases`-style block added in T2.12's regression fix).
- **C-T3.C** — Remove the dual-form (`brainstorm|brainstorming`) case arms from `bin/run-local.sh` (reconcile link), `bin/run-local-helpers.sh` (`stage_output_paths`, `assert_stage_allowlist_coverage`, `partition_dirty_paths`), and `bin/reconcile.sh`.
- **C-T3.D** — Remove `bin/render-pr-body.sh::impl_summary` verb-form fallback (`implement` lookup after `implementing` returned empty).
- **C-T3.E** — Remove the `rejection_src` grep block in `bin/verdict-handler.sh::find_fresh_verdict` (Phase 1 T1.3 added it for old-shape rejections; new-shape rejections rely on the T2.2 `stage:*` label fallback).
- **C-T3.F** — Remove the defensive `scope-deviation` acceptance in `bin/scope-check.sh::has_scope_approval`'s `case` statement (T2.0 normalizes new-shape halt reasons through `legacy_halt_reason_aliases` so the canonical `scope-violation` is the only token reaching the consumer).
- **C-T3.G** — Delete `bin/post-verdict-test.sh` along with the wrapper itself (the test exists only to exercise the wrapper). Or rewrite it as a thin smoke against `bin/pipeline.sh` if regression coverage is wanted for the legacy-translation case.
- **C-T3.H** — Remove the `post_verdict()` shim function from `bin/post-verdict.sh` (added in Phase 2 to keep the test suite green; goes with the wrapper).
- **C-T3.I** — Remove the `legacy_halt_reason_aliases` map from `bin/pipeline-events.json` (no longer consulted once the old-shape branch in `parse_pipeline_marker` is removed and `parse_pipeline_marker`'s new-shape alias-normalization step is also removed — see C-T3.J).
- **C-T3.J** — Remove the new-shape alias-normalization step in `parse_pipeline_marker` that T2.0 added (became unnecessary once the registry stops listing legacy aliases — agents only emit canonical tokens via `bin/pipeline.sh`'s registry validation).

### Phase 3 acceptance criteria

1. `grep -rn "pipeline-stage-summary\|pipeline-rejection:\|pipeline-halt:\|pipeline-wait:\|pipeline-decision:\|pipeline-sig:\|pipeline-metric:" bin/ docs/ AGENT_PROMPTS.md CLAUDE.md` returns zero matches in functional code (matches in changelog/notes are fine).
2. `bin/halt.sh` and `bin/post-verdict.sh` do not exist as files.
3. `bash bin/linear.sh list-labels --project harness` shows no legacy pipeline-namespace labels in active use.
4. All `bin/*-test.sh` tests pass.

---

## Cross-phase considerations

### Backwards compatibility window

Phase 1 ships parsers that read both shapes. Phase 2 ships writers that emit new shapes (and wrapper binaries that translate old CLI invocations to new). Phase 3 removes the legacy paths.

The window where both shapes coexist in Linear is bounded by:
- **Lower bound:** Phase 2 PR merge time.
- **Upper bound:** Phase 3 PR merge time, plus the soak period (~1 week).

In-flight issues during this window may carry a mix of old-shape and new-shape comments. The Phase 1 parsers handle this transparently; no manual remediation needed.

### Rollback

Each phase is its own PR. To roll back:
- **Phase 1 rollback:** revert the PR. Parsers go back to handling only old shapes; nothing was emitting new shapes yet, so no orphan comments.
- **Phase 2 rollback:** revert the PR. Agents go back to emitting old shapes. New-shape comments already in Linear are still readable by Phase 1 parsers; they just won't be emitted anymore.
- **Phase 3 rollback:** revert the PR. Legacy-label removal is harder to reverse (legacy labels would have to be re-applied manually), but this only affects historical-context labels, not pipeline behavior.

### Test discipline

Every task in Phase 1 follows TDD: write the failing test, verify it fails, implement, verify it passes, commit. Phase 2 and Phase 3 inherit the same discipline; the deferred detail will preserve the pattern.

---

## Self-review checklist (executed inline by author)

- **Spec coverage:** Every section §7.1–§7.9 of the brainstorm doc maps to a task in this plan. The closed registry (§7.4) → T1.1. The two-family split (§7.1, §7.3) → T1.2 + T2.1–T2.4. The label collapse (§7.5) → T2.10 + T3.4. The CLI (§7.6) → T2.1–T2.7. Stage tense (§7.7) → T2.9. Glossary (§7.8) → T2.11–T2.12. Migration (§7.9) → the three-phase structure itself.
- **Placeholder scan:** No "TBD"/"TODO" in Phase 1. Phases 2 and 3 are explicitly marked as outlines pending full sub-plans after Phase 1 ships — this is a deliberate planning-horizon limit, not a placeholder gap.
- **Type consistency:** `parse_pipeline_marker` output JSON shape is consistent across T1.2's definition, T1.3's consumer rewrite, T1.4's consumer rewrite, and T1.5's test. The `event.result` / `event.action` / `event.kind` discriminator is uniform throughout.

---

## References

- Spec: `docs/brainstorms/2026-05-02-pipeline-vocabulary-simplification-design.md` — single source of truth for design decisions.
- Branch: `feat/eng-60-pipeline-vocabulary-simplification` (commit 99836e0 carries the spec).
- Linear: ENG-60 (this issue).
- Related (for migration shape): ENG-23 (env-var rename), ENG-49 (productionization), ENG-56 (orchestrator-canonical halt applier).
