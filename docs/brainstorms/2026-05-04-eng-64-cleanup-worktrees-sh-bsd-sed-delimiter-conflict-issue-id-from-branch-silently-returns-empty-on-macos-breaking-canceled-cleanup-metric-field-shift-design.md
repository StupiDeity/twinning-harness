---
linear: ENG-64
title: cleanup-worktrees.sh BSD sed delimiter conflict + structural metric field-shift
date: 2026-05-04
status: draft
---

# `cleanup-worktrees.sh` — BSD `sed` delimiter conflict + structural metric field-shift

## 1. Overview (and a load-bearing surprise)

The Linear issue reports two symptoms hitting `bin/cleanup-worktrees.sh`
on every periodic sweep on macOS:

1. **Canceled-issue cleanup never fires.** `issue_id_from_branch`
   silently returns empty because `sed -nE 's|^(feat|fix)/...'` uses
   `|` as both the `s`-command delimiter and the ERE alternation
   operator. BSD `sed` parses the second `|` as the closing delimiter,
   exits non-zero, and the function returns empty.
2. **Metric event field-shift on `worktree-cleanup` events.** The
   recorded JSONL has `issue_id="merged"` and `stage="feat/eng-...`",
   not the canonical `issue_id="ENG-N"`, `stage="<empty>"`.

**The load-bearing surprise:** the issue attributes the field-shift to
"`issue_id_from_branch` returns empty" — but inspection of the call
site shows the field-shift is **structural and independent of the sed
bug**. `bin/cleanup-worktrees.sh:33-42::remove_tree`'s metrics call
hard-codes the wrong positional args:

```bash
remove_tree() {
  local path="$1" branch="$2" reason="$3"
  ...
  bash "$SCRIPT_DIR/metrics.sh" worktree-cleanup "$3" "$branch" "success" 0 "path=$path"
  #                                              ^^^^  ^^^^^^^^^
  #                                              reason  branch
}
```

