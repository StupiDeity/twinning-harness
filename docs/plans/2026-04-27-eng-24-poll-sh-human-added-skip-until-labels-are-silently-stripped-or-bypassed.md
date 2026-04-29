---
linear: ENG-24
date: 2026-04-27
topic: poll.sh respects human-added pipeline:skip-until-* labels (Bug A inbox filter + Bug B orphan-label branch)
spec: docs/brainstorms/2026-04-27-poll-sh-human-added-skip-until-labels-are-silently-stripped-or-bypassed-design.md
status: draft
---

# poll.sh respects human-added `pipeline:skip-until-*` labels — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

## 1. Goal

After this plan lands, an issue carrying `pipeline:skip-until-human-acts` or
`pipeline:skip-until-code-changes` is never dispatched and never has the label
silently removed by `poll.sh`, regardless of whether the issue is in `Todo`
(inbox) or in a `stage:*` label and regardless of whether
`$PROJECT_STATE_DIR/<issue>/issue-state.json` exists; verified by
`bash bin/poll-slot-test.sh` printing `RESULTS: <≥10> passed, 0 failed` with
new cases AC-8, AC-9, and AC-10.

## 2. Anti-anchoring check (mandatory)

**Problem restatement (user perspective).** "I add `pipeline:skip-until-human-acts`
to an ENG-N to pause the pipeline. On the next tick the orchestrator either
ignores the label and dispatches the issue anyway, or strips the label and
dispatches the issue. Either way my pause is silently undone."

**Does the brainstorm's solution address that problem?** Yes — directly. The
brainstorm fixes the two and only two `poll.sh` sites where the contract
documented in `bin/setup-labels.sh:38` is contradicted by code: the Pass 5
inbox-pickup jq filter (Bug A) and the `_poll_evaluate_skip` orphan-label
branch (Bug B). No reframe.

**Is the solution proportional?** Yes. ~10 lines of net diff in one source
file, plus three test cases in an existing test file. No new files, no new
script, no new ADR, no behavior change in `classify-failure.sh`,
`setup-labels.sh`, or downstream stages. The brainstorm explicitly rejected
three over-engineered alternatives (refactor inbox to call
`_poll_evaluate_skip`, special-case `human-acts` only, auto-seed a state
file).

Both checks pass; proceeding.

## 3. Assumption Inventory

Every fact below is grounded in the current worktree (HEAD of
`fix/eng-24-poll-sh-human-added-skip-until-labels-are-silently-stripped-or-bypassed`).
Per-row citations follow the brainstorm's §8.3 inventory and were re-verified
by direct `Read`/`Grep` against `bin/` during plan authoring.

### 3.1 Modified files — current shape

#### `bin/poll.sh:45-69` — `_poll_evaluate_skip` and the orphan-label branch

Current source (verbatim, indentation preserved):

```bash
# bin/poll.sh:45
_poll_evaluate_skip() {
  local ident="$1" labels_json="$2"
  local state_file; state_file="$(issue_dir "$ident")/issue-state.json"
  local has_code_label has_human_label
  has_code_label="$(jq -r --arg n "pipeline:skip-until-code-changes" \
    '[.[] | select(. == $n)] | length > 0' <<<"$labels_json")"
  has_human_label="$(jq -r --arg n "pipeline:skip-until-human-acts" \
    '[.[] | select(. == $n)] | length > 0' <<<"$labels_json")"

  # No skip label AND no state file → normal eligible candidate.
  if [[ "$has_code_label" != "true" && "$has_human_label" != "true" ]]; then
    if [[ -f "$state_file" ]]; then
      log "poll: orphan state file for $ident (no skip label); removing"
      rm -f "$state_file"
    fi
    return 0
  fi

  # bin/poll.sh:63-69  ← THIS IS THE BRANCH BEING REPLACED IN TASK 1.
  # Label without file → orphan; remove label, include.
  if [[ ! -f "$state_file" ]]; then
    log "poll: orphan skip label on $ident (no state file); clearing"
    [[ "$has_code_label" == "true" ]]  && bash "$SCRIPT_DIR/linear.sh" remove-label "$ident" "pipeline:skip-until-code-changes" || true
    [[ "$has_human_label" == "true" ]] && bash "$SCRIPT_DIR/linear.sh" remove-label "$ident" "pipeline:skip-until-human-acts"   || true
    return 0
  fi
```

Function signature is preserved. Return-code contract is preserved (0 = include,
1 = skip). The only change is the body of the branch at `:63-69`.

#### `bin/poll.sh:427-446` — Pass 5 inbox-pickup jq filter

Current source (verbatim):

```bash
# bin/poll.sh:427
  local inbox_state
  inbox_state="$(config_get '.linear.native_states.inbox')"
  local inbox_pick
  inbox_pick="$(bash "$SCRIPT_DIR/linear.sh" list-issues-in-state "$inbox_state" \
    | jq -r '
      [.data.issues.nodes[]
       | select([.labels.nodes[].name] | any(startswith("stage:")) | not)
       | select([.labels.nodes[].name] | index("pipeline:paused") | not)
       | select([.labels.nodes[].name] | index("pipeline:abandoned") | not)
       | {identifier: .identifier,
          priority_sort_rank: (if (.priority // 0) == 0 then 0 else (5 - .priority) end)}]
      | sort_by(-.priority_sort_rank)
      | .[0].identifier // ""')"
```

