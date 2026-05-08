---
linear: ENG-77
date: 2026-05-08
topic: Pin reviewer's overwrite-every-dispatch contract in §5 prompt + content test; record the deferrals (defensive net + typed channel + §§3,4 generalisation) with un-deferral preconditions; no new code on the implement stage of this branch (D-001/D-002 already shipped on main as bd8ca2d via PR #61)
---

# Plan — ENG-77 reviewer stage-summary stale-file contract

Implementation plan for the brainstorm at
`docs/brainstorms/2026-05-08-eng-77-reviewer-agent-s-stage-summary-file-goes-stale-across-review-implement-loops-blinding-the-implement-agent-on-loopback-design.md`.

## Goal

When the review agent is dispatched on a loopback re-entry (a prior
`stage-summary-reviewing.md` already exists on disk from an earlier
iter), the next reviewer dispatch MUST overwrite the file with current-
iter content, so `bin/run-stage.sh::post_completion_comment` (lines
147-224) reads and posts the iter that just ran rather than a stale
prior-iter body. The contract is enforced at the prompt layer
(`AGENT_PROMPTS.md §5` Output) and pinned by content-test asserts
(`bin/agent-prompts-content-test.sh §5` invariants block) so a future
prompt-cleanup pass cannot silently drop the rule.

**The narrow change set (D-001 + D-002 from the brainstorm) already
shipped on `main` via PR #61, commit `bd8ca2d` (verified: `git
merge-base --is-ancestor bd8ca2d main` returns 0; the same SHA is also
an ancestor of the current branch HEAD `c4b8752`, so this worktree
already carries the fix).** The implement stage on this branch
therefore produces **no new code change** — its job is to (a) verify
the shipped diff is present in HEAD at the documented path:line
anchors, (b) confirm the pre-commit test suite is green, and (c) post
the TDD-evidence comment + verdict-pass marker the orchestrator
expects. The plan-doc commit on this branch (this file) plus the
brainstorm-doc commit `c4b8752` are the only artifacts the
brainstorm/plan/implement chain on `feat/eng-77-...` is asked to
produce.

**Trade-off the brainstorm makes explicit (Goal G-5).** D-001 alone
relies on agent discipline (the agent honoring the prompt mandate);
the deferred defensive net (D-004 — orchestrator-side mtime check)
would catch a hypothetical disobedient agent at the orchestrator
layer. The plan accepts this trade because (a) the fix is reversible
in minutes if it proves wrong, (b) the mtime layer requires expanding
the closed `halt_reasons` registry at `bin/pipeline-events.json:11-19`
(or routing through `agent-blocked` with a sub-reason note — both
cross-cutting), and (c) the prompt rule's named-incident citation is
self-justifying for a future maintainer in a way a generic mtime
check is not.

## Anti-anchoring check

- **Problem restated.** ENG-71 cycled review→implement→ui→reviewing 9
  times in 9 hours (~$50, 2 manual interventions) without converging
  because the reviewer agent's iters 6-9 emitted fresh `verdict fail`
  markers but never rewrote `stage-summary-reviewing.md`. The
  orchestrator's `post_completion_comment` (`bin/run-stage.sh:147-224`,
  read site at `bin/run-stage.sh:182-191`) reads that file verbatim
  and posts it under sig `completion/reviewing/<issue>`, so the iter-5
  body landed on Linear every iter; the implement agent on each
  loopback read the stale body, fixed everything in it, reported
  done; reviewer re-ran, re-found the same NEW issues iter-9 had
  named, re-emitted fail. The bug is upstream of the dedup/equality
  machinery the implement agent fingered (ENG-63) — the
  `add_or_update_comment` path runs cleanly each tick because bodies
  are equal-after-strip. The contract gap is at the agent layer:
  `AGENT_PROMPTS.md §5` Output's stage-summary bullet was silent on
  whether overwrite-every-dispatch was required, and iters 6-9
  interpreted "file already exists with reasonable content" as "skip
  the Write."
- **Brainstorm's solution.** The bug is at the agent layer, so the
  fix is at the prompt layer — D-001 expands the §5 stage-summary
  bullet to mandate overwrite-every-dispatch with a named-incident
  citation, D-002 pins the rule with three content-test asserts.
  Three deferrals are recorded with un-deferral preconditions: D-003
  (do NOT generalise the rule to §§3, 4 — the bug substrate exists
  there but the misreading hasn't been observed), D-004 (do NOT add
  defensive mtime check in `run-stage.sh` — closed-vocabulary
  expansion + 4 control-flow interaction points), D-005 (do NOT
  build the typed cross-stage findings channel — multi-stage refactor
  + registry edit + back-compat cost).
- **Solution proportionality.** 12 lines added to `AGENT_PROMPTS.md`
  inside §5's existing fenced block (no new fence, no renumbered
  section). 40 lines added to `bin/agent-prompts-content-test.sh`
  inside the §5 invariants block (no new test runner, no new
  fixture). 0 lines of code in `bin/` outside the test file. No new
  files, no new exports, no new env vars, no new config keys, no
  changes to `bin/pipeline-events.json`, no `run-stage.sh` /
  `dispatch.sh` / `linear.sh` edits. The diff is strictly inside two
  text files.
- **Verdict.** Both checks pass. Proceed without `pipeline:supersede` /
  `pipeline:extend`.

## Assumption inventory

Every code-level claim is verified against the worktree at
composition time (branch
`feat/eng-77-reviewer-agent-s-stage-summary-file-goes-stale-across-review-implement-loops-blinding-the-implement-agent-on-loopback`,
HEAD `c4b8752`). The shipped commit is `bd8ca2d` (PR #61); both are
in this branch's history.

- **A-001 — `AGENT_PROMPTS.md:1027-1039` carries the MANDATORY
  overwrite-every-dispatch paragraph as shipped by D-001.**
  - `AGENT_PROMPTS.md:1027` — `- Stage-summary file at {stage_summary_path} (per the Stage summary comment`
  - `AGENT_PROMPTS.md:1028` — `  format contract). **MANDATORY — overwrite on every dispatch.** Use `Write``
  - `AGENT_PROMPTS.md:1029` — `  with the full report content; do not read-then-conditionally-skip. The`
  - `AGENT_PROMPTS.md:1030` — `  file's contents at exit time are your authoritative report — the`
  - `AGENT_PROMPTS.md:1031` — `  orchestrator reads it verbatim and posts it as the Linear`
  - `AGENT_PROMPTS.md:1032` — `  `completion/reviewing/{issue_id}` summary. If your findings are unchanged`
  - `AGENT_PROMPTS.md:1033` — `  from a prior iter (rare on a re-dispatched review-loopback), re-write the`
  - `AGENT_PROMPTS.md:1034` — `  same content; the orchestrator's footer-only re-apply path covers`
  - `AGENT_PROMPTS.md:1035` — `  visibility. ENG-71 (May 2026) cycled 9 review-implement loops because`
  - `AGENT_PROMPTS.md:1036` — `  iters 6-9 emitted fresh `verdict fail` markers but never updated this`
  - `AGENT_PROMPTS.md:1037` — `  file — the orchestrator kept posting the iter-5 stale body to Linear,`
  - `AGENT_PROMPTS.md:1038` — `  the implement agent kept reading the stale body, and no new feedback`
  - `AGENT_PROMPTS.md:1039` — `  reached the next iteration. Do not repeat.`
  - **Status:** verified by direct read in the current worktree. The
    paragraph sits inside §5's existing fenced block (between the
    `Output:` heading at line 1021 and the `Verdict marker
    (MANDATORY at exit):` heading at line 1046); no new column-0
    fence is introduced, so `bin/render-prompt.sh::extract_block`'s
    "fence count must be exactly 2" invariant is preserved.

