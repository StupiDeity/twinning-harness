---
linear: ENG-66
date: 2026-05-08
topic: cross-stage transcript assertion for the four banned branch-creation forms — rc=23 → branch-creation-forbidden, mirrors ENG-43 / ENG-71 / ENG-68 plumbing
---

# Plan — ENG-66 transcript-based runtime defense for banned branch-creation forms

Implementation plan for the design at
`docs/brainstorms/2026-05-08-eng-66-add-transcript-based-runtime-defense-for-banned-branch-creation-forms-git-checkout-b-b-branch-m-switch-c-design.md`.

## Anti-anchoring check

- **Problem (operator's words).** PR #48 (commit `4635cd3`, May 2026) added
  a prompt-level "Branch-name convention" section in `AGENT_PROMPTS.md`
  after the ENG-63/64/65 incident — three implementing-stage dispatches
  halted because agents created `feature/eng-N-…` branches via
  `git checkout -B` instead of using the canonical `feat/eng-N-…` the
  orchestrator had already substituted as `{branch_name}`. The prompt
  now names the four banned branch-creation forms explicitly (`git
  checkout -b`, `git checkout -B`, `git branch -m`, `git switch -c`)
  at `AGENT_PROMPTS.md:86`, with a content-test pin in
  `bin/agent-prompts-content-test.sh:505`. Prompt rules can be
  ignored; the harness needs a runtime defense like ENG-43's
  `assert_no_tool_invocation` for `gh pr create` (rc=22), ENG-71's
  build-stage four-pattern loop (rc=26), and ENG-68's cross-stage
  `core.bare` loop (rc=13).
- **Does the brainstorm address it?** Yes, with exactly the runtime
  layer the issue asks for: a four-pattern loop in
  `bin/dispatch.sh::_render_and_capture_stream` that calls
  `assert_no_tool_invocation` per pattern, returns rc=23 on first
  match, writes the sidecar at `${issue_dir}/.transcript-violation-${stage}`,
  and routes through `run-stage.sh::main` to a
  `classify_failure ... skip-until-human-acts` halt with the new
  `branch-creation-forbidden` outcome. Cross-stage by design (D-002),
  matching ENG-68's precedent.
- **Proportional?** Yes. ~12 LOC of new for-loop in `dispatch.sh`,
  ~10 LOC parallel `elif` arm in `run-stage.sh::main`, 1 line in
  `common.sh::failure_outcome_for_exit`, 1 line in `run-stage.sh:4-11`
  exit-code header, ~120 LOC of test additions split across BC1-BC8
  in `dispatch-test.sh` and Test 18 in `classify-failure-test.sh`,
  plus a small new subsection in `docs/runbooks/recovery.md`. No new
  helpers, no new state files, no allowlist edits, no registry entries,
  no metric event names. Three direct precedents (ENG-43, ENG-71,
  ENG-68) all shipped the same shape.
- **No escalation needed.** PROCEED.

## Goal

Land a single PR off `main` (`feat/eng-66-…`) that, after merge,
satisfies these acceptance criteria — verifiable by:

```
bash bin/dispatch-test.sh \
  && bash bin/classify-failure-test.sh \
  && bash bin/run-stage-test.sh \
  && bash bin/common-test.sh \
  && bash bin/agent-prompts-content-test.sh \
  && bash -n bin/dispatch.sh bin/common.sh bin/run-stage.sh \
  && bash bin/secret-probe-lint.sh
```

exiting 0 with the new BC1-BC8 fixtures (in `bin/dispatch-test.sh`)
and the new Test 18 fixture (in `bin/classify-failure-test.sh`) all
PASS.

1. **Cross-stage transcript assertion (D-001 / D-002 / D-003):**
   `bin/dispatch.sh::_render_and_capture_stream` carries a new
   for-loop iterating over four literal prefixes (`git checkout -b`,
   `git checkout -B`, `git branch -m`, `git switch -c`); on first
   match it writes the matched command to `${issue_dir}/.transcript-violation-${stage}`,
   logs `[assert] stage=<stage> transcript invoked forbidden
   branch-creation form: <command>`, and returns 23. The loop is
   inserted AFTER the ENG-71 building-stage block (line 218) and
   BEFORE the ENG-68 cross-stage `core.bare` block (line 232 / 219).
   No stage gate (cross-stage like ENG-68; mirrors AC2 of the issue).
2. **`run-stage.sh` exit-code routing (D-004):**
   `bin/run-stage.sh::main` routes `dispatch_rc == 23` through
   `classify_failure ... skip-until-human-acts` with the matched
   command as the operator-facing reason, removes the sidecar, exits
   23. The new branch sits BEFORE the existing rc=26 branch
   (current line 772 of `run-stage.sh`).
3. **Outcome taxonomy entry (D-005):**
   `bin/common.sh::failure_outcome_for_exit` maps
   `23 → branch-creation-forbidden`. `bin/run-stage.sh:4-11`
   header docstring lists `23=branch-creation-forbidden` between
   the existing `22=pr-opened-too-early` and `26=worktree-mutation-forbidden`
   entries.
4. **Test pinning (D-007 / D-008):** `bin/dispatch-test.sh`
   gains BC1-BC8 fixtures (four positives, one negative, one
   chained-bypass, one renderer-integration end-to-end on
   `stage="implementing"`, one cross-stage gating fixture
   confirming the loop fires on `stage="qa"` too).
   `bin/classify-failure-test.sh` gains Test 18 mirroring Test 15
   (existing ENG-71 entry pin) for exit 23.
5. **Operator runbook (D-004 companion, mandatory per
   product-P1 fold):** `docs/runbooks/recovery.md` gains a new
   §7 "Halted issue with `branch-creation-forbidden` exit code"
   subsection covering: (a) what triggers exit 23, (b) the manual-
   cleanup recipe (`git -C <wt> branch -D <wrong-name>` then
   confirm `{branch_name}` is on HEAD), (c) the standard
   `bash bin/pipeline.sh decide <issue> --action continue` resume,
   (d) a one-line note that on the build stage, an rc=26 halt
   whose sidecar shows a `-b`/`-B`/`-c` form is the same
   underlying drift surfaced via the ENG-71 collision case
   (D-006).

Out of scope (explicit per brainstorm §12.2):

- O-1: helper-shape generalisation (an array-of-patterns variant
  of `assert_no_tool_invocation`). Defer to a fourth call site.
- O-2: chained-command substring upgrade
  (`git status && git checkout -b foo` bypass) — inherited from
  ENG-43/71/68's `startswith` blind spot. BC6 fixture pins the
  documented blind spot so a future refactor doesn't accidentally
  fix it without an audit.
- O-3: long-flag aliases (`git switch --create`, `git branch
  --move`, `git checkout --branch`). Defer to an observed incident.
- O-4: post-dispatch state-of-the-world detector (mirror of
  ENG-71 D-003 HEAD-detect). The matched-command sidecar is the
  operator-facing surface; `--action continue` after manual
  branch deletion already covers recovery.
- O-5: SEC-005-aligned `( umask 077; ... )` wrapper around the
  four sidecar-write call sites (ENG-43 line 189, ENG-71 line 213,
  ENG-68 line 242, ENG-66's new write). Out of scope for ENG-66
  (which inherits the gap rather than introducing it).

## Architecture (where code goes)

This work is additive across:

- one new for-loop in `bin/dispatch.sh::_render_and_capture_stream`
  (between the existing ENG-71 building-stage block and the existing
  ENG-68 cross-stage `core.bare` block; no new helper functions),
- one new exit-code arm in `bin/common.sh::failure_outcome_for_exit`,
- one new exit-code header line + one new `elif (( dispatch_rc == 23 ))`
  arm in `bin/run-stage.sh`,
- BC1-BC8 fixtures in `bin/dispatch-test.sh`,
- Test 18 in `bin/classify-failure-test.sh`,
- a new §7 subsection in `docs/runbooks/recovery.md`.

The architectural pivot — already established by ENG-43, ENG-71,
ENG-68 — is that the existing `assert_no_tool_invocation` helper
is the canonical transcript-assertion primitive, and adding a new
cross-stage check is a copy-paste of the four-pattern loop pattern.
No new infrastructure is needed; this brainstorm explicitly
prefers the inline four-pattern loop over a new
`assert_no_branch_creation` wrapper (D-001 rejected alternative).

There is no `docs/VISION.md`, no `docs/ARCHITECTURE.md`, no
`docs/knowledge/decisions.md` (verified: `ls docs/` returns
`brainstorms/  pipeline-vocabulary.md  pipeline-vocabulary.template.md
plans/  runbooks/`). Governing constraints come from `CLAUDE.md` and
`learned-rules/harness/{project-profile,build}.md`. The
`learned-rules/harness/plan.md` file does not exist (verified: `ls
learned-rules/harness/` returns `build.md  project-profile.md` only).

## Tech stack

- Bash 3.2+ (Darwin default, harness target).
- `jq` for the existing `assert_no_tool_invocation` helper (one
  fork per pattern; four patterns → four forks per dispatch ≈ 40 ms,
  per brainstorm D-001 cost calculus).
- Existing `bin/metrics.sh` accepts the `branch-creation-forbidden`
  outcome string verbatim through `classify_failure`'s emission;
  no schema change.
- No new dependencies. No new `dispatch.sh::allowed_tools_for`
  cases. No new metrics event names. No new pipeline-events
  registry tokens.

## Assumption Inventory

Every modified-file fact below is `path:line`-cited against the
current worktree per ENG-5 P-002 / B-001. Assumptions marked
`assumed/new` identify the file where the artifact will be created.

### Modified files — current signatures, call sites, and insertion points

- **A-001 — `bin/dispatch.sh::_render_and_capture_stream` is
  defined at `bin/dispatch.sh:94-247`** with concrete entry signature
  at `bin/dispatch.sh:94-95`:

  ```bash
  _render_and_capture_stream() {
    local usage_file="$1" issue_dir="$2" stage="${3:-}"
  ```

  The renderer carries three existing assertion blocks today
  (verified by direct read):
  - **Implementing-stage `gh pr create` block** at
    `bin/dispatch.sh:184-193` (gated `if [[ "$stage" == "implementing" ]]`,
    returns 22).
  - **Building-stage four-pattern block** at
    `bin/dispatch.sh:207-218` (gated `if [[ "$stage" == "building" ]]`,
    loops over `'git checkout' 'git switch' 'git pull' 'git reset'`,
    returns 26).
  - **Cross-stage `core.bare` five-pattern block** at
    `bin/dispatch.sh:219-246` (no stage gate, loops over five
    patterns, returns 13).

  Plan inserts the new ENG-66 four-pattern loop between line 218
  (closing `fi` of the ENG-71 block) and line 219 (opening comment
  of the ENG-68 block). No stage gate; mirrors the ENG-68 shape
  verbatim. Returns 23. The block-after-block layout becomes:
  stage-specific scans first (ENG-43, ENG-71), cross-stage scans
  grouped at the end (ENG-66 NEW, ENG-68).

- **A-002 — `bin/dispatch.sh::assert_no_tool_invocation` is at
  `bin/dispatch.sh:48-65`** with `startswith` semantics. Concrete shape:

  ```bash
  assert_no_tool_invocation() {
    local transcript="$1" pattern="$2"
    [[ -s "$transcript" ]] || return 0
    local matched
    matched="$(jq -Rr --arg p "$pattern" '
      fromjson? // empty
      | select(.type == "assistant")
      | .message.content[]?
      | select(.type == "tool_use" and .name == "Bash")
      | (.input.command // "")
      | select(startswith($p))
    ' "$transcript" 2>/dev/null | head -1)" || true
    if [[ -n "$matched" ]]; then
      printf '%s\n' "$matched"
      return 1
    fi
    return 0
  }
  ```

  Soft-fails on missing/empty transcript at line 50; emits the first
  match via `head -1` at line 59. **Inherited limitation:** chained
  commands (`git status && git checkout -b foo`) bypass the
  `startswith` check (BC6 documents this; mirrors AS12).

- **A-003 — `bin/dispatch.sh::_render_and_capture_stream` writes
  the violation file under `${issue_dir}/.transcript-violation-${stage}`**
  with pre-clean at function entry. Verified at `bin/dispatch.sh:97-98`:

  ```bash
  local violation_file="${issue_dir}/.transcript-violation-${stage}"
  rm -f "$violation_file"            # idempotent pre-clean (D-008)
  ```

  The new ENG-66 block reuses `$violation_file` and `$raw_capture`
  in scope from the function head; no new variable assignments.

- **A-004 — `bin/dispatch.sh::allowed_tools_for` per-stage
  allowlists at `bin/dispatch.sh:297-309`** show the cross-stage
  scan rationale. Verified:
  - `implementing` (line 301): carries `Bash(git checkout:*)`,
    `Bash(git switch:*)`, `Bash(git branch:*)`.
  - `ui` (line 302): same as implementing.
  - `qa` (line 304): carries broad `Bash(git:*)`.
  - `building` (line 305): only `Bash(git fetch:*)`,
    `Bash(git clone:*)`, `Bash(git rebase:*)` — no checkout/switch/
    branch/reset/pull entries.

  Plan does NOT modify any allowlist; the four banned forms are
  ban-by-policy on top of the lane denials, not lane-level removals.

- **A-005 — `bin/common.sh::failure_outcome_for_exit` is at
  `bin/common.sh:111-136`; slot 23 is unused.** Verified. Concrete
  current shape (`bin/common.sh:114-135`):

  ```bash
  case "$exit_code" in
    0) ... ;;
    10) printf 'guards-tripped' ;;
    11) printf 'paused' ;;
    12) printf 'stage-drift' ;;
    13) printf 'lane-violation' ;;
    14) printf 'legacy-marker-write' ;;
    20) printf 'dispatch-failed' ;;
    21) printf 'scope-violation' ;;
    22) printf 'pr-opened-too-early' ;;
    24) printf 'linear-post-failed' ;;
    25) printf 'agent-contract-missing' ;;
    26) printf 'worktree-mutation-forbidden' ;;
    27) printf 'self-leak' ;;
    28) printf 'leaked-in-scope-threshold' ;;
    124) printf 'dispatch-timeout' ;;
    *)  printf 'unknown-exit-%s' "$exit_code" ;;
  esac
  ```

  Slot 23 absent. Plan inserts a `23) printf 'branch-creation-forbidden' ;;`
  arm between the existing `22)` arm (line 127) and the existing
  `24)` arm (line 128).

- **A-006 — `bin/run-stage.sh` exit-code header docstring at
  `bin/run-stage.sh:4-11`.** Verified. Current shape:

  ```
  # Exit codes: 0=success, 10=guards-tripped, 11=paused, 12=stage-drift (post-dispatch
  #             stage label changed during run; no halt re-applied), 13=lane-violation
  #             (linear.sh write rejected for caller's PIPELINE_WRITER lane),
  #             20=dispatch-failed, 21=scope-violation, 22=pr-opened-too-early,
  #             24=linear-post-failed, 25=agent-contract-missing (agent exited clean
  #             but emitted neither the stage-summary file nor a verdict-marker comment),
  #             26=worktree-mutation-forbidden (build-stage transcript invoked
  #             git checkout/switch/pull/reset; ENG-71).
  ```

  Plan adds `23=branch-creation-forbidden (any-stage transcript invoked
  git checkout -b/-B/branch -m/switch -c; ENG-66)` between the existing
  `22=pr-opened-too-early,` token and the `24=linear-post-failed,` token.

- **A-007 — `bin/run-stage.sh::main` dispatch-rc handling for rc=22
  at lines 759-771.** Verified. Concrete shape (`bin/run-stage.sh:759-771`):

  ```bash
  elif (( dispatch_rc == 22 )); then
    # ENG-43: implement-stage transcript invoked the forbidden
    # `gh pr create` tool. ...
    local _viol_file _viol_cmd
    _viol_file="$(issue_dir "$ident")/.transcript-violation-${stage}"
    _viol_cmd="$(cat "$_viol_file" 2>/dev/null || printf '<command-unavailable>')"
    classify_failure "$ident" "$stage" "skip-until-human-acts" \
      "implement-stage transcript invoked forbidden tool: $_viol_cmd" 22
    rm -f "$_viol_file" "$prompt_file"
    exit 22
  ```

  The next arm (rc=26 at lines 772-798) and the rc=13 arm (lines
  799-812) follow the same body shape. Plan adds a new
  `elif (( dispatch_rc == 23 )); then` arm immediately AFTER the
  rc=22 arm (between line 771 and line 772) and BEFORE the rc=26 arm.

- **A-008 — `bin/dispatch-test.sh` CB1-CB8 fixtures end at line 1482.**
  Verified by reading lines 1340-1482. CB1-CB5 cover the five
  `core.bare` patterns directly; CB6 covers multi-tool_use ordering
  via `head -1`; CB7 covers renderer-integration end-to-end
  (rc=13 + sidecar + log line); CB8 covers sidecar pre-clean
  idempotency. The next block — `--- QA-authored adversarial
  fixtures (AT1-AT5; ENG-43 not in Failure Mode → Test Map) ---`
  — begins at line 1484 and continues. Plan APPENDS BC1-BC8 between
  line 1482 (end of CB8) and line 1484 (header of the AT block).

- **A-009 — `bin/dispatch-test.sh` AS1-AS6 fixture pattern.** Verified at
  `bin/dispatch-test.sh:1141-1235` (per ENG-71 plan A-017). Pattern is:
  - `TX_<NAME>="$_TEST_STUB_DIR/tx-<name>.ndjson"` heredoc setup,
  - direct `assert_no_tool_invocation` call,
  - `pass_at` / `fail_at` on `(rc, stdout)` tuple.
  AS12 fixture at `bin/dispatch-test.sh:1320-1338` already pins the
  `startswith` chained-command bypass for the ENG-71 set; BC6 mirrors
  it for the ENG-66 patterns. CB7 fixture at lines 1428-1458 is the
  canonical renderer-integration template; BC7 + BC8 mirror that.

- **A-010 — `bin/classify-failure-test.sh` Test 15 pins the
  ENG-71 exit-26 entry at lines 220-232.** Verified. Concrete shape:

  ```bash
  reset_state; reset_metrics
  classify_failure "ENG-913" "building" "skip-until-human-acts" "wt" 26 ""
  outcome=$(latest_outcome)
  [[ "$outcome" == "worktree-mutation-forbidden" ]] \
    && pass_at "case-15 exit 26 → worktree-mutation-forbidden" \
    || fail_at "case-15" "outcome=$outcome"
  ```

  Plan APPENDS Test 18 at the end of the file (after Test 17 at
  approximately line 250+; Task 4 reads the file's tail to confirm
  the precise insertion point) following the same shape.

- **A-011 — `bin/agent-prompts-content-test.sh:505-512` already pins
  the four banned forms for the prompt side.** Verified:

  ```bash
  for forbidden in 'git checkout -b' 'git checkout -B' 'git branch -m' 'git switch -c'; do
    if grep -qF "$forbidden" <<<"$prompts_full"; then
      ok "Branch-name convention names forbidden form: $forbidden"
    else
      nope "Branch-name convention names forbidden form: $forbidden" \
           'section must explicitly enumerate banned commands so agents cannot rationalize a near-equivalent'
    fi
  done
  ```

  Plan does NOT modify this file. AC5 of the issue text names
  `bin/test-isolation-test.sh` as the place to pin the new exit-code
  entry; per D-008 of the brainstorm, the actual home is
  `bin/classify-failure-test.sh` (Test 18) since AC5's "or a new
  test" clause permits the deviation and the precedent (Test 15
  for the analogous ENG-71 exit-26 entry) is already there. The
  `bin/test-isolation-test.sh` file's purpose (verified at
  `bin/test-isolation-test.sh:1-5`) is fixture-leak regression for
  the 2026-05-04 incident, not exit-code taxonomy.

