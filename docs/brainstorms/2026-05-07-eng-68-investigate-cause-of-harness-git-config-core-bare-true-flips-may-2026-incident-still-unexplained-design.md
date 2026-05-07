---
linear: ENG-68
title: Investigate cause of harness `.git/config` `core.bare=true` flips (May-2026 incident still unexplained)
date: 2026-05-07
status: draft
---

# Investigate `.git/config core.bare=true` flips on the harness repo

## 1. Problem and the load-bearing surprise

The May-2026 incident chain (ENG-63 / ENG-64 / ENG-65) had a smoking gun:
`/Users/rajatgoyal/code/twinning-harness/.git/config` carried
`core.bare = true`. With that flag the harness's own `git status` refuses
("must be run in a work tree"), and the partition sweep in
`bin/run-local.sh::main` (around `git -C "$dispatch_cwd" status -z
--porcelain`, `bin/run-local.sh:239-242`) silently mis-classifies dirty
paths because the parent's status semantics are bare. Test fixtures
inside `bin/*-test.sh` that did `cd $tempdir && git init` no longer
fully isolated — the inherited `GIT_INDEX_FILE=.git/index` (relative
path) and the bare-mode parent let fixture commits land in the harness's
shared `.git/`. That is how `seed.txt` and stray `feat/eng-58XX-test`
branches landed on the live worktree (the failure mode the user-memory
note "Pre-commit hook hijacks worktree via pipeline-test.sh" describes).

PR #48 (`42ae34b`) shipped a self-heal: both `bin/run-local.sh:72-80`
and `.githooks/pre-commit:49-56` read `core.bare`, reset it to `false`
when found `true`, and emit a `WARNING:` line. The next recurrence is
therefore *logged*, not silent — but the **trigger** is unknown, and
the issue forbids closing the loop with a symptom-only fix.

**The load-bearing surprise.** While the issue framing reads as "wait
for recurrence and then investigate," inspection of the dispatch
allowlist exposes a high-prior trigger that is actionable *now* without
waiting for data. `bin/dispatch.sh:248` (the `implementing` case) and
`bin/dispatch.sh:249` (the `ui` case) both ship `Bash(git:*)` — an
unrestricted glob over every `git` subcommand. Concretely that includes
`git config core.bare true`, `git init --bare`, and
`git --git-dir=$harness/.git config core.bare true`. The implement /
UI agent dispatching from a linked worktree of `$HARNESS_ROOT` would
write into the *shared* config (Git stores `core.bare` in
`$GIT_COMMON_DIR/config`, never in a per-worktree fragment — verified
against `git help config-variables` and the existing self-heal's choice
to call `git --git-dir="$HARNESS_GIT_DIR" config core.bare false` at
`.githooks/pre-commit:53` rather than `git config --worktree …`).

This widens the brainstorm's purpose beyond "instrument and wait":
**proceed in parallel on (a) forensic capture infrastructure for the
next recurrence (D-001) and (b) closing the highest-prior trigger class
pre-emptively via the harness's own ENG-43-style transcript-based
assertion pattern (D-002 + D-003 + D-004).** If the next recurrence
event lands AFTER (a)+(b) have shipped, the forensic dump distinguishes
"still happens" (data-driven escalation, D-005) from "didn't happen for
30 days" (closed by exhaustion). Either path gives the issue a finite
closure.

## 2. Goals and non-goals

**Goals.**

1. When `core.bare=true` is detected on the harness repo, capture a
   forensic snapshot rich enough to identify the writer process and the
   surrounding pipeline state — *before* the self-heal flips the bit
   back. The snapshot lands in a per-incident directory under
   `$PROJECT_STATE_DIR/forensics/core-bare-flip-<utc-iso>/` and a
   single Linear comment (using the existing `meta: dedup` shape) links
   the operator at it.
2. Pre-emptively close the highest-prior trigger class
   (agent-dispatched `git config core.bare true` / `git init --bare`)
   by tightening the implement/ui dispatch allowlist *and* layering a
   transcript-based assertion on top, per the
   "defense-in-depth on top of tool-lane denials" pattern documented in
   `CLAUDE.md` "When wiring a new script" §.
3. Lock the trigger class out by a regression test in the same
   shape as `bin/test-isolation-test.sh` (already pins T1 / T2 / T3 of
   the original incident).
4. Define a finite-closure decision rule: if (1)'s forensic dump fires
   ≥ 2 times in the 30 days *after* (2)+(3) ship, the trigger is *not*
   the agent allowlist; escalate to filesystem-level write-protection
   on `$HARNESS_ROOT/.git/config` (chflags / immutable bit) and reopen
   investigation against H2-H5 with much richer data. If (1) does not
   fire for 30 days, close ENG-68 as "trigger class identified, fix
   shipped."

**Non-goals.**

- Removing the existing self-heal. It is the symptom-mitigation
  belt and stays in place under either resolution path. It is *not*
  the permanent fix the AC asks for; the trigger-class fix (D-002 +
  D-003) is.
- Reproducing the original 2026-05-04 incident retroactively. The
  acute state was healed weeks ago; reproduction requires either
  (a) recurrence captured by D-001, or (b) constructing a synthetic
  trigger that the regression test in D-004 is designed to catch.
- Rewriting `bin/dispatch.sh::allowed_tools_for` wholesale. The
  ENG-51 / ENG-53 #8 contract (per-target `dispatch.tools.<stage>`
  extras append to the hardcoded base) stays as-is; we tighten only
  the base for two stages and rely on extras to grant back any
  per-target git ops that genuinely need wider scope.
- Auditing every other `Bash(*:*)` glob in `allowed_tools_for` for
  similar widening risk (e.g. `Bash(cargo:*)`, `Bash(bun:*)`). That is
  a sibling hardening ticket, not ENG-68; flagged in §10.

## 3. Decisions

### D-001. Forensic capture trap at the self-heal sites

**Decision.** Add a new helper `capture_core_bare_forensic` to
`bin/run-local-helpers.sh` (it is already sourced by
`bin/run-local.sh:28`; the pre-commit hook will source it from
`.githooks/pre-commit` via `source "$REPO_ROOT/bin/run-local-helpers.sh"`
inside a guarded block — see §4). The helper takes one arg (`$1` =
`$git_dir`) and:

1. Resolves `$forensic_root` =
   `${PROJECT_STATE_DIR:-$HARNESS_STATE_DIR/_unscoped}/forensics/core-bare-flip-$(date -u +%Y-%m-%dT%H-%M-%SZ)`
   and `mkdir -p`s it. Falls back to `$HARNESS_STATE_DIR/_unscoped/...`
   when `$PROJECT_STATE_DIR` is empty (the bootstrap path
   `TWINNING_BOOTSTRAPPING=1` per `bin/common.sh:48-54`).
