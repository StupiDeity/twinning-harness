---
linear: ENG-206
date: 2026-06-17
topic: Apply orchestrator-merge to review-findings-ledger.jsonl — seed-header line carries ledger_schema_version
---

# Plan — Orchestrator owns `ledger_schema_version` via a 3rd seed-header line; agent emits content-only rows (ENG-206)

## Anti-anchoring check

- **Problem (operator-perspective):** "Reviewing dispatches halt at
  `stage:reviewing` with `review-ledger-incomplete: ledger_schema_version must
  be 1, got: MISSING` (rc=49). The agent wrote a content-correct finding row
  but slipped on one envelope key. This is the same slip class memory entry
  `qa-agent-schema-version-field-slip` documented for `verdict-qa.json` —
  agents *reliably* drop or mistype boilerplate-version fields on JSON
  artifacts. ENG-203 closed it for qa; ENG-206 closes the same surface for
  the review-findings-ledger." The fix removes the slip surface entirely: the
  agent no longer types `ledger_schema_version` at all; the orchestrator
  declares it ONCE in the per-file seed-header.
- **Brainstorm framing:** matches one-for-one. Header-line envelope
  mechanism (D-001), static-only header content (D-002), lenient per-row
  check (D-003), in-place migration in `_ensure_review_ledger` (D-004),
  validator line-3 byte-check + lenient per-row (D-005), §5 prompt edits
  drop the field and pin the new anchor (D-006), no helper reuse for the
  JSONL shape (D-007), no backward-compat shim — one-shot migration at
  first post-deploy dispatch (D-008), three test files extended (D-009).
  No reframing of the problem.
- **Proportionality:** ~30-line `_ensure_review_ledger` extension in
  `bin/run-stage.sh`, ~20-line validator change in
  `bin/review-ledger-schema.sh`, ~6-line §5 prompt edit in
  `AGENT_PROMPTS.md`, ~80 lines of new orchestration tests, ~100 lines of
  new validator unit tests, ~40 lines of new prompt-content pins, ~10 lines
  added to `docs/runbooks/recovery.md` §12, ~18 lines added to
  `docs/runbooks/review-findings-ledger.md`. NO new helper, NO new resolver
  tokens, NO new exit codes. Two subsystems (orchestrator primary,
  agent-prompts subordinate). Autonomy-safe per the ticket's stated sizing.
  Proportional. Proceed.

## Goal

Stop the review agent from ever typing `ledger_schema_version`: the
orchestrator's `_ensure_review_ledger` seeds a 3-line header
(`# review-findings-ledger …`, `# See docs/runbooks/…`, `# ledger_schema_version: 1`)
on every reviewing dispatch (migrating pre-ENG-206 2-line files in place);
the agent appends content-only rows beneath line 3 via `Edit`; the validator
byte-checks all three header lines and relaxes the per-row
`ledger_schema_version` check to lenient (accept absent OR equal to 1); and
the ENG-190 rc=49 "seed-header / schema-version missing" failure mode can no
longer originate from agent omission.

## Assumption Inventory

**branch-base freshness:** `git log --oneline HEAD..origin/main` at plan
time is NON-EMPTY:

    c4ae1e4 Merge pull request #182 from StupiDeity/fix/eng-152-verdict-author-orchestrator
    39983a1 feat(ENG-152): flip AGENT_PROMPTS to stage-completion-claim + §0 protocol rewrite
    bff6346 feat(ENG-152): stamp all orchestrator verdict writers + envelope detective + republish helper
    171b610 feat(ENG-152): verdict-handler strict-author filter + D-007 legacy fallback
    05c41a9 feat(ENG-152): registry + emit — verdict_authors, orchestrator-lane verdict w/ author auto-stamp, stage-completion-claim event, vocab regen
    2fa7605 chore(ENG-152): implementation plan for fresh verdict-author split

`origin/main` at plan time = `c4ae1e4`. The upstream ENG-152 changes touch
`AGENT_PROMPTS.md` (128 lines), `bin/agent-prompts-content-test.sh` (51
lines), `bin/run-stage.sh` (82 lines), `bin/run-stage-test.sh` (147 lines),
`bin/pipeline-events.json` (51 lines) — all overlap with this plan's File
Structure. The ENG-152 work is the `stage-completion-claim` event + verdict
author stamping; it does NOT rewrite `_ensure_review_ledger`, the
`review_ledger_path` resolver chain, the §5 ledger Output bullet body, or
the validator's `SEED_LINE_*` constants. Drift is mechanical and survives
content-anchored edits. Still: **Task 0 (Rebase onto origin/main) is
MANDATORY before any other implement work**; every `path:line` excerpt
below MUST be re-verified by content anchor after the rebase. Tasks use
CONTENT anchors only (function names, distinctive literals, comment
markers); line numbers are informational hints.

### Verified — code paths quoted from current tree

- `[verified]` `bin/review-ledger-schema.sh:97-99` — declares
  `SEED_LINE_1='# review-findings-ledger — per-issue cumulative ledger; append one JSON object per line.'`
  and `SEED_LINE_2='# See docs/runbooks/review-findings-ledger.md. Never truncate; never cleared on dispatch.'`
  as shell constants. Content anchor: the literal `SEED_LINE_1=`.
- `[verified]` `bin/review-ledger-schema.sh:181-188` — seed-header integrity
  block. Currently byte-checks lines 1 and 2; emits
  `review-ledger-incomplete: seed-header tampered or missing` on mismatch
  and returns 49. Content anchor: the literal
  `Seed-header integrity (run BEFORE per-line loop)` comment + the
  `hdr_line_1=` / `hdr_line_2=` reads.
- `[verified]` `bin/review-ledger-schema.sh:219-225` — per-row strict check
  `jq -e '.ledger_schema_version == 1'`; on fail emits
  `ledger_schema_version must be 1, got: $ver_val` via `_emit_incomplete`
  and returns 49. Content anchor: the literal
  `jq -e '.ledger_schema_version == 1'`.
- `[verified]` `bin/review-ledger-schema.sh:115-121` — `sanitise_for_diag`
  strips `\n` / `\r` and rewrites `<!--` to `<\!--`. Used at all
  diagnostic interpolation sites; new line-3 diagnostic MUST also flow
  through it (security defense; brainstorm D-005 Iter-1 P1). Content
  anchor: `sanitise_for_diag() {`.
- `[verified]` `bin/review-ledger-schema.sh:473-480` — unknown-field
  warning loop's `keys - [<known-list>]`; `ledger_schema_version` is the
  first known-field. The lenient check must NOT remove the field from
  this list (legacy rows still emit it). Content anchor: the literal
  `"ledger_schema_version","issue_id","dispatch_id"`.
