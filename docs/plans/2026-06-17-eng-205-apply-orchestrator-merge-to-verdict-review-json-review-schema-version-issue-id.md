---
linear: ENG-205
date: 2026-06-17
topic: Apply ENG-203 orchestrator-merge helper to verdict-review.json (review_schema_version, issue_id, dispatch_id)
---

# ENG-205 — Apply orchestrator-merge to verdict-review.json

## Goal

The review agent writes a content-only `verdict-review.body.json` (containing
only `sha`, `verdict`, `dimensions`); the orchestrator post-dispatch merges the
schema envelope (`review_schema_version: 1`, `issue_id`, `dispatch_id`) onto a
fresh canonical `verdict-review.json` via the existing ENG-203
`merge_artifact_envelope` helper, and the existing `_validate_review_payload`
runs on the merged canonical unchanged.

## Assumption Inventory

**Branch-base freshness:** `HEAD..origin/main` is NON-EMPTY at plan time.
`git log --oneline HEAD..origin/main` returns six commits, all on the ENG-152
verdict-author split (latest: `c4ae1e4 Merge pull request #182`). None of
these touch `_merge_qa_payload_envelope`, `merge_artifact_envelope`,
`_clear_current_stage_slots`, `_validate_review_payload`,
`bin/render-prompt.sh::PROMPT_RESOLVERS`, the `AGENT_PROMPTS.md` §5 dimensional
payload block (lines 1804-1822 of HEAD), or `bin/review-payload-schema.sh`.
Drift is clean. Task 0 below pins the rebase so subsequent tasks survive any
late-landing sibling commit; Edit boundaries below use content anchors, never
bare line numbers.

### Code-fact citations (all verified against current branch HEAD)

| Claim | Source | Status |
|---|---|---|
| `merge_artifact_envelope()` is taxonomy-agnostic, returns 0/39/41/42/50, header comment names "callers own envelope-keyset discipline" | `bin/common.sh:699-742` | verified |
| `qa_payload_body_path()` exists as the body-path helper template | `bin/common.sh:99-103` | verified |
| `qa_predicate_body_path()` exists as a sibling helper | `bin/common.sh:104-108` | verified |
| `merge_artifact_envelope` is exported via `export -f` | `bin/common.sh:961` | verified |
| `failure_outcome_for_exit` codes `36→review-payload-malformed`, `37→review-payload-incomplete`, `38→review-payload-missing` (review-payload taxonomy entries already exist) | `bin/common.sh:789-791` | verified |
| `_clear_current_stage_slots()` reviewing-stage branch already clears `verdict-review.json` (ENG-119 ENG-87 per-medium primitive) | `bin/run-stage.sh:949-964` | verified |
| `_validate_review_payload()` runs `bin/review-payload-schema.sh validate <payload> --ident --dispatch-id` and returns 36/37/38 | `bin/run-stage.sh:1400-1419` | verified |
| `_post_review_payload_halt()` embeds `raw` diagnostic via tilde-fenced section + posts via `linear.sh add-comment` | `bin/run-stage.sh:1428-1436` | verified |
| `_merge_qa_payload_envelope()` template caller (function shape + envelope construction + caller-side rc mapping) | `bin/run-stage.sh:2089-2111` | verified |
| Post-dispatch caller wire site for the review-payload validator — reviewing-stage only, guarded by `(( ! skip_dispatch ))` | `bin/run-stage.sh:2956-2972` | verified |
| Post-dispatch caller wire site for the qa-payload merge (template for the new review-payload merge wire) | `bin/run-stage.sh:3025-3046` | verified |
| `_validate_review_thresholds()` reads `$(issue_dir <ident>)/verdict-review.json`; consumes only `.verdict` + `.dimensions[<n>].score` (all content, unaffected by envelope merge) | `bin/run-stage.sh:1704-1764` | verified |
| `PROMPT_RESOLVERS` registry block — `verdict_review_path=_resolve_verdict_review_path` (canonical path, unchanged) + `qa_payload_body_path=…` / `qa_predicate_body_path=…` (sibling body-path resolvers) | `bin/render-prompt.sh:40-66` | verified |
| `_resolve_qa_payload_body_path()` and `_resolve_qa_predicate_body_path()` resolver bodies (template) | `bin/render-prompt.sh:289-290` | verified |
| `_RENDER_QA_PAYLOAD_BODY_PATH` binding in `main()` (template) — sits next to `_RENDER_VERDICT_REVIEW_PATH` at line 665 | `bin/render-prompt.sh:687-688` | verified |
| `AGENT_PROMPTS.md` §5 contains `{verdict_review_path}` token at three agent-Write instruction sites + one narrative-prose mention (which does NOT need editing) | `AGENT_PROMPTS.md:1563, 1749, 1804, 1865` | verified |
| `AGENT_PROMPTS.md` §5 lines 1808-1812 enumerate `review_schema_version: 1`, `issue_id`, `dispatch_id`, `sha`, `verdict` as required agent-emitted fields | `AGENT_PROMPTS.md:1808-1812` | verified |
| `bin/review-payload-schema.sh::cmd_validate` requires `review_schema_version: 1`, `issue_id: ^ENG-[0-9]+$`, `dispatch_id: ^ENG-[0-9]+-d[0-9]+$`, non-empty `sha`, `verdict` enum, `dimensions` object with 4 required keys | `bin/review-payload-schema.sh:112-246` | verified |
| `bin/agent-prompts-content-test.sh::section_body` helper + `s5="$(section_body "## 5. Review Agent")"` slice + sub-window awk locator template (`_slice_section_6_step_window`) used by ENG-203 AP-1..AP-4 | `bin/agent-prompts-content-test.sh:20, 75, 503-516` | verified |
| `bin/render-prompt-rc0-test.sh::case O` template for body-path token resolution check (sandboxed render harness — PIPELINE_DRY_RUN=1, sandbox/state/test-slug-rc0) | `bin/render-prompt-rc0-test.sh:497-522` | verified |
| `bin/run-stage-test.sh` OS-1..OS-7 block for the ENG-203 qa-merge tests (sandbox helper `_os_dir`, capture pattern, dispatch-id env-var setup) | `bin/run-stage-test.sh:9845-10009` | verified |
| `bin/run-stage-test.sh::_eng119_write_valid_json` shared helper writing a valid review-payload schema-v1 fixture | `bin/run-stage-test.sh:5661-5679` | verified |
| `docs/runbooks/recovery.md` §15 covers the ENG-203 qa-payload merge failure pattern; file ends at line 1244 with §15 — §16 lands immediately after | `docs/runbooks/recovery.md:1165-1244` | verified |
| `CLAUDE.md` Failure-mode quick reference table has a row for `qa-payload-invalid: qa-payload-missing` (template for the new review-payload-invalid row) | `CLAUDE.md:826` | verified |
| Harness has no API surface (it is bash orchestration scripts, no FE↔BE wire) — confirmed by Project profile addendum "Stack" line "Bash 3.2+ orchestration scripts (macOS-compatible). The repo contains no application code". | Project profile addendum | verified |
| `learned-rules/harness/project-profile.md::## Build & test gates` Test command is `bash .githooks/pre-commit` which globs `bin/*-test.sh` — no project-profile edit needed (no new test files are created, only existing test files extended) | `learned-rules/harness/project-profile.md:14-19` | verified |

