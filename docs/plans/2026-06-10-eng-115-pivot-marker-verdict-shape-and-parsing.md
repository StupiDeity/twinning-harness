---
linear: ENG-115
date: 2026-06-10
topic: pivot marker — verdict shape and parsing (writer + reader, no orchestrator routing)
---

# ENG-115 — Pivot marker: verdict shape and parsing

## Anti-anchoring check

**Problem restatement.** Today an agent or operator that emits a
pivot marker via `bash bin/pipeline.sh event ENG-N verdict pivot
--target planning` produces a Linear comment the registry says is
valid (`pivot` is listed in `verdict_results` at
`bin/pipeline-events.json:8`), but `bin/verdict-handler.sh` routes
it to `_vh_protocol_violation "$issue" "unknown-marker"
"marker=unknown"` (`bin/verdict-handler.sh:589-591`). That message is
visibly wrong: the marker IS in the registry. ENG-115 makes the
writer/reader call chain match the registry's claim, without
adding routing — that's the next sub-ticket (ENG-NEXT).

**Solution proportionality.** Three small edits: extend
`cmd_event_verdict`'s `pivot)` arm to require `--target/--stage/
--reason`, add one new registry field (`pivot_reasons`), add one
new jq arm + one new `case` arm in `verdict-handler.sh`, regenerate
the vocabulary doc, extend three existing test files. ~100 lines
diff. No new files, no new abstractions, no new dependencies.

Both checks pass. Proceeding to plan.

## Branch-base freshness check

`git log --oneline HEAD..origin/main` is **non-empty** (~200 commits
ahead — many sibling tickets have landed since this branch's
brainstorm landed). Brainstorm §11.6 ("Re-dispatch delta") flags the
same situation and notes that none of those commits touch the
pivot writer/reader call chain. To stay safe, **Task 0 below
rebases onto origin/main** before any other implement-side work,
and every Edit boundary in this plan uses content-anchored keys
(quoted code fragments, named conditionals' `fi` markers,
distinctive section headers) so the steps survive the rebase even
if line numbers drift.

## 1. Goal

Pivot markers emitted via `bash bin/pipeline.sh event ENG-N verdict
pivot --target planning --stage <stage> --reason
plan-structural-defect` are validated at the writer against the
closed registry, parsed at the reader by `find_fresh_verdict`, and
routed to a dedicated `pipeline-pivot)` arm in `verdict_handler`'s
dispatch table that logs and returns rc=1 (halt-preserved). No
orchestrator routing.

## 2. Assumption Inventory

**branch-base freshness:** `HEAD..origin/main` non-empty at plan time;
`origin/main = 72453cb` (ENG-178 merge as the most recent commit).
The 32 verified path:line refs in the 2026-06-10 brainstorm §10.3
were verified against worktree HEAD `9d37a4f`. **Task 0 below
rebases onto origin/main; the implement agent MUST re-verify
every `path:line` below after the rebase.**

The references below correspond to the pre-rebase worktree HEAD
`9d37a4f`. They appear here for clarity; the implement agent
treats them as informational hints alongside the content anchors
(quoted code fragments and section markers) that are the actual
edit boundaries.

| # | Claim (pre-rebase HEAD `9d37a4f`) | path:line | Status |
|---|---|---|---|
| A1 | `"pivot"` listed in `verdict_results` | `bin/pipeline-events.json:8` | verified |
| A2 | `pivot_targets: ["planning"]` registry field exists | `bin/pipeline-events.json:32-34` | verified |
| A3 | `cmd_event_verdict` `pivot)` arm requires `--target` only | `bin/pipeline.sh:113-114` | verified — current arm is `pivot) [[ -n "$target" ]] || die "event verdict pivot: --target required"  _validate_registry pivot_targets "$target" ;;` |
| A4 | `_validate_registry` shape `"X not in <field>"` at the writer-chokepoint | `bin/pipeline.sh:80-84` | verified |
| A5 | Marker body composition appends `stage=`/`target=`/`reason=` conditionally | `bin/pipeline.sh:117-122` | verified — current body builder is `local body="<!-- pipeline: verdict result=$result"` then three `[[ -n "$X" ]] && body="$body X=$X"` lines |
| A6 | Lane-fence warning shape | `bin/pipeline.sh:129-131` | verified |
| A7 | `find_fresh_verdict` jq projection (pass/fail/halt + `else marker:"unknown"`) | `bin/verdict-handler.sh:236-248` | verified — the jq `if/elif/elif/else` chain ends with `else {marker:"unknown",...}` |
| A8 | `verdict_handler` dispatch table at `case "$mtype" in pipeline-stage-summary)…pipeline-rejection)…pipeline-halt)…*) _vh_protocol_violation` | `bin/verdict-handler.sh:545-593` | verified |
| A9 | `_VH_LOOPBACK_TRANSITIONS` table | `bin/verdict-handler.sh:32-38` | verified |
| A10 | `apply_transition` accepts `(issue, from, to, side_labels_csv)` | `bin/verdict-handler.sh:309-311` | verified |
| A11 | `parse_pipeline_marker` generic k=v parser; family precedence pipeline > meta | `bin/common.sh:338-400` | verified |
| A12 | Generator's for-loop field list (no `pivot_reasons` yet) | `bin/generate-vocabulary-doc.sh:14` | verified — current line is `for field in verdict_results halt_reasons wait_reasons fail_targets pivot_targets decision_actions decision_gates meta_kinds stages; do` |
| A13 | Template `pivot_targets` paragraph | `docs/pipeline-vocabulary.template.md:74-75` | verified |
| A14 | `vocabulary-cleanliness-test::case-2` `required_keys` array | `bin/vocabulary-cleanliness-test.sh:102-103` | verified |
| A15 | `vocabulary-cleanliness-test::case-4` (plan-contract-invalid pattern to mirror) | `bin/vocabulary-cleanliness-test.sh:146-155` | verified |
| A16 | `pipeline-test.sh` PE7 current shape | `bin/pipeline-test.sh:82-83` | verified — current PE7 asserts only `result=pivot target=planning` |
| A17 | `pipeline-test.sh` PE3 (bogus reason rejection pattern) | `bin/pipeline-test.sh:67-69` | verified |
| A18 | `verdict-handler-test.sh` case-1 shape (mk_fixture + assert_marker_event + calls_contains) | `bin/verdict-handler-test.sh:139-156` | verified |
| A19 | `assert_marker_event` helper | `bin/verdict-handler-test.sh:110-124` | verified |
| A20 | `run-stage-test.sh::WS8` fixture uses pivot without target/reason | `bin/run-stage-test.sh:2487-2503` | verified — WS8 is a hand-crafted Linear JSON shape that tests `_fresh_wait_reason`'s wait-shadow predicate, NOT a `pipeline.sh`-emitted body. D-3's writer-tightening does not invalidate this fixture |
| A21 | `pipeline:supersede` exists as a label (post-routing side-label, not ENG-115's concern) | `bin/verdict-handler.sh:34` | verified |
| A22 | No new test files needed — all three test surfaces have existing files | (extrapolation: brainstorm §D-6; no add-side test-gate closure work) | assumed |
| A23 | Test-gate closure sweep removed-token check: ENG-115 removes ZERO tokens from production code; no sibling test needs an inverted assertion | (extrapolation: D-3 narrows the writer, D-4/D-5 add new arms — no removals) | assumed — will validate at implement time by full test suite pass |
| A24 | Implementing the new `find_fresh_verdict` arm does not break existing cases 1-NN | (extrapolation: new `elif $r == "pivot"` adds a branch but does not modify existing branches) | assumed — will validate at implement time |
| A25 | Verdict_handler rc=1 (halt-preserved) integrates with `_post_dispatch_apply_halt` (non-wait verdicts already get `pipeline:halted`) | (extrapolation: brainstorm D-5 §) | assumed — will validate at implement time |

## 3. File Structure

| File | Change |
|---|---|
| `bin/pipeline-events.json` | **modified** — add new top-level field `"pivot_reasons": ["plan-structural-defect"]` between `pivot_targets` and `decision_actions`. |
| `bin/pipeline.sh` | **modified** — tighten `cmd_event_verdict`'s `pivot)` arm to require + registry-validate `--target`, `--stage`, `--reason`. |
| `bin/verdict-handler.sh` | **modified** — (a) add `elif $r == "pivot"` arm to `find_fresh_verdict`'s jq projection; (b) add `pipeline-pivot)` case to `verdict_handler`'s dispatch table. |
| `bin/generate-vocabulary-doc.sh` | **modified** — extend the for-loop field list to include `pivot_reasons`. |
| `docs/pipeline-vocabulary.template.md` | **modified** — add a `pivot_reasons` paragraph after the existing `pivot_targets` paragraph. |
| `docs/pipeline-vocabulary.md` | **modified** — regenerated via `bash bin/generate-vocabulary-doc.sh`. |
| `bin/pipeline-test.sh` | **modified** — rewrite PE7 (full three-field assert); add PE7a/PE7b/PE7c/PE7d (missing/bogus reason and stage). |
| `bin/verdict-handler-test.sh` | **modified** — add case-NN-pivot-detected (dispatch-table arm, rc=1) and case-NN-pivot-find-fresh-projection (jq projection shape). |
| `bin/vocabulary-cleanliness-test.sh` | **modified** — add `pivot_reasons` to `required_keys` array; add `case-ENG-115` block asserting `plan-structural-defect` is in `pivot_reasons`. |

**Test-gate closure note (add-side).** No new test files are created;
existing files are extended. The harness's `learned-rules/harness/
project-profile.md` `## Build & test gates` line already lists every
file modified above (`pipeline-test.sh`, `verdict-handler-test.sh`,
`vocabulary-cleanliness-test.sh` — though the in-tree
profile-file line is currently shorter than the addendum's; the
pre-commit hook runs every `bin/*-test.sh` regardless). **No
profile-file edit required.** This is verified by §2 codebase-fact
A22 + the test-gate closure sweep.