- `[verified]` `bin/review-ledger-schema.sh:483-486` — `saw_row == 0`
  returns rc=0 valid (first-reviewing-dispatch shape with header only).
  Unchanged. Content anchor: `if (( saw_row == 0 )); then`.
- `[verified]` `bin/run-stage.sh:1024-1037` — `_ensure_review_ledger`.
  Today: short-circuit `[[ -f "$lgr" ]] && return 0` (idempotent on
  existence); on absence emits the 2-line `# review-findings-ledger …` +
  `# See docs/runbooks/…` header to `$lgr`. Content anchor:
  `_ensure_review_ledger() {`.
- `[verified]` `bin/run-stage.sh:2385` — call site, gated on
  `stage == "reviewing"`; runs BEFORE `_clear_current_stage_slots` and
  BEFORE `allocate_dispatch_id` (line ~2397). The seed function does NOT
  have `PIPELINE_DISPATCH_ID` available at this point — consistent with
  D-002a's static-only header. Content anchor:
  `[[ "$stage" == "reviewing" ]] && _ensure_review_ledger "$ident"`.
- `[verified]` `bin/run-stage.sh:947` — comment block documents
  "review-findings-ledger.jsonl (per-issue append-only ledger; opposite
  lifecycle from verdict-review.json; see docs/runbooks/review-findings-ledger.md — ENG-190)";
  the ledger is NOT in `_clear_current_stage_slots`' rm list. Migration
  must preserve this (no clear). Content anchor: the literal
  `review-findings-ledger.jsonl (per-issue append-only ledger`.
- `[verified]` `bin/run-stage.sh:1442-1461` — `_validate_review_ledger`
  shells out to `review-ledger-schema.sh validate`, mapping rc 48/49/50
  to halt-comments via `_post_review_ledger_halt`. **Unchanged** by
  this plan. Content anchor: `_validate_review_ledger() {`.
- `[verified]` `bin/run-stage.sh:1468-1476` — `_post_review_ledger_halt`
  interpolates the validator stdout into the halt-comment body via `%s`
  with the `<!--` → `<\!--` rewrite; accepts the new diagnostic shapes
  unchanged. Content anchor: `_post_review_ledger_halt() {`.
- `[verified]` `bin/common.sh:801-803` — `failure_outcome_for_exit` maps
  48/49/50 to `review-ledger-malformed/incomplete/missing`. No new code
  needed. Content anchor: `48) printf 'review-ledger-malformed'`.
- `[verified]` `bin/pipeline-events.json:31` — `review-ledger-invalid` is
  in the `halt_reasons` array. No new event token needed. Content anchor:
  the literal `"review-ledger-invalid"`.
- `[verified]` `bin/render-prompt.sh:58, 286, 673` — `review_ledger_path`
  resolver chain (`PROMPT_RESOLVERS[review_ledger_path]=_resolve_review_ledger_path`;
  `_resolve_review_ledger_path() { printf '%s' "${_RENDER_REVIEW_LEDGER_PATH-}"; }`;
  `_RENDER_REVIEW_LEDGER_PATH="$(issue_dir "$issue_id")/review-findings-ledger.jsonl"`).
  No new resolver per D-007. Content anchor:
  `review_ledger_path=_resolve_review_ledger_path`.
- `[verified]` `AGENT_PROMPTS.md` §5 Output bullet (the literal
  `Append one row per finding to \`{review_ledger_path}\` via \`Edit\` with the seed-header line as the anchor`)
  is the row instructions bullet. The same enumeration includes
  `ledger_schema_version: 1` in the required-fields list (literal
  `\`ledger_schema_version: 1\`, \`issue_id: "{issue_id}"\``). Both
  literals are this plan's primary §5 edit targets. Path-D's
  loop-mirror in §5's path-D block (literal
  `Append one row per finding to \`{review_ledger_path}\` via \`Edit\` with the seed-header line as the anchor.`)
  also needs to be re-pinned to the new line-3 anchor. Content anchor:
  the literal `Append one row per finding to \`{review_ledger_path}\``.
- `[verified]` `AGENT_PROMPTS.md` §5 Findings-ledger paragraph (literal
  `Filter lines starting with \`#\` (file header)`) documents the
  agent's read-side filter — the new line 3 is automatically filtered
  out by the agent's reader, no agent-side read code change needed.
  Content anchor: the literal `Filter lines starting with \`#\``.
- `[verified]` `bin/agent-prompts-content-test.sh:75, 916` — both extract
  §5 body via `section_body "## 5. Review Agent"`; the latter block at
  ~915-1108 is where the existing ENG-190 pins (`ENG-190-pin-ledger-output-bullet`,
  `ENG-190-pin-summary-line`, `ENG-190-pin-critical-floor`, etc.) live.
  New AP-1..AP-4 pins MUST land next to these (cohesive block). Content
  anchor: the literal `ENG-190-pin-ledger-output-bullet` comment.
