---
linear: ENG-178
date: 2026-06-10
topic: Picker unified candidate pool — let predicate-ready higher-stage waits compete when held is full
---

# ENG-178 Picker Unified Candidate Pool — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the picker from starving an approved, higher-stage `wait_recallable` issue (e.g. a build awaiting merge) behind lower-stage held work when all K slots are held.

**Architecture:** In `bin/poll.sh::_picker_build_pool`, split the single `if (( held_count < max_concurrent ))` gate that currently wraps *both* `wait_recallable` and `inbox` assembly. `wait_recallable` candidates become **always assembled** (still filtered by `_picker_predicate_ready`), so the existing unified `sort_by([-stage_index, -priority_sort_rank, fifo_ts, identifier])` + top-K truncation in `main()` can promote a ready higher-stage wait over a lower-stage held. `inbox` assembly stays under the `held_count < max_concurrent` guard, re-documented as a *lossless cost optimization* (inbox `stage_index = -1` can never outrank K helds).

**Tech Stack:** Bash 3.2 orchestration scripts; `jq`; self-contained `bin/*-test.sh` tests (no runner); `PIPELINE_DRY_RUN=1` + stubbed `linear.sh`/`entry-conditions.sh`.

---

## File structure

- **Modify:** `bin/poll.sh` — `_picker_build_pool` (the gate split) + its header "Cap discipline" comment.
- **Modify:** `bin/poll-slot-test.sh` — add two regression cases; fix one stale comment (AC-5).
- **Modify:** `CLAUDE.md` — the "Failure-mode quick reference" row that wrongly implies ENG-91 fully resolved this.

## Test coverage mapping (spec AC → tests)

The spec lists four test intents. Two need **new** cases; two are already guarded by existing cases (DRY — no duplicate added):

| Spec AC | Covered by |
|---|---|
| 1. Held-full does not starve a higher-stage ready wait | **NEW** `AC-PICK-STARVE-1` (Task 1) |
| 2. Not-ready wait still excluded + logged | **NEW** `AC-PICK-STARVE-2` (Task 1) |
| 3. Common case unchanged (no ready waits) | Existing `AC-1` (2 planning helds dispatch one) + `AC-5` (idle `max-concurrent-reached` when held full, no waits/inbox) |
| 4. Inbox admitted only when `held_count < K` | Existing `AC-2` (inbox picked when helds vacate) + `AC-PICK-1` (wait outranks inbox); inbox gate is **unchanged** by this fix |

Why the new cases are needed: `AC-WAIT-2` already asserts a building-wait beats a qa-held, **but only with `held_count = 1`** (gate open). The bug manifests only at `held_count = K` (all slots held), which no existing case exercises.

> **Harness note:** `poll-slot-test.sh` invokes `main` with no `--max`, so `_max_decisions = 1` and `main` emits a **single decision object** (not an array). All assertions below target one dispatched `issue_id`.

---

### Task 1: Add the two failing regression tests

**Files:**
- Modify (Test): `bin/poll-slot-test.sh` — insert two cases immediately before the `# ─── Summary ───` block near EOF.

- [ ] **Step 1: Add the two test cases**

Insert the following block immediately **before** this existing anchor line near the end of `bin/poll-slot-test.sh`:

```bash
# ─── Summary ──────────────────────────────────────────────────────────
```

Block to insert:

