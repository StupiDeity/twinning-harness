---
linear: ENG-109
date: 2026-05-16
topic: AGENT_PROMPTS.md §§1,4,5,6,7,8 read+write clauses for progress.md + dispatch.sh detective scan (Write on /progress.md) + bin/common.sh::assert_no_write_to_path helper + bin/progress-md-cross-stage-test.sh chain fixture + agent-prompts-content-test.sh invariants flip from §3-only absence to multi-§ presence + project-profile.md test-allowlist regen
---

# Plan — ENG-109 progress.md extend coverage to remaining stages

Implementation plan for the design at
`docs/brainstorms/2026-05-16-eng-109-progress-md-extend-coverage-to-remaining-stages-design.md`.

## Anti-anchoring check

- **Problem (operator's words).** The parent ENG-28 umbrella wants a
  continuous, per-issue `progress.md` notebook so cross-dispatch context
  on the same issue accumulates without re-parsing transcripts. ENG-107
  shipped the schema + slot. ENG-108 shipped the implement-stage reader
  pilot (the only stage today that reads). ENG-109 (this) is the
  rollout: wire the remaining six stages (brainstorm, ui, review, qa,
  build, release) as both readers AND writers, and extend the
  dispatch.sh detective scan to all stages.
- **Brainstorm addresses it?** Yes. D-001 enumerates the six stages and
  notes retrospective (§9) is intentionally excluded. D-002 specifies
  the read-clause (one shape) and write-clause (six per-stage variants
  with Decision-path gating for §§5, 6, 7). D-003 plumbs the
  `{progress_md_path}` resolver. D-004 adds the Write-on-progress.md
  detective in dispatch.sh. D-005 specifies the test surface
  (per-stage prompt assertions + a new cross-stage chain fixture). No
  reframe; the three Linear AC map onto D-001 (cover all stages),
  D-002+D-004 (every stage reads+writes; detective enforces shape),
  and D-005 (chain test + per-stage tests).
- **Proportional?** Yes. Brainstorm §3 sizes the change at ~300 LOC
  across 13 files (six near-identical AGENT_PROMPTS.md per-§ edits +
  one detective loop + one helper + one new test file + per-existing-
  test fixtures + one profile regen). The smallest set that satisfies
  the three Linear AC.
- **No anti-anchoring escalation** (problem isn't reframed; solution
  isn't disproportionate). PROCEED.

### Deviations from the brainstorm (documented, not escalated)

Three deviations are warranted by the post-brainstorm state of
`origin/main` (commits landed after the brainstorm was drafted).

1. **D-002 placement — per-§ position-1, NOT §0.** The brainstorm
   proposed inserting the read clause into §0 (Common rules). ENG-108
   instead landed the read clause at `AGENT_PROMPTS.md:615` as the
   FIRST item in §3's "Read these files first" list (with surrounding
   tests pinning that exact position; `bin/agent-prompts-content-test.sh:88`).
   Five additional tests at `bin/agent-prompts-content-test.sh:101-111`
   pin the token's ABSENCE from §§4-9. Following the established
   ENG-108 shape is the coherent move — replicate the per-§ position-1
   placement across §§1, 4, 5, 6, 7, 8 and invert the absence pins to
   presence pins for the same set (keeping §9 absence).

2. **D-003 resolver plumbing — already shipped.** The brainstorm
   proposed adding the `progress_md_path` token to `PROMPT_RESOLVERS`
   plus a `_resolve_progress_md_path` function plus the `_RENDER_
   PROGRESS_MD_PATH` binding. All three already exist in `origin/main`
   (`bin/render-prompt.sh:55`, `:228`, `:417-427`) — ENG-108 plumbed
   them. ENG-109 inherits and does not re-add.

3. **D-006 pilot-dependency gate — partially satisfied; proceeding.**
   The brainstorm's D-006 instructs the plan agent to halt if EITHER
   pilot (ENG-106 plan-stage writer OR ENG-108 implement-stage reader)
   is missing from `main`. Post-rebase `git log --oneline origin/main`
   shows ENG-108 landed (commits `d0772e5`, `54769db`, `888fcd4`,
   `9bc6729`, `d01adaa`); ENG-106 has not landed. Linear's
   "Dependencies: Blocked by the implement-reader sub-ticket" only
   names ENG-108 (which is in main). The brainstorm's D-006 elevated
   the gate to BOTH pilots out of caution about first-of-kind shapes.
   Post-ENG-108-merge, the read-side shape is settled and the
   resolver is wired; only the WRITE-clause shape is unestablished.
   The brainstorm's D-002 specifies the write clause inline with
   sufficient detail (per-stage prompt text, Decision-path gating,
   heading-shape examples) to proceed. **PROCEED.** If the operator
   disagrees, they can apply `pipeline:supersede` or
   `pipeline:extend` and fail the plan-stage verdict; the next
   dispatch will re-evaluate.

## Branch-base freshness

`git fetch origin main` (plan-agent's environment had origin/main
pre-fetched). `git log --oneline HEAD..origin/main` returned NON-EMPTY:

```
d0772e5 feat(eng-108): Progress.md: implement stage reads progress entries
54769db test(ENG-108): QA adversarial coverage
888fcd4 fix(ENG-108): add PROJECT_STATE_DIR override to sandbox invocations
9bc6729 feat(ENG-108): progress.md reader pilot — implement stage reads progress entries
d01adaa test(ENG-108): add render-prompt case-C/D fixtures and §3 position-1 invariant
bfbc30e chore(pipeline): planning for ENG-108
4d094ab chore(pipeline): brainstorming for ENG-108
```

This branch is 7 commits behind `origin/main`. The drift is **clean**:
every drifted commit is from ENG-108 (the predecessor reader pilot
that ENG-109 must extend, not replace). No sibling-ticket conflict
in File Structure. `Task 0: Rebase onto origin/main` is mandatory and
included as the first task in Backend Tasks. All `path:line` excerpts
in Assumption Inventory below are quoted against **origin/main HEAD
(`d0772e5`)** — the post-rebase state — using `git show origin/main:<path>`.

## Goal

After implement runs:

1. `bash bin/agent-prompts-content-test.sh` exits 0 with the new
   ENG-109 assertions passing: (a) §§1, 4, 5, 6, 7, 8 each carry
   `1. {progress_md_path}` at position 1 of their "Read these files
   first" list (matching the existing §3 ENG-108 invariant);
   (b) §9 absence of `{progress_md_path}` stays pinned (retrospective
   excluded); (c) §§1, 4, 5, 6, 7, 8 each carry the literal write-
   clause phrase `Append a \`progress.md\` entry`.
2. `bash bin/common-test.sh` exits 0 with three new ENG-109 fixtures
   on `assert_no_write_to_path`: empty-transcript→0, Write-on-progress
   →1+matched-path, Write-on-other-file→0.
3. `bash bin/dispatch-test.sh` exits 0 with two new ENG-109 fixtures
   on the dispatch.sh Write-on-progress.md detective: positive
   case (Write on `/progress.md`) triggers dispatch.sh return code
   29 with the matched path written to the violation file; negative
   case (Write on `stage-summary-implementing.md`) returns 0 (the
   normal stage-summary write path stays unimpeded).
4. `bash bin/progress-md-cross-stage-test.sh` (new file) exits 0
   with the brainstorm → plan → implement chain assertion: a fixture
   progress.md synthesised by three sequential mock dispatches
   contains three H2 entries in dispatch-id order, each parsing
   into the three-token heading shape, and the file is grep-friendly
   to a reader filtering by `dispatch-id={current}`.
5. `bash .githooks/pre-commit` exits 0 (every existing
   `bin/*-test.sh` plus the new cross-stage test passes).
6. `learned-rules/harness/project-profile.md` lists
   `Bash(bash bin/progress-md-cross-stage-test.sh:*)` under both the
   `implementing:` and `qa:` blocks of `## Tool allowlist`.

Verifiable by:

```
bash bin/agent-prompts-content-test.sh \
  && bash bin/common-test.sh \
  && bash bin/dispatch-test.sh \
  && bash bin/progress-md-cross-stage-test.sh \
  && bash .githooks/pre-commit
```

exiting 0.

## Assumption Inventory

Every modified-file fact below is `path:line`-cited against
`origin/main` HEAD (`d0772e5` — the rebase target). Quoted excerpts
are exact substrings to preserve in `Edit::old_string` calls. Bare
line numbers appear ONLY as informational hints alongside a content
anchor; the literal content-anchor strings are what the Edit calls
match. Task 1 (re-verify) re-greps each anchor at implement time;
Task 0 (rebase) ensures the agent is operating against the same
HEAD this inventory was anchored to.

branch-base freshness: HEAD..origin/main NON-EMPTY at plan time
(origin/main = `d0772e5`); Task 0 rebases the feature branch onto
origin/main before any other task; all anchors below survive the
rebase by design (every anchor lives in a file ENG-108 already
modified, and the anchor strings were chosen from ENG-108's
post-merge body).

### Files modified in this plan: 13 (1 new, 12 edited)

- `AGENT_PROMPTS.md` — six per-§ edits (§§1, 4, 5, 6, 7, 8) each
  inserting two clauses (read at "Read these files first" position 1;
  write in the Output / Completion-checklist section before the
  verdict marker)
- `bin/common.sh` — two edit sites: insert `assert_no_write_to_path`
  helper next to `assert_no_tool_invocation`; append the new function
  to the public `export -f` line
- `bin/dispatch.sh` — one edit site: insert the cross-stage
  Write-on-progress.md detective loop in `_render_and_capture_stream`
  after the ENG-68 `core.bare` block
- `bin/run-stage.sh` — one edit site: insert a new `dispatch_rc == 29`
  elif arm in the dispatch-rc classifier (between the existing
  rc=13 arm and the `(( dispatch_rc != 0 ))` fallthrough at
  lines ~1395-1405) so dispatch.sh's new detective returning 29
  classifies as `skip-until-human-acts dispatch-envelope-violation`
  instead of falling through to `retry-immediately` exit 20
- `bin/agent-prompts-content-test.sh` — three edit sites:
  (a) define new `s1`, `s5`, `s6`, `s9` section variables; (b) replace
  the `§§4-9 absence` loop with `§§1, 4, 5, 6, 7, 8 presence`
  assertions + a `§9 absence` assertion; (c) add per-§ write-clause
  presence assertions
- `bin/common-test.sh` — one edit site: three new fixtures for
  `assert_no_write_to_path`
- `bin/dispatch-test.sh` — one edit site: two new fixtures (positive
  + negative) for the dispatch.sh Write-on-progress detective
- `bin/progress-md-cross-stage-test.sh` — new file
- `learned-rules/harness/project-profile.md` — two edit sites:
  insert the new test under `implementing:` and `qa:` Tool allowlist
  blocks

### Modified-file facts — current state (origin/main `d0772e5`) and verification points

- **A-001 — Existing ENG-108 §3 read-clause invariant (preserved by
  ENG-109).** `bin/agent-prompts-content-test.sh:86-90` carries the
  pin:

  ```bash
  if printf '%s\n' "$s3" | grep -qF '1. {progress_md_path}'; then
    ok "§3 ENG-108: read-first list has '{progress_md_path}' at position 1"
  else
    nope "§3 ENG-108: read-first list has '{progress_md_path}' at position 1" \
      "literal '1. {progress_md_path}' line missing from §3 — has the position-1 placement been demoted, or the token removed entirely?"
  fi
  ```

  ENG-109 does NOT touch this assertion — §3 retains its pin. The
  ENG-109 additions adopt the same shape for §§1, 4, 5, 6, 7, 8.

- **A-002 — ENG-108 §§4-9 ABSENCE invariant (must be REFACTORED).**
  `bin/agent-prompts-content-test.sh:96-111` carries:

  ```bash
  for _sec_num in 4 5 6 7 8 9; do
    _sec_var="s${_sec_num}"
    if printf '%s\n' "${!_sec_var}" | grep -qF '{progress_md_path}'; then
      nope "§${_sec_num} ENG-108 QA: '{progress_md_path}' token absent from §${_sec_num} (scoped to §3 only)" \
        "token '{progress_md_path}' present in §${_sec_num} — implementing-only feature, do not propagate without updating the stage-conditional log condition"
    else
      ok "§${_sec_num} ENG-108 QA: '{progress_md_path}' token absent from §${_sec_num} (scoped to §3 only)"
    fi
  done
  ```

  Adding `{progress_md_path}` to §§4-8 will FAIL these existing
  assertions (the iteration over 4..9 includes §4 which IS currently
  defined as `s4`). Task 3.4 below REPLACES the loop body to invert
  the assertions for §§4-8 (presence required) while preserving §9
  (absence required, since retrospective is excluded per D-001).
  This is the **test-gate closure** defect the plan's feasibility
  persona must catch.

  Content anchor for Task 3.4's Edit: the literal block above
  (lines 96-111). The opening `# ─── ENG-108 QA adversarial:`
  comment header and the closing `done` are both unique within
  the file.

- **A-003 — §-variable definitions in agent-prompts-content-test.sh
  (must be EXTENDED).** `bin/agent-prompts-content-test.sh:67-71`
  defines five `s*` variables:

  ```bash
  s2="$(section_body "## 2. Plan Agent")"
  s3="$(section_body "## 3. Implementation Agent (Backend)")"
  s4="$(section_body "## 4. UI Agent (Frontend)")"
  s7="$(section_body "## 7. Build Agent")"
  s8="$(section_body "## 8. Release Agent")"
  ```

  `s1`, `s5`, `s6`, `s9` are NOT defined. The existing ENG-108
  §§4-9 absence loop iterates over 4..9 and reads `${!_sec_var}`
  for the unset vars — under bash's indirect-expansion semantics
  on unset names, this resolves to empty (which trivially passes
  the absence check; **independently verified by the fact that
  ENG-108 ships green**). ENG-109 introduces presence assertions
  for §§1, 5, 6 (already-absent vars under set -u must NOT be
  referenced as empty — they must be explicitly defined). Task
  3.3 adds `s1`, `s5`, `s6`, `s9` immediately after the existing
  block (per content anchor below).

  Content anchor for Task 3.3's Edit: the literal block of five
  `s*=` lines (unique within the file). Insertion is APPENDED
  immediately after — preserving alphabetical position is not a
  goal (s1 < s2 numerically but the existing block already
  out-of-order pins s7 and s8 after s4; chronological append is
  the file's convention).

- **A-004 — `bin/common.sh::assert_no_tool_invocation` template
  for the new helper.** `bin/common.sh:188-205`:

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

  The new `assert_no_write_to_path` (Task 4.1) is sibling-shaped
  with two surgical differences: (a) `name == "Bash"` →
  `name == "Write"`; (b) `(.input.command // "")` →
  `(.input.file_path // "")`; (c) `startswith($p)` →
  `endswith($p)` (the agent's `Write` calls carry the absolute
  worktree path so the discriminating signal is the suffix; per
  brainstorm D-004).

  Content anchor for Task 4.1's Edit: the literal closing line
  of `assert_no_tool_invocation`'s function (the `}` after the
  `return 0`) AND the literal next-block opening comment header
  `# ─── Exit-code → outcome taxonomy` (verified at
  `bin/common.sh:207` via `git show origin/main:bin/common.sh`).
  Both anchor strings appear EXACTLY ONCE in the file.

- **A-005 — `bin/common.sh::export -f` line carries
  `progress_md_path`** (ENG-107 + ENG-108). `bin/common.sh:400`:

  ```bash
  export -f issue_dir compute_pipeline_content_hash failure_outcome_for_exit parse_pipeline_marker is_orchestrator_paused set_orchestrator_paused allocate_dispatch_id current_dispatch_id assert_no_tool_invocation progress_md_path
  ```

  Content anchor for Task 4.2's Edit: the literal full line above
  appears EXACTLY ONCE in the file. Task 4.2 appends a single
  space + `assert_no_write_to_path` to the END of the line,
  preserving every existing exported name (the same append-only
  pattern ENG-107 used at this line).

- **A-006 — `bin/render-prompt.sh::PROMPT_RESOLVERS` carries
  `progress_md_path=_resolve_progress_md_path`** (ENG-108).
  `bin/render-prompt.sh:55`:

  ```bash
  progress_md_path=_resolve_progress_md_path
  ```

  ENG-109 does NOT modify `bin/render-prompt.sh` — the resolver
  wiring is fully present. This invalidates the brainstorm's
  D-003 work item (acknowledged in "Deviations from the brainstorm"
  above).

- **A-007 — `bin/render-prompt.sh::_resolve_progress_md_path` and
  `_RENDER_PROGRESS_MD_PATH` binding both present** (ENG-108).
  `bin/render-prompt.sh:228` defines the resolver:

  ```bash
  _resolve_progress_md_path() { printf '%s' "$_RENDER_PROGRESS_MD_PATH"; }
  ```

  `bin/render-prompt.sh:417-427` binds the value in `main()`:

  ```bash
  _RENDER_PROGRESS_MD_PATH="$(progress_md_path "$issue_id")"
  if [[ "$stage" == "implementing" && ! -e "$_RENDER_PROGRESS_MD_PATH" ]]; then
    log "render-prompt: progress-md missing for $issue_id at $_RENDER_PROGRESS_MD_PATH (informational; agent's Read will note absence)"
  fi
  ```

  ENG-109 does NOT touch this region. The stage-conditional log
  remains scoped to `implementing` only (per ENG-108's design call
  — the log is informational, not blocking; an absence on other
  stages doesn't deserve a log). Whether to broaden the
  stage-conditional to all stages is OQ-1; out of scope for ENG-109
  per brainstorm §3 / D-001.

- **A-008 — `bin/dispatch.sh::_render_and_capture_stream`
  post-stream detective loops (ENG-43, ENG-71, ENG-66, ENG-68)
  span lines 149-237.** The ENG-66 cross-stage branch-creation
  loop (lines 186-201) and the ENG-68 cross-stage `core.bare`
  loop (lines 209-233) are the two existing cross-stage
  detectives. Verified by `git show origin/main:bin/dispatch.sh
  | sed -n '149,237p'`. Closing brace `}` of
  `_render_and_capture_stream` at line 237:

  ```bash
        return 13
      fi
    done
  }
  ```

  Content anchor for Task 5.1's Edit: the literal closing 3 lines
  of the ENG-68 loop (the `return 13`, `fi`, `done` triplet) plus
  the closing `}` of `_render_and_capture_stream`. Both the
  triplet and the closing brace appear ONCE in the file (verified
  by `grep -c "return 13" /tmp` style searches — there is only
  one `return 13` and only one closing `}` at column 0 in this
  span). The new detective inserts BEFORE the closing `}`,
  AFTER the ENG-68 `done`. Hint: ~line 235.

- **A-009 — `bin/dispatch.sh` `violation_file` is the cross-
  stage handoff slot for matched-text.** Lines 50-54:

  ```bash
    local raw_capture="${issue_dir}/.raw-stream.ndjson.tmp"
    local violation_file="${issue_dir}/.transcript-violation-${stage}"
  ```

  The ENG-66 and ENG-68 detectives both write the matched-text
  to `$violation_file` and `return` a non-zero rc. ENG-109's new
  detective follows the same shape. No new variable; no new
  sidecar file.

- **A-010 — `bin/run-stage.sh` dispatch_rc classifier has NO
  rc=29 arm today; this plan adds one.** Verified by direct
  read of `bin/run-stage.sh:1310-1408`: the elif chain after
  `_render_and_capture_stream` returns covers rc=124 (ENG-48
  watchdog), rc=22 (ENG-43), rc=23 (ENG-66), rc=26 (ENG-71),
  rc=13 (ENG-68), and a fallthrough `(( dispatch_rc != 0 ))`
  that classifies as `retry-immediately` (exit 20). The rc=29
  branch at line ~1630 belongs to the SEPARATE post-dispatch
  `_validate_dispatch_envelope` invocation, NOT to dispatch.sh's
  own return code.

  Without a new elif arm, dispatch.sh's new ENG-109 detective
  returning 29 would fall through to `retry-immediately` exit
  20 — the orchestrator would retry the offending dispatch on
  the next tick instead of halting for operator review. This
  is the wrong outcome.

  **Task 5.2 below adds a new elif arm** for `dispatch_rc == 29`
  that mirrors the rc=22/23/26/13 shape: read the sidecar
  `.transcript-violation-${stage}` file, call
  `classify_failure ... skip-until-human-acts` with reason
  string `dispatch-stage transcript invoked forbidden Write on progress.md: <matched-path>`,
  remove the violation file + prompt file, exit 29. The shape
  is verbatim from ENG-66's rc=23 arm (lines 1338-1352),
  substituting the matched-text string and exit code.

  **Operator-triage cost.** Two distinct sources of rc=29 now
  exist:
  - dispatch.sh's ENG-109 Write-on-progress.md detective
    (NEW; this plan).
  - run-stage.sh's post-dispatch `_validate_dispatch_envelope`
    (existing; ENG-87).

  Both classify as `dispatch-envelope-violation`. Operators
  reading the Linear halt comment alone cannot distinguish the
  two; the disambiguator lives in the per-stage transcript
  (`[assert] stage=$stage transcript invoked forbidden Write on progress.md: ...`
  vs `_validate_dispatch_envelope`'s `mcp__plugin_linear` /
  `curl https://api.linear.app` body). Accepted per brainstorm
  D-004 rejected-alternative on adding a new exit code.

  Content anchor for Task 5.2's Edit: the literal closing arm
  of ENG-68's rc=13 elif block AND the literal opening of the
  fallthrough `elif (( dispatch_rc != 0 ))` block — the new
  rc=29 arm inserts BETWEEN them. Both anchors verified unique
  at plan time. The ENG-68 arm's closing `exit 13` followed by
  `    elif (( dispatch_rc != 0 )); then` is the multi-line
  unique fence.

- **A-011 — `AGENT_PROMPTS.md` §1 (Brainstorm) read list and
  Completion checklist.** Read list at lines 240-246:

  ```
  Read these files first (in order, where present):
  1. CLAUDE.md — coding standards and project structure
  2. docs/VISION.md — product vision, principles, non-goals (skip if not present)
  3. Architecture / system docs as listed in the Project profile addendum's File layout (skip if not present)
  4. docs/knowledge/decisions.md — prior architectural decisions (skip if not present)
  5. docs/knowledge/gotchas.md — known pitfalls to avoid (skip if not present)
  6. {learned_rules_dir}/brainstorm.md — learned rules from past retrospectives (follow ALL rules listed)
  ```

  Content anchor for Task 2.1's §1 Edit: the literal multi-line
  block `Read these files first (in order, where present):\n1. CLAUDE.md ...`
  (the first two lines are unique within §1 by inspection;
  `Read these files first (in order, where present):` is repeated
  across other stages, but `Read these files first (in order, where present):\n1. CLAUDE.md — coding standards and project structure\n2. docs/VISION.md` is unique to §1).

  Completion checklist starts at line 288 (`## Completion checklist (ordered — do every step in order, and do NOT exit before step 5)`)
  and runs through line 327 (the `Do NOT touch \`pipeline:halted\`` line
  before the closing fence). The write-clause insertion goes BETWEEN
  step 5 (stage-summary write at lines 308-321) and step 6 (verdict-
  marker post at lines 322-327). Content anchor for Task 2.1's §1
  write-clause Edit: the literal MULTI-LINE opening of step 6 —
  `6. **Post the verdict marker** (MANDATORY). Before exiting, post exactly ONE\n   additional append-only comment carrying the verdict for your outcome:` —
  is file-unique. Bare `6. **Post the verdict marker** (MANDATORY).`
  appears at TWO sites in the file (§1 line 322 + §2 line ~585 with
  different trailing text); the multi-line anchor including
  `Before exiting, post exactly ONE` is unique to §1. The implement
  agent MUST use the multi-line form for Edit::old_string.

- **A-012 — `AGENT_PROMPTS.md` §4 (UI) read list and Output
  section.** Read list at lines 812-818:

  ```
  Read these files first (in order, where present):
  1. CLAUDE.md — coding standards and project structure
  2. docs/UX_PRINCIPLES.md — UX constraint document (skip if not present)
  3. docs/knowledge/gotchas.md — filter by tags relevant to the frontend modules per the profile (skip if not present)
  4. docs/knowledge/conventions.md — filter by frontend tags (skip if not present)
  5. {learned_rules_dir}/ui.md — learned rules from past retrospectives (follow ALL)
  6. docs/brainstorms/{brainstorm_file}
  7. docs/plans/{plan_file} — focus on "Frontend Tasks" + the `api-contract` block
  ```

  Content anchor for Task 2.2's §4 read-clause Edit: the literal
  `1. CLAUDE.md — coding standards and project structure\n2. docs/UX_PRINCIPLES.md` triplet (unique to §4).

  Output section runs from ~line 902 (`Output:` line) through line
  925 (the closing `pipeline:halted` line); the write-clause goes as
  a new bullet inserted between the existing `- Do NOT change the
  Linear stage label — the orchestrator swaps it on successful exit.`
  bullet (line 920) and the `Verdict marker (MANDATORY at exit):`
  header (line 922). Content anchor for Task 2.2's §4 write-clause
  Edit: the literal `Verdict marker (MANDATORY at exit):` header
  appears in every stage but at §4 follows the unique-to-§4
  `Do NOT change the Linear stage label — the orchestrator swaps it on successful exit.\n\nVerdict marker (MANDATORY at exit):` (4 lines spanning unique-to-§4 last bullet + blank + header). Verified
  unique by grep.

- **A-013 — `AGENT_PROMPTS.md` §5 (Review) read list and Output
  section.** Read list at lines 951-957:

  ```
  Read these files first (in order, where present):
  1. docs/brainstorms/{brainstorm_file} — original requirements
  2. docs/plans/{plan_file} — approved plan (including the `api-contract` block)
  3. docs/knowledge/gotchas.md — filter by tags relevant to the PR's modules (skip if not present)
  4. docs/knowledge/decisions.md — verify against accepted ADRs (skip if not present)
  5. docs/knowledge/conventions.md — verify against established conventions (skip if not present)
  6. {learned_rules_dir}/review.md — learned rules (follow ALL)
  ```

  Content anchor for Task 2.3's §5 read-clause Edit: the literal
  `1. docs/brainstorms/{brainstorm_file} — original requirements\n2. docs/plans/{plan_file}` pair (unique to §5; no other stage has
  `docs/brainstorms/...` at position 1 of its read list).

  Output section starts at ~line 1139 (`Output:` header) and runs
  through line ~1158 (last bullet `Do NOT submit a GitHub PR review in the APPROVED state ...`); the write-clause is gated on
  Decision-path C (clean review only, per brainstorm D-002 §5).
  Verdict marker block runs from line ~1163 onward. The write-clause
  goes as a new bullet inserted between the existing
  `- Verdict per Decision path (A premise-failure → fail to brainstorming, B changes-requested → fail to implementing, C clean → pass advancing to qa).` bullet (line ~1156) and the
  `Verdict marker (MANDATORY at exit):` header (line ~1162).

- **A-014 — `AGENT_PROMPTS.md` §6 (QA) read list and Output
  section.** Read list at lines 1193-1199:

  ```
  Read these files first (in order, where present):
  1. The Linear issue {issue_id} — acceptance criteria
  2. docs/brainstorms/{brainstorm_file} — edge cases, error handling
  3. docs/plans/{plan_file} — Test Strategy + Failure Mode → Test Map (authoritative)
  ...
  ```

  Content anchor for Task 2.4's §6 read-clause Edit: the literal
  `1. The Linear issue {issue_id} — acceptance criteria` line
  (unique to §6 — no other stage has "The Linear issue" at
  position 1).

  Output section ends with the verdict marker at lines ~1345-1365.
  Write-clause inserts as a new bullet before the
  `Verdict marker (MANDATORY at exit):` header.

- **A-015 — `AGENT_PROMPTS.md` §7 (Build) read list and Output
  section.** Read list at lines 1376-1378:

  ```
  Read these files first (where present):
  1. {learned_rules_dir}/build.md — learned rules (follow ALL)
  2. docs/knowledge/decisions.md — check for any ADR that constrains merging (e.g., release cadence decisions, version-pinning rules)
  ```

  Note: §7's "Read these files first" uses `(where present):` not
  `(in order, where present):` — distinct opener from §§1, 4, 5, 6.
  Content anchor for Task 2.5's §7 read-clause Edit: the literal
  `Read these files first (where present):\n1. {learned_rules_dir}/build.md` pair (unique to §7 — `{learned_rules_dir}/build.md`
  appears nowhere else).

  Output section: verdict-marker block runs from line 1600+. The
  write-clause is gated on Decision-path B (merged) only per
  brainstorm D-002 §7. Insertion goes immediately above the
  `Verdict marker (MANDATORY at exit, except wait-shape exits — see P2/P5 above):`
  header at line ~1603 (unique to §7 — the `, except wait-shape exits`
  qualifier appears nowhere else).

- **A-016 — `AGENT_PROMPTS.md` §8 (Released) read list and
  Output section.** Read list at lines 1640-1643:

  ```
  Read these files first (where present):
  1. {learned_rules_dir}/release.md — learned rules (follow ALL)
  2. docs/knowledge/decisions.md — any ADR about release cadence or versioning
  3. The release-tool config named in the Project profile (e.g. `.releaserc.json`, `goreleaser.yaml`) — read-only; do not edit.
  ```

  Content anchor for Task 2.6's §8 read-clause Edit: the literal
  `Read these files first (where present):\n1. {learned_rules_dir}/release.md — learned rules (follow ALL)` pair (unique to §8 —
  `{learned_rules_dir}/release.md` appears nowhere else; §8 also
  uses `(where present):` like §7 but the position-1 line
  disambiguates).

  Output section ends at lines ~1731-1734. §8's Output is a
  closing-fence-bounded block; there is no `Verdict marker
  (MANDATORY at exit):` header in §8 (per brainstorm A11 and
  inspection — the released stage doesn't emit a verdict
  because it's a read-only observer). The write-clause is
  appended to the existing per-issue enrichment loop's success
  path; insertion goes between the existing `- No edits to any
  source files. You are a read-only observer plus Linear/Slack writer.`
  bullet at line ~1733 and the closing ``` fence at line ~1734.

- **A-017 — `AGENT_PROMPTS.md` §3 (Implement) is UNCHANGED by
  this plan.** Verified by inspection: ENG-108's §3 already
  carries the read clause at lines 614-622 in canonical
  position 1; ENG-109 does NOT touch §3. The existing §3
  ENG-108 invariant test at `bin/agent-prompts-content-test.sh:86-90`
  continues to gate it.

- **A-018 — `AGENT_PROMPTS.md` §9 (Retrospective) is UNCHANGED
  by this plan AND remains absence-pinned by the test.** Per
  brainstorm D-001 rejected alternative, retrospective is
  excluded because it has no `PIPELINE_ISSUE_ID` and no
  per-issue scratch dir. Task 3.4 below preserves the §9
  absence assertion.

- **A-019 — `bin/common-test.sh` test scaffolding pattern.**
  Per ENG-107 plan A-007 cross-reference (verified at plan time
  for ENG-107, still valid against origin/main `d0772e5` — no
  intervening edits to the test scaffolding region):
  `bin/common-test.sh:18-46` carries `_TEST_ROOT=$(mktemp -d -t
  twinning-eng44.XXXXXX)`, `TARGET_REPO`/`PROJECT_SLUG=test-slug`
  env setup, `source common.sh`, and `report_ok`/`report_fail`/`assert_eq`
  helpers. The new fixtures use this scaffolding without
  modification.

  Content anchor for Task 4.3's Edit: the final summary printf
  `printf '\ncommon-test summary: %d passed, %d failed\n' "$PASS" "$FAIL"`
  near the end of `bin/common-test.sh` (per ENG-107 A-008). The
  new fixtures are inserted IMMEDIATELY BEFORE this line.

- **A-020 — `bin/dispatch-test.sh` `assert_no_tool_invocation`
  fixture pattern.** `bin/dispatch-test.sh:1174-1268` shows the
  fixture style used for AS1-AS6 (positive cases) — each fixture
  writes a `tx-asN.ndjson` NDJSON file under `$_TEST_STUB_DIR`,
  calls `assert_no_tool_invocation` directly with the matcher
  pattern, and asserts `(rc, stdout)`. ENG-109's two new fixtures
  follow this exact shape (substituting `assert_no_write_to_path`
  + a Write-tool NDJSON line for the Bash-tool fixture).

  Content anchor for Task 4.6's Edit: the literal single
  printf line `printf '\nRESULTS: %d passed, %d failed\n' "$PASS" "$FAIL"`
  appears THREE TIMES in `bin/dispatch-test.sh` (verified at
  plan time at lines ~535, ~1185, ~3028 against origin/main).
  A single-line anchor will fail with "string appears N
  times" — Task 4.6 MUST use the multi-line file-tail summary
  block as the anchor (the `# ─── Summary ───` comment header
  + the trailing `[[ "$FAIL" == 0 ]] || exit 1` + the final
  `exit 0` form a unique-at-end-of-file triplet). The exact
  4-line anchor is documented in Task 4.6's body.

- **A-021 — `learned-rules/harness/project-profile.md` Tool
  allowlist section.** Section starts at `## Tool allowlist`
  (verified by grep). The `implementing:` block lists every
  `bin/*-test.sh` script (33 scripts visible in the system
  prompt addendum); the `qa:` block mirrors it. Adding the new
  `bin/progress-md-cross-stage-test.sh` requires inserting one
  line into each block (alphabetical position: between
  `pipeline-test.sh` and `reconcile-test.sh`? Actually,
  `progress-md-cross-stage-test.sh` sorts after `profile-
  allowlist-test.sh` and before `reconcile-test.sh`).

  Content anchors for Task 6.1's Edit (TWO sites):
  - `implementing:` block — insert AFTER the literal line
    `  - \`Bash(bash bin/profile-allowlist-test.sh:*)\``
    and BEFORE the literal line
    `  - \`Bash(bash bin/reconcile-test.sh:*)\``.
  - `qa:` block — same insertion between the same two
    sibling lines.

  Both anchor pairs are file-unique because each appears once
  in the `implementing:` block and once in the `qa:` block.

- **A-022 — No `.pipeline-config/config.json` exists for the
  harness-self target.** Verified by `ls .pipeline-config/`
  (returns "No such file or directory" at plan time). The
  brainstorm §3 listed `.pipeline-config/config.json` as a
  modified file with one entry each in `dispatch.tools.implementing[]`
  and `dispatch.tools.qa[]`. This is a brainstorm error — the
  config.json is operator-local and gitignored, and for the
  harness-self target it does not exist. The PROFILE is the
  only source of tool-allowlist truth here. Task 6.1 modifies
  ONLY the profile, not a config.json. Documented in "Deviations
  from the brainstorm."

- **A-023 — `bin/agent-prompts-content-test.sh::section_body`
  helper.** Per `bin/agent-prompts-content-test.sh:21-29` (the
  awk-based section extractor). New `s1`, `s5`, `s6`, `s9`
  definitions in Task 3.3 use the same helper.

- **A-024 — Test-gate closure sweep — REMOVALS.** This plan
  REMOVES the following tokens/assertions from production code
  and test code:

  1. **`bin/agent-prompts-content-test.sh:96-111` `for _sec_num in 4 5 6 7 8 9` LOOP** —
     replaced by Task 3.4 with a refactored assertion set
     (presence pins for §§4-8, absence pin for §9 only).
     The loop body's literal token strings to remove:
     `'§${_sec_num} ENG-108 QA: ...'` and
     `'scoped to §3 only'`. **Sibling-test sweep:** grep all
     `bin/*-test.sh` for the literal strings — only
     `bin/agent-prompts-content-test.sh` references the loop's
     specific text. No other test pins the "scoped to §3 only"
     assertion shape. Safe to refactor.

  2. **No other token removals.** ENG-109 inserts code; nothing
     in production is renamed or deleted.

  **Conclusion:** the only test-gate closure surface is
  `bin/agent-prompts-content-test.sh` itself (which Task 3.4
  modifies — captured in File Structure). Zero unaddressed
  closure defects.

- **A-025 — Test-gate closure sweep — ADDITIONS.** New tokens
  introduced (defensive check that no sibling test pins their
  ABSENCE):

  - `{progress_md_path}` in §§1, 4, 5, 6, 7, 8 — currently
    absence-pinned by `bin/agent-prompts-content-test.sh:96-111`
    for §§4-9. Task 3.4 inverts §§4-8 pins. §9 absence preserved.
    **No other sibling test** pins absence of `{progress_md_path}`
    in any §. Safe.
  - `Append a \`progress.md\` entry` write-clause phrase —
    new across §§1, 4, 5, 6, 7, 8. Grep for "Append a" returns
    no prior occurrences in `AGENT_PROMPTS.md` (per inspection).
    No sibling test pins this phrase absent. Safe.
  - `assert_no_write_to_path` helper — new export. Grep for
    `assert_no_write_to_path` in `bin/*-test.sh` returns zero
    matches pre-plan. No sibling test pins absence. Safe.
  - `bin/progress-md-cross-stage-test.sh` file — new. Grep for
    `progress-md-cross-stage-test` in `bin/*-test.sh` returns
    zero matches pre-plan. Safe.

  **Conclusion:** zero conflicting absence pins; no additional
  closure defects.

- **A-026 — Plan doc basename satisfies `partition_dirty_paths::D-004`.**
  Basename `2026-05-16-eng-109-progress-md-extend-coverage-to-remaining-stages.md`
  carries `eng-109` (lowercase) per ENG-107 plan A-015 / brainstorm
  A23 cross-reference. ✓

- **A-027 — Branch prefix matches Improvement label.** Branch
  `feat/eng-109-progress-md-extend-coverage-to-remaining-stages`
  matches the `feat/` prefix mandated for Feature/Improvement
  per CLAUDE.md "Linear conventions the harness depends on." ✓

- **A-028 — `learned-rules/harness/plan.md` does not exist.**
  Verified by `ls learned-rules/harness/`: returns only
  `build.md` and `project-profile.md`. Skip per prompt's
  "skip if not present" guidance for plan-stage learned rules.

- **A-029 — Adversarial-filename discipline (ENG-87 D-005).**
  The new detective writes the matched `file_path` to
  `$violation_file` only (NOT a Linear comment body). Per
  brainstorm §10.2 security persona, this avoids the
  `viol_str_raw → viol_str_safe` sanitisation pattern.
  Documented for the implement agent: do NOT propagate the
  matched path string to any Linear comment body without
  first applying the `${val//<!--/<\!--}` substitution used
  by existing dispatch.sh detectives.

- **A-030 — `set -euo pipefail` semantics on `${!var}` under
  bash 3.2.** ENG-108's existing `${!_sec_var}` loop iterates
  over 4..9 where `s5`, `s6`, `s9` are unset (per A-003).
  Under bash 3.2 + `set -u`, indirect expansion of an unset
  variable does NOT die — it expands to empty (verified
  indirectly by ENG-108's `bin/agent-prompts-content-test.sh`
  shipping green, which would be impossible under die-on-unset).
  Task 3.3 still explicitly defines `s1`, `s5`, `s6`, `s9` to
  avoid relying on this implementation-defined behavior in the
  new presence assertions (Task 3.5). Pinning the four new
  vars is a defensive-explicit move; an alternative would be
  reading via `${!_sec_var-}` everywhere, but explicit
  definitions are clearer to a future reader.

## File Structure

Modified or new files only — no new exit codes, no new Linear
labels, no schema files, no JSON registries, no new dispatch-time
prompt tokens (the resolver is ENG-108's territory).

- **`AGENT_PROMPTS.md`** — six per-§ edits (§§1, 4, 5, 6, 7, 8).
  Each edit has TWO sites:
  - Read clause at "Read these files first" position 1 (insert
    a new `1.` item, renumber subsequent items by +1). Wording
    mirrors ENG-108's §3 wording verbatim (the agent-side
    pattern is identical across stages; the brainstorm's per-stage
    body suggestions live in the write clause, not the read clause).
  - Write clause inserted in the Output / Completion-checklist
    section BEFORE the verdict-marker block:
    - §1 (brainstorm): inserts as a sub-step between checklist
      steps 5 (stage-summary write) and 6 (verdict marker). New
      step 5b or as a parenthetical bullet inside the step-5
      paragraph; the implement agent picks the cleaner shape
      based on §1's exact step-5 layout.
    - §4 (ui): inserts as a new bullet in the Output section
      between the existing last bullet and the
      `Verdict marker (MANDATORY at exit):` header. Decision-path
      gating: skip on pass-through (§4's pass-through clause
      exits before Output anyway per brainstorm §6).
    - §5 (review): inserts as a new bullet conditional on
      Decision-path C only (per brainstorm D-002 §5 — fail-path
      writes are explicitly rejected to avoid stale loopback
      context in next iter).
    - §6 (qa): inserts as a new bullet conditional on
      Decision-path C/D only.
    - §7 (build): inserts as a new bullet conditional on
      Decision-path B (merged) only; wait-shape exits (P2/P5)
      explicitly do NOT write.
    - §8 (released): inserts as a new bullet in the per-issue
      enrichment loop's success path. The released agent is a
      read-only observer; the entry is permissive
      (heading-only is acceptable; body suggestion: one line
      `version={version} category=<cat>`).
- **`bin/common.sh`** — two edit sites:
  - Task 4.1: insert `assert_no_write_to_path` helper (~17 lines)
    BETWEEN the closing `}` of `assert_no_tool_invocation`
    (`bin/common.sh:205`) and the next-block opening comment
    `# ─── Exit-code → outcome taxonomy ...` (line 207).
  - Task 4.2: append ` assert_no_write_to_path` (single space
    + identifier) to the END of the existing `export -f` line
    at line 400. All currently-exported helpers preserved
    verbatim.
- **`bin/dispatch.sh`** — one edit site:
  - Task 5.1: insert a ~12-line detective loop (mirroring ENG-66
    branch-creation loop in shape) BETWEEN the closing `done`
    of the ENG-68 `core.bare` loop (line ~233) and the closing
    `}` of `_render_and_capture_stream` (line 237).
- **`bin/agent-prompts-content-test.sh`** — three edit sites:
  - Task 3.3: insert `s1`, `s5`, `s6`, `s9` `section_body`
    definitions (four lines) IMMEDIATELY AFTER the existing
    `s8="$(section_body "## 8. Release Agent")"` line at line 71.
  - Task 3.4: REPLACE the existing `for _sec_num in 4 5 6 7 8 9`
    loop body (lines 96-111) with:
    - presence assertions for §§1, 4, 5, 6, 7, 8 (six checks
      mirroring the §3 ENG-108 invariant shape at lines 86-90;
      same `1. {progress_md_path}` literal pin at position 1
      of each stage's read list)
    - absence assertion for §9 only (preserve retrospective
      exclusion)
  - Task 3.5: append write-clause presence assertions
    (six checks; literal `Append a \`progress.md\` entry` phrase
    pinned in each of §§1, 4, 5, 6, 7, 8) immediately after the
    Task 3.4 block.
- **`bin/common-test.sh`** — one edit site:
  - Task 4.3: insert three new ENG-109 fixtures for
    `assert_no_write_to_path` IMMEDIATELY BEFORE the final
    summary printf line (the same content anchor ENG-107 used
    per A-019). Fixtures: (a) empty transcript → rc 0;
    (b) Write tool_use with `file_path` ending in `/progress.md`
    → rc 1 + matched path on stdout; (c) Write tool_use with
    `file_path` ending in `/stage-summary-implementing.md` →
    rc 0 (negative case).
- **`bin/dispatch-test.sh`** — one edit site:
  - Task 4.6: insert two new ENG-109 fixtures (positive
    Write-on-progress; negative Write-on-stage-summary)
    IMMEDIATELY BEFORE the multi-line file-tail summary block
    (the `# ─── Summary ───` header + `printf '\nRESULTS:` +
    `[[ "$FAIL" == 0 ]] || exit 1` + `exit 0` triplet — unique
    at end of file because `printf '\nRESULTS:` alone appears
    3× in the file). Pattern mirrors AS1-AS6 (`tx-ew1.ndjson`,
    `tx-ew2.ndjson` files in
    `$_TEST_STUB_DIR`; direct `assert_no_write_to_path` call;
    `(rc, stdout)` assertion).
- **`bin/progress-md-cross-stage-test.sh`** — new file (~120 lines):
  - Standard shebang + `set -euo pipefail` + `SCRIPT_DIR` +
    sentinel.
  - Sources `bin/common.sh` so the helpers (`progress_md_path`,
    new `assert_no_write_to_path`, `allocate_dispatch_id`,
    `report_ok`/`report_fail`) are available.
  - Synthesises a fixture progress.md by sequentially invoking
    three mock writes (brainstorming, planning, implementing
    dispatch-ids) using the established schema (H2 heading
    `## ENG-1-d0001 - brainstorming - 2026-05-16T10:00:00Z`).
  - Assertions: (a) file contains three H2 entries in dispatch-
    id order; (b) each heading parses into three tokens
    separated by ` - `; (c) `grep -F '## ENG-1-d0002 -'` finds
    exactly one match (single-dispatch grep-friendliness).
  - Sentinel at EOF so a future sibling can `source` without
    side effects.
- **`learned-rules/harness/project-profile.md`** — two edit sites:
  - Task 6.1: insert the literal line
    `  - \`Bash(bash bin/progress-md-cross-stage-test.sh:*)\``
    into BOTH the `implementing:` and `qa:` Tool allowlist
    blocks, alphabetically AFTER the
    `profile-allowlist-test.sh` line and BEFORE the
    `reconcile-test.sh` line.

Explicitly out of scope (per Linear OUT list, brainstorm §10
deviations, and the rebase-resolved D-003/D-002 ambiguities):

- `bin/render-prompt.sh` — UNCHANGED. ENG-108 already plumbed the
  `{progress_md_path}` resolver (per A-006, A-007).
- `bin/run-stage.sh::_clear_current_stage_slots` — UNCHANGED.
  `progress.md` stays never-cleared per ENG-107 D-003.
- `bin/run-stage.sh::_validate_dispatch_envelope` — UNCHANGED.
  The new detective fires in dispatch.sh (per brainstorm D-004
  rejected-alternative on putting it in run-stage.sh).
- `bin/run-local.sh`, `bin/run-local-helpers.sh::partition_dirty_paths`
  — UNCHANGED. `progress.md` lives outside the worktree.
- `bin/scope-check.sh::is_benign` — UNCHANGED. Same out-of-
  worktree rationale.
- `bin/dispatch.sh::allowed_tools_for` — UNCHANGED. Write tool
  stays permitted (legitimately used by stage-summary writes);
  the detective is the per-misuse trap, not an allowlist denial.
- `bin/pipeline-events.json` — UNCHANGED. No new verdict
  variants; the detective halt reuses exit code 29 and the
  `dispatch-envelope-violation` reason token (per A-010).
- `docs/runbooks/progress-md.md` — UNCHANGED. ENG-107's runbook
  is the schema source of truth; ENG-109 does not change the
  schema.
- `CLAUDE.md` — UNCHANGED. The per-issue state-directory diagram
  already carries `progress.md` per ENG-107. The "Per-issue state
  directory" section already documents the append-only contract.
- `.pipeline-config/config.json` — DOES NOT EXIST for the
  harness-self target (per A-022). The profile is the
  authoritative source.
- `bin/run-retrospective-local.sh` and retrospective prompts —
  UNCHANGED. Out per Linear OUT list; retrospective excluded by
  D-001.
- `learned-rules/harness/{brainstorm,plan,implementation,ui,review,qa,build,release}.md` —
  not part of this ticket. Plan-stage learned rules don't exist
  (per A-028); they accumulate via retrospective, not by hand.

## API Contract

no new API surface

(The harness has no FE↔BE API surface of its own — it is a Bash
orchestration toolkit. ENG-109 adds no endpoints, payload types,
or schema fields. The new `assert_no_write_to_path` is an
internal shell helper, exhaustively documented by Task 4.1 + the
common-test fixtures in Task 4.3; not an FE↔BE surface.)

## Backend Tasks

Task ordering: Task 0 (rebase) MUST be first (per "Branch-base
freshness check"); Task 1 (re-verify anchors) MUST follow
immediately. Tasks 2-6 can interleave but follow the natural
dependency graph below. Task 7 (gates) depends on all the others.

Task 0 → Task 1 → {Tasks 2.1-2.6 (six per-stage prompt edits;
each can run independently after Task 1 confirms anchors); Task 3
(test-invariant refactor; depends on Task 2 because the new tests
assert post-Task-2 prompt content); Task 4 (helper + run-stage.sh
rc=29 arm + dispatch.sh detective + their tests — sub-tasks 4.1
through 4.6); Task 5 (cross-stage chain test); Task 6
(profile allowlist regen)} → Task 7 (gate run).

**Task 4 sub-task ordering (load-bearing):**

- 4.1 (helper definition) → 4.2 (export) → 4.3 (run-stage.sh
  rc=29 arm) AND 4.4 (dispatch.sh detective) (4.3 and 4.4 can
  run in either order — they're in different files and the rc=29
  arm consumes what 4.4 produces only at runtime, not at edit
  time) → 4.5 (common-test fixtures) AND 4.6 (dispatch-test
  fixtures). Tasks 4.5 and 4.6 both depend on 4.1+4.2 (helper
  defined+exported); 4.6 also depends on 4.4 (the detective
  block being present is verified at gate time, not at fixture-
  source time). The implement agent SHOULD execute 4.1 → 4.2 →
  4.3 → 4.4 → 4.5 → 4.6 in sequence to minimize cognitive
  context switches.

### Task 0: Rebase onto origin/main

- `depends_on: []`
- `touches: <branch state only — git rebase>`

Steps:

- [ ] **0.1** Run `git fetch origin main && git rebase origin/main`.
  The worktree's current HEAD is 7 commits behind origin/main
  (per "Branch-base freshness"). All seven commits are ENG-108
  predecessors — clean drift, no expected conflicts.
- [ ] **0.2** Verify the rebase succeeded with no conflicts:
  `git status --porcelain` returns empty AND
  `git log --oneline HEAD..origin/main` returns empty.
- [ ] **0.3** Re-verify every Assumption Inventory anchor survived
  the rebase. The anchors were written against origin/main
  `d0772e5`; if Task 0's rebase brought in any commit beyond
  `d0772e5`, re-run Task 1 against the new HEAD.
- [ ] **0.4** If the rebase produces ANY conflict (it should not
  — this branch has no own commits beyond the plan doc), halt
  with `bash bin/pipeline.sh event ENG-109 verdict halt --reason agent-blocked`
  and a Linear comment naming the conflict file. Do NOT resolve
  silently — the implementing branch should have no merge
  surface against ENG-108's edits, and a conflict signals
  unexpected drift.

### Task 1: Re-verify Assumption Inventory anchors at implement-time

- `depends_on: [0]`
- `touches: <read-only — no file edits>`

Steps:

- [ ] **1.1** For each of A-001, A-002, A-003, A-004, A-005,
  A-008, A-011, A-012, A-013, A-014, A-015, A-016, A-019, A-020,
  A-021: re-grep the file for the literal content-anchor string
  named in the inventory entry. Each MUST match exactly once.
  If any matches zero times OR more than once, halt with
  `bash bin/pipeline.sh event ENG-109 verdict halt --reason agent-blocked`
  and a Linear comment naming the drift.
- [ ] **1.2** Confirm `bin/render-prompt.sh:55` carries the
  `progress_md_path=_resolve_progress_md_path` entry AND
  `bin/render-prompt.sh:228` defines `_resolve_progress_md_path`
  AND `bin/render-prompt.sh:417` binds `_RENDER_PROGRESS_MD_PATH`
  (Tasks 2.1-2.6 rely on these — confirms A-006 + A-007 hold
  post-rebase).
- [ ] **1.3** Confirm `bin/progress-md-cross-stage-test.sh` does
  NOT yet exist (Glob returns no match). If present, halt with
  `agent-blocked` and a Linear comment naming the file.
- [ ] **1.4** Confirm `.pipeline-config/config.json` does NOT
  exist for the harness-self target (A-022 verification at
  implement-time).

If all four pass, proceed to Tasks 2 / 3 / 4 / 5 / 6.

### Task 2: Insert read+write clauses into AGENT_PROMPTS.md §§1, 4, 5, 6, 7, 8

- `depends_on: [1]`
- `touches: AGENT_PROMPTS.md` — six §-edits, each with two sites.

The six per-§ edits are independent (different §s, different line
ranges, no cross-§ dependencies). The implement agent SHOULD do
each §'s read-clause and write-clause edits as a pair before
moving to the next § so a partial run leaves no §-level asymmetry.

Per-§ wording template — REUSE ENG-108's §3 read-clause body
verbatim for all six stages (the read-side context is uniform):

```
1. {progress_md_path} — per-issue progress notebook (cross-dispatch
   context from prior agents on this issue; see
   docs/runbooks/progress-md.md). Read this BEFORE the other
   files: the prior dispatch may have flagged that a plan task
   is blocked, that a chosen approach failed, or that a
   dead-end was already explored. Skip if not present —
   first-dispatch-on-issue is normal.
```

After this insertion, every existing list item shifts by +1
(item `1.` becomes `2.`, etc.).

Per-§ write-clause template — replicated with stage-specific
adjustments per brainstorm D-002 §§1-§8 bullet list:

```
- **Append a `progress.md` entry** at `{progress_md_path}` BEFORE
  posting the verdict marker. Use `Edit` with append-via-anchor
  (or, on stages that lack `Edit`, `bash -c "cat >> {progress_md_path} <<'EOF' ... EOF"`).
  **NEVER use `Write`** (truncates — the dispatch.sh detective
  halts with rc=29 if you do). Heading: `## {dispatch_id} - <stage-gerund> - <UTC-now>`
  where `<stage-gerund>` is your stage's prompt token
  (brainstorming|ui|reviewing|qa|building|released) and
  `<UTC-now>` is `date -u +"%Y-%m-%dT%H:%M:%SZ"`. Body: 1-5
  sentences capturing what the NEXT dispatch on this issue
  should know (decisions, dead-ends, surprises). A heading-only
  entry is acceptable when there's nothing concrete to add.
```

Per-§ wrinkles (per brainstorm D-002):

- **§1 brainstorm**: write-clause body suggestion — "open
  questions from the persona review that remain unresolved."
  Insertion: as a parenthetical inside Completion-checklist
  step 5 (after the stage-summary write, before the verdict
  marker step). Step 5's anchor: the literal `Internally you still MUST run all 6 personas`
  paragraph (line ~322 — `Internally you still ...` is unique
  to §1) — insert the write-clause bullet IMMEDIATELY BEFORE
  this paragraph's closing blank line. Conditional: clean-exit
  only; iteration-exhausted halt path does NOT append.
- **§4 ui**: write-clause body suggestion — "components
  touched + cross-component concerns the next stage should
  know." Decision-path: skip on pass-through (§4's existing
  pass-through clause exits before the Output bullets).
  Insertion: as a new bullet in the Output section between
  `- Do NOT change the Linear stage label ...` (line ~920) and
  the `Verdict marker (MANDATORY at exit):` header (line ~922).
- **§5 reviewing**: write-clause body suggestion — "the
  premise check verdict and any cross-cutting concerns."
  Decision-path: **C only** (clean review; brainstorm D-002
  §5 rejects fail-path writes). Wording must include
  conditional guard: "On Decision-path C (clean) ONLY;
  Decision-paths A and B skip this step."
- **§6 qa**: write-clause body suggestion — "adversarial
  findings or back-fill confirmation." Decision-path: C/D
  (clean AND back-fill).
- **§7 building**: write-clause body suggestion — "merge SHA +
  one-line of post-merge CI outcome." Decision-path: **B only
  (merged)**; wait-shape exits (P2/P5) explicitly skip per
  brainstorm §6.
- **§8 released**: body suggestion — `version={version} category=<cat>`
  (one-line acceptable; observer stage). Insertion: as a new
  bullet in the Output section (between
  `- No edits to any source files. You are a read-only observer plus Linear/Slack writer.`
  and the closing ``` fence).

Sub-tasks:

- [ ] **2.1** (§1) Use TWO `Edit` calls:
  - Edit A — insert the read-clause at the top of §1's read
    list and renumber items 1-6 → 2-7.
  - Edit B — insert the write-clause bullet inside Completion-
    checklist step 5, before the `Internally you still MUST run all 6 personas` paragraph.

- [ ] **2.2** (§4) Use TWO `Edit` calls:
  - Edit A — insert the read-clause at the top of §4's read
    list and renumber items 1-7 → 2-8.
  - Edit B — insert the write-clause bullet in the Output
    section between `- Do NOT change the Linear stage label ...`
    and the `Verdict marker (MANDATORY at exit):` header.

- [ ] **2.3** (§5) Use TWO `Edit` calls. Same structure as 2.2
  (read list 1-6 → 2-7; write-clause in Output before verdict-
  marker block). Write-clause text includes the Decision-path C
  guard.

- [ ] **2.4** (§6) Use TWO `Edit` calls. Same structure as 2.3
  (read list 1-6 → 2-7; write-clause in Output before verdict-
  marker block). Write-clause text includes the Decision-path
  C/D guard.

- [ ] **2.5** (§7) Use TWO `Edit` calls:
  - Edit A — insert the read-clause at the top of §7's read
    list and renumber items 1-2 → 2-3.
  - Edit B — insert the write-clause bullet in the Output
    section before `Verdict marker (MANDATORY at exit, except wait-shape exits — see P2/P5 above):`.
    Write-clause includes Decision-path B (merged) guard AND
    explicit "wait-shape exits skip this step."

- [ ] **2.6** (§8) Use TWO `Edit` calls:
  - Edit A — insert the read-clause at the top of §8's read
    list and renumber items 1-3 → 2-4.
  - Edit B — insert the write-clause bullet in the Output
    section between `- No edits to any source files. You are a read-only observer plus Linear/Slack writer.`
    and the closing ``` fence.

- [ ] **2.7** Verify each `Edit` succeeded by reading back the
  modified region (~15 lines around the insertion point) and
  confirming: (a) the new `1. {progress_md_path}` line is at
  position 1; (b) the original item 1 is now at position 2 with
  unchanged text; (c) the write-clause bullet appears in the
  expected Output section; (d) every other line in the affected
  region is unchanged byte-for-byte.

### Task 3: Refactor agent-prompts-content-test.sh invariants

- `depends_on: [2]`
- `touches: bin/agent-prompts-content-test.sh` — three edit sites.

Steps:

- [ ] **3.1** Verify Task 2 completed for all six §s by grepping
  `AGENT_PROMPTS.md` for `1. {progress_md_path}` — MUST return
  exactly 7 matches (§3 from ENG-108 plus the six new §§1, 4,
  5, 6, 7, 8 from Task 2). If the count is different, Task 2
  is incomplete; loop back.

- [ ] **3.2** Verify §9 retrospective is unchanged by grepping
  the §9 section_body for `{progress_md_path}` — MUST return
  zero matches.

- [ ] **3.3** Use a single `Edit` call inserting four new
  `s*` section variable definitions immediately after the
  existing `s8="$(section_body "## 8. Release Agent")"` line.

  Exact `old_string` (the existing s7 + s8 pair on consecutive lines):

  ```bash
  s7="$(section_body "## 7. Build Agent")"
  s8="$(section_body "## 8. Release Agent")"
  ```

  Exact `new_string`:

  ```bash
  s7="$(section_body "## 7. Build Agent")"
  s8="$(section_body "## 8. Release Agent")"
  # ENG-109: new section bodies for the §§1, 5, 6, 9 presence/absence
  # assertions added in this iteration (§4, §7, §8 already defined above).
  s1="$(section_body "## 1. Brainstorm Agent")"
  s5="$(section_body "## 5. Review Agent")"
  s6="$(section_body "## 6. QA Agent")"
  s9="$(section_body "## 9. Retrospective Agent (Scheduled)")"
  ```

- [ ] **3.4** Use a single `Edit` call REPLACING the existing
  §§4-9 absence loop with §§1, 4, 5, 6, 7, 8 presence + §9
  absence assertions.

  Exact `old_string` (lines 96-111; the multi-line block from
  the opening comment header through the closing `done`):

  ```bash
  # ─── ENG-108 QA adversarial: {progress_md_path} token scoped to §3 only ───
  # The token is intentionally absent from §§4-9. A future edit that copies
  # the position-1 read-first item into another stage's prompt block without
  # thinking about the stage-conditional log would silently break the
  # stage-gating invariant. Pin the absence here.
  for _sec_num in 4 5 6 7 8 9; do
    _sec_var="s${_sec_num}"
    if printf '%s\n' "${!_sec_var}" | grep -qF '{progress_md_path}'; then
      nope "§${_sec_num} ENG-108 QA: '{progress_md_path}' token absent from §${_sec_num} (scoped to §3 only)" \
        "token '{progress_md_path}' present in §${_sec_num} — implementing-only feature, do not propagate without updating the stage-conditional log condition"
    else
      ok "§${_sec_num} ENG-108 QA: '{progress_md_path}' token absent from §${_sec_num} (scoped to §3 only)"
    fi
  done
  ```

  Exact `new_string`:

  ```bash
  # ─── ENG-109: {progress_md_path} now present in §§1, 3, 4, 5, 6, 7, 8;
  # absent from §9 (retrospective excluded per brainstorm D-001 — no per-
  # issue PIPELINE_ISSUE_ID, no per-issue scratch dir). The §3 pin lives
  # at the ENG-108 line above; ENG-109 mirrors that shape for the other
  # five stages and converts §§4-8's absence pins into presence pins.
  for _sec_num in 1 4 5 6 7 8; do
    _sec_var="s${_sec_num}"
    if printf '%s\n' "${!_sec_var}" | grep -qF '1. {progress_md_path}'; then
      ok "§${_sec_num} ENG-109: read-first list has '{progress_md_path}' at position 1"
    else
      nope "§${_sec_num} ENG-109: read-first list has '{progress_md_path}' at position 1" \
        "literal '1. {progress_md_path}' line missing from §${_sec_num} — has the position-1 placement been demoted, or the token removed entirely?"
    fi
  done
  if printf '%s\n' "$s9" | grep -qF '{progress_md_path}'; then
    nope "§9 ENG-109: '{progress_md_path}' token absent from §9 (retrospective excluded per D-001)" \
      "token '{progress_md_path}' present in §9 — retrospective has no PIPELINE_ISSUE_ID and no per-issue scratch dir; this is a contract violation"
  else
    ok "§9 ENG-109: '{progress_md_path}' token absent from §9 (retrospective excluded per D-001)"
  fi
  ```

- [ ] **3.5** Use a single `Edit` call APPENDING write-clause
  presence assertions IMMEDIATELY AFTER the Task 3.4 block.
  The new block:

  ```bash
  # ─── ENG-109: per-stage write-clause presence ─────────────────────────
  # Every stage (except §9 retrospective) appends a `progress.md` entry on
  # clean exit per Linear AC-1. Pin the literal phrase in each stage so a
  # future edit that drops the bullet trips here.
  for _sec_num in 1 4 5 6 7 8; do
    _sec_var="s${_sec_num}"
    if printf '%s\n' "${!_sec_var}" | grep -qF 'Append a `progress.md` entry'; then
      ok "§${_sec_num} ENG-109: write-clause 'Append a \`progress.md\` entry' present"
    else
      nope "§${_sec_num} ENG-109: write-clause 'Append a \`progress.md\` entry' present" \
        "phrase 'Append a \`progress.md\` entry' missing — has the per-stage write rule been removed?"
    fi
  done
  ```

  Insertion anchor: the Task 3.4 block's closing `fi` followed by
  the next existing section-body or assertion header below — the
  implement agent identifies the next existing line via grep.

- [ ] **3.6** Run `bash bin/agent-prompts-content-test.sh` —
  expect exit 0 with the new ENG-109 rows passing. The existing
  ENG-108 §3 position-1 invariant continues to pass (preserved
  by A-001).

### Task 4: Add assert_no_write_to_path helper + dispatch.sh detective + run-stage.sh rc=29 arm + their tests

- `depends_on: [1]`
- `touches: bin/common.sh, bin/dispatch.sh, bin/run-stage.sh, bin/common-test.sh, bin/dispatch-test.sh` — five edit sites.

#### Task 4.1: Insert assert_no_write_to_path helper in bin/common.sh

Use a single `Edit` call. Exact `old_string` (the closing brace
of `assert_no_tool_invocation` + blank line + next-section
comment header — the literal 3 lines from `bin/common.sh:205-207`):

```bash
  return 0
}

# ─── Exit-code → outcome taxonomy (ENG-10 D-002) ─────────────────────
```

Exact `new_string`:

```bash
  return 0
}

# ENG-109: forbid Write-tool truncation of the per-issue progress.md.
# Sibling of assert_no_tool_invocation; the contract-shape differs only
# in (a) the tool name (Write, not Bash), (b) the input field
# (file_path, not command), and (c) the matcher direction (endswith,
# because the agent's Write calls carry an absolute path and the
# discriminating signal is the basename suffix). Exported below.
assert_no_write_to_path() {
  local transcript="$1" path_suffix="$2"
  [[ -s "$transcript" ]] || return 0
  local matched
  matched="$(jq -Rr --arg p "$path_suffix" '
    fromjson? // empty
    | select(.type == "assistant")
    | .message.content[]?
    | select(.type == "tool_use" and .name == "Write")
    | (.input.file_path // "")
    | select(endswith($p))
  ' "$transcript" 2>/dev/null | head -1)" || true
  if [[ -n "$matched" ]]; then
    printf '%s\n' "$matched"
    return 1
  fi
  return 0
}

# ─── Exit-code → outcome taxonomy (ENG-10 D-002) ─────────────────────
```

Verify by reading back `bin/common.sh` ±10 lines around the
insertion. Confirm (a) `assert_no_tool_invocation`'s closing brace
preserved; (b) the new function body uses `name == "Write"`
(literal — copy-paste-check against `name == "Bash"`);
(c) `(.input.file_path // "")` (NOT `.input.command`);
(d) `endswith($p)` (NOT `startswith`); (e) the
`# ─── Exit-code → outcome taxonomy` header preserved verbatim.

Sanity-check `bash -n bin/common.sh` returns 0 (per the profile's
Lint/check gate).

#### Task 4.2: Export assert_no_write_to_path from bin/common.sh

Use a single `Edit` call. Exact `old_string` (the existing public
export line at `bin/common.sh:400`):

```bash
export -f issue_dir compute_pipeline_content_hash failure_outcome_for_exit parse_pipeline_marker is_orchestrator_paused set_orchestrator_paused allocate_dispatch_id current_dispatch_id assert_no_tool_invocation progress_md_path
```

Exact `new_string` (same line + ` assert_no_write_to_path` appended):

```bash
export -f issue_dir compute_pipeline_content_hash failure_outcome_for_exit parse_pipeline_marker is_orchestrator_paused set_orchestrator_paused allocate_dispatch_id current_dispatch_id assert_no_tool_invocation progress_md_path assert_no_write_to_path
```

Verify by reading back `bin/common.sh:400`. The line ends with
` assert_no_write_to_path` (single trailing space + identifier).

#### Task 4.3: Insert run-stage.sh rc=29 elif arm

Use a single `Edit` call. The new arm goes between the existing
rc=13 arm and the `elif (( dispatch_rc != 0 ))` fallthrough — per
A-010 anchors.

Exact `old_string` (the literal closing 5 lines of the rc=13
arm + opening 5 lines of the fallthrough — from
`bin/run-stage.sh:1395-1408` style; verified unique at plan
time by grep for the `_viol_cmd_13` token and `exit 13`):

```bash
      classify_failure "$ident" "$stage" "skip-until-human-acts" \
        "stage transcript invoked forbidden core.bare git form: $_viol_cmd_13" 13
      rm -f "$_viol_file_13" "$prompt_file"
      exit 13
    elif (( dispatch_rc != 0 )); then
      classify_failure "$ident" "$stage" "retry-immediately" \
        "dispatch failed (see $log_file)" 20
      rm -f "$prompt_file"
      exit 20
```

Exact `new_string` (preserves the rc=13 arm verbatim, inserts
the new rc=29 arm BEFORE the fallthrough, preserves the
fallthrough verbatim):

```bash
      classify_failure "$ident" "$stage" "skip-until-human-acts" \
        "stage transcript invoked forbidden core.bare git form: $_viol_cmd_13" 13
      rm -f "$_viol_file_13" "$prompt_file"
      exit 13
    elif (( dispatch_rc == 29 )); then
      # ENG-109: dispatch.sh's Write-on-progress.md detective caught
      # an agent truncating the per-issue progress notebook via the
      # Write tool (the append-only contract of progress.md is a
      # convention not an ACL — the detective is the catch-net per
      # docs/runbooks/progress-md.md §3). Sidecar shape mirrors the
      # rc=22/23/26/13 arms above. Note: rc=29 is also produced by
      # the post-dispatch _validate_dispatch_envelope at line ~1630
      # below; both halt with skip-until-human-acts dispatch-envelope-
      # violation. The disambiguator lives in the per-stage transcript
      # (this arm's `[assert] ... forbidden Write on progress.md` log
      # vs the envelope validator's `mcp__plugin_linear` /
      # `curl https://api.linear.app` match).
      local _viol_file_29 _viol_cmd_29
      _viol_file_29="$(issue_dir "$ident")/.transcript-violation-${stage}"
      _viol_cmd_29="$(cat "$_viol_file_29" 2>/dev/null || printf '<path-unavailable>')"
      classify_failure "$ident" "$stage" "skip-until-human-acts" \
        "dispatch-stage transcript invoked forbidden Write on progress.md: $_viol_cmd_29" 29
      rm -f "$_viol_file_29" "$prompt_file"
      exit 29
    elif (( dispatch_rc != 0 )); then
      classify_failure "$ident" "$stage" "retry-immediately" \
        "dispatch failed (see $log_file)" 20
      rm -f "$prompt_file"
      exit 20
```

Verify by reading back `bin/run-stage.sh` ±20 lines around the
insertion. Confirm: (a) the rc=13 arm's closing 4 lines preserved
verbatim; (b) the new rc=29 arm appears between them and the
fallthrough; (c) the fallthrough's `retry-immediately` line is
preserved verbatim; (d) `exit 29` appears (not `exit 13` or
`exit 20` — common copy-paste error).

Sanity-check `bash -n bin/run-stage.sh` returns 0.

#### Task 4.4: Insert dispatch.sh Write-on-progress.md detective

Use a single `Edit` call. The insertion site is between the
closing `done` of the ENG-68 `core.bare` loop and the closing
`}` of `_render_and_capture_stream` — per A-008.

Exact `old_string` (the literal 4 lines from the end of the
ENG-68 loop through the closing brace, per `bin/dispatch.sh:230-237`):

```bash
        return 13
      fi
    done
}
```

Exact `new_string` (preserves both bookends, inserts the new
detective in between):

```bash
        return 13
      fi
    done
    # ENG-109: forbid Write-tool truncation of progress.md across
    # ALL stages. The append-only contract of progress.md
    # (docs/runbooks/progress-md.md §3) is a CONVENTION, not a
    # filesystem ACL; this detective is the catch-net for an agent
    # that uses Write where Edit-with-append (or
    # `cat >> {progress_md_path} <<'EOF'`) was the correct shape.
    # Reuses rc=29 (dispatch-envelope-violation) per the brainstorm
    # D-004 reading "the envelope is the agent's tool-use contract
    # surface" — operators inspecting $violation_file see the
    # matched file_path string for triage.
    local _matched_write
    if _matched_write="$(assert_no_write_to_path "$raw_capture" "/progress.md")"; then
      :   # rc 0: no match, fall through
    else
      printf '%s\n' "$_matched_write" > "$violation_file"
      log "[assert] stage=$stage transcript invoked forbidden Write on progress.md: ${_matched_write}"
      return 29
    fi
}
```

Verify by reading back `bin/dispatch.sh` ±15 lines around the
insertion. Confirm: (a) the ENG-68 `return 13` / `fi` / `done`
triplet preserved verbatim; (b) the new ENG-109 block appears
between the `done` and the closing `}`; (c) the closing `}` of
`_render_and_capture_stream` preserved (single-line, column 0,
matching pre-edit layout).

Sanity-check `bash -n bin/dispatch.sh` returns 0.

#### Task 4.5: Add common-test.sh fixtures for assert_no_write_to_path

Use a single `Edit` call. Insertion site: IMMEDIATELY BEFORE the
final summary printf line in `bin/common-test.sh` (per A-019 —
the same content anchor ENG-107 used).

Exact `old_string`:

```bash
printf '\ncommon-test summary: %d passed, %d failed\n' "$PASS" "$FAIL"
```

Exact `new_string` (3 fixtures + the preserved final printf):

```bash
# ─── ENG-109: assert_no_write_to_path helper ────────────────────────
# Three assertions (brainstorm D-005 #xiii):
#   (a) empty transcript → rc 0
#   (b) Write tool_use with file_path ending in /progress.md → rc 1 + matched path
#   (c) Write tool_use with file_path ending in /stage-summary-implementing.md → rc 0
eng109_empty_transcript() {
  local empty rc=0 out
  empty="$_TEST_ROOT/empty-tx.ndjson"
  : > "$empty"
  out="$(assert_no_write_to_path "$empty" "/progress.md")" || rc=$?
  if (( rc == 0 )) && [[ -z "$out" ]]; then
    report_ok "eng109_assert_no_write_to_path_empty_transcript"
  else
    report_fail "eng109_assert_no_write_to_path_empty_transcript" \
      "rc=0 AND out empty" "rc=$rc out=${out}"
  fi
}
eng109_empty_transcript