- **A-002 — `bin/agent-prompts-content-test.sh:197-235` carries the
  three new asserts shipped by D-002 (overwrite phrase, no-skip
  carve-out, ENG-71 citation).**
  - `bin/agent-prompts-content-test.sh:197` — `# ─── ENG-71 followup: §5 mandates overwriting the stage-summary file ───`
  - `bin/agent-prompts-content-test.sh:211` — `if printf '%s\n' "$s5" | grep -qiE 'overwrite[ d]+on every dispatch'; then`
  - `bin/agent-prompts-content-test.sh:212` — `  ok "§5 mandates 'overwrite on every dispatch' for the stage-summary file"`
  - `bin/agent-prompts-content-test.sh:221` — `if printf '%s\n' "$s5" | grep -qF 'read-then-conditionally-skip'; then`
  - `bin/agent-prompts-content-test.sh:222` — `  ok "§5 explicitly bans 'read-then-conditionally-skip' on the stage-summary file"`
  - `bin/agent-prompts-content-test.sh:230` — `if printf '%s\n' "$s5" | grep -qE 'ENG-71.*(May|2026)'; then`
  - `bin/agent-prompts-content-test.sh:231` — `  ok "§5 cites the ENG-71 incident as the reason for the overwrite rule"`
  - **Status:** verified by direct read. The block lands inside the
    `# ─── ENG-50 / ENG-54: §5 invariants ───` block opened at line
    155 (where `s5="$(section_body "## 5. Review Agent")"` is set
    once at line 156), AFTER the existing ENG-50/ENG-54 invariants
    (lines 156-195) and BEFORE the ENG-53 #11(a) probe-litter
    invariants (lines 237+). Block ordering follows the existing
    reverse-chronological-by-incident convention.