```bash
# ─── AC-PICK-STARVE-1 (ENG-178): held-full does NOT starve a higher-stage
#     predicate-ready wait. Two helds fill both slots (held_count=2=cap);
#     a predicate-ready building wait must still win the single dispatch
#     (building idx=6 > planning idx=2), even though the helds are higher
#     PRIORITY (Urgent vs Normal) — stage dominates the sort key.
#     Pre-ENG-178 the held_count<max_concurrent gate excluded the wait from
#     the pool entirely, so a planning held was dispatched and the approved
#     build starved (the 2026-06-10 ENG-154/ENG-119 incident). AC-WAIT-2
#     only covers held_count=1 (gate open), so it never exercised this path.
reset_fixtures
export ENTRY_CONDITIONS_STUB_OUTPUT=proceed
write_label_fixture "stage:planning" \
  "ENG-STARVE-H1|In Progress|1|stage:planning" \
  "ENG-STARVE-H2|In Progress|1|stage:planning"
write_label_fixture "stage:building" "ENG-STARVE-W|In Progress|3|stage:building"
write_comments_fixture "ENG-STARVE-W" \
  '<!-- pipeline: transition from=implementing to=building -->|2026-06-10T06:30:00Z' \
  '<!-- pipeline: verdict result=wait reason=awaiting-approval -->|2026-06-10T06:39:00Z'
out="$(main 2>/dev/null || true)"
issue_id="$(jq -r '.issue_id // "null"' <<<"$out")"
reason="$(jq -r '.reason // ""' <<<"$out")"
if [[ "$issue_id" == "ENG-STARVE-W" && "$reason" == *"stage:building"* ]]; then
  pass_at "AC-PICK-STARVE-1 (ENG-178): held-full does not starve higher-stage ready wait"
else
  fail_at "AC-PICK-STARVE-1 (ENG-178): held-full wait starvation" \
    "got issue_id=$issue_id reason=$reason (want ENG-STARVE-W / *stage:building*) full=$out"
fi

# ─── AC-PICK-STARVE-2 (ENG-178): with the gate split, a held-full tick
#     still runs the wait predicate check and EXCLUDES a not-ready wait,
#     logging "skipped (predicate not ready)". A planning held is
#     dispatched instead. Confirms the predicate gate is preserved by the
#     fix AND that the log line — entirely absent pre-ENG-178 because the
#     gate skipped wait assembly when held was full — now fires.
#     NB: _picker_predicate_ready treats only `skip:*` (with colon) as
#     not-ready; a bare `skip` hits the fail-open catch-all.
reset_fixtures
export ENTRY_CONDITIONS_STUB_OUTPUT="skip:awaiting-approval"
write_label_fixture "stage:planning" \
  "ENG-STARVE2-H1|In Progress|1|stage:planning" \
  "ENG-STARVE2-H2|In Progress|1|stage:planning"
write_label_fixture "stage:building" "ENG-STARVE2-W|In Progress|3|stage:building"
write_comments_fixture "ENG-STARVE2-W" \
  '<!-- pipeline: transition from=implementing to=building -->|2026-06-10T06:30:00Z' \
  '<!-- pipeline: verdict result=wait reason=awaiting-approval -->|2026-06-10T06:39:00Z'
err="$STUB_DIR/starve2-stderr.log"
out="$(main 2>"$err" || true)"
issue_id="$(jq -r '.issue_id // "null"' <<<"$out")"
skipped_logged=0
grep -qE 'picker: wait_recallable ENG-STARVE2-W skipped \(predicate not ready\)' "$err" && skipped_logged=1
export ENTRY_CONDITIONS_STUB_OUTPUT=proceed   # restore default (defensive; no later case depends on it)
if [[ "$issue_id" == ENG-STARVE2-H* ]] && (( skipped_logged == 1 )); then
  pass_at "AC-PICK-STARVE-2 (ENG-178): not-ready wait excluded + logged; held dispatched"
else
  fail_at "AC-PICK-STARVE-2 (ENG-178): predicate-not-ready exclusion" \
    "got issue_id=$issue_id skipped_logged=$skipped_logged full=$out"
fi

```

- [ ] **Step 2: Run the suite and confirm the two new cases FAIL on current code**

Run: `bash bin/poll-slot-test.sh`
Expected: exit 1, with these two lines present:
```
  ❌ AC-PICK-STARVE-1 (ENG-178): held-full wait starvation
  ❌ AC-PICK-STARVE-2 (ENG-178): predicate-not-ready exclusion
```
Rationale: on current code `held_count = 2 = max_concurrent`, so the gate suppresses wait assembly. `AC-PICK-STARVE-1` dispatches `ENG-STARVE-H1` (a planning held) instead of the wait → fail. `AC-PICK-STARVE-2` never runs the predicate check, so the "skipped (predicate not ready)" line is absent → `skipped_logged=0` → fail. All other cases must still pass.

