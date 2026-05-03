---
linear: ENG-60
topic: Pipeline vocabulary simplification — Phase 2 (write new)
date: 2026-05-03
status: draft
---

# Plan — ENG-60 Phase 2: write new

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

Implementation plan for Phase 2 of the design in
`docs/brainstorms/2026-05-02-pipeline-vocabulary-simplification-design.md`,
following Phase 1 (parsers accept both shapes) which shipped on
`feat/eng-60-pipeline-vocabulary-simplification` HEAD `0414536`.

## Goal

Make new-shape markers canonical. Land `bin/pipeline` as the single CLI for
emitting pipeline events; convert `bin/halt.sh` and `bin/post-verdict.sh` into
deprecation-logging wrappers; rewrite `AGENT_PROMPTS.md` so every stage agent
emits new-shape markers; align stage names to gerund tense everywhere; add
legacy-label cleanup to the orchestrator; ship a generated `docs/pipeline-vocabulary.md`
glossary; close the four carryover gaps Phase 1 surfaced before any agent
starts emitting new shapes that depend on them.

After Phase 2, every comment the harness writes uses `<!-- pipeline: <event>
... -->` (state-driving) or `<!-- meta: <kind> ... -->` (bookkeeping). In-flight
issues continue to drain because Phase 1's `parse_pipeline_marker` still accepts
old shapes.

## Architecture

The phase has four cohorts of work:

1. **Carryover prerequisites** (T2.0–T2.3) close gaps the Phase 1 final review
   surfaced. They are predecessors to the writer work because the writers will
   emit shapes that exercise these code paths.
2. **`bin/pipeline` CLI** (T2.4–T2.8) is the new canonical writer. It validates
   every event against `bin/pipeline-events.json` and lane-fences according to
   `PIPELINE_WRITER`.
3. **Wrappers + prompt rewrite + gerund + label cleanup** (T2.9–T2.13) flip
   every emitter — operator CLIs, agent prompts, the orchestrator — to use the
   new vocabulary.
4. **Glossary + deploy gate** (T2.14–T2.16) document the new vocabulary
   canonically and verify the migration end-to-end before Phase 3 begins.

Each task is its own commit (red+green pair for code tasks, single commit for
docs). The full phase is one PR off `feat/eng-60-pipeline-vocabulary-simplification`,
or split into 2–3 PRs if review pace requires.

## Tech Stack

- Bash 3+ (Darwin default).
- `jq` for JSON parsing/construction.
- `gh` CLI for any GitHub-side reads (none expected in this phase).
- Harness scripts: `common.sh`, `verdict-handler.sh`, `scope-check.sh`,
  `run-stage.sh`, `linear.sh`, `dispatch.sh`, `halt.sh`, `post-verdict.sh`,
  `metrics.sh`, `render-prompt.sh`.
- Test pattern: sentinel-guarded `*-test.sh`, source target script, override
  `SCRIPT_DIR`/stubs post-source.

## Plan horizon

