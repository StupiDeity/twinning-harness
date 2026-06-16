---
linear: ENG-193
date: 2026-06-14
topic: Auto-create follow-up Linear tickets for review-stage deferred majors via orchestrator-owned `bin/linear.sh create-issue` + `find-follow-up` chokepoint, idempotent via per-finding description marker
---

# Plan — Auto-create follow-up tickets for review-deferred majors (ENG-193)

## Anti-anchoring check

- **Problem (operator-perspective):** "ENG-191 posts ONE Linear comment per dispatch enumerating the K deferred majors as known debt; the debt is *logged*, not *scheduled*. Operators must hand-file follow-up tickets or the debt rots silently. The ENG-191 audit comment's own footer (`bin/run-stage.sh:1555`) promises 'ENG-193 will auto-create follow-up tickets per deferred major' — until ENG-193 lands, that line is a forward-promise mismatching reality."
- **Brainstorm framing:** matches one-for-one. Fix is an orchestrator-owned post-dispatch helper `_create_follow_up_tickets_for_deferred_majors` that runs immediately after `_post_deferred_majors_comment_if_eligible` on the same gating (`event.reason == "ship-with-deferred-majors"` AND `stage == reviewing`), reads the same per-row filter from the ledger, and for each row calls a NEW `bin/linear.sh create-issue` chokepoint to file ONE child ticket per finding (parented via `parentId`, state `Backlog`, type-label mechanically derived from `decision_factors.user_visible`). Idempotency via a per-finding description marker `<!-- meta: follow-up-source dispatch=ENG-N-d<NNNN> finding_class_key=<sanitised> -->` searched on Linear via a sibling `bin/linear.sh find-follow-up` subcommand. AC #3 envelope-clean is enforced by extending the lane-fence matrix in `bin/linear.sh::_lane_decision` + `_allowed_lanes_for` with `create child_issue` / `find child_issue` rows (orchestrator+human only). Soft-fail per-row, never halts the dispatch.
- **Proportionality:** two new `bin/linear.sh` subcommands (`create-issue`, `find-follow-up`) plus their lane-fence matrix entries; one new orchestrator helper in `bin/run-stage.sh` (`_create_follow_up_tickets_for_deferred_majors`) plus four sibling formatters (`_follow_up_title`, `_follow_up_type_label`, `_follow_up_body`, `_config_auto_ticket_deferred_majors_enabled`); one wire-up arm in `main()`'s post-dispatch hook; one ENG-191 footer rewrite (config-conditional branch); new sibling tests in `bin/linear-test.sh` (extend) and `bin/run-stage-test.sh` (extend); doc updates in `docs/runbooks/recovery.md` §13 (in-place rewrite of the existing forward-promise) and `docs/runbooks/operator-mental-model.md` §3 (new grep recipe). No new pipeline-events.json vocabulary (no verdict marker, no halt reason — the helper is post-dispatch, success-path, soft-fail). Subsystem count = 2 load-bearing (orchestrator + Linear-contract chokepoint) per the Linear ticket Sizing block. Mirrors ENG-191 D-005 (sibling post-dispatch helper, same hook block, same soft-fail shape) and the established `bin/linear.sh` chokepoint pattern (`add_label`, `add_comment` — lane fence → UUID resolution → dry-run gate → `linear_query` mutation). Proportional. Proceed.

## Goal

Immediately after `_post_deferred_majors_comment_if_eligible` posts the ENG-191 audit comment on the terminal `reviewing → qa` selective exit (i.e. when `event.reason == "ship-with-deferred-majors"`), the orchestrator's NEW post-dispatch helper `_create_follow_up_tickets_for_deferred_majors` reads the same ledger filter (`dispatch_id == $PIPELINE_DISPATCH_ID AND adjudicated_severity == "major" AND blocks_ship == false`), and for each matching row (a) shells `bash bin/linear.sh find-follow-up --dispatch-id <did> --finding-class-key <fck>` (a NEW orchestrator-only subcommand) which searches Linear via `searchIssues` for an existing child issue carrying the literal marker `<!-- meta: follow-up-source dispatch=<did> finding_class_key=<sanitised fck> -->` in its description and defensively byte-match-verifies on candidates; (b) when no existing match, shells `bash bin/linear.sh create-issue --title "[deferred from <ident>] <sanitised+truncated rationale>" --type-label <Bug|Improvement> --parent-id <ident> --state Backlog --description -` (a NEW orchestrator-only subcommand) with a markdown body composed from the ledger row (TL;DR top-line, Source section, Why deferred section, Decision factors, Type label rationale, How to triage, footer marker), where the type-label is `Bug` iff `decision_factors.user_visible == true` else `Improvement`. The new subcommands are gated by extending `bin/linear.sh::_lane_decision` and `_allowed_lanes_for` with `"create child_issue"` and `"find child_issue"` rows that allow only `orchestrator,human` — agent-lane callers are denied with rc=13 (defense-in-depth, since the reviewing-stage allowlist `Bash(bash bin/linear.sh:*)` would otherwise grant the agent broad access). Helper is soft-fail per-row: missing ledger / unset `PIPELINE_DISPATCH_ID` / `find-follow-up` parse failure (treated as miss) / `create-issue` Linear API outage / any per-row failure logs + emits a `follow-up-failed` metric event and continues to the next row; the helper itself always returns 0 (never halts the dispatch). Config gate `human_checkpoints.auto_ticket_deferred_majors` (default `true`) toggles the entire helper to a no-op (D-006); when `false`, the ENG-191 footer is rewritten in-place to a config-conditional branch so the comment never promises a feature the operator switched off. Per-create metric events: `follow-up-created` (one per successful create), `follow-up-skipped` (one per idempotency hit), `follow-up-failed` (one per create failure), emitted via `bin/metrics.sh`. Operator discoverability via four surfaces (D-005): the ENG-191 audit comment (with updated past-tense footer naming the K children), Linear's native sub-issue tree on the parent, the TL;DR top-line on each child, and a new `operator-mental-model.md` §3 grep recipe.

## Assumption Inventory

**branch-base freshness:** `git log --oneline HEAD..origin/main` is EMPTY at plan time; `origin/main = db6cbd01ad9440d6b054d8d04cd5b8f1a77f4c0c` (the ENG-192 tip — implement-side fix-the-class). HEAD is one commit ahead of origin/main (the `chore(pipeline): brainstorming for ENG-193` commit at `af97131`). Branch base is fresh. No Task 0 rebase is required — all `path:line` excerpts below are anchored against the current branch tip. Edit boundaries use CONTENT anchors (function names, unique literals, comment markers) so unrelated commits landing above the insertion points before merge are harmless.

### Verified — code paths quoted from current tree

