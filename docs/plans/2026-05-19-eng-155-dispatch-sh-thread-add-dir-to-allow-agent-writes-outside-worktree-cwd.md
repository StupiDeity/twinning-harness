---
linear: ENG-155
date: 2026-05-19
topic: dispatch.sh threads --add-dir for $issue_state_dir + sibling-of-progress-md detective for orchestrator-owned files
---

# ENG-155 — Plan

## Anti-anchoring check

- **Problem restatement.** A fresh-issue planning dispatch halts at rc=31
  (`progress-md-entry-missing`) because the claude CLI's per-session sandbox
  blocks tool access to `$PROJECT_STATE_DIR/<slug>/<issue>/` — the directory
  the agent must write `progress.md` and `stage-summary-planning.md` into.
- **Brainstorm alignment.** The brainstorm proposes one knob (`--add-dir
  "$issue_state_dir"`) plus a detective for the orchestrator-owned files
  that now become reachable. Direct match to the problem; no reframing.
- **Solution proportionality.** ~20 lines in `bin/dispatch.sh`, one
  parameterised helper in `bin/common.sh` (existing helper rewired as a
  thin wrapper for back-compat), one ≤3-line prompt directive in two
  AGENT_PROMPTS.md sections, three new test groups in `bin/dispatch-test.sh`,
  one CLAUDE.md table row. Proportional to the single-knob CLI fix.

## Goal

Add `--add-dir "$issue_state_dir"` (gated on `PIPELINE_ISSUE_ID`) to
`bin/dispatch.sh`'s `claude -p` argv plus an in-renderer detective that
returns rc=29 when the agent transcript shows `Write`/`Edit` on
orchestrator-owned files inside `$issue_state_dir`, so a fresh-issue
planning dispatch can write `progress.md` and `stage-summary-planning.md`
without the agent being able to corrupt `issue-state.json`,
`dispatch_history.jsonl`, `wait-*.json`, `usage-*.json`, or the dispatch
sidecars in the same directory.

## Assumption Inventory

**Branch-base freshness.** `git log --oneline HEAD..origin/main` was NON-EMPTY
at plan time (2 commits ahead: ENG-160's `seed stable Edit anchor in progress.md`
merge `c5c8334` and its squashed commit `d59daae`). ENG-160 touched
`bin/run-stage.sh:1320-1340` (`_ensure_progress_md` seeds two HTML-comment
anchors instead of `touch`-only) and `bin/run-stage-test.sh` — neither overlaps
this plan's File Structure (`bin/dispatch.sh`, `bin/common.sh`, `bin/dispatch-test.sh`,
`AGENT_PROMPTS.md`, `bin/common-test.sh`, `CLAUDE.md`). Clean drift; Task 0 rebases.