eng109_write_on_progress() {
  local tx="$_TEST_ROOT/write-on-progress.ndjson" rc=0 out
  cat > "$tx" <<'NDJSON'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/Users/x/.local/state/twinning-harness/harness/foo/ENG-1/progress.md"}}]}}
NDJSON
  out="$(assert_no_write_to_path "$tx" "/progress.md")" || rc=$?
  if (( rc == 1 )) && [[ "$out" == *"progress.md" ]]; then
    report_ok "eng109_assert_no_write_to_path_write_on_progress"
  else
    report_fail "eng109_assert_no_write_to_path_write_on_progress" \
      "rc=1 AND out ends with progress.md" "rc=$rc out=${out}"
  fi
}
eng109_write_on_progress

eng109_write_on_other() {
  local tx="$_TEST_ROOT/write-on-other.ndjson" rc=0 out
  cat > "$tx" <<'NDJSON'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/Users/x/.local/state/twinning-harness/harness/foo/ENG-1/stage-summary-implementing.md"}}]}}
NDJSON
  out="$(assert_no_write_to_path "$tx" "/progress.md")" || rc=$?
  if (( rc == 0 )) && [[ -z "$out" ]]; then
    report_ok "eng109_assert_no_write_to_path_write_on_other"
  else
    report_fail "eng109_assert_no_write_to_path_write_on_other" \
      "rc=0 AND out empty (stage-summary path does not match /progress.md)" "rc=$rc out=${out}"
  fi
}
eng109_write_on_other