- **A-012 — `AGENT_PROMPTS.md:77-88` is the §3 "Branch-name
  convention" section** carrying the four banned forms in the §3
  hard-rules block. Verified by direct read; rule 2 at line 86
  enumerates exactly the four forms. `AGENT_PROMPTS.md:582`
  repeats the four forms in the implement-agent §6 prompt body.
  Plan does NOT modify `AGENT_PROMPTS.md` (the prompt rule is
  the existing primary defense; ENG-66 is the runtime tripwire).

- **A-013 — `docs/runbooks/recovery.md` has six existing numbered
  sections** (per `grep '^## ' docs/runbooks/recovery.md`):
  §1 multi-stage labels, §2 forged transition comment, §3 stuck
  protocol-violation halt, §4 stale halt comment timestamp, §5
  Canceled-issue worktree backfill, §6
  `worktree-mutation-forbidden` exit code (ENG-71). The next
  available section number is §7. Plan APPENDS §7 immediately
  after §6 (which ends at line 345 — `---` separator) and BEFORE
  the existing "Quick reference: env var requirement" at line
  347. Section structure follows §6's layout: Symptom /
  Authoritative signal / Recovery / Verify.

- **A-014 — `bin/classify-failure.sh` halt-comment shape** uses
  `<!-- pipeline: verdict result=halt reason=agent-blocked -->` for
  `skip-until-human-acts` policy (verified per ENG-71 plan A-025
  and `bin/classify-failure.sh:124-146`). The exit-23 routing
  through `classify_failure ... "skip-until-human-acts" ... 23`
  produces a halt comment with that marker. The matched command
  rides through `classify_failure` as `effective_reason` text and
  ends up in the comment body via `bin/classify-failure.sh:124-146`'s
  text-builder; the metric `outcome` field gets the typed
  `branch-creation-forbidden` string from
  `failure_outcome_for_exit 23 ""`. **No new entry is added to
  `bin/pipeline-events.json::halt_reasons`** — `agent-blocked`
  already covers the operator-facing surface; the typed outcome
  is metric-only (consumed by retrospective §1's outcome filter).

- **A-015 — `bin/secret-probe-lint.sh` ENG-46 secret-handling rule.**
  The new code introduces no env-var fallback patterns matching
  the forbidden regex `*KEY|*TOKEN|*SECRET|ANTHROPIC*|GITHUB*|LINEAR*`.
  All new variables are scalar bash (`_branch_pattern`,
  `_matched_branch`, `_viol_file_23`, `_viol_cmd_23`); no secret
  references introduced.

### Read-only callees / state shapes — verified, not modified

- **A-016 — `bin/dispatch.sh::_render_and_capture_stream` writes the
  violation file under a single sidecar path per stage.** Verified —
  the path `${issue_dir}/.transcript-violation-${stage}` is shared
  by ENG-43 (line 189), ENG-71 (line 213), ENG-68 (line 242). Each
  branch returns on first match; the renderer cannot produce two
  violations in one dispatch (D-005 rationale).

- **A-017 — `bin/dispatch.sh::_render_and_capture_stream` installs a
  RETURN trap to clean up `$raw_capture`** at line 99
  (`trap 'rm -f "$raw_capture"' RETURN`). The trap fires regardless of
  which return code the function emits; no ENG-66 cleanup required
  beyond writing the violation file.

- **A-018 — Halt-comment / metric carry the matched command via
  `jq --arg`-encoded text.** Verified (per brainstorm §8 row +
  `bin/linear.sh:167` direct read). The matched command — a single
  line of agent-controlled prose — is JSON-encoded into the GraphQL
  request body; no shell injection surface. Same path applies for
  the metric `notes` field via `bin/metrics.sh`.

- **A-019 — `bin/run-local-helpers.sh::partition_dirty_paths` D-004
  basename token check applies only to `brainstorming|planning`
  stages.** Verified (per ENG-71 plan A-021). The implement-stage
  edits to `bin/dispatch.sh`, `bin/common.sh`, `bin/run-stage.sh`,
  and the two test files all bucket via the harness-self target's
  scope allowlist (verified by ENG-43 / ENG-58 / ENG-62 / ENG-63 /
  ENG-64 / ENG-71 commits successfully landing the same paths).

- **A-020 — `learned-rules/harness/build.md` Bld-001 documents the
  prompt-orchestrator query symmetry pattern.** Verified at
  `learned-rules/harness/build.md` (per ENG-71 plan A-022). ENG-66
  honors the symmetry: the prompt at `AGENT_PROMPTS.md:86`
  enumerates four literal forms; the new dispatch-side loop
  enumerates the same four forms verbatim;
  `bin/agent-prompts-content-test.sh:505` already pins the prompt
  side. A future contributor adding a fifth pattern updates BOTH
  sites or fails the symmetric content-test pin (the plan does not
  add a NEW dispatch-side content-test, on the rationale that the
  existing prompt-side pin plus the BC1-BC4 fixture coverage of
  the four exact patterns is symmetric enough; if drift becomes a
  pattern, a follow-up adds the dispatch-side grep — out of scope).

### Assumed/new artifacts

- **A-N1 — Cross-stage branch-creation assertion block (~12 LOC)**
  is NEW in `bin/dispatch.sh::_render_and_capture_stream`, inserted
  between line 218 (closing `fi` of the ENG-71 block) and line 219
  (opening comment of the ENG-68 block). No new helper functions;
  the block is inline, parallel to A-001's existing ENG-68 block.

- **A-N2 — `23)` arm in `bin/common.sh::failure_outcome_for_exit`**
  is NEW. Single line: `23) printf 'branch-creation-forbidden' ;;`
  inserted between the existing `22)` and `24)` arms (between
  `bin/common.sh:127` and `:128`).

- **A-N3 — `23=branch-creation-forbidden` enumeration in
  `bin/run-stage.sh:4-11`'s exit-code header** is NEW. One-line
  insertion, between the `22=pr-opened-too-early,` token and the
  `24=linear-post-failed,` token.

- **A-N4 — `elif (( dispatch_rc == 23 )); then` arm in
  `bin/run-stage.sh::main`** is NEW. ~10 LOC parallel to A-007's
  existing rc=22 arm (lines 759-771), inserted between the rc=22
  arm and the rc=26 arm (between line 771 and line 772). Body
  per brainstorm D-004 verbatim.

- **A-N5 — Test fixtures BC1-BC8 in `bin/dispatch-test.sh`** are
  NEW. Eight fixtures appended after CB8 (line 1482) and before
  the AT-block header at line 1484:
  - **BC1** — `git checkout -b feature/eng-99-foo` matches
    `git checkout -b` → rc=1, matched command on stdout.
  - **BC2** — `git checkout -B feature/eng-99-foo` matches
    `git checkout -B` → rc=1 (issue AC3).
  - **BC3** — `git branch -m feature-eng-99` matches
    `git branch -m` → rc=1.
  - **BC4** — `git switch -c feature/eng-99-foo` matches
    `git switch -c` → rc=1.
  - **BC5** — `git checkout feat/eng-66-add-transcript-…`
    (no `-b`/`-B`) does NOT match any of the four forbidden
    patterns → rc=0 for each (issue AC4).
  - **BC6** — `git status && git checkout -b feature/foo`
    (chained command) does NOT match (documents the inherited
    `startswith` blind spot per brainstorm O-2; mirrors AS12).
  - **BC7** — renderer integration end-to-end:
    `_render_and_capture_stream` with `stage="implementing"`
    and a transcript containing `git checkout -B feature/eng-66-foo`
    returns rc=23, writes the sidecar at
    `${ISSUE_DIR}/.transcript-violation-implementing`, emits the
    log line `[assert] stage=implementing transcript invoked
    forbidden branch-creation form: git checkout -B feature/eng-66-foo`.
    Mirrors CB7 verbatim.
  - **BC8** — cross-stage scan fires on `stage="qa"` (verifies
    D-002 has no stage gate). Same shape as BC7 but with
    `stage="qa"`; expect rc=23 and a sidecar at
    `${ISSUE_DIR}/.transcript-violation-qa`.

- **A-N6 — Test 18 in `bin/classify-failure-test.sh`** is NEW.
  Single fixture mirroring Test 15 verbatim except for the
  exit code (23) and outcome string (`branch-creation-forbidden`).
  Inserted at the end of the file (Task 4 reads the file's tail
  first to confirm the precise insertion point — Test 17 is
  currently the last fixture per `grep '^# ─── Test' bin/classify-failure-test.sh`).

- **A-N7 — `docs/runbooks/recovery.md` §7** is NEW. Inserted
  between §6 (ends at line 345 with `---`) and "Quick reference:
  env var requirement" (begins at line 347). Section body
  documents:
  - **Symptom:** `pipeline:halted` label after any-stage dispatch +
    halt comment body containing `agent transcript invoked
    forbidden branch-creation form: <command>` + an `events.jsonl`
    `stage-end` row with `outcome=branch-creation-forbidden`.
  - **Authoritative signal:** the per-issue worktree may now have
    an extra branch (`feature/eng-N-…` or similar wrong-named
    branch) created by the agent's invocation. The orchestrator's
    canonical branch (`feat/eng-N-…` per `bin/branch-name.sh`) is
    still the worktree's expected HEAD; if the agent's
    `git checkout -b` succeeded, the worktree's HEAD is now on
    the wrong branch.
  - **Recovery:**
    1. Inspect the matched command in the halt comment body.
    2. `git -C $(issue_dir <issue>)/worktree status` to see
       which branch the worktree is on.
    3. If on the wrong branch:
       `git -C $(issue_dir <issue>)/worktree checkout {canonical_branch}`
       (the canonical branch — `feat/eng-N-…` — should still
       exist as a separate ref).
    4. `git -C $(issue_dir <issue>)/worktree branch -D <wrong-branch>`
       to clean up the wrong-named branch.
    5. `bash bin/pipeline.sh decide ENG-N --action continue`.
  - **Build-stage collision note:** on the build stage, an
    rc=26 `worktree-mutation-forbidden` halt whose sidecar
    shows a `-b`/`-B`/`-c` form is the same underlying drift
    surfaced via the ENG-71 ordering (D-006 collision case).
    Apply the same recovery recipe.

## File Structure

```
bin/
  dispatch.sh                              modified — insert ~12 LOC ENG-66 cross-stage
                                                      branch-creation assertion block in
                                                      _render_and_capture_stream between :218
                                                      (end of ENG-71 block) and :219 (start
                                                      of ENG-68 block). Returns 23 on match;
                                                      writes $violation_file. (Task 1)
  common.sh                                modified — insert `23) printf
                                                      'branch-creation-forbidden' ;;` arm
                                                      between :127 (slot 22) and :128 (slot 24).
                                                      (Task 1)
  run-stage.sh                             modified — (a) one-line insertion to the exit-code
                                                      header docstring at :4-11 documenting
                                                      23=branch-creation-forbidden between the
                                                      22= and 24= tokens; (b) new ~10 LOC
                                                      `elif (( dispatch_rc == 23 ))` arm
                                                      between :771 (end of rc=22 arm) and :772
                                                      (start of rc=26 arm). (Task 2)
  dispatch-test.sh                         modified — append BC1-BC8 (eight fixtures, ~120 LOC)
                                                      between :1482 (end of CB8) and :1484
                                                      (header of AT-block). (Task 3)
  classify-failure-test.sh                 modified — append Test 18 (~10 LOC) at the end of
                                                      the file, after the current last test
                                                      (Test 17). (Task 4)

docs/
  runbooks/
    recovery.md                            modified — insert new §7 "Halted issue with
                                                      `branch-creation-forbidden` exit code"
                                                      subsection between :345 (end of §6) and
                                                      :347 (start of "Quick reference"
                                                      section). (Task 5)
  plans/
    2026-05-08-eng-66-...-git-checkout-b-b-branch-m-switch-c.md   NEW — this file.
```