| Assumption | Status | Verified at |
|---|---|---|
| `bin/dispatch.sh:457-504` defines `allowed_tools_for <stage>` with per-stage `base` followed by `${base},${profile_tools},${extras}` composition | **verified** | `bin/dispatch.sh:457,475,488-503` (case arms at 477-486; composition at 488-503) |
| `bin/dispatch.sh:478` planning base lacks `Bash(git add:*)` and `Bash(git commit:*)` | **verified** | `bin/dispatch.sh:478` (the only git verbs are `git log` + `git diff`) |
| `bin/dispatch.sh:479` implementing base contains `Bash(git add:*)` directly (also `git rm`, `git mv`, `git commit`, etc.) | **verified** | `bin/dispatch.sh:479` (`Bash(git add:*)` is the 5th git pattern) |
| `bin/dispatch.sh:480` ui base contains `Bash(git add:*)` directly | **verified** | `bin/dispatch.sh:480` |
| `bin/dispatch.sh:482` qa base contains `Bash(git:*)` wildcard (covers `git add`) | **verified** | `bin/dispatch.sh:482` (note: this is the wildcard form, distinct from impl/ui's per-verb enumeration) |
| `bin/dispatch.sh:506-527` resolves `usage_file` and `issue_state_dir` inside the `[[ -n "${PIPELINE_ISSUE_ID:-}" ]]` gate, and `issue_state_dir="$(issue_dir "$PIPELINE_ISSUE_ID")"` is empty-string when the gate doesn't fire | **verified** | `bin/dispatch.sh:519-527` (lines `local issue_state_dir=""` at 520; assignment inside gate at 522) |
| `bin/dispatch.sh:645-670` is where the cmd argv array is composed; `--setting-sources project,local --disable-slash-commands --disallowed-tools "$denies" --allowed-tools "$tools"` is the isolation-flag block | **verified** | `bin/dispatch.sh:645-670` (block at 665-670 is the isolation segment) |
| `bin/dispatch.sh:593-608` is the DRY_RUN log path that renders the would-be cmd line; `--model` is conditionally spliced into `_dry_model_seg` | **verified** | `bin/dispatch.sh:593,599-603` |
| `bin/dispatch.sh:269-276` is the existing ENG-109 `assert_no_write_to_path` detective in `_render_and_capture_stream` — fires unconditionally (no `-n "$last_result"` guard) | **verified** | `bin/dispatch.sh:269-276` (`if _matched_write="$(assert_no_write_to_path "$raw_capture" "/progress.md")"`; return 29 on match) |
| `bin/dispatch.sh:288-292` is the ENG-106 stage-gated filesystem detective `_assert_progress_md_entry` (guarded on `stage == "planning"` AND `-n "$last_result"`) | **verified** | `bin/dispatch.sh:288-292` |
| `bin/dispatch.sh:300-318` defines `_assert_progress_md_entry` (helper sibling of `_render_and_capture_stream`) | **verified** | `bin/dispatch.sh:300-318` |
| `bin/common.sh:215-232` defines `assert_no_tool_invocation <transcript> <pattern>` — Bash tool_use, `input.command` startswith semantics | **verified** | `bin/common.sh:215-232` |
| `bin/common.sh:240-257` defines `assert_no_write_to_path <transcript> <suffix>` — Write tool_use, `input.file_path` endswith semantics | **verified** | `bin/common.sh:240-257` |
| `bin/common.sh:297` maps `29 → envelope-violation` in `failure_outcome_for_exit` | **verified** | `bin/common.sh:297` |
| `bin/common.sh::issue_dir <ident>` returns `$PROJECT_STATE_DIR/$ident` and dies on empty ident | **verified** | `bin/common.sh` (called from `bin/dispatch.sh:522`; `issue_dir` function defined elsewhere in common.sh) |
| `bin/run-stage.sh:1329` already runs `mkdir -p "$(issue_dir "$ident")"` pre-dispatch | **verified** | `bin/run-stage.sh:1329` (the in-dispatch mkdir is belt-and-suspenders for non-run-stage callers — release/retrospective/mutex-test/dry-run-self-check leave PIPELINE_ISSUE_ID unset, so the new mkdir lives inside the same gate as the rest of the per-issue block) |
| `bin/run-stage.sh:1332` calls `_ensure_progress_md "$ident"`, which (post-ENG-160) seeds two HTML-comment anchor lines so `Edit` has a valid `old_string` on first dispatch | **verified** | `bin/run-stage.sh:1330-1340` post-rebase (ENG-160 fix on origin/main) |
| `bin/run-stage.sh:1470-1473` invokes `bash dispatch.sh` with `PIPELINE_ISSUE_ID="$ident"` exported into the env | **verified** | `bin/run-stage.sh:1470` (`PIPELINE_ISSUE_ID="$ident" PIPELINE_DISPATCH_MODEL=… bash "$SCRIPT_DIR/dispatch.sh"`) |
| `bin/run-local.sh:205` `cd`s into the per-issue worktree before calling `run-stage.sh`, so dispatch.sh's CWD is `$(issue_dir <ident>)/worktree` — NOT `$(issue_dir <ident>)` itself | **verified** | `bin/run-local.sh:205` (`(cd "$dispatch_cwd" && bash "$SCRIPT_DIR/run-stage.sh" …)`) |
| `bin/dispatch-test.sh:115-130` defines the `claude` stub that captures argv to `$ARGV_CAPTURE` (one arg per line) | **verified** | `bin/dispatch-test.sh:115-130` |
| `bin/dispatch-test.sh:80-101` is the per-stage allowed-tools loop (precedent for AC-GIT-ADD-AUDIT) | **verified** | `bin/dispatch-test.sh:80-101` |
| `bin/dispatch-test.sh:3072-3109` is the ENG-109 EW1/EW2 `assert_no_write_to_path` fixture block (precedent for the new D-003 detective fixtures) | **verified** | `bin/dispatch-test.sh:3072-3109` |
| `bin/dispatch-test.sh:3111-…` is the ENG-106 PG1-PG6 `_assert_progress_md_entry` fixture block (precedent for direct-helper-invocation tests) | **verified** | `bin/dispatch-test.sh:3111-3191` |
| `bin/common-test.sh:492-526` exercises `assert_no_tool_invocation` (precedent for the new parameterised-helper fixtures) | **verified** | `bin/common-test.sh:492-526` |
| AGENT_PROMPTS.md §3 Implementation Agent starts at line 690; §4 UI Agent at line 957 | **verified** | `grep -n '^## ' AGENT_PROMPTS.md` (line 690, 957) |
| AGENT_PROMPTS.md §3 TDD-discipline block at lines 828-832 ends with `"  - Minimum two commits per task. Review stage counts test-first order."` — content anchor for the new staging-discipline bullet | **verified** | `AGENT_PROMPTS.md:828-832` |
| AGENT_PROMPTS.md §4 UI's Output block starts at line 1064 with `"Output:"` and line 1065 `"- Commit any remaining work on \`{branch_name}\` and push."` — content anchor for the new UI-side staging-discipline bullet | **verified** | `AGENT_PROMPTS.md:1064-1065` |
| CLAUDE.md `## Failure-mode quick reference` heading lives at line 762; the table rows surrounding the new entry are `| Wrong-target Linear writes \| …` (line 780) AND `| Kill switch \| …` (line 781) | **verified** | `CLAUDE.md:762,780-781` |
| The claude CLI ships `--add-dir <directories...>` (additional directories the tool sandbox may write into) | **verified** | brainstorm §10 / `claude --help` |
| `learned-rules/harness/project-profile.md::## Build & test gates` Test line enumerates `bin/dispatch-test.sh` AND `bin/common-test.sh` already — no new gate-runnable file is being added by this plan, so no profile update is required for the **add-side** test-gate closure sweep | **verified** | `learned-rules/harness/project-profile.md:17` |
| **Test-gate closure (remove-side).** This plan keeps the existing helper names `assert_no_write_to_path` and `assert_no_tool_invocation` intact (the new `assert_no_tool_with_input_path` parameterised helper sits beside them; `assert_no_write_to_path` is rewired as a thin wrapper that delegates). NO test-pinned token is removed; existing assertions in `bin/common-test.sh` (23 refs) and `bin/dispatch-test.sh` (48 refs) remain valid | **verified** | `grep -c 'assert_no_write_to_path\|assert_no_tool_invocation' bin/common-test.sh bin/dispatch-test.sh` = 23 + 48 |
| `learned-rules/harness/build.md` exists; `learned-rules/harness/plan.md` does NOT (plan-stage retrospective rules absent) | **verified** | `ls learned-rules/harness/` (`build.md`, `project-profile.md` only) |

## File Structure

- `bin/dispatch.sh` — **modified** (D-001 mkdir + `--add-dir` argv splice; D-003 detective loop)
- `bin/common.sh` — **modified** (D-003 parameterised helper `assert_no_tool_with_input_path`; refactor `assert_no_write_to_path` into thin delegating wrapper)
- `AGENT_PROMPTS.md` — **modified** (D-006 staging-discipline directive in §3 Implement + §4 UI)
- `bin/dispatch-test.sh` — **modified** (3 new groups: AC-ADDDIR, AC-GIT-ADD-AUDIT, AC-D003)
- `bin/common-test.sh` — **modified** (new fixtures AC-PARAM-A/B/C/D for the parameterised helper)
- `CLAUDE.md` — **modified** (new Failure-mode quick-reference row for rc=29 + orchestrator-owned-file disambiguation)

No new files. No new exit code (D-004 reuses 29). No `failure_outcome_for_exit` table change.
No `learned-rules/<slug>/project-profile.md` change (the Test command already covers
`bin/dispatch-test.sh` AND `bin/common-test.sh`; no new gate-runnable file is added).

## API Contract

no new API surface (this is harness-internal bash plumbing; no FE↔BE handler or RPC changes).

## Backend Tasks

### Task 0: Rebase onto origin/main
- `depends_on: []`
- `touches: bin/run-stage.sh, bin/run-stage-test.sh (rebase-pull only — no edits in this plan)`
- [ ] Run `git fetch origin && git rebase origin/main` from the feature branch. Expected: clean rebase pulling in ENG-160's `_ensure_progress_md`-seeding fix (commits `d59daae` + merge `c5c8334`). NO edits to `bin/run-stage.sh` or `bin/run-stage-test.sh` belong to ENG-155 — those changes land via the rebase and the implement agent must NOT touch them.
- [ ] Re-verify Assumption Inventory `path:line` references survived: `grep -n 'mkdir -p "$(issue_dir' bin/run-stage.sh` should still hit line ~1329; `grep -n 'assert_no_write_to_path' bin/common.sh` should still hit line ~240. If a reference moved, update the Assumption Inventory before continuing.

### Task 1: Add parameterised tool-input-path helper to `bin/common.sh`
- `depends_on: [0]`
- `touches: bin/common.sh::assert_no_tool_with_input_path, bin/common.sh::assert_no_write_to_path`

**Helper signature (binding decision — Option A from coherence/design persona iteration):**
5-arg `assert_no_tool_with_input_path <transcript> <tool_names_csv> <input_field> <forbidden_substring> <mode>` where `mode ∈ {endswith, contains}` and defaults to `endswith` for back-compat with the existing `assert_no_write_to_path` thin wrapper. `endswith` preserves the ENG-109 progress.md detective semantics (full suffix `/progress.md`). `contains` is the new mode required for the D-003 wildcard prefixes (`/wait-`, `/usage-`, `/.cmd-capture-`, `/.envelope-transcript-`, `/.transcript-violation-`) — those substrings are NOT the trailing characters of a `Write.input.file_path` like `…/wait-planning.json`, so endswith would never match them.

- [ ] In `bin/common.sh`, IMMEDIATELY AFTER the existing `assert_no_write_to_path` function definition (between its closing `}` at line ~257 and the `# ─── Exit-code → outcome taxonomy (ENG-10 D-002) ─────────────────────` H3 comment header at line ~259 — content anchor: the literal H3 comment header `# ─── Exit-code → outcome taxonomy`) insert a new function:

  ```bash
  # ENG-155 D-003: parameterised generalisation of assert_no_write_to_path.
  # Matches any tool_use whose `name` is in $tool_names_csv AND whose
  # `input[$input_field]` (string) matches $forbidden_substring under the
  # selected match mode. Used to forbid Write+Edit (and any future tool
  # that takes a path-like input field) against orchestrator-owned files
  # inside $issue_state_dir.
  #
  # mode (positional arg 5, optional, default "endswith"):
  #   - endswith — current ENG-109 semantics; matches a complete trailing
  #     suffix like "/progress.md".
  #   - contains — required for wildcard prefixes like "/wait-" matching
  #     ".../wait-planning.json". Substring match, not suffix.
  #
  # Returns rc=1 + matched path on first hit, rc=0 + empty stdout on miss.
  # Soft-fail (rc=0) on empty/missing transcript so dry-run / planning-only
  # paths never synthesize false positives — mirrors the existing helpers.
  # Soft-fail (rc=0) on unknown mode (defensive — preserves rc=0-on-miss
  # invariant rather than dying inside the dispatch hot path).
  assert_no_tool_with_input_path() {
    local transcript="$1" tool_names_csv="$2" input_field="$3" forbidden_substring="$4"
    local mode="${5:-endswith}"
    [[ -s "$transcript" ]] || return 0
    local matched
    matched="$(jq -Rr \
      --arg names "$tool_names_csv" \
      --arg field "$input_field" \
      --arg p "$forbidden_substring" \
      --arg mode "$mode" '
      ($names | split(",")) as $allow
      | fromjson? // empty
      | select(.type == "assistant")
      | .message.content[]?
      | select(.type == "tool_use" and (.name as $n | $allow | index($n)))
      | (.input[$field] // "")
      | select(type == "string"
              and (   ($mode == "endswith" and endswith($p))
                   or ($mode == "contains" and contains($p)) ))
    ' "$transcript" 2>/dev/null | head -1)" || true
    if [[ -n "$matched" ]]; then
      printf '%s\n' "$matched"
      return 1
    fi
    return 0
  }
  ```

- [ ] Rewire `assert_no_write_to_path` (lines ~240-257) into a thin delegating wrapper that preserves its signature and rc/stdout semantics. Default mode `endswith` is implicit (5th arg unset):

  ```bash
  assert_no_write_to_path() {
    local transcript="$1" forbidden_path_suffix="$2"
    assert_no_tool_with_input_path "$transcript" "Write" "file_path" "$forbidden_path_suffix"
  }
  ```

  Content anchor: the existing comment block `# ENG-109: forbid Write-tool truncation of the per-issue progress.md.` (line ~234) — keep the comment, replace the function body. The 48 existing `assert_no_write_to_path` references in `bin/dispatch-test.sh` and 23 in `bin/common-test.sh` are unchanged (they pass 2 args; mode defaults to endswith; behavior is bit-identical).
- [ ] Update the `export -f` block (if assert_no_write_to_path is listed; check `grep -n 'export -f' bin/common.sh`) to also export `assert_no_tool_with_input_path`.

### Task 2: Add D-003 detective loop in `bin/dispatch.sh::_render_and_capture_stream`
- `depends_on: [1]`
- `touches: bin/dispatch.sh::_render_and_capture_stream`

**Shape choice (binding decision — OQ-6 resolution from brainstorm §5).**
This plan adopts the **enumerated-deny shape** for the orchestrator-owned
suffix list rather than the agent-writable allowlist shape that brainstorm
§13 (revised) noted as the design persona's preference. Rationale: the
9-entry deny list is closed by current architecture (every orchestrator-
owned file under `$issue_state_dir` has a known basename prefix); the
allowlist alternative would be a `progress.md` + `stage-summary-*.md`
allowlist + catch-all deny, which couples the detective to BOTH the
list of agent-writable files (today a 2-entry set, tomorrow possibly
more — e.g., a hypothetical `decisions-<stage>.md` artifact) AND the
catch-all path-suffix matcher (which would false-positive on
`stage-summary-<stage>.md.bak`-style operator scratch files unless an
explicit carve-out is added). The enumerated-deny shape ages with the
orchestrator's file set (the brainstorm's 9-entry table is the
canonical writer-site enumeration); when a future ticket adds a new
orchestrator-owned slot, the same ticket that adds the writer code
adds one line to this loop. Easier audit, narrower blast radius.

