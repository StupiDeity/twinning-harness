---
linear: ENG-71
date: 2026-05-06
topic: build agent's post-merge `git checkout main` locks main globally — close gap with prompt rule + transcript assertion + post-dispatch HEAD detector
---

# Plan — ENG-71 build-agent worktree-HEAD mutation defense

Implementation plan for the design at
`docs/brainstorms/2026-05-06-eng-71-build-agent-checks-out-main-inside-the-per-issue-worktree-post-merge-locking-main-globally-for-the-harness-design.md`.

## Anti-anchoring check

- **Problem (operator's words).** After ENG-61's PR #47 merged, the
  build agent ran `git checkout main && git pull --ff-only origin main`
  inside `~/.local/state/twinning-harness/harness/ENG-61/worktree`. Git
  refuses to have one branch checked out in two worktrees, so the
  operator could no longer `git checkout main` in their primary checkout
  (`~/code/twinning-harness`). Recovery (`git -C <wt> checkout --detach`
  or `git worktree remove --force`) is non-obvious. The agent's tool
  allowlist for the building stage at `bin/dispatch.sh:252` does NOT
  include `Bash(git checkout:*)` or `Bash(git pull:*)`, yet both ran —
  evidence in the worktree reflog (per the issue body).
- **Does the brainstorm address it?** Yes, with three layers
  (D-001 prompt rule, D-002 transcript assertion in dispatch.sh,
  D-003 post-dispatch HEAD-detection in run-stage.sh) plus a test
  pin (D-004) for each. The matcher-bypass investigation itself is
  deliberately deferred to O-1 per the Linear issue's "Suggested
  approach" (ship 1+3 immediately as one PR; defer 2 pending repro).
  This plan implements all three layers since D-002 is
  platform-agnostic and ships independent of the upstream
  matcher-bug investigation.
- **Proportional?** Yes. ~8 lines into AGENT_PROMPTS.md §7,
  ~12 lines into `bin/dispatch.sh::_render_and_capture_stream`,
  ~50 lines into `bin/run-stage.sh` (one new helper +
  one call-site + one rc=26 branch + one header docstring line),
  ~1 line into `bin/common.sh::failure_outcome_for_exit`,
  ~80 lines of test additions across `bin/dispatch-test.sh`
  (AS7-AS12), `bin/run-stage-test.sh` (D-003 fixture), and
  `bin/agent-prompts-content-test.sh` (rule-presence pins),
  ~10 lines added to `docs/runbooks/recovery.md`. No new helper
  function families, no new lane fences, no new state files, no
  cross-crate refactor, no new metric event types added to
  `bin/pipeline-events.json` (the new `worktree-mutated-by-agent`
  metric writes via the existing `bin/metrics.sh` which accepts
  arbitrary event names; `meta_kinds` already carries the
  `metric` discriminator the operator-visibility comment uses).
- **No escalation needed.** PROCEED.

## Goal

Land a single PR off `main` (`feat/eng-71-…`) that, after merge,
satisfies these acceptance criteria — verifiable by:

```
bash bin/agent-prompts-content-test.sh \
  && bash bin/dispatch-test.sh \
  && bash bin/run-stage-test.sh \
  && bash bin/common-test.sh \
  && bash -n bin/dispatch.sh bin/run-stage.sh bin/common.sh \
  && bash bin/secret-probe-lint.sh
```

exiting 0 with the new fixtures (AS7-AS12 in dispatch-test, the new
`_post_dispatch_check_worktree_head` cases in run-stage-test, and the
new ENG-71 grep block in agent-prompts-content-test) all PASS:

1. **Prompt-level (D-001):** `AGENT_PROMPTS.md` §7 carries an explicit
   `MANDATORY worktree-HEAD rule (ENG-71)` paragraph forbidding
   `git checkout`, `git switch`, `git pull`, `git reset` (standalone
   AND chained). The rule is grep-pinned by
   `bin/agent-prompts-content-test.sh`.
2. **Sandbox-level (D-002):** `bin/dispatch.sh::_render_and_capture_stream`
   gates on `stage == "building"` and runs `assert_no_tool_invocation`
   for the four forbidden patterns. On match: writes
   `$violation_file`, returns 26. `bin/run-stage.sh::main` routes
   `dispatch_rc == 26` through `classify_failure ... skip-until-human-acts`
   with the matched command as the operator-facing reason.
   `bin/common.sh::failure_outcome_for_exit` maps 26 →
   `worktree-mutation-forbidden`. `bin/run-stage.sh:4-9` documents
   the new code in the header.
3. **Defense-in-depth (D-003):** `bin/run-stage.sh::main` invokes a
   new `_post_dispatch_check_worktree_head` helper for the building
   stage AFTER `verdict_handler` returns and BEFORE the cost-flags
   loop. The helper detaches HEAD when the worktree is on a branch
   other than the expected `branch-name.sh` output, emits a
   `worktree-mutated-by-agent` metric, and posts a sig-deduped
   `<!-- meta: metric name=worktree-mutated-by-agent -->` Linear
   comment for operator visibility.
4. **Tests (D-004):** AS7-AS12 in `bin/dispatch-test.sh` pin all four
   forbidden patterns + cross-stage gating + passthrough; the
   `bin/run-stage-test.sh` fixture pins detach-on-mismatch +
   no-detach-on-match for `_post_dispatch_check_worktree_head`;
   `bin/agent-prompts-content-test.sh` pins the §7 prose with seven
   greps (rule-presence + four pattern names + chained-command phrase
   + literal worked-example). A symmetric content-test pins the four
   patterns inside `bin/dispatch.sh::_render_and_capture_stream`'s
   building-stage block per ENG-62 Bld-001 prompt-orchestrator
   symmetry discipline.
5. **Operator runbook (D-002 companion):** `docs/runbooks/recovery.md`
   gains a new §5 "Halted issue with `worktree-mutation-forbidden`
   exit code" subsection explaining the symptom and the
   `bash bin/pipeline.sh decide ENG-N --action continue` resume.

Out of scope (explicit per brainstorm §10):

- O-1: reproducing the chained-command matcher bypass and
  (if confirmed) reporting upstream.
- O-2: generalising D-002's pattern set to other stages.
- O-3: a learned-rules entry narrowing the agent's read of P6's
  `git fetch && …` chained-command idiom.
- O-4: upgrading D-002's `startswith` matcher to substring match
  (deferred pending D-003 metric data; see brainstorm §7's
  known-limitation paragraph).
- O-7: stage-gating D-003 to all stages instead of just `building`.

## Architecture

This work is additive across:

- one prose section in `AGENT_PROMPTS.md` (the §7 build-agent body,
  immediately after the Tool-allowlist preamble at line 1232),
- two helpers in `bin/dispatch.sh` (the existing
  `_render_and_capture_stream` gets a building-stage assertion
  block; no new top-level function),
- one new helper + one new call-site + one new rc=26 routing branch
  in `bin/run-stage.sh`,
- one taxonomy entry in `bin/common.sh::failure_outcome_for_exit`,
- three test files (`bin/dispatch-test.sh`, `bin/run-stage-test.sh`,
  `bin/agent-prompts-content-test.sh`),
- one operator runbook (`docs/runbooks/recovery.md`).

The architectural pivot is making the build stage's "agent must not
mutate the worktree's HEAD" contract enforceable on three layers
simultaneously: the prompt names the rule, the dispatcher asserts
against the rendered transcript, and the orchestrator detaches HEAD
post-dispatch as a state-of-the-world fallback. This mirrors the
ENG-43 implement-stage pattern (`gh pr create` forbidden) and reuses
its failure-routing surface verbatim, just with a new exit code (26)
and a parallel building-stage gate.

There is no `docs/VISION.md`, no `docs/ARCHITECTURE.md`, no
`docs/knowledge/decisions.md` (verified: `ls docs/` returns
`brainstorms/  pipeline-vocabulary.md  pipeline-vocabulary.template.md
plans/  runbooks/`). Governing constraints come from `CLAUDE.md` and
`learned-rules/harness/{project-profile,build}.md`. The
`learned-rules/harness/plan.md` file does not exist (verified: `ls
learned-rules/harness/` returns `build.md  project-profile.md` only).

## Tech stack

- Bash 3.2+ (Darwin default, harness target).
- `jq` for the existing `assert_no_tool_invocation` helper (one fork
  per pattern; four patterns → four forks per build dispatch — see
  brainstorm D-002 cost discussion).
- BSD `sed -E` and POSIX `awk` already in use across the harness; no
  new dependencies.
- `git checkout --detach` (portable BSD git on Darwin and Linux);
  no platform-specific flags.
- `bin/metrics.sh` for the new `worktree-mutated-by-agent` event
  (writes any event name verbatim — no schema change).
- `bin/linear.sh add-or-update-comment` for the operator-visibility
  comment (sig-deduped, `<!-- meta: metric name=worktree-mutated-by-agent -->`
  marker; `metric` is in the existing closed `meta_kinds` vocab).
- No new dependencies. No new `dispatch.sh::allowed_tools_for` cases
  added (the building allowlist at `bin/dispatch.sh:252` already
  correctly excludes the forbidden git verbs; the bug is the matcher
  bypass, not the allowlist contents).

## Assumption Inventory

Every modified-file fact below is `path:line`-cited against the current
worktree per ENG-5 P-002 / B-001. Assumptions marked `assumed/new`
identify the file where the artifact will be created.

### Modified files — current signatures, call sites, and insertion points

- **A-001 — `bin/dispatch.sh::_render_and_capture_stream` is defined
  at `bin/dispatch.sh:94-194`.** Verified. Concrete entry signature
  (`bin/dispatch.sh:94-95`):
  ```bash
  _render_and_capture_stream() {
    local usage_file="$1" issue_dir="$2" stage="${3:-}"
  ```
  The implementing-stage assertion block sits at `bin/dispatch.sh:184-193`:
  ```bash
  if [[ "$stage" == "implementing" ]]; then
    local _matched_cmd
    if _matched_cmd="$(assert_no_tool_invocation "$raw_capture" "gh pr create")"; then
      :   # rc 0: no match, fall through
    else
      printf '%s\n' "$_matched_cmd" > "$violation_file"
      log "[assert] implement-stage transcript invoked forbidden tool: ${_matched_cmd}"
      return 22
    fi
  fi
  ```
  Plan inserts a parallel building-stage block immediately AFTER line
  193 and BEFORE the closing `}` at line 194. Same shape, four-pattern
  loop, return code 26.

- **A-002 — `bin/dispatch.sh::assert_no_tool_invocation` is at
  `bin/dispatch.sh:48-65` with the `startswith` shape.** Verified. Soft-fails
  (returns 0) on missing/empty transcript at line 50:
  `[[ -s "$transcript" ]] || return 0`. The jq filter at `:52-59`
  prefix-matches `.input.command` against `$pattern` and emits the
  first match via `head -1`. **Inherited limitation:** chained commands
  starting with an allowed prefix (e.g., `git fetch origin main && git
  checkout main`) bypass the `startswith` check (see brainstorm §7's
  D-002 false-negative paragraph and O-4); D-003 catches this case.

- **A-003 — `bin/dispatch.sh::allowed_tools_for "building"` at line 252
  excludes `git checkout`, `git switch`, `git pull`, `git reset`.**
  Verified. Concrete value:
  ```
  building) base='Read,Write,Grep,Glob,Bash(git fetch:*),Bash(git clone:*),
                  Bash(git rebase:*),Bash(gh run:*),Bash(gh pr list:*),
                  Bash(gh pr view:*),Bash(gh pr checks:*),Bash(gh pr edit:*),
                  Bash(gh pr merge:*),Bash(jq:*),Bash(mktemp:*),
                  Bash(bash .pipeline/bin/linear.sh:*),
                  Bash(bash bin/linear.sh:*),
                  Bash(bash .pipeline/bin/pipeline.sh:*),
                  Bash(bash bin/pipeline.sh:*),
                  Bash(bash .pipeline/bin/slack.sh:*),
                  Bash(bash bin/slack.sh:*)' ;;
  ```
  No `Bash(git checkout:*)` / `Bash(git switch:*)` / `Bash(git pull:*)` /
  `Bash(git reset:*)` entries — confirms the lane denial is correct
  by omission, and the agent's bypass must have used a chained-command
  variant or a similar route. Plan does NOT modify this list.

- **A-004 — `bin/common.sh::failure_outcome_for_exit` is at
  `bin/common.sh:107-129` and codes 0/10/11/12/13/14/20/21/22/24/25/124
  are taken; code 26 is unused.** Verified. Concrete shape:
  ```bash
  failure_outcome_for_exit() {
    local exit_code="$1" subcode="${2:-}"
    case "$exit_code" in
      0) ... ;;
      10) printf 'guards-tripped' ;;
      ...
      22) printf 'pr-opened-too-early' ;;
      24) printf 'linear-post-failed' ;;
      25) printf 'agent-contract-missing' ;;
      124) printf 'dispatch-timeout' ;;
      *)  printf 'unknown-exit-%s' "$exit_code" ;;
    esac
  }
  ```
  Plan inserts a `26) printf 'worktree-mutation-forbidden' ;;` arm
  between the existing `25)` and `124)` arms.

- **A-005 — `bin/run-stage.sh` header docstring at lines 1-14
  enumerates exit codes.** Verified. Concrete shape (`bin/run-stage.sh:4-9`):
  ```
  # Exit codes: 0=success, 10=guards-tripped, 11=paused, 12=stage-drift (post-dispatch
  #             stage label changed during run; no halt re-applied), 13=lane-violation
  #             (linear.sh write rejected for caller's PIPELINE_WRITER lane),
  #             20=dispatch-failed, 21=scope-violation, 22=pr-opened-too-early,
  #             24=linear-post-failed, 25=agent-contract-missing (agent exited clean
  #             but emitted neither the stage-summary file nor a verdict-marker comment).
  ```
  Plan adds `26=worktree-mutation-forbidden (build-stage transcript
  invoked git checkout/switch/pull/reset)` to the line continuing the
  exit-code enumeration.

- **A-006 — `bin/run-stage.sh::main` dispatch-rc handling for rc=22 at
  lines 669-681.** Verified. Concrete shape:
  ```bash
  elif (( dispatch_rc == 22 )); then
    # ENG-43: implement-stage transcript invoked the forbidden
    # `gh pr create` tool. Read the matched command from the sidecar
    # written by _render_and_capture_stream and surface the same
    # operator-facing halt as the deleted state-check guard:
    # exit 22, skip-until-human-acts, pr-opened-too-early.
    local _viol_file _viol_cmd
    _viol_file="$(issue_dir "$ident")/.transcript-violation-${stage}"
    _viol_cmd="$(cat "$_viol_file" 2>/dev/null || printf '<command-unavailable>')"
    classify_failure "$ident" "$stage" "skip-until-human-acts" \
      "implement-stage transcript invoked forbidden tool: $_viol_cmd" 22
    rm -f "$_viol_file" "$prompt_file"
    exit 22
  ```
  Plan adds a parallel `elif (( dispatch_rc == 26 )); then` arm
  immediately after, mirroring the body but with a build-stage
  message and exit 26. The sidecar path is the same
  (`.transcript-violation-${stage}`, written by `_render_and_capture_stream`
  per A-001's plan).

- **A-007 — `bin/run-stage.sh::main` post-dispatch chain at lines
  836-915.** Verified. Order: artifact-validator (845-858),
  push_branch_if_ahead (864-868), post_completion_comment (872-880),
  stage-drift guard (886-900), `_post_dispatch_apply_halt` (905),
  `verdict_handler` (915). The cost-flags-and-stage-end loop runs
  at lines 917-944. Plan inserts the new
  `_post_dispatch_check_worktree_head` call AFTER line 915 (the
  `verdict_handler` call) and BEFORE line 917 (the cost-flags
  collection). Per brainstorm D-003 placement rationale: running
  after verdict_handler observes the fully settled post-dispatch
  state and avoids interaction risk with `push_branch_if_ahead`'s
  detached-HEAD bail-out at lines 235-251.

- **A-008 — `bin/run-stage.sh::_pre_dispatch_merge_gate` at
  lines 521-562 establishes the canonical `case "$stage" in
  building) ;; *) return 1 ;; esac` stage-gating idiom.** Verified
  at line 530. Plan's new `_post_dispatch_check_worktree_head`
  helper uses the SAME pattern (`case "$stage" in building) ;; *)
  return 0 ;; esac`) for symmetry. Lane-attribution (`local
  PIPELINE_WRITER=orchestrator; export PIPELINE_WRITER`) at
  `_pre_dispatch_merge_gate:526-527` (and analogously at
  `_handle_wait:398-399`) is also mirrored. Note:
  `_post_dispatch_apply_halt` at :376-388 does NOT carry the
  explicit assignment today; the new helper is intentionally MORE
  defensive than that precedent (per brainstorm §4 D-003 helper
  sketch's lane-attribution comment), matching the
  `_pre_dispatch_merge_gate` / `_handle_wait` shape instead.

- **A-009 — `bin/run-stage.sh::_post_dispatch_apply_halt` at
  lines 376-388.** Verified. The new
  `_post_dispatch_check_worktree_head` helper sits in the same
  neighbourhood (definition between line 388 and the `_handle_wait`
  function at line 397) so a code reviewer reads the post-dispatch
  helpers as a cluster. Both helpers take the `(ident, stage)`
  argument shape; both are called from `main()`'s post-dispatch
  region; both are no-ops on stage mismatches.

- **A-010 — `bin/run-stage.sh::issue_dir` is the canonical worktree
  resolver.** Verified — used at A-006's `_viol_file` line 676 and
  throughout. The new helper uses
  `wt="$(issue_dir "$ident")/worktree"` to derive the worktree
  path. Concrete usage already established at multiple call-sites.

- **A-011 — `bin/branch-name.sh::main` returns
  `feat/<eng-n-lower>-<slug>` or `fix/<eng-n-lower>-<slug>`.**
  Verified at `bin/branch-name.sh:31`. Soft-fails on Linear API
  outage via `die "could not fetch title for $ident"` at
  line 22. The new helper catches via `2>/dev/null || printf ''`
  and falls through if `expected_branch` is empty (per brainstorm
  §7 error-handling row).

- **A-012 — `bin/run-local.sh:220` invokes
  `bash "$SCRIPT_DIR/branch-name.sh" "$issue_id"` for the canonical
  branch derivation.** Verified — this is the same path the
  orchestrator uses. The new D-003 helper reuses `branch-name.sh`
  (rather than parsing the `.git` ref directly) for symmetric
  derivation. The Linear-title-rename trade-off is accepted per
  brainstorm §7 (detach is informative-only and reflog-recoverable).

- **A-013 — `bin/agent-prompts-content-test.sh::section_body` extracts
  H2 sections from `AGENT_PROMPTS.md`.** Verified at lines 20-28. The
  helper handles column-0 `## ` headings inside fenced blocks via the
  `in_fence` track (line 24). Existing assertions at lines 36-138
  use `printf '%s\n' "$s7" | grep -qF '<phrase>'` to pin literal
  text. Plan APPENDS new ENG-71 grep block after the last existing
  assertion in the file (verified by reading lines 95-138) following
  the same pattern.

- **A-014 — `AGENT_PROMPTS.md` §7 (Build Agent) header is at
  line 1225 (`## 7. Build Agent`), the fenced block opens at
  line 1227 with the `Tool allowlist & probing` preamble at line
  1232, and the `Read these files first` list begins at line 1234.**
  Verified. Plan inserts the new `MANDATORY worktree-HEAD rule
  (ENG-71)` paragraph as a single new bold paragraph BETWEEN line
  1232 (the existing preamble's end) and line 1234 (the
  `Read these files first (where present):` heading). The fence
  count of the §7 block is preserved (a single column-0 ``` opens
  the block at 1227 and closes it at 1474; render-prompt.sh
  requires exactly two fences per section).

- **A-015 — `AGENT_PROMPTS.md` §3 hard-rules block at lines 83-88
  uses identical "Do not run X" language for `git checkout -b`,
  `git checkout -B`, `git branch -m`, `git switch -c`.**
  Verified. Plan's D-001 rule mirrors this hard-rules tone but
  scopes it to §7 only (the global preamble §3 deliberately
  doesn't get the rule per brainstorm D-001 rejected-alternative
  rationale: only the build stage has the post-merge "I should
  verify main" intuition).

- **A-016 — `AGENT_PROMPTS.md` §7 P6 dry-rebase recipe at
  lines 1346-1347 uses chained commands.** Verified:
  ```
  git fetch origin main && git -C $(mktemp -d) clone --quiet --branch {branch_name} \
    <origin> && cd <clone> && git rebase --quiet origin/main
  ```
  This is correct (clones into `mktemp -d`, doesn't touch the
  worktree). Plan does NOT modify it. The D-001 rule explicitly
  names "chained commands" so a model that has internalised P6's
  idiom is told the chained variant of `git fetch && git checkout
  main` is also forbidden.

- **A-017 — `bin/dispatch-test.sh` AS1-AS6 fixtures are at
  lines 1141-1235.** Verified. The pattern is:
  - `TX_AS<N>="$_TEST_STUB_DIR/tx-as<N>.ndjson"` heredoc setup,
  - Direct `assert_no_tool_invocation` call,
  - `pass_at` / `fail_at` on `(rc, stdout)` tuple.
  Plan APPENDS AS7-AS12 fixtures (six total) immediately after
  AS6 ends at line 1235 and BEFORE the `--- QA-authored
  adversarial fixtures (AT1-AT5; ENG-43 not in Failure Mode →
  Test Map) ---` comment block at line 1237. Test scaffolding
  (`PASS`/`FAIL` counters at line 1442 unchanged; `_TEST_STUB_DIR`
  resolution; `pass_at`/`fail_at` helpers) is reused as-is.

- **A-018 — `bin/dispatch-test.sh` AT1-AT2 fixtures at lines
  1248-1296 already exercise the renderer-wrapper integration for
  the implementing stage.** Verified. AT1 (lines 1248-1270) calls
  `_render_and_capture_stream "$USAGE_AT1" "$ISSUE_DIR"
  "implementing"` with a heredoc transcript, asserts
  `at1_rc=22`, sidecar contents, and the log line. Plan APPENDS
  a parallel AT6 fixture (renderer integration, `stage="building"`
  + match → rc=26 + sidecar `.transcript-violation-building` +
  log line) and AT7 (renderer cross-stage gating: `stage="qa"`
  with a `git checkout main` transcript → rc=0, no sidecar).
  These pin the renderer-wrapper end-to-end for the build path,
  symmetric to AT1/AT2 for the implement path.

- **A-019 — `bin/run-stage-test.sh` source-and-stub layout at
  lines 1-119.** Verified. The pattern is:
  - `STUB_DIR="$(mktemp -d)"` at line 17,
  - `EXIT trap cleanup` at line 111,
  - Stubbed `linear.sh` / `branch-name.sh` / `gh` / `guards.sh` /
    `scope-check.sh` under `$STUB_DIR`,
  - Source `common.sh`, `classify-failure.sh`, `run-stage.sh`
    at lines 97-101,
  - Post-source override `SCRIPT_DIR="$STUB_DIR"` at line 114
    so `bash "$SCRIPT_DIR/<sub>.sh"` calls reach the stubs.
  Plan APPENDS the D-003 fixture at the end of the file
  (after the existing case 6 at line 198 — verified the file
  ends shortly after with the test summary). The fixture stubs
  `metrics.sh` (currently unstubbed but the existing tests don't
  invoke metrics from `run-stage.sh::main` paths they hit), sets
  up a real `git init`'d worktree under `$STUB_DIR/wt-eng-T8/worktree`,
  uses `git checkout -b main` to put HEAD on `main`, then calls
  `_post_dispatch_check_worktree_head` and asserts the worktree's
  HEAD is detached afterwards. Companion case asserts no detach
  when HEAD already on the expected branch.

- **A-020 — `bin/cleanup-worktrees.sh` post-merge sweep removes
  worktrees on merged-PR detection.** Verified at lines 67-72:
  ```bash
  pr_merged_count="$(gh pr list --head "$branch" --state merged --json number --jq 'length' 2>/dev/null || echo 0)"
  if (( pr_merged_count > 0 )); then
    issue_id="$(issue_id_from_branch "$branch")"
    transition_done "$issue_id"
    remove_tree "$path" "$branch" "merged" "$issue_id"
    continue
  fi
  ```
  No D-003-related changes here — `cleanup-worktrees.sh` will
  remove the worktree on the next post-merge tick regardless of
  D-003 having detached HEAD. The detach is the immediate-impact
  unlock; cleanup is the ultimate housekeeping.

- **A-021 — `bin/run-local-helpers.sh::partition_dirty_paths` at
  lines 133-198 applies the D-004 issue-id basename token check
  ONLY for `brainstorming|planning` stages.** Verified at
  lines 140-141: `case "$stage" in brainstorming|planning)
  apply_d004=1 ;; esac`. This brainstorm doc has `eng-71` in
  its basename per the orchestrator directive in the planning
  prompt; the new plan doc's basename also carries `eng-71`,
  so both bucket as in-scope. The implement-stage edits to
  `bin/dispatch.sh`, `bin/run-stage.sh`, `bin/common.sh`,
  `AGENT_PROMPTS.md`, and the three test files all bucket via
  the harness-self target's `.scope.allowlist.implementing`
  override (verified by recent ENG-43 / ENG-58 / ENG-62 / ENG-63
  / ENG-64 commits successfully landing the same paths).

- **A-022 — `learned-rules/harness/build.md` Bld-001 documents
  the prompt-orchestrator query symmetry pattern.** Verified at
  lines 12-52. ENG-62's prompt-side `gh pr list --head … --state all
  --json state` query and the orchestrator's
  `_pre_dispatch_merge_gate` use the IDENTICAL query. D-001 + D-002
  follow the same discipline: the prompt's pattern enumeration and
  the dispatch-side assertion both name the SAME four pattern
  literals. The symmetric pattern-pin in
  `bin/agent-prompts-content-test.sh` (per A-013 plan) makes this
  invariant testable — an edit that adds a fifth pattern to either
  site without updating the other fails the content test.

- **A-023 — `bin/pipeline-events.json::meta_kinds` is a closed
  4-element array.** Verified at lines 42-47:
  `["dedup","metric","evidence","reapplied"]`. The new
  operator-visibility comment uses `<!-- meta: metric
  name=worktree-mutated-by-agent -->` which reuses the existing
  `metric` kind — no registry change required. Precedent:
  `AGENT_PROMPTS.md` uses `<!-- meta: metric
  name=release_trigger_missing -->` (line 1394) and
  `<!-- meta: metric name=merge_conflict -->` (line 1349) for
  analogous "this happened, no halt, retrospective should
  investigate" semantics.

- **A-024 — `AGENT_PROMPTS.md:111-112` lane-write matrix permits
  orchestrator to add `other_comment` class.** Verified:
  ```
  | add `<!-- pipeline: transition ... -->` comment | allow | deny | deny | deny | allow |
  | add any other comment        | allow | allow | allow | allow | allow |
  ```
  The `<!-- meta: metric name=worktree-mutated-by-agent -->` body's
  first non-blank line is the meta marker (NOT a transition
  marker), so the orchestrator's `add-or-update-comment` call from
  D-003 is lane-allowed via the `other_comment` class.

- **A-025 — `bin/classify-failure.sh:124-146` builds the halt
  comment with `marker_reason=agent-blocked` for
  `skip-until-human-acts` policy.** Verified. The exit-26 routing
  through `classify_failure ... "skip-until-human-acts" ... 26`
  produces a halt comment with `<!-- pipeline: verdict result=halt
  reason=agent-blocked -->`. The metric `outcome` field gets the
  typed `worktree-mutation-forbidden` string from
  `failure_outcome_for_exit 26 ""`. **No new entry is added to
  `bin/pipeline-events.json::halt_reasons`** — `agent-blocked`
  already covers the operator-facing surface; the typed outcome
  is metric-only (consumed by retrospective §1's outcome filter).

- **A-026 — `docs/runbooks/recovery.md` exists, has 307 lines,
  and is the canonical operator-recovery surface.** Verified by
  `wc -l docs/runbooks/recovery.md`. Plan APPENDS a new §5
  "Halted issue with `worktree-mutation-forbidden` exit code"
  subsection at the end of the file (or at the natural insertion
  point after §4 if §4 already exists; plan's Task 5 reads the
  file before editing to confirm the boundary). The new §5
  structure follows the §1-3 conventions: Symptom / Authoritative
  signal / Recovery / Verify.

- **A-027 — `bin/secret-probe-lint.sh` enforces the ENG-46
  secret-handling rule.** Verified (per CLAUDE.md preamble). The
  D-002 / D-003 changes use no env-var fallback patterns matching
  the forbidden regex `*KEY|*TOKEN|*SECRET|ANTHROPIC*|GITHUB*|LINEAR*`.
  The new helper reads `PIPELINE_WRITER` (already present), no
  secret references introduced.

### Read-only callees / state shapes — verified, not modified

- **A-028 — `bin/dispatch.sh::_render_and_capture_stream` writes
  the violation file under `${issue_dir}/.transcript-violation-${stage}`.**
  Verified at line 97. The new building-stage assertion reuses the
  same `$violation_file` variable already defined at line 97; the
  pre-clean at line 98 (`rm -f "$violation_file"`) covers the
  building-stage path automatically (the variable is computed once
  at the top of the function regardless of which assertion fires).

- **A-029 — `bin/dispatch.sh::_render_and_capture_stream` at line 99
  installs a RETURN trap to clean up `$raw_capture`.** Verified. The
  trap fires regardless of which return code the function emits;
  no D-002 cleanup needed beyond writing the violation file.

- **A-030 — `bin/run-stage.sh::push_branch_if_ahead` at lines
  231-251 bails on `branch == main` and detached HEAD.** Verified
  at lines 234-241 (read directly via the brainstorm's verification
  pass; the function's existence is also confirmed by its call at
  `bin/run-stage.sh:866` per A-007). The detach-then-push race
  doesn't apply because D-003 fires AFTER `push_branch_if_ahead`
  has already run; the detach happens on a settled state.

### Assumed/new artifacts

- **A-N1 — Building-stage assertion block (~12 lines)** is NEW in
  `bin/dispatch.sh::_render_and_capture_stream`, inserted between
  line 193 (end of the implementing-stage block) and line 194 (the
  closing `}`). No new helper functions; the block is inline,
  parallel to A-001's existing implementing-stage block.

- **A-N2 — `26)` arm in `bin/common.sh::failure_outcome_for_exit`** is
  NEW. Single line: `26) printf 'worktree-mutation-forbidden' ;;`
  inserted between the existing `25)` and `124)` arms (between
  `bin/common.sh:125` and `:126`).

- **A-N3 — `26=worktree-mutation-forbidden` enumeration in
  `bin/run-stage.sh:4-9`'s exit-code header** is NEW. One-line
  edit appending to the existing exit-code prose.

- **A-N4 — `elif (( dispatch_rc == 26 )); then` arm in
  `bin/run-stage.sh::main`** is NEW. ~12 LOC parallel to A-006's
  existing rc=22 arm (lines 669-681), inserted between the rc=22
  arm and the generic non-zero arm (line 682).

- **A-N5 — `_post_dispatch_check_worktree_head` helper in
  `bin/run-stage.sh`** is NEW. ~45 LOC defined between the
  existing `_post_dispatch_apply_halt` (ends at line 388) and
  `_handle_wait` (starts at line 397) — one new top-level
  function in the post-dispatch helpers cluster. Body sketched
  in brainstorm §4 D-003.

- **A-N6 — Call-site for `_post_dispatch_check_worktree_head` in
  `bin/run-stage.sh::main`** is NEW. Inserted IMMEDIATELY AFTER
  line 915 (the `verdict_handler "$ident" "$vh_stage" || vh_rc=$?`
  call) and BEFORE line 917 (the `t1="$(date +%s)"; duration=...`).
  Stage-gated: `case "$stage" in building)
  _post_dispatch_check_worktree_head "$ident" "$stage" ;; esac`.

- **A-N7 — `worktree-mutated-by-agent` metric event** is NEW. No
  `bin/metrics.sh` code change required (per A-023 — `metrics.sh::main`
  accepts arbitrary event names). Downstream consumers
  (`bin/status.sh`, retrospective) will pick up the event name when
  it first appears in `events.jsonl`, per the established
  "additive event name" convention.

- **A-N8 — `MANDATORY worktree-HEAD rule (ENG-71)` paragraph in
  `AGENT_PROMPTS.md` §7** is NEW. Single bold paragraph inserted
  between lines 1232 and 1234. Body per brainstorm D-001:
  > **MANDATORY worktree-HEAD rule (ENG-71):** Never run `git checkout`,
  > `git switch`, `git pull`, or `git reset` inside the worktree.
  > [...full text in brainstorm D-001...]

- **A-N9 — Test fixtures AS7-AS12 in `bin/dispatch-test.sh`** are NEW.
  Six fixtures appended after AS6 (line 1235) and before AT1's section
  comment (line 1237):
    - AS7: `git checkout` standalone match → rc=1.
    - AS8: `git switch` standalone match → rc=1.
    - AS9: `git pull` standalone match → rc=1.
    - AS10: `git reset` standalone match → rc=1.
    - AS11: passthrough — only allowed `git fetch`, `git clone`,
      `git rebase` → rc=0.
    - AS12: stage gating — `stage="implementing"` with `git checkout
      main` in transcript → no rc=26 (the building-only loop must
      not fire on non-building stages).
  Each fixture follows the AS1-AS6 pattern of direct
  `assert_no_tool_invocation` calls. Note: AS12 is structurally a
  helper-level test — the helper itself is stage-agnostic — but the
  building-stage gate's correctness must also be exercised at the
  renderer-wrapper level (see A-N10).

- **A-N10 — Test fixtures AT6 and AT7 in `bin/dispatch-test.sh`** are
  NEW. Two fixtures appended after AT5 (line 1362) and before the
  ENG-49 Gap #7 contract section (line 1364):
    - AT6: renderer integration, `stage="building"` + `git checkout
      main` in transcript → rc=26, sidecar
      `.transcript-violation-building` written with the matched
      command, log line `[assert] build-stage transcript invoked
      forbidden tool: git checkout main` emitted. Direct mirror of
      AT1 for the implementing stage.
    - AT7: renderer cross-stage gating, `stage="qa"` with `git
      checkout main` in transcript → rc=0, no sidecar written.
      Direct mirror of AT2 for the building stage; ensures the
      gate at A-N1's `if [[ "$stage" == "building" ]]; then` doesn't
      fire on non-building stages.

- **A-N11 — Test fixtures for `_post_dispatch_check_worktree_head` in
  `bin/run-stage-test.sh`** are NEW. Two fixtures appended after the
  existing case 6 at line 198:
    - Case 7 (positive): worktree HEAD on `main` post-dispatch →
      after the helper runs, HEAD is detached AND the
      `worktree-mutated-by-agent` metric was written AND the
      `add-or-update-comment` stub captured a comment with the
      `<!-- meta: metric name=worktree-mutated-by-agent -->` body.
    - Case 8 (negative): worktree HEAD on the expected branch →
      after the helper runs, HEAD is unchanged AND no metric was
      written AND no comment was captured.
  Each case stubs `metrics.sh` (writes invocations to a capture
  file under `$STUB_DIR`), uses a real `git init`'d worktree under
  `$STUB_DIR/wt-T7/worktree` with `git checkout -b main` (or
  `feat/eng-t7-mock-slug` for the negative case), and asserts via
  `git -C "$wt" rev-parse --abbrev-ref HEAD` afterwards.

- **A-N12 — Content-test additions in
  `bin/agent-prompts-content-test.sh`** are NEW. Eight greps appended
  after the last existing assertion (verified by reading lines
  95-138 — file ends shortly after):
    - One grep for the rule-presence phrase
      `MANDATORY worktree-HEAD rule (ENG-71)` in §7.
    - Four greps for the back-tick-quoted pattern names
      (\`git checkout\`, \`git switch\`, \`git pull\`, \`git reset\`)
      in §7.
    - One grep for the `chained commands` phrase in §7.
    - One grep for the literal worked example
      `git fetch origin main && git checkout main` in §7
      (insurance against a future retrospective edit dropping the
      example while keeping the prose).
    - One symmetric grep that pins the SAME four pattern literals
      appear inside `bin/dispatch.sh` (read the file directly,
      grep for each of the four `'git checkout'`, `'git switch'`,
      `'git pull'`, `'git reset'` quoted literals — establishes
      ENG-62 Bld-001 prompt-orchestrator symmetry).

- **A-N13 — `docs/runbooks/recovery.md` §5** is NEW (or §6 if §5 was
  already taken by ENG-63 — Task 5 reads the file first to confirm
  the next available section number). Inserted at the end of the
  numbered sections, before any "Quick reference" tail. Section
  body documents the symptom (`pipeline:halted` label after a
  build dispatch + `<!-- pipeline: verdict result=halt
  reason=agent-blocked -->` halt comment with body containing
  `worktree-mutation-forbidden` evidence in the metric notes
  field) and the recovery (`bash bin/pipeline.sh decide ENG-N
  --action continue`).

## File Structure

```
bin/
  dispatch.sh                                modified — append ~12 LOC building-stage
                                                        assertion block to
                                                        _render_and_capture_stream after :193,
                                                        before closing brace at :194. Returns 26
                                                        on match; writes $violation_file. (Task 1)
  common.sh                                  modified — insert `26) printf
                                                        'worktree-mutation-forbidden' ;;` arm
                                                        between :125 and :126. (Task 1)
  run-stage.sh                               modified — (a) one-line addition to the exit-code
                                                        header docstring at :4-9 documenting
                                                        26=worktree-mutation-forbidden; (b) new
                                                        ~12 LOC `elif (( dispatch_rc == 26 ))`
                                                        arm after :681; (c) new ~45 LOC
                                                        `_post_dispatch_check_worktree_head`
                                                        helper between :388 and :397; (d)
                                                        new 1-line call-site case for stage=building
                                                        immediately after the verdict_handler
                                                        call at :915. (Tasks 1, 2)
  dispatch-test.sh                           modified — append AS7-AS12 (six fixtures, ~80 LOC)
                                                        after :1235; append AT6, AT7 (~50 LOC)
                                                        after :1362. (Task 3)
  run-stage-test.sh                          modified — append D-003 fixtures cases 7+8 (~80 LOC)
                                                        after :198. (Task 3)
  agent-prompts-content-test.sh              modified — append eight greps (rule presence,
                                                        four pattern names, chained-commands
                                                        phrase, literal example, symmetric
                                                        dispatch.sh pattern-pin). (Task 4)

