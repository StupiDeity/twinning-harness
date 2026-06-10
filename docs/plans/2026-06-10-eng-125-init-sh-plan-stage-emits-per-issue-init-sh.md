---
linear: ENG-125
date: 2026-06-10
topic: plan stage emits per-issue init.sh capturing smoke discipline
---

# init.sh: plan stage emits per-issue init.sh — implementation plan

## Anti-anchoring check

- **Problem restatement.** Stage agents rediscover the target's smoke
  discipline (type-check, lint, unit smoke) from scratch every dispatch,
  and may start work on a broken environment without noticing. The user's
  ask is: have one place that captures the per-issue baseline, written by
  the only stage with enough context (plan), so later sub-tickets can
  refuse to start when the baseline is broken. This sub-ticket (ENG-125)
  is FOUNDATION ONLY — emit + validate the file. Other stages reading or
  running it is the next sub-ticket (per Scope OUT).
- **Solution proportionality.** The plan adds one new validator (function
  in `bin/common.sh`), one filesystem detective in `bin/dispatch.sh`
  (mirroring the existing `_assert_progress_md_entry` ENG-106 pattern),
  one `{init_sh_path}` token resolver, and three exit-code entries — all
  matching established sub-ticket scope precedent (cf. ENG-122
  plan-contract validator). No new dirs, no new top-level scripts beyond
  sibling test files. Proportional to the ticket.
- **Escalation.** Neither check fails. Proceed.

## Branch-base freshness

- `git log --oneline HEAD..origin/main` is NON-EMPTY at plan time —
  this feat branch (`feat/eng-125-init-sh-plan-stage-emits-per-issue-init-sh`)
  has drifted substantially behind main (ENG-119, ENG-120, ENG-122, ENG-124,
  ENG-144, ENG-146, ENG-151, ENG-153, ENG-154, ENG-155, ENG-160, ENG-178
  have all merged since HEAD). The drift is CLEAN: every upstream change is
  additive (new validator patterns, new tokens, new detectives) and none
  rewrites a file in the ENG-125 File Structure in a way that invalidates
  the brainstorm. The new ENG-122 plan-contract validator is in fact the
  exact template ENG-125 follows.
- Task 0 (Backend Tasks) rebases the branch onto `origin/main` before any
  other work. All `path:line` references in the Assumption Inventory below
  are read against `origin/main`, knowing line numbers may shift modestly
  under rebase; every Edit boundary is content-anchored to survive that.

## Goal

Every plan-stage dispatch produces a well-formed `$issue_dir/init.sh`
capturing the target's smoke / type-check / lint / test invocations, and
a `dispatch.sh` filesystem detective halts the dispatch with a typed
exit code (39/40/41) when the file is absent, malformed (fails
`bash -n`), or incomplete (missing required shape marker).

## Assumption Inventory

`path:line` references quote `origin/main` (post-Task-0 rebase target).

### Inherited unchanged from origin/main (existing facts that ENG-125 depends on)

- **Stage-gated planning post-stream detective slot exists.**
  `bin/dispatch.sh::_render_and_capture_stream` already runs the
  filesystem progress-md detective for `stage=planning` AFTER the
  tool-use transcript scan:

  ```
  bin/dispatch.sh:346
  if [[ "$stage" == "planning" && -n "$last_result" ]]; then
    if ! _assert_progress_md_entry "$issue_dir" "$violation_file" "$stage"; then
      return 31
    fi
  fi
  ```

  The init.sh detective slots IN AFTER this block (so progress.md halts
  win the race on a dispatch that produces neither). `last_result` gate
  carries over for free — the same SIGKILL-vs-completion discipline
  applies.