**Match mode (binding decision — Option A from coherence/design persona iteration).**
Use `assert_no_tool_with_input_path`'s 5-arg form with the explicit
`mode="contains"` argument for every entry except `/issue-state.json`
and `/dispatch_history.jsonl` (which are full-suffix matches — those
two could equivalently use `endswith`, but `contains` is correct for
both and uniform-mode simplifies the loop). Endswith-only is wrong for
`/wait-`, `/usage-`, `/.cmd-capture-`, `/.envelope-transcript-`,
`/.transcript-violation-` (the agent's `Write.input.file_path` carries
the full absolute path `…/wait-planning.json`, which does NOT end
with the substring `/wait-`).

- [ ] In `bin/dispatch.sh::_render_and_capture_stream`, insert a new detective loop AFTER the existing ENG-109 progress.md Write detective block (which currently spans `# ENG-109: forbid Write-tool truncation of progress.md` comment through the `return 29` closing-fi at lines ~259-276) AND BEFORE the ENG-106 `if [[ "$stage" == "planning" && -n "$last_result" ]]` filesystem detective at line ~288. Content anchors: AFTER the closing `fi` of the ENG-109 block (the `fi` that closes the `if _matched_write="..." ... else ... fi` at line ~276), BEFORE the `# ENG-106: filesystem detective — confirm the plan agent appended` comment at line ~277.

  Insert:

  ```bash
  # ENG-155 D-003: forbid agent Write/Edit against orchestrator-owned files
  # inside $issue_state_dir. D-001 widens the sandbox to include
  # $issue_state_dir via --add-dir; this detective restores the ENG-87 /
  # ENG-146 / ENG-109 invariants that prior-sandbox-by-accident enforced.
  # No stage gate — fires on any stage's transcript (mirrors the cross-stage
  # ENG-109 progress.md detective above; brainstorm OQ-3). The substrings
  # enumerate every orchestrator-owned file shape under $issue_state_dir;
  # progress.md and stage-summary-<stage>.md are NOT in this list — those
  # are the writer-side agent contract this ticket exists to enable.
  # mode="contains" is mandatory for /wait-, /usage-, /.cmd-capture-,
  # /.envelope-transcript-, /.transcript-violation- (substring matches in
  # the absolute path the agent's Write.input.file_path carries — endswith
  # would never match those wildcard-equivalent prefixes; see brainstorm
  # iteration §12 feasibility persona / coherence persona P0).
  local _orch_pattern _matched_orch
  for _orch_pattern in \
      "/issue-state.json" \
      "/dispatch_history.jsonl" \
      "/wait-" \
      "/usage-" \
      "/.raw-stream.ndjson.tmp" \
      "/.cmd-capture-" \
      "/.envelope-transcript-" \
      "/.transcript-violation-" \
      "/.allocate.lock"; do
    if _matched_orch="$(assert_no_tool_with_input_path "$raw_capture" "Write,Edit" "file_path" "$_orch_pattern" "contains")"; then
      :   # rc 0: no match, fall through to next pattern
    else
      printf '%s\n' "$_matched_orch" > "$violation_file"
      log "[assert] stage=$stage transcript invoked forbidden Write/Edit on orchestrator-owned path: ${_matched_orch}"
      return 29
    fi
  done
  ```