### Assumed/new artefacts

* `verdict_review_body_path()` helper at `bin/common.sh` (assumed/new — to be created by Task T1 near the existing `qa_payload_body_path` at line 99).
* `_resolve_verdict_review_body_path()` resolver + `_RENDER_VERDICT_REVIEW_BODY_PATH` binding at `bin/render-prompt.sh` (assumed/new — to be created by Task T1 next to the existing qa body-path resolvers at lines 289-290 and the binding at 687-688).
* `_merge_review_payload_envelope()` function at `bin/run-stage.sh` (assumed/new — to be created by Task T2 next to `_merge_qa_payload_envelope` at line 2089).
* `docs/runbooks/recovery.md` §16 (assumed/new — to be created by Task T6 immediately after §15 which ends at line 1244).

## System invariants

Each bullet is a runtime assumption this plan depends on, carrying a
`verified_by:` token. New assertions land in this plan's Task T4.

* The `merge_artifact_envelope` helper preserves body keys not in the envelope
  and right-biases envelope keys over body keys on collision.
  `verified_by: bin/common-test.sh:U-1` (helper unit U-1..U-10 from ENG-203,
  unchanged in this plan).
* `failure_outcome_for_exit` taxonomy codes `36/37/38` map to the
  `review-payload-{malformed,incomplete,missing}` halt-reason taxonomy.
  `verified_by: bin/common.sh:789-791` (assertion is the case-statement
  itself; existing run-stage `_validate_review_payload` test
  `bin/run-stage-test.sh:5650-5780` pins the halt-comment shape).
* `_clear_current_stage_slots <ident> reviewing` removes BOTH
  `verdict-review.json` AND `verdict-review.body.json` and does NOT touch
  qa-stage files. `verified_by: task:T4` (new test ENG-205 OS-R4 added to
  `bin/run-stage-test.sh`).
* `_merge_review_payload_envelope` runs BEFORE `_validate_review_payload` in
  the reviewing-stage post-dispatch sequence (caller invocation site is
  inserted BEFORE the existing line-2956-2972 case block).
  `verified_by: task:T4` (new test ENG-205 OS-R1 added to
  `bin/run-stage-test.sh` — end-to-end merge→validate roundtrip).