No changes to: `AGENT_PROMPTS.md` (prompt rule already in place
per A-012), `bin/agent-prompts-content-test.sh` (prompt-side pin
already in place per A-011), `bin/dispatch.sh::allowed_tools_for`
(per A-004 — the four banned forms are ban-by-policy on top of
existing lane denials), `bin/run-local.sh`, `bin/run-local-helpers.sh`,
`bin/poll.sh`, `bin/reconcile.sh`, `bin/scope-check.sh`,
`bin/verdict-handler.sh`, `bin/classify-failure.sh` (A-014 — no
halt-reason or comment-shape change), `bin/linear.sh`,
`bin/metrics.sh` (A-014 — outcome string flows through
`failure_outcome_for_exit` verbatim), `bin/branch-name.sh`,
`bin/cleanup-worktrees.sh`, `bin/pipeline.sh`, `bin/setup.sh`,
`bin/render-prompt.sh`, `bin/pipeline-events.json` (A-014 — no
new event token; `agent-blocked` reason and `metric` meta-kind
already cover the surface), `bin/test-isolation-test.sh` (per
brainstorm D-008 — Test 18 home is `classify-failure-test.sh`,
not test-isolation), `learned-rules/**`, `launchd/**`,
`.github/workflows/**`, `docs/pipeline-vocabulary.md` (template +
generated doc untouched; no registry change → no regen needed),
`docs/pipeline-vocabulary.template.md`, `CLAUDE.md` (no surface
that would benefit from a row update; the recovery.md addition is
a new section operators can find via the existing runbook index).

