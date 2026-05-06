---
linear: ENG-62
date: 2026-05-06
topic: pre-dispatch merge gate in run-stage.sh — short-circuit post-merge building → released without invoking the agent
---

# Plan — ENG-62 build-stage pre-dispatch merge gate

> **For agentic workers:** REQUIRED SUB-SKILL — use
> `superpowers:subagent-driven-development` (recommended) or
> `superpowers:executing-plans` to walk this task-by-task. Steps use
> `- [ ]` for tracking.

Implementation plan for the design in
`docs/brainstorms/2026-05-06-eng-62-build-p2-still-emits-awaiting-approval-on-post-merge-dispatches-despite-non-bot-approved-review-existing-design.md`.

## Anti-anchoring

- **Problem (operator's words):** the build agent emits `verdict wait
  --reason awaiting-approval` on post-merge dispatches even when a
  non-bot APPROVED review exists; orchestrator re-dispatches every 5-min
  tick at ≈ $1.50/dispatch (~$22 wasted across the 2026-05-02
  observation session) until either an external release tag fires
  `on-new-release.sh`'s sweep or an operator manually flips the stage
  label.
- **Does the brainstorm address it?** Yes — and it reframes from
  "fix the agent's evaluation" to "stop dispatching the agent
  post-merge at all." Reframe is justified by §1.2 evidence: the prompt
  was already rewritten once (`reviewDecision` → `reviews[]`, commit
  941218f9) and the symptom recurred. Load-bearing goal is *avoiding
  the dispatch*, not correcting it after the fact. D-001 is the
  pre-dispatch gate; D-002 is symmetric defense-in-depth in the prompt.
- **Proportional?** Yes. One new helper (`_pre_dispatch_merge_gate` in
  `bin/run-stage.sh`), one structural insertion in `main()`, six new
  test cases in `bin/run-stage-test.sh`, one new precondition (P0) in
  `AGENT_PROMPTS.md` §7, one new file
  `learned-rules/harness/build.md`. No new marker shapes, no new state
  files, no new lanes, no `bin/pipeline-events.json` registry edits, no
  `bin/dispatch.sh::allowed_tools_for` change. Brainstorm explicitly
  rejected wider alternatives (gate in `poll.sh`; new `verdict done`
  shape; post-dispatch override).
- **No escalation needed.**

## Goal

Land a pre-dispatch merge-detection gate in
`bin/run-stage.sh::_pre_dispatch_merge_gate` (called from `main()`
between the `skip_dispatch` scope-approval-replay block and the
per-issue `mkdir`) plus a symmetric P0 clause in `AGENT_PROMPTS.md` §7,
such that a `stage:building` issue whose PR is `MERGED` transitions to
`stage:released` on the FIRST post-merge tick without invoking the
build agent — verifiable via `bash bin/run-stage-test.sh && bash bin/verdict-handler-test.sh && bash bin/render-prompt-test.sh && bash -n bin/run-stage.sh && bash bin/secret-probe-lint.sh`
exiting 0 with the new ENG-62 cases A–F all PASS.

## Architecture

The change is additive to one orchestrator script (`bin/run-stage.sh`)
and its sibling test (`bin/run-stage-test.sh`); one prompt edit
(`AGENT_PROMPTS.md` §7); and one new learned-rules file
(`learned-rules/harness/build.md`). No changes to `bin/poll.sh`,
`bin/verdict-handler.sh`, `bin/classify-failure.sh`, `bin/linear.sh`,
`bin/dispatch.sh`, `bin/on-new-release.sh`, `bin/pipeline-events.json`,
`bin/halt-sprawl-test.sh`, `bin/run-local-sweep-test.sh`, or
`bin/run-local-helpers.sh`.

The architectural pivot is treating "PR already merged" as an
orchestrator-observable terminal state for the build stage, parallel to
how `stage:released` is treated as terminal in `bin/poll.sh:34`. Today
the orchestrator has no pre-dispatch awareness of merge state — it
classifies `stage:building` + no halt + no fresh marker as
`{slot:hold,advanceable:true}` (`bin/poll.sh:265-267`), dispatches the
agent, and lets the agent emit a wait verdict that re-runs the same
loop next tick. ENG-62 closes that gap by hoisting one cheap `gh pr
list` query to the orchestrator and calling `apply_transition` directly
(it is already sourced at `bin/run-stage.sh:21-22` and is one of the
three documented public functions of `verdict-handler.sh:6-10`).

`apply_transition` was deliberately chosen over the
"post-pass-marker-then-call-verdict_handler" path because the
orchestrator is the *author* of this transition; making it synthesise
a `verdict pass --stage building` marker so it can read it back through
Linear is orchestrator-talks-to-itself overhead with a
read-after-write-consistency assumption. Calling `apply_transition`
directly posts exactly one `pipeline: transition` waypoint (the audit
trail), applies the label swap, drains legacy labels, and runs the
released native-state Done hook — five idempotent steps, every one
wrapped in `|| true` at `bin/verdict-handler.sh:161/164/166/172/180`.

There is no `docs/VISION.md`, no `docs/knowledge/decisions.md`, no
`SYSTEM_ARCHITECTURE.md` in this repo (verified: `ls docs/` returns
`brainstorms/  pipeline-vocabulary.md  pipeline-vocabulary.template.md
plans/  runbooks/`). Governing constraints come from `CLAUDE.md` and
`learned-rules/harness/project-profile.md`. The relevant learned-rules
file `learned-rules/harness/plan.md` does not exist (verified: `ls
learned-rules/harness/` returns `project-profile.md` only); the
`learned-rules/twinning/plan.md` rules P-001 (frontmatter `linear:
ENG-N`) and P-002 (enumerate every signature change) bind this plan
even though they live under a different slug.

## Tech stack

- Bash 3.2+ (Darwin default, harness target).
- `jq` is unused in this change (the gate parses `gh pr list --jq`
  output server-side; no client-side jq needed).
- `gh` CLI for `gh pr list --head <branch> --state all --json state
  --jq '.[0].state // ""'` — same invocation shape already in use at
  `bin/run-stage.sh:158-160` for `pr_url` derivation.
- `compgen` is unused in this change.
- No new dependencies. No `bin/dispatch.sh::allowed_tools_for` cases
  added (the gate runs in the orchestrator, not in the agent).

## Assumption Inventory

Every modified-file fact below is `path:line`-cited against the
current worktree per learned-rules P-002 and B-001 (no "follows the
existing pattern" without an excerpt). Assumptions marked `assumed/new`
identify the file where the artifact will be created.

### Modified files — current signatures, call sites, and trait/global
boundaries

- **A-001 — `bin/run-stage.sh::main()` body extends from line 495 to
  line 877.** Verified at `bin/run-stage.sh:495-497` (entry +
  arg-validation), `bin/run-stage.sh:499-500` (`t0` set), `bin/run-stage.sh:503` (`verify_preconditions` call),
  `bin/run-stage.sh:534-541` (`skip_dispatch` block — insertion-point
  upper boundary), `bin/run-stage.sh:546` (`mkdir -p "$(issue_dir
  "$ident")"` — insertion-point lower boundary), `bin/run-stage.sh:551-565`
  (render-prompt + dispatch.sh), `bin/run-stage.sh:702-741` (ENG-45
  wait-shape detection — must NOT fire when the gate already
  transitioned), `bin/run-stage.sh:813` (`_post_dispatch_apply_halt`),
  `bin/run-stage.sh:823` (`verdict_handler` call), `bin/run-stage.sh:851-855`
  (success-path state cleanup — pattern mirrored by gate's cleanup).
  The plan inserts the gate-firing block between line 541 and line
  546; no other line in `main()` is modified.

- **A-002 — `bin/run-stage.sh:21-22` sources `verdict-handler.sh`
  unconditionally.** Verified — `apply_transition` is therefore in
  scope at every line in `main()` (and at every helper definition
  below `main()`). The new helper `_pre_dispatch_merge_gate` will
  land above `main()` in source order; `apply_transition` is in scope
  there too because the source is at file scope.

- **A-003 — `bin/run-stage.sh:147-148` is the canonical `summary_path`
  derivation pattern.** Verified at `bin/run-stage.sh:146-148`
  (`post_completion_comment`'s body). The new helper will derive its
  stage-summary path the same way: `local _summary_path; _summary_path="$(issue_dir
  "$ident")/stage-summary-${stage}.md"`.

- **A-004 — `bin/run-stage.sh:158-160` is the existing `gh pr list
  --head <branch> --state {open,all} --json url` invocation.**
  Verified:

  ```
  158        if [[ -n "$branch" ]] && command -v gh >/dev/null 2>&1; then
  159          pr_url="$(gh pr list --head "$branch" --state open  --json url --jq '.[0].url // ""' 2>/dev/null || printf '')"
  160          [[ -z "$pr_url" ]] && pr_url="$(gh pr list --head "$branch" --state all --json url --jq '.[0].url // ""' 2>/dev/null || printf '')"
  ```

  The gate's query mirrors this pattern verbatim except (1) `--json
  state` instead of `--json url`, (2) `'.[0].state // ""'` instead of
  `'.[0].url // ""'`, and (3) `--state all` only (no `--state open`
  fallback) because a `--delete-branch`'d merged PR is not in `open`
  but IS in `all`. No new shell idiom enters the codebase.

- **A-005 — `bin/run-stage.sh::_handle_wait` at lines 381-470 sets
  `local PIPELINE_WRITER=orchestrator; export PIPELINE_WRITER` at
  lines 382-383.** Verified. The new `_pre_dispatch_merge_gate`
  mirrors this defensive lane attribution — explicit assignment
  prevents silent lane-violation if a future caller invokes the
  helper from an agent sub-shell (file-scope inheritance is correct
  today but not enforceable).

- **A-006 — `bin/run-stage.sh::_fresh_wait_reason` allow-lists
  `building` only at lines 303-306.** Verified:

  ```
  303    case "$stage" in
  304      building) ;;
  305      *) return 1 ;;
  306    esac
  ```

  The new gate uses an identical stage-keyed allow-list (security
  parallel) — only `building` has PR-merge semantics in the current
  pipeline.

- **A-007 — `bin/run-stage.sh::_handle_wait` at line 454 posts the
  budget-exhausted halt body via `bash "$SCRIPT_DIR/linear.sh"
  add-comment "$ident" "$halt_body" || true`.** Verified — the gate
  does NOT post a halt; it posts a transition waypoint via
  `apply_transition`, which is `linear.sh add-comment` under the
  hood (verdict-handler.sh:161). The lane fence in `bin/linear.sh`
  is the same — `PIPELINE_WRITER=orchestrator` (set explicitly per
  A-005).

- **A-008 — `bin/run-stage.sh:879-881` is the source-and-stub
  sentinel.** Verified:

  ```
  879  if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  880    main "$@"
  881  fi
  ```

  Sourcing the file in the test harness does NOT fire `main()`; the
  test can call `_pre_dispatch_merge_gate` directly. Existing ENG-45
  cases follow this same pattern (e.g., `bin/run-stage-test.sh:907+`
  source-and-call `_fresh_wait_reason` directly).

- **A-009 — `bin/run-stage-test.sh:46-52` is the existing
  `gh` stub.** Verified:

  ```
  46  # Toggleable gh stub: MOCK_GH_PR_URL controls the `gh pr list` output.
  47  cat > "$STUB_DIR/gh" <<'SH'
  48  #!/usr/bin/env bash
  49  # Only handles: gh pr list --head <branch> --state {open|all} --json url --jq '.[0].url // ""'
  50  printf '%s' "${MOCK_GH_PR_URL:-}"
  51  SH
  52  chmod +x "$STUB_DIR/gh"
  ```

  Note: the existing stub uses `${MOCK_GH_PR_URL:-}` (a `${VAR:-X}`
  pattern). Per the secret-handling lint (A-014), `${VAR:-FALLBACK}`
  is forbidden against env vars whose names match
  `*KEY|*TOKEN|*SECRET|ANTHROPIC*|GITHUB*|LINEAR*` — but
  `MOCK_GH_PR_URL` and `MOCK_GH_PR_STATE` do NOT match those patterns,
  so the new arm is lint-clean by construction.

  The replacement stub (Task 3) inspects the `--json` argument and
  routes to either `MOCK_GH_PR_URL` or `MOCK_GH_PR_STATE`; the
  former preserves backward compatibility with all 200+ existing
  test cases that only set `MOCK_GH_PR_URL`.

- **A-010 — `bin/run-stage-test.sh:885-905` rebuilds the `linear.sh`
  stub for the ENG-45 cases.** Verified — the rebuild inserts the
  `get-comments` arm and the `stage-of` arm. The new cases A–F do
  NOT need to call `get-comments` (the gate never reads Linear
  comments). They DO need `add-comment`, `add-label`, `remove-label`,
  and `transition-state` (the `apply_transition` side effects). The
  rebuilt stub at `bin/run-stage-test.sh:890-905` already captures
  every non-`get-comments`/non-`stage-of` invocation into
  `$CAPTURE_FILE` (lines 898-901). The new cases assert on
  `CAPTURE_FILE` substring matches.

- **A-011 — `bin/verdict-handler.sh::apply_transition` signature
  is `apply_transition <issue> <from> <to> <side_labels_csv>
  [post_waypoint]`.** Verified at `bin/verdict-handler.sh:154-156`:

  ```
  154  apply_transition() {
  155    local issue="$1" from="$2" to="$3" side_labels="${4:-}"
  156    local post_waypoint="${5:-1}"  # internal: resume path passes 0 to skip step 1
  ```

  The gate calls `apply_transition "$ident" "building" "released" ""`
  — explicit empty string for `side_labels`, default `post_waypoint=1`.
  The empty `side_labels` is the same shape `verdict_handler` uses
  on the forward-transition happy path; no caller passes a non-empty
  csv for forward transitions today.

- **A-012 — `bin/verdict-handler.sh:25-26` includes `building=released`
  in `_VH_FORWARD_TRANSITIONS`.** Verified:

  ```
  25  qa=building
  26  building=released
  ```

  The transition is registry-compliant; no additions to
  `_VH_FORWARD_TRANSITIONS` or `_VH_LOOPBACK_TRANSITIONS`.

- **A-013 — `bin/verdict-handler.sh:154-184` is `apply_transition`'s
  full body.** Verified — every step is wrapped in `|| true` (lines
  161, 164, 166, 172, 180) so a partial failure (e.g., transient
  Linear `add-label` outage on the first invocation) leaves the
  issue partially transitioned (waypoint posted, label not yet
  swapped). On the next tick the gate fires `apply_transition`
  again; every step is idempotent (`add-label` no-ops if already
  present, `remove-label` no-ops if already absent, the waypoint
  comment is appended again — one extra harmless duplicate that
  Linear's per-issue comment-count lookback will collapse via the
  dedup-by-normalized-hash at `bin/linear.sh::add_comment`'s body
  hash check).

- **A-014 — `bin/secret-probe-lint.sh` is the project's enforcement
  point for the ENG-46 `${VAR:-FALLBACK}` guard.** Verified — the
  new helper `_pre_dispatch_merge_gate` introduces no
  `${VAR:-FALLBACK}` patterns against `*KEY|*TOKEN|*SECRET|ANTHROPIC*|GITHUB*|LINEAR*`
  names. The only env-var presence check in the helper is
  `command -v gh` (PATH check, not env-var fallback), so the lint
  passes by construction. The `MOCK_GH_PR_STATE` test stub falls
  outside the secret name pattern.

- **A-015 — `AGENT_PROMPTS.md:1191` is the `## 7. Build Agent` H2
  section header; the body fence opens at line 1193 and closes at
  line 1418.** Verified — `bin/render-prompt.sh::main` extracts by
  H2 header and dies if the fence count inside the body is not
  exactly 2. The plan inserts the new P0 clause INSIDE the existing
  fence (between the precondition-ordering clause at lines
  1208-1211 and the existing P1 at line 1213), so the fence count
  remains 2 and `bin/render-prompt-test.sh` continues to pass.

- **A-016 — `AGENT_PROMPTS.md:1208-1211` is the precondition-ordering
  clause.** Verified — the plan adds one sentence referencing P0:
  "If P0 already determined `state == MERGED`, you do not reach this
  ordering clause — exit per P0." This preserves the existing prose
  structure and does not introduce a column-0 ``` fence.

- **A-017 — `AGENT_PROMPTS.md:1213-1216` is the existing P1 prose.**
  Verified — the new P0 lands ABOVE this line; existing P1 numbering
  and prose are unchanged. The `bin/render-prompt.sh` extract is
  literal (substring-fence based), so the renumbering of "P0 above
  P1" is text-only and does not affect any other tooling.

- **A-018 — `bin/poll.sh:34` says `# stage:released is terminal —
  not polled.`** Verified. After the gate transitions
  `building → released`, `poll.sh` will not pick the issue up on
  any subsequent tick — no infinite loop possible.

- **A-019 — `bin/poll.sh:265-267` is the else-branch advanceable=true
  path.** Verified:

  ```
  265    else
  266      class='{"slot":"hold","advanceable":true}'
  267    fi
  ```

  This is the path that fires `run-stage.sh` on a `stage:building`
  issue with no halt label and no fresh marker — the entry point
  the gate intercepts. No change to poll.sh.

- **A-020 — `bin/on-new-release.sh:25-58` is the Part-1 sweep
  (stage:building → stage:released safety net for the release-tag
  path).** Verified — unchanged. The gate runs upstream of the sweep;
  in the happy case the sweep finds no `stage:building` issues
  (already swept by the gate). The sweep remains the long-tail safety
  net for issues that escape the gate (e.g., persistent `gh` outage
  at every tick between merge and the next release tag).

- **A-021 — `bin/branch-name.sh:31` returns `feat/<id-lower>-<slug>`
  or `fix/<id-lower>-<slug>`.** Verified. The slug pattern is
  `[a-z0-9-]+`; no special-quoting concerns. The gate's
  `gh pr list --head "$_branch"` call quotes `$_branch` so even a
  hypothetical regression in branch-name.sh that produced spaces
  would not break argument tokenisation (defense-in-depth).

- **A-022 — `bin/run-stage.sh:702-741` is the ENG-45 wait-shape
  detection block in `main()`.** Verified — runs only inside
  `if (( ! skip_dispatch ))` (line 702) and only after the
  dispatch.sh return on line 565. The gate runs upstream of dispatch,
  so the wait-shape detection is naturally bypassed when the gate
  fires; no interaction.

- **A-023 — `bin/run-stage.sh::_post_dispatch_apply_halt` at lines
  360-372 has a wait-shape carve-out.** Verified — runs only after
  dispatch.sh returns. The gate exits before dispatch.sh is invoked,
  so this block is naturally bypassed when the gate fires; no
  interaction.

- **A-024 — `bin/common.sh::issue_dir` resolves to
  `$PROJECT_STATE_DIR/<ident>/`.** Verified — the canonical per-issue
  scratch path. Per CLAUDE.md "Don'ts": never reference
  `$HARNESS_STATE_DIR/<issue>` directly. The new helper writes to
  `$(issue_dir "$ident")/stage-summary-${stage}.md` only — the
  canonical per-stage-summary path.

- **A-025 — `bin/metrics.sh stage-end` accepts the call shape
  `metrics.sh stage-end <issue> <stage> <outcome> <duration_ms>
  [notes…]`** at `bin/metrics.sh:19-41`. Verified — `notes_parts`
  is collected by the unrecognised-flag arm (line 36) and joined
  into `notes` on line 41. The new outcome literal `merged-pre-dispatch`
  is written verbatim into `events.jsonl`; no schema change is
  needed.

- **A-026 — `bin/render-prompt.sh` enforces that `AGENT_PROMPTS.md`
  contains exactly two column-0 ``` fences per H2 section.**
  Verified at `bin/render-prompt.sh:35-61` (the runtime fence-count
  schema check; dies with a schema-error message if `fence_count
  != 2`). `bin/render-prompt-test.sh` exercises this code path
  end-to-end (any test that invokes `render-prompt.sh build ENG-N`
  fails on a fence-count mismatch). The plan's prompt insertion is
  INSIDE the existing § 7 fence (between lines 1211 and 1213), not
  a new fence pair, so both the runtime check and the test continue
  to pass without modification.

### Read-only callees / state shapes — verified, not modified

- **A-027 — `bin/poll.sh::_poll_classify_labels` halted branch (lines
  217-233) vacates issues with `pipeline:halted`.** Verified — an
  operator-applied or budget-exhausted halt at `stage:building`
  prevents `run-stage.sh` from being dispatched, so the gate does
  not run. The operator's standard recovery
  (`bash bin/pipeline.sh decide ENG-N --action continue`) clears
  the halt; on the NEXT tick `run-stage.sh` is dispatched and the
  gate fires cleanly. Same primitive operators already use for
  ENG-58's atomic-resume contract — no new operator workflow.

- **A-028 — `bin/verdict-handler.sh::find_fresh_verdict` excludes
  `result=wait` markers at line 113.** Verified. The gate posts a
  `pipeline: transition from=building to=released` waypoint via
  `apply_transition` at `bin/verdict-handler.sh:158-162`. The
  waypoint is a `transition` event, not a `verdict`, so it sets the
  freshness floor for any subsequent `find_fresh_verdict` call.
  Stale wait markers from the pre-merge dispatches are correctly
  invisible after the transition.

- **A-029 — `bin/pipeline-events.json::stages` includes both
  `building` and `released`.** Verified at lines 47-56. No registry
  edit needed.

- **A-030 — `bin/pipeline-events.json::halt_reasons` does NOT
  contain `external-signal-budget-exhausted`.** Verified at lines
  10-19 (only `agent-blocked`, `agent-failure`, `smoke-failed`,
  `iteration-exhausted`, `scope-violation`, `protocol-violation`,
  `dispatch-timeout`, `pr-opened-too-early`). The pre-existing
  registry gap noted in the brainstorm §9 is OUT OF SCOPE for
  ENG-62. `_handle_wait`'s halt-comment post at
  `bin/run-stage.sh:454-456` uses `linear.sh add-comment` directly
  (bypassing `pipeline.sh event` registry validation), so runtime
  works — but the gap should be filed as a separate Linear issue
  per brainstorm §9 (recommended title: "Register
  `external-signal-budget-exhausted` in `pipeline-events.json::halt_reasons`
  or migrate `_handle_wait` to a registered reason"). NOT bundled
  here.

### Assumed/new artifacts

- **A-N1 — `_pre_dispatch_merge_gate` private helper is NEW** in
  `bin/run-stage.sh`. Will live above `main()` (alongside the other
  pre-`main` helpers `_post_dispatch_apply_halt`, `_handle_wait`,
  `_post_review_dispatch_update`). The helper definition site:
  immediately after `_post_review_dispatch_update`'s closing brace
  at `bin/run-stage.sh:493`, before the `main() {` declaration at
  `bin/run-stage.sh:495`. Returns 0 = gate fired and transition
  applied (caller MUST `exit 0` after); returns 1 = gate did not
  fire (caller proceeds to render-prompt + dispatch). Pure
  side-effect-on-success: no caller-visible state change on the
  rc=1 path beyond the read-only `gh` query.

- **A-N2 — Stage-summary content for the merged-pre-dispatch case is
  NEW.** A one-line summary at `$(issue_dir "$ident")/stage-summary-building.md`:
  "Pre-dispatch merge detection (ENG-62): PR on `<branch>` was
  already MERGED at orchestrator entry. Transitioned `building →
  released` without invoking the build agent." No prior file at this
  path is overwritten; if the prior dispatch wrote one, the new
  content overwrites it (the success-path semantics in
  `bin/run-stage.sh:851-855` already overwrite stage summaries on
  every tick).

- **A-N3 — Metrics outcome `merged-pre-dispatch` is NEW.**
  No `bin/metrics.sh` schema change needed (A-025); `events.jsonl`
  receives one new row per gate fire with `outcome:"merged-pre-dispatch"
  stage:"building" duration_ms:<n>`. Q1 from the brainstorm §7
  (verify `bin/run-retrospective-local.sh`'s §1 filter accepts the
  literal) is a post-implementation dry-run check (Task 6), not a
  schema change.

- **A-N4 — `learned-rules/harness/build.md` is NEW.** Currently
  `learned-rules/harness/` contains only `project-profile.md`
  (verified: `ls learned-rules/harness/` returns
  `project-profile.md`). The new file follows the
  `learned-rules/twinning/build.md` header convention (the canonical
  "Learned Rules — Build Agent" template) and adds Rule Bld-001 per
  brainstorm §D-004. Per AC-2, the `pipeline:rule-reviewed` label
  gate applies — the entry lands as part of the implementation PR
  with the label applied at merge time. The brainstorm itself does
  not write `learned-rules/harness/build.md`; this plan does.

- **A-N5 — `AGENT_PROMPTS.md` § 7 P0 clause is NEW** above existing
  P1 at line 1213, plus a one-sentence reference in the
  precondition-ordering clause at lines 1208-1211. Both are
  inside the existing § 7 fence; render-prompt-test.sh continues to
  pass.

- **A-N6 — Test cases A–F are NEW** in `bin/run-stage-test.sh`,
  appended after the last existing case (the file is 2210 lines;
  insertion is at the END of the test body, before the existing
  `pass_at`/`fail_at` summary at the bottom — see Task 3 for exact
  line). Cases A–D are minimum-viable per AC-1; Cases E and F pin
  the partial-failure-recovery and fail-open-on-tooling-absence
  invariants.

## File Structure

```
bin/
  run-stage.sh         modified  — add _pre_dispatch_merge_gate helper above
                                    main() (between line 493 and line 495);
                                    insert gate-firing block in main() between
                                    skip_dispatch (line 541) and the per-issue
                                    mkdir (line 546).
                                    (Tasks 1, 2)
  run-stage-test.sh    modified  — extend gh stub at lines 46-52 with
                                    MOCK_GH_PR_STATE arm (preserve
                                    MOCK_GH_PR_URL for back-compat); append
                                    cases ENG-62 A–F at end of file before
                                    the RESULTS summary.
                                    (Task 3)

AGENT_PROMPTS.md       modified  — insert "P0. Merge state precheck" block
                                    above existing P1 at line 1213;
                                    add one-sentence cross-reference to P0 in
                                    the precondition-ordering clause at lines
                                    1208-1211. (Task 4)

learned-rules/
  harness/
    build.md           NEW       — Rule Bld-001 (ENG-62). Header template
                                    mirrors learned-rules/twinning/build.md.
                                    (Task 5)
```

No changes to: `bin/poll.sh`, `bin/verdict-handler.sh`,
`bin/classify-failure.sh`, `bin/linear.sh`, `bin/dispatch.sh`,
`bin/on-new-release.sh`, `bin/pipeline-events.json`, `bin/common.sh`,
`bin/metrics.sh`, `bin/render-prompt.sh`, `bin/halt-sprawl-test.sh`,
`bin/halt-sprawl-adversarial-test.sh`, `bin/run-local.sh`,
`bin/run-local-helpers.sh`, `bin/run-local-sweep-test.sh`,
`bin/scope-check.sh`, `bin/branch-name.sh`, `bin/guards.sh`,
`bin/halt.sh`, `bin/setup.sh`, `launchd/**`, `.github/workflows/**`.

## API Contract

**No new API surface.** The harness has no FE↔BE API surface; the
build stage is an orchestrator-driven CLI flow. The change adds:

- One new metrics outcome literal (`merged-pre-dispatch`) — written
  verbatim by the pre-existing `bin/metrics.sh stage-end` helper (no
  schema migration; A-025, A-N3).
- One new precondition (P0) inside the existing `AGENT_PROMPTS.md` §7
  fence (no new fence; render-prompt.sh's two-fences-per-section
  invariant preserved per A-026).
- One new file `learned-rules/harness/build.md` (no new schema; mirrors
  the `learned-rules/twinning/build.md` header template).

No CLI argv change, no env-var addition, no on-disk state-file format
change, no new exit code (the gate exits 0; the caller's `exit "$rc"`
shape on line 512 / line 576 / line 589 / line 594 is preserved).

---

## Backend Tasks

(The harness has only "backend" code in the bash-script sense — see
*Frontend Tasks* below for the no-op statement.)

### Task 1: Add `_pre_dispatch_merge_gate` helper to `bin/run-stage.sh`

- `depends_on: []`
- `touches: bin/run-stage.sh (new function _pre_dispatch_merge_gate at line ~494, between _post_review_dispatch_update at line 493 and main() at line 495)`

- [ ] In `bin/run-stage.sh`, INSERT the new helper between
      `_post_review_dispatch_update`'s closing brace at line 493 and
      `main() {` at line 495. Place it AFTER the other private helpers
      (`_fresh_wait_reason`, `_post_dispatch_apply_halt`, `_handle_wait`,
      `_post_review_dispatch_update`) so source order matches the
      ordering convention already in place.

- [ ] Helper body — `_pre_dispatch_merge_gate` (D-001 / D-006). Returns
      0 if the gate fires and `apply_transition` ran end-to-end (caller
      MUST `exit 0` after). Returns 1 otherwise. Stage-gated to
      `building`. Fail-open on `gh` outage / branch-derivation failure.

      ```bash
      # ENG-62: pre-dispatch merge-detection gate. If the PR for stage=building
      # is already MERGED (e.g., a prior dispatch fired `gh pr merge --auto`
      # successfully), there is nothing left for the build agent to do —
      # dispatching costs ≈ $1.50 and risks an awaiting-approval emission
      # from the prompt-following regression observed on ENG-43 / ENG-58.
      # Returns 0 = gate fired, transition applied (caller must exit).
      # Returns 1 = gate did not fire (caller proceeds to dispatch).
      # Stage-gated to "building" — only stage with PR-merge semantics today.
      # Fail-open on gh outage / branch-derivation failure (D-006).
      _pre_dispatch_merge_gate() {
        # Lane attribution (security): mirror _handle_wait at lines 382-383.
        # File-scope inheritance is correct today, but explicit assignment
        # prevents silent lane-violation if a future caller invokes this
        # helper from an agent sub-shell.
        local PIPELINE_WRITER=orchestrator
        export PIPELINE_WRITER

        local ident="$1" stage="$2"
        case "$stage" in building) ;; *) return 1 ;; esac
        command -v gh >/dev/null 2>&1 || return 1

        local _branch
        _branch="$(bash "$SCRIPT_DIR/branch-name.sh" "$ident" 2>/dev/null || printf '')"
        [[ -n "$_branch" ]] || return 1

        # --state all so a --delete-branch'd merged PR is still found.
        # Mirrors run-stage.sh:160's --state all fallback for pr_url.
        local _pr_state
        _pr_state="$(gh pr list --head "$_branch" --state all --json state \
                      --jq '.[0].state // ""' 2>/dev/null || printf '')"
        [[ "$_pr_state" == "MERGED" ]] || return 1

        log "build pre-dispatch: PR for $_branch is MERGED; transitioning building → released without invoking agent (ENG-62)"

        # Stage-summary for retrospective archaeology.
        local _summary_path
        _summary_path="$(issue_dir "$ident")/stage-summary-${stage}.md"
        mkdir -p "$(dirname "$_summary_path")"
        printf 'Pre-dispatch merge detection (ENG-62): PR on `%s` was already MERGED at orchestrator entry. Transitioned `building → released` without invoking the build agent.\n' \
          "$_branch" > "$_summary_path"

        # Success-path state cleanup, mirroring run-stage.sh:851-855.
        rm -f "$(issue_dir "$ident")/wait-${stage}.json" 2>/dev/null || true
        rm -f "$(issue_dir "$ident")/issue-state.json"     2>/dev/null || true

        # Apply the transition directly. Each step in apply_transition is
        # idempotent (verdict-handler.sh:158-184); on partial failure
        # (Linear add-label outage) the next tick re-enters cleanly.
        apply_transition "$ident" "building" "released" "" || true

        return 0
      }
      ```

- [ ] Verify the helper parses cleanly: `bash -n bin/run-stage.sh`
      exits 0.

- [ ] Verify no secret-leak patterns introduced:
      `bash bin/secret-probe-lint.sh` exits 0. (The new helper uses no
      `${VAR:-X}` patterns against secret-named env vars; A-014.)

### Task 2: Wire the gate into `main()`

- `depends_on: [1]`  *(uses helper from Task 1)*
- `touches: bin/run-stage.sh::main (insert block between line 541 and line 546)`

- [ ] In `bin/run-stage.sh::main()`, INSERT the gate-firing block
      AFTER the `skip_dispatch` block at line 541 (closing `fi`) and
      BEFORE the `mkdir -p "$(issue_dir "$ident")"` at line 546. The
      structural anchors are stable across unrelated edits in this
      neighbourhood (the `skip_dispatch` `fi` and the per-issue
      `mkdir` are both load-bearing for the surrounding flow).

- [ ] Block body — gate dispatch + metrics + clean exit:

      ```bash
        # ENG-62: pre-dispatch merge-detection gate. If the PR for
        # stage=building is already MERGED (e.g., a prior dispatch fired
        # `gh pr merge --auto` successfully), there is nothing left for
        # the build agent to do — dispatching costs ≈ $1.50 and risks an
        # awaiting-approval emission from a prompt-following regression.
        # Apply the transition directly and exit.
        if _pre_dispatch_merge_gate "$ident" "$stage"; then
          t1="$(date +%s)"; duration=$(( (t1 - t0) * 1000 ))
          bash "$SCRIPT_DIR/metrics.sh" stage-end "$ident" "$stage" \
            "merged-pre-dispatch" "$duration" || true
          exit 0
        fi
      ```

      Variable scope notes:
      - `t0` was set at `bin/run-stage.sh:500` (verified, present in
        every code path that reaches this insertion point).
      - `apply_transition` is in scope via the source at
        `bin/run-stage.sh:21-22` (A-002).
      - `SCRIPT_DIR` is set at `bin/run-stage.sh:16` (file-scope global
        established at the top of the script).
      - `issue_dir` is sourced from `common.sh` (A-024).

- [ ] Verify the file parses: `bash -n bin/run-stage.sh` exits 0.

- [ ] Verify the test entry-point still resolves: `grep -n
      '^if \[\[ "\${BASH_SOURCE\[0\]}"' bin/run-stage.sh` returns one
      hit at line ~879+ (sentinel preserved; A-008).

### Task 3: Append cases A–F to `bin/run-stage-test.sh`

- `depends_on: [1, 2]`  *(asserts behavior introduced by Tasks 1+2)*
- `touches: bin/run-stage-test.sh (extend gh stub at lines 46-52; append cases A–F at end of file before the test summary)`

The existing test harness already provides:
- `STUB_DIR`-rooted `linear.sh` / `branch-name.sh` / `gh` stubs
  (lines 21-52).
- `CAPTURE_FILE` log of every non-`get-comments`/non-`stage-of`
  `linear.sh` invocation (lines 32-33, also rebuilt at lines 890-905).
- `PROJECT_STATE_DIR`-rooted scratch space (lines 91-95).
- Source-and-call pattern for helpers (`bin/run-stage-test.sh:907-989`
  for `_fresh_wait_reason`, `bin/run-stage-test.sh:991+` for
  `_handle_wait`).

The new cases use the same pattern: drive
`_pre_dispatch_merge_gate "$ident" "$stage"` through the source, set
`MOCK_GH_PR_STATE` / `MOCK_GH_BRANCH` / etc. to fixture values, and
assert on the helper's return code AND on `CAPTURE_FILE` substring
matches for the `apply_transition` side effects.

- [ ] REPLACE the `gh` stub at lines 46-52 with a `--json`-aware
      variant. Preserve `MOCK_GH_PR_URL` for back-compat with all
      existing cases that test post_completion_comment's PR-tail
      derivation.

      ```bash
      # Toggleable gh stub: routes by --json arg.
      #   MOCK_GH_PR_URL   — controls `gh pr list --json url` output.
      #   MOCK_GH_PR_STATE — controls `gh pr list --json state` output. (ENG-62)
      cat > "$STUB_DIR/gh" <<'SH'
      #!/usr/bin/env bash
      # Walk argv to find the --json value (next arg after --json).
      json_arg=""
      while [[ $# -gt 0 ]]; do
        if [[ "$1" == "--json" ]]; then
          json_arg="${2-}"
          break
        fi
        shift
      done
      case "$json_arg" in
        state) printf '%s' "${MOCK_GH_PR_STATE-}" ;;
        url|*) printf '%s' "${MOCK_GH_PR_URL-}" ;;
      esac
      SH
      chmod +x "$STUB_DIR/gh"
      ```

      Note on env-var fallback shape: `${MOCK_GH_PR_STATE-}` and
      `${MOCK_GH_PR_URL-}` use the single-dash `${VAR-}` form — empty
      when the variable is unset OR empty. Both shapes match
      neither the secret-name pattern nor the lint's
      `${VAR:-FALLBACK}` matcher in `bin/secret-probe-lint.sh`
      (A-014); lint clean by construction.

- [ ] Append cases A–F at the END of `bin/run-stage-test.sh` (after
      the last existing case, before whatever final summary the file
      uses — verify by reading the last 30 lines of the file before
      inserting). Use the existing `pass_at` / `fail_at` helpers.

      Each case sets the `gh` stub's controlling env var, calls
      `_pre_dispatch_merge_gate`, captures rc, and asserts on rc plus
      `CAPTURE_FILE` substring matches for the `apply_transition`
      side effects (`add-label stage:released`,
      `remove-label stage:building`, `add-comment` with the
      transition body).

      Pre-case shared setup (insert ONCE before Case A):

      ```bash
      # ─── ENG-62 fixture helpers ─────────────────────────────────────
      _eng62_reset_capture() {
        : > "$CAPTURE_FILE"
      }
      _eng62_capture_count() {
        # Count occurrences of a substring in CAPTURE_FILE.
        local pat="$1"
        grep -c "$pat" "$CAPTURE_FILE" 2>/dev/null || true
      }
      ```

      ```bash
      # ─── ENG-62 Case A: gate fires on MERGED (D-001 happy path) ─────
      _eng62_reset_capture
      MOCK_GH_PR_STATE="MERGED"
      mkdir -p "$(issue_dir ENG-62T1)"
      printf '{}' > "$(issue_dir ENG-62T1)/wait-building.json"   # seeded; gate must remove
      printf '{}' > "$(issue_dir ENG-62T1)/issue-state.json"     # seeded; gate must remove
      rc=0
      _pre_dispatch_merge_gate ENG-62T1 building || rc=$?
      summary_present=0; [[ -s "$(issue_dir ENG-62T1)/stage-summary-building.md" ]] && summary_present=1
      wait_present=0;    [[ -e "$(issue_dir ENG-62T1)/wait-building.json" ]]      && wait_present=1
      state_present=0;   [[ -e "$(issue_dir ENG-62T1)/issue-state.json" ]]        && state_present=1
      add_label_released="$(_eng62_capture_count 'SUBCMD=add-label$')"
      remove_label_building="$(_eng62_capture_count 'SUBCMD=remove-label$')"
      transition_post="$(_eng62_capture_count 'pipeline: transition from=building to=released')"
      if [[ "$rc" == 0 \
            && "$summary_present" == 1 \
            && "$wait_present" == 0 \
            && "$state_present" == 0 \
            && "$add_label_released" -ge 1 \
            && "$remove_label_building" -ge 1 \
            && "$transition_post" -ge 1 ]]; then
        pass_at "ENG-62 case A: gate fires on MERGED (transition + cleanup applied)"
      else
        fail_at "ENG-62 case A" \
          "rc=$rc summary=$summary_present wait=$wait_present state=$state_present add=$add_label_released remove=$remove_label_building transition=$transition_post"
      fi

      # ─── ENG-62 Case B: gate skips on non-MERGED (D-006 contract) ───
      # Iterate three non-MERGED states + empty; assert rc=1 and zero
      # apply_transition side effects on each.
      for _state in OPEN CLOSED DRAFT ""; do
        _eng62_reset_capture
        MOCK_GH_PR_STATE="$_state"
        rc=0
        _pre_dispatch_merge_gate ENG-62T2 building || rc=$?
        side_effects="$(_eng62_capture_count 'SUBCMD=add-label\|SUBCMD=remove-label\|pipeline: transition')"
        if [[ "$rc" == 1 && "$side_effects" == 0 ]]; then
          pass_at "ENG-62 case B: gate skips on state='$_state' (rc=1, no side effects)"
        else
          fail_at "ENG-62 case B (state='$_state')" "rc=$rc side_effects=$side_effects"
        fi
      done
      unset _state

      # ─── ENG-62 Case C: stage allow-list (security parallel) ─────────
      # Non-building stages must be rejected even with MERGED stub.
      MOCK_GH_PR_STATE="MERGED"
      for _stage in implementing ui reviewing qa planning brainstorming released; do
        _eng62_reset_capture
        rc=0
        _pre_dispatch_merge_gate ENG-62T3 "$_stage" || rc=$?
        side_effects="$(_eng62_capture_count 'SUBCMD=add-label\|SUBCMD=remove-label\|pipeline: transition')"
        if [[ "$rc" == 1 && "$side_effects" == 0 ]]; then
          pass_at "ENG-62 case C: stage='$_stage' rejected by allow-list (rc=1)"
        else
          fail_at "ENG-62 case C (stage='$_stage')" "rc=$rc side_effects=$side_effects"
        fi
      done
      unset _stage

      # ─── ENG-62 Case D: branch-derivation failure (D-006 fail-open) ──
      # Replace branch-name.sh stub with one that returns empty; gate
      # must return 1 with no side effects (dispatch proceeds as today).
      MOCK_GH_PR_STATE="MERGED"
      cat > "$STUB_DIR/branch-name.sh" <<'SH'
      #!/usr/bin/env bash
      printf ''
      SH
      chmod +x "$STUB_DIR/branch-name.sh"
      _eng62_reset_capture
      rc=0
      _pre_dispatch_merge_gate ENG-62T4 building || rc=$?
      side_effects="$(_eng62_capture_count 'SUBCMD=add-label\|SUBCMD=remove-label\|pipeline: transition')"
      if [[ "$rc" == 1 && "$side_effects" == 0 ]]; then
        pass_at "ENG-62 case D: empty branch-name → fail-open (rc=1, no side effects)"
      else
        fail_at "ENG-62 case D" "rc=$rc side_effects=$side_effects"
      fi
      # Restore the canonical branch-name.sh stub for subsequent cases.
      cat > "$STUB_DIR/branch-name.sh" <<'SH'
      #!/usr/bin/env bash
      printf 'feat/%s-mock-slug\n' "$(tr '[:upper:]' '[:lower:]' <<<"$1")"
      SH
      chmod +x "$STUB_DIR/branch-name.sh"

      # ─── ENG-62 Case E: apply_transition partial-failure idempotency ─
      # First invocation: linear.sh stub returns 1 on the first
      # `add-label stage:released` call (Linear outage). Gate's
      # `apply_transition ... || true` swallows the error; gate still
      # returns 0. Second invocation with linear.sh restored to noop
      # success → gate returns 0 again, idempotently.
      MOCK_GH_PR_STATE="MERGED"
      mkdir -p "$(issue_dir ENG-62T5)"
      _eng62_reset_capture
      # Replace linear.sh with a one-shot-failure variant.
      cat > "$STUB_DIR/linear.sh" <<SH
      #!/usr/bin/env bash
      # Capture every call into CAPTURE_FILE for asserting; first
      # add-label invocation returns 1, all subsequent calls return 0.
      printf 'SUBCMD=%s\nSIG=%s\nIDENT=%s\nBODY_BEGIN\n%s\nBODY_END\n---\n' \
        "\${1:-}" "\${2:-}" "\${3:-}" "\${4:-}" >> "$CAPTURE_FILE"
      if [[ "\${1:-}" == "add-label" && ! -f "$STUB_DIR/.eng62_first_add_done" ]]; then
        : > "$STUB_DIR/.eng62_first_add_done"
        exit 1
      fi
      exit 0
      SH
      chmod +x "$STUB_DIR/linear.sh"
      rc1=0
      _pre_dispatch_merge_gate ENG-62T5 building || rc1=$?
      # Second invocation: linear.sh now succeeds on every call.
      _eng62_reset_capture
      rc2=0
      _pre_dispatch_merge_gate ENG-62T5 building || rc2=$?
      transition_post_2="$(_eng62_capture_count 'pipeline: transition from=building to=released')"
      add_label_released_2="$(_eng62_capture_count 'SUBCMD=add-label$')"
      if [[ "$rc1" == 0 && "$rc2" == 0 \
            && "$transition_post_2" -ge 1 \
            && "$add_label_released_2" -ge 1 ]]; then
        pass_at "ENG-62 case E: partial-failure recovery (both invocations rc=0; second produces full transition)"
      else
        fail_at "ENG-62 case E" "rc1=$rc1 rc2=$rc2 transition2=$transition_post_2 add2=$add_label_released_2"
      fi
      rm -f "$STUB_DIR/.eng62_first_add_done"
      # Restore the canonical linear.sh stub for subsequent cases (mirrors lines 890-905).
      cat > "$STUB_DIR/linear.sh" <<SH
      #!/usr/bin/env bash
      case "\${1:-}" in
        get-comments) printf '%s' "\${MOCK_COMMENTS_JSON-[]}" ;;
        stage-of)     printf 'stage:qa\n' ;;
        *)
          printf 'SUBCMD=%s\nSIG=%s\nIDENT=%s\nBODY_BEGIN\n%s\nBODY_END\n---\n' \
            "\${1:-}" "\${2:-}" "\${3:-}" "\${4:-}" >> "$CAPTURE_FILE"
          ;;
      esac
      exit 0
      SH
      chmod +x "$STUB_DIR/linear.sh"

      # ─── ENG-62 Case F: gh not in PATH → fail-open ────────────────────
      # Move the gh stub aside; gate's `command -v gh` check returns 1.
      mv "$STUB_DIR/gh" "$STUB_DIR/gh.disabled"
      _eng62_reset_capture
      rc=0
      _pre_dispatch_merge_gate ENG-62T6 building || rc=$?
      side_effects="$(_eng62_capture_count 'SUBCMD=add-label\|SUBCMD=remove-label\|pipeline: transition')"
      if [[ "$rc" == 1 && "$side_effects" == 0 ]]; then
        pass_at "ENG-62 case F: gh missing from PATH → fail-open (rc=1, no side effects)"
      else
        fail_at "ENG-62 case F" "rc=$rc side_effects=$side_effects"
      fi
      mv "$STUB_DIR/gh.disabled" "$STUB_DIR/gh"
      ```

- [ ] Run `bash bin/run-stage-test.sh` — must exit 0 with PASS lines
      for the existing cases PLUS the new ENG-62 cases A–F (the
      sub-iterations in cases B and C produce 4+7=11 additional PASS
      lines beyond the case label). The terminal summary should
      report all PASS.

- [ ] Run `bash bin/render-prompt-test.sh` — must remain green (no
      AGENT_PROMPTS.md changes from this task).

- [ ] Run `bash bin/verdict-handler-test.sh` — must remain green (no
      verdict-handler.sh changes; A-013 confirms `apply_transition`
      idempotency unchanged).

- [ ] Run `bash bin/poll-slot-test.sh` — must remain green (no poll.sh
      changes; A-019 confirms the else branch unchanged).

### Task 4: Add P0 precondition to AGENT_PROMPTS.md §7 Build Agent

- `depends_on: []`
- `touches: AGENT_PROMPTS.md (insert above line 1213; one-sentence ref at lines 1208-1211)`

- [ ] In `AGENT_PROMPTS.md`, INSERT the P0 block immediately before the
      existing P1 at line 1213. Place it AFTER the existing
      precondition-ordering clause at lines 1208-1211 (so P0 is
      logically the FIRST precondition, evaluated before the ordering
      clause's "if P1, P3, P4, P6, P7 fail" sentence binds).

      The inserted block (NO column-0 ``` fence — it lives inside the
      existing § 7 fence, per A-015):

      ```
        P0. **Merge state precheck.** Before evaluating P1–P7, run:
              gh pr list --head {branch_name} --state all --json state \
                --jq '.[0].state // ""'
            If this returns `MERGED`, the PR is already merged. Run:
              bash bin/pipeline.sh event {issue_id} verdict pass --stage building
            and exit. Do NOT evaluate P1–P7.

            The orchestrator's pre-dispatch gate (ENG-62, in
            `bin/run-stage.sh::_pre_dispatch_merge_gate`) uses the
            IDENTICAL query and short-circuits before you are dispatched
            in this state, so this clause is defense-in-depth.

            If the query returns empty (no PR record at all on this
            branch), proceed to evaluate P1–P7; P1 will catch the
            missing PR and the precondition-ordering clause routes to
            the `agent-blocked` halt.
      ```

- [ ] In the precondition-ordering clause at lines 1208-1211, ADD one
      sentence prefacing the existing prose. The current text:

      ```
      **Precondition ordering (ENG-45):** If P1, P3, P4, P6, or P7 fail, run
      `bash bin/pipeline.sh event {issue_id} verdict halt --reason agent-blocked`
      and exit. The wait path on P2 / P5 below applies ONLY when every other
      precondition has passed and the only failure is P2 or P5.
      ```

      becomes:

      ```
      **Precondition ordering (ENG-45 / ENG-62):** If P0 already determined
      `state == MERGED`, you do not reach this ordering clause — exit per P0.
      Otherwise, if P1, P3, P4, P6, or P7 fail, run
      `bash bin/pipeline.sh event {issue_id} verdict halt --reason agent-blocked`
      and exit. The wait path on P2 / P5 below applies ONLY when every other
      precondition has passed and the only failure is P2 or P5.
      ```

- [ ] Verify the fence count is unchanged: `awk '/^## 7\. Build Agent$/,/^## 8\. Release Agent$/' AGENT_PROMPTS.md | grep -c '^```'` must print `2` (one open at line 1193, one close at line 1418; A-015).

- [ ] Run `bash bin/render-prompt-test.sh` — must remain green
      (extracts § 7 by header and validates fence count; A-026).

### Task 5: Hand-seed `learned-rules/harness/build.md`

- `depends_on: []`
- `touches: learned-rules/harness/build.md (NEW file)`

- [ ] Create `learned-rules/harness/build.md` with the header template
      mirrored from `learned-rules/twinning/build.md` plus the
      Bld-001 entry per brainstorm §D-004. Per AC-2, the
      `pipeline:rule-reviewed` label gate applies — the entry lands
      as part of the implementation PR with the label applied at
      merge time.

      File body:

      ```markdown
      # Learned Rules — Build Agent

      > **Who writes:** Retrospective agent (from failed merges, broken
      >                 post-merge CI, and config-drift incidents).
      > **Who reads:** Build agent (appended to base prompt at dispatch time).
      > **Format:** Each rule is a directive the agent must follow, with
      >             context on why.
      > **Shelf life:** 60 days. If the problem hasn't recurred, the rule
      >                 may be unnecessary.
      > **Human checkpoint:** New rules require human approval before
      >                       commit (see .pipeline/config.json).

      ---

      ### Rule Bld-001: post-merge dispatches must short-circuit on `state == MERGED`
      **Added:** 2026-05-06
      **Expires:** 2026-07-05
      **Last verified:** 2026-05-06
      **Source:** ENG-62 — five wasted dispatches per merged PR observed
                  on ENG-43 (PR #41) and ENG-58 (PR #42), 2026-05-02.
                  Agent emitted `verdict wait --reason awaiting-approval`
                  post-merge despite a non-bot APPROVED review existing
                  and the prompt being correctly written against
                  `gh pr view --json reviews` (per commit 941218f9).

      **Rule:** Before evaluating P1–P7, run

          gh pr list --head {branch_name} --state all --json state \
            --jq '.[0].state // ""'

      If the result is `MERGED`, run

          bash bin/pipeline.sh event {issue_id} verdict pass --stage building

      and exit. The orchestrator's pre-dispatch gate
      (`bin/run-stage.sh::_pre_dispatch_merge_gate`) uses the IDENTICAL
      query and short-circuits BEFORE you are dispatched in this state;
      this rule is the agent-side belt to the orchestrator's braces. The
      symmetric query shape is load-bearing — divergent definitions of
      "post-merge" (e.g., one path uses `gh pr view --json state` which
      requires a PR number) would inevitably drift.

      **Why:** Post-merge, `gh pr list --head <branch> --state open`
      returns 0 PRs because `gh pr merge --auto --delete-branch` deletes
      the branch ref. The precondition-ordering clause says P1 fail
      should halt-for-human, but agents in production have been observed
      to fall back to `gh pr view --json reviewDecision` (the brittle
      pre-941218f9 path) and emit a wait verdict instead. The
      orchestrator gate eliminates the dispatch cost; this prompt-side
      rule is defense-in-depth for any future code path that invokes
      `dispatch.sh` outside `run-stage.sh::main`.

      **Evidence:** docs/brainstorms/2026-05-06-eng-62-build-p2-still-emits-awaiting-approval-on-post-merge-dispatches-despite-non-bot-approved-review-existing-design.md
      §1.2; metrics events `outcome=merged-pre-dispatch` in
      `$PROJECT_STATE_DIR/metrics/events.jsonl` after the gate ships.
      ```

- [ ] Verify the file exists and is readable: `[[ -s
      learned-rules/harness/build.md ]]` exits 0.

- [ ] Verify the file does not break shell-clients that read
      learned-rules: `bash bin/render-prompt.sh build ENG-62 >/dev/null
      2>&1; rc=$?` — `rc=0` is required (the renderer treats per-stage
      learned-rules as plain markdown appendage; no schema check).

### Task 6: Post-merge verification (Q1 follow-up from brainstorm §7)

- `depends_on: [1, 2, 3, 4, 5]`
- `touches: none (operator-side dry-run check; not a code change)`

This task is the brainstorm §7 Q1 verification: confirm
`bin/run-retrospective-local.sh`'s §1 outcome filter accepts the new
literal `merged-pre-dispatch` without silent-drop.

- [ ] After the implementation PR merges, run the retrospective in
      dry-run on a metrics file containing one
      `outcome=merged-pre-dispatch` row (synthesise via `bash
      bin/metrics.sh stage-end ENG-62-test building merged-pre-dispatch
      0 || true` against a scratch `$PROJECT_STATE_DIR`):

          PIPELINE_DRY_RUN=1 TARGET_REPO=/path/to/target \
            bash bin/run-retrospective-local.sh

      Expected: the retrospective parses the row, classifies it, and
      does NOT silently drop it. If it does drop the row, file a
      separate Linear issue (do NOT bundle here per scope discipline)
      titled "Register `merged-pre-dispatch` outcome in retrospective
      §1 filter."

- [ ] Document the verification result in a one-line follow-up
      comment on ENG-62 (`bash bin/linear.sh add-comment ENG-62 ...`).
      This is the operator's audit trail; the gate's runtime behavior
      does not depend on it.

---

## Frontend Tasks

**No frontend tasks.** The harness has no UI/frontend surface — it is
bash orchestration scripts (verified at
`learned-rules/harness/project-profile.md` Stack section: "Bash 3.2+
orchestration scripts (macOS-compatible). The repo contains no
application code…"). The "UI Agent" stage in the pipeline is a
pass-through for harness-self dispatches per `AGENT_PROMPTS.md §4`.

---

## Failure Mode → Test Map

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
|---|---|---|---|---|
| Post-merge dispatch wastes ≈ $1.50 by emitting `verdict wait --reason awaiting-approval` despite a non-bot APPROVED review existing (the ENG-62 root cause) | `gh pr list --head <branch> --state all --json state` returns `MERGED` at orchestrator entry to `stage:building` | Gate fires before `dispatch.sh`; `apply_transition building → released` runs end-to-end; stage-summary file written; `wait-building.json` and `issue-state.json` removed; `metrics.sh stage-end` records `outcome=merged-pre-dispatch` | unit | `bin/run-stage-test.sh` ENG-62 case A |
| Pre-merge tick (PR still OPEN / DRAFT / CLOSED-but-not-merged / no PR record) accidentally fires the gate, prematurely advancing an unmerged issue to `stage:released` | `gh pr list --head <branch> --state all --json state` returns `OPEN`, `DRAFT`, `CLOSED`, or empty | Gate returns 1 with zero side effects; caller proceeds to `dispatch.sh` as today | unit | `bin/run-stage-test.sh` ENG-62 case B (4 sub-iterations: OPEN, CLOSED, DRAFT, empty) |
| Cross-stage forgery: a non-`building` stage (`implementing`, `ui`, `reviewing`, `qa`, `planning`, `brainstorming`, `released`) somehow triggers the gate, applying a `building → released` transition on a stage that has no PR-merge semantics | `_pre_dispatch_merge_gate ENG-N <non-building>` invoked even with `MOCK_GH_PR_STATE=MERGED` | Gate returns 1 immediately on the stage allow-list check; zero side effects; zero `gh` calls observed | unit | `bin/run-stage-test.sh` ENG-62 case C (7 sub-iterations: implementing, ui, reviewing, qa, planning, brainstorming, released) |
| `branch-name.sh` returns empty (Linear API down, title unfetchable) — gate must NOT fabricate a transition on an unknown branch | `branch-name.sh` stub returns empty with `MOCK_GH_PR_STATE=MERGED` | Gate returns 1 with zero side effects (fail-open per D-006); caller proceeds to dispatch as today | unit | `bin/run-stage-test.sh` ENG-62 case D |
| `apply_transition` partial failure (transient Linear `add-label` outage on first call) leaves the issue in a half-transitioned state on the second tick — must be re-runnable without double-effect | `linear.sh` stub returns 1 on the FIRST `add-label` invocation, then succeeds on subsequent calls | Both gate invocations return 0 (the `\|\| true` wrappers swallow the rc=1 step); the second invocation completes the transition idempotently; `add-label stage:released` and the transition waypoint are observable in `CAPTURE_FILE` after the second call | unit | `bin/run-stage-test.sh` ENG-62 case E |
| `gh` outage (gh not in PATH OR network/auth error) — gate must NOT fabricate a `MERGED` reading | `command -v gh` fails (gh stub moved aside) | Gate returns 1 with zero side effects (fail-open per D-006); caller proceeds to dispatch as today | unit | `bin/run-stage-test.sh` ENG-62 case F |
| Halted issue at `stage:building` (operator-applied `pipeline:halted` OR budget-exhausted halt) — gate must NOT auto-recover; operator must run `pipeline.sh decide --action continue` first | `poll.sh::_poll_classify_labels` halted branch (lines 217-233) vacates the issue; `run-stage.sh` is not dispatched | Gate does not run; on next-tick after operator resume, gate fires cleanly per case A | integration | covered by `bin/poll-slot-test.sh` (existing — A-027); no new test needed (operator path is documented in CLAUDE.md kill-switch row, ENG-58 atomic-resume primitive) |
| Issue at `stage:released` (terminal) somehow re-enters `run-stage.sh` — gate's stage allow-list rejects, no double transition | `poll.sh:34` excludes `stage:released` from polling; `_pre_dispatch_merge_gate` allow-list rejects the stage anyway | Gate returns 1 immediately; zero side effects | unit | covered by ENG-62 case C (released sub-iteration) |
| Race: PR merges DURING dispatch (after gate decided "not merged") | The race window is the time between `_pre_dispatch_merge_gate`'s `gh` call and `dispatch.sh` invocation; on this tick the agent runs and emits a wait marker (or, with D-002's P0, emits pass directly) | Cost: at most ONE extra dispatch; on tick M+1 the gate catches the `MERGED` state and transitions cleanly per case A. The gate's race-tolerance is implicit in the case A test (a fresh tick post-merge is exactly the case-A scenario) | smoke | covered by ENG-62 case A (the test models this scenario directly) |
| Agent prompt-following regression on a future dispatch-outside-the-gate path (e.g., a hypothetical retry script) — agent emits `awaiting-approval` despite PR being merged | `_pre_dispatch_merge_gate` is bypassed (e.g., manual dispatch); agent runs P0 first; P0 detects MERGED; agent emits `verdict pass --stage building` and exits | Agent-side defense-in-depth fires: the symmetric prompt-side P0 (D-002) catches what the orchestrator-side gate missed; no wait emission | integration | the prompt-side P0 is exercised by `bin/render-prompt-test.sh` (verifies fence count + section extractability — A-026, A-N5); a true semantic test of agent compliance requires a real claude dispatch and is out of scope per scope discipline |

## Test Strategy

- **Unit (Cases A–F in `bin/run-stage-test.sh`):** every code path of
  `_pre_dispatch_merge_gate` is exercised — the MERGED happy path
  (case A); the four non-MERGED PR states OPEN/CLOSED/DRAFT/empty
  (case B); the seven non-building stage allow-list rejections (case
  C); the empty-branch fail-open (case D); the partial-failure
  idempotency contract (case E); the missing-`gh` fail-open (case F).
  Cases B and C use loop-iteration so each sub-state produces its own
  PASS line, giving granular failure attribution if any sub-state
  regresses. Cases E and F respectively pin the two design invariants
  the brainstorm calls out as load-bearing (idempotent-on-retry;
  fail-open-on-tooling-absence). All cases reuse the existing
  source-and-stub harness; no new fixture infrastructure introduced.

- **Integration (existing `bin/poll-slot-test.sh`,
  `bin/verdict-handler-test.sh`):** verify the gate does not regress
  the upstream `poll.sh::_poll_classify_labels` flow (no change to
  the else-branch advanceable=true path, A-019) or the downstream
  `apply_transition` invariants (idempotency at every step, A-013).
  No changes to these test files — the green run is the contract.

- **Smoke (manual, post-deploy):** brainstorm §9 AC-3 verification —
  on the next merged PR (call it ENG-N), wait one tick (≤ 5 min) and
  run `bash bin/pipeline.sh status ENG-N`; expected event sequence
  ends with `<ts> {"event":"transition","from":"building","to":"released"}`
  with NO preceding `verdict pass stage=building` comment in the same
  tick window. That absence is ENG-62's fingerprint (orchestrator
  gate fired, no agent involved). Confirm the metrics row landed via
  `jq -c 'select(.issue=="ENG-N" and .outcome=="merged-pre-dispatch")'
  $PROJECT_STATE_DIR/metrics/events.jsonl | tail -1`. Confirm the
  stage label transitioned cleanly via `bash bin/linear.sh stage-of
  ENG-N` (expects `stage:released`).

- **Adversarial coverage:** the case-C stage allow-list iteration
  exercises the cross-stage forgery surface (security parallel to
  `_fresh_wait_reason`'s build-only gate at A-006). Case-D + case-F
  exercise the fail-open contract under tooling absence (the design's
  named-and-defended availability tradeoff per brainstorm §D-006).
  No new adversarial test file is added — the existing case
  iterations cover the threat model surfaced in brainstorm §10.1
  (Security PASS).

- **Render-prompt regression (`bin/render-prompt-test.sh`):**
  the prompt edit (Task 4) is a text insertion inside the existing
  `## 7. Build Agent` fence; the fence count remains 2. The render
  test extracts § 7 by H2 header and validates the fence count;
  green run after Task 4 confirms no protocol breakage (A-026).

- **Secret-probe lint (`bin/secret-probe-lint.sh`):** the new helper
  uses no `${VAR:-FALLBACK}` patterns against secret-named env vars
  (A-014); the new `gh` stub uses `${MOCK_GH_PR_STATE-}` /
  `${MOCK_GH_PR_URL-}` (single-dash, empty-on-unset) which falls
  outside both the secret-name pattern and the lint's matcher
  (`${VAR:-FALLBACK}`). Lint clean by construction.

## Personas (self-review)

This section records each persona's verdict (PASS / CONCERN / FAIL)
and a one-paragraph summary of resolved findings. Five personas were
run in parallel via the `compound-engineering:document-review` skill
(feasibility, scope, coherence, design, product).

### Iteration 1

- **Feasibility — PASS.** Every cited path:line in the Assumption
  Inventory was re-verified against the current worktree before this
  iteration. Key items confirmed by direct Read:
  `bin/run-stage.sh:21-22` (sources verdict-handler.sh — A-002);
  `bin/run-stage.sh:147-148` (`summary_path` derivation — A-003);
  `bin/run-stage.sh:158-160` (`gh pr list --head ... --state {open,all}
  --json url` pattern — A-004); `bin/run-stage.sh:301-306`
  (`_fresh_wait_reason` allow-list — A-006); `bin/run-stage.sh:381-470`
  (`_handle_wait` lane export — A-005); `bin/run-stage.sh:454-456`
  (linear.sh add-comment direct-body pattern — A-007);
  `bin/run-stage.sh:493` (end of `_post_review_dispatch_update`,
  helper insertion site); `bin/run-stage.sh:495` (`main() {` open);
  `bin/run-stage.sh:534-541` and `bin/run-stage.sh:546`
  (insertion-point boundaries); `bin/run-stage.sh:702-741` (ENG-45
  wait-shape detection runs only inside `! skip_dispatch`, naturally
  bypassed when gate fires — A-022); `bin/run-stage.sh:813`
  (`_post_dispatch_apply_halt` runs only after dispatch — A-023);
  `bin/run-stage.sh:823` (`verdict_handler` call); `bin/run-stage.sh:851-855`
  (success cleanup pattern mirrored by gate); `bin/run-stage.sh:879-881`
  (sentinel — A-008); `bin/run-stage-test.sh:46-52` (gh stub —
  A-009); `bin/run-stage-test.sh:885-905` (rebuilt linear.sh stub —
  A-010); `bin/verdict-handler.sh:6-10` (apply_transition is
  documented public function); `bin/verdict-handler.sh:25-26`
  (building=released forward transition — A-012);
  `bin/verdict-handler.sh:113` (wait-shape exclusion — A-028);
  `bin/verdict-handler.sh:154-184` (apply_transition five idempotent
  steps — A-013); `AGENT_PROMPTS.md:1191` (§7 H2 header);
  `AGENT_PROMPTS.md:1208-1211` (precondition-ordering clause —
  A-016); `AGENT_PROMPTS.md:1213` (existing P1 — A-017);
  `bin/poll.sh:34` (released terminal — A-018); `bin/poll.sh:265-267`
  (else-branch — A-019); `bin/on-new-release.sh:25-58` (sweep
  unchanged — A-020); `bin/branch-name.sh:31` (output format —
  A-021); `bin/pipeline-events.json:47-56` (stages registry — A-029).
  Every task's `depends_on` list is correct (Task 1 has no deps; Task
  2 depends on the helper from Task 1; Task 3 depends on both for
  source-and-call to work; Task 4 has no code deps; Task 5 has no
  code deps; Task 6 depends on the full implementation). Failure Mode
  → Test Map row count (10) matches Test Strategy coverage; every row
  names a plausible test layer + test name (the manual-smoke and the
  agent-compliance row are explicitly noted as out-of-scope-for-unit
  with the test layer escalated accordingly).

- **Scope — PASS.** Every File Structure entry traces to a brainstorm
  decision: `bin/run-stage.sh` ← D-001 (gate) and §3.2-3.3
  (helper sketch + insertion point); `bin/run-stage-test.sh` ←
  D-003 (cases A–F); `AGENT_PROMPTS.md` ← D-002 (P0 prompt clause)
  + §3.4 (precondition-ordering reference); `learned-rules/harness/build.md`
  ← D-004 (hand-seeded rule). No task strays outside its `touches`
  list — every file edit is enumerated. Brainstorm §D-005 explicit
  non-changes (poll.sh, _fresh_wait_reason, _handle_wait,
  on-new-release.sh, dispatch.sh allowlist, pipeline-events.json,
  halt-sprawl-test.sh, run-local-sweep-test.sh, classify-failure.sh,
  scope-check.sh) are all confirmed unchanged in the No-Changes list.
  The `external-signal-budget-exhausted` registry gap (brainstorm §9)
  is surfaced as out-of-scope follow-up rather than bundled (A-030).
  No gold-plating: the gate is the minimal load-bearing primitive;
  the prompt P0 and learned-rules entry are the symmetric
  defense-in-depth complements explicitly motivated by brainstorm
  §1.2's "prompt was rewritten once and the symptom recurred" evidence.

- **Coherence — PASS.** The plan's Goal ("orchestrator pre-dispatch
  gate ... transitions on the FIRST post-merge tick without invoking
  the agent") matches the brainstorm Overview verbatim. Backend Tasks
  1+2 jointly realise D-001's helper-and-call-site contract (helper
  in Task 1, call site in Task 2 — split because Task 1's helper is
  source-and-callable in tests, Task 2's call-site exits the
  process). Task 3's six cases exhaustively cover D-001's contract
  (happy path, four non-MERGED states, seven non-building stages,
  empty-branch fail-open, partial-failure idempotency,
  missing-gh fail-open) per D-003. Task 4 realises D-002 (prompt
  P0 + ordering clause reference). Task 5 realises D-004
  (hand-seeded learned-rules entry). Task 6 closes brainstorm §7 Q1
  (retrospective outcome filter check). The Test Strategy covers
  every Failure Mode row; every Failure Mode row maps to a concrete
  test name in the named test layer. The §6 race-window analysis is
  consistent with the §3 happy-path data flow (gate runs in the same
  tick that detects merge; agent never dispatches). The fail-open
  contract (D-006) is consistent with the §5 error-handling table
  (Cases D and F pin both halves).

- **Design — PASS.** The change respects the run-stage.sh module
  boundary: the helper lives next to its peers
  (`_fresh_wait_reason`, `_post_dispatch_apply_halt`, `_handle_wait`,
  `_post_review_dispatch_update`) which all share the
  `_<verb>_<noun>` naming convention and the `local
  PIPELINE_WRITER=orchestrator; export PIPELINE_WRITER` lane-export
  preamble (A-005). The gate concentrates the change in one
  short-circuit path in `main()`, parallel to the existing
  `skip_dispatch` short-circuit at `bin/run-stage.sh:534-541` —
  no widening into `poll.sh` or a new module. The
  `apply_transition` direct call respects the verdict-handler.sh
  public API (apply_transition is one of three exported functions
  per A-011); no internal call. No new circular deps (the existing
  source at `bin/run-stage.sh:21-22` is preserved; no new sources).
  No layering violations: the gate is orchestrator-side, not
  agent-side; the prompt P0 is agent-side (defense-in-depth), not
  orchestrator-side. The §8.1 brainstorm tradeoff
  (run-stage.sh-vs-poll.sh) is settled and the chosen location
  matches the principle "concentrate the change in one place" applied
  in prior brainstorms (e.g., ENG-58's halt.sh atomic resume at
  `bin/halt.sh::resolve` rather than scattered in poll.sh +
  classify-failure.sh).

- **Product — PASS.** Cost recovery is concrete (≈ $1.50/tick saved,
  $22 wasted in the observed 2026-05-02 session reduced to ~$0).
  Operator-facing surface is unchanged in the happy path (the gate
  is invisible — operators see only that the issue transitioned to
  `stage:released` without the wait-loop comment thread). Operator
  recovery for halted issues uses the existing
  `bash bin/pipeline.sh decide ENG-N --action continue` primitive
  (A-027) — no new operator workflow, no new label, no new sig. The
  fix is visible to operators only as a new metrics outcome
  (`merged-pre-dispatch`) when it fires. Brainstorm §7 Q2's two
  operator queries (avoided-cost counter; weekly health check) give
  ops a documented post-deploy verification path; promotion to
  automated tripwire is correctly deferred to a follow-up if the gate
  is observed to silently fail in the field. The plan's Failure Mode
  → Test Map and Test Strategy include the smoke verification recipe
  per AC-3, so an operator can confirm correctness on the next merged
  PR end-to-end.

**Iteration-1 tally: 5/5 PASS, gate P0 = 0. Proceeding to
implementation.**