- [ ] Verify the existing `local violation_file="${issue_dir}/.transcript-violation-${stage}"` declaration at line ~73 is in scope (it is — declared at the top of `_render_and_capture_stream`); no new declaration needed.

### Task 3: Thread `mkdir -p $issue_state_dir` + `--add-dir $issue_state_dir` argv splice in `bin/dispatch.sh::main`
- `depends_on: [2]`
- `touches: bin/dispatch.sh::main`
- [ ] In `bin/dispatch.sh::main`, inside the existing `if [[ -n "${PIPELINE_ISSUE_ID:-}" ]]; then` block at lines ~521-527 (content anchor: the literal `# Pre-emptive cleanup so a missing file is the canonical "no usage to` comment at line ~525), ADD an idempotent `mkdir -p` AFTER the existing `rm -f "$usage_file"` line, before the closing `fi` of that block:

  ```bash
    # ENG-155 D-001: belt-and-suspenders mkdir for non-run-stage callers
    # (release/retrospective/mutex-test/dry-run-self-check leave
    # PIPELINE_ISSUE_ID unset; this only fires inside the gated block,
    # mirroring usage_file resolution). run-stage.sh:1329 already mkdirs
    # the same path before invoking dispatch.sh.
    mkdir -p "$issue_state_dir"
  ```