- `[verified]` `bin/run-stage-test.sh:7796-7827` — existing Y2 test for
  `_ensure_review_ledger`'s 2-line seed + idempotency. New OS-1..OS-4
  tests REPLACE the Y2 contract (which still asserts a 2-line header;
  post-ENG-206 it must assert a 3-line header). Content anchor: the
  literal `_ensure_review_ledger seeds exactly two #-prefix header lines`
  (will be flipped to "three" in this plan's Task 4).
- `[verified]` `bin/review-ledger-schema-test.sh:30-37` — the test's
  local `SEED_LINE_1` / `SEED_LINE_2` constants and `write_seed_header`
  helper. Post-ENG-206 the helper must also write `SEED_LINE_3` so
  existing T1-T12 fixtures stay valid. Content anchor: the literal
  `write_seed_header() {`.
- `[verified]` `bin/review-ledger-schema-test.sh:214-226` — T10
  (seed-header tampered → exit 49) currently writes a 2-line tampered
  header. Post-ENG-206 this remains valid (a 2-line file still fails the
  3-line byte check). New V-6/V-7 add the line-3-specific defects.
  Content anchor: the literal `T10: seed-header tampered`.
- `[verified]` `bin/common.sh:713-742` — `merge_artifact_envelope` is
  intentionally object-merge only. Confirms D-007: not reused here. The
  JSONL adaptation is "header-line envelope + content-only rows," a
  structurally different pattern.

### Assumed/new (will validate during implementation)

- `[assumed]` jq's `.field | type` returns the string `"null"` when the
  field is explicitly null, and `null` (treated as `"missing"` by the
  shell `2>/dev/null || printf 'missing'` fallback) when the field is
  truly absent. The lenient check defensively handles both via
  `type != "null" && type != "missing"`. If jq's behaviour diverges,
  the lenient predicate needs a minor tweak — no design pivot. The
  fixture write at V-1 will exercise the absent-field path and confirm.

## System invariants

- **3-line seed-header is byte-identical across the orchestrator's writer
  and the validator's reader.** Editing one constant without the other
  halts every subsequent reviewing dispatch with rc=49 (line-3 byte
  mismatch). `verified_by: task:T5` (the validator unit tests V-5/V-6/V-7
  pin the byte-equality across both call sites; passes only when both
  writers and reader use the identical literal).
- **Migration is idempotent on already-migrated files.** Post-migration
  re-entry of `_ensure_review_ledger` MUST be a no-op (no rewrite, no
  mtime touch, no log on the no-op path beyond the existing `log` for
  fresh seed). `verified_by: task:T4` (orchestration test OS-3 hashes the
  file before and after a second call and asserts equality).
- **Migration preserves prior rows byte-equal.** A pre-ENG-206 ledger
  with N rows (lines 3+) MUST emerge with the same N rows at lines 4+
  after migration — no row content changed, no rows dropped, no rows
  added except the new line 3. `verified_by: task:T4` (orchestration test
  OS-2 writes 2 fixture rows pre-migration, asserts they're byte-equal
  at lines 4-5 post-migration).
- **Validator is lenient on per-row `ledger_schema_version`.** A row
  with the field ABSENT passes; a row with the field set to integer `1`
  passes; a row with the field set to anything else (`2`, `"v1"`, `1.0`,
  `null`) halts rc=49. `verified_by: task:T5` (validator V-1, V-2, V-3,
  V-4 cover the four cases).
- **Ledger lifecycle stays opposite to verdict-review.json.** Migration
  must not introduce a clear-on-dispatch-start path; `_clear_current_stage_slots`
  reviewing-branch keeps the ledger out of its rm list. `verified_by:
  bin/run-stage-test.sh:Y1 (AC-2): two-dispatch fixture — ledger persists` (existing test pins the no-clear contract; the migration's atomic-mv only
  rewrites the header bytes — does not delete the file).
- **Prompt-side anchor literal byte-matches `SEED_LINE_3`.** The §5 anchor
  reference (`# ledger_schema_version: 1`) MUST be the byte-identical
  string the orchestrator writes and the validator reads. `verified_by:
  task:T7` (new prompt-content pin AP-3 asserts the literal appears in
  §5 as the anchor reference).

## File Structure

| Path | Change |
|---|---|
| `bin/run-stage.sh` | **Modified.** Extend `_ensure_review_ledger` from a 10-line absence-only seed into a 30-line three-case dispatch: (1) file missing → write 3-line header; (2) file exists & line 3 == `SEED_LINE_3` → no-op; (3) file exists & line 3 ≠ `SEED_LINE_3` → migrate in-place (atomic mktemp + write 3 header lines + `tail -n +N` of old file + atomic mv). Caller at line ~2385 unchanged. |
| `bin/review-ledger-schema.sh` | **Modified.** Add `SEED_LINE_3` constant beside `SEED_LINE_1`/`SEED_LINE_2`. Extend seed-header integrity check to byte-check line 3 (with diagnostic distinguishing absent vs drifted). Replace per-row strict `jq -e '.ledger_schema_version == 1'` with lenient form (pass when absent; halt rc=49 with `must be 1 when present` when present-but-wrong). |
| `AGENT_PROMPTS.md` | **Modified.** §5 Output bullet (the "Append one row per finding to `{review_ledger_path}`" enumeration): (a) remove `ledger_schema_version: 1` from the required-fields list; (b) re-pin the Edit anchor to the literal `# ledger_schema_version: 1` (line 3 of the orchestrator-seeded header); (c) add an explanatory sentence: "The orchestrator seeds the ledger header (including the `ledger_schema_version: 1` envelope line) at every reviewing dispatch start; do not author the seed-header or `ledger_schema_version` yourself." |
| `bin/run-stage-test.sh` | **Modified.** Update the existing Y2 contract (flips "two #-prefix lines" → "three"). Add OS-1 (fresh-file seed → 3 header lines), OS-2 (migration: pre-ENG-206 ledger w/ 2-line header + 2 rows → 3-line header + same 2 rows byte-equal), OS-3 (idempotent re-entry: cksum unchanged), OS-4 (ENG-190 regression: row omitting `ledger_schema_version` validates clean). |
| `bin/review-ledger-schema-test.sh` | **Modified.** Update `write_seed_header` to emit 3 lines. Add `SEED_LINE_3` constant. Add V-1 (lenient: field absent → pass), V-2 (lenient: field=1 → pass), V-3 (lenient: field=2 → rc=49), V-4 (lenient: field="v1" → rc=49), V-5 (canonical 3-line header → pass), V-6 (line 3 absent → rc=49 with `<absent>` diagnostic), V-7 (line 3 drifted → rc=49 with sanitised value in diagnostic). |
| `bin/agent-prompts-content-test.sh` | **Modified.** Add AP-1 (§5 required-fields list does NOT contain `ledger_schema_version: 1`), AP-2 (§5 contains the orchestrator-ownership sentence), AP-3 (§5 anchor uses the literal `# ledger_schema_version: 1`), AP-4 (the anchor literal appears in §5 exactly once). |
| `docs/runbooks/review-findings-ledger.md` | **Modified.** Add a paragraph under the schema description: lines 1-3 are orchestrator-owned; `ledger_schema_version` is a per-file constant declared in line 3; per-row emission is no longer required but is accepted lenient when present; per-row `ledger_schema_version: 1` on legacy rows is benign — header is the source of truth. |
| `docs/runbooks/recovery.md` | **Modified.** §12 gains a brief note: new line-3 byte-check failure mode distinguishes "line-3 absent (pre-ENG-206 unmigrated; `--action continue` resolves; ≤ K=`max_concurrent_features` issues affected at cutover)" vs "line-3 present but drifted (human or agent edit; inspect before resuming)" — so the first post-cutover halt isn't filed as a regression. |
| `bin/common.sh` | **No change.** `merge_artifact_envelope` is intentionally not reused (D-007 — JSONL append shape ≠ JSON-object merge). |
| `bin/render-prompt.sh` | **No change.** No new resolver tokens (D-007). Existing `{review_ledger_path}` suffices. |
| `bin/pipeline-events.json` | **No change.** `review-ledger-invalid` already in `halt_reasons`. |
| `bin/verdict-handler.sh` | **No change.** |
| `bin/dispatch.sh` | **No change.** Agent's `Edit` access to the ledger path unchanged; no new allowlist entries. |
| `learned-rules/harness/project-profile.md` | **No change.** No new gate-runnable test files added — all test changes are extensions to existing `bin/*-test.sh` files which the pre-commit hook's glob already covers. |

## API Contract

No new API surface. ENG-206 is an orchestrator/agent-contract change on an
on-disk artifact (`review-findings-ledger.jsonl`); there is no FE↔BE handler
boundary. The artifact's schema (`bin/review-ledger-schema.sh`'s header
comment) is the closest analog; its narrow modification is documented in
File Structure + Backend Tasks.