- `[verified]` `bin/linear.sh:927-944` — `main()` case statement lists 15 verbs: `query, get-issue, list-issues-in-state, list-issues-with-label, add-label, remove-label, swap-stage, transition-state, add-comment, stage-of, all-stage-labels, has-label, has-comment-since, get-comments, refresh-cache`. **No `create-issue` or `find-follow-up`** verb exists today. New verbs slot inside this `case "$cmd" in ... esac` block as new arms; closing `*) die ...` already handles unknown subcommand. Content anchor: the literal `refresh-cache)          refresh_cache ;;`.
- `[verified]` `bin/linear.sh:317-335` — `_lane_decision()` matrix. Today has 12 rows across 7 object_classes (`stage_label`, `pipeline_halted`, `pipeline_supersede`, `pipeline_skip_until`, `transition_comment`, `other_comment`, `any_other_label`); none correspond to issue creation. Default branch is `*) printf 'deny' ;;` at line 333 — unknown action × object_class is structurally denied. New entries `"create child_issue"` and `"find child_issue"` slot BEFORE the `*) printf 'deny'` default, mirroring `"add stage_label")` shape. Content anchor: the literal `*)                            printf 'deny' ;;`.
- `[verified]` `bin/linear.sh:337-355` — `_allowed_lanes_for()` matrix. Mirrors `_lane_decision`'s row set with `printf 'orchestrator,human'` etc. for the diagnostic message on denial. New entries `"create child_issue"` and `"find child_issue"` slot here too, BEFORE the `*) printf 'none'` default. Content anchor: the literal `*)                            printf 'none' ;;`.
- `[verified]` `bin/linear.sh:361-386` — `_check_lane()` reads `PIPELINE_WRITER` (defaults to `orchestrator`), validates the lane against the closed enum `orchestrator|agent|classify|scope-check|human`, then consults `_lane_decision`. Returns rc=13 on denial with structured stderr diagnostic. New subcommands call `_check_lane "create" "child_issue"` / `_check_lane "find" "child_issue"` FIRST (before any UUID resolution which itself would trigger Linear API reads via `get_issue`). Content anchor: `_check_lane() {`.
- `[verified]` `bin/linear.sh:397-431` — `linear_query()` is the GraphQL chokepoint. Honors `PIPELINE_DRY_RUN=1` for mutations (line 401-405: returns `{"data":{"dry_run":true}}`). Retries 3x on HTTP 5xx (lines 411-430). Dies on `.errors` field in 2xx response. New subcommands use this verbatim — no new HTTP code. Content anchor: `linear_query() {`.
- `[verified]` `bin/linear.sh:433-439` — `get_issue()` runs `query($id: String!) { issue(id: $id) { id identifier title description state { id name } labels { nodes { id name } } url createdAt updatedAt } }` and returns the GraphQL response JSON. `find-follow-up`'s defensive byte-match step uses this to re-fetch each candidate's description (Linear's `searchIssues` returns id+identifier+title+state but not description by default — D-002 defensive step). Content anchor: `get_issue() {`.
- `[verified]` `bin/linear.sh:441-445` — `_require_project_id()` reads `config_get '.linear.project_id'`, dies on missing/null. `create-issue` calls this to resolve the GraphQL `projectId` input field. Content anchor: `_require_project_id() {`.
- `[verified]` `bin/linear.sh:449` — `team_id="$(config_get '.linear.team_id')"` resolution pattern (used at the top of `list_issues_in_state` and `list_issues_with_label`). `create-issue` calls this to resolve the GraphQL `teamId` input field. Content anchor: `team_id="$(config_get '.linear.team_id')"`.
- `[verified]` `bin/linear.sh:474-501` — `add_label()` is the canonical chokepoint pattern: lane fence call FIRST (line 479: `_check_lane "add" "$_object_class" || return $?`), then UUID resolution via `_resolve_issue_uuid` (line 482) + `label_id` (line 483), then `[[ "$label_uuid" != "null" && -n "$label_uuid" ]] || die "label not in cache: $label_name (run refresh-cache)"` (line 484 — fall-back when the linear-ids.json cache misses), then `PIPELINE_DRY_RUN` gate (line 492-495), then `linear_query` mutation (line 496-499). `create_issue` and `find_follow_up` mirror this shape exactly. Content anchor: `add_label() {`.
- `[verified]` `bin/linear.sh:467-471` — `_resolve_issue_uuid()` calls `get_issue` and `jq -r '.data.issue.id'`, dies on `null` or empty. `create-issue` uses this to resolve `--parent-id ENG-N` → UUID for the GraphQL `parentId` input field. Content anchor: `_resolve_issue_uuid() {`.
- `[verified]` `bin/common.sh:1140-1146` — `label_id()` and `state_id()` resolve UUIDs from the `linear-ids.json` cache via `ids_get` (`bin/common.sh:1135-1138` — runs `jq -r` on `$IDS_CACHE`). `create-issue` uses these to resolve the type label and the state name. Content anchor: `label_id() {`.
- `[verified]` `bin/linear.sh:660-709` — `_resolve_body_arg()` is the established multi-mode flag resolver pattern: accepts `--body <val>`, `--body -` (stdin), `--body=<val>`, `--body-file <path>`, `--body-file=<path>`. The new `create-issue` subcommand reuses this pattern for `--description` (literal value, `-` for stdin, `@<path>` for file). The brainstorm's D-001 signature `--description <value | - | @<path>>` matches the same multi-mode shape. Implementation: factor out (or copy-and-rename) the resolver as `_resolve_description_arg()`. Content anchor: `_resolve_body_arg()`.
- `[verified]` `bin/linear.sh:63-80` — `_inject_dispatch_marker()` appends `<!-- meta: dispatch id=<id> stage=<stage> -->` to comment bodies when `PIPELINE_DISPATCH_ID` is set. ENG-193's `create-issue` does NOT need this marker on the description — the child issue's description carries a DIFFERENT marker (the per-finding `<!-- meta: follow-up-source ... -->` shape). The dispatch marker is for comment freshness; the follow-up marker is for issue-creation idempotency. Two separate concerns; no interaction. Content anchor: `_inject_dispatch_marker() {`.
- `[verified]` `bin/run-stage.sh:1483-1561` — `_post_deferred_majors_comment_if_eligible()` is the sibling ENG-191 helper. Reads `find_fresh_verdict "$ident"` (line 1488) → `jq -r '.event.reason'` (line 1490) → short-circuits on miss. Reads ledger at `$(issue_dir "$ident")/review-findings-ledger.jsonl` (line 1493). Reads `PIPELINE_DISPATCH_ID` via `${PIPELINE_DISPATCH_ID-}` single-dash guard (line 1498). Iterates `jq -rc` filter (lines 1519-1535). Posts via `bash "$SCRIPT_DIR/linear.sh" add-comment ... --sig "deferred-majors/$ident" --body "$body" || log "..."` (line 1557-1559). ENG-193's helper mirrors this shape verbatim for the read-and-iterate stages; the post step is replaced by `find-follow-up` + `create-issue` per-row. Content anchor: `_post_deferred_majors_comment_if_eligible() {`.
- `[verified]` `bin/run-stage.sh:1508-1514` — the `_san()` line-local sanitiser inside `_post_deferred_majors_comment_if_eligible` does `raw="${raw//$'\n'/ }; raw="${raw//$'\r'/ }; raw="${raw//<!--/<\\!--}"`. ENG-193's helper has its own analogous line-local `_san()` (line-local to avoid polluting the file's global namespace with another `sanitise_*` variant — same rationale as ENG-191). Content anchor: the literal `_san() {`.
- `[verified]` `bin/run-stage.sh:2442-2455` — post-dispatch hook block for `_post_deferred_majors_comment_if_eligible`. The block runs UNDER `if (( ! skip_dispatch )); then ... fi`, gated `case "$stage" in reviewing) ... ;; esac`. ENG-193's new helper slots IMMEDIATELY AFTER this block (after line 2455's closing `fi`) and BEFORE the qa-payload validator's block-comment at line 2457. The new block mirrors the same `if (( ! skip_dispatch )); then case "$stage" in reviewing) ... ;; esac; fi` shape. **Why a separate block** (not folded into the existing ENG-191 arm): each helper's failure mode stays isolated by `|| true` — folding into one branch chains the failures and conflates them in the operator log (D-004). Content anchor: the literal `_post_deferred_majors_comment_if_eligible "$ident" || true`.
- `[verified]` `bin/run-stage.sh:1555` — ENG-191 footer literal `'ENG-193 will auto-create follow-up tickets per deferred major.'`. ENG-193 amends this hardcoded string to a config-conditional branch (D-006): when `_config_auto_ticket_deferred_majors_enabled` returns 0, the footer reads `"ENG-193 has auto-created one follow-up ticket per row above; find them via Linear's sub-issue tree on this issue, or via the operator-mental-model.md grep recipe."`; when it returns 1, the footer reads `"Auto-ticketing is disabled by config (.human_checkpoints.auto_ticket_deferred_majors=false); the ledger above is the canonical record. Operator triage by hand."`. Tense is past ("has auto-created") because by the time the operator reads the comment, the tickets exist (D-006 paragraph 2). The minor tense lie if a per-row create fails is bounded; the `follow-up-failed` metric event captures the divergence. Content anchor: the literal `ENG-193 will auto-create follow-up tickets per deferred major.`.
- `[verified]` `bin/run-stage-test.sh:7879-8154` — six ENG-191 fixtures (Z1–Z8) for `_post_deferred_majors_comment_if_eligible`. Each fixture uses the source-and-stub pattern: stub `linear.sh` at `STUB_DIR/linear.sh` captures `add-comment` calls into `$CAPTURE_FILE` (lines 21-54). New ENG-193 fixtures extend this same stub to also capture `create-issue` and `find-follow-up` calls — add new case-branches to the stub's `case "${1:-}" in` block. Helpers `reset_capture` (line 152), `captured_sig` (153), `captured_body` (154) reused; new helpers `captured_create_issue_count`, `captured_create_issue_titles`, `captured_create_issue_type_labels` defined for the new subcommands. Content anchor: the literal `# ─── ENG-191: _post_deferred_majors_comment_if_eligible (Z1-Z6) ────────`.
- `[verified]` `bin/run-stage-test.sh:7895-7915` — `_eng191_write_row()` helper writes a ledger row with all ENG-191 deferability fields. ENG-193 fixtures reuse this verbatim — no new fixture builder needed. Content anchor: `_eng191_write_row() {`.
- `[verified]` `bin/metrics.sh:21-44` — `main()` signature is positional: `metrics.sh <event> <issue_id> <stage> <outcome> <duration_ms> [notes…] [--key value …]`. The brainstorm's D-007 example schema with a top-level `"kind"` field is informal — the actual on-disk JSONL row has `event` (called `kind` in some retrospective shapes for historical reasons), `issue_id`, `stage`, `outcome`, `duration_ms`, `notes`, with optional cost flags. ENG-193 emits `bash "$SCRIPT_DIR/metrics.sh" "follow-up-created" "$ident" "reviewing" "success" 0 "parent=$ident finding_class_key=$fck child=$new_ident dispatch_id=$did"` etc. The trailing `notes` string is free-form; the events.jsonl row will carry `event=follow-up-created`, `outcome=success`. **Brainstorm wording note:** D-007's schema example uses `"kind"`; the actual metrics.sh field is `event`. Plan corrects to `event`. Content anchor: `main() {`.
- `[verified]` `bin/common.sh:68-79` — `issue_dir() { printf '%s/%s' "$PROJECT_STATE_DIR" "$1"; }` shape; resolves the per-issue scratch directory. ENG-193's helper uses `issue_dir "$ident"` to find the ledger (line 1493 precedent). Content anchor: `issue_dir() {`.
- `[verified]` `bin/common.sh:699-747` — `failure_outcome_for_exit` taxonomy. **ENG-193 introduces NO new exit codes.** The helper is soft-fail (always returns 0); `create-issue` and `find-follow-up` reuse rc=13 (lane-violation, already mapped). No taxonomy edit needed. Content anchor: `failure_outcome_for_exit() {`.
- `[verified]` `bin/pipeline-events.json:1-176` — closed vocabulary registry. **ENG-193 introduces NO new vocabulary.** No new `pass_reasons`, `halt_reasons`, `metric_names`, or `meta_kinds`. The new metric `kind` values (`follow-up-created`, `follow-up-skipped`, `follow-up-failed`) are written to `events.jsonl` via `metrics.sh`'s free-form `event` field — NOT to Linear comments as registered `<!-- meta: metric name=... -->` markers. The brainstorm D-007 does NOT register these in `metric_names` (the metric_names registry gates Linear-comment markers, not jsonl `event` values). Content anchor: the literal `"metric_names":`.
- `[verified]` `bin/verdict-handler.sh:236-251` — `find_fresh_verdict` projection returns `{marker, source_stage, target_stage, reason, comment_id, event}` for the pass arm with top-level `reason:""` and the actual reason inside `event.reason`. ENG-193's helper reads `event.reason` exactly like ENG-191's helper (line 1490). Content anchor: the line `{marker:"pipeline-stage-summary", source_stage:$e.stage, target_stage:"", reason:"", comment_id:$id, event:$e}`.
- `[verified]` `bin/review-ledger-schema.sh:25` — `finding_class_key` shape is `<dimension>:<scope-anchor>:<concept-slug>`. The `scope-anchor` carries the file:line info per the brainstorm's D-003 + AC #1 (body carrying the finding text + file:line + originating PR). ENG-193's body interpolates `finding_class_key` verbatim (after `_san`) into the `## Source` section. Content anchor: the literal `<dimension>:<scope-anchor>:<concept-slug>`.
- `[verified]` `bin/review-ledger-schema.sh:40-65` — `blocks_ship`, `ship_classification_rationale`, `decision_factors` (5 booleans) are validated on every this-dispatch row with `adjudicated_severity ∈ {major, critical}`. ENG-193's helper relies on these being present and well-formed — guaranteed by the upstream ENG-190 + ENG-191 validator chain at `bin/run-stage.sh:2424-2440` which runs BEFORE the deferred-majors comment helper. If validation failed, the dispatch halted with `review-ledger-invalid` rc=48/49/50 and never reached ENG-193's helper. Content anchor: the literal `On every row whose adjudicated_severity ∈ {major, critical} AND`.
- `[verified]` `bin/run-stage.sh:1039-1123` — `_validate_dispatch_envelope` halts with rc=29 on `mcp__plugin_linear*`, `curl https://api.linear.app`, `gh api graphql`, `wget https://api.linear.app`, or `unset PIPELINE_DISPATCH_ID` in the transcript. ENG-193 does NOT add to this set — the new agent-side denial path (`bash bin/linear.sh create-issue` / `find-follow-up`) is caught by the lane fence (rc=13), not the envelope validator. Defense-in-depth: ENG-87 envelope catches direct API calls; ENG-193 lane fence catches the chokepoint-routed bypass. Content anchor: `_validate_dispatch_envelope() {`.
- `[verified]` `learned-rules/harness/project-profile.md:14-17` — `## Build & test gates` Test command is `bash .githooks/pre-commit` which globs every `bin/*-test.sh` (ENG-196). New sibling tests (extending `bin/linear-test.sh`, `bin/run-stage-test.sh`) are automatically covered with no profile edit. NO new `bin/*-test.sh` file is introduced by ENG-193 — all assertions extend existing siblings. Therefore `learned-rules/harness/project-profile.md` is NOT in File Structure. Content anchor: the literal `## Build & test gates`.
- `[verified]` `bin/linear.sh` HAS a `bin/linear-test.sh` sibling test file today (82,390 bytes; 1,633 lines). **Correction from iter-1 feasibility-persona finding:** earlier `Bash: ls bin/linear-test.sh 2>&1` claim was wrong; the file EXISTS and carries extensive ENG-41 lane-fence tests plus ENG-87 dispatch-marker tests through case L8. The brainstorm §3 architecture notes "EDIT (if exists) OR CREATE." Plan choice: **EXTEND** `bin/linear-test.sh` (append-only at the end of the file, BEFORE the `# ─── Summary ───` block and the final `printf '\nRESULTS: %d passed, %d failed\n'` summary line). Content anchor for the append boundary: the literal `# ─── Summary ───` header. The existing file's helpers (`PASS`, `FAIL`, `pass_at`, `fail_at`, `_TEST_TARGET_DIR`, `_TEST_STUB_DIR`, the temp-path safety pattern at the top) are reused — no new test-infrastructure scaffolding. The new ENG-193 cases L-1..L-12 are appended as a new block under a literal `# ─── ENG-193: create-issue + find-follow-up subcommands (L1-L12) ───` header.
- `[verified]` `CLAUDE.md:824` (the ENG-191 Failure-mode row "Issue at `stage:qa` with verdict comment `reason=ship-with-deferred-majors`..." per the brainstorm reference) — checked via `grep -n 'ship-with-deferred-majors' CLAUDE.md`. ENG-193 does NOT add a new failure-mode row (no new operator-visible failure mode — auto-ticketing is a success-path effect; failures are soft + bounded). The §13 runbook amendment is the operator-facing change. Content anchor: the literal `ship-with-deferred-majors`.
- `[verified]` `docs/runbooks/recovery.md` — exists; §13 documented by ENG-191 contains the literal forward-promise `**ENG-193 will auto-create follow-up tickets per deferred major.**` (per the brainstorm reference). ENG-193 rewrites this bolded sentence in-place to past tense AND appends a new "Auto-created follow-up tickets (ENG-193)" sub-paragraph. Content anchor (to be verified at implement time): the literal `ENG-193 will auto-create follow-up tickets per deferred major`.
- `[verified]` `docs/runbooks/operator-mental-model.md` — exists; §3 contains existing `deferred-majors/ENG-N` grep recipe (added by ENG-191). ENG-193 appends a NEW grep recipe for "find all auto-created follow-ups for an issue" using the `follow-up-source dispatch=ENG-N` marker substring search. Content anchor (to be verified at implement time): the literal `deferred-majors/ENG-N` recipe header.