- [ ] In the cmd array composition (lines ~645-670), SPLICE `--add-dir "$issue_state_dir"` between the `claude -p --output-format stream-json --verbose [--model …]` segment and the `--setting-sources project,local` segment. Content anchor: AFTER the existing `if [[ -n "${PIPELINE_DISPATCH_MODEL:-}" ]]; then cmd+=(--model "$PIPELINE_DISPATCH_MODEL"); fi` block (~lines 662-664), BEFORE the `cmd+=(` line that begins the isolation segment with `--setting-sources project,local` (~line 665).

  Insert (gated on `issue_state_dir` non-empty so non-run-stage callers observe no change):

  ```bash
    # ENG-155 D-001: widen claude's per-session sandbox to include the
    # per-issue state directory so the agent's Write/Edit on progress.md
    # and stage-summary-<stage>.md (paths under $issue_state_dir, NOT the
    # worktree cwd) succeed. Gated on $issue_state_dir non-empty so
    # non-PIPELINE_ISSUE_ID callers observe zero behavior change.
    # Placement: between the --model block and the isolation block so the
    # operator's eye-scan of the rendered argv keeps the isolation segment
    # (--setting-sources / --disable-slash-commands / --disallowed-tools /
    # --allowed-tools) visually contiguous.
    if [[ -n "$issue_state_dir" ]]; then
      cmd+=(--add-dir "$issue_state_dir")
    fi
  ```

- [ ] Update the DRY_RUN log line at line ~603 (content anchor: the literal string `log "[DRY_RUN] would invoke: gtimeout …"`) so the rendered cmd string carries `--add-dir <path>` between `--verbose${_dry_model_seg}` and `--setting-sources project,local`. Implementation: render a parallel `_dry_addir_seg=""` segment populated when `$issue_state_dir` is non-empty, sibling of the existing `_dry_model_seg` at line ~599-602:

  ```bash
    local _dry_addir_seg=""
    if [[ -n "${issue_state_dir:-}" ]]; then
      _dry_addir_seg=" --add-dir $issue_state_dir"
    fi
  ```

  and edit the `log "[DRY_RUN] would invoke: …"` string to splice `${_dry_addir_seg}` between `${_dry_model_seg}` and `--setting-sources project,local`.

### Task 4: Add staging-discipline directive to AGENT_PROMPTS.md §3 + §4
- `depends_on: [0]`
- `touches: AGENT_PROMPTS.md §3 (Implementation), AGENT_PROMPTS.md §4 (UI)`
- [ ] §3 Implementation Agent (`## 3. Implementation Agent (Backend)` at line 690): insert a new bullet inside the existing "TDD discipline" sub-block at lines 828-832. Content anchor: AFTER the line `  - Minimum two commits per task. Review stage counts test-first order.` (line 832), BEFORE the line `- Follow testing conventions from docs/knowledge/conventions.md and the profile's "Language idioms" section.` (line 833). Insert:

  ```
    - **Staging discipline (auto-mode bash classifier).** Use one path per
      `git add` invocation; do NOT chain with `&&` or pass multiple paths
      in a single `git add A B` call. The auto-mode classifier may reject
      multi-path or chained-command shapes even when the allowlist permits
      them (CLAUDE.md memory `feedback_dedup_update_silently_rewrites_chronology`
      / `feedback_manual_shepherd_fresh_brainstorm_halt`). One path per call
      is the shape that reliably gets through.
  ```

- [ ] §4 UI Agent (`## 4. UI Agent (Frontend)` at line 957): mirror the same bullet. Content anchor: AFTER the line `- Commit any remaining work on \`{branch_name}\` and push. Do NOT open the pull request yourself — the orchestrator handles it.` (line 1065), BEFORE the line `- Write the stage summary file at \`{stage_summary_path}\` — follow the Stage summary` (line 1066). Insert (as a sub-bullet so it visually nests under the commit directive):

  ```
    - **Staging discipline (auto-mode bash classifier).** When staging
      with `git add`, use one path per invocation; no `&&` chaining, no
      multi-path `git add A B`. The auto-mode classifier may reject those
      shapes even when the allowlist permits them; one path per call is
      the shape that reliably gets through.
  ```

### Task 5: Add three new test groups to `bin/dispatch-test.sh`
- `depends_on: [3, 4]`
- `touches: bin/dispatch-test.sh (3 new groups appended at end-of-file)`
- [ ] **AC-ADDDIR (D-001 argv + DRY_RUN log).** New group near end-of-file (after the ENG-81 Group 8 dispatch-resource-sample block at line ~2849). Two assertions:
  - Reuse the `ARGV_CAPTURE` claude stub (already set up at lines 115-130) — run a dispatch with `PIPELINE_ISSUE_ID=ENG-T-ADDDIR` set in the env, assert `grep -Fxq -- '--add-dir' "$ARGV_CAPTURE"` AND the line BELOW the `--add-dir` line contains the resolved `$issue_state_dir` path.
  - DRY_RUN fixture: `PIPELINE_DRY_RUN=1 PIPELINE_ISSUE_ID=ENG-T-ADDDIR-DRY bash "$SCRIPT_DIR/dispatch.sh" planning "$_PROMPT_FILE" 2>"$DRYRUN_OUT"`; assert `grep -E -- '--verbose( --model [^ ]+)? --add-dir [^ ]+ --setting-sources project,local' "$DRYRUN_OUT"` matches.