## Backend Tasks

### Task 0: Rebase onto origin/main

- `depends_on: []`
- `touches: (no production files — branch state only)`
- [ ] Run `git fetch origin main && git rebase origin/main` from the
  worktree root. Expected: clean rebase (the upstream ENG-152 commits
  touch `AGENT_PROMPTS.md`, `bin/run-stage.sh`, `bin/run-stage-test.sh`,
  `bin/agent-prompts-content-test.sh`, `bin/pipeline-events.json`, but
  their edit boundaries (verdict-author stamping; stage-completion-claim
  protocol) do NOT overlap with this plan's regions (`_ensure_review_ledger`,
  §5 ledger Output bullet, ENG-190 pins). Mechanical drift only.
- [ ] If a conflict arises, STOP and post a Linear comment requesting
  guidance (do NOT auto-resolve). Restart this plan's implement against the
  rebased base.
- [ ] After rebase, re-verify every `path:line` excerpt in Assumption
  Inventory against the rebased tree using the named content anchors
  (function names, distinctive literals, comment markers). Line numbers
  may shift; content anchors must still match. If any content anchor is
  gone, STOP and re-plan.

### Task 1: Add `SEED_LINE_3` constant + extend seed-header integrity check to byte-check line 3 (`bin/review-ledger-schema.sh`)

- `depends_on: [0]`
- `touches: bin/review-ledger-schema.sh (SEED_LINE_3 constant; cmd_validate seed-header block)`
- [ ] In `bin/review-ledger-schema.sh`, BELOW the existing `SEED_LINE_2`
  declaration (content anchor: the literal `SEED_LINE_2='# See docs/runbooks/`)
  ABOVE the `# Severity ladder.` comment (content anchor:
  `# Severity ladder.`), add:

  ```bash
  # ENG-206: line 3 declares the per-file schema version envelope.
  # The orchestrator owns this line (bin/run-stage.sh::_ensure_review_ledger);
  # the agent never authors it. Per-row ledger_schema_version is no longer
  # required (lenient — see cmd_validate body).
  SEED_LINE_3='# ledger_schema_version: 1'
  ```

- [ ] In `cmd_validate`, between the `hdr_line_2="$(sed -n '2p' "$file" …)"`
  read and the existing 2-line byte-check `if` (content anchor: the literal
  `if [[ "$hdr_line_1" != "$SEED_LINE_1" || "$hdr_line_2" != "$SEED_LINE_2" ]]; then`),
  add a `hdr_line_3` read and extend the byte-check predicate to include
  line 3. Replace the existing diagnostic with a two-shape distinguishing
  emitter (security defense — interpolate `hdr_line_3` only via
  `sanitise_for_diag`):

  ```bash
  hdr_line_3="$(sed -n '3p' "$file" 2>/dev/null || true)"
  if [[ "$hdr_line_1" != "$SEED_LINE_1" || "$hdr_line_2" != "$SEED_LINE_2" || "$hdr_line_3" != "$SEED_LINE_3" ]]; then
    local hint
    if [[ -z "$hdr_line_3" ]]; then
      hint="line 3: <absent>; expected '$SEED_LINE_3'"
    else
      hint="line 3: '$(sanitise_for_diag "$hdr_line_3")'; expected '$SEED_LINE_3'"
    fi
    printf 'review-ledger-incomplete: seed-header tampered or missing (%s)\n' "$hint"
    return 49
  fi
  ```

  **NOTE:** when both lines 1 & 2 are correct and only line 3 is wrong, the
  hint above accurately localises the defect. When lines 1 or 2 are also
  wrong, the hint still reports line 3's content — that's acceptable; the
  same operator triage path applies (inspect the file).

### Task 2: Relax per-row `ledger_schema_version` strict check to lenient (`bin/review-ledger-schema.sh`)

- `depends_on: [1]`
- `touches: bin/review-ledger-schema.sh (cmd_validate per-row check, content anchor: jq -e '.ledger_schema_version == 1')`
- [ ] Locate the per-row strict check (content anchor: the literal
  `jq -e '.ledger_schema_version == 1'` inside the per-row `while IFS=`
  loop, between the `fck="$(jq -r '.finding_class_key …)"` extraction and
  the `# issue_id matches ^ENG-[0-9]+$ AND equals --ident when provided.`
  comment).
- [ ] Replace the entire strict-check block (the
  `if ! jq -e '.ledger_schema_version == 1' …; then … return 49; fi`)
  with the lenient form:

  ```bash
  # ENG-206 lenient check: orchestrator declares ledger_schema_version in
  # the seed-header (line 3). Per-row presence is optional (D-001); when
  # present, value MUST equal 1 (defense-in-depth against agent regression).
  local lsv_type
  lsv_type="$(jq -r '.ledger_schema_version | type' <<<"$line" 2>/dev/null || printf 'missing')"
  if [[ "$lsv_type" != "null" && "$lsv_type" != "missing" ]]; then
    if ! jq -e '.ledger_schema_version == 1' <<<"$line" >/dev/null 2>&1; then
      local ver_val
      ver_val="$(jq -r '.ledger_schema_version' <<<"$line" 2>/dev/null || printf 'MISSING')"
      _emit_incomplete "$line_no" "ledger_schema_version must be 1 when present, got: $ver_val" "$fck"
      return 49
    fi
  fi
  # Else: field absent — accept; envelope-from-header (D-001).
  ```

- [ ] Do NOT touch the unknown-fields warning loop at
  `bin/review-ledger-schema.sh:473-480` — `ledger_schema_version` MUST
  remain in the known-fields array because legacy rows still emit it
  (otherwise the unknown-field warning would fire spuriously).

### Task 3: Extend `_ensure_review_ledger` into a three-case dispatch with in-place migration (`bin/run-stage.sh`)