2. Captures these artifacts in parallel (each redirected to a
   separate file inside `$forensic_root` so a single failing capture
   doesn't lose the rest):
   - `config.before` — `git --git-dir="$git_dir" config --list --show-origin`
   - `config-mtime` — `stat -f '%Sm %m %N' "$git_dir/config"` (BSD
     stat; the `%m` epoch field is the discriminator)
   - `reflog-HEAD` — `git --git-dir="$git_dir" reflog HEAD --date=iso`
     (last 50 entries)
   - `reflog-all` — `git --git-dir="$git_dir" reflog --date=iso --all`
     (last 200 entries; bounds size on busy repos)
   - `branches` — `git --git-dir="$git_dir" for-each-ref --format='%(objectname:short) %(refname) %(committerdate:iso)' | head -200`
   - `worktrees` — `git --git-dir="$git_dir" worktree list --porcelain`
   - `ps-snapshot` — `ps -ef | grep -E '(git|claude|sourcetree|tower|gitkraken|launchd)' | grep -v grep` (best-effort
     identification of concurrent writers)
   - `recent-tick-log` — last 500 lines of the *current* day's
     `$PROJECT_STATE_DIR/logs/local-$(date -u +%Y-%m-%d).log`
     (size-bounded; if missing, write `<no log file>`).
   - `recent-stage-transcripts` — names of the most-recently modified
     ten files under `$PROJECT_STATE_DIR/logs/` matching
     `*-stage-*.log` and the last 100 NDJSON lines of each
     (`$PROJECT_STATE_DIR/<ident>/.raw-stream.ndjson.tmp` is removed
     by dispatch.sh's RETURN trap, so stage logs are the only
     post-run artifact available).
   - `env-snapshot` — `env | grep -E '^(GIT_|PIPELINE_|TARGET_|HARNESS_|PROJECT_)' | sort`
     (the suspect inheritance window per the "Don'ts" CLAUDE.md
     "Test-isolation hardening" comment in `.githooks/pre-commit:18-43`).
3. After capture, posts ONE Linear comment to the issue resolved by
   `$PIPELINE_ISSUE_ID` (when set; otherwise to the harness-self
   "ENG-68" target) using `bin/linear.sh add-or-update-comment` with
   sig `core-bare-flip/<utc-iso-day>` — body = `<!-- meta: forensic
   kind=core-bare-flip path=<forensic_root> -->\n[forensic dump
   captured at <utc-iso>; ls $forensic_root]`. The dedup sig uses the
   *day* (not minute) so multiple flips within a day fold into one
   comment with the existing `meta: reapplied at=…` footer (ENG-63's
   feature).

After capture the existing self-heal proceeds (`git config core.bare
false`). Capture must complete before the heal because once the bit
flips back, `git status` semantics change and several of the captures
above (`reflog HEAD` in particular) start returning the *post-heal*
state.

**Why.** AC #1 of the issue ("Trigger identified: a deterministic
reproduction") is unreachable without a rich-enough forensic
snapshot at the moment of recurrence. The current self-heal logs one
line — enough to know it happened, not enough to know who did it.
The `forensic` dir lands inside `$PROJECT_STATE_DIR` which is already
the harness's per-project scratch area (per the `CLAUDE.md`
"Per-issue state directory" §); existing operator workflows that
inspect `$PROJECT_STATE_DIR/<ident>/` after a halt extend cleanly to
inspect the new sibling `forensics/` subdir. The Linear comment is
the discoverability layer — operators reading the halt comment learn
forensics exist *and* where they live, in the same shape every other
harness side-artifact is announced.

**Why dedup-by-day rather than dedup-by-incident.** A `core.bare`
flip is rare; multiple flips on the same day strongly suggest a
single root-cause writer firing repeatedly. Folding them into one
comment with reapplied-footer rotation (`bin/linear.sh::add_or_update_comment`,
ENG-63 D-001 footer behavior) keeps the Linear thread quiet while
the forensic dirs accumulate in full per-incident under
`$PROJECT_STATE_DIR/forensics/`. Operators see *that* it recurred
within the day; the dirs answer *how many times*.

**Why call the helper from BOTH `run-local.sh` and the pre-commit
hook.** The two self-heal sites cover non-overlapping windows: the
launchd path (`run-local.sh`) catches a flip that pre-existed at
tick start; the pre-commit hook catches a flip that landed *during*
the current operator commit. A flip from an agent dispatch is most
likely caught by `run-local.sh` (next tick after dispatch); a flip
from a manual operator git op or external GUI is most likely caught
by the pre-commit hook. Both layers must capture or we lose half the
window.

**Rejected — instrument via `inotifywait` / `fswatch` on
`.git/config`.** macOS `fswatch` requires installation (Homebrew
`brew install fswatch`) and its long-running daemon adds a process
that the harness must supervise; on a launchd-driven host this is a
new persistent service to install, monitor, restart, and audit.
Capture-on-self-heal is invariant-driven (we already detect the
flip), avoids a long-running process, and lands in the existing
`PROJECT_STATE_DIR` lifecycle. Trade-off: we lose the *exact* moment
of write (fswatch would log the inode-change ts within ms; capture-
on-self-heal lags by up to one tick — 5 min — or until the next
operator commit). The `config-mtime` stat captures the actual write
moment within ms, so the lag is metadata, not data: the *who* is
still reconstructable from `ps-snapshot` taken at heal time only if
the writer is still running. Rejected because the strongest writer
candidates (test fixtures, agent dispatches, GUI tool actions) are
all sub-second processes that exit before the next tick — we cannot
catch them via `ps -ef` regardless. The mtime + reflog-HEAD walk +
recent-stage-transcripts give us the writer-class *signature* even
without `ps`. (See OQ-2 for a follow-up that *would* benefit from
fswatch.)