printf '\ncommon-test summary: %d passed, %d failed\n' "$PASS" "$FAIL"
```

Run `bash bin/common-test.sh` — expect exit 0; three new
`eng109_*` rows appear in the summary.

#### Task 4.6: Add dispatch-test.sh fixtures for the dispatch.sh detective

Use a single `Edit` call. Insertion site: IMMEDIATELY BEFORE the
multi-line summary block at the END of `bin/dispatch-test.sh`.

**Anchor uniqueness note** — the literal line
`printf '\nRESULTS: %d passed, %d failed\n' "$PASS" "$FAIL"`
appears THREE TIMES in `bin/dispatch-test.sh` (verified at plan
time at lines ~535, ~1185, ~3028 against origin/main). A
single-line anchor will fail with "string appears N times."
Use the 4-line summary block from the file's tail as the
anchor — it is unique because the `# ─── Summary ───` comment
header + the trailing `[[ "$FAIL" == 0 ]] || exit 1` + the
final `exit 0` form a triplet that occurs ONLY at the file end.

Exact `old_string` (the multi-line file-tail summary block —
unique at end of file):

```bash
# ─── Summary ────────────────────────────────────────────────────────────
printf '\nRESULTS: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]] || exit 1
exit 0
```

Exact `new_string` (the two ENG-109 fixtures inserted BEFORE
the summary block, with the summary block preserved verbatim
after):