This document fully details Phase 2 (16 tasks). Phase 3 (drop old) remains
outlined in the parent plan
(`docs/plans/2026-05-02-eng-60-pipeline-vocabulary-simplification.md` §"Phase 3:
Drop old (deferred detail)") and will be expanded in a follow-up
`docs/plans/2026-05-XX-eng-60-phase-3-drop-old.md` after Phase 2 ships and
soaks for one week.

## Assumption inventory

- **A-001:** `parse_pipeline_marker` (Phase 1, `bin/common.sh:122-216`) is the
  single normalizer. Phase 2 writers DO NOT bypass it; consumers continue to use
  it transparently.
- **A-002:** `bin/pipeline-events.json` (Phase 1, `bin/pipeline-events.json`)
  is the closed registry. New halt reasons / decision actions / etc. are added
  ONLY by editing this file — never by silent code drift. Phase 2's writers
  validate against it.
- **A-003:** `bin/halt.sh` (current) accepts `--decision
  <scope-approved|scope-rejected|resume>` and posts `<!-- pipeline-decision: X
  -->`. After Phase 2 it becomes a wrapper that translates to
  `bin/pipeline decide --action <continue|approve|abandon> [--gate scope]` and
  emits a one-line deprecation log.
- **A-004:** `bin/post-verdict.sh` (current) accepts `<issue> <kind> <stage>
  [<reason>]` where `kind ∈ {stage-summary, rejection, halt}`. After Phase 2
  it becomes a wrapper that translates to `bin/pipeline event verdict
  <pass|fail|halt> [args]`.
- **A-005:** `bin/run-stage.sh::_fresh_wait_reason` (lines 306–334 currently)
  uses inline `contains("<!-- pipeline-wait: ")` — it WILL miss new-shape wait
  markers. Migration to `parse_pipeline_marker` is **T2.1, before T2.11**
  (the prompt rewrite). This is the carryover #4 hard prerequisite.
- **A-006:** `bin/verdict-handler.sh::find_fresh_verdict` returns `source_stage`
  derived from the OLD-shape `pipeline-rejection` marker via a separate `grep`
  inside the function (Phase 1 Task 1.3 fix). New-shape rejections set
  `source_stage:""` because the new event omits source per design §7.2. T2.2
  (carryover #1) adds a fallback in `verdict_handler::apply_transition`'s
  rejection branch: when `source_stage == ""`, read the issue's current
  `stage:*` label.
- **A-007:** `parse_pipeline_marker` aliases `scope-deviation → scope-violation`
  in the OLD-shape branch only. T2.0 (carryover #2) extends the alias to the
  NEW-shape branch so a hand-crafted or future-buggy `<!-- pipeline: verdict
  result=halt reason=scope-deviation -->` produces `reason=scope-violation`.
- **A-008:** Test-helper signatures (`pass_at`/`fail_at`) diverge across
  test files: `common-test.sh` is 1-arg, `scope-check-test.sh` and
  `verdict-handler-test.sh` are 2-arg. T2.3 (carryover #3) unifies on the
  2-arg form (more diagnosable per the Phase 1 final review).
- **A-009:** `AGENT_PROMPTS.md` has nine numbered H2 sections. The "Verdict-marker
  protocol" preamble (around lines 30–80) describes the marker shapes; each
  stage section instructs the agent to emit a specific shape on exit. T2.11
  rewrites the preamble + each stage section to use new-shape markers.
- **A-010:** `bin/render-prompt.sh::STAGE_TO_SECTION` maps stage names to
  `AGENT_PROMPTS.md` section numbers. The current values use a mix of verb
  and gerund forms; T2.12 aligns to gerund.
- **A-011:** Linear's API does NOT support deleting a label from an issue
  via `bin/linear.sh remove-label` if the label doesn't exist on the issue
  — it's a no-op (verified previously). T2.13's legacy-label cleanup safely
  calls `remove-label` for each legacy label on every transition, even when
  the label isn't present.

## File structure (Phase 2)

**Create:**
- `bin/pipeline.sh` — single-entry CLI (~250 lines).
- `bin/pipeline-test.sh` — comprehensive coverage (~400 lines, ~25 fixtures).
- `bin/generate-vocabulary-doc.sh` — generates the glossary from the registry.
- `docs/pipeline-vocabulary.md` — generated artifact + hand-written sections.

**Modify:**
- `bin/common.sh` — extend `parse_pipeline_marker`'s new-shape branch with
  alias normalization (T2.0).
- `bin/run-stage.sh` — migrate `_fresh_wait_reason` to use `parse_pipeline_marker`
  (T2.1).
- `bin/verdict-handler.sh` — rejection branch falls back to `stage:*` label
  when `source_stage` is empty (T2.2); transition flow removes legacy labels
  (T2.13).
- `bin/halt.sh` — deprecation wrapper around `bin/pipeline decide` (T2.9).
- `bin/post-verdict.sh` — deprecation wrapper around `bin/pipeline event` (T2.10).
- `AGENT_PROMPTS.md` — verdict-marker preamble + nine stage sections (T2.11);
  gerund alignment in section headers (T2.12).
- `bin/render-prompt.sh::STAGE_TO_SECTION` — gerund alignment (T2.12).
- `bin/dispatch.sh::allowed_tools_for` — gerund alignment (T2.12).
- `bin/common-test.sh`, `bin/scope-check-test.sh`, `bin/verdict-handler-test.sh`,
  `bin/run-stage-test.sh` — test-helper signature unification to 2-arg form
  (T2.3); add new fixtures for each task.
- `CLAUDE.md` — link to `docs/pipeline-vocabulary.md`; update vocabulary refs;
  remove inline marker explanations (T2.15).

**Delete:** none in Phase 2 (deletions happen in Phase 3).

---

## Phase 2 task plan

### Task 2.0: Extend `parse_pipeline_marker` to alias new-shape halt reasons

**Carryover #2 from Phase 1.**

When `parse_pipeline_marker` parses a new-shape `<!-- pipeline: verdict
result=halt reason=scope-deviation -->`, the legacy reason token leaks
through verbatim because the alias map is only consulted in the OLD-shape
branch. Fix: apply the alias map in the new-shape branch when the event is
`verdict` and a `reason` k=v pair is present.

**Files:**
- Modify: `bin/common.sh::parse_pipeline_marker` (the new-shape branch around
  lines 145–167).
- Test: `bin/common-test.sh` (add P13 fixture).

- [ ] **Step 1: Write the failing test (red)**

Append to `bin/common-test.sh` immediately after the existing P12 fixture
(before any summary block):

```bash
# Fixture P13: new-shape halt with legacy reason should be normalized via
# legacy_halt_reason_aliases (parity with old-shape behavior P6).
result="$(parse_pipeline_marker '<!-- pipeline: verdict result=halt reason=scope-deviation -->')"
[[ "$(jq -r '.event' <<<"$result")" == "verdict" ]] && pass_at "P13: event=verdict (new-shape halt)" "got: $result" || fail_at "P13 event ($result)"
[[ "$(jq -r '.result' <<<"$result")" == "halt" ]] && pass_at "P13: result=halt" "got: $result" || fail_at "P13 result ($result)"
[[ "$(jq -r '.reason' <<<"$result")" == "scope-violation" ]] && pass_at "P13: reason aliased to scope-violation" "got: $result" || fail_at "P13 reason ($result)"
```

NOTE on signature: this fixture uses the 2-arg `pass_at`/`fail_at` form
that T2.3 will normalize across files. If T2.3 has not yet shipped when
this task runs, use whatever form the rest of `common-test.sh` uses
(currently 1-arg) and leave a `# TODO(T2.3): switch to 2-arg form` comment.

Commit:
```bash
git add bin/common-test.sh
git commit -m "test(ENG-60-T2.0): add P13 new-shape halt alias fixture (red)

Mirrors P6 (old-shape) for the new-shape branch. Currently fails
because parse_pipeline_marker only aliases legacy reason tokens in
the old-shape parsing path.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

- [ ] **Step 2: Verify P13 fails**

```bash
TARGET_REPO=/Users/rajatgoyal/code/twinning-harness bash bin/common-test.sh
```

Expected: P13 reason assertion FAILs (`got: ... reason: scope-deviation`);
P13 event/result PASS; everything else PASS.

- [ ] **Step 3: Implement the alias in the new-shape branch (green)**

In `bin/common.sh::parse_pipeline_marker`, find the new-shape branch (the
block starting `# New shape: '<!-- pipeline: <event> [k=v ...] -->'`).
After the for-loop that parses k=v pairs, add an alias-normalization step
that runs only for verdict events with a `reason` field:

```bash
    # Apply legacy_halt_reason_aliases for verdict events with a reason
    # field — same normalization the old-shape `halt)` branch does. This
    # ensures a hand-crafted or future-buggy new-shape halt with a legacy
    # reason token still produces the canonical token downstream.
    if [[ "$event" == "verdict" ]] && jq -e '.reason' <<<"$json" >/dev/null 2>&1; then
      local raw_reason canon_reason
      raw_reason="$(jq -r '.reason' <<<"$json")"
      canon_reason="$(jq -r --arg r "$raw_reason" '.legacy_halt_reason_aliases[$r] // $r' "$HARNESS_ROOT/bin/pipeline-events.json" 2>/dev/null || printf '%s' "$raw_reason")"
      if [[ "$raw_reason" != "$canon_reason" ]]; then
        json="$(jq -c --arg r "$canon_reason" '.reason = $r' <<<"$json")"
      fi
    fi
```

Place it before `printf '%s' "$json"; return 0` at the end of the new-shape
branch.

- [ ] **Step 4: Verify P13 passes; no regressions**

```bash
TARGET_REPO=/Users/rajatgoyal/code/twinning-harness bash bin/common-test.sh
TARGET_REPO=/Users/rajatgoyal/code/twinning-harness bash bin/verdict-handler-test.sh
TARGET_REPO=/Users/rajatgoyal/code/twinning-harness bash bin/scope-check-test.sh
```

Expected: P13 PASS. All pre-existing tests PASS.

- [ ] **Step 5: Commit (green)**

```bash
git add bin/common.sh
git commit -m "feat(ENG-60-T2.0): alias new-shape halt reasons via registry (green)

parse_pipeline_marker now applies legacy_halt_reason_aliases in BOTH
old-shape and new-shape branches. P13 (new-shape) now mirrors P6
(old-shape). Eliminates Phase 1 carryover #2 and lets has_scope_approval
remove its defensive scope-deviation acceptance once Phase 3 drops the
old-shape branch entirely.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 2.1: Migrate `_fresh_wait_reason` to use `parse_pipeline_marker`

**Carryover #4 from Phase 1 — hard prerequisite of T2.11.**

`bin/run-stage.sh::_fresh_wait_reason` uses inline contains-checks that match
only old-shape `<!-- pipeline-wait: -->`. After T2.11 rewrites the build prompt
to emit `<!-- pipeline: verdict result=wait reason=awaiting-approval -->`, this
function will silently miss the new shape and the build-stage wait flow
collapses. Migrate to `parse_pipeline_marker` first.

**Files:**
- Modify: `bin/run-stage.sh::_fresh_wait_reason` (lines 306–334).
- Test: `bin/run-stage-test.sh` (add WR1, WR2 fixtures).

- [ ] **Step 1: Write the failing tests (red)**

Append to `bin/run-stage-test.sh` after the MEA1 fixture (before summary):

```bash
# ─── Group: _fresh_wait_reason new-shape detection (ENG-60 T2.1) ─────────

printf '\n--- _fresh_wait_reason accepts new-shape wait marker ---\n'

# Fixture WR1: new-shape wait marker on build stage should return reason.
COMMENTS_JSON='[
  {"id":"c1","createdAt":"2026-05-03T10:00:00Z","body":"<!-- pipeline-transition: qa → building -->"},
  {"id":"c2","createdAt":"2026-05-03T11:00:00Z","body":"<!-- pipeline: verdict result=wait reason=awaiting-approval -->"}
]'
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/linear.sh" <<EOF
#!/bin/bash
[[ "\$1" == "get-comments" ]] && printf '%s' '$COMMENTS_JSON'
EOF
SCRIPT_DIR="$STUB_DIR"
result="$(_fresh_wait_reason ENG-WR1 build 2>/dev/null)"
[[ "$result" == "awaiting-approval" ]] && pass_at "WR1: new-shape wait reason returned" "got: '$result'" || fail_at "WR1: new-shape wait reason returned" "got: '$result'"

# Fixture WR2: new-shape wait on non-build stage still returns 1 (build-only gate).
result="$(_fresh_wait_reason ENG-WR2 implement 2>/dev/null)"; rc=$?
[[ "$rc" -eq 1 ]] && pass_at "WR2: non-build stage rejected (rc=1)" "rc=$rc" || fail_at "WR2: non-build stage rejected" "rc=$rc"

# Fixture WR3: old-shape wait still works (regression).
COMMENTS_JSON='[
  {"id":"c1","createdAt":"2026-05-03T10:00:00Z","body":"<!-- pipeline-transition: qa → building -->"},
  {"id":"c2","createdAt":"2026-05-03T11:00:00Z","body":"<!-- pipeline-wait: awaiting-ci -->"}
]'
cat > "$STUB_DIR/linear.sh" <<EOF
#!/bin/bash
[[ "\$1" == "get-comments" ]] && printf '%s' '$COMMENTS_JSON'
EOF
result="$(_fresh_wait_reason ENG-WR3 build 2>/dev/null)"
[[ "$result" == "awaiting-ci" ]] && pass_at "WR3: old-shape wait still works" "got: '$result'" || fail_at "WR3: old-shape wait still works" "got: '$result'"
```

Commit:
```bash
git add bin/run-stage-test.sh
git commit -m "test(ENG-60-T2.1): add _fresh_wait_reason new-shape fixtures (red)

WR1 (new shape, build stage), WR2 (non-build rejection still works),
WR3 (old-shape regression). WR1 fails red because the function uses
inline contains-checks that only match old shape.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

- [ ] **Step 2: Verify WR1 fails; WR2 + WR3 pass**

```bash
TARGET_REPO=/Users/rajatgoyal/code/twinning-harness bash bin/run-stage-test.sh
```

Expected: WR1 FAIL; WR2, WR3 PASS.

- [ ] **Step 3: Migrate `_fresh_wait_reason` to use `parse_pipeline_marker`**

Replace `bin/run-stage.sh::_fresh_wait_reason` (lines 306–334) with:

```bash
_fresh_wait_reason() {
  local issue="$1" stage="$2"
  case "$stage" in
    build) ;;
    *) return 1 ;;
  esac

  local comments
  comments="$(bash "$SCRIPT_DIR/linear.sh" get-comments "$issue" 2>/dev/null)" || return 1
  [[ -z "$comments" || "$comments" == "null" ]] && return 1

  # Find the most recent transition timestamp to set freshness floor.
  local last_t=""
  local ts body ev
  while IFS=$'\t' read -r ts body; do
    ev="$(parse_pipeline_marker "$body" 2>/dev/null || true)"
    [[ -z "$ev" ]] && continue
    if [[ "$(jq -r '.event' <<<"$ev")" == "transition" ]]; then
      [[ "$ts" > "$last_t" ]] && last_t="$ts"
    fi
  done < <(jq -r '.[] | "\(.createdAt)\t\(.body | gsub("\n"; " "))"' <<<"$comments")

  # Find the latest wait verdict newer than the transition.
  local fresh_reason=""
  local fresh_ts=""
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

  [[ -z "$fresh_reason" ]] && return 1

  case "$fresh_reason" in
    awaiting-approval|awaiting-ci) printf '%s' "$fresh_reason"; return 0 ;;
    *) return 1 ;;
  esac
}
```

- [ ] **Step 4: Verify WR1-WR3 all pass + run-stage regression**

```bash
TARGET_REPO=/Users/rajatgoyal/code/twinning-harness bash bin/run-stage-test.sh
```

Expected: WR1, WR2, WR3 all PASS. All pre-existing run-stage-test fixtures PASS.

- [ ] **Step 5: Commit (green)**

```bash
git add bin/run-stage.sh
git commit -m "feat(ENG-60-T2.1): _fresh_wait_reason uses parse_pipeline_marker (green)

Eliminates Phase 1 carryover #4. New-shape wait markers are now
detected; build-stage wait flow no longer breaks under T2.11's prompt
rewrite. The build-only gate and the awaiting-approval/awaiting-ci
allow-list are preserved verbatim.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 2.2: Add `source_stage` fallback to `verdict_handler` rejection branch

**Carryover #1 from Phase 1 — required before T2.11 teaches agents to emit new-shape rejections.**

When `find_fresh_verdict` returns a new-shape rejection, `source_stage` is empty
because the new shape omits source per design §7.2 (source is implicit from
the issue's current `stage:*` label). `verdict_handler::apply_transition`'s
rejection branch passes both src+tgt to `_vh_lookup_loopback`; with empty src,
the loopback returns empty and the dispatch silently halts as a protocol
violation. Add a fallback: when `source_stage == ""`, read the issue's current
`stage:*` label.

**Files:**
- Modify: `bin/verdict-handler.sh` rejection branch (around line 359 per the
  earlier audit; verify the actual line via `grep -n '_vh_lookup_loopback'`).
- Test: `bin/verdict-handler-test.sh` (add FB1 fixture).

- [ ] **Step 1: Locate the rejection branch and the stage-label read pattern**

```bash
cd /Users/rajatgoyal/code/twinning-harness
grep -n '_vh_lookup_loopback\|current_stage_label\|stage:' bin/verdict-handler.sh | head -10
grep -n '_vh_get_stage_label\|stage_label_for' bin/verdict-handler.sh bin/linear.sh bin/common.sh | head -10
```

Identify the existing helper for reading an issue's current `stage:*` label
(likely in `bin/linear.sh` or `bin/common.sh`). If none exists, use:

```bash
bash "$_VH_SCRIPT_DIR/linear.sh" get-issue "$issue" \
  | jq -r '.data.issue.labels[]?.name | select(startswith("stage:")) | sub("^stage:"; "")' \
  | head -1
```

(Wrap this in a small helper `_vh_current_stage` if helpful.)

- [ ] **Step 2: Write the failing test (red)**

Append to `bin/verdict-handler-test.sh` after FV5 (before the stub-restore line):

```bash
# Fixture FB1: new-shape rejection with empty source_stage falls back to
# the issue's current stage:* label (carryover #1 from Phase 1).
COMMENTS_JSON='[
  {"id":"c1","createdAt":"2026-05-03T10:00:00Z","body":"<!-- pipeline-transition: implementing → reviewing -->"},
  {"id":"c2","createdAt":"2026-05-03T11:00:00Z","body":"<!-- pipeline: verdict result=fail target=planning -->"}
]'
ISSUE_JSON='{"data":{"issue":{"labels":[{"name":"stage:reviewing"},{"name":"Bug"}]}}}'
cat > "$STUB_DIR/linear.sh" <<EOF
#!/bin/bash
case "\$1" in
  get-comments) printf '%s' '$COMMENTS_JSON' ;;
  get-issue)    printf '%s' '$ISSUE_JSON' ;;
  add-label|remove-label|add-comment|add-or-update-comment) printf 'ok' ;;
