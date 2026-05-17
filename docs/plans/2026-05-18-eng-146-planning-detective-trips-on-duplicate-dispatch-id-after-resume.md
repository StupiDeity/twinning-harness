---
linear: ENG-146
title: Preserve dispatch_id seq across success-path cleanup + scope detective grep by stage
date: 2026-05-18
status: ready
---

# ENG-146 — Plan

## Decisions

- **D-001 — strip-not-delete on success.** Replace `rm -f
  "$(issue_dir "$ident")/issue-state.json"` at `bin/run-stage.sh:849`
  and `:1970` with a shared helper that strips the file to
  `{current_dispatch_seq, current_dispatch_id, current_stage}` when
  allocator fields are present, falls through to `rm -f` otherwise
  (legacy back-compat).
- **D-002 — lift shared helper.** Place
  `strip_state_preserve_alloc <state_file>` in `bin/common.sh`.
  `bin/pipeline.sh::_pipeline_drain_issue_state` delegates to it so
  drain + success-cleanup never drift.
- **D-003 — scope detective grep by stage.** Pass `$stage` as a third
  arg to `_assert_progress_md_entry` in `bin/dispatch.sh`. Tighten the
  regex from `^## ${PIPELINE_DISPATCH_ID-} - ` to `^## ${PIPELINE_DISPATCH_ID-} - ${stage} - `.
- **D-004 — defense-in-depth, not either-or.** Ship D-001+D-002+D-003
  together. D-001 closes the structural leak; D-003 covers same-id
  cross-stage collisions even if a future bug reintroduces seq loss.

## Tasks

### Task 0 — Rebase onto origin/main

`git fetch origin && git rebase origin/main` from the worktree branch
`fix/eng-146-...`. Current main is `027d1a1`. Fail-loud on conflict —
expectation: clean rebase, only this branch's `_strip_state_preserve_alloc`
edits exist.

### Task 1 (RED → GREEN) — `strip_state_preserve_alloc` helper in common.sh

**File:** `bin/common.sh` (insert after `current_dispatch_id`, near
line ~170, before `export -f` block).

**Body:**

```bash
# ENG-146 — Strip an issue-state.json file to just the allocator-set
# subset {current_dispatch_seq, current_dispatch_id, current_stage},
# preserving the dispatch_id monotonic counter across success-path
# cleanup and operator-resume drain. When allocator fields are absent
# (legacy / pre-cutover issue) the file is rm -f'd for back-compat.
# Idempotent: missing file is a no-op success.
strip_state_preserve_alloc() {
  local state_file="$1"
  [[ -n "$state_file" ]] || return 0
  [[ -s "$state_file" ]] || return 0
  jq -e . "$state_file" >/dev/null 2>&1 || { rm -f "$state_file"; return 0; }
  local has_alloc
  has_alloc="$(jq -r 'has("current_dispatch_id") and (.current_dispatch_id // "") != ""' "$state_file" 2>/dev/null || printf 'false')"
  if [[ "$has_alloc" == "true" ]]; then
    local stripped tmp
    stripped="$(jq -c '{current_dispatch_seq, current_dispatch_id, current_stage}' "$state_file" 2>/dev/null || printf '{}')"
    tmp="${state_file}.tmp.$$"
    printf '%s' "$stripped" > "$tmp"
    mv -f "$tmp" "$state_file"
  else
    rm -f "$state_file"
  fi
}
```

Update the `export -f` line near 433 to include `strip_state_preserve_alloc`.

**Tests (RED first, then code makes them GREEN):**

Add to `bin/common-test.sh` (create if missing — check first) or
`bin/dispatch-test.sh`'s integration block. Three fixtures:

- **AC-STRIP-A** — file with `{policy: "...", retry_count: 2,
  current_dispatch_seq: 5, current_dispatch_id: "ENG-1-d0005",
  current_stage: "planning", evidence: {...}}` → after strip:
  `{current_dispatch_seq: 5, current_dispatch_id: "ENG-1-d0005",
  current_stage: "planning"}` exactly.
- **AC-STRIP-B** — file with no allocator fields (legacy):
  `{policy: "...", retry_count: 2}` → file removed (`! -e
  "$state_file"`).
- **AC-STRIP-C** — corrupt JSON: `not-json-content` → file removed.
- **AC-STRIP-D** — missing file → no-op (return 0; file still
  absent).

### Task 2 (RED → GREEN) — wire run-stage.sh success cleanups to the helper

**File:** `bin/run-stage.sh`.

**Sites:**
- Line 849 (`_pre_dispatch_merge_gate`): replace `rm -f
  "$(issue_dir "$ident")/issue-state.json" 2>/dev/null || true` with
  `strip_state_preserve_alloc "$(issue_dir "$ident")/issue-state.json"
  2>/dev/null || true`.
- Line 1970 (success path `vh_rc=0`): identical replacement.

**Test (RED first):**

Add `AC-SUCCESS-PRESERVES-SEQ` in `bin/run-stage-test.sh`. Fixture:

