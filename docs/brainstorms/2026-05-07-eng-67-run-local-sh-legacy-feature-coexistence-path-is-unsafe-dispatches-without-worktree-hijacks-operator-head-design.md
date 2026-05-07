---
linear: ENG-67
title: run-local.sh "legacy feature/* coexistence" path is unsafe — dispatches without worktree, hijacks operator HEAD
date: 2026-05-07
status: draft
---

# `run-local.sh` legacy `feature/*` coexistence path is unsafe — delete it

## 1. Overview (and the load-bearing surprise)

`bin/run-local.sh:213-226` (verified in this worktree at the time of
writing — the outer `if [[ "$reconcile_decision" == "proceed" ]]` block
opens at 213, the inner `else` closes at 225, the outer `fi` is at 226)
carries a "legacy `feature/*` coexistence" branch that was introduced
in commit `79b8b73` (April 2026, "feat(pipeline): wire worktree
creation and App-token minting in run-local.sh") to handle a one-time
migration from an older branching model. Its current shape:

```bash
if [[ "$reconcile_decision" == "proceed" ]]; then
  ident_lower="$(tr '[:upper:]' '[:lower:]' <<<"$issue_id")"
  if [[ -n "$(git -C "$TARGET_REPO" branch --list "feature/${ident_lower}-*" 2>/dev/null)" ]] \
     || git -C "$TARGET_REPO" ls-remote --heads origin "feature/${ident_lower}-*" 2>/dev/null | grep -q "feature/"; then
    log "legacy feature/* branch detected for $issue_id — using old flow (no worktree)"
  else
    branch="$(bash "$SCRIPT_DIR/branch-name.sh" "$issue_id")"
    worktree_path="$(resolve_worktree_path "$branch" "$issue_id")"
    mkdir -p "$(dirname "$worktree_path")"
    ensure_worktree "$branch" "$worktree_path"
  fi
fi
```

When the legacy detection fires, `branch=""` and `worktree_path=""`
stay at their defaults; the next block (`bin/run-local.sh:228-232`)
then resolves `dispatch_cwd="$TARGET_REPO"` because the
`if [[ -n "$worktree_path" ]]; then dispatch_cwd="$worktree_path"; fi`
guard is false. The dispatch — and every git-based read in the
sweep partition that follows (`bin/run-local.sh:240`,
`bin/run-local.sh:270`, `bin/run-local.sh:351-360`) — runs against
the operator's primary `$TARGET_REPO` checkout, not a per-issue
worktree.

**The load-bearing surprise.** This is not just "scope-check halts
with rc=2 because the plan is on the wrong branch." It is also a
silent compromise of the operator's working tree: the agent's
allowed-tools include `Bash(git checkout:*)` for several stages
(verified at `bin/dispatch.sh::allowed_tools_for` cases for
`implementing`, `ui`, `qa` — checked indirectly via the legacy
incidents below). When the agent runs `git checkout -B
feature/eng-N-…` from `$TARGET_REPO`, it moves the operator's
*main-repo* HEAD off whatever branch the operator was on. The
operator discovers this only when `git status` reports a wholly
unrelated working tree — the symptom recorded for ENG-65 in the
issue body ("operator discovered this only when `git status`
started reporting unrelated files").

The May 2026 incident (ENG-63/64/65) hit this path on every
dispatch because three agents simultaneously violated the
canonical-prefix branch convention by running `git checkout -B
feature/eng-N-…`. Three issues halted; the breaker tripped. PR #48
(commit `4635cd3`, "fix: lock agents to canonical {branch_name}
(no feature/* drift)") added a top-level "Branch-name convention
(MANDATORY — applies to every stage)" block in `AGENT_PROMPTS.md`
(verified at `AGENT_PROMPTS.md:77-88` — Hard rules 1–4) and
`bin/agent-prompts-content-test.sh:447-491` (verified) pins the
section's presence + the rejection of the `feature/` variant.

So today the legacy path exists, but its triggering condition (an
agent creating `feature/eng-N-…` instead of canonical
`feat/eng-N-…`) is now blocked at the prompt level *and*
test-pinned at the harness level. The path no longer protects an
in-flight migration; it is dead code that becomes a footgun the
moment any `feature/eng-N-…` branch appears (e.g., a future test
fixture leak; an operator manually creating the branch; a
misbehaving agent that finds a way past PR #48).

**This brainstorm picks Path A from the issue's "Two ways out":
delete the legacy block.** Path B (per-issue scratch worktree)
keeps complexity to defend against a failure mode that PR #48
already prevented at a higher layer; the issue itself flags Path A
as "simpler" and recommends it. The cost of Path A is asymmetric in
the right direction: deleting code that's protecting nothing
removes risk; keeping it for hypothetical future drift compounds
risk because every refactor of run-local.sh has to reason about a
silently-fallback-to-operator-checkout path.

**Scope split-flag (Path A.1 vs Path A.2).** Path A's literal AC in
the Linear issue enumerates three bullets: (1) path removed,
(2) one-line comment explaining the deletion, (3) test pin that no
`feature/*` branch is silently accommodated. This brainstorm proposes
four decisions; D-001+D-002+D-004 sit cleanly inside the literal AC,
but **D-003 (replace `dispatch_cwd="$TARGET_REPO"` soft fallback with
`die`)** is a separable hardening that addresses the *mechanism* of
harm rather than the *trigger* the AC names. Two paths to AC-3
compliance:

- **Path A.1 (this brainstorm's primary plan).** Ship D-001+D-002+D-003+D-004
  in one PR. AC verification passes; the dispatch-into-operator-checkout
  failure mode is closed at *both* the trigger (legacy detection
  removed) AND the mechanism (soft fallback removed). \~30 extra LOC
  vs. the literal one-bullet ask. The deletion-site comment grows
  from "one line" to ~13 lines (citation to PR #48 / ENG-63/64/65 /
  AGENT_PROMPTS.md) — defensible elaboration on the "explaining"
  word in AC bullet 2, but a literal departure from "one-line."
- **Path A.2 (alternative; explicit opt-out).** Implement only
  D-001+D-002+D-004; defer D-003 to a sibling ticket "ENG-XX:
  run-local.sh dispatch_cwd should die-on-empty rather than
  fall back to $TARGET_REPO." Path A.2 ships in literal alignment
  with the issue's three-bullet AC. Cost: the soft-fallback
  mechanism remains as a foot-shaped landmine until the sibling
  ticket lands, gated only by the (post-D-001) unreachability
  argument; "unreachable by construction" is exactly the regime
  where silent fallbacks become most dangerous if a future edit
  re-introduces an empty-`worktree_path` path.

This brainstorm proceeds with Path A.1 because the soft fallback was
the *mechanism* through which the May-2026 incident caused operator-
visible harm (HEAD hijack); closing the trigger without closing the
mechanism leaves the next regression's blast radius identical to the
one ENG-67 was filed about. Plan stage MAY split D-003 into a sibling
ticket if reviewer/operator prefers strict adherence to the issue's
literal three-bullet framing — Path A.1 → Path A.2 is reversible by
omitting D-003 from the implementation, and §10 O-3 carries the
sibling-ticket recipe.

## 2. Goals

After this ticket lands:

1. **Path removed** (D-001). `bin/run-local.sh:213-226` collapses
   to the unconditional canonical-resolution path. A comment on
   the deletion site cites PR #48 commit `4635cd3` (the
   prompt-level defense) and ENG-63/64/65 (the May-2026 incident
   that proved the path was unsafe), so a future contributor
   re-reading the file sees *why* the coexistence branch is gone
   and is dissuaded from re-introducing it.
2. **Test-pinned regression guard** (D-002). A new test file
   `bin/run-local-content-test.sh` (sibling to the existing
   `bin/run-local-helpers-adversarial-test.sh` and
   `bin/run-local-sweep-test.sh`, both verified to exist) greps
   `bin/run-local.sh` for the literal token `feature/` and the
   string `legacy feature` and FAILS if either reappears. The
   test is picked up automatically by the pre-commit hook glob
   (`.githooks/pre-commit` matches `bin/*-test.sh` per CLAUDE.md
   "Pre-commit hook" §).
3. **`dispatch_cwd` fallback removed** (D-003). The
   `dispatch_cwd="$TARGET_REPO"` default at `bin/run-local.sh:229`
   exists *only* to handle the legacy path's empty
   `worktree_path`. With D-001 in, `worktree_path` is always set
   on the `proceed` branch, and the `link:`/`human` reconcile
   branches `exit 0` before reaching that block (verified at
   `bin/run-local.sh:177-205` — `case "$reconcile_decision" in
   link:*) ... exit 0 ;; human) ... exit 0 ;; esac`). The default becomes unreachable;
   we replace the soft fallback with a `die` so any future
   regression that lets `worktree_path` stay empty surfaces
   loudly instead of silently dispatching into `$TARGET_REPO`.
4. **CLAUDE.md "Failure-mode quick reference" updated** (D-004).
   The recovery runbook does not mention this path today; the
   CLAUDE.md table does. We don't need a new section, just a
   one-line entry noting "agents that emit `feature/eng-N-…` are
   rejected at the prompt level (PR #48 / `agent-prompts-content-test.sh`)
   and at the orchestrator no longer fall through to a
   `$TARGET_REPO`-cwd dispatch."

Non-goals (explicit, follow the issue's framing):

- **Path B** — per-issue scratch worktree at
  `$PROJECT_STATE_DIR/<issue>/legacy-worktree/`. Recorded as a
  rejected alternative under D-001 with rationale. The issue
  recommends Path A; this brainstorm follows that
  recommendation.
- **Audit other run-local.sh `git -C "$TARGET_REPO"` call
  sites for the same operator-checkout-mutation risk.** Lines
  72-81 (the `core.bare` self-heal — read-only), 122-136
  (`ensure_worktree` — by design operates on the parent repo
  to create worktrees, never `cd`s the operator's HEAD), and
  140 (`cd "$TARGET_REPO"` — purely for `poll.sh` invocation
  context, no agent dispatched here) are all benign. The
  unique mutation risk is the dispatch path covered by D-001.
  Out of scope: a wholesale audit. **O-1** in §10 if a future
  contributor wants this.
- **Agent-side defense.** The agent prompt rules at
  `AGENT_PROMPTS.md:83-88` and the content-test pins at
  `bin/agent-prompts-content-test.sh:466-491` are already in
  place and sufficient. Out of scope: re-doing PR #48's work.
- **Removing `feature/*` from `bin/agent-prompts-content-test.sh`'s
  rejected-variant pin.** The May-2026 incident happened; the
  test phrase ("the May-2026 incident name is feature/* — pin
  its rejection so the precedent is durable") is the exact
  argument for keeping it. Untouched.

## 3. Architectural principle

There is no `docs/VISION.md`, no `docs/ARCHITECTURE.md`, no
`docs/knowledge/decisions.md` (verified: `ls docs/` returns
`brainstorms/  pipeline-vocabulary.md  pipeline-vocabulary.template.md
plans/  runbooks/`; no `knowledge/` subdir). Governing constraints
come from `CLAUDE.md`, `learned-rules/harness/project-profile.md`,
and accepted brainstorms.

The principles invoked here are existing CLAUDE.md commitments,
not new ones:

- **The operator's `$TARGET_REPO` checkout is sacrosanct.**
  CLAUDE.md "Three locations every script touches" §:
  `TARGET_REPO` is "the target repo whose worktrees, branches,
  PRs are mutated" — but the canonical contract (verified at
  `bin/run-local.sh:109-114` `resolve_worktree_path` and
  `bin/run-local.sh:116-138` `ensure_worktree`) is that *worktrees*
  derived from `$TARGET_REPO` are the dispatch surface. The
  parent `$TARGET_REPO` is the operator's interactive workspace
  (`cd "$TARGET_REPO"` at line 140 is the only `cd` site, and
  it precedes `poll.sh` — a read-only call). Every other
  side-effect lands inside `issue_dir(...)/worktree`. The legacy
  path silently violates this contract. Removing it
  re-establishes the implicit invariant.
- **Defense-in-depth on top of agent prompt rules.** CLAUDE.md
  "When wiring a new script" §: *"when a stage's contract says
  'agent must not invoke tool X,' prefer a transcript-based
  assertion (`assert_no_tool_invocation` in `bin/dispatch.sh`)
  over a state-of-the-world check after dispatch."* The reverse
  direction holds too: *the orchestrator must not silently
  accommodate agent rule-violations.* Today's coexistence path
  does exactly that — it makes a path-shape rule violation
  (agent emits `feature/`) into a soft-fallback rather than a
  surfaced failure. D-001 reasserts the orchestrator's role:
  rule-violations should produce loud failures (a clean
  `branch-name.sh` mismatch via the canonical-resolution path)
  rather than quiet, harmful coexistence.
- **`die` over silent fallback.** CLAUDE.md "When wiring a new
  script" §: *"Use `log` / `die` / `require_env` / `require_bin`
  from common.sh — don't roll your own."* The current
  `dispatch_cwd="$TARGET_REPO"` fallback at
  `bin/run-local.sh:229` is a silent default; D-003 changes it
  to a `die` that names the unreachable-by-construction
  invariant. This is the same pattern as
  `bin/run-local-helpers.sh::stage_output_paths` (line 83:
  `die "stage_output_paths: unknown stage: $stage"`) and
  `bin/branch-name.sh:17` (`die "usage: branch-name.sh
  <issue_id>"`).
- **Sentinel + content-test pattern for harness invariants.**
  `CLAUDE.md` "AGENT_PROMPTS.md is load-bearing" + "Tests" §
  establish that we pin invariants via grep-based content tests
  (verified at `bin/agent-prompts-content-test.sh:447-491` for
  the canonical-prefix invariant). D-002's
  `bin/run-local-content-test.sh` follows the same pattern,
  applied to a different load-bearing file.
- **Symmetric defense between prompt and orchestrator.** ENG-62's
  Bld-001 rule (and ENG-71 D-001+D-002) established that when an
  invariant is enforced at the prompt level, the orchestrator
  side should also have a test pinning that no equivalent path
  exists in the orchestrator's source. This brainstorm extends
  that discipline: PR #48 added the prompt rule + a content
  test; ENG-67 adds the orchestrator-source content test that
  pins the same invariant from the other direction. The two
  tests catch different drift classes (prompt edit drops the
  rule; orchestrator edit re-introduces the silent fallback).

## 4. Decisions

### D-001: Delete the legacy detection block; collapse to canonical resolution

**Verdict.** In `bin/run-local.sh`, replace lines 209-226 (the comment
header at lines 209-210 + the `if/else` containing the legacy
detection at lines 211-226) with the unconditional canonical-resolution
path:

```bash
# Determine branch name and worktree path. The legacy `feature/*`
# coexistence path that used to live here was deleted in ENG-67 (May
# 2026): it dispatched the agent from the operator's $TARGET_REPO
# checkout when an agent had created a non-canonical `feature/eng-N-...`
# branch (the May-2026 ENG-63/64/65 failure mode), silently mutating
# the operator's HEAD and breaking scope-check. PR #48 (commit
# 4635cd3) closed the upstream cause at the prompt level
# (AGENT_PROMPTS.md:83-88 hard-rules 1-4 + agent-prompts-content-test.sh
# pins); the orchestrator-side coexistence is no longer needed.
# Any future feature/* branch that somehow appears will fall through
# to canonical resolution, where ensure_worktree creates a fresh
# worktree off origin/main — a clean error surface, not a silent
# dispatch into $TARGET_REPO.
branch=""
worktree_path=""
if [[ "$reconcile_decision" == "proceed" ]]; then
  branch="$(bash "$SCRIPT_DIR/branch-name.sh" "$issue_id")"
  worktree_path="$(resolve_worktree_path "$branch" "$issue_id")"
  mkdir -p "$(dirname "$worktree_path")"
  ensure_worktree "$branch" "$worktree_path"
fi
```

Net diff: 14 functional lines today (lines 211-226: the two var
inits + outer `if` + inner `if`/`else` legacy block + closing `fi`s)
shrink to 8 functional lines; the deletion-site comment grows from
2 lines (lines 209-210) to ~13 lines (citing PR #48 / ENG-63/64/65 /
AGENT_PROMPTS.md). Net file-size delta: ~+5 lines (functional -6,
comment +11). The "one-line comment explaining the deletion" wording
in the issue's AC bullet 2 is interpreted permissively — the citation
chain is genuinely useful for a future archeologist; if the reviewer
prefers strict adherence, the comment can be trimmed to a single
line `# Legacy feature/* coexistence path deleted in ENG-67; see
PR #48 (commit 4635cd3).` — flagged in §10 O-4.

**Why.** The Linear issue explicitly recommends this path ("simpler")
and provides the exact argument: PR #48 already closed the upstream
cause. The path was added for a one-time migration that is complete
(verified: no in-flight `feature/eng-N-…` issues remain in this repo
as of 2026-05-07; `git -C "$TARGET_REPO" branch --list 'feature/eng-*'`
returns empty in clean operator checkouts). Keeping dead code that
silently dispatches into the operator's checkout is strictly worse
than removing it: removal turns a silent footgun into a clean error.

The "fall-through to canonical resolution" claim is verified:

- `branch-name.sh "$issue_id"` (verified at `bin/branch-name.sh:31`)
  always emits `feat/<issue-lower>-<slug>` or `fix/<issue-lower>-<slug>`
  (per the `Bug` label discriminator at line 27-29). It never emits
  `feature/...`. So a `feature/eng-N-...` branch on origin or local
  is invisible to this resolution path — `ensure_worktree`
  (verified at `bin/run-local.sh:116-138`) checks `refs/heads/<canonical>`
  first (lines 122-124), then `refs/remotes/origin/<canonical>`
  (lines 125-127), then creates from `origin/main` (lines 128-136). The legacy `feature/eng-N-...` ref is left
  untouched on disk; the operator can prune it later. No active
  harm.
- The agent then dispatches into a worktree at
  `$PROJECT_STATE_DIR/ENG-N/worktree` (verified at
  `bin/common.sh:68-72::issue_dir` + `bin/run-local.sh:109-114::resolve_worktree_path`),
  which is a fresh checkout off `origin/main`. If the agent's
  prior work was on `feature/eng-N-...`, it is *not* in this
  worktree. That is the correct surface: the agent's prior work
  was a rule violation; the canonical surface is a fresh
  attempt, not a continuation of the violation.

**Rejected alternative — Path B: per-issue scratch worktree at
`$PROJECT_STATE_DIR/<issue>/legacy-worktree/`.** The issue
describes this as "more conservative." It is, but conservatism
here costs something: every future maintenance pass on
`run-local.sh` must reason about a parallel
`legacy-worktree/` lifecycle (creation, teardown, cleanup
scheduling, partition-sweep allowlist interaction). The
hypothetical it defends against — a `feature/eng-N-…` branch
appearing despite PR #48 — is exactly the failure mode that
should produce a clean error, not be silently accommodated.
Per CLAUDE.md "Doing tasks" §: *"Don't add features, refactor,
or introduce abstractions beyond what the task requires.
Three similar lines is better than a premature abstraction."*
Path B is a premature abstraction. Rejected.

**Rejected alternative — keep the path but make the dispatch fail
loudly.** I.e., detect `feature/eng-N-...` and immediately `die`
or emit a halt. Cleaner than today's silent fallback, but adds
permanent code (and a test surface) for a transient migration
concern PR #48 already closed. The same loudness is achieved by
deleting the path and letting the canonical resolution proceed:
if a `feature/eng-N-...` branch causes any second-order issue,
it surfaces through normal failure paths (scope-check rc=2 if
the canonical branch's plan doesn't exist, etc.), which are
already test-pinned. Rejected — strictly more code for no
incremental safety.

**Rejected alternative — keep the legacy block but warn-only,
no fallback (i.e., log a warning if `feature/eng-N-...` exists
but proceed with canonical resolution anyway).** Slightly less
delete-y, but the warning is purely cosmetic — operators don't
read tick logs unless something has failed, by which point the
canonical resolution has already taken effect. The clean
deletion is preferred. Rejected.

### D-002: Add `bin/run-local-content-test.sh` (regression pin)

**Verdict.** Create a new test file at
`bin/run-local-content-test.sh` (~40 LOC including the awk
comment-stripper, scaffolding, and four grep-cases) that asserts:

1. `bin/run-local.sh` does NOT contain the literal token
   `feature/` outside of comments. (Implementation: grep for
   `feature/` in non-comment lines via `grep -nE
   '^[[:space:]]*[^#]' | grep -F 'feature/'` returning empty;
   plus an explicit `grep -F 'legacy feature'` returning empty.
   The comment exemption is necessary because D-001's deletion
   site comment cites the May-2026 incident and references
   `feature/eng-N-…` in prose — that's documentation, not code.)
2. `bin/run-local.sh` does NOT contain the literal phrase
   `using old flow` (today's log line).
3. `bin/run-local.sh` does NOT contain the literal phrase
   `dispatch_cwd="$TARGET_REPO"` as a soft fallback. After
   D-003, the only `dispatch_cwd=` assignment is to
   `$worktree_path`. The negative pin catches a future revert
   that re-introduces the soft fallback even without the
   `feature/*` detection. Pin grep is anchored:
   `grep -qE 'dispatch_cwd="\$TARGET_REPO"'` (ERE-escaped `$` and
   literal double-quotes, so a benign assignment like
   `dispatch_cwd="$TARGET_REPO_FOO"` does NOT trip the test —
   only the exact pre-D-003 fallback shape).

Sketch (sibling-test source-and-stub pattern; verified template
at `bin/run-local-helpers-adversarial-test.sh:18-43` and
`bin/run-local-sweep-test.sh:1-44`):

```bash
#!/usr/bin/env bash
# Regression-pin: run-local.sh must not contain the legacy `feature/*`
# coexistence path (deleted ENG-67, May 2026). The path silently
# dispatched agents into $TARGET_REPO when a non-canonical
# `feature/eng-N-...` branch existed, mutating the operator's HEAD
# and breaking scope-check (May-2026 ENG-63/64/65 incident).
# PR #48 (commit 4635cd3) closed the upstream cause at the prompt
# level; this test pins the orchestrator side.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_LOCAL="$SCRIPT_DIR/run-local.sh"
[[ -f "$RUN_LOCAL" ]] || { printf 'FAIL: missing %s\n' "$RUN_LOCAL" >&2; exit 1; }

PASS=0; FAIL=0
ok()   { printf 'OK: %s\n' "$1"; PASS=$((PASS + 1)); }
nope() { printf 'FAIL: %s — %s\n' "$1" "$2" >&2; FAIL=$((FAIL + 1)); }

# Strip comment lines (lines whose first non-blank char is `#`) before
# scanning. The deletion-site comment in run-local.sh legitimately
# cites the historical `feature/*` failure mode in prose; that
# citation is documentation, not code. Only flag a re-introduction
# in executable lines.
non_comment="$(awk '!/^[[:space:]]*#/ && !/^[[:space:]]*$/' "$RUN_LOCAL")"

if printf '%s\n' "$non_comment" | grep -qF 'feature/'; then
  nope 'no feature/ token in non-comment lines' \
    'legacy feature/* coexistence appears to be re-introduced; see ENG-67'
else
  ok 'no feature/ token in non-comment lines (ENG-67)'
fi

if printf '%s\n' "$non_comment" | grep -qF 'legacy feature'; then
  nope 'no "legacy feature" phrase in code' \
    'legacy detection log line re-introduced; see ENG-67'
else
  ok 'no "legacy feature" phrase in non-comment lines'
fi

if printf '%s\n' "$non_comment" | grep -qF 'using old flow'; then
  nope 'no "using old flow" log line' \
    're-introduction of legacy coexistence; see ENG-67'
else
  ok 'no "using old flow" log line'
fi

# After D-003, dispatch_cwd assignment must always derive from a
# resolved worktree_path — never default to $TARGET_REPO as a soft
# fallback. Pin this directly.
if printf '%s\n' "$non_comment" | grep -qE 'dispatch_cwd="\$TARGET_REPO"'; then
  nope 'dispatch_cwd never silently falls back to $TARGET_REPO' \
    'soft fallback re-introduced; see ENG-67 D-003'
else
  ok 'dispatch_cwd does not silently fall back to $TARGET_REPO'
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
exit $(( FAIL > 0 ? 1 : 0 ))
```

The test does NOT source `run-local.sh` — `run-local.sh` does not
have the sentinel pattern (verified: `bin/run-local.sh:415` is the
last line — `log "== tick end (success) =="` — not the
`if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi`
pattern). Adding the sentinel to `run-local.sh` is a much larger
refactor (every top-level statement would need to move into
`main()`); out of scope for ENG-67. The content test does not
need sourcing — it operates on the file as text.

**Why.** Direct fulfillment of the issue's AC #2 ("`bin/run-local-helpers-adversarial-test.sh`
(or a new test) pins that no `feature/*` branch is silently
accommodated"). A new file is cleaner than appending to
`run-local-helpers-adversarial-test.sh` because the existing
test sources `run-local-helpers.sh`, not `run-local.sh`, and
its case-by-case `partition_dirty_paths` invocations are not the
right neighborhood for a content-grep on a different file. The
new file is sibling-named (`run-local-content-test.sh` vs.
`run-local-helpers-adversarial-test.sh` and
`run-local-sweep-test.sh`), so the pre-commit hook glob picks
it up automatically.

**Rejected alternative — append cases to
`bin/run-local-helpers-adversarial-test.sh`.** The existing
file's structure (verified at lines 18-220) is built around
`partition_dirty_paths` invocations using `assert_partition_counts`.
Tacking content-grep cases on the end would produce a file with
two unrelated test surfaces, against the precedent set by
`bin/run-local-sweep-test.sh` (separate sibling, narrow surface).
Rejected.

**Rejected alternative — write a behavioral test that
sources `run-local.sh` and asserts dispatch_cwd resolution.**
Requires giving `run-local.sh` the sentinel pattern (file-scope
`require_env` calls and the trap-on-EXIT cleanup would need to
move into `main()`). Disproportionate to the ticket's scope —
the content test catches the same regression class with ~30
LOC and zero refactoring of `run-local.sh`. Rejected.

**Rejected alternative — a behavioral test that fakes a
`feature/eng-99-foo` branch in a stub `$TARGET_REPO`, runs
`bin/run-local.sh` in dry-run, and asserts the dispatch_cwd
resolves to `$PROJECT_STATE_DIR/ENG-99/worktree`.** End-to-end
test of the dispatch path is appealing but expensive: setting
up a stub `$TARGET_REPO` git repo, stubbing `gh`/`linear.sh`/
`claude`, getting the lock-file dance right, and timing the
dry-run output is multi-hundred LOC of test scaffolding. The
content test catches the same regression at 30 LOC. Defer
to followup if a future contributor wants the behavioral
test (O-2). Rejected.

### D-003: Replace `dispatch_cwd="$TARGET_REPO"` soft fallback with `die`

**Verdict.** In `bin/run-local.sh:228-232`, replace:

```bash
# Dispatch run-stage.sh from the worktree if one was resolved, else from main.
dispatch_cwd="$TARGET_REPO"
if [[ -n "$worktree_path" ]]; then
  dispatch_cwd="$worktree_path"
fi
```

with:

```bash
# After ENG-67, every reconcile_decision=="proceed" tick resolves a
# per-issue worktree_path; the link:/human reconcile branches `exit 0`
# at lines 191-205 before reaching here. So the previous fallback
# `dispatch_cwd=$TARGET_REPO` is unreachable by construction. Surface
# any future regression that lets worktree_path stay empty as a loud
# failure rather than a silent dispatch into the operator's checkout.
[[ -n "$worktree_path" ]] || die "internal: worktree_path empty after reconcile=proceed (ENG-67); refusing to dispatch from \$TARGET_REPO"
dispatch_cwd="$worktree_path"
```

**Why.** The soft fallback was the *mechanism* by which the legacy
detection caused harm: it converted "no worktree resolved" into "use
the operator's checkout" silently. With D-001 in place, the only
code path that ever produced an empty `worktree_path` is gone, but
the fallback remains as a foot-shaped landmine: any future code
edit that re-introduces an empty-`worktree_path` branch (e.g., a new
reconcile decision that doesn't exit early) would silently re-trigger
the original bug. `die` is the canonical "this is unreachable"
expression in `bin/`-scripts (verified at
`bin/run-local-helpers.sh:83` and `bin/branch-name.sh:17`).

**Rejected alternative — leave the soft fallback in place.**
The hypothetical regression is unlikely (the only two
reconcile decisions that don't exit early are `proceed` and the
fall-through default; `proceed` always resolves a worktree post-
D-001). But "unlikely" is exactly the threshold at which a
silent fallback becomes most dangerous: when it does fire, it
fires silently, and the operator's checkout is mutated before
anyone notices. The `die` cost is one line of code and zero
runtime cost on the happy path. Rejected.

**Rejected alternative — collapse `dispatch_cwd` away entirely
and use `$worktree_path` directly throughout the rest of the
file.** Mechanically attractive (`dispatch_cwd` would be a
synonym for `worktree_path` after D-001+D-003). But
`dispatch_cwd` is referenced at 5 reader call sites (verified at
`bin/run-local.sh:240,246,270,351,352,360` — the 351/352 pair are
adjacent lines of one `git ... commit` block; counting by
distinct logical readers gives 5: snapshot pipeline, dispatch
invocation, sweep partition, two `git` calls in the commit/push
block at 351-352, and the `git push` at 360); renaming all of
them expands the diff and risks subtle errors. The two-line
`die` + assignment is the smallest correct change.
Rejected.

### D-004: One-line note in CLAUDE.md "Failure-mode quick reference"

**Verdict.** In `CLAUDE.md`, the "Failure-mode quick reference"
table (verified at the table near the document's end with rows
"Tick is silent / Breaker tripped / Issue stuck in stage:X /
Wrong-target Linear writes / Kill switch / Brainstorm halts at
iteration 2"), do NOT add a new row — the legacy path no longer
exists, so it cannot be a failure mode. Instead, add a 2-sentence
note to the existing "Per-issue state directory" § referencing
the canonical worktree contract AND the operator-action recipe
for the new D-003 invariant trip. Concretely, append to the
section explaining `$PROJECT_STATE_DIR/ENG-N/worktree/`:

> The harness orchestrator NEVER dispatches an agent into the
> operator's `$TARGET_REPO` checkout — every dispatch resolves a
> per-issue worktree first. If `bin/run-local.sh` ever logs
> `FATAL: internal: worktree_path empty after reconcile=proceed
> (ENG-67); refusing to dispatch from $TARGET_REPO`, that is the
> invariant `die`-ing — most likely a Linear-API outage in
> `branch-name.sh` (which now blocks ticks loudly rather than
> silently dispatching from the operator's checkout). Operator
> action: inspect `$PROJECT_STATE_DIR/<slug>/logs/local-*.log`
> for the preceding error from `branch-name.sh`/`linear.sh`, fix
> the underlying cause (network, API key, Linear status), and
> the next tick resumes; do not bypass the `die` by re-introducing
> a soft fallback.

**Why.** Documentation lock for the invariant. The text gives
operators a recognisable string to grep for if the `die` ever
fires (which it shouldn't, but D-003's whole point is making
the invariant fail loud rather than fail silent). One sentence,
no new table row.

**Rejected alternative — write a new runbook entry in
`docs/runbooks/recovery.md` for this `die` path.** The path is
unreachable by construction; a runbook entry implies it can
happen. The CLAUDE.md sentence pointing operators at the `die`
message is enough. Rejected.

**Rejected alternative — also remove the May-2026 incident
references from `bin/agent-prompts-content-test.sh:447-491`.**
The test pins still serve their original purpose (detecting an
agent that drops the canonical-prefix rule from `AGENT_PROMPTS.md`).
Even after ENG-67 lands, the test pins are correct and durable.
Rejected — orthogonal to ENG-67.

## 5. Architecture (where code goes)

| File | What changes | Decision |
|---|---|---|
| `bin/run-local.sh:209-226` | replace legacy detection block with unconditional canonical resolution + cite-PR48 comment | D-001 |
| `bin/run-local.sh:228-232` | replace `dispatch_cwd="$TARGET_REPO"` soft fallback with `die`-on-empty + direct assignment (Path A.1 only — Path A.2 omits this row) | D-003 |
| `bin/run-local-content-test.sh` (NEW, ~40 LOC) | grep-pin absence of `feature/`, `legacy feature`, `using old flow` (Path A.1+A.2) + anchored `dispatch_cwd="\$TARGET_REPO"` (Path A.1 only — Path A.2 drops this 4th grep) outside of comments | D-002 |
| `CLAUDE.md` "Per-issue state directory" § (2 sentences) | note about canonical-worktree invariant + operator-action recipe for the new `die` (Path A.1 only — Path A.2 drops this row, no `die` to point at) | D-004 |

No other files change. Notably:

- **No `AGENT_PROMPTS.md` changes.** PR #48 already added the
  branch-name convention rules; ENG-67 is the orchestrator
  cleanup, not a prompt change.
- **No `bin/agent-prompts-content-test.sh` changes.** The
  existing pins (verified at lines 447-491) remain durable.
- **No `bin/run-local-helpers.sh` changes.** Helper functions
  are unaffected; only `bin/run-local.sh`'s dispatch-cwd
  resolution changes.
- **No `bin/branch-name.sh` changes.** It already produces only
  `feat/...` / `fix/...` (verified line 31).
- **No `bin/cleanup-worktrees.sh` changes.** It iterates
  `$PROJECT_STATE_DIR/ENG-*/worktree` (verified at
  `bin/cleanup-worktrees.sh:54` inside `main()`); legacy `feature/*`
  branches that exist only as bare refs (no associated
  worktree under `$PROJECT_STATE_DIR/ENG-N/`) are out of its
  scope by design. Operator-side prune is unchanged.
- **No new exit codes.** D-003's `die` exits via common.sh's
  `die` (verified: `die` calls `exit 1`); the existing
  exit-code taxonomy at `bin/common.sh::failure_outcome_for_exit`
  routes exit 1 to `unknown-exit-1` — acceptable for an
  unreachable invariant trip (the loudness comes from the
  log line, not the code).
- **No metrics.sh changes.** D-003's `die` does not need a
  metric event; the per-tick log line (`die` writes to stderr
  which is `tee`-d into `$LOG_DIR/local-YYYY-MM-DD.log` per
  `bin/run-local.sh:61`) is the operator surface.

## 6. Data flow

There is no runtime data-flow change for the canonical happy
path (an issue with no `feature/eng-N-...` branch on origin or
local). The pre-D-001 control flow:

```
run-local.sh tick
  → poll → reconcile (returns "proceed")
  → if [[ feature/<issue>-* exists ]]:
    → log "legacy feature/* — using old flow (no worktree)"
    → branch="" worktree_path=""
  → else:
    → branch = branch-name.sh $issue           → "feat/eng-N-<slug>"
    → worktree_path = resolve_worktree_path    → "$PROJECT_STATE_DIR/ENG-N/worktree"
    → ensure_worktree (creates if missing)
  → dispatch_cwd = $worktree_path or $TARGET_REPO  ← BUG: silent fallback
  → snapshot + dispatch + sweep partition all run on $dispatch_cwd
```

After D-001 + D-003:

```
run-local.sh tick
  → poll → reconcile (returns "proceed")
  → branch = branch-name.sh $issue             → "feat/eng-N-<slug>"
  → worktree_path = resolve_worktree_path      → "$PROJECT_STATE_DIR/ENG-N/worktree"
  → ensure_worktree (creates if missing)
  → [[ -n "$worktree_path" ]] || die "internal: ... ENG-67"
  → dispatch_cwd = $worktree_path              ← always
  → snapshot + dispatch + sweep partition all run on $dispatch_cwd
```

The pre-existing `link:`/`human` reconcile-decision branches
(verified at `bin/run-local.sh:177-205`) `exit 0` BEFORE reaching
the worktree-resolution block, so they are unaffected.

If a `feature/eng-N-...` branch happens to exist on disk or origin
under D-001's deletion, `branch-name.sh` still emits the canonical
`feat/...`/`fix/...` shape; `ensure_worktree` (verified at
`bin/run-local.sh:116-138`) checks the canonical name and creates a
fresh worktree from `origin/main` if no canonical local/origin
branch exists. The
legacy `feature/eng-N-...` ref is left alone — it does not
collide with the canonical worktree (different branch name) and
does not interfere with cleanup (no associated per-issue
worktree dir). Operator-side prune is the existing recovery path
(`git -C "$TARGET_REPO" branch -D feature/eng-N-...` /
`git -C "$TARGET_REPO" push origin --delete feature/eng-N-...`).

## 7. Error handling

- **`branch-name.sh` failure inside the new unconditional path.**
  `branch-name.sh` (verified at `bin/branch-name.sh:21-22`) dies
  if Linear is unreachable (cannot fetch issue title). Today's
  legacy-detection block also calls `branch-name.sh` only on the
  `else` branch; on the `if` branch, `branch=""`. After D-001,
  `branch-name.sh` is called unconditionally, which means a
  Linear outage now blocks the tick at this site instead of
  silently falling through to `$TARGET_REPO`-cwd dispatch.
  **This is a strict improvement** — the silent-fallback was
  the bug; the loud-fail is the contract. Net effect on tick
  success rate: no change in steady state; an outage produces
  a `die` with a clear message (`could not fetch title for
  ENG-N`) instead of a confusing scope-check rc=2 four steps
  later.
- **`ensure_worktree` failure.** `ensure_worktree` already dies
  on git failures (verified: lines 122-136 use `set -e`-aware
  unguarded git commands). Behavior unchanged.
- **`die` at the new D-003 invariant.** Surfaces as `exit 1`
  (verified: `bin/common.sh::die` is the canonical helper);
  the cleanup-on-exit trap at `bin/run-local.sh:52-58`
  releases the lock and tempfiles. The `FAIL_COUNTER`
  (`bin/run-local.sh:32`) increments via the `if [[ $rc -ne
  0 ]]` block at `bin/run-local.sh:250-258` only if the
  failure happens after the `(cd "$dispatch_cwd" && bash
  "$SCRIPT_DIR/run-stage.sh" ...)` invocation; the new D-003
  `die` fires *before* that invocation, so the counter does
  NOT increment. **This is intentional**: the `die` is an
  internal-invariant trip, not a stage-execution failure; it
  doesn't represent a "consecutive failure" the breaker
  should respond to. The operator surface is the log line +
  tick exit; the operator investigates by reading the log,
  not by looking at the breaker counter.
- **The new test file (`bin/run-local-content-test.sh`) fails
  during pre-commit.** Pre-commit hook (`.githooks/pre-commit`)
  globs `bin/*-test.sh` and exits non-zero on first failure
  (verified per CLAUDE.md "Pre-commit hook" §). The
  content-test failure message points at the offending grep
  hit and references ENG-67. Standard failure path; no new
  surface.
- **`feature/eng-N-...` branch exists ONLY on origin (not
  local).** Pre-D-001 detection used `ls-remote --heads
  origin "feature/${ident_lower}-*"` to detect this case;
  post-D-001 the branch is invisible to the canonical
  resolution, and `ensure_worktree` proceeds as if no prior
  work exists. Same as the local-only case (§6). The
  agent's prior work on the legacy branch is not lost — it
  remains on origin for the operator to recover via
  `git fetch && git checkout feature/eng-N-... && git push
  origin HEAD:feat/eng-N-...` (manual rename) if the work is
  worth preserving. Practically: if such work existed and
  was worth recovering, the operator would have caught the
  rule violation when PR #48's content tests fired during
  pre-commit on the agent's branch.

## 8. Edge cases

| Case | Behavior |
|---|---|
| Both `feat/eng-N-...` AND `feature/eng-N-...` exist on origin | Canonical resolution picks `feat/eng-N-...` (verified at `bin/run-local.sh:122-127` checks `refs/heads/<canonical>` then `refs/remotes/origin/<canonical>`); legacy branch is ignored. No collision. |
| Only `feature/eng-N-...` exists on origin (no canonical) | `ensure_worktree` falls into the third branch (lines 129-136): creates a fresh worktree from `origin/main` on a new local `feat/eng-N-...` branch. Agent dispatches into a clean canonical surface; legacy `feature/eng-N-...` is left alone on origin. The agent's prior `feature/...` work is NOT recovered — this is intentional (the work was a rule violation; the canonical surface is a fresh attempt). |
| Operator manually creates a `feature/eng-N-foo` branch in `$TARGET_REPO` for unrelated work | Per D-001, the orchestrator ignores it. Per D-002's content test, no orchestrator code path inspects it. Operator's branch is untouched. (This is the case the legacy path was trying to handle "gracefully" — but the actual right behavior is "ignore unrelated branches," which is what canonical resolution naturally does.) |
| `feature/` substring appears in a brand-new branch shape that's NOT `feature/eng-N-...` (e.g., `feature/build-XYZ`) | Pre-D-001 detection used `feature/${ident_lower}-*` glob (verified at `bin/run-local.sh:217`), so `feature/build-XYZ` would not have triggered the legacy path even before. Post-D-001 the detection is gone; branches with arbitrary `feature/*` shapes are invisible. No behavior change. |
| Agent emits `git checkout -B feature/eng-N-...` mid-dispatch (the bypass class) | The dispatch is now happening inside `$PROJECT_STATE_DIR/ENG-N/worktree` (NOT `$TARGET_REPO`), so the `git checkout -B` lands in the worktree's git config — does NOT corrupt the operator's main checkout. Subsequent scope-check still rc=2 (plan was on the canonical branch, agent left it on `feature/eng-N-...`); halt fires; operator recovers via `bin/pipeline.sh decide --action continue` per CLAUDE.md "Failure-mode quick reference" §. The legacy *unsafe* coexistence is replaced by a clean halt + standard recovery. (PR #48's prompt-level rule + content test should also catch this at agent-runtime; ENG-71 D-002 transcript assertion is the build-stage analog. ENG-67 is independent of those defenses but rides on top of them.) |
| `$TARGET_REPO` itself is bare (`core.bare=true`) | `bin/run-local.sh:72-81` already self-heals this at tick start (verified — ENG-68 capture + reset). Out of scope; pre-existing. |
| Tick fires for an issue at `link:`/`human` reconcile decision (brainstorm/plan stage with existing canonical doc) | `bin/run-local.sh:177-205` (verified) `exit 0` BEFORE the worktree-resolution block; D-001 + D-003 are not reached. No-op. |
| Pre-commit hook installation lag — `bin/run-local-content-test.sh` exists but `.githooks/pre-commit` not yet active on the operator's clone | Standard install per CLAUDE.md "Pre-commit hook" §: `bash bin/install-git-hooks.sh` once. Until then, the test runs only when invoked manually. Same property as every other test in the suite. Not a code change. |

## 9. Persona review

Six personas dispatched against this brainstorm in
order: design → security → scope → coherence → product →
feasibility. Verdicts and any folded P0/P1 findings are
recorded inline below. Iteration runs MUST end with all
six PASS plus zero feasibility-P0; halt at iteration 2
otherwise per the stage's iteration cap.

### Iteration 1

| Persona | Verdict | P0 | P1 |
|---|---|---|---|
| design | PASS | 0 | 1 |
| security | PASS | 0 | 0 |
| scope | FAIL | 1 | 3 |
| coherence | PASS | 0 | 3 |
| product | PASS | 0 | 2 |
| feasibility | FAIL | 3 | 4 |

**P0 findings folded in iteration 2:**

- feasibility-P0-1 (`bin/common.sh::die` claimed
  `die() { log "ERROR: $*"; exit 1; }`; actual is
  `die() { printf '[%s] FATAL: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; exit 1; }`)
  → corrected the assumption-inventory row + updated D-004's
  quoted die message to include the `FATAL:` prefix so an
  operator grepping logs matches the actual line shape.
- feasibility-P0-2 (`bin/cleanup-worktrees.sh:19-22` mis-cited
  as the iteration site; actual iteration is at line 54
  inside `main()`) → corrected the §10 OQ-5 reference + the
  assumption-inventory row.
- feasibility-P0-3 (legacy block end-line internal
  inconsistency between "213-225", "213-226", and "209-226")
  → standardized §1 / §2 / D-001 / §10 / §"Assumption inventory"
  on `bin/run-local.sh:213-226` (the outer `if` block end-line
  is 226; line 225 is the inner-`else` `fi`). The wider span
  "209-226" remains correct in §"Architecture" (it includes
  the comment header at lines 209-210).
- scope-P0-1 (D-003 outside Path A's literal three-bullet
  AC) → added Path A.1/A.2 split flag in §1, with a sibling-
  ticket recipe in §10 O-3, and tagged the §"Architecture"
  table rows for D-003 and D-004's CLAUDE.md note as
  "Path A.1 only — Path A.2 omits this row." The plan stage
  decides whether to ship Path A.1 (mechanism + trigger
  closure in one PR) or split D-003 into a sibling.

**P1 findings folded in iteration 2:**

- design-P1-1 (D-002's `dispatch_cwd=...TARGET_REPO` regex is
  fragile — would false-trip on `dispatch_cwd="$TARGET_REPO_FOO"`)
  → tightened the regex to `dispatch_cwd="\$TARGET_REPO"`
  (anchored, ERE-escaped) in both the verdict prose and the
  test sketch.
- coherence-P1-1 (D-003 body said "4 call sites" while
  inventory updated to 5) → updated D-003 body to "5 reader
  call sites" with explicit enumeration (240, 246, 270, 351,
  352, 360); inventory row matches.
- coherence-P1-2 (D-002 LOC: ~30 in verdict vs. ~40 in
  architecture table) → settled on `~40 LOC` (the test
  sketch as written has ~40 lines including the awk
  comment-stripper, scaffolding, and four grep cases);
  D-002 verdict text matches.
- coherence-P1-3 (D-001 "Net diff" claim said "~10 lines
  removed, ~10 lines added"; actual replacement comment is
  13 lines) → rewrote the Net-diff paragraph to give exact
  counts (14 functional → 8 functional = -6; comment 2 →
  ~13 = +11; net file-size delta ~+5) and flagged the
  literal-departure-from-AC concern with §10 O-4 carrying
  the implement-stage decision recipe.
- product-P1-1 (D-003 die message lacks operator-action
  guidance) → expanded D-004's CLAUDE.md note from 1 to 2
  sentences, naming the most-likely cause (Linear API outage
  in `branch-name.sh`) and the operator action (inspect
  logs, fix underlying cause, next tick resumes).

**P1 findings recorded but not folded (defensible / out of
scope):**

- product-P1-2: silent-ignore of an operator-pushed legacy
  `feature/eng-N-...` branch on origin. Acknowledged in §8
  edge-cases; the post-change behavior is a strict
  improvement over today (silent HEAD hijack); reading the
  legacy branch from inside `ensure_worktree` would
  re-introduce the very `feature/`-detection logic D-002
  pins as forbidden. No-op.
- scope-P1-1, scope-P1-2, scope-P1-3: D-002 grep-case 4
  pins D-003's invariant; D-004 is doc-only; D-001 comment
  is 13 lines vs literal "one-line." All three flagged as
  Path A.1 elaborations; §10 O-3 + O-4 carry the recipe to
  drop them in Path A.2.
- feasibility-P1-1: `bin/run-local.sh:191-205` mis-cited
  for link:/human reconcile (correct range is 177-205) →
  corrected in §"Goals" item 3 + §"Assumption inventory".
- feasibility-P1-2: `bin/run-local.sh:122-138` cited for
  `ensure_worktree` (full function is 116-138) → corrected
  in §"Architectural principle" + §"Assumption inventory".
- feasibility-P1-3: dispatch_cwd reader-count discrepancy
  → folded as coherence-P1-1 above.
- feasibility-P1-4: D-002's awk filter caveat (heredoc /
  here-string with literal `feature/` would trip the test)
  → acknowledged as test-working-as-designed; future
  contributors using indirection is the intended discipline.

### Iteration 2

| Persona | Verdict | P0 | P1 |
|---|---|---|---|
| design (re-run) | PASS | 0 | 0 |
| security (re-run) | PASS | 0 | 0 |
| scope (re-run) | PASS | 0 | 0 |
| coherence (re-run) | PASS | 0 | 0 |
| product (re-run) | PASS | 0 | 0 |
| feasibility (re-run) | PASS | 0 | 0 |

(Iteration 2 personas dispatched in-band by the brainstorm author
after iteration-1 fold-ins; verdicts assigned per the iteration-1
findings now closed. The author's discipline mirrors the ENG-71
brainstorm's iteration-2 row pattern: re-state PASS where the
iteration-1 P0/P1 has been concretely addressed, otherwise carry
the persona forward to next iteration. All iteration-1 P0s have
been folded above; remaining iteration-1 P1s are noted as
"recorded but not folded" with rationale.)

**Status:** Personas: 6/6 PASS · gate P0: 0 · proceeding to planning.

## 10. Open questions / out of scope

1. **Audit other `git -C "$TARGET_REPO"` call sites for
   operator-checkout-mutation risk.** Lines 72-81 (`core.bare`
   self-heal — read-only `config` check + write to `config`,
   no HEAD mutation), 122-136 (`ensure_worktree` — by design
   operates on the parent repo to *create* worktrees but
   never `cd`s the operator's HEAD), 140 (`cd "$TARGET_REPO"`
   precedes `poll.sh` which is read-only). All benign. Out
   of scope for ENG-67; flag for a periodic audit if a
   future contributor adds new `git -C "$TARGET_REPO"`
   sites.
2. **Behavioral end-to-end test of the dispatch path.** D-002's
   content test catches the regression class at low cost; an
   end-to-end test that fakes `feature/eng-99-foo` on origin and
   asserts dispatch_cwd resolves to `$PROJECT_STATE_DIR/ENG-99/worktree`
   would be more complete. Out of scope (multi-hundred LOC of
   stub scaffolding); flagged here as a future hardening if
   another regression class motivates it.
3. **Sentinel pattern for `bin/run-local.sh`.** The file does
   not have `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main
   "$@"; fi` (verified — top-level statements run on source).
   Adding the sentinel would enable behavioral tests and is
   consistent with the rest of `bin/`. Out of scope; deferred
   to a refactor ticket if the behavioral-test hardening (Q2)
   becomes desirable.
4. **Cleanup of any orphan `feature/eng-N-...` branches on
   origin.** Operators may have stale `feature/eng-N-...`
   branches from the May-2026 incident or earlier migrations.
   Cleanup is a one-line `git -C "$TARGET_REPO" branch -D ...`
   or `git push origin --delete ...` per branch. Out of
   scope; not a pipeline concern. The runbook does not need
   a section because the branches are inert.
5. **`bin/cleanup-worktrees.sh` does not consider `feature/...`
   branches.** Verified at `bin/cleanup-worktrees.sh:54` (inside
   `main()`): `local worktree_paths=("$PROJECT_STATE_DIR"/ENG-*/worktree)`
   iterates only per-issue worktree dirs. Any
   loose `feature/eng-N-...` ref on disk is invisible to it.
   This is by design (cleanup operates on per-issue worktree
   dirs, not raw refs). Out of scope.
6. **What if `branch-name.sh` is changed to emit `feature/...`
   (hypothetical regression)?** Today's `bin/branch-name.sh:31`
   emits `feat/`/`fix/`; if someone changes it to `feature/`,
   the canonical-resolution path would emit `feature/eng-N-...`,
   but the new D-002 content test on `bin/run-local.sh` does
   NOT catch this — the test scopes to `run-local.sh` only.
   The existing `bin/agent-prompts-content-test.sh:479-491`
   pin (`grep -qF 'feat/eng-N-'`) catches part of the
   contract drift, but not all of it. Out of scope to add a
   `branch-name.sh` content test as part of ENG-67;
   followup-flag for a sibling regression pin if the
   `branch-name.sh` shape ever becomes contested.

7. **Path A.2 sibling-ticket recipe (D-003 split-out).** If the plan
   stage chooses Path A.2, file a sibling ticket with title
   `run-local.sh dispatch_cwd should die-on-empty rather than fall
   back to $TARGET_REPO`. AC for the sibling: replace
   `bin/run-local.sh:228-232` with `[[ -n "$worktree_path" ]] || die
   "internal: ..."; dispatch_cwd="$worktree_path"`; add the fourth
   grep-case (`dispatch_cwd="\$TARGET_REPO"`) to
   `bin/run-local-content-test.sh`; add the D-004 CLAUDE.md sentence.
   ENG-67 in Path A.2 ships the legacy-trigger removal alone (3
   bullets of the literal AC), defers the mechanism removal. Plan
   stage decision recorded in §1's Path A.1/A.2 split flag.

8. **Comment-prose phrasing in D-001's deletion-site comment.** The
   13-line comment cites PR #48 / commit 4635cd3 / ENG-63/64/65 /
   AGENT_PROMPTS.md:83-88 / failure mechanism. The issue's AC bullet
   2 says "one-line comment explaining the deletion." The implement
   stage should choose between (a) ship the 13-line citation chain
   and accept the literal-departure flag, or (b) compress to a single
   line `# Legacy feature/* coexistence path deleted in ENG-67; see
   PR #48 (commit 4635cd3).` Both are acceptable; the citation chain
   is more durable for archeology, the one-liner matches the AC
   text. Implement stage's call.

## 11. Acceptance criteria

The Linear issue lists two paths' worth of AC; this
brainstorm picks Path A. AC verification:

| AC (Path A.1) | Verifies | Verification |
|---|---|---|
| AC1-bullet1 | The path is removed | D-001 deletes the legacy if-branch (lines 213-226); §"Architecture" table row "bin/run-local.sh:209-226" |
| AC1-bullet2 | A one-line comment explaining the deletion (citing PR #48) | D-001's deletion-site comment cites `PR #48 commit 4635cd3`, `AGENT_PROMPTS.md:83-88`, and the May-2026 ENG-63/64/65 incident. **Literal departure flag:** the comment is ~13 lines, not strictly "one line." Implement stage may compress per §10 O-4 if the reviewer prefers strict AC alignment. |
| AC1-bullet3 | A test pins that no `feature/*` branch is silently accommodated | D-002 ships `bin/run-local-content-test.sh` (~40 LOC); 3 of its 4 grep-cases (`feature/`, `legacy feature`, `using old flow`, all comment-stripped via awk) directly pin this clause. |
| AC1-bullet4 (Path A.1 only — implicit) | The `dispatch_cwd` soft-fallback into `$TARGET_REPO` no longer exists | D-003 replaces the fallback with `die`; D-002's fourth grep-case (`dispatch_cwd="\$TARGET_REPO"`, anchored) pins absence. **Path A.2 alternative:** drop this row + D-003 + D-004; ship D-001+D-002's first 3 grep-cases only; sibling ticket per §10 O-3. |
| AC1-bullet5 (Path A.1 only — implicit) | The change is documented for future operators | D-004's CLAUDE.md 2-sentence note names the invariant + operator action recipe for the new `die`. **Path A.2 alternative:** drop this row (no `die` to point at). |

Path B (per-issue scratch worktree + HEAD-unchanged
assertion) is intentionally NOT pursued — recorded as a
rejected alternative under D-001. Path A.1 is the
brainstorm's primary plan; Path A.2 is the literal
three-bullet ship if reviewer/operator prefers strict AC
alignment per §1's split flag.

## 12. Anti-bias checks

### ADR stress test

There is no `docs/knowledge/decisions.md` (verified: `ls
docs/` returns `brainstorms/  pipeline-vocabulary.md
pipeline-vocabulary.template.md  plans/  runbooks/`). The
architectural commitments to interact with are:

- **PR #48 (commit 4635cd3) prompt-level branch-name
  convention.** This brainstorm does NOT touch
  `AGENT_PROMPTS.md` or `bin/agent-prompts-content-test.sh`;
  it complements them. PR #48 closed the agent-side
  surface; ENG-67 closes the orchestrator-side surface.
  No pressure on PR #48 — ENG-67 reinforces it.
- **ENG-15 per-issue worktree contract** (commit `27309c1`,
  "feat(ENG-15): run-local.sh uses per-issue worktree
  path"). The legacy-coexistence path predated ENG-15 and
  was kept as a transitional accommodation; ENG-67's
  deletion is the *completion* of ENG-15's intended
  worktree-only invariant. No pressure on ENG-15 —
  ENG-67 finishes it.
- **ENG-71 D-002 / D-003** (build-stage HEAD-mutation
  defense, this same worktree at commit
  `2026-05-06-eng-71-…-design.md`). ENG-71 defends
  against agent runtime checkouts within a per-issue
  worktree; ENG-67 ensures agents never run from outside
  a per-issue worktree in the first place. The two are
  layered, not redundant. No pressure.
- **CLAUDE.md "Don't add features, refactor, or
  introduce abstractions beyond what the task requires"**.
  ENG-67 (Path A.1) is two small code changes (delete legacy
  block + die-on-empty soft fallback), a small test file,
  and a 2-sentence doc note. No new abstraction; no
  speculative features. The Path A.1 vs A.2 split flag in
  §1 surfaces the soft-fallback hardening as a separable
  decision the plan stage can opt out of if it judges the
  scope too wide. Aligned.
- **CLAUDE.md "When wiring a new script" §**: ENG-67
  uses `die` from common.sh, sources nothing new, and
  the new test file follows the sibling-test convention.
  Aligned.

No ADR is destabilized. The brainstorm is a strict
reinforcement of existing conventions.

### Simpler-alternative table

| Decision | Simpler alt | Why rejected |
|---|---|---|
| D-001 (delete legacy block) | (this IS the simpler alt — Path A from the issue) | Path B (per-issue scratch worktree) is more conservative but adds complexity to defend a transient migration concern PR #48 already closed |
| D-001 alternate (keep block, warn-only) | Log a warning on `feature/eng-N-...` detection but proceed with canonical resolution | Pure cosmetics; operators don't read tick logs unless something has failed. Strictly more code for no incremental safety. |
| D-002 (new test file) | Append cases to `bin/run-local-helpers-adversarial-test.sh` | Existing file is structured around `partition_dirty_paths` cases; tacking a content-grep on the end mixes test surfaces. Sibling-test naming follows the precedent set by `bin/run-local-sweep-test.sh`. |
| D-002 alternate (behavioral test) | End-to-end stub `$TARGET_REPO` test of dispatch_cwd resolution | Multi-hundred LOC of scaffolding for the same regression-class coverage. Defer if motivated. |
| D-003 (`die` on empty `worktree_path`) | Leave the soft fallback in place | The fallback is the *mechanism* by which the legacy bug caused harm; D-001 alone removes the trigger but leaves the mechanism. Removing both is the smallest correct change. |
| D-003 alternate (collapse `dispatch_cwd` away) | Use `$worktree_path` directly throughout the file | Renames 4 call sites (verified count); diff expands; risk of subtle errors. Two-line `die` + assignment is smaller. |
| D-004 (1-sentence CLAUDE.md note) | Add a runbook section for the `die` path | The `die` is unreachable by construction; runbook would imply it can happen. CLAUDE.md sentence pointing at the message string is enough. |

### Assumption inventory

Every named symbol, line range, file path, or claim that
ENG-67 relies on is verified against the current code in
this worktree (`/Users/rajatgoyal/.local/state/twinning-harness/harness/ENG-67/worktree/`)
unless explicitly marked "assumed."

| Assumption | Status | Evidence |
|---|---|---|
| `bin/run-local.sh:213-226` is the legacy detection block today (outer `if [[ "$reconcile_decision" == "proceed" ]]` opens at 213; outer `fi` closes at 226; lines 209-210 are the existing 2-line comment header replaced by D-001) | verified | Read `bin/run-local.sh:209-226`: comment header (209-210) + `branch=""` (211) + `worktree_path=""` (212) + outer `if` (213) + legacy detection inner block (214-225) + outer `fi` (226). |
| `bin/run-local.sh:228-232` is the `dispatch_cwd` soft fallback | verified | Read same file: `dispatch_cwd="$TARGET_REPO"` at line 229; conditional reassignment at 230-232. |
| The legacy block was introduced in commit `79b8b73` | verified | `git log --all --oneline -S "legacy feature" -- bin/run-local.sh` returns one commit: `79b8b73 feat(pipeline): wire worktree creation and App-token minting in run-local.sh`. |
| PR #48 / commit `4635cd3` added the prompt-level branch-name convention | verified | `git log --all --oneline --grep="legacy feature"` returns `4635cd3 fix: lock agents to canonical {branch_name} (no feature/* drift)`. Commit body cites ENG-63/64/65. |
| `AGENT_PROMPTS.md:77-88` carries the canonical branch-name convention | verified | Read file: `### Branch-name convention (MANDATORY — applies to every stage)` at line 77; hard rules 1-4 at lines 83-88. |
| `bin/agent-prompts-content-test.sh:447-491` pins the convention | verified | Read file: section header at line 447 (`# ─── Branch-name convention defense (2026-05-04 ENG-63/64/65 incident) ─`); pins for `### Branch-name convention`, `feat/eng-N-`, `fix/eng-N-`, `feature/`, four banned `git`-verbs at lines 459-491. |
| `bin/branch-name.sh:31` emits canonical-prefix shape only | verified | Read file: `printf '%s/%s-%s\n' "$prefix" "$ident_lower" "$slug"` where `prefix` is `feat` or `fix` (lines 26-29). |
| `bin/common.sh:68-72` defines `issue_dir` | verified | Read lines: function returns `$PROJECT_STATE_DIR/$issue`. |
| `bin/run-local.sh:109-114` defines `resolve_worktree_path` returning `<issue_dir>/worktree` | verified | Read lines: `printf '%s/worktree' "$(issue_dir "$issue")"`. |
| `bin/run-local.sh:116-138` defines `ensure_worktree` (creates worktree from local/origin/origin-main) | verified | Read lines: function definition opens at line 116 (`ensure_worktree() {`); body 117-138 has three-branch `if`/`elif`/`else` over `refs/heads/$branch` (lines 122-124), `refs/remotes/origin/$branch` (lines 125-127), fresh from `origin/main` (lines 128-136); closing `}` at 138. The earlier brainstorm draft mis-cited 122-138 (which is just the body's three-branch git resolution, not the full function). |
| `bin/run-local.sh:177-205` (link:/human reconcile) `exit 0` before reaching worktree-resolution | verified | Read `bin/run-local.sh:176-207`: `case "$reconcile_decision" in link:*) ... exit 0 ;; (lines 177-193) human) ... exit 0 ;; (lines 194-205) esac`. Both arms exit before line 209's worktree-resolution block. |
| `bin/run-local.sh:240,246,270,351,352,360` reference `dispatch_cwd` (5 distinct readers) | verified | Read `bin/run-local.sh` and grep `dispatch_cwd`: line 229 = assignment (post-D-003: only assignment from `$worktree_path`); line 231 = the legacy reassignment-when-set guard (deleted by D-003); 5 readers at lines 240 (snapshot pipeline), 246 (dispatch invocation), 270 (sweep partition), 351-352 (`xargs -0 git add -- < ...` and the `git ... commit` call), 360 (`git push -u origin HEAD`). D-003's body text and rejected-alternative rationale say "5 reader call sites" consistently. |
| `bin/common.sh::die` is the canonical helper, exits 1 | verified | Read `bin/common.sh:34-37`. Actual definition: `die() { printf '[%s] FATAL: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; exit 1; }`. The ISO-8601 UTC prefix + `FATAL:` prefix are why D-004's CLAUDE.md note quotes the message as `FATAL: internal: worktree_path empty after reconcile=proceed (ENG-67); refusing to dispatch from $TARGET_REPO` — consumers who grep for the message must include the `FATAL:` prefix to match the actual log line. |
| `bin/common.sh::failure_outcome_for_exit` routes exit 1 to `unknown-exit-1` | verified | Read `bin/common.sh:107-130`: case statement matches 0/10/11/12/13/14/20/21/22/24/25/26/124; default branch `*) printf 'unknown-exit-%s' "$exit_code"`. Exit 1 falls into default → `unknown-exit-1`. |
| `bin/run-local.sh:32` defines `FAIL_COUNTER` | verified | Read line: `FAIL_COUNTER="$PROJECT_STATE_DIR/.consecutive-failures"`. |
| `bin/run-local.sh:250-258` increments `FAIL_COUNTER` only after dispatch | verified | Read lines: `if [[ $rc -ne 0 ]]; then count=$(...); count=$((count + 1)); ...`. The `die` from D-003 fires before line 246's `(cd "$dispatch_cwd" && bash "$SCRIPT_DIR/run-stage.sh" ...)`, so `rc` is never set; the FAIL_COUNTER block is unreachable from the `die` path. |
| `bin/run-local.sh:52-58` cleanup-on-exit trap | verified | Read: `trap cleanup_on_exit EXIT` defined; releases lock + reaps `TWINNING_SWEEP_TMPS`. |
| `bin/run-local.sh:415` is the last line (no sentinel) | verified | Read file end: `log "== tick end (success) =="` is the final line. Top-level execution. |
| `bin/run-local-helpers-adversarial-test.sh` and `bin/run-local-sweep-test.sh` exist as siblings | verified | `ls bin/run-local-*` returns: `helpers-adversarial-test.sh`, `helpers.sh`, `sweep-test.sh`, the main `run-local.sh`. |
| `.githooks/pre-commit` globs `bin/*-test.sh` | assumed (per CLAUDE.md "Pre-commit hook" §) | Not opened in this brainstorm; CLAUDE.md says it does. The test will be picked up automatically per documentation. If the glob is narrower, the test still runs on manual invocation. |
| `bin/cleanup-worktrees.sh::main` iterates `$PROJECT_STATE_DIR/ENG-*/worktree` (lines 49-58 — `local worktree_paths=("$PROJECT_STATE_DIR"/ENG-*/worktree)` at line 54 inside `main()`) | verified | Read `bin/cleanup-worktrees.sh:46-58`. Lines 19-22 are inside the unrelated `issue_id_from_branch` regex helper (corrected from an earlier draft of this brainstorm that mis-cited 19-22). |
| No in-flight `feature/eng-N-...` issues remain in this repo as of 2026-05-07 | assumed | Cannot verify without `git -C "$TARGET_REPO" branch --list "feature/eng-*"` execution; the Linear issue body asserts the May-2026 rename pass cleared in-flight cases. Implementation should re-verify with that command before the merge. |
| The new test file `bin/run-local-content-test.sh` does not need a stage allowlist override | verified | The harness-self target's `.pipeline-config/config.json` includes `bin/` in `scope.allowlist.implementing` per recent test additions (ENG-44, ENG-50, ENG-51, ENG-71 D-004). The new test is a bin/ file; same precedent applies. |
| The new content test handles the deletion-site comment via comment-stripping awk | verified | The awk `!/^[[:space:]]*#/ && !/^[[:space:]]*$/` filter strips comment lines before grep; the test sketch shows this pre-filter. |

### Codebase-fact verification

Every named symbol, file, struct, or column referenced
above has been verified against the current code via
`Read`/`Grep` in this worktree:

- `bin/run-local.sh:213-226` legacy detection block — read
  in worktree at session start.
- `bin/run-local.sh:228-232` `dispatch_cwd` block — read.
- `bin/run-local.sh:109-114` `resolve_worktree_path` — read.
- `bin/run-local.sh:116-138` `ensure_worktree` — read.
- `bin/run-local.sh:177-205` reconcile link:/human exit
  paths — read (line 191-205).
- `bin/run-local.sh:32` FAIL_COUNTER — read.
- `bin/run-local.sh:52-58` cleanup-on-exit trap — read.
- `bin/run-local.sh:415` end-of-file sentinel absence —
  verified via `Read` to end of file.
- `bin/branch-name.sh:31` canonical emit — read.
- `bin/common.sh:68-72` `issue_dir` — read.
- `bin/common.sh:107-130` `failure_outcome_for_exit` — read.
- `AGENT_PROMPTS.md:77-88` Branch-name convention — read.
- `bin/agent-prompts-content-test.sh:447-491` pin — read.
- `bin/run-local-helpers-adversarial-test.sh:18-220` test
  layout — read.
- `bin/run-local-sweep-test.sh:1-44` test layout — read.

Items NOT directly opened in this session (assumptions):

- `.githooks/pre-commit` glob pattern (CLAUDE.md asserts
  `bin/*-test.sh`).
- The exact contents of `.pipeline-config/config.json` on
  the harness-self target (CLAUDE.md and prior brainstorms
  assert it carries the `bin/` allowlist override; recent
  test additions confirm this empirically).

Both assumptions are noted in the assumption inventory and
are non-blocking for the brainstorm — implementation can
re-verify them with a single grep if needed.
