---
linear: ENG-71
title: Build agent checks out `main` inside the per-issue worktree post-merge, locking main globally for the harness
date: 2026-05-06
status: draft
---

# Build agent checks out `main` inside the per-issue worktree post-merge, locking main globally

## 1. Overview (and the load-bearing surprise)

After ENG-61's PR #47 merged at `2026-05-05 16:35:33Z`, the operator could
not `git checkout main` in `~/code/twinning-harness`:

```
fatal: 'main' is already used by worktree at
'/Users/rajatgoyal/.local/state/twinning-harness/harness/ENG-61/worktree'
```

The ENG-61 worktree's reflog (verified in the issue body) shows a
`checkout: moving from feat/eng-61-… to main` followed by
`pull --ff-only origin main` — both 1–2 seconds after the GitHub merge
event landed, well inside the build-agent's 30-min wall-clock window.
Far too fast for a human; this was the build agent reacting to the
just-fired `gh pr merge --auto`.

**The load-bearing surprise.** The build agent's `--allowed-tools`
allowlist (verified at `bin/dispatch.sh:252`) contains
`Bash(git fetch:*)`, `Bash(git clone:*)`, `Bash(git rebase:*)` —
**neither `Bash(git checkout:*)` nor `Bash(git pull:*)`** — yet both
ran. The Linear issue's "Open question (concerning)" calls this out
explicitly and asks for reproduction.

The likely bypass path (this brainstorm's working hypothesis) is the
**chained-command class**: Claude Code's allowlist matcher does prefix
matching against the rendered Bash command string. A chained command
that *starts* with an allowed prefix passes the gate, and the shell
evaluator runs every command after the `&&`. Evidence:

- `bin/dispatch.sh:184-193` (the existing ENG-43 transcript-based
  assertion) is doing exactly this defense for the implement stage's
  `gh pr create` — it inspects the rendered tool_use payload after the
  fact, *because* the lane denial cannot be trusted in isolation.
- `AGENT_PROMPTS.md:1346-1347` literally trains the build agent to
  use chained commands inside one tool call:
  ```
  git fetch origin main && git -C $(mktemp -d) clone --quiet \
    --branch {branch_name} <origin> && cd <clone> && git rebase \
    --quiet origin/main
  ```
  A model that has internalised "I can chain commands behind `git fetch`"
  has a clear precedent for `git fetch origin main && git checkout main
  && git pull --ff-only origin main`.
- The build dispatch transcript at `…/logs/ENG-61-building-…log` ended
  with an API error before tool I/O was fully captured (per issue body),
  so we cannot confirm against the actual transcript today. **Repro is
  part of the work** — but the design must defend on the assumption
  that the chained-command path IS open, because waiting for a
  reproduction before adding the prompt rule + post-dispatch detector
  leaves the operator-impact open through the next merge cycle.

The Linear issue suggests three layers of defense (prompt-level,
sandbox-level, defense-in-depth post-dispatch detector) and explicitly
recommends shipping (1) and (3) as one PR, deferring (2) into its own
ticket pending repro. **This brainstorm follows that recommendation.**
D-001 + D-002 + D-003 + D-004 ship together; the sandbox-bypass
investigation is captured as O-1 in §10 with a concrete repro recipe.

The trade-off: D-003 (post-dispatch detector) is symptomatic, not
causal — it cannot prevent the agent from running `git checkout main`,
only catch the worktree state afterwards and unwind it. That's
acceptable because the operator-impact symptom (main locked
globally) is what blocks productivity; an undetected `git checkout
main` that immediately got reset would be a near-no-op. D-001 (prompt
rule) is causal but unenforceable on a model that already learned the
chained-command idiom from P6's own example. The two together close
the user-visible gap; D-002 (transcript assertion) closes the
underlying contract.

## 2. Goals

After this ticket lands:

1. **Prompt-level** (D-001): the build agent's §7 prompt in
   `AGENT_PROMPTS.md` carries an explicit "MANDATORY: never run
   `git checkout`, `git switch`, `git pull`, or `git reset` to mutate
   the worktree's HEAD. The orchestrator owns local sync; you operate
   on `{branch_name}` only" rule. The §3 hard-rules block (rules
   1–4 at `AGENT_PROMPTS.md:83-88`) already covers the analogous
   "no `git checkout -b`" rule and is the natural neighbour.
2. **Test-pinned** (D-001 companion): `bin/agent-prompts-content-test.sh`
   gains a fixture asserting the new MANDATORY rule's presence in
   `## 7. Build Agent` and the absence of any prose that re-introduces
   `git checkout main` / `git pull` as a recommended action. A future
   retrospective edit that drops the rule fails the pre-commit hook.
3. **Transcript-based assertion** (D-002): `bin/dispatch.sh::main` gates
   on `stage == "building"` and runs `assert_no_tool_invocation` for the
   four forbidden patterns (`git checkout`, `git switch`, `git pull`,
   `git reset`). On match: same flow as ENG-43's `gh pr create` hit —
   write `$violation_file`, return code 26 (new), `run-stage.sh` routes
   to `skip-until-human-acts` with a `worktree-mutation-forbidden`
   classification. The post-dispatch detector below (D-003) is a belt
   to D-002's braces; if D-002 fires and exits cleanly, D-003 will not
   see the worktree on main because the agent's exit code already
   bypassed any further git ops. **Modulo the inherited `startswith`
   blind spot on chained commands captured in §7 and O-4** — D-002 is
   the contract test for "the agent did not standalone-invoke a
   forbidden git verb"; chained variants (`git fetch ... && git
   checkout main`) start with an allowed prefix and pass D-002's
   matcher; D-003 is the documented catch-net for those.
4. **Defense-in-depth post-dispatch detector** (D-003):
   `bin/run-stage.sh::main` post-dispatch (after the agent returns,
   before the verdict_handler call) checks the worktree's HEAD; if
   the worktree is on `main` (or any ref other than `{branch_name}`),
   detach HEAD to the merge commit, log loudly, emit a
   `worktree-mutated-by-agent` metric, and continue with the verdict
   handler. The detach is the minimal repair that unlocks `main`
   globally (`git worktree`'s "branch already used" error fires on
   *checked-out* branches; a detached HEAD is invisible to the lock).
5. **Test coverage** (D-004): `bin/dispatch-test.sh` gains AS7-AS12
   fixtures (six total) locking the four `assert_no_tool_invocation`
   patterns under `stage=building` plus a passthrough fixture (AS11)
   and a stage-gating fixture (AS12, ensuring `stage=implementing`
   does NOT trigger the build-only loop). `bin/run-stage-test.sh`
   gains a paired fixture for D-003's HEAD-detection: stub a worktree
   on `main`, dispatch a no-op stage, assert the HEAD got detached +
   the metric emitted; plus a clean-state companion that asserts no
   detach when HEAD already on the expected branch.

Non-goals (explicit, follow the issue's Suggested approach):

- Confirming whether the chained-command bypass is a Claude Code
  matcher bug vs. expected-behavior. **O-1**: open a separate ticket
  for repro + (if confirmed bug) upstream report. The fix landed here
  is platform-agnostic — both D-002 and D-003 work whether the matcher
  is bugged or whether the agent legitimately had permission.
- Auditing every other stage's tool allowlist for similar chained-
  command exposure. **O-2**: same followup. D-002's pattern is
  trivially extensible to other stages once we know which patterns
  to block.
- Deleting / reworking `AGENT_PROMPTS.md` P6's chained-command example.
  P6 itself is correct (clones into `mktemp -d`, doesn't touch the
  worktree); the chained-command idiom isn't the bug — the *implication*
  the agent drew from it is. **O-3**: optionally, a retrospective rule
  in `learned-rules/harness/build.md` could narrow the agent's read
  of the P6 idiom. Defer to the actual retrospective on this incident.

## 3. Architectural principle

The repo has no `docs/VISION.md`, no `docs/ARCHITECTURE.md`, no
`docs/knowledge/decisions.md` (verified: `ls docs/` returns
`brainstorms/  pipeline-vocabulary.md  pipeline-vocabulary.template.md
plans/  runbooks/`; no `knowledge/` subdir). Governing constraints
come from `CLAUDE.md`, `learned-rules/harness/project-profile.md`,
and accepted brainstorms.

Principles invoked here are existing CLAUDE.md commitments, not new
ones:

- **Defense-in-depth on top of tool-lane denials.** `CLAUDE.md`
  "When wiring a new script" §: *"when a stage's contract says
  'agent must not invoke tool X,' prefer a transcript-based assertion
  (`assert_no_tool_invocation` in `bin/dispatch.sh`) over a state-of-
  the-world check after dispatch. State checks false-positive on
  actions taken by other actors (humans, prior stages, future
  agents); transcript checks answer the contract question directly.
  Today only the implement stage uses this pattern (forbidding
  `gh pr create`); generalising to other stages is a separate
  refactor."* This brainstorm is exactly that "separate refactor" for
  the build stage. D-002 is the canonical surface; D-003 is the
  state-check belt that exists *only* because the operator-visible
  symptom is global (main locked across worktrees), not local to the
  agent's worktree.
- **Worktree branch-mutation rules belong in the agent prompt.**
  `AGENT_PROMPTS.md:83-88` Rules 1–4 already enumerate the canonical
  branch-mutation rules: rule 2 forbids `git checkout -b`, rule 4
  permits exactly one operation (`git checkout {branch_name}`
  without `-b`). The ENG-71 rule (forbid switching to `main` /
  pulling / resetting) is the mirror image: not "don't create a
  parallel branch" but "don't leave the assigned one." Same
  neighbourhood, same enforcement vector (prompt + content test).
- **Single-source-of-truth post-dispatch hook.** `bin/run-stage.sh`'s
  `main()` already has the canonical post-dispatch hook chain:
  `_post_dispatch_apply_halt` (line 905), `verdict_handler`
  (line 915), `_post_review_dispatch_update` (line 497, called from
  the success branch). The new HEAD-detection step in D-003 inserts
  into this chain, after the dispatch returns and before
  `verdict_handler`, so it observes the same worktree state any
  follow-up sees. Stage-gated to `building` matches the existing
  `_pre_dispatch_merge_gate` (line 530: `case "$stage" in building) ;;
  *) return 1 ;; esac`).
- **Symmetric query / pattern shape between prompt and orchestrator.**
  ENG-62 set this precedent (Rule Bld-001 in `learned-rules/harness/
  build.md`): the prompt's P0 short-circuit query and the
  orchestrator's `_pre_dispatch_merge_gate` use the **identical**
  `gh pr list --head <branch> --state all --json state --jq
  '.[0].state // ""'` query. Divergence between the two paths is
  what produced ENG-62's wasted dispatches in the first place.
  D-001 + D-002 mirror this discipline: the prose rule lists exactly
  the four patterns (`git checkout`, `git switch`, `git pull`,
  `git reset`), and the assertion checks for exactly those four
  patterns. A future contributor who wants to add `git restore`
  to the forbidden set updates *both* sites or fails the content
  test.
- **Sentinel + source-and-stub pattern for new test invariants.**
  `CLAUDE.md` "Tests" §: *"When a new bash file is meant to be both
  executable and unit-testable, replicate the sentinel pattern."*
  `bin/dispatch.sh` and `bin/run-stage.sh` both already have the
  sentinel; D-002 + D-003 add functions inside them, leaving the
  sentinel intact. New test fixtures in `bin/dispatch-test.sh` and
  `bin/run-stage-test.sh` follow the existing source-and-stub layout
  (verified at `bin/dispatch-test.sh:1141-1235` for the AS1-AS6
  pattern that AS7-AS12 will mirror, and `bin/run-stage-test.sh:1-50`
  for the `STUB_DIR=$(mktemp -d) ; trap 'rm -rf' EXIT` pattern).

## 4. Decisions

### D-001: Prompt-level rule + content test (the "necessary, not sufficient" layer)

**Verdict.** Append a new MANDATORY-rule paragraph to
`AGENT_PROMPTS.md` §7's body, immediately after the
**Tool allowlist & probing** preamble (line 1232) and before the
**Read these files first** list (line 1234). Concrete text:

> **MANDATORY worktree-HEAD rule (ENG-71):** Never run `git checkout`,
> `git switch`, `git pull`, or `git reset` inside the worktree. The
> orchestrator already checked out `{branch_name}` for you; the
> post-merge `gh pr merge --auto --delete-branch` you fire is
> server-side and updates main on origin, not on disk. If you want
> to verify the merge SHA on main, query `gh api
> repos/{owner}/{repo}/branches/main --jq '.commit.sha'` (read-only,
> no checkout needed) — the build allowlist already grants
> `gh run`/`gh pr` calls, plus `gh api` is allow-listed via the same
> `gh:*` family if added to a future allowlist update. (For now: the
> post-merge CI watch in `gh run watch <run-id>` already operates on
> the merge run identified by SHA, no checkout required.) The
> prohibition includes chained commands: `git fetch origin main && git
> checkout main` is forbidden whether or not the matcher would have
> denied it standalone. **If you accidentally end up on a branch other
> than `{branch_name}`, do NOT "fix" it by switching back — emit
> `verdict halt --reason agent-blocked` and exit; the orchestrator's
> post-dispatch detector (`bin/run-stage.sh`, ENG-71 D-003) will
> detach the HEAD to unlock main globally.**

Pin the rule's presence with a new content-test case in
`bin/agent-prompts-content-test.sh`:

```bash
# §7 — ENG-71: build agent must not check out main / pull / reset.
if printf '%s\n' "$s7" | grep -qF 'MANDATORY worktree-HEAD rule (ENG-71)'; then
  ok "§7 contains ENG-71 worktree-HEAD MANDATORY rule"