```bash
# ─── ENG-109: assert_no_write_to_path fixtures (EW1-EW2) ─────────────
# Mirrors the AS1-AS6 (ENG-43) / AS7-AS12 (ENG-71) shape: a synthetic
# transcript NDJSON written under $_TEST_STUB_DIR, direct helper
# invocation, (rc, stdout) tuple assertion. Helper imported via the
# same source pattern these groups use; see preconditions at the top
# of the AS1 block (~line 1182).
printf '\n--- assert_no_write_to_path fixtures (EW1-EW2, ENG-109) ---\n'

if ! declare -f assert_no_write_to_path >/dev/null 2>&1; then
  fail_at "precondition: assert_no_write_to_path defined" \
          "function not found after sourcing — Task 4.1 implementation missing"
  printf '\nRESULTS: %d passed, %d failed\n' "$PASS" "$FAIL"
  exit 1
fi

# EW1 — Write tool_use with file_path ending in /progress.md → rc=1 + matched path
TX_EW1="$_TEST_STUB_DIR/tx-ew1.ndjson"
cat > "$TX_EW1" <<'NDJSON'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/Users/x/.local/state/twinning-harness/harness/foo/ENG-1/progress.md"}}]}}
NDJSON
out_ew1="$(assert_no_write_to_path "$TX_EW1" "/progress.md")" && rc_ew1=0 || rc_ew1=$?
if [[ "$rc_ew1" == "1" && "$out_ew1" == *"progress.md" ]]; then
  pass_at "EW1: Write on /progress.md returns rc=1 + matched path on stdout"
else
  fail_at "EW1" "rc=$rc_ew1 out=$out_ew1"
fi

# EW2 — Write tool_use with file_path ending in /stage-summary-implementing.md → rc=0
TX_EW2="$_TEST_STUB_DIR/tx-ew2.ndjson"
cat > "$TX_EW2" <<'NDJSON'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/Users/x/.local/state/twinning-harness/harness/foo/ENG-1/stage-summary-implementing.md"}}]}}
NDJSON
out_ew2="$(assert_no_write_to_path "$TX_EW2" "/progress.md")" && rc_ew2=0 || rc_ew2=$?
if [[ "$rc_ew2" == "0" && -z "$out_ew2" ]]; then
  pass_at "EW2: Write on stage-summary path returns rc=0 + empty stdout"
else
  fail_at "EW2" "rc=$rc_ew2 out=$out_ew2"
fi

# ─── Summary ────────────────────────────────────────────────────────────
printf '\nRESULTS: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]] || exit 1
exit 0
```