## API Contract

**No new API surface.** The harness has no FE↔BE API surface.
The change adds:

- One new dispatch.sh exit code (`23 = branch-creation-forbidden`)
  consumed by `bin/run-stage.sh::main`'s dispatch-rc handling and
  by `bin/common.sh::failure_outcome_for_exit`.
- One new typed outcome string (`branch-creation-forbidden`)
  written verbatim by the pre-existing `bin/classify-failure.sh →
  bin/metrics.sh` plumbing through `failure_outcome_for_exit 23`.
  No schema migration.
- No new comment-body shape: the halt comment uses the existing
  `<!-- pipeline: verdict result=halt reason=agent-blocked -->`
  marker shape (per A-014). No registry change to
  `bin/pipeline-events.json`.

No CLI argv change, no env-var addition, no on-disk state-file
format change, no new lane fence, no new metric event name. The
four-shape verdict vocabulary (`pass | fail | halt | wait`) is
untouched.

## Backend Tasks

### Task 1: Add cross-stage branch-creation transcript assertion + outcome taxonomy entry

- `depends_on: []`
- `touches: bin/dispatch.sh::_render_and_capture_stream, bin/common.sh::failure_outcome_for_exit`

- [ ] **Step 1.1 — Insert cross-stage branch-creation assertion block
  in `bin/dispatch.sh::_render_and_capture_stream`.** Append the new
  block immediately AFTER line 218 (closing `fi` of the ENG-71
  building-stage block) and BEFORE line 219 (opening comment of the
  ENG-68 cross-stage `core.bare` block). Body verbatim per brainstorm
  D-001:

  ```bash
  # ENG-66: forbid agent-side branch-creation across ALL stages.
  # AGENT_PROMPTS.md §3 rule 2 lists exactly these four banned forms.
  # The orchestrator has already created and checked out {branch_name}
  # in the per-issue worktree; an agent that creates a new branch is
  # forking off the canonical path and will (a) push to a wrong-named
  # remote ref, (b) trip the legacy feature/* coexistence path in
  # run-local.sh (ENG-67), (c) make scope-check evaluate against the
  # wrong worktree.
  local _branch_pattern _matched_branch
  for _branch_pattern in \
      "git checkout -b" \
      "git checkout -B" \
      "git branch -m" \
      "git switch -c"; do
    if _matched_branch="$(assert_no_tool_invocation "$raw_capture" "$_branch_pattern")"; then
      :   # rc 0: no match, fall through to next pattern
    else
      printf '%s\n' "$_matched_branch" > "$violation_file"
      log "[assert] stage=$stage transcript invoked forbidden branch-creation form: ${_matched_branch}"
      return 23
    fi
  done
  ```

  The `$violation_file` variable is in scope from line 97
  (`violation_file="${issue_dir}/.transcript-violation-${stage}"`)
  and pre-cleaned at line 98 (per A-003). The `$raw_capture` variable
  is the renderer's captured NDJSON path (line 96). The block is
  parallel to the ENG-68 cross-stage block at lines 219-246; no
  stage gate (cross-stage by design per D-002).