- `depends_on: [0]`
- `touches: bin/run-stage.sh (_ensure_review_ledger body, content anchor: _ensure_review_ledger() {)`
- [ ] Locate `_ensure_review_ledger` (content anchor:
  `_ensure_review_ledger() {`) and replace its body in full with the
  three-case dispatch (mirrors the brainstorm's D-004 body):

  ```bash
  _ensure_review_ledger() {
    local ident="$1"
    local lgr; lgr="$(issue_dir "$ident")/review-findings-ledger.jsonl"
    local SEED_LINE_1='# review-findings-ledger — per-issue cumulative ledger; append one JSON object per line.'
    local SEED_LINE_2='# See docs/runbooks/review-findings-ledger.md. Never truncate; never cleared on dispatch.'
    local SEED_LINE_3='# ledger_schema_version: 1'

    # Case 1: file missing — fresh seed.
    if [[ ! -f "$lgr" ]]; then
      if [[ "${PIPELINE_DRY_RUN:-0}" == "1" ]]; then
        log "_ensure_review_ledger: dry-run — would seed $lgr"
        return 0
      fi
      {
        printf '%s\n' "$SEED_LINE_1"
        printf '%s\n' "$SEED_LINE_2"
        printf '%s\n' "$SEED_LINE_3"
      } > "$lgr"
      log "_ensure_review_ledger: seeded $lgr (3-line header)"
      return 0
    fi

    # OQ-2 defense: reject symlinked ledger (mirrors ENG-203 D-007 symlink guard).
    [[ -L "$lgr" ]] && die "_ensure_review_ledger: ledger is a symlink: $lgr"

    # Case 2: file exists, already migrated — no-op.
    local third_line; third_line="$(sed -n '3p' "$lgr" 2>/dev/null || true)"
    if [[ "$third_line" == "$SEED_LINE_3" ]]; then
      return 0
    fi

    # Case 3: file exists, pre-ENG-206 or operator-corrupted line 3 — migrate.
    # tail_from selection rule (Product P1#1):
    #   - line 3 is a JSON row (does NOT start with `#`) → keep it: tail -n +3.
    #   - line 3 is a `#`-comment that isn't SEED_LINE_3 → CONSUME it: tail -n +4
    #     (otherwise the corrupt comment is preserved as a "row" and the
    #     validator halts on every subsequent dispatch).
    local tail_from=3
    if [[ "${third_line:0:1}" == "#" ]]; then
      tail_from=4
    fi
    if [[ "${PIPELINE_DRY_RUN:-0}" == "1" ]]; then
      log "_ensure_review_ledger: dry-run — would migrate header for $lgr (tail_from=$tail_from)"
      return 0
    fi
    local tmp
    tmp="$(mktemp "${lgr}.tmp.XXXXXX")" \
      || die "_ensure_review_ledger: mktemp failed for $lgr"
    {
      printf '%s\n' "$SEED_LINE_1"
      printf '%s\n' "$SEED_LINE_2"
      printf '%s\n' "$SEED_LINE_3"
      tail -n "+$tail_from" "$lgr"
    } > "$tmp" || { rm -f "$tmp"; die "_ensure_review_ledger: write failed for $lgr"; }
    mv "$tmp" "$lgr" \
      || { rm -f "$tmp"; die "_ensure_review_ledger: atomic mv failed for $lgr"; }
    log "_ensure_review_ledger: migrated $lgr to 3-line header (tail_from=$tail_from)"
  }
  ```

- [ ] Update BOTH adjacent "two-line" comments to "three-line": (a) the
  `# bin/review-ledger-schema.sh::cmd_validate before per-row validation —`
  comment block IMMEDIATELY ABOVE `_ensure_review_ledger` (content anchor:
  `editing this header text without updating SEED_LINE_{1,2}`) — change to
  `SEED_LINE_{1,2,3}`; (b) the call-site comment AT `bin/run-stage.sh:2381`
  (content anchor: `the canonical two-line \`#\`-prefix header`) — change
  "two-line" → "three-line". Both comments preserve the operator-grep recipe
  for the seed-header.
- [ ] **Atomic-commit discipline (commit-ordering hazard).** Task 3's
  production edit MUST land in the SAME git commit as Task 4's Y2-flip
  test edit. Reason: Y2 currently asserts the OLD 2-line shape; landing
  Task 3 alone would turn the pre-commit gate red on main, blocking every
  agent commit per the `pre-commit-gate-red-blocks-agents` memory class.
  Stage both files together (`git add bin/run-stage.sh bin/run-stage-test.sh`)
  in the commit that ships Task 3.

### Task 4: Update orchestration tests (`bin/run-stage-test.sh`)

- `depends_on: [3]`
- `touches: bin/run-stage-test.sh (Y2 test contract; new OS-1..OS-4 cases adjacent to Y1)`
- [ ] **Flip Y2's line count to 3.** Locate the existing Y2 block (content
  anchor: the literal
  `_ensure_review_ledger seeds exactly two #-prefix header lines`).
  Update the assertion: `_eng190_y2_line_count == 3`, also add a `line3`
  check against `_eng190_seed_line_3` (define the constant at the top of
  the Y-block helpers next to the existing `_eng190_seed_line_1` /
  `_eng190_seed_line_2`). The idempotency cksum check below is unchanged.
  Rename the pass message to "seeds exactly three #-prefix header lines"
  for accuracy.
- [ ] AFTER the existing Y3-variant block's closing `fi` (content anchor:
  the literal `ENG-190 Y3-variant (AC-3): stabilise count`) BEFORE the
  Y4 block's opening (content anchor: `ENG-190 Y4: missing-ledger halt`),
  insert a new `# ─── ENG-206 OS-1..OS-4 ───` section with:
  - **OS-1.** Fresh-file seed: `mkdir -p` issue dir, ensure ledger
    absent, call `_ensure_review_ledger ENG-206OS1`, assert file has
    exactly 3 lines matching `SEED_LINE_*` and no other content.
  - **OS-2.** Migration: pre-create a ledger with the OLD 2-line header
    + two `_eng190_write_row`-emitted rows. Call `_ensure_review_ledger
    ENG-206OS2`. Assert: file has 3 header lines + the original 2 rows
    byte-equal at lines 4-5 (use `sed -n '4p'` / `sed -n '5p'` against
    saved copies). Pins D-004.
  - **OS-3.** Idempotent re-entry: pre-create a ledger with the NEW
    3-line header + N rows. Call `_ensure_review_ledger ENG-206OS3` twice.
    Cksum the file after each call; assert equality. Pins D-004's no-op
    short-circuit.
  - **OS-4.** ENG-190 omission regression: create a 3-header-line ledger,
    append one row that OMITS `ledger_schema_version` (use `jq -cn` with
    all other required fields), invoke `_validate_review_ledger
    ENG-206OS4` (the orchestrator-side wrapper at
    `bin/run-stage.sh:1442`), assert rc=0. **Pins AC#3** — the
    rc=49 seed-header/version defect cannot originate from agent omission.