- **A-003 — `bin/run-stage.sh::post_completion_comment` (lines
  147-224) is the orchestrator read-and-post path that posted the
  stale body in the ENG-71 cycle and that D-001's mandate now keeps
  fresh.**
  - `bin/run-stage.sh:147` — `post_completion_comment() {`
  - `bin/run-stage.sh:148` — `  local issue="$1" stage="$2"`
  - `bin/run-stage.sh:149` — `  local summary_path; summary_path="$(issue_dir "$issue")/stage-summary-${stage}.md"`
  - `bin/run-stage.sh:150` — `  local sig="completion/${stage}/${issue}"`
  - `bin/run-stage.sh:179-184` — read-arm: `if [[ -L "$summary_path" ]]; then fallback_marker="summary_symlink_refused"; elif [[ ! -s "$summary_path" ]]; then fallback_marker="summary_missing"; else …`
  - `bin/run-stage.sh:186` — body sed-strips dedup-marker LINES + legacy `<!-- pipeline-<word>: ... -->` lines: `body="$(sed -E -e '/<!-- meta: dedup key=.* -->/d' -e '/<!-- pipeline-[a-z]+: .* -->/d' "$summary_path" | head -c 32768)"`
  - `bin/run-stage.sh:219-223` — `add-or-update-comment` upsert with one retry: `if bash "$SCRIPT_DIR/linear.sh" add-or-update-comment "$sig" "$issue" "$comment_body"; then return 0; fi; sleep 5; bash "$SCRIPT_DIR/linear.sh" add-or-update-comment "$sig" "$issue" "$comment_body"`
  - **Status:** verified by direct read. The function is unchanged by
    this PR (D-001 ships the prompt rule, not an orchestrator edit).
    The brainstorm's E-7a security finding flagged that line 186's
    sed does NOT strip `<!-- meta: reapplied at=... -->` lines from
    the body — explicitly **out of scope for ENG-77**, recorded as a
    follow-up bundled with D-004's eventual un-deferral.

- **A-004 — `bin/run-stage.sh:495-497` is `_handle_wait`'s pre-emptive
  clear of the stage-summary file (build's wait-budget path is
  structurally immune to the bug).**
  - `bin/run-stage.sh:495` — `  # Clear any stale stage-summary file so a later post_completion_comment`
  - `bin/run-stage.sh:496` — `  # cannot post stale content from a prior dispatch.`
  - `bin/run-stage.sh:497` — `  rm -f "$(issue_dir "$ident")/stage-summary-${stage}.md" 2>/dev/null || true`
  - **Status:** verified. Build (§7) is the only stage that clears
    the file pre-dispatch; review/implement/ui all inherit residual
    files across loopback re-dispatches, which is the substrate
    that made ENG-71 possible. D-003 leans on this distinction.

- **A-005 — `bin/run-stage.sh:1080-1084` is the success-path cleanup
  that clears `issue-state.json` and skip labels but does NOT clear
  `stage-summary-<stage>.md`.**
  - `bin/run-stage.sh:1081` — `      rm -f "$(issue_dir "$ident")/issue-state.json" 2>/dev/null || true`
  - `bin/run-stage.sh:1082` — `      rm -f "$(issue_dir "$ident")/wait-${stage}.json" 2>/dev/null || true`
  - `bin/run-stage.sh:1083-1084` — remove `pipeline:skip-until-code-changes` / `pipeline:skip-until-human-acts`
  - **Status:** verified. The absence of an explicit
    `stage-summary-${stage}.md` removal is exactly the architectural
    surface D-003's "structural exposure exists in §3, §4, §5" claim
    rests on. Brainstorm O-2 records the smaller alternative
    (clearing the file on success) without pursuing it; not in
    scope for this plan.

- **A-006 — `AGENT_PROMPTS.md:665` (§3 Implement Output bullet) and
  `AGENT_PROMPTS.md:810` (§4 UI Output bullet) carry the minimal
  pre-D-001 language. D-003 explicitly DOES NOT change these lines.**
  - `AGENT_PROMPTS.md:665` — `- Write the stage summary file at `{stage_summary_path}` — follow the Stage summary`
  - `AGENT_PROMPTS.md:810` — `- Write the stage summary file at `{stage_summary_path}` — follow the Stage summary`
  - **Status:** verified. Both bullets are unchanged by D-001/D-002
    and remain unchanged by this plan (D-003).

- **A-007 — `bin/linear.sh::add_or_update_comment` advances `updatedAt`
  on identical-body re-apply via the `<!-- meta: reapplied at=… -->`
  footer (ENG-63 fix); D-001's "footer-only re-apply path covers
  visibility" language relies on this.**
  - `bin/linear.sh:541-548` — function entrypoint
  - `bin/linear.sh:559-563` — marker append (new + legacy shapes)
  - `bin/linear.sh:577-579` — search via `select(.body | contains($m) or contains($l))`
  - `bin/linear.sh:582-606` — reapplied-footer mutation when bodies are byte-equal-after-strip (the ENG-63 fix)
  - `bin/linear.sh:607-611` — `commentUpdate` mutation
  - `bin/linear.sh:613-617` — fall-through `commentCreate`
  - **Status:** verified by direct read at the cited line ranges. No
    changes by this plan.