- [ ] **Step 1.2 — Add `23)` arm to
  `bin/common.sh::failure_outcome_for_exit`.** Insert the new arm
  between the existing `22)` arm (line 127) and the existing `24)`
  arm (line 128):

  ```bash
  22) printf 'pr-opened-too-early' ;;
  23) printf 'branch-creation-forbidden' ;;
  24) printf 'linear-post-failed' ;;
  ```

- [ ] **Step 1.3 — Verify with `bash -n bin/dispatch.sh bin/common.sh`.**
  Syntax check, must exit 0.

- [ ] **Step 1.4 — Verify with `bash bin/secret-probe-lint.sh`.**
  No new env-var fallback patterns introduced (per A-015).

### Task 2: Add `dispatch_rc == 23` routing in `run-stage.sh`

- `depends_on: [1]`
- `touches: bin/run-stage.sh::main (rc=23 arm + header docstring)`

- [ ] **Step 2.1 — Update the exit-code header docstring at
  `bin/run-stage.sh:4-11`.** Insert `23=branch-creation-forbidden`
  between the existing `22=pr-opened-too-early,` token and the
  `24=linear-post-failed,` token. Concrete edit replaces the
  existing two-line span:

  ```
  #             20=dispatch-failed, 21=scope-violation, 22=pr-opened-too-early,
  #             24=linear-post-failed, 25=agent-contract-missing (agent exited clean
  ```

  with:

  ```
  #             20=dispatch-failed, 21=scope-violation, 22=pr-opened-too-early,
  #             23=branch-creation-forbidden (any-stage transcript invoked
  #             git checkout -b/-B/branch -m/switch -c; ENG-66),
  #             24=linear-post-failed, 25=agent-contract-missing (agent exited clean
  ```

- [ ] **Step 2.2 — Add `elif (( dispatch_rc == 23 )); then` arm in
  `bin/run-stage.sh::main`.** Insert immediately AFTER the existing
  rc=22 arm at line 771 (`exit 22`) and BEFORE the existing rc=26
  arm at line 772 (`elif (( dispatch_rc == 26 )); then`). Body
  per brainstorm D-004 verbatim:

  ```bash
  elif (( dispatch_rc == 23 )); then
    # ENG-66: agent transcript invoked one of the four banned
    # branch-creation forms (git checkout -b/-B, git branch -m,
    # git switch -c). The orchestrator owns the worktree's branch;
    # this is a hard halt — the operator must investigate before
    # the next dispatch. Cross-stage by design (the renderer's
    # ENG-66 loop has no stage gate); fires on any stage whose
    # transcript matched. Recovery recipe is documented in
    # docs/runbooks/recovery.md §7.
    local _viol_file_23 _viol_cmd_23
    _viol_file_23="$(issue_dir "$ident")/.transcript-violation-${stage}"
    _viol_cmd_23="$(cat "$_viol_file_23" 2>/dev/null || printf '<command-unavailable>')"
    classify_failure "$ident" "$stage" "skip-until-human-acts" \
      "agent transcript invoked forbidden branch-creation form: $_viol_cmd_23" 23
    rm -f "$_viol_file_23" "$prompt_file"
    exit 23
  ```

- [ ] **Step 2.3 — Verify with `bash -n bin/run-stage.sh`.** Syntax
  check, must exit 0.

### Task 3: Pin BC1-BC8 fixtures in `bin/dispatch-test.sh`

- `depends_on: [1]`
- `touches: bin/dispatch-test.sh`

