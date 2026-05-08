---
linear: ENG-66
title: Transcript-based runtime defense for banned branch-creation forms (`git checkout -b`/`-B`, `git branch -m`, `git switch -c`)
date: 2026-05-08
status: draft
---

# Transcript-based runtime defense for banned branch-creation forms

## 1. Overview

PR #48 (commit `4635cd3`, May 2026) added a prompt-level "Branch-name
convention" section in `AGENT_PROMPTS.md` after the ENG-63/64/65
incident: three implementing-stage dispatches halted because agents
created `feature/eng-N-…` branches via `git checkout -B` instead of
using the canonical `feat/eng-N-…` the orchestrator had already
substituted as `{branch_name}`. The prompt now lists the four banned
branch-creation forms explicitly (`git checkout -b`, `git checkout -B`,
`git branch -m`, `git switch -c`) at `AGENT_PROMPTS.md:86`, with a
content-test pin in `bin/agent-prompts-content-test.sh:505` that
fails the pre-commit hook if any of the four phrases is dropped.

Prompt instructions can be ignored. The harness already operates a
runtime-defense pattern for an analogous class — ENG-43's
`bin/dispatch.sh::assert_no_tool_invocation` (verified at
`bin/dispatch.sh:48-65`) detects `gh pr create` in the agent's
stream-json transcript and halts with exit 22 →
`pr-opened-too-early`. ENG-71 generalised that to a per-stage loop
(four forbidden git-mutation patterns at the build stage, exit 26 →
`worktree-mutation-forbidden`, verified at `bin/dispatch.sh:207-218`).
ENG-68 generalised it again to a **cross-stage** loop (five
`core.bare`-touching git forms, exit 13 → `lane-violation`, verified
at `bin/dispatch.sh:219-246`).

This ticket adds one more cross-stage loop in the same renderer
function: four banned branch-creation prefixes (`git checkout -b`,
`git checkout -B`, `git branch -m`, `git switch -c`), exit 23 →
`branch-creation-forbidden`, sidecar to
`${issue_dir}/.transcript-violation-${stage}`, halt with
`skip-until-human-acts` policy. Same plumbing the three predecessor
features established; no new infrastructure.

The load-bearing tradeoff: defense-in-depth duplicates the
prompt-level rule that already exists. The prompt is the primary
defense (cheaper to maintain, broader linguistic coverage); the
transcript assertion is a late-binding tripwire that fires when the
prompt is ignored or when a future prompt edit drops the rule. Cost
is four additional jq forks per dispatch (one per pattern in the
loop) — about 40 ms per dispatch against the 30-min watchdog cap and
the ~$1.50/dispatch claude cost.

## 2. Goals

After this ticket lands:

1. **Cross-stage transcript assertion** (D-002): every dispatched
   stage has its raw NDJSON transcript scanned for the four
   banned-branch-creation prefixes. On match: write the matched
   command to `${issue_dir}/.transcript-violation-${stage}`, log
   `[assert] stage=<stage> transcript invoked forbidden branch-creation
   form: <command>`, return exit code 23 from
   `_render_and_capture_stream`.
2. **`run-stage.sh` exit-code routing** (D-004): `dispatch_rc == 23`
   reads the sidecar, calls `classify_failure ... skip-until-human-acts
   "agent transcript invoked forbidden branch-creation form: <command>"
   23`, removes the sidecar, exits 23. Operator unblocks via the
   standard `bash bin/pipeline.sh decide ENG-N --action continue` after
   investigating.
3. **Exit-code taxonomy** (D-005): `bin/common.sh::failure_outcome_for_exit`
   gains `23) printf 'branch-creation-forbidden' ;;` between existing
   slots `22` and `24` (the 23 slot is currently unused — verified at
   `bin/common.sh:111-136`). `bin/run-stage.sh:4-11` exit-code header
   lists `23=branch-creation-forbidden`.
4. **Test pinning** (D-006): `bin/dispatch-test.sh` gains BC1-BC8
   fixtures (4 positives — one per pattern; 1 negative —
   `git checkout {branch_name}` permitted; 1 chained-command bypass
   pinning the inherited `startswith` blind spot; 1 renderer-integration
   end-to-end on stage `implementing`; 1 cross-stage gating fixture
   confirming the loop fires on stage `qa` too — i.e. NOT stage-gated).
   `bin/classify-failure-test.sh` gains a Test 18 mirror of Test 15
   (existing ENG-71 entry pin) for exit 23. Both follow the existing
   AS-block / Test-15 patterns verbatim.