Note on line drift: the Linear issue cites `:316-325`; the actual lines on
this branch are `:427-446`. The structural match (`select(...)
startswith("stage:")` followed by two `index("pipeline:paused"|
"pipeline:abandoned")` excludes) is exact. The Linear issue was filed against
an earlier line layout; the bug is the same.

#### `bin/poll.sh:186-232` — `_poll_classify_labels` (call site of `_poll_evaluate_skip`)

```bash
# bin/poll.sh:186
_poll_classify_labels() {
  local ident="$1" labels_json="$2"
  local refreshed_labels=""

  if ! refreshed_labels="$(_poll_evaluate_skip "$ident" "$labels_json")"; then
    jq -nc --argjson l "$labels_json" '{slot:"vacate",advanceable:false,labels:$l}'
    return 0
  fi
  …
}
```

Call site unchanged. A non-zero return from `_poll_evaluate_skip` (the new
branch's behavior on label-without-state-file) maps to `slot:"vacate",
advanceable:false`, which is exactly the behavior we need.

#### `bin/poll.sh:452-454` — sentinel

```bash
# bin/poll.sh:452
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
```

Test file already sources via this sentinel; no change.

#### `bin/poll-slot-test.sh:62-87` — `linear.sh` stub with `LINEAR_STUB_LOG`

```bash
# bin/poll-slot-test.sh:62
cat > "$STUB_DIR/linear.sh" <<'SH'
#!/usr/bin/env bash
case "$1" in
  list-issues-with-label)   …  ;;
  list-issues-in-state)     …  ;;
  get-comments)             …  ;;
  remove-label|add-label|swap-stage|transition-state|add-comment|add-or-update-comment|refresh-cache|stage-of|has-label)
    [[ -n "${LINEAR_STUB_LOG:-}" ]] && printf '%s\n' "$*" >> "$LINEAR_STUB_LOG"
    exit 0
    ;;
  *) exit 0 ;;
esac
SH
```

The stub appends `<subcommand> <args...>` (a single space-separated line per
call) to `$LINEAR_STUB_LOG`. New tests assert exact-line absence with
`grep -Fxq` to guard against future unrelated `remove-label` calls relaxing
the regression guard. (Persona P2 from brainstorm §10.)

#### `bin/poll-slot-test.sh:159-206` — fixture writers

`write_label_fixture <stage_label> <issue_spec>...` and
`write_inbox_fixture <issue_spec>...` are defined here. Issue spec format:
`"ENG-N|state_name|priority_int|comma,separated,labels"`. New tests reuse
both verbatim.

#### `bin/poll-slot-test.sh:412-446` — AC-7 (last existing case) and `# ─── Summary ───`

```bash
# bin/poll-slot-test.sh:412
# ─── AC-7: auto-resume is a no-op when pipeline:halted is absent ──────
…
fi

# ─── Summary ──────────────────────────────────────────────────────────
printf '\nRESULTS: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]] || exit 1
exit 0
```

New AC-8/AC-9/AC-10 cases append between the trailing `fi` of AC-7
(`bin/poll-slot-test.sh:446`) and the `# ─── Summary ───` line
(`bin/poll-slot-test.sh:448`).

### 3.2 Read-only references (verified, unmodified)

| # | Fact | Citation |
|---|---|---|
| R1 | `_poll_evaluate_skip` is the sole skip-decision point. | `bin/poll.sh:45-116`, called at `bin/poll.sh:190`. |
| R2 | `pipeline:skip-until-human-acts` contract: "skipped until a human resolves … and removes this label." | `bin/setup-labels.sh:38`. |
| R3 | `pipeline:skip-until-code-changes` contract: auto-resumes on hash/SHA change OR label removal. | `bin/setup-labels.sh:37`; resume comment template at `bin/classify-failure.sh:128-129`. |
| R4 | Pipeline-side label apply. | `bin/classify-failure.sh:100-108` (`case "$effective_policy" in skip-until-code-changes) … skip-until-human-acts) …`). |
| R5 | `issue_dir` resolves `$PROJECT_STATE_DIR/<issue>` and is the canonical state-file location. | `bin/common.sh:61-65`. |
| R6 | `compute_pipeline_content_hash` is exported from common.sh. | `bin/common.sh:148`. |
| R7 | Labels existing today: `pipeline:halted`, `pipeline:abandoned`, `pipeline:paused`, `pipeline:scope-approval-needed`, `pipeline:skip-until-code-changes`, `pipeline:skip-until-human-acts`. | `bin/setup-labels.sh:28-38`. |
| R8 | `pipeline:paused` is already filtered correctly in the inbox path — the precedent. | `bin/poll.sh:434`. |
| R9 | Test scaffolding (`PIPELINE_DRY_RUN=1`, `STUB_DIR`, `PROJECT_STATE_DIR`, `LINEAR_STUB_LOG`, `CONFIG`, `git()` override, `write_label_fixture`, `write_inbox_fixture`, `pass_at`/`fail_at`). | `bin/poll-slot-test.sh:1-222`. |
| R10 | Pass 4 `advanceable:false` items are not dispatched; Pass 5 inbox query is keyed on `Todo` (the configured `inbox` native state). | `bin/poll.sh:397-399`, `bin/poll.sh:430` (`list-issues-in-state "$inbox_state"`). |
| R11 | The repo has no `docs/architecture/`, no `docs/knowledge/`, no `docs/VISION.md`. The harness's design source-of-truth is `CLAUDE.md` + `AGENT_PROMPTS.md`. | `ls docs/` → `brainstorms/`, `plans/` only. The framework boilerplate in the prompt template (Tauri/SvelteKit/Rust, ADR list filtering, Tauri Command API Contract) is N/A for this bash-only fix. |