**Test-gate closure note (remove-side).** ENG-115 REMOVES zero
tokens from production code. The closest call is the existing
`marker:"unknown"` `else` branch in `find_fresh_verdict`'s jq —
which is preserved (pivot is added as a new `elif` *before* the
fallback). No sibling test references the `unknown-marker`
fallback in a way that ENG-115's elif insertion would break (case
1-7 in `verdict-handler-test.sh` exercise stage-summary, rejection,
halt, no-marker, stage-mismatch, unknown-loopback — none assert
the `*)` arm fires for a pivot body).

## 4. API Contract

No new API surface. The harness has no FE↔BE API; all changes are
internal to bash scripts and the JSON registry. The marker shape
itself is documented in §5 below as part of D-1.

## 5. Backend Tasks

### Task 0: Rebase onto origin/main

- `depends_on: []`
- `touches: (working-tree only — no source edits)`
- [ ] Run `git fetch origin main && git rebase origin/main` in
  the worktree. Resolve any conflicts mechanically (no semantic
  changes); if any conflict touches a file in §3 File Structure,
  STOP and halt with `agent-blocked` for human review (the
  brainstorm's stale-context risk has materialised).
- [ ] After the rebase, re-verify the §2 Assumption Inventory by
  spot-checking three claims with `grep`:
  - A3: `grep -n 'pivot)' bin/pipeline.sh` — expect to see the
    `[[ -n "$target" ]] || die "event verdict pivot: --target
    required"` line.
  - A7: `grep -n 'marker:"unknown"' bin/verdict-handler.sh` — expect
    exactly one match inside `find_fresh_verdict`.
  - A12: `grep -n 'for field in' bin/generate-vocabulary-doc.sh` —
    expect the field list NOT to contain `pivot_reasons` yet.
  Any mismatch means a sibling commit refactored the surface
  during ENG-115's brainstorm; halt with `agent-blocked`.

### Task 1: Add `pivot_reasons` registry field

- `depends_on: [0]`
- `touches: bin/pipeline-events.json`
- [ ] In `bin/pipeline-events.json`, AFTER the closing `]` of
  the `"pivot_targets"` array (content anchor: the line containing
  `"pivot_targets": [` opens this object; the closing line
  contains only `]` with a trailing comma) AND BEFORE the line
  containing `"decision_actions"`, insert:
  ```json
  "pivot_reasons": [
    "plan-structural-defect"
  ],
  ```
- [ ] Verify JSON validity: `jq . bin/pipeline-events.json` returns
  zero exit code.
- [ ] Verify the new field appears: `jq -e '.pivot_reasons |
  index("plan-structural-defect") != null'
  bin/pipeline-events.json` exits 0.

### Task 2: Tighten `cmd_event_verdict pivot` arm in `bin/pipeline.sh`

- `depends_on: [1]`
- `touches: bin/pipeline.sh::cmd_event_verdict`
- [ ] In `bin/pipeline.sh`, locate the `pivot)` arm inside the
  `case "$result" in` block. Content anchor: the line
  `pivot) [[ -n "$target" ]] || die "event verdict pivot:
  --target required"` immediately followed by
  `_validate_registry pivot_targets "$target" ;;`.
- [ ] Replace that two-line arm with:
  ```bash
      pivot) [[ -n "$target" ]] || die "event verdict pivot: --target required"
             [[ -n "$stage" ]]  || die "event verdict pivot: --stage required"
             [[ -n "$reason" ]] || die "event verdict pivot: --reason required"
             _validate_registry pivot_targets "$target"
             _validate_registry stages "$stage"
             _validate_registry pivot_reasons "$reason" ;;
  ```
- [ ] **DO NOT** modify the body builder block (the `local body="<!--
  pipeline: verdict result=$result"` line plus the three conditional
  `body="$body X=$X"` lines). The existing logic already appends
  `stage=`, `target=`, `reason=` when set, which now becomes the
  three-field canonical pivot body.

### Task 3: Add pivot arm to `find_fresh_verdict`'s jq projection

- `depends_on: [2]`
- `touches: bin/verdict-handler.sh::find_fresh_verdict`
- [ ] In `bin/verdict-handler.sh`, locate the jq projection inside
  `find_fresh_verdict`. Content anchor: the jq expression
  beginning `($e.result) as $r |` and ending with the closing
  `end')"`.
- [ ] Insert a new `elif` arm BEFORE the `else` branch (content
  anchor: the line `else` immediately above
  `{marker:"unknown", source_stage:"", target_stage:"",
  reason:"", comment_id:$id, event:$e}`). The new arm:
  ```jq
        elif $r == "pivot" then
          {marker:"pipeline-pivot", source_stage:$e.stage, target_stage:$e.target, reason:$e.reason, comment_id:$id, event:$e}
  ```
- [ ] Preserve the existing `else marker:"unknown"` branch — it is
  the protocol-violation fallback for genuinely unknown markers.

### Task 4: Add `pipeline-pivot)` case to `verdict_handler` dispatch table

- `depends_on: [3]`
- `touches: bin/verdict-handler.sh::verdict_handler`
- [ ] In `bin/verdict-handler.sh`, locate the `case "$mtype" in`
  block inside `verdict_handler`. Content anchor: the line
  `pipeline-halt)` immediately followed by
  `log "verdict-handler: halt marker on $issue (reason=$(jq -r
  '.reason' <<<"$fresh")) — leaving halt intact"` then `return 1`
  then `;;`.
- [ ] Immediately AFTER the `;;` that closes the `pipeline-halt)`
  arm AND BEFORE the `*)` fallback arm, insert:
  ```bash
      pipeline-pivot)
        # ENG-115: parsing-only stub. The next sub-ticket (ENG-NEXT) replaces
        # this log+return body with `apply_transition "$issue" "$src" "$tgt"
        # "pipeline:supersede"` mirroring the reviewing → brainstorming
        # loopback row at _VH_LOOPBACK_TRANSITIONS line 34.
        local pivot_reason
        pivot_reason="$(jq -r '.reason' <<<"$fresh")"
        log "verdict-handler: pivot-detected on $issue (source=$src → target=$tgt, reason=$pivot_reason) — routing deferred to ENG-NEXT"
        return 1
        ;;
  ```
- [ ] Do NOT add a `pivot` row to `_VH_LOOPBACK_TRANSITIONS` (that's
  the routing sub-ticket's job).

### Task 5: Extend the vocabulary-doc generator

- `depends_on: [1]`
- `touches: bin/generate-vocabulary-doc.sh`
- [ ] In `bin/generate-vocabulary-doc.sh`, locate the for-loop.
  Content anchor: the line `for field in verdict_results
  halt_reasons wait_reasons fail_targets pivot_targets
  decision_actions decision_gates meta_kinds stages; do`.
- [ ] Replace the for-loop's field list to insert `pivot_reasons`
  immediately AFTER `pivot_targets`:
  ```bash
    for field in verdict_results halt_reasons wait_reasons fail_targets pivot_targets pivot_reasons decision_actions decision_gates meta_kinds stages; do
  ```

### Task 6: Add `pivot_reasons` paragraph to the vocabulary template

- `depends_on: [1]`
- `touches: docs/pipeline-vocabulary.template.md`
- [ ] In `docs/pipeline-vocabulary.template.md`, locate the
  `pivot_targets` paragraph. Content anchor: the line beginning
  `- **\`pivot_targets\`** — currently only \`planning\`. Used
  when an agent decides the plan itself was wrong; rare.`
- [ ] Insert a new bullet IMMEDIATELY AFTER the closing of that
  `pivot_targets` bullet and BEFORE the `- **\`decision_actions\`**`
  bullet:
  ```markdown
  - **`pivot_reasons`** — why an agent declared the plan is
    structurally wrong. Currently only `plan-structural-defect`.
    Mirrors the `halt_reasons` shape; the rare-and-bucketed
    discipline applies (the retrospective surfaces pivot rates so
    we can size when to grow the vocabulary). *Routing of pivot
    markers (loopback to `stage:planning` with
    `pipeline:supersede`) is not yet wired in ENG-115; the
    verdict_handler logs the detection and halts the issue
    pending the routing sub-ticket. Operator recovery is
    `bash bin/pipeline.sh decide --action continue`, same as any
    other halt.*
  ```

### Task 7: Regenerate `docs/pipeline-vocabulary.md`

- `depends_on: [5, 6]`
- `touches: docs/pipeline-vocabulary.md`
- [ ] Run `bash bin/generate-vocabulary-doc.sh` from the worktree
  root. This overwrites `docs/pipeline-vocabulary.md` from the
  template + registry.
- [ ] Verify the regenerated doc contains BOTH the new prose
  paragraph (from Task 6) AND the new generated registry block
  for `pivot_reasons`:
  - `grep -q '### .pivot_reasons.' docs/pipeline-vocabulary.md`
  - `grep -q 'plan-structural-defect' docs/pipeline-vocabulary.md`
  - both must exit 0.

### Task 8: Extend `bin/pipeline-test.sh` PE7 + add PE7a-PE7d

- `depends_on: [2]`
- `touches: bin/pipeline-test.sh`
- [ ] In `bin/pipeline-test.sh`, locate PE7. Content anchor: the
  comment `# PE5–PE7: fail/wait/pivot variants — required field
  validation` plus the line `out="$(run_pipe event ENG-PE7 verdict
  pivot --target planning)"`.
- [ ] Replace the existing PE7 two-line stanza with the full
  three-field form AND four new rejection-shape cases (PE7a/PE7b/
  PE7c/PE7d), preserving the surrounding PE5/PE6 stanzas
  unchanged:
  ```bash
  # PE7: verdict pivot — full three-field body (target + stage + reason)
  out="$(run_pipe event ENG-PE7 verdict pivot --target planning --stage implementing --reason plan-structural-defect)"
  expect='<!-- pipeline: verdict result=pivot stage=implementing target=planning reason=plan-structural-defect -->'
  [[ "$out" == *"$expect"* ]] && pass_at "PE7: verdict pivot full body" || fail_at "PE7: verdict pivot full body" "got: $out"

  # PE7a: pivot missing --reason
  out="$(run_pipe event ENG-PE7a verdict pivot --target planning --stage implementing 2>&1 || true)"
  [[ "$out" == *"--reason required"* ]] && pass_at "PE7a: pivot requires --reason" || fail_at "PE7a: pivot requires --reason" "got: $out"

  # PE7b: pivot bogus reason
  out="$(run_pipe event ENG-PE7b verdict pivot --target planning --stage implementing --reason bogus-reason 2>&1 || true)"
  [[ "$out" == *"not in pivot_reasons"* ]] && pass_at "PE7b: bogus pivot reason rejected" || fail_at "PE7b: bogus pivot reason rejected" "got: $out"

  # PE7c: pivot missing --stage
  out="$(run_pipe event ENG-PE7c verdict pivot --target planning --reason plan-structural-defect 2>&1 || true)"
  [[ "$out" == *"--stage required"* ]] && pass_at "PE7c: pivot requires --stage" || fail_at "PE7c: pivot requires --stage" "got: $out"

  # PE7d: pivot bogus stage
  out="$(run_pipe event ENG-PE7d verdict pivot --target planning --stage bogus-stage --reason plan-structural-defect 2>&1 || true)"
  [[ "$out" == *"not in stages"* ]] && pass_at "PE7d: bogus pivot stage rejected" || fail_at "PE7d: bogus pivot stage rejected" "got: $out"
  ```
  Note: the order of k=v pairs in PE7's `$expect` matches the body
  builder's append order — `stage=` then `target=` then `reason=`
  (per the `pipeline.sh:117-122` three-conditional sequence; see
  brainstorm A5).

### Task 9: Add pivot cases to `bin/verdict-handler-test.sh`

- `depends_on: [3, 4]`
- `touches: bin/verdict-handler-test.sh`
- [ ] In `bin/verdict-handler-test.sh`, locate the end-of-test
  section. Content anchor: the final `pass_at` / `fail_at` call
  before the file's trailing `printf '\nverdict-handler-test:
  passed=%s failed=%s\n' ...` summary line (the trailing summary
  is the unambiguous tail of the file).
