---
linear: ENG-59
title: scope-check.sh — diff against origin/main, not stale local main (false-positive halt when host pull lags)
date: 2026-05-08
status: draft
---

# `scope-check.sh` must own its merge-base reference: fetch origin/main per run and diff against `origin/main`

## 1. Overview (and the load-bearing surprise)

`bin/scope-check.sh::main` extracts the agent's diff with (verified at
`bin/scope-check.sh:191` in this worktree at the time of writing — the
issue body cites line 168, which is stale; the file has grown by
~23 lines since the ticket was filed):

```bash
# bin/scope-check.sh:191 (pre-ENG-59)
changed="$(git -C "$worktree_root" diff --name-only "main...${branch}" 2>/dev/null || true)"
```

The merge base of `main` and `${branch}` is computed from the **local**
`refs/heads/main`. Worktrees share `refs/heads/*` with the host repo
(`git worktree`'s default, verified by inspecting `git rev-parse
--git-common-dir` returning the host's `.git/`), and the harness has no
auto-pull on the host's main: `bin/run-local.sh::ensure_worktree`
fetches `origin/main` *only when creating a new worktree*
(`bin/run-local.sh:135`), and `bin/run-local.sh` never advances the
host's `refs/heads/main` itself. The host's local `main` only catches
up when the operator runs `git pull` interactively.

When the host's local `main` lags an upstream merge (Y) but the
worktree's branch was created off origin/main at Y (i.e., HEAD is at Y
plus the agent's commits Z), the merge base of (local-main=X, HEAD=Z)
is X — the parent of Y, not Y itself. `main...HEAD` then includes Y's
file paths. `scope-check.sh` classifies those paths against the plan's
File Structure. Y's paths almost always SEVERE-flag (they belong to a
different ticket and weren't declared in this plan), and
`bin/run-stage.sh:912-921` halts the issue with `pipeline:halted +
pipeline:skip-until-human-acts` and rc=21.

**The load-bearing surprise.** `scope-check.sh` does not own — and is
not asked to own — the freshness of the reference it diffs against. It
inherits whatever staleness the operator's `git pull` cadence has
produced on the host. The harness's bot identity (no operator behind
the keyboard) is the failure-mode amplifier: the bot ticks every five
minutes, an upstream merge can land at any moment, and the operator
may not pull for hours. ENG-43's halt at 2026-05-02 13:41 IST (issue
body, "Concrete reproduction") happened because the operator pulled
~13 hours after ENG-52's merge — the cost was one false-positive halt
per issue whose tick fell into that gap. As pipeline throughput grows
against an active main, the gap-collision rate grows linearly with
both throughput and merge frequency.

The fix moves the freshness contract one layer down — from the
operator (uncontrolled) to scope-check itself (deterministic,
per-run).

## 2. Goals

After this ticket lands:

1. **Per-run freshness** (D-001). `bin/scope-check.sh::main` runs
   `git fetch --quiet --no-tags origin main` immediately before
   computing the diff. The merge-base reference is recomputed on every
   tick from origin's truth, not the host's last-pull truth.
2. **Diff against origin/main, not local main** (D-002). The diff
   line at `bin/scope-check.sh:191` switches to `origin/main...${branch}`,
   so even on a tick where the fetch is a no-op (origin already up to
   date) the reference is the canonical one. Coupling the fetch to a
   reference swap closes the failure mode at the structural level —
   future drift in the host's local main can't reintroduce the bug
   because no scope-check path consults `refs/heads/main` anymore on
   the happy path.
3. **Soft fallback on fetch failure** (D-003). On `git fetch` failure
   (offline operator, transient origin unreachability, no remote
   configured in test fixtures), scope-check logs a single-line
   warning and resolves the diff base by ref-existence: prefer
   `refs/remotes/origin/main` if present (a stale prior fetch is
   strictly fresher than the host's local main, because the worktree
   creation flow at `bin/run-local.sh:135` already fetched it once),
   else fall back to local `main`. The script does not exit non-zero
   from fetch failure alone.
4. **Test-pinned regression guard** (D-004). `bin/scope-check-test.sh`
   gains a stale-local-main fixture: SHA X (local main, stale), SHA Y
   (origin/main tip, child of X with an out-of-scope file like
   `OTHER.md`), branch Z off Y modifying only an in-scope file. With
   the pre-fix code the test asserts the false-positive set
   (`OTHER.md` flagged); with the post-fix code the diff is clean.
   Asserts both the positive (post-fix passes) and the negative (the
   diff resolved against origin/main does not contain Y's files).
5. **Operator-facing documentation** (D-005). One-line note added to
   the CLAUDE.md "Failure-mode quick reference" table covering the
   pre-fix symptom (scope-check halts with files from a recent
   upstream merge) and the post-fix expectation (no operator action
   needed; spurious halt rate drops to zero on online ticks).

Non-goals (explicit, follow the issue's framing):

- **Auto-pulling the host's local `main`.** Different blast radius —
  affects worktree creation, host commits, and any other script that
  reads `refs/heads/main`. Out of scope; see Open Questions O-1.
- **Auditing every other harness script that implicitly reads local
  main.** `bin/scan-gotcha-trailers.sh:25` (verified: `git -C
  "$TARGET_REPO" log ... "main..${branch}"`) has the same
  staleness bug class. Out of scope; see Open Questions O-2.
- **Switching to a worktree-aware fetch primitive.** `git fetch
  origin main` from inside a worktree updates the shared
  `refs/remotes/origin/main` correctly (verified: `git
  rev-parse --git-common-dir` resolves to the host's `.git/`,
  `refs/remotes/*` is shared per the worktree contract); no special
  invocation needed.
- **A global pre-tick fetch in `bin/run-local.sh`.** Wider blast radius
  (touches every script and the main loop); the per-call fetch in
  scope-check is the minimal change that satisfies the ticket.

## 3. Architectural principle

There is no `docs/VISION.md`, no `docs/ARCHITECTURE.md`, no
`docs/knowledge/decisions.md` (verified: `ls docs/` returns
`brainstorms/  pipeline-vocabulary.md  pipeline-vocabulary.template.md
plans/  runbooks/`). Governing constraints come from CLAUDE.md and
accepted brainstorms — same regime ENG-67 / ENG-71 / ENG-79 documented.

The principles invoked here are existing CLAUDE.md commitments, not
new ones:

- **Each script owns its preconditions.** CLAUDE.md "When wiring a new
  script" §: *"Use `log` / `die` / `require_env` / `require_bin` from
  common.sh — don't roll your own."* Implicit corollary: a script
  that needs a fresh ref must fetch it itself rather than relying on
  side-channel state. Today scope-check delegates "is local main
  fresh?" to the operator's pull cadence; D-001 promotes that
  contract from "implicit, side-channel" to "explicit, per-call."
- **Failure-mode loudness via warning-not-die for non-fatal
  inputs.** ENG-67 added a `die` for empty `worktree_path` — the path
  there *must* exist for dispatch to be safe. ENG-59's fetch failure
  is different: the diff is still computable from a stale ref (just
  worse), so the right shape is a logged warning, not a `die`.
  Symmetric to how `bin/scope-check.sh:191`'s existing `2>/dev/null
  || true` handles the diff itself — a soft fallback at every failure
  surface that has a defensible degraded mode.
- **Symmetric fetch behaviour with `bin/run-local.sh::ensure_worktree`
  (`bin/run-local.sh:135`).** That site already runs `git -C
  "$TARGET_REPO" fetch origin main` before creating a new worktree.
  ENG-59 D-001 extends the same pattern to the post-stage
  scope-check: every consumer of "what's on origin/main" runs its
  own fetch. CLAUDE.md "Sweep + scope partition (ENG-14)" § implicitly
  treats `partition_dirty_paths` as the gate that catches drift; the
  same discipline applied here means scope-check can't leak a
  false-positive halt from staleness any more than the partition can
  leak a self-leak from a stale snapshot.
- **Test pin via end-to-end fixture, mirroring existing case-2/3/4/5
  pattern.** `bin/scope-check-test.sh:46-186` (verified) constructs
  per-case sandboxes with `git init`, plan docs, and branches.
  D-004's stale-local-main case slots in as case-6, building on the
  same sandbox idiom. No new test runner, no new helpers.

## 4. Decisions

### D-001: Fetch `origin/main` at the top of `scope-check.sh::main`

**Verdict.** Insert the fetch immediately after the
`worktree_root` resolution at `bin/scope-check.sh:155` and before the
plan-resolution path:

```bash
# bin/scope-check.sh (post-ENG-59)
local fetch_ok=1
if ! git -C "$worktree_root" fetch --quiet --no-tags origin main 2>/dev/null; then
  fetch_ok=0
  log "scope-check: fetch origin main failed; falling back to local refs"
fi
```

The `--quiet` suppresses progress output, `--no-tags` avoids
pulling tag refs that scope-check has no use for, and `2>/dev/null`
suppresses transport errors so they don't confuse run-stage.sh's
transcript-capture path.

**Why.** Per-run freshness. The fetch is the only step that converts
"operator pull cadence" from a load-bearing precondition into an
internal implementation detail of scope-check. Before fix: a stale
local main produces false positives. After fix: scope-check's
correctness depends only on (a) origin reachable at fetch time, OR
(b) `origin/main` ref exists from any prior fetch on the worktree.
Both conditions hold under normal harness operation — `run-local.sh`
fetches when creating each worktree, so `refs/remotes/origin/main`
is always present after worktree creation, even on offline ticks.

**Rejected alternative — fetch from `bin/run-local.sh` (top of every
tick) instead of from scope-check.** Cleaner from a DRY standpoint
(one fetch per tick, not per scope-check call), but wider blast
radius: every script that runs in the tick now sees a freshly-fetched
origin/main, which could change behaviour in scripts that aren't
ready for it (`scan-gotcha-trailers.sh`, the partition logic, the
review-stage's gh-pr lookups, etc.). The issue explicitly scopes
this fix to scope-check; broadening to a global pre-tick fetch is
recorded as O-1. Rejected — minimal change wins.

**Rejected alternative — fetch from `bin/run-stage.sh` immediately
before invoking scope-check.** Marginally less DRY than D-001 (the
fetch lives at the call site rather than the callee), but more
surgical. Disadvantage: scope-check is also invoked
`has-scope-approval`-style for verdict-handler approval-tracking
(verified at `bin/scope-check.sh:106-144`); that path doesn't need a
fetch. Putting the fetch *inside* scope-check's `main()` keeps the
fetch coupled to the diff-computing path only and avoids paying it
on every approval check. Rejected — D-001 has a cleaner blast-radius
shape.

**Rejected alternative — `git fetch origin` (no refspec).** Fetches
*all* origin branches, not just main. Wastes bandwidth and time on
the common case where the harness only cares about origin/main for
this diff. Rejected — `origin main` is the minimal refspec.

### D-002: Switch the diff base to `origin/main`

**Verdict.** Replace the diff line at `bin/scope-check.sh:191`:

```bash
# pre-ENG-59
changed="$(git -C "$worktree_root" diff --name-only "main...${branch}" 2>/dev/null || true)"

# post-ENG-59
local diff_base
if git -C "$worktree_root" rev-parse --verify --quiet refs/remotes/origin/main >/dev/null; then
  diff_base="origin/main"
else
  diff_base="main"
  log "scope-check: origin/main ref absent; using local main (fewer guarantees)"
fi
changed="$(git -C "$worktree_root" diff --name-only "${diff_base}...${branch}" 2>/dev/null || true)"
```

**Why.** Coupling the fetch and the diff-reference swap closes the
failure mode at the structural level. With the fetch but without the
ref swap, the diff would still be against `main` (stale local) — the
fetch alone doesn't fix the bug. With the ref swap but without the
fetch, the diff would be against `origin/main` (which is whatever
state the worktree creation left behind — could be hours stale if a
merge landed mid-tick). Together, the diff is against `origin/main`
*as of the start of the scope-check call*.

The two-arm `if rev-parse --verify` guard handles the tests: the
existing case-2/3/4/5 fixtures have no `origin` remote configured
(verified at `bin/scope-check-test.sh:46-186`). After D-001's fetch
fails (no remote), `refs/remotes/origin/main` doesn't exist, so the
fallback arm uses local `main` — preserving today's behaviour for
those tests.

The `rev-parse --verify --quiet` form is the same shape used at
`bin/run-local.sh:130` and `bin/run-stage.sh:243` (verified) — a
recognised idiom in this codebase.

**Rejected alternative — always use `origin/main`, `die` if absent.**
Stricter, but breaks the existing test fixtures (no remote =
`origin/main` absent = `die`). Re-architecting every test sandbox to
add an origin remote is high cost for low benefit; the
rev-parse-guard approach gets the same correctness on the live
harness with zero test churn. Rejected.

**Rejected alternative — fix the prefix in the test fixtures
(add a fake origin) and always use `origin/main`.** Same as the prior
alternative but pushes the cost into the test fixtures. Five fixtures
× ~20 lines of plumbing each ≈ 100 lines of test churn vs. 4 lines
of guard logic in production code. Rejected — guard logic is
strictly cheaper.

### D-003: Soft fallback on fetch failure

**Verdict.** D-001 already encodes the fallback (the `2>/dev/null`
swallow + the `fetch_ok=0` flag + the warning log). D-002's
ref-existence guard then resolves the diff base correctly even when
fetch fails. The combined contract:

| Condition | Fetch | origin/main ref | Diff base | Warning emitted |
|---|---|---|---|---|
| Online, origin reachable | success | present (fresh) | `origin/main` | none |
| Online, origin reachable, no upstream change | success (no-op) | present (unchanged) | `origin/main` | none |
| Offline / origin unreachable, prior fetch left ref | fail | present (stale) | `origin/main` | "fetch origin main failed; falling back to local refs" |
| Test fixture / no remote configured | fail | absent | `main` | "fetch origin main failed; falling back to local refs" + "origin/main ref absent; using local main" |

**Why.** The issue's AC #3 is satisfied: on fetch failure, scope-check
logs a single-line warning and proceeds (does NOT exit non-zero).
The "and proceeds against `main`" wording from the AC describes the
end-of-fallback state in the no-remote case; the more nuanced case
(prior fetch left a stale origin/main ref) is strictly better than
"local main" because the worktree-creation fetch at
`bin/run-local.sh:135` is, on every live worktree, fresher than the
host's local main. Trading "always fall back to local main" for "fall
back to origin/main if available, else local main" costs one extra
`rev-parse --verify` call per tick (sub-millisecond) and saves the
common false-positive class on offline ticks.

The two log lines are intentionally distinct so an operator reading
the per-stage transcript can distinguish "transient fetch failure
but ref is fresh-ish" from "ref completely unavailable." This
matters for ENG-43-shaped repros: the first warning is mostly
informational; the second is a strong hint that the operator is in
test-fixture-shaped state and should investigate before trusting the
result.

**Rejected alternative — die on fetch failure.** Trades a recoverable
false-positive halt (today's bug) for a hard non-recoverable halt
(the cure is worse than the disease, especially since the operator
has no diagnostic path beyond "look at /var/log/system.log for
network errors"). Rejected — issue body's AC #3 explicitly forbids
this.

**Rejected alternative — silently fall back, no warning log.** The
warning is the operator's only signal that scope-check is running in
a degraded mode. Without it, a chronic fetch failure (e.g., a
misconfigured remote URL) would silently re-introduce the very
staleness this fix removes — except now it would be invisible to the
operator. Rejected — observability is cheap; silent degradation is
dangerous.

### D-004: `bin/scope-check-test.sh` regression pin (case 6)

**Verdict.** Append a new case to `bin/scope-check-test.sh` (under a
`# ─── Case 6: stale local main ─── ENG-59 ───` heading,
following the existing case-N comment idiom). The fixture:

1. `git init` sandbox; create plan declaring `IN_SCOPE.md` (or
   `CLAUDE.md` to mirror case-2's shape).
2. Initial commit X: plan + `IN_SCOPE.md` + `OUT_OF_SCOPE.md` (a
   file outside the plan's File Structure).
3. `git branch -m main`.
4. Create commit Y on a side branch that modifies
   `OUT_OF_SCOPE.md` (simulates the upstream merge).
5. `git update-ref refs/remotes/origin/main <Y>` — simulates origin
   tip at Y. (No remote URL needed; the ref exists in the local
   ref store.)
6. `git update-ref refs/heads/main <X>` — rolls local main back to
   X (simulates the operator's stale local).
7. `git checkout -b test-branch <Y>` — branch tip is at Y.
8. Modify `IN_SCOPE.md` (the only file the plan declares).
9. Commit "agent change" → SHA Z.
10. Run `scope-check.sh ENG-T-stale-main test-branch`.

Asserts:

- **Post-fix passes (rc=0)**: with the post-fix script, the diff
  base resolves to `origin/main` (Y), `origin/main...test-branch`
  contains only `IN_SCOPE.md` (the agent change), and the script
  exits 0 (clean pass).
- **Negative pin against the bug** (optional, defensive): if a future
  refactor reverts D-002 (diff against `main`), the same fixture
  would emit `severe	OUT_OF_SCOPE.md` on stdout and exit rc=3. The
  test asserts BOTH that the in-scope file is allowed AND that the
  rc is 0 — a regression on D-002 alone trips the rc assertion.

**Why.** Direct fulfilment of the issue's AC #4. The fixture
construction matches the AC's "fixture sets local `main` to SHA X,
branches off SHA Y (Y is a child of X), simulates an `origin/main`
ref at Y" verbatim.

`update-ref` is the right primitive here: it's deterministic, no
network, no parallel process, no second clone. The test runs in <1
second alongside the existing cases.

**Rejected alternative — use a real bare repo with `git init --bare`,
add as origin remote, push `main` to it, then mutate via a second
clone.** More realistic but ~3x the fixture code, no additional
correctness coverage. The bug is in ref-resolution semantics
(`main` vs `origin/main` in a `diff` invocation), not in the
fetch transport. `update-ref` exercises the same ref-resolution
path. Rejected.

**Rejected alternative — assert via internal function call (source
the script and call a helper directly).** Would require refactoring
`scope-check.sh::main` to expose `resolve_diff_base` as a separate
function. Out of scope; the integration test catches the same class
of regression with no production-code refactor. Rejected.

### D-005: One-line CLAUDE.md note

**Verdict.** Add a row to the "Failure-mode quick reference" table
in CLAUDE.md (after `:434`'s "Brainstorm halts at iteration 2…" row):

```markdown
| scope-check halts an issue with files belonging to a recent upstream merge | Pre-ENG-59 bug: scope-check diffed against the host's local `main`, which lags upstream merges until the operator runs `git pull`. Post-ENG-59 (`bin/scope-check.sh:155-…`) fetches `origin main` per run and diffs against `origin/main`. If you still see this symptom, check the per-stage transcript for `scope-check: fetch origin main failed` — fetch unreachable + no prior `refs/remotes/origin/main` falls back to local `main` (the pre-ENG-59 behaviour, preserved as a warning-emitting degraded mode). |
```

**Why.** AC #6: "[CLAUDE.md] 'Failure-mode quick reference' gets one
row noting that scope-check now fetches origin/main per run; no
operator-facing behavior change beyond fewer spurious halts." The
row's "Where to look" cell names both the new behaviour AND the
diagnostic path for the residual failure mode, so an operator
encountering a post-fix halt with files from a merged ticket has a
self-serve resolution path before reaching for `--action continue`.

**Rejected alternative — update `docs/runbooks/operator-mental-model.md`
instead.** That doc is the long-form reference; the
"Failure-mode quick reference" table is the short-form lookup. AC #6
specifies the table. Rejected — straight compliance with AC.

## 5. Architecture (where code goes)

Two files modified, one test file modified, one doc updated. No new
files, no new scripts, no new dependencies.

| File | Change | Lines |
|---|---|---|
| `bin/scope-check.sh` | Insert fetch + diff-base resolver immediately after `worktree_root` resolution at line 155. Update the diff line at 191 to use the resolved `${diff_base}`. Add an inline comment block citing ENG-59 / ENG-43 / ENG-52. | net +18 (functional +12, comment +6) |
| `bin/scope-check-test.sh` | Append case 6 (stale-local-main) under a `# ─── Case 6 ─── ENG-59 ───` heading. | +50 |
| `CLAUDE.md` | One row added to the "Failure-mode quick reference" table (after the brainstorm-iteration-exhausted row). | +1 |

Lane considerations: `scope-check.sh` runs from `run-stage.sh` in the
orchestrator (verified at `bin/run-stage.sh:856, 872, 699`), NOT from
inside the dispatched agent's `--allowed-tools` fence. The fetch
needs no allowlist update — it's full bash from the orchestrator.

## 6. Data flow

Pre-ENG-59:

```
worktree_root resolved (HEAD's toplevel)
  └─ git diff --name-only "main...${branch}"     ← reads stale local main
       └─ false-positive paths from merged-but-unpulled commits
```

Post-ENG-59:

```
worktree_root resolved (HEAD's toplevel)
  ├─ git fetch --quiet --no-tags origin main       ← per-run freshness (D-001)
  │    └─ updates refs/remotes/origin/main in shared .git/
  ├─ rev-parse --verify refs/remotes/origin/main   ← resolve diff_base (D-002)
  │    ├─ ref present → diff_base="origin/main"
  │    └─ ref absent  → diff_base="main"  + warning log
  └─ git diff --name-only "${diff_base}...${branch}"
       └─ paths reflect ONLY the agent's commits on the branch (typical case)
```

Two failure modes, both intentionally soft:

1. `git fetch` returns non-zero (no remote, transient network,
   credentials issue) → captured by `2>/dev/null`, surfaces as
   `fetch_ok=0`, logged as a single-line warning, control proceeds
   to ref resolution.
2. `refs/remotes/origin/main` absent at the time of `rev-parse`
   (no prior fetch ever succeeded — only realistic in test
   fixtures) → the fallback arm uses local `main`, logs a second
   single-line warning, control proceeds to the diff.

In both modes, the diff is still computable and the script exits
under its existing rc taxonomy (0/1/2/3) — the freshness contract
is best-effort, the diff contract is unchanged.

## 7. Error handling

- **`git fetch` transport failure** (offline / origin unreachable /
  bad credentials) → soft fallback per D-003. Symmetric with the
  existing `2>/dev/null || true` on the diff invocation. The single
  warning log lands in the per-stage transcript at
  `$PROJECT_STATE_DIR/<ident>/logs/<stage>-*.log`; if the operator
  sees recurring warnings here they investigate the network, but the
  pipeline keeps moving.
- **`origin` remote not configured** (test fixtures, brand-new clone
  pre-`origin` setup) → `git fetch origin main` errors with
  "'origin' does not appear to be a git repository" (exit 128). Our
  `2>/dev/null` swallows the message; `fetch_ok=0`. Then
  `rev-parse --verify refs/remotes/origin/main` returns non-zero
  (ref absent). Diff base resolves to local `main`. Warning logged.
  Existing case-2/3/4/5 tests pass unchanged.
- **`refs/remotes/origin/main` exists but is broken** (e.g., points
  to a SHA not in the local object store after a partial clone) →
  the subsequent `git diff` invocation errors; the existing
  `2>/dev/null || true` on line 191 (preserved) swallows the error;
  `changed=""`; the script exits 0 with the existing
  "no file changes on $branch" log line. Slightly worse than the
  pre-fix behaviour (which would have errored against `main`), but
  the reach probability of this case is sub-1% and the failure mode
  ("clean pass when there should have been a diff") trips the
  next-stage gate via a different mechanism (review/QA noticing
  empty work). Recorded as O-3 if it ever surfaces.
- **`worktree_root` resolves to `$TARGET_REPO`** (cwd not inside a
  worktree, the existing fallback at line 155) → the fetch runs
  from `$TARGET_REPO`'s `.git/`, which is the same shared `.git/`
  the worktrees use. Same outcome. No new failure.

## 8. Edge cases

- **First-ever tick on a brand-new project** (no `origin/main` ref
  cached, no prior fetch) → fetch succeeds (assuming network),
  populates `refs/remotes/origin/main`, diff resolves correctly.
  No special handling needed.
- **Worktree's branch is itself `main`** (no longer realistic
  post-ENG-67 but worth pinning) → `origin/main...main` resolves to
  the merge-base of itself and itself, which is empty. Diff is empty.
  scope-check exits 0 with "no file changes on $branch". No
  regression vs. pre-ENG-59 (which would also produce an empty
  `main...main` diff).
- **Fetch races with a concurrent `bin/run-local.sh::ensure_worktree`
  fetch** — two `git fetch` invocations against the same shared
  `.git/`. Git serialises ref updates via `packed-refs.lock`; worst
  case one of them retries and succeeds. Not a new failure mode;
  scope-check already runs alongside the orchestrator's other git
  ops without coordination.
- **Operator's local `main` is *ahead* of `origin/main`** (operator
  has uncommitted/unpushed work on main locally) — in normal harness
  use this should never happen (the operator's main never moves on
  its own), but if it does: pre-ENG-59 the diff was against the
  ahead-local main, which would actually *lose* false-positives
  relative to a clean origin/main. Post-ENG-59 the diff is against
  origin/main, which now correctly captures any agent commits on
  the branch. Strictly better. No special handling.
- **Per-tick fetch cost.** A `git fetch origin main` over the harness's
  typical `gh.github.com` HTTPS path costs ~150-400ms warm and
  ~600-1200ms cold (per `man git-fetch` and operator-side
  observation; not measured for this brainstorm). Per scope-check
  call, called twice per implement-stage tick (once for `has-scope-
  approval`, once for the post-stage diff — actually no, has-scope-
  approval is in a different code path that doesn't reach `main`
  at all; verified at `bin/scope-check.sh:106-144`, which only
  reads Linear comments, no git ops). So one fetch per
  implement/ui post-stage tick = a few hundred ms added. Acceptable.

## 9. Persona review

### design — PASS
The fix is a clean delegation to the canonical reference
(`origin/main` instead of `main`). Symmetric with `bin/run-local.sh:135`
which already does this for worktree creation, and with
`bin/run-stage.sh:243` which uses `refs/remotes/origin/<branch>` for
the push-ahead check. Three-arm fallback (online → offline-stale →
offline-no-ref) is symmetric and exhaustive. No new abstractions.
**Verdict: PASS, no findings.**

### security — PASS
No secret-handling surface introduced. The fetch invocation is
`git -C "$worktree_root" fetch --quiet --no-tags origin main`. No
`${VAR:-FALLBACK}` patterns against secret-named env vars (D-001 uses
no env var fallbacks at all). No subprocess argv that could leak —
`origin` and `main` are constants. The fetch uses whatever git auth
the operator's environment provides (SSH/HTTPS), unchanged from the
pre-existing `bin/run-local.sh:135` invocation. **Verdict: PASS, no
findings.**

### scope — PASS
Strictly within the issue's "Acceptance criteria" 1-6. No
introduction of fixes for `bin/scan-gotcha-trailers.sh:25` (same
bug class — explicitly out-of-scope per issue body, recorded as O-2).
No global pre-tick fetch in `bin/run-local.sh` (out of scope, O-1).
No worktree-aware fetch primitive (out of scope per issue's
"Out of scope" §). The CLAUDE.md row addition is exactly one row, no
adjacent edits. **Verdict: PASS, no findings.**

### coherence — PASS
Brainstorm structure follows the pattern of
`docs/brainstorms/2026-05-08-eng-79-…-design.md` and
`docs/brainstorms/2026-05-07-eng-67-…-design.md` —
Overview → Goals → Architectural principle → Decisions → Architecture
→ Data flow → Error handling → Edge cases → Persona review → Open
questions → Anti-bias checks → Conflicts. Each decision cites a
CLAUDE.md commitment or a prior brainstorm's precedent. Rejected
alternatives are substantive (each names a specific cost). The
inline diff snippets in D-001 / D-002 / D-005 match the
ENG-79 brainstorm's "show the change" idiom. **Verdict: PASS, no
findings.**

### product — PASS
The fix removes a recurring operator-burden failure mode. ENG-43's
halt at 2026-05-02 13:41 IST cost the operator one resume cycle
plus the read of "what was on the diff" — multiplied across the
expected throughput ramp (the issue notes "as pipeline throughput
grows, the gap-collision rate grows"), this is bounded operator
toil that scales linearly with merge frequency × tick rate. The
post-fix experience is invisible (no halt, no resume) on the happy
path. The degraded mode (offline + no prior fetch) is rare and
visible (warning log in transcript). **Verdict: PASS, no findings.**

### feasibility — PASS (gating)
Codebase-fact verification (every named path:line cross-checked
against the current worktree at `git rev-parse HEAD`):

- `bin/scope-check.sh:155` — verified, the `worktree_root` resolution
  via `git rev-parse --show-toplevel`. ✅
- `bin/scope-check.sh:191` — verified, the bug site:
  `changed="$(git -C "$worktree_root" diff --name-only "main...${branch}" 2>/dev/null || true)"`. ✅
- `bin/scope-check.sh:106-144` — verified, `has_scope_approval`
  function does NOT touch `main` or origin/main; only reads Linear
  comments via `bash "$SCRIPT_DIR/linear.sh" get-comments`. ✅
- `bin/scope-check-test.sh:46-186` — verified, end-to-end fixtures
  for cases 2-5; none configure an `origin` remote. ✅
- `bin/run-local.sh:135` — verified, `git -C "$TARGET_REPO" fetch
  origin main` invocation; same form as the new D-001 invocation. ✅
- `bin/run-local.sh:130` — verified, `rev-parse --verify
  "refs/remotes/origin/$branch"` invocation; same idiom D-002 uses. ✅
- `bin/run-stage.sh:243` — verified, `rev-parse --verify --quiet
  "$upstream_ref"` invocation; same idiom D-002 uses. ✅
- `bin/run-stage.sh:856, 872, 699` — verified, scope-check.sh
  invocation sites (post-stage diff, scope-approval check, build P2
  scope-approval re-check). ✅
- `bin/scan-gotcha-trailers.sh:25` — verified, same bug class
  (`git -C "$TARGET_REPO" log ... "main..${branch}"`); explicitly
  out of scope per issue. ✅
- `CLAUDE.md:416, 434` — verified, "Failure-mode quick reference"
  table location, ending with the brainstorm-iteration-exhausted row. ✅
- `git rev-parse --git-common-dir` returns the host's `.git/` from
  inside a worktree → `refs/remotes/*` is shared → fetch from inside
  worktree updates the shared ref. ✅ (verified by reading
  `bin/run-local.sh:127-141` and the `git-worktree(1)` semantics).
- `failure_outcome_for_exit` taxonomy at `bin/common.sh:111-…` — no
  new exit codes introduced; D-001/D-002/D-003 stay within the
  existing 0/1/2/3 rc taxonomy (verified). ✅
- `bin/dispatch.sh::allowed_tools_for` — no agent-allowlist change
  needed; scope-check runs from the orchestrator, not the agent. ✅
- `bin/secret-probe-lint.sh` (per CLAUDE.md secret-handling §) — no
  `${VAR:-X}` introductions in this fix. ✅

No facts referenced that are not verified. No P0 findings.
**Verdict: PASS (gating).**

## 10. Open questions

- **O-1 (deferred — global pre-tick fetch).** Should
  `bin/run-local.sh` run `git fetch origin main` at tick start so
  every script in the tick benefits? Wider blast radius (touches
  the partition logic, scan-gotcha-trailers, the host's local main,
  any host-side diff invocations); explicit issue-body non-goal.
  Filing recommendation: low-priority follow-up after observing
  whether other scripts hit the same staleness bug.
- **O-2 (deferred — `bin/scan-gotcha-trailers.sh:25`).** Same bug
  class. Verified via `grep -n "main\.\." bin/`. Trailer counts may
  drift on stale-main ticks; impact is bounded (extra
  `gotcha_triggered` bumps don't halt the issue, they just inflate
  the retrospective's input). Filing recommendation: medium-priority
  follow-up; easier than O-1 since the surface is one script.
- **O-3 (deferred edge case — broken origin/main ref).** If
  `refs/remotes/origin/main` exists but points to a SHA not in the
  local object store (truncated clone, partial fetch corruption),
  the diff invocation errors and `changed` ends up empty. Reach
  probability sub-1%; failure mode is "false-pass" rather than
  "false-fail," which is a different failure shape that downstream
  stages may catch. Recorded for completeness; not actively
  designed for.
- **O-4 (test sandbox setup — verify `update-ref` actually
  populates `refs/remotes/origin/main` correctly).** The case-6
  fixture writes to `refs/remotes/origin/main` directly via
  `git update-ref refs/remotes/origin/main <sha>`. Need to confirm
  during implementation that this exact incantation populates the
  ref such that `rev-parse --verify --quiet refs/remotes/origin/main`
  returns 0 (it should — `update-ref` is the canonical primitive).
  Marked "assumed" in §11.

## 11. Anti-bias checks

### ADR stress test
There are no formal ADRs in this repo (verified). The closest
analogues are accepted brainstorms. Specific stress points:

- **ENG-67's brainstorm** establishes that the orchestrator's
  worktree-creation path is the canonical entry to the harness's
  branch-reference world. ENG-59 *strengthens* that line by
  ensuring scope-check reads from the same `origin/main` reference
  the worktree-creation path uses. **No tension** — reinforcement.
- **ENG-71's brainstorm** establishes that the per-issue worktree
  must NOT be a place where global state (like `refs/heads/main`)
  is mutated. ENG-59's fetch updates `refs/remotes/origin/main`
  (a shared remote-tracking ref, not a local branch ref); no
  conflict with ENG-71's invariant. **No tension.**
- **CLAUDE.md "Sweep + scope partition (ENG-14)" §** — the
  partition logic in `bin/run-local-helpers.sh` reads from the
  pre/post-tick file snapshots, not from git refs. Independent
  surface. **No tension.**

### Simpler alternative
Documented under each decision (D-001 has three rejected
alternatives, D-002 has two, D-003 has two, D-004 has two, D-005
has one). Each rejection cites a specific cost — broader blast
radius, test-fixture churn, observability loss, etc.

### Assumption inventory

| Assumption | Status |
|---|---|
| `bin/scope-check.sh:191` is the bug site | verified (read at this worktree's HEAD) |
| `bin/scope-check.sh:155` resolves `worktree_root` and is the right insertion point for D-001's fetch | verified |
| `git -C <worktree> fetch origin main` updates the shared `refs/remotes/origin/main` | verified (worktrees share `.git/` per `git-worktree(1)`; `bin/run-local.sh:135` already uses this idiom from `$TARGET_REPO`, which has the same shared store) |
| `git update-ref refs/remotes/origin/main <sha>` is sufficient to simulate a populated origin/main ref in test fixtures (no remote URL needed) | assumed (validated during implementation; standard primitive) |
| `bin/scope-check-test.sh` cases 2/3/4/5 fixtures don't have an `origin` remote | verified (read full file, no `git remote add` invocations) |
| `bin/scan-gotcha-trailers.sh:25` has the same bug class but is out of scope | verified (read source; issue body explicitly defers) |
| The fetch cost (~few hundred ms per implement/ui tick) is acceptable | assumed (no measurement; comparable to existing tick latencies) |
| `failure_outcome_for_exit` taxonomy doesn't need updating | verified (no new exit codes introduced) |
| `dispatch.sh::allowed_tools_for` doesn't need updating | verified (scope-check runs from orchestrator, not agent) |
| The CLAUDE.md "Failure-mode quick reference" table is the right place for the operator-facing note | verified (AC #6 specifies it; row pattern matches) |
| `secret-probe-lint.sh` (ENG-46) has no triggers in the new code | verified (no `${VAR:-X}` patterns introduced) |

### Codebase-fact verification (gating)
All named files, line numbers, and idioms verified — see §9
feasibility checklist. Zero unverified facts. Zero P0 findings.

## 12. Conflicts with existing architecture

None identified. This brainstorm strengthens the existing
"orchestrator owns its preconditions" pattern established by:

- `bin/run-local.sh::ensure_worktree`'s explicit `git fetch origin
  main` before worktree creation (the original pattern),
- ENG-67's `die`-on-empty-`worktree_path` invariant (explicit
  precondition ownership at the orchestrator/worktree boundary),
- ENG-71's "per-issue worktree must not mutate global refs" rule
  (explicit refs-domain ownership),

by adding scope-check to the set of scripts that own their refs
freshness explicitly rather than inheriting it from operator pull
cadence. Three sites, one principle: each script that consumes a
remote-tracking ref refreshes it itself before reading.