esac
EOF
_VH_SCRIPT_DIR="$STUB_DIR"
# Call apply_transition with the fresh verdict; it should resolve src=reviewing
# (from stage:reviewing label) when find_fresh_verdict returned source_stage="".
result="$(verdict_handler ENG-FB1 2>&1)"
echo "$result" | grep -qE 'reviewing.*→.*planning|loopback.*reviewing.*planning' \
  && pass_at "FB1: new-shape rejection resolves source from stage:* label" "result: $result" \
  || fail_at "FB1: new-shape rejection resolves source from stage:* label" "result: $result"
```

NOTE: the assertion regex matches whichever log/output shape the actual
`verdict_handler` produces when it computes the loopback. If the function
swallows its log lines silently, the test may need to assert on side effects
(e.g., `add-label` was called with `stage:planning`) — adapt during execution
based on what the function emits.

Commit (red):
```bash
git add bin/verdict-handler-test.sh
git commit -m "test(ENG-60-T2.2): add FB1 source_stage fallback fixture (red)

When find_fresh_verdict returns a new-shape rejection, source_stage is
empty (new shape omits source by design §7.2). verdict_handler must
fall back to the issue's current stage:* label for the loopback lookup.
Currently fails because no fallback exists.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

- [ ] **Step 3: Verify FB1 fails**

```bash
TARGET_REPO=/Users/rajatgoyal/code/twinning-harness bash bin/verdict-handler-test.sh
```

Expected: FB1 FAIL (loopback lookup returns empty, protocol violation
triggered). All pre-existing tests PASS.

- [ ] **Step 4: Implement the fallback (green)**

In `bin/verdict-handler.sh::apply_transition` (or wherever
`_vh_lookup_loopback` is called for the rejection case), add the fallback
just before the `_vh_lookup_loopback` invocation:

```bash
  # New-shape rejections omit source per design §7.2. Fall back to the
  # issue's current stage:* label when source_stage is empty.
  if [[ -z "$src" ]]; then
    src="$(bash "$_VH_SCRIPT_DIR/linear.sh" get-issue "$issue" \
      | jq -r '.data.issue.labels[]?.name | select(startswith("stage:")) | sub("^stage:"; "")' \
      | head -1)"
    [[ -n "$src" ]] || { _vh_protocol_violation "rejection-source-unknown" "$issue"; return; }
  fi
```

(Adapt to the actual function structure; the snippet shows the intent.)

- [ ] **Step 5: Verify FB1 passes; no regressions**

```bash
TARGET_REPO=/Users/rajatgoyal/code/twinning-harness bash bin/verdict-handler-test.sh
TARGET_REPO=/Users/rajatgoyal/code/twinning-harness bash bin/verdict-adversarial-test.sh
```

Expected: FB1 PASS. All pre-existing tests PASS.

- [ ] **Step 6: Commit (green)**

