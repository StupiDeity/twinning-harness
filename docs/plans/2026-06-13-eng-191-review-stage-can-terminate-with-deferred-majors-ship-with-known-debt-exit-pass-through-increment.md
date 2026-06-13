---
linear: ENG-191
date: 2026-06-13
topic: Review stage selective exit (ship-with-deferred-majors) — agent-decided path D + per-finding blocks_ship axis on the ENG-190 ledger + orchestrator-side deferred-majors comment
---

# Plan — Review stage selective exit (ship-with-deferred-majors) (ENG-191)

## Anti-anchoring check

- **Problem (operator-perspective):** "Today the only terminal state of the review stage is `Adjudicated major == 0 AND Adjudicated critical == 0`. A PR that legitimately surfaces ≥1 genuine adjudicated-major every round — even after ENG-190's stabilise/defer-candidate adjudication memory — has no exit. The agent either loops back to implementing forever, or `review_rejection(2>=2)` trips at the next implementing dispatch and halts for human triage. Real teams ship with known debt; the harness doesn't."
- **Brainstorm framing:** matches the problem one-for-one. Fix is a third reachable path D from §5 — `reviewing → qa` with `reason=ship-with-deferred-majors` — gated on (a) `Adjudicated critical == 0`, (b) every adjudicated-major has `blocks_ship == false` per a structured five-question rubric, (c) `convergence_rounds_at_zero_critical >= N` (config-driven, default 2). Selective: any major adjudged `blocks_ship == true` forces the existing path B loopback (no exit taken). Critical-floor-blocks-ship extension makes critical always `blocks_ship == true`. The agent decides; the orchestrator posts the deferred-majors enumeration comment after the fact.
- **Proportionality:** registry edit (one `pass_reasons` array + one `field_registry_by_arm.pass.reason` line in `bin/pipeline-events.json`), schema-validator extension on the existing `bin/review-ledger-schema.sh` (three new optional fields + critical-floor-blocks-ship rule + schema-grace clause via `dispatch_id == --dispatch-id` gate), one new resolver token `{review_converge_rounds}` in `bin/render-prompt.sh`, §5 prompt edits in `AGENT_PROMPTS.md` (deferability axis + five-question rubric + path D + sub-variant path B′ + Deferrable count-tuple line + new ledger fields in Output bullet + path-D verdict-marker bullet), one new orchestrator hook `_post_deferred_majors_comment_if_eligible` slotted between `_validate_review_ledger` and `post_completion_comment` in `bin/run-stage.sh::main`, six sibling test-suite extensions (no new test files — existing siblings extended). Mirrors ENG-115 (per-arm registry override), ENG-119 / ENG-190 (validator + halt detective pattern), ENG-87 dispatch_id primitive (schema-grace clause), ENG-133 + ENG-190 (count-tuple emission). Subsystem count = 3 load-bearing (orchestrator + agent-prompts + Linear-contract/config) plus tests/docs subordinate, per the Linear Sizing block. Proportional. Proceed.

## Goal