- **Exit-code taxonomy lives in `bin/common.sh::failure_outcome_for_exit`.**
  Current contiguous block runs `33|34|35` (plan-contract) and `36|37|38`
  (review-payload). Next free triple is `39|40|41`:

  ```
  bin/common.sh:333-340
  33) printf 'plan-contract-malformed' ;;
  34) printf 'plan-contract-incomplete' ;;
  35) printf 'plan-contract-missing' ;;
  36) printf 'review-payload-malformed' ;;
  37) printf 'review-payload-incomplete' ;;
  38) printf 'review-payload-missing' ;;
  124) printf 'dispatch-timeout' ;;
  ```

  Mirror that shape: `39=init-sh-malformed`, `40=init-sh-incomplete`,
  `41=init-sh-missing`. (Symmetric with plan-contract; matches Acceptance
  Criteria 3's "well-formed + missing + malformed" coverage.)

- **`_assert_progress_md_entry` is the template detective signature** the
  new helper mirrors:

  ```
  bin/dispatch.sh:358-379
  _assert_progress_md_entry() {
    local issue_dir="$1" violation_file="$2" stage="$3"
    ...
    printf '...' > "$violation_file"
    return 31
  ```

  Three positional args, writes diagnostic to `$violation_file`, returns
  0 / typed rc. ENG-125 adds `_assert_init_sh_well_formed` with the
  identical signature.

- **`{progress_md_path}` is the precedent for issue-dir-rooted tokens.**
  The PROMPT_RESOLVERS registry pattern at `bin/render-prompt.sh:41-59`
  binds a name to a resolver function; `_resolve_progress_md_path` at
  `bin/render-prompt.sh:231` returns `$_RENDER_PROGRESS_MD_PATH`, and
  `main()` binds that global at `bin/render-prompt.sh:524`:

  ```
  bin/render-prompt.sh:524
  _RENDER_PROGRESS_MD_PATH="$(progress_md_path "$issue_id")"
  ```

  ENG-125 adds `init_sh_path=_resolve_init_sh_path` to the registry,
  `_resolve_init_sh_path` next to `_resolve_progress_md_path`, and
  binds `_RENDER_INIT_SH_PATH="$(issue_dir "$issue_id")/init.sh"` in
  the same main()-binding block.

- **AGENT_PROMPTS.md plan-section H2 anchor.** The plan agent's body
  begins at `AGENT_PROMPTS.md:368` (`## 2. Plan Agent`) and runs to the
  close-fence near `AGENT_PROMPTS.md:691`. The structured-contract block
  at `AGENT_PROMPTS.md:432-460` (the `Your task:` bullet) is where the
  new `init.sh` emission instruction slots in alongside the existing
  `plan.json` emission instruction. Content anchor: the bullet that
  starts with `- Additionally produce a sibling structured contract at`.

- **Project profile's `## Build & test gates` Test line** at
  `learned-rules/harness/project-profile.md:17` (the long `&&`-chained
  command) is the authoritative gate list. Two new sibling test files
  (see File Structure) join it; per the plan-prompt's add-side
  test-gate-closure sweep, profile MUST appear in File Structure.

- **Implementing + qa tool allowlists are enumerated.** At
  `learned-rules/harness/project-profile.md:31-78` (implementing) and
  `:78-...` (qa), each `bin/*-test.sh` is listed as
  `Bash(bash bin/<name>:*)`. The two new test files must be added
  to BOTH allowlists, alphabetically sorted, per the wildcard-pitfall
  discipline in CLAUDE.md.

- **Plan-stage in-scope path is `docs/plans/`.**
  `bin/run-local-helpers.sh::stage_output_paths:466-468`:

  ```
  planning)
    printf '%s\n' 'docs/plans/'
    ;;
  ```

  This plan writes ONLY to `docs/plans/`. The dispatch this plan
  produces is in-scope (just the plan + JSON). The implement-stage
  dispatch in the next phase will pick up `bin/`, `AGENT_PROMPTS.md`,
  `learned-rules/` writes under the `implementing` allowlist.

- **`issue_dir` resolver.** `bin/common.sh:68-71` resolves
  `$PROJECT_STATE_DIR/$ident/` — used by `progress_md_path` and to be
  used identically by `_resolve_init_sh_path`'s caller. The detective
  receives `$issue_dir` as a positional from
  `_render_and_capture_stream` (not via lookup), so the helper is
  stub-friendly the same way `_assert_progress_md_entry` is.

### Assumed/new (artifacts created by this plan)

- `validate_init_sh` function — assumed/new, lands in `bin/common.sh`
  next to `assert_no_tool_invocation` and friends. Exported via the
  `export -f` line at `bin/common.sh:495`.
- `_assert_init_sh_well_formed` function — assumed/new, lands in
  `bin/dispatch.sh` directly after `_assert_progress_md_entry` (the
  template; see content anchor below).
- `_resolve_init_sh_path` function and `_RENDER_INIT_SH_PATH` global —
  assumed/new, land in `bin/render-prompt.sh` next to
  `_resolve_progress_md_path`.
- `bin/init-sh-validator-test.sh` — assumed/new, sibling test file
  covering `validate_init_sh` cases. Mirrors `bin/plan-schema-test.sh`
  structure.
- `bin/init-sh-validator-adversarial-test.sh` — assumed/new, holds
  adversarial coverage (truncation, hijack markers, embedded `\n` in
  shape marker). Mirrors `bin/plan-schema-adversarial-test.sh`.

## File Structure

New files:
- `bin/init-sh-validator-test.sh` — sibling test for `validate_init_sh` and `_assert_init_sh_well_formed` integration.
- `bin/init-sh-validator-adversarial-test.sh` — adversarial coverage.

Modified files:
- `bin/common.sh` — add `validate_init_sh` function; extend `failure_outcome_for_exit` with codes 39/40/41; extend `export -f` line.
- `bin/dispatch.sh` — add `_assert_init_sh_well_formed` helper; call it from `_render_and_capture_stream` after the existing planning-stage progress-md detective.
- `bin/render-prompt.sh` — add `init_sh_path` to PROMPT_RESOLVERS registry; add `_resolve_init_sh_path` function; bind `_RENDER_INIT_SH_PATH` in `main()`.
- `bin/run-stage.sh` — extend the exit-code-map header comment to document 39/40/41.
- `AGENT_PROMPTS.md` — extend §2 Plan Agent's "Your task" + Completion checklist with the init.sh emission step and shape.
- `learned-rules/harness/project-profile.md` — append `bin/init-sh-validator-test.sh` and `bin/init-sh-validator-adversarial-test.sh` to the `## Build & test gates` Test command AND to the `implementing` and `qa` Tool allowlists.
- `bin/dispatch-test.sh` — add fixtures IS1–IS6 mirroring PG1–PG6 to pin `_assert_init_sh_well_formed` integration.
- `bin/render-prompt-test.sh` — add a `{init_sh_path}` resolver case (mirror the existing `{verdict_review_path}` Case ENG-119).
- `bin/common-test.sh` — add a `validate_init_sh` unit-test block (well-formed / missing-shape-marker / bad-syntax cases).

## API Contract

No new API surface (harness has no FE↔BE — Bash orchestration only).

## Backend Tasks

### Task 0: Rebase onto origin/main

- `depends_on: []`
- `touches: <branch-state-only>`
- [ ] Run `git fetch origin main && git rebase origin/main` from
  `$worktree`. The branch (`feat/eng-125-init-sh-plan-stage-emits-per-issue-init-sh`)
  is many commits behind origin/main; subsequent tasks reference
  `path:line` anchors against origin/main, and a non-rebased branch
  will fail every content-anchor lookup below.
- [ ] After rebase, re-verify each Assumption Inventory `path:line`
  excerpt still matches. Drift is expected for line numbers, but the
  content anchors (function signatures, surrounding section headers,
  the `_assert_progress_md_entry` block) MUST still be present and
  contiguous. If any anchor is missing post-rebase, halt with
  `bash bin/pipeline.sh event ENG-125 verdict halt --reason agent-blocked`
  and post a Linear comment naming the missing anchor.
- [ ] Resolve conflicts (if any) by preferring origin/main for every
  file ENG-125 has not yet authored. The local commits on this branch
  (ENG-106/ENG-109 progress.md work) are already represented upstream
  via merge #115 (commit `0a51c68`) — local-vs-remote should be a no-op
  in practice but verify before continuing.

### Task 1: Allocate exit codes 39/40/41 in failure_outcome_for_exit

- `depends_on: [0]`
- `touches: bin/common.sh::failure_outcome_for_exit, bin/run-stage.sh (header comment)`
- [ ] In `bin/common.sh`, INSIDE the `failure_outcome_for_exit` case
  block, AFTER the line `38) printf 'review-payload-missing' ;;`
  AND BEFORE the line `124) printf 'dispatch-timeout' ;;`, add three
  arms:

  ```
  39) printf 'init-sh-malformed' ;;
  40) printf 'init-sh-incomplete' ;;
  41) printf 'init-sh-missing' ;;
  ```

  Content anchor: the existing `38) printf 'review-payload-missing'`
  arm immediately above the `124)` arm.
- [ ] In `bin/run-stage.sh`, INSIDE the exit-code-map header comment
  block (the lines starting `#             33=plan-contract-malformed`),
  AFTER the `38=review-payload-missing` entry (if present; if absent
  upstream, after `35=plan-contract-missing`) AND BEFORE the
  `124=dispatch-timeout` entry, append three lines:

  ```
  #             39=init-sh-malformed   (init.sh fails bash -n syntax check; ENG-125),
  #             40=init-sh-incomplete  (init.sh present + parses but missing shape marker; ENG-125),
  #             41=init-sh-missing     (no init.sh at $issue_dir/init.sh; ENG-125),
  ```

  Content anchor: the `124=dispatch-timeout` line at the end of the
  numeric block.

### Task 2: Add validate_init_sh to common.sh

- `depends_on: [1]`
- `touches: bin/common.sh::validate_init_sh, bin/common.sh (export -f line)`
- [ ] In `bin/common.sh`, insert a new function `validate_init_sh`
  AFTER `assert_no_write_to_path` (line ~285 origin/main) AND BEFORE
  the `# ─── Exit-code → outcome taxonomy (ENG-10 D-002) ───` block
  header. Content anchor: the `assert_no_write_to_path` function's
  closing `}` and the `# ─── Exit-code` comment header.
- [ ] Function signature:

  ```
  # ENG-125: validate $issue_dir/init.sh shape. Returns:
  #   0  — well-formed (file exists, bash -n clean, all 4 shape markers present)
  #   39 — malformed (file exists but bash -n fails)
  #   40 — incomplete (file exists, syntax-clean, but ≥1 shape marker absent)
  #   41 — missing  (no file at the given path)
  # Caller writes the rc-specific diagnostic to its violation_file;
  # this helper writes diagnostics to STDOUT (caller captures).
  # Shape markers: comments at column 0 of the form `# ─── <gate> ───`
  # where <gate> ∈ {smoke, typecheck, lint, test}.
  validate_init_sh() {
    local path="$1"
    [[ -f "$path" ]] || { printf 'init-sh-missing: %s\n' "$path"; return 41; }
    if ! bash -n "$path" 2>/dev/null; then
      printf 'init-sh-malformed: bash -n failed for %s\n' "$path"
      return 39
    fi
    local gate
    for gate in smoke typecheck lint test; do
      if ! grep -Eq "^# ─── ${gate} ───$" "$path"; then
        printf 'init-sh-incomplete: missing shape marker # ─── %s ───\n' "$gate"
        return 40
      fi
    done
    return 0
  }
  ```
- [ ] Add `validate_init_sh` to the `export -f` line. Content anchor:
  the existing line `export -f issue_dir compute_pipeline_content_hash failure_outcome_for_exit parse_pipeline_marker is_orchestrator_paused set_orchestrator_paused allocate_dispatch_id current_dispatch_id strip_state_preserve_alloc assert_no_tool_invocation progress_md_path assert_no_write_to_path assert_no_tool_with_input_path` — append ` validate_init_sh` after the last name.

### Task 3: Add init_sh_path token to render-prompt.sh

- `depends_on: [0]`
- `touches: bin/render-prompt.sh::PROMPT_RESOLVERS, bin/render-prompt.sh::_resolve_init_sh_path, bin/render-prompt.sh::main`
- [ ] In `bin/render-prompt.sh`, INSIDE the `PROMPT_RESOLVERS` heredoc
  (lines ~41-59), AFTER the line `verdict_review_path=_resolve_verdict_review_path`
  AND BEFORE the closing `'`, add:

  ```
  init_sh_path=_resolve_init_sh_path
  ```

  Content anchor: the `verdict_review_path=_resolve_verdict_review_path`
  line and the closing single-quote of the heredoc.
- [ ] Add the resolver function next to the existing path resolvers.
  Insert AFTER the line `_resolve_verdict_review_path() { printf '%s' "$_RENDER_VERDICT_REVIEW_PATH"; }`
  (line ~232) AND BEFORE the next blank line:

  ```
  _resolve_init_sh_path() { printf '%s' "$_RENDER_INIT_SH_PATH"; }
  ```

  Content anchor: the `_resolve_verdict_review_path` function body.
- [ ] In `main()`, AFTER the line
  `_RENDER_VERDICT_REVIEW_PATH="$(issue_dir "$issue_id")/verdict-review.json"`
  (line ~533) AND BEFORE the `_RENDER_DISPATCH_ID` binding (line ~539),
  bind:

  ```
  # ENG-125: per-issue init.sh path. Composed from issue_dir per
  # common.sh::issue_dir. Resolver returns the absolute path the plan
  # agent must Write to. Plan-stage filesystem detective in dispatch.sh
  # validates shape post-stream.
  _RENDER_INIT_SH_PATH="$(issue_dir "$issue_id")/init.sh"
  ```

  Content anchor: the `_RENDER_VERDICT_REVIEW_PATH=` binding line.

### Task 4: Add _assert_init_sh_well_formed to dispatch.sh

- `depends_on: [2, 3]`
- `touches: bin/dispatch.sh::_assert_init_sh_well_formed, bin/dispatch.sh::_render_and_capture_stream`
- [ ] In `bin/dispatch.sh`, insert the new helper AFTER the body of
  `_assert_progress_md_entry` (its closing `}`, ~line 379) AND BEFORE
  the next comment block `# ENG-48 isolation: platform tools…`.
  Signature mirrors `_assert_progress_md_entry`:

  ```
  # ENG-125 — stage-gated to planning; rc=39/40/41 map to
  # init-sh-{malformed,incomplete,missing} in failure_outcome_for_exit.
  _assert_init_sh_well_formed() {
    local issue_dir="$1" violation_file="$2" stage="$3"
    local init_path="${issue_dir}/init.sh"
    local diag rc=0
    diag="$(validate_init_sh "$init_path")" || rc=$?
    if (( rc != 0 )); then
      printf '%s\n' "$diag" > "$violation_file"
      log "[assert] plan-stage init.sh validate rc=${rc} for ${PIPELINE_DISPATCH_ID-<empty>}: ${diag}"
      return "$rc"
    fi
    return 0
  }
  ```

  Content anchor: the `_assert_progress_md_entry` closing `}` and the
  `# ENG-48 isolation: platform tools` comment that follows.
- [ ] In `_render_and_capture_stream`, INSIDE the planning-stage
  detective slot, AFTER the existing `_assert_progress_md_entry`
  block (`if [[ "$stage" == "planning" && -n "$last_result" ]]; then`
  → `fi`, lines ~346-350) AND BEFORE the closing `}` of
  `_render_and_capture_stream`, add a sibling detective:

  ```
  # ENG-125: plan stage emits $issue_dir/init.sh. Same SIGKILL-vs-result
  # discipline as progress-md detective above.
  if [[ "$stage" == "planning" && -n "$last_result" ]]; then
    local _isf_rc=0
    _assert_init_sh_well_formed "$issue_dir" "$violation_file" "$stage" || _isf_rc=$?
    if (( _isf_rc != 0 )); then
      return "$_isf_rc"
    fi
  fi
  ```

  Content anchor: the closing `fi` of the progress-md detective `if`
  block, and the closing `}` of `_render_and_capture_stream`.

### Task 5: Extend AGENT_PROMPTS.md §2 Plan Agent with init.sh emission

- `depends_on: [3]`
- `touches: AGENT_PROMPTS.md (§2 Plan Agent body)`
- [ ] In `AGENT_PROMPTS.md`, in the §2 Plan Agent fenced block, find
  the `Your task:` bullet starting with
  `- Additionally produce a sibling structured contract at docs/plans/...`
  (the plan-contract block, ~line 433). AFTER the entire `plan-schema-v1`
  fenced sub-block's closing triple-backtick AND its trailing prose
  paragraph (the one ending `bash bin/pipeline.sh decide {issue_id} --action continue`)
  AND BEFORE the next bullet `- Follow the format of existing plans`,
  add a new bullet:

  ~~~markdown
  - Also produce `{init_sh_path}` — a per-issue smoke-discipline script.
    Required shape (column-0 markers; any of the four invocations may be
    a one-liner or a multi-line block, but the marker MUST appear
    verbatim above its block):

        #!/usr/bin/env bash
        # ENG-125: per-issue init.sh — smoke discipline for {issue_id}.
        # Authored by plan stage; consumed by other stages in the next
        # sub-ticket. Must run cleanly under `bash $0` on the target's
        # worktree.
        set -euo pipefail

        # ─── smoke ───
        <smoke command for this target — discover from package.json
         scripts / Makefile / cargo manifest / pyproject.toml>

        # ─── typecheck ───
        <type-check command, or `:` if the stack has none>

        # ─── lint ───
        <lint command, or `:` if the stack has none>

        # ─── test ───
        <unit-test invocation>

    The dispatch detective will halt this dispatch with
    `init-sh-missing` (rc=41), `init-sh-malformed` (rc=39, fails
    `bash -n`), or `init-sh-incomplete` (rc=40, missing a column-0
    `# ─── <gate> ───` marker). Recovery: fix the script (or the
    prompt's emission step), then
    `bash bin/pipeline.sh decide {issue_id} --action continue`.
  ~~~

  Content anchor: the closing prose of the plan-contract bullet (the
  sentence ending with `decide {issue_id} --action continue.`) and the
  next-bullet starter `- Follow the format of existing plans`.
- [ ] Extend the §2 Completion checklist with a new step explicitly
  naming init.sh emission. Find the existing step 4 (the commit step,
  the one starting `4. **Commit artifacts**`). Step 4 commits plan
  doc + JSON; INSERT a new step BEFORE step 5 (the `**Append a
  progress.md entry**` step), renumbering 5→6, 6→7, 7→8, AND
  updating the section header line
  `## Completion checklist (ordered — do every step in order, and do NOT exit before step 6)`
  to read `before step 7`:

  ~~~markdown
  5. **Write `{init_sh_path}`** with the shape documented in §2 above.
     Use `Write` (overwrite-on-every-dispatch — like the stage summary
     file). The file lives in `$issue_dir/`, which is granted to the
     plan agent's sandbox via `--add-dir` (ENG-155 D-001). The
     `bin/dispatch.sh::_assert_init_sh_well_formed` detective halts
     this dispatch with rc=39/40/41 if the file is malformed,
     incomplete, or missing.
  ~~~

  Content anchor: the existing `4. **Commit artifacts**` step heading
  and the `5. **Append a progress.md entry**` step heading.

### Task 6: Update project-profile.md gates and allowlists

- `depends_on: [0]`
- `touches: learned-rules/harness/project-profile.md (## Build & test gates, ## Tool allowlist)`
- [ ] In `learned-rules/harness/project-profile.md`, on the `Test:`
  line (single-line `&&`-chain at line ~17), INSIDE the backtick-quoted
  command, AFTER the existing `bash bin/review-payload-schema-test.sh`
  AND BEFORE the closing backtick + trailing prose, append:

  ```
   && bash bin/init-sh-validator-test.sh && bash bin/init-sh-validator-adversarial-test.sh
  ```

  Content anchor: the existing `bash bin/review-payload-schema-test.sh`
  substring and the closing backtick.
- [ ] In the `## Tool allowlist` section, INSIDE the
  `implementing:` sub-block, insert the two new entries in
  alphabetical position. AFTER
  `- \`Bash(bash bin/install-launchd-test.sh:*)\`` AND BEFORE
  `- \`Bash(bash bin/linear-test.sh:*)\``:

  ```
  - `Bash(bash bin/init-sh-validator-adversarial-test.sh:*)`
  - `Bash(bash bin/init-sh-validator-test.sh:*)`
  ```

  Content anchor: the `install-launchd-test.sh` entry and the
  `linear-test.sh` entry.
- [ ] Repeat the same two insertions in the `qa:` sub-block at the
  same alphabetical position. Content anchor: identical to the
  implementing block (same two surrounding entries).

### Task 7: Add bin/init-sh-validator-test.sh

- `depends_on: [2, 4]`
- `touches: bin/init-sh-validator-test.sh (new)`
- [ ] Create `bin/init-sh-validator-test.sh` as a self-contained
  executable mirroring `bin/plan-schema-test.sh` structure. Sentinel
  pattern at end (sourcing-safe). Source `bin/common.sh` and
  `bin/dispatch.sh` to get both `validate_init_sh` and
  `_assert_init_sh_well_formed`.
- [ ] Test cases (named for traceability with Failure Mode → Test Map):
  - `T_valid_well_formed` — file with shebang, `set -e`, all 4 column-0
    markers + dummy gates → `validate_init_sh` returns 0.
  - `T_missing_file` — `$issue_dir/init.sh` absent → returns 41.
  - `T_malformed_bash_n` — file with unbalanced quote / dangling `{` →
    returns 39.
  - `T_incomplete_missing_smoke` — file missing the `# ─── smoke ───`
    marker → returns 40.
  - `T_incomplete_missing_typecheck` — same, typecheck → returns 40.
  - `T_incomplete_missing_lint` — same, lint → returns 40.
  - `T_incomplete_missing_test` — same, test → returns 40.
  - `T_marker_at_indent_rejected` — marker at column-4 indent rather
    than column-0 → returns 40 (incomplete; pins the regex anchor).
  - `T_detective_well_formed` — `_assert_init_sh_well_formed` with
    a well-formed file → returns 0, no violation_file written.
  - `T_detective_missing` — `_assert_init_sh_well_formed` with no
    file → returns 41, violation_file contains `init-sh-missing:`.
  - `T_detective_malformed` — `_assert_init_sh_well_formed` with
    bad-syntax file → returns 39, violation_file contains
    `init-sh-malformed:`.
  - `T_detective_incomplete` — `_assert_init_sh_well_formed` with
    missing marker → returns 40, violation_file contains
    `init-sh-incomplete:`.

### Task 8: Add bin/init-sh-validator-adversarial-test.sh

- `depends_on: [2, 4]`
- `touches: bin/init-sh-validator-adversarial-test.sh (new)`
- [ ] Create `bin/init-sh-validator-adversarial-test.sh` mirroring
  `bin/plan-schema-adversarial-test.sh`. Cases:
  - `T_adv_hijack_marker_in_quoted_string` — a quoted string containing
    `# ─── smoke ───` inside a heredoc body must NOT count as a real
    marker (matcher requires column-0 anchor with `^…$`).
  - `T_adv_marker_with_trailing_whitespace` — a line `# ─── smoke ───  `
    (trailing spaces) must NOT match. Pins the `$` anchor.
  - `T_adv_zero_byte_file` — empty `init.sh` → returns 40 (bash -n is
    clean on empty input; first missing marker is smoke). The detective
    falls through to the incomplete path, not malformed.
  - `T_adv_bash_n_on_non_bash_shebang` — `#!/bin/sh` shebang with
    bash-only syntax → bash -n still validates; returns 0 if shape
    markers are present. Documents the choice: shape, not portability.
  - `T_adv_marker_inside_comment_block` — marker INSIDE a `<<COMMENT`
    heredoc payload must NOT match (the column-0 anchor and `^…$`
    constraint suffice; heredoc lines inside a `cat <<COMMENT` body
    are NOT at column 0 once indented). Pins the regex.
  - `T_adv_runs_cleanly_under_bash` — write a well-formed init.sh with
    real `:` gates and verify `bash $init_path` exits 0 (Acceptance
    Criteria #2 — "runs cleanly under bash").

### Task 9: Extend bin/dispatch-test.sh with IS1–IS6 fixtures

- `depends_on: [4]`
- `touches: bin/dispatch-test.sh`
- [ ] Append a new fixture block in `bin/dispatch-test.sh` mirroring
  the PG1–PG6 progress-md block (around `--- ENG-106 PG1-PG6: progress.md detective fixtures ---`).
  Content anchor: the block-header
  `printf '\n--- ENG-106 PG1-PG6: progress.md detective fixtures ---\n'`
  and the next major section header.
- [ ] Cases (each invokes `_assert_init_sh_well_formed` directly):
  - `IS1` — well-formed → rc=0, no violation.
  - `IS2` — file missing → rc=41, violation contains `init-sh-missing`.
  - `IS3` — malformed (bash -n fails) → rc=39, violation contains
    `init-sh-malformed`.
  - `IS4` — incomplete (missing `typecheck` marker) → rc=40, violation
    contains `init-sh-incomplete`.
  - `IS5` — issue_dir with NO init.sh AND no progress.md →
    `_assert_progress_md_entry` returns 31 first (caller already
    early-returns on 31). Pins ORDER: progress.md detective runs
    BEFORE init.sh detective per Task 4's insertion point.
  - `IS6` — assert that `bin/dispatch.sh` source contains both
    `_assert_progress_md_entry` AND `_assert_init_sh_well_formed`
    calls inside a planning-gated `if` block (structural pin against
    a future refactor accidentally dropping the planning gate).

### Task 10: Extend bin/render-prompt-test.sh with init_sh_path resolver case

- `depends_on: [3]`
- `touches: bin/render-prompt-test.sh`
- [ ] Append a new test case AFTER the existing Case ENG-119
  (`{verdict_review_path}` resolver pin, ~line 236-248) AND BEFORE
  the next major case header. Content anchor: the existing
  `pass_at "ENG-119: {verdict_review_path} resolves from _RENDER_VERDICT_REVIEW_PATH"`
  line.
- [ ] Case shape (mirror ENG-119):

  ```
  # Case ENG-125: {init_sh_path} token resolves from _RENDER_INIT_SH_PATH.
  _RENDER_INIT_SH_PATH="/tmp/test-state/ENG-125/init.sh"
  out="$(resolve_block_tokens "{init_sh_path}")"
  if [[ "$out" == "/tmp/test-state/ENG-125/init.sh" ]]; then
    pass_at "ENG-125: {init_sh_path} resolves from _RENDER_INIT_SH_PATH"
  else
    fail_at "ENG-125: {init_sh_path} token resolves" \
            "got '$out', expected '/tmp/test-state/ENG-125/init.sh'"
  fi
  ```

### Task 11: Add validate_init_sh unit-test block to bin/common-test.sh

- `depends_on: [2]`
- `touches: bin/common-test.sh`
- [ ] Append a small unit-test block for `validate_init_sh` at end of
  `bin/common-test.sh` (or in a natural spot — content anchor: the
  test file's `main` function). Cases mirror IS1/IS2/IS3/IS4 but at
  the unit-of-validate_init_sh layer, not the detective layer. Pins
  the function's exit-code contract independently of dispatch.sh.

## Frontend Tasks

None — harness has no UI.

## Failure Mode → Test Map

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
|---|---|---|---|---|
| Plan dispatch produces no `init.sh` | Agent forgets emission step | `_assert_init_sh_well_formed` returns 41; dispatch.sh returns 41; classify_failure halts with `init-sh-missing` | unit + integration | `T_missing_file`, `IS2` |
| `init.sh` exists but `bash -n` fails | Agent emits truncated heredoc / unbalanced quote | Returns 39; halt with `init-sh-malformed` | unit + integration | `T_malformed_bash_n`, `IS3` |
| `init.sh` missing one shape marker | Agent emits 3 of 4 gate markers | Returns 40; halt with `init-sh-incomplete` | unit + integration | `T_incomplete_missing_{smoke,typecheck,lint,test}`, `IS4` |
| Marker at non-zero indent | Agent indents marker comments | Returns 40 (column-0 anchor required) | unit | `T_marker_at_indent_rejected` |
| Marker hijack inside quoted string | Agent embeds `# ─── smoke ───` in a heredoc body | Treated as ABSENT; returns 40 | adversarial | `T_adv_marker_inside_comment_block`, `T_adv_hijack_marker_in_quoted_string` |
| Marker with trailing whitespace | Agent emits `# ─── smoke ───   ` | Treated as ABSENT; returns 40 (`$`-anchor) | adversarial | `T_adv_marker_with_trailing_whitespace` |
| Zero-byte `init.sh` | Agent emits an empty file via Write | bash -n clean → marker check fails → returns 40 | adversarial | `T_adv_zero_byte_file` |
| Well-formed `init.sh` runs cleanly under bash | Agent emits the documented shape with `:` placeholder gates | `bash $init_path` exits 0 | adversarial | `T_adv_runs_cleanly_under_bash` |
| Detective fires only on planning stage | Brainstorm/implement/qa dispatch produces no init.sh | No halt — case-arm gates on `stage == planning` | integration | `IS6` (structural pin) |
| Detective ordering: progress.md halts first | Plan dispatch missing BOTH progress.md AND init.sh | rc=31 wins (caller returns on first failed detective) | integration | `IS5` |

## Test Strategy

- **Unit** — `bin/common-test.sh` block (validate_init_sh) and
  `bin/init-sh-validator-test.sh` cover every return-code branch of
  `validate_init_sh` and every diagnostic shape. No filesystem
  isolation beyond a per-case `mktemp -d` scratch directory.
- **Integration** — `bin/dispatch-test.sh` IS1–IS6 cases drive
  `_assert_init_sh_well_formed` directly with synthesised
  `$issue_dir` payloads. Mirrors the PG1–PG6 pattern; uses the same
  source-and-stub fixture style established by `_TEST_STUB_DIR`.
- **Adversarial** — `bin/init-sh-validator-adversarial-test.sh` pins
  the regex anchors (`^…$`, column-0), heredoc-hijack resistance,
  empty-file behavior, and the "runs cleanly under bash" acceptance
  criterion.
- **Smoke** — no new dedicated smoke; the existing
  `bash -n bin/*.sh` profile gate exercises every new bash file.

**Test-gate closure (remove-side).** This plan REMOVES no tokens from
production code (it is purely additive). No remove-side closure sweep
is required.

**Test-gate closure (add-side).** Two new test files
(`bin/init-sh-validator-test.sh`,
`bin/init-sh-validator-adversarial-test.sh`) are added under the
gate-runnable glob `bin/*-test.sh`. `learned-rules/harness/project-profile.md`
IS in File Structure with Task 6 explicitly extending the `## Build & test gates`
Test command line AND both implementing/qa allowlists to include the
new files. Add-side closure satisfied.

## Self-review

Personas dispatched in parallel (compound-engineering:document-review):

- **feasibility — PASS.** Every `path:line` in Assumption Inventory
  verified against origin/main (see git show outputs in transcript).
  Every modified-file entry has a content anchor for its Edit step;
  no bare line numbers stand alone. `validate_init_sh` exit codes
  39/40/41 are unallocated upstream. The `_RENDER_*` resolver pattern
  is mirrored verbatim from the ENG-119 verdict_review precedent.
  Add-side test-gate-closure sweep present (Task 6 covers profile).
  Remove-side sweep N/A (no token removed). Failure Mode rows all
  bind to named tests in Tasks 7/8/9/11.
- **scope — PASS.** Every task and File Structure entry traces to a
  brainstorm decision (parent ENG-36 §Decisions or ENG-125 IN scope).
  No task strays into ENG-126 territory (other stages running init.sh
  is explicitly OUT). The detective slot is foundation-only.
- **coherence — PASS.** Goal restates Acceptance Criteria #1 + #3
  verbatim; Acceptance Criterion #2 ("runs cleanly under bash") is
  bound to test `T_adv_runs_cleanly_under_bash`. Test Strategy covers
  every Failure Mode row.
- **design — PASS.** validate_init_sh lives in common.sh next to
  sibling assert helpers (no layering violation). Detective in
  dispatch.sh next to `_assert_progress_md_entry` (same pattern).
  Resolver in render-prompt.sh next to sibling path resolvers. No
  circular deps; no new module boundaries crossed.
- **product — PASS.** Plan delivers what ENG-125 asked for: plan
  stage emits init.sh, schema validator in common.sh, dispatch.sh
  detective halts on missing/malformed, tests cover well-formed +
  missing + malformed. Sub-ticket scope respected — other stages
  reading/running init.sh stays in ENG-126.

Iteration 1, P0 = 0, gate = pass. Proceeding to commit.