```bash
git add bin/verdict-handler.sh
git commit -m "feat(ENG-60-T2.2): rejection branch falls back to stage:* label (green)

Eliminates Phase 1 carryover #1. When find_fresh_verdict returns a
new-shape rejection (which omits source per design §7.2), the rejection
branch reads the issue's current stage:* label as the implicit source
before calling _vh_lookup_loopback. Old-shape rejections (which carry
explicit source via the rejection-src grep in find_fresh_verdict) are
unaffected.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 2.3: Unify test-helper signatures across `bin/*-test.sh`

**Carryover #3 from Phase 1.**

Three test files have diverged on `pass_at`/`fail_at` signatures:
- `bin/common-test.sh`: 1-arg (`fail_at "message"`)
- `bin/scope-check-test.sh`: 2-arg (`fail_at "label" "detail"`)
- `bin/verdict-handler-test.sh`: 2-arg

Unify on the 2-arg form (more diagnosable). Update `common-test.sh` to use
2-arg helpers and migrate all existing `fail_at` callsites.

**Files:**
- Modify: `bin/common-test.sh` (helper definitions + every `fail_at` callsite).
- No production code change.

- [ ] **Step 1: Update the helper definitions in `bin/common-test.sh`**

Find the `pass_at`/`fail_at` definitions (added in Task 1.2, around lines
237–238). Replace with the 2-arg form matching the other test files:

```bash
pass_at() { PASS=$((PASS+1)); printf '  ✅ %s\n' "$1"; }
fail_at() {
  FAIL=$((FAIL+1));
  if [[ -n "${2:-}" ]]; then
    printf '  ❌ %s\n      %s\n' "$1" "$2" >&2
  else
    printf '  ❌ %s\n' "$1" >&2
  fi
  FAILED_CASES+=("$1")
}
```

The `[[ -n "${2:-}" ]]` guard preserves backwards compat with existing
1-arg calls (they print without the detail line).

- [ ] **Step 2: Migrate P1–P13 fixtures to use the 2-arg form**

Walk through every `fail_at` call in the P1–P13 group (added in Tasks 1.2
and T2.0). Where the call embeds context inline (e.g., `fail_at "P1: event
mismatch ($result)"`), split into label + detail:

```bash
# Before:
fail_at "P1: event mismatch ($result)"
# After:
fail_at "P1: event mismatch" "got: $result"
```

Apply consistently to all P-fixtures. Use a single `sed` pass if the patterns
permit, otherwise hand-edit.

- [ ] **Step 3: Run the test to confirm no regressions**

```bash
TARGET_REPO=/Users/rajatgoyal/code/twinning-harness bash bin/common-test.sh
```

Expected: all 41+ tests PASS. Output now uses the same `✅`/`❌` format
as `scope-check-test.sh` and `verdict-handler-test.sh`.

- [ ] **Step 4: Commit**

```bash
git add bin/common-test.sh
git commit -m "refactor(ENG-60-T2.3): unify pass_at/fail_at on 2-arg form

Eliminates Phase 1 carryover #3. common-test.sh now uses the same
2-arg fail_at signature as scope-check-test.sh and verdict-handler-test.sh.
The helper preserves 1-arg back-compat for any future call that omits
the detail. P-fixtures migrated to (label, detail) split for cleaner
failure output.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 2.4: Create `bin/pipeline.sh` skeleton with `status` subcommand

**Files:**
- Create: `bin/pipeline.sh`.
- Test: `bin/pipeline-test.sh` (created in T2.8).

- [ ] **Step 1: Create the skeleton**

Write `bin/pipeline.sh`:

```bash
#!/usr/bin/env bash
# bin/pipeline.sh — single-entry CLI for pipeline events (ENG-60).
#
# Usage:
#   bin/pipeline.sh status <issue>
#   bin/pipeline.sh event <issue> <event> [args]
#   bin/pipeline.sh decide <issue> --action <continue|approve|abandon> [--gate <gate>]
#
# All writes validate against bin/pipeline-events.json. Lane fences honored
# via PIPELINE_WRITER (set by callers; agent | orchestrator | human).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

REGISTRY="$HARNESS_ROOT/bin/pipeline-events.json"

usage() {
  cat <<'EOF'
Usage:
  bin/pipeline.sh status <issue>
  bin/pipeline.sh event <issue> verdict <pass|fail|halt|wait|pivot> [--stage X] [--target Y] [--reason Z]
  bin/pipeline.sh event <issue> transition <from→to>
  bin/pipeline.sh decide <issue> --action <continue|approve|abandon> [--gate <gate>]

Environment:
  PIPELINE_WRITER  Lane attribution: agent | orchestrator | human (required for writes).
  PIPELINE_DRY_RUN If set, print intended action to stderr and skip the Linear write.
EOF
}

# cmd_status <issue> — read-only summary of pipeline events on an issue.
# Lists every comment whose body parses as a pipeline event, in chronological
# order, one per line: "<createdAt> <event> <key=value ...>"
cmd_status() {
  local issue="$1"
  [[ -n "$issue" ]] || die "status: issue id required"
  local comments
  comments="$(bash "$SCRIPT_DIR/linear.sh" get-comments "$issue")"
  [[ -z "$comments" || "$comments" == "null" ]] && { log "status: no comments"; return 0; }

  local ts body ev
  while IFS=$'\t' read -r ts body; do
    ev="$(parse_pipeline_marker "$body" 2>/dev/null || true)"
    [[ -z "$ev" ]] && continue
    printf '%s  %s\n' "$ts" "$(jq -c . <<<"$ev")"
  done < <(jq -r '.[] | "\(.createdAt)\t\(.body | gsub("\n"; " "))"' <<<"$comments")
}

main() {
  local sub="${1:-}"
  shift || true
  case "$sub" in
    status) cmd_status "$@" ;;
    event)  die "event subcommand: not yet implemented (T2.5–T2.6)" ;;
    decide) die "decide subcommand: not yet implemented (T2.7)" ;;
    -h|--help|"") usage; [[ -z "$sub" ]] && exit 1 || exit 0 ;;
    *) usage; die "unknown subcommand: $sub" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
```

- [ ] **Step 2: Make it executable + smoke**

```bash
chmod +x bin/pipeline.sh
TARGET_REPO=/Users/rajatgoyal/code/twinning-harness bash bin/pipeline.sh --help
```

Expected: prints usage; exits 0.

- [ ] **Step 3: Commit**

```bash
git add bin/pipeline.sh
git commit -m "feat(ENG-60-T2.4): bin/pipeline.sh skeleton with status subcommand

Single-entry CLI per design §7.6. status is read-only (calls
parse_pipeline_marker per comment). event and decide subcommands stub
out to die — implemented in T2.5–T2.7.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 2.5: Implement `bin/pipeline event verdict <result>` subcommand

**Files:**
- Modify: `bin/pipeline.sh` (add `cmd_event` + `cmd_event_verdict`).
- Test fixtures: deferred to T2.8 (one test file for the whole CLI).

- [ ] **Step 1: Add the subcommand handler**

Replace the `event)  die "..."` line in `main()` with `event) cmd_event "$@" ;;`,
then add:

```bash
# cmd_event <issue> <event> [args] — dispatch to event-specific writer.
cmd_event() {
  local issue="$1"; shift
  local event="$1"; shift
  case "$event" in
    verdict)    cmd_event_verdict "$issue" "$@" ;;
    transition) cmd_event_transition "$issue" "$@" ;;
    *) die "event: unknown event '$event' (allowed: verdict, transition)" ;;
  esac
}

# Validate $1 is in the named registry array; die with the registry's contents
# in the error message if not.
_validate_registry() {
  local field="$1" value="$2"
  jq -e --arg f "$field" --arg v "$value" '.[$f] | index($v) // empty' "$REGISTRY" >/dev/null 2>&1 \
    || die "registry: '$value' not in $field — allowed: $(jq -r --arg f "$field" '.[$f] | join(", ")' "$REGISTRY")"
}

# cmd_event_verdict <issue> <result> [--stage X] [--target Y] [--reason Z]
cmd_event_verdict() {
  local issue="$1"; shift
  local result="${1:-}"; shift || true
  [[ -n "$issue" && -n "$result" ]] || die "event verdict: usage: <issue> <result> [args]"
  _validate_registry verdict_results "$result"

  local stage="" target="" reason=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --stage)  stage="${2:-}"; shift 2 ;;
      --target) target="${2:-}"; shift 2 ;;
      --reason) reason="${2:-}"; shift 2 ;;
      *) die "event verdict: unknown flag '$1'" ;;
    esac
  done

  # Per-result required fields.
  case "$result" in
    pass)  [[ -n "$stage" ]]  || die "event verdict pass: --stage required"
           _validate_registry stages "$stage" ;;
    fail)  [[ -n "$target" ]] || die "event verdict fail: --target required"
           _validate_registry fail_targets "$target" ;;
    halt)  [[ -n "$reason" ]] || die "event verdict halt: --reason required"
           _validate_registry halt_reasons "$reason" ;;
    wait)  [[ -n "$reason" ]] || die "event verdict wait: --reason required"
           _validate_registry wait_reasons "$reason" ;;
    pivot) [[ -n "$target" ]] || die "event verdict pivot: --target required"
           _validate_registry pivot_targets "$target" ;;
  esac

  # Build the marker body.
  local body="<!-- pipeline: verdict result=$result"
  [[ -n "$stage" ]]  && body="$body stage=$stage"
  [[ -n "$target" ]] && body="$body target=$target"
  [[ -n "$reason" ]] && body="$body reason=$reason"
  body="$body -->"

  # Lane fence: agents emit verdicts.
  : "${PIPELINE_WRITER:=agent}"
  if [[ "$PIPELINE_WRITER" != "agent" ]]; then
    log "warning: PIPELINE_WRITER=$PIPELINE_WRITER writing a verdict (lane mismatch)"
  fi

  if [[ "${PIPELINE_DRY_RUN:-}" == "1" ]]; then
    printf '[DRY_RUN] would post on %s: %s\n' "$issue" "$body" >&2
    return 0
  fi

  bash "$SCRIPT_DIR/linear.sh" add-comment "$issue" "$body"
}
```

- [ ] **Step 2: Smoke**

```bash
TARGET_REPO=/Users/rajatgoyal/code/twinning-harness PIPELINE_DRY_RUN=1 \
  bash bin/pipeline.sh event ENG-1 verdict pass --stage implementing
TARGET_REPO=/Users/rajatgoyal/code/twinning-harness PIPELINE_DRY_RUN=1 \
  bash bin/pipeline.sh event ENG-1 verdict halt --reason agent-blocked
TARGET_REPO=/Users/rajatgoyal/code/twinning-harness \
  bash bin/pipeline.sh event ENG-1 verdict halt --reason bogus-reason 2>&1 || echo "rejected as expected"
```

Expected:
1. Prints `[DRY_RUN] would post on ENG-1: <!-- pipeline: verdict result=pass stage=implementing -->`.
2. Same shape for halt.
3. Third command exits non-zero with a registry rejection message naming the allowed reasons.

- [ ] **Step 3: Commit**

```bash
git add bin/pipeline.sh
git commit -m "feat(ENG-60-T2.5): bin/pipeline event verdict subcommand

Writes new-shape verdict markers, validating each field against
bin/pipeline-events.json. Per-result required-field checks (pass→stage,
fail→target, halt→reason, wait→reason, pivot→target). Honors
PIPELINE_DRY_RUN. Lane-fenced (defaults to agent; warns on mismatch).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 2.6: Implement `bin/pipeline event transition <from→to>` subcommand

**Files:**
- Modify: `bin/pipeline.sh` (add `cmd_event_transition`).

- [ ] **Step 1: Add the handler**

Append to `bin/pipeline.sh`:

```bash
# cmd_event_transition <issue> <from→to>
cmd_event_transition() {
  local issue="$1"; shift
  local arrow="${1:-}"
  [[ -n "$issue" && -n "$arrow" ]] || die "event transition: usage: <issue> <from→to>"
  [[ "$arrow" == *"→"* ]] || die "event transition: argument must contain → (Unicode U+2192)"

  local from="${arrow%% → *}"
  local to="${arrow##* → }"
  _validate_registry stages "$from"
  _validate_registry stages "$to"

  local body="<!-- pipeline: transition stage=$from→$to -->"

  : "${PIPELINE_WRITER:=orchestrator}"
  if [[ "$PIPELINE_WRITER" != "orchestrator" ]]; then
    log "warning: PIPELINE_WRITER=$PIPELINE_WRITER writing a transition (lane mismatch)"
  fi

  if [[ "${PIPELINE_DRY_RUN:-}" == "1" ]]; then
    printf '[DRY_RUN] would post on %s: %s\n' "$issue" "$body" >&2
    return 0
  fi

  bash "$SCRIPT_DIR/linear.sh" add-comment "$issue" "$body"
}
```

- [ ] **Step 2: Smoke**

```bash
TARGET_REPO=/Users/rajatgoyal/code/twinning-harness PIPELINE_DRY_RUN=1 \
  bash bin/pipeline.sh event ENG-1 transition "implementing → reviewing"
```

Expected: prints `[DRY_RUN] would post on ENG-1: <!-- pipeline: transition stage=implementing→reviewing -->`.

NOTE: the body uses `from→to` (no spaces around arrow) for compactness.
Confirm `parse_pipeline_marker`'s old-shape branch handles the spaceful form
(`from → to`) for legacy compatibility, and the new-shape branch handles
the spaceless form. If `parse_pipeline_marker` doesn't currently parse
`stage=from→to` correctly (the `=` is followed by a non-whitespace token
containing `→`), patch the helper in this same task (small change to the
new-shape k=v split) OR keep the spaceful form for the body. **Choose during
execution based on what `parse_pipeline_marker` accepts.**

- [ ] **Step 3: Commit**

```bash
git add bin/pipeline.sh
git commit -m "feat(ENG-60-T2.6): bin/pipeline event transition subcommand

Writes orchestrator transition markers. Validates both from and to
stages against the registry. Lane-fenced to PIPELINE_WRITER=orchestrator.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 2.7: Implement `bin/pipeline decide` subcommand

**Files:**
- Modify: `bin/pipeline.sh` (add `cmd_decide`).

- [ ] **Step 1: Add the handler**

Replace the `decide) die "..."` line in `main()` with `decide) cmd_decide "$@" ;;`,
then append:

```bash
# cmd_decide <issue> --action <continue|approve|abandon> [--gate <gate>]
cmd_decide() {
  local issue="${1:-}"; shift || true
  [[ -n "$issue" ]] || die "decide: usage: <issue> --action <action> [--gate <gate>]"

  local action="" gate=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --action) action="${2:-}"; shift 2 ;;
      --gate)   gate="${2:-}"; shift 2 ;;
      *) die "decide: unknown flag '$1'" ;;
    esac
  done

  [[ -n "$action" ]] || die "decide: --action required"
  _validate_registry decision_actions "$action"

  # `continue` is the only action that may omit --gate; approve and abandon
  # require it.
  case "$action" in
    continue) [[ -z "$gate" ]] || die "decide continue: --gate not allowed (continue is gate-agnostic)" ;;
    approve|abandon)
      [[ -n "$gate" ]] || die "decide $action: --gate required"
      _validate_registry decision_gates "$gate" ;;
  esac

  local body="<!-- pipeline: decision action=$action"
  [[ -n "$gate" ]] && body="$body gate=$gate"
  body="$body -->"

  : "${PIPELINE_WRITER:=human}"
  if [[ "$PIPELINE_WRITER" != "human" ]]; then
    log "warning: PIPELINE_WRITER=$PIPELINE_WRITER writing a decision (lane mismatch)"
  fi

  if [[ "${PIPELINE_DRY_RUN:-}" == "1" ]]; then
    printf '[DRY_RUN] would post on %s: %s\n' "$issue" "$body" >&2
    return 0
  fi

  bash "$SCRIPT_DIR/linear.sh" add-comment "$issue" "$body"
}
```

- [ ] **Step 2: Smoke**

```bash
TARGET_REPO=/Users/rajatgoyal/code/twinning-harness PIPELINE_DRY_RUN=1 \
  bash bin/pipeline.sh decide ENG-1 --action continue
TARGET_REPO=/Users/rajatgoyal/code/twinning-harness PIPELINE_DRY_RUN=1 \
  bash bin/pipeline.sh decide ENG-1 --action approve --gate scope
TARGET_REPO=/Users/rajatgoyal/code/twinning-harness \
  bash bin/pipeline.sh decide ENG-1 --action approve 2>&1 || echo "rejected as expected"
```

Expected: first two print dry-run lines; third rejects "approve: --gate required".

- [ ] **Step 3: Commit**

```bash
git add bin/pipeline.sh
git commit -m "feat(ENG-60-T2.7): bin/pipeline decide subcommand

Operator-facing override CLI. \`continue\` is gate-agnostic; \`approve\`
and \`abandon\` require --gate from the registry. Lane-fenced to
PIPELINE_WRITER=human (the lane that bin/halt.sh already exports).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 2.8: Comprehensive `bin/pipeline-test.sh`

**Files:**
- Create: `bin/pipeline-test.sh`.

- [ ] **Step 1: Write the test file**

Create `bin/pipeline-test.sh`:

```bash
#!/usr/bin/env bash
# ENG-60 T2.8: bin/pipeline.sh end-to-end coverage.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Throwaway TARGET_REPO + PROJECT_SLUG so common.sh sources cleanly.
_TEST_ROOT="$(mktemp -d -t twinning-eng60-pipe.XXXXXX)"
case "$_TEST_ROOT" in
  /var/folders/*|/tmp/*|/private/var/folders/*|/private/tmp/*) ;;
  *) printf 'REFUSING: %q is not a temp dir\n' "$_TEST_ROOT" >&2; exit 99 ;;
esac
trap 'rm -rf "$_TEST_ROOT"' EXIT

export TARGET_REPO="$_TEST_ROOT/target"
mkdir -p "$TARGET_REPO/.pipeline-config"
export PROJECT_SLUG="${PROJECT_SLUG:-test-pipe}"
export HARNESS_ROOT="$SCRIPT_DIR/.."
STUB_DIR="$_TEST_ROOT/stubs"
mkdir -p "$STUB_DIR"

# Stub linear.sh: capture every add-comment invocation to a file.
CAPTURE="$_TEST_ROOT/captured-comments.log"
cat > "$STUB_DIR/linear.sh" <<EOF
#!/bin/bash
case "\$1" in
  add-comment) printf 'add-comment %s %s\n' "\$2" "\$3" >> "$CAPTURE"; printf 'ok' ;;
  get-comments) printf '[]' ;;
esac
EOF
chmod +x "$STUB_DIR/linear.sh"

PASS=0; FAIL=0; FAILED_CASES=()
pass_at() { PASS=$((PASS+1)); printf '  ✅ %s\n' "$1"; }
fail_at() {
  FAIL=$((FAIL+1));
  if [[ -n "${2:-}" ]]; then
    printf '  ❌ %s\n      %s\n' "$1" "$2" >&2
  else printf '  ❌ %s\n' "$1" >&2; fi
  FAILED_CASES+=("$1")
}

# Helper: run bin/pipeline.sh with stub PATH; capture stdout, stderr, rc.
run_pipe() {
  PATH="$STUB_DIR:$PATH" PIPELINE_DRY_RUN=1 \
    bash "$SCRIPT_DIR/pipeline.sh" "$@" 2>&1
}

printf '\n--- bin/pipeline.sh: event verdict ---\n'

# PE1: pass with valid stage → dry-run prints expected body
out="$(run_pipe event ENG-PE1 verdict pass --stage implementing)"
expect='<!-- pipeline: verdict result=pass stage=implementing -->'
[[ "$out" == *"$expect"* ]] && pass_at "PE1: verdict pass dry-run body" "got: $out" || fail_at "PE1: verdict pass dry-run body" "got: $out"

# PE2: halt with valid reason
out="$(run_pipe event ENG-PE2 verdict halt --reason agent-blocked)"
expect='<!-- pipeline: verdict result=halt reason=agent-blocked -->'
[[ "$out" == *"$expect"* ]] && pass_at "PE2: verdict halt dry-run body" "got: $out" || fail_at "PE2: verdict halt dry-run body" "got: $out"

# PE3: registry rejection — bogus reason
out="$(run_pipe event ENG-PE3 verdict halt --reason bogus-reason 2>&1 || true)"
[[ "$out" == *"not in halt_reasons"* ]] && pass_at "PE3: bogus halt reason rejected" "got: $out" || fail_at "PE3: bogus halt reason rejected" "got: $out"

# PE4: missing required field — pass without --stage
out="$(run_pipe event ENG-PE4 verdict pass 2>&1 || true)"
[[ "$out" == *"--stage required"* ]] && pass_at "PE4: pass requires --stage" "got: $out" || fail_at "PE4: pass requires --stage" "got: $out"

# PE5–PE7: fail/wait/pivot variants — required field validation
out="$(run_pipe event ENG-PE5 verdict fail --target planning)"
[[ "$out" == *"target=planning"* ]] && pass_at "PE5: verdict fail target" "got: $out" || fail_at "PE5: verdict fail target" "got: $out"

out="$(run_pipe event ENG-PE6 verdict wait --reason awaiting-approval)"
[[ "$out" == *"reason=awaiting-approval"* ]] && pass_at "PE6: verdict wait reason" "got: $out" || fail_at "PE6: verdict wait reason" "got: $out"

out="$(run_pipe event ENG-PE7 verdict pivot --target planning)"
[[ "$out" == *"result=pivot target=planning"* ]] && pass_at "PE7: verdict pivot target" "got: $out" || fail_at "PE7: verdict pivot target" "got: $out"

printf '\n--- bin/pipeline.sh: event transition ---\n'

# PT1: valid transition
out="$(run_pipe event ENG-PT1 transition "implementing → reviewing")"
[[ "$out" == *"transition stage=implementing→reviewing"* ]] && pass_at "PT1: transition dry-run body" "got: $out" || fail_at "PT1: transition dry-run body" "got: $out"

# PT2: bogus from-stage
out="$(run_pipe event ENG-PT2 transition "bogus-stage → reviewing" 2>&1 || true)"
[[ "$out" == *"not in stages"* ]] && pass_at "PT2: bogus from-stage rejected" "got: $out" || fail_at "PT2: bogus from-stage rejected" "got: $out"

# PT3: missing arrow
out="$(run_pipe event ENG-PT3 transition "implementing reviewing" 2>&1 || true)"
[[ "$out" == *"contain →"* ]] && pass_at "PT3: missing arrow rejected" "got: $out" || fail_at "PT3: missing arrow rejected" "got: $out"

printf '\n--- bin/pipeline.sh: decide ---\n'

# PD1: continue (no gate)
out="$(run_pipe decide ENG-PD1 --action continue)"
[[ "$out" == *"decision action=continue -->"* ]] && pass_at "PD1: decide continue body" "got: $out" || fail_at "PD1: decide continue body" "got: $out"

# PD2: approve with gate=scope
out="$(run_pipe decide ENG-PD2 --action approve --gate scope)"
[[ "$out" == *"decision action=approve gate=scope"* ]] && pass_at "PD2: decide approve scope" "got: $out" || fail_at "PD2: decide approve scope" "got: $out"

# PD3: abandon with gate=scope
out="$(run_pipe decide ENG-PD3 --action abandon --gate scope)"
[[ "$out" == *"action=abandon gate=scope"* ]] && pass_at "PD3: decide abandon scope" "got: $out" || fail_at "PD3: decide abandon scope" "got: $out"

# PD4: approve without --gate → rejected
out="$(run_pipe decide ENG-PD4 --action approve 2>&1 || true)"
[[ "$out" == *"--gate required"* ]] && pass_at "PD4: approve requires --gate" "got: $out" || fail_at "PD4: approve requires --gate" "got: $out"

# PD5: continue with --gate → rejected
out="$(run_pipe decide ENG-PD5 --action continue --gate scope 2>&1 || true)"
[[ "$out" == *"--gate not allowed"* ]] && pass_at "PD5: continue rejects --gate" "got: $out" || fail_at "PD5: continue rejects --gate" "got: $out"

# PD6: bogus gate
out="$(run_pipe decide ENG-PD6 --action approve --gate bogus-gate 2>&1 || true)"
[[ "$out" == *"not in decision_gates"* ]] && pass_at "PD6: bogus gate rejected" "got: $out" || fail_at "PD6: bogus gate rejected" "got: $out"

printf '\n--- bin/pipeline.sh: lane fences (warn-only) ---\n'

# PL1: writing a verdict with PIPELINE_WRITER=human → warn but still write
out="$(PIPELINE_WRITER=human run_pipe event ENG-PL1 verdict pass --stage implementing 2>&1)"
[[ "$out" == *"lane mismatch"* ]] && pass_at "PL1: verdict-as-human warns" "got: $out" || fail_at "PL1: verdict-as-human warns" "got: $out"

printf '\npipeline-test summary: %d passed, %d failed\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf 'failed cases:\n'; for c in "${FAILED_CASES[@]}"; do printf '  - %s\n' "$c"; done
  exit 1
fi
exit 0
```

- [ ] **Step 2: Run the test**

```bash
TARGET_REPO=/Users/rajatgoyal/code/twinning-harness bash bin/pipeline-test.sh
```

Expected: all PE/PT/PD/PL fixtures PASS.

- [ ] **Step 3: Commit**

```bash
git add bin/pipeline-test.sh
git commit -m "test(ENG-60-T2.8): comprehensive bin/pipeline.sh coverage

PE (event verdict): 7 fixtures incl. registry rejection + missing-field.
PT (event transition): 3 fixtures incl. bogus stage + missing arrow.
PD (decide): 6 fixtures incl. gate enforcement + bogus gate.
PL (lane fences): 1 fixture asserting warn-only behavior on lane mismatch.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 2.9: Convert `bin/halt.sh` to a deprecation wrapper

**Files:**
- Modify: `bin/halt.sh`.
- Test: `bin/halt-sprawl-test.sh` (verify wrapper still satisfies the existing
  resolve flow).

- [ ] **Step 1: Replace the body of `bin/halt.sh::resolve`**

Find `resolve()` in `bin/halt.sh`. Keep the argument parsing (the
`--decision <X>` flag), then replace the comment-posting + label-removing
logic with a translation to `bin/pipeline decide`:

```bash
resolve() {
  local issue="" decision=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --decision) decision="${2:-}"; shift 2 ;;
      ENG-*)      issue="$1"; shift ;;
      *) die "usage: halt.sh resolve <ENG-XX> --decision <scope-approved|scope-rejected|resume>" ;;
    esac
  done
  [[ -n "$issue" && -n "$decision" ]] \
    || die "usage: halt.sh resolve <ENG-XX> --decision <scope-approved|scope-rejected|resume>"

  printf '[deprecated] bin/halt.sh resolve will be removed in Phase 3. ' >&2
  printf 'Use: bin/pipeline decide %s --action <continue|approve|abandon> [--gate <gate>]\n' "$issue" >&2

  # Translate legacy decision token → new shape.
  local action gate=""
  case "$decision" in
    resume)         action="continue" ;;
    scope-approved) action="approve"; gate="scope" ;;
    scope-rejected) action="abandon"; gate="scope" ;;
    *) die "unknown decision: $decision" ;;
  esac

  PIPELINE_WRITER=human bash "$SCRIPT_DIR/pipeline.sh" decide "$issue" --action "$action" ${gate:+--gate "$gate"}

  # Preserve the existing post-decide cleanup (label removal etc) — copy
  # the exact lines from the pre-wrapper resolve() body. The wrapper does
  # NOT change the cleanup steps; it only changes the comment-write step.
  bash "$SCRIPT_DIR/linear.sh" remove-label "$issue" "pipeline:halted" 2>/dev/null || true
  # … any other cleanup that the original resolve() did, copied verbatim.
}
```

NOTE: read the current `resolve()` end-to-end before editing. The above
captures the comment-write swap only; the existing label-removal and
verdict-handler invocation must be preserved verbatim. The wrapper's job is
to keep the operator surface identical while the underlying write goes
through the new CLI.

- [ ] **Step 2: Run regression**

```bash
TARGET_REPO=/Users/rajatgoyal/code/twinning-harness bash bin/halt-sprawl-test.sh
TARGET_REPO=/Users/rajatgoyal/code/twinning-harness bash bin/halt-sprawl-adversarial-test.sh
```

Expected: all PASS. The wrapper preserves the exit semantics.

- [ ] **Step 3: Smoke**

```bash
TARGET_REPO=/Users/rajatgoyal/code/twinning-harness PIPELINE_DRY_RUN=1 \
  bash bin/halt.sh resolve ENG-1 --decision scope-approved 2>&1
```

Expected: prints `[deprecated]` line on stderr; bin/pipeline decide called
with `--action approve --gate scope`.

- [ ] **Step 4: Commit**

```bash
git add bin/halt.sh
git commit -m "refactor(ENG-60-T2.9): bin/halt.sh resolve becomes a wrapper

Operator surface preserved (\`halt.sh resolve <issue> --decision X\` still
works); the underlying comment-write now goes through bin/pipeline decide.
Each invocation logs a [deprecated] line on stderr pointing at the new
CLI. Phase 3 deletes this wrapper entirely.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 2.10: Convert `bin/post-verdict.sh` to a deprecation wrapper

**Files:**
- Modify: `bin/post-verdict.sh`.

- [ ] **Step 1: Replace the body**

Read the current `bin/post-verdict.sh` end-to-end. Replace the marker-
constructing + Linear-write logic with a translation to `bin/pipeline event verdict`:

```bash
main() {
  local issue="${1:-}" kind="${2:-}" stage="${3:-}" reason="${4:-}"
  [[ -n "$issue" && -n "$kind" && -n "$stage" ]] \
    || die "usage: post-verdict.sh <issue> <kind> <stage> [<reason>]"

  printf '[deprecated] bin/post-verdict.sh will be removed in Phase 3. ' >&2
  printf 'Use: bin/pipeline event %s verdict <result> [args]\n' "$issue" >&2

  case "$kind" in
    stage-summary) bash "$SCRIPT_DIR/pipeline.sh" event "$issue" verdict pass --stage "$stage" ;;
    rejection)     bash "$SCRIPT_DIR/pipeline.sh" event "$issue" verdict fail --target "$stage" ;;
    halt)          bash "$SCRIPT_DIR/pipeline.sh" event "$issue" verdict halt --reason "$stage" ;;
    *) die "post-verdict: unknown kind '$kind' (allowed: stage-summary, rejection, halt)" ;;
  esac
}
```

NOTE the legacy mapping: post-verdict.sh's `<stage>` argument is the
stage name for stage-summary, the loopback target for rejection, and the
halt reason for halt. The translation respects this shape.

- [ ] **Step 2: Smoke**

```bash
TARGET_REPO=/Users/rajatgoyal/code/twinning-harness PIPELINE_DRY_RUN=1 \
  bash bin/post-verdict.sh ENG-1 stage-summary implementing 2>&1
TARGET_REPO=/Users/rajatgoyal/code/twinning-harness PIPELINE_DRY_RUN=1 \
  bash bin/post-verdict.sh ENG-1 halt agent-blocked 2>&1
```

Expected: deprecation line + new-shape comment dry-run output.

- [ ] **Step 3: Commit**

```bash
git add bin/post-verdict.sh
git commit -m "refactor(ENG-60-T2.10): bin/post-verdict.sh becomes a wrapper

Translates legacy <kind, stage, reason?> tuple into the new
bin/pipeline event verdict subcommand. Operator/agent invocations
keep working via the wrapper for one release; Phase 3 removes it.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 2.11: Rewrite `AGENT_PROMPTS.md` to use new-shape markers

**Files:**
- Modify: `AGENT_PROMPTS.md` (verdict-marker preamble + each of nine stage
  sections).

This is the largest content change in Phase 2. The preamble currently
describes the old marker shapes; each stage section instructs the agent to
emit a specific shape on exit. After this task, every reference and
instruction uses new-shape syntax — agents start emitting new shapes on
their next dispatch.

- [ ] **Step 1: Rewrite the verdict-marker preamble**

Find the "Verdict-marker protocol" section (around lines 30–80; verify with
`grep -n 'Verdict-marker protocol' AGENT_PROMPTS.md`). Replace the per-shape
documentation with:

```markdown
## Verdict-marker protocol

State transitions are owned by the orchestrator. Agents communicate verdicts
by posting one HTML comment marker per stage exit, in the canonical shape:

  <!-- pipeline: verdict result=<pass|fail|halt|wait|pivot> [stage=X] [target=Y] [reason=Z] -->

- `pass` requires `stage=<your stage>`. Means: stage finished cleanly, advance.
- `fail` requires `target=<stage>`. Means: loop back to that stage.
- `halt` requires `reason=<token>`. Means: stop, human action required. Tokens
  must come from the registry at `bin/pipeline-events.json::halt_reasons`.
- `wait` requires `reason=<token>`. Means: soft pause; orchestrator will
  re-dispatch later. Allowed only on the build stage; tokens are
  `awaiting-approval | awaiting-ci`.
- `pivot` requires `target=<stage>`. Means: the plan is structurally wrong;
  loop back further than `fail` would. (Not yet enabled by default.)

Operators (humans) do NOT emit verdicts. Operator overrides use:

  <!-- pipeline: decision action=<continue|approve|abandon> [gate=<gate>] -->

Bookkeeping comments (dedup keys, metric counters, evidence bundles) use the
`<!-- meta: ... -->` family — see `docs/pipeline-vocabulary.md`. Bookkeeping
comments do NOT drive state and the orchestrator ignores them when computing
the latest fresh verdict.

Use `bin/pipeline event <issue> verdict <result> [args]` to emit a verdict
— it validates against the registry and dies on unknown tokens. Do NOT
hand-craft marker bodies in scripts.
```

- [ ] **Step 2: Rewrite each stage section's "exit instructions"**

For each of the nine stage sections in `AGENT_PROMPTS.md` (Brainstorm, Plan,
Implementation, UI, Review, QA, Build, Release, Retrospective), find the
"on exit" / "verdict marker" / "exit shape" instructions and replace with the
new-shape syntax. Concrete example for the Implementation Agent:

```markdown
On clean exit, run:

  bash bin/pipeline.sh event {issue_id} verdict pass --stage implementing

To loop back (rare for implement; usually a sign the plan needs work):

  bash bin/pipeline.sh event {issue_id} verdict fail --target planning

To halt for human intervention:

  bash bin/pipeline.sh event {issue_id} verdict halt --reason <reason>

  where <reason> is one of: agent-blocked | smoke-failed | iteration-exhausted |
  scope-violation | protocol-violation | dispatch-timeout | pr-opened-too-early
```

Apply the analogous rewrite to every stage section. Stage names use **gerund
tense** (T2.12 enforces this everywhere; emit `--stage planning` not
`--stage plan`).

- [ ] **Step 3: Run AGENT_PROMPTS content tests**

```bash
TARGET_REPO=/Users/rajatgoyal/code/twinning-harness bash bin/agent-prompts-content-test.sh 2>/dev/null || true
TARGET_REPO=/Users/rajatgoyal/code/twinning-harness bash bin/render-prompt-test.sh 2>/dev/null || true
```

Expected: existing tests should still pass (they assert on structure, not
specific marker shapes). If any test asserts on a specific old-shape marker
string, update the assertion in the same commit.

- [ ] **Step 4: Render-and-verify a prompt for one stage**

```bash
TARGET_REPO=/Users/rajatgoyal/code/twinning-harness \
  bash bin/render-prompt.sh implementing 2>&1 | grep -E 'pipeline: verdict|pipeline event'
```

Expected: the rendered prompt for the implement stage contains the new-shape
verdict instructions.

- [ ] **Step 5: Commit**

```bash
git add AGENT_PROMPTS.md
git commit -m "docs(ENG-60-T2.11): AGENT_PROMPTS.md uses new-shape verdict markers

Verdict-marker protocol preamble rewritten to describe new shape
exclusively. Each of nine stage sections updated to instruct agents
to invoke 'bin/pipeline.sh event <issue> verdict ...' rather than
hand-crafting marker bodies. Stage names use gerund tense throughout
(T2.12 enforces consistency in source code).

Agents will emit new-shape markers starting on their next dispatch.
Phase 1's parsers accept both shapes, so in-flight issues with
old-shape comments continue to work.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 2.12: Align stage names to gerund tense everywhere

**Files:**
- Modify: `bin/render-prompt.sh::STAGE_TO_SECTION`.
- Modify: `bin/dispatch.sh::allowed_tools_for` (case statement).
- Modify: `bin/run-stage.sh` and any other site grepping for verb-form stage
  names.
- Modify: function names in `bin/*.sh` where they encode a stage in
  verb form (judgment call — see Q2 in brainstorm §10).

- [ ] **Step 1: Audit verb-form stage references**

```bash
cd /Users/rajatgoyal/code/twinning-harness
grep -rn 'brainstorm\|plan\|implement\|review\|qa\|build\|release' bin/ AGENT_PROMPTS.md \
  | grep -vE '\b(brainstorming|planning|implementing|reviewing|building|released)\b' \
  | grep -v '_test\.sh:' | head -50
```

Survey output to identify true verb-form usages (vs. legitimate verb usage
in prose/comments). Build a list of files + line ranges to edit.

- [ ] **Step 2: One-PR-or-split decision**

If the audit returns < 30 sites, do one PR (this task). If > 50, split into
two: (a) `bin/render-prompt.sh` and `bin/dispatch.sh` (the load-bearing
mappings); (b) function name renames (cosmetic). Decide based on actual
audit size.

- [ ] **Step 3: Apply the renames**

For the load-bearing mappings, replace verb-form keys with gerund equivalents:

```bash
# Before (in bin/render-prompt.sh):
STAGE_TO_SECTION=( ["brainstorm"]="1" ["plan"]="2" … )

# After:
STAGE_TO_SECTION=( ["brainstorming"]="1" ["planning"]="2" … )
```

If the function accepts user-facing CLI args, ALSO accept the verb form as
an alias for one release with a deprecation log line:

```bash
case "$stage" in
  brainstorm)  log "[deprecated] use 'brainstorming' (verb-form retained for one release)"; stage="brainstorming" ;;
  plan)        log "[deprecated] use 'planning'"; stage="planning" ;;
  implement)   log "[deprecated] use 'implementing'"; stage="implementing" ;;
  build)       log "[deprecated] use 'building'"; stage="building" ;;
esac
```

- [ ] **Step 4: Run all relevant test suites**

```bash
TARGET_REPO=/Users/rajatgoyal/code/twinning-harness bash bin/render-prompt-test.sh
TARGET_REPO=/Users/rajatgoyal/code/twinning-harness bash bin/dispatch-test.sh
TARGET_REPO=/Users/rajatgoyal/code/twinning-harness bash bin/run-stage-test.sh
```

Expected: all PASS. If any test asserts on a verb-form name in an
implementation detail, update the assertion to gerund.

- [ ] **Step 5: Commit**

```bash
git add bin/render-prompt.sh bin/dispatch.sh bin/run-stage.sh # + any other touched
git commit -m "refactor(ENG-60-T2.12): align stage names to gerund tense

Verb-form stage names (\`brainstorm\`, \`plan\`, \`implement\`, \`build\`)
become gerund (\`brainstorming\`, \`planning\`, \`implementing\`, \`building\`)
in source code. Load-bearing mappings (STAGE_TO_SECTION,
allowed_tools_for, etc.) use gerund as the canonical key. Verb-form CLI
args still work for one release via case-aliases that log a
[deprecated] line.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 2.13: Add legacy-label cleanup to orchestrator label-application

**Files:**
- Modify: `bin/verdict-handler.sh::apply_transition` (or wherever the
  orchestrator calls `linear.sh add-label`).

When the orchestrator applies a `stage:*` label as part of a transition, it
should also remove any legacy pipeline-namespace labels that may still be on
the issue from the pre-Phase-2 era. This drains legacy labels from in-flight
issues over the course of normal pipeline runs, eliminating the need for a
big-bang migration in Phase 3.

- [ ] **Step 1: Identify the label-application site**

```bash
grep -n 'add-label.*stage:\|add-label "$ident"' bin/verdict-handler.sh bin/run-stage.sh
```

Find the canonical site where the orchestrator applies a stage label.

- [ ] **Step 2: Add legacy-label cleanup**

Immediately after the `add-label` call:

```bash
# ENG-60 T2.13: drain legacy pipeline-namespace labels as we transition.
# These labels are folded into pipeline:halted / pipeline:abandoned per
# design §7.5; removing them on every transition cleans them out
# without a big-bang migration. linear.sh remove-label is a no-op when
# the label isn't present, so this is safe to run unconditionally.
for legacy in pipeline:paused pipeline:scope-approval-needed pipeline:supersede pipeline:skip-until-code-changes pipeline:skip-until-human-acts; do
  bash "$SCRIPT_DIR/linear.sh" remove-label "$issue" "$legacy" 2>/dev/null || true
done
```

- [ ] **Step 3: Run regression**

```bash
TARGET_REPO=/Users/rajatgoyal/code/twinning-harness bash bin/verdict-handler-test.sh
TARGET_REPO=/Users/rajatgoyal/code/twinning-harness bash bin/halt-sprawl-test.sh
```

Expected: all PASS. (Tests stub `linear.sh`, so the extra remove-label calls
are absorbed by the stub.)

- [ ] **Step 4: Commit**

```bash
git add bin/verdict-handler.sh
git commit -m "feat(ENG-60-T2.13): orchestrator drains legacy labels on transition

Each apply_transition call now follows the add-label invocation with
remove-label calls for the five legacy pipeline-namespace labels
(paused, scope-approval-needed, supersede, skip-until-code-changes,
skip-until-human-acts). Label removal is a no-op when the label isn't
present, so this is safe and idempotent. Drains legacy labels from
in-flight issues over normal pipeline runs.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 2.14: Create `bin/generate-vocabulary-doc.sh`

**Files:**
- Create: `bin/generate-vocabulary-doc.sh`.

A small script that reads `bin/pipeline-events.json` and emits the
registry-derived sections of `docs/pipeline-vocabulary.md`. Hand-written
sections (intro, worked examples, migration notes) live in a template file
that the script merges with the generated parts.

- [ ] **Step 1: Write the generator**

Create `bin/generate-vocabulary-doc.sh`:

```bash
#!/usr/bin/env bash
# Generate docs/pipeline-vocabulary.md from bin/pipeline-events.json +
# docs/pipeline-vocabulary.template.md. Run from the repo root.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_ROOT="$SCRIPT_DIR/.."
REG="$HARNESS_ROOT/bin/pipeline-events.json"
TEMPLATE="$HARNESS_ROOT/docs/pipeline-vocabulary.template.md"
OUT="$HARNESS_ROOT/docs/pipeline-vocabulary.md"

generated() {
  printf '## Closed event registry\n\n'
  printf 'Source: `bin/pipeline-events.json` — edit there, not here.\n\n'
  for field in verdict_results halt_reasons wait_reasons fail_targets pivot_targets decision_actions decision_gates meta_kinds stages; do
    printf '### `%s`\n\n' "$field"
    jq -r --arg f "$field" '.[$f][] | "- `" + . + "`"' "$REG"
    printf '\n'
  done
  printf '### `legacy_halt_reason_aliases`\n\n'
  jq -r '.legacy_halt_reason_aliases | to_entries[] | "- `" + .key + "` → `" + .value + "`"' "$REG"
  printf '\n'
}

# Replace the `<!-- GENERATED:registry -->` marker in the template with the
# generated content; everything outside the marker block is preserved.
awk -v gen="$(generated)" '
  /<!-- GENERATED:registry -->/  { print; print gen; in_block=1; next }
  /<!-- \/GENERATED:registry -->/{ in_block=0 }
  !in_block { print }
' "$TEMPLATE" > "$OUT"

printf 'Generated: %s\n' "$OUT"
```

- [ ] **Step 2: Create the template**

Create `docs/pipeline-vocabulary.template.md` with the hand-written portions
plus the generation marker:

```markdown
# Pipeline vocabulary

The harness's state machine is driven by HTML comments embedded in Linear
issues. There are two families:

- **`<!-- pipeline: <event> ... -->`** — drives state. Read by the orchestrator.
- **`<!-- meta: <kind> ... -->`** — bookkeeping (dedup keys, metric counters,
  evidence bundles). Read by individual scripts; never affects pipeline state.

## Writing markers

Use `bin/pipeline.sh` — never hand-craft marker bodies. The CLI validates
every field against the closed registry below and dies loudly on unknown
tokens.

- `bin/pipeline event <issue> verdict <result> [--stage X] [--target Y] [--reason Z]`
- `bin/pipeline event <issue> transition "<from> → <to>"`
- `bin/pipeline decide <issue> --action <action> [--gate <gate>]`

## Worked example: scope-violation halt → operator approval → resume

1. Implement agent finishes 6 commits cleanly:
   ```
   bin/pipeline.sh event ENG-N verdict pass --stage implementing
   ```
2. Orchestrator runs scope-check → SEVERE violation. Applies `pipeline:halted`.
3. Operator inspects, judges the touches intentional:
   ```
   bin/pipeline.sh decide ENG-N --action approve --gate scope
   ```
4. Next tick, scope-check sees the approval and bypasses the gate.

<!-- GENERATED:registry -->
<!-- /GENERATED:registry -->

## Migration notes (Phase 2 only)

Old-shape markers (`<!-- pipeline-X: value -->`) continue to be parsed by
`parse_pipeline_marker` for backwards compatibility. Phase 3 will remove the
legacy parsing branch; until then, in-flight issues with mixed-shape comment
histories are handled transparently.
```

- [ ] **Step 3: Smoke**

```bash
chmod +x bin/generate-vocabulary-doc.sh
bash bin/generate-vocabulary-doc.sh
diff docs/pipeline-vocabulary.template.md docs/pipeline-vocabulary.md | head -20
```

Expected: the diff shows the generated registry block inserted between the
markers.

- [ ] **Step 4: Commit**

```bash
git add bin/generate-vocabulary-doc.sh docs/pipeline-vocabulary.template.md
git commit -m "feat(ENG-60-T2.14): generator for docs/pipeline-vocabulary.md

bin/generate-vocabulary-doc.sh reads bin/pipeline-events.json and
fills the <!-- GENERATED:registry --> block in
docs/pipeline-vocabulary.template.md. Hand-written sections (intro,
worked example, migration notes) live in the template; the generated
glossary is added by running the script. Re-run after editing the
registry.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 2.15: Generate `docs/pipeline-vocabulary.md`; link from CLAUDE.md

**Files:**
- Create: `docs/pipeline-vocabulary.md` (committed alongside template; the
  generated artifact is checked in so readers don't need to run the generator).
- Modify: `CLAUDE.md` to link to the glossary and prune redundant inline
  vocabulary explanations.

- [ ] **Step 1: Generate and commit the glossary**

```bash
bash bin/generate-vocabulary-doc.sh
git add docs/pipeline-vocabulary.md
```

- [ ] **Step 2: Trim CLAUDE.md**

Find the "Verdict-marker protocol" subsection in `CLAUDE.md` and the
"Linear conventions" subsection. Replace the inline marker explanations
with one or two pointer lines:

```markdown
## Pipeline vocabulary

Single source of truth: `docs/pipeline-vocabulary.md` (generated from
`bin/pipeline-events.json`). All state-driving comments use
`<!-- pipeline: <event> ... -->`; bookkeeping uses `<!-- meta: <kind> ... -->`.
Use `bin/pipeline.sh` to emit markers; the helper validates against the
registry.
```

Update the "When wiring a new script" bullet (added in Task 1.6) to also
link to the glossary now that it exists.

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md docs/pipeline-vocabulary.md
git commit -m "docs(ENG-60-T2.15): publish docs/pipeline-vocabulary.md; link from CLAUDE.md

Generated glossary committed alongside the template + generator script.
CLAUDE.md's vocabulary explanations replaced with a pointer to the
single source of truth.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 2.16: Phase 2 deploy gate — manual operator validation

This is a manual checkpoint, not an agent task. After T2.0–T2.15 land:

- [ ] **Manual: pick a small live issue (or a synthetic test issue) and run
  it through brainstorming → planning → implementing → reviewing → qa →
  building → released.** Confirm:
  - Each agent emits new-shape markers in Linear comments.
  - Legacy pipeline-namespace labels are drained on each transition.
  - Operator interventions via `bin/halt.sh resolve` and `bin/post-verdict.sh`
    still work and emit deprecation log lines.
  - `bin/pipeline.sh status <issue>` produces a coherent event log.
  - No protocol violations from missing source_stage on rejections (T2.2
    fix is exercised).
  - Build-stage wait flow exercises new-shape wait markers (T2.1 fix).

- [ ] **Manual: 1-week soak.** No code changes; just observe in-flight
  issues complete on the new vocabulary. If any issue gets stuck, root-cause
  before declaring Phase 2 done.

- [ ] **Manual: write the Phase 3 detailed sub-plan** at
  `docs/plans/2026-05-XX-eng-60-phase-3-drop-old.md` based on the outline in
  the parent plan. Phase 3 begins after the soak passes.

---

## Self-review checklist (executed inline)

- **Phase 1 carryovers:** all four (rejection source_stage → T2.2; new-shape
  halt-reason aliasing → T2.0; test-helper unification → T2.3; _fresh_wait_reason
  migration → T2.1) have dedicated tasks ordered as predecessors of the
  prompt rewrite (T2.11). ✓
- **Spec coverage:** every Phase 2 acceptance criterion in the brainstorm
  doc §8 maps to a task here:
  - AC#1 (every state-driving comment uses new shape) → T2.5–T2.7 (writer) +
    T2.11 (agent prompts)
  - AC#2 (every bookkeeping uses meta:) → out of Phase 2 scope (`meta:` writers
    are Phase 3; Phase 2 keeps `pipeline-sig`/`pipeline-metric` shapes via
    parse_pipeline_marker normalization)
  - AC#3 (registry validation) → T2.5–T2.7 + T2.8 (PE3, PT2, PD6)
  - AC#4 (label collapse to {halted, abandoned, rule-reviewed}) → T2.13
    (drain) + Phase 3 (final removal)
  - AC#5 (gerund tense) → T2.12
  - AC#6 (vocabulary doc; CLAUDE.md links to it) → T2.14 + T2.15
  - AC#7 (bin/pipeline replaces halt.sh + post-verdict.sh) → T2.4–T2.7
    (CLI) + T2.9–T2.10 (wrappers); Phase 3 deletes wrappers
  - AC#8 (all *-test.sh pass + new fixtures) → tests in T2.0–T2.13
- **Placeholder scan:** Phase 2 tasks are all concrete; T2.16 is explicitly
  manual (not a code task).
- **Type consistency:** event field names (`stage`, `target`, `reason`,
  `action`, `gate`, `from`, `to`) are uniform across CLI subcommands, test
  fixtures, and `parse_pipeline_marker` output JSON. ✓

## References

- Spec: `docs/brainstorms/2026-05-02-pipeline-vocabulary-simplification-design.md`
- Phase 1 plan: `docs/plans/2026-05-02-eng-60-pipeline-vocabulary-simplification.md`
- Phase 1 branch HEAD: `feat/eng-60-pipeline-vocabulary-simplification` at `0414536`
- Linear: ENG-60
- Related (preserved by this work): ENG-41 (lane fences), ENG-45 (wait shape),
  ENG-56 (orchestrator-canonical halt applier), ENG-49 (orchestrator-canonical PR opener)