When the reviewing-stage agent finds `Adjudicated critical == 0 AND Adjudicated major > 0 AND every adjudicated-major has blocks_ship == false AND convergence_rounds_at_zero_critical >= N` (config-driven via `human_checkpoints.review_converge_rounds`, default 2; the `major > 0` guard prevents the Path D predicate from overlapping with Path C's clean-exit predicate on the empty-major-set case where "every adjudicated-major has blocks_ship==false" is vacuously true), the agent emits `verdict pass --stage reviewing --reason ship-with-deferred-majors`, the verdict-handler forwards `reviewing → qa` unchanged (no new transition), and the orchestrator's post-dispatch hook `_post_deferred_majors_comment_if_eligible` reads this-dispatch ledger rows where `adjudicated_severity == major AND blocks_ship == false` and posts ONE markdown-bulleted Linear comment under `--sig deferred-majors/<ident>` enumerating the deferred majors (per-finding rationale + five-question decision-factors + ledger-row provenance); the per-finding `blocks_ship: bool`, `ship_classification_rationale: string`, `decision_factors: {five booleans}` are emitted on every this-dispatch ledger row whose `adjudicated_severity ∈ {major, critical}` and validated by `bin/review-ledger-schema.sh` under a critical-floor-blocks-ship invariant (`adjudicated_severity == critical ⇒ blocks_ship == true`) and a schema-grace clause that exempts prior-dispatch rows (`dispatch_id != --dispatch-id`) from the new requirements; the new `pass_reasons` closed-vocabulary entry `ship-with-deferred-majors` is registered under `events.verdict.linear_comment.field_registry_by_arm.pass.reason` so the pass arm accepts it while halt/wait/fail/pivot arms reject it; any major adjudged `blocks_ship == true` forces the existing `reviewing → implementing` path-B loopback (selective exit, not all-or-nothing); and a new sub-variant path B′ — fires when path D's first two conditions hold but `convergence_rounds < N` — loops back without bumping `review_rejection`, so a PR waiting for the convergence plateau cannot exhaust the implement-rejection budget.

## Assumption Inventory

**branch-base freshness:** `git log --oneline HEAD..origin/main` is EMPTY at plan time; `origin/main = 438bd7376211c9763d3fcbcf638fd98839f843b2` (the ENG-190 tip — adjudication ledger shipped). Branch base is fresh. No Task 0 rebase is required — all `path:line` excerpts below are anchored against the current branch tip. Edit boundaries use CONTENT anchors (function names, unique literals, comment markers) so unrelated commits landing above the insertion points before merge are harmless.

### Verified — code paths quoted from current tree

- `[verified]` `bin/pipeline-events.json:10-26` — `halt_reasons` array (15 entries, `review-ledger-invalid` is last; no change here). `verdict_results` at `:3-9`; `field_registry_by_arm` at `:108-113` (today carries only `pivot.target = "pivot_targets"` and `pivot.reason = "pivot_reasons"`). The new `pass_reasons: ["ship-with-deferred-majors"]` array slots at top level AFTER `verdict_results` (preserving alphabetic-by-group convention; mirrors the `wait_reasons`/`fail_targets`/`pivot_targets`/`pivot_reasons` shape). New `field_registry_by_arm.pass.reason = "pass_reasons"` slots INSIDE the existing `field_registry_by_arm` object BEFORE the `pivot:` key. Content anchor: the line `"field_registry_by_arm": {`.
- `[verified]` `bin/pipeline.sh:168-181` — `_validate_event_payload` reads `field_registry_by_arm[arm][k]` and prefers it over `field_registry[k]`. The `pass.reason` override therefore activates for `cmd_event_verdict ... verdict pass --reason ship-with-deferred-majors` and never affects halt/wait/fail/pivot. Content anchor: the line `(.field_registry_by_arm // {})[$a][$k] // .field_registry[$k] // empty`.
- `[verified]` `bin/pipeline.sh:266-289` — `cmd_event_verdict` parses `--reason`, builds `args+=("reason=$reason")`, calls `_validate_event_payload verdict "$result" "${args[@]}"`. The new pass-arm reason flows through this path unchanged. Content anchor: `cmd_event_verdict() {`.
- `[verified]` `bin/verdict-handler.sh:19-27` — `_VH_FORWARD_TRANSITIONS` row `reviewing=qa` exists. No change. Content anchor: the literal `reviewing=qa`.
- `[verified]` `bin/verdict-handler.sh:236-251` — `find_fresh_verdict` projects the pass arm as `{marker:"pipeline-stage-summary", source_stage:$e.stage, target_stage:"", reason:"", comment_id:$id, event:$e}`. **Critical:** top-level `reason` is HARD-WIRED to `""` for the pass arm; the actual reason lives inside the projected `event` field (the full parsed marker JSON), reachable as `event.reason`. The orchestrator hook MUST read `event.reason`, not the top-level `reason` field. Content anchor: the line `{marker:"pipeline-stage-summary", source_stage:$e.stage, target_stage:"", reason:"", comment_id:$id, event:$e}`.
- `[verified]` `bin/verdict-handler.sh:311-432` — `apply_transition` parameters are `issue, from, to, side_labels, post_waypoint`. It does NOT consult any `reason` field. The pass-arm reason token is informational for the orchestrator hook only; the state machine ignores it. Content anchor: `apply_transition() {`.
- `[verified]` `bin/guards.sh:135-137` — `review_rejection` trip is gated on `[[ -z "$stage" || "$stage" == "implementing" ]]`. Path D (`reviewing → qa`) bypasses by NEVER bumping; path B′ (loopback to implementing without bump) does the same. No change to guards.sh. Content anchor: the literal `(( rev >= review_threshold )) && [[ -z "$stage" || "$stage" == "implementing" ]]`.
- `[verified]` `bin/render-prompt.sh:40-62` — `PROMPT_RESOLVERS` registry (22 tokens; last entry `artifacts_dir=_resolve_artifacts_dir` on line 61). New entry `review_converge_rounds=_resolve_review_converge_rounds` slots AFTER `artifacts_dir=_resolve_artifacts_dir` on line 61 and BEFORE the closing `'` on line 62. Content anchor: the line `artifacts_dir=_resolve_artifacts_dir`.
- `[verified]` `bin/render-prompt.sh:280` — `_resolve_review_ledger_path() { printf '%s' "${_RENDER_REVIEW_LEDGER_PATH-}"; }` — one-line resolver shape precedent. New `_resolve_review_converge_rounds()` mirrors the shape but reads from config rather than `_RENDER_*` (the value is data, not a `main()`-bound global; D-010). Insertion: IMMEDIATELY AFTER `_resolve_artifacts_dir() { printf '%s' "$_RENDER_ARTIFACTS_DIR"; }` at line 283, BEFORE `_resolve_learned_rules_dir()` at line 284. Content anchor: `_resolve_artifacts_dir() { printf '%s' "$_RENDER_ARTIFACTS_DIR"; }`.
- `[verified]` `bin/render-prompt.sh:93-126` — `_write_rendered_paths_sidecar` enumerates path-shaped resolvers explicitly. **NOT modified** by this plan — the new `{review_converge_rounds}` resolver returns an integer (data, not a path), so it does not belong in the sandbox-denial detective surface (D-010 ENG-156 D-004 compliance).
- `[verified]` `bin/common.sh:1130-1133` — `config_get` reads `$CONFIG` JSON via `jq -r`; missing key returns `"null"`. The new resolver uses this helper exactly like `bin/guards.sh::check` reads thresholds. Content anchor: `config_get() {`.
- `[verified]` `bin/review-ledger-schema.sh:1-63` — header comment carries the canonical schema-v1 row shape and severity-ladder + critical-floor rules. New schema-grace + blocks_ship/decision_factors/ship_classification_rationale documentation needs to be added in this header (per D-009 + the ENG-190 D-002 SoT pattern). Content anchor: the literal `# Deferred from v1 (per plan Task 2 / brainstorm D-009):`.
- `[verified]` `bin/review-ledger-schema.sh:89-95` — `sanitise_for_diag` strips `\n`/`\r` and rewrites `<!-- → <\!--`. Applies unchanged to the new `ship_classification_rationale` interpolation (D-009 + ENG-190 D-009 SoT). Content anchor: `sanitise_for_diag() {`.
- `[verified]` `bin/review-ledger-schema.sh:123-148` — `cmd_validate` accepts `--ident`, `--dispatch-id`, positional `<file>`; the existing `dispatch_id_flag` variable + `dispatch_id_flag_set` are the schema-grace gate primitive. New rule: skip the new `blocks_ship` / `decision_factors` / `ship_classification_rationale` checks when `dispatch_id_flag_set == 0` OR `dispatch_id_flag != row.dispatch_id` (grace for prior-dispatch rows). Content anchor: `dispatch_id_flag_set=0`.
- `[verified]` `bin/review-ledger-schema.sh:303-309` — existing critical-floor block (`cs_val == critical ⇒ dec_val == block AND as_val == critical`). The NEW critical-floor-blocks-ship rule slots IMMEDIATELY AFTER this block (still inside the per-row loop, before the unknown-fields block at line 311) and ALSO gates on `dispatch_id == --dispatch-id` (schema-grace). Content anchor: the line `_emit_incomplete "$line_no" "critical-floor violation: cold=critical but decision=$dec_val adjudicated=$as_val" "$fck"`.
- `[verified]` `bin/review-ledger-schema.sh:311-318` — unknown-fields allowlist. The hardcoded list of known fields needs `blocks_ship`, `ship_classification_rationale`, `decision_factors` appended so the validator does not `_warn_unknown` on every well-formed row. Content anchor: the literal `(keys) - ["ledger_schema_version","issue_id","dispatch_id","iteration","created_at","finding_class_key","cold_severity","adjudicated_severity","decision","rationale"]`.
- `[verified]` `bin/run-stage.sh:2331-2347` — post-dispatch hook block for `_validate_review_ledger`. Ends with `esac; fi` on line 2347. The NEW `_post_deferred_majors_comment_if_eligible` arm slots IMMEDIATELY AFTER line 2347 and BEFORE the `_validate_qa_payload` hook at line 2349. Content anchor: the comment block `# ENG-190: review-ledger validator.` and the closing `esac` at line 2346.
- `[verified]` `bin/run-stage.sh:1460-1468` — `_post_review_ledger_halt` shows the canonical halt-comment shape (sanitisation via `${raw//<!--/<\\!--}`, tilde-fence wrap, `bash "$SCRIPT_DIR/linear.sh" add-comment "$ident" "$body" || true`). The new helper `_post_deferred_majors_comment_if_eligible` reuses the sanitisation idiom but emits a NON-HALT post (no `<!-- pipeline: verdict result=halt -->` marker; just a markdown lede + bullets). Content anchor: `_post_review_ledger_halt() {`.
- `[verified]` `bin/run-stage.sh:2244` — `_fresh_marker="$(find_fresh_verdict "$ident" 2>/dev/null || printf '')"` in the pre-existing summary/marker presence check. Demonstrates the read shape the new helper uses. Content anchor: the line `_fresh_marker="$(find_fresh_verdict "$ident" 2>/dev/null || printf '')"`.
- `[verified]` `bin/run-stage.sh:2317-2347` — verifies `_validate_review_payload` invocation is at line 2321 and `_validate_review_ledger` invocation is at line 2339, post_completion_comment is at line 2381 (3-line shift from the brainstorm's cited `1013`/`2321`/`2339`/`2381` thanks to ENG-190 ledger landing). The shift is bounded (≤6 lines); the content anchors in this plan are line-number-independent.
- `[verified]` `bin/linear.sh add-comment --sig` chokepoint — ENG-150 append-only contract per CLAUDE.md "Tool allowlist & probing" section + the existing `bash "$SCRIPT_DIR/linear.sh" add-comment "$ident" --sig "$sig" --body "$comment_body"` usage at `bin/run-stage.sh:432`. The chokepoint also auto-injects `<!-- meta: dispatch id=… stage=… -->` when `PIPELINE_DISPATCH_ID` is set. Content anchor (sample): `bash "$SCRIPT_DIR/linear.sh" add-comment "$issue" --sig "$sig" --body "$comment_body"`.
- `[verified]` `AGENT_PROMPTS.md:1288` — `## 5. Review Agent` H2 header. Section body fenced at line 1290 (opening ` ``` `) and 1672 (closing ` ``` `). Fence count = 2; all this-plan §5 edits stay INSIDE the existing fenced block. No new H2 sections; no new column-0 fences.
- `[verified]` `AGENT_PROMPTS.md:1365-1390` — existing Adjudication block (ENG-190). The new "Deferability adjudication" block — five-question rubric + BLOCK-default fallthrough — slots IMMEDIATELY AFTER the Adjudication block's closing prose at line 1390 and BEFORE the Count-tuple emission block at line 1392. Content anchor: the line `When a class matches a prior `finding_class_key`, REUSE the prior key verbatim.`.
- `[verified]` `AGENT_PROMPTS.md:1392-1404` — Count-tuple emission block (ENG-133 + ENG-190). The NEW third emission line `Deferrable: (deferrable_majors=N, blocking_majors=N)` is appended IMMEDIATELY AFTER the `Adjudicated: (critical=N, major=N, minor=N, nit=N)` line (between the `Adjudicated:` line at 1396 and the explanatory paragraph at 1398). Content anchor: the literal `Adjudicated: (critical=N, major=N, minor=N, nit=N)`.
- `[verified]` `AGENT_PROMPTS.md:1504-1554` — Decision path block. Today: paths A (premise failure), B (changes requested), C (clean). The NEW path D (selective exit) slots IMMEDIATELY AFTER the path C block's closing line at 1554 (`Human approval is collected later, at build's P2 preflight, on the post-QA SHA.`) and BEFORE the prose paragraph at 1556 (`The agent does NOT submit GitHub PR reviews in the APPROVED state...`). The path-B/path-C predicate prose at lines 1506-1514 is also amended to add the path-D + path-B′ predicates. Content anchor for the path-D insertion: the literal `Human approval is collected later, at build's P2 preflight, on the post-QA SHA.`. Content anchor for the predicate edit: the literal `Compute `(critical, major)` from the **`Adjudicated:`` paragraph at lines 1506-1514.
- `[verified]` `AGENT_PROMPTS.md:1565-1646` — Output bullet list. New ledger fields (`blocks_ship`, `ship_classification_rationale`, `decision_factors`) extend the existing "Append one row per finding" bullet at lines 1617-1632. Content anchor: the literal `Each row is one JSON object per line with the required fields per`.
- `[verified]` `AGENT_PROMPTS.md:1648-1671` — Verdict marker block (ENG-54 contract). New path-D bullet slots IMMEDIATELY AFTER the path-C bullet (`bash bin/pipeline.sh event {issue_id} verdict pass --stage reviewing` at line 1653) and BEFORE the path-B bullet (`To loop back to implementing (path B...)` at line 1655). Content anchor: the literal `bash bin/pipeline.sh event {issue_id} verdict pass --stage reviewing` (without `--reason`).
- `[verified]` `bin/agent-prompts-content-test.sh:730-794` — `s5` ENG-190 assertion block (ENG-190-pin-cold-pass-clause through ENG-190-pin-summary-line). The new ENG-191 assertions (per D-008's seven content tests) slot IMMEDIATELY AFTER the existing ENG-190 block. Content anchor: the literal `§5 ENG-190: adjudicator summary one-liner pinned with operator-visibility framing (ENG-190-pin-summary-line)`.
- `[verified]` `bin/pipeline-test.sh:55-77` — existing `cmd_event_verdict` test cases. New ENG-191 cases append AFTER the existing PE-block. Content anchor: any unused PE-token (the plan uses fresh PE-X tokens).
- `[verified]` `bin/render-prompt-test.sh` — exists; resolver-test pattern is documented in plan ENG-190 (Task 5). The new `{review_converge_rounds}` resolver test appends here. Content anchor: file existence verified via `ls bin/render-prompt-test.sh`.
- `[verified]` `bin/run-stage-test.sh` — exists; ENG-190 fixtures landed at the Y-group per plan ENG-190 (Task 7). New ENG-191 fixtures (Z-group: AC #1 deferrable-exit posts, AC #2 mixed → no post + path B, AC #5 critical never exits, sanitisation, regular pass no-post, loopback no-post) append AFTER the Y-group. Content anchor: any unused Z-token.
- `[verified]` `bin/review-ledger-schema-test.sh` — exists; happy-path test patterns landed in ENG-190 (Task 3). New ENG-191 cases (T-block: well-formed major+blocks_ship rows, schema-grace prior-dispatch rows pass without new fields) append AFTER. Content anchor: any unused T-token.
- `[verified]` `bin/review-ledger-schema-adversarial-test.sh` — exists; adversarial-block landed in ENG-190 (Task 4). New ENG-191 adversarial cases AC-AD-{1..9} per D-009 (blocks_ship missing on major row, critical-floor-blocks-ship violation, ship_classification_rationale missing/empty, decision_factors missing/incomplete keys, sanitisation, schema-grace prior-dispatch passes, this-dispatch fails). Content anchor: any unused AC-AD-token.
- `[verified]` `docs/runbooks/recovery.md:773` — existing `## 12. rc=48/49/50 — review-ledger-invalid` section runs from line 773 through ~845. The new §13 (ENG-191 selective exit) appends AFTER §12 and BEFORE `## Quick reference: env var requirement` at line 848. Content anchor: the literal `See `docs/runbooks/review-findings-ledger.md` for the full lifecycle` (last sentence of §12).
- `[verified]` `docs/runbooks/operator-mental-model.md:136-180` — `## §3 — Comment chronology (append-only ledger)` section. The new `deferred-majors/<issue>` grep recipe appends inside §3, AFTER the existing `halt/implementing/ENG-N` recipe at lines 155-165. Content anchor: the literal `dedup key=halt/implementing/ENG-N`.
- `[verified]` `CLAUDE.md:833` — last row of the Failure-mode quick reference table (the ENG-190 `Halt at rc=48/49/50` row). The NEW ENG-191 row appends IMMEDIATELY AFTER line 833 and BEFORE the empty line 834 that closes the table. Content anchor: the literal `the ledger is NOT cleared on resume, so the detective re-halts on the same row until you fix or remove it. |`.
- `[verified]` `learned-rules/harness/project-profile.md:17` — `## Build & test gates` Test command line ends with `bash bin/review-ledger-schema-adversarial-test.sh` (the last chained `&&`). **NOT modified** by this plan — ENG-191 EXTENDS existing sibling test files; no new test files are introduced. The gate command stays unchanged. Same for the implementing/qa tool-allowlist arms at lines 31-87 / 90-141 — every test file ENG-191 extends already enumerated.

### Verified — file / directory existence and absence

- `[verified]` `bin/review-ledger-schema.sh` — EXISTS at HEAD (ENG-190). Extended by Task 2.
- `[verified]` `bin/review-ledger-schema-test.sh` — EXISTS. Extended by Task 3.
- `[verified]` `bin/review-ledger-schema-adversarial-test.sh` — EXISTS. Extended by Task 4.
- `[verified]` `bin/agent-prompts-content-test.sh` — EXISTS. Extended by Task 7.
- `[verified]` `bin/pipeline-test.sh` — EXISTS. Extended by Task 1's sibling test arm.
- `[verified]` `bin/render-prompt-test.sh` — EXISTS. Extended by Task 5.
- `[verified]` `bin/run-stage-test.sh` — EXISTS. Extended by Task 9.
- `[verified]` `docs/runbooks/recovery.md`, `docs/runbooks/operator-mental-model.md`, `CLAUDE.md` — EXIST. Each extended by Task 10.

### Verified — runtime / dependency

- `[verified]` `jq` is required runtime; the new orchestrator helper `_post_deferred_majors_comment_if_eligible` uses `jq` per-row to read this-dispatch `adjudicated_severity == major AND blocks_ship == false` rows from the ledger.

### Assumed — to be verified during implement

- `[assumed]` `_post_deferred_majors_comment_if_eligible` failing to post (Linear API outage) does NOT halt the dispatch — same soft-fail shape as `post_completion_comment`'s `|| true` retry path. Verify against `bin/run-stage.sh`'s post_completion_comment retry pattern during implement; if a different convention applies in ENG-191's slot, the implementer follows it and notes the divergence in the commit message.

## System invariants

- The selective-exit path predicate (Adjudicated critical==0 AND Adjudicated major>0 AND blocking_majors==0 AND convergence_rounds_at_zero_critical >= {review_converge_rounds}) is sourced from agent-emitted prompt counts in §5, NOT from any orchestrator computation. The `Adjudicated major>0` conjunct is load-bearing: without it, Path D and Path C overlap when major==0 (vacuous truth over the empty major set). `verified_by: task:T5`
- The `pass_reasons` registry-by-arm override scopes `ship-with-deferred-majors` to the pass arm only — halt/wait/fail/pivot arms reject the token through `bin/pipeline.sh::_validate_event_payload`'s per-arm override precedence. `verified_by: task:T1`
- Critical-floor-blocks-ship invariant: when `adjudicated_severity == critical AND dispatch_id == --dispatch-id`, `blocks_ship == true` (validator rejects with rc=49 `critical-floor-blocks-ship-violation` otherwise). `verified_by: task:T4`
- Schema-grace clause: prior-dispatch rows (`dispatch_id != --dispatch-id`) are exempt from the new `blocks_ship` / `decision_factors` / `ship_classification_rationale` presence checks. Only this-dispatch rows enforce the ENG-191 contract; prior rows validate under the pre-ENG-191 closed contract. `verified_by: task:T4`
- `decision_factors` closed-vocabulary keys are exactly `{in_changed_code, is_regression, user_visible, reversible_post_ship, has_workaround}` on every this-dispatch row whose `adjudicated_severity ∈ {major, critical}`; missing key halts rc=49 incomplete, unknown key warns and passes. `verified_by: task:T4`
- Path D does NOT bump `review_rejection` (agent skips the `guards.sh bump` step at exit); path B′ (convergence-waiting loopback) ALSO does NOT bump; only path B (real loopback on blocking majors / critical) bumps. `verified_by: task:T5`
- The orchestrator-side `_post_deferred_majors_comment_if_eligible` reads `event.reason` from the `find_fresh_verdict` JSON projection (NOT top-level `reason`, which is hard-wired to `""` for the pass arm at `bin/verdict-handler.sh:241`). `verified_by: task:T7`
- The orchestrator's deferred-majors comment is posted via `bash bin/linear.sh add-comment --sig deferred-majors/<ident>` only — the agent never posts under this sig (defense-in-depth: prompt rule + ENG-87 envelope-validator catches direct API calls; sig-forgery via `bash bin/linear.sh` chokepoint is bounded by the prompt-content test pin in T5 and the runtime duplicate-sig audit signal). `verified_by: task:T5`
- `{review_converge_rounds}` resolver registers in `PROMPT_RESOLVERS` and returns an integer (default 2 on absent/invalid). Render-time validator dies on unknown tokens — the resolver MUST exist before §5 edits land or the planning/implement merge order breaks. `verified_by: task:T2`
- `_post_deferred_majors_comment_if_eligible` runs ONLY on `stage == reviewing AND $event.reason == "ship-with-deferred-majors"`; on a regular pass, a loopback, or a halt, the helper short-circuits and posts nothing. `verified_by: task:T7`
- All six agent-controlled interpolated fields (`finding_class_key`, `ship_classification_rationale`, the five `decision_factors` booleans rendered as strings, `dispatch_id`, `iteration`) are sanitised via the existing `<!-- → <\!--` + `\n,\r → space` pattern before reaching the deferred-majors comment body. `verified_by: task:T7`

## File Structure

### Modified

- `bin/pipeline-events.json` — (a) add new top-level array `"pass_reasons": ["ship-with-deferred-majors"]` AFTER the existing `"verdict_results": [...]` array (anchor: the closing `]` of `verdict_results` on line 9 followed by the `,`; preserve JSON-array trailing-comma discipline); (b) extend `events.verdict.linear_comment.field_registry_by_arm` to add `"pass": { "reason": "pass_reasons" }` IMMEDIATELY BEFORE the existing `"pivot": { ... }` block (anchor: the line `"field_registry_by_arm": {`). Both edits keep field_registry_by_arm a valid JSON object with two arms.
- `docs/pipeline-vocabulary.md` — regenerated artifact (NOT hand-edited); committed alongside the pipeline-events.json change. Generated by `bash bin/generate-vocabulary-doc.sh`.
- `bin/pipeline-test.sh` — append three new fixtures (ENG-191 block) AFTER the existing PE-block: (a) `verdict pass --stage reviewing --reason ship-with-deferred-majors` validates and renders correctly; (b) `verdict pass --stage reviewing --reason unknown-token` is rejected with `registry: 'unknown-token' not in pass_reasons`; (c) `verdict halt --reason ship-with-deferred-majors` is rejected (per-arm override is pass-only; halt arm reads `halt_reasons|wait_reasons` union which does not contain the token).
- `bin/render-prompt.sh` — (a) register `review_converge_rounds=_resolve_review_converge_rounds` in `PROMPT_RESOLVERS` (insertion: IMMEDIATELY AFTER `artifacts_dir=_resolve_artifacts_dir` on line 61, BEFORE the closing `'` on line 62); (b) define `_resolve_review_converge_rounds()` reading `config_get '.human_checkpoints.review_converge_rounds'`, validating integer >= 1, falling back to default `2` on absent/invalid (with stderr `log` warning on the invalid path only). Insertion: IMMEDIATELY AFTER `_resolve_artifacts_dir() { printf '%s' "$_RENDER_ARTIFACTS_DIR"; }` at line 283, BEFORE `_resolve_learned_rules_dir()` at line 284. NO `_RENDER_*` main()-bound global needed (the resolver reads config at render time). NO sidecar entry (non-path token; D-010 / ENG-156 D-004).
- `bin/render-prompt-test.sh` — append one test case: `_resolve_review_converge_rounds` returns `"2"` on absent config, returns the configured integer on a valid integer, returns `"2"` with a warning on a non-integer / `<1` value. Insertion: AFTER any existing resolver test block (alphabetic positioning is acceptable but not required).
- `bin/review-ledger-schema.sh` — extend `cmd_validate`'s per-row loop with four new gated checks (each gate is `[[ "$as_val" ∈ {major, critical} && "$did_val" == "$dispatch_id_flag" ]]` — schema-grace clause):
  - (a) **`blocks_ship` presence + type.** When the gate holds, `.blocks_ship | type == "boolean"`; else rc=49 with diagnostic `blocks_ship-missing-on-blocking-severity: row N: adjudicated=$as_val but blocks_ship type=<x>`.
  - (b) **Critical-floor-blocks-ship extension.** When `as_val == critical AND did_val == dispatch_id_flag`, `blocks_ship == true`; else rc=49 with diagnostic `critical-floor-blocks-ship-violation: row N: adjudicated=critical but blocks_ship=$bs_val`.
  - (c) **`ship_classification_rationale` presence + non-empty.** When the gate holds AND `blocks_ship` is present, `.ship_classification_rationale` is a non-empty string; else rc=49 with diagnostic `ship_classification_rationale must be non-empty string`. Sanitise the value via the existing `sanitise_for_diag` before any diagnostic interpolation.
  - (d) **`decision_factors` presence + closed-vocabulary keys.** When the gate holds AND `blocks_ship` is present, `.decision_factors` is an object with all five required boolean keys (`in_changed_code`, `is_regression`, `user_visible`, `reversible_post_ship`, `has_workaround`); else rc=49 with diagnostic `decision_factors must be object with all five required boolean keys; missing: <comma-list>` (or `wrong type for <key>`).

  Insertion of (a)/(b)/(c)/(d) goes IMMEDIATELY AFTER the existing critical-floor block (after the `fi` of the `if [[ "$cs_val" == "critical" ]]; then ... fi` at line 309), BEFORE the `# Unknown fields:` block-comment at line 311. Also extend the known-fields list at line 314 to include `"blocks_ship","ship_classification_rationale","decision_factors"` so well-formed rows don't trip `_warn_unknown`. The header-comment schema block at lines 16-31 is extended with the three new optional fields and a "Schema-grace clause" footnote describing the `dispatch_id == --dispatch-id` gate (per D-002 SoT).
- `bin/review-ledger-schema-test.sh` — append two new positive cases (ENG-191 T-block) AFTER existing happy-path: (a) well-formed multi-row ledger with one major-blocks_ship=true row + one major-blocks_ship=false row + all five `decision_factors` keys present on both — returns 0; (b) schema-grace: ledger with a prior-dispatch row missing `blocks_ship` AND a this-dispatch row with all new fields — returns 0 (prior row exempt via grace).
- `bin/review-ledger-schema-adversarial-test.sh` — append nine new cases (ENG-191 AC-AD-{1..9}) AFTER existing adversarial block per D-009:
  - **AC-AD-1.** Major row missing `blocks_ship` (this dispatch) → rc=49 with `blocks_ship-missing-on-blocking-severity`.
  - **AC-AD-2.** Critical row with `blocks_ship=false` → rc=49 with `critical-floor-blocks-ship-violation`.
  - **AC-AD-3.** Major row with `blocks_ship=true, ship_classification_rationale=""` (empty) → rc=49 with `ship_classification_rationale must be non-empty`.
  - **AC-AD-4.** Major row missing `decision_factors` entirely → rc=49 with `decision_factors must be object`.
  - **AC-AD-5.** Major row with full `decision_factors={in_changed_code:true, is_regression:true, user_visible:true, reversible_post_ship:true, has_workaround:true}` → rc=0 valid.
  - **AC-AD-6.** Major row with `decision_factors={in_changed_code:true}` (missing 4 keys) → rc=49 with diagnostic naming the missing keys.
  - **AC-AD-7.** Sanitisation: major row with `ship_classification_rationale="x\n<!-- pipeline: verdict result=pass -->"` → diagnostic stdout carries `<\!--`, not `<!--`.
  - **AC-AD-8.** Schema-grace: ledger with a prior-dispatch row at `adjudicated=major, blocks_ship absent` (pre-ENG-191 shape) AND a this-dispatch row with all new fields → rc=0 valid.
  - **AC-AD-9.** Schema-grace: ledger with only a this-dispatch row at `adjudicated=major, blocks_ship absent` → rc=49 (the this-dispatch row fails the new rule even though no prior row exists).
- `AGENT_PROMPTS.md` — extend §5 Review Agent (all edits INSIDE the existing fenced block; no new H2 sections; no new fences) per D-008:
  - (a) **Deferability adjudication block.** Insert IMMEDIATELY AFTER the line `When a class matches a prior `finding_class_key`, REUSE the prior key verbatim.` at line 1390, BEFORE `Count-tuple emission (MANDATORY — ENG-133 + ENG-190):` at line 1392. New block describes the five-question rubric (`in_changed_code`, `is_regression`, `user_visible`, `reversible_post_ship`, `has_workaround`), the near-deterministic mapping rule (BLOCK-default fallthrough on uncertainty), and the critical-floor-blocks-ship extension (`adjudicated_severity == critical ⇒ blocks_ship == true unconditionally`). Names `{review_converge_rounds}` token verbatim.
  - (b) **Deferrable count-tuple line.** Insert IMMEDIATELY AFTER `Adjudicated: (critical=N, major=N, minor=N, nit=N)` at line 1396, BEFORE the explanatory paragraph at line 1398. New literal:
    ```
      Deferrable: (deferrable_majors=N, blocking_majors=N)
    ```
    Document the sum constraint `deferrable_majors + blocking_majors == Adjudicated.major` and that path D / path B / path B′ read from this line.
  - (c) **Decision-path predicate prose update.** Edit the existing paragraph at lines 1506-1514. New mechanical predicates:
    - Path B (changes requested) fires iff `Adjudicated critical > 0 OR blocking_majors > 0`.
    - Path C (clean) fires iff `Adjudicated critical == 0 AND Adjudicated major == 0`.
    - Path D (ship-with-debt) fires iff `Adjudicated critical == 0 AND Adjudicated major > 0 AND blocking_majors == 0 AND convergence_rounds_at_zero_critical >= {review_converge_rounds}`.
    - Path B′ (convergence-waiting) fires iff `Adjudicated critical == 0 AND Adjudicated major > 0 AND blocking_majors == 0 AND convergence_rounds_at_zero_critical < {review_converge_rounds}`.
    Compute `convergence_rounds_at_zero_critical` from the ledger: count consecutive prior-dispatch iterations (descending from most-recent) whose rows all have `cold_severity != critical`, PLUS 1 if this dispatch's cold critical == 0.
  - (d) **Path D block.** Insert IMMEDIATELY AFTER the path C block's closing prose at line 1554, BEFORE the paragraph beginning `The agent does NOT submit GitHub PR reviews in the APPROVED state` at line 1556. The block:
    > D. Ship with deferred majors (mechanical: Adjudicated critical == 0 AND Adjudicated major > 0 AND blocking_majors == 0 AND convergence_rounds_at_zero_critical >= {review_converge_rounds}).
    >   - Post a consolidated COMMENTED-state review with all findings via `gh pr review {pr_number} --comment --body "<full summary>"`. Summary line: "Reviewed commit {sha[:8]}. N personas: PASS. 0 critical, M major adjudged deferrable (shipping with debt)." Followed by severity-prefixed bullets for each deferrable major + minor/nit observations.
    >   - Post Linear consolidated review summary via `add-comment --sig completion/reviewing/{issue_id}`. Include the Adjudicator summary line (ENG-190) AND a new ship-with-debt summary line: "Ship-with-debt: M deferrable major(s) recorded; orchestrator will post deferred-majors comment under sig deferred-majors/{issue_id}." Do NOT post the deferred-majors comment yourself; the orchestrator owns that write.
    >   - Write the stage summary file at `{stage_summary_path}` per the Stage summary comment format contract.
    >   - Write the dimension-scoring payload at `{verdict_review_path}` (verdict="approve").
    >   - Append one row per finding to `{review_ledger_path}` via `Edit` with the seed-header line as the anchor; emit `blocks_ship`, `ship_classification_rationale`, `decision_factors` on every major/critical row (D-002).
    >   - Append a `progress.md` entry at `{progress_md_path}` (path D is a clean-exit shape; same conventions as path C).
    >   - Run: `bash bin/pipeline.sh event {issue_id} verdict pass --stage reviewing --reason ship-with-deferred-majors`.
    >   - Exit. Orchestrator transitions `reviewing → qa`, applies pipeline:halted (ENG-56), AND posts the deferred-majors comment under sig `deferred-majors/{issue_id}` via its post-dispatch hook.
  - (e) **Path B′ block.** Insert IMMEDIATELY AFTER path D's "Exit. ..." line, BEFORE the paragraph beginning `The agent does NOT submit GitHub PR reviews in the APPROVED state`. The block:
    > B′. Convergence-waiting loopback (mechanical: Adjudicated critical == 0 AND Adjudicated major > 0 AND blocking_majors == 0 AND convergence_rounds_at_zero_critical < {review_converge_rounds}).
    >   - Mechanically identical to path B in EVERY step EXCEPT: do NOT run `bash .pipeline/bin/guards.sh bump {issue_id} review_rejection --reason "..."` (the review-rejection counter is reserved for genuine blocking findings; convergence-waiting iterations must not burn the implementer's loopback budget).
    >   - Same verdict marker shape as path B: `bash bin/pipeline.sh event {issue_id} verdict fail --target implementing`.
    >   - Exit. Orchestrator transitions `reviewing → implementing` exactly like path B.
  - (f) **Output bullet ledger-row extension.** Edit the existing "Append one row per finding to `{review_ledger_path}`" bullet at lines 1617-1632. Extend the per-row required-fields list:
    > Each row's required fields per `bin/review-ledger-schema.sh`'s header comment: `ledger_schema_version: 1`, `issue_id: "{issue_id}"`, `dispatch_id: "{dispatch_id}"`, `iteration` (computed in the Findings ledger step), `created_at` (ISO-8601 UTC), `finding_class_key` (stable, reused for prior matches), `cold_severity`, `adjudicated_severity`, `decision`, `rationale` (≤280 char soft cap). **On every row whose `adjudicated_severity ∈ {major, critical}`, ALSO emit: `blocks_ship` (boolean — per D-002), `ship_classification_rationale` (non-empty string naming the BLOCK pattern or the DEFER rubric category that justifies the decision), `decision_factors` (object with all five required boolean keys: `in_changed_code`, `is_regression`, `user_visible`, `reversible_post_ship`, `has_workaround`).** Critical-floor-blocks-ship invariant: `adjudicated_severity == critical ⇒ blocks_ship == true`; the validator halts with `critical-floor-blocks-ship-violation` rc=49 on any critical row with `blocks_ship != true`.
  - (g) **Verdict marker block path-D bullet.** Insert IMMEDIATELY AFTER the existing path-C verdict-marker line at line 1653 (`bash bin/pipeline.sh event {issue_id} verdict pass --stage reviewing`), BEFORE the path-B verdict-marker bullet at line 1655. New bullet:
    > To ship with deferred majors (path D — Adjudicated critical=0, all adjudicated majors deferrable, convergence rounds satisfied):
    >
    >   bash bin/pipeline.sh event {issue_id} verdict pass --stage reviewing --reason ship-with-deferred-majors
- `bin/agent-prompts-content-test.sh` — append seven new §5 assertions AFTER the ENG-190 block (after `ENG-190-pin-summary-line` at line 794, before whatever comes next):
  - **ENG-191-pin-deferrable-count-tuple:** `s5` contains literal `Deferrable: (deferrable_majors=N, blocking_majors=N)`.
  - **ENG-191-pin-five-question-rubric:** `s5` contains all five literal tokens `in_changed_code`, `is_regression`, `user_visible`, `reversible_post_ship`, `has_workaround` (positive `grep -qF` on each).
  - **ENG-191-pin-block-default-fallthrough:** `s5` contains literal `when uncertain` AND `BLOCK` AND (a phrase like `BLOCK on uncertainty` or `Deferral requires positive justification`) signalling the asymmetric default.
  - **ENG-191-pin-path-d-predicate:** `s5` contains literal `Adjudicated critical == 0 AND Adjudicated major > 0 AND blocking_majors == 0 AND convergence_rounds_at_zero_critical >= {review_converge_rounds}`.
  - **ENG-191-pin-path-d-verdict-command:** `s5` contains literal `bash bin/pipeline.sh event {issue_id} verdict pass --stage reviewing --reason ship-with-deferred-majors`.
  - **ENG-191-pin-agent-no-deferred-majors-post:** `s5` contains literal `Do NOT post the deferred-majors comment yourself; the orchestrator owns that write.` (defends AC #4 — envelope-validator alignment).
  - **ENG-191-pin-path-b-prime-bump-elision:** `s5` contains literal `Convergence-waiting loopback` AND literal `do NOT run `bash .pipeline/bin/guards.sh bump` (sub-variant path B′ semantics pinned at edit time).
  - **ENG-191-pin-review-converge-rounds-token:** `s5` references the literal `{review_converge_rounds}` token at least twice (predicate prose + path-D block).
- `bin/run-stage.sh` — (a) define new helper `_post_deferred_majors_comment_if_eligible(ident)` IMMEDIATELY AFTER the closing brace of `_post_review_ledger_halt()` at line 1468, BEFORE the `# ENG-117: qa-payload validator.` block-comment at line 1470. Helper:
  - Reads `find_fresh_verdict "$ident"`; jq-extracts `event.reason`. Short-circuits return 0 when `event.reason != "ship-with-deferred-majors"`.
  - Reads `$(issue_dir <ident>)/review-findings-ledger.jsonl` line-by-line (skip `#`-prefix lines); jq-filters rows where `dispatch_id == $PIPELINE_DISPATCH_ID AND adjudicated_severity == "major" AND blocks_ship == false`.
  - For each matching row, interpolates six agent-controlled fields after sanitisation (`<!-- → <\!--` + `\n,\r → space`): `finding_class_key`, `ship_classification_rationale`, the five `decision_factors` booleans (rendered as `yes`/`no`), `dispatch_id`, `iteration`. Per-row body shape:
    > - [major] `<sanitised finding_class_key>`
    >   Rationale: `<sanitised ship_classification_rationale>`
    >   Decision factors:
    >     - in_changed_code: `<yes|no>`
    >     - is_regression: `<yes|no>`
    >     - user_visible: `<yes|no>`
    >     - reversible_post_ship: `<yes|no>`
    >     - has_workaround: `<yes|no>`
    >   Ledger row: dispatch_id=`<sanitised dispatch_id>` iteration=`<sanitised iteration>`
  - Composes the full body with a fixed-prose lede line `Review took the selective exit (ENG-191). <N> major finding(s) deferred as known debt.` and a fixed-prose footer line `ENG-193 will auto-create follow-up tickets per deferred major.` (per brainstorm §7 OQ-4).
  - Posts via `bash "$SCRIPT_DIR/linear.sh" add-comment "$ident" --sig "deferred-majors/$ident" --body "$body" || log "[deferred-majors] post failed for $ident; ledger remains canonical record"` (soft-fail; non-blocking).
  
  (b) Wire the helper into `main()`'s post-dispatch hook section: insertion IMMEDIATELY AFTER the existing `_validate_review_ledger` block closing on line 2347 (the `fi` after the `esac`), BEFORE the qa-payload validator's block-comment `# ENG-117: qa-payload validator.` at line 2349. New block:
  ```
  # ENG-191: post-dispatch deferred-majors enumeration. Reviewing stage only.
  # Reads the fresh verdict marker; when event.reason == ship-with-deferred-majors,
  # enumerates this-dispatch ledger rows with adjudicated=major + blocks_ship=false
  # and posts ONE markdown bullet comment under sig deferred-majors/<ident>.
  # Soft-fail; never halts the dispatch (ledger remains the canonical record).
  if (( ! skip_dispatch )); then
    case "$stage" in
      reviewing)
        _post_deferred_majors_comment_if_eligible "$ident" || true
        ;;
    esac
  fi
  ```
- `bin/run-stage-test.sh` — append six new fixtures (ENG-191 Z-block) AFTER any existing Y-block (ENG-190 fixtures):
  - **Z1 (AC #1, deferrable-only exit):** fixture with verdict marker `<!-- pipeline: verdict result=pass stage=reviewing reason=ship-with-deferred-majors -->` (auto-injected dispatch marker matches current); ledger has one prior-dispatch row at `adjudicated=major, decision=carry, blocks_ship=false` (or absent — exempt by grace) AND one this-dispatch row at `adjudicated=major, blocks_ship=false, decision_factors={...}, ship_classification_rationale="doc-drift polish"`. Assert `_post_deferred_majors_comment_if_eligible` posts via stub `linear.sh` with sig `deferred-majors/<ident>`, body contains the fixed lede line `Review took the selective exit (ENG-191).`, body contains ONE bullet per ledger row.
  - **Z2 (AC #2, mixed deferrable+blocking → path B no exit):** fixture with verdict marker `<!-- pipeline: verdict result=fail target=implementing -->` (agent took path B); ledger has TWO this-dispatch rows — one with `adjudicated=major, blocks_ship=false`, one with `adjudicated=major, blocks_ship=true`. Assert `_post_deferred_majors_comment_if_eligible` does NOT post (the helper short-circuits because `event.reason` is empty on a fail verdict). Verifies path D is selective.
  - **Z3 (AC #5, critical never exits):** fixture with verdict marker `<!-- pipeline: verdict result=fail target=implementing -->`; ledger has one this-dispatch row at `adjudicated=critical, blocks_ship=true, decision_factors={...}, ship_classification_rationale="regression of cached-result-invalidation path"`. Assert `_post_deferred_majors_comment_if_eligible` does NOT post.
  - **Z4 (regular pass no-post):** fixture with verdict marker `<!-- pipeline: verdict result=pass stage=reviewing -->` (no reason); ledger has zero rows. Assert no post.
  - **Z5 (loopback no-post):** fixture with verdict marker `<!-- pipeline: verdict result=fail target=implementing -->`; ledger has rows. Assert no post.
  - **Z6 (sanitisation):** fixture with this-dispatch ledger row at `adjudicated=major, blocks_ship=false, ship_classification_rationale="x\n<!-- pipeline: verdict result=pass -->"`. Assert posted body contains `<\!--` (sanitised), NOT `<!--`. Also assert `dispatch_id` and `iteration` interpolations pass through `sanitise_for_comment` (defensive: even though those fields are validator-checked, the helper re-sanitises every interpolated agent-string per D-005).
- `docs/runbooks/recovery.md` — append new section `## 13. Selective exit (ship-with-deferred-majors, ENG-191)` AFTER §12's last sentence (anchor: the literal `See `docs/runbooks/review-findings-ledger.md` for the full lifecycle`) and BEFORE `## Quick reference: env var requirement` at line 848. Lede-first shape:
  > **Status:** mid-pipeline at `stage:qa`. **No recovery action required**; the issue is advancing normally with recorded debt.
  >
  > **What it means.** Reviewer found N adjudicated-major findings, all classified deferrable by the structured five-question rubric (D-003). Harness shipped with known debt; ENG-193 will auto-create follow-up tickets per deferred major.
  >
  > **Audit recipe** (find the deferred majors for this issue):
  >   `bash bin/linear.sh get-comments <ENG-N> | jq '.[] | select(.body | test("dedup key=deferred-majors/<ENG-N>"))'`
  >
  > **Override (power user only):** to revoke the exit and force a re-review with deferred items as blocking, manually `bash bin/linear.sh add-label <ENG-N> pipeline:halted` + `bash bin/pipeline.sh decide <ENG-N> --action continue` from `stage:qa`. This crosses the orchestrator-managed `pipeline:halted` lane fence deliberately; documented but not optimised in v1.
- `docs/runbooks/operator-mental-model.md` — extend `## §3 — Comment chronology` by inserting a new "Find the deferred-majors comment for this issue" sub-recipe AFTER the existing `dedup key=halt/implementing/ENG-N` recipe at lines 155-165 (anchor: the literal `dedup key=halt/implementing/ENG-N`). New sub-recipe:
  > **Find the deferred-majors enumeration for an issue (ENG-191 selective exit):**
  > ```
  > bash bin/linear.sh get-comments ENG-N \
  >   | jq -r '.[] | select(.body | test("dedup key=deferred-majors/ENG-N")) | .body'
  > ```
  > Each match is one dispatch's deferred-majors comment; multi-dispatch issues accumulate one comment per ship-with-deferred-majors exit.
- `CLAUDE.md` — append one new row to the Failure-mode quick reference table AFTER line 833 (the ENG-190 `Halt at rc=48/49/50` row) and BEFORE the empty line 834 that closes the table. Row body:
  > | Issue at `stage:qa` with verdict comment `reason=ship-with-deferred-majors` and a fresh `deferred-majors/<ENG-N>` Linear comment | Selective exit (ENG-191) — no recovery needed; deferred-majors audit + power-user override in `docs/runbooks/recovery.md` §13. |

### New

(none — ENG-191 extends existing files only; no new test files, no new helper scripts, no new runbooks. The orchestrator helper `_post_deferred_majors_comment_if_eligible` is a new function inside an existing file.)

## API Contract

No new API surface. ENG-191 is a harness-internal change: bash + jq orchestration only. No FE↔BE handler, no protobuf, no JSON-over-HTTP route. The on-disk JSONL row schema (extended in `bin/review-ledger-schema.sh`'s header comment) and the Linear-comment marker shape (extended in `bin/pipeline-events.json::pass_reasons` + `field_registry_by_arm.pass.reason`) are the contracts — both live in their respective source-of-truth files per the ENG-190 / ENG-115 precedents.

## Backend Tasks

### Task 1: Register `pass_reasons` and the `field_registry_by_arm.pass.reason` override; regenerate vocabulary; add sibling pipeline-test fixtures

- `depends_on: []`
- `touches: bin/pipeline-events.json, docs/pipeline-vocabulary.md, bin/pipeline-test.sh`

- [ ] In `bin/pipeline-events.json`, AFTER the existing `"verdict_results": [...]` array (anchor: the line `"verdict_results": [`), insert a new top-level array `"pass_reasons": ["ship-with-deferred-majors"]`. Preserve JSON-array trailing-comma discipline (comma after `verdict_results`'s closing `]`, comma after `pass_reasons`'s closing `]`).
- [ ] In `bin/pipeline-events.json`, INSIDE the existing `events.verdict.linear_comment.field_registry_by_arm` object (anchor: the literal `"field_registry_by_arm": {`), insert `"pass": { "reason": "pass_reasons" }` as a SIBLING entry to the existing `"pivot": { ... }` entry, IMMEDIATELY BEFORE the `"pivot":` line. Preserve JSON-object trailing-comma discipline.
- [ ] Run `bash bin/generate-vocabulary-doc.sh` from the repo root to regenerate `docs/pipeline-vocabulary.md`; stage the regenerated artifact.
- [ ] In `bin/pipeline-test.sh`, AFTER the existing `PE7g` test block (anchor: the line `[[ "$out" == *"--reason required"* ]] && pass_at "PE7g`), append three new fixtures using fresh PE-tokens (e.g. `PE-191A`, `PE-191B`, `PE-191C`):
  - `PE-191A`: `run_pipe event ENG-191-A verdict pass --stage reviewing --reason ship-with-deferred-majors` exits 0 AND stdout body contains `reason=ship-with-deferred-majors`.
  - `PE-191B`: `run_pipe event ENG-191-B verdict pass --stage reviewing --reason unknown-token 2>&1 || true` exits non-zero AND stderr contains `not in pass_reasons`.
  - `PE-191C`: `run_pipe event ENG-191-C verdict halt --reason ship-with-deferred-majors 2>&1 || true` exits non-zero AND stderr contains `not in halt_reasons` (or the `halt_reasons|wait_reasons` union message — pipeline.sh's exact wording).

### Task 2: Add `{review_converge_rounds}` resolver

- `depends_on: []`
- `touches: bin/render-prompt.sh, bin/render-prompt-test.sh`

- [ ] In `bin/render-prompt.sh`, register the new resolver in `PROMPT_RESOLVERS`. Insertion: IMMEDIATELY AFTER the line `artifacts_dir=_resolve_artifacts_dir` (anchor) inside the multi-line single-quoted block, BEFORE the closing `'` of `PROMPT_RESOLVERS`. New line:
  ```
  review_converge_rounds=_resolve_review_converge_rounds
  ```
- [ ] In `bin/render-prompt.sh`, define `_resolve_review_converge_rounds()`. Insertion: IMMEDIATELY AFTER the line `_resolve_artifacts_dir() { printf '%s' "$_RENDER_ARTIFACTS_DIR"; }` (anchor), BEFORE `_resolve_learned_rules_dir()`. Body:
  ```bash
  _resolve_review_converge_rounds() {
    # ENG-191 D-010: config-driven convergence-rounds gate for path-D
    # (ship-with-deferred-majors). Default 2 (lowest defensible plateau);
    # operators tune via .pipeline-config/config.json::human_checkpoints
    # .review_converge_rounds. Invalid (non-integer / <1) logs warn and
    # falls back; absent is silent (absent != invalid).
    local n
    n="$(config_get '.human_checkpoints.review_converge_rounds' 2>/dev/null || printf '')"
    if [[ -n "$n" && "$n" != "null" && "$n" =~ ^[0-9]+$ && "$n" -ge 1 ]]; then
      printf '%s' "$n"
    else
      [[ -n "$n" && "$n" != "null" ]] && log "[render] review_converge_rounds invalid value '$n'; falling back to default 2" >&2 || true
      printf '2'
    fi
  }
  ```
- [ ] Do NOT add a `_RENDER_REVIEW_CONVERGE_ROUNDS` main()-bound global. The resolver reads config at render time directly (the value is data, not a path).
- [ ] Do NOT add a sidecar entry in `_write_rendered_paths_sidecar` — the token resolves to an integer, not a path (D-010 / ENG-156 D-004 closed allowlist).
- [ ] In `bin/render-prompt-test.sh`, append a sibling test for the new resolver. Three cases:
  - **default-on-absent:** with `human_checkpoints` absent from `$CONFIG`, the resolver returns `"2"`, stderr is empty.
  - **valid-integer:** with `.human_checkpoints.review_converge_rounds = 3`, the resolver returns `"3"`.
  - **invalid-fallback:** with `.human_checkpoints.review_converge_rounds = "abc"`, the resolver returns `"2"` AND stderr contains `invalid value 'abc'; falling back to default 2`.

### Task 3: Extend `bin/review-ledger-schema.sh` per-row validation with `blocks_ship` / `ship_classification_rationale` / `decision_factors` rules + critical-floor-blocks-ship + schema-grace clause

- `depends_on: []`
- `touches: bin/review-ledger-schema.sh`

- [ ] In `bin/review-ledger-schema.sh`, extend the header comment block. Insertion: IMMEDIATELY AFTER the existing critical-floor rule paragraph (anchor: the literal `No exceptions. The adjudicator may never downgrade a critical.` on line 38), BEFORE the seed-header paragraph at line 40. New paragraph documents the three new optional fields (`blocks_ship`, `ship_classification_rationale`, `decision_factors`), the closed-vocabulary keys of `decision_factors` (the five booleans), the critical-floor-blocks-ship extension, and the schema-grace clause (`dispatch_id == --dispatch-id` gate).
- [ ] In `bin/review-ledger-schema.sh::cmd_validate`, INSIDE the per-row loop, IMMEDIATELY AFTER the existing critical-floor block's closing `fi` (anchor: the line `_emit_incomplete "$line_no" "critical-floor violation: cold=critical but decision=$dec_val adjudicated=$as_val" "$fck"`, then the closing `fi`s — find the unique block boundary), BEFORE the `# Unknown fields:` block-comment (anchor: the literal `# Unknown fields: stderr warning, exit 0 path.`), insert the new gated checks. Pseudocode:
  ```bash
  # ENG-191: gated on adjudicated_severity ∈ {major, critical} AND this-dispatch
  # row. Schema-grace clause exempts prior-dispatch rows (dispatch_id != flag).
  if [[ "$as_val" == "major" || "$as_val" == "critical" ]] \
     && [[ -n "$dispatch_id_flag" && "$did_val" == "$dispatch_id_flag" ]]; then
    # (a) blocks_ship: boolean.
    local bs_type bs_val
    bs_type="$(jq -r '.blocks_ship | type' <<<"$line" 2>/dev/null || printf 'missing')"
    bs_val="$(jq -r '.blocks_ship // "MISSING"' <<<"$line" 2>/dev/null || printf 'MISSING')"
    if [[ "$bs_type" != "boolean" ]]; then
      _emit_incomplete "$line_no" "blocks_ship-missing-on-blocking-severity: adjudicated=$as_val but blocks_ship type=$bs_type" "$fck"
      return 49
    fi
    # (b) Critical-floor-blocks-ship: as=critical ⇒ blocks_ship=true.
    if [[ "$as_val" == "critical" && "$bs_val" != "true" ]]; then
      _emit_incomplete "$line_no" "critical-floor-blocks-ship-violation: adjudicated=critical but blocks_ship=$bs_val" "$fck"
      return 49
    fi
    # (c) ship_classification_rationale: non-empty string.
    local scr_type scr_val
    scr_type="$(jq -r '.ship_classification_rationale | type' <<<"$line" 2>/dev/null || printf 'missing')"
    scr_val="$(jq -r '.ship_classification_rationale // "MISSING"' <<<"$line" 2>/dev/null || printf 'MISSING')"
    if [[ "$scr_val" == "MISSING" || "$scr_type" != "string" || -z "$scr_val" ]]; then
      _emit_incomplete "$line_no" "ship_classification_rationale must be a non-empty string, got type=$scr_type" "$fck"
      return 49
    fi
    # (d) decision_factors: object with all five required boolean keys.
    local df_type
    df_type="$(jq -r '.decision_factors | type' <<<"$line" 2>/dev/null || printf 'missing')"
    if [[ "$df_type" != "object" ]]; then
      _emit_incomplete "$line_no" "decision_factors must be object, got type=$df_type" "$fck"
      return 49
    fi
    local missing_keys
    missing_keys="$(jq -r '
      ["in_changed_code","is_regression","user_visible","reversible_post_ship","has_workaround"] as $req
      | ($req - (.decision_factors | keys))
      | join(",")' <<<"$line" 2>/dev/null || printf '')"
    if [[ -n "$missing_keys" ]]; then
      _emit_incomplete "$line_no" "decision_factors missing required keys: $missing_keys" "$fck"
      return 49
    fi
    local wrong_type_keys
    wrong_type_keys="$(jq -r '
      [.decision_factors | to_entries[] | select(.value | type != "boolean") | .key]
      | join(",")' <<<"$line" 2>/dev/null || printf '')"
    if [[ -n "$wrong_type_keys" ]]; then
      _emit_incomplete "$line_no" "decision_factors keys must be boolean; non-boolean: $wrong_type_keys" "$fck"
      return 49
    fi
  fi
  ```
  All agent-controlled string interpolation (`$bs_val`, `$scr_val`, `$missing_keys`, `$wrong_type_keys`, `$fck`) flows through the existing `sanitise_for_diag` via the `_emit_incomplete` helper — no separate sanitisation step needed (the diagnostic emitter already applies it to `$key`; the `<message>` field is interpolated raw, so sanitise the `scr_val` etc. explicitly before passing if any of them carry agent-controlled content. **For safety, the implementer should wrap `$bs_val`, `$scr_val`, `$missing_keys`, `$wrong_type_keys` in `sanitise_for_diag` before interpolation** — the validator's diagnostic line is operator-visible plain text, but Linear-comment posting later could carry the diagnostic through `_post_review_ledger_halt`, and sanitisation there is bulk `<!-- → <\!--` only; defense-in-depth at the diag-emit site is correct).
- [ ] Extend the known-fields allowlist at line 314 (anchor: the literal `(keys) - ["ledger_schema_version",...`) to add `"blocks_ship","ship_classification_rationale","decision_factors"` to the subtraction list so well-formed ENG-191 rows do not trip `_warn_unknown`.

### Task 4: Sibling test extensions for `bin/review-ledger-schema.sh`

- `depends_on: [3]`
- `touches: bin/review-ledger-schema-test.sh, bin/review-ledger-schema-adversarial-test.sh`

- [ ] In `bin/review-ledger-schema-test.sh`, append two new positive cases (ENG-191 T-block) AFTER any existing happy-path test:
  - **T-191-1:** Construct a 2-row ledger with a well-formed seed header. Row 1: `adjudicated=major, blocks_ship=true, ship_classification_rationale="regression of cached-result path", decision_factors={all five booleans}`. Row 2: `adjudicated=major, blocks_ship=false, ship_classification_rationale="doc-drift polish", decision_factors={all five booleans}`. Both carry `dispatch_id == --dispatch-id`. Run `bash bin/review-ledger-schema.sh validate <fixture> --ident ENG-191 --dispatch-id ENG-191-d0001`; assert rc=0 AND stdout contains `review-ledger-valid`.
  - **T-191-2 (schema-grace):** 2-row ledger. Row 1: `adjudicated=major, blocks_ship` absent, `dispatch_id=ENG-191-d0001` (PRIOR dispatch — pre-ENG-191 shape). Row 2: `adjudicated=major, blocks_ship=false, ship_classification_rationale="...", decision_factors={...}, dispatch_id=ENG-191-d0002`. Run with `--dispatch-id ENG-191-d0002`; assert rc=0 (prior row exempt via grace; this-dispatch row passes the new rules).
- [ ] In `bin/review-ledger-schema-adversarial-test.sh`, append nine new cases (ENG-191 AC-AD-{1..9}) AFTER the existing adversarial block. Each case constructs a fixture (one or two rows + the canonical seed header), runs `bash bin/review-ledger-schema.sh validate <fixture> --ident ENG-191 --dispatch-id ENG-191-d0001`, and asserts (rc, stderr/stdout) per the table in File Structure above. Use a shared helper to construct fixtures with the seed header to avoid copy-paste drift.

### Task 5: Author §5 prompt edits in `AGENT_PROMPTS.md` and sibling content-test pins

- `depends_on: [2]`
- `touches: AGENT_PROMPTS.md, bin/agent-prompts-content-test.sh`

- [ ] Apply the §5 edits described in File Structure (Deferability adjudication block, Deferrable count-tuple line, Decision-path predicate update, Path D block, Path B′ block, Output ledger-row extension, Verdict-marker path-D bullet). All edits stay INSIDE the existing fenced block; verify post-edit that `awk '/^```$/{c++} END{print c}' AGENT_PROMPTS.md` is unchanged.
- [ ] After each Edit, sanity-check with `bash bin/render-prompt.sh reviewing ENG-191 'placeholder' '' '' 'placeholder' '' '' '' '' '' >/dev/null` (or the equivalent test-mode invocation per `bin/render-prompt-test.sh`) — render-time validator must not die on unknown tokens. The new `{review_converge_rounds}` token MUST already resolve (Task 2 dependency).
- [ ] In `bin/agent-prompts-content-test.sh`, append the seven new §5 assertions documented in File Structure (ENG-191-pin-* assertions). Insertion: IMMEDIATELY AFTER the existing `ENG-190-pin-summary-line` block (anchor: the literal `§5 ENG-190: adjudicator summary one-liner pinned with operator-visibility framing`). Each assertion is a `grep -qF` against the `s5` capture; failures emit `nope` with the missing literal.

### Task 6: Add orchestrator helper `_post_deferred_majors_comment_if_eligible` and wire into `run-stage.sh::main`

- `depends_on: [1, 3]`
- `touches: bin/run-stage.sh`

- [ ] In `bin/run-stage.sh`, define the new helper function. Insertion: IMMEDIATELY AFTER the closing `}` of `_post_review_ledger_halt()` (anchor: the closing `}` on a line by itself, following the function's `body="$(printf ..."` block ending at line 1467), BEFORE the `# ENG-117: qa-payload validator.` block-comment at line 1470. Helper body shape:
  ```bash
  # ENG-191: post-dispatch deferred-majors enumeration helper. Reviewing
  # stage only. Reads the fresh verdict marker via find_fresh_verdict; when
  # the agent emitted `verdict pass --reason ship-with-deferred-majors`,
  # enumerates this-dispatch ledger rows where adjudicated_severity == major
  # AND blocks_ship == false, formats one markdown bullet per row, posts
  # ONE comment under sig deferred-majors/<ident>. Soft-fail: any failure
  # logs a warning and returns 0; the ledger remains the canonical record.
  # AC #4 (envelope-validator-clean): agent must NOT post under this sig;
  # the orchestrator owns the write. Sanitisation: every agent-controlled
  # interpolated field (finding_class_key, ship_classification_rationale,
  # the five decision_factors booleans, dispatch_id, iteration) is sanitised
  # via `<!-- → <\!--` and `\n,\r → space` (defense-in-depth even though
  # validator-checked at row level — see D-005).
  _post_deferred_majors_comment_if_eligible() {
    local PIPELINE_WRITER=orchestrator
    export PIPELINE_WRITER
    local ident="$1"
    local fresh reason
    fresh="$(find_fresh_verdict "$ident" 2>/dev/null || printf '')"
    [[ -z "$fresh" ]] && return 0
    reason="$(jq -r '.event.reason // ""' <<<"$fresh" 2>/dev/null || printf '')"
    [[ "$reason" == "ship-with-deferred-majors" ]] || return 0
    local ledger
    ledger="$(issue_dir "$ident")/review-findings-ledger.jsonl"
    [[ -f "$ledger" ]] || { log "[deferred-majors] ledger absent at $ledger; skipping post"; return 0; }
    local did="${PIPELINE_DISPATCH_ID-}"
    [[ -n "$did" ]] || { log "[deferred-majors] PIPELINE_DISPATCH_ID unset; skipping post"; return 0; }
    # Per-row sanitiser (line-local; mirrors _post_review_ledger_halt's idiom).
    _san() {
      local raw="$1"
      raw="${raw//$'\n'/ }"
      raw="${raw//$'\r'/ }"
      raw="${raw//<!--/<\\!--}"
      printf '%s' "$raw"
    }
    # Collect matching rows. jq filter selects this-dispatch + adjudicated=major
    # + blocks_ship=false rows. Emits a tab-delimited per-row stream.
    local rows
    rows="$(jq -rc --arg did "$did" '
      select(.dispatch_id == $did)
      | select(.adjudicated_severity == "major")
      | select(.blocks_ship == false)
      | [
          (.finding_class_key // ""),
          (.ship_classification_rationale // ""),
          (.decision_factors.in_changed_code // false),
          (.decision_factors.is_regression // false),
          (.decision_factors.user_visible // false),
          (.decision_factors.reversible_post_ship // false),
          (.decision_factors.has_workaround // false),
          (.dispatch_id // ""),
          (.iteration // 0)
        ] | @tsv' \
      < <(grep -v '^#' "$ledger" | grep -v '^[[:space:]]*$') 2>/dev/null || printf '')"
    # Empty selection: post-dispatch helper still runs but emits a body
    # whose bullet count is 0; operator-visible "wrong" signal per D-006
    # adversarial-agent defense ("deferred-majors comment with 0 bullets").
    local count=0
    local bullets=""
    while IFS=$'\t' read -r fck scr ic isr uv rp hw d_id it; do
      [[ -z "$fck" ]] && continue
      count=$((count+1))
      local yn() { [[ "$1" == "true" ]] && printf 'yes' || printf 'no'; }
      bullets+="$(printf -- '- [major] %s\n  Rationale: %s\n  Decision factors:\n    - in_changed_code: %s\n    - is_regression: %s\n    - user_visible: %s\n    - reversible_post_ship: %s\n    - has_workaround: %s\n  Ledger row: dispatch_id=%s iteration=%s' \
        "$(_san "$fck")" "$(_san "$scr")" \
        "$(yn "$ic")" "$(yn "$isr")" "$(yn "$uv")" "$(yn "$rp")" "$(yn "$hw")" \
        "$(_san "$d_id")" "$(_san "$it")")
  
  "
    done <<< "$rows"
    local body
    body="$(printf 'Review took the selective exit (ENG-191). %s major finding(s) deferred as known debt.\n\n%s\nENG-193 will auto-create follow-up tickets per deferred major.' \
      "$count" "$bullets")"
    bash "$SCRIPT_DIR/linear.sh" add-comment "$ident" \
      --sig "deferred-majors/$ident" --body "$body" \
      || log "[deferred-majors] post failed for $ident; ledger remains the canonical record"
    return 0
  }
  ```
  Implementation notes:
  - `find_fresh_verdict`'s pass-arm projection sets top-level `reason: ""` and stashes the actual reason in `event.reason` (verified at `bin/verdict-handler.sh:241`). The helper MUST read `.event.reason`, NOT `.reason`.
  - The nested `yn()` function inside the while-loop is bash-3.2-safe — but if the implementer hits scoping issues, hoist it to file scope above `_post_deferred_majors_comment_if_eligible`.
  - The `_san` helper is intentionally local-to-function (avoids polluting the file's global namespace with another `sanitise_*` variant; the canonical `sanitise_for_diag` in `bin/review-ledger-schema.sh` is not source-able from `bin/run-stage.sh` because it lives inside a different sourced-once script).
- [ ] In `bin/run-stage.sh::main`, wire the helper into the post-dispatch hook. Insertion: IMMEDIATELY AFTER the closing `fi` of the `_validate_review_ledger` block at line 2347 (anchor: the comment `# ENG-190: review-ledger validator.` at line 2331 and the closing `esac` then `fi` at lines 2346-2347), BEFORE the `# ENG-117: qa-payload validator.` block-comment at line 2349. New block:
  ```bash
  # ENG-191: post-dispatch deferred-majors enumeration. Reviewing stage
  # only. Reads the fresh verdict marker; when event.reason ==
  # ship-with-deferred-majors, enumerates this-dispatch ledger rows with
  # adjudicated=major + blocks_ship=false and posts ONE markdown bullet
  # comment under sig deferred-majors/<ident>. Soft-fail; never halts the
  # dispatch (ledger remains the canonical record). AC #4 envelope-clean:
  # the agent's prompt forbids self-posting; the orchestrator owns this write.
  if (( ! skip_dispatch )); then
    case "$stage" in
      reviewing)
        _post_deferred_majors_comment_if_eligible "$ident" || true
        ;;
    esac
  fi
  ```

### Task 7: `bin/run-stage-test.sh` fixtures for the new orchestrator hook

- `depends_on: [6]`
- `touches: bin/run-stage-test.sh`

- [ ] Append six new fixtures (ENG-191 Z-block) as described in File Structure (Z1 deferrable-only exit, Z2 mixed path B, Z3 critical never exits, Z4 regular pass, Z5 loopback, Z6 sanitisation). Each fixture uses the existing source-and-stub pattern: stub `bin/linear.sh` (assert post body content + sig), construct a per-issue fixture directory with a seed-headed ledger + the appropriate verdict-marker file, invoke `_post_deferred_majors_comment_if_eligible "$ident"`, then assert against the stub's recorded calls. Use the existing `find_fresh_verdict` stub pattern (intercept `linear.sh get-comments` to return canned JSON for the verdict marker).

### Task 8: Documentation — recovery.md §13, operator-mental-model.md §3 sub-recipe, CLAUDE.md row

- `depends_on: []`
- `touches: docs/runbooks/recovery.md, docs/runbooks/operator-mental-model.md, CLAUDE.md`

- [ ] Append `## 13. Selective exit (ship-with-deferred-majors, ENG-191)` to `docs/runbooks/recovery.md` per the lede-first shape documented in File Structure.
- [ ] Append the "Find the deferred-majors enumeration" sub-recipe to `docs/runbooks/operator-mental-model.md::## §3` per the shape documented in File Structure.
- [ ] Append one new row to `CLAUDE.md::## Failure-mode quick reference` per the shape documented in File Structure. Verify the markdown table renders by counting `|` characters on the new row (must be 3: leading + 2 column dividers + trailing — same shape as the existing rows).

## Frontend Tasks

(none — ENG-191 is a harness-internal change; no UI surface.)

## Failure Mode → Test Map

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
|---|---|---|---|---|
| Agent emits `verdict pass --reason ship-with-deferred-majors` and ledger has this-dispatch major+blocks_ship=false rows | Path-D fixture in `run-stage-test.sh` | Orchestrator posts ONE comment under sig `deferred-majors/<ident>`; body contains lede + N bullets + ENG-193 footer | integration | Z1 deferrable-only exit posts deferred-majors comment |
| Agent emits `verdict fail --target implementing` and ledger has mixed deferrable + blocking major rows | Path-B fixture in `run-stage-test.sh` | Orchestrator does NOT post; transition `reviewing → implementing` runs unchanged | integration | Z2 mixed deferrable+blocking → path B no exit |
| Critical row present, agent emits path B (per critical-floor) | Path-B critical fixture | Orchestrator does NOT post deferred-majors (path D never reached) | integration | Z3 critical never takes the exit |
| Agent emits regular `verdict pass --stage reviewing` (no reason) | Path-C fixture | Orchestrator does NOT post deferred-majors (event.reason empty) | integration | Z4 regular pass does not post |
| Agent emits `verdict fail --target implementing` | Loopback fixture | Orchestrator does NOT post deferred-majors | integration | Z5 loopback does not post |
| `ship_classification_rationale` contains `<!--` injection attempt | Sanitisation fixture | Posted body contains `<\!--`, never raw `<!--`; `dispatch_id` and `iteration` interpolations also sanitised | integration | Z6 sanitisation neutralises markers |
| Major row missing `blocks_ship` on this dispatch | Adversarial schema fixture | `bash bin/review-ledger-schema.sh validate` rc=49 with `blocks_ship-missing-on-blocking-severity` | unit | AC-AD-1 blocks_ship missing |
| Critical row with `blocks_ship=false` | Adversarial schema fixture | rc=49 with `critical-floor-blocks-ship-violation` | unit | AC-AD-2 critical-floor violation |
| Major row with `blocks_ship=true, ship_classification_rationale=""` | Adversarial schema fixture | rc=49 with `ship_classification_rationale must be non-empty` | unit | AC-AD-3 empty rationale |
| Major row missing `decision_factors` | Adversarial schema fixture | rc=49 with `decision_factors must be object` | unit | AC-AD-4 decision_factors missing |
| Major row with all five `decision_factors` keys present (truthy / falsy mix) | Happy-path schema fixture | rc=0 | unit | AC-AD-5 / T-191-1 well-formed positive |
| Major row with `decision_factors` missing 4 keys | Adversarial schema fixture | rc=49 naming the missing keys | unit | AC-AD-6 incomplete decision_factors |
| `ship_classification_rationale` contains `\n<!--` injection | Adversarial schema fixture | Validator diagnostic stdout carries `<\!--`, not `<!--` | unit | AC-AD-7 sanitisation |
| Ledger has both pre-ENG-191 (no blocks_ship) and this-dispatch (full new fields) rows | Schema-grace fixture | rc=0; prior row exempt; this-dispatch row passes | unit | AC-AD-8 / T-191-2 schema-grace passes |
| Ledger has only a this-dispatch row missing `blocks_ship` (no prior rows) | Adversarial schema fixture | rc=49 (this-dispatch row fails the new rule even with no prior rows) | unit | AC-AD-9 this-dispatch missing fails |
| `verdict pass --reason ship-with-deferred-majors` against registry | Pipeline fixture | rc=0; body contains `reason=ship-with-deferred-majors` | unit | PE-191A pass+reason valid |
| `verdict pass --reason unknown-token` | Pipeline fixture | rc!=0; stderr `not in pass_reasons` | unit | PE-191B unknown reason rejected |
| `verdict halt --reason ship-with-deferred-majors` (cross-arm leak) | Pipeline fixture | rc!=0; stderr `not in halt_reasons` (or union) | unit | PE-191C per-arm scope |
| `human_checkpoints.review_converge_rounds` absent from config | Render-prompt fixture | Resolver returns `"2"`; no warn | unit | render-prompt default-on-absent |
| `human_checkpoints.review_converge_rounds = 3` | Render-prompt fixture | Resolver returns `"3"` | unit | render-prompt valid integer |
| `human_checkpoints.review_converge_rounds = "abc"` (non-integer) | Render-prompt fixture | Resolver returns `"2"`; stderr `invalid value 'abc'` | unit | render-prompt invalid-fallback |
| AGENT_PROMPTS.md §5 missing the Deferrable count-tuple line | Prompt-content fixture | `bin/agent-prompts-content-test.sh` fails ENG-191-pin-deferrable-count-tuple | unit | ENG-191-pin-deferrable-count-tuple |
| AGENT_PROMPTS.md §5 missing one of the five rubric tokens | Prompt-content fixture | Fails ENG-191-pin-five-question-rubric | unit | ENG-191-pin-five-question-rubric |
| AGENT_PROMPTS.md §5 missing the BLOCK-default fallthrough wording | Prompt-content fixture | Fails ENG-191-pin-block-default-fallthrough | unit | ENG-191-pin-block-default-fallthrough |
| AGENT_PROMPTS.md §5 missing the path-D predicate literal | Prompt-content fixture | Fails ENG-191-pin-path-d-predicate | unit | ENG-191-pin-path-d-predicate |
| AGENT_PROMPTS.md §5 missing the path-D verdict-marker command | Prompt-content fixture | Fails ENG-191-pin-path-d-verdict-command | unit | ENG-191-pin-path-d-verdict-command |
| AGENT_PROMPTS.md §5 missing the "Do NOT post the deferred-majors comment yourself" instruction | Prompt-content fixture | Fails ENG-191-pin-agent-no-deferred-majors-post | unit | ENG-191-pin-agent-no-deferred-majors-post |
| AGENT_PROMPTS.md §5 missing the path-B′ bump-elision instruction | Prompt-content fixture | Fails ENG-191-pin-path-b-prime-bump-elision | unit | ENG-191-pin-path-b-prime-bump-elision |
| AGENT_PROMPTS.md §5 missing the `{review_converge_rounds}` token | Prompt-content fixture | Fails ENG-191-pin-review-converge-rounds-token | unit | ENG-191-pin-review-converge-rounds-token |

## Test Strategy

**Test-gate closure (removed-token sweep).** ENG-191 REMOVES no production tokens. The path-B/path-C predicate WORDING at AGENT_PROMPTS.md:1506-1514 is edited (predicate prose updated to add path D + path B′), but the literal pinning strings asserted by `bin/agent-prompts-content-test.sh:706` (`mechanical: critical == 0 AND major == 0`) and `:713` (`mechanical: critical > 0 OR major > 0`) survive verbatim — those literal phrases continue to appear in the path-C and path-B headers. The cold-pass `Findings:` line (`bin/agent-prompts-content-test.sh:699`) ALSO survives unchanged. No sibling test file outside the File Structure pins a token that the §5 edits remove.

**Test-gate closure (added-side sweep).** ENG-191 creates ZERO new test files; all assertions extend existing siblings (`bin/review-ledger-schema-test.sh`, `bin/review-ledger-schema-adversarial-test.sh`, `bin/agent-prompts-content-test.sh`, `bin/pipeline-test.sh`, `bin/render-prompt-test.sh`, `bin/run-stage-test.sh`) that are already enumerated in `learned-rules/harness/project-profile.md::## Build & test gates`'s chained Test command (line 17) AND in BOTH the implementing/qa arms of `## Tool allowlist`. Therefore `learned-rules/harness/project-profile.md` is NOT in File Structure — the gate command + tool allowlist stay correct without edits. This contrasts with ENG-190's plan, which added three new files (`review-ledger-schema.sh` + sibling tests) and therefore had to extend the gate. ENG-191 extends-only.

**System invariants resolution sweep.** Each `verified_by:` token in the `## System invariants` section resolves either to an existing test assertion (the `bin/agent-prompts-content-test.sh:ENG-190-pin-adjudicated-predicate` reuse) or to a `task:T<N>` whose `touches:` field names a gate-runnable test file:
- T1 → `bin/pipeline-test.sh` ✓
- T2 → `bin/render-prompt.sh`, `bin/render-prompt-test.sh` ✓
- T3 → `bin/review-ledger-schema.sh` (extended; sibling test in T4)
- T4 → `bin/review-ledger-schema-test.sh`, `bin/review-ledger-schema-adversarial-test.sh` ✓
- T5 → `AGENT_PROMPTS.md`, `bin/agent-prompts-content-test.sh` ✓
- T6 → `bin/run-stage.sh` (extended; sibling test in T7)
- T7 → `bin/run-stage-test.sh` ✓
All resolve.

**Unit coverage.**
- Schema validator: AC-AD-1..9 + T-191-1, T-191-2 cover field presence/type, critical-floor-blocks-ship, sanitisation, schema-grace clause, full positive path.
- Resolver: three render-prompt cases cover default/valid/invalid paths.
- Registry: three pipeline-test cases cover per-arm scope (pass accepts, halt rejects, unknown rejects).
- Prompt content: eight content-test pins cover every load-bearing literal in §5.

**Integration coverage.**
- Orchestrator hook: six run-stage-test fixtures cover AC #1 (deferrable exit posts), AC #2 (mixed → path B), AC #5 (critical never exits), regular pass (no post), loopback (no post), sanitisation. The fixtures use the existing source-and-stub pattern; `bin/linear.sh` is stubbed to record post calls.

**Adversarial coverage.**
- The orchestrator hook treats `find_fresh_verdict` returning empty (no marker) as "skip post" — covered implicitly by Z4/Z5 (no `event.reason` field on those verdicts).
- A buggy agent emitting `reason=ship-with-deferred-majors` on a path-B-eligible state is operator-visible: the ledger has zero rows matching `adjudicated=major AND blocks_ship=false` AND `dispatch_id == $PIPELINE_DISPATCH_ID`, so the comment renders with bullet count `0` (per the count loop). The `count=0` literal in the lede is the operator's visible signal that something went wrong. NOT separately tested — the failure mode is bounded and operator-discoverable.

**Smoke coverage.**
- The harness has no language-toolchain smoke step (bash is interpreted). The pre-commit hook (`.githooks/pre-commit`) runs the full `bin/*-test.sh` suite; that's the smoke gate. Plan-stage gate (`bash bin/run-stage.sh ... planning`) does not run tests; the implement stage's gate runs them. No extra smoke layer needed.

**E2E coverage (out-of-scope).** ENG-191 is not exercised end-to-end (no real `claude -p` dispatch in the test suite). The integration fixtures cover orchestrator behaviour against synthesized ledger + verdict-marker inputs; the agent-side behaviour is pinned via prompt-content tests. Full E2E coverage requires a live reviewing dispatch on an issue with deferrable findings — observable only in production.