- [ ] BEFORE the trailing summary `printf`, append two new test
  cases following the established `mk_fixture` + `reset_calls` +
  `verdict_handler` + assertion pattern from case-1 (see §2 A18):
  ```bash
  # ─── case-ENG-115-pivot-detected ─────────────────────────────────────
  # Fresh pivot verdict (full three-field body) after a transition.
  # verdict_handler dispatches the pipeline-pivot arm: logs and rc=1,
  # NO transition applied, NO protocol-violation comment posted.
  reset_calls
  VH_FIXTURE_COMMENTS="$(mk_fixture \
    "<!-- pipeline: transition from=planning to=implementing -->|2026-06-10T10:00:00.000Z" \
    "<!-- pipeline: verdict result=pivot stage=implementing target=planning reason=plan-structural-defect -->|2026-06-10T11:00:00.000Z")"
  VH_CURRENT_STAGE_LABEL="stage:implementing"
  VH_CURRENT_LABELS="stage:implementing pipeline:halted"
  rc=0; log_output="$(verdict_handler "ENG-911" "implementing" 2>&1)" || rc=$?
  if [[ "$rc" == "1" ]] \
     && [[ "$log_output" == *"pivot-detected"* ]] \
     && [[ "$log_output" == *"source=implementing"* ]] \
     && [[ "$log_output" == *"target=planning"* ]] \
     && [[ "$log_output" == *"reason=plan-structural-defect"* ]] \
     && ! calls_contains "add-or-update-comment protocol-violation/" \
     && ! calls_contains "add-label ENG-911 stage:planning"; then
    pass_at "case-ENG-115-pivot-detected"
  else
    fail_at "case-ENG-115-pivot-detected" "rc=$rc log=$log_output calls=$(cat "$STUB_LOG")"
  fi

  # ─── case-ENG-115-pivot-find-fresh-projection ────────────────────────
  # Same fixture, direct find_fresh_verdict — assert the projected JSON
  # shape: marker=pipeline-pivot, source_stage/target_stage/reason all set
  # from the registry-validated fields.
  reset_calls
  VH_FIXTURE_COMMENTS="$(mk_fixture \
    "<!-- pipeline: transition from=planning to=implementing -->|2026-06-10T10:00:00.000Z" \
    "<!-- pipeline: verdict result=pivot stage=implementing target=planning reason=plan-structural-defect -->|2026-06-10T11:00:00.000Z")"
  VH_CURRENT_STAGE_LABEL="stage:implementing"
  proj="$(find_fresh_verdict "ENG-912")"
  if [[ "$(jq -r '.marker' <<<"$proj")" == "pipeline-pivot" ]] \
     && [[ "$(jq -r '.source_stage' <<<"$proj")" == "implementing" ]] \
     && [[ "$(jq -r '.target_stage' <<<"$proj")" == "planning" ]] \
     && [[ "$(jq -r '.reason' <<<"$proj")" == "plan-structural-defect" ]]; then
    pass_at "case-ENG-115-pivot-find-fresh-projection"
  else
    fail_at "case-ENG-115-pivot-find-fresh-projection" "proj=$proj"
  fi
  ```