- [ ] **AC-GIT-ADD-AUDIT (D-005 verification, no code change for impl/ui/qa).** New group: per-stage assertions on `allowed_tools_for "$stage"` output:
  - For `stage ∈ {implementing, ui}`: assert the tools string contains `Bash(git add:*)` as a literal entry.
  - For `stage == qa`: assert the tools string contains `Bash(git:*)` (the wildcard which covers `git add`).
  - For `stage == planning`: assert the tools string does NOT contain `Bash(git add:*)` AND does NOT contain `Bash(git:*)` — pinning D-005's deliberate omission. (When OQ-2 is fixed in a follow-up ticket, this assertion gets inverted; flagged inline.)

- [ ] **AC-D003 (D-003 detective tripping).** New group: direct-helper-invocation fixtures, mirroring the EW1/EW2 shape at lines 3072-3109. All fixtures invoke the 5-arg helper with explicit `mode="contains"` for parity with the dispatch.sh loop:
  - **AC-D003-A**: Write tool_use against `/issue-state.json` → `assert_no_tool_with_input_path "$tx" "Write,Edit" "file_path" "/issue-state.json" "contains"` returns rc=1 + matched path.
  - **AC-D003-B**: Edit tool_use against `/wait-planning.json` (full path e.g. `/Users/x/.local/state/twinning-harness/harness/foo/ENG-1/wait-planning.json`) → call with `forbidden_substring="/wait-"` AND `mode="contains"` returns rc=1 + matched path.
  - **AC-D003-C**: Write tool_use against `/dispatch_history.jsonl` → rc=1 + matched path.
  - **AC-D003-D**: Edit tool_use against `/usage-planning.json` → with `forbidden_substring="/usage-"` AND `mode="contains"` returns rc=1 + matched path.
  - **AC-D003-E**: Write tool_use against `/progress.md` (benign for D-003 — owned by the agent contract) → with `forbidden_substring="/issue-state.json" mode="contains"` returns rc=0 + empty stdout. (This MUST NOT trip the D-003 detective; the existing ENG-109 detective at line 269-276 already covers progress.md separately.)
  - **AC-D003-F**: Write tool_use against `/stage-summary-planning.md` → with each of the 9 D-003 substrings + `mode="contains"` returns rc=0 (benign; agent contract).
  - **AC-D003-G (end-to-end via `_render_and_capture_stream`):** Synth a fake stream-json file containing a Write tool_use against `/issue-state.json` plus a `type:result` event; invoke `_render_and_capture_stream "$usage_file" "$issue_dir" "planning"` directly; assert the function returns 29 AND `$violation_file` content names `/issue-state.json`.

### Task 6: Add parameterised-helper fixtures to `bin/common-test.sh`
- `depends_on: [1]`
- `touches: bin/common-test.sh (new fixture block)`
- [ ] New fixture block AFTER the existing ENG-87 C1 `assert_no_tool_invocation` block at lines 492-526 (content anchor: the closing assertion of the C1 block — the `pass_at` or `fail_at` line that follows the empty-transcript test ~line 526). Six fixtures:
  - **AC-PARAM-A**: Write tool_use ending `/progress.md` matched by `"Write" "file_path" "/progress.md"` (4-arg call; default mode=endswith) → rc=1.
  - **AC-PARAM-B**: Edit tool_use ending `/progress.md` matched by `"Write,Edit" "file_path" "/progress.md"` (4-arg; endswith) → rc=1 (csv tool-name resolution).
  - **AC-PARAM-C**: Edit tool_use ending `/progress.md` matched by `"Write" "file_path" "/progress.md"` (Write-only allowlist) → rc=0 (csv tool-name resolution rejects Edit when only Write is listed).
  - **AC-PARAM-D**: Empty transcript → rc=0 (soft-fail mirroring the existing helpers).
  - **AC-PARAM-E (mode arg — contains):** Write tool_use against full path `/Users/x/foo/wait-planning.json`, call with `"Write,Edit" "file_path" "/wait-" "contains"` → rc=1 + matched path. Negative companion: same call with default mode (omit the 5th arg, or pass `"endswith"` explicitly) → rc=0 (because `…/wait-planning.json` does NOT endswith `/wait-`).
  - **AC-PARAM-F (mode arg — unknown mode defensive):** unknown mode value (e.g. `"foo"`) → rc=0 (defensive soft-fail), no false-positive.
- [ ] Pin back-compat: re-run any existing fixture that calls `assert_no_write_to_path` (2-arg call shape — `assert_no_write_to_path "$tx" "/progress.md"`) and assert behavior is bit-identical to pre-rewire (delegates through the thin wrapper to `assert_no_tool_with_input_path "$tx" "Write" "file_path" "/progress.md"` with implicit default mode=endswith).