- **A-008 — `bin/pipeline-events.json:11-19` enumerates 8
  `halt_reasons`; `stale-stage-summary` is NOT among them. D-004's
  un-deferral would require expanding this list.**
  - `bin/pipeline-events.json:11-19` — `"halt_reasons": ["agent-blocked", "agent-failure", "smoke-failed", "iteration-exhausted", "scope-violation", "protocol-violation", "dispatch-timeout", "pr-opened-too-early"]`
  - **Status:** verified by direct read. No registry change by this
    plan.

- **A-009 — `bin/pipeline-events.json:42-48` enumerates 5
  `meta_kinds`; `findings` is NOT among them. D-005's un-deferral
  would require adding it.**
  - `bin/pipeline-events.json:42-48` — `"meta_kinds": ["dedup", "metric", "evidence", "reapplied", "forensic"]`
  - **Status:** verified by direct read. No registry change by this
    plan.

- **A-010 — Branch `feat/eng-77-...` already contains the shipped
  fix. `git merge-base --is-ancestor bd8ca2d HEAD` returns 0; the
  diff between the in-worktree `AGENT_PROMPTS.md` and the
  post-`bd8ca2d` `AGENT_PROMPTS.md` on `main` is empty for §5 lines
  1021-1069.**
  - **Status:** verified. The implement stage on this branch produces
    no new lines of `AGENT_PROMPTS.md` or `bin/agent-prompts-content-
    test.sh` content. The §11 banner in the brainstorm marks "Static
    gates GREEN; live-verify gates PENDING" — the implement agent's
    job here is to confirm the static state and post evidence, not
    to recreate the diff.

- **A-011 — `.githooks/pre-commit` runs the full `bin/*-test.sh`
  suite including `bin/agent-prompts-content-test.sh`, so D-002's
  asserts gate every commit that touches `AGENT_PROMPTS.md`.**
  - **Status:** verified per CLAUDE.md "Pre-commit hook" §; the hook
    bypass `git commit --no-verify` is not used by this PR.

