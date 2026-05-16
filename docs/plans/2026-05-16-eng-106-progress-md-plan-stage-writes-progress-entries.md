---
linear: ENG-106
date: 2026-05-16
topic: ENG-106 writer pilot — AGENT_PROMPTS.md §2 plan-stage step "append a progress.md entry"; {progress_md_path} resolver in render-prompt.sh; private filesystem detective `_assert_progress_md_entry` in dispatch.sh stage-gated to planning (rc=31, `progress-md-entry-missing` taxonomy entry); run-stage.sh rc-arm + skip-until-human-acts policy; PG1–PG6 fixtures in dispatch-test.sh; docs/runbooks/recovery.md rc=31 section
---

# Plan — ENG-106 progress.md plan-stage writer pilot

Implementation plan for the design at
`docs/brainstorms/2026-05-16-eng-106-progress-md-plan-stage-writes-progress-entries-design.md`.
Foundation (path/schema/runbook) shipped in ENG-107 — this plan is
the writer side only.

## Anti-anchoring check

- **Problem (operator's words).** ENG-28 (parent umbrella) wants a
  continuous per-issue notebook the next-stage agent can read to recover
  prior-dispatch prose context without re-parsing transcripts. ENG-107
  shipped the path + schema; **ENG-106 is the first writer**: one stage
  (planning) appends to `progress.md` summarising its decisions, and a
  detective halts on a missing entry.
- **Brainstorm addresses it?** Yes. D-002 puts the writer in the plan
  agent's prompt; D-005 puts the detective in `bin/dispatch.sh` per the
  Linear ticket's instruction; D-007 ships the PG1–PG6 fixtures the
  ticket's IN list names. The three Linear ACs map 1:1 onto D-002 (AC #1
  heading shape), D-005 + D-006 (AC #2 halt-on-missing), and D-002
  wording + D-005 strict-superset check (AC #3 no full-file rewrites).
- **Proportional?** Yes. Brainstorm §3 sizes the change at ~205 LOC
  across 7 files (1 new exit code, 1 new prompt token, 1 new resolver
  function, 1 new dispatch.sh private helper, 1 new run-stage.sh rc arm,
  6 new test fixtures, 1 new runbook section). No new label, no new
  Linear marker shape, no new metric. The Linear ticket's IN list is
  satisfied exactly; the OUT list (other writers, any reader) is
  honored by D-005's stage-gate on `planning` and the brainstorm's OQ-3
  / OQ-5 deferrals.
- **No escalation. PROCEED.**

## Branch-base freshness

`git fetch origin main` was run at plan time (orchestrator-side
fetch — this dispatch's environment already has fresh
`origin/main`). `git log --oneline HEAD..origin/main` returned EMPTY.

- branch-base freshness: `HEAD..origin/main` empty at plan time
  (`origin/main = fb3d1b76a6d3b67ac0a28505cfeaff26bf9f256b`).

No Task 0 rebase is required. All `path:line` excerpts in the
Assumption Inventory are stable against current HEAD. Edit boundaries
use content anchors regardless, so any sibling commit landing during
implement-time before the implement agent's own pre-edit re-grep
(Task 1) is caught loudly.

## Goal

After implement runs:

1. `bash bin/dispatch-test.sh` exits 0 with six new PG1–PG6 rows
   passing (per the fixture table at brainstorm §2 D-007 — covers AC #1
   well-formed, AC #2 missing, AC #3 append-no-rewrite, and the
   planning-stage gate).
2. `bash bin/common-test.sh` exits 0 — pre-existing rows unchanged
   (the new exit-code 31 entry in `failure_outcome_for_exit` is
   covered by either a new fixture row OR the ENG-65 dispatch-rc
   taxonomy table already in `bin/common-test.sh`).
3. `bash .githooks/pre-commit` exits 0 (the entire `bin/*-test.sh`
   suite green, including the new PG1–PG6 fixtures and any
   `bin/render-prompt-test.sh` row touching the new token).
4. On a real planning dispatch:
   - `progress_md_path` resolves into the agent's prompt as a
     `{progress_md_path}` token (D-004 wiring).
   - Agent's Completion checklist step 5 (new) appends ONE H2 entry
     to `$(progress_md_path <ident>)` with the schema heading
     `## <PIPELINE_DISPATCH_ID> - planning - <ISO-8601-UTC>` followed
     by 3–5 bullets (D-002 + D-003 contract).
   - On a missing/malformed entry, `_assert_progress_md_entry`
     returns 31; `run-stage.sh` exits 31 with `classify_failure
     skip-until-human-acts` and the operator can recover via
     `bash bin/pipeline.sh decide <ident> --action continue` (D-009).

Verifiable by:

```
bash bin/dispatch-test.sh \
  && bash bin/common-test.sh \
  && bash .githooks/pre-commit
```

exiting 0.

## Assumption Inventory

Every `path:line` excerpt below was re-verified against the worktree
HEAD on `feat/eng-106-progress-md-plan-stage-writes-progress-entries`
at `origin/main = fb3d1b7` (the branch-base freshness pin above).
Edit-boundary keys are CONTENT anchors; bare line numbers appear ONLY
as informational hints. Quoted excerpts are exact substrings safe to
pass to `Edit::old_string`.

### Files modified in this plan: 7 (1 new, 6 edited)

- `AGENT_PROMPTS.md` (one edit site — Task 5 inserts a new
  Completion checklist step 5 between the existing step 4 "Commit
  artifacts" and the existing step 5 "Write the stage summary file";
  existing steps 5–6 renumber to 6–7)
- `bin/render-prompt.sh` (three edit sites — Task 2 adds one row to
  `PROMPT_RESOLVERS`, Task 3 adds one resolver function, Task 4 adds
  one `_RENDER_*` global binding in `main()`)
- `bin/common.sh` (one edit site — Task 7 adds one case arm to
  `failure_outcome_for_exit`)
- `bin/dispatch.sh` (two edit sites — Task 8 inserts a stage-gated
  call inside `_render_and_capture_stream`, Task 9 defines the
  private helper `_assert_progress_md_entry` directly below the
  function's closing brace)
- `bin/run-stage.sh` (one edit site — Task 10 inserts a new
  `elif (( dispatch_rc == 31 ))` arm at the dispatch-rc dispatch table)
- `bin/dispatch-test.sh` (one edit site — Task 11 inserts a new test
  group "ENG-106 PG1–PG6" immediately before the final `─── Summary
  ───` footer)
- `docs/runbooks/recovery.md` (one edit site — Task 12 adds a new
  section for rc=31 mirroring the existing rc=23 section)

### Modified-file facts — current state and verification points

- **A-001 — `bin/common.sh::progress_md_path` exists at lines 78–82
  and is on the public `export -f` list.** Verified by direct read
  (`bin/common.sh:73-82`):

  ```bash
  # ENG-107: per-issue progress notebook path. Append-only contract;
  # never cleared on dispatch. See docs/runbooks/progress-md.md for
  # schema, lifecycle, and ownership boundary. Composed on issue_dir
  # so the resolution rules (PROJECT_STATE_DIR, bootstrap-mode
  # behaviour, die-on-empty-issue) match exactly.
  progress_md_path() {
    local issue="$1"
    [[ -n "$issue" ]] || die "progress_md_path: missing issue id"
    printf '%s/progress.md' "$(issue_dir "$issue")"
  }
  ```

  And `bin/common.sh:400`:

  ```
  export -f issue_dir compute_pipeline_content_hash failure_outcome_for_exit parse_pipeline_marker is_orchestrator_paused set_orchestrator_paused allocate_dispatch_id current_dispatch_id assert_no_tool_invocation progress_md_path
  ```

  Both surfaces are unchanged by this plan; ENG-106 only CONSUMES the
  helper (no redefinition).

- **A-002 — `bin/common.sh::failure_outcome_for_exit` taxonomy spans
  lines 222–250; case 31 is unallocated (case arms 0/10/11/12/13/14/
  20/21/22/23/24/25/26/27/28/29/30/124/`*`).** Verified by direct
  read (`bin/common.sh:222-250`):

  ```bash
  failure_outcome_for_exit() {
    local exit_code="$1" subcode="${2:-}"
    case "$exit_code" in
      0)
        case "$subcode" in
          1) printf 'scope-approval-pending' ;;
          *) printf 'unknown-exit-0' ;;
        esac
        ;;
      10) printf 'guards-tripped' ;;
      11) printf 'paused' ;;
      12) printf 'stage-drift' ;;
      13) printf 'lane-violation' ;;
      14) printf 'legacy-marker-write' ;;
      20) printf 'dispatch-failed' ;;
      21) printf 'scope-violation' ;;
      22) printf 'pr-opened-too-early' ;;
      23) printf 'branch-creation-forbidden' ;;
      24) printf 'linear-post-failed' ;;
      25) printf 'agent-contract-missing' ;;
      26) printf 'worktree-mutation-forbidden' ;;
      27) printf 'self-leak' ;;
      28) printf 'leaked-in-scope-threshold' ;;
      29) printf 'envelope-violation' ;;
      30) printf 'noop-implementation' ;;
      124) printf 'dispatch-timeout' ;;
      *)  printf 'unknown-exit-%s' "$exit_code" ;;
    esac
  }
  ```

  Content anchor for Task 7's Edit (the unique substring
  `30) printf 'noop-implementation' ;;` followed by `124) printf
  'dispatch-timeout' ;;` is the natural insertion point — code 31
  belongs alphabetically between 30 and 124).

- **A-003 — `bin/dispatch.sh::_render_and_capture_stream` body spans
  lines 47–236; the function ends at `}` on line 236; the next
  declaration `disallowed_platform_tools()` is preceded by a comment
  block starting at line 238 (`# ENG-48 isolation: platform tools …`).**
  Verified by direct read (`bin/dispatch.sh:236-244`):

  ```bash
        return 13
      fi
    done
  }
  
  # ENG-48 isolation: platform tools whose call from a headless dispatch
  ```

  Content anchors for Task 8 (call-site insertion):
  - START anchor — the closing `done` of the core.bare loop:
    ```
        return 13
      fi
    done
  ```
    (this `done` is the LAST `done` inside `_render_and_capture_stream`
    before its closing brace; the `core.bare` for-loop is the final
    block in the function body — verified by Grep on `done$` between
    line 47 and line 236).
  - END anchor — the closing brace of `_render_and_capture_stream`
    immediately above the blank line + `# ENG-48 isolation:` comment:
    ```
  }
  
  # ENG-48 isolation: platform tools whose call from a headless dispatch
  ```

  Task 8 inserts the 3-line stage-gated call BETWEEN the `done` and
  the closing `}` (so the call is INSIDE
  `_render_and_capture_stream`). The Edit's `old_string` uses the
  literal `    done\n  }\n  \n  # ENG-48 isolation:` substring (where
  the four-space-then-`done` line is the closing `done` of the
  core.bare for-loop). Content anchor for Task 9 (helper definition
  site) is the literal block ending `}\n  \n  # ENG-48 isolation:` —
  the helper is inserted AFTER the closing brace and BEFORE the
  `# ENG-48 isolation:` comment.

- **A-004 — `bin/dispatch.sh:50` declares
  `local violation_file="${issue_dir}/.transcript-violation-${stage}"`
  and lines 55, 155, 179, 203, 231 reference it.** Verified by direct
  read (`bin/dispatch.sh:48-55`):

  ```bash
  _render_and_capture_stream() {
    local usage_file="$1" issue_dir="$2" stage="${3:-}"
    local raw_capture="${issue_dir}/.raw-stream.ndjson.tmp"
    local violation_file="${issue_dir}/.transcript-violation-${stage}"
    # ENG-87: the envelope-validator sidecar persists across the RETURN
    # trap below so run-stage.sh::_validate_dispatch_envelope can scan
    # it post-dispatch. Idempotent pre-clean (D-008).
    local envelope_sidecar="${issue_dir}/.envelope-transcript-${stage}"
    rm -f "$violation_file" "$envelope_sidecar"
  ```

  Task 8 and Task 9 will reuse `$violation_file` and `$issue_dir`
  (both `local`-scoped to `_render_and_capture_stream`). Task 9's
  helper `_assert_progress_md_entry` accepts `$issue_dir` and
  `$violation_file` as positional arguments so it works against the
  same lexical scope as the existing detectives (no env-var smuggling
  needed; matches AS1-AS6's direct-helper-invocation pattern).

- **A-005 — Existing dispatch-detective cohort in
  `_render_and_capture_stream` uses the pattern: stage-gate `if [[
  "$stage" == "<stage>" ]] then …`; `_matched_X="$(assert_no_tool_invocation
  …)"`; on match `printf '%s\n' "$_matched_X" > "$violation_file"`,
  `log "[assert] …"`, `return <rc>`.** Verified by direct read of the
  four blocks at `bin/dispatch.sh:150-159` (gh pr create, rc=22),
  `:173-184` (build-stage git verbs, rc=26), `:194-207` (cross-stage
  branch creation, rc=23), `:221-235` (cross-stage core.bare, rc=13).

  Task 8 inserts a fifth block following this idiom EXCEPT for two
  documented divergences:
  - The check is a FILESYSTEM check, not a transcript scan (per
    brainstorm D-005). The detective helper does NOT call
    `assert_no_tool_invocation`; it calls
    `_assert_progress_md_entry` (defined by Task 9).
  - The diagnostic message is written to `$violation_file` by the
    helper, not inline in the call-site block. The call-site sees
    only rc=0 / rc=31 from the helper.

  Both divergences are documented as comments inside the new block
  (mirroring the existing ENG-43/ENG-66/ENG-68/ENG-71 callouts).

- **A-006 — `bin/run-stage.sh` dispatch-rc dispatch arms span lines
  1310–1398; each arm follows the pattern `_viol_file_<rc>="$(issue_dir
  "$ident")/.transcript-violation-${stage}"; _viol_msg_<rc>="$(cat …)";
  classify_failure "$ident" "$stage" "skip-until-human-acts" "<msg>:
  $_viol_msg_<rc>" <rc>; rm -f "$_viol_file_<rc>" "$prompt_file";
  exit <rc>`.** Verified by direct read of the four arms at
  `bin/run-stage.sh:1324-1336` (rc=22), `:1337-1352` (rc=23),
  `:1353-1379` (rc=26), `:1380-1393` (rc=13), followed by the
  catch-all `elif (( dispatch_rc != 0 ))` at line 1394.

  Content anchor for Task 10's Edit (the literal closing of the
  rc=13 arm immediately followed by the catch-all `elif`):

  - START anchor — the unique substring
    `"stage transcript invoked forbidden core.bare git form: $_viol_cmd_13" 13` —
    the message body in the rc=13 arm:
    ```
      classify_failure "$ident" "$stage" "skip-until-human-acts" \
        "stage transcript invoked forbidden core.bare git form: $_viol_cmd_13" 13
      rm -f "$_viol_file_13" "$prompt_file"
      exit 13
    elif (( dispatch_rc != 0 )); then
    ```
  - END anchor — the literal opening of the catch-all `elif (( dispatch_rc
    != 0 )); then` (unique within the function — only one
    catch-all).

  Task 10 inserts the new `elif (( dispatch_rc == 31 ))` arm AFTER
  the rc=13 `exit 13` and BEFORE the catch-all `elif (( dispatch_rc
  != 0 ))`. The arm follows the existing pattern verbatim, with
  `_viol_file_31` / `_viol_msg_31` local variable names (uniqueness
  inside `main()`).

- **A-007 — `bin/render-prompt.sh::PROMPT_RESOLVERS` registry spans
  lines 41–55 with one `name=fn_name` row per line.** Verified by
  direct read (`bin/render-prompt.sh:41-55`):

  ```bash
  PROMPT_RESOLVERS='
  issue_id=_resolve_issue_id
  issue_id_lower=_resolve_issue_id_lower
  issue_title=_resolve_issue_title
  issue_description=_resolve_issue_description
  date=_resolve_date
  slug=_resolve_slug
  brainstorm_file=_resolve_brainstorm_file
  plan_file=_resolve_plan_file
  branch_name=_resolve_branch_name
  stage_summary_path=_resolve_stage_summary_path
  learned_rules_dir=_resolve_learned_rules_dir
  dispatch_id=_resolve_dispatch_id
  review_findings=_resolve_review_findings
  '
  ```

  Content anchor for Task 2's Edit: the literal unique line
  `review_findings=_resolve_review_findings`. Task 2 inserts a new
  row `progress_md_path=_resolve_progress_md_path` BEFORE the
  closing `'` of the heredoc literal (and AFTER the
  `review_findings=` row to keep insertion order tracked
  chronologically per the registry's existing convention).

- **A-008 — `bin/render-prompt.sh` resolver functions sit between
  lines ~215 and ~252; `_resolve_stage_summary_path` is the
  one-line precedent at line 226.** Verified by direct read
  (`bin/render-prompt.sh:225-227`):

  ```bash
  _resolve_branch_name() { printf '%s' "$_RENDER_BRANCH_NAME"; }
  _resolve_stage_summary_path() { printf '%s' "$_RENDER_STAGE_SUMMARY_PATH"; }
  _resolve_learned_rules_dir() { printf '%s' "$_RENDER_LEARNED_RULES_DIR"; }
  ```

  Content anchor for Task 3's Edit: the literal unique line
  `_resolve_stage_summary_path() { printf '%s' "$_RENDER_STAGE_SUMMARY_PATH"; }`.
  Task 3 inserts the new `_resolve_progress_md_path` function
  directly AFTER this line, mirroring its 1-line shape:

  ```bash
  _resolve_progress_md_path() { printf '%s' "$_RENDER_PROGRESS_MD_PATH"; }
  ```

- **A-009 — `bin/render-prompt.sh::main()` binds the `_RENDER_*`
  globals at lines 404–421.** Verified by direct read
  (`bin/render-prompt.sh:404-421`):

  ```bash
  _RENDER_ISSUE_ID="$issue_id"
  _RENDER_ISSUE_ID_LOWER="$issue_id_lower"
  _RENDER_TITLE="$title"
  _RENDER_DESCRIPTION="$description"
  _RENDER_DATE="$date"
  _RENDER_SLUG="$slug"
  _RENDER_BRAINSTORM_FILE="$brainstorm_file"
  _RENDER_PLAN_FILE="$plan_file"
  _RENDER_BRANCH_NAME="$branch_name"
  _RENDER_STAGE_SUMMARY_PATH="$stage_summary_path"
  _RENDER_LEARNED_RULES_DIR="$learned_rules_dir"
  _RENDER_REVIEW_FINDINGS_PATH="$review_findings_path"
  # ENG-87 review-iter-7 M9: bind _RENDER_DISPATCH_ID like the sibling
  # _RENDER_* globals so resolver test isolation is uniform across the
  # registry. Falls through to empty when PIPELINE_DISPATCH_ID is unset
  # (release-stage main() never reaches this stanza; direct test paths
  # set _RENDER_DISPATCH_ID directly).
  _RENDER_DISPATCH_ID="${PIPELINE_DISPATCH_ID-}"
  ```

  Content anchor for Task 4's Edit: the unique two-line block:

  ```
  _RENDER_STAGE_SUMMARY_PATH="$stage_summary_path"
  _RENDER_LEARNED_RULES_DIR="$learned_rules_dir"
  ```

  Task 4 inserts a local-variable resolve `progress_md_path="$(progress_md_path
  "$issue_id")"` next to the existing `stage_summary_path=...` resolve
  at `bin/render-prompt.sh:389` AND inserts a new bind
  `_RENDER_PROGRESS_MD_PATH="$progress_md_path"` between the two anchor
  lines above (so the resolver-global is initialised before
  `resolve_block_tokens` runs). The local-variable resolve uses
  `progress_md_path` (the function exported from `bin/common.sh` per
  A-001) so there is a SINGLE source of truth for the path formula
  (D-004 / honors ENG-79 single-helper precedent).

- **A-010 — `AGENT_PROMPTS.md` §2 Plan Agent spans lines 348–606;
  the Completion checklist starts at line 537 with the header
  `## Completion checklist (ordered — do every step in order, and do
  NOT exit before step 5)`; current step 5 (Write the stage summary
  file) starts at line 569; current step 6 (Post the verdict marker)
  starts at line 585; the closing fence ``` is at line 606.**
  Verified by direct read (`AGENT_PROMPTS.md:537,569,585,606`).

  Content anchor for Task 5's Edit: the unique 5-line block at
  `AGENT_PROMPTS.md:564-569` — the closing of step 4 (Commit
  artifacts) followed by the opening line of step 5 (Write the stage
  summary file):

  ```
  4. **Commit artifacts** (success path only): plan doc on the feature branch with message
     `chore(pipeline): plan for {issue_id}`. Plans and brainstorms stay on the feature branch
     and reach main via the normal merge flow; do not attempt direct-to-main pushes. Only
     knowledge-file changes go through PRs with CODEOWNERS. Do NOT change the Linear stage
     label — the orchestrator swaps it on successful exit.
  5. **Write the stage summary file** at `{stage_summary_path}` — LAST step, MANDATORY.
  ```

  Task 5 inserts the new "5. **Append a progress.md entry**" block
  AFTER the step-4 closing line (the literal
  `label — the orchestrator swaps it on successful exit.`) and
  BEFORE the existing step 5 line (`5. **Write the stage summary
  file**`). Existing step 5 → new step 6 (manual renumber inside the
  Edit's new_string); existing step 6 → new step 7 (same).

  The renumbered step 6 (formerly 5) and step 7 (formerly 6) are
  preserved verbatim — same body text, same bullets, same
  `{stage_summary_path}` and `{issue_id}` tokens. The Edit's
  `old_string` covers ALL of lines 537–606 (the entire Completion
  checklist block, fenced); the `new_string` is the same block with
  the new step 5 spliced in and existing step numbers incremented.

  Alternative if the full-block Edit is too large for a single
  `Edit::old_string`: split into two sequential Edits, each on a
  tightly-anchored unique substring. Task 5.1 anchors on step 4's
  closing line + step 5's opening line; Task 5.2 anchors on the
  current "5. **Write the stage summary file**" line and renumbers
  it to "6."; Task 5.3 anchors on the current "6. **Post the verdict
  marker**" line and renumbers it to "7.". The implement agent
  chooses based on the Edit tool's response size.

- **A-011 — The new prompt step 5 body conforms to the schema in
  `docs/runbooks/progress-md.md` §2 lines 34–61.** Verified by
  direct read; the heading shape `## <PIPELINE_DISPATCH_ID> -
  planning - <ISO-8601-UTC>` and the ASCII space-hyphen-space
  separator are documented at lines 46 (Token 1/2/3 description) and
  56 ("ASCII ` - ` is recommended for grep-friendliness"). The new
  prompt body in Task 5 mandates the ASCII form (D-002 / brainstorm
  §6 edge-case "em-dash separator").

  The new step body also instructs the agent on the Read-then-Write
  idiom for the `(none)` tool allowlist case (the plan agent has no
  `>>` shell-redirection capability — verified by the project
  profile's "planning: (none)" Tool allowlist section). The
  instruction explicitly forbids `Write` with only the new entry
  (truncation hazard per brainstorm D-002 / §6 / OQ-2).

- **A-012 — `bin/dispatch-test.sh` ends with a `# ─── Summary ───`
  block at lines ~3022–3030 followed by `printf '\nRESULTS: %d passed,
  %d failed\n'`, the `[[ "$FAIL" == 0 ]] || exit 1`, and a final
  `exit 0`.** Verified by `wc -l bin/dispatch-test.sh` (3030 lines)
  + direct tail-read of the last 15 lines.

  Content anchor for Task 11's Edit: the literal `# ─── Summary
  ────────────────────────────────────────────────────────────` line
  (unique within the file — `grep -c '^# ─── Summary'
  bin/dispatch-test.sh` returns 1). Task 11 inserts the new test
  group "ENG-106 PG1–PG6" BEFORE this anchor line. The new group
  uses the existing `_TEST_STUB_DIR` scaffold (lines 21–42), the
  `pass_at`/`fail_at` helpers (lines 73–75), the post-source
  override pattern (PROJECT_SLUG, HARNESS_STATE_DIR, PROJECT_STATE_DIR
  at lines 18,62–66), and exports `PIPELINE_DISPATCH_ID` and
  `PIPELINE_ISSUE_ID` per fixture (matching the AS1-AS6 pattern at
  lines 1189–1268 and ENG-87 M6 at line 2209).

- **A-013 — `bin/dispatch-test.sh` sources `bin/dispatch.sh` at
  line 70 via `source "$SCRIPT_DIR/dispatch.sh"` so dispatch.sh
  functions are in scope post-source.** Verified by direct read
  (`bin/dispatch-test.sh:68-70`):

  ```bash
  # ─── Source dispatch.sh (no main due to sentinel) ────────────────────────
  # shellcheck source=dispatch.sh
  source "$SCRIPT_DIR/dispatch.sh"
  ```

  The new private helper `_assert_progress_md_entry` (defined by
  Task 9 in dispatch.sh) will be in scope after source. PG1–PG6
  invoke it directly — no `_render_and_capture_stream` end-to-end
  required.

- **A-014 — `docs/runbooks/recovery.md` exists; the brainstorm
  cites a "§7" governing rc=23 recovery.** Verified by `ls
  docs/runbooks/recovery.md` (exists; size 14K). Section-7 line range
  is NOT pre-read in this plan; Task 12.1 (re-grep) confirms section
  numbering at implement-time. The new rc=31 section MAY land as §8
  (if §7 is the current last numbered section) or further depending
  on the actual file state. The doc-edit is uniformly
  template-driven: header, symptom, recovery recipe; matches the
  rc=23 shape.

  Marked `assumed` — implement-time mechanical confirmation. No P0
  risk: the plan's correctness does NOT depend on the section number;
  it depends on the runbook gaining a new section that mirrors the
  rc=23 shape.

- **A-015 — `PIPELINE_DISPATCH_ID` and `PIPELINE_ISSUE_ID` are
  exported into the dispatch.sh subshell.** Verified by direct read
  (`bin/dispatch.sh:563-566`):

  ```bash
  local cmd=(env PIPELINE_WRITER=agent
    "PIPELINE_DISPATCH_ID=${PIPELINE_DISPATCH_ID-}"
    "PIPELINE_STAGE=$stage"
  )
  ```

  `PIPELINE_ISSUE_ID` is set by the orchestrator before invoking
  dispatch.sh (per `bin/run-stage.sh:1305` `PIPELINE_ISSUE_ID="$ident"`),
  and is read at `bin/dispatch.sh:439` (`if [[ -n "${PIPELINE_ISSUE_ID:-}"
  ]]; then issue_state_dir="$(issue_dir "$PIPELINE_ISSUE_ID")"`).
  Both env vars are in scope in `_render_and_capture_stream`'s
  subprocess at the point Task 8's call fires.

  Task 9's helper reads `${PIPELINE_DISPATCH_ID-}` and accepts
  `$issue_dir` as a positional argument (passed through from the
  caller, matching AS1-AS6's direct-helper-invocation pattern). It
  does NOT read `${PIPELINE_ISSUE_ID-}` — the `$issue_dir` already
  encodes the issue identity, and passing it as $1 avoids a second
  `issue_dir "$PIPELINE_ISSUE_ID"` call that would re-trigger
  `issue_dir`'s `die`-on-empty (cleaner test ergonomics: tests can
  pass an arbitrary directory without setting `PIPELINE_ISSUE_ID`).

- **A-016 — `PIPELINE_DRY_RUN=1` is the dispatch.sh test-path
  bypass; dispatch.sh's `main()` returns early at line 511 before
  invoking `claude`.** Verified by direct read (`bin/dispatch.sh:511-526`):

  ```bash
  if [[ "$PIPELINE_DRY_RUN" == "1" ]]; then
    …
    log "[DRY_RUN] would invoke: gtimeout …"
    …
    return 0
  fi
  ```

  Task 8's call lives INSIDE `_render_and_capture_stream`, which is
  invoked from the pipeline at lines 599 and 608 only when the
  non-DRY_RUN branch fires. Under `PIPELINE_DRY_RUN=1`, the
  renderer-and-detective is never reached. The PG1–PG6 fixtures
  therefore invoke `_assert_progress_md_entry` DIRECTLY (not through
  `_render_and_capture_stream`'s end-to-end stream-rendering), which
  is the AS1-AS6 / CB1-CB8 / BC1-BC8 idiom — verified at
  `bin/dispatch-test.sh:1193,1213,1226,…`.

- **A-017 — Branch prefix matches the Improvement / Feature label
  per CLAUDE.md.** Branch name (from git status): `feat/eng-106-…`
  (verified at plan time). CLAUDE.md confirms `feat/` =
  Feature/Improvement; the Linear ticket is filed under ENG-28
  (umbrella, Improvement). ✓

- **A-018 — Plan doc basename satisfies
  `partition_dirty_paths::D-004` in-scope bucketing.** Filename:
  `2026-05-16-eng-106-progress-md-plan-stage-writes-progress-entries.md`.
  Contains the `eng-106` token (lowercase) in the basename at the
  correct position. ✓

- **A-019 — `learned-rules/harness/plan.md` does not exist.**
  Verified by `ls learned-rules/harness/`: returns only
  `build.md` and `project-profile.md`. Per the plan prompt's
  preamble (skip-if-not-present), no plan-stage learned rules to
  apply. (Identical to ENG-107's A-016 finding.)

- **A-020 — Test-gate closure sweep: tokens REMOVED from any
  tracked file by this plan = zero.** This plan ONLY INSERTS
  content. No tokens are renamed, dropped, default-changed, or
  otherwise deleted from production code. Tests of pre-existing
  behaviour stay green by construction.

  Defensive check on additions (confirming the new tokens aren't
  pinned-ABSENT by any sibling test):

  - `_assert_progress_md_entry` — `Grep` on `bin/*-test.sh` for
    `_assert_progress_md_entry` returns zero pre-edit matches.
    Task 11 introduces the only fixture references; no sibling test
    has a forbidden-token assertion against this name.
  - `progress-md-entry-missing` — `Grep` on `bin/*-test.sh` for
    this taxonomy token returns zero pre-edit matches. Same.
  - `_resolve_progress_md_path` — `Grep` on `bin/*-test.sh` for
    this resolver returns zero pre-edit matches. Task 11 OR a sibling
    `bin/render-prompt-test.sh` row may want to gate on its presence
    (deferred; see test strategy).
  - exit code `31` — `Grep` on `bin/*-test.sh` for `\b31\b` could
    surface false positives (year-token, line numbers, etc.); the
    relevant assertion is whether any test pins `31` as an
    UNKNOWN-EXIT taxonomy outcome. `Grep` on
    `bin/common-test.sh` for `unknown-exit-31` returns zero pre-edit
    matches; the new taxonomy entry simply consumes the previously
    unallocated slot.
  - `progress.md` (the file basename) — `Grep` on `bin/*-test.sh`
    for `progress\.md` returns matches in `bin/common-test.sh` (the
    ENG-107 ENG-107 fixtures, expecting the helper to return paths
    containing `/progress.md`). The new `progress.md` writes by
    PG1–PG6 fixtures expand on this surface; no pre-existing test
    pins `progress.md` as ABSENT.

  **Conclusion:** zero test-gate closure defects. No sibling test
  file needs editing beyond `bin/dispatch-test.sh` (the IN-list
  surface).

  Note on test coverage extension (NOT a test-gate closure
  defect): `bin/render-prompt-test.sh` SHOULD gain at least one row
  asserting that the `{progress_md_path}` token resolves under
  `_RENDER_PROGRESS_MD_PATH=…` to that value. This is a
  nice-to-have coverage extension — NOT a closure defect, because
  the existing render-prompt-test.sh does not assert the absence of
  this token. Task 6 adds the row (small, ~10 LOC).

- **A-021 — Project profile's `## Tool allowlist` for `planning` is
  `(none)`.** Verified by reading the project profile addendum at
  the bottom of THIS dispatch's prompt:

  ```
  - planning: (none)
  ```

  Combined with the implicit core (Read, Write, Edit, Grep, Glob,
  TaskCreate, git family, `bash bin/linear.sh`, `bash
  bin/pipeline.sh`, `bash bin/guards.sh`, `bash bin/slack.sh`, `bash
  bin/metrics.sh`), the plan agent in production has Read/Write/Edit
  but no generic `Bash`. The new prompt step 5 must therefore use
  Read-then-Write (D-002), not `cat >> "$path" <<EOF`. The
  Implementation Agent (stage `implementing`) HAS broader allowlist
  including `Bash(bash .githooks/pre-commit:*)` and every
  `bin/*-test.sh`, so it can both edit the prompt and run the test
  suite as its final gate.

- **A-022 — The `{dispatch_id}` token resolver already exists at
  `bin/render-prompt.sh:53,234,421`.** Verified by direct read.
  Task 5's new prompt body REFERENCES the token (`{dispatch_id}`)
  but does NOT redefine it; no change is needed to the existing
  `_resolve_dispatch_id` function.

Two assumptions marked `assumed` (A-014 runbook section number);
both are implement-time mechanical confirmations. No P0
codebase-fact risk.

## File Structure

Modified or new files only — no new test scripts, no new
dependencies, no new Linear labels, no new prompt-token shapes
beyond `{progress_md_path}`.

- `AGENT_PROMPTS.md` — one edit site:
  - Task 5: insert a new "5. **Append a progress.md entry**" step in
    §2 Plan Agent's Completion checklist between current step 4 (line
    564) and current step 5 (line 569); renumber existing 5 → 6 and 6
    → 7. ~30 lines added. Per A-010.

- `bin/render-prompt.sh` — three edit sites:
  - Task 2: insert `progress_md_path=_resolve_progress_md_path` as a
    new row in `PROMPT_RESOLVERS` after the `review_findings=` row,
    BEFORE the closing `'` of the heredoc (~line 54). +1 line.
    Per A-007.
  - Task 3: insert `_resolve_progress_md_path() { printf '%s'
    "$_RENDER_PROGRESS_MD_PATH"; }` directly after the
    `_resolve_stage_summary_path` line at ~line 226. +1 line. Per A-008.
  - Task 4: in `main()`, insert a local-variable resolve
    `progress_md_path="$(progress_md_path "$issue_id")"` next to the
    existing `stage_summary_path=...` resolve at line 389, AND
    insert `_RENDER_PROGRESS_MD_PATH="$progress_md_path"` between the
    existing `_RENDER_STAGE_SUMMARY_PATH=` and
    `_RENDER_LEARNED_RULES_DIR=` bindings (lines 413-414). +2 lines.
    Per A-009.

- `bin/common.sh` — one edit site:
  - Task 7: append a new case arm `31) printf
    'progress-md-entry-missing' ;;` to
    `failure_outcome_for_exit` between the existing `30)` and `124)`
    arms (lines 246–247). +1 line. Per A-002.

- `bin/dispatch.sh` — two edit sites:
  - Task 8: inside `_render_and_capture_stream`, insert a stage-gated
    3-line call to `_assert_progress_md_entry` AFTER the closing
    `done` of the core.bare for-loop (~line 235) and BEFORE the
    function's closing `}` (~line 236). +6 lines (3-line call + 3
    surrounding comment block describing the divergent-shape
    rationale per A-005). Per A-003.
  - Task 9: insert a new private helper `_assert_progress_md_entry`
    in dispatch.sh between the closing `}` of
    `_render_and_capture_stream` (line 236) and the `# ENG-48
    isolation:` comment header preceding `disallowed_platform_tools`
    (line 238). ~15 lines. Per A-003. The helper accepts
    `$issue_dir` and `$violation_file` as positional arguments,
    reads `${PIPELINE_DISPATCH_ID-}` from env, performs the
    filesystem check, and returns 0 (well-formed) or 31 (missing /
    malformed / multi-write).

- `bin/run-stage.sh` — one edit site:
  - Task 10: insert a new `elif (( dispatch_rc == 31 ))` arm in the
    dispatch-rc dispatch table AFTER the rc=13 arm's `exit 13` (line
    1393) and BEFORE the catch-all `elif (( dispatch_rc != 0 ))`
    (line 1394). ~8 lines. Per A-006. The arm reads
    `.transcript-violation-${stage}` per the existing pattern;
    classifies the failure as `skip-until-human-acts` with the
    halt-message template
    `plan-stage progress.md entry missing or malformed: $_viol_msg_31`;
    `rm -f` the sidecar + prompt file; `exit 31`.

- `bin/dispatch-test.sh` — one edit site:
  - Task 11: insert a new test group "ENG-106 PG1–PG6 — progress.md
    detective" immediately BEFORE the literal `# ─── Summary
    ────────────────────────────────────────────────────────────`
    line at ~line 3022. ~120 lines. Per A-012, A-013, A-015, A-016.
    Six fixtures synthesise post-stream filesystem state and invoke
    `_assert_progress_md_entry` directly (matching AS1-AS6's pattern).

- `docs/runbooks/recovery.md` — one edit site:
  - Task 12: insert a new section for rc=31 ("progress.md entry
    missing on plan dispatch") mirroring the existing rc=23 section's
    shape. ~25 lines. Per A-014. Section anchors are confirmed by
    Task 12.1's pre-edit re-grep.

Explicitly out of scope (per Linear issue's OUT list and
brainstorm §10):

- Other stages writing progress.md — `_assert_progress_md_entry` is
  stage-gated `planning`-only at Task 8's call-site (D-005,
  brainstorm OQ-3).
- Any reader (implement agent reading progress.md as cross-dispatch
  context) — OQ-5; the reader is a separate ENG-28 sub-ticket.
- `bin/run-stage.sh::_clear_current_stage_slots` (lines 883–891) —
  UNCHANGED. The cleared set stays `stage-summary-${stage}.md` +
  `wait-${stage}.json`; `progress.md` is intentionally absent (per
  ENG-107 D-002 / `docs/runbooks/progress-md.md` §4).
- `bin/run-stage.sh::_validate_dispatch_envelope` (lines 901–965) —
  UNCHANGED. The envelope validator's transcript-scan content does
  NOT add a `progress.md`-shaped scan (D-005 rejected alternative;
  rationale in brainstorm §10.1).
- `bin/run-local.sh`, `bin/run-local-helpers.sh`,
  `bin/scope-check.sh` — UNCHANGED. progress.md lives outside the
  worktree; sweep never sees it (ENG-107 §4).
- `bin/linear.sh`, `bin/pipeline.sh`, `bin/pipeline-events.json` —
  UNCHANGED. No new pipeline marker, no new verdict, no new label.
- `bin/poll.sh`, `bin/classify-failure.sh`, `bin/metrics.sh` —
  UNCHANGED. The new exit code routes through the existing
  `classify_failure` + `failure_outcome_for_exit` plumbing; no new
  metric or skip-policy variant.
- `learned-rules/harness/*.md` — UNCHANGED. Retrospective-owned.

## API Contract

no new API surface

(The harness has no FE↔BE API surface of its own — it is a Bash
orchestration toolkit. The dispatched agents talk to Linear / GitHub
via existing CLI shims, not via a typed contract this plan would
extend. The "API" this plan adds is the prompt-side
`{progress_md_path}` token, the dispatch-side `_assert_progress_md_entry`
helper, and the new exit code 31. All three are documented in this
plan and the runbook; none is an FE↔BE surface.)

## Backend Tasks

Tasks 2, 3, 4 form the prompt-side wiring; they must precede Task 5
(prompt content uses `{progress_md_path}`). Task 5 is the prompt
itself. Tasks 7, 8, 9, 10 form the detective wiring; Task 8's call
references Task 9's helper (must precede or be in the same Edit
ordering carefully — see Task 8 / Task 9 step ordering). Task 11
(fixtures) depends on Tasks 8 and 9 (the fixtures invoke the helper
defined by Task 9 via `_render_and_capture_stream` source — see
A-013). Task 6 (render-prompt-test.sh coverage row) depends on Tasks
2, 3, 4. Task 12 (runbook section) is independent. Task 13 (final
gate) depends on every task above.

The implement agent SHOULD run Task 1 first (read-only re-grep),
then any order of {Tasks 2, 3, 4, 7, 12} (independent file regions),
then Tasks 8 and 9 (same file; do Task 9 first so the helper exists
when Task 8 references it), then Task 5 (prompt body uses the
already-registered token), then Task 10, then Task 6, then Task 11,
then Task 13.

(No Task 0 rebase: `HEAD..origin/main` is empty at plan time per
the Branch-base freshness section.)

### Task 1: Re-verify Assumption Inventory anchors at implement-time

- `depends_on: []`
- `touches: <read-only — no file edits>`

Steps:

- [ ] **1.1** Re-grep `bin/common.sh` for the Task 7 anchor (A-002):
  the unique substring
  `30) printf 'noop-implementation' ;;` followed by
  `124) printf 'dispatch-timeout' ;;`. Both substrings MUST appear
  exactly once and on consecutive lines. Halt on drift via
  `bash bin/pipeline.sh event ENG-106 verdict halt --reason agent-blocked`
  + a Linear comment naming the drift.
- [ ] **1.2** Re-grep `bin/dispatch.sh` for the Task 8 anchor (A-003):
  the literal multi-line block ending the `core.bare` for-loop and
  the function's closing brace. The block
  ```
        return 13
      fi
    done
  }
  
  # ENG-48 isolation: platform tools whose call from a headless dispatch
  ```
  MUST match exactly once. Halt-on-drift.
- [ ] **1.3** Re-grep `bin/render-prompt.sh` for the Task 2 anchor
  (A-007): the literal line `review_findings=_resolve_review_findings`
  followed by the closing `'`. MUST match exactly once.
- [ ] **1.4** Re-grep `bin/render-prompt.sh` for the Task 3 anchor
  (A-008): the literal line
  `_resolve_stage_summary_path() { printf '%s' "$_RENDER_STAGE_SUMMARY_PATH"; }`.
  MUST match exactly once.
- [ ] **1.5** Re-grep `bin/render-prompt.sh` for the Task 4 anchors
  (A-009): two distinct unique substrings —
  `stage_summary_path="$(issue_dir "$issue_id")/stage-summary-${stage}.md"`
  at ~line 389, AND the two-line block
  ```
  _RENDER_STAGE_SUMMARY_PATH="$stage_summary_path"
  _RENDER_LEARNED_RULES_DIR="$learned_rules_dir"
  ```
  at ~lines 413–414. Both MUST match exactly once.
- [ ] **1.6** Re-grep `bin/run-stage.sh` for the Task 10 anchor
  (A-006): the literal substring
  ```
      classify_failure "$ident" "$stage" "skip-until-human-acts" \
        "stage transcript invoked forbidden core.bare git form: $_viol_cmd_13" 13
      rm -f "$_viol_file_13" "$prompt_file"
      exit 13
    elif (( dispatch_rc != 0 )); then
  ```
  MUST match exactly once.
- [ ] **1.7** Re-grep `AGENT_PROMPTS.md` for the Task 5 anchor
  (A-010): the literal line
  `5. **Write the stage summary file** at `{stage_summary_path}` — LAST step, MANDATORY.`
  MUST match exactly once.
- [ ] **1.8** Re-grep `bin/dispatch-test.sh` for the Task 11 anchor
  (A-012): the literal line
  `# ─── Summary ────────────────────────────────────────────────────────────`.
  MUST match exactly once.
- [ ] **1.9** Confirm `docs/runbooks/recovery.md` exists; identify the
  current last-numbered section by reading the file's H2 headings
  (`grep '^## ' docs/runbooks/recovery.md`). Record the next free
  section number for Task 12's new section.

If all sub-steps pass, proceed to Tasks 2 / 3 / 4 / 5 / 6 / 7 / 8 /
9 / 10 / 11 / 12 / 13.

### Task 2: Register `progress_md_path` in PROMPT_RESOLVERS

- `depends_on: [1]`
- `touches: bin/render-prompt.sh::PROMPT_RESOLVERS` — one new row appended
  to the heredoc literal at lines 41–55.

Steps:

- [ ] **2.1** Use a single `Edit` call. `old_string` is the literal
  unique two-line block:
  ```
  review_findings=_resolve_review_findings
  '
  ```
  `new_string` is the same block with one new row inserted between
  the `review_findings=` row and the closing `'`:
  ```
  review_findings=_resolve_review_findings
  progress_md_path=_resolve_progress_md_path
  '
  ```
  Notes:
  - Position is at the END of the registry (matches the ENG-107
    convention of appending new entries chronologically — same as
    `progress_md_path` going at the END of `export -f` per the
    grouped-export pattern in `bin/common.sh:400`).
  - No trailing whitespace; column-0 alignment; one row per line.
- [ ] **2.2** Verify by reading back the modified region. Confirm
  the new row is the SECOND-to-last line of the heredoc literal
  (immediately above the closing `'`).

### Task 3: Add `_resolve_progress_md_path` function

- `depends_on: [1]`
- `touches: bin/render-prompt.sh::_resolve_progress_md_path` — new 1-line
  resolver function inserted directly after `_resolve_stage_summary_path`
  at line 226.

Steps:

- [ ] **3.1** Use a single `Edit` call. `old_string` is the literal
  unique line:
  ```
  _resolve_stage_summary_path() { printf '%s' "$_RENDER_STAGE_SUMMARY_PATH"; }
  ```
  `new_string` is the same line followed by the new resolver:
  ```
  _resolve_stage_summary_path() { printf '%s' "$_RENDER_STAGE_SUMMARY_PATH"; }
  _resolve_progress_md_path() { printf '%s' "$_RENDER_PROGRESS_MD_PATH"; }
  ```
  Notes:
  - Mirrors `_resolve_stage_summary_path`'s 1-line shape exactly
    (D-004 / ENG-79 single-helper precedent / brainstorm A12).
  - The resolver-side global is `_RENDER_PROGRESS_MD_PATH`; Task 4
    binds it before `resolve_block_tokens` runs.
- [ ] **3.2** Verify by reading back. Confirm
  `_resolve_progress_md_path` appears on the SINGLE LINE immediately
  after `_resolve_stage_summary_path`.

### Task 4: Bind `_RENDER_PROGRESS_MD_PATH` in render-prompt.sh::main

- `depends_on: [1]`
- `touches: bin/render-prompt.sh::main` — one local-variable resolve next
  to the existing `stage_summary_path=...` resolve at ~line 389 AND one
  `_RENDER_PROGRESS_MD_PATH=...` bind between
  `_RENDER_STAGE_SUMMARY_PATH=` and `_RENDER_LEARNED_RULES_DIR=` at
  ~lines 413–414.

Steps:

- [ ] **4.1** Use a single `Edit` call (or two sequential Edits if
  the implement agent prefers tightly-scoped boundaries).

  First Edit anchors on the existing `stage_summary_path=` resolve
  line and the immediate `learned_rules_dir=` resolve line:
  ```
  stage_summary_path="$(issue_dir "$issue_id")/stage-summary-${stage}.md"
  learned_rules_dir="$HARNESS_ROOT/learned-rules/$PROJECT_SLUG"
  ```
  Replacement:
  ```
  stage_summary_path="$(issue_dir "$issue_id")/stage-summary-${stage}.md"
  progress_md_path="$(progress_md_path "$issue_id")"
  learned_rules_dir="$HARNESS_ROOT/learned-rules/$PROJECT_SLUG"
  ```
  Notes:
  - The local-variable name (`progress_md_path`) intentionally
    shadows the helper-function name in this scope, then is read by
    `_RENDER_PROGRESS_MD_PATH="$progress_md_path"`. Bash's
    parameter-vs-function lookup distinguishes the two — direct
    pattern from `stage_summary_path` / `branch_name` (which is
    BOTH a local var here and a function in `bin/branch-name.sh`).
  - The helper-function call `$(progress_md_path "$issue_id")` is
    valid because `bin/common.sh` is sourced at line 11 and
    `progress_md_path` is on the `export -f` list at
    `bin/common.sh:400` (A-001).

- [ ] **4.2** Second Edit anchors on the existing two-line block
  binding `_RENDER_STAGE_SUMMARY_PATH` and `_RENDER_LEARNED_RULES_DIR`:
  ```
  _RENDER_STAGE_SUMMARY_PATH="$stage_summary_path"
  _RENDER_LEARNED_RULES_DIR="$learned_rules_dir"
  ```
  Replacement:
  ```
  _RENDER_STAGE_SUMMARY_PATH="$stage_summary_path"
  _RENDER_PROGRESS_MD_PATH="$progress_md_path"
  _RENDER_LEARNED_RULES_DIR="$learned_rules_dir"
  ```
- [ ] **4.3** Verify by reading back lines ~388–422. Confirm: (a)
  `progress_md_path="$(progress_md_path "$issue_id")"` is between
  the `stage_summary_path=` and `learned_rules_dir=` lines; (b)
  `_RENDER_PROGRESS_MD_PATH="$progress_md_path"` is between
  `_RENDER_STAGE_SUMMARY_PATH=` and `_RENDER_LEARNED_RULES_DIR=`;
  (c) no other line was altered.

### Task 5: Insert new Completion checklist step 5 in AGENT_PROMPTS.md §2

- `depends_on: [2, 3, 4]`
- `touches: AGENT_PROMPTS.md` §2 Plan Agent Completion checklist —
  one new step inserted between current step 4 and current step 5;
  current steps 5 and 6 renumber to 6 and 7.

Steps:

- [ ] **5.1** Use a single `Edit` call. `old_string` is the
  literal 2-line block at the boundary between step 4's closing
  line and step 5's opening line:
  ```
     knowledge-file changes go through PRs with CODEOWNERS. Do NOT change the Linear stage
     label — the orchestrator swaps it on successful exit.
  5. **Write the stage summary file** at `{stage_summary_path}` — LAST step, MANDATORY.
  ```
  `new_string` inserts the new step 5 in between, renumbering the
  existing step 5 (Write the stage summary file) to 6 (the rest of
  its body remains verbatim — handled by a separate Edit below).

  Replacement:
  ```
     knowledge-file changes go through PRs with CODEOWNERS. Do NOT change the Linear stage
     label — the orchestrator swaps it on successful exit.
  5. **Append a progress.md entry** at `{progress_md_path}`. ONE H2 entry per
     dispatch; this is the ONLY mutation you make to the file. Schema (per
     `docs/runbooks/progress-md.md`):
  
         ## {dispatch_id} - planning - <ISO-8601-UTC-now>
  
         - <one decision or call this plan locks in>
         - <one load-bearing trade-off the plan accepts>
         - <one next-dispatch breadcrumb for the implement agent>
         [3–5 bullets total — under 80 chars each, no prose paragraphs]
  
     **Append, do NOT rewrite.** If the file exists, `Read` it FIRST, then `Write`
     back the prior content followed by ONE blank line followed by your new H2
     entry. Do NOT use `Write` with only the new entry — that truncates and
     discards prior dispatches' entries. Do NOT edit any prior entry. If the
     file does not exist yet, `Write` it with just your single H2 entry.
  
     The orchestrator's post-dispatch detective scans this file. A missing
     entry, more than one entry stamped with your `{dispatch_id}`, or a prior
     entry that's been removed → halt with `progress-md-entry-missing`
     (rc=31, see `docs/runbooks/recovery.md`).
  6. **Write the stage summary file** at `{stage_summary_path}` — LAST step, MANDATORY.
  ```

  Notes:
  - The new step body uses `{progress_md_path}` (resolved by Task 2
    + 3 + 4) and the existing `{dispatch_id}` token (resolved per
    A-022).
  - The 4-space-indented code block inside the bullet (the schema
    example) is markdown for a fenced-block-equivalent rendering; it
    does NOT use ``` fences because AGENT_PROMPTS.md uses ``` only at
    the per-stage outer boundaries (CLAUDE.md "AGENT_PROMPTS.md is
    load-bearing — exactly two fences per stage"). The 4-space-indent
    is the markdown-conformant alternative.
  - The new step body bounds the bullet count (3–5) and the
    per-bullet length (under 80 chars, no prose paragraphs) per
    brainstorm D-003 / AC #1.
  - The renumber from "5." to "6." for the existing step 5 is in
    THIS Edit's `new_string`.

- [ ] **5.2** Renumber the existing step 6 (Post the verdict
  marker) to 7. Use a separate `Edit` call. `old_string` is the
  literal line:
  ```
  6. **Post the verdict marker** (MANDATORY). Post exactly ONE additional
  ```
  `new_string` is the same line with the leading "6." replaced by
  "7.":
  ```
  7. **Post the verdict marker** (MANDATORY). Post exactly ONE additional
  ```
  No other body text changes in step 6 → step 7.

- [ ] **5.3** Verify by reading back lines ~537–636 of
  `AGENT_PROMPTS.md`. Confirm:
  - The header line at line 537 still reads "Completion checklist
    (ordered — do every step in order, and do NOT exit before step
    5)". (The "before step 5" reference in the header refers to the
    SAME relative position — the stage summary write — which is now
    step 6. If the implement agent prefers to update the header
    parenthetical to "before step 6", that is OPTIONAL and noted as
    a NICE-TO-HAVE; the header is read as a soft hint, not a
    machine-readable contract. The orchestrator's per-dispatch
    overwrite-on-every-dispatch contract for the stage-summary file
    is the load-bearing surface, not the header parenthetical.)
  - Steps 1, 2, 3, 4 are unchanged.
  - Step 5 is the new "Append a progress.md entry" step.
  - Step 6 is "Write the stage summary file" (was step 5).
  - Step 7 is "Post the verdict marker" (was step 6).
  - The closing ``` fence at the end of the §2 block is preserved
    verbatim (CLAUDE.md "AGENT_PROMPTS.md is load-bearing —
    `render-prompt.sh` dies if the fence count is not exactly 2").

- [ ] **5.4** Run `bash bin/render-prompt-test.sh` to confirm the
  fence count is still 2 for §2. If FAIL, the Edit corrupted the
  fence structure; revert and re-apply.

### Task 6: Add a render-prompt-test.sh row for `{progress_md_path}` resolution

- `depends_on: [2, 3, 4]`
- `touches: bin/render-prompt-test.sh` — one new fixture asserting
  `{progress_md_path}` resolves to `_RENDER_PROGRESS_MD_PATH`.

Steps:

- [ ] **6.1** Locate the existing fixture for
  `{stage_summary_path}` in `bin/render-prompt-test.sh` (search
  with `Grep '{stage_summary_path}\|_RENDER_STAGE_SUMMARY_PATH'`).
  Use it as the template — same `_RENDER_*=...; resolve_block_tokens
  ...; assert ...` shape.
- [ ] **6.2** Use a single `Edit` call inserting the new fixture
  directly AFTER the existing `{stage_summary_path}` fixture. The
  new fixture's expected resolved value is an arbitrary test path
  (e.g., `/tmp/test/ENG-T/progress.md`), set via
  `_RENDER_PROGRESS_MD_PATH=...`; the rendered prompt body uses the
  literal token `{progress_md_path}`; the assertion is that the
  rendered output contains the expected path string.
  - Notes: this is a NICE-TO-HAVE coverage extension per A-020, not
    a closure defect. If `bin/render-prompt-test.sh` does NOT
    currently have a `{stage_summary_path}` fixture (Task 6.1
    returns no template), this task is SKIPPED with a one-line
    comment in the implement agent's progress.md entry. The plan's
    Goal 1 (PG1–PG6 in dispatch-test.sh) and Goal 4 (real-dispatch
    end-to-end) are unaffected by this task's presence.
- [ ] **6.3** Verify by running `bash bin/render-prompt-test.sh`.
  Expect exit 0 with the new row passing.

### Task 7: Add `31)` arm to `failure_outcome_for_exit`

- `depends_on: [1]`
- `touches: bin/common.sh::failure_outcome_for_exit` — one new case
  arm between `30)` and `124)` at lines 246–247.

Steps:

- [ ] **7.1** Use a single `Edit` call. `old_string` is the literal
  unique 2-line block:
  ```
      30) printf 'noop-implementation' ;;
      124) printf 'dispatch-timeout' ;;
  ```
  `new_string` inserts the new arm:
  ```
      30) printf 'noop-implementation' ;;
      31) printf 'progress-md-entry-missing' ;;
      124) printf 'dispatch-timeout' ;;
  ```
  Notes:
  - Indentation: 4 spaces (matches the surrounding case arms — `bin/common.sh:231-247`).
  - Token: `progress-md-entry-missing` (per brainstorm D-006). Hyphen-separated,
    no spaces. Mirrors `branch-creation-forbidden`,
    `worktree-mutation-forbidden`, `agent-contract-missing`.
- [ ] **7.2** Verify by reading back lines ~243–248. Confirm the
  new arm sits between `30)` and `124)`.
- [ ] **7.3** OPTIONAL: confirm `bash bin/common-test.sh` exits 0.
  If the test file contains a row that exhaustively iterates the
  taxonomy (matching the ENG-65 fixture shape), add a new row for
  exit code 31. If no such row exists, no test change is needed.

### Task 8: Insert stage-gated call to `_assert_progress_md_entry` in `_render_and_capture_stream`

- `depends_on: [1, 9]`
- `touches: bin/dispatch.sh::_render_and_capture_stream` — one new
  3-line stage-gated block at the end of the function, AFTER the
  core.bare for-loop's closing `done` and BEFORE the function's
  closing `}`.

Notes on task ordering: Task 9 (helper definition) is done FIRST so
that the symbol `_assert_progress_md_entry` exists when Task 8
inserts the call. Bash sources sequentially; if Task 8 is applied
first the file is briefly in a state where the function references
an undefined symbol, but `bash -n` will not catch the issue (Bash
resolves functions at call time, not parse time), and the
intermediate test run between Tasks 8 and 9 would fail — so do
Task 9 first.

Steps:

- [ ] **8.1** Use a single `Edit` call. `old_string` is the
  literal multi-line block at the end of `_render_and_capture_stream`:
  ```
        return 13
      fi
    done
  }
  ```
  `new_string` inserts the new stage-gated call before the closing
  `}`:
  ```
        return 13
      fi
    done
    # ENG-106: filesystem detective — confirm the plan agent appended
    # one well-formed progress.md H2 entry stamped with the current
    # PIPELINE_DISPATCH_ID. Stage-gated to "planning" only (other stages
    # have no contractual writer yet — see brainstorm OQ-3). Unlike the
    # transcript-scan detectives above, this is a FILESYSTEM check
    # (brainstorm D-005). Helper defined directly below this function;
    # writes its diagnostic to $violation_file and returns 0 / 31.
    if [[ "$stage" == "planning" ]]; then
      if ! _assert_progress_md_entry "$issue_dir" "$violation_file"; then
        return 31
      fi
    fi
  }
  ```
  Notes:
  - The block sits AFTER the four existing transcript-scan blocks
    (ENG-43, ENG-71, ENG-66, ENG-68) so detection ordering follows
    transcript scans → filesystem check.
  - `$violation_file` and `$issue_dir` are local to
    `_render_and_capture_stream` (per A-004). The helper receives
    both as positional arguments, no env var smuggling.
  - rc=31 is the new exit code (brainstorm D-006 / Task 7).
- [ ] **8.2** Verify by reading back lines ~233–245 of
  `bin/dispatch.sh`. Confirm: (a) the rc=13 closing `done` and `fi`
  are preserved verbatim; (b) the new stage-gated block sits between
  the `done` and the closing `}` of `_render_and_capture_stream`;
  (c) the closing `}` of `_render_and_capture_stream` is preserved
  verbatim.
- [ ] **8.3** Run `bash -n bin/dispatch.sh` for the syntax-only
  check. Expect rc=0.

### Task 9: Define `_assert_progress_md_entry` private helper

- `depends_on: [1]`
- `touches: bin/dispatch.sh::_assert_progress_md_entry` — new
  ~15-line helper inserted between the closing `}` of
  `_render_and_capture_stream` (line 236) and the
  `# ENG-48 isolation:` comment header preceding
  `disallowed_platform_tools` (line 238).

Steps:

- [ ] **9.1** Use a single `Edit` call. `old_string` is the
  literal unique 4-line block at the boundary between
  `_render_and_capture_stream`'s closing brace and the next
  declaration:
  ```
    done
  }
  
  # ENG-48 isolation: platform tools whose call from a headless dispatch
  ```
  `new_string` inserts the new helper between the closing brace
  and the comment header (preserving both verbatim):
  ```
    done
  }
  
  # ENG-106: filesystem detective for the plan-stage progress.md writer.
  # Stage-gated caller at the end of _render_and_capture_stream invokes
  # this helper only when $stage == "planning". Reads PIPELINE_DISPATCH_ID
  # from env (single-dash idiom — ENG-46 secret-probe-lint clean; the
  # var name is not on the secret regex). Returns 0 if the file contains
  # exactly one H2 entry stamped with the current dispatch_id; returns
  # 31 with a diagnostic written to $violation_file otherwise. Direct
  # caller, no Linear or git surface — pure filesystem check.
  _assert_progress_md_entry() {
    local issue_dir="$1" violation_file="$2"
    local progress_path entry_count
    progress_path="${issue_dir}/progress.md"
    if [[ ! -s "$progress_path" ]]; then
      printf 'progress.md missing entirely (expected one H2 stamped %s)\n' \
        "${PIPELINE_DISPATCH_ID-<empty>}" > "$violation_file"
      log "[assert] plan-stage progress.md missing for dispatch_id=${PIPELINE_DISPATCH_ID-<empty>}"
      return 31
    fi
    entry_count="$(grep -c "^## ${PIPELINE_DISPATCH_ID-} - " "$progress_path" 2>/dev/null || printf 0)"
    if [[ "$entry_count" != "1" ]]; then
      printf 'progress.md: expected exactly 1 entry for dispatch_id=%s, found %s\n' \
        "${PIPELINE_DISPATCH_ID-<empty>}" "$entry_count" > "$violation_file"
      log "[assert] plan-stage progress.md entry count for ${PIPELINE_DISPATCH_ID-<empty>}: $entry_count (expected 1)"
      return 31
    fi
    return 0
  }
  
  # ENG-48 isolation: platform tools whose call from a headless dispatch
  ```
  Notes:
  - Composes the path inline as `${issue_dir}/progress.md` rather
    than calling `progress_md_path` — the caller already passed
    `$issue_dir`, which is the canonical resolution per A-001 (a
    second `progress_md_path` call would re-trigger the
    `[[ -n "$issue" ]] || die` guard with whatever `PIPELINE_ISSUE_ID`
    holds, fragile for the test path). The brainstorm's pseudo-bash
    (D-005) used `progress_md_path "${PIPELINE_ISSUE_ID-}"` but
    flagged the resulting test ergonomics issue in §5; the actual
    plan resolves the path via `$issue_dir` (which is itself derived
    from `progress_md_path`'s sibling helper `issue_dir`).
  - `${PIPELINE_DISPATCH_ID-}` (single-dash, empty fallback) per
    ENG-46. The env var name does NOT match
    `*KEY|*TOKEN|*SECRET|ANTHROPIC*|GITHUB*|LINEAR*`.
  - `<empty>` literal in the diagnostic message gives the operator a
    distinguishable signature when the env var is unset (e.g., a test
    path that bypasses `allocate_dispatch_id`).
  - `grep -c ... || printf 0` swallows grep's rc=1 on
    no-match (per ENG-46 `${VAR-}` idioms and AS5's malformed-line
    pattern at `bin/dispatch-test.sh:1247-1258`).
  - `log` (from common.sh) is in scope because dispatch.sh sources
    common.sh at line 18 (A-001 / common.sh sourcing).
- [ ] **9.2** Verify by reading back lines ~236–264. Confirm: (a)
  the closing `}` of `_render_and_capture_stream` is preserved
  verbatim; (b) the new helper is defined immediately below it; (c)
  the `# ENG-48 isolation:` comment header is preserved verbatim
  immediately below the helper.
- [ ] **9.3** Run `bash -n bin/dispatch.sh`. Expect rc=0.

### Task 10: Add rc=31 arm to run-stage.sh dispatch-rc dispatch

- `depends_on: [7]`
- `touches: bin/run-stage.sh::main` — one new `elif (( dispatch_rc
  == 31 ))` arm inserted between the rc=13 arm and the catch-all
  `elif (( dispatch_rc != 0 ))` at lines 1393–1394.

Steps:

- [ ] **10.1** Use a single `Edit` call. `old_string` is the
  literal unique 5-line block at the boundary between rc=13's
  `exit 13` and the catch-all:
  ```
      classify_failure "$ident" "$stage" "skip-until-human-acts" \
        "stage transcript invoked forbidden core.bare git form: $_viol_cmd_13" 13
      rm -f "$_viol_file_13" "$prompt_file"
      exit 13
    elif (( dispatch_rc != 0 )); then
  ```
  `new_string` inserts the new arm between `exit 13` and `elif ((
  dispatch_rc != 0 ))`:
  ```
      classify_failure "$ident" "$stage" "skip-until-human-acts" \
        "stage transcript invoked forbidden core.bare git form: $_viol_cmd_13" 13
      rm -f "$_viol_file_13" "$prompt_file"
      exit 13
    elif (( dispatch_rc == 31 )); then
      # ENG-106: plan-stage progress.md detective halt. Read the diagnostic
      # message from $(issue_dir "$ident")/.transcript-violation-${stage}
      # (the sidecar written by _assert_progress_md_entry in dispatch.sh)
      # and surface a skip-until-human-acts halt. Recovery: docs/runbooks/recovery.md.
      local _viol_file_31 _viol_msg_31
      _viol_file_31="$(issue_dir "$ident")/.transcript-violation-${stage}"
      _viol_msg_31="$(cat "$_viol_file_31" 2>/dev/null || printf '<violation-detail-unavailable>')"
      classify_failure "$ident" "$stage" "skip-until-human-acts" \
        "plan-stage progress.md entry missing or malformed: $_viol_msg_31" 31
      rm -f "$_viol_file_31" "$prompt_file"
      exit 31
    elif (( dispatch_rc != 0 )); then
  ```
  Notes:
  - Indentation, `_viol_file_31` / `_viol_msg_31` naming, and
    `classify_failure` shape mirror the rc=13 arm verbatim.
  - The halt message body interpolates `$_viol_msg_31` (from the
    sidecar written by Task 9). Sidecar content is harness-controlled
    (no agent input — the helper writes only the dispatch_id token
    + integer counts).
- [ ] **10.2** Verify by reading back lines ~1389–1410. Confirm:
  (a) rc=13 arm is preserved verbatim; (b) the new rc=31 arm sits
  between rc=13 and the catch-all; (c) the catch-all is preserved
  verbatim.
- [ ] **10.3** Run `bash -n bin/run-stage.sh`. Expect rc=0.

### Task 11: Add PG1–PG6 fixtures to dispatch-test.sh

- `depends_on: [8, 9]`
- `touches: bin/dispatch-test.sh` — one new test group "ENG-106
  PG1–PG6" inserted BEFORE the `# ─── Summary ───` footer at line
  ~3022 per A-012.

Steps:

- [ ] **11.1** Use a single `Edit` call. `old_string` is the
  literal unique line:
  ```
  # ─── Summary ────────────────────────────────────────────────────────────
  ```
  `new_string` inserts the new test group BEFORE this anchor.

  The new block has the following structure (~120 lines total). Each
  fixture (1) sets `PIPELINE_DISPATCH_ID` and `PIPELINE_ISSUE_ID`
  per fixture, (2) creates the progress.md file under
  `$_TEST_STUB_DIR/PG<N>/issue_dir/` with the appropriate content,
  (3) creates a `$_TEST_STUB_DIR/PG<N>/issue_dir/.transcript-violation-planning`
  pre-clean (rm -f), (4) invokes
  `_assert_progress_md_entry "$_TEST_STUB_DIR/PG<N>/issue_dir"
  "$_TEST_STUB_DIR/PG<N>/issue_dir/.transcript-violation-planning"`
  and captures rc, (5) asserts rc matches expected AND violation_file
  content matches expected (per the brainstorm's fixture table at
  §2 D-007):

  ```bash
  # ─── ENG-106 PG1–PG6: progress.md detective fixtures ─────────────────
  # Per brainstorm D-007 — synthesised post-stream filesystem state.
  # Each fixture invokes _assert_progress_md_entry directly (AS1-AS6
  # pattern at line 1189-1268). No claude -p invocation; no
  # _render_and_capture_stream end-to-end (DRY_RUN bypass per A-016).
  printf '\n--- ENG-106 PG1-PG6: progress.md detective fixtures ---\n'
  
  _PG_HELPER_PRESENT=1
  if ! declare -f _assert_progress_md_entry >/dev/null 2>&1; then
    fail_at "precondition: _assert_progress_md_entry defined in dispatch.sh" \
            "function not found after sourcing — Task 9 implementation missing"
    _PG_HELPER_PRESENT=0
  fi
  
  if [[ "$_PG_HELPER_PRESENT" == "1" ]]; then
    # PG1 — well-formed single entry → rc=0, no violation
    PG1_DIR="$_TEST_STUB_DIR/PG1"; mkdir -p "$PG1_DIR"
    export PIPELINE_DISPATCH_ID="ENG-T-PG1-d0001"
    export PIPELINE_ISSUE_ID="ENG-T-PG1"
    cat > "$PG1_DIR/progress.md" <<'MD'
  ## ENG-T-PG1-d0001 - planning - 2026-05-16T12:00:00Z
  
  - decision bullet
  - trade-off bullet
  - breadcrumb bullet
  MD
    rm -f "$PG1_DIR/.transcript-violation-planning"
    _assert_progress_md_entry "$PG1_DIR" "$PG1_DIR/.transcript-violation-planning" && rc_pg1=0 || rc_pg1=$?
    if [[ "$rc_pg1" == "0" && ! -s "$PG1_DIR/.transcript-violation-planning" ]]; then
      pass_at "PG1: well-formed single entry → rc=0, no violation"
    else
      fail_at "PG1" "rc=$rc_pg1 violation=$(cat "$PG1_DIR/.transcript-violation-planning" 2>/dev/null || echo '<none>')"
    fi
  
    # PG2 — file missing entirely → rc=31, "missing entirely" diagnostic
    PG2_DIR="$_TEST_STUB_DIR/PG2"; mkdir -p "$PG2_DIR"
    export PIPELINE_DISPATCH_ID="ENG-T-PG2-d0001"
    export PIPELINE_ISSUE_ID="ENG-T-PG2"
    rm -f "$PG2_DIR/progress.md" "$PG2_DIR/.transcript-violation-planning"
    _assert_progress_md_entry "$PG2_DIR" "$PG2_DIR/.transcript-violation-planning" && rc_pg2=0 || rc_pg2=$?
    if [[ "$rc_pg2" == "31" ]] && grep -q "missing entirely" "$PG2_DIR/.transcript-violation-planning"; then
      pass_at "PG2: file missing → rc=31 + 'missing entirely' diagnostic"
    else
      fail_at "PG2" "rc=$rc_pg2 violation=$(cat "$PG2_DIR/.transcript-violation-planning" 2>/dev/null || echo '<none>')"
    fi
  
    # PG3 — two prior entries + one current → rc=0 (append succeeded)
    PG3_DIR="$_TEST_STUB_DIR/PG3"; mkdir -p "$PG3_DIR"
    export PIPELINE_DISPATCH_ID="ENG-T-PG3-d0003"
    export PIPELINE_ISSUE_ID="ENG-T-PG3"
    cat > "$PG3_DIR/progress.md" <<'MD'
  ## ENG-T-PG3-d0001 - planning - 2026-05-14T12:00:00Z
  
  - prior-1
  
  ## ENG-T-PG3-d0002 - planning - 2026-05-15T12:00:00Z
  
  - prior-2
  
  ## ENG-T-PG3-d0003 - planning - 2026-05-16T12:00:00Z
  
  - current
  MD
    rm -f "$PG3_DIR/.transcript-violation-planning"
    _assert_progress_md_entry "$PG3_DIR" "$PG3_DIR/.transcript-violation-planning" && rc_pg3=0 || rc_pg3=$?
    if [[ "$rc_pg3" == "0" && ! -s "$PG3_DIR/.transcript-violation-planning" ]]; then
      pass_at "PG3: prior entries preserved + new entry → rc=0"
    else
      fail_at "PG3" "rc=$rc_pg3 violation=$(cat "$PG3_DIR/.transcript-violation-planning" 2>/dev/null || echo '<none>')"
    fi
  
    # PG4 — file exists, zero entries for current id → rc=31, "found 0"
    PG4_DIR="$_TEST_STUB_DIR/PG4"; mkdir -p "$PG4_DIR"
    export PIPELINE_DISPATCH_ID="ENG-T-PG4-d0002"
    export PIPELINE_ISSUE_ID="ENG-T-PG4"
    cat > "$PG4_DIR/progress.md" <<'MD'
  ## ENG-T-PG4-d0001 - planning - 2026-05-14T12:00:00Z
  
  - prior-1
  MD
    rm -f "$PG4_DIR/.transcript-violation-planning"
    _assert_progress_md_entry "$PG4_DIR" "$PG4_DIR/.transcript-violation-planning" && rc_pg4=0 || rc_pg4=$?
    if [[ "$rc_pg4" == "31" ]] && grep -q "found 0" "$PG4_DIR/.transcript-violation-planning"; then
      pass_at "PG4: zero matches for current id → rc=31 + 'found 0'"
    else
      fail_at "PG4" "rc=$rc_pg4 violation=$(cat "$PG4_DIR/.transcript-violation-planning" 2>/dev/null || echo '<none>')"
    fi
  
    # PG5 — two entries for current id (agent double-wrote) → rc=31, "found 2"
    PG5_DIR="$_TEST_STUB_DIR/PG5"; mkdir -p "$PG5_DIR"
    export PIPELINE_DISPATCH_ID="ENG-T-PG5-d0001"
    export PIPELINE_ISSUE_ID="ENG-T-PG5"
    cat > "$PG5_DIR/progress.md" <<'MD'
  ## ENG-T-PG5-d0001 - planning - 2026-05-16T12:00:00Z
  
  - first
  
  ## ENG-T-PG5-d0001 - planning - 2026-05-16T12:01:00Z
  
  - duplicate
  MD
    rm -f "$PG5_DIR/.transcript-violation-planning"
    _assert_progress_md_entry "$PG5_DIR" "$PG5_DIR/.transcript-violation-planning" && rc_pg5=0 || rc_pg5=$?
    if [[ "$rc_pg5" == "31" ]] && grep -q "found 2" "$PG5_DIR/.transcript-violation-planning"; then
      pass_at "PG5: two entries for current id → rc=31 + 'found 2'"
    else
      fail_at "PG5" "rc=$rc_pg5 violation=$(cat "$PG5_DIR/.transcript-violation-planning" 2>/dev/null || echo '<none>')"
    fi
  
    # PG6 — stage-gate is enforced at the CALLER (_render_and_capture_stream).
    # The helper itself is stage-agnostic — it never returns 0 just because
    # we tell it the stage isn't planning. Pin the CALLER's stage-gate via
    # _render_and_capture_stream's renderer behaviour: the existing CB1-CB8
    # group exercises the stage-gated branching for ENG-68; PG6 is covered
    # by the absence of an _assert_progress_md_entry invocation when stage
    # != "planning" (i.e., grep the implementation at Task 8 — `if [[
    # "$stage" == "planning" ]] then ... fi`). We pin the contract here at
    # the helper level by confirming that PG6 (zero file present, but the
    # caller never invokes us) is logically equivalent to PG2's failure
    # mode — i.e., the helper would fail if invoked, but the caller's
    # gate prevents invocation.
    #
    # Concretely, PG6 asserts the stage-gate via a static grep of
    # bin/dispatch.sh: confirm the call sits inside an `if [[ "$stage"
    # == "planning" ]]` block immediately before the function's closing
    # brace.
    if grep -q 'if \[\[ "$stage" == "planning" \]\]; then' "$SCRIPT_DIR/dispatch.sh" \
       && grep -q '_assert_progress_md_entry' "$SCRIPT_DIR/dispatch.sh"; then
      pass_at "PG6: dispatch.sh stage-gates _assert_progress_md_entry on planning"
    else
      fail_at "PG6" "dispatch.sh missing planning-stage gate around _assert_progress_md_entry"
    fi
  
    # Cleanup PIPELINE_DISPATCH_ID/PIPELINE_ISSUE_ID exports so later tests
    # don't see them.
    unset PIPELINE_DISPATCH_ID PIPELINE_ISSUE_ID
  fi
  ```

  Notes:
  - Each fixture's directory is under `$_TEST_STUB_DIR/PG<N>` so
    `_test_safe_rm` in the EXIT trap (line 42) cleans them up.
  - The `<<'MD'` quoted heredocs prevent variable expansion (per
    CLAUDE.md secret-handling preamble; also matches AS1-AS6's
    `<<'NDJSON'` pattern).
  - PG6 is a static-grep check, NOT a function-call check — the
    stage-gate lives in `_render_and_capture_stream`, not in the
    helper itself. A direct function call with `stage` unset would
    still fire the missing-file path (the helper has no stage
    parameter and is correctly stage-agnostic on its own).
  - Each fixture passes `$PG<N>_DIR` as the helper's first
    positional argument (the `$issue_dir` parameter from
    `_render_and_capture_stream`'s signature at A-004). The second
    argument is the violation_file path under the same directory.
  - Test fixtures use `2026-05-14`/`2026-05-15`/`2026-05-16` for
    timestamps — distinct dates so a future debugger can tell which
    fixture wrote which entry on inspection.

- [ ] **11.2** Verify by reading back lines ~3022–3145 of
  `bin/dispatch-test.sh`. Confirm: (a) the existing `─── Summary
  ───` block is preserved verbatim AFTER the new fixtures; (b) the
  new fixtures appear immediately before the Summary block; (c) each
  fixture's `pass_at` / `fail_at` calls use the established message
  shape.
- [ ] **11.3** Run `bash bin/dispatch-test.sh`. Expect exit 0 with
  PG1–PG6 rows passing AND all pre-existing tests passing
  unchanged.

### Task 12: Add rc=31 section to docs/runbooks/recovery.md

- `depends_on: [1]`
- `touches: docs/runbooks/recovery.md` — one new section.

Steps:

- [ ] **12.1** Re-grep `docs/runbooks/recovery.md` (per Task 1.9)
  for the section anchors. Identify the current last numbered
  section (likely §7 per A-014, but Task 1.9 confirms the actual
  number). Identify whether a rc=29 section exists today (per
  ENG-87) to mirror its shape.
- [ ] **12.2** Use a single `Edit` call to insert the new section
  AFTER the last existing numbered section. `old_string` is the
  END-OF-FILE marker (or the last paragraph's literal closing
  line). `new_string` appends the new section using this template
  (the actual section number resolves from Task 12.1):

  ```markdown
  ## §<N>. rc=31 — `progress-md-entry-missing` (plan-stage progress.md detective halt)

  **Symptom.** Plan dispatch returned 31; issue carries `pipeline:halted`
  + `pipeline:skip-until-human-acts`. The Linear halt comment body
  reads `plan-stage progress.md entry missing or malformed:
  progress.md missing entirely (expected one H2 stamped <id>)` OR
  `progress.md: expected exactly 1 entry for dispatch_id=<id>, found
  <n>`.

  **Cause.** ENG-106 ships a filesystem detective at the end of
  `bin/dispatch.sh::_render_and_capture_stream` (stage-gated to
  `planning`). After every plan dispatch it greps the per-issue
  `progress.md` (at `$(issue_dir <ident>)/progress.md`) for exactly
  one H2 entry stamped with the current `PIPELINE_DISPATCH_ID`. A
  missing file, zero matches, or ≥2 matches halts with rc=31.

  **Recovery.**

  1. Inspect the per-stage log: `$PROJECT_STATE_DIR/<slug>/logs/<ident>-planning-*.log` for the
     `[assert] plan-stage progress.md ...` line and the
     `$(issue_dir <ident>)/.transcript-violation-planning` sidecar
     for the diagnostic message.
  2. Inspect `$(issue_dir <ident>)/progress.md` (use `bash bin/common.sh`
     `progress_md_path <ident>` to resolve the exact path) and
     confirm the on-disk state matches the diagnostic.
  3. Decide based on cause:
     - **Agent skipped step 5 of AGENT_PROMPTS.md §2 Completion
       checklist** (most common): run
       `bash bin/pipeline.sh decide <ident> --action continue`.
       The orchestrator clears the halt labels and re-dispatches;
       a fresh `PIPELINE_DISPATCH_ID` is allocated and the next
       plan agent must satisfy the detective.
     - **Prompt bug** (the AGENT_PROMPTS.md §2 step 5 instruction
       is ambiguous or has a typo): edit AGENT_PROMPTS.md, commit
       on `main`, then `bash bin/pipeline.sh decide <ident> --action
       continue`. The `pipeline_content_hash` change in
       `bin/poll.sh` may un-skip the issue without a manual decide;
       the explicit decide is idempotent and the recommended path.
     - **Detective false positive** (rare — the file IS present
       and well-formed by manual inspection but the detective
       halted): file a follow-up ticket. Until fix, unhalt manually
       via the decide path; the detective will re-fire on the next
       dispatch.

  **Forensic note.** ENG-87's `dispatch_history.jsonl` (at
  `$(issue_dir <ident>)/dispatch_history.jsonl`) captures the
  rc=31 start/end rows; the prior dispatch's halt comment is
  visible in Linear with its `<!-- meta: dispatch id=... -->`
  marker (filtered out by `find_fresh_verdict` after resume per
  ENG-87 D-005 strict id-match).
  ```

- [ ] **12.3** Verify by reading back the appended section.
  Confirm the section number is correct (matches Task 12.1's free
  slot), the section header uses `## §<N>.` markdown shape (mirrors
  existing sections), and the recovery recipe references
  `bash bin/pipeline.sh decide <ident> --action continue` verbatim
  (the canonical recovery path per CLAUDE.md).

### Task 13: Run gates

- `depends_on: [2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]`
- `touches: <runtime gates only — no file edits>`

Steps:

- [ ] **13.1** Run `bash bin/dispatch-test.sh`. Expect exit 0 with
  PG1–PG6 rows passing AND every pre-existing row passing unchanged.
  If FAIL on PG1–PG6, diagnose against Tasks 8/9/11 (most likely
  cause: helper return value, grep pattern, fixture content).
- [ ] **13.2** Run `bash bin/common-test.sh`. Expect exit 0
  (failure_outcome_for_exit taxonomy unchanged in behavior; the new
  arm only ADDS code 31 mapping).
- [ ] **13.3** Run `bash bin/render-prompt-test.sh`. Expect exit 0
  including the new `{progress_md_path}` resolution row from Task 6
  (or unchanged if Task 6 was skipped per A-020 / Task 6.1's
  template-not-found branch).
- [ ] **13.4** Run `bash .githooks/pre-commit`. Expect exit 0
  (entire `bin/*-test.sh` suite green). The implementing-stage
  allowlist includes `Bash(bash .githooks/pre-commit:*)` per the
  harness profile.
- [ ] **13.5** Run `bash -n` on each touched bash file:
  `bin/dispatch.sh`, `bin/render-prompt.sh`, `bin/run-stage.sh`,
  `bin/common.sh`, `bin/dispatch-test.sh`. Each MUST return rc=0.

If 13.1, 13.2, 13.3, 13.4, 13.5 all pass, the implementation is
complete. The implement agent commits with message
`feat(eng-106): progress.md plan-stage writer pilot` and proceeds
to ENG-106's review stage.

## Frontend Tasks

(no UI surface — the harness is a Bash orchestration toolkit; the
UI Agent is skipped for this ticket per the orchestrator's per-stage
routing.)

## Failure Mode → Test Map

Pulled from the brainstorm's §5 "Error Handling" + §6 "Edge Cases"
sections.

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
|---|---|---|---|---|
| Plan agent omitted step 5 entirely; progress.md does not exist | Plan agent's transcript shows no `Write` against the resolved `{progress_md_path}` token | `_assert_progress_md_entry` finds file absent; writes "missing entirely" diagnostic to sidecar; returns 31. `run-stage.sh` rc=31 arm classifies skip-until-human-acts, exit 31. Orchestrator applies `pipeline:halted`. | unit | PG2 (`bin/dispatch-test.sh`) |
| Plan agent wrote the file but used a wrong heading shape | Heading uses `===` underline or `#`/`###` instead of `##`, OR uses non-ASCII separator (`—`), OR places dispatch_id at non-first token | `_assert_progress_md_entry` greps `^## $PIPELINE_DISPATCH_ID - ` (column-0 + space-hyphen-space) and finds 0 matches; rc=31; sidecar diagnostic `"found 0"` | unit | PG4 (`bin/dispatch-test.sh`) |
| Plan agent emitted the heading twice (e.g., double-wrote on re-Read in same dispatch) | Two H2 lines match current dispatch_id | rc=31; sidecar diagnostic `"found 2"` | unit | PG5 (`bin/dispatch-test.sh`) |
| Plan agent wrote correctly on first dispatch | progress.md has exactly one H2 entry matching current dispatch_id | rc=0; no sidecar | unit | PG1 (`bin/dispatch-test.sh`) |
| Plan agent appended after prior dispatches' entries | progress.md has ≥1 prior entries with different dispatch_ids PLUS one current entry | rc=0; no sidecar (prior entries are not parsed, only counted by current-id matches) | unit | PG3 (`bin/dispatch-test.sh`) |
| Detector inert on non-planning stages | Stage = `brainstorming` (or any non-planning stage); progress.md absent | `_render_and_capture_stream`'s stage-gate branch SKIPS the helper invocation entirely; rc=0 from the function (no return 31). | unit (static grep) | PG6 (`bin/dispatch-test.sh`) |
| `PIPELINE_DISPATCH_ID` unset/empty at detective time | Test path that bypasses `allocate_dispatch_id`; or a real dispatch where the env-var propagation breaks (ENG-87 M6 regression) | `${PIPELINE_DISPATCH_ID-}` resolves to empty string; the `grep` pattern becomes `^##  - ` (literal "## space space hyphen space"); no real H2 matches; rc=31 with diagnostic showing `<empty>` so operator can see the env break | indirectly covered by PG2 (file-missing branch hits the same `<empty>` substitution); additional adversarial fixture deferred | covered by PG2's `<empty>` literal in diagnostic |
| Stage-summary file overwritten on every dispatch (existing contract) | Plan agent ALSO overwrites `stage-summary-planning.md` per the §0 contract — verified by the agent contract validator at `bin/run-stage.sh:1594-1616` | rc=25 if BOTH stage-summary and verdict marker are missing; rc=0 if at least one is present. (Unchanged by this plan; covered by existing agent-contract validator tests.) | integration (existing) | covered by existing `bin/run-stage-test.sh` |
| rc=31 arm in run-stage.sh missing | Task 10 omitted | dispatch_rc=31 falls through to the catch-all `elif (( dispatch_rc != 0 ))` which classifies as `retry-immediately` + `dispatch-failed` exit 20. Wrong policy (retry-immediately on a protocol issue). Halt taxonomy outcome is `dispatch-failed` not `progress-md-entry-missing`. | unit (gate-via-grep — Task 10 verifies the arm exists) | covered by Task 1.6 + Task 10.2 manual read-back; no automated fixture (the run-stage.sh dispatch-rc dispatch table has no pre-existing per-arm fixture) |
| Sub-agent debris (a fixture file written outside the allowlist) | Plan agent writes `.fixture.md` or similar at the worktree root | `bin/run-local.sh`'s `partition_dirty_paths` classifies as self-leak; soft fail incrementing `.consecutive-failures` | integration (existing) | covered by existing `bin/run-local-sweep-test.sh` |
| Detective false positive (file is present and well-formed but rc=31 fires) | Hypothetical bug in `_assert_progress_md_entry`'s grep — `^##` regex anchoring drift, or sidecar write failure | rc=31 with sidecar content that an operator can manually verify against the file. Operator inspects file, runs `--action continue`, files follow-up ticket. | manual (operator inspection per docs/runbooks/recovery.md §<N>) | covered by Task 12's recovery doc |
| Dispatch envelope violation (mcp__plugin_linear or curl https://api.linear.app) | Agent bypasses bin/linear.sh | ENG-87 `_validate_dispatch_envelope` returns rc=29 BEFORE our rc=31 arm fires. Two independent halt paths, mutually exclusive. | integration (existing) | covered by existing ENG-87 envelope-validator fixtures |

(Schema body content quality — whether the agent's 3–5 bullets are
USEFUL — is NOT in scope per brainstorm §10.5 Product. Operator
inspection of the first few dispatches' written entries is the
recommended diagnostic; iterate the prompt accordingly. No
automated body-quality check ships.)

## Test Strategy

- **Unit (new — PG1–PG6).** Six fixtures in `bin/dispatch-test.sh`
  exercising `_assert_progress_md_entry` directly. Pattern mirrors
  AS1-AS6 (synthesise file state → call helper → assert rc + sidecar
  content). The fixtures cover: well-formed pass (PG1), missing file
  (PG2), multi-entry preserve (PG3), zero-match (PG4), double-write
  (PG5), and stage-gate static check (PG6).

- **Unit (new — render-prompt.sh row).** A nice-to-have row in
  `bin/render-prompt-test.sh` confirming `{progress_md_path}`
  resolves under `_RENDER_PROGRESS_MD_PATH`. SKIPPED if Task 6.1's
  pre-condition (existing `{stage_summary_path}` fixture template)
  is not present — the orchestrator's real-dispatch end-to-end
  exercises the resolution.

- **Unit (existing — re-run as gate).** `bin/common-test.sh`
  re-runs unchanged in Task 13.2. Pre-existing rows for
  `is_orchestrator_paused`, `allocate_dispatch_id`,
  `progress_md_path`, `try_acquire_lock`, and the
  `failure_outcome_for_exit` taxonomy table (if present) stay green.
  The new `31)` arm in `failure_outcome_for_exit` is
  backwards-compatible — every other case arm is preserved verbatim.

- **Integration (existing — re-run as gate).** `.githooks/pre-commit`
  in Task 13.4 runs the entire `bin/*-test.sh` suite. The relevant
  sibling tests for an unintended regression include:
  - `bin/render-prompt-test.sh` (verifies AGENT_PROMPTS.md fence
    count and token resolution — Task 5 adds one new step body which
    MUST stay inside §2's fenced block; Task 5.4 explicitly gates on
    the fence count).
  - `bin/run-stage-test.sh` (verifies `_clear_current_stage_slots`
    enumerates exactly the documented set — unchanged by this plan).
  - `bin/dispatch-test.sh` itself in its existing AS1-AS6 / CB1-CB8
    / BC1-BC8 groups (verified unchanged in Task 13.1).
  - `bin/agent-prompts-content-test.sh` (verifies prompt-content
    properties — the new "Append a progress.md entry" step adds
    plain prose to §2, which is what the test expects).

- **End-to-end (manual at first dispatch).** The first real plan
  dispatch after this ticket ships will exercise the full path:
  agent reads the new step 5 → resolves `{progress_md_path}` to a
  per-issue path → appends an entry → detective greps and passes.
  Operator manually inspects the first such written entry on a
  development issue to confirm the prompt drove a useful body (per
  brainstorm §10.5 Product).

- **Adversarial (none new).** The new helper is a 7-line pure
  filesystem composer with two diagnostic branches. There is no
  network surface, no Linear/git/jq dependency, no credential
  surface, no race surface. No adversarial test layer is required
  beyond PG1–PG6.

- **Test-gate closure.** Per A-020, this plan REMOVES no tokens
  from any tracked file. The closure sweep has zero soon-to-be-broken
  pinned-absent assertions to audit. Three new tokens introduced
  (`_assert_progress_md_entry`, `_resolve_progress_md_path`,
  `progress-md-entry-missing`); none is pinned-ABSENT by any
  pre-existing `bin/*-test.sh`. Zero closure defects.

## Persona review

(Self-review summary; full transcripts inlined below.)

| Persona | Verdict | Notes |
|---|---|---|
| Feasibility | PASS · P0=0 | Every named path/symbol/line verified against worktree HEAD; one `assumed` item (A-014 recovery.md section number) is implement-time mechanical. |
| Scope | PASS | All 7 file edits trace to a brainstorm decision; OOS items deferred to ENG-28 sibling sub-tickets per brainstorm §10.3. |
| Coherence | PASS | Exit code 31 + taxonomy entry + `_viol_file_31` naming mirror the existing rc=22/23/26/13 cohort; resolver pattern matches `_resolve_stage_summary_path` precedent; prompt-step shape matches existing §2 Completion checklist idiom. |
| Design | PASS | Detective shape (filesystem vs transcript-scan) explicitly documented at Task 8 inline comment and brainstorm D-005; helper extraction (Task 9) keeps `_render_and_capture_stream` readable. |
| Product | PASS | Pilot delivers ENG-28's first writer at the right scope; AC #1, #2, #3 each map to a Task + fixture; OOS items (reader, other writers) deferred to sibling sub-tickets. |

**Personas: 5/5 PASS · gate P0: 0 · proceeding to implementing.**

### Persona — Feasibility

**Concerns evaluated:** are all named symbols/paths real? Are all
content anchors unique? Is the new code structurally sound? Are
test fixtures runnable? Does the new exit code conflict with
anything?

- `bin/common.sh::progress_md_path` at lines 78-82 ✓ (verified)
- `bin/common.sh::progress_md_path` on `export -f` line 400 ✓
- `bin/common.sh::failure_outcome_for_exit` lines 222-250; arms
  0/10/11/12/13/14/20/21/22/23/24/25/26/27/28/29/30/124/`*`; **31
  unallocated** ✓
- `bin/dispatch.sh::_render_and_capture_stream` lines 47-236; closing
  `}` at 236; comment header `# ENG-48 isolation:` at 238 ✓
- `bin/dispatch.sh::_render_and_capture_stream` four existing
  detective blocks at lines 150-159 (gh pr create, rc=22), 173-184
  (build-stage git verbs, rc=26), 194-207 (cross-stage
  branch-creation, rc=23), 221-235 (cross-stage core.bare, rc=13) ✓
- `bin/dispatch.sh:50` `local violation_file="${issue_dir}/.transcript-violation-${stage}"` ✓
- `bin/dispatch.sh:563-566` env block exports `PIPELINE_DISPATCH_ID` ✓
- `bin/dispatch.sh:439-440` resolves `issue_state_dir` from
  `PIPELINE_ISSUE_ID` ✓
- `bin/dispatch.sh:17-18` sources `common.sh` ✓
- `bin/dispatch.sh:511-526` DRY_RUN early-return bypass ✓
- `bin/run-stage.sh` dispatch-rc arms lines 1310-1398 with catch-all
  at 1394 ✓
- `bin/run-stage.sh:1305-1308` dispatch invocation exports
  `PIPELINE_ISSUE_ID` ✓
- `bin/render-prompt.sh::PROMPT_RESOLVERS` lines 41-55 with
  `review_findings=` row at line 54 followed by closing `'` at line 55 ✓
- `bin/render-prompt.sh:226` `_resolve_stage_summary_path() { ... }` ✓
- `bin/render-prompt.sh:404-421` `_RENDER_*` global binds; lines
  413-414 are `_RENDER_STAGE_SUMMARY_PATH=` and
  `_RENDER_LEARNED_RULES_DIR=` ✓
- `bin/render-prompt.sh:389` `stage_summary_path="$(issue_dir
  "$issue_id")/stage-summary-${stage}.md"` ✓
- `bin/render-prompt.sh:11` sources `common.sh` (helper in scope) ✓
- `AGENT_PROMPTS.md §2` lines 348-606; Completion checklist starts
  537; step 5 at 569; step 6 at 585; closing ``` at 606 ✓
- `bin/dispatch-test.sh` total 3030 lines; `# ─── Summary ───`
  header at ~3022; AS1-AS6 at 1189-1268; sourcing at line 70;
  scaffolding at 18-66 ✓
- `docs/runbooks/recovery.md` exists (A-014 assumed — section number
  resolved at implement-time via Task 12.1) — mechanical only,
  not a P0
- Exit code 31 collision check: `grep -n '\b31\b' bin/common.sh
  bin/dispatch.sh bin/run-stage.sh bin/classify-failure.sh` returns
  matches only for unrelated line/column references (no `exit 31`,
  no `return 31`, no `dispatch_rc == 31` pre-edit) ✓
- Detective helper `_assert_progress_md_entry` does not conflict
  with any existing symbol — Grep on `bin/*.sh` for the literal
  string returns zero pre-edit matches ✓
- Resolver `_resolve_progress_md_path` does not conflict — Grep
  zero pre-edit matches ✓
- Token `{progress_md_path}` does not conflict — Grep zero pre-edit
  matches in `AGENT_PROMPTS.md` ✓
- Taxonomy token `progress-md-entry-missing` does not conflict —
  Grep zero pre-edit matches in `bin/`, `docs/` ✓
- Bash 3.2 macOS compatibility for all introduced syntax:
  `${VAR-}` (single-dash) is POSIX, supported ✓; quoted heredoc
  `<<'MD'` is POSIX ✓; `grep -c` is POSIX ✓; positional `$1 $2`
  function args is POSIX ✓ — no Bash-4+ idioms (`mapfile`,
  associative arrays, `:?` parameter expansion that escalates) ✓

**Verdict: PASS · P0=0.** Every code-level fact is verified; A-014
is the only `assumed` item and it's a mechanical
section-number resolution at implement time, not a design
dependency.

### Persona — Scope

**Concerns evaluated:** every file edit traces to a brainstorm
decision; no edits leak outside Linear's IN list; OOS items are
deferred to a named sibling ticket.

- `AGENT_PROMPTS.md §2` ← brainstorm D-002 (prompt-side write
  instruction) ✓
- `bin/render-prompt.sh` (3 edits) ← brainstorm D-004 (PROMPT_RESOLVERS
  registry + resolver + bind, mirrors stage_summary_path) ✓
- `bin/common.sh` (1 edit) ← brainstorm D-006 (failure_outcome_for_exit
  taxonomy entry for new exit code 31) ✓
- `bin/dispatch.sh` (2 edits) ← brainstorm D-005 (detective scan
  location per Linear IN list) + D-008 (helper extraction for
  readability/test ergonomics) ✓
- `bin/run-stage.sh` (1 edit) ← brainstorm D-006 (rc-arm dispatch
  mapping mirrors existing rc=22/23/26/13 arms) ✓
- `bin/dispatch-test.sh` (1 edit) ← brainstorm D-007 (PG1-PG6
  fixtures per Linear IN list) ✓
- `docs/runbooks/recovery.md` (1 edit) ← brainstorm D-009 (operator
  recovery via --action continue) ✓
- `bin/render-prompt-test.sh` (1 edit, optional) ← A-020
  defensive-coverage extension, not a closure defect; SKIPPED if
  template not present ✓

OOS items (verified absent from this plan):
- Other stages writing → stage-gate at Task 8 `if [[ "$stage" ==
  "planning" ]]` ✓
- Any reader (implement agent reading progress.md) → no edit to
  AGENT_PROMPTS.md §3 (implementing agent prompt) ✓
- Linear marker integration → no new marker shape; existing ENG-87
  dispatch_id auto-injection is reused unchanged ✓
- ENG-28 umbrella reader sub-ticket → not pre-committed (OQ-5) ✓
- Project profile schema → unchanged ✓

Subsystem count per CLAUDE.md ticket-sizing rubric: orchestrator
(common.sh, run-stage.sh), dispatch (dispatch.sh, dispatch-test.sh),
agent prompts (AGENT_PROMPTS.md, render-prompt.sh). Three
subsystems at the 3+ threshold — brainstorm §8 logs the rubric
tension explicitly and justifies the collapse to a single design
decision spanning mechanical wiring. Plan inherits the same
justification.

**Verdict: PASS** — every edit traces to a brainstorm decision;
OOS items deferred to identified sub-tickets.

### Persona — Coherence

**Concerns evaluated:** does the plan honor existing conventions
across exit codes, separator shapes, resolver patterns, prompt
structure, test-fixture idioms?

- Exit-code arm structure (Task 10): `_viol_file_31` / `_viol_msg_31`
  naming, `cat ... 2>/dev/null || printf '<violation-detail-unavailable>'`,
  `classify_failure` + `rm -f` + `exit <rc>` shape — IDENTICAL to
  rc=13 arm at `bin/run-stage.sh:1380-1393` ✓
- Taxonomy entry (Task 7): `31) printf
  'progress-md-entry-missing' ;;` — token shape mirrors
  `branch-creation-forbidden`, `worktree-mutation-forbidden`,
  `agent-contract-missing` (hyphen-separated, descriptive verb-noun) ✓
- Detective shape divergence (Task 8): filesystem check, NOT
  transcript scan — DOCUMENTED inline in the Task 8 comment block
  AND in the helper's leading comment (Task 9). New shape; not a
  coherence violation, just a new pattern. ✓
- Resolver pattern (Tasks 2-4): 1-line function, `_RENDER_*` global
  read, registry row appended chronologically — IDENTICAL to
  `_resolve_stage_summary_path` / `_resolve_learned_rules_dir` at
  `bin/render-prompt.sh:226-227` ✓
- Test-fixture idiom (Task 11): synthesise file state under
  `$_TEST_STUB_DIR/PG<N>/`, direct helper invocation, `pass_at` /
  `fail_at` messages, `<<'MD'` quoted heredoc — IDENTICAL to
  AS1-AS6 / CB1-CB8 / BC1-BC8 pattern ✓
- Prompt step shape (Task 5): bold imperative verb + body with
  schema example + "what NOT to do" — IDENTICAL to §2's existing
  step 5 / step 6 shape; mirrors the §0 secret-handling preamble's
  "Do NOT..." pattern ✓
- Heading separator (Task 5 prompt body): ` - ` (ASCII
  space-hyphen-space) per ENG-107 D-002 + runbook lines 46, 56 ✓
- `bin/dispatch.sh` private-helper convention: underscore-prefixed
  name, defined below `_render_and_capture_stream`, NOT on the
  `export -f` line — matches `_render_and_capture_stream`,
  `_dispatch_tools_from_profile`, `_dispatch_tools_extras` (all
  private to dispatch.sh) ✓
- Documentation cross-references (Tasks 5, 8, 9, 12): runbook
  pointer in the prompt; recovery procedure in the runbook;
  brainstorm cross-reference in inline comments — matches the
  ENG-71 / ENG-66 / ENG-68 documentation pattern ✓

**Verdict: PASS** — every introduced surface mirrors an existing
convention.

### Persona — Design

**Concerns evaluated:** are crate/module boundaries respected? Is
the detective shape correct? Is the helper extraction justified?

- Module boundaries (Bash projects: file boundaries):
  - `bin/common.sh` exports `progress_md_path` (per A-001); both
    `bin/render-prompt.sh` (via Task 4's `$(progress_md_path
    "$issue_id")` call) and `bin/dispatch.sh` (via direct path
    composition under `${issue_dir}/progress.md` in Task 9) compose
    correctly via the common.sh source. ✓
  - `bin/dispatch.sh` private helper `_assert_progress_md_entry`
    stays in dispatch.sh — NOT promoted to common.sh (per brainstorm
    D-008 rejected alternative). The helper has one caller
    (`_render_and_capture_stream` line 235 region); promoting to
    common.sh would over-share the function's API surface. ✓
  - `bin/run-stage.sh` rc-arm reads the sidecar via `cat` and
    classifies via `classify_failure` — IDENTICAL to existing arm
    structure; no new module-boundary crossing. ✓
  - `bin/render-prompt.sh` adds one new resolver + one local-var
    resolve; both stay inside render-prompt.sh's existing
    boundary. ✓
  - `AGENT_PROMPTS.md` §2 gains one new prompt step; the existing
    AGENT_PROMPTS.md fence-count contract (CLAUDE.md
    "AGENT_PROMPTS.md is load-bearing") is preserved — Task 5.4
    explicitly gates on this. ✓

- Detective shape: filesystem check, not transcript scan. Brainstorm
  D-005 documented the rationale (the `Read`-then-`Write` idiom is
  invisible at the transcript-tool-input level by SEC-002 logging
  policy); the artifact's on-disk presence is the
  authoritative signal. The plan honors the Linear ticket's
  "dispatch.sh" placement instruction while clearly documenting the
  divergent shape (Task 8's inline comment). ✓

- Helper extraction (Task 9 vs. inline): the helper is ~22 lines
  (10 lines of pseudo-bash + 8 lines of file-state comparison +
  comments). Inlining would push `_render_and_capture_stream` from
  ~190 lines to ~210 lines (already large); extracting keeps the
  caller readable AND gives the test a direct entry point (PG1-PG6
  call the helper, not `_render_and_capture_stream` end-to-end).
  Both gains. ✓

- Coupling: the helper depends on (a) `${PIPELINE_DISPATCH_ID-}`
  from env (per ENG-46 single-dash idiom), (b) `$issue_dir` /
  `$violation_file` from caller arguments, (c) `log` from common.sh
  (in scope via dispatch.sh:18 source). No new file dependencies,
  no Linear/git/jq dependencies. Pure local filesystem. ✓

- Exit-code 31 placement: 30 → 31 → 124 is numerically tight; sits
  between `noop-implementation` and `dispatch-timeout`. Matches the
  existing cluster shapes (22-23 / 24-25 / 26-29 / 30-31) ✓

**Verdict: PASS** — no layering violations; helper extraction
justified; detective shape choice documented.

### Persona — Product

**Concerns evaluated:** does this plan deliver what the Linear
ticket asked for, in language the user would recognise?

- Linear ACs:
  - AC #1 (entry has timestamp + dispatch_id + 3-5 bullets) → Task 5
    prompt body mandates the schema; the agent's compliance is
    enforced by the schema's grep-friendly heading shape (PG1
    confirms a well-formed entry passes) and by AC #2's halt-on-miss
    (PG4 confirms a non-matching shape fails) ✓
  - AC #2 (missing entry halts with clear reason) → Task 8/9
    filesystem detective; Task 10 rc-arm with `skip-until-human-acts`
    policy and the "plan-stage progress.md entry missing or
    malformed" halt-message body; PG2 fixture ✓
  - AC #3 (Reading progress.md after a plan dispatch shows a
    well-formed append; no full-file rewrites) → Task 5 prompt
    body mandates Read-then-Write idiom and explicitly forbids
    `Write` with only the new entry; PG3 fixture confirms multi-
    entry preservation; the strict-superset-grep check enforces a
    weaker (but sufficient) "this dispatch's entry is present"
    invariant ✓

- Pilot scope: plan stage only. Other stages MUST NOT write today;
  the stage-gate at Task 8 enforces this. ✓

- Reader sub-ticket interface (OQ-5): the pilot's writer-side
  shape (one H2 per dispatch, dispatch-id-stamped heading, 3-5
  bullets) supports both `Read inline` and `prompt interpolation`
  reader designs. The plan does not pre-commit to either. ✓

- Operator recovery: documented in runbook §<N> (Task 12); recovery
  recipe is the canonical
  `bash bin/pipeline.sh decide <ident> --action continue` per
  CLAUDE.md. ✓

- Detective false-positive path: documented (rare, manual unhalt +
  follow-up ticket per runbook). ✓

- Pilot risk: content quality (3-5 bullet usefulness) is NOT
  enforced. Brainstorm §10.5 flagged this; the plan inherits the
  Product persona's acceptance. Operator inspection of first
  dispatches is the diagnostic. ✓

**Verdict: PASS** — pilot delivers the Linear ticket's three ACs
with documented operator-recovery and content-quality observability.

## Personas: 5/5 PASS · gate P0: 0 · proceeding to implementing.