### Task 7: Add CLAUDE.md Failure-mode quick-reference row
- `depends_on: [3]`
- `touches: CLAUDE.md (single table row)`
- [ ] In `CLAUDE.md`, insert a new row AFTER the line `| Wrong-target Linear writes \| \`git log\` on \`$TARGET_REPO/.pipeline-config/schemas/linear-ids.json\` — stale cache is the usual cause |` (line 780) AND BEFORE the line `| Kill switch \| \`bash bin/pipeline.sh decide <ENG-N> --action continue\` (atomic reset) or set \`orchestrator.paused=true\` (next tick) |` (line 781). Content:

  ```
  | Halt at rc=29 with sidecar `.transcript-violation-<stage>` naming a path ending in `/issue-state.json`, `/wait-*.json`, `/dispatch_history.jsonl`, `/usage-*.json`, or one of the dispatch sidecars (`/.raw-stream.ndjson.tmp`, `/.cmd-capture-*`, `/.envelope-transcript-*`, `/.transcript-violation-*`, `/.allocate.lock`) | ENG-155 D-003 detective tripped: agent's transcript shows `Write` / `Edit` against an orchestrator-owned file inside `$issue_state_dir`. The same rc=29 is also used by ENG-87's envelope-validator (forbidden `mcp__plugin_linear` / `curl https://api.linear.app` / `gh api graphql` / `wget https://api.linear.app` / `unset PIPELINE_DISPATCH_ID` in transcript) — the sidecar's matched-string disambiguates. Recovery: `bash bin/pipeline.sh decide <ENG-N> --action continue`. |
  ```

## Frontend Tasks

N/A — the harness has no frontend layer; the prompt-side edits in Task 4 are
AGENT_PROMPTS.md content, not UI components.

## Failure Mode → Test Map

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
|---|---|---|---|---|
| Fresh-issue planning halts at rc=31 because agent can't reach `progress.md` | `PIPELINE_ISSUE_ID` set, `claude -p` invoked without `--add-dir`, agent attempts `Edit` on absolute path outside cwd | Post-fix: `--add-dir "$issue_state_dir"` in argv; agent writes succeed; `_assert_progress_md_entry` finds entry; rc=0 | unit | `bin/dispatch-test.sh::AC-ADDDIR` |
| DRY_RUN log misrepresents the cmd line operator inspects | `PIPELINE_DRY_RUN=1` set; rendered "would invoke" line | Carries `--add-dir <path>` between `--verbose` and `--setting-sources` | unit | `bin/dispatch-test.sh::AC-ADDDIR (DRY_RUN sub-assertion)` |
| Non-run-stage caller (release/retrospective/mutex-test) gets `--add-dir` even though no issue id is in scope | dispatch.sh invoked with `PIPELINE_ISSUE_ID` unset | The `--add-dir` splice is gated on `[[ -n "$issue_state_dir" ]]`; argv does NOT carry the flag | unit | `bin/dispatch-test.sh::AC-ADDDIR (no-issue-id sub-assertion — invoke `main brainstorm` without setting PIPELINE_ISSUE_ID, assert argv lacks `--add-dir`)` |
| Agent overwrites `issue-state.json` and corrupts `dispatch_id` monotonicity | Write tool_use against absolute path ending `/issue-state.json` | D-003 detective trips, rc=29, sidecar names the matched path | unit | `bin/dispatch-test.sh::AC-D003-A` |
| Agent overwrites `wait-planning.json` and resets external-signal budget | Edit tool_use against path ending in a `/wait-*.json` shape | D-003 trips, rc=29 | unit | `bin/dispatch-test.sh::AC-D003-B` |
| Agent forges `dispatch_history.jsonl` to break forensic append-only invariant | Write tool_use against `/dispatch_history.jsonl` | D-003 trips, rc=29 | unit | `bin/dispatch-test.sh::AC-D003-C` |
| Agent rewrites `usage-planning.json` to bias cost telemetry | Edit tool_use against `/usage-planning.json` | D-003 trips, rc=29 | unit | `bin/dispatch-test.sh::AC-D003-D` |
| Legitimate `progress.md` write false-positives D-003 | Write tool_use against `/progress.md` (agent contract) | D-003 detective returns rc=0 (only ENG-109's existing detective covers `/progress.md`; D-003 does not touch it) | unit | `bin/dispatch-test.sh::AC-D003-E` |
| Legitimate `stage-summary-*.md` write false-positives D-003 | Write tool_use against `/stage-summary-planning.md` | D-003 returns rc=0 (no suffix in the orchestrator-owned list matches) | unit | `bin/dispatch-test.sh::AC-D003-F` |
| End-to-end: NDJSON stream carries a forbidden Write; `_render_and_capture_stream` halts | Fake stream-json input containing Write→`/issue-state.json` plus a `type:result` event | `_render_and_capture_stream` returns 29; `$violation_file` content names `/issue-state.json` | integration | `bin/dispatch-test.sh::AC-D003-G` |
| Parameterised helper rejects unrecognized tool name | `assert_no_tool_with_input_path tx "Write" file_path /progress.md` against an Edit tool_use | rc=0 (Edit not in `"Write"` allowlist) | unit | `bin/common-test.sh::AC-PARAM-C` |
| Parameterised helper accepts csv tool-name list | `assert_no_tool_with_input_path tx "Write,Edit" file_path /progress.md` against an Edit tool_use | rc=1 + matched path | unit | `bin/common-test.sh::AC-PARAM-B` |
| Back-compat: existing `assert_no_write_to_path` callers keep passing | All 23 + 48 existing references invoke the now-thin-wrapper | Unchanged rc/stdout semantics | unit | `bin/common-test.sh` (existing fixtures, re-run after Task 1 rewire) |
| Auto-mode bash classifier rejects multi-path `git add A B` | Implement/UI agent stages multiple paths in one invocation | Prompt-side directive says "one path per call"; the agent's commit hits the docs/knowledge/conventions trail at impl time | smoke | (Process — verified by manual inspection of next implement-stage run after merge; not a unit test — the classifier is sandbox-side, transcript-invisible) |
| Per-stage allowlist for impl/ui/qa drops `git add` | `allowed_tools_for "$stage"` regression | impl + ui contain literal `Bash(git add:*)`; qa contains `Bash(git:*)` wildcard | unit | `bin/dispatch-test.sh::AC-GIT-ADD-AUDIT` |
| Planning allowlist silently gains `git add` (OQ-2 drift) | `allowed_tools_for planning` regression | Does NOT contain `Bash(git add:*)` or `Bash(git:*)` | unit | `bin/dispatch-test.sh::AC-GIT-ADD-AUDIT (planning sub-assertion)` |

## Test Strategy

- **Unit (helper-direct):** Task 1's parameterised helper and Task 2's D-003 detective are exercised via direct-call fixtures in `bin/common-test.sh` (AC-PARAM-*) and `bin/dispatch-test.sh` (AC-D003-A through F). This is the same shape the existing EW1/EW2 (ENG-109) and AS1-AS12 (ENG-43, ENG-71) blocks use. Coverage: every forbidden-suffix entry has at least one matching fixture; the two legitimate writes (progress.md, stage-summary-*.md) have negative fixtures.
- **Integration (end-to-end through `_render_and_capture_stream`):** AC-D003-G synthesizes a complete stream-json input file (Write tool_use + `type:result` event) and invokes the renderer directly, asserting both return code and sidecar contents. This mirrors the ENG-26 Group 3 Fixture A-E shape at lines 544-705.
- **Argv-capture (dispatch-side):** AC-ADDDIR re-uses the existing `claude` stub at `bin/dispatch-test.sh:115-130` (`$ARGV_CAPTURE` file, one arg per line) to assert `--add-dir` placement. The DRY_RUN sub-assertion parses the `[DRY_RUN] would invoke:` log line. This is the same shape Group 4 (ENG-48) uses for `--setting-sources` / `--disable-slash-commands`.
- **Allowlist regression:** AC-GIT-ADD-AUDIT pins the four stages' git verb composition. Per-stage assertions live in the same per-stage loop pattern Group 1 uses for `mcp__*linear*` exclusion.
- **Adversarial (sandbox + classifier surfaces):** Process-only — the bash classifier rejection is sandbox-side and transcript-invisible. D-006's prompt-side directive is the cheapest defense; verification happens at the next implement-stage run by manual transcript inspection if the symptom recurs.
- **Smoke (gate suite):** Every gate in `learned-rules/harness/project-profile.md::## Build & test gates` passes (`bash bin/dispatch-test.sh && bash bin/run-stage-test.sh && bash bin/common-test.sh && …`). Pre-commit hook also runs.
- **Why no `bin/run-stage-test.sh` change:** the D-001 plumbing lives entirely inside `bin/dispatch.sh`; `bin/run-stage.sh` already calls `mkdir -p "$(issue_dir "$ident")"` at line 1329 (pre-existing) so the integration surface from run-stage's perspective is unchanged. The post-ENG-160 `_ensure_progress_md` seeding (lines ~1330-1340) is what makes the agent's `Edit` succeed on the first write; that combination — ENG-160 seed + ENG-155 `--add-dir` + ENG-155 D-003 detective — is the full fix.
- **Test-gate closure (add-side) — explicit rationale.** No new gate-runnable file is being created. All three test surfaces (AC-ADDDIR, AC-GIT-ADD-AUDIT, AC-D003) land as new groups inside the already-gated `bin/dispatch-test.sh`; AC-PARAM-* land inside the already-gated `bin/common-test.sh`. `learned-rules/harness/project-profile.md::## Build & test gates` Test command already enumerates both files (line 17). No profile edit required.
- **Test-gate closure (remove-side) — explicit rationale.** This plan removes ZERO test-pinned tokens. `assert_no_write_to_path` and `assert_no_tool_invocation` names are preserved; the parameterised helper is purely additive. The 23 references in `bin/common-test.sh` and 48 in `bin/dispatch-test.sh` continue to pass after the thin-wrapper rewire. Verified at plan time: `grep -c 'assert_no_write_to_path\|assert_no_tool_invocation' bin/common-test.sh bin/dispatch-test.sh` = 23 + 48.