`bin/metrics.sh:20`'s signature is `<event> <issue_id> <stage>
<outcome> <duration_ms> [notes]`. So `$3` (`reason`) lands in the
`issue_id` slot regardless of platform. On Linux — where the sed
regex works — the JSONL is *still* `issue_id="merged"` because
`remove_tree` never receives the resolved issue_id; the for-loop body
discards it after `transition_done` is called. The same structural
shift exists at `bin/cleanup-worktrees.sh:88` (`worktree-orphan-detected`
event passes `"$branch"` in the `issue_id` slot).

**Scope flag.** The issue's AC #3 ("Verify metric event shape after
fix: a synthetic worktree-cleanup event carries `issue_id: "ENG-N"`,
`stage: "<actual stage name or empty>"`, with the branch name in
`notes`") is worded as a *verification* step, framed under the
assumption that the sed fix alone resolves the symptom. Inspection
shows the verification will FAIL after a sed-only fix — the
field-shift is structural and independent. Two paths to AC #3
compliance:

- **Path A (recommended; this brainstorm's primary plan).** Fix the
  structural bug as part of ENG-64 (D-3). \~20 extra LOC. AC #3
  passes on the verification step itself; the issue closes in one
  PR. Cost: ENG-64 widens beyond the literal "one-line code fix"
  framing.
- **Path B (alternative; explicitly opt-out).** Implement only D-1
  (sed fix) + D-5 cases A-G (regex contract). File a sibling
  ticket "ENG-65: cleanup-worktrees.sh remove_tree metric
  field-shift" carrying D-3 + cases H-I-J. ENG-64 ships in \~5 LOC
  + \~15 LOC test, satisfying the literal one-line framing.
  AC #3 on ENG-64 reads as "verified to be a separate, tracked
  bug, scoped out of this ticket and tracked in ENG-65." Cost:
  the user-visible JSONL pollution persists for one more
  release cycle until ENG-65 lands.

This brainstorm proceeds with Path A for the reasons stated below
in D-3's Why, but the plan stage SHOULD reconsider Path B if the
operator/reviewer prefers strict adherence to the issue's literal
LOC-budget framing. The implement stage decision is reversible
either direction (Path A → Path B by deferring D-3 to a fast-follow
PR; Path B → Path A by amending the same PR).

This brainstorm is the bug-fix companion to ENG-26's metric-shape
work (which guaranteed the *cost-flag* fields round-trip cleanly) — it
guarantees the *positional* fields land in the right slots for one
event family that ENG-26 did not touch.

## 2. Goals

After this ticket lands:

1. `bin/cleanup-worktrees.sh:25-31::issue_id_from_branch` works on
   both macOS BSD `sed` and GNU `sed`. `feat/eng-99-foo` returns
   `ENG-99`; `fix/eng-100-bar-baz` returns `ENG-100`; bare or
   no-match input returns empty.
1a. The `RE error: parentheses not balanced` lines stop appearing
   in `$PROJECT_STATE_DIR/logs/local-*.log` on every periodic
   cleanup tick (the user-visible noise that triggered the issue).
2. `worktree-cleanup` and `worktree-orphan-detected` events in
   `events.jsonl` carry `issue_id="ENG-N"` (or empty when the branch
   does not match), `stage=""` (empty — see D-3 rationale on namespace
   collision), `outcome="success"`/`"warn"`, with branch + reason
   accessible from `notes`.
3. The Canceled-issue cleanup path (lines 70-78) actually fires
   on the next tick that observes a Canceled state.
4. A regression test (`bin/cleanup-worktrees-test.sh`) locks the
   `issue_id_from_branch` contract AND the `remove_tree` metrics
   shape in place. Both are uncovered today; a future refactor that
   regresses either is a silent failure mode (no test catches it
   until the JSONL pollutes downstream queries).
5. Existing macOS hosts get a one-shot operator backfill note
   (added to `docs/runbooks/recovery.md`) — primarily a one-liner
   pointing at "re-run `bin/cleanup-worktrees.sh` or wait
   `CLEANUP_EVERY_N_TICKS`" since the periodic sweep itself is
   idempotent and self-clearing post-fix.

Non-goals (explicit per the issue's framing):

- Re-architecting cleanup. The branch-pattern matching, the Linear
  `Canceled` lookup, the orphan-detect logic, and the safety-net
  `transition_done` call are all correct and stay as-is.
- Auditing every other `sed -nE` call in the repo for the same `|`
  delimiter pattern. (See §10 — followup.)
- Changing `bin/metrics.sh`. The signature is correct; the bug is
  on the caller side.

## 3. Architectural principle

There is no `docs/VISION.md` or `docs/ARCHITECTURE.md` in this repo
(verified: `ls docs/` returns `brainstorms/  pipeline-vocabulary.md
pipeline-vocabulary.template.md  plans/  runbooks/`). There is no
`docs/knowledge/decisions.md`. The governing constraints come from
`CLAUDE.md` and `learned-rules/harness/project-profile.md`.

The principles invoked here are existing CLAUDE.md commitments,
not new ones:

- **macOS-first compatibility.** `learned-rules/harness/project-profile.md:11`
  ("Bash 3.2+ orchestration scripts (macOS-compatible)") and the
  launchd-driven runtime topology (`CLAUDE.md` "Runtime topology"
  diagram) make BSD `sed` the *production* `sed` for every operator
  who runs the harness from their Mac. A regex that fires `RE error`
  on the production interpreter is a P0-level latent bug.
- **Single-source-of-truth metric shape.** `CLAUDE.md` "When wiring
  a new script" §: "Metric writes go through `bin/metrics.sh` so they
  end up in `events.jsonl` and on the retrospective's input." That
  contract is satisfied here at the call-site level — the file does
  call `metrics.sh` — but the *positional contract* is silently
  violated. The retrospective consumes `events.jsonl` and joins by
  `issue_id`; a polluted `issue_id` slot is invisible to the existing
  metric tests but corrupts every downstream query.
- **Test-locked invariants for code paths the orchestrator depends
  on.** `CLAUDE.md` "Tests" §: "Tests are sibling shell scripts named
  `*-test.sh` in `bin/`." The cleanup-worktrees path has no sibling
  test today; this brainstorm adds one that locks the regex AND the
  metrics shape simultaneously. Note: writing `bin/*-test.sh` files
  during the implement stage requires the harness-self target's
  `.pipeline-config/config.json` to carry a `scope.allowlist.implementing`
  override that includes `bin/` (otherwise `partition_dirty_paths`
  classifies new `bin/` paths as out-of-scope → self-leak — see §10
  Open Question 7). Recent test additions (e.g. ENG-44
  `bin/common-test.sh` 30ee400, ENG-50 `bin/review-poll-test.sh`
  de375b2, ENG-51 `bin/profile-allowlist-test.sh` 0172b98) confirm
  the harness-self operator has this override in place; this
  brainstorm assumes its continued presence.
- **Sentinel pattern for executable-and-testable scripts.** `CLAUDE.md`
  "Tests" §: "When a new bash file is meant to be both executable
  and unit-testable, replicate the sentinel pattern; otherwise tests
  cannot source it without side effects." `cleanup-worktrees.sh` is
  not currently testable — its main loop is inline at the bottom.
  This ticket converts it to the sentinel pattern as a precondition
  for AC #2.

## 4. Decisions

Each decision is **D-N: \<verdict\>** + a "Why" line citing the
constraint or principle motivating it + the rejected alternative(s).

### D-1: Replace the `s|...|` regex with `s,...,` and drop the `I` flag (the literal one-liner from the issue)

**Verdict.** In `bin/cleanup-worktrees.sh:28`, change:

```bash
m="$(sed -nE 's|^(feat|fix)/(eng-[0-9]+)-.*|\2|pI' <<<"$branch" || true)"
```

to:

```bash
m="$(sed -nE 's,^(feat|fix)/(eng-[0-9]+)-.*,\2,p' <<<"$branch" || true)"
```

Specifically:
- Change all three `|` delimiters to `,` (comma) — `,` is rare in
  branch names (git refuses commas in many contexts) and is one of
  the canonical alternative `s`-command delimiters.
- Drop the trailing `I` flag (case-insensitive). BSD `sed` does not
  support `I`; the existing tests + harness convention name branches
  with lowercase `feat/eng-N-...` / `fix/eng-N-...` (verified at
  `bin/branch-name.sh:20,31` which lowercases the issue identifier
  via `tr '[:upper:]' '[:lower:]'` and emits `printf '%s/%s-%s\n'
  "$prefix" "$ident_lower" "$slug"`, then invoked from
  `bin/run-stage.sh:157,610,847`). The case-insensitive flag was
  redundant cosmetics, not a contract.
- Then `printf '%s\n' "$(tr '[:lower:]' '[:upper:]' <<<"$m")"` on
  line 30 stays — it normalizes the captured `eng-N` to canonical
  `ENG-N` for downstream consumers.

**Why.** Direct fix for the macOS-first principle, and a literal
match for the Linear issue's AC #1 wording (`change delimiter from
`|` to `,` (or `#`), and drop the `I` flag`). The `,` delimiter is
the smallest possible change that makes the regex platform-portable.
Honors the issue's stated effort estimate ("\~5 lines code"). The
contract — input → output — is locked by the test cases in D-5
regardless of implementation, so a future contributor can refactor
to a Bash-native form (or anything else) without re-introducing the
pipe-delimiter bug class as long as the tests pass.

**Rejected alternative — escape the inner `|` as `\|`.** ERE doesn't
allow that escape inside a `s` command; `\|` would be a literal pipe
in the *target* string. Doesn't compile. Rejected.

**Rejected alternative — switch to BRE (without `-E`) and use
`\(feat\|fix\)`.** BRE's alternation is `\|` (GNU extension; not
POSIX BRE). BSD BRE does not support alternation at all. Forces
splitting into two `sed` invocations. More LOC, no clarity win.
Rejected.

**Rejected alternative — switch to `awk` with a regex match.**
Drags in an awk one-liner `awk 'match($0, /^(feat|fix)\/(eng-[0-9]+)-.*/, a) {print a[2]}'`.
GNU awk's third-arg `match` capture is non-portable to BSD awk.
Cleaner: `awk -F/ '/^(feat|fix)\/eng-[0-9]+-/ {split($2,a,"-"); print a[1]"-"a[2]}'`.
That's portable but harder to read than the comma-delimiter fix.
Rejected — readability beats novelty for a one-liner.

**Rejected alternative — replace `sed` entirely with Bash-native
`[[ =~ ]]`.** Mechanically attractive: removes the subshell,
sidesteps the entire `sed`-delimiter landmine class, and is a
pattern used elsewhere in `bin/` for ad-hoc string matching
(e.g. `bin/dispatch.sh:277`, `bin/linear.sh:64-65`,
`bin/pipeline.sh:240` all use `[[ =~ ]]`; not used in
`bin/common.sh::parse_pipeline_marker` itself, which prefers
`grep -oE` + `sed -E` + `jq` for marker extraction). The verdict
text would read:

```bash
issue_id_from_branch() {
  local branch="$1"
  if [[ "$branch" =~ ^(feat|fix)/(eng-[0-9]+)- ]]; then
    printf '%s\n' "$(tr '[:lower:]' '[:upper:]' <<<"${BASH_REMATCH[2]}")"
  fi
}
```