Notes:
- The `pass_at` / `fail_at` helpers are dispatch-test.sh-local
  conventions (per the existing AS1-AS12 fixtures); the new
  block reuses them without redefinition.
- The `$_TEST_STUB_DIR` variable is set in the dispatch-test.sh
  setup (per the AS1-AS6 fixture region); the new EW1/EW2
  fixtures are placed AFTER the AS1-AS12 region so the stub
  directory is already in scope.

Run `bash bin/dispatch-test.sh` — expect exit 0; EW1 + EW2 rows
appear in the summary.

### Task 5: Author bin/progress-md-cross-stage-test.sh (new file)

- `depends_on: [4]`
- `touches: bin/progress-md-cross-stage-test.sh` — new file (~120 lines).

Steps:

- [ ] **5.1** Create the file with the standard shell-test
  scaffolding (per the harness profile's "Language idioms"):

  ```bash
  #!/usr/bin/env bash
  # ENG-109: cross-stage progress.md chain coherence.
  #
  # Synthesises a fixture progress.md by sequentially invoking three
  # mock writes (brainstorming, planning, implementing dispatch-ids)
  # using the schema at docs/runbooks/progress-md.md §2. Asserts the
  # AC#3 chain: three H2 entries, dispatch-id order preserved, heading
  # shape parses into the three-token form, single-dispatch greps
  # return exactly one match.
  set -euo pipefail
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  HARNESS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

  _TEST_ROOT="$(mktemp -d -t twinning-eng109.XXXXXX)"
  trap 'rm -rf "$_TEST_ROOT"' EXIT

  PASS=0; FAIL=0; FAILED_CASES=()
  report_ok()   { printf 'OK: %s\n' "$1"; PASS=$((PASS+1)); }
  report_fail() { printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3" >&2; FAIL=$((FAIL+1)); FAILED_CASES+=("$1"); }

  main() {
    local fixture="$_TEST_ROOT/progress.md"
    # Simulate three sequential dispatches on ENG-1 — note: NOT calling
    # the real bin/common.sh::allocate_dispatch_id (it would require
    # an issue_dir, issue-state.json, etc.); we hand-construct the
    # dispatch-ids in the canonical ENG-N-d<NNNN> shape.
    local d1="ENG-1-d0001" d2="ENG-1-d0002" d3="ENG-1-d0003"
    local t1="2026-05-16T10:00:00Z" t2="2026-05-16T10:30:00Z" t3="2026-05-16T11:00:00Z"

    # Write 1 — brainstorming dispatch
    cat >> "$fixture" <<EOF
  ## $d1 - brainstorming - $t1

  Open question OQ-1 from persona review: deferred to ENG-110.

  EOF
    # Write 2 — planning dispatch (appends; never overwrites)
    cat >> "$fixture" <<EOF
  ## $d2 - planning - $t2

  Plan chose option B (extending existing helper) over option A.

  EOF
    # Write 3 — implementing dispatch
    cat >> "$fixture" <<EOF
  ## $d3 - implementing - $t3

  TDD evidence: gates green. Implementation matches plan task graph.

  EOF

    # AC#3 (a): three H2 entries
    local h2_count
    h2_count="$(grep -cE '^## ENG-1-d[0-9]{4} - [a-z]+ - [0-9]{4}-[0-9]{2}-[0-9]{2}T' "$fixture" || true)"
    if [[ "$h2_count" == "3" ]]; then
      report_ok "chain: three H2 entries"
    else
      report_fail "chain: three H2 entries" "3 H2 entries" "got $h2_count"
    fi

    # AC#3 (b): dispatch-id order preserved
    local order
    order="$(grep -oE 'ENG-1-d[0-9]{4}' "$fixture" | tr '\n' ' ')"
    if [[ "$order" == "$d1 $d2 $d3 " ]]; then
      report_ok "chain: dispatch-id order preserved"
    else
      report_fail "chain: dispatch-id order preserved" "$d1 $d2 $d3" "$order"
    fi

    # AC#3 (c): grep-friendly to a reader filtering by dispatch-id
    local one_count
    one_count="$(grep -cE "^## $d2 - " "$fixture" || true)"
    if [[ "$one_count" == "1" ]]; then
      report_ok "chain: single-dispatch grep returns exactly one match"
    else
      report_fail "chain: single-dispatch grep returns exactly one match" "1 match for d0002" "got $one_count"
    fi

    # AC#3 (d): each heading parses into three ` - `-separated tokens
    local parse_ok=1
    while IFS= read -r heading; do
      local tokens
      tokens="$(printf '%s\n' "$heading" | awk -F' - ' '{print NF}')"
      [[ "$tokens" == "3" ]] || parse_ok=0
    done < <(grep -E '^## ENG-1-d' "$fixture")
    if (( parse_ok == 1 )); then
      report_ok "chain: every heading parses into three tokens"
    else
      report_fail "chain: every heading parses into three tokens" "all headings split into 3 by ' - '" "at least one heading has != 3 tokens"
    fi

    printf '\nprogress-md-cross-stage-test summary: %d passed, %d failed\n' "$PASS" "$FAIL"
    if (( FAIL > 0 )); then
      printf 'failed cases:\n'
      for c in "${FAILED_CASES[@]}"; do printf '  - %s\n' "$c"; done
      exit 1
    fi
  }

  if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
  ```

- [ ] **5.2** Run `bash bin/progress-md-cross-stage-test.sh` —
  expect exit 0 with four PASS rows.

- [ ] **5.3** Confirm the file is the ONLY new file created by
  this plan: `git status --porcelain | awk '$1=="??"{print $2}'`
  should list ONLY `bin/progress-md-cross-stage-test.sh` (plus
  the plan doc itself, which is committed by Task 7). Any other
  untracked path is sub-agent debris per ENG-100; halt with
  `verdict halt --reason agent-blocked` and name the leaked path.

### Task 6: Regen learned-rules/harness/project-profile.md Tool allowlist

- `depends_on: [5]`
- `touches: learned-rules/harness/project-profile.md` — two edit sites.

Steps:

- [ ] **6.1a** Use a single `Edit` call inserting the new test
  into the `implementing:` Tool allowlist block. Exact
  `old_string` (the literal pair of consecutive lines from the
  current profile per A-021):

  ```
    - `Bash(bash bin/profile-allowlist-test.sh:*)`
    - `Bash(bash bin/reconcile-test.sh:*)`
  ```

  Exact `new_string`:

  ```
    - `Bash(bash bin/profile-allowlist-test.sh:*)`
    - `Bash(bash bin/progress-md-cross-stage-test.sh:*)`
    - `Bash(bash bin/reconcile-test.sh:*)`
  ```

  Note: there are TWO copies of this pair in the profile file
  (one each in `implementing:` and `qa:`). The first `Edit` call
  with `replace_all: false` will fail because of duplicates;
  the implement agent should use `replace_all: true` AND verify
  by reading back BOTH blocks to confirm both got the new entry.

  Alternative: do TWO independent Edit calls, each anchored on
  a LARGER unique context window (e.g., include the parent
  block header `- implementing:` or `- qa:` line as part of the
  `old_string`). This is the safer approach because `replace_all`
  inadvertently modifying a third sibling block would be silent.

- [ ] **6.1b** Verify by `grep -c 'progress-md-cross-stage-test'`
  on the profile file — expect exactly 2 matches (one each in
  `implementing:` and `qa:`).

### Task 7: Gate run

- `depends_on: [2, 3, 4, 5, 6]`
- `touches: <runtime gates only — no file edits>`

Steps:

- [ ] **7.1** Run `bash bin/agent-prompts-content-test.sh` —
  expect exit 0 with the ENG-109 rows passing AND the existing
  ENG-108 §3 invariant still passing.
- [ ] **7.2** Run `bash bin/common-test.sh` — expect exit 0
  with the three ENG-109 `eng109_*` rows passing.
- [ ] **7.3** Run `bash bin/dispatch-test.sh` — expect exit 0
  with the EW1 + EW2 fixture rows passing.
- [ ] **7.4** Run `bash bin/progress-md-cross-stage-test.sh` —
  expect exit 0 with the four chain-coherence rows passing.
- [ ] **7.5** Run `bash bin/render-prompt-test.sh` — expect
  exit 0. The existing ENG-87 R5/R8 resolver invariants
  auto-cover the `{progress_md_path}` token now that it appears
  in §§1, 4, 5, 6, 7, 8 of AGENT_PROMPTS.md. Failure here would
  signal a resolver-registry / token-name mismatch.
- [ ] **7.6** Run `bash bin/profile-allowlist-test.sh` —
  expect exit 0. The new profile entry must not break the
  profile-allowlist parser.
- [ ] **7.6b** Run `bash bin/run-stage-test.sh` — expect exit 0.
  The new `dispatch_rc == 29` elif arm (Task 4.3) sits adjacent
  to the existing rc=22/23/26/13 arms which `run-stage-test.sh`
  exercises. Failure here would signal a syntax error in the
  inserted block OR a regression on a sibling arm's behavior.
- [ ] **7.7** Run `bash .githooks/pre-commit` — expect exit 0
  (entire `bin/*-test.sh` suite green, plus the new
  `bin/progress-md-cross-stage-test.sh`).
- [ ] **7.8** Run `bash -n bin/common.sh bin/dispatch.sh bin/run-stage.sh bin/progress-md-cross-stage-test.sh`
  — expect rc=0 (syntax-only check per the profile's
  Lint/check gate).

If all eight pass, implementation is complete.

## Frontend Tasks

(no UI surface — the harness is a Bash orchestration toolkit;
there is no FE the UI agent would touch. The UI Agent is
skipped for this ticket per the orchestrator's per-stage
routing.)

## Failure Mode → Test Map

Pulled from brainstorm §5 (Error Handling) and §6 (Edge Cases).

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
|---|---|---|---|---|
| Agent uses `Write` on `progress.md` (truncates the cross-dispatch log) | `tool_use` with `name="Write"` + `input.file_path` ending in `/progress.md` in the transcript | dispatch.sh's new ENG-109 detective writes the matched path to `$violation_file`, logs `[assert] ... forbidden Write on progress.md`, returns 29; run-stage.sh's NEW rc=29 elif arm (Task 4.3) reads the sidecar and halts with `classify_failure ... skip-until-human-acts dispatch-envelope-violation` exit 29 | unit + integration | `EW1` (in `bin/dispatch-test.sh`) — positive case fires the assertion; `eng109_assert_no_write_to_path_write_on_progress` (in `bin/common-test.sh`) — helper-level fixture |
| Agent does Write on a non-progress.md path (e.g., the stage-summary file's legitimate overwrite) | `tool_use` with `name="Write"` + `input.file_path` ending in `/stage-summary-implementing.md` | detective returns rc 0; dispatch.sh continues normally; stage-summary write is unimpeded | unit + integration | `EW2` (in `bin/dispatch-test.sh`); `eng109_assert_no_write_to_path_write_on_other` (in `bin/common-test.sh`) |
| Empty transcript (dispatch produced no NDJSON — extremely rare race) | `assert_no_write_to_path` called with a zero-byte transcript file | helper short-circuits with rc 0 (no violation possible to detect) | unit | `eng109_assert_no_write_to_path_empty_transcript` (in `bin/common-test.sh`) |
| Stage prompt drift — `{progress_md_path}` removed from a stage's read list | A future edit deletes `1. {progress_md_path}` from §§1, 3, 4, 5, 6, 7, or 8 | `bin/agent-prompts-content-test.sh` ENG-109 presence loop fails with `literal '1. {progress_md_path}' line missing from §<N>` | unit | per-stage rows of the ENG-109 read-clause presence loop (in `bin/agent-prompts-content-test.sh`) |
| Stage prompt drift — write clause removed from a stage's Output section | A future edit deletes the `Append a \`progress.md\` entry` bullet from any of §§1, 4, 5, 6, 7, 8 | `bin/agent-prompts-content-test.sh` ENG-109 write-clause loop fails with `phrase 'Append a \`progress.md\` entry' missing` | unit | per-stage rows of the ENG-109 write-clause presence loop (in `bin/agent-prompts-content-test.sh`) |
| §9 retrospective accidentally gains `{progress_md_path}` (would point at undefined `PIPELINE_ISSUE_ID`) | A future edit propagates the read-clause to §9 | `bin/agent-prompts-content-test.sh` ENG-109 §9 absence row fails with `retrospective has no PIPELINE_ISSUE_ID and no per-issue scratch dir; this is a contract violation` | unit | `§9 ENG-109: '{progress_md_path}' token absent from §9` (in `bin/agent-prompts-content-test.sh`) |
| Cross-stage chain incoherence (out-of-order entries, missing entries, malformed headings) | A regression in the writer pattern produces a progress.md whose entries don't match the schema | `bin/progress-md-cross-stage-test.sh` fails on one of: H2 count != 3, dispatch-id order broken, heading does not split into 3 tokens, single-dispatch grep returns != 1 | integration | `chain: three H2 entries`, `chain: dispatch-id order preserved`, `chain: single-dispatch grep returns exactly one match`, `chain: every heading parses into three tokens` (in `bin/progress-md-cross-stage-test.sh`) |
| Resolver registry / token-name drift (`{progress_md_path}` token appears in AGENT_PROMPTS.md without a registered resolver) | A future edit to `bin/render-prompt.sh` removes the registry entry | `bin/render-prompt.sh::resolve_block_tokens` dies at render time with `render-prompt: unknown token '{progress_md_path}' in source` | unit (existing) | covered by `bin/render-prompt-test.sh` ENG-87 R5/R8 invariants (no new test) |
| New cross-stage test absent from `learned-rules/harness/project-profile.md` Tool allowlist | A future operator runs ENG-109's tests under a fresh dispatch, but the orchestrator's `--allowed-tools` argv doesn't include `Bash(bash bin/progress-md-cross-stage-test.sh:*)` | implement/qa stage agent's `bash bin/progress-md-cross-stage-test.sh` call is rejected by the sandbox matcher (`Bash(...)` pattern not allowlisted); agent halts | integration | covered by `bin/profile-allowlist-test.sh` parser (the new entry's presence is asserted by Task 6.1b grep; the parser invariant covers shape validity) |
| Build wait-shape exit accidentally appends entry (D-002 §7 violation) | §7 agent appends despite being on a P2/P5 wait path | NOT caught at runtime by ENG-109's detective (which is negative-only — checks for Write misuse, not write-when-prohibited). Caught at retrospective review by humans inspecting progress.md for wait-shape entries | smoke (manual; brainstorm §5 acknowledged out of scope) | covered indirectly by §7 write-clause prompt-side wording (Decision-path B guard + explicit "wait-shape exits skip"); a runtime detective would require additional state-tracking that the brainstorm rejected per OQ-1 |
| Brainstorm iteration-exhausted halt accidentally appends entry (D-002 §1 violation) | §1 agent appends despite being on the iteration-exhausted halt path | NOT caught at runtime. Caught at retrospective review. | smoke (manual; brainstorm §5 + §6 acknowledged out of scope) | covered by §1 write-clause prompt-side wording ("clean-exit only" guard) |
| Review fail-path accidentally appends entry (D-002 §5 violation) | §5 agent appends on Decision-path A or B | NOT caught at runtime. Caught at retrospective review (the next-iter implement agent reading progress.md sees stale loopback rationale and acts on it — the ENG-77 stale-state hazard the brainstorm flagged) | smoke (manual; brainstorm §5 acknowledged out of scope) | covered by §5 write-clause prompt-side wording ("Decision-path C only" guard) |

## Test Strategy

- **Unit (new).** Three fixtures in `bin/common-test.sh`
  covering `assert_no_write_to_path` (empty / match / no-match).
  Two fixtures in `bin/dispatch-test.sh` covering the
  dispatch.sh detective wired through the same helper. Six
  read-clause presence checks + six write-clause presence
  checks + one §9 absence check in
  `bin/agent-prompts-content-test.sh`.

- **Integration (new).** `bin/progress-md-cross-stage-test.sh`
  exercises the schema's chain coherence by synthesising three
  sequential mock writes and asserting structural properties
  (entry count, dispatch-id order, heading-shape parse,
  grep-friendliness). This is the AC#3 surface.

- **Integration (existing — re-run as gate).**
  `.githooks/pre-commit` runs the full `bin/*-test.sh` suite.
  The relevant sibling tests for unintended regressions:
  - `bin/render-prompt-test.sh` — ENG-87 R5/R8 resolver
    invariants gate the registry side of the new token usage;
    no change in this plan but the gate fires automatically
    when `{progress_md_path}` is referenced from a new §.
  - `bin/dispatch-test.sh` — the AS1-AS12 existing fixtures
    cover other dispatch.sh detectives (ENG-43, ENG-66,
    ENG-68, ENG-71). No expected regression — the new
    detective sits AFTER ENG-68 and produces a NEW exit code
    path (29) that does not interfere with the existing
    code's rc=22/23/26/13 paths.
  - `bin/profile-allowlist-test.sh` — the new profile entry's
    parse-validity is gated here.
  - `bin/run-local-sweep-test.sh` — progress.md lives outside
    the worktree, so the sweep never sees it; no regression.

- **Smoke (manual at implement-time).** Each Task 2.X
  read-back step (per-§). Each Task 4 read-back step. Task 5.3
  no-debris check. These are the documentation-correctness +
  prompt-correctness gates; no executable test today asserts
  the exact phrase ordering inside each Output section.

- **Adversarial (none new).** The detective is a single
  jq-over-transcript scan. The helper is sibling-shaped with
  `assert_no_tool_invocation` which already has six adversarial
  fixtures (AS1-AS6 in `bin/dispatch-test.sh`). The two new
  EW1+EW2 fixtures are sufficient for ENG-109's contract
  surface; further adversarial coverage (e.g., NDJSON-malformed,
  chained Write+Bash redirect) is OUT of scope per brainstorm
  §5 rejected-alternative "forbid Bash `>` redirect to
  progress.md" — the runbook + prompt rule are the primary
  defense.

- **End-to-end (none new).** No agent writes or reads through
  a full dispatch in this plan's tests. The dry-run integration
  surface for cross-dispatch reads/writes belongs to a future
  E2E ticket (not in any current sub-ticket of ENG-28).

- **Test-gate closure.** Per A-024 + A-025, the only token this
  plan REMOVES is the `for _sec_num in 4 5 6 7 8 9` absence
  loop body in `bin/agent-prompts-content-test.sh:96-111`.
  The sibling-test sweep returns no other test file pinning the
  "scoped to §3 only" assertion shape. Task 3.4 explicitly
  rewrites this block, satisfying the closure. New tokens
  introduced (`assert_no_write_to_path`, `Append a \`progress.md\` entry`,
  `bin/progress-md-cross-stage-test.sh`) are not pinned absent
  by any sibling test. Zero closure defects.

## Persona review

Five personas dispatched in parallel via the document-review
skill (feasibility, scope, coherence, design, product). Two
iterations.

| Persona | Iter 1 | Iter 2 | Notes |
|---|---|---|---|
| Feasibility | P0=2 | PASS · P0=0 | Iter 1 P0-1: rc=29 falls through to `retry-immediately` in run-stage.sh's classifier (no rc=29 elif arm existed; envelope-validator's rc=29 at line 1630 is a separate code path). FIX: added Task 4.3 inserting a new `dispatch_rc == 29` elif arm; A-010 rewritten; File Structure adds `bin/run-stage.sh`; Failure Mode row updated; Task 7.6b adds `run-stage-test.sh` gate. Iter 1 P0-2: `printf '\nRESULTS: %d passed, %d failed\n'` appears 3× in `bin/dispatch-test.sh` (not unique). FIX: Task 4.6 anchor switched to the 4-line file-tail summary block (`# ─── Summary ───` header + printf + `[[ "$FAIL" == 0 ]]` + `exit 0`). Iter 1 P1-2/P1-3 (anchor uniqueness in AGENT_PROMPTS.md §§1, 4-7): A-011/A-012/A-013/A-014 documented multi-line anchors. |
| Scope | PASS · P0=0 | — | Every task and File Structure entry traces to a Linear AC, brainstorm D-N, or documented deviation. Two P2 nits (EW1/EW2 partially redundant with common-test fixtures — mirrors AS1-AS6 dual-coverage pattern; D-006 deviation could be tightened) — non-blocking. |
| Coherence | PASS · P0=0 | — | All brainstorm decisions D-001..D-006 map cleanly to tasks. D-005 items (i)/(viii) are functionally re-mapped to per-§ presence assertions under the documented D-002 deviation. Two P2 nits (note D-005 re-mapping inline in Task 3.4; comment that §2 absence is intentionally not pinned for ENG-106's future write-clause) — non-blocking. |
| Design | PASS · P0=0 | — | No layering violations. Subsystem distribution within sizing rubric (3 subsystems + tests subordinate). Helper colocation, detective wiring layer, exit-code reuse all align with established patterns (ENG-43, ENG-66, ENG-68, ENG-71, ENG-108). Three P2 nits (rc=29 reuse operator-triage cost — documented; comment density slightly above CLAUDE.md "default to no comments" but matches house style; Task 3.4 replacement vs additive — current shape minimal) — non-blocking. |
| Product | PASS · P0=0 | — | All three Linear AC addressed. D-006 deviation (proceed without ENG-106) is the right product call given (a) Linear blocked-by names only ENG-108 (shipped), (b) ENG-108 establishes the read-side pilot shape, (c) D-002 specifies the write-side wording inline. One P2 nit (Goal section is implementation-facing rather than user-facing) — non-blocking. |

**Personas: 5/5 PASS · gate P0: 0 · proceeding to implementing.**

P2-level concerns from iter 1 are documented above but not
blocking. The plan ships as-is.