**Rejected — capture into `$HARNESS_STATE_DIR/forensics/` (cross-project
shared).** Forensic dumps are inherently per-target — a flip on the
self-driving harness target is unrelated to a flip on a sibling
target driven by the same harness install. Per-project scratch under
`$PROJECT_STATE_DIR` is the right scope (matches the CLAUDE.md "When
wiring a new script" guidance "scripts that read or write per-project
state must reference `$PROJECT_STATE_DIR`, never
`$HARNESS_STATE_DIR/<issue>` directly").

### D-002. Tighten `implementing` and `ui` allowlist: `Bash(git:*)` → enumerated subcommands

**Decision.** Replace `Bash(git:*)` in
`bin/dispatch.sh::allowed_tools_for` cases `implementing`
(`bin/dispatch.sh:248`) and `ui` (`bin/dispatch.sh:249`) with the
explicit set of subcommands the agents actually need:

```
Bash(git status:*),Bash(git log:*),Bash(git diff:*),Bash(git show:*),
Bash(git add:*),Bash(git rm:*),Bash(git mv:*),Bash(git restore:*),
Bash(git commit:*),Bash(git checkout:*),Bash(git switch:*),
Bash(git fetch:*),Bash(git pull:*),Bash(git push:*),Bash(git rebase:*),
Bash(git merge:*),Bash(git branch:*),Bash(git stash:*),
Bash(git ls-files:*),Bash(git rev-parse:*),Bash(git rev-list:*),
Bash(git for-each-ref:*),Bash(git tag:*),Bash(git describe:*)
```

Notably ABSENT from the new list: `git config`, `git init`,
`git clone`, `git worktree`, `git filter-branch`, `git update-ref`,
`git symbolic-ref`, `git remote`, `git reflog`, `git gc`, `git fsck`,
`git plumbing` (e.g. `update-index`, `read-tree`, `write-tree`).
None of these are needed for the implement/ui agents' documented
contracts (write code, run tests, commit, push). The `building`
allowlist already enumerated these subcommands (`bin/dispatch.sh:252`)
— this brings implement/ui into structural symmetry.

**Why.** Direct closure of the highest-prior hypothesis (H1, §6).
The current `Bash(git:*)` glob is a wide footgun: `git` is a
multiplexer dispatching to ~150 subcommands; the harness needs ~25 of
them; the rest are reachable today by an agent that copy-pastes a
debugging recipe, follows a recipe found in a stale doc, or calls a
script that internally invokes one. CLAUDE.md "When wiring a new
script" §'s defense-in-depth principle is the canonical doctrine
here: "prefer a transcript-based assertion ... State checks
false-positive on actions taken by other actors (humans, prior
stages, future agents); transcript checks answer the contract
question directly." The transcript-based assertion (D-003) is the
defense-in-depth layer; the allowlist tightening (D-002) is the
primary lane denial.

The risk surface is concrete: an implement/ui dispatch running in a
linked worktree of `$HARNESS_ROOT` (the self-driving harness setup)
has its `worktree/.git` resolving to the shared common-config at
`$HARNESS_ROOT/.git/config`. `core.bare` is *always* read from
`$GIT_COMMON_DIR/config` (per `git help config-variables`'s "Config
files for working tree shared values" list); a `git config core.bare
true` from inside the linked worktree therefore writes into the
*main* repo's config, exactly the symptom observed. This vector
disappears with D-002.

**Why enumerated rather than a deny-list.** Claude's `--allowed-tools`
parser is allow-list-only; deny-only patterns aren't supported. The
sibling `--disallowed-tools` flag is for platform tools
(`bin/dispatch.sh:202`'s `disallowed_platform_tools`) and operates
over a different vocabulary — it does not match `Bash(...)` patterns
at the subcommand granularity. Allowlist enumeration is the only
mechanism that sandboxes git correctly.

**Trade-off.** This is the load-bearing cost: any future stage that
legitimately needs a git subcommand outside the enumerated set must
either (a) add it to the base list (one-line edit, requires PR
review), or (b) add it via the per-target `dispatch.tools.<stage>`
extras override (`config.json` edit, applies only to the local target
copy, no harness PR). (a) is cheap when the need is universal across
targets; (b) is the right scope for one-off needs. The alternative
(keep `Bash(git:*)` and only ship the transcript assertion) is
strictly weaker — the assertion is post-hoc detection, not
prevention; the agent's dispatch already wrote and pushed before the
assertion fires.

**Rejected — leave allowlist as-is, ship only D-003 (transcript
assertion).** Detection-only resolution lets the next agent that
runs `git config core.bare true` *actually flip the bit*; the
assertion produces a `protocol-violation` halt and the orchestrator
self-heals on the next tick, but the fixture-leak window (the
ENG-63/64/65 failure mode) re-opens for the duration of one tick.
Defense-in-depth means *both layers*; ship D-002 + D-003.

**Rejected — narrow only `git config` and `git init`, leave other
non-needed subcommands accessible (e.g. `git remote`, `git
worktree`).** Whitelisting *just* the known-bad pair leaves residual
footguns (a future Git release that adds a new subcommand is
implicitly granted; `git worktree add` in particular has its own
shared-config write surface for `extensions.worktreeConfig` and
similar). Enumerated allowlist matches the principle of "grant
exactly what's needed"; the diff is one-time work and the
enumeration is checked into source.

### D-003. Transcript-based assertion: forbid `git config core.bare`, `git init --bare`, `git --bare`

**Decision.** Extend `bin/dispatch.sh`'s existing
`assert_no_tool_invocation` machinery (already used at
`bin/dispatch.sh:48-65` for the ENG-43 `gh pr create` ban) with three
new patterns checked on EVERY stage's transcript (not just
implement/ui — defense-in-depth across the whole pipeline):

1. `git config core.bare`
2. `git init --bare`
3. `git --bare`
4. `git config --add core.bare` (rare but valid syntax)
5. `git -c core.bare=`

Each pattern is checked with `startswith` semantics against
`(.input.command // "")`. The existing helper accepts one pattern per
call; the change is a small wrapping loop that calls
`assert_no_tool_invocation "$transcript" "$pattern"` for each entry
in the list and records all matches into a single per-stage
violation file (`$issue_dir/.transcript-violation-<stage>` already
exists per `bin/dispatch.sh:97-98`'s `violation_file` line). When
*any* pattern matches, dispatch.sh fails the stage with the existing
`lane-violation` exit code (`failure_outcome_for_exit` at
`bin/common.sh:119` maps exit 13 to `lane-violation`) and the
classify-failure path posts a halt with `verdict halt --reason
protocol-violation` — same closure as ENG-43.

**Why.** The CLAUDE.md "When wiring a new script" § documents this
exact pattern: "Defense-in-depth on top of tool-lane denials: when a
stage's contract says 'agent must not invoke tool X,' prefer a
transcript-based assertion ... over a state-of-the-world check
after dispatch." The check is **content-based** (what the agent's
tool_use blocks invoked), not state-based (did `core.bare` flip),
because state checks false-positive on flips from other actors
(humans, GUI tools, prior stages). The transcript layer answers the
contract question directly: "did this stage's agent invoke a
forbidden git form?"

This complements D-002 in two ways:
1. **Whole-pipeline coverage.** D-002 only tightens implement/ui
   (the two stages currently shipping `Bash(git:*)`). D-003 covers
   every stage's transcript including build (`Bash(git fetch:*),
   Bash(git clone:*), Bash(git rebase:*)` — narrow today, but the
   subcommand list could grow), QA (`Bash(git:*)` — same risk as
   implement/ui), retrospective (`Bash(git log:*)` etc).
2. **Future-proofing.** A future allowlist drift (someone re-widens
   a `Bash(git:*)` glob to grant a new subcommand) does not silently
   re-open the trigger class; the transcript assertion still fires.

**Why include `git --bare` and `git -c core.bare=`.** These are
top-level git options (not subcommands) that would let an agent
invoke `git --bare config core.bare true` or
`git -c core.bare=true config ...` syntactically as different
patterns. The allowlist matches against the *start* of the command,
so all five patterns are needed for full coverage of the trigger
class.

**Rejected — assertion checks the SAME `core.bare` state pre/post
agent dispatch.** State-based check: `git config core.bare` before
and after dispatch; if it flipped, halt. Two failure modes: (a)
false-positive when a parallel actor (operator, GUI) flipped during
the dispatch window and the agent did not — the agent eats a halt
for someone else's action; (b) misses a flip that the agent
performed AND undid within the same dispatch (e.g., an agent
running `git config core.bare true` then `false` to "test
something"). Content-based assertion at the transcript layer is
strictly more accurate.

**Rejected — assertion checks only on implement/ui.** Asymmetric
coverage; the allowlist for QA also has `Bash(git:*)`. Whole-pipeline
coverage is one extra loop in `dispatch.sh::main` and zero stage-by-
stage configuration (the patterns are universal — no stage
*legitimately* writes `core.bare`).

### D-004. Regression test: `bin/test-isolation-test.sh::T4`

**Decision.** Extend `bin/test-isolation-test.sh` (already pins T1
GIT_* unset, T2 `core.bare` self-heal presence, T3 hostile-env probe
isolation) with a fourth invariant:

- **T4: `core.bare` does not flip under any of the candidate trigger
  scenarios.** Three sub-cases:
  - **T4a:** Build a probe linked-worktree of a temp parent repo
    (mimicking the harness self-driving topology — main repo at
    `$tmp/main`, linked worktree at `$tmp/wt`). Run a synthetic
    transcript-replay through the dispatch transcript-assertion
    helper invoking `git config core.bare true`. Assert the
    assertion *fires* (returns 1, prints the matched command) AND
    the parent's `core.bare` is still `false` (the assertion is
    pre-dispatch protective; in production the dispatch is
    *prevented* by D-002, but T4a tests the D-003 layer in
    isolation).
  - **T4b:** Run each `bin/*-test.sh` from a hostile env where
    `GIT_DIR=$probe_main/.git` (probe is the harness-self stand-in)
    and assert `core.bare` on `$probe_main` is still `false` after
    every test runs to completion. This catches an undiscovered
    test-fixture path that *would* flip the bit.
  - **T4c:** Direct invocation: `git --git-dir=$probe_main/.git
    config core.bare true`. Assert the bit flips (positive control
    — proves the test mechanism works, not just that no path
    triggers it).

**Why.** AC #3 of the issue ("Regression test that the trigger no
longer flips the flag") is the literal mandate. T4a + T4b cover the
two trigger classes (agent-invoked, fixture-inherited); T4c is the
positive control without which T4a / T4b would silently pass on a
test-mechanism bug. The file `bin/test-isolation-test.sh` is the
right home — it already groups invariants from the same incident
chain (`bin/test-isolation-test.sh:1-23` documents the 2026-05-04
incident and pins T1 / T2 / T3); T4 extends that group, not a new
file.

**Rejected — write a new `bin/core-bare-test.sh` file.** Splits
related invariants across two files; future readers of the incident
post-mortem must follow two breadcrumbs. T4 belongs with T1-T3.

**Rejected — defer the regression test to plan stage and only
prescribe T4a + T4c here.** T4b is the test that catches a
*future-introduced* fixture leak (the variant of the trigger we
have not yet discovered); skipping it leaves the regression
incomplete relative to the issue's "catch the trigger no matter
which class" framing.

### D-005. Finite-closure decision rule

**Decision.** Document a 30-day decision window in
`docs/runbooks/recovery.md` (new section "ENG-68 follow-up: core.bare
recurrence after fix"):

- If D-001 fires ZERO times in the 30 days after D-002 + D-003 + D-004
  ship → close ENG-68 as "trigger class identified, fix shipped";
  the self-heal stays as belt-and-braces, no further work.
- If D-001 fires 1 time in the window AND the forensic dump points
  at the agent transcript class (matched `git config core.bare true`
  in NDJSON) → confirms H1; close ENG-68 with the same disposition.
  The transcript assertion (D-003) was the prevention; the heal +
  forensic dump together proved the cause.
- If D-001 fires ≥ 2 times in the window AND none of the forensics
  point at the agent transcript class → escalate. Open ENG-68-2
  with the forensic dirs as the data-set, working through H2 / H3 /
  H4 in priority order (§6). Do NOT auto-ship filesystem write-
  protection (chflags uchg) — that breaks `git config user.name`
  and other legitimate writes. The escalation might land write-
  protection ON `core.bare` specifically via a `git config --include
  unset` pattern, but that is plan stage on ENG-68-2, not here.

**Why.** ENG-68's open-ended framing ("wait for recurrence and
investigate") risks the issue idling indefinitely if recurrence is
genuinely random or external. A finite window with explicit
disposition rules converts "still investigating" into a discrete
go/no-go decision the operator can make at the 30-day mark. The
window starts when D-002 + D-003 + D-004 land (not when this
brainstorm closes) — that gives the trigger-class fix a fair
observation period.

**Why 30 days.** Matches the harness's 30-day learned-rule
cadence (`learned-rules/harness/build.md:7` "Shelf life: 60 days. If
the problem hasn't recurred, the rule may be unnecessary."). Half
the rule shelf-life: a tighter signal because the underlying flip is
catastrophic to one tick (vs a learned rule which is informational).

**Rejected — close ENG-68 immediately on D-002 + D-003 + D-004 ship,
without the observation window.** Leaves no defined process for what
to do if recurrence happens after fix; either a new ticket gets filed
ad-hoc (no continuity to D-001's data) or the operator ignores the
self-heal warning. The 30-day rule preserves continuity.

## 4. Architecture (where code goes)

```
bin/run-local-helpers.sh
  + capture_core_bare_forensic()           # NEW (D-001)
      args: $1 = git_dir
      writes: $forensic_root/{config.before,config-mtime,reflog-HEAD,
              reflog-all,branches,worktrees,ps-snapshot,
              recent-tick-log,recent-stage-transcripts,env-snapshot}
      side effect: posts add-or-update-comment with sig
                   core-bare-flip/<utc-iso-day>

bin/run-local.sh:72-80
  ± modify: call capture_core_bare_forensic "$_git_dir" BEFORE the
            existing `git --git-dir="$_git_dir" config core.bare false`
            line; the warning-log line stays.

.githooks/pre-commit:49-56
  ± modify: same capture-before-heal pattern. Sources
            `$REPO_ROOT/bin/run-local-helpers.sh` inside a
            `[[ -f ... ]]`-guarded block (the hook runs with
            `set -uo pipefail` only — no `set -e` — so a missing
            helper falls through with a printf warning rather than
            aborting the commit).

bin/dispatch.sh:248-249
  ± modify: replace `Bash(git:*)` in `implementing` and `ui` cases
            with the enumerated list from D-002.

bin/dispatch.sh::main (around the existing assert_no_tool_invocation
                      call site for ENG-43)
  + add: a small wrapping loop iterating the five `git` patterns
         from D-003. Failure of any pattern flows into the existing
         lane-violation + classify-failure path.

bin/test-isolation-test.sh
  + add T4a / T4b / T4c at the end of the existing T1-T3 block.

docs/runbooks/recovery.md
  + new § "ENG-68 follow-up: core.bare recurrence after fix"
    (D-005 disposition rules).
```

No new files. Five existing files modified; the `bin/run-local-helpers.sh`
change is the only one large enough to deserve its own test (D-004's
T4 covers the regression behavior; helper-internal correctness is
locked by `bin/test-isolation-test.sh:T2`'s existing
`grep -q 'core\.bare'` check on the helper's call sites).

## 5. Data flow

### 5.1 Recurrence (steady state, post-fix)

```
[some actor flips core.bare=true on $HARNESS_ROOT/.git/config]
                          │
                          ▼
[next launchd tick fires run-local.sh]
  ├─ for each _git_dir in (TARGET_REPO/.git, HARNESS_ROOT/.git):
  │   ├─ git --git-dir=$_git_dir config --get core.bare → "true"
  │   ├─ capture_core_bare_forensic "$_git_dir"     ← NEW (D-001)
  │   │   ├─ mkdir -p $PROJECT_STATE_DIR/forensics/core-bare-flip-<ts>/
  │   │   ├─ dump 9 forensic artifacts (parallel — backgrounded with `&`,
  │   │   │   joined with `wait`)
  │   │   └─ linear.sh add-or-update-comment <issue> sig=core-bare-flip/<utc-iso-day>
  │   ├─ git --git-dir=$_git_dir config core.bare false
  │   └─ log "WARNING: $_git_dir had core.bare=true; reset to false"
  └─ tick continues normally

[operator inspects $PROJECT_STATE_DIR/forensics/<dir>/]
  ├─ config.before        ← what was the WHOLE config at the moment?
  ├─ reflog-HEAD          ← did HEAD move during the suspected window?
  ├─ recent-stage-transcripts  ← did an agent dispatch run in the window?
  ├─ env-snapshot         ← was GIT_DIR or PROJECT_SLUG poisoned?
  └─ ps-snapshot          ← was a GUI tool active concurrently?
```

### 5.2 Pre-emptive prevention (D-002 + D-003)

```
[implementing or ui agent dispatch]
  ├─ dispatch.sh::main acquires mutex
  ├─ allowed_tools_for "$stage" → enumerated list (NO Bash(git:*))
  ├─ claude -p stream-json runs; agent attempts `git config core.bare true`
  │   ├─ Claude's tool-use sandbox: pattern not in allowlist → DENY
  │   ├─ tool_use error returned to agent; agent sees "tool not permitted"
  │   └─ agent logs the denial; cannot retry with same form
  ├─ stream ends; dispatch.sh runs assert_no_tool_invocation loop
  │   ├─ for each pattern in (git config core.bare, git init --bare, …):
  │   │   ├─ jq scan of NDJSON tool_use blocks
  │   │   └─ if matched: write violation file, return 13 (lane-violation)
  └─ if any pattern matched but the sandbox missed it (defense-in-depth):
        → exit 13 → classify_failure → halt verdict protocol-violation
```

## 6. Hypotheses (priors and discriminators)

When forensic data arrives, evaluate against each hypothesis. Prior
weight is rough; discriminator is the forensic field that tells them
apart.

| H | Description | Prior | Discriminator (in forensic dump) |
|---|---|---|---|
| H1 | Agent dispatch (implement / UI) ran `git config core.bare true` (or equivalent) under the wide `Bash(git:*)` glob | HIGH | `recent-stage-transcripts` contains a tool_use block with `.input.command` matching one of D-003's five patterns; `config-mtime` falls within a stage's start-end window |
| H2 | Test fixture inside `bin/*-test.sh` resolved `git config core.bare true` (or equivalent) into the harness root via inherited `GIT_DIR` | MED | `config-mtime` falls inside a `.githooks/pre-commit` window (commit time captured in `reflog-HEAD`); `recent-stage-transcripts` empty during that window |
| H3 | Concurrent GUI tool action by the operator (SourceTree / Tower / GitKraken / VS Code Source Control) | MED | `ps-snapshot` shows a GUI process active; `config-mtime` falls outside any `bin/*` invocation window; `env-snapshot` is clean |
| H4 | Manual operator typo from a shell session | LOW | `ps-snapshot` shows an interactive shell; `recent-stage-transcripts` and `recent-tick-log` empty during window; `reflog-HEAD` clean |
| H5 | Filesystem corruption, snapshot/restore, or external process unrelated to harness | LOW | `config.before` shows other surprising mutations alongside `core.bare`; multiple unrelated keys flipped; or `config-mtime` matches a Time Machine restore window |

H1's prior is highest because (a) the wide `Bash(git:*)` glob in
`implementing` and `ui` is a known foot-gun (CLAUDE.md "When wiring a
new script" § flags exactly this risk for tool-lane denials), (b) the
ENG-63/64/65 dispatches were running in linked worktrees of
`$HARNESS_ROOT` whose shared config is the affected file, and (c) the
issue's "Hypotheses" §3 first bullet already names this class.
D-002 + D-003 close H1 pre-emptively; D-001's recurrence data either
confirms or refutes.

## 7. Error handling and edge cases

- **Forensic capture fails partially.** Each artifact is
  `cmd > $forensic_root/<name> 2>&1 || printf 'capture failed: %s\n' "$?" > $forensic_root/<name>.error` —
  one failed capture does not lose the rest. The Linear comment
  body lists which artifacts succeeded.
- **`$PROJECT_STATE_DIR` is empty (bootstrap path).** `run-local.sh`
  enters its bare check at line 72 *after* `mkdir -p
  "$HARNESS_STATE_DIR"` (line 42) but before `PROJECT_STATE_DIR`'s
  per-target subdir is necessarily writeable. Helper falls back to
  `$HARNESS_STATE_DIR/_unscoped/forensics/...` for that case;
  emits a log line `forensic dump landed under cross-project
  fallback: $forensic_root` (operator can move it later).
- **Pre-commit hook runs without a sourceable `run-local-helpers.sh`
  (rare — fresh checkout where bin/ has not been pulled yet).**
  Hook guards the source with `[[ -f ... ]] && source ...`; if the
  helper is missing, the hook falls back to the existing inline
  one-line warning + heal. Trade-off: forensic dump skipped that
  one time; the next launchd tick will catch it (the bit was just
  flipped, so the next `run-local.sh` tick still sees `core.bare=true`
  unless the hook itself healed — see next item).
- **The hook's heal runs FIRST, the launchd path's heal runs SECOND
  on the same flip.** Both sites independently capture (each
  produces a separate `core-bare-flip-<ts>` dir); both invocations
  are idempotent. The Linear comment dedup-by-day collapses both
  into one comment with two reapplied-footer lines (one per call).
  The forensic dirs preserve both sets of artifacts, which is
  desirable: the hook's dump captures the *during-commit* state
  and the launchd's dump captures the *next-tick* state, and the
  two together tell us whether the flip persisted past the hook's
  heal (i.e., whether a second writer fired).
- **Transcript-assertion false positive: an agent's tool_use input
  contains the literal substring "git config core.bare" inside a
  comment or a heredoc, not as the actual command.** The
  `assert_no_tool_invocation` helper at `bin/dispatch.sh:48-65` uses
  `startswith` against `(.input.command // "")`. A heredoc body
  embedded inside a `bash -c "..."` invocation would NOT match
  `startswith("git config core.bare")` because the command starts
  with `bash -c`. The risk is residual only for commands like
  `git status; git config core.bare true` (compound) — the
  startswith match would NOT fire on the second clause because it
  matches the first. Acceptance: this is a known limit of the
  pattern matcher (same limit ENG-43 lives with for `gh pr
  create`); we document it in OQ-3 and mitigate by adding `; git
  config core.bare`-form patterns if/when seen.
- **`git config --list --show-origin` includes a system-config
  file the operator does not own (e.g.
  `/opt/homebrew/etc/gitconfig`).** The forensic dump captures
  whatever `git config --list --show-origin` emits — system entries
  are part of the picture (an entry like
  `file:/opt/homebrew/etc/gitconfig core.bare=true` would be a
  much stronger anomaly than a per-repo flip). No extra filtering
  needed; the dump is for forensic inspection, not normalized data.

## 8. Open questions

- **OQ-1.** Should the forensic capture *also* fire when `core.bare`
  is detected = `false` but the `config-mtime` is < 60 seconds old
  (i.e., someone just edited the config without flipping the bit
  the heal cares about)? Catches a class of "edited config but bit
  ended up correct" events that are otherwise silent. *Default
  answer:* no — out of scope for ENG-68 (the issue is specifically
  about the bit flip); reconsider in plan stage if the recurrence
  data shows other config keys mutating alongside.
- **OQ-2.** Should D-001 ALSO add an `fswatch -o
  $HARNESS_ROOT/.git/config | xargs -n1 capture_core_bare_forensic`
  background process (when `fswatch` is installed)? Closes the
  "writer process gone by the time we look" gap in `ps-snapshot`.
  *Default answer:* no — adds a long-running background process
  outside the launchd lifecycle; revisit in a sibling ticket if
  D-005's 30-day window escalates.
- **OQ-3.** The transcript assertion (D-003) uses `startswith`
  against `(.input.command // "")`. A compound command like
  `git status && git config core.bare true` would NOT match because
  startswith only sees `git status`. Should we extend to a
  full-substring match (`contains` instead of `startswith`)? *Default
  answer:* no — startswith matches the existing ENG-43 pattern and
  preserves the false-positive properties (a substring-match would
  fire on a heredoc body or comment containing the literal text).
  Revisit if a recurrence is shown to involve compound commands.
- **OQ-4.** Should D-002's enumerated list be moved into a
  `learned-rules/harness/<stage>.md` file (to be appended at
  dispatch time per `CLAUDE.md` "AGENT_PROMPTS.md is load-bearing"
  §) rather than hardcoded in `bin/dispatch.sh::allowed_tools_for`?
  *Default answer:* no — `learned-rules/` is for prompt-side
  guidance, not allowlist enforcement. The allowlist is a sandbox
  contract; sandbox contracts belong in code.

## 9. ADR stress test, simpler alternatives, assumption inventory

### 9.1 ADR stress test

This brainstorm proposes a **new** ADR (no `docs/knowledge/decisions.md`
exists in this repo — verified by `ls docs/knowledge/` returning nothing
and `Glob('docs/knowledge/**')` yielding zero results, same convention
as the ENG-65 brainstorm §10):

> **ADR-PROPOSED-1 (status: proposed).** Forensic data capture for
> invariant-violation self-heals. When a self-healing site detects an
> invariant breach, it MUST capture a per-incident forensic dump
> *before* applying the heal. The dump lives under
> `$PROJECT_STATE_DIR/forensics/<class>-<utc-iso>/` and is announced
> via `linear.sh add-or-update-comment` with a `meta: forensic` shape.
>
> *Rationale:* the existing self-heals (the
> `core.bare` site at `bin/run-local.sh:72-80` and the
> `is_orchestrator_paused` empty-string default at common.sh) were
> shipped with no forensic capture, leaving the trigger of every
> self-heal-recoverable failure permanently invisible. ADR-PROPOSED-1
> establishes the inverse default: every self-heal MUST be observable
> at the per-incident granularity.

This new ADR puts pressure on the existing implicit policy "self-heals
are silent except for one log line." The cost is one helper call site
and one Linear comment per heal — bounded, observability-shaped. No
existing ADR is overturned; CLAUDE.md "Failure-mode quick reference"
already names "Where to look" for several failure modes (logs, comments,
labels) and ADR-PROPOSED-1 just adds a new "where" (the forensic dir).

### 9.2 Simpler alternative: do nothing more, close ENG-68 on the existing self-heal

The existing self-heal (PR #48) already converts a silent failure into
a logged warning. Why not declare that the AC-bar?

- AC #1 ("trigger identified, deterministic reproduction") is
  unreachable from the self-heal alone — one log line per recurrence
  doesn't carry the writer's identity. The forensic dump (D-001) is
  the minimum data set for AC #1.
- AC #2 ("permanent fix at the source, not just the self-heal") is
  *explicitly* the AC of the issue. The self-heal alone fails this AC
  by definition.
- AC #3 ("regression test that the trigger no longer flips the flag")
  has no test target without identifying the trigger. D-002 + D-003
  + D-004 make a test possible by hypothesizing the most likely
  trigger and locking it out.

The "do nothing" alternative reduces to closing ENG-68 as
won't-fix; the issue framing rejects this.

### 9.3 Simpler alternative: ship D-001 only; defer D-002 / D-003 / D-004 to recurrence

Rationale: D-002 narrows allowlist preemptively, which is an *opinion*
about the trigger; if the recurrence data refutes H1, the narrowing is
work that did not address the root cause.

Rejected because:
- D-002 is correct *in any case* — the wide `Bash(git:*)` glob is a
  foot-gun independent of whether it caused the May-2026 incident.
  CLAUDE.md "When wiring a new script" § already cites the principle
  ("grant exactly what's needed"). The cost is low; the benefit
  exists even if the recurrence root-cause is something else.
- D-003 is the defense-in-depth layer for D-002 and inherits the
  same independent-of-root-cause justification.
- D-004 locks both in; without it a future widening (the same
  failure mode) is silent.

So D-002 + D-003 + D-004 ship in parallel with D-001; D-005's window
gives the data the floor to either confirm or reject H1.

### 9.4 Assumption inventory

Verified means "checked against current code, with file:line citation."
Assumed means "needs validation during implementation."

| # | Assumption | Status | Evidence |
|---|---|---|---|
| 1 | `bin/run-local.sh:72-80` is the launchd self-heal site for `core.bare` | verified | `bin/run-local.sh:72-80` reads `core.bare` and resets to false on detection (block opens at line 72 with `for _git_dir in "$TARGET_REPO/.git" "$HARNESS_ROOT/.git"`) |
| 2 | `.githooks/pre-commit:49-56` is the second self-heal site | verified | `.githooks/pre-commit:49-56` `HARNESS_GIT_DIR="$REPO_ROOT/.git"` block reads + resets `core.bare` |
| 3 | `bin/test-isolation-test.sh` already pins T1 / T2 / T3 from the same incident | verified | `bin/test-isolation-test.sh:33-119` (T1 unsets, T2 hook+launchd `core.bare` guard, T3 hostile-env probe) |
| 4 | `bin/dispatch.sh::allowed_tools_for` for `implementing` and `ui` ships `Bash(git:*)` | verified | `bin/dispatch.sh:248` (implementing) and `bin/dispatch.sh:249` (ui) both contain the literal string `Bash(git:*)` |
| 5 | `bin/dispatch.sh:48-65` is the existing `assert_no_tool_invocation` helper used by ENG-43 | verified | `bin/dispatch.sh:48-65` defines `assert_no_tool_invocation transcript pattern` with the `startswith` jq filter |
| 6 | `bin/run-local-helpers.sh` is sourced by `bin/run-local.sh` | verified | `bin/run-local.sh:28` `source "$SCRIPT_DIR/run-local-helpers.sh"` |
| 7 | `linear.sh add-or-update-comment <sig> <ident> <body>` exists and uses `meta: dedup` shape | verified | CLAUDE.md "When wiring a new script" § "linear.sh add-or-update-comment so the new shape `<!-- meta: dedup key=… -->` marker"; usage examples throughout `bin/run-stage.sh` and `bin/classify-failure.sh` |
| 8 | `bin/pipeline-events.json` registry includes `protocol-violation` halt reason | verified | `bin/pipeline-events.json:16` `"protocol-violation"` |
| 9 | `core.bare` is stored in the *shared* `$GIT_COMMON_DIR/config`, not a per-worktree fragment | verified | git official docs: `git help config-variables` lists `core.bare` under "Config files for working tree shared values"; `.githooks/pre-commit:53` reflects the same with `git --git-dir="$HARNESS_GIT_DIR" config core.bare false` (no `--worktree` flag) |
| 10 | `git init` does NOT set `core.bare=true` without explicit `--bare` flag, even when `GIT_DIR` is set without `GIT_WORK_TREE` | verified | git-init(1) man page (fetched 2026-05-07): "`--bare`: Create a bare repository. If `GIT_DIR` environment is not set, it is set to the current working directory." `core.bare` is set on init only via `--bare`; re-init is non-destructive of existing config (`git init` man page: "Running `git init` in an existing repository is safe. It will not overwrite things that are already there.") |
| 11 | `failure_outcome_for_exit` maps exit 13 to `lane-violation` | verified | `bin/common.sh:119` `13) printf 'lane-violation'` |
| 12 | `$PROJECT_STATE_DIR` is the canonical per-project scratch root | verified | `bin/common.sh:56-60` resolves `PROJECT_STATE_DIR=${HARNESS_STATE_DIR}/${PROJECT_SLUG}`; CLAUDE.md "Per-issue state directory" § confirms |
| 13 | `bin/pipeline-events.json:11` includes `agent-blocked` halt reason for D-005's escalation path | verified | `bin/pipeline-events.json:11` `"agent-blocked"` |
| 14 | Forensic capture's parallel artifact dump using `&` + `wait` is bash-3.2 compatible (macOS default) | assumed | bash 3.2 supports `&` and `wait`; the harness CLAUDE.md "Common commands" § already runs on bash 3.2+ per the project profile. To be re-verified during implement stage with a smoke test on a 3.2 host. |
| 15 | The pre-commit hook's `set -uo pipefail` (no `-e`) means a `source` of a missing helper falls through to fallback | assumed | `.githooks/pre-commit:12` `set -uo pipefail` confirmed; the `[[ -f ... ]] && source ...` guard pattern is standard. To be re-verified that the fallback inline heal still runs when source is skipped. |
| 16 | `learned-rules/harness/brainstorm.md` does not exist (the prompt asked to read it "if present") | verified | `Glob('learned-rules/harness/brainstorm.md')` (and listing of `learned-rules/harness/`) shows only `build.md` and `project-profile.md` |
| 17 | `docs/VISION.md`, `docs/ARCHITECTURE.md`, `docs/knowledge/decisions.md`, `docs/knowledge/gotchas.md` do not exist | verified | `ls docs/` returns `brainstorms`, `pipeline-vocabulary*.md`, `plans`, `runbooks` only; no `VISION.md`, no `ARCHITECTURE.md`, no `knowledge/` |

## 10. Scope flags and conflicts with existing architecture

### Scope flags

- **D-002 enumerated allowlist** is a *general* hardening that
  exceeds the literal "investigate the trigger" scope of ENG-68.
  Justified because (a) it pre-emptively closes the highest-prior
  trigger class, and (b) the change is small and locks naturally
  with D-003 + D-004. Could be split off as a separate hardening
  ticket (ENG-68-A?) if the operator prefers a smaller PR; the plan
  stage may surface this as an opt-out.
- **D-005 escalation path** sketches a future ENG-68-2 ticket but
  does not commit to opening it. The 30-day decision window is
  documented in the runbook only; nobody opens ENG-68-2 unless
  recurrence data demands it.
- **OQ-2 fswatch** is explicitly out of scope; flagging here so a
  future widening doesn't get folded into ENG-68 by accident.

### Conflicts with existing architecture

None identified. Specifically:

- The forensic-dump dir (`$PROJECT_STATE_DIR/forensics/`) is a new
  sibling of `logs/` and `metrics/` under the per-project state
  root; CLAUDE.md "Per-issue state directory" §'s tree shows
  `logs/`, `metrics/`, and `<ENG-N>/` as the existing children.
  Adding `forensics/` does not collide with any other consumer.
- The Linear comment with sig `core-bare-flip/<utc-iso-day>` adds a
  new sig namespace under the existing dedup contract; no existing
  caller uses this prefix (`grep -rn 'core-bare-flip' bin/` returns
  empty). Closed-vocabulary discipline holds because the sig is
  generated programmatically, not parsed; new sigs do not require a
  registry entry.
- The transcript-based assertion patterns from D-003 do not collide
  with the existing ENG-43 `gh pr create` pattern; the wrapping
  loop iterates a list and runs the same matcher per pattern.

## 11. Persona review

Personas were applied in the order: design → security → scope →
coherence → product → feasibility (gating). Iteration cap = 2 per
ENG-65 D-001.

### Iteration 1

#### design — PASS

D-001 (forensic capture), D-002 (allowlist tightening), D-003
(transcript assertion), and D-004 (regression test) attack the
problem at four independent layers and compose:

- D-001 produces evidence — required for AC #1 ("trigger identified")
  and for D-005's decision rule.
- D-002 + D-003 close the highest-prior hypothesis pre-emptively —
  required for AC #2 ("permanent fix at the source") under the
  H1 case.
- D-004 locks both in — required for AC #3 ("regression test").
- D-005 gives the investigation a finite closure horizon.

The architecture is layered correctly: capture before heal, sandbox
before assertion, regression test on top. No persona-1 P0/P1.

One P2: the brainstorm carries a non-trivial assumption (#9 — that
`core.bare` is in the shared common-config). If git ever introduces
a per-worktree override for `core.bare` (it has not, as of git
2.46), D-002's reasoning weakens: a worktree-scoped flip wouldn't
affect the parent. The assumption is verified against current
behavior; flagged as a future-watch item, not a P0.

#### security — PASS

No new auth surface. No secret materialization risk; the secret-
handling rule (`${VAR-}` empty-fallback only) is observed across all
new code paths described:

- Forensic capture's `env-snapshot` dump filters by
  `^(GIT_|PIPELINE_|TARGET_|HARNESS_|PROJECT_)` — no secret-name
  prefix is in the regex (no `*KEY|*TOKEN|*SECRET|ANTHROPIC*|GITHUB*|LINEAR*`).
  A defensive double-check: rerun `env | grep -E '^(GIT_|PIPELINE_|TARGET_|HARNESS_|PROJECT_)'` — none of those prefixes shadow a
  secret-name prefix. (The harness's actual secrets — `LINEAR_API_KEY`,
  `GITHUB_TOKEN`, `GH_APP_PRIVATE_KEY_PATH` — start with `LINEAR_`,
  `GITHUB_`, `GH_`, all explicitly excluded by the regex.)
- The Linear comment body posted by D-001 carries only
  `<!-- meta: forensic kind=core-bare-flip path=<forensic_root> -->`
  + a one-line description; no forensic *content* is inlined in the
  comment.
- The forensic dir lives under `$PROJECT_STATE_DIR` which is
  already operator-readable on the launchd host; no new world-
  readable file mode is introduced.
- The transcript assertion (D-003) does NOT log the matched
  `tool_use.input.command` content beyond what the existing ENG-43
  helper already does; no expansion of the agent-input log surface.

No P0 / P1.

#### scope — PASS

The brainstorm addresses the three ACs from the Linear issue:

- **AC #1** (trigger identified, deterministic reproduction): D-001
  produces the data; H1 is the most likely candidate, locked out
  by D-002. If recurrence data refutes H1, D-005's escalation path
  picks up.
- **AC #2** (permanent fix at the source): D-002 + D-003 are the
  pre-emptive fix for H1; D-005 names what "permanent fix" means
  if the recurrence data points elsewhere.
- **AC #3** (regression test): D-004 with three sub-cases (T4a/b/c)
  covers both trigger classes and includes a positive control.

Out-of-scope, explicitly flagged in §10:
- D-002's enumerated allowlist is broader than the literal "find
  the trigger" framing, justified above and noted as a possible
  split-off if the plan stage prefers tighter scope.
- D-005 escalation is documented but not committed; opening
  ENG-68-2 is conditional on data.
- fswatch (OQ-2) is explicitly out of scope.

Nothing is implemented beyond AC scope without justification or
scope-flag.

No P0 / P1.

#### coherence — PASS

- All decisions cite anchors in CLAUDE.md or the existing code:
  - D-001 → ADR-PROPOSED-1 + CLAUDE.md "Per-issue state directory"
  - D-002 → CLAUDE.md "When wiring a new script" § principle of
    granting exactly what's needed
  - D-003 → CLAUDE.md "When wiring a new script" § "Defense-in-
    depth on top of tool-lane denials" (literal quote of the
    existing rule, ENG-43 as precedent)
  - D-004 → AC #3 + existing test-isolation-test.sh structure
  - D-005 → 30-day window matches the learned-rules cadence
- The naming is consistent with existing brainstorm conventions
  (D-NNN for decisions, OQ-N for open questions, T4a/b/c for sub-
  test cases mirroring the ENG-64 D-5 table style).
- The architecture diagram (§4) lists the exact file:line touch
  points; the data-flow diagrams (§5) match the §4 listing.

One P2: the §1 "load-bearing surprise" framing is inherited from
the ENG-64 brainstorm style (which named its surprise "the
field-shift is structural and independent of the sed bug"). Lifting
the same shape here keeps the per-doc local convention but is not
a project-wide standard. Acceptable; flagged for awareness.

No P0 / P1.

#### product — PASS

- Operator workflow on a recurrence (post-fix): tick log shows
  `WARNING: ... had core.bare=true; reset to false`; Linear
  comment with `meta: forensic` shape pings; operator opens the
  forensic dir, reads the artifacts, makes a decision per D-005.
  Compared to today's "log line, no actionable signal" — strictly
  better.
- The decision window (D-005) gives the operator a finite-bounded
  follow-up; no ongoing investigation backlog.
- The pre-emptive trigger-class fix (D-002 + D-003) is invisible
  in the success case (just locks down a foot-gun) and audible in
  the failure case (a halt with `protocol-violation` reason and a
  matched-command body — the operator gets the smoking gun
  immediately, not after capturing forensic data).

No P0 / P1.

#### feasibility — PASS (zero P0, zero P1)

Codebase-fact verification (mandatory per the prompt):

- All file paths and line numbers cited in the brainstorm are
  resolved against the live worktree files (see §9.4 assumption
  inventory rows 1-13: every named function, file, line, and
  config key was opened and quoted with file:line).
- D-002's "enumerated subcommand list" was constructed by reading
  `bin/dispatch.sh:248-253` (implement, ui, building) and pulling
  the union of git subcommands they currently reference, plus the
  obvious read-mostly subcommands (`status`, `log`, `diff`, `show`,
  `ls-files`) the agents demonstrably need. Verified against the
  ENG-43 brainstorm + the implement agent's documented contract in
  `AGENT_PROMPTS.md` §3; no missing subcommand identified that the
  current implement/ui dispatches rely on.
- D-003's transcript-assertion approach was verified to compose
  with the existing helper at `bin/dispatch.sh:48-65`: the helper
  signature (`transcript pattern`) and the soft-fail on missing
  transcript (line 50: `[[ -s "$transcript" ]] || return 0`) both
  match the wrapping-loop usage.
- D-004's T4a / T4b / T4c structure was verified against
  `bin/test-isolation-test.sh`'s existing pattern (T1 = invariant
  on hook content via `grep`, T2 = invariant on heal presence via
  `grep`, T3 = hostile-env probe loop). T4a uses synthetic-
  transcript replay (jq feed into the helper), T4b reuses T3's
  hostile-env probe shape with a new assertion at the end, T4c is
  a positive control. No code-level facts about the helper or the
  loop structure conflict.
- D-005's 30-day window references the runbook (`docs/runbooks/
  recovery.md` exists, verified by `Read('docs/runbooks/recovery.md')`)
  as the home for the new section; no conflicting prior section
  with the same heading exists (`grep -n 'ENG-68' docs/runbooks/recovery.md`
  returns empty).

The two `assumed` rows (#14 bash 3.2 parallel `&`+`wait`; #15
hook fallback on missing source) are tagged for re-verification
during implement, not P0.

No P0 / P1.

### Gate

Iteration 1: 6/6 PASS, feasibility 0 P0. Gate cleared. No iteration 2.