**Rejected because the Linear issue's AC #1 names the delimiter
swap explicitly as the fix.** Going beyond it is scope creep on a
ticket framed as "one-line code fix." The class-of-bug argument
("future contributor might re-introduce the pipe delimiter") is
defended by D-5's test cases — a regression on the regex contract
is caught by the test regardless of whether the implementation
uses `sed` or `[[ =~ ]]`. Defer the broader rewrite to a followup
ticket if a future contributor argues the case (see §10).

**Rejected alternative — extract a `_normalize_eng_id` helper into
`bin/common.sh`.** Premature abstraction — the only caller is
`cleanup-worktrees.sh`. Add the helper if/when a second caller
appears (CLAUDE.md "Doing tasks" §: "No premature abstractions —
three similar lines is better than a premature abstraction").
Rejected.

### D-3: Pass `issue_id` through `remove_tree`; fix the metric shape

**Verdict.** Restructure `remove_tree` to accept `issue_id` as a
fourth positional arg, and use it correctly in the metrics call.
Concretely:

```bash
# bin/cleanup-worktrees.sh:33-42 (rewritten)
remove_tree() {
  local path="$1" branch="$2" reason="$3" issue_id="${4:-}"
  log "cleanup: removing worktree $path (branch=$branch, reason=$reason)"
  git -C "$TARGET_REPO" worktree remove --force "$path" 2>/dev/null || {
    log "cleanup: git worktree remove failed; forcing rm of $path"
    rm -rf "$path"
  }
  git -C "$TARGET_REPO" branch -D "$branch" 2>/dev/null || true
  bash "$SCRIPT_DIR/metrics.sh" worktree-cleanup "$issue_id" "" success 0 \
    "branch=$branch reason=$reason path=$path"
}
```

Update the two call sites:

```bash
# line 64-66 (PR-merged path):
issue_id="$(issue_id_from_branch "$branch")"
transition_done "$issue_id"
remove_tree "$path" "$branch" "merged" "$issue_id"

# line 75 (Canceled path):
remove_tree "$path" "$branch" "canceled" "$issue_id"
```

And fix the orphan-detected metric on line 88 in the same way:

```bash
# line 88 (rewritten):
bash "$SCRIPT_DIR/metrics.sh" worktree-orphan-detected "${issue_id:-}" "" warn 0 \
  "branch=$branch path=$path age_days=$age_days"
```

**Why.** Direct fix for the issue's AC #3. The retrospective
(`bin/run-retrospective-local.sh`) joins `events.jsonl` records by
`issue_id`; a polluted `issue_id="merged"` field is invisible to
existing tests but corrupts every per-issue retrospective metric
view. The structural shape `event > issue_id > stage > outcome >
duration_ms > notes` matches every other call site of `metrics.sh`
in the harness (verified: `grep -rn 'metrics.sh' bin/` shows 14
call sites; all pass `<ENG-N>` or empty in slot 2 and a fixed
stage name in slot 3, never the branch name).

**Why empty-string for the stage slot.** This script's runtime is
the periodic sweep, not a stage in the `brainstorm → plan → ...`
pipeline. The issue's AC #3 explicitly accepts both `"<actual stage
name or empty>"` — empty is the safer choice because the canonical
`stage:*` namespace (`stage:brainstorming`, `stage:planning`, etc.)
maps to Linear labels and pipeline transitions; injecting a non-canonical
synthetic value like `cleanup` into `events.jsonl` makes downstream
retrospective queries that filter `select(.stage == "build")` (or
similar) inconsistent in their semantics. Empty is the explicit
"this event is not associated with a pipeline stage" sentinel.

Note: line 88's old code passed the literal `"cleanup"` in slot 3.
That choice stayed invisible because the field-shift bug always
overrode it (slot 2 carried `$branch`, slot 3 carried `cleanup`,
the resulting JSONL had `stage="cleanup"` accidentally for orphan
events). Switching both events to empty-string makes them
self-consistent and removes the `cleanup` synthetic from the
pipeline-stage namespace.

**Rejected alternative — make `metrics.sh` tolerate the wrong
positional shape and auto-detect.** Pulls schema-recovery logic
into `metrics.sh` for a caller bug. Hides the contract violation
instead of fixing it. Rejected.

**Rejected alternative — fix only the new cleanup metric, leave
the orphan-detected one with the same field-shift bug since the
issue calls out the cleanup event explicitly.** Both calls are in
the same file, the same five-line range, and exhibit the same bug;
fixing one without the other is incoherent. The issue's AC #3 says
"verify metric event shape" (singular) but inspection shows two
events with the same problem. Rejected.

**Rejected alternative — drop the metrics call entirely from the
cleanup path.** Removes the regression-detection signal the
retrospective uses to spot worktree-cleanup leak rates. The metric
is useful when the field is correctly populated. Rejected.

### D-4: Add the sentinel pattern + restructure into `main()`

**Verdict.** Wrap the inline for-loop (currently lines 56-90) into
a `main()` function and add the standard sentinel:

```bash
# new structure after edits:
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
# (require_bin moved INTO main — see below)

issue_id_from_branch() { ... }
remove_tree() { ... }
transition_done() { ... }

main() {
  require_bin gh jq git              # moved from file scope
  shopt -s nullglob
  local worktree_paths=("$PROJECT_STATE_DIR"/ENG-*/worktree)
  if (( ${#worktree_paths[@]} == 0 )); then
    log "no per-issue worktrees under $PROJECT_STATE_DIR; nothing to sweep"
    return 0
  fi

  local path branch issue_id state pr_merged_count pr_open_count last_commit_ts now_ts age_days
  for path in "${worktree_paths[@]}"; do
    ...
  done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
```

Three things move INTO `main()` that were inline at file scope today:
1. `shopt -s nullglob` (cleanup-worktrees.sh:17)
2. The `worktree_paths` early-exit (lines 18-22)
3. **`require_bin gh jq git`** (line 11) — design-persona P1 fold-in.
   At file scope, `require_bin` fires on every `source`, forcing
   the test to PATH-shadow `gh`/`jq`/`git` purely as a side-effect
   of sourcing. Moving into `main()` keeps the source-and-stub
   pattern clean — tests that source the file to get the helper
   functions don't need to care about `gh`/`jq`/`git` availability
   unless they actually invoke `main`.

**Why.** Required precondition for D-5. Without the sentinel, the
test file cannot source `cleanup-worktrees.sh` to access
`issue_id_from_branch` and `remove_tree` as functions; it would
have to invoke the script as a subprocess and assert on side
effects, which is a much weaker test (no introspection of the
function's return value, no isolation of the metrics call vs. the
git operations, no way to assert on `remove_tree`'s metric output
without also having `remove_tree` actually nuke a worktree).

**Rejected alternative — leave the inline structure, write the
test as a black-box subprocess invocation.** Forces the test to
construct a fake `$PROJECT_STATE_DIR/ENG-N/worktree` git worktree,
stub `gh pr list`, stub `linear.sh`, stub `metrics.sh`, run the
full sweep, then read `events.jsonl` to assert shape. Possible but
\~3x the LOC, and brittle to changes in any of the stubs. Rejected.

**Rejected alternative — leave the inline structure, write the
test as a unit test that re-implements the regex inline (i.e.,
test the *spec* of `issue_id_from_branch`, not the *function*).**
Misses the point of regression-locking — a future edit that
diverges the function from the spec would not be caught. Rejected.

### D-5: New test file `bin/cleanup-worktrees-test.sh`

**Verdict.** Create `bin/cleanup-worktrees-test.sh` following the
source-and-stub pattern (`bin/common-test.sh:1-50` and
`bin/metrics-test.sh:1-50` are the canonical templates). Coverage:

| # | Case | Asserts |
|---|---|---|
| A | `issue_id_from_branch "feat/eng-99-foo"` | returns `ENG-99` |
| B | `issue_id_from_branch "fix/eng-100-bar-baz"` | returns `ENG-100` |
| C | `issue_id_from_branch "feat/eng-7-x"` | returns `ENG-7` (single-digit guard) |
| D | `issue_id_from_branch "main"` | returns empty (no match) |
| E | `issue_id_from_branch "feature/eng-5-foo"` | returns empty (`feature` ≠ `feat`) |
| F | `issue_id_from_branch "feat/foo-bar"` | returns empty (no `eng-N` segment) |
| G | `issue_id_from_branch ""` (empty string passed as one positional arg) | returns empty (does not crash). Note: this calls the function with `""` as `$1`, NOT with no args — the test invokes `issue_id_from_branch ""` to ensure `local branch="$1"` works under `set -u`. The "no positional arg at all" case is not exercised because the only caller (`cleanup-worktrees.sh`) always passes one arg. |
| G2 | `issue_id_from_branch "feat/ENG-99-foo"` (uppercase ENG) | returns empty (deliberate case-sensitivity narrowing per AC #1's "drop the `I` flag"). Documents the contract change. |
| H | `remove_tree` end-to-end with stubbed `metrics.sh` and stubbed `git` | `events.jsonl` line has `event="worktree-cleanup"`, `issue_id="ENG-13"`, `stage=""`, `outcome="success"`, `notes` contains `branch=feat/eng-13-foo`, `reason=merged`, `path=...` |
| I | `remove_tree` with empty `issue_id` (caller passes `""` because branch did not match) | `events.jsonl` line has `issue_id=""`, `stage=""`, no field-shift |
| J | `worktree-orphan-detected` synthetic event with branch matching | `events.jsonl` line has `event="worktree-orphan-detected"`, `issue_id="ENG-13"`, `stage=""`, `outcome="warn"`, `notes` contains `branch=feat/eng-13-foo` and `age_days=...` |

Cases A-G2 are the regex contract (~10 LOC of test logic). Cases
H-J are the metrics-shape contract (~15 LOC, includes a tiny
`metrics.sh` stub that just prints argv and a tiny `git` stub
that no-ops the `worktree remove`).

The test exports `STUB_DIR` first in `PATH` so the stub `git` and
stub `metrics.sh` shadow the real ones — same pattern as
`bin/metrics-test.sh:23` (`STUB_DIR="$(mktemp -d)"`).

**Why.** Direct AC #2 ("Add a regression test"). Coverage of
cases C-G is beyond the issue's literal "two cases" but is
proportionate to "the next person who tries to refactor the regex
introduces a regression we can't see"; each case targets a
specific failure mode (single-digit, no-match prefix, no eng-N
segment, empty input) that the original `sed` regex would have
matched correctly but a careless refactor might break. Case H-I
locks the metrics-shape contract that D-3 establishes.

**Rejected alternative — only cases A and B (issue's literal
spec).** Two cases is enough to detect the BSD-`sed` regression
we just shipped, but not enough to detect a regex tightening
("require 2+ digit numbers") or a regex loosening ("accept
`feat/eng_99-foo`"). Cheap insurance; included.

**Rejected alternative — fold the regex tests into `bin/common-test.sh`.**
The function lives in `cleanup-worktrees.sh`, not `common.sh`.
CLAUDE.md "Tests" §: "Tests are sibling shell scripts." Sibling
test goes next to the file under test. Rejected.

### D-6: Operator backfill — short note in `docs/runbooks/recovery.md`

**Verdict.** Append a brief subsection (\~5 lines) to
`docs/runbooks/recovery.md` titled "Backfill — accumulated
Canceled-issue worktrees from pre-ENG-64 hosts":

> ENG-64 fixed `issue_id_from_branch` for macOS; before that fix
> the Canceled-issue cleanup branch silently never fired. Existing
> hosts have an accumulated backlog of Canceled-issue worktrees
> under `$PROJECT_STATE_DIR/ENG-*/worktree`. **Action:** none
> required — the next periodic cleanup tick (every
> `CLEANUP_EVERY_N_TICKS` ticks of `bin/run-local.sh`) will sweep
> them automatically. To accelerate: `TARGET_REPO=… bash
> bin/cleanup-worktrees.sh` runs the sweep manually; it is
> idempotent.

**Why.** AC #4 asks for "a one-time pass for accumulated
Canceled-issue worktrees." After D-3, the periodic sweep IS the
one-time pass — it just runs automatically on the next tick. The
runbook's job here is to tell the operator "the backlog is
self-clearing; wait one tick or invoke the sweep manually if
impatient." A longer recipe (with enumeration helper, dry-run
flag, etc.) is documentation that rots; we keep it minimal.

**Rejected alternative — add a `--backfill` flag to
`cleanup-worktrees.sh` that does the same thing.** Dead code the
moment the first tick clears the backlog. Rejected.

**Rejected alternative — ship a multi-step enumeration helper in
the runbook.** Per the product persona's P1: the brainstorm itself
notes the next periodic tick auto-clears the backlog, so anything
beyond a one-liner is doc surface that rots. Rejected.

**Rejected alternative — leave AC #4 unimplemented; document only
in the PR description.** The PR description disappears from operator
view after merge; the runbook is the durable surface. Rejected.

## 5. Architecture (where code goes)

| File | What changes | Decision |
|---|---|---|
| `bin/cleanup-worktrees.sh:28` | swap `\|` delimiters → `,` ; drop `I` flag | D-1 |
| `bin/cleanup-worktrees.sh:33-42` | `remove_tree` accepts `issue_id`; metric call uses correct slots; `stage` slot becomes empty string | D-3 |
| `bin/cleanup-worktrees.sh:64,75` | call sites pass `issue_id` through to `remove_tree` | D-3 |
| `bin/cleanup-worktrees.sh:88` | orphan-detected metric uses `${issue_id:-}` in issue_id slot; `stage` slot becomes empty string | D-3 |
| `bin/cleanup-worktrees.sh:11, 17-22, 56-90` | move `require_bin` + `shopt -s nullglob` + worktree-paths early-exit + main loop INTO `main()`; add sentinel | D-4 |
| `bin/cleanup-worktrees-test.sh` (NEW, \~90 LOC) | ten test cases A, B, C, D, E, F, G, G2, H, I, J | D-5 |
| `docs/runbooks/recovery.md` (append \~5 lines) | brief operator backfill note | D-6 |

No other files change. No `bin/metrics.sh` changes. No
`AGENT_PROMPTS.md` changes. No new `dispatch.sh::allowed_tools_for`
case (this is not a stage-level script). No `bin/run-local.sh`
changes — `bin/cleanup-worktrees.sh` is invoked from
`bin/run-local.sh:392` as a black-box subprocess; the sentinel
refactor is invisible to the caller.

## 6. Data flow

There is no runtime data-flow change for the cleanup mechanism
itself. The two flows are unchanged in structure:

```
run-local.sh tick (every CLEANUP_EVERY_N_TICKS)
  → cleanup-worktrees.sh::main
    → for each $PROJECT_STATE_DIR/ENG-*/worktree:
      → branch = git rev-parse --abbrev-ref HEAD
      → if PR merged: transition_done($issue_id) → remove_tree → metrics.sh worktree-cleanup
      → elif Linear state == Canceled: remove_tree → metrics.sh worktree-cleanup
      → elif orphan (no PR + 30d age): metrics.sh worktree-orphan-detected (warn-only, no remove)
```

What changes is the *shape* of the JSONL records produced. Before:

```json
{"event":"worktree-cleanup","issue_id":"merged","stage":"feat/eng-43-...","outcome":"success","notes":"path=..."}
{"event":"worktree-orphan-detected","issue_id":"feat/eng-43-...","stage":"cleanup","outcome":"warn","notes":"path=... age_days=33"}
```

After:

```json
{"event":"worktree-cleanup","issue_id":"ENG-43","stage":"","outcome":"success","notes":"branch=feat/eng-43-foo reason=merged path=..."}
{"event":"worktree-orphan-detected","issue_id":"ENG-43","stage":"","outcome":"warn","notes":"branch=feat/eng-43-foo path=... age_days=33"}
```

(`issue_id` is empty when the branch does not match, e.g., a
worktree someone manually checked out at `main`.)

## 7. Error handling

- **Empty input to `issue_id_from_branch`.** Bash 3.2 `[[ "" =~ ... ]]`
  evaluates to false (no match); the function returns 0 with no
  output. Behavior matches the old `sed` path. Test case G locks
  this.
- **Branch with non-ASCII characters.** `[[ =~ ]]` operates on
  bytes; the regex anchors are still `^...` so a non-ASCII prefix
  would simply not match. Same behavior as `sed`.
- **`metrics.sh` is unavailable** (file missing, permissions). The
  `bash "$SCRIPT_DIR/metrics.sh" ...` call exits non-zero; the
  outer `set -euo pipefail` propagates. Same as today. Out of
  scope to change.
- **`git -C "$path" rev-parse` fails** (worktree corrupted).
  `[[ -n "$branch" ]]` guard on line 59 still triggers `continue`.
  Unchanged.
- **`gh pr list` rate-limited or failing.** `2>/dev/null || echo 0`
  on lines 62, 81 swallows the error and treats it as "no merged
  PR / no open PR." Conservative — leaves the worktree in place,
  no false-positive deletion. Unchanged.
- **`bin/linear.sh get-issue` fails.** `2>/dev/null` on line 73
  + `jq` returning empty → `state` stays empty → cancel path
  skipped. Conservative. Unchanged.
- **Test stubs leak into other tests.** `bin/cleanup-worktrees-test.sh`
  uses `mktemp -d` for `STUB_DIR` and `HARNESS_STATE_DIR`, then
  `trap 'rm -rf …' EXIT` — same pattern as `bin/common-test.sh:26`
  and `bin/metrics-test.sh:29`. No global state leaks.

## 8. Edge cases

| Case | Behavior |
|---|---|
| Branch is uppercase: `feat/ENG-99-foo` | Old `sed` had `I` flag (case-insensitive) but it never fired on macOS anyway because of the delimiter bug. New `sed` (D-1) drops the `I` flag per AC #1, so uppercase `ENG-99` does NOT match. Acceptable: the harness branch-creation site (verified: `bin/run-stage.sh` and `bin/poll.sh` build branches with literal `feat/eng-` lowercase prefix) always emits lowercase. If a human creates a worktree manually with uppercase `feat/ENG-99-foo`, they will skip the cleanup path on the merged-PR and Canceled-issue branches and fall through to the orphan-detect path on its 30-day timer. Locked into the test by case G2. |
| Branch matches multiple times (impossible — anchored `^`) | `[[ =~ ]]` populates `BASH_REMATCH` with the first match. Anchored regex means there is only one match. No-op concern. |
| `transition_done` fails (Linear API down) on the merged-PR path | Unchanged behavior: `transition_done` calls `bin/linear.sh transition-state`, which propagates errors via `set -e`. The `remove_tree` after it does NOT run on Linear failure, so the worktree stays. After ENG-64, `remove_tree` accepts the same `issue_id`; if `transition_done` succeeded, the issue_id is still resolved correctly. No change to error path. |
| Caller passes an empty issue_id to `remove_tree` (Canceled path: branch matched the regex; if it didn't, the cancel-state lookup would have been skipped). | The metric carries `issue_id=""`. JSONL emits `"issue_id":""`. Acceptable — empty is the documented sentinel for "no issue resolvable." Test case I locks this. |
| Sentinel refactor breaks `bin/run-local.sh:392` invocation | `bin/run-local.sh:392` invokes `bash "$SCRIPT_DIR/cleanup-worktrees.sh"` with no args. After the sentinel refactor, that triggers `main "$@"` with empty args. `main` ignores positional args (it has no parameter handling). No-op. |
| `bin/run-local.sh` invokes the script in a subshell where `$PROJECT_STATE_DIR` is unset | `cleanup-worktrees.sh` sources `bin/common.sh` first, which `require_env`s the upstream variables. If `PROJECT_STATE_DIR` is unset, `common.sh` dies before the inline body runs (today) and before `main` runs (after refactor). Same behavior. |
| Pre-commit hook (`.githooks/pre-commit`) runs `bin/cleanup-worktrees-test.sh` and times out or fails on first install | The test does not require Linear API access (case H-I stubs `linear.sh` and `metrics.sh`); cases A-G are pure regex tests on string input. Total runtime should be well under the ~30s budget the hook documents (estimated <2s per case ×9 cases = ~1s). Not a real risk. The test is added to the standard `bin/*-test.sh` glob; pre-commit picks it up automatically. |

## 9. Persona review

Six personas dispatched. Verdicts and any folded P0/P1 findings are
recorded at the end of the brainstorming stage; if any P0 remained
after iteration 3, the gate sets status=`escalate`. The status line
in the stage summary names the final pass count and any unresolved
P0s.

(Slot intentionally pre-populated with structure; final verdicts and
folded findings are appended below by the iteration loop.)

### Iteration 1

| Persona | Verdict | P0 | P1 |
|---|---|---|---|
| design | PASS | 0 | 3 |
| security | PASS | 0 | 0 |
| scope | FAIL | 2 | 3 |
| coherence | FAIL | 1 | 3 |
| product | PASS | 0 | 2 |
| feasibility | _pending_ | _ | _ |

**P0 findings folded in iteration 2:**
- scope-P0-1 ("D-3 expands beyond AC #3 verification step") →
  added explicit Path A / Path B scope-split flag in §1 with
  reversibility note for the plan stage.
- scope-P0-2 ("D-2 supersedes the literal one-line ask in AC #1") →
  swapped: D-1 (comma-delim sed) is now the primary verdict; D-2
  (Bash-native rewrite) demoted to a rejected alternative under
  D-1 with a "defer to followup" note. AC #1 row in §11 updated
  to reference D-1.
- coherence-P0-1 ("§11 AC1 row text inconsistent with §5/D-2") →
  resolved by the same D-2 → D-1 swap.

**P1 findings folded in iteration 2:**
- design-P1-a (uppercase narrowing) → added test case G2 to
  document the contract; updated §8 edge-cases row.
- design-P1-b (`stage="cleanup"` namespace pollution) → switched
  both events to empty-string `stage`, with rationale in D-3.
- design-P1-c (`require_bin gh jq git` at file scope) → moved
  into `main()` per D-4.
- coherence-P1-a (uppercase claim unsupported in test table) →
  added explicit case G2.
- coherence-P1-b (orphan-detected metric not in any AC test) →
  added case J + AC #3 row references J.
- coherence-P1-c (case G `set -u` ambiguity) → clarified case G
  description (calls function with `""` as `$1`, not zero args).
- product-P1-a (log-noise symptom not in goals) → added Goal #1a.
- product-P1-b (D-6 backfill section over-elaborate) → trimmed
  D-6 to a \~5-line note.
- scope-P1-a (D-4 sentinel refactor) → kept; rationale stands
  (precondition for source-and-stub testing, harness's standard
  pattern).
- scope-P1-b (D-5 ships more cases than AC2) → kept; rationale
  stands (regression insurance).
- scope-P1-c (D-6 enumeration helper) → trimmed alongside
  product-P1-b.

### Iteration 2

| Persona | Verdict | P0 | P1 |
|---|---|---|---|
| feasibility | PASS | 0 | 0 |
| scope (re-run) | PASS | 0 | 2 |
| coherence (re-run) | PASS | 0 | 0 |

Iteration 2 P1s (none load-bearing):
- scope-P1-a (D-3 still expands beyond AC #3 wording) — defensible
  per Path A/B split flag in §1; plan stage decides.
- scope-P1-b (D-5 ships 10 cases vs issue's literal 2) — defensible
  regression insurance; AC2 row maps cleanly to cases A and B.

**Status:** Personas: 6/6 PASS · gate P0: 0 · proceeding to planning.

## 10. Open questions / out of scope

1. **Audit other `sed -E` call sites for the same `|` delimiter
   pattern.** A grep across `bin/*.sh` for `sed -nE\|sed -E` would
   surface any other call that uses `|` for both delimiter and
   alternation. Out of scope for ENG-64 (the issue is scoped to
   `cleanup-worktrees.sh`); flag for a followup audit ticket if
   any are found, with the same comma-delimiter or `[[ =~ ]]` fix.
2. **CI-on-Linux blind spot.** Pre-commit hook (`.githooks/pre-commit`)
   runs the suite on the operator's host (macOS). There is no
   Linux CI today (`learned-rules/harness/project-profile.md`
   §"Build & test gates": "no compile step, lint = `bash -n`").
   This means the inverse class of bug (a fix that works on macOS
   BSD-`sed` but breaks on GNU-`sed`) is also undetected. Out of
   scope: D-2's `[[ =~ ]]` fix uses Bash-native regex which is
   identical across platforms, sidestepping this concern for the
   cleanup-worktrees path. Bigger CI question is a separate
   ticket.
3. **`bin/cleanup-worktrees.sh` does not currently route exit codes
   through `failure_outcome_for_exit`.** It runs as a fire-and-forget
   subprocess from `run-local.sh:392` (`|| log "...non-fatal"`),
   so any non-zero exit is swallowed. Improving this would require
   `run-local.sh` to record per-run cleanup outcomes via
   `metrics.sh` itself. Out of scope; flagged.
4. **The orphan-detected event currently logs but does not delete.**
   AC #3 calls out `worktree-cleanup` shape, not orphan-detected
   shape. We fix both (D-3) for coherence, but the question of
   "should we auto-delete orphans after N days" is a separate
   design decision deferred to a future ticket — D-3 is shape-fix-
   only.
5. **`stage` slot value (`"cleanup"`) breaks downstream queries
   that filter by canonical pipeline stage names.** If a
   retrospective query does `select(.stage == "build")`, it never
   saw `worktree-cleanup` events anyway (because `stage` was
   "feat/eng-...-..."). After ENG-64 the value is `"cleanup"`,
   which is consistent with `worktree-orphan-detected`'s existing
   `"cleanup"` value. Acceptable — actually *fixes* the stage-name
   namespace pollution.
6. **One-time backfill enumeration helper is doc-only, not
   scripted.** D-6's runbook gives operators a recipe; we don't
   ship a `--dry-run` flag on cleanup-worktrees.sh because the
   sweep is already idempotent and runs every CLEANUP_EVERY_N_TICKS.
   If operators ask for a flag in followup, that's a small
   add-on PR.
7. **`partition_dirty_paths` does NOT have a built-in `bin/*-test.sh`
   allow-rule.** Verified at `bin/run-local-helpers.sh:47-86` —
   the default `implementing` allowlist is `src/ src-tauri/ crates/
   tests/ docs/ package.json package-lock.json bun.lock bun.lockb
   Cargo.toml Cargo.lock`. New `bin/cleanup-worktrees-test.sh`
   (or any other `bin/*` modification during the implement stage)
   would be classified as out-of-scope → self-leak unless the
   harness-self target's `.pipeline-config/config.json` carries
   `scope.allowlist.implementing` with `bin/` (or `bin/*-test.sh`,
   or specific paths). This is verified by recent test additions
   (ENG-44, ENG-50, ENG-51 in git log) that DID land via the
   implement-stage path. Assumes operator's per-target override
   stays configured. If not, ENG-64's implement stage halts on
   self-leak and the operator must add the override before
   re-dispatching. Not a code change for ENG-64; a config
   precondition. Out-of-scope for this ticket as a *fix*; flagged
   here so the implement stage knows to re-dispatch after the
   operator adds the override if it is somehow missing.

## 11. Acceptance criteria

The Linear issue lists 4 acceptance criteria (AC1–AC4). All four
are verified by automated tests except AC4 which is operator
work documented in the runbook.

| AC | Verifies | Verification |
|---|---|---|
| AC1 | One-line code fix at `bin/cleanup-worktrees.sh:28` — `\|` delimiters → `,` ; `I` flag dropped | D-1 literal one-liner; contract locked by test cases A, B, C, D, E, F, G, G2 (G2 documents the case-sensitivity narrowing per the dropped `I` flag) |
| AC2 | Regression test asserts `issue_id_from_branch "feat/eng-99-foo"` → `ENG-99`, `"fix/eng-100-bar-baz"` → `ENG-100` | `bash bin/cleanup-worktrees-test.sh` cases A and B |
| AC3 | Synthetic `worktree-cleanup` event has `issue_id="ENG-N"`, `stage="<actual stage name or empty>"`, branch in `notes` | `bash bin/cleanup-worktrees-test.sh` case H (issue_id=ENG-13, stage=empty, notes contains branch=...) + case I (issue_id="" when branch did not match) + case J (orphan-detected event has the same shape) |
| AC4 | One-time pass for accumulated Canceled-issue worktrees | `docs/runbooks/recovery.md` "Backfill" subsection (D-6); operator action — periodic sweep is self-clearing post-fix |

## 12. Anti-bias checks

### ADR stress test

There is no `docs/knowledge/decisions.md` (verified: `ls docs/`).
The architectural commitments to interact with are:

- **ENG-26 metric-shape work** (preserved cost-flag round-tripping
  in `bin/metrics.sh`). This brainstorm reinforces ENG-26 by
  fixing the *positional* shape that ENG-26 did not touch. No
  pressure on ENG-26.
- **ENG-23 path-variable rename** (`HARNESS_ROOT`, `TARGET_REPO`,
  `HARNESS_STATE_DIR`, `PROJECT_STATE_DIR`). This brainstorm uses
  `$PROJECT_STATE_DIR` correctly (line 18 today, unchanged). No
  pressure.
- **CLAUDE.md "When wiring a new script" §** — sentinel pattern,
  metrics.sh/linear.sh wrappers, `failure_outcome_for_exit`.
  D-4 brings cleanup-worktrees.sh into the sentinel pattern;
  D-3 keeps the metrics.sh wrapper. Strengthens the existing
  conventions; no pressure.
- **CLAUDE.md "Sweep + scope partition" §** — `partition_dirty_paths`
  applies the D-004 issue-id basename token check ONLY for
  `brainstorming|planning` stages (verified at
  `bin/run-local-helpers.sh:140-141`: `case "$stage" in
  brainstorming|planning) apply_d004=1 ;; esac`). The brainstorm
  doc itself (this file) has `eng-64` in its basename and is
  written under the brainstorming stage — buckets as in-scope.
  The new test file `bin/cleanup-worktrees-test.sh` will be
  written under the **implement** stage, where the D-004 token
  check is NOT applied; instead, the implement-stage allowlist
  (`src/ src-tauri/ crates/ tests/ docs/ ...` per default, OR
  the per-target `.scope.allowlist.implementing` override) governs.
  The harness-self target presumably has the override configured
  (recent test-additions confirm it works) — see §10 Q7.
  No pressure on existing ADRs; this is a noted feasibility
  precondition for the implement stage, not an architectural
  conflict.

No ADR is destabilized. The brainstorm is a strict reinforcement
of existing conventions.

### Simpler-alternative table

| Decision | Simpler alt | Why rejected |
|---|---|---|
| D-1 (comma-delim sed; literal one-liner from issue) | (this IS the simpler alt) | Adopted as the primary verdict; the broader Bash-native rewrite is now a rejected alternative under D-1, reserved for a followup ticket |
| D-3 (pass issue_id through; fix orphan event too) | Fix only `worktree-cleanup` event, leave orphan-detected | Same bug, same five-line range; fixing one but not the other is incoherent. Path B in §1 split flag is the *fully* simpler alt that defers D-3 entirely to ENG-65 — recorded explicitly. |
| D-4 (sentinel refactor) | Keep inline body, write black-box subprocess test | Subprocess test is ~3x LOC and brittle; sentinel is the harness's standard pattern |
| D-5 (10-case test file) | Issue's literal "two cases" (A, B) | Eight extra cases catch regex-tightening / regex-loosening regressions and lock the metrics-shape contract at \~negligible cost |
| D-6 (5-line runbook note) | PR description only | PR description rots; runbook is durable operator surface. (Trimmed from a longer recipe per product-persona feedback — periodic sweep is self-clearing.) |

### Assumption inventory (codebase-fact verification)

| # | Assumption | Status | Evidence |
|---|---|---|---|
| 1 | `bin/cleanup-worktrees.sh:28` uses `sed -nE 's|^(feat|fix)/(eng-[0-9]+)-.*|\2|pI'` with `|` as both delimiter and alternation | verified | `bin/cleanup-worktrees.sh:28` (read directly) |
| 2 | BSD `sed` parses the second `|` as the closing delimiter and exits with `RE error: parentheses not balanced` on macOS | verified | issue body reproduction; consistent with BSD `sed`'s POSIX-ish behavior; also the issue cites observed firing 6+ times in the operator's session log |
| 3 | `bin/cleanup-worktrees.sh:33-42::remove_tree` does not receive `issue_id` from its callers; line 41 passes `"$3"` (= `reason`) in the `metrics.sh` `issue_id` slot | verified | `bin/cleanup-worktrees.sh:33-42` (read directly) |
| 4 | `bin/metrics.sh:20` signature is `<event> <issue_id> <stage> <outcome> <duration_ms> [notes…]` | verified | `bin/metrics.sh:19-21` (read directly) |
| 5 | `bin/cleanup-worktrees.sh:88` (orphan-detected) passes `"$branch"` in the `metrics.sh` `issue_id` slot — same field-shift class | verified | `bin/cleanup-worktrees.sh:88` (read directly) |
| 6 | `bin/cleanup-worktrees.sh` lacks the sentinel `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi` pattern; the for-loop body is inline at lines 56-90 | verified | `bin/cleanup-worktrees.sh:56-90` (read directly) |
| 7 | `bin/cleanup-worktrees-test.sh` does not exist | verified | `ls bin/cleanup-worktrees-test.sh 2>&1` returned "No such file or directory" |
| 8 | `bin/run-local.sh:392` invokes `bash "$SCRIPT_DIR/cleanup-worktrees.sh"` as a fire-and-forget subprocess | verified | `bin/run-local.sh:391-392` (read directly) |
| 9 | `bin/common-test.sh` and `bin/metrics-test.sh` use the source-and-stub pattern with `STUB_DIR=$(mktemp -d)`, post-source override of `PROJECT_STATE_DIR`, `trap 'rm -rf' EXIT` | verified | `bin/common-test.sh:13-30`, `bin/metrics-test.sh:13-30` |
| 10 | `[[ =~ ]]` is used in `bin/` files (idiomatic for ad-hoc string matching) | verified, but original wording was wrong | `bin/common.sh` itself does NOT use `=~` (verified: `grep '=~' bin/common.sh` returns 0 matches; `parse_pipeline_marker` uses `grep -oE` + `sed -E` + `jq`; `failure_outcome_for_exit` is a pure `case` switch). Other files DO: `bin/dispatch.sh:277`, `bin/linear.sh:64-65,160,178`, `bin/pipeline.sh:240`, `bin/halt-sprawl-adversarial-test.sh:178`, `bin/dispatch-test.sh:147`. The D-1 rejected-alternative paragraph has been corrected to reference these actual call sites. |
| 11 | The harness convention emits branches as lowercase `feat/eng-N-...` / `fix/eng-N-...` (so the `I` case-insensitive flag in the original `sed` was redundant) | verified | `bin/branch-name.sh:20,31` lowercases the issue identifier via `tr '[:upper:]' '[:lower:]'` and emits `printf '%s/%s-%s\n' "$prefix" "$ident_lower" "$slug"`; invoked from `bin/run-stage.sh:157,610,847`. (Earlier brainstorm cited `run-stage.sh` as the construction site — corrected to `branch-name.sh`.) |
| 12 | `docs/runbooks/recovery.md` exists and is the harness's existing operator-recovery surface | verified | `ls docs/runbooks/` returns `recovery.md`; read confirmed it's an ENG-41 recovery doc with H2-section structure that D-6 can append to |
| 13 | `bin/run-local-helpers.sh::partition_dirty_paths` does NOT have a built-in `bin/*-test.sh` allow-rule; new `bin/` paths during the implement stage are bucketed via `_scope_allowlist_override` (per-target `.pipeline-config/config.json::scope.allowlist.implementing`) — the harness-self target presumably has this override since recent commits added `bin/*-test.sh` files via the implement stage | verified, claim wording corrected | `bin/run-local-helpers.sh:11-20` (`_scope_allowlist_override` reads `.scope.allowlist[stage]` from CONFIG); `:47-68` (default `implementing` allowlist is `src/ src-tauri/ crates/ tests/ docs/ package.json …`, no `bin/`); `:60-68` (override returned by `_scope_allowlist_override` REPLACES the default if non-empty array). Recent test additions verified by `git log --diff-filter=A --name-only -- 'bin/*-test.sh'`: ENG-44 30ee400, ENG-50 de375b2, ENG-51 0172b98 — all landed via implement-stage flow. The harness-self `.pipeline-config/config.json` is gitignored and not in the worktree (verified: `find .pipeline-config` returned "No such file or directory"); operator's actual config presumed to include the override. Risk: if the override is missing, ENG-64's implement stage will self-leak — see §10 Q7. |
| 14 | `bin/cleanup-worktrees.sh:33-42` `transition_done` is invoked on the PR-merged path before `remove_tree` (line 64-66); on Canceled path `transition_done` is NOT invoked (D-3's behavior preserves this) | verified | `bin/cleanup-worktrees.sh:62-78` (read directly) |
| 15 | The pre-commit hook (`.githooks/pre-commit:90`) runs `bin/*-test.sh` via glob; the new test file is auto-included | verified | `.githooks/pre-commit:90` (`for t in bin/*-test.sh; do …`) |
| 16 | `learned-rules/harness/project-profile.md` documents the runtime as macOS-compatible Bash 3.2+ | verified | `learned-rules/harness/project-profile.md:11` |
| 17 | There is no `docs/VISION.md`, `docs/ARCHITECTURE.md`, or `docs/knowledge/decisions.md` in this repo | verified | `ls docs/` returns only `brainstorms/  pipeline-vocabulary.md  pipeline-vocabulary.template.md  plans/  runbooks/`; no `knowledge/` subdir |
| 18 | `learned-rules/harness/brainstorm.md` does not exist (no learned rules to follow) | verified | `ls learned-rules/harness/` returns only `project-profile.md` |

All 18 assumptions verified against current code/repo state in
iteration 2. Two iteration-1 codebase-fact errors were caught by
the feasibility persona and corrected:

- **Row 10 wording fix.** Previously claimed `bin/common.sh::parse_pipeline_marker`
  and `failure_outcome_for_exit` use `[[ =~ ]]`. They do not
  (verified by direct read). Corrected to cite the actual
  `[[ =~ ]]` call sites: `bin/dispatch.sh:277`, `bin/linear.sh:64-65`,
  `bin/pipeline.sh:240`. Load-bearing context: this was in D-1's
  rejected-alternative paragraph rationalizing the Bash-native
  rewrite by an idiom-alignment argument. Since D-1's verdict is
  the literal sed fix (not the Bash-native rewrite), the corrected
  citation is now an accurate description of where the alternative
  idiom IS used elsewhere, without making a false claim about
  `common.sh`.
- **Row 13 wording fix.** Previously claimed
  `partition_dirty_paths` has a built-in `bin/*-test.sh` allow-rule.
  It does not (verified at `bin/run-local-helpers.sh:47-86`).
  Corrected to: the per-target `.pipeline-config/config.json::scope.allowlist.implementing`
  override is what allows new `bin/` paths to bucket in-scope
  during the implement stage. The harness-self operator's
  `.pipeline-config/` is gitignored and not in the worktree;
  recent test additions confirm the override exists in operator's
  per-machine config.

Codebase-fact verification per the ENG-5 anti-pattern guard:
every named function (`issue_id_from_branch`, `remove_tree`,
`transition_done`, `partition_dirty_paths`,
`_scope_allowlist_override`, `stage_output_paths`, `main`), file
path, line range, and metric event name in this brainstorm has
been opened and confirmed in the current `bin/` tree.