- [ ] **Step 3.1 — Append BC1-BC8 to `bin/dispatch-test.sh`** between
  line 1482 (end of CB8) and line 1484 (header of the AT-block).
  Each fixture follows the AS1-AS6 / CB1-CB6 source-and-stub layout
  for direct-helper tests (BC1-BC6) or the CB7 / CB8 layout for
  renderer-integration tests (BC7-BC8). Concrete shape (ASCII
  approximation; final form mirrors AS1 / CB1 byte-for-byte except
  for the pattern strings):

  ```bash
  # ─── Group 7 cont'd: branch-creation transcript-pattern fixtures (ENG-66, BC1-BC8) ───
  # AGENT_PROMPTS.md §3 rule 2 lists exactly four banned branch-creation
  # forms. _render_and_capture_stream's ENG-66 cross-stage loop scans
  # for these four prefixes on every dispatched stage (no stage gate;
  # mirrors the ENG-68 cross-stage core.bare block). BC1-BC4 pin each
  # of the four positives; BC5 pins the canonical-checkout negative;
  # BC6 pins the inherited startswith blind spot on chained commands
  # (mirror of AS12); BC7 pins renderer integration end-to-end on
  # stage=implementing (mirror of CB7); BC8 pins cross-stage gating
  # by firing on stage=qa (NEW shape — verifies D-002 no-stage-gate).
  printf '\n--- assert_no_tool_invocation fixtures (BC1-BC8, ENG-66 branch-creation patterns + renderer integration + cross-stage gating) ---\n'

  # BC1 — `git checkout -b feature/eng-99-foo` matches "git checkout -b"
  TX_BC1="$_TEST_STUB_DIR/tx-bc1.ndjson"
  cat > "$TX_BC1" <<'NDJSON'
  {"type":"system","subtype":"init","session_id":"bc1","model":"test"}
  {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git checkout -b feature/eng-99-foo"}}]}}
  NDJSON
  out_bc1="$(assert_no_tool_invocation "$TX_BC1" "git checkout -b")" && rc_bc1=0 || rc_bc1=$?
  if [[ "$rc_bc1" == "1" && "$out_bc1" == "git checkout -b feature/eng-99-foo" ]]; then
    pass_at "BC1: 'git checkout -b feature/eng-99-foo' matches 'git checkout -b' pattern"
  else
    fail_at "BC1" "rc=$rc_bc1 out=$out_bc1"
  fi

  # BC2 — `git checkout -B feature/eng-99-foo` matches "git checkout -B" (issue AC3)
  TX_BC2="$_TEST_STUB_DIR/tx-bc2.ndjson"
  cat > "$TX_BC2" <<'NDJSON'
  {"type":"system","subtype":"init","session_id":"bc2","model":"test"}
  {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git checkout -B feature/eng-99-foo"}}]}}
  NDJSON
  out_bc2="$(assert_no_tool_invocation "$TX_BC2" "git checkout -B")" && rc_bc2=0 || rc_bc2=$?
  if [[ "$rc_bc2" == "1" && "$out_bc2" == "git checkout -B feature/eng-99-foo" ]]; then
    pass_at "BC2: 'git checkout -B feature/eng-99-foo' matches 'git checkout -B' pattern (issue AC3)"
  else
    fail_at "BC2" "rc=$rc_bc2 out=$out_bc2"
  fi

  # BC3 — `git branch -m feature-eng-99` matches "git branch -m"
  TX_BC3="$_TEST_STUB_DIR/tx-bc3.ndjson"
  cat > "$TX_BC3" <<'NDJSON'
  {"type":"system","subtype":"init","session_id":"bc3","model":"test"}
  {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git branch -m feature-eng-99"}}]}}
  NDJSON
  out_bc3="$(assert_no_tool_invocation "$TX_BC3" "git branch -m")" && rc_bc3=0 || rc_bc3=$?
  if [[ "$rc_bc3" == "1" && "$out_bc3" == "git branch -m feature-eng-99" ]]; then
    pass_at "BC3: 'git branch -m feature-eng-99' matches 'git branch -m' pattern"
  else
    fail_at "BC3" "rc=$rc_bc3 out=$out_bc3"
  fi

  # BC4 — `git switch -c feature/eng-99-foo` matches "git switch -c"
  TX_BC4="$_TEST_STUB_DIR/tx-bc4.ndjson"
  cat > "$TX_BC4" <<'NDJSON'
  {"type":"system","subtype":"init","session_id":"bc4","model":"test"}
  {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git switch -c feature/eng-99-foo"}}]}}
  NDJSON
  out_bc4="$(assert_no_tool_invocation "$TX_BC4" "git switch -c")" && rc_bc4=0 || rc_bc4=$?
  if [[ "$rc_bc4" == "1" && "$out_bc4" == "git switch -c feature/eng-99-foo" ]]; then
    pass_at "BC4: 'git switch -c feature/eng-99-foo' matches 'git switch -c' pattern"
  else
    fail_at "BC4" "rc=$rc_bc4 out=$out_bc4"
  fi

  # BC5 — passthrough: `git checkout {canonical-branch}` (no -b/-B) does NOT
  # match any of the four forbidden patterns (issue AC4). Loop over each
  # pattern; each must return rc=0 with empty stdout.
  TX_BC5="$_TEST_STUB_DIR/tx-bc5.ndjson"
  cat > "$TX_BC5" <<'NDJSON'
  {"type":"system","subtype":"init","session_id":"bc5","model":"test"}
  {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git checkout feat/eng-66-add-transcript-based-runtime-defense"}}]}}
  NDJSON
  bc5_failures=0
  for _pat in 'git checkout -b' 'git checkout -B' 'git branch -m' 'git switch -c'; do
    out_bc5="$(assert_no_tool_invocation "$TX_BC5" "$_pat")" && rc_bc5=0 || rc_bc5=$?
    if [[ "$rc_bc5" != "0" || -n "$out_bc5" ]]; then
      bc5_failures=$((bc5_failures+1))
      fail_at "BC5 ($_pat passthrough)" "rc=$rc_bc5 out=$out_bc5"
    fi
  done
  if [[ "$bc5_failures" == "0" ]]; then
    pass_at "BC5: 'git checkout feat/eng-66-...' (no -b/-B) does NOT match any of the four forbidden patterns (issue AC4)"
  fi

  # BC6 — chained-command bypass: `git status && git checkout -b feature/foo`
  # starts with `git status`, not `git checkout -b`. Inherited startswith
  # blind spot per brainstorm O-2; mirrors AS12 / CB6's startswith semantics.
  # Documents the limitation so a future refactor doesn't accidentally fix
  # it without an audit.
  TX_BC6="$_TEST_STUB_DIR/tx-bc6.ndjson"
  cat > "$TX_BC6" <<'NDJSON'
  {"type":"system","subtype":"init","session_id":"bc6","model":"test"}
  {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git status && git checkout -b feature/foo"}}]}}
  NDJSON
  out_bc6="$(assert_no_tool_invocation "$TX_BC6" "git checkout -b")" && rc_bc6=0 || rc_bc6=$?
  if [[ "$rc_bc6" == "0" && -z "$out_bc6" ]]; then
    pass_at "BC6: chained-command bypass — 'git status && git checkout -b feature/foo' does NOT match (startswith blind spot; brainstorm O-2)"
  else
    fail_at "BC6 chained-command bypass" "rc=$rc_bc6 out=$out_bc6 (expected rc=0; the chained command starts with 'git status', not 'git checkout -b')"
  fi

  # BC7 — _render_and_capture_stream end-to-end on stage="implementing"
  # (mirror of CB7 for ENG-68). Pin the dispatch-side wiring of D-001/D-002
  # end-to-end: gating absence (cross-stage), sidecar write at
  # ${issue_dir}/.transcript-violation-implementing, log-line emission,
  # rc=23.
  USAGE_BC7="$ISSUE_DIR/usage-implementing-BC7.json"
  RAW_BC7="$ISSUE_DIR/.raw-stream.ndjson.tmp"
  VIOLATION_BC7="$ISSUE_DIR/.transcript-violation-implementing"
  rm -f "$USAGE_BC7" "$RAW_BC7" "$VIOLATION_BC7"

  bc7_rc=0
  RENDER_OUT_BC7="$(
    _render_and_capture_stream "$USAGE_BC7" "$ISSUE_DIR" "implementing" 2>&1 <<'NDJSON'
  {"type":"system","subtype":"init","session_id":"bc7","model":"claude-opus-4-7"}
  {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git checkout -B feature/eng-66-foo"}}]}}
  {"type":"result","total_cost_usd":0.01,"usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"modelUsage":{"claude-opus-4-7":{}}}
  NDJSON
  )" || bc7_rc=$?

  if [[ "$bc7_rc" == "23" ]] \
     && [[ -f "$VIOLATION_BC7" ]] \
     && [[ "$(cat "$VIOLATION_BC7")" == "git checkout -B feature/eng-66-foo" ]] \
     && grep -q '\[assert\] stage=implementing transcript invoked forbidden branch-creation form: git checkout -B feature/eng-66-foo' <<<"$RENDER_OUT_BC7"; then
    pass_at "BC7 (renderer integration): branch-creation form on stage=implementing → rc=23, sidecar written, log line emitted"
  else
    fail_at "BC7 renderer integration" "rc=$bc7_rc viol_exists=$([[ -f $VIOLATION_BC7 ]] && echo y || echo n) viol_body=$(cat "$VIOLATION_BC7" 2>/dev/null) out=$RENDER_OUT_BC7"
  fi
  rm -f "$VIOLATION_BC7"

  # BC8 — cross-stage scan fires on stage="qa" (verifies D-002 has no
  # stage gate). Mirror of BC7 with stage="qa" and the violation file
  # at .transcript-violation-qa. Confirms the ENG-66 loop is NOT
  # gated to a specific stage (in contrast to ENG-43 implementing-only
  # and ENG-71 building-only).
  USAGE_BC8="$ISSUE_DIR/usage-qa-BC8.json"
  RAW_BC8="$ISSUE_DIR/.raw-stream.ndjson.tmp"
  VIOLATION_BC8="$ISSUE_DIR/.transcript-violation-qa"
  rm -f "$USAGE_BC8" "$RAW_BC8" "$VIOLATION_BC8"

  bc8_rc=0
  RENDER_OUT_BC8="$(
    _render_and_capture_stream "$USAGE_BC8" "$ISSUE_DIR" "qa" 2>&1 <<'NDJSON'
  {"type":"system","subtype":"init","session_id":"bc8","model":"claude-opus-4-7"}
  {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git switch -c feature/eng-66-qa"}}]}}
  {"type":"result","total_cost_usd":0.01,"usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"modelUsage":{"claude-opus-4-7":{}}}
  NDJSON
  )" || bc8_rc=$?

  if [[ "$bc8_rc" == "23" ]] \
     && [[ -f "$VIOLATION_BC8" ]] \
     && [[ "$(cat "$VIOLATION_BC8")" == "git switch -c feature/eng-66-qa" ]] \
     && grep -q '\[assert\] stage=qa transcript invoked forbidden branch-creation form: git switch -c feature/eng-66-qa' <<<"$RENDER_OUT_BC8"; then
    pass_at "BC8 (cross-stage gating): branch-creation form on stage=qa → rc=23 (D-002 no-stage-gate verified)"
  else
    fail_at "BC8 cross-stage gating" "rc=$bc8_rc viol_exists=$([[ -f $VIOLATION_BC8 ]] && echo y || echo n) viol_body=$(cat "$VIOLATION_BC8" 2>/dev/null) out=$RENDER_OUT_BC8"
  fi
  rm -f "$VIOLATION_BC8"
  ```

- [ ] **Step 3.2 — Run `bash bin/dispatch-test.sh` and confirm all
  BC1-BC8 fixtures PASS (alongside the existing AS/CB/AT fixtures).**

### Task 4: Pin Test 18 in `bin/classify-failure-test.sh`

- `depends_on: [1]`
- `touches: bin/classify-failure-test.sh`

- [ ] **Step 4.1 — Read the tail of `bin/classify-failure-test.sh`**
  to confirm the precise insertion point. Test 17 is currently the
  last fixture (`grep '^# ─── Test' bin/classify-failure-test.sh`
  enumerates Tests 1-17). Test 18 inserts immediately after Test 17.

- [ ] **Step 4.2 — Append Test 18** mirroring Test 15 verbatim
  except for the exit code (23) and the outcome string
  (`branch-creation-forbidden`). Concrete shape:

  ```bash
  # ─── Test 18: exit 23 → outcome=branch-creation-forbidden (ENG-66) ────
  # Pin the new cross-stage exit code added in ENG-66. Without this
  # fixture, a regression that drops the `23)` arm in
  # failure_outcome_for_exit routes silently to `unknown-exit-23` and
  # the retrospective's §1 outcome filter misses it (CLAUDE.md: "adding
  # a new exit code without updating that switch routes it to
  # `unknown-exit-N` and the retrospective's §1 filter will not classify
  # it"). Mirror of Test 15 (ENG-71 exit-26 entry pin).
  reset_state; reset_metrics
  classify_failure "ENG-914" "implementing" "skip-until-human-acts" "br" 23 ""
  outcome=$(latest_outcome)
  [[ "$outcome" == "branch-creation-forbidden" ]] \
    && pass_at "case-18 exit 23 → branch-creation-forbidden" \
    || fail_at "case-18" "outcome=$outcome"
  ```