- [ ] **Step 3: Commit the failing tests**

```bash
git add bin/poll-slot-test.sh
git commit -m "test(ENG-178): regression for held-full wait starvation (failing)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Implement the gate split in `_picker_build_pool`

**Files:**
- Modify: `bin/poll.sh` — `_picker_build_pool` body (~L468-525).

- [ ] **Step 1: Replace the gated block**

Find this exact block in `bin/poll.sh::_picker_build_pool`:

```bash
  local wait_pool='[]' inbox_pool='[]'
  if (( held_count < max_concurrent )); then
    local wait_candidates wn wi=0
    wait_candidates="$(jq -c '
      [.[]
       | select(.slot == "vacate" and (.wait_recallable // false) == true)
      ]' <<<"$classified")"
    wn="$(jq 'length' <<<"$wait_candidates")"
    while (( wi < wn )); do
      local wc wid wstage_label wstage_arg
      wc="$(jq -c ".[$wi]" <<<"$wait_candidates")"
      wid="$(jq -r '.identifier'  <<<"$wc")"
      wstage_label="$(jq -r '.stage_label' <<<"$wc")"
      wstage_arg="$(stage_arg_for_label "$wstage_label")"
      if _picker_predicate_ready "$wid" "$wstage_arg"; then
        local wc_aug
        wc_aug="$(jq -c '. + {picker_source:"wait_recallable", fifo_ts:(.wait_progress_ts // "")}' <<<"$wc")"
        wait_pool="$(jq -nc --argjson p "$wait_pool" --argjson x "$wc_aug" '$p + [$x]')"
      else
        log "picker: wait_recallable $wid skipped (predicate not ready)"
      fi
      wi=$((wi+1))
    done

    local inbox_state
    inbox_state="$(config_get '.linear.native_states.inbox')"
```

Replace it with (the `if (( held_count < max_concurrent ))` now wraps **only** inbox; wait assembly is hoisted out):

```bash
  local wait_pool='[]' inbox_pool='[]'

  # ENG-178: wait_recallable candidates ALWAYS compete — they are NOT
  # gated on held_count<max_concurrent. A predicate-ready higher-stage
  # wait (e.g. an approved build awaiting merge) must be able to outrank a
  # lower-stage held; the prior gate excluded the whole wait class from
  # the pool whenever K issues were held, and the unified sort cannot
  # promote a candidate that was never assembled. The per-tick dispatch
  # cap is still enforced downstream by main()'s top-K (_max_decisions)
  # truncation, and the predicate filter below still drops not-ready waits.
  local wait_candidates wn wi=0
  wait_candidates="$(jq -c '
    [.[]
     | select(.slot == "vacate" and (.wait_recallable // false) == true)
    ]' <<<"$classified")"
  wn="$(jq 'length' <<<"$wait_candidates")"
  while (( wi < wn )); do
    local wc wid wstage_label wstage_arg
    wc="$(jq -c ".[$wi]" <<<"$wait_candidates")"
    wid="$(jq -r '.identifier'  <<<"$wc")"
    wstage_label="$(jq -r '.stage_label' <<<"$wc")"
    wstage_arg="$(stage_arg_for_label "$wstage_label")"
    if _picker_predicate_ready "$wid" "$wstage_arg"; then
      local wc_aug
      wc_aug="$(jq -c '. + {picker_source:"wait_recallable", fifo_ts:(.wait_progress_ts // "")}' <<<"$wc")"
      wait_pool="$(jq -nc --argjson p "$wait_pool" --argjson x "$wc_aug" '$p + [$x]')"
    else
      log "picker: wait_recallable $wid skipped (predicate not ready)"
    fi
    wi=$((wi+1))
  done

  # ENG-178: inbox assembly STAYS gated on held_count<max_concurrent, but
  # this is a lossless COST optimization, not a correctness gate. Inbox
  # candidates carry stage_index=-1, strictly below every stage, so they
  # can never outrank K held issues; skipping the list-issues-in-state
  # network call when held is full changes no dispatch outcome. The WIP
  # cap on inbox admission is still enforced by the unified sort + top-K
  # (inbox wins a slot only when fewer than K higher-stage workable
  # candidates exist).
  if (( held_count < max_concurrent )); then
    local inbox_state
    inbox_state="$(config_get '.linear.native_states.inbox')"
```

The remainder of the inbox assembly (the `inbox_pool="$(bash "$SCRIPT_DIR/linear.sh" list-issues-in-state ...`, the `[[ -z "$inbox_pool" ]] && inbox_pool='[]'`, and the closing `fi`) is unchanged and stays inside this `if`.

- [ ] **Step 2: Run the suite and confirm ALL cases pass**

Run: `bash bin/poll-slot-test.sh`
Expected: `RESULTS: N passed, 0 failed`, exit 0. The two `AC-PICK-STARVE-*` cases now pass; every pre-existing `AC-*` / `AC-WAIT-*` / `AC-PICK-*` case still passes (notably `AC-1`, `AC-5`, `AC-WAIT-2`, `AC-WAIT-3`).

- [ ] **Step 3: Commit the fix**

```bash
git add bin/poll.sh
git commit -m "fix(ENG-178): always let predicate-ready waits compete in picker

Hoist wait_recallable assembly out of the held_count<max_concurrent gate
in _picker_build_pool so a higher-stage approved wait can outrank a
lower-stage held when all K slots are held. Inbox stays gated as a
lossless cost optimization. Drives AC-PICK-STARVE-1/2.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Update stale comments

**Files:**
- Modify: `bin/poll.sh` — the "Cap discipline" header comment of `_picker_build_pool`.
- Modify: `bin/poll-slot-test.sh` — the `AC-5` explanatory comment.

- [ ] **Step 1: Update the "Cap discipline" comment in `bin/poll.sh`**

Find:

```bash
# Cap discipline:
#   - held items always included (they are already counted in
#     held_count; their fifo_ts is the gather projection's updatedAt).
#   - wait_recallable + inbox cap-guarded by held_count <
#     max_concurrent. Mirrors today's pre-ENG-91 Pass 5/6 cap guards.
```

Replace with:

```bash
# Cap discipline:
#   - held items always included (they are already counted in
#     held_count; their fifo_ts is the gather projection's updatedAt).
#   - wait_recallable always included (ENG-178) — gated only on
#     _picker_predicate_ready, NOT on held_count. A ready higher-stage
#     wait must be able to outrank a lower-stage held.
#   - inbox cap-guarded by held_count < max_concurrent — a LOSSLESS cost
#     optimization (inbox stage_index=-1 can never outrank K helds), not a
#     correctness gate. Per-tick dispatch is capped downstream by main()'s
#     top-K (_max_decisions) truncation.
```

- [ ] **Step 2: Update the `AC-5` comment in `bin/poll-slot-test.sh`**

Find:

```bash
# guard suppresses wait + inbox enrolment and the final idle path
# emits "max-concurrent-reached".
```

Replace with:

```bash
# guard suppresses inbox enrolment (post-ENG-178 wait enrolment is no
# longer gated, but this fixture has no wait candidates) and the final
# idle path emits "max-concurrent-reached".
```

- [ ] **Step 3: Run the suite to confirm comments did not break anything**

Run: `bash bin/poll-slot-test.sh`
Expected: `RESULTS: N passed, 0 failed`, exit 0.

- [ ] **Step 4: Commit the comment updates**

```bash
git add bin/poll.sh bin/poll-slot-test.sh
git commit -m "docs(ENG-178): correct cap-discipline + AC-5 comments for gate split

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Update the CLAUDE.md failure-mode row

**Files:**
- Modify: `CLAUDE.md` — the "Failure-mode quick reference" row (~L779).

- [ ] **Step 1: Replace the row**

Find this exact line:

```
| Approved/ready ticket at later stage sits idle while earlier-stage/inbox issue dispatches each tick | Pre-ENG-91 the picker walked Pass 4→5→6 sequentially and exited after first dispatch. ENG-91's unified Pass 4U picker (`bin/poll.sh::_picker_build_pool`) sorts by `[-stage_index, -priority_sort_rank, fifo_ts]` and gates wait_recallable inclusion on `should_dispatch == proceed`. Inspect logs for `picker: wait_recallable <ENG-N> skipped (predicate not ready)`. Recovery: add `pipeline:paused` to held issue, let next tick re-pick the wait, then remove. |
```

Replace with:

```
| Approved/ready ticket at later stage sits idle while earlier-stage/inbox issue dispatches each tick | ENG-91 unified the picker (`bin/poll.sh::_picker_build_pool`, sort `[-stage_index, -priority_sort_rank, fifo_ts]`) but still gated wait_recallable assembly on `held_count < max_concurrent`, so a ready higher-stage wait was excluded whenever K issues were held (the 2026-06-10 ENG-154/ENG-119 incident). ENG-178 hoists wait_recallable assembly out of that gate — waits always compete, gated only on `_picker_predicate_ready`; inbox stays gated as a lossless cost optimization. If a wait still idles, inspect logs for `picker: wait_recallable <ENG-N> skipped (predicate not ready)` (predicate genuinely not ready, e.g. PR not approved). Legacy manual recovery (rarely needed post-ENG-178): add `pipeline:paused` to a held issue, let the next tick re-pick the wait, then remove. |
```

- [ ] **Step 2: Commit the doc update**

```bash
git add CLAUDE.md
git commit -m "docs(ENG-178): update failure-mode row — ENG-91 starvation fixed

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Full suite + final verification

**Files:** none (verification only).

- [ ] **Step 1: Run the entire test sweep (the pre-commit gate)**

Run:
```bash
for t in bin/*-test.sh; do echo "== $t =="; bash "$t" || { echo "FAILED: $t"; break; }; done
```
Expected: every test file prints its `RESULTS: … 0 failed` (or equivalent) and exits 0; no `FAILED:` line. Pay special attention to `bin/poll-slot-test.sh` (new + existing cases) and any other test that sources `poll.sh` (`bin/halt-sprawl-test.sh`, `bin/halt-sprawl-adversarial-test.sh`, `bin/run-local-sweep-test.sh`).

- [ ] **Step 2: Syntax check**

Run: `bash -n bin/poll.sh && echo OK`
Expected: `OK`.

- [ ] **Step 3: Confirm clean tree**

Run: `git status --short`
Expected: empty (all changes committed across Tasks 1-4).

---

## Out of scope

- Anti-starvation / fairness guard (explicitly declined — stuck higher-stage tickets remove themselves from contention via `_picker_predicate_ready` / `vacate`).
- Broader `_picker_build_pool` / Pass 3 held-selection refactor.
- Any change to `_poll_classify_labels` slot contract or `_picker_predicate_ready` semantics.
- The structured `docs/plans/*.json` plan sidecar (consumed only by `render-prompt.sh` at implement/qa **dispatch**; this fix is implemented manually with the harness paused).

## Self-review notes

- **Spec coverage:** all 7 spec ACs map to a task (see table above; ACs 3 & 4 to existing tests, deliberately not duplicated).
- **No placeholders:** every code/edit step shows literal before/after text and exact run commands with expected output.
- **Type/name consistency:** test helper names (`reset_fixtures`, `write_label_fixture`, `write_comments_fixture`, `pass_at`, `fail_at`), env var `ENTRY_CONDITIONS_STUB_OUTPUT`, and the `skip:*` predicate contract match `bin/poll-slot-test.sh` and `bin/poll.sh::_picker_predicate_ready` exactly.