### 3.3 Assumed/new artifacts

| # | Artifact | Status | Where |
|---|---|---|---|
| N1 | Test cases AC-8, AC-9, AC-10. | new | Appended to `bin/poll-slot-test.sh` between line 446 (`fi` of AC-7) and line 448 (`# ─── Summary ───`). |

No other new artifacts. No new files. No `learned-rules/**` writes.

## 4. File Structure

| File | Action | Responsibility |
|---|---|---|
| `bin/poll.sh` | Modify | Two surgical edits: (a) replace orphan-label branch at `:63-69` so a skip label without a state file returns 1 (skip) and performs no Linear writes; (b) add two `select(...)` clauses to the Pass 5 inbox jq filter at `:434-435` excluding both `pipeline:skip-until-*` labels. |
| `bin/poll-slot-test.sh` | Modify | Append three regression test cases (AC-8 Bug A inbox filter; AC-9 Bug B orphan branch — `human-acts` flavor; AC-10 Bug B orphan branch — `code-changes` flavor) before the existing `# ─── Summary ───` block at `:448`. |

No other files touched. No new files. No `AGENT_PROMPTS.md`,
`learned-rules/**`, `bin/classify-failure.sh`, `bin/setup-labels.sh`, or
`config.json` changes. The Linear issue's "OUT" boundaries §1, §2, §3, §4
are honored by this scope.

## 5. Command API Contract

**No new command API.** This is a bash-only fix in two existing shell
scripts. No Tauri commands, no Rust types, no TS types, no events. The
prompt template's Tauri/SvelteKit framing does not apply (R11). Backend and
frontend agents will read this section, see "no new command API", and there
will be no drift to find at review time.

## 6. Backend Tasks

The Implementation Agent owns these tasks. Tasks 1 and 2 modify `bin/poll.sh`
in two non-overlapping regions (`:63-69` and `:434-435`); they are
independent at the function level and could in principle run in parallel,
but they share a file so they SHOULD be serialized to keep the diff
reviewable. Tasks 3a/3b/3c are independent of each other (each appends a
fresh test case) but all depend on Tasks 1 and 2 (their assertions describe
post-fix behavior). Task 4 is the gating verification.

### Task 1: Replace orphan-skip-label branch in `_poll_evaluate_skip`

- `depends_on: []`
- `touches: bin/poll.sh:_poll_evaluate_skip`

- [ ] **Step 1.1 — Read `bin/poll.sh:45-116`** to confirm the function shape
  matches the Assumption Inventory §3.1 quote. If the branch at `:63-69` no
  longer matches the four-line "Label without file → orphan" form, STOP and
  flag — the plan was written against this exact text.

- [ ] **Step 1.2 — Replace lines `:63-69` of `bin/poll.sh`** with the
  honor-the-label form below. The replacement preserves the function's
  return-code contract (0 = include, 1 = skip), so callers (`_poll_classify_labels`
  at `bin/poll.sh:190`) need no change.

  ```bash
  # Skip label present without a state file → respect the label and skip.
  # Either a human applied it (the documented contract — see
  # bin/setup-labels.sh:38) or classify-failure.sh has not yet written the
  # state file. In every case, the conservative default is to leave the
  # label in place and let either a human remove-label call or the next
  # classify-failure.sh write resolve. Do NOT call linear.sh remove-label
  # here — that silently undid human pauses (ENG-24 Bug B).
  if [[ ! -f "$state_file" ]]; then
    log "poll: $ident has skip label without state file (code=$has_code_label human=$has_human_label); skipping"
    return 1
  fi
  ```

  Notes:
  - The log line names which label(s) are present (`code=$has_code_label
    human=$has_human_label`) per persona P2 (brainstorm §10). It does NOT
    assert the label is "human-applied", because at this read site the
    cause cannot be disambiguated.
  - The two `bash "$SCRIPT_DIR/linear.sh" remove-label …` calls are
    deleted; this is the entire fix for Bug B.
  - The `[[ "$has_code_label" == "true" ]]` short-circuit and the
    `||true` swallow are both deleted with the calls.