- [ ] **Step 4.3 — Run `bash bin/classify-failure-test.sh` and confirm
  Test 18 PASS (alongside the existing Tests 1-17).**

### Task 5: Add §7 to `docs/runbooks/recovery.md`

- `depends_on: [1, 2]`
- `touches: docs/runbooks/recovery.md`

- [ ] **Step 5.1 — Read `docs/runbooks/recovery.md`** to confirm
  the §6 boundary at line 345 and the next-section start at line
  347 (Quick reference: env var requirement). Insertion point is
  after the `---` at line 345 and before the `## Quick reference`
  heading at line 347.

- [ ] **Step 5.2 — Append §7 "Halted issue with
  `branch-creation-forbidden` exit code"** following §6's structure:

  ```markdown
  ## 7. Halted issue with `branch-creation-forbidden` exit code

  An issue carries `pipeline:halted` after any-stage dispatch with
  the halt comment body referencing "agent transcript invoked
  forbidden branch-creation form" and an `events.jsonl` row with
  `outcome=branch-creation-forbidden`.

  ### Symptom

  - `bash bin/linear.sh has-label ENG-N pipeline:halted` returns 0.
  - The most-recent `<!-- pipeline: verdict result=halt reason=agent-blocked -->`
    halt comment body contains: `agent transcript invoked forbidden
    branch-creation form: <command>`, where `<command>` starts with
    one of `git checkout -b`, `git checkout -B`, `git branch -m`,
    or `git switch -c`.
  - `events.jsonl` shows a `stage-end` event with
    `outcome=branch-creation-forbidden` for the offending stage.

  ### Authoritative signal

  AGENT_PROMPTS.md §3 rule 2 explicitly forbids these four
  branch-creation forms; the orchestrator has already created the
  canonical `feat/eng-N-…` (or `fix/eng-N-…`) branch and checked
  it out in the per-issue worktree before the agent's dispatch.
  An agent that ran one of the four forbidden forms has likely
  created an off-canon branch (e.g. `feature/eng-N-…`); the
  worktree's HEAD may now be on that wrong branch. ENG-66's
  cross-stage runtime defense (`bin/dispatch.sh::_render_and_capture_stream`)
  is the runtime tripwire on top of the prompt rule and the
  `bin/agent-prompts-content-test.sh:505` content pin.

  ### Recovery

  1. Inspect the matched command in the halt comment body.
     Confirm it starts with one of the four banned forms.
  2. Inspect the worktree HEAD:
     ```bash
     git -C "$(bash bin/run-stage.sh issue_dir ENG-N)/worktree" status
     ```
     (or use the per-project state path directly:
     `$PROJECT_STATE_DIR/<slug>/ENG-N/worktree/`).
  3. If the worktree's HEAD is on a wrong-named branch (e.g.
     `feature/eng-N-…`):
     1. Switch back to the canonical branch:
        ```bash
        git -C <wt> checkout feat/eng-N-<slug>
        ```
        (Use `bash bin/branch-name.sh ENG-N` to derive the
        canonical name.)
     2. Delete the wrong-named branch:
        ```bash
        git -C <wt> branch -D <wrong-branch>
        ```
     3. Confirm `git -C <wt> status` shows `On branch feat/eng-N-…`.
  4. Resume the issue:
     ```bash
     bash bin/pipeline.sh decide ENG-N --action continue
     ```

  ### Build-stage collision note

  On the build stage, an `rc=26` halt with
  `outcome=worktree-mutation-forbidden` whose sidecar shows a
  `-b`/`-B`/`-c` form is the same underlying branch-creation
  drift surfaced via the ENG-71 ordering (D-006 collision case).
  Apply the same recovery recipe — the operator-facing recovery
  is identical regardless of which exit code fired.

  ### Verify

  After `--action continue`:

  1. `bash bin/linear.sh has-label ENG-N pipeline:halted || echo "not halted"`
     returns `not halted`.
  2. The next 5-minute poll tick re-dispatches the offending stage.
     Inspect the new dispatch's transcript at
     `$PROJECT_STATE_DIR/<ident>/logs/<stage>-*.log` to confirm the
     re-dispatch is clean (no rc=23 in the log).

  ---
  ```

- [ ] **Step 5.3 — `bash -n` on shell syntax in the markdown.**
  No shell to syntax-check; the recipe blocks are illustrative.
  Confirm the markdown renders cleanly with `head -100
  docs/runbooks/recovery.md` (no malformed code-fence boundaries).

### Task 6: Final regression sweep

- `depends_on: [1, 2, 3, 4, 5]`
- `touches: (no new edits — verification only)`

- [ ] **Step 6.1 — Run the full repo test sweep:**

  ```bash
  bash bin/dispatch-test.sh \
    && bash bin/classify-failure-test.sh \
    && bash bin/run-stage-test.sh \
    && bash bin/common-test.sh \
    && bash bin/agent-prompts-content-test.sh \
    && bash -n bin/dispatch.sh bin/common.sh bin/run-stage.sh \
    && bash bin/secret-probe-lint.sh
  ```

  All commands exit 0; no regression in the existing AS / CB / AT
  / Test 15-17 fixtures.

- [ ] **Step 6.2 — Inspect the implement-stage transcript** for any
  ENG-66-related log line during the implement dispatch (the agent
  does not need to invoke any of the four banned forms — its only
  branch-mutation surface during implement is `git checkout`
  without `-b`, plus `git commit`, `git push`, etc.). The renderer
  scans the agent's own transcript; if the agent followed the
  prompt rule, no rc=23 fires.

## Frontend Tasks

**No frontend tasks.** The harness has no FE↔BE API surface. The
runtime defense lives entirely in shell orchestration scripts
(`bin/dispatch.sh`, `bin/common.sh`, `bin/run-stage.sh`).

## Failure Mode → Test Map