### Task 5: Update validator unit tests (`bin/review-ledger-schema-test.sh`)

- `depends_on: [1, 2]`
- `touches: bin/review-ledger-schema-test.sh (write_seed_header helper; new V-1..V-7 cases at end of file)`
- [ ] Update the test's local `SEED_LINE_2='…'` declaration (content
  anchor: `SEED_LINE_2='# See docs/runbooks/`); add a sibling line below:
  `SEED_LINE_3='# ledger_schema_version: 1'`.
- [ ] Update `write_seed_header` (content anchor: `write_seed_header() {`)
  to emit three lines: `printf '%s\n%s\n%s\n' "$SEED_LINE_1" "$SEED_LINE_2" "$SEED_LINE_3" > "$file"`.
  This makes ALL existing T1-T12 fixtures correctly produce a 3-line
  header without modification; T10 (tampered header) still independently
  writes a 2-line tampered file, which the post-ENG-206 validator now
  rejects on line-3 grounds (still rc=49, still passes).
- [ ] AFTER the existing T-191-2 block (content anchor:
  `T-191-2: schema-grace`) BEFORE the final
  `printf '\nreview-ledger-schema-test: passed=%d failed=%d\n'` summary
  line, insert a `--- ENG-206 V-1..V-7 ---` section with:
  - **V-1.** Seed a 3-line header. Append one row that OMITS
    `ledger_schema_version` (use `jq -cn` with all other required fields).
    Invoke validator. Assert rc=0. (Lenient: absent → pass.)
  - **V-2.** Seed a 3-line header. Append a row WITH
    `ledger_schema_version: 1`. Invoke validator. Assert rc=0. (Lenient:
    field=1 → pass; back-compat for pre-ENG-206 legacy rows.)
  - **V-3.** Seed 3-line header + row with `ledger_schema_version: 2`.
    Assert rc=49 and stdout contains the literal `must be 1 when present`.
  - **V-4.** Seed 3-line header + row with `ledger_schema_version: "v1"`
    (string). Assert rc=49 and stdout contains `must be 1 when present`.
  - **V-5.** Seed canonical 3-line header + one well-formed row. Assert
    rc=0. (Sanity baseline — exercises the new line-3 byte-check
    pass path against the canonical header.)
  - **V-6.** Write ONLY a 2-line header (`SEED_LINE_1` + `SEED_LINE_2`,
    no line 3). Append one valid row. Invoke validator. Assert rc=49
    and stdout contains the literal `line 3: <absent>` and the literal
    `expected '# ledger_schema_version: 1'`. (Pins the cutover edge
    case from D-008.)
  - **V-7.** Write the 2 prose lines + a drifted line 3 (e.g.
    `# ledger_schema_version: 2`). Append one valid row. Invoke
    validator. Assert rc=49 and stdout contains the literal
    `line 3: '# ledger_schema_version: 2'`. (Pins the
    "operator/agent edited the seed-header" path.)
- [ ] Sanity: re-run T1-T12 after the `write_seed_header` flip; they must
  still all pass (their rows now sit at line 4+ inside a 3-line header).

### Task 6: Update §5 prompt — drop `ledger_schema_version: 1` from required-fields list; pin line-3 anchor; add orchestrator-ownership sentence (`AGENT_PROMPTS.md`)

- `depends_on: [0]`
- `touches: AGENT_PROMPTS.md (§5 Output bullet + path-D loop-mirror)`
- [ ] Locate the §5 Output bullet (content anchor: the literal
  `Append one row per finding to \`{review_ledger_path}\`** via \`Edit\` with`).
  In the required-fields enumeration that follows
  (content anchor: the literal `ledger_schema_version: 1\`, \`issue_id:`),
  **delete** `\`ledger_schema_version: 1\`,` (and the trailing space) —
  leave the remaining fields unchanged.
- [ ] In the same Output bullet, replace the Edit-anchor phrase. Current
  literal (content anchor): `via \`Edit\` with the seed-header line as the anchor`.
  Replace with: `via \`Edit\` with \`# ledger_schema_version: 1\` (line 3 of the orchestrator-seeded header) as the anchor`.
- [ ] Also locate the path-D loop-mirror at ~`AGENT_PROMPTS.md:1751-1752`
  (content anchor: the literal
  `Append one row per finding to \`{review_ledger_path}\` via \`Edit\``
  inside the path-D block). Apply the SAME anchor replacement.
- [ ] AFTER the required-fields enumeration (the rationale `≤280 char
  soft cap.` clause; content anchor: `\`rationale\` (≤280 char soft cap)`)
  BEFORE the **On every row whose `adjudicated_severity ∈ {major, critical}`**
  clause, insert a new sentence: `The orchestrator seeds the ledger header
  (including the \`ledger_schema_version: 1\` envelope line) at every
  reviewing dispatch start; do not author the seed-header or
  \`ledger_schema_version\` yourself.`
- [ ] Verify the file still has exactly two ``` fences in §5 (the
  `bin/render-prompt.sh` fence-count contract — column-0 fences must
  remain exactly two per stage). Run `bash bin/render-prompt.sh review`
  as a smoke check; it must exit 0.
- [ ] Verify the literal `# ledger_schema_version: 1` appears in §5
  EXACTLY ONCE — used as the anchor reference; AP-4 pins this. If two
  near-matches exist (e.g. inside a separate prose paragraph), prune so
  only the anchor reference remains; otherwise an LLM may pick the wrong
  match for the `Edit` `old_string`.

### Task 7: Update prompt-content tests (`bin/agent-prompts-content-test.sh`)