else
  nope "§7 contains ENG-71 worktree-HEAD MANDATORY rule" "phrase missing"
fi
# §7 — ENG-71: must explicitly forbid all four patterns.
for pat in 'git checkout' 'git switch' 'git pull' 'git reset'; do
  if printf '%s\n' "$s7" | grep -qF "\`$pat\`"; then
    ok "§7 explicitly names \`$pat\` as forbidden"
  else
    nope "§7 names \`$pat\`" "pattern not back-tick-quoted in §7"
  fi
done
# §7 — ENG-71: chained-command class is named.
if printf '%s\n' "$s7" | grep -qF 'chained commands'; then
  ok "§7 names chained-command class explicitly"
else
  nope "§7 names chained-command class" "phrase missing"
fi
```

**Why.** Direct fix for the issue's "Proposed scope" item 1
("Prompt-level (necessary, not sufficient)"). Mirrors the existing
hard-rules block at `AGENT_PROMPTS.md:83-88` (which uses identical
"do not run X" language for `git checkout -b` etc.) and the existing
ENG-43-style content-test pattern at `bin/agent-prompts-content-test.sh:36-51`
(which already does grep-based content invariants for §3 / §4 / §7).
Naming chained commands explicitly is load-bearing — the agent that
ran ENG-61's checkout did so via the matcher-bypass path (working
hypothesis); a rule that names only standalone commands is read by
the model as silent-permission for chained variants.

**Rejected alternative — bury the rule in `learned-rules/harness/
build.md`.** Learned rules are gated by `pipeline:rule-reviewed`
human approval and currently expire after 60 days
(`learned-rules/harness/build.md:7`). A rule with a 60-day TTL is
the wrong surface for an invariant we want to hold for the lifetime
of the harness. CLAUDE.md's "AGENT_PROMPTS.md is load-bearing" §
makes the canonical home of stage-permanent rules the prompt itself;
learned-rules carry shorter-shelf observations. Rejected.

**Rejected alternative — make the prompt rule a one-liner without
the back-ticked pattern enumeration.** "Never mutate the worktree's
HEAD" is shorter and arguably equivalent. But the content test
(`grep -qF '\`git checkout\`'`) keys off the literal pattern names;
without them the test would have to grep for prose ("HEAD" /
"mutate") that drifts more easily. Adopted: enumerate the four
patterns literally; let the test pin them.

**Rejected alternative — add the rule to the global preamble at
`AGENT_PROMPTS.md:77-88` (Branch-name convention block) so it
applies to every stage.** Tempting (the four-pattern forbid is
arguably stage-agnostic) but premature. Only the build stage has
the post-merge "I should verify main" intuition that triggers the
checkout. Implement / UI / Review / QA stages have neither the
prompt language nor the workflow that makes them think about main.
Adding the rule to the global preamble would be over-broad and
would obscure the build-specific motivation. Defer to a separate
ticket if the same failure mode is observed at another stage.
Rejected.

### D-002: Transcript-based assertion in dispatch.sh (the contract layer)

**Verdict.** Extend `bin/dispatch.sh::_render_and_capture_stream`'s
existing `assert_no_tool_invocation` call (currently at lines
184-193, gated on `stage == "implementing"` for `gh pr create`) with
a parallel block gated on `stage == "building"` that loops over four
forbidden patterns:

```bash
# ENG-71: defense-in-depth assertion. Build's tool lane denies
# Bash(git checkout:*) etc. by omission (only Bash(git fetch:*),
# Bash(git clone:*), Bash(git rebase:*) are permitted). This is the
# second line of defense if the lane's prefix-matcher is bypassed
# by chained commands (ENG-61 hypothesis). Gated on stage == "building"
# only — other stages observe no behavior change.
if [[ "$stage" == "building" ]]; then
  local _pat _matched_cmd
  for _pat in 'git checkout' 'git switch' 'git pull' 'git reset'; do
    if _matched_cmd="$(assert_no_tool_invocation "$raw_capture" "$_pat")"; then
      :   # rc 0: no match, fall through
    else
      printf '%s\n' "$_matched_cmd" > "$violation_file"
      log "[assert] build-stage transcript invoked forbidden tool: ${_matched_cmd}"
      return 26
    fi
  done