1. Pre-populate `$(issue_dir ENG-X)/issue-state.json` with `{policy:
   "...", current_dispatch_seq: 3, current_dispatch_id: "ENG-X-d0003",
   current_stage: "brainstorming"}`.
2. Source `run-stage.sh`, simulate the success branch by calling a
   helper or sourcing the function in question (the existing tests do
   this).
3. Assert the file still exists.
4. Assert `jq -r '.current_dispatch_seq' file` returns `3`.
5. Assert `jq -e '.policy' file` returns non-zero (policy stripped).

### Task 3 (RED → GREEN) — delegate drain to the shared helper

**File:** `bin/pipeline.sh::_pipeline_drain_issue_state`.

Replace the inline `if has_alloc` / `if not` block (lines ~228–243)
with a delegation to `strip_state_preserve_alloc` plus its existing
state_drained accounting.

**Test (RED first):**

The existing drain tests (search `_pipeline_drain_issue_state` in
`bin/pipeline-test.sh`) should still pass unchanged after delegation.
Add `AC-DRAIN-DELEGATES` asserting the shared helper is called (e.g.,
via `bash -x` trace OR by shimming the helper to write a sentinel and
asserting the sentinel exists after drain).

### Task 4 (RED → GREEN) — scope detective grep by stage

**File:** `bin/dispatch.sh`.

Change `_assert_progress_md_entry()`'s signature to take a third arg
`stage`. Tighten the grep:

```bash
_assert_progress_md_entry() {
  local issue_dir="$1" violation_file="$2" stage="$3"
  ...
  entry_count="$(grep -c "^## ${PIPELINE_DISPATCH_ID-} - ${stage} - " "$progress_path" 2>/dev/null || printf 0)"
  ...
}
```

Update the call site at `bin/dispatch.sh:289` to pass `$stage` as the
third arg.

**Test (RED first):**

Extend `bin/dispatch-test.sh`'s PG/QA fixtures. Add a new fixture
`AC-DETECTIVE-STAGE-SCOPED`:

1. Fixture `progress.md` with TWO entries under the same dispatch_id
   but different stages:
   ```
   ## ENG-X-d0007 - brainstorming - 2026-05-18T01:00:00Z
   foo
   ## ENG-X-d0007 - planning - 2026-05-18T01:05:00Z
   bar
   ```
2. `PIPELINE_DISPATCH_ID=ENG-X-d0007` then call
   `_assert_progress_md_entry "$dir" "$violation_file" "planning"` →
   return 0 (count is 1, not 2).
3. Repeat with `stage="brainstorming"` → return 0.
4. Pre-fix regression: with the old stage-blind grep, count=2 →
   return 31.

### Task 5 (smoke) — full pre-commit gate suite green

`bash .githooks/pre-commit` exits 0. Cover any sibling tests that
might brittle on the helper move.

### Task 6 — content pins (anti-regression)

- `bin/common.sh` exports `strip_state_preserve_alloc`.
- `bin/run-stage.sh` no longer contains `rm -f.*issue-state.json` —
  pin `grep -c 'rm -f.*issue-state.json' bin/run-stage.sh` returns 0.
- `bin/run-stage.sh` calls `strip_state_preserve_alloc` at exactly
  the two sites (lines that previously held the rm).
- `bin/dispatch.sh::_assert_progress_md_entry` grep regex contains
  literal `\${stage}` reference (or interpolated `$stage` — pin the
  source line).
- `bin/pipeline.sh::_pipeline_drain_issue_state` calls
  `strip_state_preserve_alloc` (delegation pin).

## Risks

- **R-1 (low).** `_pre_dispatch_merge_gate` (line 849) transitions
  `building → released`; downstream consumers of state for the
  released stage are empty (terminal). Strip-not-delete is harmless
  but unnecessary. Cost is symmetry with the other site. Accept.
- **R-2 (medium).** If a future stage's classify-failure code stomps
  the seq when re-writing under a different policy (e.g., torn write
  recovery), the helper alone doesn't catch it. The shared regression
  test in Task 1 + the scoped detective in Task 4 mitigate; defer
  the broader merge-idiom audit to a sibling ticket if any AC #2
  flake materializes.
- **R-3 (low).** Tests rely on jq filtering correctly emitting
  `{seq, id, stage}` keys when the input lacks one (jq emits `null`
  for missing). Allocator's `// 0` fallback covers seq; id and stage
  re-emit empty string. Manual one-shot validation passes — pin the
  schema in AC-STRIP-A.

## Anti-pattern check

- No premature abstraction: `strip_state_preserve_alloc` collapses
  three existing inline blocks (two rm sites + drain's strip block)
  into one — reduction of duplication, not creation of abstraction.
- No half-finished implementation: D-001 + D-002 + D-003 together
  close the bug fully; partial application leaves a known gap.
- No new comments other than the helper's docstring + the AC-pinned
  test description headers.

## Out of scope

- The seq-counter persistence model (file-level, separate file, db).
  See brainstorm §6 OQ-2.
- Status surface (`bin/status.sh`) reporting of seq. See brainstorm
  §6 (deferred).
- ENG-87 review-iter-2 merge-idiom audit in classify-failure (no
  evidence it's leaky on the canonical path).