- [ ] **Step 1.3 — Update the function-header comment at `bin/poll.sh:40-44`.**
  The current comment claims "for orphan labels (no state file), removes
  the label and includes the candidate." That claim is now false. Replace
  with:

  ```bash
  # Return 0 iff the candidate should be INCLUDED (i.e., not currently in a
  # resolved-but-cleared skip state). Side effects: if the skip state's
  # evidence has changed, deletes the state file, removes the
  # skip-until-code-changes label, and (if pipeline:halted is also present)
  # clears the halt label and posts a pipeline-decision: resume marker.
  # For orphan state files (label absent), deletes the state file. For a
  # skip label without a state file, skips and performs no Linear writes
  # — see ENG-24.
  ```

- [ ] **Step 1.4 — Verify shell syntax** locally:

  ```bash
  bash -n bin/poll.sh
  ```
  Expected: no output, exit 0.

- [ ] **Step 1.5 — Commit.**

  ```bash
  git add bin/poll.sh
  git commit -m "fix(ENG-24): poll.sh respects human-added skip-until-* labels (Bug B)

  _poll_evaluate_skip's orphan-skip-label branch silently stripped the
  label and included the candidate, undoing any human-applied
  pipeline:skip-until-human-acts or pipeline:skip-until-code-changes pause.
  Honor the label instead: return 1 (skip), perform no Linear writes."
  ```

### Task 2: Extend the Pass 5 inbox-pickup jq filter

- `depends_on: [1]`  (same file as Task 1; serialize for reviewability)
- `touches: bin/poll.sh:main (Pass 5 inbox-pickup block)`

- [ ] **Step 2.1 — Read `bin/poll.sh:427-446`** and confirm the jq filter
  contains the two existing `select(...) index("pipeline:paused")` and
  `select(...) index("pipeline:abandoned")` exclusions.

- [ ] **Step 2.2 — Insert two filter clauses** immediately after the
  existing `pipeline:abandoned` exclusion, modelled byte-for-byte on it.
  After the edit, the filter at `bin/poll.sh:431-439` reads:

  ```bash
    inbox_pick="$(bash "$SCRIPT_DIR/linear.sh" list-issues-in-state "$inbox_state" \
      | jq -r '
        [.data.issues.nodes[]
         | select([.labels.nodes[].name] | any(startswith("stage:")) | not)
         | select([.labels.nodes[].name] | index("pipeline:paused") | not)
         | select([.labels.nodes[].name] | index("pipeline:abandoned") | not)
         | select([.labels.nodes[].name] | index("pipeline:skip-until-human-acts") | not)
         | select([.labels.nodes[].name] | index("pipeline:skip-until-code-changes") | not)
         | {identifier: .identifier,
            priority_sort_rank: (if (.priority // 0) == 0 then 0 else (5 - .priority) end)}]
        | sort_by(-.priority_sort_rank)
        | .[0].identifier // ""')"
  ```

  - Spelling MUST match `bin/setup-labels.sh:37-38` exactly:
    `pipeline:skip-until-human-acts`, `pipeline:skip-until-code-changes`.
    Copy-paste from `bin/setup-labels.sh` rather than retyping (security
    persona P0-mitigation, brainstorm §10).
  - No other line in this `inbox_pick=` assignment changes — the
    `priority_sort_rank` shaping, `sort_by`, and `.[0].identifier // ""`
    fall-through stay byte-for-byte identical.

- [ ] **Step 2.3 — Verify shell syntax** locally:

  ```bash
  bash -n bin/poll.sh
  ```
  Expected: no output, exit 0.

- [ ] **Step 2.4 — Commit.**

  ```bash
  git add bin/poll.sh
  git commit -m "fix(ENG-24): poll.sh inbox filter excludes skip-until-* labels (Bug A)

  Pass 5 inbox-pickup picked up Todo issues carrying only a
  pipeline:skip-until-* label and dispatched them into stage:brainstorming.
  Mirror the existing pipeline:paused/pipeline:abandoned exclusions for
  both skip-until labels."
  ```

### Task 3a: Append AC-8 — Bug A regression (inbox filter)

- `depends_on: [2]`  (asserts post-fix Pass 5 behavior)
- `touches: bin/poll-slot-test.sh (insertion before # ─── Summary ───)`

- [ ] **Step 3a.1 — Locate the insertion point** at `bin/poll-slot-test.sh`,
  immediately before the line `# ─── Summary ──────────────────────────────────────────────────────────`
  (currently `:448`). Append to this region; do NOT modify earlier cases.