- `depends_on: [6]`
- `touches: bin/agent-prompts-content-test.sh (new AP-1..AP-4 pins adjacent to ENG-190-pin-ledger-output-bullet)`
- [ ] Locate the `ENG-190-pin-ledger-output-bullet` block (content anchor:
  the literal `ENG-190-pin-ledger-output-bullet`). Update the test name to
  preserve continuity (the `grep -qF 'Append one row per finding to`
  + `NEVER use the \`Write\` tool` checks both still hold post-ENG-206
  and don't need a change).
- [ ] IMMEDIATELY AFTER that block's closing `fi` BEFORE the
  `ENG-190-pin-summary-line` block (content anchor: the literal
  `ENG-190-pin-summary-line`), insert four new pin blocks:
  - **AP-1** (`ENG-206-pin-no-ledger-schema-version-in-required-fields`):
    assert `! grep -qE 'ledger_schema_version: 1\`,' <<<"$s5"` — the
    required-fields enumeration MUST NOT contain the literal
    `ledger_schema_version: 1\`,`. Negative pin; satisfies AC#1.
  - **AP-2** (`ENG-206-pin-orchestrator-ownership-sentence`): assert
    `grep -qF 'orchestrator seeds the ledger header'` against `$s5`.
    Positive pin; documents the new contract for future agents.
  - **AP-3** (`ENG-206-pin-line3-anchor-reference`): assert
    that `$s5` contains the literal Edit-anchor phrase from Task 6 step
    2 — i.e., the §5 Output bullet pins line 3 as the `Edit` anchor.
    Use a double-quoted `grep -qF` arg to avoid the embedded
    single-quote/backtick mess:
    `grep -qF "# ledger_schema_version: 1\` (line 3 of the orchestrator-seeded header) as the anchor" <<<"$s5"` —
    NOTE the literal backtick after the `1` matches the §5 prompt's
    closing backtick on the inline-code `\`# ledger_schema_version: 1\``.
    Positive pin.
  - **AP-4** (`ENG-206-pin-anchor-literal-appears-once`): assert
    `[[ "$(printf '%s\n' "$s5" | grep -cF '# ledger_schema_version: 1')" == "1" ]]` — the literal `# ledger_schema_version: 1`
    appears in §5 EXACTLY once (otherwise an LLM picks the wrong
    `Edit` `old_string` and the `Edit` tool fails at runtime with a
    poorly-localised error). Cardinality pin.

### Task 8: Update operator runbooks (`docs/runbooks/review-findings-ledger.md`, `docs/runbooks/recovery.md`)

- `depends_on: [3]`
- `touches: docs/runbooks/review-findings-ledger.md, docs/runbooks/recovery.md`
- [ ] In `docs/runbooks/review-findings-ledger.md`, AFTER the existing
  schema description (content anchor: TBD — read the file at Task-time
  and find the schema overview paragraph) BEFORE any "Failure modes" or
  "Recovery" section, insert a paragraph: "Lines 1-3 are orchestrator-
  owned (`bin/run-stage.sh::_ensure_review_ledger` writes them on every
  reviewing dispatch). Line 1 is the prose introduction; line 2 is the
  cross-reference; line 3 declares the per-file schema version envelope
  (`# ledger_schema_version: 1`). The agent never authors any header
  line. Per-row `ledger_schema_version` is OPTIONAL (lenient validator
  check accepts absent OR equal to 1); legacy rows from pre-ENG-206
  dispatches that DO emit `ledger_schema_version: 1` per row are benign
  — the header is the source of truth."
- [ ] In `docs/runbooks/recovery.md` §12 (content anchor: the literal
  `## 12.` or similar §12 heading — read the file at Task-time), append
  a sub-bullet: "**ENG-206 cutover edge case.** On the first reviewing
  dispatch after the ENG-206 deploy, an in-flight dispatch that landed
  with the pre-ENG-206 prompt against an unmigrated ledger may halt with
  `review-ledger-incomplete: seed-header tampered or missing (line 3: <absent>; expected '# ledger_schema_version: 1')`. Up to
  `orchestrator.max_concurrent_features` (default 2) issues per project
  can be affected at deploy. **Recovery:** `bash bin/pipeline.sh decide
  <ENG-N> --action continue` — the next dispatch's
  `_ensure_review_ledger` migrates the header in place; subsequent
  validation passes. If the diagnostic instead names a present-but-drifted
  line 3 (e.g. `line 3: '# ledger_schema_version: 2'`), inspect the file
  BEFORE resuming: human or agent hand-edit may indicate prior triage in
  progress."

## Frontend Tasks

None. The harness has no UI surface; all artifacts are on-disk JSONL +
markdown + Linear comments.

## Failure Mode → Test Map

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
|---|---|---|---|---|
| Pre-ENG-206 ledger unmigrated reaches the validator | Cutover: in-flight reviewing dispatch lands on a 2-line-header ledger before next-tick migration ran | Validator halts rc=49 `review-ledger-incomplete: seed-header tampered or missing (line 3: <absent>; expected '# ledger_schema_version: 1')` | unit | `bin/review-ledger-schema-test.sh::V-6` |
| Agent edits the seed-header (line 3) instead of using it as Edit anchor | Agent misreads anchor instructions; emits a row inside the header | Validator halts rc=49 with drifted line-3 diagnostic naming the sanitised actual value | unit | `bin/review-ledger-schema-test.sh::V-7` |
| Agent regresses and writes `ledger_schema_version: 2` per row | Agent ignores new prompt; emits wrong-typed envelope key | Lenient check catches present-but-not-1; halts rc=49 with `must be 1 when present` | unit | `bin/review-ledger-schema-test.sh::V-3` |
| Agent regresses and writes `ledger_schema_version: "v1"` per row | Agent's string-vs-int slip | Same as above; halts rc=49 | unit | `bin/review-ledger-schema-test.sh::V-4` |
| Agent omits `ledger_schema_version` per row per the new prompt | Happy path post-ENG-206 | Lenient check passes (envelope-from-header); validator returns rc=0 | integration | `bin/run-stage-test.sh::ENG-206 OS-4` |
| Fresh issue, first reviewing dispatch | No ledger exists | Orchestrator creates 3-line header file; validator passes (`saw_row == 0`) | integration | `bin/run-stage-test.sh::ENG-206 OS-1` |
| Pre-ENG-206 ledger with rows reaches `_ensure_review_ledger` | Cutover migration path | 3 header lines + original rows byte-equal at lines 4+ | integration | `bin/run-stage-test.sh::ENG-206 OS-2` |
| Post-ENG-206 ledger reaches `_ensure_review_ledger` again | Second reviewing dispatch on same issue | No-op short-circuit; cksum unchanged | integration | `bin/run-stage-test.sh::ENG-206 OS-3` |
| Operator hand-pastes corrupt comment as line 3 (e.g. whitespace, BOM) | `# x` or `# ledger_schema_version: 99` as line 3, then orchestrator re-enters | `tail_from=4` consumes the corrupt line; subsequent dispatches no-op | integration | (covered by OS-2 with a corrupt-line variant; if size dictates a separate case, OS-2a) |
| Symlinked ledger at the canonical path | Operator foot-gun: `ln -s …` at `review-findings-ledger.jsonl` | `_ensure_review_ledger` dies loud before any rewrite — `ledger is a symlink` | integration | (covered by OS-2 symlink variant or a sibling case; brainstorm OQ-2) |
| §5 Output bullet still mentions `ledger_schema_version: 1` in required-fields | Prompt edit was incomplete / future regression | Content test fails; gate halts | prompt-content | `bin/agent-prompts-content-test.sh::AP-1` |
| §5 anchor reference drifts from `# ledger_schema_version: 1` literal | Prompt edit drifted; agent's `Edit` `old_string` won't match | Content test fails; gate halts | prompt-content | `bin/agent-prompts-content-test.sh::AP-3` |
| §5 anchor literal appears more than once in §5 (ambiguous match) | Prose adds a stray mention | Content test fails; gate halts | prompt-content | `bin/agent-prompts-content-test.sh::AP-4` |

## Test Strategy

### Unit
- **`bin/review-ledger-schema-test.sh`** — V-1..V-7 cover the validator's
  new line-3 byte-check (V-5/V-6/V-7) and lenient per-row check
  (V-1/V-2/V-3/V-4). All seven cases lift the post-ENG-206 contract
  directly from the validator's diff. T1-T12 + T-191-* continue to pass
  unchanged because `write_seed_header` was widened to 3 lines (no
  fixture rewrites needed — the helper update propagates).

### Integration
- **`bin/run-stage-test.sh`** — OS-1..OS-4 exercise the orchestrator
  side of the contract end-to-end: fresh seed (OS-1), migration with row
  preservation (OS-2), idempotent re-entry (OS-3), and the AC#3
  regression pin (OS-4) — agent omits `ledger_schema_version` per row,
  the orchestrator-side `_validate_review_ledger` returns rc=0. The
  existing Y2 contract flips from 2-line to 3-line; Y3/Y3-variant/Y4
  carry through unchanged because they test orthogonal properties
  (Adjudicated count semantics; missing-ledger halt).
- **Test-gate closure (add-side check).** The plan creates NO new
  gate-runnable files — all test changes are extensions to existing
  `bin/*-test.sh` files. The harness's project-profile gate command is
  `bash .githooks/pre-commit`, which globs `bin/*-test.sh` and
  automatically covers the modified files. No `learned-rules/harness/project-profile.md`
  edit is required.
- **Test-gate closure (remove-side check).** This plan REMOVES the
  per-row strict check on `ledger_schema_version`. No sibling test file
  contains a pinning assertion that would START failing as a result —
  T8 (empty-after-header-strip → rc=0) is orthogonal; T10 (tampered
  header → rc=49) is orthogonal; the strict per-row check has NO
  positive-coverage pin in any existing test (it was inline in the
  validator only). The strict check's lenient replacement is itself
  pinned by V-1..V-4. No file-structure additions needed for closure.

### Smoke
- `bash -n bin/run-stage.sh` (post-edit syntax check; covered in
  pass_criteria).
- `bash -n bin/review-ledger-schema.sh` (post-edit syntax check;
  covered in pass_criteria).
- `bash bin/agent-prompts-content-test.sh` (passes only when all
  AP-1..AP-4 pins assert true AND existing ENG-190 pins still hold).
- `bash bin/review-ledger-schema-test.sh` (passes only when V-1..V-7
  added AND T1-T12 + T-191-* survive `write_seed_header`'s widening).
- `bash bin/run-stage-test.sh` (large file; passes only when Y2
  contract flipped to 3-line AND OS-1..OS-4 added AND existing
  Y1/Y3/Y4 unchanged).

### Adversarial
- **Symlink defense.** OS-2 (or a sibling case) creates a symlink at
  the ledger path and asserts `_ensure_review_ledger` exits with `die`
  before any rewrite — pins OQ-2's defense-in-depth.
- **Corrupt line-3 trap.** A variant of OS-2 pre-creates a ledger
  whose line 3 is `# comment_garbage` (a `#`-prefix line that's NOT
  `SEED_LINE_3`); asserts the migrated file consumed the corrupt line
  (`tail_from=4`) so subsequent dispatches no-op — pins Product P1#1.
- **Anchor-literal coupling.** If a future ENG-206-v2 bumps the schema
  to v2, three callsites must move in lockstep: validator's
  `SEED_LINE_3`, orchestrator's `SEED_LINE_3` local in
  `_ensure_review_ledger`, and §5's anchor literal. AP-3 + V-5 jointly
  guard byte-equality; a drift between any pair surfaces as a halt.

## Persona review

### Iteration 1 — initial doc

Five personas ran in parallel. All five returned PASS with zero P0
findings. Iteration 1 cleared the gate.

| Persona     | Verdict | P0 | P1 | P2 |
|-------------|---------|----|----|----|
| feasibility | PASS    | 0  | 2  | 3  |
| scope       | PASS    | 0  | 0  | 2  |
| coherence   | PASS    | 0  | 0  | 2  |
| design      | PASS    | 0  | 0  | 2  |
| product     | PASS    | 0  | 1  | 1  |

**P1 findings folded into the doc:**

| Persona     | Finding | Resolution |
|-------------|---------|------------|
| feasibility P1#1 | AP-3 grep instruction in Task 7 had unbalanced single-quotes. | Task 7's AP-3 step now uses a double-quoted `grep -qF` arg + heredoc; the literal Edit-anchor phrase byte-matches Task 6's §5 edit. |
| feasibility P1#2 | Two adjacent comments in `bin/run-stage.sh` say "two-line `#`-prefix header" (one above `_ensure_review_ledger` at lines 1016-1023; one at the call site at lines 2380-2384). The original Task 3 only addressed the call-site comment. | Task 3's last step now updates BOTH adjacent comments (the function-header comment block AND the call-site comment) to say "three-line." |
| product P1 | Commit-ordering hazard: Task 3 production code edits flip the contract that Task 4's Y2 test asserts. Landing Task 3 first would turn the pre-commit gate red on main and silently block agent commits (per the `pre-commit-gate-red-blocks-agents` memory class). | Task 3 now mandates atomic-commit discipline: stage `bin/run-stage.sh` + `bin/run-stage-test.sh` together. |

**Independent codebase-fact checks** (feasibility persona): all 17
`[verified]` rows in Assumption Inventory CONFIRMED against cited
content anchors. No design pivots required from the verification pass.

**Persona panel readout.** The plan is structurally complete, codebase-
factual, in-scope per the brainstorm's §10 scope guard (no creep or
shortfall beyond the brainstorm's documented OQ-4 narrowing), coherent
across Goal/Tasks/Failure Modes/Test Strategy, design-clean (no new
exit codes, no premature abstractions, no layering violations), and
delivers the operator-facing outcome the Linear issue asked for. All P1
findings folded; P2 findings acknowledged. No iteration 2 needed.