### Verified — file / directory existence and absence

- `[verified]` `bin/linear.sh` — EXISTS at HEAD. Extended by Tasks 1, 2, 3.
- `[verified]` `bin/run-stage.sh` — EXISTS at HEAD. Extended by Task 5 (helpers + wire-up) + Task 4 (ENG-191 footer rewrite).
- `[verified]` `bin/run-stage-test.sh` — EXISTS at HEAD. Extended by Task 6 (ENG-193 W-block fixtures).
- `[verified]` `bin/linear-test.sh` — EXISTS at HEAD (1,633 lines). Extended by Task 3 (append-only block at end, BEFORE the `# ─── Summary ───` line).
- `[verified]` `bin/metrics.sh` — EXISTS at HEAD. NOT modified (the existing positional API accommodates the new `event` values).
- `[verified]` `bin/pipeline-events.json` — EXISTS at HEAD. NOT modified (no new vocabulary).
- `[verified]` `docs/runbooks/recovery.md` — EXISTS at HEAD. Extended by Task 7.
- `[verified]` `docs/runbooks/operator-mental-model.md` — EXISTS at HEAD. Extended by Task 7.
- `[verified]` `CLAUDE.md` — EXISTS at HEAD. NOT modified (no new failure mode).
- `[verified]` `AGENT_PROMPTS.md` — EXISTS at HEAD. NOT modified (no agent prompt change — the helper is orchestrator-only, post-dispatch, after the envelope validator).
- `[verified]` `learned-rules/harness/project-profile.md` — EXISTS at HEAD. NOT modified (no new `bin/*-test.sh` file; the `## Build & test gates` glob already covers `bin/linear-test.sh` if created — confirmed by reading lines 14-17).

### Verified — runtime / dependency