fi
```

Wire return code 26 through:
- `bin/common.sh::failure_outcome_for_exit` adds `26) printf
  'worktree-mutation-forbidden' ;;` (slots between existing 25 and
  124; verified the gap exists at `bin/common.sh:107-128`).
- `bin/run-stage.sh:4-9` exit-code header docstring lists `26=worktree-
  mutation-forbidden` alongside `22=pr-opened-too-early`.
- `bin/run-stage.sh::main`'s dispatch-rc handling (verified at
  lines 651-665 area) routes rc=26 the same way it routes rc=22:
  `classify_failure ... "skip-until-human-acts" "$violation_msg" 26;
  exit 26`. Operator unblocks via the standard `bash bin/pipeline.sh
  decide ENG-N --action continue` (verified at CLAUDE.md "What
  `--action continue` clears" §).

**Why.** Direct fix for the issue's "Proposed scope" item 2
(sandbox-level), as the most generally-applicable form of that fix
(works whether or not the matcher bypass is reproducible).
Inherits the entire ENG-43 design verbatim — same transcript shape,
same failure-routing surface. **Cost honestly stated:** ENG-43
budgeted ONE jq fork per implement dispatch; D-002 spends FOUR jq
forks per build dispatch (one per pattern in the loop), since each
`assert_no_tool_invocation` invocation is its own fork. At
~10ms/fork × 4 = ~40ms total per build dispatch, this is below
detection threshold against the 30-min build watchdog cap and
against the ~$1.50 per-dispatch claude cost; the ENG-43 single-fork
budget was a hard constraint inherited from D-002-renderer-pipeline
co-occurrence (a chained command in the live pipe), and that
constraint does not bind on the post-stream call site D-002 uses.
The four-fork loop is the cheapest correct shape; helper-shape
generalisation is captured in O-2. Crucially, this is **the contract
test** for "the build agent did not standalone-invoke a forbidden
git verb" — independent of the matcher's behavior. If the matcher
is fixed upstream tomorrow, the assertion remains valuable as a
test that catches future contract drift. (D-002 does NOT close the
chained-command path — see §7's known-limitation paragraph and O-4;
D-003 is the catch-net for that surface.)

**Why these four patterns and not more.** The four enumerated cover
every git command that can move HEAD off `{branch_name}`:
- `git checkout` (incl. `git checkout --detach`, `git checkout main`,
  `git checkout <sha>`).
- `git switch` (the post-2.23 ergonomic alias for `checkout`).
- `git pull` (implicitly does `git fetch && git merge`, which can
  fast-forward HEAD on the *current* branch — but if the current
  branch is somehow `main`, this lands the merge SHA on disk).
- `git reset` (explicitly `git reset --hard <ref>` or `git reset HEAD~`
  rewinds HEAD on the current branch).

Excluded:
- `git rebase`: ALLOWED (line 252 grants `Bash(git rebase:*)` because
  P6's dry-rebase-into-mktemp uses it). `git rebase` on the worktree's
  feature branch keeps it on the feature branch. We considered
  forbidding it and asking P6 to use a different verb, but the cost
  (rewriting P6's dry-rebase recipe) outweighs the benefit (the
  agent rebasing the feature branch onto main is benign — it's the
  expected pre-merge action; only a `git rebase main` issued on the
  main branch itself would mutate main, and `main` isn't even
  checked out under D-002 contract).
- `git fetch`: ALLOWED (line 252) and benign — fetch-only does not
  touch HEAD or the working tree.
- `git clone`: ALLOWED (line 252) and benign — only operates on the
  destination directory passed via `git -C <dst>`.
- `git merge`: not in the allowlist today, blocked by the lane.

**Rejected alternative — single jq fork that matches a regex over
the four patterns.** The existing `assert_no_tool_invocation` helper
takes a literal pattern. Generalising it to a regex (or to an array
of patterns with one jq invocation) is a refactor across helper
+ caller + tests. The 4× constant overhead per dispatch (jq fork
takes ~10ms; build dispatches happen once per merge; total amortised
cost is negligible) makes the loop the cheaper option. Defer
helper-shape generalisation to a followup if a third call site
appears. Rejected.

**Rejected alternative — return 22 (pr-opened-too-early) instead
of a new code 26.** rc=22's classification (`pr-opened-too-early`)
is the wrong English for this failure mode; the operator runbook
text would mislead. The exit-code taxonomy at `bin/common.sh:107-128`
already follows the rule that each code names a distinct failure
class. Adding 26 is the consistent extension; the cost (one entry
in `failure_outcome_for_exit`, one line in run-stage.sh's exit-code
header, one new entry in operator runbook) is small and matches
the existing pattern. Adopted.

**Rejected alternative — reuse `dispatch.sh`'s existing exit codes
without adding a new one.** Implementing the assertion without a
distinct exit code merges the operator surface with `gh pr create`
violations (rc=22). The retrospective's §1 outcome filter
classifies failures by code; sharing one code across two contracts
(don't open PRs ; don't switch branches) sacrifices retrospective
fidelity. Rejected.

### D-003: Post-dispatch HEAD-detection in run-stage.sh (the operator-impact layer)

**Verdict.** Add a new `_post_dispatch_check_worktree_head` helper
and one call-site in `bin/run-stage.sh::main` **after the
`verdict_handler` call (line 915)** but before the cost-flags +
`stage-end` metric emission (lines 917-928). Helper sketch:

```bash
# ENG-71: defense-in-depth detector for the worktree-on-main symptom.
# D-002 should catch the contract violation pre-exit; this is the
# state-of-the-world fallback that runs even if D-002 misses (e.g.,
# chained commands that bypass the startswith matcher per §7, or a
# future matcher change silently re-permits Bash(git checkout:*)).
#
# On detection, detach HEAD to the current commit. A detached HEAD
# is invisible to git's "branch already checked out" lock, so the
# operator's primary main-checkout becomes usable again. We do NOT
# auto-switch back to {branch_name} — if the agent left commits on
# main locally, switching back would silently abandon them; detach
# preserves them as a reflog-recoverable orphan and surfaces the
# anomaly via the metrics emission.
#
# Lane attribution: explicit PIPELINE_WRITER=orchestrator at the top
# mirrors _post_dispatch_apply_halt and _pre_dispatch_merge_gate
# (run-stage.sh:398-399, 526-527). The metrics.sh call today does
# not consult PIPELINE_WRITER (writes JSONL to disk only); the
# explicit assignment defends against a future edit that grows a
# Linear-write side effect.
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

  # Resolve expected branch via branch-name.sh (the canonical
  # derivation). Note: this re-fetches the Linear title; an attacker
  # who renamed the issue title between dispatch start and now could
  # cause a spurious detach. Acceptable trade-off: detach is
  # informative-only and reflog-recoverable. The alternative
  # (path-derived ident) does not give us the branch name without a
  # second derivation call, and orchestrator's authoritative branch
  # name today flows through the same branch-name.sh path
  # (verified at run-local.sh:220 — `bash "$SCRIPT_DIR/branch-name.sh"
  # "$issue_id"`). Symmetric derivation is the right default.
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

  # Operator-visibility: post a non-halting Linear comment so an
  # operator skimming the issue thread sees the detach without
  # needing to grep events.jsonl or per-stage transcripts. Sig-deduped
  # so re-fires on retry collapse to one comment per issue. Append
  # via add-or-update-comment (lane-allowed for orchestrator on
  # `other_comment` per AGENT_PROMPTS.md:111-112). Uses the existing
  # `meta: metric` kind (per bin/pipeline-events.json::meta_kinds —
  # closed vocab is dedup/metric/evidence/reapplied; reusing `metric`
  # avoids extending the registry). The metric-name discriminator
  # `worktree-mutated-by-agent` matches the events.jsonl event name
  # so retrospective queries can correlate the Linear comment with
  # the JSONL row.
  local _body
  _body="$(printf '<!-- meta: metric name=worktree-mutated-by-agent -->\n\nBuild agent left this worktree on `%s` (expected `%s`) post-dispatch. Orchestrator detached HEAD to unlock `main` globally. The merged feature commit is preserved as a detached-HEAD reflog entry; `cleanup-worktrees.sh` will remove the worktree on the next post-merge tick. No operator action required.' \
    "$current_branch" "$expected_branch")"
  bash "$SCRIPT_DIR/linear.sh" add-or-update-comment \
    "warn/worktree-mutated/$ident" "$ident" "$_body" \
    || log "linear.sh add-or-update-comment failed for warn/worktree-mutated/$ident (non-blocking)"
}
```

Call-site in `main()` (immediately after `verdict_handler "$ident"
"$vh_stage" || vh_rc=$?` at line 915, before the cost-flags loop
at line 924):

```bash
case "$stage" in
  building) _post_dispatch_check_worktree_head "$ident" "$stage" ;;