## Verification (AC #2 operator-confirmation)

After this plan lands and the orchestrator's next tick runs:

1. **Pick a halted fixture.** Linear ticket cites ENG-125 (planning halt with `progress-md-entry-missing`, rc=31); any open issue in `pipeline:halted` with sidecar matching `progress-md-entry-missing` is an equivalent fixture.
2. **Run the resume command:** `bash bin/pipeline.sh decide ENG-125 --action continue`. This atomically clears `pipeline:halted`, `pipeline:skip-until-*`, `wait-planning.json`, `.consecutive-failures`, drains `issue-state.json` (preserving allocator fields via ENG-146), and posts an operator-resume transition waypoint.
3. **Wait one tick (≤5 min).** The orchestrator re-allocates `dispatch_id` (`ENG-125-d000N+1`), runs `_clear_current_stage_slots`, dispatches `bin/dispatch.sh planning` with `--add-dir "$(issue_dir ENG-125)"` in argv.
4. **Confirm success signals:**
   - `tail -20 $PROJECT_STATE_DIR/harness/logs/local-$(date -u +%Y-%m-%d).log` shows `dispatch.sh exit=0` for ENG-125 planning.
   - `cat $(issue_dir ENG-125)/progress.md` contains one new H2 entry stamped with the freshly-allocated dispatch_id.
   - Linear comment `completion/plan/ENG-125` posted with the new plan doc artifact link.
   - `bash bin/status.sh` shows ENG-125 advanced to `stage:implementing`.
5. **Spot-check `--add-dir` reached the agent:** inspect `$PROJECT_STATE_DIR/harness/ENG-125/.envelope-transcript-planning` for the captured stream-json init event; its `cwd` and configuration block should show the per-issue worktree as cwd AND `$(issue_dir ENG-125)` in the allowed-add-dir set.

If step 4 returns rc != 0 OR `progress.md` carries no new entry, this plan's fix is incomplete; file a follow-up halt comment with the rc and the sidecar contents — `--action continue` is the canonical recovery and should succeed for any `progress-md-entry-missing` halt class post-ENG-155.