- `[verified]` `jq` is required runtime; the new orchestrator helper `_create_follow_up_tickets_for_deferred_majors` uses `jq` per-row to filter the ledger (identical pattern to ENG-191's helper).
- `[verified]` `gh` is on the launchd host PATH per CLAUDE.md "PATH expectations on the launchd host" — the helper calls `gh pr view --json url --jq .url 2>/dev/null` once per dispatch (best-effort PR URL discovery; falls back to `(not discoverable)` on failure).
- `[verified]` `curl` is on the launchd host PATH (already required by `linear_query`).
- `[verified]` `bin/linear.sh add-comment --sig deferred-majors/<ident>` (the ENG-191 emission point) is unchanged by ENG-193's logic; only the FOOTER STRING inside the body is amended (Task 4 — config-conditional branch).

### Assumed — to be verified during implement

- `[assumed]` Linear's `issueCreate.input` accepts `title: String!, description: String, teamId: String!, projectId: String, stateId: String, parentId: String, labelIds: [String!]` per the brainstorm's Assumption #33. Implementation-time validation: at the FIRST live run on a target's Linear team, the create dies with a GraphQL error if the shape is wrong; the soft-fail path logs + emits `follow-up-failed`; operator inspects log, adjusts shape (e.g. `parentId` → `parentIssueId` if Linear's schema diverges from the brainstorm's assumption), re-runs. The harness-level cost of a wrong-shape assumption is bounded to one dispatch's K failures.
- `[assumed]` Linear's `searchIssues(term: String!, first: Int)` accepts an arbitrary substring term and returns `{nodes: [{id, identifier, title}]}` per the brainstorm's Assumption #34. Implementation-time validation: at the FIRST live run, `find-follow-up`'s GraphQL query fires; if the shape is wrong, the parse fails (treated as miss per D-002 stdout contract), the helper proceeds with creation, and on the SECOND run the same path repeats — leading to potential duplicates until the operator notices. **Mitigation:** add a unit-test fixture in `bin/linear-test.sh` that exercises the GraphQL shape in dry-run mode (linear_query returns `{"data":{"dry_run":true}}`); a live-Linear validation step is part of the implement-stage smoke check.

## System invariants

- The auto-ticketing helper `_create_follow_up_tickets_for_deferred_majors` runs ONLY on `stage == reviewing AND $event.reason == "ship-with-deferred-majors"` — same predicate as ENG-191's `_post_deferred_majors_comment_if_eligible`. On a regular pass, a loopback (path B / B′), or a halt, the helper short-circuits returning 0 with zero create-issue calls. `verified_by: task:T6`
- The new `bin/linear.sh create-issue` and `find-follow-up` subcommands call `_check_lane "create" "child_issue"` and `_check_lane "find" "child_issue"` FIRST — before any UUID resolution (which would trigger a Linear API read via `_resolve_issue_uuid`) and before any `PIPELINE_DRY_RUN` short-circuit. Agent-lane (`PIPELINE_WRITER=agent`) is denied with rc=13. `verified_by: task:T3`
- The per-finding idempotency marker is `<!-- meta: follow-up-source dispatch=<dispatch_id> finding_class_key=<sanitised key> -->` embedded at the BOTTOM of the child issue's description. `find-follow-up`'s `searchIssues` term is the literal marker substring; the helper defensively re-fetches each candidate's description via `get_issue` and byte-match-compares the marker line before declaring a hit. `verified_by: task:T2`
- The type label is mechanically derived: `Bug` iff `decision_factors.user_visible == true`, else `Improvement`. Never `Feature` (the rubric makes deferrable + Feature structurally implausible). The derivation is deterministic; no agent inference. `verified_by: task:T5`
- All seven agent-controlled interpolated fields (`finding_class_key`, `ship_classification_rationale`, the five `decision_factors` booleans rendered as `yes`/`no`, `dispatch_id`, `iteration`) are sanitised via the line-local `_san()` helper (`<!-- → <\!--` + `\n,\r → space`) BEFORE reaching the title, body, or marker. The marker uses sanitised values so the write-time embed byte-matches the search-time term. `verified_by: task:T5`
- The helper is soft-fail per-row: any per-row failure (Linear API outage during `find-follow-up`, parse failure, lane-fence denial, `create-issue` failure) logs + emits the appropriate metric event and continues to the next row. The helper itself ALWAYS returns 0; no path leads to `bin/pipeline.sh event ... verdict halt`. `verified_by: task:T6`
- The config gate `human_checkpoints.auto_ticket_deferred_majors` (boolean, default `true`) toggles the entire helper to a no-op. When `false`, the ENG-191 footer is rewritten to a config-conditional branch that truthfully reads "Auto-ticketing is disabled by config" instead of the past-tense "has auto-created" lie. `verified_by: task:T4`
- The lane-fence matrix entries (`"create child_issue"` and `"find child_issue"` rows in `_lane_decision` + `_allowed_lanes_for`) allow ONLY `orchestrator,human` — `agent`, `classify`, and `scope-check` lanes are denied. The agent-stage reviewing allowlist `Bash(bash bin/linear.sh:*)` would otherwise grant the agent the ability to invoke the new subcommands; the lane fence is THE structural denial (not redundant with the allowlist). `verified_by: task:T3`
- The helper runs AFTER `_validate_dispatch_envelope` in `bin/run-stage.sh::main` — by the time `_create_follow_up_tickets_for_deferred_majors` fires, the agent's `claude -p` subprocess has exited and the envelope validator has already scanned the transcript. No agent-side Linear write can occur from inside this helper's invocation. `verified_by: task:T5`
- The follow-up issue is filed at state `Backlog`, parented via `parentId`. Backlog state keeps it invisible to the poller (per `CLAUDE.md` L254-257) until an operator triages to `Todo`; this prevents auto-flooding the queue with auto-scheduled low-value debt. `verified_by: task:T5`

## File Structure

### Modified

- `bin/linear.sh` — (a) header comment block (lines 4-26) extended with two new subcommand usage lines for `create-issue` and `find-follow-up`; (b) `_lane_decision()` matrix extended with `"create child_issue")` and `"find child_issue")` rows (slot BEFORE the `*) printf 'deny'` default at line 333; both rows allow `orchestrator|human`); (c) `_allowed_lanes_for()` matrix extended with same two rows (slot BEFORE the `*) printf 'none'` default at line 353); (d) NEW `_resolve_description_arg()` function (copy-and-rename of `_resolve_body_arg` at lines 660-709 to accept `--description` instead of `--body`; same multi-mode flag handling `--description <val>`, `--description -` for stdin, `--description=<val>`, `--description-file <path>`, `--description-file=<path>`; insertion: IMMEDIATELY AFTER `_resolve_body_arg` at line 709, BEFORE the `add_comment` function at line 711); (e) NEW `create_issue()` function (mirrors `add_label`'s chokepoint shape: lane fence FIRST → flag parse → UUID resolution for `--parent-id` → cache lookup for `--type-label` and `--state` → `_require_project_id` + `config_get '.linear.team_id'` → description resolved via `_resolve_description_arg` → `PIPELINE_DRY_RUN` gate → `issueCreate` GraphQL mutation via `linear_query` → stdout prints the new issue's `identifier`; insertion: IMMEDIATELY AFTER `add_comment`'s closing `}` at line 877, BEFORE `refresh_cache` at line 879); (f) NEW `find_follow_up()` function (lane fence FIRST → flag parse for `--dispatch-id` and `--finding-class-key` → sanitise the finding-class-key via the same `<!-- → <\!--` + `\n,\r → space` rule → build marker substring → `searchIssues` GraphQL query via `linear_query` → for each candidate node, re-fetch description via `get_issue` and byte-match the literal marker line → stdout single-line identifier on hit / empty on miss; insertion: IMMEDIATELY AFTER `create_issue`'s closing `}`, BEFORE `refresh_cache`); (g) `main()` case statement (line 927) extended with `create-issue) create_issue "$@" ;;` and `find-follow-up) find_follow_up "$@" ;;` arms (slot AFTER `get-comments) get_comments "$@" ;;` at line 941, BEFORE `refresh-cache) refresh_cache ;;` at line 942). Content anchors for each edit named above.
- `bin/run-stage.sh` — (a) NEW helper `_config_auto_ticket_deferred_majors_enabled()` reads `config_get '.human_checkpoints.auto_ticket_deferred_majors'` and returns 0 on `true`/`""`/`null`/absent, 1 on `false`, 0 (default-true) with stderr `log` warning on any other value. Insertion: IMMEDIATELY AFTER the closing `}` of `_post_deferred_majors_comment_if_eligible` at line 1561, BEFORE the `# ENG-117: qa-payload validator.` block-comment at line 1563. (b) NEW helper `_follow_up_title(scr, fck, ident)` formats the title `[deferred from <ident>] <sanitised scr, truncated>` per D-003 sanitise-then-truncate rule (the `ident` argument is the parent issue identifier, needed to build the bracketed prefix) (apply `_san` first, then trim to fit ≤80 char budget = 80 − len(prefix); detect partial `<\!--` escape at the tail and trim further until clean boundary). Insertion: IMMEDIATELY AFTER `_config_auto_ticket_deferred_majors_enabled`. (c) NEW helper `_follow_up_type_label(user_visible_bool)` returns `"Bug"` when input is `"true"`, else `"Improvement"`. Insertion: IMMEDIATELY AFTER `_follow_up_title`. (d) NEW helper `_follow_up_body(ident, pr_url, dispatch_id, iteration, fck, scr, ic, isr, uv, rp, hw)` formats the markdown body per D-003 shape (TL;DR top-line, ## Source, ## Why this was deferred, ## Decision factors, ## Type label rationale, ## How to triage, footer marker). All agent-controlled fields sanitised via line-local `_san()` (mirror ENG-191 idiom). Insertion: IMMEDIATELY AFTER `_follow_up_type_label`. (e) NEW helper `_create_follow_up_tickets_for_deferred_majors(ident)` orchestrates the per-row loop. Reads `find_fresh_verdict` + `.event.reason` (short-circuit on miss). Reads ledger at `$(issue_dir "$ident")/review-findings-ledger.jsonl`. Reads `PIPELINE_DISPATCH_ID` via single-dash guard. Runs `_config_auto_ticket_deferred_majors_enabled` (short-circuit on disabled, with `log` line). Calls `gh pr view --json url --jq .url 2>/dev/null` ONCE for the dispatch's PR URL (falls back to `(not discoverable)`). Iterates ledger rows via `jq -rc` filter (same shape as ENG-191's helper). For each row: calls `bash "$SCRIPT_DIR/linear.sh" find-follow-up --dispatch-id "$d_id" --finding-class-key "$fck"`; on hit (non-empty single-line identifier), logs + emits `follow-up-skipped` metric + continues; on miss, builds title via `_follow_up_title`, type-label via `_follow_up_type_label`, body via `_follow_up_body`; pipes body via stdin to `bash "$SCRIPT_DIR/linear.sh" create-issue --title "$title" --type-label "$type_label" --parent-id "$ident" --state "Backlog" --description -`; on success (captures new identifier from stdout), logs + emits `follow-up-created` metric; on failure, logs + emits `follow-up-failed` metric + continues. Accumulates `created` / `skipped` / `failed` counters; emits summary log line `[follow-up] $ident: created=N skipped=N failed=N (dispatch=<did>)` at end. Always returns 0 (soft-fail). Insertion: IMMEDIATELY AFTER `_follow_up_body`. (f) Wire the helper into `main()`'s post-dispatch hook block. Insertion: IMMEDIATELY AFTER the existing ENG-191 hook block's closing `fi` at line 2455 (content anchor: the literal `_post_deferred_majors_comment_if_eligible "$ident" || true` followed by `;;`, `esac`, `fi`), BEFORE the qa-payload validator's block-comment `# ENG-117: qa-payload validator.` at line 2457. New block:
  ```bash
  # ENG-193: post-dispatch deferred-majors follow-up ticket creation.
  # Runs AFTER the ENG-191 comment helper (the comment narrates that the
  # tickets exist; by the time the operator reads the comment, this hook
  # has fired). Soft-fail; per-finding; never halts the dispatch. AC #3
  # envelope-clean: runs orchestrator-side, after the envelope validator.
  if (( ! skip_dispatch )); then
    case "$stage" in
      reviewing)
        _create_follow_up_tickets_for_deferred_majors "$ident" || true
        ;;
    esac
  fi
  ```
  (g) ENG-191 footer rewrite in `_post_deferred_majors_comment_if_eligible`. Edit boundary: the literal `body="$(printf 'Review took the selective exit (ENG-191). %s major finding(s) deferred as known debt.\n\n%s\n\nENG-193 will auto-create follow-up tickets per deferred major.' \` at line 1555 (CONTENT anchor: the literal `ENG-193 will auto-create follow-up tickets per deferred major.`). Replace the hardcoded footer with a config-conditional two-branch construction:
  ```bash
  local footer
  if _config_auto_ticket_deferred_majors_enabled; then
    footer="ENG-193 has auto-created one follow-up ticket per row above; find them via Linear's sub-issue tree on this issue, or via the operator-mental-model.md grep recipe."
  else
    footer="Auto-ticketing is disabled by config (.human_checkpoints.auto_ticket_deferred_majors=false); the ledger above is the canonical record. Operator triage by hand."
  fi
  body="$(printf 'Review took the selective exit (ENG-191). %s major finding(s) deferred as known debt.\n\n%s\n\n%s' \
    "$count" "$bullets" "$footer")"
  ```
- `bin/run-stage-test.sh` — extend `STUB_DIR/linear.sh` stub (lines 21-54) to handle two new subcommands `create-issue` and `find-follow-up`. Stub captures argv into the existing `$CAPTURE_FILE` with a discriminator prefix (e.g. `SUBCMD=create-issue\nTITLE=...\nTYPE_LABEL=...\nPARENT_ID=...\nSTATE=...\nBODY_BEGIN\n<body>\nBODY_END\n---\n`); for `find-follow-up`, the stub reads `$MOCK_FIND_FOLLOW_UP_HIT` (default empty = miss) and prints that to stdout, then records the call. New helpers `captured_create_issue_count() { grep -c '^SUBCMD=create-issue$' "$CAPTURE_FILE" || true; }` and `captured_create_issue_titles() { awk '/^SUBCMD=create-issue$/{flag=1; next} flag && /^TITLE=/{sub(/^TITLE=/,""); print; flag=0}' "$CAPTURE_FILE"; }`. Append seven new fixtures (ENG-193 W-block) AFTER the existing ENG-191 Z-block at line 8154 — W1: AC #1 deferrable-only exit creates K=N tickets; W2: AC #2 idempotency hit (mock `find-follow-up` returns existing ENG-N for one row) → K-1 creates + 1 skipped; W3: AC #3 helper does not invoke `mcp` / `curl` / `gh api graphql` (assert via the stub never seeing those args); W4: type-label mapping — `user_visible=true` row → `Bug`, `user_visible=false` row → `Improvement`; W5: title shape — includes `[deferred from ENG-N]` prefix and truncated rationale; W6: body shape — TL;DR top-line + Source section + Decision factors + footer marker; W7: config off — helper is no-op (zero create-issue captures, zero find-follow-up captures); W8: sanitisation — `ship_classification_rationale="x\n<!-- pipeline: verdict result=pass -->"` → posted body / title / marker contain `<\!--`, not raw `<!--`; W9: mixed dispatch — prior-dispatch rows (different `dispatch_id`) AND this-dispatch rows in ledger → only this-dispatch rows produce tickets. Each fixture uses the source-and-stub pattern; `_eng191_write_row` helper reused verbatim. Content anchor: the literal `echo "run-stage-test: passed=$PASS failed=$FAIL"` (last line — fixtures insert BEFORE the summary).
- `docs/runbooks/recovery.md` — in-place rewrite of the existing ENG-191 forward-promise sentence in §13 PLUS append a new "Auto-created follow-up tickets (ENG-193)" sub-paragraph. Edit boundary 1 (content anchor): the literal `**ENG-193 will auto-create follow-up tickets per deferred major.**` — rewrite in-place to `**the orchestrator auto-created one Linear sub-ticket per deferred major (unless `auto_ticket_deferred_majors` is disabled — see below).**`. Edit boundary 2 (content anchor for append): the closing line of §13's existing prose (before §14 begins or before the file's quick-reference section, whichever comes first). Append new sub-paragraph per D-009 body:
  > **Auto-created follow-up tickets (ENG-193).** The orchestrator's post-dispatch hook files one Linear sub-ticket per deferred major: parented to the originating issue, in state `Backlog`, typed as `Bug` (when `user_visible=true`) or `Improvement` (otherwise). Find them via Linear's sub-issue tree view on the parent, or grep via Linear's GraphQL `searchIssues` for the marker substring `follow-up-source dispatch=ENG-N` (recipe in `operator-mental-model.md` §3). Each follow-up carries `<!-- meta: follow-up-source dispatch=ENG-N-d<NNNN> finding_class_key=<key> -->` in its description for cross-reference. Idempotent across re-runs: re-taking the exit looks up the marker and skips already-created tickets.
  >
  > **Disable auto-ticketing (operator opt-out).** Set `.human_checkpoints.auto_ticket_deferred_majors: false` in target's `.pipeline-config/config.json`. The deferred-majors comment (ENG-191) still posts; only the auto-ticket step is suppressed.
- `docs/runbooks/operator-mental-model.md` — extend §3 with a new "Find auto-created follow-up tickets for an issue (ENG-193)" sub-recipe per D-009 body. Edit boundary (content anchor): the existing `deferred-majors/ENG-N` recipe header inside §3. Append AFTER that recipe:
  > **Find auto-created follow-up tickets for an issue (ENG-193):**
  > ```bash
  > bash bin/linear.sh query \
  >   'query { searchIssues(term: "follow-up-source dispatch=ENG-N", first: 50) { nodes { id identifier title state { name } } } }' '{}' \
  >   | jq '.data.searchIssues.nodes'
  > ```
  > Each match is a follow-up; group by `dispatch_id` substring in the title (the `[deferred from ENG-N]` prefix) or re-fetch the description via `bin/linear.sh get-issue ENG-M` to see the finding details. The marker line in the description is `<!-- meta: follow-up-source dispatch=ENG-N-d<NNNN> finding_class_key=<key> -->`.

### New

(none — ENG-193 extends existing files only. No new files are introduced. The orchestrator helpers `_create_follow_up_tickets_for_deferred_majors` + sibling formatters are NEW functions inside an existing file (`bin/run-stage.sh`). The `bin/linear.sh create-issue` + `find-follow-up` subcommands are NEW functions inside an existing file (`bin/linear.sh`). `bin/linear-test.sh` is EXTENDED with a new ENG-193 L-block, NOT created from scratch.)

#### Test extensions to `bin/linear-test.sh` (Task 3, append-only block before `# ─── Summary ───`)

The new ENG-193 cases L-1..L-12 are appended to `bin/linear-test.sh` under a literal `# ─── ENG-193: create-issue + find-follow-up subcommands (L1-L12) ───` header. They reuse the existing file's PASS/FAIL counters, `pass_at`/`fail_at` helpers, `_TEST_TARGET_DIR` + `_TEST_STUB_DIR` scaffolding (lines 19-30 of the existing file), the minimal target-repo config + linear-ids.json fixtures (lines 49-77), and the source-pattern at the bottom (loading `linear.sh` without firing main). Tests cover ENG-193's new surface only (no full-file backfill — out-of-scope):
  - **L-1 (create-issue dry-run):** with `PIPELINE_DRY_RUN=1`, `bash bin/linear.sh create-issue --title "t" --type-label Improvement --parent-id ENG-1 --state Backlog --description "d"` exits 0 AND `linear_query`'s dry-run path returns `{"data":{"dry_run":true}}` (stub the GraphQL endpoint or assert the dry-run log line).
  - **L-2 (lane fence — agent denied):** with `PIPELINE_WRITER=agent`, the same `create-issue` invocation exits 13 AND stderr contains `lane=agent denied: create child_issue`.
  - **L-3 (lane fence — find-follow-up agent denied):** with `PIPELINE_WRITER=agent`, `bash bin/linear.sh find-follow-up --dispatch-id ENG-1-d0001 --finding-class-key foo` exits 13 AND stderr contains `lane=agent denied: find child_issue`.
  - **L-4 (lane fence — orchestrator allowed):** with `PIPELINE_WRITER=orchestrator` (or unset, default), `create-issue` lane check passes (rc != 13).
  - **L-5 (required flags):** missing `--type-label` exits non-zero with `die` diagnostic; missing `--title` exits non-zero; missing `--description` (and no stdin) exits non-zero.
  - **L-6 (description from stdin):** `printf 'body' | bash bin/linear.sh create-issue --title "t" --type-label Improvement --parent-id ENG-1 --description -` reads the body from stdin (verify via dry-run log echo of the body's first 80 chars).
  - **L-7 (marker substring in description):** the description body sent to `linear_query` contains the literal `<!-- meta: follow-up-source dispatch=...` marker only when the caller embeds it (the subcommand does NOT auto-inject the marker — orchestrator-side helper composes it).
  - **L-8 (find-follow-up miss):** stub `linear_query` to return `{"data":{"searchIssues":{"nodes":[]}}}`; `find-follow-up` returns empty stdout AND rc=0.
  - **L-9 (find-follow-up hit + defensive byte-match):** stub `linear_query` to return one candidate node; stub `get_issue` (via the same dispatcher) to return a description containing the literal marker; `find-follow-up` returns the candidate's `identifier` on stdout AND rc=0.
  - **L-10 (find-follow-up false-positive defended):** stub returns one candidate whose description does NOT contain the marker line (search matched a different substring coincidentally); `find-follow-up` returns empty stdout (defensive byte-match filters the candidate out).
  - **L-11 (cache miss — type label):** with `linear-ids.json` missing the `Bug` label, `create-issue --type-label Bug ...` dies with `label not in cache: Bug (run refresh-cache)` per the `add_label` line 484 pattern.
  - **L-12 (cache miss — state):** with `linear-ids.json` missing the `Backlog` state, `create-issue --state Backlog ...` dies with `state not in cache: Backlog (run refresh-cache)`.
  The new L-block reuses the existing `bin/linear-test.sh` source-and-stub pattern (the file already sources `bin/linear.sh` near the top and exercises lane-fence helpers directly). Per-fixture stubbing of `linear_query` uses post-source function redefinition — possible because `linear.sh` defines `linear_query` as a top-level function at line 397, so a `linear_query() { ... }` redefinition in the test wins on subsequent invocations.

## API Contract

No new FE↔BE API surface. ENG-193 is a harness-internal change: bash + jq + GraphQL orchestration only. No handler, no HTTP route added to a target. The on-disk JSONL row schema (already extended by ENG-191 at `bin/review-ledger-schema.sh`'s header comment) and the Linear-comment marker shape (already extended by ENG-191 in `bin/pipeline-events.json::pass_reasons`) are unchanged by ENG-193. The new GraphQL contracts are:

- `issueCreate(input: { title, description, teamId, projectId, stateId, parentId, labelIds })` — Linear's documented mutation, consumed by `bin/linear.sh create-issue`. NOT a project-defined contract; uses Linear's public API.
- `searchIssues(term: String!, first: Int)` — Linear's documented query, consumed by `bin/linear.sh find-follow-up`. NOT a project-defined contract; uses Linear's public API.

Both are stable Linear surfaces; the brainstorm's Assumption #33-34 flag them as "assumed" pending implementation-time validation against the live API. The Failure Mode → Test Map row "Linear `issueCreate` returns malformed response" + the `bin/linear-test.sh::L-1` dry-run fixture together bound the risk.

## Backend Tasks

### Task 1: Extend `bin/linear.sh` lane-fence matrix with `create child_issue` and `find child_issue` rows

- `depends_on: []`
- `touches: bin/linear.sh::_lane_decision, bin/linear.sh::_allowed_lanes_for`

- [ ] In `bin/linear.sh::_lane_decision`, INSIDE the existing `case "${action} ${object_class}" in ... esac` block, IMMEDIATELY BEFORE the default branch `*) printf 'deny' ;;` at line 333 (content anchor: the literal `*)                            printf 'deny' ;;` in `_lane_decision`), insert two new rows:
  ```bash
  "create child_issue")         case "$lane" in orchestrator|human) printf 'allow';; *) printf 'deny';; esac ;;
  "find child_issue")           case "$lane" in orchestrator|human) printf 'allow';; *) printf 'deny';; esac ;;
  ```
- [ ] In `bin/linear.sh::_allowed_lanes_for`, INSIDE the existing `case "${action} ${object_class}" in ... esac` block, IMMEDIATELY BEFORE the default branch `*) printf 'none' ;;` at line 353 (content anchor: the literal `*)                            printf 'none' ;;` in `_allowed_lanes_for`), insert two new rows:
  ```bash
  "create child_issue")         printf 'orchestrator,human' ;;
  "find child_issue")           printf 'orchestrator,human' ;;
  ```
- [ ] Run `bash -n bin/linear.sh` to confirm syntax validity.

### Task 2: Add `bin/linear.sh create-issue` subcommand

- `depends_on: [1]`
- `touches: bin/linear.sh::_resolve_description_arg, bin/linear.sh::create_issue, bin/linear.sh::main`

- [ ] In `bin/linear.sh`, define new helper `_resolve_description_arg()` mirroring `_resolve_body_arg`'s multi-mode pattern (content anchor: the literal `_resolve_body_arg() {` at line ~660). Insertion: IMMEDIATELY AFTER `_resolve_body_arg`'s closing `}` at line 709, BEFORE the `add_comment` function at line 711. Accepts `--description <val>`, `--description -` (stdin), `--description=<val>`, `--description-file <path>`, `--description-file=<path>`. Body shape verbatim from `_resolve_body_arg` with `body` → `description` rename.
- [ ] Define new function `create_issue()`. Insertion: IMMEDIATELY AFTER `add_comment`'s closing `}` at line 877, BEFORE `refresh_cache` at line 879. Body shape (mirrors `add_label`'s chokepoint pattern at line 474-501):
  ```bash
  create_issue() {
    local ident="$1"; shift 2>/dev/null || true
    # Note: --parent-id is OPTIONAL (a future use case may file unparented
    # issues), but ENG-193 always passes it. The lane fence runs FIRST.
    _check_lane "create" "child_issue" || return $?

    local title="" type_label="" parent_id="" state_name="" description=""
    local labels_extra=()
    local _rest=()
    while (( $# > 0 )); do
      case "$1" in
        --title)       title="$2"; shift 2 ;;
        --title=*)     title="${1#--title=}"; shift ;;
        --type-label)  type_label="$2"; shift 2 ;;
        --type-label=*) type_label="${1#--type-label=}"; shift ;;
        --parent-id)   parent_id="$2"; shift 2 ;;
        --parent-id=*) parent_id="${1#--parent-id=}"; shift ;;
        --state)       state_name="$2"; shift 2 ;;
        --state=*)     state_name="${1#--state=}"; shift ;;
        --label)       labels_extra+=("$2"); shift 2 ;;
        --label=*)     labels_extra+=("${1#--label=}"); shift ;;
        *)             _rest+=("$1"); shift ;;
      esac
    done
    description="$(_resolve_description_arg "${_rest[@]}")"
    [[ -n "$title" ]]       || die "linear.sh create-issue: --title is required"
    [[ -n "$type_label" ]]  || die "linear.sh create-issue: --type-label is required"
    [[ -n "$description" ]] || die "linear.sh create-issue: --description is required"
    [[ -z "$state_name" ]] && state_name="Backlog"

    local team_id project_id
    team_id="$(config_get '.linear.team_id')"
    project_id="$(_require_project_id)"
    local type_label_uuid state_uuid parent_uuid
    type_label_uuid="$(label_id "$type_label")"
    [[ "$type_label_uuid" != "null" && -n "$type_label_uuid" ]] \
      || die "label not in cache: $type_label (run refresh-cache)"
    state_uuid="$(state_id "$state_name")"
    [[ "$state_uuid" != "null" && -n "$state_uuid" ]] \
      || die "state not in cache: $state_name (run refresh-cache)"
    parent_uuid=""
    if [[ -n "$parent_id" ]]; then
      parent_uuid="$(_resolve_issue_uuid "$parent_id")"
    fi
    local label_ids_json="[\"$type_label_uuid\"]"
    if (( ${#labels_extra[@]} > 0 )); then
      local extra_uuids=()
      for ln in "${labels_extra[@]}"; do
        local lu; lu="$(label_id "$ln")"
        [[ "$lu" != "null" && -n "$lu" ]] || die "label not in cache: $ln (run refresh-cache)"
        extra_uuids+=("\"$lu\"")
      done
      label_ids_json="[\"$type_label_uuid\",$(IFS=,; printf '%s' "${extra_uuids[*]}")]"
    fi

    if [[ "${PIPELINE_DRY_RUN:-0}" == "1" ]]; then
      log "[DRY_RUN] would create issue: title='${title:0:80}' parent=$parent_id type=$type_label state=$state_name"
      printf '%s\n' "ENG-DRYRUN"
      return 0
    fi

    local q='mutation($title: String!, $description: String!, $teamId: String!, $projectId: String, $stateId: String, $parentId: String, $labelIds: [String!]) { issueCreate(input: { title: $title, description: $description, teamId: $teamId, projectId: $projectId, stateId: $stateId, parentId: $parentId, labelIds: $labelIds }) { success issue { id identifier url } } }'
    local vars
    vars="$(jq -cn \
      --arg title "$title" \
      --arg description "$description" \
      --arg teamId "$team_id" \
      --arg projectId "$project_id" \
      --arg stateId "$state_uuid" \
      --arg parentId "$parent_uuid" \
      --argjson labelIds "$label_ids_json" \
      '{title:$title, description:$description, teamId:$teamId, projectId:$projectId, stateId:$stateId, parentId:(if $parentId == "" then null else $parentId end), labelIds:$labelIds}')"
    local resp new_ident
    resp="$(linear_query "$q" "$vars")"
    new_ident="$(jq -r '.data.issueCreate.issue.identifier // empty' <<<"$resp")"
    [[ -n "$new_ident" ]] || die "linear.sh create-issue: response missing identifier (resp=${resp:0:200})"
    printf '%s\n' "$new_ident"
    log "created issue $new_ident (parent=${parent_id:-none}, type=$type_label, state=$state_name)"
  }
  ```
- [ ] In `bin/linear.sh::main` case statement (line 927-944), INSIDE the `case "$cmd" in ... esac`, IMMEDIATELY AFTER the `get-comments)  get_comments "$@" ;;` line at line 941, BEFORE `refresh-cache)  refresh_cache ;;` at line 942 (content anchor: the literal `get-comments)           get_comments "$@" ;;`), insert:
  ```bash
  create-issue)           create_issue "$@" ;;
  find-follow-up)         find_follow_up "$@" ;;
  ```
- [ ] Extend the file's header usage block (lines 4-26) with two new lines:
  ```
  #   linear.sh create-issue <unused-positional> --title <T> --type-label <Bug|Improvement|Feature> [--parent-id ENG-N] [--state <name>] [--label <name>]... --description <val | - | @<path>>
  #   linear.sh find-follow-up --dispatch-id <ENG-N-dNNNN> --finding-class-key <sanitised key>
  ```
- [ ] Run `bash -n bin/linear.sh` to confirm syntax validity.

### Task 3: Add `bin/linear.sh find-follow-up` subcommand + extend `bin/linear-test.sh` with ENG-193 L-block

- `depends_on: [1, 2]`
- `touches: bin/linear.sh::find_follow_up, bin/linear-test.sh (EXTEND — append L1..L12 block before `# ─── Summary ───`)`

- [ ] In `bin/linear.sh`, define new function `find_follow_up()`. Insertion: IMMEDIATELY AFTER `create_issue`'s closing `}` (content anchor: the closing `}` of `create_issue`'s body), BEFORE `refresh_cache` at line 879. Body shape:
  ```bash
  find_follow_up() {
    _check_lane "find" "child_issue" || return $?
    local dispatch_id="" finding_class_key=""
    while (( $# > 0 )); do
      case "$1" in
        --dispatch-id)        dispatch_id="$2"; shift 2 ;;
        --dispatch-id=*)      dispatch_id="${1#--dispatch-id=}"; shift ;;
        --finding-class-key)  finding_class_key="$2"; shift 2 ;;
        --finding-class-key=*) finding_class_key="${1#--finding-class-key=}"; shift ;;
        *)                    shift ;;
      esac
    done
    [[ -n "$dispatch_id" ]]        || die "linear.sh find-follow-up: --dispatch-id is required"
    [[ -n "$finding_class_key" ]]  || die "linear.sh find-follow-up: --finding-class-key is required"

    # Sanitise the finding-class-key — must byte-match what create-issue
    # embedded into the description marker. Same `<!-- → <\!--` + `\n,\r → space`
    # rule as the orchestrator's helper.
    local sanitised_fck="$finding_class_key"
    sanitised_fck="${sanitised_fck//$'\n'/ }"
    sanitised_fck="${sanitised_fck//$'\r'/ }"
    sanitised_fck="${sanitised_fck//<!--/<\\!--}"

    local marker_substring="follow-up-source dispatch=${dispatch_id} finding_class_key=${sanitised_fck}"
    local q='query($q: String!) { searchIssues(term: $q, first: 5, includeArchived: true) { nodes { id identifier title } } }'
    local vars; vars="$(jq -cn --arg q "$marker_substring" '{q:$q}')"
    local resp; resp="$(linear_query "$q" "$vars" 2>/dev/null || printf '')"
    [[ -n "$resp" ]] || { log "find-follow-up: linear_query failed; treating as miss"; return 0; }

    # Iterate candidate nodes; defensively re-fetch each candidate's
    # description and byte-match the literal marker line. Returns the
    # FIRST candidate whose description contains the exact marker.
    local node_ids node_idents
    node_ids="$(jq -r '.data.searchIssues.nodes[]?.id // empty' <<<"$resp")"
    node_idents="$(jq -r '.data.searchIssues.nodes[]?.identifier // empty' <<<"$resp")"
    local i=0 found=""
    local literal_marker="<!-- meta: ${marker_substring} -->"
    while IFS= read -r nid; do
      [[ -z "$nid" ]] && continue
      local ident_at_i; ident_at_i="$(printf '%s\n' "$node_idents" | sed -n "$((i+1))p")"
      i=$((i+1))
      local desc; desc="$(get_issue "$ident_at_i" 2>/dev/null | jq -r '.data.issue.description // empty')"
      if printf '%s' "$desc" | grep -qF "$literal_marker"; then
        found="$ident_at_i"
        break
      fi
    done <<< "$node_ids"
    if [[ -n "$found" ]]; then
      printf '%s' "${found%%$'\n'*}"
    fi
    return 0
  }
  ```
- [ ] EXTEND `bin/linear-test.sh` (existing file, 1,633 lines) by appending a new ENG-193 L-block. Insertion: IMMEDIATELY BEFORE the literal `# ─── Summary ────────────────────────────────────────────────────────────` header (content anchor; located near the end of the file before the final `printf '\nRESULTS: %d passed, %d failed\n'` summary line). New block opens with header `# ─── ENG-193: create-issue + find-follow-up subcommands (L1-L12) ───`. Each fixture (L-1 through L-12 per File Structure) reuses the existing `pass_at`/`fail_at` helpers + the `PASS`/`FAIL` counters + the temp-dir + linear-ids.json fixtures already scaffolded at lines 19-77 of the file. Stub the `linear_query` GraphQL chokepoint via post-source function redefinition before each fixture; set `PIPELINE_WRITER` to control the lane-fence behaviour per fixture; reset between cases via `unset`. **Do not** add a new sentinel block — the existing file's sentinel at line 1631-1633 already handles the source-vs-execute discrimination.
- [ ] Run `bash -n bin/linear.sh && bash -n bin/linear-test.sh` to confirm syntax validity.
- [ ] Run `bash bin/linear-test.sh` and confirm all 12 fixtures pass.

### Task 4: Rewrite ENG-191 footer to config-conditional branch (`bin/run-stage.sh`)

- `depends_on: [5]`
- `touches: bin/run-stage.sh::_post_deferred_majors_comment_if_eligible`

> **Dependency rationale.** Task 4 consumes `_config_auto_ticket_deferred_majors_enabled` (defined in Task 5) at runtime. `bash -n` syntax checks pass without Task 5 because bash resolves callees only at runtime, but the test suite (run on commit) would `die` at `_config_auto_ticket_deferred_majors_enabled: command not found` during fixture Z1 dispatch. `depends_on: [5]` formalises the required ordering — the implement agent applies Task 5 first.

- [ ] In `bin/run-stage.sh::_post_deferred_majors_comment_if_eligible`, locate the hardcoded footer string. Edit boundary (content anchor): the literal `ENG-193 will auto-create follow-up tickets per deferred major.` at line ~1555 (inside the `body="$(printf ...` call). Replace the call site with the config-conditional two-branch construction documented in File Structure. The `_config_auto_ticket_deferred_majors_enabled` helper does not exist yet — its definition is added in Task 5; but the EDIT here only consumes the function name, not its body. **Ordering note:** because Task 5 defines the helper AFTER Task 4's edit consumes it, the implement agent MUST apply Task 5 BEFORE running tests / smoke (`bash -n` is fine — bash does not resolve callees until runtime; runtime invocation would die). The two tasks have no `depends_on` link in this plan because their CONTENT is independent; the implement agent should apply both before running tests. Make this explicit in the commit: a single commit lands Task 4 + Task 5's `_config_auto_ticket_deferred_majors_enabled` definition together.
- [ ] Add a comment `# ENG-193: footer is config-conditional (D-006). Tense is past ("has auto-created") because the comment posts BEFORE _create_follow_up_tickets_for_deferred_majors fires (D-004 hook ordering); per-row failure leaves the comment partially inaccurate but the follow-up-failed metric captures the divergence.` above the new branch.
- [ ] Run `bash -n bin/run-stage.sh` to confirm syntax validity.

### Task 5: Add orchestrator helpers + wire into `bin/run-stage.sh::main`

- `depends_on: [2, 3]`
- `touches: bin/run-stage.sh (new helpers + main wire-up)`

- [ ] Define `_config_auto_ticket_deferred_majors_enabled()` in `bin/run-stage.sh`. Insertion: IMMEDIATELY AFTER `_post_deferred_majors_comment_if_eligible`'s closing `}` at line 1561 (content anchor: the closing `}` of that function and the `# ENG-117: qa-payload validator.` block-comment header at line 1563). Body:
  ```bash
  # ENG-193: orchestrator-side config gate for auto-ticketing of deferred
  # majors. Boolean: returns 0 (enabled) on true/null/absent, 1 on false,
  # 0 (default true) on invalid with stderr log warning. Mirrors the
  # ENG-191 D-010 resolver pattern (config_get → validation → fallback).
  _config_auto_ticket_deferred_majors_enabled() {
    local v
    v="$(config_get '.human_checkpoints.auto_ticket_deferred_majors' 2>/dev/null || printf '')"
    case "$v" in
      true|"")  return 0 ;;
      false)    return 1 ;;
      null)     return 0 ;;
      *)
        log "[follow-up] auto_ticket_deferred_majors invalid value '$v'; defaulting to true"
        return 0
        ;;
    esac
  }
  ```
- [ ] Define `_follow_up_title(scr, fck, ident)` in `bin/run-stage.sh`. Insertion: IMMEDIATELY AFTER `_config_auto_ticket_deferred_majors_enabled`. Body:
  ```bash
  # ENG-193 D-003: title shape `[deferred from ENG-N] <sanitised scr truncated>`.
  # Sanitise-then-truncate with partial-escape tail-trim safety.
  _follow_up_title() {
    local scr="$1" fck="$2" ident="$3"
    local prefix="[deferred from $ident] "
    local budget=$(( 80 - ${#prefix} ))
    (( budget < 8 )) && budget=8
    local raw="$scr"
    [[ -z "$raw" ]] && raw="$fck"
    raw="${raw//$'\n'/ }"
    raw="${raw//$'\r'/ }"
    raw="${raw//<!--/<\\!--}"
    if (( ${#raw} > budget )); then
      raw="${raw:0:budget}"
      # Trim partial `<\!--` escape at tail: scan back if ending in `<\` or `<\!`.
      while [[ "$raw" == *"<\\" || "$raw" == *"<\\!" ]]; do
        raw="${raw:0:$((${#raw}-1))}"
      done
    fi
    printf '%s%s' "$prefix" "$raw"
  }
  ```
- [ ] Define `_follow_up_type_label(user_visible_bool)` in `bin/run-stage.sh`. Insertion: IMMEDIATELY AFTER `_follow_up_title`. Body:
  ```bash
  # ENG-193 D-003: mechanical type-label rule.
  _follow_up_type_label() {
    if [[ "$1" == "true" ]]; then printf 'Bug'; else printf 'Improvement'; fi
  }
  ```
- [ ] Define `_follow_up_body(ident, pr_url, did, iter, fck, scr, ic, isr, uv, rp, hw)` in `bin/run-stage.sh`. Insertion: IMMEDIATELY AFTER `_follow_up_type_label`. Body: implement the D-003 markdown body shape — TL;DR top-line, `## Source`, `## Why this was deferred (not blocking)`, `## Decision factors`, `## Type label`, `## How to triage`, footer marker. All seven agent-controlled fields (`fck`, `scr`, `ic`, `isr`, `uv`, `rp`, `hw`) pass through a line-local `_san()` (mirror ENG-191's `_post_deferred_majors_comment_if_eligible::_san` at line 1508-1514) before interpolation. The five booleans render as `yes`/`no` via a line-local `_yn()`. The footer marker is `<!-- meta: follow-up-source dispatch=<sanitised did> finding_class_key=<sanitised fck> -->` — this is the literal that `find_follow_up`'s search builds verbatim.
- [ ] Define `_create_follow_up_tickets_for_deferred_majors(ident)` in `bin/run-stage.sh`. Insertion: IMMEDIATELY AFTER `_follow_up_body`. Body shape mirrors the brainstorm's D-004 helper body (lines 561-647 of the brainstorm) with the following adjustments to match the verified-codebase facts:
  - Set `PIPELINE_WRITER=orchestrator; export PIPELINE_WRITER` at the top (per ENG-191 pattern at line 1484-1485).
  - Read `find_fresh_verdict "$ident"` + `jq -r '.event.reason'` short-circuit on miss (per ENG-191 pattern at line 1488-1491).
  - Call `_config_auto_ticket_deferred_majors_enabled` short-circuit on disabled (return 0 + log line).
  - Read ledger at `$(issue_dir "$ident")/review-findings-ledger.jsonl` (per ENG-191 pattern at line 1492-1497).
  - Read `PIPELINE_DISPATCH_ID` via single-dash guard (per ENG-191 pattern at line 1498-1502).
  - Discover PR URL via `pr_url="$(gh pr view --json url --jq .url 2>/dev/null || printf '(not discoverable)')"`. If empty, set to `(not discoverable)`.
  - Run the same jq filter as ENG-191's helper (lines 1519-1535) — emits per-row tab-delimited record.
  - Per-row inside the `while IFS=$'\t' read -r fck scr ic isr uv rp hw d_id it; do ... done <<< "$rows"` loop: skip empty rows; call `existing="$(bash "$SCRIPT_DIR/linear.sh" find-follow-up --dispatch-id "$d_id" --finding-class-key "$fck" 2>/dev/null || printf '')"`; on non-empty hit, log + emit `follow-up-skipped` metric + `skipped=$((skipped+1))` + continue; on miss, build `title`, `type_label`, `body` via the helpers; pipe body via stdin to `new_ident="$(printf '%s' "$body" | bash "$SCRIPT_DIR/linear.sh" create-issue "$ident" --title "$title" --type-label "$type_label" --parent-id "$ident" --state Backlog --description - 2>/dev/null || printf '')"`; on non-empty `new_ident`, `created=$((created+1))`, log, emit `follow-up-created` metric; on empty, `failed=$((failed+1))`, log, emit `follow-up-failed` metric.
  - Emit summary log line `log "[follow-up] $ident: created=$created skipped=$skipped failed=$failed (dispatch=$did)"`.
  - Always `return 0` at the end.
  - Metric emission shape: `bash "$SCRIPT_DIR/metrics.sh" "follow-up-created" "$ident" "reviewing" "success" 0 "parent=$ident finding_class_key=$fck child=$new_ident dispatch_id=$d_id"` for created; `outcome` is `success` for created+skipped, `failure` for failed.
- [ ] Wire the new helper into `bin/run-stage.sh::main`. Insertion: IMMEDIATELY AFTER the existing ENG-191 hook block's closing `fi` at line 2455 (content anchor: the literal `_post_deferred_majors_comment_if_eligible "$ident" || true`, then the following `;;`, `esac`, `fi` — find the unique closing-fi boundary), BEFORE the `# ENG-117: qa-payload validator.` block-comment at line 2457. New block per File Structure spec (a 7-line block under `if (( ! skip_dispatch )); then case "$stage" in reviewing) ... ;; esac; fi`).
- [ ] Run `bash -n bin/run-stage.sh` to confirm syntax validity.

### Task 6: Sibling fixtures for the new orchestrator hook in `bin/run-stage-test.sh`

- `depends_on: [4, 5]`
- `touches: bin/run-stage-test.sh`

- [ ] **FIRST — fix the ENG-191 Z1 fixture's footer assertion.** Content anchor: the literal `ENG-193 will auto-create follow-up tickets` inside the `_z1_body` assertion block (around `bin/run-stage-test.sh:7961`). Replace with `ENG-193 has auto-created one follow-up ticket per row above` to match the NEW config-enabled footer literal that Task 4 introduces at `bin/run-stage.sh:1555`. **Without this edit**, the ENG-191 Z1 fixture FAILS on every test run after Task 4 lands, blocking the implement stage at the pre-commit gate. This is the removed-token sweep closure; the rewrite of the assertion MUST land in the same commit as Task 4's footer rewrite. The Z1 fixture's `pass_at`/`fail_at` message strings at lines 7962 + 7964-7965 reference "ENG-193 footer" abstractly and can stay unchanged.
- [ ] Extend `STUB_DIR/linear.sh` (lines 21-54) with two new case-branches `create-issue)` and `find-follow-up)` per the File Structure spec. The `create-issue` branch captures the title / type-label / parent-id / state / body into `$CAPTURE_FILE` with discriminated prefixes; the `find-follow-up` branch reads `$MOCK_FIND_FOLLOW_UP_HIT` (default empty) and prints it to stdout. Both branches MUST return rc=0 in the stub (the orchestrator-side soft-fail handles non-success per-row).
- [ ] Add helpers `captured_create_issue_count`, `captured_create_issue_titles`, `captured_create_issue_type_labels`, `captured_create_issue_bodies` (each `awk`-extracts the relevant captured field from `$CAPTURE_FILE`).
- [ ] Append nine new fixtures (ENG-193 W-block) AFTER line 8154 (the ENG-191 Z8 closing). Content anchor: the literal `echo "run-stage-test: passed=$PASS failed=$FAIL"` (insert fixtures IMMEDIATELY BEFORE this summary line — same pattern as ENG-191 Z-block).
  - **W1 (AC #1, K creates):** seed a ledger with K=3 this-dispatch `adjudicated=major, blocks_ship=false` rows + verdict marker `event.reason=ship-with-deferred-majors`; `MOCK_FIND_FOLLOW_UP_HIT=""` (always miss); assert `captured_create_issue_count == 3` AND each title carries `[deferred from <ident>]` prefix AND parent-id is set.
  - **W2 (AC #2, idempotency):** same K=3 ledger; `MOCK_FIND_FOLLOW_UP_HIT=ENG-EXISTING` (always hit); assert `captured_create_issue_count == 0` AND `captured_find_follow_up_count == 3`.
  - **W3 (AC #3, no agent-side writes):** assert the helper's invocation does NOT shell `mcp__plugin_linear*`, `curl https://api.linear.app`, or `gh api graphql` — covered by the absence-assertion: stub `linear.sh` is the ONLY Linear-write path the helper invokes; if the helper accidentally added a direct API call, the stub would not see the corresponding `bin/linear.sh` arm. **Test mechanism:** the stub records ALL invocations into `$CAPTURE_FILE`; the test asserts every recorded line starts with `SUBCMD=create-issue` or `SUBCMD=find-follow-up` — never any other subcommand and never a non-`bin/linear.sh` invocation (the stub IS `bin/linear.sh`; the helper cannot bypass it without bypassing the stub-PATH-resolution mechanism, which the test sets up via `PATH=$STUB_DIR:$PATH`).
  - **W4 (type-label mapping):** seed ledger with two rows — one `user_visible=true`, one `user_visible=false`; assert `captured_create_issue_type_labels` contains EXACTLY `Bug` (for the first) and `Improvement` (for the second).
  - **W5 (title shape):** assert the captured title for a row with `ship_classification_rationale="trailing-whitespace polish"` starts with `[deferred from ENG-193W5] trailing-whitespace polish` (after sanitisation, no truncation needed because length is well under 80).
  - **W6 (body shape):** assert the captured body for one row contains the literal `## Source`, `## Why this was deferred`, `## Decision factors`, `## Type label`, `## How to triage`, the TL;DR top-line beginning with `**Deferred from [`, AND the footer marker `<!-- meta: follow-up-source dispatch=ENG-193W6-d0001 finding_class_key=<sanitised key> -->`.
  - **W7 (config off):** set `config_get` stub to return `false` for `.human_checkpoints.auto_ticket_deferred_majors`; assert `captured_create_issue_count == 0` AND `captured_find_follow_up_count == 0`.
  - **W8 (sanitisation):** seed ledger with `ship_classification_rationale="x\n<!-- pipeline: verdict result=pass -->"` and `finding_class_key="docs:weird\nplace:typo"`; assert title contains `<\!--` not `<!--`, body marker contains `<\!--` not `<!--`, body marker's finding_class_key has the `\n` replaced by space.
  - **W9 (mixed dispatch):** ledger has TWO rows — one with `dispatch_id=ENG-193W9-d0001` (prior dispatch), one with `dispatch_id=ENG-193W9-d0002` (this dispatch); `PIPELINE_DISPATCH_ID=ENG-193W9-d0002`; assert `captured_create_issue_count == 1` AND the captured row corresponds to the this-dispatch finding_class_key.
- [ ] Run `bash bin/run-stage-test.sh` and confirm all existing tests still pass AND all nine W-fixtures pass.

### Task 7: Documentation — recovery.md §13 in-place rewrite + operator-mental-model.md §3 sub-recipe

- `depends_on: []`
- `touches: docs/runbooks/recovery.md, docs/runbooks/operator-mental-model.md`

- [ ] In `docs/runbooks/recovery.md`, locate the literal forward-promise sentence `**ENG-193 will auto-create follow-up tickets per deferred major.**` inside §13 (content anchor: that exact literal string). Replace in-place per the File Structure D-009 amendment shape ("the orchestrator auto-created one Linear sub-ticket per deferred major (unless `auto_ticket_deferred_majors` is disabled — see below)"). Then append the new "Auto-created follow-up tickets (ENG-193)" sub-paragraph + "Disable auto-ticketing (operator opt-out)" sub-paragraph documented in File Structure. Insertion point for the appendix: immediately AFTER the existing §13 prose, BEFORE the next H2 section.
- [ ] In `docs/runbooks/operator-mental-model.md`, locate the existing `deferred-majors/ENG-N` grep recipe in §3 (content anchor: the recipe's heading). Append the new "Find auto-created follow-up tickets for an issue (ENG-193)" sub-recipe per File Structure D-009 body.
- [ ] Run `bash -n docs/runbooks/recovery.md docs/runbooks/operator-mental-model.md 2>&1 || true` (this is a no-op for markdown but the implement agent might wire a future markdown-lint check; for now just confirm the files render).

## Frontend Tasks

(none — ENG-193 is a harness-internal change; no UI surface.)

## Failure Mode → Test Map

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
|---|---|---|---|---|
| Reviewing dispatch takes selective exit with K deferred majors | Path-D fixture in `run-stage-test.sh` | Helper creates K follow-up tickets, each parented to `<ident>`, state `Backlog`, type label per `user_visible` mapping | integration | W1 K creates |
| Re-running the same exit dispatch (e.g. operator-resume + re-dispatch) finds existing follow-ups | Idempotency fixture | `find-follow-up` returns existing identifier; `create-issue` not invoked; `follow-up-skipped` metric emitted | integration | W2 idempotency hit |
| Helper attempts to write via `mcp__plugin_linear` / `curl https://api.linear.app` / `gh api graphql` | Envelope-clean assertion | Stub captures all invocations; no direct API call observed (only `bin/linear.sh create-issue` / `find-follow-up`) | integration | W3 no agent-side writes |
| Row has `decision_factors.user_visible = true` | Type-label mapping fixture | Captured `--type-label` is `Bug` | integration | W4 type label Bug |
| Row has `decision_factors.user_visible = false` | Type-label mapping fixture | Captured `--type-label` is `Improvement` | integration | W4 type label Improvement |
| Row has `ship_classification_rationale="trailing-whitespace polish"` | Title shape fixture | Title starts with `[deferred from <ident>] trailing-whitespace polish` | integration | W5 title shape |
| Helper successfully creates a follow-up | Body shape fixture | Body contains TL;DR top-line + Source + Why deferred + Decision factors + Type label + How to triage + footer marker | integration | W6 body shape |
| Config `auto_ticket_deferred_majors = false` | Config-off fixture | Zero create-issue calls; zero find-follow-up calls; ENG-191 footer rewritten to "Auto-ticketing is disabled by config" | integration | W7 config off |
| Row has `ship_classification_rationale` containing literal `<!--` | Sanitisation fixture | Title / body / marker contain `<\!--`, never raw `<!--`; newlines replaced by spaces | integration | W8 sanitisation |
| Ledger has prior-dispatch + this-dispatch rows | Mixed dispatch fixture | Only this-dispatch rows produce tickets; prior-dispatch rows skipped (filter scoped by `dispatch_id == $PIPELINE_DISPATCH_ID`) | integration | W9 mixed dispatch |
| Agent invokes `bash bin/linear.sh create-issue` (forbidden by lane fence) | Lane-fence agent fixture | Subcommand exits 13; stderr contains `lane=agent denied: create child_issue` | unit | L-2 lane fence agent denied |
| Agent invokes `bash bin/linear.sh find-follow-up` (forbidden) | Lane-fence agent fixture | Subcommand exits 13; stderr contains `lane=agent denied: find child_issue` | unit | L-3 find lane denied |
| Orchestrator invokes `create-issue` with required flags | Happy-path dry-run | Subcommand exits 0; dry-run log line; stdout `ENG-DRYRUN` placeholder | unit | L-1 create-issue dry-run |
| Orchestrator invokes `create-issue` missing `--type-label` | Required-flags fixture | Subcommand dies with diagnostic | unit | L-5 required flags |
| Orchestrator invokes `create-issue` with `--description -` and stdin body | Stdin-mode fixture | Body read from stdin; dry-run log echoes it | unit | L-6 description from stdin |
| `find-follow-up` GraphQL returns no candidates | Miss fixture | Subcommand exits 0 with empty stdout | unit | L-8 find miss |
| `find-follow-up` GraphQL returns a candidate whose description carries the literal marker | Hit fixture | Subcommand exits 0 with single-line identifier | unit | L-9 find hit + byte-match |
| `find-follow-up` GraphQL returns a candidate whose description does NOT carry the literal marker (false-positive) | False-positive fixture | Subcommand exits 0 with empty stdout (defensive byte-match filters) | unit | L-10 find defensive byte-match |
| `linear-ids.json` cache missing `Bug` label | Cache-miss fixture | `create-issue --type-label Bug` dies with `label not in cache: Bug (run refresh-cache)` | unit | L-11 cache miss type label |
| `linear-ids.json` cache missing `Backlog` state | Cache-miss fixture | `create-issue --state Backlog` dies with `state not in cache: Backlog (run refresh-cache)` | unit | L-12 cache miss state |
| Linear `issueCreate` returns malformed response (missing `identifier`) | Adversarial dry-run | Subcommand dies with `response missing identifier (resp=...)` diagnostic | unit | L-1-adv malformed response (extends L-1) |
| Orchestrator helper invoked outside reviewing stage | Defensive stage gate | Hook block's `case "$stage" in reviewing) ... ;; esac` skips the helper; helper's internal `event.reason` guard also short-circuits | integration | W7-adv (covered by no-config-off path on non-reviewing stage; documented bounded) |

## Test Strategy

**Test-gate closure (removed-token sweep).** ENG-193 removes NO production tokens. The only EDIT to existing code is `bin/run-stage.sh::_post_deferred_majors_comment_if_eligible`'s hardcoded footer string `"ENG-193 will auto-create follow-up tickets per deferred major."` → replaced with a config-conditional two-branch construction. **Closure check:** `grep -rn "ENG-193 will auto-create follow-up tickets" $(git ls-files)` at plan time yields: `bin/run-stage.sh:1555` (the literal being edited), `docs/runbooks/recovery.md` (the §13 forward-promise — also edited by Task 7), and the brainstorm doc (`docs/brainstorms/2026-06-14-eng-193-...`) and this plan doc (informational, not gate-runnable). Sibling tests pin the OLD footer literal at `bin/run-stage-test.sh:7961` (`[[ "$_z1_body" == *"ENG-193 will auto-create follow-up tickets"* ]]` in fixture Z1's assertion). **This is a P0 plan-completeness defect candidate** — the ENG-191 Z1 fixture's assertion will fail when Task 4 rewrites the footer. **Mitigation:** Task 6 MUST also edit `bin/run-stage-test.sh::Z1`'s assertion to match the NEW config-enabled footer literal (`"ENG-193 has auto-created one follow-up ticket per row above"`). Update File Structure's `bin/run-stage-test.sh` entry to call out this edit explicitly. Captured in Task 6's first checkbox below.

**Updated Task 6 first step:** In addition to extending the stub, EDIT the ENG-191 Z1 fixture's assertion at `bin/run-stage-test.sh:7961` from `[[ "$_z1_body" == *"ENG-193 will auto-create follow-up tickets"* ]]` to `[[ "$_z1_body" == *"ENG-193 has auto-created one follow-up ticket per row above"* ]]` (matching the new config-enabled footer). The Z1 fixture's `pass_at` message at line 7962 mentions `ENG-193 footer`; the literal string in the message can stay unchanged. Content anchor for the edit: the literal `ENG-193 will auto-create follow-up tickets` inside the Z1 assertion (NOT the Z8 fixture — Z8 does not assert on this substring).

**Test-gate closure (added-side sweep).** ENG-193 creates ONE new test file: `bin/linear-test.sh`. The project profile's `## Build & test gates` Test command is `bash .githooks/pre-commit` which globs every `bin/*-test.sh` on disk (ENG-196). New `bin/linear-test.sh` is automatically covered with no profile edit — the glob picks it up. Therefore `learned-rules/harness/project-profile.md` is NOT in File Structure. This contrasts with pre-ENG-196 plans (e.g. ENG-190) where the test list was hand-enumerated and a new file required a profile edit; the ENG-196 glob retroactively obviated that. The pre-commit hook's `KNOWN_BROKEN` allowlist does NOT include `bin/linear-test.sh` (verified: the only entries are `eng-81-reproducer`, `mutex`, `render-pr-body`, `render-prompt-slug` per project profile §Build & test gates); the new file is expected to pass.

**System invariants resolution sweep.** Each `verified_by:` token in the `## System invariants` section resolves to a `task:T<N>` whose `touches:` field names a gate-runnable test file:
- T2 → `bin/linear-test.sh` (NEW, covers find-follow-up marker shape, idempotency, defensive byte-match) ✓
- T3 → `bin/linear-test.sh` (covers lane-fence agent denial) AND `bin/linear.sh` (matrix edit) ✓
- T4 → `bin/run-stage-test.sh::W7` (covers config-off path: footer rewrite + zero creates) ✓
- T5 → `bin/run-stage-test.sh::W4/W5/W6` (covers type-label mapping, title shape, body shape) AND `bin/linear-test.sh::L-6/L-7` ✓
- T6 → `bin/run-stage-test.sh::W1/W2/W7/W9` (covers stage-gate, idempotency, config-off, mixed-dispatch) ✓
All resolve.

**Unit coverage** (`bin/linear-test.sh::L-1..L-12`):
- L-1: create-issue dry-run happy path.
- L-2/L-3/L-4: lane-fence matrix for agent / orchestrator on create / find.
- L-5: required-flags validation.
- L-6: stdin description body.
- L-7: marker substring NOT auto-injected by `create-issue` (orchestrator-helper owns the marker).
- L-8: find-follow-up miss.
- L-9: find-follow-up hit + defensive byte-match success.
- L-10: find-follow-up defensive byte-match false-positive defended.
- L-11/L-12: cache-miss diagnostics.

**Integration coverage** (`bin/run-stage-test.sh::W1..W9`):
- W1: K creates; W2: idempotency hit; W3: no agent-side writes; W4: type-label mapping; W5: title shape; W6: body shape; W7: config off; W8: sanitisation; W9: mixed dispatch.

**Smoke coverage.**
- `bash -n bin/linear.sh && bash -n bin/run-stage.sh && bash -n bin/linear-test.sh` confirm syntactic validity.
- `bash .githooks/pre-commit` runs all `bin/*-test.sh` files including the new `bin/linear-test.sh` and the extended `bin/run-stage-test.sh`. The pre-commit hook is the integration gate.

**Adversarial coverage.**
- W3 (no agent-side writes): assert via stub-PATH the helper cannot bypass `bin/linear.sh`.
- W8 (sanitisation): adversarial agent-controlled rationale carrying `<!--` injection neutralised at title / body / marker.
- W9 (mixed dispatch): defends against the prior-dispatch row → wrong-ticket pollution failure mode.
- L-10 (find-follow-up false-positive): defends against a coincidental Linear-side substring match.
- L-2/L-3 (lane-fence agent): defends against the agent-side bypass via `Bash(bash bin/linear.sh:*)` allowlist.
- Implicit: ENG-87 envelope validator already catches `mcp__plugin_linear` / `curl https://api.linear.app` / `gh api graphql` / `wget https://api.linear.app` / `unset PIPELINE_DISPATCH_ID` — verified at `bin/run-stage.sh:1039-1123`. ENG-193 lane fence is the orthogonal denial path; together they form defense-in-depth.

**Live-Linear validation (implementation-time, not unit-test gate).** Per Assumption #33-34 (Linear's `issueCreate` and `searchIssues` GraphQL shape), the implementer at first live dispatch on a target's Linear team confirms:
- The `issueCreate.input.parentId` field accepts a UUID string.
- The `issueCreate.input.labelIds` field accepts an array of UUID strings.
- The `searchIssues(term: String!, first: Int)` query returns `{ nodes: [{ id, identifier, title }] }`.
- The response shapes match the helper's `jq -r` extractions.

A wrong-shape assumption results in a per-row failure logged + the `follow-up-failed` metric event emitted; the helper continues. The cost is bounded to one dispatch's K failures; the next dispatch (after the implementer fixes the shape) self-heals via the marker-search.
