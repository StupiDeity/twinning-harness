---
linear: ENG-146
title: Planning detective trips on duplicate dispatch_id after success-path state-file delete (seq counter resets on every stage transition)
date: 2026-05-18
status: draft
---

# Planning detective trips on duplicate dispatch_id — preserve seq across success cleanup AND scope detective grep by stage

## 1. Overview (and the load-bearing surprise)

The ticket framed this as an `--action continue` bug: the operator resumes
a halted planning dispatch, the next dispatch re-emits the same
`dispatch_id` as the halted one, the planning detective
(`_assert_progress_md_entry`) grep'ed `progress.md` finds 2 entries for
that id, and trips with `progress-md-entry-missing` (rc=31). The
proposed fix in the ticket body was: preserve `current_dispatch_seq`
across the atomic-reset.

**The surprise:** that fix already landed in `2c6216d` (2026-05-10):
`_pipeline_drain_issue_state` in `bin/pipeline.sh:217-247` already
preserves `{current_dispatch_seq, current_dispatch_id, current_stage}`
when `policy == "skip-until-human-acts"` and the file carries the
allocator fields. ENG-87 review-iter-2 introduced this exact
preservation as fix `C1'`. The drain is not the leak.

The real leak is upstream — in the **success path**. Two sites in
`bin/run-stage.sh` clear `issue-state.json` with `rm -f` on a successful
stage transition (lines 849 and 1970). Both were added by `244c3c5`
(ENG-15, 2026-04-20) before `dispatch_id` existed (ENG-87 landed
`d94bb27` 2026-04-30). When those rm sites were merged with the
dispatch_id allocator, the contract broke: every successful stage
transition wipes the seq counter. The next stage's first dispatch reads
`prior_seq = 0`, emits `d0001`, and collides with the previous stage's
`d0001` (which is already an H2 entry in `progress.md`).

The planning detective then greps `^## ${PIPELINE_DISPATCH_ID-} - ` —
note the trailing space — which matches *any* stage's entry stamped
with that id. `progress.md` after a clean brainstorming + a freshly-
started planning has:

```
## ENG-N-d0001 - brainstorming - 2026-05-17T11:46:55Z   ← from brainstorming
...
## ENG-N-d0001 - planning - 2026-05-17T12:14:24Z       ← from planning
```

`grep -c "^## ENG-N-d0001 - "` returns 2, the detective expects 1, halts
at rc=31. The agent's actual output was fine; the detective tripped on a
false positive caused by collateral state in the file.

This is exactly the structural failure pattern ENG-87 named: a fresh
dispatch's reader treats data written by a prior dispatch (here, by a
prior *stage's* dispatch under the same identifier) as if it were
current. The seq-collision and the stage-blind grep are both
manifestations.

## 2. Forensic ground truth — ENG-140 incident, 2026-05-17

From `~/.local/state/twinning-harness/harness/ENG-140/dispatch_history.jsonl`:

```jsonl
{"dispatch_id":"ENG-140-d0001","stage":"brainstorming","exit_at":"...11:48:44Z","exit_code":0,...}
{"dispatch_id":"ENG-140-d0001","stage":"planning","exit_at":"...12:15:37Z","exit_code":31,...}
{"dispatch_id":"ENG-140-d0001","stage":"planning","exit_at":"...13:17:37Z","exit_code":31,...}
```

Three dispatches across two stages, all under the same id. The first
two collide because of the success-path rm wipe between brainstorming
end (11:48:44) and planning start (12:04:35). The third collides with
the second because... actually, no — between 12:15:37 (halt) and
13:05:21 (re-dispatch), `_pipeline_drain_issue_state` *should* have
preserved the seq. But the third dispatch ran under `d0001` again,
which means the drain didn't preserve, OR something between the drain
and the next dispatch wiped the file again.

Re-reading the drain helper: it only strips the file when `policy ==
"skip-until-human-acts"`. The 12:15:37 row shows
`policy: "skip-until-human-acts"`, so drain *should* have stripped (not
deleted) the file. Then allocator at 13:05:21 should have read seq=1
and bumped to d0002.

**Open question OQ-1 (load-bearing for the fix):** why did drain not
preserve at 13:05? Hypotheses:
- (a) Some other code path between drain and 13:05 dispatch wiped the
  state file. Candidates: `branch-name.sh`, `reconcile.sh`, an explicit
  `rm` for skip-label clearance. `grep -rn "rm.*issue-state.json" bin/`
  shows only the two sites in `run-stage.sh` plus the drain itself.