Non-goals (explicit, follow the issue's "Scope" framing):

- **Adding a separate `assert_no_branch_creation` helper.** The issue
  text mentions either "or a multi-prefix version of
  `assert_no_tool_invocation`" — the existing helper already accepts a
  literal pattern and a transcript path, and the cross-stage `core.bare`
  loop at `bin/dispatch.sh:232-246` is the established precedent for
  looping over multiple patterns. Adding a new wrapper helper would
  duplicate boilerplate without adding signal. **O-1**: if a fourth
  call site materialises with a *different* pattern shape (e.g. regex,
  substring), refactor then.
- **Catching chained-command bypass** (`git status && git checkout -b
  foo`). Inherited from ENG-43/71's startswith blind spot
  (`bin/dispatch.sh:50` filter uses `startswith($p)`). The chained
  command's `.input.command` starts with `git status`, not
  `git checkout -b`, so the matcher does not fire. **O-2**: same
  followup as ENG-71 O-4 (substring-match upgrade). For now, the
  prompt rule + content test plus this prefix-match check are the
  load-bearing surfaces.
- **Catching the long-flag aliases** (`git switch --create`,
  `git branch --move`, `git checkout --branch`). The issue enumerates
  exactly four short-flag forms; the prompt rule mirrors that
  enumeration. **O-3**: if a retrospective shows agents drifting to
  long-flag aliases, extend the pattern table. For now, the
  short-flag forms are the demonstrated incident surface.
- **A separate post-dispatch state-of-the-world detector for branch
  drift** (mirror of ENG-71's D-003 HEAD-detect). Branch creation
  is symmetric: if the agent created `feature/eng-N-foo`, the
  expected `{branch_name}` is `feat/eng-N-foo` and a `git -C $wt
  rev-parse --abbrev-ref HEAD` mismatch would be detectable. But
  the agent that ran `git checkout -B feature/eng-N-foo` left the
  worktree on `feature/eng-N-foo` — exit 23 surfaces that
  fact via the matched-command sidecar; the operator's recovery
  recipe is "delete the wrong-named branch, ensure the right one
  exists, run `--action continue`." Adding a state-detector would
  duplicate the operator-facing surface without changing the
  recovery path. **O-4**: revisit if metric volume on
  `branch-creation-forbidden` reveals chained-command bypasses
  that escape D-002. For now, D-002 plus the existing scope-check
  cascade are sufficient.

## 3. Architectural principle

The repo has no `docs/VISION.md`, no `docs/ARCHITECTURE.md`, no
`docs/knowledge/decisions.md` (verified by listing `docs/` — only
`brainstorms/`, `runbooks/`, `pipeline-vocabulary.md`, and
`pipeline-vocabulary.template.md` are present). Governing
constraints come from `CLAUDE.md`, `learned-rules/harness/project-profile.md`,
and accepted brainstorms.

Principles invoked here are existing CLAUDE.md commitments, not
new ones:

- **Defense-in-depth on top of tool-lane denials and prompt rules.**
  `CLAUDE.md` "When wiring a new script" §:
  > *Defense-in-depth on top of tool-lane denials: when a stage's
  > contract says "agent must not invoke tool X," prefer a
  > transcript-based assertion (`assert_no_tool_invocation` in
  > `bin/dispatch.sh`) over a state-of-the-world check after dispatch.
  > State checks false-positive on actions taken by other actors
  > (humans, prior stages, future agents); transcript checks answer
  > the contract question directly. Today only the implement stage
  > uses this pattern (forbidding `gh pr create`); generalising to
  > other stages is a separate refactor.*

  This brainstorm is exactly that "separate refactor" continuing
  the ENG-71 (build-stage) and ENG-68 (cross-stage `core.bare`)
  generalisation. The contract question is "did the agent invoke a
  branch-creation verb that contradicts the prompt's MANDATORY
  rule?" — directly answered by the transcript scan.

- **One sidecar path per stage; one exit code per failure class.**
  ENG-43 D-008 (sidecar at `${issue_dir}/.transcript-violation-${stage}`)
  is reused verbatim by ENG-71 (rc=26), ENG-68 (rc=13), and now
  ENG-66 (rc=23). The single sidecar path is safe because each
  dispatch produces at most one violation (the renderer returns on
  first match and the sidecar is pre-cleaned at function entry,
  verified at `bin/dispatch.sh:98`). Each new failure class gets a
  fresh exit code so retrospective filtering and operator runbooks
  can disambiguate (verified: 22, 26, 13 each map to a distinct
  outcome at `bin/common.sh:127, 130, 123`). Slot 23 is currently
  unused and is the next ascending number per the existing pattern.

- **Cross-stage scan is the right shape.** The issue's scope item 2
  reads "Apply across **all** stages — branch-name drift can land from
  any stage that has Bash(git:\*) in its allow-list." Verified
  against `bin/dispatch.sh:301-308`: implementing, ui, qa stages
  all have wide `Bash(git*:*)` permissions in their base allowlists.
  The brainstorm has no stage-gate around the new loop, mirroring
  ENG-68's `core.bare` block at `bin/dispatch.sh:232-246`.

- **Symmetric prompt / transcript pattern set.** ENG-62's Bld-001
  rule (mentioned in `learned-rules/harness/build.md` per ENG-71
  brainstorm) and ENG-71 D-001 + D-002 set the precedent: when a
  prompt rule names N forbidden patterns, the orchestrator-side
  detector should scan for the same N patterns. The prompt at
  `AGENT_PROMPTS.md:86` and `:582` enumerates *exactly* four forms;
  the dispatch-side loop and `bin/agent-prompts-content-test.sh:505`
  list the same four. A future contributor who adds a fifth pattern
  to the prompt updates both sites, or fails the symmetric
  content-test pin (D-006 §3 below).

- **Sentinel + source-and-stub for new test invariants.** `CLAUDE.md`
  "Tests" §: *"When a new bash file is meant to be both executable
  and unit-testable, replicate the sentinel pattern."* `bin/dispatch.sh`
  and `bin/common.sh` both already carry the sentinel; this brainstorm
  edits functions inside them, leaving sentinels intact. New test
  fixtures in `bin/dispatch-test.sh` and `bin/classify-failure-test.sh`
  follow existing source-and-stub layout.

## 4. Decisions

### D-001 — Reuse the existing `assert_no_tool_invocation` helper; loop over four patterns

**Verdict.** Add a new block to `bin/dispatch.sh::_render_and_capture_stream`,
between the existing ENG-71 building-stage block (line 218) and the
ENG-68 cross-stage `core.bare` block (line 232). The block iterates
over four literal prefixes and calls the existing
`assert_no_tool_invocation` helper for each, mirroring ENG-68's loop
shape verbatim:

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

**Why.** Direct fix for AC1 ("New `assert_no_branch_creation` (or a
multi-prefix version of `assert_no_tool_invocation`) in `bin/dispatch.sh`
that scans the raw stream NDJSON for the four banned forms"). The
issue's "or" clause permits reusing the multi-prefix loop pattern;
ENG-68 already established it for cross-stage scans, and ENG-71
established it for per-stage scans. Adding a wrapper helper named
`assert_no_branch_creation` would duplicate the loop in a one-line
function for no reader benefit; the inline loop with four literal
strings is precisely as discoverable.

**Rejected alternative — add a new `assert_no_branch_creation` helper
function.** Slightly more semantic at the call site. But:
- The helper would do nothing the loop does not already do.
- The loop's pattern enumeration IS the documentation; hiding it
  behind a function name diverges the prompt rule from the
  dispatch-side check (the prompt enumerates four strings; the
  dispatch code would enumerate four strings inside a helper, and
  the call site would just say "no branch creation" without the
  list). ENG-62 Bld-001 discipline ("symmetric query / pattern shape")
  argues against this divergence.
- ENG-68's `core.bare` loop chose the same shape (five literal
  patterns inline) and is the canonical precedent.
- AC1's "or a multi-prefix version" wording explicitly permits this
  shape.

Rejected.

**Rejected alternative — single jq fork that matches all four
patterns at once.** A modified helper variant that takes an array
of patterns and runs one jq with `any(startswith(...))` over them
would reduce four jq forks to one. But:
- Refactoring `assert_no_tool_invocation` to accept an array changes
  three existing call sites (ENG-43 implement, ENG-71 build, ENG-68
  cross-stage) — wider blast radius than the issue asks for.
- Per-pattern `head -1` semantics gives the operator the FIRST
  matching command in the loop's declared order. Combining patterns
  loses that ordering; the operator-facing diagnostic becomes "one of
  these four patterns matched" instead of "this exact command matched."
- Cost: 4 jq forks × ~10 ms = ~40 ms per dispatch, well below the
  watchdog cap (30 min) and below the noise threshold of a typical
  dispatch (~10–60 s for an interactive stage). ENG-71 D-002 audited
  the same calculus and reached the same conclusion.

Rejected.

### D-002 — Cross-stage scan: no `if [[ "$stage" == ... ]]` gate

**Verdict.** The new loop runs on **every** dispatched stage. No
stage gate. Mirrors ENG-68's `core.bare` block at
`bin/dispatch.sh:232-246`, which is also cross-stage with a comment
calling that out explicitly:
> *D-003: forbid `core.bare`-touching git forms across ALL stages.
> Defense-in-depth on top of D-002 (the implementing/ui base allowlist
> no longer carries Bash(git:*)). Catches future allowlist drift on
> any stage AND covers stages whose base allowlist still has wide
> Bash(git:*) (qa).*

**Why.** AC2 ("Apply across **all** stages — branch-name drift can
land from any stage that has Bash(git:\*) in its allow-list").
Verified against `bin/dispatch.sh::allowed_tools_for`:
- `implementing` carries `Bash(git checkout:*)`, `Bash(git switch:*)`,
  `Bash(git branch:*)` (line 301).
- `ui` carries the same set (line 302).
- `qa` carries `Bash(git:*)` (broad), line 304.
- `building` carries only fetch/clone/rebase (line 305) — but the
  ENG-71 building-stage loop covers `git checkout`/`switch`/`pull`/
  `reset`. Non-overlapping with the four ENG-66 patterns at the
  startswith level: `git checkout -b foo` starts with `git checkout`
  (an ENG-71 pattern) AND with `git checkout -b` (an ENG-66 pattern).
  See D-006 below for the ordering rationale that decides which
  fires first.
- `brainstorming`, `planning`, `reviewing`, `released`,
  `retrospective` have NO `Bash(git checkout:*)` etc. in their base
  allowlists — but tool-lane bypass is exactly the failure mode
  ENG-43/71/68 demonstrated, and the cross-stage scan defends
  against future drift on those stages too.

**Rejected alternative — gate on the four "git-rich" stages
(`implementing`, `ui`, `qa`, `building`) only.** Reduces jq forks on
brainstorm/plan/review/retrospective dispatches (saves ~40 ms × 4
stages × ~50 dispatches/week ≈ 8 s/week — negligible).
- Cost asymmetry: even on stages whose base allowlist excludes
  `Bash(git:*)`, a future configuration change (a per-target
  `dispatch.tools.<stage>` extension at `bin/dispatch.sh:268-277`)
  could grant the verb. Stage-gating now bakes today's allowlist
  into the defense, defeating the "future drift" rationale that's
  the whole point of defense-in-depth.
- ENG-68's choice was cross-stage for exactly this reason.

Rejected.

### D-003 — Pattern set: four literal prefixes, matching the prompt and content-test verbatim

**Verdict.** The four patterns are exactly:
1. `git checkout -b`
2. `git checkout -B`
3. `git branch -m`
4. `git switch -c`

These mirror `AGENT_PROMPTS.md:86` and the existing
`bin/agent-prompts-content-test.sh:505` enumeration verbatim.

**Why.** AC1 lists exactly these four patterns. ENG-62 Bld-001
discipline ("symmetric query / pattern shape between prompt and
orchestrator"): the prompt enumerates four literal forms; the
content test pins those four forms; the dispatch loop scans for
the same four forms. A future contributor adding `git switch
--create` to the prompt updates the loop too, OR adds it only to
the prompt and the content-test passes (the four short-flag forms
are still pinned) — but the dispatch loop fails to fire on the new
pattern. Surface that discrepancy in a follow-up; for v1, exact
parity with the prompt enumeration is the contract.

**Rejected alternative — broader pattern `git checkout -` (single
hyphen) to catch both `-b` and `-B` in one entry.** Saves one
jq fork (3 patterns × 10 ms = 30 ms instead of 40 ms).
- Over-broad: matches `git checkout --` (which is a legitimate way
  to discard worktree changes — `git checkout -- path/to/file`).
  False-positive failure risk.
- Asymmetric with the prompt rule, which lists `-b` and `-B`
  separately.

Rejected.

**Rejected alternative — long-flag aliases included** (`git switch
--create`, `git branch --move`, `git branch --rename`,
`git checkout --branch`). All semantically equivalent to the
short-flag forms.
- AC1 lists exactly the four short-flag forms; the issue's title
  even includes the four short forms in the slug.
- The May-2026 incident (ENG-63/64/65) was specifically the
  short-flag form (`git checkout -B feature/eng-N-…`).
- Adding long-flag aliases without an observed failure mode is
  speculative scope.
- O-3 captures the followup if a future incident shows long-flag
  drift.

Rejected.

**Rejected alternative — also include `git worktree add` (which
implicitly creates a branch).** `git worktree add` is the
orchestrator's own mechanism (called from `bin/run-local.sh`) and
is not in any agent stage's allowlist. Including it in the
forbidden list would never fire on a real agent invocation but
would fire if the orchestrator ever tried to delegate worktree
creation to an agent — which is itself a design constraint we
should not paper over with a transcript check.

Rejected.

### D-004 — Match-failure surface: exit 23, `skip-until-human-acts`, reason text preserved

**Verdict.** `bin/run-stage.sh` adds an `elif (( dispatch_rc == 23 ))`
branch BEFORE the existing `dispatch_rc == 26` branch (line 772 in
the current file). Concrete shape (mirror of the rc=22 / rc=26 / rc=13
branches):

```bash
elif (( dispatch_rc == 23 )); then
  # ENG-66: agent transcript invoked one of the four banned
  # branch-creation forms (git checkout -b/-B, git branch -m,
  # git switch -c). The orchestrator owns the worktree's branch;
  # this is a hard halt — the operator must investigate before
  # the next dispatch.
  local _viol_file_23 _viol_cmd_23
  _viol_file_23="$(issue_dir "$ident")/.transcript-violation-${stage}"
  _viol_cmd_23="$(cat "$_viol_file_23" 2>/dev/null || printf '<command-unavailable>')"
  classify_failure "$ident" "$stage" "skip-until-human-acts" \
    "agent transcript invoked forbidden branch-creation form: $_viol_cmd_23" 23
  rm -f "$_viol_file_23" "$prompt_file"
  exit 23
```

`bin/common.sh::failure_outcome_for_exit` adds `23) printf
'branch-creation-forbidden' ;;` between existing slots `22` and
`24` (verified slot is unused at `bin/common.sh:127-128`).

`bin/run-stage.sh:4-11` exit-code header docstring lists
`23=branch-creation-forbidden` between `22=pr-opened-too-early`
and `26=worktree-mutation-forbidden` (verified the docstring
exists and lists each rc with its outcome).

**Why.** AC2 ("On hit: write the matched command to a sidecar like
`$issue_dir/.transcript-violation-<stage>` (mirroring the ENG-43
pattern) and return a fresh exit code (e.g. `23 →
branch-creation-forbidden`)") and AC3 (`classify-failure.sh` routes
to `skip-until-human-acts`). This is the canonical
`skip-until-human-acts` shape used by the three predecessor
features:
- ENG-43 → exit 22 → `pr-opened-too-early`
- ENG-71 → exit 26 → `worktree-mutation-forbidden`
- ENG-68 → exit 13 → `lane-violation`
- ENG-66 → exit 23 → `branch-creation-forbidden` (this brainstorm)

Operator unblocks via the standard `bash bin/pipeline.sh decide
ENG-N --action continue` (verified at CLAUDE.md "What `--action
continue` clears" §). No new label, no new marker shape, no new
operator command.

**Rejected alternative — reuse exit code 26 (worktree-mutation-forbidden).**
ENG-71's rc=26 carries the English "agent mutated the worktree's
HEAD off `{branch_name}`." Branch creation IS a HEAD mutation
(creating a branch via `-b`/`-B`/`-c` switches HEAD to the new
branch), so the semantic overlap is real.
- But the operator-facing English of "worktree-mutation-forbidden"
  emphasises "the agent moved off the assigned branch"; the English
  of "branch-creation-forbidden" emphasises "the agent forked the
  branch namespace." These are distinct failure surfaces with
  distinct recovery actions:
  - rc=26 recovery: detach HEAD, ensure operator's main is unlocked
    (ENG-71 D-003).
  - rc=23 recovery: delete the wrong-named branch, ensure the
    canonical branch exists, run `--action continue`.
- The retrospective's §1 outcome filter classifies failures by
  exit code; sharing a code merges the two failure classes into
  one row, losing fidelity for the retrospective.
- Slot 23 is unused; the marginal cost of a new entry is one line in
  `failure_outcome_for_exit` plus one Test in `classify-failure-test.sh`.

Rejected.

**Rejected alternative — `retry-immediately` policy (lower-friction
recovery).** Branch creation might be a one-off agent slip; auto-retry
could repair without operator intervention.
- ENG-43/71/68 all chose `skip-until-human-acts` for transcript-assertion
  hits, on the rationale that a contract-violating agent has
  demonstrated drift the operator should inspect. Same logic
  applies here.
- The May-2026 incident showed the agent can REPEATEDLY create the
  same wrong branch on retry (the prompt fix was the load-bearing
  remedy). `retry-immediately` would loop until the per-issue
  failure counter (`tally_leaked_in_scope_failure` in
  `run-local-helpers.sh`) tripped at threshold 3 — three wasted
  dispatches and one halt vs. one dispatch and one halt today.

Rejected.

### D-005 — Sidecar location: existing `${issue_dir}/.transcript-violation-${stage}`

**Verdict.** Reuse the existing single-file path. ENG-43, ENG-71,
ENG-68 all write to the same sidecar; the renderer's pre-clean
at `bin/dispatch.sh:98` removes any stale file at function entry,
and on a clean dispatch no sidecar is written. ENG-66 writes to the
same path on its own match.

**Why.** Single-sidecar design was an explicit ENG-43 D-008
decision; ENG-71 / ENG-68 inherited it. Each dispatch produces at
most one violation (each branch in the renderer returns on first
match), so multi-violation collision is structurally impossible.
A future violation class that wants to share the path follows
the same pattern; if a hypothetical class wants to compose with
existing sidecars (write multiple), THAT is when the path schema
needs widening — out of scope here.

**Rejected alternative — distinct path per failure class** (e.g.
`${issue_dir}/.transcript-violation-${stage}-branch`). Trivially
adds isolation but introduces multi-path management for no
present-day benefit. The renderer returns on first match; the
single sidecar is sufficient.

Rejected.

### D-006 — Insertion point: between ENG-71 (line 218) and ENG-68 (line 232)

**Verdict.** The new loop is placed in `_render_and_capture_stream`
**after** the ENG-71 building-stage block and **before** the ENG-68
cross-stage `core.bare` block. The ordering matters when an agent
issues a command that matches BOTH ENG-71 and ENG-66 patterns
(only on the build stage; only for `git checkout -b` /
`git checkout -B` since `git switch -c` and `git branch -m` aren't
ENG-71 patterns):

| Command | ENG-71 match | ENG-66 match | First-match wins |
|---|---|---|---|
| `git checkout main` (build) | yes (`git checkout`) | no | rc=26 ✓ |
| `git checkout -b foo` (build) | yes (`git checkout`) | yes (`git checkout -b`) | **rc=26 with proposed ordering** |
| `git checkout -b foo` (implement) | n/a (stage gate) | yes | rc=23 |
| `git switch -c foo` (build) | yes (`git switch`) | yes (`git switch -c`) | **rc=26 with proposed ordering** |
| `git branch -m foo bar` (any stage) | n/a | yes | rc=23 |

So on the build stage, an agent that runs `git checkout -b foo`
gets diagnosed as `worktree-mutation-forbidden` (rc=26), not
`branch-creation-forbidden` (rc=23). That's acceptable because:
- The build-stage tool lane already excludes `Bash(git checkout:*)`
  (`bin/dispatch.sh:305`); a build agent invoking ANY `git checkout`
  is a contract violation, regardless of whether `-b` is present.
- ENG-71's `worktree-mutation-forbidden` English is correct in
  spirit ("the agent shouldn't be touching HEAD"); the more-specific
  "branch-creation-forbidden" English is a strict refinement.
  Operator recovery action is the same in both cases (`decide
  --action continue` after manual investigation).
- The retrospective sees an exit-26 metric for the build-stage
  collision instead of exit-23; the metric still fires.

**Why.** Two ordering options (ENG-66 first vs. ENG-71 first) are
both defensible. The chosen order (ENG-71 first) groups both
cross-stage scans (ENG-66 + ENG-68) at the bottom of the function,
which is cleaner code organisation:

```
_render_and_capture_stream:
  └ stream pipeline (existing)
  └ result-event extraction (existing)
  └ implementing-stage assert: gh pr create        (ENG-43, line 184-193)
  └ building-stage assert: git checkout/switch/pull/reset  (ENG-71, line 207-218)
  └ cross-stage assert: branch-creation forms      (ENG-66, NEW)
  └ cross-stage assert: core.bare forms            (ENG-68, line 219-246)
```

The block-after-block layout reads as: stage-specific scans first,
cross-stage scans grouped at the end. This matches the existing
file's organisation principle.

**Rejected alternative — ENG-66 BEFORE ENG-71 (more-specific
diagnostic wins).** Would surface `branch-creation-forbidden` on
the build-stage `git checkout -b foo` and `git switch -c foo`
collision cases (per the D-006 collision matrix above, all three
of `git checkout -b foo`, `git checkout -B foo`, `git switch -c foo`
match BOTH ENG-71 and ENG-66; only `git branch -m` is
ENG-66-exclusive on the build stage).
- Marginal benefit (operator recovery is identical either way; the
  matched command in the sidecar is unambiguous either way).
- Breaks the cross-stage-scans-grouped layout established by ENG-68.
- The chosen order makes ENG-71's English ("the agent shouldn't be
  touching HEAD") fire on every build-stage HEAD-mutating verb,
  including the four-ENG-66 subset; ENG-66 then exclusively
  carries the `branch-creation-forbidden` outcome on non-build
  stages, where the May-2026 incident actually originated.

Rejected.

**Rejected alternative — merge ENG-66 INTO the ENG-71 building
loop (i.e., add the four branch-creation patterns to the existing
build-stage loop).** Conceptually the simplest path.
- Loses the cross-stage requirement (AC2): the loop is gated
  `if [[ "$stage" == "building" ]]` and would not fire on
  implementing / ui / qa stages, which are the actual incident
  surface from ENG-63/64/65.
- The May-2026 incident was an *implementing*-stage agent that
  ran `git checkout -B feature/eng-N-…`, not a build-stage agent.

Rejected.

### D-007 — Test coverage: BC1-BC8 in dispatch-test.sh + Test 18 in classify-failure-test.sh

**Verdict.** Three test surfaces, mirrored on existing patterns:

1. **`bin/dispatch-test.sh`** — append a new "ENG-66" group after
   the existing CB1-CB8 block (line 1340). Eight fixtures (four
   positives, one negative, one chained-bypass, one renderer-integration,
   one cross-stage-fires-on-implement-too):

   - **BC1** — `git checkout -b feature/eng-99-foo` matches `git checkout -b`.
   - **BC2** — `git checkout -B feature/eng-99-foo` matches `git checkout -B` (issue AC3).
   - **BC3** — `git branch -m feature-eng-99` matches `git branch -m`.
   - **BC4** — `git switch -c feature/eng-99-foo` matches `git switch -c`.
   - **BC5** — `git checkout feat/eng-66-add-transcript-…` (no `-b`/`-B`) does NOT match any of the four (issue AC4).
   - **BC6** — `git status && git checkout -b feature/foo` (chained command) does NOT match (documents the inherited startswith blind spot per O-2; mirror of AS12).
   - **BC7** — renderer integration end-to-end: `_render_and_capture_stream` with `stage="implementing"` and a transcript containing `git checkout -B feature/eng-66-foo` returns rc=23, writes the sidecar, emits the `[assert] stage=implementing transcript invoked forbidden branch-creation form: …` log line. Mirror of AT1 (ENG-43) / AT6 (ENG-71) / CB7 (ENG-68).
   - **BC8** — cross-stage scan fires on `stage="qa"` (verifies D-002 has no stage gate). Same shape as BC7 but with `stage="qa"`; expect rc=23 and a sidecar at `${issue_dir}/.transcript-violation-qa`.

2. **`bin/classify-failure-test.sh`** — append a Test 18 mirror of
   the existing Test 15 (line 220, ENG-71 pin) for exit code 23:
   ```bash
   reset_state; reset_metrics
   classify_failure "ENG-914" "implementing" "skip-until-human-acts" "br" 23 ""
   outcome=$(latest_outcome)
   [[ "$outcome" == "branch-creation-forbidden" ]] \
     && pass_at "case-18 exit 23 → branch-creation-forbidden" \
     || fail_at "case-18" "outcome=$outcome"
   ```

3. **`bin/agent-prompts-content-test.sh`** — already pins the four
   prompt patterns at line 505. **No change needed.** AC5 names
   `bin/test-isolation-test.sh` as the place to pin the entry; D-008
   below explains the deviation.

**Why.** AC3 (positive fixture for `git checkout -B feature/eng-99-foo`),
AC4 (negative fixture for non-`-b`/`-B` `git checkout`), and AC5
(taxonomy entry pinned in a test). The BC-block letters are the
next available prefix following AS (ENG-43/71) and CB (ENG-68);
mnemonic: BC = "branch creation."

**Rejected alternative — only test the four positives** (BC1-BC4).
- Cheaper but doesn't pin the negative case (AC4) or the chained-
  command bypass (an inherited blind spot the operator must know
  about). BC5 + BC6 are cheap insurance against future refactors
  that broaden the matcher.

Rejected.

### D-008 — Pin `failure_outcome_for_exit 23` in `bin/classify-failure-test.sh`, NOT `bin/test-isolation-test.sh`

**Verdict.** The taxonomy-entry pin (AC5) goes in
`bin/classify-failure-test.sh` as Test 18, mirroring the existing
Test 15 (ENG-71's exit-26 pin) and Tests 11–14 (other exit codes).
**Deviation from the literal text of AC5**, which names
`bin/test-isolation-test.sh`.

**Why.** AC5 says: *"`bin/common.sh::failure_outcome_for_exit` adds
`23 → branch-creation-forbidden`; `bin/test-isolation-test.sh`
(or a new test) pins this entry."* The "or a new test" clause
permits the deviation. `bin/classify-failure-test.sh` is the
natural home for `classify_failure` taxonomy invariants, and
ENG-71 (the most recent precedent) already added Test 15 there for
its exit-26 entry — verified at `bin/classify-failure-test.sh:220-232`.
`bin/test-isolation-test.sh` (verified at the file's first 50
lines) is *"a regression test for the 2026-05-04 fixture-leak
incident"* — its concern is test-fixture isolation (mocks not
leaking between source-and-stub tests), not exit-code taxonomy.
Pinning the new entry there would be off-topic and would invite
future contributors to mistake the file's purpose.

**Why this matters.** A contributor who reads only AC5 and
implements it literally adds a test in the wrong file. Surfacing
the deviation in the brainstorm decisions makes the choice durable
and reviewable.

**Rejected alternative — pin in BOTH `classify-failure-test.sh`
AND `test-isolation-test.sh`.** Belt-and-braces. But duplication
costs tester attention; the single Test 18 is sufficient and
matches the precedent.

Rejected.

## 5. Architecture (where code goes)

| File | What changes | Decision |
|---|---|---|
| `bin/dispatch.sh::_render_and_capture_stream` (insert ~12 LOC after line 218) | new for-loop scanning the four branch-creation patterns, returns 23 on match | D-001, D-002, D-003 |
| `bin/common.sh::failure_outcome_for_exit` (1 line) | add `23) printf 'branch-creation-forbidden' ;;` between existing `22)` and `24)` (verified slot is unused at `bin/common.sh:127-128`) | D-005 |
| `bin/run-stage.sh:4-11` (1 line in header docstring) | add `23=branch-creation-forbidden` between `22=pr-opened-too-early` and `26=worktree-mutation-forbidden` | D-005 |
| `bin/run-stage.sh::main` (~10 LOC, mirror of existing rc=22 / rc=26 / rc=13 branches) | new `elif (( dispatch_rc == 23 )); then …` branch BEFORE the existing rc=26 branch (line 772); reads sidecar, calls `classify_failure ... skip-until-human-acts ... 23`, removes sidecar, exits 23 | D-004 |
| `bin/dispatch-test.sh` (append ~120 LOC after CB8 at line 1482) | BC1-BC8 fixtures (eight total): four positives + one negative + one chained-bypass + one renderer integration (stage=implementing) + one cross-stage gating (stage=qa fires) | D-006, D-007 |
| `bin/classify-failure-test.sh` (append ~10 LOC after Test 15 at line 232) | Test 18: pin `classify_failure ... 23 → branch-creation-forbidden` outcome via `latest_outcome` helper | D-007, D-008 |
| `docs/runbooks/recovery.md` (append a small "branch-creation-forbidden" subsection — **mandatory**, not optional, per product-P1-1/P1-2 fold) | add a section that (a) names the new exit code 23 / outcome string, (b) gives the operator the manual-cleanup recipe (`git -C $(issue_dir <issue>)/worktree branch -D <wrong-name>; git -C $wt status` to confirm `{branch_name}` is on HEAD), THEN `bash bin/pipeline.sh decide <issue> --action continue`, and (c) notes that on the build stage, an `rc=26 worktree-mutation-forbidden` halt whose sidecar shows a `-b`/`-B`/`-c` form should be treated as a branch-creation cleanup (D-006 collision case). This is the FIRST halt class whose recovery requires a manual filesystem step before `--action continue` succeeds; rc=22/26/13 all leave `--action continue` standalone-sufficient. Surfacing the asymmetry is what makes this row mandatory. | D-004 (companion) |

No other files change. Notably:

- **No `AGENT_PROMPTS.md` changes.** PR #48 already added the
  prompt rule; ENG-66 is the runtime defense, not the prompt edit.
- **No `bin/agent-prompts-content-test.sh` changes.** PR #48 already
  pinned the four patterns at line 505.
- **No `bin/dispatch.sh::allowed_tools_for` changes.** The implement /
  ui / qa stages legitimately have `Bash(git checkout:*)` etc. for
  benign uses (`git checkout {branch_name}` to recover from a tool
  moving HEAD; `git checkout path/to/file` to discard changes). The
  bug is the agent invoking the *banned forms* of those verbs, not
  the verbs themselves.
- **No new `disallowed_platform_tools` entries.** The forbidden
  patterns are git subcommands, not Claude platform tools.
- **No new metrics events.** `classify_failure` already emits a
  `stage-end` metric with the resolved outcome
  (`branch-creation-forbidden`); the retrospective's §1 filter
  picks it up via `failure_outcome_for_exit 23`.
- **No new operator runbook beyond the row in `recovery.md`** (and
  the row is optional — the existing `--action continue` recipe
  applies cleanly to this halt class).

## 6. Data flow

The happy-path data flow is unchanged: a clean dispatch produces no
sidecar, the renderer returns 0, `run-stage.sh` proceeds to its
existing scope-check / completion branches.

The new violation-path data flow:

```
run-stage.sh main()
  → dispatch.sh main()
    → _render_and_capture_stream()
      → [stream pipeline tee + jq]                                  (existing, unchanged)
      → [result-event extraction → usage-<stage>.json]               (existing, unchanged)
      → [implementing-stage: gh pr create assertion]                 (existing, ENG-43, unchanged)
      → [building-stage: 4 patterns: checkout/switch/pull/reset]     (existing, ENG-71, unchanged)
      → [cross-stage: 4 patterns: -b / -B / branch -m / switch -c]   (NEW, D-001/D-002/D-003)
        → match? → write $violation_file → return 23
      → [cross-stage: 5 patterns: core.bare forms]                   (existing, ENG-68, unchanged)
    → return 23 (NEW exit code)
  → run-stage.sh: dispatch_rc=23
    → classify_failure ... skip-until-human-acts ... 23              (NEW routing, D-004)
    → exit 23
```

`classify-failure.sh` then:
1. Writes `issue-state.json` with `policy=skip-until-human-acts`.
2. Adds `pipeline:halted` and `pipeline:skip-until-human-acts`
   labels via `bin/linear.sh add-label`.
3. Emits a halt comment via `bash bin/linear.sh add-or-update-comment`
   under sig `halt/<stage>/<issue>` (the existing dedup signature).
4. Emits a `stage-end` metric with `outcome=branch-creation-forbidden`
   and `notes` containing the matched command (verified at
   `bin/classify-failure.sh:175-185`).

Operator unblock recipe: read the halt comment (it carries the
matched command), inspect the worktree to see if the agent created
a wrong-named branch, delete the wrong-named branch if present,
ensure `{branch_name}` is checked out, run `bash bin/pipeline.sh
decide ENG-N --action continue`.

## 7. Error handling

- **Empty/missing transcript.** `assert_no_tool_invocation` soft-fails
  via `[[ -s "$transcript" ]] || return 0` (verified at
  `bin/dispatch.sh:50`). On dry-run or any path where the renderer
  is bypassed, no false positives.
- **Malformed JSON line in transcript.** `fromjson? // empty` in
  the helper's jq filter (verified at `bin/dispatch.sh:53`) silently
  drops malformed lines. One bad line cannot abort the assertion.
- **Sidecar from a prior crashed dispatch.** `rm -f "$violation_file"`
  at `bin/dispatch.sh:98` pre-cleans on every renderer entry; clean
  current dispatch never sees stale state.
- **`run-stage.sh` crashes between dispatch and the rc=23 branch.**
  Sidecar persists in `$issue_dir`; next dispatch's renderer
  pre-cleans it. No false replay.
- **Multiple matching `tool_use` blocks.** The helper's `head -1`
  returns the FIRST matching command in NDJSON order. The pattern
  loop's order is `-b` → `-B` → `branch -m` → `switch -c`; the
  first MATCHING pattern in that order wins. Operator sees one
  command in the sidecar; if the transcript has multiple violations,
  only the first is named.
- **Pattern with regex metacharacters.** jq's `startswith($p)` is
  literal-string (verified at `bin/dispatch.sh:58`); no surprise
  expansion. AT5 in the existing test file already pins this for
  the helper.
- **Chained-command bypass** (`git status && git checkout -b foo`).
  Inherited from ENG-43/71's `startswith` semantics — the
  `.input.command` starts with `git status`, not `git checkout -b`,
  so the matcher does not fire. Documented as O-2; mitigated only
  by the prompt rule (which reads as plain English regardless of
  command structure). BC6 fixture pins this so a future refactor
  doesn't accidentally fix it without an audit.
- **Agent issues `git checkout -bfoo` (no space between flag and
  branch name).** Starts with `git checkout -b`; matches via
  `startswith`. Captured.
- **Agent issues `git checkout -bb`.** Also starts with
  `git checkout -b`; matches. False positive in principle, but
  `-bb` is not a valid git short flag, so this is a no-op edge case.

## 8. Edge cases

| Case | Behavior |
|---|---|
| Agent narrates `gh pr create` or `git checkout -b` in a `text` block | Helper's filter requires `tool_use` with `.name == "Bash"` (verified at `bin/dispatch.sh:56`); text-block prose is ignored. AS3/AS4 already pin this. |
| Agent issues a permitted `git checkout {branch_name}` (no `-b`/`-B`) | None of the four patterns match (`git checkout {branch_name}` does NOT start with `git checkout -b` etc.). BC5 fixture pins. |
| Agent issues `git checkout` with a path arg (`git checkout -- file.sh`) | `git checkout -- file.sh` does not start with `git checkout -b`. Helper does not fire. |
| Agent issues `git switch {branch_name}` (no `-c`) | Does not match `git switch -c`. Permitted. |
| Agent issues `git branch -d <name>` (delete) | Does not match `git branch -m`. Permitted. (Branch deletion is fine; it doesn't create a wrong-named branch.) |
| Agent issues `git checkout -b feat/eng-66-...` (correct branch name, wrong verb) | Matches `git checkout -b`; rc=23 fires. **Slight false-positive friction**: the agent attempted the canonical name but used the forbidden creation verb. Operator inspects, sees the canonical name was used, deletes the duplicate branch, runs `--action continue`. Verbosity friction is acceptable; the prompt rule is unambiguous that **none** of the four creation forms are permitted regardless of the resulting branch name. |
| Build agent issues `git checkout -b foo` | Both ENG-71 (rc=26) and ENG-66 (rc=23) match. Per D-006 ordering, ENG-71 fires first; rc=26. Operator recovery is identical. |
| Build agent issues `git switch -c foo` | Both ENG-71 (rc=26 — `git switch` startswith match) and ENG-66 (rc=23 — `git switch -c` startswith match) match. Per D-006, ENG-71 fires first. Same operator recovery. |
| Implement agent issues `git switch -c foo` | Only ENG-66 matches. rc=23. |
| QA agent issues `git checkout -B foo` | ENG-71's loop is gated on `stage == "building"`; it does NOT fire on QA. ENG-66 (cross-stage) fires; rc=23. |
| Brainstorm agent issues `git checkout -b foo` | The brainstorm allowlist (`bin/dispatch.sh:299`) carries no `Bash(git:*)` entries, so the lane should deny the call before it reaches the transcript. But if the agent somehow gets a `tool_use` to dispatch (matcher bug; sub-agent escape), ENG-66 fires; rc=23. |
| Pre-commit hook hits the new tests | `bin/dispatch-test.sh`, `bin/classify-failure-test.sh` are already in the suite. BC1-BC8 add ~120 LOC and 8 jq forks (each <100 ms). Test 18 adds ~10 LOC. Total wall-clock < 1 s within the ~30 s pre-commit budget. |
| Sidecar contains a command with newlines or shell metacharacters | The sidecar is one-line text (the matched `.input.command` is single-line by the renderer's stream shape). `cat "$_viol_file_23"` is safe; `_viol_cmd_23` ends up in a halt-comment body via `classify_failure`'s text — `linear.sh::linear_query` builds the GraphQL request with `jq -cn --arg q "$query" --argjson v "$variables"` (verified at `bin/linear.sh:167`), so the matched-command bytes are JSON-encoded into the request body via jq's `--arg` (never shell-evaluated). The metric `notes` field follows the same `jq --arg` path into events.jsonl (verified at `bin/metrics.sh`). No injection surface. |
| Operator uses `--action approve --gate scope` instead of `--action continue` | `--gate scope` is for scope-violation halts only (CLAUDE.md "Operator workflow" §3). For `branch-creation-forbidden`, the correct command is `--action continue` — same as every `agent-blocked`/`smoke-failed`/`iteration-exhausted` halt. The recovery.md row addition (D-004 companion) documents this. |

## 9. Open questions

- **Q1.** Should the helper-shape generalisation (D-001 alternative —
  array-of-patterns argument) be tracked as O-1 follow-up if a fourth
  cross-stage call site appears? **Recommendation:** yes; the cost
  is small (~80 LOC refactor; updates 4 call sites — ENG-43, ENG-71,
  ENG-68, ENG-66) but the benefit is deferred. Wait for the
  fourth call site.
- **Q2.** Should the chained-command bypass be closed via a substring-
  match upgrade (`contains($p)` instead of `startswith($p)`)? Inherited
  from ENG-71 O-4. **Recommendation:** out of scope; O-2.
- **Q3.** Should `git switch --create` (long-flag) be added to the
  pattern set? **Recommendation:** out of scope; O-3. Add only if a
  retrospective shows long-flag drift.
- **Q4.** Does the build-stage collision (D-006 ordering decision) need
  any operator-runbook clarification? **Recommendation:** the
  recovery action is identical for rc=23 and rc=26, and the matched
  command in the sidecar tells the operator unambiguously what
  happened. No extra runbook needed beyond the recovery.md row.
- **Q5 — closed in iteration 2:** BC8 fires on stage=qa. qa is the
  realistic case (broad `Bash(git:*)` surface; agents on the qa
  stage have the most opportunity to drift into branch creation).
  No further open question.

## 10. Persona review

Per the brainstorm checklist, six personas (design → security →
scope → coherence → product → feasibility) reviewed this brainstorm.
Verdicts and any folded findings recorded below; final tally + gate
decision in the stage summary file.

### Iteration 1

| Persona | Verdict | P0 | P1 |
|---|---|---|---|
| design | PASS | 0 | 2 |
| security | PASS | 0 | 1 |
| scope | PASS | 0 | 2 |
| coherence | PASS | 0 | 2 |
| product | PASS | 0 | 1 |
| feasibility | PASS | 0 | 2 |

**Iteration-1 P1 findings folded into the doc before declaring PASS:**

- **design-P1-1** (D-006 ordering rationale incomplete — should
  enumerate the collision matrix explicitly): folded — D-006 now
  contains a per-command match table showing rc-winners under the
  proposed ordering for the build-stage collision cases.
- **design-P1-2** (D-001 doesn't honestly state the 4-fork cost):
  folded — D-001 now states "Cost: 4 jq forks × ~10 ms = ~40 ms per
  dispatch" with the same calculus ENG-71 D-002 used.
- **security-P1-1** (sidecar body could carry shell metacharacters
  if the matched command contains them): folded — §8 row added
  noting `linear.sh::linear_query` JSON-encodes the body via
  `jq -cn --arg` (verified at `bin/linear.sh:167`), and metric
  `notes` follows the same `jq --arg` path. No injection surface.
  (Iteration-1 wording said "HTML-escapes"; corrected to
  "JSON-encodes via jq --arg" to match the actual code path
  reviewers verified.)
- **scope-P1-1** (AC5 names a different file than the brainstorm
  picks): folded — D-008 explicitly calls out the deviation and
  invokes AC5's "or a new test" clause.
- **scope-P1-2** (`git switch -c` is a subset of ENG-71's
  `git switch` for the build stage — duplicative): folded —
  D-006's collision matrix and §8 row both show the build-stage
  case explicitly; the ENG-66 entry is still load-bearing for
  non-build stages.
- **coherence-P1-1** (failure_outcome_for_exit slot ordering):
  folded — D-005 verifies slot 23 is unused at
  `bin/common.sh:127-128`.
- **coherence-P1-2** (test-isolation-test.sh is wrong file per
  AC5): folded — see D-008 + scope-P1-1 fold.
- **product-P1-1** (operator-runbook row in recovery.md is a soft
  add, not blocking): folded — §5 row marked "if such a table
  exists" since the file structure isn't load-bearing.
- **feasibility-P1-1** (verify slot 23 is unused): verified at
  `bin/common.sh:127-128`.
- **feasibility-P1-2** (verify `bin/run-stage.sh` line 772 is the
  rc=26 branch): verified — the issue's literal "before existing
  rc=26 branch" requirement matches the current file (the rc=22
  branch is at line 759, rc=26 at line 772; ENG-66's rc=23 fits
  between).

### Iteration 2

Addressed converging P1 findings from iteration 1:

- **design-P1-1 / coherence-P1-1** (D-006 self-contradicting
  parenthetical): folded — D-006's "Rejected alternative — ENG-66
  BEFORE ENG-71" prose tightened. The collision matrix table
  already showed all three of `git checkout -b`, `git checkout -B`,
  `git switch -c` collide on the build stage; the only ENG-66-
  exclusive build-stage match is `git branch -m`. Stated cleanly.
- **scope-P1-1 / coherence-P1-2 / design-P1-2** (§11 assumption
  row about `bin/run-stage.sh:4-11` docstring marked "assumed"):
  verified on disk (`bin/run-stage.sh:4-11` carries the docstring
  with rc=22, 24, 25, 26 explicitly listed; slot 23 unused).
  §11 row upgraded to **verified (iteration 2)**.
- **design-P1-3 / scope-P1-2** (Q5 left open while §15 said
  "flagged out-of-scope"): closed — Q5 promoted to a settled
  recommendation (BC8 fires on stage=qa) with rationale already
  captured.
- **product-P1-1 / product-P1-2** (recovery.md row marked optional;
  halt comment doesn't surface the manual-cleanup recipe): folded —
  §5 row promoted to **mandatory** with explicit content list:
  (a) what triggers exit 23, (b) cleanup recipe (`git -C $wt branch
  -D <wrong-name>`), (c) resume command, (d) build-stage collision
  hint. §14 implementation checklist step 7 updated accordingly.
- **product-P1-3 / coherence-P1-3** (build-stage rc=26 collision
  English): folded — recovery.md content list (§5) now requires
  the one-line cross-reference noting that rc=26 with a `-b`/`-B`/
  `-c` sidecar should be treated as a branch-creation cleanup.
- **security-P1-1** (matched-command bytes safety claim was
  stated as "HTML-escaped" — incorrect): corrected to "JSON-encoded
  via `jq -cn --arg`" (verified at `bin/linear.sh:167` and the
  same path for metric `notes` via `bin/metrics.sh`). §8 row and
  §10 fold notes both updated.
- **security-P1-2** (sidecar permissions inherited from ENG-43/71/68
  — written under default umask 022, not SEC-005's umask 077):
  acknowledged as **inherited** from the three predecessor sites
  (each writes `printf '%s\n' "$cmd" > "$violation_file"` without
  wrapping in `( umask 077; ... )`; verified at `bin/dispatch.sh:189,
  213, 242`). The matched command is agent-controlled prose that
  the prompt secret-handling preamble keeps secret-free, so the
  operational risk is low. Captured as **O-5**: a follow-up that
  wraps all four sidecar-write call sites in `( umask 077; ... )`
  uniformly. ENG-66 does NOT widen this gap; deferring matches
  the precedent.
- **coherence-P1-3 / design-P1-3 (`-bb` typo edge case framing)**:
  acknowledged — `git checkout -bb foo` would match `git checkout -b`
  via startswith and fire rc=23 even though `-bb` is not a valid
  flag. The operator sees the matched command unambiguously and
  can dismiss as a typo via `--action continue` (or escalate if it
  recurs). False-halt friction is bounded; not worth a regex
  word-boundary upgrade for a hypothetical typo class. No fold.

## 11. Assumption inventory

Every code-level claim in this brainstorm, with verification:

| Claim | Source-of-truth | Status |
|---|---|---|
| `assert_no_tool_invocation` exists in `bin/dispatch.sh` and takes (transcript, pattern) | `bin/dispatch.sh:48-65` | **verified** |
| Helper soft-fails on empty/missing transcript | `bin/dispatch.sh:50` (`[[ -s "$transcript" ]] || return 0`) | **verified** |
| Helper uses jq `startswith` (literal, not regex) | `bin/dispatch.sh:58` | **verified** |
| Helper returns first match via `head -1` | `bin/dispatch.sh:59` | **verified** |
| `_render_and_capture_stream` accepts `(usage_file, issue_dir, stage)` | `bin/dispatch.sh:94-95` | **verified** |
| Sidecar path is `${issue_dir}/.transcript-violation-${stage}` | `bin/dispatch.sh:97` | **verified** |
| Sidecar pre-clean at function entry | `bin/dispatch.sh:98` (`rm -f "$violation_file"`) | **verified** |
| ENG-43 implementing-stage block exists at lines 184-193 | `bin/dispatch.sh:184-193` (`if [[ "$stage" == "implementing" ]]`) | **verified** |
| ENG-71 building-stage block exists at lines 207-218 with 4 patterns | `bin/dispatch.sh:207-218` (`for _pat in 'git checkout' 'git switch' 'git pull' 'git reset'`) | **verified** |
| ENG-68 cross-stage `core.bare` block exists at lines 219-246 with 5 patterns | `bin/dispatch.sh:219-246` (`for _git_pattern in "git config core.bare" …`) | **verified** |
| `failure_outcome_for_exit` is at `bin/common.sh:111-136`; slot 23 unused | `bin/common.sh:127-128` (slot 22 → `pr-opened-too-early`, then 24 → `linear-post-failed`; no 23 entry) | **verified** |
| `run-stage.sh` dispatch-rc handling at lines 740-818 with rc=22 (line 759), rc=26 (line 772), rc=13 (line 799) branches | `bin/run-stage.sh:740-818` | **verified** |
| `bin/run-stage.sh:4-11` carries an exit-code header docstring listing rc=22, 24, 25, 26 explicitly (slot 23 is currently unused; consistent with `bin/common.sh:127-128`) | `bin/run-stage.sh:4-11` | **verified** (iteration 2) |
| `bin/dispatch-test.sh` AS1-AS6 fixtures at lines 1141-1235 | `bin/dispatch-test.sh:1141-1235` | **verified** |
| `bin/dispatch-test.sh` AS7-AS12 (ENG-71) fixtures continue at lines 1237-1338 | `bin/dispatch-test.sh:1237-1338` | **verified** |
| `bin/dispatch-test.sh` CB1-CB8 (ENG-68) fixtures at lines 1340-1482 | `bin/dispatch-test.sh:1340-1482` | **verified** |
| `bin/dispatch-test.sh` AT1-AT5 / AT6-AT11 adversarial fixtures continue past line 1485 | `bin/dispatch-test.sh:1484+` | **verified** |
| `bin/classify-failure-test.sh` Test 15 pins ENG-71 exit-26 entry at lines 220-232 | `bin/classify-failure-test.sh:220-232` | **verified** |
| `bin/agent-prompts-content-test.sh:505` pins the four banned forms | `bin/agent-prompts-content-test.sh:505-512` (`for forbidden in 'git checkout -b' 'git checkout -B' 'git branch -m' 'git switch -c'`) | **verified** |
| `AGENT_PROMPTS.md:86` enumerates the four forms in the §3 hard rules | `AGENT_PROMPTS.md:86` | **verified** |
| `AGENT_PROMPTS.md:582` repeats the four forms in the implement §3 prompt | `AGENT_PROMPTS.md:582` | **verified** |
| `bin/test-isolation-test.sh` is a fixture-leak regression test, not a taxonomy pin | `bin/test-isolation-test.sh:1-5` (header comment: "Regression test for the 2026-05-04 fixture-leak incident") | **verified** |
| `classify_failure` writes `issue-state.json`, applies labels, emits `stage-end` metric | `bin/classify-failure.sh:103, 108-113, 175-185` | **verified** |
| Implementing/UI/QA tool-lane allowlists carry `Bash(git checkout:*)` etc. | `bin/dispatch.sh:301` (implementing), 302 (ui), 304 (qa: `Bash(git:*)`) | **verified** |
| Building tool-lane allowlist carries only fetch/clone/rebase | `bin/dispatch.sh:305` | **verified** |
| ENG-43 brainstorm at `docs/brainstorms/2026-05-02-eng-43-…-design.md` | direct read | **verified** |
| ENG-71 brainstorm at `docs/brainstorms/2026-05-06-eng-71-…-design.md` | direct read | **verified** |
| CLAUDE.md "When wiring a new script" § names the assertion pattern as the canonical defense | `CLAUDE.md` "When wiring a new script" §; quoted in §3 above | **verified** |
| `--action continue` clears halt label, skip-* labels, wait files, issue-state, breaker, per-issue counter | `CLAUDE.md` "What `--action continue` clears" § | **verified** |
| `linear.sh add-or-update-comment` is the dedup writer with sig | `bin/linear.sh add-or-update-comment` (referenced in CLAUDE.md "Linear conventions" §) | **verified** |
| `docs/runbooks/recovery.md` exists and may carry an exit-code reference table | `docs/runbooks/` listing shows `recovery.md` and `operator-mental-model.md` exist | **verified** (file exists; exact table presence to be confirmed at implement-time) |

## 12. Scope flags

### 12.1 In scope (matches issue Acceptance Criteria)

- AC1: cross-stage transcript scan in `bin/dispatch.sh` calling
  `assert_no_tool_invocation` four times in a loop (D-001).
- AC2: hit produces exit 23, sidecar at
  `${issue_dir}/.transcript-violation-${stage}`, log line, halt
  comment naming the offending command via the
  `classify_failure` plumbing in `run-stage.sh`'s rc=23 branch
  (D-004).
- AC3: BC2 fixture pins `git checkout -B feature/eng-99-foo` →
  rc=23 with the matched command in the sidecar (D-007).
- AC4: BC5 fixture pins benign `git checkout {branch_name}` →
  rc=0, no sidecar (D-007).
- AC5: `bin/common.sh::failure_outcome_for_exit` adds the entry
  (D-005); `bin/classify-failure-test.sh` Test 18 pins it (D-007,
  D-008 explains the deviation from the issue's literal `bin/test-
  isolation-test.sh` reference).

### 12.2 Out of scope (explicitly deferred)

- O-1: Helper-shape generalisation to take an array of patterns
  (D-001 §rejected). Defer to a fourth call site materializing
  with a different shape.
- O-2: Chained-command substring-match upgrade
  (`git status && git checkout -b foo` bypass). Inherited from
  ENG-43/71. Defer to post-deploy if metric volume reveals it.
- O-3: Long-flag aliases (`git switch --create`, `git branch
  --move`, `git checkout --branch`). Defer to a future incident.
- O-4: A separate post-dispatch state-of-the-world detector
  (mirror of ENG-71 D-003 HEAD-detect). Operator recovery via
  `--action continue` already covers this; defer if metric volume
  shows escapes.
- O-5: Wrap the four sidecar-write call sites (ENG-43 line 189,
  ENG-71 line 213, ENG-68 line 242, ENG-66's new write) in
  `( umask 077; ... )` uniformly to match SEC-005's `umask 077`
  precedent for the usage-file write. The matched-command bytes
  are agent-controlled prose kept secret-free by the prompt
  preamble's `*KEY|*TOKEN|*SECRET` handling rule, so the
  operational risk today is low; the SEC-005 alignment is a
  cleanup that should touch all four sites in one PR. Out of
  scope for ENG-66 (which inherits the gap rather than introducing
  it).

### 12.3 Conflicts with existing architecture

None. The proposed changes:

- Honor the ENG-43 D-008 sidecar path invariant.
- Honor the ENG-43 D-005 soft-fail on missing transcript.
- Honor the ENG-43 D-010 helper-purity contract (no harness ambient
  context).
- Honor the cross-stage precedent set by ENG-68's `core.bare` block.
- Honor the symmetric-pattern-set discipline (ENG-62 Bld-001 →
  ENG-71 D-001/D-002): prompt rule, content test, dispatch loop
  enumerate the same four patterns.
- Honor CLAUDE.md's defense-in-depth rule for transcript-based
  assertions.
- Preserve the operator-facing surface (exit code, sidecar,
  classify_failure plumbing) used by all three predecessor features.

## 13. Test strategy

### 13.1 Unit (BC1-BC8 in `bin/dispatch-test.sh`)

Each fixture writes an NDJSON file under `$_TEST_STUB_DIR/`, calls
either the helper directly (BC1-BC6) or `_render_and_capture_stream`
(BC7-BC8), and asserts the (return-code, stdout, sidecar
existence) tuple. See D-007 for the per-fixture purpose and the
exact NDJSON inputs.

### 13.2 Taxonomy pin (Test 18 in `bin/classify-failure-test.sh`)

Calls `classify_failure ... 23 ""` and asserts the resulting
`stage-end` metric's outcome is `branch-creation-forbidden`.
Mirror of Test 15 verbatim except for the exit code and outcome
string.

### 13.3 Integration

`bin/run-stage-test.sh` does not need a new case for the rc=23
branch in v1: stubbing `dispatch.sh` to return 23 with a sidecar is
doable but adds material complexity. The dispatch-test.sh BC7
fixture covers the helper-and-renderer path end-to-end; the
classify-failure-test.sh Test 18 covers the metrics path. The
small, mechanical addition to run-stage.sh's exit ladder is a
copy-paste from the existing rc=22 / rc=26 / rc=13 branches and
needs no new test. (Same calculus as ENG-43, ENG-71, ENG-68.)

### 13.4 Smoke

`bash bin/dry-run.sh` continues to pass (dispatch.sh's dry-run path
short-circuits before the renderer is invoked, so the assertion
loop is not exercised).

### 13.5 Pre-commit gate

The pre-commit hook at `.githooks/pre-commit` (per CLAUDE.md "Pre-
commit hook" §) globs `bin/*-test.sh`. BC1-BC8 + Test 18 land
under the suite automatically. Total added wall-clock budget < 1 s
inside the ~30 s pre-commit cap.

## 14. Implementation checklist

For the planning / implementing agents that follow:

1. `bin/common.sh` — insert `23) printf 'branch-creation-forbidden' ;;`
   between existing `22)` and `24)` arms in `failure_outcome_for_exit`.
2. `bin/run-stage.sh:4-11` — add `23=branch-creation-forbidden` to the
   exit-code header docstring, between 22 and 26.
3. `bin/run-stage.sh::main` — add the `elif (( dispatch_rc == 23 ))`
   branch BEFORE the existing `dispatch_rc == 26` branch (current
   line 772 of `bin/run-stage.sh`). Body shape per D-004.
4. `bin/dispatch.sh::_render_and_capture_stream` — insert the
   ENG-66 four-pattern loop AFTER the ENG-71 building-stage block
   (current line 218) and BEFORE the ENG-68 cross-stage `core.bare`
   block (current line 219). Body shape per D-001.
5. `bin/dispatch-test.sh` — append BC1-BC8 fixtures after the CB8
   block (current line 1482). Mirror the AS1/AS7/CB1/CB7 patterns.
6. `bin/classify-failure-test.sh` — append Test 18 mirror of Test
   15 (current line 220-232).
7. `docs/runbooks/recovery.md` — add a `branch-creation-forbidden`
   subsection (**mandatory** per product-P1 fold). Section MUST
   include: (a) what triggers exit 23 (the four banned forms), (b)
   the manual-cleanup recipe (`git -C <wt> branch -D <wrong-name>`
   followed by `git -C <wt> status` to confirm `{branch_name}` is
   on HEAD), (c) the standard `bash bin/pipeline.sh decide <issue>
   --action continue` resume command, (d) a one-line note that on
   the build stage, an rc=26 halt whose sidecar shows a `-b`/`-B`/
   `-c` form should be treated as a branch-creation cleanup (D-006
   collision case). Cross-link from the halt-comment (the body
   `classify-failure.sh` builds for skip-until-human-acts already
   names the matched command; the operator needs the cleanup recipe
   on top of that).
8. Run `bash bin/dispatch-test.sh && bash bin/classify-failure-test.sh
   && bash bin/run-stage-test.sh && bash bin/common-test.sh` to
   confirm no regressions.

## 15. Persona review (final tally)

After folding the iteration-1 P1 findings AND the iteration-2 P1
folds (security-P1-1 escaping wording, security-P1-2 sidecar umask
deferral, design-P1-1 / coherence-P1-1 D-006 self-contradiction
tightening, scope-P1-1 / coherence-P1-2 / design-P1-2 §11 row
upgrade, design-P1-3 / scope-P1-2 Q5 closure, product-P1-1 /
product-P1-2 / product-P1-3 recovery.md row promotion, coherence-P1-3
/ design-P1-3 `-bb` typo framing), all six personas return PASS
with zero P0 findings. Gate condition met — proceed to planning.

| Persona | Verdict | Notes |
|---|---|---|
| design | PASS | ENG-43 / ENG-71 / ENG-68 patterns inherited verbatim; D-006 ordering rationale + collision matrix; cost (4 jq forks) honestly stated. |
| security | PASS | Halt-comment body JSON-encoded via `jq --arg` (verified at `bin/linear.sh:167`); metric `notes` follows the same path (`bin/metrics.sh`); no new secret surface; helper purity preserved (ENG-43 D-010). Sidecar umask gap inherited from ENG-43/71/68 acknowledged (security-P1-2) and deferred as O-5. |
| scope | PASS | Out-of-scope items O-1..O-5 explicitly deferred; AC5 deviation (D-008) documented; no scope creep. |
| coherence | PASS | All decisions reference an earlier ADR-equivalent (ENG-43 D-005/D-008/D-010, ENG-71 D-002, ENG-68 cross-stage precedent, ENG-62 Bld-001). No conflicts. Iteration-2 fold tightened wording around scope-P1-1, coherence-P1-2. |
| product | PASS | Operator-facing surface preserved (`branch-creation-forbidden` is a strict refinement of existing halt classes; recovery uses standard `--action continue` after manual cleanup). recovery.md row promoted to mandatory and now lists the cleanup recipe explicitly. |
| feasibility | PASS | Every code reference verified against current `bin/dispatch.sh`, `bin/common.sh`, `bin/run-stage.sh`, `bin/dispatch-test.sh`, `bin/classify-failure-test.sh`, `bin/agent-prompts-content-test.sh`, `bin/test-isolation-test.sh`, `bin/linear.sh`, `AGENT_PROMPTS.md` (§11). Zero P0 findings. |