AGENT_PROMPTS.md                             modified — insert MANDATORY worktree-HEAD rule
                                                        paragraph between :1232 and :1234. (Task 4)

docs/
  runbooks/
    recovery.md                              modified — append new §N "Halted issue with
                                                        worktree-mutation-forbidden exit code"
                                                        subsection at the end (Task 5 confirms
                                                        next section number). (Task 5)
  plans/
    2026-05-06-eng-71-...md                  NEW — this file.
```

No changes to: `bin/run-local.sh`, `bin/run-local-helpers.sh`,
`bin/poll.sh`, `bin/reconcile.sh`, `bin/scope-check.sh`,
`bin/verdict-handler.sh`, `bin/classify-failure.sh`, `bin/linear.sh`,
`bin/metrics.sh`, `bin/branch-name.sh`, `bin/cleanup-worktrees.sh`,
`bin/pipeline.sh`, `bin/setup.sh`, `bin/render-prompt.sh`,
`bin/pipeline-events.json` (the `metric` meta-kind already covers
the new operator-visibility comment per A-023; no new event token
needed in the closed registry), `learned-rules/**`, `launchd/**`,
`.github/workflows/**`, `docs/pipeline-vocabulary.md` (template +
generated doc untouched; no registry change → no regen needed),
`docs/pipeline-vocabulary.template.md`, `CLAUDE.md` (no surface
that would benefit from a row update; the recovery.md addition is
a new section operators can find via the existing runbook index).

## API Contract

**No new API surface.** The harness has no FE↔BE API surface.
The change adds:

- One new dispatch.sh exit code (`26 = worktree-mutation-forbidden`)
  consumed by `bin/run-stage.sh::main`'s dispatch-rc handling and
  by `bin/common.sh::failure_outcome_for_exit`.
- One new metrics event name (`worktree-mutated-by-agent`) — written
  verbatim by the pre-existing `bin/metrics.sh` helper. No schema
  migration (per A-023, A-N7).
- One new comment-body shape using the existing
  `<!-- meta: metric name=<event> -->` marker family. Reuses the
  existing closed `meta_kinds` vocab (`metric` kind, A-023). No
  registry change to `bin/pipeline-events.json`.
- One new orchestrator post-dispatch hook
  (`_post_dispatch_check_worktree_head`) called from
  `bin/run-stage.sh::main` after `verdict_handler` for `stage =
  building` only. Stage-gated; other stages observe no behavior
  change.

No CLI argv change, no env-var addition, no on-disk state-file
format change, no new lane fence. The four-shape verdict vocabulary
(`pass | fail | halt | wait`) is untouched. No new halt reason —
exit 26 routes through `classify_failure` with policy
`skip-until-human-acts`, which produces the existing
`<!-- pipeline: verdict result=halt reason=agent-blocked -->` marker
shape per A-025.

## Backend Tasks

### Task 1: Add building-stage transcript assertion + rc=26 routing + outcome taxonomy entry

- `depends_on: []`
- `touches: bin/dispatch.sh::_render_and_capture_stream, bin/common.sh::failure_outcome_for_exit, bin/run-stage.sh::main (rc=26 arm + header docstring)`

- [ ] **Step 1.1 — Insert building-stage assertion block in
  `bin/dispatch.sh::_render_and_capture_stream`.** Append the new
  block immediately AFTER line 193 (end of the existing
  implementing-stage block) and BEFORE the closing `}` at line 194:

  ```bash
  # ENG-71: defense-in-depth assertion. Build's tool lane denies
  # Bash(git checkout:*) etc. by omission (only Bash(git fetch:*),
  # Bash(git clone:*), Bash(git rebase:*) are permitted; verified
  # at allowed_tools_for "building" in this file). This is the second
  # line of defense if the lane's prefix-matcher is bypassed (ENG-61
  # observed; chained-command hypothesis in ENG-71 brainstorm §1).
  # Stage-gated to "building" only — other stages observe no behavior change.
  # Modulo the inherited `startswith` blind spot on chained commands
  # (e.g., `git fetch origin main && git checkout main` starts with
  # `git fetch` and bypasses this loop's matcher); D-003 in run-stage.sh
  # is the catch-net for that surface (ENG-71 §7 / O-4).
  if [[ "$stage" == "building" ]]; then
    local _pat _matched_cmd
    for _pat in 'git checkout' 'git switch' 'git pull' 'git reset'; do
      if _matched_cmd="$(assert_no_tool_invocation "$raw_capture" "$_pat")"; then
        :   # rc 0: no match, fall through to next pattern
      else
        printf '%s\n' "$_matched_cmd" > "$violation_file"
        log "[assert] build-stage transcript invoked forbidden tool: ${_matched_cmd}"
        return 26
      fi
    done
  fi
  ```

  The `$violation_file` variable is already in scope from line 97
  (`violation_file="${issue_dir}/.transcript-violation-${stage}"`)
  and pre-cleaned at line 98 (per A-028, A-029). The `$raw_capture`
  variable is the renderer's captured NDJSON (line 96).

- [ ] **Step 1.2 — Add `26)` arm to
  `bin/common.sh::failure_outcome_for_exit`.** Insert the new arm
  between the existing `25)` and `124)` arms (between
  `bin/common.sh:125` and `:126`):

  ```bash
  25) printf 'agent-contract-missing' ;;
  26) printf 'worktree-mutation-forbidden' ;;
  124) printf 'dispatch-timeout' ;;
  ```

- [ ] **Step 1.3 — Update the exit-code header docstring in
  `bin/run-stage.sh:4-9`.** Append `26=worktree-mutation-forbidden`
  to the enumeration. Concrete edit replaces the existing line:

  ```
  #             24=linear-post-failed, 25=agent-contract-missing (agent exited clean
  #             but emitted neither the stage-summary file nor a verdict-marker comment).
  ```

  with:

  ```
  #             24=linear-post-failed, 25=agent-contract-missing (agent exited clean
  #             but emitted neither the stage-summary file nor a verdict-marker comment),
  #             26=worktree-mutation-forbidden (build-stage transcript invoked
  #             git checkout/switch/pull/reset; ENG-71).
  ```

- [ ] **Step 1.4 — Add `elif (( dispatch_rc == 26 )); then` arm in
  `bin/run-stage.sh::main`.** Insert immediately AFTER the existing
  rc=22 arm at line 681 (`exit 22`) and BEFORE the generic non-zero
  arm at line 682 (`elif (( dispatch_rc != 0 )); then`):

  ```bash
  elif (( dispatch_rc == 26 )); then
    # ENG-71: build-stage transcript invoked one of `git checkout`,
    # `git switch`, `git pull`, `git reset` — the four worktree-HEAD-
    # mutating verbs the build agent is contractually forbidden from
    # invoking (the merge is server-side via `gh pr merge --auto`;
    # local sync is the harness's job). Read the matched command
    # from the sidecar written by _render_and_capture_stream and
    # surface a skip-until-human-acts halt. The orchestrator's
    # post-dispatch _post_dispatch_check_worktree_head detector
    # (D-003) does not run because we exit before the post-dispatch
    # chain — but if an undetected bypass mutated HEAD anyway, the
    # next tick's run-local cleanup will pick it up.
    local _viol_file _viol_cmd
    _viol_file="$(issue_dir "$ident")/.transcript-violation-${stage}"
    _viol_cmd="$(cat "$_viol_file" 2>/dev/null || printf '<command-unavailable>')"
    classify_failure "$ident" "$stage" "skip-until-human-acts" \
      "build-stage transcript invoked forbidden worktree-HEAD-mutating tool: $_viol_cmd" 26
    rm -f "$_viol_file" "$prompt_file"
    exit 26
  ```

- [ ] **Step 1.5 — Verify with `bash -n bin/dispatch.sh bin/common.sh
  bin/run-stage.sh`.** Syntax check, must exit 0.

- [ ] **Step 1.6 — Verify with `bash bin/secret-probe-lint.sh`.**
  No new env-var fallback patterns introduced (per A-027).

### Task 2: Add `_post_dispatch_check_worktree_head` helper + call-site

- `depends_on: [1]`
- `touches: bin/run-stage.sh (new helper + call-site after :915)`

- [ ] **Step 2.1 — Define `_post_dispatch_check_worktree_head` in
  `bin/run-stage.sh`** between the existing `_post_dispatch_apply_halt`
  closing `}` at line 388 and the `_handle_wait` opening at line
  397. Function body per brainstorm §4 D-003 (verbatim):

  ```bash
  # ENG-71: defense-in-depth detector for the worktree-on-main symptom.
  # D-002 (in dispatch.sh) catches the contract violation pre-exit; this
  # is the state-of-the-world fallback that runs even if D-002 misses
  # (chained commands that bypass the startswith matcher per the brainstorm
  # §7 known-limitation; future matcher change silently re-permits
  # Bash(git checkout:*); etc.).
  #
  # On detection, detach HEAD to the current commit. A detached HEAD is
  # invisible to git's "branch already checked out" lock, so the operator's
  # primary main-checkout becomes usable again. We do NOT auto-switch back
  # to {branch_name} — if the agent left commits on main locally, switching
  # back would silently abandon them; detach preserves them as a
  # reflog-recoverable orphan and surfaces the anomaly via the metric.
  #
  # Lane attribution: explicit PIPELINE_WRITER=orchestrator at the top
  # mirrors _post_dispatch_apply_halt and _pre_dispatch_merge_gate
  # (this file, lines 376/521). The metrics.sh call today does not
  # consult PIPELINE_WRITER (writes JSONL to disk only); the explicit
  # assignment defends against a future edit that grows a Linear-write
  # side effect.
  #
  # Stage-gated to "building" because that's the only stage with the
  # observed symptom (post-merge worktree-on-main). Other stages may
  # legitimately have detached HEADs (none today, but the gate keeps
  # the change minimal).
  _post_dispatch_check_worktree_head() {
    local PIPELINE_WRITER=orchestrator
    export PIPELINE_WRITER

    local ident="$1" stage="$2"
    case "$stage" in building) ;; *) return 0 ;; esac
    local wt; wt="$(issue_dir "$ident")/worktree"
    [[ -d "$wt/.git" ]] || [[ -f "$wt/.git" ]] || return 0

    # Resolve expected branch via branch-name.sh (the canonical derivation;
    # mirrors run-local.sh:220). Soft-fail on Linear API outage so we don't
    # detach on a wrong expected value.
    local expected_branch current_branch
    expected_branch="$(bash "$SCRIPT_DIR/branch-name.sh" "$ident" 2>/dev/null || printf '')"
    current_branch="$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || printf '')"
    [[ -n "$expected_branch" && -n "$current_branch" ]] || return 0
    [[ "$current_branch" == "$expected_branch" ]] && return 0

    log "post-dispatch: WORKTREE HEAD MUTATED — expected=$expected_branch current=$current_branch; detaching to unlock parent ref"
    git -C "$wt" checkout --detach 2>&1 | sed 's/^/  detach: /' >&2 || true
    bash "$SCRIPT_DIR/metrics.sh" worktree-mutated-by-agent "$ident" "$stage" \
      "warn" 0 "expected=$expected_branch current=$current_branch" \
      || log "metrics.sh worktree-mutated-by-agent emission failed (non-blocking)"

    # Operator-visibility: post a non-halting Linear comment so an operator
    # skimming the issue thread sees the detach without grepping events.jsonl
    # or per-stage transcripts. Sig-deduped via add-or-update-comment so
    # re-fires on retry collapse to one comment per issue. The
    # `<!-- meta: metric name=worktree-mutated-by-agent -->` marker shape
    # reuses the existing `metric` kind in the closed meta_kinds vocab
    # (bin/pipeline-events.json:42-47); the metric-name discriminator
    # matches the events.jsonl event so retrospective queries can correlate.
    local _body
    _body="$(printf '<!-- meta: metric name=worktree-mutated-by-agent -->\n\nBuild agent left this worktree on `%s` (expected `%s`) post-dispatch. Orchestrator detached HEAD to unlock `main` globally. The merged feature commit is preserved as a detached-HEAD reflog entry; `cleanup-worktrees.sh` will remove the worktree on the next post-merge tick. No operator action required.' \
      "$current_branch" "$expected_branch")"
    bash "$SCRIPT_DIR/linear.sh" add-or-update-comment \
      "warn/worktree-mutated/$ident" "$ident" "$_body" \
      || log "linear.sh add-or-update-comment failed for warn/worktree-mutated/$ident (non-blocking)"
  }
  ```

- [ ] **Step 2.2 — Insert call-site in `bin/run-stage.sh::main`.**
  Insert immediately AFTER the existing `verdict_handler "$ident"
  "$vh_stage" || vh_rc=$?` at line 915 and BEFORE the existing
  `t1="$(date +%s)"; duration=$(( (t1 - t0) * 1000 ))` at line 917:

  ```bash
  # ENG-71: defense-in-depth check for the worktree-on-main symptom
  # observed in ENG-61. Stage-gated to building inside the helper.
  case "$stage" in
    building) _post_dispatch_check_worktree_head "$ident" "$stage" ;;
  esac
  ```

- [ ] **Step 2.3 — Verify with `bash -n bin/run-stage.sh`.** Syntax
  check, must exit 0.

### Task 3: Pin AS7-AS12 + AT6 + AT7 in `bin/dispatch-test.sh` and D-003 fixtures in `bin/run-stage-test.sh`

- `depends_on: [1, 2]`
- `touches: bin/dispatch-test.sh, bin/run-stage-test.sh`

- [ ] **Step 3.1 — Append AS7-AS12 to `bin/dispatch-test.sh`** between
  line 1235 (end of AS6) and line 1237 (`--- QA-authored adversarial
  fixtures (AT1-AT5; ENG-43 not in Failure Mode → Test Map) ---`).
  Each fixture follows the AS1-AS6 source-and-stub layout. Concrete
  shape:

  ```bash
  # ─── Group 7b: ENG-71 building-stage forbidden patterns (AS7-AS12) ────
  # AS7-AS10: each of the four worktree-HEAD-mutating verbs in turn,
  # standalone tool_use → assert_no_tool_invocation matches and rc=1.
  # AS11: passthrough — only the allowed git verbs (fetch, clone, rebase)
  #       are present → rc=0.
  # AS12: stage-agnostic — assert_no_tool_invocation itself does NOT
  #       know about stage; the gate lives in _render_and_capture_stream.
  #       This fixture is a HELPER-LEVEL passthrough that mirrors AS2
  #       (gh pr create not present → rc=0). Cross-stage gating at the
  #       renderer-wrapper level is exercised by AT7.
  printf '\n--- ENG-71: build-stage forbidden patterns (AS7-AS12) ---\n'

  # AS7 — git checkout standalone
  TX_AS7="$_TEST_STUB_DIR/tx-as7.ndjson"
  cat > "$TX_AS7" <<'NDJSON'
  {"type":"system","subtype":"init","session_id":"as7","model":"claude-opus-4-7"}
  {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git checkout main"}}]}}
  NDJSON
  out_as7="$(assert_no_tool_invocation "$TX_AS7" "git checkout")" && rc_as7=0 || rc_as7=$?
  if [[ "$rc_as7" == "1" && "$out_as7" == "git checkout main" ]]; then
    pass_at "AS7: git checkout standalone → rc=1, matched command on stdout"
  else
    fail_at "AS7" "rc=$rc_as7 out=$out_as7"
  fi

  # AS8 — git switch standalone
  TX_AS8="$_TEST_STUB_DIR/tx-as8.ndjson"
  cat > "$TX_AS8" <<'NDJSON'
  {"type":"system","subtype":"init","session_id":"as8","model":"claude-opus-4-7"}
  {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git switch main"}}]}}
  NDJSON
  out_as8="$(assert_no_tool_invocation "$TX_AS8" "git switch")" && rc_as8=0 || rc_as8=$?
  if [[ "$rc_as8" == "1" && "$out_as8" == "git switch main" ]]; then
    pass_at "AS8: git switch standalone → rc=1, matched command on stdout"
  else
    fail_at "AS8" "rc=$rc_as8 out=$out_as8"
  fi

  # AS9 — git pull standalone
  TX_AS9="$_TEST_STUB_DIR/tx-as9.ndjson"
  cat > "$TX_AS9" <<'NDJSON'
  {"type":"system","subtype":"init","session_id":"as9","model":"claude-opus-4-7"}
  {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git pull --ff-only origin main"}}]}}
  NDJSON
  out_as9="$(assert_no_tool_invocation "$TX_AS9" "git pull")" && rc_as9=0 || rc_as9=$?
  if [[ "$rc_as9" == "1" && "$out_as9" == "git pull --ff-only origin main" ]]; then
    pass_at "AS9: git pull standalone → rc=1, matched command on stdout"
  else
    fail_at "AS9" "rc=$rc_as9 out=$out_as9"
  fi

  # AS10 — git reset standalone
  TX_AS10="$_TEST_STUB_DIR/tx-as10.ndjson"
  cat > "$TX_AS10" <<'NDJSON'
  {"type":"system","subtype":"init","session_id":"as10","model":"claude-opus-4-7"}
  {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git reset --hard origin/main"}}]}}
  NDJSON
  out_as10="$(assert_no_tool_invocation "$TX_AS10" "git reset")" && rc_as10=0 || rc_as10=$?
  if [[ "$rc_as10" == "1" && "$out_as10" == "git reset --hard origin/main" ]]; then
    pass_at "AS10: git reset standalone → rc=1, matched command on stdout"
  else
    fail_at "AS10" "rc=$rc_as10 out=$out_as10"
  fi

  # AS11 — passthrough: only allowed verbs present → rc=0 for each forbidden pattern
  TX_AS11="$_TEST_STUB_DIR/tx-as11.ndjson"
  cat > "$TX_AS11" <<'NDJSON'
  {"type":"system","subtype":"init","session_id":"as11","model":"claude-opus-4-7"}
  {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git fetch origin main"}}]}}
  {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git clone --quiet --branch foo /src /dst"}}]}}
  {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git rebase --quiet origin/main"}}]}}
  NDJSON
  as11_failures=0
  for _pat in 'git checkout' 'git switch' 'git pull' 'git reset'; do
    out_as11="$(assert_no_tool_invocation "$TX_AS11" "$_pat")" && rc_as11=0 || rc_as11=$?
    if [[ "$rc_as11" != "0" || -n "$out_as11" ]]; then
      as11_failures=$((as11_failures+1))
      fail_at "AS11 ($_pat passthrough)" "rc=$rc_as11 out=$out_as11"
    fi
  done
  if [[ "$as11_failures" == "0" ]]; then
    pass_at "AS11: passthrough — only allowed git verbs (fetch/clone/rebase) → rc=0 for all four forbidden patterns"
  fi

  # AS12 — helper-level passthrough mirror (assert_no_tool_invocation is
  # stage-agnostic; the gate lives in _render_and_capture_stream — see
  # AT7 for the renderer-wrapper cross-stage gating test).
  TX_AS12="$_TEST_STUB_DIR/tx-as12.ndjson"
  cat > "$TX_AS12" <<'NDJSON'
  {"type":"system","subtype":"init","session_id":"as12","model":"claude-opus-4-7"}
  {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"echo hello"}}]}}
  NDJSON
  out_as12="$(assert_no_tool_invocation "$TX_AS12" "git checkout")" && rc_as12=0 || rc_as12=$?
  if [[ "$rc_as12" == "0" && -z "$out_as12" ]]; then
    pass_at "AS12: helper is stage-agnostic; non-matching transcript → rc=0 (cross-stage gating exercised at renderer level by AT7)"
  else
    fail_at "AS12" "rc=$rc_as12 out=$out_as12"
  fi
  ```

- [ ] **Step 3.2 — Append AT6 + AT7 to `bin/dispatch-test.sh`**
  immediately after AT5 ends at line 1362 and BEFORE the
  `--- ENG-49 Gap #7: prompt<->allowlist contract ---` at line 1364.
  AT6 is the renderer-wrapper integration test for the building-stage
  block; AT7 is the cross-stage gating test. Both follow AT1-AT2's
  layout from lines 1248-1296:

  ```bash
  # ─── AT6: renderer integration, stage="building" + match → rc=26, sidecar, log ─
  # AS7-AS12 cover the helper. AT6 covers the renderer-wrapper end-to-end
  # for the build path: gating, sidecar write, pre-clean, log emission.
  USAGE_AT6="$ISSUE_DIR/usage-building-AT6.json"
  RAW_AT6="$ISSUE_DIR/.raw-stream.ndjson.tmp"
  VIOLATION_AT6="$ISSUE_DIR/.transcript-violation-building"
  rm -f "$USAGE_AT6" "$RAW_AT6" "$VIOLATION_AT6"

  at6_rc=0
  RENDER_OUT_AT6="$(
    _render_and_capture_stream "$USAGE_AT6" "$ISSUE_DIR" "building" 2>&1 <<'NDJSON'
  {"type":"system","subtype":"init","session_id":"at6","model":"claude-opus-4-7"}
  {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git checkout main"}}]}}
  {"type":"result","total_cost_usd":0.01,"usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"modelUsage":{"claude-opus-4-7":{}}}
  NDJSON
  )" || at6_rc=$?

  if [[ "$at6_rc" == "26" ]] \
     && [[ -f "$VIOLATION_AT6" ]] \
     && [[ "$(cat "$VIOLATION_AT6")" == "git checkout main" ]] \
     && grep -q '\[assert\] build-stage transcript invoked forbidden tool: git checkout main' <<<"$RENDER_OUT_AT6"; then
    pass_at "AT6 (renderer integration): stage=building+match → rc=26, sidecar written, log line emitted"
  else
    fail_at "AT6 renderer integration" "rc=$at6_rc viol_exists=$([[ -f $VIOLATION_AT6 ]] && echo y || echo n) viol_body=$(cat "$VIOLATION_AT6" 2>/dev/null) out=$RENDER_OUT_AT6"
  fi
  rm -f "$VIOLATION_AT6"

  # ─── AT7: renderer cross-stage gating, stage="qa" + match → rc=0 ─
  # The building-stage block at A-N1 must not fire on non-building stages.
  # Mirror of AT2 for the building-stage gate.
  USAGE_AT7="$ISSUE_DIR/usage-qa-AT7.json"
  VIOLATION_AT7_BUILD="$ISSUE_DIR/.transcript-violation-building"
  VIOLATION_AT7_QA="$ISSUE_DIR/.transcript-violation-qa"
  rm -f "$USAGE_AT7" "$ISSUE_DIR/.raw-stream.ndjson.tmp" "$VIOLATION_AT7_BUILD" "$VIOLATION_AT7_QA"

  at7_rc=0
  _render_and_capture_stream "$USAGE_AT7" "$ISSUE_DIR" "qa" >/dev/null 2>&1 <<'NDJSON' || at7_rc=$?
  {"type":"system","subtype":"init","session_id":"at7","model":"claude-opus-4-7"}
  {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git checkout main-should-be-ignored-on-qa"}}]}}
  {"type":"result","total_cost_usd":0.01,"usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"modelUsage":{"claude-opus-4-7":{}}}
  NDJSON

  if [[ "$at7_rc" == "0" ]] \
     && [[ ! -f "$VIOLATION_AT7_BUILD" ]] \
     && [[ ! -f "$VIOLATION_AT7_QA" ]]; then
    pass_at "AT7 (cross-stage gating): stage=qa with matching transcript → rc=0, no sidecar"
  else
    fail_at "AT7 cross-stage gating" "rc=$at7_rc viol_build=$([[ -f $VIOLATION_AT7_BUILD ]] && echo y || echo n) viol_qa=$([[ -f $VIOLATION_AT7_QA ]] && echo y || echo n)"
  fi
  rm -f "$VIOLATION_AT7_BUILD" "$VIOLATION_AT7_QA"
  ```

- [ ] **Step 3.3 — Append D-003 fixtures (cases 7 + 8) to
  `bin/run-stage-test.sh`** after the last existing case (case 6 at
  line 198 — Task 3.3 reads the file's tail first to confirm the
  insertion point and the existing test summary block):

  ```bash
  # ─── Case 7: D-003 detach-on-mismatch (ENG-71) ─────────────────────────
  # Stub a real git worktree on `main`, call _post_dispatch_check_worktree_head
  # with stage=building, assert (a) HEAD is detached after the call,
  # (b) the worktree-mutated-by-agent metric was written via the metrics
  # stub, (c) an add-or-update-comment was captured with the meta-marker body.
  reset_capture
  reset_metrics_capture() { : > "$STUB_DIR/metrics.capture"; }
  if [[ ! -x "$STUB_DIR/metrics.sh" ]]; then
    cat > "$STUB_DIR/metrics.sh" <<SH
  #!/usr/bin/env bash
  # args: \$1 event \$2 ident \$3 stage \$4 outcome \$5 duration_ms \$6 notes
  printf 'EVENT=%s\nIDENT=%s\nSTAGE=%s\nOUTCOME=%s\nNOTES=%s\n---\n' \
    "\${1:-}" "\${2:-}" "\${3:-}" "\${4:-}" "\${6:-}" >> "$STUB_DIR/metrics.capture"
  exit 0
  SH
    chmod +x "$STUB_DIR/metrics.sh"
  fi
  reset_metrics_capture

  ENG_T7_WT="$(issue_dir ENG-T7)/worktree"
  rm -rf "$ENG_T7_WT"
  mkdir -p "$ENG_T7_WT"
  ( cd "$ENG_T7_WT" \
    && git init --quiet \
    && git config user.email t@t \
    && git config user.name t \
    && git commit --quiet --allow-empty -m init \
    && git checkout -b main --quiet 2>/dev/null \
       || git checkout main --quiet )

  # Override branch-name.sh to return a different branch than `main` so the
  # mismatch fires.
  cat > "$STUB_DIR/branch-name.sh" <<'SH'
  #!/usr/bin/env bash
  printf 'feat/eng-t7-mock-slug\n'
  SH
  chmod +x "$STUB_DIR/branch-name.sh"

  _post_dispatch_check_worktree_head ENG-T7 building >/dev/null 2>&1 || true

  current_head="$(git -C "$ENG_T7_WT" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  metric_count="$(grep -c '^EVENT=worktree-mutated-by-agent$' "$STUB_DIR/metrics.capture" 2>/dev/null || true)"
  comment_count="$(grep -c '^SIG=warn/worktree-mutated/ENG-T7$' "$CAPTURE_FILE" 2>/dev/null || true)"

  if [[ "$current_head" == "HEAD" ]] \
     && [[ "$metric_count" == "1" ]] \
     && [[ "$comment_count" == "1" ]]; then
    pass_at "case-7 D-003 detach-on-mismatch (stage=building, current=main, expected=feat/eng-t7-…) → HEAD detached, metric+comment emitted"
  else
    fail_at "case-7 D-003 detach-on-mismatch" \
      "current_head=$current_head metric_count=$metric_count comment_count=$comment_count"
  fi

  # Restore branch-name.sh to its original mock-slug shape for downstream cases.
  cat > "$STUB_DIR/branch-name.sh" <<'SH'
  #!/usr/bin/env bash
  printf 'feat/%s-mock-slug\n' "$(tr '[:upper:]' '[:lower:]' <<<"$1")"
  SH
  chmod +x "$STUB_DIR/branch-name.sh"

  # ─── Case 8: D-003 no-detach when HEAD on expected branch ──────────────
  reset_capture
  reset_metrics_capture
  ENG_T8_WT="$(issue_dir ENG-T8)/worktree"
  rm -rf "$ENG_T8_WT"
  mkdir -p "$ENG_T8_WT"
  ( cd "$ENG_T8_WT" \
    && git init --quiet \
    && git config user.email t@t \
    && git config user.name t \
    && git commit --quiet --allow-empty -m init \
    && git checkout -b feat/eng-t8-mock-slug --quiet 2>/dev/null \
       || git checkout feat/eng-t8-mock-slug --quiet )

  _post_dispatch_check_worktree_head ENG-T8 building >/dev/null 2>&1 || true

  current_head="$(git -C "$ENG_T8_WT" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  metric_count="$(grep -c '^EVENT=worktree-mutated-by-agent$' "$STUB_DIR/metrics.capture" 2>/dev/null || true)"
  comment_count="$(grep -c '^SIG=warn/worktree-mutated/ENG-T8$' "$CAPTURE_FILE" 2>/dev/null || true)"

  if [[ "$current_head" == "feat/eng-t8-mock-slug" ]] \
     && [[ "$metric_count" == "0" ]] \
     && [[ "$comment_count" == "0" ]]; then
    pass_at "case-8 D-003 no-detach when HEAD on expected branch → no detach, no metric, no comment"
  else
    fail_at "case-8 D-003 no-detach" \
      "current_head=$current_head metric_count=$metric_count comment_count=$comment_count"
  fi

  # ─── Case 9: D-003 stage gate (stage=qa with HEAD on main → no-op) ─────
  reset_capture
  reset_metrics_capture
  ENG_T9_WT="$(issue_dir ENG-T9)/worktree"
  rm -rf "$ENG_T9_WT"
  mkdir -p "$ENG_T9_WT"
  ( cd "$ENG_T9_WT" \
    && git init --quiet \
    && git config user.email t@t \
    && git config user.name t \
    && git commit --quiet --allow-empty -m init \
    && git checkout -b main --quiet 2>/dev/null \
       || git checkout main --quiet )

  _post_dispatch_check_worktree_head ENG-T9 qa >/dev/null 2>&1 || true

  current_head="$(git -C "$ENG_T9_WT" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  metric_count="$(grep -c '^EVENT=worktree-mutated-by-agent$' "$STUB_DIR/metrics.capture" 2>/dev/null || true)"
  comment_count="$(grep -c '^SIG=warn/worktree-mutated/ENG-T9$' "$CAPTURE_FILE" 2>/dev/null || true)"

  if [[ "$current_head" == "main" ]] \
     && [[ "$metric_count" == "0" ]] \
     && [[ "$comment_count" == "0" ]]; then
    pass_at "case-9 D-003 stage gate (stage=qa) → no-op even when HEAD on main"
  else
    fail_at "case-9 D-003 stage gate" \
      "current_head=$current_head metric_count=$metric_count comment_count=$comment_count"
  fi
  ```

- [ ] **Step 3.4 — Run `bash bin/dispatch-test.sh` and
  `bash bin/run-stage-test.sh`** and confirm all new fixtures
  (AS7-AS12, AT6, AT7, cases 7/8/9) PASS, all pre-existing
  fixtures still PASS, exit code 0.

### Task 4: Add `MANDATORY worktree-HEAD rule (ENG-71)` paragraph to AGENT_PROMPTS.md §7 + content-test pins

- `depends_on: []`
- `touches: AGENT_PROMPTS.md (§7 Build Agent), bin/agent-prompts-content-test.sh`

- [ ] **Step 4.1 — Insert the MANDATORY worktree-HEAD rule paragraph
  in `AGENT_PROMPTS.md` §7** between line 1232 (end of the existing
  Tool-allowlist preamble) and line 1234 (the `Read these files
  first (where present):` heading). Concrete content:

  ```markdown
  **MANDATORY worktree-HEAD rule (ENG-71):** Never run `git checkout`,
  `git switch`, `git pull`, or `git reset` inside the worktree. The
  orchestrator already checked out `{branch_name}` for you; the
  post-merge `gh pr merge --auto --delete-branch` you fire is
  server-side and updates main on origin, not on disk. If you want
  to verify the merge SHA on main, query `gh api
  repos/{owner}/{repo}/branches/main --jq '.commit.sha'` (read-only,
  no checkout needed). The post-merge CI watch (`gh run watch
  <run-id>`) operates on the merge run identified by SHA — no
  checkout required. **The prohibition includes chained commands:**
  `git fetch origin main && git checkout main` is forbidden whether
  or not the matcher would have denied it standalone. **If you
  accidentally end up on a branch other than `{branch_name}`, do
  NOT "fix" it by switching back — emit `verdict halt --reason
  agent-blocked` and exit; the orchestrator's post-dispatch detector
  (`bin/run-stage.sh`, ENG-71 D-003) will detach the HEAD to unlock
  main globally.**
  ```

- [ ] **Step 4.2 — Append ENG-71 content-test block to
  `bin/agent-prompts-content-test.sh`.** Insert after the last
  existing assertion (currently at the end of the file, before the
  `printf '\nRESULTS:` summary line). Eight greps in total per A-N12:

  ```bash
  # ─── ENG-71: §7 build agent must not check out main / pull / reset ────
  if printf '%s\n' "$s7" | grep -qF 'MANDATORY worktree-HEAD rule (ENG-71)'; then
    ok "§7 contains ENG-71 worktree-HEAD MANDATORY rule"
  else
    nope "§7 contains ENG-71 worktree-HEAD MANDATORY rule" "phrase missing"
  fi
  for pat in 'git checkout' 'git switch' 'git pull' 'git reset'; do
    if printf '%s\n' "$s7" | grep -qF "\`$pat\`"; then
      ok "§7 explicitly names \`$pat\` as forbidden"
    else
      nope "§7 names \`$pat\`" "pattern not back-tick-quoted in §7"
    fi
  done
  if printf '%s\n' "$s7" | grep -qF 'chained commands'; then
    ok "§7 names chained-command class explicitly"
  else
    nope "§7 names chained-command class" "phrase missing"
  fi
  if printf '%s\n' "$s7" | grep -qF 'git fetch origin main && git checkout main'; then
    ok "§7 contains literal worked example of chained-command bypass"
  else
    nope "§7 contains literal chained-command worked example" \
      "phrase 'git fetch origin main && git checkout main' missing"
  fi

  # ─── ENG-71 symmetric pin: bin/dispatch.sh's building-stage block names
  # the SAME four pattern literals (ENG-62 Bld-001 prompt-orchestrator
  # symmetry discipline). A future contributor who adds a fifth pattern
  # to either site without updating the other fails this test.
  DISPATCH_SH="$HARNESS_ROOT/bin/dispatch.sh"
  if [[ -f "$DISPATCH_SH" ]]; then
    eng71_dispatch_missing=""
    for pat in "'git checkout'" "'git switch'" "'git pull'" "'git reset'"; do
      if ! grep -qF "$pat" "$DISPATCH_SH"; then
        eng71_dispatch_missing+="$pat "
      fi
    done
    if [[ -z "$eng71_dispatch_missing" ]]; then
      ok "ENG-71 symmetric pin: bin/dispatch.sh names all four forbidden patterns"
    else
      nope "ENG-71 symmetric pin: bin/dispatch.sh missing patterns" \
        "patterns missing from bin/dispatch.sh: $eng71_dispatch_missing"
    fi
  else
    nope "ENG-71 symmetric pin: bin/dispatch.sh exists" "file missing"
  fi
  ```

- [ ] **Step 4.3 — Run `bash bin/agent-prompts-content-test.sh`** and
  confirm all eight new assertions PASS, all pre-existing assertions
  still PASS, exit code 0.

### Task 5: Add `docs/runbooks/recovery.md` recovery section

- `depends_on: [1]`
- `touches: docs/runbooks/recovery.md`

- [ ] **Step 5.1 — Read `docs/runbooks/recovery.md`** to determine
  the next available section number (the brainstorm assumes §5; the
  ENG-63 plan also added a §4. Read the file to confirm the actual
  highest existing section number first; this is the only step that
  must read before writing.).

- [ ] **Step 5.2 — Append a new §N "Halted issue with
  `worktree-mutation-forbidden` exit code" subsection** after the
  last existing section. Concrete content (substitute N with the
  number determined in Step 5.1):

  ```markdown
  ---

  ## N. Halted issue with `worktree-mutation-forbidden` exit code

  An issue carries `pipeline:halted` after a build dispatch with the halt
  comment body referencing "build-stage transcript invoked forbidden
  worktree-HEAD-mutating tool" and an `events.jsonl` row with
  `outcome=worktree-mutation-forbidden`.

  ### Symptom

  - `bash bin/linear.sh has-label ENG-N pipeline:halted` returns 0.
  - The most-recent `<!-- pipeline: verdict result=halt reason=agent-blocked -->`
    halt comment body contains: `build-stage transcript invoked forbidden
    worktree-HEAD-mutating tool: <command>`.
  - `events.jsonl` shows a `stage-end` event with
    `outcome=worktree-mutation-forbidden` for the building stage.
  - Optionally, an additional `<!-- meta: metric name=worktree-mutated-by-agent -->`
    comment exists if the chained-command bypass also fired the post-dispatch
    HEAD-detection (D-003 path); the worktree's HEAD will then be detached.

  ### Authoritative signal

  The build agent's tool allowlist excludes `git checkout`, `git switch`,
  `git pull`, and `git reset` (verified at `bin/dispatch.sh::allowed_tools_for
  "building"`). A transcript that invoked any of these — standalone or
  chained — indicates either a tool-lane matcher bypass or a prompt-side
  drift. The dispatch-time assertion (ENG-71 D-002) is the contract test;
  the orchestrator's post-dispatch HEAD-detection (ENG-71 D-003) is the
  catch-net for chained-command variants the assertion's `startswith`
  matcher does not catch.

  ### Recovery

  1. Inspect the matched command in the halt comment body. Confirm it
     is one of the four forbidden patterns and was issued by the build
     agent (not by an operator manually stepping into the worktree).
  2. If the worktree HEAD is detached (D-003 fired), no operator action
     is required for the worktree itself — `cleanup-worktrees.sh` will
     remove it on the next post-merge tick.
  3. If the worktree HEAD is on `main` AND the operator's primary
     `~/code/<repo>/` checkout is locked (`fatal: 'main' is already used
     by worktree at …`), manually detach: `git -C
     <issue-worktree-path> checkout --detach`. This is the same operation
     D-003 performs automatically; running it manually is safe and
     idempotent.
  4. Resume the issue: `bash bin/pipeline.sh decide ENG-N --action continue`.
     The next tick re-dispatches build; if the underlying matcher bypass
     persists, the assertion will fire again (idempotent).

  ### Verify

  After `--action continue`:

  1. `bash bin/linear.sh has-label ENG-N pipeline:halted || echo "not halted"`
     returns `not halted`.
  2. The next 5-minute poll tick re-dispatches build. Inspect the new
     dispatch's transcript at
     `$PROJECT_STATE_DIR/<ident>/logs/building-*.log` to confirm the
     re-dispatch is clean (no rc=26 in the log).

  ---
  ```

- [ ] **Step 5.3 — Confirm `docs/runbooks/recovery.md` is well-formed
  markdown** by visual inspection (no automated lint exists for this
  file; the test suite does not parse it).

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
    && bash bin/phase-project-profile-test.sh && bash bin/common-test.sh \
    && bash bin/agent-prompts-content-test.sh
  ```

  All exit 0. The new fixtures (AS7-AS12, AT6, AT7, run-stage-test
  cases 7/8/9, agent-prompts-content-test ENG-71 block) all PASS.

- [ ] **Step 6.2 — Run the syntax checks.**

  ```bash
  bash -n bin/dispatch.sh bin/run-stage.sh bin/common.sh
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

Pulled from the brainstorm's §7 Error Handling and §8 Edge Cases.

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
|---|---|---|---|---|
| Build agent invokes `git checkout` standalone | Tool_use with `.input.command == "git checkout main"` in transcript | `assert_no_tool_invocation` returns 1 with the matched command on stdout; renderer-wrapper writes `$violation_file`, logs `[assert] build-stage transcript invoked forbidden tool`, returns 26; `run-stage.sh::main` routes via `classify_failure ... skip-until-human-acts ... 26` and exits 26 | unit + integration | `AS7` (helper) + `AT6` (renderer integration) |
| Build agent invokes `git switch` standalone | Tool_use with `.input.command == "git switch main"` | Same as above | unit | `AS8` |
| Build agent invokes `git pull` standalone | Tool_use with `.input.command == "git pull --ff-only origin main"` | Same as above | unit | `AS9` |
| Build agent invokes `git reset` standalone | Tool_use with `.input.command == "git reset --hard origin/main"` | Same as above | unit | `AS10` |
| Build agent uses only allowed git verbs | Tool_use blocks for `git fetch`, `git clone`, `git rebase` only | All four assertions return rc=0; renderer returns cleanly; no sidecar written | unit | `AS11` |
| Helper is stage-agnostic; gate lives in renderer | Helper called with non-matching transcript | rc=0, empty stdout | unit | `AS12` |
| Renderer cross-stage gating: non-building stage has matching transcript | `_render_and_capture_stream` called with stage=qa, transcript contains `git checkout main-should-be-ignored-on-qa` | rc=0, no sidecar (.transcript-violation-building NOT written) | integration | `AT7` |
| D-003 detach-on-mismatch | Worktree HEAD on `main`, `expected_branch=feat/eng-t7-mock-slug` | Helper detaches HEAD, emits `worktree-mutated-by-agent` metric, posts sig-deduped Linear comment | integration | `case-7 D-003 detach-on-mismatch` |
| D-003 no-detach when HEAD on expected branch | Worktree HEAD already on `feat/eng-t8-mock-slug`, `expected_branch=feat/eng-t8-mock-slug` | Helper returns 0 cleanly; no detach, no metric, no comment | integration | `case-8 D-003 no-detach` |
| D-003 stage gate excludes non-building stages | Stage=qa with HEAD on main | Helper returns 0 immediately; no detach, no metric, no comment | integration | `case-9 D-003 stage gate` |
| §7 prompt rule presence drift | A future retrospective edit drops the `MANDATORY worktree-HEAD rule (ENG-71)` paragraph | `bin/agent-prompts-content-test.sh` fails on the rule-presence grep | unit | (content-test grep block in `bin/agent-prompts-content-test.sh` — `§7 contains ENG-71 worktree-HEAD MANDATORY rule`) |
| §7 pattern enumeration drift | A future edit removes `git checkout` / `git switch` / `git pull` / `git reset` from the §7 prose | Content-test fails on the missing pattern grep | unit | (per-pattern asserts in the same content-test block — `§7 explicitly names \`<pattern>\` as forbidden`) |
| §7 chained-commands phrase drift | A future edit removes the `chained commands` phrase or the literal worked example | Content-test fails on the chained-commands grep or the literal-example grep | unit | (`§7 names chained-command class explicitly` + `§7 contains literal worked example of chained-command bypass`) |
| dispatch.sh ↔ §7 pattern symmetry drift | Either site adds a fifth pattern without the other | Symmetric pin in `bin/agent-prompts-content-test.sh` fails for the missing site | unit | (`ENG-71 symmetric pin: bin/dispatch.sh names all four forbidden patterns`) |
| `branch-name.sh` Linear API outage during D-003 | `branch-name.sh` dies (Linear unreachable) | D-003's `2>/dev/null \|\| printf ''` catches; helper falls through to `[[ -n "$expected_branch" ... ]] \|\| return 0`; no detach, no metric (false-negative tolerated per §7 trade-off) | (none — `\|\| return 0` short-circuit; documented impossibility for unit tests without a Linear stub double-failure) | n/a |
| `git -C $wt checkout --detach` failure | Corrupt worktree, permission denial | Logged via `2>&1 \| sed 's/^/  detach: /' >&2 \|\| true`; does not abort the function (next callee in main() runs as normal) | (none — `\|\| true` is a documented trade-off per brainstorm §7) | n/a |
| `metrics.sh worktree-mutated-by-agent` write failure | `events.jsonl` directory unwritable | Logged via `\|\| log "...non-blocking"`; helper continues; the operator-visibility comment still posts | (none — `\|\| log` is a documented trade-off per brainstorm §7) | n/a |
| Chained command starting with allowed prefix bypasses D-002 | Tool_use with `.input.command == "git fetch origin main && git checkout main"` | D-002's `startswith` matcher misses (the command starts with `git fetch`); D-003 catches the resulting worktree-on-main state and detaches; metric+comment fire | (covered by case-7 — same end state as standalone-checkout because D-003 is state-of-the-world, not transcript-based) | `case-7 D-003 detach-on-mismatch` |
| Two consecutive build dispatches: first triggers D-002, operator runs `decide --action continue`, second re-dispatches | Standard halt-resume flow | `pipeline:halted` removed, skip-until-* labels removed, wait-* JSON removed, issue-state.json conditionally removed, transition waypoint posted; next tick re-dispatches; if behavior corrected, second dispatch passes; if not, loop repeats and operator escalates | (none — this is the standard ENG-58 atomic-resume contract; no new test surface introduced) | n/a |
| Operator runs `decide --action approve --gate scope` instead of `--action continue` for an exit-26 halt | Operator confusion | `--action approve --gate scope` is for scope-violation halts only (per CLAUDE.md "Operator workflow"); for `worktree-mutation-forbidden` the correct command is `--action continue`. The runbook §N (Task 5) documents this explicitly | (none — runbook doc only) | n/a |

## Test Strategy

### Unit (primary layer)

The change is fully testable at the unit level via the source-and-stub
patterns already used by `bin/dispatch-test.sh` (AS-block fixtures
that call `assert_no_tool_invocation` directly with hand-rolled
NDJSON transcripts) and `bin/run-stage-test.sh` (real `git init`'d
worktrees under `$STUB_DIR` with stubbed `linear.sh` / `branch-name.sh`
/ `metrics.sh`).

AS7-AS12 cover D-002's helper-level surface (4 forbidden patterns +
1 passthrough + 1 stage-agnostic confirmation). AT6 + AT7 cover
D-002's renderer-wrapper integration (rc=26 + sidecar + log on
match; rc=0 + no sidecar on cross-stage). Cases 7/8/9 in
`run-stage-test.sh` cover D-003's behavior under the three relevant
states (mismatch → detach + metric + comment; match → no-op; non-building
stage → gate-excluded no-op). The eight greps in
`agent-prompts-content-test.sh` cover D-001's prompt prose (rule
presence, four pattern enumerations, chained-commands phrase, literal
worked example, plus the symmetric dispatch.sh pin per A-N12).

### Integration (renderer-wrapper level)

AT6 + AT7 in `bin/dispatch-test.sh` exercise the renderer-wrapper
end-to-end (helper + gate + sidecar + log) for the building-stage
path. They mirror AT1 + AT2's design for the implementing-stage
path verbatim.

Run-stage cases 7/8/9 exercise `_post_dispatch_check_worktree_head`
end-to-end against real `git init`'d worktrees, verifying the
detach action's effect on the actual git state (not just function
return codes).

### Smoke / e2e

None added. The brainstorm explicitly rejected end-to-end tests
that dispatch a real `claude -p` (per D-004 rejected-alternative).
Real `claude -p` invocations are exactly the boundary the
source-and-stub pattern was designed to avoid; AS1-AS6 / AT1-AT5
established this convention, AS7-AS12 / AT6-AT7 / cases 7-9
extend it.

### Adversarial

The plan does not add a separate adversarial test file
(`bin/halt-sprawl-adversarial-test.sh`-style). Two adversarial
considerations from the brainstorm:

- **Chained-command bypass of D-002's `startswith` matcher.** Covered
  end-to-end by case-7's behavior (D-003 catches the resulting
  state regardless of how the agent issued the chained command);
  no separate adversarial fixture needed because the unit-level
  tests already exercise the catch-net.
- **Linear-title rename between dispatch start and post-dispatch
  D-003 fire** (would cause a spurious detach if `branch-name.sh`'s
  Linear-derived title differs from what was used at dispatch
  start). Acknowledged trade-off per brainstorm §7 (detach is
  informative-only and reflog-recoverable). No defensive code, no
  test fixture — the failure mode is bounded to a brief race
  window (post-dispatch, pre-cleanup) and the worst-case outcome
  (detach on a worktree that was correctly on the feature branch)
  is non-destructive.

The pre-existing adversarial test files target different surfaces
(`halt-sprawl-adversarial-test.sh` covers halt-state sprawl;
`run-local-helpers-adversarial-test.sh` covers partition_dirty_paths
edge cases); no new adversarial file is warranted for this scope.

---

## Self-review summary (5 personas)

Run inline this session per the planning stage's persona-review
contract. Five personas dispatched against the iter-1 draft.

| Persona | Verdict | P0 | Notes / changes from iter-1 |
|---|---|---|---|
| feasibility | PASS | 0 | All 30 codebase facts (A-001…A-030) verified against the current worktree at `path:line`. `bin/dispatch.sh::_render_and_capture_stream` exists at :94-194 with the implementing-stage block at :184-193 (verified by reading the file directly); `assert_no_tool_invocation` at :48-65 with the `startswith` shape; `building` allowlist at :252 excludes the four forbidden patterns; `bin/common.sh::failure_outcome_for_exit` taxonomy gap at code 26 (verified at :107-129); `bin/run-stage.sh::main` post-dispatch chain at :836-915 with `verdict_handler` call at :915 (verified by reading the file directly); `_post_dispatch_apply_halt` at :376-388 and `_pre_dispatch_merge_gate` at :521-562 establish the helper-shape precedents the new `_post_dispatch_check_worktree_head` mirrors; `bin/branch-name.sh::main` at :15-32 is the canonical derivation reused in the new helper; `bin/dispatch-test.sh` AS1-AS6 layout at :1141-1235 is the template for AS7-AS12; `bin/run-stage-test.sh` source-and-stub at :1-119 is the template for cases 7-9; `bin/agent-prompts-content-test.sh::section_body` at :20-28 is the template for the new ENG-71 grep block; `AGENT_PROMPTS.md` §7 fence range at :1227-1474 with insertion point at :1232-1234 confirmed by direct read; `bin/pipeline-events.json::meta_kinds` at :42-47 includes `metric` (used by the new operator-visibility comment); `bin/classify-failure.sh:124-146` confirms exit-26 routing through `skip-until-human-acts` produces `agent-blocked` halt marker (no new halt_reason needed). Every task's `depends_on` is correct: Task 1 has no deps, Task 2 depends on Task 1 (the helper sits adjacent to existing helpers but the call-site in main() must coexist with the rc=26 routing also added in Task 1), Task 3 depends on 1+2 (test fixtures exercise the implemented behavior), Task 4 has no deps (prompt + content-test pair is independent), Task 5 depends on Task 1 (runbook documents the implemented exit code), Task 6 depends on all. Every Failure Mode → Test Map row names a concrete test by name except the documented "n/a" rows (impossible/documented-only edge cases). |
| scope | PASS | 0 | Every task and every File Structure entry traces to a brainstorm decision: Task 1 → D-002; Task 2 → D-003; Task 3 → D-004 (test pin); Task 4 → D-001 + D-004; Task 5 → D-002 companion (operator runbook); Task 6 → AC verification. Acceptance criteria #1 (prompt rule), #2 (transcript assertion), #3 (post-dispatch detector), #4 (test fixtures), #5 (runbook) all covered. The Linear issue's three-layer "Proposed scope" (prompt-level, sandbox-level, defense-in-depth) is fully addressed; the issue's recommendation to "do (1) and (3) immediately as one PR; defer (2) into its own ticket" is honored in spirit (D-001 + D-003 ship as the user-visible defense; D-002 ships alongside as the contract layer; the matcher-bypass investigation itself is deferred to O-1). Out-of-scope items (O-1 matcher repro, O-2 cross-stage helper generalisation, O-3 learned-rules entry, O-4 substring-match upgrade, O-7 D-003 stage-gating widening) explicitly listed and unchanged from brainstorm. No gold-plating: the plan does not modify allowed_tools_for, does not change pipeline-events.json, does not add new lane fences, does not extend the meta_kinds vocab. |
| coherence | PASS | 0 | Plan's Goal matches brainstorm §1 Overview (defense across three layers against build-agent worktree-HEAD mutation). Backend tasks jointly realise every brainstorm decision (D-001…D-004). Test Strategy covers every Failure Mode row with a named test or an explicit n/a justified by the brainstorm's documented impossibility/trade-off. No frontend tasks (correctly stated as "no UI surface"). No API contract block (correctly stated as "no FE↔BE API surface"). Failure Mode → Test Map is complete: AS7-AS12 cover the helper-level matrix, AT6-AT7 cover the renderer-integration matrix, cases 7-9 cover the post-dispatch detector matrix, the content-test grep block covers the prompt/orchestrator symmetry. |
| design | PASS | 0 | Plan respects the harness's bash module boundaries: changes confined to `bin/dispatch.sh` (one function, one new block), `bin/common.sh` (one taxonomy entry), `bin/run-stage.sh` (one new helper + one rc arm + one call-site + one header line), and three test files. No new helper functions in `bin/dispatch.sh` (the new block is inline, parallel to ENG-43's pattern). The new `_post_dispatch_check_worktree_head` follows the existing post-dispatch helper shape (PIPELINE_WRITER attribution, stage-gating idiom, soft-fail guards). The dispatch-time assertion (D-002) ↔ orchestrator state-check (D-003) split mirrors CLAUDE.md's "Defense-in-depth on top of tool-lane denials" guidance: D-002 is the canonical contract test (transcript-based); D-003 is the state-check fallback that exists *because* the symptom is global (operator-impact across worktrees), not local. Lane fences untouched. The new metric event (`worktree-mutated-by-agent`) joins the existing event-name family (`worktree-cleanup`, `worktree-orphan-detected` per `bin/cleanup-worktrees.sh`). |
| product | PASS | 0 | Plan delivers the operator's actual ask in language they would recognise: "the build agent will no longer lock main globally by checking it out in the per-issue worktree." The runbook §N gives the operator a clear recovery recipe for the exit-26 halt class. The metric emission (D-003's `worktree-mutated-by-agent`) closes the retrospective-blindness gap so future occurrences surface in the weekly review. Changes are scoped narrowly enough that an unrelated reviewer can verify the operator-visible behaviour by reading: (a) the §7 prompt rule (one paragraph), (b) AS9's transcript fixture (one heredoc), (c) case-7's worktree fixture (one git-init flow). The prompt-level rule is the durable layer; the dispatch assertion is the contract layer; the post-dispatch detector is the safety net for the chained-command bypass class. All three layers are necessary because each closes a different failure mode (prompt = teaching, assertion = contract, detector = state recovery). |

**Gate:** 5/5 PASS, 0 P0. Threshold (≥4/5 PASS AND zero P0)
cleanly satisfied. Proceeding to implementing.