- [ ] **Step 3a.2 — Append AC-8** verbatim:

  ```bash
  # ─── AC-8: ENG-24 Bug A — Todo with skip-until-human-acts is NOT inbox-picked ──
  # A Todo issue carrying only pipeline:skip-until-human-acts (no state
  # file, no stage:* label) must be skipped by Pass 5's inbox jq filter.
  # Pre-fix: the issue was dispatched into stage:brainstorming.
  reset_fixtures
  write_inbox_fixture \
    "ENG-8001|Todo|3|Bug,pipeline:skip-until-human-acts"
  out="$(main 2>/dev/null || true)"
  issue_id="$(jq -r '.issue_id // "null"' <<<"$out")"
  if [[ "$issue_id" == "null" ]]; then
    pass_at "AC-8 Bug A — Todo with skip-until-human-acts is NOT inbox-picked"
  else
    fail_at "AC-8 Bug A — Todo with skip-until-human-acts is NOT inbox-picked" "out=$out"
  fi

  # AC-8b: same shape, code-changes label flavor.
  reset_fixtures
  write_inbox_fixture \
    "ENG-8002|Todo|3|Bug,pipeline:skip-until-code-changes"
  out="$(main 2>/dev/null || true)"
  issue_id="$(jq -r '.issue_id // "null"' <<<"$out")"
  if [[ "$issue_id" == "null" ]]; then
    pass_at "AC-8b Bug A — Todo with skip-until-code-changes is NOT inbox-picked"
  else
    fail_at "AC-8b Bug A — Todo with skip-until-code-changes is NOT inbox-picked" "out=$out"
  fi
  ```

  Notes:
  - Uses `write_inbox_fixture` (same as AC-2/AC-3) — exists at
    `bin/poll-slot-test.sh:185-206`.
  - Asserts `issue_id == "null"` (i.e., `main` emitted no dispatch).
    `main`'s idle path emits no JSON (`idle "no-work"` at
    `bin/poll.sh:449`); the `jq -r '.issue_id // "null"'` extraction
    yields `null` on empty input.
  - No `LINEAR_STUB_LOG` capture needed — AC-8 only asserts non-dispatch.

- [ ] **Step 3a.3 — Run the test file** and confirm AC-8 (and AC-8b) pass:

  ```bash
  bash bin/poll-slot-test.sh
  ```
  Expected (fragment): `✅ AC-8 Bug A — Todo with skip-until-human-acts is NOT inbox-picked`
  and `✅ AC-8b Bug A — Todo with skip-until-code-changes is NOT inbox-picked`,
  trailing line `RESULTS: <≥9> passed, 0 failed`.

- [ ] **Step 3a.4 — Commit.**

  ```bash
  git add bin/poll-slot-test.sh
  git commit -m "test(ENG-24): AC-8 Todo with skip-until-* is NOT inbox-picked (Bug A)"
  ```

### Task 3b: Append AC-9 — Bug B regression (orphan branch, human-acts)

- `depends_on: [1]`  (asserts post-fix `_poll_evaluate_skip` behavior)
- `touches: bin/poll-slot-test.sh (insertion after AC-8b, before # ─── Summary ───)`

