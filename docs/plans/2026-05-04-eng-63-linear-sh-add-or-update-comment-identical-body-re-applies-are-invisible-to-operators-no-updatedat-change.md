---
linear: ENG-63
date: 2026-05-04
topic: linear.sh add-or-update-comment — make identical-body re-applies operator-visible via a `<!-- meta: reapplied at=… -->` footer
---

# Plan — ENG-63 linear.sh `add-or-update-comment` identical-body visibility

Implementation plan for the design in
`docs/brainstorms/2026-05-04-eng-63-linear-sh-add-or-update-comment-identical-body-re-applies-are-invisible-to-operators-no-updatedat-change-design.md`.

## Anti-anchoring check

- **Problem (operator's words).** When a halt re-fires against the same
  Linear issue, the comment thread surfaces only the FIRST occurrence's
  timestamp; subsequent identical-body re-applies update the comment
  in-place but Linear short-circuits the `updatedAt` move. Operators
  reasonably read the stale timestamp as "this was cleared already" and
  stop investigating, while `pipeline:halted` is being re-asserted within
  seconds of each `--action continue`. Cost \~30 minutes of confusion on
  the [ENG-58](https://linear.app/twinning/issue/ENG-58) incident.
- **Does the brainstorm address it?** Yes. D-001 detects byte-identical
  re-applies inside `add_or_update_comment` and rewrites the body to
  carry a `<!-- meta: reapplied at=<iso8601-utc> -->` footer; the body
  byte-changes, Linear's `updatedAt` advances, the footer line itself
  encodes the latest re-apply moment for operators inspecting the body.
  D-002 anchors the strip-and-compare regex to line boundaries.
  D-003 keeps a single rotating footer (not a stack). D-004 keeps the
  footer off the `commentCreate` path. D-005 closes the new marker into
  the `meta_kinds` registry. D-006 lists four test cases. D-007 updates
  `docs/runbooks/recovery.md` with a decision tree. D-009 emits a
  `comment-reapplied` metric so the retrospective can flag halt-loop
  patterns.
- **Proportional?** Yes. \~14 lines inside `add_or_update_comment`, one
  one-line append to `bin/pipeline-events.json::meta_kinds`, four new
  test cases in the existing `bin/linear-test.sh` add\_or\_update\_comment
  block (no new test file), one new §4 in the existing
  `docs/runbooks/recovery.md`, a parenthetical added to one row of
  `CLAUDE.md`'s Failure-mode quick reference, and a regenerated
  `docs/pipeline-vocabulary.md`. The brainstorm explicitly rejected
  Approach B (split-by-stage sig), free-form non-registered marker
  shapes, extracting a `_strip_reapplied_footer` helper, and emitting
  the metric from each caller. No new helper functions, no new lane
  fences, no new state files, no `dispatch.sh::allowed_tools_for` cases
  added.
- **No escalation needed.** PROCEED.

## Goal

Land a single PR off `main` (`feat/eng-5814-test`) that, after merge,
satisfies these acceptance criteria, verifiable via
`bash bin/linear-test.sh && bash -n bin/linear.sh && bash -n bin/pipeline-events.json && bash bin/secret-probe-lint.sh && bash bin/generate-vocabulary-doc.sh`
exiting 0 with the new C-001/C-002/C-003/C-004 cases in PASS state and
existing add\_or\_update\_comment ENG-55 cases unchanged:

1. `bin/linear.sh::add_or_update_comment` — when the existing comment's
   body (with any `<!-- meta: reapplied at=… -->` line stripped) is
   byte-equal to the caller's body (also stripped), the function appends
   a fresh `<!-- meta: reapplied at=<iso8601-utc> -->` footer on the
   normalised body and emits one `comment-reapplied` metric event before
   calling `commentUpdate`. When bodies differ, no footer is appended
   and no metric fires.
2. `commentCreate` (the no-existing-comment branch) is untouched —
   first emissions never carry the footer.
3. `bin/pipeline-events.json::meta_kinds` carries `"reapplied"` so the
   ENG-60 closed registry covers the new marker shape.
4. `bin/linear-test.sh` carries cases C-001 (identical → footer),
   C-002 (different → no footer), C-003 (rotation, not stacking) and
   C-004 (metric-emission count) — all PASS against the modified
   `linear.sh`.
5. `docs/runbooks/recovery.md` carries a §4 "Halted issue with
   stale-looking halt comment timestamp" with an operator decision tree
   and the `bash bin/linear.sh get-comments | jq` recipe.
6. `CLAUDE.md` Failure-mode quick reference row "Issue stuck in
   `stage:X`" mentions the footer caveat in a parenthetical.
7. `docs/pipeline-vocabulary.md` has been regenerated from the updated
   registry (the closed event registry section reflects `reapplied`).

Out of scope (explicit per brainstorm §10 + Q-001/Q-002/Q-003):

- Approach B (per-stage sig split for `protocol-violation`).
- Re-apply counter footer (`<!-- meta: reapplied count=N at=… -->`).
- Modernising `docs/runbooks/recovery.md` §3 stale `bin/halt.sh` refs.
- Surfacing re-apply count in `bin/pipeline.sh decide --action continue`
  output.

## Architecture

This work is additive to one library function (`bin/linear.sh::add_or_update_comment`),
its sibling test (`bin/linear-test.sh`), the closed-vocabulary registry
(`bin/pipeline-events.json`), and one operator runbook
(`docs/runbooks/recovery.md`); `CLAUDE.md` gets a one-row touch-up; the
auto-generated vocabulary doc gets re-rendered.

The architectural pivot is making `add_or_update_comment`'s update path
observably idempotent — today the call hits `commentUpdate` whether or
not the body has changed; Linear's API short-circuits no-op updates and
the operator loses the "did this halt re-fire?" signal. The fix moves
the no-op detection into the caller (us): we compare existing-vs-new
ourselves, and on byte-equality append a single rotating footer that
forces `updatedAt` to advance AND gives the operator inspectable proof
of the latest re-apply moment. Callers (`bin/verdict-handler.sh`,
`bin/classify-failure.sh`, `bin/run-stage.sh::post_completion_comment`)
are unchanged — they keep posting the same bodies they post today and
get the new visibility property for free.

There is no `docs/VISION.md`, no `docs/knowledge/decisions.md`, no
`SYSTEM_ARCHITECTURE.md` in this repo (verified: `ls docs/` returns
`brainstorms/  plans/  runbooks/  pipeline-vocabulary.md  pipeline-vocabulary.template.md  plans/`).
Governing constraints come from `CLAUDE.md` and
`learned-rules/harness/project-profile.md`. The `learned-rules/harness/plan.md`
file does not exist (verified: `ls learned-rules/harness/` returns
`project-profile.md` only).

## Tech stack

- Bash 3.2+ (Darwin default, harness target).
- `jq` for the existing-body extract from the already-fetched GraphQL
  payload.
- BSD `sed -E` with line-anchored regex for the strip step (macOS
  default; no GNU coreutils dependency).
- BSD `date -u +%Y-%m-%dT%H:%M:%SZ` for the iso8601 footer timestamp
  (verified macOS-native).
- `bin/metrics.sh` for the new `comment-reapplied` event (writes any
  event name verbatim — no schema change).
- No new dependencies. No `dispatch.sh::allowed_tools_for` cases added
  (`linear.sh` is not agent-dispatched at this granularity; agents call
  it via the existing `Bash(bash bin/linear.sh:*)` allowlist).

## Assumption Inventory

Every modified-file fact below is `path:line`-cited against the current
worktree per ENG-5 P-002 / B-001. Assumptions marked `assumed/new`
identify the file where the artifact will be created.

### Modified files — current signatures and call sites

- **A-001 — `bin/linear.sh::add_or_update_comment` lives at
  `bin/linear.sh:529-582`.** Verified. Concrete signature
  (`bin/linear.sh:529-541`):
  ```bash
  add_or_update_comment() {
    # $1 = sig (e.g., "halt/implement/ENG-14")
    # $2 = ident (e.g., "ENG-14")
    # $3+ = body, accepted via the same --body / --body-file / --body - / legacy
    #       positional shapes as add-comment (ENG-55).
    local sig="$1" ident="$2"; shift 2
    [[ -n "$sig" && -n "$ident" ]] \
      || die "add-or-update-comment: <sig> and <ident> required"
    local body
    body="$(_resolve_body_arg "$@")"
    [[ -n "$body" ]] \
      || die "add-or-update-comment: body is empty (received no --body, --body-file, or stdin via --body -)"
    _reject_legacy_marker_body "add-or-update-comment" "$body" || return $?
  ```
  Marker append at `bin/linear.sh:547-551`; dry-run short-circuit at
  `:553-556`; existing-id resolution at `:561-567`; commentUpdate branch
  at `:569-574`; commentCreate branch at `:575-581`. The plan inserts
  ~14 lines BETWEEN line 567 (end of `existing_id` resolution) and line
  569 (start of the `if [[ -n "$existing_id" ]]; then` block).

- **A-002 — `bin/linear.sh:561-567` already fetches `{ id body }` for up
  to 50 comments.** Verified — the GraphQL query at line 562 is
  `query($id: String!) { issue(id: $id) { comments(first: 50, orderBy: updatedAt) { nodes { id body } } } }`.
  The `body` field is currently discarded by the `existing_id`
  extractor at `:566-567`; the plan reuses the SAME response (`$resp`)
  to extract `existing_body` via a second `jq` selector — no extra
  GraphQL roundtrip.

- **A-003 — Caller call sites that pass identical bodies on re-apply.**
  Three confirmed:
  - `bin/verdict-handler.sh:52-60::_vh_protocol_violation` — sig
    `protocol-violation/<case_id>/<issue>`, body shape
    `<!-- pipeline: verdict result=halt reason=protocol-violation -->\n\nProtocol violation (<case_id>): <reason>` —
    deterministic for a given `(case_id, reason)`, so re-firing on
    a later stage re-applies an identical body. Verified at
    `bin/verdict-handler.sh:52-60`.
  - `bin/classify-failure.sh:124-146` — sig `halt/$stage/$issue`, body
    constructed at `:131-144` carrying `pipeline_content_hash` and
    `branch_head_sha`. Identical-body window: same stage halting twice
    with same exit code, subcode, retry\_count, branch and content hash
    (the `retry-immediately` churn case). Verified.
  - `bin/run-stage.sh:147-217::post_completion_comment` — sig
    `completion/$stage/$issue` (verified via `grep "completion/" bin/run-stage.sh`),
    body deterministically composed from the agent's stage-summary
    file. Identical-body window: re-dispatch on an unchanged worktree.
    Verified at `bin/run-stage.sh:212,216`.

  None of these callers are modified by the plan — the visibility
  property is delivered transparently inside `add_or_update_comment`.

- **A-004 — `bin/pipeline-events.json::meta_kinds` is a top-level
  three-element array at lines 42-46.** Verified:
  ```json
  "meta_kinds": [
    "dedup",
    "metric",
    "evidence"
  ],
  ```
  Plan appends `"reapplied"` as the fourth element. No schema change;
  the jq-based generator at `bin/generate-vocabulary-doc.sh:14`
  iterates the array unchanged.

- **A-005 — `bin/generate-vocabulary-doc.sh:11-23` regenerates
  `docs/pipeline-vocabulary.md` from `bin/pipeline-events.json` +
  `docs/pipeline-vocabulary.template.md`.** Verified — the script
  iterates `meta_kinds` along with seven other registry fields at line
  14 and emits one bullet per element. Adding `reapplied` to the array
  surfaces it in the auto-generated doc on the next run.

- **A-006 — `bin/linear-test.sh:493-510` carries the existing
  `add_or_update_comment` test block.** Verified at lines 493-510 — three
  ENG-55 cases (stdin body, legacy positional body, empty-body die).
  All run under `PIPELINE_DRY_RUN=1` (set at line 13) and reach the
  dry-run short-circuit at `bin/linear.sh:553-556` before any GraphQL.
  Plan APPENDS C-001/C-002/C-003/C-004 after line 510 and before the
  RESULTS summary at lines 512-515. Existing ENG-55 cases stay
  unchanged.

- **A-007 — `bin/linear-test.sh:1-92` provides reusable scaffolding.**
  Verified — `_TEST_TARGET_DIR`/`_TEST_STUB_DIR` (lines 19-40, with
  `_test_assert_temp_path` and `_test_safe_rm` traps), `TARGET_REPO`
  scaffold + linear-ids fixture (lines 42-71), `HARNESS_STATE_DIR` +
  `PROJECT_STATE_DIR` setup (lines 73-77), source of `linear.sh` at
  line 82 with post-source `SCRIPT_DIR=$_TEST_STUB_DIR` override at
  line 87, `PASS`/`FAIL`/`pass_at`/`fail_at` helpers at lines 90-92.
  C-001…C-004 reuse this scaffolding; no new fixture infrastructure.

- **A-008 — `bin/linear.sh::linear_query` (line 156) short-circuits
  mutations under `PIPELINE_DRY_RUN=1` but NOT queries.** Verified at
  `bin/linear.sh:160-164` — only `[[ "$PIPELINE_DRY_RUN" == "1" && "$query" =~ mutation ]]`
  triggers the dry-run path; queries still hit `curl`. The
  `add_or_update_comment` outer dry-run guard at `:553-556` short-
  circuits the WHOLE function before any `linear_query` is reached.
  C-001…C-004 must therefore (a) flip `PIPELINE_DRY_RUN=0` for the
  duration of the four cases (and back to `1` afterwards to leave the
  rest of the file's invariants intact), and (b) override
  `linear_query` post-source to inject controlled GraphQL responses
  without making real network calls.

- **A-009 — Post-source overriding `linear_query` is the documented
  pattern.** Verified — `bin/linear.sh:156-194` defines `linear_query`
  at top level (no `local`), so re-defining it after `source` replaces
  the global. The comment at `bin/linear-test.sh:84-87` already
  documents this idiom for `SCRIPT_DIR`. Same idiom applies to
  `linear_query`.

- **A-010 — `bin/metrics.sh::main` signature accepts arbitrary event
  names.** Verified at `bin/metrics.sh:19-41` — the only validation is
  `[[ -n "$event" && -n "$outcome" ]]` (line 41). `comment-reapplied`
  is a new event name but no `metrics.sh` code change is needed; the
  helper writes `event:$event` verbatim into `events.jsonl` at line 67.

- **A-011 — `bin/metrics.sh:43` writes to
  `$PROJECT_STATE_DIR/metrics/events.jsonl`.** Verified. `mkdir -p` at
  line 47 makes the directory idempotently. C-004 asserts on the
  presence of one new line in this file (per-test `PROJECT_STATE_DIR`
  is the temp-dir scaffold from `bin/linear-test.sh:73-77`).

- **A-012 — `_reject_legacy_marker_body` (`bin/linear.sh:402-416`)
  guards against `<!-- pipeline-(stage-summary|rejection|rejection-target|halt|wait|decision|sig|metric|transition): -->`
  shapes only.** Verified — the `<!-- meta: reapplied at=… -->` shape
  is in the new `meta:` namespace, not the rejected legacy `pipeline-:`
  family, and is therefore not impacted by the guard.

- **A-013 — `add_or_update_comment` does not call `_check_lane`.**
  Verified — `bin/linear.sh:529-582` carries no `_check_lane`
  invocation; the only lane-fenced call path is `add_comment` at
  `bin/linear.sh:476-479`. The footer-rewrite branch therefore
  inherits whatever lane the existing comment was originally posted
  under; no new lane consideration. (The asymmetry between
  `add_comment` and `add_or_update_comment` is a pre-existing property
  flagged for follow-up in the brainstorm's §7 security row, but is
  out of scope for ENG-63.)

- **A-014 — `docs/runbooks/recovery.md` exists and currently covers
  three "stuck" recovery modes.** Verified at lines 1-251. §1 (multiple
  stage labels), §2 (forged transition comment), §3 (stuck halted with
  protocol-violation marker). No §4 today. The plan APPENDS §4 between
  the existing §3 (ends \~line 226 with the verify block at lines
  205-225) and the "Quick reference: env var requirement" tail
  (lines 229-251).

- **A-015 — `CLAUDE.md` Failure-mode quick reference table is at lines
  328-336.** Verified — five rows; row 3 is `Issue stuck in stage:X`
  at line 334:
  ```
  | Issue stuck in `stage:X` | Linear comments under sigs `halt/<stage>/<issue>`, `scope-approval/<stage>/<issue>` |
  ```
  Plan replaces the right-hand cell with a parenthetical addendum
  pointing at the new footer behaviour and the recovery.md §4 cross-
  reference.

- **A-016 — `docs/pipeline-vocabulary.md` is regenerated by
  `bin/generate-vocabulary-doc.sh`.** Verified — file header at line 1
  exists; the generator's perl substitution at lines 30-42 fills in
  the `<!-- GENERATED:registry --> ... <!-- /GENERATED:registry -->`
  block. Plan re-runs the generator (Task 5) so the merged tree
  carries the regenerated doc.

- **A-017 — `bin/secret-probe-lint.sh` enforces the ENG-46 secret-
  handling rule.** Verified (per CLAUDE.md preamble). The new
  `add_or_update_comment` body uses `${PIPELINE_DRY_RUN:-0}` (already
  present at `bin/linear.sh:553`) and reads no env var matching the
  forbidden regex `*KEY|*TOKEN|*SECRET|ANTHROPIC*|GITHUB*|LINEAR*`.
  No new lint exposure.

### Read-only callees / state shapes — verified, not modified

- **A-018 — `bin/run-stage.sh:212,216::post_completion_comment` already
  retries `add-or-update-comment` once on failure.** Verified — the
  caller-side retry behaviour is preserved; identical-body second-attempt
  retries continue to dedup-by-sig and now (post-fix) gain a `reapplied`
  footer if the first attempt's `commentUpdate` succeeded but the bash
  process crashed before returning. Edge case documented; no defensive
  code needed.

- **A-019 — `bin/verdict-handler.sh:56-57` calls `add-or-update-comment`
  via `bash "$_VH_SCRIPT_DIR/linear.sh"`.** Verified. The footer
  behaviour applies transparently; no caller-side change.

- **A-020 — `bin/classify-failure.sh:146` calls `add-or-update-comment`
  via `bash "$_CFS_SCRIPT_DIR/linear.sh"`.** Verified at line 146.
  Same — caller is unchanged; footer applies transparently when the
  body is identical.

- **A-021 — `bin/linear.sh::SCRIPT_DIR` is the per-script directory
  resolved at line 26.** Verified. The metrics-call inside the new
  branch uses `bash "$SCRIPT_DIR/metrics.sh"` exactly the same way
  `bin/run-stage.sh` already invokes metrics.sh from a sibling
  position (`bin/run-stage.sh:130,505,510,557,664,716,736,805,839`).

### Assumed/new artifacts

- **A-N1 — Identical-body detection block (~14 lines)** is NEW in
  `bin/linear.sh::add_or_update_comment`, inserted between line 567
  (end of `existing_id` resolution) and line 569 (start of the
  `if [[ -n "$existing_id" ]]; then` block). No new helper functions;
  the block is inline per D-008.

- **A-N2 — `comment-reapplied` metric event** is NEW. No
  `bin/metrics.sh` code change required (A-010). Downstream consumers
  (`bin/status.sh`, the retrospective agent) do not filter on this
  event today; they will start to once it exists, per the established
  "additive event name" convention (precedent: `stage-end`,
  `halt-resume`).

- **A-N3 — `<!-- meta: reapplied at=<iso8601-utc> -->`** is a NEW
  marker shape under the existing `meta:` namespace. Registered in
  `bin/pipeline-events.json::meta_kinds` (D-005). Auto-surfaces in
  `docs/pipeline-vocabulary.md` on the next generator run.

- **A-N4 — Test cases C-001/C-002/C-003/C-004** are NEW in
  `bin/linear-test.sh`, appended after the existing ENG-55 case at
  line 510 and before the RESULTS summary at line 513. Cases require
  a `linear_query` override (post-source) and a temporary
  `PIPELINE_DRY_RUN=0` flip (re-set to `1` after the four cases). The
  override approach is the same idiom used at `bin/linear-test.sh:87`
  for `SCRIPT_DIR`.

- **A-N5 — `docs/runbooks/recovery.md::§4`** is NEW. Inserted between
  the existing §3 verify block and the "Quick reference" tail
  (between lines 226 and 229).

- **A-N6 — `CLAUDE.md` parenthetical** on row "Issue stuck in
  `stage:X`" (line 334) is a one-line in-place edit.

## File Structure

```
bin/
  linear.sh                                  modified — insert ~14 lines into add_or_update_comment
                                                        between existing_id resolution (:567) and the
                                                        commentUpdate branch (:569). One metrics.sh call
                                                        on the identical-body path. (Task 1)
  pipeline-events.json                       modified — append "reapplied" to meta_kinds. (Task 2)
  linear-test.sh                             modified — append C-001/C-002/C-003/C-004 after line 510;
                                                        post-source linear_query override + PIPELINE_DRY_RUN
                                                        flip; re-set PIPELINE_DRY_RUN=1 after the four
                                                        cases. (Task 3)

docs/
  runbooks/
    recovery.md                              modified — insert new §4 "Halted issue with stale-looking
                                                        halt comment timestamp" between §3 and the
                                                        "Quick reference" tail. (Task 4)
  pipeline-vocabulary.md                     modified — auto-regenerated from the updated
                                                        pipeline-events.json. (Task 5)
  plans/
    2026-05-04-eng-63-...md                  NEW — this file.

CLAUDE.md                                    modified — parenthetical added to row 3 of the Failure-mode
                                                        quick reference table at line 334. (Task 4)
```

No changes to: `bin/verdict-handler.sh`, `bin/classify-failure.sh`,
`bin/run-stage.sh`, `bin/run-local.sh`, `bin/poll.sh`, `bin/dispatch.sh`,
`bin/scope-check.sh`, `bin/halt-sprawl-test.sh`, `bin/run-local-helpers.sh`,
`bin/common.sh`, `bin/metrics.sh`, `bin/pipeline.sh`, `AGENT_PROMPTS.md`,
`learned-rules/**`, `launchd/**`, `.github/workflows/**`,
`docs/pipeline-vocabulary.template.md` (template untouched; generator
re-renders the registry section).

## API Contract

**No new API surface.** The harness has no FE↔BE API surface;
`add_or_update_comment` is an internal bash function called via
`bash bin/linear.sh add-or-update-comment <sig> <ident> <body>`. The
public CLI signature is unchanged. The change adds:

- One new metrics event name (`comment-reapplied`) — written verbatim
  by the pre-existing `bin/metrics.sh` helper. No schema migration
  (A-010, A-N2).
- One new HTML-comment footer shape (`<!-- meta: reapplied at=<iso8601-utc> -->`)
  emitted on identical-body re-applies. Registered in
  `bin/pipeline-events.json::meta_kinds` per the ENG-60 closed-
  vocabulary discipline.
- Three idempotent post-conditions on the existing `commentUpdate`
  invocation: (i) bodies that DIFFER (after stripping any prior
  footer) are posted as-is, no footer; (ii) bodies that are IDENTICAL
  (after the strip) gain exactly one footer rotated to the latest
  iso8601-utc moment; (iii) one `comment-reapplied` metric event fires
  per identical-body update.

No CLI argv change, no env-var addition, no on-disk state-file format
change, no new exit code, no new lane fence. The four-shape verdict
vocabulary (`pass | fail | halt | wait`) is untouched.

## Backend Tasks

### Task 1: Insert identical-body detection + footer rewrite + metric emit into `bin/linear.sh::add_or_update_comment`

- `depends_on: []`
- `touches: bin/linear.sh::add_or_update_comment`

- [ ] **Step 1.1 — Insert ~14 lines between `bin/linear.sh:567` and
  `:569`.** The insertion sits AFTER the existing `existing_id`
  extractor and BEFORE the `if [[ -n "$existing_id" ]]; then` block.
  The block uses the SAME `$resp` already in scope from the GraphQL
  fetch at `:565`; no extra GraphQL roundtrip.

  Concrete patch (apply between line 567 and line 569 of `bin/linear.sh`):
  ```bash
  if [[ -n "$existing_id" ]]; then
    # ENG-63: detect identical-body re-apply and append a re-applied
    # footer so Linear's updatedAt advances and operators see a visible
    # cue. Strip ONLY the line-anchored `<!-- meta: reapplied at=… -->`
    # marker before comparing — anchors prevent stripping a quoted
    # mention of the marker shape inside a fenced code block.
    local existing_body strip_re existing_norm new_norm now_iso
    existing_body="$(jq -r --arg id "$existing_id" \
      '[.data.issue.comments.nodes[]? | select(.id == $id) | .body] | first // ""' \
      <<<"$resp")"
    strip_re='/^<!-- meta: reapplied at=[^>]* -->$/d'
    existing_norm="$(printf '%s' "$existing_body" | sed -E "$strip_re")"
    new_norm="$(printf '%s' "$body" | sed -E "$strip_re")"
    if [[ "$existing_norm" == "$new_norm" && -n "$existing_norm" ]]; then
      now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      body="${new_norm}"$'\n'"<!-- meta: reapplied at=${now_iso} -->"
      bash "$SCRIPT_DIR/metrics.sh" comment-reapplied "$ident" "-" \
        "reapplied" 0 "sig=$sig" "comment_id=$existing_id" || true
    fi
    local mu='mutation($id: String!, $body: String!) { commentUpdate(id: $id, input: { body: $body }) { success } }'
    # … unchanged from bin/linear.sh:570-573 …
  ```

  The `&& -n "$existing_norm"` guard prevents an empty `existing_body`
  (jq parse failure or null body — see brainstorm §5) from triggering
  a footer append against an empty string. Behaviour on parse failure:
  fall through to a normal `commentUpdate` with the caller's body —
  functionally equivalent to today, no new failure mode.

- [ ] **Step 1.2 — Verify `bash -n bin/linear.sh` is clean.** The only
  syntax gate.

- [ ] **Step 1.3 — Verify `bash bin/secret-probe-lint.sh` passes.**
  No new env-var fallback patterns introduced (per A-017).

### Task 2: Append `"reapplied"` to `bin/pipeline-events.json::meta_kinds`

- `depends_on: []`
- `touches: bin/pipeline-events.json`

- [ ] **Step 2.1 — Open `bin/pipeline-events.json` and append
  `"reapplied"` as the fourth element of `meta_kinds` (currently lines
  42-46).** The post-edit shape:
  ```json
  "meta_kinds": [
    "dedup",
    "metric",
    "evidence",
    "reapplied"
  ],
  ```

- [ ] **Step 2.2 — Verify the JSON is well-formed.** Run
  `jq '.meta_kinds' bin/pipeline-events.json` — should print the
  four-element array.

### Task 3: Append C-001/C-002/C-003/C-004 to `bin/linear-test.sh`

- `depends_on: [1, 2]`
- `touches: bin/linear-test.sh`

- [ ] **Step 3.1 — Insert the four cases between line 510 and line
  512** (after the last ENG-55 case; before the `# ─── Summary ───`
  block at line 512). The insertion follows the source-and-stub
  pattern documented in `bin/linear-test.sh:84-87`. Concrete shape:

  ```bash
  # ─── ENG-63: add_or_update_comment identical-body footer (C-001..C-004) ──
  printf '\n--- ENG-63: identical-body re-apply visibility ---\n'

  # Override linear_query post-source to inject controlled GraphQL
  # responses. This bypasses curl entirely. Save originals first so we
  # can restore at the end of the section.
  _eng63_orig_linear_query="$(declare -f linear_query)"
  _eng63_orig_resolve_uuid="$(declare -f _resolve_issue_uuid)"
  _eng63_orig_dry_run="$PIPELINE_DRY_RUN"

  # Stub _resolve_issue_uuid so it does not hit the cache lookup (or
  # call out to GraphQL).
  _resolve_issue_uuid() { printf 'uuid-mock'; }

  # Capture for assertions.
  _eng63_capture_file="$(mktemp -t eng63-capture.XXXXXX)"
  _eng63_canned_existing_body=""
  _eng63_canned_existing_id="cmt-mock-001"

  # linear_query stub: route by GraphQL operation. Reads return a
  # canned comments list; mutations record their body to the capture
  # file and return success.
  linear_query() {
    local query="$1" variables="${2:-{\}}"
    if [[ "$query" =~ commentUpdate ]]; then
      jq -r '.body' <<<"$variables" >> "$_eng63_capture_file"
      printf '{"data":{"commentUpdate":{"success":true}}}\n'
      return 0
    fi
    if [[ "$query" =~ commentCreate ]]; then
      jq -r '.body' <<<"$variables" >> "$_eng63_capture_file"
      printf '{"data":{"commentCreate":{"success":true}}}\n'
      return 0
    fi
    # Read query — return a single canned comment carrying the dedup marker
    # and the canned existing body.
    jq -cn --arg id "$_eng63_canned_existing_id" --arg body "$_eng63_canned_existing_body" \
      '{data:{issue:{comments:{nodes:[{id:$id,body:$body}]}}}}'
  }

  export PIPELINE_DRY_RUN=0
  export PROJECT_STATE_DIR
  mkdir -p "$PROJECT_STATE_DIR/metrics"
  : > "$PROJECT_STATE_DIR/metrics/events.jsonl"

  # ── C-001: identical body (no prior footer) → footer appended ──
  : > "$_eng63_capture_file"
  _eng63_canned_existing_body=$'Test body line 1\nTest body line 2\n\n<!-- meta: dedup key=test/sig/ENG-63T -->'
  add_or_update_comment "test/sig/ENG-63T" ENG-63T \
    --body "$_eng63_canned_existing_body" >/dev/null 2>&1
  if grep -qE '^<!-- meta: reapplied at=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z -->$' "$_eng63_capture_file"; then
    pass_at "C-001 identical body → footer appended"
  else
    fail_at "C-001 identical body → footer appended" "captured: $(cat "$_eng63_capture_file")"
  fi

  # ── C-002: different body → no footer ──
  : > "$_eng63_capture_file"
  _eng63_canned_existing_body=$'Test body line 1\n\n<!-- meta: dedup key=test/sig/ENG-63T -->'
  add_or_update_comment "test/sig/ENG-63T" ENG-63T \
    --body $'Test body line 1 CHANGED\n\n<!-- meta: dedup key=test/sig/ENG-63T -->' >/dev/null 2>&1
  if grep -q '<!-- meta: reapplied at=' "$_eng63_capture_file"; then
    fail_at "C-002 different body → no footer" "captured: $(cat "$_eng63_capture_file")"
  else
    pass_at "C-002 different body → no footer"
  fi

  # ── C-003: identical body + prior footer → footer rotated, not stacked ──
  : > "$_eng63_capture_file"
  _eng63_canned_existing_body=$'Test body line 1\n<!-- meta: dedup key=test/sig/ENG-63T -->\n<!-- meta: reapplied at=2025-01-01T00:00:00Z -->'
  add_or_update_comment "test/sig/ENG-63T" ENG-63T \
    --body $'Test body line 1\n<!-- meta: dedup key=test/sig/ENG-63T -->' >/dev/null 2>&1
  _eng63_footer_count="$(grep -cE '^<!-- meta: reapplied at=' "$_eng63_capture_file" || true)"
  _eng63_has_old_ts="$(grep -c '2025-01-01T00:00:00Z' "$_eng63_capture_file" || true)"
  if [[ "$_eng63_footer_count" == "1" && "$_eng63_has_old_ts" == "0" ]]; then
    pass_at "C-003 identical body + prior footer → rotated, not stacked"
  else
    fail_at "C-003 identical body + prior footer → rotated, not stacked" \
      "footer_count=$_eng63_footer_count has_old_ts=$_eng63_has_old_ts captured: $(cat "$_eng63_capture_file")"
  fi

  # ── C-004: identical body emits exactly one comment-reapplied metric ──
  : > "$PROJECT_STATE_DIR/metrics/events.jsonl"
  : > "$_eng63_capture_file"
  _eng63_canned_existing_body=$'Test body line 1\n\n<!-- meta: dedup key=test/sig/ENG-63T -->'
  add_or_update_comment "test/sig/ENG-63T" ENG-63T \
    --body "$_eng63_canned_existing_body" >/dev/null 2>&1
  _eng63_metric_count="$(grep -c '"event":"comment-reapplied"' "$PROJECT_STATE_DIR/metrics/events.jsonl" || true)"
  if [[ "$_eng63_metric_count" == "1" ]]; then
    pass_at "C-004 identical body → one comment-reapplied metric event"
  else
    fail_at "C-004 identical body → one comment-reapplied metric event" \
      "metric_count=$_eng63_metric_count events.jsonl: $(cat "$PROJECT_STATE_DIR/metrics/events.jsonl")"
  fi

  # ── Restore originals ──
  rm -f "$_eng63_capture_file"
  unset -f linear_query _resolve_issue_uuid
  eval "$_eng63_orig_linear_query"
  eval "$_eng63_orig_resolve_uuid"
  export PIPELINE_DRY_RUN="$_eng63_orig_dry_run"
  ```

- [ ] **Step 3.2 — Run `bash bin/linear-test.sh`** and confirm:
  - All four new cases (C-001, C-002, C-003, C-004) PASS.
  - The pre-existing ENG-55 cases (lines 480-510) still PASS.
  - The pre-existing lane-fence matrix cases (sections 1-5) still
    PASS.
  - Exit code 0.

### Task 4: Add `docs/runbooks/recovery.md` §4 and `CLAUDE.md` parenthetical

- `depends_on: [1]`
- `touches: docs/runbooks/recovery.md, CLAUDE.md`

- [ ] **Step 4.1 — Insert §4 in `docs/runbooks/recovery.md`** between
  the §3 verify block (ends at line 226) and the "Quick reference: env
  var requirement" tail at line 229. The new section follows the
  format of §§1-3 (heading, Symptom subsection, Detect subsection,
  Operator decision tree, Verify). Concrete content (per brainstorm
  D-007):

  ```markdown
  ---

  ## 4. Halted issue with stale-looking halt comment timestamp

  An issue carries `pipeline:halted` but the most-recent halt comment
  shows a `createdAt` timestamp from a much earlier occurrence. The
  thread looks as if the halt was already resolved (no fresh comment
  appears to mark a re-fire), yet the label is present.

  ### Symptom

  - `bash bin/linear.sh has-label ENG-N pipeline:halted` returns 0.
  - The most-recent `<!-- pipeline: verdict result=halt … -->` comment's
    `createdAt` is many minutes/hours/days older than the most recent
    `bash bin/pipeline.sh decide ENG-N --action continue` operator action.
  - Linear's web UI does NOT reliably surface "(edited)" for API-driven
    `commentUpdate` calls; do not rely on the indicator. `createdAt`
    is the original first-emission moment regardless of any updates.

  ### Authoritative signal

  **The `pipeline:halted` LABEL is the state of record.** Comment
  `createdAt` reflects only the FIRST emission of any given halt body;
  identical-body re-applies update the existing comment in place. ENG-63
  introduced a `<!-- meta: reapplied at=<iso8601-utc> -->` footer that
  gives operators an inspectable signal of the latest re-apply moment.

  ### Recency evidence

  Filter for the most recent halt comment and inspect its full body:

  ```bash
  bash bin/linear.sh get-comments ENG-N \
    | jq -r '.[] | select(.body | contains("verdict result=halt")) | .body' \
    | tail -1
  ```

  Look for a `<!-- meta: reapplied at=<ts> -->` line at the bottom of
  that comment body. The timestamp on that line is the most recent
  re-application moment (NOT the original `createdAt`).

  ### Operator decision tree

  - **Footer present AND timestamp recent (\< 1h)** → halt is FRESH.
    Investigate the halt's `reason=` token (read the full comment body)
    BEFORE running `bash bin/pipeline.sh decide ENG-N --action continue`.
    A bare `--action continue` will be silently re-halted within seconds.
  - **Footer present BUT timestamp old (\> 1h)** → halt has not re-fired
    since the footer's timestamp; safe to investigate at leisure or run
    `bash bin/pipeline.sh decide ENG-N --action continue` if the cause was
    external (CI flake, infrastructure outage).
  - **Footer absent** → halt has only ever been emitted once at
    `createdAt`; treat per §3 guidance.

  ### Verify

  After `--action continue`, re-fetch the comment thread and confirm:

  1. `bash bin/linear.sh has-label ENG-N pipeline:halted || echo "not halted"`
     returns `not halted`.
  2. The next 5-minute poll tick proceeds without re-applying
     `pipeline:halted` — check `$PROJECT_STATE_DIR/logs/local-*.log`
     for a successful dispatch entry on the next stage.

  ---
  ```

- [ ] **Step 4.2 — Update `CLAUDE.md` row 3 of the Failure-mode quick
  reference** (line 334). Replace:
  ```
  | Issue stuck in `stage:X` | Linear comments under sigs `halt/<stage>/<issue>`, `scope-approval/<stage>/<issue>` |
  ```
  with:
  ```
  | Issue stuck in `stage:X` | Linear comments under sigs `halt/<stage>/<issue>`, `scope-approval/<stage>/<issue>` (comment `createdAt` reflects FIRST emission only; check the `<!-- meta: reapplied at=… -->` footer for the latest re-apply moment — see `docs/runbooks/recovery.md` §4) |
  ```

### Task 5: Regenerate `docs/pipeline-vocabulary.md`

- `depends_on: [2]`
- `touches: docs/pipeline-vocabulary.md`

- [ ] **Step 5.1 — Run the generator from the repo root.**
  ```bash
  bash bin/generate-vocabulary-doc.sh
  ```
  The generator's perl substitution at `bin/generate-vocabulary-doc.sh:30-42`
  refreshes the `<!-- GENERATED:registry --> ... <!-- /GENERATED:registry -->`
  block in `docs/pipeline-vocabulary.md` to include `reapplied` under
  the `meta_kinds` heading.

- [ ] **Step 5.2 — Verify** the generated section now lists the four
  meta kinds (`dedup`, `metric`, `evidence`, `reapplied`) by visually
  inspecting the regenerated file or running:
  ```bash
  grep -A 4 '^### `meta_kinds`' docs/pipeline-vocabulary.md
  ```

### Task 6: Run the full test gate

- `depends_on: [1, 2, 3, 4, 5]`
- `touches: (none — verification only)`

- [ ] **Step 6.1 — Run the project-profile test enumeration** per
  `learned-rules/harness/project-profile.md::Test:`. From the repo root:
  ```bash
  bash bin/dispatch-test.sh && bash bin/run-stage-test.sh && bash bin/poll-slot-test.sh \
    && bash bin/scope-check-test.sh && bash bin/verdict-handler-test.sh \
    && bash bin/classify-failure-test.sh && bash bin/halt-sprawl-test.sh \
    && bash bin/halt-sprawl-adversarial-test.sh && bash bin/linear-test.sh \
    && bash bin/metrics-test.sh && bash bin/mutex-test.sh \
    && bash bin/setup-helpers-test.sh && bash bin/render-prompt-test.sh \
    && bash bin/phase-project-profile-test.sh && bash bin/common-test.sh
  ```
  Expect exit 0. The four new C-001…C-004 cases in `bin/linear-test.sh`
  must show as PASS in the section "ENG-63: identical-body re-apply
  visibility".

- [ ] **Step 6.2 — Run the syntax check.**
  ```bash
  bash -n bin/linear.sh
  ```

- [ ] **Step 6.3 — Run the secret-probe lint.**
  ```bash
  bash bin/secret-probe-lint.sh
  ```

## Frontend Tasks

**No frontend work.** The harness has no UI surface; no UI Agent
dispatch; no `bin/ui/`-equivalent paths. Per the project profile —
"This repo contains no application code; it is the harness that drives
an SDLC pipeline against a separate target repo."

## Failure Mode → Test Map

Pulled from the brainstorm's §5 Error Handling and §6 Edge Cases.

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
|---|---|---|---|---|
| Identical body re-applied (no prior footer) | Caller posts the SAME body that already exists under the sig | Footer `<!-- meta: reapplied at=<ts> -->` appended; one `comment-reapplied` metric event fires; commentUpdate called with the new body | unit | `C-001 identical body → footer appended` |
| Different body re-applied | Caller posts a body that differs (after stripping any prior footer) | No footer appended; commentUpdate called with the caller's body verbatim; no metric event | unit | `C-002 different body → no footer` |
| Identical body, prior footer present | Existing comment carries `<!-- meta: reapplied at=<ts1> -->`; caller posts identical body (no footer) | Old footer stripped; new footer with fresh timestamp appended; exactly ONE footer line in the resulting body | unit | `C-003 identical body + prior footer → rotated, not stacked` |
| Identical body emits metric | Caller posts identical body → footer path | Exactly ONE `comment-reapplied` JSONL line written to `events.jsonl` per identical-body re-apply | unit | `C-004 identical body → one comment-reapplied metric event` |
| First-ever post (no existing comment) | Caller posts under a new sig with no existing comment | `commentCreate` called with the body verbatim; no footer; no metric | unit | `C-006 no existing comment → no footer on create` |
| jq extraction returns empty body | GraphQL response shape is malformed or `body` is null | `existing_norm` empty; `&& -n "$existing_norm"` guard skips the footer; commentUpdate called with caller's body verbatim (functionally equivalent to today's behaviour) | unit | (no separate fixture — the guard is exercised implicitly by the create path in C-006: when the canned existing body is empty, the first jq's `select(.body \| contains($m))` yields no match, existing_id is empty, and the function takes the commentCreate branch instead of reaching the guard. To exercise the guard directly would require a stub that returns a node containing the marker but a `null` body — a shape Linear's API never produces in practice; the guard is a defensive belt-and-braces against a hypothetical jq parse failure.) |
| Trailing-newline asymmetry | Existing body carries trailing `\n` while caller's body does not | Footer still appended (shell `$()` strips trailing newlines from both norms; explicit `${var%$'\n'}` trim documents intent) | unit | `C-005 trailing-newline asymmetry → footer still appended` |
| Mixed legacy/new dedup marker shapes | Existing comment carries legacy `<!-- pipeline-sig: <sig> -->`, caller posts new `<!-- meta: dedup key=<sig> -->` | Bodies differ by marker shape → no footer → caller's body posted (in-place migration to new shape) | unit | (covered by C-002 — different bodies branch) |
| Caller passes body already containing `meta: reapplied` | Unexpected; tolerated | Strip applies symmetrically; caller's footer becomes a no-op residue; if equal, fresh footer rewritten; if unequal, caller's footer rides along | unit | (covered by C-003 — rotation logic strips both old and new footers identically) |
| Re-apply at exact same UTC second | Two re-applies separated by sub-second intervals | Identical timestamps → second re-apply's normalised body matches first's → bug re-emerges. Practical exposure: zero (harness tick is 5 min; Linear roundtrip alone takes \>100ms) | (none — documented impossibility, no defensive code per brainstorm §6) | n/a |
| `metrics.sh comment-reapplied` write fails | `events.jsonl` directory unwritable, etc. | `\|\| true` swallows; commentUpdate still proceeds with the footer | (none — `\|\| true` is a documented trade-off per D-009) | n/a |

## Test Strategy

### Unit (sole layer)

The change is fully testable at the unit level via the source-and-stub
pattern already used by `bin/linear-test.sh`. C-001…C-006 verify the
six critical observable properties (footer-on-identical, no-footer-on-
different, rotation, metric-emission count via before/after delta,
trailing-newline asymmetry pinned, no-footer-on-create). The
`linear_query` override technique (post-source global-function rewrite,
A-009) exercises both the `commentUpdate` and `commentCreate` branches
under controlled GraphQL responses without hitting the network.

The six cases are sufficient because the change touches exactly one
function (`add_or_update_comment`) at two branches (`commentUpdate` and
`commentCreate`), and the cases cover every observable behavioural axis
introduced:
1. footer-presence × body-identity (2x2 — three meaningful cells; the
   "different body + no prior footer → no footer" cell is C-002, the
   "identical body + no prior footer → footer added" cell is C-001,
   the "identical body + prior footer → rotated" cell is C-003; the
   "different body + prior footer → no footer" cell is the trivial
   composition of C-002 + the strip-symmetry, not separately
   exercised).
2. metric-emission count (C-004 — exactly 1 per identical-body
   re-apply, asserted as a before/after delta so prior-test residue
   does not mask a regression).
3. byte-equality robustness (C-005 — trailing-newline asymmetry
   between existing and caller body must not silently skip the footer).
4. create-path passthrough (C-006 — when no existing comment matches
   the sig, `commentCreate` is called and no footer is added).

### Integration / smoke / e2e

None added. The brainstorm explicitly rejected adding tests in
`bin/verdict-handler-test.sh` (D-006 rejection) — the bug is in
`linear.sh`'s update path, not in any caller's correctness. Existing
sibling tests (`bin/verdict-handler-test.sh`, `bin/classify-failure-test.sh`)
continue to dry-run-stub `linear.sh` and observe call shapes; their
contracts are unchanged because `add_or_update_comment`'s public CLI
(argv) is unchanged.

### Adversarial

None added. Two adversarial considerations from the brainstorm:
- Quoted prose containing the literal `<!-- meta: reapplied at=… -->`
  shape inside a fenced code block — handled by line-anchored regex
  (D-002); no test added because the strip's correctness on quoted
  prose is implicit in the regex shape (`^…$` anchors).
- Caller-supplied body already containing a footer — covered by C-003's
  rotation assertion.

The pre-existing adversarial test files (`bin/halt-sprawl-adversarial-test.sh`,
`bin/run-local-helpers-adversarial-test.sh`) target different surfaces;
no new adversarial file is warranted for a 14-line `add_or_update_comment`
patch.

---

## Self-review summary (5 personas)

Run inline this session per the planning stage's persona-review contract.
Five personas dispatched against the iter-1 draft.

| Persona | Verdict | P0 | Notes / changes from iter-1 |
|---|---|---|---|
| feasibility | PASS | 0 | All 21 codebase facts (A-001…A-021) verified against the current worktree at `path:line`. `meta_kinds` registry already present at `bin/pipeline-events.json:42-46`; `bin/generate-vocabulary-doc.sh:14` already iterates it; macOS BSD `date`/`sed` compatibility confirmed; jq selector valid against the `{ id body }` query payload at `bin/linear.sh:562`. The post-source `linear_query` override pattern matches the existing idiom at `bin/linear-test.sh:84-87`. Every task's `depends_on` and `touches` lists check out — Task 3 depends on Tasks 1+2 (needs the function change + registry append), Task 4 depends on Task 1 (runbook reflects the implemented behaviour), Task 5 depends on Task 2 (regen pulls from updated registry). Every Failure Mode → Test Map row names a concrete test by name; impossible/documented-only edge cases are explicitly marked n/a. |
| scope | PASS | 0 | Every task and every File Structure entry traces to a brainstorm decision: Task 1 → D-001/D-002/D-003/D-004/D-008/D-009; Task 2 → D-005; Task 3 → D-006; Task 4 → D-007; Task 5 → D-005 (auto-regen); Task 6 → AC verification. Acceptance criteria #1 (Approach A footer), #3 (test fixture), #4 (operator runbook) all covered; AC #2 (Approach B) cleanly rejected per D-001. Out-of-scope items (Q-001 counter footer, Q-002 §3 modernisation, Q-003 resume-time summary) explicitly listed. |
| coherence | PASS | 0 | Plan's Goal matches brainstorm §1 Overview (operator-visible re-apply signal). Backend tasks jointly realise every D-001…D-009 decision plus the §3.1 file-by-file matrix. Test Strategy covers every Failure Mode row with a named test or an explicit n/a. No frontend tasks (correctly stated as "no UI surface"). No API contract block (correctly stated as "no FE↔BE API surface"). |
| design | PASS | 0 | Plan respects bash file boundaries: changes confined to `bin/linear.sh::add_or_update_comment` (one function, one branch), the registry file, and the runbook. No new helper functions; no cross-file refactors; no caller-side changes. The metrics emission rides through the existing `bash "$SCRIPT_DIR/metrics.sh"` precedent (`bin/run-stage.sh:130` etc). The marker shape `<!-- meta: reapplied at=… -->` joins the existing `meta:` namespace per ENG-60 vocabulary closure. Lane fences untouched (the function does not call `_check_lane`; A-013). |
| product | PASS | 0 | Plan delivers the operator's actual ask in language they would recognise: "the comment now shows when the halt re-fired." The runbook §4 decision tree gives the operator a recipe for the exact symptom they hit on ENG-58. The metric emission (D-009) closes the retrospective-blindness gap so future halt-loops surface in the weekly review. Changes are scoped narrowly enough that an unrelated reviewer can verify the operator-visible behaviour by reading the C-001 fixture. |

**Gate:** 5/5 PASS, 0 P0. Threshold (≥4/5 PASS AND zero P0) cleanly
satisfied. Proceeding to implementing.