- (b) The drain wrote `current_dispatch_seq: 1` but the allocator's
  read parsed it as 0. The allocator's parser has a defensive
  `[[ "$prior_seq" =~ ^[0-9]+$ ]] || prior_seq=0`, but jq's `// 0`
  fallback also returns 0 if the field is `null`. If `jq -c
  '{current_dispatch_seq, ...}'` is invoked on a file *missing* the
  seq field, the output is `{"current_dispatch_seq":null,...}` — and
  then `// 0` returns 0. So if the file was already missing the seq
  field at drain time, drain would re-emit `null` and the bump would
  start fresh.
- (c) An intermediate halt cycle (e.g., classify-failure re-running)
  rewrote the file without preserving the seq. ENG-87 review C2
  hardened classify-failure to merge over `prior_json` (b1a82e3
  similar to drain), so this should not happen on the canonical path.
  But if classify-failure's read of the file errored out (corrupt
  JSON), `prior_json={}` and the merge stomps the seq.

The brainstorm cannot resolve this without re-running the scenario
with extra trace logging. The fix in §4 assumes hypothesis (b) is
load-bearing — even if drain wrote the file correctly the first time,
*some* path can lose the seq, so the regression test should pin the
path explicitly. The structural fix (don't delete in run-stage.sh) is
independent.

## 3. Candidate fixes

The ticket body proposed two. The brainstorm should weigh both;
neither alone closes both holes.

### Fix A — preserve seq across success-path cleanup

**Site 1:** `bin/run-stage.sh:1970` — replace `rm -f issue-state.json`
with a strip that mirrors `_pipeline_drain_issue_state`:

```bash
# Strip-but-preserve: keep allocator fields {seq, id, stage}, drop
# everything else (policy, retry_count, evidence, ...). When the file
# carries no allocator fields (legacy / pre-cutover issue), fall
# through to rm -f for back-compat.
_strip_state_preserve_alloc() {
  local state_file="$1"
  [[ -s "$state_file" ]] || return 0
  jq -e . "$state_file" >/dev/null 2>&1 || { rm -f "$state_file"; return 0; }
  local has_alloc
  has_alloc="$(jq -r 'has("current_dispatch_id") and (.current_dispatch_id // "") != ""' "$state_file")"
  if [[ "$has_alloc" == "true" ]]; then
    local stripped tmp
    stripped="$(jq -c '{current_dispatch_seq, current_dispatch_id, current_stage}' "$state_file")"
    tmp="${state_file}.tmp.$$"
    printf '%s' "$stripped" > "$tmp"
    mv -f "$tmp" "$state_file"
  else
    rm -f "$state_file"
  fi
}
```

Call this from both success sites (849 and 1970). The drain in
`pipeline.sh::_pipeline_drain_issue_state` does the same thing; the
shared helper avoids drift. Lift it into `bin/common.sh` so all three
sites (success-1970, success-849, drain) call the same function.

**Why it's the structural fix:** the seq counter is *per-issue*
monotonic. The contract has always been "id is fresh per dispatch."
Wiping the file on every stage transition broke that contract silently;
this fix restores it. Once seq is preserved across stage transitions,
every dispatch gets a unique id — the planning detective's grep
returns 1 even on the unaltered stage-blind regex.

### Fix B — scope the detective grep by stage

**Site:** `bin/dispatch.sh:298-311` `_assert_progress_md_entry`. Today's
grep is:

```bash
entry_count="$(grep -c "^## ${PIPELINE_DISPATCH_ID-} - " "$progress_path" ...)"
```

Tighten to:

```bash
local stage_re="$stage"
# escape any regex meta-chars in stage (defensive — stage names are
# lowercase alpha but the variable is bash-interpolated)
entry_count="$(grep -c "^## ${PIPELINE_DISPATCH_ID-} - ${stage_re} - " "$progress_path" ...)"
```

Pass `$stage` into `_assert_progress_md_entry` as a third arg (it's
already in scope at the only call site, `dispatch.sh:283`).

**Why it's the narrower fix:** even if seq somehow collides (e.g.,
torn-write recovery, a future code path that wipes the file), the
detective wouldn't trip on cross-stage entries. The same-stage
re-dispatch case (planning halt → resume planning under same id)
still produces two `planning` entries and trips — but that case is
already prevented by Fix A.

### Should we ship both?

**Yes.** Fix A is the structural fix; Fix B is defense-in-depth. They
target different failure modes:

- Fix A alone: closes the canonical "every stage starts at d0001"
  case. But if the seq counter ever resets due to a future bug
  (corrupted state file recovery, a new code path we haven't
  anticipated), the cross-stage collision returns.
- Fix B alone: closes the cross-stage symptom. But same-stage
  re-dispatch (planning → halt → continue → planning) under
  colliding id would still trip — and Fix A is what prevents that.

Shipping both is ~10 lines of code + 3 tests. The asymmetric cost
(both fixes are tiny; the failure cost of either gap is operator
intervention with no obvious diagnosis) tips strongly toward both.

## 4. Acceptance criteria (informs §6)