- [ ] **Step 3b.1 — Append AC-9** after AC-8b and before `# ─── Summary ───`:

  ```bash
  # ─── AC-9: ENG-24 Bug B — stage-labeled + skip-until-human-acts + no state file ──
  # An issue carrying stage:planning AND pipeline:skip-until-human-acts AND
  # NO state file must vacate its slot AND the label must NOT be stripped
  # by poll. Pre-fix: _poll_evaluate_skip's orphan-label branch fired
  # `linear.sh remove-label ENG-9001 pipeline:skip-until-human-acts` then
  # returned 0 (include).
  reset_fixtures
  write_label_fixture "stage:planning" \
    "ENG-9001|In Progress|3|Bug,stage:planning,pipeline:skip-until-human-acts"
  # No mkdir / no issue-state.json — exercises the no-state-file path.

  LINEAR_STUB_LOG="$STUB_DIR/linear-calls-ac9.log"
  : > "$LINEAR_STUB_LOG"
  export LINEAR_STUB_LOG

  out="$(main 2>/dev/null || true)"
  issue_id="$(jq -r '.issue_id // "null"' <<<"$out")"

  # Negative assertion: the EXACT line `remove-label ENG-9001
  # pipeline:skip-until-human-acts` must not appear in the stub log.
  # `grep -Fxq` matches a full line literally (no regex), so a future
  # unrelated remove-label on ENG-9001 (different label) cannot relax
  # this guard. Persona P2, brainstorm §10.
  stripped=0
  grep -Fxq 'remove-label ENG-9001 pipeline:skip-until-human-acts' "$LINEAR_STUB_LOG" && stripped=1

  unset LINEAR_STUB_LOG

  if [[ "$issue_id" != "ENG-9001" ]] && (( stripped == 0 )); then
    pass_at "AC-9 Bug B — stage+skip-until-human-acts (no state file) vacates and preserves label"
  else
    fail_at "AC-9 Bug B — stage+skip-until-human-acts (no state file) vacates and preserves label" \
      "issue=$issue_id stripped=$stripped"
  fi
  ```

  Notes:
  - Asserts dispatch-target ≠ ENG-9001 (vacate semantics — Pass 5 may
    still emit `idle "no-work"`, in which case `issue_id` is `"null"`,
    which also satisfies `!= "ENG-9001"`).
  - The `grep -Fxq` exact-line match guards against a future change that
    legitimately calls `remove-label ENG-9001 stage:planning` (or any
    other label) on this issue while still failing the regression as
    intended.

- [ ] **Step 3b.2 — Run the test file** and confirm AC-9 passes.

- [ ] **Step 3b.3 — Commit.**

  ```bash
  git add bin/poll-slot-test.sh
  git commit -m "test(ENG-24): AC-9 stage+skip-until-human-acts no state file vacates without stripping (Bug B)"
  ```

### Task 3c: Append AC-10 — Bug B regression (orphan branch, code-changes)

- `depends_on: [1]`  (same fix as AC-9, different label flavor)
- `touches: bin/poll-slot-test.sh (insertion after AC-9, before # ─── Summary ───)`

This case proves the brainstorm's D-2 claim that uniform treatment of both
skip-until-* flavors is correct. It is a P0 in the brainstorm's §9; without
it, a future regression that special-cases only `human-acts` would not be
caught.

- [ ] **Step 3c.1 — Append AC-10** after AC-9 and before `# ─── Summary ───`:

  ```bash
  # ─── AC-10: ENG-24 Bug B (uniformity) — same as AC-9 with code-changes label ──
  # The orphan-label branch must treat both skip-until-* labels identically:
  # vacate, no Linear writes. AC-10 guards the uniformity claim that drives
  # D-2's rationale (brainstorm §2 D-2 "Why uniformity is correct").
  reset_fixtures
  write_label_fixture "stage:planning" \
    "ENG-9002|In Progress|3|Bug,stage:planning,pipeline:skip-until-code-changes"
  # No mkdir / no issue-state.json.

  LINEAR_STUB_LOG="$STUB_DIR/linear-calls-ac10.log"
  : > "$LINEAR_STUB_LOG"
  export LINEAR_STUB_LOG

  out="$(main 2>/dev/null || true)"
  issue_id="$(jq -r '.issue_id // "null"' <<<"$out")"

  stripped=0
  grep -Fxq 'remove-label ENG-9002 pipeline:skip-until-code-changes' "$LINEAR_STUB_LOG" && stripped=1

  unset LINEAR_STUB_LOG

  if [[ "$issue_id" != "ENG-9002" ]] && (( stripped == 0 )); then
    pass_at "AC-10 Bug B uniformity — stage+skip-until-code-changes (no state file) vacates and preserves label"
  else
    fail_at "AC-10 Bug B uniformity — stage+skip-until-code-changes (no state file) vacates and preserves label" \
      "issue=$issue_id stripped=$stripped"
  fi
  ```

- [ ] **Step 3c.2 — Run the test file** and confirm AC-10 passes:

  ```bash
  bash bin/poll-slot-test.sh
  ```
  Expected trailing line: `RESULTS: <≥10> passed, 0 failed`.

- [ ] **Step 3c.3 — Commit.**

  ```bash
  git add bin/poll-slot-test.sh
  git commit -m "test(ENG-24): AC-10 stage+skip-until-code-changes uniform with human-acts (Bug B)"
  ```

### Task 4: Full regression sweep + supporting test files

- `depends_on: [3a, 3b, 3c]`
- `touches: (none — verification only)`

- [ ] **Step 4.1 — Run all test files in `bin/*-test.sh`** to confirm no
  unrelated regression:

  ```bash
  for t in bin/*-test.sh; do
    echo "== $t =="
    bash "$t" || { echo "FAILED: $t"; exit 1; }
  done
  ```
  Expected: every test file exits 0. Specifically:
  - `bin/poll-slot-test.sh` reports `RESULTS: <≥10> passed, 0 failed`
    (AC-1..AC-7 unchanged + AC-8/AC-8b/AC-9/AC-10 new).
  - `bin/classify-failure-test.sh`, `bin/reconcile-test.sh`,
    `bin/run-stage-test.sh`, `bin/scope-check-test.sh`,
    `bin/verdict-handler-test.sh`, `bin/halt-sprawl-test.sh`,
    `bin/halt-sprawl-adversarial-test.sh`, `bin/run-local-sweep-test.sh`,
    `bin/run-local-helpers-adversarial-test.sh`,
    `bin/verdict-adversarial-test.sh` all exit 0 unchanged.

- [ ] **Step 4.2 — Sanity-grep that the fix is actually present** (defensive
  guard against the AGENT_PROMPTS.md fence-counting class of subtle
  reverts):

  ```bash
  # The two filter clauses must be present.
  grep -F 'index("pipeline:skip-until-human-acts")'   bin/poll.sh
  grep -F 'index("pipeline:skip-until-code-changes")' bin/poll.sh
  # The orphan-branch log line must be GONE (this is the single, unambiguous
  # signature of the deleted branch — the orphan `remove-label` calls were
  # the only ones in `_poll_evaluate_skip` paired with this exact log
  # message).
  ! grep -F 'orphan skip label on' bin/poll.sh
  # The new "skipping" log line MUST be present.
  grep -F 'has skip label without state file' bin/poll.sh
  ```
  The three positive `grep -F` calls must each print exactly one line. The
  one `! grep -F` guard must print nothing and exit 0 (the `!` inverts
  grep's exit). NB: do not write a broader `grep -nE 'remove-label .*
  pipeline:skip-until-…' bin/poll.sh` here — it would false-positive on
  the legitimate auto-resume `remove-label` at `bin/poll.sh:91` (the
  evidence-changed branch in `_poll_evaluate_skip`, which this fix does
  NOT touch).

- [ ] **Step 4.3 — Confirm no unrelated diff** before handing off:

  ```bash
  git status -s
  git log --oneline origin/main..HEAD
  ```
  Expected: `git status -s` reports clean tree; `git log` shows the four
  ENG-24 commits from Tasks 1, 2, 3a, 3b, 3c (or fewer if Tasks were
  squashed by the implementer; the harness does not require one-commit-per-
  task).

## 7. Frontend Tasks

**No frontend changes.** This is a fix in two bash scripts under `bin/`. The
harness has no frontend; the only "UI" is the Linear comment surface, and
no Linear comment template changes (verdict-marker shapes, halt comments,
resume markers) are introduced or modified by this fix.

## 8. Failure Mode → Test Map

Each row binds a brainstorm Edge Case (§6) or Error-Handling row (§5) to a
concrete named test. QA reads this table verbatim.

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
|---|---|---|---|---|
| **Bug A** Todo issue with only `pipeline:skip-until-human-acts` is inbox-picked. | `bash bin/poll-slot-test.sh` AC-8 fixture: one Todo issue, label `pipeline:skip-until-human-acts`, no state file. | `main` emits no dispatch JSON (`issue_id == null`). | unit | `AC-8 Bug A — Todo with skip-until-human-acts is NOT inbox-picked` (`bin/poll-slot-test.sh`) |
| **Bug A (uniform)** Todo issue with only `pipeline:skip-until-code-changes` is inbox-picked. | AC-8b fixture: one Todo issue, label `pipeline:skip-until-code-changes`, no state file. | `main` emits no dispatch JSON. | unit | `AC-8b Bug A — Todo with skip-until-code-changes is NOT inbox-picked` (`bin/poll-slot-test.sh`) |
| **Bug B (human-acts)** stage-labeled issue with skip-label and no state file is dispatched and the label stripped. | AC-9 fixture: `stage:planning`+`pipeline:skip-until-human-acts`, no state file, `LINEAR_STUB_LOG` enabled. | (a) dispatch target ≠ ENG-9001; (b) `grep -Fxq 'remove-label ENG-9001 pipeline:skip-until-human-acts'` returns 1 (no match). | unit | `AC-9 Bug B — stage+skip-until-human-acts (no state file) vacates and preserves label` (`bin/poll-slot-test.sh`) |
| **Bug B (code-changes)** uniformity guard. | AC-10 fixture: same as AC-9 with `pipeline:skip-until-code-changes`. | (a) dispatch target ≠ ENG-9002; (b) `grep -Fxq 'remove-label ENG-9002 pipeline:skip-until-code-changes'` returns 1 (no match). | unit | `AC-10 Bug B uniformity — stage+skip-until-code-changes (no state file) vacates and preserves label` (`bin/poll-slot-test.sh`) |
| **Existing — orphan state file (state file without label) cleanup** must still work. | Existing AC-1..AC-7 plus the §6 case-4 path: stage-labeled issue with state file but no skip label. Already covered by AC-1, AC-2, AC-4 path through `_poll_evaluate_skip` — the file-without-label branch at `bin/poll.sh:54-61` is exercised whenever a non-skip stage-labeled issue is classified. | State file at `$PROJECT_STATE_DIR/<issue>/issue-state.json` is `rm -f`'d; issue is included (returned 0). | unit | All of AC-1, AC-2, AC-4 (`bin/poll-slot-test.sh`) — coverage via the `_poll_evaluate_skip(no-skip,no-state)` short-circuit + the planted-state-file shape exercised at AC-6. |
| **Existing — `skip-until-code-changes` evidence-recompute auto-resume with state file** must still work. | AC-6 / AC-7 (existing). State file at `$PROJECT_STATE_DIR/ENG-7001/issue-state.json` with stale hash; evidence diff fires. | State file deleted; `pipeline:skip-until-code-changes` removed; if `pipeline:halted` present, halt cleared and `pipeline-decision: resume` posted; refreshed labels emitted. | unit | `AC-6 auto-resume clears skip+halt, posts resume marker, dispatches stage` (`bin/poll-slot-test.sh`) and `AC-7 auto-resume skips halt-clear when pipeline:halted absent` (`bin/poll-slot-test.sh`). Unchanged by this fix. |
| **Race — pipeline-side `classify-failure.sh` writes state file mid-tick after a human applied the label.** | Brainstorm §6 case 6. Cannot easily be fixture-driven (concurrency), but is bounded by the next-tick re-read of labels + state file. | Next tick: state file exists → `has_human_label=true` → existing skip-until-human branch at `bin/poll.sh:71-74` returns 1 (skip). | (no automated test — protected by AC-9 + the unchanged `bin/poll.sh:71-74` branch covered transitively by AC-7's full-`_poll_evaluate_skip` exercise.) | n/a — design-time argument. Implementation agent does not author a new test for this row. |
| **Adversarial — both skip labels present at once.** | §6 case 1. | First-detected skip label fires the skip branch; either label alone is sufficient. The fix's branch returns 1 on either label. The inbox filter drops on either match. | (covered transitively by AC-9 + AC-10 — both labels exercise the same branch.) | n/a — orthogonal to `_poll_evaluate_skip` since both flavors enter the same branch. |
| **`classify-failure.sh:100-108` pipeline-applied skip-label flow** unchanged. | Existing `bin/classify-failure-test.sh` cases — out of scope per Linear "OUT" §1. | All existing cases pass unchanged. | unit | `bin/classify-failure-test.sh` (full suite). Run as part of Task 4.1. |

## 9. Test Strategy

### 9.1 Unit (the only layer in this plan)

Three new cases (AC-8, AC-8b, AC-9, AC-10) appended to
`bin/poll-slot-test.sh`. The test file already follows the CLAUDE.md
"Tests" pattern: `PIPELINE_DRY_RUN=1`, `STUB_DIR`, post-source override of
`SCRIPT_DIR`/`HARNESS_STATE_DIR`/`PROJECT_STATE_DIR`/`CONFIG`, sentinel-
sourced `poll.sh`, fixture writers (`write_label_fixture`,
`write_inbox_fixture`), and `LINEAR_STUB_LOG` for write-side assertions.
New tests reuse all of this verbatim.

Coverage axes (each row in §8 maps to the cell): post-fix Pass 5 inbox
filter (AC-8/AC-8b), post-fix `_poll_evaluate_skip` orphan branch with no
Linear writes (AC-9/AC-10), and existing AC-1..AC-7 must continue to pass
(Task 4.1).

### 9.2 Integration / smoke

Not applicable. The fix is purely in `poll.sh`'s read-side decision logic;
there is no new external interaction. The existing `*-test.sh` suite plus
the no-op `dry-run.sh` smoke test (run on every tick already) covers
end-to-end propagation.

### 9.3 Adversarial

`bin/halt-sprawl-adversarial-test.sh`,
`bin/run-local-helpers-adversarial-test.sh`, and
`bin/verdict-adversarial-test.sh` already exercise concurrent and
malformed-input cases for adjacent code paths. These are run as part of
Task 4.1's full sweep; this plan does not add a new adversarial file
because the change surface (two non-overlapping in-function edits) does
not introduce a new adversarial axis. Per the Linear issue's "Scope
Boundaries — OUT", "Refactoring unrelated parts of poll.sh" is not
in scope.

### 9.4 What is intentionally NOT tested

- A `linear.sh remove-label` failing on the orphan-label branch — that
  branch is gone; the only `remove-label` calls touched are the two
  deleted ones.
- Auto-seeding a state file on human-applied label — explicitly rejected
  in the brainstorm (D-2 alt 2). Out of scope.
- Updating the `setup-labels.sh:37` description of
  `pipeline:skip-until-code-changes` — the brainstorm §7 "Open
  questions" defers this; the contract already reads "auto-resumes …
  OR when the label is removed", which covers the no-state-file case
  adequately.

---

## Acceptance gate

The fix is complete and ready to advance to `stage:implementing` when:

1. `bash bin/poll-slot-test.sh` exits 0 and reports `RESULTS: <≥10> passed,
   0 failed` with named cases AC-8, AC-8b, AC-9, AC-10 visibly passing.
2. The full sweep `for t in bin/*-test.sh; do bash "$t"; done` exits 0.
3. The defensive greps in Task 4.2 produce the expected output (two
   matches; two non-matches).
4. `git status -s` is clean and `git log` shows the ENG-24 commit chain
   on the feature branch.

The Linear issue's five Acceptance Criteria map onto this plan as:

| Linear AC | Plan section |
|---|---|
| AC-1 (inbox jq filter excludes both labels) | Task 2 |
| AC-2 (orphan branch returns 1, no `linear.sh remove-label`) | Task 1 |
| AC-3 (Todo + skip-until-human-acts → idle) | Task 3a (AC-8) |
| AC-4 (stage + skip-until-human-acts + no state file → vacate, label preserved) | Task 3b (AC-9) |
| AC-5 (legitimate orphan-state-file cleanup unchanged) | §8 row "Existing — orphan state file (state file without label) cleanup", verified by Task 4.1 running AC-1..AC-7 + AC-6's full `_poll_evaluate_skip` exercise. |