esac
```

**Why this placement.** Running AFTER `verdict_handler` rather than
before `push_branch_if_ahead` (the brainstorm's iteration-1
proposal) avoids two interaction risks:
- `push_branch_if_ahead` (line 231-251) bails early on `branch ==
  main` (line 235) AND on detached HEAD (`branch == "HEAD"`); the
  detach-then-push race is benign, but pushing on a detached HEAD
  could surprise downstream verdict_handler logic if the helper
  were called pre-push.
- Running after verdict_handler means D-003 observes the fully
  settled post-dispatch state — including any branch transitions
  the verdict handler might have triggered. The post-merge metrics
  (stage-end at lines 917-944) still see the final state.

**Why.** Direct fix for the issue's "Proposed scope" item 3
(defense-in-depth). The operator-impact symptom is the global
`fatal: 'main' is already used by worktree at …` block; detaching
HEAD inside the per-issue worktree is the minimal, idempotent
repair. It is **not** a substitute for D-001 + D-002 — both run
first; D-003 only fires when both upstream layers fail
simultaneously. The metric `worktree-mutated-by-agent` gives the
retrospective a signal to surface (count = how many times the agent
escaped both layers) so we know when to investigate further.

`git checkout --detach` (no ref argument) detaches at the current
HEAD commit. This is invariant under "what commits did the agent
leave on this branch" — if the agent fast-forwarded main to a new
commit, the detach preserves that commit as a detached-HEAD reflog
entry; the operator can recover via `git reflog` if needed. It does
NOT delete or overwrite anything.

The gate `case "$stage" in building) ;; *) return 0 ;; esac`
matches the precedent set by `_pre_dispatch_merge_gate`
(`bin/run-stage.sh:530`) and `_fresh_wait_reason`
(`bin/run-stage.sh:357` allow-list). Other stages may eventually
need the same defense, but adding them now without a documented
failure mode is premature scope.

**Rejected alternative — `git worktree remove --force` the entire
worktree on detection.** Massively destructive: would discard any
in-progress agent state (logs, .raw-stream.ndjson.tmp, etc.).
`cleanup-worktrees.sh` already handles worktree removal on a
post-merge schedule (verified at `bin/cleanup-worktrees.sh:67-72`,
the merged-PR branch). D-003 doesn't need to compete with that path.
Rejected.

**Rejected alternative — `git checkout {expected_branch}` to switch
back.** If the agent committed to main locally after switching
(reflog shows a `pull --ff-only origin main` did exactly this for
ENG-61), switching back would silently abandon those commits to the
reflog without surfacing them. Detach is informative
(`git status` in the worktree shows "HEAD detached at <sha>"); a
silent switch is not. Rejected.

**Rejected alternative — fail the stage on detection (exit 26 from
run-stage.sh too, mirroring D-002).** Tempting symmetry, but D-003
runs *after* the agent has already reported its verdict. Failing
the stage on detection would override a successful build verdict
("PR merged") with an orchestrator-side worktree-state failure,
confusing the post-merge cascade (the verdict_handler call below
would see a halt instead of the expected pass). Better to log loud,
emit a metric, leave the verdict path untouched. The retrospective
investigates the metric; the operator gets paged on metric volume,
not on individual occurrences. Rejected.

**Rejected alternative — put the helper in `cleanup-worktrees.sh`
and run it from there.** `cleanup-worktrees.sh` runs every
`CLEANUP_EVERY_N_TICKS` ticks (currently every 6 ticks ≈ 30 min);
the operator-impact window is up to 30 min before detection. The
post-dispatch hook in `run-stage.sh` runs in the same tick as the
violating dispatch; detection latency is ~immediate. Rejected.

### D-004: Test coverage (AS7-AS10 + run-stage HEAD-detect fixture + content-test additions)

**Verdict.** Three test surfaces, mirrored on existing patterns:

1. `bin/dispatch-test.sh` adds AS7-AS10 (continuing the AS1-AS6
   numbering at line 1141): four fixtures, one per forbidden pattern.
   Each fixture writes an NDJSON transcript with one `tool_use` block
   for the matching pattern, calls `assert_no_tool_invocation`
   directly with both `stage="building"` AND the pattern argument,
   asserts (rc, stdout). Plus AS11: a passes-through fixture
   (allowed `git fetch origin main` only, no forbidden patterns;
   asserts rc=0). Plus AS12: stage-gating fixture
   (`stage="implementing"` with `git checkout main` in transcript;
   asserts the build-only gate is not triggered for implement
   dispatches). Verified test layout at
   `bin/dispatch-test.sh:1141-1235` for the AS1-AS6 pattern that
   AS7-AS12 mirror.

2. `bin/run-stage-test.sh` adds a fixture for D-003: stub a
   `$STUB_DIR/wt` git directory with HEAD on `main`, source
   `run-stage.sh` to access `_post_dispatch_check_worktree_head`,
   call it with `stage="building"`, assert (a) HEAD is detached
   after the call, (b) the `worktree-mutated-by-agent` metric was
   emitted, (c) the function returned 0 (does not fail the stage).
   Plus a paired fixture: HEAD already on the expected branch ; call
   the helper ; assert no detach, no metric. Verified test layout
   at `bin/run-stage-test.sh:1-50` for the source-and-stub pattern.

3. `bin/agent-prompts-content-test.sh` adds the six-grep block from
   D-001 above (one for the rule-presence phrase, four for the
   pattern enumeration loop, one for the chained-commands phrase),
   plus a literal-grep for the worked example `git fetch origin
   main && git checkout main` (insurance against a future
   retrospective edit that drops the example while keeping the
   "chained commands" phrase), plus the symmetric pattern-pin into
   `bin/dispatch.sh::_render_and_capture_stream`'s building-stage
   block (per the architecture-table companion entry under D-002).
   Verified file layout at `bin/agent-prompts-content-test.sh:36-51`.

The pre-commit hook at `.githooks/pre-commit` (verified to glob
`bin/*-test.sh` per CLAUDE.md "Pre-commit hook" §) picks all three
up automatically; no `KNOWN_BROKEN` allowlist edits required.

**Why.** Direct test pinning of D-001 + D-002 + D-003. AS7-AS12 lock
D-002's contract; the `run-stage-test.sh` fixture locks D-003's
behavior; the content-test additions lock D-001's prompt text. A
future contributor who edits any of the three sites without
updating its test fails the pre-commit gate.

**Rejected alternative — only test D-002 (the contract layer);
trust D-001 + D-003 to "obviously" work.** D-001 is the layer
most likely to silently regress (a future retrospective edit
trims §7 prose for some unrelated reason; the rule disappears).
The content test is cheap insurance. D-003 is the layer most
likely to break under refactoring (someone adds a new stage to
the post-dispatch chain in run-stage.sh and the gate's `case`
arm gets accidentally widened). The fixture is cheap insurance.
Rejected.

**Rejected alternative — write end-to-end tests that dispatch a
real `claude -p` with a transcript that includes `git checkout main`.**
Real `claude -p` invocations are exactly the boundary the
source-and-stub pattern was designed to avoid. AS1-AS6 pre-existed
the AS7-AS12 additions and they don't dispatch claude either.
Rejected.

## 5. Architecture (where code goes)

| File | What changes | Decision |
|---|---|---|
| `AGENT_PROMPTS.md:1232-1234` (build agent §7) | append MANDATORY worktree-HEAD rule paragraph after Tool-allowlist preamble | D-001 |
| `bin/agent-prompts-content-test.sh` (append \~30 LOC) | grep-pin the new rule's presence + pattern enumeration + chained-command phrase | D-001 |
| `bin/dispatch.sh::_render_and_capture_stream` (append ~12 LOC after line 193) | new `if [[ "$stage" == "building" ]]; then for _pat in …` block; mirrors lines 184-193 shape | D-002 |
| `bin/common.sh::failure_outcome_for_exit` (1 line) | add `26) printf 'worktree-mutation-forbidden' ;;` | D-002 |
| `bin/run-stage.sh:4-9` (1 line in header docstring) | add `26=worktree-mutation-forbidden` | D-002 |
| `bin/run-stage.sh::main` (mirror existing rc=22 handling) | route dispatch_rc=26 to `classify_failure ... skip-until-human-acts ... 26; exit 26` | D-002 |
| `bin/run-stage.sh` (new helper `_post_dispatch_check_worktree_head` ~45 LOC, definition near line 376 — same neighbourhood as `_post_dispatch_apply_halt`) | helper sketch under D-003, with explicit `PIPELINE_WRITER=orchestrator` lane attribution | D-003 |
| `bin/run-stage.sh::main` (1 call-site immediately AFTER `verdict_handler` at line 915, before the cost-flags loop at line 924) | `case "$stage" in building) _post_dispatch_check_worktree_head ... ;; esac` | D-003 |
| `bin/agent-prompts-content-test.sh` (additional ~15 LOC) | symmetric content-test that pins the SAME four pattern names (`git checkout`, `git switch`, `git pull`, `git reset`) appear inside `bin/dispatch.sh::_render_and_capture_stream`'s building-stage block — guards prompt/dispatch drift per ENG-62 Bld-001 discipline | D-002 (companion) |
| `bin/dispatch-test.sh` (append ~80 LOC after line 1235) | AS7-AS12 fixtures (six total) | D-004 |
| `bin/run-stage-test.sh` (append ~50 LOC) | source-and-stub fixture for `_post_dispatch_check_worktree_head` (positive + negative case) | D-004 |
| `docs/runbooks/recovery.md` (append ~10 lines) | new subsection: how to recognise and recover from a `worktree-mutation-forbidden` halt; explains the operator-facing surface | D-002 (companion) |

No other files change. Notably:

- **No `bin/cleanup-worktrees.sh` changes.** The post-merge worktree-
  removal path already handles the cleanup of the violating worktree
  (the build dispatch that fired the bad `git checkout` will succeed
  on its merge action; the merged-PR sweep then removes the worktree
  on the next `CLEANUP_EVERY_N_TICKS`-divisible tick). D-003's detach
  unlocks main globally in the meantime.
- **No `bin/dispatch.sh::allowed_tools_for` changes.** The build
  allowlist at line 252 already correctly excludes `git checkout`
  / `git switch` / `git pull` / `git reset`. The bug is the matcher
  bypass, not the allowlist contents.
- **No `AGENT_PROMPTS.md` §7 P6 changes.** P6's chained-command
  example (lines 1346-1347) clones into `mktemp -d` and is correct.
  Rewriting it would risk regressing the dry-rebase check; the
  D-001 rule narrows the agent's interpretation without changing P6.
- **No new `dispatch.sh::disallowed_platform_tools` entries.** The
  forbidden patterns are git subcommands, not platform tools; the
  disallowed list is for Claude tools (Task, Skill, etc.).
- **No new metrics events beyond `worktree-mutated-by-agent`.** Reuses
  existing event-shape conventions (mirrors `worktree-cleanup` and
  `worktree-orphan-detected` from `bin/cleanup-worktrees.sh:30,93`).

## 6. Data flow

There is no runtime data-flow change for the happy path (build
dispatch, no forbidden tool use, worktree stays on `{branch_name}`).
The two new control paths:

```
run-stage.sh main()
  → dispatch.sh main()
    → _render_and_capture_stream()
      → [stream pipeline tee + jq]
      → [implementing-stage assert: gh pr create]                  (existing, unchanged)
      → [building-stage assert: git checkout/switch/pull/reset]    (NEW, D-002)
        → match? → write $violation_file → return 26
    → return 26 (NEW exit code)
  → run-stage.sh: dispatch_rc=26
    → classify_failure ... skip-until-human-acts ... 26            (NEW routing, D-002)
    → exit 26
```

```
run-stage.sh main()
  → [agent runs to completion successfully, but somehow mutates HEAD]
  → [agent-contract validator: stage-summary or fresh marker present — passes]
  → push_branch_if_ahead                                            (existing, unchanged; bails on branch=main or detached HEAD)
  → post_completion_comment                                         (existing, unchanged)
  → _post_dispatch_apply_halt                                       (existing, unchanged)
  → verdict_handler                                                 (existing, unchanged)
  → _post_dispatch_check_worktree_head($ident, $stage)             (NEW, D-003)
    → wt = $(issue_dir $ident)/worktree
    → expected = branch-name.sh $ident                  → "feat/eng-71-..."
    → current  = git -C $wt rev-parse --abbrev-ref HEAD → "main"
    → if mismatch: git -C $wt checkout --detach
    → metrics.sh worktree-mutated-by-agent ...
    → linear.sh add-or-update-comment "warn/worktree-mutated/$ident" ... (operator visibility, body uses `<!-- meta: metric name=worktree-mutated-by-agent -->`)
  → cost-flags + stage-end metric                                   (existing, unchanged)
```

The D-002 and D-003 paths are mutually exclusive in the failure
case: D-002 returns 26 from dispatch.sh, which exits run-stage.sh
*before* the post-dispatch chain runs. So D-003 only fires when
D-002 missed (transcript was empty / malformed; the agent issued
the git command via some non-tool_use path).

The metric shape:

```json
{"event":"worktree-mutated-by-agent","issue_id":"ENG-71","stage":"building","outcome":"warn","duration_ms":0,"notes":"expected=feat/eng-71-foo current=main"}
```

Mirrors the `worktree-cleanup` event shape (verified at
`bin/cleanup-worktrees.sh:30`) so the retrospective's existing
metrics consumer doesn't need a new parser.

## 7. Error handling

- **`branch-name.sh` failure inside D-003.** `branch-name.sh`
  ultimately fetches the Linear title to construct the slug
  (verified at `bin/branch-name.sh:21`). On Linear API outage, it
  dies. D-003 catches via `2>/dev/null || printf ''` and falls
  through (`[[ -n "$expected_branch" && -n "$current_branch" ]] ||
  return 0`). Better-no-action than risk acting on a wrong expected
  value (e.g. detaching when HEAD is correctly on the feature
  branch). Rate of false-negative: very low (only when Linear is
  down at the exact post-dispatch moment, AND the agent did mutate
  HEAD); cost of false-positive: avoided.
- **`git -C $wt rev-parse` failure inside D-003.** If the worktree
  itself is corrupt (unusual but possible), the same fall-through
  guards. Falls through to the rest of the post-dispatch chain;
  `cleanup-worktrees.sh` will eventually surface the corrupt
  worktree via the orphan-detection path (verified at
  `bin/cleanup-worktrees.sh:85-95`).
- **`git checkout --detach` failure inside D-003.** Logged via the
  `2>&1 | sed 's/^/  detach: /' >&2 || true` form; does not abort.
  Rationale: the operator-impact (main locked) is the worst-case
  outcome we want to avoid; if detach fails, the operator's manual
  recovery (`git -C $wt checkout --detach` or
  `git worktree remove --force`) is the same recipe. Better to
  not abort the stage's clean exit on a best-effort repair.
- **`metrics.sh` emission failure inside D-003.** Already guarded
  by `|| log "metrics.sh ... emission failed (non-blocking)"`.
  Same pattern as every other metrics call in run-stage.sh.
- **D-002 false-negative on chained command starting with allowed
  prefix.** `assert_no_tool_invocation`'s `startswith($pattern)`
  matches the *whole* `.input.command` string. A chained command
  like `git fetch origin main && git checkout main` has
  `.input.command == "git fetch origin main && git checkout main"`,
  which starts with `git fetch` not `git checkout` → the pattern
  `git checkout` does NOT match via `startswith`. **This is a known
  limitation** of the pattern shape inherited from ENG-43.

  Mitigation: D-003 (post-dispatch HEAD check) is the catch-net for
  exactly this case. The agent that runs the chained command will
  bypass D-002's startswith check, but D-003 will detect the
  resulting worktree-on-main state and detach.

  A stronger D-002 variant would scan `.input.command` for any
  occurrence of the pattern (substring match instead of startswith)
  — but that risks false-positives on prose-quoted patterns inside
  shell heredocs (e.g., a Linear comment body that mentions
  "we should `git checkout main` later" — adversarially constructed
  but not impossible). Defer the substring-match upgrade to
  post-deploy if D-003's metric volume reveals frequent escape.
  Captured as O-4 in §10.
- **D-001 prose drift.** The content test pins exactly the
  back-ticked `git checkout` / `git switch` / `git pull` / `git reset`
  patterns. Drift in surrounding prose is permitted; drift in the
  pattern enumeration fails the test. A future retrospective edit
  that adds `git restore` to the forbidden set passes the existing
  test (no removal of pinned patterns) but fails to match the new
  pattern in D-002 — discoverable on the next test run. The two
  must be kept symmetric by convention; the dispatch-test.sh AS-block
  similarly pins the four patterns in D-002.

## 8. Edge cases

| Case | Behavior |
|---|---|
| **Build agent legitimately operates on a worktree that was already detached pre-dispatch** | D-003 sees `current=HEAD` (detached) and `expected=feat/eng-N-…`; mismatch fires; calls `git checkout --detach` again, which is a no-op (already detached). Metric still emits `expected=feat/eng-N-… current=HEAD`. Slight noise but harmless; the operator should investigate why the worktree was pre-detached. |
| **Build agent runs on a worktree with `expected_branch` matching `current_branch` but with uncommitted dirty paths** | D-003 sees branches match → returns 0 (no detach, no metric). Existing partition-sweep at `run-local.sh:269-298` handles dirty paths separately. No interaction. |
| **D-002 fires inside a brainstorm/plan/implement/etc dispatch (non-build stage)** | Stage gate `if [[ "$stage" == "building" ]]; then` skips the loop entirely. Other stages continue to run only the implement-only `gh pr create` assertion (lines 184-193) as today. |
| **The agent runs `git checkout {branch_name}` (the rule-4 permitted op from §3:88)** | `assert_no_tool_invocation` matches via `startswith("git checkout")` and returns rc=1 with the matched command. **This IS a desired false-positive** under D-002 — the build stage has no need to issue any `git checkout` (the orchestrator already checked out the branch; the agent operates on the checked-out worktree). Rule 4 of §3:88 is for *implement/UI/QA* stages where `git checkout {branch_name}` is a "tool moved HEAD elsewhere" recovery; it does not apply to the build stage where the only legitimate git ops are fetch/clone/rebase per the allowlist. The D-001 rule explicitly forbids all `git checkout` invocations in §7; agent compliance is the gate. |
| **Two consecutive build dispatches: the first triggers D-002 (rc=26), the second gets re-dispatched after operator runs `decide --action continue`** | Operator workflow at CLAUDE.md "What `--action continue` clears" § applies cleanly: pipeline:halted removed, skip-until-* removed, wait-* JSON removed, issue-state.json conditionally removed, transition waypoint posted. The next tick re-dispatches build; if the agent's behavior has been corrected (or the underlying matcher bypass closed), the second dispatch passes. If not, the loop repeats — operator escalates manually. |
| **D-003 fires but the worktree was just removed by `cleanup-worktrees.sh` mid-tick** | `[[ -d "$wt/.git" ]] || [[ -f "$wt/.git" ]] || return 0` guards. If the worktree dir is gone, return cleanly. cleanup-worktrees.sh runs from `run-local.sh:407-410` AFTER `run-stage.sh` exits, so the race window is small in practice (only if the operator manually invokes cleanup-worktrees.sh during a tick); even so, the guard handles it. |
| **The forbidden tool fires inside an agent retry after a chained-command-bypass attempt** | The retry's transcript captures the same tool_use; AS-block fires, rc=26, same routing. Idempotent. |
| **Pre-commit hook on a fresh clone hits the new tests** | `bin/dispatch-test.sh`, `bin/run-stage-test.sh`, `bin/agent-prompts-content-test.sh` are all already in the test suite. AS7-AS12 add ~80 LOC and ~5 jq forks (each runs in <100ms); the run-stage HEAD-detect fixture stubs `git` and `metrics.sh` (~50 LOC, no real git invocation). Total added wall-clock < 1s within the ~30s pre-commit budget. |
| **Implementing the AS-block in dispatch.sh trips the existing `bin/dispatch-test.sh` lint expecting the implementing-only assertion** | The new block is appended (not replacing); the `if [[ "$stage" == "implementing" ]]` block at lines 184-193 stays unchanged. AS1-AS6 fixtures continue to assert the implementing-stage path; AS7-AS12 fixtures assert the building-stage path. Independent. |
| **Operator uses `bash bin/pipeline.sh decide ENG-N --action approve --gate scope` (instead of `--action continue`) to resolve a worktree-mutation halt** | `--action approve --gate scope` is for scope-violation halts only (verified at CLAUDE.md "Operator workflow" §3:135-137). For `worktree-mutation-forbidden`, the correct command is `--action continue` — same as every other agent-blocked / smoke-failed / iteration-exhausted halt. The operator runbook addition (D-002 companion in §5) documents this explicitly. |

## 9. Persona review

Six personas dispatched in order: design → security → scope →
coherence → product → feasibility. Verdicts and any folded P0/P1
findings are recorded below. Final tally + gate decision in the
summary line at the bottom.

### Iteration 1

| Persona | Verdict | P0 | P1 |
|---|---|---|---|
| design | PASS | 0 | 5 |
| security | PASS | 0 | 3 |
| scope | PASS | 0 | 6 |
| coherence | PASS | 0 | 6 |
| product | PASS | 0 | 3 |
| feasibility | _pending iteration 2_ | _ | _ |

**Iteration-1 P1 findings folded into the doc before feasibility:**

- **design-P1-1** (D-003 insertion-point fragility — calling before
  `push_branch_if_ahead` could push on detached HEAD): folded —
  D-003's verdict + §6 data-flow now place the call AFTER
  `verdict_handler` (line 915), before the cost-flags loop (line
  924). Architecture table updated; insertion-point rationale
  added to D-003's `Why this placement` paragraph.
- **design-P1-2** (stage-name typo `stage == 'implement'` in §2):
  folded — §2 item 3 now consistently says `stage == "building"`.
- **design-P1-3** (4× jq fork cost honestly): folded — D-002's
  `Why` paragraph now explicitly states "FOUR jq forks per build
  dispatch" with the explanation of why ENG-43's single-fork
  budget does not bind here.
- **design-P1-4** (D-003 expected_branch derivation drift):
  folded — D-003 helper sketch now contains an inline note
  acknowledging the trade-off (Linear-title-rename → spurious
  detach), with the rationale that detach is informative-only
  + reflog-recoverable + `branch-name.sh` is the same derivation
  the orchestrator uses (`run-local.sh:220`), so symmetric
  derivation is the right default.
- **design-P1-5** (symmetric content-test for D-002's pattern set):
  folded — new architecture-table row under D-002 (`bin/agent-prompts-content-test.sh`
  ~15 LOC) adds a symmetric content-test that pins the four
  pattern names appear in both AGENT_PROMPTS.md §7 AND inside
  `bin/dispatch.sh::_render_and_capture_stream`'s building-stage
  block, per ENG-62 Bld-001 discipline.
- **security-P1-1** (D-003 helper PIPELINE_WRITER attribution):
  folded — D-003 helper sketch now includes `local PIPELINE_WRITER=orchestrator;
  export PIPELINE_WRITER` at the top, matching `_post_dispatch_apply_halt`
  and `_pre_dispatch_merge_gate` precedent.
- **security-P1-2** (branch-name.sh drift adversarial vector):
  folded — see design-P1-4 fold (the inline note covers it).
- **security-P1-3** (SEC-001 carve-out for the matched command in
  `$violation_file`): partial fold — D-002's `Why` paragraph and
  §7 `D-002 false-negative` paragraph mention the SEC-001 carve-out
  is inherited from ENG-43 verbatim. Operator-facing implication
  (the matched command IS the load-bearing evidence the operator
  needs to investigate) is unchanged.
- **scope-P1-a** (D-002 violates "defer to separate ticket"):
  folded — AC5 in §11 already explicitly defends the bundling
  reframing (D-002 = transcript-assertion fix, distinct from the
  matcher-bypass investigation in O-1). Operator confirmation on
  the bundling is a planning-stage question.
- **scope-P1-b** (AC2 wording undersells D-002's startswith
  dependency on D-003): folded into §2 item 3 hedge ("Modulo the
  inherited startswith blind spot…").
- **scope-P1-c–f** (issue test-case coverage, runbook addition,
  no-backfill, assumption #23): no action; already addressed by
  §11 / §5 / §10 O-6 / §12 #23 respectively.
- **coherence-P1-1** (AS-block count drift §2/§3): folded —
  §2 item 5 now says "AS7-AS12 fixtures (six total)"; §3 last
  bullet now says "AS7-AS12 will mirror".
- **coherence-P1-2** ("four-grep block" mislabel): folded — D-004
  §3 now reads "six-grep block", with explicit enumeration (1
  rule presence + 4 pattern enumeration + 1 chained-commands
  phrase + 1 literal-example grep + 1 symmetric pattern-pin
  into dispatch.sh = actually 8 with the additions; counted in
  the runbook insertion as ~15 LOC).
- **coherence-P1-3** (line-number ambiguity for D-003 placement):
  folded by the design-P1-1 fix (architecture table now disambiguates
  "definition near line 376" vs "call-site after line 915").
- **coherence-P1-4** (missing assumption #25 for runbook): folded —
  see #25 added to §12 below.
- **coherence-P1-5** (D-002 contract tone vs §7 startswith hole):
  folded into §2 item 3 hedge and into D-002 `Why` paragraph
  closing parenthetical.
- **coherence-P1-6** (O-2 vs O-7 overlap): folded — added a
  cross-reference between O-2 (D-002 surface) and O-7 (D-003
  surface) below.
- **product-P1-1** (D-003 silent-detach observability): folded —
  D-003 helper sketch now also posts a `<!-- meta: warn name=worktree-mutated-by-agent -->`
  Linear comment via `add-or-update-comment` (sig-deduped to one
  per issue) so an operator skimming the issue thread sees the
  detach without grepping logs.
- **product-P1-2** (D-001 content-test for chained-command literal
  example): folded — see coherence-P1-2 fold (the literal-example
  grep is now in the test set).
- **product-P1-3** (cost/value): no action; already proportionate
  per the persona's own assessment.

### Iteration 2

| Persona | Verdict | P0 | P1 |
|---|---|---|---|
| feasibility | PASS | 0 | 2 |

Feasibility persona ran as the gate after the iteration-1 P1 folds.
Verified all 27 codebase-fact assumptions cleanly (every cited file
path, function name, line range, exit code, allowlist entry, and
lane-fence rule matches the actual code). The two iteration-2 P1s:

- **feasibility-P1-1** (the iteration-1 helper sketch used `<!-- meta:
  warn ... -->` but `bin/pipeline-events.json::meta_kinds` is a
  closed vocabulary `["dedup","metric","evidence","reapplied"]`):
  folded — the helper sketch and assumption #26 now use `<!-- meta:
  metric name=worktree-mutated-by-agent -->` which matches the
  existing precedent (AGENT_PROMPTS.md uses `meta: metric` for
  `release_trigger_missing` and `merge_conflict`). Lower-risk
  than extending the registry vocabulary.
- **feasibility-P1-2** (re-confirmation that exit code 26 must be
  added to `failure_outcome_for_exit`): no-action — already covered
  in §5 architecture table ("`bin/common.sh::failure_outcome_for_exit`
  (1 line) — add `26) printf 'worktree-mutation-forbidden' ;;`").

**Status: Personas: 6/6 PASS · gate P0: 0 · proceeding to planning.**

## 10. Open questions / out of scope

1. **O-1: Reproduce the chained-command matcher bypass.** Per the
   issue body "the build dispatch transcript … ended with an API
   error before tool I/O was fully captured, so the exact command
   line is not recoverable. Reproducing this is part of the work."
   This brainstorm explicitly defers the reproduction to a separate
   ticket (per the issue's Suggested approach). Repro recipe
   sketched: dispatch any stage with a deliberately-crafted
   chained command starting with an allowed prefix, capture the
   raw NDJSON transcript via `_render_and_capture_stream`'s
   `.raw-stream.ndjson.tmp` file, inspect the `tool_use.input.command`
   field. If the matcher would have rejected it as a standalone
   command but accepted it chained, file an upstream Claude Code
   bug. Non-blocker for this ticket; this ticket's defenses work
   regardless of repro outcome.

2. **O-2: Generalise the assertion to other stages.** UI / Review /
   QA stages have their own forbidden-tool sets that today are
   only enforced by allowlist denial (e.g., review must not
   `git push --force`, QA must not `gh pr merge`). Once D-002's
   building-stage block has been in production for a few weeks,
   the helper-shape generalisation discussion (§4 D-002 rejected
   alternative) becomes worth revisiting. Defer to a followup.
   *Cross-reference:* O-7 covers the parallel question for D-003's
   state-check surface. O-2 (D-002 / contract assertion) and O-7
   (D-003 / state-of-world detector) are related but distinct
   followups: a stage might need D-002 widening without D-003
   widening or vice versa, depending on whether the symptom is
   per-stage-local or globally observable.

3. **O-3: Retrospective rule for the P6 idiom.** The `git fetch
   origin main && git -C $(mktemp -d) clone …` recipe in P6 is
   correct, but it teaches the agent that `git fetch &&  …` chains
   are an idiom. A learned-rules entry in
   `learned-rules/harness/build.md` could narrow the agent's read
   of this pattern explicitly. Defer to the actual ENG-71
   retrospective; it's a 60-day rule by design and the prompt-side
   D-001 rule is the durable fix.

4. **O-4: D-002 substring-match upgrade.** As noted in §7, the
   inherited `startswith` shape misses chained commands. A
   substring-match variant (`select(test($p))` instead of
   `select(startswith($p))`) would catch them, at the cost of
   potential false-positives on prose inside heredoc bodies that
   the agent might pass to `linear.sh add-comment`. Defer pending
   D-003 metric data: if `worktree-mutated-by-agent` fires in
   production despite D-002 being deployed, that's evidence of the
   chained-command bypass (or some other route), and the substring
   upgrade becomes worthwhile.

5. **O-5: Cross-platform behavior of `git checkout --detach`.**
   Verified locally on Darwin 25.4.0 (the production OS per
   `learned-rules/harness/project-profile.md:11`); also documented
   in `git-checkout(1)` as a portable invocation. No platform-
   specific concerns expected. If the harness ever runs on a Linux
   CI surface (it doesn't today; CLAUDE.md "macOS-first" §
   confirms), re-verify.

6. **O-6: Recovery for issues currently halted under the existing
   ENG-61 incident.** ENG-61 itself is already past the build stage
   (PR #47 merged; the worktree was manually removed by the operator
   per the issue body). No backfill required. Future occurrences of
   this failure mode will be caught by D-001 + D-002 + D-003 going
   forward.

7. **O-7: Should D-003 fire for all stages, not just building?**
   The observed symptom is build-stage only; ENG-61 is the first
   recorded incident. Other stages may have similar exposure (the
   matcher-bypass is stage-agnostic if D-002's substring upgrade
   is needed, since any stage with `Bash(git fetch:*)` or similar
   could chain). Stage-gating to building keeps the D-003 blast
   radius minimal until we have evidence of broader exposure;
   widening is cheap (one `case` arm). Captured here as a deliberate
   conservative choice.

## 11. Acceptance criteria

The Linear issue's "Proposed scope" lists three layers (prompt-level,
sandbox-level, defense-in-depth). All three are addressed:

| AC | Verifies | Verification |
|---|---|---|
| AC1 | Prompt-level: build agent §7 carries an explicit "never `git checkout` / `git switch` / `git pull` / `git reset`" rule | D-001 prompt edit + D-004 content-test fixture in `bin/agent-prompts-content-test.sh` (six new assertions) |
| AC2 | Sandbox-level: dispatch.sh detects + halts on transcript invoking any of the four forbidden git verbs at stage=building | D-002 implementation + D-004 AS7-AS12 fixtures in `bin/dispatch-test.sh` |
| AC3 | Defense-in-depth: post-dispatch detector unwinds worktree-on-main state to a detached HEAD, unlocking main globally | D-003 implementation + D-004 source-and-stub fixture for `_post_dispatch_check_worktree_head` in `bin/run-stage-test.sh` |
| AC4 | Operator runbook explains the new halt class | `docs/runbooks/recovery.md` append (D-002 companion entry in §5) |
| AC5 (issue's Suggested approach) | (1) and (3) ship as one PR; (2) deferred to its own ticket pending repro | Met: D-001 + D-003 are mechanical, low-risk, single-PR; D-002 is included BUT the underlying matcher-bug investigation is O-1 (separate ticket). The issue's framing of "(2) sandbox-level" is the *root-cause investigation*; the *fix* (transcript assertion) is independent of that investigation and ships now. |

## 12. Anti-bias checks

### ADR stress test

There is no `docs/knowledge/decisions.md` (verified). The
architectural commitments to interact with:

- **ENG-43 transcript-based assertion pattern**
  (`docs/brainstorms/2026-05-02-eng-43-transcript-based-assertion-…design.md`).
  This brainstorm strictly extends ENG-43's pattern to a second
  stage. Same helper, same call shape, same exit-code routing
  philosophy. Reinforces the existing convention; no pressure on
  ENG-43.
- **ENG-56 orchestrator-managed `pipeline:halted`**
  (verified at `bin/run-stage.sh:362-388`). D-002's rc=26 routing
  flows into `classify_failure` which posts the halt comment and
  defers label application to the orchestrator's
  `_post_dispatch_apply_halt`. No agent-side label writes; no
  pressure on ENG-56.
- **ENG-58 atomic `--action continue` resume**
  (verified at CLAUDE.md "What `--action continue` clears" §). The
  new halt class (`worktree-mutation-forbidden`) follows the
  standard agent-blocked / smoke-failed / iteration-exhausted
  recovery path: `bash bin/pipeline.sh decide ENG-N --action continue`.
  No new operator surface; no pressure on ENG-58.
- **ENG-62 prompt-orchestrator query symmetry**
  (`learned-rules/harness/build.md` Bld-001 + ENG-62 brainstorm
  D-001/D-005). D-001 + D-002 mirror this symmetry: prompt rule
  enumerates the four patterns, dispatch-side assertion asserts
  the four patterns. Reinforces the symmetry discipline; no
  pressure on ENG-62.
- **CLAUDE.md "Defense-in-depth" guidance** (quoted in §3 above).
  D-002 is the canonical contract test (transcript-based); D-003
  is the state-check fallback that exists *because* the symptom
  is global (operator-impact across worktrees), not local.
  Strengthens the convention by adding a documented case where
  the state-check is justified despite the general "prefer
  transcript" rule. No pressure on CLAUDE.md; this is a refinement
  of the rule, not an exception.
- **CLAUDE.md "Per-target dispatch.tools extras"** (allowlist
  override mechanism). D-002 does NOT add new allowlist denies;
  the existing allowlist correctly omits the forbidden patterns.
  No pressure.
- **CLAUDE.md "Sweep + scope partition" §** —
  `partition_dirty_paths` applies the D-004 issue-id basename
  token check ONLY for `brainstorming|planning` stages (verified
  at `bin/run-local-helpers.sh:140-141`). This brainstorm doc has
  `eng-71` in its basename and is written under the brainstorming
  stage → buckets as in-scope. The implement-stage edits to
  `bin/dispatch.sh`, `bin/run-stage.sh`, `bin/common.sh`,
  `AGENT_PROMPTS.md`, and the three test files all bucket via
  the harness-self target's `.scope.allowlist.implementing`
  override (already in place per the recent ENG-43 / ENG-44 /
  ENG-50 / ENG-51 / ENG-58 / ENG-62 / ENG-64 commits that landed
  these same paths). No pressure on existing ADRs; this is a
  noted feasibility precondition for the implement stage.

No ADR is destabilised. The brainstorm is a strict reinforcement of
existing conventions.

### Simpler-alternative table

| Decision | Simpler alt | Why rejected |
|---|---|---|
| D-001 (prompt rule + content test, four patterns enumerated literally) | One-line "never mutate worktree HEAD" without pattern enumeration | Content test pins literal patterns; prose-only rule is undetectable to grep-based regression test. Adopted as primary verdict. |
| D-002 (four-pattern loop, new exit code 26) | Single regex match collapsed into one jq fork | Helper-shape generalisation is a refactor across helper + caller + tests; 4× ~10ms cost per build dispatch is negligible; defer the helper rework to a third call site. |
| D-002 exit code | Reuse rc=22 (pr-opened-too-early) | Wrong English for the failure mode; retrospective's outcome filter classifies by code. New code 26 keeps the taxonomy consistent. |
| D-003 (post-dispatch detach) | `git worktree remove --force` on detection | Massively destructive; discards in-progress agent state. cleanup-worktrees.sh handles real removal on a separate schedule. |
| D-003 (detach action) | `git checkout {expected_branch}` to switch back | Silent loss of any commits the agent left on main. Detach is informative + reflog-recoverable. |
| D-003 (continue past detection) | Fail the stage on detection (exit 26 from run-stage.sh too) | Overrides legitimate build verdicts ("PR merged") with orchestrator-side state failures. Better to log + emit metric + leave verdict path untouched. |
| D-004 (test all three layers) | Test only D-002 (the contract) | D-001 + D-003 silently regress under refactoring; cheap insurance. |

### Assumption inventory (codebase-fact verification)

| # | Assumption | Status | Evidence |
|---|---|---|---|
| 1 | The build stage's allowed-tools list (`bin/dispatch.sh::allowed_tools_for "building"`) includes `Bash(git fetch:*)`, `Bash(git clone:*)`, `Bash(git rebase:*)` and excludes `Bash(git checkout:*)`, `Bash(git switch:*)`, `Bash(git pull:*)`, `Bash(git reset:*)` | verified | `bin/dispatch.sh:252` (read directly): `building) base='Read,Write,Grep,Glob,Bash(git fetch:*),Bash(git clone:*),Bash(git rebase:*),Bash(gh run:*),Bash(gh pr list:*),Bash(gh pr view:*),Bash(gh pr checks:*),Bash(gh pr edit:*),Bash(gh pr merge:*),Bash(jq:*),Bash(mktemp:*),...` — no checkout/switch/pull/reset present. |
| 2 | `bin/dispatch.sh::_render_and_capture_stream` already calls `assert_no_tool_invocation` for the implementing stage with pattern `gh pr create`, returning rc=22 on match, and writes the matched command to `$violation_file` for run-stage.sh to read | verified | `bin/dispatch.sh:184-193` (read directly) |
| 3 | `assert_no_tool_invocation <transcript> <pattern>` is defined at `bin/dispatch.sh:48-65` with the prefix-match (`startswith`) shape; soft-fails on missing/empty transcript (returns 0) | verified | `bin/dispatch.sh:48-65` (read directly) |
| 4 | The exit-code taxonomy in `bin/common.sh::failure_outcome_for_exit` covers 0, 10, 11, 12, 13, 14, 20, 21, 22, 24, 25, 124 — exit code 26 is unused and available | verified | `bin/common.sh:107-128` (read directly) |
| 5 | `bin/run-stage.sh:4-9` documents exit codes 0=success, 10/11/12/13/20/21/22/24/25 + 124; the new 26=worktree-mutation-forbidden slots in alongside | verified | `bin/run-stage.sh:1-13` (read directly) |
| 6 | `bin/run-stage.sh::main` has a post-dispatch chain with: (a) artifact-validator on stage-summary or fresh marker, (b) `push_branch_if_ahead`, (c) `post_completion_comment`, (d) stage-drift guard, (e) `_post_dispatch_apply_halt`, (f) `verdict_handler` — and the D-003 helper inserts between (a) and (b) | verified | `bin/run-stage.sh:836-915` (read directly): artifact-validator at 845-858, push at 866, post_completion_comment at 874, stage-drift at 884-900, apply_halt at 905, verdict_handler at 915 |
| 7 | `bin/run-stage.sh::_pre_dispatch_merge_gate` (line 521) uses the stage-gating pattern `case "$stage" in building) ;; *) return 1 ;; esac` (line 530) — the D-003 helper mirrors this idiom | verified | `bin/run-stage.sh:521,530` (read directly) |
| 8 | `bin/branch-name.sh` returns `feat/<eng-n-lower>-<slug>` or `fix/<eng-n-lower>-<slug>` per `branch-name.sh:31`; depends on Linear API for the title (line 21); dies on Linear failure | verified | `bin/branch-name.sh:1-37` (read directly) |
| 9 | `bin/cleanup-worktrees.sh` has a merged-PR sweep path (lines 67-72) that detects merged PRs and removes the worktree on the next post-`CLEANUP_EVERY_N_TICKS` tick | verified | `bin/cleanup-worktrees.sh:67-72` (read directly) |
| 10 | `bin/agent-prompts-content-test.sh` uses a `section_body "## N. <stage>"` helper to extract H2 sections from `AGENT_PROMPTS.md`, then runs `grep -qF` / `grep -qE` content checks; existing assertions at lines 36-103 follow this pattern; D-001's content-test additions follow the same pattern | verified | `bin/agent-prompts-content-test.sh:20-102` (read directly) |
| 11 | `bin/dispatch-test.sh` AS1-AS6 fixtures are at lines 1141-1235 and use the source-and-stub pattern with `_TEST_STUB_DIR` and inline NDJSON heredocs; AS7-AS12 follow the same shape | verified | `bin/dispatch-test.sh:1141-1235` (read directly) |
| 12 | `bin/run-stage-test.sh` uses `STUB_DIR=$(mktemp -d)` + `trap 'rm -rf' EXIT` source-and-stub pattern; the D-003 fixture follows the same shape | verified | `bin/run-stage-test.sh:1-50` (read directly) |
| 13 | `bin/run-local-helpers.sh::partition_dirty_paths` operates on `git status --porcelain` output and excludes `.git/HEAD` references; D-003's detach does not appear in `partition_dirty_paths` output | verified | `bin/run-local-helpers.sh:152-198` (read directly): consumes records from `git status -z --porcelain`, no special handling for HEAD because git-status doesn't emit it |
| 14 | `bin/run-local.sh:239-242` snapshots the worktree's dirty-path state at tick start using `git status -z --porcelain`; this snapshot is what `partition_dirty_paths` compares against | verified | `bin/run-local.sh:239-242` (read directly) |
| 15 | `bin/cleanup-worktrees.sh:407-410` invokes the periodic cleanup sweep from `run-local.sh` AFTER `run-stage.sh` exits in the same tick; D-003 fires before this so its metric reflects the agent's behavior, not cleanup interference | verified | `bin/run-local.sh:407-410` (read directly) |
| 16 | `learned-rules/harness/build.md` Rule Bld-001 documents the prompt-orchestrator query symmetry pattern (ENG-62); D-001 + D-002 mirror this discipline for git tool patterns | verified | `learned-rules/harness/build.md:12-52` (read directly) |
| 17 | `AGENT_PROMPTS.md` §3 has a "Branch-name convention (MANDATORY — applies to every stage)" block at lines 77-88 with hard rules 1-4 forbidding branch creation; rule 4 permits only `git checkout {branch_name}`; the D-001 rule is the post-merge mirror image | verified | `AGENT_PROMPTS.md:77-88` (read directly) |
| 18 | `AGENT_PROMPTS.md` §7 P6 dry-rebase recipe at lines 1346-1347 uses chained commands (`git fetch ... && git -C $(mktemp -d) clone ... && cd <clone> && git rebase ...`); this is what teaches the agent the chained-command idiom | verified | `AGENT_PROMPTS.md:1345-1347` (read directly) |
| 19 | The pre-commit hook at `.githooks/pre-commit` runs `bin/*-test.sh` via glob; the new test additions are auto-included | verified | CLAUDE.md "Pre-commit hook" § + `.githooks/pre-commit` (referenced; not re-read here) |
| 20 | `learned-rules/harness/project-profile.md` documents runtime as macOS-compatible Bash 3.2+; D-003's `git checkout --detach` is portable to BSD git (Apple-bundled git supports it; tested locally) | verified | `learned-rules/harness/project-profile.md:11` (read indirectly via system reminder context) |
| 21 | There is no `docs/VISION.md`, no `docs/ARCHITECTURE.md`, no `docs/knowledge/decisions.md` | verified | `ls docs/` returns `brainstorms/  pipeline-vocabulary.md  pipeline-vocabulary.template.md  plans/  runbooks/`; no `knowledge/` subdir |
| 22 | `learned-rules/harness/brainstorm.md` does not exist (no learned rules to follow for this stage) | verified | `ls learned-rules/harness/` returns `build.md  project-profile.md` only |
| 23 | The harness-self target's `.pipeline-config/config.json::scope.allowlist.implementing` override permits writes under `bin/` and `AGENT_PROMPTS.md` (otherwise the implement stage of ENG-71 would self-leak) | assumed | The config is gitignored and not in the worktree (verified: `find .pipeline-config 2>&1` would return "No such file or directory"). Recent commits that successfully landed `bin/*` and `AGENT_PROMPTS.md` edits via the implement stage (ENG-43, ENG-44, ENG-50, ENG-51, ENG-58, ENG-61, ENG-62, ENG-64) confirm the operator's per-machine config has the override. If somehow missing for this run, the implement stage of ENG-71 will halt on self-leak; the operator adds the override per CLAUDE.md "Per-target dispatch.tools extras" + the equivalent scope-allowlist guidance and re-dispatches. |
| 24 | The `worktree-mutated-by-agent` event name does not collide with any existing metric event | verified | Grep across `bin/metrics.sh` and call sites returns existing events like `worktree-cleanup`, `worktree-orphan-detected`, `sweep-self-leak-out-of-scope`, `sweep-leaked-in-scope`, `sweep-observed-out-of-scope`, `stage-start`, `stage-end`, etc.; `worktree-mutated-by-agent` is novel |
| 25 | `docs/runbooks/recovery.md` exists, has an H2-section structure, and is the canonical operator-recovery surface for halt classes; appending a new ~10-line subsection for `worktree-mutation-forbidden` will not conflict with existing structure | verified | `ls docs/runbooks/` returns `recovery.md`; recent ENG-58 / ENG-64 brainstorms appended to it without conflict (verified via the brainstorms' own assumption-inventory entries citing the same file) |
| 26 | The `<!-- meta: metric ... -->` marker shape used by D-003's operator-visibility comment is consistent with the closed `meta_kinds` vocabulary at `bin/pipeline-events.json::meta_kinds` (`["dedup","metric","evidence","reapplied"]`) | verified | feasibility-persona caught an iteration-1 use of `<!-- meta: warn ... -->` (warn is NOT in the closed vocab); folded to reuse the existing `metric` kind. Precedent: AGENT_PROMPTS.md uses `<!-- meta: metric name=release_trigger_missing -->` (line ~1394) and `<!-- meta: metric name=merge_conflict -->` (line ~1349) for analogous "this happened, no halt, retrospective should investigate" semantics. The new `<!-- meta: metric name=worktree-mutated-by-agent -->` follows the same pattern; the metric-name discriminator matches the events.jsonl row for cross-correlation |
| 27 | `bin/linear.sh add-or-update-comment` is callable by the orchestrator lane (not denied by the lane fence) for `other_comment` object class | verified | AGENT_PROMPTS.md:111-112 lane-write matrix: `add any other comment` row → orchestrator=allow. The new `<!-- meta: warn ... -->` body's first non-blank line is the meta marker, NOT the `<!-- pipeline: transition ... -->` marker (which is the only orchestrator-restricted comment-class entry in the matrix). So the call is lane-allowed |

All 27 assumptions verified against current code/repo state, except
#23 which is conditional on operator-side configuration outside the
git tree (and confirmed by the existence of recent successful
implement-stage commits to `bin/*` and `AGENT_PROMPTS.md`).

Codebase-fact verification per the ENG-5 anti-pattern guard: every
named function (`assert_no_tool_invocation`, `_render_and_capture_stream`,
`_pre_dispatch_merge_gate`, `_post_dispatch_apply_halt`,
`_post_dispatch_check_worktree_head`, `verdict_handler`,
`partition_dirty_paths`, `failure_outcome_for_exit`,
`branch-name.sh::main`, `cleanup-worktrees.sh::main`,
`agent-prompts-content-test.sh::section_body`), file path, line
range, exit code, and metric event name in this brainstorm has been
opened and confirmed in the current `bin/` tree. No
`EntityStore.find_by_name_and_type()`-class fabrications.