- **A-012 — `learned-rules/harness/` contains only `build.md` and
  `project-profile.md` at composition time (no `review.md`, no
  `plan.md`, no `implementation.md`).**
  - **Status:** verified via Glob `learned-rules/**/*.md`. Brainstorm
    O-4 records this. A future retrospective-authored `review.md`
    can only ADD to the §5 base prompt (per CLAUDE.md "AGENT_PROMPTS.md
    is load-bearing" §); it cannot weaken D-001's mandate.

- **A-013 — `bin/render-prompt.sh::extract_block` requires exactly 2
  column-0 fences per stage section. D-001's edit lands inside §5's
  existing fenced block; no new column-0 fence is introduced.**
  - `bin/agent-prompts-content-test.sh:147-153` covers the §2
    fence-count case; `bin/render-prompt-test.sh` (per CLAUDE.md
    "AGENT_PROMPTS.md is load-bearing" §) is the cross-section
    backstop.
  - **Status:** verified. Re-running `bash bin/render-prompt.sh
    reviewing` would emit §5's full body including lines 1027-1039
    (the brainstorm verifies this at composition); the implement
    agent re-runs it as part of Task 2 below.

- **A-014 — `bin/dispatch.sh::allowed_tools_for "reviewing"` includes
  `Read,Write` so the agent CAN invoke either; the brainstorm's
  EC-5 carve-out (Read is allowed; the *decision* to skip Write is
  what's banned) relies on this.**
  - **Status:** verified per brainstorm §12 "Codebase-fact
    verification" — `bin/dispatch.sh:284-285` (the `reviewing` line
    of `allowed_tools_for`).

- **A-015 — `bin/verdict-handler.sh::_VH_LOOPBACK_TRANSITIONS` (lines
  32-38) lists `reviewing|implementing` as a direct loopback row;
  `reviewing|ui` is NOT a row.** UI is reached on review-loopback
  only via the forward `implementing|ui` transition AFTER
  review-loopback dispatches implementing. D-005's "ui re-dispatched
  on every iter though not a direct loopback target" claim relies
  on this.
  - **Status:** verified per brainstorm §4 D-005's "Verified facts"
    paragraph.

- **A-016 — `bin/common.sh::issue_dir` resolves to
  `$PROJECT_STATE_DIR/<ident>` and validates `ident =~
  ^[A-Z]+-[0-9]+$`. The brainstorm's D-004 security precondition
  (validate `$ident` at the un-deferral mtime callsite) leans on
  the validator already existing at `bin/common.sh:67-72`.**
  - **Status:** verified. No callsite changes in this plan.

- **A-017 — Linear has no comment-delete mechanism; this is what
  forces sigs to be append-only-or-upsert. The brainstorm's
  reasoning that probe-comments "become permanent thread litter"
  relies on this.**
  - `bin/linear.sh` exports no `delete-comment` subcommand
    (verified by direct read of the script's case-statement
    dispatcher).
  - **Status:** verified.

All seventeen load-bearing facts verify in the current worktree.

## File Structure

The "Modified" files below carry the diff that **already shipped on
`main` via PR #61, commit `bd8ca2d`**, and that is already present in
this branch's HEAD. The implement stage on this branch produces no
new lines in either file — the implement agent's contract is to
verify the diff is present and pass. No new files are created.

- **MODIFIED (already shipped, no new edit by this plan)**
  `AGENT_PROMPTS.md` — §5 Review Agent's `Output` section, the
  `Stage-summary file at …` bullet at lines 1027-1039, expanded with
  the MANDATORY overwrite-every-dispatch paragraph (12 lines added
  inside §5's existing fenced block). Per A-001.
- **MODIFIED (already shipped, no new edit by this plan)**
  `bin/agent-prompts-content-test.sh` — three new asserts in the §5
  invariants block at lines 197-235 (overwrite-phrase, no-skip
  carve-out, ENG-71 citation). 40 lines added (94 cases up from 91,
  per the shipped commit's diff stat). Per A-002.
- **NOT MODIFIED (D-003 — explicit non-change)** `AGENT_PROMPTS.md`
  §3 Implement (`AGENT_PROMPTS.md:665`) and §4 UI
  (`AGENT_PROMPTS.md:810`) — both share the architectural substrate
  (residual `stage-summary-<stage>.md` across loopback re-dispatches
  per A-005) but neither has observed the silent-skip behaviour, so
  the rule is not generalised. Brainstorm D-003 records the
  un-deferral preconditions.
- **NOT MODIFIED (D-004 — explicit non-change)** `bin/run-stage.sh`,
  `bin/pipeline-events.json` — defensive mtime check + halt-reason
  registry expansion deferred. Brainstorm D-004 records the
  un-deferral preconditions including the security precondition
  (`$ident` validation at the mtime callsite).
- **NOT MODIFIED (D-005 — explicit non-change)** typed cross-stage
  findings channel — `bin/pipeline-events.json::meta_kinds`,
  `AGENT_PROMPTS.md §3` (loopback findings read), and the new
  `findings` meta-kind parser path are untouched. Brainstorm D-005
  records the un-deferral preconditions including the schema design
  precondition (typed JSON body + byte-cap + nested-marker
  rejection).

No new files. No new exports. No new env vars. No new config keys.
No changes to `bin/pipeline-events.json`. No changes to
`bin/run-stage.sh`, `bin/dispatch.sh`, `bin/linear.sh`,
`bin/verdict-handler.sh`, or `bin/common.sh`. No CLAUDE.md edit (the
`stage-summary-<stage>.md` path is already documented at
`CLAUDE.md:208-211`).

## API Contract

no new API surface (this is a bash-orchestration repo with no FE↔BE
API; the only "interface" change is the agent contract documented in
`AGENT_PROMPTS.md §5` Output, which is consumed by `claude -p` via
`bin/render-prompt.sh::extract_block` and asserted by
`bin/agent-prompts-content-test.sh`).

## Backend Tasks

### Task 1: Verify the shipped diff is present in this branch's HEAD at the documented anchors

- `depends_on: []`
- `touches: AGENT_PROMPTS.md (verify lines 1027-1039), bin/agent-prompts-content-test.sh (verify lines 197-235)`
- [ ] Open `AGENT_PROMPTS.md` and confirm lines 1027-1039 carry the
      MANDATORY overwrite-every-dispatch paragraph verbatim per
      A-001 (the 12-line bullet expansion shipped by D-001). The
      paragraph must contain the literal phrases:
  - `MANDATORY — overwrite on every dispatch`
  - `do not read-then-conditionally-skip`
  - `ENG-71 (May 2026)` (or `ENG-71` followed by `2026` within the
    same sentence — the test regex at A-002 line 230 is
    `ENG-71.*(May|2026)`)
- [ ] Open `bin/agent-prompts-content-test.sh` and confirm lines
      197-235 carry the three asserts per A-002. Each assert pairs an
      `ok "§5 …"` line with a `nope "§5 …"` line; all three must be
      present.
- [ ] Confirm by reading lines 1021 (Output: heading) and 1046
      (Verdict marker heading) of `AGENT_PROMPTS.md` that the new
      paragraph sits inside §5's existing fenced block — i.e., no
      new column-0 ``` fence is introduced inside §5. (Per CLAUDE.md
      "AGENT_PROMPTS.md is load-bearing" §, `bin/render-prompt.sh::
      extract_block` requires exactly 2 column-0 fences per stage
      section.)
- [ ] Run `bash bin/render-prompt.sh reviewing` and confirm the
      emitted prompt body includes the full 12-line paragraph
      (search the output for `MANDATORY — overwrite on every
      dispatch`; the phrase must appear exactly once).

### Task 2: Confirm the pre-commit test suite is green on the current HEAD

- `depends_on: [1]`
- `touches: (test execution only — no file edits)`
- [ ] Run `bash bin/agent-prompts-content-test.sh` and confirm the
      summary line shows 94 passed cases (was 91 pre-`bd8ca2d`; +3
      new asserts in the §5 invariants block per A-002).
- [ ] Run the full `bin/*-test.sh` suite via the pre-commit hook
      path. CLAUDE.md "Pre-commit hook" § says ~30 seconds of total
      runtime and a short `KNOWN_BROKEN` allowlist exempts pre-
      existing failures. Expected outcome: every test other than
      KNOWN_BROKEN entries passes. Do NOT use `git commit --no-verify`
      to bypass.
- [ ] If the pre-commit suite is NOT green on the current HEAD AND
      the failures are not in the `KNOWN_BROKEN` allowlist, escalate
      via `bash bin/pipeline.sh event ENG-77 verdict halt --reason
      agent-blocked` with a one-line description of which test
      failed; do NOT attempt to "fix" unrelated test breakage in
      this PR.

### Task 3: Post the implement-stage TDD-evidence + stage-summary

- `depends_on: [1, 2]`
- `touches: $(issue_dir ENG-77)/stage-summary-implementing.md (write); Linear comment add-or-update-comment "tdd-evidence/implement/ENG-77" ENG-77`
- [ ] Write the stage summary file at
      `$(issue_dir ENG-77)/stage-summary-implementing.md` (per the §3
      Implement Output bullet at `AGENT_PROMPTS.md:665`). For the
      harness-self target this resolves to
      `$PROJECT_STATE_DIR/ENG-77/stage-summary-implementing.md`,
      which on this operator's machine is
      `/Users/rajatgoyal/.local/state/twinning-harness/harness/ENG-77/stage-summary-implementing.md`
      (the trailing `harness/` segment is `$PROJECT_SLUG`, frozen at
      first setup per CLAUDE.md "Three locations every script
      touches" §). The dispatched agent receives this path via the
      `{stage_summary_path}` template substitution at
      `bin/render-prompt.sh` time — do NOT hand-construct the path;
      use the substituted value. Per the §3 Stage-specific slots,
      include:
  - **Artifact link:** branch-compare URL
    `https://github.com/<owner>/<repo>/compare/main...feat/eng-77-…`
    AND a link to the plan doc on this branch.
  - **TL;DR:** one sentence stating that the §5 prompt mandate +
    test asserts already shipped via PR #61 (commit `bd8ca2d`) and
    the implement stage on this branch produced no new code change.
  - **Status line (clean gate):** literal —
    `0 commits · +0 test / +0 src · api-contract: n/a · gates green
    · proceeding to ui`. (Zero commits because the shipped commit
    `bd8ca2d` predates this branch's HEAD; the plan-doc commit is
    counted under the planning stage, not implementing.)
  - **Notes:** explicitly call out the unusual SDLC topology per
    brainstorm O-5 — the brainstorm runs on `feat/eng-77-…` but the
    fix shipped on `fix/eng-71-followup-…` via PR #61. The two
    branches converge on `main`; `bd8ca2d` is in this worktree's
    history via the merge. Also surface the two PENDING live-verify
    items from brainstorm §11 (operator-driven; not blocking the
    implement-stage verdict per Task 4 below).
- [ ] Post the implement-stage TDD-evidence comment using the §3
      Output bullet's contract (`bash bin/linear.sh add-or-update-
      comment "tdd-evidence/implement/{issue_id}" {issue_id} --body -
      <<'EOF' … EOF`). For harness-self the script lives at
      `bin/linear.sh` (no `.pipeline/` prefix — the `.pipeline/`
      shape applies only when the harness is vendored inside a
      target repo). The body MUST be piped via stdin using
      `--body -` and a quoted heredoc (`<<'EOF'`) per ENG-55; do NOT
      inline the body as a `bash bin/...` argument. Body content
      (TDD evidence) — commits added: 0; test changes: 0; src
      changes: 0; per-task SHA matrix: Task 1 verified at HEAD;
      Task 2 test suite green; explicit deviation: this implement
      stage produces no new code because the fix shipped on main as
      `bd8ca2d` via PR #61 prior to ENG-77's brainstorm/plan/
      implement chain on `feat/eng-77-…`.
- [ ] Confirm by reading the Linear comment thread that the new
      comment carries sig `<!-- meta: dedup key=tdd-evidence/implement/ENG-77 -->`
      (idempotent — re-running the same call upserts in place per
      A-007's `add_or_update_comment` semantics). Sig MUST be the
      verbatim `tdd-evidence/implement/ENG-77` string; do NOT
      mutate it (per ENG-57 / the global no-probe paragraph).

### Task 4: Emit the implement-stage verdict-pass marker

- `depends_on: [3]`
- `touches: Linear append-only comment via bin/pipeline.sh`
- [ ] Run exactly:

```bash
bash bin/pipeline.sh event ENG-77 verdict pass --stage implementing
```

  This validates `pass` against the `verdict_results` registry at
  `bin/pipeline-events.json:3-9` and `implementing` against the
  `stages` list, then posts the verdict marker via
  `bin/linear.sh add-comment`. Do NOT touch `pipeline:halted` —
  per CLAUDE.md "When wiring a new script" §, the orchestrator
  applies it after dispatch (ENG-56 contract).
- [ ] If the live-verify items in §11 of the brainstorm
      (Acceptance — operator-driven E2E checks) are still PENDING,
      include a one-line note in the TDD-evidence body (Task 3)
      stating that the static guardrail is GREEN but the live
      operator verification on a future review-loopback dispatch
      has not yet completed. Do NOT halt for live-verify — the
      brainstorm's §9 Feasibility persona explicitly carved this
      out as "PASS on static surface only" with the live-verify
      gates as separate-ticket follow-ups.

## Frontend Tasks

(no UI surface in this repo; the harness contains only bash
orchestration scripts per the project profile addendum's "Stack" §)

## Failure Mode → Test Map

| Failure mode | Trigger | Expected behavior | Test layer | Test name |
|---|---|---|---|---|
| Reviewer agent skips the `Write` on a loopback re-entry (the original ENG-71 cycle, iters 6-9) | Reviewer dispatch where prior `stage-summary-reviewing.md` exists on disk and findings appear "unchanged" | Agent rewrites the file with current-iter content; orchestrator's `post_completion_comment` posts a fresh body to Linear; implement agent on next loopback reads fresh feedback | unit (content) | `bin/agent-prompts-content-test.sh` §5 invariants block — assert "§5 mandates 'overwrite on every dispatch' for the stage-summary file" (line 211) |
| Future prompt-cleanup PR replaces "overwrite on every dispatch" with a synonym (e.g. "always rewrite") that drops the matchable phrase | Edit to `AGENT_PROMPTS.md:1027-1039` removing the regex-matched literal | Test fails: `nope "§5 mandates 'overwrite on every dispatch' for the stage-summary file"` | unit (content) | `bin/agent-prompts-content-test.sh` line 211 (regex `overwrite[ d]+on every dispatch`) |
| Future prompt-cleanup PR drops the explicit "read-then-conditionally-skip" carve-out | Edit to `AGENT_PROMPTS.md:1029` removing the literal phrase | Test fails: `nope "§5 explicitly bans 'read-then-conditionally-skip'"` | unit (content) | `bin/agent-prompts-content-test.sh` line 221 (literal `grep -qF 'read-then-conditionally-skip'`) |
| Future prompt-cleanup PR strips the ENG-71 named-incident citation | Edit to `AGENT_PROMPTS.md:1035` removing `ENG-71` and the May/2026 token | Test fails: `nope "§5 cites the ENG-71 incident"` | unit (content) | `bin/agent-prompts-content-test.sh` line 230 (regex `ENG-71.*(May\|2026)`) |
| §5 fenced block is corrupted (new column-0 ``` fence introduced inside the body) | Edit that adds a column-0 ``` fence in §5 between the heading and the closing fence | `bin/render-prompt.sh::extract_block` dies on fence-count != 2; render-prompt-test catches the regression at suite time | unit (structural) | `bin/render-prompt-test.sh` (whole-file fence-count test, per CLAUDE.md "AGENT_PROMPTS.md is load-bearing" §) — covers all 9 stage sections including §5 |
| Build (§7) wait-budget loop somehow inherits a stale stage-summary file | Build wait-exit at `bin/run-stage.sh:495-497` fails to clear the file | Build's `_handle_wait` clear at line 497 prevents this; verified-fact A-004 | integration | existing `bin/run-stage-test.sh` `_handle_wait` cases (no new test — the property is `rm -f` followed by no rewrite, structurally immune per brainstorm §6 forensic note) |
| Implement agent on review-loopback reads a stale `completion/reviewing/<issue>` Linear comment because the file was not rewritten | Reviewer fails to obey D-001 | Captured by D-002's three asserts at content-test time; if the asserts pass, the prompt mandate is in place; if the agent ignores the prompt, this is the D-004 un-deferral trigger | (unit content) covers prompt presence; D-004 (deferred) would cover runtime enforcement | n/a — runtime enforcement is the deferred work tracked under D-004; the un-deferral preconditions are documented in the brainstorm §4 D-004 |
| §3 (Implement) or §4 (UI) silently exhibits the same read-then-skip on their own stage-summary file (architectural exposure exists per A-005) | Implement / UI agent reads existing `stage-summary-implementing.md` / `stage-summary-ui.md` and decides to skip the Write | Not currently caught — D-003 explicitly defers generalisation. One observed instance is the un-deferral trigger | (deferred — no test today) | n/a — un-deferral preconditions are in brainstorm §4 D-003 |
| `bin/linear.sh::add_or_update_comment` regression breaks the footer-only re-apply path that D-001's "covers visibility" language relies on | Edit to `bin/linear.sh:582-606` that drops the reapplied footer | D-001's "re-write the same content" guarantee fails open: identical-body re-applies become invisible to operators | unit | existing `bin/linear-test.sh` `add_or_update_comment` cases (covers the ENG-63 fix; no new test by this plan) |
| Operator-resume `decide --action continue` accidentally drains the agent-emitted stage-summary file | `bin/pipeline.sh::_pipeline_drain_issue_state` overreaches | Today's behavior preserves `stage-summary-<stage>.md` (drain only touches `issue-state.json` when `.policy == "skip-until-human-acts"`, plus the labels and waypoint comment); ENG-77 does not change this | integration | existing `bin/pipeline-test.sh` `_pipeline_drain_issue_state` cases — no new test |

## Test Strategy

### Unit (content tests — already shipped, must remain green)

`bin/agent-prompts-content-test.sh` is the guard. The pre-commit
hook runs the full `bin/*-test.sh` suite (per CLAUDE.md "Pre-commit
hook" §). The implement stage on this branch does NOT add any new
test cases — D-002's three asserts at lines 197-235 already pin the
contract per A-002. The implement agent's Task 2 re-runs the suite
to confirm the 94/0 outcome documented in the shipped commit's body
is still green at this branch's HEAD.

### Unit (structural — fence-count regression net)

`bin/render-prompt-test.sh` catches column-0 fence-count regressions
across all 9 stage sections (per CLAUDE.md "AGENT_PROMPTS.md is
load-bearing" §). Brainstorm EC-7 records that D-001's edit lands
inside §5's existing fenced block; verified at A-013. Implement
Task 1 re-runs `bash bin/render-prompt.sh reviewing` to confirm the
fence-extraction succeeds on the current HEAD.

### Integration (full pre-commit suite)

The pre-commit hook gates every commit on `bin/*-test.sh`. Implement
Task 2 runs the suite and confirms green status. KNOWN_BROKEN
allowlist entries are not regressed by this PR (no `bin/run-stage.sh`,
`bin/dispatch.sh`, or other touched orchestration files).

### Smoke / E2E (deferred — operator-driven)

Two operator-driven smoke checks track from the Linear issue's "Test
plan" section, both still PENDING per brainstorm §11:

1. Live verify on ENG-71: delete the stale
   `stage-summary-reviewing.md`, run `bash bin/pipeline.sh decide
   ENG-71 --action continue`, observe whether the next reviewer
   dispatch rewrites the file from scratch with current findings.
   The implement agent on `feat/eng-77-…` cannot itself perform this
   verification (it requires a real Anthropic dispatch + operator
   action on a different issue's worktree). Operator-tracked.
2. Live verify on the next review-loopback issue (any future): the
   summary file refreshes on every dispatch, even when findings are
   unchanged. Same constraint — operator-tracked.

Brainstorm §11 explicitly marks "Static gates GREEN; live-verify
gates PENDING" and §9 Feasibility verdict is "PASS on static
surface only". Implement Task 3 surfaces this in the stage-summary
Notes block.

### Adversarial coverage (already in Failure Mode → Test Map)

The three D-002 asserts each lock a different regression class:
phrase regression (Failure Mode row 2), carve-out regression (row
3), citation regression (row 4). The brainstorm's §7 E-6 considered
the "false-positive negative-example paragraph" risk and concluded
the three-assert overlap makes that scenario implausible (a
negative-example paragraph would have to embed all three pinned
phrases inside the §5 fenced block, which is structurally
implausible).

### Out-of-scope tests (deferred per brainstorm)

- **D-004's runtime enforcement test** (e.g., a `run-stage-test.sh`
  fixture that proves the orchestrator detects an absent Write).
  Deferred. Brainstorm §4 D-004 records the un-deferral
  preconditions including the security precondition.
- **D-005's typed-findings parser test** (e.g., a test that the
  closed `meta_kinds` registry rejects unrecognised kinds at the
  validator). Deferred. Brainstorm §4 D-005 records the un-deferral
  preconditions including the schema design precondition.
- **D-003's §§3, 4 generalisation tests** (e.g., copies of D-002's
  three asserts pinned to §3 and §4 invariants blocks). Deferred.
  Brainstorm §4 D-003 records the un-deferral preconditions (one
  observed instance of an implement-stage or UI-stage read-then-skip
  is the trigger).
- **O-6 detection signal test** (e.g., a `status.sh` test that
  surfaces issues whose `stage-summary-<stage>.md` mtime regressed
  across consecutive dispatches). Deferred. Brainstorm O-6
  recommends filing as a separate Linear issue.

## Self-review

Personas — feasibility, scope, coherence, design, product — will be
run via `compound-engineering:document-review` after the draft is
committed. Required gate: 4/5 PASS, zero P0 findings (codebase-fact
errors, malformed API contract block, missing `depends_on`/`touches`
metadata, unbound Failure Mode rows, File Structure entries
feasibility cannot locate or justify as new). Iterate at most 3
times.