1. After a clean brainstorming dispatch followed by a planning
   dispatch on a fresh issue, the two dispatches' `dispatch_id`s
   differ (brainstorming = d0001, planning = d0002).
2. After `bin/pipeline.sh decide <issue> --action continue` on a
   halted planning dispatch, the next planning dispatch's id is
   `d<prior_seq + 1>`, NOT `d<prior_seq>`.
3. `_assert_progress_md_entry` does not count entries from other
   stages — even if two stages happen to share a `dispatch_id` (e.g.,
   manual operator edit, or a future bug we haven't anticipated).
4. `dispatch_history.jsonl` rows continue to write monotonically; no
   rewinds. The acceptance criterion from the ticket carries through.
5. Pre-cutover/legacy issues (state file without allocator fields)
   still get cleaned by `rm -f` — back-compat preserved.
6. The two existing rm sites in run-stage.sh AND the drain helper in
   pipeline.sh all delegate to the SAME shared helper in common.sh —
   no drift.
7. New regression tests pin: (a) seq survives success-path cleanup,
   (b) seq survives drain (already covered, extend to assert exact
   `d0002` on resume), (c) detective grep is stage-scoped.

## 5. Not in scope

- Reworking how `dispatch_history.jsonl` records dispatch outcomes.
  Append-only; this fix doesn't touch the writer.
- Changing the `progress.md` H2 entry shape. Stays
  `## <dispatch_id> - <stage> - <iso-ts>` per
  `docs/runbooks/progress-md.md`.
- Adding an operator-visible seq-counter to `bin/status.sh`. The
  counter is now preserved across stage transitions, so it's
  reportable in principle; deferring the UI surface.

## 6. Open questions deferred (acknowledged, not blocking)

- **OQ-1:** the 13:05 re-emission of `d0001` (per §2 hypotheses (a)/
  (b)/(c)). Fix A makes the success-path leak go away; if OQ-1's root
  cause is *not* the success-path leak, the regression test for AC #2
  will fail and we'll re-open. Worst case: ship Fix A + Fix B, then
  follow up with a tighter trace if AC #2 still flakes.
- **OQ-2:** should we move the seq counter out of `issue-state.json`
  into a separate `dispatch-seq` file? That would decouple the
  monotonic counter from the failure-state classifier. Deferred —
  the merge idiom in classify-failure + drain + new shared helper
  is consistent enough that the coupling isn't an active leak.
- **OQ-3:** `_pre_dispatch_merge_gate`'s rm at line 849 is for the
  building→released auto-transition. Should it preserve seq for the
  released stage's downstream consumers? `released` is terminal — no
  downstream dispatches. Applying the strip helper there is correct
  but the consumer side is empty.

## 7. Persona review

### Correctness reviewer (cold pass)

P0: none.
P1: the shared helper must be lifted to `bin/common.sh`, not duplicated
in `run-stage.sh`. Drift between the success-path cleanup and the
drain helper is the original ENG-87 review-iter-2 finding. The plan in
§3 already lifts the helper. PASS.
P1: classify-failure also writes `issue-state.json` with `jq -cn
--argjson prior $prior_json ...`. If `prior_json` is `{}` (corrupt
JSON path), the seq is lost. Hardening classify-failure's
prior_json-on-corruption recovery is OUT of scope for this ticket but
the regression test in §4 AC #2 will exercise the canonical path.
PASS.

### Simplicity reviewer (cold pass)

P0: none.
P1: 10 lines of new code + 1 shared helper + 3 tests is the right size
for the two-axis sizing rubric. Subsystems touched: dispatch
(`dispatch.sh::_assert_progress_md_entry`), orchestrator
(`run-stage.sh` two rm sites + the new helper in `common.sh`). Two
subsystems with one clearly subordinate (orchestrator carries the
structural fix; dispatch carries the defense-in-depth). PASS.

### Anti-pattern reviewer (cold pass)

P0: none.
P1: the `_strip_state_preserve_alloc` helper duplicates the body of
`_pipeline_drain_issue_state` (the inner `if has_alloc` block). The
plan in §3 mitigates by extracting the shared helper to `common.sh`
and having drain delegate to it. PASS.

### Feasibility reviewer (cold pass)

P0: none.
P1: The fix is purely additive to `bin/common.sh` + 2 call-site swaps
in `run-stage.sh` + 1 regex tighten + 1 arg in `dispatch.sh`. No
schema migration, no Linear-contract change, no agent-prompt change.
Lowest-risk class of fix. PASS.

### Operator reviewer (cold pass)

P0: none.
P1: Operators currently work around this bug by running the manual
shepherd (e.g., ENG-140 → PR #124 was operator-driven). Shipping this
removes one well-known reason for manual intervention. PASS.

## 8. Decision

Ship Fix A + Fix B. Plan tasks in §6 of the plan doc.