* The `_merge_review_payload_envelope` caller constructs the envelope JSON
  with EXACTLY the three keys `{review_schema_version, issue_id, dispatch_id}`
  — no extras, no omissions. `verified_by: task:T4` (new test ENG-205 OS-R6
  added to `bin/run-stage-test.sh` — caller-side envelope-keyset discipline,
  mirroring ENG-203's OS-6).
* The `AGENT_PROMPTS.md` §5 documented agent-required-fields enumeration does
  NOT contain `review_schema_version`, `issue_id`, or `dispatch_id` (it MAY
  contain those literals in narrative prose explaining what the orchestrator
  merges — both situations are pinned by the section-locator). The Write
  target token in §5 is `{verdict_review_body_path}`, not
  `{verdict_review_path}`. `verified_by: task:T4` (new tests ENG-205 AP-R1,
  AP-R2, AP-R3, AP-R4 added to `bin/agent-prompts-content-test.sh`).
* The render registry's `verdict_review_body_path` token resolves to an
  absolute path of shape `<issue_dir>/verdict-review.body.json` on the
  reviewing stage. `verified_by: task:T4` (new test ENG-205 RP-R1 added to
  `bin/render-prompt-rc0-test.sh`).

## File Structure

| Path | New/Modified | Change |
|---|---|---|
| `bin/common.sh` | modified | Add `verdict_review_body_path()` helper next to `qa_payload_body_path`; add token to the existing `export -f` list. |
| `bin/render-prompt.sh` | modified | Add `verdict_review_body_path=_resolve_verdict_review_body_path` to `PROMPT_RESOLVERS`; add `_resolve_verdict_review_body_path` body next to the existing qa body-path resolvers; bind `_RENDER_VERDICT_REVIEW_BODY_PATH` in `main()` next to the existing qa-body bindings. (`_write_rendered_paths_sidecar` is NOT extended — review-stage's canonical `verdict_review_path` is already absent from the sidecar by D-004 enumeration in render-prompt.sh, and the body sidecar inherits that omission. Documented as a deliberate omission consistent with the existing Phase-B blind spot recorded in `bin/render-prompt-test.sh:1301-1328`.) |
| `bin/run-stage.sh` | modified | (a) Extend `_clear_current_stage_slots()`'s reviewing-stage block to also `rm -f` `verdict-review.body.json`. (b) Add `_merge_review_payload_envelope()` next to `_merge_qa_payload_envelope`. (c) Insert the merge-caller block in the post-dispatch sequence BEFORE the existing `_validate_review_payload` block. |
| `AGENT_PROMPTS.md` | modified | §5 Review Agent: replace the three agent-Write target tokens from `{verdict_review_path}` to `{verdict_review_body_path}` (in-mind narrative, Decision-path D step list, Output bullet). Strip `review_schema_version`, `issue_id`, `dispatch_id` from the documented required-fields enumeration and add the explanatory sentence "the orchestrator merges schema envelope before validation; do NOT emit those keys yourself." Leave the line-1865 narrative-prose reference to `verdict-review.json` untouched (canonical filename does not change). |
| `bin/run-stage-test.sh` | modified | Add ENG-205 OS-R1..OS-R6 block (end-to-end merge + missing/malformed/symlink/write-fail rc paths, clear-on-start, caller envelope-keyset). |
| `bin/agent-prompts-content-test.sh` | modified | Add ENG-205 AP-R1..AP-R4 block (envelope keys absent from §5 required-fields sub-window; body-path token present; canonical-path token absent from agent Write line). |
| `bin/render-prompt-rc0-test.sh` | modified | Add ENG-205 case Q (or next free letter) — `{verdict_review_body_path}` resolves on reviewing-stage render. |
| `docs/runbooks/recovery.md` | modified | Add §16 "review-payload merge failure (ENG-205)" mirroring §15's shape (defect/rc table, diagnosis, --action continue recovery + body-pre-clean warning, deploy-cutover edge case, envelope-overwrite forensic signal). |
| `CLAUDE.md` | modified | Add a row to the "Failure-mode quick reference" table for rc=36/37/38 with halt-reason `review-payload-invalid` (defect string starting with `review-payload-missing`, `-malformed`, or `-incomplete`). Point to `docs/runbooks/recovery.md` §16. |
| `bin/review-payload-schema.sh` | unchanged | Validator runs on the merged canonical, schema-v1 shape unchanged. |
| `bin/common-test.sh` | unchanged | Helper U-1..U-10 cases added by ENG-203 already cover the helper contract. |
| `bin/pipeline-events.json` | unchanged | No new event-registry entries; the existing `review-payload-invalid` halt reason and `envelope-overwrite` metric (already emitted by the helper) cover the surface. |
| `learned-rules/harness/project-profile.md` | unchanged | No new `bin/*-test.sh` files are added (tests land in three existing files); the profile's Test command `bash .githooks/pre-commit` globs `bin/*-test.sh` so the gate auto-discovers the new assertions. |

## API Contract

No new API surface. The harness is bash orchestration scripts driving
external CLIs (`claude -p`, `gh`, raw GraphQL via `linear.sh`); it has no
FE↔BE wire. The only "contract" this plan touches is the on-disk JSON shape
of `verdict-review.json`, which is governed by `bin/review-payload-schema.sh`
(unchanged) and reproduced inline in §6 below for completeness.

## Backend Tasks

### Task 0: Rebase onto origin/main

- `depends_on: []`
- `touches: (no source edits — git operation only)`

- [ ] Run `git fetch origin main`.
- [ ] Run `git rebase origin/main`. The non-empty `HEAD..origin/main` log
      at plan time is entirely ENG-152 verdict-author work that does NOT
      touch the files in File Structure above. Expected: clean rebase, no
      merge conflicts.
- [ ] Re-verify Assumption Inventory `path:line` citations survived the
      rebase by `grep`ing for the anchor strings named in each row:
      `_merge_qa_payload_envelope` in `bin/run-stage.sh`,
      `merge_artifact_envelope` in `bin/common.sh`,
      `_RENDER_QA_PAYLOAD_BODY_PATH` in `bin/render-prompt.sh`,
      `{verdict_review_path}` in `AGENT_PROMPTS.md`. Line numbers MAY shift;
      the anchor strings MUST survive. If any anchor is missing, STOP and
      post a Linear comment on ENG-205 requesting `pipeline:supersede` —
      the brainstorm is drafting against a stale base.

### Task 1: Add `verdict_review_body_path()` helper + render-prompt resolver

- `depends_on: [0]`
- `touches: bin/common.sh::verdict_review_body_path, bin/common.sh::export -f list, bin/render-prompt.sh::PROMPT_RESOLVERS, bin/render-prompt.sh::_resolve_verdict_review_body_path, bin/render-prompt.sh::main`

- [ ] In `bin/common.sh`, **AFTER** the existing `qa_predicate_body_path()`
      function block (whose body ends with the literal closing line
      `printf '%s/qa-predicate-%s.body.json' "$(issue_dir "$issue")" "$issue"`
      followed by `}`) and **BEFORE** the comment block beginning
      `# Shared per-pass_criterion validator (brainstorm D-007 — single source`,
      add a new function:

      ```bash
      verdict_review_body_path() {
        local issue="$1"
        [[ -n "$issue" ]] || die "verdict_review_body_path: missing issue id"
        printf '%s/verdict-review.body.json' "$(issue_dir "$issue")"
      }
      ```

      Line-number hint: near line ~109 in the unmodified tree.

- [ ] In `bin/common.sh`, locate the `export -f` line whose content begins
      `export -f issue_dir compute_pipeline_content_hash …`. Append the
      single token `verdict_review_body_path` to the end of the
      space-separated list on that same line (it's adjacent to
      `qa_payload_body_path qa_predicate_body_path` at the existing list
      tail). Line-number hint: line ~961.

- [ ] In `bin/render-prompt.sh`, locate the `PROMPT_RESOLVERS` block (the
      multi-line single-quoted string assignment). Add a new line
      `verdict_review_body_path=_resolve_verdict_review_body_path` AFTER the
      existing `qa_predicate_body_path=_resolve_qa_predicate_body_path` line
      and BEFORE the `artifacts_dir=_resolve_artifacts_dir` line.
      Line-number hint: between lines 62 and 63.

- [ ] In `bin/render-prompt.sh`, locate the resolver-body sequence ending
      with `_resolve_qa_predicate_body_path() { printf '%s' "$_RENDER_QA_PREDICATE_BODY_PATH"; }`.
      Add a new line IMMEDIATELY AFTER it (before
      `_resolve_artifacts_dir()`):

      ```bash
      _resolve_verdict_review_body_path() { printf '%s' "$_RENDER_VERDICT_REVIEW_BODY_PATH"; }
      ```

      Line-number hint: between lines 290 and 291.

- [ ] In `bin/render-prompt.sh::main()`, locate the binding block whose
      anchor is the comment beginning
      `# ENG-203: per-issue qa-payload + qa-predicate BODY sidecar paths`,
      followed by the two assignments `_RENDER_QA_PAYLOAD_BODY_PATH=…` and
      `_RENDER_QA_PREDICATE_BODY_PATH=…`. AFTER those two assignment lines
      and BEFORE the next comment block beginning `# ENG-27: per-issue
      artifacts directory`, add a new comment + assignment pair:

      ```bash
      # ENG-205: per-issue verdict-review BODY sidecar path. Content-only
      # artifact the review agent Writes; the orchestrator merges the
      # schema envelope ({review_schema_version, issue_id, dispatch_id})
      # onto it before _validate_review_payload runs.
      _RENDER_VERDICT_REVIEW_BODY_PATH="$(verdict_review_body_path "$issue_id")"
      ```

      Line-number hint: after line 688.

- [ ] Confirm: `bash -n bin/common.sh && bash -n bin/render-prompt.sh`.

### Task 2: Add `_merge_review_payload_envelope()` + post-dispatch caller

- `depends_on: [1]`
- `touches: bin/run-stage.sh::_merge_review_payload_envelope, bin/run-stage.sh::main (post-dispatch reviewing-stage merge block)`

- [ ] In `bin/run-stage.sh`, locate the `_merge_qa_payload_envelope()`
      function (its opening header comment includes the literal phrase
      "qa-stage envelope merge"). IMMEDIATELY BEFORE that function's
      opening header comment block, add a new sibling function:

      ```bash
      # ENG-205: review-payload envelope merge. Reads agent-authored
      # content-only verdict-review.body.json; splices
      # {review_schema_version, issue_id, dispatch_id} envelope onto a
      # fresh canonical verdict-review.json. Runs BEFORE
      # _validate_review_payload in the reviewing-stage post-dispatch
      # sequence so the validator sees a fully-formed canonical.
      #
      # Returns: 0 on success. On failure, the helper rc is REMAPPED to
      # the review-payload taxonomy (36/38) before return because the
      # helper's qa-range codes (39/41/42/50) do NOT overlap the
      # review-payload taxonomy (36/37/38). This is a deliberate
      # divergence from _merge_qa_payload_envelope (which returns the
      # helper's rc verbatim because the qa range overlaps).
      _merge_review_payload_envelope() {
        local ident="$1"
        local d; d="$(issue_dir "$ident")"
        local body="$d/verdict-review.body.json"
        local canonical="$d/verdict-review.json"
        local env_json
        env_json="$(jq -nc --arg ii "$ident" --arg di "${PIPELINE_DISPATCH_ID:-}" \
          '{review_schema_version: 1, issue_id: $ii, dispatch_id: $di}')"
        local rc=0 raw=""
        raw="$(PIPELINE_ISSUE_ID="$ident" PIPELINE_STAGE=reviewing \
          merge_artifact_envelope "$body" "$env_json" "$canonical" 2>&1)" || rc=$?
        if (( rc != 0 )); then
          local defect="" remap=0
          case "$rc" in
            41)        defect="review-payload-missing";   remap=38 ;;
            39|42|50)  defect="review-payload-malformed"; remap=36 ;;
          esac
          _post_review_payload_halt "$ident" "$defect" \
            "merge_artifact_envelope failed (rc=$rc) for body=$body${raw:+ — $raw}"
          return "$remap"
        fi
        return 0
      }
      ```

      Line-number hint: just before line ~2079.

- [ ] In `bin/run-stage.sh::main()`, locate the post-dispatch
      review-payload validator caller block whose anchor is the literal
      comment `# ENG-119: review-payload validator. Post-dispatch; reviewing
      stage only.` IMMEDIATELY BEFORE that comment line, insert the new
      merge-caller block:

      ```bash
      # ENG-205: review-payload envelope merge. Post-dispatch; reviewing
      # stage only. Reads $(issue_dir)/verdict-review.body.json
      # (agent-authored, content only), splices the
      # orchestrator-constructed envelope keys
      # ({review_schema_version, issue_id, dispatch_id}) onto a fresh
      # canonical verdict-review.json. Halts with review-payload-invalid
      # on merge failure (body missing → rc=38 after remap, body
      # malformed/symlink/write-fail → rc=36). The downstream
      # _validate_review_payload runs on the merged canonical.
      if (( ! skip_dispatch )); then
        case "$stage" in
          reviewing)
            local _rev_merge_rc=0
            _merge_review_payload_envelope "$ident" || _rev_merge_rc=$?
            if (( _rev_merge_rc != 0 )); then
              classify_failure "$ident" "$stage" "skip-until-human-acts" \
                "review-payload-invalid: $(failure_outcome_for_exit "$_rev_merge_rc")" \
                "$_rev_merge_rc"
              exit "$_rev_merge_rc"
            fi
            ;;
        esac
      fi
      ```

      Line-number hint: just before line 2956. The block MUST be inserted
      ABOVE the existing ENG-119 validator block to preserve the merge →
      validate sequence.

- [ ] Confirm: `bash -n bin/run-stage.sh`.

### Task 3: Extend `_clear_current_stage_slots()` + edit AGENT_PROMPTS.md §5

- `depends_on: [1]`
- `touches: bin/run-stage.sh::_clear_current_stage_slots, AGENT_PROMPTS.md §5`

- [ ] In `bin/run-stage.sh::_clear_current_stage_slots()`, locate the
      reviewing-stage `if` block. The anchor is the literal comment
      `# ENG-119: pre-clean verdict-review.json on reviewing-stage dispatch`.
      Inside that `if [[ "$stage" == "reviewing" ]]; then … fi` block, AFTER
      the existing line `rm -f "$d/verdict-review.json" 2>/dev/null || true`
      and BEFORE the closing `fi`, add ONE NEW LINE:

      ```bash
        rm -f "$d/verdict-review.body.json" 2>/dev/null || true
      ```

      Line-number hint: insert after line 963.

- [ ] In `AGENT_PROMPTS.md` §5, locate the literal sentence
      `You will Write this as JSON to \`{verdict_review_path}\` at the end of the`
      and replace the token `{verdict_review_path}` with
      `{verdict_review_body_path}` (the sentence becomes
      "You will Write the content-only body as JSON to
      `{verdict_review_body_path}` at the end of the …"). Phrasing edit:
      change "Write this" to "Write the content-only body". Line-number
      hint: line ~1563.

- [ ] In `AGENT_PROMPTS.md` §5, locate the Decision-path D bullet
      `- Write the dimension-scoring payload at \`{verdict_review_path}\``
      (the sentence parenthetically notes `(verdict="approve" — same as path C; the selective exit IS a pass).`). Replace the token
      `{verdict_review_path}` with `{verdict_review_body_path}` and change
      the leading noun "payload" to "body" so the line reads:
      `- Write the dimension-scoring body at \`{verdict_review_body_path}\``.
      Line-number hint: line ~1749.

- [ ] In `AGENT_PROMPTS.md` §5, locate the Output bullet whose first line
      is `- **Write the dimension-scoring payload** at \`{verdict_review_path}\` as`.
      Edit two things in this multi-line bullet:

    (a) Change the bold lead from `**Write the dimension-scoring
        payload**` to `**Write the dimension-scoring body**`, and change
        `\`{verdict_review_path}\`` to `\`{verdict_review_body_path}\``.

    (b) Locate the **Required top-level fields:** sentence (begins
        `**Required top-level fields:**`) and rewrite it. Old:
        `**Required top-level fields:** \`review_schema_version: 1\`, \`issue_id\` (must equal \`{issue_id}\`), \`dispatch_id\` (must equal \`{dispatch_id}\`), \`sha\` (the PR HEAD SHA you reviewed against), \`verdict\` (\`approve\` …)`
        New (single sentence):
        `**Required top-level fields:** \`sha\` (the PR HEAD SHA you reviewed against), \`verdict\` (\`approve\` on path C, \`request-changes\` on path B, \`premise-failure\` on path A, \`halt\` if you exit via agent-blocked). **The orchestrator merges the schema envelope (\`review_schema_version\`, \`issue_id\`, \`dispatch_id\`) onto your body before validation; do NOT emit those keys yourself.**`

        Keep the immediately-following **Required dimensions** block
        (`correctness, testing, maintainability, scope, …`) and the
        **Optional dimensions** block exactly as written — those are
        content, not envelope.

    Line-number hint: starts at line ~1804 and spans ~1804-1822.

- [ ] Do NOT edit the `AGENT_PROMPTS.md` §5 narrative-prose line at ~1865
      (`This is the OPPOSITE lifecycle from the stage-summary file and
      \`verdict-review.json\` (which …)`). The canonical filename
      `verdict-review.json` does not change; this reference remains
      correct.

- [ ] Confirm: `bash -n bin/run-stage.sh`. Also re-render the §5 fence
      count: `awk '/^```/ && /^## 5\. Review Agent/,/^## 6\. QA Agent/' AGENT_PROMPTS.md`
      to spot-check that the §5 block still has exactly two fence lines
      (the `render-prompt.sh` parse contract).

### Task 4: Tests — orchestration + prompt-content + render

- `depends_on: [2, 3]`
- `touches: bin/run-stage-test.sh::ENG-205 OS-R1..OS-R6, bin/agent-prompts-content-test.sh::ENG-205 AP-R1..AP-R4, bin/render-prompt-rc0-test.sh::ENG-205 case Q`

- [ ] In `bin/run-stage-test.sh`, locate the ENG-203 OS-1..OS-7 block
      (anchor: literal header comment
      `# ─── ENG-203: orchestrator-merge + clear-on-start (OS-1..OS-7) ────────`).
      IMMEDIATELY AFTER that entire OS-1..OS-7 block ends (anchor: the
      `# ─── ENG-87 review M1+M2: dispatch_history.jsonl end-row trap.` header
      that immediately follows it on the unmodified tree, or any equivalent
      next-section anchor), add a new block headed
      `# ─── ENG-205: review-payload orchestrator-merge (OS-R1..OS-R6) ────────`.

      Reuse the existing `_os_dir` helper, `reset_capture`, and
      `captured_body` helpers from the OS-1..OS-7 block. Use issue ids
      that match the schema regex `^ENG-[0-9]+$` (e.g. `ENG-9205001`
      through `ENG-9205006`) to avoid collisions with the live ENG-205
      issue dir and to allow end-to-end `_validate_review_payload` calls.

  * **OS-R1** Clean body roundtrip. Write a body containing only
    `sha`, `verdict: "approve"`, and four required `dimensions` keys
    (reuse `_eng119_write_valid_json`'s shape but strip the three
    envelope fields). Set `PIPELINE_DISPATCH_ID=ENG-9205001-d0001`. Call
    `_merge_review_payload_envelope ENG-9205001`. Assert: rc=0; canonical
    `verdict-review.json` exists; `jq -e` confirms it has
    `.review_schema_version == 1`, `.issue_id == "ENG-9205001"`,
    `.dispatch_id == "ENG-9205001-d0001"`, `.verdict == "approve"`,
    `(.dimensions | keys | length) >= 4`. Then call
    `_validate_review_payload ENG-9205001` and assert rc=0. Pins
    AC#2 + the System invariant "merge runs before validator on
    end-to-end roundtrip."

  * **OS-R2** Body missing. Pre-clean (`rm -f`) both
    `verdict-review.body.json` and `verdict-review.json` for
    `ENG-9205002`. Set `PIPELINE_DISPATCH_ID=ENG-9205002-d0001`. Call
    `_merge_review_payload_envelope ENG-9205002` with `reset_capture`
    first. Assert: rc=38 (remapped from helper rc=41); halt comment body
    contains the literal `verdict result=halt reason=review-payload-invalid`
    AND the literal `review-payload-missing` (the Defect line). Pins
    Failure Mode "body missing" + D-004 remap path.

  * **OS-R3** Body parse error. Write `{not json` to
    `verdict-review.body.json` for `ENG-9205003`; pre-clean canonical.
    Call merge with `reset_capture`; assert rc=36 (remapped from helper
    rc=39); halt comment carries the `review-payload-malformed`
    Defect line. Pins Failure Mode "body malformed".

  * **OS-R4** Clear-on-dispatch-start. For `ENG-9205004`, pre-seed
    `verdict-review.json`, `verdict-review.body.json`, AND a qa-stage
    `verdict-qa.json` in the same per-issue dir. Call
    `_clear_current_stage_slots ENG-9205004 reviewing`. Assert: BOTH
    reviewing files are absent post-clear AND the qa-stage file is
    PRESERVED. Pins AC#3 + the System invariant "reviewing clear
    removes both reviewing files and does NOT touch qa-stage files."

  * **OS-R5** ENG-118 threshold-gate compatibility. Write a body where
    `dimensions.correctness.score = "concern"` (or "fail"); set a
    test-only `.review.thresholds.correctness = "pass"` floor via the
    same config-write pattern the existing ENG-118 tests use; merge
    body; assert merge rc=0; call `_validate_review_thresholds`
    against the merged canonical; assert the threshold gate reads the
    merged file and emits the existing coercion comment shape. Pins
    AC#3's "ENG-118's threshold-coercion read of the merged file is
    unaffected." (If the existing ENG-118 test harness in
    `bin/run-stage-test.sh` does not expose a config-write helper, this
    sub-assertion narrows to "the merged canonical's
    `.dimensions.correctness.score` survives the merge with the
    body-emitted value" — equivalent end-to-end coverage.)

  * **OS-R6** Caller-side envelope-keyset discipline. Stub
    `merge_artifact_envelope` to capture the env_json argument (mirror
    OS-6's `_os6_capture` pattern at `bin/run-stage-test.sh:9991-10009`,
    including the `eval "$_os6_real_def"` restore + the
    `export -f merge_artifact_envelope` re-export trail). Call
    `_merge_review_payload_envelope ENG-9205006`. Assert the captured
    env_json's keys are EXACTLY `{review_schema_version, issue_id,
    dispatch_id}` (no extras, no omissions) via
    `jq -e '(keys | sort) == ["dispatch_id", "issue_id", "review_schema_version"]'`.
    Pins the System invariant "envelope JSON contains exactly the three
    keys."

- [ ] In `bin/agent-prompts-content-test.sh`, locate the existing
      ENG-203 §6 AP-1..AP-7 block (anchor: the comment header
      `# ─── ENG-203: §6 content-only body contract ─────────────────────────────`
      at line ~490). AFTER that entire AP-1..AP-7 block, add a new block
      headed `# ─── ENG-205: §5 content-only body contract (review) ──────────────────`.

      Mirror the `_slice_section_6_step_window` pattern but anchor on
      §5's structure. Helpers:

      ```bash
      _slice_section_5_window() {
        local _anchor="$1" _max="${2:-40}"
        printf '%s\n' "$s5" | awk -v anchor="$_anchor" -v maxL="$_max" '
          BEGIN { in_block = 0; lines = 0 }
          index($0, anchor) > 0 { in_block = 1 }
          in_block == 1 {
            print
            lines++
            if (lines >= maxL) exit
          }
        '
      }
      ```

      Anchor the "Write the dimension-scoring body" Output bullet
      (anchor string: `Write the dimension-scoring body`). Slice the
      ~25-line window covering the bullet + its Required-fields and
      Required-dimensions sub-blocks. Narrow further to the
      `**Required top-level fields:**` sub-block by awk-extracting
      from the literal `**Required top-level fields:**` anchor through
      the next blank line.

  * **AP-R1** The `Required top-level fields` sub-window does NOT
    contain the literal `review_schema_version`. (The narrative
    sentence "The orchestrator merges the schema envelope
    (`review_schema_version`, `issue_id`, `dispatch_id`) …" may
    contain that literal but lives BELOW the required-fields sub-block
    and is sliced out by the awk extractor.)

  * **AP-R2** The `Required top-level fields` sub-window does NOT
    contain the literal `dispatch_id` and does NOT contain the literal
    `issue_id` as a documented required-emitted field.

  * **AP-R3** §5 contains the literal `{verdict_review_body_path}` token.

  * **AP-R4** The agent-Write instruction line (anchor: the bullet
    `**Write the dimension-scoring body**`) does NOT contain the literal
    `{verdict_review_path}` token. (The line-1865 narrative-prose
    reference uses bare backticks around `verdict-review.json`, NOT the
    `{verdict_review_path}` token, so a whole-§5 scan would pass too —
    but narrow the assertion to the Output bullet's leading line for
    precision.)

- [ ] In `bin/render-prompt-rc0-test.sh`, locate the case O block
      (anchor: comment header
      `# ─── ENG-113/ENG-203 case O: {qa_predicate_body_path} resolves on qa-stage render`).
      AFTER case O and BEFORE the
      `printf '\n━━━ Summary ━━━\nPASS: %d / FAIL: %d\n'` line, add case Q
      (or the next free letter):

      ```bash
      # ─── ENG-205 case Q: {verdict_review_body_path} resolves on reviewing-stage render
      # The §5 prompt body carries the literal token {verdict_review_body_path},
      # render-prompt.sh::PROMPT_RESOLVERS registers it → _resolve_verdict_review_body_path,
      # and main() binds _RENDER_VERDICT_REVIEW_BODY_PATH via
      # common.sh::verdict_review_body_path(issue_id). After resolution the
      # rendered prompt MUST contain the full absolute-path shape
      # `<issue-dir>/verdict-review.body.json`.
      ISSUE_DIR_Q="$sandbox/state/test-slug-rc0/ENG-87R6X-Q"
      rm -rf "$ISSUE_DIR_Q"; mkdir -p "$ISSUE_DIR_Q"
      out_q="$(PIPELINE_DRY_RUN=1 LINEAR_API_KEY=test-mock-key \
        TARGET_REPO="$sandbox/target" PROJECT_SLUG=test-slug-rc0 \
        PROJECT_STATE_DIR="$sandbox/state/test-slug-rc0" \
        HARNESS_ROOT="$sandbox" HARNESS_STATE_DIR="$sandbox/state" \
        _timeout bash "$sandbox/bin/render-prompt.sh" reviewing ENG-87R6X-Q 2>/dev/null || true)"
      EXPECTED_Q="$sandbox/state/test-slug-rc0/ENG-87R6X-Q/verdict-review.body.json"
      if grep -qF "$EXPECTED_Q" <<<"$out_q"; then
        ok "ENG-205 case Q: {verdict_review_body_path} resolves to $EXPECTED_Q on reviewing-stage render"
      else
        fail "ENG-205 case Q: {verdict_review_body_path} resolves on reviewing-stage render" \
             "expected absolute-path substring '$EXPECTED_Q' missing from rendered prompt — out tail: $(tail -10 <<<"$out_q" | tr '\n' ' ')"
      fi
      ```

- [ ] Confirm: run each modified test file once
      (`bash bin/run-stage-test.sh`, `bash bin/agent-prompts-content-test.sh`,
      `bash bin/render-prompt-rc0-test.sh`) and confirm all new
      ENG-205 assertions pass alongside the existing suite.

### Task 5: Operator documentation — recovery.md §16

- `depends_on: [2, 3]`
- `touches: docs/runbooks/recovery.md (new §16), CLAUDE.md (Failure-mode quick reference table)`

- [ ] In `docs/runbooks/recovery.md`, AFTER the existing §15 (anchor: the
      file's final code-fence
      `\`\`\`bash
      jq -c 'select(.event == "envelope-overwrite")' \\
        "$PROJECT_STATE_DIR/<slug>/metrics/events.jsonl"
      \`\`\``
      at the bottom of §15), append a new H2 section:

      ```markdown
      ## 16. review-payload merge failure (ENG-205)

      **Symptom.** Issue halts at `stage:reviewing` with a verdict
      comment `<!-- pipeline: verdict result=halt reason=review-payload-invalid -->`
      and a defect string starting with one of:

      | Defect | rc | Trigger |
      |---|---|---|
      | `review-payload-missing`   | 38 | Agent did not Write `verdict-review.body.json` |
      | `review-payload-malformed` | 36 | Body is JSON parse error / not an object / oversize (>64 KiB) |
      | `review-payload-malformed` | 36 | Body is a symlink, OR caller passed a non-object envelope (remapped from helper rc=42) |
      | `review-payload-malformed` | 36 | Canonical write target unwritable (remapped from helper rc=50) |

      `failure_outcome_for_exit` for the helper rcs 39/42/50 cosmetically
      reads `qa-payload-malformed` / `qa-predicate-malformed` /
      `review-ledger-missing` — but `_merge_review_payload_envelope`
      remaps them all to the review-payload taxonomy (36/38) BEFORE
      `classify_failure` runs, so the halt-reason taxonomy you see in the
      verdict comment is always one of `review-payload-{malformed,missing}`.
      The halt comment's `Defect:` line names the underlying subcode.

      **Diagnosis.** The orchestrator-side
      `_merge_review_payload_envelope` runs post-dispatch on the
      reviewing stage, splices a fresh schema envelope
      (`review_schema_version: 1`, `issue_id`, `dispatch_id`) onto the
      agent's content-only body at
      `$(issue_dir <ident>)/verdict-review.body.json`, and writes the
      merged canonical at `$(issue_dir <ident>)/verdict-review.json`
      BEFORE `_validate_review_payload` runs.

      Inspect the agent's body sidecar (NOT the canonical):

      ```bash
      cat "$PROJECT_STATE_DIR/<slug>/<ENG-N>/verdict-review.body.json"
      ```

      For the rc=50 write-failure case (canonical target unwritable),
      check disk space and per-issue directory permissions (same recipe
      as §15's rc=50 path):

      ```bash
      df -h "$PROJECT_STATE_DIR"
      ls -la "$PROJECT_STATE_DIR/<slug>/<ENG-N>/"
      ```

      **Recovery.** Standard `--action continue` reset:

      ```bash
      bash bin/pipeline.sh decide <ENG-N> --action continue
      ```

      > ⚠️ `_clear_current_stage_slots reviewing` pre-cleans BOTH
      > `verdict-review.json` AND `verdict-review.body.json` at the next
      > reviewing dispatch's start. A hand-edit on either file BEFORE
      > resume is therefore erased. Operators wanting to repair the
      > body must instead edit the canonical `verdict-review.json` and
      > emit the verdict marker themselves with
      > `bash bin/pipeline.sh event <ENG-N> verdict pass --stage reviewing`
      > (see §11 for the manual-repair recipe — the same shape applies).

      **Deploy-cutover edge case.** A reviewing dispatch already in
      flight when ENG-205 deploys ran under the OLD §5 prompt and wrote
      a full canonical instead of a body sidecar. Post-cutover the new
      `_merge_review_payload_envelope` halts with
      `review-payload-invalid: review-payload-missing` because the
      body file is absent. Recovery is the same `--action continue`:
      the next reviewing dispatch runs the new prompt, the agent writes
      the body, and the merge succeeds. Bounded to one issue per
      project (whichever was in `stage:reviewing` at deploy time).

      **Defensive double-write.** If the agent writes BOTH a full
      canonical AND a body sidecar, the merge helper's atomic `mv` of
      its tmp file silently overwrites the agent's canonical. Behaviour
      is correct (the orchestrator-built envelope wins). The
      `envelope-overwrite` metric fires only when one or more body keys
      collide with the envelope keyset
      (`review_schema_version`/`issue_id`/`dispatch_id` — see "Forensic
      signal" below); a pure content-only body that just happens to
      sit next to a stale canonical does NOT fire it (no
      body↔envelope key collision). The retrospective may still notice
      via the prompt-content tests in
      `bin/agent-prompts-content-test.sh::§5 ENG-205 AP-R1..AP-R4`.

      **Forensic signal.** When the helper merges successfully but the
      agent's body collides with one or more envelope keys (e.g. the
      agent typed `review_schema_version` despite the §5 instruction
      not to), the helper emits an `envelope-overwrite` metric to
      `events.jsonl` with `count=<n> keys=<csv> body=<path>` and
      `stage=reviewing` (set by the caller-exported
      `PIPELINE_STAGE=reviewing`). Operators auditing prompt-drift:

      ```bash
      jq -c 'select(.event == "envelope-overwrite" and .stage == "reviewing")' \
        "$PROJECT_STATE_DIR/<slug>/metrics/events.jsonl"
      ```
      ```

- [ ] In `CLAUDE.md`, locate the "Failure-mode quick reference" table
      row whose first column begins
      `| Halt at rc=41 with halt-reason \`qa-payload-invalid\``
      (the ENG-203 row, line ~826). AFTER that row, add a new row
      mirroring its shape:

      ```markdown
      | Halt at rc=36 or rc=38 with halt-reason `review-payload-invalid` and a defect string starting with `review-payload-missing` (rc=38) or `review-payload-malformed` (rc=36) | ENG-205 orchestrator-merge helper tripped on the reviewing stage: the review agent did not write `verdict-review.body.json`, or the body was malformed / a symlink / oversize / the canonical was unwritable. The §5 prompt now instructs the agent to write a content-only body sidecar at `{verdict_review_body_path}`; the orchestrator merges the schema envelope (`review_schema_version`, `issue_id`, `dispatch_id`) before the schema validator runs. See `docs/runbooks/recovery.md` §16 for the per-rc diagnosis table, the deploy-cutover edge case (one issue per project halts on first post-cutover reviewing dispatch), and the `envelope-overwrite` forensic signal. **Recovery:** `bash bin/pipeline.sh decide <ENG-N> --action continue` — the reviewing-stage clear pre-cleans BOTH `verdict-review.json` AND `verdict-review.body.json`, so hand-edits to either file before resume are erased; repair the canonical instead and emit the verdict manually if the body is unrecoverable. |
      ```

- [ ] Confirm: visual inspection of the CLAUDE.md table renders the new
      row correctly (no broken pipes / missing trailing pipe).

## Frontend Tasks

None — the harness has no UI surface. The Project profile addendum's "Stack"
line states: "Bash 3.2+ orchestration scripts (macOS-compatible). The repo
contains no application code — it is the harness that drives an SDLC
pipeline against a separate target repo."

## Failure Mode → Test Map

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
|---|---|---|---|---|
| Agent did not Write the body sidecar | `verdict-review.body.json` absent on dispatch exit | Halt with `review-payload-invalid: review-payload-missing` (rc=38, remapped from helper rc=41); halt comment names the body path | integration | `bin/run-stage-test.sh::ENG-205 OS-R2` |
| Body is a JSON parse error / not an object / oversize | Body contains malformed JSON or has size > 64 KiB | Halt with `review-payload-invalid: review-payload-malformed` (rc=36, remapped from helper rc=39); helper stderr embedded verbatim in halt comment | integration | `bin/run-stage-test.sh::ENG-205 OS-R3` |
| Body is a symlink (path-traversal defense) | `verdict-review.body.json` is a symlink to anywhere | Same halt as above (rc=36, remapped from helper rc=42); helper diagnostic "merge: body is symlink:" surfaces in the halt comment | integration | covered by OS-R3 generalisation (helper rc=42 → same caller remap as rc=39); explicit fixture optional |
| Canonical write target unwritable (disk full / permissions / atomic-mv fail) | Canonical path or its parent dir unwritable | Same halt as above (rc=36, remapped from helper rc=50); helper diagnostic "merge: atomic mv failed" / "merge: mktemp failed" surfaces | integration | covered by OS-R3 generalisation (helper rc=50 → same caller remap); operator-visible signal via §16 §recovery.md `df -h` / `ls -la` recipe |
| Clean roundtrip — content-only body merges to a valid canonical | Body has only `sha`/`verdict`/`dimensions` | Merge rc=0; canonical has all five top-level keys; `_validate_review_payload` returns rc=0 | integration | `bin/run-stage-test.sh::ENG-205 OS-R1` |
| Stale body from prior dispatch | `verdict-review.body.json` survives from a previous reviewing iteration | `_clear_current_stage_slots reviewing` removes BOTH reviewing files at dispatch start; merge runs on fresh body | unit | `bin/run-stage-test.sh::ENG-205 OS-R4` |
| Loopback `reviewing → implementing` preserves review files | Decision-path B (`verdict request-changes`) | Reviewing files survive the loopback (implementing-stage clear does not touch reviewing files); next reviewing-stage clear fires fresh | unit | indirectly pinned by OS-R4 (stage-gating preserved) + the existing ENG-203 OS-4 test for the same stage-gating contract on qa files |
| Empty `dispatch_id` (scope-approval replay path) | `$PIPELINE_DISPATCH_ID` is unset; envelope `dispatch_id` is empty string | Schema validator rejects with `dispatch_id must be a non-empty string`; halt with `review-payload-invalid: review-payload-incomplete` (rc=37) — pre-existing behavior, unchanged | integration | covered by the existing `bin/run-stage-test.sh::ENG-119 INT*` review-payload validator tests (no new test needed; ENG-205 inherits the validator's contract) |
| Agent writes envelope key inside body (e.g. `review_schema_version: 99`) | Body emits a key in the envelope keyset | Envelope-wins merge overwrites silently; `envelope-overwrite` metric fires with `count=<n> keys=<csv> stage=reviewing`; canonical remains valid; no halt | integration | covered by the existing ENG-203 `bin/run-stage-test.sh::OS-7` (`envelope-overwrite` metric assertion against the helper); ENG-205's caller exports `PIPELINE_STAGE=reviewing` (verified in OS-R6 by inspection of the env_json call) |
| Caller's envelope-keyset does not match the documented 3-key contract | Future maintainer adds a key to the envelope JSON | Test fails — `jq -e '(keys | sort) == ["dispatch_id", "issue_id", "review_schema_version"]'` returns rc=1 | unit | `bin/run-stage-test.sh::ENG-205 OS-R6` |
| §5 prompt drifts to re-document envelope keys as agent-required | Future prompt edit reintroduces `review_schema_version` to the Required top-level fields sub-block | Test fails — `bin/agent-prompts-content-test.sh::ENG-205 AP-R1` (or AP-R2) reports the literal key present in the sub-block | unit (prompt-content) | `bin/agent-prompts-content-test.sh::ENG-205 AP-R1/AP-R2` |
| §5 prompt drifts to use the canonical-path token on the Write line | Future prompt edit changes `{verdict_review_body_path}` back to `{verdict_review_path}` on the agent Write instruction | Test fails — AP-R3 missing (body-path token gone) and/or AP-R4 fails (canonical-path token reappears on the bullet's lead line) | unit (prompt-content) | `bin/agent-prompts-content-test.sh::ENG-205 AP-R3/AP-R4` |
| Render-time resolver token broken | Future PROMPT_RESOLVERS regression (typo, missing binding) | Rendered prompt contains the literal `{verdict_review_body_path}` instead of an absolute path; render-prompt's residual unknown-token validator dies | smoke | `bin/render-prompt-rc0-test.sh::ENG-205 case Q` |
| ENG-118 threshold gate consumes merged canonical | `.review.thresholds.correctness = "pass"` and body emits `dimensions.correctness.score = "fail"` | Threshold gate reads the merged canonical and coerces the verdict (or emits the dimensional-threshold/<stage>/<ident> comment); the merge does not strip `.verdict` or `.dimensions[].score` | integration | `bin/run-stage-test.sh::ENG-205 OS-R5` |

## Test Strategy

* **Unit (orchestration helpers).** OS-R6 stubs `merge_artifact_envelope`
  and inspects the env_json the caller built; this is a pure unit
  assertion on the envelope-keyset discipline of
  `_merge_review_payload_envelope`. OS-R4 exercises
  `_clear_current_stage_slots`'s file-removal contract directly.
* **Integration (orchestrator end-to-end).** OS-R1 runs merge → validator
  roundtrip with no stubs; OS-R2/OS-R3 trip the merge helper's rc paths
  and assert the halt comment surface; OS-R5 wires the merge to the
  ENG-118 threshold gate to assert downstream consumers see body
  content. The existing ENG-119 INT block continues to pin the
  validator's error shape for `dispatch_id`/`issue_id` mismatch
  (legacy guards that survive ENG-205 because the validator runs on
  the merged canonical).
* **Smoke (render path).** Case Q exercises the rendered-prompt path
  end-to-end via the sandbox harness; if any of (resolver registration,
  resolver body, `_RENDER_VERDICT_REVIEW_BODY_PATH` binding,
  `verdict_review_body_path()` helper) regress, the rendered prompt
  emits a literal `{verdict_review_body_path}` token and the
  grep-for-absolute-path assertion fails.
* **Adversarial (prompt-content).** AP-R1..AP-R4 narrow their
  assertions to the `Required top-level fields` sub-window in §5 (an
  awk-anchored slice), so the narrative-prose sentence
  "The orchestrator merges the schema envelope (`review_schema_version`,
  `issue_id`, `dispatch_id`) onto your body before validation" is
  ALLOWED to mention the envelope keys (it's documentary, not
  instructive). A future prompt-edit that re-promotes those keys to
  the agent-required-fields list trips AP-R1/AP-R2. AP-R4 anchors on
  the bullet's bold lead line `**Write the dimension-scoring body**`
  to avoid false-positives from the line-1865 narrative-prose mention
  of `verdict-review.json` (which is the canonical name, not the
  token).
* **No new test files.** Every new assertion lands in an existing
  `bin/*-test.sh`. The Project profile's `## Build & test gates` Test
  command (`bash .githooks/pre-commit`) globs `bin/*-test.sh`, so the
  new ENG-205 assertions are auto-discovered; no project-profile edit
  is required.
* **Helper coverage untouched.** ENG-203's U-1..U-10 unit tests in
  `bin/common-test.sh` pin the `merge_artifact_envelope` helper's
  contract end-to-end; reuse is the design intent (D-001 of the
  brainstorm) and re-adding caller-specific helper-level tests for
  ENG-205 would be YAGNI.

## Self-review (5 personas)

Five personas were dispatched in parallel against this plan
post-draft. Results below; all five PASS with zero P0s remaining
after a single iteration. Notes (P1/P2 commentary) integrated above
into the relevant tasks/sections; no further rework.

| Persona | Verdict | Notes |
|---|---|---|
| feasibility | PASS · 0 P0 | All `path:line` citations in Assumption Inventory re-verified against current HEAD; helper rcs (39/41/42/50 → caller-remapped 36/38) match the existing `failure_outcome_for_exit` taxonomy at `bin/common.sh:789-791`; the `_merge_qa_payload_envelope` template is byte-stable at `bin/run-stage.sh:2089-2111`. Test-gate closure (remove-side) sweep: the literal `{verdict_review_path}` token is removed from the §5 agent-Write instruction sites ONLY — the token remains live (resolver + `_RENDER_VERDICT_REVIEW_PATH` + canonical filename are unchanged) so `bin/render-prompt-test.sh::ENG-119` and `:1301-1328` continue to pass without edit. Test-gate closure (add-side) sweep: no new `bin/*-test.sh` files are created; the profile's glob auto-discovers the new assertions appended to existing files; no `learned-rules/harness/project-profile.md` edit needed. System invariants resolution sweep: all bullets either resolve to existing test sites (`bin/common-test.sh::U-1`, `bin/common.sh:789-791`) or to in-plan Task T4, which touches `bin/run-stage-test.sh`, `bin/agent-prompts-content-test.sh`, and `bin/render-prompt-rc0-test.sh` — all on the harness's gate-runnable glob. |
| scope | PASS · 0 P0 | Subsystems touched: orchestrator (`bin/run-stage.sh`), agent-prompts (`AGENT_PROMPTS.md` §5), tests/fixtures (3 test files), dispatch (`bin/common.sh` + `bin/render-prompt.sh` — clearly subordinate at ≤10 lines per file). Matches the brainstorm's "2 subsystems, autonomy-safe" sizing. No gold-plating: the `sha` envelope-move suggestion (Open Question OQ-1 in the brainstorm) is explicitly deferred; the review-ledger envelope/body split (OQ-2) is explicitly out-of-scope. Every `touches:` field stays within the declared File Structure. |
| coherence | PASS · 0 P0 | Goal sentence aligns with brainstorm Overview ("ENG-205 ships the smallest cut against the next-most-likely slip surface"). Failure Mode → Test Map covers all six edge cases the brainstorm names in §6 (empty dispatch_id, loopback, deploy-cutover, content-key-in-envelope, threshold gate read-path, defensive double-write). The `_validate_review_payload` schema check runs on the merged canonical unchanged — all consumer read-paths verified path-compatible (`_validate_review_thresholds` at `bin/run-stage.sh:1722` reads canonical; `_validate_review_ledger` reads ledger, not payload — unaffected; `_post_deferred_majors_comment_if_eligible` reads verdict marker, not payload — unaffected). Backend tasks jointly realise every brainstorm decision (D-001 → T2; D-002 → T1; D-003 → T3; D-004 → T2; D-005 → T3; D-006 → T2; D-007 → T5 §16 deploy-cutover; D-008 → no in-dispatch flag, T2 is post-dispatch only; D-009 → T4). |
| design | PASS · 0 P0 | No new architectural decision. Mechanism (sidecar-merge with orchestrator-side envelope construction) mirrors ENG-203 D-001 verbatim, putting the reuse contract under the same pressure ENG-203 D-001 already withstood. Crate-boundaries equivalent: `bin/common.sh` carries cross-script helpers (existing pattern); `bin/render-prompt.sh` registry adds a token (existing pattern); `bin/run-stage.sh` adds a stage-gated post-dispatch caller (existing pattern). No circular deps. No layering violation: the agent prompt does NOT name the envelope keys; the orchestrator owns them; the validator runs on the merged canonical — the same one-direction flow ENG-203 introduced. |
| product | PASS · 0 P0 | Operator contact surface (halt comment shape, recovery recipe, deploy-cutover bound) mirrors ENG-203's §15 shape — the operator's mental model from the qa-merge cutover carries over directly. The halt comment's `Defect:` line names the underlying subcode so the operator sees the actual cause even when the cosmetic taxonomy text is the qa-flavoured `qa-payload-malformed` for rc=42/50. The §16 "Defensive double-write" note (added by feasibility persona's P2 note) addresses the case where an agent both writes a full canonical AND a body sidecar — behaviour is correct (orchestrator's mv wins) but the operator might be confused if they see a fresh canonical. Bounded blast radius: one in-flight reviewing dispatch at deploy time. |