### Task 10: Extend `bin/vocabulary-cleanliness-test.sh`

- `depends_on: [1]`
- `touches: bin/vocabulary-cleanliness-test.sh`
- [ ] In `bin/vocabulary-cleanliness-test.sh`, locate the
  `required_keys` array. Content anchor: the two lines
  ```bash
    required_keys=(verdict_results halt_reasons wait_reasons fail_targets
                   pivot_targets decision_actions decision_gates meta_kinds stages)
  ```
- [ ] Insert `pivot_reasons` between `pivot_targets` and
  `decision_actions`:
  ```bash
    required_keys=(verdict_results halt_reasons wait_reasons fail_targets
                   pivot_targets pivot_reasons decision_actions decision_gates meta_kinds stages)
  ```
- [ ] Locate the `case-4` block. Content anchor: the lines
  beginning `# ─── ENG-122: plan-contract-invalid in halt_reasons
  registry ──────────`.
- [ ] AFTER the closing `fi` of the `case-4` block and BEFORE the
  `# ─── Summary ───` header, append:
  ```bash
  # ─── ENG-115: plan-structural-defect in pivot_reasons registry ──────
  # Verifies that the new pivot reason token added by ENG-115 is present
  # in the closed vocabulary so that `bash bin/pipeline.sh event ... verdict
  # pivot --reason plan-structural-defect` passes registry validation.
  if jq -e '.pivot_reasons | index("plan-structural-defect") != null' "$REG" >/dev/null 2>&1; then
    pass_at "ENG-115 case-5: plan-structural-defect in pivot_reasons registry"
  else
    fail_at "ENG-115 case-5: plan-structural-defect in pivot_reasons registry" \
      "expected \"plan-structural-defect\" in .pivot_reasons array of $REG"
  fi
  ```

### Task 11: Run the full pre-commit gate

- `depends_on: [7, 8, 9, 10]`
- `touches: (no source edits — verification only)`
- [ ] Run `bash .githooks/pre-commit` (the same surface the
  install-git-hooks pre-commit hook runs). All `bin/*-test.sh`
  must pass. The new cases in Tasks 8/9/10 must show as PASS.
- [ ] If any test fails, the implement agent fixes the underlying
  cause (NOT the test) and re-runs. The
  `KNOWN_BROKEN` allowlist in the pre-commit hook must not be
  edited as part of ENG-115.

## 6. Frontend Tasks

No frontend tasks. The harness has no UI surface — the changes are
entirely in bash scripts, JSON registry, and operator-facing
markdown docs. This plan deliberately produces zero work for the
UI stage.

## 7. Failure Mode → Test Map

The brainstorm's §7 Error Handling + §8 Edge Cases bind to
concrete tests as follows. QA will generate / verify tests
against this mapping.

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
|---|---|---|---|---|
| `event verdict pivot` missing `--reason` | `bash bin/pipeline.sh event ENG-X verdict pivot --target planning --stage implementing` | dies with `event verdict pivot: --reason required` | unit | `bin/pipeline-test.sh::PE7a` |
| `event verdict pivot` bogus `--reason` | `--reason bogus-reason` | dies with `'bogus-reason' not in pivot_reasons — allowed: ...` | unit | `bin/pipeline-test.sh::PE7b` |
| `event verdict pivot` missing `--stage` | `--target planning --reason plan-structural-defect` (no `--stage`) | dies with `event verdict pivot: --stage required` | unit | `bin/pipeline-test.sh::PE7c` |
| `event verdict pivot` bogus `--stage` | `--stage bogus-stage` | dies with `'bogus-stage' not in stages — allowed: ...` | unit | `bin/pipeline-test.sh::PE7d` |
| `event verdict pivot` happy path | full three-field args | emits `<!-- pipeline: verdict result=pivot stage=... target=... reason=... -->` | unit | `bin/pipeline-test.sh::PE7` |
| Fresh pivot verdict at reader (full body) | linear stream contains a transition then a pivot marker | `find_fresh_verdict` returns `{marker:"pipeline-pivot", source_stage:..., target_stage:..., reason:..., ...}` | integration | `bin/verdict-handler-test.sh::case-ENG-115-pivot-find-fresh-projection` |
| Fresh pivot verdict at dispatch table | verdict_handler called with fresh pivot | logs `pivot-detected on $issue (source=... → target=..., reason=...) — routing deferred to ENG-NEXT`, returns 1, NO `apply_transition`, NO protocol-violation comment | integration | `bin/verdict-handler-test.sh::case-ENG-115-pivot-detected` |
| Registry missing `pivot_reasons` key | hand-edit `bin/pipeline-events.json` to remove the key | `case-2 (required_keys)` fails with explicit name; writer rejects every pivot attempt with `'X' not in pivot_reasons — allowed: ` (empty) | unit | `bin/vocabulary-cleanliness-test.sh::case-2` (existing) + `case-ENG-115` (new) |
| Vocabulary doc out-of-sync (template lacks `pivot_reasons` after generator change) | run `bash bin/generate-vocabulary-doc.sh` after Task 5 but skip Task 6 | regenerated doc has generated registry block for `pivot_reasons` but no prose paragraph; cleanliness test still passes (no doc-content assertion) — Task 7 verification commands catch this with `grep -q '### .pivot_reasons.'` | smoke | Task 7 verification step |
| WS8 fixture (pivot without target/reason) | existing WS8 test calls `_fresh_wait_reason` with hand-crafted JSON | unchanged behaviour — D-3's writer-tightening does not affect a hand-crafted JSON fixture; the wait-shadow predicate (`!= "wait"`) still trips on `result=pivot` regardless of field count | smoke | `bin/run-stage-test.sh::WS8` (existing — preserved as a regression pin) |
| Hand-crafted malformed pivot reaches Linear (bypass `pipeline.sh`) | operator hand-writes a `<!-- pipeline: verdict result=pivot -->` comment with no target/stage/reason | `find_fresh_verdict`'s jq projection emits `{marker:"pipeline-pivot", source_stage:null, target_stage:null, reason:null, ...}`; `verdict_handler` logs `reason=null` and returns rc=1; orchestrator's `_post_dispatch_apply_halt` applies `pipeline:halted`. Same recovery as any other halt. | (documented — not test-pinned; brainstorm §7 row 3) | (no test — bypass path is operator-initiated and the recovery is the standard halt flow) |

## 8. Test Strategy

**Unit coverage.** The writer-side tightening (`bin/pipeline.sh`)
gets five unit tests: PE7 (full happy path) plus PE7a-PE7d (each
of the two new required fields × each of {missing, bogus}). The
registry sanity gets one cleanliness test
(`vocabulary-cleanliness-test.sh::case-ENG-115`).

**Integration coverage.** The reader-side dispatch
(`bin/verdict-handler.sh`) gets two integration cases in
`verdict-handler-test.sh`: one exercising the full
`verdict_handler` from a fixture comment stream through to the
log line and rc, the other isolating `find_fresh_verdict`'s jq
projection to assert the shape of the projected JSON.

**Smoke coverage.** Task 7 runs `bash bin/generate-vocabulary-doc.sh`
and grep-verifies the regenerated doc carries both the generated
registry block and the new template paragraph for `pivot_reasons`.

**Adversarial / cold-pass coverage.**
- WS8 (`run-stage-test.sh:2487-2503`, existing) acts as a
  regression pin against accidentally including `pivot` in the
  wait-shadow predicate's exclusion list. This plan does NOT touch
  WS8; the fixture's hand-crafted body (no target/reason) remains
  valid input for `_fresh_wait_reason`, which uses only the
  `result` field. The brainstorm §D-6 explicitly calls this out so
  a future reader does not "fix" a working test.
- The unknown-marker `*)` arm in `verdict_handler`'s dispatch
  table remains the catch-all for genuinely unknown markers. Case
  5 (`verdict-handler-test.sh::case-5 no-marker-protocol-violation`)
  exercises the no-marker path, not the unknown-marker-arm path —
  but the existing fixture surface (case-1 through case-NN) does
  not assert the `*)` arm fires for a pivot body, so ENG-115's
  insertion of `pipeline-pivot)` before `*)` does not break any
  existing assertion. The new case-ENG-115-pivot-detected pins
  this routing change explicitly.

**Pre-commit gate.** `.githooks/pre-commit` runs every
`bin/*-test.sh` (Task 11). All new cases land in the gate
automatically because every modified test file is already in the
gate's globpath.

**What's deliberately uncovered.** No new test covers the
operator-initiated hand-crafted malformed pivot scenario (last row
of §7). The brainstorm §7 row 3 documents that the recovery shape
is identical to any other halt (`decide --action continue`); a
test would add nothing the existing halt-handling tests do not
already cover.