Pulled from brainstorm §7 (Error handling), §8 (Edge cases), §10
(Persona review iteration-2 folds), and §13 (Test strategy):

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
|---|---|---|---|---|
| Empty/missing transcript | dry-run path or any path bypassing the renderer | `assert_no_tool_invocation` returns 0 (soft-fail at `bin/dispatch.sh:50`); no false rc=23 | unit | implicit (existing AS1-AS6 / CB1-CB6 share this code path; no new fixture needed — already covered by the helper's `[[ -s "$transcript" ]] || return 0` guard) |
| Malformed JSON line in transcript | one bad NDJSON line | `fromjson? // empty` silently drops it (line 53); rc=0 / rc=1 honors valid lines | unit | implicit (existing AT5 fixture covers malformed-input; `fromjson? // empty` is shared) |
| Sidecar from a prior crashed dispatch | stale `.transcript-violation-<stage>` from previous dispatch | Renderer pre-clean at line 98 removes stale file; clean current dispatch sees no stale state | unit | CB8 already pins this for the ENG-68 path; ENG-66 inherits the same pre-clean path (single sidecar across all four assertion blocks) — implicit pin |
| `run-stage.sh` crashes between dispatch and rc=23 branch | unhandled non-routing failure | Sidecar persists in `$issue_dir`; next dispatch's renderer pre-cleans it (no false replay) | integration | implicit (covered by the renderer's pre-clean — same path BC7 / BC8 exercise) |
| Multiple matching `tool_use` blocks | transcript with two or more banned forms | `head -1` returns the FIRST match; pattern loop's order (`-b` → `-B` → `-m` → `-c`) decides which fires first | unit | BC1-BC4 pin each pattern individually; loop ordering is preserved by design (literal-string array in source order) — implicit |
| Pattern with regex metacharacters | hypothetical agent invokes a literal `[` etc. | jq's `startswith($p)` is literal-string; no surprise expansion | unit | covered by AT5 (existing); ENG-66 inherits the same code path |
| Chained-command bypass | `git status && git checkout -b foo` | `.input.command` starts with `git status`; matcher does NOT fire (inherited blind spot, brainstorm O-2) | unit | **BC6** |
| `git checkout -bfoo` (no space between flag and value) | unusual short-flag attachment | Starts with `git checkout -b`; matches via `startswith` | unit | implicit (BC1 covers `git checkout -b feature/eng-99-foo`; the `startswith` semantics extend to attached-arg variants — no separate fixture needed) |
| Agent narrates `git checkout -b` in a `text` block | model self-narration without invoking the tool | Helper's filter requires `tool_use` with `.name == "Bash"` (line 56); text-block prose is ignored | unit | covered by AS3/AS4 (existing); ENG-66 inherits the same code path |
| Agent issues permitted `git checkout {branch_name}` (no `-b`/`-B`) | normal HEAD recovery per `AGENT_PROMPTS.md:88` | None of the four patterns match | unit | **BC5** (issue AC4) |
| Agent issues `git branch -d <name>` (delete) | branch deletion | Does not match `git branch -m`; permitted | unit | implicit (BC5's loop covers four passthrough patterns; deletion-shape is structurally analogous and would not match `git branch -m`) |
| Agent issues `git checkout -b feat/eng-66-...` (correct branch name, wrong verb) | agent attempts canonical name with forbidden creation verb | Matches `git checkout -b`; rc=23 fires; operator must inspect | unit | implicit (BC1 covers `git checkout -b <any>`; per brainstorm §8 — false-positive friction is acceptable since rule 2 forbids ALL four forms regardless of resulting name) |
| Build agent issues `git checkout -b foo` | both ENG-71 and ENG-66 patterns match | Per D-006 ordering, ENG-71 fires first (rc=26); recovery identical | integration | implicit (BC7 / BC8 do not exercise the `stage="building"` collision case directly, but ENG-71's existing AT-block fixtures pin the rc=26 path; collision behavior is documented in brainstorm §8 / runbook §7 build-stage collision note) |
| QA agent issues `git checkout -B foo` | only ENG-66 cross-stage scan matches | rc=23 fires (ENG-71 is gated to building) | integration | **BC8** (verifies stage=qa fires) |
| Brainstorm agent invokes `git checkout -b foo` (lane-bypass) | hypothetical sub-agent escape on a stage with no `Bash(git:*)` permission | If `tool_use` reaches transcript: ENG-66 cross-stage scan fires; rc=23 | unit | implicit (BC8's stage=qa pattern is the canonical cross-stage proof; brainstorm-stage proof is structurally identical — same code path) |
| Sidecar contains a command with shell metacharacters | hypothetical | `linear.sh::linear_query` JSON-encodes via `jq -cn --arg`; `bin/metrics.sh` follows same path; no shell injection | integration | covered by inherited ENG-43/71/68 path (no new test); brainstorm §8 row + iteration-2 security-P1-1 fold pin the rationale |
| `failure_outcome_for_exit 23` regression | future edit drops the `23)` arm | Routes silently to `unknown-exit-23`; retrospective §1 misses the row | unit | **Test 18** (ENG-66 mirror of Test 15 for ENG-71's exit-26 entry) |
| Pre-commit hook hits the new tests | `bin/dispatch-test.sh`, `bin/classify-failure-test.sh` already in suite | BC1-BC8 + Test 18 add ~120 LOC and ~8 jq forks (each <100 ms); total <1 s in the ~30 s pre-commit budget | smoke | implicit (the pre-commit hook globs `bin/*-test.sh`; new fixtures land automatically) |

## Test Strategy

### Unit (BC1-BC8 in `bin/dispatch-test.sh`, Test 18 in `bin/classify-failure-test.sh`)

- **BC1-BC4** pin each of the four banned patterns matched against
  the helper directly (`assert_no_tool_invocation`); each fixture
  asserts `(rc=1, stdout=<full command>)`. Mirrors AS1-AS6 / CB1-CB6.
- **BC5** pins the canonical-checkout negative (`git checkout
  feat/eng-66-…` → rc=0 for each of the four patterns); satisfies
  issue AC4.
- **BC6** pins the chained-command startswith blind spot (brainstorm
  O-2); mirrors AS12.
- **BC7** is the renderer-integration end-to-end test on
  `stage="implementing"`: heredoc transcript → renderer → rc=23,
  sidecar at `${ISSUE_DIR}/.transcript-violation-implementing`,
  log line. Mirrors CB7 verbatim.
- **BC8** pins the cross-stage no-gate property by firing on
  `stage="qa"`; same shape as BC7 with the qa-named sidecar.
- **Test 18** (in `bin/classify-failure-test.sh`) pins
  `failure_outcome_for_exit 23 ""` returns the typed string
  `branch-creation-forbidden` via the metrics emission; mirrors
  Test 15 verbatim.

### Integration

`bin/run-stage-test.sh` does NOT need a new case for the rc=23
branch in v1: stubbing `dispatch.sh` to return 23 with a sidecar
adds material complexity. The dispatch-test BC7 / BC8 fixtures
cover the helper-and-renderer path end-to-end; the
classify-failure-test Test 18 covers the metric-emission path.
The small, mechanical addition to `run-stage.sh::main`'s exit
ladder (Task 2 Step 2.2) is a copy-paste from the existing rc=22
/ rc=26 / rc=13 branches and needs no new test, on the same
calculus as ENG-43, ENG-71, ENG-68.

### Smoke

`bash bin/dry-run.sh` continues to pass — `dispatch.sh`'s dry-run
path short-circuits before the renderer is invoked, so the
ENG-66 loop is not exercised on dry-run dispatches.

### Adversarial

The brainstorm's iteration-2 review identified one residual P1
that did not block the gate:

- **`-bb` typo edge case** (e.g. `git checkout -bb foo`): would
  match `git checkout -b` via `startswith` and fire rc=23 even
  though `-bb` is not a valid git short flag. Operator sees the
  matched command unambiguously and dismisses as a typo via
  `--action continue` (or escalates if it recurs). Not worth a
  regex word-boundary upgrade for a hypothetical typo class. No
  fixture needed.

The brainstorm also enumerates four "out-of-scope" follow-ups
(O-1 through O-5; see Goal section's "Out of scope" list above);
none are implemented in this plan.

### Pre-commit gate

The pre-commit hook at `.githooks/pre-commit` (per CLAUDE.md
"Pre-commit hook" §) globs `bin/*-test.sh`. BC1-BC8 + Test 18
land under the suite automatically. Total added wall-clock budget
< 1 s inside the ~30 s pre-commit cap.

## Persona review (final tally)

| Persona | Verdict | Notes |
|---|---|---|
| feasibility | PASS | Every code reference verified against current `bin/dispatch.sh` (lines 48-65 helper, 94-247 renderer, 184-193 ENG-43 block, 207-218 ENG-71 block, 219-246 ENG-68 block, 297-309 allowlists), `bin/common.sh:111-136` taxonomy, `bin/run-stage.sh:4-11` header + 759-812 dispatch-rc arms, `bin/dispatch-test.sh:1141-1235 / 1237-1338 / 1340-1482` AS/CB blocks, `bin/classify-failure-test.sh:220-232` Test 15, `bin/agent-prompts-content-test.sh:505-512`, `AGENT_PROMPTS.md:77-88 + :582`, `docs/runbooks/recovery.md:286-345 + :347` §6 / Quick-ref boundary. Every task's `depends_on` is correct: Task 1 has none; Task 2 depends on Task 1's exit-code arm; Task 3 depends on Task 1's renderer block; Task 4 depends on Task 1's taxonomy entry; Task 5 depends on Tasks 1+2 for the documented recovery to be accurate; Task 6 depends on all five. Failure Mode → Test Map binds each row to a concrete test (BC1-BC8 + Test 18) or an inherited code-path (`fromjson? // empty`, `head -1`, JSON-encoding). |
| scope | PASS | Every task and File Structure entry traces to a brainstorm decision (D-001 / D-002 / D-003 / D-004 / D-005 / D-007 / D-008) or to an explicit acceptance criterion (AC1-AC5). The mandatory recovery.md row is the product-P1 fold from brainstorm iteration 2. Out-of-scope items O-1 through O-5 are deferred per brainstorm §12.2. No gold-plating, no `touches` outside File Structure. |
| coherence | PASS | Plan Goal aligns with brainstorm §1 (ENG-43/71/68 plumbing, exit 23, `branch-creation-forbidden`, sidecar, halt-with-skip-until-human-acts). Backend Tasks jointly realise every brainstorm decision: Task 1 = D-001 + D-002 + D-003 + D-005; Task 2 = D-004 + D-005 (header docstring); Task 3 = D-007 (BC1-BC8); Task 4 = D-007 + D-008 (Test 18); Task 5 = product-P1 fold (recovery.md §7); Task 6 = pre-commit gate. Test Strategy covers every Failure Mode row. No frontend tasks (correctly stated as "No FE↔BE API surface"). |
| design | PASS | Crate boundaries unchanged (no harness has crates; bash scripts under `bin/` are the unit). Module responsibilities preserved: `dispatch.sh` owns the renderer + transcript assertions, `common.sh` owns the taxonomy switch, `run-stage.sh` owns dispatch-rc routing, `classify-failure.sh` owns the metric emission. No layering violations, no circular deps. The block-after-block layout in `_render_and_capture_stream` (stage-specific scans first, cross-stage scans grouped at the end) is preserved by inserting ENG-66 between the building-stage block and the existing cross-stage `core.bare` block. |
| product | PASS | The plan delivers exactly what the Linear issue asked for: a transcript-based runtime tripwire that catches the four banned branch-creation forms across all stages, halts with operator-facing diagnostic. AC1-AC5 of the issue are all satisfied (see Goal). The mandatory recovery.md §7 surface ensures the operator-facing surface is documented; the build-stage collision note (D-006) cross-references the inherited rc=26 path so operators don't get confused. The recovery recipe is concrete (`branch -D <wrong>`, then `--action continue`). |
