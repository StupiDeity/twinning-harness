---
linear: ENG-108
date: 2026-05-16
topic: bin/render-prompt.sh `_resolve_progress_md_path` resolver + main()-bound `_RENDER_PROGRESS_MD_PATH` global + stage-conditional info-log on missing file + AGENT_PROMPTS.md §3 read-first list prepend (`{progress_md_path}` as new position 1) + bin/render-prompt-rc0-test.sh case-A/B fixtures + bin/agent-prompts-content-test.sh position-1 invariant — first reader pilot for ENG-28
---

# Plan — ENG-108 progress.md implement stage reads progress entries

Implementation plan for the design at
`docs/brainstorms/2026-05-16-eng-108-progress-md-implement-stage-reads-progress-entries-design.md`.

## Anti-anchoring check

- **Problem (operator's words).** ENG-28 (parent umbrella) wants a
  continuous, per-issue `progress.md` notebook so a future dispatch's
  agent has the prior-stage agent's context without re-reading every
  transcript. ENG-107 shipped the substrate; ENG-106 ships the first
  writer (plan stage); **ENG-108 ships the first reader: the
  implement-stage agent reads `progress.md` BEFORE the other
  onboarding artifacts (CLAUDE.md, architecture, brainstorm/plan).**
- **Brainstorm addresses it?** Yes. D-001 picks path-token + agent
  `Read` tool (vs inline content) so the orchestrator does not have
  to bound an unbounded file in the prompt and the read remains
  visible in the agent's transcript. D-002 places the new
  `{progress_md_path}` token at position 1 of §3's read-first list
  (above CLAUDE.md) — the literal "first" the AC asks for. D-003
  fires an orchestrator-side info-log when the file is absent
  (satisfies AC-2's "logs a 'progress-md missing' info note") and
  pairs it with a prompt-side "skip if not present" instruction so
  the agent does not halt. D-004 extends the existing
  `bin/render-prompt-rc0-test.sh` ENG-105 case-A/B precedent with
  one new pair. D-005 walls off ui/qa/review prompts and writer
  responsibilities (Linear OUT list).
- **Proportional?** Yes. Brainstorm §3 sizes the change at ~10 LOC of
  production code (one resolver function, one main()-bound global,
  one stage-conditional log, one AGENT_PROMPTS.md prepend) plus
  ~30 LOC of test fixture extension and a one-line content-test
  invariant. Zero changes to `bin/run-stage.sh`, `bin/dispatch.sh`,
  `bin/run-local-helpers.sh`, `bin/scope-check.sh`,
  `bin/run-local.sh`, `bin/linear.sh`, `bin/verdict-handler.sh`,
  `bin/classify-failure.sh`, `bin/poll.sh`, `bin/common.sh`, or
  `docs/runbooks/progress-md.md`. The Linear ticket's IN list is
  precisely the three artifacts named (prompt preamble + optional
  render-prompt token + with/without test fixture); the OUT list
  (ui/qa/review readers, implement-stage writer) is honored by D-005.
- **No escalation. PROCEED.**

## Branch-base freshness

`git fetch origin main` succeeded at plan time (orchestrator-side;
the plan agent's tool surface inherits a pre-fetched origin/main).
`git log --oneline HEAD..origin/main` returned EMPTY.

- branch-base freshness: `HEAD..origin/main` empty at plan time
  (`origin/main = fb3d1b76a6d3b67ac0a28505cfeaff26bf9f256b`).

No Task 0 rebase is required. All `path:line` excerpts in the
Assumption Inventory are stable against current HEAD; subsequent
edits still use content anchors per "Edit-boundary keys" guidance to
defend against any sibling commit landing during implement-time
before the implement agent's own pre-edit re-grep (Task 1).

## Goal

After implement runs:

1. `bash bin/render-prompt-rc0-test.sh` exits 0 with two new
   ENG-108 case rows passing: (A) when no
   `$PROJECT_STATE_DIR/<slug>/<issue>/progress.md` exists, the
   rendered implementing prompt's stdout contains the resolved
   absolute path string (the `{progress_md_path}` token resolves to
   a real path) AND stderr contains the literal substring
   `progress-md missing`; (B) when `progress.md` IS pre-seeded with
   a sentinel entry, the rendered prompt's stdout contains the
   resolved absolute path AND stderr does NOT contain
   `progress-md missing`.
2. `bash bin/agent-prompts-content-test.sh` exits 0 with a new
   ENG-108 row asserting that AGENT_PROMPTS.md §3's "Read these
   files first" list has `{progress_md_path}` as position 1 (above
   the line referencing CLAUDE.md).
3. `bash bin/render-prompt.sh implementing ENG-N` (called for any
   issue) renders without error, and the output contains the
   resolved absolute progress.md path (verifiable by greppable
   substring in the rendered prompt).
4. `bash .githooks/pre-commit` exits 0 (the entire `bin/*-test.sh`
   suite is green, including the new ENG-108 fixtures and the
   continued green of every previously-passing test).

Verifiable by:

```
bash bin/render-prompt-rc0-test.sh \
  && bash bin/agent-prompts-content-test.sh \
  && bash .githooks/pre-commit
```

exiting 0.

## Assumption Inventory

Every modified-file fact below is `path:line`-cited against the
current worktree HEAD. Quoted excerpts are exact substrings to
preserve in `Edit::old_string` calls. Bare line numbers appear ONLY
as informational hints alongside a content anchor; the literal
content-anchor strings are what the Edit calls match.

### Files modified in this plan: 4 (0 new, 4 edited)

- `bin/render-prompt.sh` (four edit sites — Task 2 inserts a
  `progress_md_path` registry entry; Task 3 inserts the
  `_resolve_progress_md_path` resolver function next to the
  `_resolve_stage_summary_path` sibling; Task 4 inserts the
  `_RENDER_PROGRESS_MD_PATH=...` binding in `main()` next to the
  other `_RENDER_*` bindings; Task 5 inserts the stage-conditional
  info-log next to the same `main()` block)
- `AGENT_PROMPTS.md` (one §3 edit site — Task 6 inserts a new
  position-1 read-first item and shifts items 1-8 down to 2-9)
- `bin/render-prompt-rc0-test.sh` (one new ENG-108 fixture pair
  inserted after the ENG-105 case A/B pair)
- `bin/agent-prompts-content-test.sh` (one new §3 invariant
  inserted alongside the existing §3 assertions)

### Modified-file facts — current state and verification points

- **A-001 — `bin/common.sh::progress_md_path` exists at lines 78-82
  and returns `$PROJECT_STATE_DIR/<ident>/progress.md`.** Verified
  by direct read:

  ```bash
  progress_md_path() {
    local issue="$1"
    [[ -n "$issue" ]] || die "progress_md_path: missing issue id"
    printf '%s/progress.md' "$(issue_dir "$issue")"
  }
  ```

  No change to this helper in this plan; it is the dependency the
  new resolver consumes.

- **A-002 — `bin/common.sh:400` exports `progress_md_path` from the
  public `export -f` line.** Verified by direct read:

  ```bash
  export -f issue_dir compute_pipeline_content_hash failure_outcome_for_exit parse_pipeline_marker is_orchestrator_paused set_orchestrator_paused allocate_dispatch_id current_dispatch_id assert_no_tool_invocation progress_md_path
  ```

  Subshell `bash -c` calls (e.g., from `render-prompt.sh::main`'s
  process AFTER `source common.sh`) can therefore call
  `progress_md_path` directly without re-sourcing. No change.

- **A-003 — `bin/render-prompt.sh::PROMPT_RESOLVERS` is the resolver
  registry at lines 41-55.** Verified by direct read:

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

  Content anchor for Task 2's Edit (literal closing `'` line of the
  registry, unique within the file):

  - END anchor (preserved as bookend): the literal closing line of
    the heredoc-ish single-quoted variable assignment —
    `review_findings=_resolve_review_findings` followed by a column-0
    `'` line.

  Task 2 inserts the new entry `progress_md_path=_resolve_progress_md_path`
  on the line BEFORE the closing `'`, after the existing
  `review_findings=_resolve_review_findings` entry. Both anchor
  strings appear EXACTLY ONCE in the file.

- **A-004 — `bin/render-prompt.sh::_resolve_stage_summary_path`
  exists at line 226 as a single-line `printf` of a `_RENDER_*`
  global.** Verified by direct read:

  ```bash
  _resolve_stage_summary_path() { printf '%s' "$_RENDER_STAGE_SUMMARY_PATH"; }
  ```

  Content anchor for Task 3's Edit: the literal
  `_resolve_stage_summary_path() { printf '%s' "$_RENDER_STAGE_SUMMARY_PATH"; }`
  line followed on the next line by
  `_resolve_learned_rules_dir() { printf '%s' "$_RENDER_LEARNED_RULES_DIR"; }`.
  Both lines are unique within the file. Task 3 inserts the new
  `_resolve_progress_md_path() { printf '%s' "$_RENDER_PROGRESS_MD_PATH"; }`
  function on a new line BETWEEN them.

- **A-005 — `bin/render-prompt.sh::_resolve_review_findings` at
  lines 245-252 is the precedent for content-inlining resolvers.**
  Verified by direct read:

  ```bash
  _resolve_review_findings() {
    local p="${_RENDER_REVIEW_FINDINGS_PATH-}"
    if [[ -n "$p" && -s "$p" ]]; then
      cat "$p"
    else
      printf '(no prior review for this issue — this dispatch is not a review-loopback)'
    fi
  }
  ```

  This is NOT the shape ENG-108 picks — D-001 explicitly picks the
  path-token shape (mirror of `_resolve_stage_summary_path`), not
  the content-inlining shape. Cited here only to justify that the
  divergence is intentional.

- **A-006 — `bin/render-prompt.sh::main` binds `_RENDER_*` globals
  at lines 404-421 BEFORE calling `resolve_block_tokens`.** Verified
  by direct read:

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
  _RENDER_DISPATCH_ID="${PIPELINE_DISPATCH_ID-}"
  ```

  Content anchor for Task 4's Edit: the literal full line
  `_RENDER_DISPATCH_ID="${PIPELINE_DISPATCH_ID-}"` (last `_RENDER_*`
  binding before `resolve_block_tokens "$block" | append_project_profile "$stage"`).
  This line is unique within the file. Task 4 inserts the new
  binding `_RENDER_PROGRESS_MD_PATH="$(progress_md_path "$issue_id")"`
  on a new line BETWEEN the `_RENDER_REVIEW_FINDINGS_PATH=…` line
  and the `_RENDER_DISPATCH_ID=…` line. (The new binding sits next
  to the path-shaped sibling `_RENDER_REVIEW_FINDINGS_PATH=…` so
  reviewers tracing the resolver pattern land on the right
  precedent.)

- **A-007 — `bin/render-prompt.sh::resolve_block_tokens` iterates
  ONLY over tokens that appear in the source (lines 267-312).**
  Verified by direct read:

  ```bash
  tokens="$(grep -oE '\{[a-z_]+\}' <<<"$rendered" | sort -u || true)"
  while IFS= read -r t; do
    [[ -z "$t" ]] && continue
    name="${t#\{}"; name="${name%\}}"
    ...
    resolver="$(_lookup_resolver "$name")"
    [[ -n "$resolver" ]] \
      || die "render-prompt: unknown token '$t' in source — register a resolver in PROMPT_RESOLVERS"
    value="$("$resolver" 2>/dev/null || printf '')"
    ...
  done <<<"$tokens"
  ```

  Implication: registering `progress_md_path=_resolve_progress_md_path`
  has zero observable effect on stage prompts that do NOT contain
  the `{progress_md_path}` token (every stage other than
  implementing today). The token-presence-driven dispatch is the
  reason D-005's "stage-agnostic resolver registration / stage-
  conditional info-log" asymmetry is safe.

- **A-008 — `AGENT_PROMPTS.md §3 Implementation Agent`'s "Read these
  files first" list lives at lines 614-622, comprising 8 numbered
  items.** Verified by direct read:

  ```
  Read these files first (in order, where present):
  1. CLAUDE.md — coding standards and project structure
  2. Architecture / system docs as listed in the Project profile addendum's File layout (skip if not present)
  3. docs/knowledge/gotchas.md — filter by tags relevant to the modules you're modifying (skip if not present)
  4. docs/knowledge/decisions.md — follow all accepted ADRs (skip if not present)
  5. docs/knowledge/conventions.md — filter by tags relevant to the modules you're modifying (skip if not present)
  6. {learned_rules_dir}/implementation.md — learned rules from past retrospectives (follow ALL)
  7. docs/brainstorms/{brainstorm_file}
  8. docs/plans/{plan_file} — focus on "Backend Tasks" and the `api-contract` block
  ```

  Content anchors for Task 6's Edit:

  - START anchor (preserved as bookend): the literal preamble line
    `Read these files first (in order, where present):`
  - Body anchor (renumbered): the eight numbered lines verbatim,
    with their numbers shifted from `1.` … `8.` to `2.` … `9.` and a
    new `1. {progress_md_path} — …` line inserted between the
    preamble and the (renumbered) `2. CLAUDE.md` line.

  Both the preamble line and each numbered line appear EXACTLY ONCE
  in the file (verified by Grep at plan time — the read-first list
  shape is unique to §3; §1 / §2 / §5 / §6 / §7 / §8 / §9's
  read-first lists, where present, have different preambles or
  different first items).

- **A-009 — `AGENT_PROMPTS.md §3` is the only section that
  references `{progress_md_path}` after this plan lands.** Verified
  by `Grep -n 'progress_md_path' AGENT_PROMPTS.md` returning zero
  matches today (token does not exist yet). The token will appear
  EXACTLY ONCE post-plan: in §3's new position-1 line. No other §
  references it; Task 6 does not edit §§4-9.

- **A-010 — `bin/render-prompt-rc0-test.sh` exercises full `main()`
  execution via stub `linear.sh` + `branch-name.sh` and uses an
  ENG-105 case A/B pair at lines 117-157 for present/absent fixture
  testing of `{review_findings}`.** Verified by direct read.
  Sandbox setup at lines 30-89; iteration over every dispatch-time
  stage at lines 113-115; ENG-105 fixture pair at lines 117-157.

  Content anchor for Task 7's Edit: the literal final summary
  printf line at line 159:

  ```
  printf '\n━━━ Summary ━━━\nPASS: %d / FAIL: %d\n' "$PASS" "$FAIL"
  ```

  This line is unique within the file. Task 7 inserts the new
  ENG-108 case-A/B fixture block IMMEDIATELY BEFORE this line
  (matches the ENG-105 pair's relative position). The new block
  reuses the same `HARNESS_STATE_DIR="$sandbox/state"` pattern from
  the ENG-105 fixtures (lines 134, 150) so no new sandbox
  scaffolding is needed.

- **A-011 — `bin/render-prompt-rc0-test.sh`'s ENG-105 case A/B pair
  uses issue identifiers `ENG-87R6X-A` and `ENG-87R6X-B` to keep
  per-case state directories independent.** Verified by direct read
  (lines 130, 143). The new ENG-108 case-A/B pair will use
  `ENG-87R6X-C` and `ENG-87R6X-D` to preserve the same
  per-case-isolation pattern. (Identifiers are sandbox-only; the
  sandbox `linear.sh` stub at lines 72-83 returns the same JSON for
  any issue.)

- **A-012 — `bin/render-prompt-rc0-test.sh`'s `linear.sh` stub does
  NOT depend on the issue id (the case statement returns the same
  JSON for any `get-issue` call) and the `branch-name.sh` stub
  prints `feat/<lower-issue-id>-test-slug-rc0`.** Verified by direct
  read (lines 72-89). Implication: passing different `ENG-…`
  identifiers to the new fixture pair drives different
  per-issue state directories under `$sandbox/state/test-slug-rc0/`
  but the stage-prompt rendering is identical. The case-A/B
  divergence is entirely driven by the existence (or not) of
  `progress.md` in each case's per-issue dir.

- **A-013 — `bin/agent-prompts-content-test.sh` is the canonical
  home for AGENT_PROMPTS.md content invariants.** Verified by
  direct read (lines 1-30). Helper functions: `section_body` (line
  20) and `rendered_stage_body` (line 36); existing §3 assertions
  at lines 73-83 (e.g., `§3 contains 'Do NOT create a PR'`,
  `§3 lacks 'gh pr create'`).

  Content anchor for Task 8's Edit: the literal closing line of the
  existing §3 lacks-gh-pr-create assertion block. Specifically the
  full block:

  ```
  if printf '%s\n' "$s3" | grep -qE 'gh pr create'; then
    nope "§3 lacks 'gh pr create'" "string 'gh pr create' present"
  else
    ok "§3 lacks 'gh pr create'"
  fi
  ```

  This `if ... fi` block is the last §3-scoped assertion before §4
  assertions begin. Task 8 inserts the new ENG-108 §3 invariant
  block IMMEDIATELY AFTER the closing `fi` of this block (and
  before the first §4 assertion at the existing line that opens
  with `if printf '%s\n' "$s4" | grep -qE 'gh pr create'`). Both
  anchor strings appear EXACTLY ONCE in the file.

- **A-014 — `docs/runbooks/progress-md.md` exists and documents the
  schema/lifecycle.** Verified by direct read (134 lines). The
  Section 6 dispatch-id-glue note (lines 108-115) names the
  `PIPELINE_DISPATCH_ID`-based reader-side filter the implement
  agent applies inline. The new prompt body for the position-1
  read-first item references the runbook URL so a reader curious
  about the schema lands directly on it. No change to the runbook
  in this plan.

- **A-015 — `PIPELINE_DISPATCH_ID` is allocated by
  `bin/common.sh::allocate_dispatch_id` at lines 114-156 with
  format `ENG-N-d<NNNN>`.** Verified by direct read. The runbook's
  "filter entries by dispatch-id" pattern (Section 6) relies on this
  allocator's stability; ENG-108 does not modify the allocator.

- **A-016 — `bin/run-stage.sh::_clear_current_stage_slots` at line
  883 enumerates the per-dispatch-cleared files as exactly two:
  `stage-summary-${stage}.md` and `wait-${stage}.json`.** Verified
  by direct read (lines 883-891):

  ```bash
  _clear_current_stage_slots() {
    local PIPELINE_WRITER=orchestrator
    export PIPELINE_WRITER
    local ident="$1" stage="$2"
    local d; d="$(issue_dir "$ident")"
    rm -f "$d/stage-summary-${stage}.md" 2>/dev/null || true
    rm -f "$d/wait-${stage}.json"        2>/dev/null || true
    return 0
  }
  ```

  Per D-005: this function is NOT modified by this plan. The
  agent-side reader is safe because `progress.md` is never wiped
  out from under it on dispatch start.

- **A-017 — `bin/render-prompt.sh::main` at line 423 calls
  `resolve_block_tokens "$block" | append_project_profile "$stage"`
  AFTER all `_RENDER_*` bindings.** Verified by direct read. The
  new `_RENDER_PROGRESS_MD_PATH` binding from Task 4 must be set
  BEFORE this line, which is satisfied by the placement next to
  the other `_RENDER_*` bindings.

- **A-018 — `bin/render-prompt.sh::main` reads the `stage`
  parameter as `${1:-}` at line 315, so `$stage` is in scope at the
  `_RENDER_*` binding point.** Verified by direct read. Task 5's
  stage-conditional log (`if [[ "$stage" == "implementing" ... ]]`)
  can reference `$stage` directly without re-passing it.

- **A-019 — `log` is the canonical stderr-emitting helper from
  `bin/common.sh`.** Verified by direct grep — every existing
  `render-prompt.sh` log line (e.g., line 204:
  `log "render-prompt: WARNING — project-profile schema_version != 1, continuing"`)
  uses it. `log` is not exported via `export -f` (it's defined and
  available within the sourcing process); `bin/render-prompt.sh`
  sources `bin/common.sh` at line 11 so `log` is in scope inside
  `main()`.

- **A-020 — Test-gate closure sweep: tokens REMOVED from any
  tracked file by this plan = zero.** This plan ONLY INSERTS
  content. No tokens are renamed, dropped, enum-variant-removed,
  default-changed, or otherwise deleted from production code.
  Test-gate closure sweep has no removals to verify.

  Defensive check on additions (confirming the new tokens aren't
  pinned-ABSENT by any sibling test):

  - `progress_md_path` (new resolver registry entry) — `Grep` on
    `bin/*-test.sh` for `progress_md_path` returns matches in
    `bin/common-test.sh` (the ENG-107 fixtures landed by ENG-107)
    and zero matches elsewhere. None of those matches are
    pinned-ABSENT assertions; they all positively assert the
    helper's behavior. Adding the resolver registry entry has zero
    test-suite impact.
  - `_resolve_progress_md_path` (new resolver function name) —
    `Grep` on `bin/*-test.sh` returns zero matches pre-edit. Safe.
  - `_RENDER_PROGRESS_MD_PATH` (new global) — `Grep` on
    `bin/*-test.sh` returns zero matches pre-edit. Safe.
  - `progress-md missing` (new info-log substring) — `Grep` on
    `bin/*-test.sh` returns zero matches pre-edit; the new fixture
    in Task 7 introduces the first match. Safe.
  - `{progress_md_path}` (new prompt-body token in §3) — `Grep` on
    `bin/*-test.sh` and `AGENT_PROMPTS.md` returns zero matches
    pre-edit. Safe.

  Tokens whose ABSENCE is asserted that this plan must not violate:

  - `bin/agent-prompts-content-test.sh`'s ENG-97 forbidden_token
    loop scans `AGENT_PROMPTS.md` for Tauri-shaped tokens. This
    plan adds the literal text `progress.md` and `{progress_md_path}`
    to §3's body; neither is a Tauri-shaped token. Safe.
  - `bin/agent-prompts-content-test.sh`'s §2 column-0 fence count
    invariant (line 264) and the §2 indented-fence count invariant
    (line 188-194). This plan does not touch §2. Safe.
  - `bin/agent-prompts-content-test.sh`'s `Do NOT create a PR` /
    `gh pr create` §3 invariants (lines 73-83). This plan only
    PREPENDS a new position-1 read-first item to §3 and renumbers
    the existing items 1-8 to 2-9; it does NOT touch the
    "Do NOT create a PR" prose later in §3. Safe.
  - `bin/render-prompt-test.sh`'s `append_project_profile`
    assertions. This plan does not touch `append_project_profile`.
    Safe.
  - `bin/vocabulary-cleanliness-test.sh` enforces the closed
    pipeline-marker vocabulary. This plan adds prose only — no new
    `<!-- pipeline: ... -->` or `<!-- meta: ... -->` markers. Safe.

  **Conclusion:** zero test-gate closure defects. No additional
  sibling test file needs editing beyond the two named in File
  Structure (`render-prompt-rc0-test.sh` for the case-A/B fixtures
  and `agent-prompts-content-test.sh` for the position-1
  invariant).

- **A-021 — Plan doc basename satisfies
  `partition_dirty_paths::D-004`.** The plan filename
  `2026-05-16-eng-108-progress-md-implement-stage-reads-progress-entries.md`
  contains the `eng-108` token (lowercase) in the basename at the
  correct position for in-scope bucketing per
  `bin/run-local-helpers.sh::D-004`. ✓

- **A-022 — `learned-rules/harness/plan.md` does not exist.**
  Verified by `Glob` on `learned-rules/**/*.md`: returns
  `learned-rules/harness/build.md` and
  `learned-rules/harness/project-profile.md` only (the
  `learned-rules/twinning/` files are for a different slug). Per
  the plan prompt's preamble (skip-if-not-present), no plan-stage
  learned rules to apply.

- **A-023 — Branch prefix matches Improvement label.** Branch name
  (from git status):
  `feat/eng-108-progress-md-implement-stage-reads-progress-entries`.
  CLAUDE.md confirms `feat/` = Feature/Improvement; the Linear
  issue is filed as Improvement (per parent ENG-28 + brainstorm
  framing). ✓

- **A-024 — `bin/render-prompt-rc0-test.sh`'s sandbox sets
  `HARNESS_STATE_DIR="$sandbox/state"` ONLY for the ENG-105 case
  A/B fixtures (lines 134, 150) — the per-stage iteration loop
  above (lines 113-115) does NOT set `HARNESS_STATE_DIR`.**
  Verified by direct read. Implication: `progress_md_path "$issue"`
  called inside the per-stage loop's `bash bin/render-prompt.sh
  implementing ENG-87R6X` invocation would resolve to
  `${HARNESS_STATE_DIR:-default}/test-slug-rc0/ENG-87R6X/progress.md`,
  where `HARNESS_STATE_DIR` defaults via `common.sh:46` to
  `${XDG_STATE_HOME:-~/.local/state}/twinning-harness`. The path
  is well-defined, the file does not exist, and the new
  stage-conditional log will fire — which is the case-A behavior.
  No regression in the per-stage iteration loop's existing
  assertions: those assert `rc=0` only, not stderr content. New
  assertions land in the dedicated ENG-108 case-A/B fixture block
  (Task 7).

- **A-025 — The `{progress_md_path}` token does NOT need to be
  added to `AGENT_RUNTIME_TOKENS` (the agent-runtime allowlist at
  `bin/render-prompt.sh:75`).** Verified by reading lines 65-75:
  `AGENT_RUNTIME_TOKENS=' file pr_number stage_failure_summary_path '`
  is the allowlist for tokens that are intentionally left as
  literal `{name}` text for the agent to fill in at runtime.
  `progress_md_path` is resolved at render time (not by the agent)
  so it belongs in `PROMPT_RESOLVERS`, not in `AGENT_RUNTIME_TOKENS`.
  Adding it to both would be a contradiction; adding it only to
  `AGENT_RUNTIME_TOKENS` would skip resolution and pass the
  literal `{progress_md_path}` text to the agent.

## File Structure

Modified or new files only — no new test scripts, no new
dependencies, no new Linear labels, no new exit codes, no schema
files, no JSON registries.

- `bin/render-prompt.sh` — four edit sites:
  - Task 2: insert one line into the `PROMPT_RESOLVERS` registry
    (between the `review_findings=...` line and the closing `'`)
    per A-003. Section: `# ENG-87: prompt-token resolver registry`
    block at lines 33-55.
  - Task 3: insert one line defining `_resolve_progress_md_path()`
    between the existing `_resolve_stage_summary_path` (line 226)
    and `_resolve_learned_rules_dir` (line 227) per A-004. Section:
    `# ENG-87: per-token resolver functions` block at lines 213-234.
  - Task 4: insert one line binding `_RENDER_PROGRESS_MD_PATH=...`
    in `main()` between the existing `_RENDER_REVIEW_FINDINGS_PATH`
    binding (line 415) and `_RENDER_DISPATCH_ID` binding (line 421)
    per A-006. Composes on `progress_md_path "$issue_id"` (the
    helper from `bin/common.sh:78-82`, exported per A-002).
  - Task 5: insert a 3-line stage-conditional `log` block in
    `main()` IMMEDIATELY AFTER the new `_RENDER_PROGRESS_MD_PATH`
    binding from Task 4. The block:

    ```bash
    if [[ "$stage" == "implementing" && ! -e "$_RENDER_PROGRESS_MD_PATH" ]]; then
      log "render-prompt: progress-md missing for $issue_id at $_RENDER_PROGRESS_MD_PATH (informational; agent's Read will note absence)"
    fi
    ```

    Stage-scoped to `implementing` per D-005 (the only stage that
    today references `{progress_md_path}` in its prompt body).
- `AGENT_PROMPTS.md` — one §3 edit site (Task 6): prepend a new
  position-1 item to the "Read these files first" list in §3 and
  renumber the existing items `1.` … `8.` to `2.` … `9.`. The new
  position-1 item body (per brainstorm D-002):

  ```
  1. {progress_md_path} — per-issue progress notebook (cross-dispatch
     context from prior agents on this issue; see
     docs/runbooks/progress-md.md). Read this BEFORE the other
     files: the prior dispatch may have flagged that a plan task
     is blocked, that a chosen approach failed, or that a
     dead-end was already explored. Skip if not present —
     first-dispatch-on-issue is normal.
  ```

- `bin/render-prompt-rc0-test.sh` — one new ENG-108 case-A/B
  fixture pair (~30 lines) inserted IMMEDIATELY BEFORE the final
  summary printf at line 159 per A-010. Two cases:
  - Case A — no `progress.md` exists in the per-issue state dir.
    Asserts: (a) `bash bin/render-prompt.sh implementing
    ENG-87R6X-C` rc=0; (b) stdout contains the resolved absolute
    progress.md path string (the path the resolver computes for
    `$sandbox/state/test-slug-rc0/ENG-87R6X-C/progress.md`); (c)
    stderr contains the literal substring `progress-md missing`.
  - Case B — `progress.md` IS pre-seeded with a sentinel entry.
    Asserts: (a) rc=0; (b) stdout contains the resolved absolute
    progress.md path string; (c) stderr does NOT contain
    `progress-md missing`.
- `bin/agent-prompts-content-test.sh` — one new §3 invariant
  (Task 8) inserted IMMEDIATELY AFTER the existing §3 lacks-`gh pr
  create` assertion block per A-013. Asserts: §3's "Read these
  files first" list has `{progress_md_path}` at position 1 (the
  literal substring `1. {progress_md_path}` appears in §3's body).

Explicitly out of scope (per Linear issue's OUT list and brainstorm
§D-005):

- `bin/run-stage.sh` (`_clear_current_stage_slots`,
  `_validate_dispatch_envelope`) — unchanged. The cleared-set stays
  exactly `stage-summary-${stage}.md` + `wait-${stage}.json` (per
  A-016). No envelope-validator transcript-scan extension (e.g.,
  "did the implementer Read progress.md when it existed?") — that
  is OQ-1 in the brainstorm.
- `bin/run-local.sh`, `bin/run-local-helpers.sh` — unchanged.
  `progress.md` lives outside the worktree, so the sweep never
  sees it. No allowlist change in `partition_dirty_paths`.
- `bin/scope-check.sh` — unchanged. Same out-of-worktree rationale.
- `bin/dispatch.sh`, `bin/linear.sh`, `bin/poll.sh`,
  `bin/verdict-handler.sh`, `bin/classify-failure.sh`,
  `bin/metrics.sh`, `bin/pipeline.sh`, `bin/pipeline-events.json`,
  `bin/common.sh` — unchanged. No new exit code, no new verdict
  variant, no new label, no new metric.
- `AGENT_PROMPTS.md §§4-9` (UI Agent, Review Agent, QA Agent, Build
  Agent, Release Agent, Retrospective Agent) — unchanged. ui/qa/
  review readers are explicitly Linear OUT (separate sub-ticket).
- Implement-stage WRITER instructions — unchanged. §3 gets the
  prepended read-first item (reader pilot) but no instruction to
  append entries to `progress.md`. The writer is OUT per the Linear
  ticket.
- `docs/runbooks/progress-md.md` — unchanged. The runbook landed in
  ENG-107; ENG-108 references it from the new prompt body but does
  not edit it.
- `learned-rules/harness/plan.md` — unchanged (does not exist; per
  A-022 the prompt-time skip-if-not-present applies).
- `bin/run-retrospective-local.sh` — unchanged. Retrospective-side
  reading of `progress.md` is out of scope (deferred per
  brainstorm D-005 + ENG-107 D-003).

## API Contract

no new API surface

(The harness has no FE↔BE API surface of its own — it is a Bash
orchestration toolkit. The internal "API" added is the new shell
function `_resolve_progress_md_path` and its surrounding registry
entry / `_RENDER_*` global / info-log; their contract is
exhaustively documented by Tasks 2-5 + the existing brainstorm
§4 Data Flow trace and §5 Error Handling. No FE/BE handler types
or HTTP endpoints. The Linear-CLI / GitHub-CLI surface the
harness uses is unchanged.)

## Backend Tasks

Tasks 2, 3, 4, 5, 6, 8 can be authored in any order after Task 1
(a read-only re-grep) completes. Task 4 depends on Task 2 + Task 3
because the `_RENDER_PROGRESS_MD_PATH` binding presupposes the
registry entry and the resolver function exist (otherwise an
abandoned binding is harmless but the prompt-side `{progress_md_path}`
substitution in Task 6 would die at render time with the registry
guard at `bin/render-prompt.sh:289`). Task 5 depends on Task 4
because the info-log condition references the new
`_RENDER_PROGRESS_MD_PATH` global. Task 7 (test fixture extension)
depends on Tasks 2-6 because the fixture exercises full `main()`
through every layer this plan adds. Task 8 (content-test
invariant) depends on Task 6 because the invariant checks for the
position-1 line that Task 6 introduces. Task 9 (gate run) depends
on Tasks 2-8.

The implement agent SHOULD run Task 1 first, then any order of
{Task 2, Task 3} (they edit different file regions), then Task 4,
then Task 5, then Task 6, then Task 7, then Task 8, then Task 9.

(No Task 0 rebase: `HEAD..origin/main` is empty at plan time per
the Branch-base freshness section.)

### Task 1: Re-verify Assumption Inventory anchors at implement-time

- `depends_on: []`
- `touches: <read-only — no file edits>`

Steps:

- [ ] **1.1** Re-grep `bin/render-prompt.sh` for the Task 2 anchor
  (per A-003) — the literal full line
  `review_findings=_resolve_review_findings`
  followed on the next line by a column-0 `'`. Both lines MUST
  match exactly once. If either is absent OR appears more than
  once, halt with
  `bash bin/pipeline.sh event ENG-108 verdict halt --reason agent-blocked`
  and a Linear comment naming the drift.
- [ ] **1.2** Re-grep `bin/render-prompt.sh` for the Task 3 anchor
  (per A-004) — the literal full line
  `_resolve_stage_summary_path() { printf '%s' "$_RENDER_STAGE_SUMMARY_PATH"; }`
  followed on the next line by
  `_resolve_learned_rules_dir() { printf '%s' "$_RENDER_LEARNED_RULES_DIR"; }`.
  Both lines MUST match exactly once. Halt-on-drift behavior as 1.1.
- [ ] **1.3** Re-grep `bin/render-prompt.sh` for the Task 4 anchor
  (per A-006) — the literal full line
  `_RENDER_REVIEW_FINDINGS_PATH="$review_findings_path"`
  followed downstream by
  `_RENDER_DISPATCH_ID="${PIPELINE_DISPATCH_ID-}"`.
  Both lines MUST match exactly once. Halt-on-drift behavior.
- [ ] **1.4** Re-grep `AGENT_PROMPTS.md` for the Task 6 anchors
  (per A-008):
  - The literal full line
    `Read these files first (in order, where present):` MUST match
    exactly once (it is unique to §3).
  - The literal full line
    `1. CLAUDE.md — coding standards and project structure` MUST
    match exactly once. (This is the line that becomes `2. CLAUDE.md
    — …` post-Task 6. If a sibling commit has already changed §3's
    item-1 wording, halt with `verdict halt --reason agent-blocked`
    and re-derive the new anchor against current HEAD; do not
    silently retry.)
  - The literal full line
    `8. docs/plans/{plan_file} — focus on "Backend Tasks" and the \`api-contract\` block`
    MUST match exactly once. (This is the line that becomes `9.` …
    post-Task 6.)
- [ ] **1.5** Re-grep `bin/render-prompt-rc0-test.sh` for the Task 7
  anchor (per A-010) — the literal final summary printf line:
  ```
  printf '\n━━━ Summary ━━━\nPASS: %d / FAIL: %d\n' "$PASS" "$FAIL"
  ```
  MUST match exactly once. Halt-on-drift behavior.
- [ ] **1.6** Re-grep `bin/agent-prompts-content-test.sh` for the
  Task 8 anchor (per A-013) — the literal closing `fi` line of the
  existing §3 lacks-`gh pr create` block. The full block:
  ```
  if printf '%s\n' "$s3" | grep -qE 'gh pr create'; then
    nope "§3 lacks 'gh pr create'" "string 'gh pr create' present"
  else
    ok "§3 lacks 'gh pr create'"
  fi
  ```
  MUST match exactly once. Halt-on-drift behavior.

If all six sub-steps pass, proceed to Tasks 2 / 3 / 4 / 5 / 6 / 7 /
8.

### Task 2: Register progress_md_path in PROMPT_RESOLVERS

- `depends_on: [1]`
- `touches: bin/render-prompt.sh::PROMPT_RESOLVERS` — append one
  registry entry per A-003.

Steps:

- [ ] **2.1** Use a single `Edit` call with `old_string` =
  the existing last-entry line + the closing `'` and `new_string` =
  the same lines with the new `progress_md_path` entry inserted
  between them.

  Exact `old_string` (2 lines as they appear in the file —
  `review_findings=_resolve_review_findings` followed by the
  column-0 closing `'`):

  ```
  review_findings=_resolve_review_findings
  '
  ```

  Exact `new_string` (3 lines — preserves both bookends, inserts
  the new registry entry between them):

  ```
  review_findings=_resolve_review_findings
  progress_md_path=_resolve_progress_md_path
  '
  ```

  Notes:
  - Append at the END of the registry (after `review_findings`,
    before the closing `'`) — matches the existing convention
    where entries are grouped chronologically by feature-family
    (e.g., `dispatch_id` and `review_findings` come AFTER
    `learned_rules_dir` because they landed later).
  - The entry name `progress_md_path` mirrors the
    `stage_summary_path` convention (snake-case, underscore
    separator, `_path` suffix for path-shaped tokens).
  - The resolver function name `_resolve_progress_md_path` mirrors
    the `_resolve_stage_summary_path` convention (leading
    underscore, `_resolve_` prefix, snake-case body).

- [ ] **2.2** Verify by reading back `bin/render-prompt.sh` lines
  ~50-58. Confirm the registry now has 14 entries (was 13
  pre-edit), and the new entry sits between `review_findings=…`
  and the closing `'`.

- [ ] **2.3** Sanity-check `bash -n bin/render-prompt.sh` returns
  rc=0. The registry is a single-quoted heredoc-ish multiline
  string; a missing closing `'` would be caught here.

### Task 3: Add _resolve_progress_md_path resolver function

- `depends_on: [1]`
- `touches: bin/render-prompt.sh::_resolve_progress_md_path` — new
  function inserted between `_resolve_stage_summary_path` (line
  226) and `_resolve_learned_rules_dir` (line 227) per A-004.

Steps:

- [ ] **3.1** Use a single `Edit` call with `old_string` = the two
  consecutive resolver lines (pre-edit) and `new_string` = the same
  two lines with the new resolver inserted between them.

  Exact `old_string` (2 lines as they appear in the file):

  ```
  _resolve_stage_summary_path() { printf '%s' "$_RENDER_STAGE_SUMMARY_PATH"; }
  _resolve_learned_rules_dir() { printf '%s' "$_RENDER_LEARNED_RULES_DIR"; }
  ```

  Exact `new_string` (3 lines — preserves both bookends, inserts
  the new resolver between them):

  ```
  _resolve_stage_summary_path() { printf '%s' "$_RENDER_STAGE_SUMMARY_PATH"; }
  _resolve_progress_md_path() { printf '%s' "$_RENDER_PROGRESS_MD_PATH"; }
  _resolve_learned_rules_dir() { printf '%s' "$_RENDER_LEARNED_RULES_DIR"; }
  ```

  Notes:
  - The resolver body is BYTE-FOR-BYTE structurally identical to
    `_resolve_stage_summary_path` (same `printf '%s' "$_RENDER_…"`
    shape). No new abstraction, no fallback string, no `cat`
    of file contents. Path-token shape only — D-001's contract.
  - Placement directly after `_resolve_stage_summary_path` (rather
    than at the end of the resolver block) keeps the two
    path-shaped resolvers visually adjacent so a future reader
    tracing the pattern lands on both at once.

- [ ] **3.2** Verify by reading back `bin/render-prompt.sh` lines
  225-230. Confirm the new resolver sits between
  `_resolve_stage_summary_path` and `_resolve_learned_rules_dir`,
  and the function body is `printf '%s' "$_RENDER_PROGRESS_MD_PATH"`
  (NOT `printf '%s' "$_RENDER_STAGE_SUMMARY_PATH"` — common
  copy-paste bug).

- [ ] **3.3** Sanity-check `bash -n bin/render-prompt.sh` returns
  rc=0.

### Task 4: Bind _RENDER_PROGRESS_MD_PATH in main()

- `depends_on: [2, 3]`
- `touches: bin/render-prompt.sh::main` — new
  `_RENDER_PROGRESS_MD_PATH=...` binding inserted between the
  existing `_RENDER_REVIEW_FINDINGS_PATH` binding (line 415) and
  the `_RENDER_DISPATCH_ID` binding (line 421) per A-006.

Steps:

- [ ] **4.1** Use a single `Edit` call with `old_string` = the
  contiguous block from `_RENDER_REVIEW_FINDINGS_PATH` through
  `_RENDER_DISPATCH_ID` (inclusive of any intervening comment
  lines) and `new_string` = the same block with the new binding
  inserted between the two existing bindings.

  Exact `old_string` (7 lines as they appear at lines 415-421;
  preserved verbatim with all intervening comments):

  ```
    _RENDER_REVIEW_FINDINGS_PATH="$review_findings_path"
    # ENG-87 review-iter-7 M9: bind _RENDER_DISPATCH_ID like the sibling
    # _RENDER_* globals so resolver test isolation is uniform across the
    # registry. Falls through to empty when PIPELINE_DISPATCH_ID is unset
    # (release-stage main() never reaches this stanza; direct test paths
    # set _RENDER_DISPATCH_ID directly).
    _RENDER_DISPATCH_ID="${PIPELINE_DISPATCH_ID-}"
  ```

  Exact `new_string` (13 lines — preserves both bookends and the
  intervening ENG-87 comment block, inserts the new binding +
  one labelled comment between `_RENDER_REVIEW_FINDINGS_PATH` and
  the ENG-87 comment block):

  ```
    _RENDER_REVIEW_FINDINGS_PATH="$review_findings_path"
    # ENG-108: per-issue progress notebook path. Composes on
    # bin/common.sh::progress_md_path (exported per common.sh:400). The
    # resolver is path-shaped (D-001); the agent reads via Read at
    # dispatch time. Stage-conditional info-log below fires when the
    # file is absent on an implementing dispatch (D-003).
    _RENDER_PROGRESS_MD_PATH="$(progress_md_path "$issue_id")"
    # ENG-87 review-iter-7 M9: bind _RENDER_DISPATCH_ID like the sibling
    # _RENDER_* globals so resolver test isolation is uniform across the
    # registry. Falls through to empty when PIPELINE_DISPATCH_ID is unset
    # (release-stage main() never reaches this stanza; direct test paths
    # set _RENDER_DISPATCH_ID directly).
    _RENDER_DISPATCH_ID="${PIPELINE_DISPATCH_ID-}"
  ```

  Notes:
  - `progress_md_path "$issue_id"` is a function call to the
    helper sourced from `bin/common.sh:78-82` (per A-001) and
    exported per A-002. `bin/render-prompt.sh:11` sources
    `bin/common.sh` at file-top, so the helper is in scope inside
    `main()` without re-sourcing.
  - The binding placement (BEFORE the ENG-87 dispatch_id comment
    block, AFTER `_RENDER_REVIEW_FINDINGS_PATH`) preserves the
    "path-shaped resolvers stay grouped" convention. The existing
    ENG-87 comment block above `_RENDER_DISPATCH_ID` is a
    single semantic unit (explanation + binding); the new
    ENG-108 comment + binding mirror that semantic shape.
  - 4-space indentation matches the surrounding context (every
    `_RENDER_*` binding inside `main()` uses 4-space).
  - Token interpolation order does NOT depend on binding order —
    `resolve_block_tokens` reads each `_RENDER_*` global from
    process scope at call-time per A-007.

- [ ] **4.2** Verify by reading back `bin/render-prompt.sh` lines
  413-425. Confirm: (a) `_RENDER_REVIEW_FINDINGS_PATH` is preserved
  verbatim; (b) the new `_RENDER_PROGRESS_MD_PATH=…` line appears;
  (c) the ENG-87 comment block + `_RENDER_DISPATCH_ID` binding are
  preserved verbatim; (d) the function body composes on
  `progress_md_path "$issue_id"` (NOT `progress_md_path
  "$_RENDER_ISSUE_ID"` — both work today but the former mirrors
  the call shape used elsewhere in `main()` for raw `$issue_id`
  consumers).

- [ ] **4.3** Sanity-check `bash -n bin/render-prompt.sh` returns
  rc=0.

### Task 5: Add stage-conditional info-log for missing progress.md

- `depends_on: [4]`
- `touches: bin/render-prompt.sh::main` — new 3-line `if [[ ... ]];
  then log ...; fi` block inserted IMMEDIATELY AFTER the new
  `_RENDER_PROGRESS_MD_PATH` binding from Task 4 (and BEFORE the
  ENG-87 dispatch_id comment block).

Steps:

- [ ] **5.1** Use a single `Edit` call with `old_string` =
  the contiguous block from `_RENDER_PROGRESS_MD_PATH=...` (newly
  added in Task 4) through the start of the ENG-87 dispatch_id
  comment block, and `new_string` = the same block with the
  3-line `if/log/fi` inserted between them.

  Exact `old_string` (2 lines as they appear in the file
  POST-TASK-4 — confirmed by Task 4.2's read-back):

  ```
    _RENDER_PROGRESS_MD_PATH="$(progress_md_path "$issue_id")"
    # ENG-87 review-iter-7 M9: bind _RENDER_DISPATCH_ID like the sibling
  ```

  Exact `new_string` (5 lines — preserves both bookends, inserts
  the stage-conditional log block between them):

  ```
    _RENDER_PROGRESS_MD_PATH="$(progress_md_path "$issue_id")"
    if [[ "$stage" == "implementing" && ! -e "$_RENDER_PROGRESS_MD_PATH" ]]; then
      log "render-prompt: progress-md missing for $issue_id at $_RENDER_PROGRESS_MD_PATH (informational; agent's Read will note absence)"
    fi
    # ENG-87 review-iter-7 M9: bind _RENDER_DISPATCH_ID like the sibling
  ```

  Notes:
  - Stage scoping (`$stage == "implementing"`) is REQUIRED per
    D-005 — only the implementing prompt today references
    `{progress_md_path}`; logging on render of other stages is
    noise. When ui/qa/review readers land in the follow-up sub-
    ticket, the condition extends.
  - The `! -e` test is the appropriate predicate (file does not
    exist at all, regardless of file type/mode). `-f` would
    incorrectly skip on a directory at that path; `-s` would
    incorrectly fire on a zero-byte file (the brainstorm §5
    Error-Handling notes the empty-file case is acceptable
    no-op).
  - The log message ENDS with `(informational; agent's Read will
    note absence)` so an operator scanning the per-stage transcript
    knows the line is not an error/warning. The literal substring
    `progress-md missing` (hyphenated) is what Task 7's case-A
    fixture greps for. The hyphenated form matches the brainstorm
    D-003 message and the AC-2 wording verbatim ("logs a 'progress-md
    missing' info note").
  - `log` (sourced from `bin/common.sh` per A-019) writes to
    stderr; the per-stage transcript captures stderr per the
    harness's tee convention.
  - 4-space indentation matches the surrounding context.

- [ ] **5.2** Verify by reading back `bin/render-prompt.sh` lines
  ~415-430. Confirm: (a) `_RENDER_PROGRESS_MD_PATH=…` is preserved
  verbatim; (b) the new 3-line `if/log/fi` block appears
  immediately below; (c) the ENG-87 dispatch_id comment block is
  preserved verbatim below the new block; (d) the log substring
  is exactly `progress-md missing` (hyphenated, lowercase) — this
  is the literal string Task 7's case-A fixture asserts.

- [ ] **5.3** Sanity-check `bash -n bin/render-prompt.sh` returns
  rc=0.

### Task 6: Prepend progress.md as position 1 in AGENT_PROMPTS.md §3 read-first list

- `depends_on: [2, 3]`
- `touches: AGENT_PROMPTS.md` — single edit in §3 per A-008.

Steps:

- [ ] **6.1** Use a single `Edit` call with `old_string` =
  the existing 9-line read-first list (preamble + 8 numbered items)
  and `new_string` = the same preamble + new position-1 item +
  renumbered (former 1-8 → new 2-9) items.

  Exact `old_string` (9 lines as they appear at AGENT_PROMPTS.md
  lines 614-622):

  ```
  Read these files first (in order, where present):
  1. CLAUDE.md — coding standards and project structure
  2. Architecture / system docs as listed in the Project profile addendum's File layout (skip if not present)
  3. docs/knowledge/gotchas.md — filter by tags relevant to the modules you're modifying (skip if not present)
  4. docs/knowledge/decisions.md — follow all accepted ADRs (skip if not present)
  5. docs/knowledge/conventions.md — filter by tags relevant to the modules you're modifying (skip if not present)
  6. {learned_rules_dir}/implementation.md — learned rules from past retrospectives (follow ALL)
  7. docs/brainstorms/{brainstorm_file}
  8. docs/plans/{plan_file} — focus on "Backend Tasks" and the `api-contract` block
  ```

  Exact `new_string` (15 lines — preserves the preamble, inserts
  the new position-1 item with its 6-line body, renumbers items
  1-8 to 2-9 verbatim with no other word changes):

  ```
  Read these files first (in order, where present):
  1. {progress_md_path} — per-issue progress notebook (cross-dispatch
     context from prior agents on this issue; see
     docs/runbooks/progress-md.md). Read this BEFORE the other
     files: the prior dispatch may have flagged that a plan task
     is blocked, that a chosen approach failed, or that a
     dead-end was already explored. Skip if not present —
     first-dispatch-on-issue is normal.
  2. CLAUDE.md — coding standards and project structure
  3. Architecture / system docs as listed in the Project profile addendum's File layout (skip if not present)
  4. docs/knowledge/gotchas.md — filter by tags relevant to the modules you're modifying (skip if not present)
  5. docs/knowledge/decisions.md — follow all accepted ADRs (skip if not present)
  6. docs/knowledge/conventions.md — filter by tags relevant to the modules you're modifying (skip if not present)
  7. {learned_rules_dir}/implementation.md — learned rules from past retrospectives (follow ALL)
  8. docs/brainstorms/{brainstorm_file}
  9. docs/plans/{plan_file} — focus on "Backend Tasks" and the `api-contract` block
  ```

  Notes:
  - Items 2-9 in the new list are byte-for-byte the SAME
    descriptive text as items 1-8 in the old list, with ONLY the
    leading number changed. This preserves every existing
    semantic, link, and learned-rules cross-reference.
  - Item 1's body is 6 prose lines (continuation lines indented 3
    spaces to align under `{progress_md_path}` after the `1. `
    prefix). The continuation indentation matches the existing
    visual convention for multi-line numbered items elsewhere in
    `AGENT_PROMPTS.md`; if §3 has none today, the new item is the
    first multi-line entry but the indent is consistent with
    standard markdown.
  - The token `{progress_md_path}` is the literal string
    `render-prompt.sh::resolve_block_tokens` substitutes against
    the resolver from Tasks 2 + 3 (registry entry +
    `_resolve_progress_md_path()` function). The
    surrounding-curly-braces shape is required for resolution
    per `bin/render-prompt.sh:272`'s `\{[a-z_]+\}` regex.
  - The trailing `Skip if not present — first-dispatch-on-issue
    is normal.` clause is the agent-side "no-halt on missing
    file" instruction per D-003 (paired with the orchestrator-
    side info-log from Task 5).
  - The body intentionally does NOT instruct the agent to filter
    by `$PIPELINE_DISPATCH_ID` (that's brainstorm OQ-2 — the
    filter becomes load-bearing only when an implementing-stage
    writer also reads its own writes). For this ticket, the
    agent reads ALL entries (including any tagged with prior
    dispatch ids) and reasons about freshness inline.

- [ ] **6.2** Verify by reading back `AGENT_PROMPTS.md` lines
  613-630. Confirm: (a) the preamble line `Read these files first
  (in order, where present):` is preserved verbatim; (b) the new
  position-1 item appears with `1. {progress_md_path}` at column 0
  and continuation lines indented 3 spaces; (c) items 2-9 are
  byte-for-byte the former items 1-8 with only the leading number
  changed; (d) the closing fence ``` ``` ``` of the §3 block (further
  down at AGENT_PROMPTS.md ~line 800+) is preserved (no fence
  drift); (e) the `Your scope: backend modules ...` line at the
  former line 624 is preserved verbatim.

- [ ] **6.3** Sanity-check that `bash bin/render-prompt.sh
  implementing ENG-N` (for any test issue using the
  `bin/render-prompt-rc0-test.sh` sandbox) does NOT die with the
  unresolved-token error from `resolve_block_tokens` at
  `bin/render-prompt.sh:309`. If it does, Task 2 was not
  completed; revisit Task 2.2.

### Task 7: Add ENG-108 case-A/B fixtures to bin/render-prompt-rc0-test.sh

- `depends_on: [2, 3, 4, 5, 6]`
- `touches: bin/render-prompt-rc0-test.sh` — new ENG-108 case-A/B
  fixture pair inserted IMMEDIATELY BEFORE the final summary
  printf at line 159 per A-010.

Steps:

- [ ] **7.1** Use a single `Edit` call with `old_string` = the
  literal final summary printf line and `new_string` = the new
  ENG-108 case-A/B fixture block + the same final printf preserved
  verbatim.

  Exact `old_string` (1 line, unique within the file):

  ```
  printf '\n━━━ Summary ━━━\nPASS: %d / FAIL: %d\n' "$PASS" "$FAIL"
  ```

  Exact `new_string` (the new block + the preserved final printf):

  ```
  # ─── ENG-108: {progress_md_path} token wiring (implement reader pilot) ───
  # Two cases (mirror of the ENG-105 pair above):
  #   C. No progress.md exists in the per-issue state dir → render-prompt's
  #      stage-conditional log fires with `progress-md missing` to stderr;
  #      stdout still carries the resolved absolute path (the agent will
  #      Read-fail at runtime per D-003).
  #   D. progress.md present with a sentinel entry → no `progress-md
  #      missing` log fires; stdout still carries the resolved absolute
  #      path (the agent will Read it at runtime).
  # Both cases exercise the full main() path through the new
  # _RENDER_PROGRESS_MD_PATH binding, the new info-log condition, and the
  # resolve_block_tokens registry pass. A regression that drops
  # progress_md_path from PROMPT_RESOLVERS would die at the registry
  # validator with "unresolved token after registry pass: {progress_md_path}".

  ISSUE_DIR_C="$sandbox/state/test-slug-rc0/ENG-87R6X-C"
  rm -rf "$ISSUE_DIR_C"
  err_c="$(mktemp)"
  out_c="$(PIPELINE_DRY_RUN=1 LINEAR_API_KEY=test-mock-key \
    TARGET_REPO="$sandbox/target" PROJECT_SLUG=test-slug-rc0 \
    HARNESS_ROOT="$sandbox" HARNESS_STATE_DIR="$sandbox/state" \
    bash "$sandbox/bin/render-prompt.sh" implementing ENG-87R6X-C 2>"$err_c" || true)"
  if grep -qF "$ISSUE_DIR_C/progress.md" <<<"$out_c"; then
    ok "ENG-108 case C: absent progress.md → resolved absolute path appears in implementing prompt body"
  else
    fail "ENG-108 case C: absent progress.md → resolved absolute path in prompt body" \
         "stdout tail: $(tail -3 <<<"$out_c" | tr '\n' ' ')"
  fi
  if grep -qF 'progress-md missing' "$err_c"; then
    ok "ENG-108 case C: absent progress.md → stderr carries 'progress-md missing' info-log"
  else
    fail "ENG-108 case C: absent progress.md → 'progress-md missing' info-log on stderr" \
         "stderr tail: $(tail -3 "$err_c" | tr '\n' ' ')"
  fi
  rm -f "$err_c"

  ISSUE_DIR_D="$sandbox/state/test-slug-rc0/ENG-87R6X-D"
  rm -rf "$ISSUE_DIR_D"; mkdir -p "$ISSUE_DIR_D"
  PROGRESS_SENTINEL='SENTINEL-PROGRESS-MD-ENTRY-FROM-FIXTURE-D-9143'
  printf '## ENG-87R6X-D-d0001 - planning - 2026-05-16T12:34:56Z\n\n%s\n' "$PROGRESS_SENTINEL" \
    > "$ISSUE_DIR_D/progress.md"
  err_d="$(mktemp)"
  out_d="$(PIPELINE_DRY_RUN=1 LINEAR_API_KEY=test-mock-key \
    TARGET_REPO="$sandbox/target" PROJECT_SLUG=test-slug-rc0 \
    HARNESS_ROOT="$sandbox" HARNESS_STATE_DIR="$sandbox/state" \
    bash "$sandbox/bin/render-prompt.sh" implementing ENG-87R6X-D 2>"$err_d" || true)"
  if grep -qF "$ISSUE_DIR_D/progress.md" <<<"$out_d"; then
    ok "ENG-108 case D: present progress.md → resolved absolute path appears in implementing prompt body"
  else
    fail "ENG-108 case D: present progress.md → resolved absolute path in prompt body" \
         "stdout tail: $(tail -3 <<<"$out_d" | tr '\n' ' ')"
  fi
  if grep -qF 'progress-md missing' "$err_d"; then
    fail "ENG-108 case D: present progress.md → NO 'progress-md missing' info-log" \
         "stderr unexpectedly contained 'progress-md missing': $(tail -3 "$err_d" | tr '\n' ' ')"
  else
    ok "ENG-108 case D: present progress.md → no 'progress-md missing' info-log on stderr"
  fi
  rm -f "$err_d"

  printf '\n━━━ Summary ━━━\nPASS: %d / FAIL: %d\n' "$PASS" "$FAIL"
  ```

  Notes:
  - The block names cases C and D (continuing the ENG-105 A/B
    naming) so future readers grep `bin/render-prompt-rc0-test.sh`
    for `case A`, `case B`, `case C`, `case D` and find a clean
    chronology.
  - `ISSUE_DIR_C` is intentionally NOT mkdir'd before the
    render-prompt invocation (case C tests the missing-file path);
    `ISSUE_DIR_D` IS mkdir'd and pre-seeded.
  - The case-D sentinel uses an H2 heading shape that exactly
    matches the schema in `docs/runbooks/progress-md.md:34-58`
    (dispatch-id - stage - ISO-UTC), so a future change that
    extended the test to validate the heading shape would not need
    fixture rework.
  - `PIPELINE_DRY_RUN=1` and `LINEAR_API_KEY=test-mock-key` mirror
    the existing ENG-105 case-A/B invocations at lines 132-135 /
    148-151. The stub `linear.sh` returns the same JSON for any
    issue id (per A-012).
  - Stderr is captured to a tempfile (`err_c`, `err_d`) rather
    than discarded — case C asserts the literal substring
    `progress-md missing` IS present; case D asserts it is NOT
    present.
  - Both cases assert the resolved absolute path appears in
    stdout (the rendered prompt body); a regression that broke
    the resolver-registry pass would either die rc!=0 (caught by
    the existing per-stage iteration loop's rc=0 assertion) or
    leave the literal `{progress_md_path}` token in stdout
    (caught by the absent-path-substring test).
  - `ok`, `fail`, `PASS`, `FAIL` are the existing helpers from
    the file's preamble (lines 26-28); no new helpers introduced.
  - Test isolation: `rm -rf "$ISSUE_DIR_C"` and
    `rm -rf "$ISSUE_DIR_D"; mkdir -p "$ISSUE_DIR_D"` at the start
    of each case prevent cross-fixture contamination if the
    sandbox tempdir somehow inherits prior state.

- [ ] **7.2** Run `bash bin/render-prompt-rc0-test.sh`. Expect
  exit 0; the new four rows appear in the summary as `OK: ENG-108
  case C: absent progress.md → resolved absolute path …`,
  `OK: ENG-108 case C: absent progress.md → stderr carries
  'progress-md missing' …`, `OK: ENG-108 case D: present progress.md
  → resolved absolute path …`, `OK: ENG-108 case D: present
  progress.md → no 'progress-md missing' …`. If any assertion
  fails, diagnose:
  - Both case-C assertions failing AND case-D assertions failing
    suggests the registry entry (Task 2) did not land, or the
    `_RENDER_PROGRESS_MD_PATH` binding (Task 4) did not land —
    the `bash bin/render-prompt.sh implementing` invocation
    would die rc!=0 and `out_*` / `err_*` would be empty/short.
  - Case C's "stderr carries 'progress-md missing'" failing while
    everything else passes suggests the Task 5 stage-conditional
    log was not added (or was scoped to the wrong stage, or used
    the wrong substring).
  - Case D's "no 'progress-md missing'" failing suggests Task 5's
    log was scoped TOO BROADLY (e.g., fires regardless of file
    existence). Re-read the `if [[ "$stage" == "implementing" &&
    ! -e "$_RENDER_PROGRESS_MD_PATH" ]]` predicate.
  - Either case's "resolved absolute path appears in stdout"
    failing while the substring-grep is correct suggests Task 6's
    AGENT_PROMPTS.md prepend did not land (the prompt body has no
    `{progress_md_path}` token to substitute, so nothing
    appears).

### Task 8: Add ENG-108 §3 position-1 invariant to bin/agent-prompts-content-test.sh

- `depends_on: [6]`
- `touches: bin/agent-prompts-content-test.sh` — new §3 invariant
  inserted IMMEDIATELY AFTER the existing §3 lacks-`gh pr create`
  block per A-013.

Steps:

- [ ] **8.1** Use a single `Edit` call with `old_string` = the
  closing block of the existing §3 lacks-`gh pr create` assertion
  (4 lines as they appear in the file) and `new_string` = the same
  block + the new ENG-108 invariant block.

  Exact `old_string` (4 lines):

  ```
  if printf '%s\n' "$s3" | grep -qE 'gh pr create'; then
    nope "§3 lacks 'gh pr create'" "string 'gh pr create' present"
  else
    ok "§3 lacks 'gh pr create'"
  fi
  ```

  Exact `new_string` (the existing block preserved verbatim + the
  new ENG-108 invariant block):

  ```
  if printf '%s\n' "$s3" | grep -qE 'gh pr create'; then
    nope "§3 lacks 'gh pr create'" "string 'gh pr create' present"
  else
    ok "§3 lacks 'gh pr create'"
  fi

  # ─── ENG-108: §3 read-first list has {progress_md_path} at position 1 ───
  # The implementing prompt MUST instruct the agent to read the per-issue
  # progress notebook before any other onboarding artifact (Linear AC-1).
  # Pin the literal `1. {progress_md_path}` line in §3's body so a future
  # edit that demotes the token (or removes it entirely) trips here.
  if printf '%s\n' "$s3" | grep -qF '1. {progress_md_path}'; then
    ok "§3 ENG-108: read-first list has '{progress_md_path}' at position 1"
  else
    nope "§3 ENG-108: read-first list has '{progress_md_path}' at position 1" \
      "literal '1. {progress_md_path}' line missing from §3 — has the position-1 placement been demoted, or the token removed entirely?"
  fi
  ```

  Notes:
  - Uses `grep -qF` (fixed-string, not regex) so the `{` and `}`
    in `{progress_md_path}` are matched literally without
    escaping.
  - The assertion is presence-of-substring `1. {progress_md_path}`
    — matches OQ-4's "presence-only" recommendation in the
    brainstorm. Exact-wording would brittle-fail on any future
    copy-edit to the position-1 item's prose body.
  - The leading `1. ` is the load-bearing positional anchor (it
    asserts position 1 specifically). If a future edit moved the
    item to position 2, the literal line `1. {progress_md_path}`
    would no longer appear and the test would fire — exactly the
    desired regression behavior.
  - Insertion location (immediately after the existing §3
    lacks-`gh pr create` block) keeps all §3 invariants
    contiguous, matching the file's existing organization
    (§-block per topic).

- [ ] **8.2** Run `bash bin/agent-prompts-content-test.sh`.
  Expect exit 0; the new row appears as `OK: §3 ENG-108: read-first
  list has '{progress_md_path}' at position 1`. If the assertion
  FAILS:
  - Most likely cause: Task 6's prepend did not land (or landed
    with a different number — e.g., `0. {progress_md_path}` or
    `1) {progress_md_path}`).
  - Re-read `AGENT_PROMPTS.md` §3's read-first list and confirm
    the literal substring `1. {progress_md_path}` is present.

### Task 9: Run gates

- `depends_on: [2, 3, 4, 5, 6, 7, 8]`
- `touches: <runtime gates only — no file edits>`

Steps:

- [ ] **9.1** Run `bash bin/render-prompt-rc0-test.sh`. Expect exit
  0; every row passes (the existing per-stage iteration rows + the
  ENG-105 case A/B + the new ENG-108 case C/D). If any prior row
  regresses, diagnose: the most likely cause is a syntax error in
  a multi-line Edit (Task 2/3/4/5) — `bash -n bin/render-prompt.sh`
  would have caught it in 2.3 / 3.3 / 4.3 / 5.3.
- [ ] **9.2** Run `bash bin/agent-prompts-content-test.sh`. Expect
  exit 0; the new ENG-108 row passes alongside every existing row.
  If any existing row regresses, diagnose: the most likely cause
  is Task 6 inadvertently broke a §3 invariant (e.g., introducing
  a `gh pr create` substring in the new position-1 body — read the
  prose carefully).
- [ ] **9.3** Run `bash bin/render-prompt-test.sh`. Expect exit 0
  (this is the sibling that exercises `append_project_profile`
  individually; ENG-108 does not change that function). If FAIL,
  the change to `bin/render-prompt.sh` introduced a regression in
  the function-level test scaffolding — likely a global-name
  collision (`_RENDER_PROGRESS_MD_PATH` shadowing an existing
  test variable).
- [ ] **9.4** Run `bash .githooks/pre-commit`. Expect exit 0 (full
  `bin/*-test.sh` suite green; the per-stage allowlist for
  `implementing` includes `Bash(bash .githooks/pre-commit:*)` per
  the harness profile's `## Tool allowlist` section). If FAIL on
  any test other than the three above, diagnose: this plan touches
  `bin/render-prompt.sh` and `AGENT_PROMPTS.md`; any unrelated
  test failure is either a pre-existing failure (consult the
  hook's `KNOWN_BROKEN` allowlist) OR a sibling sweep collateral
  (e.g., the AGENT_PROMPTS.md edit accidentally introduced a
  forbidden token caught by ENG-97's negative-grep loop).
- [ ] **9.5** Run `bash -n bin/render-prompt.sh`. Expect rc=0 (the
  syntax-only check from the harness profile's "Lint/check" gate
  — already covered piecemeal by Tasks 2.3 / 3.3 / 4.3 / 5.3, but
  re-run as a final gate over the cumulative edits).

If 9.1, 9.2, 9.3, 9.4, and 9.5 all pass, the implementation is
complete.

## Frontend Tasks

(no UI surface — the harness is a Bash orchestration toolkit; there
is no FE the UI agent would touch. The UI Agent is skipped for this
ticket per the orchestrator's per-stage routing.)

## Failure Mode → Test Map

Pulled from the brainstorm's §5 "Error Handling" + §6 "Edge Cases"
sections.

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
|---|---|---|---|---|
| Implementing dispatch on issue with NO progress.md on disk | `progress.md` does not exist at `$PROJECT_STATE_DIR/<issue>/progress.md` (most issues today, until ENG-106 lands the writer) | render-prompt resolves the absolute path AND emits `render-prompt: progress-md missing for <issue> at <path> (informational; …)` to stderr; agent's prompt carries the path; agent's Read of the absent path returns "File does not exist" and the prompt's "Skip if not present" clause prevents halt | unit | `ENG-108 case C: absent progress.md → resolved absolute path` AND `ENG-108 case C: absent progress.md → stderr carries 'progress-md missing'` (in `bin/render-prompt-rc0-test.sh`) |
| Implementing dispatch on issue WITH progress.md on disk | `progress.md` exists with at least one entry (post-ENG-106; or post-implement-loopback once an implement-stage writer lands in a future ticket) | render-prompt resolves the absolute path AND does NOT emit `progress-md missing`; agent reads the file via Read tool; agent uses entries as cross-dispatch context | unit | `ENG-108 case D: present progress.md → resolved absolute path` AND `ENG-108 case D: present progress.md → no 'progress-md missing'` (in `bin/render-prompt-rc0-test.sh`) |
| Position-1 read-first item demoted or removed | future edit to `AGENT_PROMPTS.md §3` removes the `1. {progress_md_path}` line OR demotes it to a different position number | content test fires — `bin/agent-prompts-content-test.sh` greps for the literal `1. {progress_md_path}` substring in §3's body | unit | `§3 ENG-108: read-first list has '{progress_md_path}' at position 1` (in `bin/agent-prompts-content-test.sh`) |
| Resolver-registry entry dropped (regression) | future edit to `bin/render-prompt.sh::PROMPT_RESOLVERS` removes the `progress_md_path=_resolve_progress_md_path` line | `resolve_block_tokens` dies at line 309 with `render-prompt: unresolved token after registry pass: {progress_md_path}` because the AGENT_PROMPTS.md §3 body contains the unresolvable token | unit | covered by `bin/render-prompt-rc0-test.sh`'s per-stage iteration loop (lines 113-115) — the implementing-stage `bash bin/render-prompt.sh implementing ENG-87R6X` invocation would exit non-zero and the existing rc=0 assertion fires |
| Resolver function dropped while registry entry remains | future edit removes `_resolve_progress_md_path()` body but leaves the registry entry | `resolve_block_tokens` calls `_lookup_resolver` which returns `_resolve_progress_md_path`, then attempts to invoke it; bash errors `command not found`; `value=""` (per `2>/dev/null`); the prompt body substitutes `{progress_md_path}` with the empty string | unit | covered by `bin/render-prompt-rc0-test.sh`'s ENG-108 case-C/D fixtures — both cases assert the absolute path string `$ISSUE_DIR/progress.md` appears in stdout; an empty substitution would fail those assertions |
| Stage-conditional log scoped to wrong stage (e.g., fires for every stage) | future edit drops the `$stage == "implementing"` clause | render-prompt would emit `progress-md missing` on every render of every stage when the file is absent — visible regression to operators staring at per-stage transcripts | unit | `ENG-108 case C: …` exercises the implementing path; the existing per-stage iteration loop (lines 113-115) already runs every stage with HARNESS_STATE_DIR unset and would not trigger on absent files; if the loop's stages started emitting `progress-md missing`, a future tightening could add a per-stage "stderr does NOT contain 'progress-md missing'" assertion, but for ENG-108 the case C/D pair plus the existing rc=0 row is sufficient |
| Stage-conditional log scoped too narrowly (file present but log fires anyway) | future edit changes `! -e` to `-e` (predicate inverted) | `progress-md missing` would log on case D — the file exists but the predicate fires | unit | `ENG-108 case D: present progress.md → no 'progress-md missing'` (in `bin/render-prompt-rc0-test.sh`) |
| `progress.md` exists but is zero bytes (legitimate edge per brainstorm §5) | first-write-failed-mid-write or a manual `touch` with no append | render-prompt's `! -e` test returns false (file exists), so no `progress-md missing` log fires; agent Reads zero content and treats as no-op | unit | implicit in `ENG-108 case D: …no 'progress-md missing'` — the case-D fixture writes a non-empty sentinel, but the predicate is `! -e` not `! -s`, so a hypothetical zero-byte case D would also pass this assertion. Adding a dedicated zero-byte case is gold-plating per brainstorm §5 ("Acceptable: agent will read zero entries and proceed.") |
| Sub-agent debris (a fixture file written outside the allowlist) | implement agent writes `.review-body.md` / fixture markdown / scratch text at the worktree root | `bin/run-local.sh`'s `partition_dirty_paths` classifies as self-leak; soft fail incrementing `.consecutive-failures` | integration (orchestrator-side; covered by `bin/run-local-sweep-test.sh` which already gates this surface for every issue) | covered by existing `bin/run-local-sweep-test.sh` (no new fixture needed; the implement agent's prompt + Task 7's case-A/B fixture pre-cleanup with `rm -rf "$ISSUE_DIR_C"` are the prevention) |
| `PROJECT_STATE_DIR` unset (bootstrap mode) | `bin/render-prompt.sh` invoked outside the launchd / `bin/setup.sh` flow with no `PROJECT_SLUG` exported | `progress_md_path "$issue_id"` returns `/<issue>/progress.md` (a malformed path; ENG-107 §6 inherits this hazard from `issue_dir`); `! -e` test returns true; info-log fires with the malformed path; agent Read fails on the malformed path; no damage | smoke (manual; not asserted by any test today — bootstrap-mode renders are an operator-only debug surface, not a runtime path) | covered by brainstorm §6 "PROJECT_STATE_DIR unset (bootstrap mode)" and inherited from ENG-107's identical edge case |
| Agent-runtime token confusion (token added to `AGENT_RUNTIME_TOKENS` by accident) | future edit appends `progress_md_path` to `AGENT_RUNTIME_TOKENS` at `bin/render-prompt.sh:75` | `resolve_block_tokens`'s `AGENT_RUNTIME_TOKENS` skip (line 284-286) would short-circuit before the registry lookup; the token would be left as literal `{progress_md_path}` text in the prompt; the agent would see an unresolved literal string and have no path to read | unit | covered by `bin/render-prompt-rc0-test.sh`'s ENG-108 case-C/D fixtures — both assert the resolved absolute path string `$ISSUE_DIR/progress.md` appears in stdout; a literal `{progress_md_path}` would fail both assertions |

## Test Strategy

- **Unit (new — `bin/render-prompt-rc0-test.sh`).** Two new fixture
  cases (C and D) inserted before the final summary printf per
  Task 7. Each case asserts two facts: (1) the resolved absolute
  progress.md path appears in stdout (implies registry lookup +
  resolver function + main()-bound global all worked), and (2)
  the `progress-md missing` info-log fires (case C) or does NOT
  fire (case D). The four assertions cover every layer this plan
  adds (Tasks 2, 3, 4, 5, 6) under both branches of the
  conditional. The fixtures reuse the existing sandbox setup (no
  new test scaffolding) and the existing `ok`/`fail`/`PASS`/`FAIL`
  helpers (no new helper functions).

- **Unit (new — `bin/agent-prompts-content-test.sh`).** One new §3
  invariant assertion inserted after the existing §3 invariants
  per Task 8. Asserts the literal substring `1. {progress_md_path}`
  appears in §3's body. Defends against future edits that demote
  the position-1 placement (the load-bearing AC-1 commitment).
  Presence-only assertion per OQ-4's recommendation; exact-wording
  is rejected as brittle.

- **Unit (existing — re-run as gate).** `bin/render-prompt-rc0-test.sh`'s
  per-stage iteration loop at lines 113-115 already exercises
  `bash bin/render-prompt.sh implementing ENG-87R6X` and asserts
  rc=0. Post-Task 6, that invocation will additionally substitute
  the new `{progress_md_path}` token; if Task 2's registry entry
  is missing, the existing rc=0 assertion catches the regression
  via the registry's `die "render-prompt: unresolved token after
  registry pass: ..."` path. The per-stage loop is therefore an
  additional gate on Task 2 + Task 6 wiring.

- **Unit (existing — re-run as gate).** `bin/render-prompt-rc0-test.sh`'s
  ENG-105 case A/B fixtures at lines 117-157 are unchanged by
  this plan. They continue to assert that
  `_resolve_review_findings` works correctly. ENG-108 adds
  sibling resolvers/bindings; a regression that broke the
  `_RENDER_REVIEW_FINDINGS_PATH` binding (e.g., Task 4's Edit
  trimmed the wrong line) would surface here.

- **Unit (existing — re-run as gate).** `bin/render-prompt-test.sh`
  exercises `append_project_profile` individually. ENG-108 does
  not touch that function; it stays green. Listed here so that a
  Task 9.3 regression has a documented diagnostic path (the most
  likely cause is a global-name collision between
  `_RENDER_PROGRESS_MD_PATH` and an existing test variable).

- **Unit (existing — re-run as gate).** `bin/agent-prompts-content-test.sh`'s
  pre-existing §3 invariants (`Do NOT create a PR`, `lacks gh pr
  create` — lines 73-83) are unchanged; the new ENG-108 invariant
  is appended after them. The pre-existing ENG-97 forbidden_token
  loop scans `AGENT_PROMPTS.md` for Tauri-shaped tokens; the new
  prompt body Task 6 introduces contains zero such tokens. The
  pre-existing §2 fence-count invariants do not touch §3 and are
  unaffected.

- **Integration (existing — re-run as gate).** `.githooks/pre-commit`
  runs the full `bin/*-test.sh` suite. Per Task 9.4. The relevant
  sibling tests for unintended cross-cutting regressions include
  `bin/run-stage-test.sh` (verifies `_clear_current_stage_slots`
  enumerates exactly the documented set; no change in this plan
  means it stays green), `bin/run-local-sweep-test.sh` (verifies
  `partition_dirty_paths` classification; `progress.md` lives
  outside the worktree so out-of-worktree paths stay invisible),
  `bin/dispatch-test.sh` (verifies allowed-tools per stage; the
  implementing allowlist already grants Read implicitly so no
  change), and `bin/vocabulary-cleanliness-test.sh` (verifies the
  closed pipeline-marker vocabulary; the new prompt body uses
  prose only, no `<!-- pipeline:...-->` markers).

- **Smoke (manual at implement-time).** Task 4.2, Task 5.2, Task
  6.2 readbacks are documentation-correctness gates: confirm the
  Edit landed verbatim against the expected lines. Not test-pinned;
  the readbacks are part of the implement agent's discipline.

- **Adversarial (none new).** The new resolver is a 1-line pure
  printf of a `_RENDER_*` global; the new info-log is a 3-line
  conditional with no I/O beyond `! -e` + `log` (stderr). There
  is no syscall surface beyond `! -e` (a single stat), no Linear/
  git/jq dependency, no credential surface, no race surface (the
  resolver is invoked synchronously by the rendering process).
  The brainstorm §5 explicitly enumerates the resolver's failure
  modes; none warrant adversarial coverage today.

- **End-to-end (none new).** The agent's runtime behavior (Read
  the path, react to absence per the prompt's "Skip if not
  present" instruction) is structural — the prompt-text placement
  is verifiable by grep (Task 8) and the path-resolution is
  verifiable by render-prompt rc0 (Task 7). An end-to-end test
  would require a live `claude -p` dispatch which `PIPELINE_DRY_RUN=1`
  short-circuits per the harness profile. Per brainstorm D-004's
  rejected `bin/run-stage-test.sh` integration alternative, that
  surface adds no observable behavior beyond what the rc0 test
  covers.

- **Test-gate closure.** Per A-020, this plan REMOVES no tokens
  from any tracked file. The closure sweep has no test files to
  audit for soon-to-be-broken pinned-absent assertions. Five new
  tokens introduced (`progress_md_path` registry entry,
  `_resolve_progress_md_path` function name, `_RENDER_PROGRESS_MD_PATH`
  global, `progress-md missing` info-log substring,
  `{progress_md_path}` AGENT_PROMPTS.md token) — none are
  pinned-ABSENT by any existing `bin/*-test.sh`. Zero closure
  defects.
